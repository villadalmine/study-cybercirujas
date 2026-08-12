#!/usr/bin/env python3
"""Generates STATUS.md: cert x language x lab matrix, and path x video language matrix.

It is always read from the actual filesystem (file counts), never manually
updated — the lesson of this session is that "N/N topics" proves nothing unless
content.md, exercises.md, and break_fix.sh are counted separately (see
CHANGELOG.md 2026-07-16/17). Run again after any generation to keep the state updated:

    .venv/bin/python3 scripts/status_matrix.py
"""
import sys
from pathlib import Path

import yaml

from teach.core import certs, pipeline, quality, video

REPO = Path(__file__).resolve().parent.parent
STATUS = REPO / "STATUS.md"
# Derived, never declared here. A private copy of these lists is the exact defect
# this repo has hit three times: the matrix reported on the languages it had been
# told about and stayed silent about the rest, which reads as "nothing missing".
#
# LANGS       every language the platform supports (teach/core/certs.py)
# VIDEO_LANGS only those Piper can actually speak — a video column for a language
#             with no voice would be permanently red for something that cannot be
#             done at all, which is noise rather than a finding.
LANGS = list(certs.LANGS)
VIDEO_LANGS = [l for l in certs.LANGS if l in video.VOICES]


def cert_topics(cert_id: str) -> list[dict]:
    path = REPO / "certs" / f"{cert_id}.md"
    if not path.exists():
        return []
    front = yaml.safe_load(path.read_text().split("---")[1])
    return front.get("topics") or []


def lang_cell(cert_dir: Path, lang: str, n: int, wanted: bool = True,
              topic_ids: list[str] | None = None) -> str:
    """Count only material that meets the quality floor in pipeline.yaml.

    `wanted` is whether the certification declares this language at all. A cert
    configured for `[en, es]` is not "missing" Japanese — nobody asked for it —
    and printing ❌ there made a finished certification read as five-sevenths
    undone. Undeclared languages get – , the same mark used for a syllabus that
    has not been snapshotted: not applicable, rather than not done.

    Counting files that merely exist marked a whole certification ✅ while its
    topics averaged a ninth of the usual size and had no answers section. A
    file that is present but below the standard is pending work, not finished
    work, and the matrix has to say so.
    """
    if not wanted:
        return "–"
    # Enumerate topics from the syllabus, never from disk. Globbing counts any
    # directory that happens to be there, including topics a re-snapshot removed:
    # lpic-3-305 read "16/13c" because the three chapter-level directories from
    # the old syllabus were still on disk and were counted as progress toward the
    # thirteen objectives that replaced them. The audit learned this in
    # 2026-07-16; the matrix did not, so the two disagreed about the same tree.
    ids = topic_ids if topic_ids is not None else [d.name for d in cert_dir.iterdir()
                                                   if d.is_dir()]
    files = [p for p in (cert_dir / t / lang / "content.md" for t in ids) if p.exists()]
    exercises = [p for p in (cert_dir / t / lang / "exercises.md" for t in ids)
                 if p.exists()]
    c = sum(1 for f in files if not quality.check_file(f))
    e = sum(1 for f in exercises if not quality.check_file(f))
    below = (len(files) - c) + (len(exercises) - e)

    if c == n and e == n:
        return "✅"
    if not files and not exercises:
        return "❌"
    cell = f"🔶 {c}/{n}c·{e}/{n}e"
    return f"{cell} ⚠️{below}" if below else cell


def lab_cell(cert_dir: Path, n: int, topic_ids: list[str] | None = None) -> str:
    # Same reason as lang_cell: a lab under a topic the syllabus no longer
    # has is not progress toward the topics it does have.
    ids = topic_ids if topic_ids is not None else [d.name for d in
                                                   cert_dir.iterdir() if d.is_dir()]
    lab = sum(1 for t in ids if (cert_dir / t / "lab" / "break_fix.sh").exists())
    if lab == n:
        return "✅"
    if lab == 0:
        return "❌"
    return f"🔶 {lab}/{n}"


def refresh() -> bool:
    """Regenerate STATUS.md from disk. True if it changed.

    The single implementation every caller shares — `make cert`, `make publish`,
    the unattended timer and the CLI all land here rather than each shelling out
    to a script and each getting it slightly wrong. Importable on purpose:

        from status_matrix import refresh
        refresh()

    Idempotent by construction: it derives everything from the filesystem, so
    running it twice produces the same bytes and running it never is the only way
    to be wrong. STATUS.md sat a day stale reporting kcsa at 2/42 when it was
    42/42, because the one path that does most of the generating did not call it.
    """
    before = STATUS.read_text() if STATUS.exists() else None
    _write()
    return STATUS.read_text() != before


def check() -> list[str]:
    """[] if STATUS.md matches the filesystem; the differing lines otherwise.

    `refresh()` keeps it current, but nothing proved it WAS current, so the file
    could drift for two reasons that look identical in a diff: a work path that
    forgot to call refresh (which happened — see `_refresh_status`), or someone
    editing the dashboard by hand. Both make it a claim rather than a report, and
    a report that is only right when someone remembers is worse than none,
    because it is believed.

    Reads nothing but the tree: STATUS.md is derived from what is on disk, never
    from what a process said it did. A generator that crashes after writing half
    a topic cannot produce a green dashboard, because nobody asked it.

    Does not write, so it is safe in a gate.
    """
    current = STATUS.read_text() if STATUS.exists() else ""
    expected = _render()
    if current == expected:
        return []
    import difflib
    return [l for l in difflib.unified_diff(
        current.splitlines(), expected.splitlines(),
        fromfile="STATUS.md (committed)", tofile="STATUS.md (from disk)", lineterm="")]


def _write() -> None:
    STATUS.write_text(_render())


def _render() -> str:
    catalog = yaml.safe_load((REPO / "catalog.yaml").read_text())
    lines = [
        "# Content Status",
        "",
        "Generated by `scripts/status_matrix.py` from the actual filesystem "
        "— run again after any generation, do not edit directly. Counts only "
        "material that meets the quality floor in `pipeline.yaml`, not files "
        "that merely exist: a topic present but below the floor is pending "
        "work, not finished work.",
        "",
        "✅ complete · 🔶 partial (details) · ⚠️N N files below the quality "
        "floor · ❌ declared but not started · – not applicable: the language or "
        "video is not declared for that certification, or no syllabus has been "
        "snapshotted yet",
        "",
    ]

    # What the unattended timer is working toward, and how far it is. Without
    # this the goal lives only in pipeline.yaml, so the dashboard could show a
    # certification at 3/12 and give no way to tell whether anything is working
    # on it — or whether the timer is deliberately idle, which is a normal state
    # here and must not read as a stall.
    goal = pipeline.milestone()
    goal_targets = pipeline.milestone_targets()
    lines += ["## Milestone", ""]
    if goal_targets is None:
        lines += ["None declared — the unattended timer generates nothing. That is "
                  "the safe default: an unset goal must not read as \"everything\". "
                  "Set one with `scripts/steer.py milestone <cert> <langs...>`.", ""]
    else:
        lines += [f"**{goal.get('name') or 'declared goal'}** — the timer works only "
                  f"on this and stops when it is met.", "",
                  "| Cert | Language | Topics done | Remaining |", "|---|---|---|---|"]
        for cert_id, langs in goal_targets:
            topics = cert_topics(cert_id)
            ids = [str(t["id"]) for t in topics]
            cert_dir = REPO / "certs" / cert_id
            for lang in langs:
                # Existence is checked explicitly rather than inferred from the
                # floor. `quality.check_file` keys its rules on the filename, so
                # it returns "no problems" for anything it does not recognise —
                # true of a missing file only by accident of how it fails, and
                # counting "done" on an accident is how a dashboard lies.
                done = sum(1 for t in ids if all(
                    (cert_dir / t / lang / kind).exists()
                    and not quality.check_file(cert_dir / t / lang / kind)
                    for kind in ("content.md", "exercises.md"))) if ids else 0
                mark = "✅" if done == len(ids) else f"{done}/{len(ids)}"
                lines.append(f"| `{cert_id}` | {lang} | {mark} | {len(ids) - done} |")
        lines.append("")

    lines += [
        "## Certifications",
        "",
        "| Cert | Topics | " + " | ".join(l.upper() for l in LANGS) + " | Labs |",
        "|---|---|" + "---|" * len(LANGS) + "---|",
    ]
    for cert_id, cert in catalog["certs"].items():
        topics = cert_topics(cert_id)
        n = len(topics)
        cert_dir = REPO / "certs" / cert_id
        if n == 0:
            row = [f"`{cert_id}`", "–"] + ["–"] * len(LANGS) + ["–"]
        else:
            row = [f"`{cert_id}`", str(n)]
            declared = set(pipeline.languages_for(cert_id))
            ids = [str(topic['id']) for topic in topics]
            row += [lang_cell(cert_dir, lang, n, lang in declared, ids)
                    for lang in LANGS]
            row.append(lab_cell(cert_dir, n, ids))
        lines.append("| " + " | ".join(row) + " |")

    # Exam versions: what the material was built on vs what upstream publishes.
    # Two different questions that used to share one field — see
    # scripts/check_versions.py for why that made the comparison impossible.
    sys.path.insert(0, str(REPO / "scripts"))
    from check_versions import survey as version_survey

    lines += ["", "## Exam versions", "",
              "`built on` is frozen by `teach cert snapshot` and never touched by a "
              "sync; `upstream` is refreshed by `teach tracker sync` and never touched "
              "by a snapshot. **outdated** means upstream changed after we froze — "
              "re-snapshot and the changed topics go stale automatically. **unknown** "
              "means unmeasured, not fine.", "",
              "| Cert | Built on | Snapshot | Upstream | Upstream changed | Checked | State |",
              "|---|---|---|---|---|---|---|"]
    MARK = {"current": "✅ current", "outdated": "⚠️ **outdated**", "unknown": "– unknown"}
    for row in sorted(version_survey(), key=lambda r: (r["state"] != "outdated", r["cert"])):
        lines.append(
            f"| `{row['cert']}` | {row['version'] or '–'} | {row['snapshot'] or '–'} "
            f"| {row['upstream_version'] or '–'} | {row['upstream_changed'] or '–'} "
            f"| {row['last_checked'] or 'never'} | {MARK[row['state']]} |"
        )

    lines += ["", "## Path Videos", "",
              "| Path | " + " | ".join(l.upper() for l in VIDEO_LANGS) + " |",
              "|---|" + "---|" * len(VIDEO_LANGS)]
    for slug, path in (catalog.get("paths") or {}).items():
        if path.get("type"):
            continue  # achievements/info do not have video
        row = [f"`{slug}`"]
        for lang in VIDEO_LANGS:
            video = REPO / "media" / "paths" / slug / lang / "video.mp4"
            row.append("✅" if video.exists() else "❌")
        lines.append("| " + " | ".join(row) + " |")

    lines += ["", "## Certification Videos", "",
              "| Cert | " + " | ".join(l.upper() for l in VIDEO_LANGS) + " |",
              "|---|" + "---|" * len(VIDEO_LANGS)]
    for cert_id in catalog["certs"]:
        row = [f"`{cert_id}`"]
        # Same distinction as the language columns: a certification that never
        # declared a video in German is not missing one.
        declared = set(pipeline.video_languages(cert_id))
        for lang in VIDEO_LANGS:
            if lang not in declared:
                row.append("–")
                continue
            rendered = REPO / "media" / "certs" / cert_id / lang / "video.mp4"
            row.append("✅" if rendered.exists() else "❌")
        lines.append("| " + " | ".join(row) + " |")

    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if "--check" in sys.argv:
        # Gate mode: prove the dashboard matches the tree instead of assuming it.
        drift = check()
        if drift:
            print("STATUS.md does not match the filesystem. It is generated, never "
                  "written by hand — run `teach status`:\n")
            print("\n".join(drift[:40]))
            sys.exit(1)
        print("STATUS.md matches the filesystem.")
        sys.exit(0)
    print("STATUS.md updated" if refresh() else "STATUS.md already current")
