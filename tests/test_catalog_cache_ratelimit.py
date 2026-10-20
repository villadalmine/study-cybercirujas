"""catalog.load() parses once per file version; /api is rate limited."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml
from fastapi.testclient import TestClient

from teach import api
from teach.core import catalog, ratelimit


class CatalogCacheTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "catalog.yaml").write_text(yaml.safe_dump({"certs": {"a": {"name": "A"}}}))
        patcher = mock.patch.dict(os.environ, {"TEACH_ROOT": str(self.root)})
        patcher.start()
        self.addCleanup(patcher.stop)
        catalog._CACHE.clear()
        self.addCleanup(catalog._CACHE.clear)

    def test_load_parses_once_and_returns_copies(self):
        real = yaml.safe_load
        with mock.patch.object(catalog.yaml, "safe_load", side_effect=real) as spy:
            first = catalog.load()
            first["certs"]["a"]["name"] = "mutated"
            for _ in range(40):
                self.assertEqual(catalog.load()["certs"]["a"]["name"], "A")
            self.assertEqual(spy.call_count, 1)

    def test_load_sees_a_changed_file(self):
        self.assertNotIn("b", catalog.load()["certs"])
        path = self.root / "catalog.yaml"
        path.write_text(yaml.safe_dump({"certs": {"a": {"name": "A"}, "b": {"name": "B"}}}))
        os.utime(path, ns=(1, 2_000_000_000))
        self.assertIn("b", catalog.load()["certs"])

    def test_missing_catalog_is_empty(self):
        (self.root / "catalog.yaml").unlink()
        self.assertEqual(catalog.load(), {"certs": {}})


class RateLimitTests(unittest.TestCase):
    def test_limiter_window(self):
        now = [0.0]
        lim = ratelimit.Limiter(window=60, clock=lambda: now[0])
        self.assertEqual([lim.hit("k", 3) for _ in range(3)], [0, 0, 0])
        self.assertGreater(lim.hit("k", 3), 0)
        self.assertEqual(lim.hit("other", 3), 0)
        now[0] = 61
        self.assertEqual(lim.hit("k", 3), 0)
        self.assertEqual(lim.hit("k", 0), 0)  # 0 = off

    def test_search_endpoint_returns_429(self):
        with mock.patch.object(ratelimit, "LIMITER", ratelimit.Limiter()), \
                mock.patch.object(ratelimit, "SEARCH_LIMIT", 2):
            client = TestClient(api.app)
            codes = [client.get("/api/search", params={"q": "x"}).status_code for _ in range(4)]
            self.assertEqual(codes[-1], 429)
            self.assertNotEqual(codes[0], 429)
            self.assertTrue(client.get("/api/search", params={"q": "x"}).headers.get("retry-after"))


class _Req:
    def __init__(self, xff=None, peer="10.0.0.1"):
        self.headers = {"x-forwarded-for": xff} if xff is not None else {}
        self.client = type("C", (), {"host": peer})()


class ClientIdentityTests(unittest.TestCase):
    def test_peer_is_used_unless_the_proxy_is_trusted(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TEACH_TRUST_PROXY", None)
            self.assertEqual(ratelimit.client_id(_Req("1.1.1.1, 2.2.2.2")), "10.0.0.1")

    def test_trusted_proxy_uses_the_right_most_entry(self):
        with mock.patch.dict(os.environ, {"TEACH_TRUST_PROXY": "1"}):
            os.environ.pop("TEACH_TRUSTED_HOPS", None)
            # the client sent "6.6.6.6"; the proxy appended the real peer
            self.assertEqual(ratelimit.client_id(_Req("6.6.6.6, 203.0.113.7")), "203.0.113.7")
            self.assertEqual(ratelimit.client_id(_Req("203.0.113.7")), "203.0.113.7")

    def test_extra_trusted_hops_and_missing_header(self):
        with mock.patch.dict(os.environ, {"TEACH_TRUST_PROXY": "1", "TEACH_TRUSTED_HOPS": "2"}):
            self.assertEqual(ratelimit.client_id(_Req("6.6.6.6, 203.0.113.7, 10.9.9.9")), "203.0.113.7")
            self.assertEqual(ratelimit.client_id(_Req("10.9.9.9")), "10.0.0.1")  # fewer entries than hops
        with mock.patch.dict(os.environ, {"TEACH_TRUST_PROXY": "1"}):
            self.assertEqual(ratelimit.client_id(_Req()), "10.0.0.1")

    def test_rotating_a_spoofed_header_does_not_escape_the_limit(self):
        with mock.patch.dict(os.environ, {"TEACH_TRUST_PROXY": "1"}),                 mock.patch.object(ratelimit, "LIMITER", ratelimit.Limiter()),                 mock.patch.object(ratelimit, "SEARCH_LIMIT", 2):
            client = TestClient(api.app)
            codes = [client.get("/api/search", params={"q": "x"},
                                headers={"X-Forwarded-For": f"9.9.9.{i}, 203.0.113.7"}).status_code
                     for i in range(5)]
            self.assertEqual(codes[-1], 429)

    def test_different_visitors_behind_the_proxy_have_their_own_bucket(self):
        with mock.patch.dict(os.environ, {"TEACH_TRUST_PROXY": "1"}),                 mock.patch.object(ratelimit, "LIMITER", ratelimit.Limiter()),                 mock.patch.object(ratelimit, "SEARCH_LIMIT", 1):
            client = TestClient(api.app)
            a = [client.get("/api/search", params={"q": "x"}, headers={"X-Forwarded-For": "203.0.113.7"}).status_code
                 for _ in range(2)]
            b = client.get("/api/search", params={"q": "x"}, headers={"X-Forwarded-For": "203.0.113.8"}).status_code
            self.assertEqual(a[-1], 429)
            self.assertNotEqual(b, 429)


@unittest.skipIf(shutil.which("helm") is None, "helm not installed")
class ChartTests(unittest.TestCase):
    def test_chart_ships_the_limiter_off(self):
        chart = Path(__file__).resolve().parent.parent / "deploy" / "helm"
        out = subprocess.run(["helm", "template", "study", str(chart), "--set-string", "env.TEACH_SECRET=" + "a1" * 20],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        for name in ("TEACH_RATE_API", "TEACH_RATE_SEARCH", "TEACH_TRUST_PROXY"):
            self.assertRegex(out.stdout, rf'name: {name}\s+value: "0"')


if __name__ == "__main__":
    unittest.main()
