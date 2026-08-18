# Topic 2.1 — GitOps Principles & Practices

## Guided Exercises

These exercises make you *build* GitOps from first principles before touching a full controller, so that every behavior of a production tool (Flux, Argo CD) maps to a mechanism you have already implemented by hand. You will need: a Linux/macOS shell, `git`, `kubectl`, `kind` (or any disposable Kubernetes cluster), and the `flux` CLI for the final exercises.

The four principles you are about to exercise are defined by the OpenGitOps project (a CNCF working group) in [GitOps Principles v1.0.0](https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md):

| # | Principle | Essence |
|---|-----------|---------|
| 1 | **Declarative** | Desired state is expressed as data (facts), not instructions |
| 2 | **Versioned and Immutable** | Desired state is stored with full history; versions are immutable |
| 3 | **Pulled Automatically** | Agents pull desired state from the store; state is not pushed at them |
| 4 | **Continuously Reconciled** | Agents continuously observe actual state and converge it toward desired state |

Reference sources used throughout:

- https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- https://opengitops.dev/
- https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md
- https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md
- https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/declarative-object-management-configuration/
- https://kubernetes.io/docs/reference/using-api/server-side-apply/
- https://fluxcd.io/flux/concepts/
- https://argo-cd.readthedocs.io/en/stable/

---

## Exercise 1 — Declarative desired state vs. imperative commands (Principle 1)

The word *declarative* is doing precise work in GitOps: the system's desired state must be expressed as **data that can be stored, diffed, and applied idempotently** — not as a sequence of commands whose outcome depends on the state they ran against.

### Steps

1. Create a disposable cluster:

   ```bash
   kind create cluster --name gitops-lab
   ```

2. Create a working directory and a declarative manifest:

   ```bash
   mkdir -p ~/gitops-lab/manifests && cd ~/gitops-lab
   cat > manifests/nginx.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: default
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
           image: nginx:1.27.0
           ports:
           - containerPort: 80
           resources:
             requests:
               cpu: 50m
               memory: 64Mi
             limits:
               memory: 128Mi
   EOF
   ```

3. First, do it the **imperative** way, twice, and observe the failure mode:

   ```bash
   kubectl create deployment web-imperative --image=nginx:1.27.0 --replicas=2
   kubectl create deployment web-imperative --image=nginx:1.27.0 --replicas=2
   ```

   Expected output of the second invocation:

   ```
   error: failed to create deployment: deployments.apps "web-imperative" already exists
   ```

4. Now the **declarative** way, also twice:

   ```bash
   kubectl apply -f manifests/nginx.yaml
   kubectl apply -f manifests/nginx.yaml
   ```

   Expected output:

   ```
   deployment.apps/web created
   deployment.apps/web unchanged
   ```

   Note `unchanged`: applying the same desired state again is a no-op. This property is **idempotency**, and it is what makes an automated reconciliation loop safe to run forever.

5. Preview a change *without* applying it. Edit `replicas: 2` → `replicas: 3` in `manifests/nginx.yaml`, then:

   ```bash
   kubectl diff -f manifests/nginx.yaml; echo "exit code: $?"
   ```

   Expected output (abridged):

   ```diff
   -  replicas: 2
   +  replicas: 3
   exit code: 1
   ```

   `kubectl diff` exits `1` when a difference exists, `0` when live state already matches, and `>1` on real errors — which makes desired-vs-actual comparison scriptable. This is the primitive underneath every GitOps tool's "diff/drift" feature.

6. Clean up the imperative experiment:

   ```bash
   kubectl delete deployment web-imperative
   ```

### Check your understanding

- **Q1.1** — Why can `kubectl apply` be run in an unattended loop while `kubectl create` cannot? Name the property and explain what the second `apply` did differently from the second `create` at the API level.
- **Q1.2** — A teammate proposes keeping a `setup.sh` full of `kubectl create ...` and `kubectl scale ...` commands in Git and calls it "GitOps, because the script is versioned." Which of the four principles does this violate, and what concrete capability do you lose?
- **Q1.3** — Principle 1 says desired state is "expressed declaratively." Does GitOps require YAML specifically? What does the [OpenGitOps glossary](https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md) actually require of the format?

---

## Exercise 2 — Git as the versioned, immutable state store (Principle 2)

The desired state store must provide **versioning, immutability, and a complete history**. Git is the canonical choice — not because GitOps requires Git, but because commits are content-addressed (a SHA identifies exactly one tree) and history manipulation is detectable.

### Steps

1. Turn the manifests directory into the **source of truth**:

   ```bash
   cd ~/gitops-lab
   git init --initial-branch=main
   git add manifests/nginx.yaml
   git commit -m "web: nginx 1.27.0, 3 replicas"
   ```

2. Make a change *as data*: bump the image. Edit `nginx:1.27.0` → `nginx:1.27.1`, then:

   ```bash
   git add -A
   git commit -m "web: bump nginx to 1.27.1"
   git log --oneline
   ```

   Expected output (your SHAs will differ):

   ```
   9f3c2b1 web: bump nginx to 1.27.1
   4a81e77 web: nginx 1.27.0, 3 replicas
   ```

3. Prove immutability by content-addressing. Ask Git what the manifest looked like at each version:

   ```bash
   git show 4a81e77:manifests/nginx.yaml | grep image:
   git show 9f3c2b1:manifests/nginx.yaml | grep image:
   ```

   Expected output:

   ```
           image: nginx:1.27.0
           image: nginx:1.27.1
   ```

   Any tampering with the old commit's content would change its SHA. The SHA *is* the version.

4. Roll back **as a Git operation**, preserving history:

   ```bash
   git revert --no-edit HEAD
   git log --oneline
   ```

   Expected output:

   ```
   c07d4e2 Revert "web: bump nginx to 1.27.1"
   9f3c2b1 web: bump nginx to 1.27.1
   4a81e77 web: nginx 1.27.0, 3 replicas
   ```

   The tree now matches the 1.27.0 state, but the history records that 1.27.1 existed, when, and that it was reverted. Compare with `git reset --hard 4a81e77` + force-push, which would *rewrite* history — destroying the audit trail the principle exists to protect.

5. Mark a known-good state with an immutable reference:

   ```bash
   git tag -a v0.1.0 -m "known good: nginx 1.27.0, 3 replicas"
   ```

### Check your understanding

- **Q2.1** — Why is `git revert` the GitOps-conformant rollback, and `git reset --hard` + force-push a violation of Principle 2? Answer in terms of what an auditor (or an incident retrospective) needs.
- **Q2.2** — In a production incident you must know *exactly* what was deployed at 03:12. What two identifiers, together, answer that question in a GitOps system, and why is "the CI build number" not one of them?
- **Q2.3** — Does Principle 2 mandate Git? Name one property a state store must have to qualify, and one storage system other than Git that could satisfy it.

---

## Exercise 3 — Build a pull-based reconciler in 15 lines of shell (Principles 3 & 4)

Before installing any tool, you will *be* the tool. A GitOps agent does exactly this: fetch desired state from the store, compare with actual state, apply. Building it by hand removes all magic from Flux and Argo CD.

### Steps

1. Create a bare repository to play the role of the remote (in production this is GitHub/GitLab; the mechanics are identical):

   ```bash
   git clone --bare ~/gitops-lab ~/gitops-remote.git
   cd ~/gitops-lab
   git remote add origin ~/gitops-remote.git
   git push -u origin main
   ```

2. Write the reconciler:

   ```bash
   cat > ~/reconciler.sh <<'EOF'
   #!/usr/bin/env bash
   # Minimal GitOps agent: pull desired state, converge actual state.
   set -euo pipefail
   REPO="$HOME/gitops-remote.git"
   WORKDIR="$(mktemp -d)"
   trap 'rm -rf "$WORKDIR"' EXIT
   git clone --quiet --depth 1 "$REPO" "$WORKDIR"
   REV="$(git -C "$WORKDIR" rev-parse --short HEAD)"
   if kubectl diff -f "$WORKDIR/manifests/" >/dev/null 2>&1; then
     echo "$(date -Is) rev=$REV in sync"
   else
     echo "$(date -Is) rev=$REV drift detected, reconciling"
     kubectl apply -f "$WORKDIR/manifests/"
   fi
   EOF
   chmod +x ~/reconciler.sh
   ```

3. Run one reconciliation cycle:

   ```bash
   ~/reconciler.sh
   ```

   Expected output (first run applies the reverted 1.27.0 state from Exercise 2 over the 1.27.1 you applied in Exercise 1):

   ```
   2026-08-18T10:41:02+00:00 rev=c07d4e2 drift detected, reconciling
   deployment.apps/web configured
   ```

4. Start the **continuous** loop in a second terminal and leave it running:

   ```bash
   while true; do ~/reconciler.sh; sleep 15; done
   ```

5. Now attack your own system. In the first terminal, introduce drift imperatively — the classic 3 a.m. hotfix:

   ```bash
   kubectl scale deployment web --replicas=10
   kubectl get deployment web -o jsonpath='{.spec.replicas}'; echo
   ```

   Expected output: `10` — briefly. Within 15 seconds the loop terminal shows:

   ```
   2026-08-18T10:43:17+00:00 rev=c07d4e2 drift detected, reconciling
   deployment.apps/web configured
   ```

   and the replica count is back to `3`. The manual change was **stomped** because it never existed in the desired state. This is drift correction, a.k.a. self-healing.

6. Make a *legitimate* change the GitOps way — through the store, never through the cluster:

   ```bash
   cd ~/gitops-lab
   sed -i 's/replicas: 3/replicas: 5/' manifests/nginx.yaml
   git commit -am "web: scale to 5 for launch traffic"
   git push origin main
   ```

   Within one cycle the loop picks it up and the deployment converges to 5 replicas. Stop the loop with `Ctrl-C` when done.

7. Reflect on the security topology you just built: the cluster-side agent held credentials to *read* the repo and *write* to the cluster it lives in. Nothing outside the cluster ever held cluster credentials. Compare with a push pipeline (CI runs `kubectl apply`), where a `KUBECONFIG` with write access must live in the CI system — outside the cluster's trust boundary.

### Check your understanding

- **Q3.1** — Principle 3 says desired state is *pulled automatically*, and the OpenGitOps notes add that it should not depend on being notified. Your loop polls every 15 s; many setups also add a webhook from the Git host to trigger an immediate sync. Is a system that reconciles *only* on webhooks GitOps-conformant? Why or why not?
- **Q3.2** — List two concrete security or operational advantages of the pull model over a CI-push model, based on what you observed in step 7.
- **Q3.3** — In step 5 your imperative fix was reverted automatically. In a real incident, engineers sometimes *need* a manual change to survive (break-glass). What are two conformant ways to handle this without abandoning GitOps?
- **Q3.4** — Your reconciler treats the repo as authoritative even for changes it didn't make. What is the name of the discrepancy it detects, and what is the general term for the process in step 5 that eliminates it?

---

## Exercise 4 — The same principles with a production controller: Flux (Principles 3 & 4 at scale)

Your shell loop lacks: retry with backoff, health assessment, garbage collection of deleted resources, status reporting as API objects, and multi-tenancy. Flux adds these while implementing exactly the loop you wrote. Docs: https://fluxcd.io/flux/concepts/

### Steps

1. Install the Flux controllers (no Git write access needed for this read-only exercise):

   ```bash
   flux install
   flux check
   ```

   Expected tail of output:

   ```
   ✔ helm-controller: deployment ready
   ✔ kustomize-controller: deployment ready
   ✔ notification-controller: deployment ready
   ✔ source-controller: deployment ready
   ✔ all checks passed
   ```

2. Declare the **source** — where desired state lives (equivalent to the `git clone` in your script):

   ```bash
   flux create source git podinfo \
     --url=https://github.com/stefanprodan/podinfo \
     --branch=master \
     --interval=1m
   ```

3. Declare the **reconciliation** — what path to apply and how (equivalent to your `kubectl apply` + loop):

   ```bash
   flux create kustomization podinfo \
     --source=GitRepository/podinfo \
     --path="./kustomize" \
     --target-namespace=default \
     --prune=true \
     --interval=1m \
     --wait --health-check-timeout=2m
   ```

   Expected output ends with:

   ```
   ✔ Kustomization podinfo is ready
   ```

4. Inspect the reconciled state — note that sync status is itself a Kubernetes object, with the applied Git SHA recorded:

   ```bash
   flux get kustomizations
   ```

   Expected output:

   ```
   NAME     REVISION              SUSPENDED  READY  MESSAGE
   podinfo  master@sha1:073f1ec5  False      True   Applied revision: master@sha1:073f1ec5
   ```

5. Attack it, harder than before — delete the entire Deployment:

   ```bash
   kubectl delete deployment podinfo
   flux reconcile kustomization podinfo --with-source
   kubectl get deployment podinfo
   ```

   Expected final output — resurrected from desired state:

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   podinfo   2/2     2            2           14s
   ```

6. Observe what your shell loop could never do — **prune**. Your script's `kubectl apply` adds and updates but never deletes: if you remove a manifest from Git, the live object leaks forever (an *orphan*). Flux with `--prune=true` tracks everything it created and garbage-collects objects that disappear from the source. Verify the mechanism:

   ```bash
   kubectl get deployment podinfo -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep kustomize.toolkit
   ```

   Expected output:

   ```
   "kustomize.toolkit.fluxcd.io/name":"podinfo"
   "kustomize.toolkit.fluxcd.io/namespace":"flux-system"
   ```

   These labels are Flux's inventory marker — how it knows which live objects belong to which Kustomization, so deletion-by-omission becomes safe.

7. Suspend reconciliation — the break-glass control from Q3.3, as a first-class, auditable operation:

   ```bash
   flux suspend kustomization podinfo
   flux get kustomizations
   ```

   Expected output shows `SUSPENDED: True`. Manual changes will now persist — visibly, temporarily, and reversibly (`flux resume kustomization podinfo`).

### Check your understanding

- **Q4.1** — Map each component you used (`GitRepository`, `Kustomization`, `source-controller`, `kustomize-controller`) onto the lines of your 15-line shell reconciler from Exercise 3.
- **Q4.2** — Why does pruning require an inventory (the labels from step 6)? Explain the failure mode of a naive "delete everything not in the repo" strategy in a cluster where several teams — or non-GitOps operators — also create objects.
- **Q4.3** — In step 4 the status object records `master@sha1:073f1ec5`. Connect this to Q2.2: what auditing question does storing the applied revision *in the cluster* answer that Git alone cannot?
- **Q4.4** — Argo CD implements the same principles with different vocabulary. What are the Argo CD equivalents of (a) the desired-state source + path, and (b) drift correction? (See https://argo-cd.readthedocs.io/en/stable/ — terms: `Application`, `syncPolicy.automated.selfHeal`.)

---

## Exercise 5 — Practices synthesis: deployment, rollback, and the CI/CD boundary

GitOps redraws the line between CI and CD: CI *produces* artifacts and updates desired state; the agent *delivers* it. Nothing in CI touches the cluster.

### Steps

1. On paper (or in a scratch file), lay out the production flow for a new application version, in order:

   ```
   1. Developer merges code PR            → CI builds image myapp:1.4.0, pushes to registry
   2. CI (or automation bot) opens a PR   → edits desired-state repo: image tag 1.3.2 → 1.4.0
   3. Human (or policy engine) approves   → merge to main
   4. Agent pulls within its interval     → detects new revision
   5. Agent applies, checks health        → cluster converges to 1.4.0
   6. Status reported                     → revision recorded in cluster + notifications
   ```

   Note what is absent: no `kubectl` in CI, no cluster credentials outside the cluster, no human running commands at any point after merge.

2. Identify the **two repositories** in this flow and their different lifecycles: the *application repo* (code, built by CI) and the *desired-state repo* (manifests, watched by the agent). Write down one reason to keep them separate (hint: consider what a revert of each one means, and who needs merge rights on which).

3. Simulate the rollback drill end-to-end with your Exercise 3 setup. Bad release:

   ```bash
   cd ~/gitops-lab
   sed -i 's/nginx:1.27.0/nginx:1.99.99-doesnotexist/' manifests/nginx.yaml
   git commit -am "web: bump nginx to 1.99.99"
   git push origin main
   ~/reconciler.sh
   kubectl rollout status deployment/web --timeout=30s
   ```

   Expected output:

   ```
   error: deployment "web" exceeded its progress deadline
   ```

   ```bash
   kubectl get pods -l app=web | head -4
   ```

   ```
   NAME                   READY   STATUS             RESTARTS   AGE
   web-7d9f8c6b5-x2kqp    0/1     ImagePullBackOff   0          45s
   web-6b8d7f9c4-a1wzr    1/1     Running            0          20m
   ```

   Note that the old ReplicaSet's pods are still `Running` — the Deployment controller's own rollout logic contains the blast radius while you fix forward or roll back.

4. Roll back through the store, never the cluster:

   ```bash
   git revert --no-edit HEAD
   git push origin main
   ~/reconciler.sh
   kubectl rollout status deployment/web --timeout=60s
   ```

   Expected output:

   ```
   deployment "web" successfully rolled out
   ```

   Total rollback procedure: one `git revert`. No special runbook, no snowflake commands — the *deploy path and the rollback path are the same path*, which is why they are equally well-rehearsed.

5. Tear down:

   ```bash
   kind delete cluster --name gitops-lab
   ```

### Check your understanding

- **Q5.1** — A pipeline runs `kubectl apply` from CI after every merge to main, using manifests stored in Git. Which principles does it satisfy, which does it violate, and name one class of failure it cannot detect that your Exercise 3 loop can.
- **Q5.2** — Why is `kubectl rollout undo` an anti-pattern in a GitOps-managed cluster, even though it "works"? What state divergence does it create?
- **Q5.3** — Give two reasons the application repo and the desired-state repo are typically separate, drawn from step 2 and from CI behavior (hint: what happens if CI triggers on every commit to a combined repo?).
- **Q5.4** — GitOps is related to, but distinct from, Infrastructure as Code. State the relationship in one sentence: what does IaC provide, and what do Principles 3 and 4 add on top of it?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — The property is **idempotency**. `kubectl apply` declares a desired end state: the API server (with server-side apply, via field management) computes the difference between the declared state and the live object and performs the minimal patch — or nothing, hence `unchanged`. `kubectl create` is an instruction ("make this object exist now") whose validity depends on prior state, so re-execution is an error. A reconciliation loop must run the same operation indefinitely, so every operation in it must be idempotent. See https://kubernetes.io/docs/reference/using-api/server-side-apply/

**A1.2** — It violates **Principle 1 (Declarative)**. A script is an *instruction sequence*; its result depends on the state it runs against, it is not idempotent, and it cannot be diffed against live state. You lose the ability to compute drift (`kubectl diff` has nothing to compare), and therefore Principle 4 (continuous reconciliation) becomes impossible to implement on top of it. Versioning a script satisfies Principle 2's letter while making 1, 3, and 4 unachievable.

**A1.3** — No. The [OpenGitOps glossary](https://github.com/open-gitops/documents/blob/v1.0.0/GLOSSARY.md) requires the desired state to be expressed *declaratively* — as data describing outcomes, not procedures. YAML, JSON, Kustomize overlays, Helm values, Jsonnet, or Terraform HCL all qualify, provided the expression is data from which an agent can compute and apply a diff.

### Exercise 2

**A2.1** — `git revert` creates a *new* commit whose tree matches the earlier state, preserving the complete history: an auditor can see that the bad version was deployed, during which window, and when it was rolled back — which is precisely the incident timeline a retrospective needs. `git reset --hard` + force-push *rewrites* history, destroying the record that the bad state ever existed, violating Principle 2's requirement of an immutable, complete version history (and breaking every clone that had fetched the old head).

**A2.2** — The **Git commit SHA** of the desired-state repo that the agent had applied, plus the **agent's recorded applied revision/status** at that timestamp (e.g. Flux's `Applied revision: master@sha1:...`). Together they prove both what the store said and what the cluster had actually converged to. A CI build number identifies an *artifact build*, not the desired state of the whole system at a point in time, and nothing guarantees the cluster was running it at 03:12.

**A2.3** — No — the principles say "state store," with Git as the dominant implementation. Qualifying properties: versioning, immutability of versions, and complete retrievable history. An **OCI registry with immutable, versioned artifacts** qualifies (Flux supports `OCIRepository` sources); an S3 bucket with versioning + object lock is another defensible example. A plain file share is not.

### Exercise 3

**A3.1** — No. Webhook-only sync makes the system *event-driven push-triggered*: if the webhook is lost (network partition, Git host outage, misconfiguration), desired and actual state silently diverge forever, and drift introduced *in the cluster* (which generates no Git webhook at all — as in step 5) is never corrected. Conformant systems reconcile on an interval *and* optionally accept webhooks as a latency optimization. Pull on a schedule is the correctness mechanism; the webhook is only an accelerator.

**A3.2** — (1) **Credential direction**: cluster write-credentials never leave the cluster; the agent only needs read access to the repo. A compromised CI system can propose state but cannot touch the cluster. (2) **Drift correction**: a push pipeline only acts when Git changes, so out-of-band cluster mutations (manual `kubectl`, a misbehaving operator) persist undetected; the pull loop detects and reverts them on every cycle. (Also acceptable: firewall posture — the cluster needs no inbound access from CI; and fleet scalability — N clusters pull from one repo without the pipeline knowing them.)

**A3.3** — (1) **Suspend reconciliation explicitly** (e.g. `flux suspend kustomization`, or Argo CD disabling auto-sync) — the pause itself is visible and reversible — make the manual fix, then backport it to Git and resume. (2) **Commit the emergency change to Git first** and let the agent roll it out — with a short interval or forced reconcile this is nearly as fast and never leaves the store behind. In both cases the invariant is restored: Git ends up matching the cluster.

**A3.4** — The discrepancy is **drift** (actual state diverging from desired state). The process that eliminates it is **reconciliation** — specifically automatic drift correction, commonly called **self-healing**.

### Exercise 4

**A4.1** — `GitRepository` ≙ the `REPO=` declaration plus `git clone` (fetch desired state; `source-controller` runs this loop, verifies, and packages the artifact). `Kustomization` ≙ the declaration of *what to apply from it* — `manifests/` path, interval, and the apply policy; `kustomize-controller` executes it: your `kubectl diff`/`kubectl apply` lines plus health checking, retries, and pruning. Your `while true; sleep 15` is each controller's `interval`. The key upgrade: in Flux the loop's *configuration is itself declarative state* stored as Kubernetes objects — the reconciler is configured by the same principles it enforces.

**A4.2** — Without an inventory, "delete everything not in the repo" cannot distinguish objects *this* reconciler created from objects created by other teams, other Kustomizations, operators/controllers (which create objects the repo never mentions), or Kubernetes itself. It would mass-delete resources it never owned. The inventory labels scope garbage collection to exactly the set of objects previously applied by this Kustomization, making removal-from-Git a safe deletion signal.

**A4.3** — It answers "**what has the cluster actually converged to right now?**" Git records what was *desired* and when it changed; it cannot say whether, or when, a given cluster applied it (the agent may be failing, suspended, or lagging). The in-cluster status closes the loop: desired revision (Git) vs. applied revision (cluster status) — their difference is precisely the sync lag or failure an operator needs to see.

**A4.4** — (a) The Argo CD `Application` resource, whose `spec.source` (repoURL + path/chart + targetRevision) plays the role of `GitRepository` + `Kustomization` path. (b) Automated sync with self-healing: `syncPolicy.automated: {selfHeal: true, prune: true}` — `selfHeal` reverts live drift, `prune` is Flux's `--prune`. Argo CD calls the desired-vs-actual comparison "sync status" (`Synced`/`OutOfSync`) and the convergence operation a "sync." See https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/

### Exercise 5

**A5.1** — It satisfies Principles **1** (declarative manifests) and **2** (versioned store). It violates **3** — state is pushed by an external system holding cluster credentials, not pulled by an in-cluster agent — and **4** — it runs only on merge events, not continuously. The undetectable failure class: **in-cluster drift** — any mutation made directly to the cluster (manual scale, deleted Deployment, mutated ConfigMap) generates no Git event, so the pipeline never notices; your loop detects and corrects it within one interval.

**A5.2** — `kubectl rollout undo` changes live state (rolls the Deployment back to a previous ReplicaSet template) without changing the desired state in Git. The divergence: Git still declares the bad version, so on the next reconciliation cycle the agent will re-apply it and **re-deploy the exact version you just rolled back** — self-healing works against you. The conformant rollback is `git revert`, which moves the *source of truth* and lets convergence do the rest; deploy and rollback then share one code path.

**A5.3** — (1) **Trigger hygiene**: in a combined repo, the CI bot's manifest-bump commit re-triggers CI, producing loops or wasted builds, and every app-code commit spuriously re-triggers deployment reconciliation. (2) **Independent lifecycles and permissions**: reverting the state repo rolls back a *deployment* without reverting *code*, and merge rights differ — developers merge code, while state-repo merges may require operator or policy-engine approval. (Also acceptable: one state repo fans out to many clusters/environments that a single app repo doesn't map to.)

**A5.4** — IaC provides Principles 1 and 2 — infrastructure defined as declarative, versioned data; GitOps adds 3 and 4: an autonomous in-cluster agent that continuously *pulls* that definition and *reconciles* actual state against it, turning "we can recreate the system from code" into "the system continuously converges to the code, and drift is corrected without a human running anything."

</details>