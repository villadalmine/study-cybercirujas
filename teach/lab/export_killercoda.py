"""study-lab export --target killercoda: lab.yaml + break/verify/cleanup scripts -> a Killercoda scenario tree.

An adapter, never a source: the lab stays the same code that runs in Docker or on your own cluster.
Pure and deterministic: no clock, no randomness, sorted keys, LF bytes (same input -> same bytes).
"""

from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

import yaml

from . import spec

SITE = "https://study.cybercirujas.club"
REPO = "https://github.com/villadalmine/study-cybercirujas"
IMAGES = {"linux": {0: "ubuntu"}, "kind": {0: "kubernetes-kubeadm-1node", 1: "kubernetes-kubeadm-2nodes"}}
IMAGES["k3s"] = IMAGES["kind"]
RULE = re.compile(r"^\s*#\s*[-=]{5,}\s*$")
SOLUTION = re.compile(r"^\s*#.*(SOLUCI[OÓ]N|SOLUTION)", re.I)
RPM = re.compile(r"^[^#\n]*\b(dnf|yum|rpm|zypper)\s+(install|-i|-q|-e|-U|erase|remove|update)", re.M)
FORBIDDEN = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY|AKIA(?![0-9A-Z]*EXAMPLE)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}"
                       r"|/home/(alumno|rino|dalmine)|/mnt/[a-z]/|C:\\Users|Nextcloud|\.super6c", re.I)


class ExportError(Exception):
    pass


def bash_n(text: str) -> int:
    """Exit code of `bash -n` on the script, fed as bytes with LF endings whatever the platform's text mode."""
    return subprocess.run(["bash", "-n"], input=text.replace("\r\n", "\n").encode("utf-8"), capture_output=True).returncode


def split_solution(text: str) -> tuple[str, str]:
    """(script without its trailing commented solution, the solution as plain text)."""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if SOLUTION.match(line) and all(not x.strip() or x.lstrip().startswith("#") for x in lines[i:]):
            sol = [re.sub(r"^\s*# ?", "", x) for x in lines[i:] if not RULE.match(x)]
            while i > 0 and RULE.match(lines[i - 1]):
                i -= 1
            return "\n".join(lines[:i]).rstrip("\n") + "\n", "\n".join(sol).strip("\n")
    return text, ""


def _fence(code: str) -> str:
    ticks = "`" * max(3, max((len(m) for m in re.findall(r"`+", code)), default=0) + 1)
    return f"{ticks}\n{code}\n{ticks}"


def _footer(lab: spec.Lab) -> str:
    c, t = lab.spec["cert"], lab.spec["topic"]
    return (f"\n---\nSource and full course: [study.cybercirujas.club]({SITE}) | "
            f"[lab code]({REPO}/tree/main/certs/{c}/{t}/lab)\n")


def _run_line(lab: spec.Lab, action: str) -> str:
    mode = (lab.spec.get("modes") or {}).get(action) or {}
    cmd = " ".join(["timeout", str(int(lab.spec["timeout"][action])), "bash", "./" + shlex.quote(lab.spec["script"]),
                    *[shlex.quote(a) for a in lab.contract[action]]])
    # never interactive: a confirmation prompt without a TTY would exit silently under `set -e`
    return f"printf %b {shlex.quote(mode['stdin'])} | {cmd}" if mode.get("stdin") else cmd + " </dev/null"


def _env(lab: spec.Lab) -> str:
    return "\n".join(f"export {k}={shlex.quote(str(v))}" for k, v in sorted(lab.spec["env"].items()))


def _verify_test(lab: spec.Lab) -> str:
    rx = (((lab.spec.get("modes") or {}).get("verify") or {}).get("success") or {}).get("output_regex")
    return '[ "$code" -eq 0 ]' + (f' && echo "$out" | grep -Eq -e {shlex.quote(rx)}' if rx else "")


def scenario(lab: spec.Lab, allow_unverified: bool = False, needs: tuple = ()) -> dict[str, str]:
    """Relative path -> text for one scenario (the lab's scripts go under assets/)."""
    s = lab.spec
    if lab.errors or not lab.contract_ok:
        raise ExportError(f"{lab.lab_id}: needs a valid lab.yaml with break+verify+cleanup (study-lab validate --strict)")
    if not lab.verified and not allow_unverified:
        raise ExportError(f"{lab.lab_id}: not verified in the runner (pass --include-unverified to export it labelled)")
    if s["run_as"] != "root":
        raise ExportError(f"{lab.lab_id}: run_as {s['run_as']} (Killercoda gives you root only)")
    image = IMAGES.get(s["requires"], {}).get(int(s.get("nodes") or 0))
    if not image:
        raise ExportError(f"{lab.lab_id}: no Killercoda image for requires={s['requires']} nodes={s.get('nodes')}")
    if RPM.search((lab.directory / s["script"]).read_text(encoding="utf-8")):
        raise ExportError(f"{lab.lab_id}: installs with rpm/dnf (Killercoda is Ubuntu)")
    home = f"/opt/study-lab/{s['cert']}-{s['topic']}"
    files = [s["script"], *[f for f in (s.get("setup") or []) if f != s["script"]]]
    assets, solution = {}, ""
    for name in files:
        p = (lab.directory / name).resolve()
        if lab.directory.resolve() not in p.parents or not p.is_file():
            raise ExportError(f"{lab.lab_id}: {name} is not a file inside the lab")
        body, sol = split_solution(p.read_text(encoding="utf-8"))
        if name.endswith(".sh") and bash_n(body):
            raise ExportError(f"{lab.lab_id}: {name} has a bash syntax error (bash -n)")
        assets[f"assets/{name}"] = body
        solution = solution or (sol if name == s["script"] else "")
    caps = load_envs()["capabilities"]
    setup = "".join(caps[n]["script"] for n in needs if n in caps)
    wait = "kubectl wait --for=condition=Ready node --all --timeout=180s || true\n" if s["requires"] != "linux" else ""
    mv = "\n".join(f"[ -f /root/{shlex.quote(n)} ] && mv /root/{shlex.quote(n)} \"$LAB/\"" for n in files)
    hints = "\n".join(f"<details><summary>Hint {i}</summary>\n\n{h}\n\n</details>\n" for i, h in enumerate(s.get("hints") or [], 1))
    out = {
        "background.sh": f"""#!/bin/bash
# Generated by study-lab export --target killercoda. Do not edit: change the lab and export again.
LAB={home}
mkdir -p "$LAB"
trap 'touch /tmp/finished' EXIT
for i in $(seq 1 60); do [ -f /root/{shlex.quote(s['script'])} ] && break; sleep 1; done
{mv}
{wait}{setup}{_env(lab)}
cd "$LAB" || exit 1
# break is idempotent by contract; a fresh cluster can still be settling (e.g. the default ServiceAccount), so retry
for attempt in 1 2 3; do
  {_run_line(lab, 'break')} > "$LAB/break.out" 2>&1 && ok=1 && break
  sleep 10
done
[ "${{ok:-}}" = 1 ] || {{ echo failed > /tmp/study-lab-setup-failed; cat "$LAB/break.out"; }}
""",
        "foreground.sh": f"""#!/bin/bash
echo "Preparing the lab..."
while [ ! -f /tmp/finished ]; do sleep 1; done
clear
if [ -f /tmp/study-lab-setup-failed ]; then echo "The lab setup failed: see {home}/break.out and /var/log/killercoda"; else cat {home}/break.out; fi
""",
        "cleanup.sh": f"""#!/bin/bash
# Not shown to the student: the parity test (study-lab test) runs it to prove the lab cleans up after itself.
{_env(lab)}
cd {home} || exit 1
{_run_line(lab, 'cleanup')}
""",
        "verify.sh": f"""#!/bin/bash
# Exit 0 only when the lab's own verify mode says solved.
{_env(lab)}
cd {home} || exit 1
out=$({_run_line(lab, 'verify')} 2>&1)
code=$?
echo "$out"
{_verify_test(lab)}
""",
        "intro.md": f"# {s['title']}\n\n{s.get('level', 'beginner').capitalize()} break/fix lab ({s['cert']} {s['topic']}). "
                    "Something is broken on purpose: find it, fix it, press Check.\n\n"
                    "The lab sets itself up while this page loads; its symptom is printed in the terminal.\n"
                    + ("" if lab.verified else "\nStatus: not yet verified end to end in the study-lab runner; it may be rough.\n")
                    + _footer(lab),
        "step1.md": "## Read the symptom\n\nThe terminal shows what was broken. Read it again with:\n\n"
                    f"```\ncat {home}/break.out\n```{{{{exec}}}}\n\nInvestigate before you change anything.\n",
        "step2.md": "## Fix it\n\nWhen you think it is solved, press **Check**.\n\n" + hints,
        "finish.md": "## Done\n\nThe lab's own check passed.\n" + (
            f"\n<details><summary>Reference solution</summary>\n\n{_fence(solution)}\n\n</details>\n" if solution else "") + _footer(lab),
    }
    index = {"title": s["title"], "description": f"{s['cert']} {s['topic']}: break/fix lab, {s.get('level', 'beginner')}",
             "details": {"intro": {"text": "intro.md", "foreground": "foreground.sh", "background": "background.sh"},
                         "steps": [{"title": "Read the symptom", "text": "step1.md"},
                                   {"title": "Fix it", "text": "step2.md", "verify": "verify.sh"}],
                         "finish": {"text": "finish.md"},
                         "assets": {"host01": [{"file": n, "target": "/root"} for n in files]}},
             "backend": {"imageid": image}}
    out["index.json"] = json.dumps(index, indent=2, ensure_ascii=False) + "\n"
    out.update(assets)
    bad = [n for n, t in out.items() if FORBIDDEN.search(t)]
    if bad:
        raise ExportError(f"{lab.lab_id}: secret-like or maintainer-only text in {', '.join(sorted(bad))}")
    return out


def natural(s: str) -> list:
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", str(s))]


def slug(topic: str, title: str = "") -> str:
    return re.sub(r"[^a-z0-9]+", "-", f"{topic} {title}".lower()).strip("-")[:48].strip("-")


def load_envs() -> dict:
    """What Killercoda runs, pinned in deploy/killercoda/killercoda_envs.yaml (with how each value is known)."""
    return yaml.safe_load((Path(__file__).resolve().parents[2] / "deploy" / "killercoda" / "killercoda_envs.yaml")
                          .read_text(encoding="utf-8"))


def tree(labs: list[spec.Lab], names: dict[str, str] | None = None, allow_unverified: bool = False,
         needs: dict | None = None, evidence: dict | None = None, day: str = "", gated: list | None = None, decorate: bool = False) -> dict[str, str]:
    """The whole mirror: <cert>/<topic>/... per lab, a structure.json per cert (a Killercoda course) and one at the root."""
    names, out, certs = names or {}, {}, {}
    for lab in sorted(labs, key=lambda x: (x.spec["cert"], natural(x.spec["topic"]))):
        c, t = lab.spec["cert"], lab.spec["topic"]
        d = slug(t, lab.spec["title"])
        files = scenario(lab, allow_unverified, tuple((needs or {}).get(f"{c}/{t}", ())))
        ev = None
        if evidence is not None:   # the publish gate: no passing evidence for THIS scenario and today's environment, no scenario
            from . import kc_test
            ev = evidence.get(f"{c}/{d}")
            if not kc_test.valid_for(ev, files, json.loads(files["index.json"])["backend"]["imageid"], day):
                (gated if gated is not None else []).append(f"{c}/{t}: no passing tested.json for this scenario and today's environment")
                continue
            files["tested.json"] = json.dumps(ev, indent=2, ensure_ascii=False) + "\n"
        if decorate:   # certification header, provenance banner, metadata.json, syllabus-ordered titles (the hash was taken before)
            from . import kc_meta
            files = kc_meta.decorate(lab, files, ev)
        for rel, text in files.items():
            out[f"{c}/{d}/{rel}"] = text
        certs.setdefault(c, []).append({"path": d, "title": json.loads(files["index.json"])["title"]})
    dump = lambda d: json.dumps(d, indent=2, ensure_ascii=False) + "\n"  # noqa: E731
    for c, items in certs.items():
        out[f"{c}/structure.json"] = dump({"title": names.get(c, c), "description": f"Break/fix labs for {names.get(c, c)}",
                                            "items": items})
    for c, items in certs.items():
        out[f"{c}/README.md"] = (f"# {names.get(c, c)}\n\n{len(items)} break/fix labs for {names.get(c, c)}: something is "
                                 "broken on purpose, you fix it, the lab checks it. Study material, exercises and the tutor "
                                 f"for this certification: {SITE} (syllabus: {REPO}/blob/main/certs/{c}.md).\n")
    probe = Path(__file__).resolve().parents[2] / "deploy" / "killercoda" / "probe"
    for f in sorted(probe.rglob("*")):   # the environment probe: how we learn what Killercoda's images really have
        if f.is_file():
            out["probe/" + f.relative_to(probe).as_posix()] = f.read_text(encoding="utf-8")
    out["probe/structure.json"] = dump({"title": "Environment probe", "description": "What the Killercoda images really have",
                                        "items": [{"path": "ubuntu"}, {"path": "k8s"}]})
    out["structure.json"] = dump({"items": [{"path": c, "title": names.get(c, c)} for c in sorted(certs)] +
                                 [{"path": "probe", "title": "Environment probe"}]})
    return out


def select(root: Path, certs: list[str] | None = None) -> tuple[list[spec.Lab], list[tuple[str, str]]]:
    """Every curated lab that fits a Killercoda environment, and (lab, reason) for the rest."""
    fit, skipped = [], []
    for d in sorted(root.glob("certs/*/*/lab")):
        if certs and d.parts[-3] not in certs:
            continue
        lab = spec.load(d, "curated")
        try:
            scenario(lab, True)
            from . import kc_meta
            kc_meta.syllabus(lab.spec["cert"], lab.spec["topic"], lab.spec["title"])   # R1, R3, R5: the objective exists, title exact
            fit.append(lab)
        except ExportError as exc:
            skipped.append((f"{d.parts[-3]}/{d.parts[-2]}", str(exc).split(": ", 1)[-1]))
    return fit, skipped


def check_tree(files: dict[str, str]) -> list[str]:
    """Guardrails on the GENERATED tree: schema of every index.json, referenced files exist, scripts parse, courses list real folders."""
    import jsonschema
    schema = json.loads((Path(__file__).resolve().parents[2] / "deploy" / "killercoda" / "index.schema.json").read_text(encoding="utf-8"))
    problems = []
    for rel in sorted(f for f in files if f.endswith("/index.json")):
        base, idx = rel[: -len("index.json")], json.loads(files[rel])
        for e in jsonschema.Draft202012Validator(schema).iter_errors(idx):
            problems.append(f"{rel}: {'/'.join(map(str, e.path)) or '(root)'}: {e.message}")
        d = idx.get("details", {})
        pages = [d.get("intro", {}), d.get("finish", {}), *d.get("steps", [])]
        refs = [p[k] for p in pages for k in ("text", "foreground", "background", "verify") if k in p]
        refs += [f"assets/{a['file']}" for v in d.get("assets", {}).values() for a in v]
        problems += [f"{rel}: references {r}, which does not exist" for r in refs if base + r not in files]
        for r in sorted(set(refs)):
            if r.endswith(".sh") and base + r in files and (not files[base + r].startswith("#!") or
                    bash_n(files[base + r])):
                problems.append(f"{base + r}: not a valid bash script (shebang, bash -n)")
        if d.get("steps") and "verify" not in d["steps"][-1]:
            problems.append(f"{rel}: the last step has no verify script")
    for rel in sorted(f for f in files if f.endswith("structure.json")):
        base = rel[: -len("structure.json")]
        problems += [f"{rel}: lists {i['path']}, which is not a folder" for i in json.loads(files[rel]).get("items", [])
                     if not any(f.startswith(f"{base}{i['path']}/") for f in files)]
    return problems


def write(files: dict[str, str], out: Path) -> None:
    for rel, text in sorted(files.items()):
        p = out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))


def cert_names(root: Path) -> dict[str, str]:
    f = root / "catalog.yaml"
    data = (yaml.safe_load(f.read_text(encoding="utf-8")) if f.is_file() else None) or {}
    return {k: v.get("name", k) for k, v in (data.get("certs") or {}).items()}
