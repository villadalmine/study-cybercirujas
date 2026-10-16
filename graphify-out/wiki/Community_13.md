# Community 13

> 24 nodes · cohesion 0.11

## Key Concepts

- **check()** (16 connections) — `teach/core/quality.py`
- **QualityFloorTest** (8 connections) — `tests/test_quality.py`
- **rules()** (6 connections) — `teach/core/quality.py`
- **QualityThresholdsTest** (5 connections) — `tests/test_quality.py`
- **evaluate()** (5 connections) — `scripts/translation_study.py`
- **.test_without_a_quality_block_everything_passes()** (4 connections) — `tests/test_quality.py`
- **.test_content_without_references_is_rejected()** (3 connections) — `tests/test_quality.py`
- **.test_exercises_without_details_are_rejected()** (3 connections) — `tests/test_quality.py`
- **.test_references_heading_in_other_languages()** (3 connections) — `tests/test_quality.py`
- **_reusable()** (2 connections) — `teach/core/generator.py`
- **.test_complete_material_passes()** (2 connections) — `tests/test_quality.py`
- **.test_missing_leading_heading()** (2 connections) — `tests/test_quality.py`
- **.test_short_material_is_rejected()** (2 connections) — `tests/test_quality.py`
- **.test_unknown_kind_invents_no_rules()** (2 connections) — `tests/test_quality.py`
- **.test_floor_sits_below_the_observed_minimum()** (2 connections) — `tests/test_quality.py`
- **.test_thresholds_are_declared()** (2 connections) — `tests/test_quality.py`
- **Run the pipeline's own two gates. Verdict plus the reasons it failed.** (1 connections) — `scripts/translation_study.py`
- **Rules for 'content' or 'exercises'. With no `quality` block in the YAML there…** (1 connections) — `teach/core/quality.py`
- **Return the problems found. An empty list means the floor is met. `kind` is…** (1 connections) — `teach/core/quality.py`
- **The references section is explicitly requested by the prompt, and it is what…** (1 connections) — `tests/test_quality.py`
- **The real case: CNPE produced 18 of 18 exercises with no collapsible answers…** (1 connections) — `tests/test_quality.py`
- **Material is generated in seven languages; the heading changes and the floor…** (1 connections) — `tests/test_quality.py`
- **The thresholds live in pipeline.yaml and are calibrated against material…** (1 connections) — `tests/test_quality.py`
- **The floor is optional: a repo with no `quality` in the YAML must not break.…** (1 connections) — `tests/test_quality.py`

## Relationships

- [Community 43](Community_43.md) (5 shared connections)
- [Community 50](Community_50.md) (2 shared connections)
- [Community 21](Community_21.md) (1 shared connections)
- [Community 36](Community_36.md) (1 shared connections)
- [Community 47](Community_47.md) (1 shared connections)
- [Community 7](Community_7.md) (1 shared connections)
- [Community 31](Community_31.md) (1 shared connections)
- [Community 49](Community_49.md) (1 shared connections)

## Source Files

- `scripts/translation_study.py`
- `teach/core/generator.py`
- `teach/core/quality.py`
- `tests/test_quality.py`

## Audit Trail

- EXTRACTED: 44 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*