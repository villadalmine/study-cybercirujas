"""What a Killercoda scenario says about itself: certification, syllabus objective, who wrote it and what proved it.

Everything is read from files (catalog.yaml, the frozen syllabus certs/<cert>.md, the topic's meta.yaml, lab.yaml) and
rendered deterministically: the same inputs give the same words. The wording of the quality levels is the study site's
(teach/web/index.html: Verified / AI beta / Draft).
"""

from __future__ import annotations

import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path

import yaml

from . import export_killercoda as kc
from . import runner, spec

LEVELS = {"verified": "Verified", "ai-beta": "AI beta", "draft": "Draft"}
AI_WORDS = re.compile(r"claude|gpt|gemini|llama|opus|sonnet|haiku|codex|openai|anthropic|\bai\b|\bllm\b", re.I)


def _yaml(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) if path.is_file() else None


def syllabus(cert: str, topic: str, title: str) -> dict:
    """The objective in the frozen syllabus of the catalog's tracked version, or an ExportError naming the broken rule."""
    root = runner.REPO_ROOT
    cat = ((_yaml(root / "catalog.yaml") or {}).get("certs") or {}).get(cert)
    if not cat:
        raise kc.ExportError(f"{cert}/{topic}: syllabus R1: certification {cert} is not in catalog.yaml")
    text = (root / cat.get("file", f"certs/{cert}.md")).read_text(encoding="utf-8")
    front = yaml.safe_load(text.split("---", 2)[1])
    row = next((t for t in front.get("topics") or [] if str(t["id"]) == str(topic)), None)
    if not row:
        raise kc.ExportError(f"{cert}/{topic}: syllabus R3: objective {topic} is not in the syllabus of {cert} {cat['tracked_version']}")
    if row["title"] != title:
        raise kc.ExportError(f"{cert}/{topic}: syllabus R5: lab title {title!r} is not the syllabus title {row['title']!r}")
    did, _, dtitle = str(row.get("topic", "")).partition(" - ")
    dom = {"id": did.strip(), "title": dtitle.strip() or did.strip()}
    digest = hashlib.sha256("\0".join([cert, str(cat["tracked_version"]), dom["id"], dom["title"], str(topic), row["title"]])
                            .encode()).hexdigest()
    exam = str(front.get("exam") or cat.get("exam") or cert)
    ver = str(cat["tracked_version"])
    return {"cert": cert, "cert_name": cat.get("name", cert), "exam": exam, "exam_version": ver,
            "label": f"{exam} v{ver}" if ver[:1].isdigit() else f"{exam} ({ver})", "domain": dom,
            "objective": {"id": str(topic), "title": row["title"]}, "objective_sha256": digest,
            "curriculum": {"url": (front.get("sources") or [None])[0], "commit": None}}


def lab_hash(lab: spec.Lab) -> str:
    h = hashlib.sha256()
    # sorted by the relative path's parts, a plain tuple of str: Path objects compare case-insensitively on Windows, so the hash
    # of the same files would differ by OS (a Linux CI hash must equal the one computed on a maintainer's PC)
    for f in sorted((p for p in lab.directory.rglob("*") if p.is_file()), key=lambda p: p.relative_to(lab.directory).parts):
        h.update(f.relative_to(lab.directory).as_posix().encode() + b"\0" + f.read_bytes().replace(b"\r\n", b"\n") + b"\0")
    return h.hexdigest()


def source_commit(lab: spec.Lab) -> str | None:
    """The last commit that touched the lab folder: it only changes when the lab does, so the export stays stable."""
    try:
        out = subprocess.run(["git", "-C", str(runner.REPO_ROOT), "log", "-1", "--format=%H", "--", str(lab.directory)],
                             capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out[:12] or None


def provenance(lab: spec.Lab) -> dict:
    """Who wrote the lab and what reviewed it. lab.yaml (origin) decides; the topic's meta.yaml is only the fallback when the
    lab declares nothing, and its review checks (they judge the topic's material, not the lab) are used only then."""
    o = lab.spec.get("origin") or {}
    cert, topic = lab.spec["cert"], lab.spec["topic"]
    meta = next((m for m in (_yaml(runner.REPO_ROOT / "certs" / cert / topic / lang / "meta.yaml") for lang in ("en", "es")) if m), {})
    q = meta.get("quality") or {}
    who = " ".join(str(o.get(k)) for k in ("generated_by", "author") if o.get(k))
    declared = bool(who) or o.get("kind") in ("community", "generated")
    if declared:
        ai = bool(o.get("generated_by")) or o.get("kind") == "generated" or bool(AI_WORDS.search(who))
        kind, tool, reviews = ("ai" if ai else "human"), (who.split(",")[0] or None), {}
    else:
        backend, model = str(meta.get("backend") or ""), str(meta.get("model") or "")
        kind = "ai" if backend not in ("", "none", "human") else "human" if backend in ("none", "human") else "unknown"
        tool = (backend + (f"/{model}" if model and model != backend else "")) or None
        checks = {c["name"]: c for c in q.get("checks") or []}
        reviews = {k: {"evidence": checks[k].get("evidence"), "date": checks[k].get("ran_at")}
                   for k in ("independent_review", "human_review") if checks.get(k, {}).get("result") == "pass"}
    return {"kind": kind, "tool": tool, "level": q.get("level"), "score": q.get("score"), "reviews": reviews,
            "from": "lab.yaml" if declared else "topic meta.yaml"}


HUMAN_TESTED = Path(__file__).resolve().parents[2] / "deploy" / "killercoda" / "human_tested.yaml"
GITHUB_LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def human_record(key: str, path: Path | None = None) -> dict | None:
    """The validated human_tested.yaml entry of `key` ('cert/topic'), or None. It is rendered into published text, so a bad
    entry stops the export instead of landing on the page: {by: GitHub login, date: ISO date}, exactly those keys."""
    if key not in (_yaml(path or HUMAN_TESTED) or {}):
        return None
    e = _yaml(path or HUMAN_TESTED)[key]
    if not isinstance(e, dict) or set(e) != {"by", "date"}:
        raise kc.ExportError(f"human_tested.yaml {key}: must be a mapping with exactly the keys by and date")
    by, date = e["by"], e["date"]
    if isinstance(date, datetime.date):   # an unquoted YYYY-MM-DD is read by YAML as a date
        date = date.isoformat()
    if not isinstance(by, str) or not GITHUB_LOGIN.match(by):
        raise kc.ExportError(f"human_tested.yaml {key}: by must be a GitHub login (letters, digits, hyphens), got {by!r}")
    if not isinstance(date, str) or not ISO_DATE.match(date):
        raise kc.ExportError(f"human_tested.yaml {key}: date must be YYYY-MM-DD, got {date!r}")
    return {"by": by, "date": date}


def banner(prov: dict, ev: dict | None, human: dict | None = None) -> str:
    lvl = LEVELS.get(prov["level"], prov["level"])
    q = f" Quality level: *{lvl}*" + (f" ({prov['score']}/100)." if prov["score"] is not None else ".") if lvl else ""
    r = prov["reviews"]
    if prov["kind"] == "unknown":
        line = "Authorship not recorded."
    elif prov["kind"] == "human":
        line = f"Written by a human ({prov['tool']})." if prov["tool"] else "Written by a human."
    elif "independent_review" in r:
        line = f"AI-generated ({prov['tool']}), independently reviewed: {r['independent_review']['evidence']}."
    elif "human_review" in r:
        d = r["human_review"]
        line = f"AI-assisted ({prov['tool']}); recorded review: {d['evidence']} ({d['date']})."
    else:
        line = f"AI-generated ({prov['tool'] or 'model not recorded'}), not independently reviewed yet."
    out = f"> **About this lab:** {line}{q}\n"
    if ev:
        e = ev["env"]
        k8s = f", Kubernetes {e['kubernetes']}" if e.get("kubernetes") else ""
        link = f" ([run]({ev['runner']['url']}))" if ev["runner"].get("url") else ""
        note = {"measured": " Environment measured on Killercoda.",
                "partially-measured": " Environment measured on Killercoda (Cilium version assumed)."}.get(
            e.get("parity"), " Environment assumed from public reports, not yet measured on Killercoda.")
        out += f"> **Tested:** {e['image']}, Ubuntu {e['os']}{k8s} on {ev['date']}{link}: break, verify fails, fix, verify passes, cleanup.{note}\n"
    if human:
        out += f"> **Tested on Killercoda** by @{human['by']} on {human['date']}: a person ran this scenario there and it behaved.\n"
    return out


def decorate(lab: spec.Lab, files: dict[str, str], ev: dict | None) -> dict[str, str]:
    """The published scenario: the exported one with the certification header, the banner and metadata.json."""
    syl = syllabus(lab.spec["cert"], lab.spec["topic"], lab.spec["title"])
    prov = provenance(lab)
    lic = lab.spec.get("license")
    head = (f"**{syl['label']} · Domain {syl['domain']['id']}: {syl['domain']['title']} · Objective {syl['objective']['id']}: "
            f"{syl['objective']['title']}**\n\n[Topic on study.cybercirujas.club]({kc.SITE}) · "
            f"[Official curriculum]({syl['curriculum']['url']})\n\n")
    human = human_record(f"{lab.spec['cert']}/{lab.spec['topic']}")
    meta = {"cert": syl["cert"], "exam_version": syl["exam_version"], "domain": syl["domain"], "objective": syl["objective"],
            "objective_sha256": syl["objective_sha256"], "curriculum": syl["curriculum"],
            "source": {"path": f"certs/{lab.spec['cert']}/{lab.spec['topic']}/lab", "commit": source_commit(lab)},
            "lab_hash": lab_hash(lab), "license": lic, "provenance": prov,
            "tested_on_killercoda": human,
            "tested": ({"ci_run": ev["runner"].get("url"), "date": ev["date"], "result": ev["result"], "parity": ev["env"]["parity"]}
                       if ev else None)}
    out = dict(files)
    idx = json.loads(files["index.json"])
    idx["title"] = f"{syl['domain']['id']} | {syl['domain']['title']} - {syl['objective']['id']} {syl['objective']['title']}"
    idx["description"] = f"{syl['label']} - {syl['domain']['id']} {syl['domain']['title']} - {syl['objective']['id']}"
    out["index.json"] = json.dumps(idx, indent=2, ensure_ascii=False) + "\n"
    intro = files["intro.md"]
    title, _, rest = intro.partition("\n\n")
    foot = f"\nLicense: {lic}. Source commit: {meta['source']['commit']}.\n" if lic and meta["source"]["commit"] else ""
    out["intro.md"] = f"{title}\n\n{head}{banner(prov, ev, human)}\n{rest}{foot}"
    out["metadata.json"] = json.dumps(meta, indent=2, ensure_ascii=False) + "\n"
    return out
