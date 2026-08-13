# Topic 2.5 — High Availability Installations

## Guided Exercises

> **Scope.** These exercises build, break, diagnose and recover a highly available Kubernetes control plane from scratch, using `kubeadm`, `HAProxy`, `keepalived` and `etcd`. Every command is meant to be executed. Expected outputs are shown so you can compare, but **do not copy the outputs into your notes as if they were results** — run the commands and read *your* cluster.
>
> **Warning.** Exercises 5 and 6 deliberately destroy quorum and restore from a snapshot. Run this on disposable VMs only.

---

## Lab topology

Provision six VMs (2 vCPU / 4 GiB / 40 GiB SSD minimum for control plane nodes — etcd is fsync-bound, spinning disks will produce spurious leader elections).

| Role | Hostname | IP | Notes |
|---|---|---|---|
| Virtual IP (VIP) | `k8s-api.internal.example.com` | `192.168.100.10` | floats between control plane nodes via VRRP |
| Control plane 1 | `cp-1` | `192.168.100.11` | stacked etcd + haproxy + keepalived |
| Control plane 2 | `cp-2` | `192.168.100.12` | stacked etcd + haproxy + keepalived |
| Control plane 3 | `cp-3` | `192.168.100.13` | stacked etcd + haproxy + keepalived |
| Worker 1 | `w-1` | `192.168.100.21` | |
| Worker 2 | `w-2` | `192.168.100.22` | |

Target version for this walkthrough: **Kubernetes v1.33.x**. Substitute the version your exam targets; the topology and the failure semantics do not change.

Assumed already done on all six nodes: swap disabled, `containerd` installed and running with `SystemdCgroup = true`, `br_netfilter` loaded, `net.ipv4.ip_forward=1`, and `kubeadm`/`kubelet`/`kubectl` installed and version-pinned.

Reference: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/>

---

## Exercise 1 — Choose a topology and size the quorum before touching a keyboard

HA is a decision about *blast radius*, not about node count. Do this exercise on paper first, then verify the arithmetic with `etcd`'s own documentation.

**Steps**

1. Read the two supported `kubeadm` topologies and write down, in one sentence each, what a single node loss destroys in either case:
   - Stacked etcd: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/#stacked-etcd-topology>
   - External etcd: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/#external-etcd-topology>

2. Fill in this table from first principles. Quorum is `floor(N/2) + 1`; tolerated failures are `N - quorum`.

   | etcd members `N` | Quorum | Tolerated simultaneous failures |
   |---|---|---|
   | 1 | | |
   | 2 | | |
   | 3 | | |
   | 4 | | |
   | 5 | | |
   | 6 | | |
   | 7 | | |

3. Check your table against the upstream FAQ: <https://etcd.io/docs/v3.5/faq/#what-is-failure-tolerance>

4. Compute the *write* cost of adding members. An etcd write is committed only after it is durably persisted (fsync to the WAL) on a quorum of members. Argue in two sentences why a 7-member cluster is slower to write than a 3-member one, and why read throughput moves in the opposite direction (with `--consistency=s` serializable reads).

5. Record your sizing decision for this lab: **3 stacked control plane nodes**, tolerating **1** simultaneous failure.

**Verification questions**

- **Q1.1** Why does a 4-member etcd cluster provide *no more* availability than a 3-member one, while costing more on every write?
- **Q1.2** In the stacked topology, `cp-2` dies. Name every control plane component that disappears with it, and state which of them the cluster can lose without a user-visible outage.
- **Q1.3** You are told "we run 2 control plane nodes for HA." Explain precisely why this configuration is *less* available for writes than a single node with a good backup.
- **Q1.4** Under what concrete operational condition is the external etcd topology worth its doubled machine count?

---

## Exercise 2 — Build the control plane endpoint (`controlPlaneEndpoint`) before the cluster exists

The single most common irreversible mistake in an HA build is running `kubeadm init` without `controlPlaneEndpoint`. The API server's serving certificate and every kubeconfig on every node are minted against whatever address you used at init time; changing it later means regenerating certificates cluster-wide and re-issuing every kubeconfig.

**Steps**

1. On **each** of `cp-1`, `cp-2`, `cp-3`, install the load balancer pair:

   ```bash
   sudo apt-get install -y haproxy keepalived   # or: dnf install -y haproxy keepalived
   ```

2. Write `/etc/haproxy/haproxy.cfg` identically on all three control plane nodes:

   ```
   global
       log         /dev/log local0
       maxconn     20000
       daemon

   defaults
       mode                tcp
       log                 global
       option              tcplog
       option              dontlognull
       retries             3
       timeout connect     10s
       timeout client      4h
       timeout server      4h
       timeout check       5s

   frontend kube-apiserver
       bind                *:8443
       default-server      inter 3s fall 3 rise 2
       default_backend     kube-apiserver

   backend kube-apiserver
       balance             roundrobin
       option              httpchk
       http-check          send meth GET uri /readyz
       http-check          expect status 200
       default-server      check check-ssl verify none inter 3s fall 3 rise 2
       server cp-1 192.168.100.11:6443
       server cp-2 192.168.100.12:6443
       server cp-3 192.168.100.13:6443
   ```

   Note the frontend binds `:8443`, not `:6443` — the API servers themselves own `:6443` on these same hosts.

3. Write the VRRP health check `/etc/keepalived/check_apiserver.sh` (mode `0755`) on all three:

   ```bash
   #!/bin/sh
   errorExit() { echo "*** $*" 1>&2; exit 1; }

   APISERVER_VIP=192.168.100.10
   APISERVER_DEST_PORT=8443

   curl -sfk --max-time 2 https://localhost:${APISERVER_DEST_PORT}/readyz -o /dev/null \
     || errorExit "Error GET https://localhost:${APISERVER_DEST_PORT}/readyz"

   if ip addr | grep -q ${APISERVER_VIP}; then
       curl -sfk --max-time 2 https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/readyz -o /dev/null \
         || errorExit "Error GET https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/readyz"
   fi
   ```

4. Write `/etc/keepalived/keepalived.conf`. Use `priority` `101`, `100`, `99` on `cp-1`, `cp-2`, `cp-3` respectively; everything else is identical:

   ```
   ! /etc/keepalived/keepalived.conf
   global_defs {
       enable_script_security
       script_user root
   }

   vrrp_script check_apiserver {
       script   "/etc/keepalived/check_apiserver.sh"
       interval 3
       timeout  5
       fall     3
       rise     2
       weight   -20
   }

   vrrp_instance VI_1 {
       state             BACKUP
       interface         eth0
       virtual_router_id 51
       priority          101
       advert_int        1
       nopreempt
       authentication {
           auth_type PASS
           auth_pass 4f8a2b6c
       }
       virtual_ipaddress {
           192.168.100.10/24
       }
       track_script {
           check_apiserver
       }
   }
   ```

5. Start both services on all three nodes and confirm exactly one node owns the VIP:

   ```bash
   sudo systemctl enable --now haproxy keepalived
   ip -4 addr show dev eth0 | grep 192.168.100
   ```

   Expected on `cp-1` only:

   ```
       inet 192.168.100.11/24 brd 192.168.100.255 scope global eth0
       inet 192.168.100.10/24 scope global secondary eth0
   ```

6. Confirm the VIP is reachable and that HAProxy currently has **no** healthy backend (nothing is listening on `:6443` yet):

   ```bash
   nc -zv 192.168.100.10 8443
   sudo journalctl -u haproxy -n 20 --no-pager | grep -i 'is DOWN'
   ```

7. Add the DNS record (or `/etc/hosts` entry on all six nodes):

   ```
   192.168.100.10  k8s-api.internal.example.com
   ```

**Verification questions**

- **Q2.1** Why does the HAProxy frontend listen on `8443` instead of `6443` in this co-located design, and what would happen at `kubeadm init` time if it listened on `6443`?
- **Q2.2** The health check probes `/readyz`, not `/healthz` or a bare TCP connect. What failure mode does each of the two rejected options let through?
- **Q2.3** `timeout client` and `timeout server` are set to 4 hours. What breaks if you leave HAProxy's 50-second default in place?
- **Q2.4** All three nodes declare `state BACKUP` with `nopreempt`, rather than one `MASTER`. What operational behaviour is this trading away, and what is it buying?
- **Q2.5** `weight -20` on the tracked script — what does keepalived do with that number, and why is a negative weight preferable to `killing` the VRRP instance outright?

---

## Exercise 3 — Bootstrap the first control plane node from a declarative config

Never bootstrap an HA control plane from CLI flags. The config file is the artifact you version, diff and reuse in a rebuild.

**Steps**

1. On `cp-1`, write `/root/kubeadm-ha.yaml`:

   ```yaml
   apiVersion: kubeadm.k8s.io/v1beta4
   kind: InitConfiguration
   localAPIEndpoint:
     advertiseAddress: 192.168.100.11
     bindPort: 6443
   nodeRegistration:
     name: cp-1
     criSocket: unix:///run/containerd/containerd.sock
   ---
   apiVersion: kubeadm.k8s.io/v1beta4
   kind: ClusterConfiguration
   kubernetesVersion: v1.33.2
   clusterName: ha-lab
   controlPlaneEndpoint: "k8s-api.internal.example.com:8443"
   networking:
     podSubnet: 10.244.0.0/16
     serviceSubnet: 10.96.0.0/12
     dnsDomain: cluster.local
   apiServer:
     certSANs:
       - "k8s-api.internal.example.com"
       - "192.168.100.10"
       - "192.168.100.11"
       - "192.168.100.12"
       - "192.168.100.13"
       - "127.0.0.1"
     extraArgs:
       - name: "goaway-chance"
         value: "0.001"
       - name: "shutdown-delay-duration"
         value: "20s"
   controllerManager:
     extraArgs:
       - name: "node-monitor-grace-period"
         value: "40s"
   etcd:
     local:
       dataDir: /var/lib/etcd
       extraArgs:
         - name: "heartbeat-interval"
           value: "250"
         - name: "election-timeout"
           value: "2500"
   ---
   apiVersion: kubelet.config.k8s.io/v1beta1
   kind: KubeletConfiguration
   cgroupDriver: systemd
   ```

   `v1beta4` (Kubernetes ≥ 1.31) expresses `extraArgs` as a **list of `{name, value}` objects**, not a map — this is the change that breaks copy-pasted `v1beta3` configs. Reference: <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>

2. Dry-run first. This renders every static Pod manifest without writing to `/etc/kubernetes`:

   ```bash
   sudo kubeadm init --config /root/kubeadm-ha.yaml --upload-certs --dry-run
   ```

3. Initialise:

   ```bash
   sudo kubeadm init --config /root/kubeadm-ha.yaml --upload-certs | tee /root/kubeadm-init.log
   ```

   The tail contains **two different join commands**. Capture both:

   ```
   You can now join any number of control-plane nodes running the following command on each as root:

     kubeadm join k8s-api.internal.example.com:8443 --token 9f2k1x.8d7c6b5a4e3f2g1h \
       --discovery-token-ca-cert-hash sha256:0b3e...c91a \
       --control-plane --certificate-key 7c1f...9ae2

   Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
   As a safeguard, uploaded-certs will be deleted in two hours; ...

   Then you can join any number of worker nodes by running the following on each as root:

   kubeadm join k8s-api.internal.example.com:8443 --token 9f2k1x.8d7c6b5a4e3f2g1h \
       --discovery-token-ca-cert-hash sha256:0b3e...c91a
   ```

4. Configure `kubectl` and install a CNI plugin (nothing becomes `Ready` until you do):

   ```bash
   mkdir -p $HOME/.kube && sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
   ```

5. Prove that the certificate you just minted actually covers the VIP name — this is what makes the other two joins possible:

   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
     | grep -A1 'Subject Alternative Name'
   ```

   Expected (order may vary):

   ```
           X509v3 Subject Alternative Name:
               DNS:cp-1, DNS:k8s-api.internal.example.com, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.100.11, IP Address:192.168.100.10, IP Address:192.168.100.12, IP Address:192.168.100.13, IP Address:127.0.0.1
   ```

6. Confirm your kubeconfig points at the VIP, not at `cp-1`:

   ```bash
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
   ```

   ```
   https://k8s-api.internal.example.com:8443
   ```

7. Watch HAProxy pick up the first healthy backend:

   ```bash
   sudo journalctl -u haproxy -n 30 --no-pager | grep -i 'is UP'
   ```

**Verification questions**

- **Q3.1** `advertiseAddress` is `192.168.100.11` while `controlPlaneEndpoint` is the VIP. What distinct thing does each value control? Which one ends up in the `kubernetes` Service's EndpointSlice?
- **Q3.2** You omitted `--upload-certs`. The `--control-plane` join command is missing from the output. What exactly did `--upload-certs` do, where does the material live, and how do you recover 3 hours later?
- **Q3.3** Why do `192.168.100.12` and `.13` appear in `certSANs` even though no API server runs there yet?
- **Q3.4** `--goaway-chance=0.001` is set. Which specific HA failure mode does it address, and why is the documented maximum only `0.02`?
- **Q3.5** etcd's `heartbeat-interval` was raised from the 100 ms default to 250 ms and `election-timeout` from 1000 ms to 2500 ms. State the invariant that must hold between the two values, and the symptom you are protecting against.

---

## Exercise 4 — Join the remaining control plane nodes and verify real membership

**Steps**

1. On `cp-2`, run the `--control-plane` join command captured in Exercise 3, adding an explicit advertise address:

   ```bash
   sudo kubeadm join k8s-api.internal.example.com:8443 \
     --token 9f2k1x.8d7c6b5a4e3f2g1h \
     --discovery-token-ca-cert-hash sha256:0b3e...c91a \
     --control-plane --certificate-key 7c1f...9ae2 \
     --apiserver-advertise-address 192.168.100.12
   ```

2. Repeat on `cp-3` with `--apiserver-advertise-address 192.168.100.13`.

3. If the two-hour window expired, regenerate both secrets instead of guessing:

   ```bash
   # on cp-1
   sudo kubeadm init phase upload-certs --upload-certs
   sudo kubeadm token create --print-join-command
   ```

4. Join the two workers with the **worker** join command (no `--control-plane`, no `--certificate-key`).

5. Verify from `cp-1`:

   ```bash
   kubectl get nodes -o wide
   ```

   ```
   NAME   STATUS   ROLES           AGE     VERSION   INTERNAL-IP
   cp-1   Ready    control-plane   14m     v1.33.2   192.168.100.11
   cp-2   Ready    control-plane   6m21s   v1.33.2   192.168.100.12
   cp-3   Ready    control-plane   3m47s   v1.33.2   192.168.100.13
   w-1    Ready    <none>          2m11s   v1.33.2   192.168.100.21
   w-2    Ready    <none>          97s     v1.33.2   192.168.100.22
   ```

6. **Node count is not membership.** Verify etcd's own view. Define a helper on `cp-1`:

   ```bash
   alias e3="kubectl -n kube-system exec -i etcd-cp-1 -- etcdctl \
     --endpoints=https://192.168.100.11:2379,https://192.168.100.12:2379,https://192.168.100.13:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key"
   ```

   ```bash
   e3 member list -w table
   ```

   ```
   +------------------+---------+------+-----------------------------+-----------------------------+------------+
   |        ID        | STATUS  | NAME |         PEER ADDRS          |        CLIENT ADDRS         | IS LEARNER |
   +------------------+---------+------+-----------------------------+-----------------------------+------------+
   | 3a1d9c0f5b2e7841 | started | cp-1 | https://192.168.100.11:2380 | https://192.168.100.11:2379 |      false |
   | 8c47f2b6a90d1e35 | started | cp-2 | https://192.168.100.12:2380 | https://192.168.100.12:2379 |      false |
   | b91e04a7cd68f2a3 | started | cp-3 | https://192.168.100.13:2380 | https://192.168.100.13:2379 |      false |
   +------------------+---------+------+-----------------------------+-----------------------------+------------+
   ```

7. Identify the current Raft leader and the database size per member:

   ```bash
   e3 endpoint status --cluster -w table
   ```

   ```
   +-----------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   |          ENDPOINT           |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
   +-----------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   | https://192.168.100.11:2379 | 3a1d9c0f5b2e7841 |   3.5.x |  6.2 MB |      true |      false |         3 |      18422 |              18422 |        |
   | https://192.168.100.12:2379 | 8c47f2b6a90d1e35 |   3.5.x |  6.1 MB |     false |      false |         3 |      18422 |              18422 |        |
   | https://192.168.100.13:2379 | b91e04a7cd68f2a3 |   3.5.x |  6.1 MB |     false |      false |         3 |      18422 |              18422 |        |
   +-----------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   ```

8. Inspect how the *stateless* control plane components achieve HA — they do not shard, they elect:

   ```bash
   kubectl -n kube-system get lease kube-scheduler kube-controller-manager \
     -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime
   ```

   ```
   NAME                      HOLDER                                           RENEWED
   kube-controller-manager   cp-1_4f6c1a2b-9d3e-4f18-8c77-1a2b3c4d5e6f        2026-08-13T14:22:41.000000Z
   kube-scheduler            cp-2_7a9e5d31-2c48-4b60-9f11-8e7d6c5b4a39        2026-08-13T14:22:42.000000Z
   ```

9. Now inspect the API server, which does **not** elect — every replica is active:

   ```bash
   kubectl -n kube-system get leases -l apiserver.kubernetes.io/identity=kube-apiserver
   kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o yaml | grep -E 'addresses|port:'
   ```

   ```
     - addresses:
       - 192.168.100.11
       - addresses:
       - 192.168.100.12
       - addresses:
       - 192.168.100.13
       port: 6443
   ```

10. Confirm which path an in-cluster client takes:

    ```bash
    kubectl run probe --rm -it --image=curlimages/curl --restart=Never -- \
      sh -c 'curl -sk https://kubernetes.default.svc/livez; echo'
    ```

**Verification questions**

- **Q4.1** `kubectl get nodes` shows three `Ready` control plane nodes, but `etcdctl member list` shows two members. Is the cluster healthy? What exact situation produces this, and which output do you trust?
- **Q4.2** A Pod resolves `kubernetes.default.svc` and connects to `10.96.0.1:443`. Trace the path to an actual API server. Does traffic pass through HAProxy or the VIP? Why does that matter when you are draining a control plane node?
- **Q4.3** `kube-controller-manager` runs as a static Pod on all three nodes, yet only one holds the Lease. What are the other two doing, and what is the worst-case time before one of them takes over after the holder is hard-killed? (Use the defaults `leader-elect-lease-duration=15s`, `renew-deadline=10s`, `retry-period=2s`.)
- **Q4.4** Why is `--control-plane` join *not* idempotent in the same sense as a worker join, and what must you run before retrying a failed control plane join?
- **Q4.5** The `RAFT INDEX` on `cp-3` is 400 behind the leader and stays behind. What are the two most likely causes, and which single metric confirms the more common one?

---

## Exercise 5 — Break it: degraded operation, then quorum loss

This is the exercise that teaches the difference between "a node is down" and "the cluster is down".

**Steps**

1. Establish a baseline write path in a second terminal, and leave it running for the whole exercise:

   ```bash
   while true; do
     date -u +%T
     kubectl -n default annotate --overwrite pod/probe canary="$(date -u +%s)" 2>&1 | tail -1
     sleep 2
   done
   ```

   (If `probe` no longer exists, use `kubectl create configmap canary-$RANDOM --from-literal=t=$(date +%s)`.)

2. **Lose one node (n=1, quorum survives).** On `cp-3`:

   ```bash
   sudo systemctl stop kubelet containerd
   ```

3. Observe from `cp-1`. Writes should continue uninterrupted:

   ```bash
   e3 endpoint health --cluster -w table
   ```

   ```
   +-----------------------------+--------+-------------+-------------------------+
   |          ENDPOINT           | HEALTH |    TOOK     |          ERROR          |
   +-----------------------------+--------+-------------+-------------------------+
   | https://192.168.100.11:2379 |   true |  4.112211ms |                         |
   | https://192.168.100.12:2379 |   true |  4.980113ms |                         |
   | https://192.168.100.13:2379 |  false | 5.000216114s | context deadline exceeded |
   +-----------------------------+--------+-------------+-------------------------+
   ```

4. Confirm HAProxy removed the dead backend on every LB instance:

   ```bash
   sudo journalctl -u haproxy --since '2 min ago' --no-pager | grep -i 'cp-3'
   ```

   ```
   haproxy[912]: Server kube-apiserver/cp-3 is DOWN, reason: Layer4 connection problem, ... 2 active and 0 backup servers left. 0 sessions active...
   ```

5. **Lose a second node (n=2, quorum lost).** On `cp-2`:

   ```bash
   sudo systemctl stop kubelet containerd
   ```

6. Watch the canary loop. Then run, from `cp-1`:

   ```bash
   kubectl get nodes
   ```

   ```
   Error from server (InternalError): an error on the server ("") has prevented the request from succeeding (get nodes)
   ```

   ```bash
   kubectl get --raw='/readyz?verbose' | tail -20
   ```

   ```
   [+]ping ok
   [+]log ok
   [-]etcd failed: reason withheld
   [-]etcd-readiness failed: reason withheld
   [+]informer-sync ok
   ...
   readyz check failed
   ```

7. Read the actual cause in the surviving etcd's log — this is the string to memorise:

   ```bash
   sudo crictl ps -a --name etcd
   sudo crictl logs --tail 20 $(sudo crictl ps -q --name etcd)
   ```

   ```
   {"level":"warn","msg":"lost leader","local-member-id":"3a1d9c0f5b2e7841"}
   {"level":"warn","msg":"failed to send out heartbeat on time","to":"8c47f2b6a90d1e35"}
   {"level":"warn","msg":"apply request took too long","error":"etcdserver: request timed out"}
   {"level":"info","msg":"3a1d9c0f5b2e7841 is starting a new election at term 3"}
   {"level":"info","msg":"3a1d9c0f5b2e7841 became candidate at term 4"}
   {"level":"info","msg":"3a1d9c0f5b2e7841 received MsgVoteResp from 3a1d9c0f5b2e7841 at term 4"}
   ```

8. Determine empirically what still works with no quorum. Try each and record the result:

   ```bash
   kubectl get --raw='/livez'          # process liveness
   kubectl get --raw='/readyz'         # readiness (LB decision)
   kubectl get nodes                   # a read
   kubectl create ns quorum-test       # a write
   ```

   On a worker, check whether already-running Pods kept serving traffic:

   ```bash
   curl -s http://<pod-ip>:80 >/dev/null && echo "dataplane OK"
   ```

9. **Recover.** Start `cp-2` again and confirm the cluster returns without operator intervention:

   ```bash
   # on cp-2
   sudo systemctl start containerd kubelet
   ```

   ```bash
   # on cp-1, within ~30s
   e3 endpoint status --cluster -w table
   kubectl get nodes
   ```

10. Restore `cp-3` the same way and confirm all three members are `started` with equal `RAFT APPLIED INDEX`.

**Verification questions**

- **Q5.1** With 2 of 3 etcd members down, `/livez` returns `ok` but `/readyz` fails. Explain the design intent of that split, and what would go wrong if `/livez` also failed.
- **Q5.2** During the quorum outage, Pods already running on `w-1` kept serving traffic. Name three cluster behaviours that were nonetheless silently suspended, and state the user-visible consequence of each.
- **Q5.3** A colleague proposes fixing the outage by running `etcdctl member remove` on the two dead members to "get back to a 1-node cluster". Why does this command fail, and what is the actual escape hatch?
- **Q5.4** Recovery required no `etcdctl` at all — the members rejoined by themselves. What state on disk made that possible, and in which failure mode does it *not* happen?
- **Q5.5** In step 6, `kubectl` returned `InternalError` rather than a connection error. What does that tell you about where the failure is, and how would the error text differ if the VIP itself had failed over incorrectly?

---

## Exercise 6 — Snapshot, and restore an HA etcd cluster from total loss

Backups that were never restored are not backups. Reference: <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster> and <https://etcd.io/docs/v3.5/op-guide/recovery/>

**Steps**

1. Create a marker object so you can prove the restore worked *and* prove data loss:

   ```bash
   kubectl create ns before-snapshot
   ```

2. Take a snapshot from a **single** member endpoint (a snapshot is a member-local operation; `--cluster` is not valid here):

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://192.168.100.11:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save /root/etcd-$(date -u +%Y%m%dT%H%M%SZ).db
   ```

   ```
   {"level":"info","msg":"created temporary db file","path":"/root/etcd-20260813T143010Z.db.part"}
   {"level":"info","msg":"fetching snapshot","endpoint":"https://192.168.100.11:2379"}
   {"level":"info","msg":"fetched snapshot","endpoint":"https://192.168.100.11:2379","size":"6.2 MB","took":"213.7ms"}
   Snapshot saved at /root/etcd-20260813T143010Z.db
   ```

3. Verify the snapshot before you need it:

   ```bash
   sudo etcdutl --write-out=table snapshot status /root/etcd-20260813T143010Z.db
   ```

   ```
   +----------+----------+------------+------------+
   |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
   +----------+----------+------------+------------+
   | 7f31c0a2 |    18904 |       1147 |     6.2 MB |
   +----------+----------+------------+------------+
   ```

4. Copy the snapshot to all three control plane nodes and to somewhere **off** the cluster.

5. Create a marker that is *newer than the snapshot* — this is the data you are about to lose:

   ```bash
   kubectl create ns after-snapshot
   ```

6. **Simulate total etcd loss.** On all three control plane nodes:

   ```bash
   sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak    # stop the static Pod
   sudo crictl ps --name etcd                                          # wait until empty
   sudo mv /var/lib/etcd /var/lib/etcd.lost
   ```

7. **Restore on all three nodes from the same snapshot**, each with its own `--name` / `--initial-advertise-peer-urls`, an identical `--initial-cluster` naming all three peers, and a **new** cluster token:

   ```bash
   # cp-1
   sudo etcdutl snapshot restore /root/etcd-20260813T143010Z.db \
     --name cp-1 \
     --initial-cluster cp-1=https://192.168.100.11:2380,cp-2=https://192.168.100.12:2380,cp-3=https://192.168.100.13:2380 \
     --initial-cluster-token ha-lab-restore-1 \
     --initial-advertise-peer-urls https://192.168.100.11:2380 \
     --data-dir /var/lib/etcd
   ```

   ```
   # cp-2
   sudo etcdutl snapshot restore /root/etcd-20260813T143010Z.db \
     --name cp-2 \
     --initial-cluster cp-1=https://192.168.100.11:2380,cp-2=https://192.168.100.12:2380,cp-3=https://192.168.100.13:2380 \
     --initial-cluster-token ha-lab-restore-1 \
     --initial-advertise-peer-urls https://192.168.100.12:2380 \
     --data-dir /var/lib/etcd
   ```

   ```
   # cp-3 — same, with cp-3 / .13
   ```

   Expected on each:

   ```
   2026-08-13T14:41:02Z	info	snapshot/v3_snapshot.go:265	restoring snapshot	{"path": "/root/etcd-20260813T143010Z.db", "wal-dir": "/var/lib/etcd/member/wal", "data-dir": "/var/lib/etcd", "snap-dir": "/var/lib/etcd/member/snap"}
   2026-08-13T14:41:02Z	info	membership/cluster.go:421	added member	{"cluster-id": "d9a7c1b3e05f4826", "local-member-id": "0", "added-peer-id": "3a1d9c0f5b2e7841", ...}
   ```

8. Fix ownership and restart etcd on all three nodes:

   ```bash
   sudo chown -R etcd:etcd /var/lib/etcd 2>/dev/null || sudo chown -R root:root /var/lib/etcd
   sudo mv /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
   ```

9. Restart the other control plane components so they reconnect and re-elect cleanly:

   ```bash
   sudo systemctl restart kubelet
   ```

10. Verify. Note the new cluster ID and the reset Raft term:

    ```bash
    e3 endpoint status --cluster -w table
    kubectl get ns | grep -E 'before-snapshot|after-snapshot'
    ```

    ```
    before-snapshot   Active   19m
    ```

11. Confirm the expected data loss and reason about it:

    ```bash
    kubectl get ns after-snapshot
    ```

    ```
    Error from server (NotFound): namespaces "after-snapshot" not found
    ```

**Verification questions**

- **Q6.1** Why must `--initial-cluster-token` change on restore? What concrete accident does the token prevent?
- **Q6.2** You restored on `cp-1` only, then started etcd on `cp-2` and `cp-3` with their *old* `/var/lib/etcd` directories intact. Describe what happens and why it is worse than a clean outage.
- **Q6.3** Restoring from a snapshot rolls the cluster back to revision 18904. Beyond the missing Namespace, name two categories of *external* state that are now inconsistent with etcd, and how each manifests.
- **Q6.4** Why must the etcd static Pod be stopped *before* moving `/var/lib/etcd`, rather than moving the directory first?
- **Q6.5** The snapshot was taken from `192.168.100.11` alone. Under what circumstance would a snapshot taken from a *follower* be meaningfully staler than one from the leader, and does that matter for a Kubernetes restore?
- **Q6.6** `etcdctl snapshot restore` also exists. Why does upstream now direct you to `etcdutl`, and what does that split tell you about whether restore talks to a running server?

---

## Exercise 7 — Operate the HA cluster: rolling upgrade, certificate rotation, graceful drain

An HA control plane exists so that maintenance is not an outage. Prove it.

**Steps**

1. Audit certificate expiry across the control plane. Every control plane node has its own set — `kubeadm` does **not** rotate them cluster-wide:

   ```bash
   sudo kubeadm certs check-expiration
   ```

   ```
   CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   admin.conf                 Aug 13, 2027 14:10 UTC   364d            no
   apiserver                  Aug 13, 2027 14:10 UTC   364d            no
   apiserver-etcd-client      Aug 13, 2027 14:10 UTC   364d            no
   apiserver-kubelet-client   Aug 13, 2027 14:10 UTC   364d            no
   controller-manager.conf    Aug 13, 2027 14:10 UTC   364d            no
   etcd-healthcheck-client    Aug 13, 2027 14:10 UTC   364d            no
   etcd-peer                  Aug 13, 2027 14:10 UTC   364d            no
   etcd-server                Aug 13, 2027 14:10 UTC   364d            no
   scheduler.conf             Aug 13, 2027 14:10 UTC   364d            no

   CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME
   ca                      Aug 11, 2036 14:10 UTC   9y
   etcd-ca                 Aug 11, 2036 14:10 UTC   9y
   front-proxy-ca          Aug 11, 2036 14:10 UTC   9y
   ```

2. Rotate on **one** node and confirm the blast radius is one node:

   ```bash
   sudo kubeadm certs renew all
   sudo systemctl restart kubelet     # or: crictl rm the control plane containers
   sudo kubeadm certs check-expiration | head -5
   ```

   While it restarts, run a read loop against the VIP from your workstation and confirm zero failures:

   ```bash
   for i in $(seq 1 60); do kubectl get --raw=/livez >/dev/null || echo "FAIL $i"; sleep 1; done
   ```

3. Start a rolling minor-patch upgrade. **First control plane node only:**

   ```bash
   # cp-1
   sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.33.3-1.1 && sudo apt-mark hold kubeadm
   sudo kubeadm upgrade plan
   ```

   ```
   [upgrade/versions] Cluster version: v1.33.2
   [upgrade/versions] kubeadm version: v1.33.3
   Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
   COMPONENT   CURRENT       TARGET
   kubelet     5 x v1.33.2   v1.33.3
   ```

   ```bash
   sudo kubeadm upgrade apply v1.33.3
   ```

4. **Every other control plane node** uses a different verb:

   ```bash
   # cp-2 and cp-3
   sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.33.3-1.1 && sudo apt-mark hold kubeadm
   sudo kubeadm upgrade node
   ```

5. Upgrade the `kubelet` node by node, draining first:

   ```bash
   kubectl drain cp-1 --ignore-daemonsets
   # on cp-1:
   sudo apt-mark unhold kubelet kubectl \
     && sudo apt-get install -y kubelet=1.33.3-1.1 kubectl=1.33.3-1.1 \
     && sudo apt-mark hold kubelet kubectl
   sudo systemctl daemon-reload && sudo systemctl restart kubelet
   kubectl uncordon cp-1
   ```

6. Confirm the drain of a control plane node did **not** stop etcd, and reason about why:

   ```bash
   e3 endpoint health --cluster -w table
   sudo crictl ps --name etcd
   ```

7. Test the API server's graceful shutdown path, which is what makes step 5 non-disruptive behind a load balancer. On `cp-2`, delete the API server container and watch the LB:

   ```bash
   kubectl get --raw='/readyz?verbose' --server=https://192.168.100.12:6443 --insecure-skip-tls-verify | grep shutdown
   ```

   ```
   [+]shutdown ok
   ```

8. Repeat the read loop from step 2 for the entire upgrade window and record the number of failures. Any non-zero count is a finding — investigate it against your HAProxy `fall`/`inter` settings and `shutdown-delay-duration`.

**Verification questions**

- **Q7.1** `kubeadm upgrade apply` runs on exactly one node and `kubeadm upgrade node` on the rest. What does `apply` do that `node` must not do a second time?
- **Q7.2** Certificate rotation is per-node and `kubeadm` will happily leave `cp-3` expired. What is the observable symptom on `cp-3` the day its `apiserver` cert expires, and why might monitoring *not* catch it if you only alert on `kubectl get nodes`?
- **Q7.3** `shutdown-delay-duration: 20s` was set in Exercise 3. Describe the exact sequence between `SIGTERM` and process exit, and which HAProxy setting must be smaller than 20 s for the design to work.
- **Q7.4** Draining `cp-1` evicted workloads but etcd kept running. Why? What would you have to do to actually stop etcd on that node, and why is `kubectl drain` the wrong tool for it?
- **Q7.5** You upgraded from v1.33.2 to v1.33.3. Explain why the *order* control plane → workers is mandatory, and what version-skew rule would be violated by doing it the other way.

---

## Diagnostic reference

Commands worth having in muscle memory when an HA control plane misbehaves:

| Symptom | Command | What it tells you |
|---|---|---|
| `kubectl` hangs or 500s | `kubectl get --raw='/readyz?verbose'` | which subsystem gate failed |
| Suspected quorum loss | `etcdctl endpoint status --cluster -w table` | leader presence, per-member Raft index |
| Slow API, no obvious cause | `etcdctl alarm list` | `NOSPACE` from hitting `quota-backend-bytes` (2 GiB default) |
| DB size grows without keys | `etcdctl endpoint status` → `DB SIZE` vs `etcdutl snapshot status` → `TOTAL KEYS` | fragmentation; fix with `etcdctl defrag --cluster` |
| Random leader elections | etcd metrics `etcd_disk_wal_fsync_duration_seconds` p99 | disk fsync > ~10 ms means the disk is the fault |
| Component "not doing anything" | `kubectl -n kube-system get lease` | who holds leadership, and whether `renewTime` is advancing |
| Client stuck on one API server | `--goaway-chance`, then `ss -tnp \| grep 6443` on a kubelet | connection pinning after failover |
| Node joined but not in etcd | `etcdctl member list` vs `kubectl get nodes` | a failed `--control-plane` join |

---

## Sources

- KCA curriculum: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Creating Highly Available Clusters with kubeadm: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/>
- Options for Highly Available Topology: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/>
- Set up a HA etcd cluster with kubeadm: <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/setup-ha-etcd-with-kubeadm/>
- kubeadm configuration API `v1beta4`: <https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/>
- Operating etcd clusters for Kubernetes: <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Upgrading kubeadm clusters: <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/>
- Certificate management with kubeadm: <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/>
- Kubernetes API health endpoints: <https://kubernetes.io/docs/reference/using-api/health-checks/>
- Leases: <https://kubernetes.io/docs/concepts/architecture/leases/>
- kube-apiserver reference (`--goaway-chance`, `--shutdown-delay-duration`): <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>
- Version skew policy: <https://kubernetes.io/releases/version-skew-policy/>
- etcd FAQ (failure tolerance, tuning): <https://etcd.io/docs/v3.5/faq/>
- etcd disaster recovery: <https://etcd.io/docs/v3.5/op-guide/recovery/>
- etcd tuning: <https://etcd.io/docs/v3.5/tuning/>
- etcd hardware recommendations: <https://etcd.io/docs/v3.5/op-guide/hardware/>
- keepalived documentation: <https://keepalived.readthedocs.io/en/latest/>
- HAProxy configuration manual: <https://docs.haproxy.org/2.8/configuration.html>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** Quorum for `N=4` is `floor(4/2)+1 = 3`, so it tolerates `4-3 = 1` failure — identical to `N=3`. Meanwhile every write must be fsynced by 3 members instead of 2, and every Raft round trip involves more peers, so latency rises and the probability that *some* member is slow increases. Even-numbered clusters strictly increase cost and increase the chance of hitting a failure that costs quorum, without buying tolerance. Always use an odd member count.

**A1.2** Losing `cp-2` removes: one etcd member, one `kube-apiserver`, one `kube-controller-manager` replica, one `kube-scheduler` replica, one `kube-proxy`, one `kubelet`, one HAProxy and one keepalived instance. All of them are survivable: etcd still has 2 of 3 (quorum holds), the API server is active-active behind the LB and two remain, and the controller-manager/scheduler are active-passive with leader election, so if `cp-2` held a Lease another replica acquires it within roughly 15 s. There is no user-visible outage — only reduced headroom, because a *second* failure now stops writes.

**A1.3** Quorum for `N=2` is `floor(2/2)+1 = 2`. Both members must be up for any write to commit, so the cluster's write availability is `p²` where `p` is single-node availability — strictly worse than one node. A single node with backups has availability `p` plus a bounded recovery. Two members is the worst possible configuration: double the failure surface, zero fault tolerance.

**A1.4** When etcd's resource profile conflicts with the API server's on the same box, or when the fault domains must differ. Concretely: large clusters where etcd needs dedicated NVMe and predictable I/O and the API server's CPU spikes cause fsync latency; a requirement that losing a control plane node never touch cluster state; or an etcd cluster shared/managed by a separate team with its own lifecycle. The price is double the machines and a second CA/PKI to operate — for a 3-node cluster of ordinary size, stacked is the right default.

---

### Exercise 2

**A2.1** The API server itself binds `0.0.0.0:6443` on each control plane node. Since HAProxy is co-located on those same nodes, both cannot own port 6443 on the same address. If HAProxy bound `:6443`, either `kubeadm init` would fail with `Port 6443 is in use` during preflight, or — if HAProxy started later — HAProxy would fail to bind and the VIP would front nothing. Splitting the port (`8443` for the LB, `6443` for the API servers) is what makes the co-located design work. An external, dedicated load balancer pair can use `6443` on both sides.

**A2.2** A bare TCP connect only proves something is listening; an API server that has lost etcd still accepts TCP connections, so the LB would keep routing traffic to a server that returns `500` on every request. `/healthz` is the legacy aggregate endpoint and is deprecated for this purpose — it reports liveness-ish state and can be `ok` while the server is not yet ready to serve (still syncing informers, or shutting down). `/readyz` is the endpoint that specifically answers "should traffic be sent here", and it flips to failing during graceful shutdown *before* connections are refused — which is exactly the signal a load balancer needs.

**A2.3** Kubernetes clients use long-lived `WATCH` connections (kubelets, controllers, `kubectl get -w`, operators). With a 50-second idle timeout HAProxy silently severs them, and every watcher must re-LIST and re-WATCH. At scale this produces a synchronised thundering herd of expensive LIST requests against the API servers roughly every 50 seconds. The timeout must exceed the API server's own request timeout (`--min-request-timeout`, default 1800 s, randomised upward), hence a value of several hours.

**A2.4** With `state BACKUP` everywhere plus `nopreempt`, the VIP does not migrate back when a higher-priority node recovers. You give up deterministic VIP placement (you must check `ip addr` to know where it is). You buy the elimination of a second, unnecessary failover: when `cp-1` reboots and comes back, a preempting configuration would move the VIP again, dropping every established TCP connection a second time for no benefit. One failover per incident instead of two.

**A2.5** keepalived subtracts 20 from the instance's effective VRRP priority when `check_apiserver.sh` exits non-zero (and adds it back, capped, when the script recovers). Because the configured priorities differ by only 1–2, a 20-point penalty is enough to push a broken node below its healthy peers and hand the VIP away. Using a weight rather than tearing the instance down keeps the node participating in VRRP — it still advertises, still receives advertisements, and can reclaim the VIP the moment its check passes, instead of requiring a full instance re-initialisation. It also degrades gracefully: if *all* nodes fail the check, the penalty applies uniformly and the VIP stays somewhere rather than vanishing entirely.

---

### Exercise 3

**A3.1** `advertiseAddress` is this specific API server's own address: it is what the API server binds/advertises and what it registers into the `kubernetes` Service's EndpointSlice in the `default` namespace, so it is the address *in-cluster* clients reach through the ClusterIP. `controlPlaneEndpoint` is the cluster-wide stable address: it goes into every generated kubeconfig, into the `cluster-info` ConfigMap used by `kubeadm join` discovery, and it is the address *external* clients and joining nodes use. The EndpointSlice gets `advertiseAddress` (`192.168.100.11`), never the VIP.

**A3.2** `--upload-certs` copies the cluster CA keys and the other shared control plane certificates into a Secret named `kubeadm-certs` in `kube-system`, encrypted with a freshly generated 32-byte `certificate-key`; joining control plane nodes decrypt it with that key instead of you copying private keys around by hand. The Secret carries an owner reference to a token whose TTL is 2 hours, after which it is garbage-collected. Three hours later, run `kubeadm init phase upload-certs --upload-certs` on an existing control plane node to re-upload and print a new key, and `kubeadm token create --print-join-command` for a fresh bootstrap token — then combine them.

**A3.3** The API server's serving certificate is generated once, on `cp-1`, and the *same* certificate and key are distributed to `cp-2` and `cp-3` through the `kubeadm-certs` Secret. If `.12` and `.13` were not in the SAN list, any client connecting directly to those nodes' `192.168.100.12:6443` / `.13:6443` — including HAProxy's own health check, `kubelet`s configured with a direct address, and your `--server=https://192.168.100.12:6443` debugging — would fail TLS verification with `x509: certificate is valid for ..., not 192.168.100.12`. SANs must be complete at init time; adding one later requires deleting `apiserver.crt`/`.key` and running `kubeadm init phase certs apiserver` on every control plane node.

**A3.4** HTTP/2 multiplexes many requests over one TCP connection, so once a kubelet or controller establishes a connection to a particular API server it keeps using it indefinitely. After a failover — or after adding a third API server — all clients remain pinned to the servers they originally reached, and load never rebalances; the recovered node sits idle while the survivors stay saturated. `--goaway-chance` makes the API server send an HTTP/2 `GOAWAY` frame on a random fraction of requests, causing the client to reconnect (through the LB, landing anywhere) while the in-flight request still completes successfully. The maximum is `0.02` because the reconnect is not free: at higher rates the connection churn and TLS handshakes cost more than the imbalance they fix. Values around `0.001`–`0.005` are the practical range.

**A3.5** The invariant is `election-timeout ≥ 5 × heartbeat-interval` (upstream recommends 5–10×), and `heartbeat-interval` should be at least the round-trip time between members. Here 2500 ≥ 5 × 250 holds. The symptom being protected against is *spurious leader elections*: if a heartbeat is delayed past the election timeout — by network jitter, a slow disk, or CPU starvation on the leader — followers assume the leader is dead and start a new election. Each election is a brief write outage and a new Raft term, and on a marginal network they can repeat indefinitely, producing a cluster that is nominally up but never commits anything. The cost of raising these values is a longer detection window for a genuinely dead leader. `election-timeout` must not exceed 50000 ms.

---

### Exercise 4

**A4.1** The cluster is **not** healthy, and `etcdctl member list` is the output to trust. `kubectl get nodes` reports on the `kubelet` — a node is `Ready` as soon as its kubelet registers and the CNI is up, regardless of whether the etcd member on it ever joined. This state is produced by a `kubeadm join --control-plane` that failed *after* the kubelet started but *before* or during the `etcd` member-add phase, leaving a node that looks like a control plane node but contributes no etcd member. It is dangerous because the operator believes they tolerate one failure when they actually have a 2-member cluster tolerating zero. Always verify HA at the etcd layer, never at the node layer.

**A4.2** The Pod's traffic to `10.96.0.1:443` is DNAT'd by `kube-proxy` (iptables/IPVS rules on the Pod's own node) to one of the addresses in the `kubernetes` EndpointSlice — `192.168.100.11:6443`, `.12:6443` or `.13:6443` — chosen at connection time. It does **not** pass through HAProxy or the VIP at all; those exist for out-of-cluster clients and for `kubeadm join`. This matters when draining: `kubectl drain` and HAProxy's health check only affect the external path. In-cluster clients keep being sent to the node's API server until the API server actually stops serving and removes itself from the EndpointSlice (the lease-based endpoint reconciler does this on graceful shutdown, but there is a propagation delay). So "the LB has drained it" does not mean "no in-cluster client is talking to it".

**A4.3** The other two replicas are running, connected to the API server, and repeatedly attempting to acquire the Lease object — they run no controllers and schedule nothing. Worst case: the holder is hard-killed immediately after a successful renew, so the Lease is valid for another `leaseDurationSeconds` = 15 s; a candidate observing an unrenewed Lease waits for it to expire, then attempts acquisition on its `retryPeriod` = 2 s cadence. Worst case is therefore roughly 15 s + up to 2 s of retry phase + the time to initialise controllers — call it ~15–20 s of no scheduling and no controller reconciliation. `renewDeadline` = 10 s is the *holder's* self-fencing timeout: if it cannot renew within 10 s it stops acting as leader voluntarily, which is what guarantees no two leaders act simultaneously.

**A4.4** A worker join only registers a kubelet; rerunning it after `kubeadm reset` is clean. A `--control-plane` join additionally calls `etcdctl member add` against the live etcd cluster — a *cluster-wide mutation*. A join that fails after that call leaves a phantom member in the membership list; etcd counts it toward quorum immediately, so a 3-member cluster with one phantom member has quorum 3 and tolerates zero failures. Before retrying you must run `kubeadm reset` on the failed node **and** verify with `etcdctl member list` that no stale member remains, removing it with `etcdctl member remove <ID>` if it does. (Modern `kubeadm` adds members as *learners* first, which does not affect quorum until promotion — but you must still confirm, not assume.)

**A4.5** Either (a) `cp-3`'s disk cannot keep up — it is applying entries slower than the leader produces them, or (b) the network between `cp-3` and the leader is lossy or saturated so entries arrive slowly. Disk is by far the more common cause, and the metric that confirms it is `etcd_disk_wal_fsync_duration_seconds` (p99 should be well under 10 ms; also check `etcd_disk_backend_commit_duration_seconds`). Scrape it from `https://<node>:2381/metrics`. A permanently lagging member is a hidden availability loss: it counts toward quorum but may not be able to serve reads consistently, and if it is elected leader the whole cluster inherits its latency.

---

### Exercise 5

**A5.1** `/livez` answers "is this process functioning, or should the kubelet restart it?"; `/readyz` answers "should this instance receive traffic?". etcd being unreachable is not something restarting the API server fixes — the API server is behaving correctly, its dependency is gone. If `/livez` also failed, the kubelet's liveness probe would kill and restart the API server container in a crash loop for the entire duration of the etcd outage. That guarantees the API server is *also* unavailable the instant etcd returns (cold caches, restart backoff), turning a recoverable dependency outage into a compounded one. The split exists precisely so that dependency failures degrade readiness, not liveness.

**A5.2** Any three of: (1) **Scheduling** — new Pods stay `Pending` forever; a Deployment scale-up produces nothing. (2) **Controller reconciliation** — a crashed Pod is not recreated, a failed node's Pods are not evicted and rescheduled, Jobs do not progress, Deployments do not roll. (3) **Service/EndpointSlice updates** — a Pod that dies is never removed from its EndpointSlice, so `kube-proxy` keeps sending traffic to a dead backend and requests fail; conversely a newly healthy Pod never receives traffic. (4) **Every API write** — no `kubectl apply`, no CI deploy, no Secret/ConfigMap change, no cert rotation, no admission of new nodes. (5) **Lease renewal** — kubelets cannot renew their node leases, so once etcd returns the controller-manager may see nodes as `NotReady` and begin evicting. Existing Pods on existing nodes with existing iptables rules keep serving, which is why the outage is often invisible to end users until something needs to change.

**A5.3** `etcdctl member remove` is itself a Raft write (a configuration change entry) and requires quorum to commit — the very thing you do not have. It will hang and then fail with `context deadline exceeded` / `etcdserver: request timed out`. The actual escape hatch is to bring a dead member back (always try this first — the on-disk data is intact and rejoining is instantaneous), and if the data is genuinely lost, to rebuild the cluster from a snapshot as in Exercise 6, or restart the surviving member with `--force-new-cluster` to forcibly reduce it to a single-member cluster and then re-add peers. `--force-new-cluster` is a last resort: it discards the membership configuration and any uncommitted entries, and running it on the wrong member silently loses writes.

**A5.4** Each etcd member persists its WAL, snapshots and — critically — its membership configuration under `/var/lib/etcd/member`. Stopping the process left all of that intact, so on restart the member replayed its WAL, recognised its own ID and peer list, contacted the surviving members, and caught up on the entries it missed. No operator action is needed as long as the data directory survives *and* the missed entries have not been compacted away past the member's last index. It does **not** happen when the data directory is lost or corrupted (disk failure, VM re-provisioned, someone deleted `/var/lib/etcd`), or when the member has been down so long that the leader has compacted the log beyond its position — in both cases the member must be removed from membership and re-added as a fresh member (`etcdctl member remove` then `member add`, with an empty data dir and `--initial-cluster-state existing`).

**A5.5** `InternalError` is an HTTP 500 generated *by an API server* — which means TLS terminated, the request was routed to a live API server, and that server failed to service it internally. So the VIP, HAProxy and at least one API server process are all functioning; the failure is behind the API server, in etcd. Had the VIP failed over incorrectly (no node owning it, or two nodes claiming it), you would see a transport-layer error instead: `dial tcp 192.168.100.10:8443: connect: no route to host` / `connection refused` / `i/o timeout` — no HTTP status code at all. Reading the *shape* of the error tells you which layer to open first, before you run a single diagnostic.

---

### Exercise 6

**A6.1** `--initial-cluster-token` is mixed into the computation of the cluster ID and member IDs. Changing it guarantees the restored cluster is a distinct cluster from the original. The accident it prevents: if any member of the *old* cluster is still running (or is later restarted) and can reach the restored members, matching cluster IDs would let it attempt to join and replicate its divergent log into the new cluster — two independent write histories merging, which is unrecoverable data corruption. With a new token, the stale member is rejected with a cluster ID mismatch and the damage is contained to that one node.

**A6.2** `cp-2` and `cp-3` start with the *old* data directory, which contains the old cluster ID, old member IDs and a log that has diverged from the restored snapshot. They cannot join the restored cluster — they will log `request cluster ID mismatch` and refuse to communicate. Worse, they still have each other: two of the three original members are alive with intact membership for the *old* cluster, which is exactly quorum for it. You now have two clusters, both believing they are authoritative, and the API servers on `cp-2`/`cp-3` are happily serving pre-snapshot data while `cp-1` serves restored data — with the LB round-robining clients between them. That is split-brain: reads are non-deterministic, writes land in one universe or the other, and no backup will reconcile it. A clean outage is strictly better because it is *visible*. Restore is all-or-nothing across every member.

**A6.3** Any two of: (1) **Cloud/infra resources** — LoadBalancer Services, PersistentVolumes and their backing disks, cloud routes and node objects provisioned after the snapshot still exist at the provider but not in etcd. They become orphans nobody deletes and nobody pays attention to, and re-created objects may collide with them or provision duplicates. (2) **Running Pods on nodes** — kubelets are running containers for Pods that no longer exist in etcd. The kubelet reconciles against the API server and will eventually terminate them, causing a wave of unexpected shutdowns; conversely, Pods deleted after the snapshot reappear in etcd and get re-created. (3) **Bootstrap/serving certificates and node identity** — nodes that joined after the snapshot are unknown to the restored cluster and their CSRs no longer exist, so they show up as unauthorised or must re-join; rotated kubelet client certs approved after the snapshot are gone. (4) **External systems** — anything that read a resourceVersion or watched the API (GitOps controllers, admission webhooks with state, external secret stores) now sees revisions go *backwards*, which most clients do not expect and some handle by resyncing everything at once.

**A6.4** etcd holds the data directory open and continues writing to the WAL and boltdb file. Moving the directory out from under a running process on Linux does not stop those writes — the open file descriptors follow the inode to the new path — so you would get a snapshot-restore into a directory that etcd is simultaneously ignoring, and etcd would continue to serve stale in-memory state from the moved files. Worse, restarting it later can leave a half-written boltdb page. Moving the static Pod manifest out of `/etc/kubernetes/manifests` makes the kubelet tear the Pod down cleanly (a proper shutdown flushes and closes the backend), and confirming with `crictl ps` that the container is gone is what makes the subsequent directory move safe.

**A6.5** A follower can be behind the leader by whatever has not yet been replicated and applied — normally milliseconds, but arbitrarily long if that member is lagging (see A4.5). So a follower snapshot can be missing the most recent writes. For a Kubernetes restore this is almost always irrelevant: you are already accepting the loss of everything between the snapshot time and the disaster, which is minutes-to-hours, so a few hundred milliseconds of additional staleness changes nothing. What *does* matter is snapshotting from a member you know is healthy — a snapshot from a badly lagging member could be meaningfully old — so check `endpoint status --cluster` before trusting a scheduled backup, and alert on the `RAFT APPLIED INDEX` spread.

**A6.6** `etcdutl` operates purely on files on disk and requires no running etcd server; `etcdctl` is the client that talks to a live server over gRPC. Restore is fundamentally an offline, filesystem-level operation — it constructs a brand-new data directory from a snapshot file — so it belongs in `etcdutl`, and the `etcdctl snapshot restore` alias was deprecated in 3.5 to make that unambiguous. The practical implication follows directly: you cannot "restore into" a running cluster, there is no in-place rollback, and the endpoints/certificate flags you use with `etcdctl` are meaningless for restore. If you find yourself passing `--endpoints` to a restore command, you have misunderstood what the operation does.

---

### Exercise 7

**A7.1** `kubeadm upgrade apply` performs the cluster-wide, run-once actions: it verifies version skew and upgrade feasibility, upgrades the addons (`CoreDNS`, `kube-proxy` DaemonSet), updates the `kubeadm-config` ConfigMap in `kube-system` to record the new version, renews control plane certificates, and *then* upgrades that node's own static Pod manifests. `kubeadm upgrade node` does only the node-local part — rewrite this node's static Pod manifests and local kubelet config from the (already updated) cluster ConfigMap. Running `apply` again on `cp-2` would re-run the cluster-scoped addon and config upgrade steps against a cluster already at that version; the verb split makes the run-once work explicitly run-once.

**A7.2** On expiry, `cp-3`'s API server refuses to serve TLS with a valid certificate — external clients hitting it directly get `x509: certificate has expired or is not yet valid`, and its own control plane components fail to authenticate (`controller-manager.conf` and `scheduler.conf` client certs expire on the same schedule). HAProxy's `/readyz` check fails and pulls `cp-3` from the pool. Monitoring based on `kubectl get nodes` misses it entirely for two reasons: `kubectl` goes through the VIP and is served by a *healthy* node, and `cp-3`'s kubelet has its own independently rotating certificate (kubelet client certs auto-rotate via CSR by default), so the Node object keeps reporting `Ready` while its API server is dead. You have silently dropped from 3 API servers to 2 and from tolerating 1 failure to tolerating 0, with a green dashboard. Alert on `kubeadm certs check-expiration` per node, or on the `apiserver_client_certificate_expiration_seconds` / per-endpoint LB health metrics.

**A7.3** On `SIGTERM` the API server (1) immediately fails `/readyz` — specifically the `shutdown` check — while continuing to accept and serve new requests normally; (2) waits the full `shutdown-delay-duration` (20 s) in that state, so load balancers have time to observe the failing health check and stop sending new connections; (3) then stops accepting new requests, sends `GOAWAY` to HTTP/2 clients, and removes itself from the `kubernetes` EndpointSlice; (4) waits for in-flight requests to drain (bounded by `--request-timeout`), then exits. For the design to work, HAProxy must mark the backend `DOWN` within the 20-second window: with `inter 3s fall 3`, detection takes at most ~9 s plus check latency, comfortably inside 20 s. If `inter × fall` exceeded `shutdown-delay-duration`, the LB would still be routing new connections to a server that has stopped accepting them, producing connection errors during every planned restart.

**A7.4** etcd and the other control plane components run as **static Pods** — created directly by the kubelet from manifests in `/etc/kubernetes/manifests`, not by the API server. They are unmanaged mirror Pods from the API server's point of view, so `kubectl drain` refuses to evict them (it skips them the same way it skips DaemonSet Pods) and could not delete them meaningfully anyway: the kubelet would recreate them instantly from the on-disk manifest. To actually stop etcd on a node you move `/etc/kubernetes/manifests/etcd.yaml` aside (as in Exercise 6) or stop the kubelet. `kubectl drain` is the wrong tool because it operates through the API server on API-managed workloads, and static Pods are by design outside that control loop — that is precisely what lets the control plane bootstrap before an API server exists.

**A7.5** The version skew policy allows `kubelet` to be up to **three minor versions older** than `kube-apiserver`, but **never newer**. Upgrading workers first would put a newer kubelet under an older API server — an unsupported and untested combination where the kubelet may send API objects or use API versions the server does not understand. The same rule constrains the control plane internally: `kube-controller-manager` and `kube-scheduler` must not be newer than `kube-apiserver`, which is why `kubeadm upgrade apply` upgrades the API server on the first node before anything else, and why all API servers should reach the new version before the workers follow. For a patch-level bump (v1.33.2 → v1.33.3) the practical risk is small, but the order is the same discipline you must have for minor upgrades, and enforcing it always is cheaper than remembering when it matters. Reference: <https://kubernetes.io/releases/version-skew-policy/>

</details>