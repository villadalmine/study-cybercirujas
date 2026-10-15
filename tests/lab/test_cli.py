"""CLI flows that need no Docker: new (scaffold), validate, migrate, list, resolve (curated, local, --from)."""
import json

import yaml

from conftest import REPO, git_repo, run_cli
from teach.lab import cli, spec


def test_new_scaffold_passes_strict_validate(new_lab):
    for requires in ("linux", "kind"):
        d = new_lab(requires=requires, name=f"lab-{requires}")
        assert run_cli("validate", str(d), "--strict") == 0
        lab = spec.load(d)
        assert lab.spec["requires"] == requires and lab.contract_ok
        assert b"\r\n" not in (d / "break_fix.sh").read_bytes()
        assert b"\r\n" not in (d / "lab.yaml").read_bytes()


def test_new_never_overwrites(new_lab):
    d = new_lab()
    (d / "lab.yaml").write_text((d / "lab.yaml").read_text() + "x-mine: 1\n")
    assert run_cli("new", str(d), "--cert", "a", "--topic", "1", "--title", "t") == 0
    assert "x-mine" in (d / "lab.yaml").read_text()


def test_validate_tree_report(new_lab, tmp_path):
    new_lab(name="a")
    bad = new_lab(name="b")
    data = yaml.safe_load((bad / "lab.yaml").read_text())
    data["requires"] = "vm"
    (bad / "lab.yaml").write_text(yaml.safe_dump(data))
    report = tmp_path / "r.json"
    assert run_cli("validate", str(tmp_path), "--report", str(report)) == 1
    r = json.loads(report.read_text())
    assert r["total"] == 2 and r["schema_ok"] == 1


def test_validate_strict_fails_without_verify(tmp_path):
    (tmp_path / "lab.yaml").write_text("cert: a\ntopic: '1'\ntitle: t\n")
    (tmp_path / "break_fix.sh").write_text("#!/bin/bash\necho broken\n")
    assert run_cli("validate", str(tmp_path)) == 0
    assert run_cli("validate", str(tmp_path), "--strict") == 1


def test_migrate_write_roundtrip(tmp_path):
    (tmp_path / "lab.yaml").write_text("cert: a\ntopic: '1'\ntitle: t\nsetup: [break_fix.sh]\n")
    (tmp_path / "break_fix.sh").write_text('case "$1" in break) :;; verify) :;; cleanup) :;; esac\n')
    assert run_cli("migrate", str(tmp_path), "--write") == 0
    lab = spec.load(tmp_path)
    assert lab.spec["schema_version"] == 2 and lab.errors == [] and lab.contract_ok


def test_resolve_curated_and_local(new_lab):
    lab = cli.resolve(["cka", "1.1"], None)
    assert lab.origin == "curated" and lab.directory == REPO / "certs" / "cka" / "1.1" / "lab"
    assert cli.resolve([str(new_lab())], None).origin == "local"


def test_resolve_from_git_repo_is_idempotent(new_lab, tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "CACHE", tmp_path / "cache")
    new_lab(name="repo/labs/demo")
    repo = git_repo(tmp_path / "repo")
    lab = cli.resolve(["labs/demo"], f"file://{repo}")
    assert lab.origin == "community" and lab.errors == []
    assert lab.source.startswith(f"file://{repo}@")
    again = cli.resolve(["labs/demo"], f"file://{repo}")  # second fetch reuses the clone
    assert again.directory == lab.directory


def test_from_repo_path_cannot_escape(new_lab, tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "CACHE", tmp_path / "cache")
    new_lab(name="repo/labs/demo")
    repo = git_repo(tmp_path / "repo")
    assert run_cli("run", "--from", f"file://{repo}", "../../..") == 2


def test_curated_pilot_labs_are_strict_valid_and_verified():
    for t in ("1.1", "3.3", "3.4", "3.5"):
        d = REPO / "certs" / "cka" / t / "lab"
        assert run_cli("validate", str(d), "--strict") == 0
        assert spec.load(d).verified


def test_all_curated_labs_pass_the_schema():
    """Backward compatibility: every lab.yaml in the repo validates (v1 or v2)."""
    assert run_cli("validate", str(REPO / "certs")) == 0


def test_hint_and_list(capsys):
    assert run_cli("hint", "cka", "1.1", "-n", "2") == 0
    assert "pista 2/" in capsys.readouterr().out
    assert run_cli("list", "cka") == 0
    assert "1.1" in capsys.readouterr().out


def test_new_in_certs_declares_where_the_lab_comes_from(tmp_path):
    # Review of #10: `study-lab new` wrote v2 without derived_from, which
    # check_source_chain.py fails at once for a lab in certs/.
    topic = tmp_path / "certs" / "demo" / "1.1"
    (topic / "en").mkdir(parents=True)
    (topic / "en" / "content.md").write_text("# T\n", encoding="utf-8")
    assert run_cli("new", str(topic / "lab"), "--cert", "demo", "--topic", "1.1",
                   "--title", "Demo lab", "--requires", "linux") == 0
    import yaml
    from teach.core import certs as core_certs
    doc = yaml.safe_load((topic / "lab" / "lab.yaml").read_text(encoding="utf-8"))
    assert doc["derived_from"] == {"syllabus": "certs/demo.md#1.1", "content": "certs/demo/1.1/en/content.md",
                                   "content_sha256": core_certs.chain_sha256(topic / "en" / "content.md")}


def test_new_outside_certs_has_no_derived_from(new_lab):
    import yaml
    assert "derived_from" not in yaml.safe_load((new_lab() / "lab.yaml").read_text(encoding="utf-8"))
