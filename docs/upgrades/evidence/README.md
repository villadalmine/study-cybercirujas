# Kubernetes 1.37 lab evidence (CKA and CKAD upgrade, #51)

The logs of the labs proved on 2026-10-21 on Kubernetes 1.37. Their 12 per-target records (6 labs x 2 targets, `kind` and
`k3s-incus`, each with the lab hash and the sha256 of its log) live in deploy/lab-evidence.yaml, the one evidence file (#206);
they moved there as they were (#217), and `scripts/quality_score.py` checks each log's sha256 against the file below.
A missing target means "not tested there", not "broken".

| File | What it is |
| :--- | :--- |
| `logs/<target>-<cert>-<topic>.log` | the whole run: break, check before the fix (FAIL), the reference fix, check after it (PASS), down or cleanup, with the server version |
| `logs/SHA256SUMS` | `cd logs && sha256sum -c SHA256SUMS` |

Why not in `lab.yaml`: the `verified:` block records the proof of the v1.35 run on its date; a version bump must not rewrite it
(the upgrade script, scripts/upgrade_versions.py in PR #201, skips it). It is also only a claim: the `lab` quality check credits
an entry in deploy/lab-evidence.yaml for the lab's current hash, never `verified:` alone (#217).
