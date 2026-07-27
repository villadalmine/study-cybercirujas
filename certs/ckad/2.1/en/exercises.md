# 2.1 — Deployment Strategies: Rolling Update, Blue/Green, Canary

*Reference: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf), domain "Application Deployment" (weight 5).*

These exercises build up from the built-in `RollingUpdate` strategy to blue/green and canary patterns implemented with plain Deployments and Services — the primitives available on the exam, with no service mesh or Ingress controller required.

---

## Exercise 1 — Controlling the pace of a Rolling Update

1. Create a working namespace:
   ```bash
   kubectl create namespace ckad-2-1
   ```

2. Save the following as `webapp-v1.yaml` and apply it:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: webapp
     labels:
       app: webapp
   spec:
     replicas: 6
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxSurge: 1
         maxUnavailable: 1
     selector:
       matchLabels:
         app: webapp
     template:
       metadata:
         labels:
           app: webapp
       spec:
         containers:
         - name: webapp
           image: nginx:1.25
           ports:
           - containerPort: 80
   ```
   ```bash
   kubectl apply -f webapp-v1.yaml -n ckad-2-1
   kubectl rollout status deployment/webapp -n ckad-2-1
   ```

3. In one terminal, watch the ReplicaSets while the rollout happens:
   ```bash
   kubectl get rs -n ckad-2-1 -l app=webapp -w
   ```

4. In a second terminal, trigger a new rollout:
   ```bash
   kubectl set image deployment/webapp webapp=nginx:1.26 -n ckad-2-1
   kubectl rollout status deployment/webapp -n ckad-2-1
   ```

5. Inspect the revision history kept for this Deployment:
   ```bash
   kubectl rollout history deployment/webapp -n ckad-2-1
   ```

**Check your understanding:**
1. With `maxSurge: 1` and `maxUnavailable: 1` on 6 replicas, what are the minimum number of *available* pods and the maximum *total* pods (old + new) Kubernetes may run at any instant during the rollout?
2. While `kubectl get rs -w` is running you see two ReplicaSets both with a nonzero pod count at the same time. What happens to the old ReplicaSet once the rollout finishes — is it deleted?

---

## Exercise 2 — Blue/Green cutover via Service selector

1. Save and apply the "blue" version:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: myapp-blue
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: myapp
         version: blue
     template:
       metadata:
         labels:
           app: myapp
           version: blue
       spec:
         containers:
         - name: myapp
           image: hashicorp/http-echo:latest
           args: ["-text=response from BLUE", "-listen=:5678"]
           ports:
           - containerPort: 5678
   ```

2. Apply a Service that initially routes only to blue:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: myapp
   spec:
     selector:
       app: myapp
       version: blue
     ports:
     - port: 80
       targetPort: 5678
   ```
   ```bash
   kubectl apply -f myapp-blue.yaml -n ckad-2-1
   kubectl apply -f myapp-svc.yaml -n ckad-2-1
   ```

3. Confirm traffic reaches blue:
   ```bash
   kubectl run tmp-curl --image=busybox:1.36 --rm -it --restart=Never -n ckad-2-1 -- wget -qO- myapp
   ```

4. Deploy "green" alongside blue (same manifest, `name: myapp-green`, `version: green`, text `response from GREEN`), and apply it. Confirm 6 pods now exist (`kubectl get pods -n ckad-2-1 -l app=myapp --show-labels`) but the curl test in step 3 still returns BLUE.

5. Cut traffic over to green:
   ```bash
   kubectl patch service myapp -n ckad-2-1 -p '{"spec":{"selector":{"app":"myapp","version":"green"}}}'
   ```
   Re-run the curl test — it should now return GREEN.

6. If something is wrong, roll back instantly:
   ```bash
   kubectl patch service myapp -n ckad-2-1 -p '{"spec":{"selector":{"app":"myapp","version":"blue"}}}'
   ```

7. Once confident, decommission the old version:
   ```bash
   kubectl delete deployment myapp-blue -n ckad-2-1
   ```

**Check your understanding:**
1. Between steps 4 and 6, both `myapp-blue` and `myapp-green` have all pods Ready, but only one version receives client traffic. Which object/field decides that, and why is flipping it near-instantaneous compared to a rolling update?
2. What's the fastest way to undo a bad blue/green cutover, and how does its speed/risk compare to `kubectl rollout undo` on a single rolling-update Deployment?

---

## Exercise 3 — Canary via replica-ratio traffic splitting

1. Deploy the stable track at 4 replicas, labeled `app: myapp, track: stable`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: myapp-stable
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: myapp
         track: stable
     template:
       metadata:
         labels:
           app: myapp
           track: stable
       spec:
         containers:
         - name: myapp
           image: hashicorp/http-echo:latest
           args: ["-text=response from STABLE v1", "-listen=:5678"]
           ports:
           - containerPort: 5678
   ```

2. Deploy the canary track at 1 replica, same `app` label, different `track`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: myapp-canary
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: myapp
         track: canary
     template:
       metadata:
         labels:
           app: myapp
           track: canary
       spec:
         containers:
         - name: myapp
           image: hashicorp/http-echo:latest
           args: ["-text=response from CANARY v2", "-listen=:5678"]
           ports:
           - containerPort: 5678
   ```

3. Point a Service at `app: myapp` only — **omit** `track` from the selector so it targets both:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: myapp
   spec:
     selector:
       app: myapp
     ports:
     - port: 80
       targetPort: 5678
   ```

4. Confirm the Service sees all 5 pods, then sample the traffic split:
   ```bash
   kubectl get endpoints myapp -n ckad-2-1
   kubectl run tmp-curl --image=busybox:1.36 --rm -it --restart=Never -n ckad-2-1 -- \
     sh -c 'for i in $(seq 1 20); do wget -qO- myapp; echo; done'
   ```

5. Promote the canary once satisfied — scale it up, scale stable down, then delete the old track:
   ```bash
   kubectl scale deployment/myapp-canary -n ckad-2-1 --replicas=4
   kubectl scale deployment/myapp-stable -n ckad-2-1 --replicas=0
   kubectl delete deployment myapp-stable -n ckad-2-1
   ```

**Check your understanding:**
1. Why does a Service selecting only `app: myapp` (dropping `track`) turn two independent Deployments into a canary rollout, and what determines the approximate traffic percentage each version receives?
2. Vanilla Kubernetes Services load-balance per-connection roughly evenly across all matching Endpoints — they have no concept of "route 5% of requests here." Given that, how do you approximate a small canary percentage with just Deployments/Services, and what would a *precise*, replica-independent split require instead?

---

## Exercise 4 — Recovering from a bad rollout

1. Reuse the `webapp` Deployment from Exercise 1 (or redeploy it at `nginx:1.25`, 4 replicas).

2. Roll out a broken image tag:
   ```bash
   kubectl set image deployment/webapp webapp=nginx:1.25-does-not-exist -n ckad-2-1
   kubectl rollout status deployment/webapp -n ckad-2-1 --timeout=30s
   ```
   The command should time out without completing.

3. Inspect what's stuck:
   ```bash
   kubectl get pods -n ckad-2-1 -l app=webapp
   kubectl rollout history deployment/webapp -n ckad-2-1
   ```

4. Roll back to the last working revision:
   ```bash
   kubectl rollout undo deployment/webapp -n ckad-2-1
   kubectl rollout status deployment/webapp -n ckad-2-1
   ```

5. Roll back to a specific earlier revision number instead of "one step back":
   ```bash
   kubectl rollout undo deployment/webapp -n ckad-2-1 --to-revision=1
   ```

**Check your understanding:**
1. In step 2, the rollout stalls partway instead of tearing down all old pods immediately. Which `strategy` field is responsible, and how does it stop a bad rollout from causing full downtime?
2. `kubectl rollout undo` re-applies a previous ReplicaSet's pod template. Why must that old ReplicaSet still exist for undo to work, and which Deployment field controls how many old ReplicaSets are kept around?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
1. `maxUnavailable: 1` guarantees at least `6 - 1 = 5` available pods at any time. `maxSurge: 1` allows up to `6 + 1 = 7` total pods (old + new) to exist simultaneously while the new ReplicaSet scales up before the old one finishes scaling down.
2. The old ReplicaSet is *not* deleted on success — it's scaled down to 0 replicas but the object itself is kept (up to `spec.revisionHistoryLimit`, default 10) so `kubectl rollout undo`/`rollout history` have a pod template to restore from.

**Exercise 2**
1. The Service's `spec.selector`. Flipping it is near-instant because it only rewrites which Endpoints the Service resolves to — kube-proxy reprograms iptables/IPVS rules immediately. No pods are created, terminated, or have to pass readiness probes, unlike a rolling update.
2. Patch the Service selector back to the previous version (`version: blue`). It's essentially instant and low-risk because the old pods were never deleted — they were left running the whole time. Compare to `kubectl rollout undo`, which must recreate pods from the old ReplicaSet's template and is paced by `maxSurge`/`maxUnavailable` and readiness probes, so it's slower and briefly changes pod counts.

**Exercise 3**
1. A Service's Endpoints are the union of all Ready pods matching its selector, regardless of which Deployment owns them. Since `track` isn't part of the selector, both `myapp-stable` and `myapp-canary` pods qualify. kube-proxy round-robins per-connection across all matching Endpoints, so each version's traffic share is approximately `(that version's pod count) / (total pods behind the Service)` — here roughly 4/5 stable, 1/5 canary.
2. You approximate the split purely by choosing a replica ratio (e.g., 1 canary : 19 stable ≈ 5%) — there's no native weighting independent of pod count. A precise, replica-independent split (e.g., exactly 5% regardless of how many pods exist, or routing by header/cookie) needs a traffic-splitting layer above plain Services: an Ingress controller with canary annotations, Gateway API `HTTPRoute` weights, or a service mesh like Istio/Linkerd — none of which are covered by bare `kubectl` Deployment/Service primitives.

**Exercise 4**
1. `spec.strategy.rollingUpdate.maxUnavailable`. It caps how many pods can be down at once, so Kubernetes only terminates an old pod once a new one is ready (or up to that cap) — a broken image just leaves pods stuck in `ImagePullBackOff` without ever exceeding the allowed unavailable count, so the rest keep serving stable traffic.
2. The old ReplicaSet holds the previous pod template that `rollout undo` re-applies; if it were deleted, there would be nothing to restore from. `spec.revisionHistoryLimit` on the Deployment controls how many old ReplicaSets are retained (default 10) — once exceeded, the oldest ones are actually garbage collected and can no longer be targeted by `--to-revision`.

</details>