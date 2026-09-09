# AI certification roadmap

Owner's brief (2026-09-06): build an **AI roadmap** on top of the existing
catalogue — official vendor certifications only, ones with real market
demand, whose syllabus is clear enough to teach and trackable by the same
machinery as everything else.

## The five filters

A certification enters the catalogue only if it passes all five. They are
not preferences: each one maps to something the pipeline needs to exist.

1. **Official** — issued by the vendor, not a third-party course.
2. **Public objectives document** that our extractor can read. Verified by
   probing the URL *before* cataloguing (an overview page is not a syllabus
   — the mistake that cost seven LPI re-snapshots).
3. **Open enrolment** — anyone can sit it. A partner-gated exam cannot be
   studied for by our audience.
4. **Market demand** — it appears in job postings or is the recognised entry
   point of a vendor path.
5. **Trackable** — upstream publishes something (version or date) that
   `tracker sync` can compare against our frozen snapshot, so
   `make check-updates` keeps telling the truth about it.

## Phase 1 — AI fundamentals (extends the three cloud careers)

URLs probed live 2026-09-06, all HTTP 200.

| Cert | Exam | Price | Objectives document |
|---|---|---|---|
| AWS Certified AI Practitioner | AIF-C01 | $100 | `d1.awsstatic.com/.../AWS-Certified-AI-Practitioner_Exam-Guide.pdf` |
| Microsoft Azure AI Fundamentals | AI-901 | $99 | `learn.microsoft.com/.../study-guides/ai-901` |
| Google Generative AI Leader | — | ~$99 | `services.google.com/.../generative_ai_leader_exam_guide_english.pdf` |

Why first: fundamentals-tier topics are light (the measured sweet spot for
completion context), each one becomes the second rung of a career path that
already exists on the site, and `sync_clouds()` already knows how to track
these vendors. Estimated ~50 topics total, about a week of unattended timer.

**Note on AI-901 vs AI-900**: both study-guide URLs answer 200 today —
Microsoft's 2026 redesign is mid-transition and old codes still resolve. The
snapshot freezes whatever the AI-901 document states about itself, and
`check-updates` surfaces the drift if Microsoft retires one.

## Phase 2 — the technical tier, led by market demand

| Cert | Exam | Price | Objectives document | Note |
|---|---|---|---|---|
| Google Professional ML Engineer | PMLE | $200 | `services.google.com/.../professional_machine_learning_engineer_exam_guide_english.pdf` | **The most requested AI cert in job postings** of everything surveyed — the anchor of this roadmap |
| AWS ML Engineer Associate | MLA-C01 | $150 | `d1.awsstatic.com/.../AWS-Certified-Machine-Learning-Engineer-Associate_Exam-Guide.pdf` | AWS technical pair |
| Azure AI Apps and Agents Developer | AI-103 | $165 | `learn.microsoft.com/.../study-guides/ai-103` | The 2026 redesign's agent-oriented track |

Professional-tier topics run deep (LPIC-3 class). Watch per-completion size:
if single files pass ~150k tokens consistently, split generation into
sections — see the context finding in AGENTS_SYNC.

## NVIDIA career track (researched 2026-09-09, owner's request)

NVIDIA has the **best-shaped catalogue after the three public clouds** —
nine certifications, two coherent branches, an associate rung feeding each —
but **filter 2 is unresolved**: no machine-readable objectives document has
been found yet.

**Correction, same session:** the outline URLs indexed by search engines
(`academy.nvidia.com/.../<Exam-Name>-Outline-2026.pdf`) all **301-redirect
to the training landing page** and serve HTML. They read as HTTP 200 only
because the probe followed redirects — the mistake this file exists to
prevent, made and caught inside one session. `fetch_text` confirmed it:
`invalid pdf header: b'\n<!DO'`. The academy site was reorganised and the
PDFs moved or went behind the login.

Before cataloguing anything NVIDIA, someone has to find where the outlines
live now — check the individual exam pages under
`nvidia.com/en-us/learn/certification/<exam>/`, or whether Certiverse (the
exam delivery platform) publishes the domain breakdown. **Probe without
`-L` and confirm the body is a real PDF**, not just a 200.

| Cert | Code | Level | Price | Branch |
|---|---|---|---|---|
| AI Infrastructure and Operations | NCA-AIIO | Associate | $125 | infra (entry) |
| AI Infrastructure | NCP-AII | Professional | $400 | infra |
| AI Operations | NCP-AIO | Professional | $500 | infra |
| AI Networking | NCP-AIN | Professional | $400 | infra |
| AI Rack and Interconnect | NCP-ARI | Professional | $400 | infra |
| Generative AI LLM | NCA-GENL | Associate | $125 | genai (entry) |
| Generative AI Multimodal | NCA-GENM | Associate | $125 | genai |
| Generative AI LLMs | NCP-GENL | Professional | $200 | genai |
| Agentic AI | NCP-AAI | Professional | $200 | genai |

Proposed path shape — two entry points, then specialise:

    NCA-AIIO ──> NCP-AII ──> NCP-AIO / NCP-AIN / NCP-ARI     (infrastructure)
    NCA-GENL ──> NCP-GENL ──> NCP-AAI                        (generative/agentic)
                 NCA-GENM

Why it fits this catalogue: the infra branch is the natural continuation of
the Kubernetes corpus (GPU scheduling, cluster networking, workload ops),
and the agentic branch matches where the market is moving. Suggested start:
**NCA-AIIO** alone — one associate cert, cheapest to produce, proves the
outline-PDF extraction works before committing to eight more.

Caveat to check at snapshot time: these outlines are slide-style PDFs and
may carry the CAPA disease (unextractable fonts). `scripts/ocr_pdf.py` is
the fallback, and it needs a human to read the result before freezing.

## Phase 3 — specialists (need a verification pass before cataloguing)

- **Databricks GenAI Engineer Associate** ($200) — official and open, but the
  exam-guide URL tried on 2026-09-06 returned **404**. Locate the current PDF
  before cataloguing.
- **NVIDIA NCP-AII** ($400, AI infrastructure) — vendor page resolves;
  natural pairing with the Kubernetes catalogue. Confirm the objectives are
  published outside a login.
- **CompTIA SecAI+** (launched 2026-02-17, AI security, no prerequisites) —
  strong synergy with CKS. Page returned **404** on the URL tried; CompTIA
  usually gates objectives behind a form, which would fail filter 2.

## Watchlist — official, but they fail a filter today

Re-check with `make check-updates` reasoning, not by memory:

### Model-provider certifications — researched in depth 2026-09-09

Owner asked for a proper analysis of both. They are the first credentials
issued by *model providers* rather than cloud/infra vendors, which is why
they matter beyond their size: they define what the market will call
"certified" for LLM work. Verdict: **real, growing, and not catalogable
yet** — but for different reasons, and only one of them is close.

**Anthropic — Claude Certified.** Four role-based exams live since
2026-07-23, delivered by Pearson VUE (online-proctored or test centre),
120 minutes, multiple-choice/multiple-response, pass at 720 on a 100–1000
scale, **12-month validity**:

| Exam | Domains | Note |
|---|---|---|
| Associate (Foundations) | 7 | $99, least technical — consultants, sellers, delivery leads |
| Developer (Foundations) | 8 | — |
| Architect (Foundations) | 5 | Agentic Architecture 27% · Claude Code Workflows 20% · Prompt Engineering 20% · Tool Design & MCP 18% · Context Management 15% |
| Architect (Professional) | 7 | — |

What blocks it, checked directly: `anthropic.com/certifications` → **404**;
the public Anthropic Academy (anthropic.skilljar.com) lists courses and
**no certification section at all**; registration runs through the Partner
Academy, open to partner *organisations* (free to join for firms taking
Claude to market, but not a route for an individual student). Every domain
breakdown circulating — including the Architect weights above — comes from
community write-ups that state they are **not affiliated with Anthropic**.
So filter 2 fails on provenance, not on difficulty: building material from
third-party guesses at an official syllabus is exactly what this project
refuses to do.

**OpenAI — AI Foundations.** Different shape entirely: launched 2025-12,
assessed through **scenario-based tasks performed inside ChatGPT**, backed
by ETS psychometrics with Credly badges. Since 2026-06 three certificate
courses are **open to the public** (no employer, no waitlist, no payment).
The full proctored OpenAI Certification — the ETS/Pearson exam — had still
not launched publicly as of this research. `openai.com/certifications`
returns 403 to us; OpenAI Academy is public but course-shaped.

The deeper mismatch is pedagogical: a competency assessed by doing tasks
inside a product has no domain-and-weight syllabus to freeze, and our whole
pipeline is built on one. Even when it opens, OpenAI may never publish the
document our snapshot needs.

**Actions, concrete:**
1. Re-check quarterly (next: 2026-12) via `/check-updates` reasoning —
   specifically whether `anthropic.com` publishes an exam guide outside the
   Partner Academy, and whether OpenAI's proctored exam ships with an
   objectives document.
2. **Anthropic is the one to watch**: it already has the right shape
   (domains, weights, proctored exam, fixed syllabus). The single blocker
   is publication. If Anthropic ever posts an official exam guide, it goes
   straight to Phase 1 priority — the platform runs on Claude, so the
   material would be unusually well-grounded.
3. Do NOT catalogue either from community-sourced domain lists, however
   detailed they look. A syllabus nobody official published is the same
   defect as a syllabus scraped from the wrong page.
- **AWS AI Business Strategist** — entered beta 2026-09-01. Objectives can
  still move in beta; snapshot at GA, not before.
- **Azure AB-100 / AB-730** (agentic business architect tiers) — confirm
  whether study guides are published.
- **ISACA AAISM / AAIA** — require an active CISM/CISA, which shrinks the
  audience below filter 4.
- **AWS ML Specialty** — retires 2026-03-31. Do not catalogue a dying exam.
- **Meta / Llama** — no official certification exists; everything found is
  third-party. Permanently out.

## How each course cites its own syllabus

Every topic records the exact objectives document it was generated from in
its `meta.yaml`, and since 2026-09-06 the site shows it: the provenance line
on each topic page links the vendor document next to the model and date.
That closes the loop the EU AI Act cares about — a reader can go from the
AI-generated page to the official source it derives from in one click.
