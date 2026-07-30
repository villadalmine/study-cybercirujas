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
import json
import re
import socket
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CACHE = Path("/tmp/teach-citations-cache.json")

REFS_SECTION = re.compile(
    r"^#+ *(?:Referencias|References|Références|Referenzen|Referências|参考文献|参考)\s*$(.*)",
    re.MULTILINE | re.DOTALL | re.IGNORECASE,
)
URL = re.compile(r"https?://[^\s)\]>\"'`]+")

# 403/429/418 mean bot blocking (gnu.org, freedesktop), not dead links.
# Reporting them as broken would fill the report with noise and make it useless.
BLOCKED = {401, 403, 405, 418, 429, 503}


def citations(path: Path) -> set[str]:
    match = REFS_SECTION.search(path.read_text(errors="replace"))
    if not match:
        return set()
    return {u.rstrip(".,;:>") for u in URL.findall(match.group(1))}


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", default=["certs"])
    parser.add_argument("--sample", type=int, default=0,
                        help="check only N random URLs (quick review)")
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()

    socket.setdefaulttimeout(args.timeout)
    by_url: dict[str, list[str]] = defaultdict(list)
    for base in args.paths:
        for path in sorted(Path(base).glob("**/content.md")):
            for url in citations(path):
                by_url[url].append(str(path))

    urls = sorted(by_url)
    if args.sample and args.sample < len(urls):
        import random

        random.seed(11)
        urls = sorted(random.sample(urls, args.sample))

    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    print(f"{len(by_url)} unique citations; checking {len(urls)}", flush=True)

    broken: list[tuple[str, int | str, list[str]]] = []
    for i, url in enumerate(urls, 1):
        code = status(url, cache)
        if code != 200 and code not in BLOCKED:
            broken.append((url, code, by_url[url]))
        if i % 25 == 0:
            print(f"  {i}/{len(urls)}", flush=True)
    CACHE.write_text(json.dumps(cache, indent=2))

    if not broken:
        print("\nAll citations resolve.")
        return 0

    print(f"\n{len(broken)} citations do not resolve — check whether the source was invented:\n")
    for url, code, files in sorted(broken, key=lambda b: str(b[1])):
        print(f"  [{code}] {url}")
        for f in sorted(files)[:3]:
            print(f"        {f}")
        if len(files) > 3:
            print(f"        (+{len(files) - 3} more files)")
    print("\nA 403/429 is bot blocking and is not reported. A 404 on an "
          "official domain is usually a URL the model invented.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
