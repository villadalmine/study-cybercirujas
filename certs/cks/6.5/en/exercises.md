# CKS 6.5 — Use Kubernetes Audit Logs to Monitor Access

## Guided Exercises

> **Exam weight:** 4 · **Cluster version:** v1.34 · **Estimated time:** 120–150 min
>
> Audit logging is the only mechanism in Kubernetes that answers *"who did what, to which object, from where, and was it allowed?"* after the fact. RBAC tells you what is *permitted*; the audit log tells you what was *attempted*. In the CKS exam this topic almost always appears as a static-pod edit under time pressure, so every exercise below ends with the same discipline: **change → restart → prove it works → prove you did not break the API server.**

---

### Lab prerequisites

* A **kubeadm-provisioned cluster** where you have `root` SSH on the control-plane node. The API server must run as a **static Pod** (`/etc/kubernetes/manifests/kube-apiserver.yaml`). Managed control planes (EKS/GKE/AKS) do **not** work for these exercises — you cannot edit their API server flags.
* `jq` installed on the control-plane node (`apt-get install -y jq` / `dnf install -y jq`).
* `crictl` configured (`crictl` is already present on kubeadm nodes; if `crictl ps` warns about the endpoint, run `crictl config runtime-endpoint unix:///run/containerd/containerd.sock`).
* A snapshot or backup of the manifest before you start. Non-negotiable:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.orig
```

Throughout, `controlplane` is the control-plane node hostname; substitute yours.

---

## Exercise 1 — Enable the log backend with a baseline policy

**Goal:** get audit events on disk with the smallest correct configuration, and understand each of the four moving parts (policy file, log path, hostPath mounts, static-pod restart).

1. Create the directory that will hold the log and the directory for the policy. The log directory **must exist on the host** before you mount it, unless you use `type: DirectoryOrCreate`:

```bash
sudo mkdir -p /var/log/kubernetes/audit
sudo mkdir -p /etc/kubernetes/audit
```

2. Write a deliberately naive, catch-all policy:

```bash
sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
EOF
```

3. Edit the API server static Pod manifest:

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

4. Add the audit flags to `spec.containers[0].command` (each flag is its own list item, aligned with the existing `- --advertise-address=...`):

```yaml
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

5. Add the two `volumeMounts` inside `spec.containers[0]`:

```yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/audit
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
      readOnly: false
```

6. Add the matching `volumes` under `spec` (same indentation level as `containers`):

```yaml
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

7. Save and exit. The kubelet detects the manifest change and recreates the Pod. Watch the container come back — **do not** use `kubectl` for this, because the API server is exactly what is down:

```bash
sudo crictl ps -a --name kube-apiserver --latest
```

Expected once healthy:

```
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT   POD ID
9f2b1c7a4e8d1  8a9c1f0d7e21b  18 seconds ago  Running   kube-apiserver   1         3ab77c9e1f2a4
```

8. Confirm the API is answering again and that the log file was created:

```bash
kubectl get nodes
sudo ls -lh /var/log/kubernetes/audit/
```

```
total 3.4M
-rw------- 1 root root 3.4M Aug  6 09:14 audit.log
```

9. Generate one event you can find deterministically, then look for it:

```bash
kubectl create namespace audit-demo
sudo grep -c '"kind":"Event"' /var/log/kubernetes/audit/audit.log
sudo grep 'audit-demo' /var/log/kubernetes/audit/audit.log | head -1 | jq .
```

**Questions**

* **Q1.** You added `--audit-policy-file` but forgot `--audit-log-path` and did not configure a webhook. The API server starts normally. Where do the audit events go, and why is this the single most dangerous misconfiguration of this topic?
* **Q2.** Why does the `audit-policy` volume use `readOnly: true` while `audit-log` uses `readOnly: false`? What happens at runtime if you invert them?
* **Q3.** The policy file lives on the host at `/etc/kubernetes/audit/policy.yaml` and the flag points at `/etc/kubernetes/audit/policy.yaml`. Explain precisely why both paths must be spelled out even though they look identical.
* **Q4.** In this baseline policy, roughly how many events does a single `kubectl create namespace` produce, and why is the count greater than one?

---

## Exercise 2 — Dissect an audit Event

**Goal:** read the schema fluently, because every investigation is a `jq` filter over these fields.

1. Extract one complete event for a Secret read. First, create something to read:

```bash
kubectl -n audit-demo create secret generic db-credentials \
  --from-literal=password='S3cr3t-Rotate-Me'
kubectl -n audit-demo get secret db-credentials -o yaml >/dev/null
```

2. Pull the corresponding event:

```bash
sudo jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="db-credentials" and .verb=="get")' \
  /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

Expected shape (values will differ):

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "4f8b0d47-2c6a-4a9d-9a41-2ec8f2a1c0d3",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-demo/secrets/db-credentials",
  "verb": "get",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["kubeadm:cluster-admins", "system:authenticated"]
  },
  "sourceIPs": ["192.168.178.20"],
  "userAgent": "kubectl/v1.34.0 (linux/amd64) kubernetes/f9a2c1e",
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-demo",
    "name": "db-credentials",
    "apiVersion": "v1"
  },
  "responseStatus": { "metadata": {}, "code": 200 },
  "requestReceivedTimestamp": "2026-08-06T09:14:22.118374Z",
  "stageTimestamp": "2026-08-06T09:14:22.121905Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" of ClusterRole \"cluster-admin\" to Group \"kubeadm:cluster-admins\""
  }
}
```

3. Produce a compact access report — one line per event — which is the format you actually want during an incident:

```bash
sudo jq -r 'select(.stage=="ResponseComplete")
  | [.stageTimestamp, .user.username, .verb,
     (.objectRef.resource // .requestURI), (.objectRef.namespace // "-"),
     (.objectRef.name // "-"), (.responseStatus.code|tostring)]
  | @tsv' /var/log/kubernetes/audit/audit.log | tail -20
```

4. Find every request that was **denied** by authorization — the highest-signal query in the whole log:

```bash
sudo jq -r 'select(.annotations."authorization.k8s.io/decision"=="forbid")
  | "\(.stageTimestamp) \(.user.username) \(.verb) \(.requestURI) :: \(.annotations."authorization.k8s.io/reason")"' \
  /var/log/kubernetes/audit/audit.log
```

5. Identify how many distinct identities touched the API in the current log, sorted by volume:

```bash
sudo jq -r 'select(.stage=="ResponseComplete") | .user.username' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
```

```
  48213 system:apiserver
  19077 system:kube-scheduler
  16552 system:node:controlplane
   9814 system:kube-controller-manager
    412 kubernetes-admin
     37 system:serviceaccount:audit-demo:reporting
```

**Questions**

* **Q5.** The event above has `level: Metadata` and `verb: get`. Would raising that rule to `level: Request` reveal the Secret's `data` field? Would `RequestResponse`? Justify both answers with the semantics of each level.
* **Q6.** `requestReceivedTimestamp` is `09:14:22.118374Z` and `stageTimestamp` is `09:14:22.121905Z`. What does the difference measure, and how would you use it to hunt for a slow admission webhook?
* **Q7.** What is the difference between `user.username` and `impersonatedUser`, and which field must an investigation filter on to catch an operator who ran `kubectl --as=system:serviceaccount:kube-system:default`?
* **Q8.** `sourceIPs` is an array, not a scalar. Under what topology does it contain more than one entry, and what does the ordering mean?

---

## Exercise 3 — A surgical policy: rule order, levels, `omitStages`, `omitManagedFields`

**Goal:** replace the catch-all with a production policy. The catch-all is unusable in production: on an idle three-node cluster it writes ~1–2 GB/day, and it logs the noisy control-plane loops that you never investigate.

1. Measure your current volume before changing anything:

```bash
sudo ls -l /var/log/kubernetes/audit/audit.log
sleep 60
sudo ls -l /var/log/kubernetes/audit/audit.log
```

2. Write the production policy. **Read the comments — rule order is the whole exercise:**

```bash
sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy

# Global: never emit the RequestReceived stage. It roughly halves log volume
# and carries no information that ResponseComplete does not already have,
# except for requests that never complete.
omitStages:
  - "RequestReceived"

# Global: strip .metadata.managedFields from logged bodies. Server-Side Apply
# metadata can be larger than the object itself and has no forensic value.
omitManagedFields: true

rules:
  # ---- 1. DROP: high-volume, low-value control-plane chatter -------------
  - level: None
    users:
      - "system:kube-scheduler"
      - "system:kube-controller-manager"
      - "system:apiserver"
    verbs: ["get", "list", "watch"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "pods/status", "endpoints"]

  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"
      - "/openapi/*"
      - "/apis*"
      - "/api*"

  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # ---- 2. SENSITIVE: metadata ONLY, never bodies ------------------------
  # Bodies of these objects contain credentials in cleartext. Logging them at
  # Request/RequestResponse converts the audit log into a secret store.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # ---- 3. HIGH VALUE: full request+response on privilege changes ---------
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "admissionregistration.k8s.io"
      - group: "policy"
        resources: ["podsecuritypolicies"]
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # ---- 4. Workload mutations: request body, not response -----------------
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "services", "persistentvolumeclaims"]
      - group: "apps"
      - group: "batch"

  # ---- 5. Exec / attach / port-forward: always, always logged ------------
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/eviction"]

  # ---- 6. Catch-all ------------------------------------------------------
  - level: Metadata
    omitStages:
      - "ResponseStarted"
EOF
```

3. Validate the YAML **before** the kubelet reads it (a malformed policy prevents the API server from starting):

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open("/etc/kubernetes/audit/policy.yaml")); print("YAML OK")'
```

4. Force a restart of the API server. Editing the policy file alone is **not** enough — the policy is parsed once at startup:

```bash
sudo crictl rm -f $(sudo crictl ps -q --name kube-apiserver)
```

Alternatively, touch the manifest to make the kubelet recreate the Pod:

```bash
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
```

5. Wait for readiness and confirm the drop rules work — kube-scheduler reads should now be absent:

```bash
sudo truncate -s 0 /var/log/kubernetes/audit/audit.log
sleep 60
sudo jq -r '.user.username' /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
```

6. Verify each level behaves as designed:

```bash
# Metadata only — no data field must appear
kubectl -n audit-demo get secret db-credentials -o yaml >/dev/null
sudo jq -c 'select(.objectRef.resource=="secrets") | {level, verb, hasBody: (has("responseObject"))}' \
  /var/log/kubernetes/audit/audit.log | tail -3

# RequestResponse on RBAC — full object must appear
kubectl -n audit-demo create role reader --verb=get --resource=pods
sudo jq -c 'select(.objectRef.resource=="roles") | {level, verb, rules: .responseObject.rules}' \
  /var/log/kubernetes/audit/audit.log | tail -1

# RequestResponse on exec
kubectl -n audit-demo run probe --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n audit-demo wait --for=condition=Ready pod/probe --timeout=60s
kubectl -n audit-demo exec probe -- id
sudo jq -c 'select(.objectRef.subresource=="exec") | {user: .user.username, uri: .requestURI}' \
  /var/log/kubernetes/audit/audit.log | tail -1
```

Expected for the exec event:

```json
{"user":"kubernetes-admin","uri":"/api/v1/namespaces/audit-demo/pods/probe/exec?command=id&container=probe&stderr=true&stdout=true"}
```

7. Compare volume against step 1 — you should see a reduction of roughly one order of magnitude.

**Questions**

* **Q9.** Move the catch-all `- level: Metadata` rule from the bottom to the top of `rules` and restart. What happens to the RBAC `RequestResponse` rule, and what is the general matching algorithm?
* **Q10.** The exec rule (`pods/exec`) sits at position 5, *after* the `level: None` rule for `system:nodes`. Could a `kubectl exec` ever be silently dropped by that earlier rule? Explain using the fields the rules match on.
* **Q11.** The policy sets `omitManagedFields: true` globally. Write the two-line change that keeps managed fields **only** for the RBAC rule, and explain the override semantics (global vs. rule-level) for `omitManagedFields` versus `omitStages`.
* **Q12.** Rule 6 uses `omitStages: ["ResponseStarted"]` while the policy header already omits `RequestReceived`. Which stages does a `kubectl get pods` matching rule 6 actually emit?
* **Q13.** Rule 3 declares `- group: "admissionregistration.k8s.io"` with no `resources` key. What does an empty `resources` list mean, and why is that both convenient and risky?

---

## Exercise 4 — Incident investigation from the audit log

**Goal:** run the four queries you will actually need at 03:00: *who read the secret*, *who deleted the object*, *who is enumerating*, *what did the compromised ServiceAccount touch*.

1. Stage the incident. Create a ServiceAccount with a narrow Role, then use it:

```bash
kubectl -n audit-demo create serviceaccount reporting
kubectl -n audit-demo create role secret-reader --verb=get,list --resource=secrets
kubectl -n audit-demo create rolebinding reporting-secret-reader \
  --role=secret-reader --serviceaccount=audit-demo:reporting

TOKEN=$(kubectl -n audit-demo create token reporting --duration=1h)
APISERVER=https://$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}'):6443

# Allowed
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/audit-demo/secrets/db-credentials" >/dev/null

# Denied — enumeration attempt across the cluster
for r in pods deployments nodes secrets serviceaccounts; do
  curl -sk -o /dev/null -w "%{http_code} $r\n" -H "Authorization: Bearer $TOKEN" \
    "$APISERVER/api/v1/$r"
done
```

Expected:

```
403 pods
404 deployments
403 nodes
403 secrets
403 serviceaccounts
```

2. **Who read the Secret?** — every principal that touched any Secret, with the outcome:

```bash
sudo jq -r 'select(.objectRef.resource=="secrets" and (.verb|test("get|list|watch")))
  | "\(.stageTimestamp)\t\(.user.username)\t\(.verb)\t\(.objectRef.namespace)/\(.objectRef.name // "*")\t\(.responseStatus.code)\t\(.annotations."authorization.k8s.io/decision")"' \
  /var/log/kubernetes/audit/audit.log | sort | tail -20
```

3. **Who deleted it?** — simulate and then trace a destructive action:

```bash
kubectl -n audit-demo delete pod probe --now
sudo jq -r 'select(.verb=="delete" or .verb=="deletecollection")
  | "\(.stageTimestamp) \(.user.username) via \(.userAgent | split(" ")[0]) from \(.sourceIPs[0]) -> \(.objectRef.resource)/\(.objectRef.name) in \(.objectRef.namespace // "-") [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log | tail -10
```

4. **Enumeration detection** — count 403s per identity in a rolling window. Any non-human identity with a burst of denials is a compromised-credential signal:

```bash
sudo jq -r 'select(.responseStatus.code==403)
  | "\(.user.username)"' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head
```

```
      4 system:serviceaccount:audit-demo:reporting
      1 system:anonymous
```

5. **Blast radius of one identity** — everything a single principal did, in order:

```bash
sudo jq -r 'select(.user.username=="system:serviceaccount:audit-demo:reporting")
  | "\(.stageTimestamp) \(.verb) \(.requestURI) [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log | sort
```

6. **Detect impersonation abuse** — the field most teams forget to monitor:

```bash
kubectl --as=system:serviceaccount:kube-system:default get pods -A 2>/dev/null | head -2
sudo jq -r 'select(has("impersonatedUser"))
  | "\(.stageTimestamp) REAL=\(.user.username) AS=\(.impersonatedUser.username) \(.verb) \(.requestURI) [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log
```

7. Note the log rotation state. The API server rotates in-process, it does not use `logrotate`:

```bash
sudo ls -la /var/log/kubernetes/audit/
```

```
-rw------- 1 root root  42M Aug  6 09:52 audit.log
-rw------- 1 root root 100M Aug  6 08:31 audit-2026-08-06T08-31-04.117.log
```

**Questions**

* **Q14.** In step 1, the request for `deployments` returned **404** while the others returned **403**. Explain why, and what the audit event for that request looks like in terms of `objectRef` and `annotations`.
* **Q15.** Your policy logs Secrets at `Metadata`. An auditor asks: *"prove that the `reporting` ServiceAccount never saw the value of `db-credentials`."* Can you prove it from this log? What can you actually prove, and what is the correct architectural answer to the auditor?
* **Q16.** Someone deleted a Deployment and you find only an event with `user.username: system:serviceaccount:kube-system:generic-garbage-collector`. What happened, and which field in the *original* event identifies the human who really triggered it?
* **Q17.** The log rotated and the file you need is `audit-2026-08-06T08-31-04.117.log`. With `--audit-log-maxbackup=10` and `--audit-log-maxsize=100`, what is the maximum on-disk footprint and the worst-case retention window on a busy cluster? Why is `--audit-log-maxage=30` misleading here?
* **Q18.** You have a three-node HA control plane behind a load balancer. You run the query in step 5 on `controlplane-1` and find nothing. Is the identity clean?

---

## Exercise 5 — The webhook backend: shipping audit events off-node

**Goal:** understand why the log backend alone fails an audit requirement, and configure the dynamic sink.

1. On the control-plane node, run a minimal receiver that prints what it gets. The API server runs with `hostNetwork: true`, so `127.0.0.1` on the node is reachable from inside the Pod:

```bash
sudo tee /root/audit-sink.py >/dev/null <<'EOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        payload = json.loads(body)
        for ev in payload.get('items', []):
            print(f"{ev.get('stageTimestamp')} {ev['user']['username']} "
                  f"{ev.get('verb')} {ev.get('requestURI')} "
                  f"[{ev.get('responseStatus', {}).get('code')}]", flush=True)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', 9900), Sink).serve_forever()
EOF

sudo nohup python3 /root/audit-sink.py >/var/log/audit-sink.log 2>&1 &
```

2. Write the webhook configuration. It is a **kubeconfig-format** file — this trips up most people, because it describes an external HTTP endpoint, not a cluster:

```bash
sudo tee /etc/kubernetes/audit/webhook.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: audit-sink
  cluster:
    server: http://127.0.0.1:9900/events
users:
- name: kube-apiserver
contexts:
- name: default
  context:
    cluster: audit-sink
    user: kube-apiserver
current-context: default
EOF
```

3. Add the webhook flags to the API server manifest, alongside the existing log flags:

```yaml
    - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
    - --audit-webhook-mode=batch
    - --audit-webhook-batch-max-size=100
    - --audit-webhook-batch-max-wait=5s
    - --audit-webhook-initial-backoff=10s
```

The `webhook.yaml` file already lives under `/etc/kubernetes/audit`, which is mounted, so **no new volume is required**.

4. Save, wait for the restart, and watch the sink:

```bash
sudo tail -f /var/log/audit-sink.log
```

In a second shell:

```bash
kubectl -n audit-demo get secrets
kubectl -n audit-demo create configmap probe-cm --from-literal=a=b
```

Expected in the sink:

```
2026-08-06T10:22:41.882913Z kubernetes-admin list /api/v1/namespaces/audit-demo/secrets [200]
2026-08-06T10:22:44.019447Z kubernetes-admin create /api/v1/namespaces/audit-demo/configmaps [201]
```

5. Test the failure mode. Kill the sink and observe that the cluster keeps working:

```bash
sudo pkill -f audit-sink.py
kubectl -n audit-demo get pods     # still works
sudo crictl logs $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i webhook | tail -5
```

```
E0806 10:24:11.774218  1 metrics.go:120] "Failed to post latency metrics" err="Post \"http://127.0.0.1:9900/events\": dial tcp 127.0.0.1:9900: connect: connection refused"
```

6. Now change `--audit-webhook-mode=batch` to `--audit-webhook-mode=blocking-strict`, restart, and repeat step 5 with the sink still down. Observe the effect on API requests, then **revert to `batch`**.

**Questions**

* **Q19.** Both backends were active simultaneously in this exercise. Is that supported, and do both use the same policy file?
* **Q20.** Explain the operational difference between `--audit-webhook-mode=batch`, `blocking`, and `blocking-strict`. Which one can take your cluster down, and what exactly does `blocking-strict` block on that `blocking` does not?
* **Q21.** The webhook config above uses plain `http://` with no client credentials. Name the three concrete risks this creates, and how you would fix each with fields available in that same kubeconfig.
* **Q22.** A colleague asks you to configure the `AuditSink` API object so audit policy can be managed dynamically with `kubectl` instead of by editing the static Pod. What do you tell them?

---

## Exercise 6 — Break/fix: the API server will not come back

**Goal:** the failure mode you *will* hit in the exam. Practice recovering without `kubectl`.

1. Introduce a realistic fault — a policy path that is not mounted:

```bash
sudo cp /etc/kubernetes/audit/policy.yaml /root/policy-elsewhere.yaml
sudo sed -i 's#--audit-policy-file=.*#--audit-policy-file=/root/policy-elsewhere.yaml#' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

2. Confirm the cluster is down:

```bash
kubectl get nodes
```

```
E0806 10:41:02.113 The connection to the server 192.168.178.20:6443 was refused - did you specify the right host or port?
```

3. Diagnose. Since the container exits immediately, `crictl ps` shows nothing — you need `-a`:

```bash
sudo crictl ps -a --name kube-apiserver --latest
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver --latest) 2>&1 | tail -20
```

```
Error: error while parsing file: open /root/policy-elsewhere.yaml: no such file or directory
```

4. The other reliable source, which survives container garbage collection:

```bash
sudo ls /var/log/pods/kube-system_kube-apiserver-controlplane_*/kube-apiserver/
sudo tail -20 /var/log/pods/kube-system_kube-apiserver-controlplane_*/kube-apiserver/*.log
```

5. Fix the path and confirm recovery:

```bash
sudo sed -i 's#--audit-policy-file=.*#--audit-policy-file=/etc/kubernetes/audit/policy.yaml#' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sudo crictl ps -a --name kube-apiserver --latest
kubectl get nodes
```

6. Repeat the drill with a **second** fault class — an invalid policy document:

```bash
sudo sed -i 's/^  - level: Metadata$/  - level: MetaData/' /etc/kubernetes/audit/policy.yaml
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 15
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver --latest) 2>&1 | tail -5
```

```
Error: loading audit policy file: failed to decode: strict decoding error: invalid policy level "MetaData"
```

Then repair it:

```bash
sudo sed -i 's/^  - level: MetaData$/  - level: Metadata/' /etc/kubernetes/audit/policy.yaml
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
```

7. Third fault class — the `volumes` block missing while `volumeMounts` is present. Remove the `audit-log` entry from `spec.volumes` only, then restart and read the kubelet's view:

```bash
sudo journalctl -u kubelet --since "2 min ago" | grep -i -A3 'kube-apiserver'
```

**Questions**

* **Q23.** In step 3 you used `crictl ps -a`. Why is the `-a` mandatory here, and why does `crictl logs` sometimes return nothing at all for this Pod?
* **Q24.** The kubelet keeps restarting the API server container. Is there a backoff, and how does that change your troubleshooting rhythm (i.e. how long should you wait before concluding your fix failed)?
* **Q25.** Rank these three faults by how they present: (a) policy file path not mounted, (b) invalid `level` value, (c) `volumeMounts` referencing a `name` that has no matching entry in `volumes`. Which one produces an error from the *kubelet* rather than from the *API server*, and why?
* **Q26.** You have no `crictl` and no `journalctl` access, only a shell on the node. Name one more place to look for the reason the API server died.

---

## Exercise 7 — Admission-generated audit annotations (advanced)

**Goal:** enrich audit events from admission control, so the audit log records *policy verdicts*, not just API calls. This is the modern replacement for "run a mutating webhook that logs".

1. Create a `ValidatingAdmissionPolicy` that flags privileged containers **without blocking them**, and attaches an audit annotation:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: privileged-container-audit
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
  - expression: >-
      !object.spec.containers.exists(c,
        has(c.securityContext) &&
        has(c.securityContext.privileged) &&
        c.securityContext.privileged == true)
    message: "privileged containers are not allowed"
    reason: Forbidden
  auditAnnotations:
  - key: "privileged-request"
    valueExpression: >-
      object.spec.containers.exists(c,
        has(c.securityContext) &&
        has(c.securityContext.privileged) &&
        c.securityContext.privileged == true)
      ? "pod " + object.metadata.name + " requested a privileged container"
      : null
EOF
```

2. Bind it in **audit-only** mode:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: privileged-container-audit-binding
spec:
  policyName: privileged-container-audit
  validationActions: ["Audit"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: audit-demo
EOF
```

3. Trigger it:

```bash
kubectl -n audit-demo apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
EOF
```

The Pod is **created** (`validationActions: ["Audit"]` does not deny).

4. Read the annotations that admission wrote into the audit event:

```bash
sudo jq -c 'select(.objectRef.resource=="pods" and .objectRef.name=="bad-pod" and .verb=="create")
  | .annotations' /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

```json
{
  "authorization.k8s.io/decision": "allow",
  "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" ...",
  "privileged-container-audit/privileged-request": "pod bad-pod requested a privileged container",
  "validation.policy.admission.k8s.io/validation_failure": "[{\"expressionIndex\":0,\"message\":\"privileged containers are not allowed\",\"reason\":\"Forbidden\",\"binding\":\"privileged-container-audit-binding\",\"policy\":\"privileged-container-audit\",\"validationActions\":[\"Audit\"]}]"
}
```

5. Build the detection query you would actually alert on:

```bash
sudo jq -r 'select(.annotations."validation.policy.admission.k8s.io/validation_failure" != null)
  | "\(.stageTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.name) :: \(.annotations."validation.policy.admission.k8s.io/validation_failure")"' \
  /var/log/kubernetes/audit/audit.log
```

6. Also check what Pod Security Admission writes on its own — enable audit mode on the namespace and repeat:

```bash
kubectl label ns audit-demo pod-security.kubernetes.io/audit=restricted --overwrite
kubectl -n audit-demo run bad-pod-2 --image=busybox:1.36 --restart=Never -- sleep 3600
sudo jq -c 'select(.objectRef.name=="bad-pod-2") | .annotations
  | with_entries(select(.key|startswith("pod-security")))' \
  /var/log/kubernetes/audit/audit.log | tail -1
```

```json
{"pod-security.kubernetes.io/audit-violations":"would violate PodSecurity \"restricted:latest\": allowPrivilegeEscalation != false (container \"bad-pod-2\" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (...), runAsNonRoot != true (...), seccompProfile (...)"}
```

**Questions**

* **Q27.** Your policy logs Pod creates at `level: Request`. Would these annotations still appear if that rule were `level: Metadata`? What is the lowest level at which `annotations` are recorded, and what does that imply for the "drop noise" rules in Exercise 3?
* **Q28.** The `valueExpression` returns `null` for compliant Pods. What is the practical effect on the audit log, and why is that better than returning `"ok"`?
* **Q29.** You want the same visibility but with enforcement. What single field do you change, and what will the audit event look like afterwards — specifically `responseStatus.code` and whether the `validation_failure` annotation is still present?

---

## Exercise 8 — Timed exam drill (12 minutes, no notes)

**Goal:** reproduce the exact shape of the exam task from scratch.

> **Task.** On `controlplane`, enable API server audit logging so that:
> 1. Events are written to `/var/log/kubernetes/audit/audit.log`, rotated at 100 MB, keeping 5 files, discarding files older than 7 days.
> 2. The `RequestReceived` stage is never logged.
> 3. Changes to `Secrets` in **any** namespace are logged at `Metadata` level.
> 4. `get`/`list`/`watch` on `ConfigMaps` in namespace `kube-system` are **not** logged at all.
> 5. Everything else is logged at `Metadata`.
> 6. The policy lives at `/etc/kubernetes/audit-policy.yaml`.

1. Set a timer for 12 minutes.
2. Write the policy, edit the manifest, restart, and verify with a command that proves *each* of requirements 2, 3 and 4 independently.
3. Stop the timer. Then check your work against the reference solution in the answers section.

**Questions**

* **Q30.** Requirement 3 says "changes to Secrets". Did you constrain `verbs`? What is the difference in resulting log volume and in correctness between constraining it and not?
* **Q31.** Requirements 4 and 5 are in tension. What is the only rule ordering that satisfies both, and what one-line `jq` command proves requirement 4 is actually in effect?

---

## Cleanup

```bash
kubectl delete ns audit-demo --ignore-not-found
kubectl delete validatingadmissionpolicybinding privileged-container-audit-binding --ignore-not-found
kubectl delete validatingadmissionpolicy privileged-container-audit --ignore-not-found
sudo pkill -f audit-sink.py 2>/dev/null
sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 20 && kubectl get nodes
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.** Nowhere. The policy is evaluated and events are generated, but with no backend configured they are discarded. The API server does **not** warn about this at any meaningful log level, and it starts perfectly healthily. This is dangerous because every verification you might run — "the API server is up", "the policy file parses", "the flag is present" — passes, so the configuration looks correct in a change review while producing zero forensic coverage. The only valid verification is the one in step 8/9: prove the file exists **and** grows **and** contains an event you deliberately caused. The same trap exists in reverse: `--audit-log-path` without `--audit-policy-file` makes the API server refuse to start.

**A2.** The API server only reads the policy, so mounting it read-only is least-privilege and prevents a compromised API server process from rewriting its own audit rules. It must *write* the log, so that mount cannot be read-only. If inverted: the API server would still start (it never writes the policy), but on the first audit event it fails to open the log file for writing and exits — `open /var/log/kubernetes/audit/audit.log: read-only file system`. Note this is one of the few cases where the failure is delayed rather than immediate.

**A3.** They are two different filesystems. The path in `hostPath.path` is resolved on the **node**; the path in `--audit-policy-file` and in `mountPath` is resolved inside the **API server container's mount namespace**. They coincide here only because we chose to mount at the same path — a deliberate convention that makes the manifest readable. Nothing forces it: you could mount the host's `/etc/kubernetes/audit` at `/policies` inside the container and pass `--audit-policy-file=/policies/policy.yaml`. The failure in Exercise 6 step 1 is exactly this distinction: `/root/policy-elsewhere.yaml` exists on the host but not in the container.

**A4.** At minimum **two**, and typically more. With no `omitStages`, every request produces a `RequestReceived` event and a `ResponseComplete` event. Long-running requests (watches) additionally emit `ResponseStarted`. On top of the `create namespace` call itself, `kubectl` performs discovery requests against `/api`, `/apis`, and `/apis/<group>/<version>`, and the namespace controller immediately begins reconciling — so the practical count for one `kubectl create namespace` on a catch-all policy is in the dozens. This is why the catch-all policy is a teaching device only.

### Exercise 2

**A5.** Neither reveals it for a `get`.
- `Request` logs event metadata plus the **request** body. A `get` has no request body, so `Request` is informationally identical to `Metadata` for reads. It *would* reveal the Secret on a `create`/`update`, because there the request body is the object.
- `RequestResponse` logs metadata plus request **and response** bodies. For a `get secrets`, the response body is the Secret, including `.data` — base64, which is encoding, not encryption. So `RequestResponse` on Secrets writes every credential in the cluster into a plaintext file on the control-plane node, and into whatever SIEM you ship it to.

This is why the upstream recommended policy pins Secrets, ConfigMaps and TokenReviews to `Metadata`. The audit log then becomes a *new* secret store with weaker access control than etcd — the opposite of the control's intent.

**A6.** ~3.5 ms — the server-side latency from the moment the API server received the request until the moment the given stage completed. It spans authentication, authorization, **all admission webhooks**, and the etcd round-trip. To hunt a slow webhook, compare the delta for mutating verbs (which traverse admission) against read verbs (which do not) on the same resource:

```bash
sudo jq -r 'select(.stage=="ResponseComplete" and (.verb=="create" or .verb=="update"))
  | [((.stageTimestamp|fromdateiso8601) - (.requestReceivedTimestamp|fromdateiso8601)),
     .objectRef.resource, .user.username] | @tsv' /var/log/kubernetes/audit/audit.log \
  | sort -rn | head
```

Anything above ~1 s on a create is almost always a webhook, and the `objectRef.resource` tells you which webhook's `rules` to inspect. Caveat: `fromdateiso8601` truncates sub-second precision; for millisecond work, parse the fractional part or use the `apiserver_request_duration_seconds` metric instead.

**A7.** `user` is the **authenticated** identity — who actually presented the credential. `impersonatedUser` is the identity they asked the API server to act as, populated only when `Impersonate-User`/`Impersonate-Group` headers are present (which is what `kubectl --as` sends). Authorization is checked **twice**: the real user must hold the `impersonate` verb, and the impersonated user must be allowed to perform the action.

An investigation must filter on **both**. Filtering only on `user.username` misses what the operator did while impersonating; filtering only on `impersonatedUser` loses the human accountable for it. The correct query joins them, as in Exercise 4 step 6. Impersonation is a common privilege-escalation path precisely because most detection rules ignore the field.

**A8.** `sourceIPs` contains more than one entry when the request traversed proxies that appended `X-Forwarded-For`, and the API server was started with `--requestheader-allowed-names`/proxy trust configured. The ordering is **originating client first, nearest proxy last** — so `sourceIPs[0]` is the claimed origin and the final element is the peer the API server actually accepted the TCP connection from. Only the last element is trustworthy without a trusted proxy chain; `X-Forwarded-For` is client-settable otherwise.

### Exercise 3

**A9.** The RBAC rule becomes dead. **The first rule that matches an event determines its level, and evaluation stops there** — there is no "most specific wins", no rule merging, and no warning about unreachable rules. A catch-all at the top makes every subsequent rule unreachable, so the entire policy collapses to `Metadata` for everything. The corollary is the design rule for every audit policy: **`None` drop rules first, most specific `RequestResponse` rules next, catch-all last, always.**

**A10.** No. That rule matches on `userGroups: ["system:nodes"]` **and** `resources` limited to `nodes`, `pods`, `endpoints` and their status subresources — and matching is an AND across the fields present in the rule. `pods/exec` is a *different* resource entry (`resources: ["pods"]` does **not** cover `pods/exec`; subresources must be named explicitly as `pods/exec` or wildcarded as `pods/*`). Additionally, `kubectl exec` is a `create` verb, and that rule constrains verbs to `get`/`list`/`watch`. Two independent reasons it cannot match — but note that the safety here comes from the explicit subresource semantics, not from luck: if that rule had said `resources: ["pods/*"]` with no verb constraint, it *would* have swallowed exec events from kubelets.

**A11.** Add a rule-level override:

```yaml
  - level: RequestResponse
    omitManagedFields: false          # <-- keep managedFields for RBAC objects
    resources:
      - group: "rbac.authorization.k8s.io"
      ...
```

The two fields have **opposite** composition semantics, and this is a classic exam trap:
- `omitManagedFields`: the rule-level value **overrides** the global value.
- `omitStages`: the rule-level list is **unioned** with the global list. A rule can therefore only ever omit *more* stages than the policy header, never fewer — there is no way to re-enable `RequestReceived` for one rule once the header omits it globally.

**A12.** Only `ResponseComplete`. `RequestReceived` is omitted globally, `ResponseStarted` is omitted by the rule, and the union of the two lists leaves `ResponseComplete` (and `Panic`, which is emitted only when the handler panics). For a short `get pods` this is exactly the one event you want.

**A13.** An empty or absent `resources` list within a `group` entry means **all resources in that API group**, at all versions. It is convenient because a new resource added to `admissionregistration.k8s.io` in a future release (a new policy kind, for example) is covered automatically without a policy edit. It is risky for exactly the same reason: an upstream release can silently multiply your log volume, and if the group ever gains a high-cardinality or credential-bearing resource, you have opted into logging it at `RequestResponse` without review. The rule is safe here only because the accompanying `verbs` list excludes reads. For any group that might carry secret material, enumerate resources explicitly.

### Exercise 4

**A14.** `/api/v1/deployments` is not a valid path — Deployments live in the `apps` group at `/apis/apps/v1/deployments`. The API server's routing rejects the path before RBAC ever runs, so it returns **404**, and the audit event is a **non-resource** event: `objectRef` is absent or empty, `requestURI` is `/api/v1/deployments`, and there is **no** `authorization.k8s.io/decision` annotation because authorization was never consulted.

The forensic lesson is that 404 and 403 mean very different things: 403 proves the identity was authenticated and RBAC denied it (a real access attempt); 404 on a bogus path often just means a broken client — but a *burst* of 404s across many paths is fingerprinting, and it is invisible to any detection rule that only counts 403s.

**A15.** **No, and this is the central trade-off of the topic.** At `Metadata` level you can prove that a `get` for `secrets/db-credentials` occurred, by whom, from where, at what time, and that it returned `200`. You cannot prove what value was returned — but a `200` on a `get` of a Secret means the caller *did* receive the data. So you can prove the opposite of what the auditor wants: the log shows the SA **did** obtain it.

The correct answer to the auditor is that the audit log is not the right control for this question, and that raising the level to `RequestResponse` to "prove" it would be actively harmful — it would write the credential into the log. The right controls are: rotate the credential, remove the RoleBinding, use short-lived projected ServiceAccount tokens with an audience, encrypt Secrets at rest (`EncryptionConfiguration`), and move to an external secret store with its own access log. Audit tells you *access happened*; confidentiality of the value is a different control.

**A16.** Cascading deletion. The human deleted an owner object (the Deployment), and the garbage collector subsequently deleted the dependents (ReplicaSet, Pods) under its own identity. You are looking at the *dependent's* event, not the trigger.

Correlate on the **original** event: find the `delete` on the owner resource where `user.username` is the human. Two fields make the join reliable — `objectRef.uid` on the owner event matches the `metadata.ownerReferences[].uid` on the dependents, and `requestReceivedTimestamp` orders the cascade. Practically: search backwards in time from the garbage-collector event for the nearest `delete` on the owning resource by a non-`system:` identity.

**A17.** Maximum footprint is **`maxsize × (maxbackup + 1)` = 100 MB × 11 ≈ 1.1 GB** — 10 rotated files plus the active one. `--audit-log-maxage=30` is misleading because it is a *ceiling*, not a guarantee: rotation is driven by **size first**. On a cluster producing 500 MB/day, 11 × 100 MB is consumed in roughly 2.2 days, so files are deleted by the `maxbackup` limit long before they reach 30 days old. Your effective retention is `1.1 GB ÷ daily volume`, and it shrinks the moment traffic increases — meaning your forensic window silently collapses during exactly the incident that generates extra API traffic. The fix is not bigger numbers on the node; it is shipping events off-node (webhook backend, or a log collector reading the file) so retention is decoupled from node disk.

**A18.** No — you have only proven it did not talk to *that* API server instance. **Audit configuration and audit logs are per-API-server-process.** In HA, the load balancer distributes requests across all three, so a single identity's activity is scattered across three files on three nodes. You must (a) deploy the identical policy and flags to every control-plane node — a drift here creates a blind spot that looks like clean logs — and (b) aggregate centrally before querying. Until both are true, "I found nothing" is not a finding. This is the strongest practical argument for the webhook backend over the log backend.

### Exercise 5

**A19.** Yes, both backends can be enabled simultaneously and that is the recommended production shape: the log backend as a node-local buffer of record, the webhook for central aggregation and alerting. **Both consume the same single policy** — there is exactly one `--audit-policy-file` and it governs which events are generated at all. You cannot send `Metadata` to the webhook and `RequestResponse` to disk; filtering per-backend has to happen downstream, in the collector.

**A20.**
- `batch` (default for the webhook backend): events are buffered and POSTed asynchronously in batches. API requests never wait on the sink. If the sink is down, events are retried with backoff and then **dropped** when the buffer fills.
- `blocking`: the API request blocks until the event has been sent. A slow sink adds its latency to every API call; a failing sink causes request errors.
- `blocking-strict`: as `blocking`, and additionally, if the event for the **`RequestReceived` stage** fails to be recorded, the API request itself is **failed** rather than allowed to proceed.

`blocking` and `blocking-strict` can both take a cluster down when the sink degrades; `blocking-strict` is strictly worse operationally and strictly better for compliance, because it makes it impossible for an action to occur without a corresponding audit record. That is the actual trade: `batch` may lose evidence, `blocking-strict` may lose availability. Choose deliberately, and if you choose `blocking-strict`, the sink must be as highly available as the control plane itself. (The log backend has the analogous `--audit-log-mode`, defaulting to `blocking`.)

**A21.**
1. **Cleartext on the wire** — audit events contain usernames, resource names, and at `RequestResponse` full object bodies. Fix: `https://` plus `certificate-authority-data` in the `cluster` stanza so the API server verifies the sink.
2. **No server authentication** — anything that can bind the port or win a DNS/ARP race receives your audit stream. Fix: same as above; CA pinning is what makes the endpoint's identity meaningful.
3. **No client authentication** — the sink cannot tell your API server from any other poster, so anyone can inject forged audit events to bury a real one. Fix: `client-certificate-data`/`client-key-data` in the `users` stanza (mTLS), or a bearer `token`.

All three are fields of the standard kubeconfig schema, which is precisely why the webhook config uses that format. Also note the file must be mounted into the API server container and its private key protected at `0600` root-owned.

**A22.** The `AuditSink` API (`auditregistration.k8s.io/v1alpha1`, "dynamic audit configuration") was deprecated and **removed in Kubernetes 1.19**. It does not exist in v1.34 and is not coming back. Audit policy is control-plane configuration, not cluster data, and it is configured through API server flags and files only — which is a security property, not an oversight: if audit policy were a cluster-scoped API object, anyone with the RBAC to edit it could disable their own logging before acting. Managing the static Pod manifest and policy file with configuration management (or a managed provider's control-plane logging settings) is the supported path.

### Exercise 6

**A23.** `crictl ps` lists only **running** containers. A container that crashes during startup is in `Exited` state within a second, so without `-a` (all states) you see an empty list and might wrongly conclude the container was never created. `crictl logs` returns nothing when the container has already been garbage-collected by the kubelet — on a fast crash loop the ID you captured a moment ago may no longer exist, which is why `--latest` matters and why `/var/log/pods/.../*.log` (step 4) is the more durable source: those files survive container removal and retain previous attempts.

**A24.** Yes — the kubelet applies **exponential backoff** to crash-looping containers, starting around 10 s and doubling up to a cap of 5 minutes. Practically this means that after a fix, a container that has already crashed many times may take minutes to be retried, and an impatient operator will conclude the fix failed and start changing more things — turning one fault into three. The correct rhythm: apply the fix, then **force** a fresh attempt rather than waiting out the backoff. `sudo crictl rm -f <id>` on the exited container, or moving the manifest out of `/etc/kubernetes/manifests` and back in, makes the kubelet treat it as a new Pod and resets the backoff.

**A25.**
- (a) Path not mounted → **API server** error, container starts and exits: `open /root/policy-elsewhere.yaml: no such file or directory`.
- (b) Invalid `level` → **API server** error at policy parse time, container starts and exits: `invalid policy level "MetaData"`.
- (c) `volumeMounts` name with no matching `volumes` entry → **kubelet** error; the container is **never created at all**.

(c) is the one to recognise, because its signature is different in kind: `crictl ps -a` shows no new container and `crictl logs` has nothing to show, so the usual reflex produces zero information. The reason is that the mount reference is resolved by the kubelet while constructing the Pod, before the runtime is ever asked to create a container. The evidence lives in `journalctl -u kubelet` as a validation error on the Pod spec. Rule of thumb: **no container at all → kubelet; container that starts and dies → API server.**

**A26.** Several, in order of usefulness:
1. `/var/log/pods/kube-system_kube-apiserver-<node>_<uid>/kube-apiserver/*.log` — the raw container stdout/stderr, retained across restarts including prior attempts.
2. `/var/log/containers/kube-apiserver-*.log` — symlinks into the above.
3. The mirror Pod's status once the API server recovers: `kubectl -n kube-system describe pod kube-apiserver-<node>` shows `Last State: Terminated` with the exit reason and message.
4. `sudo ctr -n k8s.io containers ls` / `ctr -n k8s.io tasks ls` if `crictl` is unavailable but containerd is present.

### Exercise 7

**A27.** Yes, they would still appear. **`annotations` are part of event metadata and are recorded at `Metadata` level and above** — you do not need `Request` or `RequestResponse` to capture admission verdicts, RBAC decisions, or PSA violations. That is a significant efficiency result: you get full policy-verdict visibility at the cheapest logging level.

The implication for the drop rules is the sharp one: **`level: None` discards the annotations too.** Any resource or identity you drop for volume reasons becomes invisible to admission-verdict alerting, no matter how loudly your admission policies complain. So before adding a `None` rule, check that no admission policy you rely on for detection matches that same traffic — a `None` rule on `system:nodes` writes is a plausible-looking optimisation that would silently blind you to kubelet-originated policy violations.

**A28.** `valueExpression` returning `null` means the annotation is **not recorded at all**. Every compliant Pod create therefore produces an audit event with no extra annotation, and the alerting query in step 5 is a simple existence check with no false positives to filter.

Returning `"ok"` would attach an annotation to every single Pod create in the cluster — inflating event size, costing storage and SIEM ingest on the 99.9% of events that are uninteresting, and forcing every downstream query to filter by *value* rather than by *presence*. The general principle: **audit annotations should be sparse and mean "something happened", not dense and mean "here is a status".**

**A29.** Change `validationActions: ["Audit"]` to `["Deny"]` (or `["Deny", "Audit"]`) on the **binding** — the policy itself is unchanged, which is the point of the policy/binding split: one policy can be enforced in one namespace and audited in another.

Afterwards:
- `responseStatus.code` becomes **403** and `responseStatus.message` carries the policy's `message`, because `reason: Forbidden` maps to a 403.
- Your `auditAnnotations` (`privileged-container-audit/privileged-request`) **are still present** — audit annotations are emitted regardless of whether the request was admitted.
- The `validation.policy.admission.k8s.io/validation_failure` annotation is emitted when `Audit` is among the actions. With `["Deny"]` alone the denial is visible from the 403 and the response message; include `["Deny","Audit"]` if you want the structured annotation as well, which is the better choice because it gives you one uniform detection query across enforced and unenforced namespaces.

Note also that `Warn` is a third action, surfacing the message on the client's stderr — useful during rollout, invisible to the audit log.

### Exercise 8 — reference solution

`/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 4. Drop reads of ConfigMaps in kube-system — MUST come first
  - level: None
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["configmaps"]
    namespaces: ["kube-system"]

  # 3. Secret changes at Metadata
  - level: Metadata
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["secrets"]

  # 5. Everything else at Metadata
  - level: Metadata
```

Flags added to `spec.containers[0].command`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxsize=100
    - --audit-log-maxbackup=5
    - --audit-log-maxage=7
```

Volumes — note the policy is a **file** at `/etc/kubernetes/audit-policy.yaml`, not a directory, so `type: File`:

```yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit/
      name: audit-log
      readOnly: false
```

```yaml
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit/
      type: DirectoryOrCreate
```

Independent verification, one command per requirement:

```bash
# req 2 — must return 0
sudo jq -r 'select(.stage=="RequestReceived")' /var/log/kubernetes/audit/audit.log | wc -l

# req 3 — must show the create at Metadata level
kubectl -n default create secret generic drill --from-literal=a=b
sudo jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="drill")
  | {level, verb, ns: .objectRef.namespace}' /var/log/kubernetes/audit/audit.log

# req 4 — must return 0
kubectl -n kube-system get configmaps >/dev/null
sudo jq -r 'select(.objectRef.resource=="configmaps" and .objectRef.namespace=="kube-system"
  and (.verb|test("get|list|watch")))' /var/log/kubernetes/audit/audit.log | wc -l
```

**A30.** Yes — `verbs: ["create","update","patch","delete","deletecollection"]` is required. "Changes" excludes reads, and a Secret-heavy cluster performs far more `get`/`watch` on Secrets than writes (every kubelet watches the Secrets mounted into its Pods, every controller re-reads its credentials). Omitting `verbs` is not just noisier — it is *wrong* against the stated requirement, and graders check the rule, not the log.

The correctness nuance in the other direction: `patch` and `deletecollection` are easy to forget, and both are genuine mutations. A rule with only `create,update,delete` silently misses `kubectl patch secret` — which is what a `create --dry-run | apply` or a controller-driven rotation actually issues.

**A31.** The `level: None` rule for `kube-system` ConfigMaps must come **before** the catch-all `level: Metadata`. Since the first match wins and the catch-all matches everything, any ordering with the catch-all above the drop rule reduces the entire policy to "log everything at Metadata" and silently fails requirement 4 — while still looking like a three-rule policy that mentions kube-system.

Proof that the drop is live (the third command above): generate the traffic, then count matching events. A non-zero count means the rule is unreachable. The `wc -l` returning `0` after a *deliberate* `kubectl -n kube-system get configmaps` is the whole verification — counting zero without first generating the traffic proves nothing.

</details>

---

## References

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes Documentation, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes API Reference, *Audit Configuration (`audit.k8s.io/v1`)* — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes Documentation, *kube-apiserver command-line reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes Documentation, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes Documentation, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Documentation, *User impersonation* — https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- Kubernetes Documentation, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes Documentation, *Debugging Kubernetes Nodes With Crictl* — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/