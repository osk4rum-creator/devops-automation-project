# Pinned base image (never :latest)
FROM python:3.12.16-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001

CMD ["python", "-m", "src.worker"]
