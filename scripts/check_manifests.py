#!/usr/bin/env python3
"""Check that manifests embedded in the material parse.

A broken YAML manifest in Kubernetes study material is worse than useless: the
student copies it, it fails, and they cannot tell whether they made the mistake
or the material did. Unlike prose, this is objective — it parses or it does not
— and it costs no API budget.

Honest scope: this checks **syntax**, not validity against the Kubernetes API.
An invented `spec.replicaCount` (the real field is `replicas`) parses fine and
passes. Catching that needs validation against the real schemas — see the
verification section of WORKFLOW.md.

    scripts/check_manifests.py              # whole repo
    scripts/check_manifests.py certs/cks    # one subtree
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

BLOCK = re.compile(r"^```(yaml|yml|json)[ \t]*\n(.*?)^```", re.MULTILINE | re.DOTALL)

# Teaching elision: "..." trimming a long output, either on its own line or at
# the end of one (`"items":[{...},...`).
ELISION = re.compile(r"\.\.\.")

# A YAML document cannot start indented: a block beginning with whitespace is a
# fragment showing part of a larger manifest, not something the student is meant
# to apply whole.
FRAGMENT = re.compile(r"\A\s*\n?[ \t]+\S")

# Helm/Go and Jinja templates are deliberately NOT valid plain YAML — that is
# the point of a template. Flagging them would turn the report into noise.
TEMPLATED = re.compile(r"\{\{|\{%")

# Blocks tagged `yaml` whose actual content is a shell command carrying YAML
# inside (`cat <<'EOF' | kubectl apply -f -`). The tag is imprecise but the
# material is correct and the student uses it as-is.
SHELL_START = re.compile(
    r"^\s*(cat|kubectl|helm|echo|curl|sudo|docker|\$|#!)\b|<<-?\s*['\"]?EOF"
)


def _skip(body: str) -> bool:
    return bool(
        ELISION.search(body)
        or TEMPLATED.search(body)
        or SHELL_START.search(body)
        or FRAGMENT.match(body)
    )


def problems(path: Path) -> list[tuple[int, str]]:
    found = []
    text = path.read_text(errors="replace")
    for match in BLOCK.finditer(text):
        tag, body = match.group(1), match.group(2)
        if _skip(body):
            continue
        line = text[: match.start()].count("\n") + 1
        try:
            if tag == "json":
                json.loads(body)
            else:
                list(yaml.safe_load_all(body))
        except Exception as error:
            first = str(error).splitlines()[0][:110]
            found.append((line, f"{tag}: {first}"))
    return found


def main() -> int:
    bases = sys.argv[1:] or ["certs"]
    total = broken = 0
    report: list[str] = []
    for base in bases:
        for path in sorted(Path(base).glob("**/*.md")):
            found = problems(path)
            total += 1
            if found:
                broken += 1
                for line, message in found:
                    report.append(f"  {path}:{line}  {message}")

    if not report:
        print(f"{total} files checked, all embedded manifests parse.")
        return 0
    print(f"{total} files checked, {broken} with manifests that do not parse:\n")
    print("\n".join(report))
    print("\nThis validates syntax, not Kubernetes API fields.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
