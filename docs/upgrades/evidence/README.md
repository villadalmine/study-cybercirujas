# Kubernetes 1.37 lab evidence (CKA and CKAD upgrade, #51)

Per-target records of the labs that run something, proved on 2026-10-21, in the shape of deploy/lab-evidence.yaml (#206):
`<cert>/<topic>: {<target>: {date, lab_hash, evidence, runner}}`. Targets: `kind` and `k3s-incus` (ids from deploy/lab-targets.yaml).
A missing target means "not tested there", not "broken".

| File | What it is |
| :--- | :--- |
| `cka-ckad-1.37.lab-evidence.yaml` | 12 records: 6 labs x 2 targets, each with the lab hash and the sha256 of its log |
| `logs/<target>-<cert>-<topic>.log` | the whole run: break, check before the fix (FAIL), the reference fix, check after it (PASS), down or cleanup, with the server version |
| `logs/SHA256SUMS` | `cd logs && sha256sum -c SHA256SUMS` |

Why here and not in `lab.yaml`: the `verified:` block records the proof of the v1.35 run on its date; a version bump must not rewrite it
(the upgrade script, scripts/upgrade_versions.py in PR #201, skips it). When #206 is on main these entries move into deploy/lab-evidence.yaml as they are.
