# Community 101

> 26 nodes · cohesion 0.10

## Key Concepts

- **PlanTests** (12 connections) — `tests/test_milestone_sync.py`
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
- **.test_earliest_due_open_release_milestone_undated_last()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_git_and_description_parsing()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_issue_link_forms()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_minor_release_with_its_planned_milestone()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_missing_milestone_is_created_and_shipped_work_moves_into_it()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_new_milestone_never_moves_open_items_even_if_passed()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_only_completed_issues_without_milestone()** (1 connections) — `tests/test_milestone_sync.py`
- **.test_release_moves_open_items_to_the_next_and_closes()** (1 connections) — `tests/test_milestone_sync.py`
- *... and 1 more nodes in this community*

## Relationships

- [Community 43](Community_43.md) (3 shared connections)
- [Community 14](Community_14.md) (1 shared connections)

## Source Files

- `tests/test_milestone_sync.py`

## Audit Trail

- EXTRACTED: 32 (86%)
- INFERRED: 5 (14%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*