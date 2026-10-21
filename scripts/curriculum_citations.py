#!/usr/bin/env python3
"""What the material and the metadata say about each cert's curriculum, against what the catalog says (#220). No model, no network.

The catalog (`catalog.yaml`) is the single source of truth: per cert, `tracked_version` and the pinned `sources.objectives`
URL. Everything else that cites the curriculum (content.md, exercises.md, each meta.yaml's `sources`, the lab scripts'
headers) must say the same thing. The catalog says WHAT; `scripts/curriculum_patterns.yaml` says how to recognise a citation.

Used by `check_curriculum_consistency.py` (the CI gate), `curriculum_diff.py` (the plan lists these lines; the guard verifies
them) and `upgrade_versions.py` (the edit). `fix_line` is the single definition of "the line, made consistent".

The upgrade window. While an upgrade is open the catalog has an `upstream:` block: the version and pinned URL that will become
tracked. A citation may then name either, but one value per cert (never both), and only if the block is valid: a dotted
version newer than `tracked_version`, a pinned URL of the same document, a frozen snapshot (`upstream.snapshot`) whose version
and source URL are those, and an upgrade spec in docs/upgrades/ that names `upstream.milestone`. An invalid block is a failure
of its own, never a quiet widening. The switch PR removes the block; from then on only `tracked_version` passes.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PATTERNS = yaml.safe_load((HERE / "curriculum_patterns.yaml").read_text(encoding="utf-8"))
URL = re.compile(PATTERNS["url"])
FAMILY = [(re.compile(a), b) for a, b in PATTERNS["family"]]
NUMERIC = re.compile(PATTERNS["numeric_tracked"])
IGNORE = [re.compile(x) for x in PATTERNS.get("ignore") or []]
TRAIL = ".,;:*_"


def family(url: str) -> str:
    for rx, rep in FAMILY:
        url = rx.sub(rep, url)
    return url


def parts(version: str) -> tuple[int, ...]:
    return tuple(int(x) for x in version.split("."))


def rule_for(entry: dict, cert: str) -> dict:
    """The version-recognition rule of a cert: the default, overridden by a vendor entry (matched on the objectives URL or the id)."""
    rule = dict(PATTERNS["version"])
    url = (entry.get("sources") or {}).get("objectives") or ""
    for key, override in (PATTERNS.get("vendors") or {}).items():
        if key == cert or key in url:
            rule.update(override)
    return rule


def version_regexes(rule: dict, tracked: str, cert: str) -> list[re.Pattern]:
    """The three ways a cert cites its version, each with the number as group 1.

    A: an introducing word, then the marker and the number ("Curriculum v1.35", "Curriculum_v1.35.pdf").
    B: the cert's own id, then the number ("# CKA 1.35 - Topic 1.1", "(CKA v1.35)"), the number in the shape of tracked_version.
    C: a long marker and the number, then an introducing word ("Version 4.0 objectives:")."""
    number = r"\d+" + r"(?:\.\d+)" * tracked.count(".")
    shaped = r"\.".join(r"\d{%d}" % len(c) for c in tracked.split("."))
    words = rule["words"]
    gap = int(rule["gap"])
    cert_re = re.escape(cert).replace(r"\-", "[ -]")
    return [
        re.compile(rf"(?i:(?<![A-Za-z])(?:{words})(?![A-Za-z])[^\n]{{0,{gap}}}?(?<![A-Za-z]){rule['marker']})({number})(?!\.?\d)"),
        re.compile(rf"(?i:(?<![A-Za-z0-9])(?:{cert_re})(?![A-Za-z0-9])[ \t:]*\(?\s*(?:{rule['marker']})?)(?<!\d)({shaped})(?!\.?\d)(?!\s*%)"),
        re.compile(rf"(?i:(?<![A-Za-z]){rule['long_marker']})({number})(?!\.?\d)(?=[^\n]{{0,{gap}}}?(?<![A-Za-z])(?:{words})(?![A-Za-z]))"),
    ]


def spans(line: str, want: dict) -> list[tuple[int, int, str]]:
    """(start, end, version) of every cited version in the line, left to right, overlaps dropped."""
    found = []
    masked = _mask(line)
    for rx in want["regexes"]:
        found += [(m.start(1), m.end(1), m.group(1)) for m in rx.finditer(masked)
                  if not (rx is want["regexes"][1] and m.group(1) in want["topic_ids"])]
    out, end = [], -1
    for a, b, v in sorted(set(found)):
        if a >= end:
            out.append((a, b, v))
            end = b
    return out


def window(entry: dict, root: Path | None = None) -> tuple[dict | None, list[str]]:
    """(the upstream block if it is a valid upgrade window, the reasons it is not)."""
    up = entry.get("upstream")
    if not up:
        return None, []
    tracked = str(entry.get("tracked_version") or "")
    version = str(up.get("version") or "")
    url = up.get("objectives") or ""
    pinned = (entry.get("sources") or {}).get("objectives") or ""
    why = []
    if not (NUMERIC.match(tracked) and NUMERIC.match(version)) or len(parts(tracked)) != len(parts(version)):
        why.append(f"upstream.version {version!r} and tracked_version {tracked!r} must be dotted numbers of the same shape")
    elif parts(version) <= parts(tracked):
        why.append(f"upstream.version {version} is not newer than tracked_version {tracked}")
    if not url or url == pinned or (pinned and family(url) != family(pinned)):
        why.append("upstream.objectives must be a different pinned URL of the same document as sources.objectives")
    if root is not None:
        snap = root / str(up.get("snapshot") or "-")
        data = yaml.safe_load(snap.read_text(encoding="utf-8")) if snap.is_file() else None
        if not isinstance(data, dict) or str(data.get("version")) != version or (data.get("source") or {}).get("url") != url:
            why.append(f"upstream.snapshot {up.get('snapshot')!r} is not the frozen PDF of {version} at upstream.objectives")
        specs = [yaml.safe_load(p.read_text(encoding="utf-8")) or {} for p in sorted((root / "docs" / "upgrades").glob("*.yaml"))
                 if not p.name.endswith(".pins.yaml")]
        if not any(isinstance(s, dict) and s.get("milestone") == up.get("milestone") for s in specs) or not up.get("milestone"):
            why.append(f"no upgrade spec in docs/upgrades/ names upstream.milestone {up.get('milestone')!r}")
    return (None if why else up), why


def wanted(entry: dict, cert: str = "", root: Path | None = None, strict: bool = False) -> dict:
    """What a cert's citations may say.

    `strict=False` (the gate): the tracked value, and the upstream one while the window is valid. `strict=True` (an edit, the
    guard): only the target, which is the upstream value while the window is valid and the tracked one otherwise."""
    tracked = str(entry.get("tracked_version") or "")
    pinned = (entry.get("sources") or {}).get("objectives") or ""
    up, why = window(entry, root)
    target_v = str(up["version"]) if up else tracked
    target_u = up["objectives"] if up else pinned
    versions = [target_v] if strict else [tracked] + ([target_v] if up else [])
    urls = [target_u] if strict else [pinned] + ([target_u] if up else [])
    urls += list((PATTERNS.get("accept") or {}).get(cert, []))
    numeric = bool(NUMERIC.match(tracked))
    return {"cert": cert, "tracked": tracked, "window": bool(up), "window_errors": why,
            "versions": sorted({v for v in versions if NUMERIC.match(v)}), "urls": [u for u in dict.fromkeys(urls) if u],
            "target_version": target_v if numeric else "", "target_url": target_u, "pinned_url": pinned,
            "families": {family(u) for u in [pinned, target_u] if u},
            "topic_ids": {p.name for p in (root / "certs" / cert).glob("*") if p.is_dir()} if root and cert else set(),
            "regexes": version_regexes(rule_for(entry, cert), tracked, cert) if numeric else []}


def _urls(line: str):
    for m in URL.finditer(line):
        raw = m.group(0)
        url = raw.rstrip(TRAIL)
        yield m.start(), m.start() + len(url), url


def fix_line(line: str, want: dict) -> str:
    """The line with its curriculum links pinned to the catalog's and its cited version set to the catalog's.

    A link of the pinned document's family that is not an accepted spelling becomes the target URL; a cited version that is
    not an accepted one becomes the target version. A line that already agrees comes back unchanged."""
    if want["target_url"]:
        out, last = [], 0
        for a, b, url in _urls(line):
            if family(url) in want["families"] and url not in want["urls"]:
                out += [line[last:a], want["target_url"]]
                last = b
        line = "".join(out) + line[last:] if out else line
    if want["regexes"] and want["target_version"]:
        out, last = [], 0
        for a, b, v in spans(line, want):
            if v not in want["versions"]:
                out += [line[last:a], want["target_version"]]
                last = b
        line = "".join(out) + line[last:] if out else line
    return line


def _mask(line: str) -> str:
    """The line with the spans that only look like a cited version blanked out (same length, so positions still apply)."""
    for rx in IGNORE:
        line = rx.sub(lambda m: " " * len(m.group(0)), line)
    return line


def cited(line: str, want: dict) -> tuple[set[str], set[str]]:
    """(versions, document URLs) this line cites, for the one-value-per-cert rule."""
    versions = {v for _, _, v in spans(line, want)}
    urls = {url for _, _, url in _urls(line) if family(url) in want["families"]}
    return versions, urls


def files(root: Path, cert: str) -> list[Path]:
    base = root / "certs" / cert
    out: set[Path] = set()
    for pat in PATTERNS["files"]:
        out.update(p for p in base.glob(pat) if p.is_file())
    return sorted(out)


def problems(root: Path, catalog: dict) -> list[str]:
    """Things that make the control itself unable to speak for a cert: an invalid upstream window, or nothing to compare."""
    out = []
    for cert, entry in sorted(catalog["certs"].items()):
        want = wanted(entry, cert, root)
        out += [f"{cert}: {w}" for w in want["window_errors"]]
        if not want["urls"] and not want["target_version"]:
            if cert not in (PATTERNS.get("exempt") or {}):
                out.append(f"{cert}: no pinned sources.objectives URL and no dotted tracked_version: the control cannot tell "
                           "how this cert cites its curriculum; give it a URL in the catalog or an `exempt:` reason in "
                           "curriculum_patterns.yaml")
    return out


def offenders(root: Path, catalog: dict) -> list[dict]:
    """Every line of every cert that disagrees with its catalog entry, with what `fix_line` would write."""
    found = []
    for cert, entry in sorted(catalog["certs"].items()):
        want = wanted(entry, cert, root)
        if not want["urls"] and not want["target_version"]:
            continue
        strict = wanted(entry, cert, root, strict=True)
        seen_v: dict[str, list] = {}
        seen_u: dict[str, list] = {}
        for path in files(root, cert):
            rel = path.relative_to(root).as_posix()
            for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                fixed = fix_line(line, want)
                if fixed != line:
                    found.append({"cert": cert, "file": rel, "line": n, "text": line, "fixed": fix_line(line, strict), "kind": "stale"})
                    continue
                if want["window"]:
                    v, u = cited(line, want)
                    for x in v:
                        seen_v.setdefault(x, []).append((rel, n, line))
                    for x in u:
                        seen_u.setdefault(x, []).append((rel, n, line))
        if want["window"]:
            # one value per cert: if the tracked and the upstream value are both cited, the upstream lines are the offenders
            mixed: dict[tuple, dict] = {}
            for seen in (seen_v, seen_u):
                if len(seen) > 1:
                    keep = want["tracked"] if seen is seen_v else want["pinned_url"]
                    for value, lines in seen.items():
                        if value != keep:
                            for rel, n, line in lines:
                                o = mixed.setdefault((rel, n), {"cert": cert, "file": rel, "line": n, "text": line,
                                                                "kind": "mixed", "fixed": line})
                                o["fixed"] = o["fixed"].replace(value, keep)
            found += [mixed[k] for k in sorted(mixed)]
    return found


def key(o: dict, occurrence: int = 0) -> str:
    """Identity of an offender for the baseline: the file, the text and which repeat of that text it is (not the line number)."""
    return f"{o['file']}::{hashlib.sha256(o['text'].encode()).hexdigest()[:12]}::{occurrence}"


def keys(found: list[dict]) -> list[str]:
    seen: dict[tuple, int] = {}
    out = []
    for o in found:
        k = (o["file"], o["text"])
        out.append(key(o, seen.get(k, 0)))
        seen[k] = seen.get(k, 0) + 1
    return out


def meta_ok(old_text: str, new_text: str, want: dict, lang: str | None = None) -> bool:
    """A meta.yaml edited by the citation fix: only `sources` moved, and each source is `fix_line` of the old one.

    `quality` (re-scored after the content changed) and `tool_edit` (the stamp) are the two keys allowed to differ. `lang`
    may be corrected to the language of its own directory (`lang`, when given): a derived field, and the guard refuses a
    meta whose lang is not its directory's."""
    try:
        old, new = yaml.safe_load(old_text) or {}, yaml.safe_load(new_text) or {}
    except yaml.YAMLError:
        return False
    for d in (old, new):
        d.pop("quality", None)
        d.pop("tool_edit", None)
    old["sources"] = [fix_line(str(x), want) for x in old.get("sources") or []]
    if lang and new.get("lang") == lang:
        old["lang"] = lang
    return old == new
