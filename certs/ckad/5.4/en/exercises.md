# Guided Exercises: Kustomize (CKAD 5.4)

**Reference Sources:**
- CNCF, *CKAD Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes docs, *Declarative Management of Kubernetes Objects Using Kustomize* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/

Requirements: `kubectl` >= 1.14 (built-in Kustomize) and access to a working cluster (minikube, kind, etc.).

---

## Exercise 1: Basic `kustomization.yaml` using `resources`

1. Create working directory structure:
   ```bash
   mkdir -p ~/kustomize-demo/base && cd ~/kustomize-demo/base
   ```
2. Create `deployment.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: nginx
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: nginx
     template:
       metadata:
         labels:
           app: nginx
       spec:
         containers:
           - name: nginx
             image: nginx:1.25
             ports:
               - containerPort: 80
   ```
3. Create `service.yaml`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: nginx
   spec:
     selector:
       app: nginx
     ports:
       - port: 80
         targetPort: 80
   ```
4. Create `kustomization.yaml` referencing both files:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   ```
5. Render generated manifest without applying:
   ```bash
   kubectl kustomize .
   ```
6. Apply to cluster:
   ```bash
   kubectl apply -k .
   ```

**Comprehension Questions:**
- What is the difference between `kubectl apply -k .` and `kubectl apply -f .`?
- What does `kubectl kustomize .` do, and why should you run it before `kubectl apply -k`?

---

## Exercise 2: `commonLabels`, `commonAnnotations`, `namePrefix`/`nameSuffix`

1. Add these fields to base `kustomization.yaml`:
   ```yaml
   namePrefix: dev-
   nameSuffix: "-v1"
   commonLabels:
     env: dev
   commonAnnotations:
     managed-by: kustomize
   ```
2. Re-render output:
   ```bash
   kubectl kustomize .
   ```
3. Observe `Deployment` and `Service` names updated to `dev-nginx-v1`, and label `env: dev` injected into `metadata.labels`, Deployment `spec.selector.matchLabels`, and Service `spec.selector`.

**Comprehension Questions:**
- Why does `commonLabels` modify `selectors` alongside `metadata.labels`?
- If this Deployment were running live in the cluster, what issue would applying updated `commonLabels` cause? (Consider immutable Deployment fields).

---

## Exercise 3: `configMapGenerator` and Name Hashing

1. Return to `base` directory and create `app.properties`:
   ```bash
   cat > app.properties <<EOF
   GREETING=hello
   LOG_LEVEL=info
   EOF
   ```
2. Add generator to `kustomization.yaml`:
   ```yaml
   configMapGenerator:
     - name: app-config
       files:
         - app.properties
   ```
3. Reference ConfigMap inside Deployment container spec:
   ```yaml
           envFrom:
             - configMapRef:
                 name: app-config
   ```
4. Render and observe generated object name:
   ```bash
   kubectl kustomize . | grep -A2 "kind: ConfigMap"
   ```
   Notice generated name contains a content hash suffix (e.g., `name: app-config-9m9df2b8k5`), and Deployment `envFrom` reference updates to match the hashed name.
5. Add `disableNameSuffixHash: true` to generator and re-render to compare.

**Comprehension Questions:**
- What purpose does Kustomize's generated ConfigMap name hash suffix serve?
- What operational advantage is lost when setting `disableNameSuffixHash: true` in CI/CD pipelines?

---

## Exercise 4: Overlays (`base` + `overlays/dev` + `overlays/prod`)

1. From `~/kustomize-demo`, create overlay directories:
   ```bash
   mkdir -p overlays/dev overlays/prod
   ```
2. Create `overlays/dev/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base
   patches:
     - target:
         kind: Deployment
         name: nginx
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 1
   ```
3. Create `overlays/prod/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base
   patchesStrategicMerge:
     - patch-resources.yaml
   ```
4. Create `overlays/prod/patch-resources.yaml` (strategic merge patch):
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: nginx
   spec:
     replicas: 5
     template:
       spec:
         containers:
           - name: nginx
             resources:
               limits:
                 cpu: "500m"
                 memory: "256Mi"
   ```
5. Compare generated manifests across environments:
   ```bash
   kubectl kustomize overlays/dev
   kubectl kustomize overlays/prod
   ```

**Comprehension Questions:**
- What advantage does maintaining a shared `base` with environment overlays provide over duplicating full manifest files for dev and prod?
- Why is a strategic merge patch (`patch-resources.yaml`) safer than targeting container array index `containers/0`?

---

## Exercise 5: JSON 6902 Patching to Override Image Tag in Prod

1. In `overlays/prod`, create `patch-image.yaml`:
   ```yaml
   - op: replace
     path: /spec/template/spec/containers/0/image
     value: nginx:1.27
   ```
2. Add patch to `overlays/prod/kustomization.yaml` under `patches`:
   ```yaml
   patches:
     - target:
         kind: Deployment
         name: nginx
       path: patch-image.yaml
   ```
3. Re-render and confirm prod uses `nginx:1.27` while `base` remains `nginx:1.25`:
   ```bash
   kubectl kustomize overlays/prod | grep image:
   kubectl kustomize overlays/dev | grep image:
   ```

**Comprehension Questions:**
- When is a JSON 6902 patch (`op`/`path`/`value`) preferred over a strategic merge patch?
- What happens if a JSON 6902 patch `path` specifies an array index that does not exist in the target resource?

---

## Exercise 6: `images` and `replicas` Transformers

1. In `overlays/prod/kustomization.yaml`, remove JSON 6902 patch from Exercise 5 and replace with `images` transformer:
   ```yaml
   images:
     - name: nginx
       newTag: "1.27"
   ```
2. Replace replica strategic merge patch with `replicas` transformer:
   ```yaml
   replicas:
     - name: nginx
       count: 5
   ```
3. Render and confirm output matches results from Exercises 4 and 5:
   ```bash
   kubectl kustomize overlays/prod
   ```
4. Apply prod overlay to cluster and inspect Pods:
   ```bash
   kubectl apply -k overlays/prod
   kubectl get deploy,pods -l env=dev
   ```
5. Teardown resources:
   ```bash
   kubectl delete -k overlays/prod
   ```

**Comprehension Questions:**
- What advantage do dedicated transformers (`images`, `replicas`) offer over writing manual patches?
- On the exam, if you need to override only an image tag in an overlay, which Kustomize feature is most direct?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- `kubectl apply -k .` runs Kustomize engine processing (`kustomization.yaml`, applying generators/transformers/patches) before transmitting generated YAML to API server; `kubectl apply -f .` sends raw file manifests without processing.
- `kubectl kustomize .` renders and outputs generated YAML to stdout without contacting cluster API, enabling validation before deployment.

**Exercise 2**
- `commonLabels` applies labels consistently across resource `metadata.labels` and workload selectors (`spec.selector.matchLabels`, Service `spec.selector`) to prevent selector misalignment.
- Deployment `spec.selector.matchLabels` is **immutable** post-creation. Updating `commonLabels` on an existing live Deployment causes `kubectl apply` validation failures (requires recreating Deployment).

**Exercise 3**
- Content hash suffix guarantees that modifying ConfigMap contents generates a new object name, forcing dependent Deployment Pods to undergo rolling updates.
- `disableNameSuffixHash: true` loses automatic rolling update triggers: modified ConfigMaps retain identical names, leaving running Pods using stale in-memory/mounted values.

**Exercise 4**
- Shared `base` eliminates duplicated manifest YAML across environments, isolating environment-specific changes to concise overlay files.
- Strategic merge patches match array elements by key (`name: nginx`) rather than array index (`containers/0`), remaining resilient if container order changes in `base`.

**Exercise 5**
- JSON 6902 patches are preferred for explicit single-field modifications (`replace`, `add`, `remove`) without strategic merge overhead, and are required for field deletion operations.
- Non-existent path targets cause Kustomize rendering failures (`kubectl kustomize` returns error).

**Exercise 6**
- Dedicated transformers (`images`, `replicas`) operate declaratively without requiring explicit JSON paths, avoiding fragile path index references.
- `images` transformer (`images: - name: ... newTag: ...`) is the most direct mechanism for overriding container tags in overlays.

</details>
