#!/usr/bin/env bash
# FTP -> MinIO server-side migration / re-runnable sync.
# Run this ON the MinIO host. Streams FTP -> MinIO; nothing staged to local disk,
# never transits your workstation. Re-running is idempotent: only new/missing
# files are copied (additive `copy`, not destructive `sync`).
#
# Usage:
#   set -a; source ./config.env; set +a     # load your private config (see config.sample)
#   ./sync.sh                                # run
#   ./sync.sh --dry-run                      # preview, transfer nothing
#
# Single-instance: a flock guards against concurrent runs. A second invocation
# exits immediately (code 99). Set SYNC_WAIT=1 to block & queue instead.
# Lock file: ${LOCK_FILE:-/tmp/ftp-to-minio.lock} (stale locks auto-released).
#
# Required env (set in config.env, NOT committed):
#   FTP_HOST FTP_USER FTP_PASS FTP_PATH
#   MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY BUCKET
# Optional env: FTP_PORT FTP_TLS PREFIX MINIO_REGION
#   TRANSFERS CHECKERS FTP_CONCURRENCY S3_CHUNK_SIZE S3_CONCURRENCY

set -euo pipefail

# Always load config.env (next to this script; authoritative). Lets you just
# run ./sync.sh without sourcing, and avoids stale exported vars from an earlier
# `source` masking newly-added keys. Override path with CONFIG_FILE=/path ./sync.sh
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${CONFIG_FILE:-$script_dir/config.env}"
if [ -f "$config_file" ]; then
  echo "loading config: $config_file"
  set -a; . "$config_file"; set +a
fi

: "${FTP_HOST:?set FTP_HOST (in config.env next to sync.sh, or export it)}"
: "${FTP_USER:?set FTP_USER}"
: "${FTP_PASS:?set FTP_PASS}"
: "${FTP_PATH:=/}"
: "${FTP_PORT:=21}"
: "${FTP_TLS:=false}"
: "${MINIO_ENDPOINT:?set MINIO_ENDPOINT}"
: "${MINIO_ACCESS_KEY:?set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?set MINIO_SECRET_KEY}"
: "${MINIO_REGION:=us-east-1}"
: "${BUCKET:?set BUCKET}"
: "${PREFIX:=}"

: "${TRANSFERS:=16}"
: "${CHECKERS:=16}"
: "${FTP_CONCURRENCY:=0}"   # 0 = unlimited; else MUST exceed TRANSFERS+CHECKERS
: "${S3_CHUNK_SIZE:=64M}"
: "${S3_CONCURRENCY:=8}"
: "${BUFFER_SIZE:=32M}"          # per-transfer read-ahead buffer
: "${ORDER_BY:=modtime,desc}"    # transfer NEWEST files first

# rclone's FTP backend opens one connection per transfer AND per checker. If the
# connection cap (FTP_CONCURRENCY) is <= transfers+checkers, checkers grab every
# connection and wait for transfer connections that can never open -> deadlock
# (symptom: 0 B/s on every file while listing worked). Auto-raise to stay safe.
if [ "$FTP_CONCURRENCY" != "0" ]; then
  need=$(( TRANSFERS + CHECKERS + 1 ))
  if [ "$FTP_CONCURRENCY" -le "$(( TRANSFERS + CHECKERS ))" ]; then
    echo "WARN: FTP_CONCURRENCY=$FTP_CONCURRENCY <= transfers+checkers=$((TRANSFERS+CHECKERS)); raising to $need to avoid FTP deadlock" >&2
    FTP_CONCURRENCY="$need"
  fi
fi

command -v rclone >/dev/null || { echo "rclone not installed. See README."; exit 1; }
command -v flock  >/dev/null || { echo "flock not installed (util-linux)."; exit 1; }

# --- single-instance lock -------------------------------------------------
# Hold an exclusive flock on fd 200 for the script's lifetime. The kernel
# releases it when the process exits (even on crash/kill) -> no stale lock.
LOCK_FILE="${LOCK_FILE:-/tmp/ftp-to-minio.lock}"
exec 200>"$LOCK_FILE"
if [ "${SYNC_WAIT:-0}" = "1" ]; then
  flock 200                                       # block & queue until free
else
  flock -n 200 || {                               # fail fast if already held
    echo "another sync is already running (lock: $LOCK_FILE). exit." >&2
    exit 99
  }
fi
# -------------------------------------------------------------------------

ts="$(date +%Y%m%d-%H%M%S)"
log_dir="${LOG_DIR:-./logs}"
mkdir -p "$log_dir"
log_file="${log_dir}/sync-${ts}.log"

dst="minio:${BUCKET}"
[ -n "$PREFIX" ] && dst="minio:${BUCKET}/${PREFIX%/}"

echo "FTP  ftp:${FTP_PATH}  ->  ${dst}"
echo "log  ${log_file}"

# Define both remotes inline via env so no rclone.conf / secrets on disk.
export RCLONE_CONFIG_FTP_TYPE=ftp
export RCLONE_CONFIG_FTP_HOST="$FTP_HOST"
export RCLONE_CONFIG_FTP_PORT="$FTP_PORT"
export RCLONE_CONFIG_FTP_USER="$FTP_USER"
export RCLONE_CONFIG_FTP_PASS="$(rclone obscure "$FTP_PASS")"
export RCLONE_CONFIG_FTP_EXPLICIT_TLS="$FTP_TLS"
export RCLONE_CONFIG_FTP_CONCURRENCY="$FTP_CONCURRENCY"

export RCLONE_CONFIG_MINIO_TYPE=s3
export RCLONE_CONFIG_MINIO_PROVIDER=Minio
export RCLONE_CONFIG_MINIO_ENV_AUTH=false
export RCLONE_CONFIG_MINIO_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
export RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
export RCLONE_CONFIG_MINIO_ENDPOINT="$MINIO_ENDPOINT"
export RCLONE_CONFIG_MINIO_REGION="$MINIO_REGION"

# Progress / stats:
#  - --stats prints a periodic block showing transfer SPEED and FILE COUNTS
#    (e.g. "Transferred: 1.2 GiB / 5 GiB, 10 MiB/s" and "120 / 5000" files).
#  - on an interactive terminal we also add --progress for a live updating bar
#    (speed, ETA, current files). In detached/cron runs the stats go to the log.
: "${STATS_INTERVAL:=15s}"
args=(
  --transfers "$TRANSFERS"
  --checkers "$CHECKERS"
  --order-by "$ORDER_BY"
  --buffer-size "$BUFFER_SIZE"
  --fast-list
  --size-only
  --s3-chunk-size "$S3_CHUNK_SIZE"
  --s3-upload-concurrency "$S3_CONCURRENCY"
  --s3-no-check-bucket
  --retries 3
  --low-level-retries 20
  --stats "$STATS_INTERVAL"
  --stats-log-level NOTICE
  --log-file "$log_file"
  --log-level INFO
)
# live bar only when stdout is a real terminal (skip under nohup/cron)
[ -t 1 ] && args+=(--progress)

# --- source path list ----------------------------------------------------
# Migrate one OR many FTP paths in a single locked run. Precedence:
#   PATHS_FILE (one path per line, # comments allowed)
#   > FTP_PATHS (inline, whitespace/newline separated)
#   > FTP_PATH  (single path, default)
# With >1 path each source is mirrored UNDER the dest at its own subpath, so
# trees never collide (e.g. ftp:/a -> minio:bucket/prefix/a). A single path
# keeps the original flat behavior (contents land directly at the dest).
paths=()
if [ -n "${PATHS_FILE:-}" ] && [ -f "$PATHS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                       # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [ -n "$line" ] && paths+=("$line")
  done < "$PATHS_FILE"
elif [ -n "${FTP_PATHS:-}" ]; then
  read -r -a paths <<< "$FTP_PATHS"
else
  paths=("$FTP_PATH")
fi
[ "${#paths[@]}" -gt 0 ] || { echo "no FTP paths to migrate" >&2; exit 1; }
multi=0; [ "${#paths[@]}" -gt 1 ] && multi=1

for p in "${paths[@]}"; do
  this_dst="$dst"
  if [ "$multi" = 1 ]; then
    sub="${p#/}"; sub="${sub%/}"
    [ -n "$sub" ] && this_dst="$dst/$sub"
  fi
  echo ">> ftp:${p}  ->  ${this_dst}"
  rclone copy "ftp:${p}" "$this_dst" "${args[@]}" "$@"
done

echo "done. summary tail:"
tail -n 3 "$log_file"
