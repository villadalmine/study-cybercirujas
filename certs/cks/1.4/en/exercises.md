# Guided Exercises — Protect Node Metadata and Endpoints (CKS 1.34, Topic 1.4)

These hands-on exercises walk you through discovering, testing, and hardening the network endpoints exposed by Kubernetes nodes, and through blocking Pod access to the cloud provider metadata service. Run each block in order, then answer the verification questions before moving on. Consolidated answers are in the collapsible section at the end.

> **Lab environment.** You need a cluster where you have `sudo` on the nodes (kubeadm, `kind`, or a cloud cluster with SSH access). Commands assume a control-plane node plus at least one worker. Where a step touches the kubelet config, take a backup first — a malformed config will stop the kubelet. Nothing here needs to run against production.

**Reference sources**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Ports and Protocols — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubelet config (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Securing a cluster / restricting cloud metadata API — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

## Exercise 1 — Map the endpoints a node exposes

Before you can protect endpoints, you must know which ones listen and whether they authenticate callers.

1. SSH into a **worker** node and list every TCP listening socket with its owning process:

   ```bash
   sudo ss -tlnp
   ```

2. Identify the well-known control-plane and node ports in the output. On a worker you should at least see the kubelet. Cross-check against the documented defaults:

   ```bash
   # Kubelet API (HTTPS, authenticated)       -> 10250
   # Kubelet read-only port (HTTP, NO auth)   -> 10255  (should be absent/disabled)
   # Kubelet healthz (localhost only)          -> 10248
   # kube-proxy health/metrics                 -> 10256 / 10249
   ```

3. Probe the kubelet's read-only port from the node. If it is disabled you will get a connection refused:

   ```bash
   curl -s http://localhost:10255/pods | head -c 200 ; echo
   ```

4. Now probe the authenticated kubelet API **anonymously** (no client cert, no token):

   ```bash
   curl -sk https://localhost:10250/pods/ | head -c 200 ; echo
   ```

5. On the **control-plane** node, check whether etcd's client port is reachable and how it is protected:

   ```bash
   sudo ss -tlnp | grep -E '2379|2380'
   sudo grep -E 'client-cert-auth|listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
   ```

**Verification questions**

1. What is the difference in purpose and authentication between kubelet ports `10250` and `10255`?
2. In step 4, a hardened kubelet returns `401 Unauthorized`. What does a `200` with a JSON pod list instead tell you about the node's configuration?
3. Why is exposing etcd's `2379` without `client-cert-auth` catastrophic even if the API server is otherwise secured?

---

## Exercise 2 — Harden the kubelet endpoint

Now close the anonymous-access holes on the kubelet you just probed.

1. Back up and open the kubelet config on the worker node:

   ```bash
   sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
   sudo vi /var/lib/kubelet/config.yaml
   ```

2. Ensure the `authentication`, `authorization`, and `readOnlyPort` sections match the hardened baseline:

   ```yaml
   authentication:
     anonymous:
       enabled: false      # reject unauthenticated callers
     webhook:
       enabled: true       # let the API server issue TokenReviews
     x509:
       clientCAFile: /etc/kubernetes/pki/ca.crt
   authorization:
     mode: Webhook         # delegate authz to the API server (not AlwaysAllow)
   readOnlyPort: 0         # disable the unauthenticated 10255 port
   ```

3. Restart the kubelet and confirm it comes back healthy:

   ```bash
   sudo systemctl restart kubelet
   sudo systemctl status kubelet --no-pager | head -n 5
   ```

4. Re-run the anonymous probes from Exercise 1 and confirm the behavior changed:

   ```bash
   curl -s http://localhost:10255/pods ; echo        # expect: connection refused
   curl -sk https://localhost:10250/pods/ ; echo      # expect: 401 Unauthorized
   ```

5. Prove that an **authorized** caller still works, using the node's own credentials as a sanity check:

   ```bash
   sudo curl -s --cacert /etc/kubernetes/pki/ca.crt \
     --cert /var/lib/kubelet/pki/kubelet-client-current.pem \
     --key  /var/lib/kubelet/pki/kubelet-client-current.pem \
     https://localhost:10250/pods/ | head -c 120 ; echo
   ```

**Verification questions**

4. Why is `authorization.mode: Webhook` required in addition to `anonymous.enabled: false`? What attack remains open if `mode` were left as `AlwaysAllow` even with anonymous auth disabled?
5. Setting `readOnlyPort: 0` removes port 10255. Name one piece of information an attacker could scrape from `10255` before it was disabled.
6. After the change, `kubectl logs` and `kubectl exec` still work. Which component authenticates to the kubelet on your behalf when you run those commands?

---

## Exercise 3 — Reach the cloud metadata service from a Pod

The link-local address `169.254.169.254` is the cloud provider's Instance Metadata Service (IMDS). By default a Pod inherits the node's network path to it and can steal the node's cloud identity.

1. Launch a throwaway Pod with networking tools:

   ```bash
   kubectl run meta-test --image=nicolaka/netshoot --restart=Never -- sleep 3600
   kubectl wait --for=condition=Ready pod/meta-test
   ```

2. From inside the Pod, try to reach the metadata root (this works on AWS IMDSv1, and is analogous on other clouds):

   ```bash
   kubectl exec meta-test -- curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ ; echo
   ```

3. If you are on AWS with IMDSv1 reachable, attempt to enumerate the node's IAM role and pull its temporary credentials (this is the actual attack you are defending against):

   ```bash
   kubectl exec meta-test -- sh -c \
     'R=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/); \
      echo "role: $R"; \
      curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/$R'
   ```

   > On GCP the equivalent is `curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`; on Azure, `curl -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"`. On `kind`/bare-metal there is no IMDS, so the request simply times out — that is the expected "nothing to steal" result.

**Verification questions**

7. Why is a Pod being able to read `169.254.169.254` a privilege-escalation risk rather than just an information leak?
8. IMDSv2 (AWS) requires a `PUT` to fetch a session token and enforces a low IP hop limit. How does the hop limit specifically frustrate the Pod-based attack in step 3?

---

## Exercise 4 — Block metadata access with a NetworkPolicy

Your CNI must enforce NetworkPolicy (Calico, Cilium, etc.) for this to take effect. This is the primary in-cluster control CKS expects you to apply.

1. Write a policy that allows normal egress but carves out the metadata IP as an exception:

   ```yaml
   # deny-metadata.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-cloud-metadata
     namespace: default
   spec:
     podSelector: {}          # every Pod in the namespace
     policyTypes:
       - Egress
     egress:
       - to:
           - ipBlock:
               cidr: 0.0.0.0/0
               except:
                 - 169.254.169.254/32
   ```

2. Apply it and confirm it exists:

   ```bash
   kubectl apply -f deny-metadata.yaml
   kubectl get networkpolicy deny-cloud-metadata
   ```

3. Re-run the metadata probe from Exercise 3 — it should now time out or be refused:

   ```bash
   kubectl exec meta-test -- curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ ; echo "exit=$?"
   ```

4. Confirm ordinary egress and DNS still work, so you know the exception is surgical and not a blanket deny:

   ```bash
   kubectl exec meta-test -- nslookup kubernetes.default
   kubectl exec meta-test -- curl -s --max-time 3 -o /dev/null -w '%{http_code}\n' https://kubernetes.io
   ```

5. Clean up:

   ```bash
   kubectl delete pod meta-test
   ```

**Verification questions**

9. This policy uses `ipBlock: 0.0.0.0/0` with an `except`. Why is that pattern necessary here instead of simply listing the metadata IP under a "deny" rule?
10. A teammate applies the same manifest but Pods can still reach `169.254.169.254`. Give two distinct reasons the policy might not be enforced.
11. The policy targets `podSelector: {}` in one namespace. What is the gap if the cluster has 12 namespaces, and how would you close it cluster-wide?
12. Blocking `169.254.169.254` at the NetworkPolicy layer is defense-in-depth. What complementary control at the *cloud* layer removes the credential-theft risk even if the NetworkPolicy is missing?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

**Exercise 1**

1. **10250** is the kubelet's full HTTPS API (`/pods`, `/exec`, `/logs`, `/metrics`); it is meant to be authenticated (x509 client cert or bearer token) and authorized. **10255** is the legacy **read-only HTTP** port that serves pod/spec/metrics data with **no authentication** — anyone who can reach it reads cluster state. It should be disabled (`readOnlyPort: 0`).
2. A `200` with a real pod list means the kubelet accepts **anonymous** requests and its authorization mode effectively grants access (e.g. `anonymous.enabled: true` and/or `authorization.mode: AlwaysAllow`). That lets an unauthenticated network peer read pods and potentially `exec` into containers.
3. etcd holds the entire cluster state in plaintext, including every Secret. Direct client access to `2379` without `client-cert-auth` bypasses the API server, RBAC, admission control, and audit logging entirely — an attacker can read or overwrite any object, so it is a full cluster compromise.

**Exercise 2**

4. `anonymous.enabled: false` only forces callers to *present an identity*; it does not decide what that identity may do. With `mode: AlwaysAllow`, any authenticated identity — including a low-value token — is authorized for every kubelet operation. `mode: Webhook` delegates the authorization decision to the API server (SubjectAccessReview), so only principals with the right RBAC on `nodes/*` subresources succeed. Without it, authentication is meaningless for authorization.
5. Any of: the full list of pods and their specs/namespaces on the node, container environment/mounts, node and pod resource metrics, or running container names/images — all useful for reconnaissance and for locating Secrets-bearing workloads.
6. The **kube-apiserver** authenticates to the kubelet on your behalf, using its kubelet client certificate (`--kubelet-client-certificate`/`--kubelet-client-key`), when it proxies `logs`/`exec`/`attach`/`port-forward` requests.

**Exercise 3**

7. IMDS returns the **node's cloud identity credentials** (IAM role temporary keys on AWS, the default service account OAuth token on GCP, a managed-identity token on Azure). A Pod that reads them can call cloud APIs *as the node* — creating resources, reading storage buckets, or escalating in the cloud account. That is privilege escalation out of the cluster, not just disclosure.
8. IMDSv2 stamps the session-token response with an IP TTL/hop limit of 1 by default. A Pod's traffic to `169.254.169.254` is routed/NAT'd through the node's network namespace, adding a hop, so the reply is dropped before it reaches the Pod — the container cannot obtain the session token needed for subsequent metadata reads.

**Exercise 4**

9. NetworkPolicy has no explicit "deny" rules — it is allow-list based, and the effect of an `Egress` policy is "deny everything except what is listed." To keep normal egress working while blocking one address, you must **allow a broad range and subtract the metadata IP** via `ipBlock.except`. Listing the IP as a positive rule would *permit* it; there is no negative rule type.
10. Two of: (a) the CNI plugin does not enforce NetworkPolicy (e.g. Flannel without an add-on); (b) the policy was created in the wrong namespace or the Pods don't match the selector; (c) the metadata traffic is SNAT'd to the node IP before policy evaluation, or the node reaches IMDS via host networking that the Pod inherits (`hostNetwork: true` Pods bypass Pod NetworkPolicy); (d) a more permissive policy also selects the Pods (policies are additive/OR'd, so another egress rule can re-allow the IP).
11. The policy only protects the **`default`** namespace; Pods in the other 11 namespaces still reach IMDS. Close it by applying the same policy in **every namespace** (a per-namespace default managed by GitOps/Kyverno), or use a cluster-scoped control such as a Calico `GlobalNetworkPolicy` / Cilium `CiliumClusterwideNetworkPolicy` that blocks `169.254.169.254/32` across all namespaces.
12. At the cloud layer: enforce **IMDSv2 with a hop limit of 1** (AWS) so containers can't reach the token endpoint, and/or use per-workload cloud identity (IRSA / GKE Workload Identity / Azure Workload Identity) so the node role carries no meaningful permissions. Then even an unblocked metadata call yields nothing worth stealing.

</details>