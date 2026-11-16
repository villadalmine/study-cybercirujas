#!/usr/bin/env python3
"""Check that cited sources actually exist.

What this catches and what it does not
--------------------------------------
This does NOT validate that an explanation is correct. It catches one concrete
and frequent hallucination signature: the invented documentation URL —
plausible, well formed, with the official site's path structure, and
nonexistent. A real example found in this repo:

    https://kubernetes.io/docs/tasks/debug/debug-application/debug-ephemeral-container/
    (the real page is .../debug-running-pod/#ephemeral-container)

A model that invents the source backing a claim is often inventing the claim
too. It is an indirect signal, but an objective and deterministic one, and it
costs no API budget.

Only the References section is inspected: URLs inside code blocks are examples
(`http://app.example.com`, cluster addresses), not citations.

    scripts/check_citations.py                 # whole repo
    scripts/check_citations.py certs/cks       # one subtree
    scripts/check_citations.py --sample 50     # quick sample
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import random
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlsplit

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(Path(__file__).resolve().parent))
CACHE = Path("/tmp/teach-citations-cache.json")

import check_sources  # noqa: E402
from teach.core.references import section as references_section  # noqa: E402  (one definition)

URL = re.compile(r"https?://[^\s)\]>\"'`]+")

# 403/429/418 mean bot blocking (gnu.org, freedesktop), not dead links.
# Reporting them as broken would fill the report with noise and make it useless.
BLOCKED = {401, 403, 405, 418, 429, 503}
GIT_HOSTS = {"github.com", "raw.githubusercontent.com", "gitlab.com"}
FLOAT_GIT = re.compile(r"/(?:raw|blob|tree)/(?:main|master|HEAD)(?:/|$)")
SHA_GIT = re.compile(r"/[0-9a-f]{7,40}(?:/|$)")
# `stable`/`latest`/`lts` are floating aliases (docs.cilium.io/en/stable), not pins.
TAG_OR_PIN = re.compile(r"(?:^|/)(?:v?\d+\.\d+[^/]*|20\d{2}(?:[-/]\d{2})?|release-[^/]+|onlinepubs/\d+|r\d+)(?:/|$|[?#])")
QUERY_PIN = re.compile(r"[?&](?:v|ver|version|tag)=")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ISSUE_MARKER = "<!-- citation-rot -->"
QUALITY_KEY = re.compile(r"^quality:.*", re.M | re.S)


def citations(path: Path) -> set[str]:
    refs = references_section(path.read_text(encoding="utf-8", errors="replace"))
    if refs is None:
        return set()
    return {u.rstrip(".,;:>") for u in URL.findall(refs)}


def status(url: str, cache: dict) -> int | str:
    if url in cache:
        return cache[url]
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "Mozilla/5.0 (teach-plat link check)"}
    )
    try:
        code: int | str = urllib.request.urlopen(request).status
    except urllib.error.HTTPError as error:
        # Some sites reject HEAD but answer GET. Retry before accusing the
        # citation of not existing.
        if error.code in (405, 403):
            try:
                code = urllib.request.urlopen(
                    urllib.request.Request(
                        url, headers={"User-Agent": "Mozilla/5.0 (teach-plat link check)"}
                    )
                ).status
            except Exception:
                code = error.code
        else:
            code = error.code
    except Exception as error:
        code = type(error).__name__
    cache[url] = code
    return code


def source_domains() -> tuple[dict[str, str], set[str], set[str]]:
    owner, neutral, data = check_sources.catalogue()
    versioned = {d.lower() for cfg in (data.get("projects") or {}).values()
                 if isinstance(cfg, dict) and cfg.get("versioned") for d in cfg.get("domains") or []}
    return owner, neutral, versioned


def host_of(url: str) -> str:
    return (urlsplit(url).hostname or "").lower()


def is_official(url: str, owner: dict[str, str], neutral: set[str]) -> bool:
    host = host_of(url)
    return host in owner or host in neutral


def is_pinned(url: str, versioned_domains: set[str], meta_pins: dict | None = None) -> bool:
    pin = (meta_pins or {}).get(url)
    if isinstance(pin, dict) and SHA256_RE.match(str(pin.get("sha256") or "")):
        return True
    parts = urlsplit(url)
    host, path = (parts.hostname or "").lower(), parts.path or ""
    if host in GIT_HOSTS:
        if FLOAT_GIT.search(path):
            return False
        if SHA_GIT.search(path) or "/releases/tag/" in path or TAG_OR_PIN.search(path):
            return True
        return len([p for p in path.split("/") if p]) <= 2
    if host not in versioned_domains:
        return True
    return bool(TAG_OR_PIN.search(path) or QUERY_PIN.search("?" + parts.query if parts.query else ""))


def fetch_sha256(url: str, timeout: int = 10) -> tuple[int | str, str | None]:
    headers = {"User-Agent": "Mozilla/5.0 (teach-plat link check)"}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as resp:
            code, body = resp.status, resp.read()
        return code, hashlib.sha256(body).hexdigest() if code == 200 else None
    except urllib.error.HTTPError as error:
        return error.code, None
    except Exception as error:
        return type(error).__name__, None


def write_meta_pins(meta_path: Path, pins: dict[str, dict[str, str]]) -> bool:
    if not meta_path.is_file() or not pins:
        return False
    text = meta_path.read_text(encoding="utf-8")
    meta = yaml.safe_load(text) or {}
    merged = {**(meta.get("citation_pins") or {}), **pins}
    pin_yaml = yaml.safe_dump({"citation_pins": dict(sorted(merged.items()))}, sort_keys=False, allow_unicode=True)
    m = QUALITY_KEY.search(text)
    head = re.sub(r"^citation_pins:.*?(?=^\S|\Z)", "", text[:m.start()] if m else text, flags=re.M | re.S).rstrip("\n")
    tail = "\n" + text[m.start():] if m else ""
    updated = (head + "\n" if head else "") + pin_yaml.rstrip("\n") + "\n" + tail.lstrip("\n")
    if updated == text:
        return False
    meta_path.write_text(updated, encoding="utf-8")
    return True


def changed_content_files(base: str, root: Path = REPO) -> list[Path]:
    res = subprocess.run(["git", "diff", "--name-only", f"{base}...HEAD", "--", "certs/*/*/*/content.md"],
                         cwd=root, capture_output=True, text=True)
    if res.returncode != 0:
        # An empty scope here would pass even in block mode: fail instead.
        raise SystemExit(f"check_citations: git diff {base}...HEAD failed: {res.stderr.strip()}")
    return [root / p for p in sorted(res.stdout.splitlines()) if p and (root / p).is_file()]


def audit(paths: list[str], *, base: str | None = None, offline: bool = False, sample: int = 0,
          cache_path: Path | None = CACHE, write_pins: bool = False, date_str: str | None = None,
          timeout: int = 10, root: Path = REPO) -> dict:
    files = changed_content_files(base, root) if base else sorted(
        {p for raw in paths for p in ((Path(raw) if Path(raw).is_absolute() else root / raw)).glob("**/content.md")})
    owner, neutral, versioned = source_domains()
    by_url: dict[str, list[str]] = defaultdict(list)
    meta_pins_by_file: dict[Path, dict] = {}
    for path in files:
        meta_file = path.parent / "meta.yaml"
        if meta_file.is_file():
            meta_pins_by_file[path] = (yaml.safe_load(meta_file.read_text(encoding="utf-8")) or {}).get("citation_pins") or {}
        rel = path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)
        for url in citations(path):
            by_url[url].append(rel)

    urls = sorted(by_url)
    unofficial = [{"url": u, "host": host_of(u), "files": by_url[u]} for u in urls if not is_official(u, owner, neutral)]
    file_by_rel = {(p.relative_to(root).as_posix() if p.is_relative_to(root) else str(p)): p for p in files}
    unpinned = [{"url": u, "files": by_url[u]} for u in urls
                if not any(is_pinned(u, versioned, meta_pins_by_file.get(file_by_rel[r])) for r in by_url[u])]

    broken, pins_written = [], 0
    if not offline:
        socket.setdefaulttimeout(timeout)
        target_urls = sorted(random.Random(11).sample(urls, sample)) if sample and sample < len(urls) else urls
        cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path and cache_path.exists() else {}
        fetched_pins: dict[str, dict[str, str]] = {}
        today = date_str or datetime.date.today().isoformat()
        print(f"{len(by_url)} unique citations; checking {len(target_urls)}", flush=True)
        for i, url in enumerate(target_urls, 1):
            code, sha = fetch_sha256(url, timeout=timeout) if write_pins else (status(url, cache), None)
            if sha:
                fetched_pins[url] = {"sha256": sha, "date": today}
            if code != 200 and code not in BLOCKED:
                broken.append({"url": url, "status": code, "files": by_url[url]})
            if i % 25 == 0:
                print(f"  {i}/{len(target_urls)}", flush=True)
        if cache_path and not write_pins:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(cache, indent=2), encoding="utf-8")
        if write_pins and fetched_pins:
            for path in files:
                local = {u: fetched_pins[u] for u in citations(path) if u in fetched_pins}
                if write_meta_pins(path.parent / "meta.yaml", local):
                    pins_written += 1
    else:
        target_urls = []

    return {"total_urls": len(by_url), "checked_urls": len(target_urls), "files_checked": len(files),
            "broken": broken, "unofficial": unofficial, "unpinned": unpinned, "pins_written": pins_written}


def render_issue_body(report: dict) -> str:
    lines = [ISSUE_MARKER, "# Citation validation report", "",
             f"- Files inspected: **{report['files_checked']}**",
             f"- Unique cited URLs: **{report['total_urls']}** (reachability checked: **{report['checked_urls']}**)",
             f"- Broken URLs: **{len(report['broken'])}** · Uncatalogued domains: **{len(report['unofficial'])}** · Unpinned URLs: **{len(report['unpinned'])}**", ""]
    if report["broken"]:
        lines += ["## Broken URLs", ""]
        for item in sorted(report["broken"], key=lambda x: (str(x["status"]), x["url"]))[:50]:
            s = ", ".join(f"`{f}`" for f in item["files"][:3]) + (f" (+{len(item['files']) - 3})" if len(item["files"]) > 3 else "")
            lines.append(f"- `[{item['status']}]` {item['url']} — {s}")
        lines.append("")
    if report["unofficial"]:
        lines += [f"## Uncatalogued domains ({len(report['unofficial'])})", ""] + [f"- `{i['host']}` — {i['url']}" for i in report["unofficial"][:20]] + [""]
    if report["unpinned"]:
        lines += [f"## Unpinned URLs on versioned/floating sources ({len(report['unpinned'])})", ""] + [f"- {i['url']}" for i in report["unpinned"][:20]]
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="*", default=["certs"])
    ap.add_argument("--base", help="check only content.md files changed relative to BASE...HEAD")
    ap.add_argument("--offline", action="store_true", help="skip network HTTP checks")
    ap.add_argument("--mode", choices=("warn", "block"), default=None)
    ap.add_argument("--strict-pins", action="store_true")
    ap.add_argument("--sample", type=int, default=0, help="check only N random URLs (quick review)")
    ap.add_argument("--timeout", type=int, default=10)
    ap.add_argument("--cache", default=str(CACHE))
    ap.add_argument("--write-pins", action="store_true")
    ap.add_argument("--json", type=Path)
    ap.add_argument("--issue-body", type=Path)
    args = ap.parse_args(argv)

    rep = audit(args.paths, base=args.base, offline=args.offline, sample=args.sample,
                cache_path=Path(args.cache) if args.cache else None, write_pins=args.write_pins, timeout=args.timeout)
    if args.json:
        args.json.write_text(json.dumps(rep, indent=2), encoding="utf-8")
    if args.issue_body:
        args.issue_body.write_text(render_issue_body(rep), encoding="utf-8")
    print(f"citations: {rep['files_checked']} files, {rep['total_urls']} URLs, {rep['checked_urls']} checked, "
          f"{len(rep['broken'])} broken, {len(rep['unofficial'])} uncatalogued, {len(rep['unpinned'])} unpinned")
    if args.mode == "warn":
        return 0
    if args.mode == "block":
        return 1 if (rep["broken"] or rep["unofficial"] or (args.strict_pins and rep["unpinned"])) else 0
    return 1 if rep["broken"] else 0


if __name__ == "__main__":
    sys.exit(main())
