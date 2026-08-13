# KCA — Topic 3.1: `apply` (Kyverno CLI)

## Guided Exercises

The `kyverno apply` command evaluates one or more Kyverno policies against one or more resources and reports the outcome as five result categories: **pass**, **fail**, **warn**, **error**, **skip**. It runs **offline** by default (no cluster, no admission controller, no kubeconfig required), which makes it the primary tool for testing policies in CI pipelines, pre-commit hooks, and local development. It can also run **against a live cluster** with `--cluster`.

These exercises assume a Unix shell and the Kyverno CLI (`kyverno`) on your `PATH`. No Kubernetes cluster is needed except where explicitly noted.

> **A note on the policy schema used below.** Since Kyverno 1.11 the validation action lives on the rule, at `spec.rules[].validate.failureAction` (values `Enforce` / `Audit`). The older `spec.validationFailureAction` still works but is deprecated. All examples use the modern per-rule form.
>
> **A note on CLI output.** The exact wording and the box-drawing of the table renderer drift slightly between CLI releases. The **stable contract you are graded on** is the five result categories and the **process exit code** — treat those as authoritative, not the surrounding decoration.

---

### Exercise 0 — Setup and sanity check

1. Confirm the CLI is installed and print its version:

   ```bash
   kyverno version
   ```

   Expected (version numbers will differ):

   ```
   Version: v1.13.2
   Time: 2026-01-14T09:22:01Z
   Git commit ID: a1b2c3d
   ```

2. Create a working directory with two subfolders, one for policies and one for resources:

   ```bash
   mkdir -p kca-apply/policies kca-apply/resources
   cd kca-apply
   ```

3. Create the first policy, `policies/require-team-label.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     background: false
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Enforce
           message: "The label 'team' is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

4. Create two resources. `resources/pod-good.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-good
     labels:
       team: payments
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
   ```

   `resources/pod-bad.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-bad
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
   ```

**Comprehension checkpoint**

- **Q0.1** — Does `kyverno apply` need a running cluster or a valid kubeconfig to evaluate these files?
- **Q0.2** — In the pattern `team: "?*"`, what does `?*` assert, and how does it differ from `"*"`?

---

### Exercise 1 — A single policy against a single resource

1. Apply the policy to the compliant Pod:

   ```bash
   kyverno apply policies/require-team-label.yaml --resource resources/pod-good.yaml
   echo "exit code: $?"
   ```

   Expected:

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   exit code: 0
   ```

2. Apply the same policy to the non-compliant Pod:

   ```bash
   kyverno apply policies/require-team-label.yaml --resource resources/pod-bad.yaml
   echo "exit code: $?"
   ```

   Expected:

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   policy require-team-label -> resource default/Pod/web-bad failed:
   1. check-team-label: validation error: The label 'team' is required on every Pod. rule check-team-label failed at path /metadata/labels/team/

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

3. Apply the policy to **both** resources in one invocation (the `--resource` / `-r` flag is repeatable):

   ```bash
   kyverno apply policies/require-team-label.yaml \
     -r resources/pod-good.yaml \
     -r resources/pod-bad.yaml
   echo "exit code: $?"
   ```

   Expected summary:

   ```
   pass: 1, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

**Comprehension checkpoint**

- **Q1.1** — What is the process exit code when at least one resource fails, and why does this single fact make `kyverno apply` usable as a CI gate?
- **Q1.2** — `web-bad` has no explicit `namespace`, yet the output reports it as `default/Pod/web-bad`. Where did `default` come from?
- **Q1.3** — In step 3, one resource passed and one failed. What determined the overall exit code — the pass, the fail, or the count of each?

---

### Exercise 2 — Directories, multiple policies, and the table renderer

1. Add a second policy, `policies/disallow-latest-tag.yaml`, this one in **Audit** mode:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: disallow-latest-tag
   spec:
     background: false
     rules:
       - name: require-image-tag
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Audit
           message: "Using the mutable ':latest' tag is not allowed."
           pattern:
             spec:
               containers:
                 - image: "!*:latest"
   ```

2. Add a resource that violates the new policy, `resources/pod-latest.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web-latest
     labels:
       team: payments
   spec:
     containers:
       - name: nginx
         image: nginx:latest
   ```

3. Apply **every policy in `policies/`** to **every resource in `resources/`** by passing directories, and render the result as a table:

   ```bash
   kyverno apply policies/ --resource resources/ --table
   echo "exit code: $?"
   ```

   Expected (columns abbreviated):

   ```
   Applying 4 policy rule(s) to 3 resource(s)...

   ┌───┬──────────────────────┬───────────────────┬─────────────────────────┬────────┐
   │ # │ POLICY               │ RULE              │ RESOURCE                │ RESULT │
   ├───┼──────────────────────┼───────────────────┼─────────────────────────┼────────┤
   │ 1 │ require-team-label   │ check-team-label  │ default/Pod/web-good    │ Pass   │
   │ 2 │ require-team-label   │ check-team-label  │ default/Pod/web-bad     │ Fail   │
   │ 3 │ require-team-label   │ check-team-label  │ default/Pod/web-latest  │ Pass   │
   │ 4 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-good    │ Pass   │
   │ 5 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-bad     │ Pass   │
   │ 6 │ disallow-latest-tag  │ require-image-tag │ default/Pod/web-latest  │ Fail   │
   └───┴──────────────────────┴───────────────────┴─────────────────────────┴────────┘

   pass: 4, fail: 2, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

4. For a richer per-result view (including messages), use `--detailed-results` instead of, or together with, `--table`:

   ```bash
   kyverno apply policies/ --resource resources/ --detailed-results
   ```

**Comprehension checkpoint**

- **Q2.1** — The header says "Applying **4** policy rule(s) to **3** resource(s)", yet the table has 6 rows. Reconcile these numbers.
- **Q2.2** — `disallow-latest-tag` is in **Audit** mode. In step 3 its violation on `web-latest` still appears as `Fail` and still drove the exit code to 1. Why did Audit mode *not* soften it here? (Foreshadows Exercise 3.)
- **Q2.3** — You pass a directory that also contains a `README.md` and a `kustomization.yaml`. Will `kyverno apply` choke on them? What does it do with non-policy / non-resource files?

---

### Exercise 3 — Enforce vs Audit, `--audit-warn`, and controllable exit codes

The five categories are not interchangeable, and `warn` exists specifically to let Audit findings be *visible without blocking*.

1. Run only the Audit policy against the offending resource, with **no** softening flag:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

2. Re-run with `--audit-warn`. This reclassifies failures produced by **Audit-mode** rules from `fail` to `warn`:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml --audit-warn
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 0, warn: 1, error: 0, skip: 0
   exit code: 0
   ```

3. Now make warnings *also* block, without touching the policy — set the exit code returned for warnings:

   ```bash
   kyverno apply policies/disallow-latest-tag.yaml -r resources/pod-latest.yaml \
     --audit-warn --warn-exit-code 1
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 0, warn: 1, error: 0, skip: 0
   exit code: 1
   ```

4. Prove that `--audit-warn` does **not** soften an **Enforce** rule. Run the Enforce policy from Exercise 1 with the flag:

   ```bash
   kyverno apply policies/require-team-label.yaml -r resources/pod-bad.yaml --audit-warn
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

**Comprehension checkpoint**

- **Q3.1** — Describe the exact effect of `--audit-warn`. Which rules does it touch and which does it leave alone?
- **Q3.2** — You want a CI job that *reports* Audit findings but *blocks* only on Enforce violations. Which single flag gives you that, and what is the exit code when only Audit rules fail?
- **Q3.3** — Later, the platform team decides Audit findings should block too, during a hardening sprint — but you are told **not to edit any policy**. Which flag combination achieves this, and why is "don't edit the policy" a meaningful constraint (think of the difference between the CLI and the admission controller)?

---

### Exercise 4 — Mocking admission context: `--set` and a `Values` file

Offline there is no admission request, so variables like `{{ request.operation }}`, `{{ request.userInfo }}`, or ConfigMap context are absent. `kyverno apply` lets you **inject** them.

1. Create a context-dependent policy, `policies/require-owner-on-write.yaml`. It only enforces on write operations and embeds the operation in its message:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-owner-on-write
   spec:
     background: false
     rules:
       - name: check-owner
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         preconditions:
           all:
             - key: "{{ request.operation || 'BACKGROUND' }}"
               operator: NotEquals
               value: DELETE
         validate:
           failureAction: Enforce
           message: "ConfigMaps must carry annotation 'owner' (operation was {{ request.operation }})."
           pattern:
             metadata:
               annotations:
                 owner: "?*"
   ```

2. Create `resources/cm.yaml` **without** the `owner` annotation:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
   data:
     LOG_LEVEL: info
   ```

3. Apply while mocking a **CREATE** operation with `--set` (`-s`), which sets a global variable as `key=value`:

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --set request.operation=CREATE
   echo "exit code: $?"
   ```

   Expected — the precondition passes, validation runs, and it fails:

   ```
   policy require-owner-on-write -> resource default/ConfigMap/app-config failed:
   1. check-owner: validation error: ConfigMaps must carry annotation 'owner' (operation was CREATE). ...

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   exit code: 1
   ```

4. Now mock a **DELETE** operation. The precondition evaluates false, so the rule is **skipped** rather than failed:

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --set request.operation=DELETE
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 0, warn: 0, error: 0, skip: 1
   exit code: 0
   ```

5. For anything larger than a couple of variables, prefer a **Values file** over stacked `--set` flags. Create `values.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Values
   metadata:
     name: values
   globalValues:
     request.operation: DELETE
   ```

   Apply with `--values-file` (`-f`):

   ```bash
   kyverno apply policies/require-owner-on-write.yaml -r resources/cm.yaml \
     --values-file values.yaml
   ```

   This reproduces the `skip: 1` result from step 4, now driven by a file you can version-control alongside the policy tests.

**Comprehension checkpoint**

- **Q4.1** — Without `--set` or a Values file, what would `{{ request.operation }}` resolve to under `kyverno apply`, and why is the `|| 'BACKGROUND'` fallback in the precondition prudent?
- **Q4.2** — A failing precondition produced `skip`, not `fail`. Contrast this with a rule whose `match` block simply doesn't select the resource — is that also a `skip`, or is it absent from the counts entirely?
- **Q4.3** — When would you reach for a `Values` file (kind `Values`, apiVersion `cli.kyverno.io/v1alpha1`) instead of repeated `--set` flags? Name two capabilities the file has that `--set` does not.

---

### Exercise 5 — Applying a mutate policy: previewing the transformed resource

`apply` is not only for `validate`. Against a `mutate` rule it prints the **mutated resource**, which is how you preview a mutation before it ever reaches the cluster.

1. Create `policies/add-safe-to-evict.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-safe-to-evict
   spec:
     background: false
     rules:
       - name: add-annotation
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
   ```

2. Apply it to the good Pod:

   ```bash
   kyverno apply policies/add-safe-to-evict.yaml -r resources/pod-good.yaml
   ```

   Expected — the emitted YAML now carries the injected annotation:

   ```yaml
   Applying 1 policy rule(s) to 1 resource(s)...

   mutate policy add-safe-to-evict applied to default/Pod/web-good:

   apiVersion: v1
   kind: Pod
   metadata:
     annotations:
       cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
     labels:
       team: payments
     name: web-good
     namespace: default
   spec:
     containers:
       - image: nginx:1.27
         name: nginx
   ---
   pass: 1, fail: 0, warn: 0, error: 0, skip: 0
   ```

**Comprehension checkpoint**

- **Q5.1** — For a `mutate` rule, what does the `pass` count actually mean? Does `pass` imply the resource was rejected or accepted?
- **Q5.2** — How would you use this behaviour in a review workflow to let a human confirm *exactly* what a mutation will do before merging the policy?

---

### Exercise 6 — Machine-readable output, exceptions, and CI wiring

1. Emit results as a Kubernetes **PolicyReport** instead of human text, and write it to a file:

   ```bash
   kyverno apply policies/ --resource resources/ --policy-report -o report.yaml
   ```

   `report.yaml` (abridged) uses the Working Group's report API:

   ```yaml
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: merged
   results:
     - policy: require-team-label
       rule: check-team-label
       result: fail
       resources:
         - apiVersion: v1
           kind: Pod
           name: web-bad
           namespace: default
     # ... one entry per policy/rule/resource ...
   summary:
     pass: 4
     fail: 2
     warn: 0
     error: 0
     skip: 0
   ```

2. Suppress a known, accepted violation with a **PolicyException** rather than by weakening the policy. Create `exception.yaml`:

   ```yaml
   apiVersion: kyverno.io/v2
   kind: PolicyException
   metadata:
     name: web-bad-team-label-exception
     namespace: default
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
     match:
       any:
         - resources:
             kinds:
               - Pod
             names:
               - web-bad
   ```

   > On Kyverno releases before the `kyverno.io/v2` GA, use `apiVersion: kyverno.io/v2beta1` — the schema is identical.

3. Apply the exception file with `--exception` (`-e`). The previously failing `web-bad` now resolves to `skip`:

   ```bash
   kyverno apply policies/require-team-label.yaml \
     -r resources/pod-bad.yaml \
     --exception exception.yaml
   echo "exit code: $?"
   ```

   Expected:

   ```
   pass: 0, fail: 0, warn: 0, error: 0, skip: 1
   exit code: 0
   ```

4. Wire the whole thing into a CI gate. Because `apply` returns exit code 1 on failure, no explicit parsing is required:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   kyverno apply policies/ \
     --resource resources/ \
     --exception exceptions/ \
     --audit-warn \
     --detailed-results
   # Non-zero exit here fails the pipeline stage automatically.
   ```

5. *(Optional, requires a cluster.)* Instead of files, evaluate the resources that are **live in the cluster** with `--cluster`; `-n` scopes the fetch to a namespace:

   ```bash
   kyverno apply policies/require-team-label.yaml --cluster -n default
   ```

**Comprehension checkpoint**

- **Q6.1** — A PolicyException turned a `fail` into a `skip`. Argue why that is operationally safer than editing `require-team-label` to stop matching `web-bad`.
- **Q6.2** — In the CI script of step 4, which findings can still fail the build, and which are merely printed? Trace it through the flags.
- **Q6.3** — What fundamentally changes when you add `--cluster`? Name one thing that becomes true offline-vs-cluster (the source of resources) and one variable that no longer needs mocking.

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 0**

- **Q0.1** — No. `kyverno apply` runs fully offline: it reads policy and resource YAML from the filesystem and evaluates them in-process. A cluster and kubeconfig are only involved when you add `--cluster` (or when a policy needs context you supply another way). This is precisely why it fits CI and pre-commit use.
- **Q0.2** — `?*` is a Kyverno pattern anchor meaning "one required character (`?`) followed by any number of characters (`*`)" — i.e. **a non-empty value must be present**. Plain `"*"` matches zero-or-more characters, so it would also accept an empty string. `?*` is the idiom for "this label/annotation must exist and be non-empty".

**Exercise 1**

- **Q1.1** — The exit code is **1** whenever there is at least one `fail` (and `warn` if you opt in via `--warn-exit-code`). A non-zero exit code is the universal contract every CI runner already understands, so `kyverno apply` becomes a gate with no output parsing: if it exits non-zero, the stage fails.
- **Q1.2** — From Kyverno's default. A namespaced resource with no `metadata.namespace` is treated as living in `default` for reporting purposes, mirroring how `kubectl` would place it. The `default` in `default/Pod/web-bad` is that fallback, not something you wrote.
- **Q1.3** — The **presence of any `fail`**, not the ratio. One failing resource forces exit code 1 regardless of how many passed. A gate is "all clear or blocked", not "majority wins".

**Exercise 2**

- **Q2.1** — "4 policy rule(s)" counts **rule evaluations discovered across all policies**, and "3 resource(s)" counts distinct resources. The 6 table rows are the **rule × resource combinations that actually matched**: two policies (one rule each) applied to three Pods = 6 evaluations. The header's per-category counts and the row count describe different things.
- **Q2.2** — Because the CLI has no admission controller. Offline, `Audit` vs `Enforce` does **not** change whether something is reported as a failure by default — both surface as `fail`. The action only affects the *cluster's* runtime behaviour (Audit = report, Enforce = reject). To make the CLI treat Audit failures as non-blocking you must ask for it explicitly with `--audit-warn` (Exercise 3).
- **Q2.3** — It does not choke. `kyverno apply` filters inputs by kind: files that aren't recognizable Kyverno policies or Kubernetes resources are ignored. `README.md`, `kustomization.yaml`, and similar files in a passed directory are skipped rather than causing an error.

**Exercise 3**

- **Q3.1** — `--audit-warn` reclassifies failures produced by **`Audit`-mode** rules from the `fail` bucket into the `warn` bucket. It has **no effect on `Enforce`-mode** rules — their failures remain `fail`. Since the default exit code for warnings is 0, Audit findings then stop blocking while Enforce findings still block.
- **Q3.2** — `--audit-warn` alone. When only Audit rules fail, they become `warn`, `fail` is 0, and the exit code is **0** (build passes but the warnings are printed). Enforce failures would still be `fail` and exit 1.
- **Q3.3** — `--audit-warn --warn-exit-code 1`: warnings are still shown as `warn`, but the process now exits **1** when any warning is present, so Audit findings block too. "Don't edit the policy" matters because the `failureAction` field also governs the **live admission controller** — flipping Audit→Enforce there would start *rejecting real workloads in the cluster*. The CLI flags change only the local/CI verdict, decoupling "how strict is CI today" from "how strict is production admission".

**Exercise 4**

- **Q4.1** — Unset, `{{ request.operation }}` has no value in offline mode; referencing it directly risks a substitution `error`. The `|| 'BACKGROUND'` fallback makes the precondition resolve deterministically (to `BACKGROUND`) when no operation is injected, so the policy degrades gracefully instead of erroring. When you *do* pass `--set request.operation=CREATE`, that value wins.
- **Q4.2** — They are different. A **failed precondition** is an explicit `skip` (the rule matched but chose not to act). A rule whose **`match` block does not select the resource** is not evaluated at all and is **absent from the counts** — it is neither pass, fail, nor skip. Rule of thumb: `skip` = "matched, then bailed out (precondition/exception)"; not-counted = "never matched".
- **Q4.3** — Reach for a `Values` file when you have more than a handful of variables, or when values must differ **per policy, per rule, or per resource**, or when you need `namespaceSelector` labels mocked. Two things it does that `--set` cannot: (1) scope values to a specific policy/rule/resource rather than only globally, and (2) supply `namespaceSelector` metadata so namespace-label-based matching can be tested offline. It is also version-controllable alongside the tests.

**Exercise 5**

- **Q5.1** — For a `mutate` rule, `pass: 1` means **the mutation was successfully computed and applied to the resource** (the rule ran without error and produced a patch). It is not an accept/reject verdict — mutation policies transform, they don't gate — so `pass` here reads as "the transformation succeeded", and the printed YAML is the resulting object.
- **Q5.2** — Run `kyverno apply <mutate-policy> -r <sample-resources>` in the pull request and attach (or diff) the emitted YAML. A reviewer sees the exact fields the mutation adds/changes on representative inputs before the policy is merged, catching over-broad `match` blocks or unintended overwrites while it is still a diff, not a cluster-wide side effect.

**Exercise 6**

- **Q6.1** — A `PolicyException` is a scoped, named, auditable object: it records *which* policy/rule is waived, for *which* resource, and it lives in version control (and, in-cluster, is itself governable). The policy keeps its original, strict intent for every other resource. Editing `require-team-label` to stop matching `web-bad` weakens the rule silently and permanently, is easy to over-broaden, and erases the "why" — the exception preserves the exception as data.
- **Q6.2** — With `--audit-warn`, only **Enforce**-mode failures land in `fail` and can exit non-zero to fail the build; **Audit**-mode failures become `warn` and are printed but do not block (no `--warn-exit-code` is set). Resources covered by files in `exceptions/` become `skip` and never block. So: Enforce → blocks; Audit → printed; excepted → skipped.
- **Q6.3** — `--cluster` changes the **source of resources**: instead of reading YAML files, Kyverno fetches the objects live from the API server (via kubeconfig), optionally narrowed by `-n <namespace>`. Because you are evaluating real admitted objects, cluster-derived context — most notably things like the resources' actual namespaces and existing state — no longer needs to be hand-mocked with `--set`/`--values-file` the way it does offline.

</details>

---

### Sources

- Kyverno CLI — `apply` command reference: <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Kyverno CLI — overview and installation: <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Validate rules and `failureAction`: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Mutate rules: <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kubernetes Policy WG — PolicyReport API (`wgpolicyk8s.io/v1alpha2`): <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- CNCF Curriculum (KCA): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>