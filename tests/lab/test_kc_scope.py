"""Killercoda scope: `tested` labs (an allowlist in tracks.yaml) are a gate, everything else is `loaded-untested`
and never fails CI nor reaches the mirror. The scope is data, not workflow YAML."""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

from teach.lab import cli, kc_scope
from teach.lab import export_killercoda as kc

ROOT = Path(__file__).resolve().parents[2]
KD = ROOT / "deploy" / "killercoda"
TRACKS = KD / "tracks.yaml"


def _write(tmp_path, body):
    f = tmp_path / "t.yaml"
    f.write_text(body, encoding="utf-8")
    return f


def test_cka_and_ckad_are_the_supported_certifications():
    assert kc_scope.load(TRACKS).certs == ["cka", "ckad"]


def test_the_data_names_only_labs_and_certifications_that_exist():
    lab_ids = [f"{d.parts[-3]}/{d.parts[-2]}" for d in ROOT.glob("certs/*/*/lab")]
    kc_scope.check_known(kc_scope.load(TRACKS), kc.cert_names(ROOT), lab_ids)


def test_every_tested_lab_has_a_way_to_be_proven():
    """A lab in the allowlist without a reference fix would fail its own gate: catch it here."""
    sc = kc_scope.load(TRACKS)
    provable = {f"{c}/{t}" for c, t in cli.provable_labs(KD, sc)}
    assert set(sc.required) <= provable


def test_status_is_tested_only_for_the_allowlist():
    sc = kc_scope.Scope(["cka"], ["cka/1.1"], {"cka/1.2": "verify never passed"})
    assert kc_scope.status("cka/1.1", sc) == kc_scope.TESTED and kc_scope.is_required("cka/1.1", sc)
    assert kc_scope.status("cka/1.2", sc) == kc_scope.UNTESTED and not kc_scope.is_required("cka/1.2", sc)
    assert kc_scope.status("cka/9.9", sc) == kc_scope.UNTESTED
    assert kc_scope.reason("cka/1.1", sc, True) == ""
    assert kc_scope.reason("cka/1.2", sc, True) == "verify never passed"
    assert "no reference fix" in kc_scope.reason("cka/9.9", sc, False)
    assert "never run" in kc_scope.reason("cka/9.8", sc, True)


def test_nothing_is_tested_without_a_list(tmp_path):
    sc = kc_scope.load(tmp_path / "missing.yaml")
    assert sc == kc_scope.Scope() and kc_scope.status("cka/1.1", sc) == kc_scope.UNTESTED
    assert kc_scope.load(_write(tmp_path, "pilot: [cka/1.1]\n")) == kc_scope.Scope()


@pytest.mark.parametrize("body", [
    "required: cka/1.1\n", "required: [cka]\n", "required: [cka/1.1, cka/1.1]\n", "scope: [cka/1.1]\n",
    "required: [cka/1.1]\nfailed: {cka/1.1: x}\n", "failed: [a]\n",
])
def test_a_malformed_file_fails_loudly(tmp_path, body):
    with pytest.raises(kc_scope.ScopeError):
        kc_scope.load(_write(tmp_path, body))


def test_a_typo_fails_instead_of_dropping_a_lab_from_the_gate():
    sc = kc_scope.Scope(["cka", "ckda"], ["cka/1.1"])
    with pytest.raises(kc_scope.ScopeError, match="not in catalog.yaml"):
        kc_scope.check_known(sc, ["cka", "ckad"], ["cka/1.1"])
    with pytest.raises(kc_scope.ScopeError, match="do not exist"):
        kc_scope.check_known(kc_scope.Scope(["cka"], ["cka/1.1", "cka/7.7"]), ["cka"], ["cka/1.1"])


def test_fix_verb_detection():
    assert kc_scope.has_fix_verb('case "$1" in\n  verify) v ;;\n  fix)    fix_lab ;;\nesac\n')
    assert not kc_scope.has_fix_verb("# fix) in a comment\nverify) v ;;\n")


def test_labs_with_a_fix_verb_or_a_fix_file_are_provable():
    got = cli.provable_labs(KD, kc_scope.load(TRACKS))
    assert ("cka", "1.1") in got and ("lpic-2", "200.1") in got   # fix files
    assert ("ckad", "4.4") in got and ("ckad", "5.2") in got      # fix verb in the script
    assert ("cka", "1.2") not in got                              # nothing to prove it with: loaded-untested


def test_the_plan_marks_only_the_allowlist_as_required(capsys):
    assert cli.main(["test", "--target", "killercoda", "--plan", "--today", "2026-10-16"]) == 0
    rows = {m["lab"]: m["required"] for m in json.loads(capsys.readouterr().out)}
    sc = kc_scope.load(TRACKS)
    assert rows["cka/1.1"] is True and rows["lpic-2/200.1"] is False
    assert {k for k, v in rows.items() if v} == set(sc.required) & set(rows)


def test_publish_gate_refuses_a_scenario_without_passing_evidence_for_any_cert():
    """Untested never reaches the mirror, whatever the certification: no tested.json, no scenario."""
    labs, _ = kc.select(ROOT, ["cka"])
    gated: list = []
    files = kc.tree(labs[:3], kc.cert_names(ROOT), True, {}, {}, "2026-10-16", gated, decorate=True)
    assert len(gated) == 3 and not [k for k in files if k.startswith("cka/")]
    assert not any(k.endswith("tested.json") for k in files)


def test_workflows_name_no_lab_they_read_the_plan():
    """The scope is data (tracks.yaml). A workflow that lists labs or certs by hand drifts from it."""
    for name in ("killercoda-parity.yml", "killercoda-publish.yml"):
        text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
        assert "--plan" in text and "fromJSON(needs.plan.outputs.labs)" in text, name
        assert "continue-on-error: ${{ !matrix.required }}" in text, name
        assert not re.search(r"lab:\s*'?(cka|ckad|lpic)", text), f"{name} lists a lab by hand"


def test_lpic_2_stays_in_the_default_export():
    pilot = yaml.safe_load(TRACKS.read_text(encoding="utf-8"))["pilot"]
    assert "lpic-2/200.1" in pilot and "cka/1.1" in pilot
