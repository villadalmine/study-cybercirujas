#!/usr/bin/env python3
"""The ONE way to take a certification from nothing to finished.

Every agent and every human uses this. It exists because ad-hoc orchestrators
keep being written, and each one re-invents — and gets wrong — the same four
things:

  * **The lock.** `resume.lock` is what stops the systemd timer and a manual run
    from generating at the same time. A script that does not take it can pick the
    same topic as the timer and overwrite its output, and both pay for it. Seen
    on 2026-08-06: an improvised daemon ran `teach cert generate lpic-1` while the
    timer was authoring cnpa. Different certs by luck, not by design.
  * **The budget.** `budget.topics_per_run` is 2. `teach cert generate <cert>`
    with no `--topic` authors EVERY pending topic in one invocation — 59 of them
    for lpic-1 — which does not finish faster, it just fails later and wastes more
    when it does.
  * **The flags.** `teach cert translate` takes `--to`, not `--lang`. An
    orchestrator that gets this wrong dies at the translate step, and with
    `set -e` the steps after it never run — so "the whole certification is ready"
    is reported while the Spanish half never happened.
  * **The order.** Content, then verification, then video; authoring language
    first, translations after. A video narrates material that has to exist and
    have passed the floor.

    scripts/run_cert.py lpic-1                     # everything, in order
    scripts/run_cert.py lpic-1 --stage author      # one stage only
    scripts/run_cert.py lpic-1 --dry-run           # what it would do

Idempotent: it asks the audit what is missing on every pass, so interrupting and
relaunching is free and needs no flags.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

from teach.core import certs, pipeline  # noqa: E402

TEACH = REPO / ".venv" / "bin" / "teach"
STAGES = ("author", "verify", "video", "translate")


def run(command: list[str], dry: bool) -> int:
    printable = " ".join(str(part) for part in command)
    print(f"  $ {printable}", flush=True)
    if dry:
        return 0
    return subprocess.run(command, cwd=REPO).returncode


def pending_topics(cert: str, lang: str) -> list[str]:
    import fix_corrupted_content as audit
    return sorted({t for c, t, l in audit.find_bad_combos() if c == cert and l == lang})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cert")
    parser.add_argument("--backend", default="claude",
                        help="any provider; it is recorded in meta.yaml either way")
    parser.add_argument("--translate-backend", default=None,
                        help="backend for translation (default: same as --backend). "
                             "Translating is the one step measured safe on a cheap "
                             "model — see docs/TRANSLATION_STUDY.md")
    parser.add_argument("--stage", choices=STAGES, action="append",
                        help="run only these stages (repeatable). Default: all, in order")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    stages = args.stage or list(STAGES)
    source = certs.DEFAULT_LANG
    languages = pipeline.languages_for(args.cert)
    if source not in languages:
        raise SystemExit(f"{args.cert} does not declare the authoring language "
                         f"'{source}' in pipeline.yaml")
    targets = [lang for lang in languages if lang != source]

    print(f"{args.cert}: authoring language {source}, translating to "
          f"{', '.join(targets) or '(none)'}\n")

    # 1. AUTHOR — bounded, one batch at a time, holding the lock.
    if "author" in stages:
        remaining = pending_topics(args.cert, source)
        print(f"[author] {len(remaining)} topics pending in {source}")
        while remaining:
            code = run([sys.executable, str(REPO / "scripts" / "run_batch.py"),
                        args.cert, "--lang", source, "--backend", args.backend], args.dry_run)
            if args.dry_run:
                break
            if code == 3:
                # run_batch's exit 3 means OWNERSHIP, not the lock: the global
                # lock died with per-topic claims, but this message outlived it
                # and diagnosed a refusal as contention on 2026-08-18.
                print("[author] refused: this certification belongs to another "
                      "agent (pipeline.yaml -> owner). Reassign with "
                      "`scripts/steer.py own <cert> <agent>`, or take one "
                      "deliberate batch with run_batch --anyway.")
                return 3
            if code != 0:
                print("[author] stopped (quota, or a topic that will not pass). "
                      "Re-run this command to continue — nothing is lost.")
                return code
            still = pending_topics(args.cert, source)
            if len(still) >= len(remaining):
                print("[author] no progress this pass, stopping to avoid a loop")
                break
            remaining = still

    # 2. VERIFY — free, and the gate for everything after it.
    if "verify" in stages:
        print("\n[verify] provenance, bookkeeping and ordering")
        code = run([sys.executable, str(REPO / "scripts" / "check_provenance.py"), args.cert],
                   args.dry_run)
        if code != 0 and not args.dry_run:
            print("[verify] fix the above before rendering a video or translating: "
                   "both build on this content.")
            return code

    # 3. VIDEO for the authoring language — only once the content is all there.
    if "video" in stages and source in pipeline.video_languages(args.cert):
        print(f"\n[video] {source}")
        if pending_topics(args.cert, source):
            print(f"[video] skipped: {source} content is not finished. A video "
                  f"narrates material that must already exist.")
        else:
            run([str(TEACH), "cert", "video-script", args.cert, "--lang", source,
                 "--backend", args.backend], args.dry_run)
            run([str(TEACH), "cert", "video", args.cert, "--lang", source], args.dry_run)

    # 4. TRANSLATE, then that language's video.
    if "translate" in stages:
        backend = args.translate_backend or args.backend
        for lang in targets:
            print(f"\n[translate] {source} -> {lang}")
            # NOTE: --to, not --lang. `--lang` re-authors from the syllabus and
            # would pay full authoring cost for a sibling that drifts.
            code = run([str(TEACH), "cert", "translate", args.cert, "--to", lang,
                        "--from", source, "--backend", backend], args.dry_run)
            if code != 0 and not args.dry_run:
                print(f"[translate] {lang} incomplete; re-run to continue")
                continue
            if lang in pipeline.video_languages(args.cert):
                run([str(TEACH), "cert", "video-script", args.cert, "--lang", lang,
                     "--backend", backend], args.dry_run)
                run([str(TEACH), "cert", "video", args.cert, "--lang", lang], args.dry_run)

    print(f"\nDone. `make audit` and `scripts/usage_report.py` say where it stands "
          f"and what it cost.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
