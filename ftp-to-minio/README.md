# FTP → MinIO migration (server-side)

Streams files from an FTP server directly into MinIO. **rclone runs on the MinIO
host**, so the data path is `FTP → MinIO host → MinIO (localhost)` — it never
transits your workstation, and nothing is staged to local disk (only small
multipart chunks live in RAM).

Re-runnable: uses `rclone copy` (additive). Re-running transfers only files that
are missing or changed size on MinIO — safe to run "when needed". It never
deletes anything on MinIO.

## Why this approach

| Constraint | How it's met |
| --- | --- |
| No data through current machine | rclone runs on the MinIO host, not your laptop |
| Large (>500GB / millions of files) | parallel transfers + checkers, multipart upload, restartable |
| Recurring on-demand | `copy` is idempotent; just run `./sync.sh` again |

## Setup (on the MinIO host)

1. Install rclone:
   ```bash
   curl https://rclone.org/install.sh | sudo bash
   rclone version            # need >= 1.60
   ```
2. Copy this folder to the host. Then:
   ```bash
   cp config.sample config.env
   $EDITOR config.env        # fill FTP + MinIO creds, bucket, path
   chmod +x sync.sh
   ```
3. Make sure the target bucket exists (or create it):
   ```bash
   # via mc, or:
   set -a; source ./config.env; set +a
   AWS_ACCESS_KEY_ID=$MINIO_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$MINIO_SECRET_KEY \
     rclone mkdir "minio:$BUCKET" 2>/dev/null || true
   ```

## Run

```bash
set -a; source ./config.env; set +a
./sync.sh --dry-run      # preview: lists what WOULD copy, transfers nothing
./sync.sh                # real run
```

### Progress (speed + file count)

On an interactive terminal `sync.sh` shows a live rclone progress bar — transfer
**speed**, ETA, bytes done, and **files transferred / total**. Under
`nohup`/cron (no TTY) it instead writes the same stats to the log every
`STATS_INTERVAL` (default `15s`); follow with `tail -f logs/sync-*.log`. Each
block looks like:

```
Transferred:   12.34 GiB / 480 GiB, 3%, 78.5 MiB/s, ETA 1h42m   <- speed
Transferred:         9214 / 2148301, 0%                          <- files
```

### Single-instance lock

`sync.sh` takes an exclusive `flock` (`/tmp/ftp-to-minio.lock`, override with
`LOCK_FILE`). A second run while one is active **exits immediately with code 99**
— no two rclone processes hammer the same FTP + bucket. The lock is held by an
open fd, so the kernel frees it automatically if the process dies (no stale
locks). To queue instead of fail-fast, run with `SYNC_WAIT=1 ./sync.sh`.

### Long jobs (hours/days for millions of files)

Run detached so an SSH drop doesn't kill it:

```bash
# tmux
tmux new -s ftp2minio
set -a; source ./config.env; set +a
./sync.sh
# detach: Ctrl-b d   | reattach: tmux attach -t ftp2minio

# or nohup
set -a; source ./config.env; set +a
nohup ./sync.sh > logs/run.out 2>&1 &
```

Watch progress: `tail -f logs/sync-*.log`

## Tuning notes

- **`--size-only`** is used because FTP modtimes (MDTM) are often unreliable.
  A file is re-copied only if its size differs. If your FTP files can change
  *content but not size*, remove `--size-only` from `sync.sh` (slower, needs
  modtime support).
- **`FTP_CONCURRENCY`** — many FTP servers cap connections per IP. If you see
  "too many connections" errors, lower it. If the link is idle, raise it.
- **RAM** ≈ `S3_CHUNK_SIZE × S3_CONCURRENCY × TRANSFERS`. Defaults ≈ 4 GB.
  Lower `TRANSFERS` or `S3_CHUNK_SIZE` on a small host.
- **Millions of files**: FTP directory listing is the bottleneck, not bandwidth.
  Consider sharding by top-level directory and running several `sync.sh` with
  different `FTP_PATH`/`PREFIX` in parallel tmux windows.
- **Mirror instead of additive?** If you want MinIO to exactly match FTP
  (including deleting files removed from FTP), change `rclone copy` to
  `rclone sync` in `sync.sh`. ⚠️ destructive — it deletes from MinIO.

## Recurring on a schedule (optional)

systemd timer or cron on the MinIO host:

```cron
# every night at 02:00, on-demand-equivalent
0 2 * * * cd /opt/ftp-to-minio && set -a; . ./config.env; set +a; ./sync.sh >> logs/cron.log 2>&1
```
