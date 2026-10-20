"""Determinism: with AI or without it, the same pipeline and the same validator.

Everything a student or a contributor runs — the site, the API, the CLI, the
validators, the lab checks — must give the same bytes twice and must work with
no model and no network. AI is optional and lives only in the maintainer steps
that author, translate or snapshot, and what they produce passes through the
very validators tested here. Without AI is sovereignty in its purest form, so
it is the configuration these tests run in:

- external network blocked (tests/netguard/sitecustomize.py on PYTHONPATH),
- every model credential removed from the environment,
- the model CLIs (claude, codex, gemini, agy, ollama) replaced by tripwires
  that record any call,
- TEACH_OFFLINE=1, so the API does not even try its live price check.

Each derived artefact and each validator runs twice in fresh processes and the
outputs are compared byte for byte.

    make determinism      # just this
    make test             # this and everything else
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NETGUARD = REPO / "tests" / "netguard"
MODEL_CLIS = ("claude", "codex", "gemini", "agy", "ollama")
MODEL_ENV_PREFIXES = ("LITELLM_", "OPENROUTER", "ANTHROPIC", "OPENAI", "GEMINI",
                      "GOOGLE_API", "TEACH_BACKEND", "TEACH_TRANSLATE", "TEACH_AGENT_CMD",
                      "TEACH_CLAUDE_")

# Prints every derived artefact the site and the repository serve. Run in a
# fresh interpreter each time, so nothing is shared between the two runs.
DERIVE = r"""
import json, sys
sys.path.insert(0, "scripts")
import status_matrix, model_comparison, gen_readme_table, gen_api_docs
from fastapi.testclient import TestClient
from teach.api import app
out = {
    "docs/STATUS.md": status_matrix._render(),
    "docs/MODELS.md": model_comparison.render_markdown(),
    "README table": gen_readme_table.table(),
    "API table": gen_api_docs.table(),
}
client = TestClient(app)
for path in ["/api/langs", "/api/catalog", "/api/paths", "/api/status", "/api/models",
             "/api/certs/cka", "/api/certs/cka/topics/1.1?lang=en",
             "/api/certs/cka/topics/1.1?lang=es", "/api/certs/cka/topics/1.1?lang=ja",
             "/api/search?q=etcd%20backup", "/"]:
    response = client.get(path)
    out[path] = [response.status_code, response.text]
print(json.dumps(out, sort_keys=True, ensure_ascii=False))
"""

# The validators of `make verify-ci`, plus the lab contract.
VALIDATORS = [
    ["scripts/quality_report.py"],
    ["scripts/check_manifests.py"],
    ["scripts/check_k8s_apis.py"],
    ["scripts/check_provenance.py"],
    ["scripts/check_sources.py"],
    ["scripts/check_versions.py"],
    ["scripts/check_syllabus.py"],
    ["scripts/check_source_chain.py"],
    ["scripts/quality_score.py", "--check"],
]
# Must give the same verdict twice; whether every lab passes is
# tests/test_labs.py's job (it knows the documented exceptions).
LAB_VALIDATE = ["-c", "from teach.cli import main; main()", "lab", "validate", "--all"]


def sovereign_env(tripwire_dir: Path) -> dict:
    """The environment of a machine with no model and no internet."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(MODEL_ENV_PREFIXES)}
    env.update({
        "TEACH_ROOT": str(REPO),
        "TEACH_OFFLINE": "1",
        "PYTHONPATH": os.pathsep.join(filter(None, [str(NETGUARD), str(REPO)])),
        "PATH": str(tripwire_dir) + os.pathsep + env.get("PATH", ""),
        "PYTHONHASHSEED": "0",
    })
    return env


class DeterminismTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.tripwires = Path(cls.tmp.name) / "bin"
        cls.tripwires.mkdir()
        cls.calls = Path(cls.tmp.name) / "model-calls.log"
        for name in MODEL_CLIS:
            script = cls.tripwires / name
            script.write_text(f"#!/bin/sh\necho {name} \"$@\" >> '{cls.calls}'\nexit 1\n")
            script.chmod(script.stat().st_mode | stat.S_IEXEC)
        cls.env = sovereign_env(cls.tripwires)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_py(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, *args], cwd=REPO, env=self.env,
                              capture_output=True, text=True, timeout=600)

    def assertNoModelCalled(self):
        self.assertFalse(self.calls.exists() and self.calls.read_text().strip(),
                         f"a model CLI was invoked: {self.calls.read_text() if self.calls.exists() else ''}")

    def test_netguard_blocks_the_outside_world(self):
        result = self.run_py("-c", "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("netguard", result.stderr)

    def test_netguard_blocks_connect_ex_to_a_numeric_address(self):
        # No DNS involved, and connect_ex is a separate method from connect.
        result = self.run_py("-c", "import socket; s = socket.socket(); s.settimeout(2); "
                                   "print(s.connect_ex(('1.1.1.1', 443)))")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("netguard", result.stderr)

    def test_netguard_lets_loopback_through(self):
        result = self.run_py("-c", "import socket; s = socket.socket(); s.settimeout(2); "
                                   "print(s.connect_ex(('127.0.0.1', 9)))")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_derived_artefacts_are_byte_identical_twice(self):
        first = self.run_py("-c", DERIVE)
        self.assertEqual(first.returncode, 0, first.stderr[-2000:])
        second = self.run_py("-c", DERIVE)
        self.assertEqual(second.returncode, 0, second.stderr[-2000:])
        self.assertEqual(hashlib.sha256(first.stdout.encode()).hexdigest(),
                         hashlib.sha256(second.stdout.encode()).hexdigest(),
                         "the same tree produced different derived output")
        served = json.loads(first.stdout)
        self.assertFalse(json.loads(served["/api/models"][1])["live_checked"])
        self.assertNoModelCalled()

    def test_validators_pass_offline_and_agree_with_themselves(self):
        for args in VALIDATORS:
            with self.subTest(validator=" ".join(args[-3:])):
                first, second = self.run_py(*args), self.run_py(*args)
                self.assertEqual(first.returncode, 0, (first.stdout + first.stderr)[-2000:])
                self.assertEqual((first.returncode, first.stdout),
                                 (second.returncode, second.stdout))
        self.assertNoModelCalled()

    def test_lab_validation_is_stable_offline(self):
        first, second = self.run_py(*LAB_VALIDATE), self.run_py(*LAB_VALIDATE)
        self.assertIn("lab(s) checked", first.stdout)
        self.assertEqual((first.returncode, first.stdout), (second.returncode, second.stdout))
        self.assertNoModelCalled()


if __name__ == "__main__":
    unittest.main()
