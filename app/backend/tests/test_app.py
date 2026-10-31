"""Unit tests for the backend API. They run without a database or AWS:
anything that would touch them is either rejected before that point or mocked."""
import pytest

from src import app as backend


@pytest.fixture
def client():
    backend.app.config["TESTING"] = True
    return backend.app.test_client()


def test_healthz_is_ok_without_database(client):
    # Liveness must not depend on the DB, or a DB outage would restart every pod
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_readyz_reports_not_ready_when_database_is_unreachable(client, monkeypatch):
    def broken_db():
        raise ConnectionError("database down")

    monkeypatch.setattr(backend, "db", broken_db)
    monkeypatch.setattr(backend, "_schema_ready", False)
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.get_json()["status"] == "not ready"


def test_create_note_rejects_empty_text(client):
    response = client.post("/api/notes", json={"text": "   "})
    assert response.status_code == 400


def test_create_note_rejects_missing_body(client):
    response = client.post("/api/notes")
    assert response.status_code == 400


def test_upload_returns_503_when_s3_is_not_configured(client, monkeypatch):
    monkeypatch.setattr(backend, "s3", None)
    response = client.post("/api/upload")
    assert response.status_code == 503
    assert "S3" in response.get_json()["error"]
