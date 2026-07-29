# CKS 1.2 — Guided Exercises: Using the CIS Benchmark to Review Kubernetes Component Security

**Exam domain:** Cluster Setup (1.2) · **Weight:** 3

---

## Lab prerequisites

- A `kubeadm`-provisioned cluster, Kubernetes **v1.34**, with at least one control plane node (`cp1`) and one worker (`w1`).
- `root` (or `sudo`) shell access on both nodes.
- `kube-bench` available. If it is not installed, any of these work:
  - binary/package on the node,
  - `docker run --rm -v /etc:/etc:ro -v /var:/var:ro -t aquasec/kube-bench:latest run`,
  - an in-cluster `Job` (Exercise 7).

> **Snapshot your VMs before starting.** Several steps intentionally break the control plane so you can practise recovery.

---

## Exercise 1 — Understand what the benchmark actually is

The **CIS Kubernetes Benchmark** is a consensus-built hardening guide published by the Center for Internet Security. It is a *document*, not a tool. `kube-bench` is one open-source implementation that automates the document's audit commands.

Each benchmark entry has a fixed shape: an **ID** (e.g. `1.2.5`), a **title**, a **scoring type** (Automated or Manual), a **level** (L1 = broadly safe, L2 = defence-in-depth with operational cost), an **audit command**, an **expected result**, and a **remediation**.

1. On `cp1`, confirm which benchmark revisions your tool knows about:

   ```bash
   kube-bench version
   ls /etc/kube-bench/cfg/
   ```

2. Look at the raw check definitions rather than only the output. Pick the newest `cis-*` directory you saw above and inspect it:

   ```bash
   BENCH=$(ls -d /etc/kube-bench/cfg/cis-* | sort -V | tail -1)
   echo "$BENCH"
   ls "$BENCH"
   ```

3. Read the definition of a single API server check:

   ```bash
   grep -A 25 'id: 1.2.5' "$BENCH/master.yaml"
   ```

4. Note the structure: `audit:` (the command run on the node), `tests:` → `test_items:` with `flag`, `compare`, and `set`, plus `remediation:` and `scored:`.

**Questions**

1. Why does reading `master.yaml` matter more than reading the tool's summary output?
2. What is the difference between a check marked `scored: true` and one marked `scored: false`, and how does that surface in the results?
3. The benchmark is versioned independently of Kubernetes (e.g. CIS 1.10 targets Kubernetes 1.29–1.30). Why is check numbering an unreliable thing to memorise?
4. `kube-bench` reads static pod manifests and process arguments. Name one class of misconfiguration it therefore **cannot** detect.

---

## Exercise 2 — Run the benchmark against the control plane

`kube-bench` groups checks into **targets**: `master`, `controlplane`, `etcd`, `node`, `policies`. Which targets are valid depends on the node's role.

1. Run the full control-plane sweep on `cp1`:

   ```bash
   kube-bench run --targets=master,controlplane,etcd,policies
   ```

2. If the tool refuses to start with an error about detecting the version, pin it explicitly:

   ```bash
   kube-bench run --benchmark cis-1.10 --targets=master,etcd
   ```

3. Re-run, suppressing the remediation text so the pass/fail list fits on one screen:

   ```bash
   kube-bench run --targets=master --noremediations
   ```

4. Capture a machine-readable baseline and extract only the failures:

   ```bash
   kube-bench run --targets=master,etcd --json --outputfile /root/bench-baseline.json
   jq -r '.Controls[].tests[].results[]
          | select(.status=="FAIL")
          | "\(.test_number)\t\(.test_desc)"' /root/bench-baseline.json
   ```

   > If the field names differ in your build, discover them with
   > `jq '.Controls[0].tests[0].results[0] | keys' /root/bench-baseline.json`.

5. Count each outcome class:

   ```bash
   jq -r '.Controls[].tests[].results[].status' /root/bench-baseline.json | sort | uniq -c
   ```

6. Run exactly one check, then run everything except a noisy one:

   ```bash
   kube-bench run --targets=master --check 1.2.5
   kube-bench run --targets=master --skip 1.2.5
   ```

**Questions**

5. On `cp1`, why does `--targets=node` usually still produce results even though it is a control plane node?
6. What does a `WARN` status mean, and why is `WARN` more dangerous to ignore than `FAIL` in an audit context?
7. You want the benchmark to fail a CI pipeline when any check fails. Which flag do you add, and what is the risk of wiring it up naively?
8. Why is saving `bench-baseline.json` before you change anything a better workflow than fixing findings as you read them?

---

## Exercise 3 — Fix file permission and ownership findings (section 1.1 / 4.1)

These are the cheapest findings to close and they appear in both control plane and worker sections.

1. On `cp1`, run only the configuration-file section:

   ```bash
   kube-bench run --targets=master --check 1.1.1,1.1.2,1.1.11,1.1.12,1.1.19,1.1.20,1.1.21
   ```

2. Inspect the current state by hand — this is the same thing the audit command does:

   ```bash
   stat -c '%n %a %U:%G' /etc/kubernetes/manifests/*.yaml
   stat -c '%n %a %U:%G' /etc/kubernetes/admin.conf /etc/kubernetes/scheduler.conf
   stat -c '%n %a %U:%G' /var/lib/etcd
   find /etc/kubernetes/pki -name '*.key' -exec stat -c '%n %a %U:%G' {} \;
   ```

3. Deliberately introduce a violation, then confirm the tool catches it:

   ```bash
   chmod 666 /etc/kubernetes/manifests/kube-apiserver.yaml
   kube-bench run --targets=master --check 1.1.1
   ```

4. Remediate to the benchmark's expected value and re-verify:

   ```bash
   chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
   chown root:root /etc/kubernetes/manifests/kube-apiserver.yaml
   kube-bench run --targets=master --check 1.1.1
   ```

5. Harden the etcd data directory and its PKI keys:

   ```bash
   chmod 700 /var/lib/etcd
   chown etcd:etcd /var/lib/etcd 2>/dev/null || chown root:root /var/lib/etcd
   chmod 600 /etc/kubernetes/pki/*.key
   ```

6. Repeat the exercise on the worker. On `w1`:

   ```bash
   kube-bench run --targets=node --check 4.1.1,4.1.2,4.1.9,4.1.10
   stat -c '%n %a %U:%G' /var/lib/kubelet/config.yaml /etc/kubernetes/kubelet.conf
   chmod 600 /var/lib/kubelet/config.yaml
   chown root:root /var/lib/kubelet/config.yaml
   ```

**Questions**

9. `/etc/kubernetes/manifests/*.yaml` is only readable by root either way. Why does the benchmark still insist on `600` rather than `644`?
10. Why is `/var/lib/etcd` singled out with the strictest mode (`700`) of any path in the benchmark?
11. A finding says the *ownership* of `admin.conf` is wrong even though the mode is `600`. Give a scenario where mode alone is insufficient.
12. After `chmod 600` on a static pod manifest, does the kubelet need to be restarted? Why or why not?

---

## Exercise 4 — Remediate kube-apiserver findings (section 1.2)

The API server is configured entirely through flags in `/etc/kubernetes/manifests/kube-apiserver.yaml`. The kubelet watches that directory and restarts the static pod on write.

1. See the flags the benchmark is actually parsing:

   ```bash
   ps -ef | grep '[k]ube-apiserver' | tr ' ' '\n' | grep '^--' | sort
   ```

2. Run the API server section and list its failures:

   ```bash
   kube-bench run --targets=master --json \
     | jq -r '.Controls[].tests[].results[]
              | select(.status=="FAIL" and (.test_number|startswith("1.2")))
              | "\(.test_number)\t\(.test_desc)"'
   ```

3. Back up the manifest before editing — a syntax error here takes the cluster offline:

   ```bash
   cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   ```

4. Apply three low-risk remediations. Edit the manifest and ensure the `command:` list contains:

   ```yaml
       - --profiling=false
       - --service-account-lookup=true
       - --request-timeout=60s
   ```

5. Watch the static pod come back. The container ID changes when the manifest is rewritten:

   ```bash
   watch -n 2 'crictl ps --name kube-apiserver'
   # or, once the API is answering again:
   kubectl -n kube-system get pod kube-apiserver-cp1 -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
   ```

6. Ensure the admission plugin the benchmark requires is present. Find the existing line and add `NodeRestriction` if missing:

   ```bash
   grep 'enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

7. Now trigger the classic trap. Add `--anonymous-auth=false` to the manifest, save, and observe:

   ```bash
   sleep 30
   crictl ps -a --name kube-apiserver
   crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20
   kubectl get nodes
   ```

8. Diagnose it. `kubeadm` configures `livenessProbe`/`readinessProbe`/`startupProbe` against `/livez`, `/readyz` and `/healthz` on port 6443 with **no credentials**. With anonymous auth disabled, the probes get `401`, the kubelet declares the container unhealthy, and it is killed in a loop.

9. Recover:

   ```bash
   cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
   sleep 45 && kubectl get nodes
   ```

10. Apply the modern remediation instead. On Kubernetes 1.32+, anonymous access can be restricted to specific paths via a structured authentication config:

    ```bash
    mkdir -p /etc/kubernetes/auth
    cat > /etc/kubernetes/auth/anonymous.yaml <<'EOF'
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    anonymous:
      enabled: true
      conditions:
      - path: /livez
      - path: /readyz
      - path: /healthz
    EOF
    ```

    Then reference it from the manifest, mounting the directory into the pod:

    ```yaml
        - --authentication-config=/etc/kubernetes/auth/anonymous.yaml
    ```

    ```yaml
        volumeMounts:
        - mountPath: /etc/kubernetes/auth
          name: auth-config
          readOnly: true
      volumes:
      - hostPath:
          path: /etc/kubernetes/auth
          type: DirectoryOrCreate
        name: auth-config
    ```

11. Verify that anonymous requests are now rejected everywhere except the probe paths:

    ```bash
    curl -sk https://127.0.0.1:6443/livez ; echo
    curl -sk https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets | head -5
    ```

**Questions**

13. Why does the benchmark's `--anonymous-auth=false` remediation break a default `kubeadm` cluster, and what exactly fails first?
14. `--authentication-config` and `--anonymous-auth` cannot both be set. What does that imply for a rollback plan?
15. What does `--service-account-lookup=true` protect against that ordinary token signature validation does not?
16. You added a flag and the API server never comes back — `kubectl` times out. Name two ways to read the failure reason without a working API server.
17. Why does `NodeRestriction` appear in the benchmark, and which principal does it constrain?

---

## Exercise 5 — Remediate etcd findings (section 2)

etcd holds every Secret in the cluster in plaintext unless encryption at rest is configured. Compromise of etcd is total compromise of the cluster.

1. Run the etcd section:

   ```bash
   kube-bench run --targets=etcd
   ```

2. Read the live flags:

   ```bash
   ps -ef | grep '[e]tcd ' | tr ' ' '\n' | grep '^--' | sort
   ```

3. Verify the four transport-security properties the benchmark cares about, in the manifest `/etc/kubernetes/manifests/etcd.yaml`:

   ```bash
   grep -E 'cert-file|key-file|client-cert-auth|auto-tls|trusted-ca-file|peer-' \
     /etc/kubernetes/manifests/etcd.yaml
   ```

   You should see `--client-cert-auth=true`, `--peer-client-cert-auth=true`, and **no** `--auto-tls=true` or `--peer-auto-tls=true`.

4. Prove that client certificate authentication is enforced. First, an unauthenticated attempt:

   ```bash
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     endpoint health
   ```

   Then a correctly authenticated one:

   ```bash
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     endpoint health
   ```

5. Demonstrate why this matters — read a Secret straight out of the datastore:

   ```bash
   kubectl -n default create secret generic cis-demo --from-literal=password=Sup3rS3cret
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/default/cis-demo | strings | grep -i sup3r
   ```

6. Confirm the API server talks to etcd over mTLS with a dedicated identity:

   ```bash
   grep -E 'etcd-(cafile|certfile|keyfile)' /etc/kubernetes/manifests/kube-apiserver.yaml
   openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt -noout -subject -issuer
   ```

7. Check whether etcd uses a CA distinct from the cluster CA:

   ```bash
   openssl x509 -in /etc/kubernetes/pki/etcd/ca.crt -noout -subject -fingerprint
   openssl x509 -in /etc/kubernetes/pki/ca.crt      -noout -subject -fingerprint
   ```

**Questions**

18. What does `--client-cert-auth=true` add on top of already having `--cert-file` and `--key-file` set?
19. Why does the benchmark insist on `--auto-tls=false` when auto-TLS still encrypts the connection?
20. Step 5 exposed a Secret in plaintext. Which additional control closes this, and is it an etcd flag or an API server flag?
21. The benchmark asks for etcd to use a **unique** CA. What attack does sharing the cluster CA with etcd enable?
22. Explain the practical difference between the `--peer-*` flags and the client-facing ones.

---

## Exercise 6 — Remediate kubelet findings (section 4.2)

The kubelet is the most attractive target on a worker: it can exec into any pod on the node. Modern `kubeadm` clusters configure it through `/var/lib/kubelet/config.yaml`, **not** command-line flags — and config-file settings are what you must edit.

1. On `w1`, run the kubelet section:

   ```bash
   kube-bench run --targets=node
   ```

2. Determine where configuration actually comes from:

   ```bash
   systemctl cat kubelet | grep -E 'ExecStart|EnvironmentFile|--config'
   cat /var/lib/kubelet/config.yaml
   ```

3. Confirm the current authn/authz posture. These are the two highest-value checks in the whole section:

   ```bash
   grep -A 5 -E '^authentication:|^authorization:' /var/lib/kubelet/config.yaml
   ```

   Expected: `authentication.anonymous.enabled: false`, `authentication.x509.clientCAFile` set, `authorization.mode: Webhook`.

4. Prove the effect by attacking the kubelet API from the node itself:

   ```bash
   curl -sk https://127.0.0.1:10250/pods | head -c 200 ; echo
   curl -s  http://127.0.0.1:10255/pods | head -c 200 ; echo
   ```

   The first should return `401 Unauthorized`; the second should fail to connect because `readOnlyPort` is `0`.

5. Temporarily weaken the kubelet to see the failure surface, then observe what an attacker gains:

   ```bash
   cp /var/lib/kubelet/config.yaml /root/kubelet-config.yaml.bak
   sed -i 's/^\( *\)enabled: false/\1enabled: true/' /var/lib/kubelet/config.yaml
   systemctl restart kubelet && sleep 10
   curl -sk https://127.0.0.1:10250/pods | jq -r '.items[].metadata.name' | head
   kube-bench run --targets=node --check 4.2.1
   ```

6. Restore immediately:

   ```bash
   cp /root/kubelet-config.yaml.bak /var/lib/kubelet/config.yaml
   systemctl restart kubelet && sleep 10
   kube-bench run --targets=node --check 4.2.1
   ```

7. Apply the remaining common remediations. Edit `/var/lib/kubelet/config.yaml` so it contains:

   ```yaml
   readOnlyPort: 0
   streamingConnectionIdleTimeout: 5m
   makeIPTablesUtilChains: true
   eventRecordQPS: 5
   rotateCertificates: true
   serverTLSBootstrap: true
   tlsCipherSuites:
     - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
     - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
     - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
   ```

8. Now the second classic trap — `protectKernelDefaults`. Add it and restart:

   ```bash
   echo 'protectKernelDefaults: true' >> /var/lib/kubelet/config.yaml
   systemctl restart kubelet
   sleep 5
   systemctl is-active kubelet
   journalctl -u kubelet --no-pager -n 30 | grep -i sysctl
   ```

9. If the kubelet refuses to start, set the kernel parameters the kubelet expects rather than reverting the setting:

   ```bash
   cat > /etc/sysctl.d/99-kubelet-cis.conf <<'EOF'
   vm.overcommit_memory = 1
   vm.panic_on_oom = 0
   kernel.panic = 10
   kernel.panic_on_oops = 1
   EOF
   sysctl --system
   systemctl restart kubelet && systemctl is-active kubelet
   ```

10. Re-run the section and diff against your baseline:

    ```bash
    kube-bench run --targets=node --noremediations
    ```

11. If you enabled `serverTLSBootstrap`, the kubelet's serving certificate now needs approval:

    ```bash
    kubectl get csr
    kubectl certificate approve <csr-name>
    ```

**Questions**

23. Why does `authorization.mode: Webhook` matter even when `anonymous.enabled` is already `false`?
24. What exactly could an attacker do on port `10255` if `readOnlyPort` were left at its old default of `10255`?
25. Why does `protectKernelDefaults: true` prevent the kubelet from starting on some hosts, and what is the security argument for keeping it on anyway?
26. You edited `/var/lib/kubelet/config.yaml` but `kube-bench` still reports the old value. Give two distinct causes.
27. `rotateCertificates` and `serverTLSBootstrap` cover different certificates. Which is which, and why does the second one create pending CSRs?
28. Why is `streamingConnectionIdleTimeout: 0` a finding rather than a convenience?

---

## Exercise 7 — Audit CoreDNS (the "kubedns" component)

The benchmark has no dedicated DNS section, so this component is reviewed through the general policy checks in section 5 plus manual inspection. CoreDNS is highly exposed: every pod in the cluster can reach it by default.

1. Inspect the workload's security posture:

   ```bash
   kubectl -n kube-system get deploy coredns -o yaml \
     | grep -A 15 -E 'securityContext|serviceAccountName|automountServiceAccountToken'
   ```

   Look for `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and capabilities dropped to `ALL` with only `NET_BIND_SERVICE` added.

2. Check what its ServiceAccount is permitted to do:

   ```bash
   kubectl -n kube-system get sa coredns
   kubectl get clusterrole system:coredns -o yaml
   kubectl get clusterrolebinding system:coredns -o yaml
   ```

3. Run the policy checks and read the manual guidance:

   ```bash
   kube-bench run --targets=policies
   ```

4. Verify the two `default` ServiceAccount checks the benchmark raises, using CoreDNS's namespace as the example:

   ```bash
   kubectl -n kube-system get sa default -o yaml | grep -i automount
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
              | "\(.metadata.name)\t\(.subjects[]?.kind):\(.subjects[]?.name)"'
   ```

5. Read the CoreDNS configuration for risky plugins:

   ```bash
   kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
   ```

   Confirm there is no wildcard `proxy`/`forward` to an untrusted resolver and that the `kubernetes` plugin is scoped to `cluster.local`.

6. Demonstrate the flat-network exposure, then constrain it:

   ```bash
   kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
     nslookup kubernetes.default.svc.cluster.local
   ```

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: coredns-ingress
     namespace: kube-system
   spec:
     podSelector:
       matchLabels:
         k8s-app: kube-dns
     policyTypes: ["Ingress"]
     ingress:
     - ports:
       - protocol: UDP
         port: 53
       - protocol: TCP
         port: 53
   EOF
   ```

7. Re-test resolution to confirm you did not break the cluster:

   ```bash
   kubectl run probe --image=busybox:1.36 --restart=Never -it --rm -- \
     nslookup kubernetes.default.svc.cluster.local
   ```

**Questions**

29. Why does CoreDNS need `NET_BIND_SERVICE` but nothing else?
30. Benchmark check 5.1.5 says the `default` ServiceAccount should not be actively used and should not auto-mount its token. What is the concrete attack this prevents?
31. The NetworkPolicy above allows ingress on 53 from **any** source. Why is it still an improvement over having no policy at all, and what would a stricter version look like?
32. If CoreDNS were compromised, name two attacks the attacker could mount against workloads that never touch the API server.

---

## Exercise 8 — Run the benchmark in-cluster and produce a report

In real clusters — and in nodes you cannot SSH into — the benchmark runs as a Job.

1. Create a Job that runs `kube-bench` on the control plane node:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: kube-bench-master
     namespace: default
   spec:
     template:
       spec:
         hostPID: true
         nodeSelector:
           node-role.kubernetes.io/control-plane: ""
         tolerations:
         - key: node-role.kubernetes.io/control-plane
           operator: Exists
           effect: NoSchedule
         containers:
         - name: kube-bench
           image: docker.io/aquasec/kube-bench:latest
           command: ["kube-bench", "run", "--targets", "master,etcd,controlplane,policies"]
           volumeMounts:
           - name: var-lib-etcd
             mountPath: /var/lib/etcd
             readOnly: true
           - name: etc-kubernetes
             mountPath: /etc/kubernetes
             readOnly: true
           - name: etc-systemd
             mountPath: /etc/systemd
             readOnly: true
         restartPolicy: Never
         volumes:
         - name: var-lib-etcd
           hostPath: {path: /var/lib/etcd}
         - name: etc-kubernetes
           hostPath: {path: /etc/kubernetes}
         - name: etc-systemd
           hostPath: {path: /etc/systemd}
   EOF
   ```

2. Read the report:

   ```bash
   kubectl wait --for=condition=complete job/kube-bench-master --timeout=120s
   kubectl logs job/kube-bench-master | tail -40
   ```

3. Compare your post-remediation state against the baseline you saved in Exercise 2:

   ```bash
   kube-bench run --targets=master,etcd --json --outputfile /root/bench-after.json
   diff <(jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | .test_number' /root/bench-baseline.json | sort) \
        <(jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | .test_number' /root/bench-after.json    | sort)
   ```

4. Clean up:

   ```bash
   kubectl delete job kube-bench-master
   kubectl -n default delete secret cis-demo
   kubectl -n kube-system delete networkpolicy coredns-ingress
   ```

**Questions**

33. The Job mounts `/etc/kubernetes` and `/var/lib/etcd` read-only from the host. Why is a Pod that can do this effectively a control-plane-level privilege?
34. `hostPID: true` is set. What does `kube-bench` use it for, and what is the security cost of granting it?
35. The Job scheduled onto the control plane node needs a toleration. What happens to the results if it lands on a worker instead?
36. Your diff shows a check that moved from `FAIL` to `PASS` without you changing anything. Give two plausible explanations.

---

<details>
<summary><strong>Answer key</strong> — click to expand</summary>

### Exercise 1

**1.** The summary tells you *that* a check failed; `master.yaml` tells you *what command was run* and *what string it compared*. That matters because the tool's parsing is textual and can produce false results — for example, a flag set in a config file rather than on the command line, a flag that appears twice, or a value the tool matches with `has` rather than an exact comparison. In an exam or an audit you have to be able to justify a verdict, not just report one.

**2.** `scored: true` checks contribute to the pass/fail total and are meant to be machine-verifiable ("Automated" in CIS language). `scored: false` checks ("Manual") require human judgement — the tool cannot decide, so it emits `WARN` and prints the guidance instead of a verdict. They still count as unreviewed risk.

**3.** Benchmark revisions renumber, merge, split, and retire checks as Kubernetes changes. Checks for the removed insecure port (`--insecure-port`, `--insecure-bind-address`) disappeared entirely once those flags were dropped from Kubernetes; the kubelet `--hostname-override` check was retired; the section 5 policy checks were reorganised around Pod Security Standards after PodSecurityPolicy was removed. Memorise the *control* ("the kubelet must not allow anonymous authentication") and look up the number.

**4.** Anything not visible in a process argument list or an on-disk config file. Examples: RBAC bindings that grant excessive privilege, whether audit logs are actually shipped anywhere, whether the certificates in use are actually trustworthy, admission webhook behaviour, runtime container configuration, and network reachability. It also cannot see managed control planes (EKS/GKE/AKS) where the API server is not a process on your node.

### Exercise 2

**5.** A `kubeadm` control plane node also runs a kubelet and `kube-proxy` — it *is* a node. Section 4 checks apply to it, and a hardened API server on a node with an anonymous-auth kubelet is not hardened at all.

**6.** `WARN` means the check is Manual or the tool could not gather enough information to decide. It is more dangerous than `FAIL` because a `FAIL` is a known defect with a known fix, while a `WARN` is an *unknown* — teams routinely filter `WARN` out of dashboards and then report "zero findings" on a cluster with unreviewed controls. Silent truncation of an audit reads as coverage it does not have.

**7.** `--exit-code 1` makes `kube-bench` exit non-zero when there is at least one `FAIL`. The naive risk: any benchmark upgrade adds new checks, so a pipeline that was green yesterday goes red today for reasons unrelated to your change. Mitigate by pinning `--benchmark`, maintaining an explicit `--skip` list with documented justifications, and reviewing skips on a schedule.

**8.** Three reasons. First, you need a before/after diff to prove the remediation worked — otherwise you are asserting it. Second, some remediations change *other* checks as a side effect, and only a diff reveals that. Third, if you break the cluster you need to know what the working configuration looked like.

### Exercise 3

**9.** Defence in depth against a *partial* compromise. Any process running as a non-root user that can read the manifest learns the full control plane topology, certificate paths, etcd endpoints, and admission configuration — useful reconnaissance for privilege escalation. It also matters for backup tooling, log shippers, and monitoring agents that often run as unprivileged users with broad filesystem read access.

**10.** `/var/lib/etcd` contains every object in the cluster, including every Secret, in plaintext unless encryption at rest is enabled. Read access to that directory is equivalent to `cluster-admin` plus every credential the cluster holds. There is no more sensitive path on the machine. `700` also blocks group access, which matters because container runtime and monitoring accounts are frequently placed in shared groups.

**11.** Mode `600` means "owner read/write only" — but if the owner is not `root`, then whatever account *does* own it has full access. A common real case: a misconfigured backup or configuration-management run leaves `admin.conf` owned by a service account, so that service account holds a `cluster-admin` kubeconfig despite the restrictive mode. Mode governs *who else*; ownership governs *who*.

**12.** No. The kubelet watches `/etc/kubernetes/manifests` for changes to file *content*, and a metadata-only change (mode/owner) does not alter content, so nothing restarts. This is convenient: permission remediation on the control plane is zero-downtime. Flag changes in step 4 of Exercise 4 are the opposite — those rewrite the file and do trigger a pod restart.

### Exercise 4

**13.** `kubeadm` gives the `kube-apiserver` static pod `startupProbe`, `livenessProbe`, and `readinessProbe` entries that issue plain HTTPS `GET` requests to `/livez`, `/readyz`, and `/healthz` on port 6443 with no client credentials. Those are anonymous requests. With `--anonymous-auth=false` they return `401`, the kubelet counts them as probe failures, and the startup/liveness probe kills the container — which then fails again on restart. The first visible symptom is the API server container restarting in a loop and `kubectl` timing out.

**14.** The two are mutually exclusive: setting both makes the API server refuse to start. So the rollback is not "remove one line" — you must remove `--authentication-config`, and if you had also removed the mounted volume you must restore that too, or the container will fail on a missing path. Keep the backup manifest and roll back the whole file, not individual flags. Also note that `--authentication-config` reads from inside the pod's filesystem, so the `hostPath` volume and `volumeMount` must both be present or the API server exits before it ever serves a request.

**15.** Signature validation only proves the token was issued by this cluster's signing key. `--service-account-lookup=true` makes the API server additionally verify that the corresponding Secret/token object still exists in etcd. Without it, a legacy static ServiceAccount token that was stolen remains valid forever even after you delete the ServiceAccount — revocation silently does nothing. (Modern bound tokens carry expiry and audience, which reduces but does not eliminate the concern.)

**16.** Any two of: `crictl ps -a --name kube-apiserver` plus `crictl logs <id>` to read the container's stderr directly from the runtime; `journalctl -u kubelet -f` to see the kubelet's view of why it is restarting the static pod; reading `/var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log` on disk; or `docker ps -a` / `docker logs` on a Docker-based runtime. The key insight is that a static pod does not need the API server to run, so the runtime and the kubelet still have the evidence.

**17.** `NodeRestriction` is an admission plugin that limits what a kubelet can do with its own node identity: it may only modify its own `Node` object and only `Pod` objects bound to itself, and it cannot add or remove certain labels. It constrains the `system:node:<name>` principal. Without it, stealing any single kubelet's credentials lets an attacker manipulate other nodes' objects and label themselves into privileged scheduling positions.

### Exercise 5

**18.** `--cert-file`/`--key-file` give etcd a server certificate — that gets you encryption and server authentication, but any client that trusts the CA can connect. `--client-cert-auth=true` makes etcd *require* clients to present a certificate signed by the trusted CA, turning one-way TLS into mutual TLS. Without it, network access to port 2379 is access to the entire datastore.

**19.** Auto-TLS makes etcd generate its own self-signed certificates at startup. The traffic is encrypted, but there is no trusted CA to validate against, so peer and client identities cannot be verified — the encryption protects against passive eavesdropping while leaving the deployment open to an active man-in-the-middle or to any client that connects. Encryption without authentication is not a security control.

**20.** Encryption at rest, configured with the API server flag `--encryption-provider-config` pointing at an `EncryptionConfiguration` (AES-CBC/AES-GCM/KMS providers). It is deliberately an **API server** flag, not an etcd flag: the API server encrypts resources before writing them, so etcd never sees plaintext. Existing Secrets stay in their old form until rewritten — `kubectl get secrets -A -o json | kubectl replace -f -` forces the re-encryption.

**21.** If etcd trusts the cluster CA, then *any* certificate that CA issues becomes a valid etcd client certificate. The cluster CA routinely signs kubelet client certificates via the CSR API. So an attacker who compromises a single worker node — or who can get a CSR approved — obtains a certificate that authenticates directly to etcd, bypassing the API server, RBAC, admission control, and audit logging entirely. A separate etcd CA breaks that chain.

**22.** The `--cert-file`/`--key-file`/`--client-cert-auth`/`--trusted-ca-file` set governs the **client-to-server** channel on port 2379 — this is how the API server talks to etcd. The `--peer-*` equivalents govern the **server-to-server** replication channel on port 2380 between etcd members. Both need mTLS: an unauthenticated peer channel lets an attacker join the cluster as a bogus member and read or write the full keyspace via replication, without ever touching port 2379.

### Exercise 6

**23.** Authentication answers "who are you"; authorization answers "what may you do". With `anonymous.enabled: false` and `authorization.mode: AlwaysAllow`, *any* client that can present a certificate signed by the kubelet's client CA — including every other node's kubelet credential, or any workload that obtains one — gets unrestricted access to the kubelet API: listing pods, reading logs, and `exec`ing into containers on that node. `Webhook` mode delegates each request to the API server's `SubjectAccessReview`, so RBAC actually applies.

**24.** Port 10255 is the read-only kubelet port: no authentication, no authorization, plain HTTP. An attacker with pod-network access could enumerate `/pods` to get every pod spec on the node — including environment variables, which frequently contain credentials — plus `/metrics` and `/spec` for node reconnaissance. It requires no credentials at all, so it is reachable from any compromised pod on the network. Setting `readOnlyPort: 0` disables it; this is the `kubeadm` default on current versions.

**25.** With `protectKernelDefaults: true`, the kubelet refuses to overwrite kernel sysctl values and instead **errors out at startup** if the host's values do not already match what it expects (`vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`). The security argument: without it, the kubelet silently mutates host kernel tunables at startup, which means a compromised or misconfigured kubelet can change the security-relevant behaviour of the whole machine, and your host hardening baseline is not actually in force. Fix the host, do not disable the flag.

**26.** Any two of: (a) you did not restart the kubelet, so the running process still holds the old configuration — the config file is read at startup, not watched (unless dynamic reload is enabled); (b) the setting is *also* present as a command-line flag in the systemd unit or drop-in, and flags win over the config file; (c) you edited the file on the wrong node; (d) YAML indentation put the key in the wrong block, so the kubelet ignored it — check `journalctl -u kubelet` for a parse warning; (e) `kube-bench` is reading a different config path than the one the kubelet was started with.

**27.** `rotateCertificates: true` rotates the kubelet's **client** certificate — the credential it uses to authenticate *to* the API server. `serverTLSBootstrap: true` makes the kubelet request its **serving** certificate — the one it presents to clients on port 10250 — from the API server via the CSR API instead of self-signing it. The second creates pending CSRs because serving-certificate CSRs are not auto-approved by the default controller (auto-approving them would let a node claim arbitrary names/IPs), so a human or a dedicated approver controller must approve each one.

**28.** `streamingConnectionIdleTimeout: 0` disables the timeout on `exec`, `attach`, and `port-forward` streams. An abandoned or hijacked session then stays open indefinitely: it survives credential rotation and RBAC revocation, because the authorization decision was made once at connection time. It is also a resource-exhaustion vector. The benchmark asks for a non-zero value, conventionally `5m` or more.

### Exercise 7

**29.** CoreDNS binds UDP and TCP port 53, which is below 1024 and therefore requires `CAP_NET_BIND_SERVICE` on Linux when running as a non-root user. Everything else — filesystem writes, raw sockets, module loading, `chroot` — is unnecessary for a DNS server that reads its zone data from the API and its configuration from a mounted ConfigMap. Hence `drop: [ALL]` plus a single `add: [NET_BIND_SERVICE]`, with `readOnlyRootFilesystem: true` and `allowPrivilegeEscalation: false`.

**30.** Every pod that does not name a ServiceAccount gets the namespace's `default` one, and by default its token is mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. If an attacker achieves code execution in *any* such pod, they immediately hold a valid API credential with whatever the `default` SA has been granted — and in clusters where someone bound `default` to a broad Role (or to `cluster-admin`), that is instant escalation. Setting `automountServiceAccountToken: false` on the SA or the Pod removes the credential from the blast radius of a container compromise.

**31.** Before the policy, CoreDNS pods have no ingress restriction whatsoever: any pod in the cluster can reach *any* port on them, including metrics on 9153, the health endpoint on 8080/8181, and — if a sidecar or debug port were ever added — that too. After the policy, only 53/UDP and 53/TCP are reachable, which shrinks the attack surface to the one service CoreDNS is supposed to offer. A stricter version adds `from:` selectors, but that is rarely practical since every namespace legitimately needs DNS; the realistic tightening is a separate policy allowing 9153 only from the monitoring namespace, plus an egress policy limiting CoreDNS to the API server and the upstream resolvers.

**32.** Any two of: (a) DNS poisoning — return attacker-controlled IPs for `internal-service.default.svc.cluster.local`, redirecting service-to-service traffic to a proxy that harvests credentials and tokens from the intercepted requests; (b) exfiltration via the `forward` plugin — point upstream resolution at an attacker-controlled nameserver and tunnel data out over DNS queries, which frequently bypasses egress filtering; (c) denial of service by returning NXDOMAIN for critical names, which breaks the whole cluster since almost every workload resolves service names; (d) reconnaissance — CoreDNS's ServiceAccount can list Services and EndpointSlices cluster-wide, so its token maps the entire cluster topology.

### Exercise 8

**33.** `/etc/kubernetes` contains `admin.conf` (a `cluster-admin` kubeconfig) and the entire `pki/` tree, including `ca.key` — the cluster's signing key. Read access to `ca.key` lets an attacker mint a client certificate for any user or group, including `system:masters`, which bypasses RBAC entirely and is not revocable without rotating the CA. `/var/lib/etcd` gives every Secret in plaintext. So the ability to create this Pod is the ability to become cluster-admin permanently — which is exactly why the benchmark's policy section flags Pods that mount sensitive host paths, and why `hostPath` should be blocked by admission control for anything but audited, short-lived workloads.

**34.** `kube-bench` uses the host PID namespace to inspect the command lines of control plane processes (`kube-apiserver`, `etcd`, `kubelet`) that run outside its own container — that is how it reads the flags it audits. The cost: `hostPID` lets the container see and signal every process on the node, read `/proc/<pid>/environ` for other processes' environment variables (a common credential leak), and, combined with other privileges, escape to the host. It is a genuine privilege grant, not a formality.

**35.** The `master` and `etcd` targets would report a large number of failures or errors — not because the cluster is insecure, but because `/etc/kubernetes/manifests/kube-apiserver.yaml` and `/var/lib/etcd` do not exist on a worker. The lesson: benchmark results are only meaningful when the target matches the node's actual role, and "everything failed" is more often a targeting mistake than a finding. Always confirm the node the Job landed on before acting on results.

**36.** Any two of: (a) a remediation you applied for a different check also satisfied this one — for example, replacing the API server manifest to add a flag also corrected its file mode; (b) `kube-bench` selected a different benchmark revision on the second run (auto-detection can shift after a component version changes), and that revision defines the check differently or retires it; (c) the check is timing-sensitive and the component had not finished restarting during the first run, so the tool read a stale or absent process; (d) the check is Manual and the tool's `WARN`/`PASS` handling differs between the two invocations' flag sets.

</details>

---

## References

- CKS Curriculum v1.34, CNCF — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- CIS Kubernetes Benchmark (registration required) — <https://www.cisecurity.org/benchmark/kubernetes>
- `kube-bench`, Aqua Security — <https://github.com/aquasecurity/kube-bench>
- Kubernetes documentation, kubelet configuration file — <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/>
- Kubernetes documentation, `kubelet` reference — <https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/>
- Kubernetes documentation, `kube-apiserver` reference — <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>
- Kubernetes documentation, authenticating (anonymous requests and `AuthenticationConfiguration`) — <https://kubernetes.io/docs/reference/access-authn-authz/authentication/>
- Kubernetes documentation, using Node Authorization and `NodeRestriction` — <https://kubernetes.io/docs/reference/access-authn-authz/node/>
- Kubernetes documentation, encrypting confidential data at rest — <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>
- Kubernetes documentation, operating etcd clusters for Kubernetes — <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Kubernetes documentation, kubelet TLS bootstrapping and certificate rotation — <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/>
- Kubernetes documentation, customizing DNS service (CoreDNS) — <https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/>
- Kubernetes documentation, network policies — <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- etcd documentation, transport security model — <https://etcd.io/docs/latest/op-guide/security/>