# ─── Versions ──────────────────────────────────────────────
ARG DBTOOLS_VERSION=100.14.1
ARG SUPERCRONIC_VERSION=0.2.29

# ── Stage 1: Download and install AWS CLI ────────────────────────────────────
FROM debian:bookworm-slim AS aws-installer

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    fi && \
    curl -fsSL "$AWS_URL" -o awscliv2.zip && \
    unzip -q awscliv2.zip && \
    ./aws/install --install-dir /aws-cli-bin --bin-dir /aws-cli-bin/bin && \
    rm -rf awscliv2.zip aws/

# ── Stage 2: Download supercronic ────────────────────────────────────────────
FROM debian:bookworm-slim AS supercronic-installer

ARG SUPERCRONIC_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        SC_URL="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-arm64"; \
    else \
        SC_URL="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    fi && \
    curl -fsSL "$SC_URL" -o /usr/local/bin/supercronic && \
    chmod +x /usr/local/bin/supercronic

# ── Stage 3: Final image ──────────────────────────────────────────────────────
FROM debian:bookworm-slim

ARG DBTOOLS_VERSION
LABEL org.opencontainers.image.title="mongodb-backup"
LABEL org.opencontainers.image.description="MongoDB backup to S3-compatible storage"
LABEL org.opencontainers.image.source="https://github.com/quyendv/mongodb-backup"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gzip \
    findutils \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# MongoDB Database Tools: x86_64 = official repo + apt (per https://www.mongodb.com/docs/v8.0/tutorial/install-mongodb-on-debian/); aarch64 = tarball (Debian repo only supports x86_64).
RUN set -eux; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
    x86_64) \
        curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg; \
        echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" > /etc/apt/sources.list.d/mongodb-org-8.0.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends mongodb-org-tools; \
        ;; \
    aarch64) \
        curl -fsSL "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2204-arm64-${DBTOOLS_VERSION}.tgz" | tar xz -C /tmp; \
        cp /tmp/mongodb-database-tools-*/bin/* /usr/local/bin/; \
        rm -rf /tmp/mongodb-database-tools-*; \
        ;; \
    *) echo "Unsupported ARCH: $ARCH"; exit 1 ;; \
    esac; \
    rm -rf /var/lib/apt/lists/*

COPY --from=aws-installer /aws-cli-bin /aws-cli-bin
ENV PATH="/aws-cli-bin/bin:$PATH"

COPY --from=supercronic-installer /usr/local/bin/supercronic /usr/local/bin/supercronic

COPY scripts/backup.sh /usr/local/bin/backup.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r//' /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENV MONGODB_URI=""
ENV S3_ACCESS_KEY=""
ENV S3_SECRET_KEY=""
ENV S3_ENDPOINT=""
ENV S3_BUCKET=""
ENV S3_REGION="us-east-1"
ENV S3_PATH="backups"
ENV TTL_DAYS="7"
ENV BACKUP_DIR="/backup"
ENV SCHEDULE=""

RUN mkdir -p /backup
VOLUME ["/backup"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
