"""Per-phase timeouts hold even when the lab prints nothing (review of PR #2).

The long phases are silent on purpose (`docker pull -q`, `kind create cluster
> /tmp/kind.log`, `kubectl wait > /dev/null`); a deadline checked only when a
line arrives never fires there. No Docker needed: _stream runs a plain process.
"""
import sys
import time

from teach.lab import runner

SILENT_SLEEP = [sys.executable, "-c", "import time; time.sleep(30)"]


def test_timeout_fires_while_the_child_is_silent():
    t0 = time.monotonic()
    code, out = runner._stream(SILENT_SLEEP, "", 1, quiet=True)
    assert time.monotonic() - t0 < 10
    assert code == 124
    assert "timeout after 1s" in out


def test_timeout_stops_what_runs_inside_the_container():
    killed = []
    code, _ = runner._stream(SILENT_SLEEP, "", 1, quiet=True, on_timeout=lambda: killed.append(1))
    assert code == 124
    assert killed == [1]


def test_the_message_names_the_phase_timeout_not_the_host_backstop():
    # lab.yaml says timeout.up: 600; the host waits 600 + GRACE. The student
    # must read 600 (review round 2 of PR #2).
    t0 = time.monotonic()
    code, out = runner._stream(SILENT_SLEEP, "", 1, quiet=True, grace=1)
    assert code == 124
    assert 1.5 < time.monotonic() - t0 < 10
    assert "timeout after 1s" in out and "2s" not in out


def test_a_child_that_exits_124_is_not_reported_as_a_timeout():
    code, out = runner._stream([sys.executable, "-c", "raise SystemExit(124)"], "", 30, quiet=True)
    assert code == 124
    assert "timeout after" not in out
    assert "ran out" in runner._why(124, "verify", 120) and "120s" in runner._why(124, "verify", 120)
    assert runner._why(1, "verify", 120) == "exit 1"


def test_a_stuck_on_timeout_does_not_hang_the_runner():
    # The backstop runs when the lab is wedged; a `docker exec ... pkill` into
    # it can block as well (review round 2 of PR #2).
    t0 = time.monotonic()
    code, out = runner._stream(SILENT_SLEEP, "", 1, quiet=True, grace=1, on_timeout=lambda: time.sleep(60))
    assert code == 124
    assert time.monotonic() - t0 < 15
    assert "could not stop the process inside the container" in out


def test_the_backstop_docker_exec_is_bounded(monkeypatch):
    calls = []
    monkeypatch.setattr(runner, "_docker", lambda *a, **k: calls.append(k))
    lab = Lab("node")
    runner._killer(lab, "study-lab-x", "/lab/break_fix.sh")()
    assert len(calls) == 2
    assert all(k.get("timeout") == runner.GRACE for k in calls)


def test_output_and_exit_code_pass_through():
    code, out = runner._stream([sys.executable, "-c", "print('a'); print('b'); raise SystemExit(3)"],
                               "", 30, quiet=True, on_timeout=lambda: (_ for _ in ()).throw(AssertionError))
    assert code == 3
    assert out.splitlines() == ["a", "b"]


class Lab:
    lab_id = "cka/1.1"
    contract = {"verify": ["verify"]}

    def __init__(self, run_in="container"):
        self.spec = {"env": {}, "script": "break_fix.sh", "run_in": run_in, "run_as": "root",
                     "timeout": {"verify": 42}, "modes": {}}


def test_scripts_run_under_timeout_inside_the_container():
    # The host-side kill only stops the `docker exec` client; the script and
    # its children must be stopped by `timeout` inside the container.
    for run_in in ("container", "node"):
        cmd, _ = runner._mode_cmd(Lab(run_in), "study-lab-x", "verify")
        i = cmd.index("timeout")
        assert cmd[i:i + 4] == ["timeout", "-k", "10", "42"]
        assert cmd[i + 4:] == ["bash", "/lab/break_fix.sh", "verify"]
