"""lab.yaml `safety`: what a lab does beyond a throwaway container, said before it runs.

Most labs only touch the container or the kind cluster the runner gives them. A few do more: they
edit files of the machine they run on, or create real (billable, sometimes public) cloud resources.
Those labs declare it in lab.yaml:

    safety:
      risks: [modifies-host]            # modifies-host | billable-cloud | public-exposure
      warning: >-
        One or two sentences a student must read before starting: what it changes and where to run it.

The same text is shown everywhere a student meets the lab: `teach lab up` prints it and asks for
confirmation, the lab's README.md and its break_fix.sh header carry it, and the Killercoda intro
repeats it if the lab is exported. Pure functions, no I/O except `confirm`.
"""

from __future__ import annotations

import os
import sys

RISKS = {
    "modifies-host": "changes files or settings of the machine it runs on",
    "billable-cloud": "creates real cloud resources that cost money until you delete them",
    "public-exposure": "exposes something on a public IP address while it runs",
}

# For unattended runs (CI, a script): the warning is still printed, the question is skipped.
ACCEPT_ENV = "STUDY_LAB_ACCEPT_RISKS"


def of(spec: dict | None) -> dict | None:
    """The lab's safety block, or None when it declares none."""
    block = (spec or {}).get("safety")
    if not (isinstance(block, dict) and block.get("risks")):
        return None
    risks = block["risks"]
    # lab.yaml is read unvalidated by `lab up`: a hand-written `risks: modifies-host` is one risk.
    return {**block, "risks": [risks] if isinstance(risks, str) else list(risks)}


def lines(spec: dict | None) -> list[str]:
    """The warning as plain lines (no markup): headline, one line per risk, the lab's own text."""
    block = of(spec)
    if not block:
        return []
    out = ["WARNING: this lab does more than break a throwaway container."]
    out += [f"  - It {RISKS.get(r, r)}." for r in block["risks"]]
    out.append(" ".join(str(block.get("warning", "")).split()))
    return out


def markdown(spec: dict | None) -> str:
    """The warning as a Markdown block for a README or the Killercoda intro, or ''."""
    block = of(spec)
    if not block:
        return ""
    risks = "\n".join(f"> - It {RISKS.get(r, r)}." for r in block["risks"])
    text = " ".join(str(block.get("warning", "")).split())
    return f"> **Warning: this lab does more than break a throwaway container.**\n>\n{risks}\n>\n> {text}\n"


def confirm(spec: dict | None, label: str, *, echo=print, ask=None, stdin=None, env=None) -> bool:
    """Print the warning and get an explicit yes. True when the lab may start.

    No safety block: True, nothing printed. `STUDY_LAB_ACCEPT_RISKS=yes`: printed, then True.
    Not a terminal and no such variable: printed, then False (never assume consent).
    """
    text = lines(spec)
    if not text:
        return True
    env = os.environ if env is None else env
    stdin = sys.stdin if stdin is None else stdin
    echo(f"\n{label}")
    for line in text:
        echo(line)
    if env.get(ACCEPT_ENV) == "yes":
        echo(f"({ACCEPT_ENV}=yes: continuing without asking.)")
        return True
    if not (hasattr(stdin, "isatty") and stdin.isatty()):
        echo(f"Not an interactive terminal: nothing was started. Set {ACCEPT_ENV}=yes to accept these risks.")
        return False
    ask = ask or (lambda prompt: input(prompt))
    try:
        answer = ask("Type 'yes' to start it anyway: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        answer = ""
    if answer != "yes":
        echo("Not started.")
        return False
    return True
