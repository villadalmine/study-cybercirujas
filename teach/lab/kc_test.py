"""study-lab test --target killercoda: run a GENERATED scenario the way Killercoda does, and write the evidence.

Meant for a machine that looks like a Killercoda host: an Ubuntu 24.04 VM where you are root (a GitHub-hosted
ubuntu-24.04 runner, or `make killercoda-test` in a local VM). For the kubernetes image the cluster comes from
deploy/killercoda/bootstrap-kubeadm.sh with the versions pinned in killercoda_envs.yaml.

Flow: assets -> /root, background.sh, wait for /tmp/finished, verify.sh must FAIL, the reference fix
(deploy/killercoda/fixes/<cert>-<topic>.sh), verify.sh must PASS, cleanup.sh twice (it must be idempotent).
Evidence: tested.json, tied to the sha256 of the scenario and to the environment versions.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from . import export_killercoda as kc

TOOL = "study-lab-test-killercoda/1"
EVIDENCE = "tested.json"
SKIP_IN_HASH = {EVIDENCE, "metadata.json"}


def sha256_of(files: dict[str, str]) -> str:
    h = hashlib.sha256()
    for rel in sorted(f for f in files if f not in SKIP_IN_HASH):
        h.update(rel.encode() + b"\0" + files[rel].encode("utf-8") + b"\0")
    return h.hexdigest()


def resolve_env(image: str, today: str) -> dict:
    """The environment Killercoda runs for `image` on `today`: pinned versions and how sure we are (parity)."""
    spec_ = kc.load_envs()["images"][image]
    env = {"image": image, "os": spec_["os"]["version"]}
    if "kubernetes" in spec_:
        row = next((r for r in spec_["kubernetes"] if r["from"] <= today < r.get("until", "9999-12-31")), None)
        if row is None:
            raise ValueError(f"killercoda_envs.yaml: no kubernetes schedule row of image {image!r} covers {today}; add or extend one")
        env["kubernetes"] = row["patch"]
    for k in ("runtime", "cni"):
        if k in spec_:
            env[k] = spec_[k]["name"] + (" " + spec_[k]["version"] if "version" in spec_[k] else "")
    facts = [v for v in spec_.values() if isinstance(v, dict) and "status" in v] + spec_.get("kubernetes", [])
    env["parity"] = "measured" if all(f["status"] == "measured" for f in facts) else "assumed"
    return env


def measure(image: str) -> dict:
    """What the host really is, read from the host: OS, and for the k8s image the server version, runtime and CNI."""
    osr = dict(l.split("=", 1) for l in Path("/etc/os-release").read_text().splitlines() if "=" in l)
    env = {"image": image, "os": osr.get("VERSION_ID", "").strip('"')}
    if image.startswith("kubernetes"):
        def run(*cmd):
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            return p.stdout if p.returncode == 0 else ""
        server = (json.loads(run("kubectl", "version", "-o", "json") or "{}").get("serverVersion") or {}).get("gitVersion", "")
        env["kubernetes"] = server.lstrip("v")
        env["runtime"] = "containerd" if run("containerd", "--version").startswith("containerd") else ""
        images = run("kubectl", "get", "ds", "-A", "-o", "jsonpath={range .items[*]}{.spec.template.spec.containers[0].image}{\"\\n\"}{end}")
        flannel = next((i for i in images.split() if "flannel" in i), "")
        env["cni"] = f"flannel {flannel.rpartition(':')[2]}" if flannel else ""
    return env


def _sh(cmd: list[str], timeout: int, extra_env: dict | None = None) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env={**os.environ, **(extra_env or {})})
        return p.returncode, (p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {timeout}s: {' '.join(cmd)}"


def run_scenario(scen: Path, fix: Path, root: Path = Path("/root")) -> dict:
    """The stages, in order. `scen` is a generated scenario directory; returns {stage: {ok, seconds, rc, tail}}."""
    stages: dict = {}

    def stage(name: str, ok_if, cmd: list[str], timeout: int = 900, poll: int = 0) -> bool:
        t0, deadline = time.time(), time.time() + (poll or 0)
        while True:
            rc, out = _sh(cmd, timeout)
            ok = ok_if(rc)
            if ok or time.time() >= deadline:
                break
            time.sleep(5)
        stages[name] = {"ok": ok, "rc": rc, "seconds": round(time.time() - t0, 1), **({} if ok else {"tail": out[-1500:]})}
        return ok

    for f in (scen / "assets").glob("*"):
        shutil.copy(f, root / f.name)
    for marker in ("/tmp/finished", "/tmp/study-lab-setup-failed"):
        Path(marker).unlink(missing_ok=True)
    verify = ["bash", str(scen / "verify.sh")]
    ok = stage("background", lambda rc: rc == 0 and not Path("/tmp/study-lab-setup-failed").exists() and Path("/tmp/finished").exists(),
               ["bash", str(scen / "background.sh")], 1200)
    ok = ok and stage("verify_fails_when_broken", lambda rc: rc != 0, verify, 300)
    ok = ok and stage("reference_fix", lambda rc: rc == 0, ["bash", str(fix)], 600)
    ok = ok and stage("verify_passes_when_fixed", lambda rc: rc == 0, verify, 300, poll=120)
    ok = ok and stage("cleanup", lambda rc: rc == 0, ["bash", str(scen / "cleanup.sh")], 600)
    ok = ok and stage("cleanup_twice", lambda rc: rc == 0, ["bash", str(scen / "cleanup.sh")], 600)
    return stages


def evidence(files: dict[str, str], image: str, stages: dict, runner: dict, today: str, measured: dict) -> dict:
    """`env` is what the host MEASURED; `expected` is what killercoda_envs.yaml said it should be on that date."""
    expected = resolve_env(image, today)
    return {"scenario_sha256": sha256_of(files), "env": {**measured, "parity": expected["parity"]}, "expected": expected, "runner": runner, "date": today,
            "tool": TOOL, "result": "pass" if stages and all(s["ok"] for s in stages.values()) and len(stages) == 6 else "fail",
            "stages": stages}


def runner_info() -> dict:
    if os.environ.get("GITHUB_RUN_ID"):
        return {"kind": "ci", "url": f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"}
    return {"kind": "local", "host": os.uname().nodename}


def valid_for(ev: dict | None, files: dict[str, str], image: str, today: str) -> bool:
    """The publish gate: a pass for THIS scenario and for the environment Killercoda runs today, on a measured basis or not."""
    if not ev or ev.get("result") != "pass" or ev.get("scenario_sha256") != sha256_of(files):
        return False
    now, got = resolve_env(image, today), ev.get("env") or {}
    # the MEASURED versions must be the ones Killercoda runs today (the runtime is compared by name only)
    return all((got.get(k) or "").split(" ")[0] == v.split(" ")[0] if k == "runtime" else got.get(k) == v
               for k, v in now.items() if k != "parity")


def today() -> str:
    return datetime.date.today().isoformat()
