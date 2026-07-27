# Guided Exercises — 5.6 Understand and use CoreDNS

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with `kubectl` configured.

---

## Exercise 1 — Inspecting CoreDNS Deployments and Services

1. List CoreDNS Pods in `kube-system`:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   ```
2. Inspect the `kube-dns` Service:
   ```bash
   kubectl get svc kube-dns -n kube-system
   kubectl describe svc kube-dns -n kube-system
   ```

---

## Exercise 2 — Inspecting the Corefile ConfigMap

1. View the `coredns` ConfigMap:
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```
2. Inspect plugin definitions: `kubernetes`, `forward`, `cache`, `loop`, `reload`.

---

## Exercise 3 — Pod DNS Resolution

1. Create test namespace and workload:
   ```bash
   kubectl create namespace dns-lab
   kubectl create deployment web --image=nginx -n dns-lab
   kubectl expose deployment web --port=80 -n dns-lab
   ```
2. Run test utility Pod:
   ```bash
   kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 \
     -n dns-lab --command -- sleep 3600
   ```
3. Test resolution using short and FQDN names:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- nslookup web
   kubectl exec -it dnsutils -n dns-lab -- nslookup web.dns-lab.svc.cluster.local
   ```
4. View container `/etc/resolv.conf`:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- cat /etc/resolv.conf
   ```

---

## Exercise 4 — Custom dnsPolicy and dnsConfig

1. Manifest Pod with explicit `dnsPolicy: None` and `dnsConfig`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dns-custom-config
     namespace: dns-lab
   spec:
     dnsPolicy: None
     dnsConfig:
       nameservers:
         - 8.8.8.8
       searches:
         - dns-lab.svc.cluster.local
       options:
         - name: ndots
           value: "2"
     containers:
       - name: shell
         image: busybox
         command: ["sleep", "3600"]
   ```

---

<details>
<summary>View Answers</summary>

1. Service retains `kube-dns` as its name for backwards compatibility with `kubelet` `--cluster-dns` flags.
2. The `kubernetes` plugin resolves `*.svc.cluster.local` names against the API server.
3. `ndots:5` specifies the dot count threshold triggering search domain suffix iteration prior to absolute FQDN checks.

</details>
