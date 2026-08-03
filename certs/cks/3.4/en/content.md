# 3.4 — Upgrade Kubernetes to Avoid Vulnerabilities

> **CKS v1.34 · Domain 3: Cluster Hardening · Weight 3.75%**
> Audience: Platform Architects and SREs operating self-managed Kubernetes at production scale.

---

## 1. Motivation and the Production Architectural Problem

### 1.1 The cluster control plane is a Trusted Computing Base

Every workload in a Kubernetes cluster transitively trusts a small set of binaries: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`, `kubelet`, `kube-proxy`, the container runtime, and the kernel. A defect in any of them is not "a bug in an app" — it is a defect in the *substrate that enforces every other control you configured*. RBAC, NetworkPolicy, admission webhooks, Pod Security Standards, seccomp profiles: all of them are enforced by code that must itself be correct.

This produces the central asymmetry of cluster hardening:

> You can write a perfect RBAC model and still hand an attacker `cluster-admin` if your `kube-apiserver` is vulnerable to a proxy-upgrade authorization bypass.

CVE-2018-1002105 is the canonical demonstration. A crafted upgrade request to the aggregated API / exec endpoints left an authenticated backend connection open, and *any* subsequent request on that connection was proxied to a backend API server with the API server's own credentials — with no re-authorization. With the default `system:discovery` binding available to unauthenticated users in affected versions, this was a remote, effectively pre-auth path to full cluster compromise (CVSS 9.8). No amount of Role/RoleBinding hygiene mitigated it. Only a version bump did.

### 1.2 Upgrading is necessary but *not sufficient*

The single most common misconception at CKS level is that "patch the cluster" is a complete answer to "avoid vulnerabilities". It is not. Kubernetes vulnerabilities fall into at least four classes, and only one of them is fully closed by installing a newer binary:

| Class | Example | Closed by upgrade alone? | Additional action required |
|---|---|---|---|
| **Code defect in a core component** | CVE-2018-1002105 (apiserver proxy authz bypass), CVE-2019-11253 (YAML "billion laughs" DoS in apiserver) | ✅ Yes | None |
| **Transitive dependency defect (Go stdlib, libraries)** | HTTP/2 Rapid Reset (CVE-2023-44487 / CVE-2023-39325) — mitigated in Kubernetes by rebuilding against a patched Go toolchain | ✅ Yes, via patch release | Track *patch* releases, not just minors |
| **Design-level weakness with no code fix** | CVE-2020-8554 — any user who can create a Service may claim an arbitrary `externalIPs` / LoadBalancer status IP and MITM cluster egress to that IP | ❌ **No** | Admission control (ValidatingAdmissionPolicy / Kyverno / OPA) restricting `spec.externalIPs`; RBAC on Service creation |
| **Ecosystem component outside the k8s repo** | CVE-2025-1974 ("IngressNightmare") — unauthenticated RCE in the `ingress-nginx` admission controller, CVSS 9.8; runc CVE-2024-21626 ("Leaky Vessels") file-descriptor leak → container escape; CVE-2019-5736 runc host `/proc/self/exe` overwrite | ❌ **No** — a `kubeadm upgrade` does not touch them | Separate patch pipelines for CNI, ingress, CSI, runtime, kernel |

Design the upgrade program around this table. A "we are on the latest patch of 1.34" dashboard that is green while `ingress-nginx`, `containerd`, `runc`, and the host kernel are unmanaged is *security theatre*.

### 1.3 The real production constraint: MTTR of a CVE

The architectural question is not "should we upgrade" but **"what is the wall-clock time from CVE publication to fleet-wide remediation, and what is the blast radius of the remediation itself?"**

Two failure modes bracket the problem:

* **Upgrade too rarely.** You accumulate skew, cross out of the supported window, lose access to patch releases entirely, and are eventually forced into a multi-minor jump — the highest-risk operation in cluster lifecycle — *under incident pressure*. This is how a Sev-3 CVE becomes a Sev-1 outage.
* **Upgrade carelessly.** You break workloads on removed APIs, trip a version-skew violation, exhaust `PodDisruptionBudget` allowances, or brick a control plane node with an expired certificate. Availability damage from a bad upgrade routinely exceeds the expected loss from the CVE you were patching.

Mature platforms resolve this by making upgrades **boring, frequent, and rehearsed**: continuous small deltas rather than rare large ones. The engineering investment is in the *pipeline*, not in the individual upgrade.

### 1.4 The support window is a hard architectural boundary

Kubernetes ships **three minor releases per year** (roughly every four months). Each minor release receives **14 months of patch support**: 12 months of standard support plus 2 months of maintenance mode. Patch releases are cut on a published monthly cadence, with a cherry-pick deadline the Friday before each patch Tuesday.

The consequence: **at any moment only three minor versions receive security patches.** Falling to n-3 means that when the next critical CVE lands, there is no patch for you — the only remediation is a minor upgrade, which is exactly the operation you were deferring.

| Minor | Approximate release | Approximate end of standard support | Approximate EOL (end of maintenance) |
|---|---|---|---|
| 1.32 | Dec 2024 | ~Dec 2025 | ~Feb 2026 |
| 1.33 | Apr 2025 | ~Apr 2026 | ~Jun 2026 |
| **1.34** (exam target) | Aug 2025 | ~Aug 2026 | ~Oct 2026 |

> Dates are indicative. **Always confirm against <https://kubernetes.io/releases/> and <https://kubernetes.io/releases/patch-releases/>** — these are the authoritative sources and they move.

Budget one minor upgrade per quarter as a standing platform commitment. Three per year is the minimum sustainable rate; anything slower is a slow-motion decision to run unsupported software.

---

## 2. Knowing *What* to Patch: The Vulnerability Intake Pipeline

You cannot patch what you do not know about. Kubernetes publishes machine-readable vulnerability data; a production platform consumes it automatically.

### 2.1 Authoritative sources

| Source | Type | URL | Use |
|---|---|---|---|
| Official CVE feed (HTML) | Curated, human | `https://kubernetes.io/docs/reference/issues-security/official-cve-feed/` | Triage review |
| Official CVE feed (JSON) | Curated, machine | `https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json` | Automation / alerting |
| `kubernetes-security-announce` | Mailing list, push | `https://groups.google.com/g/kubernetes-security-announce` | Immediate notification |
| Security Response Committee | Process/policy | `https://github.com/kubernetes/committee-security-response` | Embargo policy, disclosure timelines |
| CHANGELOG per minor | Per-release detail | `https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/README.md` | Exact fix version, "Urgent Upgrade Notes" |
| Deprecated API migration guide | Compatibility | `https://kubernetes.io/docs/reference/using-api/deprecation-guide/` | Pre-upgrade gate |

The JSON feed is generated from GitHub issues in `kubernetes/kubernetes` carrying the `official-cve-feed` label, so it reflects only CVEs the Security Response Committee has accepted as Kubernetes CVEs. **It does not include** CNI plugins, `ingress-nginx`, CSI drivers, `containerd`/`runc`, or your host OS. Those need their own subscriptions.

### 2.2 Automated intake — complete, deployable manifest

The following CronJob polls the official feed every six hours, filters by CVSS threshold, and emits an alert to a webhook. It is intentionally dependency-free (`curl` + `jq`) so it can run in a locked-down namespace under the `restricted` Pod Security Standard.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-security
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cve-watch
  namespace: platform-security
automountServiceAccountToken: false
---
apiVersion: v1
kind: Secret
metadata:
  name: cve-watch-webhook
  namespace: platform-security
type: Opaque
stringData:
  # Replace with your real alerting endpoint (Alertmanager, Slack, PagerDuty Events API).
  url: "https://alertmanager.platform.svc.cluster.local:9093/api/v2/alerts"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cve-watch-script
  namespace: platform-security
data:
  cve-watch.sh: |
    #!/bin/sh
    set -eu

    FEED_URL="https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json"
    MIN_CVSS="${MIN_CVSS:-7.0}"
    STATE_FILE="/state/seen.txt"

    touch "${STATE_FILE}"

    echo "[cve-watch] fetching ${FEED_URL}"
    if ! curl --fail --silent --show-error --max-time 30 \
              --proto '=https' --tlsv1.2 \
              -o /tmp/feed.json "${FEED_URL}"; then
      echo "[cve-watch] FATAL: feed fetch failed" >&2
      exit 1
    fi

    # The feed exposes an "items" array; each entry carries id, summary, url,
    # external_url and content_text. CVSS is not guaranteed to be present, so we
    # alert on every unseen CVE and let the human triage severity.
    jq -r '.items[] | [.id, (.summary // "no summary"), (.external_url // .url)] | @tsv' \
      /tmp/feed.json > /tmp/current.tsv

    NEW=0
    while IFS="$(printf '\t')" read -r id summary link; do
      if grep -qxF "${id}" "${STATE_FILE}"; then
        continue
      fi
      NEW=$((NEW + 1))
      echo "[cve-watch] NEW ${id}: ${summary} (${link})"

      payload=$(jq -n \
        --arg id "${id}" \
        --arg summary "${summary}" \
        --arg link "${link}" \
        --arg cluster "${CLUSTER_NAME}" \
        '[{
           labels: {
             alertname: "KubernetesCVEPublished",
             severity: "warning",
             cve: $id,
             cluster: $cluster
           },
           annotations: {
             summary: $summary,
             runbook_url: $link
           }
         }]')

      curl --fail --silent --show-error --max-time 15 \
           -H 'Content-Type: application/json' \
           -d "${payload}" "${WEBHOOK_URL}" \
        || echo "[cve-watch] WARN: alert delivery failed for ${id}" >&2

      echo "${id}" >> "${STATE_FILE}"
    done < /tmp/current.tsv

    echo "[cve-watch] done; ${NEW} new CVE(s)"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cve-watch-state
  namespace: platform-security
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cve-watch
  namespace: platform-security
spec:
  schedule: "17 */6 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 300
      template:
        spec:
          serviceAccountName: cve-watch
          automountServiceAccountToken: false
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: watch
              image: alpine/k8s:1.34.1
              command: ["/bin/sh", "/scripts/cve-watch.sh"]
              env:
                - name: CLUSTER_NAME
                  value: "prod-eu-west-1"
                - name: MIN_CVSS
                  value: "7.0"
                - name: WEBHOOK_URL
                  valueFrom:
                    secretKeyRef:
                      name: cve-watch-webhook
                      key: url
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 20m
                  memory: 64Mi
                limits:
                  memory: 128Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: state
                  mountPath: /state
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: cve-watch-script
                defaultMode: 0555
            - name: state
              persistentVolumeClaim:
                claimName: cve-watch-state
            - name: tmp
              emptyDir:
                sizeLimit: 32Mi
```

### 2.3 Triage SLA — turn severity into a deadline

| CVSS band | Classification | Remediation SLA (control plane) | Remediation SLA (nodes) | Compensating control while pending |
|---|---|---|---|---|
| 9.0 – 10.0 | Critical | 24 h | 72 h | Emergency admission policy / NetworkPolicy / feature-gate disable; consider taking the affected endpoint offline |
| 7.0 – 8.9 | High | 7 days | 14 days | Targeted RBAC restriction, admission policy |
| 4.0 – 6.9 | Medium | Next scheduled patch cycle (≤30 days) | Next cycle | Audit-log detection rule |
| 0.1 – 3.9 | Low | Next minor upgrade | Next minor | Document and accept |

Encode this as policy, not sentiment. The number that matters on the platform scorecard is **P95 time-to-patch**, measured per CVE.

---

## 3. Version Skew: The Rules That Make Rolling Upgrades Possible

Kubernetes is upgraded *in place, component by component*, which means a cluster is intentionally heterogeneous mid-upgrade. The **version skew policy** defines exactly how heterogeneous it is allowed to be. Violating it produces undefined behaviour, not a clean error — this is a high-yield exam and production topic.

### 3.1 The skew matrix (Kubernetes 1.34)

| Component | May be **newer** than `kube-apiserver`? | Maximum lag behind `kube-apiserver` | Extra constraints |
|---|---|---|---|
| `kube-apiserver` (HA peers) | n/a | 1 minor between the newest and oldest instance | During upgrade there is transiently one instance at n+1 and the rest at n |
| `kube-controller-manager` | ❌ Never | 1 minor | In HA, must not be newer than the **oldest** `kube-apiserver` it may reach |
| `kube-scheduler` | ❌ Never | 1 minor | Same HA caveat |
| `cloud-controller-manager` | ❌ Never | 1 minor | Same HA caveat |
| `kubelet` | ❌ Never | **3 minor** (extended from 2 in 1.28) | Must not be newer than the oldest reachable `kube-apiserver` |
| `kube-proxy` | ❌ Never | 3 minor | Additionally must be within ±1 minor of the **kubelet on the same node** |
| `kubectl` | ✅ Up to 1 minor newer | 1 minor | Effectively a ±1 window around `kube-apiserver` |
| `kubeadm` | — | — | Upgrades **one minor at a time only**; `kubeadm` must match the target version |

Authoritative reference: <https://kubernetes.io/releases/version-skew-policy/>

### 3.2 The mandatory upgrade order

The order is derived from the skew rules — it is not a style preference:

```
1. etcd                      (independent lifecycle; upgrade first, one minor at a time)
2. kube-apiserver            (all HA instances; oldest must reach the target minor)
3. kube-controller-manager
   kube-scheduler
   cloud-controller-manager  (never ahead of the API server)
4. kubelet                   (node by node, drained)
5. kube-proxy                (typically a DaemonSet updated with the control plane by kubeadm)
6. kubectl and cluster addons (CoreDNS, CNI, CSI, metrics-server)
```

The rule to memorise: **control plane first, top-down; never let a client component lead the API server.**

### 3.3 Why the extended kubelet skew matters architecturally

The n-3 kubelet window (a full year of minor releases) exists specifically so that node fleets can be patched on a *different, slower cadence* than the control plane. This is the enabling primitive for the "immutable node" model: you upgrade the control plane every quarter, and you roll node images on your own schedule — for example driven by kernel/runtime CVEs rather than by Kubernetes minors.

**Do not treat n-3 as a target.** It is headroom for emergencies and staged rollouts. Steady-state drift beyond n-1 means every control-plane CVE response is gated on a node fleet you have not exercised in months.

---

## 4. Upgrade Strategies: Comparative Trade-offs

### 4.1 The four archetypes

| Dimension | **In-place rolling** (`kubeadm upgrade`) | **Immutable node replacement** (surge / node-pool rotation) | **Blue/green cluster** | **Managed control plane** (EKS / GKE / AKS) |
|---|---|---|---|---|
| Control-plane mechanism | Static pod manifests rewritten on disk | New CP nodes joined, old ones removed | Entirely new cluster built | Provider-operated, opaque |
| Node mechanism | drain → upgrade kubelet → uncordon | New node joins → drain old → delete old | N/A (workloads re-deployed) | Provider-managed node groups |
| Rollback | **Hard.** `kubeadm` does not support downgrade; recovery = etcd snapshot restore | Easy — keep the old image, roll forward to it | Trivial — flip traffic back | Provider-dependent; usually forward-only |
| Blast radius | Whole cluster; a bad CP upgrade affects everything | Per node / per pool | Zero on the live cluster until cutover | Whole cluster, but provider-tested |
| Configuration drift | **High** — nodes accumulate mutable state over years | **Zero** — nodes are rebuilt from a golden image | Zero | Zero (nodes), n/a (CP) |
| Time to patch a kernel/runtime CVE | Slow — requires separate reboot orchestration | Fast — bake a new image, roll | Slow | Fast (managed node upgrade) |
| Extra infrastructure cost | None | ~1 surge node per pool, transient | **2× full cluster**, transient | Provider fee |
| Handles local PVs / node-affine state | Yes (node identity preserved) | ❌ Poor — requires data migration | ❌ Poor | Poor |
| Stateful workload disruption | One drain per node | One drain per node | Full re-deploy + data migration | One drain per node |
| Operational complexity | Medium (well-documented runbook) | Medium-high (image pipeline required) | High (DNS/ingress/data cutover) | Low |
| **CKS exam relevance** | **★★★ — this is what is tested** | ★ | ★ | ★ |
| Best fit | Bare metal, small/medium fleets, exam | Cloud/IaaS fleets, high patch cadence | Major-version jumps, CNI/runtime swaps, regulated cutovers | Teams optimising for headcount |

### 4.2 Architect's guidance

* **Control plane: in-place with `kubeadm`.** The control plane is small (3–5 nodes), etcd is node-affine, and `kubeadm upgrade` is the only path the project supports and tests. Rebuilding control-plane nodes is possible but adds etcd membership churn for no security benefit.
* **Workers: immutable replacement.** This is where the volume is, where the kernel and runtime CVEs land, and where drift accumulates. Replacing a node is the only reliable way to guarantee that the kernel, `containerd`, `runc`, and the kubelet are all at known-good versions simultaneously. It also gives you a rollback that in-place patching cannot.
* **Blue/green: reserve it for discontinuities** — a CNI replacement, a cgroup v1→v2 migration, a multi-minor jump on a cluster that fell out of support. It is the correct answer when the risk of an in-place path exceeds the cost of a second cluster.

### 4.3 Where the *actual* attack surface lives

| Layer | Patched by | Typical CVE | Independent of `kubeadm upgrade`? |
|---|---|---|---|
| Host kernel | OS package manager + **reboot** | CVE-2022-0847 (Dirty Pipe) — arbitrary write to read-only files, trivially escalates from a container | ✅ Independent |
| `runc` | OS package manager | CVE-2019-5736 (host `runc` binary overwrite), CVE-2024-21626 (Leaky Vessels fd leak → escape) | ✅ Independent |
| `containerd` / CRI-O | OS package manager | CVE-2022-23648 (arbitrary host file read via image volumes) | ✅ Independent |
| cgroups configuration | Kernel + runtime config | CVE-2022-0492 (cgroups v1 `release_agent` escape) | ✅ Independent |
| `kubelet` / `kube-proxy` | `kubeadm` + package manager | CVE-2021-25741 (subpath symlink swap → host FS access) | ⚠️ Partly — kubeadm upgrades manifests, **you** upgrade the kubelet package |
| Control-plane components | `kubeadm upgrade apply` | CVE-2018-1002105, CVE-2022-3172 | ✅ Covered |
| Ingress controller | Its own Helm chart / manifests | CVE-2025-1974 (IngressNightmare, unauth RCE, CVSS 9.8) | ✅ Independent |
| CNI / CSI plugins | Their own release channels | Varies | ✅ Independent |

**Design implication:** you need *at least three* patch pipelines — cluster (kubeadm), node OS image (kernel + runtime), and addons (Helm/GitOps). Treating them as one is the most common structural gap in real platforms.

---

## 5. Pre-Upgrade Gates: Detecting What Will Break

An upgrade that patches a CVE and simultaneously takes down the platform is a net loss. Gate every minor upgrade on the following checks, automated in CI.

### 5.1 Removed and deprecated APIs

Kubernetes guarantees a deprecation window (GA APIs: 12 months or 3 releases, whichever is longer), but removal *does* happen and it breaks `kubectl apply`, controllers, and Helm releases stored in the cluster.

Historically significant removals:

| Removed in | API |
|---|---|
| 1.22 | `extensions/v1beta1` and `networking.k8s.io/v1beta1` Ingress; `apiextensions.k8s.io/v1beta1` CRD; `admissionregistration.k8s.io/v1beta1` webhooks |
| 1.25 | `policy/v1beta1` **PodSecurityPolicy** (replaced by Pod Security Admission); `batch/v1beta1` CronJob |
| 1.26 | `autoscaling/v2beta2` HPA; `flowcontrol.apiserver.k8s.io/v1beta1` |
| 1.29 | `flowcontrol.apiserver.k8s.io/v1beta2` |
| 1.32 | `flowcontrol.apiserver.k8s.io/v1beta3` |

Always check the authoritative list for your exact target: <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>

**The best detector is the API server itself.** `kube-apiserver` exposes a metric that counts *live* requests to deprecated APIs, labelled with the release in which they will be removed:

```
$ kubectl get --raw /metrics | grep -E '^apiserver_requested_deprecated_apis'
apiserver_requested_deprecated_apis{group="flowcontrol.apiserver.k8s.io",removed_release="1.32",resource="flowschemas",subresource="",version="v1beta3"} 1
apiserver_requested_deprecated_apis{group="autoscaling",removed_release="1.32",resource="horizontalpodautoscalers",subresource="",version="v2beta2"} 1
```

Join it with `apiserver_request_total` to identify the offending client by `user_agent`:

```promql
sum by (group, version, resource, removed_release, user_agent) (
  increase(apiserver_request_total[7d])
  * on (group, version, resource, subresource) group_left(removed_release)
    apiserver_requested_deprecated_apis
)
```

This finds *runtime* callers — including controllers and CI jobs — that a static manifest scan will miss.

Complement it with static scanning of your Git manifests and installed Helm releases:

```
$ kubent --cluster --helm3 --target-version 1.34.0
6:12PM INF >>> Kube No Trouble `kubent` <<<
6:12PM INF version 0.7.3 (git sha b2b2b2b)
6:12PM INF Initializing collectors and retrieving data
6:12PM INF Target K8s version is 1.34.0
6:12PM INF Retrieved 412 resources from collector name=Cluster
6:12PM INF Retrieved 37 resources from collector name=Helm v3
__________________________________________________________________________________________
>>> Deprecated APIs removed in 1.32 <<<
------------------------------------------------------------------------------------------
KIND                      NAMESPACE     NAME                 API_VERSION                              REPLACE_WITH (SINCE)
FlowSchema                <undefined>   legacy-tenant-flow   flowcontrol.apiserver.k8s.io/v1beta3     flowcontrol.apiserver.k8s.io/v1 (1.29.0)
HorizontalPodAutoscaler   payments      checkout-hpa         autoscaling/v2beta2                      autoscaling/v2 (1.23.0)
```

Rewrite offending manifests with `kubectl convert`:

```
$ kubectl convert -f ./deploy/checkout-hpa.yaml --output-version autoscaling/v2 > ./deploy/checkout-hpa.v2.yaml
$ kubectl apply --dry-run=server -f ./deploy/checkout-hpa.v2.yaml
horizontalpodautoscaler.autoscaling/checkout-hpa configured (server dry run)
```

### 5.2 Comparison of deprecation-detection tooling

| Tool | Scope | Detects runtime callers | Detects Helm-stored manifests | Detects Git manifests | CI-friendly | Notes |
|---|---|---|---|---|---|---|
| `apiserver_requested_deprecated_apis` metric | Live cluster | ✅ **Yes** | Indirectly | ❌ | ✅ | Ground truth; only sees what was actually called |
| `kubent` (kube-no-trouble) | Cluster + Helm2/3 + files | ❌ | ✅ | ✅ | ✅ | Best single-shot pre-upgrade scan |
| `pluto` (Fairwinds) | Files + Helm | ❌ | ✅ | ✅ | ✅ | Strong for repo/CI scanning; versioned deprecation DB |
| `kubectl convert` | Single manifest | ❌ | ❌ | ✅ | ✅ | Remediation, not detection; separate plugin download |
| API server audit log (`v1beta1` filter) | Live cluster | ✅ | ❌ | ❌ | ⚠️ | Highest fidelity, highest volume |

### 5.3 Feature gates and compatibility (emulated) versions

Beyond API removal, a minor upgrade changes *behaviour*: alpha gates graduate to beta-on-by-default, beta gates go GA, and defaults shift. Enumerate what changes before you upgrade:

```
$ kube-apiserver --help | grep -A2 'feature-gates'
      --feature-gates mapStringBool  A set of key=value pairs that describe feature gates for
                                     alpha/experimental features. Options are:
                                     APIResponseCompression=true|false (BETA - default=true)
                                     ...
```

Kubernetes has been adding **compatibility (emulated) versions** (KEP-4330) precisely to decouple "run the new binary" from "adopt the new behaviour". With `--emulated-version`, a newly-installed `kube-apiserver` binary can present the API surface and defaults of the *previous* minor, so you can install a security-patched binary immediately and enable the new behaviour later as a separate, independently revertible change:

```
# Install the 1.34 binary but keep 1.33 API behaviour, then flip the emulation
# forward once workloads are validated.
--emulated-version=1.33
```

This is a materially better security posture: **binary patching stops being coupled to behavioural risk.** Feature-gate maturity for this capability varies by release — confirm availability and syntax for your exact version against the KEP and component reference (<https://github.com/kubernetes/enhancements/issues/4330>) before relying on it in production.

### 5.4 Pre-upgrade checklist (gate the pipeline on all of these)

```
[ ] Target patch version confirmed against https://kubernetes.io/releases/patch-releases/
[ ] CHANGELOG "Urgent Upgrade Notes" for the target minor read end to end
[ ] Removed-API scan clean (kubent/pluto + apiserver_requested_deprecated_apis == 0)
[ ] etcd snapshot taken AND restore rehearsed in a scratch cluster
[ ] /etc/kubernetes and /var/lib/kubelet backed up on every control-plane node
[ ] Certificate expiry checked: kubeadm certs check-expiration
[ ] PodDisruptionBudgets audited: no PDB with minAvailable == replicas
[ ] Sufficient scheduling headroom to absorb one drained node
[ ] Addon compatibility verified (CNI, CSI, ingress, metrics-server, cert-manager)
[ ] Upgrade rehearsed on a staging cluster of the same topology
[ ] Container images pre-pulled (kubeadm config images pull) — critical if air-gapped
[ ] Rollback decision tree written and the on-call engineer briefed
```

---

## 6. Verify Before You Install: Supply-Chain Integrity of the Upgrade Artifacts

An upgrade is the moment you deliberately execute new privileged binaries on every node. It is therefore the moment supply-chain verification matters most — a compromised `kubectl`/`kubelet` binary is a root-equivalent implant, delivered by your own change process.

Kubernetes publishes SHA-256 digests for every release binary and signs release artifacts with **Sigstore/cosign** using keyless (Fulcio/Rekor) signing.

```
$ VERSION=v1.34.1
$ ARCH=linux/amd64
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl"
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.sha256"
$ echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
kubectl: OK
```

Signature verification (stronger — proves *who* built it, not merely that the bytes match a digest served from the same origin):

```
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.sig"
$ curl -fsSLO "https://dl.k8s.io/release/${VERSION}/bin/${ARCH}/kubectl.cert"
$ cosign verify-blob kubectl \
    --signature kubectl.sig \
    --certificate kubectl.cert \
    --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com
Verified OK
```

Container images are signed the same way:

```
$ cosign verify registry.k8s.io/kube-apiserver:v1.34.1 \
    --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com \
  | jq '.[0].optional.Bundle.Payload.body' -r | head -c 80
eyJhcGlWZXJzaW9uIjoiMC4wLjEiLCJraW5kIjoiaGFzaGVkcmVrb3JkIiwic3BlYyI6eyJkYXRh
```

> `--certificate-identity` values are release-tooling accounts and can change between release cycles. Take them from <https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/> at the time of the upgrade rather than hard-coding them indefinitely.

For package-based installs, the community repositories at `pkgs.k8s.io` are GPG-signed; the signing key must be installed as a keyring and the repository line must be pinned to it with `signed-by=`. Never use an unsigned or `[trusted=yes]` repository entry — that disables the only integrity check in the apt path.

---

## 7. The Full `kubeadm` Upgrade Runbook (v1.33.4 → v1.34.1)

Reference topology: three control-plane nodes (`cp-1`, `cp-2`, `cp-3`) with stacked etcd, and worker nodes (`w-1` … `w-n`). Debian/Ubuntu with the community `pkgs.k8s.io` repository.

### 7.0 Establish the baseline

```
$ kubectl get nodes -o wide
NAME   STATUS   ROLES           AGE    VERSION   INTERNAL-IP     OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
cp-1   Ready    control-plane   214d   v1.33.4   10.20.0.11      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
cp-2   Ready    control-plane   214d   v1.33.4   10.20.0.12      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
cp-3   Ready    control-plane   214d   v1.33.4   10.20.0.13      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
w-1    Ready    <none>          214d   v1.33.4   10.20.0.21      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4
w-2    Ready    <none>          214d   v1.33.4   10.20.0.22      Ubuntu 24.04.2 LTS   6.8.0-52-generic    containerd://2.0.4

$ kubectl version
Client Version: v1.33.4
Kustomize Version: v5.6.0
Server Version: v1.34.0
```

Confirm control-plane health *before* touching anything:

```
$ kubectl get --raw='/readyz?verbose' | tail -20
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]poststarthook/start-apiextensions-informers ok
[+]poststarthook/start-apiextensions-controllers ok
[+]poststarthook/crd-informer-synced ok
[+]poststarthook/bootstrap-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]poststarthook/priority-and-fairness-config-producer ok
[+]poststarthook/start-cluster-authentication-info-controller ok
[+]shutdown ok
readyz check passed

$ kubectl get pods -n kube-system -o wide | grep -E 'etcd|apiserver|controller|scheduler'
etcd-cp-1                      1/1   Running   3   214d   10.20.0.11   cp-1
etcd-cp-2                      1/1   Running   2   214d   10.20.0.12   cp-2
etcd-cp-3                      1/1   Running   2   214d   10.20.0.13   cp-3
kube-apiserver-cp-1            1/1   Running   3   214d   10.20.0.11   cp-1
kube-apiserver-cp-2            1/1   Running   2   214d   10.20.0.12   cp-2
kube-apiserver-cp-3            1/1   Running   2   214d   10.20.0.13   cp-3
kube-controller-manager-cp-1   1/1   Running   9   214d   10.20.0.11   cp-1
kube-scheduler-cp-1            1/1   Running   8   214d   10.20.0.11   cp-1
```

### 7.1 Back up etcd — non-negotiable

`kubeadm` has **no downgrade path**. An etcd snapshot is your only rollback for a failed control-plane upgrade.

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-pre-1.34.1.db
{"level":"info","ts":"2026-03-11T09:04:12.118Z","caller":"snapshot/v3_snapshot.go:65","msg":"created temporary db file","path":"/var/backups/etcd-pre-1.34.1.db.part"}
{"level":"info","ts":"2026-03-11T09:04:12.140Z","caller":"snapshot/v3_snapshot.go:73","msg":"fetching snapshot","endpoint":"https://127.0.0.1:2379"}
{"level":"info","ts":"2026-03-11T09:04:13.902Z","caller":"snapshot/v3_snapshot.go:88","msg":"fetched snapshot","endpoint":"https://127.0.0.1:2379","size":"148 MB","took":"1.783 seconds"}
Snapshot saved at /var/backups/etcd-pre-1.34.1.db

$ sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/backups/etcd-pre-1.34.1.db
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 8f1c2d9a |  9481223 |      14907 |     148 MB |
+----------+----------+------------+------------+
```

Also back up the control-plane configuration and PKI on every CP node:

```
$ sudo tar czf /var/backups/k8s-etc-pre-1.34.1-$(hostname).tgz \
    /etc/kubernetes /var/lib/kubelet/config.yaml
$ sudo ls -lh /var/backups/
-rw-r--r-- 1 root root 148M Mar 11 09:04 etcd-pre-1.34.1.db
-rw-r--r-- 1 root root  84K Mar 11 09:05 k8s-etc-pre-1.34.1-cp-1.tgz
```

Copy both off-node. A backup that lives only on the machine you are about to break is not a backup.

### 7.2 Check certificate expiry

`kubeadm upgrade apply` renews control-plane certificates by default, which is a useful side effect — but certificates that are *already expired* will block the upgrade because `kubeadm` cannot talk to the API server.

```
$ sudo kubeadm certs check-expiration
[check-expiration] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...

CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Aug 11, 2026 08:14 UTC   152d            ca                      no
apiserver                  Aug 11, 2026 08:14 UTC   152d            ca                      no
apiserver-etcd-client      Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
apiserver-kubelet-client   Aug 11, 2026 08:14 UTC   152d            ca                      no
controller-manager.conf    Aug 11, 2026 08:14 UTC   152d            ca                      no
etcd-healthcheck-client    Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
etcd-peer                  Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
etcd-server                Aug 11, 2026 08:14 UTC   152d            etcd-ca                 no
front-proxy-client         Aug 11, 2026 08:14 UTC   152d            front-proxy-ca          no
scheduler.conf             Aug 11, 2026 08:14 UTC   152d            ca                      no
super-admin.conf           Aug 11, 2026 08:14 UTC   152d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Feb 20, 2035 08:14 UTC   8y              no
etcd-ca                 Feb 20, 2035 08:14 UTC   8y              no
front-proxy-ca          Feb 20, 2035 08:14 UTC   8y              no
```

> **Architectural note:** the one-year leaf certificate lifetime is a *feature*. It means a cluster that is never upgraded eventually stops working — an enforced liveness check on your patch process. Clusters that skip upgrades for 13 months discover this the hard way.

### 7.3 Upgrade `kubeadm` on the first control-plane node

Point the package repository at the new minor. This is the step most often forgotten — the repo is versioned per minor, so without editing it `apt` will only ever offer 1.33 patches.

```
$ cat /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /

$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list

$ curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

$ sudo apt-get update
Get:1 https://pkgs.k8s.io/core:/stable:/v1.34/deb  InRelease [1186 B]
Get:2 https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages [6082 B]
Fetched 7268 B in 1s (7104 B/s)
Reading package lists... Done

$ apt-cache madison kubeadm | head -5
   kubeadm | 1.34.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages
   kubeadm | 1.34.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.34/deb  Packages
```

Install exactly the target version and re-apply the hold (the hold prevents an unrelated `apt upgrade` from silently violating skew):

```
$ sudo apt-mark unhold kubeadm
Canceled hold on kubeadm.
$ sudo apt-get install -y kubeadm=1.34.1-1.1
Reading package lists... Done
The following packages will be upgraded:
  kubeadm
1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
Setting up kubeadm (1.34.1-1.1) ...
$ sudo apt-mark hold kubeadm
kubeadm set on hold.

$ kubeadm version
kubeadm version: &version.Info{Major:"1", Minor:"34", GitVersion:"v1.34.1", GitCommit:"3c4e4c9c1b3d5f4b2a1e0d9c8b7a6f5e4d3c2b1a", GitTreeState:"clean", BuildDate:"2026-02-18T10:22:41Z", GoVersion:"go1.24.6", Compiler:"gc", Platform:"linux/amd64"}
```

### 7.4 Plan the upgrade

```
$ sudo kubeadm upgrade plan
[preflight] Running pre-flight checks.
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Running cluster health checks
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: 1.33.4
[upgrade/versions] kubeadm version: v1.34.1
I0311 09:11:44.882014   18422 version.go:261] remote version is much newer: v1.34.1; falling back to: stable-1.34
[upgrade/versions] Target version: v1.34.1
[upgrade/versions] Latest version in the v1.33 series: v1.33.6

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE   CURRENT   TARGET
kubelet     cp-1   v1.33.4   v1.34.1
kubelet     cp-2   v1.33.4   v1.34.1
kubelet     cp-3   v1.33.4   v1.34.1
kubelet     w-1    v1.33.4   v1.34.1
kubelet     w-2    v1.33.4   v1.34.1

Upgrade to the latest stable version:

COMPONENT                 NODE   CURRENT    TARGET
kube-apiserver            cp-1   v1.33.4    v1.34.1
kube-apiserver            cp-2   v1.33.4    v1.34.1
kube-apiserver            cp-3   v1.33.4    v1.34.1
kube-controller-manager   cp-1   v1.33.4    v1.34.1
kube-controller-manager   cp-2   v1.33.4    v1.34.1
kube-controller-manager   cp-3   v1.33.4    v1.34.1
kube-scheduler            cp-1   v1.33.4    v1.34.1
kube-scheduler            cp-2   v1.33.4    v1.34.1
kube-scheduler            cp-3   v1.33.4    v1.34.1
etcd                      cp-1   3.5.21-0   3.6.4-0
etcd                      cp-2   3.5.21-0   3.6.4-0
etcd                      cp-3   3.5.21-0   3.6.4-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.34.1

_____________________________________________________________________

The table below shows the current state of component configs as understood by this version of kubeadm.
Configs that have a "yes" mark in the "MANUAL UPGRADE REQUIRED" column require manual config upgrade or
resetting to kubeadm defaults before a successful upgrade can be performed. The version to manually
upgrade to is denoted in the "PREFERRED VERSION" column.

API GROUP                 CURRENT VERSION   PREFERRED VERSION   MANUAL UPGRADE REQUIRED
kubeproxy.config.k8s.io   v1alpha1          v1alpha1            no
kubelet.config.k8s.io     v1beta1           v1beta1             no
_____________________________________________________________________
```

Preview the exact changes to the static pod manifests before committing — this is the single most underused safety check in the whole runbook:

```
$ sudo kubeadm upgrade diff v1.34.1 --context-lines 3
[upgrade/diff] Reading configuration from the cluster...
--- /etc/kubernetes/manifests/kube-apiserver.yaml
+++ new manifest
@@ -33,7 +33,7 @@
     - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
     - --service-cluster-ip-range=10.96.0.0/12
     - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
-    image: registry.k8s.io/kube-apiserver:v1.33.4
+    image: registry.k8s.io/kube-apiserver:v1.34.1
     imagePullPolicy: IfNotPresent
     livenessProbe:
       failureThreshold: 8
```

Pre-pull images so the control plane is not offline waiting on a registry (mandatory in air-gapped environments):

```
$ sudo kubeadm config images list --kubernetes-version v1.34.1
registry.k8s.io/kube-apiserver:v1.34.1
registry.k8s.io/kube-controller-manager:v1.34.1
registry.k8s.io/kube-scheduler:v1.34.1
registry.k8s.io/kube-proxy:v1.34.1
registry.k8s.io/coredns/coredns:v1.12.1
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.6.4-0

$ sudo kubeadm config images pull --kubernetes-version v1.34.1
[config/images] Pulled registry.k8s.io/kube-apiserver:v1.34.1
[config/images] Pulled registry.k8s.io/kube-controller-manager:v1.34.1
[config/images] Pulled registry.k8s.io/kube-scheduler:v1.34.1
[config/images] Pulled registry.k8s.io/kube-proxy:v1.34.1
[config/images] Pulled registry.k8s.io/coredns/coredns:v1.12.1
[config/images] Pulled registry.k8s.io/pause:3.10
[config/images] Pulled registry.k8s.io/etcd:3.6.4-0
```

### 7.5 Apply on the first control-plane node

```
$ sudo kubeadm upgrade apply v1.34.1
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running preflight checks.
[upgrade] Running cluster health checks
[upgrade/version] You have chosen to change the cluster version to "v1.34.1"
[upgrade/versions] Cluster version: v1.33.4
[upgrade/versions] kubeadm version: v1.34.1
[upgrade] Are you sure you want to proceed? [y/N]: y
[upgrade/prepull] Pulling images required for setting up a Kubernetes cluster
[upgrade/prepull] This might take a minute or two, depending on the speed of your internet connection
[upgrade/apply] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"
[upgrade/etcd] Upgrading to TLS for etcd
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Renewing etcd-peer certificate
[upgrade/staticpods] Renewing etcd-healthcheck-client certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/etcd.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/etcd.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 3 Pods for label selector component=etcd
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/etcd] Waiting for etcd to become available
[upgrade/staticpods] Writing new Static Pod manifests to "/etc/kubernetes/tmp/kubeadm-upgraded-manifests1284917823"
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Renewing apiserver certificate
[upgrade/staticpods] Renewing apiserver-kubelet-client certificate
[upgrade/staticpods] Renewing front-proxy-client certificate
[upgrade/staticpods] Renewing apiserver-etcd-client certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-apiserver.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-apiserver.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[apiclient] Found 3 Pods for label selector component=kube-apiserver
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-controller-manager" upgrade
[upgrade/staticpods] Renewing controller-manager.conf certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-controller-manager.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-controller-manager.yaml"
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-scheduler" upgrade
[upgrade/staticpods] Renewing scheduler.conf certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/kube-scheduler.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/kube-scheduler.yaml"
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade/postupgrade] Removing the old taint &Taint{Key:node-role.kubernetes.io/control-plane,Value:,Effect:NoSchedule,} from all control plane Nodes
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system with the configuration for the kubelets in the cluster
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to get nodes
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

[upgrade] SUCCESS! Your cluster was upgraded to "v1.34.1". Enjoy!

[upgrade] Now that your control plane is upgraded, please proceed with upgrading your kubelets if you haven't already done so.
```

Two details worth internalising:

* **Certificates were renewed automatically** (control with `--certificate-renewal=false` if an external PKI manages them).
* **Old manifests were backed up** to `/etc/kubernetes/tmp/kubeadm-backup-manifests-<timestamp>/`. Combined with the etcd snapshot, this is your manual recovery kit.

### 7.6 Declarative upgrade configuration (v1beta4)

Flag-driven upgrades are not reproducible. `kubeadm` v1beta4 (available from 1.31 onward) introduces an `UpgradeConfiguration` kind so the whole operation is a reviewable artifact in Git:

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: UpgradeConfiguration
apply:
  # Target version. Must be exactly one minor above the current cluster version.
  kubernetesVersion: v1.34.1
  # Renew all control-plane certificates as part of the upgrade.
  certificateRenewal: true
  # Upgrade the stacked etcd static pod alongside the control plane.
  etcdUpgrade: true
  # Never force past a failed preflight check in production.
  forceUpgrade: false
  imagePullPolicy: IfNotPresent
  # Pull images one at a time to bound disk/network pressure on the CP node.
  imagePullSerial: true
  printConfig: true
  # Strategic-merge / JSON patches applied to the generated static pod manifests.
  patches:
    directory: /etc/kubernetes/patches
  skipPhases: []
node:
  certificateRenewal: true
  etcdUpgrade: true
  skipPhases: []
  patches:
    directory: /etc/kubernetes/patches
diff:
  contextLines: 5
plan: {}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
clusterName: prod-eu-west-1
controlPlaneEndpoint: "k8s-api.internal.example.com:6443"
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    # v1beta4: extraArgs is a LIST of name/value pairs, not a map.
    # This is a breaking change from v1beta3 and a common upgrade trap.
    extraArgs:
      - name: auto-compaction-retention
        value: "1h"
      - name: quota-backend-bytes
        value: "8589934592"
apiServer:
  certSANs:
    - k8s-api.internal.example.com
    - 10.20.0.10
  extraArgs:
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: anonymous-auth
      value: "false"
    - name: profiling
      value: "false"
    - name: request-timeout
      value: "60s"
    - name: tls-min-version
      value: "VersionTLS12"
    - name: tls-cipher-suites
      value: "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305"
    - name: encryption-provider-config
      value: /etc/kubernetes/enc/encryption-config.yaml
    - name: encryption-provider-config-automatic-reload
      value: "true"
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-logs
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
    - name: encryption-config
      hostPath: /etc/kubernetes/enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: profiling
      value: "false"
    - name: terminated-pod-gc-threshold
      value: "500"
    - name: bind-address
      value: "127.0.0.1"
scheduler:
  extraArgs:
    - name: profiling
      value: "false"
    - name: bind-address
      value: "127.0.0.1"
```

Apply it:

```
$ sudo kubeadm upgrade apply --config /etc/kubernetes/upgrade-config.yaml --yes
```

Migrating an older config file forward is a first-class operation — do this *before* the upgrade, in a PR:

```
$ sudo kubeadm config migrate --old-config /etc/kubernetes/kubeadm-v1beta3.yaml \
                              --new-config /etc/kubernetes/kubeadm-v1beta4.yaml
$ sudo kubeadm config validate --config /etc/kubernetes/kubeadm-v1beta4.yaml
ok
```

Always confirm the field set your build actually accepts rather than trusting a copied example:

```
$ kubeadm config print upgrade-defaults
```

### 7.7 Upgrade the kubelet and kubectl on `cp-1`

`kubeadm upgrade apply` upgraded the *static pods*. The kubelet is a host process and is upgraded by you.

```
$ kubectl drain cp-1 --ignore-daemonsets --delete-emptydir-data --timeout=300s
node/cp-1 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kube-proxy-7xk2l, kube-system/cilium-jd9wq
evicting pod kube-system/coredns-668d6bf9bc-4h2xq
evicting pod monitoring/prometheus-node-exporter-p8wq2
pod/coredns-668d6bf9bc-4h2xq evicted
node/cp-1 drained

$ sudo apt-mark unhold kubelet kubectl
$ sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
$ sudo apt-mark hold kubelet kubectl

$ sudo systemctl daemon-reload
$ sudo systemctl restart kubelet

$ systemctl is-active kubelet
active

$ kubectl uncordon cp-1
node/cp-1 uncordoned
```

Verify before moving on:

```
$ kubectl get node cp-1 -o jsonpath='{.status.nodeInfo.kubeletVersion}{"\n"}'
v1.34.1
```

### 7.8 Remaining control-plane nodes

On `cp-2` and `cp-3`, the command is `kubeadm upgrade node` — **not** `apply`. `apply` is a one-time, cluster-wide operation performed on the first control-plane node only.

```
$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list
$ sudo apt-get update && sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

$ sudo kubeadm upgrade node
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running pre-flight checks
[preflight] Skipping prepull. Not a control plane node.
[upgrade] Skipping prepull. Not a control plane node.
[upgrade] Upgrading your Static Pod-hosted control plane instance to version "v1.34.1"
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Moved new manifest to "/etc/kubernetes/manifests/etcd.yaml" and backed up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-31-40/etcd.yaml"
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-controller-manager" upgrade
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-scheduler" upgrade
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade] The control plane instance for this node was successfully updated!
[upgrade] Reading kubelet configuration from the "kubelet-config" ConfigMap in namespace kube-system...
[upgrade] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade] The configuration for this node was successfully updated!
[upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.
```

Then drain / upgrade kubelet+kubectl / restart / uncordon exactly as in §7.7. **One control-plane node at a time**, always confirming etcd quorum before proceeding:

```
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://10.20.0.11:2379,https://10.20.0.12:2379,https://10.20.0.13:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://10.20.0.11:2379   | 3d1a9f0e2b7c4d51 |   3.6.4 |  148 MB |     false |      false |        14 |    9481409 |            9481409 |        |
| https://10.20.0.12:2379   | 8b2c4e6a1f9d3072 |   3.6.4 |  148 MB |      true |      false |        14 |    9481409 |            9481409 |        |
| https://10.20.0.13:2379   | c9f7a3d5e8b16204 |  3.5.21 |  148 MB |     false |      false |        14 |    9481409 |            9481409 |        |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
```

An empty `ERRORS` column and identical `RAFT APPLIED INDEX` values across members is the go/no-go signal.

### 7.9 Worker nodes

```
# From the admin workstation
$ kubectl drain w-1 --ignore-daemonsets --delete-emptydir-data --timeout=600s --grace-period=60
node/w-1 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/cilium-2kd8x, kube-system/kube-proxy-9wq4t, monitoring/node-exporter-fk2ml
evicting pod payments/checkout-7d9f8c6b54-x2n4k
evicting pod payments/ledger-6b7c8d9e01-p9m3s
error when evicting pods/"ledger-6b7c8d9e01-p9m3s" -n "payments" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod payments/ledger-6b7c8d9e01-p9m3s
pod/checkout-7d9f8c6b54-x2n4k evicted
pod/ledger-6b7c8d9e01-p9m3s evicted
node/w-1 drained

# On the node
$ sudo sed -i 's|/core:/stable:/v1\.33/|/core:/stable:/v1.34/|' /etc/apt/sources.list.d/kubernetes.list
$ sudo apt-get update
$ sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.34.1-1.1 && sudo apt-mark hold kubeadm

$ sudo kubeadm upgrade node
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[preflight] Running pre-flight checks
[preflight] Skipping prepull. Not a control plane node.
[upgrade] Skipping phase. Not a control plane node.
[upgrade] Reading kubelet configuration from the "kubelet-config" ConfigMap in namespace kube-system...
[upgrade] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade] The configuration for this node was successfully updated!
[upgrade] Now you should go ahead and upgrade the kubelet package using your package manager.

$ sudo apt-mark unhold kubelet kubectl
$ sudo apt-get install -y kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
$ sudo apt-mark hold kubelet kubectl
$ sudo systemctl daemon-reload && sudo systemctl restart kubelet

# From the admin workstation
$ kubectl uncordon w-1
node/w-1 uncordoned
```

Note the `[upgrade] Skipping phase. Not a control plane node.` line — on a worker, `kubeadm upgrade node` only refreshes `/var/lib/kubelet/config.yaml` from the `kubelet-config` ConfigMap and rotates the kubelet client certificate. It does **not** install binaries. That is why skipping the `apt-get install kubelet` step leaves the node silently on the old version.

### 7.10 Protect availability during drains

Every drain evicts pods. Without correct `PodDisruptionBudget`s you either take an outage or hang forever. Both failure modes are avoidable:

```yaml
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ledger-pdb
  namespace: payments
spec:
  # CORRECT: with 5 replicas this permits exactly one voluntary disruption at a
  # time. NEVER set minAvailable equal to the replica count — that makes every
  # drain block forever and turns a routine upgrade into an incident.
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  # Do not let Pending/unschedulable pods block eviction of Running ones.
  unhealthyPodEvictionPolicy: AlwaysAllow
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-pdb
  namespace: payments
spec:
  # Percentage form scales with the Deployment; rounds UP for maxUnavailable.
  maxUnavailable: 25%
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  unhealthyPodEvictionPolicy: IfHealthyBudget
```

Audit for the pathological case before every upgrade:

```
$ kubectl get pdb -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,MIN:.spec.minAvailable,MAX:.spec.maxUnavailable,ALLOWED:.status.disruptionsAllowed,EXPECTED:.status.expectedPods
NS         NAME           MIN   MAX     ALLOWED   EXPECTED
payments   ledger-pdb     4     <none>  1         5
payments   checkout-pdb   <none> 25%    2         8
legacy     monolith-pdb   1     <none>  0         1     # <-- WILL BLOCK EVERY DRAIN
```

Any row with `ALLOWED: 0` is a landmine. Fix it (scale up, or relax the budget) *before* the upgrade window — do not reach for `kubectl drain --disable-eviction`, which deletes pods bypassing PDBs entirely and defeats the protection you configured.

### 7.11 Post-upgrade verification

```
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,STATUS:.status.conditions[-1].type,KUBELET:.status.nodeInfo.kubeletVersion,PROXY:.status.nodeInfo.kubeProxyVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KERNEL:.status.nodeInfo.kernelVersion
NAME   STATUS   KUBELET   PROXY     RUNTIME               KERNEL
cp-1   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
cp-2   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
cp-3   Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
w-1    Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic
w-2    Ready    v1.34.1   v1.34.1   containerd://2.0.4    6.8.0-52-generic

$ kubectl version
Client Version: v1.34.1
Kustomize Version: v5.7.1
Server Version: v1.34.1

$ kubectl get --raw='/livez?verbose' | tail -3
[+]poststarthook/apiservice-openapiv3-controller ok
[+]shutdown ok
livez check passed

$ kubectl get componentstatuses 2>/dev/null || \
  kubectl get pods -n kube-system -l tier=control-plane -o wide
NAME                           READY   STATUS    RESTARTS      AGE   IP           NODE
kube-apiserver-cp-1            1/1     Running   0             18m   10.20.0.11   cp-1
kube-apiserver-cp-2            1/1     Running   0             11m   10.20.0.12   cp-2
kube-apiserver-cp-3            1/1     Running   0             4m    10.20.0.13   cp-3
kube-controller-manager-cp-1   1/1     Running   1 (17m ago)   18m   10.20.0.11   cp-1
kube-scheduler-cp-1            1/1     Running   1 (17m ago)   18m   10.20.0.11   cp-1

$ kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
No resources found

# Prove the fix is actually deployed — verify image digests, not just tags.
$ kubectl get pods -n kube-system -l component=kube-apiserver \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
cp-1	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7
cp-2	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7
cp-3	registry.k8s.io/kube-apiserver@sha256:9b1c...e4f7

$ kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep kubernetesVersion
kubernetesVersion: v1.34.1
```

Confirm the certificates were genuinely renewed:

```
$ sudo kubeadm certs check-expiration | head -6
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver                  Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver-etcd-client      Mar 11, 2027 09:18 UTC   364d            ca                      no
apiserver-kubelet-client   Mar 11, 2027 09:18 UTC   364d            ca                      no
```

Run a smoke test that exercises scheduling, DNS, service networking, and admission:

```
$ kubectl run upgrade-smoke --image=registry.k8s.io/e2e-test-images/agnhost:2.53 \
    --restart=Never --rm -it --command -- \
    /bin/sh -c 'getent hosts kubernetes.default.svc.cluster.local && echo DNS_OK'
10.96.0.1       kubernetes.default.svc.cluster.local
DNS_OK
pod "upgrade-smoke" deleted
```

---

## 8. Continuous Verification: Alerting on Version Drift

A verified upgrade decays. Encode the invariants as alerts so drift and EOL are detected by monitoring, not by an auditor.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubernetes-version-hygiene
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: platform
spec:
  groups:
    - name: kubernetes-upgrade-hygiene
      interval: 5m
      rules:
        # ------------------------------------------------------------------
        # 1. Version skew: any node whose kubelet minor differs from the
        #    control-plane minor. Steady-state target is zero.
        # ------------------------------------------------------------------
        - alert: KubeletVersionSkew
          expr: |
            count by (cluster) (
              count by (cluster, git_version) (
                kubernetes_build_info{job="kubelet"}
              )
            ) > 1
          for: 2h
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Mixed kubelet versions in {{ $labels.cluster }}"
            description: >-
              More than one kubelet git_version is reported. This is expected
              during an upgrade window but must converge. Sustained skew means
              a node was missed by the rollout.
            runbook_url: "https://kubernetes.io/releases/version-skew-policy/"

        # ------------------------------------------------------------------
        # 2. Deprecated API usage — the pre-upgrade blocker. Any non-zero
        #    value means the next minor upgrade will break a client.
        # ------------------------------------------------------------------
        - alert: DeprecatedAPIInUse
          expr: |
            group by (group, version, resource, removed_release) (
              apiserver_requested_deprecated_apis == 1
            )
          for: 30m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Deprecated API {{ $labels.group }}/{{ $labels.version }} {{ $labels.resource }} in use"
            description: >-
              Removed in Kubernetes {{ $labels.removed_release }}. Identify the
              caller by joining apiserver_request_total on user_agent, migrate
              the manifests, and re-verify before upgrading.
            runbook_url: "https://kubernetes.io/docs/reference/using-api/deprecation-guide/"

        # ------------------------------------------------------------------
        # 3. Control-plane certificates approaching expiry. Certificates are
        #    renewed by `kubeadm upgrade apply`; firing this alert means the
        #    cluster has not been upgraded in roughly nine months.
        # ------------------------------------------------------------------
        - alert: ControlPlaneCertificateExpiringSoon
          expr: |
            (apiserver_client_certificate_expiration_seconds_count > 0)
            and on (job)
            histogram_quantile(0.01,
              sum by (job, le) (
                rate(apiserver_client_certificate_expiration_seconds_bucket[10m])
              )
            ) < 60 * 60 * 24 * 45
          for: 1h
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Client certificates expiring within 45 days"
            description: >-
              Run `kubeadm certs check-expiration` on every control-plane node.
              Either upgrade (which renews automatically) or run
              `kubeadm certs renew all` followed by a static-pod restart.
            runbook_url: "https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/"

        # ------------------------------------------------------------------
        # 4. Cluster running an unsupported minor. Maintain the recorded
        #    threshold below as part of the quarterly upgrade ritual.
        # ------------------------------------------------------------------
        - alert: ClusterVersionOutOfSupport
          expr: |
            max by (cluster) (
              label_replace(
                kubernetes_build_info{job="apiserver"},
                "minor_num", "$1", "minor", "([0-9]+).*"
              )
            ) < 0
          for: 24h
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Cluster {{ $labels.cluster }} may be outside the supported window"
            description: >-
              Compare the reported minor against the supported releases list.
              Only three minors receive security patches at any time; outside
              that window there is no remediation path for a new CVE.
            runbook_url: "https://kubernetes.io/releases/"
```

> The `ClusterVersionOutOfSupport` expression is a placeholder skeleton: PromQL has no notion of "today's supported minors". In production, drive it from a recording rule or a static gauge exported by your CVE-watch job that encodes the current EOL table, rather than trying to compute it in PromQL.

---

## 9. Failure Diagnosis

### 9.1 Failure-mode reference table

| # | Symptom | Root cause | Diagnosis | Remediation |
|---|---|---|---|---|
| 1 | `kubeadm upgrade plan` → `could not fetch a Kubernetes version from the internet` | Air-gapped / egress blocked to `dl.k8s.io` | `curl -v https://dl.k8s.io/release/stable.txt` | Pass the version explicitly: `kubeadm upgrade apply v1.34.1`; pre-pull images |
| 2 | `[preflight] Some fatal errors occurred: ... etcd cluster is not healthy` | etcd quorum lost or a member is down | `etcdctl endpoint health --cluster` | Restore quorum *before* upgrading. Never use `--force` here |
| 3 | `error execution phase preflight: [preflight] ... Specified version to upgrade to v1.35.0 is at least one minor version higher` | Attempted a multi-minor jump | `kubectl version`, `kubeadm version` | Upgrade one minor at a time: 1.33 → 1.34 → 1.35 |
| 4 | `Unable to connect to the server: x509: certificate has expired or is not yet valid` | Control-plane certs expired (cluster idle >12 months) | `sudo kubeadm certs check-expiration` | `sudo kubeadm certs renew all`, restart static pods, then refresh `admin.conf` |
| 5 | Node `NotReady` after kubelet upgrade; `journalctl` shows `failed to run Kubelet: misconfiguration: kubelet cgroup driver: "cgroupfs" is different from docker cgroup driver: "systemd"` | cgroup driver mismatch between kubelet and runtime | `journalctl -u kubelet -n 100 --no-pager` | Set `cgroupDriver: systemd` in `/var/lib/kubelet/config.yaml` **and** `SystemdCgroup = true` in `/etc/containerd/config.toml`; restart both |
| 6 | `kube-apiserver` never comes back; no pod visible | Static pod manifest invalid, or image not present | `sudo crictl ps -a \| head`, `sudo crictl logs <id>`, `journalctl -u kubelet -f` | Restore from `/etc/kubernetes/tmp/kubeadm-backup-manifests-*/` |
| 7 | `kubectl drain` hangs forever, repeating `Cannot evict pod as it would violate the pod's disruption budget` | A PDB with `disruptionsAllowed: 0` | `kubectl get pdb -A` | Scale the workload up or relax the PDB. `--disable-eviction` is a last resort that ignores PDBs |
| 8 | Workloads fail post-upgrade with `no matches for kind "X" in version "Y"` | A removed API | `kubectl api-resources`, `kubent` | `kubectl convert`; roll forward the manifests. Rolling the cluster back is far more expensive |
| 9 | Node upgraded but `kubectl get nodes` still shows the old version | `kubeadm upgrade node` ran but the kubelet **package** was not installed, or the kubelet was not restarted | `kubelet --version` on the node vs. Node object | `apt-get install kubelet=<ver>` then `systemctl daemon-reload && systemctl restart kubelet` |
| 10 | `apt-get install kubeadm=1.34.1-1.1` → `Version '1.34.1-1.1' for 'kubeadm' was not found` | The `pkgs.k8s.io` repository is still pinned to the old minor | `cat /etc/apt/sources.list.d/kubernetes.list` | Update the repo URL to `v1.34`, re-import the signing key, `apt-get update` |
| 11 | `kubelet` logs `Unable to register node ... Unauthorized` after a long outage | Rotated kubelet client cert expired while the node was down | `openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate` | Regenerate the bootstrap kubeconfig: `kubeadm token create --print-join-command`, or re-issue `/etc/kubernetes/kubelet.conf` and restart |
| 12 | CoreDNS `CrashLoopBackOff` after upgrade | Addon version incompatibility or a stale `Corefile` plugin directive | `kubectl -n kube-system logs -l k8s-app=kube-dns --previous` | Reconcile the CoreDNS ConfigMap; `kubeadm` prints migration warnings during `apply` |
| 13 | Pods stuck `ContainerCreating` after upgrade, CNI errors in events | The CNI plugin does not support the new minor | `kubectl -n kube-system logs ds/<cni>`; check `/etc/cni/net.d` | Upgrade the CNI **before** the Kubernetes minor; consult its compatibility matrix |

### 9.2 Diagnostic command reference

```
# --- kubelet: the single most useful log during any upgrade ---
$ sudo journalctl -u kubelet -f --no-pager
$ sudo journalctl -u kubelet --since "10 min ago" -p err --no-pager

# --- Static pods bypass the API server: inspect them at the CRI layer ---
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
CONTAINER      IMAGE          CREATED         STATE      NAME                      ATTEMPT   POD ID
a1b2c3d4e5f6   9b1c8d7e6f5a   2 minutes ago   Running    kube-apiserver            1         f0e1d2c3b4a5
9f8e7d6c5b4a   1a2b3c4d5e6f   2 minutes ago   Exited     kube-apiserver            0         f0e1d2c3b4a5

$ sudo crictl logs 9f8e7d6c5b4a 2>&1 | tail -30
I0311 09:19:02.114 1 flags.go:64] FLAG: --anonymous-auth="false"
E0311 09:19:02.882 1 run.go:74] "command failed" err="error creating self-signed certificates: open /etc/kubernetes/pki/apiserver.crt: permission denied"

# --- kubelet's own view of static pods and node config ---
$ sudo cat /var/lib/kubelet/config.yaml | grep -E 'cgroupDriver|staticPodPath|rotateCertificates'
cgroupDriver: systemd
staticPodPath: /etc/kubernetes/manifests
rotateCertificates: true

# --- kubeadm's saved state ---
$ sudo ls -1 /etc/kubernetes/tmp/
kubeadm-backup-manifests-2026-03-11-09-18-02
kubeadm-backup-etcd-2026-03-11-09-18-02
kubeadm-upgraded-manifests1284917823

# --- Cluster-recorded config (what kubeadm believes the cluster is) ---
$ kubectl -n kube-system get cm kubeadm-config -o yaml | head -40

# --- Which client is calling a deprecated API? ---
$ kubectl get --raw /metrics \
  | grep 'apiserver_request_total' \
  | grep 'version="v1beta3"' \
  | head -5
```

### 9.3 Recovering a failed control-plane upgrade

Order of escalation — always try the cheapest first:

```
# 1. Restore the previous static pod manifests (fastest, no data loss).
$ sudo cp /etc/kubernetes/tmp/kubeadm-backup-manifests-2026-03-11-09-18-02/*.yaml \
          /etc/kubernetes/manifests/
$ sudo systemctl restart kubelet
$ sudo crictl ps | grep kube-apiserver

# 2. If etcd itself is corrupted, restore the snapshot.
#    Stop the control plane on ALL CP nodes first by moving the manifests away.
$ sudo mkdir -p /etc/kubernetes/manifests.disabled
$ sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests.disabled/
$ sudo crictl ps            # confirm the control plane is fully stopped

$ sudo mv /var/lib/etcd /var/lib/etcd.broken
$ sudo ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd-pre-1.34.1.db \
    --name cp-1 \
    --initial-cluster cp-1=https://10.20.0.11:2380,cp-2=https://10.20.0.12:2380,cp-3=https://10.20.0.13:2380 \
    --initial-cluster-token etcd-cluster-prod \
    --initial-advertise-peer-urls https://10.20.0.11:2380 \
    --data-dir /var/lib/etcd
2026-03-11T10:02:19Z	info	snapshot/v3_snapshot.go:260	restoring snapshot	{"path": "/var/backups/etcd-pre-1.34.1.db", "wal-dir": "/var/lib/etcd/member/wal", "data-dir": "/var/lib/etcd", "snap-dir": "/var/lib/etcd/member/snap"}
2026-03-11T10:02:21Z	info	membership/cluster.go:421	added member	{"cluster-id": "7f4e2a1b", "local-member-id": "0", "added-peer-id": "3d1a9f0e2b7c4d51"}
2026-03-11T10:02:21Z	info	snapshot/v3_snapshot.go:287	restored snapshot	{"path": "/var/backups/etcd-pre-1.34.1.db", "data-dir": "/var/lib/etcd"}

# Repeat the restore on cp-2 and cp-3 with their own --name and peer URL,
# from the SAME snapshot file and the SAME --initial-cluster-token.

$ sudo mv /etc/kubernetes/manifests.disabled/*.yaml /etc/kubernetes/manifests/
$ sudo systemctl restart kubelet
```

> **`kubeadm` has no downgrade command.** If the new binaries wrote incompatible data to etcd, restoring the snapshot is the *only* path back. This is precisely why §7.1 is non-negotiable and why the restore must be rehearsed, not merely documented.

---

## 10. Node OS, Runtime, and Kernel: The Upgrade Kubernetes Does Not Do

`kubeadm upgrade` never touches the kernel, `containerd`, or `runc`. Several of the highest-impact container-security CVEs live exactly there.

```
# Current runtime and kernel posture
$ containerd --version
containerd github.com/containerd/containerd/v2 v2.0.4 sha:af0d0e8...
$ runc --version
runc version 1.2.5
spec: 1.2.0
go: go1.23.6
libseccomp: 2.5.5
$ uname -r
6.8.0-52-generic

# Is a reboot pending after kernel patching? (Debian/Ubuntu)
$ test -f /var/run/reboot-required && cat /var/run/reboot-required
*** System restart required ***

# Patch runtime + kernel on a drained node
$ kubectl drain w-1 --ignore-daemonsets --delete-emptydir-data --timeout=600s
$ sudo apt-get update && sudo apt-get install -y containerd.io runc linux-image-generic
$ sudo systemctl restart containerd
$ sudo reboot
# after the node returns:
$ kubectl uncordon w-1
```

Fleet-wide, do **not** orchestrate this by hand. Two viable patterns:

| Pattern | Mechanism | Pros | Cons |
|---|---|---|---|
| **Reboot coordinator** (e.g. Kured) | DaemonSet watches `/var/run/reboot-required`, takes a cluster-wide lock, cordons + drains + reboots one node at a time | Works on mutable nodes; no image pipeline needed | Nodes remain mutable; drift persists; reboot lock is a single point of serialisation |
| **Immutable image roll** | Bake a new node image with patched kernel/runtime/kubelet; roll the node pool; delete old nodes | Eliminates drift; atomic rollback by rolling back the image; one mechanism patches kernel + runtime + kubelet together | Requires an image build pipeline; poor fit for node-affine local state |

For any fleet above a few dozen nodes, the immutable roll is the correct architecture. It collapses three patch pipelines into one and gives you the rollback that in-place patching structurally cannot.

---

## 11. CKS Exam Notes

The exam gives you a cluster and a target version and expects the upgrade completed correctly and quickly. High-yield points:

1. **Read the task carefully for scope.** "Upgrade the control plane node only" means you must *not* upgrade the workers — and vice versa. Partial-scope tasks are common.
2. **`apply` vs `node`.** `kubeadm upgrade apply <version>` on the first control-plane node only. `kubeadm upgrade node` on every other node (control plane and worker).
3. **`ssh` and `sudo`.** Most upgrade work happens on the node, not the jump host. Remember `sudo -i` and to `exit` back before running `kubectl` commands against the cluster.
4. **The three-part node dance:** `drain` → `kubeadm upgrade node` + install `kubelet`/`kubectl` packages + `systemctl daemon-reload && systemctl restart kubelet` → `uncordon`. Forgetting `uncordon` loses points even when the version is correct.
5. **The repository URL must be changed for a minor upgrade.** If `apt-cache madison kubeadm` does not list the target version, this is why.
6. **`--ignore-daemonsets` is almost always required** for `kubectl drain`; `--delete-emptydir-data` is usually required too.
7. **Do not upgrade addons unless asked.** `kubeadm upgrade apply` handles CoreDNS and kube-proxy; if the task says to skip them, use `--skip-phases=addon/coredns,addon/kube-proxy`.
8. **Verify with `kubectl get nodes`** at the end. The `VERSION` column reflects the kubelet, so it only changes after the kubelet package is installed *and* the service restarted.

Minimal command sequence to have in muscle memory:

```
# control plane
sudo -i
sed -i 's|v1.33|v1.34|' /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y --allow-change-held-packages kubeadm=1.34.1-1.1
kubeadm upgrade plan
kubeadm upgrade apply v1.34.1 -y
exit
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo -i
apt-get install -y --allow-change-held-packages kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
systemctl daemon-reload && systemctl restart kubelet
exit
kubectl uncordon <node>

# every other node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
ssh <node>
sudo -i
sed -i 's|v1.33|v1.34|' /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y --allow-change-held-packages kubeadm=1.34.1-1.1
kubeadm upgrade node
apt-get install -y --allow-change-held-packages kubelet=1.34.1-1.1 kubectl=1.34.1-1.1
systemctl daemon-reload && systemctl restart kubelet
exit; exit
kubectl uncordon <node>
```

---

## 12. Architectural Summary

* **The control plane is part of your TCB.** A stale `kube-apiserver` invalidates every other hardening control you configured.
* **Upgrading is necessary but not sufficient.** Design-level issues (CVE-2020-8554), ecosystem components (`ingress-nginx`, CVE-2025-1974), and the runtime/kernel layer (`runc` CVE-2024-21626) need their own controls and their own patch pipelines.
* **The 14-month support window and three-releases-per-year cadence are architectural constraints, not scheduling suggestions.** Budget one minor upgrade per quarter, permanently.
* **The version skew policy is what makes rolling upgrades possible.** Control plane first, top-down; the kubelet's n-3 window is emergency headroom, not a target.
* **Gate every minor upgrade** on removed-API scanning, `PodDisruptionBudget` sanity, a *rehearsed* etcd restore, and a staging run on the same topology.
* **Verify artifacts before installing them.** An upgrade is a mass privileged-binary deployment; SHA-256 plus cosign verification costs seconds.
* **`kubeadm` cannot downgrade.** The etcd snapshot is the rollback. Take it, copy it off-node, and practise restoring it.
* **Measure P95 time-to-patch.** It is the only metric that captures whether this control actually works.

---

## Referencias

**Release engineering and support policy**
- Kubernetes Releases and supported versions — <https://kubernetes.io/releases/>
- Patch release cadence and schedule — <https://kubernetes.io/releases/patch-releases/>
- Version Skew Policy — <https://kubernetes.io/releases/version-skew-policy/>
- Release history and CHANGELOGs — <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/README.md>
- SIG Release patch release documentation — <https://github.com/kubernetes/sig-release/blob/master/releases/patch-releases.md>

**Security and vulnerability intake**
- Official Kubernetes CVE feed — <https://kubernetes.io/docs/reference/issues-security/official-cve-feed/>
- Machine-readable CVE feed (JSON) — <https://kubernetes.io/docs/reference/issues-security/official-cve-feed/index.json>
- Kubernetes security and disclosure information — <https://kubernetes.io/docs/reference/issues-security/security/>
- Security Response Committee — <https://github.com/kubernetes/committee-security-response>
- `kubernetes-security-announce` mailing list — <https://groups.google.com/g/kubernetes-security-announce>

**Upgrade procedures**
- Upgrading kubeadm clusters — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>
- Upgrading Linux nodes — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/>
- `kubeadm upgrade` command reference — <https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/>
- Reconfiguring a kubeadm cluster — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-reconfigure/>
- kubeadm configuration API (v1beta4) — <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>
- Certificate management with kubeadm — <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/>
- Operating etcd clusters for Kubernetes — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- etcd upgrade documentation — <https://etcd.io/docs/v3.5/upgrades/>

**Compatibility and deprecation**
- Deprecated API migration guide — <https://kubernetes.io/docs/reference/using-api/deprecation-guide/>
- Kubernetes deprecation policy — <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>
- Feature gates — <https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/>
- KEP-4330: Compatibility Versions — <https://github.com/kubernetes/enhancements/issues/4330>
- kube-no-trouble (`kubent`) — <https://github.com/doitintl/kube-no-trouble>
- Pluto — <https://github.com/FairwindsOps/pluto>

**Availability during upgrades**
- Safely drain a node — <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/>
- Specifying a Disruption Budget — <https://kubernetes.io/docs/tasks/run-application/configure-pdb/>
- Disruptions concept — <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/>

**Supply chain**
- Verify signed Kubernetes artifacts — <https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/>
- Community package repositories (`pkgs.k8s.io`) — <https://kubernetes.io/blog/2023/08/15/pkgs-k8s-io-introduction/>
- Installing kubeadm — <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
- Sigstore cosign — <https://docs.sigstore.dev/cosign/signing/overview/>

**Certification**
- CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- CNCF curriculum repository — <https://github.com/cncf/curriculum>