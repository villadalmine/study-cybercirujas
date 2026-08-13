#!/usr/bin/env python3
"""Does the cited page actually SAY what the material claims it says?

`check_citations.py` answers a different, easier question: does the URL exist. It
catches the invented-documentation-link signature, which is the classic
hallucination, and it costs nothing. But a URL that resolves proves the page is
there, not that it supports the sentence citing it.

That gap is not theoretical. Found 2026-08-06 in freshly generated kcsa/1.1:

    - Kubernetes Documentation — "Overview of Cloud Native Security" (the 4Cs):
      https://kubernetes.io/docs/concepts/security/overview/

The URL resolves and `check_citations.py` passes it. The page no longer contains
the 4Cs model at all — it was restructured into lifecycle phases. The model is
real and the explanation is sound; the *attribution* is stale, so a student
following the link finds nothing. No mechanical check can see that.

This one fetches the page and asks a model whether it supports the claim. That
costs quota, so it is a SAMPLING tool, not a gate: run it over a few topics after
a big generation run, or over anything you have reason to doubt.

    scripts/check_claims.py certs/kcsa/1.1/en/content.md
    scripts/check_claims.py certs/kcsa --sample 5

Output is advisory. A "not supported" verdict means look, not delete: the model
judging is as fallible as the model that wrote it, which is exactly why this
prints evidence rather than exit codes.
"""
from __future__ import annotations

import argparse
import random
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

# A reference-section line: "- Label — *Title*: https://..."
REFERENCE = re.compile(r"^[-*]\s+(?P<label>[^:]{4,160}?):\s*(?P<url>https?://\S+)\s*$", re.M)
REFS_HEADING = re.compile(
    r"^#+\s*(?:[0-9]+[.)]?\s*)?(Referencias|References|Références|Referenzen|Referências)",
    re.I | re.M,
)


def references(text: str) -> list[tuple[str, str]]:
    """(label, url) from the references section only. URLs in the body are
    examples and cluster addresses, not citations."""
    match = REFS_HEADING.search(text)
    if not match:
        return []
    return [(m.group("label").strip(" *_—-"), m.group("url").rstrip(".,;)"))
            for m in REFERENCE.finditer(text[match.end():])]


def ask(url: str, label: str, backend: str) -> str:
    """Fetch and judge. Deliberately a separate process per claim: one failure
    should cost one claim, not the run."""
    prompt = (
        f"Fetch {url} and answer in at most three lines.\n"
        f"A study guide cites that page as: \"{label}\".\n"
        f"Question: does the page actually cover that subject?\n"
        f"Answer SUPPORTED if the page covers it, STALE if the page exists but no "
        f"longer covers it (moved or restructured), or WRONG if it never did. "
        f"Then one line of evidence, quoting the page."
    )
    result = subprocess.run(
        ["claude", "-p", "--allowedTools", "WebFetch", "--", prompt],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300,
    )
    return (result.stdout or result.stderr).strip()[:400]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--all", action="store_true",
                        help="every citation, not a sample. The owner's "
                             "constraint is quality, not quota (2026-08-13): "
                             "content written once and read for years is worth "
                             "verifying completely.")
    parser.add_argument("--sample", type=int, default=3,
                        help="citations to check per file (default 3). Each costs a completion.")
    parser.add_argument("--backend", default="claude")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    files: list[Path] = []
    for raw in args.paths:
        path = Path(raw)
        files.extend(sorted(path.glob("**/content.md")) if path.is_dir() else [path])
    if not files:
        raise SystemExit("No content.md found in those paths.")

    rng = random.Random(args.seed)
    checked = suspect = 0
    for path in files:
        refs = references(path.read_text(errors="replace"))
        if not refs:
            print(f"{path}: no references section found")
            continue
        picked = refs if args.all else rng.sample(refs, min(args.sample, len(refs)))
        print(f"\n=== {path} — {len(picked)} of {len(refs)} citations ===")
        for label, url in picked:
            verdict = ask(url, label, args.backend)
            checked += 1
            flag = "  "
            if re.search(r"\b(STALE|WRONG)\b", verdict):
                flag = "!!"
                suspect += 1
            print(f"{flag} {label[:70]}\n     {url}\n     {verdict.splitlines()[0][:200]}")

    print(f"\n{checked} citations checked, {suspect} look stale or wrong.")
    print("Advisory only: the model judging is as fallible as the one that wrote "
          "the material. Read the evidence before changing anything.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
