"""study-lab never adopts or deletes a container it did not create.

run() recreates, down() removes and check/shell/exec enter containers by name;
a container holding the name without the study-lab=1 label is someone else's
(manual review of the labs-runner PR, and review of PR #2). No Docker needed: docker calls are recorded, not executed.
"""
import pytest

from teach.lab import runner


class FakeLab:
    lab_id = "cka/1.1"
    origin = "curated"
    source = "certs/cka/1.1/lab"
    contract = {"cleanup": ["cleanup"]}
    spec = {"timeout": {"cleanup": 5}}


@pytest.fixture
def docker_calls(monkeypatch):
    calls = []
    monkeypatch.setattr(runner, "_docker", lambda *a, **k: calls.append(a))
    return calls


@pytest.mark.parametrize("labels", [None, {}, {"study-lab": "0"}, {"owner": "student"}])
def test_down_refuses_a_foreign_container(monkeypatch, docker_calls, labels):
    monkeypatch.setattr(runner, "inspect", lambda name: {"State": {"Running": True},
                                                        "Config": {"Labels": labels}})
    with pytest.raises(runner.RunnerError, match="not created by study-lab"):
        runner.down(FakeLab())
    assert not any(a[:2] == ("rm", "-f") for a in docker_calls)


def test_run_refuses_a_foreign_container(monkeypatch, docker_calls):
    monkeypatch.setattr(runner, "inspect", lambda name: {"State": {"Running": True},
                                                        "Config": {"Labels": {}}})
    monkeypatch.setattr(runner, "spec_hash", lambda lab: "h")
    with pytest.raises(runner.RunnerError, match="not created by study-lab"):
        runner.run(FakeLab())
    assert not any(a[:2] == ("rm", "-f") for a in docker_calls)


@pytest.mark.parametrize("action", ["check", "shell", "exec"])
def test_check_shell_exec_refuse_a_foreign_container(monkeypatch, docker_calls, action):
    monkeypatch.setattr(runner, "inspect", lambda name: {"State": {"Running": True},
                                                        "Config": {"Labels": {}}})
    entered = []
    monkeypatch.setattr(runner, "_stream", lambda *a, **k: entered.append(a) or (0, ""))
    monkeypatch.setattr(runner.subprocess, "call", lambda *a, **k: entered.append(a) or 0)
    lab = FakeLab()
    lab.spec = {"timeout": {"verify": 5}, "env": {}, "script": "break_fix.sh",
                "run_in": "container", "run_as": "root", "requires": "kind"}
    lab.contract = {"verify": ["verify"]}
    with pytest.raises(runner.RunnerError, match="not created by study-lab"):
        if action == "check":
            runner.check(lab)
        elif action == "shell":
            runner.shell(lab)
        else:
            runner.shell(lab, ["id"])
    assert entered == []


def test_ours_passes_study_lab_containers():
    info = {"Config": {"Labels": {"study-lab": "1"}}}
    assert runner._ours("x", info) is info
    assert runner._ours("x", None) is None


@pytest.mark.parametrize("version", ["1.33", "1.38", "1.33.2"])
def test_run_refuses_a_kubernetes_minor_without_a_node_image(monkeypatch, docker_calls, version):
    # The schema accepts any 1.N; without a node image for it, kind used to run
    # the pinned default silently.
    lab = FakeLab()
    lab.spec = {"requires": "kind", "kubernetes": version, "timeout": {}}
    with pytest.raises(runner.RunnerError, match=r"not available.*1\.34, 1\.35, 1\.36, 1\.37"):
        runner.run(lab)
    assert docker_calls == []


@pytest.mark.parametrize("version,tag", [("1.35", "v1.35.8"), ("1.34.2", "v1.34.11"), ("", "")])
def test_node_image_for_supported_minors(version, tag):
    lab = FakeLab()
    lab.spec = {"requires": "kind", "kubernetes": version}
    assert tag in runner.node_image(lab)
