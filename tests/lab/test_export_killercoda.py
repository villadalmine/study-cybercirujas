"""study-lab export --target killercoda: fixture labs, golden tree, determinism, guards, the verify wrapper."""
import json
import os
import shutil
import subprocess

import pytest

from teach.lab import export_killercoda as kc
from teach.lab import spec

from conftest import REPO, run_cli

FX = REPO / "tests" / "fixtures" / "lab_kc"
GOLDEN = REPO / "tests" / "fixtures" / "killercoda" / "golden"


def _labs():
    return [spec.load(FX / "linux", "curated"), spec.load(FX / "kind", "curated")]


def test_golden_tree():
    files = kc.tree(_labs(), {"democert": "Demo Cert"})
    if os.environ.get("UPDATE_GOLDEN"):
        shutil.rmtree(GOLDEN, ignore_errors=True)
        kc.write(files, GOLDEN)
    want = {p.relative_to(GOLDEN).as_posix(): p.read_text(encoding="utf-8") for p in GOLDEN.rglob("*") if p.is_file()}
    assert files == want


def test_images_and_shape():
    files = kc.tree(_labs())
    idx = json.loads(files["democert/t-1-1/index.json"])
    assert idx["backend"]["imageid"] == "ubuntu"
    assert idx["details"]["steps"][-1]["verify"] == "verify.sh"
    assert json.loads(files["structure.json"])["items"][0]["path"] == "democert"
    assert "SOLUTION" not in files["democert/t-1-1/assets/break_fix.sh"]
    assert "echo fixed" in files["democert/t-1-1/finish.md"]
    assert all("study.cybercirujas.club" in files[f"democert/t-1-1/{n}"] for n in ("intro.md", "finish.md"))


def test_kind_family_image(tmp_path):
    only = kc.scenario(spec.load(FX / "kind", "curated"))
    assert json.loads(only["index.json"])["backend"]["imageid"] == "kubernetes-kubeadm-1node"
    assert "kubectl wait" in only["background.sh"]


def test_byte_identical_twice(tmp_path):
    for d in ("a", "b"):
        assert run_cli("export", "--target", "killercoda", "--out", str(tmp_path / d), "cka/1.1", "lpic-2/200.1") == 0
    got = [{p.relative_to(tmp_path / d).as_posix(): p.read_bytes() for p in (tmp_path / d).rglob("*") if p.is_file()}
           for d in ("a", "b")]
    assert got[0] == got[1] and b"\r" not in b"".join(got[0].values())


def test_refuses_what_does_not_fit(tmp_path):
    shutil.copytree(FX / "linux", tmp_path / "l")
    y = (tmp_path / "l" / "lab.yaml")
    y.write_text(y.read_text().replace("verified: {status: true,", "verified: {status: false,"))
    lab = spec.load(tmp_path / "l")
    with pytest.raises(kc.ExportError, match="not verified"):
        kc.scenario(lab)
    assert "not yet verified" in kc.scenario(lab, True)["intro.md"]
    y.write_text(y.read_text() + "run_as: student\n")
    with pytest.raises(kc.ExportError, match="root only"):
        kc.scenario(spec.load(tmp_path / "l"), True)


def test_secret_guard(tmp_path):
    shutil.copytree(FX / "linux", tmp_path / "l")
    s = tmp_path / "l" / "break_fix.sh"
    s.write_text(s.read_text() + "# key ghp_" + "a" * 30 + "\n")
    with pytest.raises(kc.ExportError, match="secret-like"):
        kc.scenario(spec.load(tmp_path / "l"))
    assert not kc.FORBIDDEN.search("AKIAIOSFODNN7EXAMPLE")


@pytest.mark.skipif(shutil.which("bash") is None, reason="needs bash")
def test_verify_wrapper_honours_regex(tmp_path):
    lab = spec.load(FX / "linux", "curated")
    files = kc.scenario(lab)
    state = tmp_path / "s"
    home = tmp_path / "home"
    (home).mkdir()
    (home / "break_fix.sh").write_text(files["assets/break_fix.sh"].replace("/tmp/demo-state", str(state)))
    script = files["verify.sh"].replace("/opt/study-lab/democert-1.1", str(home))

    def run():
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True).returncode
    state.write_text("broken\n")
    assert run() != 0
    state.write_text("fixed\n")
    assert run() == 0
