# Verifying the material is true — design notes

Status: **design, nothing built**. Written 2026-08-06 after `check_claims.py`
found a real stale citation in fresh content and made the remaining gap obvious.

## The gap, precisely

What is verified today, all free and deterministic:

| Question | Tool |
|---|---|
| Is it a stub? | quality floor, before writing |
| Does the cited URL exist? | `check_citations.py` |
| Does the embedded YAML parse? | `check_manifests.py` |
| Does it teach a removed Kubernetes API? | `check_k8s_apis.py` |
| Does the cited page cover the subject? | `check_claims.py` (costs a completion, sampling) |

What is **not** verified: whether a technical assertion is *true*. "The kubelet
read-only port is 10255 and disabled by default since 1.10" is either right or
wrong, and nothing here can tell. That is the class that matters, because a
confident wrong explanation is indistinguishable from a right one to every check
above.

## The design mistake to avoid

The obvious idea — index all mainstream documentation, RAG over it, ask a model
whether each paragraph is supported — is the expensive version of a cheaper
answer, and it fails in a specific way: **retrieval finds something related, and
the judge says "supported"**. A judge asked "is this consistent with these
chunks?" agrees far too often. Confirmation is the default failure of RAG
verification.

Two corrections shape everything below:

1. **The auditor's job is falsification, not confirmation.** Ask "find me the
   passage that CONTRADICTS this" and "is this claim absent from the docs
   entirely?" — absence of support is the signal, and it is one a confirmation-
   shaped pipeline structurally cannot produce.
2. **Most sentences are not checkable, and should not be checked.** Prose about
   why platforms exist has no truth value to look up. Spending retrieval on it
   buries the 5% that does.

## A funnel, cheapest layer first

### Layer 0 — what exists (free, deterministic)
Already built. Keep it as the first filter.

### Layer 1 — a structured fact base, no RAG at all (free, deterministic)
**This is the highest value per unit of effort and it needs no embeddings, no
model and no cluster.**

The most damaging errors are not prose, they are *facts with a machine-readable
source of truth*:

| Claim type | Ground truth, already machine-readable |
|---|---|
| `apiVersion` exists in version X | Kubernetes OpenAPI spec (`api/openapi-spec/swagger.json`, per release) |
| Field name/type on a resource | same spec |
| Feature gate exists / its default / its stage | `k8s.io/apiserver` feature list, published per release |
| Default ports, flags | component `--help` output and the reference docs, versioned |
| A CNCF project's current version | its GitHub releases API |

Checking those is `grep` against a downloaded spec, not inference. It is exact,
it costs nothing per topic, and it catches the errors a reader would actually be
misled by. It also composes with what exists: `check_k8s_apis.py` is already a
crude version of this — it knows removed APIs but not fields, defaults or gates.

**Versioning is not optional.** Every certification already records
`tracked_version`; the fact base must be fetched per version and the check must
use the version the topic is written against. A claim true in 1.29 and false in
1.34 is the single most likely real error in this corpus, and a version-blind
checker would report it as fine.

### Layer 2 — retrieval over a bounded corpus (cheap, one-off indexing)
Only for claims Layer 1 cannot express — behaviour, sequencing, "why".

**Do not index "all documentation".** The corpus is already self-defining and
bounded: every `certs/<cert>.md` declares `sources`, and every `content.md` has a
references section naming the exact pages the material claims to rest on. Index
*those*, plus what they link one hop deep. That corpus grows with the material,
stays relevant, and is perhaps a few thousand pages rather than the open web.

Practical shape, reusing what is already running:

- **Store**: Postgres + pgvector — already a dependency of the leloir cluster.
- **Embeddings**: `text-embedding-3-small` through the existing LiteLLM proxy.
  One-off cost; re-embedding only what changed.
- **Chunking**: by heading, keeping the source URL and the doc version on each
  chunk, because the verdict is worthless without knowing which version answered.
- **Freshness**: re-crawl on a schedule and *diff*. A changed chunk that backs an
  existing citation is exactly the `STALE` case found in kcsa/1.1 — and detecting
  it by diff is free, where re-judging every citation is not.

### Layer 3 — adversarial judging (costs quota, sample only)
For each extracted claim, retrieve top-k and ask **three separate questions**,
not one:

1. Does any passage state this? (support)
2. Does any passage contradict it? (refutation)
3. Is the subject absent from the corpus entirely? (unverifiable)

Report the three. A claim with no support *and* no contradiction is not "fine",
it is unverified — and conflating those two is how a verification pipeline ends
up reassuring everyone about nothing.

Batch many claims per completion. One call judging twenty claims costs the same
as one judging one.

## What I would build, in order

1. **Layer 1 for Kubernetes only, versioned.** Feature gates, field existence,
   defaults, ports, from the OpenAPI spec and release notes. Free, deterministic,
   catches the highest-value errors, and extends `check_k8s_apis.py` rather than
   starting a new thing. **Start here.**
2. **A claim extractor.** Pull assertions worth checking out of a topic —
   version statements, numbers, API shapes, flags — and store them next to the
   topic. Useful on its own: it makes "what does this material actually assert?"
   answerable, and it is what both remaining layers consume.
3. **The crawl + diff, without any judging.** Snapshot the cited pages, re-crawl
   weekly, report which cited pages *changed*. Catches staleness — the failure
   already observed — for the price of bandwidth.
4. **Retrieval and adversarial judging last**, once there is a claim extractor to
   feed it and a reason to believe Layer 1 has been exhausted.

Steps 1–3 need no model and no cluster. Step 4 is the only one that costs quota,
and by then it runs on a filtered list rather than on everything.

## Honest limits

- A judge model is as fallible as the author model, sometimes in correlated ways.
  Layers 1 and 3 are not equally trustworthy and should not be reported as if
  they were: one is a lookup, the other is an opinion.
- Retrieval failure is indistinguishable from absence without care. If the
  indexer missed a page, the auditor will call true material unverifiable.
- None of this checks pedagogy: material can be entirely true and still a bad
  explanation, badly ordered, or wrong for the level.
