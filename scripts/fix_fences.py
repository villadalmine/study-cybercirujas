#!/usr/bin/env python3
"""Retag fenced blocks whose label promises something the content is not.

`check_manifests.py` reports a block as broken when it cannot parse. Some of
those are wrong material; a measurable share are *correct* material behind a
wrong fence label — a ```json block holding console output, or holding JSON
Lines (one object per line, which is not one JSON document). The student is not
misled by either, but the check cannot tell them apart from real breakage, and
a report full of non-problems stops being read.

Two rules, both mechanical and both narrow:

  console   a `json` block whose first non-blank character is not `{` or `[`
            is program output, not a document. Retagged to a plain fence.
  jsonl     a `json` block where every non-blank line parses on its own but
            the block does not parse as one document is JSON Lines. Retagged
            to a plain fence, because ```jsonl renders as nothing useful.

Anything else is left alone: this script never edits inside a block, and never
touches YAML. Real breakage stays reported.

    scripts/fix_fences.py              # show what would change (default)
    scripts/fix_fences.py --apply      # write it
    scripts/fix_fences.py certs/kcsa   # narrow the scope

Free: no model, no network.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BLOCK = re.compile(r"^```json[ \t]*\n(.*?)^```", re.MULTILINE | re.DOTALL)


def classify(body: str) -> str | None:
    """'console' | 'jsonl' | None — None means leave it alone."""
    stripped = body.strip()
    if not stripped:
        return None
    try:
        json.loads(stripped)
        return None  # parses as one document: nothing to fix
    except json.JSONDecodeError:
        pass
    if stripped[0] not in "{[":
        return "console"
    lines = [l for l in stripped.splitlines() if l.strip()]
    if len(lines) > 1:
        try:
            for line in lines:
                json.loads(line)
            return "jsonl"
        except json.JSONDecodeError:
            return None
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", default=["certs"])
    parser.add_argument("--apply", action="store_true", help="write the changes")
    args = parser.parse_args()

    changed_files = 0
    changed_blocks = {"console": 0, "jsonl": 0}
    for base in args.paths or ["certs"]:
        for path in sorted(Path(base).glob("**/*.md")):
            text = path.read_text(errors="replace")
            out, last, hits = [], 0, 0
            for match in BLOCK.finditer(text):
                kind = classify(match.group(1))
                if not kind:
                    continue
                hits += 1
                changed_blocks[kind] += 1
                line_no = text[: match.start()].count("\n") + 1
                first = match.group(1).strip().splitlines()[0][:64]
                print(f"  {path}:{line_no}  {kind}: ```json → ```   ({first}…)")
                out.append(text[last:match.start()])
                out.append("```\n" + match.group(1) + "```")
                last = match.end()
            if hits:
                changed_files += 1
                if args.apply:
                    out.append(text[last:])
                    path.write_text("".join(out))

    total = sum(changed_blocks.values())
    if not total:
        print("No mislabelled json fences found.")
        return 0
    print(f"\n{total} block(s) in {changed_files} file(s): "
          f"{changed_blocks['console']} console output, {changed_blocks['jsonl']} JSON Lines.")
    if not args.apply:
        print("Nothing written. Re-run with --apply to make these changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
