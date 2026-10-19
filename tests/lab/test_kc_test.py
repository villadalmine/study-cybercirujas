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
    rows = kc.load_envs()["images"]["kubernetes-kubeadm-1node"]["kubernetes"]   # the 1.37 row cannot resolve until a Cilium lists it
    assert rows[1]["from"] == "2026-10-25" and rows[1]["minor"] == "1.37"
    assert kc_test.resolve_env("ubuntu", "2026-10-16")["parity"] == "measured"   # probe of 2026-10-19
    # the Cilium version was not printed by the probe: assumed, so the image is only partially measured
    assert kc_test.resolve_env("kubernetes-kubeadm-1node", "2026-10-16")["parity"] == "partially-measured"


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
    assert ev["expected"]["kubernetes"] == "1.36.1" and ev["env"]["kubernetes"] == "1.36.1"
    assert ev["env"]["cni"] == "cilium v1.20.3" and ev["env"]["runtime"] == "containerd 2.2.1"   # measured, not flannel


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


def test_a_k8s_row_without_a_compatible_cilium_fails_loudly():
    import pytest
    # 1.37 starts on 2026-10-25 and no Cilium release lists it yet: resolve_env must raise, not pin a wrong CNI
    with pytest.raises(LookupError, match="1.37"):
        kc_test.resolve_env("kubernetes-kubeadm-1node", "2026-10-26")
    files = _scenario()
    assert not kc_test.valid_for(_ev(files, "2026-10-16"), files, "kubernetes-kubeadm-1node", "2026-10-26")


def test_print_env_gives_the_three_bootstrap_arguments():
    from teach.lab import cli
    assert cli.main(["test", "--target", "killercoda", "--print-env", "kubernetes-kubeadm-1node", "--today", "2026-10-16"]) == 0


def test_every_bootstrap_call_site_passes_the_three_values_from_print_env():
    import re
    calls = 0
    for wf in (REPO / ".github" / "workflows").glob("*.yml"):
        text = wf.read_text(encoding="utf-8")
        for m in re.finditer(r"bootstrap-kubeadm\.sh([^\n]*)", text):
            calls += 1
            assert m.group(1).split() == ['"$patch"', '"$cilium"', '"$containerd"'], f"{wf.name}: {m.group(1)}"
            assert "read -r patch cilium containerd" in text and "--print-env" in text, wf.name
    assert calls >= 2


def test_measure_parsing_of_real_kubectl_output():
    out = "quay.io/cilium/cilium:v1.20.3@sha256:abc\nquay.io/cilium/cilium-envoy:v1.35.0@sha256:def\n"
    assert kc_test.parse_cni(out) == "cilium v1.20.3"
    assert kc_test.parse_cni("quay.io/flannel/flannel:v0.28.10\n") == ""
    # kubectl's jsonpath wants backslash-n inside the quotes; a real newline is "unterminated quoted string"
    assert chr(10) not in kc_test.DS_IMAGES and kc_test.DS_IMAGES.endswith("{'" + chr(92) + "n'}{end}")
