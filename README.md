# mongodb-backup

Docker image to backup MongoDB databases to S3-compatible storage (MinIO, AWS S3, DigitalOcean Spaces, Cloudflare R2, etc.).

**Features:**

- `mongodump` with gzip compression — produces a single portable archive file
- Upload to any S3-compatible storage via AWS CLI v2
- Automatic cleanup of old backups (local + remote) based on TTL, with optional minimum count of newest backups always kept
- Built-in cron scheduler via `supercronic` — no extra container needed
- Set `SCHEDULE` env to run periodically; omit to run once and exit
- One-shot **restore** from S3 with `MODE=restore` (same image as backup)
- Multi-arch: `linux/amd64` + `linux/arm64`
- Install once, run forever — no need to install anything on the host server

---

## Quickstart

### Run once (one-off backup)

```bash
docker run --rm \
  -e MONGODB_URI="mongodb://user:pass@192.168.1.100:27017/?authSource=admin" \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e S3_REGION=us-east-1 \
  -e S3_PATH=backups/mongodb \
  -e TTL_DAYS=7 \
  ghcr.io/quyendv/mongodb-backup:latest
```

### Restore once (from S3)

Restore expects the same object layout as backup: `mongodb_backup.archive.gz` under `S3_PATH/<timestamp>/`.

```bash
docker run --rm \
  -e MODE=restore \
  -e MONGODB_URI="mongodb://user:pass@192.168.1.100:27017/?authSource=admin" \
  -e RESTORE_DROP=true \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e S3_REGION=us-east-1 \
  -e S3_PATH=backups/mongodb \
  ghcr.io/quyendv/mongodb-backup:latest
```

- Set `RESTORE_TIMESTAMP=YYYYMMDD_HHMMSS` to pick a specific folder; omit to use the **latest** `YYYYMMDD_*` prefix under `S3_PATH/`.
- `RESTORE_DROP=true` passes `--drop` to `mongorestore` (drops collections before restore). Omit or set `false` to merge into existing data.

### Run on a schedule (cron mode)

```bash
docker run -d \
  -e MONGODB_URI="mongodb://user:pass@192.168.1.100:27017/?authSource=admin" \
  -e S3_ACCESS_KEY=xxx \
  -e S3_SECRET_KEY=xxx \
  -e S3_ENDPOINT=https://minio.example.com \
  -e S3_BUCKET=my-bucket \
  -e SCHEDULE="0 */4 * * *" \
  --restart unless-stopped \
  ghcr.io/quyendv/mongodb-backup:latest
```

---

## Installation on Ubuntu

### Option A — Docker Compose (recommended, single container)

```bash
# 1. Clone repo
git clone https://github.com/quyendv/mongodb-backup.git
cd mongodb-backup

# 2. Configure environment
cp .env.example .env
nano .env   # fill in your values

# 3. Set SCHEDULE in docker-compose.yml (or override via .env)

# 4. Start
docker compose up -d

# 5. Check logs
docker compose logs -f mongodb-backup
```

### Option B — Docker + System Crontab (no SCHEDULE env)

```bash
# 1. Pull image
docker pull ghcr.io/quyendv/mongodb-backup:latest

# 2. Create config directory
mkdir -p /opt/mongodb-backup
cd /opt/mongodb-backup

# 3. Create .env file
cp .env.example .env
nano .env   # fill in your values

# 4. Add to crontab (runs every 4 hours)
crontab -e
```

Add the following line to crontab:

```
0 */4 * * * docker run --rm --env-file /opt/mongodb-backup/.env -v mongodb_backup:/backup ghcr.io/quyendv/mongodb-backup:latest >> /var/log/mongodb-backup.log 2>&1
```

### Option C — Run manually (one-off)

```bash
docker compose run --rm mongodb-backup
```

---

## Environment Variables

| Variable        | Required | Default     | Description                                                         |
| --------------- | -------- | ----------- | ------------------------------------------------------------------- |
| `MONGODB_URI`   | ✅       | —           | Full MongoDB connection URI                                         |
| `S3_ACCESS_KEY` | ✅       | —           | S3 access key                                                       |
| `S3_SECRET_KEY` | ✅       | —           | S3 secret key                                                       |
| `S3_ENDPOINT`   | ✅       | —           | Endpoint URL (e.g. `https://minio.example.com`)                     |
| `S3_BUCKET`     | ✅       | —           | Bucket name                                                         |
| `S3_REGION`     | ✅       | `us-east-1` | Region                                                              |
| `S3_PATH`       | ✅       | `backups`   | Path prefix inside bucket                                           |
| `TTL_DAYS`      | ❌       | `7`         | Number of days to retain backups                                    |
| `MIN_BACKUPS`   | ❌       | `0`         | Always keep this many **newest** backups (local + S3), even past TTL |
| `BACKUP_DIR`    | ❌       | `/backup`   | Local backup directory inside container                             |
| `SCHEDULE`      | ❌       | _(empty)_   | Cron expression to run periodically. If empty, runs once and exits. |
| `MODE`          | ❌       | `backup`    | Set to `restore` to run restore instead of backup (ignores `SCHEDULE`). |

#### Restore-only variables

| Variable             | Required | Default      | Description |
| -------------------- | -------- | ------------ | ----------- |
| `RESTORE_TIMESTAMP`  | ❌       | _(latest)_   | Backup folder under `S3_PATH` (e.g. `20260305_020000`). |
| `RESTORE_DROP`       | ❌       | `false`      | If `true`, run `mongorestore --drop`. |
| `RESTORE_WORK_DIR`   | ❌       | `/tmp/mongodb-restore` | Temp path for the downloaded archive. |

### MONGODB_URI examples

| Value                                                                 | Description                    |
| --------------------------------------------------------------------- | ------------------------------ |
| `mongodb://user:pass@host:27017/?authSource=admin`                    | Single node with auth          |
| `mongodb://user:pass@host:27017/mydb?replicaSet=rs0&authSource=admin` | Replica set, specific database |
| `mongodb+srv://user:pass@cluster.mongodb.net/`                        | Atlas / DNS SRV                |

### SCHEDULE examples

| Value         | Meaning                               |
| ------------- | ------------------------------------- |
| `0 */4 * * *` | Every 4 hours                         |
| `0 2 * * *`   | Daily at 02:00 UTC                    |
| `0 2 * * 0`   | Every Sunday at 02:00 UTC             |
| `@every 6h`   | Every 6 hours (supercronic extension) |
| _(empty)_     | Run once and exit                     |

---

## Build Locally

```bash
docker build -t mongodb-backup:local .
```

---

## Kubernetes

- [`k8s/cronjob.yaml`](k8s/cronjob.yaml) — scheduled backup (no per-run tool install).
- [`k8s/restore-job.yaml`](k8s/restore-job.yaml) — example Job with `MODE=restore`.

See also [`scripts/demo-restore-job.yaml`](scripts/demo-restore-job.yaml) for a minimal Pod + Service + restore Job.

If you reuse the same image tag after each push, use `imagePullPolicy: Always` (as in the sample) so nodes pull fresh layers; otherwise Kubernetes may keep a cached image when the default is `IfNotPresent`.

```bash
# Apply to your cluster
kubectl apply -f k8s/cronjob.yaml

# Trigger a manual backup immediately
kubectl create job --from=cronjob/mongodb-backup mongodb-backup-manual -n default
```

---

## Backup Structure on S3

```
s3://BUCKET/S3_PATH/
├── 20260305_020000/
│   └── mongodb_backup.archive.gz
├── 20260305_060000/
│   └── mongodb_backup.archive.gz
└── ...
```

---

## Restore (manual / outside the image)

The image’s restore mode downloads the same archive and runs `mongorestore` with a matching Database Tools build.

```bash
aws s3 cp s3://BUCKET/S3_PATH/20260305_020000/mongodb_backup.archive.gz ./mongodb_backup.archive.gz \
    --endpoint-url https://your-endpoint.com

mongorestore \
    --uri="mongodb://user:pass@host:27017/?authSource=admin" \
    --gzip \
    --archive=mongodb_backup.archive.gz \
    --drop
```

`--drop` drops collections that exist in the archive before restoring; omit it to merge.
