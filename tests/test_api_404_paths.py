"""404 responses never carry an absolute filesystem path."""
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from teach import api
from teach.core import catalog, certs


def _boom(*args, **kwargs):
    raise FileNotFoundError("No existe /srv/secret/place/certs/x.md. Crear con: teach cert add x")


class NotFoundTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(api.app)

    def test_file_not_found_is_generic(self):
        for url in ("/api/certs/cka", "/api/certs/cka/topics/1.1/preview", "/api/certs/cka/topics/1.1"):
            with self.subTest(url=url), \
                    mock.patch.object(certs, "topics", _boom), \
                    mock.patch.object(certs, "get_topic", _boom), \
                    mock.patch.object(catalog, "get_cert", lambda c: {"name": "x"}):
                res = self.client.get(url)
                self.assertEqual(res.status_code, 404)
                self.assertNotIn("/srv", res.text)
                self.assertEqual(res.json()["detail"], "Not found")

    def test_unknown_cert_still_explains_itself(self):
        res = self.client.get("/api/certs/does-not-exist")
        self.assertEqual(res.status_code, 404)
        self.assertIn("does-not-exist", res.json()["detail"])


if __name__ == "__main__":
    unittest.main()
