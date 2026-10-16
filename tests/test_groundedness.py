"""check_groundedness.py: segmentation, determinism, no network; the model test needs the pinned weights."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_groundedness as g  # noqa: E402

FIXTURE = REPO / "tests" / "fixtures" / "groundedness"
TOPIC = REPO / "certs" / "cka" / "1.1" / "en"
CACHE = g.CACHE


def overlap(premise, claim):
    """A stand-in scorer with no model: the share of the claim's words found in the premise."""
    want = set(g.WORD.findall(claim.lower()))
    return round(len(want & set(g.WORD.findall(premise.lower()))) / max(len(want), 1), 4)


def run(*args, cache):
    env = dict(os.environ, PYTHONPATH=str(REPO / "tests" / "netguard"), GROUNDEDNESS_CACHE=str(cache))
    return subprocess.run([sys.executable, "scripts/check_groundedness.py", *args], cwd=REPO, env=env,
                          capture_output=True, text=True, encoding="utf-8")


class Segmentation(unittest.TestCase):
    def test_prose_and_list_items_only_with_stable_ids(self):
        self.assertEqual(g.claims((FIXTURE / "sample.md").read_text("utf-8")), [
            {"id": "L5.1", "text": "A StorageClass names the provisioner that creates the volume."},
            {"id": "L5.2", "text": "It is cluster-scoped and never namespaced."},
            {"id": "L8.1", "text": "reclaimPolicy: Retain keeps the volume after the claim is deleted."},
            {"id": "L19.1", "text": "See the docs for every field of the object."}])


class Determinism(unittest.TestCase):
    def test_same_tree_same_cache_same_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            g.CACHE = Path(tmp)
            (g.CACHE / "sources").mkdir()
            for url, text in zip(g.cited(TOPIC), json.loads((FIXTURE / "sources.json").read_text("utf-8")).values()):
                (g.CACHE / "sources" / f"{g.sha(url)}.txt").write_text(text, encoding="utf-8")
            try:
                first, second = (json.dumps(g.check_topic(TOPIC, overlap), sort_keys=True) for _ in range(2))
            finally:
                g.CACHE = CACHE
        self.assertEqual(first, second)
        report = json.loads(first)
        self.assertEqual(report["sources"][0]["source"], "syllabus")
        self.assertTrue(report["unsupported"] and report["result"] == "fail")

    def test_written_entry_agrees_with_quality_score(self):
        import quality_score as qs
        before = (meta := TOPIC / "meta.yaml").read_bytes()
        try:
            for result in ("pass", "pass", "fail"):
                g.write_quality(TOPIC, {"result": result, "evidence": "0 of 3 claims unsupported"})
                data = g.yaml.safe_load(meta.read_text("utf-8"))["quality"]
                self.assertEqual([(c["result"], c["weight"], c["ran_at"]) for c in data["checks"] if c["name"] == "groundedness"],
                                 [(result, 5, None)])
                self.assertEqual(qs.main(["--check", str(TOPIC)]), 0)
        finally:
            meta.write_bytes(before)


class NoNetwork(unittest.TestCase):
    def test_dry_run_and_fetch_with_the_network_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            outs = []
            for n, extra in enumerate(([], ["--fetch"])):
                r = run("--dry-run", *extra, "certs/cka/1.1/en", "--json", f"{tmp}/{n}.json", cache=tmp)
                self.assertEqual(r.returncode, 0, r.stderr)
                outs.append(Path(f"{tmp}/{n}.json").read_bytes())
        self.assertEqual(outs[0], outs[1])
        self.assertTrue(all(s.get("status") for s in json.loads(outs[0])[0]["sources"][1:]))


@unittest.skipUnless((g.MODEL / "model.safetensors").exists(), "no weights: check_groundedness.py --download")
class Model(unittest.TestCase):
    def test_pr6_traps_caught_offline_and_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as tmp:
            for n in range(2):
                r = run("--fixture", str(FIXTURE), "--json", f"{tmp}/{n}.json", cache=CACHE)
                self.assertEqual(r.returncode, 0, r.stderr)
            first, second = (Path(f"{tmp}/{n}.json").read_bytes() for n in range(2))
        self.assertEqual(first, second)
        result = json.loads(first)[0]
        self.assertEqual(result["pr6_traps_caught"], "13/13")
        self.assertGreaterEqual(result["accuracy"], 0.9)


if __name__ == "__main__":
    unittest.main()
