"""StatusPulse API.

Manages uptime monitors, serves check history, uptime statistics and
incidents to the dashboard, and exports CSV reports to S3. The worker service
does the actual checking and sends the alert emails.

All configuration comes from environment variables, which Kubernetes fills
from a ConfigMap (non-sensitive) and Secrets (DB password, AWS keys).
"""
import csv
import functools
import hmac
import io
import ipaddress
import logging
import os
import socket
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlparse

import boto3
import psycopg
from botocore.config import Config
from flask import Flask, jsonify, request
from psycopg.rows import dict_row

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("backend")

app = Flask(__name__)

S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")
APP_VERSION = os.environ.get("APP_VERSION", "dev")          # image tag, set by Helm
POD_NAME = os.environ.get("POD_NAME", socket.gethostname())  # which replica answered
SEED_DEMO = os.environ.get("SEED_DEMO", "false").lower() == "true"
# Read-only demo mode: when ADMIN_TOKEN is set (from a Kubernetes Secret), every
# change - add / pause / delete monitors, export reports - needs that token.
# Visitors through the public Cloudflare Tunnel can look, but not change anything.
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")

MAX_MONITORS = 50
MIN_INTERVAL, MAX_INTERVAL, DEFAULT_INTERVAL = 30, 3600, 60
REPORT_LINK_SECONDS = 3600

# boto3 finds credentials automatically: env vars locally, IRSA on EKS.
s3 = (
    boto3.client("s3", region_name=AWS_REGION,
                 config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}))
    if S3_BUCKET else None
)

DEMO_MONITORS = [
    ("GitHub", "https://github.com", 60),
    ("Google", "https://www.google.com", 60),
    ("Cloudflare", "https://www.cloudflare.com", 120),
    ("Broken demo site", "https://statuspulse-demo.invalid", 60),   # .invalid never resolves
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS monitors (
    id                   SERIAL PRIMARY KEY,
    name                 TEXT NOT NULL,
    url                  TEXT NOT NULL,
    interval_seconds     INTEGER NOT NULL DEFAULT 60,
    paused               BOOLEAN NOT NULL DEFAULT false,
    status               TEXT NOT NULL DEFAULT 'pending',   -- pending | up | down
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    last_checked_at      TIMESTAMPTZ,
    last_response_ms     INTEGER,
    last_error           TEXT,
    status_since         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS checks (
    id          BIGSERIAL PRIMARY KEY,
    monitor_id  INTEGER NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
    checked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ok          BOOLEAN NOT NULL,
    status_code INTEGER,
    response_ms INTEGER,
    error       TEXT
);
CREATE INDEX IF NOT EXISTS checks_monitor_time ON checks (monitor_id, checked_at DESC);
CREATE TABLE IF NOT EXISTS incidents (
    id          SERIAL PRIMARY KEY,
    monitor_id  INTEGER NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    cause       TEXT
);
CREATE TABLE IF NOT EXISTS reports (
    id         SERIAL PRIMARY KEY,
    s3_key     TEXT NOT NULL,
    monitors   INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

_schema_ready = False


def db():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=3,
        row_factory=dict_row,
    )


def ensure_schema():
    """Create tables once. Called from the readiness probe, so traffic only
    arrives after the database is reachable and the schema exists."""
    global _schema_ready
    if _schema_ready:
        return
    with db() as conn:
        # Two backend replicas start at the same time: a transaction-level
        # advisory lock makes them create the schema one after the other.
        conn.execute("SELECT pg_advisory_xact_lock(4242)")
        conn.execute(SCHEMA)
        if SEED_DEMO and conn.execute("SELECT count(*) AS n FROM monitors").fetchone()["n"] == 0:
            for name, url, interval in DEMO_MONITORS:
                conn.execute("INSERT INTO monitors (name, url, interval_seconds) VALUES (%s, %s, %s)",
                             (name, url, interval))
            log.info("seeded %d demo monitors", len(DEMO_MONITORS))
    _schema_ready = True
    log.info("database schema ready")


# --- Validation ----------------------------------------------------------------

BLOCKED_HOST_SUFFIXES = (".local", ".internal", ".localhost", ".svc", ".cluster.local")


def validate_url(raw):
    """Return (url, None) if the URL may be monitored, else (None, reason).

    SSRF protection: the worker fetches these URLs from INSIDE the cluster, so
    a user must not be able to point it at internal services (the database,
    the Kubernetes API, cloud metadata at 169.254.169.254, ...). The worker
    re-checks the resolved IP before every request, and NetworkPolicies block
    private ranges at the network level as a third layer.
    """
    url = (raw or "").strip()
    if not url:
        return None, "URL is required"
    if len(url) > 2048:
        return None, "URL is too long"
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return None, "only http:// and https:// URLs can be monitored"
    host = (parsed.hostname or "").lower().rstrip(".")
    if not host:
        return None, "URL has no host name"
    if parsed.username or parsed.password:
        return None, "URLs with credentials are not allowed"
    try:
        ip = ipaddress.ip_address(host)      # IP literal, e.g. 10.0.0.1 or ::1
    except ValueError:
        ip = None
    if ip is not None:
        if not ip.is_global:
            return None, "private, loopback and link-local addresses are not allowed"
        return url, None
    if host == "localhost" or host.endswith(BLOCKED_HOST_SUFFIXES) or "." not in host:
        return None, "internal host names are not allowed"
    return url, None                         # a DNS name: the worker checks what it resolves to


def validate_monitor(payload):
    """Return (clean_dict, None) or (None, error_message)."""
    if not isinstance(payload, dict):
        return None, "JSON body required"
    name = str(payload.get("name", "")).strip()
    if not 1 <= len(name) <= 60:
        return None, "name must be 1-60 characters"
    url, error = validate_url(payload.get("url"))
    if error:
        return None, error
    try:
        interval = int(payload.get("interval_seconds", DEFAULT_INTERVAL))
    except (TypeError, ValueError):
        return None, "interval_seconds must be a number"
    if not MIN_INTERVAL <= interval <= MAX_INTERVAL:
        return None, f"interval_seconds must be between {MIN_INTERVAL} and {MAX_INTERVAL}"
    return {"name": name, "url": url, "interval_seconds": interval}, None


# --- Helpers -------------------------------------------------------------------

def to_json(row):
    """dict row -> JSON-friendly dict (ISO timestamps, floats rounded)."""
    out = {}
    for key, value in row.items():
        if isinstance(value, datetime):
            out[key] = value.isoformat()
        elif isinstance(value, (float, Decimal)):   # Postgres avg() returns exact Decimals
            out[key] = round(float(value), 2)
        else:
            out[key] = value
    return out


def presign(key):
    return s3.generate_presigned_url(
        "get_object", Params={"Bucket": S3_BUCKET, "Key": key}, ExpiresIn=REPORT_LINK_SECONDS)


def error(message, status):
    return jsonify({"error": message}), status


def is_admin():
    """True if no token is configured (open mode) or the request carries it."""
    if not ADMIN_TOKEN:
        return True
    header = request.headers.get("Authorization", "")
    supplied = header[7:] if header.startswith("Bearer ") else ""
    # Constant-time comparison: response time doesn't leak how much of the token matched
    return hmac.compare_digest(supplied.encode(), ADMIN_TOKEN.encode())


def admin_required(view):
    @functools.wraps(view)
    def wrapper(*args, **kwargs):
        if not is_admin():
            return error("read-only demo: unlock with the admin token to make changes", 401)
        return view(*args, **kwargs)
    return wrapper


# --- Probes --------------------------------------------------------------------

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


@app.get("/api/health")
def api_health():
    """Same as readiness, reachable through nginx (used by the CD smoke test)."""
    return readyz()


@app.get("/api/version")
def version():
    """Which version and which pod answered - shows rolling updates live."""
    return {"version": APP_VERSION, "pod": POD_NAME, "s3_enabled": s3 is not None,
            "read_only": bool(ADMIN_TOKEN)}


@app.get("/api/auth/check")
def auth_check():
    """Lets the dashboard verify a token before switching to admin mode."""
    if not is_admin():
        return error("invalid admin token", 401)
    return {"admin": True}


# --- Dashboard data ----------------------------------------------------------------

@app.get("/api/summary")
def summary():
    with db() as conn:
        counts = conn.execute(
            """SELECT count(*) FILTER (WHERE NOT paused AND status = 'up')      AS up,
                      count(*) FILTER (WHERE NOT paused AND status = 'down')    AS down,
                      count(*) FILTER (WHERE NOT paused AND status = 'pending') AS pending,
                      count(*) FILTER (WHERE paused)                            AS paused,
                      count(*)                                                  AS total
               FROM monitors"""
        ).fetchone()
        stats = conn.execute(
            """SELECT avg(ok::int) * 100                       AS uptime_24h,
                      avg(response_ms) FILTER (WHERE ok)       AS avg_response_ms,
                      count(*)                                 AS checks_24h
               FROM checks WHERE checked_at > now() - interval '24 hours'"""
        ).fetchone()
        open_incidents = conn.execute(
            "SELECT count(*) AS n FROM incidents WHERE resolved_at IS NULL").fetchone()["n"]
    return jsonify(to_json({**counts, **stats, "open_incidents": open_incidents}))


@app.get("/api/monitors")
def list_monitors():
    with db() as conn:
        monitors = conn.execute(
            """SELECT m.*, s.uptime_24h, s.avg_response_ms
               FROM monitors m
               LEFT JOIN LATERAL (
                   SELECT avg(ok::int) * 100 AS uptime_24h,
                          avg(response_ms) FILTER (WHERE ok) AS avg_response_ms
                   FROM checks c
                   WHERE c.monitor_id = m.id AND c.checked_at > now() - interval '24 hours'
               ) s ON true
               ORDER BY m.created_at"""
        ).fetchall()
        # Last 30 checks per monitor for the sparklines
        recent = conn.execute(
            """SELECT monitor_id, ok, response_ms FROM (
                   SELECT monitor_id, ok, response_ms, checked_at,
                          row_number() OVER (PARTITION BY monitor_id ORDER BY checked_at DESC) AS rn
                   FROM checks WHERE checked_at > now() - interval '24 hours'
               ) t WHERE rn <= 30 ORDER BY monitor_id, checked_at"""
        ).fetchall()
    spark = {}
    for r in recent:
        spark.setdefault(r["monitor_id"], []).append({"ok": r["ok"], "ms": r["response_ms"]})
    return jsonify([{**to_json(m), "spark": spark.get(m["id"], [])} for m in monitors])


@app.post("/api/monitors")
@admin_required
def create_monitor():
    clean, problem = validate_monitor(request.get_json(silent=True))
    if problem:
        return error(problem, 400)
    with db() as conn:
        if conn.execute("SELECT count(*) AS n FROM monitors").fetchone()["n"] >= MAX_MONITORS:
            return error(f"limit of {MAX_MONITORS} monitors reached", 409)
        row = conn.execute(
            "INSERT INTO monitors (name, url, interval_seconds) VALUES (%s, %s, %s) RETURNING *",
            (clean["name"], clean["url"], clean["interval_seconds"]),
        ).fetchone()
    log.info("created monitor %s (%s)", row["id"], row["url"])
    return jsonify(to_json(row)), 201


@app.get("/api/monitors/<int:monitor_id>")
def get_monitor(monitor_id):
    with db() as conn:
        monitor = conn.execute("SELECT * FROM monitors WHERE id = %s", (monitor_id,)).fetchone()
        if monitor is None:
            return error("monitor not found", 404)
        checks = conn.execute(
            """SELECT checked_at, ok, status_code, response_ms, error FROM checks
               WHERE monitor_id = %s ORDER BY checked_at DESC LIMIT 60""", (monitor_id,)
        ).fetchall()
        incidents = conn.execute(
            """SELECT id, started_at, resolved_at, cause FROM incidents
               WHERE monitor_id = %s ORDER BY started_at DESC LIMIT 10""", (monitor_id,)
        ).fetchall()
    return jsonify({**to_json(monitor),
                    "checks": [to_json(c) for c in checks],
                    "incidents": [to_json(i) for i in incidents]})


@app.delete("/api/monitors/<int:monitor_id>")
@admin_required
def delete_monitor(monitor_id):
    with db() as conn:
        deleted = conn.execute("DELETE FROM monitors WHERE id = %s RETURNING id", (monitor_id,)).fetchone()
    if deleted is None:
        return error("monitor not found", 404)
    log.info("deleted monitor %s", monitor_id)
    return "", 204


@app.post("/api/monitors/<int:monitor_id>/<action>")
@admin_required
def pause_resume(monitor_id, action):
    if action not in ("pause", "resume"):
        return error("unknown action", 404)
    with db() as conn:
        row = conn.execute(
            "UPDATE monitors SET paused = %s WHERE id = %s RETURNING *",
            (action == "pause", monitor_id),
        ).fetchone()
    if row is None:
        return error("monitor not found", 404)
    return jsonify(to_json(row))


@app.get("/api/incidents")
def list_incidents():
    with db() as conn:
        rows = conn.execute(
            """SELECT i.id, i.monitor_id, m.name AS monitor_name, i.started_at, i.resolved_at, i.cause
               FROM incidents i JOIN monitors m ON m.id = i.monitor_id
               ORDER BY i.started_at DESC LIMIT 20"""
        ).fetchall()
    return jsonify([to_json(r) for r in rows])


# --- Reports (S3) ------------------------------------------------------------------

@app.get("/api/reports")
def list_reports():
    if s3 is None:
        return jsonify({"enabled": False, "reports": []})
    with db() as conn:
        rows = conn.execute("SELECT * FROM reports ORDER BY created_at DESC LIMIT 10").fetchall()
    return jsonify({"enabled": True,
                    "reports": [{**to_json(r), "url": presign(r["s3_key"])} for r in rows]})


@app.post("/api/reports")
@admin_required
def create_report():
    """Build a 24h uptime report as CSV, store it in S3, return a download link
    that expires after an hour (the bucket itself stays private)."""
    if s3 is None:
        return error("S3 is not configured (S3_BUCKET is empty)", 503)
    with db() as conn:
        rows = conn.execute(
            """SELECT m.name, m.url, m.status, m.paused,
                      round((avg(c.ok::int) * 100)::numeric, 2)            AS uptime_24h,
                      round(avg(c.response_ms) FILTER (WHERE c.ok))        AS avg_response_ms,
                      count(c.id)                                          AS checks_24h,
                      (SELECT count(*) FROM incidents i WHERE i.monitor_id = m.id
                         AND i.started_at > now() - interval '24 hours')   AS incidents_24h
               FROM monitors m
               LEFT JOIN checks c ON c.monitor_id = m.id AND c.checked_at > now() - interval '24 hours'
               GROUP BY m.id ORDER BY m.name"""
        ).fetchall()
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(["monitor", "url", "status", "paused", "uptime_24h_percent",
                         "avg_response_ms", "checks_24h", "incidents_24h"])
        for r in rows:
            writer.writerow([r["name"], r["url"], r["status"], r["paused"], r["uptime_24h"],
                             r["avg_response_ms"], r["checks_24h"], r["incidents_24h"]])
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        key = f"uploads/reports/statuspulse-{stamp}-{uuid.uuid4().hex[:8]}.csv"
        s3.put_object(Bucket=S3_BUCKET, Key=key, Body=buffer.getvalue().encode(),
                      ContentType="text/csv", ContentDisposition=f'attachment; filename="{key.rsplit("/", 1)[1]}"')
        report = conn.execute("INSERT INTO reports (s3_key, monitors) VALUES (%s, %s) RETURNING *",
                              (key, len(rows))).fetchone()
    log.info("report uploaded to s3://%s/%s", S3_BUCKET, key)
    return jsonify({**to_json(report), "url": presign(key)}), 201


@app.errorhandler(404)
def not_found(_):
    return error("not found", 404)
