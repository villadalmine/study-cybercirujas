"""study-lab never adopts or deletes a container it did not create.

run() recreates and down() removes containers by name; a container holding the
name without the study-lab=1 label is someone else's (manual review of the
labs-runner PR). No Docker needed: docker calls are recorded, not executed.
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


def test_ours_passes_study_lab_containers():
    info = {"Config": {"Labels": {"study-lab": "1"}}}
    assert runner._ours("x", info) is info
    assert runner._ours("x", None) is None
