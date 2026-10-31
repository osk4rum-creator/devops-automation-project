"""Unit tests for the worker loop, using a fake database connection."""
from src import worker


class FakeConnection:
    """Stands in for a psycopg connection: returns given rows, records SQL."""

    def __init__(self, rows):
        self.rows = rows
        self.executed = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=None):
        self.executed.append((" ".join(sql.split()), params))
        return self

    def fetchall(self):
        return self.rows


def test_marks_each_new_upload_as_notified(monkeypatch):
    conn = FakeConnection(rows=[(1, "a.txt", "uploads/a.txt"), (2, "b.txt", "uploads/b.txt")])
    monkeypatch.setattr(worker, "db", lambda: conn)
    monkeypatch.setattr(worker, "sns", None)

    worker.process_new_uploads()

    updates = [params for sql, params in conn.executed if sql.startswith("UPDATE uploads")]
    assert updates == [(1,), (2,)]


def test_publishes_to_sns_when_configured(monkeypatch):
    sent = []

    class FakeSNS:
        def publish(self, **kwargs):
            sent.append(kwargs)

    conn = FakeConnection(rows=[(7, "report.pdf", "uploads/report.pdf")])
    monkeypatch.setattr(worker, "db", lambda: conn)
    monkeypatch.setattr(worker, "sns", FakeSNS())
    monkeypatch.setattr(worker, "SNS_TOPIC_ARN", "arn:aws:sns:eu-central-1:123456789012:test")

    worker.process_new_uploads()

    assert len(sent) == 1
    assert "report.pdf" in sent[0]["Message"]
    assert sent[0]["TopicArn"].endswith(":test")


def test_does_nothing_when_there_are_no_new_uploads(monkeypatch):
    conn = FakeConnection(rows=[])
    monkeypatch.setattr(worker, "db", lambda: conn)

    worker.process_new_uploads()

    assert not any(sql.startswith("UPDATE") for sql, _ in conn.executed)
