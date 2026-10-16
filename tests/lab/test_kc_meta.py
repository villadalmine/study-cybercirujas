"""Certification header, syllabus gate (R1/R3/R5), provenance banner, metadata.json and the generated-tree guardrails."""
import json
import shutil

import pytest

from teach.lab import export_killercoda as kc
from teach.lab import kc_meta, runner, spec

from conftest import REPO

FX = REPO / "tests" / "fixtures" / "lab_kc"
REPO_FX = REPO / "tests" / "fixtures" / "kc_repo"


@pytest.fixture(autouse=True)
def fixture_repo(monkeypatch):
    monkeypatch.setattr(runner, "REPO_ROOT", REPO_FX)


def _lab(name="linux"):
    return spec.load(FX / name, "curated")


def test_syllabus_rules():
    s = kc_meta.syllabus("democert", "1.1", "Demo linux lab")
    assert (s["label"], s["domain"], s["objective"]["id"]) == ("DEMO v2.0", {"id": "1", "title": "Basics"}, "1.1")
    assert len(s["objective_sha256"]) == 64
    with pytest.raises(kc.ExportError, match="R1"):
        kc_meta.syllabus("nocert", "1.1", "x")
    with pytest.raises(kc.ExportError, match="R3"):
        kc_meta.syllabus("democert", "9.9", "x")
    with pytest.raises(kc.ExportError, match="R5"):
        kc_meta.syllabus("democert", "1.1", "Another title")


def test_decorated_scenario_shows_certification_provenance_and_metadata():
    lab = _lab()
    out = kc_meta.decorate(lab, kc.scenario(lab), None)
    intro = out["intro.md"].split("\n")
    assert intro[2] == "**DEMO v2.0 · Domain 1: Basics · Objective 1.1: Demo linux lab**"
    assert "AI-generated (claude/opus)" in out["intro.md"] or "AI-assisted (claude/opus)" in out["intro.md"]   # lab declares nothing: the topic is the fallback
    meta = json.loads(out["metadata.json"])
    assert {"cert", "exam_version", "domain", "objective", "objective_sha256"} <= set(meta)
    assert json.loads(out["index.json"])["title"] == "1 | Basics - 1.1 Demo linux lab"


def test_the_labs_own_provenance_wins_over_the_topics(tmp_path):
    shutil.copytree(FX / "linux", tmp_path / "l")
    y = tmp_path / "l" / "lab.yaml"
    y.write_text(y.read_text() + "origin: {kind: community, author: ana}\n")
    prov = kc_meta.provenance(spec.load(tmp_path / "l", "curated"))
    assert (prov["kind"], prov["tool"], prov["reviews"], prov["from"]) == ("human", "ana", {}, "lab.yaml")   # not the AI topic's review
    assert kc_meta.banner(prov, None).startswith("> **About this lab:** Written by a human (ana).")
    fallback = kc_meta.provenance(_lab())
    assert fallback["kind"] == "ai" and "human_review" in fallback["reviews"] and fallback["from"] == "topic meta.yaml"


def test_commit_id_is_fixed_length():
    assert len(kc_meta.source_commit(_lab()) or "x" * 12) == 12


def test_bash_n_gets_lf_bytes_whatever_the_platform(monkeypatch):
    seen = []
    monkeypatch.setattr(kc.subprocess, "run", lambda cmd, **kw: seen.append(kw["input"]) or type("R", (), {"returncode": 0})())
    assert kc.bash_n("echo hi\r\nexit 0\r\n") == 0
    assert isinstance(seen[0], bytes) and b"\r" not in seen[0]
    assert kc.bash_n("if then\r\n") == 0   # the stub always answers 0; the real call is covered below


def test_bash_n_real_script_with_crlf_passes_and_syntax_error_fails():
    assert kc.bash_n("set -e\r\necho ok\r\n") == 0
    assert kc.bash_n("if then\n") != 0


def test_banner_wording():
    p = {"kind": "ai", "tool": "claude/opus", "level": "ai-beta", "score": 86.1, "reviews": {}}
    assert kc_meta.banner(p, None).startswith("> **About this lab:** AI-generated (claude/opus), not independently reviewed yet.")
    assert "Quality level: *AI beta* (86.1/100)" in kc_meta.banner(p, None)
    r = dict(p, reviews={"independent_review": {"evidence": "reviewer X", "date": "2026-10-01"}})
    assert "independently reviewed: reviewer X" in kc_meta.banner(r, None)
    assert kc_meta.banner(dict(p, kind="human", tool="ana"), None).startswith("> **About this lab:** Written by a human (ana).")
    ev = {"env": {"image": "ubuntu", "os": "24.04", "parity": "assumed"}, "runner": {"url": "https://ci/1"}, "date": "2026-10-16"}
    assert "Tested:** ubuntu, Ubuntu 24.04 on 2026-10-16 ([run](https://ci/1))" in kc_meta.banner(p, ev)
    assert "not yet measured on Killercoda" in kc_meta.banner(p, ev)


def test_tree_guardrails(tmp_path):
    files = kc.tree([_lab(), _lab("kind")], None, decorate=True)
    assert kc.check_tree(files) == []
    broken = dict(files)
    key = next(k for k in broken if k.endswith("/verify.sh"))
    del broken[key]
    bad = kc.check_tree(broken)
    assert any("verify.sh, which does not exist" in b for b in bad)
    idx = next(k for k in files if k.startswith("democert/") and k.endswith("/index.json"))
    broken = dict(files, **{idx: files[idx].replace("ubuntu", "centos")})
    assert any("imageid" in b for b in kc.check_tree(broken))
