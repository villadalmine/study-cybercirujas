"""Smoke test: what a student does after cloning, end to end, offline and free.

Starts the real server (uvicorn, the same app `make serve` and the Docker image
run) on a free local port, and checks the site, the API endpoints the README
shows, and the student half of the CLI. No key, no model, no network beyond
127.0.0.1 — it runs the same in CI (`make verify-ci`) as on a laptop
(`make smoke`).

It exists because the README's "clone and run" path had never been followed on
a clean machine: on 2026-10-14 it failed at `make setup` (no python3-venv) and
`teach lab up` silently broke nothing. A path that is documented but not tested
is a path that is broken without anyone knowing.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# Offline on purpose: external network blocked, no live price check. If the
# site or the CLI ever needs the internet to work, this test says so.
OFFLINE_ENV = {**os.environ, "TEACH_ROOT": str(REPO), "TEACH_OFFLINE": "1",
               "PYTHONPATH": os.pathsep.join([str(REPO / "tests" / "netguard"), str(REPO)])}
# A certification that is complete in en and es (docs/STATUS.md) and has a topic 1.1.
CERT, TOPIC = "cka", "1.1"


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ServerSmokeTests(unittest.TestCase):
    """The site and the API, through a real HTTP server."""

    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        cls.base = f"http://127.0.0.1:{cls.port}"
        env = OFFLINE_ENV
        cls.server = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "teach.api:app",
             "--host", "127.0.0.1", "--port", str(cls.port), "--log-level", "warning"],
            cwd=REPO, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise RuntimeError("server exited: " + cls.server.stderr.read().decode())
            try:
                urllib.request.urlopen(cls.base + "/healthz", timeout=2)
                return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.3)
        cls.server.kill()
        raise RuntimeError("server did not answer /healthz within 60 s")

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.server.kill()
        cls.server.stderr.close()

    def get(self, path: str):
        with urllib.request.urlopen(self.base + path, timeout=30) as response:
            self.assertEqual(response.status, 200, path)
            body = response.read()
            if "json" in response.headers.get("content-type", ""):
                return json.loads(body)
            return body.decode("utf-8", "replace")

    def test_health(self):
        self.assertTrue(self.get("/healthz")["ok"])

    def test_site_and_docs_are_served(self):
        self.assertIn("<html", self.get("/").lower())
        self.assertIn("swagger", self.get("/docs").lower())

    def test_catalog_lists_certifications(self):
        catalog = self.get("/api/catalog")
        self.assertIn(CERT, catalog)
        self.assertGreater(len(catalog), 20)

    def test_status_reports_complete_certifications(self):
        status = self.get("/api/status")
        row = next(r for r in status if r["id"] == CERT)
        self.assertEqual(row["generated"], row["topics"])
        self.assertIn("en", row["langs"])

    def test_syllabus_lists_topics_with_languages(self):
        cert = self.get(f"/api/certs/{CERT}")
        topic = next(t for t in cert["topics"] if t["id"] == TOPIC)
        self.assertTrue(topic["available"])
        self.assertIn("es", topic["langs"])

    def test_topic_reads_in_english_and_spanish(self):
        for lang in ("en", "es"):
            with self.subTest(lang=lang):
                data = self.get(f"/api/certs/{CERT}/topics/{TOPIC}?lang={lang}")
                self.assertEqual(data["lang"], lang)
                self.assertIsNone(data["lang_fallback"])
                self.assertGreater(len(data["content"]), 1000)
                self.assertTrue(data["generated_by"]["model"])  # the AI disclosure

    def test_missing_language_falls_back_and_says_so(self):
        data = self.get(f"/api/certs/{CERT}/topics/{TOPIC}?lang=ja")
        self.assertEqual(data["lang_fallback"], "en")
        self.assertTrue(data["content"])

    def test_search_finds_topics(self):
        hits = self.get("/api/search?q=etcd&limit=3")["hits"]
        self.assertTrue(hits)
        self.assertTrue(all("why" in h for h in hits))

    def test_models_catalogue_for_the_bot(self):
        self.assertIn("tiers", self.get("/api/models"))


class StudentCliSmokeTests(unittest.TestCase):
    """The CLI commands the README offers a student — no key, no model."""

    def teach(self, *args: str) -> str:
        script = Path(sys.executable).parent / "teach"
        cmd = [str(script)] if script.exists() else [
            sys.executable, "-c", "from teach.cli import main; main()"]
        result = subprocess.run([*cmd, *args], cwd=REPO, capture_output=True, text=True,
                                timeout=60, env=OFFLINE_ENV)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_cert_list(self):
        self.assertIn(CERT, self.teach("cert", "list"))

    def test_cert_show(self):
        out = self.teach("cert", "show", CERT)
        self.assertIn(TOPIC, out)
        self.assertIn("generated", out)

    def test_lab_help(self):
        self.assertIn("up", self.teach("lab", "--help"))


if __name__ == "__main__":
    unittest.main()
