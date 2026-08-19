# Topic 4.1 — GitOps Security & Observability

## Guided Exercises

> **What you build.** A `kind` cluster with API-server audit logging enabled, running **both** Flux and Argo CD, plus Kyverno and a Prometheus stack. On top of it you exercise the seven security and observability controls that a production GitOps platform must have: least-privilege reconciliation, encrypted secrets, supply-chain verification, admission policy, drift detection, reconciliation telemetry, and incident response.
>
> **Why these are *security* exercises and not just operations.** The four OpenGitOps principles — declarative, versioned & immutable, pulled automatically, continuously reconciled ([opengitops.dev](https://opengitops.dev/)) — each buy you a security property, and each one fails in a specific way:
>
> | Principle | Security property it buys | How it fails |
> |---|---|---|
> | Declarative | The desired state is auditable text, not a side effect of a script | Templating/`ignoreDifferences` hides the real state |
> | Versioned & immutable | Every change has an author, a timestamp and a signature | Unsigned commits, force-push, mutable tags |
> | Pulled automatically | No CI credential ever holds cluster admin | The reconciler itself becomes cluster admin |
> | Continuously reconciled | Out-of-band changes are detected and reverted | Reconciliation suspended, degraded, or unmonitored |
>
> The right-hand column *is* the syllabus for this topic.
>
> **Time:** ~4 hours. **Cost:** zero (all local; `ttl.sh` is a free anonymous ephemeral registry).

---

## Exercise 0 — Build the lab (with an audit trail from minute one)

You enable API-server audit logging *now*, because Exercise 5 asks "who changed this outside Git?" and that question cannot be answered retroactively.

### Steps

1. Verify tooling. Install anything missing before continuing.

```bash
for b in kind kubectl helm flux argocd sops age age-keygen cosign jq; do
  printf '%-12s %s\n' "$b" "$(command -v "$b" || echo 'MISSING')"
done
```

2. Create a working directory and the audit policy the API server will load.

```bash
mkdir -p ~/gitops-sec && cd ~/gitops-sec
cat > audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
# The RequestReceived stage doubles every event for no analytical value.
omitStages:
  - RequestReceived
rules:
  # Control-plane chatter would drown the signal we care about.
  - level: None
    users:
      - system:kube-scheduler
      - system:kube-controller-manager
      - system:apiserver
  - level: None
    userGroups: ["system:nodes"]
  # Reads are noise for change attribution.
  - level: None
    verbs: ["get", "list", "watch"]
  # Full request+response for the objects a GitOps attacker cares about.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "serviceaccounts"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  # Everything else that mutates: who, what, when.
  - level: Metadata
EOF
```

3. Create the cluster with the policy mounted into the control-plane node.

```bash
cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: gitops-sec
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxage: "2"
            audit-log-maxbackup: "2"
          extraVolumes:
            - name: audit-policies
              hostPath: /etc/kubernetes/policies
              mountPath: /etc/kubernetes/policies
              readOnly: true
              pathType: DirectoryOrCreate
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
EOF

kind create cluster --config kind-config.yaml
kubectl cluster-info --context kind-gitops-sec
```

4. Confirm the audit log is actually being written. If this file is empty, stop and fix it — Exercise 5 depends on it.

```bash
docker exec gitops-sec-control-plane sh -c 'wc -l /var/log/kubernetes/audit.log'
```

Expected (line count will differ):

```
1834 /var/log/kubernetes/audit.log
```

5. Install Flux (no bootstrap — this lab drives Flux from OCI artifacts, so no hosted Git repository is required).

```bash
flux check --pre
flux install
flux check
```

Representative tail of `flux check`:

```
► checking prerequisites
✔ Kubernetes 1.31.2 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.4.0
✔ bootstrapped: false
► checking controllers
✔ helm-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
► checking crds
✔ all checks passed
```

6. Install Argo CD and log in with the CLI.

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &
sleep 3
ARGO_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGO_PW" --insecure
```

7. Install Kyverno and the Prometheus stack.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
```

The three `...NilUsesHelmValues=false` flags matter: by default the Prometheus Operator only discovers `PodMonitor`/`ServiceMonitor`/`PrometheusRule` objects carrying the chart's own release label. Every monitor you write in Exercise 6 would be silently ignored.

8. Sanity check.

```bash
kubectl get pods -A --field-selector=status.phase!=Running
```

An empty result (or only `Completed` jobs) means the lab is up.

### Checkpoint questions — block 0

- **Q0.1** — The audit policy sets `level: None` for `get`, `list` and `watch`. Name one GitOps-relevant attack this blinds you to, and state what you would change to catch it.
- **Q0.2** — Why is `RequestResponse` used for `secrets` but only `Metadata` for the catch-all rule? What is the risk of `RequestResponse` on secrets?
- **Q0.3** — This lab installs Flux with `flux install` rather than `flux bootstrap`. Which OpenGitOps principle is *not* satisfied by `flux install` alone, and what does bootstrap add?

---

## Exercise 1 — Least privilege: the reconciler is the most powerful identity in the cluster

In a pull-based GitOps setup nobody holds cluster credentials in CI — but the agent in the cluster holds them permanently. By default `kustomize-controller` runs as `system:serviceaccount:flux-system:kustomize-controller`, bound to `cluster-admin`. That means **anyone with merge rights on any watched path has cluster-admin**, transitively. The fix is *impersonation*: the controller applies each `Kustomization` as a ServiceAccount you choose.

### Steps

1. Confirm the default blast radius.

```bash
kubectl get clusterrolebinding cluster-reconciler-flux-system \
  -o jsonpath='{.roleRef.name}{"\n"}{range .subjects[*]}{.namespace}/{.name}{"\n"}{end}'
```

Expected:

```
cluster-admin
flux-system/kustomize-controller
flux-system/helm-controller
```

2. Create a tenant namespace with a deliberately narrow ServiceAccount.

```bash
kubectl create namespace tenant-a

cat > tenant-a-rbac.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["configmaps", "services", "deployments", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-reconciler
  namespace: tenant-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant-a-reconciler
subjects:
  - kind: ServiceAccount
    name: tenant-a-reconciler
    namespace: tenant-a
EOF

kubectl apply -f tenant-a-rbac.yaml
```

3. Enumerate exactly what that identity can do. This command, not the YAML, is the authoritative answer.

```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler -n tenant-a
```

Representative output (trimmed):

```
Resources                    Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io  []     []               [create]
configmaps                   []                  []               [get list watch create update patch delete]
services                     []                  []               [get list watch create update patch delete]
deployments.apps             []                  []               [get list watch create update patch delete]
ingresses.networking.k8s.io  []                  []               [get list watch create update patch delete]
```

4. Prove the negative — the identity must *not* be able to escalate:

```bash
kubectl auth can-i create clusterrolebindings \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler
kubectl auth can-i get secrets -n tenant-a \
  --as=system:serviceaccount:tenant-a:tenant-a-reconciler
```

Both must print `no`.

5. Build a tenant payload containing one legitimate resource and one privilege-escalation attempt, and push it as an OCI artifact. (Using OCI here keeps the lab self-contained; a `GitRepository` behaves identically.)

```bash
mkdir -p tenant-a-config
cat > tenant-a-config/app.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: tenant-a
  labels:
    app: podinfo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          ports:
            - name: http
              containerPort: 9898
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { memory: 64Mi }
EOF

# The escalation attempt: a tenant granting itself cluster-admin.
cat > tenant-a-config/escalate.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tenant-a-owns-the-cluster
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: tenant-a-reconciler
    namespace: tenant-a
EOF

REPO="ttl.sh/gitops-sec-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
echo "REPO=$REPO" | tee repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config \
  --source="lab" \
  --revision="v1/$(date +%s)"
```

6. Wire it up **with impersonation** and watch the escalation fail.

```bash
source repo.env
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  url: oci://${REPO}/tenant-a
  ref:
    tag: v1
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  retryInterval: 30s
  prune: true
  sourceRef:
    kind: OCIRepository
    name: tenant-a
  path: ./
  targetNamespace: tenant-a
  serviceAccountName: tenant-a-reconciler   # <-- the whole point
EOF

sleep 20
flux get kustomizations -n tenant-a
```

Expected:

```
NAME      REVISION   SUSPENDED  READY  MESSAGE
tenant-a             False      False  Kustomization/tenant-a/tenant-a dry-run failed: clusterrolebindings.rbac.authorization.k8s.io "tenant-a-owns-the-cluster" is forbidden: User "system:serviceaccount:tenant-a:tenant-a-reconciler" cannot create resource "clusterrolebindings" in API group "rbac.authorization.k8s.io" at the cluster scope
```

Note **`dry-run failed`**: kustomize-controller server-side dry-runs the whole set before applying. The apply is atomic in intent — the legitimate Deployment is *not* created either.

7. Remove the escalation and confirm the tenant reconciles cleanly.

```bash
rm tenant-a-config/escalate.yaml
source repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config --source="lab" --revision="v2/$(date +%s)"
flux reconcile kustomization tenant-a -n tenant-a --with-source
kubectl -n tenant-a get deploy podinfo
```

8. Make impersonation the default, so a forgotten `serviceAccountName` fails closed instead of open:

```bash
kubectl -n flux-system patch deployment kustomize-controller --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-",
   "value":"--default-service-account=flux-default"}
]'
kubectl -n flux-system rollout status deploy/kustomize-controller
```

Now any `Kustomization` without an explicit `serviceAccountName` is applied as `flux-default` in its own namespace — a ServiceAccount that does not exist, so it is denied everything.

9. Do the equivalent on the Argo CD side with an `AppProject` — Argo CD's tenancy and blast-radius boundary.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-b
  namespace: argocd
spec:
  description: Tenant B — namespaced workloads only
  sourceRepos:
    - https://github.com/argoproj/argocd-example-apps.git
  destinations:
    - namespace: tenant-b
      server: https://kubernetes.default.svc
  # Empty whitelist => no cluster-scoped resource may ever be created.
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: Role
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: deployer
      description: May sync, may not delete or edit the Application
      policies:
        - p, proj:tenant-b:deployer, applications, get, tenant-b/*, allow
        - p, proj:tenant-b:deployer, applications, sync, tenant-b/*, allow
        - p, proj:tenant-b:deployer, applications, delete, tenant-b/*, deny
      groups:
        - my-org:tenant-b-devs
EOF
```

10. Configure the global RBAC policy and test it without a browser.

```bash
kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p '{
  "data": {
    "policy.default": "role:readonly",
    "scopes": "[groups, email]",
    "policy.csv": "p, role:tenant-b-dev, applications, sync, tenant-b/*, allow\np, role:tenant-b-dev, applications, get, tenant-b/*, allow\np, role:tenant-b-dev, applications, delete, */*, deny\ng, my-org:tenant-b-devs, role:tenant-b-dev\n"
  }
}'

argocd account can-i sync applications 'tenant-b/guestbook'
argocd account can-i delete applications 'tenant-b/guestbook'
```

(As `admin` both return `yes` — admin bypasses `policy.csv`. The point of the exercise is step 11.)

11. Verify the policy *as the tenant*, not as admin. Argo CD ships a linter for exactly this:

```bash
kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' > policy.csv
argocd admin settings rbac can my-org:tenant-b-devs sync applications 'tenant-b/guestbook' --policy-file policy.csv
argocd admin settings rbac can my-org:tenant-b-devs delete applications 'tenant-b/guestbook' --policy-file policy.csv
argocd admin settings rbac validate --policy-file policy.csv
```

Expected:

```
Yes
No
Policy is valid.
```

### Checkpoint questions — block 1

- **Q1.1** — In step 6 the escalation failed with `dry-run failed`. Explain why the compliant `Deployment` in the same artifact was *also* not applied, and why that behaviour is desirable for security.
- **Q1.2** — A colleague argues that impersonation is unnecessary because "only reviewers can merge to `main`". Give two concrete ways cluster-admin is still reachable in that model.
- **Q1.3** — `--default-service-account=flux-default` points at a ServiceAccount that does not exist. Why is a *non-existent* SA a better default than a read-only one?
- **Q1.4** — `clusterResourceWhitelist: []` and `namespaceResourceBlacklist` both appear in the `AppProject`. Which of the two is fail-closed, and what does that imply about which one you should rely on for a hostile tenant?
- **Q1.5** — Why does `argocd account can-i` as `admin` fail to prove anything about the tenant's permissions, and which command actually proves it?

---

## Exercise 2 — Secrets: the one thing that must never be plaintext in Git

Git is a replicated, permanent, widely-mirrored log. A secret committed once is compromised even after a force-push, because it survives in every clone, every CI cache, and every mirror. GitOps therefore needs a scheme where the *ciphertext* is the declarative artifact. You will implement SOPS + age with Flux, then compare it against the two other mainstream patterns.

### Steps

1. Generate an age key pair and load the **private** key into the cluster.

```bash
cd ~/gitops-sec
age-keygen -o age.agekey
export AGE_PUB=$(grep -oP 'public key: \K(.*)' age.agekey)
echo "$AGE_PUB"

kubectl -n tenant-a create secret generic sops-age \
  --from-file=age.agekey=./age.agekey
```

The file name inside the Secret matters: kustomize-controller looks for keys with the `.agekey` suffix.

2. Declare an encryption rule so nobody has to remember flags.

```bash
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: '^(data|stringData)$'
    age: ${AGE_PUB}
EOF
```

`encrypted_regex` is the key line: it encrypts *values only*, leaving `apiVersion`, `kind`, `metadata` and `type` in cleartext. The diff of a rotated secret then stays reviewable, and `kubectl`-shaped tooling can still parse the file.

3. Author the secret and encrypt it in place.

```bash
cat > tenant-a-config/db-credentials.sops.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: tenant-a
type: Opaque
stringData:
  username: podinfo
  password: "c0rrect-h0rse-battery-staple"
  dsn: "postgres://podinfo:c0rrect-h0rse-battery-staple@db.tenant-a.svc:5432/app"
EOF

sops --encrypt --in-place tenant-a-config/db-credentials.sops.yaml
head -20 tenant-a-config/db-credentials.sops.yaml
```

Representative output:

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: db-credentials
    namespace: tenant-a
type: Opaque
stringData:
    username: ENC[AES256_GCM,data:vQ9lZg==,iv:9pB...,tag:1kQ...,type:str]
    password: ENC[AES256_GCM,data:xR2m...,iv:Uk7...,tag:Hh4...,type:str]
    dsn: ENC[AES256_GCM,data:Lp8t...,iv:aQ0...,tag:9dZ...,type:str]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
    lastmodified: "2026-08-18T14:02:11Z"
    mac: ENC[AES256_GCM,data:...]
    version: 3.9.1
```

4. Prove the plaintext is gone from the file before it ever reaches a remote:

```bash
grep -c 'battery-staple' tenant-a-config/db-credentials.sops.yaml || echo "clean"
```

Must print `clean` (grep exits 1 with zero matches).

5. Tell the `Kustomization` how to decrypt, and republish.

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge -p '{
  "spec": {"decryption": {"provider": "sops", "secretRef": {"name": "sops-age"}}}
}'

source repo.env
flux push artifact "oci://${REPO}/tenant-a:v1" \
  --path=./tenant-a-config --source="lab" --revision="v3/$(date +%s)"
flux reconcile kustomization tenant-a -n tenant-a --with-source
```

6. Verify decryption happened in-cluster:

```bash
kubectl -n tenant-a get secret db-credentials \
  -o jsonpath='{.data.username}' | base64 -d; echo
```

Expected: `podinfo`

7. Now the check most teams skip — **did the plaintext leak into logs or events?**

```bash
kubectl -n flux-system logs deploy/kustomize-controller --tail=500 \
  | grep -i 'battery-staple' || echo "no plaintext in controller logs"

kubectl -n tenant-a get events --field-selector involvedObject.kind=Kustomization \
  -o json | grep -i 'battery-staple' || echo "no plaintext in events"

kubectl -n tenant-a get kustomization tenant-a -o yaml \
  | grep -i 'battery-staple' || echo "no plaintext in status"
```

8. Observe the failure mode. Break decryption and read the error carefully:

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge \
  -p '{"spec":{"decryption":{"secretRef":{"name":"sops-age-wrong"}}}}'
flux reconcile kustomization tenant-a -n tenant-a
flux get kustomizations -n tenant-a
```

Representative:

```
NAME      REVISION       SUSPENDED  READY  MESSAGE
tenant-a  v3/1755523... False      False  decryption failed: cannot get decryption Secret 'tenant-a/sops-age-wrong': Secret "sops-age-wrong" not found
```

Restore it:

```bash
kubectl -n tenant-a patch kustomization tenant-a --type merge \
  -p '{"spec":{"decryption":{"secretRef":{"name":"sops-age"}}}}'
flux reconcile kustomization tenant-a -n tenant-a
```

9. Rotate the *value* and confirm the diff is legible:

```bash
cp tenant-a-config/db-credentials.sops.yaml /tmp/before.yaml
sops set tenant-a-config/db-credentials.sops.yaml '["stringData"]["password"]' '"n3w-r0tated-secret"'
diff <(grep -E '^(apiVersion|kind|type)|^    (name|namespace):' /tmp/before.yaml) \
     <(grep -E '^(apiVersion|kind|type)|^    (name|namespace):' tenant-a-config/db-credentials.sops.yaml) \
  && echo "structure unchanged; only ciphertext moved"
```

10. Compare the three mainstream patterns. Read the table, then answer Q2.4.

| | **SOPS (+age/KMS)** | **Sealed Secrets** | **External Secrets Operator** |
|---|---|---|---|
| What is in Git | Ciphertext of the real secret | Ciphertext, bound to *this* cluster's controller key | A *reference* — no secret material at all |
| Decryption happens | In kustomize-controller | In the sealed-secrets controller | Never; ESO fetches from Vault/ASM/GSM |
| Works offline / air-gapped | Yes (age) | Yes | No — depends on the external store reachability |
| Rotation of the data key | Re-encrypt every file (`sops updatekeys`) | Controller re-seals; existing sealed secrets keep working | Free — rotate in the store, ESO re-syncs |
| Blast radius if Git leaks | Ciphertext only | Ciphertext only | Nothing |
| Blast radius if the cluster is compromised | All secrets that cluster can decrypt | Same | Same, plus the store credentials |
| Disaster recovery | Need the age/KMS key | Need the controller's private key backup — a classic outage cause | Rebuild cluster, secrets re-sync automatically |
| Audit of secret *access* | None (it is a file read) | None | Yes — the external store logs every read |
| Cost / dependency | Zero | Zero | Runs and pays for a secret manager |

11. Cleanup guard — never let the private key reach the repo:

```bash
cat >> .gitignore <<'EOF'
*.agekey
age.agekey
EOF
```

### Checkpoint questions — block 2

- **Q2.1** — `encrypted_regex: '^(data|stringData)$'` leaves `metadata.name` and `metadata.namespace` readable. State one security benefit and one information-disclosure risk of that choice.
- **Q2.2** — Step 7 greps controller logs, events *and* `.status`. Why is checking only the logs insufficient, and which Flux field is the historical hazard here?
- **Q2.3** — The cluster holds the age private key as a plain `Secret` in `tenant-a`. Who can read it, and what single RBAC check would you run to find out? Why does this make SOPS-in-cluster weaker than it looks?
- **Q2.4** — A regulated customer requires an audit record of *every read* of a production database password. Which of the three patterns in the table can satisfy that, and why can the other two not?
- **Q2.5** — Sealed Secrets encrypts against a controller key that is per-cluster. Explain why this makes cluster rebuild a security *and* availability incident, and what the corresponding SOPS failure mode is.

---

## Exercise 3 — Supply chain: verify the artifact, not just the URL

An `OCIRepository` pointing at `ttl.sh/whatever:latest` trusts (a) the registry, (b) DNS, (c) whoever can push that tag. Tags are mutable. Verification with Sigstore turns "I fetched from a place" into "I fetched a thing that a specific identity signed".

### Steps

1. Generate a cosign key pair (keyless is the production answer; keys keep the lab offline and deterministic).

```bash
cd ~/gitops-sec
COSIGN_PASSWORD="" cosign generate-key-pair
ls cosign.key cosign.pub
```

2. Push a fresh artifact and capture its immutable digest.

```bash
source repo.env
flux push artifact "oci://${REPO}/tenant-a:v2" \
  --path=./tenant-a-config --source="lab" --revision="v4/$(date +%s)" \
  --output json | tee push.json
DIGEST=$(jq -r '.digest' push.json)
echo "DIGEST=$DIGEST" | tee -a repo.env
```

3. Sign the artifact **by digest**, never by tag.

```bash
source repo.env
COSIGN_PASSWORD="" cosign sign --key cosign.key --yes "${REPO}/tenant-a@${DIGEST}"
cosign verify --key cosign.pub "${REPO}/tenant-a@${DIGEST}" | jq '.[0].critical'
```

Representative:

```json
{
  "identity": { "docker-reference": "ttl.sh/gitops-sec-4f2a1c9b/tenant-a" },
  "image": { "docker-manifest-digest": "sha256:9c1f...b3e2" },
  "type": "cosign container image signature"
}
```

4. Load the **public** key into the cluster and make Flux enforce verification.

```bash
kubectl -n tenant-a create secret generic cosign-pub --from-file=cosign.pub=./cosign.pub

source repo.env
cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: tenant-a
  namespace: tenant-a
spec:
  interval: 1m
  url: oci://${REPO}/tenant-a
  ref:
    tag: v2
  verify:
    provider: cosign
    secretRef:
      name: cosign-pub
EOF

sleep 15
flux get sources oci -n tenant-a
```

Expected:

```
NAME      REVISION            SUSPENDED  READY  MESSAGE
tenant-a  v2@sha256:9c1f...   False      True   stored artifact for digest 'v2@sha256:9c1f...'
```

And the verification condition:

```bash
kubectl -n tenant-a get ocirepository tenant-a \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} :: {.message}{"\n"}{end}'
```

```
Ready=True :: stored artifact for digest 'v2@sha256:9c1f...b3e2'
ArtifactInStorage=True :: stored artifact for digest 'v2@sha256:9c1f...b3e2'
SourceVerified=True :: verified signature of revision v2@sha256:9c1f...b3e2
```

5. Now simulate a tag hijack — push *unsigned* content over the same tag.

```bash
source repo.env
echo '# injected by an attacker who can push to the registry' >> tenant-a-config/app.yaml
flux push artifact "oci://${REPO}/tenant-a:v2" \
  --path=./tenant-a-config --source="lab" --revision="evil/$(date +%s)"
flux reconcile source oci tenant-a -n tenant-a
flux get sources oci -n tenant-a
```

Expected:

```
NAME      REVISION  SUSPENDED  READY  MESSAGE
tenant-a            False      False  failed to verify the signature using provider 'cosign': no matching signatures were found for 'ttl.sh/gitops-sec-4f2a1c9b/tenant-a'
```

The `Kustomization` keeps running against the last **verified** artifact. Verification failure is fail-closed at the source, not at apply time.

6. Pin by digest so even a signed-but-wrong tag cannot move under you:

```bash
source repo.env
kubectl -n tenant-a patch ocirepository tenant-a --type merge -p "{
  \"spec\": {\"ref\": {\"digest\": \"${DIGEST}\"}}
}"
flux reconcile source oci tenant-a -n tenant-a
flux get sources oci -n tenant-a
```

7. The production shape — keyless identity binding. Do not apply this (it needs a real OIDC-issued signature); read it and answer Q3.4.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/my-org/platform-config
  ref:
    semver: ">=1.0.0 <2.0.0"
  verify:
    provider: cosign
    matchOIDCIdentity:
      # Anchored regexes. An unanchored `subject` is a common, silent bypass.
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/my-org/platform-config/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

8. Close the second half of the supply chain: Flux verified the *config*; nothing yet verifies the *container images* the config references. Add a Kyverno image-verification policy.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-tenant-images
spec:
  webhookTimeoutSeconds: 25
  failurePolicy: Fail
  rules:
    - name: verify-signed-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a]
      verifyImages:
        - imageReferences:
            - "ghcr.io/stefanprodan/podinfo*"
          mutateDigest: true      # rewrite tag -> digest on admission
          required: true
          verifyDigest: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/stefanprodan/podinfo/.github/workflows/release.yml@refs/tags/*"
                    rekor:
                      url: https://rekor.sigstore.dev
EOF
```

9. Observe the outcome and the *cost* of this control:

```bash
kubectl -n tenant-a rollout restart deploy/podinfo
sleep 20
kubectl -n tenant-a get pods
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n tenant-a get pod -l app=podinfo -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

If the lab has egress to `rekor.sigstore.dev` and the signature matches, the Pod runs and its image reference has been **mutated to a digest** while the Deployment still says `:6.7.1`. If egress is blocked you will instead see admission fail:

```
Error creating: admission webhook "mutate.kyverno.svc-fail" denied the request:
failed to verify image ghcr.io/stefanprodan/podinfo:6.7.1: .../rekor.sigstore.dev: dial tcp: i/o timeout
```

That failure is not a bug — it is `failurePolicy: Fail` doing its job, and it is the trade-off you must be able to articulate.

### Checkpoint questions — block 3

- **Q3.1** — Step 3 signs `@sha256:...` rather than `:v2`. Explain precisely what an attacker with push access to the registry can do if you sign and verify by tag.
- **Q3.2** — In step 5 verification failed, yet `kubectl -n tenant-a get deploy podinfo` still shows a healthy Deployment. Which GitOps principle explains that, and is it the correct behaviour?
- **Q3.3** — Flux verified the artifact and Kyverno verified the image. Name a third supply-chain artifact still unverified in this lab and the mechanism that would cover it.
- **Q3.4** — The `matchOIDCIdentity.subject` regex in step 7 is anchored with `^...$`. Write the exploit that becomes possible with the unanchored `"https://github.com/my-org/"` instead.
- **Q3.5** — `mutateDigest: true` rewrites tag to digest on admission. Give one security benefit and one operational consequence for a team that relies on `imagePullPolicy: Always` with a floating tag.
- **Q3.6** — `failurePolicy: Fail` on a policy that calls out to `rekor.sigstore.dev` couples cluster admission to internet reachability. State the availability risk and one production mitigation that keeps the security property.

---

## Exercise 4 — Policy as code: two gates, not one

A common misconception is that "everything goes through Git, so review is the control". Review is *a* control; it is not an enforcing one. Admission control is enforcing. You need both, and — this is the exam-relevant part — you need to know which threats each one covers.

### Steps

1. Write a baseline hardening policy in `Audit` first. Never ship a new policy in `Enforce`.

```bash
cat > policy-baseline.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-baseline
  annotations:
    policies.kyverno.io/title: Tenant workload baseline
    policies.kyverno.io/severity: high
spec:
  background: true
  rules:
    - name: no-privileged-containers
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit          # Kyverno >= 1.13; older: spec.validationFailureAction
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  =(allowPrivilegeEscalation): "false"
    - name: no-host-namespaces
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit
        message: "hostNetwork, hostPID and hostIPC are not allowed."
        pattern:
          spec:
            =(hostNetwork): "false"
            =(hostPID): "false"
            =(hostIPC): "false"
    - name: allowed-registries-only
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [tenant-a, tenant-b]
      validate:
        failureAction: Audit
        message: "Images must come from ghcr.io/stefanprodan or the internal registry."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotEquals
                    value: "ghcr.io/stefanprodan/*"
EOF
kubectl apply -f policy-baseline.yaml
```

2. Deploy a deliberately non-compliant workload and read the *report* rather than an error.

```bash
cat > bad-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  namespace: tenant-a
spec:
  hostNetwork: true
  hostPID: true
  containers:
    - name: shell
      image: docker.io/library/busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
EOF
kubectl apply -f bad-pod.yaml

sleep 5
kubectl -n tenant-a get policyreport -o wide
kubectl -n tenant-a get policyreport -o json \
  | jq -r '.items[].results[] | select(.result=="fail") | "\(.policy)/\(.rule): \(.message)"'
```

Representative:

```
tenant-baseline/no-privileged-containers: validation error: Privileged containers are not allowed. rule no-privileged-containers failed at path /spec/containers/0/securityContext/privileged/
tenant-baseline/no-host-namespaces: validation error: hostNetwork, hostPID and hostIPC are not allowed. rule no-host-namespaces failed at path /spec/hostNetwork/
tenant-baseline/allowed-registries-only: Images must come from ghcr.io/stefanprodan or the internal registry.
```

This is the correct rollout order: measure the violation rate against real traffic **before** you can break anyone.

3. Promote to `Enforce` and confirm the gate closes.

```bash
kubectl delete pod intruder -n tenant-a
sed -i 's/failureAction: Audit/failureAction: Enforce/g' policy-baseline.yaml
kubectl apply -f policy-baseline.yaml
sleep 5
kubectl apply -f bad-pod.yaml
```

Expected:

```
Error from server: error when creating "bad-pod.yaml": admission webhook "validate.kyverno.svc-fail"
denied the request:

resource Pod/tenant-a/intruder was blocked due to the following policies

tenant-baseline:
  no-privileged-containers: 'validation error: Privileged containers are not allowed. ...'
  no-host-namespaces: 'validation error: hostNetwork, hostPID and hostIPC are not allowed. ...'
```

4. Shift the same policy left, so the developer sees it in CI instead of at 3 a.m.

```bash
kubectl krew install kyverno 2>/dev/null || echo "install the kyverno CLI: https://kyverno.io/docs/kyverno-cli/"
kyverno apply policy-baseline.yaml --resource bad-pod.yaml
kyverno apply policy-baseline.yaml --resource tenant-a-config/app.yaml
```

Representative:

```
Applying 3 policy rule(s) to 1 resource(s)...

policy tenant-baseline -> resource tenant-a/Pod/intruder failed:
1. no-privileged-containers: validation error: Privileged containers are not allowed.
2. no-host-namespaces: validation error: hostNetwork, hostPID and hostIPC are not allowed.

pass: 0, fail: 2, warn: 0, error: 0, skip: 1
```

5. Wire it as a merge gate (this is the artifact the exam expects you to be able to describe):

```yaml
# .github/workflows/policy.yaml
name: policy
on:
  pull_request:
    paths: ["clusters/**", "tenants/**"]
permissions:
  contents: read          # the CI job needs NO cluster credential — that is the point
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Render manifests
        run: kustomize build tenants/tenant-a > /tmp/rendered.yaml
      - name: Schema validation
        run: kubeconform -strict -summary -schema-location default /tmp/rendered.yaml
      - name: Policy validation
        run: kyverno apply policies/ --resource /tmp/rendered.yaml --detailed-results
```

6. Demonstrate why the Git gate alone is not sufficient. Bypass Git entirely:

```bash
kubectl -n tenant-a set image deploy/podinfo podinfo=docker.io/library/nginx:1.27
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

The image changed. No pull request, no review, no CI. Note also that the Kyverno *registry* rule matched `Pod`, so the `Deployment` edit passed and only the resulting Pod is evaluated.

### Checkpoint questions — block 4

- **Q4.1** — Step 6 changed a running workload with no Git involvement. Which *two* controls in this lab are capable of noticing, and which one is capable of *undoing* it?
- **Q4.2** — The policy matches `kinds: [Pod]`. Explain why the `Deployment` edit in step 6 produced a confusing result, and what you would change to give the developer a good error message.
- **Q4.3** — Step 1 ships in `Audit`, step 3 promotes to `Enforce`. Describe the specific production incident that the reverse order causes on a cluster with existing workloads.
- **Q4.4** — The CI workflow declares `permissions: contents: read`. Relate that single line to the pull-vs-push security argument for GitOps.
- **Q4.5** — Give one class of violation that CI-side `kyverno apply` can catch but the admission webhook cannot, and one the webhook catches that CI structurally cannot.

---

## Exercise 5 — Drift detection and self-healing, and attributing the drift

Continuous reconciliation is the control that converts "someone changed production" from a permanent compromise into a bounded window. Here you measure that window and then attribute the change using the audit log you enabled in Exercise 0.

### Steps

1. Deploy an Argo CD `Application` with self-heal deliberately **off**, so you can see the un-healed state first.

```bash
kubectl create namespace tenant-b
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: tenant-b
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF

argocd app wait guestbook --health --timeout 180
argocd app get guestbook
```

2. Introduce drift and observe detection without correction.

```bash
kubectl -n tenant-b scale deploy guestbook-ui --replicas=5
sleep 15
argocd app get guestbook | head -20
argocd app diff guestbook || true
```

Representative:

```
Name:               argocd/guestbook
Project:            tenant-b
Sync Status:        OutOfSync from HEAD (53e28ff)
Health Status:      Healthy
```

```diff
===== apps/Deployment tenant-b/guestbook-ui ======
26c26
<   replicas: 5
---
>   replicas: 1
```

Detected in seconds. Corrected: never. `OutOfSync` alone is a *dashboard*, not a control.

3. Turn on self-heal and measure the correction window.

```bash
argocd app set guestbook --self-heal --auto-prune

kubectl -n tenant-b scale deploy guestbook-ui --replicas=7
date -u +%H:%M:%S
watch -n 1 'kubectl -n tenant-b get deploy guestbook-ui -o jsonpath="{.spec.replicas}"; echo'
```

The value returns to `1`. Note the elapsed time — that is your drift window, and it is bounded by the reconciliation interval plus the controller queue, not by any alert.

4. Do the same on the Flux side and observe the sharper failure mode:

```bash
kubectl -n tenant-a set image deploy/podinfo podinfo=docker.io/library/nginx:1.27
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
flux reconcile kustomization tenant-a -n tenant-a
kubectl -n tenant-a get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Flux reverts because kustomize-controller uses server-side apply with itself as field manager: the drifted field is owned by Flux, so the next apply takes it back.

5. Now demonstrate the *anti*-pattern. Suppress the drift and watch the control silently disappear:

```bash
argocd app set guestbook --ignore-normal-diffs 2>/dev/null || true
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: tenant-b
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: tenant-b
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
        - /spec/template/spec/containers/0/image   # <-- this is the dangerous one
EOF

kubectl -n tenant-b set image deploy/guestbook-ui guestbook-ui=docker.io/library/nginx:1.27
sleep 40
argocd app get guestbook | grep 'Sync Status'
kubectl -n tenant-b get deploy guestbook-ui -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

`Synced`, and the image is `nginx`. You have a green dashboard over a compromised workload. `ignoreDifferences` on `/spec/replicas` is legitimate when an HPA owns that field; on `image` it is a supply-chain hole with a friendly name.

6. Revert the anti-pattern:

```bash
kubectl -n argocd patch application guestbook --type json \
  -p='[{"op":"remove","path":"/spec/ignoreDifferences"}]'
argocd app sync guestbook
```

7. Attribute the drift. This is the question an incident review actually asks:

```bash
docker exec gitops-sec-control-plane sh -c \
  'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.objectRef.resource=="deployments"
           and (.verb=="patch" or .verb=="update")
           and .objectRef.name=="guestbook-ui")
           | "\(.requestReceivedTimestamp)  \(.verb)  \(.user.username)  \(.userAgent // "-")"' \
  | tail -20
```

Representative:

```
2026-08-18T14:41:02.118Z  patch   kubernetes-admin        kubectl/v1.31.2 (linux/amd64)
2026-08-18T14:41:44.905Z  update  system:serviceaccount:argocd:argocd-application-controller  argocd-application-controller/v0.0.0
```

Two lines, two stories: a human with `kubectl` made the change; the controller took it back 42 seconds later. That is the drift window, measured, with the actor named.

8. Build the reusable query — "every mutation of a GitOps-managed resource that did **not** come from a reconciler":

```bash
docker exec gitops-sec-control-plane sh -c 'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.verb | test("^(create|update|patch|delete)$"))
           | select(.user.username | test("argocd|flux|kyverno|system:") | not)
           | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.resource)/\(.objectRef.name)"' \
  | sort | tail -30
```

In production this query lives in your log pipeline as a standing alert, not in a shell.

### Checkpoint questions — block 5

- **Q5.1** — In step 2 the app was `OutOfSync` *and* `Healthy` simultaneously. Explain the difference between the two statuses and why alerting on `Healthy` alone is a security gap.
- **Q5.2** — Step 5 produced `Synced` while running the wrong image. Write the rule you would apply when reviewing a PR that adds an `ignoreDifferences` entry.
- **Q5.3** — Self-heal reverts drift automatically. Name one scenario where automatic reversion makes an incident *worse*, and the mechanism GitOps tools give you to pause it deliberately.
- **Q5.4** — Flux reverted the drift in step 4 because of server-side apply field ownership. What happens to a field that Flux does *not* manage (say, an annotation added by a mutating webhook), and why is that the correct design?
- **Q5.5** — Why can the Git history alone not answer "who changed the running Deployment at 14:41?", and what is the minimum additional data source required?

---

## Exercise 6 — Observability: what "reconciliation is healthy" actually means

You cannot alert on "GitOps is working" without deciding what the failure looks like. The two mistakes are alerting on the wrong signal (`Ready=False`, which fires on every transient network blip) and forgetting the *silent* failures: a suspended `Kustomization` and a stale-but-successful reconciliation are both invisible to a naive query.

### Steps

1. Scrape the Flux controllers by hand to learn the metric shapes before writing any rule.

```bash
kubectl -n flux-system port-forward deploy/kustomize-controller 8081:8080 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8081/metrics | grep -E '^gotk_(reconcile_condition|suspend_status)' | head -20
```

Representative:

```
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="True"} 1
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="False"} 0
gotk_reconcile_condition{kind="Kustomization",name="tenant-a",namespace="tenant-a",type="Ready",status="Deleted"} 0
gotk_suspend_status{kind="Kustomization",name="tenant-a",namespace="tenant-a"} 0
```

The encoding is the important detail: **one time series per condition status**, each a 0/1 gauge. Rules must select on the `status` label, not on the value alone.

2. Do the same for Argo CD.

```bash
kubectl -n argocd port-forward svc/argocd-metrics 8082:8082 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8082/metrics | grep -E '^argocd_app_info' | head
curl -s localhost:8082/metrics | grep -E '^argocd_app_sync_total' | head
```

Representative:

```
argocd_app_info{dest_namespace="tenant-b",dest_server="https://kubernetes.default.svc",health_status="Healthy",name="guestbook",namespace="argocd",operation="",project="tenant-b",repo="https://github.com/argoproj/argocd-example-apps",sync_status="Synced"} 1
argocd_app_sync_total{dest_server="...",name="guestbook",namespace="argocd",phase="Succeeded",project="tenant-b"} 4
```

3. Register both with Prometheus.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: flux-system
  namespace: flux-system
spec:
  namespaceSelector:
    matchNames: [flux-system]
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - helm-controller
          - source-controller
          - kustomize-controller
          - notification-controller
  podMetricsEndpoints:
    - port: http-prom
      relabelings:
        - action: replace
          sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-server-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server-metrics
  endpoints:
    - port: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-repo-server-metrics
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  endpoints:
    - port: metrics
EOF
```

4. Confirm the targets are actually up — a `PodMonitor` that matches nothing fails silently.

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 4
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("controller|argocd"))
           | "\(.labels.job)\t\(.health)\t\(.lastError)"' | sort -u
```

Every row must read `up`.

5. Run the four queries that matter. Paste each into `localhost:9090/graph`.

```promql
# 1. Anything Flux-managed that is failing, ignoring resources you deliberately suspended.
max by (exported_namespace, name, kind) (
  gotk_reconcile_condition{status="False", type="Ready"}
)
* on (exported_namespace, name, kind) group_left
max by (exported_namespace, name, kind) (gotk_suspend_status == 0)
== 1
```

```promql
# 2. Silent failure #1 — suspended reconciliation. A suspended Kustomization is
#    NOT failing and NOT drifting: it has simply stopped enforcing anything.
gotk_suspend_status == 1
```

```promql
# 3. Argo CD applications out of sync or degraded.
sum by (name, project, dest_namespace) (
  argocd_app_info{sync_status!="Synced"}
) > 0
or
sum by (name, project, dest_namespace) (
  argocd_app_info{health_status=~"Degraded|Missing|Unknown"}
) > 0
```

```promql
# 4. Reconciliation latency — the p99 of how long an apply takes.
histogram_quantile(0.99,
  sum by (le, kind) (rate(gotk_reconcile_duration_seconds_bucket[10m]))
)
```

6. Turn queries 1–3 into alerts. Note the `for:` durations — they encode "transient vs. real".

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-alerts
  namespace: monitoring
spec:
  groups:
    - name: gitops.reconciliation
      rules:
        - alert: FluxReconciliationFailure
          expr: |
            max by (exported_namespace, name, kind) (
              gotk_reconcile_condition{status="False", type="Ready"}
            )
            * on (exported_namespace, name, kind) group_left
            max by (exported_namespace, name, kind) (gotk_suspend_status == 0)
            == 1
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.exported_namespace }}/{{ $labels.name }} has not reconciled for 10m"
            runbook: "flux get all -A --status-selector=ready=false"

        - alert: FluxReconciliationSuspended
          expr: gotk_suspend_status == 1
          for: 1h
          labels: { severity: warning }
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.name }} suspended >1h — drift is no longer corrected"

        - alert: ArgoAppOutOfSync
          expr: argocd_app_info{sync_status!="Synced"} == 1
          for: 15m
          labels: { severity: warning }
          annotations:
            summary: "Application {{ $labels.name }} out of sync for 15m — cluster state differs from Git"

        - alert: ArgoAppDegraded
          expr: argocd_app_info{health_status=~"Degraded|Missing"} == 1
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "Application {{ $labels.name }} is {{ $labels.health_status }}"

        - alert: GitOpsControllerAbsent
          expr: |
            absent(gotk_reconcile_condition{kind="Kustomization"})
            or absent(argocd_app_info)
          for: 10m
          labels: { severity: critical }
          annotations:
            summary: "GitOps telemetry has disappeared — the reconciler may be down or unmonitored"
EOF
```

7. Prove each alert fires. Do not trust a rule you have not seen go red.

```bash
# Trip FluxReconciliationFailure
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p '{"spec":{"url":"oci://ttl.sh/does-not-exist-4f2a/tenant-a"}}'

# Trip FluxReconciliationSuspended
flux suspend kustomization tenant-a -n tenant-a

sleep 90
curl -s localhost:9090/api/v1/alerts \
  | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.state)\t\(.labels.name // "-")"'
```

Representative:

```
FluxReconciliationFailure   pending   tenant-a
FluxReconciliationSuspended pending   tenant-a
```

(`pending` becomes `firing` after the `for:` duration elapses.)

8. Restore:

```bash
source repo.env
flux resume kustomization tenant-a -n tenant-a
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p "{\"spec\":{\"url\":\"oci://${REPO}/tenant-a\"}}"
flux reconcile kustomization tenant-a -n tenant-a --with-source
```

### Checkpoint questions — block 6

- **Q6.1** — Alert 1 multiplies by `gotk_suspend_status == 0`. What operational failure does that filter prevent, and what *new* blind spot does it create that alert 2 exists to cover?
- **Q6.2** — `GitOpsControllerAbsent` uses `absent()`. Explain why a rule based on `== 1` or `> 0` cannot detect a dead controller.
- **Q6.3** — `ArgoAppOutOfSync` has `for: 15m` while `ArgoAppDegraded` has `for: 5m`. Justify the asymmetry in terms of what each condition means.
- **Q6.4** — `argocd_app_info` carries `sync_status` as a **label**. Describe the cardinality and staleness problem that creates when an application's status flips repeatedly, and how it can produce a stuck alert.
- **Q6.5** — All the metrics here measure the *reconciler*. Name the end-to-end quantity they do **not** measure — the one a platform SLO should actually be written against — and sketch how you would measure it.

---

## Exercise 7 — Notifications, incident response and rollback

The last control is the human loop: a change fails, someone is told, and the remediation preserves Git as the source of truth.

### Steps

1. Stand up a webhook sink so notifications are observable locally.

```bash
kubectl create namespace tooling
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-sink
  namespace: tooling
spec:
  replicas: 1
  selector: { matchLabels: { app: webhook-sink } }
  template:
    metadata: { labels: { app: webhook-sink } }
    spec:
      containers:
        - name: sink
          image: docker.io/mendhak/http-https-echo:34
          env:
            - name: HTTP_PORT
              value: "8080"
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-sink
  namespace: tooling
spec:
  selector: { app: webhook-sink }
  ports: [{ port: 80, targetPort: 8080 }]
EOF
kubectl -n tooling rollout status deploy/webhook-sink
```

2. Configure Flux notifications.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: sink
  namespace: tenant-a
spec:
  type: generic
  address: http://webhook-sink.tooling.svc/flux
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: tenant-a-alerts
  namespace: tenant-a
spec:
  providerRef:
    name: sink
  eventSeverity: info          # 'error' for failures only; 'info' includes successes
  eventSources:
    - kind: Kustomization
      name: '*'
    - kind: OCIRepository
      name: '*'
EOF
```

3. Cause a failure and read the notification as an on-call engineer would.

```bash
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p '{"spec":{"ref":{"tag":"nope"}}}'
sleep 25
kubectl -n tooling logs deploy/webhook-sink --tail=200 \
  | grep -o '"body":.*' | tail -2
```

Representative payload:

```json
{
  "involvedObject": {"kind":"OCIRepository","namespace":"tenant-a","name":"tenant-a"},
  "severity": "error",
  "timestamp": "2026-08-18T15:22:41Z",
  "reason": "OCIArtifactPullFailed",
  "message": "failed to pull artifact from 'oci://ttl.sh/gitops-sec-4f2a1c9b/tenant-a:nope': nope: not found",
  "reportingController": "source-controller"
}
```

4. The same, Argo CD side.

```bash
kubectl -n argocd patch configmap argocd-notifications-cm --type merge -p '{
  "data": {
    "service.webhook.sink": "url: http://webhook-sink.tooling.svc/argocd\nheaders:\n- name: Content-Type\n  value: application/json\n",
    "template.app-sync-failed": "webhook:\n  sink:\n    method: POST\n    body: |\n      {\"app\":\"{{.app.metadata.name}}\",\"status\":\"{{.app.status.sync.status}}\",\"health\":\"{{.app.status.health.status}}\",\"revision\":\"{{.app.status.sync.revision}}\"}\n",
    "trigger.on-sync-failed": "- when: app.status.operationState.phase in [\"Error\", \"Failed\"]\n  send: [app-sync-failed]\n",
    "trigger.on-health-degraded": "- when: app.status.health.status == \"Degraded\"\n  send: [app-sync-failed]\n"
  }
}'

kubectl -n argocd annotate application guestbook \
  notifications.argoproj.io/subscribe.on-sync-failed.sink="" \
  notifications.argoproj.io/subscribe.on-health-degraded.sink="" --overwrite
```

5. Triage a failing reconciliation with the three-command drill. Learn this sequence:

```bash
flux get all -A --status-selector ready=false
flux events --for OCIRepository/tenant-a -n tenant-a
kubectl -n flux-system logs deploy/source-controller --tail=50 | grep -i tenant-a
```

Representative `flux events` output:

```
LAST SEEN  TYPE     REASON                  OBJECT                       MESSAGE
2m         Warning  OCIArtifactPullFailed   OCIRepository/tenant-a       failed to pull artifact ... nope: not found
14m        Normal   NewArtifact             OCIRepository/tenant-a       stored artifact for digest 'v2@sha256:9c1f...'
```

The Argo CD equivalent:

```bash
argocd app get guestbook --show-operation
argocd app history guestbook
kubectl -n argocd logs deploy/argocd-application-controller --tail=50 | grep guestbook
```

```
ID  DATE                           REVISION
0   2026-08-18 14:31:07 +0000 UTC  HEAD (53e28ff)
1   2026-08-18 14:47:52 +0000 UTC  HEAD (53e28ff)
2   2026-08-18 15:10:33 +0000 UTC  HEAD (53e28ff)
```

6. Roll back — the correct way and the wrong way, side by side.

**Wrong (imperative rollback):**

```bash
argocd app rollback guestbook 1
argocd app get guestbook | grep 'Sync Status'
```

The workload reverts, and the app immediately goes `OutOfSync` against Git — or, with self-heal on, is rolled *forward* again within one interval. You have created drift to fix drift.

**Right (declarative rollback):**

```bash
# git revert <bad-commit>   # in the config repository
# git push
# the reconciler applies the revert; the rollback is itself a reviewed, signed commit
```

In this lab, the OCI equivalent of a revert is repointing at the last verified digest:

```bash
source repo.env
kubectl -n tenant-a patch ocirepository tenant-a --type merge \
  -p "{\"spec\":{\"ref\":{\"digest\":\"${DIGEST}\",\"tag\":\"\"}}}"
flux reconcile kustomization tenant-a -n tenant-a --with-source
flux get sources oci -n tenant-a
```

7. Break-glass, done properly. When you must act outside Git, make the deviation *visible and expiring*:

```bash
flux suspend kustomization tenant-a -n tenant-a \
  --reason="INC-4471: manual mitigation, expires 2026-08-18T18:00Z, owner @dalmine"
kubectl -n tenant-a get kustomization tenant-a \
  -o jsonpath='{.spec.suspend}{"\t"}{.metadata.annotations}{"\n"}'
```

The suspension trips `FluxReconciliationSuspended` from Exercise 6 after an hour, so break-glass cannot become the permanent state by accident. That alert is the entire point of the annotation discipline.

```bash
flux resume kustomization tenant-a -n tenant-a
```

8. Assemble the incident timeline from all four sources — this is the deliverable of a GitOps security review:

```bash
echo "== Git / artifact provenance =="; cat push.json | jq '{digest, url: .repository}'
echo "== Reconciler events =="; flux events --for Kustomization/tenant-a -n tenant-a | tail -5
echo "== Notifications delivered =="; kubectl -n tooling logs deploy/webhook-sink --tail=5 | grep -o '"reason":"[^"]*"' | tail -5
echo "== Out-of-band API mutations =="
docker exec gitops-sec-control-plane sh -c 'cat /var/log/kubernetes/audit.log' \
  | jq -r 'select(.verb|test("^(create|update|patch|delete)$"))
           | select(.user.username|test("argocd|flux|kyverno|system:")|not)
           | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.name)"' \
  | tail -5
```

### Checkpoint questions — block 7

- **Q7.1** — The Flux `Alert` uses `eventSeverity: info`. State the trade-off against `error`, and which one belongs on a production paging channel.
- **Q7.2** — `argocd app rollback` reverted the workload and then it drifted or rolled forward. Explain the mechanism, and name the *only* rollback that is stable under continuous reconciliation.
- **Q7.3** — The break-glass step records a reason and an owner in a `--reason` flag. Name the two independent controls that make that annotation more than a comment.
- **Q7.4** — Notification payloads carry `message` verbatim from the controller. What is the data-exfiltration risk of routing Flux/Argo CD notifications to a third-party chat service, and what would you do about it?
- **Q7.5** — Step 8 correlates four sources: artifact provenance, reconciler events, notifications, audit log. Which single one of these is *not* reconstructible after the fact if you did not configure it in advance, and why does that make it the first thing to set up?

---

## Cleanup

```bash
kill %1 %2 %3 %4 2>/dev/null
kind delete cluster --name gitops-sec
cd ~ && rm -rf ~/gitops-sec   # contains cosign.key and age.agekey — do not leave these around
```

---

## Answers

<details>
<summary><strong>Click to expand — answers to all checkpoint questions</strong></summary>

### Block 0 — Lab and audit

**Q0.1** — `level: None` on reads blinds you to **secret exfiltration**: an attacker (or an over-broad ServiceAccount) doing `kubectl get secret -A -o yaml` reads every credential in the cluster and leaves no audit record. It also hides reconnaissance — `list` across all namespaces is the first move of most in-cluster attacks. The fix is a targeted rule *above* the blanket `None` rule, since audit rules are evaluated top-down and the first match wins:

```yaml
- level: Metadata
  verbs: ["get", "list"]
  resources:
    - group: ""
      resources: ["secrets"]
```

Keep it at `Metadata`, not `RequestResponse` — see Q0.2.

**Q0.2** — `RequestResponse` logs the full object body. For `secrets` that is exactly what makes it valuable during an incident (you can see *which* credential was written, and whether it was a rotation or a replacement) and exactly what makes it dangerous: **the audit log now contains plaintext secret material**. Base64 is not encryption. The audit log becomes a secret-tier artifact requiring the same encryption-at-rest, retention limits and access control as the etcd datastore, and it is typically shipped to a log aggregator with far weaker controls. Most production policies use `Metadata` for `secrets` for this reason, and only enable `RequestResponse` temporarily during a forensic investigation. The lab uses it so you can *see* the hazard.

**Q0.3** — `flux install` does not satisfy **"pulled automatically"** for Flux itself. The controllers are running, but they were installed imperatively; their own manifests are not in Git, so upgrading or reconfiguring Flux is a manual `kubectl apply`, drift in the Flux deployment is undetected, and there is no audit trail for changes to the reconciler — the most privileged component in the cluster. `flux bootstrap` commits the Flux manifests to the repository and creates a `Kustomization` that reconciles `flux-system` against them, making Flux self-managing: Flux drift is detected and corrected like any other workload, and every controller upgrade is a reviewed commit.

### Block 1 — Least privilege

**Q1.1** — kustomize-controller performs a **server-side dry-run apply of the entire resource set** before committing any change, and treats the set as a unit. If any object in the set is rejected, the whole `Kustomization` is marked not-ready and nothing is applied. Security-wise this is what you want: it makes partial application impossible, so an attacker cannot smuggle a change through by pairing it with an object they *know* will fail — there is no state where the "good half" landed. It also means the failure is loud and atomic rather than a half-applied configuration that is neither the old state nor the new one.

**Q1.2** — Two of several:
1. **The repository is not the only input.** A `Kustomization` may reference remote bases, a `HelmRelease` pulls an arbitrary chart, an `OCIRepository` follows a mutable tag. None of those go through your review. If the reconciler is cluster-admin, whoever controls that upstream is cluster-admin.
2. **Review is not enforcement.** Branch protection can be disabled by a repo admin, bypassed by an admin merge, or defeated by a compromised bot account/CI token with write access. Repo-level compromise is common; the security model should not convert it into cluster-root.
3. Additionally: anyone with `patch` on the `Kustomization`/`Application` object in-cluster can repoint `spec.path` or `spec.source` at content they control, bypassing Git entirely.

**Q1.3** — A read-only ServiceAccount grants *something*. A non-existent one grants *nothing* — every request from that identity is denied because there are no bindings for it at all — and it also produces an unmistakable error (`serviceaccounts "flux-default" not found` / a blanket `forbidden`) that tells the operator "you forgot `serviceAccountName`", rather than a subtle partial success. The rule is: the default must be a state no one would ever intend to leave in place. A read-only default fails quietly and might survive to production; a non-existent one cannot.

**Q1.4** — `clusterResourceWhitelist: []` is **fail-closed**: it is an allow-list, so anything not enumerated is denied, including resource kinds introduced by a CRD installed next year. `namespaceResourceBlacklist` is **fail-open**: it denies only what you thought to list, so any kind you did not anticipate is permitted. For a hostile or untrusted tenant, rely on the allow-lists (`clusterResourceWhitelist`, `namespaceResourceWhitelist`, `sourceRepos`, `destinations`) and treat the blacklists as defence in depth only. A blacklist that must be updated every time the ecosystem ships a new CRD is a maintenance obligation you will lose.

**Q1.5** — `argocd account can-i` evaluates the policy **for the currently logged-in account**, and `admin` is a built-in superuser that bypasses `policy.csv` entirely — it returns `yes` for everything, so it proves nothing about a tenant. The command that actually evaluates the policy for an arbitrary subject is:

```bash
argocd admin settings rbac can <subject> <action> <resource> <object> --policy-file policy.csv
```

which runs the Casbin evaluation offline against a given subject/group. Pair it with `argocd admin settings rbac validate` in CI so a malformed `policy.csv` is caught before it is applied — a syntax error in that ConfigMap silently falls back to `policy.default`.

### Block 2 — Secrets

**Q2.1** — **Benefit:** the diff of a rotated secret shows only the changed ciphertext blob against unchanged, human-readable structure, so a reviewer can confirm "this PR rotates the password of `db-credentials` in `tenant-a`" without decrypting anything. Encrypting the whole file makes every diff an opaque wall of ciphertext, and reviewers stop reviewing. It also lets `kustomize`, schema validators and policy engines parse the file. **Risk:** the cleartext metadata is an inventory. `metadata.name`, `namespace`, and the *key names* under `stringData` disclose your architecture — `stripe-live-api-key`, `prod-root-db-password`, `okta-saml-signing-cert` tell an attacker exactly where to aim, and the set of namespaces maps your tenancy. In a public repository this is real reconnaissance value; treat key naming as semi-public.

**Q2.2** — Logs are only one of several places a controller can echo input. The historical hazard in Flux is **`.status`** — specifically status conditions and the events derived from them, where an error message that embeds the offending object can carry decrypted content into an object that is readable by anyone with `get` on `Kustomization` (a much wider group than `get secrets`). Kubernetes `Event` objects are the same problem with a longer reach: they are namespace-readable by default and are usually shipped wholesale to a logging backend. So the check must cover logs **and** events **and** `.status`, and in production you should also confirm your log pipeline is not indexing controller stdout into a system with broader access than the cluster itself.

**Q2.3** — Anyone with `get` on Secrets in `tenant-a`, plus anyone with cluster-wide secret read (`cluster-admin`, most monitoring/backup agents, and any workload whose ServiceAccount is over-bound). Find out with:

```bash
kubectl auth can-i get secrets -n tenant-a --as=<subject>
# or, exhaustively:
kubectl get rolebindings,clusterrolebindings -A -o json \
  | jq '.items[] | select(.roleRef.name|test("admin|edit|cluster-admin")) | {kind, ns:.metadata.namespace, name:.metadata.name, subjects}'
```

This is the structural weakness of SOPS-in-cluster: **the decryption key is a Kubernetes Secret**, so the security of every encrypted file collapses to the security of one Secret in one namespace, protected by the same RBAC you were trying to strengthen. Mitigations: put the key in a namespace no tenant can reach, use a KMS provider (AWS/GCP/Azure KMS, Vault) so the private key never exists in the cluster at all, and enable etcd encryption-at-rest. But note that even with KMS, anything the controller can decrypt, an attacker with the controller's identity can decrypt.

**Q2.4** — Only **External Secrets Operator** (or any pull-from-a-secret-manager pattern) can satisfy it. The audit record has to exist at the moment of *access*, and with ESO every retrieval is an authenticated API call to Vault/AWS Secrets Manager/GCP Secret Manager, which logs caller identity, timestamp and secret path. SOPS and Sealed Secrets cannot: in both cases the secret material is decrypted from a file the operator already possesses, and reading a file is not an auditable event — there is no third party to log it. (Caveat worth stating in an exam answer: ESO audits the *fetch into the cluster*, not subsequent reads of the resulting Kubernetes Secret. For that you still need API-server audit on `secrets`, which is exactly the rule from Q0.1.)

**Q2.5** — Sealed Secrets encrypts against a public key whose private half is generated by, and lives only in, the sealed-secrets controller of that specific cluster. So:
- **Availability:** rebuilding the cluster generates a *new* key pair, and every `SealedSecret` in Git becomes undecryptable. Recovery requires having backed up the controller's private key — a step that is easy to skip and is discovered missing during a disaster, which is the worst possible moment. This is the single most common Sealed Secrets outage.
- **Security:** that backup is itself a master key to every secret in the cluster, so you have created a high-value artifact that must be stored somewhere *other* than the cluster, with its own access control and rotation story. Multi-cluster makes it worse: either you share one key across clusters (destroying the per-cluster blast radius that was the feature) or you maintain N encrypted copies of every secret.

The corresponding **SOPS** failure mode is the mirror image: losing the age/KMS private key makes every encrypted file in the repository permanently undecryptable, and rotating recipients means re-encrypting every file (`sops updatekeys`) — an all-repository change that is easy to apply incompletely, leaving files that only the *old* key can open.

### Block 3 — Supply chain

**Q3.1** — Tags are mutable pointers. If you sign `:v2` and verify `:v2`, the signature attests to whatever manifest that tag pointed at when you signed — but verification re-resolves the tag at pull time. An attacker with push access repoints `:v2` at a manifest they control; the verifier fetches the new digest and looks for a signature over *it*. With cosign the signature is stored at a digest-derived tag (`sha256-<digest>.sig`), so the attacker's digest has no signature and verification fails — which is why signing by digest and verifying by digest is safe. The genuinely dangerous variants are (a) verification schemes that check "is there *a* valid signature for this reference" without binding it to the resolved digest, and (b) **the operator's own workflow**: `cosign sign :v2` resolves the tag at signing time, so if the tag moved between your review and your signature, you have signed content you never reviewed. Signing the digest you actually inspected removes the race entirely.

**Q3.2** — **Continuous reconciliation** — specifically, reconciliation of the *last known-good* state. source-controller only stores an artifact after verification succeeds, so a verification failure leaves the previously stored artifact in place, and kustomize-controller keeps applying it. Yes, this is correct: the alternative — stopping enforcement when the source is unavailable or untrusted — would mean that anyone who can break your source verification can also freeze your cluster and let drift accumulate unopposed. Fail-closed on *accepting new state*, fail-static on *enforcing known-good state*. The essential corollary is that this failure is silent from the workload's point of view, so it **must** be alerted on (`FluxReconciliationFailure`, Exercise 6) — otherwise you run indefinitely on stale config while believing you are current.

**Q3.3** — Several defensible answers:
- **The Helm charts** pulled by `HelmRelease` — covered by `HelmRepository`/`HelmChart` with `verify.provider: cosign` for OCI-hosted charts, or provenance files (`.prov`) for classic repositories.
- **The Flux controller images themselves** — covered by verifying Flux's own signed releases at bootstrap, and by `flux install --image-pull-secret`/digest-pinned manifests.
- **The base images and dependencies inside `podinfo`** — covered by SLSA provenance attestations and SBOM attestations (`cosign attest --type slsaprovenance` / `--type cyclonedx`), verified with Kyverno `attestations:` blocks rather than a bare signature check. A signature says "this identity built it"; an attestation says "and here is what went into it".
- **The Git commits** — covered by signed commits/tags and `GitRepository.spec.verify`.

**Q3.4** — With `subject: "https://github.com/my-org/"` (unanchored, treated as a regex), the pattern matches any subject *containing* that substring. An attacker registers `https://github.com/my-org-evil/...`, or more simply pushes a branch to *any* repository under `my-org` that has a workflow with `id-token: write`, and gets a Sigstore keyless signature whose subject is `https://github.com/my-org/some-unrelated-repo/.github/workflows/anything.yaml@refs/heads/attacker-branch`. That subject contains the substring, so verification passes and Flux deploys their artifact as if it were the platform config. The anchored version pins the exact repository, the exact workflow file, and `@refs/tags/v*` — so only a tag-triggered run of one specific workflow in one specific repository produces an accepted signature. **Always anchor, and always pin the workflow path and ref type, not just the org.**

**Q3.5** — **Benefit:** the running Pod is pinned to an immutable digest, so the content is fixed at admission time. Without it, a kubelet restart or a node scale-out re-pulls `:6.7.1`, and if that tag has since been repointed the new node runs different code than the old one — the classic "same tag, different bits across the fleet" split-brain, and a persistence mechanism for an attacker who can push to the registry. It also makes `kubectl describe pod` an accurate record of what is actually running. **Operational consequence:** the digest is frozen at admission. A team that relies on `imagePullPolicy: Always` with a floating tag to pick up patches will find that Pods no longer change content on restart — updates now require the Deployment's pod template to change (which is the GitOps-correct behaviour, via an image-automation controller writing the new digest to Git, but it *is* a workflow change). Rollback and forensics also now reference digests rather than friendly tags.

**Q3.6** — **Risk:** `failurePolicy: Fail` means that if the webhook cannot complete — because Rekor is unreachable, slow, rate-limiting, or your egress proxy is down — *every* Pod creation in the matched scope is denied. That converts an external service's availability into your cluster's ability to schedule workloads, and it bites hardest exactly when you need it (during an incident, when you are scaling up or replacing nodes). It is also a self-inflicted DoS surface. **Mitigations that preserve the security property:**
- Run a **local Sigstore mirror / TUF root** and an internal Rekor, or use `--offline` verification against a bundled signature so no network call is required at admission.
- Sign with a **static key** whose public half is stored in-cluster (no transparency-log round trip) for the workloads that must never fail to schedule; keep keyless+Rekor for the rest.
- Scope the policy tightly (specific namespaces, exclude `kube-system` and the CNI) and set an aggressive `webhookTimeoutSeconds`, so a stall degrades a slice rather than the cluster.
- Verify **at admission for the image reference already resolved by an earlier CI gate**, so the admission check is a cheap digest comparison rather than a full remote verification.

What is *not* an acceptable mitigation is switching to `failurePolicy: Ignore`, which turns the control into a suggestion: an attacker who can degrade Rekor connectivity can then deploy anything.

### Block 4 — Policy as code

**Q4.1** — **Capable of noticing:** (a) the reconciler's drift detection — Argo CD marks the app `OutOfSync`, Flux reports a diff; and (b) the API-server audit log, which records the `patch` and its author. Kyverno does *not* notice, because the Deployment edit was permitted and only the resulting Pod is matched by the policy. **Capable of undoing:** only the reconciler, and only if self-heal/continuous reconciliation is enabled — `syncPolicy.automated.selfHeal: true` in Argo CD, or Flux's default behaviour of re-applying every interval. The audit log is a detective control with no corrective power. This is the exercise's whole point: detection, prevention and correction are three different controls, and GitOps supplies only the third by default.

**Q4.2** — Matching only `Pod` means the `Deployment` was accepted, the ReplicaSet was created, and the *Pod* was blocked (or in this case allowed, since the registry rule ran against a Pod that had not yet been created at edit time). The developer's `kubectl set image` returns success and the failure surfaces later as a ReplicaSet event nobody reads, with the Deployment showing `0/1 ready` and no obvious cause. The fix is to match the **controller kinds as well**, so the error is returned synchronously to whoever made the change:

```yaml
match:
  any:
    - resources:
        kinds: [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet]
```

Kyverno auto-generates rules for pod controllers when the rule matches `Pod` (the `pod-policies.kyverno.io/autogen-controllers` annotation controls this), but you should verify the autogen actually produced the rules you expect with `kubectl get clusterpolicy tenant-baseline -o yaml | grep autogen`, rather than assume it. Matching the controller kinds explicitly is what makes the error message land on the human who caused it.

**Q4.3** — Applying a new policy directly in `Enforce` on a cluster with existing workloads breaks **the next mutation of every non-compliant workload already running**. The running Pods are untouched — admission only evaluates new requests — so nothing appears wrong. Then a node drains, an HPA scales up, a Deployment rolls, or a `CrashLoopBackOff` Pod is recreated, and the replacement Pod is denied. You get a partial, delayed, seemingly random outage that surfaces hours or days after the policy merged, in workloads unrelated to the change, and often during an unrelated incident when the cluster is already reshuffling Pods. `Audit` first gives you the `PolicyReport` inventory of exactly which workloads will break, so you fix them before flipping the switch — and the `for:`-style delay between the two steps is what makes the rollout reviewable.

**Q4.4** — `permissions: contents: read` means the CI job holds **no cluster credential at all** — it can read the repository and nothing else. That is the structural security argument for pull-based GitOps: in a push-based pipeline, CI must hold a kubeconfig with write access to production, so every CI system, every third-party action, every dependency in the build, and every contributor able to modify a workflow file becomes a path to cluster-admin. Pull-based GitOps inverts the direction of trust — the cluster reaches out to Git, credentials never leave the cluster, and the CI compromise surface is reduced to "can propose a change that a human reviews and a reconciler with least privilege applies". CI validates; it does not deploy.

**Q4.5** — **CI-only:** violations in configuration that never reaches admission — a `Kustomization` overlay that fails to build, a resource for a namespace that does not exist, a policy violation in a manifest for a *different* cluster, a secret accidentally committed in plaintext, or a change that would delete a resource (admission sees the delete request, not the "this PR removes 40 objects" fact). CI also catches violations in resources that would be pruned or never created, and it can fail the *pull request*, which is the only place a human is looking. **Webhook-only:** anything that bypasses Git — `kubectl` from a laptop, a controller or operator creating objects programmatically, a Helm chart's hooks, a mutating webhook injecting a sidecar after CI validated the manifest, or values resolved at runtime from a ConfigMap. Structurally, CI validates *source text*; the webhook validates *the actual API request*, including everything that was templated, defaulted, or mutated in between. Neither is sufficient alone, which is why the answer is always both.

### Block 5 — Drift and attribution

**Q5.1** — **Sync status** compares the live cluster state against the desired state in Git — it answers "is the cluster what we declared?". **Health status** is an application-level assessment of the live resources — Deployment replicas available, Service endpoints ready — and answers "is the thing running okay?". They are orthogonal: an attacker who injects a backdoored image produces a perfectly `Healthy` application that is `OutOfSync`, and a legitimately-synced app can be `Degraded` because of a bad image tag in Git. Alerting only on `Healthy` means every successful unauthorized change is invisible, because malicious changes are usually designed to keep the workload running. Sync status is the security signal; health status is the availability signal. Page on `Degraded`; alert on sustained `OutOfSync`.

**Q5.2** — *Every `ignoreDifferences` entry must name the controller that legitimately owns the field, and must not cover anything that determines what code runs.* Concretely: acceptable for fields owned by another in-cluster controller (`/spec/replicas` under an HPA, `caBundle` injected by cert-manager, `clusterIP` assigned by the API server, webhook `caBundle`s). Unacceptable for `image`, `command`, `args`, `env`, `securityContext`, `serviceAccountName`, RBAC rules, or anything under `/spec/template/spec/containers/*` other than resource fields managed by a VPA. A PR that adds one of the latter should be treated as a request to disable a security control and reviewed as such — including "what alerts stop working if we merge this?" Prefer the narrower, self-documenting alternatives: `managedFieldsManagers` (ignore only what a named field manager owns) over a raw JSON pointer, and `RespectIgnoreDifferences=true` so the exclusion is consistent between diff and sync.

**Q5.3** — Automatic reversion makes an incident worse when the drift *is* the mitigation. Classic cases: an on-call engineer scales a runaway Deployment to zero to stop it flooding a database, and self-heal scales it back up 30 seconds later; someone patches a Service selector to shed traffic from a bad release; a manual `hotfix` image is applied while the fix is still in review. Self-heal turns each of these into a fight the human loses on a timer. The deliberate pause mechanisms:
- Flux: `flux suspend kustomization <name>` (sets `spec.suspend: true`), `flux suspend helmrelease`, or `flux suspend source`.
- Argo CD: `argocd app set <app> --sync-policy none`, or the `argocd.argoproj.io/sync-options: Prune=false` / per-resource `argocd.argoproj.io/compare-options: IgnoreExtraneous` annotations for narrower exclusions.

Both must be paired with the suspension alert from Exercise 6, because a suspended reconciler is a security control that has been switched off, and the failure mode is that nobody switches it back on.

**Q5.4** — A field Flux does not manage is **left alone**. Server-side apply tracks ownership per-field in `metadata.managedFields`; kustomize-controller sends only the fields present in its manifests, so it asserts ownership of those and takes them back on the next apply, while fields owned by other managers (a mutating webhook's injected sidecar annotation, an HPA's `spec.replicas`, the API server's defaulted values) are untouched. This is the correct design because Kubernetes is a multi-writer system: several controllers legitimately co-own one object. A reconciler that enforced *whole-object* equality would fight every admission webhook, every autoscaler and every defaulter in an endless apply loop — the exact behaviour that made client-side-apply GitOps unusable with service meshes. Note the security consequence, though: **Flux only corrects drift in fields it declares.** A field you never wrote in Git (say, an added `hostPath` volume on a Deployment... which SSA *would* catch as part of the containers list, but an added label, annotation or tolerations entry) is drift that reconciliation will not remove unless `spec.force` or an explicit declaration covers it. Detection of *added* fields is weaker than correction of *changed* declared ones.

**Q5.5** — Git records what was *declared* and by whom, and when it was merged. It has no record of the running cluster: an out-of-band `kubectl patch` never touches Git, so from Git's point of view nothing happened at 14:41. The reconciler's own events tell you that it *corrected* something and when, but not who caused it — the actor is on the other side of the API server. The minimum additional data source is the **API-server audit log** (or an equivalent that captures authenticated request metadata: a proxy/audit sidecar, or a Falco/Tetragon-style runtime sensor observing the API traffic). It is the only place that binds *identity* to *mutation*. This is also why the audit log had to be enabled in Exercise 0 — see Q7.5.

### Block 6 — Observability

**Q6.1** — The multiplication by `gotk_suspend_status == 0` prevents **alert fatigue from deliberate suspensions**: a `Kustomization` suspended for a migration or break-glass is not failing, and if it pages the on-call every 10 minutes, the team learns to ignore the alert — which is worse than not having it. The blind spot it creates is exactly the thing suspension *is*: a reconciler that has stopped enforcing anything. Drift is no longer corrected, unauthorized changes persist indefinitely, and the failure alert is muted by construction. `FluxReconciliationSuspended` (`gotk_suspend_status == 1`, `for: 1h`) closes it by turning "suspended" from an invisible state into a time-bounded one. The pair encodes the real policy: *suspension is allowed, permanent suspension is not.*

**Q6.2** — `gotk_reconcile_condition` and `argocd_app_info` are exported *by the controllers themselves*. If a controller crashes, is scaled to zero, is deleted, or its `PodMonitor` selector stops matching after a label change, the series simply **stop being produced**. Prometheus retains them briefly (staleness markers make them disappear within ~5 minutes) and then any query of the form `metric == 1` or `metric > 0` returns an *empty result* — which for an alerting rule means "no alert". Silence is indistinguishable from health. `absent()` inverts this: it returns `1` precisely when the selector matches nothing, so the disappearance of telemetry becomes the signal. Every alert stack that depends on an application-exported metric needs an `absent()` (or `up == 0`) companion; without it you are monitoring "the reconciler says it is fine", not "the reconciler exists". A production version would also alert on `up{job=~".*controller.*"} == 0` to distinguish "controller down" from "scrape config broken".

**Q6.3** — `Degraded` means the workload is failing *right now* — Pods crash-looping, no ready endpoints, users affected. That is an availability incident and five minutes is already generous; the `for: 5m` exists only to absorb a normal rolling update. `OutOfSync` means the cluster differs from Git, which is routinely transient: it is the expected state for the seconds-to-minutes between a merge and the next reconciliation, during a sync operation, and while a slow rollout completes. Alerting at 5 minutes would fire on every deploy. Fifteen minutes says "this divergence has outlived any legitimate deployment window, so it is either a stuck sync or an unauthorized change" — a security signal that deserves investigation but not a 3 a.m. page. The general principle: set `for:` longer than the longest *normal* duration of the condition, and the severity by what the condition means once that duration is exceeded.

**Q6.4** — Because `sync_status` and `health_status` are labels rather than values, **each distinct status produces a distinct time series**. An application that flips `Synced` → `OutOfSync` → `Synced` creates two series, and the `OutOfSync` one does not go to zero when the app recovers — it goes *stale*. Prometheus keeps returning its last value for up to 5 minutes after the last scrape that contained it, so `argocd_app_info{sync_status!="Synced"} == 1` can keep evaluating true for several minutes after the condition cleared, and with a short scrape interval and a flapping app you can accumulate series for statuses that no longer exist. The practical failures are (a) an alert that resolves several minutes late, and (b) with unusual scrape/retention settings, an alert that appears stuck firing. Cardinality also grows with `name × project × dest_namespace × health_status × sync_status`, which on a cluster with thousands of applications is a real memory cost. Mitigations: aggregate with `max by (name) (...)` and compare against the *current* status rather than selecting on the label, keep the `for:` window comfortably longer than the staleness window, and use recording rules to collapse the status labels into a numeric health score.

**Q6.5** — None of these measure **commit-to-live lag**: the wall-clock time from a change being merged in Git to that change being observably running in the cluster. `gotk_reconcile_duration_seconds` measures how long *one apply* took, not how long the change waited in the source poll interval, the CI pipeline, the image build, or the rollout. That end-to-end number is the one a platform SLO should be written against ("95% of merges are live within 10 minutes"), because it is the only one a user of the platform experiences, and it is also the security-relevant number: it bounds how long a *security patch* takes to reach production, and — read the other way — how long an attacker's merged change survives before being noticed. To measure it: stamp each commit into the rendered manifests (a label or annotation carrying the commit SHA and its author timestamp), then export a metric that compares the commit timestamp with the observation time of that SHA in the live cluster. Flux exposes `.status.lastAppliedRevision` on the `Kustomization` and Argo CD exposes `.status.sync.revision` on the `Application`; a small exporter (or `kube-state-metrics` custom resource config) can turn either into `gitops_commit_to_live_seconds`. Synthetic canaries — a job that commits a timestamp file every N minutes and measures when it appears — are the cheap version and are usually good enough.

### Block 7 — Notifications and response

**Q7.1** — `eventSeverity: info` delivers *every* event, including successful reconciliations. That is valuable as a low-noise audit stream in a chat channel — "tenant-a reconciled to v4 at 14:02" gives the team ambient awareness of what is changing, and its *absence* is itself a signal. But it is high volume: with a 1-minute interval across dozens of resources it will drown a channel and, more importantly, it trains people to ignore the channel. `eventSeverity: error` delivers only failures. **Production paging goes to `error`**, routed to the on-call; the `info` stream, if you want it, goes to a separate low-priority channel or straight to the log pipeline. The general rule: the channel that wakes someone up must have a near-100% actionable rate, and any stream containing routine successes cannot.

**Q7.2** — `argocd app rollback N` performs an imperative sync to a previously-recorded revision. It changes the *cluster* without changing *Git*, so the moment it completes, the live state differs from the declared state. With `selfHeal: false` the app sits `OutOfSync` (and your Exercise 6 alert fires); with `selfHeal: true` the application controller re-applies the desired state from Git within one interval and rolls you straight back *forward* onto the broken revision — often faster than the engineer can react, which is a genuinely confusing incident to be in. The only rollback that is stable under continuous reconciliation is one that **changes the declared state**: `git revert <bad-commit>` (or a commit repointing to the previous digest/tag), pushed to the tracked branch. It is stable because the reconciler now agrees with it; it is also reviewable, signed, attributable, and leaves the incident visible in the history rather than as an untraceable cluster mutation. `argocd app rollback` is a break-glass tool for when Git or CI is unavailable, and it should be followed by a real revert as soon as it is.

**Q7.3** — (1) **The suspension alert** — `gotk_suspend_status == 1` with `for: 1h` from Exercise 6. Without it, the annotation is a note nobody reads and the suspension becomes permanent by attrition; with it, break-glass has a built-in expiry conversation. (2) **The audit log** — `kubectl patch`/`flux suspend` is an authenticated mutation of the `Kustomization` object, recorded with the actor's identity and timestamp, so the claim in the `--reason` string can be checked against who actually did it and when. Together they make the annotation *verifiable and time-bounded* rather than decorative. A third, if your setup has it: the notification stream, since suspending emits an event that lands in the incident channel, putting the deviation in front of the team in real time rather than in a field someone has to think to look at.

**Q7.4** — Controller messages embed the content that caused them: failed field paths, rejected object excerpts, error strings from the API server, repository URLs, image references, and occasionally decrypted values (see Q2.2). Routing that to a third-party chat or webhook service **publishes internal architecture — and potentially secret material — to a vendor**, where it is retained, indexed, searchable by anyone in the workspace, and often replicated to that vendor's own logging and support systems. Chat workspaces typically have far broader membership than cluster RBAC, so this can be a larger disclosure than granting `get secrets` to the whole company. What to do: treat notification payloads as cluster-confidential — prefer a self-hosted sink or a `generic` provider pointing at infrastructure you control; use templates that emit only structured, allow-listed fields (`app`, `namespace`, `revision`, `status`) rather than passing `message` through verbatim; route to a private channel with membership reviewed like any other access grant; and verify the check from Exercise 2 step 7 against the *notification sink* as well as the logs. If you must use a SaaS provider, send an identifier and make the engineer fetch the detail from a system that authenticates them.

**Q7.5** — The **API-server audit log**. Artifact provenance can be reconstructed after the fact (the digest is still in the registry, the signature is still in Rekor's transparency log, `push.json` or the OCI manifest can be re-read). Reconciler events and object status can be re-derived to a degree from controller logs, `.status` fields, and the objects themselves. Notifications, if lost, are a duplicate of information the controllers still hold. But the audit log is the **only** record binding an *identity* to a *mutation*, it exists only if the API server was configured to write it **before** the event, and it cannot be reconstructed from anything else — the request is gone the moment it is served. Everything in this topic that answers "who did this, and when" collapses without it. That is why it belongs in Exercise 0: it is the one control whose absence you can only discover when it is already too late to fix.

</details>

---

## Sources

- CNCF GitOps Associate (CGOA) curriculum — <https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md>
- OpenGitOps Principles v1.0.0 — <https://opengitops.dev/>
- Flux security documentation — <https://fluxcd.io/flux/security/>
- Flux multi-tenancy and reconciler impersonation — <https://fluxcd.io/flux/installation/configuration/multitenancy/>
- Flux SOPS guide — <https://fluxcd.io/flux/guides/mozilla-sops/>
- Flux `OCIRepository` signature verification — <https://fluxcd.io/flux/components/source/ocirepositories/>
- Flux `GitRepository` verification — <https://fluxcd.io/flux/components/source/gitrepositories/>
- Flux monitoring and metrics — <https://fluxcd.io/flux/monitoring/metrics/>
- Flux notification controller — <https://fluxcd.io/flux/components/notification/>
- Argo CD RBAC — <https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/>
- Argo CD projects — <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/>
- Argo CD metrics — <https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/>
- Argo CD notifications — <https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/>
- Argo CD secret management overview — <https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/>
- Argo CD sync options and `ignoreDifferences` — <https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/>
- SOPS — <https://github.com/getsops/sops>
- age — <https://github.com/FiloSottile/age>
- Sealed Secrets — <https://github.com/bitnami-labs/sealed-secrets>
- External Secrets Operator — <https://external-secrets.io/latest/>
- Sigstore / cosign documentation — <https://docs.sigstore.dev/>
- Kyverno writing policies — <https://kyverno.io/docs/writing-policies/>
- Kyverno image verification — <https://kyverno.io/docs/writing-policies/verify-images/>
- Kyverno CLI — <https://kyverno.io/docs/kyverno-cli/>
- Kubernetes auditing — <https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/>
- Kubernetes server-side apply and field management — <https://kubernetes.io/docs/reference/using-api/server-side-apply/>
- kind audit-logging configuration — <https://kind.sigs.k8s.io/docs/user/configuration/>
- SLSA specification — <https://slsa.dev/spec/v1.0/levels>
- Prometheus alerting rules — <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>