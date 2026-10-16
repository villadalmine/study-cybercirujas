"""The Killercoda publish gate: environment schedule, evidence tied to the scenario hash and to today's versions."""
import json

from teach.lab import export_killercoda as kc
from teach.lab import kc_test, spec

from conftest import REPO

FX = REPO / "tests" / "fixtures" / "lab_kc"


def _scenario():
    return kc.scenario(spec.load(FX / "kind", "curated"))


def _ev(files, day, result="pass"):
    image = json.loads(files["index.json"])["backend"]["imageid"]
    stages = {n: {"ok": True} for n in "abcdef"}
    measured = {k: v for k, v in kc_test.resolve_env(image, day).items() if k != "parity"}
    return kc_test.evidence(files, image, stages, {"kind": "local"}, day, measured) | {"result": result}


def test_k8s_version_follows_the_schedule():
    assert kc_test.resolve_env("kubernetes-kubeadm-1node", "2026-10-16")["kubernetes"].startswith("1.36")
    assert kc_test.resolve_env("kubernetes-kubeadm-1node", "2026-10-25")["kubernetes"].startswith("1.37")
    assert kc_test.resolve_env("ubuntu", "2026-10-16")["parity"] == "assumed"   # nothing is `measured` yet


def test_gate_needs_the_same_scenario_and_todays_environment():
    files = _scenario()
    ev = _ev(files, "2026-10-16")
    assert kc_test.valid_for(ev, files, "kubernetes-kubeadm-1node", "2026-10-16")
    assert not kc_test.valid_for(ev, files, "kubernetes-kubeadm-1node", "2026-10-26")   # Killercoda moved to 1.37: retest
    assert not kc_test.valid_for(_ev(files, "2026-10-16", "fail"), files, "kubernetes-kubeadm-1node", "2026-10-16")
    assert not kc_test.valid_for(None, files, "kubernetes-kubeadm-1node", "2026-10-16")
    changed = dict(files, **{"verify.sh": files["verify.sh"] + "\n# edited\n"})
    assert not kc_test.valid_for(ev, changed, "kubernetes-kubeadm-1node", "2026-10-16")


def test_gate_compares_what_was_measured_not_what_was_planned():
    files = _scenario()
    ev = _ev(files, "2026-10-16")
    assert kc_test.valid_for(ev, files, "kubernetes-kubeadm-1node", "2026-10-16")
    drift = dict(ev, env=dict(ev["env"], kubernetes="1.37.1"))   # the cluster that really ran was newer than the plan
    assert not kc_test.valid_for(drift, files, "kubernetes-kubeadm-1node", "2026-10-16")
    assert not kc_test.valid_for(dict(ev, env={k: v for k, v in ev["env"].items() if k != "cni"}), files, "kubernetes-kubeadm-1node", "2026-10-16")
    assert ev["expected"]["kubernetes"] == "1.36.5" and ev["env"]["kubernetes"] == "1.36.5"


def test_hash_ignores_evidence_files():
    files = _scenario()
    assert kc_test.sha256_of(files) == kc_test.sha256_of(dict(files, **{"tested.json": "{}", "metadata.json": "{}"}))


def test_export_publishes_only_what_has_evidence():
    labs = [spec.load(FX / "kind", "curated")]
    files = _scenario()
    gated: list = []
    out = kc.tree(labs, None, False, None, {}, "2026-10-16", gated)
    assert gated and not any(k.startswith("democert/") and k.endswith("index.json") for k in out)
    d = kc.slug("1.2", "Demo kind lab")
    out = kc.tree(labs, None, False, None, {f"democert/{d}": _ev(files, "2026-10-16")}, "2026-10-16", gated)
    assert f"democert/{d}/tested.json" in out and f"democert/{d}/index.json" in out
