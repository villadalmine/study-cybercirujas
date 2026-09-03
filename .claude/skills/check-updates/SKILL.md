---
name: check-updates
description: Compare every frozen syllabus against what the vendor currently publishes, refresh the Exam versions table in STATUS.md, and report what needs re-snapshotting. Use when the user asks to check for curriculum/syllabus updates, upstream changes, or whether the material is current.
---

# Check curriculum updates

The question this answers: **is our frozen material built on the exam version
the vendor currently publishes?** Two facts, recorded separately on purpose
(see scripts/check_versions.py header): what we froze lives in each
`certs/<cert>.md` frontmatter; what upstream publishes lives in
`catalog.yaml`, refreshed only by `teach tracker sync`.

## Steps

1. Run the deterministic chain (spends a few completions on the sync scrape):

   ```bash
   make check-updates
   ```

2. Read the refreshed **"Exam versions" table in STATUS.md** — that is the
   artifact of record, one row per cert: built-on version, snapshot date,
   upstream version, when upstream changed, last checked, and the verdict
   (✅ current · ⚠️ outdated · – unknown).

3. Report to the user, most severe first:
   - **outdated** certs: name the version gap, and estimate the re-snapshot
     blast radius honestly — a version bump can be a renumbering or a full
     overhaul (lpi-devops v2.0 dropped Ansible and added a Kubernetes
     domain; only title-exact topics survived the remap). Recommend
     re-snapshot + the map-exact/author-rest procedure, never a blind remap.
   - **unknown** rows mean unmeasured, not fine — say which side lacks a
     version and whether `--upstream` checking could settle it.
   - current rows need no words beyond the count.

4. Do NOT re-snapshot anything from this skill — that decision changes
   content scope and is the owner's. Present the table and the
   recommendation; stop.

## Notes

- The sync only touches `catalog.yaml` upstream fields; it can never damage
  frozen syllabi (that separation exists because a sync used to overwrite
  the comparison it was supposed to enable).
- Commit the refreshed `catalog.yaml` + `STATUS.md` after running, so the
  table on GitHub reflects the latest check.
