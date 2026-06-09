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
# Required env (set in config.env, NOT committed):
#   FTP_HOST FTP_USER FTP_PASS FTP_PATH
#   MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY BUCKET
# Optional env: FTP_PORT FTP_TLS PREFIX MINIO_REGION
#   TRANSFERS CHECKERS FTP_CONCURRENCY S3_CHUNK_SIZE S3_CONCURRENCY

set -euo pipefail

: "${FTP_HOST:?set FTP_HOST}"
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
: "${CHECKERS:=32}"
: "${FTP_CONCURRENCY:=8}"
: "${S3_CHUNK_SIZE:=64M}"
: "${S3_CONCURRENCY:=4}"

command -v rclone >/dev/null || { echo "rclone not installed. See README."; exit 1; }

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

rclone copy "ftp:${FTP_PATH}" "$dst" \
  --transfers "$TRANSFERS" \
  --checkers "$CHECKERS" \
  --size-only \
  --s3-chunk-size "$S3_CHUNK_SIZE" \
  --s3-upload-concurrency "$S3_CONCURRENCY" \
  --s3-no-check-bucket \
  --retries 3 \
  --low-level-retries 20 \
  --stats 30s \
  --stats-one-line \
  --log-file "$log_file" \
  --log-level INFO \
  "$@"

echo "done. summary tail:"
tail -n 3 "$log_file"
