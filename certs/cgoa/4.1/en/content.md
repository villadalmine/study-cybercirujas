# CGOA 4.1 — GitOps Security & Observability

**Domain weight: 25%** — the largest single block in the exam and, not by coincidence, the part of GitOps that most production platforms get wrong first. Everything before this domain teaches you how to make a cluster converge on a declared state. This domain asks a harder question: *who is allowed to declare it, how do you prove they did, and how do you know the loop is still running?*

---

## 1. The production problem

### 1.1 What actually changes when the cluster pulls

In a classic CI/CD push pipeline, the CI runner holds the keys. It has a kubeconfig, usually with broad rights, usually for every environment, and it authenticates from outside the cluster's trust boundary. The security posture of your production cluster is therefore the security posture of your CI system — its plugins, its third-party actions, its shared runners, its secret store, and every engineer who can open a PR that modifies a pipeline file.

GitOps inverts the direction: an in-cluster agent (Argo CD's application-controller, Flux's source-controller + kustomize-controller) pulls the desired state and reconciles it. No external system holds cluster credentials. That single inversion removes a whole class of attacks — but it does not remove risk, it **relocates** it. Three new concentrations of privilege appear:

1. **The repository becomes a production control plane.** A merge is a deploy. `git push --force` to a tracked branch is now a change-management event with the same blast radius as `kubectl apply -f`.
2. **The reconciler is the most privileged workload in the cluster.** By default, both Argo CD and Flux install with an identity capable of creating and deleting arbitrary resources across all namespaces. A tenant who can get a manifest into the repo can get it applied *by that identity*.
3. **The loop is now infrastructure that can silently stop.** A push pipeline fails loudly — the build turns red. A pull loop fails quietly: the last-applied state keeps serving traffic, the `Kustomization` goes `Ready=False` in a namespace nobody watches, and eleven days later a rollback "does nothing" because reconciliation has been broken since the credential expired.

Point 3 is why security and observability are one exam domain rather than two. **In GitOps, observability is a security control**: the only evidence that the declared state is the running state is a metric emitted by the reconciler. Drift you cannot see is drift you cannot attribute.

### 1.2 Threat model of the GitOps loop

Walk the pipeline stage by stage and enumerate what an adversary — external or a careless insider — can do at each hop.

| # | Stage | Threat | Realistic vector | Primary control | Verifiable by |
|---|---|---|---|---|---|
| T1 | Developer → Git | Unauthorized change to desired state | Compromised laptop, stolen PAT, no review requirement | Branch protection + required reviews + CODEOWNERS | Provider API / `gh api` |
| T2 | Developer → Git | Change attributed to the wrong author | Git author fields are free text; anyone can set `user.email` | Mandatory commit signing (GPG / SSH / gitsign) | `git log --show-signature`, Argo CD `signatureKeys`, Flux `spec.verify` |
| T3 | CI → Registry | Malicious or unreviewed image published | Compromised build step, dependency confusion | Signed images + provenance attestations (SLSA) | `cosign verify`, `cosign verify-attestation` |
| T4 | Git → Cluster | Man-in-the-middle on repo fetch | Missing `known_hosts`, TLS verification disabled | SSH host-key pinning, CA bundle, no `insecure: true` | source-controller logs, `argocd cert list` |
| T5 | Repo content → Cluster | Privilege escalation via manifest | Tenant commits a `ClusterRoleBinding` to `cluster-admin` | Reconciler impersonation + admission policy | Kyverno/Gatekeeper audit, K8s audit log |
| T6 | Repo content → Cluster | Cross-tenant write | Tenant A's `Kustomization` targets namespace B | `--no-cross-namespace-refs`, AppProject destinations | `flux get kustomizations -A`, Argo CD project validation |
| T7 | Secrets | Plaintext credentials in Git | "Temporary" `Secret` manifest committed | SOPS / SealedSecrets / ESO — never plaintext | `check_citations`-style repo scan, gitleaks, ESO status |
| T8 | Cluster → Git | Exfiltration via reconciler egress | Reconciler pod given unrestricted egress | NetworkPolicy egress allowlist | `kubectl exec` probe, CNI flow logs |
| T9 | The loop itself | Silent stop / suspend | Expired deploy key, `flux suspend` left on, controller OOM | Alerting on `Ready=False` **and** on suspension **and** on staleness | Prometheus rules (§7.4) |
| T10 | The loop itself | Drift fight / thrash | HPA vs declared `replicas` | `ignoreDifferences` / server-side apply field ownership | Reconcile-rate metric, event flood |

Two of these deserve emphasis because they are the ones exam questions and real incidents both circle around:

- **T2 (attribution).** Git author and committer identity are unauthenticated strings. `git commit --author="Alice <alice@acme.io>"` is not a lie the tool will catch. Cryptographic signing is the only mechanism that makes the audit trail an audit trail rather than a log of self-asserted claims.
- **T9 (liveness).** "Synced" is a statement about the last successful reconciliation, not about now. A `Kustomization` whose source has not been fetched in three days can still report `Ready=True` on a stale revision if you read only the wrong field.

### 1.3 Push vs pull: the security trade-off, stated honestly

| Dimension | Push (CI holds kubeconfig) | Pull (in-cluster agent) |
|---|---|---|
| Cluster credential location | External CI secret store | Never leaves the cluster |
| Attack surface | CI runners, plugins, marketplace actions | Reconciler + repo credential |
| Network requirement | CI must reach API server (often public / bastion) | Cluster egress to Git/OCI only; API server can be private |
| Credential rotation | Rotate kubeconfig in *n* CI systems | Rotate one deploy key or workload identity |
| Drift correction | None — only at next pipeline run | Continuous; detection interval is a tunable |
| Failure visibility | High (red build) | **Low by default** — must be instrumented |
| Blast radius of agent compromise | CI compromise = all clusters | Agent compromise = that cluster (unless it's a hub) |
| Multi-cluster fan-out | *n* credentials in CI | *n* agents, or one hub with *n* credentials (re-centralizes risk) |
| Ephemeral/preview envs | Simple | Needs ApplicationSet / bootstrap automation |

The honest reading: pull is a genuine improvement on credential custody and drift, and a genuine regression on default-visibility. Domain 4.1 exists to make you close the second gap while you enjoy the first.

### 1.4 Where this maps to the OpenGitOps principles

The four principles (declarative, versioned & immutable, pulled automatically, continuously reconciled) are not security controls by themselves, but each one creates a security *affordance* — and each affordance requires an explicit control to be realized:

| Principle | Security affordance | Control that realizes it | Observability signal |
|---|---|---|---|
| Declarative | State is reviewable before it exists | PR review, policy-as-code in CI | Policy pass/fail rate |
| Versioned & immutable | Every state is attributable and restorable | Signed commits, protected refs, signed OCI artifacts by digest | Signature verification result |
| Pulled automatically | No external credential holder | Reconciler identity + impersonation | Source fetch success, artifact revision |
| Continuously reconciled | Unauthorized in-cluster change is transient | Drift correction (`selfHeal` / SSA) | Drift events, reconcile duration |

---

## 2. Trust and the chain of custody

### 2.1 Git is the root of trust — which is exactly the problem

"Git is the source of truth" is a statement about *authority*, not about *authenticity*. Authority says: whatever is in `main` is what the cluster should run. Authenticity asks: is what is in `main` what the humans who are accountable for `main` actually approved?

The gap between those two is closed by three layers, and you need all three:

1. **Forge-side policy** — branch protection, required approvals, CODEOWNERS, disallowed force-push, required status checks. Cheap, effective, and *not verifiable from inside the cluster*. A repo administrator can turn it off; the reconciler will never know.
2. **Cryptographic signing** — commit or tag signatures verified by the reconciler at fetch time. This is the only layer inside the cluster's own trust boundary.
3. **Admission policy** — final-line enforcement of what may exist, independent of how it got there.

Layer 2 is the one CGOA cares about most, because it is the one unique to GitOps.

### 2.2 Signing options compared

| Mechanism | Key material | Verified by | Revocation story | Ops cost | Notes |
|---|---|---|---|---|---|
| GPG commit signing | Long-lived private key per developer | Flux `GitRepository.spec.verify`, Argo CD `AppProject.spec.signatureKeys` | Key expiry + removal from allowlist | High (key distribution, expiry, HSM/YubiKey) | The classic; both tools support it natively |
| SSH commit signing (`gpg.format=ssh`) | Reuse existing SSH auth key | Forge-side; **not** natively verified by Flux/Argo CD reconcilers | Remove from allowed-signers | Low | Great for forge policy, weak for in-cluster verification |
| Sigstore `gitsign` (keyless) | Ephemeral cert, OIDC identity, Rekor transparency log | Forge / CI; in-cluster via policy tooling | Identity revoked at IdP; log is append-only | Medium | No key custody at all; requires OIDC identity per signer |
| Signed **tags** only | One release key, held by release automation | Flux `verify.mode: Tag` / `TagAndHEAD` | Rotate the release key | Low | Strong fit for promotion boundaries |
| Signed **OCI artifacts** (`cosign` + Flux `OCIRepository`) | Keyless or KMS key | Flux `spec.verify.provider: cosign`, Kyverno `verifyImages` | OIDC identity / KMS key policy | Medium | Verifies the *packaged config*, not just the commit |

Practical guidance for a platform team: require SSH signing for every developer (forge-enforced, near-zero friction), and require a **signed tag or signed OCI artifact** at the production promotion boundary, verified in-cluster. Per-developer GPG verified by the reconciler is defensible but rarely survives contact with key expiry at scale.

### 2.3 Flux: verifying signatures at fetch time

Import the allowed public keys and pin them to the source:

```console
$ gpg --export --armor 3CF6A1B4C0DE9A17 > release-signing.asc
$ gpg --export --armor 9B2E4D1A77C0F332 >> release-signing.asc

$ kubectl -n flux-system create secret generic git-signing-keys \
    --from-file=release-signing.asc=./release-signing.asc
secret/git-signing-keys created
```

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 1m
  timeout: 60s
  url: ssh://git@github.com/acme/platform-config
  ref:
    # Track signed release tags only, never a moving branch, for production.
    semver: ">=1.0.0 <2.0.0"
  secretRef:
    name: platform-config-auth      # identity + known_hosts, see §3
  verify:
    # HEAD  -> verify the commit at the resolved ref
    # Tag   -> verify the annotated tag object
    # TagAndHEAD -> both must verify (strongest)
    # NOTE: pre-Flux-2.1 the only accepted value was the lowercase "head".
    mode: TagAndHEAD
    secretRef:
      name: git-signing-keys
  ignore: |
    # Never let non-manifest content into the artifact.
    /*
    !/clusters/prod/
    !/apps/
    /**/*.md
    /**/*.png
```

A failed verification is a hard stop — the artifact is never produced, so nothing downstream can apply an unverified revision:

```console
$ flux get sources git platform-config
NAME            	REVISION	SUSPENDED	READY	MESSAGE
platform-config 	        	False    	False	failed to verify the signature of 'v1.4.2': unable to verify Git tag: object not signed by a trusted key

$ kubectl -n flux-system get gitrepository platform-config \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq
{
  "lastTransitionTime": "2026-08-18T09:12:44Z",
  "message": "failed to verify the signature of 'v1.4.2': unable to verify Git tag: object not signed by a trusted key",
  "observedGeneration": 7,
  "reason": "VerificationError",
  "status": "False",
  "type": "Ready"
}
```

### 2.4 Argo CD: signature enforcement per project

Argo CD enforces at the **AppProject** level, which is the correct granularity — production projects require signatures, sandbox projects need not.

```console
$ kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.admin\.enabled}'
false

# GPG verification is off unless the controller/repo-server sees this env var.
$ kubectl -n argocd set env statefulset/argocd-application-controller ARGOCD_GPG_ENABLED=true
statefulset.apps/argocd-application-controller env updated

$ argocd gpg add --from ./release-signing.asc
Created 2 GPG public keys

$ argocd gpg list
KEYID             TYPE  IDENTITY
3CF6A1B4C0DE9A17  rsa   ACME Release Bot <release@acme.io>
9B2E4D1A77C0F332  rsa   ACME Platform SRE <platform@acme.io>
```

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Production workloads. Signed revisions only.
  sourceRepos:
    - https://github.com/acme/platform-config
    - https://acme.github.io/charts
  destinations:
    - server: https://kubernetes.default.svc
      namespace: payments
    - server: https://kubernetes.default.svc
      namespace: checkout
  # Only these cluster-scoped kinds may ever be created by this project.
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
    - group: networking.k8s.io
      kind: IngressClass
  # Explicitly deny escalation primitives even inside allowed namespaces.
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  # Every revision synced by this project must carry a signature from one of these keys.
  signatureKeys:
    - keyID: 3CF6A1B4C0DE9A17
    - keyID: 9B2E4D1A77C0F332
  orphanedResources:
    warn: true
    ignore:
      - group: ""
        kind: ServiceAccount
        name: default
  syncWindows:
    - kind: deny
      schedule: "0 22 * * 5"        # Friday 22:00
      duration: 58h                 # through Monday 08:00
      applications:
        - "*"
      manualSync: true              # break-glass still possible, and audited
      timeZone: "Europe/Madrid"
  roles:
    - name: deployer
      description: CI identity, may sync but never mutate the spec
      policies:
        - p, proj:prod:deployer, applications, sync, prod/*, allow
        - p, proj:prod:deployer, applications, get, prod/*, allow
      jwtTokens:
        - iat: 1755500000
```

Verification of the deny path:

```console
$ argocd app sync payments
FATA[0001] rpc error: code = InvalidArgument desc = application repository revision
'9f3c2ab' is not signed by a key in the project's allowed signature key list
```

### 2.5 Extending the chain to artifacts: OCI + cosign

Commit signing proves who wrote the YAML. It does not prove which container image is safe to run. Close the loop by (a) publishing the rendered config as a signed OCI artifact, and (b) verifying image signatures at admission.

```console
$ flux push artifact oci://ghcr.io/acme/platform-config:v1.4.2 \
    --path="./clusters/prod" \
    --source="$(git config --get remote.origin.url)" \
    --revision="v1.4.2@sha1:$(git rev-parse HEAD)"
► pushing artifact to ghcr.io/acme/platform-config:v1.4.2
✔ artifact successfully pushed to ghcr.io/acme/platform-config@sha256:6f0a1c...e42b

$ cosign sign --yes ghcr.io/acme/platform-config@sha256:6f0a1c...e42b
tlog entry created with index: 148829301
```

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/acme/platform-config
  ref:
    semver: ">=1.4.0 <2.0.0"
  secretRef:
    name: ghcr-pull
  verify:
    provider: cosign
    # Keyless: bind the artifact to the identity of the workflow that produced it.
    matchOIDCIdentity:
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/acme/platform-config/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

```console
$ flux get sources oci platform-config
NAME           	REVISION                       	SUSPENDED	READY	MESSAGE
platform-config	v1.4.2@sha256:6f0a1c...e42b   	False    	True 	stored artifact for digest 'v1.4.2@sha256:6f0a1c...e42b'
```

If verification fails, the message names the reason precisely:

```console
$ flux get sources oci platform-config
NAME           	REVISION	SUSPENDED	READY	MESSAGE
platform-config	        	False    	False	failed to verify the signature of 'ghcr.io/acme/platform-config:v1.4.3': no matching signatures: none of the expected identities matched what was in the certificate
```

---

## 3. Repository credentials: the reconciler's identity

The reconciler needs read access to Git and/or an OCI registry. That credential is a production secret with an interesting property: it is the *only* long-lived external credential in a well-built pull-based system, which makes it worth over-engineering.

| Credential type | Scope | Rotation | Auditability | Verdict |
|---|---|---|---|---|
| Personal access token | Everything the human can see | Manual, breaks when they leave | Attributed to a human, wrongly | **Never** |
| Machine-user PAT | Repos the bot is added to | Manual, calendar-driven | Bot identity, decent | Acceptable stop-gap |
| Deploy key (SSH, read-only) | **One repository** | Manual, per repo | Per-repo, excellent | Good default |
| GitHub App / GitLab group token | Selected repos, fine-grained | Short-lived installation tokens | App-level, excellent | Best for many repos |
| Cloud workload identity (OIDC → IAM) | Registry/artifact store | Automatic, no static secret | IAM audit trail | Best where supported |

**Rule: one read-only deploy key per repository per cluster.** A single org-wide key means one compromised cluster reads every repo, and rotation becomes a change-freeze-sized project.

### 3.1 Flux: SSH identity with host-key pinning

```console
$ flux create secret git platform-config-auth \
    --namespace=flux-system \
    --url=ssh://git@github.com/acme/platform-config \
    --ssh-key-algorithm=ecdsa \
    --ssh-ecdsa-curve=p384
✚ generating GitRepository authentication secret
► public key: ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQ...
✔ authentication configured

$ kubectl -n flux-system get secret platform-config-auth -o jsonpath='{.data}' | jq 'keys'
[
  "identity",
  "identity.pub",
  "known_hosts"
]
```

The `known_hosts` key is the control that defeats T4. Verify it is populated and matches the forge's published fingerprint — an empty or wildcarded `known_hosts` silently disables host verification:

```console
$ kubectl -n flux-system get secret platform-config-auth \
    -o jsonpath='{.data.known_hosts}' | base64 -d | ssh-keygen -lf -
3072 SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s github.com (RSA)
```

### 3.2 Argo CD: repository credential as a labelled Secret (declarative, not `argocd repo add`)

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: repo-platform-config
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ssh://git@github.com/acme/platform-config
  # sshPrivateKey is injected by External Secrets — see §5.3. Never inline it.
  project: prod
```

```console
$ argocd repo list
TYPE  NAME             REPO                                              INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE  PROJECT
git   platform-config  ssh://git@github.com/acme/platform-config         false     false  false  true   Successful           prod

$ argocd cert list --cert-type ssh
HOSTNAME    TYPE  SUBTYPE              FINGERPRINT/SUBJECT
github.com  ssh   ecdsa-sha2-nistp256  SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
```

`INSECURE=false` and a populated `argocd cert list` are the two things to assert in a hardening review. `insecure: "true"` on a repo secret disables TLS/host verification and is a finding, not a workaround.

---

## 4. Least privilege for the reconciler

This is the highest-value control in the entire domain and the one most often skipped, because the default install works and the hardened one requires thought.

### 4.1 The escalation you are defending against

A tenant with write access to `apps/team-a/` in the config repo commits:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: team-a-helper
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
```

If the reconciler runs as `cluster-admin`, this applies successfully. Kubernetes' own privilege-escalation prevention does not save you: the reconciler genuinely *has* `cluster-admin`, so granting it is permitted. The tenant never needed cluster access — they needed repo access, and the reconciler laundered it into cluster-admin.

### 4.2 Flux: impersonation as the default

Flux's kustomize-controller and helm-controller impersonate a ServiceAccount when applying. Configure the enforcement flags at bootstrap so that *omitting* `serviceAccountName` is a failure rather than a fallback to full privilege.

```yaml
# clusters/prod/flux-system/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
patches:
  - target:
      kind: Deployment
      name: "(kustomize-controller|helm-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --no-cross-namespace-refs=true
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --no-remote-bases=true
      # Any Kustomization without spec.serviceAccountName falls back to the
      # ServiceAccount named "default" IN ITS OWN NAMESPACE, which has no rights.
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --default-service-account=default
  - target:
      kind: Deployment
      name: "(source-controller|notification-controller|image-reflector-controller|image-automation-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --watch-all-namespaces=true
```

Tenant onboarding is then a namespace, a ServiceAccount, a namespaced Role, and a `Kustomization` that impersonates it:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    toolkit.fluxcd.io/tenant: team-a
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: team-a-reconciler
  namespace: team-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-a-reconciler
  namespace: team-a
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "services", "serviceaccounts", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Deliberately absent: rbac.authorization.k8s.io, all cluster-scoped kinds,
  # and any *.k8s.io admission/policy group.
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-a-reconciler
  namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: team-a-reconciler
subjects:
  - kind: ServiceAccount
    name: team-a-reconciler
    namespace: team-a
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: team-a
  namespace: team-a
spec:
  interval: 5m
  url: https://github.com/acme/team-a-config
  ref:
    branch: main
  secretRef:
    name: team-a-git-auth
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: team-a
  namespace: team-a
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  path: ./deploy/prod
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: team-a          # cross-namespace ref would be rejected by the flag above
  # The whole point: apply AS the tenant identity, not as the controller.
  serviceAccountName: team-a-reconciler
  targetNamespace: team-a
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: api
      namespace: team-a
```

Proof that the escalation is now blocked:

```console
$ flux -n team-a get kustomizations
NAME  	REVISION	SUSPENDED	READY	MESSAGE
team-a	        	False    	False	Kustomization/team-a/team-a dry-run failed: clusterrolebindings.rbac.authorization.k8s.io "team-a-helper" is forbidden: User "system:serviceaccount:team-a:team-a-reconciler" cannot create resource "clusterrolebindings" in API group "rbac.authorization.k8s.io" at the cluster scope

$ kubectl auth can-i create clusterrolebindings \
    --as=system:serviceaccount:team-a:team-a-reconciler
no
```

Note that the failure occurs at **dry-run**, before any partial apply. Flux server-side dry-runs the whole set first, so a forbidden resource aborts the transaction rather than leaving half the manifests applied.

### 4.3 Argo CD: projects, RBAC, and namespaced install

Argo CD's isolation model is the `AppProject` (what an Application may reference and create) plus `argocd-rbac-cm` (who may act on Applications).

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Anything not explicitly allowed is denied outright.
  policy.default: ""
  scopes: '[groups, email]'
  policy.csv: |
    # --- roles -------------------------------------------------------------
    p, role:platform-sre, applications, *,        */*,      allow
    p, role:platform-sre, clusters,     get,      *,        allow
    p, role:platform-sre, repositories, *,        *,        allow
    p, role:platform-sre, projects,     *,        *,        allow
    p, role:platform-sre, exec,         create,   */*,      deny

    p, role:team-a-dev,   applications, get,      team-a/*, allow
    p, role:team-a-dev,   applications, sync,     team-a/*, allow
    p, role:team-a-dev,   applications, action/*, team-a/*, allow
    p, role:team-a-dev,   applications, delete,   team-a/*, deny
    p, role:team-a-dev,   applications, override, team-a/*, deny
    p, role:team-a-dev,   logs,         get,      team-a/*, allow

    p, role:auditor,      applications, get,      */*,      allow
    p, role:auditor,      projects,     get,      *,        allow

    # --- bindings (SSO groups) --------------------------------------------
    g, acme:platform-sre, role:platform-sre
    g, acme:team-a,       role:team-a-dev
    g, acme:security,     role:auditor
```

Argo CD ships a policy simulator — use it in CI so an RBAC change is reviewed with evidence, not with confidence:

```console
$ argocd admin settings rbac can acme:team-a sync applications 'team-a/payments' \
    --policy-file rbac-cm.yaml --namespace argocd
Yes

$ argocd admin settings rbac can acme:team-a delete applications 'team-a/payments' \
    --policy-file rbac-cm.yaml --namespace argocd
No

$ argocd admin settings rbac can acme:team-a sync applications 'prod/checkout' \
    --policy-file rbac-cm.yaml --namespace argocd
No

$ argocd admin settings rbac validate --policy-file rbac-cm.yaml
Policy is valid.
```

Harden the server itself in `argocd-cm`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.acme.io
  admin.enabled: "false"                 # local admin off; SSO is the only path
  users.anonymous.enabled: "false"
  exec.enabled: "false"                  # no terminal into workloads from the UI
  users.session.duration: "8h"
  application.instanceLabelKey: argocd.argoproj.io/instance
  # Restrict which resources Argo CD tracks at all (reduces cache + blast radius)
  resource.exclusions: |
    - apiGroups: ["cilium.io"]
      kinds: ["CiliumIdentity"]
      clusters: ["*"]
    - apiGroups: ["*"]
      kinds: ["Event", "EndpointSlice"]
      clusters: ["*"]
  dex.config: |
    connectors:
      - type: oidc
        id: acme-idp
        name: ACME SSO
        config:
          issuer: https://idp.acme.io
          clientID: $oidc.acme.clientId
          clientSecret: $oidc.acme.clientSecret
          requestedScopes: ["openid", "profile", "email", "groups"]
```

### 4.4 Side-by-side isolation model

| Control | Flux | Argo CD |
|---|---|---|
| Apply-time identity | SA impersonation per `Kustomization` (`spec.serviceAccountName`) | Controller SA, or per-destination cluster credential; **no per-app impersonation by default** |
| Enforce identity is set | `--default-service-account` | Not applicable — use one Argo instance per tenant, or `AppProject` restrictions |
| Cross-namespace reference | Blocked by `--no-cross-namespace-refs` | `AppProject.spec.destinations` / `sourceNamespaces` |
| Allowed sources | `GitRepository` must exist in tenant NS | `AppProject.spec.sourceRepos` |
| Allowed kinds | Whatever the impersonated Role permits | `clusterResourceWhitelist` / `namespaceResourceBlacklist` |
| Human RBAC | Native Kubernetes RBAC on CRs | `argocd-rbac-cm` (Casbin), separate from K8s RBAC |
| Remote bases from the internet | `--no-remote-bases=true` | Repo allowlist + `kustomize.buildOptions` hardening |
| Time-based gating | `spec.suspend` (manual) | `AppProject.spec.syncWindows` |

The structural difference matters for the exam: **Flux's tenancy is Kubernetes RBAC**; **Argo CD's tenancy is an application-layer authorization system on top of a shared privileged controller**. Neither is wrong, but the Argo CD hardening story usually ends in "one Argo CD instance per trust zone" for genuinely hostile multi-tenancy.

### 4.5 Egress containment for the reconciler (T8)

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: flux-controllers-egress
  namespace: flux-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: flux
  policyTypes: ["Egress"]
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Kubernetes API server
    - to:
        - ipBlock:
            cidr: 10.100.0.1/32
      ports:
        - protocol: TCP
          port: 443
    # Git forge + registry, via the egress proxy only
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: egress
          podSelector:
            matchLabels:
              app: egress-proxy
      ports:
        - protocol: TCP
          port: 3128
    # Intra-namespace (source-controller artifact HTTP server on :9090)
    - to:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 9090
```

---

## 5. Secrets in a workflow whose premise is "everything is in Git"

The declarative principle says all state lives in the repo. Secrets are state. This is the collision that every GitOps adoption hits in week two.

### 5.1 The five viable answers, compared

| Approach | Ciphertext in Git? | Trust anchor | Rotation without a commit | Works offline / air-gapped | Key failure mode |
|---|---|---|---|---|---|
| **SealedSecrets** | Yes | Controller's private key, in-cluster | No — re-seal and commit | Yes | Losing the controller key loses every sealed secret; per-cluster ciphertext |
| **SOPS + age** | Yes | age private key as a K8s Secret | No | Yes | The age key itself is a bootstrap secret you must protect out-of-band |
| **SOPS + cloud KMS** | Yes | Cloud KMS / IAM | No | No | KMS outage or IAM drift blocks all reconciliation |
| **External Secrets Operator** | **No** — only references | External store (Vault, cloud SM) | **Yes** — `refreshInterval` picks it up | No | Store outage; ESO becomes a critical dependency |
| **Vault Agent / CSI driver** | No — mounted at pod start | Vault + workload identity | Yes (with templating/restart) | No | Secret never becomes a K8s `Secret` object — some workloads can't consume it |

**Decision heuristic:** if the secret is *cluster bootstrap* material (the Git deploy key, the ESO credential, the age key itself), use SOPS or SealedSecrets — you cannot depend on an operator that has not been installed yet. For everything *application-level*, use ESO, because rotation without a commit is worth more than every other property combined.

### 5.2 SOPS + age with Flux, end to end

```console
$ age-keygen -o age.agekey
Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

$ cat age.agekey | kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin
secret/sops-age created

# Store the private key in the org password manager / HSM, then destroy the local copy.
$ shred -u age.agekey
```

`.sops.yaml` at the repo root — this file is what makes encryption *the default* rather than a thing people remember:

```yaml
creation_rules:
  - path_regex: clusters/prod/.*\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
  - path_regex: clusters/staging/.*\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1vy7q9wr3kdqcs8n2m6ldg0rp4uz5xh7ct2j9fw0lqe8dnvs4a3xq7hj2ke
```

```console
$ kubectl -n payments create secret generic payments-db \
    --from-literal=username=payments_rw \
    --from-literal=password='S3cr3t-not-really' \
    --dry-run=client -o yaml > clusters/prod/payments/db-secret.yaml

$ sops --encrypt --in-place clusters/prod/payments/db-secret.yaml

$ head -14 clusters/prod/payments/db-secret.yaml
apiVersion: v1
kind: Secret
metadata:
    name: payments-db
    namespace: payments
type: Opaque
data:
    username: ENC[AES256_GCM,data:2rN9xQ==,iv:8vK1...,tag:pQ==,type:str]
    password: ENC[AES256_GCM,data:mLp0dR6yTt==,iv:cW4z...,tag:9a==,type:str]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
```

Note that `apiVersion`, `kind`, `metadata` and `type` stay in cleartext. That is deliberate and is what `encrypted_regex` buys you: Kustomize can still patch, merge and reference the object, and a reviewer can still see *what* changed without seeing the value.

Wire decryption into the `Kustomization`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/prod/payments
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-config
  serviceAccountName: payments-reconciler
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

Diagnosing the classic failure:

```console
$ flux get kustomizations payments
NAME    	REVISION	SUSPENDED	READY	MESSAGE
payments	        	False    	False	Decryption failed for 'payments-db': failed to decrypt sops data key with provider 'age': no identity matched any of the recipients

$ kubectl -n flux-system get secret sops-age -o jsonpath='{.data}' | jq 'keys'
["age.agekey"]      # correct key name — the controller looks for *.agekey

$ kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' \
    | base64 -d | age-keygen -y
age1vy7q9wr3kdqcs8n2m6ldg0rp4uz5xh7ct2j9fw0lqe8dnvs4a3xq7hj2ke
#  ^ the STAGING public key is in the PROD cluster. Root cause found.
```

### 5.3 External Secrets Operator: rotation without a commit

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets
---
# NOTE: ESO ≥ 0.17 serves the stable external-secrets.io/v1 API; older
# deployments serve v1beta1. Check with: kubectl api-resources | grep external-secrets
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-prod
spec:
  provider:
    vault:
      server: https://vault.internal.acme.io:8200
      path: kv
      version: v2
      caProvider:
        type: ConfigMap
        name: vault-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes/prod
          role: eso-prod
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
  # Fail closed and loudly rather than serving stale material silently.
  retrySettings:
    maxRetries: 5
    retryInterval: "10s"
  conditions:
    - namespaceSelector:
        matchLabels:
          acme.io/environment: prod
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-db
  namespace: payments
spec:
  refreshInterval: 15m
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-prod
  target:
    name: payments-db
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: Opaque
      data:
        DATABASE_URL: >-
          postgres://{{ .username }}:{{ .password }}@pg.payments.svc.cluster.local:5432/payments?sslmode=verify-full&sslrootcert=/etc/pg/ca.crt
  data:
    - secretKey: username
      remoteRef:
        key: payments/db
        property: username
    - secretKey: password
      remoteRef:
        key: payments/db
        property: password
```

```console
$ kubectl -n payments get externalsecret payments-db
NAME          STORE        REFRESH INTERVAL   STATUS         READY
payments-db   vault-prod   15m                SecretSynced   True

$ kubectl -n payments get secret payments-db -o jsonpath='{.metadata.ownerReferences}' | jq -r '.[].kind'
ExternalSecret

# Rotate in Vault; no commit, no sync, no PR.
$ vault kv put kv/payments/db username=payments_rw password="$(openssl rand -base64 32)"
====== Secret Path ======
kv/data/payments/db
Version: 8

$ kubectl -n payments annotate externalsecret payments-db \
    force-sync=$(date +%s) --overwrite
externalsecret.external-secrets.io/payments-db annotated

$ kubectl -n payments get secret payments-db -o jsonpath='{.metadata.resourceVersion}'
88421037
```

The Git repo contains the `ExternalSecret` — a *reference*, reviewable and diffable — and never the value. This is the reconciliation of "everything in Git" with "no secrets in Git": what is declared is the *binding*, not the material.

### 5.4 Preventing plaintext from ever landing (defence in depth)

Two independent gates, because either alone has a bypass:

```yaml
# .github/workflows/secret-scan.yaml — gate 1, pre-merge
name: secret-scan
on: [pull_request]
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Detect committed secrets
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source=/repo --redact --exit-code=1 --report-format=sarif \
            --report-path=/repo/gitleaks.sarif
      - name: Assert every Secret manifest is SOPS-encrypted
        run: |
          fail=0
          while IFS= read -r f; do
            if ! grep -q '^sops:' "$f"; then
              echo "::error file=$f::Secret manifest is not SOPS-encrypted"
              fail=1
            fi
          done < <(grep -rlE '^kind:[[:space:]]*Secret$' clusters/ apps/ || true)
          exit "$fail"
```

```yaml
# gate 2 — admission, catches anything that bypassed CI
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-unmanaged-secrets
spec:
  # Kyverno ≥1.13 moves this to spec.rules[].validate.failureAction
  validationFailureAction: Enforce
  background: false
  rules:
    - name: secrets-must-be-operator-owned
      match:
        any:
          - resources:
              kinds: ["Secret"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      exclude:
        any:
          - resources:
              kinds: ["Secret"]
              selector:
                matchExpressions:
                  - key: "type"
                    operator: In
                    values: ["kubernetes.io/service-account-token"]
      validate:
        message: >-
          Secrets in prod namespaces must be created by External Secrets Operator,
          the SealedSecrets controller, or a SOPS-enabled Flux Kustomization.
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.ownerReferences[?kind=='ExternalSecret'] || `[]` | length(@) }}"
                operator: Equals
                value: 0
              - key: "{{ request.object.metadata.ownerReferences[?kind=='SealedSecret'] || `[]` | length(@) }}"
                operator: Equals
                value: 0
              - key: "{{ request.object.metadata.annotations.\"kustomize.toolkit.fluxcd.io/name\" || '' }}"
                operator: Equals
                value: ""
```

---

## 6. Policy as code: where to enforce, and why "both" is the answer

| Enforcement point | Catches | Latency of feedback | Bypassable by | Cost |
|---|---|---|---|---|
| Pre-commit hook | Typos, obvious policy breaks | Seconds | `--no-verify` | Free |
| CI (PR check) | Schema, policy, drift-from-render | Minutes | Admin merge, direct push | Cheap |
| Reconciler dry-run | RBAC violations, invalid API versions | One reconcile interval | Nothing (it's in-path) | Free |
| **Admission controller** | Everything, from any source (`kubectl`, operators, GitOps) | Instant, at write | Nothing (short of bypassing the webhook) | Availability risk |
| Runtime audit / periodic scan | Resources that predate the policy | Hours | Nothing | Cheap |

CI-only policy is the most common mistake. It validates the manifests it was pointed at, in the state the PR left them, on the assumption that nothing else writes to the cluster. Admission-only policy is the second mistake: developers learn about the violation after merge, when the reconciler is already retrying in a loop. Run policy in CI **for feedback** and at admission **for enforcement**, from the same policy source.

### 6.1 Kyverno: verify image signatures at admission

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-provenance
  annotations:
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false
  rules:
    - name: require-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          # Rewrite tag -> digest so the admitted spec is immutable.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/*/.github/workflows/release.yaml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
    - name: require-slsa-provenance
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/slsa-framework/slsa-github-generator/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ predicate.buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
                    - key: "{{ predicate.runDetails.builder.id }}"
                      operator: Equals
                      value: "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.0.0"
```

```console
$ kubectl -n prod-payments run rogue --image=docker.io/library/nginx:latest
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod-payments/rogue was blocked due to the following policies

verify-image-provenance:
  require-cosign-keyless-signature: 'failed to verify image docker.io/library/nginx:latest:
    .attestors[0].entries[0].keyless: no signatures found'
```

### 6.2 Gatekeeper: constrain what the reconciler may create

```yaml
---
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("container <%v> has an untrusted image <%v>; allowed prefixes: %v",
                         [container.name, container.image, input.parameters.repos])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("initContainer <%v> has an untrusted image <%v>",
                         [container.name, container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: prod-registry-allowlist
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaceSelector:
      matchLabels:
        acme.io/environment: prod
  parameters:
    repos:
      - "ghcr.io/acme/"
      - "registry.k8s.io/"
```

```console
$ kubectl get k8sallowedrepos prod-registry-allowlist \
    -o jsonpath='{.status.totalViolations}'
0

$ kubectl get constraint -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'
NAME                      ENFORCE   VIOLATIONS
prod-registry-allowlist   deny      0
```

### 6.3 Kyverno vs Gatekeeper for a GitOps platform

| | Kyverno | OPA Gatekeeper |
|---|---|---|
| Policy language | YAML (Kubernetes-native) | Rego |
| Learning curve | Low | Steep, but far more expressive |
| Mutation | First-class (`mutate`, `mutateDigest`) | Assign/AssignMetadata (newer, less mature) |
| Image verification | Built in (`verifyImages`, cosign, attestations) | Requires external data / `external_data` provider |
| Generation of resources | `generate` rules (e.g. default NetworkPolicy per NS) | Expansion only |
| Cross-object queries | `context` with API lookups | `data.inventory` (replicated cache) |
| CLI for CI | `kyverno apply -p policies/ -r manifests/` | `gator test` |
| Best fit | Supply-chain + Kubernetes-shaped rules | Complex, org-wide, logic-heavy policy |

Run the same policies in CI so the feedback arrives on the PR:

```console
$ kyverno apply ./policies/ --resource ./rendered/prod.yaml --policy-report
Applying 6 policy(ies) to 41 resource(s)...

pass: 38, fail: 2, warn: 0, error: 0, skip: 1

policy: verify-image-provenance / require-cosign-keyless-signature
  FAIL  Pod/prod-payments/payments-7c9f8   image ghcr.io/acme/payments:dev-build not signed
policy: block-unmanaged-secrets / secrets-must-be-operator-owned
  FAIL  Secret/prod-payments/legacy-api-key
```

---

## 7. Observability of the reconciliation loop

### 7.1 The four questions

Every GitOps observability stack answers exactly four questions. If your dashboard cannot answer all four in under thirty seconds, it is incomplete.

1. **Is the declared state the running state?** → sync/drift status
2. **Is the running state healthy?** → workload health, which is *not* the same thing
3. **How long since the loop last actually ran?** → liveness/staleness, the one everybody forgets
4. **Which commit is running, and who signed it?** → attribution

A subtle and exam-relevant point: **`Synced` + `Degraded` is a normal, expected state.** It means "we successfully applied exactly what you asked for, and what you asked for is broken." GitOps tooling reports these two axes independently precisely so you can tell "the pipeline failed" apart from "the change was bad."

### 7.2 Flux metrics reference

All Flux controllers expose Prometheus metrics on port `8080` (`/metrics`) and health on `9440`.

| Metric | Type | Key labels | What it tells you |
|---|---|---|---|
| `gotk_reconcile_condition` | Gauge (0/1) | `kind`, `name`, `exported_namespace`, `type` (`Ready`\|`Reconciling`\|`Stalled`), `status` | The canonical readiness signal for every Flux CR |
| `gotk_suspend_status` | Gauge (0/1) | `kind`, `name`, `exported_namespace` | Whether reconciliation is deliberately paused |
| `gotk_resource_info` | Gauge (1) | `kind`, `name`, `revision`, `ready`, `suspended`, `url` | Flux ≥2.3: revision-carrying info series — best for "which commit is live" |
| `controller_runtime_reconcile_total` | Counter | `controller`, `result` (`success`\|`error`\|`requeue`) | Reconcile throughput and error rate |
| `controller_runtime_reconcile_errors_total` | Counter | `controller` | Hard error rate |
| `controller_runtime_reconcile_time_seconds` | Histogram | `controller` | Reconcile latency distribution |
| `workqueue_depth` | Gauge | `name` | Backlog — sustained >0 means the controller is saturated |
| `workqueue_longest_running_processor_seconds` | Gauge | `name` | A single stuck reconcile |
| `rest_client_requests_total` | Counter | `code`, `method` | API-server pressure and 429s |
| `go_memstats_alloc_bytes`, `process_cpu_seconds_total` | Gauge/Counter | — | Controller resource headroom |

```console
$ kubectl -n flux-system port-forward deploy/kustomize-controller 8080:8080 >/dev/null 2>&1 &
$ curl -s localhost:8080/metrics | grep '^gotk_reconcile_condition' | sort | head -8
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="Deleted",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="False",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="True",type="Ready"} 1
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="Unknown",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="infra",namespace="flux-system",status="False",type="Ready"} 1
gotk_reconcile_condition{kind="Kustomization",name="infra",namespace="flux-system",status="True",type="Ready"} 0

$ curl -s localhost:8080/metrics | grep '^gotk_suspend_status'
gotk_suspend_status{kind="Kustomization",name="apps",namespace="flux-system"} 0
gotk_suspend_status{kind="Kustomization",name="infra",namespace="flux-system"} 0
gotk_suspend_status{kind="Kustomization",name="tenants",namespace="flux-system"} 1
```

> **The `exported_namespace` trap.** The metric emits a `namespace` label naming the namespace of the *reconciled object*. Prometheus also attaches a `namespace` label identifying the *scrape target's* pod namespace. The default `honor_labels: false` behaviour renames the conflicting original to `exported_namespace`. Every alert rule you copy from upstream will therefore reference `exported_namespace`, and every rule you write from a raw `curl` of `/metrics` will reference `namespace` — and silently match nothing. Confirm which one your Prometheus produces before writing rules:
>
> ```console
> $ curl -sG 'http://prometheus:9090/api/v1/series' \
>     --data-urlencode 'match[]=gotk_reconcile_condition' | jq -r '.data[0] | keys[]'
> __name__
> container
> endpoint
> exported_namespace
> instance
> job
> kind
> name
> namespace
> pod
> status
> type
> ```

### 7.3 Argo CD metrics reference

| Component | Service / port | Key metrics |
|---|---|---|
| application-controller | `argocd-metrics:8082` | `argocd_app_info`, `argocd_app_sync_total`, `argocd_app_reconcile` (histogram), `argocd_app_k8s_request_total`, `argocd_cluster_api_resource_objects`, `argocd_cluster_events_total`, `argocd_kubectl_exec_total` |
| api-server | `argocd-server-metrics:8083` | `argocd_redis_request_total`, `grpc_server_handled_total`, `argocd_proxy_extension_request_total` |
| repo-server | `argocd-repo-server:8084` | `argocd_git_request_total{request_type="ls-remote"\|"fetch"}`, `argocd_git_request_duration_seconds`, `argocd_repo_pending_request_total` |
| notifications-controller | `argocd-notifications-controller-metrics:9001` | `argocd_notifications_deliveries_total`, `argocd_notifications_trigger_eval_total` |
| applicationset-controller | `:8080` | `controller_runtime_*` |

```console
$ kubectl -n argocd port-forward svc/argocd-metrics 8082:8082 >/dev/null 2>&1 &
$ curl -s localhost:8082/metrics | grep '^argocd_app_info' | head -2
argocd_app_info{autosync_enabled="true",dest_namespace="payments",dest_server="https://kubernetes.default.svc",health_status="Healthy",name="payments",namespace="argocd",operation="",project="prod",repo="https://github.com/acme/platform-config",sync_status="Synced"} 1
argocd_app_info{autosync_enabled="false",dest_namespace="checkout",dest_server="https://kubernetes.default.svc",health_status="Degraded",name="checkout",namespace="argocd",operation="Sync",project="prod",repo="https://github.com/acme/platform-config",sync_status="OutOfSync"} 1

$ curl -s localhost:8082/metrics | grep '^argocd_app_sync_total'
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="payments",namespace="argocd",phase="Succeeded",project="prod"} 341
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="checkout",namespace="argocd",phase="Failed",project="prod"} 17
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="checkout",namespace="argocd",phase="Error",project="prod"} 2
```

`autosync_enabled="false"` on a production app is a *security* finding, not just an operational one: it means drift is no longer being corrected and someone's manual `kubectl` change will persist indefinitely. Alert on it (§7.4).

### 7.4 Scrape configuration and alerting rules

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: flux-controllers
  namespace: flux-system
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: ["flux-system"]
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - source-controller
          - kustomize-controller
          - helm-controller
          - notification-controller
          - image-automation-controller
          - image-reflector-controller
  podMetricsEndpoints:
    - port: http-prom
      path: /metrics
      interval: 30s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_app]
          targetLabel: flux_controller
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-repo-server
  namespace: argocd
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  endpoints:
    - port: metrics
      interval: 30s
```

The rules that matter. Note the four distinct failure classes: **failing**, **suspended**, **stale**, and **thrashing** — a stack that alerts only on the first is the stack that discovers the other three from a customer.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-reconciliation
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: flux-reconciliation
      rules:
        # Failing AND not deleted. The "* 2 == 1" arithmetic is upstream's idiom:
        # a resource pending deletion also reports Ready=False, and paging on
        # a deliberate deletion is noise.
        - alert: FluxReconciliationFailure
          expr: |
            max by (exported_namespace, name, kind) (
              gotk_reconcile_condition{type="Ready",status="False"}
            )
            + on(exported_namespace, name, kind)
            (
              max by (exported_namespace, name, kind) (
                gotk_reconcile_condition{type="Deleted",status="True"}
              )
            ) * 2
            == 1
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "{{ $labels.kind }} {{ $labels.exported_namespace }}/{{ $labels.name }} has been failing for 10m"
            runbook_url: "https://runbooks.acme.io/gitops/reconciliation-failure"

        # Suspension is a legitimate operation that becomes an incident when forgotten.
        - alert: FluxResourceSuspendedTooLong
          expr: gotk_suspend_status == 1
          for: 24h
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.kind }} {{ $labels.exported_namespace }}/{{ $labels.name }} suspended for >24h — drift is not being corrected"

        # Staleness: the loop stopped without turning anything red.
        - alert: FluxReconcileStalled
          expr: |
            rate(controller_runtime_reconcile_total{controller=~"kustomization|gitrepository|helmrelease|ocirepository"}[15m]) == 0
          for: 30m
          labels:
            severity: critical
          annotations:
            summary: "Controller {{ $labels.controller }} has performed no reconciliations in 30m"

        - alert: FluxControllerAbsent
          expr: |
            absent(up{job=~".*flux.*"} == 1)
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No Flux controller is being scraped — the observability of the loop is itself down"

        - alert: FluxReconcileLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, controller) (
                rate(controller_runtime_reconcile_time_seconds_bucket[10m])
              )
            ) > 60
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "p99 reconcile latency for {{ $labels.controller }} is {{ $value | humanizeDuration }}"

        - alert: FluxWorkqueueBacklog
          expr: workqueue_depth{name=~"kustomization|helmrelease|gitrepository"} > 20
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Workqueue {{ $labels.name }} depth {{ $value }} — controller is saturated"

    - name: argocd-reconciliation
      rules:
        - alert: ArgoCDAppOutOfSync
          expr: |
            argocd_app_info{sync_status!="Synced",project="prod"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Application {{ $labels.name }} is {{ $labels.sync_status }} for 15m"

        - alert: ArgoCDAppUnhealthy
          expr: |
            argocd_app_info{health_status=~"Degraded|Missing|Unknown",project="prod"} == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Application {{ $labels.name }} health is {{ $labels.health_status }}"

        # Drift correction silently disabled — a security control regression.
        - alert: ArgoCDAutoSyncDisabled
          expr: argocd_app_info{autosync_enabled="false",project="prod"} == 1
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Auto-sync disabled on prod application {{ $labels.name }} — drift will persist"

        - alert: ArgoCDSyncFailureRate
          expr: |
            sum by (name) (rate(argocd_app_sync_total{phase=~"Failed|Error"}[30m]))
              /
            clamp_min(sum by (name) (rate(argocd_app_sync_total[30m])), 1e-9)
              > 0.25
          for: 20m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.name }}: {{ $value | humanizePercentage }} of syncs failing"

        # Thrash detector: healthy sync rate far above the human change rate
        # means selfHeal is fighting something (HPA, mutating webhook, operator).
        - alert: ArgoCDSyncThrashing
          expr: sum by (name) (rate(argocd_app_sync_total{phase="Succeeded"}[10m])) * 600 > 20
          for: 20m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.name }} synced >20 times in 10m — probable drift fight"

        - alert: ArgoCDRepoServerGitErrors
          expr: |
            sum by (repo) (rate(argocd_git_request_total{request_type="ls-remote"}[10m])) > 5
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Excessive ls-remote against {{ $labels.repo }} — check webhook / polling interval"
```

### 7.5 SLOs for the GitOps control plane

Treat the loop as a service with its own SLIs. These are the four worth defining:

| SLI | Definition | Query sketch | Suggested target |
|---|---|---|---|
| **Reconciliation success ratio** | successful reconciles ÷ total | `sum(rate(controller_runtime_reconcile_total{result="success"}[28d])) / sum(rate(controller_runtime_reconcile_total[28d]))` | ≥ 99.0% |
| **Sync latency (merge → applied)** | p95 seconds from commit timestamp to `Ready=True` on the new revision | Requires commit-time export; approximate with `histogram_quantile(0.95, ...reconcile_time_seconds_bucket)` + poll interval | p95 < 5 min |
| **Drift MTTR** | time a resource spends `OutOfSync` before correction | `avg_over_time(argocd_app_info{sync_status="OutOfSync"}[1h])` × window | p95 < 3 min |
| **Loop liveness** | fraction of time at least one reconcile occurred per 15 min | `avg_over_time((rate(controller_runtime_reconcile_total[15m]) > bool 0)[28d:15m])` | ≥ 99.9% |

These roll up into the DORA metrics the business actually asks about — deployment frequency is `rate(argocd_app_sync_total{phase="Succeeded"}[1d])`, and change failure rate is the ratio of syncs followed by a rollback or a `Degraded` transition within 30 minutes.

```console
$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=sum(rate(controller_runtime_reconcile_total{result="success"}[7d])) / sum(rate(controller_runtime_reconcile_total[7d]))' \
    | jq -r '.data.result[0].value[1]'
0.9973118279569892

$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=histogram_quantile(0.95, sum by (le) (rate(controller_runtime_reconcile_time_seconds_bucket{controller="kustomization"}[6h])))' \
    | jq -r '.data.result[0].value[1]'
3.8421052631578947
```

### 7.6 Event-driven notification (the fast path)

Metrics are for trends and SLOs; events are for "this specific change failed, here is the commit." Both, not either.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: slack-webhook
  namespace: flux-system
type: Opaque
stringData:
  address: https://hooks.slack.com/services/T000/B000/XXXXXXXX   # via SOPS/ESO in reality
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-platform
  namespace: flux-system
spec:
  type: slack
  channel: platform-alerts
  secretRef:
    name: slack-webhook
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: on-call-errors
  namespace: flux-system
spec:
  providerRef:
    name: slack-platform
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      namespace: flux-system
      name: '*'
    - kind: OCIRepository
      namespace: flux-system
      name: '*'
    - kind: Kustomization
      namespace: '*'
      name: '*'
    - kind: HelmRelease
      namespace: '*'
      name: '*'
  # Suppress transient chatter that resolves on the next interval.
  exclusionList:
    - "waiting for the .* to be ready"
    - "dependency .* is not ready"
  suspend: false
---
# Commit-status write-back: the PR that introduced a bad manifest turns red.
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: github-status
  namespace: flux-system
spec:
  type: github
  address: https://github.com/acme/platform-config
  secretRef:
    name: github-token
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: github-commit-status
  namespace: flux-system
spec:
  providerRef:
    name: github-status
  eventSeverity: info
  eventSources:
    - kind: Kustomization
      namespace: flux-system
      name: apps
---
# Push-triggered reconciliation: latency drops from the poll interval to seconds.
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-webhook
  namespace: flux-system
spec:
  type: github
  events: ["ping", "push"]
  secretRef:
    name: webhook-token       # key "token" -> the HMAC shared secret
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: platform-config
      namespace: flux-system
```

```console
$ kubectl -n flux-system create secret generic webhook-token \
    --from-literal=token="$(head -c 32 /dev/urandom | base64)"
secret/webhook-token created

$ kubectl -n flux-system get receiver github-webhook \
    -o jsonpath='{.status.webhookPath}'
/hook/7d1f9ac5b4e2f0c831a6d94e5b7c20fa3e8d6194b2c7f05a83d1e4b96c7025af
```

Register `https://flux-webhook.acme.io<webhookPath>` in the forge. The HMAC token is what stops an unauthenticated internet host from forcing reconciliation on demand — the receiver rejects unsigned payloads, so the endpoint can be public.

Argo CD's equivalent:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  trigger.on-health-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [app-health-degraded]
  trigger.on-sync-status-unknown: |
    - when: app.status.sync.status == 'Unknown'
      send: [app-sync-failed]
  template.app-sync-failed: |
    message: |
      :x: *{{.app.metadata.name}}* sync {{.app.status.operationState.phase}}
      Revision: {{.app.status.operationState.syncResult.revision}}
      Author:   {{.app.status.operationState.operation.initiatedBy.username}}
      Message:  {{.app.status.operationState.message}}
      <{{.context.argocdUrl}}/applications/{{.app.metadata.name}}|Open in Argo CD>
  template.app-health-degraded: |
    message: |
      :warning: *{{.app.metadata.name}}* is Degraded on revision {{.app.status.sync.revision}}
  subscriptions: |
    - recipients: [slack:platform-alerts]
      triggers: [on-sync-failed, on-health-degraded, on-sync-status-unknown]
      selector: argocd.argoproj.io/notified!=true
```

### 7.7 The audit trail: Git plus the API server, not Git alone

"Git is the audit log" is true only for changes that went through Git. Changes made directly against the API server — by a human, an operator, or the reconciler itself — are recorded in the **Kubernetes audit log**, and correlating the two is what produces a complete narrative.

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Full request+response for everything the GitOps agents write.
  - level: RequestResponse
    users:
      - system:serviceaccount:flux-system:kustomize-controller
      - system:serviceaccount:flux-system:helm-controller
      - system:serviceaccount:argocd:argocd-application-controller
    verbs: ["create", "update", "patch", "delete"]

  # Impersonated tenant identities — this is where escalation attempts appear.
  - level: RequestResponse
    userGroups: ["system:serviceaccounts"]
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Any human writing directly to a prod namespace is, by definition, drift.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    namespaces: ["payments", "checkout"]
    omitStages: ["RequestReceived"]

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]

  - level: Metadata
```

Answering "who changed this, and did it go through Git?":

```console
$ kubectl -n payments get deploy payments \
    -o jsonpath='{.metadata.annotations}' | jq
{
  "deployment.kubernetes.io/revision": "42",
  "kustomize.toolkit.fluxcd.io/name": "payments",
  "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
  "fluxcd.io/reconcileAt": "2026-08-18T09:41:02Z"
}

$ kubectl -n flux-system get kustomization payments \
    -o jsonpath='{.status.lastAppliedRevision}'
v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93

$ git log -1 --show-signature 9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
commit 9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
gpg: Signature made Mon 18 Aug 2026 09:33:11 AM CEST
gpg:                using RSA key 3CF6A1B4C0DE9A17
gpg: Good signature from "ACME Release Bot <release@acme.io>" [ultimate]
Author: ACME Release Bot <release@acme.io>
Date:   Mon Aug 18 09:33:11 2026 +0200

    feat(payments): raise connection pool to 40 (#1187)
```

`flux trace` collapses that whole chain into one command:

```console
$ flux trace --kind Deployment --api-version apps/v1 --name payments --namespace payments

Object:          Deployment/payments
Namespace:       payments
Status:          Managed by Flux
---
Kustomization:   payments
Namespace:       flux-system
Path:            ./clusters/prod/payments
Revision:        v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
Status:          Last reconciled at 2026-08-18 09:41:02 +0200 CEST
Message:         Applied revision: v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
---
GitRepository:   platform-config
Namespace:       flux-system
URL:             ssh://git@github.com/acme/platform-config
Tag:             v1.4.2
Revision:        v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
Status:          Last reconciled at 2026-08-18 09:40:55 +0200 CEST
Message:         stored artifact for revision 'v1.4.2@sha1:9f3c2ab...'
```

An object that returns "Status: Unmanaged by Flux" while living in a GitOps-owned namespace is either drift or a policy gap. Both are findings.

---

## 8. Verification and failure diagnosis

### 8.1 The pre-flight check

```console
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.4.0
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
► ghcr.io/fluxcd/helm-controller:v1.1.0
✔ kustomize-controller: deployment ready
► ghcr.io/fluxcd/kustomize-controller:v1.4.0
✔ notification-controller: deployment ready
► ghcr.io/fluxcd/notification-controller:v1.4.0
✔ source-controller: deployment ready
► ghcr.io/fluxcd/source-controller:v1.4.1
► checking crds
✔ alerts.notification.toolkit.fluxcd.io/v1beta3
✔ buckets.source.toolkit.fluxcd.io/v1
✔ gitrepositories.source.toolkit.fluxcd.io/v1
✔ helmreleases.helm.toolkit.fluxcd.io/v2
✔ kustomizations.kustomize.toolkit.fluxcd.io/v1
✔ ocirepositories.source.toolkit.fluxcd.io/v1beta2
✔ receivers.notification.toolkit.fluxcd.io/v1
✔ all checks passed
```

```console
$ argocd admin app get-reconcile-results --l 'argocd.argoproj.io/instance' -o results.yaml
$ kubectl -n argocd get application -o custom-columns=\
'NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision'
NAME       PROJECT   SYNC       HEALTH     REV
payments   prod      Synced     Healthy    9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
checkout   prod      OutOfSync  Degraded   9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
grafana    infra     Synced     Healthy    9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
```

### 8.2 Failure taxonomy

| # | Symptom | Most likely cause | First command | Fix |
|---|---|---|---|---|
| F1 | `Ready=False`, `unable to clone` | Bad/expired deploy key; missing `known_hosts` | `kubectl -n flux-system logs deploy/source-controller \| grep -i clone` | Recreate the auth secret; re-add the deploy key |
| F2 | `Ready=False`, `object not signed by a trusted key` | Signing key rotated / not in allowlist | `flux get sources git -A` | Add the new public key to the verify secret |
| F3 | `Decryption failed ... no identity matched` | Wrong age/KMS key for this cluster | `kubectl get secret sops-age -o ... \| age-keygen -y` | Install the correct private key |
| F4 | `is forbidden: User "system:serviceaccount:..." cannot ...` | Impersonated SA lacks the right (usually correct behaviour) | `kubectl auth can-i <verb> <res> --as=<sa>` | Grant narrowly, or reject the manifest |
| F5 | `OutOfSync` forever, `Synced` never reached | `ignoreDifferences` missing; mutating webhook rewrites the object | `argocd app diff <app>` | Add `ignoreDifferences` or `managedFieldsManagers` |
| F6 | Sync count climbing, resource flapping | Drift fight: HPA vs declared `replicas` | `kubectl -n <ns> get events --sort-by=.lastTimestamp` | Remove `replicas` from the manifest |
| F7 | `Synced` + `Degraded` | Manifest is correct, workload is broken | `kubectl -n <ns> describe pod ...` | Application bug — roll back the commit |
| F8 | `Progressing` forever | `wait: true` + `healthChecks` on a never-ready object | `flux -n <ns> get kustomization <k>` | Fix readiness probe or the health check target |
| F9 | Nothing happens on push | Webhook not firing; `suspend: true` | `flux get all -A \| grep True` (suspended col) | `flux resume`; verify Receiver token/path |
| F10 | Metrics absent in Prometheus | ServiceMonitor label mismatch; NetworkPolicy blocks scrape | `kubectl get servicemonitor -A -o yaml \| grep release` | Match the Prometheus `serviceMonitorSelector` |
| F11 | Alerts never fire | Rule uses `namespace` where Prometheus emits `exported_namespace` | Query the series in the Prometheus UI | Fix the label name |
| F12 | `Kustomization` fails, `no matches for kind` | CRD not yet applied (ordering) | `flux tree kustomization flux-system` | `dependsOn` the CRD Kustomization |
| F13 | Repo-server CPU pinned, syncs slow | Polling interval too low across many apps | `argocd_git_request_total` rate | Enable webhooks; raise `timeout.reconciliation` |
| F14 | Prune deleted something unexpected | Resource lost its Flux/Argo label, or moved paths | Audit log for the delete | Restore from Git; use `prune: false` while migrating |

### 8.3 Scenario A — the loop that stopped without turning red

```console
$ flux get kustomizations -A
NAMESPACE  	NAME       	REVISION                     	SUSPENDED	READY	MESSAGE
flux-system	apps       	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
flux-system	flux-system	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
flux-system	infra      	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
```

Everything green — but `main` in the forge is at `7c19d3a`, eleven commits ahead. The `Kustomization` is `Ready=True` because it last *applied* successfully; the failure is upstream, at the source:

```console
$ flux get sources git -A
NAMESPACE  	NAME           	REVISION         	SUSPENDED	READY	MESSAGE
flux-system	platform-config	main@sha1:4b81ff0	False    	False	failed to checkout and determine revision: unable to list remote for 'ssh://git@github.com/acme/platform-config': ssh: handshake failed: knownhosts: key mismatch

$ kubectl -n flux-system get gitrepository platform-config \
    -o jsonpath='{.status.artifact.lastUpdateTime}'
2026-08-07T11:22:41Z          # eleven days stale
```

The forge rotated its host key. The `Kustomization` never noticed because it only consumes the artifact, and a stale artifact is still a valid one.

```console
$ ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null > /tmp/known_hosts
$ kubectl -n flux-system create secret generic platform-config-auth \
    --from-file=identity=/dev/stdin \
    --from-file=known_hosts=/tmp/known_hosts \
    --dry-run=client -o yaml < <(kubectl -n flux-system get secret platform-config-auth -o jsonpath='{.data.identity}' | base64 -d) \
    | kubectl apply -f -
secret/platform-config-auth configured

$ flux reconcile source git platform-config
► annotating GitRepository platform-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:7c19d3a
```

**Lesson, and the reason `FluxReconcileStalled` exists in §7.4:** never build a GitOps dashboard on `Ready` alone. Add source freshness — `time() - gotk_resource_info` last-update, or simply alert on the `GitRepository`'s own `Ready` condition, which is a different series from the `Kustomization`'s.

### 8.4 Scenario B — permanent `OutOfSync` from a mutating webhook

```console
$ argocd app get checkout
Name:               argocd/checkout
Sync Status:        OutOfSync from main (9f3c2ab)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME      STATUS     HEALTH   MESSAGE
apps   Deployment  checkout   checkout  OutOfSync  Healthy

$ argocd app diff checkout
===== apps/Deployment checkout/checkout ======
28c28
<       - name: istio-proxy
<         image: docker.io/istio/proxyv2:1.24.1
---
>   (absent)
```

The service mesh injects a sidecar after admission. Argo CD sees a container it did not declare and reports drift forever. Correct fix — declare the ignore, do not disable self-heal:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout
  namespace: argocd
spec:
  project: prod
  source:
    repoURL: https://github.com/acme/platform-config
    targetRevision: main
    path: apps/checkout/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: checkout
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true      # honour ignores during SYNC too, not just diff
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  ignoreDifferences:
    # Sidecar injected by the mesh admission webhook.
    - group: apps
      kind: Deployment
      name: checkout
      jsonPointers:
        - /spec/template/spec/containers/1
    # Replica count owned by the HPA, not by Git.
    - group: apps
      kind: Deployment
      name: checkout
      jsonPointers:
        - /spec/replicas
    # Preferred modern form: defer to whichever manager owns the field.
    - group: apps
      kind: Deployment
      managedFieldsManagers:
        - istio-sidecar-injector
        - kube-controller-manager
```

> **`RespectIgnoreDifferences=true` is the option people miss.** Without it, `ignoreDifferences` affects only what the *diff* displays; the sync still pushes the declared value, so `selfHeal` strips the sidecar every cycle. The app looks fine on the dashboard and pods restart every few minutes.

Verify with server-side apply field ownership — the definitive answer to "who owns this field":

```console
$ kubectl -n checkout get deploy checkout --show-managed-fields -o json \
    | jq '.metadata.managedFields[] | {manager, operation, fields: (.fieldsV1 | keys)}'
{
  "manager": "kustomize-controller",
  "operation": "Apply",
  "fields": ["f:metadata", "f:spec"]
}
{
  "manager": "kube-controller-manager",
  "operation": "Update",
  "fields": ["f:spec"]
}
{
  "manager": "istio-sidecar-injector",
  "operation": "Update",
  "fields": ["f:spec"]
}
```

### 8.5 Scenario C — drift injected out of band, and its correction

```console
$ kubectl -n payments scale deploy/payments --replicas=12
deployment.apps/payments scaled

$ kubectl -n payments get deploy payments -o jsonpath='{.spec.replicas}'
12

# ... one reconcile interval later ...
$ kubectl -n payments get deploy payments -o jsonpath='{.spec.replicas}'
4

$ kubectl -n flux-system get events --field-selector involvedObject.name=payments \
    --sort-by=.lastTimestamp | tail -3
LAST SEEN   TYPE     REASON              OBJECT                   MESSAGE
2m14s       Normal   Progressing         kustomization/payments   Deployment/payments/payments configured
2m14s       Normal   ReconciliationSucceeded  kustomization/payments   Reconciliation finished in 1.42s, next run in 10m
```

Now the security question the exam actually asks: **who did it?** The reconciler corrected the drift, which is good, but correction without attribution means a probing attacker gets unlimited free attempts.

```console
$ kubectl get --raw '/api/v1/namespaces/payments/events' >/dev/null   # events are already gone (1h TTL)

$ jq -c 'select(.objectRef.resource=="deployments"
         and .objectRef.name=="payments"
         and .verb=="patch"
         and (.user.username | startswith("system:") | not))
         | {t:.requestReceivedTimestamp, user:.user.username, groups:.user.groups, sub:.objectRef.subresource}' \
    /var/log/kubernetes/audit.log | tail -2
{"t":"2026-08-18T10:14:02.881Z","user":"jorge@acme.io","groups":["acme:team-a","system:authenticated"],"sub":"scale"}
```

Two follow-ups, both required: revoke the direct-write path (`jorge@acme.io` should not hold `patch` on prod Deployments), and add a `DirectWriteToGitOpsNamespace` alert sourced from audit logs. Continuous reconciliation makes unauthorized change *transient*; it does not make it *visible*. Audit logging is what makes it visible.

### 8.6 Scenario D — the reconciler is fine, the observability is not

```console
$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=gotk_reconcile_condition' | jq '.data.result | length'
0

$ kubectl -n flux-system get svc -l app.kubernetes.io/part-of=flux
No resources found in flux-system namespace.
```

There is no `Service` in front of the Flux controllers — the upstream install exposes metrics on the pods directly. A `ServiceMonitor` will therefore never match anything; you need a `PodMonitor` (§7.4). Confirm the selector actually resolves:

```console
$ kubectl -n flux-system get pods -l app=kustomize-controller \
    -o jsonpath='{.items[0].spec.containers[0].ports}' | jq
[
  {"containerPort": 8080, "name": "http-prom", "protocol": "TCP"},
  {"containerPort": 9440, "name": "healthz", "protocol": "TCP"}
]

$ kubectl apply -f podmonitor-flux.yaml
podmonitor.monitoring.coreos.com/flux-controllers created

$ kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
    -o jsonpath='{.spec.podMonitorSelector}' | jq
{ "matchLabels": { "release": "kube-prometheus-stack" } }
# -> the PodMonitor must carry release: kube-prometheus-stack, and it does.

$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=count(gotk_reconcile_condition)' | jq -r '.data.result[0].value[1]'
248
```

Also confirm the scrape is not blocked by the NetworkPolicy you wrote in §4.5 — that policy covers egress only, but a corresponding ingress-deny in `flux-system` would silently break scraping while leaving reconciliation perfectly healthy. This failure mode is the one that produces "we had no alerts, so we thought it was fine."

### 8.7 Security verification checklist (runnable)

```bash
#!/usr/bin/env bash
# gitops-audit.sh — assert the controls of domain 4.1 are actually in place.
set -euo pipefail
fail=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

check "No plaintext Secret manifests in the repo" \
  '! grep -rlE "^kind:[[:space:]]*Secret$" clusters/ apps/ 2>/dev/null | xargs -r grep -L "^sops:" | grep -q .'

check "Every Kustomization impersonates a ServiceAccount" \
  '[ "$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.serviceAccountName == null)] | length")" -eq 0 ]'

check "Cross-namespace source refs are disabled" \
  'kubectl -n flux-system get deploy kustomize-controller -o yaml | grep -q -- "--no-cross-namespace-refs=true"'

check "Reconciler cannot create ClusterRoleBindings as a tenant" \
  '! kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:team-a:team-a-reconciler -q'

check "Git source enforces signature verification" \
  '[ "$(kubectl get gitrepositories.source.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.verify == null)] | length")" -eq 0 ]'

check "No repository is configured as insecure" \
  '! kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository -o json | jq -r ".items[].data.insecure // empty" | base64 -d 2>/dev/null | grep -q true'

check "Argo CD local admin account is disabled" \
  '[ "$(kubectl -n argocd get cm argocd-cm -o jsonpath="{.data.admin\.enabled}")" = "false" ]'

check "Argo CD default RBAC policy denies" \
  '[ -z "$(kubectl -n argocd get cm argocd-rbac-cm -o jsonpath="{.data.policy\.default}")" ]'

check "Nothing is left suspended" \
  '[ "$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.suspend == true)] | length")" -eq 0 ]'

check "Flux metrics are reaching Prometheus" \
  '[ "$(curl -sG http://prometheus.monitoring:9090/api/v1/query --data-urlencode "query=count(gotk_reconcile_condition)" | jq -r ".data.result[0].value[1] // 0")" -gt 0 ]'

check "Reconciliation alert rules are loaded" \
  'curl -s http://prometheus.monitoring:9090/api/v1/rules | jq -e ".data.groups[].rules[] | select(.name==\"FluxReconciliationFailure\")" >/dev/null'

exit "$fail"
```

```console
$ ./gitops-audit.sh
PASS  No plaintext Secret manifests in the repo
PASS  Every Kustomization impersonates a ServiceAccount
PASS  Cross-namespace source refs are disabled
PASS  Reconciler cannot create ClusterRoleBindings as a tenant
FAIL  Git source enforces signature verification
PASS  No repository is configured as insecure
PASS  Argo CD local admin account is disabled
PASS  Argo CD default RBAC policy denies
FAIL  Nothing is left suspended
PASS  Flux metrics are reaching Prometheus
PASS  Reconciliation alert rules are loaded
$ echo $?
1
```

---

## 9. Key takeaways

- **Repo write access is production write access.** Branch protection, required review and signing are change-management controls, not developer-experience preferences.
- **Signing is the only in-cluster authenticity control.** Everything else in the forge can be disabled by a repo admin without the cluster ever noticing. Enforce `verify` on the source (Flux) or `signatureKeys` on the project (Argo CD).
- **A reconciler with `cluster-admin` converts repo access into cluster-admin.** Impersonate a per-tenant ServiceAccount and enforce it with `--default-service-account`; in Argo CD, use `AppProject` allow/deny lists and accept that hostile multi-tenancy usually means separate instances.
- **Secrets: encrypt for bootstrap material, reference for everything else.** SOPS/SealedSecrets for what must exist before the operators do; External Secrets for everything after, because rotation without a commit is the property that matters.
- **Policy belongs in CI *and* at admission.** CI gives feedback, admission gives enforcement; neither alone covers the other's bypass.
- **`Synced` ≠ `Healthy` ≠ `Fresh`.** Three independent axes, three independent alerts. The third — freshness — is the one that produces multi-week silent outages.
- **Alert on suspension and on auto-sync being disabled.** Both are legitimate operations that become unmonitored drift when forgotten.
- **Reconciliation makes unauthorized change transient; only the audit log makes it visible.** Correlate `lastAppliedRevision` → commit → signature, and log direct writes to GitOps-owned namespaces.
- **Watch out for `exported_namespace`.** The single most common reason a correct-looking Flux alert never fires.

---

## References

**CNCF / exam**
- CGOA curriculum — https://github.com/cncf/curriculum/blob/master/cgoa/README.md
- Linux Foundation, CGOA certification — https://training.linuxfoundation.org/certification/certified-gitops-associate-cgoa/
- OpenGitOps Principles v1.0.0 — https://opengitops.dev/
- CNCF GitOps WG glossary — https://github.com/open-gitops/documents/blob/main/GLOSSARY.md

**Flux**
- Security documentation — https://fluxcd.io/flux/security/
- Multi-tenancy & tenant isolation — https://fluxcd.io/flux/installation/configuration/multitenancy/
- `GitRepository` API (including `spec.verify`) — https://fluxcd.io/flux/components/source/gitrepositories/
- `OCIRepository` API and cosign verification — https://fluxcd.io/flux/components/source/ocirepositories/
- `Kustomization` API (`serviceAccountName`, `decryption`) — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Managing secrets with SOPS — https://fluxcd.io/flux/guides/mozilla-sops/
- Monitoring with Prometheus & Grafana — https://fluxcd.io/flux/monitoring/metrics/
- Alerting rules and `gotk_reconcile_condition` — https://fluxcd.io/flux/monitoring/alerts/
- Notification controller `Alert` / `Provider` / `Receiver` — https://fluxcd.io/flux/components/notification/
- Webhook receivers — https://fluxcd.io/flux/guides/webhook-receivers/
- `flux trace` — https://fluxcd.io/flux/cmd/flux_trace/

**Argo CD**
- Security overview and hardening — https://argo-cd.readthedocs.io/en/stable/operator-manual/security/
- RBAC configuration — https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Projects (`AppProject`) — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- GnuPG signature verification — https://argo-cd.readthedocs.io/en/stable/user-guide/gpg-verification/
- Metrics reference — https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- Diffing customization / `ignoreDifferences` — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Sync options (`ServerSideApply`, `RespectIgnoreDifferences`) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Notifications — https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/

**Secrets and supply chain**
- External Secrets Operator — https://external-secrets.io/latest/
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- SOPS — https://github.com/getsops/sops
- age — https://github.com/FiloSottile/age
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- gitsign — https://docs.sigstore.dev/cosign/signing/gitsign/
- SLSA specification v1.0 — https://slsa.dev/spec/v1.0/
- CNCF Software Supply Chain Best Practices — https://github.com/cncf/tag-security/blob/main/community/resources/software-supply-chain-security/secure-software-factory/secure-software-factory.md

**Policy and platform**
- Kyverno image verification — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kubernetes RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Server-Side Apply and field management — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Prometheus Operator `PodMonitor` / `ServiceMonitor` — https://prometheus-operator.dev/docs/api-reference/api/