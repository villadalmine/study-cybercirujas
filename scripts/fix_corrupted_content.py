#!/usr/bin/env python3
"""Detect and regenerate corrupt or missing content.md/exercises.md.

Originally written for one bug: the `claude` backend returning a process recap
("Escribí certs/.../content.md...") instead of the requested content, because a
coding agent was running without tool restrictions (see CHANGELOG.md).
teach/core/generator.py now blocks that at the source (--disallowedTools plus
validation before writing), so the recap check here is only cleanup for what
was saved before the fix.

It has since grown into the work queue: targets come from pipeline.yaml, and a
combo counts as pending when it is corrupt, missing, or below the quality floor.

Idempotent: it rescans on every pass, so it can be interrupted and relaunched
freely — it converges on its own until the suspect list is empty.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

from teach.core import certs, claims, pipeline, quality

REPO = Path(__file__).resolve().parent.parent
TEACH = REPO / ".venv" / "bin" / "teach"


def _cert_topic_ids(cert: str) -> list[str]:
    """Ids de todos los topics del temario (frontmatter del .md), para poder
    detectar labs faltantes sin depender de qué haya en disco."""
    md = (REPO / "certs" / f"{cert}.md").read_text()
    front = yaml.safe_load(md.split("---")[1])
    return [str(t["id"]) for t in front.get("topics", [])]

RECAP_PATTERNS = [
    r"^`?certs/",
    r"^(He |Wrote|Written|Escribí|Creado|Created|Content (file )?(written|created)"
    r"|Fichier créé|J'ai créé|Ich habe|Datei erstellt|已创建|作成しました|を作成)",
    r"content\.md`? (fue |was |está )?(creado|escrito|written|created)",
    r"verificad[oa] con `?wc -c`?",
    r"no es un stub",
    r"not a stub",
    r"chat.recap",
]
RECAP_RE = re.compile("|".join(RECAP_PATTERNS), re.IGNORECASE)
MIN_REAL_BYTES = 1500

# What to audit comes from pipeline.yaml, not from a list here. That private
# list existed and drifted twice without anything failing: the audit reported
# "0 corrupt" for combinations it had never been told about.
TARGETS = pipeline.targets()

# Never re-declare this here. A private copy of a pipeline-wide constant is the
# exact shape of the drift that caused three separate audit blind spots, and
# this one flipped from "es" to "en" on 2026-08-04.
DEFAULT_LANG = certs.DEFAULT_LANG

# Translation is measured safe on a cheap model and ~1000x cheaper than
# authoring (docs/TRANSLATION_STUDY.md). Falls back to claude if the proxy
# is not configured, since a translation on the strong model is still far
# cheaper than re-authoring.
TRANSLATE_BACKEND = os.environ.get("TEACH_TRANSLATE_BACKEND", "claude")

FENCE_RE = re.compile(r"^```[a-zA-Z]*\n?|\n?```\s*$")


def strip_fences_in_place() -> int:
    """A veces el backend envuelve la respuesta entera en ```markdown ... ```
    (visto por primera vez en CKA, 2026-07-16) — no es corrupción, el
    contenido es real, pero rompe el render en la web. Se arregla en el
    archivo directamente (sin gastar cuota en regenerar vía AI).
    teach/core/generator.py ya lo evita para generaciones nuevas."""
    fixed = 0
    for cert, langs in TARGETS:
        cert_dir = REPO / "certs" / cert
        globs = [f"*/{lang}/{kind}" for lang in langs for kind in ("content.md", "exercises.md")]
        globs.append("*/lab/break_fix.sh")
        for pattern in globs:
            for f in sorted(cert_dir.glob(pattern)):
                text = f.read_text(errors="replace")
                if text.strip().startswith("```"):
                    f.write_text(FENCE_RE.sub("", text).strip() + "\n")
                    fixed += 1
    return fixed


def find_bad_combos() -> set[tuple[str, str, str]]:
    bad = set()
    for cert, langs in TARGETS:
        cert_dir = REPO / "certs" / cert
        # Enumerate topics from the syllabus, never from disk. Globbing
        # `*/{lang}` only sees language directories that already exist, so a
        # topic never generated in that language at all has no directory and
        # is silently skipped — the audit would then report "0 corrupt" for a
        # translation that is only a third done (hit for real on cks/en, which
        # stopped at 6 of 26 when the API quota ran out). Same blind spot the
        # 2026-07-16 fix closed for missing files inside an existing dir; this
        # closes it one level up, for the missing dir itself.
        try:
            topic_ids = _cert_topic_ids(cert)
        except (FileNotFoundError, IndexError):
            topic_ids = []
        for lang in langs:
            for topic in topic_ids:
                lang_dir = cert_dir / topic / lang
                for kind in ("content.md", "exercises.md"):
                    f = lang_dir / kind
                    if not f.exists():
                        bad.add((cert, topic, lang))
                        continue
                    text = f.read_text(errors="replace")
                    stripped = text.strip()
                    lines = stripped.splitlines()
                    first_line = lines[0] if lines else ""
                    last_line = lines[-1] if lines else ""
                    # The floor (size and structure) comes from pipeline.yaml,
                    # the same one the generator applies before writing. Only
                    # the recap check stays here: it is audit-specific, cleaning
                    # up what was saved before that guard existed.
                    looks_recap = bool(RECAP_RE.search(first_line)) or bool(
                        RECAP_RE.search(last_line)
                    )
                    if looks_recap or quality.check_file(f):
                        bad.add((cert, topic, lang))
        # break_fix.sh es compartido entre idiomas (una copia por tema, no
        # por lang) — solo se regenera con force+lang==DEFAULT_LANG. Reusa la
        # lista de topics del temario calculada arriba, por el mismo motivo:
        # detectar labs FALTANTES, no solo corruptos.
        for topic in topic_ids:
            f = cert_dir / topic / "lab" / "break_fix.sh"
            if not f.exists():
                bad.add((cert, topic, DEFAULT_LANG))
                continue
            text = f.read_text(errors="replace")
            stripped = text.strip()
            lines = stripped.splitlines()
            first_line = lines[0] if lines else ""
            last_line = lines[-1] if lines else ""
            is_small = f.stat().st_size < MIN_REAL_BYTES
            looks_recap = bool(RECAP_RE.search(first_line)) or bool(RECAP_RE.search(last_line))
            if is_small or looks_recap:
                bad.add((cert, topic, DEFAULT_LANG))
    return bad


def find_missing_videos() -> list[tuple[str, str]]:
    """[(cert, lang), ...] declared in pipeline.yaml but not rendered.

    Kept OUT of `find_bad_combos` on purpose: that set drives
    `teach cert generate --topic`, and a video is per certification, not per
    topic — feeding it in would make the regeneration loop ask for a topic that
    does not exist. Reported separately instead.

    It is reported at all because the audit is the work queue, and until now it
    only looked at content, exercises and labs. A video declared in
    `pipeline.yaml` and never rendered was invisible here, so "0 pending" could
    be true of the text and silently wrong about the media — the same blind spot
    that hit content three separate times (CHANGELOG 2026-07-16 / 07-28 / 07-29).
    """
    missing = []
    for cert, _ in TARGETS:
        for lang in pipeline.video_languages(cert):
            if not (REPO / "media" / "certs" / cert / lang / "video.mp4").exists():
                missing.append((cert, lang))
    return missing


def render_ready_videos(limit: int = 1) -> int:
    """Produce videos for certifications whose content is finished.

    The unattended pass reported missing videos and could not make them, so a
    certification reached "content complete" and stopped there — the last step
    always needed a human running `make cert`. That is the one gap that kept the
    timer from finishing anything on its own.

    Only for languages that are actually complete, which is the same ordering rule
    the rest of the pipeline follows: a video narrates material that must already
    exist and have cleared the floor. Bounded like everything else — a script is
    cheap (~$0.12) but not free, and the render costs nothing at all.
    """
    made = 0
    for cert, _ in TARGETS:
        for lang in pipeline.video_languages(cert):
            if made >= limit:
                return made
            if (REPO / "media" / "certs" / cert / lang / "video.mp4").exists():
                continue
            try:
                topic_ids = _cert_topic_ids(cert)
            except (FileNotFoundError, IndexError):
                continue
            ready = all(
                (REPO / "certs" / cert / t / lang / k).exists()
                and not quality.check_file(REPO / "certs" / cert / t / lang / k)
                for t in topic_ids for k in ("content.md", "exercises.md")
            )
            if not topic_ids or not ready:
                continue
            print(f"--- video {cert} ({lang}): content complete, producing ---", flush=True)
            for step in (["cert", "video-script", cert, "--lang", lang, "--backend", "claude"],
                         ["cert", "video", cert, "--lang", lang]):
                result = subprocess.run([str(TEACH), *step], cwd=REPO,
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    # Full output, not a 200-character slice. The first failure
                    # here was an ffmpeg error whose actual cause sat past the cut,
                    # so the log said "video failed" and nothing usable — the same
                    # mistake that made a repeating generation failure impossible
                    # to diagnose until rejected text started being kept.
                    detail = (result.stdout + result.stderr).strip() or \
                        f"no output, exit code {result.returncode}"
                    print(f"    {step[1]} failed:\n{detail}", flush=True)
                    break
            else:
                made += 1
    return made


def main() -> None:
    n_fenced = strip_fences_in_place()
    if n_fenced:
        print(f"Archivos con fence ```markdown envolvente arreglados en el lugar: {n_fenced}", flush=True)
    bad = sorted(find_bad_combos())
    all_bad = list(bad)   # before ownership, so the milestone can tell
                          # "finished" from "someone else's to finish"
    # Only this agent's certifications. The timer runs on the owner's Claude
    # subscription, so letting it generate LPI work that Antigravity produces with
    # its own plan spends the scarcer quota on the wrong half. Ownership lives in
    # pipeline.yaml; TEACH_AGENT selects who this run is.
    mine = [c for c in bad if pipeline.mine(c[0])]
    skipped = len(bad) - len(mine)
    if skipped:
        others = sorted({c[0] for c in bad if not pipeline.mine(c[0])})
        print(f"Skipping {skipped} combos owned by another agent "
              f"({', '.join(others)}); I am '{pipeline.me()}'.", flush=True)
    bad = mine

    # `--milestone` narrows the queue to the declared goal and is how the
    # unattended timer runs. Without it the timer works until nothing is pending,
    # and "nothing is pending" is not a state this repository reaches — one
    # commit re-snapshotting seven syllabi put 162 topics back in the queue.
    # A goal that is not set means no work, never all work: an unattended process
    # that treats "unspecified" as "everything" is the failure this prevents.
    if "--milestone" in sys.argv:
        goal = pipeline.milestone()
        if pipeline.milestone_targets() is None:
            print("No milestone declared in pipeline.yaml, so there is nothing to "
                  "work toward and nothing will be generated. Set one with "
                  "`scripts/steer.py milestone <cert> <langs...>`.", flush=True)
            return
        scoped = [c for c in bad if pipeline.in_milestone(c[0], c[2])]
        # Measured against the queue BEFORE ownership was applied, because
        # "finished" and "not mine to do" are different states that produce the
        # same empty list. Reporting the second as the first would have this
        # timer announce a goal complete while another agent had not started it.
        in_scope_anywhere = [c for c in all_bad if pipeline.in_milestone(c[0], c[2])]
        if not scoped and in_scope_anywhere:
            others = sorted({c[0] for c in in_scope_anywhere})
            print(f"Milestone NOT met and not mine to do: "
                  f"{goal.get('name') or 'declared goal'} needs "
                  f"{len(in_scope_anywhere)} combos in {', '.join(others)}, owned by "
                  f"another agent. Either reassign it "
                  f"(`scripts/steer.py own {others[0]} {pipeline.me()}`) or set a "
                  f"goal this agent can finish.", flush=True)
            return
        if not scoped:
            print(f"Milestone met: {goal.get('name') or 'declared goal'} — "
                  f"{len(bad)} combos are pending elsewhere and are deliberately "
                  f"not being worked on. Set the next goal with "
                  f"`scripts/steer.py milestone <cert> <langs...>`.", flush=True)
            # Finish it rather than return: video, dashboard, publish. Returning
            # here meant the pass that COMPLETES a milestone was the one pass
            # that skipped every finishing step, so a certification reached
            # "content done" and stopped — which is the exact failure the
            # automatic publish exists to remove. Hit on capa, whose content
            # finished on pass 8 and then sat there with no video and unpublished.
            _finish()
            return
        print(f"Milestone: {goal.get('name') or 'declared goal'} — "
              f"{len(scoped)} of {len(bad)} pending combos are in scope.", flush=True)
        bad = scoped

    # "pending" rather than "corrupt": now that targets come from pipeline.yaml,
    # this list mixes damaged content with content simply not generated yet for
    # a declared language. For regeneration it makes no difference, but calling
    # it corrupt makes the report misleading.
    print(f"Pending or corrupt (cert, topic, lang) combos: {len(bad)}", flush=True)
    videos = find_missing_videos()
    if videos:
        print(f"Certification videos declared but not rendered: {len(videos)}"
              f" ({', '.join(f'{c}/{l}' for c, l in videos)})", flush=True)
    if "--audit-only" in sys.argv:
        for cert, topic, lang in bad:
            print(f"    {cert} {topic} ({lang})", flush=True)
        return
    # The budget comes from the YAML: an unattended pass must not drain the
    # month's quota in one sitting.
    limit = pipeline.topics_per_run()
    batch = bad[:limit] if limit else bad
    if limit and len(bad) > limit:
        print(f"Budget per pass: {limit}. {len(bad) - limit} left for the "
              f"following ones.", flush=True)
    for cert, topic, lang in batch:
        # Claim it. This is the path the unattended timer runs, and it was the
        # one place still generating without claiming — so the timer and a manual
        # run could pick the same topic and both pay for it, which is exactly
        # what the claim system exists to prevent.
        with claims.claim(cert, topic, lang) as mine:
            if not mine:
                print(f"--- {cert} {topic} ({lang}): claimed by another run, skipping ---",
                      flush=True)
                continue
            # AUTHOR the authoring language; TRANSLATE everything else.
            #
            # This used to run `generate --lang <x>` for every language, which
            # re-authors the topic from the syllabus and never reads the English.
            # That is the mistake the whole pipeline is documented against: it
            # costs a full authoring pass (~$2 and ~100k output tokens) where a
            # translation costs ~$0.002, and it produces a sibling that drifts
            # from its source instead of a translation verified to preserve it.
            # The unattended timer does most of the generating, so it did this to
            # every non-English topic in the corpus.
            source = REPO / "certs" / cert / topic / certs.DEFAULT_LANG / "content.md"
            translating = lang != certs.DEFAULT_LANG and source.exists() and \
                not quality.check_file(source)
            if translating:
                print(f"--- translating {cert} {topic} "
                      f"({certs.DEFAULT_LANG} -> {lang}) ---", flush=True)
                command = [str(TEACH), "cert", "translate", cert, "--topic", topic,
                           "--to", lang, "--from", certs.DEFAULT_LANG,
                           "--backend", TRANSLATE_BACKEND, "--force"]
            else:
                print(f"--- authoring {cert} {topic} ({lang}) ---", flush=True)
                command = [str(TEACH), "cert", "generate", cert, "--topic", topic,
                           "--lang", lang, "--backend", "claude", "--force"]
            result = subprocess.run(command, cwd=REPO, capture_output=True, text=True)
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            if pipeline.is_fatal(output):
                print(f"    fatal, stopping this pass:\n{output}", flush=True)
                return
            # A killed process exits non-zero with no output at all, which used
            # to print an empty reason and look like a mystery. Report the exit
            # code so "someone killed it" is distinguishable from a real error.
            detail = output or f"no output, exit code {result.returncode} (killed?)"
            print(f"    failed, will retry on the next pass: {detail}", flush=True)

    # Last: a certification whose content is finished but whose video is not.
    # Without this the unattended pass could take a certification to "content
    # complete" and no further, so nothing ever finished without a human.
    _finish()


def _finish() -> None:
    """Everything that turns finished content into a published certification.

    One function because every early return in the pass was a chance to skip it,
    and one of them did: the pass that met a milestone returned before rendering
    the video, so completing a goal was the single case where nothing got
    finished.
    """
    render_ready_videos()
    _refresh_status()
    _publish_if_complete()


def _publish_if_complete() -> None:
    """Ship a certification the moment it is finished, without being asked.

    Finishing and publishing were two steps and the second needed a human to
    notice the first — the same shape as the dashboard going stale. It publishes
    only when the SET of complete certifications changes, so an unattended pass
    that finishes nothing does not rebuild the cluster for no reason.

    Never fatal: a cluster that is unreachable must not discard generated
    content, and the record is left untouched so the next pass retries.
    """
    try:
        sys.path.insert(0, str(REPO / "scripts"))
        import publish_if_complete
        publish_if_complete.main()
    except SystemExit:
        pass
    except Exception as error:
        print(f"    not published ({error}); content is safe, run "
              f"`scripts/publish_if_complete.py` when the cluster is reachable",
              flush=True)


def _refresh_status() -> None:
    """Regenerate STATUS.md here, in the thing that does the work.

    It used to live only in `resume-generation.sh`, so any other caller of this
    script left the dashboard stale — and the timer's own comment records what
    that costs: STATUS.md sat a day reporting kcsa at 2/42 when it was 42/42,
    because the path doing most of the generating did not call it. That is
    exactly what happened again while writing this: an ad-hoc runner calling
    this script directly generated for an hour against a dashboard that never
    moved.

    A caller that must remember to refresh is a caller that will forget. Putting
    it after the work means every path gets it — the timer, `make next`, a
    one-off run, anything written later — and the shell script's own call
    becomes harmless duplication rather than the only copy.

    Idempotent and derived from disk: running it twice writes the same bytes.
    Never fatal — a broken dashboard must not discard finished generation.
    """
    try:
        sys.path.insert(0, str(REPO / "scripts"))
        from status_matrix import refresh
        print("STATUS.md updated" if refresh() else "STATUS.md already current",
              flush=True)
    except Exception as error:
        print(f"    STATUS.md not refreshed ({error}); the content is fine, "
              f"run `teach status` to catch the dashboard up", flush=True)


if __name__ == "__main__":
    sys.exit(main())
