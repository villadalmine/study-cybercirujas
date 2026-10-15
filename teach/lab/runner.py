"""Docker side of study-lab: one container per lab, everything inside it.

The host only ever runs `docker` and `git clone`; the lab's script, its
cluster and whatever it breaks live in the container (and, for kind labs, in
the container's own dockerd). Every public function converges to a state, so
calling it twice gives the same result.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path

from .spec import Lab

IMAGE_PREFIX = os.environ.get("STUDY_LAB_IMAGE_PREFIX", "study-lab")
IMAGES = {"kind": "k8s", "k3s": "k8s", "linux": "linux"}
CACHE_VOLUME = "study-lab-cache"
STATE_FILE = "/run/study-lab.state"
REPO_ROOT = Path(os.environ.get("STUDY_REPO", Path(__file__).resolve().parents[2]))
IMAGES_DIR = REPO_ROOT / "deploy" / "study-lab"

# From the kind v0.33.0 release notes (the version pinned in deploy/study-lab/k8s).
KIND_NODES = {
    "1.37": "kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5",
    "1.36": "kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed",
    "1.35": "kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0",
    "1.34": "kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d",
}


class RunnerError(Exception):
    pass


def _docker(*args: str, check: bool = False, capture: bool = True, **kw) -> subprocess.CompletedProcess:
    if shutil.which("docker") is None:
        raise RunnerError("docker is not installed (https://docs.docker.com/get-docker/)")
    res = subprocess.run(["docker", *args], capture_output=capture, text=True, **kw)
    if check and res.returncode != 0:
        raise RunnerError(f"docker {' '.join(args[:2])} failed: {(res.stderr or '').strip()}")
    return res


def image_for(lab: Lab) -> str:
    return f"{IMAGE_PREFIX}:{IMAGES[lab.spec['requires']]}"


def container_name(lab: Lab) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", lab.lab_id.lower()).strip("-")
    if lab.origin == "curated":
        return f"study-lab-{slug}"
    tag = hashlib.sha256(lab.source.encode()).hexdigest()[:6]
    return f"study-lab-{'ext' if lab.origin == 'community' else 'local'}-{tag}-{slug}"


def spec_hash(lab: Lab) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in lab.directory.rglob("*") if p.is_file()):
        h.update(f.relative_to(lab.directory).as_posix().encode())
        h.update(f.read_bytes())
    h.update(image_for(lab).encode())
    return h.hexdigest()[:16]


def inspect(name: str) -> dict | None:
    res = _docker("inspect", name)
    if res.returncode != 0:
        return None
    return json.loads(res.stdout)[0]


def _ours(name: str, info: dict | None) -> dict | None:
    """`info` if the container is a study-lab one; refuse to touch it otherwise.

    run() recreates, down() removes and check/shell/exec enter containers by
    name. A container that holds the name but was not created by study-lab (no
    `study-lab=1` label) is someone else's work: never adopted, entered or deleted.
    """
    if info and (info.get("Config", {}).get("Labels") or {}).get("study-lab") != "1":
        raise RunnerError(f"a container named {name} exists but was not created by study-lab "
                          "(no study-lab=1 label); not touching it — rename or remove it yourself")
    return info


def ensure_image(lab: Lab) -> str:
    image = image_for(lab)
    if _docker("image", "inspect", image).returncode == 0:
        return image
    print(f"[study-lab] image {image} not found locally; trying docker pull")
    if _docker("pull", image, capture=False).returncode == 0:
        return image
    build(IMAGES[lab.spec["requires"]])
    return image


def build(family: str) -> None:
    ctx = IMAGES_DIR / family
    if not (ctx / "Dockerfile").is_file():
        raise RunnerError(f"cannot build {IMAGE_PREFIX}:{family}: no {ctx}/Dockerfile")
    print(f"[study-lab] building {IMAGE_PREFIX}:{family} from {ctx}")
    res = _docker("build", "-t", f"{IMAGE_PREFIX}:{family}", str(ctx), capture=False)
    if res.returncode != 0:
        raise RunnerError(f"docker build {family} failed")


# Seconds the host waits beyond a phase's timeout before it gives up on the
# `docker exec` client: the `timeout` wrapper inside the container fires first.
GRACE = 15


def _in_time(timeout: int, cmd: list[str]) -> list[str]:
    """`cmd` under coreutils `timeout` INSIDE the container (all three images have it).

    timeout runs the command in its own process group and signals the whole
    group, so `kind create`, `kubectl wait` or a `sleep` started by the script
    die with it; killing only the host's `docker exec` client would leave them
    running in the container.
    """
    return ["timeout", "-k", "10", str(timeout), *cmd]


def _stream(cmd: list[str], stdin: str, timeout: int, quiet: bool = False,
            on_timeout=None) -> tuple[int, str]:
    """Run, echo output live, and return (exit code, full output).

    The deadline holds even while the child prints nothing: stdout is read in a
    thread and the main thread waits on the process. On expiry `on_timeout()`
    runs (to stop what runs inside the container), the client is killed and the
    exit code is 124, like coreutils timeout.
    """
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    try:
        proc.stdin.write(stdin)
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    out: list[str] = []

    def pump():
        for line in proc.stdout:
            out.append(line)
            if not quiet:
                sys.stdout.write(line)
                sys.stdout.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if on_timeout:
            try:
                on_timeout()
            except Exception as exc:  # best effort: the client is killed anyway
                out.append(f"[study-lab] could not stop the process inside the container: {exc}\n")
        proc.kill()
        proc.wait()
        code = 124
    reader.join(timeout=5)
    if code == 124:
        msg = f"\n[study-lab] timeout after {timeout}s\n"
        out.append(msg)
        if not quiet:
            sys.stdout.write(msg)
    return code, "".join(out)


def _mode_cmd(lab: Lab, name: str, action: str) -> tuple[list[str], str]:
    mode = (lab.spec.get("modes") or {}).get(action) or {}
    args = lab.contract.get(action)
    if args is None:
        raise RunnerError(f"this lab's script has no '{action}' mode (declare it under modes.{action} in lab.yaml)")
    env = dict(lab.spec["env"])
    env.update(mode.get("env") or {})
    script = f"/lab/{lab.spec['script']}"
    env_flags = [x for k, v in env.items() for x in ("-e", f"{k}={v}")]
    script_cmd = _in_time(lab.spec["timeout"][action], ["bash", script, *args])
    if lab.spec["run_in"] == "node":
        inner = ["docker", "exec", "-i", *env_flags, "-w", "/lab", "lab-control-plane", *script_cmd]
        cmd = ["docker", "exec", "-i", name, *inner]
    else:
        user = lab.spec["run_as"]
        cmd = ["docker", "exec", "-i", *env_flags, "-e", f"STUDY_LAB_ID={lab.lab_id}",
               "-u", user, "-w", "/lab", name, *script_cmd]
    return cmd, mode.get("stdin", "")


def _killer(lab: Lab, name: str, pattern: str):
    """on_timeout for _stream: stop `pattern` inside the lab container (and the kind node)."""
    def kill() -> None:
        _docker("exec", name, "pkill", "-KILL", "-f", pattern)
        if lab.spec.get("run_in") == "node":
            _docker("exec", name, "docker", "exec", "lab-control-plane", "pkill", "-KILL", "-f", pattern)
    return kill


def _run_mode(lab: Lab, name: str, action: str) -> tuple[int, str]:
    cmd, stdin = _mode_cmd(lab, name, action)
    return _stream(cmd, stdin, lab.spec["timeout"][action] + GRACE,
                   on_timeout=_killer(lab, name, f"/lab/{lab.spec['script']}"))


def _state(name: str) -> str:
    res = _docker("exec", name, "cat", STATE_FILE)
    return res.stdout.strip() if res.returncode == 0 else ""


def run(lab: Lab) -> int:
    name = container_name(lab)
    h = spec_hash(lab)
    info = _ours(name, inspect(name))
    if info and info["State"]["Running"] and info["Config"]["Labels"].get("study-lab.hash") == h:
        if _state(name) == "broken":
            print(f"[study-lab] {name} is already up and broken (same lab, nothing to do).")
            _next_steps(lab)
            return 0
    elif info:
        print(f"[study-lab] {name} exists but is stale or stopped: recreating it")
        _docker("rm", "-f", "-v", name, check=True)
        info = None

    image = ensure_image(lab)
    fam = lab.spec["requires"]
    if not info:
        flags = ["run", "-d", "--name", name, "--hostname", "lab",
                 "--label", "study-lab=1", "--label", f"study-lab.hash={h}",
                 "--label", f"study-lab.lab={lab.lab_id}", "--label", f"study-lab.origin={lab.origin}",
                 "--label", f"study-lab.source={lab.source}",
                 "--memory", f"{lab.spec['limits']['ram_mb']}m", "--cpus", str(lab.spec["limits"]["cpus"])]
        if fam in ("kind", "k3s"):
            flags += ["--privileged", "-v", f"{CACHE_VOLUME}:/cache"]
        else:
            # systemd as PID 1 without --privileged: its own cgroup namespace,
            # writable only inside it (security-opt writable-cgroups, tested on Docker 29.8).
            flags += ["--cgroupns=private", "--security-opt", "writable-cgroups=true",
                      "--tmpfs", "/run", "--tmpfs", "/run/lock", "--tmpfs", "/tmp"]
        for p in lab.spec.get("ports") or []:
            flags += ["-p", f"127.0.0.1:{p.get('host', 0) or ''}:{p['container']}"]
        _docker(*flags, image, check=True)
        _docker("exec", name, "mkdir", "-p", "/lab", check=True)
        _docker("cp", f"{lab.directory}{os.sep}.", f"{name}:/lab", check=True)

    print(f"[study-lab] preparing the environment ({fam}) inside {name}")
    if fam in ("kind", "k3s"):
        node = KIND_NODES.get(".".join((lab.spec.get("kubernetes") or "").split(".")[:2]), "")
        init = ["study-lab-init", fam, str(lab.spec.get("nodes", 0))] + ([node] if node else [])
    else:
        init = ["study-lab-init"]
    up = lab.spec["timeout"]["up"]
    code, _ = _stream(["docker", "exec", name, *_in_time(up, init)], "", up + GRACE,
                      on_timeout=_killer(lab, name, "study-lab-init"))
    if code != 0:
        raise RunnerError(f"the environment did not come up (exit {code}); see above. 'study-lab down' cleans it.")
    if lab.spec["run_in"] == "node":
        _docker("exec", name, "docker", "cp", "/lab", "lab-control-plane:/", check=True)

    print(f"[study-lab] breaking the lab ({' '.join(lab.contract['break']) or 'no args'})")
    # Unknown until break finishes: a break that times out or fails must not
    # leave an older "broken" behind for the next run to trust.
    _docker("exec", name, "rm", "-f", STATE_FILE, check=True)
    code, _ = _run_mode(lab, name, "break")
    if code != 0:
        raise RunnerError(f"break failed (exit {code}); the lab is not in a known state. Try 'study-lab down' and run again.")
    _docker("exec", name, "sh", "-c", f"echo broken > {STATE_FILE}", check=True)
    _next_steps(lab)
    return 0


def _next_steps(lab: Lab) -> None:
    target = " ".join(lab.cli_args) if getattr(lab, "cli_args", None) else lab.lab_id
    print(f"\n[study-lab] listo. Entrá con:   study-lab shell {target}")
    print(f"[study-lab] verificá con:      study-lab check {target}")
    print(f"[study-lab] y limpiá con:      study-lab down {target}")


def _require_running(lab: Lab) -> str:
    name = container_name(lab)
    info = _ours(name, inspect(name))  # check/shell/exec never enter a container study-lab did not create
    if not info or not info["State"]["Running"]:
        raise RunnerError(f"{name} is not running: start it with 'study-lab run ...'")
    return name


def check(lab: Lab) -> int:
    name = _require_running(lab)
    code, out = _run_mode(lab, name, "verify")
    success = ((lab.spec.get("modes") or {}).get("verify") or {}).get("success") or {}
    ok = code == success.get("exit_code", 0)
    if ok and success.get("output_regex"):
        ok = re.search(success["output_regex"], out, re.M) is not None
    print(f"\n[study-lab] check: {'PASS' if ok else 'FAIL'}  (exit {code}"
          + (f", regex /{success['output_regex']}/ {'found' if ok else 'not found'}" if success.get("output_regex") else "") + ")")
    return 0 if ok else 1


def shell(lab: Lab, command: list[str] | None = None) -> int:
    name = _require_running(lab)
    env = ["-e", f"STUDY_LAB_ID={lab.lab_id}"]
    if command:
        return subprocess.call(["docker", "exec", "-i", *env, "-w", "/lab", name, *command])
    rc = ["--rcfile", "/etc/bash/study-lab.sh"] if lab.spec["requires"] != "linux" else ["-l"]
    tty = ["-it"] if sys.stdin.isatty() else ["-i"]
    return subprocess.call(["docker", "exec", *tty, *env, "-w", "/lab", name, "bash", *rc])


def down(lab: Lab, purge_cache: bool = False) -> int:
    name = container_name(lab)
    info = _ours(name, inspect(name))
    if info and info["State"]["Running"] and lab.contract.get("cleanup") is not None:
        print("[study-lab] running the lab's cleanup")
        _run_mode(lab, name, "cleanup")
    if info:
        _docker("rm", "-f", "-v", name, check=True)
        print(f"[study-lab] {name} removed (with its anonymous volumes: the inner dockerd and kind go with it)")
    else:
        print(f"[study-lab] {name} was not there (nothing to do)")
    left = _docker("ps", "-a", "--filter", f"name=^{name}$", "-q").stdout.strip()
    if left:
        raise RunnerError(f"{name} still exists after down")
    if purge_cache:
        _docker("volume", "rm", CACHE_VOLUME)
        print(f"[study-lab] cache volume {CACHE_VOLUME} removed")
    return 0


def running() -> list[dict]:
    res = _docker("ps", "-a", "--filter", "label=study-lab=1",
                  "--format", "{{.Names}}\t{{.Status}}\t{{.Label \"study-lab.origin\"}}\t{{.Label \"study-lab.source\"}}")
    rows = []
    for line in res.stdout.splitlines():
        n, st, origin, src = (line.split("\t") + ["", "", "", ""])[:4]
        rows.append({"name": n, "status": st, "origin": origin, "source": src})
    return rows
