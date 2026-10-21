"""Killercoda is an optional channel: a lab is `tested` or `loaded-untested`, a Killercoda failure never fails CI,
and an untested scenario never reaches the mirror. The scope is data (tracks.yaml), not workflow YAML."""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

from teach.lab import cli, kc_scope, kc_test, spec
from teach.lab import export_killercoda as kc

ROOT = Path(__file__).resolve().parents[2]
KD = ROOT / "deploy" / "killercoda"
TRACKS = KD / "tracks.yaml"


def test_the_data_names_only_labs_and_certifications_that_exist():
    lab_ids = [f"{d.parts[-3]}/{d.parts[-2]}" for d in ROOT.glob("certs/*/*/lab")]
    sc = kc_scope.load(TRACKS)
    assert sc.certs == ["cka", "ckad"]
    kc_scope.check_known(sc, kc.cert_names(ROOT), lab_ids)


def test_every_tested_lab_has_a_way_to_be_proven():
    """A lab with Killercoda evidence and no reference fix could never be re-proven: catch it here."""
    sc = kc_scope.load(TRACKS)
    provable = {f"{c}/{t}" for c, t in cli.provable_labs(KD, sc)}
    assert {x for x in sc.evidence if sc.tested(x)} <= provable


def test_labs_with_a_fix_verb_or_a_fix_file_are_provable():
    got = cli.provable_labs(KD, kc_scope.load(TRACKS))
    assert ("cka", "1.1") in got and ("lpic-2", "200.1") in got   # fix files
    assert ("ckad", "4.4") in got and ("ckad", "5.2") in got      # fix verb in the script
    assert ("cka", "1.2") not in got                              # nothing to prove it with: loaded-untested


def test_the_plan_lists_the_provable_labs(capsys):
    assert cli.main(["test", "--target", "killercoda", "--plan", "--today", "2026-10-16"]) == 0
    rows = json.loads(capsys.readouterr().out)
    assert {m["lab"] for m in rows} >= {"cka/1.1", "ckad/5.2", "lpic-2/200.1"}
    assert all(set(m) == {"lab", "image"} for m in rows)   # nothing is "required"


def test_publish_gate_refuses_a_scenario_without_passing_evidence_for_any_cert():
    """Untested never reaches the mirror, whatever the certification: no tested.json, no scenario."""
    labs, _ = kc.select(ROOT, ["cka"])
    gated: list = []
    files = kc.tree(labs[:3], kc.cert_names(ROOT), True, {}, {}, "2026-10-16", gated, decorate=True)
    assert len(gated) == 3 and not [k for k in files if k.startswith("cka/")]


def test_killercoda_jobs_never_fail_a_pr_and_name_no_lab():
    for name in ("killercoda-parity.yml", "killercoda-publish.yml"):
        text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
        assert "--plan" in text and re.search(r"fromJSON\(needs\.[a-z-]+\.outputs\.labs\)", text), name
        assert "continue-on-error: true" in text and "matrix.required" not in text, name
        assert "\n    continue-on-error" not in text, f"{name}: a job-level flag leaves a red check; use the step level"
        assert not re.search(r"lab:\s*'?(cka|ckad|lpic)", text), f"{name} lists a lab by hand"


def test_human_tested_entries_match_the_evidence_file():
    """human_tested.yaml drives the scenario banner; lab-evidence.yaml is the standard. They must say the same."""
    human = yaml.safe_load((KD / "human_tested.yaml").read_text(encoding="utf-8")) or {}
    ev = kc_scope.load(TRACKS).evidence
    for lab, rec in human.items():
        got = ev.get(lab, {}).get("human-killercoda")
        assert got and got["date"] == str(rec["date"]) and rec["by"] in got["evidence"], lab


def _forged(lab_id):
    """A tested.json that passes valid_for for this lab's scenario: what a forged or stale one would look like."""
    cert, _, topic = lab_id.partition("/")
    lab = spec.load(ROOT / "certs" / cert / topic / "lab", "curated")
    files = kc.scenario(lab, True)
    image = json.loads(files["index.json"])["backend"]["imageid"]
    day = "2026-10-16"
    measured = {k: v for k, v in kc_test.resolve_env(image, day).items() if k != "parity"}
    ev = kc_test.evidence(files, image, {n: {"ok": True} for n in "abcdef"}, {"kind": "local"}, day, measured)
    assert kc_test.valid_for(ev, files, image, day)
    return lab, {f"{cert}/{kc.slug(topic, lab.spec['title'])}": ev}, day


def test_the_mirror_gate_needs_a_recorded_proof_for_the_current_lab_hash():
    """A passing tested.json alone is not enough: ckad/4.4 is under `failed:` and has no killercoda entry, so a forged one is refused."""
    scope = kc_scope.load(TRACKS)
    lab, evidence, day = _forged("ckad/4.4")
    gated: list = []
    files = kc.tree([lab], kc.cert_names(ROOT), True, {}, evidence, day, gated, decorate=True, scope=scope)
    assert not [k for k in files if k.startswith("ckad/")] and "lab-evidence.yaml" in gated[0]
    # the same forgery is refused for a lab with only a kind proof, and for a stale hash
    stale = kc_scope.Scope(scope.certs, {}, {"ckad/4.4": {"killercoda-kubeadm": {**scope.evidence["ckad/5.2"]["killercoda-kubeadm"], "lab_hash": "0" * 64}}}, scope.publishing)
    gated = []
    files = kc.tree([lab], kc.cert_names(ROOT), True, {}, evidence, day, gated, decorate=True, scope=stale)
    assert gated and not [k for k in files if k.startswith("ckad/")]
    # positive control: a lab with a current killercoda entry goes through with the same kind of tested.json
    from teach.lab import kc_meta
    lab, evidence, day = _forged("ckad/5.2")
    entry = {**next(iter(scope.evidence["ckad/5.2"].values())), "lab_hash": kc_meta.lab_hash(lab)}   # a proof for the lab as it is now
    ok = kc_scope.Scope(scope.certs, {}, {"ckad/5.2": {"killercoda-kubeadm": entry}}, scope.publishing)
    files = kc.tree([lab], kc.cert_names(ROOT), True, {}, evidence, day, [], decorate=True, scope=ok)
    assert any(k.startswith("ckad/") and k.endswith("tested.json") for k in files)
