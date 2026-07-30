# Topic 2.2 — Manage Kubernetes Secrets: Guided Exercises

**Certification:** CKS (exam version 1.34) · **Exam weight:** 5

## Lab prerequisites

- A kubeadm-provisioned cluster where you have **root/sudo on the control plane node** (you will edit static Pod manifests and read etcd directly).
- `kubectl`, `etcdctl` (or `ETCDCTL_API=3 etcdctl` via the etcd container), `jq`, `base64`, `openssl`.
- A scratch namespace. Create it once and reuse it across all exercises:

```bash
kubectl create namespace secret-lab
kubectl config set-context --current --namespace=secret-lab
```

> All exercises are idempotent: re-running a step either succeeds or fails with "AlreadyExists", which is safe. Where a manifest is edited, a backup step is included so you can roll back.

---

## Exercise 1 — Prove that a Secret is only encoded, not encrypted

### Steps

1. Create a Secret with two keys, deliberately using `-n` to avoid a trailing newline in the value:

   ```bash
   kubectl -n secret-lab create secret generic app-db \
     --from-literal=username=appuser \
     --from-literal=password='S3cr3t-P@ss'
   ```

2. Inspect how the API server stores and returns it:

   ```bash
   kubectl -n secret-lab get secret app-db -o yaml
   ```

3. Decode a single key without dumping the whole object:

   ```bash
   kubectl -n secret-lab get secret app-db -o jsonpath='{.data.password}' | base64 -d; echo
   ```

4. Compare with `describe`, which never prints values:

   ```bash
   kubectl -n secret-lab describe secret app-db
   ```

5. Now read the raw record straight out of etcd on the control plane node:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/app-db | hexdump -C | head -n 20
   ```

6. Create a second Secret using `stringData` instead of `data`, then read it back:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-api
     namespace: secret-lab
   type: Opaque
   stringData:
     apikey: "ak-1234567890"
   EOF

   kubectl -n secret-lab get secret app-api -o yaml | grep -A2 '^data:'
   ```

### Check your understanding

- **Q1.1** In step 5, was `S3cr3t-P@ss` visible in the etcd output? What does that tell you about the default protection level of Secrets?
- **Q1.2** Why is `base64` not a security control here?
- **Q1.3** `describe` hid the values but `get -o yaml` showed them. Which RBAC verb do both operations need, and what does that imply about "read-only" access to Secrets?
- **Q1.4** What happened to the `stringData` field after `apply`? Which field wins if both `data` and `stringData` define the same key?
- **Q1.5** Why did the instructions insist on `--from-literal` / `echo -n` semantics rather than `--from-file=password.txt` created with `echo`?

---

## Exercise 2 — Enable encryption at rest for Secrets

### Steps

1. Back up the current API server manifest and etcd data before touching anything:

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     snapshot save /root/etcd-before-encryption.db
   ```

2. Generate a 32-byte key and write the `EncryptionConfiguration`:

   ```bash
   sudo mkdir -p /etc/kubernetes/enc
   KEY=$(head -c 32 /dev/urandom | base64)

   sudo tee /etc/kubernetes/enc/enc.yaml >/dev/null <<EOF
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources:
         - secrets
       providers:
         - secretbox:
             keys:
               - name: key1
                 secret: ${KEY}
         - identity: {}
   EOF

   sudo chmod 600 /etc/kubernetes/enc/enc.yaml
   ```

3. Wire the file into the API server static Pod. Add the flags under `command:`:

   ```yaml
       - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
       - --encryption-provider-config-automatic-reload=true
   ```

   Add the volume mount to the `kube-apiserver` container:

   ```yaml
       volumeMounts:
         - name: enc
           mountPath: /etc/kubernetes/enc
           readOnly: true
   ```

   And the host volume at Pod level:

   ```yaml
     volumes:
       - name: enc
         hostPath:
           path: /etc/kubernetes/enc
           type: DirectoryOrCreate
   ```

4. Save the file and wait for the kubelet to restart the static Pod:

   ```bash
   sudo crictl ps | grep kube-apiserver
   kubectl -n kube-system get pod -l component=kube-apiserver
   until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
   ```

5. Create a **new** Secret and read it from etcd:

   ```bash
   kubectl -n secret-lab create secret generic post-enc --from-literal=token=after-encryption

   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/post-enc | hexdump -C | head -n 5
   ```

6. Now re-read the Secret created **before** you enabled encryption:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     --endpoints=https://127.0.0.1:2379 \
     get /registry/secrets/secret-lab/app-db | hexdump -C | head -n 5
   ```

7. Force every existing Secret through the write path so it gets encrypted:

   ```bash
   kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

   Verify `app-db` again with the command from step 6.

8. Confirm the cluster still functions from the client side:

   ```bash
   kubectl -n secret-lab get secret app-db -o jsonpath='{.data.password}' | base64 -d; echo
   ```

### Check your understanding

- **Q2.1** What prefix appeared in front of the encrypted payload in step 5, and what are its components?
- **Q2.2** Why is `identity: {}` listed **after** `secretbox` and not before? What breaks if you put it first?
- **Q2.3** Step 6 showed plaintext. Explain precisely why, and what step 7 does about it.
- **Q2.4** In step 8 you still read the password with `kubectl`. Which threat does encryption at rest actually mitigate, and which does it *not*?
- **Q2.5** You added `--encryption-provider-config-automatic-reload=true`. Which change can you now make without restarting the API server, and which change still requires one?
- **Q2.6** The Kubernetes documentation flags `aescbc` as not recommended and treats KMS v2 as the preferred provider. Give one reason for each of those positions.
- **Q2.7** To roll encryption back safely, what is the exact order of operations?

---

## Exercise 3 — Consume Secrets from a Pod: env vars vs projected files

### Steps

1. Deploy a Pod that consumes the Secret as environment variables:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: env-consumer
     namespace: secret-lab
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         envFrom:
           - secretRef:
               name: app-db
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/env-consumer --timeout=60s
   ```

2. Enumerate the leakage surface of the env-var approach:

   ```bash
   kubectl -n secret-lab exec env-consumer -- env | grep -E 'username|password'
   kubectl -n secret-lab exec env-consumer -- cat /proc/1/environ | tr '\0' '\n' | grep password
   ```

3. Rotate the Secret value and check whether the running container sees the change:

   ```bash
   kubectl -n secret-lab patch secret app-db \
     -p '{"stringData":{"password":"R0tated-P@ss"}}'
   sleep 10
   kubectl -n secret-lab exec env-consumer -- env | grep password
   ```

4. Deploy a Pod that mounts the same Secret as a read-only volume with restrictive permissions:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: file-consumer
     namespace: secret-lab
   spec:
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       fsGroup: 10001
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - name: db
             mountPath: /etc/db
             readOnly: true
     volumes:
       - name: db
         secret:
           secretName: app-db
           defaultMode: 0400
           items:
             - key: password
               path: password
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/file-consumer --timeout=60s
   ```

5. Inspect what landed in the container:

   ```bash
   kubectl -n secret-lab exec file-consumer -- ls -l /etc/db/
   kubectl -n secret-lab exec file-consumer -- ls -l /etc/db/..data/
   kubectl -n secret-lab exec file-consumer -- cat /etc/db/password; echo
   kubectl -n secret-lab exec file-consumer -- ls -a /etc/db/
   ```

6. Rotate again and observe propagation into the mounted file:

   ```bash
   kubectl -n secret-lab patch secret app-db \
     -p '{"stringData":{"password":"R0tated-Twice"}}'
   for i in $(seq 1 12); do
     kubectl -n secret-lab exec file-consumer -- cat /etc/db/password; echo
     sleep 10
   done
   ```

7. Make the Secret immutable and try to change it:

   ```bash
   kubectl -n secret-lab patch secret app-api -p '{"immutable":true}'
   kubectl -n secret-lab patch secret app-api -p '{"stringData":{"apikey":"ak-new"}}'
   ```

### Check your understanding

- **Q3.1** List three distinct ways the value exposed in step 2 can escape the container that do **not** apply to a file-mounted Secret.
- **Q3.2** Step 3 vs step 6: which consumption method picked up the rotation, and what is the mechanism behind the difference?
- **Q3.3** What are `..data` and `..2026_07_29_...` in the mount directory, and why does that design matter for atomic rotation?
- **Q3.4** Which single field in the `file-consumer` manifest would break the auto-update behaviour if you used it to mount just one key into an existing directory?
- **Q3.5** Why is `automountServiceAccountToken: false` a Secrets-management control and not just a tidy-up?
- **Q3.6** Step 7 failed. Name two benefits of `immutable: true` — one security-related, one performance-related — and state how you would then roll the value.
- **Q3.7** `defaultMode: 0400` was requested. Why can the effective mode still differ from what you expect, and which field interacts with it?

---

## Exercise 4 — Least-privilege RBAC for Secrets

### Steps

1. Create a ServiceAccount and a Role that grants access to exactly one Secret:

   ```bash
   kubectl -n secret-lab create serviceaccount app-sa

   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: read-app-db
     namespace: secret-lab
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       resourceNames: ["app-db"]
       verbs: ["get"]
   EOF

   kubectl -n secret-lab create rolebinding app-sa-read-app-db \
     --role=read-app-db --serviceaccount=secret-lab:app-sa
   ```

2. Test the permission boundary with impersonation:

   ```bash
   SA=system:serviceaccount:secret-lab:app-sa
   kubectl auth can-i get secret/app-db      -n secret-lab --as=$SA
   kubectl auth can-i get secret/app-api     -n secret-lab --as=$SA
   kubectl auth can-i list secrets           -n secret-lab --as=$SA
   kubectl auth can-i get secrets            -n secret-lab --as=$SA -n kube-system
   ```

3. Confirm behaviour with a real request instead of a dry-run check:

   ```bash
   kubectl -n secret-lab get secret app-db  --as=$SA -o jsonpath='{.data.username}' | base64 -d; echo
   kubectl -n secret-lab get secret app-api --as=$SA
   kubectl -n secret-lab get secrets        --as=$SA
   ```

4. Now add a `list` rule and observe what `resourceNames` can and cannot do:

   ```bash
   kubectl -n secret-lab patch role read-app-db --type=json -p \
     '[{"op":"add","path":"/rules/0/verbs/-","value":"list"}]'
   kubectl -n secret-lab get secrets --as=$SA
   ```

5. Remove the `list` verb again, then probe the classic escalation path:

   ```bash
   kubectl -n secret-lab patch role read-app-db --type=json -p \
     '[{"op":"remove","path":"/rules/0/verbs/1"}]'

   kubectl auth can-i create pods -n secret-lab --as=$SA
   ```

6. Audit the cluster for over-broad Secret access:

   ```bash
   kubectl get clusterroles -o json | jq -r '
     .items[] | select(.rules[]? |
       ((.resources//[]) | index("secrets") or index("*")) and
       ((.verbs//[]) | index("get") or index("list") or index("*"))
     ) | .metadata.name' | sort -u

   kubectl get clusterrolebindings -o json | jq -r '
     .items[] | select(.roleRef.name=="cluster-admin") |
     "\(.metadata.name): \([.subjects[]?|"\(.kind)/\(.name)"]|join(","))"'
   ```

### Check your understanding

- **Q4.1** Step 2 showed `get secret/app-db` allowed but `list secrets` denied even after the Role covered `secrets`. Why does `resourceNames` not constrain `list` and `watch` in a useful way?
- **Q4.2** In step 4, once `list` was granted, what did `app-sa` actually receive? Why is that an authorization decision people frequently get wrong?
- **Q4.3** Step 5 checked `create pods`. Explain why the answer to that question can make the whole Role in step 1 irrelevant.
- **Q4.4** Give two mitigations for the escalation path in Q4.3 that do not involve changing this Role.
- **Q4.5** Why is `kubectl auth can-i --as` acceptable evidence in a hardening review, and what is one thing it will not tell you?
- **Q4.6** Which built-in ClusterRoles typically appear in the step 6 output for legitimate reasons, and how would you triage the list?

---

## Exercise 5 — Bound service account tokens and short-lived credentials

### Steps

1. Inspect the token the API server projects into a Pod by default:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: token-inspect
     namespace: secret-lab
   spec:
     serviceAccountName: app-sa
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/token-inspect --timeout=60s

   kubectl -n secret-lab exec token-inspect -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

2. Decode the token payload:

   ```bash
   kubectl -n secret-lab exec token-inspect -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

3. Check whether a long-lived Secret backs this ServiceAccount:

   ```bash
   kubectl -n secret-lab get serviceaccount app-sa -o yaml
   kubectl -n secret-lab get secrets
   ```

4. Request an explicitly scoped token from the TokenRequest API:

   ```bash
   kubectl -n secret-lab create token app-sa --duration=10m --audience=vault \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, exp, iat, sub}'
   ```

5. Project a custom-audience, short-lived token into a Pod:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: token-projected
     namespace: secret-lab
   spec:
     serviceAccountName: app-sa
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: vault-token
             mountPath: /var/run/secrets/tokens
             readOnly: true
     volumes:
       - name: vault-token
         projected:
           sources:
             - serviceAccountToken:
                 path: vault-token
                 audience: vault
                 expirationSeconds: 600
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/token-projected --timeout=60s

   kubectl -n secret-lab exec token-projected -- \
     cat /var/run/secrets/tokens/vault-token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, exp, "kubernetes.io"}'
   ```

6. Create a legacy, non-expiring token Secret and compare:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-sa-legacy-token
     namespace: secret-lab
     annotations:
       kubernetes.io/service-account.name: app-sa
   type: kubernetes.io/service-account-token
   EOF

   kubectl -n secret-lab get secret app-sa-legacy-token \
     -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

7. Verify that a mismatched audience is rejected:

   ```bash
   TOKEN=$(kubectl -n secret-lab create token app-sa --audience=vault)
   cat <<EOF | kubectl create -o json -f - | jq '.status'
   apiVersion: authentication.k8s.io/v1
   kind: TokenReview
   spec:
     token: "${TOKEN}"
     audiences: ["https://kubernetes.default.svc"]
   EOF
   ```

### Check your understanding

- **Q5.1** Which claims in step 2 prove the token is *bound*, and bound to what exactly?
- **Q5.2** Step 3 found no auto-generated token Secret for `app-sa`. What changed in Kubernetes to make that the norm, and why is it a security improvement?
- **Q5.3** Compare the payloads from step 5 and step 6. What is the practical blast radius difference if each token leaks?
- **Q5.4** Why does the `audience` field matter when a workload authenticates to an external system such as Vault?
- **Q5.5** In step 5, `automountServiceAccountToken: false` was combined with a projected token. Is that contradictory? Explain.
- **Q5.6** Step 7 returned an unauthenticated result. Which component performs this check in a real integration, and what attack does it stop?

---

## Exercise 6 — Keep Secrets out of the audit log and out of manifests

### Steps

1. Write an audit policy that records Secret access without recording Secret contents:

   ```bash
   sudo mkdir -p /etc/kubernetes/audit
   sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   omitStages:
     - RequestReceived
   rules:
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]
     - level: Metadata
       resources:
         - group: "authentication.k8s.io"
           resources: ["tokenreviews"]
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]
     - level: Metadata
   EOF
   ```

2. Enable it on the API server (`/etc/kubernetes/manifests/kube-apiserver.yaml`), reusing the backup habit from Exercise 2:

   ```yaml
       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
       - --audit-log-path=/var/log/kubernetes/audit/audit.log
       - --audit-log-maxage=30
       - --audit-log-maxbackup=5
       - --audit-log-maxsize=100
   ```

   Mount both the policy directory (read-only) and the log directory (writable), then wait for readiness as in Exercise 2 step 4.

3. Generate Secret traffic and inspect what was logged:

   ```bash
   kubectl -n secret-lab get secret app-db -o yaml >/dev/null
   sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log | tail -n 1 | jq .
   ```

4. Confirm the value is absent from the log:

   ```bash
   sudo grep -c 'R0tated-Twice' /var/log/kubernetes/audit/audit.log || echo "value not present"
   ```

5. Detect Secret material committed into manifests, the most common real-world leak:

   ```bash
   kubectl -n secret-lab set env deployment/dummy FOO=bar --dry-run=client 2>/dev/null || true

   cat <<'EOF' > /tmp/bad-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardcoded
     namespace: secret-lab
   spec:
     containers:
       - name: app
         image: busybox:1.36
         env:
           - name: DB_PASSWORD
             value: "S3cr3t-P@ss"
   EOF

   grep -nEi '(password|passwd|secret|token|apikey|api_key)[[:space:]]*:' /tmp/bad-pod.yaml
   ```

6. Refactor the manifest to reference a Secret instead of embedding the value, and verify the workload still starts:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardcoded-fixed
     namespace: secret-lab
   spec:
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: db
             mountPath: /etc/db
             readOnly: true
     volumes:
       - name: db
         secret:
           secretName: app-db
           defaultMode: 0400
   EOF
   kubectl -n secret-lab wait --for=condition=Ready pod/hardcoded-fixed --timeout=60s
   ```

7. Sketch the external-store pattern and reason about it without installing a provider:

   ```bash
   cat <<'EOF' > /tmp/spc.yaml
   apiVersion: secrets-store.csi.x-k8s.io/v1
   kind: SecretProviderClass
   metadata:
     name: vault-db
     namespace: secret-lab
   spec:
     provider: vault
     parameters:
       roleName: app-role
       vaultAddress: https://vault.example.internal:8200
       objects: |
         - objectName: "password"
           secretPath: "secret/data/app/db"
           secretKey: "password"
   EOF

   kubectl apply -f /tmp/spc.yaml --dry-run=client -o yaml | head -n 8
   ```

### Check your understanding

- **Q6.1** Why is `level: Metadata` mandatory for `secrets` rather than `Request` or `RequestResponse`?
- **Q6.2** Rule order matters in an audit policy. What would happen if the catch-all `level: Metadata` rule were moved to the top?
- **Q6.3** The audit log records `get` on a Secret. Does it record that a Pod read a mounted Secret file? Why is that a monitoring gap, and what would you correlate instead?
- **Q6.4** Beyond git history, name two other places a hardcoded value from step 5 typically ends up.
- **Q6.5** In the CSI pattern of step 7, where does the Secret material live at rest, and which local exposure from Exercise 1 does that remove?
- **Q6.6** `secretObjects` / `syncSecret` can mirror an external secret into a Kubernetes Secret. What do you gain and what do you give up by enabling that?
- **Q6.7** You have encryption at rest, tight RBAC, file-based mounts, and an external store. Rank these four by how much residual risk each removes, and justify the top choice.

---

## Cleanup

```bash
kubectl delete namespace secret-lab

# Roll back the API server changes if this was a scratch cluster
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw='/readyz' 2>/dev/null; do sleep 3; done; echo
```

> If you keep encryption enabled but delete the key file, every encrypted Secret becomes unreadable. Treat `/etc/kubernetes/enc/enc.yaml` as a backup-critical artifact, and never store it inside the cluster it protects.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** Yes — the password appears in the etcd output as readable ASCII inside the serialized object. By default Kubernetes Secrets are stored in etcd **unencrypted**; the only difference from a ConfigMap is base64 encoding of values, separate RBAC-relevant resource type, and the fact that they are not written to the node's disk in the usual case (kubelet keeps them in tmpfs). Anyone with etcd file access, an etcd client certificate, or an etcd backup snapshot reads them in the clear.

**A1.2** base64 is a reversible encoding with no key. It exists so binary values can be embedded in JSON/YAML. Anyone holding the encoded string holds the secret.

**A1.3** Both need `get` on `secrets`. `describe` merely chooses not to print values client-side — the API response contained them either way. There is no read permission that returns a Secret's metadata but hides its data, so "let them describe the Secret" is not a lesser privilege than "let them read it".

**A1.4** `stringData` is write-only: the API server base64-encodes it into `data` and the stored object shows only `data`. If a key appears in both, the `stringData` value wins.

**A1.5** `echo` appends a newline, so `--from-file` on such a file stores `S3cr3t-P@ss\n`. The application then authenticates with a trailing newline and fails, or the operator adds a `tr -d '\n'` workaround. Use `echo -n`, `printf`, or `--from-literal`.

### Exercise 2

**A2.1** `k8s:enc:secretbox:v1:key1:` followed by ciphertext. Components: the `k8s:enc:` marker, the provider name (`secretbox`), the provider's internal version, and the **key name** from the configuration — which is how the API server knows which key to use for decryption.

**A2.2** The **first** provider in the list is used for **writes**; all listed providers are tried for **reads**. `identity` means "no encryption". Putting it first would make every write plaintext again while still successfully decrypting old data — encryption silently disabled with no error.

**A2.3** Encryption happens on write. Objects already in etcd are untouched until something rewrites them. Step 7 reads every Secret and `replace`s it, forcing a write through the new provider so it is re-serialized encrypted. You must repeat this after any key rotation that retires the old key.

**A2.4** It mitigates **offline** access to the datastore: stolen etcd volumes, etcd backup snapshots, direct etcd client access, and disk forensics. It does **not** protect against anyone authorized through the API server — RBAC is still your only control there — nor against a compromised API server, which holds the key.

**A2.5** With automatic reload you can add a new key, reorder keys, or change which resources are covered by editing `enc.yaml` — the API server picks it up without a restart (a health/reload metric reflects the outcome). Adding or removing the `--encryption-provider-config` flag itself, or the volume mount, still requires the static Pod to restart.

**A2.6** `aescbc` uses CBC mode without authenticating the ciphertext, which exposes it to padding-oracle-style attacks; `secretbox` and AES-GCM are authenticated. KMS v2 is preferred because the data-encryption keys are wrapped by an external KMS, so the root key never sits in a file on the control plane node, and it supports rotation and per-object DEKs with far less operational risk.

**A2.7** (1) Edit `enc.yaml` so `identity: {}` becomes the first provider while keeping the old key listed after it; (2) let the config reload (or restart the API server); (3) rewrite all Secrets with `kubectl get secrets -A -o json | kubectl replace -f -` so they are stored in plaintext; (4) only then remove the key material and the flag. Removing the key before step 3 makes existing Secrets permanently unreadable.

### Exercise 3

**A3.1** Any of: the full environment is readable via `/proc/<pid>/environ` by any process in the container (and by anything sharing the PID namespace); env is inherited by every child process, including debug shells and crash handlers; crash dumps, `docker inspect`/`crictl inspect`, and many application frameworks or error trackers dump the environment into logs; `kubectl exec ... env` requires no Secret RBAC at all, only `pods/exec`. Files can additionally be given restrictive modes and mounted read-only, which env vars cannot.

**A3.2** Only the **volume mount** picked up the new value. Environment variables are resolved once at container start and are immutable for the process lifetime — the Pod must be recreated. Mounted Secrets are refreshed by the kubelet on its sync loop (up to roughly the kubelet sync period plus cache TTL, typically within a minute or two), and the symlink swap makes the update visible without a restart.

**A3.3** The kubelet writes each version of the Secret into a timestamped hidden directory (`..2026_07_29_10_11_12.123456789`), points the symlink `..data` at it, and exposes each key as a symlink into `..data`. Updating means creating a new timestamped directory and atomically re-pointing `..data`, so a reader never observes a half-written set of keys — all keys change together or not at all.

**A3.4** `subPath`. A `subPath` mount is resolved once at container start and is **never** updated by the kubelet, which silently defeats Secret rotation. Use a dedicated mount directory plus `items` instead.

**A3.5** The projected service account token is a credential to the Kubernetes API itself. Left mounted in a workload that never calls the API, it is free lateral-movement material for anyone who achieves code execution in that container. Disabling it removes a Secret you did not need to hand out — set it on the ServiceAccount or the Pod, and opt back in explicitly per workload.

**A3.6** Security: nothing can modify the Secret in place, so an attacker with `patch`/`update` on Secrets cannot swap credentials under a running workload, and rotation becomes an explicit, auditable create-and-redeploy. Performance: the kubelet stops watching that Secret for changes, which materially reduces API server load in large clusters. To roll the value you must delete the Secret and create it again (then restart consumers), or create a new versioned Secret name and update the workload to reference it — the latter is the safer pattern.

**A3.7** `defaultMode` is subject to the container's umask semantics only indirectly; more importantly it interacts with `fsGroup` and with `runAsUser` — the files are owned by root with the `fsGroup` GID, so a non-root user reads them via group membership. With `0400` and no matching group bit the process may be unable to read its own Secret; `0440` plus `fsGroup` is the usual working combination. Per-key `items[].mode` overrides `defaultMode`.

### Exercise 4

**A4.1** `resourceNames` filters by the object name taken from the request path. `list` and `watch` requests are made against the **collection** (`/api/v1/namespaces/secret-lab/secrets`) and carry no object name, so a rule with `resourceNames` cannot match them — the request is simply denied. There is no supported way to say "list only these Secrets" in RBAC; field/label selectors are not authorization boundaries.

**A4.2** It received the ability to list **every** Secret in the namespace, including their data — `resourceNames` did not narrow it. People assume `resourceNames` scopes all verbs in the rule; in practice granting `list` on `secrets` in a namespace is equivalent to granting read on all Secrets in that namespace.

**A4.3** Anyone who can create Pods in a namespace can mount **any** Secret in that namespace into a container they control and read it — the kubelet, not the requester, performs the read. So `create pods` in `secret-lab` is a superset of read access to all Secrets in `secret-lab`, making the carefully scoped Role cosmetic. The same applies to controllers that create Pods on the user's behalf.

**A4.4** Options include: keep Secrets in namespaces where untrusted principals cannot create Pods (namespace isolation as the real boundary); use an admission policy (ValidatingAdmissionPolicy, Kyverno, Gatekeeper) that restricts which Secrets a Pod may reference; source the credential from an external store with per-workload identity so a Pod spec alone is not enough; require the workload identity to authenticate to the store with a bound, audience-scoped token.

**A4.5** `auth can-i --as` asks the API server's authorizer the same question a real request would ask, so it reflects the effective union of all bindings — better evidence than reading Roles by hand. It will not tell you about indirect paths (Pod creation, controllers, impersonation, escalation via `bind`/`escalate`), nor about anything enforced by admission rather than authorization, and it requires impersonation privileges to run.

**A4.6** `cluster-admin`, `system:kube-controller-manager`, `system:controller:*` (many controllers legitimately read Secrets), and `system:kubelet-...`-style roles will show up. Triage by asking: is this an aggregated/system role shipped by Kubernetes, and are the bindings limited to system identities? Then focus on custom ClusterRoles with `secrets` + `get/list/*`, wildcards (`resources: ["*"]`), and any ClusterRoleBinding placing human users or a broad group such as `system:authenticated` into them.

### Exercise 5

**A5.1** The `kubernetes.io` claim contains the `namespace`, `serviceaccount` (name and UID), **and** `pod` (name and UID) — that pod binding is what makes it a bound token. It also carries `exp` (a short expiry, one hour by default, auto-refreshed by the kubelet) and `aud` set to the API server's identifier. If the Pod is deleted, the token stops being valid even before `exp`.

**A5.2** Kubernetes stopped auto-creating permanent token Secrets for ServiceAccounts; the kubelet now obtains tokens through the TokenRequest API and projects them into the Pod. The improvement is that credentials are short-lived, bound to a specific Pod, audience-scoped, and never persisted as a cluster object an attacker can list and reuse indefinitely.

**A5.3** The projected token expires in 600 seconds, is only accepted by an audience of `vault`, and dies with the Pod — a leak is a narrow, time-boxed window against one system. The legacy token Secret has **no** `exp`, a general audience, and no pod binding: it is a permanent cluster credential for that ServiceAccount, reusable from anywhere until the Secret is deleted, and it is itself a Secret sitting in etcd.

**A5.4** Audience binding stops a token issued for one relying party from being replayed against another. Without it, a token handed to Vault could be turned around and used directly against the Kubernetes API (or a second external service) by whoever receives it — a confused-deputy problem. With `aud: vault`, the API server rejects it for any other audience.

**A5.5** Not contradictory — it is the recommended combination. `automountServiceAccountToken: false` suppresses the *default* general-purpose API token at `/var/run/secrets/kubernetes.io/serviceaccount`, while the projected volume supplies exactly one token with a narrow audience and lifetime at a path you chose. The workload gets the credential it needs and nothing more.

**A5.6** The relying party (Vault, or any service integrating with Kubernetes auth) calls `TokenReview` with the audiences it expects; the API server's authentication layer performs the validation. It stops token replay across audiences, and it also catches expired, revoked-by-pod-deletion, and forged tokens.

### Exercise 6

**A6.1** At `Request` or `RequestResponse` level the audit backend writes the object body into the log — for a Secret that means the base64-encoded values land in a plaintext log file, usually with wider read access and longer retention than etcd, and often shipped off-cluster to a log aggregator. `Metadata` records who did what, to which object, when, and from where, without the payload. (The API server special-cases some of this, but relying on that instead of writing the rule correctly is a finding.)

**A6.2** Audit rules are evaluated top-down and the **first match wins**. A catch-all `Metadata` rule at the top would swallow every request, so the RBAC-specific `RequestResponse` rule would never fire and you would lose the detailed record of permission changes. Order specific rules before general ones.

**A6.3** No. Once a Secret is mounted, reads happen inside the container against a tmpfs file and never touch the API server, so there is no audit event. The audit log shows the kubelet's/API server's Secret access at Pod admission time, not per-read usage. To reason about who accessed what you correlate the Secret's audit trail with Pod creation events (which Pod referenced which Secret, created by which principal) and with runtime tooling such as Falco watching opens under the mount path.

**A6.4** Common ones: CI/CD job logs and build artifacts; the cluster itself, where the value is visible in `kubectl get pod -o yaml` to anyone with `get pods` (a much more widely granted permission than `get secrets`); GitOps repository history and rendered Helm manifests; container images if the manifest is baked in; ticketing systems and chat where manifests get pasted.

**A6.5** The material lives in the external store (Vault, a cloud secrets manager, an HSM-backed KMS), and the CSI driver delivers it into the Pod's tmpfs mount at start. This removes the etcd exposure entirely — there is no Kubernetes Secret object to read from etcd, from an etcd backup, or via `get secrets` RBAC.

**A6.6** You gain compatibility: workloads that need `envFrom`/`secretKeyRef`, and controllers that expect a Secret object (ingress TLS, image pull secrets), keep working. You give up the main benefit — the value is now written into etcd again, subject to Secret RBAC and to whatever encryption-at-rest you configured, and it becomes a second copy that can drift from the source of truth. Enable it only where a real consumer requires a Secret object.

**A6.7** A defensible ranking: (1) **tight RBAC / namespace isolation**, because the authorized-API-caller path is the one attackers actually use, and it is the only control that limits who can read a Secret at all — including via the Pod-creation escalation; (2) **external store with workload identity**, which shrinks what exists in the cluster to short-lived, per-workload material; (3) **file-based mounts with restrictive modes and no `subPath`**, which shrinks in-container exposure and enables rotation; (4) **encryption at rest**, which is necessary and often mandated but only addresses offline datastore compromise while the API server holds the key. The top choice is RBAC because the other three all assume an attacker who has not yet obtained legitimate API access — RBAC is what decides that.

</details>

---

## References

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Secrets — https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Encrypting Confidential Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Using a KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Kubernetes — Good practices for Kubernetes Secrets — https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Kubernetes — Distribute Credentials Securely Using Secrets — https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Kubernetes — Projected Volumes — https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Kubernetes — Managing Service Accounts / Bound tokens — https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes Secrets Store CSI Driver — https://secrets-store-csi-driver.sigs.k8s.io/