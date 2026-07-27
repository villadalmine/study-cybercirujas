# Guided Exercises — 5.1 Understand connectivity between Pods

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working Kubernetes cluster with `kubectl` configured.

```bash
kubectl create namespace net-lab
kubectl config set-context --current --namespace=net-lab
```

---

## Exercise 1: Flat Network Model Operations

1. Deploy two Pods:

```bash
kubectl run pod-a --image=nicolaka/netshoot --command -- sleep infinity
kubectl run pod-b --image=nicolaka/netshoot --command -- sleep infinity
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b
```

2. Retrieve assigned Pod IP addresses:

```bash
kubectl get pods -o wide
```

3. Test direct IP connectivity from `pod-a` to `pod-b`:

```bash
POD_B_IP=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
kubectl exec pod-a -- ping -c 3 "$POD_B_IP"
```

4. Test connectivity in reverse (`pod-b` to `pod-a`):

```bash
POD_A_IP=$(kubectl get pod pod-a -o jsonpath='{.status.podIP}')
kubectl exec pod-b -- ping -c 3 "$POD_A_IP"
```

5. Verify internal network interface IP assignments inside `pod-a`:

```bash
kubectl exec pod-a -- ip addr show eth0
```

### Questions

1. Why does `ping` succeed bi-directionally without configuring Services or NAT rules?
2. Does internal `eth0` IP reporting match external `kubectl get pods -o wide` outputs?

---

## Exercise 2: Shared Pod Network Namespaces

1. Manifest a multi-container Pod:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-multicontainer
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
  - name: shell
    image: nicolaka/netshoot
    command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready pod/pod-multicontainer
```

2. Query container `web` from container `shell` targeting `localhost`:

```bash
kubectl exec pod-multicontainer -c shell -- curl -s -o /dev/null -w "%{http_code}\n" http://localhost:80
```

3. Verify shared interface and IP assignments:

```bash
kubectl exec pod-multicontainer -c web   -- hostname -i
kubectl exec pod-multicontainer -c shell -- hostname -i
```

### Questions

3. Why does `curl http://localhost:80` inside container `shell` connect to container `web` processes?
4. Can two containers inside the same Pod bind to identical listening ports?

---

## Exercise 3: Cross-Node Pod Connectivity

1. Inspect cluster nodes:

```bash
kubectl get nodes -o wide
```

2. Force scheduling across distinct host nodes:

```bash
NODE1=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
NODE2=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[1].metadata.name}')

kubectl run pod-node1 --image=nicolaka/netshoot --overrides="{\"spec\":{\"nodeName\":\"$NODE1\"}}" --command -- sleep infinity
kubectl run pod-node2 --image=nicolaka/netshoot --overrides="{\"spec\":{\"nodeName\":\"$NODE2\"}}" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/pod-node1 pod/pod-node2
```

3. Confirm node assignments:

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

4. Test cross-node ping:

```bash
IP_NODE2=$(kubectl get pod pod-node2 -o jsonpath='{.status.podIP}')
kubectl exec pod-node1 -- ping -c 3 "$IP_NODE2"
```

### Questions

5. Which component routes cross-node Pod-to-Pod traffic across host boundaries?

---

## Exercise 4: Network Namespace Inspection

1. Inspect container routing tables:

```bash
kubectl exec pod-node1 -- ip route
```

2. Inspect container network interface MTU values:

```bash
kubectl exec pod-node1 -- ip link show eth0 | grep -o 'mtu [0-9]*'
```

### Questions

6. What relationship links container `eth0` interfaces to host `veth*` interfaces?

---

<details>
<summary>View Answers</summary>

1. Kubernetes enforces flat IP-per-Pod networking without NAT across cluster boundaries.
2. Yes. Pod IPs match across control plane queries and internal interface checks.
3. Containers inside the same Pod share a single network namespace (and `localhost` interface).
4. No. Binding identical ports inside shared network namespaces causes address collision errors.
5. Installed CNI drivers manage cross-node Pod routing via overlay networks or native BGP routes.
6. Container `eth0` interfaces bind to host-side `veth*` virtual ethernet pairs attached to local host bridges.

</details>
