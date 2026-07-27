# 2.4 Understand API deprecations

## What is an API deprecation?

In Kubernetes, every resource (`Deployment`, `CronJob`, `Ingress`, etc.) is exposed through a combination of **API group**, **version**, and **kind**, which appears in a manifest as the `apiVersion` field:

```yaml
apiVersion: apps/v1
kind: Deployment
```

An **API deprecation** occurs when the Kubernetes project announces that a specific version of a resource (for example `batch/v1beta1` for `CronJob`) will no longer be available in the future, replaced by a more stable version (for example `batch/v1`). Deprecating is not the same as removing: deprecation is the warning; removal is when that version actually stops responding in the `kube-apiserver`.

For anyone managing or deploying workloads, understanding this process is critical because **a manifest using a removed `apiVersion` fails directly upon application** (`error: resource mapping not found`), typically after a cluster upgrade.

## API Stability Levels

Each API version has a maturity level, visible in its name:

| Level | Version Example | Guarantees |
|---|---|---|
| **Alpha** | `v1alpha1` | May contain bugs, disabled by default, **may change or be removed at any time without prior notice**. Do not use in production. |
| **Beta** | `v1beta1` | Well-tested code, enabled by default, supported for at least 9 months or 3 releases (whichever is longer) from deprecation announcement. Schema may undergo minor incompatible changes between beta releases. |
| **Stable / GA** | `v1` | Appears in major release notes, guaranteed support for at least 12 months or 3 releases (whichever is longer) after deprecation announcement. |

Kubernetes releases minor versions approximately every 4 months, so "3 releases" roughly equals one year, matching the figures above.

## The Deprecation Policy (Concrete Rules)

Official project rules (documented in the *Kubernetes Deprecation Policy*) are:

1. **APIs with a given maturity level are not removed directly**: they must first undergo a deprecation period.
2. **GA/stable**: minimum support of **12 months or 3 releases** after announcement, whichever is longer.
3. **Beta**: minimum support of **9 months or 3 releases**.
4. **Alpha**: no support guarantee, may disappear in any release.
5. When an API is replaced by a newer version, **a documented migration path must exist** (a new `apiVersion` with an equivalent or convertible schema).
6. Deprecation is communicated in **release notes** and via **runtime warnings** (see next section).

This enables upgrade planning: before jumping cluster versions, always audit which beta/GA APIs you use that will be out of support in the target version.

## How Kubernetes Warns You: Deprecation Warnings

Since Kubernetes 1.19, `kube-apiserver` sends an **HTTP warning header** when a deprecated `apiVersion` is used, and `kubectl` displays it in the terminal. Real example applying a `CronJob` with an old version:

```console
$ kubectl apply -f cronjob-old.yaml
Warning: batch/v1beta1 CronJob is deprecated in v1.21+, unavailable in v1.25+; use batch/v1 CronJob
cronjob.batch/backup-job created
```

The object is created anyway (while the version still exists), but the warning signals that the manifest needs migration. This also applies to `kubectl create`, `kubectl replace`, and any client communicating with the API (Helm, controllers, etc.).

## Historical Deprecations / Removals Table

These are classic examples illustrating the "beta → GA" pattern (for the exact Kubernetes version used in the exam, always verify against the official *deprecation guide*, as version details change over time):

| Resource | Deprecated Version | Replacement Version | Removed In |
|---|---|---|---|
| `Deployment`, `DaemonSet`, `ReplicaSet` | `extensions/v1beta1`, `apps/v1beta1`, `apps/v1beta2` | `apps/v1` | v1.16 |
| `NetworkPolicy` | `extensions/v1beta1` | `networking.k8s.io/v1` | v1.16 |
| `Ingress` | `extensions/v1beta1`, `networking.k8s.io/v1beta1` | `networking.k8s.io/v1` | v1.22 |
| `CronJob` | `batch/v1beta1` | `batch/v1` | v1.25 |
| `PodDisruptionBudget` | `policy/v1beta1` | `policy/v1` | v1.25 |
| `PodSecurityPolicy` | `policy/v1beta1` | *(no direct replacement; migrate to Pod Security Admission)* | v1.25 |
| `HorizontalPodAutoscaler` | `autoscaling/v2beta2` | `autoscaling/v2` | v1.26 |

The pattern to memorize is not the table itself, but the mechanism: **beta → GA**, with a co-existence period where both versions respond and `kubectl` warns.

## How to Detect Deprecated API Usage in a Cluster

**1. Inspect which API groups/versions current `kube-apiserver` exposes:**

```console
$ kubectl api-versions | grep batch
batch/v1
```

If `batch/v1beta1` does not appear in output, it means it has already been removed in that cluster.

**2. See all available resources and their preferred version:**

```console
$ kubectl api-resources -o wide | grep -i cronjob
cronjobs   cj   batch/v1   true   CronJob   ...
```

**3. Check schema of a specific version with `kubectl explain`:**

```console
$ kubectl explain cronjob --api-version=batch/v1
```

**4. Dedicated tools to audit manifests/clusters before an upgrade** (mentioned in CNCF ecosystem, useful for checking Helm releases, Git manifests, or live cluster state):

```console
$ pluto detect-all-in-cluster
NAME              KIND      VERSION          REPLACEMENT   REMOVED   DEPRECATED
backup-job        CronJob   batch/v1beta1    batch/v1      true      true
```

```console
$ kubent
>>> Deprecated APIs removed in 1.25 <<<
------------------------------------------------------------------------------------
KIND       NAMESPACE   NAME       API_VERSION
CronJob    default     backup-job batch/v1beta1
```

These tools are not part of `kubectl` (not installed by default), but useful to know in the context of "how this is managed in practice".

## Migrating a Manifest to New `apiVersion`

Most often the change is just updating the `apiVersion` field (fields in `spec` rarely change between beta and GA):

```yaml
# Before
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: busybox
          restartPolicy: OnFailure
```

```yaml
# After
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: busybox
          restartPolicy: OnFailure
```

If you attempt to apply the old version on a cluster where it was removed, the error is explicit:

```console
$ kubectl apply -f cronjob-old.yaml
error: resource mapping not found for name: "backup-job" namespace: "" from "cronjob-old.yaml": no matches for kind "CronJob" in version "batch/v1beta1"
ensure CRDs are installed first
```

## Key Exam Day Commands

```bash
kubectl api-versions                       # list all group/version available in cluster
kubectl api-resources                      # list resources, their kind, and preferred version
kubectl explain <resource> --api-version=<v> # view schema for a specific version
kubectl apply -f file.yaml                  # apply and check if deprecation Warning appears
kubectl get <resource>.<version>.<group>    # force query against a specific API version
```

In the exam, if a provided manifest uses a deprecated or missing `apiVersion` in the cluster version, the task is usually to fix that field relying on `kubectl api-resources`/`kubectl explain` to find the correct version.

## References

- Kubernetes Deprecation Policy: https://kubernetes.io/docs/reference/using-api/deprecation-policy/
- Deprecated API Migration Guide: https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- API versioning conceptual overview: https://kubernetes.io/docs/reference/using-api/#api-versioning
- CKAD Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Pluto (deprecated API detection): https://pluto.docs.fairwinds.com/
- kube-no-trouble (kubent): https://github.com/doitintl/kube-no-trouble
