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

RESTORE_DROP="${RESTORE_DROP:-false}"
WORK_DIR="${RESTORE_WORK_DIR:-/tmp/mongodb-restore}"
ARCHIVE_NAME="mongodb_backup.archive.gz"

is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

MASKED_URI=$(echo "${MONGODB_URI}" | sed 's|://\([^:]*\):[^@]*@|://\1:***@|')

# ─── Header ──────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
log_info "MongoDB Restore Job Started"
log_info "Timestamp  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log_info "MongoDB URI: ${MASKED_URI}"
log_info "S3 prefix  : s3://${S3_BUCKET}/${S3_PATH}/"
log_info "RESTORE_DROP: ${RESTORE_DROP}"
echo "════════════════════════════════════════════════════"

# ─── Step 1: Configure AWS CLI ───────────────────────────────────────────────
log_info "Configuring AWS credentials..."
aws configure set aws_access_key_id     "${S3_ACCESS_KEY}"
aws configure set aws_secret_access_key "${S3_SECRET_KEY}"
aws configure set default.region        "${S3_REGION}"
log_success "AWS CLI configured."

# ─── Step 2: Resolve backup timestamp folder ───────────────────────────────
if [[ -n "${RESTORE_TIMESTAMP:-}" ]]; then
    BACKUP_TS="${RESTORE_TIMESTAMP}"
    log_info "Using RESTORE_TIMESTAMP=${BACKUP_TS}"
    S3_KEY="${S3_PATH}/${BACKUP_TS}/${ARCHIVE_NAME}"
    if ! aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" \
        --endpoint-url "${S3_ENDPOINT}" &>/dev/null; then
        log_error "Object not found: s3://${S3_BUCKET}/${S3_KEY}"
        exit 1
    fi
else
    log_info "RESTORE_TIMESTAMP unset — selecting latest backup folder..."
    BACKUP_TS=$(
        aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" \
            --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
            | awk '{print $2}' \
            | grep -E '^[0-9]{8}_' \
            | sed 's|/$||' \
            | sort -r \
            | head -1
    ) || true
    if [[ -z "${BACKUP_TS}" ]]; then
        log_error "No backup folders matching YYYYMMDD_* under s3://${S3_BUCKET}/${S3_PATH}/"
        exit 1
    fi
    log_success "Latest backup folder: ${BACKUP_TS}"
    S3_KEY="${S3_PATH}/${BACKUP_TS}/${ARCHIVE_NAME}"
fi

S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

# ─── Step 3: Download archive ─────────────────────────────────────────────────
mkdir -p "${WORK_DIR}"
LOCAL_ARCHIVE="${WORK_DIR}/${ARCHIVE_NAME}"
log_info "Downloading ${S3_URI} ..."
aws s3 cp "${S3_URI}" "${LOCAL_ARCHIVE}" \
    --endpoint-url "${S3_ENDPOINT}" \
    --no-progress

ARCHIVE_SIZE=$(stat -c%s "${LOCAL_ARCHIVE}" 2>/dev/null || echo 0)
if [[ ! -s "${LOCAL_ARCHIVE}" ]] || [[ "${ARCHIVE_SIZE}" -lt 512 ]]; then
    log_error "Downloaded archive is empty or too small (${ARCHIVE_SIZE} bytes)."
    exit 1
fi
log_success "Download complete — $(du -sh "${LOCAL_ARCHIVE}" | cut -f1)"

# ─── Step 4: Wait for MongoDB (optional; image may not include mongosh) ─────
log_info "mongorestore: $(mongorestore --version 2>&1 | head -n1)"
if command -v mongosh &>/dev/null; then
    log_info "Waiting for MongoDB (mongosh ping)..."
    for i in $(seq 1 30); do
        if mongosh "${MONGODB_URI}" --eval "db.adminCommand('ping')" --quiet &>/dev/null; then
            log_success "MongoDB is reachable."
            break
        fi
        if [[ "${i}" -eq 30 ]]; then
            log_error "Cannot ping MongoDB after 30 attempts."
            exit 1
        fi
        sleep 2
    done
else
    log_warn "mongosh not installed — skipping wait loop; ensure MongoDB is up before restore."
fi

# ─── Step 5: mongorestore ───────────────────────────────────────────────────
MR_CMD=(mongorestore --uri="${MONGODB_URI}" --gzip --archive="${LOCAL_ARCHIVE}")
if is_true "${RESTORE_DROP}"; then
    MR_CMD+=(--drop)
    log_info "RESTORE_DROP=true — collections will be dropped before restore."
else
    log_info "RESTORE_DROP=false — merging into existing data (no --drop)."
fi

log_info "Starting mongorestore from archive ..."
"${MR_CMD[@]}"
log_success "mongorestore completed."

rm -rf "${WORK_DIR}"
log_success "Local temp removed."

echo "════════════════════════════════════════════════════"
log_success "MongoDB Restore completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
log_info "Source backup folder: ${BACKUP_TS}"
echo "════════════════════════════════════════════════════"
