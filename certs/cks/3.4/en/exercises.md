# Topic 3.4 — Upgrade Kubernetes to Avoid Vulnerabilities

**Certification:** CKS (Certified Kubernetes Security Specialist) — Exam version 1.34
**Domain:** Cluster Hardening — *Upgrade Kubernetes to avoid vulnerabilities*
**Exam weight:** 3.75 %
**Format:** guided exercises. Execute every numbered step; answer the checkpoint questions before moving on. All answers are collapsed at the end of the document.

---

## 0. Lab environment and ground rules

These exercises mutate a control plane. **Do not run them against anything you care about.** Build a throwaway cluster first.

**Reference topology used throughout:**

| Host   | Role                    | Starting version |
|--------|-------------------------|------------------|
| `cp01` | control-plane (kubeadm) | v1.33.4          |
| `w01`  | worker                  | v1.33.4          |
| `w02`  | worker                  | v1.33.4          |

* Cluster bootstrapped with `kubeadm`, control plane running as **static Pods**, stacked `etcd`.
* Container runtime: `containerd`.
* Root/`sudo` on every node, and `kubectl` configured against `cp01`.
* Target version in the examples: **v1.34.1**. Substitute the latest v1.34 patch available in your package repository — the *mechanics* are what you are learning, not the digits.

> **Quick build option (Debian/Ubuntu):** `kubeadm init --kubernetes-version v1.33.4 --pod-network-cidr 10.244.0.0/16` on `cp01`, then join `w01`/`w02`, then install a CNI. If you only have one machine, `kind create cluster --image kindest/node:v1.33.4` works for Exercises 1, 2, 4, 8 and 9, but **not** for 5–7 (kind nodes are not package-managed the way kubeadm nodes are).

**Exam framing.** In the CKS exam this objective almost always appears as: *"Upgrade this cluster from v1.X to v1.Y. Upgrade **only** the control-plane node (or: upgrade `cp` first, then `node01`). Do not upgrade the worker nodes."* The whole task is worth a few points and should take under 8 minutes once you have the sequence memorised. Speed matters more than elegance here — Exercise 10 is the speed-run.

---

## Exercise 1 — Establish the baseline and internalise the version skew policy

You cannot decide *whether* you are exposed, or *how far* you may jump, without an exact inventory. "The cluster is on 1.33" is not an inventory: `kube-apiserver`, `kubelet`, `kube-proxy`, `etcd`, `CoreDNS` and the container runtime all version independently, and each has its own CVE stream.

### Steps

1. Get the node-reported versions. The `VERSION` column is the **kubelet** version, not the API server version — a distinction that trips people up constantly.

   ```bash
   kubectl get nodes -o wide
   ```

   ```
   NAME   STATUS   ROLES           AGE   VERSION   INTERNAL-IP    OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
   cp01   Ready    control-plane   31d   v1.33.4   10.10.0.11     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   w01    Ready    <none>          31d   v1.33.4   10.10.0.21     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   w02    Ready    <none>          31d   v1.33.4   10.10.0.22     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://2.0.5
   ```

2. Get the client (`kubectl`) and server (`kube-apiserver`) versions separately:

   ```bash
   kubectl version
   ```

   ```
   Client Version: v1.33.4
   Kustomize Version: v5.6.0
   Server Version: v1.33.4
   ```

3. Get the version of the `kubeadm` binary on `cp01`. **This is the version that governs what you are allowed to upgrade to** — `kubeadm upgrade apply vX.Y.Z` refuses to install a version that does not match the running `kubeadm` binary.

   ```bash
   sudo kubeadm version -o short
   ```

   ```
   v1.33.4
   ```

4. Read the *actual image tags* of the control-plane static Pods. This is ground truth; the `kubeadm-config` ConfigMap can drift from reality after a partial or failed upgrade.

   ```bash
   kubectl -n kube-system get pods \
     -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   ```
   POD                    IMAGE
   etcd-cp01              registry.k8s.io/etcd:3.6.4-0
   kube-apiserver-cp01    registry.k8s.io/kube-apiserver:v1.33.4
   kube-controller-manager-cp01  registry.k8s.io/kube-controller-manager:v1.33.4
   kube-scheduler-cp01    registry.k8s.io/kube-scheduler:v1.33.4
   ```

5. Add the components kubeadm treats as *addons* (they are upgraded by `kubeadm upgrade apply`, but they are not part of the control-plane skew rules):

   ```bash
   kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   registry.k8s.io/kube-proxy:v1.33.4
   registry.k8s.io/coredns/coredns:v1.12.0
   ```

6. Add the layers Kubernetes will **not** upgrade for you — the runtime and the kernel. A very large share of real container-escape CVEs live here (`runc`, `containerd`), not in Kubernetes.

   ```bash
   sudo crictl version
   containerd --version
   runc --version
   uname -r
   ```

   ```
   Version:  0.1.0
   RuntimeName:  containerd
   RuntimeVersion:  v2.0.5
   RuntimeApiVersion:  v1
   containerd github.com/containerd/containerd/v2 v2.0.5 ...
   runc version 1.2.6
   6.8.0-51-generic
   ```

7. Persist the baseline. You will diff against it in Exercise 8.

   ```bash
   { kubectl get nodes -o wide
     kubectl version
     kubectl -n kube-system get pods -l tier=control-plane \
       -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   } > ~/upgrade-baseline-$(date +%F).txt
   ```

8. Read the version skew policy — **https://kubernetes.io/releases/version-skew-policy/** — and write down, from the doc, the maximum permitted skew for `kubelet` relative to `kube-apiserver`, and for `kubectl` relative to `kube-apiserver`.

### ✅ Checkpoint 1

- **Q1.1** — The `VERSION` column of `kubectl get nodes` shows `v1.33.4` for `cp01`. Which binary's version is that, and which component's version is it *not*?
- **Q1.2** — A colleague proposes going from v1.31 straight to v1.34 with `kubeadm upgrade apply v1.34.1` to close a CVE quickly. Why will this fail, and what is the correct path?
- **Q1.3** — After you upgrade `kube-apiserver` to v1.34.1 but leave every `kubelet` on v1.33.4, is the cluster in a supported state? For how many minor versions can that situation persist?
- **Q1.4** — Your workstation has `kubectl` v1.31.0 and the cluster is being upgraded to v1.34.1. Is that combination supported? What symptom would you expect first?
- **Q1.5** — Why must you upgrade `kube-apiserver` *before* the kubelets, and never the reverse?
- **Q1.6** — `containerd` 2.0.5 and `runc` 1.2.6 appear in your inventory. Does `kubeadm upgrade apply v1.34.1` patch them? What is the security implication?

---

## Exercise 2 — Decide whether you are actually vulnerable (CVE triage)

"Upgrade to avoid vulnerabilities" is not "upgrade constantly". The professional workflow is: **identify the CVE → find the *fixed-in* versions → determine whether your components are below any of them → upgrade to the nearest fixed patch.** Kubernetes publishes a machine-readable, auto-generated CVE feed exactly for this.

### Steps

1. Fetch the official CVE feed. It is JSON Feed 1.1, built from issues labelled `official-cve-feed` in `kubernetes/kubernetes`.

   ```bash
   curl -sSL https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json -o /tmp/k8s-cve.json
   jq 'keys' /tmp/k8s-cve.json
   ```

   ```json
   [
     "description",
     "home_page_url",
     "items",
     "title",
     "version"
   ]
   ```

2. **Inspect one item before writing filters.** Never assume a feed schema; it changes.

   ```bash
   jq '.items[0]' /tmp/k8s-cve.json
   ```

   ```json
   {
     "id": "https://github.com/kubernetes/kubernetes/issues/NNNNNN",
     "url": "https://github.com/kubernetes/kubernetes/issues/NNNNNN",
     "external_url": "https://www.cve.org/CVERecord?id=CVE-20XX-NNNNN",
     "title": "CVE-20XX-NNNNN: <short description>",
     "content_text": "<issue body: affected components, affected versions, fixed versions, CVSS>",
     "date_published": "20XX-XX-XXT00:00:00Z"
   }
   ```

3. List the most recent advisories in a readable form:

   ```bash
   jq -r '.items | sort_by(.date_published) | reverse | .[:10][]
          | [ (.date_published[:10]), .title ] | @tsv' /tmp/k8s-cve.json | column -t -s $'\t'
   ```

4. Search the feed for a component you run, and read the *fixed-in* line out of the body text:

   ```bash
   jq -r '.items[] | select(.content_text | test("kubelet"; "i"))
          | "\(.date_published[:10])  \(.title)\n\(.external_url)\n"' /tmp/k8s-cve.json | head -40
   ```

5. Cross-check the patch-release support window. Kubernetes maintains the **three most recent minor releases**; each gets patches for roughly 12 months plus a 2-month maintenance-mode tail. Anything older receives **no security patches at all**.

   ```bash
   curl -sSL https://kubernetes.io/releases/patch-releases/ | grep -iEo '1\.3[0-9]' | sort -u
   ```

   Read the authoritative table at **https://kubernetes.io/releases/patch-releases/**.

6. Cover the layers the Kubernetes feed does not: the distro's own security tracker for `containerd`, `runc`, `kernel`, and `openssl`.

   ```bash
   sudo apt-get update
   apt list --upgradable 2>/dev/null | grep -Ei 'containerd|runc|linux-image|kube'
   # RPM-based:
   # sudo dnf updateinfo list --security
   ```

7. Subscribe (do this once, for real, on a real cluster): the `kubernetes-announce` Google Group is the channel where embargoed fixes are announced — **https://kubernetes.io/docs/reference/issues-security/security/**.

### ✅ Checkpoint 2

- **Q2.1** — An advisory states: *"Affected: kubelet v1.32.0 – v1.32.6, v1.33.0 – v1.33.5. Fixed in: v1.32.7, v1.33.6, v1.34.0."* Your cluster runs kubelet v1.33.4. What is the **minimum-risk** remediation, and why is it not "upgrade to v1.34.1"?
- **Q2.2** — Your cluster runs v1.29. Nothing is broken and the workloads are happy. Give the security argument, in one sentence, for why v1.29 is nonetheless unacceptable.
- **Q2.3** — The CVE feed shows nothing new this month, yet a container-escape exploit is circulating publicly. Which two inventory lines from Exercise 1 would you check first, and why does the Kubernetes feed miss them?
- **Q2.4** — Why does the official CVE feed live behind `official-cve-feed`-labelled GitHub issues instead of a hand-curated page? What does that imply about latency and completeness?
- **Q2.5** — Explain why upgrading a *minor* version to fix a CVE is generally a *higher*-risk action than upgrading a *patch* version, even though both close the CVE.

---

## Exercise 3 — Pre-flight: back up etcd and the control-plane state

There is **no supported downgrade path** in Kubernetes. `kubeadm upgrade` moves forward only. Your rollback is an etcd snapshot plus the PKI/manifest directory — nothing else. Take it *before* touching a single package.

### Steps

1. Locate the etcd client certificates from the static Pod manifest (do not guess the paths):

   ```bash
   sudo grep -E 'cert-file|key-file|trusted-ca-file|listen-client-urls|data-dir' \
     /etc/kubernetes/manifests/etcd.yaml
   ```

   ```
       - --cert-file=/etc/kubernetes/pki/etcd/server.crt
       - --key-file=/etc/kubernetes/pki/etcd/server.key
       - --listen-client-urls=https://127.0.0.1:2379,https://10.10.0.11:2379
       - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
       - --data-dir=/var/lib/etcd
   ```

2. Take the snapshot. Use the **client** certificate pair (`healthcheck-client` or `apiserver-etcd-client`), not the server key:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
     --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
     snapshot save /var/backups/etcd-pre-1.34-$(date +%F).db
   ```

   ```
   {"level":"info","msg":"created temporary db file",...}
   {"level":"info","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
   {"level":"info","msg":"fetched snapshot","size":"42 MB"}
   Snapshot saved at /var/backups/etcd-pre-1.34-2026-07-31.db
   ```

3. Verify the snapshot is readable and non-empty. `etcdctl snapshot status` is deprecated; the modern tool is `etcdutl`:

   ```bash
   sudo etcdutl snapshot status /var/backups/etcd-pre-1.34-$(date +%F).db --write-out=table
   ```

   ```
   +----------+----------+------------+------------+
   |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
   +----------+----------+------------+------------+
   | 8f1c1a2b |   918442 |       1873 |      42 MB |
   +----------+----------+------------+------------+
   ```

4. Back up the control-plane configuration and PKI. A snapshot alone will not rebuild a node:

   ```bash
   sudo tar -czf /var/backups/k8s-etc-$(date +%F).tgz \
     /etc/kubernetes \
     /var/lib/kubelet/config.yaml \
     /var/lib/kubelet/kubeadm-flags.env
   sudo tar -tzf /var/backups/k8s-etc-$(date +%F).tgz | head
   ```

5. Copy both artefacts **off the node**. A backup that lives only on the machine you are about to break is not a backup.

   ```bash
   scp /var/backups/etcd-pre-1.34-*.db /var/backups/k8s-etc-*.tgz backup-host:/srv/k8s-backups/
   ```

6. Check certificate expiry while you are here — `kubeadm upgrade apply` renews control-plane certificates automatically, which is a useful side effect worth recording *before*:

   ```bash
   sudo kubeadm certs check-expiration
   ```

   ```
   CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   admin.conf                 Aug 20, 2026 09:11 UTC   20d             no
   apiserver                  Aug 20, 2026 09:11 UTC   20d             no
   apiserver-etcd-client      Aug 20, 2026 09:11 UTC   20d             no
   apiserver-kubelet-client   Aug 20, 2026 09:11 UTC   20d             no
   controller-manager.conf    Aug 20, 2026 09:11 UTC   20d             no
   etcd-healthcheck-client    Aug 20, 2026 09:11 UTC   20d             no
   etcd-peer                  Aug 20, 2026 09:11 UTC   20d             no
   etcd-server                Aug 20, 2026 09:11 UTC   20d             no
   front-proxy-client         Aug 20, 2026 09:11 UTC   20d             no
   scheduler.conf             Aug 20, 2026 09:11 UTC   20d             no
   ```

### ✅ Checkpoint 3

- **Q3.1** — `kubeadm upgrade apply v1.32.9` on a v1.33 cluster: what does kubeadm do, and what is your only real path back to v1.32?
- **Q3.2** — You restore the etcd snapshot from step 2 but keep the already-upgraded v1.34.1 static Pod manifests. What class of failure should you expect?
- **Q3.3** — Which certificates does `kubeadm upgrade apply` renew by default, and which flag disables that? Name one situation where you would want to disable it.
- **Q3.4** — Why is `healthcheck-client.crt` the right certificate for `etcdctl snapshot save`, rather than `server.crt`?
- **Q3.5** — On a cluster with **external** etcd, what changes about this exercise?

---

## Exercise 4 — Detect removed APIs before the upgrade removes them for you

Minor upgrades remove APIs that were deprecated one or more releases earlier. If a Deployment, a Helm chart, an operator's CRD or an admission webhook still speaks a removed version, the upgrade silently breaks it — and "roll back to fix it" is not available. This check belongs *before* `kubeadm upgrade plan`, not after.

### Steps

1. Ask the API server itself which deprecated APIs clients have been calling. This metric is the single highest-value pre-upgrade signal in the cluster:

   ```bash
   kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
   ```

   ```
   apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.35",resource="flowschemas",subresource="",version="v1beta3"} 1
   apiserver_requested_deprecated_apis{group="",removed_release="",resource="endpoints",subresource="",version="v1"} 1
   ```

   The `removed_release` label tells you the exact minor version at which the call stops working.

2. Join that metric with request counts, so you learn **who** is calling and how often:

   ```bash
   kubectl get --raw /metrics | grep -E 'apiserver_request_total.*v1beta3' | head
   ```

3. Enumerate the served API versions currently in the cluster, and compare against the deprecation guide:

   ```bash
   kubectl api-resources --sort-by=name -o wide | head -30
   kubectl api-versions | sort
   ```

   Authoritative removal table: **https://kubernetes.io/docs/reference/using-api/deprecation-guide/**

4. Scan the manifests you actually deploy (your GitOps repo, your Helm charts), not just the live cluster. A resource stored in etcd is auto-converted on read; a manifest in Git is not.

   ```bash
   # kube-no-trouble (third-party, widely used):
   kubent --context "$(kubectl config current-context)"
   # or, against files:
   kubent -f ./manifests/
   ```

   ```
   __ ____  _ _____
   ...
   >>> Deprecated APIs removed in 1.35 <<<
   KIND        NAMESPACE   NAME        API_VERSION                                REPLACE_WITH (SINCE)
   FlowSchema  <undefined> my-flow     flowcontrol.apiserver.k8s.io/v1beta3       flowcontrol.apiserver.k8s.io/v1 (1.29.0)
   ```

5. Convert an offending manifest with the official plugin (install `kubectl-convert` separately — it is not built into `kubectl`):

   ```bash
   kubectl convert -f ./manifests/my-flow.yaml --output-version flowcontrol.apiserver.k8s.io/v1
   ```

6. Inventory the things that break *silently* on a minor upgrade because they are out-of-tree: admission webhooks, CRDs with a removed `apiextensions` version, and CSI/CNI/device plugins.

   ```bash
   kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
   kubectl get crd -o custom-columns='NAME:.metadata.name,VERSIONS:.spec.versions[*].name'
   kubectl -n kube-system get ds -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
   ```

7. Check each third-party component's own compatibility matrix for v1.34 (Calico/Cilium, the CSI drivers, ingress controller, cert-manager, Prometheus operator…). Record any that must be upgraded **first**.

### ✅ Checkpoint 4

- **Q4.1** — `apiserver_requested_deprecated_apis` shows `removed_release="1.35"` for a group you use. You are upgrading to v1.34. Is this urgent? What do you do with the finding?
- **Q4.2** — A `Deployment` was created years ago via `apps/v1beta2`. Today `kubectl get deploy -o yaml` returns `apps/v1`. Explain the storage-vs-serving mechanism that makes this true, and why the object survives the removal of `apps/v1beta2` while a Git manifest does not.
- **Q4.3** — Why is a `ValidatingWebhookConfiguration` a potential *cluster-wide outage* during an upgrade, and what field controls the blast radius?
- **Q4.4** — Name the security-relevant reason this "check removed APIs" exercise belongs in a **security** objective at all, rather than only in a reliability runbook.

---

## Exercise 5 — Plan the upgrade (`kubeadm upgrade plan`)

`kubeadm` upgrades **one minor version at a time**, and it will only install the version matching its own binary. So the plan step is really two steps: repoint the package repository, install the new `kubeadm`, *then* plan.

### Steps

1. Inspect the current repository definition. On the community `pkgs.k8s.io` repos, **the minor version is baked into the URL** — this is the number-one reason `apt-cache madison kubeadm` shows no v1.34 candidate:

   ```bash
   cat /etc/apt/sources.list.d/kubernetes.list
   ```

   ```
   deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /
   ```

2. Repoint the repository to v1.34 **and re-import the signing key** (each minor-version repo is signed separately):

   **Debian / Ubuntu**

   ```bash
   sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
     | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
     | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   ```

   **RHEL / Fedora / CentOS**

   ```bash
   cat <<'EOF' | sudo tee /etc/yum.repos.d/kubernetes.repo
   [kubernetes]
   name=Kubernetes
   baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
   enabled=1
   gpgcheck=1
   gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
   exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
   EOF
   ```

3. List the available patch versions and pick a concrete one. Never install unpinned:

   ```bash
   sudo apt-cache madison kubeadm | head
   # RPM: sudo dnf --showduplicates list kubeadm
   ```

   ```
      kubeadm | 1.34.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb/  Packages
      kubeadm | 1.34.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb/  Packages
   ```

4. Install **only** `kubeadm` for now, releasing and reapplying the version hold:

   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get install -y kubeadm=1.34.1-1.1
   sudo apt-mark hold kubeadm
   sudo kubeadm version -o short
   ```

   ```
   kubeadm set on hold.
   v1.34.1
   ```

   **RPM equivalent:**
   ```bash
   sudo dnf install -y kubeadm-1.34.1-150500.1.1 --disableexcludes=kubernetes
   ```

5. Run the plan. Read every line — this output *is* the change plan, and it tells you explicitly which components kubeadm will **not** handle:

   ```bash
   sudo kubeadm upgrade plan
   ```

   ```
   [preflight] Running pre-flight checks.
   [upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Running cluster health checks
   [upgrade] Fetching available versions to upgrade to
   [upgrade/versions] Cluster version: v1.33.4
   [upgrade/versions] kubeadm version: v1.34.1
   [upgrade/versions] Target version: v1.34.1
   [upgrade/versions] Latest version in the v1.33 series: v1.33.6

   Components that must be upgraded manually after you have upgraded the control plane
   with 'kubeadm upgrade apply':
   COMPONENT   NODE   CURRENT   TARGET
   kubelet     cp01   v1.33.4   v1.34.1
   kubelet     w01    v1.33.4   v1.34.1
   kubelet     w02    v1.33.4   v1.34.1

   Upgrade to the latest stable version:

   COMPONENT                 NODE   CURRENT   TARGET
   kube-apiserver            cp01   v1.33.4   v1.34.1
   kube-controller-manager   cp01   v1.33.4   v1.34.1
   kube-scheduler            cp01   v1.33.4   v1.34.1
   kube-proxy                       1.33.4    v1.34.1
   CoreDNS                          v1.12.0   v1.12.1
   etcd                      cp01   3.6.4-0   3.6.4-0

   You can now apply the upgrade by executing the following command:

           kubeadm upgrade apply v1.34.1

   _____________________________________________________________________
   ```

   > Your exact `etcd` and `CoreDNS` target versions will differ by release; read them from *your* output, not from this page.

6. Rehearse without mutating anything. `--dry-run` renders the new manifests into a temporary directory and runs the same preflight logic:

   ```bash
   sudo kubeadm upgrade apply v1.34.1 --dry-run
   ```

7. Note that the plan reported `v1.33.6` as "latest in the v1.33 series". If your only goal is closing a CVE fixed in v1.33.6, **that is the upgrade you should be doing** (see Q2.1).

### ✅ Checkpoint 5

- **Q5.1** — `apt-cache madison kubeadm` shows only 1.33.x even after `apt-get update`. What is the cause, and what is the fix?
- **Q5.2** — Why does `kubeadm upgrade plan` list the kubelets under *"must be upgraded manually"*? What is the design reason kubeadm refuses to do it?
- **Q5.3** — What does `apt-mark hold kubeadm` protect you from, and why is it a *security* control and not just an operational nicety?
- **Q5.4** — You install `kubeadm=1.34.1-1.1` but run `kubeadm upgrade apply v1.34.0`. What happens?
- **Q5.5** — In the plan output, `etcd` shows `3.6.4-0 → 3.6.4-0`. Does kubeadm restart the etcd static Pod anyway? Which flag would you use to keep etcd untouched, and when is that justified?

---

## Exercise 6 — Upgrade the first control-plane node

Order matters and is non-negotiable: **control-plane components first, then drain, then the node's own `kubelet`/`kubectl`, then uncordon.**

### Steps

1. Apply the control-plane upgrade. This is the only node where you run `apply`:

   ```bash
   sudo kubeadm upgrade apply v1.34.1
   ```

   ```
   [upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [preflight] Running pre-flight checks.
   [upgrade] Running cluster health checks
   [upgrade/version] You have chosen to change the cluster version to "v1.34.1"
   [upgrade/versions] Cluster version: v1.33.4
   [upgrade/versions] kubeadm version: v1.34.1
   [upgrade] Are you sure you want to proceed? [y/N]: y
   [upgrade/prepull] Pulling images required for setting up a Kubernetes cluster
   [upgrade/apply] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1" (timeout: 5m0s)...
   [upgrade/etcd] Upgrading etcd
   [upgrade/staticpods] Preparing for "etcd" upgrade
   [upgrade/staticpods] Writing new Static Pod manifests to "/etc/kubernetes/tmp/kubeadm-upgraded-manifests..."
   [upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/kube-apiserver.yaml"
   [upgrade/staticpods] Waiting for the kubelet to restart the component
   [apiclient] Found 1 Pods for label selector component=kube-apiserver
   [upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
   ...
   [upgrade/postupgrade] Removing the old taint ...
   [addons] Applied essential addon: CoreDNS
   [addons] Applied essential addon: kube-proxy

   [upgrade] SUCCESS! A control plane instance for this node was upgraded to "v1.34.1".

   [upgrade] Now please proceed with upgrading the kubelet on this node if you haven't already done so.
   ```

   For unattended runs add `-y`. To skip the interactive confirmation *and* the etcd upgrade: `sudo kubeadm upgrade apply v1.34.1 -y --etcd-upgrade=false`.

2. Confirm the control plane really moved, before touching the kubelet:

   ```bash
   kubectl version | grep Server
   kubectl -n kube-system get pods -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   ```
   Server Version: v1.34.1
   POD                            IMAGE
   etcd-cp01                      registry.k8s.io/etcd:3.6.4-0
   kube-apiserver-cp01            registry.k8s.io/kube-apiserver:v1.34.1
   kube-controller-manager-cp01   registry.k8s.io/kube-controller-manager:v1.34.1
   kube-scheduler-cp01            registry.k8s.io/kube-scheduler:v1.34.1
   ```

   Note that `kubectl get nodes` **still** shows `v1.33.4` for `cp01` — the kubelet has not been touched yet.

3. Drain the node. `--ignore-daemonsets` is mandatory on any real cluster (CNI and `kube-proxy` are DaemonSets and cannot be evicted):

   ```bash
   kubectl drain cp01 --ignore-daemonsets
   ```

   ```
   node/cp01 cordoned
   Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-8x2vq, kube-system/kube-proxy-lm4rt
   evicting pod kube-system/coredns-6f9c7d8b4-h2kqz
   pod/coredns-6f9c7d8b4-h2kqz evicted
   node/cp01 drained
   ```

   If it hangs on local storage, add `--delete-emptydir-data`. If it refuses because of a bare Pod not owned by a controller, add `--force` — and understand that `--force` **deletes that Pod permanently**, it does not reschedule it.

4. Upgrade the node's `kubelet` and `kubectl` packages:

   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
   sudo apt-mark hold kubelet kubectl
   ```

   **RPM:**
   ```bash
   sudo dnf install -y kubelet-1.34.1-150500.1.1 kubectl-1.34.1-150500.1.1 --disableexcludes=kubernetes
   ```

5. Reload systemd and restart the kubelet. **`daemon-reload` is required** — the package may have changed the unit or its drop-ins:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   sudo systemctl status kubelet --no-pager | head -12
   ```

6. Return the node to service:

   ```bash
   kubectl uncordon cp01
   kubectl get nodes
   ```

   ```
   node/cp01 uncordoned
   NAME   STATUS   ROLES           AGE   VERSION
   cp01   Ready    control-plane   31d   v1.34.1
   w01    Ready    <none>          31d   v1.33.4
   w02    Ready    <none>          31d   v1.33.4
   ```

7. Confirm the certificate renewal side effect from Exercise 3:

   ```bash
   sudo kubeadm certs check-expiration | head -6
   ```

   ```
   CERTIFICATE   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   admin.conf    Jul 31, 2027 11:42 UTC   364d            no
   apiserver     Jul 31, 2027 11:42 UTC   364d            no
   ```

### ✅ Checkpoint 6

- **Q6.1** — Why must the node be drained *before* `apt-get install kubelet`, and not after?
- **Q6.2** — After step 1 succeeded, `kubectl get nodes` still reports `v1.33.4` for `cp01`. Is this a bug? Explain precisely what `kubeadm upgrade apply` did and did not change.
- **Q6.3** — Explain the mechanism by which writing a new file into `/etc/kubernetes/manifests/` upgrades `kube-apiserver`. Which component performs the restart?
- **Q6.4** — During step 1 the API server is briefly unavailable. Do running application Pods on `w01` stop serving traffic? Justify.
- **Q6.5** — You forget `systemctl daemon-reload` and only run `systemctl restart kubelet`. What class of bug does this invite?
- **Q6.6** — What is the exact difference in effect between `--force` and `--delete-emptydir-data` on `kubectl drain`, and which one can cause permanent data loss?

---

## Exercise 7 — Additional control-plane nodes, then the workers

The second control-plane node and every worker use `kubeadm upgrade node`, **never** `apply`. `apply` is the "decide the cluster's target version" operation; `node` is the "conform this node to the already-decided version" operation.

### Steps

1. On any *additional* control-plane node (`cp02`), install the matching `kubeadm`, then:

   ```bash
   sudo kubeadm upgrade node
   ```

   ```
   [upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"...
   [upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
   [upgrade] The control plane instance for this node was successfully upgraded!
   ```

   Then drain → upgrade `kubelet`/`kubectl` → `daemon-reload` → `restart kubelet` → uncordon, exactly as in Exercise 6.

2. Before draining the first worker, look for PodDisruptionBudgets that could block eviction indefinitely:

   ```bash
   kubectl get pdb -A
   ```

   ```
   NAMESPACE   NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
   payments    api-pdb       2               N/A               0                     14d
   ```

   `ALLOWED DISRUPTIONS: 0` means `kubectl drain` will loop forever on that Pod. Fix the *cause* (scale up the Deployment, or correct an over-strict PDB) — do not reach for `--disable-eviction`.

3. On `w01`, install the new `kubeadm` (repo repoint + pinned install, as in Exercise 5), then update the node's local kubelet configuration:

   ```bash
   sudo kubeadm upgrade node
   ```

   ```
   [upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
   [upgrade] Skipping phase. Not a control plane node.
   [upgrade] Upgrading kubelet configuration for this node
   [upgrade] The configuration for this node was successfully updated!
   [upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.
   ```

4. From the **control-plane node** (or wherever your `kubectl` lives), drain the worker:

   ```bash
   kubectl drain w01 --ignore-daemonsets --delete-emptydir-data
   ```

5. Back on `w01`, upgrade and restart the kubelet:

   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
   sudo apt-mark hold kubelet kubectl
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

6. Uncordon and **wait for the node to be genuinely healthy** before touching `w02`:

   ```bash
   kubectl uncordon w01
   kubectl get nodes -w    # Ctrl-C when w01 is Ready at v1.34.1
   ```

7. Repeat steps 3–6 for `w02`. **One node at a time.** Verify the `kube-proxy` DaemonSet rolled onto each upgraded node:

   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
   ```

### ✅ Checkpoint 7

- **Q7.1** — What exactly does `kubeadm upgrade node` do on a worker, given that it explicitly does *not* install the kubelet binary? Why is the step not skippable?
- **Q7.2** — A drain has been stuck for 10 minutes on `payments/api-*`. `kubectl get pdb -A` shows `ALLOWED DISRUPTIONS: 0`. Give two correct remediations and one that a reviewer should reject.
- **Q7.3** — Why does `kubectl drain` never evict DaemonSet Pods, and why does that make `--ignore-daemonsets` effectively mandatory rather than optional?
- **Q7.4** — You upgrade `kubelet` on `w01` to v1.34.1 but the `kube-proxy` DaemonSet still runs the v1.33.4 image because you skipped the control plane. Is that a supported skew? What is the ordering rule you broke?
- **Q7.5** — Explain the practical, security-relevant reason for doing workers strictly one at a time rather than draining all of them in parallel.

---

## Exercise 8 — Verify the upgrade, and verify the *artefacts* you installed

An upgrade is not finished when `kubectl get nodes` looks nice. Two things remain: prove the cluster is healthy, and prove that what you installed is what the Kubernetes project actually published (supply-chain integrity — the other half of "upgrade to avoid vulnerabilities").

### Steps

1. Diff against the Exercise 1 baseline:

   ```bash
   kubectl get nodes -o wide
   kubectl version
   kubectl -n kube-system get pods -l tier=control-plane \
     -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image'
   ```

   Every `VERSION` should read `v1.34.1`; every control-plane image tag should read `v1.34.1`.

2. Check API-server health endpoints individually — `readyz?verbose` names the failing check instead of just returning non-200:

   ```bash
   kubectl get --raw='/readyz?verbose' | tail -20
   ```

   ```
   [+]etcd ok
   [+]etcd-readiness ok
   [+]informer-sync ok
   [+]poststarthook/start-kube-apiserver-admission-initializer ok
   [+]shutdown ok
   readyz check passed
   ```

3. Confirm nothing is stuck or crash-looping cluster-wide:

   ```bash
   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
   kubectl get events -A --sort-by=.lastTimestamp | tail -20
   ```

4. Re-run the deprecated-API metric from Exercise 4. It resets on API-server restart, so let real traffic flow for a while first:

   ```bash
   kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
   ```

5. Re-run your CIS benchmark. A minor upgrade rewrites the static Pod manifests, which can silently reset a hardening flag you had added by hand:

   ```bash
   kubectl run kube-bench --image=docker.io/aquasec/kube-bench:latest --rm -it --restart=Never \
     --overrides='{"spec":{"hostPID":true,"nodeName":"cp01","tolerations":[{"operator":"Exists"}],"volumes":[{"name":"etc","hostPath":{"path":"/etc"}},{"name":"var","hostPath":{"path":"/var"}}],"containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:latest","command":["kube-bench","run","--targets","master"],"volumeMounts":[{"name":"etc","mountPath":"/etc","readOnly":true},{"name":"var","mountPath":"/var","readOnly":true}]}]}}'
   ```

6. **Verify artefact integrity.** If you download binaries directly rather than via packages, always check the published SHA-256:

   ```bash
   curl -LO "https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl"
   curl -LO "https://dl.k8s.io/release/v1.34.1/bin/linux/amd64/kubectl.sha256"
   echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
   ```

   ```
   kubectl: OK
   ```

7. **Verify signatures.** Kubernetes signs release images and binaries with Sigstore/cosign (keyless, recorded in Rekor):

   ```bash
   cosign verify registry.k8s.io/kube-apiserver:v1.34.1 \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com \
     | jq '.[0].optional.Subject'
   ```

   The exact identity/issuer strings are release-engineering details that change; take them from **https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/** rather than from memory.

8. Close the loop on the runtime and kernel that Kubernetes did not touch:

   ```bash
   sudo apt-get install -y --only-upgrade containerd.io runc
   sudo systemctl restart containerd
   sudo crictl version
   # kernel CVEs require a reboot; schedule it with the same drain/uncordon discipline
   ```

9. Re-check the CVE that motivated the upgrade: confirm your now-running version is at or above the **fixed-in** version from Exercise 2.

### ✅ Checkpoint 8

- **Q8.1** — After the upgrade, `kubectl get --raw='/readyz?verbose'` shows `[-]etcd failed: reason withheld`. Name two plausible causes tied specifically to the upgrade you just performed.
- **Q8.2** — You had manually added `--audit-log-path` to `/etc/kubernetes/manifests/kube-apiserver.yaml`. Does `kubeadm upgrade apply` preserve it? What is the durable way to make such a flag survive every future upgrade?
- **Q8.3** — `sha256sum --check` passes on a downloaded `kubectl`. What attack does that defeat, and what attack does it **not** defeat? Which step in this exercise covers the gap?
- **Q8.4** — Why does the `apiserver_requested_deprecated_apis` metric read `0` (or vanish) immediately after the upgrade even in a cluster full of legacy clients?
- **Q8.5** — You upgraded Kubernetes to v1.34.1 to close a container-escape CVE, but the advisory's affected component was `runc`. Did the Kubernetes upgrade remediate it? What is the correct action, and what does it require of the node?

---

## Exercise 9 — Failure drill: what "rollback" actually means

There is no `kubeadm downgrade`. Rehearse the real recovery path once, in the lab, so you are not learning it during an incident.

### Steps

1. Simulate a failed upgrade: stop the kubelet mid-flight on a scratch node and observe the state.

   ```bash
   sudo systemctl stop kubelet
   sudo kubeadm upgrade apply v1.34.1 -y   # will time out waiting for static Pods
   ```

   ```
   [upgrade/staticpods] Waiting for the kubelet to restart the component
   [kubelet-check] It seems like the kubelet isn't running or healthy.
   ...
   couldn't upgrade control plane. kubeadm has tried to recover everything into the earlier state.
   Errors faced: [timed out waiting for the condition]
   ```

2. Observe kubeadm's own recovery: it keeps the previous manifests under `/etc/kubernetes/tmp/`. Inspect them:

   ```bash
   sudo ls -la /etc/kubernetes/tmp/
   sudo ls -la /etc/kubernetes/manifests/
   ```

3. Recover forward — start the kubelet and let the static Pods reconcile:

   ```bash
   sudo systemctl start kubelet
   sudo crictl ps | grep -E 'apiserver|scheduler|controller'
   ```

4. Retry with `--force` only if kubeadm refuses because of a version mismatch it recorded mid-failure:

   ```bash
   sudo kubeadm upgrade apply v1.34.1 --force -y
   ```

5. Rehearse the full rollback (destructive — lab only). Stop the control plane, restore the snapshot into a **new** data directory, and repoint etcd:

   ```bash
   sudo mv /etc/kubernetes/manifests /etc/kubernetes/manifests.off   # stop static Pods
   sudo etcdutl snapshot restore /var/backups/etcd-pre-1.34-2026-07-31.db \
     --data-dir /var/lib/etcd-restored
   sudo sed -i 's#path: /var/lib/etcd#path: /var/lib/etcd-restored#' \
     /etc/kubernetes/manifests.off/etcd.yaml
   ```

6. Downgrade the packages to the pre-upgrade pin, restore the manifests, and restart:

   ```bash
   sudo apt-mark unhold kubeadm kubelet kubectl
   sudo apt-get install -y --allow-downgrades kubeadm=1.33.4-1.1 kubelet=1.33.4-1.1 kubectl=1.33.4-1.1
   sudo apt-mark hold kubeadm kubelet kubectl
   sudo mv /etc/kubernetes/manifests.off /etc/kubernetes/manifests
   sudo systemctl daemon-reload && sudo systemctl restart kubelet
   ```

   (You will also need to repoint the apt repository URL back to `v1.33`.)

7. Verify, and note in your runbook exactly how long this took.

### ✅ Checkpoint 9

- **Q9.1** — `kubeadm` reported *"has tried to recover everything into the earlier state"*. What did it restore, and what did it explicitly **not** restore?
- **Q9.2** — Why does `etcdutl snapshot restore` insist on an empty, new `--data-dir` rather than overwriting `/var/lib/etcd`?
- **Q9.3** — Restoring an etcd snapshot taken before the upgrade discards every object written since. Name two categories of object whose loss would be operationally severe and are easy to forget.
- **Q9.4** — Given that rollback is this expensive, state the two practices from Exercises 3–5 that most reduce the probability of ever needing it.

---

## Exercise 10 — Exam speed-run

Memorise this. On the exam you will be given a target version and told which nodes to touch.

**On the control-plane node (`ssh cp01`):**

```bash
# 1. repoint repo to the target minor version + re-import key
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2. kubeadm only
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

# 3. plan + apply
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.34.1 -y

# 4. drain, upgrade kubelet+kubectl, restart, uncordon
kubectl drain cp01 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon cp01
```

**On each worker (`ssh node01`) — note `upgrade node`, not `apply`:**

```bash
# repo repoint (same as above), then:
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm
sudo kubeadm upgrade node
# from the control plane / wherever kubectl works:
kubectl drain node01 --ignore-daemonsets --delete-emptydir-data
# back on node01:
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon node01
```

**The five mistakes that cost points:**

1. Forgetting to repoint the repository URL to the new minor version (then "the package doesn't exist").
2. Running `kubeadm upgrade apply` on a worker instead of `kubeadm upgrade node`.
3. Forgetting `--ignore-daemonsets` and concluding the drain is broken.
4. Forgetting `systemctl daemon-reload` before `restart kubelet`.
5. Forgetting `kubectl uncordon` — the task is not complete while the node is `SchedulingDisabled`.

### ✅ Checkpoint 10

- **Q10.1** — The exam task says *"upgrade the control plane node only; do not upgrade the worker nodes."* Which of the commands above do you run, and which do you deliberately skip?
- **Q10.2** — After finishing, `kubectl get nodes` shows `cp01 Ready,SchedulingDisabled v1.34.1`. Have you completed the task? What is the one remaining command?

---

<details>
<summary><strong>📖 Answers — click to expand</strong></summary>

### Checkpoint 1

**Q1.1** — It is the **kubelet** version, as self-reported by the node in `.status.nodeInfo.kubeletVersion`. It is emphatically **not** the `kube-apiserver` version. Immediately after `kubeadm upgrade apply` the API server is on the new version while the `VERSION` column still shows the old one — the two are decoupled by design. Get the API server's version from `kubectl version` (`Server Version:`) or from the static Pod image tag.

**Q1.2** — `kubeadm` supports upgrading **exactly one minor version at a time**. `kubeadm upgrade plan` / `apply` will refuse a v1.31 → v1.34 jump at preflight. The correct path is sequential: v1.31 → v1.32 → v1.33 → v1.34, each hop with its own `kubeadm` binary, its own repository URL, and its own kubelet rollout. The constraint exists because storage-version migrations, API removals and feature-gate transitions are only validated between adjacent minors. Additionally, `kubeadm upgrade plan` on a v1.31 cluster will only ever offer you v1.32.

**Q1.3** — Yes, this is supported. `kubelet` may be up to **three minor versions older** than `kube-apiserver` (since v1.28; it was two before that). It must **never** be newer. So v1.34.1 apiserver with v1.33.4 kubelets is fine, and could in principle persist for three minors — but "supported" is not "secure": those kubelets are still carrying whatever CVE you upgraded to fix. Treat the skew allowance as a rollout window measured in hours or days, not as a resting state.

**Q1.4** — Not supported. `kubectl` is supported within **one minor version** of `kube-apiserver` (older or newer), so v1.31 against a v1.34 server is three minors out. Expected symptoms: missing or unrecognised fields being silently dropped on `apply`, subcommands failing against APIs the old client doesn't know, and `kubectl` warning `client version is older than server version`. This is worse than an outage because it fails *quietly* — a stripped `securityContext` on apply is a real security regression.

**Q1.5** — The skew policy is asymmetric on purpose: components may be *older* than the API server, never *newer*. A newer kubelet will attempt to use API groups, fields and subresources that the older API server does not serve, producing registration failures, dropped fields and a node that may never become `Ready`. The API server is the schema authority; everything else must trail it. This is exactly why `kubeadm upgrade apply` (control plane) precedes the `kubelet` package install on every node.

**Q1.6** — No. `kubeadm` manages `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`, `kube-proxy` and `CoreDNS`, plus the kubelet's *configuration*. It never touches `containerd`, `runc`, the CNI plugin binaries, or the kernel. Since the highest-severity container-escape CVEs historically live in `runc` and the kernel (e.g. the `runc` file-descriptor-leak class of bugs), a cluster can be fully patched at the Kubernetes layer and still trivially escapable. Node OS patching is a separate, mandatory track with its own drain/reboot discipline.

### Checkpoint 2

**Q2.1** — Upgrade to **v1.33.6**, the patch release in your current minor series. It closes the CVE while changing nothing about API surfaces, feature gates, addon versions, or third-party compatibility — the blast radius is a binary swap. Jumping to v1.34.1 also closes the CVE but simultaneously ships a minor's worth of API removals, defaulting changes and behavioural drift, so you would be coupling an urgent security fix to a change that requires the whole Exercise-4 compatibility review. Security response and platform modernisation are separate changes and should be separate maintenance windows.

**Q2.2** — v1.29 is outside the three-most-recent-minors support window, so it receives **no security patches at all**: every CVE disclosed against it from now on is permanently unfixed in that branch, and disclosure makes the exploit public. Running an EOL Kubernetes is accepting an unbounded and monotonically growing set of known-exploitable vulnerabilities.

**Q2.3** — The `CONTAINER-RUNTIME` column (`containerd://2.0.5`, and the `runc` version behind it) and `KERNEL-VERSION`. The Kubernetes CVE feed only covers CVEs in the `kubernetes/kubernetes` project and its subprojects; `runc`, `containerd` and the Linux kernel are separate upstreams with separate advisories, tracked by your distro's security feed. The great majority of true *container escapes* originate there, not in Kubernetes.

**Q2.4** — The feed is auto-generated from GitHub issues labelled `official-cve-feed` in `kubernetes/kubernetes`, maintained by the Security Response Committee. That makes it programmatically consumable and low-latency — an entry appears as soon as the SRC files it, with no separate publishing step to fall behind. The trade-off: it covers only CVEs the Kubernetes project has *accepted and filed*, so it is authoritative for Kubernetes itself and silent about dependencies, vendor distributions and third-party addons. Consume it as one input, not as your whole vulnerability picture.

**Q2.5** — A patch release changes only bug fixes within a stable API and feature-gate surface; a minor release can remove APIs (Exercise 4), flip feature gates to on-by-default, change admission defaults, bump `CoreDNS`/`etcd`, and break third-party controllers, CSI drivers and CNI plugins that pin to a compatibility matrix. So the minor upgrade carries all the CVE-closing benefit plus a much larger set of ways to cause an outage — and outages taken while responding to a security incident are the worst possible time to discover a compatibility break.

### Checkpoint 3

**Q3.1** — kubeadm rejects it. Downgrades are not supported: `kubeadm upgrade apply` validates that the requested version is not older than the current cluster version and fails preflight. Your only real path back to v1.32 is a **restore**: stop the control plane, restore the pre-upgrade etcd snapshot into a fresh data directory, downgrade the `kubeadm`/`kubelet`/`kubectl` packages (with the repository repointed to the old minor), restore the old static Pod manifests and PKI from your `/etc/kubernetes` tarball, and restart the kubelet. This is precisely why Exercise 3 is not optional.

**Q3.2** — A version mismatch between the data in etcd (written by v1.33 with v1.33 storage versions) and a v1.34 control plane, *and* the reverse hazard: a v1.34 API server may have already migrated objects to storage versions the restored data does not contain, or the restored data may contain objects in serving versions v1.34 no longer serves. Expect API server crash-loops, objects that fail to decode, and controllers that cannot reconcile. **Restore the manifests and the packages together with the data** — the snapshot and the binaries are one atomic unit of state.

**Q3.3** — `kubeadm upgrade apply` (and `kubeadm upgrade node`) renews **all kubeadm-managed control-plane certificates** — `apiserver`, `apiserver-kubelet-client`, `apiserver-etcd-client`, `front-proxy-client`, `etcd-server`, `etcd-peer`, `etcd-healthcheck-client` — and the client certificates embedded in `admin.conf`, `controller-manager.conf` and `scheduler.conf`, each for another year. Disable with `--certificate-renewal=false`. You would disable it when certificates are **externally managed** (issued by your corporate PKI, cert-manager, or Vault), where kubeadm's self-signed renewal would replace a properly issued cert with one your trust chain does not accept.

**Q3.4** — `server.crt` is etcd's *serving* certificate; it identifies the server to clients, and its key must never be handed to an arbitrary client process. `healthcheck-client.crt` (like `apiserver-etcd-client.crt`) is a *client* certificate signed by the etcd CA with client-auth EKU, which is what etcd's mutual-TLS client authentication actually validates on an incoming connection. Using the server key may work by accident on some configurations, but it is a credential-handling error: it spreads the serving key to more places than necessary.

**Q3.5** — The etcd cluster is no longer managed by kubeadm, so: (a) `kubeadm upgrade plan` will not show an etcd row and `kubeadm upgrade apply` will not upgrade or restart etcd; (b) you take the snapshot against the external endpoints using the *external* etcd CA and client certs, not the ones under `/etc/kubernetes/pki/etcd/`; (c) upgrading etcd itself becomes a separate, manually sequenced task with its own version-compatibility check against the target Kubernetes release; (d) `--etcd-upgrade` is irrelevant. See https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/.

### Checkpoint 4

**Q4.1** — Not urgent for *this* upgrade — `removed_release="1.35"` means the API still works in v1.34, so the v1.34 upgrade will not break it. But it is a hard blocker for the *next* one, and you have exactly one release cycle to fix it. Correct handling: file it now with an owner, identify the calling client from `apiserver_request_total` (`userAgent` label) and audit logs, migrate the manifests to the replacement version with `kubectl convert` or by hand, and re-check the metric before you plan v1.35. Do not let it become a v1.35-day surprise.

**Q4.2** — Kubernetes distinguishes the **storage version** (the single version an object is persisted as in etcd) from the **served versions** (all versions the API server will convert to and from on request). The object was stored once under whatever the storage version was, and every read is converted on the fly to the version you request; `kubectl get -o yaml` shows `apps/v1` because that is the preferred served version today. So the live object survives the removal of `apps/v1beta2` — only *requests* naming the removed version fail. A YAML file in Git is a request waiting to happen: `kubectl apply -f` of an `apps/v1beta2` manifest fails hard after removal. That asymmetry is why scanning the live cluster is not sufficient and you must scan your manifest sources too.

**Q4.3** — A webhook with `failurePolicy: Fail` that becomes unreachable causes the API server to **reject every matching request**, and if its `rules` are broad (`apiGroups: ["*"]`, `resources: ["*"]`) that means the whole cluster stops accepting writes — including the writes needed to fix the webhook. Upgrades trigger this by restarting the API server, restarting the webhook's own Pods during drains, or by the webhook's client library being incompatible with the new `admissionregistration.k8s.io` version. The blast-radius controls are `failurePolicy`, the `rules` scoping, `namespaceSelector`/`objectSelector` (in particular excluding `kube-system`), and `timeoutSeconds`.

**Q4.4** — Because a broken upgrade is routinely "fixed" under pressure by disabling the safety control that broke. When a security webhook (OPA/Gatekeeper, Kyverno, an image-signature verifier) fails after an upgrade, the fastest path back to a working cluster is to set `failurePolicy: Ignore` or delete the webhook configuration — and that temporary fix becomes permanent, leaving the cluster admitting unsigned images and privileged Pods indefinitely. Doing the compatibility review *before* the upgrade is what prevents the incident that degrades your security posture.

### Checkpoint 5

**Q5.1** — The `pkgs.k8s.io` community repositories are **per-minor-version**: the URL `.../core:/stable:/v1.33/deb/` contains only v1.33 packages and will never serve v1.34, no matter how often you `apt-get update`. Fix: rewrite `/etc/apt/sources.list.d/kubernetes.list` to `.../core:/stable:/v1.34/deb/`, re-import that repo's `Release.key` into `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` (each repo is signed independently), then `apt-get update`. See https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/. This is the single most common stumble on this exam task.

**Q5.2** — Because the `kubelet` is an **operating-system-level package and systemd unit on every node**, not a container the control plane can reschedule. kubeadm has no remote execution channel into your nodes — it is a local bootstrapping tool, deliberately not a configuration-management system. It does what it can reach: it updates the node's kubelet *configuration* (via `kubeadm upgrade node`) and tells you to install the binary yourself. That separation is why kubelet rollout is your job (or Ansible's / your image pipeline's), node by node.

**Q5.3** — It pins the installed version so that an unrelated `apt-get upgrade` or an automated `unattended-upgrades` run cannot move `kubelet`/`kubeadm`/`kubectl` underneath you. Security relevance: an out-of-band bump can silently push a `kubelet` **newer than the API server**, violating the skew policy and breaking the node; conversely, an unpinned mass upgrade across the fleet can restart every kubelet simultaneously. Version control over the components that enforce your authentication, authorisation and admission path is itself a security control — you want upgrades to happen on your schedule, in your order, with your verification.

**Q5.4** — It fails at preflight. `kubeadm` refuses to apply a version that does not match its own binary version, with an error along the lines of *"the --version argument is invalid due to these errors: … kubeadm version v1.34.1 is not the same as the requested version v1.34.0"*. The rule is: install the exact `kubeadm` patch you intend to run, then pass that same version to `apply`. (`--force` can override some preflight failures but is not a way around this — install the right `kubeadm`.)

**Q5.5** — Yes. `kubeadm upgrade apply` rewrites `/etc/kubernetes/manifests/etcd.yaml` as part of the upgrade even when the image tag is unchanged, and any write to that file makes the kubelet restart the static Pod. On a single-node stacked-etcd control plane that is a brief full-cluster write outage. Use `--etcd-upgrade=false` to leave etcd alone; justified when etcd is externally managed, when you have a separate etcd maintenance window, or when you are deliberately minimising the change set of an urgent patch-level security upgrade. Always take the snapshot first regardless.

### Checkpoint 6

**Q6.1** — Because `apt-get install kubelet` triggers a kubelet restart, and on a busy node that briefly interrupts the process supervising every container. Draining first moves workloads off and cordons the node so the scheduler does not place new ones there, so the restart happens on an idle node. Reversing the order means a live restart under load: eviction of Pods that were mid-request, possible container restarts, and — if the new kubelet fails to start due to a config incompatibility — an outage of everything that was still running there. On the control-plane node the same argument applies to `CoreDNS` and any other non-DaemonSet workload scheduled there.

**Q6.2** — Not a bug; it is the expected intermediate state. `kubeadm upgrade apply` rewrote the **static Pod manifests** for `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `etcd`, upgraded the `kube-proxy` and `CoreDNS` addons, renewed the certificates, and updated the `kubeadm-config` / `kubelet-config` ConfigMaps. It did **not** install a new `kubelet` binary on any node, including this one. `kubectl get nodes` reports `.status.nodeInfo.kubeletVersion`, so it keeps showing `v1.33.4` until you install the package and restart the service in steps 4–5.

**Q6.3** — The **kubelet** performs it. The kubelet watches its `staticPodPath` (`/etc/kubernetes/manifests`, set in `/var/lib/kubelet/config.yaml`) and treats every manifest there as a Pod it owns directly, with no API server involvement. When kubeadm writes a new `kube-apiserver.yaml` with an updated image tag, the kubelet notices the file change, kills the old container and starts one from the new image. This is why the control plane can be upgraded even while the API server is down, and why a kubelet that is stopped (Exercise 9) causes `kubeadm upgrade apply` to hang and time out.

**Q6.4** — No — already-running Pods keep serving. The API server is the control plane's coordination point, not a data-path component: `kubelet` continues managing its existing containers, `kube-proxy` keeps the iptables/IPVS rules it already programmed, and the CNI dataplane is untouched. What stops is *change*: no new scheduling, no Deployment rollouts, no Service/Endpoint updates, no `kubectl`, and — importantly — no reaction to Pod failures. So a Pod that crashes during the window will not be restarted or rescheduled until the API server returns. Short, but not zero-risk.

**Q6.5** — systemd continues running the **cached** unit definition. If the package shipped a changed `kubelet.service` or a new drop-in under `/etc/systemd/system/kubelet.service.d/` (which is where kubeadm puts `10-kubeadm.conf`), the restarted kubelet starts with stale `ExecStart` flags or an outdated `--config` path. Symptoms range from the kubelet failing to register, to it running silently with the *previous* release's flags — including, potentially, security-relevant ones like `--authorization-mode`, `--anonymous-auth` or the TLS settings. Always `daemon-reload` before `restart`.

**Q6.6** — `--delete-emptydir-data` permits eviction of Pods that have an `emptyDir` volume; the volume's contents are destroyed with the Pod, but the Pod itself is owned by a controller and will be **recreated elsewhere**. `--force` permits deletion of Pods that have **no controller** (bare Pods, or Pods orphaned from their owner); those are deleted and **never come back** — nothing exists to recreate them. `--force` is therefore the one that causes permanent workload loss; `--delete-emptydir-data` causes permanent *scratch-data* loss. Both should be conscious decisions, and on a production cluster you should know what bare Pods exist before you type `--force`.

### Checkpoint 7

**Q7.1** — On a worker, `kubeadm upgrade node` downloads the new cluster-wide kubelet configuration from the `kubelet-config` ConfigMap in `kube-system` and writes it to `/var/lib/kubelet/config.yaml`, and refreshes the node's kubeadm-managed client certificate/`kubelet.conf` as needed. It does not install any binary. It is not skippable because the new kubelet binary expects the new configuration schema: skipping it can leave the node running v1.34 kubelet against a v1.33 config file, which at best ignores new defaults and at worst fails to start. On additional control-plane nodes it does more — it also upgrades that node's static Pod manifests.

**Q7.2** — Correct: (1) scale the Deployment up so `ALLOWED DISRUPTIONS` becomes ≥1 and the eviction can proceed while the PDB's availability guarantee still holds; (2) fix an over-strict or wrong PDB — e.g. `minAvailable: 2` on a 2-replica Deployment mathematically forbids all voluntary disruption, so correct it to `maxUnavailable: 1` or raise the replica count. Reject: `kubectl drain --disable-eviction`, which bypasses the eviction API and **deletes the Pods outright**, silently defeating the exact availability guarantee the application owner encoded in the PDB. (`--force` is likewise not the answer here — the Pods are controller-owned; the blocker is the budget, not ownership.)

**Q7.3** — Drain's contract is "move workloads to another node". DaemonSet Pods are, by definition, one-per-node and pinned to *this* node — the DaemonSet controller would immediately recreate any evicted Pod on the same node, so eviction is a no-op loop. `kubectl drain` therefore refuses to proceed rather than do something futile, unless you acknowledge it with `--ignore-daemonsets`. Since every real cluster runs the CNI plugin and `kube-proxy` as DaemonSets, the flag is required in practice on every drain — and it must be, because those Pods are exactly what the node still needs while it drains.

**Q7.4** — Unsupported in the sense that matters. `kube-proxy` must not be newer than `kube-apiserver` and should stay within one minor of the kubelet on its node — but the deeper breach is ordering: you upgraded a node-level component while the control plane is still older, which is the forbidden direction. The rule is **control plane first, always**: `kube-apiserver` → other control-plane components → `kubelet`/`kube-proxy` on each node. `kube-proxy`'s image is managed by the DaemonSet that `kubeadm upgrade apply` updates, so in the correct order this resolves itself. Check the authoritative table at https://kubernetes.io/releases/version-skew-policy/.

**Q7.5** — Capacity and blast radius. Draining several nodes at once can leave the cluster without room to reschedule the evicted Pods, so workloads sit `Pending` — and PDBs that were satisfiable one node at a time become unsatisfiable in parallel, stalling every drain simultaneously. The security-relevant part: a cluster in that state is one where the operator is under pressure and reaches for `--force`, `--disable-eviction`, or "just delete the PDB", each of which trades an availability or safety guarantee for speed. Serial rollout keeps every failure recoverable by simply stopping.

### Checkpoint 8

**Q8.1** — (1) The etcd static Pod was restarted by the upgrade (kubeadm rewrites `etcd.yaml` even on an unchanged version) and has not finished coming back — check `sudo crictl ps -a | grep etcd` and the container logs. (2) The `apiserver-etcd-client` certificate was renewed by `kubeadm upgrade apply`, but etcd is still presenting or trusting the old material because its Pod restarted at the wrong moment, or because your certificates are externally managed and the renewal replaced a properly issued cert with a kubeadm self-signed one. Also plausible: an etcd version bump with a data-directory or peer-URL mismatch. Diagnose with `sudo crictl logs $(sudo crictl ps -a --name etcd -q | head -1)`.

**Q8.2** — **No.** `kubeadm upgrade apply` regenerates the static Pod manifests from the `kubeadm-config` ConfigMap and its own templates, overwriting hand-edited flags. The durable fix is to put the flag in the cluster configuration rather than the manifest: `apiServer.extraArgs` in the `ClusterConfiguration` (and `extraVolumes` for any host paths the flag needs), applied with `kubeadm upgrade apply --config`, so every future upgrade regenerates the manifest *with* your flag. This is a first-class security concern — audit logging, admission plugin lists, encryption-at-rest config and TLS settings all live in these flags, and silently losing one during an upgrade is a hardening regression nobody gets alerted about. Re-running `kube-bench` after every upgrade is the detective control that catches it.

**Q8.3** — It defeats **corruption and tampering in transit or at rest on the mirror** — a truncated download, a malicious proxy, a compromised CDN edge — *provided* the checksum itself came from a trustworthy channel. It does **not** defeat an attacker who controls the distribution point, because they would publish a matching `.sha256` alongside the malicious binary; the checksum is not an identity proof, only an integrity proof relative to a URL you already trust. Step 7 covers the gap: `cosign verify` checks a cryptographic signature bound to a specific release-engineering identity and logged in the Rekor transparency log, so a forged artefact would need a valid signature from that identity and a public log entry attesting it.

**Q8.4** — Because `apiserver_requested_deprecated_apis` is a Prometheus metric held in the API server process's memory, and the upgrade restarted that process. All counters reset to zero. It only repopulates as clients actually make deprecated calls again — and infrequent callers (a nightly CronJob, a quarterly batch job, a human running an old script) may not appear for days or months. Consequence: check this metric over a long observation window *before* the upgrade, and never read a clean post-upgrade metric as evidence that nothing uses deprecated APIs.

**Q8.5** — No. The Kubernetes upgrade replaced `kube-apiserver`, `kubelet` and friends; it did not touch the `runc` binary that actually creates containers, so the escape remains fully exploitable. Correct action: upgrade `runc` (and usually `containerd` with it) through the node's package manager, then restart `containerd`. That restart interrupts the container runtime on the node, so it requires the same discipline as a kubelet upgrade — drain, patch, restart, verify, uncordon — and if the fix is in the kernel instead, a reboot in the same drain window. Node-level patching is a separate track from `kubeadm upgrade` and must be scheduled explicitly; assuming Kubernetes upgrades cover it is one of the most common real-world gaps.

### Checkpoint 9

**Q9.1** — It restored the **static Pod manifests** it had just replaced, from the backup copies it keeps under `/etc/kubernetes/tmp/kubeadm-backup-manifests-*`, so the control plane returns to its previous component versions. It did **not** roll back anything outside those files: `etcd` data written during the attempt stays written, storage-version migrations are not reverted, addons (`CoreDNS`, `kube-proxy`) already re-applied at the new version stay at the new version, ConfigMap changes to `kubeadm-config`/`kubelet-config` persist, and installed packages are untouched. "Recovered into the earlier state" means the manifests, not the cluster.

**Q9.2** — Because `snapshot restore` builds a **complete new member data directory** — including a fresh member ID, cluster ID and WAL — rather than merging into an existing one. Writing into a directory that already contains a member's WAL and snapshot files would produce an inconsistent mix of two histories, and etcd refuses rather than risk silent data corruption. Requiring an empty target also preserves the original `/var/lib/etcd` untouched, so a failed restore leaves you exactly one `sed` away from where you started.

**Q9.3** — Any of: (1) **Secrets and ServiceAccount tokens** created since the snapshot — restoring resurrects rotated/revoked credentials and destroys newly issued ones, so applications authenticate with secrets that no longer exist, and credentials you deliberately rotated after an incident come back to life; (2) **RBAC changes** — a `RoleBinding` you removed to revoke someone's access is restored, silently reinstating that access; (3) **CRs of operators** (certificates issued by cert-manager, database clusters, backup schedules), where the operator's view of the world and the actual cloud resources diverge; (4) **PersistentVolume/PVC bindings** created since the snapshot, leaving real volumes orphaned. The RBAC and Secret cases are the security-critical ones: an etcd restore is a *credential and authorisation time machine* and must be followed by a deliberate re-audit.

**Q9.4** — (1) **Prefer patch upgrades within the current minor** for CVE response (Q2.1) — same fix, dramatically smaller change surface, far less that can require a rollback. (2) **Rehearse with `kubeadm upgrade plan` and `--dry-run`, and complete the removed-API/compatibility review of Exercise 4 first**, so the upgrade's failure modes are discovered before any manifest is written. Adjacent and equally load-bearing: upgrade one node at a time, and never start without a verified, off-node etcd snapshot.

### Checkpoint 10

**Q10.1** — Run the entire control-plane block: repoint the repository, `apt-mark unhold kubeadm` → install the pinned `kubeadm` → `apt-mark hold kubeadm`, `kubeadm upgrade plan`, `kubeadm upgrade apply v1.34.1 -y`, then `kubectl drain cp01 --ignore-daemonsets`, install the pinned `kubelet`/`kubectl`, `systemctl daemon-reload && systemctl restart kubelet`, `kubectl uncordon cp01`. **Skip the entire worker block** — do not `ssh` to the workers, do not run `kubeadm upgrade node`, do not drain or upgrade them. Leaving the kubelets one minor behind is within the supported skew, which is exactly why the task can ask for it.

**Q10.2** — No. `SchedulingDisabled` means the node still carries the `node.kubernetes.io/unschedulable` taint and the `spec.unschedulable: true` field left by `drain`; the cluster will not place any new Pods there, so the task is incomplete and will be graded as such. Run `kubectl uncordon cp01` and confirm the status reads plain `Ready`.

</details>

---

## Reference sources

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum
- Upgrading kubeadm clusters — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Upgrading Linux nodes — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- Changing the Kubernetes package repository — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
- Version skew policy — https://kubernetes.io/releases/version-skew-policy/
- Patch releases and support window — https://kubernetes.io/releases/patch-releases/
- Official CVE feed — https://kubernetes.io/docs/reference/issues-security/official-cve-feed/
- Security and disclosure information — https://kubernetes.io/docs/reference/issues-security/security/
- Deprecated API migration guide — https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- API deprecation policy — https://kubernetes.io/docs/reference/using-api/deprecation-policy/
- `kubeadm upgrade` command reference — https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/
- Certificate management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Safely drain a node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Disruptions and PodDisruptionBudgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Verify signed Kubernetes artifacts — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/