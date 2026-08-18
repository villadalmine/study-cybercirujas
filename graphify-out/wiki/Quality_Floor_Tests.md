# Quality Floor Tests

> 19 nodes · cohesion 0.11

## Key Concepts

- **QualityFloorTest** (8 connections) — `tests/test_quality.py`
- **test_quality.py** (5 connections) — `tests/test_quality.py`
- **QualityThresholdsTest** (5 connections) — `tests/test_quality.py`
- **.test_content_without_references_is_rejected()** (2 connections) — `tests/test_quality.py`
- **.test_exercises_without_details_are_rejected()** (2 connections) — `tests/test_quality.py`
- **.test_references_heading_in_other_languages()** (2 connections) — `tests/test_quality.py`
- **.test_without_a_quality_block_everything_passes()** (2 connections) — `tests/test_quality.py`
- **.test_complete_material_passes()** (1 connections) — `tests/test_quality.py`
- **.test_missing_leading_heading()** (1 connections) — `tests/test_quality.py`
- **.test_short_material_is_rejected()** (1 connections) — `tests/test_quality.py`
- **.test_unknown_kind_invents_no_rules()** (1 connections) — `tests/test_quality.py`
- **.test_floor_sits_below_the_observed_minimum()** (1 connections) — `tests/test_quality.py`
- **.test_thresholds_are_declared()** (1 connections) — `tests/test_quality.py`
- **Quality floor: the same standard for every backend. Tested because a floor is…** (1 connections) — `tests/test_quality.py`
- **The references section is explicitly requested by the prompt, and it is what…** (1 connections) — `tests/test_quality.py`
- **The real case: CNPE produced 18 of 18 exercises with no collapsible answers…** (1 connections) — `tests/test_quality.py`
- **Material is generated in seven languages; the heading changes and the floor…** (1 connections) — `tests/test_quality.py`
- **The thresholds live in pipeline.yaml and are calibrated against material…** (1 connections) — `tests/test_quality.py`
- **The floor is optional: a repo with no `quality` in the YAML must not break.…** (1 connections) — `tests/test_quality.py`

## Relationships

- [Pipeline Config & Quality](Pipeline_Config_&_Quality.md) (1 shared connections)
- [Translation Study & Quality](Translation_Study_&_Quality.md) (1 shared connections)

## Source Files

- `tests/test_quality.py`

## Audit Trail

- EXTRACTED: 20 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*