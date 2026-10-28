"""Backend API: stores notes in PostgreSQL and uploads files to S3.

All configuration comes from environment variables, which Kubernetes fills
from a ConfigMap (non-sensitive) and Secrets (DB password, AWS keys).
"""
import logging
import os
import uuid

import boto3
import psycopg
from flask import Flask, jsonify, request
from werkzeug.utils import secure_filename

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("backend")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024  # 10 MB upload limit

S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")

# boto3 finds credentials automatically: env vars locally, IRSA on EKS.
s3 = boto3.client("s3", region_name=AWS_REGION) if S3_BUCKET else None

_schema_ready = False


def db():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=3,
    )


def ensure_schema():
    """Create tables once; called from the readiness probe so traffic only
    arrives after the database is reachable and the schema exists."""
    global _schema_ready
    if _schema_ready:
        return
    with db() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS notes (
                   id SERIAL PRIMARY KEY,
                   text TEXT NOT NULL,
                   created_at TIMESTAMPTZ NOT NULL DEFAULT now())"""
        )
        conn.execute(
            """CREATE TABLE IF NOT EXISTS uploads (
                   id SERIAL PRIMARY KEY,
                   filename TEXT NOT NULL,
                   s3_key TEXT NOT NULL,
                   notified BOOLEAN NOT NULL DEFAULT false,
                   created_at TIMESTAMPTZ NOT NULL DEFAULT now())"""
        )
    _schema_ready = True
    log.info("database schema ready")


# --- Probes -----------------------------------------------------------------

@app.get("/healthz")
def healthz():
    """Liveness: the process is up. Deliberately does NOT check the DB, so a
    database outage doesn't make Kubernetes restart healthy pods in a loop."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    """Readiness: only accept traffic when the database works."""
    try:
        ensure_schema()
        with db() as conn:
            conn.execute("SELECT 1")
        return {"status": "ready"}
    except Exception as exc:  # noqa: BLE001 - report any DB failure as not ready
        log.warning("not ready: %s", exc)
        return {"status": "not ready", "error": str(exc)}, 503


# --- API ----------------------------------------------------------------------

@app.get("/api/health")
def api_health():
    """Same as readiness, but reachable through nginx for end-to-end checks."""
    return readyz()


@app.get("/api/notes")
def list_notes():
    with db() as conn:
        rows = conn.execute(
            "SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT 50"
        ).fetchall()
    return jsonify([{"id": r[0], "text": r[1], "created_at": r[2].isoformat()} for r in rows])


@app.post("/api/notes")
def create_note():
    text = (request.get_json(silent=True) or {}).get("text", "").strip()
    if not text:
        return {"error": "text is required"}, 400
    with db() as conn:
        note_id = conn.execute(
            "INSERT INTO notes (text) VALUES (%s) RETURNING id", (text,)
        ).fetchone()[0]
    log.info("created note %s", note_id)
    return {"id": note_id, "text": text}, 201


@app.get("/api/uploads")
def list_uploads():
    with db() as conn:
        rows = conn.execute(
            "SELECT id, filename, s3_key, notified, created_at FROM uploads ORDER BY id DESC LIMIT 50"
        ).fetchall()
    return jsonify([
        {"id": r[0], "filename": r[1], "s3_key": r[2], "notified": r[3], "created_at": r[4].isoformat()}
        for r in rows
    ])


@app.post("/api/upload")
def upload_file():
    if s3 is None:
        return {"error": "S3 is not configured (S3_BUCKET is empty)"}, 503
    file = request.files.get("file")
    if file is None or not file.filename:
        return {"error": "file is required"}, 400

    filename = secure_filename(file.filename)
    key = f"uploads/{uuid.uuid4()}-{filename}"
    s3.upload_fileobj(file, S3_BUCKET, key)

    # The worker picks up rows with notified=false and sends the SNS email.
    with db() as conn:
        upload_id = conn.execute(
            "INSERT INTO uploads (filename, s3_key) VALUES (%s, %s) RETURNING id", (filename, key)
        ).fetchone()[0]
    log.info("uploaded %s to s3://%s/%s", filename, S3_BUCKET, key)
    return {"id": upload_id, "filename": filename, "s3_key": key}, 201
