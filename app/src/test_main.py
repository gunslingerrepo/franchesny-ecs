import os

os.environ.setdefault("APP_VERSION", "test")
os.environ.setdefault("GIT_COMMIT", "testsha")

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_version_returns_expected_fields():
    response = client.get("/version")
    assert response.status_code == 200
    body = response.json()
    assert body["version"] == "test"
    assert body["git_commit"] == "testsha"
    assert "env" in body
    assert "server_time_utc" in body
