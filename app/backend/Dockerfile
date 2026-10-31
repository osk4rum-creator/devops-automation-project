# Pinned base image (never :latest) - "slim" keeps the image small
FROM python:3.12.16-slim

# Links the image in the registry (GHCR) back to this repository (traceability)
LABEL org.opencontainers.image.source="https://github.com/osk4rum-creator/devops-automation-project"

# No .pyc files (root filesystem is read-only in Kubernetes), unbuffered logs
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first: Docker caches this layer until requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# Run as an unprivileged user; UID matches runAsUser in the Helm chart
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001

EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--worker-tmp-dir", "/tmp", "--access-logfile", "-", "src.app:app"]
