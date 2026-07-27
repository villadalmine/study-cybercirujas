# Topic 5.4: Kustomize

## What is Kustomize?

**Kustomize** is a native Kubernetes configuration management tool that customizes YAML manifests without using templates or variables. Integrated directly into `kubectl` since version 1.14 (`kubectl apply -k`), it also exists as a standalone CLI tool (`kustomize build`).

The core concept is **declarative and template-free**: rather than parameterizing YAML using placeholders (like Helm), Kustomize starts from clean, unmodified base manifests (`base`) and applies **transformations** (patches, prefixes, labels, etc.) to generate environment-specific variants (`overlays`) for environments like dev, staging, or prod.

Everything revolves around a file named **`kustomization.yaml`**, which declares which resources to include and what transformations to apply.

## Basic `kustomization.yaml` Structure

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  app: my-app

namePrefix: prod-
```

With this minimal configuration:

```bash
$ kubectl kustomize .
```

generates final combined YAML merging `deployment.yaml` + `service.yaml`, appending label `app: my-app` across all resources and prepending `prod-` to their metadata names.

To apply directly to the cluster:

```bash
$ kubectl apply -k .
deployment.apps/prod-my-app created
service/prod-my-app created
```

`-k` tells `kubectl` that the specified directory path contains a `kustomization.yaml` file, rather than a raw manifest file.

## Base + Overlays Pattern

The most common pattern (and the primary one tested on the exam) organizes repositories like this:

```
app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        └── replica-patch.yaml
```

**`base/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**`overlays/prod/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: production
resources:
  - ../../base
patches:
  - path: replica-patch.yaml
```

**`overlays/prod/replica-patch.yaml`**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 5
```

Each overlay references the `base` directory under `resources` (`resources: [../../base]`) and applies its own customizations, preventing duplicated YAML across environment directories.

```bash
$ kubectl apply -k overlays/prod
namespace/production unchanged
deployment.apps/my-app created
service/my-app created
```

## Common Transformers

| Field | Effect |
|---|---|
| `namePrefix` / `nameSuffix` | Prepends/appends prefix or suffix to `metadata.name` across all resources |
| `namespace` | Enforces specific namespace on all generated resources |
| `commonLabels` | Appends labels to `metadata.labels` and matching workload selectors |
| `commonAnnotations` | Appends annotations across all generated resources |
| `images` | Overrides container image names or tags without modifying base YAML |
| `replicas` | Adjusts `spec.replicas` count on Deployments/StatefulSets by name |
| `configMapGenerator` / `secretGenerator` | Generates ConfigMaps/Secrets with content hashes appended to names |

Example using `images` (frequently used to promote container image tags without modifying Deployment files):

```yaml
images:
  - name: nginx
    newName: my-registry/nginx
    newTag: "1.27.0"
```

Example using `replicas`:

```yaml
replicas:
  - name: my-app
    count: 3
```

## Generators: ConfigMap and Secret

Kustomize can **generate** ConfigMaps and Secrets dynamically from literals or files, appending a content **hash** to generated object names. When content updates, the generated name changes, triggering automatic rolling updates on consuming Deployments.

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=debug
      - MAX_CONNECTIONS=100

secretGenerator:
  - name: app-secret
    literals:
      - DB_PASSWORD=s3cr3t
```

```bash
$ kubectl kustomize .
apiVersion: v1
data:
  LOG_LEVEL: debug
  MAX_CONNECTIONS: "100"
kind: ConfigMap
metadata:
  name: app-config-8t2gc4bd2k
---
apiVersion: v1
data:
  DB_PASSWORD: czNjcjN0
kind: Secret
metadata:
  name: app-secret-fh9k274bmg
type: Opaque
```

If a Deployment references `app-config` under `envFrom` or `volumes.configMap.name`, Kustomize updates the reference to match the generated name with hash (`app-config-8t2gc4bd2k`).

## Patches: Strategic Merge vs JSON 6902

Kustomize supports two patching mechanisms:

**1. Strategic Merge Patch** (most common, matches target resource structure containing only modified fields):

```yaml
patches:
  - path: patch.yaml
```

```yaml
# patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
        - name: app
          resources:
            limits:
              memory: "512Mi"
```

**2. JSON 6902 Patch** (explicit `add`/`replace`/`remove` operations targeting JSON paths, used for specific inline modifications):

```yaml
patches:
  - target:
      kind: Deployment
      name: my-app
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
```

## Verification and Inspection

Render generated YAML to inspect output before applying:

```bash
$ kubectl kustomize overlays/dev > /tmp/render.yaml
$ less /tmp/render.yaml
```

or via standalone CLI:

```bash
$ kustomize build overlays/dev
```

Apply generated resources:

```bash
$ kubectl apply -k overlays/dev
```

Delete generated resources:

```bash
$ kubectl delete -k overlays/dev
```

## Kustomize vs Helm Context

- **Kustomize**: Template-free, valid YAML at all times, overlay/patch model, built natively into `kubectl`.
- **Helm**: Template-based (`{{ .Values.x }}`), package management with chart versioning, ideal for third-party application distribution.

CKAD tests Kustomize because of its native integration inside `kubectl`.

## References

- Official Kustomize Documentation in Kubernetes: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kustomize Project Docs: https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
- Kustomize Field Reference: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- `kubectl` Reference (`apply -k`, `kustomize`): https://kubernetes.io/docs/reference/kubectl/generated/kubectl_kustomize/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
