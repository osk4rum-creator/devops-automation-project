"""Unit tests for the StatusPulse API. They run without a database or AWS:
anything that would touch them is either rejected before that point or mocked."""
import pytest

from src import app as backend


@pytest.fixture
def client():
    backend.app.config["TESTING"] = True
    return backend.app.test_client()


# --- Probes / meta ---------------------------------------------------------------

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


def test_version_reports_image_tag_and_pod(client, monkeypatch):
    monkeypatch.setattr(backend, "APP_VERSION", "abc1234")
    monkeypatch.setattr(backend, "POD_NAME", "backend-xyz")
    assert client.get("/api/version").get_json()["version"] == "abc1234"


# --- URL validation (SSRF protection) ----------------------------------------------

@pytest.mark.parametrize("url", [
    "https://github.com",
    "http://example.com/health?x=1",
    "https://8.8.8.8",                          # public IP literal is fine
])
def test_public_urls_are_accepted(url):
    clean, problem = backend.validate_url(url)
    assert problem is None and clean == url


@pytest.mark.parametrize("url, reason_part", [
    ("ftp://example.com", "http"),
    ("file:///etc/passwd", "http"),
    ("https://localhost:8080", "internal"),
    ("http://backend:8000", "internal"),         # Kubernetes service short name
    ("http://postgres.devops-app.svc.cluster.local:5432", "internal"),
    ("http://10.43.0.10", "private"),            # cluster IP range
    ("http://192.168.1.1", "private"),
    ("http://127.0.0.1", "private"),
    ("http://169.254.169.254/latest/meta-data", "private"),   # cloud metadata endpoint
    ("http://[::1]/", "private"),
    ("https://user:pass@example.com", "credentials"),
    ("", "required"),
])
def test_internal_and_unsafe_urls_are_rejected(url, reason_part):
    clean, problem = backend.validate_url(url)
    assert clean is None
    assert reason_part in problem


def test_monitor_validation_checks_name_and_interval():
    assert backend.validate_monitor({"name": "", "url": "https://github.com"})[1]
    assert backend.validate_monitor({"name": "x" * 61, "url": "https://github.com"})[1]
    assert backend.validate_monitor({"name": "ok", "url": "https://github.com", "interval_seconds": 5})[1]
    assert backend.validate_monitor({"name": "ok", "url": "https://github.com", "interval_seconds": "abc"})[1]
    clean, problem = backend.validate_monitor({"name": " GitHub ", "url": "https://github.com"})
    assert problem is None
    assert clean == {"name": "GitHub", "url": "https://github.com", "interval_seconds": 60}


# --- API behaviour without a database ------------------------------------------------

def test_create_monitor_rejects_invalid_input_before_touching_the_database(client, monkeypatch):
    def no_db():
        raise AssertionError("database must not be used for invalid input")

    monkeypatch.setattr(backend, "db", no_db)
    response = client.post("/api/monitors", json={"name": "evil", "url": "http://169.254.169.254"})
    assert response.status_code == 400
    assert "private" in response.get_json()["error"]


def test_create_monitor_requires_json(client):
    assert client.post("/api/monitors").status_code == 400


def test_report_returns_503_when_s3_is_not_configured(client, monkeypatch):
    monkeypatch.setattr(backend, "s3", None)
    response = client.post("/api/reports")
    assert response.status_code == 503
    assert "S3" in response.get_json()["error"]


def test_unknown_api_route_returns_json_404(client):
    response = client.get("/api/does-not-exist")
    assert response.status_code == 404
    assert response.get_json() == {"error": "not found"}


# --- Read-only demo mode ----------------------------------------------------------------

@pytest.fixture
def read_only(monkeypatch):
    monkeypatch.setattr(backend, "ADMIN_TOKEN", "s3cret-admin-token")

    def no_db():
        raise AssertionError("database must not be reached without a valid token")

    monkeypatch.setattr(backend, "db", no_db)


@pytest.mark.parametrize("method, path", [
    ("post", "/api/monitors"),
    ("delete", "/api/monitors/1"),
    ("post", "/api/monitors/1/pause"),
    ("post", "/api/reports"),
])
def test_changes_are_rejected_without_token(client, read_only, method, path):
    response = getattr(client, method)(path, json={"name": "x", "url": "https://github.com"})
    assert response.status_code == 401
    assert "read-only" in response.get_json()["error"]


def test_wrong_token_is_rejected(client, read_only):
    response = client.post("/api/monitors", json={"name": "x", "url": "https://github.com"},
                           headers={"Authorization": "Bearer wrong-token"})
    assert response.status_code == 401


def test_correct_token_unlocks(client, read_only):
    ok = client.get("/api/auth/check", headers={"Authorization": "Bearer s3cret-admin-token"})
    assert ok.status_code == 200
    assert client.get("/api/auth/check").status_code == 401


def test_version_tells_the_dashboard_it_is_read_only(client, read_only):
    assert client.get("/api/version").get_json()["read_only"] is True
