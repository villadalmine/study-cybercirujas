# Guided Exercises — 4.5 Use Helm and Kustomize to install cluster components

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with `kubectl` and `helm` v3 installed.

---

## Exercise 1 — Installing Cluster Components via Helm

1. Verify Helm version:
   ```bash
   helm version --short
   ```
2. Add repository and update indexes:
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm repo update
   ```
3. Install chart release:
   ```bash
   helm install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --create-namespace
   ```
4. Verify release registration:
   ```bash
   helm list --namespace ingress-nginx
   kubectl get pods --namespace ingress-nginx
   ```

---

## Exercise 2 — Customizing Chart Configuration Values

1. Create custom values override manifest `values-custom.yaml`:
   ```yaml
   controller:
     replicaCount: 2
     service:
       type: ClusterIP
   ```
2. Upgrade release with file overrides:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml
   ```
3. Pass inline `--set` parameter overrides:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     -f values-custom.yaml \
     --set controller.replicaCount=3
   ```
4. Inspect release revision history:
   ```bash
   helm history ingress-nginx --namespace ingress-nginx
   ```

---

## Exercise 3 — Rollback and Release Uninstall

1. Simulate failing image tag deployment:
   ```bash
   helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --set controller.image.tag=invalid-tag
   ```
2. Perform release rollback:
   ```bash
   helm rollback ingress-nginx --namespace ingress-nginx
   ```
3. Uninstall release:
   ```bash
   helm uninstall ingress-nginx --namespace ingress-nginx
   ```

---

## Exercise 4 — Kustomize Base and Overlays Architecture

1. Directory layout:
   ```
   app/
     base/
       deployment.yaml
       service.yaml
       kustomization.yaml
     overlays/
       prod/
         kustomization.yaml
   ```
2. Manifest base `deployment.yaml` and `service.yaml`.
3. Manifest `base/kustomization.yaml`:
   ```yaml
   resources:
     - deployment.yaml
     - service.yaml
   ```
4. Manifest `overlays/prod/kustomization.yaml`:
   ```yaml
   resources:
     - ../../base
   patches:
     - target:
         kind: Deployment
         name: nginx
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
   ```
5. Render and apply overlay:
   ```bash
   kubectl kustomize app/overlays/prod
   kubectl apply -k app/overlays/prod
   ```

---

<details>
<summary>View Answers</summary>

1. `--set` flags take precedence over `-f` values files.
2. `helm rollback` defaults to rolling back to the previous revision.
3. `kubectl apply -k <dir>` invokes Kustomize natively inside `kubectl`.

</details>
