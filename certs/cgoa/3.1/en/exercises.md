# CGOA — Domain 3.1: GitOps Tooling & Implementation
## Guided Exercises (25% of the exam)

> **Scope.** These exercises exercise the *implementation* half of GitOps: the reconcilers (Flux CD, Argo CD), the manifest renderers they drive (Kustomize, Helm), the supply-chain surfaces around them (OCI artifacts, image automation, encrypted secrets), and progressive delivery. Every step is meant to be typed into a real cluster. Expected outputs are shown so you can diff your reality against the reference.
>
> **How to work through this.** Do the blocks in order — later exercises depend on earlier state. After each block there are comprehension questions; answer them *before* reading the collapsible answer section at the bottom. The questions target the reasoning the exam probes, not command memorization.

---

## Exercise 0 — Lab environment

**Objective:** a disposable cluster, a Git remote, and both reconcilers' CLIs.

### Steps

1. Create a local cluster. Any conformant Kubernetes ≥ 1.30 works; `kind` is used here because node images are pinned and reproducible.

   ```bash
   kind create cluster --name gitops --image kindest/node:v1.33.1
   ```

   ```
   Creating cluster "gitops" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
   Set kubectl context to "kind-gitops"
   ```

2. Verify the context and the API surface you will be reconciling into.

   ```bash
   kubectl config current-context
   kubectl get nodes -o wide
   ```

   ```
   kind-gitops
   NAME                   STATUS   ROLES           AGE   VERSION
   gitops-control-plane   Ready    control-plane   62s   v1.33.1
   ```

3. Install the Flux CLI and check the cluster is a valid target *before* installing anything.

   ```bash
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux --version
   flux check --pre
   ```

   ```
   flux version 2.6.4
   ► checking prerequisites
   ✔ Kubernetes 1.33.1 >=1.30.0-0
   ✔ prerequisites checks passed
   ```

4. Install the Argo CD CLI (you will use it in Exercise 4 onward).

   ```bash
   curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
   argocd version --client --short
   ```

   ```
   argocd: v3.1.0+e8c5f2a
   ```

5. Create an empty Git repository named `gitops-cgoa` on your Git provider and export credentials. A classic PAT with `repo` scope (or a fine-grained token with *Contents: read & write* and *Administration: read & write*) is required, because bootstrap creates a deploy key.

   ```bash
   export GITHUB_USER="<your-user>"
   export GITHUB_TOKEN="<your-pat>"
   ```

### Comprehension check — Block 0

- **Q0.1** `flux check --pre` passed, but it inspected *nothing* about your Git repository. What class of failure does it therefore not protect you from, and which command covers that gap after bootstrap?
- **Q0.2** You will run two reconcilers in one cluster. Name the concrete failure mode if both are configured to manage the same `Deployment`, and describe what you would observe in the object.
- **Q0.3** Why is pinning `kindest/node:v1.33.1` (rather than `:latest`) itself a GitOps-consistent choice, even though the cluster is disposable?

---

## Exercise 1 — Bootstrap Flux: the reconciler manages its own installation

**Objective:** understand that `flux bootstrap` is not "an installer" — it is the act of making the controllers a reconciled workload described in Git.

### Steps

1. Bootstrap Flux, requesting the two optional image-automation controllers you will need in Exercise 8.

   ```bash
   flux bootstrap github \
     --owner="${GITHUB_USER}" \
     --repository=gitops-cgoa \
     --branch=main \
     --path=clusters/dev \
     --personal \
     --components-extra=image-reflector-controller,image-automation-controller
   ```

   ```
   ► connecting to github.com
   ► cloning branch "main" from Git repository "https://github.com/<user>/gitops-cgoa.git"
   ✔ cloned repository
   ► generating component manifests
   ✔ generated component manifests
   ✔ committed component manifests to "main" ("6b1f0c9")
   ► pushing component manifests to "https://github.com/<user>/gitops-cgoa.git"
   ► installing components in "flux-system" namespace
   ✔ installed components
   ✔ reconcilers are healthy!
   ► determining if source secret "flux-system/flux-system" exists
   ► generating source secret
   ✔ configured deploy key "flux-system-main-flux-system-./clusters/dev"
   ► applying source secret "flux-system/flux-system"
   ✔ reconciled source secret
   ► generating sync manifests
   ✔ committed sync manifests to "main" ("a3d47e1")
   ► pushing sync manifests to "https://github.com/<user>/gitops-cgoa.git"
   ► applying sync manifests
   ✔ reconciled sync configuration
   ► waiting for Kustomization "flux-system/flux-system" to be reconciled
   ✔ Kustomization reconciled successfully
   ► confirming components are healthy
   ✔ all components are healthy
   ```

2. Inspect what bootstrap wrote to Git.

   ```bash
   git clone https://github.com/${GITHUB_USER}/gitops-cgoa.git
   cd gitops-cgoa
   find clusters/dev -type f | sort
   ```

   ```
   clusters/dev/flux-system/gotk-components.yaml
   clusters/dev/flux-system/gotk-sync.yaml
   clusters/dev/flux-system/kustomization.yaml
   ```

3. Read the sync manifest — this is the root of the whole reconciliation tree.

   ```bash
   cat clusters/dev/flux-system/gotk-sync.yaml
   ```

   ```yaml
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: flux-system
     namespace: flux-system
   spec:
     interval: 1m0s
     ref:
       branch: main
     secretRef:
       name: flux-system
     url: ssh://git@github.com/<user>/gitops-cgoa.git
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: flux-system
     namespace: flux-system
   spec:
     interval: 10m0s
     path: ./clusters/dev
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   ```

4. Observe the controller set and the two reconciliation loops separately.

   ```bash
   kubectl -n flux-system get deploy
   flux get sources git
   flux get kustomizations
   ```

   ```
   NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
   helm-controller               1/1     1            1           3m
   image-automation-controller   1/1     1            1           3m
   image-reflector-controller    1/1     1            1           3m
   kustomize-controller          1/1     1            1           3m
   notification-controller       1/1     1            1           3m
   source-controller             1/1     1            1           3m

   NAME         REVISION            SUSPENDED  READY  MESSAGE
   flux-system  main@sha1:a3d47e1   False      True   stored artifact for revision 'main@sha1:a3d47e1'

   NAME         REVISION            SUSPENDED  READY  MESSAGE
   flux-system  main@sha1:a3d47e1   False      True   Applied revision: main@sha1:a3d47e1
   ```

5. Prove that the installation is now *reconciled*, not merely *installed*: delete a controller and let Flux restore it.

   ```bash
   kubectl -n flux-system delete deploy notification-controller
   flux reconcile kustomization flux-system --with-source
   kubectl -n flux-system get deploy notification-controller
   ```

   ```
   deployment.apps "notification-controller" deleted
   ► annotating GitRepository flux-system in flux-system namespace
   ✔ GitRepository annotated
   ◎ waiting for GitRepository reconciliation
   ✔ fetched revision main@sha1:a3d47e1
   ► annotating Kustomization flux-system in flux-system namespace
   ✔ Kustomization annotated
   ◎ waiting for Kustomization reconciliation
   ✔ applied revision main@sha1:a3d47e1

   NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
   notification-controller   1/1     1            1           9s
   ```

### Comprehension check — Block 1

- **Q1.1** `GitRepository.spec.interval` is `1m` and `Kustomization.spec.interval` is `10m`. Trace what each timer actually does, and state the worst-case latency between a `git push` and the change landing in the cluster with these values.
- **Q1.2** In step 5 you ran `flux reconcile ... --with-source`. What is different about the *source* fetch when you omit that flag, and why would omitting it have still worked in this particular case?
- **Q1.3** The `Kustomization` at the root has `prune: true`. Explain precisely how the controller decides an object is prunable — what is it comparing, and where is the record kept?
- **Q1.4** Bootstrap wrote `gotk-components.yaml` into the same path the root `Kustomization` reconciles. What operational property does that self-reference buy you, and what is the one upgrade step that this does **not** make automatic?

---

## Exercise 2 — Deploy an application with Flux + Kustomize overlays

**Objective:** separate *source* from *rendering* from *environment configuration*.

### Steps

1. Create a base for a sample application. From the repo root:

   ```bash
   mkdir -p apps/base/podinfo apps/dev
   ```

2. Write the base manifests.

   ```bash
   cat > apps/base/podinfo/deployment.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: podinfo
     labels:
       app.kubernetes.io/name: podinfo
   spec:
     replicas: 1
     selector:
       matchLabels:
         app.kubernetes.io/name: podinfo
     template:
       metadata:
         labels:
           app.kubernetes.io/name: podinfo
       spec:
         securityContext:
           runAsNonRoot: true
           seccompProfile:
             type: RuntimeDefault
         containers:
           - name: podinfo
             image: ghcr.io/stefanprodan/podinfo:6.7.0
             imagePullPolicy: IfNotPresent
             ports:
               - name: http
                 containerPort: 9898
             readinessProbe:
               httpGet:
                 path: /readyz
                 port: http
               initialDelaySeconds: 3
             livenessProbe:
               httpGet:
                 path: /healthz
                 port: http
               initialDelaySeconds: 5
             securityContext:
               allowPrivilegeEscalation: false
               capabilities:
                 drop: ["ALL"]
               readOnlyRootFilesystem: true
             resources:
               requests:
                 cpu: 10m
                 memory: 32Mi
               limits:
                 memory: 128Mi
   EOF

   cat > apps/base/podinfo/service.yaml <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: podinfo
     labels:
       app.kubernetes.io/name: podinfo
   spec:
     type: ClusterIP
     selector:
       app.kubernetes.io/name: podinfo
     ports:
       - name: http
         port: 9898
         targetPort: http
   EOF

   cat > apps/base/podinfo/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   EOF
   ```

3. Write the `dev` overlay — a namespace, a replica patch, and a common label.

   ```bash
   cat > apps/dev/namespace.yaml <<'EOF'
   apiVersion: v1
   kind: Namespace
   metadata:
     name: podinfo-dev
   EOF

   cat > apps/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-dev
   resources:
     - namespace.yaml
     - ../base/podinfo
   labels:
     - pairs:
         app.kubernetes.io/part-of: cgoa-lab
         environment: dev
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 2
   EOF
   ```

4. Render locally **before** committing. This is the cheapest possible feedback loop and it costs no cluster.

   ```bash
   kubectl kustomize apps/dev | grep -E '^(kind|  name:|  namespace:|  replicas:)' 
   ```

   ```
   kind: Namespace
     name: podinfo-dev
   kind: Service
     name: podinfo
     namespace: podinfo-dev
   kind: Deployment
     name: podinfo
     namespace: podinfo-dev
     replicas: 2
   ```

5. Declare the Flux `Kustomization` that reconciles this overlay, and place it in the cluster path so the root picks it up.

   ```bash
   cat > clusters/dev/apps.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: apps-dev
     namespace: flux-system
   spec:
     interval: 10m
     retryInterval: 1m
     timeout: 3m
     path: ./apps/dev
     prune: true
     wait: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     healthChecks:
       - apiVersion: apps/v1
         kind: Deployment
         name: podinfo
         namespace: podinfo-dev
   EOF
   ```

6. Commit, push, and force a reconciliation instead of waiting for the interval.

   ```bash
   git add apps clusters && git commit -m "feat: podinfo dev overlay" && git push
   flux reconcile kustomization flux-system --with-source
   flux get kustomizations
   ```

   ```
   NAME         REVISION            SUSPENDED  READY  MESSAGE
   apps-dev     main@sha1:c19be40   False      True   Applied revision: main@sha1:c19be40
   flux-system  main@sha1:c19be40   False      True   Applied revision: main@sha1:c19be40
   ```

7. Confirm the workload and trace an individual object back to its source of truth.

   ```bash
   kubectl -n podinfo-dev get deploy,pod
   flux trace --kind=Deployment --api-version=apps/v1 --namespace=podinfo-dev podinfo
   ```

   ```
   NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/podinfo   2/2     2            2           31s

   Object:         Deployment/podinfo
   Namespace:      podinfo-dev
   Status:         Managed by Flux
   ---
   Kustomization:  apps-dev
   Namespace:      flux-system
   Path:           ./apps/dev
   Revision:       main@sha1:c19be40
   Status:         Last reconciled at 2026-08-18 10:41:12 +0000 UTC
   Message:        Applied revision: main@sha1:c19be40
   ---
   GitRepository:  flux-system
   Namespace:      flux-system
   URL:            ssh://git@github.com/<user>/gitops-cgoa.git
   Branch:         main
   Revision:       main@sha1:c19be40
   Status:         Last reconciled at 2026-08-18 10:41:11 +0000 UTC
   Message:        stored artifact for revision 'main@sha1:c19be40'
   ```

### Comprehension check — Block 2

- **Q2.1** There are now two objects called "Kustomization" in play with *different* `apiVersion`s. State both, and explain which one the `kustomize-controller` executes and which one it merely *reads as data*.
- **Q2.2** `apps-dev` sets `wait: true` **and** a `healthChecks` entry. Are these redundant? Describe the behavioral difference and when you would use one without the other.
- **Q2.3** In the overlay you set `includeSelectors: false` on the common labels. Predict, concretely, what would break on the *second* reconciliation if that were `true`.
- **Q2.4** `flux trace` reported a chain of three objects. Which GitOps principle does that chain make auditable, and what would the equivalent evidence be if you had run `kubectl apply -f` by hand?

---

## Exercise 3 — Drift detection, self-healing, and the limits of both

**Objective:** see what a reconciler *does* and *does not* consider drift.

### Steps

1. Introduce drift in a field the desired state declares.

   ```bash
   kubectl -n podinfo-dev scale deployment podinfo --replicas=5
   kubectl -n podinfo-dev get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   deployment.apps/podinfo scaled
   5
   ```

2. Trigger reconciliation of the app Kustomization only (no source refetch needed — Git has not changed).

   ```bash
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   ► annotating Kustomization apps-dev in flux-system namespace
   ✔ Kustomization annotated
   ◎ waiting for Kustomization reconciliation
   ✔ applied revision main@sha1:c19be40

   2
   ```

3. Now introduce drift in a field the desired state does **not** declare.

   ```bash
   kubectl -n podinfo-dev set env deployment/podinfo INJECTED=by-hand
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
   ```

   ```
   deployment.apps/podinfo env updated
   ✔ applied revision main@sha1:c19be40

   [{"name":"INJECTED","value":"by-hand"}]
   ```

   The environment variable **survived**. Understand why before continuing.

4. Inspect the field-management record that explains step 3.

   ```bash
   kubectl -n podinfo-dev get deploy podinfo --show-managed-fields -o yaml \
     | yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}'
   ```

   ```yaml
   manager: kustomize-controller
   operation: Apply
   manager: kubectl-set
   operation: Update
   ```

5. Correct it declaratively — the only legitimate remedy. Add the field to Git so it becomes owned, or remove the intruder by taking ownership. Here, force ownership of the whole pod template by declaring an empty `env` list is *not* how it works; instead, observe the supported escape hatch:

   ```bash
   kubectl -n podinfo-dev delete deployment podinfo
   flux reconcile kustomization apps-dev
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}'
   ```

   ```
   deployment.apps "podinfo" deleted
   ✔ applied revision main@sha1:c19be40

   ```

6. Test pruning. Remove the Service from the base and confirm the cluster object disappears.

   ```bash
   sed -i '/service.yaml/d' apps/base/podinfo/kustomization.yaml
   git commit -am "chore: drop podinfo service" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl -n podinfo-dev get svc
   ```

   ```
   ✔ applied revision main@sha1:7f22ab3
   No resources found in podinfo-dev namespace.
   ```

7. Restore it (you need the Service later).

   ```bash
   git revert --no-edit HEAD && git push
   flux reconcile kustomization flux-system --with-source
   ```

### Comprehension check — Block 3

- **Q3.1** Replicas were reverted; the injected env var was not. Give the mechanism — name the API feature and the specific rule that produces this asymmetry.
- **Q3.2** A colleague proposes "just make Flux delete anything it does not own." Explain, with a concrete controller example, why that is unsafe in a real cluster.
- **Q3.3** In step 6, pruning removed the Service after the commit. If instead the *whole* `apps/dev` directory had been deleted in Git, what would `prune: true` do, and what protects you from doing that accidentally to a production namespace?
- **Q3.4** Distinguish *drift detection* from *drift correction*. Name one production scenario where you deliberately want detection with alerting but **not** automatic correction.

---

## Exercise 4 — Argo CD: install, Application CRD, and the three-way comparison

**Objective:** the same principles, a different reconciliation model — cluster-side rendering, an explicit `Application` object, and a UI/API for the sync state machine.

### Steps

1. Install Argo CD into its own namespace. (In a real GitOps setup this manifest would itself be sourced from Git — see Q4.4.)

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
   ```

   ```
   deployment "argocd-server" successfully rolled out
   ```

2. Get the initial admin password and log in through a port-forward.

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
   ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d)
   argocd login localhost:8080 --username admin --password "$ARGOCD_PW" --insecure
   ```

   ```
   'admin:login' logged in successfully
   Context 'localhost:8080' updated
   ```

3. Declare an `Application`. Note it is *declarative* — created from a file in Git, not from `argocd app create`.

   ```bash
   cat > argocd/podinfo-staging.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: podinfo-staging
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/<user>/gitops-cgoa.git
       targetRevision: main
       path: apps/staging
     destination:
       server: https://kubernetes.default.svc
       namespace: podinfo-staging
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
         allowEmpty: false
       syncOptions:
         - CreateNamespace=true
         - ApplyOutOfSyncOnly=true
         - ServerSideApply=true
       retry:
         limit: 5
         backoff:
           duration: 5s
           factor: 2
           maxDuration: 3m
   EOF
   ```

4. Create the `staging` overlay it points at.

   ```bash
   mkdir -p apps/staging
   cat > apps/staging/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-staging
   resources:
     - ../base/podinfo
   labels:
     - pairs:
         environment: staging
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
   EOF
   ```

5. Push, then apply the `Application` once (the bootstrap of Argo's own tree).

   ```bash
   git add argocd apps/staging && git commit -m "feat: argocd staging app" && git push
   kubectl apply -f argocd/podinfo-staging.yaml
   argocd app wait podinfo-staging --health --timeout 180
   ```

   ```
   application.argoproj.io/podinfo-staging created

   Name:               argocd/podinfo-staging
   Project:            default
   Server:             https://kubernetes.default.svc
   Namespace:          podinfo-staging
   Repo:               https://github.com/<user>/gitops-cgoa.git
   Target:             main
   Path:               apps/staging
   SyncWindow:         Sync Allowed
   Sync Policy:        Automated (Prune)
   Sync Status:        Synced to main (9d02c77)
   Health Status:      Healthy
   ```

6. Read the per-resource view and the live-vs-desired diff machinery.

   ```bash
   argocd app resources podinfo-staging
   kubectl -n podinfo-staging scale deploy podinfo --replicas=7
   argocd app diff podinfo-staging
   ```

   ```
   GROUP  KIND        NAMESPACE         NAME     ORPHANED  STATUS  HEALTH
          Service     podinfo-staging   podinfo  No        Synced  Healthy
   apps   Deployment  podinfo-staging   podinfo  No        Synced  Healthy

   ===== apps/Deployment podinfo-staging/podinfo ======
   3c3
   <   replicas: 7
   ---
   >   replicas: 3
   ```

7. Watch self-heal close the gap, then confirm.

   ```bash
   argocd app wait podinfo-staging --sync --timeout 120
   kubectl -n podinfo-staging get deploy podinfo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   3
   ```

### Comprehension check — Block 4

- **Q4.1** `syncPolicy.automated` has `prune` and `selfHeal` as independent booleans. Describe the exact behavior of an `Application` with `selfHeal: true, prune: false` when a resource is deleted from Git and a different one is edited in the cluster.
- **Q4.2** `argocd app diff` printed a difference while `argocd app resources` reported `Synced`. Reconcile those two statements — what refresh semantics explain it?
- **Q4.3** The `Application` carries `resources-finalizer.argocd.argoproj.io`. What happens if you `kubectl delete application podinfo-staging` **with** the finalizer versus **without** it, and why is that choice a policy decision rather than a detail?
- **Q4.4** Argo CD was installed here with a raw `kubectl apply` from a URL. Name two concrete GitOps properties you lost by doing that, and outline how you would make Argo CD manage itself.
- **Q4.5** `ApplyOutOfSyncOnly=true` and `ServerSideApply=true` were both set. State the operational problem each one solves.

---

## Exercise 5 — Sync waves, hooks, and ordering guarantees

**Objective:** control *order* in a system whose default is "apply everything, converge eventually."

### Steps

1. Add an ordered bundle: a migration Job that must complete before the app rolls, and a ConfigMap that must exist before both.

   ```bash
   mkdir -p apps/staging/ordering
   cat > apps/staging/ordering/configmap.yaml <<'EOF'
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: podinfo-config
     annotations:
       argocd.argoproj.io/sync-wave: "-1"
   data:
     PODINFO_UI_MESSAGE: "cgoa staging"
   EOF

   cat > apps/staging/ordering/migration-job.yaml <<'EOF'
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: podinfo-migrate
     annotations:
       argocd.argoproj.io/hook: PreSync
       argocd.argoproj.io/hook-delete-policy: HookSucceeded
   spec:
     backoffLimit: 2
     ttlSecondsAfterFinished: 300
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: migrate
             image: busybox:1.36
             command: ["sh", "-c", "echo 'running schema migration'; sleep 5; echo done"]
             securityContext:
               allowPrivilegeEscalation: false
               runAsNonRoot: true
               runAsUser: 65534
               capabilities:
                 drop: ["ALL"]
   EOF
   ```

2. Wire them into the overlay and give the Deployment a later wave.

   ```bash
   cat > apps/staging/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-staging
   resources:
     - ../base/podinfo
     - ordering/configmap.yaml
     - ordering/migration-job.yaml
   labels:
     - pairs:
         environment: staging
       includeSelectors: false
   patches:
     - target:
         kind: Deployment
         name: podinfo
       patch: |-
         - op: replace
           path: /spec/replicas
           value: 3
         - op: add
           path: /metadata/annotations
           value:
             argocd.argoproj.io/sync-wave: "1"
         - op: add
           path: /spec/template/spec/containers/0/envFrom
           value:
             - configMapRef:
                 name: podinfo-config
   EOF
   ```

3. Push and watch the ordering in real time.

   ```bash
   git add apps/staging && git commit -m "feat: sync waves + presync hook" && git push
   argocd app sync podinfo-staging --async
   watch -n1 'argocd app get podinfo-staging --output tree'
   ```

   ```
   KIND/NAME                        STATUS      HEALTH
   Job/podinfo-migrate              Running     Progressing   <- PreSync hook
   ConfigMap/podinfo-config         OutOfSync   -
   Deployment/podinfo               OutOfSync   Healthy
   ```

   then, after the hook completes:

   ```
   KIND/NAME                        STATUS      HEALTH
   ConfigMap/podinfo-config         Synced      -             <- wave -1
   Deployment/podinfo               Synced      Progressing   <- wave 1
   └─ReplicaSet/podinfo-7c9f4b8d5   
     └─Pod/podinfo-7c9f4b8d5-x2klm  
   ```

4. Confirm the hook Job was garbage-collected by its delete policy.

   ```bash
   kubectl -n podinfo-staging get jobs
   ```

   ```
   No resources found in podinfo-staging namespace.
   ```

5. Compare with Flux's ordering model, which is *between* Kustomizations rather than inside one. Add a dependency edge:

   ```bash
   cat > clusters/dev/infra.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: infra-dev
     namespace: flux-system
   spec:
     interval: 10m
     path: ./infra/dev
     prune: true
     wait: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   EOF

   # make apps depend on infra
   yq -i '.spec.dependsOn = [{"name": "infra-dev"}]' clusters/dev/apps.yaml
   mkdir -p infra/dev
   cat > infra/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources: []
   EOF
   git add clusters infra && git commit -m "feat: infra->apps dependency" && git push
   flux reconcile kustomization flux-system --with-source
   flux get kustomizations
   ```

   ```
   NAME         REVISION            SUSPENDED  READY  MESSAGE
   apps-dev     main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   flux-system  main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   infra-dev    main@sha1:e4410fa   False      True   Applied revision: main@sha1:e4410fa
   ```

### Comprehension check — Block 5

- **Q5.1** State the ordering rule Argo CD applies *within* a single wave, before waves are even considered. Why does that make waves necessary only for cross-kind dependencies it cannot infer?
- **Q5.2** The migration Job is a `PreSync` hook, not a wave `-2` resource. Give two behaviors you get from the hook that a plain wave-ordered Job would not provide.
- **Q5.3** Flux's `dependsOn` and Argo's `sync-wave` both express ordering, but at different granularities. Describe a requirement that `dependsOn` can express and `sync-wave` cannot, and one where the reverse is true.
- **Q5.4** `infra-dev` has `wait: true`. Explain why omitting it would silently make `dependsOn` nearly meaningless.

---

## Exercise 6 — Helm under GitOps: `HelmRelease` and Argo's Helm source

**Objective:** run a templating engine inside the reconciliation loop without reintroducing imperative `helm upgrade`.

### Steps

1. Flux side — declare the chart repository and the release as data.

   ```bash
   mkdir -p infra/dev/podinfo-helm
   cat > infra/dev/podinfo-helm/repository.yaml <<'EOF'
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 30m
     url: https://stefanprodan.github.io/podinfo
   EOF

   cat > infra/dev/podinfo-helm/release.yaml <<'EOF'
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: podinfo-helm
     namespace: flux-system
   spec:
     interval: 10m
     releaseName: podinfo-helm
     targetNamespace: podinfo-helm
     install:
       createNamespace: true
       remediation:
         retries: 3
     upgrade:
       remediation:
         retries: 3
         remediateLastFailure: true
       cleanupOnFail: true
     driftDetection:
       mode: enabled
     chart:
       spec:
         chart: podinfo
         version: "6.7.x"
         sourceRef:
           kind: HelmRepository
           name: podinfo
           namespace: flux-system
         interval: 30m
     values:
       replicaCount: 2
       ui:
         message: "reconciled by flux"
       resources:
         requests:
           cpu: 10m
           memory: 32Mi
   EOF

   cat > infra/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - podinfo-helm/repository.yaml
     - podinfo-helm/release.yaml
   EOF
   ```

2. Push and reconcile, then inspect the release.

   ```bash
   git add infra && git commit -m "feat: podinfo helmrelease" && git push
   flux reconcile kustomization flux-system --with-source
   flux get helmreleases -A
   kubectl -n podinfo-helm get deploy
   ```

   ```
   NAMESPACE    NAME          REVISION  SUSPENDED  READY  MESSAGE
   flux-system  podinfo-helm  6.7.1     False      True   Helm install succeeded for release podinfo-helm/podinfo-helm.v1 with chart podinfo@6.7.1

   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo-helm   2/2     2            2           41s
   ```

3. Prove Helm drift detection. Change a value in the cluster, not in Git.

   ```bash
   kubectl -n podinfo-helm set env deploy/podinfo-helm PODINFO_UI_MESSAGE="tampered"
   flux reconcile helmrelease podinfo-helm
   kubectl -n podinfo-helm get deploy podinfo-helm \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}{"\n"}'
   ```

   ```
   ✔ applied revision 6.7.1
   reconciled by flux
   ```

4. Argo CD side — the equivalent, using a chart as an `Application` source with values held in Git.

   ```bash
   cat > argocd/podinfo-helm-argo.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: podinfo-helm-argo
     namespace: argocd
   spec:
     project: default
     sources:
       - repoURL: https://stefanprodan.github.io/podinfo
         chart: podinfo
         targetRevision: 6.7.1
         helm:
           releaseName: podinfo-argo
           valueFiles:
             - $values/argocd/values/podinfo-staging.yaml
       - repoURL: https://github.com/<user>/gitops-cgoa.git
         targetRevision: main
         ref: values
     destination:
       server: https://kubernetes.default.svc
       namespace: podinfo-helm-argo
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   EOF

   mkdir -p argocd/values
   cat > argocd/values/podinfo-staging.yaml <<'EOF'
   replicaCount: 1
   ui:
     message: "reconciled by argo cd"
   EOF

   git add argocd && git commit -m "feat: multi-source helm app" && git push
   kubectl apply -f argocd/podinfo-helm-argo.yaml
   argocd app wait podinfo-helm-argo --health --timeout 180
   ```

5. See what Argo actually sends to the API server.

   ```bash
   argocd app manifests podinfo-helm-argo | grep -E '^(kind|  name:)' | head
   kubectl -n podinfo-helm-argo get deploy -o wide
   ```

### Comprehension check — Block 6

- **Q6.1** Both tools run `helm template`-equivalent rendering, but only one keeps a Helm release *record*. Which one, where does it store it, and name one operational capability that record enables and the other approach loses.
- **Q6.2** The `HelmRelease` pins `version: "6.7.x"` while the Argo `Application` pins `targetRevision: 6.7.1`. Explain what breaks the GitOps guarantee of *declarative and versioned* in the first form, and when a range is nevertheless defensible.
- **Q6.3** The Argo app uses two `sources` with `ref: values`. State the design problem this solves and why simply forking the chart into your repo is usually worse.
- **Q6.4** `driftDetection.mode: enabled` had to be turned on explicitly on the `HelmRelease`. Why is it not the default, given that Flux corrects drift on plain Kustomizations without asking?

---

## Exercise 7 — Secrets: SOPS-encrypted state in Git

**Objective:** keep the "everything in Git" property without putting plaintext credentials in Git.

### Steps

1. Generate an `age` key pair and load the **private** half into the cluster only.

   ```bash
   age-keygen -o age.agekey
   export SOPS_AGE_RECIPIENT=$(grep 'public key:' age.agekey | awk '{print $4}')
   echo "$SOPS_AGE_RECIPIENT"
   ```

   ```
   Public key: age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
   age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
   ```

   ```bash
   cat age.agekey | kubectl -n flux-system create secret generic sops-age \
     --from-file=age.agekey=/dev/stdin
   ```

   ```
   secret/sops-age created
   ```

2. Add a `.sops.yaml` so encryption rules are themselves declarative and only the *values* are encrypted.

   ```bash
   cat > .sops.yaml <<EOF
   creation_rules:
     - path_regex: .*\.sops\.yaml$
       encrypted_regex: "^(data|stringData)$"
       age: ${SOPS_AGE_RECIPIENT}
   EOF
   ```

3. Author the Secret in plaintext, encrypt it in place, and verify what lands in Git.

   ```bash
   cat > apps/dev/podinfo-secret.sops.yaml <<'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: podinfo-credentials
     namespace: podinfo-dev
   type: Opaque
   stringData:
     API_TOKEN: "s3cr3t-do-not-commit-in-clear"
   EOF

   sops --encrypt --in-place apps/dev/podinfo-secret.sops.yaml
   head -12 apps/dev/podinfo-secret.sops.yaml
   ```

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
       name: podinfo-credentials
       namespace: podinfo-dev
   type: Opaque
   stringData:
       API_TOKEN: ENC[AES256_GCM,data:pQ9v2r...,iv:8Kx...,tag:mJ4...,type:str]
   sops:
       age:
           - recipient: age1qz9k0m8x7v6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7vqk4mn2p
             enc: |
               -----BEGIN AGE ENCRYPTED FILE-----
   ```

   Note that `apiVersion`, `kind`, `metadata` and `type` are **readable** — that is deliberate.

4. Tell the Flux `Kustomization` how to decrypt, and include the file in the overlay.

   ```bash
   yq -i '.resources += ["podinfo-secret.sops.yaml"]' apps/dev/kustomization.yaml
   yq -i '.spec.decryption = {"provider": "sops", "secretRef": {"name": "sops-age"}}' \
     clusters/dev/apps.yaml
   git add .sops.yaml apps clusters && git commit -m "feat: sops-encrypted secret" && git push
   flux reconcile kustomization flux-system --with-source
   ```

5. Verify the cluster has the plaintext and Git does not.

   ```bash
   kubectl -n podinfo-dev get secret podinfo-credentials \
     -o jsonpath='{.data.API_TOKEN}' | base64 -d; echo
   git grep -c 's3cr3t-do-not-commit-in-clear' || echo "not present in working tree"
   ```

   ```
   s3cr3t-do-not-commit-in-clear
   not present in working tree
   ```

6. Delete the private key locally and confirm reconciliation still works — the cluster is the only decryption authority.

   ```bash
   shred -u age.agekey
   flux reconcile kustomization apps-dev
   ```

   ```
   ✔ applied revision main@sha1:b71c904
   ```

### Comprehension check — Block 7

- **Q7.1** `encrypted_regex: "^(data|stringData)$"` leaves metadata in clear. Name the specific GitOps workflow that would break if the whole file were opaque, and the specific information leak you accept in exchange.
- **Q7.2** Compare SOPS-in-Git with an External Secrets Operator pulling from Vault. For each, state where the *source of truth* for the secret value lives, and what a full cluster rebuild from Git alone requires.
- **Q7.3** Sealed Secrets encrypts with a controller-held public key, scoped by namespace *and* name by default. Explain what that scoping prevents, and what it costs you when you promote a manifest from staging to production.
- **Q7.4** After step 6 you can no longer decrypt the file locally. Describe the disaster-recovery consequence and the minimum backup policy that makes this design safe.

---

## Exercise 8 — Image update automation: closing the CI→CD loop through Git

**Objective:** let new container images reach the cluster *via a commit*, never via a pipeline that talks to the API server.

### Steps

1. Declare the image scanner and the selection policy.

   ```bash
   mkdir -p clusters/dev/automation
   cat > clusters/dev/automation/image.yaml <<'EOF'
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImageRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     image: ghcr.io/stefanprodan/podinfo
     interval: 5m
     exclusionList:
       - "^.*\\.sig$"
   ---
   apiVersion: image.toolkit.fluxcd.io/v1beta2
   kind: ImagePolicy
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     imageRepositoryRef:
       name: podinfo
     policy:
       semver:
         range: 6.7.x
   EOF
   ```

2. Declare who writes the commit and where.

   ```bash
   cat > clusters/dev/automation/update.yaml <<'EOF'
   apiVersion: image.toolkit.fluxcd.io/v1beta1
   kind: ImageUpdateAutomation
   metadata:
     name: podinfo-automation
     namespace: flux-system
   spec:
     interval: 5m
     sourceRef:
       kind: GitRepository
       name: flux-system
     git:
       checkout:
         ref:
           branch: main
       commit:
         author:
           name: fluxcdbot
           email: fluxcdbot@users.noreply.github.com
         messageTemplate: |
           chore(images): {{range .Changed.Changes}}{{.OldValue}} -> {{.NewValue}}{{end}}

           Automated image update by Flux image-automation-controller.
       push:
         branch: main
     update:
       path: ./apps/base/podinfo
       strategy: Setters
   EOF
   ```

3. Mark the field to be rewritten. The marker is a YAML comment referencing the policy by `namespace:name`.

   ```bash
   sed -i 's|image: ghcr.io/stefanprodan/podinfo:6.7.0|image: ghcr.io/stefanprodan/podinfo:6.7.0 # {"$imagepolicy": "flux-system:podinfo"}|' \
     apps/base/podinfo/deployment.yaml
   grep image: apps/base/podinfo/deployment.yaml
   ```

   ```
           image: ghcr.io/stefanprodan/podinfo:6.7.0 # {"$imagepolicy": "flux-system:podinfo"}
   ```

4. Push and observe the policy resolve a tag.

   ```bash
   git add apps clusters && git commit -m "feat: image update automation" && git push
   flux reconcile kustomization flux-system --with-source
   flux get images all -A
   ```

   ```
   NAMESPACE    NAME             LAST SCAN                 SUSPENDED  READY  MESSAGE
   flux-system  podinfo          2026-08-18T11:02:47Z      False      True   successful scan: found 41 tags

   NAMESPACE    NAME             LATEST IMAGE                            READY  MESSAGE
   flux-system  podinfo          ghcr.io/stefanprodan/podinfo:6.7.1      True   Latest image tag for 'ghcr.io/stefanprodan/podinfo' resolved to 6.7.1

   NAMESPACE    NAME                 LAST RUN                  SUSPENDED  READY  MESSAGE
   flux-system  podinfo-automation   2026-08-18T11:03:12Z      False      True   committed and pushed commit '4ac9e30' to branch 'main'
   ```

5. Read the commit the controller authored, then confirm the cluster followed.

   ```bash
   git pull --rebase
   git log -1 --format='%an <%ae>%n%n%B'
   kubectl -n podinfo-dev get deploy podinfo \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   fluxcdbot <fluxcdbot@users.noreply.github.com>

   chore(images): ghcr.io/stefanprodan/podinfo:6.7.0 -> ghcr.io/stefanprodan/podinfo:6.7.1

   Automated image update by Flux image-automation-controller.

   ghcr.io/stefanprodan/podinfo:6.7.1
   ```

6. Make it review-gated instead of push-to-main — the production shape.

   ```bash
   yq -i '.spec.git.push.branch = "flux-image-updates"' clusters/dev/automation/update.yaml
   git commit -am "chore: image updates via PR branch" && git push
   ```

### Comprehension check — Block 8

- **Q8.1** The policy is `semver: {range: 6.7.x}`. Explain what happens on the day `6.8.0` is published, and why that is the *desired* behavior for an automated updater.
- **Q8.2** In step 6 the controller now pushes to `flux-image-updates` while the `GitRepository` still tracks `main`. Describe the full path a new image now takes to production, and name the human control point.
- **Q8.3** A teammate argues it is simpler for CI to run `kubectl set image` after building. List three properties from this exercise that approach forfeits.
- **Q8.4** `ImageRepository` scans the registry every 5 minutes. Identify the two distinct rate-limit/credential concerns this creates and how you would configure each.
- **Q8.5** Why does the `$imagepolicy` marker live in the **base**, not in the `dev` overlay, and what would go wrong if you marked both overlays independently?

---

## Exercise 9 — Progressive delivery: Argo Rollouts canary with analysis

**Objective:** the deployment strategy itself becomes declarative state, and promotion is driven by measured signals.

### Steps

1. Install Argo Rollouts and its kubectl plugin.

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   curl -sSL -o /tmp/kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   sudo install -m 555 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
   kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=3m
   ```

2. Declare a `Rollout` with a canary strategy and an automated analysis gate.

   ```bash
   mkdir -p apps/canary
   cat > apps/canary/analysis.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: success-rate
   spec:
     args:
       - name: service-name
     metrics:
       - name: request-success-rate
         interval: 30s
         count: 3
         successCondition: result[0] >= 0.95
         failureLimit: 1
         provider:
           prometheus:
             address: http://prometheus.monitoring.svc:9090
             query: |
               sum(rate(http_requests_total{
                 service="{{args.service-name}}", status!~"5.."
               }[1m]))
               /
               sum(rate(http_requests_total{
                 service="{{args.service-name}}"
               }[1m]))
   EOF

   cat > apps/canary/rollout.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: podinfo-canary
   spec:
     replicas: 4
     revisionHistoryLimit: 3
     selector:
       matchLabels:
         app: podinfo-canary
     template:
       metadata:
         labels:
           app: podinfo-canary
       spec:
         containers:
           - name: podinfo
             image: ghcr.io/stefanprodan/podinfo:6.7.0
             ports:
               - name: http
                 containerPort: 9898
             readinessProbe:
               httpGet:
                 path: /readyz
                 port: http
             resources:
               requests:
                 cpu: 10m
                 memory: 32Mi
     strategy:
       canary:
         analysis:
           templates:
             - templateName: success-rate
           startingStep: 2
           args:
             - name: service-name
               value: podinfo-canary
         steps:
           - setWeight: 20
           - pause: {duration: 30s}
           - setWeight: 50
           - pause: {duration: 30s}
           - setWeight: 100
   EOF

   cat > apps/canary/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: podinfo-canary
   resources:
     - namespace.yaml
     - analysis.yaml
     - rollout.yaml
   EOF

   cat > apps/canary/namespace.yaml <<'EOF'
   apiVersion: v1
   kind: Namespace
   metadata:
     name: podinfo-canary
   EOF
   ```

3. Reconcile it through Flux and observe the initial (non-canary) rollout.

   ```bash
   cat > clusters/dev/canary.yaml <<'EOF'
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: canary-dev
     namespace: flux-system
   spec:
     interval: 10m
     path: ./apps/canary
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
   EOF
   git add apps/canary clusters/dev/canary.yaml && git commit -m "feat: canary rollout" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary
   ```

   ```
   Name:            podinfo-canary
   Namespace:       podinfo-canary
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          5/5
     SetWeight:     100
     ActualWeight:  100
   Images:          ghcr.io/stefanprodan/podinfo:6.7.0 (stable)
   Replicas:
     Desired:       4
     Current:       4
     Updated:       4
     Ready:         4
     Available:     4
   ```

4. Trigger a canary by changing the image **in Git**.

   ```bash
   sed -i 's|podinfo:6.7.0|podinfo:6.7.1|' apps/canary/rollout.yaml
   git commit -am "feat: podinfo 6.7.1 canary" && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary --watch
   ```

   ```
   Name:            podinfo-canary
   Status:          ॥ Paused
   Message:         CanaryPauseStep
   Strategy:        Canary
     Step:          1/5
     SetWeight:     20
     ActualWeight:  20
   Images:          ghcr.io/stefanprodan/podinfo:6.7.0 (stable)
                    ghcr.io/stefanprodan/podinfo:6.7.1 (canary)
   Replicas:
     Desired:       4
     Current:       5
     Updated:       1
   ```

5. Abort the rollout imperatively, then observe the conflict with GitOps.

   ```bash
   kubectl argo rollouts abort podinfo-canary -n podinfo-canary
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | head -5
   flux reconcile kustomization canary-dev
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | head -5
   ```

   ```
   Name:            podinfo-canary
   Status:          ✖ Degraded
   Message:         RolloutAborted: Rollout aborted update to revision 2

   Name:            podinfo-canary
   Status:          ॥ Paused
   Message:         CanaryPauseStep
   ```

   The abort did not survive reconciliation. Understand why.

6. Roll back the correct way — revert the commit.

   ```bash
   git revert --no-edit HEAD && git push
   flux reconcile kustomization flux-system --with-source
   kubectl argo rollouts get rollout podinfo-canary -n podinfo-canary | grep Images -A2
   ```

### Comprehension check — Block 9

- **Q9.1** In step 5 the abort was undone. Name the exact mechanism, and state the general rule it illustrates about imperative actions in a self-healing system.
- **Q9.2** `startingStep: 2` means analysis begins after the first weight step. What operational tradeoff is being made, and when would you set it to `0`?
- **Q9.3** The `AnalysisTemplate` queries Prometheus. What happens to the rollout if Prometheus is unreachable, and which fields control that behavior?
- **Q9.4** Contrast the rollback in step 6 with `kubectl argo rollouts undo`. Both restore 6.7.0 in the cluster — explain why only one of them is a *GitOps* rollback and what the other leaves you with.
- **Q9.5** Argo Rollouts uses a `Rollout` CRD replacing `Deployment`; Flagger drives a stock `Deployment` from outside. State one consequence of each choice for a team already running many `Deployment`s.

---

## Exercise 10 — Observability and diagnostics of the reconciliation loop

**Objective:** answer "why is my cluster not what Git says?" with evidence, in under two minutes.

### Steps

1. Inject a realistic failure: a manifest that is valid YAML but invalid against the API.

   ```bash
   cat > apps/dev/broken.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: broken
   spec:
     replicas: "two"
     selector:
       matchLabels:
         app: broken
     template:
       metadata:
         labels:
           app: broken
       spec:
         containers:
           - name: c
             image: busybox:1.36
   EOF
   yq -i '.resources += ["broken.yaml"]' apps/dev/kustomization.yaml
   git add apps/dev && git commit -m "test: broken manifest" && git push
   flux reconcile kustomization flux-system --with-source
   ```

2. Triage top-down. First, *which* object is unhealthy across the whole cluster.

   ```bash
   flux get all -A --status-selector ready=false
   ```

   ```
   NAMESPACE    NAME                            REVISION  SUSPENDED  READY  MESSAGE
   flux-system  kustomization/apps-dev                    False      False  Deployment/podinfo-dev/broken dry-run failed: cannot convert string to int32
   ```

3. Then the object's conditions, which carry the machine-readable reason.

   ```bash
   kubectl -n flux-system get kustomization apps-dev \
     -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
   ```

   ```
   Ready       False   BuildFailed
   Reconciling True    ProgressingWithRetry
   ```

4. Then the events, which carry the ordering.

   ```bash
   kubectl -n flux-system get events --field-selector involvedObject.name=apps-dev \
     --sort-by=.lastTimestamp | tail -5
   ```

5. Then the controller logs, filtered.

   ```bash
   flux logs --level=error --kind=Kustomization --name=apps-dev --since=10m
   ```

   ```
   2026-08-18T11:31:04.882Z error Kustomization/apps-dev.flux-system - Reconciler error
     Deployment/podinfo-dev/broken dry-run failed: cannot convert string to int32
   ```

6. Confirm the critical property: **the previous good state was not damaged**.

   ```bash
   kubectl -n podinfo-dev get deploy podinfo
   ```

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo   2/2     2            2           47m
   ```

7. Wire an alert so you do not discover this by polling. (`Provider` + `Alert`, using a generic webhook.)

   ```bash
   cat > clusters/dev/notifications.yaml <<'EOF'
   ---
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Provider
   metadata:
     name: on-call
     namespace: flux-system
   spec:
     type: generic
     address: http://alert-sink.monitoring.svc/flux
   ---
   apiVersion: notification.toolkit.fluxcd.io/v1beta3
   kind: Alert
   metadata:
     name: reconciliation-failures
     namespace: flux-system
   spec:
     providerRef:
       name: on-call
     eventSeverity: error
     eventSources:
       - kind: Kustomization
         name: '*'
       - kind: HelmRelease
         name: '*'
       - kind: ImageUpdateAutomation
         name: '*'
     suspend: false
   EOF
   ```

8. Fix forward and verify recovery.

   ```bash
   git revert --no-edit HEAD
   git add clusters/dev/notifications.yaml && git commit -m "feat: failure alerts" && git push
   flux reconcile kustomization flux-system --with-source
   flux get all -A --status-selector ready=false
   ```

   ```
   ✗ no Flux objects found with ready=false status
   ```

9. Argo CD equivalent triage, for comparison.

   ```bash
   argocd app get podinfo-staging --hard-refresh
   argocd app history podinfo-staging
   kubectl -n argocd logs deploy/argocd-application-controller --tail=50 | grep -i error
   ```

### Comprehension check — Block 10

- **Q10.1** The failure was caught at *dry-run*, before anything was applied. Name the Kubernetes API feature that makes this possible and state why partial application would be far worse in a GitOps system than in an imperative one.
- **Q10.2** During the failure, `podinfo` kept running at 2/2. Explain what that tells you about the atomicity unit of a Flux `Kustomization`, and how you would have *reduced the blast radius* if `broken.yaml` had been in the same directory as something critical.
- **Q10.3** The `Alert` sets `eventSeverity: error`. What do you lose by not also alerting on `info`, and what do you gain?
- **Q10.4** Give the ordered diagnostic ladder used in steps 2–5 (four rungs), and state what each rung answers that the previous one cannot.
- **Q10.5** `argocd app get --hard-refresh` was used instead of plain `--refresh`. State the difference and name a failure it is specifically for.

---

## Cleanup

```bash
kind delete cluster --name gitops
```

---

## Answers

<details>
<summary><strong>Click to reveal the answers to all comprehension checks</strong></summary>

### Block 0

**A0.1** `flux check --pre` validates only the *target*: the Kubernetes version and the client's ability to reach the API server. It knows nothing about repository reachability, credentials, deploy-key permissions, branch existence, or path validity. Those failures show up only after bootstrap, as a `GitRepository` whose `Ready` condition is `False`. The covering command is `flux check` (post-install) plus `flux get sources git`, and for credentials specifically, reading the `GitOperationFailed` reason on the `GitRepository` status.

**A0.2** If both reconcilers own the same `Deployment`, you get an **apply war**: each controller sees the other's mutation as drift and rewrites the object on every reconciliation. Observable symptoms are a `metadata.generation` and `resourceVersion` climbing continuously with no Git change, both `kustomize-controller` and `argocd-controller` appearing in `metadata.managedFields` for overlapping field sets, and constant `Updated`/`SyncPerformed` events. In the lab they are kept apart by namespace and by directory: Flux owns `apps/dev` and `infra/dev`, Argo owns `apps/staging`.

**A0.3** Because the cluster version is part of the desired state of the system, and a floating `:latest` makes the environment non-reproducible: the same Git revision would yield a different result depending on *when* you ran it. GitOps requires the desired state to be declarative and versioned; that requirement does not stop at the application boundary. A pinned node image means a colleague reproducing your bug gets your bug.

### Block 1

**A1.1** `GitRepository.spec.interval` (1m) is how often the **source-controller** polls the remote, fetches, and — if the revision changed — stores a new artifact locally and updates `status.artifact`. `Kustomization.spec.interval` (10m) is how often the **kustomize-controller** re-renders the artifact it currently sees and applies it, *regardless* of whether the revision changed (this is what corrects drift). The controller also reacts to a new artifact, but the guaranteed upper bound on latency is the sum: up to 1 minute to notice the push, plus up to 10 minutes until the next apply cycle — **worst case ≈ 11 minutes**. Drift with no Git change is corrected within 10 minutes.

**A1.2** Without `--with-source`, `flux reconcile kustomization` annotates only the `Kustomization`, forcing an immediate re-apply of the artifact the source-controller **already has**. With `--with-source`, it first annotates the `GitRepository` to force an immediate fetch. In step 5 nothing had been pushed — the deletion was cluster-side drift — so the cached artifact was already current and the plain form would have restored the controller just the same.

**A1.3** The controller records an inventory of every object it applied in `Kustomization.status.inventory`, as a list of `id` entries (`namespace_name_group_kind`) plus the resource version. On each reconciliation it renders the new desired set, diffs it against the stored inventory, and deletes objects present in the *old* inventory but absent from the *new* render. So pruning is driven by Flux's own record of what it previously owned — not by label heuristics and not by anything the cluster tells it. Objects it never applied are never candidates.

**A1.4** The self-reference means the Flux control plane is itself reconciled desired state: someone deleting a controller (step 5) or drifting its configuration gets corrected automatically, and the exact controller version in the cluster is auditable from Git history. What it does **not** make automatic is *version upgrades* — `gotk-components.yaml` is a static rendering of one Flux release. Bumping Flux still requires regenerating that file, which is what `flux bootstrap` (re-run) or `flux install --export` does, followed by a commit. Automating that is exactly what the `flux-system` `OCIRepository`-based install or a scheduled `flux bootstrap` in CI addresses.

### Block 2

**A2.1** The two are `kustomize.config.k8s.io/v1beta1` (the **Kustomize tool's** own file, `kustomization.yaml`, which describes bases, patches and transformers) and `kustomize.toolkit.fluxcd.io/v1` (the **Flux CRD**, a cluster object that says *which source, which path, how often, prune or not*). The kustomize-controller *executes* the Flux CRD — it is a reconciled Kubernetes object with status and conditions. It *reads* the `kustomize.config.k8s.io` file as input data when rendering the path, exactly as `kubectl kustomize` would. Confusing them is the single most common CGOA trap.

**A2.2** Not redundant. `wait: true` makes the controller block until **every** applied object reports readiness (using the same readiness heuristics as `kubectl wait`) before marking the `Kustomization` `Ready`. `healthChecks` restricts the wait to an **explicit list** of objects. Setting both means Flux waits on everything *and* the list is applied — in practice `healthChecks` is what you use *instead of* `wait: true` when the set contains objects with no meaningful readiness (raw ConfigMaps, CRDs) or slow-but-irrelevant ones. Use `wait: true` alone for small, uniformly-healthchecked bundles; use `healthChecks` alone when you need `dependsOn` gating to hinge on two or three specific workloads.

**A2.3** `includeSelectors: true` would inject `environment: dev` and `app.kubernetes.io/part-of: cgoa-lab` into `Deployment.spec.selector.matchLabels` **and** into the pod template labels. `spec.selector` on a `Deployment` is **immutable** after creation. The first apply would succeed (creating the Deployment with the extended selector); a later change to those labels, or applying the same base to an existing Deployment created without them, fails with `field is immutable`, and the `Kustomization` goes `Ready=False` with no way forward except deleting the Deployment. This is why the modern `labels:` transformer defaults to `includeSelectors: false` and why the old `commonLabels` field is discouraged.

**A2.4** It makes **traceability / auditability** verifiable: any running object can be mapped back to a specific Git revision, a specific path, and the reconciler that applied it — which is the operational expression of the principle that the desired state is declarative, versioned, and continuously reconciled from a single source of truth. With `kubectl apply -f` your evidence is `kubectl.kubernetes.io/last-applied-configuration` (the *content* applied, with no author, no revision, no repository) plus whatever shell history the operator happened to keep. You can see *what* is running; you cannot prove *why* or *from where*.

### Block 3

**A3.1** The mechanism is **server-side apply (SSA)** with field ownership. The kustomize-controller applies as field manager `kustomize-controller` with `force: true`, so it owns exactly the fields present in its rendered manifest. `spec.replicas` **is** in the manifest → owned → any other manager's value is overwritten on the next apply. `spec.template.spec.containers[0].env` is **not** in the manifest → not owned by the controller → SSA leaves fields owned by other managers (here `kubectl-set`, via an `Update` operation) untouched. The rule is: *SSA reconciles the fields you declare; it does not delete fields you never mentioned.* That is a feature — it lets HPAs, mutating webhooks, and sidecar injectors coexist with GitOps.

**A3.2** Because a live Kubernetes object legitimately carries fields written by controllers that are **not** and must not be in Git: an HPA writes `spec.replicas`, a service-mesh or vault webhook injects sidecar containers and volumes, `cluster-autoscaler` and schedulers write status, cloud controllers write `status.loadBalancer.ingress`, and `metadata.finalizers` are added by other operators. A reconciler that stripped every unowned field would fight the HPA on every cycle (flapping replica counts), delete injected sidecars (breaking mTLS), and remove finalizers (causing orphaned cloud resources). Field-level ownership is what makes GitOps composable with the rest of the ecosystem.

**A3.3** Deleting `apps/dev` in Git would make the render empty, so every object in the `apps-dev` inventory — Deployment, Service, Namespace, Secret — would be **deleted from the cluster**. Protections, in increasing strength: (a) `spec.suspend: true` on the `Kustomization` while restructuring; (b) `kustomize.toolkit.fluxcd.io/prune: disabled` annotation on individual must-never-delete objects; (c) branch protection with required review on the paths that back production; (d) `--prune=false` equivalents plus the fact that Flux refuses to apply an *empty* result if the build fails (an empty directory is a build error, not an empty inventory — but an explicitly emptied `kustomization.yaml` **is** a valid empty render and will prune). Argo CD's equivalent guards are `allowEmpty: false` and the `Prune=false` sync option.

**A3.4** *Detection* is comparing live state to desired state and reporting the delta. *Correction* is writing the desired state back. You want detection-only where a human decision is required before the change takes effect: a **regulated production environment with change-control windows** (the delta must be recorded and approved before it is closed), a **cluster undergoing incident response** where an on-call engineer has deliberately scaled or patched something and auto-revert would re-break the outage, and any **migration** where the cluster is intentionally ahead of Git. Flux expresses this with `spec.suspend: true` plus alerting; Argo CD with `syncPolicy.automated` omitted (manual sync) — in both cases the `OutOfSync`/drift signal still fires.

### Block 4

**A4.1** With `selfHeal: true, prune: false`: the resource **edited** in the cluster is reverted to the Git state automatically (that is `selfHeal` — it triggers a sync when live state diverges without a Git change). The resource **deleted from Git** is *not* removed from the cluster; instead the `Application` reports `OutOfSync` with that resource marked `Prune` / `RequiresPruning`, and it stays running indefinitely until someone runs `argocd app sync --prune` or flips the flag. The result is a cluster that silently accumulates orphans while claiming to self-heal — which is why `prune: false` should always be paired with alerting on `OutOfSync`.

**A4.2** `argocd app resources` reads the **cached** application state from the application controller's last reconciliation. `argocd app diff` (without flags) also uses the cached live state but can be ahead of the displayed aggregate status because the controller's status field is written at the end of a reconcile cycle. Between the manual `kubectl scale` and the next reconciliation (default ~3 min app resync, or immediately on a watch event), the cached aggregate can still read `Synced` while the diff against freshly-read live state shows 7 vs 3. `argocd app get --refresh` forces a re-comparison; `--hard-refresh` additionally discards the manifest-generation cache. Self-heal closed the gap in step 7.

**A4.3** **With** the finalizer, deleting the `Application` performs a **cascading delete**: Argo CD removes every resource in the app's inventory from the cluster before allowing the `Application` object itself to be removed. **Without** it, only the `Application` object disappears and the workloads keep running, now unmanaged and orphaned. It is a policy decision because the two answers to "what does deleting the app definition mean?" are both legitimate: for ephemeral preview environments you want everything to vanish; for a shared production database you emphatically do not want a `kubectl delete app` typo to drop the StatefulSet. Choose per-`Application`, and pair the destructive choice with RBAC on `applications` delete.

**A4.4** Lost: (1) **versioning and auditability** — there is no record in Git of which Argo CD version is installed, `stable` is a moving tag, and you cannot diff or roll back the install; (2) **continuous reconciliation / self-healing** — nothing corrects drift in Argo CD's own Deployments, ConfigMaps or RBAC, so a manual edit to `argocd-cm` persists invisibly. To fix it, use the **app-of-apps / self-management** pattern: commit a pinned Argo CD install (Kustomize overlay of a specific release tag, or a `HelmRelease`/Helm-source `Application` pinned to a chart version) to Git, and create an `Application` named e.g. `argocd` whose source is that path and whose destination is the `argocd` namespace. Argo CD then reconciles itself. The remaining bootstrap step — the first apply that creates that `Application` — is irreducible and is the same chicken-and-egg that `flux bootstrap` solves.

**A4.5** `ApplyOutOfSyncOnly=true` makes a sync send only the resources the diff marked out-of-sync, instead of re-applying the entire manifest set. It solves **API-server load and sync duration** on large applications (hundreds of resources), and reduces spurious `Update` events and resourceVersion churn. `ServerSideApply=true` switches from client-side apply (which stuffs the whole manifest into the `last-applied-configuration` annotation) to SSA. It solves two things: the **262 KB annotation size limit** that breaks large CRDs, and **field-ownership conflicts** with other controllers — the same mechanism analyzed in A3.1, making Argo's behavior match Flux's coexistence semantics.

### Block 5

**A5.1** Within a wave, Argo CD applies resources in a **fixed kind order** derived from the Helm/`kubectl apply` ordering convention: Namespaces, ResourceQuotas, NetworkPolicies, LimitRanges, PodSecurityPolicies, ServiceAccounts, Secrets, ConfigMaps, StorageClasses, PVs, PVCs, CustomResourceDefinitions, ClusterRoles/Bindings, Roles/Bindings, Services, then workloads (DaemonSet, Pod, ReplicaSet, Deployment, StatefulSet, Job, CronJob), then Ingress/APIService. Ties break alphabetically by name. That built-in order already handles the common structural dependencies (namespace before everything in it, CRD before its CR, Secret before the Pod mounting it), so waves are needed only for **semantic** dependencies the ordering cannot infer — "the database must be migrated before the app version that expects the new schema", "the cert-manager `ClusterIssuer` must be ready before the `Certificate`".

**A5.2** (1) **Lifecycle relative to the sync, not to the resource set**: a `PreSync` hook runs *before any* wave, and the sync **fails and stops** if the hook Job fails — nothing else is applied. A wave `-2` Job is just an object; Argo applies it and moves on when it is *created*, not when it *succeeds* (unless you also add health assessment), and a failed Job leaves a half-applied release. (2) **Automatic garbage collection** via `hook-delete-policy` (`HookSucceeded`, `HookFailed`, `BeforeHookCreation`) — hooks are not part of the app inventory, so re-running the sync recreates them cleanly, whereas a plain Job with a fixed name fails to re-apply on the second sync because `spec.template` is immutable. Also worth noting: `PostSync` and `SyncFail` hooks have no wave equivalent at all.

**A5.3** `dependsOn` gates **whole reconciliation units** across sources, namespaces, and even different Git paths: "do not apply *anything* in `apps-dev` until *every* object in `infra-dev` is Ready." A `sync-wave` cannot cross `Application` boundaries — it orders only within one app's resource set — so cluster-wide sequencing (CRDs and operators from one repo before workloads from another) needs `dependsOn` (or Argo's own app-of-apps waves on the parent `Application` objects). Conversely, `sync-wave` can express **fine-grained ordering inside a single unit** — ConfigMap at `-1`, Deployment at `1`, Ingress at `2`, all in the same directory — which `dependsOn` cannot do without splitting the directory into separate `Kustomization` objects, each with its own interval, status and inventory.

**A5.4** `dependsOn` waits for the dependency's `Ready` condition to be `True`. Without `wait: true` (and without `healthChecks`), a `Kustomization` reports `Ready=True` as soon as its objects have been **successfully applied to the API server** — not when they are running. So `infra-dev` would go Ready the instant the CRDs and operator Deployment were *created*, and `apps-dev` would immediately apply custom resources whose controller has not started and whose CRDs may not yet be established. You would get intermittent `no matches for kind` errors that disappear on retry — the classic symptom. `wait: true` (or an explicit `healthChecks` list) is what converts "applied" into "actually usable," which is the only meaning of "depends on" that helps.

### Block 6

**A6.1** **Flux's `HelmRelease`** keeps a real Helm release record — the helm-controller uses the Helm SDK and writes the standard release Secret (`sh.helm.release.v1.<name>.v<N>`, type `helm.sh/release.v1`) in the target namespace. Argo CD by default runs `helm template` and applies the output, so there is **no** Helm release record. What the record enables: `helm history` / `helm rollback` semantics, atomic install/upgrade with automatic rollback on failure (`upgrade.remediation.remediateLastFailure`, `cleanupOnFail`), correct execution of chart **hooks** (`pre-install`, `post-upgrade`), and `helm test`. What Argo's approach gains in exchange: the rendered output is fully visible to Argo's diff engine and to `argocd app manifests`, so drift and diff are per-object rather than per-release, and there is no second state store to lose.

**A6.2** `6.7.x` is a **range**: the source-controller re-resolves it on every `chart.spec.interval` and will silently upgrade the release when `6.7.2` is published. The revision running in the cluster is then not determined by the Git revision — two clusters at the same commit can run different chart versions, and rolling back the commit does not roll back the chart. That breaks *declarative + versioned + immutable*. It is defensible when (a) the range is narrow and the chart's semver discipline is trusted, (b) it is confined to non-production where fast patch pickup is worth more than reproducibility, and (c) it is paired with alerting on `HelmRelease` revision changes so the upgrade is at least *observed*. In production, pin exactly — and use image/chart update automation (Exercise 8) so the bump arrives as a reviewable **commit**, which gives you both freshness and reproducibility.

**A6.3** It solves the **"upstream chart, local values"** problem: the chart is owned by a third party and versioned in their repository, while the environment-specific values are yours and belong in your Git repo under review. `ref: values` names the second source so `$values/...` can resolve a `valueFiles` path inside it, letting one `Application` combine an unmodified upstream chart with your versioned configuration. Forking the chart into your repo is worse because you inherit maintenance of the entire template tree: every upstream release must be merged by hand, security fixes lag, and your diff against upstream grows until the fork is effectively a new chart. Keeping the chart external and the values internal keeps the boundary at the right place — you version your *intent*, not their implementation.

**A6.4** Because for a Helm release, "drift" is ambiguous and correcting it is expensive. The helm-controller's normal comparison is between the **desired chart+values and the last release record**, not between the release and live cluster state — so with drift detection off, an upgrade only happens when the chart version or values change. Turning it on makes the controller additionally render the release and diff it against live objects on every interval, which costs CPU and API calls proportional to release size, and — critically — can conflict with charts that legitimately expect mutation after install (webhook-injected fields, charts whose own hooks patch resources, `lookup`-based templates that are non-deterministic). Plain Kustomizations have none of that ambiguity: the rendered manifest *is* the desired state, and SSA field ownership already scopes correction safely, so it can default to on. If you enable it, `driftDetection.ignore` with JSON pointers is the escape hatch for the fields other controllers own.

### Block 7

**A7.1** Leaving `apiVersion`, `kind`, `metadata` and `type` in clear is what allows **Kustomize (and Flux, and code review) to treat the file as a manifest**: overlays can patch it, `namePrefix`/`namespace` transformers apply to it, the Flux inventory can track it, and a reviewer can see *that* a Secret named `podinfo-credentials` is being added to `podinfo-dev` and reason about blast radius without decrypting anything. If the whole file were opaque, it would be an unparseable blob — no patching, no diffing, no structural review, and a rename would be indistinguishable from a rotation. The accepted leak is **metadata**: the existence, name, namespace, type, and the *key names* of every secret are public in the repository. That is a real leak (it maps your credential inventory) and it is the reason the repo should still not be world-readable.

**A7.2** **SOPS-in-Git:** the source of truth for the *ciphertext* is Git; the source of truth for the *plaintext* is Git plus the private key. A full cluster rebuild from Git alone is **not** sufficient — you must first restore the age/KMS private key into the new cluster, after which everything else follows from the repository. **External Secrets Operator + Vault:** Git holds only an `ExternalSecret` — a *pointer* (which Vault path, which keys, which target Secret name). The source of truth for the value is Vault. A rebuild from Git alone requires a **live, reachable, populated Vault** and working workload-identity/auth for the new cluster; the repository by itself reconstructs nothing. Trade-off: SOPS keeps the closed-loop "Git is the source of truth" property and works air-gapped, but rotation means a commit and the ciphertext history is permanent; ESO gives central rotation, dynamic/short-lived credentials, and real audit logs, at the cost of a hard runtime dependency outside the Git loop.

**A7.3** Sealed Secrets' default scope (`strict`) binds the ciphertext to **both** the namespace and the name of the target Secret. This prevents a **cut-and-paste privilege escalation**: a developer with write access to namespace `team-b` cannot copy the sealed production database credential out of `prod/`'s manifests into their own namespace and have the controller decrypt it for them — the controller refuses because the sealing metadata does not match. The cost is that a manifest is **not portable across environments**: promoting `staging/db-secret.yaml` to `prod/` requires **re-sealing** the value against the production name and namespace, which means the plaintext must be available to whoever does the promotion. The escape hatches are `namespace-wide` scope (portable within a namespace, still isolated between them) and `cluster-wide` scope (fully portable, and it discards exactly the protection described above — use only for genuinely non-sensitive-by-namespace values).

**A7.4** The consequence is that the **cluster's `sops-age` Secret is now the only copy of the decryption key**. If the cluster is lost, every encrypted file in Git becomes permanently unreadable — the repository is intact and completely useless, and there is no recovery path because age has no key escrow. The minimum safe policy: store the private key in at least **two independent, durable, access-controlled locations outside the cluster** (a password manager or an offline HSM/paper backup, plus an org-level secret store), document who can retrieve it, and **test the restore** by decrypting a known file from a clean machine. Better still, use `.sops.yaml` `creation_rules` with **multiple recipients** — a cloud KMS key (AWS KMS / GCP KMS / Azure Key Vault, which brings IAM, rotation and audit logging) alongside one or more break-glass age keys — so that losing any single custodian is survivable and revoking one recipient is a re-encryption commit rather than a catastrophe.

### Block 8

**A8.1** Nothing. `semver: {range: 6.7.x}` is equivalent to `>=6.7.0 <6.8.0`, so `6.8.0` is **outside the range** and the `ImagePolicy` will keep resolving to the newest `6.7.z`. That is desired because a **minor** bump can carry behavioral changes, new required configuration, or changed defaults — things that should be reviewed by a human in a pull request, not applied automatically at 03:00. The automation's job is to make the *safe* class of updates (patch releases: bug and CVE fixes within a stable contract) frictionless, so that the *unsafe* class gets the scarce human attention. Moving to 6.8 is then a deliberate one-line commit changing the range, which is itself reviewable and revertible. For pre-release/CI streams the equivalent discipline is a `filterTags` regex plus `numerical` ordering on a build timestamp, never an unfiltered "latest tag."

**A8.2** The image-automation-controller resolves the new tag, rewrites the marked field, and pushes a commit to the **`flux-image-updates`** branch. Because the `GitRepository` tracks `main`, nothing in the cluster changes. A pull request is opened from `flux-image-updates` → `main` (by the controller's push triggering a provider automation, or by a scheduled job); CI runs against it; a **human reviews and merges**. Only the merge into `main` changes what the source-controller fetches, and the cluster converges on the next interval. The human control point is the **PR approval / merge**, and it is the only one — which is precisely why branch protection on `main` (required reviews, required status checks, no force-push) is a *cluster* security control in GitOps, not just a code-hygiene setting.

**A8.3** (1) **Auditability and reproducibility** — with `kubectl set image` the running image is nowhere in Git, so the repository no longer describes the cluster, and a rebuild from Git resurrects the old image. (2) **Rollback** — reverting is a `git revert` in the GitOps model versus "remember what the previous tag was and run another imperative command" in the CI model. (3) **Credential blast radius** — the CI system needs write credentials to the *Kubernetes API server*, permanently, from outside the trust boundary; in the pull model CI only needs to push to a container registry, and nothing outside the cluster ever holds cluster-admin. Secondary losses: no drift correction (the next reconciliation would revert `kubectl set image` anyway, causing a fight), and no review gate.

**A8.4** (1) **Registry rate limits / cost**: `ImageRepository` lists *all* tags on every scan. Against Docker Hub's anonymous limits or a paid registry with per-request billing, a 5-minute interval across many repositories is expensive. Mitigate by lengthening `interval` (30m–1h is usually plenty, since the PR is reviewed by a human anyway), narrowing with `exclusionList`/`filterTags` on the `ImagePolicy`, and — where supported — using a registry webhook plus `flux reconcile image repository` instead of polling. (2) **Credentials for private registries**: the controller needs pull-level auth, configured via `spec.secretRef` pointing at a `kubernetes.io/dockerconfigjson` Secret, via `spec.serviceAccountName` with an attached imagePullSecret, or via `spec.provider: aws|azure|gcp` for cloud workload identity (which avoids storing static credentials at all — the preferred option). Note the automation *also* needs **Git write** credentials, which is a third, separate concern: the bootstrap deploy key must be write-enabled (`--read-write-key`) or a dedicated `secretRef` supplied.

**A8.5** The marker belongs in the **base** because the base is the single place the image is *declared*; the overlays only patch other fields. `strategy: Setters` rewrites the value at the marked location in the file on disk, and the `update.path` (`./apps/base/podinfo`) scopes which files the controller may touch. If both overlays carried their own marked `image:` line referencing the same `ImagePolicy`, every overlay would be bumped to the same tag simultaneously — which **destroys the ability to promote between environments**: staging and production would always be identical, and there would be no window in which staging runs a version production does not. The correct multi-environment pattern is *distinct policies per environment* (e.g. a `podinfo-staging` policy on a broad range and a `podinfo-prod` policy on a narrow, manually-advanced one), each with its own `ImageUpdateAutomation` scoped to that environment's path — or, more commonly, automation only on staging and a human-authored promotion PR into production.

### Block 9

**A9.1** `kubectl argo rollouts abort` sets `spec.pause`/status fields **on the live `Rollout` object** — it is an imperative mutation of a field that the Flux `Kustomization` renders from Git. On the next reconciliation, server-side apply restored the object to the Git-declared state (no abort), and the Rollouts controller resumed the canary from where the spec said it should be. The general rule: **in a continuously-reconciled system, any imperative change to a field that Git declares has a lifetime bounded by the reconciliation interval.** Imperative commands are diagnostic tools, not control mechanisms. The GitOps-compatible ways to stop a rollout are to suspend the reconciler (`flux suspend kustomization canary-dev`) and then act, or — properly — to change Git.

**A9.2** `startingStep: 2` means the analysis run starts only once the rollout reaches step index 2 (`setWeight: 50`), so the first 20% step proceeds **unmeasured**. The trade-off is **signal quality versus exposure**: at 20% weight on 4 replicas the canary receives too little traffic for a rate-based success-rate query to be statistically meaningful within a 30-second window — the metric would be noisy and would abort on nothing. Waiting until 50% buys a usable denominator at the cost of exposing more users before the first automated verdict. Set it to `0` when the canary receives enough traffic immediately (high request volume, or a service where a 1-minute window at 20% still yields thousands of requests) or when the metric is not rate-based — a synthetic probe, a smoke-test `Job` metric, or an error *count* threshold works fine at low weight and should gate the very first step.

**A9.3** A provider error is **not** treated as a success. The metric result is recorded as `Error`, which counts against `failureLimit`-adjacent budgets — specifically, consecutive errors are governed by `consecutiveErrorLimit` (default 4); exceeding it fails the `AnalysisRun`, and a failed analysis **aborts the rollout** and scales the canary back to zero, leaving the stable version serving. The controlling fields are `consecutiveErrorLimit` (how many provider/transport errors are tolerated in a row), `failureLimit` (how many measurements may violate `successCondition`), `inconclusiveLimit` with an explicit `inconclusiveCondition` (for "cannot tell" verdicts, which pause for human decision rather than aborting), plus `interval`/`count` which set the sampling. The important design point: **unavailable telemetry fails closed**, because a canary you cannot measure is a canary you cannot approve — but you must set `consecutiveErrorLimit` deliberately, or a brief Prometheus restart will abort legitimate rollouts.

**A9.4** `git revert` changes the **desired state**, so the cluster converges to 6.7.0 *and stays there*: the repository and the cluster agree, the rollback is recorded as a reviewable, attributable commit, a rebuilt cluster reproduces the rolled-back state, and any other cluster tracking the same branch rolls back too. `kubectl argo rollouts undo` mutates the live `Rollout` only. Git still says 6.7.1, so you now have **deliberate, invisible drift**: the next reconciliation (or the next unrelated commit touching that path) re-applies 6.7.1 and silently redeploys the bad version — the outage returns, with no obvious cause. Only the first is a GitOps rollback; the second is a temporary local override that has to be immediately followed by a commit, and it is the classic way a 2 a.m. fix reappears as a 9 a.m. incident.

**A9.5** **Argo Rollouts (`Rollout` CRD replaces `Deployment`)**: you must *migrate* every workload — change `kind`, adjust anything that references the Deployment (HPA `scaleTargetRef`, some dashboards, kubectl muscle memory, admission policies and tooling that key on `apps/v1 Deployment`) — and third-party Helm charts that hard-code `Deployment` cannot be used unmodified. In exchange you get the full step DSL (weights, pauses, experiments, blue-green with preview services) as first-class, versioned spec, plus a purpose-built CLI/UI. **Flagger (drives a stock `Deployment`)**: you keep your existing `Deployment` manifests and charts untouched — Flagger creates a shadow primary Deployment and manipulates Services/mesh routing from outside — so adoption is incremental and reversible. The cost is a more indirect model (two Deployments per app, the original is scaled to zero and *owned* by Flagger, which surprises people reading `kubectl get deploy`), a hard dependency on a supported traffic provider (Istio, Linkerd, NGINX, Gateway API, App Mesh…), and less expressive step control. A team with a large existing `Deployment` estate and a service mesh usually finds Flagger cheaper to adopt; a team standardizing on Argo CD and wanting rollout state visible in the same UI usually picks Rollouts.

### Block 10

**A10.1** The feature is the API server's **dry-run** (`kubectl apply --server-dry-run` / `?dryRun=All`), which runs the full admission chain — decoding, schema validation, mutating and validating webhooks, quota checks — and returns the result **without persisting anything to etcd**. Flux runs a server-side dry-run of the whole rendered set before applying it. Partial application is far worse under GitOps than under imperative operation because the system is a **loop, not a command**: an imperative `kubectl apply` that half-fails leaves a mess that a human is standing right there to see and clean up. A reconciler that half-applies will re-attempt the same half-application every interval, forever, producing a cluster that is permanently in a state described by no Git revision — neither the old one nor the new one — while the reconciler emits an error nobody is watching. Atomic all-or-nothing keeps the invariant that the cluster always matches *some* commit.

**A10.2** The atomicity unit of a Flux `Kustomization` is the **entire rendered path**: it builds, dry-runs, and applies as one transaction, and a failure anywhere aborts the whole apply — which is why `broken.yaml` prevented *any* change from `apps/dev` from landing, while previously-applied objects were left running untouched. That is the good news (nothing was damaged) and the bad news (one bad manifest **blocks every other change in that directory**, including an urgent fix). To reduce blast radius, **split the path into multiple `Kustomization` objects** with separate inventories — e.g. `apps-dev-critical` for the payment service and `apps-dev-experimental` for everything else — optionally linked with `dependsOn`. Each then fails independently. The general principle: the `Kustomization` boundary *is* your failure-isolation boundary, so draw it around things that should fail together.

**A10.3** By alerting only on `error` you lose the **positive signal**: successful reconciliations, new revisions applied, image automations committed, HelmReleases upgraded. That stream is what feeds deployment-frequency and lead-time metrics, what lets you correlate "the graph changed shape at 14:02" with "revision `a3d47e1` was applied at 14:01", and what tells you a reconciler is *alive* rather than merely not-failing — a suspended or crash-looping controller emits no errors at all. What you gain is a **signal-to-noise ratio a human can actually sustain**: with `info`, a cluster with a dozen `Kustomization`s reconciling every 10 minutes generates a constant stream, and the one real failure is lost in it. The production answer is **two `Alert` objects with different `providerRef`s**: `error` (and `inclusionList` for specific critical objects) to the on-call pager, and `info` to a low-priority chat channel or an events sink that feeds dashboards. Severity is a routing decision, not a filtering decision.

**A10.4** The ladder, and what each rung uniquely answers:

1. `flux get all -A --status-selector ready=false` — **which object is broken?** Scopes the whole cluster to the failing reconciler(s) in one command. It cannot tell you *why* beyond a truncated message.
2. `kubectl get <kind> <name> -o jsonpath='{.status.conditions...}'` — **what is the machine-readable state right now?** Gives the `reason` (`BuildFailed`, `HealthCheckFailed`, `ArtifactFailed`, `ReconciliationSucceeded`) and whether a retry is in flight (`Reconciling`/`Stalled`). Conditions are a *snapshot* — they cannot tell you what happened before the current attempt.
3. `kubectl get events --field-selector involvedObject.name=...` — **what is the sequence?** Ordering, repetition counts, and first/last timestamps distinguish "failed once and recovered" from "failing every interval for six hours." Events are truncated and expire (default 1h retention), and carry no controller-internal detail.
4. `flux logs --level=error --kind=... --name=...` — **what did the controller actually do?** Full error strings, stack context, the exact rendering or API error. This is the only rung that sees inside the controller, and the only one that survives event expiry (if logs are shipped).

The discipline is to go **top-down and stop as soon as you have the answer** — most failures are fully explained at rung 1 or 2, and jumping straight to logs on a large cluster is how a two-minute triage becomes twenty.

**A10.5** `--refresh` forces the application controller to **re-compare** desired versus live state: it re-reads live cluster state and re-runs the diff, but it may reuse the **cached rendered manifests** for the current Git revision. `--hard-refresh` additionally **invalidates the manifest-generation cache** and re-runs the repo-server's rendering (`kustomize build` / `helm template`) from scratch. It is specifically for failures where the *rendering* is stale or wrong while the Git revision appears unchanged: a **mutable upstream reference** — a Helm chart re-published under the same version, a `targetRevision` pointing at a moving tag or branch that was force-pushed, a remote Kustomize base fetched over HTTP, or a chart dependency resolved from a repository index that has since changed. Symptom: `argocd app get` insists the app is `Synced` at revision X while the manifests it would apply are demonstrably not what that revision produces today. Plain `--refresh` will happily re-diff against the same stale render and report everything fine.

</details>

---

## Official sources

- CNCF GitOps Certified Associate (CGOA) curriculum — https://github.com/cncf/curriculum/blob/master/cgoa/README.md
- OpenGitOps Principles v1.0.0 — https://opengitops.dev/ · https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
- Flux CD documentation — https://fluxcd.io/flux/
  - Bootstrap — https://fluxcd.io/flux/installation/bootstrap/
  - `Kustomization` API — https://fluxcd.io/flux/components/kustomize/kustomizations/
  - `GitRepository` API — https://fluxcd.io/flux/components/source/gitrepositories/
  - `HelmRelease` API — https://fluxcd.io/flux/components/helm/helmreleases/
  - Image update automation — https://fluxcd.io/flux/guides/image-update/
  - SOPS secrets management — https://fluxcd.io/flux/guides/mozilla-sops/
  - Notifications / `Alert` & `Provider` — https://fluxcd.io/flux/components/notification/
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
  - `Application` specification — https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/
  - Automated sync policy — https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
  - Sync waves and resource hooks — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
  - Sync options (`ServerSideApply`, `ApplyOutOfSyncOnly`) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
  - Multiple sources for an Application — https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/
  - App of Apps pattern — https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- Argo Rollouts documentation — https://argo-rollouts.readthedocs.io/en/stable/
  - Canary strategy — https://argo-rollouts.readthedocs.io/en/stable/features/canary/
  - Analysis and progressive delivery — https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Flagger documentation — https://docs.flagger.app/
- Kustomize reference — https://kubectl.docs.kubernetes.io/references/kustomize/
- Kubernetes Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Helm documentation — https://helm.sh/docs/
- SOPS — https://getsops.io/docs/ · age — https://github.com/FiloSottile/age
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator — https://external-secrets.io/latest/