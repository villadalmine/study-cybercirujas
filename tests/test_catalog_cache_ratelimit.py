"""catalog.load() parses once per file version; /api is rate limited."""
import os
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


if __name__ == "__main__":
    unittest.main()
