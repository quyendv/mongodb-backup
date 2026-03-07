#!/bin/bash
set -euo pipefail

# ─── Color output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Validate required env vars ──────────────────────────────────────────────
REQUIRED_VARS=(
    MONGODB_URI
    S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET S3_REGION S3_PATH
)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required environment variable '$var' is not set."
        exit 1
    fi
done

TTL_DAYS="${TTL_DAYS:-7}"
BACKUP_BASE_DIR="${BACKUP_DIR:-/backup}"

# Mask password in URI for display: mongodb://user:PASS@host → mongodb://user:***@host
MASKED_URI=$(echo "${MONGODB_URI}" | sed 's|://\([^:]*\):[^@]*@|://\1:***@|')

# ─── Header ──────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
log_info "MongoDB Backup Job Started"
log_info "Timestamp  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log_info "MongoDB URI: ${MASKED_URI}"
log_info "S3 Target  : s3://${S3_BUCKET}/${S3_PATH}"
log_info "TTL        : ${TTL_DAYS} days"
echo "════════════════════════════════════════════════════"

# ─── Step 1: Configure AWS CLI ───────────────────────────────────────────────
log_info "Configuring AWS credentials..."
aws configure set aws_access_key_id     "${S3_ACCESS_KEY}"
aws configure set aws_secret_access_key "${S3_SECRET_KEY}"
aws configure set default.region        "${S3_REGION}"
log_success "AWS CLI configured."

# ─── Step 2: Run mongodump ────────────────────────────────────────────────────
log_info "mongodump version: $(mongodump --version | head -1)"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_FILE="${BACKUP_BASE_DIR}/mongodb_${TIMESTAMP}.archive.gz"

mkdir -p "${BACKUP_BASE_DIR}"
log_info "Starting mongodump → ${ARCHIVE_FILE}"

mongodump \
    --uri="${MONGODB_URI}" \
    --gzip \
    --archive="${ARCHIVE_FILE}"

BACKUP_SIZE=$(stat -c%s "${ARCHIVE_FILE}" 2>/dev/null || echo 0)
if [[ ! -s "${ARCHIVE_FILE}" ]] || [[ "${BACKUP_SIZE}" -lt 512 ]]; then
    log_error "Backup archive is empty or too small (${BACKUP_SIZE} bytes). Aborting."
    exit 1
fi

log_success "Backup completed — Size: $(du -sh "${ARCHIVE_FILE}" | cut -f1)"

# ─── Step 3: Upload to S3 ────────────────────────────────────────────────────
S3_KEY="${S3_PATH}/${TIMESTAMP}/mongodb_backup.archive.gz"
log_info "Uploading to s3://${S3_BUCKET}/${S3_KEY} ..."

aws s3 cp "${ARCHIVE_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" \
    --endpoint-url "${S3_ENDPOINT}" \
    --no-progress

log_success "Upload complete."

# ─── Step 4: Cleanup local files older than TTL_DAYS ─────────────────────────
log_info "Cleaning local backups older than ${TTL_DAYS} days..."
find "${BACKUP_BASE_DIR}" -type f -name "*.archive.gz" -mtime "+${TTL_DAYS}" -delete
log_success "Local cleanup done."

# ─── Step 5: Cleanup remote files older than TTL_DAYS ────────────────────────
log_info "Cleaning remote backups older than ${TTL_DAYS} days..."
CUTOFF_DATE=$(date -d "${TTL_DAYS} days ago" +%Y%m%d)
log_info "Cutoff date: ${CUTOFF_DATE}"

aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" \
    --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $2}' \
    | grep -E '^[0-9]{8}_' \
    | while IFS= read -r folder; do
        FOLDER_DATE=$(echo "${folder}" | cut -d'_' -f1)
        if [[ "${FOLDER_DATE}" < "${CUTOFF_DATE}" ]]; then
            log_warn "Removing old remote backup: ${folder}"
            aws s3 rm "s3://${S3_BUCKET}/${S3_PATH}/${folder}" \
                --recursive \
                --endpoint-url "${S3_ENDPOINT}"
        fi
    done

log_success "Remote cleanup done."

# ─── Done ────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
log_success "MongoDB Backup Job Completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "════════════════════════════════════════════════════"
