# Syllabus Coverage Tests

> 18 nodes · cohesion 0.17

## Key Concepts

- **SyllabusCoverageTests** (14 connections) — `tests/test_tracker.py`
- **_reject_unreadable_syllabus()** (12 connections) — `teach/core/tracker.py`
- **objective_ids()** (8 connections) — `teach/core/tracker.py`
- **.test_normalising_does_not_disguise_weights_taken_from_the_count()** (3 connections) — `tests/test_tracker.py`
- **.test_accepts_a_full_extraction()** (2 connections) — `tests/test_tracker.py`
- **.test_accepts_an_even_split_when_the_vendor_publishes_no_weights()** (2 connections) — `tests/test_tracker.py`
- **.test_accepts_equal_weights_the_document_actually_publishes()** (2 connections) — `tests/test_tracker.py`
- **.test_counts_objectives_and_ignores_page_furniture()** (2 connections) — `tests/test_tracker.py`
- **.test_declaring_no_weights_does_not_excuse_missing_objectives()** (2 connections) — `tests/test_tracker.py`
- **.test_does_not_count_an_objective_the_exam_withdrew()** (2 connections) — `tests/test_tracker.py`
- **.test_normalises_a_published_scale_to_exactly_one_hundred()** (2 connections) — `tests/test_tracker.py`
- **.test_rejects_chapter_headings_extracted_from_a_numbered_document()** (2 connections) — `tests/test_tracker.py`
- **.test_rejects_weights_computed_from_the_topic_count()** (2 connections) — `tests/test_tracker.py`
- **.test_unnumbered_document_yields_nothing_rather_than_a_pass()** (2 connections) — `tests/test_tracker.py`
- **.test_strips_backend_diagnostics_that_are_not_the_answer()** (1 connections) — `tests/test_tracker.py`
- **Numbered objectives present in a syllabus document. Empty when the document…** (1 connections) — `teach/core/tracker.py`
- **Refuse a topic list that the source document does not support. Both checks…** (1 connections) — `teach/core/tracker.py`
- **A snapshot must be refused when the document does not support it. Seven…** (1 connections) — `tests/test_tracker.py`

## Relationships

- [Community 74](Community_74.md) (6 shared connections)
- [Community 55](Community_55.md) (2 shared connections)
- [Community 43](Community_43.md) (1 shared connections)

## Source Files

- `teach/core/tracker.py`
- `tests/test_tracker.py`

## Audit Trail

- EXTRACTED: 35 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*