# Guided Exercises — CNPA 1.1: Declarative Resource Management and Infrastructure Concepts

**Certification:** CNPA (Certified Cloud Native Platform Engineering Associate), exam version 2025-04-01
**Domain weight:** 7.2
**Estimated lab time:** 150–210 minutes

## What you will be able to do after this lab

1. Explain, with evidence taken from a live cluster, why the Kubernetes API server is a *store of desired state* and not an execution engine.
2. Distinguish imperative, imperative-object and declarative object management, and predict the outcome of each on a resource that already exists.
3. Read `metadata.managedFields`, diagnose a Server-Side Apply (SSA) conflict, and decide between `--force-conflicts`, co-ownership and removing the field.
4. Prove empirically that Kubernetes controllers are **level-triggered**, and explain why that property is what makes declarative platforms self-healing.
5. Detect and remediate configuration drift (`kubectl diff`, `terraform plan`) and reason about pruning/garbage collection of resources removed from source.
6. Extend the declarative API surface with a CRD (structural schema, defaulting, CEL validation, status subresource, printer columns) and drive it with a minimal reconciler.
7. Compare a state-file-based IaC engine (Terraform) with a control-plane-based one (Kubernetes / Crossplane) in terms of drift, ownership and blast radius.

---

## Prerequisites

| Tool | Minimum version | Check |
|---|---|---|
| `kind` (or any cluster where you are cluster-admin) | 0.24 | `kind version` |
| `kubectl` | 1.30 (1.32 used for outputs below) | `kubectl version --client -o yaml` |
| `jq` | 1.6 | `jq --version` |
| `docker` or `podman` | any recent | `docker version` |
| `terraform` (Exercise 7 only) | 1.6 | `terraform version` |
| `helm` (Exercise 7b, optional) | 3.14 | `helm version` |

> Every command in this lab runs against a throwaway cluster. Do **not** run Exercise 3 Step 6 (stopping `kube-controller-manager`) on anything you did not create yourself.

### Setup

```bash
kind create cluster --name cnpa-1-1 --image kindest/node:v1.32.0
```

Expected output:

```
Creating cluster "cnpa-1-1" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-cnpa-1-1"
```

```bash
mkdir -p ~/cnpa-1-1 && cd ~/cnpa-1-1
kubectl create namespace cnpa-lab
kubectl config set-context --current --namespace=cnpa-lab
```

---

## Exercise 1 — Imperative vs. declarative object management, and the three-way merge

The goal is not "declarative is better". The goal is to be able to predict *exactly* which fields change when you run `kubectl apply`, because that prediction is what a platform engineer owes their tenants.

### Steps

1. Create a Deployment **imperatively** (imperative command — no manifest exists anywhere):

   ```bash
   kubectl create deployment web --image=nginx:1.27.3 --replicas=2
   ```

   ```
   deployment.apps/web created
   ```

2. Inspect the annotations of the object you just created:

   ```bash
   kubectl get deployment web -o jsonpath='{.metadata.annotations}' | jq .
   ```

   ```json
   {
     "deployment.kubernetes.io/revision": "1"
   }
   ```

   Note what is **absent**: there is no `kubectl.kubernetes.io/last-applied-configuration`.

3. Perform another imperative change, simulating a 3 a.m. incident response:

   ```bash
   kubectl scale deployment web --replicas=5
   kubectl get deployment web -o wide
   ```

   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES         SELECTOR
   web    5/5     5            5           45s   nginx        nginx:1.27.3   app=web
   ```

4. Now write the manifest that the platform team believes is the truth, `deploy-v1.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: cnpa-lab
     labels:
       app: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.3
             ports:
               - containerPort: 80
                 name: http
             resources:
               requests:
                 cpu: 50m
                 memory: 64Mi
               limits:
                 memory: 128Mi
             readinessProbe:
               httpGet:
                 path: /
                 port: http
               initialDelaySeconds: 2
               periodSeconds: 5
   ```

5. Apply it (declarative object management, client-side apply):

   ```bash
   kubectl apply -f deploy-v1.yaml
   ```

   ```
   Warning: resource deployments/web is missing the kubectl.kubernetes.io/last-applied-configuration
   annotation which is required by kubectl apply. kubectl apply should only be used on resources created
   declaratively by either kubectl create --save-config or kubectl apply. The missing annotation will be
   patched automatically.
   deployment.apps/web configured
   ```

   ```bash
   kubectl get deployment web
   ```

   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    2/2     2            2           3m10s
   ```

6. Read the annotation that now exists, and confirm it is the *applied configuration*, not the live object:

   ```bash
   kubectl get deployment web \
     -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
     | jq '.spec | keys'
   ```

   ```json
   [
     "replicas",
     "selector",
     "template"
   ]
   ```

> **Questions — block 1A**
> **Q1.1** — Name the three fields the client-side three-way merge compares, and say which one lives in the cluster, which one lives on your disk, and which one lives in the annotation.
> **Q1.2** — In step 5, the live object had `replicas: 5` and the manifest had `replicas: 2`. Explain *mechanically* why the result was 2 and not 5, given that there was no `last-applied-configuration` at that moment.
> **Q1.3** — Why does the warning in step 5 matter operationally? What class of field could have been silently deleted if the imperative object had carried fields that the manifest does not mention?

7. Now the trap that has taken down more production autoscaling than any other single mistake. Remove `replicas` from the manifest:

   ```bash
   cp deploy-v1.yaml deploy-v2.yaml
   # delete the "replicas: 2" line from deploy-v2.yaml
   sed -i '/^  replicas: 2$/d' deploy-v2.yaml
   ```

8. Scale up imperatively first, to simulate an HPA having done it:

   ```bash
   kubectl scale deployment web --replicas=6
   kubectl get deployment web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   6
   ```

9. Apply the manifest that no longer mentions `replicas`:

   ```bash
   kubectl apply -f deploy-v2.yaml
   kubectl get deployment web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   deployment.apps/web configured
   1
   ```

> **Questions — block 1B**
> **Q1.4** — The manifest said nothing about `replicas`, the live object said 6, and the result is 1. Reconstruct the exact merge patch `kubectl` sent, and explain where the value `1` came from.
> **Q1.5** — Your platform runs an HPA on this Deployment and your CD pipeline runs `kubectl apply` on every commit. Describe the failure that follows, and give two different correct fixes (one that changes the manifest, one that changes the apply mechanism).
> **Q1.6** — Classify each of these as *imperative command*, *imperative object configuration*, or *declarative object configuration*: `kubectl scale`, `kubectl replace -f`, `kubectl apply -f`, `kubectl create -f`, `kubectl edit`.

---

## Exercise 2 — Server-Side Apply: field ownership as a first-class API concept

Client-side apply keeps intent in an annotation that only `kubectl` understands. Server-Side Apply moves ownership into the API server, where *every* client — controllers, operators, GitOps agents, humans — participates in the same ownership model.

### Steps

1. Reset to a known state and adopt the object with SSA under an explicit field manager:

   ```bash
   kubectl apply --server-side --field-manager=platform-team -f deploy-v1.yaml
   ```

   ```
   deployment.apps/web serverside-applied
   ```

2. Read the ownership ledger:

   ```bash
   kubectl get deployment web --show-managed-fields -o yaml \
     | yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}' 2>/dev/null \
     || kubectl get deployment web --show-managed-fields -o json | jq '.metadata.managedFields[] | {manager, operation}'
   ```

   ```json
   { "manager": "kube-controller-manager", "operation": "Update" }
   { "manager": "platform-team",           "operation": "Apply" }
   ```

3. Look at what `platform-team` actually owns:

   ```bash
   kubectl get deployment web --show-managed-fields -o json \
     | jq '.metadata.managedFields[] | select(.manager=="platform-team") | .fieldsV1.["f:spec"] | keys'
   ```

   ```json
   [
     "f:replicas",
     "f:selector",
     "f:template"
   ]
   ```

   And the full structure of one entry (trimmed):

   ```yaml
   - apiVersion: apps/v1
     fieldsType: FieldsV1
     fieldsV1:
       f:spec:
         f:replicas: {}
         f:template:
           f:spec:
             f:containers:
               k:{"name":"nginx"}:
                 .: {}
                 f:image: {}
                 f:name: {}
                 f:resources:
                   f:requests:
                     f:cpu: {}
                     f:memory: {}
     manager: platform-team
     operation: Apply
     time: "2026-08-06T10:14:22Z"
   ```

> **Questions — block 2A**
> **Q2.1** — What does the key `k:{"name":"nginx"}` mean, and what property of the `containers` list makes that key possible? What would the entry look like for a list that is *atomic* instead?
> **Q2.2** — Why is `kube-controller-manager` listed with `operation: Update` rather than `Apply`, and what is the practical difference between the two operations for ownership?

4. Now a second actor — an application team's pipeline — applies a competing configuration:

   ```bash
   sed 's/replicas: 2/replicas: 4/' deploy-v1.yaml > deploy-appteam.yaml
   kubectl apply --server-side --field-manager=app-team -f deploy-appteam.yaml
   ```

   ```
   error: Apply failed with 1 conflict: conflict with "platform-team" using apps/v1: .spec.replicas
   Please review the fields above--they currently have other managers. Here
   are the ways you can resolve this warning:
   * If you intend to manage all of these fields, please re-run the apply
     command with the `--force-conflicts` flag.
   * If you do not intend to manage all of the fields, please edit your
     manifest to remove references to the fields that should keep their
     current managers.
   * You may co-own fields by updating your manifest to match the existing
     value; in this case, you'll become the manager if the other manager(s)
     stop managing the field (remove it from their configuration).
   See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
   ```

5. Take ownership by force, then inspect who owns `spec.replicas`:

   ```bash
   kubectl apply --server-side --force-conflicts --field-manager=app-team -f deploy-appteam.yaml
   kubectl get deployment web --show-managed-fields -o json \
     | jq -r '.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:replicas"]) | .manager'
   ```

   ```
   deployment.apps/web serverside-applied
   app-team
   ```

6. Re-apply as `platform-team` **without** force, and observe that the conflict is now symmetric:

   ```bash
   kubectl apply --server-side --field-manager=platform-team -f deploy-v1.yaml
   ```

   ```
   error: Apply failed with 1 conflict: conflict with "app-team" using apps/v1: .spec.replicas
   ...
   ```

7. Demonstrate co-ownership: make `platform-team`'s manifest agree with the live value.

   ```bash
   kubectl apply --server-side --field-manager=platform-team -f deploy-appteam.yaml
   kubectl get deployment web --show-managed-fields -o json \
     | jq -r '[.metadata.managedFields[] | select(.fieldsV1["f:spec"]["f:replicas"]) | .manager]'
   ```

   ```
   deployment.apps/web serverside-applied
   [
     "app-team",
     "platform-team"
   ]
   ```

8. Demonstrate deletion-by-omission under SSA. Remove `resources` from `platform-team`'s config and apply:

   ```bash
   kubectl apply --server-side --field-manager=platform-team -f - <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: cnpa-lab
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.3
   EOF

   kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
   ```

   ```
   deployment.apps/web serverside-applied
   {}
   ```

> **Questions — block 2B**
> **Q2.3** — In step 8, `resources` disappeared. State the general rule SSA uses to decide whether omitting a field deletes it. Would the result have been the same if `app-team` had also been applying `resources`?
> **Q2.4** — Your GitOps agent applies with field manager `argocd-controller`. An SRE runs `kubectl edit` during an incident. Predict what happens on the next sync, and what the ownership ledger looks like afterwards. Then predict the same scenario if the SRE had used `kubectl apply --server-side --field-manager=sre-hotfix` instead.
> **Q2.5** — Why is `--force-conflicts` in an automated pipeline a policy decision rather than a convenience flag? Name one scenario where the correct answer is to *fail the pipeline* on conflict.
> **Q2.6** — Both `spec.replicas` co-owners now agree on `4`. `app-team` removes `replicas` from its manifest and applies. What is the resulting value, and why?

---

## Exercise 3 — The reconciliation loop: proving controllers are level-triggered

### Steps

1. Establish the ownership chain from Deployment to Pod:

   ```bash
   kubectl get deployment,replicaset,pod -l app=web
   ```

   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   4/4     4            4           14m

   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6d8f9c7b54   4         4         4       14m

   NAME                       READY   STATUS    RESTARTS   AGE
   pod/web-6d8f9c7b54-4kt2p   1/1     Running   0          6m
   ...
   ```

   ```bash
   kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}' | jq .
   ```

   ```json
   [
     {
       "apiVersion": "apps/v1",
       "kind": "ReplicaSet",
       "name": "web-6d8f9c7b54",
       "uid": "4b0c1e0e-3a9e-4b34-9a5f-1f3f1f2e77aa",
       "controller": true,
       "blockOwnerDeletion": true
     }
   ]
   ```

2. Watch reconciliation happen. In terminal A:

   ```bash
   kubectl get pods -l app=web --watch
   ```

   In terminal B:

   ```bash
   kubectl delete pod -l app=web --field-selector=status.phase=Running --wait=false | head -1
   ```

   Terminal A shows the deleted Pods terminating and **new Pod names** appearing:

   ```
   web-6d8f9c7b54-4kt2p   1/1   Terminating   0   8m
   web-6d8f9c7b54-x9plq   0/1   Pending       0   0s
   web-6d8f9c7b54-x9plq   0/1   ContainerCreating   0   0s
   web-6d8f9c7b54-x9plq   1/1   Running       0   2s
   ```

3. Confirm the ReplicaSet itself was never modified:

   ```bash
   kubectl get replicaset -l app=web -o jsonpath='{.items[0].metadata.generation}{"\t"}{.items[0].spec.replicas}{"\n"}'
   ```

   ```
   1	4
   ```

4. Now edit the *child* directly and watch the parent controller overrule you:

   ```bash
   RS=$(kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl scale rs "$RS" --replicas=1
   sleep 3
   kubectl get rs "$RS" -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   replicaset.apps/web-6d8f9c7b54 scaled
   4
   ```

> **Questions — block 3A**
> **Q3.1** — Nothing in step 2 "told" the ReplicaSet controller that a Pod was gone. Describe the loop that produced the new Pod, naming the two inputs it compares.
> **Q3.2** — In step 4 you changed the ReplicaSet and it reverted. Which controller reverted it, and what desired state was it reconciling against? Draw the full chain from your `kubectl apply` down to the container running on the node.
> **Q3.3** — Pod names changed in step 2. What does that tell you about the identity model of Deployment-managed Pods, and which workload API would have preserved the identity instead?

5. Explore ownership-based garbage collection:

   ```bash
   kubectl delete deployment web --cascade=orphan
   kubectl get replicaset,pod -l app=web
   ```

   ```
   deployment.apps "web" deleted
   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6d8f9c7b54   4         4         4       22m

   NAME                       READY   STATUS    RESTARTS   AGE
   pod/web-6d8f9c7b54-x9plq   1/1     Running   0          9m
   ...
   ```

   ```bash
   kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}{"\n"}'
   ```

   ```

   ```

   (empty — the owner reference was removed, not the object)

   Now re-create the Deployment and watch adoption:

   ```bash
   kubectl apply -f deploy-v1.yaml
   kubectl get rs -l app=web
   ```

   ```
   deployment.apps/web created
   NAME                             DESIRED   CURRENT   READY   AGE
   web-6d8f9c7b54                   2         2         2       23m
   ```

   Note: **no new ReplicaSet** was created, and its age is unchanged.

6. **Advanced (throwaway clusters only).** Remove the reconciler and observe that the API server alone changes nothing:

   ```bash
   docker exec cnpa-1-1-control-plane \
     mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/kcm.yaml
   sleep 15
   kubectl -n kube-system get pods -l component=kube-controller-manager
   ```

   ```
   No resources found in kube-system namespace.
   ```

   ```bash
   kubectl delete pod -l app=web --wait=false | head -1
   sleep 20
   kubectl get pods -l app=web
   ```

   ```
   No resources found in cnpa-lab namespace.
   ```

   ```bash
   kubectl get deployment web -o jsonpath='desired={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
   ```

   ```
   desired=2 ready=
   ```

   Restore it:

   ```bash
   docker exec cnpa-1-1-control-plane \
     mv /tmp/kcm.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml
   sleep 30
   kubectl get pods -l app=web
   ```

   ```
   NAME                     READY   STATUS    RESTARTS   AGE
   web-6d8f9c7b54-2f9jm     1/1     Running   0          12s
   web-6d8f9c7b54-nb7xk     1/1     Running   0          12s
   ```

> **Questions — block 3B**
> **Q3.4** — During step 6, the Deployment object still declared `replicas: 2` while zero Pods existed. Was the cluster in a valid state? Use the words *desired state*, *observed state* and *reconciliation* in your answer.
> **Q3.5** — When the controller came back it did **not** replay the delete events it missed — it simply looked at the world. Name that property, contrast it with edge-triggered event handling, and explain why it is the reason a controller can crash-loop, be OOM-killed or be upgraded without corrupting the platform.
> **Q3.6** — `--cascade=orphan` removed the `ownerReferences` from the ReplicaSet. Which controller performs cascading deletion normally, and what would `--cascade=background` vs `--cascade=foreground` have done differently?
> **Q3.7** — Adoption in step 5 happened because a selector matched. Describe the production hazard of two Deployments in one namespace whose selectors overlap.

---

## Exercise 4 — Drift detection, immutability, and removing resources declaratively

### Steps

1. Introduce drift out-of-band and detect it *before* changing anything:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.25.5
   kubectl diff -f deploy-v1.yaml
   echo "exit code: $?"
   ```

   ```diff
   diff -u -N /tmp/LIVE-1834/apps.v1.Deployment.cnpa-lab.web /tmp/MERGED-2901/apps.v1.Deployment.cnpa-lab.web
   --- /tmp/LIVE-1834/apps.v1.Deployment.cnpa-lab.web
   +++ /tmp/MERGED-2901/apps.v1.Deployment.cnpa-lab.web
   @@ -33,7 +33,7 @@
          spec:
            containers:
   -        - image: nginx:1.25.5
   +        - image: nginx:1.27.3
              imagePullPolicy: IfNotPresent
              name: nginx
   exit code: 1
   ```

2. Remediate:

   ```bash
   kubectl apply -f deploy-v1.yaml && kubectl diff -f deploy-v1.yaml; echo "exit code: $?"
   ```

   ```
   deployment.apps/web configured
   exit code: 0
   ```

> **Questions — block 4A**
> **Q4.1** — `kubectl diff` exits 1 on difference and 0 on none. Write the one-line CI check that turns this into a drift alarm, and explain why exit code 1 here is *not* an error.
> **Q4.2** — `kubectl diff` performs the merge server-side (dry-run) rather than comparing YAML text. Give two concrete differences that a naive text diff would report as drift but that are not drift.

3. Hit the wall of immutability — the point where declarative intent cannot be reconciled in place:

   ```bash
   sed 's/app: web/app: web-v2/g' deploy-v1.yaml > deploy-badselector.yaml
   kubectl apply -f deploy-badselector.yaml
   ```

   ```
   The Deployment "web" is invalid: spec.selector: Invalid value:
   v1.LabelSelector{MatchLabels:map[string]string{"app":"web-v2"}, MatchExpressions:[]v1.LabelSelectorRequirement(nil)}:
   field is immutable
   ```

4. Same class of failure on a different API:

   ```bash
   kubectl create job pi --image=perl:5.34 -- perl -Mbignum=bpi -wle 'print bpi(200)'
   kubectl patch job pi --type=merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"pi","image":"perl:5.36"}]}}}}'
   ```

   ```
   job.batch/pi created
   The Job "pi" is invalid: spec.template: Invalid value: ...: field is immutable
   ```

> **Questions — block 4B**
> **Q4.3** — Immutable fields break the illusion that "declarative means I write what I want and it happens". Explain what the platform (or the tenant's tooling) must do instead, and what that implies for a GitOps controller's sync strategy.
> **Q4.4** — Name three more immutable or conditionally-immutable fields you would expect an application team to trip over, and for each, the correct remediation.

5. Deleting resources declaratively. Create a directory-based configuration set:

   ```bash
   mkdir -p manifests && cp deploy-v1.yaml manifests/
   cat > manifests/svc.yaml <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: cnpa-lab
     labels:
       app: web
       cnpa.io/managed-by: exercise-4
   spec:
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   EOF
   cat > manifests/cm.yaml <<'EOF'
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: web-config
     namespace: cnpa-lab
     labels:
       app: web
       cnpa.io/managed-by: exercise-4
   data:
     LOG_LEVEL: "info"
   EOF

   kubectl apply -f manifests/
   ```

   ```
   configmap/web-config created
   deployment.apps/web configured
   service/web created
   ```

6. Now delete `manifests/cm.yaml` from the source of truth and re-apply:

   ```bash
   rm manifests/cm.yaml
   kubectl apply -f manifests/
   kubectl get configmap web-config
   ```

   ```
   deployment.apps/web configured
   service/web unchanged
   NAME          DATA   AGE
   web-config    1      2m
   ```

   The ConfigMap **survives**. Now prune with an explicit ownership label:

   ```bash
   kubectl apply -f manifests/ --prune -l cnpa.io/managed-by=exercise-4
   kubectl get configmap web-config
   ```

   ```
   service/web unchanged
   configmap/web-config pruned
   Error from server (NotFound): configmaps "web-config" not found
   ```

   > The exact deprecation wording around `--prune` varies by `kubectl` minor version; from 1.27 onwards the supported successor is ApplySet-based pruning:
   > ```bash
   > KUBECTL_APPLYSET=true kubectl apply -f manifests/ \
   >   --prune --applyset=cnpa-exercise4 --namespace=cnpa-lab
   > ```

> **Questions — block 4C**
> **Q4.5** — Explain in one sentence why "delete the file from Git" is not, by itself, a delete operation. What is the general name for this problem in GitOps tooling, and how do Argo CD and Flux each solve it?
> **Q4.6** — Pruning by label selector is dangerous. Describe the blast radius if a tenant adds `cnpa.io/managed-by=exercise-4` to a resource that is not in `manifests/`, and name the ApplySet property that mitigates it.

---

## Exercise 5 — Extending the declarative API: CRD + reconciler

This is the platform-engineering core of the domain: a platform is a set of **APIs** plus **controllers** that make those APIs true.

### Steps

1. Define the API. Save as `crd-databaseclaim.yaml`:

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: databaseclaims.platform.example.com
   spec:
     group: platform.example.com
     scope: Namespaced
     names:
       plural: databaseclaims
       singular: databaseclaim
       kind: DatabaseClaim
       shortNames: [dbc]
       categories: [platform]
     versions:
       - name: v1alpha1
         served: true
         storage: true
         subresources:
           status: {}
         schema:
           openAPIV3Schema:
             type: object
             description: A tenant's request for a managed database. The platform, not the tenant, decides how it is fulfilled.
             required: [spec]
             properties:
               spec:
                 type: object
                 required: [engine]
                 properties:
                   engine:
                     type: string
                     description: Database engine requested by the tenant.
                     enum: [postgres, mysql]
                   version:
                     type: string
                     description: Major (or major.minor) engine version.
                     pattern: '^[0-9]+(\.[0-9]+)?$'
                     default: "16"
                   sizeGi:
                     type: integer
                     description: Requested storage in GiB.
                     minimum: 10
                     maximum: 500
                     default: 20
                   tier:
                     type: string
                     description: Service tier; drives backup policy and SLO.
                     enum: [dev, staging, prod]
                     default: dev
                 x-kubernetes-validations:
                   - rule: "self.tier != 'prod' || self.sizeGi >= 100"
                     message: "prod tier requires sizeGi >= 100"
                   - rule: "self.engine != 'mysql' || self.version != '16'"
                     message: "mysql has no version 16; set spec.version explicitly"
               status:
                 type: object
                 properties:
                   phase:
                     type: string
                   connectionConfigRef:
                     type: string
                   observedGeneration:
                     type: integer
                     format: int64
         additionalPrinterColumns:
           - name: Engine
             type: string
             jsonPath: .spec.engine
           - name: Version
             type: string
             jsonPath: .spec.version
           - name: Size
             type: integer
             jsonPath: .spec.sizeGi
           - name: Tier
             type: string
             jsonPath: .spec.tier
           - name: Phase
             type: string
             jsonPath: .status.phase
           - name: Age
             type: date
             jsonPath: .metadata.creationTimestamp
   ```

   ```bash
   kubectl apply -f crd-databaseclaim.yaml
   kubectl api-resources --api-group=platform.example.com
   ```

   ```
   customresourcedefinition.apiextensions.k8s.io/databaseclaims.platform.example.com created
   NAME             SHORTNAMES   APIVERSION                            NAMESPACED   KIND
   databaseclaims   dbc          platform.example.com/v1alpha1         true         DatabaseClaim
   ```

2. Confirm the API is self-documenting — the schema *is* the documentation:

   ```bash
   kubectl explain databaseclaims.spec
   ```

   ```
   GROUP:      platform.example.com
   KIND:       DatabaseClaim
   VERSION:    v1alpha1

   FIELD: spec <Object>

   FIELDS:
     engine	<string> -required-
       Database engine requested by the tenant.
     sizeGi	<integer>
       Requested storage in GiB.
     tier	<string>
       Service tier; drives backup policy and SLO.
     version	<string>
       Major (or major.minor) engine version.
   ```

3. Exercise validation — the API rejects bad intent *before* any controller runs:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: DatabaseClaim
   metadata:
     name: bad-engine
     namespace: cnpa-lab
   spec:
     engine: mongodb
   EOF
   ```

   ```
   The DatabaseClaim "bad-engine" is invalid: spec.engine: Unsupported value: "mongodb": supported values: "mysql", "postgres"
   ```

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: DatabaseClaim
   metadata:
     name: undersized-prod
     namespace: cnpa-lab
   spec:
     engine: postgres
     tier: prod
     sizeGi: 20
   EOF
   ```

   ```
   The DatabaseClaim "undersized-prod" is invalid: spec: Invalid value: "object": prod tier requires sizeGi >= 100
   ```

4. Create a valid claim and observe **defaulting**:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: DatabaseClaim
   metadata:
     name: orders
     namespace: cnpa-lab
   spec:
     engine: postgres
   EOF

   kubectl get dbc orders -o jsonpath='{.spec}{"\n"}' | jq .
   ```

   ```json
   {
     "engine": "postgres",
     "sizeGi": 20,
     "tier": "dev",
     "version": "16"
   }
   ```

   ```bash
   kubectl get dbc
   ```

   ```
   NAME     ENGINE     VERSION   SIZE   TIER   PHASE   AGE
   orders   postgres   16        20     dev            8s
   ```

> **Questions — block 5A**
> **Q5.1** — `PHASE` is empty. Is the object "broken"? Explain what the empty status column proves about the relationship between the API and its controller.
> **Q5.2** — Defaulting happened at admission, and the defaults were *persisted* into `spec`. Name one operational consequence of persisted defaults when the platform team later changes `default: 20` to `default: 50`.
> **Q5.3** — The `prod tier requires sizeGi >= 100` rule is CEL evaluated by the API server. Name two advantages over enforcing the same rule in a validating admission webhook, and one thing the webhook can do that CEL cannot.
> **Q5.4** — Why does `subresources: {status: {}}` matter for a controller? What would break in the reconciler if the status subresource did not exist?

5. Write the reconciler, `reconcile.sh`:

   ```bash
   cat > reconcile.sh <<'EOF'
   #!/usr/bin/env bash
   set -euo pipefail

   NS="${NS:-cnpa-lab}"
   MANAGER="dbclaim-controller"
   INTERVAL="${INTERVAL:-5}"

   reconcile_once() {
     local claims
     claims=$(kubectl get databaseclaims -n "$NS" -o json)

     echo "$claims" | jq -c '.items[]' | while read -r claim; do
       local name uid engine version size generation
       name=$(jq -r '.metadata.name'        <<<"$claim")
       uid=$(jq -r '.metadata.uid'          <<<"$claim")
       engine=$(jq -r '.spec.engine'        <<<"$claim")
       version=$(jq -r '.spec.version'      <<<"$claim")
       size=$(jq -r '.spec.sizeGi'          <<<"$claim")
       generation=$(jq -r '.metadata.generation' <<<"$claim")

       # 1) Converge the child objects towards desired state (create OR correct).
       kubectl apply --server-side --field-manager="$MANAGER" -f - >/dev/null <<YAML
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: ${name}-connection
     namespace: ${NS}
     labels:
       platform.example.com/claim: ${name}
     ownerReferences:
       - apiVersion: platform.example.com/v1alpha1
         kind: DatabaseClaim
         name: ${name}
         uid: ${uid}
         controller: true
         blockOwnerDeletion: true
   data:
     host: "${name}.${engine}.db.svc.internal"
     port: "$([ "$engine" = postgres ] && echo 5432 || echo 3306)"
     engine: "${engine}"
     version: "${version}"
     sizeGi: "${size}"
   YAML

       # 2) Report observed state back on the status subresource.
       kubectl patch databaseclaim "$name" -n "$NS" \
         --subresource=status --type=merge \
         -p "{\"status\":{\"phase\":\"Ready\",\"connectionConfigRef\":\"${name}-connection\",\"observedGeneration\":${generation}}}" \
         >/dev/null

       echo "$(date -Is) reconciled ${name} (generation ${generation})"
     done
   }

   echo "dbclaim-controller starting; namespace=${NS} interval=${INTERVAL}s"
   while true; do
     reconcile_once || echo "$(date -Is) reconcile error, retrying"
     sleep "$INTERVAL"
   done
   EOF
   chmod +x reconcile.sh
   ```

6. Run it in terminal A:

   ```bash
   ./reconcile.sh
   ```

   ```
   dbclaim-controller starting; namespace=cnpa-lab interval=5s
   2026-08-06T10:41:03+00:00 reconciled orders (generation 1)
   2026-08-06T10:41:08+00:00 reconciled orders (generation 1)
   ```

   In terminal B:

   ```bash
   kubectl get dbc
   kubectl get configmap orders-connection -o jsonpath='{.data}{"\n"}' | jq .
   ```

   ```
   NAME     ENGINE     VERSION   SIZE   TIER   PHASE   AGE
   orders   postgres   16        20     dev    Ready   4m

   {
     "engine": "postgres",
     "host": "orders.postgres.db.svc.internal",
     "port": "5432",
     "sizeGi": "20",
     "version": "16"
   }
   ```

7. Prove self-healing of the *child*:

   ```bash
   kubectl delete configmap orders-connection
   sleep 8
   kubectl get configmap orders-connection
   ```

   ```
   configmap "orders-connection" deleted
   NAME                DATA   AGE
   orders-connection   5      6s
   ```

8. Prove **level-triggered** behaviour. Stop the controller (Ctrl-C in terminal A), then create work while it is down:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: DatabaseClaim
   metadata:
     name: billing
     namespace: cnpa-lab
   spec:
     engine: mysql
     version: "8.0"
     tier: prod
     sizeGi: 200
   EOF

   kubectl get dbc
   ```

   ```
   NAME      ENGINE     VERSION   SIZE   TIER   PHASE   AGE
   billing   mysql      8.0       200    prod           5s
   orders    postgres   16        20     dev    Ready   9m
   ```

   Restart the controller and wait one interval:

   ```bash
   ./reconcile.sh &
   sleep 8
   kubectl get dbc
   kubectl get configmaps -l platform.example.com/claim
   ```

   ```
   NAME      ENGINE     VERSION   SIZE   TIER   PHASE   AGE
   billing   mysql      8.0       200    prod   Ready   1m
   orders    postgres   16        20     dev    Ready   10m

   NAME                 DATA   AGE
   billing-connection   5      6s
   orders-connection    5      3m
   ```

9. Prove **garbage collection** by ownership:

   ```bash
   kubectl delete dbc orders
   sleep 5
   kubectl get configmaps -l platform.example.com/claim
   ```

   ```
   databaseclaim.platform.example.com "orders" deleted
   NAME                 DATA   AGE
   billing-connection   5      1m
   ```

> **Questions — block 5B**
> **Q5.5** — The reconciler never subscribes to events; it lists everything every 5 seconds. Which delivery guarantee does that give you that an event subscription does not? What does a real controller-runtime controller use instead, and how does it keep the same guarantee?
> **Q5.6** — In step 9 nothing in `reconcile.sh` deletes ConfigMaps, yet the ConfigMap disappeared. Name the component responsible and the exact field that made it possible.
> **Q5.7** — `observedGeneration` is written from `metadata.generation`. Write the one-line expression a monitoring system would use to detect "the controller has not yet caught up with the user's latest change", and explain why `metadata.resourceVersion` would be the wrong field.
> **Q5.8** — The reconciler uses `kubectl apply --server-side --field-manager=dbclaim-controller` rather than `kubectl create`. Give two distinct reasons why that matters for a controller specifically.
> **Q5.9** — The reconciler writes `phase: Ready` unconditionally. Explain why real APIs use a `conditions` list (`type/status/reason/message/lastTransitionTime`) instead of a single phase string, and what a client can do with conditions that it cannot do with a phase.

10. Finalizers — declarative deletion is also a reconciliation:

    ```bash
    kubectl patch dbc billing --type=merge \
      -p '{"metadata":{"finalizers":["platform.example.com/deprovision-storage"]}}'
    kubectl delete dbc billing --timeout=15s
    ```

    ```
    databaseclaim.platform.example.com/billing patched
    error: timed out waiting for the condition on databaseclaims/billing
    ```

    ```bash
    kubectl get dbc billing -o jsonpath='deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}'
    ```

    ```
    deletionTimestamp=2026-08-06T10:55:12Z finalizers=["platform.example.com/deprovision-storage"]
    ```

    Release it (this is what the controller would do after deprovisioning the real storage):

    ```bash
    kubectl patch dbc billing --type=merge -p '{"metadata":{"finalizers":null}}'
    kubectl get dbc billing
    ```

    ```
    databaseclaim.platform.example.com/billing patched
    Error from server (NotFound): databaseclaims.platform.example.com "billing" not found
    ```

> **Questions — block 5C**
> **Q5.10** — `kubectl delete` "hung". What actually happened at the API server, and what is the object's state called during that window?
> **Q5.11** — Your controller is uninstalled while 40 claims carry its finalizer. Describe the incident and the two remediation paths, including the one that is *unsafe* and why.
> **Q5.12** — Why must a finalizer-based deprovision be idempotent? Give a concrete sequence where the controller runs its cleanup twice.

---

## Exercise 6 — Declarative composition without templating: Kustomize

### Steps

1. Build the structure:

   ```bash
   mkdir -p kustomize/base kustomize/overlays/{dev,prod}
   cp deploy-v1.yaml kustomize/base/deployment.yaml
   cp manifests/svc.yaml kustomize/base/service.yaml

   cat > kustomize/base/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   labels:
     - pairs:
         app.kubernetes.io/name: web
         app.kubernetes.io/part-of: cnpa-lab
       includeSelectors: false
   EOF
   ```

2. A production overlay expressing *only the delta*:

   ```bash
   cat > kustomize/overlays/prod/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: cnpa-lab
   namePrefix: prod-
   resources:
     - ../../base
   images:
     - name: nginx
       newTag: 1.27.3-alpine
   replicas:
     - name: web
       count: 5
   patches:
     - target:
         kind: Deployment
         name: web
       patch: |-
         - op: add
           path: /spec/template/spec/topologySpreadConstraints
           value:
             - maxSkew: 1
               topologyKey: kubernetes.io/hostname
               whenUnsatisfiable: ScheduleAnyway
               labelSelector:
                 matchLabels:
                   app: web
   EOF
   ```

3. Render without applying — the fundamental discipline:

   ```bash
   kubectl kustomize kustomize/overlays/prod | head -40
   ```

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     labels:
       app: web
       app.kubernetes.io/name: web
       app.kubernetes.io/part-of: cnpa-lab
       cnpa.io/managed-by: exercise-4
     name: prod-web
     namespace: cnpa-lab
   spec:
     ports:
     - name: http
       port: 80
       targetPort: http
     selector:
       app: web
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     labels:
       app: web
       app.kubernetes.io/name: web
       app.kubernetes.io/part-of: cnpa-lab
     name: prod-web
     namespace: cnpa-lab
   spec:
     replicas: 5
     selector:
       matchLabels:
         app: web
   ...
   ```

4. Diff the render against the cluster, then apply:

   ```bash
   kubectl diff -k kustomize/overlays/prod | head -20
   kubectl apply -k kustomize/overlays/prod
   ```

   ```
   service/prod-web created
   deployment.apps/prod-web created
   ```

5. Now break it on purpose. Change the base to include selectors in the common labels:

   ```bash
   sed -i 's/includeSelectors: false/includeSelectors: true/' kustomize/base/kustomization.yaml
   kubectl apply -k kustomize/overlays/prod
   ```

   ```
   service/prod-web configured
   The Deployment "prod-web" is invalid: spec.selector: Invalid value:
   v1.LabelSelector{MatchLabels:map[string]string{"app":"web", "app.kubernetes.io/name":"web",
   "app.kubernetes.io/part-of":"cnpa-lab"}, MatchExpressions:[]v1.LabelSelectorRequirement(nil)}:
   field is immutable
   ```

   Revert:

   ```bash
   sed -i 's/includeSelectors: true/includeSelectors: false/' kustomize/base/kustomization.yaml
   ```

> **Questions — block 6**
> **Q6.1** — Kustomize has no variables, no conditionals and no loops. Argue *for* that constraint from a platform-engineering standpoint, then name the concrete case where it forces you to reach for Helm or a CRD instead.
> **Q6.2** — Step 5 failed on the Deployment but the Service was already `configured`. Name the property `kubectl apply` does **not** have, and describe how that partial application can leave a system in an inconsistent state. What does a GitOps engine do about it?
> **Q6.3** — `kubectl kustomize` (render) and `kubectl apply -k` (render + apply) are separated. Explain why "render to a file, review the file, apply the file" is the correct CI shape, and what class of regression it catches that `kubectl diff` alone does not.
> **Q6.4** — `namePrefix: prod-` renamed the objects. If this overlay had been applied over an existing un-prefixed deployment, what would have happened to the old objects, and which mechanism from Exercise 4 do you need to clean them up?

---

## Exercise 7 — State-file IaC vs. control-plane IaC

### Steps

1. Build a minimal Terraform configuration that needs no cloud credentials:

   ```bash
   mkdir -p tf && cd tf
   cat > main.tf <<'EOF'
   terraform {
     required_version = ">= 1.6"
     required_providers {
       local = {
         source  = "hashicorp/local"
         version = "~> 2.5"
       }
     }
   }

   variable "log_level" {
     type    = string
     default = "info"
   }

   resource "local_file" "app_config" {
     filename        = "${path.module}/out/app.conf"
     file_permission = "0644"
     content         = <<-EOT
       log_level = ${var.log_level}
       replicas  = 2
     EOT
   }
   EOF

   terraform init -no-color | tail -3
   ```

   ```
   Terraform has been successfully initialized!
   ```

2. Plan — the declarative diff:

   ```bash
   terraform plan -no-color -out=tfplan | tail -12
   ```

   ```
   Terraform will perform the following actions:

     # local_file.app_config will be created
     + resource "local_file" "app_config" {
         + content              = <<-EOT
               log_level = info
               replicas  = 2
           EOT
         + filename             = "./out/app.conf"
         + id                   = (known after apply)
       }

   Plan: 1 to add, 0 to change, 0 to destroy.
   ```

3. Apply, then inspect where "desired state" is remembered:

   ```bash
   terraform apply -no-color tfplan | tail -2
   ls out/ && cat terraform.tfstate | jq '.resources[0].instances[0].attributes.filename'
   ```

   ```
   Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
   app.conf
   "./out/app.conf"
   ```

4. Introduce drift out-of-band, exactly as in Exercise 4:

   ```bash
   echo "log_level = debug" > out/app.conf
   terraform plan -no-color -detailed-exitcode | tail -8; echo "exit code: $?"
   ```

   ```
     # local_file.app_config must be replaced
   -/+ resource "local_file" "app_config" {
         ~ content = "log_level = debug\n" -> <<-EOT
               log_level = info
               replicas  = 2
           EOT
             # forces replacement
       }

   Plan: 1 to add, 0 to change, 1 to destroy.
   exit code: 2
   ```

5. Now the decisive experiment. Delete the state file and plan again:

   ```bash
   mv terraform.tfstate terraform.tfstate.bak
   terraform plan -no-color | tail -3
   ```

   ```
   Plan: 1 to add, 0 to change, 0 to destroy.
   ```

   Terraform believes the file does not exist — even though it does.

   ```bash
   mv terraform.tfstate.bak terraform.tfstate
   cd ..
   ```

6. Contrast: delete the "state" of a Kubernetes object and ask the cluster what it thinks.

   ```bash
   kubectl get deployment prod-web -o jsonpath='{.spec.replicas} desired / {.status.readyReplicas} ready{"\n"}'
   ```

   ```
   5 desired / 5 ready
   ```

   There is no state file to delete. The desired state *is* the object; the observed state *is* the status.

> **Questions — block 7**
> **Q7.1** — Terraform reconciles only when a human or a pipeline runs `terraform apply`; Kubernetes reconciles continuously. Express both as the same loop, and identify precisely which part is missing from the Terraform version.
> **Q7.2** — In step 5, deleting `terraform.tfstate` made Terraform hallucinate. Explain why Kubernetes has no equivalent failure mode, and what Kubernetes gives up in exchange.
> **Q7.3** — `terraform plan -detailed-exitcode` returned 2. Map Terraform's exit codes (0/1/2) onto `kubectl diff`'s (0/1/>1) and explain how each is consumed by CI.
> **Q7.4** — Terraform destroyed and recreated the file rather than editing it (`forces replacement`). Relate this to the immutable-field behaviour in Exercise 4 Step 3 and say which of the two systems makes the replacement decision explicit *before* acting.
> **Q7.5** — A platform team wants "Terraform semantics, continuously reconciled, expressed as Kubernetes APIs". Name the CNCF project that provides exactly that, and describe how a `Composition` + `CompositeResourceDefinition` maps onto the `DatabaseClaim` CRD + reconciler you built in Exercise 5.
> **Q7.6** — State-file IaC concentrates blast radius in one artifact (state lock, state corruption); control-plane IaC concentrates it in one API server. For each model, name the operational control that bounds the damage.

### Optional (7b) — Crossplane with `provider-nop`

Only if you have `helm` and outbound network. This installs a control plane for external resources and a provider that provisions nothing, so no cloud credentials are required.

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --wait

kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-nop
spec:
  package: xpkg.crossplane.io/crossplane-contrib/provider-nop:v0.4.0
EOF

kubectl get providers
```

Then inspect the installed API before using it — **do not assume the schema**:

```bash
kubectl api-resources --api-group=nop.crossplane.io
kubectl explain nopresources.spec.forProvider
```

Create a resource whose readiness is simulated after a delay, then observe that the *cluster*, not a pipeline, is what drives it to Ready:

```bash
kubectl apply -f - <<'EOF'
apiVersion: nop.crossplane.io/v1alpha1
kind: NopResource
metadata:
  name: fake-database
spec:
  forProvider:
    conditionAfter:
      - time: "0s"
        conditionType: Ready
        conditionStatus: "False"
      - time: "20s"
        conditionType: Ready
        conditionStatus: "True"
EOF

kubectl get nopresources -w
```

> **Q7.7** — `NopResource` has `spec.forProvider` (desired) and `status.atProvider` (observed). Explain why Crossplane splits the schema that way, and how it lets a controller detect drift in an external system it does not own.

---

## Cleanup

```bash
kind delete cluster --name cnpa-1-1
rm -rf ~/cnpa-1-1
```

---

## Reference sources

- CNCF, *CNPA Curriculum* — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes, *Declarative Management of Kubernetes Objects Using Configuration Files* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes, *Kubernetes Object Management* — https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- Kubernetes, *Server-Side Apply* — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes, *Controllers* — https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes, *Owners and Dependents* / *Garbage Collection* — https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/ and https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes, *Finalizers* — https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Kubernetes, *Extend the Kubernetes API with CustomResourceDefinitions* — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes, *Validation Rules (CEL)* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Operator pattern* — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Kubernetes, *Declarative Management with Kustomize* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kubernetes API Conventions (`spec`/`status`, conditions, `observedGeneration`) — https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
- OpenGitOps, *GitOps Principles v1.0.0* — https://opengitops.dev/
- Argo CD, *Resource Pruning and Sync Options* — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Flux, *Garbage collection* — https://fluxcd.io/flux/components/kustomize/kustomizations/#prune
- Crossplane, *Concepts: Managed Resources and Compositions* — https://docs.crossplane.io/latest/concepts/
- HashiCorp, *Terraform State* and *Command: plan* — https://developer.hashicorp.com/terraform/language/state and https://developer.hashicorp.com/terraform/cli/commands/plan

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 1A

**A1.1** — The three-way merge compares:
1. **Live object configuration** — the object as it currently exists in etcd, served by the API server.
2. **Local (new) object configuration** — the manifest on your disk, the file passed to `-f`.
3. **Last-applied configuration** — the previous manifest, stored in the cluster in the `kubectl.kubernetes.io/last-applied-configuration` annotation.

The merge computes: fields present in local but not in live → **set**; fields present in local and live with different values → **set to local**; fields present in last-applied but **absent from local** → **delete**; fields present in live but absent from both local and last-applied → **left alone** (they belong to someone else — a controller, a defaulter, a mutating webhook).

**A1.2** — At that moment `last-applied` did not exist, so `kubectl` fell back to a two-way merge between the local config and the live object: for every field the manifest specifies, the manifest wins. The manifest specified `replicas: 2`, so 2 was written. The warning exists precisely because the third input was missing — the "delete fields removed from the manifest" rule could not be evaluated, so this apply could not delete anything, and after the apply the annotation was populated so that future applies can.

**A1.3** — Operationally the warning means "this apply is running with degraded semantics, and the next one will behave differently". The dangerous class is any field that a *previous imperative operation* added and that your manifest does not mention: because the two-way merge cannot distinguish "I never managed this" from "I stopped managing this", ownership is ambiguous. The concrete production version of this: an object created with `kubectl create`, patched at 3 a.m. with `kubectl patch`, then adopted by `kubectl apply` from a pipeline — the pipeline silently becomes the owner of a subset of fields and the emergency patch survives invisibly until a later apply removes it.

### Block 1B

**A1.4** — The patch was:

```json
{"spec":{"replicas":null}}
```

`replicas` was present in `last-applied` (value 2, from step 5) and absent from the new manifest, so the merge rule "in last-applied, not in local → delete" fired. `null` in a strategic-merge patch means *delete the field*. Once deleted, the field is unset, and the API server's defaulting for `apps/v1 Deployment` sets `spec.replicas` to its default value of **1**. The live value of 6 was irrelevant — deletion is unconditional, it is not a comparison.

**A1.5** — Failure: the HPA scales the Deployment to, say, 40 replicas under load; the pipeline runs `kubectl apply`; `replicas` is deleted and defaults to 1; the service is instantly under-provisioned by 40×; the HPA then scales back up over its stabilization window (default 5 minutes down / immediate up, but it still needs metrics), leaving a real outage window. It repeats on every deploy.

Two correct fixes:
- **Manifest-level:** never put `replicas` in the manifest at all — if it was never in `last-applied`, it is never deleted, and the HPA is the sole owner. (If it *is* already in `last-applied`, you must remove it from the annotation too, or accept one deletion.) Argo CD expresses the same idea with `ignoreDifferences` on `/spec/replicas`; Flux with `spec.patches` or by excluding the field.
- **Mechanism-level:** use Server-Side Apply and do not claim the field. Under SSA, `spec.replicas` is owned by the HPA's field manager; your apply, which does not list `replicas`, neither sets nor deletes it, and if you *did* list it you would get an explicit conflict error instead of a silent scale-down. Explicit failure beats silent breakage.

**A1.6** —
- `kubectl scale` — **imperative command** (operates on a live object, arguments only, no file).
- `kubectl replace -f` — **imperative object configuration** (a file, but the operation is "replace this whole object now", it does not merge and it fails if the object does not exist).
- `kubectl apply -f` — **declarative object configuration**.
- `kubectl create -f` — **imperative object configuration**.
- `kubectl edit` — **imperative command** (an interactive read-modify-write; it produces an `Update`, not an `Apply`).

### Block 2A

**A2.1** — `k:{"name":"nginx"}` identifies **one element of an associative list** by its merge key. `spec.template.spec.containers` is declared in the Kubernetes API schema with `x-kubernetes-list-type: map` and `x-kubernetes-list-map-keys: ["name"]`, so the API server treats it as a map keyed by `name` rather than an ordered array. That is what lets two managers own two different containers in the same Pod template without conflicting, and what makes `f:image: {}` inside that key meaningful.

For an **atomic** list (`x-kubernetes-list-type: atomic`, e.g. `spec.template.spec.containers[*].args` or `command`), the entry is just `f:args: {}` — the whole list is one indivisible field with exactly one owner. You cannot own "the third argument"; you own the argument list or you do not.

**A2.2** — `Update` is a plain write (`PUT`/`PATCH` of the whole object or a merge patch) — the classic verb used by controllers and by `kubectl edit`/`kubectl scale`. `Apply` is the SSA verb (`PATCH` with `Content-Type: application/apply-patch+yaml`), where the client sends only the fields it intends to own.

The practical difference: an `Update` manager takes ownership of every field whose value it *changed*, and it can never remove ownership by omission (it always sends the full object). An `Apply` manager owns exactly the field set it declared, and omission means release-or-delete. `kube-controller-manager` shows up as `Update` because the Deployment controller writes `status` (and defaults) with a normal update, not with SSA.

### Block 2B

**A2.3** — The rule: **when a manager applies, any field it previously owned and no longer includes in its applied configuration is removed from its ownership set; if no other manager owns that field, the field is deleted from the object.** Ownership is per-manager; deletion happens only when the *last* owner drops it.

If `app-team` had also been applying `resources`, the field would have been co-owned. `platform-team` dropping it would only have removed `platform-team` from the owner list; the field would have kept `app-team`'s value and remained on the object.

**A2.4** — GitOps agent applies as `argocd-controller` and owns the spec fields. The SRE runs `kubectl edit`, which issues an **Update** under the manager name `kubectl-edit`. Because the SRE changed the value of a field that `argocd-controller` owns, `kubectl-edit` becomes a **co-owner** of that field (Update grabs ownership of what it changes) and the live value is now the SRE's. On the next sync, `argocd-controller` applies its configuration; SSA conflict detection sees another manager on the field. In practice Argo CD applies with `--force-conflicts` semantics on sync (its default is to force), so the field is reverted to Git and `kubectl-edit` is stripped from the owner set — the hotfix silently disappears, which is exactly what "Git is the source of truth" means.

If the SRE had used `kubectl apply --server-side --field-manager=sre-hotfix`, the first thing that happens is a **conflict error** at edit time, which is an explicit signal that this field belongs to the GitOps controller and the change must go through Git. That is the desired behaviour: fail loudly at the human, not silently at 3 a.m. two hours later.

**A2.5** — `--force-conflicts` is a statement that "this actor's configuration outranks every other actor's, unconditionally". That is a governance decision about who owns which fields on the platform, not an ergonomics choice. In a healthy platform, forcing is correct for the GitOps controller (Git is authoritative by definition) and wrong for almost everything else.

A scenario where the pipeline should **fail** on conflict: the pipeline applies a `Deployment` whose manifest still carries `spec.replicas`, while an HPA owns that field. Forcing the conflict overwrites the autoscaler's decision on every deploy. Failing the pipeline surfaces the real defect — `replicas` should not be in the manifest — instead of institutionalizing a periodic scale-down.

**A2.6** — The value stays **4**, and the sole owner becomes `platform-team`. Removing a field under SSA only removes *your* ownership; because another manager still owns it, the field is not deleted and its value is not changed. This is exactly the co-ownership mechanism described in the conflict error's third bullet.

### Block 3A

**A3.1** — The ReplicaSet controller runs a loop that continuously compares:
1. **Desired state** — `spec.replicas` on the ReplicaSet object (4).
2. **Observed state** — the number of Pods that match the ReplicaSet's `spec.selector`, are not terminating, and carry an `ownerReference` pointing to this ReplicaSet.

Observing 2 running Pods against a desired 4, it creates 2 new Pods (with generated names and the owner reference set), then writes what it observed into `status`. No delete event is required for this to work; the difference between the two numbers is sufficient. The scheduler then reconciles unscheduled Pods against nodes, and each node's kubelet reconciles the Pods assigned to it against the containers actually running.

**A3.2** — The **Deployment controller** reverted it. Its desired state is `spec.replicas` on the **Deployment** object (4); it reconciles by ensuring that the current ReplicaSet's `spec.replicas` matches (accounting for rollout strategy across old and new ReplicaSets). Your manual scale of the ReplicaSet became observed state that did not match, so it was corrected.

The full chain:

```
deploy-v1.yaml            (your intent, on disk / in Git)
   ↓ kubectl apply → API server → etcd
Deployment  spec.replicas=4
   ↓ deployment-controller
ReplicaSet  spec.replicas=4
   ↓ replicaset-controller
Pod × 4     (spec.nodeName empty)
   ↓ kube-scheduler
Pod × 4     (spec.nodeName=kind-worker)
   ↓ kubelet on that node
containers running via the CRI runtime
```

Each arrow is an independent controller with its own loop, reading desired state from the level above and writing observed state back into `status`. Nothing pushes commands down the chain.

**A3.3** — Deployment-managed Pods have **no stable identity**: names are generated, and a replacement Pod is a *different* Pod, not a restart of the old one — different name, different UID, different IP, fresh ephemeral storage. The desired state is "N Pods matching this template", not "these specific N Pods". That is what makes the workload safely fungible and horizontally scalable.

`StatefulSet` preserves identity: ordinal-indexed stable names (`web-0`, `web-1`), a stable network identity via the headless Service, and stable PersistentVolumeClaim binding across rescheduling. You choose it when identity is part of the desired state.

### Block 3B

**A3.4** — Yes, it was a perfectly **valid** state. The API server stores desired state; it makes no promise that observed state matches it at any given instant. `spec.replicas: 2` was the desired state, the observed state was zero Pods (and `status.readyReplicas` was absent, not `0`, because nothing had reported), and **reconciliation** — the process that closes that gap — was not running. The gap between desired and observed is normal and permanent in a distributed system; what a healthy platform guarantees is that the gap is *continuously being closed*, not that it is zero. This is also why an SLO on a platform is written against `status`, never against `spec`.

**A3.5** — The property is **level-triggered** reconciliation (as opposed to **edge-triggered**). A level-triggered controller acts on the *current value* of the world; an edge-triggered one acts on *transitions* (events). The consequences:

- A missed event is harmless: the next loop observes the level and converges anyway.
- Restart is free: the controller does not need a durable event log, replay, or exactly-once delivery. It resyncs — lists everything — and converges.
- Duplicate events are harmless, because the action is idempotent: "make it be 4", not "add one".
- Ordering is not required, so controllers can be sharded, upgraded, or run in HA with leader election without coordination protocols.

In real controllers the event stream (watch) is an **optimization** for latency, not the source of truth: `client-go` informers deliver events but hand the controller only an object *key*, and the controller then re-reads current state from its cache and reconciles the level. The periodic resync exists precisely so that a lost watch cannot cause permanent divergence.

**A3.6** — The **garbage collector** in `kube-controller-manager` performs cascading deletion, driven by `metadata.ownerReferences` on dependents.

- `--cascade=background` (the default): the owner is deleted immediately, and the GC deletes dependents asynchronously afterwards. Fast, but there is a window where orphaned dependents still exist.
- `--cascade=foreground`: the owner gets `foregroundDeletion` in `metadata.finalizers` and a `deletionTimestamp`, remains visible and un-deleted until every dependent with `blockOwnerDeletion: true` has been deleted, and only then is the owner removed. Slower, but you can wait on it — which is what you want in a pipeline that must not proceed until the children are actually gone.
- `--cascade=orphan`: the GC *removes the ownerReference* from every dependent, then deletes the owner. Dependents survive as unowned objects.

**A3.7** — If two Deployments in one namespace have selectors that both match a set of Pods, each Deployment's ReplicaSets count those Pods towards their own desired replicas. They will fight: one deletes Pods it considers surplus, the other creates replacements, forever. Symptoms are endless Pod churn, hot-looping controllers, and (in the adoption case) one Deployment's ReplicaSet adopting Pods created from a completely different container image — so a rollout appears to "succeed" while serving the wrong version. This is why `spec.selector` is immutable and why every generated manifest should carry a unique `app.kubernetes.io/instance` in its selector.

### Block 4A

**A4.1** —

```bash
kubectl diff -f deploy-v1.yaml > /tmp/drift.diff || \
  { echo "DRIFT DETECTED"; cat /tmp/drift.diff; exit 1; }
```

Exit code 1 is *by design* — `kubectl diff` documents 0 as "no differences" and 1 as "differences found"; any other non-zero value is a genuine failure (auth, connectivity, invalid manifest). Treating 1 as an error is the intended usage; the mistake would be treating 1 and 2 identically, which conflates "the cluster drifted" with "I could not reach the cluster" — two alerts that need very different responses.

**A4.2** — A text diff would flag as drift:
1. **Server-applied defaults and mutations** — `imagePullPolicy: IfNotPresent`, `terminationMessagePath`, `dnsPolicy`, `restartPolicy`, `schedulerName`, the default `ServiceAccount`, `securityContext` fields injected by a mutating webhook, `clusterIP` on a Service. These are in the live object and not in your file, but they are not drift: your file never claimed them.
2. **Server-managed metadata and status** — `metadata.uid`, `resourceVersion`, `generation`, `creationTimestamp`, `managedFields`, and the entire `status` block, which no manifest should ever set.

`kubectl diff` avoids both because it sends your manifest to the API server as a **dry-run apply** and diffs the *resulting* object against the live one — it compares two post-merge, post-defaulting objects, which is exactly the semantics of "what will change if I apply this".

### Block 4B

**A4.3** — Where a field is immutable, the platform must **replace** the object rather than update it: delete-and-recreate, or create a new object under a new name and cut traffic over. Declarative intent still describes the destination; what is not automatic is the *path*.

For a GitOps controller this means the sync strategy must include an explicit replace/recreate behaviour, and it must be opt-in per resource because it is destructive: Argo CD exposes `Replace=true` and `Force=true` sync options (and `ServerSideApply=true` for the merge semantics); Flux exposes `force: true` on a Kustomization to recreate immutable resources. The important discipline: **the tenant must know** that a change to an immutable field is a replacement with downtime implications, so the plan/diff must surface it *before* the sync — which is precisely what a `kubectl diff` in CI and a manual approval gate are for.

**A4.4** — Common ones:
1. **`Service.spec.clusterIP`** (and `spec.type` transitions in some directions) — remediation: delete and recreate the Service, accepting a new ClusterIP; or omit `clusterIP` from the manifest entirely so it is never claimed.
2. **`PersistentVolumeClaim.spec.resources.requests.storage` (shrink) and `spec.storageClassName`, `spec.accessModes`, `spec.volumeMode`** — growth is allowed if the StorageClass has `allowVolumeExpansion: true`; shrinking and class changes are not. Remediation: provision a new PVC and migrate data.
3. **`StatefulSet.spec` fields other than `replicas`, `template`, `updateStrategy`, `persistentVolumeClaimRetentionPolicy`, `minReadySeconds`** — notably `serviceName` and `volumeClaimTemplates`. Remediation: `kubectl delete sts --cascade=orphan` then recreate, so the Pods and PVCs survive the swap.
4. **`Job.spec.template`, `Job.spec.selector`** and most of `Job.spec` (only `parallelism`, `activeDeadlineSeconds`, `suspend`, and `ttlSecondsAfterFinished` are mutable) — remediation: generate a new Job name per run (a `CronJob`, or a name suffixed with the Git SHA).
5. **`CustomResourceDefinition.spec.group/names/scope`** — remediation: a new CRD and a migration of all custom objects.

### Block 4C

**A4.5** — `kubectl apply -f <dir>` computes the union of *what is in the directory* against *what is in the cluster* only for objects it can see in the directory; an object that is no longer in the directory is simply never visited, so nothing tells the API server to delete it. The problem is called **pruning** (or **garbage collection** / **resource tracking**) in GitOps tooling: the engine must maintain an inventory of "objects I created from this source" so it can compute the set difference on every sync.

- **Argo CD** tracks resources by an application-instance label or annotation (`app.kubernetes.io/instance` / `argocd.argoproj.io/tracking-id`, per the `application.instanceLabelKey` and `resourceTrackingMethod` settings) and deletes tracked resources missing from the desired manifests when `prune: true` is set in the sync policy — with `PruneLast`, `PrunePropagationPolicy` and `Prune=false` per-resource escape hatches.
- **Flux** writes an **inventory** into the `Kustomization` object's status, listing every applied object's GVK/namespace/name; on each reconcile it applies the new set, diffs against the stored inventory, and deletes the difference when `prune: true`.

**A4.6** — If a tenant labels an unrelated resource with `cnpa.io/managed-by=exercise-4`, the very next `kubectl apply --prune -l cnpa.io/managed-by=exercise-4` will see an object that carries the selector but is absent from the manifest set — and **delete it**. Label-based pruning delegates deletion authority to whoever can write labels, which in a shared namespace is everyone. It is also vulnerable to the inverse failure: if the apply set is accidentally empty (a bad `kustomize build`, a wrong path in CI), pruning deletes *everything* carrying the label.

**ApplySet** (KEP-3659, `--applyset`) mitigates this by anchoring the inventory to a **parent object** (a Secret, ConfigMap or dedicated custom resource) that records the exact GroupKinds and namespaces in scope, with `applyset.kubernetes.io/id` hashed from the parent's identity. Membership is asserted by the tooling against that parent rather than inferred from a free-form label, the scope of the sweep is bounded to declared GKs/namespaces, and RBAC on the parent object controls who can change the inventory.

### Block 5A

**A5.1** — Not broken — **not yet reconciled**. The empty `PHASE` proves that a CRD gives you an API (storage, validation, defaulting, RBAC, watch, `kubectl` integration) and **nothing else**. An API without a controller is a well-typed wish list: the user's intent is durably recorded and syntactically guaranteed, but no state in the world corresponds to it. This is the single most important distinction in the domain: *the CRD is the contract; the controller is the implementation.* It is also why an empty `status` is the correct initial state — status must only ever be written by the controller that observed something, never by the user and never by a default.

**A5.2** — Because defaults are applied at admission and **persisted into `spec`**, existing objects keep the old value forever — they are not re-defaulted. Changing `default: 20` to `default: 50` changes the behaviour of *new* objects only, producing a fleet where identical-looking manifests yield different results depending on when they were first applied. Worse, a tenant who reads back `spec.sizeGi: 20` cannot tell whether they asked for 20 or inherited it, so "reset to platform default" is not expressible. Mitigations: version the API and use a conversion webhook, or treat the default as policy (validate/mutate at admission and record its provenance in an annotation) rather than as a schema default.

**A5.3** — Advantages of CEL (`x-kubernetes-validations`) over a validating admission webhook:
1. **No availability dependency** — the rule is evaluated in-process by the API server. A webhook is a network hop to a Deployment that can be down, slow, or unreachable, and with `failurePolicy: Fail` an outage of your webhook blocks writes to the resources it guards; with `failurePolicy: Ignore` it silently stops enforcing. CEL has neither failure mode.
2. **No operational surface** — no certificate rotation, no CA bundle injection, no separate deployment/rollout, no latency budget, no `timeoutSeconds` tuning; the rule ships with the CRD as one atomic artifact and is versioned with it. Also: the rule is visible in the published OpenAPI schema, so clients can see it.

What the webhook can do that CEL cannot: **consult state outside the object under review** — query other objects, an external quota service, an IPAM, or a licensing system; enforce cross-object uniqueness; and mutate (CEL validation cannot set values, though `MutatingAdmissionPolicy` addresses part of this in newer releases). CEL rules are pure functions of the object (plus `oldSelf` for transition rules), by design.

**A5.4** — The status subresource splits the object into two endpoints with independent write paths (`/apis/.../databaseclaims/x` and `/apis/.../databaseclaims/x/status`). It matters because:
- **RBAC separation** — tenants can be granted write on the resource and *not* on `databaseclaims/status`, so no one can forge "Ready". The controller gets the inverse.
- **No lost updates / no hot loops** — a status write does not touch `spec`, so a controller writing status cannot clobber a concurrent user edit to `spec`, and vice versa.
- **`metadata.generation` semantics** — with a status subresource, `generation` is incremented **only when `spec` changes**, never when `status` changes. That is what makes the `status.observedGeneration == metadata.generation` idiom meaningful.

Without it, `reconcile.sh` would have to read-modify-write the whole object to set status, racing with users, and every status write would bump `generation`, so the controller's own writes would look like new user intent — a self-sustaining reconcile loop.

### Block 5B

**A5.5** — Polling the full list gives **eventual convergence regardless of missed or duplicated notifications**: correctness depends only on the current state of the world, never on having seen a transition. An event subscription gives lower latency but no such guarantee — a dropped connection, a compacted watch window (`410 Gone` / `resourceVersion` too old), a crash between event and action, or a controller that was simply not running all mean the edge is lost forever.

Real controllers (`controller-runtime` / `client-go`) get both: an **informer** maintains a local cache seeded by a LIST and kept current by a WATCH; events are enqueued as **object keys** into a rate-limited workqueue, and `Reconcile(ctx, req)` then re-reads the object from the cache and reconciles current state — it is never handed the event payload or a delta. The same guarantee is preserved by (a) relisting from scratch whenever the watch breaks, (b) a periodic **resync** that replays every cached key through the queue, and (c) requeueing on error with backoff. The event stream is a latency optimization layered over a level-triggered core.

**A5.6** — The **garbage collector controller** in `kube-controller-manager`, driven by `metadata.ownerReferences` on the ConfigMap — specifically the entry pointing at the `DatabaseClaim` by `uid`. When the owner's UID no longer resolves to a live object, the dependent is deleted. `controller: true` marks this as the managing owner; `blockOwnerDeletion: true` makes foreground deletion of the claim wait for this ConfigMap. Note the `uid` is what matters, not the name: a claim deleted and recreated with the same name has a new UID, so the stale dependent is correctly collected rather than adopted.

**A5.7** —

```bash
kubectl get dbc -o json | jq '.items[] | select(.status.observedGeneration != .metadata.generation) | .metadata.name'
```

or, per object, the condition `status.observedGeneration < metadata.generation` → *the controller has not yet processed the user's latest spec change*. (Absent `observedGeneration` means never reconciled.)

`metadata.resourceVersion` is wrong because it is an **opaque, non-comparable** value that changes on *every* write to the object — including the controller's own status writes, label edits, annotation churn from other tools, and even relocations within storage. It carries no ordering semantics you are allowed to rely on, and it would never converge, since acknowledging it changes it. `generation` is incremented **only on `spec` changes** (thanks to the status subresource) and is monotonic, which is exactly the semantics needed for "have you caught up with what I asked for".

**A5.8** — Two reasons:
1. **Idempotent convergence, not creation.** `kubectl create` fails with `AlreadyExists` on the second pass, so the controller would need create-then-fallback-to-update logic and would still race with other writers. `apply` expresses "make this be true", which is the only verb whose semantics match a reconcile loop that runs every 5 seconds forever.
2. **Explicit, attributable field ownership.** With a named field manager, `metadata.managedFields` records exactly which fields this controller asserts. It can therefore *correct drift on the fields it owns* (someone edits `data.host` → next reconcile restores it) while leaving fields it does not own untouched (a mesh injector's annotations, a tenant's extra label survive). It also makes SSA conflicts visible if a second actor tries to own the same field, and it removes fields the controller stops managing — the state machine of ownership is maintained by the API server rather than reimplemented in the controller.

**A5.9** — A single `phase` string is a **state machine the API owner must define exhaustively and in advance**, and it collapses independent concerns into one dimension. A database can simultaneously be provisioned-but-not-backed-up, reachable-but-degraded, or healthy-but-pending-upgrade; one string cannot express that without a combinatorial explosion of phase names, and adding a phase value is a breaking change for every client doing string equality.

The `conditions` convention (`type`, `status: True|False|Unknown`, `reason`, `message`, `lastTransitionTime`, `observedGeneration`) is **extensible and orthogonal**: new condition types can be added without breaking clients, each condition is an independent observation, and `Unknown` is a first-class value that distinguishes "not healthy" from "haven't looked yet" — a distinction a phase string cannot make and one that matters enormously during a controller outage.

What clients gain: `kubectl wait --for=condition=Ready` works generically; alerting can key on `reason` (machine-readable) while humans read `message`; `lastTransitionTime` gives flap detection and time-in-state SLIs for free; per-condition `observedGeneration` tells you *which* spec version each observation refers to; and a fleet query can ask "everything where `Ready=False` and `reason != Provisioning`" without enumerating phases.

### Block 5C

**A5.10** — Nothing hung on the server. The `DELETE` request **succeeded immediately**: the API server saw a non-empty `metadata.finalizers`, so instead of removing the object from etcd it set `metadata.deletionTimestamp` and returned. What timed out was `kubectl`'s client-side wait for the object to actually disappear.

The object is in **terminating** (or *deletion-pending*) state. In that state it is still readable and still served, but it is effectively read-only for practical purposes: the API server rejects attempts to add new finalizers, and the object will be reaped by the API server the instant the finalizer list becomes empty. `deletionTimestamp` is the signal to every controller that owns a finalizer: "do your cleanup, then remove your finalizer". Deletion is therefore itself a reconciliation, with `deletionTimestamp != null` as the desired state.

**A5.11** — The incident: all 40 claims are stuck in terminating forever. Nothing removes the finalizers, so the objects are never reaped. Second-order effects: `kubectl delete namespace` on any namespace containing one of them hangs indefinitely with the namespace in `Terminating` (the namespace controller cannot finish while any object still has finalizers), which then blocks all namespace-scoped cleanup, blocks CI environments that delete/recreate namespaces, and eventually blocks cluster teardown.

Two remediation paths:
1. **Safe:** reinstall the controller. It observes the `deletionTimestamp`, runs its deprovision logic for real, and removes its own finalizer. The external resources are actually released.
2. **Unsafe:** force-remove the finalizers (`kubectl patch ... -p '{"metadata":{"finalizers":null}}'`). The Kubernetes objects vanish instantly, which *looks* like success — but the external side effects the finalizer existed to clean up are **never performed**. You have just orphaned 40 databases (or volumes, or DNS records, or cloud load balancers) with no remaining record of them in the cluster: they keep billing, keep holding IP/quota, and there is no longer any object to reconcile them from. Only do this once you have independently confirmed the external resources are gone, or accepted a documented manual cleanup.

**A5.12** — Because the controller can crash, be evicted, lose leader election, or have its status/finalizer write rejected on a conflict **after** the cleanup has already run but **before** the finalizer removal is persisted. On the next reconcile it will see `deletionTimestamp` set and its finalizer still present, and it will run the cleanup again.

Concrete sequence:
1. `t0` — controller sees `deletionTimestamp`, calls the storage API: `DeleteVolume(vol-123)` → succeeds.
2. `t0+50ms` — controller issues the patch removing its finalizer; the API server returns `409 Conflict` (another manager updated the object) — or the Pod is OOM-killed right here.
3. `t0+5s` — new leader/restarted controller reconciles: `deletionTimestamp` set, finalizer present → calls `DeleteVolume(vol-123)` again.

If `DeleteVolume` is not idempotent, step 3 returns `NotFound` and a naïve implementation treats it as a fatal error, never removes the finalizer, and wedges the object permanently — or worse, the ID has since been recycled and it deletes someone else's volume. Correct implementations treat "already gone" as success, key deletes on immutable identifiers recorded in `status`, and only then remove the finalizer.

### Block 6

**A6.1** — In favour of the constraint: what Kustomize consumes and emits is always **valid, parseable Kubernetes YAML**, never a text template that only becomes YAML after rendering. Every input can be linted, schema-validated, policy-checked (OPA/Kyverno), and diffed by ordinary tools *before* rendering; the base is a working deployment on its own; and the transformations are structural (they address `/spec/template/spec/...` by path, not by line number), so a change to the base cannot silently break an overlay's string interpolation. Crucially, the absence of conditionals means there is no hidden control flow: reading a base plus an overlay tells you the whole story, whereas a heavily-conditioned Helm chart requires you to *execute* it to know what it does. For a platform team maintaining golden paths for many tenants, "auditable and inert" beats "expressive".

Where it forces you elsewhere: when the *set* or *shape* of resources depends on input — "if `redis.enabled` create these five objects", "loop over N environments", "compute a value from another value" — Kustomize has no answer, and duplicating an overlay per combination scales combinatorially. That is the boundary. Helm answers it with templating (accepting the loss of pre-render validity); a **CRD + controller** answers it properly, by moving the logic from build time into a reconciled API where the abstraction is a first-class object with a schema, validation and status — exactly the `DatabaseClaim` shape from Exercise 5. Rule of thumb: build-time variation → Helm; run-time variation that must be *maintained* → a controller.

**A6.2** — `kubectl apply` is **not atomic and not transactional**. Each object is a separate API call; there is no all-or-nothing boundary, no rollback of the calls that already succeeded, and (with `-f dir/` or `-k`) not even a guaranteed ordering beyond kubectl's internal sort. The Service was already reconfigured when the Deployment was rejected, so the cluster now holds a state that exists in no version of your source: half-new, half-old. Concretely here, if the Service's selector had also changed, it could be selecting Pods that the Deployment was never allowed to create — a total outage produced by a *partially* applied change.

What GitOps engines do:
- **Detect and report, not pretend** — the Application/Kustomization goes to a failed/degraded state with the exact API error, rather than reporting success because "most objects applied".
- **Dry-run the whole set first** — Argo CD and Flux both run a server-side dry-run/validation pass over every object before committing any of them, which catches immutability and schema errors before the first real write.
- **Order deliberately** — sync waves / phases and health gates, so dependencies land in a defined sequence rather than an arbitrary one.
- **Retry with backoff and converge** — since the desired state is still in Git, the next reconcile re-attempts the failed objects; the partial state is transient rather than terminal (provided the error is transient, which an immutable-field error is not — that one needs `Replace`/`force`, or a human).
- **Roll back** — revert the commit; the engine converges the cluster back. Note this is *convergence*, not an undo log: it works only because desired state is declarative.

**A6.3** — Separating render from apply gives you an artifact you can **inspect, store, sign, policy-check and reason about** before anything mutable happens. The correct CI shape is: `kubectl kustomize overlays/prod > rendered.yaml` → run schema validation (`kubeconform`), policy (`conftest`/Kyverno CLI), and a human-readable review of `rendered.yaml` in the PR diff → then apply exactly that artifact. The rendered manifest is also the audit record of what was deployed, independent of whether the Kustomize version in CI matches the one on your laptop.

What it catches that `kubectl diff` does not: `kubectl diff` shows the delta *against the current cluster*, so it is blind to anything the cluster already has wrong, and it needs a live cluster with credentials (so it cannot run on an untrusted PR). Rendering catches **build-time regressions**: a patch whose `target` no longer matches any resource and silently does nothing, a `namePrefix` change that would orphan objects, an accidentally-removed resource from `resources:`, a base bump that changes the render for every one of twenty overlays. Reviewing the rendered diff between two commits is the only way to see the true blast radius of a base change — and none of it requires cluster access.

**A6.4** — `namePrefix: prod-` produces objects named `prod-web`, which are **different objects** from `web`. Applying the overlay would create the prefixed pair and leave the originals running, untouched — you would silently double your capacity and have two Services, with the old one still receiving traffic from whatever points at it. The apply reports nothing wrong, because from its point of view it created exactly what it was asked to create.

Cleaning up requires the mechanism from Exercise 4 Step 6: **pruning** — a tracked inventory (ApplySet, or Argo CD's tracking label, or Flux's inventory) that knows `web` was previously part of this application's desired set and is no longer, and therefore deletes it. Without an inventory, the only options are a manual `kubectl delete` or a label-selector prune, with the blast-radius caveats from A4.6. This is the general lesson: **any change to an object's identity — name, namespace, or GVK — is a create-plus-delete, not an update**, and the delete half only happens if something is tracking ownership.

### Block 7

**A7.1** — Both are the same loop:

```
observe (read current state) → diff (compare against desired) → act (converge) → repeat
```

- **Terraform:** *observe* = refresh (read the real resources named in the state file); *diff* = `plan`; *act* = `apply`. Desired state is the `.tf` files, observed state is the refreshed state file.
- **Kubernetes:** *observe* = list/watch via the informer cache; *diff* = the controller's comparison of `spec` to reality; *act* = create/update/delete calls.

What is missing from Terraform is **`repeat`** — the loop has no autonomous driver. It executes when a human or a pipeline invokes it, and between invocations no one is watching. Terraform is a *declarative description executed imperatively, on demand*; Kubernetes is a *declarative description executed continuously, by resident controllers*. Everything else about the two follows from that one difference: drift persists in Terraform until the next run, and self-healing is not a property Terraform can have, only a property a scheduler wrapped around Terraform can approximate.

**A7.2** — Terraform's state file is a **separate, authoritative record of the mapping between configuration and real-world objects** — it holds resource IDs that generally cannot be recovered from the config alone. Lose it and Terraform loses the identity of everything it manages: it plans to *create* resources that already exist (name collisions, duplicate infrastructure, or an apply that fails halfway), and it can no longer destroy what it provisioned. Recovery means `terraform import` for every resource, by hand.

Kubernetes has no equivalent because **the cluster is the state**: desired state lives in `spec` on the object, observed state in `status`, and identity in `metadata.uid` — all in the same store, written through the same API, subject to the same RBAC and audit log. There is no second artifact to lose, no lock to break, no drift between the record and the thing recorded.

What is given up in exchange:
- **No plan.** There is no first-class "show me everything that will change across this whole change set, then let me approve it". `kubectl diff` approximates it per-object, but there is no dependency-ordered, cluster-wide preview, and no `-target`.
- **No dependency graph or ordering.** Terraform derives a DAG from references and acts in order; Kubernetes controllers converge independently and eventually, which means transient invalid intermediate states are normal.
- **A single point of authority.** Availability and integrity of the whole platform's desired state now depend on the API server and etcd, and everything must be modelled as a Kubernetes object to participate.
- **No history of intent.** etcd holds the current object, not why or when it changed (compaction discards old revisions) — which is exactly the gap Git-as-source-of-truth exists to fill.

**A7.3** —

| | Terraform (`plan -detailed-exitcode`) | `kubectl diff` |
|---|---|---|
| 0 | no changes needed | no differences |
| 1 | error (config invalid, provider failure, auth) | **differences found** |
| 2 | **changes present** | error (>1: connectivity, invalid manifest, auth) |

The codes are ordered differently, which is a classic CI bug: a pipeline that copies a Terraform idiom onto `kubectl diff` treats "drift found" as "everything is fine" and vice versa. Note also that Terraform's *plain* `plan` returns 0 whether or not there are changes — `-detailed-exitcode` is required to distinguish them at all.

Consumption in CI: on a pull request, run the diff/plan and **fail the check if changes are present but unapproved**, posting the diff as a comment — this is the review gate. On the main branch after merge, run it as a **drift alarm** on a schedule: changes present means someone modified infrastructure out of band. In both cases the error code must page a human differently from the change code, because "the plan shows a change" is information while "I could not reach the provider" is an outage of your control loop.

**A7.4** — Both are the same phenomenon: a field whose value cannot be changed on a live object, so satisfying the new desired state requires **destroying and recreating** the object. Terraform annotates it explicitly in the plan (`# forces replacement`, `-/+ resource ... must be replaced`, with `Plan: 1 to add, 0 to change, 1 to destroy`) *before* touching anything, and refuses to proceed until you approve — and `create_before_destroy` / `prevent_destroy` let you encode policy about it.

Kubernetes makes the replacement decision **explicit only by refusing**: the API server rejects the update with `field is immutable` and does nothing. That is safe — nothing was destroyed — but it is a *failure at apply time*, not a *plan before apply time*, and it arrives after other objects in the same apply may already have been changed (see A6.2). `kubectl diff` will show the field changing but will not tell you it requires a replacement.

So Terraform makes replacement explicit and planned; Kubernetes makes it explicit and *blocked*, delegating the recreate decision to the operator or to a GitOps engine's `Replace`/`force` option. The practical consequence for a platform team: the "will this deploy require downtime?" question is answerable from a Terraform plan and is **not** answerable from a Kubernetes diff — you need policy checks (or a controller) that know which fields are immutable.

**A7.5** — **Crossplane** (CNCF incubating). It runs provider controllers inside the cluster that continuously reconcile external cloud resources against Kubernetes objects, so infrastructure gets the level-triggered, self-healing, RBAC-governed, no-state-file model of Exercise 3 rather than the run-on-demand model of Exercise 7.

The mapping onto what you built:

| Exercise 5 | Crossplane | Role |
|---|---|---|
| `DatabaseClaim` CRD (schema, defaults, CEL rules, printer columns) | **`CompositeResourceDefinition` (XRD)** — generates the `XDatabase` (cluster-scoped composite) and `Database` (namespaced claim) CRDs | The tenant-facing API contract: the only vocabulary the tenant needs |
| `reconcile.sh` — the loop that turns a claim into concrete objects | **`Composition`** (plus the Crossplane engine and function pipeline) — declares which **managed resources** a composite expands into, and how fields are patched from claim to resource | The platform's opinion about *how* the intent is fulfilled |
| the `ConfigMap` with `ownerReferences` | **Managed resources** (`RDSInstance`, `SubnetGroup`, …) owned by the composite, plus the published connection `Secret` | The concrete, individually-reconciled things |
| `status.phase` / `observedGeneration` | `status.conditions` (`Ready`, `Synced`) on both claim and composite | Observed state reported back |
| GC via `ownerReferences` | the same GC, plus deletion policies and finalizers on managed resources | Cleanup |

The essential insight is identical in both: **the tenant declares intent against a narrow API; the platform team owns the implementation behind it and can change that implementation without changing the tenant's manifest.** Crossplane's contribution is that the "implementation" is itself declarative and reconciled, and reaches outside the cluster.

**A7.6** —
- **State-file IaC:** remote state backend with **locking** (DynamoDB/GCS/Consul/Terraform Cloud) so two applies cannot interleave; **versioned and encrypted** state storage with point-in-time recovery so corruption is recoverable; **state splitting** — many small state files per environment/component rather than one monolith, so the blast radius of a corrupt or locked state is one component, not the estate; `-target` and `prevent_destroy` as narrow escape hatches; and least-privilege credentials per state so a compromised pipeline cannot reach beyond its own component.
- **Control-plane IaC:** **RBAC** as the primary bound — namespaced claims, tenants able to write `DatabaseClaim` but not `RDSInstance`, and no write access to `/status`; **admission policy** (Kyverno/OPA/ValidatingAdmissionPolicy) and **ResourceQuota** to cap what any tenant can request; **etcd backups plus a Git source of truth** so the desired state is reconstructible independently of the cluster; **separate control-plane clusters per blast-radius domain** (a management cluster per environment) so one API server outage is not global; and **deletion policies / `prevent_destroy` equivalents** (`deletionPolicy: Orphan`, foreground deletion, finalizers) so a `kubectl delete` on a claim cannot silently drop a production database.

In both models the underlying control is the same: bound the scope of any single artifact of authority, and make destructive operations require an explicit, auditable act.

**A7.7** — The split mirrors the universal Kubernetes `spec`/`status` contract, applied across an ownership boundary that Kubernetes does not control:

- **`spec.forProvider`** is the **desired state as expressed by the user** — only the fields the platform intends to manage in the external system.
- **`status.atProvider`** is the **observed state as last read from the external system** — the full set of fields the provider's API returned, including everything the external system computed, defaulted or mutated on its own (generated IDs, endpoints, assigned CIDRs, current maintenance window).

Keeping them apart is what makes drift detection possible in a system you do not own. The provider controller periodically **observes** the external resource, projects the result into `status.atProvider`, and diffs it against `spec.forProvider`. Any field the user declared whose external value no longer matches is drift, and the controller issues an update to correct it — continuously, without anyone running a command. Fields present only in `atProvider` are explicitly *not* the user's business and are never "corrected", which is the external-system equivalent of the ownership rule from Exercise 2: **you only reconcile what you claimed.** If both lived in one struct, the controller could not tell "the user wants this" from "the cloud told me this", and every provider-side default would look like drift.

</details>