# Guided Exercises — 2.5 Configuring Pod Endpoint Availability

These exercises cover how a Pod's health becomes Service reachability. The chain is: container probes → Pod `Ready` condition → EndpointSlice `conditions` → kube-proxy / DNS / load balancers. You will adjust each link and watch the effect on the next one.

**Official references used throughout:**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Liveness, readiness and startup probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Pod lifecycle (conditions, readiness gates, termination): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- EndpointSlices and endpoint conditions: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Pod and endpoint termination flow: https://kubernetes.io/docs/tutorials/services/pods-and-endpoint-termination-flow/
- Service API reference (`publishNotReadyAddresses`): https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/
- Container lifecycle hooks: https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Deployments (rolling update, `minReadySeconds`, progress deadline): https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Disruptions and PodDisruptionBudgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/ and https://kubernetes.io/docs/tasks/run-application/configure-pdb/

---

## Exercise 0 — Lab setup

**Requirements:** a disposable cluster running Kubernetes v1.31 or later (`kind`, `minikube` or `k3d` all work), `kubectl` at the same minor version, and permission to patch `pods/status`. On a kind cluster, the default admin kubeconfig already has that permission.

1. Create the cluster (skip this if you already have one):

   ```bash
   kind create cluster --name ckne-avail
   kubectl version
   ```

2. Create a namespace for the lab, make it your default, and start a long-lived client Pod:

   ```bash
   kubectl create namespace avail
   kubectl config set-context --current --namespace=avail
   kubectl run client --image=busybox:1.36 --restart=Never -- sleep 36000
   kubectl wait --for=condition=Ready pod/client --timeout=60s
   ```

3. Define two helper functions for this shell session. `eps` prints each endpoint of a Service with its conditions. `hits` sends 30 requests through the Service's ClusterIP and counts which Pod answered each one:

   ```bash
   eps() {
     kubectl get endpointslices -l kubernetes.io/service-name="$1" \
       -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"\t"}{.addresses[0]}{"\t"}{.conditions}{"\n"}{end}'
   }

   hits() {
     kubectl exec client -- sh -c \
       "for i in \$(seq 1 30); do wget -qO- -T 2 http://$1 2>/dev/null || echo FAIL; done" \
       | sort | uniq -c
   }
   ```

**Questions**

- **Q0.1** — `eps` filters on the label `kubernetes.io/service-name` instead of fetching an object named after the Service. Why?
- **Q0.2** — Why does this lab read EndpointSlices and not the `v1/Endpoints` object?

---

## Exercise 1 — Readiness decides who receives traffic

1. Save this as `web.yaml`. The container writes its own hostname into `index.html`, so each response shows which Pod answered. The readiness probe requests `/ready`, a file that does not exist yet, so nginx answers `404`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: avail
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             command:
               - sh
               - -c
               - |
                 echo "$HOSTNAME" > /usr/share/nginx/html/index.html
                 exec nginx -g 'daemon off;'
             ports:
               - name: http
                 containerPort: 80
             readinessProbe:
               httpGet:
                 path: /ready
                 port: http
               periodSeconds: 2
               failureThreshold: 1
               successThreshold: 1
             livenessProbe:
               httpGet:
                 path: /
                 port: http
               periodSeconds: 5
               failureThreshold: 3
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: avail
   spec:
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

2. Apply it, then look at the Pods, the endpoints and the traffic:

   ```bash
   kubectl apply -f web.yaml
   kubectl rollout status deployment/web --timeout=20s   # this is expected to time out
   kubectl get pods -l app=web
   eps web
   hits web
   ```

   Expected output (Pod names and IPs will differ):

   ```
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6d9c7b5f8d-2kq8n   0/1     Running   0          25s
   web-6d9c7b5f8d-7xwzp   0/1     Running   0          25s
   web-6d9c7b5f8d-lm4tr   0/1     Running   0          25s

   web-6d9c7b5f8d-2kq8n   10.244.0.7   {"ready":false,"serving":false,"terminating":false}
   web-6d9c7b5f8d-7xwzp   10.244.0.8   {"ready":false,"serving":false,"terminating":false}
   web-6d9c7b5f8d-lm4tr   10.244.0.9   {"ready":false,"serving":false,"terminating":false}

        30 FAIL
   ```

3. Make exactly one Pod ready, wait a few seconds, then check again:

   ```bash
   P1=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$P1" -- touch /usr/share/nginx/html/ready
   sleep 4
   eps web
   hits web
   ```

   Expected: only `$P1` shows `"ready":true`, and it answers all 30 requests.

4. Make the other two Pods ready too:

   ```bash
   for p in $(kubectl get pods -l app=web -o name); do
     kubectl exec "$p" -- touch /usr/share/nginx/html/ready
   done
   sleep 4
   hits web
   ```

   Expected: roughly 10 responses from each Pod. The split will not be exactly even.

**Questions**

- **Q1.1** — In step 2, all three Pods have an IP address and are `Running`. Why does every request fail?
- **Q1.2** — The not-ready Pods still appear in the EndpointSlice. Who might care about endpoints that are not ready?
- **Q1.3** — With `periodSeconds: 2` and `failureThreshold: 1`, what is the longest a broken Pod can keep receiving new connections before it is removed? What else adds to that delay?

---

## Exercise 2 — Readiness is not liveness

1. Take one Pod out of rotation without killing it:

   ```bash
   P1=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$P1" -- rm /usr/share/nginx/html/ready
   sleep 4
   kubectl get pod "$P1"
   kubectl get pod "$P1" -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   hits web
   ```

   Expected: `READY 0/1`, `RESTARTS 0`, the `Ready` and `ContainersReady` conditions are `False`, and `$P1` no longer appears in `hits`.

2. Now deploy the anti-pattern: a liveness probe that points at the readiness endpoint. Save it as `web-bad.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web-bad
     namespace: avail
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: web-bad
     template:
       metadata:
         labels:
           app: web-bad
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - name: http
                 containerPort: 80
             readinessProbe:
               httpGet:
                 path: /ready
                 port: http
               periodSeconds: 2
             livenessProbe:
               httpGet:
                 path: /ready
                 port: http
               periodSeconds: 3
               failureThreshold: 2
   ```

   ```bash
   kubectl apply -f web-bad.yaml
   sleep 45
   kubectl get pods -l app=web-bad
   kubectl get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -n 4
   ```

   Expected: `RESTARTS` keeps increasing, and the events show `Liveness probe failed: HTTP probe failed with statuscode: 404`.

3. Try to rescue it by creating the file, then watch:

   ```bash
   PB=$(kubectl get pods -l app=web-bad -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$PB" -- touch /usr/share/nginx/html/ready
   kubectl get pod "$PB" -w     # press Ctrl-C after about 30 s
   ```

4. Restore `$P1` and remove the broken Deployment:

   ```bash
   kubectl exec "$P1" -- touch /usr/share/nginx/html/ready
   kubectl delete -f web-bad.yaml
   ```

**Questions**

- **Q2.1** — In step 1 the Pod stopped receiving traffic, but the kubelet did nothing to it. Which component acted on the failed readiness probe, and what did it do?
- **Q2.2** — In step 3, the Pod may become ready briefly but loses the file again on the next restart. Why?
- **Q2.3** — Give a real production failure that should fail readiness but *not* liveness, and one that should fail liveness.

---

## Exercise 3 — Startup probes protect slow starts

1. Create a Pod that takes 30 s to start listening. Its liveness probe has no grace period. Save it as `slow.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: slow
     namespace: avail
     labels:
       app: slow
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
         command:
           - sh
           - -c
           - |
             sleep 30
             exec nginx -g 'daemon off;'
         ports:
           - name: http
             containerPort: 80
         livenessProbe:
           httpGet:
             path: /
             port: http
           periodSeconds: 5
           failureThreshold: 2
   ```

   ```bash
   kubectl apply -f slow.yaml
   sleep 90
   kubectl get pod slow
   ```

   Expected: `RESTARTS` is above 0. The status may be `CrashLoopBackOff`, and the Pod never reaches `1/1`.

2. Replace the Pod with one that has a startup probe. Most Pod spec fields, probes included, cannot be changed on a running Pod, so delete it and create it again. Save as `slow-fixed.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: slow
     namespace: avail
     labels:
       app: slow
   spec:
     containers:
       - name: nginx
         image: nginx:1.27
         command:
           - sh
           - -c
           - |
             sleep 30
             exec nginx -g 'daemon off;'
         ports:
           - name: http
             containerPort: 80
         startupProbe:
           httpGet:
             path: /
             port: http
           periodSeconds: 5
           failureThreshold: 12
         readinessProbe:
           httpGet:
             path: /
             port: http
           periodSeconds: 2
         livenessProbe:
           httpGet:
             path: /
             port: http
           periodSeconds: 5
           failureThreshold: 2
   ```

   ```bash
   kubectl delete pod slow
   kubectl apply -f slow-fixed.yaml
   kubectl get pod slow -w      # press Ctrl-C once it shows 1/1
   ```

   Expected: the Pod stays `0/1 Running` with `RESTARTS 0` for about 30–35 s, then shows `1/1`.

**Questions**

- **Q3.1** — How long is the startup budget in `slow-fixed.yaml`, and what happens when it runs out?
- **Q3.2** — Why is a startup probe better than just adding `initialDelaySeconds: 40` to the liveness probe?
- **Q3.3** — While the startup probe has not yet succeeded, do the readiness and liveness probes run? What does the EndpointSlice report for this Pod during that time?

---

## Exercise 4 — Termination: `ready`, `serving` and `terminating`

1. Deploy a workload that shuts down slowly. The `preStop` hook keeps nginx running for 20 s after the Pod is deleted. Save as `web-term.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web-term
     namespace: avail
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: web-term
     template:
       metadata:
         labels:
           app: web-term
       spec:
         terminationGracePeriodSeconds: 40
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - name: http
                 containerPort: 80
             readinessProbe:
               httpGet:
                 path: /
                 port: http
               periodSeconds: 2
             lifecycle:
               preStop:
                 exec:
                   command:
                     - sleep
                     - "20"
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web-term
     namespace: avail
   spec:
     selector:
       app: web-term
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f web-term.yaml
   kubectl rollout status deployment/web-term
   eps web-term
   ```

2. Delete one Pod without waiting for it to finish, then check the endpoints right away:

   ```bash
   VICTIM=$(kubectl get pods -l app=web-term -o jsonpath='{.items[0].metadata.name}')
   kubectl delete pod "$VICTIM" --wait=false
   sleep 2
   eps web-term
   kubectl get endpoints web-term -o jsonpath='{.subsets[*].addresses[*].targetRef.name}{"\n"}'
   ```

   Expected (the replacement Pod may appear as a third line, not ready yet):

   ```
   web-term-5f7c9d8b6-abcde   10.244.0.20   {"ready":false,"serving":true,"terminating":true}
   web-term-5f7c9d8b6-fghij   10.244.0.21   {"ready":true,"serving":true,"terminating":false}
   ```

   The legacy `Endpoints` object no longer lists `$VICTIM` at all. On v1.33+ it also prints a deprecation warning.

3. Watch the terminating endpoint until it disappears:

   ```bash
   for i in $(seq 1 12); do date +%T; eps web-term; echo; sleep 3; done
   ```

**Questions**

- **Q4.1** — Explain what each of the three conditions means for `$VICTIM` in step 2.
- **Q4.2** — Why is the `preStop` sleep useful if the endpoint is marked not ready as soon as the Pod is deleted?
- **Q4.3** — kube-proxy normally ignores endpoints with `ready: false`. When will it send traffic to an endpoint that is `serving: true, terminating: true`?
- **Q4.4** — What happens if `preStop` sleeps for 60 s but `terminationGracePeriodSeconds` is 40?

---

## Exercise 5 — `publishNotReadyAddresses` on headless Services

1. Create two headless Services for the same `web` Pods. They differ only in `publishNotReadyAddresses`. Save as `web-headless.yaml`:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web-headless
     namespace: avail
   spec:
     clusterIP: None
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web-peers
     namespace: avail
   spec:
     clusterIP: None
     publishNotReadyAddresses: true
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f web-headless.yaml
   ```

2. Take one `web` Pod out of rotation, then compare the endpoints and DNS answers:

   ```bash
   P1=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$P1" -- rm /usr/share/nginx/html/ready
   sleep 5
   eps web-headless
   eps web-peers
   kubectl exec client -- nslookup web-headless.avail.svc.cluster.local
   kubectl exec client -- nslookup web-peers.avail.svc.cluster.local
   ```

   Expected: `web-headless` returns 2 A records, and `$P1` shows `"ready":false`. `web-peers` returns 3 A records, and `$P1` shows `"ready":true,"serving":false`.

3. Restore the Pod:

   ```bash
   kubectl exec "$P1" -- touch /usr/share/nginx/html/ready
   ```

**Questions**

- **Q5.1** — For `web-peers`, the endpoint of a Pod that is *not* ready reports `ready: true`. How does the EndpointSlice controller compute `ready`, and which condition still tells the truth?
- **Q5.2** — Name a workload that needs `publishNotReadyAddresses: true`, and explain why.
- **Q5.3** — Why is it risky to set this field on a regular ClusterIP Service that clients use?

---

## Exercise 6 — Pod readiness gates

1. Create a Pod whose readiness also depends on an external condition. In production, a load-balancer controller would set that condition. Save as `gated.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: gated
     namespace: avail
     labels:
       app: gated
   spec:
     readinessGates:
       - conditionType: example.com/lb-registered
     containers:
       - name: nginx
         image: nginx:1.27
         ports:
           - name: http
             containerPort: 80
         readinessProbe:
           httpGet:
             path: /
             port: http
           periodSeconds: 2
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: gated
     namespace: avail
   spec:
     selector:
       app: gated
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f gated.yaml
   sleep 10
   kubectl get pod gated -o wide
   kubectl get pod gated -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   eps gated
   ```

   Expected: `READY 1/1`, but `READINESS GATES 0/1`. `ContainersReady=True`, `Ready=False`, and the endpoint shows `"ready":false`.

2. Play the controller's role and set the condition through the `status` subresource:

   ```bash
   kubectl patch pod gated --subresource=status \
     -p '{"status":{"conditions":[{"type":"example.com/lb-registered","status":"True"}]}}'
   sleep 3
   kubectl get pod gated -o wide
   eps gated
   ```

   Expected: `READINESS GATES 1/1` and the endpoint shows `"ready":true`.

3. Withdraw it again:

   ```bash
   kubectl patch pod gated --subresource=status \
     -p '{"status":{"conditions":[{"type":"example.com/lb-registered","status":"False"}]}}'
   sleep 3
   eps gated
   ```

**Questions**

- **Q6.1** — `kubectl get pod` shows `1/1` but the Pod is not in the Service. Which rule decides the Pod's `Ready` condition when readiness gates exist?
- **Q6.2** — What real problem do readiness gates solve during a rolling update behind a cloud load balancer that targets Pod IPs directly?
- **Q6.3** — Why does the patch need `--subresource=status`, and what RBAC does a controller need to do this?

---

## Exercise 7 — Rollouts that keep capacity

1. Save as `roll.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: roll
     namespace: avail
   spec:
     replicas: 4
     minReadySeconds: 5
     progressDeadlineSeconds: 60
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxSurge: 1
         maxUnavailable: 0
     selector:
       matchLabels:
         app: roll
     template:
       metadata:
         labels:
           app: roll
       spec:
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - name: http
                 containerPort: 80
             readinessProbe:
               httpGet:
                 path: /
                 port: http
               periodSeconds: 2
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: roll
     namespace: avail
   spec:
     selector:
       app: roll
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f roll.yaml
   kubectl rollout status deployment/roll
   ```

2. Ship a broken release, with a readiness probe that can never pass:

   ```bash
   kubectl patch deployment roll --type=json -p \
     '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/does-not-exist"}]'
   kubectl rollout status deployment/roll --timeout=90s
   ```

   Expected: the command ends with `error: deployment "roll" exceeded its progress deadline`.

3. Check the damage:

   ```bash
   kubectl get pods -l app=roll
   kubectl get deploy roll -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}{"\n"}'
   eps roll | grep -c '"ready":true'
   ```

   Expected: 4 old Pods at `1/1` and 1 new Pod at `0/1`. The reason is `ProgressDeadlineExceeded`, and there are 4 ready endpoints.

4. Roll back:

   ```bash
   kubectl rollout undo deployment/roll
   kubectl rollout status deployment/roll
   ```

**Questions**

- **Q7.1** — Why did users see no loss of capacity during the broken rollout? What would change with `maxUnavailable: 1`?
- **Q7.2** — What does `minReadySeconds: 5` add on top of the readiness probe?
- **Q7.3** — Does reaching `progressDeadlineSeconds` roll the Deployment back automatically?

---

## Exercise 8 — PodDisruptionBudgets count *ready* Pods

1. Make sure all three `web` Pods are ready, then create a PDB. Save as `web-pdb.yaml`:

   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: web
     namespace: avail
   spec:
     minAvailable: 2
     selector:
       matchLabels:
         app: web
     unhealthyPodEvictionPolicy: IfHealthyBudget
   ```

   ```bash
   for p in $(kubectl get pods -l app=web -o name); do
     kubectl exec "$p" -- touch /usr/share/nginx/html/ready
   done
   kubectl apply -f web-pdb.yaml
   sleep 3
   kubectl get pdb web
   ```

   Expected:

   ```
   NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
   web    2               N/A               1                     5s
   ```

2. Define an eviction helper. It calls the Eviction API, the same one `kubectl drain` uses:

   ```bash
   evict() {
     kubectl create --raw "/api/v1/namespaces/avail/pods/$1/eviction" -f - <<EOF
   {"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$1","namespace":"avail"}}
   EOF
   }
   ```

3. Evict one ready Pod. Its replacement starts *not ready*, because `/ready` does not exist in a new container:

   ```bash
   READY1=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
   evict "$READY1"
   sleep 8
   kubectl get pods -l app=web
   kubectl get pdb web -o jsonpath='healthy={.status.currentHealthy} desired={.status.desiredHealthy} allowed={.status.disruptionsAllowed}{"\n"}'
   ```

   Expected: `healthy=2 desired=2 allowed=0`.

4. Try to evict another ready Pod, then the not-ready replacement:

   ```bash
   READY2=$(kubectl get pods -l app=web -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{"\n"}{end}' | head -n1)
   UNREADY=$(kubectl get pods -l app=web -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\n"}{end}' | head -n1)
   evict "$READY2"
   evict "$UNREADY"
   ```

   Expected: the first call fails with `Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.` The second call succeeds.

5. Push the application below its budget. Take a ready Pod out of rotation, so there are 2 unready Pods and 1 healthy Pod, then try to evict an unready Pod:

   ```bash
   sleep 8
   READY2=$(kubectl get pods -l app=web -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{"\n"}{end}' | head -n1)
   kubectl exec "$READY2" -- rm /usr/share/nginx/html/ready
   sleep 4
   kubectl get pdb web -o jsonpath='healthy={.status.currentHealthy} desired={.status.desiredHealthy}{"\n"}'
   UNREADY=$(kubectl get pods -l app=web -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\n"}{end}' | head -n1)
   evict "$UNREADY"
   ```

   Expected: `healthy=1 desired=2`, and the eviction fails with `TooManyRequests`.

6. Change the policy and try again:

   ```bash
   kubectl patch pdb web --type=merge -p '{"spec":{"unhealthyPodEvictionPolicy":"AlwaysAllow"}}'
   evict "$UNREADY"
   ```

   Expected: the eviction succeeds.

**Questions**

- **Q8.1** — Why did `allowed` drop to 0 in step 3 even though the Deployment still had 3 Pods?
- **Q8.2** — In step 4, why was the not-ready Pod evictable under `IfHealthyBudget` while the ready one was not?
- **Q8.3** — In step 5, `IfHealthyBudget` blocked evicting a Pod that served no traffic anyway. What operational problem does that cause, and why is `AlwaysAllow` usually recommended?
- **Q8.4** — Does a PDB protect against `kubectl delete pod` or a node that loses power?

---

## Cleanup

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace avail
kind delete cluster --name ckne-avail   # only if you created it for this lab
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**Q0.1** — A Service can have several EndpointSlices, which the controller splits at 100 endpoints each by default, plus separate slices per address family. Their names are generated, like `web-x7k2p`. What links a slice to its Service is the `kubernetes.io/service-name` label, so selecting by label returns all of them.

**Q0.2** — `v1/Endpoints` is deprecated since v1.33. It only has `addresses` and `notReadyAddresses`, and it drops terminating Pods entirely, so it cannot represent `serving` or `terminating`. kube-proxy and modern controllers read EndpointSlices.

### Exercise 1

**Q1.1** — A Pod is in rotation only when its `Ready` condition is `True`. Until the readiness probe succeeds, the EndpointSlice controller writes `ready: false`, and kube-proxy programs no backends for the ClusterIP. A Service with no ready endpoints rejects the connection (typically `REJECT` in iptables/nftables mode), so `wget` fails.

**Q1.2** — Components that need to know a Pod exists before it serves: controllers doing their own health or draining logic, service meshes, and peer-discovery systems. It also lets kube-proxy fall back to `serving` + `terminating` endpoints (Exercise 4). Keeping every endpoint in the slice with explicit conditions carries more information than the old ready/not-ready split.

**Q1.3** — The probe itself fails at most `periodSeconds × failureThreshold` = about 2 s after the failure, plus the probe `timeoutSeconds` (default 1 s). After that, the kubelet updates the Pod status, the EndpointSlice controller rewrites the slice, and every node's kube-proxy (or external load-balancer controller) observes the change and reprograms its rules. Existing connections are **not** cut by this. Only new connections stop going to the Pod.

### Exercise 2

**Q2.1** — The kubelet only sets `Ready=False` on the Pod status. It never restarts a container for failed readiness. The EndpointSlice controller in kube-controller-manager sees the change and marks the endpoint `ready: false`. kube-proxy then removes the backend. The Pod stays alive and can recover by itself.

**Q2.2** — A liveness failure makes the kubelet kill the container and start a new one. The new container gets a fresh writable layer, so the `touch`ed file is gone. `/ready` returns 404 again, liveness fails again, and the loop repeats. Tying liveness to a dependency or readiness signal turns a temporary "not ready" into a permanent restart loop, which can spread across a whole fleet.

**Q2.3** — **Readiness only:** the database is unreachable, the cache is warming, or the process is overloaded and shedding load. Restarting would not help and would drop in-flight work. **Liveness:** a deadlocked process, or an event loop that is stuck and no longer answers even a trivial local handler. Only a restart fixes it. Liveness checks should stay local and cheap, never depending on anything downstream.

### Exercise 3

**Q3.1** — `periodSeconds × failureThreshold` = 5 × 12 = 60 s. If the startup probe has not succeeded by then, the kubelet kills the container and applies the Pod's `restartPolicy`, just like a liveness failure.

**Q3.2** — `initialDelaySeconds` applies to every container start, and it also delays detecting a hang early in the life of *every* restart. A startup probe finishes as soon as the app is up, whether that takes 3 s or 55 s. After that, the tight liveness settings (5 s × 2) apply for the rest of the container's life. You get a generous start and fast detection afterwards, instead of choosing one.

**Q3.3** — No. Liveness and readiness probes are disabled until the startup probe succeeds once. The container is not ready during that time, so its endpoint reports `ready: false, serving: false, terminating: false`.

### Exercise 4

**Q4.1** — `terminating: true`: the Pod has a `deletionTimestamp`. `ready: false`: by definition a terminating endpoint is never ready, unless `publishNotReadyAddresses` is set, so normal load balancing stops sending it new connections. `serving: true`: its readiness probe still passes, meaning the process can still answer. The kubelet keeps running readiness probes during termination, and `serving` reports that result regardless of termination.

**Q4.2** — Marking the endpoint not ready is only the start of a chain that runs asynchronously: EndpointSlice update → watch delivery → every node's kube-proxy or an external load balancer reprogramming. Meanwhile, the kubelet runs `preStop` and then sends SIGTERM *in parallel with* that chain. Without a delay, the process can exit while some nodes or LBs still route new connections to it, which surfaces as resets and 502s. The sleep keeps the process accepting connections until everyone has stopped sending them. On recent versions, the built-in `preStop: sleep: seconds: N` action does the same without needing a `sleep` binary in the image.

**Q4.3** — When a Service has **no** ready endpoints left, kube-proxy falls back to endpoints that are `serving: true` and `terminating: true`. It does this rather than dropping traffic. A common case is a rolling update or scale-down where all remaining Pods are terminating, especially with `externalTrafficPolicy: Local` on a node whose local Pods are all shutting down. This avoids a black hole while the Pods finish draining. See the termination-flow tutorial.

**Q4.4** — The grace period covers `preStop` **and** the SIGTERM handling together. At 40 s, the kubelet stops waiting, sends SIGKILL, and the container dies mid-hook with no graceful shutdown. The kubelet also records a `FailedPreStopHook`/`Killing` event. Always set `terminationGracePeriodSeconds` greater than the `preStop` delay plus the app's own drain time.

### Exercise 5

**Q5.1** — The controller computes `ready = publishNotReadyAddresses || (podReady && !terminating)`, so the Service-level flag forces `ready: true`. `serving` is always derived from the Pod's real `Ready` condition, so it still shows `false`. Consumers that care about actual health should read `serving`.

**Q5.2** — Stateful clustered systems whose members must find each other *before* any of them is ready, such as etcd, Cassandra, ZooKeeper, Elasticsearch or a Galera/MySQL group. Their readiness often depends on forming a quorum. If peer DNS only published ready members, no member would become ready: a bootstrap deadlock. They use a dedicated headless "peers" Service with this flag, usually as the StatefulSet's `serviceName`, plus a separate normal Service for clients.

**Q5.3** — The flag disables readiness-based filtering. Clients would be load-balanced to Pods that are starting, overloaded or failing their probes, and to terminating Pods, because `ready` is forced to `true`. Readiness probes stop protecting users.

### Exercise 6

**Q6.1** — A Pod is `Ready` only when **all** its containers are ready (`ContainersReady=True`) **and** every condition listed in `spec.readinessGates` exists in `status.conditions` with `status: "True"`. A missing condition counts as `False`. The `READY 1/1` column only counts containers, so it can mislead.

**Q6.2** — With IP-targeted load balancers (for example the AWS Load Balancer Controller or GKE NEGs), a new Pod can pass its probes before the cloud LB has registered it and health-checked it. The Deployment then counts the Pod as available and terminates an old one, so the rollout can remove every old target before any new target is live in the LB, causing an outage. The controller adds a readiness gate and sets it `True` only once the target is healthy in the LB. That makes the rollout wait for the load balancer.

**Q6.3** — Pod `status` is a separate subresource. Writes to the main resource ignore changes to `status`, so a patch without `--subresource=status` silently has no effect. A controller needs `patch` (or `update`) on `pods/status` in the relevant namespaces, and usually `get`/`list`/`watch` on `pods`.

### Exercise 7

**Q7.1** — With `maxUnavailable: 0` the controller can never go below 4 available Pods. It can only add a surge Pod (`maxSurge: 1`) and must wait for that Pod to become available before removing an old one. The new Pod never became ready, so nothing old was removed, and all 4 ready endpoints kept serving. With `maxUnavailable: 1`, the controller would have immediately scaled the old ReplicaSet down to 3 and created new, never-ready Pods. The rollout would still stall, but you would be running at 75 % capacity for as long as it stayed broken.

**Q7.2** — A Pod counts as **available** only after it has stayed ready for `minReadySeconds` without any container crashing. This catches Pods that pass a probe once and then crash, and slows the rollout so problems appear before more old Pods are replaced. It affects the Deployment's *available* count. It does **not** delay the endpoint: the Pod receives traffic as soon as it is ready.

**Q7.3** — No. The controller sets `Progressing=False` with reason `ProgressDeadlineExceeded`, and `kubectl rollout status` exits non-zero. Rolling back is up to you (`kubectl rollout undo`) or to CI/CD or a progressive-delivery tool reacting to that condition.

### Exercise 8

**Q8.1** — A PDB counts **healthy** Pods, meaning Pods whose `Ready` condition is `True`, not Pods that exist. The replacement was not ready, so `currentHealthy` = 2 = `desiredHealthy`, and `disruptionsAllowed` = 0. Broken readiness therefore also blocks node drains.

**Q8.2** — `IfHealthyBudget` lets a Running but not-ready Pod be evicted only while the application is not disrupted (`currentHealthy >= desiredHealthy`). With 2 ≥ 2, evicting the unready Pod does not reduce healthy capacity, so it was allowed. Evicting a ready Pod would drop healthy to 1 < 2, so the API server returned 429.

**Q8.3** — Once an application is already below its budget, for example after a bad deploy or a crashing dependency, `IfHealthyBudget` prevents evicting even the *broken* Pods. Draining a node then hangs forever on Pods that serve nothing, which blocks upgrades and autoscaler scale-down. `AlwaysAllow` lets not-ready Running Pods be evicted at any time. That costs no availability, because they were not serving, so the Kubernetes docs recommend it for most workloads. Keep `IfHealthyBudget` only when an application still needs its not-ready Pods, for example during quorum recovery.

**Q8.4** — No. PDBs only apply to *voluntary* disruptions that go through the Eviction API: `kubectl drain`, the Cluster Autoscaler, and tooling that respects the Eviction API. A direct `kubectl delete pod`, deleting a Deployment, a kernel panic, or a lost node bypass it entirely. Protection against involuntary failures comes from replica count, topology spread, anti-affinity, and correct readiness and termination handling.

</details>