"""Worker: finds new uploads in the database and sends an SNS email for each.

It has no HTTP server and receives no traffic, so it gets no Kubernetes
Service and is never exposed. Kubernetes checks it via a heartbeat file.
"""
import logging
import os
import pathlib
import time

import boto3
import psycopg

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("worker")

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "10"))
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")
# Liveness probe checks this file's age. /tmp is a private emptyDir volume of
# this pod (not shared with other users or containers), so S108 doesn't apply.
HEARTBEAT = pathlib.Path("/tmp/heartbeat")  # noqa: S108

sns = boto3.client("sns", region_name=AWS_REGION) if SNS_TOPIC_ARN else None


def db():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=3,
    )


def process_new_uploads():
    with db() as conn:
        # SKIP LOCKED: if you run 2+ worker replicas, each row is handled once
        rows = conn.execute(
            """SELECT id, filename, s3_key FROM uploads
               WHERE notified = false ORDER BY id LIMIT 10
               FOR UPDATE SKIP LOCKED"""
        ).fetchall()
        for upload_id, filename, key in rows:
            message = f"New file uploaded: {filename} (s3://{S3_BUCKET}/{key})"
            if sns:
                sns.publish(TopicArn=SNS_TOPIC_ARN, Subject="New upload", Message=message)
                log.info("sent SNS notification for upload %s", upload_id)
            else:
                log.info("SNS not configured, would send: %s", message)
            conn.execute("UPDATE uploads SET notified = true WHERE id = %s", (upload_id,))


def main():
    log.info("worker started, polling every %ss", POLL_SECONDS)
    while True:
        try:
            process_new_uploads()
        except psycopg.errors.UndefinedTable:
            log.info("uploads table not created yet (backend creates it), waiting")
        except Exception as exc:  # noqa: BLE001 - keep the loop alive, log the cause
            log.error("poll failed: %s", exc)
        # Touch the heartbeat every loop: proves the loop isn't stuck.
        HEARTBEAT.touch()
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
