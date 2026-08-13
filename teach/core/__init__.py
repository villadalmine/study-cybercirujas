"""Loads `.env` from the repository root, once, before anything reads a variable.

Every entry point — the CLI, the scripts, the unattended timer — imports
something from this package, so this is the one place that guarantees the file
is read no matter how the pipeline was started. A loader each caller has to
remember to invoke is a loader that gets forgotten by the next caller.

Real environment always wins: a variable already set is never overwritten, so
`LITELLM_MODEL=x teach ...` and the systemd unit both still work, and `.env` is
the default rather than an override.

`.env` is git-ignored. `.env.example` is the committed template, carrying the
reasoning rather than just the variable names.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# `.env` exists for ONE purpose: translating without spending the subscription.
# It may set these and nothing else.
#
# The restriction is the logic, not a convention. `TEACH_BACKEND=litellm` in this
# file would silently move AUTHORING to a cheap model — the one substitution this
# project does not make, and one that would be invisible afterwards except in the
# meta.yaml of every topic written while it was set. Translation is different in
# kind: its substance is fixed by the source and every failure mode is
# mechanically detectable, which is the whole reason it is safe there and not
# here. See docs/TRANSLATION_STUDY.md.
TRANSLATION_ONLY = {
    "LITELLM_BASE_URL",     # where the OpenAI-compatible API lives
    "LITELLM_API_KEY",      # the credential
    "LITELLM_MODEL",        # which cheap model translates
    "TEACH_TRANSLATE_BACKEND",  # the switch itself
    "OPENAI_TIMEOUT",       # long documents need more than the default
}


def load_env(path: Path | None = None) -> int:
    """Read KEY=VALUE lines into the environment. Returns how many were set.

    Deliberately not python-dotenv: this is a dozen lines, and the project runs
    with no dependency it does not need. Understands `#` comments, blank lines,
    a leading `export`, and surrounding quotes — nothing more, because anything
    more is a shell, and a config file that needs a shell is a config file that
    can surprise you.
    """
    root = Path(os.environ.get("TEACH_ROOT") or Path(__file__).resolve().parents[2])
    env_file = path or root / ".env"
    if not env_file.is_file():
        return 0

    loaded = 0
    for line in env_file.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not key:
            continue
        if key not in TRANSLATION_ONLY:
            # Refused, not ignored quietly: someone put it there on purpose and
            # is entitled to know it did nothing. Loudest for the one that would
            # have changed what authoring runs on.
            print(f"{env_file.name}: ignoring {key} — this file may only "
                  f"configure translation ({', '.join(sorted(TRANSLATION_ONLY))}). "
                  f"Authoring backends are chosen with --backend or TEACH_BACKEND "
                  f"in the environment, never here.", file=sys.stderr)
            continue
        # Never clobber what the caller set. An explicit variable on the command
        # line or in the systemd unit is a decision; the file is a default.
        if key not in os.environ:
            os.environ[key] = value
            loaded += 1
    return loaded


load_env()
