# Guided Exercises — Topic 1.2: DevOps Practices and Culture in Platform Engineering

> **Exam weight:** 7.2 % · **Certification:** CNPA (2025-04-01)
> These exercises turn the cultural principles of DevOps — automation over toil, everything as code, fast feedback loops, blameless learning, and team interaction design — into things you execute and measure. A platform team does not "have" a culture; it encodes one into its repositories, pipelines, and incident practices. That is what you will build here.

## Prerequisites

- Linux/macOS shell with `git`, `curl`, `docker`
- [`kind`](https://kind.sigs.k8s.io/) ≥ 0.23 and `kubectl` ≥ 1.30
- ~2 GB free RAM for the local cluster

Create the lab cluster once; Exercises 1 and 5 use it:

```bash
kind create cluster --name cnpa-12
```

Expected output:

```
Creating cluster "cnpa-12" ...
 ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-cnpa-12"
```

---

## Exercise 1 — Quantify toil, then automate it away

The SRE definition of **toil** is work that is manual, repetitive, automatable, tactical, and scales linearly with growth ([https://sre.google/sre-book/eliminating-toil/](https://sre.google/sre-book/eliminating-toil/)). Team onboarding is the classic platform example. You will do it the ticket-ops way first, feel why it does not scale, then replace it with a declarative, idempotent bundle.

1. Simulate the "ticket arrives, operator types commands" flow, and time it:

   ```bash
   time (
     kubectl create namespace team-checkout
     kubectl label namespace team-checkout team=checkout cost-center=cc-1042
     kubectl create quota team-checkout-quota -n team-checkout \
       --hard=requests.cpu=4,requests.memory=8Gi,pods=20
   )
   ```

   ```
   namespace/team-checkout created
   namespace/team-checkout labeled
   resourcequota/team-checkout-quota created

   real    0m1.284s
   ```

2. A second operator, unaware the ticket was already handled, runs the same commands. Re-run step 1 and observe:

   ```
   Error from server (AlreadyExists): namespaces "team-checkout" already exists
   ```

   The imperative sequence is **not idempotent**: it cannot be safely retried, so every execution needs a human to interpret the outcome.

3. Delete the manual result and rebuild it as a declarative bundle:

   ```bash
   kubectl delete namespace team-checkout
   mkdir -p onboarding
   cat > onboarding/team-checkout.yaml <<'EOF'
   apiVersion: v1
   kind: Namespace
   metadata:
     name: team-checkout
     labels:
       team: checkout
       cost-center: cc-1042
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-checkout-quota
     namespace: team-checkout
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       pods: "20"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: team-checkout-defaults
     namespace: team-checkout
   spec:
     limits:
       - type: Container
         default:
           cpu: 500m
           memory: 256Mi
         defaultRequest:
           cpu: 100m
           memory: 128Mi
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: team-checkout
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   EOF
   kubectl apply -f onboarding/team-checkout.yaml
   ```

   ```
   namespace/team-checkout created
   resourcequota/team-checkout-quota created
   limitrange/team-checkout-defaults created
   networkpolicy.networking.k8s.io/default-deny-ingress created
   ```

4. Run the **same** command again:

   ```bash
   kubectl apply -f onboarding/team-checkout.yaml
   ```

   ```
   namespace/team-checkout unchanged
   resourcequota/team-checkout-quota unchanged
   limitrange/team-checkout-defaults unchanged
   networkpolicy.networking.k8s.io/default-deny-ingress unchanged
   ```

5. Onboard a second team in seconds — the marginal cost of automation is near zero:

   ```bash
   sed 's/team-checkout/team-payments/g; s/checkout/payments/g; s/cc-1042/cc-2077/g' \
     onboarding/team-checkout.yaml > onboarding/team-payments.yaml
   kubectl apply -f onboarding/team-payments.yaml
   ```

**Q1.1** — What property, demonstrated in step 4, makes the declarative bundle safe to run from an unattended pipeline, and why does the imperative sequence in step 2 lack it?

**Q1.2** — Name the five characteristics of toil per the Google SRE book, and identify which of them the manual onboarding flow exhibits.

**Q1.3** — In the CALMS model (Culture, Automation, Lean, Measurement, Sharing), which two pillars does this exercise directly address, and how?

---

## Exercise 2 — Everything as Code and the pull-request contract

"Everything as code" is not a storage decision; it is a **collaboration protocol**. Putting platform configuration in Git means every change gets an author, a reviewer, a timestamp, and an undo button. You will build the platform repository and run one change through the review flow.

1. Create the repository and move the onboarding bundle into it:

   ```bash
   mkdir platform-repo && cd platform-repo && git init -q -b main
   mkdir -p onboarding docs .github
   cp ../onboarding/team-checkout.yaml onboarding/
   ```

2. Declare ownership so review is routed automatically, not by tribal knowledge:

   ```bash
   cat > .github/CODEOWNERS <<'EOF'
   onboarding/**  @org/platform-team
   docs/**        @org/platform-team @org/tech-writers
   EOF
   git add . && git commit -qm "chore: bootstrap platform repository"
   ```

3. The checkout team needs more CPU. Make the change on a branch — never on `main`:

   ```bash
   git switch -c change/raise-checkout-quota
   sed -i 's/requests.cpu: "4"/requests.cpu: "6"/' onboarding/team-checkout.yaml
   git commit -aqm "feat(onboarding): raise checkout CPU quota to 6 cores"
   ```

4. Simulate the reviewed merge (in a forge this is the pull request; `--no-ff` preserves the review boundary as a merge commit):

   ```bash
   git switch main
   git merge --no-ff -m "merge: raise checkout quota (reviewed by @org/platform-team)" \
     change/raise-checkout-quota
   git log --oneline --graph
   ```

   ```
   *   9f3c2ab merge: raise checkout quota (reviewed by @org/platform-team)
   |\
   | * 4e81d07 feat(onboarding): raise checkout CPU quota to 6 cores
   |/
   * 1a2b3c4 chore: bootstrap platform repository
   ```

5. Prove the undo button exists — revert the entire reviewed change as one atomic unit, then restore it:

   ```bash
   git revert --no-edit -m 1 HEAD
   git log --oneline -1
   git revert --no-edit HEAD   # put the change back for later exercises
   ```

**Q2.1** — List three concrete capabilities the Git-based flow provides that the "operator types kubectl at the cluster" model from Exercise 1 cannot provide.

**Q2.2** — In Team Topologies terms, what interaction mode does a CODEOWNERS-routed review implement between a stream-aligned team requesting quota and the platform team, and why does the platform team review the *what* (the diff) rather than performing the *how* (typing commands)?

**Q2.3** — Why is `git revert` of the merge commit operationally safer than an operator "fixing it by hand" in the cluster?

---

## Exercise 3 — Shift-left: fail in seconds, not in production

The Second Way of DevOps is **amplifying feedback loops** ([https://itrevolution.com/articles/the-three-ways-principles-underpinning-devops/](https://itrevolution.com/articles/the-three-ways-principles-underpinning-devops/)). The cost of a defect grows with every stage it survives: seconds on the laptop, minutes in CI, an incident in production. You will move two classes of failure — invalid schema and policy violation — to the earliest possible point: the commit.

1. Install the validators (still inside `platform-repo`):

   ```bash
   curl -sL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz kubeconform
   curl -sL https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_x86_64.tar.gz | tar xz conftest
   sudo mv kubeconform conftest /usr/local/bin/
   kubeconform -v && conftest --version
   ```

2. Author a Deployment with two production-grade defects — a type error and a `:latest` tag:

   ```bash
   mkdir -p deploy
   cat > deploy/checkout.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: checkout
     namespace: team-checkout
   spec:
     replicas: "three"
     selector:
       matchLabels:
         app: checkout
     template:
       metadata:
         labels:
           app: checkout
       spec:
         containers:
           - name: web
             image: nginx:latest
   EOF
   ```

3. Schema validation catches the type error without touching any cluster:

   ```bash
   kubeconform -strict -summary deploy/checkout.yaml
   ```

   ```
   deploy/checkout.yaml - Deployment checkout is invalid: problem validating schema. Check JSON formatting: jsonschema: '/spec/replicas' does not validate with ...: expected integer or null, but got string
   Summary: 1 resource found in 1 file - Valid: 0, Invalid: 1, Errors: 0, Skipped: 0
   ```

   Fix it: `sed -i 's/replicas: "three"/replicas: 3/' deploy/checkout.yaml`

4. Encode organizational rules as **policy as code** with OPA/conftest ([https://www.conftest.dev/](https://www.conftest.dev/)):

   ```bash
   mkdir -p policy
   cat > policy/deployment.rego <<'EOF'
   package main

   import rego.v1

   deny contains msg if {
   	input.kind == "Deployment"
   	some container in input.spec.template.spec.containers
   	endswith(container.image, ":latest")
   	msg := sprintf("container '%s' uses the ':latest' tag; pin an immutable version", [container.name])
   }

   deny contains msg if {
   	input.kind == "Deployment"
   	some container in input.spec.template.spec.containers
   	not container.resources.limits
   	msg := sprintf("container '%s' declares no resource limits", [container.name])
   }
   EOF
   conftest test deploy/checkout.yaml
   ```

   ```
   FAIL - deploy/checkout.yaml - main - container 'web' uses the ':latest' tag; pin an immutable version
   FAIL - deploy/checkout.yaml - main - container 'web' declares no resource limits

   2 tests, 0 passed, 0 warnings, 2 failures, 0 exceptions
   ```

5. Wire both checks into a pre-commit hook — the shortest possible feedback loop:

   ```bash
   cat > .git/hooks/pre-commit <<'EOF'
   #!/usr/bin/env bash
   set -euo pipefail
   files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.ya?ml$' || true)
   [ -z "$files" ] && exit 0
   kubeconform -strict -summary $files
   conftest test $files
   EOF
   chmod +x .git/hooks/pre-commit
   git add deploy/ policy/ && git commit -m "feat(deploy): checkout service"
   ```

   The commit is **blocked** by the conftest failures. Now fix the manifest and commit again:

   ```bash
   cat > deploy/checkout.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: checkout
     namespace: team-checkout
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: checkout
     template:
       metadata:
         labels:
           app: checkout
       spec:
         containers:
           - name: web
             image: nginx:1.27.0
             resources:
               requests:
                 cpu: 100m
                 memory: 64Mi
               limits:
                 cpu: 250m
                 memory: 128Mi
   EOF
   git add deploy/ && git commit -m "feat(deploy): checkout service"
   ```

   ```
   Summary: 1 resource found in 1 file - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
   2 tests, 2 passed, 0 warnings, 0 failures, 0 exceptions
   [main 7d1e0f2] feat(deploy): checkout service
   ```

**Q3.1** — Order these four detection points by feedback-loop length and by blast radius: cluster admission webhook, production incident, CI pipeline, pre-commit hook. Why does a mature platform run the *same* policies at more than one of these points?

**Q3.2** — Why is a Rego policy in the repository culturally superior to the same rule written on a wiki page titled "Deployment standards"?

**Q3.3** — The pre-commit hook lives in `.git/hooks/`, which is not versioned or shared. What does a platform team ship instead so every engineer — and CI — runs identical checks?

---

## Exercise 4 — Measure your delivery: DORA metrics from the repository itself

DORA research ([https://dora.dev/](https://dora.dev/)) established four keys: **deployment frequency** and **lead time for changes** (throughput), **change failure rate** and **failed deployment recovery time** (stability). You cannot improve a feedback loop you do not measure. You will build a controlled Git history and compute two of the four directly from it.

1. Create a repository with deterministic timestamps (so your numbers match the answers):

   ```bash
   cd .. && mkdir dora-lab && cd dora-lab && git init -q -b main
   export GIT_AUTHOR_DATE="2026-08-03T09:00:00" GIT_COMMITTER_DATE="2026-08-03T09:00:00"
   echo v1 > app.txt && git add . && git commit -qm "feat: add checkout button"
   export GIT_AUTHOR_DATE="2026-08-03T15:00:00" GIT_COMMITTER_DATE="2026-08-03T15:00:00"
   git tag -a deploy-1 -m "deploy to production"
   export GIT_AUTHOR_DATE="2026-08-04T10:00:00" GIT_COMMITTER_DATE="2026-08-04T10:00:00"
   echo v2 > app.txt && git commit -aqm "fix: null price on empty cart"
   export GIT_AUTHOR_DATE="2026-08-05T11:00:00" GIT_COMMITTER_DATE="2026-08-05T11:00:00"
   echo v3 > app.txt && git commit -aqm "feat: gift cards"
   export GIT_AUTHOR_DATE="2026-08-05T16:00:00" GIT_COMMITTER_DATE="2026-08-05T16:00:00"
   git tag -a deploy-2 -m "deploy to production"
   unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
   ```

2. **Deployment frequency** — deployments in the observed window (one work-week here):

   ```bash
   git tag -l 'deploy-*' | wc -l
   ```

   ```
   2
   ```

3. **Lead time for changes** — for every commit, time from commit to the deploy that shipped it:

   ```bash
   prev=""
   for tag in deploy-1 deploy-2; do
     deploy_ts=$(git for-each-ref --format='%(taggerdate:unix)' "refs/tags/$tag")
     range=$([ -n "$prev" ] && echo "$prev..$tag" || echo "$tag")
     for c in $(git rev-list $range); do
       commit_ts=$(git log -1 --format=%at "$c")
       printf '%s  %-32s lead_h=%d\n' "$tag" "$(git log -1 --format=%s "$c")" \
         $(( (deploy_ts - commit_ts) / 3600 ))
     done
     prev=$tag
   done
   ```

   ```
   deploy-1  feat: add checkout button        lead_h=6
   deploy-2  feat: gift cards                 lead_h=5
   deploy-2  fix: null price on empty cart    lead_h=30
   ```

4. Compute the median lead time by hand from those three values, then answer Q4.2 about what a naive "time between last commit and deploy" script would have reported instead.

**Q4.1** — Match each of the four DORA metrics to throughput or stability, and state which two this exercise measured.

**Q4.2** — A simpler script that only measures the *newest* commit per deploy would report lead times of 6 h and 5 h. Which real value does it hide, what batching behavior does that value reveal, and which DevOps principle (First Way) does the hidden value violate?

**Q4.3** — Why should a platform team track these metrics for the teams *using* the platform, and what is the danger of using them as individual performance targets? (Goodhart's law is relevant.)

---

## Exercise 5 — Break, restore, and write the blameless postmortem

Blameless postmortem culture ([https://sre.google/sre-book/postmortem-culture/](https://sre.google/sre-book/postmortem-culture/)) holds that "human error" is never a root cause — it is a symptom of a system that allowed the error to reach production. You will cause a realistic failed deployment, recover, and convert the incident into systemic action items.

1. Deploy the good manifest from Exercise 3 and confirm health:

   ```bash
   kubectl apply -f ../platform-repo/deploy/checkout.yaml
   kubectl -n team-checkout rollout status deployment/checkout
   ```

   ```
   deployment "checkout" successfully rolled out
   ```

2. Record the incident start time, then ship a bad image tag (a one-character typo — exactly what the Exercise 3 policies do *not* catch, since `nginx:1.99` is well-formed):

   ```bash
   date -u +%H:%M:%SZ   # note this as T0
   kubectl -n team-checkout set image deployment/checkout web=nginx:1.99
   kubectl -n team-checkout get pods
   ```

   ```
   NAME                        READY   STATUS             RESTARTS   AGE
   checkout-5f6d8b9c77-2xkqp   1/1     Running            0          3m
   checkout-5f6d8b9c77-8wnzt   1/1     Running            0          3m
   checkout-5f6d8b9c77-l4vrd   1/1     Running            0          3m
   checkout-7c9f4d5b66-qm2ns   0/1     ImagePullBackOff   0          25s
   ```

   Note what did **not** happen: the three old pods are still `Running`. The RollingUpdate strategy refused to remove healthy capacity before new capacity became ready.

3. Diagnose with the standard triage pair:

   ```bash
   kubectl -n team-checkout describe pod -l app=checkout | grep -A3 'Events:' | head -8
   kubectl -n team-checkout rollout status deployment/checkout --timeout=30s
   ```

   ```
   error: timed out waiting for the condition
   ```

4. Recover, and record T1 when the rollout completes:

   ```bash
   kubectl -n team-checkout rollout undo deployment/checkout
   kubectl -n team-checkout rollout status deployment/checkout
   date -u +%H:%M:%SZ   # T1; T1 - T0 is your failed deployment recovery time
   ```

   ```
   deployment.apps/checkout rolled back
   deployment "checkout" successfully rolled out
   ```

5. Write the postmortem — the artifact that turns an incident into organizational learning:

   ```bash
   cat > ../platform-repo/docs/pm-2026-08-06-checkout-imagepull.md <<'EOF'
   # Postmortem: checkout rollout failure (ImagePullBackOff)

   - **Date:** 2026-08-06 · **Duration:** T0→T1 (~4 min) · **Severity:** SEV-3
   - **User impact:** none — RollingUpdate kept previous ReplicaSet serving.

   ## Timeline
   - T0: image `nginx:1.99` rolled out; new pods enter ImagePullBackOff.
   - T0+2m: rollout status timeout alerts the on-call engineer.
   - T0+4m: `kubectl rollout undo` restores previous ReplicaSet.

   ## Root cause
   A syntactically valid but nonexistent image tag passed schema and policy
   checks. No pipeline stage verifies that the image reference is resolvable
   before it reaches the cluster.

   ## What went well
   - Rollout strategy contained the blast radius automatically.
   - Recovery used a standard, rehearsed command.

   ## Action items (systemic, owned, dated)
   - [ ] platform-team, 2026-08-13: add an image-resolvability check
         (crane manifest / registry HEAD) to the CI template.
   - [ ] platform-team, 2026-08-20: set `progressDeadlineSeconds: 120` in the
         golden-path Deployment template so failures alert faster.
   EOF
   ```

**Q5.1** — "The engineer typed the wrong tag" is a true statement. Why does a blameless postmortem still reject it as the root cause, and what does it record instead?

**Q5.2** — Which two DORA metrics did this incident move, and in which direction?

**Q5.3** — Why did users see no downtime, mechanically? Name the Deployment fields that control this behavior and their defaults.

**Q5.4** — One proposed action item was "remind engineers to double-check image tags." Explain, using the hierarchy of hazard controls or the Second Way, why both items actually written in the postmortem are stronger.

---

## Exercise 6 — Classify the interaction: from collaboration to X-as-a-Service (paper exercise)

Team Topologies ([https://teamtopologies.com/key-concepts](https://teamtopologies.com/key-concepts)) and the CNCF Platforms White Paper ([https://tag-app-delivery.cncf.io/whitepapers/platforms/](https://tag-app-delivery.cncf.io/whitepapers/platforms/)) frame a platform as a **product** whose purpose is reducing the cognitive load of stream-aligned teams. No cluster needed — classify each scenario as **collaboration**, **X-as-a-Service**, or **facilitating**:

1. The platform team pairs with the payments team for two sprints to co-design the first version of a PCI-scoped CI template neither team fully understands yet.
2. Any team provisions a namespace by opening a PR that adds a file like `onboarding/team-*.yaml` (your Exercise 2 flow); merge triggers apply; no platform engineer is involved per-request.
3. A platform SRE embeds with the search team for three weeks to coach them on writing SLOs, then leaves; the search team owns its SLOs afterward.
4. Every deployment to production requires a platform engineer to review the manifests in a synchronous meeting, indefinitely, "because they know the standards."

**Q6.1** — Classify scenarios 1–3 and justify each in one sentence.

**Q6.2** — Scenario 4 fits none of the three modes healthily. What is it, why does it not scale, and which exercise in this lab shows the mechanism that replaces it?

**Q6.3** — Using the CNCF Platform Engineering Maturity Model ([https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/)), describe the expected evolution of scenario 1 over time along the "Interfaces" aspect.

---

## Cleanup

```bash
kind delete cluster --name cnpa-12
cd .. && rm -rf platform-repo dora-lab onboarding
```

## References

- CNPA Curriculum — [https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)
- CNCF Platforms White Paper — [https://tag-app-delivery.cncf.io/whitepapers/platforms/](https://tag-app-delivery.cncf.io/whitepapers/platforms/)
- CNCF Platform Engineering Maturity Model — [https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/](https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/)
- DORA research program — [https://dora.dev/](https://dora.dev/)
- Google SRE Book: Eliminating Toil / Postmortem Culture — [https://sre.google/sre-book/eliminating-toil/](https://sre.google/sre-book/eliminating-toil/), [https://sre.google/sre-book/postmortem-culture/](https://sre.google/sre-book/postmortem-culture/)
- The Three Ways — [https://itrevolution.com/articles/the-three-ways-principles-underpinning-devops/](https://itrevolution.com/articles/the-three-ways-principles-underpinning-devops/)
- Team Topologies key concepts — [https://teamtopologies.com/key-concepts](https://teamtopologies.com/key-concepts)
- kubeconform — [https://github.com/yannh/kubeconform](https://github.com/yannh/kubeconform) · conftest — [https://www.conftest.dev/](https://www.conftest.dev/)

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — **Idempotency.** `kubectl apply` computes a diff between desired state (the file) and actual state (the cluster) and converges them; applying an already-satisfied state is a no-op (`unchanged`), so a pipeline can retry blindly after any interruption. The imperative sequence encodes *actions* rather than *state*: `kubectl create` asserts "this does not exist yet," which is false on the second run, so it fails with `AlreadyExists` and requires human judgment to distinguish "already done" from "genuinely broken."

**A1.2** — Toil is **manual, repetitive, automatable, tactical (interrupt-driven), devoid of enduring value, and scales linearly (O(n)) with service growth** — the SRE book lists these six traits. Manual onboarding exhibits all of them: an operator types it (manual), every new team triggers it again (repetitive, linear scaling), a YAML bundle replaces it entirely (automatable), it arrives as a ticket interrupt (tactical), and the cluster is no better afterward than the automated path would leave it (no enduring value).

**A1.3** — **Automation** (the ticket flow became a re-runnable artifact) and **Lean** (eliminating wait states and handoffs: the ticket queue, the operator's availability, and the "was it already done?" verification step are all waste in Lean terms — waiting, motion, and defects). One could argue Measurement too, since `time` quantified the baseline, but the primary pillars are Automation and Lean.

### Exercise 2

**A2.1** — Any three of: (1) **audit trail** — every change has an author, timestamp, and reviewer, satisfying compliance without extra tooling; (2) **peer review before effect** — defects are caught pre-merge instead of post-incident; (3) **atomic revertability** — `git revert` undoes an entire reviewed change as a unit; (4) **reproducibility** — the repository *is* the desired state, so a new cluster can be rebuilt from it; (5) **asynchronous collaboration** — requester and approver need not be online simultaneously, unlike a ticket handoff or a shared terminal.

**A2.2** — It is the **X-as-a-Service** interaction mode: the stream-aligned team consumes onboarding as a self-service product (a PR against a documented contract), and the platform team's involvement is bounded to an asynchronous review. The platform team reviews the *what* because the *how* is already automated and idempotent (Exercise 1); if platform engineers executed changes by hand, they would become a synchronous bottleneck and the interaction would degrade into permanent, unscalable collaboration.

**A2.3** — The revert is itself a reviewed, recorded, reproducible change: Git remains the single source of truth, so the cluster and the repository never diverge. A hand-fix in the cluster creates **drift** — the repository now lies about production, the next `apply` silently reintroduces the reverted state, and the fix exists only in one operator's shell history.

### Exercise 3

**A3.1** — Feedback-loop length, shortest to longest: **pre-commit hook (seconds) → CI pipeline (minutes) → admission webhook (at deploy time) → production incident (hours-to-days, discovered by users)**. Blast radius grows in the same order: a blocked commit affects one engineer; a failed pipeline, one team's merge; a rejected admission, one deployment; a production incident, real users. Mature platforms run the same policies at multiple points because each layer has different bypass characteristics: hooks can be skipped (`--no-verify`), CI can be misconfigured, but admission control is unbypassable — so early layers optimize feedback speed while the last layer guarantees enforcement (defense in depth).

**A3.2** — The wiki rule depends on every engineer reading, remembering, and voluntarily applying it — it is advice. The Rego policy is **executable**: it runs identically for everyone, cannot be forgotten, fails loudly with an explanatory message, is versioned and reviewed like any code (so the *rules themselves* go through the PR contract), and updating it updates enforcement everywhere at once. Culturally, it shifts standards from "senior engineers police juniors" to "the system gives everyone the same immediate, impersonal feedback" — which is also what makes blameless culture possible.

**A3.3** — A **versioned hook manager configuration** — typically a `.pre-commit-config.yaml` for the [pre-commit](https://pre-commit.com/) framework (or a committed `hooks/` directory installed via `make setup` / `core.hooksPath`) — plus a CI job that runs the *same* commands. The repository ships the checks; the hook is merely a local accelerator, and CI is the authoritative gate because local hooks are bypassable.

### Exercise 4

**A4.1** — Throughput: **deployment frequency** and **lead time for changes**. Stability: **change failure rate** and **failed deployment recovery time** (historically MTTR). This exercise measured the two throughput metrics: deployment frequency (2 deploys in the window, step 2) and lead time for changes (6 h, 5 h, 30 h; **median = 6 h**, step 3).

**A4.2** — It hides the **30-hour lead time** of `fix: null price on empty cart`, which sat undeployed for more than a day while another feature was batched on top of it. That reveals **large-batch, infrequent deployment behavior**: changes queue and ship together. It violates the **First Way — flow in small batches**: small, frequent deployments shorten lead time, shrink the diff to debug when something breaks, and lower change failure rate. A bug fix waiting 30 hours behind an unrelated feature is precisely the queueing waste the metric exists to expose.

**A4.3** — The platform's product goal is improving its consumers' delivery performance, so the DORA keys of stream-aligned teams are the platform's **outcome metrics** — if the platform is good, *their* lead time drops and *their* deployment frequency rises; measuring the platform team alone measures output, not impact (this is the framing of the CNPA "Measuring your Platform" domain and the CNCF maturity model). The danger: Goodhart's law — "when a measure becomes a target, it ceases to be a good measure." Set as individual targets, the metrics get gamed (empty deploys to inflate frequency, incidents reclassified to protect change failure rate) and, worse, they become blame instruments, destroying the psychological safety that Exercise 5's practice depends on. DORA metrics are team-level capability signals for improvement conversations, not performance-review inputs.

### Exercise 5

**A5.1** — Because "human error" terminates the investigation exactly where learning should begin: it explains one past event but prevents none of the future ones, since some human will always eventually type a wrong tag. Blameless analysis assumes the engineer acted reasonably given the information and tools available, and asks **why the system allowed** a nonexistent image reference to travel from a keyboard to production unverified. The postmortem records the systemic gap — *no pipeline stage checks image resolvability* — which is fixable, testable, and prevents the whole class of error regardless of who types.

**A5.2** — **Change failure rate** worsened (this deployment failed and required remediation — it counts in the numerator), and **failed deployment recovery time** was exercised: T1 − T0, roughly 4 minutes, which is an excellent recovery time and reflects that `rollout undo` is a rehearsed, standard path.

**A5.3** — The Deployment's default strategy is `RollingUpdate` with `maxUnavailable: 25%` and `maxSurge: 25%`. Kubernetes created a *new* ReplicaSet for the bad revision and surged one new pod, but because that pod never passed readiness (stuck in `ImagePullBackOff`), the rollout never progressed to scaling down the old ReplicaSet beyond the `maxUnavailable` allowance — the three healthy pods kept serving. The failure was contained by design: readiness gating plus rolling strategy means "new version broken" degrades to "rollout stuck," not "service down." (`progressDeadlineSeconds`, default 600, is what eventually marks the rollout as failed — which is why the postmortem tightens it to 120.)

**A5.4** — "Remind engineers" is an **administrative control** — the weakest tier of the hierarchy of controls, dependent on memory and vigilance, with effectiveness that decays in weeks. The written action items are **engineering controls** that remove the hazard path itself: the CI resolvability check makes the error mechanically impossible to ship, and the tighter `progressDeadlineSeconds` shortens the feedback loop when something novel still slips through (Second Way). Good action items share three properties both of these have and the reminder lacks: they change the *system*, they have an owner and a date, and their completion is verifiable.

### Exercise 6

**A6.1** —
1. **Collaboration** — two teams working jointly, with high communication bandwidth, on a problem neither can solve alone; correct for discovery, and explicitly time-boxed (two sprints).
2. **X-as-a-Service** — the capability is consumed through a self-service, documented interface with no per-request human involvement; the platform team maintains the product, not each transaction.
3. **Facilitating** — the platform SRE transfers capability and deliberately exits; the outcome is the search team's increased autonomy, not a deliverable the SRE owns.

**A6.2** — It is an unbounded **handoff/gate** — collaboration's communication cost made permanent, without its discovery payoff (sometimes called a ticket-driven or approval-driven anti-pattern). It cannot scale because platform engineers' synchronous time grows linearly with deployment count, so it caps the organization's deployment frequency at the platform team's calendar, and it concentrates knowledge instead of spreading it. Exercise 3 shows the replacement mechanism: the reviewers' standards encoded as policy as code, executed automatically at commit, CI, and admission — the review still happens, but by software, in seconds, for everyone.

**A6.3** — Along the **Interfaces** aspect, the maturity model describes evolution from bespoke, high-touch interaction toward standardized self-service. Scenario 1 should follow it: the collaboration phase produces a working, co-designed CI template (custom/manual today); the platform team then hardens it into a documented, versioned golden-path template that any team can adopt without pairing (self-service consumption); later maturity adds discoverability and integration — the template surfaced in a portal or CLI, with policy checks and provenance built in — so what began as two teams pairing ends as an X-as-a-Service product, and the collaboration bandwidth is freed for the next unknown problem. If the pairing never ends, that is the maturity model's signal that the interface failed to productize.

</details>