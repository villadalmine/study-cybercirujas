# KCNA · Topic 3.4 — Networking

> Reference Source: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)
> Exam Weight: 4

Prerequisite: a working local Kubernetes cluster (`kind` or `minikube`) and `kubectl` configured against it. All commands are executed from the terminal.

---

## Exercise 1 — The Kubernetes networking model (pod-to-pod)

Kubernetes requires that every Pod can communicate with any other Pod in the cluster without NAT, using its own IP. Let's verify this directly.

1. Create two simple Pods:
   ```bash
   kubectl run pod-a --image=nginx --restart=Never
   kubectl run pod-b --image=busybox --restart=Never -- sleep 3600
   ```
2. Wait until both are `Running`:
   ```bash
   kubectl get pods -o wide
   ```
3. Note the IP of `pod-a` (column `IP`).
4. From `pod-b`, make a direct HTTP request to `pod-a`'s IP:
   ```bash
   kubectl exec pod-b -- wget -qO- <IP-of-pod-a>
   ```
5. You should see the nginx welcome HTML, confirming direct connectivity between Pods without going through any Service.

**Review questions:**
- Why does this work without us having configured any manual NAT rules?
- Which cluster component is responsible for assigning an IP to each Pod?

---

## Exercise 2 — Service type `ClusterIP` and internal DNS (CoreDNS)

Pod IPs are ephemeral (they change if the Pod is recreated). A `Service` provides a stable identity; CoreDNS gives it a resolvable name.

1. Create a Deployment with 2 replicas:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   ```
2. Expose it as a `ClusterIP` Service:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80
   ```
3. Verify the Service and its assigned ClusterIP:
   ```bash
   kubectl get svc web
   ```
4. From `pod-b` (created in the previous exercise), resolve the DNS name of the Service:
   ```bash
   kubectl exec pod-b -- nslookup web.default.svc.cluster.local
   ```
5. Make a request using the short name (within the same namespace the full FQDN is not required):
   ```bash
   kubectl exec pod-b -- wget -qO- web
   ```

**Review questions:**
- If you delete one of the two Pods from the Deployment and Kubernetes recreates it with a new IP, does the Service stop working? Why?
- What DNS name pattern does CoreDNS use for a Service (`<service>.<namespace>.svc.cluster.local`)?

---

## Exercise 3 — `NodePort` vs `LoadBalancer`

1. Change the `web` Service type to `NodePort`:
   ```bash
   kubectl patch svc web -p '{"spec":{"type":"NodePort"}}'
   ```
2. Check the port assigned on the node:
   ```bash
   kubectl get svc web
   ```
   (look for the second number in the `PORT(S)` column, format `80:3XXXX/TCP`)
3. Get the IP of a cluster node:
   ```bash
   kubectl get nodes -o wide
   ```
4. Access the Service using `<Node-IP>:<NodePort>` (with `minikube`, you can use `minikube service web --url` instead).
5. Change the type to `LoadBalancer`:
   ```bash
   kubectl patch svc web -p '{"spec":{"type":"LoadBalancer"}}'
   kubectl get svc web
   ```
   Note that `EXTERNAL-IP` remains `<pending>` if the cluster does not have a cloud controller that provisions a real load balancer.

**Review questions:**
- What is the hierarchical relationship between `ClusterIP`, `NodePort`, and `LoadBalancer` (each includes the previous)?
- Why does `EXTERNAL-IP` remain pending in a local cluster like `kind` or `minikube` without additional addons?

---

## Exercise 4 — Ingress

An Ingress allows exposing multiple HTTP/HTTPS Services under a single IP, routing by hostname or path. It requires an Ingress Controller running (e.g., nginx).

1. Install the nginx Ingress Controller (example with `minikube`):
   ```bash
   minikube addons enable ingress
   ```
2. Confirm the controller is running:
   ```bash
   kubectl get pods -n ingress-nginx
   ```
3. Create an Ingress resource that routes `web.local` to the `web` Service:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
   spec:
     ingressClassName: nginx
     rules:
     - host: web.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: web
               port:
                 number: 80
   EOF
   ```
4. Add `web.local` pointing to the Ingress Controller's IP in your local `/etc/hosts`.
5. Test access:
   ```bash
   curl http://web.local
   ```

**Review questions:**
- What is the difference between the `Ingress` resource and the `Ingress Controller`?
- Why does an Ingress operate at layer 7 (HTTP/HTTPS) and does not replace a layer 4 Service?

---

## Exercise 5 — NetworkPolicy

By default, in Kubernetes every Pod can talk to every Pod. A `NetworkPolicy` restricts that traffic (requires a CNI plugin that supports it, like Calico).

1. Verify that you can reach the `web` Service from `pod-b` (it should work, as in Exercise 2):
   ```bash
   kubectl exec pod-b -- wget -qO- --timeout=2 web
   ```
2. Apply a "default deny" policy for ingress to Pods with label `app=web`:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-all-web
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
   EOF
   ```
3. Retry the same `wget` from `pod-b`: it should now fail with a timeout.
4. Add a policy that explicitly allows traffic only from Pods with label `access=allowed`:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-from-labeled
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             access: allowed
   EOF
   ```
5. Label `pod-b` and test again:
   ```bash
   kubectl label pod pod-b access=allowed
   kubectl exec pod-b -- wget -qO- --timeout=2 web
   ```

**Review questions:**
- If no CNI plugin in the cluster implements `NetworkPolicy` (e.g., the basic `bridge` CNI), what happens when you apply the YAML from step 2?
- Why is the NetworkPolicy model "additive" (rules from different policies that apply to the same Pod are combined) rather than evaluated in order?

---

## Exercise 6 — Identify the cluster's CNI plugin

The Container Network Interface (CNI) is the specification implemented by plugins (Calico, Cilium, Flannel, etc.) to assign IPs and connect Pods to the network.

1. List the Pods in the `kube-system` namespace and look for the networking component:
   ```bash
   kubectl get pods -n kube-system
   ```
2. Identify which one corresponds to the CNI plugin (by name: `kindnet`, `calico-node`, `weave-net`, `cilium`, etc.).
3. Inspect its configuration on the node (if you have SSH/exec access to the node):
   ```bash
   kubectl exec -n kube-system <cni-pod> -- ls /etc/cni/net.d/
   ```

**Review questions:**
- Is the CNI plugin the same component that implements `kube-proxy`, or are they different responsibilities?
- Why does Kubernetes delegate networking to plugins instead of having a single embedded implementation?

---

<details>
<summary>View answers</summary>

**Exercise 1**
- It works because the Kubernetes networking model requires (as a design requirement, not a feature of a specific plugin) that all Pods share a flat IP space, routable without NAT between them. This guarantee is implemented by the CNI plugin installed in the cluster, not by `kube-proxy`.
- The responsible component is the **CNI plugin** (invoked by the kubelet when creating the Pod), which assigns an IP and connects its network interface to the rest of the cluster.

**Exercise 2**
- It does not stop working: the Service maintains a stable virtual IP (`ClusterIP`) and an `Endpoints`/`EndpointSlice` that automatically updates with the current IPs of Pods matching its selector. The client always resolves to the Service, never directly to the Pod's IP.
- The pattern is `<service>.<namespace>.svc.cluster.local`. Within the same namespace, `<service>` is sufficient thanks to the `search domain` configured in each Pod's `/etc/resolv.conf`.

**Exercise 3**
- It is hierarchical: `NodePort` automatically includes a `ClusterIP` (still exists, accessible internally) and also opens a fixed port on each node in the cluster. `LoadBalancer` in turn includes a `NodePort` and asks the cloud provider to provision an external load balancer pointing to those node ports.
- It remains `<pending>` because provisioning a real load balancer requires a **cloud controller manager** integrated with a provider (AWS, GCP, Azure, etc.) or an addon like MetalLB; a local cluster without that integration has nothing to satisfy the request.

**Exercise 4**
- The `Ingress` resource is just a declarative configuration object (routing rules). The **Ingress Controller** is the software (e.g., nginx, Traefik, HAProxy) that actually reads those resources and programs a proxy/load balancer to fulfill them. Without a running controller, an Ingress does nothing.
- It operates at layer 7 because it routes based on HTTP information (host header, path), something a Service (layer 4, based on IP:port) cannot interpret. That is why Ingress is used to consolidate multiple HTTP services behind a single IP/domain instead of creating a `LoadBalancer` per Service.

**Exercise 5**
- With a CNI plugin that does not implement `NetworkPolicy` (the `apiserver` still accepts and stores it because it is just an API object), the YAML is applied without error, but it has **no real effect**: traffic continues to flow unrestricted because no one enforces the rule at the network level.
- It is additive because the model is designed so that multiple teams/policies can coexist safely: each policy can only *allow* additional traffic, never *remove* a permission granted by another policy. This prevents a poorly written policy from accidentally blocking something that another policy authorized.

**Exercise 6**
- They are different responsibilities. The **CNI plugin** assigns IPs to Pods and provides L3 connectivity between them (and optionally enforces NetworkPolicies). **`kube-proxy`** is a separate component that implements traffic routing to Services (via `iptables`, `IPVS`, or eBPF rules), translating the virtual Service IP to a real backend Pod IP.
- Because different environments (on-prem, each cloud provider, different performance or security requirements) need very different network implementations. Defining CNI as a decoupled specification allows Kubernetes to be agnostic to the underlying network infrastructure and lets the ecosystem (Calico, Cilium, Flannel, etc.) compete and innovate freely on that common interface.

</details>