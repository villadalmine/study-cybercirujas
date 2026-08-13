# Helm-based Installation and Configuration — Guided Exercises

> **Topic 2.1 · KCA · Exam weight: 3.0**
> These labs assume a working Kubernetes cluster (`kubectl` configured against a context you can freely modify — `kind`, `minikube`, or a throwaway namespace on a shared cluster) and Helm **v3.x**. Helm v3 is client-only: there is no Tiller, and release state lives in Kubernetes `Secret` objects in the release namespace.
> Every command is real. Where a `-o` flag or a version pin would change the output, it is noted. Adjust chart versions to what your repositories actually serve — pinning `--version` is the production habit and is required for reproducibility.

---

## Exercise 1 — Install Helm and wire up a repository

**Goal:** get a working client, understand where its configuration lives, and add/query a chart repository.

1. Install the client (script method shown; a package manager or a pinned binary is equally valid in production):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   ```

2. Confirm the version and that it talks to your cluster:

   ```bash
   helm version --short
   # v3.15.2+g...
   kubectl config current-context
   ```

3. Inspect where Helm keeps its own state. These are XDG paths, not Kubernetes objects:

   ```bash
   helm env | grep -E 'HELM_(REPOSITORY|CACHE|DATA|CONFIG)'
   # HELM_CACHE_HOME="/home/user/.cache/helm"
   # HELM_CONFIG_HOME="/home/user/.config/helm"
   # HELM_DATA_HOME="/home/user/.local/share/helm"
   # HELM_REPOSITORY_CONFIG="/home/user/.config/helm/repositories.yaml"
   ```

4. Add a repository and refresh the local index:

   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm repo update
   ```

5. Search the repository index and then Helm's public hub (Artifact Hub):

   ```bash
   helm search repo bitnami/nginx --versions | head
   helm search hub wordpress --max-col-width=60 | head
   ```

**Check your understanding:**
- **1a.** Helm v3 removed a server-side component that Helm v2 required. What was it called, and where does release state live now?
- **1b.** `helm search repo` and `helm search hub` hit two different data sources. Which one works offline, and why?
- **1c.** After `helm repo add`, a teammate publishes a new chart version but your `helm search repo` doesn't show it. What one command fixes this, and what does it actually download?

---

## Exercise 2 — Install a release and inspect it

**Goal:** create a release, understand the release/namespace/revision model, and read live state without `kubectl`.

1. Create a dedicated namespace and install a chart into it. Pin the chart version and name the release explicitly:

   ```bash
   kubectl create namespace demo
   helm install web bitnami/nginx --version 18.1.0 --namespace demo
   ```

   Expected tail of the output:

   ```
   NAME: web
   LAST DEPLOYED: ...
   NAMESPACE: demo
   STATUS: deployed
   REVISION: 1
   ```

2. List releases — first in the namespace, then across all namespaces:

   ```bash
   helm list --namespace demo
   helm list --all-namespaces
   ```

3. Read the release without touching `kubectl`:

   ```bash
   helm status web --namespace demo
   helm get values web --namespace demo          # user-supplied values (empty here)
   helm get values web --namespace demo --all    # user + computed defaults
   helm get manifest web --namespace demo | head -40
   ```

4. Prove where Helm stores its state. It is a Kubernetes `Secret`, base64-of-gzip-of-JSON:

   ```bash
   kubectl get secret --namespace demo -l owner=helm
   # NAME                          TYPE                 DATA
   # sh.helm.release.v1.web.v1     helm.sh/release.v1   1
   ```

**Check your understanding:**
- **2a.** A release name must be unique within one scope. What is that scope — the cluster, or the namespace? What does this let you do that Helm v2 could not?
- **2b.** What is the difference between `helm get values web` and `helm get values web --all`? Which one would you commit to Git as your "source of truth" for a release?
- **2c.** You delete the `sh.helm.release.v1.web.v1` Secret by hand but leave the Deployment running. What breaks about `helm upgrade`/`helm rollback` afterward, and why?

---

## Exercise 3 — Configure a release with values

**Goal:** override chart defaults three ways (`--set`, `--set-string`, `-f`), and understand precedence.

1. Inspect the chart's configurable surface before overriding anything:

   ```bash
   helm show values bitnami/nginx --version 18.1.0 | grep -A3 -E '^(replicaCount|service):'
   ```

2. Install a *second* release in a new namespace using a values file. Write it first:

   ```bash
   cat > /tmp/web-values.yaml <<'EOF'
   replicaCount: 3
   service:
     type: ClusterIP
   commonLabels:
     team: platform
   EOF

   kubectl create namespace staging
   helm install web bitnami/nginx --version 18.1.0 \
     --namespace staging \
     -f /tmp/web-values.yaml
   ```

3. Override a single value on top of the file at install time. Later `--set` flags win over `-f` files:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging \
     -f /tmp/web-values.yaml \
     --set replicaCount=5
   ```

4. Observe the type-coercion trap. `--set` interprets `true`, `123`, `null` as typed scalars; `--set-string` forces a string:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 --namespace staging \
     --reuse-values --set-string podAnnotations.build=00123 --dry-run=server \
     | grep -A2 annotations
   # build: "00123"   <-- leading zero preserved; --set would have made it 123
   ```

5. Confirm what actually took effect:

   ```bash
   helm get values web --namespace staging
   # replicaCount: 5
   # service:
   #   type: ClusterIP
   ```

**Check your understanding:**
- **3a.** You pass `-f base.yaml -f override.yaml --set image.tag=1.2` in one command. State the precedence order from lowest to highest.
- **3b.** What is the difference between `--reuse-values` and `--reset-values` on an upgrade? Which one is the *default* when you pass `--set` but no `-f`, and why does that surprise people?
- **3c.** Why would you reach for `--set-string` to set a version like `1.10`? What goes wrong with plain `--set`?

---

## Exercise 4 — Upgrade, roll back, and read history

**Goal:** treat a release as a versioned, reversible object.

1. Look at the release history so far:

   ```bash
   helm history web --namespace staging
   # REVISION  STATUS      CHART        APP VERSION  DESCRIPTION
   # 1         superseded  nginx-18.1.0 ...          Install complete
   # 2         superseded  nginx-18.1.0 ...          Upgrade complete
   # 3         deployed    nginx-18.1.0 ...          Upgrade complete
   ```

2. Perform an upgrade that changes an image tag, and wait for it to become ready. `--atomic` rolls back automatically on failure; `--timeout` bounds the wait:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging --reuse-values \
     --set image.tag=1.27.0-debian-12-r0 \
     --atomic --timeout 3m
   ```

3. Trigger a deliberately broken upgrade to see `--atomic` protect you. Point at a tag that will never pull:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging --reuse-values \
     --set image.tag=this-tag-does-not-exist \
     --atomic --timeout 90s
   # Error: UPGRADE FAILED: ... ; the release was rolled back
   ```

4. Roll back manually to a known-good revision and confirm history records the rollback as a *new* revision:

   ```bash
   helm rollback web 4 --namespace staging --wait
   helm history web --namespace staging | tail -3
   ```

**Check your understanding:**
- **4a.** Does a `helm rollback` to revision 4 reuse revision number 4, or create a new one? What does that tell you about how Helm models history?
- **4b.** `--atomic` implies another flag. Which one, and what is the failure behavior of an upgrade *without* `--atomic`?
- **4c.** Helm keeps a bounded number of historical revisions by default. Roughly how many, and which flag on `helm upgrade` controls it? Why does an unbounded history hurt on a busy release?

---

## Exercise 5 — Author your own chart

**Goal:** scaffold a chart, understand its anatomy, template it offline, and lint it.

1. Scaffold and read the tree:

   ```bash
   helm create mychart
   find mychart -maxdepth 2 -type f | sort
   # mychart/Chart.yaml
   # mychart/values.yaml
   # mychart/.helmignore
   # mychart/templates/deployment.yaml
   # mychart/templates/service.yaml
   # mychart/templates/_helpers.tpl
   # mychart/templates/NOTES.txt
   # ...
   ```

2. Inspect the two metadata fields that are *not* the same thing:

   ```bash
   grep -E '^(version|appVersion):' mychart/Chart.yaml
   # version: 0.1.0       # the chart's own SemVer
   # appVersion: "1.16.0" # the app being deployed — a label, not used for ordering
   ```

3. Render the chart to plain manifests **without a cluster** and search for a value substitution:

   ```bash
   helm template demo ./mychart --set replicaCount=2 | grep -E 'replicas:|kind:'
   ```

4. Break the chart on purpose, then let `lint` catch it. Introduce an invalid indent in `values.yaml`, run lint, then revert:

   ```bash
   helm lint ./mychart
   # ==> Linting ./mychart
   # 1 chart(s) linted, 0 chart(s) failed
   ```

5. Package the chart into a versioned, distributable artifact:

   ```bash
   helm package ./mychart
   # Successfully packaged chart and saved it to: mychart-0.1.0.tgz
   ```

**Check your understanding:**
- **5a.** `Chart.yaml` has both `version` and `appVersion`. Explain the distinct meaning of each and which one Helm actually uses to order upgrades.
- **5b.** `helm template` and `helm install --dry-run` both render manifests. Name one thing `--dry-run=server` does that `helm template` cannot.
- **5c.** What does `_helpers.tpl` hold, and why is its filename prefixed with an underscore? (Hint: think about what Helm treats as a rendered manifest vs. a partial.)

---

## Exercise 6 — Dependencies and subcharts

**Goal:** compose a chart from others and understand value propagation and conditions.

1. Declare a dependency in `Chart.yaml`. Add a database subchart, gated by a condition:

   ```yaml
   # append to mychart/Chart.yaml
   dependencies:
     - name: postgresql
       version: "15.5.38"
       repository: https://charts.bitnami.com/bitnami
       condition: postgresql.enabled
   ```

2. Resolve and lock the dependency. This writes `Chart.lock` and pulls the tarball into `charts/`:

   ```bash
   helm dependency update ./mychart
   ls mychart/charts
   # postgresql-15.5.38.tgz
   cat mychart/Chart.lock
   ```

3. Enable and configure the subchart from the parent's `values.yaml`. Values for a subchart nest under its name:

   ```yaml
   # mychart/values.yaml
   postgresql:
     enabled: true
     auth:
       database: appdb
   ```

4. Render and confirm the subchart's objects appear (or vanish when disabled):

   ```bash
   helm template demo ./mychart | grep -c 'kind: StatefulSet'   # 1 (postgresql)
   helm template demo ./mychart --set postgresql.enabled=false | grep -c 'kind: StatefulSet'  # 0
   ```

**Check your understanding:**
- **6a.** To set `auth.database` on the `postgresql` subchart from the parent chart, under which top-level key must the value live? Write the exact YAML path.
- **6b.** What is the purpose of `Chart.lock`, and why should it be committed to version control? What command regenerates it?
- **6c.** `condition` vs `tags` in a dependency entry — what does each control, and which wins if both are set?

---

## Exercise 7 — Templating, dry-run, and debugging a bad render

**Goal:** debug template logic the way you would under exam time pressure — offline, fast, with the built-in objects.

1. Add a template that uses the `Release` and `Values` built-in objects. Create `mychart/templates/configmap.yaml`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: {{ include "mychart.fullname" . }}-info
   data:
     release:   {{ .Release.Name | quote }}
     namespace: {{ .Release.Namespace | quote }}
     replicas:  {{ .Values.replicaCount | default 1 | quote }}
   ```

2. Render just that behavior and read the values that flowed in:

   ```bash
   helm template demo ./mychart --show-only templates/configmap.yaml \
     --namespace prod --set replicaCount=4
   ```

   Expected:

   ```yaml
   data:
     release: "demo"
     namespace: "prod"
     replicas: "4"
   ```

3. Introduce a template error (reference a missing key with `required`) and read Helm's diagnostic:

   ```bash
   helm template demo ./mychart \
     --set-string image.repository= \
     --set 'image.tag=null' 2>&1 | tail -5
   ```

4. Use `--debug` with a server dry-run to see the fully computed manifest plus the values Helm merged:

   ```bash
   helm install demo ./mychart --namespace demo --dry-run=server --debug 2>&1 | head -30
   ```

**Check your understanding:**
- **7a.** Name three built-in objects available inside a template and one fact each exposes. Which one is *not* known at `helm template` time but *is* known at `--dry-run=server` time?
- **7b.** What does the `required "msg" .Values.x` function do that a plain `{{ .Values.x }}` does not? When would you prefer `default`?
- **7c.** `--show-only templates/configmap.yaml` narrows the render. Why is this the fastest debugging loop for a single broken manifest, and why does it *not* need a cluster?

---

## Exercise 8 — Distribute a chart via an OCI registry

**Goal:** publish and consume a chart the modern way — no `index.yaml`, just an OCI registry.

1. Log in to an OCI-compatible registry (any works; a local `zot`/`registry:2` is fine for the lab):

   ```bash
   helm registry login registry.example.com --username "$USER"
   ```

2. Push the packaged chart from Exercise 5. Note the `oci://` scheme and that the chart *name* is implied, not part of the URL:

   ```bash
   helm push mychart-0.1.0.tgz oci://registry.example.com/charts
   # Pushed: registry.example.com/charts/mychart:0.1.0
   # Digest: sha256:...
   ```

3. Install directly from the registry — no `helm repo add` step exists for OCI:

   ```bash
   helm install demo oci://registry.example.com/charts/mychart \
     --version 0.1.0 --namespace demo
   ```

4. Inspect the remote chart's metadata without installing:

   ```bash
   helm show chart oci://registry.example.com/charts/mychart --version 0.1.0
   ```

**Check your understanding:**
- **8a.** Traditional HTTP chart repos rely on a file that OCI registries do not use. Name that file and explain what replaces its role in OCI.
- **8b.** For an `oci://` chart, `helm repo add` is neither needed nor valid. What is the OCI equivalent of "adding" a source before you can pull from a private registry?
- **8c.** In the `oci://registry.example.com/charts/mychart` reference, which part is the chart name and which is the "repository/namespace" path? Where does the chart *version* come from?

---

## Cleanup

```bash
helm uninstall web --namespace demo
helm uninstall web --namespace staging
helm uninstall demo --namespace demo
kubectl delete namespace demo staging
```

`helm uninstall` deletes the release's Kubernetes objects and its history Secret. Add `--keep-history` to retain the record so a `helm rollback` of an uninstalled release remains possible.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** The removed component was **Tiller**, the in-cluster server of Helm v2. Helm v3 is a pure client; release state is stored as Kubernetes **`Secret`** objects (type `helm.sh/release.v1`) in the release's own namespace — base64 of gzip of the release JSON. This removed Tiller's cluster-wide privileges and made Helm honor normal RBAC.
- **1b.** `helm search repo` works **offline** — it queries the locally cached `index.yaml` files downloaded by `helm repo add`/`update`, stored under `HELM_CACHE_HOME`. `helm search hub` queries **Artifact Hub over the network** and needs connectivity.
- **1c.** `helm repo update`. It re-downloads each configured repository's `index.yaml` into the local cache; it does **not** download any chart archives — only the index of available charts and versions.

### Exercise 2
- **2a.** The uniqueness scope is the **namespace**. Two releases named `web` can coexist in different namespaces. Helm v2 names were **cluster-global**, so this per-namespace scoping is new in v3 and is what lets you install the same chart under the same release name in `demo` and `staging`.
- **2b.** `helm get values web` shows only the **user-supplied** overrides (what you passed with `-f`/`--set`); `--all` merges those on top of the chart's computed defaults, showing the **full effective** value set. Commit the **user-supplied** set (ideally the actual `-f` file) as source of truth — the `--all` output includes defaults that change with the chart version and would drift.
- **2c.** Helm's history and current-state live in that Secret. Deleting it makes Helm believe the release does not exist: `helm upgrade` will refuse (or try a fresh install and collide with existing objects), and `helm rollback` has no revisions to roll back to. The live Deployment is now **orphaned** from Helm's point of view.

### Exercise 3
- **3a.** Lowest → highest: **chart `values.yaml` defaults → subchart/parent merges → each `-f` file in the order given (later files win) → `--set`/`--set-string`/`--set-file` flags**. So `--set image.tag=1.2` beats both files, and `override.yaml` beats `base.yaml`.
- **3b.** `--reuse-values` carries forward the values from the previous revision and layers new `--set`/`-f` on top; `--reset-values` discards prior overrides and starts from chart defaults plus whatever you pass now. The surprise: when you pass **only `--set` and no `-f`**, Helm historically defaults toward reusing prior values for that path, so people expect a clean slate and get a merge. Be explicit with `--reuse-values`/`--reset-values` to avoid ambiguity.
- **3c.** YAML/Go type coercion. Plain `--set image.tag=1.10` can be parsed as the **number** `1.1` (trailing zero dropped) or otherwise retyped; `--set-string` forces the literal string `"1.10"`. Same reasoning protects zero-padded values like `00123`.

### Exercise 4
- **4a.** It creates a **new revision** (here revision 5) whose content equals revision 4. History is **append-only** — Helm never rewrites or reuses a past revision number; a rollback is just another recorded change.
- **4b.** `--atomic` implies **`--wait`**. Without `--atomic`, a failed upgrade leaves the release in a **`failed`** state with partially-applied changes and does **not** auto-roll-back — you must roll back manually.
- **4c.** The default retained history is **10** revisions (`--history-max` on `helm upgrade`, `HELM_MAX_HISTORY` env). Unbounded history means one large Secret per revision accumulating in the namespace, bloating etcd and slowing every Helm operation on that release.

### Exercise 5
- **5a.** `version` is the **chart's own SemVer** and is the field Helm uses to order and select chart versions (`--version`, dependency resolution, upgrade ordering). `appVersion` is a free-form label describing the **application** shipped inside (e.g. the nginx version) and has no effect on ordering.
- **5b.** `--dry-run=server` sends the rendered manifests to the API server for **validation/admission** (schema checks, defaulting, admission webhooks) and can resolve **cluster-known** data; `helm template` renders purely client-side and knows nothing about the target cluster, so it cannot validate against it.
- **5c.** `_helpers.tpl` holds **named template partials** (`define`/`template`/`include`) — reusable snippets like label blocks and the `fullname` helper. The underscore prefix tells Helm the file is **not** an installable manifest: files beginning with `_` (and `NOTES.txt`) are excluded from the set of objects applied to the cluster.

### Exercise 6
- **6a.** Under the subchart's name as a top-level key in the parent's values:
  ```yaml
  postgresql:
    auth:
      database: appdb
  ```
- **6b.** `Chart.lock` pins the **exact resolved versions and digests** of every dependency, so `helm dependency build` reproduces the identical `charts/` contents anywhere. Commit it for reproducible builds. `helm dependency update` regenerates it (re-resolving against repositories); `helm dependency build` installs strictly what the lock already names.
- **6c.** `condition` is a **path to a boolean value** (e.g. `postgresql.enabled`) that turns a single dependency on/off. `tags` group several dependencies under named switches toggled together. If both are present, an explicitly set **`condition` wins** over tags for that dependency.

### Exercise 7
- **7a.** Examples: `.Release` (`.Name`, `.Namespace`, `.Revision`, `.IsUpgrade`/`.IsInstall`), `.Chart` (`.Name`, `.Version`, `.AppVersion`), `.Values` (merged user+default values), `.Capabilities` (`.KubeVersion`, available API groups), `.Files` (non-template files in the chart). **`.Capabilities`** (the cluster's real version and API set) is unknown to `helm template` unless you fake it with `--api-versions`/`--kube-version`, but is populated for real by `--dry-run=server`.
- **7b.** `required "msg" .Values.x` **fails the render with your message** if `x` is empty/absent, turning a silent misconfiguration into a hard, explanatory error. Prefer `default` when a missing value has a **safe fallback** and the deployment should still proceed.
- **7c.** `--show-only` renders the **whole chart** (so cross-references and helpers still resolve) but prints **only the named file**, giving a tight edit-render-read loop for one manifest. It runs entirely client-side — no API server is contacted — so it works with no cluster and no credentials.

### Exercise 8
- **8a.** HTTP repos rely on **`index.yaml`**, a catalog of every chart/version at that repo. OCI registries have **no index**; discovery uses the registry's own tag/manifest API (each chart is an OCI artifact addressed by `name:tag` and content digest), so there is nothing to periodically re-download.
- **8b.** `helm registry login <registry>` (and `helm registry logout`). Authentication is per-registry via the OCI login, reusing Docker-style credentials — there is no `repo add`/`index.yaml` step for `oci://` sources.
- **8c.** In `oci://registry.example.com/charts/mychart`: `registry.example.com/charts` is the **registry host + repository/namespace path**, `mychart` is the **chart name**, and the **version is not in the URL** — it comes from `--version` (or the artifact tag), e.g. `--version 0.1.0` resolving to the `mychart:0.1.0` artifact.

</details>

---

**Sources (official):**
- Helm documentation — Using Helm: https://helm.sh/docs/intro/using_helm/
- Helm — Charts guide (structure, dependencies, `Chart.yaml`): https://helm.sh/docs/topics/charts/
- Helm — Values files and precedence: https://helm.sh/docs/chart_template_guide/values_files/
- Helm — Built-in Objects: https://helm.sh/docs/chart_template_guide/builtin_objects/
- Helm — OCI-based registries: https://helm.sh/docs/topics/registries/
- Helm CLI reference (`helm install`, `upgrade`, `rollback`, `history`, `template`, `dependency`): https://helm.sh/docs/helm/
- KCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf