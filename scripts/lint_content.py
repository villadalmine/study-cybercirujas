#!/usr/bin/env python3
"""Syntax-check fenced bash/sh/shell/console (bash -O extglob -n) and yaml/yml (PyYAML) blocks (#207).

Console transcripts keep only prompt lines (`$ `, `user@host:~$ `, `root@host:~# `), continuations and heredocs;
`<placeholder>` words and Helm/Jinja `{{ ... }}`/`{% ... %}` templates are ignored. Optional `--shellcheck` and
`--kubeconform` print WARN lines without changing the exit code. Offline, deterministic, shrink-only baseline at
tests/fixtures/lint_content_baseline.txt (`--write-baseline` drops fixed keys; `--list` / `--summary` inspect).
"""
from __future__ import annotations

import argparse, hashlib, os, re, shutil, subprocess, sys, tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "tests" / "fixtures" / "lint_content_baseline.txt"
FILES = ("content.md", "exercises.md")
SHELL = {"bash", "sh", "shell", "console"}
YAML = {"yaml", "yml"}

FENCE = re.compile(r"^(?P<indent> {0,3}|\s*)(?P<fence>`{3,}|~{3,})\s*(?P<info>[^`\s]*)[^`]*$")
PROMPT = re.compile(r"^\s*(?:(?:[\w.-]+@[\w.-]+(?::[^\s$#]*)?\s*|\[[^\]\n]+\]\s*)[$#]|(?:\([\w.-]+\)\s*)?\$) (?P<cmd>.*)$")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(?P<tag>[A-Za-z_][\w]*)\1")
PLACEHOLDER = re.compile(r"(?<![<\w])<[A-Za-z](?:[^<>\n]*[\w)])?>")
BASH_ERR = re.compile(r"line (\d+): (.*)")


def blocks(text: str) -> list[dict]:
    """Fenced blocks: {"lang", "line" (1-based line of the first code line), "code"}. Unclosed fences are dropped."""
    out, cur = [], None
    for i, raw in enumerate(text.splitlines(), 1):
        m = FENCE.match(raw)
        if cur is None:
            if m:
                cur = {"lang": m["info"].lower(), "line": i + 1, "lines": [], "fence": m["fence"],
                       "indent": len(m["indent"])}
            continue
        if m and m["fence"][0] == cur["fence"][0] and len(m["fence"]) >= len(cur["fence"]) and not m["info"]:
            out.append({"lang": cur["lang"], "line": cur["line"], "code": "\n".join(cur["lines"]) + "\n"})
            cur = None
            continue
        n = cur["indent"]
        cur["lines"].append(raw[n:] if raw[:n].strip() == "" else raw.lstrip())
    return out


def incomplete(cmd: str) -> bool:
    """A transcript command that obviously goes on: trailing `\\`/`|`/`&&`, an open quote, or an open if/do/case/{."""
    if re.search(r"(\\|\||&&|\|\||\(|\{)\s*$", cmd):
        return True
    q, esc, bare = None, False, []
    for ch in cmd:
        if esc:
            esc = False
        elif ch == "\\" and q != "'":
            esc = True
        elif q:
            q = None if ch == q else q
        elif ch in "'\"":
            q = ch
        else:
            bare.append(ch)
    if q:
        return True
    opens = {"if": 1, "do": 1, "case": 1, "{": 1, "fi": -1, "done": -1, "esac": -1, "}": -1}
    depth = 0
    for seg in re.split(r"[;&|(\n]", "".join(bare)):
        w = seg.split()
        if len(w) > 1 and w[0] in ("then", "else", "elif"):
            w = w[1:]
        depth += opens.get(w[0], 0) if w else 0
    return depth > 0


def strip_prompts(code: str) -> tuple[str, list[int]]:
    """A console transcript as a script: (commands, 0-based line of each kept line). Bare `# ` comments stay ignored."""
    kept, where, cmd_so_far, tag = [], [], "", None
    for i, ln in enumerate(code.splitlines()):
        if tag is not None:
            kept.append(ln)
            where.append(i)
            if ln.strip() == tag:
                tag = None
            continue
        if cmd_so_far and incomplete(cmd_so_far):
            cmd = ln[2:] if ln.startswith("> ") else ln
            cmd_so_far += "\n" + cmd
        elif (m := PROMPT.match(ln)):
            cmd = cmd_so_far = m["cmd"]
        else:
            cmd_so_far = ""
            continue
        kept.append(cmd)
        where.append(i)
        if (h := HEREDOC.search(cmd)):
            tag = h["tag"]
    return "\n".join(kept) + "\n", where


def is_transcript(lang: str, code: str) -> bool:
    return lang == "console" or any(re.match(r"\s*\$ ", ln) for ln in code.splitlines())


def check_shell(lang: str, code: str) -> list[tuple[int, str]]:
    """(0-based block line, message) for each `bash -n` error."""
    where = None
    if is_transcript(lang, code):
        code, where = strip_prompts(code)
        if not code.strip():
            return []
    p = subprocess.run(["bash", "--norc", "--noprofile", "-O", "extglob", "-n"], input=PLACEHOLDER.sub("PLACEHOLDER", code),
                       capture_output=True, text=True, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C"})
    if p.returncode == 0:
        return []
    errs = [(max(where[min(int(m[1]) - 1, len(where) - 1)] if where else 0 if where is not None else int(m[1]) - 1, 0),
             m[2].strip()) for ln in p.stderr.splitlines() if (m := BASH_ERR.search(ln))]
    return errs or [(0, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "bash -n failed")]


class _AnyTag(getattr(yaml, "CSafeLoader", yaml.SafeLoader)):  # libyaml when present: ~10x faster, same verdicts
    """SafeLoader that accepts application tags (`!Ref`, `!GetAtt`, `!vault`, ...): they are valid YAML syntax."""


_AnyTag.add_multi_constructor("!", lambda loader, suffix, node: None)


def check_yaml(code: str) -> list[tuple[int, str]]:
    if "{{" in code or "{%" in code:
        return []
    try:
        for _ in yaml.load_all(code, Loader=_AnyTag):  # noqa: S506 (SafeLoader subclass)
            pass
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        return [(mark.line if mark else 0, f"yaml: {getattr(e, 'problem', None) or str(e).splitlines()[0]}")]
    return []


def check_block(lang: str, code: str) -> list[tuple[int, str]]:
    return check_shell(lang, code) if lang in SHELL else check_yaml(code) if lang in YAML else []


def material(paths: list[Path]) -> list[Path]:
    return sorted({f for base in paths for f in (
        [base] if base.is_file() else (p for name in FILES for p in base.glob(f"{'*/*/*' if base.name == 'certs' else '**'}/{name}"))
    )})


def offenders(paths: list[Path] | None = None) -> list[dict]:
    """Every block with a syntax error: {"file", "line", "lang", "msg", "key"}; deterministic order."""
    todo = []
    for f in material(paths or [REPO / "certs"]):
        rel = f.relative_to(REPO).as_posix()
        for b in blocks(f.read_text(encoding="utf-8")):
            if b["lang"] in SHELL or b["lang"] in YAML:
                todo.append((rel, b))
    unique = {(b["lang"], b["code"]) for _, b in todo}
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        res = dict(zip(unique, pool.map(lambda k: check_block(*k), unique)))
    out, seen = [], Counter()
    for rel, b in todo:
        errs = res[(b["lang"], b["code"])]
        if not errs:
            continue
        digest = hashlib.sha256(b["code"].encode()).hexdigest()[:12]
        seen[(rel, digest)] += 1
        n = seen[(rel, digest)]
        key = f"{rel}:{digest}" + (f"#{n}" if n > 1 else "")
        line, msg = errs[0]
        out.append({"file": rel, "line": b["line"] + line, "lang": b["lang"], "msg": msg, "key": key, "code": b["code"]})
    return out


def load_baseline(path: Path = BASELINE) -> set[str]:
    if not path.is_file():
        return set()
    return {ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.startswith("#")}


def write_baseline(found: list[dict], path: Path = BASELINE) -> tuple[int, list[str]]:
    """(entries written, keys refused). An existing baseline only loses entries; a missing one is created."""
    keys = {o["key"] for o in found}
    refused = []
    if path.is_file():
        old = load_baseline(path)
        refused = sorted(keys - old)
        keys &= old
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# Code blocks that failed lint_content.py when it was added (#207). It may only shrink: fix the block,\n"
                    "# then run scripts/lint_content.py --write-baseline. Key: file:sha256(block)[:12].\n"
                    + "".join(f"{k}\n" for k in sorted(keys)), encoding="utf-8")
    return len(keys), refused


def check(paths: list[Path] | None = None, baseline_path: Path = BASELINE) -> tuple[list[dict], list[str], list[dict]]:
    """(new offenders, stale baseline keys, all offenders). Stale keys only count inside the paths checked."""
    found = offenders(paths)
    base = load_baseline(baseline_path)
    keys = {o["key"] for o in found}
    scope = [p.relative_to(REPO).as_posix() for p in (paths or [REPO / "certs"])]
    stale = sorted(k for k in base - keys if any(k.startswith(s.rstrip("/") + "/") or k.split(":")[0] == s
                                                     for s in scope))
    return [o for o in found if o["key"] not in base], stale, found


def category(msg: str) -> str:
    msg = re.sub(r"`[^']*'", "`X'", msg)
    msg = re.sub(r"line \d+", "line N", msg)
    return re.sub(r"\s+", " ", msg)[:70]


def optional_tools(found_files: list[Path], shellcheck: bool, kubeconform: bool) -> None:
    """Report-only extras; never change the exit code."""
    have = {t: shutil.which(t) for t, on in (("shellcheck", shellcheck), ("kubeconform", kubeconform)) if on}
    for tool, exe in have.items():
        if not exe:
            print(f"NOTE {tool} not installed: skipped")
    if not any(have.values()):
        return
    with tempfile.TemporaryDirectory() as tmp:
        tmpf = Path(tmp) / "block"
        for f in found_files:
            rel = f.relative_to(REPO).as_posix()
            for b in blocks(f.read_text(encoding="utf-8")):
                if have.get("shellcheck") and b["lang"] in SHELL:
                    code = strip_prompts(b["code"])[0] if is_transcript(b["lang"], b["code"]) else b["code"]
                    tmpf.write_text(PLACEHOLDER.sub("PLACEHOLDER", code), encoding="utf-8")
                    out = subprocess.run(["shellcheck", "--severity=error", "--shell=bash", "--format=gcc", str(tmpf)],
                                         capture_output=True, text=True).stdout
                    for ln in out.splitlines():
                        print(f"WARN shellcheck {rel}:{b['line']}: {ln.split(': ', 1)[-1]}")
                if have.get("kubeconform") and b["lang"] in YAML and "apiVersion" in b["code"] and "kind" in b["code"]:
                    tmpf.write_text(b["code"], encoding="utf-8")
                    p = subprocess.run(["kubeconform", "-ignore-missing-schemas", "-summary=false", str(tmpf)],
                                       capture_output=True, text=True)
                    for ln in (p.stdout + p.stderr).splitlines():
                        print(f"WARN kubeconform {rel}:{b['line']}: {ln.split(' - ', 1)[-1]}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="*", type=Path, help="cert or topic directories (default: certs/)")
    for flag, msg in (("--list", "every offender with file:line and error"), ("--summary", "counts by cert and category"),
                      ("--write-baseline", "shrink baseline (or create it)"),
                      ("--shellcheck", "report-only shellcheck"), ("--kubeconform", "report-only kubeconform")):
        ap.add_argument(flag, action="store_true", help=msg)
    a = ap.parse_args(argv)
    paths = [p.resolve() for p in a.paths] or None
    new, stale, found = check(paths)
    if a.write_baseline:
        n, refused = write_baseline(found)
        for k in refused:
            print(f"REFUSED (new offender, fix it; the baseline may only shrink): {k}")
        print(f"baseline: {n} entr{'y' if n == 1 else 'ies'}")
        return 1 if refused else 0
    if a.list:
        for o in found:
            print(f"{o['file']}:{o['line']}: [{o['lang']}] {o['msg']}")
    if a.summary:
        by_cert = sorted(Counter(o["file"].split("/")[1] for o in found).items(), key=lambda x: (-x[1], x[0]))
        by_cat = Counter(f"[{'yaml' if o['lang'] in YAML else 'shell'}] {category(o['msg'])}" for o in found).most_common(15)
        for label, rows in (("by cert:", by_cert), ("by category:", by_cat)):
            print(label, *(f"\n  {n:5}  {c}" for c, n in rows), sep="")
    for o in new:
        print(f"NEW {o['file']}:{o['line']}: [{o['lang']}] {o['msg']}")
    for k in stale:
        print(f"STALE baseline entry (no longer an offender, run --write-baseline): {k}")
    optional_tools(material(paths or [REPO / "certs"]), a.shellcheck, a.kubeconform)
    print(f"lint content: {len(found)} offender(s), {len(found) - len(new)} in the baseline, {len(new)} new, "
          f"{len(stale)} stale baseline entr{'y' if len(stale) == 1 else 'ies'}")
    return 1 if new or stale else 0


if __name__ == "__main__":
    sys.exit(main())
