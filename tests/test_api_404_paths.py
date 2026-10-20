"""404 responses never carry an absolute filesystem path."""
import pytest
from fastapi.testclient import TestClient

from teach import api
from teach.core import catalog, certs


@pytest.fixture
def client():
    return TestClient(api.app)


def _boom(*a, **k):
    raise FileNotFoundError("No existe /srv/secret/place/certs/x.md. Crear con: teach cert add x")


@pytest.mark.parametrize("url", ["/api/certs/cka", "/api/certs/cka/topics/1.1/preview", "/api/certs/cka/topics/1.1"])
def test_file_not_found_is_generic(client, monkeypatch, url):
    monkeypatch.setattr(certs, "topics", _boom)
    monkeypatch.setattr(certs, "get_topic", _boom)
    monkeypatch.setattr(catalog, "get_cert", lambda c: {"name": "x"})
    res = client.get(url)
    assert res.status_code == 404
    assert "/srv" not in res.text and res.json()["detail"] == "Not found"


def test_unknown_cert_still_explains_itself(client):
    res = client.get("/api/certs/does-not-exist")
    assert res.status_code == 404 and "does-not-exist" in res.json()["detail"]
