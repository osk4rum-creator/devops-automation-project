"""StatusPulse worker.

Every few seconds it picks the monitors that are due, checks them in
parallel, records each result, and keeps every monitor's status up to date:

    2 failed checks in a row  -> status DOWN, incident opened, SNS email sent
    first success after DOWN  -> status UP,   incident resolved, SNS email sent

It receives no traffic, so it has no Kubernetes Service and is never
exposed. Kubernetes checks it via a heartbeat file instead of HTTP.
"""
import concurrent.futures
import ipaddress
import logging
import os
import pathlib
import socket
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

import boto3
import psycopg
from psycopg.rows import dict_row

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "5"))
CHECK_TIMEOUT = float(os.environ.get("CHECK_TIMEOUT_SECONDS", "10"))
FAILURES_BEFORE_DOWN = int(os.environ.get("FAILURES_BEFORE_DOWN", "2"))
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "7"))
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")
USER_AGENT = "StatusPulse/1.0 (uptime monitor)"
# Liveness probe checks this file's age. /tmp is a private emptyDir volume of
# this pod (not shared with other users or containers), so S108 doesn't apply.
HEARTBEAT = pathlib.Path("/tmp/heartbeat")  # noqa: S108

sns = boto3.client("sns", region_name=AWS_REGION) if SNS_TOPIC_ARN else None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Don't follow redirects: a redirect to an internal address would bypass
    the SSRF check. A 3xx answer still means the site is up."""

    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


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


# --- Checking a URL --------------------------------------------------------------

def resolves_to_public(host):
    """SSRF guard: every address the host resolves to must be public.
    (The API validated the URL text; this catches DNS names that point inside.)"""
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        return False, f"DNS lookup failed ({exc.strerror or exc})"
    for info in infos:
        address = ipaddress.ip_address(info[4][0])
        if not address.is_global:
            return False, f"blocked: {host} resolves to non-public address {address}"
    return True, None


def check_url(url):
    """Run one check. Returns dict(ok, status_code, response_ms, error)."""
    parsed = urlparse(url)
    # Defense in depth: the API already allows only http(s), but never let
    # urllib open file:// or other schemes even if a bad row got into the DB.
    if parsed.scheme not in ("http", "https"):
        return {"ok": False, "status_code": None, "response_ms": None, "error": "unsupported URL scheme"}
    allowed, reason = resolves_to_public(parsed.hostname or "")
    if not allowed:
        return {"ok": False, "status_code": None, "response_ms": None, "error": reason}

    request = urllib.request.Request(  # noqa: S310 - scheme restricted to http(s) just above
        url, method="GET", headers={"User-Agent": USER_AGENT})
    started = time.monotonic()
    status_code, problem = None, None
    try:
        with _opener.open(request, timeout=CHECK_TIMEOUT) as response:
            response.read(1024)
            status_code = response.status
    except urllib.error.HTTPError as exc:            # 3xx (not followed), 4xx, 5xx
        status_code = exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        problem = str(getattr(exc, "reason", exc))[:200] or exc.__class__.__name__
    elapsed_ms = int((time.monotonic() - started) * 1000)

    ok = status_code is not None and status_code < 400
    if status_code is not None and not ok:
        problem = f"HTTP {status_code}"
    return {"ok": ok, "status_code": status_code,
            "response_ms": elapsed_ms if status_code is not None else None, "error": problem}


# --- Status logic (pure function, unit-tested) --------------------------------------

def next_state(status, failures, ok, threshold=FAILURES_BEFORE_DOWN):
    """Given the current status and a new check result, return
    (new_status, new_failure_count, event) where event is None, 'down' or 'recovered'.
    Requiring `threshold` failures in a row avoids alerts for a single blip."""
    if ok:
        return "up", 0, ("recovered" if status == "down" else None)
    failures += 1
    if status == "down":
        return "down", failures, None
    if failures >= threshold:
        return "down", failures, "down"
    return status, failures, None                  # still 'up' or 'pending' for now


# --- Notifications -------------------------------------------------------------------

def notify(subject, message):
    if sns is None:
        log.info("SNS not configured, would send: %s - %s", subject, message)
        return
    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)
        log.info("sent SNS notification: %s", subject)
    except Exception as exc:  # noqa: BLE001 - an email failure must not stop monitoring
        log.error("SNS publish failed: %s", exc)


def human_duration(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {seconds}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m"


# --- Main loop -------------------------------------------------------------------------

def process_due_monitors():
    with db() as conn:
        # SKIP LOCKED: with 2+ worker replicas, each monitor is checked by one of them
        due = conn.execute(
            """SELECT id, name, url, status, consecutive_failures FROM monitors
               WHERE NOT paused
                 AND (last_checked_at IS NULL
                      OR last_checked_at < now() - make_interval(secs => interval_seconds))
               ORDER BY last_checked_at NULLS FIRST
               LIMIT 25
               FOR UPDATE SKIP LOCKED"""
        ).fetchall()
        if not due:
            return 0

        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda m: check_url(m["url"]), due))

        for monitor, result in zip(due, results, strict=True):
            conn.execute(
                "INSERT INTO checks (monitor_id, ok, status_code, response_ms, error) VALUES (%s, %s, %s, %s, %s)",
                (monitor["id"], result["ok"], result["status_code"], result["response_ms"], result["error"]),
            )
            status, failures, event = next_state(monitor["status"], monitor["consecutive_failures"], result["ok"])
            conn.execute(
                """UPDATE monitors SET
                       status = %(status)s,
                       consecutive_failures = %(failures)s,
                       last_checked_at = now(),
                       last_response_ms = %(ms)s,
                       last_error = %(error)s,
                       status_since = CASE WHEN status <> %(status)s THEN now() ELSE status_since END
                   WHERE id = %(id)s""",
                {"status": status, "failures": failures, "ms": result["response_ms"],
                 "error": result["error"], "id": monitor["id"]},
            )
            if event == "down":
                conn.execute("INSERT INTO incidents (monitor_id, cause) VALUES (%s, %s)",
                             (monitor["id"], result["error"]))
                notify(f"DOWN: {monitor['name']}",
                       f"{monitor['name']} ({monitor['url']}) is DOWN.\n"
                       f"Reason: {result['error']}\n"
                       f"Failed {failures} checks in a row.\n\n- StatusPulse")
            elif event == "recovered":
                incident = conn.execute(
                    """UPDATE incidents SET resolved_at = now()
                       WHERE monitor_id = %s AND resolved_at IS NULL
                       RETURNING extract(epoch FROM resolved_at - started_at) AS seconds""",
                    (monitor["id"],),
                ).fetchone()
                downtime = human_duration(incident["seconds"]) if incident else "unknown"
                notify(f"RECOVERED: {monitor['name']}",
                       f"{monitor['name']} ({monitor['url']}) is back UP after {downtime} of downtime.\n"
                       f"Response time: {result['response_ms']} ms\n\n- StatusPulse")
        return len(due)


def cleanup_old_checks():
    with db() as conn:
        deleted = conn.execute(
            "DELETE FROM checks WHERE checked_at < now() - make_interval(days => %s)", (RETENTION_DAYS,)
        ).rowcount
    if deleted:
        log.info("removed %d checks older than %d days", deleted, RETENTION_DAYS)


def main():
    log.info("worker started: tick %ss, timeout %ss, down after %d failures",
             POLL_SECONDS, CHECK_TIMEOUT, FAILURES_BEFORE_DOWN)
    last_cleanup = 0.0
    while True:
        try:
            checked = process_due_monitors()
            if checked:
                log.info("checked %d monitor(s)", checked)
            if time.monotonic() - last_cleanup > 3600:
                cleanup_old_checks()
                last_cleanup = time.monotonic()
        except psycopg.errors.UndefinedTable:
            log.info("tables not created yet (the backend creates them), waiting")
        except Exception as exc:  # noqa: BLE001 - keep the loop alive, log the cause
            log.error("tick failed: %s", exc)
        # Touch the heartbeat every loop: proves the loop isn't stuck.
        HEARTBEAT.touch()
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
