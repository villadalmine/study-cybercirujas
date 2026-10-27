# Community 101

> 16 nodes · cohesion 0.18

## Key Concepts

- **.run_main()** (10 connections) — `tests/test_milestone_sync.py`
- **MainTests** (9 connections) — `tests/test_milestone_sync.py`
- **pr()** (5 connections) — `tests/test_milestone_sync.py`
- **.test_a_milestone_set_since_the_event_is_kept()** (3 connections) — `tests/test_milestone_sync.py`
- **.test_pr_merged_patches_the_milestone_and_writes_the_warning()** (3 connections) — `tests/test_milestone_sync.py`
- **paged()** (2 connections) — `tests/test_milestone_sync.py`
- **.run_main_status()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_a_bad_tag_input_is_refused()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_patch_release_creates_the_milestone_and_collects_what_shipped()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_release_moves_comments_then_closes()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_workflow_dispatch_input_and_rerun_is_a_noop()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_left_alone_existing_milestone_release_pr_unmerged_or_other_base()** (2 connections) — `tests/test_milestone_sync.py`
- **.test_sets_the_current_release_and_warns_only_without_an_issue_link()** (2 connections) — `tests/test_milestone_sync.py`
- **call()** (1 connections) — `tests/test_milestone_sync.py`
- **git()** (1 connections) — `tests/test_milestone_sync.py`
- **issue()** (1 connections) — `tests/test_milestone_sync.py`

## Relationships

- [Community 43](Community_43.md) (2 shared connections)
- [Community 265](Community_265.md) (2 shared connections)
- [Community 14](Community_14.md) (1 shared connections)

## Source Files

- `tests/test_milestone_sync.py`

## Audit Trail

- EXTRACTED: 22 (81%)
- INFERRED: 5 (19%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*