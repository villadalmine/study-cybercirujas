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
