# CKS 5.3 — Minimize External Access to the Network
## Guided Exercises (Kubernetes v1.34)

> **Domain:** System Hardening · **Exam weight:** 2.5 %
> **Goal:** reduce the reachable surface of a Kubernetes node and of the workloads on it — at the host (kernel packet filter, systemd services, sshd), at the control-plane component level (bind addresses, ports), and at the Kubernetes API level (Service types, `kube-proxy` bind scope, NetworkPolicy, admission control).

### Lab assumptions

| Item | Value |
|---|---|
| Cluster | `kubeadm`, Kubernetes **v1.34** |
| Control plane | `cp01` — `192.168.56.10` |
| Worker | `w01` — `192.168.56.11` |
| Node OS | Ubuntu 24.04 LTS, `nftables` backend |
| CNI | Calico (any NetworkPolicy-capable CNI works) |
| Pod CIDR / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` |
| Access | `root` (or `sudo`) on both nodes, `cluster-admin` kubeconfig |

> **Warning — do not run these on a cluster you care about without a snapshot.** Several steps change packet-filter state and kubelet configuration. Every exercise ends with a rollback step.

---

## Exercise 1 — Build a ground-truth inventory of the node's listening surface

You cannot minimize what you have not enumerated. Firewall rules written from memory are how port `10255` stays open for three years.

1. On `cp01`, list every listening TCP socket with its owning process:

   ```bash
   sudo ss -lntp
   ```

   Expected (abridged, control-plane node):

   ```
   State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
   LISTEN  0       4096     127.0.0.1:10248      0.0.0.0:*          users:(("kubelet",pid=921,fd=20))
   LISTEN  0       4096     127.0.0.1:10249      0.0.0.0:*          users:(("kube-proxy",pid=1755,fd=14))
   LISTEN  0       4096     127.0.0.1:2379       0.0.0.0:*          users:(("etcd",pid=1402,fd=9))
   LISTEN  0       4096  192.168.56.10:2379      0.0.0.0:*          users:(("etcd",pid=1402,fd=10))
   LISTEN  0       4096  192.168.56.10:2380      0.0.0.0:*          users:(("etcd",pid=1402,fd=8))
   LISTEN  0       4096     127.0.0.1:2381       0.0.0.0:*          users:(("etcd",pid=1402,fd=12))
   LISTEN  0       4096     127.0.0.1:10257      0.0.0.0:*          users:(("kube-controller",pid=1385,fd=3))
   LISTEN  0       4096     127.0.0.1:10259      0.0.0.0:*          users:(("kube-scheduler",pid=1361,fd=3))
   LISTEN  0       4096       0.0.0.0:10250      0.0.0.0:*          users:(("kubelet",pid=921,fd=21))
   LISTEN  0       4096       0.0.0.0:10256      0.0.0.0:*          users:(("kube-proxy",pid=1755,fd=16))
   LISTEN  0       4096             *:6443             *:*          users:(("kube-apiserver",pid=1420,fd=3))
   LISTEN  0       4096       0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=804,fd=3))
   ```

2. Do the same for UDP, and include sockets held by containers in the host network namespace:

   ```bash
   sudo ss -lunp
   sudo lsof -nP -i -sTCP:LISTEN | awk '{print $1, $2, $9}' | sort -u
   ```

3. Separate "bound to loopback" from "bound to the world". This is the single most useful triage command of the whole domain:

   ```bash
   sudo ss -lntH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\])' | sort -u
   ```

   Expected:

   ```
   *:6443
   0.0.0.0:10250
   0.0.0.0:10256
   0.0.0.0:22
   192.168.56.10:2379
   192.168.56.10:2380
   ```

4. Confirm the picture from *outside* the node — a local `ss` cannot tell you what a firewall already blocks. From `w01`:

   ```bash
   nmap -Pn -n -sS -p 22,2379,2380,6443,10248-10260,30000-30010 192.168.56.10
   ```

   Expected:

   ```
   PORT      STATE    SERVICE
   22/tcp    open     ssh
   2379/tcp  open     etcd-client
   2380/tcp  open     etcd-server
   6443/tcp  open     sun-sr-https
   10250/tcp open     unknown
   10256/tcp open     unknown
   10248/tcp filtered unknown
   ```

5. Snapshot the inventory so you can diff after every change:

   ```bash
   sudo ss -lntuH | awk '{print $1, $5}' | sort -u | sudo tee /root/baseline-listeners.txt
   ```

**Questions**

- **Q1.1** — In step 3 you excluded `127.0.0.1`. Why is a component listening on `127.0.0.1:10257` materially safer than one listening on `0.0.0.0:10257`, given that both are on the same host?
- **Q1.2** — `nmap` reports `10248/tcp filtered` while `ss` on the node shows it `LISTEN`. Explain the discrepancy, and state what `filtered` means as opposed to `closed`.
- **Q1.3** — `kube-proxy` binds `10249` to `127.0.0.1` but `10256` to `0.0.0.0`. What are those two ports, and why does the default differ?
- **Q1.4** — A pod running with `hostNetwork: true` opens a listener on `0.0.0.0:9000`. Would it appear in `ss -lntp` on the node? What about a normal pod that exposes `containerPort: 9000`?

---

## Exercise 2 — Close the kubelet's unauthenticated surfaces

The kubelet is the highest-value target on any node: port `10250` gives `exec` into every container it runs.

1. Locate the kubelet configuration and inspect the security-relevant keys:

   ```bash
   sudo grep -E 'readOnlyPort|anonymous|authorization|mode:|enabled:|healthzPort|port:' \
     -A1 /var/lib/kubelet/config.yaml
   ```

   Expected on a well-configured `kubeadm` node:

   ```yaml
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
   authorization:
     mode: Webhook
   ```

2. **Do not trust an absent key.** `readOnlyPort` defaults to `10255` in the kubelet's own defaulting code when it is not set. Verify empirically instead of reading the file:

   ```bash
   sudo ss -lntp | grep -E ':(10250|10255|10248)\b'
   curl -s --max-time 3 http://192.168.56.10:10255/pods | head -c 200; echo
   ```

   If `10255` is open you will get an unauthenticated JSON dump of every pod on the node — including `env` values injected from ConfigMaps:

   ```
   {"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-cp01",...
   ```

3. Probe the authenticated port anonymously and confirm it rejects you:

   ```bash
   curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.56.10:10250/pods
   ```

   Expected: `401`.
   `403` would mean anonymous *authentication* succeeded and only *authorization* stopped you — a weaker posture. `200` means the node is fully compromised by anyone who can reach it.

4. Harden explicitly. Edit `/var/lib/kubelet/config.yaml`:

   ```yaml
   apiVersion: kubelet.config.k8s.io/v1beta1
   kind: KubeletConfiguration
   readOnlyPort: 0
   healthzBindAddress: 127.0.0.1
   healthzPort: 10248
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
       cacheTTL: 2m0s
     x509:
       clientCAFile: /etc/kubernetes/pki/ca.crt
   authorization:
     mode: Webhook
   ```

5. Apply and verify:

   ```bash
   sudo systemctl restart kubelet
   sudo systemctl is-active kubelet
   sudo ss -lntp | grep -E ':(10250|10255)\b'
   kubectl get nodes
   ```

   Expected: only `10250` remains; the node stays `Ready`.

6. Confirm the read-only port is gone from outside:

   ```bash
   curl -s --max-time 3 http://192.168.56.10:10255/pods || echo "refused/timeout — good"
   ```

**Questions**

- **Q2.1** — With `authentication.anonymous.enabled: false` and `authorization.mode: Webhook`, describe end-to-end what happens when the API server calls `POST /exec/...` on the kubelet. Which two API objects does the webhook path consult?
- **Q2.2** — Why is `authorization.mode: AlwaysAllow` catastrophic even when anonymous authentication is disabled?
- **Q2.3** — `readOnlyPort: 10255` serves no write operations. Give two concrete pieces of sensitive data an attacker extracts from it, and name the endpoint for each.
- **Q2.4** — After you set `readOnlyPort: 0`, a monitoring agent that scraped `http://$NODE_IP:10255/metrics/cadvisor` breaks. What is the correct replacement path, and what identity does the scraper now need?

---

## Exercise 3 — Verify the bind addresses of the remaining control-plane components

1. Inspect the static pod manifests for the flags that decide *who can reach* each component:

   ```bash
   sudo grep -HE 'bind-address|listen-client-urls|listen-peer-urls|listen-metrics-urls|secure-port' \
     /etc/kubernetes/manifests/*.yaml
   ```

   Expected:

   ```
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.10:2379
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-metrics-urls=http://127.0.0.1:2381
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-peer-urls=https://192.168.56.10:2380
   /etc/kubernetes/manifests/kube-apiserver.yaml:    - --bind-address=0.0.0.0
   /etc/kubernetes/manifests/kube-apiserver.yaml:    - --secure-port=6443
   /etc/kubernetes/manifests/kube-controller-manager.yaml:    - --bind-address=127.0.0.1
   /etc/kubernetes/manifests/kube-scheduler.yaml:    - --bind-address=127.0.0.1
   ```

2. Prove that the loopback binding actually holds, from `w01`:

   ```bash
   curl -sk --max-time 3 https://192.168.56.10:10259/healthz || echo "unreachable — expected"
   curl -sk --max-time 3 https://192.168.56.10:2379/health   || echo "unreachable or TLS-rejected"
   ```

3. On a single-control-plane cluster, `etcd` has no peers, so `2380` need not be on the LAN. Narrow the client URL too — but understand the constraint first:

   ```bash
   sudo grep -E 'advertise-client-urls|initial-advertise-peer-urls' /etc/kubernetes/manifests/etcd.yaml
   ```

   ```
   - --advertise-client-urls=https://192.168.56.10:2379
   - --initial-advertise-peer-urls=https://192.168.56.10:2380
   ```

4. Rather than changing `etcd`'s topology (which breaks HA scale-out later), enforce the restriction in the packet filter — done in Exercise 4.

5. Confirm `etcd` refuses unauthenticated clients even when reachable:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://192.168.56.10:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt endpoint health
   ```

   Expected: a TLS handshake failure — `etcd` requires a client certificate (`--client-cert-auth=true`).

**Questions**

- **Q3.1** — `kube-apiserver` binds `0.0.0.0` while `kube-scheduler` binds `127.0.0.1`. Justify both defaults in terms of who the legitimate clients of each component are.
- **Q3.2** — Why is restricting network access to `etcd` a *defence in depth* control rather than the primary one, and what is the primary one?
- **Q3.3** — `--listen-metrics-urls=http://127.0.0.1:2381` is plain HTTP. Is that a finding? Justify.
- **Q3.4** — You set `--bind-address=127.0.0.1` on `kube-apiserver` on a single-node cluster and the cluster keeps working from that node, but `kubelet` on `w01` goes `NotReady`. Explain the failure path.

---

## Exercise 4 — Host packet filter with `nftables`, without breaking `kube-proxy`

A Kubernetes node is *already* a packet-filtering appliance: `kube-proxy` and the CNI own large rule sets. Naïve hardening (`iptables -F`, `ufw enable` with a default `FORWARD DROP`) severs pod networking.

1. Look at what is already installed before you add anything:

   ```bash
   sudo nft list ruleset | grep -E '^table' 
   sudo iptables-save | grep -c '^-A KUBE'
   ```

   Expected:

   ```
   table ip kube-proxy
   table ip6 kube-proxy
   table inet filter
   table ip nat
   1274
   ```

2. Create your **own** table so you never edit a chain another controller reconciles. `nftables` evaluates *all* base chains registered on a hook, in priority order, and a `drop` verdict in any of them is final:

   ```bash
   sudo tee /etc/nftables.d/cks-host-guard.nft >/dev/null <<'EOF'
   table inet cks_guard
   delete table inet cks_guard

   table inet cks_guard {
     set trusted_cp {
       type ipv4_addr
       flags interval
       elements = { 192.168.56.10/32, 192.168.56.11/32 }
     }

     set admin_net {
       type ipv4_addr
       flags interval
       elements = { 192.168.56.0/24 }
     }

     chain input {
       type filter hook input priority filter - 10; policy accept;

       ct state established,related accept
       ct state invalid drop
       iif lo accept

       # Cluster-internal sources are exempt from the rules below
       ip saddr @trusted_cp accept
       iifname { "cali*", "tunl0", "vxlan.calico", "cni0", "flannel.1" } accept

       # Restrict the sensitive control-plane ports to the admin network
       tcp dport { 2379, 2380, 10250, 10256, 10257, 10259 } ip saddr != @admin_net \
         log prefix "cks-guard-drop-cp " level warn counter drop

       # SSH from the admin network only
       tcp dport 22 ip saddr != @admin_net counter drop
     }
   }
   EOF
   ```

3. Load it and confirm counters exist:

   ```bash
   sudo nft -f /etc/nftables.d/cks-host-guard.nft
   sudo nft list table inet cks_guard
   ```

4. Make it survive reboot (Debian/Ubuntu):

   ```bash
   grep -q 'nftables.d' /etc/nftables.conf || \
     echo 'include "/etc/nftables.d/*.nft"' | sudo tee -a /etc/nftables.conf
   sudo systemctl enable --now nftables
   ```

5. Validate from a source *outside* the admin network (or simulate with a different source IP), then validate that the cluster is intact:

   ```bash
   kubectl get nodes
   kubectl -n kube-system get pods -o wide | head
   kubectl run probe --image=nicolaka/netshoot --restart=Never --rm -it -- \
     curl -s -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc/version -k
   ```

   Expected: nodes `Ready`, pods `Running`, probe returns `401` or `403` (reachability proven; authn is a separate matter).

6. Inspect the drop counters after a probe attempt:

   ```bash
   sudo nft list table inet cks_guard | grep -A1 counter
   sudo journalctl -k -g 'cks-guard-drop-cp' -n 20
   ```

7. Rollback:

   ```bash
   sudo nft delete table inet cks_guard
   ```

**Questions**

- **Q4.1** — Why is `ct state established,related accept` placed *before* every drop rule, and what breaks if you omit it while dropping inbound `10250`?
- **Q4.2** — Explain precisely why `iptables -F` on a worker node breaks Service traffic, and why the damage may appear to "heal itself" after a while.
- **Q4.3** — You added a base chain at `priority filter - 10` in your own table rather than appending to `table inet filter`. State two operational advantages.
- **Q4.4** — A colleague runs `ufw default deny incoming && ufw enable` on a node. Pod-to-pod traffic across nodes stops. Which `ufw`/`iptables` chain is responsible, and what is the minimal correct fix?

---

## Exercise 5 — Why an `INPUT` rule does not block a NodePort (and what does)

This is the most commonly failed "minimize external access" task in the field.

1. Create a NodePort Service:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=2
   kubectl expose deployment web --type=NodePort --port=80 --name=web-np
   kubectl get svc web-np
   ```

   Expected:

   ```
   NAME     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
   web-np   NodePort   10.107.24.11    <none>        80:31544/TCP   5s
   ```

2. Confirm it is reachable from off-cluster:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.11:31544/
   ```

   Expected: `200`.

3. Try to block it with an obvious `input` rule:

   ```bash
   sudo nft add table inet np_test
   sudo nft add chain inet np_test input '{ type filter hook input priority filter; policy accept; }'
   sudo nft add rule inet np_test input tcp dport 31544 counter drop
   curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://192.168.56.11:31544/
   sudo nft list table inet np_test
   ```

   Expected: still `200`, and the counter reads `packets 0 bytes 0`.

4. Explain it with `conntrack` — the packet was DNAT'd in `prerouting` **before** the routing decision, so it took the `forward` hook, never `input`:

   ```bash
   sudo conntrack -L -p tcp --dport 31544 2>/dev/null | head -3
   ```

   ```
   tcp 6 118 TIME_WAIT src=192.168.56.1 dst=192.168.56.11 sport=51022 dport=31544 \
       src=10.244.1.7 dst=192.168.56.1 sport=80 dport=51022 [ASSURED]
   ```

5. Block it correctly — filter **before** `dstnat` (priority `-100`):

   ```bash
   sudo nft flush table inet np_test
   sudo nft add chain inet np_test prerouting \
     '{ type filter hook prerouting priority -160; policy accept; }'
   sudo nft add rule inet np_test prerouting ip saddr != 192.168.56.0/24 \
     tcp dport 30000-32767 counter drop
   ```

6. Or, equivalently, match the pre-DNAT destination port after the fact:

   ```bash
   sudo iptables -I FORWARD 1 -m conntrack --ctorigdstport 31544 \
     ! -s 192.168.56.0/24 -j DROP
   ```

7. Verify and clean up:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://192.168.56.11:31544/
   sudo nft list table inet np_test
   sudo nft delete table inet np_test
   sudo iptables -D FORWARD -m conntrack --ctorigdstport 31544 ! -s 192.168.56.0/24 -j DROP
   ```

**Questions**

- **Q5.1** — Order these `nftables` hook priorities and say where NodePort DNAT happens: `raw (-300)`, `mangle (-150)`, `dstnat (-100)`, `filter (0)`, `srcnat (100)`. Why must your drop rule sit at `-160`?
- **Q5.2** — Why does `-m conntrack --ctorigdstport 31544` work in `FORWARD` while `--dport 31544` does not?
- **Q5.3** — A NodePort Service is reachable on **every** node, including nodes with no backing pod. Which mechanism makes that work, and how does `externalTrafficPolicy: Local` change it?
- **Q5.4** — Is `externalTrafficPolicy: Local` a security control? Answer yes/no and justify in one sentence.

---

## Exercise 6 — Shrink the exposed Service surface from the Kubernetes side

Host firewalls are per-node and drift. Removing the exposure at the API level is durable.

1. Audit what is currently exposed cluster-wide:

   ```bash
   kubectl get svc -A -o json | jq -r '
     .items[]
     | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer" or (.spec.externalIPs|length>0))
     | [.metadata.namespace, .metadata.name, .spec.type,
        ((.spec.ports//[])|map(.nodePort|tostring)|join(",")),
        ((.spec.loadBalancerSourceRanges//["ANY"])|join(",")),
        ((.spec.externalIPs//[])|join(","))]
     | @tsv' | column -t
   ```

   Expected:

   ```
   default   web-np      NodePort      31544   ANY
   ingress   ingress-lb  LoadBalancer  32180   ANY
   ```

2. Convert the workload to `ClusterIP` and front it with an Ingress/Gateway, which gives you one auditable entry point instead of N node ports:

   ```bash
   kubectl patch svc web-np --type=merge -p '{"spec":{"type":"ClusterIP","ports":[{"port":80,"targetPort":80,"protocol":"TCP","nodePort":null}]}}'
   kubectl get svc web-np
   ```

3. Where a `LoadBalancer` is unavoidable, pin the source ranges **and** suppress the node ports it would otherwise open on every node:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: ingress-lb
     namespace: ingress
   spec:
     type: LoadBalancer
     allocateLoadBalancerNodePorts: false     # no 30000-32767 listener on any node
     externalTrafficPolicy: Local             # preserve client source IP for the ranges below
     loadBalancerSourceRanges:
       - 203.0.113.0/24
       - 198.51.100.17/32
     selector:
       app.kubernetes.io/name: ingress-nginx
     ports:
       - name: https
         port: 443
         targetPort: 443
         protocol: TCP
   ```

   ```bash
   kubectl apply -f ingress-lb.yaml
   kubectl get svc -n ingress ingress-lb -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
   ```

   Expected: empty output.

4. Narrow the NodePort range itself so a stray Service cannot land on a port your firewall permits. On `cp01`:

   ```bash
   sudo sed -i 's#^\( *\)- --service-cluster-ip-range#\1- --service-node-port-range=30000-30100\n\1- --service-cluster-ip-range#' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo crictl ps --name kube-apiserver -q   # wait for the static pod to be recreated
   kubectl get --raw /livez?verbose | tail -3
   ```

5. Restrict which node interface `kube-proxy` even binds NodePorts to — this is the control most teams never enable:

   ```bash
   kubectl -n kube-system edit configmap kube-proxy
   ```

   ```yaml
   apiVersion: kubeproxy.config.k8s.io/v1alpha1
   kind: KubeProxyConfiguration
   mode: nftables
   nodePortAddresses:
     - 192.168.56.0/24     # or the literal ["primary"] on recent releases
   ```

   ```bash
   kubectl -n kube-system rollout restart daemonset kube-proxy
   kubectl -n kube-system rollout status daemonset kube-proxy
   ```

6. Prove the effect — recreate a NodePort Service and check it is *not* bound on a second interface of the node.

7. Rollback: restore the ConfigMap and remove `--service-node-port-range`.

**Questions**

- **Q6.1** — `loadBalancerSourceRanges` is enforced by the cloud provider / load-balancer controller, not by `kube-proxy`. What is the security consequence on a bare-metal cluster using MetalLB in L2 mode?
- **Q6.2** — What is `allocateLoadBalancerNodePorts: false` protecting you against, given the LoadBalancer already restricts sources?
- **Q6.3** — `spec.externalIPs` appears harmless. Explain why it is treated as a privileged field and what an attacker with `create services` in one namespace can do with it.
- **Q6.4** — Setting `nodePortAddresses` does not remove existing NodePort Services. Why is it still valuable, and what does it *not* protect?

---

## Exercise 7 — Prevent the exposure from being recreated: `ValidatingAdmissionPolicy`

Deleting one NodePort is remediation. Making NodePorts unrepresentable is hardening.

1. Write the policy (CEL, in-tree, no external webhook to keep available):

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: restrict-external-service-exposure
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["services"]
     validations:
       - expression: "object.spec.type != 'NodePort'"
         message: "NodePort Services are forbidden; use ClusterIP behind the shared Ingress."
         reason: Forbidden
       - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
         message: "spec.externalIPs is forbidden."
         reason: Forbidden
       - expression: >-
           object.spec.type != 'LoadBalancer' ||
           (has(object.spec.loadBalancerSourceRanges) &&
            size(object.spec.loadBalancerSourceRanges) > 0 &&
            object.spec.loadBalancerSourceRanges.all(r, r != '0.0.0.0/0'))
         message: "LoadBalancer Services must set a non-wildcard spec.loadBalancerSourceRanges."
         reason: Forbidden
   ```

2. Bind it, exempting the namespaces that legitimately need exposure:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: restrict-external-service-exposure-binding
   spec:
     policyName: restrict-external-service-exposure
     validationActions: ["Deny", "Audit"]
     matchResources:
       namespaceSelector:
         matchExpressions:
           - key: kubernetes.io/metadata.name
             operator: NotIn
             values: ["kube-system", "ingress"]
   ```

3. Apply and test:

   ```bash
   kubectl apply -f vap-services.yaml -f vap-services-binding.yaml
   kubectl expose deployment web --type=NodePort --port=80 --name=web-np2
   ```

   Expected:

   ```
   error: failed to create service: services "web-np2" is forbidden: ValidatingAdmissionPolicy
   'restrict-external-service-exposure' with binding
   'restrict-external-service-exposure-binding' denied request:
   NodePort Services are forbidden; use ClusterIP behind the shared Ingress.
   ```

4. Confirm the exemption still works:

   ```bash
   kubectl -n ingress create service nodeport tmp --tcp=80:80 --dry-run=server -o name
   ```

5. Dry-run the policy against existing objects before enforcing in production by first deploying with `validationActions: ["Audit"]` and reading the API audit log:

   ```bash
   sudo grep -o '"validation_policy[^,]*' /var/log/kubernetes/audit.log | sort | uniq -c | head
   ```

6. Cleanup:

   ```bash
   kubectl delete validatingadmissionpolicybinding restrict-external-service-exposure-binding
   kubectl delete validatingadmissionpolicy restrict-external-service-exposure
   ```

**Questions**

- **Q7.1** — `failurePolicy: Fail` on a `ValidatingAdmissionPolicy` has a very different availability profile than `failurePolicy: Fail` on a `ValidatingWebhookConfiguration`. Explain why.
- **Q7.2** — The binding exempts `kube-system` and `ingress` by namespace label. Why is `kubernetes.io/metadata.name` reliable for this, and what would be wrong with a custom label like `exempt: "true"`?
- **Q7.3** — Your policy blocks `CREATE` and `UPDATE` on Services. Name one path by which a NodePort could still appear in the cluster.
- **Q7.4** — Why does the third validation explicitly reject `0.0.0.0/0` instead of only checking that the list is non-empty?

---

## Exercise 8 — Cut pod egress: default-deny plus a metadata-endpoint block

Minimizing external access is bidirectional. A pod that can reach the cloud metadata service can often mint node-level cloud credentials.

1. Create a namespace and a probe pod:

   ```bash
   kubectl create namespace payments
   kubectl -n payments run probe --image=nicolaka/netshoot --command -- sleep 3600
   kubectl -n payments wait --for=condition=Ready pod/probe --timeout=60s
   ```

2. Establish the "before" state:

   ```bash
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'internet=%{http_code}\n' --max-time 5 https://example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'metadata=%{http_code}\n' --max-time 3 http://169.254.169.254/latest/meta-data/
   kubectl -n payments exec probe -- nslookup kubernetes.default.svc.cluster.local
   ```

3. Apply a default-deny egress policy:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-egress
     namespace: payments
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
   ```

   ```bash
   kubectl apply -f default-deny-egress.yaml
   kubectl -n payments exec probe -- nslookup kubernetes.default.svc.cluster.local || echo "DNS blocked — expected"
   ```

4. Re-open only what the workload needs. Note the two-element `to:` list semantics carefully:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: payments-egress-allowlist
     namespace: payments
   spec:
     podSelector:
       matchLabels:
         app: payments-api
     policyTypes: ["Egress"]
     egress:
       # 1) Cluster DNS only
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
       # 2) Public internet, minus link-local and RFC1918
       - to:
           - ipBlock:
               cidr: 0.0.0.0/0
               except:
                 - 169.254.0.0/16
                 - 10.0.0.0/8
                 - 172.16.0.0/12
                 - 192.168.0.0/16
         ports:
           - protocol: TCP
             port: 443
   ```

   ```bash
   kubectl apply -f payments-egress-allowlist.yaml
   kubectl -n payments label pod probe app=payments-api --overwrite
   ```

5. Verify the resulting posture:

   ```bash
   kubectl -n payments exec probe -- nslookup example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'https=%{http_code}\n' --max-time 5 https://example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'meta=%{http_code}\n' --max-time 3 http://169.254.169.254/latest/meta-data/ || echo "metadata blocked — expected"
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'apiserver=%{http_code}\n' --max-time 3 -k https://kubernetes.default.svc/version || echo "apiserver blocked — expected"
   ```

6. Test the CNI's honesty about node-local traffic — many CNIs exempt traffic to the pod's own node IP from `ipBlock`:

   ```bash
   NODE_IP=$(kubectl -n payments get pod probe -o jsonpath='{.status.hostIP}')
   kubectl -n payments exec probe -- curl -sk -o /dev/null -w "kubelet=%{http_code}\n" --max-time 3 https://$NODE_IP:10250/pods
   ```

7. Cleanup:

   ```bash
   kubectl delete namespace payments
   ```

**Questions**

- **Q8.1** — In the DNS rule, `namespaceSelector` and `podSelector` are two keys of a **single** list element. Rewrite the semantics in words, and state what changes if you put a `-` before `podSelector`.
- **Q8.2** — Why must every entry in `except` be a subset of the enclosing `cidr`? What error does the API server return otherwise?
- **Q8.3** — In step 6, some CNIs return `401` (reachable) rather than a timeout. Explain the underlying reason and name the mechanism (per CNI) you would use to close it.
- **Q8.4** — The allowlist permits `TCP/443` to `0.0.0.0/0` minus private ranges. Why does an egress policy expressed in IP CIDRs give weak protection against exfiltration, and what class of policy engine addresses it?
- **Q8.5** — A pod with `hostNetwork: true` in the `payments` namespace ignores `default-deny-egress`. Why, and which admission control prevents that pod from existing?

---

## Exercise 9 — Host OS: remove listeners you never needed

1. Enumerate socket-activated units — services that are not running but will start on first connection:

   ```bash
   systemctl list-sockets --all
   systemctl list-units --type=socket --state=active
   ```

2. Enumerate enabled services and cross-reference with your listener baseline:

   ```bash
   systemctl list-unit-files --state=enabled --type=service | sort
   ```

3. Disable what a Kubernetes node has no use for:

   ```bash
   for u in avahi-daemon cups cups-browsed rpcbind postfix bluetooth ModemManager; do
     systemctl list-unit-files "$u.service" >/dev/null 2>&1 && \
       sudo systemctl disable --now "$u.service" "$u.socket" 2>/dev/null
   done
   sudo systemctl mask avahi-daemon.socket
   ```

4. Harden `sshd` and verify with the *effective* configuration, not the file:

   ```bash
   sudo tee /etc/ssh/sshd_config.d/99-cks.conf >/dev/null <<'EOF'
   PermitRootLogin no
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitEmptyPasswords no
   X11Forwarding no
   AllowTcpForwarding no
   MaxAuthTries 3
   ClientAliveInterval 300
   ClientAliveCountMax 2
   AllowGroups k8s-admins
   ListenAddress 192.168.56.10
   EOF
   sudo sshd -t && sudo systemctl reload ssh
   sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|allowgroups|listenaddress|maxauthtries)'
   ```

   Expected:

   ```
   permitrootlogin no
   passwordauthentication no
   maxauthtries 3
   allowgroups k8s-admins
   listenaddress 192.168.56.10:22
   ```

5. Re-run the inventory from Exercise 1 and diff:

   ```bash
   sudo ss -lntuH | awk '{print $1, $5}' | sort -u > /tmp/now-listeners.txt
   diff /root/baseline-listeners.txt /tmp/now-listeners.txt
   ```

**Questions**

- **Q9.1** — Why does `systemctl stop avahi-daemon.service` alone leave the node exposed, and what does `mask` add over `disable`?
- **Q9.2** — Why must you validate `sshd` with `sshd -T` rather than by reading `/etc/ssh/sshd_config`? Give two concrete ways the file misleads you.
- **Q9.3** — `AllowTcpForwarding no` — what specific pivoting technique does this remove from an attacker who obtained a valid SSH key?
- **Q9.4** — `ListenAddress 192.168.56.10` binds sshd to the management interface. On a cloud node with a single NIC carrying both roles, what is the equivalent control?

---

## Exercise 10 — Continuous verification: an exposure drift check

1. Write a check that fails loudly when the node's external surface changes:

   ```bash
   sudo tee /usr/local/bin/check-external-exposure.sh >/dev/null <<'EOF'
   #!/usr/bin/env bash
   # Fails (exit 1) if the node exposes a listener outside the approved allowlist.
   set -uo pipefail

   ALLOWED_PORTS="22 6443 10250"
   ALLOWED_CIDR="192.168.56.0/24"
   rc=0

   echo "== Externally bound listeners =="
   while read -r addr; do
     port="${addr##*:}"
     grep -qw "$port" <<<"$ALLOWED_PORTS" || { echo "UNEXPECTED listener: $addr"; rc=1; }
   done < <(ss -lntH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\])')

   echo "== Kubelet read-only port =="
   ss -lntH | grep -q ':10255' && { echo "kubelet readOnlyPort is OPEN"; rc=1; }

   echo "== Kubelet anonymous auth =="
   code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:10250/pods")
   [ "$code" = "401" ] || { echo "kubelet /pods returned $code (expected 401)"; rc=1; }

   echo "== Exposed Services =="
   if command -v kubectl >/dev/null; then
     kubectl get svc -A -o json 2>/dev/null | jq -e '
       [.items[] | select(.spec.type=="NodePort"
         or (.spec.type=="LoadBalancer" and ((.spec.loadBalancerSourceRanges//[])|length==0))
         or ((.spec.externalIPs//[])|length>0))] | length == 0' >/dev/null \
       || { echo "Unrestricted NodePort/LoadBalancer/externalIP Services present"; rc=1; }
   fi

   echo "== Guard table loaded =="
   nft list table inet cks_guard >/dev/null 2>&1 || { echo "cks_guard nftables table missing"; rc=1; }

   exit $rc
   EOF
   sudo chmod 0750 /usr/local/bin/check-external-exposure.sh
   ```

2. Run it and read the exit status explicitly — never pipe it through `tee`, which masks the failure as exit `0`:

   ```bash
   sudo /usr/local/bin/check-external-exposure.sh
   echo "exit=$?"
   ```

3. Schedule it and alert on failure:

   ```bash
   sudo systemd-run --on-calendar='*:0/15' --unit=exposure-check \
     /usr/local/bin/check-external-exposure.sh
   systemctl list-timers exposure-check.timer
   ```

4. Cross-check against the CIS Kubernetes Benchmark with `kube-bench` for the same domain:

   ```bash
   kubectl run kube-bench --rm -it --restart=Never \
     --image=docker.io/aquasec/kube-bench:latest \
     --overrides='{"spec":{"hostPID":true,"nodeName":"cp01","containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:latest","command":["kube-bench","run","--targets","node"],"volumeMounts":[{"name":"varlib","mountPath":"/var/lib/kubelet","readOnly":true},{"name":"etckube","mountPath":"/etc/kubernetes","readOnly":true}]}],"volumes":[{"name":"varlib","hostPath":{"path":"/var/lib/kubelet"}},{"name":"etckube","hostPath":{"path":"/etc/kubernetes"}}]}}' \
     2>/dev/null | grep -E '^\[(FAIL|WARN)\]' | head -20
   ```

**Questions**

- **Q10.1** — The script asserts `401` from `https://127.0.0.1:10250/pods`. Why is `401` the pass condition and both `200` and `403` failures?
- **Q10.2** — The check runs on the node and reads local state. Name one exposure it structurally cannot detect, and the complementary control that would.
- **Q10.3** — Why does `set -uo pipefail` appear without `-e` in this script? What would `-e` break here?
- **Q10.4** — You add this to CI as a gate. An attacker with node root can make it pass while leaving a backdoor listener. Describe how, and what class of tooling detects it instead.

---

<details>
<summary><b>Solutions</b> — expand only after attempting every block</summary>

### Exercise 1

**A1.1** — A socket bound to `127.0.0.1` is only reachable through the loopback interface, so packets arriving on a physical NIC with that destination are dropped by the kernel's martian/route handling; there is no route by which a remote host reaches it. It converts a *network*-reachable attack surface into a *local-code-execution*-reachable one: the attacker must already have a foothold on the node (a shell, or a `hostNetwork` pod, or a container escape). That is a materially higher bar, and it is why CIS 1.3.x / 1.4.x require `--bind-address=127.0.0.1` on the scheduler and controller-manager. It is not a substitute for authentication — a `hostNetwork: true` pod shares the host's network namespace and can reach loopback listeners directly.

**A1.2** — `ss` reports what the kernel's socket table contains; `nmap` reports what survived the packet filter *on the path*. `10248` is bound to `127.0.0.1`, so a SYN from `w01` never reaches the socket. `filtered` means `nmap` sent probes and received neither a SYN/ACK nor an RST — the packet was silently dropped (a firewall `DROP`, a route rejection, or no listener on that address). `closed` means the host actively answered with a TCP RST: reachable host, no listener. The distinction matters for reconnaissance: `closed` confirms the host is alive and the port is unprotected-but-empty; `filtered` tells the attacker something is deliberately blocking, and also silently costs them scan time.

**A1.3** — `10249` is `metricsBindAddress`, serving `/metrics` (Prometheus data about `kube-proxy`'s own syncs, rule counts, latency). `10256` is `healthzBindAddress`, serving `/healthz`. The defaults differ because of their consumers: metrics are scraped by an in-cluster agent that can be pointed at the pod IP or run as a sidecar, so loopback is sufficient and protects the moderately sensitive service/endpoint topology metrics. Health is probed by *external* load balancers — a cloud LB doing health checks against each node's `:10256/healthz` to decide whether to send NodePort traffic there — so it must be reachable off-node by default. In a cluster with no external LB, set `healthzBindAddress: 127.0.0.1` and close `10256`, as Exercise 4 does with the firewall.

**A1.4** — Yes for the `hostNetwork: true` pod: it shares the host's network namespace, so its socket is in the host's socket table and `ss -lntp` shows it (with the container process's PID, since `ss` reads `/proc/net/tcp` for the current namespace). No for a normal pod: its listener lives in its own network namespace, and `containerPort` is purely informational metadata — it opens nothing. To see it you must enter the pod's namespace, e.g. `nsenter -t <pid> -n ss -lntp` or `crictl inspect` to find the sandbox PID. This asymmetry is exactly why `hostNetwork` is a Pod Security Standards *baseline* violation.

### Exercise 2

**A2.1** — The API server presents its client certificate (`--kubelet-client-certificate`, usually `kube-apiserver-kubelet-client`). The kubelet's `x509` authenticator validates it against `authentication.x509.clientCAFile` and extracts the subject CN as the username (`kube-apiserver-kubelet-client`) and the O as groups (`system:masters` in default kubeadm). Because `authorization.mode: Webhook`, the kubelet then issues a `SubjectAccessReview` to the API server asking whether that identity may perform `create` on `nodes/proxy` (subresource `nodes/proxy`, or more precisely the `nodes/exec`-mapped verb) for that node. The two objects are **`TokenReview`** (used when the client presents a bearer token rather than a certificate — the authentication delegation path) and **`SubjectAccessReview`** (the authorization delegation path). Both are answered by the API server, which is why a kubelet with `mode: Webhook` fails closed if the API server is unreachable, subject to `cacheTTL`.

**A2.2** — Because authentication and authorization answer different questions. With `anonymous.enabled: false`, any request must carry *some* valid credential — but "valid" only means "signed by the configured CA" or "a token the API server accepts". Every pod in the cluster has a ServiceAccount token mounted; any node has certificates on disk; any client cert signed by the cluster CA (including a kubelet's own `system:node:*` cert, or one obtained via a CSR) authenticates successfully. With `AlwaysAllow`, all of those identities get full kubelet API access — `exec` into any container on the node, read all logs, list all pods with their environment. Authentication proves *who*; only authorization decides *what*. `AlwaysAllow` deletes the second half.

**A2.3** — (a) `GET /pods` on `10255` returns the full `PodList` for the node, including each container's `env` array; environment variables sourced from a ConfigMap are rendered as literal values, so database hostnames, feature flags, internal URLs, and any credential someone put in a ConfigMap are disclosed. (Values from `secretKeyRef` appear as a reference, not the value — but the *names* of the Secrets, the ServiceAccount, image registries, node labels, and the full topology are all disclosed.) (b) `GET /metrics/cadvisor` (and `/stats/summary`) on `10255` returns per-container CPU, memory, filesystem and network counters keyed by pod name and namespace — a complete inventory of what runs where, plus a side channel for inferring activity. Both are unauthenticated; both give an attacker the target map before they spend a single exploit.

**A2.4** — The equivalent authenticated endpoint is `https://$NODE_IP:10250/metrics/cadvisor`. The scraper now needs a bearer token for a ServiceAccount bound to a ClusterRole granting `get` on the `nodes/metrics` resource (and typically `nodes/stats`, `nodes/proxy`), plus the cluster CA to validate the kubelet's serving certificate. The canonical form is the `kubelet-serving`/`node-metrics` ClusterRole that Prometheus Operator installs, with `authorization: type: Bearer` and `tlsConfig.caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt` — note the kubelet's serving cert must actually be signed by the cluster CA (`serverTLSBootstrap: true` plus CSR approval), otherwise the scraper needs `insecureSkipVerify: true`, which reintroduces a MITM path.

### Exercise 3

**A3.1** — `kube-apiserver`'s legitimate clients are, by design, off-node: every kubelet in the cluster, every `kubectl` user, every controller running as a pod, and external CI systems. It cannot be reached over loopback by any of them, so it must bind a routable address; its defence is TLS with mandatory authentication (x509/OIDC/ServiceAccount tokens) plus RBAC, not network reachability. `kube-scheduler` and `kube-controller-manager` have exactly two client categories: their own liveness probes (localhost) and metrics scrapers. Nothing off-node needs to call them, so binding loopback removes their `/metrics` (which leaks scheduling topology) and their `/healthz` from the network entirely at zero functional cost. The principle: bind scope should equal the true client set, and for these two components that set is local.

**A3.2** — The primary control is mutual TLS with `--client-cert-auth=true`: `etcd` will not complete a handshake with a client that does not present a certificate signed by the etcd CA (`/etc/kubernetes/pki/etcd/ca.crt`). Network restriction is defence in depth because it does not stop the attack that actually matters — an attacker who has obtained `/etc/kubernetes/pki/etcd/healthcheck-client.crt` (or `apiserver-etcd-client.*`) from the node's filesystem, which grants full read/write to the entire cluster state including every Secret in plaintext (unless encryption-at-rest is configured). Firewalling `2379` buys you protection against the *unauthenticated network scanner* and reduces the blast radius of a future `etcd` TLS vulnerability; it buys you nothing against filesystem access. That is why CKS pairs this with `EncryptionConfiguration` and file permissions `0600 root:root` on the PKI directory.

**A3.3** — No, provided it is bound to `127.0.0.1`. The `listen-metrics-urls` endpoint on `2381` serves only `/metrics` and `/health`; it has no write path and cannot read keys. Because it is bound to loopback, plaintext HTTP is only observable by a process already on the node with the ability to sniff loopback (`CAP_NET_RAW` in the host netns) — an attacker at that privilege level already has the certificates. It is deliberately HTTP so that liveness probes and node-local scrapers do not need client certificates. It *would* be a finding if the URL were `http://0.0.0.0:2381` or any routable address: then etcd's operational metrics (DB size, raft term, leader changes, key counts) traverse the network unauthenticated and unencrypted.

**A3.4** — `kubelet` on every node connects to the API server using the endpoint in its `/etc/kubernetes/kubelet.conf` (`server: https://192.168.56.10:6443`). Binding the API server to `127.0.0.1` removes the `0.0.0.0:6443` listener, so `w01`'s kubelet gets connection-refused. It can no longer POST its `NodeStatus` heartbeat (`Lease` objects in `kube-node-lease`). After `--node-monitor-grace-period` (default 40 s) the node controller in `kube-controller-manager` — which still works, because it runs on `cp01` and reaches the API server over loopback — marks the node `NotReady`, then begins evicting pods after `--default-not-ready-toleration-seconds` (300 s). Local `kubectl` on `cp01` keeps working because its kubeconfig also resolves to the loopback-reachable address. This is the classic "the cluster looks fine from where I'm standing" failure.

### Exercise 4

**A4.1** — Firewall rules are evaluated against *every* packet in both directions of a flow's return path. When the node itself initiates a connection — `kubelet` → API server, `crictl` pulling an image, a `hostNetwork` pod calling out — the *replies* arrive inbound with arbitrary source ports and, critically, with the remote's port as the source. A drop rule matching `tcp dport 10250` will not hit those, but a `policy drop` or a broader rule will, and the connection stalls. The `ct state established,related accept` rule short-circuits all of that: any packet belonging to a flow conntrack already knows is passed before the drop logic runs, so only genuinely new inbound connections are evaluated. Omitting it while dropping `10250` specifically is survivable (the drop is narrow), but the moment you switch to `policy drop` — the correct end state — omitting it severs the node's own outbound connectivity, including its heartbeat to the API server, and you lose the node.

**A4.2** — `kube-proxy` implements Services by programming DNAT rules (`KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*` chains in the `nat` table) and the CNI programs forwarding/masquerade rules of its own. `iptables -F` flushes the `filter` table; `iptables -t nat -F` flushes the DNAT rules, at which point ClusterIP traffic has nowhere to go and every Service becomes a black hole — pods can still talk pod-IP-to-pod-IP but every `svc.cluster.local` connection times out. It appears to "heal" because `kube-proxy` runs a periodic full resync (`syncPeriod`, default 30 s, and `minSyncPeriod` throttling) that rewrites its chains from scratch; the CNI agent does the same on its own interval. So the outage lasts seconds to a minute and then vanishes, which is precisely what makes it a nightmare to diagnose from a ticket. The lesson: never flush shared chains — put your rules in your own table (or your own chain with a jump you control).

**A4.3** — (1) **No reconciliation conflict.** `kube-proxy` and the CNI agent periodically rewrite the tables they own, and modern `kube-proxy` in nftables mode does a full-table replace; a rule you appended into a chain they manage is silently deleted on the next resync. Your own table is never touched by them. (2) **Atomic, reviewable, reversible lifecycle.** `nft -f file` applies the whole file as one transaction — either every rule loads or none does, so there is no window with a half-applied policy — and `nft delete table inet cks_guard` is a complete, single-command rollback that cannot accidentally take a `kube-proxy` rule with it. A secondary advantage: `nft list table inet cks_guard` gives you a clean audit artifact containing only your policy, instead of grepping it out of 1,200 `KUBE-*` rules.

**A4.4** — `ufw`'s default profile sets the `filter FORWARD` policy to `DROP` (and inserts `ufw-before-forward`/`ufw-reject-forward` chains). Pod-to-pod traffic across nodes is *forwarded* by the node — packets enter on the physical NIC (or the VXLAN/IPIP tunnel interface) and leave on a `cali*`/`veth` interface toward the pod — so it traverses `FORWARD`, not `INPUT`, and is dropped. `ufw allow` rules only touch `INPUT`, which is why "I allowed the port and it still doesn't work" is the usual report. Minimal correct fix: set `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw` and reload (`ufw reload`), then, if you want forward filtering at all, add explicit allowances for the pod and service CIDRs and the CNI's tunnel interface (`ufw route allow` rules), e.g. `ufw allow in on cali+`, `ufw allow in on vxlan.calico`, `ufw route allow from 10.244.0.0/16 to 10.244.0.0/16`. On a Kubernetes node the honest answer is usually: do not use `ufw` — it is an abstraction over a table Kubernetes co-owns.

### Exercise 5

**A5.1** — Order of traversal for an inbound packet: `raw (-300)` → `mangle prerouting (-150)` → `dstnat (-100)` → *routing decision* → `filter forward (0)` or `filter input (0)` → ... → `srcnat (100)`. NodePort DNAT happens in the `dstnat` hook at priority `-100`: the destination is rewritten from `192.168.56.11:31544` to the endpoint `10.244.1.7:80`. After that rewrite the kernel makes its routing decision on the *new* destination, which is not a local address, so the packet is sent to `forward` — `input` is never consulted. Your drop rule must sit at a priority numerically **lower** than `-100` (earlier), hence `-160`, so it sees the original destination port `31544` before it is rewritten. `-160` also sits after `mangle (-150)`; any priority in `(-300, -100)` works, and choosing one that does not collide with `mangle` or `raw` conventions keeps the ruleset legible.

**A5.2** — After DNAT, the packet's L3/L4 headers carry the *translated* destination (`10.244.1.7:80`), so a plain `--dport 31544` match in `FORWARD` matches nothing. Conntrack, however, records the connection's **original** tuple alongside the reply tuple — that is exactly what you saw in the `conntrack -L` output, where `dport=31544` appears in the original direction and `sport=80` in the reply. `-m conntrack --ctorigdstport 31544` matches against that stored original tuple rather than the current headers, so it correctly identifies "this flow entered as a NodePort connection" even though the packet in front of you no longer looks like one. The same technique with `--ctorigdst` is how you write "block traffic that originally targeted this external IP" rules on a node doing NAT.

**A5.3** — `kube-proxy` on *every* node programs a rule for the node port that DNATs to the full set of ready endpoints cluster-wide, regardless of where those endpoints live. If the selected endpoint is on another node, the packet is SNAT'd (masqueraded) to the receiving node's IP and forwarded there — one extra hop, and the backend pod sees the intermediate node's IP as the client. With `externalTrafficPolicy: Local`, `kube-proxy` programs the node port only with endpoints *local to that node*: nodes with no backing pod either drop the traffic or fail their `:10256` health check so the external LB stops sending to them, and because no second hop is needed there is no SNAT, so the pod sees the real client IP. The trade-off is uneven load distribution (traffic is split per-node, not per-pod) and hard dependency on the LB's health checking.

**A5.4** — **No.** It changes *which* nodes answer and preserves the client source IP; it does not authenticate, filter, or restrict who may connect — any client that can reach a node which happens to host a backing pod still gets full access to the Service. Its security value is indirect and secondary: because the true client IP now reaches the pod, application-layer allowlists, rate limits, and audit logs become meaningful instead of recording the node IP. Do not present it as an access control in an exam answer or a design review.

### Exercise 6

**A6.1** — `loadBalancerSourceRanges` is a *request* to the provider's load-balancer controller, which is expected to translate it into cloud security-group rules (AWS NLB/ALB, GCP firewall rules, Azure NSG). MetalLB in L2 mode does no such thing: it simply answers ARP for the VIP from one elected node and lets `kube-proxy` handle the rest, so the field is silently ignored — the Service object shows the ranges, the audit passes, and the VIP is reachable from the entire L2 segment. This is the worst kind of control: one that *appears* configured. On bare metal you must enforce the ranges yourself, at the node packet filter (a `prerouting` drop matching the VIP as in Exercise 5), on the upstream router/switch ACL, or by fronting the VIP with an Ingress/Gateway that does its own source filtering. Always verify enforcement empirically from a disallowed source rather than trusting the field's presence.

**A6.2** — Against the bypass path. A `type: LoadBalancer` Service by default *also* allocates a node port and programs it on every node, because that is how most cloud LBs reach the backends. The LB enforces `loadBalancerSourceRanges`, but the node port does not — anyone who can reach any node IP on `30000-32767` walks straight past the load balancer and its source filtering, its WAF, its TLS termination, and its access logs. `allocateLoadBalancerNodePorts: false` removes that side door; it is safe when the LB implementation targets pod IPs directly (AWS NLB/ALB in `ip` target mode, Cilium's LB-IPAM, most CNI-integrated implementations) and will break connectivity when the LB targets node ports, so verify before rolling it out.

**A6.3** — `spec.externalIPs` tells `kube-proxy` on **every node** to intercept traffic destined to arbitrary IP addresses you name and DNAT it to your Service's endpoints — with no validation that you own or should be allowed to claim that address. An attacker with `create services` in one namespace can set `externalIPs: ["10.96.0.10"]` (the cluster DNS ClusterIP) or the API server's IP, or the address of an internal service in another namespace, and hijack that traffic cluster-wide, breaking namespace isolation entirely: a DNS hijack alone lets them redirect every workload's name resolution. This is why the upstream `DenyServiceExternalIPs` admission plugin exists (enable via `--enable-admission-plugins=DenyServiceExternalIPs`), why the Pod Security Standards' sibling guidance flags it, and why the policy in Exercise 7 rejects a non-empty `externalIPs` outright.

**A6.4** — It prevents `kube-proxy` from binding node ports on interfaces outside the listed CIDRs, so a Service created on a multi-homed node (management NIC + public NIC, or a NIC on a DMZ VLAN) is no longer silently published on the internet-facing address. Its value is that it is a *default-scope* control applied by the data plane to every Service, present and future, without per-Service configuration — a new NodePort created tomorrow is automatically confined. What it does **not** protect: (a) anything reachable on the approved CIDR itself — it is a bind-scope control, not an authentication or per-source control; (b) `hostPort` and `hostNetwork` pods, which bypass `kube-proxy` entirely and bind whatever the container asks for; (c) `LoadBalancer` VIPs handled by a CNI-integrated implementation that does not route through `kube-proxy`; (d) existing conntrack entries, which is why a `kube-proxy` restart does not immediately tear down established flows.

### Exercise 7

**A7.1** — A `ValidatingWebhookConfiguration` with `failurePolicy: Fail` makes the API server depend on an external HTTPS endpoint — usually a Deployment *inside the cluster it is gating*. If that Deployment is down (a bad rollout, a drained node, a cert expiry, a network policy mistake), every matching API write is rejected, and if the webhook matches broadly you get a cluster you cannot repair because you cannot create the pods that would fix the webhook. `ValidatingAdmissionPolicy` evaluates CEL **in-process inside the API server**: there is no network call, no separate Deployment, no certificate to expire, and no cold-start latency. `failurePolicy: Fail` there only triggers on a CEL runtime error (type error, missing field on an unexpected object shape), which is a bug in your expression, not an availability event. That is the central operational reason to prefer VAP over a webhook for policies expressible in CEL — and, on the exam, the reason to reach for it first.

**A7.2** — `kubernetes.io/metadata.name` is set and continuously reconciled onto every Namespace by the API server itself (the `NamespaceDefaultLabelName` behaviour, GA since v1.22); a user cannot remove or forge it, and its value always equals the namespace name. A custom label like `exempt: "true"` is under the control of anyone with `update namespaces` — and, more subtly, anyone who can *create* a namespace, since they choose its initial labels. That turns your exemption list into a privilege-escalation primitive: create `namespace foo` with `exempt: "true"`, then create all the NodePorts you like. The general rule for selector-based policy exemptions: select on immutable, server-managed labels, and treat "who can label a namespace" as equivalent to "who can bypass every namespace-selected policy" — the same reasoning that makes `pod-security.kubernetes.io/enforce` label-write permission a privileged grant.

**A7.3** — Several, and naming any one is sufficient: (a) **Objects that already exist** — VAP is an admission control, so pre-existing NodePort Services are untouched; you need the audit from Exercise 6 step 1 to find them, which is why `validationActions: ["Deny","Audit"]` and a survey pass matter. (b) **The exempt namespaces** — `kube-system` and `ingress` are excluded by the binding, so anyone with `create services` there is unconstrained. (c) **`hostPort` / `hostNetwork` pods**, which expose a port on the node without any Service object being created at all — a completely different resource, not matched by `matchConstraints`. (d) The API server's own bootstrap Services, and any object created while the policy is absent (deleted binding, cluster restore from a backup taken before the policy existed). Structurally: admission control governs *the write path from now on*, so it must always be paired with a periodic audit of existing state — which is exactly what Exercise 10 provides.

**A7.4** — Because `loadBalancerSourceRanges: ["0.0.0.0/0"]` is semantically identical to omitting the field — it allows the entire internet — while satisfying a naïve "is the list non-empty?" check. Policies that can be trivially satisfied by a value that provides no protection are worse than no policy: they produce a green audit result and a false sense of coverage, and they train engineers to write the incantation that passes rather than the range that is correct. The CEL `.all(r, r != '0.0.0.0/0')` closes the obvious form; a production version would go further and require every range to be a subset of an approved corporate CIDR list, and reject `::/0` and near-wildcards like `0.0.0.0/1` + `128.0.0.0/1`.

### Exercise 8

**A8.1** — As written, the two selectors are keys of one `NetworkPolicyPeer`, so they are **ANDed**: "pods labelled `k8s-app: kube-dns` *that are in* namespaces labelled `kubernetes.io/metadata.name: kube-system`" — i.e. exactly the CoreDNS pods and nothing else. Adding a `-` before `podSelector` makes it a second, separate element of the `to:` list, and list elements are **ORed**: "any pod in the `kube-system` namespace, **OR** any pod labelled `k8s-app: kube-dns` in *any* namespace". The second form is dramatically broader — it grants egress to every pod in `kube-system` (including the API server proxy paths, the CNI agents, any operator running there) and lets an attacker in any namespace they control open a path by simply labelling their own pod `k8s-app: kube-dns`. This one-character difference is the single most common NetworkPolicy error and a favourite exam trap; always read the YAML by asking "how many list elements are in this `to:`?"

**A8.2** — The API server validates that each `except` CIDR is contained within the enclosing `cidr`, because `ipBlock` is defined as a set-subtraction over one address range: an `except` outside the range is meaningless and almost always signals that the author misunderstood the semantics (typically writing `cidr: 10.0.0.0/8, except: [169.254.169.254/32]` and believing they blocked metadata). The API server rejects it at admission with a message of the form `spec.egress[1].to[0].ipBlock.except[0]: Invalid value: "169.254.169.254/32": must be a subnet of the network 10.0.0.0/8`. Practical consequence: to exclude the link-local metadata range you must nest it under a `cidr` that contains it — `0.0.0.0/0` — which is why the allowlist rule is written as "the whole internet minus the private and link-local ranges".

**A8.3** — Most CNIs treat traffic from a pod to *its own node's* IP as node-local host traffic that falls outside the pod-network policy enforcement path — the packet is delivered through the host's routing without traversing the per-endpoint policy chains, or the CNI explicitly allowlists the node IP so that kubelet health checks and node-local DNS keep working. The result is that an `ipBlock` `except: 169.254.0.0/16` or a deny of RFC1918 does not stop `curl https://$NODE_IP:10250/pods`, and the kubelet answers `401` (reachable, unauthorized) rather than timing out. Closing it requires the CNI's host-level policy API, which core NetworkPolicy does not have: **Calico** — a `GlobalNetworkPolicy` with `applyOnForward` plus a `HostEndpoint` for the node interfaces; **Cilium** — a `CiliumClusterwideNetworkPolicy` with `nodeSelector` (host firewall, `--enable-host-firewall`); **generic fallback** — the node `nftables`/`iptables` guard from Exercise 4 dropping traffic to `10250` sourced from the pod CIDR. Always test this specific path rather than assuming your NetworkPolicy covers it.

**A8.4** — Because CIDRs are a poor proxy for identity on the modern internet. A single CDN or cloud IP range fronts millions of unrelated destinations, so allowing `TCP/443` to any public IP is effectively "allow exfiltration to any service that happens to sit behind Cloudflare, S3, or a GitHub Pages site"; conversely, pinning a legitimate SaaS partner to an IP list breaks the first time they change their DNS, and DNS-based load balancing means the resolved address is not stable in the first place. Address the gap with a policy engine that understands **DNS names and L7 semantics**: Cilium's `CiliumNetworkPolicy` with `toFQDNs` (and `toPorts` + `rules.http` for method/path granularity), Calico's `GlobalNetworkPolicy` with domain-based rules, or an explicit egress proxy (Envoy/Squid) that all workloads must route through, with the CIDR policy narrowed to "only the proxy". The general point for the exam: core `NetworkPolicy` is an L3/L4 API — say so, and name FQDN-aware policy or an egress gateway as the L7 answer.

**A8.5** — A `hostNetwork: true` pod shares the **node's** network namespace, so its traffic originates from the node IP and does not pass through the per-pod endpoint that the CNI attaches policy to; there is no pod-network identity to select, so `podSelector: {}` does not match it and the CNI has no enforcement point. It also means such a pod can reach every loopback-bound control-plane listener from Exercise 3. The admission control that prevents it is the **Pod Security Standards** at the `baseline` (or `restricted`) level, enforced via Pod Security admission with the namespace label `pod-security.kubernetes.io/enforce: baseline` — `baseline` forbids `hostNetwork`, `hostPID`, `hostIPC`, `hostPort`, and privileged containers. Equivalent enforcement via a `ValidatingAdmissionPolicy` on `pods` with `!has(object.spec.hostNetwork) || object.spec.hostNetwork == false` is also acceptable; the key insight is that *network* policy cannot fix a *pod spec* problem, so the two controls must be deployed together.

### Exercise 9

**A9.1** — `systemctl stop` terminates the running process but leaves the unit enabled, so it returns on the next boot; worse, if the service is socket-activated, `avahi-daemon.socket` remains listening and the *kernel* restarts the daemon on the first inbound packet, so the port never actually closes. `disable` removes the `WantedBy` symlinks so it does not start at boot — but it can still be started as a dependency of another unit, or manually, or by socket activation if the socket unit is separately enabled. `mask` symlinks the unit to `/dev/null`, making it impossible to start by any means (dependency, socket activation, or explicit `systemctl start`, which fails with "Unit is masked"). On a hardened node the correct sequence for a service you never want is `systemctl disable --now <unit>.service <unit>.socket` followed by `systemctl mask` on both — and, better still, not installing the package at all (`apt purge`), which is the actual minimize-the-footprint answer.

**A9.2** — `sshd -T` prints the fully resolved effective configuration exactly as the daemon computes it, after processing every include, every override, and every built-in default. Reading the main file misleads you because: (1) **`Include /etc/ssh/sshd_config.d/*.conf` is processed at the point it appears — usually line 1 on Debian/Ubuntu — and `sshd` applies the *first* occurrence of most keywords**, so a drop-in file silently wins over the value you are reading further down the main file (and cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`, which is how "I set it to no and it still accepts passwords" happens). (2) **Options absent from the file still have values** — the compiled-in defaults — so `PermitRootLogin` not appearing does not mean it is off; the historical default was `prohibit-password`, which still permits key-based root login. Additional traps: `Match` blocks change the effective value per user/address (use `sshd -T -C user=x,addr=y,host=z` to render those), and a config error means `sshd` keeps running the *old* config after a failed reload — which is why `sshd -t` before `systemctl reload` is mandatory.

**A9.3** — It removes **port forwarding as a pivot**: `ssh -L` (local forward, turning the node into a gateway into the cluster's internal networks — e.g. `ssh -L 2379:127.0.0.1:2379 node`, which defeats every loopback binding from Exercise 3 in one command), `ssh -R` (remote forward, establishing an inbound tunnel from the attacker's infrastructure through the node's egress and straight past the firewall), and `ssh -D` (a SOCKS proxy turning the node into a general-purpose pivot into the pod and service CIDRs). This is precisely the control that stops a stolen key from converting "shell on one node" into "network access to every loopback-bound and firewall-protected service on that node". Pair it with `AllowAgentForwarding no` (which otherwise lets an attacker on the node hijack your forwarded agent socket to authenticate onward as you) and, for accounts that need no shell at all, `ForceCommand` or a `restrict` prefix in `authorized_keys`.

**A9.4** — With a single NIC you cannot separate roles by bind address, so the equivalent control is **source-based restriction at the packet filter plus identity restriction in `sshd`**: (a) the cloud security group / NSG / firewall rule limiting `22/tcp` to the bastion's address or the VPN CIDR — the cloud-native analogue of `ListenAddress`, and the one that keeps internet scanners off the port entirely; (b) `AllowGroups`/`AllowUsers` and key-only authentication so that reaching the port is not sufficient; (c) architecturally, remove the listener from the network altogether — AWS SSM Session Manager, GCP IAP TCP forwarding, or Azure Bastion open an outbound-initiated session so `22` need not be reachable at all, which is strictly better than any allowlist because there is nothing to scan. The general principle to state: when you cannot narrow the *bind* scope, narrow the *source* scope, and prefer removing the network path over filtering it.

### Exercise 10

**A10.1** — `401 Unauthorized` is the correct pass condition because it proves both halves of the kubelet's security posture in one probe: the TLS listener is up (so the check is actually testing something), and the request was rejected at the **authentication** stage — meaning `authentication.anonymous.enabled: false` is in effect and an unauthenticated caller has no identity at all. `403 Forbidden` is a failure because it means anonymous authentication *succeeded* — the request was assigned the `system:anonymous` identity and only the authorizer stopped it. That is a strictly weaker posture: it depends on RBAC bindings staying correct, it means any endpoint the authorizer happens to allow for `system:anonymous`/`system:unauthenticated` is open, and a single over-broad ClusterRoleBinding (a distressingly common one grants `system:unauthenticated` more than intended) converts it into `200`. `200` is total failure: unauthenticated read of every pod on the node, and the same listener serves `exec`.

**A10.2** — It cannot detect **upstream network exposure** — that the node's IP is published through a cloud load balancer, a security group opened to `0.0.0.0/0`, a NAT/port-forward on the perimeter router, or a `LoadBalancer` VIP announced by MetalLB from a different node. Every one of those makes an "internal-only" listener internet-reachable while `ss`, `nft`, and the local `curl` all report a perfectly hardened node. (A second valid answer: it cannot see a listener bound inside a non-`hostNetwork` pod's namespace, per A1.4.) The complementary control is **external attack-surface validation**: a scheduled scan from outside the trust boundary (`nmap` from an external host, or a commercial ASM/external-scanner service) whose results are diffed against the approved exposure list, plus cloud-configuration scanning of the security groups and LB rules themselves. The rule to internalize: a control that measures from *inside* the boundary can never validate the boundary — you need at least one observer on the other side.

**A10.3** — `-u` catches unset-variable typos and `-o pipefail` makes the `ss | awk | grep` pipelines report a real failure instead of the last command's status — both desirable. `-e` is deliberately omitted because the script's entire purpose is to **run every check and accumulate `rc=1`**, then report a full picture. With `-e`, the first command returning non-zero aborts the script: `grep -q ':10255'` legitimately returns 1 when the port is *closed* (the good case), the `kubectl`/`jq -e` pipeline returns non-zero as its normal "found a violation" signal, and `nft list table` returns non-zero when the table is missing — so `-e` would either exit on the very first *passing* check or exit after the first failure, hiding every subsequent finding. A check script wants "run all, aggregate, exit with the aggregate"; `-e` implements "stop at the first surprise", which is the wrong contract here. (If you want both, guard each check with `if ! cmd; then ... fi` and keep `-e`.)

**A10.4** — With root on the node the attacker controls everything the script reads: they can bind the backdoor to a port in `ALLOWED_PORTS` (a second listener on `10250` is impossible, but on `22` via a patched `sshd`, or simply multiplex the implant over the existing `6443`/`443` egress so it never listens at all); they can replace `ss`/`nft`/`curl` with wrappers that filter their own entries; they can edit `/usr/local/bin/check-external-exposure.sh` itself or point the timer at a stub; or they can load an LKM/eBPF program that hides the socket from `/proc/net/tcp` so even an unmodified `ss` cannot see it. The generic weakness is that the check is **on-host, in-band, and reads mutable local state** — the attacker is inside the measurement path. Detecting this needs (a) **runtime security with kernel-level visibility** — Falco, Tetragon, or an eBPF EDR emitting `listen()`/`connect()`/`execve` events off-node in real time; (b) **file integrity monitoring** on `/usr/local/bin`, `/etc/kubernetes`, `/etc/ssh`, and the systemd unit directories (AIDE, Falco rules, or the immutable-infrastructure answer: rebuild the node from an image and never patch in place); and (c) **out-of-band observation** — external scanning and network-flow analysis at the switch/VPC-flow-log layer, which the node cannot tamper with. State plainly in a review: any node-local check is a *drift* detector, not an *intrusion* detector.

</details>

---

## Sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Ports and Protocols* — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *kubelet configuration (v1beta1) reference* — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes, *Service* (types, `externalIPs`, `loadBalancerSourceRanges`, `allocateLoadBalancerNodePorts`, `externalTrafficPolicy`) — https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes, *Virtual IPs and Service Proxies* (`nodePortAddresses`, nftables mode) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes, *kube-proxy configuration (v1alpha1) reference* — https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Kubernetes, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *kube-apiserver reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- netfilter project, *nftables wiki — Configuring chains and hook priorities* — https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains
- CIS, *Kubernetes Benchmark* — https://www.cisecurity.org/benchmark/kubernetes
- Aqua Security, *kube-bench* — https://github.com/aquasecurity/kube-bench
- OpenSSH, *sshd_config(5)* — https://man.openbsd.org/sshd_config