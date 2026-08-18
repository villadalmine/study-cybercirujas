# Content Corruption Audit

> 24 nodes · cohesion 0.13

## Key Concepts

- **fix_corrupted_content.py** (20 connections) — `scripts/fix_corrupted_content.py`
- **main()** (16 connections) — `scripts/fix_corrupted_content.py`
- **check_file()** (11 connections) — `teach/core/quality.py`
- **video_languages()** (9 connections) — `teach/core/pipeline.py`
- **_finish()** (6 connections) — `scripts/fix_corrupted_content.py`
- **render_ready_videos()** (6 connections) — `scripts/fix_corrupted_content.py`
- **_cert_topic_ids()** (4 connections) — `scripts/fix_corrupted_content.py`
- **find_bad_combos()** (4 connections) — `scripts/fix_corrupted_content.py`
- **find_missing_videos()** (4 connections) — `scripts/fix_corrupted_content.py`
- **_refresh_status()** (4 connections) — `scripts/fix_corrupted_content.py`
- **_usable_translate_backend()** (4 connections) — `scripts/fix_corrupted_content.py`
- **_publish_if_complete()** (3 connections) — `scripts/fix_corrupted_content.py`
- **_record_quota_block()** (3 connections) — `scripts/fix_corrupted_content.py`
- **strip_fences_in_place()** (3 connections) — `scripts/fix_corrupted_content.py`
- **A veces el backend envuelve la respuesta entera en ```markdown ... ``` (visto…** (1 connections) — `scripts/fix_corrupted_content.py`
- **[(cert, lang), ...] declared in pipeline.yaml but not rendered. Kept OUT of…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Produce videos for certifications whose content is finished. The unattended…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Ids de todos los topics del temario (frontmatter del .md), para poder detectar…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Write a generation-time limit into the quota history. Only `quota.py` wrote…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Everything that turns finished content into a published certification. One…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Ship a certification the moment it is finished, without being asked. Finishing…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Regenerate STATUS.md here, in the thing that does the work. It used to live…** (1 connections) — `scripts/fix_corrupted_content.py`
- **TRANSLATE_BACKEND if it can actually answer, else claude. A misconfigured…** (1 connections) — `scripts/fix_corrupted_content.py`
- **Same as `check`, resolving the kind from the filename. A file that cannot be…** (1 connections) — `teach/core/quality.py`

## Relationships

- [Status Matrix Generation](Status_Matrix_Generation.md) (8 shared connections)
- [Provenance & Usage Reports](Provenance_&_Usage_Reports.md) (6 shared connections)
- [Pipeline Config & Quality](Pipeline_Config_&_Quality.md) (5 shared connections)
- [Topic Content Generation](Topic_Content_Generation.md) (3 shared connections)
- [Batch Generation Runner](Batch_Generation_Runner.md) (3 shared connections)
- [Translation Study & Quality](Translation_Study_&_Quality.md) (3 shared connections)
- [Run Until Complete](Run_Until_Complete.md) (2 shared connections)
- [Publish Complete Certs](Publish_Complete_Certs.md) (2 shared connections)
- [Certification Run Script](Certification_Run_Script.md) (1 shared connections)

## Source Files

- `scripts/fix_corrupted_content.py`
- `teach/core/pipeline.py`
- `teach/core/quality.py`

## Audit Trail

- EXTRACTED: 70 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*