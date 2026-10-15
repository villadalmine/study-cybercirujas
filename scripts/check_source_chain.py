#!/usr/bin/env python3
"""Does every link of the source chain say where it comes from?

docs/PRINCIPLES.md -> "The source chain": each artefact rests only on the one
before it and declares which one.

    1 syllabus     certs/<cert>.md          version (or "unknown"), snapshot_date, source URL
    2 content      <topic>/<lang>/content.md   meta.yaml `sources` + a References section with URLs
    3 labs         <topic>/lab/lab.yaml        cert + topic of its own directory, a topic that is in
                                               the syllabus; v2 labs also `derived_from` (syllabus
                                               topic + the content file and its sha256)
    4 translations <topic>/<lang>/meta.yaml    `translated_from` + `source_sha256` of the source files
    5 videos       media/certs/<cert>/<lang>/script.yaml   cert + lang + `derived_from`
                                               (the syllabus file and its sha256)

Fails when a link does not declare its origin. When it declares a hash and the
origin changed afterwards, it reports the link as STALE (a warning: the
material may still be right, a person decides), the same way a topic is
marked stale when its syllabus changes.

Artefacts made before origins were recorded are listed, path by path, in
tests/fixtures/source_chain_baseline.txt. That list only shrinks: anything new
must declare its origin. Deterministic, offline, no model.

    scripts/check_source_chain.py            # check, exit 1 on a missing origin
    scripts/check_source_chain.py --report   # the numbers per link, for a PR or a doc
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from teach.core.certs import chain_sha256 as sha256_of  # noqa: E402  (one hash definition)
from teach.core.certs import translation_source_sha256  # noqa: E402
BASELINE = REPO / "tests" / "fixtures" / "source_chain_baseline.txt"
REFS_HEADING = re.compile(
    r"^#+\s*(?:[0-9]+[.)]?\s*)?(Referencias|References|Références|Referenzen|Referências|参考文献|参考)",
    re.I | re.M,
)
URL = re.compile(r"https?://[^\s)\]>\"'`]+")


def frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    return yaml.safe_load(text.split("---", 2)[1]) or {}


def load_yaml(path: Path) -> dict:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return {}


def rel(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def baseline() -> set[str]:
    if not BASELINE.exists():
        return set()
    return {line.split("#", 1)[0].strip() for line in BASELINE.read_text(encoding="utf-8").splitlines()
            if line.split("#", 1)[0].strip()}


BASELINE_HEADER = """# Links of the source chain made before their origin was recorded (2026-10-15).
# scripts/check_source_chain.py accepts these without a declared origin; every
# new artefact must declare one. This list only shrinks: regenerating or
# re-deriving an entry with the current pipeline records its origin, and the
# check then asks for its line to be deleted. Adding a line needs a reason in
# the PR. Labs and syllabi are never here: they are fixed, not excused.
"""


class Chain:
    def __init__(self) -> None:
        self.counts: dict[str, Counter] = {}
        self.missing: list[tuple[str, str]] = []   # (path, what is missing)
        self.stale: list[tuple[str, str]] = []
        self.legacy: set[str] = baseline()
        self.legacy_seen: set[str] = set()
        self.syllabus_topics: dict[str, set[str]] = {}

    def count(self, link: str, key: str) -> None:
        self.counts.setdefault(link, Counter())[key] += 1

    def lack(self, link: str, path: str, what: str, legacy_ok: bool = False) -> None:
        if legacy_ok and path in self.legacy:
            self.legacy_seen.add(path)
            self.count(link, "legacy (baseline)")
            return
        self.count(link, "missing")
        self.missing.append((path, what))

    # 1 ------------------------------------------------------------------
    def syllabi(self) -> None:
        for path in sorted((REPO / "certs").glob("*.md")):
            front = frontmatter(path)
            topics = front.get("topics") or []
            self.syllabus_topics[path.stem] = {str(t.get("id")) for t in topics}
            if not topics:
                self.count("1 syllabus", "no topics yet (placeholder)")
                continue
            self.count("1 syllabus", "total")
            gaps = [k for k in ("snapshot_date", "sources") if not front.get(k)]
            if "version" not in front:
                gaps.append("version (or 'unknown')")
            if gaps:
                self.lack("1 syllabus", rel(path), ", ".join(gaps))
            else:
                self.count("1 syllabus", "declared")
            if str(front.get("version") or "unknown") == "unknown":
                self.count("1 syllabus", "version 'unknown' (vendor publishes none)")

    # 2 and 4 ------------------------------------------------------------
    def content_and_translations(self) -> None:
        for content in sorted((REPO / "certs").glob("*/*/*/content.md")):
            lang_dir = content.parent
            meta = load_yaml(lang_dir / "meta.yaml")
            self.count("2 content", "total")
            refs = REFS_HEADING.search(content.read_text(encoding="utf-8", errors="replace"))
            urls = URL.findall(content.read_text(encoding="utf-8", errors="replace")[refs.end():]) if refs else []
            gaps = []
            if not meta.get("sources"):
                gaps.append("meta.yaml sources")
            if not urls:
                gaps.append("a References section with URLs")
            if gaps:
                self.lack("2 content", rel(content), " and ".join(gaps), legacy_ok=True)
            else:
                self.count("2 content", "declared")
            source_lang = meta.get("translated_from")
            if not source_lang:
                continue
            self.count("4 translations", "total")
            said = meta.get("source_sha256")
            if not said:
                self.lack("4 translations", rel(lang_dir / "meta.yaml"), "source_sha256", legacy_ok=True)
                continue
            self.count("4 translations", "declared")
            if said != translation_source_sha256(lang_dir.parent, str(source_lang)):
                self.count("4 translations", "STALE (source changed)")
                self.stale.append((rel(lang_dir), f"its {source_lang} source changed after translation"))

    # 3 ------------------------------------------------------------------
    def labs(self) -> None:
        for spec_file in sorted((REPO / "certs").glob("*/*/lab/lab.yaml")):
            spec = load_yaml(spec_file)
            cert, topic = spec_file.parent.parent.parent.name, spec_file.parent.parent.name
            self.count("3 labs", "total")
            gaps = []
            if str(spec.get("cert")) != cert or str(spec.get("topic")) != topic:
                gaps.append(f"cert/topic {spec.get('cert')}/{spec.get('topic')} != its directory {cert}/{topic}")
            if topic not in self.syllabus_topics.get(cert, set()):
                gaps.append(f"topic {topic} is not in certs/{cert}.md")
            if spec.get("schema_version") == 2:
                self.count("3 labs", "v2")
                derived = spec.get("derived_from") or {}
                if not (derived.get("syllabus") and derived.get("content") and derived.get("content_sha256")):
                    gaps.append("derived_from (syllabus, content, content_sha256)")
                else:
                    content = REPO / derived["content"]
                    if not content.exists():
                        gaps.append(f"derived_from.content {derived['content']} does not exist")
                    elif sha256_of(content) != derived["content_sha256"]:
                        self.count("3 labs", "STALE (content changed)")
                        self.stale.append((rel(spec_file), f"{derived['content']} changed after the lab was derived"))
            if gaps:
                self.lack("3 labs", rel(spec_file), "; ".join(gaps))
            else:
                self.count("3 labs", "declared")

    # 5 ------------------------------------------------------------------
    def videos(self) -> None:
        for script in sorted((REPO / "media" / "certs").glob("*/*/script.yaml")):
            data = load_yaml(script)
            cert, lang = script.parent.parent.name, script.parent.name
            self.count("5 videos", "total")
            if data.get("cert") != cert or data.get("lang") != lang:
                self.lack("5 videos", rel(script), f"cert/lang {data.get('cert')}/{data.get('lang')} != {cert}/{lang}")
                continue
            derived = data.get("derived_from") or {}
            if not derived.get("syllabus_sha256"):
                self.lack("5 videos", rel(script), "derived_from.syllabus_sha256", legacy_ok=True)
                continue
            self.count("5 videos", "declared")
            if derived["syllabus_sha256"] != sha256_of(REPO / "certs" / f"{cert}.md"):
                self.count("5 videos", "STALE (syllabus changed)")
                self.stale.append((rel(script), f"certs/{cert}.md changed after the script was written"))

    def run(self) -> "Chain":
        self.syllabi()
        self.content_and_translations()
        self.labs()
        self.videos()
        return self


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", action="store_true", help="print the numbers per link")
    parser.add_argument("--write-baseline", action="store_true",
                        help="(maintainer) write the current legacy links to the baseline; it must only shrink")
    args = parser.parse_args(argv)
    if args.write_baseline:
        BASELINE.write_text("", encoding="utf-8")
        missing = Chain().run().missing
        legacy = sorted(path for path, what in missing
                        if not path.endswith("lab.yaml") and not re.fullmatch(r"certs/[^/]+\.md", path))
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(BASELINE_HEADER + "".join(f"{p}\n" for p in legacy))
        print(f"baseline: {len(legacy)} legacy link(s) written to {rel(BASELINE)}")
        return 0
    chain = Chain().run()
    if args.report:
        for link in sorted(chain.counts):
            print(f"{link}: " + ", ".join(f"{k} {v}" for k, v in sorted(chain.counts[link].items())))
    for path, why in chain.stale:
        print(f"chain: STALE {path}: {why}")
    gone = sorted(chain.legacy - chain.legacy_seen)
    for path in gone:
        print(f"chain: baseline entry {path} no longer needs an exception — delete its line")
    for path, what in chain.missing:
        print(f"chain: {path} does not declare its origin: {what}")
    if chain.missing or gone:
        print(f"\n{len(chain.missing)} link(s) without origin, {len(gone)} stale baseline line(s). "
              "See docs/PRINCIPLES.md -> The source chain.")
        return 1
    print(f"chain: OK — every link declares its origin ({len(chain.legacy_seen)} legacy in the baseline, "
          f"{len(chain.stale)} stale).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
