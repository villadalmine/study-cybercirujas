"""lab.yaml v2 schema: valid and invalid cases, v1 compatibility, migration."""
import pytest
import yaml

from teach.lab import spec

V1 = {"cert": "cka", "topic": "1.1", "title": "x", "provider": "local",
      "resources": {"vms": [{"name": "lab", "os": "debian-12", "cpus": 1, "ram_mb": 1024}]},
      "setup": ["break_fix.sh"]}
SCRIPT_BVC = '#!/usr/bin/env bash\ncase "$1" in\n  break) kubectl get ns;;\n  verify) true;;\n  cleanup) true;;\nesac\n'


def write(directory, data, script=SCRIPT_BVC, name="break_fix.sh"):
    (directory / "lab.yaml").write_text(yaml.safe_dump(data), encoding="utf-8")
    if script is not None:
        (directory / name).write_bytes(script.encode())
    return directory


def test_v1_file_validates_unchanged(tmp_path):
    lab = spec.load(write(tmp_path, V1))
    assert lab.errors == []
    assert lab.spec["schema_version"] == 1
    assert lab.spec["requires"] == "kind"  # inferred: the script uses kubectl
    assert lab.contract_ok


def test_v1_without_kubectl_is_linux(tmp_path):
    lab = spec.load(write(tmp_path, V1, script="#!/bin/bash\necho hi\n"))
    assert lab.spec["requires"] == "linux"
    assert lab.contract["break"] == []  # breaks when called without args
    assert lab.contract["verify"] is None and not lab.contract_ok


def test_full_v2_validates(tmp_path):
    data = dict(V1, schema_version=2, requires="kind", kubernetes="1.35", nodes=1,
                modes={"break": {"args": ["break"]},
                       "verify": {"args": ["check"], "success": {"output_regex": "OK"}},
                       "cleanup": {"args": ["clean"], "stdin": "y\n"}},
                env={"FORCE": "1"}, ports=[{"container": 8080}], limits={"ram_mb": 2048, "cpus": 2},
                timeout={"up": 300}, hints=["a"], level="beginner", goals={"fix": ["a", "b"], "solved": "c"},
                origin={"kind": "community", "repo": "https://example.org/x"},
                verified={"status": True, "date": "2026-10-15", "method": "runner"},
                license="MIT", **{"x-anything": {"free": True}})
    lab = spec.load(write(tmp_path, data))
    assert lab.errors == []
    assert lab.contract == {"break": ["break"], "verify": ["check"], "cleanup": ["clean"]}
    assert lab.verified


@pytest.mark.parametrize("patch,needle", [
    ({"requires": "vm"}, "requires"),
    ({"unknown_key": 1}, "unknown_key"),
    ({"level": "expert"}, "level"),
    ({"kubernetes": "latest"}, "kubernetes"),
    ({"ports": [{"container": 70000}]}, "ports"),
    ({"verified": {"date": "2026-10-15"}}, "status"),
    ({"modes": {"verify": {"args": "verify"}}}, "modes"),
    ({"schema_version": 3}, "schema_version"),
    ({"goals": {"fix": []}}, "goals"),
    ({"goals": {"solved": "x"}}, "goals"),
    ({"goals": {"fix": ["a"], "extra": 1}}, "goals"),
])
def test_invalid_cases(tmp_path, patch, needle):
    lab = spec.load(write(tmp_path, dict(V1, **patch)))
    assert lab.errors, f"{patch} should not validate"
    assert any(needle in e for e in lab.errors), lab.errors


def test_missing_required_field(tmp_path):
    data = dict(V1)
    del data["title"]
    assert any("title" in e for e in spec.load(write(tmp_path, data)).errors)


def test_missing_script(tmp_path):
    assert any("does not exist" in e for e in spec.load(write(tmp_path, V1, script=None)).errors)


def test_crlf_script_rejected(tmp_path):
    lab = spec.load(write(tmp_path, V1, script=SCRIPT_BVC.replace("\n", "\r\n")))
    assert any("CRLF" in e for e in lab.errors)


def test_script_cannot_escape_lab_dir(tmp_path):
    lab_dir = tmp_path / "lab"
    lab_dir.mkdir()
    (tmp_path / "evil.sh").write_text("echo")
    lab = spec.load(write(lab_dir, dict(V1, schema_version=2, script="../evil.sh"), script=None))
    assert any("escapes" in e for e in lab.errors)


def test_numeric_topic_rejected(tmp_path):
    assert spec.load(write(tmp_path, dict(V1, topic=1.1))).errors


def test_migrate_v1_to_v2_validates(tmp_path):
    lab = spec.load(write(tmp_path, V1))
    out = spec.migrate(lab)
    assert out["schema_version"] == 2 and out["requires"] == "kind"
    assert out["modes"]["verify"] == {"args": ["verify"]}
    assert spec.schema_errors(out) == []


def test_verbs_detected_in_existing_styles():
    s = 'case "$1" in\n  check) x;;\n  clean) y;;\nesac\n'
    c = spec.infer_contract(s)
    assert c["verify"] == ["check"] and c["cleanup"] == ["clean"]


def test_declared_modes_override_inference(tmp_path):
    data = dict(V1, schema_version=2, modes={"cleanup": {"args": ["--restore"]}})
    lab = spec.load(write(tmp_path, data))
    assert lab.contract["cleanup"] == ["--restore"]
