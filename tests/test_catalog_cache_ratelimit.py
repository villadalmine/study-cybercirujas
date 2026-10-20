"""catalog.load() parses once per file version; /api is rate limited."""
import os

import pytest
import yaml
from fastapi.testclient import TestClient

from teach import api
from teach.core import catalog, ratelimit


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("TEACH_ROOT", str(tmp_path))
    (tmp_path / "catalog.yaml").write_text(yaml.safe_dump({"certs": {"a": {"name": "A"}}}))
    catalog._CACHE.clear()
    return tmp_path


def test_load_parses_once_and_returns_copies(root, monkeypatch):
    calls = []
    real = yaml.safe_load
    monkeypatch.setattr(catalog.yaml, "safe_load", lambda s: calls.append(1) or real(s))
    first = catalog.load()
    first["certs"]["a"]["name"] = "mutated"
    for _ in range(40):
        assert catalog.load()["certs"]["a"]["name"] == "A"
    assert len(calls) == 1


def test_load_sees_a_changed_file(root):
    assert "b" not in catalog.load()["certs"]
    path = root / "catalog.yaml"
    path.write_text(yaml.safe_dump({"certs": {"a": {"name": "A"}, "b": {"name": "B"}}}))
    os.utime(path, ns=(1, 2_000_000_000))
    assert "b" in catalog.load()["certs"]


def test_missing_catalog_is_empty(tmp_path, monkeypatch):
    monkeypatch.setenv("TEACH_ROOT", str(tmp_path))
    catalog._CACHE.clear()
    assert catalog.load() == {"certs": {}}


def test_limiter_window():
    now = [0.0]
    lim = ratelimit.Limiter(window=60, clock=lambda: now[0])
    assert [lim.hit("k", 3) for _ in range(3)] == [0, 0, 0]
    assert lim.hit("k", 3) > 0
    assert lim.hit("other", 3) == 0
    now[0] = 61
    assert lim.hit("k", 3) == 0
    assert lim.hit("k", 0) == 0  # 0 = off


def test_search_endpoint_returns_429(monkeypatch):
    monkeypatch.setattr(ratelimit, "LIMITER", ratelimit.Limiter())
    monkeypatch.setattr(ratelimit, "SEARCH_LIMIT", 2)
    client = TestClient(api.app)
    codes = [client.get("/api/search", params={"q": "x"}).status_code for _ in range(4)]
    assert codes[:2] != [429, 429] and codes[-1] == 429
    res = client.get("/api/search", params={"q": "x"})
    assert res.headers.get("retry-after")
