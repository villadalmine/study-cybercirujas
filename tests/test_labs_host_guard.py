"""`teach lab up` never runs a kubectl lab's script on the host unless --host is passed."""
import pytest
from typer.testing import CliRunner

from teach import cli
from teach.core import labs


@pytest.fixture
def cluster_lab(monkeypatch, tmp_path):
    (tmp_path / "break_fix.sh").write_text("#!/bin/bash\nkubectl get nodes\n")
    (tmp_path / "lab.yaml").write_text("provider: local\n")
    monkeypatch.setattr(labs, "lab_dir", lambda c, t: tmp_path)
    monkeypatch.setattr(labs, "_load_spec", lambda d: {"provider": "local"})
    monkeypatch.setattr(labs, "_write_status", lambda d, state, msg=None: {"state": state})
    calls = []
    monkeypatch.setattr(labs, "_up_cluster", lambda d, n: calls.append(("host", n)))
    return calls


def test_kubectl_lab_is_refused_by_default(cluster_lab):
    with pytest.raises(labs.LabError, match="study-lab run"):
        labs.up("cka", "1.1")
    assert cluster_lab == []


def test_host_flag_runs_it_with_a_loud_warning(cluster_lab, capsys):
    assert labs.up("cka", "1.1", host=True)["state"] == "running"
    assert cluster_lab == [("host", "teach-cka-1-1")]
    assert "DIRECTLY ON THIS MACHINE" in capsys.readouterr().err


def test_cli_exposes_host_flag(cluster_lab):
    runner = CliRunner()
    res = runner.invoke(cli.app, ["lab", "up", "cka", "1.1"])
    assert res.exit_code == 1 and cluster_lab == []
    res = runner.invoke(cli.app, ["lab", "up", "cka", "1.1", "--host"])
    assert res.exit_code == 0 and cluster_lab
