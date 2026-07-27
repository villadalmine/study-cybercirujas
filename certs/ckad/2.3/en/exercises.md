# CKAD 1.35 — Topic 2.3: Use the Helm Package Manager to Deploy Existing Packages

*Exam weight: 5. Reference: CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf*

These exercises use the [podinfo](https://github.com/stefanprodan/podinfo) chart — a small, single-Deployment demo app — so you can focus on the Helm workflow instead of waiting on heavy dependencies.

---

## Exercise 1 — Verify Helm and inspect its configuration

1. Check the installed client version (Helm 3 has no server-side Tiller component):
   ```bash
   helm version --short
   ```
2. Confirm which kubeconfig context Helm will act against — Helm always uses your current `kubectl` context:
   ```bash
   kubectl config current-context
   ```
3. List Helm's environment settings (cache, config, and data paths):
   ```bash
   helm env
   ```

**Check your understanding**
- Since Helm 3 removed Tiller, whose RBAC permissions govern what `helm install` is allowed to do in the cluster?
- Why does `helm version` alone not tell you which cluster a `helm install` will target?

---

## Exercise 2 — Add, update, and list chart repositories

1. Add the podinfo repository:
   ```bash
   helm repo add podinfo https://stefanprodan.github.io/podinfo
   ```
2. Refresh the local index of every added repo:
   ```bash
   helm repo update
   ```
3. List configured repositories and their URLs:
   ```bash
   helm repo list
   ```

**Check your understanding**
- What file does `helm repo add` write to, and what does `helm repo update` actually download from each repo's URL?
- If you add two repositories that both publish a chart named `nginx`, how do you tell Helm exactly which one to install?

---

## Exercise 3 — Search for charts

1. Search your added repos for podinfo:
   ```bash
   helm search repo podinfo
   ```
2. List every published chart version:
   ```bash
   helm search repo podinfo --versions
   ```
3. Search Artifact Hub for charts you haven't added locally:
   ```bash
   helm search hub wordpress
   ```

**Check your understanding**
- What's the functional difference between `helm search repo` and `helm search hub`?
- You need chart version `6.5.4` specifically. Which flag on `helm install`/`helm upgrade` lets you pin that exact version instead of getting the latest?

---

## Exercise 4 — Inspect a chart before installing it

1. View chart metadata (`Chart.yaml` contents):
   ```bash
   helm show chart podinfo/podinfo
   ```
2. View the full set of default configurable values:
   ```bash
   helm show values podinfo/podinfo
   ```
3. Download the chart archive locally without installing it, and unpack it:
   ```bash
   helm pull podinfo/podinfo --untar --untardir /tmp/charts
   ls /tmp/charts/podinfo
   ```

**Check your understanding**
- Why would you run `helm show values` before writing your own `-f values.yaml` override file?
- What's inside the `templates/` directory that `helm pull --untar` exposes, and how does it differ from what `helm show values` shows you?

---

## Exercise 5 — Render and dry-run before touching the cluster

1. Create a namespace for this exercise set:
   ```bash
   kubectl create namespace helm-demo
   ```
2. Simulate an install against the live API server without creating objects:
   ```bash
   helm install my-app podinfo/podinfo --namespace helm-demo --dry-run --debug
   ```
3. Render the chart's templates purely client-side, with no cluster contact, and save the output:
   ```bash
   helm template my-app podinfo/podinfo --namespace helm-demo > /tmp/rendered.yaml
   ```
4. Review the rendered manifests:
   ```bash
   less /tmp/rendered.yaml
   ```

**Check your understanding**
- `helm install --dry-run` and `helm template` both produce rendered YAML — what can `--dry-run` validate that `helm template` alone cannot?
- If a rendered manifest looks wrong, is it faster to fix it by editing `/tmp/rendered.yaml` directly, or by changing chart values? Why?

---

## Exercise 6 — Install a chart with default values

1. Install podinfo with default values under the release name `my-app`:
   ```bash
   helm install my-app podinfo/podinfo --namespace helm-demo
   ```
2. Confirm the release is recorded:
   ```bash
   helm list --namespace helm-demo
   ```
3. Confirm the workload it created is running:
   ```bash
   kubectl get deploy,svc,pods -n helm-demo -l app.kubernetes.io/instance=my-app
   ```

**Check your understanding**
- What label does Helm attach to every resource it creates, and how does that label let `helm uninstall` find everything belonging to a release later?
- What error do you get if you run `helm install my-app podinfo/podinfo -n helm-demo` again unchanged, and which flag would let it succeed by generating a random release name instead?

---

## Exercise 7 — Customize a release with `--set` and `-f`

1. Write a values override file:
   ```bash
   cat <<EOF > /tmp/override-values.yaml
   replicaCount: 2
   resources:
     requests:
       cpu: 50m
       memory: 32Mi
   EOF
   ```
2. Install a second, independently-named release combining the file and a command-line override (flags passed after `-f` win over the file):
   ```bash
   helm install my-app-2 podinfo/podinfo \
     --namespace helm-demo \
     -f /tmp/override-values.yaml \
     --set replicaCount=3
   ```
3. Confirm which value actually took effect:
   ```bash
   kubectl get deploy my-app-2-podinfo -n helm-demo -o jsonpath='{.spec.replicas}{"\n"}'
   ```

**Check your understanding**
- Given the command in step 2, how many replicas does `my-app-2` end up with, and why?
- When would you reach for `--set` versus maintaining a `-f values.yaml` file in a real workflow?

---

## Exercise 8 — Upgrade a release and inspect revision history

1. Upgrade `my-app` in place, changing its replica count:
   ```bash
   helm upgrade my-app podinfo/podinfo --namespace helm-demo --set replicaCount=2
   ```
2. Confirm the change rolled out:
   ```bash
   kubectl get deploy my-app-podinfo -n helm-demo -o jsonpath='{.spec.replicas}{"\n"}'
   ```
3. List the release's revision history:
   ```bash
   helm history my-app --namespace helm-demo
   ```
4. Show only the values currently applied to the running release:
   ```bash
   helm get values my-app --namespace helm-demo
   ```

**Check your understanding**
- If you run `helm upgrade` with none of your previous `--set`/`-f` overrides repeated, what happens to those previously-set values? What flag preserves them automatically?
- What does the `REVISION` column in `helm history` represent, and what triggers a new revision?

---

## Exercise 9 — Roll back a release

1. Intentionally break the release with an invalid image tag:
   ```bash
   helm upgrade my-app podinfo/podinfo --namespace helm-demo \
     --reuse-values --set image.tag=does-not-exist
   ```
2. Watch the rollout stall:
   ```bash
   kubectl rollout status deployment/my-app-podinfo -n helm-demo --timeout=30s
   ```
3. Roll back to the last working revision:
   ```bash
   helm rollback my-app --namespace helm-demo
   ```
4. Confirm the deployment recovered and check history again:
   ```bash
   kubectl rollout status deployment/my-app-podinfo -n helm-demo
   helm history my-app --namespace helm-demo
   ```

**Check your understanding**
- Does `helm rollback my-app` (with no revision number) go back one revision, or to a specific one — and how would you target revision `1` explicitly?
- Which flag on `helm upgrade` would have made step 1's failure roll back automatically, without you needing to run `helm rollback` yourself?

---

## Exercise 10 — Inspect release resources and uninstall

1. Dump the exact manifest Helm applied for a release:
   ```bash
   helm get manifest my-app --namespace helm-demo
   ```
2. Check the release's current status and notes:
   ```bash
   helm status my-app --namespace helm-demo
   ```
3. Remove both releases created in this exercise set:
   ```bash
   helm uninstall my-app --namespace helm-demo
   helm uninstall my-app-2 --namespace helm-demo
   ```
4. Confirm no resources remain, then delete the namespace:
   ```bash
   kubectl get all -n helm-demo
   kubectl delete namespace helm-demo
   ```

**Check your understanding**
- By default, does `helm uninstall` delete the release's revision history, or only its Kubernetes resources? Which flag changes that?
- If `kubectl get all -n helm-demo` still shows resources after `helm uninstall`, what does that tell you about how those resources were created?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- Helm 3 has no Tiller; `helm install` talks to the API server directly using your current kubeconfig identity, so the action is bound by **your** user/service-account RBAC permissions, not a separate cluster-wide component.
- `helm version` only reports the client (and, historically, server) binary version — it says nothing about which kubeconfig context is active. That's controlled independently by `kubectl config current-context` / `$KUBECONFIG`, and Helm always follows whatever context `kubectl` would use.

**Exercise 2**
- `helm repo add` appends the name/URL pair to Helm's local `repositories.yaml`. `helm repo update` downloads each repo's `index.yaml` (the chart catalog: names, versions, digests) and caches it locally — no chart contents are fetched yet, only the index.
- Prefix the chart name with the repo name you want, e.g. `helm install web repoA/nginx` vs `helm install web repoB/nginx`.

**Exercise 3**
- `helm search repo` searches only repositories you've already added locally (via cached `index.yaml` files); `helm search hub` queries Artifact Hub, a public catalog of charts across many repos you may not have added.
- `--version 6.5.4` (works on both `helm install` and `helm upgrade`).

**Exercise 4**
- It shows every key the chart's templates support, with its default — the only reliable way to know what you can override without reading every template file.
- `templates/` contains the Go-templated Kubernetes manifests (Deployment, Service, etc.) that get rendered using the values; `helm show values` only shows the input *data*, not the logic/structure that consumes it.

**Exercise 5**
- `--dry-run` sends the rendered manifests to the API server for server-side validation (e.g., catches invalid API fields, honors `lookup` template functions and capability checks) without persisting objects. `helm template` renders entirely client-side and never contacts the cluster, so it can't catch server-side validation errors.
- Change chart values — editing the rendered YAML directly is a dead end, since re-running `helm install`/`upgrade` regenerates manifests from the chart and values, discarding manual edits.

**Exercise 6**
- `app.kubernetes.io/instance=<release-name>` (Helm also injects `app.kubernetes.io/managed-by=Helm`). `helm uninstall` uses Helm's own release record (not label selection) to know what to delete, but you can use that label with `kubectl` to inspect or filter a release's resources yourself.
- Error: `cannot re-use a name that is still in use`. Use `--generate-name` (with a positional chart argument only) to have Helm generate a random unique release name instead of specifying one.

**Exercise 7**
- 3 replicas. Values are merged in order, and later sources win: the `-f /tmp/override-values.yaml` file sets `replicaCount: 2`, but the `--set replicaCount=3` that follows it on the command line overrides that value.
- `--set` is quick for one-off overrides or scripting/CI; a `-f values.yaml` file is better for anything you want to version-control, review, or reuse/share as the durable source of truth for a deployment.

**Exercise 8**
- Without `--reuse-values` (or repeating the same flags), `helm upgrade` resets any values not explicitly passed back to the chart's defaults — previous `--set`/`-f` overrides are **not** remembered automatically. `--reuse-values` merges the new flags on top of the previously-deployed values.
- Each row is a stored release snapshot (chart version + computed values + manifest) Helm can roll back to. A new revision is created by any `helm upgrade`, `helm rollback`, or in some cases `helm install` retry — essentially any state-changing Helm operation on that release.

**Exercise 9**
- With no revision number, `helm rollback my-app` reverts to the immediately preceding revision. To target a specific one: `helm rollback my-app 1`.
- `--atomic` (combined with `--wait`, which it implies) — it makes `helm upgrade` roll back automatically if the upgrade doesn't reach a ready state within the timeout.

**Exercise 10**
- By default `helm uninstall` deletes both the Kubernetes resources **and** the release history. `--keep-history` retains the revision records (visible via `helm history`/`helm status --revision`) even though the resources are gone.
- It means those resources weren't tracked as part of the Helm release (e.g., created manually with `kubectl apply`, by a different tool, or via a hook Helm doesn't manage on delete) — `helm uninstall` only removes what's in its own release manifest.

</details>