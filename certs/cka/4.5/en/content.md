# 4.5 Use Helm and Kustomize to install cluster components

## Overview

Kubernetes manages declarative YAML objects, but maintaining raw manifests by hand becomes unmanageable when:

- A cluster component (Ingress controller, CNI driver, metrics-server, cert-manager) includes dozens of interdependent API objects (Deployments, Services, RBAC roles, CRDs, ConfigMaps).
- Applications require deployment across multiple target environments (dev/staging/prod) with minor parameter variations.
- Operators need to version, upgrade, and rollback sets of resources as unified release units.

**Helm** provides a **packaging** model (charts, templates, releases).
**Kustomize** provides a **composition** model (bases + overlays without templating engines), integrated directly inside `kubectl`.

The CKA exam expects candidates to install and manage cluster components using both tools.

---

## Helm

### Core Concepts

| Term | Description |
|---|---|
| **Chart** | Helm package containing template YAML files, metadata (`Chart.yaml`), and default values (`values.yaml`). |
| **Release** | A named instance of a chart deployed into a cluster namespace. |
| **Repository** | An HTTP(S) location or OCI registry publishing packaged charts (`.tgz`) and `index.yaml` manifests. |
| **Values** | Configuration parameters overriding chart defaults (`values.yaml`, `--set`, `-f`). |
| **Revision** | Each `install` or `upgrade` operation generates a new revision record supporting `rollback`. |

Helm 3 operates without Tiller: the CLI interacts directly with the Kubernetes API server and stores release state inside **Secrets** within target namespaces.

### Helm CLI Setup

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Chart Directory Structure

```
mychart/
├── Chart.yaml          # Metadata: name, version, appVersion
├── values.yaml          # Default value settings
├── charts/               # Sub-chart dependencies
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl     # Reusable template helper functions
│   └── NOTES.txt        # Post-installation output instructions
└── .helmignore
```

Templates use Go template syntax:

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-{{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

### Installing Cluster Components via Helm

Example: Installing the NGINX Ingress Controller.

```bash
# 1. Add repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# 2. Search for charts and view default values
helm search repo ingress-nginx
helm show values ingress-nginx/ingress-nginx > values.yaml

# 3. Install release into namespace
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort

# 4. Verify release status
helm list -n ingress-nginx
helm status ingress-nginx -n ingress-nginx
kubectl get all -n ingress-nginx
```

### Overriding Configuration Values

Precedence ordering (last flag takes precedence):

```bash
# Custom values file
helm install myrelease repo/chart -f custom-values.yaml

# Inline --set parameters
helm install myrelease repo/chart --set replicaCount=3,image.tag=1.2.3

# Combining files and inline overrides
helm install myrelease repo/chart -f custom-values.yaml --set replicaCount=5
```

Render template output locally without installing:

```bash
helm template myrelease repo/chart -f custom-values.yaml
helm install myrelease repo/chart --dry-run --debug
```

### Upgrades, History, and Rollbacks

```bash
# Upgrade active release
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --set controller.replicaCount=2

# Inspect revision history
helm history ingress-nginx -n ingress-nginx

# Rollback to revision 1
helm rollback ingress-nginx 1 -n ingress-nginx
```

Idempotent installation (`upgrade --install`):

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

### Uninstalling Releases

```bash
helm uninstall ingress-nginx -n ingress-nginx
```

Helm 3 does not automatically delete CRDs installed by charts to prevent accidental data loss. CRDs must be deleted manually using `kubectl delete crd` if required.

---

## Kustomize

### Core Concepts

Kustomize **omits templating engines**; it consumes plain YAML manifests (`base`) and applies declarative transformations using **overlays** and **patches** defined in `kustomization.yaml`.

Integrated inside `kubectl` since v1.14:

```bash
kubectl apply -k <directory>
kubectl kustomize <directory>     # Render YAML output without applying
```

### Base + Overlay Architecture

```
app/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── replica-patch.yaml
    └── prod/
        ├── kustomization.yaml
        └── replica-patch.yaml
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
namePrefix: prod-
commonLabels:
  env: prod
resources:
  - ../../base
patches:
  - path: replica-patch.yaml
    target:
      kind: Deployment
      name: myapp
images:
  - name: myapp
    newTag: v1.4.0
```

```yaml
# overlays/prod/replica-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 5
```

Render and apply:

```bash
kubectl kustomize overlays/prod/
kubectl apply -k overlays/prod/
```

### Common Kustomization Transformers

| Kustomization Field | Operation |
|---|---|
| `namePrefix` / `nameSuffix` | Prepends/appends strings to `metadata.name` across resources |
| `namespace` | Enforces target namespace across all resources |
| `commonLabels` | Appends labels to `metadata.labels` and matching selectors |
| `commonAnnotations` | Appends annotations across resources |
| `images` | Replaces container `image` names or tags |
| `configMapGenerator` / `secretGenerator` | Generates ConfigMaps/Secrets appending content hashes to names |
| `replicas` | Adjusts replica counts on Deployments or StatefulSets |

Content-hash generator example:

```yaml
# kustomization.yaml
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=debug
      - FEATURE_X=enabled
```

Updates to literal values change the generated name hash (`app-config-8gcm2ttbdg`), triggering automated Pod rollouts when ConfigMaps update.

---

## Exam Tips

- `kubectl apply -k <directory>` requires that target directories contain `kustomization.yaml`.
- `helm install` fails if a release name already exists within the target namespace; use `helm upgrade --install` for idempotency.
- Helm release state is stored in namespace Secrets named `helm.sh/release.v1.*`: `kubectl get secrets -n <ns> | grep sh.helm.release`.
- `kubectl kustomize` renders manifests locally without applying changes to the cluster.

---

## References

- Helm Official Documentation: https://helm.sh/docs/
- Kustomize Official References: https://kubectl.docs.kubernetes.io/references/kustomize/
- Declarative Management with Kustomize: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
