"""lab.yaml `goals`: what the student has to fix, said before they start, and what Check looks at.

    goals:
      fix:
      - One sentence per fault: the symptom and what "fixed" means, without the commands.
      solved: >-
        The conditions the verify mode checks, in plain words.

The same text is shown everywhere a student meets the lab: the Killercoda intro and Fix step
(export_killercoda) and the lab's README.md (a test keeps the README in step). Pure functions.
"""

from __future__ import annotations


def of(spec: dict | None) -> dict | None:
    """The lab's goals block, or None when it declares none."""
    block = (spec or {}).get("goals")
    return block if isinstance(block, dict) and block.get("fix") else None


def markdown(spec: dict | None, heading: str = "## Goals") -> str:
    """The goals as a Markdown block (numbered list, then what Check looks at), or ''."""
    block = of(spec)
    if not block:
        return ""
    items = "\n".join(f"{i}. {' '.join(str(g).split())}" for i, g in enumerate(block["fix"], 1))
    solved = " ".join(str(block.get("solved") or "").split())
    return f"{heading}\n\n{items}\n" + (f"\n**Solved means:** {solved}\n" if solved else "")
