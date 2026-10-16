"""Certification header, syllabus gate (R1/R3/R5), provenance banner, metadata.json and the generated-tree guardrails."""
import json

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
    assert "Authorship not recorded" in out["intro.md"]
    meta = json.loads(out["metadata.json"])
    assert {"cert", "exam_version", "domain", "objective", "objective_sha256"} <= set(meta)
    assert json.loads(out["index.json"])["title"] == "1 | Basics - 1.1 Demo linux lab"


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
