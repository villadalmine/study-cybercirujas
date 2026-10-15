"""study-lab — run a study break/fix lab in a throwaway container.

    study-lab run cka 1.1                       curated lab from this repo
    study-lab run --from <git-url> <path>       lab from any repo that follows the template
    study-lab run ./my-lab                      lab from a local folder
    study-lab shell|check|down|hint <same target>
    study-lab exec <target> -- <command...>     one command inside the lab
    study-lab list [cert]                       running labs, or a cert's labs
    study-lab validate <path> [--strict]        schema + contract, one lab or a whole tree
    study-lab migrate <path> [--write]          v1 lab.yaml -> v2
    study-lab new <dir> --cert --topic --title [--requires kind|linux]   scaffold from the template
    study-lab build k8s|linux                   build a runner image locally

Only the standard library plus PyYAML and jsonschema, so a GitHub Action in
another repository can run `validate` without installing teach-plat.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

from . import runner, spec

ORIGIN_LABEL = {"curated": "curado (repo study)", "community": "repo externo", "local": "carpeta local"}
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "study-lab" / "repos"


def _clone(url: str) -> tuple[Path, str]:
    """Shallow clone (or refresh) into the cache. Only fetches; runs nothing."""
    dest = CACHE / hashlib.sha256(url.encode()).hexdigest()[:12]
    if (dest / ".git").is_dir():
        subprocess.run(["git", "-C", str(dest), "fetch", "-q", "--depth", "1", "origin"], check=True)
        subprocess.run(["git", "-C", str(dest), "reset", "-q", "--hard", "FETCH_HEAD"], check=True)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "-q", "--depth", "1", url, str(dest)], check=True)
    commit = subprocess.run(["git", "-C", str(dest), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    return dest, commit


def _lab_dir(path: Path) -> Path:
    if (path / "lab.yaml").is_file():
        return path
    if (path / "lab" / "lab.yaml").is_file():
        return path / "lab"
    raise spec.SpecError(f"no lab.yaml in {path} (nor in {path}/lab)")


def resolve(target: list[str], from_repo: str | None) -> spec.Lab:
    if from_repo:
        if len(target) != 1:
            raise spec.SpecError("--from needs exactly one path inside the repo")
        root, commit = _clone(from_repo)
        directory = _lab_dir((root / target[0]).resolve())
        if root.resolve() not in directory.resolve().parents and directory.resolve() != root.resolve():
            raise spec.SpecError("path escapes the cloned repo")
        lab = spec.load(directory, "community", f"{from_repo}@{commit}:{target[0]}")
        lab.cli_args = ["--from", from_repo, target[0]]
    elif len(target) == 1:
        directory = _lab_dir(Path(target[0]).resolve())
        lab = spec.load(directory, "local", str(directory))
        lab.cli_args = [target[0]]
    elif len(target) == 2:
        cert, topic = target
        directory = runner.REPO_ROOT / "certs" / cert / topic / "lab"
        lab = spec.load(directory, "curated", f"study certs/{cert}/{topic}")
        lab.cli_args = [cert, topic]
    else:
        raise spec.SpecError("target: <cert> <topic> | --from <repo> <path> | ./folder")
    return lab


def _banner(lab: spec.Lab) -> None:
    print(f"[study-lab] lab:     {lab.lab_id} — {lab.spec.get('title', '')}")
    print(f"[study-lab] origen:  {ORIGIN_LABEL[lab.origin]} ({lab.source})")
    if lab.verified:
        v = lab.spec["verified"]
        print(f"[study-lab] estado:  VERIFICADO {v.get('date', '')} ({v.get('method', '')})")
    else:
        print("[study-lab] AVISO:   este lab NO está verificado: puede no romper o no verificar bien. "
              "Corre igual aislado en su contenedor.")
    if lab.errors:
        raise spec.SpecError("lab.yaml does not follow the template:\n  " + "\n  ".join(lab.errors))
    if not lab.contract_ok:
        missing = [a for a in ("break", "verify", "cleanup") if lab.contract.get(a) is None]
        print(f"[study-lab] AVISO:   el script no ofrece {', '.join(missing)}; "
              "declaralo en modes: de lab.yaml (ver docs/LABS-RUNNER.md)")


def cmd_validate(args) -> int:
    root = Path(args.path)
    dirs = [root] if (root / "lab.yaml").is_file() else sorted({p.parent for p in root.rglob("lab.yaml")})
    if not dirs:
        print(f"no lab.yaml under {root}")
        return 1
    rows, bad_schema, bad_contract, verified = [], 0, 0, 0
    for d in dirs:
        try:
            lab = spec.load(d)
        except spec.SpecError as exc:
            rows.append({"lab": str(d), "schema": [str(exc)], "contract": {}, "ok": False})
            bad_schema += 1
            continue
        missing = [a for a in ("break", "verify", "cleanup") if lab.contract.get(a) is None]
        bad_schema += bool(lab.errors)
        bad_contract += bool(missing)
        verified += lab.verified
        rows.append({"lab": str(d), "requires": lab.spec.get("requires"), "schema": lab.errors,
                     "missing_modes": missing, "verified": lab.verified})
        if lab.errors or (missing and (args.strict or args.verbose)):
            print(f"{'FAIL' if lab.errors or args.strict else 'WARN'} {d}")
            for e in lab.errors:
                print(f"     schema: {e}")
            if missing:
                print(f"     contract: no {', '.join(missing)} mode")
    n = len(dirs)
    print(f"\nlabs: {n} | schema OK: {n - bad_schema} | full contract (break+verify+cleanup): "
          f"{n - bad_contract} | verified: {verified}")
    if args.report:
        Path(args.report).write_text(json.dumps({"total": n, "schema_ok": n - bad_schema,
                                                 "contract_ok": n - bad_contract, "verified": verified,
                                                 "labs": rows}, indent=1), encoding="utf-8")
    failed = bad_schema or (args.strict and bad_contract)
    return 1 if failed else 0


def cmd_migrate(args) -> int:
    lab = spec.load(_lab_dir(Path(args.path)))
    out = yaml.safe_dump(spec.migrate(lab), sort_keys=False, allow_unicode=True)
    if args.write:
        (lab.directory / "lab.yaml").write_text(out, encoding="utf-8")
        print(f"written {lab.directory / 'lab.yaml'}")
    else:
        sys.stdout.write(out)
    return 0


def cmd_list(args) -> int:
    if args.cert:
        for d in sorted((runner.REPO_ROOT / "certs" / args.cert).glob("*/lab")):
            lab = spec.load(d, "curated")
            c = "".join(k[0].upper() if lab.contract.get(k) is not None else "-" for k in ("break", "verify", "cleanup"))
            print(f"{lab.spec['cert']:<12} {lab.spec['topic']:<6} {lab.spec['requires']:<6} {c} "
                  f"{'verificado' if lab.verified else 'sin verificar':<13} {lab.spec.get('title', '')}")
        return 0
    rows = runner.running()
    if not rows:
        print("no hay labs levantados (study-lab list <cert> muestra los labs de una certificación)")
    for r in rows:
        print(f"{r['name']:<36} {r['status']:<22} {ORIGIN_LABEL.get(r['origin'], r['origin'])}: {r['source']}")
    return 0


def cmd_new(args) -> int:
    """Scaffold a lab that already follows the template (and passes validate --strict)."""
    import datetime
    import re
    dest = Path(args.path)
    if (dest / "lab.yaml").exists():
        print(f"{dest}/lab.yaml already exists: nothing written (new never overwrites)")
        return 0
    family = "kind" if args.requires in ("kind", "k3s") else "linux"
    ns = re.sub(r"[^a-z0-9]+", "-", f"lab-{args.cert}-{args.topic}".lower()).strip("-")
    dest.mkdir(parents=True, exist_ok=True)
    script = (Path(__file__).parent / "template" / family / "break_fix.sh").read_text(encoding="utf-8")
    (dest / "break_fix.sh").write_text(script.replace("__NS__", ns), encoding="utf-8", newline="\n")
    os.chmod(dest / "break_fix.sh", 0o755)
    doc = {
        "schema_version": spec.SCHEMA_VERSION, "cert": args.cert, "topic": str(args.topic), "title": args.title,
        "requires": args.requires, "script": "break_fix.sh",
        "modes": {"break": {"args": ["break"]}, "verify": {"args": ["verify"]}, "cleanup": {"args": ["cleanup"]}},
        "level": "beginner", "hints": ["Mirá el síntoma que imprimió el break antes de tocar nada."],
        "origin": {"kind": "community", "author": os.environ.get("USER", "")},
        "verified": {"status": False}, "license": "Apache-2.0",
        "x-created": datetime.date.today().isoformat(),
    }
    derived = spec.derived_from(dest)   # a lab in certs/<cert>/<topic>/lab/ declares its origin
    if derived:
        doc["derived_from"] = derived
    (dest / "lab.yaml").write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True), encoding="utf-8", newline="\n")
    print(f"lab creado en {dest} ({args.requires}). Editá break_fix.sh y probalo con: study-lab run {dest}")
    return 0


def cmd_hint(lab: spec.Lab, n: int) -> int:
    hints = lab.spec.get("hints") or []
    if not hints:
        print("este lab no trae pistas (hints:) en su lab.yaml; el script las imprime al romper")
        return 0
    for i, h in enumerate(hints[: max(1, n)], 1):
        print(f"pista {i}/{len(hints)}: {h}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="study-lab", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("run", "shell", "check", "down", "hint", "exec"):
        s = sub.add_parser(name)
        s.add_argument("--from", dest="from_repo", help="git URL of a repo that follows the lab template")
        s.add_argument("target", nargs="+" if name != "exec" else "+")
        if name == "down":
            s.add_argument("--purge-cache", action="store_true", help="also remove the node-image cache volume")
        if name == "hint":
            s.add_argument("-n", type=int, default=1, help="how many hints to show")
    v = sub.add_parser("validate")
    v.add_argument("path")
    v.add_argument("--strict", action="store_true", help="fail when break/verify/cleanup are not all reachable")
    v.add_argument("--verbose", action="store_true")
    v.add_argument("--report", help="write a JSON report here")
    m = sub.add_parser("migrate")
    m.add_argument("path")
    m.add_argument("--write", action="store_true")
    ls = sub.add_parser("list")
    ls.add_argument("cert", nargs="?")
    n = sub.add_parser("new", help="scaffold a lab from the template")
    n.add_argument("path")
    n.add_argument("--cert", required=True)
    n.add_argument("--topic", required=True)
    n.add_argument("--title", required=True)
    n.add_argument("--requires", choices=["kind", "k3s", "linux"], default="linux")
    b = sub.add_parser("build")
    b.add_argument("family", choices=["k8s", "linux"])

    argv = list(sys.argv[1:] if argv is None else argv)
    command = None
    if argv and argv[0] == "exec" and "--" in argv:
        i = argv.index("--")
        argv, command = argv[:i], argv[i + 1:]
    args = p.parse_args(argv)
    try:
        if args.cmd == "validate":
            return cmd_validate(args)
        if args.cmd == "migrate":
            return cmd_migrate(args)
        if args.cmd == "new":
            return cmd_new(args)
        if args.cmd == "list":
            return cmd_list(args)
        if args.cmd == "build":
            runner.build(args.family)
            return 0
        lab = resolve(args.target, args.from_repo)
        if args.cmd == "hint":
            return cmd_hint(lab, args.n)
        if args.cmd == "run":
            _banner(lab)
            return runner.run(lab)
        if lab.errors and args.cmd != "down":
            raise spec.SpecError("lab.yaml does not follow the template:\n  " + "\n  ".join(lab.errors))
        if args.cmd == "check":
            return runner.check(lab)
        if args.cmd == "shell":
            return runner.shell(lab)
        if args.cmd == "exec":
            if not command:
                raise spec.SpecError("exec needs: -- <command...>")
            return runner.shell(lab, command)
        if args.cmd == "down":
            return runner.down(lab, args.purge_cache)
    except (spec.SpecError, runner.RunnerError, subprocess.CalledProcessError) as exc:
        print(f"[study-lab] error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
