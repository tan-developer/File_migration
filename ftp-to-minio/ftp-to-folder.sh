#!/usr/bin/env bash
# FTP -> local folder. Re-runnable mirror of an FTP tree into a directory.
# Streams via rclone; additive copy (only new/changed files), idempotent.
#
# Usage:
#   ./ftp-to-folder.sh                 # uses DEST_DIR from config.env
#   DEST_DIR=/data/ftp ./ftp-to-folder.sh
#   ./ftp-to-folder.sh --dry-run       # preview, download nothing
#
# Reads FTP_* + DEST_DIR from config.env next to this script (auto-loaded),
# or from the environment. Same single-instance lock + progress as sync.sh.
#
# Required: FTP_HOST FTP_USER FTP_PASS FTP_PATH DEST_DIR
# Optional: FTP_PORT FTP_TLS TRANSFERS CHECKERS FTP_CONCURRENCY STATS_INTERVAL

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${CONFIG_FILE:-$script_dir/config.env}"
# Always load config.env (authoritative). Avoids stale exported vars from an
# earlier `source` masking newly-added keys. Override file with CONFIG_FILE=.
if [ -f "$config_file" ]; then
  echo "loading config: $config_file"
  set -a; . "$config_file"; set +a
fi

: "${FTP_HOST:?set FTP_HOST (in config.env next to this script, or export it)}"
: "${FTP_USER:?set FTP_USER}"
: "${FTP_PASS:?set FTP_PASS}"
: "${FTP_PATH:=/}"
: "${FTP_PORT:=21}"
: "${FTP_TLS:=false}"
: "${DEST_DIR:?set DEST_DIR (local folder to download into)}"

: "${TRANSFERS:=16}"
: "${CHECKERS:=16}"
: "${FTP_CONCURRENCY:=0}"   # 0 = unlimited; else MUST exceed TRANSFERS+CHECKERS
: "${BUFFER_SIZE:=32M}"          # per-transfer read-ahead buffer
: "${ORDER_BY:=modtime,desc}"    # download NEWEST files first

# Avoid rclone FTP deadlock (see sync.sh): connections must exceed transfers+checkers.
if [ "$FTP_CONCURRENCY" != "0" ]; then
  need=$(( TRANSFERS + CHECKERS + 1 ))
  if [ "$FTP_CONCURRENCY" -le "$(( TRANSFERS + CHECKERS ))" ]; then
    echo "WARN: FTP_CONCURRENCY=$FTP_CONCURRENCY <= transfers+checkers=$((TRANSFERS+CHECKERS)); raising to $need to avoid FTP deadlock" >&2
    FTP_CONCURRENCY="$need"
  fi
fi

command -v rclone >/dev/null || { echo "rclone not installed. See README."; exit 1; }
command -v flock  >/dev/null || { echo "flock not installed (util-linux)."; exit 1; }

# single-instance lock (separate from sync.sh so both can run if you want)
LOCK_FILE="${LOCK_FILE:-/tmp/ftp-to-folder.lock}"
exec 200>"$LOCK_FILE"
if [ "${SYNC_WAIT:-0}" = "1" ]; then
  flock 200
else
  flock -n 200 || { echo "another ftp-to-folder run is active (lock: $LOCK_FILE). exit." >&2; exit 99; }
fi

mkdir -p "$DEST_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
log_dir="${LOG_DIR:-$script_dir/logs}"
mkdir -p "$log_dir"
log_file="${log_dir}/ftp2folder-${ts}.log"

echo "FTP  ftp:${FTP_PATH}  ->  ${DEST_DIR}"
echo "log  ${log_file}"

# Define FTP remote inline (no rclone.conf, no secret on disk).
export RCLONE_CONFIG_FTP_TYPE=ftp
export RCLONE_CONFIG_FTP_HOST="$FTP_HOST"
export RCLONE_CONFIG_FTP_PORT="$FTP_PORT"
export RCLONE_CONFIG_FTP_USER="$FTP_USER"
export RCLONE_CONFIG_FTP_PASS="$(rclone obscure "$FTP_PASS")"
export RCLONE_CONFIG_FTP_EXPLICIT_TLS="$FTP_TLS"
export RCLONE_CONFIG_FTP_CONCURRENCY="$FTP_CONCURRENCY"

: "${STATS_INTERVAL:=15s}"
args=(
  --transfers "$TRANSFERS"
  --checkers "$CHECKERS"
  --order-by "$ORDER_BY"
  --buffer-size "$BUFFER_SIZE"
  --size-only
  --retries 3
  --low-level-retries 20
  --stats "$STATS_INTERVAL"
  --stats-log-level NOTICE
  --log-file "$log_file"
  --log-level INFO
)
[ -t 1 ] && args+=(--progress)

# --- source path list ----------------------------------------------------
# Migrate one OR many FTP paths in a single locked run. Precedence:
#   PATHS_FILE (one path per line, # comments allowed)
#   > FTP_PATHS (inline, whitespace/newline separated)
#   > FTP_PATH  (single path, default)
# With >1 path each source mirrors UNDER DEST_DIR at its own subpath so trees
# never collide. A single path keeps the original flat behavior.
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
  this_dst="$DEST_DIR"
  if [ "$multi" = 1 ]; then
    sub="${p#/}"; sub="${sub%/}"
    [ -n "$sub" ] && this_dst="$DEST_DIR/$sub"
  fi
  mkdir -p "$this_dst"
  echo ">> ftp:${p}  ->  ${this_dst}"
  rclone copy "ftp:${p}" "$this_dst" "${args[@]}" "$@"
done

echo "done. summary tail:"
tail -n 3 "$log_file"
