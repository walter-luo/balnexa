# Balnexa Executor image (M0-A preparation; UA V1.2 §3, §9.2-§9.3; WP CORE-8, DOC-2, INT-2/3).
# One image for every job kind, run as a Cloud Run Job task: python -m bnx_exec run --kind KIND [--item ID ...].
# Contents: Python 3.12, the hash-pinned requirements, pg_dump/pg_restore 16 and 17 (PGDG), age, tesseract (eng) and the
# bnx_exec package. No credential, key or configuration is baked in: they come from the job's environment and secret mounts
# (runner.Config). The process runs as an unprivileged user with a read-only code tree and a tmpfs scratch directory.
# Building or pushing this image creates no cloud resource; deploying it is M0-A (Owner gate O-7 / M0-AUTH).
# Pinned by exact version here; M0-A pins the digest of the image it qualifies.
FROM python:3.12.8-slim-bookworm AS base

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    BNX_SCRATCH=/scratch BNX_DB_DIR=/opt/balnexa/db

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg postgresql-common tesseract-ocr tesseract-ocr-eng age; \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y; \
    apt-get install -y --no-install-recommends postgresql-client-16 postgresql-client-17; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/*

COPY apps/executor/requirements.txt /opt/balnexa/requirements.txt
RUN pip install --no-cache-dir --require-hashes --only-binary=:all: -r /opt/balnexa/requirements.txt

# repository layout (the detector finds spec/ four levels above its module, as in the repository)
COPY apps/executor/bnx_exec /opt/balnexa/apps/executor/bnx_exec
COPY spec/sin-detector /opt/balnexa/spec/sin-detector
COPY db /opt/balnexa/db

RUN useradd --system --uid 10001 --home /nonexistent --shell /usr/sbin/nologin bnx && mkdir -p /scratch && chown bnx /scratch
USER 10001
WORKDIR /opt/balnexa/apps/executor
ENTRYPOINT ["python", "-m", "bnx_exec"]
CMD ["run", "--kind", "REPORT_RENDER"]
