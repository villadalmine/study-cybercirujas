# CKAD 1.35 — Domain 2.3: Use the Helm Package Manager to Deploy Existing Packages

## Why Helm

Kubernetes manifests for anything beyond a toy app quickly multiply: a `Deployment`, a `Service`, a `ConfigMap`, a `Secret`, maybe an `Ingress` and a `HorizontalPodAutoscaler`, each needing slightly different values per environment (dev/staging/prod). Managing that by hand with `kubectl apply -f` across many files and manually templating YAML with `sed`/`envsubst` does not scale.

**Helm** is the de facto package manager for Kubernetes. It packages a set of Kubernetes manifests, parameterized with a templating engine, into a single distributable unit called a **chart**. A chart can be installed, upgraded, rolled back, and uninstalled as one atomic unit, called a **release**.

For CKAD, the exam does **not** test writing charts from scratch (that is closer to a CKA/advanced-operations skill). It tests that you can **consume** existing charts efficiently: find a chart, inspect what it deploys, install it with custom configuration, and manage the resulting release lifecycle from the CLI. `helm` is available on the exam terminal — you are not expected to memorize chart internals, but you must be fast with the CLI.

## Core concepts

| Term | Meaning |
|---|---|
| **Chart** | A packaged collection of templated Kubernetes YAML files plus metadata (`Chart.yaml`), default configuration (`values.yaml`), and optional dependencies. Distributed as a directory or a `.tgz` archive. |
| **Release** | A specific instance of a chart deployed into a cluster with a specific configuration. Installing the same chart twice (with different release names) creates two independent releases. |
| **Repository (repo)** | An HTTP server exposing an `index.yaml` that lists available charts and their versions (e.g., Bitnami, the ingress-nginx repo). |
| **Values** | The configuration passed to a chart's templates at render time. Comes from the chart's own `values.yaml` defaults, overridden by `-f custom.yaml` files and/or `--set key=value` flags, in increasing order of precedence. |

Helm 3 (current, no Tiller) talks directly to the Kubernetes API using your kubeconfig context/RBAC — there is no separate in-cluster server component to manage, which matters for the exam because there's nothing extra to install beyond the `helm` CLI itself.

## Working with repositories

```bash
# add a repo (name + URL)
helm repo add bitnami https://charts.bitnami.com/bitnami

# refresh local cache of all added repos
helm repo update

# list configured repos
helm repo list

# search a specific repo (or all if configured that way)
helm search repo nginx
```

Sample output of `helm search repo nginx`:

```
NAME                        CHART VERSION   APP VERSION   DESCRIPTION
bitnami/nginx               15.4.4          1.25.3        NGINX Open Source is a web server...
bitnami/nginx-ingress-...   9.3.28          1.9.4         NGINX Ingress Controller...
```

You can also search the public **Artifact Hub** across all published repos without adding anything:

```bash
helm search hub wordpress
```

## Inspecting a chart before installing

Never install blind. Useful inspection commands:

```bash
# show all default configurable values
helm show values bitnami/nginx

# show chart metadata (name, version, dependencies)
helm show chart bitnami/nginx

# show README
helm show readme bitnami/nginx

# render the manifests locally WITHOUT installing (dry render)
helm template my-nginx bitnami/nginx

# server-side dry-run, validates against the live cluster
helm install my-nginx bitnami/nginx --dry-run --debug
```

`helm template` is especially handy on the exam when you just want to see what a chart would create, or pipe it into `kubectl apply -f -` for a one-off tweak.

## Installing a chart (creating a release)

```bash
helm install <release-name> <chart-reference> [flags]
```

Examples:

```bash
# install with all default values
helm install my-release bitnami/nginx

# install from a local chart directory or .tgz
helm install my-release ./mychart
helm install my-release ./mychart-1.2.3.tgz

# install into a specific namespace, creating it if needed
helm install my-release bitnami/nginx -n web --create-namespace

# pin a specific chart version (not app version)
helm install my-release bitnami/nginx --version 15.4.0
```

Output:

```
NAME: my-release
LAST DEPLOYED: Thu Jul 17 10:04:12 2026
NAMESPACE: web
STATUS: deployed
REVISION: 1
NOTES:
...chart-provided post-install notes (e.g. how to access the service)...
```

### Customizing values at install time

Two mechanisms, combinable, `--set` wins over `-f` when both touch the same key and multiple `-f`/`--set` are applied left-to-right (later overrides earlier):

```bash
# inline override, dot notation for nested keys
helm install my-release bitnami/nginx \
  --set service.type=NodePort \
  --set replicaCount=3

# override with a values file
helm install my-release bitnami/nginx -f custom-values.yaml

# combine: file first, then inline override on top
helm install my-release bitnami/nginx -f custom-values.yaml --set replicaCount=5
```

`custom-values.yaml` only needs to contain the keys you want to change — it is merged with the chart's defaults, not a full replacement:

```yaml
replicaCount: 3
service:
  type: NodePort
resources:
  requests:
    cpu: 100m
    memory: 128Mi
```

`--set` supports arrays and multiple keys with commas: `--set image.tag=1.25,service.ports[0].port=8080`.

## Listing and inspecting releases

```bash
# releases in current namespace
helm list
helm ls

# across all namespaces
helm list -A

# status of one release (resources, notes)
helm status my-release

# the actual computed values currently in use (defaults + overrides)
helm get values my-release

# all values, including chart defaults not explicitly set
helm get values my-release --all

# the full rendered manifest actually applied
helm get manifest my-release
```

Sample `helm list -A`:

```
NAME         NAMESPACE   REVISION   UPDATED                    STATUS     CHART          APP VERSION
my-release   web         2          2026-07-17 10:20:03 -03    deployed   nginx-15.4.4   1.25.3
```

## Upgrading a release

Changing configuration or bumping the chart version is done in place via `upgrade`, never by uninstalling and reinstalling:

```bash
# upgrade with a new value
helm upgrade my-release bitnami/nginx --set replicaCount=5

# upgrade to a specific chart version
helm upgrade my-release bitnami/nginx --version 15.5.0

# idempotent pattern used often in CI / on the exam:
# installs if the release doesn't exist, upgrades if it does
helm upgrade --install my-release bitnami/nginx -f custom-values.yaml
```

Each `upgrade` increments the release's **revision number**, and Helm keeps a revision history (default keeps all unless `--history-max` was set at install time).

## Rolling back

```bash
# see revision history
helm history my-release
```

```
REVISION   UPDATED                    STATUS       CHART          APP VERSION   DESCRIPTION
1          Thu Jul 17 10:04:12 2026   superseded   nginx-15.4.4   1.25.3        Install complete
2          Thu Jul 17 10:20:03 2026   superseded   nginx-15.5.0   1.25.4        Upgrade complete
3          Thu Jul 17 10:31:47 2026   deployed     nginx-15.5.0   1.25.4        Upgrade complete
```

```bash
# roll back to the immediately previous revision
helm rollback my-release

# roll back to a specific revision
helm rollback my-release 1
```

A rollback is itself recorded as a new revision (it does not delete history), so `helm history` keeps growing forward even when you go "back."

## Uninstalling

```bash
helm uninstall my-release

# uninstall but keep history (allows rollback even after uninstall)
helm uninstall my-release --keep-history

# specify namespace if not in current context
helm uninstall my-release -n web
```

By default, uninstalling deletes all Kubernetes resources the release created (Deployments, Services, ConfigMaps, etc.) and purges the release record.

## Quick troubleshooting flow (exam-relevant)

If a release doesn't behave as expected:

1. `helm status <release>` — is it `deployed`, `failed`, `pending-install`?
2. `helm get values <release> --all` — confirm what config actually took effect (typos in `--set` silently create unused keys instead of erroring on a wrong path).
3. `helm get manifest <release>` — see the real rendered YAML, then cross-check with `kubectl get`/`kubectl describe` on the actual objects.
4. `kubectl get events -n <ns>` / `kubectl logs` — standard pod-level debugging still applies; Helm only manages the manifests, not runtime behavior.

## Command summary

| Task | Command |
|---|---|
| Add/update repo | `helm repo add`, `helm repo update` |
| Search charts | `helm search repo`, `helm search hub` |
| Inspect before install | `helm show values/chart/readme`, `helm template` |
| Install | `helm install <release> <chart> [-f file] [--set k=v] [-n ns --create-namespace]` |
| List releases | `helm list [-A]` |
| Release detail | `helm status`, `helm get values/manifest/notes` |
| Upgrade | `helm upgrade <release> <chart> [flags]`, or `helm upgrade --install` |
| History | `helm history <release>` |
| Rollback | `helm rollback <release> [revision]` |
| Uninstall | `helm uninstall <release> [--keep-history]` |

## Referencias

- Helm Docs — Quickstart Guide: https://helm.sh/docs/intro/quickstart/
- Helm Docs — Using Helm (install/upgrade/rollback/uninstall): https://helm.sh/docs/intro/using_helm/
- Helm Docs — Helm CLI command reference: https://helm.sh/docs/helm/helm/
- Helm Docs — Charts (structure and values): https://helm.sh/docs/topics/charts/
- Artifact Hub (search public charts): https://artifacthub.io/
- CNCF CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf