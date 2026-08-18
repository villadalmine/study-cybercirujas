# CGOA — Topic 1.1: GitOps Fundamentals
## Guided Exercises

> **Environment prerequisites:** a Linux/macOS workstation with `docker`, `kind` ≥ 0.20, `kubectl` ≥ 1.29, `git` ≥ 2.40, and `curl`. Every exercise is self-contained and idempotent: if a step fails, fix the cause and re-run it. Total estimated time: 90–120 minutes.

These exercises make you *build* GitOps from first principles before you touch a GitOps tool. You will express desired state declaratively (Principle 1), version it immutably in Git (Principle 2), write your own pull-based reconciler in ~15 lines of bash (Principles 3 and 4), and only then install Argo CD and recognize that it is the same loop, hardened for production. This mirrors how the OpenGitOps working group defines GitOps: not a tool, but four properties of a system ([https://opengitops.dev/](https://opengitops.dev/)).

---

## Exercise 1 — Desired state, expressed declaratively

The first OpenGitOps principle: *"A system managed by GitOps must have its desired state expressed declaratively."* Declarative means you record **what** the system should look like, never the sequence of commands that produced it.

1. Create a working directory and a local cluster:

   ```bash
   mkdir -p ~/cgoa-lab/desired && cd ~/cgoa-lab
   kind create cluster --name gitops-lab
   ```

   Expected output (abridged):

   ```
   Creating cluster "gitops-lab" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
   Set kubectl context to "kind-gitops-lab"
   ```

2. Write the desired state of a workload. Note that this file contains no verbs — no "create", "scale", or "update":

   ```bash
   cat > desired/deployment.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: default
     labels:
       app.kubernetes.io/name: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app.kubernetes.io/name: web
     template:
       metadata:
         labels:
           app.kubernetes.io/name: web
       spec:
         containers:
         - name: nginx
           image: nginx:1.27.1
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

3. Apply it and verify convergence:

   ```bash
   kubectl apply -f desired/
   kubectl get deploy web
   ```

   Expected output:

   ```
   deployment.apps/web created
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    2/2     2            2           14s
   ```

4. Re-apply the identical file — this is the property that makes GitOps automation safe:

   ```bash
   kubectl apply -f desired/
   ```

   Expected output:

   ```
   deployment.apps/web unchanged
   ```

5. Now do the *imperative* thing you must unlearn, and observe the consequence:

   ```bash
   kubectl scale deploy web --replicas=4
   kubectl diff -f desired/; echo "exit code: $?"
   ```

   Expected output (abridged): a unified diff showing the live object diverging from the file, and the documented exit code for "differences found":

   ```diff
   -  generation: 2
   +  generation: 3
   ...
   -  replicas: 4
   +  replicas: 2
   exit code: 1
   ```

   `kubectl diff` exit codes are part of its contract: `0` = no drift, `1` = drift, `>1` = error ([https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/)). You will build on this in Exercise 3.

6. Restore the desired state before continuing:

   ```bash
   kubectl apply -f desired/
   ```

**Check your understanding**

- **Q1.1** — The cluster now runs 2 replicas again. In GitOps terms, what is the name of the condition you created in step 5, and which two "states" did it separate?
- **Q1.2** — `kubectl scale` and editing `replicas:` in the file produce the same running pods. Why is only one of them GitOps-compatible?
- **Q1.3** — Why does idempotency (step 4's `unchanged`) matter for a system where an agent applies the same state in a loop, potentially thousands of times a day?

---

## Exercise 2 — Versioned and immutable

Principle 2: *"Desired state is stored in a way that enforces immutability, versioning and retains a complete version history."* Git satisfies this because every commit is a content-addressed, immutable object — you never edit history, you append to it.

1. Turn the desired state into a versioned source of truth:

   ```bash
   cd ~/cgoa-lab
   git init -b main
   git add desired/
   git commit -m "web: nginx 1.27.1, 2 replicas"
   ```

2. Inspect what Git actually stored. A commit is an object addressed by the SHA-1/SHA-256 hash of its own content:

   ```bash
   git log --oneline
   git cat-file -p HEAD
   ```

   Expected output (your hashes will differ):

   ```
   9f3c1aa web: nginx 1.27.1, 2 replicas
   tree 4b825dc6...
   author dalmine <...> 1755500000 +0200
   web: nginx 1.27.1, 2 replicas
   ```

3. Make a change *as a new version*, never as an edit of an old one:

   ```bash
   sed -i 's/replicas: 2/replicas: 3/' desired/deployment.yaml
   git commit -am "web: scale to 3 for launch traffic"
   git log --oneline
   ```

   Expected output:

   ```
   7d02e4f web: scale to 3 for launch traffic
   9f3c1aa web: nginx 1.27.1, 2 replicas
   ```

4. Roll back the GitOps way — a *new* commit that reintroduces the old state, preserving the audit trail:

   ```bash
   git revert --no-edit HEAD
   git log --oneline
   grep replicas desired/deployment.yaml
   ```

   Expected output:

   ```
   c11b9e0 Revert "web: scale to 3 for launch traffic"
   7d02e4f web: scale to 3 for launch traffic
   9f3c1aa web: nginx 1.27.1, 2 replicas
       replicas: 2
   ```

5. Mark a known-good state with an immutable reference:

   ```bash
   git tag -a v1.0.0 -m "baseline: known-good web stack"
   git show v1.0.0 --stat --oneline | head -3
   ```

**Check your understanding**

- **Q2.1** — Why is `git revert` the canonical GitOps rollback, while `git reset --hard` + force-push violates Principle 2?
- **Q2.2** — An auditor asks: "who changed the replica count, when, and what exactly changed?" Which single Git command answers all three, and why can't the answer be forged after the fact?
- **Q2.3** — The tag `v1.0.0` and the branch `main` both point at commits. Which one is an immutable *version* in the sense of Principle 2, and what operational risk do you take by having an agent deploy a moving reference like `HEAD` of `main`?

---

## Exercise 3 — Build the reconciliation loop yourself

Principles 3 and 4: agents *pull* the desired state and *continuously reconcile* the live state toward it. Before installing 200 MB of controller, prove the concept in bash. This is a **level-triggered** loop — it compares complete states every cycle — exactly the model of a Kubernetes controller ([https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)).

1. Write the reconciler. It clones the truth (pull), diffs (observe), applies (act):

   ```bash
   cat > reconcile.sh <<'EOF'
   #!/usr/bin/env bash
   # Minimal level-triggered GitOps reconciler.
   # Pulls desired state from a Git repo, converges the cluster toward it.
   set -u
   REPO="$HOME/cgoa-lab"          # in production: an https:// or ssh:// remote
   WORKDIR="$(mktemp -d)"
   INTERVAL=5

   while true; do
     rm -rf "$WORKDIR/src"
     git clone --quiet --depth 1 "$REPO" "$WORKDIR/src"     # PULL
     kubectl diff -f "$WORKDIR/src/desired/" >/dev/null 2>&1 # OBSERVE
     rc=$?
     if [ "$rc" -eq 1 ]; then
       echo "$(date -Is) drift detected — reconciling"
       kubectl apply -f "$WORKDIR/src/desired/"              # ACT
     elif [ "$rc" -gt 1 ]; then
       echo "$(date -Is) ERROR: diff failed (rc=$rc), retrying next cycle"
     fi
     sleep "$INTERVAL"
   done
   EOF
   chmod +x reconcile.sh
   ```

2. Run it in one terminal and leave it running:

   ```bash
   ./reconcile.sh
   ```

3. In a **second terminal**, attack the live state (simulate a hotfixing human or a failing node):

   ```bash
   kubectl scale deploy web --replicas=5
   kubectl get deploy web -w
   ```

   Expected: within one interval, the first terminal prints `drift detected — reconciling` and the watch shows replicas return to 2 without any human action:

   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    5/5     5            5           9m
   web    2/5     2            2           9m
   web    2/2     2            2           9m
   ```

4. Now change the state *the correct way* — through Git — and watch the same loop deliver it:

   ```bash
   cd ~/cgoa-lab
   sed -i 's/replicas: 2/replicas: 3/' desired/deployment.yaml
   git commit -am "web: scale to 3"
   ```

   Expected: the reconciler picks it up within one cycle. Deployment and rollback are now *the same mechanism* — a commit.

5. Note what your reconciler **cannot** do (this is why real tools exist): it never deletes objects removed from Git (no pruning), applies in file order (no dependency ordering or health gating), reports state only to stdout (no status API), and clones with your personal credentials (no identity separation).

**Check your understanding**

- **Q3.1** — Your loop is level-triggered: it compares full desired vs. live state every cycle. An edge-triggered design would instead react to individual change events. What failure mode does level-triggering survive that edge-triggering does not?
- **Q3.2** — Step 3 demonstrated automatic drift correction. Name the two *sources* of drift this protects against in production, and explain why "nobody has cluster write access" does not make the loop unnecessary.
- **Q3.3** — In step 1 the script comment says a production reconciler pulls from a remote. Where does the reconciler run and where do the cluster credentials live in this model, compared to a CI pipeline that runs `kubectl apply` from GitHub Actions? Why is this the security argument for *pull-based* GitOps?

Stop the reconciler with `Ctrl-C` before Exercise 4.

---

## Exercise 4 — The same loop, production-grade: Argo CD

Argo CD implements the loop you just wrote as a set of controllers, with the `Application` CRD as *desired state about desired state*: a declarative record of "which repo, which path, which revision, into which cluster" ([https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)).

1. Install Argo CD and wait for it to converge:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd wait deploy --all --for=condition=Available --timeout=300s
   ```

   Expected final lines:

   ```
   deployment.apps/argocd-repo-server condition met
   deployment.apps/argocd-server condition met
   ```

2. Register an application **declaratively** — an `Application` is itself a Kubernetes object you could (and in production, would) store in Git:

   ```bash
   cat > app-guestbook.yaml <<'EOF'
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: guestbook
     syncPolicy:
       syncOptions:
       - CreateNamespace=true
   EOF
   kubectl apply -f app-guestbook.yaml
   ```

3. Observe the two orthogonal status axes Argo CD computes:

   ```bash
   kubectl -n argocd get application guestbook
   ```

   Expected output:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   OutOfSync     Missing
   ```

   `OutOfSync` = Git and cluster differ (your reconciler's `rc=1`). `Missing`/`Healthy` is a separate judgment: is the *live* workload actually working? Your bash loop had no equivalent.

4. No `automated` policy is set, so Argo CD detects drift but waits for a human — GitOps with a manual gate. Trigger the sync decl
aratively:

   ```bash
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   sleep 20
   kubectl -n argocd get application guestbook
   kubectl -n guestbook get deploy
   ```

   Expected output:

   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   Synced        Healthy
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           25s
   ```

**Check your understanding**

- **Q4.1** — The `Application` object never contains the guestbook's Deployment manifest. What does it contain instead, and why does that indirection make the whole delivery system recoverable from scratch (`kubectl apply -f app-guestbook.yaml` on an empty cluster)?
- **Q4.2** — Explain the difference between `SYNC STATUS` and `HEALTH STATUS` with a concrete scenario in which an app is `Synced` but `Degraded`.
- **Q4.3** — In step 4 the app was `OutOfSync` and Argo CD did nothing. Which of the four OpenGitOps principles was the system *not yet* fulfilling, and which spec field turns it on?

---

## Exercise 5 — Continuous reconciliation: self-heal and prune

1. Enable full automation — this is Principle 4 as configuration:

   ```bash
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

   The resulting policy block, as it would live in Git:

   ```yaml
   syncPolicy:
     automated:
       prune: true      # objects removed from Git are removed from the cluster
       selfHeal: true   # drift in live state is reverted without a new commit
     syncOptions:
     - CreateNamespace=true
   ```

2. Attack the live state twice, and watch the controller win both times:

   ```bash
   kubectl -n guestbook scale deploy guestbook-ui --replicas=3
   sleep 15
   kubectl -n guestbook get deploy guestbook-ui

   kubectl -n guestbook delete deploy guestbook-ui
   sleep 15
   kubectl -n guestbook get deploy guestbook-ui
   ```

   Expected output — replicas back to 1, and the deleted Deployment recreated with a fresh `AGE`:

   ```
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           6m
   NAME           READY   UP-TO-DATE   AVAILABLE   AGE
   guestbook-ui   1/1     1            1           9s
   ```

3. Read the controller's own account of what happened:

   ```bash
   kubectl -n argocd logs statefulset/argocd-application-controller --since=2m \
     | grep -i "guestbook" | grep -iE "sync|drift|apply" | tail -5
   ```

**Check your understanding**

- **Q5.1** — `selfHeal` reverted your manual scale without any new Git commit. What, then, is the *only* legitimate write path to this cluster now, and what does that imply for emergency "break-glass" procedures?
- **Q5.2** — `prune: true` is the setting teams fear most. Describe the exact accident it enables, and one mechanism (Git-side or Argo-side) that mitigates it while keeping pruning on.
- **Q5.3** — Argo CD's default self-heal reaction is fast (seconds), while your bash loop polled every 5 s and a `git clone` of a large monorepo could take minutes. What architectural component lets a production controller detect *live-state* drift near-instantly without polling the cluster? (Hint: it is the same mechanism `kubectl get -w` uses.)

---

## Exercise 6 — Failure and rollback through Git

A bad change ships. In GitOps the rollback is a commit, and the exercise is proving the loop delivers it. We use the local repo and your bash reconciler, where you control history.

1. Restart your reconciler from Exercise 3 in a second terminal:

   ```bash
   ./reconcile.sh
   ```

2. Ship a broken version — a tag that does not exist:

   ```bash
   cd ~/cgoa-lab
   sed -i 's/nginx:1.27.1/nginx:1.27.99-nonexistent/' desired/deployment.yaml
   git commit -am "web: bump nginx (BROKEN: tag does not exist)"
   ```

3. Observe the failure mode. The reconciler applies successfully — the *API server* accepted the manifest — but the rollout cannot progress:

   ```bash
   sleep 10
   kubectl get pods -l app.kubernetes.io/name=web
   kubectl rollout status deploy/web --timeout=30s
   ```

   Expected output:

   ```
   NAME                  READY   STATUS             RESTARTS   AGE
   web-5f9c7b6d4-x2kkq   0/1     ImagePullBackOff   0          45s
   web-7d4b8c9f6-a1b2c   1/1     Running            0          20m
   web-7d4b8c9f6-d3e4f   1/1     Running            0          20m
   error: timed out waiting for the condition
   ```

   Note the two ReplicaSets: the Deployment's rolling update strategy is still protecting you — old pods keep serving while the new one crash-loops. "Applied" and "healthy" are different claims (this is Argo CD's sync-vs-health distinction from Q4.2, observed in the wild).

4. Roll back with history intact, and let the loop converge:

   ```bash
   git revert --no-edit HEAD
   sleep 10
   kubectl get pods -l app.kubernetes.io/name=web
   git log --oneline | head -3
   ```

   Expected: only `Running` pods on `nginx:1.27.1`, and a history that *shows the incident*:

   ```
   f00dcafe Revert "web: bump nginx (BROKEN: tag does not exist)"
   badc0de1 web: bump nginx (BROKEN: tag does not exist)
   c11b9e0  Revert "web: scale to 3 for launch traffic"
   ```

5. Clean up:

   ```bash
   # Ctrl-C the reconciler, then:
   kind delete cluster --name gitops-lab
   ```

**Check your understanding**

- **Q6.1** — Argo CD offers `argocd app rollback <app> <history-id>`, which re-syncs the cluster to a previously deployed revision. Why is `git revert` still the preferred production rollback, and what does Argo CD do to auto-sync when you use its rollback command instead?
- **Q6.2** — In step 3, every check your bash reconciler performs passed, yet the service was one failed pod away from an outage. Which capability, present in Argo CD and absent in your loop, closes this gap — and at which point in a sync would a production setup act on it?
- **Q6.3** — Write the one-sentence incident-review answer to "how do we prevent the broken tag from shipping again?" that is compatible with GitOps (i.e., the fix lives *before* the merge, not in the cluster).

---

## Reference sources

- OpenGitOps Principles v1.0.0 — [https://opengitops.dev/](https://opengitops.dev/) and [https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md](https://github.com/open-gitops/documents/blob/v1.0.0/PRINCIPLES.md)
- CNCF CGOA Curriculum — [https://github.com/cncf/curriculum](https://github.com/cncf/curriculum)
- Kubernetes: Controllers (level-triggered reconciliation) — [https://kubernetes.io/docs/concepts/architecture/controller/](https://kubernetes.io/docs/concepts/architecture/controller/)
- `kubectl diff` reference (exit-code contract) — [https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/)
- Argo CD documentation: Declarative setup, Automated Sync, Sync/Health status — [https://argo-cd.readthedocs.io/en/stable/](https://argo-cd.readthedocs.io/en/stable/)
- Flux documentation: GitOps concepts (source/reconciliation model) — [https://fluxcd.io/flux/concepts/](https://fluxcd.io/flux/concepts/)

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — You created **drift** (state divergence): the **live state** (4 replicas, observed from the cluster) no longer matched the **desired state** (2 replicas, recorded in the file). GitOps is precisely the discipline of detecting and eliminating this divergence continuously, always in the direction of the declared state.

**A1.2** — `kubectl scale` mutates the live state directly and leaves no record in the source of truth; the change is invisible to review, unversioned, and will be reverted by any reconciler. Editing `replicas:` in the tracked file changes the *desired* state, which is reviewable, versioned, and is what agents converge toward. Same pods, opposite direction of authority: in GitOps, authority flows only from declaration to cluster, never backwards.

**A1.3** — A reconciler applies the same state on every cycle, drift or not (or after transient errors, retries). If apply were not idempotent — if re-applying caused restarts, duplicate objects, or errors — continuous reconciliation would be destructive. `unchanged` is the property that makes "apply forever, in a loop" a safe architecture rather than a hazard.

### Exercise 2

**A2.1** — `git revert` creates a **new** commit whose content restores the old state, so history remains append-only and complete: the bad change, the decision to undo it, who and when — all retained. `git reset --hard` + force-push **rewrites** history, destroying the record that the bad state ever existed. Principle 2 requires immutability and *complete version history*; a forged history also breaks every agent and audit process that assumed commits are permanent.

**A2.2** — `git log -p desired/deployment.yaml` (or `git blame` for line-level attribution) shows author, timestamp, and exact diff for each change. It cannot be forged after the fact because each commit's ID is a cryptographic hash of its content *and its parent's ID*: altering any historical commit changes every descendant hash, which is immediately visible to every clone. (Author fields are self-reported, which is why production setups add signed commits — `git commit -S` — and server-side branch protection.)

**A2.3** — The tag (specifically an annotated tag, and by convention never moved) is the immutable version; `main` is a moving pointer. Deploying `HEAD` of `main` means the deployed version changes whenever anyone merges — you cannot state "production runs v1.0.0", only "production runs whatever main was at the last sync", and an unreviewed merge deploys itself. Production systems pin releases to tags or commit SHAs, and promotion between environments is an explicit change of that pin.

### Exercise 3

**A3.1** — A **missed or lost event**. Edge-triggered systems act only when they observe a change notification; if the watcher is down when the event fires (crash, network partition, webhook lost), the change is never processed and the system stays wrong forever. A level-triggered loop recomputes the full desired-vs-live comparison every cycle, so any missed change is caught on the next pass — the design is self-correcting after arbitrary downtime. This is why both Kubernetes controllers and GitOps agents are level-based.

**A3.2** — (1) **Human drift**: manual `kubectl` hotfixes, debugging edits, well-meaning tweaks that never make it back to Git. (2) **System drift**: controllers, admission webhooks, operators, or failures mutating/deleting objects (evictions, namespace cleanup jobs, a colleague's operator fighting over a field). Removing human write access eliminates only source (1); the cluster itself keeps changing state, so continuous reconciliation remains necessary.

**A3.3** — In pull mode the reconciler runs **inside the cluster** (or its trust boundary) and cluster credentials never leave it; the only outbound requirement is read access to Git. In push mode, a CI system *outside* the cluster holds admin-level kubeconfig/credentials, meaning: a CI compromise is a cluster compromise, credentials for every environment accumulate in the CI secret store, and the cluster must expose its API to the CI network. Pull inverts the trust: Git holds no secrets that can write to the cluster, and the attack surface shrinks to "can you get a malicious commit merged" — which is exactly the gate code review already defends.

### Exercise 4

**A4.1** — It contains a **pointer**: repo URL, path, target revision, and destination — desired state *about* where desired state lives. Because both layers are declarative, the entire delivery system is reconstructible from Git alone: apply the Application (or an "app-of-apps" root that lists all Applications), and Argo CD re-pulls and re-creates everything beneath it. Disaster recovery becomes `git clone` + one `kubectl apply`, which is the practical payoff of Principles 1+2 applied recursively.

**A4.2** — `SYNC STATUS` compares Git manifests against live objects: are they identical? `HEALTH STATUS` evaluates whether the live resources are actually functioning (Deployment progressing, replicas available, Ingress admitted, PVC bound). Concrete `Synced` + `Degraded` scenario: you commit an image tag that doesn't exist. Argo CD applies the Deployment perfectly — Git and cluster match, so `Synced` — but pods sit in `ImagePullBackOff`, replicas never become available, and the health assessment reports `Degraded`. Exercise 6 step 3 is this exact case.

**A4.3** — Principle 4, **continuously reconciled** — the system observed and *reported* drift but did not act on it (and arguably Principle 3's "automatically pulled and applied" is only half-fulfilled). The field is `spec.syncPolicy.automated` (with `selfHeal: true` extending automation to live-state drift, not just new commits). Until it is set, Argo CD is a drift *detector* with a manual gate — a legitimate stepping-stone configuration, but not full GitOps automation.

### Exercise 5

**A5.1** — The only legitimate write path is **a merged commit to the tracked repository**. Kubectl-level changes are now cosmetic-until-reverted. Break-glass therefore has to be designed, not improvised: either an explicit procedure to pause reconciliation for the affected app (disable `selfHeal`/automation, act, then re-commit the fix and re-enable), or an expedited merge path for emergencies. A team that enables `selfHeal` without a documented break-glass procedure discovers it at 03:00 when the controller keeps reverting their mitigation.

**A5.2** — The accident: a refactor (moving/renaming a path, a faulty Kustomize/Helm render, an accidental deletion of a directory) makes objects disappear from the rendered output, and prune **deletes the live resources** — including, in the worst case, stateful ones. Mitigations that keep pruning on: Git-side, mandatory review + CI that renders manifests and diffs object counts before merge; Argo-side, protect critical resources with the `Prune=false` sync option or the `argocd.argoproj.io/sync-options: Prune=false` annotation on specific objects, so the blast radius of a bad render excludes them.

**A5.3** — The Kubernetes **watch API** (the informer/shared-cache machinery built on it). The application controller keeps watches open on managed resource kinds, so any mutation to a live object arrives as a push event within milliseconds, triggering re-evaluation — no cluster polling. Git, which has no equivalent push channel by default, is still polled (default every 3 minutes) or accelerated with webhooks. Note the architecture is watch-*triggered* but still level-*based*: the event only schedules a full desired-vs-live comparison, preserving the resilience from A3.1.

### Exercise 6

**A6.1** — `argocd app rollback` makes the cluster run a state that **Git no longer declares** — truth has forked: the repo says one thing, production runs another, and every property GitOps promised (single source of truth, audit-by-history, reproducibility) is suspended until they re-converge. Argo CD knows this, which is why rollback to a previous deployment **disables automated sync** on the app (it must, or the automation would immediately re-deploy the bad revision). It is an emergency lever. `git revert` keeps truth and cluster unified and needs no special mode — the rollback *is* an ordinary deployment.

**A6.2** — **Health assessment integrated into the sync process.** Argo CD evaluates per-resource health (Deployment progress, replica availability, plus custom health checks in Lua for CRDs) and reports `Degraded` even while `Synced`. A production setup acts on it inside **sync phases/waves and hooks**: resources sync in ordered waves, and a wave that fails health gates stops the rollout of subsequent waves; combined with a progressive-delivery controller (e.g. Argo Rollouts), a failed analysis automatically aborts and reverts the rollout. Your bash loop's contract ended at "the API server accepted it".

**A6.3** — "Add a pre-merge CI check that resolves every container image reference in the rendered manifests against the registry (tag exists, digest pinned), so a nonexistent tag fails the pull request instead of the rollout." — The GitOps-compatible prevention always strengthens the gate in front of the source of truth; by the time state reaches the cluster, agents deploy it without judgment.

</details>