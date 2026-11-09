"""Unit tests for the worker: status transitions, SSRF guard and URL checks.
No network or database is used - DNS and HTTP are replaced by fakes."""
import io
import socket
import urllib.error

import pytest

from src import worker

# --- Status transitions ---------------------------------------------------------------

@pytest.mark.parametrize("status, failures, ok, expected", [
    ("pending", 0, True, ("up", 0, None)),          # first success
    ("up", 0, False, ("up", 1, None)),              # one blip: no alert yet
    ("up", 1, False, ("down", 2, "down")),          # second failure in a row -> DOWN alert
    ("down", 2, False, ("down", 3, None)),          # still down: no repeated alert
    ("down", 5, True, ("up", 0, "recovered")),      # back up -> RECOVERED alert
    ("up", 1, True, ("up", 0, None)),               # success resets the failure count
    ("pending", 1, False, ("down", 2, "down")),     # a new monitor that never worked
])
def test_next_state(status, failures, ok, expected):
    assert worker.next_state(status, failures, ok, threshold=2) == expected


# --- SSRF guard ----------------------------------------------------------------------------

def fake_dns(address):
    def getaddrinfo(host, port, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 0))]
    return getaddrinfo


def test_public_address_is_allowed(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", fake_dns("140.82.121.4"))
    assert worker.resolves_to_public("github.com") == (True, None)


@pytest.mark.parametrize("address", ["10.43.0.10", "127.0.0.1", "169.254.169.254", "192.168.0.5"])
def test_name_resolving_to_private_address_is_blocked(monkeypatch, address):
    # e.g. an attacker's domain that points at the cluster's internal network
    monkeypatch.setattr(socket, "getaddrinfo", fake_dns(address))
    allowed, reason = worker.resolves_to_public("evil.example.com")
    assert not allowed and "non-public" in reason


def test_blocked_address_is_never_requested(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", fake_dns("10.0.0.1"))

    def must_not_open(*args, **kwargs):
        raise AssertionError("HTTP request must not be made")

    monkeypatch.setattr(worker._opener, "open", must_not_open)
    result = worker.check_url("http://evil.example.com")
    assert result["ok"] is False and "blocked" in result["error"]


# --- HTTP check results --------------------------------------------------------------------

class FakeResponse(io.BytesIO):
    def __init__(self, status):
        super().__init__(b"hello")
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture
def public_dns(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", fake_dns("93.184.215.14"))


def test_200_is_up(monkeypatch, public_dns):
    monkeypatch.setattr(worker._opener, "open", lambda req, timeout: FakeResponse(200))
    result = worker.check_url("https://example.com")
    assert result["ok"] is True and result["status_code"] == 200 and result["response_ms"] is not None


def http_error(code):
    def raise_error(req, timeout):
        raise urllib.error.HTTPError(req.full_url, code, "error", {}, None)
    return raise_error


def test_503_is_down(monkeypatch, public_dns):
    monkeypatch.setattr(worker._opener, "open", http_error(503))
    result = worker.check_url("https://example.com")
    assert result["ok"] is False and result["error"] == "HTTP 503"


def test_redirect_counts_as_up_but_is_not_followed(monkeypatch, public_dns):
    monkeypatch.setattr(worker._opener, "open", http_error(301))
    assert worker.check_url("https://example.com")["ok"] is True


def test_connection_error_is_down(monkeypatch, public_dns):
    def refuse(req, timeout):
        raise urllib.error.URLError(ConnectionRefusedError("connection refused"))

    monkeypatch.setattr(worker._opener, "open", refuse)
    result = worker.check_url("https://example.com")
    assert result["ok"] is False and "refused" in result["error"]


def test_non_http_scheme_is_never_opened(monkeypatch):
    def must_not_open(*args, **kwargs):
        raise AssertionError("must not be opened")

    monkeypatch.setattr(worker._opener, "open", must_not_open)
    result = worker.check_url("file:///etc/passwd")
    assert result["ok"] is False and "scheme" in result["error"]


def test_human_duration():
    assert worker.human_duration(42) == "42s"
    assert worker.human_duration(125) == "2m 5s"
    assert worker.human_duration(3 * 3600 + 120) == "3h 2m"
