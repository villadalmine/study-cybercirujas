#!/usr/bin/env python3
"""Is each claim in a topic supported by the sources the topic declares?

Claims are the sentences of content.md; premises are the topic's frozen syllabus
entry and the documents it cites, downloaded once into .cache/groundedness/
(keyed by the URL's sha256). A pinned GLiClass model scores each claim against
the windows of those documents sharing the most words with it; under the
threshold it is "unsupported". --deep sends the suspects to Granite Guardian on
a llama-server you run. Models, hashes, thresholds and mode: groundedness.yaml.
It finds "a number, list or output the source does not say", not a bad design.

    scripts/check_groundedness.py --download                  # once: pinned weights (network)
    scripts/check_groundedness.py --base origin/main --fetch  # topics changed against main
    scripts/check_groundedness.py certs/cka/1.1/en --deep     # suspects through Guardian
    scripts/check_groundedness.py --dry-run certs/cka/1.1/en  # claims and sources, no model
    scripts/check_groundedness.py --fixture tests/fixtures/groundedness
"""
from __future__ import annotations

import argparse
import hashlib
import html
import io
import json
import math
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from teach.core import certs, references  # noqa: E402

CACHE = Path(os.environ.get("GROUNDEDNESS_CACHE", REPO / ".cache" / "groundedness"))
CFG = yaml.safe_load((REPO / "groundedness.yaml").read_text(encoding="utf-8"))
MODEL = CACHE / "models" / f"{CFG['prefilter']['repo'].replace('/', '--')}@{CFG['prefilter']['revision']}"
URL = re.compile(r"https?://[^\s)\]>\"'`]+")
TOPIC = re.compile(r"^certs/[^/]+/[^/]+/[^/]+/content\.md$")
SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[\"'(¿¡A-Z0-9ÁÉÍÓÚÑ])")
WORD = re.compile(r"[a-z0-9áéíóúñü][a-z0-9áéíóúñü._/-]*")


def sha(data: str | bytes) -> str:
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def claims(text: str, min_words: int = CFG["segmentation"]["min_words"]) -> list[dict]:
    """Sentences of the prose (no code, headings, tables, comments or References),
    each with a stable id L<line of its paragraph>.<n>."""
    m = references.HEADING.search(text)
    out, block, start, fence = [], [], 0, False

    def flush():
        prose = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", " ".join(block))
        prose = re.sub(r"\s+", " ", re.sub(r"[*`]+", "", prose)).strip()
        out.extend({"id": f"L{start}.{n}", "text": s} for n, s in enumerate(SENTENCE.split(prose), 1)
                   if len(s.split()) >= min_words)
        block.clear()

    for i, line in enumerate((text[:m.start()] if m else text).split("\n"), 1):
        bare, item = line.strip(), re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", line)
        if bare.startswith(("```", "~~~")):
            fence = not fence
        if fence or bare.startswith(("```", "~~~", "#", "|", "<!--")) or not bare or item:
            flush()
            if fence or not item or bare.startswith(("```", "~~~")):
                continue
            line = line[item.end():]
        start = start if block else i
        block.append(line.strip().lstrip("> "))
    flush()
    return out


def syllabus(cert: str, topic: str) -> tuple[str, list[str]]:
    """The frozen syllabus entry and its sources. The weight is left out: it is the
    project's normalised share, not the vendor's figure, and would back a wrong claim."""
    for t in certs.topics(cert):
        if str(t.get("id")) == topic:
            text = f"{certs.load(cert).metadata.get('exam', cert)} syllabus, topic {topic} ({t.get('topic', '')}): {t.get('title', '')}."
            return text, list(t.get("sources") or [])
    return "", []


def cited(lang_dir: Path) -> list[str]:
    """content.md References, meta.yaml sources and the syllabus topic's sources."""
    refs, meta = references.section((lang_dir / "content.md").read_text(encoding="utf-8")), lang_dir / "meta.yaml"
    urls = set(URL.findall(refs or ""))
    urls |= set((yaml.safe_load(meta.read_text(encoding="utf-8")) or {}).get("sources") or []) if meta.exists() else set()
    urls |= set(syllabus(lang_dir.parts[-3], lang_dir.parts[-2])[1])
    return sorted({u.split("#")[0].rstrip(".,;:>") for u in urls})


def fetch(url: str) -> str | None:
    """Download a citation as text into the cache: the only network use besides --download."""
    req = urllib.request.Request(url, headers={"User-Agent": "study-cybercirujas groundedness check"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body, kind = r.read(), r.headers.get("Content-Type", "")
    except Exception as e:  # noqa: BLE001 — a dead link is check_citations' finding, not a crash here
        print(f"  not available: {url} ({type(e).__name__})", file=sys.stderr)
        return None
    if "pdf" in kind or body[:5] == b"%PDF-":
        from pypdf import PdfReader
        text = " ".join(p.extract_text() or "" for p in PdfReader(io.BytesIO(body)).pages)
    else:
        text = re.sub(r"(?is)<(script|style|noscript|nav|header|footer|svg)\b.*?</\1>", " ", body.decode("utf-8", "replace"))
        text = html.unescape(re.sub(r"(?s)<[^>]+>", " ", text))
    text = re.sub(r"\s+", " ", text).strip()
    (CACHE / "sources").mkdir(parents=True, exist_ok=True)
    (CACHE / "sources" / f"{sha(url)}.txt").write_text(text, encoding="utf-8")
    return text


def windows(text: str) -> list[str]:
    r = CFG["retrieval"]
    words, step = text.split(), r["chunk_words"] - r["overlap_words"]
    return [" ".join(words[i:i + r["chunk_words"]]) for i in range(0, max(len(words) - r["overlap_words"], 1), step)]


def best_windows(claim: str, wins: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """The top_k windows sharing the most words with the claim; ties keep source order."""
    want = set(WORD.findall(claim.lower()))
    ranked = sorted(range(len(wins)), key=lambda i: (-len(want & set(WORD.findall(wins[i][1].lower()))), i))
    return [wins[i] for i in ranked[:CFG["retrieval"]["top_k"]]]


def download() -> None:
    from huggingface_hub import snapshot_download
    p = CFG["prefilter"]
    snapshot_download(p["repo"], revision=p["revision"], local_dir=MODEL)
    for name, digest in p["sha256"].items():
        if sha((MODEL / name).read_bytes()) != digest:
            raise SystemExit(f"groundedness: the sha256 of {name} is not the one in groundedness.yaml")
    print(f"groundedness: {p['repo']}@{p['revision'][:12]} in {MODEL}")


class Prefilter:
    """GLiClass as NLI: premise = the source window, label = the claim; score = P(supported)."""

    def __init__(self):
        p = CFG["prefilter"]
        if not (MODEL / "model.safetensors").exists():
            raise SystemExit("groundedness: no weights; run scripts/check_groundedness.py --download first")
        os.environ["HF_HUB_OFFLINE"] = "1"
        import torch
        from gliclass import GLiClassModel, ZeroShotClassificationPipeline
        from transformers import AutoTokenizer
        torch.set_num_threads(p["threads"])
        torch.manual_seed(42)
        self.pipe = ZeroShotClassificationPipeline(
            GLiClassModel.from_pretrained(MODEL).eval(), AutoTokenizer.from_pretrained(MODEL),
            classification_type="multi-label", device="cpu", max_length=p["max_length"], progress_bar=False)

    def score(self, premise: str, claim: str) -> float:
        return round(float(self.pipe(premise, [claim], threshold=0.0)[0][0]["score"]), 4)


def guardian(premise: str, claim: str) -> float:
    """P("yes" = ungrounded) from Granite Guardian on the llama-server at GUARDIAN_URL."""
    doc = json.dumps({"doc_id": "0", "text": premise}, ensure_ascii=False)
    prompt = CFG["deep"]["prompt"].replace("{document}", doc).replace("{claim}", claim)
    body = json.dumps({"prompt": prompt, "n_predict": 24, "temperature": 0, "seed": 42, "n_probs": 5,
                       "cache_prompt": False}).encode()
    url = os.environ.get("GUARDIAN_URL", CFG["deep"]["url"]).rstrip("/") + "/completion"
    with urllib.request.urlopen(urllib.request.Request(url, body, {"Content-Type": "application/json"}), timeout=600) as r:
        resp = json.load(r)
    for tok in resp.get("completion_probabilities") or []:
        probs = {}
        for c in tok.get("top_logprobs") or tok.get("probs") or []:
            t, lp = (c.get("token") or c.get("tok_str") or "").strip().lower(), c.get("logprob")
            if t in ("yes", "no"):
                probs[t] = max(probs.get(t, 0.0), math.exp(lp) if lp is not None else c.get("prob", 0.0))
        if probs:
            return round(probs.get("yes", 0.0) / (sum(probs.values()) + 1e-12), 4)
    verdict = re.findall(r"<score>\s*(\w+)", resp.get("content", ""))
    return 1.0 if verdict and verdict[0].lower() == "yes" else 0.0


def check_topic(lang_dir: Path, score=None, deep=None, fetch_missing: bool = False) -> dict:
    content = (lang_dir / "content.md").read_text(encoding="utf-8")
    entry = syllabus(lang_dir.parts[-3], lang_dir.parts[-2])[0]
    docs = [("syllabus", entry)] if entry else []
    sources = [{"source": "syllabus", "sha256": sha(entry)}] if entry else []
    for url in cited(lang_dir):
        f = CACHE / "sources" / f"{sha(url)}.txt"
        text = f.read_text(encoding="utf-8") if f.exists() else (fetch(url) if fetch_missing else None)
        sources.append({"source": url, "sha256": sha(text)} if text else {"source": url, "status": "not available"})
        docs += [(url, text)] if text else []
    wins = [(src, w) for src, text in docs for w in windows(text)]
    found = claims(content)
    report = {"topic": lang_dir.resolve().relative_to(REPO).as_posix(), "content_sha256": sha(content),
              "model": f"{CFG['prefilter']['repo']}@{CFG['prefilter']['revision']}",
              "threshold": CFG["prefilter"]["threshold"], "sources": sources, "claims": len(found), "unsupported": []}
    if score is None:
        return report | {"claim_list": found}
    for c in found:
        top = best_windows(c["text"], wins)
        best = max(((score(w, c["text"]), src) for src, w in top), default=(0.0, None))
        if best[0] < CFG["prefilter"]["threshold"]:
            row = {"id": c["id"], "claim": c["text"], "score": best[0], "best_source": best[1]}
            if deep:
                row["guardian"] = deep("\n\n".join(w for _, w in top), c["text"])
                row["confirmed"] = row["guardian"] >= CFG["deep"]["threshold"]
            report["unsupported"].append(row)
    flagged = [r for r in report["unsupported"] if r.get("confirmed", True)]
    how = "confirmed by Granite Guardian" if deep else "GLiClass prefilter, not confirmed"
    return report | {"result": "fail" if flagged else "pass",
                     "evidence": f"{len(flagged)} of {len(found)} claims unsupported ({how})"}


def write_quality(lang_dir: Path, report: dict) -> None:
    """Upsert the `groundedness` entry of meta.yaml `quality.checks` (the shape of PR #11)."""
    path = lang_dir / "meta.yaml"
    meta = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    q = meta.setdefault("quality", {})
    q["checks"] = [c for c in q.get("checks") or [] if c.get("name") != "groundedness"] + [
        {"name": "groundedness", "version": str(CFG["version"]), "result": report["result"],
         "weight": CFG["quality"]["weight"], "ran_at": None, "evidence": report["evidence"]}]
    path.write_text(yaml.safe_dump(meta, sort_keys=False, allow_unicode=True, width=1000), encoding="utf-8")


def fixture(path: Path, score, deep=None) -> dict:
    """A labelled fixture's claims against their own sources: per-claim scores and the metrics."""
    sources = json.loads((path / "sources.json").read_text(encoding="utf-8"))
    rows = []
    for line in (path / "claims.jsonl").read_text(encoding="utf-8").splitlines():
        c = json.loads(line)
        s = (deep or score)(sources[c["source"]], c["claim"])
        flagged = s >= CFG["deep"]["threshold"] if deep else s < CFG["prefilter"]["threshold"]
        rows.append({"id": c["id"], "origin": c["origin"], "supported": c["supported"], "score": s, "flagged": flagged})
    traps, good = [r for r in rows if r["origin"] == "pr6"], [r for r in rows if r["supported"]]
    return {"model": CFG["deep"]["repo"] if deep else CFG["prefilter"]["repo"], "claims": rows,
            "accuracy": round(sum(r["flagged"] != r["supported"] for r in rows) / len(rows), 3),
            "pr6_traps_caught": f"{sum(r['flagged'] for r in traps)}/{len(traps)}",
            "false_alarms": f"{sum(r['flagged'] for r in good)}/{len(good)}"}


def changed(base: str) -> list[Path]:
    out = subprocess.run(["git", "diff", "--name-only", "--diff-filter=AMR", f"{base}...HEAD"], cwd=REPO,
                         capture_output=True, text=True, check=True).stdout.split()
    return sorted({REPO / Path(f).parent for f in out if TOPIC.match(f)})


def summary(reports: list[dict]) -> str:
    lines = [f"## Groundedness ({CFG['mode']} mode, threshold {CFG['prefilter']['threshold']})", ""]
    for r in reports:
        missing = [s["source"] for s in r["sources"] if s.get("status")]
        lines += [f"### `{r['topic']}` — {r['result']}: {r['evidence']}", ""]
        lines += [f"Sources not available: {', '.join(missing)}", ""] if missing else []
        lines += ["| claim | score | text |", "| :-- | --: | :-- |"] if r["unsupported"] else []
        lines += [f"| {u['id']} | {u['score']} | {u['claim'][:160].replace('|', '/')} |" for u in r["unsupported"]] + [""]
    return "\n".join(lines + ([] if reports else ["No topic content changed.", ""]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("topics", nargs="*", type=Path, help="certs/<cert>/<topic>/<lang> directories")
    ap.add_argument("--base", help="also check the topics whose content.md changed against this git ref")
    ap.add_argument("--fetch", action="store_true", help="download citations missing from the cache (network)")
    ap.add_argument("--download", action="store_true", help="download the pinned weights, check their sha256")
    ap.add_argument("--deep", action="store_true", help="confirm the suspects with Granite Guardian")
    ap.add_argument("--dry-run", action="store_true", help="claims and sources only, no model")
    ap.add_argument("--write", action="store_true", help="record the result in meta.yaml quality:")
    ap.add_argument("--fixture", type=Path, help="score a labelled fixture directory instead of topics")
    ap.add_argument("--json", type=Path, help="write the full report here")
    ap.add_argument("--summary", type=Path, help="append the Markdown summary here ($GITHUB_STEP_SUMMARY)")
    a = ap.parse_args()
    if a.download:
        download()
        if not (a.topics or a.base or a.fixture):
            return 0
    score = None if a.dry_run or (a.fixture and a.deep) else Prefilter().score
    deep = guardian if a.deep else None
    if a.fixture:
        reports = [fixture(a.fixture, score, deep)]
        print("groundedness fixture: accuracy {accuracy}, PR #6 traps {pr6_traps_caught}, "
              "false alarms {false_alarms}".format(**reports[0]))
    else:
        topics = sorted({t.resolve() for t in a.topics} | set(changed(a.base) if a.base else []))
        reports = [check_topic(t, score, deep, a.fetch) for t in topics]
        for r in reports:
            print(f"{r['topic']}: {r.get('evidence', str(r['claims']) + ' claims (dry run)')}")
            if a.write and score:
                write_quality(REPO / r["topic"], r)
        if a.summary and score:
            with a.summary.open("a", encoding="utf-8") as f:
                f.write(summary(reports))
    if a.json:
        a.json.write_text(json.dumps(reports, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    failed = any(r.get("result") == "fail" for r in reports)
    return 1 if failed and CFG["mode"] == "block" and not a.fixture else 0


if __name__ == "__main__":
    sys.exit(main())
