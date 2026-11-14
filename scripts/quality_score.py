#!/usr/bin/env python3
"""Score every topic and language from the checks that exist, and record it in meta.yaml.

Each `certs/<cert>/<topic>/<lang>/meta.yaml` gets a `quality:` block, written
by this script and never by hand: one entry per check (name, version, result
pass | fail | not_run, weight, ran_at, evidence), the score and the level.
Weights, penalties and level thresholds live in quality_weights.yaml.

Deterministic and offline: the same tree and the same weights give the same
blocks, byte for byte. A check that cannot run here (network, a model, a
person) is `not_run` and costs part of its weight; nothing is assumed to pass.
`ran_at` is the date a recorded fact happened (a lab verified, a review, a
human edit); for checks this script evaluates from the files it is null —
the result is a function of the files, not of when it was computed.

    make quality                              # rewrite the blocks (after generating or editing)
    scripts/quality_score.py --check          # CI: fail if any block is not what the tree gives
    scripts/quality_score.py --report         # the distribution, per certification
    scripts/quality_score.py certs/cka        # one certification
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "scripts"))

import check_k8s_apis  # noqa: E402
import check_manifests  # noqa: E402
import check_source_chain  # noqa: E402
import check_sources  # noqa: E402
from teach.core import generator, quality  # noqa: E402
from teach.core.scoring import level_for, load_weights, score  # noqa: E402
from teach.lab import kc_meta, kc_scope, spec  # noqa: E402

KNOWN_BROKEN_LABS = REPO / "tests" / "fixtures" / "labs_known_broken.txt"
LAB_EVIDENCE = kc_scope.EVIDENCE_FILE   # deploy/lab-evidence.yaml: lab -> target -> {date, lab_hash, evidence, runner}
LAB_EVIDENCE_NAME = LAB_EVIDENCE.relative_to(REPO).as_posix()
RUN_LINK = re.compile(r"https://\S+")
LOG_SHA = re.compile(r"(?:(\S+)\s+)?sha256[:\s]+([0-9a-f]{64})\b")
REPO_PATH = re.compile(r"^[\w.-]+(?:/[\w.-]+)+$")
CHECK_VERSION = "1"


def entry(name: str, result: str, weights: dict, evidence: str, ran_at: str | None = None) -> dict:
    return {"name": name, "version": CHECK_VERSION, "result": result,
            "weight": weights["checks"][name]["weight"], "ran_at": ran_at, "evidence": evidence}


class Context:
    """What is loaded once for the whole corpus."""

    def __init__(self) -> None:
        self.weights = load_weights()
        self.owner, self.neutral, _ = check_sources.catalogue()
        chain = check_source_chain.Chain().run()
        self.chain_missing = {path for path, _ in chain.missing}
        self.chain_stale = {path for path, _ in chain.stale}
        self.chain_legacy = chain.legacy_seen
        self.broken_labs = set()
        if KNOWN_BROKEN_LABS.exists():
            for line in KNOWN_BROKEN_LABS.read_text(encoding="utf-8").splitlines():
                path = line.split("#", 1)[0].strip()
                if path:
                    self.broken_labs.add(path)
        self.lab_evidence = kc_scope.load_evidence(LAB_EVIDENCE)


def rel(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def floor_check(lang_dir: Path, w: dict) -> dict:
    problems = [f"{p.name}: {msg}" for p in (lang_dir / "content.md", lang_dir / "exercises.md")
                for msg in quality.check_file(p)]
    if problems:
        return entry("quality_floor", "fail", w, "; ".join(problems)[:300])
    return entry("quality_floor", "pass", w, "content.md and exercises.md meet the floor")


def provenance_check(meta: dict, w: dict) -> dict:
    missing = [k for k in ("backend", "model", "generated_at") if not meta.get(k)]
    unknown = [k for k in ("backend", "model") if str(meta.get(k)).lower() == "unknown"]
    if missing or unknown:
        return entry("provenance", "fail", w, "meta.yaml: " + ", ".join(
            [f"no {k}" for k in missing] + [f"{k} unknown" for k in unknown]))
    return entry("provenance", "pass", w, f"{meta['backend']} / {meta['model']}, {str(meta['generated_at'])[:10]}")


def sources_check(content: Path, ctx: Context) -> dict:
    w = ctx.weights
    domains = check_sources.cited_domains(content)
    if not domains:
        return entry("sources", "fail", w, "no URL under a References heading")
    known = sum(1 for d in domains if d in ctx.owner or d in ctx.neutral)
    share = known / len(domains)
    evidence = f"{len(domains)} citation(s), {round(100 * share)}% from catalogued projects"
    return entry("sources", "pass" if share >= w["sources_min_catalogued"] else "fail", w, evidence)


def k8s_check(lang_dir: Path, w: dict) -> dict | None:
    blocks = broken = removed = 0
    for path in (lang_dir / "content.md", lang_dir / "exercises.md"):
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        blocks += sum(1 for m in check_manifests.BLOCK.finditer(text) if not check_manifests._skip(m.group(2)))
        broken += len(check_manifests.problems(path))
        removed += sum(1 for f in check_k8s_apis.findings(path) if not f[4])
    if not blocks and not removed:
        return None   # nothing to check: the topic has no YAML/JSON manifests
    if broken or removed:
        return entry("k8s_manifests", "fail", w, f"{blocks} block(s): {broken} do not parse, {removed} removed API(s)")
    return entry("k8s_manifests", "pass", w, f"{blocks} YAML/JSON block(s) parse; no removed Kubernetes API")


def translation_check(lang_dir: Path, meta: dict, w: dict) -> dict | None:
    source_lang = meta.get("translated_from")
    if not source_lang:
        return None
    problems = []
    for name in ("content.md", "exercises.md"):
        source, target = lang_dir.parent / str(source_lang) / name, lang_dir / name
        if not source.exists() or not target.exists():
            problems.append(f"{name}: missing {'source' if not source.exists() else 'translation'}")
            continue
        try:
            generator._verify_translation(source.read_text(encoding="utf-8"), target.read_text(encoding="utf-8"), name)
        except generator.GeneratorConfigError as error:
            problems.append(re.sub(r"^The \S+ translation does not preserve the source structure: ", f"{name}: ", str(error)))
    if problems:
        return entry("translation_gate", "fail", w, f"against {source_lang}: " + "; ".join(problems)[:300])
    return entry("translation_gate", "pass", w, f"structure preserved against {source_lang}")


def chain_check(lang_dir: Path, meta: dict, ctx: Context) -> dict:
    w = ctx.weights
    path = rel(lang_dir / ("meta.yaml" if meta.get("translated_from") else "content.md"))
    if path in ctx.chain_legacy:
        return entry("source_chain", "not_run", w, "made before origins were recorded (source_chain_baseline.txt)")
    if path in ctx.chain_missing:
        return entry("source_chain", "fail", w, "does not declare its origin")
    stale = rel(lang_dir) if meta.get("translated_from") else None
    if stale and stale in ctx.chain_stale:
        return entry("source_chain", "fail", w, "STALE: its source changed after translation")
    return entry("source_chain", "pass", w, "declares its origin" + (" (source_sha256 matches)" if stale else " (sources + References)"))


def proof_problem(evidence: str) -> str | None:
    """Why a recorded `evidence` is not a proof that can be checked, or None when it is one.

    A proof is a run link (https://...) or the sha256 of a log. When the log is a file in this repository,
    its sha256 must be the recorded one: a log edited or deleted after the entry is not evidence any more.
    A person's report ("by <login>") is neither: it is kept in the evidence file, it earns no credit here."""
    logs = LOG_SHA.findall(evidence)
    for path, digest in logs:
        if path and REPO_PATH.match(path) and not RUN_LINK.match(path):
            log = (REPO / path).resolve()
            if REPO.resolve() not in log.parents or not log.is_file():
                return f"names the log {path}, which is not in the repository"
            if hashlib.sha256(log.read_bytes()).hexdigest() != digest:
                return f"the sha256 of {path} is not the recorded one"
    if logs or RUN_LINK.search(evidence):
        return None
    return "no run link or log sha256"


def lab_check(topic_dir: Path, ctx: Context) -> dict:
    """Credit only a proof that can be checked (#217): an entry in deploy/lab-evidence.yaml for the lab AS IT IS NOW.

    The entry must carry the lab_hash of the current lab folder (teach/lab/kc_meta.py) and a run link or a log sha256.
    lab.yaml's `verified:` block is self-declared, so on its own it earns nothing: it stays visible in the evidence as
    "claimed, not proven". Evidence for an older hash is stale (the lab changed after it was proven) and earns nothing.
    """
    w = ctx.weights
    spec_file = topic_dir / "lab" / "lab.yaml"
    if rel(topic_dir / "lab") in ctx.broken_labs:
        return entry("lab", "fail", w, "listed in tests/fixtures/labs_known_broken.txt")
    if not spec_file.exists():
        return entry("lab", "not_run", w, "no lab")
    lab_id = f"{topic_dir.parent.name}/{topic_dir.name}"
    recorded = ctx.lab_evidence.get(lab_id) or {}
    raw = yaml.safe_load(spec_file.read_text(encoding="utf-8")) or {}
    claim = raw.get("verified") if isinstance(raw.get("verified"), dict) else {}
    claimed = "claimed, not proven: lab.yaml says verified, " if claim.get("status") is True else ""
    if not recorded:
        if claimed:
            return entry("lab", "not_run", w, f"{claimed}no entry in {LAB_EVIDENCE_NAME}")
        return entry("lab", "not_run", w, "not yet run in the study-lab runner")
    try:
        current = kc_meta.lab_hash(spec.load(topic_dir / "lab", "curated"))
    except spec.SpecError as error:
        return entry("lab", "not_run", w, f"{claimed}the lab does not load: {error}"[:200])
    why = {}
    for target, e in sorted(recorded.items(), key=lambda te: (te[1]["date"], te[0]), reverse=True):
        if e["lab_hash"] != current:
            why[target] = f"stale on {target}: proven for lab hash {e['lab_hash'][:8]}, the lab is now {current[:8]}"
        elif problem := proof_problem(str(e["evidence"])):
            why[target] = f"{target}: {problem}"
        else:
            return entry("lab", "pass", w, f"proven on {target} for the current lab hash: {e['evidence']}"[:200],
                         ran_at=e["date"])
    return entry("lab", "not_run", w, f"{claimed}no usable proof in {LAB_EVIDENCE_NAME} ({'; '.join(why.values())})"[:300])


def review_check(meta: dict, w: dict) -> dict:
    """The LATEST review decides (docs/REVIEWS.md): a later fail outweighs an earlier pass.

    Latest by date; on the same date, the one listed last. A review without a
    date is the oldest (it sorts before any ISO date), never the latest. A
    result other than pass counts as fail.
    """
    reviews = [r for r in meta.get("reviews") or [] if isinstance(r, dict)]
    if not reviews:
        return entry("independent_review", "not_run", w, "no independent review recorded")
    latest = max(enumerate(reviews), key=lambda ir: (str(ir[1].get("date") or ""), ir[0]))[1]
    result = "pass" if latest.get("result") == "pass" else "fail"
    return entry("independent_review", result, w, f"latest of {len(reviews)}: {latest.get('by')}: {latest.get('link')}",
                 ran_at=str(latest.get("date")) if latest.get("date") else None)


def human_check(meta: dict, w: dict) -> dict:
    edits = [e for e in meta.get("human_edits") or [] if isinstance(e, dict)]
    if edits:
        last = sorted(edits, key=lambda e: str(e.get("date")))[-1]
        return entry("human_review", "pass", w, f"{len(edits)} human edit(s), last by {last.get('author')}",
                     ran_at=str(last.get("date")) if last.get("date") else None)
    return entry("human_review", "not_run", w, "no human review or edit recorded")


def groundedness_check(meta: dict, w: dict) -> dict:
    """Keep the result of a recorded `groundedness` entry (written by scripts/check_groundedness.py).

    Only the facts of the run are kept (result, evidence, ran_at). The weight and the
    version are the project's, as for every other check, so quality_weights.yaml decides
    what it is worth and an edited entry cannot score itself. A result other than
    pass or fail is not_run. With no entry recorded it defaults to not_run.
    """
    for recorded in (meta.get("quality") or {}).get("checks") or []:
        if isinstance(recorded, dict) and recorded.get("name") == "groundedness":
            result = recorded.get("result")
            return entry("groundedness", result if result in ("pass", "fail") else "not_run", w,
                         recorded.get("evidence"), ran_at=recorded.get("ran_at"))
    return entry("groundedness", "not_run", w, "pending: the classifier lab decides which model checks it")


def block_for(lang_dir: Path, ctx: Context) -> dict:
    w = ctx.weights
    meta = yaml.safe_load((lang_dir / "meta.yaml").read_text(encoding="utf-8")) or {}
    checks = [floor_check(lang_dir, w), provenance_check(meta, w), sources_check(lang_dir / "content.md", ctx),
              entry("citations_resolve", "not_run", w, "network check: scripts/check_citations.py (not run in CI)"),
              k8s_check(lang_dir, w), translation_check(lang_dir, meta, w), chain_check(lang_dir, meta, ctx),
              lab_check(lang_dir.parent, ctx), review_check(meta, w), human_check(meta, w),
              groundedness_check(meta, w)]
    checks = [c for c in checks if c is not None]
    value = score(checks, w)
    return {"weights_version": w["version"], "score": value, "level": level_for(value, checks, w)["id"],
            "checks": checks}


QUALITY_KEY = re.compile(r"^quality:.*?(?=^\S|\Z)", re.M | re.S)


def render(meta_text: str, block: dict) -> str:
    """meta.yaml with its `quality:` block replaced (or appended); the rest is untouched."""
    body = QUALITY_KEY.sub("", meta_text)
    if body and not body.endswith("\n"):
        body += "\n"
    return body + yaml.safe_dump({"quality": block}, sort_keys=False, allow_unicode=True, width=1000)


def topic_dirs(paths: list[str]) -> list[Path]:
    roots = [REPO / p for p in paths] if paths else [REPO / "certs"]
    found = []
    for root in roots:
        found.extend(p.parent for p in sorted(root.glob("**/content.md"))
                     if (p.parent / "meta.yaml").exists() and p.parent.parent.parent.parent.name == "certs")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="certs/<cert> or a topic directory (default: all of certs/)")
    parser.add_argument("--check", action="store_true", help="fail if a block differs from what the tree gives")
    parser.add_argument("--report", action="store_true", help="the distribution per certification")
    args = parser.parse_args(argv)

    ctx = Context()
    stale, levels, scores = [], defaultdict(Counter), defaultdict(list)
    for lang_dir in topic_dirs(args.paths):
        meta_file = lang_dir / "meta.yaml"
        text = meta_file.read_text(encoding="utf-8")
        block = block_for(lang_dir, ctx)
        wanted = render(text, block)
        cert = lang_dir.parent.parent.name
        levels[cert][block["level"]] += 1
        scores[cert].append(block["score"])
        if wanted != text:
            if args.check:
                stale.append(rel(meta_file))
            elif not args.report:
                with open(meta_file, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(wanted)
    if args.report:
        for cert in sorted(levels):
            mean = round(sum(scores[cert]) / len(scores[cert]), 1)
            print(f"{cert:22} mean {mean:5}  " + "  ".join(f"{k} {v}" for k, v in sorted(levels[cert].items())))
        total = Counter()
        for c in levels.values():
            total.update(c)
        print(f"{'all':22} " + "  ".join(f"{k} {v}" for k, v in sorted(total.items())))
        return 0
    if args.check:
        for path in stale[:20]:
            print(f"quality: {path} — its quality block is not what the tree gives")
        if stale:
            print(f"\n{len(stale)} meta.yaml with a stale quality block. Run `make quality` and commit them.")
            return 1
        print("quality: OK — every quality block is what the tree gives.")
        return 0
    print("quality: blocks written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
