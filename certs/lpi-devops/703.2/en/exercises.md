# 703.2 — Basic Kubernetes Operations
## Guided Exercises (LPI DevOps Tools Engineer, exam 701-100 v2.0.0)

> **Weight in the exam:** 11.67 — the single heaviest objective of Topic 703.
> **What you are drilling:** the `kubectl` command surface, the Pod → ReplicaSet → Deployment ownership chain, Services and cluster DNS, ConfigMaps and Secrets, labels/selectors/annotations, namespaces, probes and resource requests, and the diagnostic loop you will actually use in production.
>
> Every step below is executable. Outputs shown are real shapes from a `kind` cluster running Kubernetes v1.33; hashes, IPs and timestamps will differ on your machine — the *structure* is what you verify against.

---

## Exercise 0 — Build the lab cluster

You need a throwaway cluster you can break. `kind` (Kubernetes IN Docker) gives you a three-node cluster in about a minute and is disposable by design.

**Steps**

1. Verify the client tooling:

   ```bash
   docker version --format '{{.Server.Version}}'
   kind version
   kubectl version --client
   ```

   ```
   27.3.1
   kind v0.27.0 go1.23.6 linux/amd64
   Client Version: v1.33.1
   Kustomize Version: v5.6.0
   ```

2. Write the cluster definition. The `extraPortMappings` block publishes NodePort `30080` from the control-plane container to your host — you will need it in Exercise 5.

   ```yaml
   # kind-703.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: lpi-703
   nodes:
     - role: control-plane
       extraPortMappings:
         - containerPort: 30080
           hostPort: 30080
           protocol: TCP
     - role: worker
     - role: worker
   ```

3. Create the cluster:

   ```bash
   kind create cluster --config kind-703.yaml
   ```

   ```
   Creating cluster "lpi-703" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦 📦 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
    ✓ Joining worker nodes 🚜
   Set kubectl context to "kind-lpi-703"
   ```

4. Confirm the nodes are `Ready` and note their roles:

   ```bash
   kubectl get nodes -o wide
   ```

   ```
   NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
   lpi-703-control-plane    Ready    control-plane   84s   v1.33.1   172.18.0.4    Debian GNU/Linux 12
   lpi-703-worker           Ready    <none>          71s   v1.33.1   172.18.0.2    Debian GNU/Linux 12
   lpi-703-worker2          Ready    <none>          71s   v1.33.1   172.18.0.3    Debian GNU/Linux 12
   ```

5. Inspect what makes the control-plane node different from the workers:

   ```bash
   kubectl get node lpi-703-control-plane \
     -o jsonpath='{.spec.taints}{"\n"}'
   ```

   ```
   [{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane"}]
   ```

**Checkpoint questions**

- **Q0.1** — Two of the nodes show `ROLES: <none>`. Where does the `control-plane` role in that column come from — is it a field in the Node spec?
- **Q0.2** — What concrete effect does the taint printed in step 5 have on a workload you create later, and what would a Pod need in order to land there anyway?
- **Q0.3** — `kubectl version --client` printed a *Kustomize* version. Why does a Kubernetes CLI report that at all?

---

## Exercise 1 — kubectl, kubeconfig and API discovery

Before you create anything, learn to interrogate the API server. Most "kubectl doesn't work" incidents are context or RBAC problems, not cluster problems.

**Steps**

1. List the contexts your kubeconfig knows about and identify the active one:

   ```bash
   kubectl config get-contexts
   ```

   ```
   CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
   *         kind-lpi-703    kind-lpi-703    kind-lpi-703
   ```

2. Show only the active context, with credentials redacted, and extract the API endpoint:

   ```bash
   kubectl config view --minify
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
   ```

   ```
   https://127.0.0.1:38471
   ```

3. Find out which file kubectl actually read:

   ```bash
   echo "${KUBECONFIG:-$HOME/.kube/config}"
   kubectl config view --raw -o jsonpath='{.users[0].name}{"\n"}'
   ```

4. Ask the API server what it serves. These two commands answer *different* questions:

   ```bash
   kubectl api-versions | sort | head -20
   kubectl api-resources --namespaced=true -o wide | head -12
   ```

   ```
   NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND         VERBS
   configmaps    cm           v1           true         ConfigMap    [create delete deletecollection get list patch update watch]
   endpoints     ep           v1           true         Endpoints    [create delete deletecollection get list patch update watch]
   events        ev           v1           true         Event        [create delete deletecollection get list patch update watch]
   pods          po           v1           true         Pod          [create delete deletecollection get list patch update watch]
   secrets                    v1           true         Secret       [create delete deletecollection get list patch update watch]
   services      svc          v1           true         Service      [create delete deletecollection get list patch update watch]
   daemonsets    ds           apps/v1      true         DaemonSet    [create delete deletecollection get list patch update watch]
   deployments   deploy       apps/v1      true         Deployment   [create delete deletecollection get list patch update watch]
   replicasets   rs           apps/v1      true         ReplicaSet   [create delete deletecollection get list patch update watch]
   ```

5. List the cluster-scoped resources — the ones a namespace cannot contain:

   ```bash
   kubectl api-resources --namespaced=false -o name | sort
   ```

   ```
   apiservices.apiregistration.k8s.io
   clusterrolebindings.rbac.authorization.k8s.io
   clusterroles.rbac.authorization.k8s.io
   csidrivers.storage.k8s.io
   ingressclasses.networking.k8s.io
   namespaces
   nodes
   persistentvolumes
   priorityclasses.scheduling.k8s.io
   runtimeclasses.node.k8s.io
   storageclasses.storage.k8s.io
   ...
   ```

6. Read the schema straight from the server instead of guessing field names:

   ```bash
   kubectl explain deployment.spec.strategy.rollingUpdate
   kubectl explain pod.spec.containers.livenessProbe --recursive | head -25
   ```

   ```
   GROUP:      apps
   KIND:       Deployment
   VERSION:    v1

   FIELD: rollingUpdate <RollingUpdateDeployment>

   DESCRIPTION:
       Rolling update config params. Present only if DeploymentStrategyType =
       RollingUpdate.

   FIELDS:
     maxSurge      <IntOrString>
     maxUnavailable        <IntOrString>
   ```

7. Check your own permissions before blaming the cluster:

   ```bash
   kubectl auth can-i create deployments --namespace default
   kubectl auth can-i delete nodes
   kubectl auth can-i --list --namespace default | head -6
   ```

   ```
   yes
   yes
   ```

8. Talk to a raw endpoint, bypassing kubectl's object layer:

   ```bash
   kubectl get --raw='/readyz?verbose' | tail -8
   kubectl get --raw='/api/v1/namespaces/kube-system/pods' | head -c 200; echo
   ```

   ```
   [+]poststarthook/start-legacy-token-tracking-controller ok
   [+]poststarthook/start-service-ip-repair-controllers ok
   [+]shutdown ok
   readyz check passed
   ```

**Checkpoint questions**

- **Q1.1** — In precedence order, what determines which kubeconfig file kubectl uses, and how do you point at a different one for a single command without exporting anything permanently?
- **Q1.2** — Explain the difference between `kubectl api-versions` and `kubectl api-resources`. Which one would tell you that a Custom Resource named `Certificate` is available and what its short name is?
- **Q1.3** — Why is `kubectl explain` more trustworthy than upstream documentation when you are working on someone else's cluster?
- **Q1.4** — `kubectl auth can-i --list` returned results without you creating any RBAC. What identity is kubectl using, and how would you check a *different* subject's permissions from your admin account?

---

## Exercise 2 — Namespaces and the two ways to create objects

**Steps**

1. Create a namespace and inspect the result:

   ```bash
   kubectl create namespace ops-lab
   kubectl get ns
   ```

   ```
   namespace/ops-lab created
   NAME                 STATUS   AGE
   default              Active   6m
   kube-node-lease      Active   6m
   kube-public          Active   6m
   kube-system          Active   6m
   local-path-storage   Active   6m
   ops-lab              Active   2s
   ```

2. Make it the default for the current context so you stop typing `-n`:

   ```bash
   kubectl config set-context --current --namespace=ops-lab
   kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'
   ```

   ```
   Context "kind-lpi-703" modified.
   ops-lab
   ```

3. Use the imperative commands as **manifest generators**, not as a deployment method:

   ```bash
   kubectl run sandbox --image=busybox:1.36 --restart=Never \
     --dry-run=client -o yaml -- sleep 3600
   ```

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     creationTimestamp: null
     labels:
       run: sandbox
     name: sandbox
   spec:
     containers:
     - args:
       - sleep
       - "3600"
       image: busybox:1.36
       name: sandbox
       resources: {}
     dnsPolicy: ClusterFirst
     restartPolicy: Never
   status: {}
   ```

4. Now write the declarative version you would actually commit to Git:

   ```yaml
   # 01-pods.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sandbox
     namespace: ops-lab
     labels:
       app: sandbox
       tier: tooling
   spec:
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sleep", "3600"]
         resources:
           requests:
             cpu: 10m
             memory: 16Mi
           limits:
             cpu: 100m
             memory: 64Mi
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-solo
     namespace: ops-lab
     labels:
       app: nginx-solo
       tier: frontend
   spec:
     containers:
       - name: nginx
         image: nginx:1.27.4-alpine
         ports:
           - name: http
             containerPort: 80
         resources:
           requests:
             cpu: 50m
             memory: 32Mi
           limits:
             cpu: 200m
             memory: 128Mi
   ```

   ```bash
   kubectl apply -f 01-pods.yaml
   ```

   ```
   pod/sandbox created
   pod/nginx-solo created
   ```

5. Watch them start, then look at placement:

   ```bash
   kubectl get pods -o wide
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINATED NODE   READINESS GATES
   nginx-solo   1/1     Running   0          22s   10.244.1.5   lpi-703-worker    <none>           <none>
   sandbox      1/1     Running   0          22s   10.244.2.4   lpi-703-worker2   <none>           <none>
   ```

6. Read a Pod's full story:

   ```bash
   kubectl describe pod nginx-solo | sed -n '1,12p;/Events:/,$p'
   ```

   ```
   Name:             nginx-solo
   Namespace:        ops-lab
   Priority:         0
   Service Account:  default
   Node:             lpi-703-worker/172.18.0.2
   Start Time:       Thu, 03 Sep 2026 09:14:02 -0300
   Labels:           app=nginx-solo
                     tier=frontend
   Annotations:      <none>
   Status:           Running
   IP:               10.244.1.5
   Events:
     Type    Reason     Age   From               Message
     ----    ------     ----  ----               -------
     Normal  Scheduled  32s   default-scheduler  Successfully assigned ops-lab/nginx-solo to lpi-703-worker
     Normal  Pulling    31s   kubelet            Pulling image "nginx:1.27.4-alpine"
     Normal  Pulled     29s   kubelet            Successfully pulled image "nginx:1.27.4-alpine" in 1.84s
     Normal  Created    29s   kubelet            Created container: nginx
     Normal  Started    29s   kubelet            Started container nginx
   ```

7. Prove that `create` and `apply` are not interchangeable:

   ```bash
   kubectl create -f 01-pods.yaml
   kubectl apply -f 01-pods.yaml
   ```

   ```
   Error from server (AlreadyExists): error when creating "01-pods.yaml": pods "sandbox" already exists
   Error from server (AlreadyExists): error when creating "01-pods.yaml": pods "nginx-solo" already exists

   pod/sandbox unchanged
   pod/nginx-solo unchanged
   ```

**Checkpoint questions**

- **Q2.1** — `--dry-run=client` and `--dry-run=server` both print an object without persisting it. What does the server-side variant catch that the client-side one cannot?
- **Q2.2** — In step 5 the two Pods landed on different nodes. Which component made that decision, and at what point did the Pod object first exist in etcd relative to that decision?
- **Q2.3** — `sandbox` was created with `restartPolicy: Never` in the generated YAML but the committed manifest omits `restartPolicy`. What value does the API server store, and why does that matter for a bare Pod?
- **Q2.4** — If you run `kubectl delete namespace ops-lab`, what happens to the two Pods, and why can the namespace sit in `Terminating` for a long time?
- **Q2.5** — Neither Pod is managed by a controller. Name two failure modes that will *not* be recovered from as a result.

---

## Exercise 3 — Labels, selectors and annotations

Labels are the join key of the entire system. Services, ReplicaSets, NetworkPolicies and `kubectl` itself all address objects through selectors — never through names.

**Steps**

1. Create a small, deliberately heterogeneous population:

   ```bash
   kubectl run cache   --image=redis:7.4-alpine --labels='app=cache,tier=backend,env=dev'
   kubectl run api-dev --image=nginx:1.27.4-alpine --labels='app=api,tier=backend,env=dev'
   kubectl run api-prd --image=nginx:1.27.4-alpine --labels='app=api,tier=backend,env=prod'
   kubectl get pods --show-labels
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE   LABELS
   api-dev      1/1     Running   0          9s    app=api,env=dev,tier=backend
   api-prd      1/1     Running   0          8s    app=api,env=prod,tier=backend
   cache        1/1     Running   0          10s   app=cache,env=dev,tier=backend
   nginx-solo   1/1     Running   0          4m    app=nginx-solo,tier=frontend
   sandbox      1/1     Running   0          4m    app=sandbox,tier=tooling
   ```

2. Equality-based selection, then promote a label to a column:

   ```bash
   kubectl get pods -l tier=backend
   kubectl get pods -l 'app=api,env=prod'
   kubectl get pods -L env,tier
   ```

   ```
   NAME      READY   STATUS    RESTARTS   AGE   ENV    TIER
   api-dev   1/1     Running   0          40s   dev    backend
   api-prd   1/1     Running   0          39s   prod   backend
   cache     1/1     Running   0          41s   dev    backend
   nginx-solo 1/1    Running   0          5m    <none> frontend
   sandbox   1/1     Running   0          5m    <none> tooling
   ```

3. Set-based selection — the form that has no equality equivalent:

   ```bash
   kubectl get pods -l 'env in (dev,staging)'
   kubectl get pods -l 'app notin (cache,sandbox)'
   kubectl get pods -l 'env'          # has the key, any value
   kubectl get pods -l '!env'         # does NOT have the key
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE
   nginx-solo   1/1     Running   0          6m
   sandbox      1/1     Running   0          6m
   ```

4. Mutate labels in place, including the overwrite guard:

   ```bash
   kubectl label pod cache env=prod
   kubectl label pod cache env=prod --overwrite
   kubectl label pod cache retention-              # trailing dash removes a key
   ```

   ```
   error: 'env' already has a value (dev), and --overwrite is false
   pod/cache labeled
   pod/cache not labeled
   ```

5. Attach an annotation — arbitrary, non-selectable metadata:

   ```bash
   kubectl annotate pod api-prd \
     owner='sre-platform@example.com' \
     runbook='https://wiki.example.com/runbooks/api' \
     kubernetes.io/change-cause='initial manual placement'
   kubectl get pod api-prd -o jsonpath='{.metadata.annotations}{"\n"}' | tr ',' '\n'
   ```

   ```
   {"kubernetes.io/change-cause":"initial manual placement"
   "owner":"sre-platform@example.com"
   "runbook":"https://wiki.example.com/runbooks/api"}
   ```

6. Try to select on the annotation, then on a *field*:

   ```bash
   kubectl get pods -l owner=sre-platform@example.com
   kubectl get pods --field-selector status.phase=Running
   kubectl get pods --field-selector spec.nodeName=lpi-703-worker2
   kubectl get pods --field-selector metadata.annotations.owner=x
   ```

   ```
   No resources found in ops-lab namespace.

   NAME         READY   STATUS    RESTARTS   AGE
   api-dev      1/1     Running   0          3m
   ...
   NAME      READY   STATUS    RESTARTS   AGE
   sandbox   1/1     Running   0          9m
   cache     1/1     Running   0          3m

   Error from server (BadRequest): Unable to find "/v1, Resource=pods" that match label selector "",
   field selector "metadata.annotations.owner=x": "metadata.annotations.owner" is not a known field selector...
   ```

7. Bulk operations driven by a selector:

   ```bash
   kubectl get pods -l env=dev -o name
   kubectl delete pods -l env=dev
   ```

   ```
   pod/api-dev
   pod/cache
   pod "api-dev" deleted
   pod "cache" deleted
   ```

**Checkpoint questions**

- **Q3.1** — State the rule that decides whether a piece of metadata belongs in `labels` or in `annotations`. Give one example of each from a real cluster.
- **Q3.2** — Write the selector that means "backend tier, in production, but not the `cache` app" in a single `-l` expression.
- **Q3.3** — Step 6 shows that annotations are not selectable and that only some fields are valid field selectors. Why is that restriction there — what is the API server doing differently for labels?
- **Q3.4** — A Deployment's `.spec.selector.matchLabels` is immutable in `apps/v1`. Why did the API designers make it immutable, and what is the practical procedure when you must change it?
- **Q3.5** — What are the syntactic constraints on a label *value* (length, allowed characters), and why can't you put a URL in one?

---

## Exercise 4 — Deployments, ReplicaSets and rollouts

**Steps**

1. Create a Deployment declaratively:

   ```yaml
   # 02-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: ops-lab
     labels:
       app: web
   spec:
     replicas: 3
     revisionHistoryLimit: 5
     selector:
       matchLabels:
         app: web
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxSurge: 1
         maxUnavailable: 0
     template:
       metadata:
         labels:
           app: web
           tier: frontend
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.4-alpine
             ports:
               - name: http
                 containerPort: 80
             resources:
               requests:
                 cpu: 25m
                 memory: 32Mi
               limits:
                 cpu: 250m
                 memory: 128Mi
   ```

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl rollout status deployment/web --timeout=90s
   ```

   ```
   deployment.apps/web created
   Waiting for deployment "web" rollout to finish: 0 of 3 updated replicas are available...
   deployment "web" successfully rolled out
   ```

2. Observe the three-level ownership chain:

   ```bash
   kubectl get deploy,rs,pods -l app=web
   ```

   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   3/3     3            3           35s

   NAME                            DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-7d9c8b6f45  3         3         3       35s

   NAME                      READY   STATUS    RESTARTS   AGE
   pod/web-7d9c8b6f45-4kxq7  1/1     Running   0          35s
   pod/web-7d9c8b6f45-9v2mt  1/1     Running   0          35s
   pod/web-7d9c8b6f45-tz8n6  1/1     Running   0          35s
   ```

3. Follow the ownership links explicitly:

   ```bash
   kubectl get pod web-7d9c8b6f45-4kxq7 \
     -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
   kubectl get rs web-7d9c8b6f45 \
     -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
   kubectl get pod web-7d9c8b6f45-4kxq7 --show-labels
   ```

   ```
   ReplicaSet/web-7d9c8b6f45
   Deployment/web
   NAME                   READY   STATUS    RESTARTS   AGE   LABELS
   web-7d9c8b6f45-4kxq7   1/1     Running   0          2m    app=web,pod-template-hash=7d9c8b6f45,tier=frontend
   ```

4. Scale imperatively, then note the drift you have just introduced:

   ```bash
   kubectl scale deployment/web --replicas=5
   kubectl get deploy web
   kubectl scale deployment/web --replicas=3 --current-replicas=5
   ```

   ```
   deployment.apps/web scaled
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    5/5      5           5           3m
   deployment.apps/web scaled
   ```

5. Roll a new image and record *why*:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5-alpine
   kubectl annotate deployment/web kubernetes.io/change-cause='CVE patch: nginx 1.27.4 -> 1.27.5'
   kubectl rollout status deployment/web
   kubectl get rs -l app=web
   ```

   ```
   deployment.apps/web image updated
   deployment.apps/web annotated
   Waiting for deployment "web" rollout to finish: 2 out of 3 new replicas have been updated...
   deployment "web" successfully rolled out

   NAME             DESIRED   CURRENT   READY   AGE
   web-58f6c4d9c7   3         3         3       48s
   web-7d9c8b6f45   0         0         0       6m
   ```

6. Read and use the revision history:

   ```bash
   kubectl rollout history deployment/web
   kubectl rollout history deployment/web --revision=2
   ```

   ```
   deployment.apps/web
   REVISION  CHANGE-CAUSE
   1         <none>
   2         CVE patch: nginx 1.27.4 -> 1.27.5
   ```

7. Break the rollout on purpose and watch it stall rather than destroy capacity:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5-alpin   # typo: no 'e'
   kubectl rollout status deployment/web --timeout=45s
   kubectl get pods -l app=web
   ```

   ```
   deployment.apps/web image updated
   Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
   error: timed out waiting for the condition

   NAME                   READY   STATUS             RESTARTS   AGE
   web-58f6c4d9c7-7bqhr   1/1     Running            0          3m
   web-58f6c4d9c7-h4z9m   1/1     Running            0          3m
   web-58f6c4d9c7-m2xkd   1/1     Running            0          3m
   web-6f4b9dd58c-nkw8t   0/1     ImagePullBackOff   0          46s
   ```

8. Roll back, then verify:

   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   kubectl get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   deployment.apps/web rolled back
   deployment "web" successfully rolled out
   nginx:1.27.5-alpine
   ```

9. Pause a Deployment to batch several edits into one rollout:

   ```bash
   kubectl rollout pause deployment/web
   kubectl set image deployment/web nginx=nginx:1.27.4-alpine
   kubectl set resources deployment/web -c nginx --limits=memory=192Mi
   kubectl get rs -l app=web --no-headers | wc -l
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   ```

   ```
   deployment.apps/web paused
   deployment.apps/web image updated
   deployment.apps/web resource requirements updated
   3
   deployment.apps/web resumed
   deployment "web" successfully rolled out
   ```

10. Delete the live ReplicaSet and observe the controller's response:

    ```bash
    RS=$(kubectl get rs -l app=web -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{end}')
    kubectl delete rs "$RS"
    sleep 5
    kubectl get rs,pods -l app=web
    ```

    ```
    replicaset.apps "web-7d9c8b6f45" deleted
    NAME                            DESIRED   CURRENT   READY   AGE
    replicaset.apps/web-7d9c8b6f45  3         3         2       6s

    NAME                       READY   STATUS    RESTARTS   AGE
    pod/web-7d9c8b6f45-6dlzs   1/1     Running   0          6s
    pod/web-7d9c8b6f45-c8m4v   1/1     Running   0          6s
    pod/web-7d9c8b6f45-qq7pn   0/1     Running   0          6s
    ```

11. Now do it non-destructively, with orphaning:

    ```bash
    RS=$(kubectl get rs -l app=web -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{end}')
    kubectl delete rs "$RS" --cascade=orphan
    sleep 5
    kubectl get rs,pods -l app=web
    ```

    ```
    replicaset.apps "web-7d9c8b6f45" deleted
    NAME                            DESIRED   CURRENT   READY   AGE
    replicaset.apps/web-7d9c8b6f45  3         3         3       4s

    NAME                       READY   STATUS    RESTARTS   AGE
    pod/web-7d9c8b6f45-6dlzs   1/1     Running   0          2m14s
    pod/web-7d9c8b6f45-c8m4v   1/1     Running   0          2m14s
    pod/web-7d9c8b6f45-qq7pn   1/1     Running   0          2m14s
    ```

**Checkpoint questions**

- **Q4.1** — What is `pod-template-hash`, who computes it, and which two objects carry it? What would break if the Deployment controller did not add it to the ReplicaSet's selector?
- **Q4.2** — In step 7 the rollout stalled with one broken Pod and three healthy ones. Which two fields of the manifest produced exactly that behaviour, and what would have happened with `maxUnavailable: 1`?
- **Q4.3** — Revision 1 shows `CHANGE-CAUSE: <none>`. Where does that column come from, and why did `kubectl annotate` in step 5 populate it for revision 2?
- **Q4.4** — `kubectl rollout undo` does not delete the current ReplicaSet. Describe mechanically what it changes, and predict the revision numbers in `rollout history` afterwards.
- **Q4.5** — Compare the outcomes of steps 10 and 11. In step 11 no new Pods were created even though the ReplicaSet object was deleted — explain the adoption mechanism that made that possible.
- **Q4.6** — `revisionHistoryLimit: 5` is set in the manifest. What is the default, what is retained, and what is the operational cost of setting it to `0`?
- **Q4.7** — Step 4 scaled to 5 replicas imperatively while `02-deploy.yaml` still says `replicas: 3`. What happens the next time CI runs `kubectl apply -f 02-deploy.yaml`, and how would you make the Deployment safe to co-manage with a HorizontalPodAutoscaler?

---

## Exercise 5 — Services, EndpointSlices and cluster DNS

**Steps**

1. Expose the Deployment with a ClusterIP Service, written declaratively:

   ```yaml
   # 03-svc.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: ops-lab
   spec:
     type: ClusterIP
     selector:
       app: web
     ports:
       - name: http
         port: 8080          # the Service port
         targetPort: http    # the *named* container port
         protocol: TCP
   ```

   ```bash
   kubectl apply -f 03-svc.yaml
   kubectl get svc web
   ```

   ```
   service/web created
   NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
   web    ClusterIP   10.96.183.24    <none>        8080/TCP   3s
   ```

2. Inspect what the Service actually resolved to:

   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=web
   kubectl get endpointslice -l kubernetes.io/service-name=web \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.targetRef.name}{"\n"}{end}'
   ```

   ```
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
   web-lq2f7   IPv4          80      10.244.1.7,10.244.2.6,10.244.1.8   40s

   10.244.1.7   true   web-7d9c8b6f45-6dlzs
   10.244.2.6   true   web-7d9c8b6f45-c8m4v
   10.244.1.8   true   web-7d9c8b6f45-qq7pn
   ```

3. Consume it from inside the cluster, by DNS:

   ```bash
   kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh
   ```

   ```sh
   / # nslookup web
   Server:    10.96.0.10
   Address:   10.96.0.10:53
   Name:      web.ops-lab.svc.cluster.local
   Address:   10.96.183.24

   / # wget -qO- http://web:8080 | head -4
   <!DOCTYPE html>
   <html>
   <head>
   <title>Welcome to nginx!</title>

   / # cat /etc/resolv.conf
   search ops-lab.svc.cluster.local svc.cluster.local cluster.local
   nameserver 10.96.0.10
   options ndots:5

   / # wget -qO- http://web.ops-lab.svc.cluster.local:8080 -O /dev/null && echo FQDN-OK
   FQDN-OK
   / # exit
   ```

4. Add a headless Service over the same Pods and compare the DNS answer:

   ```yaml
   # 04-svc-headless.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web-headless
     namespace: ops-lab
   spec:
     clusterIP: None
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f 04-svc-headless.yaml
   kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
     nslookup web-headless.ops-lab.svc.cluster.local
   ```

   ```
   Name:      web-headless.ops-lab.svc.cluster.local
   Address 1: 10.244.1.7 10-244-1-7.web-headless.ops-lab.svc.cluster.local
   Address 2: 10.244.1.8 10-244-1-8.web-headless.ops-lab.svc.cluster.local
   Address 3: 10.244.2.6 10-244-2-6.web-headless.ops-lab.svc.cluster.local
   ```

5. Publish externally with a NodePort on the port you mapped in Exercise 0:

   ```bash
   kubectl patch svc web -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":8080,"targetPort":"http","nodePort":30080}]}}'
   kubectl get svc web
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30080
   ```

   ```
   service/web patched
   NAME   TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)          AGE
   web    NodePort   10.96.183.24   <none>        8080:30080/TCP   6m
   200
   ```

6. Break the selector and watch the endpoints evaporate:

   ```bash
   kubectl patch svc web -p '{"spec":{"selector":{"app":"web-typo"}}}'
   kubectl get endpointslice -l kubernetes.io/service-name=web
   curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://localhost:30080 || echo "connection failed"
   kubectl patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
   ```

   ```
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
   web-lq2f7   IPv4          <unset> <unset>     7m
   000
   connection failed
   service/web patched
   ```

7. Reach a single Pod without any Service at all:

   ```bash
   POD=$(kubectl get pod -l app=web -o name | head -1)
   kubectl port-forward "$POD" 8888:80 &
   sleep 2
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8888
   kill %1
   ```

   ```
   Forwarding from 127.0.0.1:8888 -> 80
   Handling connection for 8888
   200
   ```

**Checkpoint questions**

- **Q5.1** — `targetPort: http` is a string, not a number. Where is that name defined, and what breaks if you rename the container port but not the Service?
- **Q5.2** — Trace the full path of `wget http://web:8080` from inside the `tmp` Pod: which DNS suffix matched first (and why `ndots:5` matters), which component rewrote the destination IP, and which address the packet finally carried.
- **Q5.3** — What is the difference between the legacy `Endpoints` object and `EndpointSlice`, and which problem did the newer API solve?
- **Q5.4** — A headless Service returned Pod IPs instead of a single virtual IP. Name a workload type where that is exactly what you want, and explain why a ClusterIP would be wrong there.
- **Q5.5** — Which port range may `nodePort` use by default, and what would have happened in step 5 if you had asked for `nodePort: 8080`?
- **Q5.6** — In step 6 the Service still had a `CLUSTER-IP` and the NodePort was still allocated, yet connections failed. Explain in terms of the EndpointSlice controller and kube-proxy what "no endpoints" does to traffic.
- **Q5.7** — `kubectl port-forward` worked without a Service and without a NodePort. Which component proxied that connection, and why does this make it a debugging tool rather than an exposure mechanism?

---

## Exercise 6 — ConfigMaps and Secrets

**Steps**

1. Create a ConfigMap three ways and inspect the resulting keys:

   ```bash
   printf 'server.port=8080\nserver.mode=production\n' > app.properties
   kubectl create configmap web-config \
     --from-literal=LOG_LEVEL=info \
     --from-literal=GREETING='hello from ops-lab' \
     --from-file=app.properties
   kubectl get configmap web-config -o yaml
   ```

   ```yaml
   apiVersion: v1
   data:
     GREETING: hello from ops-lab
     LOG_LEVEL: info
     app.properties: |
       server.port=8080
       server.mode=production
   kind: ConfigMap
   metadata:
     name: web-config
     namespace: ops-lab
   ```

2. Create a Secret and look closely at how it is stored:

   ```bash
   kubectl create secret generic web-secret \
     --from-literal=DB_PASSWORD='s3cr3t-p@ss' \
     --from-literal=API_TOKEN='tok_live_9f3a'
   kubectl get secret web-secret -o yaml | sed -n '1,10p'
   kubectl get secret web-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
   ```

   ```yaml
   apiVersion: v1
   data:
     API_TOKEN: dG9rX2xpdmVfOWYzYQ==
     DB_PASSWORD: czNjcjN0LXBAc3M=
   kind: Secret
   metadata:
     name: web-secret
     namespace: ops-lab
   type: Opaque
   ```
   ```
   s3cr3t-p@ss
   ```

3. Consume both, as environment variables *and* as a projected volume:

   ```yaml
   # 05-consumer.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: consumer
     namespace: ops-lab
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: consumer
     template:
       metadata:
         labels:
           app: consumer
       spec:
         containers:
           - name: shell
             image: busybox:1.36
             command: ["sh", "-c", "while true; do sleep 30; done"]
             env:
               - name: LOG_LEVEL                     # one explicit key
                 valueFrom:
                   configMapKeyRef:
                     name: web-config
                     key: LOG_LEVEL
               - name: DB_PASSWORD
                 valueFrom:
                   secretKeyRef:
                     name: web-secret
                     key: DB_PASSWORD
             envFrom:
               - configMapRef:                       # every key, as-is
                   name: web-config
                   optional: true
             volumeMounts:
               - name: config
                 mountPath: /etc/app
                 readOnly: true
               - name: creds
                 mountPath: /etc/creds
                 readOnly: true
             resources:
               requests: {cpu: 10m, memory: 16Mi}
               limits:   {cpu: 100m, memory: 64Mi}
         volumes:
           - name: config
             configMap:
               name: web-config
               items:
                 - key: app.properties
                   path: app.properties
           - name: creds
             secret:
               secretName: web-secret
               defaultMode: 0400
   ```

   ```bash
   kubectl apply -f 05-consumer.yaml
   kubectl rollout status deploy/consumer
   POD=$(kubectl get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- env | grep -E 'LOG_LEVEL|GREETING|DB_PASSWORD'
   kubectl exec "$POD" -- sh -c 'ls -l /etc/app /etc/creds; cat /etc/app/app.properties'
   ```

   ```
   LOG_LEVEL=info
   GREETING=hello from ops-lab
   DB_PASSWORD=s3cr3t-p@ss

   /etc/app:
   lrwxrwxrwx    1 root root   21 Sep  3 12:41 app.properties -> ..data/app.properties
   /etc/creds:
   lrwxrwxrwx    1 root root   18 Sep  3 12:41 API_TOKEN -> ..data/API_TOKEN
   lrwxrwxrwx    1 root root   20 Sep  3 12:41 DB_PASSWORD -> ..data/DB_PASSWORD
   server.port=8080
   server.mode=production
   ```

4. Change the ConfigMap and measure what updates and what does not:

   ```bash
   kubectl patch configmap web-config \
     --type merge -p '{"data":{"LOG_LEVEL":"debug","app.properties":"server.port=9090\nserver.mode=canary\n"}}'
   sleep 75
   kubectl exec "$POD" -- sh -c 'echo "ENV:  $LOG_LEVEL"; echo "FILE:"; cat /etc/app/app.properties'
   ```

   ```
   ENV:  info
   FILE:
   server.port=9090
   server.mode=canary
   ```

5. Force the environment variables to refresh the only way that works:

   ```bash
   kubectl rollout restart deployment/consumer
   kubectl rollout status deploy/consumer
   POD=$(kubectl get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- printenv LOG_LEVEL
   ```

   ```
   deployment.apps/consumer restarted
   deployment "consumer" successfully rolled out
   debug
   ```

6. Make a ConfigMap immutable and observe the API server's reaction:

   ```bash
   kubectl create configmap pinned --from-literal=VERSION=1.0.0
   kubectl patch configmap pinned -p '{"immutable":true}'
   kubectl patch configmap pinned --type merge -p '{"data":{"VERSION":"1.0.1"}}'
   ```

   ```
   configmap/pinned created
   configmap/pinned patched
   The ConfigMap "pinned" is invalid: data: Forbidden: field is immutable when `immutable` is set
   ```

7. Reference a key that does not exist, and see the failure mode:

   ```bash
   kubectl set env deployment/consumer --from=configmap/missing-cm --prefix=X_
   kubectl get pods -l app=consumer
   kubectl describe pod -l app=consumer | grep -A3 'Events:'
   ```

   ```
   NAME                       READY   STATUS                       RESTARTS   AGE
   consumer-6b9f7c4d8-2hpvz   0/1     CreateContainerConfigError   0          18s

   Events:
     Type     Reason     Age   From       Message
     ----     ------     ----  ----       -------
     Warning  Failed     6s    kubelet    Error: configmap "missing-cm" not found
   ```

   ```bash
   kubectl rollout undo deployment/consumer
   ```

**Checkpoint questions**

- **Q6.1** — A colleague says Secrets are "encrypted". Correct the statement precisely: what does the API do to the value, and what must a cluster administrator configure for at-rest encryption to be real?
- **Q6.2** — Explain the asymmetry seen in step 4: the mounted file changed, the environment variable did not. What is the mechanism in each case, and roughly how long is the worst-case propagation delay for the volume?
- **Q6.3** — What would have happened in step 4 if the volume had been mounted with `subPath: app.properties` instead of via `items`?
- **Q6.4** — What is the `..data` symlink in the mounted directory for?
- **Q6.5** — Give two operational reasons to mark a ConfigMap `immutable: true`, and describe the update procedure once you have.
- **Q6.6** — Compare `env.valueFrom.configMapKeyRef` with `envFrom.configMapRef`. Which one is safe against a ConfigMap that contains a key named `PATH`, and why?
- **Q6.7** — The Pod in step 7 is `CreateContainerConfigError`, not `CrashLoopBackOff` or `Pending`. What does that distinction tell you about *where* in the Pod lifecycle it failed?
- **Q6.8** — Why does listing Secrets with `kubectl get secret -o yaml` still count as a security event even though the value looks scrambled? Name the RBAC verb you would restrict.

---

## Exercise 7 — Probes, resource requests and QoS

**Steps**

1. Deploy a workload with all three probe types and an explicit resource profile:

   ```yaml
   # 06-probes.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: health
     namespace: ops-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: health
     template:
       metadata:
         labels:
           app: health
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.4-alpine
             ports:
               - name: http
                 containerPort: 80
             lifecycle:
               postStart:
                 exec:
                   command: ["sh", "-c", "echo ok > /usr/share/nginx/html/healthz"]
             startupProbe:
               httpGet: {path: /healthz, port: http}
               periodSeconds: 2
               failureThreshold: 30        # up to 60s to boot
             readinessProbe:
               httpGet: {path: /healthz, port: http}
               periodSeconds: 3
               failureThreshold: 2
             livenessProbe:
               httpGet: {path: /, port: http}
               periodSeconds: 5
               failureThreshold: 3
             resources:
               requests:
                 cpu: 50m
                 memory: 64Mi
               limits:
                 cpu: 50m
                 memory: 64Mi
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: health
     namespace: ops-lab
   spec:
     selector:
       app: health
     ports:
       - port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f 06-probes.yaml
   kubectl rollout status deploy/health
   kubectl get endpointslice -l kubernetes.io/service-name=health \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}={.conditions.ready}{"\n"}{end}'
   ```

   ```
   10.244.1.11=true
   10.244.2.9=true
   ```

2. Read the QoS class the scheduler assigned:

   ```bash
   kubectl get pods -l app=health \
     -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName'
   kubectl get pod nginx-solo -o jsonpath='{.status.qosClass}{"\n"}'
   kubectl run bare --image=busybox:1.36 --restart=Never -- sleep 300
   kubectl get pod bare -o jsonpath='{.status.qosClass}{"\n"}'
   ```

   ```
   NAME                     QOS         NODE
   health-84c6d5b7f9-jr2wq  Guaranteed  lpi-703-worker
   health-84c6d5b7f9-x8t4b  Guaranteed  lpi-703-worker2
   Burstable
   BestEffort
   ```

3. Fail *readiness only*, and watch the endpoint disappear while the container keeps running:

   ```bash
   POD=$(kubectl get pod -l app=health -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- rm /usr/share/nginx/html/healthz
   sleep 10
   kubectl get pod "$POD"
   kubectl get endpointslice -l kubernetes.io/service-name=health \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}={.conditions.ready}{"\n"}{end}'
   kubectl describe pod "$POD" | grep -A2 'Readiness'
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   health-84c6d5b7f9-jr2wq   0/1     Running   0          3m

   10.244.1.11=false
   10.244.2.9=true

   Readiness probe failed: HTTP probe failed with statuscode: 404
   ```

4. Restore readiness:

   ```bash
   kubectl exec "$POD" -- sh -c 'echo ok > /usr/share/nginx/html/healthz'
   sleep 8
   kubectl get pod "$POD"
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   health-84c6d5b7f9-jr2wq   1/1     Running   0          4m
   ```

5. Now fail *liveness* and compare the consequence:

   ```bash
   kubectl exec "$POD" -- sh -c 'mv /usr/share/nginx/html/index.html /tmp/'
   sleep 30
   kubectl get pod "$POD"
   kubectl describe pod "$POD" | grep -E 'Restart Count|Last State|Reason|Liveness probe failed' | head
   ```

   ```
   NAME                      READY   STATUS    RESTARTS      AGE
   health-84c6d5b7f9-jr2wq   1/1     Running   1 (12s ago)   5m

   Last State:     Terminated
     Reason:       Error
     Exit Code:    137
   Restart Count:  1
   Warning  Unhealthy  35s  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 403
   ```

6. Exceed a memory limit and read the kernel's verdict:

   ```yaml
   # 07-oom.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
     namespace: ops-lab
   spec:
     containers:
       - name: stress
         image: polinux/stress
         command: ["stress"]
         args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
         resources:
           requests:
             memory: 50Mi
           limits:
             memory: 100Mi
   ```

   ```bash
   kubectl apply -f 07-oom.yaml
   sleep 20
   kubectl get pod memory-hog
   kubectl describe pod memory-hog | grep -E 'Reason|Exit Code|Restart Count'
   ```

   ```
   NAME         READY   STATUS             RESTARTS      AGE
   memory-hog   0/1     CrashLoopBackOff   2 (14s ago)   38s

       Reason:       OOMKilled
       Exit Code:    137
   Restart Count:    2
   ```

7. Try to schedule something the cluster cannot satisfy:

   ```bash
   kubectl run too-big --image=nginx:1.27.4-alpine \
     --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27.4-alpine","resources":{"requests":{"memory":"64Gi"}}}]}}'
   sleep 5
   kubectl get pod too-big
   kubectl describe pod too-big | sed -n '/Events:/,$p'
   ```

   ```
   NAME      READY   STATUS    RESTARTS   AGE
   too-big   0/1     Pending   0          6s

   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint
       {node-role.kubernetes.io/control-plane: }, 2 Insufficient memory. preemption: 0/3 nodes are available:
       1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
   ```

   ```bash
   kubectl delete pod too-big memory-hog bare --now
   ```

**Checkpoint questions**

- **Q7.1** — State the consequence of a failed readiness probe and of a failed liveness probe, in one sentence each, referring to what you observed in steps 3 and 5.
- **Q7.2** — Why does a `startupProbe` exist at all, given that `initialDelaySeconds` on the liveness probe could delay the first check? What is the failure mode it prevents on a slow-booting JVM application?
- **Q7.3** — Derive the QoS class for each of these and justify: (a) `requests.cpu=100m, limits.cpu=100m, requests.memory=128Mi, limits.memory=128Mi`; (b) `limits.memory=128Mi` only; (c) nothing specified; (d) two containers, one Guaranteed and one Burstable.
- **Q7.4** — Under node memory pressure, in what order does the kubelet evict Pods by QoS class, and where does a Burstable Pod that is *under* its request sit in that order?
- **Q7.5** — Exit code 137 appeared twice, with `Reason: Error` in step 5 and `Reason: OOMKilled` in step 6. What does 137 decompose into, and what distinguishes the two cases?
- **Q7.6** — In step 7 the scheduler reported "2 Insufficient memory" while the nodes had free RAM. Which number is the scheduler actually comparing against, and why is `requests` — not `limits` — the scheduling currency?
- **Q7.7** — Both containers in the `health` Deployment are `Guaranteed`. If you set only `limits` and omitted `requests` entirely, what would the QoS class be and why?

---

## Exercise 8 — The diagnostic loop

This is the exercise that pays for itself. Practise the sequence until it is muscle memory: **get → describe → events → logs → exec/debug**.

**Steps**

1. Manufacture an image failure:

   ```bash
   kubectl create deployment broken --image=nginx:does-not-exist
   sleep 20
   kubectl get pods -l app=broken
   kubectl describe pod -l app=broken | sed -n '/Events:/,$p'
   ```

   ```
   NAME                       READY   STATUS             RESTARTS   AGE
   broken-6d8c47f5b9-lm4zc    0/1     ImagePullBackOff   0          21s

   Events:
     Type     Reason     Age                From               Message
     ----     ------     ----               ----               -------
     Normal   Scheduled  21s                default-scheduler  Successfully assigned ops-lab/broken-...
     Normal   Pulling    20s                kubelet            Pulling image "nginx:does-not-exist"
     Warning  Failed     18s                kubelet            Failed to pull image "nginx:does-not-exist":
       failed to resolve reference "docker.io/library/nginx:does-not-exist": docker.io/library/nginx:does-not-exist:
       not found
     Warning  Failed     18s                kubelet            Error: ErrImagePull
     Normal   BackOff    5s (x2 over 17s)   kubelet            Back-off pulling image "nginx:does-not-exist"
     Warning  Failed     5s                 kubelet            Error: ImagePullBackOff
   ```

2. Manufacture a crash loop, then read the *previous* container's logs:

   ```bash
   kubectl run crasher --image=busybox:1.36 --restart=Always -- \
     sh -c 'echo "starting up"; sleep 5; echo "fatal: config missing" >&2; exit 1'
   sleep 45
   kubectl get pod crasher
   kubectl logs crasher
   kubectl logs crasher --previous
   ```

   ```
   NAME      READY   STATUS             RESTARTS      AGE
   crasher   0/1     CrashLoopBackOff   3 (18s ago)   47s

   starting up
   fatal: config missing

   starting up
   fatal: config missing
   ```

3. Read the backoff progression from the events:

   ```bash
   kubectl get events --field-selector involvedObject.name=crasher --sort-by=.lastTimestamp | tail -6
   ```

   ```
   LAST SEEN   TYPE      REASON      OBJECT        MESSAGE
   62s         Normal    Created     pod/crasher   Created container: crasher
   62s         Normal    Started     pod/crasher   Started container crasher
   35s         Warning   BackOff     pod/crasher   Back-off restarting failed container crasher in pod crasher_ops-lab(...)
   ```

4. Aggregate logs across a whole Deployment, with useful flags:

   ```bash
   kubectl logs -l app=web --all-containers --prefix --tail=3 --timestamps
   kubectl logs deploy/web --since=5m | tail -3
   kubectl logs -f deploy/web --max-log-requests=6 &   # streaming; Ctrl-C or kill to stop
   sleep 3; kill %1
   ```

   ```
   [pod/web-7d9c8b6f45-6dlzs/nginx] 2026-09-03T12:58:11.104Z 10.244.0.5 - - [03/Sep/2026:12:58:11 +0000] "GET / HTTP/1.1" 200 615 "-" "Wget"
   ```

5. Get a shell in a running container, and understand its limits:

   ```bash
   POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -it "$POD" -c nginx -- sh -c 'id; nginx -v; ls /usr/share/nginx/html'
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root),...
   nginx version: nginx/1.27.4
   50x.html  index.html
   ```

6. Attach a debug container to a Pod whose image has no shell tooling:

   ```bash
   kubectl debug -it "$POD" --image=busybox:1.36 --target=nginx -- sh
   ```

   ```sh
   Defaulting debug container name to debugger-7zqm4.
   / # ps aux | head -4
   PID   USER     TIME  COMMAND
       1 root      0:00 nginx: master process nginx -g daemon off;
      29 101       0:00 nginx: worker process
       1 root      0:00 sh
   / # wget -qO- http://localhost:80 | head -2
   <!DOCTYPE html>
   <html>
   / # exit
   ```

   ```bash
   kubectl get pod "$POD" -o jsonpath='{range .spec.ephemeralContainers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
   ```

   ```
   debugger-7zqm4   busybox:1.36
   ```

7. Copy a file out of a container and inspect resource usage:

   ```bash
   kubectl cp "$POD:/etc/nginx/nginx.conf" ./nginx.conf -c nginx
   head -3 ./nginx.conf
   kubectl top pods 2>&1 | head -3
   ```

   ```
   user  nginx;
   worker_processes  auto;

   error: Metrics API not available
   ```

8. Clean up the deliberate failures:

   ```bash
   kubectl delete deploy broken --now
   kubectl delete pod crasher --now
   ```

**Checkpoint questions**

- **Q8.1** — Distinguish `ErrImagePull` from `ImagePullBackOff`. Which one tells you the kubelet has given up retrying at full speed, and what is the backoff behaviour?
- **Q8.2** — Why did `kubectl logs crasher` succeed in step 2 even though the container was not running at that moment? What exactly does `--previous` return, and when is it unavailable?
- **Q8.3** — What is the default maximum interval between restart attempts in `CrashLoopBackOff`, how is it reached, and what resets it?
- **Q8.4** — `kubectl logs deploy/web` printed logs from one Pod, not three, unless you added a selector. Explain what `kubectl logs deploy/...` actually resolves to, and the correct way to tail all replicas.
- **Q8.5** — In step 6, `ps` inside the debug container listed the nginx master process. Which flag caused that, and what would you have seen without it?
- **Q8.6** — Can you remove an ephemeral container from a running Pod? What is the lifecycle consequence of using `kubectl debug` on a production Pod?
- **Q8.7** — `kubectl top pods` failed. What is missing, and — importantly — does that failure affect the scheduler, the HorizontalPodAutoscaler, or both?
- **Q8.8** — You are handed a Pod stuck in `Pending` with no events at all. List, in order, the three checks you would run and what each would distinguish.

---

## Exercise 9 — Declarative management: apply, drift and Server-Side Apply

**Steps**

1. Establish a baseline and confirm the annotation client-side apply leaves behind:

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web \
     -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
     | head -c 120; echo
   ```

   ```
   {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{},"labels":{"app":"web"},"name":"web","na
   ```

2. Introduce drift imperatively, then preview what a re-apply would do:

   ```bash
   kubectl scale deploy/web --replicas=6
   kubectl label deploy web owner=sre                 # a field the manifest never mentions
   kubectl diff -f 02-deploy.yaml
   ```

   ```diff
   diff -u -N /tmp/LIVE-.../apps.v1.Deployment.ops-lab.web /tmp/MERGED-.../apps.v1.Deployment.ops-lab.web
   --- LIVE
   +++ MERGED
   @@ -6,6 +6,7 @@
      labels:
        app: web
   -    owner: sre
      name: web
   @@ -14,7 +15,7 @@
    spec:
   -  replicas: 6
   +  replicas: 3
   ```

3. Re-apply and confirm which drift survived:

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web -o jsonpath='replicas={.spec.replicas} owner={.metadata.labels.owner}{"\n"}'
   ```

   ```
   deployment.apps/web configured
   replicas=3 owner=sre
   ```

4. Prove that removing a field from the manifest deletes it from the live object:

   ```bash
   kubectl apply -f 02-deploy.yaml     # manifest has revisionHistoryLimit: 5
   sed -i '/revisionHistoryLimit/d' 02-deploy.yaml
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web -o jsonpath='{.spec.revisionHistoryLimit}{"\n"}'
   ```

   ```
   deployment.apps/web configured
   10
   ```

5. Switch to Server-Side Apply and inspect the ownership ledger:

   ```bash
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci
   kubectl get deploy web --show-managed-fields -o json \
     | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)\t\(.subresource // "-")"'
   ```

   ```
   deployment.apps/web serverside-applied
   kubectl-client-side-apply   Update   -
   platform-ci                 Apply    -
   kube-controller-manager     Update   status
   ```

6. Create a conflict on purpose:

   ```bash
   kubectl patch deploy web --field-manager=hotfix-operator --type merge -p '{"spec":{"replicas":8}}'
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci
   ```

   ```
   deployment.apps/web patched
   error: Apply failed with 1 conflict: conflict with "hotfix-operator" using apps/v1:
     .spec.replicas
   Please review the fields above--they currently have conflicting field ownership...
   ```

7. Resolve it deliberately:

   ```bash
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci --force-conflicts
   kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   deployment.apps/web serverside-applied
   3
   ```

8. Assemble the same objects with the kustomize support built into kubectl:

   ```yaml
   # kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: ops-lab
   commonLabels:
     managed-by: kustomize
   resources:
     - 02-deploy.yaml
     - 03-svc.yaml
   images:
     - name: nginx
       newTag: 1.27.5-alpine
   ```

   ```bash
   kubectl kustomize . | grep -E 'image:|managed-by' | head
   kubectl apply -k .
   ```

   ```
       managed-by: kustomize
         image: nginx:1.27.5-alpine
   deployment.apps/web configured
   service/web configured
   ```

**Checkpoint questions**

- **Q9.1** — Client-side apply performs a *three-way* merge. Name the three inputs and say which one is stored in the `last-applied-configuration` annotation.
- **Q9.2** — In step 3, `replicas` was reverted but the `owner=sre` label survived. Explain why, using the three inputs from Q9.1.
- **Q9.3** — Step 4 shows `revisionHistoryLimit` returning to `10` after being removed from the file. Would the same have happened if the field had been set with `kubectl patch` instead of having been applied earlier? Why?
- **Q9.4** — What problem does Server-Side Apply solve that the `last-applied-configuration` annotation could not? Name two concrete drawbacks of the annotation approach.
- **Q9.5** — `--force-conflicts` fixed the error in step 7. Describe what it did to `hotfix-operator`'s ownership record, and when using it is the *wrong* answer.
- **Q9.6** — You run a HorizontalPodAutoscaler on `web` and CI applies a manifest containing `replicas: 3` every ten minutes. Describe the failure, and give the correct fix for both client-side and server-side apply workflows.
- **Q9.7** — When is `kubectl replace -f` genuinely correct, and what does it do that `apply` never does?

---

## Exercise 10 — DaemonSets, Jobs and CronJobs

**Steps**

1. Deploy a node-level agent:

   ```yaml
   # 08-daemonset.yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: node-agent
     namespace: ops-lab
   spec:
     selector:
       matchLabels:
         app: node-agent
     template:
       metadata:
         labels:
           app: node-agent
       spec:
         containers:
           - name: agent
             image: busybox:1.36
             command: ["sh", "-c", "while true; do echo \"$(date) heartbeat from $NODE\"; sleep 60; done"]
             env:
               - name: NODE
                 valueFrom:
                   fieldRef:
                     fieldPath: spec.nodeName
             resources:
               requests: {cpu: 10m, memory: 16Mi}
               limits:   {cpu: 50m, memory: 32Mi}
   ```

   ```bash
   kubectl apply -f 08-daemonset.yaml
   sleep 10
   kubectl get ds node-agent
   kubectl get pods -l app=node-agent -o wide --no-headers | awk '{print $1, $7}'
   ```

   ```
   NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
   node-agent   2         2         2       2            2           <none>          10s

   node-agent-4mfq7 lpi-703-worker
   node-agent-t9k2p lpi-703-worker2
   ```

2. Make it run on the control-plane too, by tolerating the taint:

   ```bash
   kubectl patch ds node-agent --type merge -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
   sleep 10
   kubectl get ds node-agent
   ```

   ```
   NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
   node-agent   3         3         3       3            3           <none>          72s
   ```

3. Run a batch Job with parallelism and a retry budget:

   ```yaml
   # 09-job.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: digest
     namespace: ops-lab
   spec:
     completions: 6
     parallelism: 2
     backoffLimit: 3
     ttlSecondsAfterFinished: 300
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: worker
             image: busybox:1.36
             command: ["sh", "-c", "echo processing shard $RANDOM; sleep 5"]
             resources:
               requests: {cpu: 10m, memory: 16Mi}
   ```

   ```bash
   kubectl apply -f 09-job.yaml
   kubectl get job digest -w &
   sleep 25; kill %1
   kubectl get pods -l job-name=digest --no-headers | awk '{print $1, $3}'
   ```

   ```
   NAME     STATUS     COMPLETIONS   DURATION   AGE
   digest   Running    0/6           2s         2s
   digest   Running    2/6           9s         9s
   digest   Running    4/6           16s        16s
   digest   Complete   6/6           23s        23s

   digest-2jx8p Completed
   digest-6vkzq Completed
   digest-9dt4m Completed
   digest-hcn7w Completed
   digest-mq5rl Completed
   digest-xw2fb Completed
   ```

4. Make a Job fail and observe `backoffLimit` doing its work:

   ```bash
   kubectl create job doomed --image=busybox:1.36 -- sh -c 'exit 3'
   kubectl patch job doomed --type merge -p '{"spec":{"backoffLimit":2}}' 2>&1 | tail -1
   sleep 60
   kubectl get job doomed
   kubectl get pods -l job-name=doomed --no-headers | wc -l
   kubectl describe job doomed | grep -E 'Pods Statuses|Warning'
   ```

   ```
   NAME     STATUS   COMPLETIONS   DURATION   AGE
   doomed   Failed   0/1           58s        60s

   7
   Pods Statuses:  0 Active (0 Ready) / 0 Succeeded / 7 Failed
     Warning  BackoffLimitExceeded  4s   job-controller  Job has reached the specified backoff limit
   ```

5. Schedule recurring work:

   ```bash
   kubectl create cronjob heartbeat \
     --image=busybox:1.36 \
     --schedule='*/1 * * * *' \
     -- /bin/sh -c 'date -Is; echo "cron tick ok"'
   kubectl get cronjob heartbeat
   sleep 130
   kubectl get jobs -l batch.kubernetes.io/cronjob-name=heartbeat
   kubectl logs job/$(kubectl get jobs -l batch.kubernetes.io/cronjob-name=heartbeat \
     -o jsonpath='{.items[0].metadata.name}')
   ```

   ```
   NAME        SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
   heartbeat   */1 * * * *   <none>     False     0        <none>          3s

   NAME                 STATUS     COMPLETIONS   DURATION   AGE
   heartbeat-29360281   Complete   1/1           4s         2m
   heartbeat-29360282   Complete   1/1           3s         62s

   2026-09-03T13:41:02+00:00
   cron tick ok
   ```

6. Trigger an out-of-band run, and suspend the schedule:

   ```bash
   kubectl create job manual-run --from=cronjob/heartbeat
   kubectl patch cronjob heartbeat -p '{"spec":{"suspend":true}}'
   kubectl get cronjob heartbeat -o jsonpath='suspend={.spec.suspend}{"\n"}'
   ```

   ```
   job.batch/manual-run created
   cronjob.batch/heartbeat patched
   suspend=true
   ```

7. Inspect the history-retention knobs:

   ```bash
   kubectl get cronjob heartbeat \
     -o jsonpath='{.spec.successfulJobsHistoryLimit}/{.spec.failedJobsHistoryLimit}/{.spec.concurrencyPolicy}{"\n"}'
   ```

   ```
   3/1/Allow
   ```

**Checkpoint questions**

- **Q10.1** — In step 1 the DaemonSet reported `DESIRED: 2` on a three-node cluster, and `3` after step 2. Explain what computes `DESIRED` and why a DaemonSet has no `replicas` field.
- **Q10.2** — What is the difference between a Job's `completions` and `parallelism`? What does a Job with `completions` unset but `parallelism: 4` mean?
- **Q10.3** — Which values of `restartPolicy` are legal in a Job's Pod template, and which one makes `backoffLimit` count *container* restarts rather than Pod failures?
- **Q10.4** — Step 4 produced 7 failed Pods against `backoffLimit: 2`. Explain the discrepancy — what did the `kubectl patch` on a Job actually do?
- **Q10.5** — What is `ttlSecondsAfterFinished` for, and what happens to the Job's Pods and logs when it fires?
- **Q10.6** — A CronJob's controller missed several schedules while the control plane was down. What determines whether those runs are executed late or skipped entirely, and what is `startingDeadlineSeconds`?
- **Q10.7** — Compare the three `concurrencyPolicy` values and give a workload that requires each.
- **Q10.8** — Why is `kubectl create job --from=cronjob/...` preferable to copying the Job manifest by hand for an out-of-hours manual run?

---

## Exercise 11 — Capstone

Do this one without looking anything up. Twenty minutes, one namespace, no imperative shortcuts except for generating manifests.

**Steps**

1. Create namespace `capstone` and make it your default context namespace.
2. Author a single YAML file containing:
   - a ConfigMap `site` with a key `index.html` whose value is `<h1>703.2 capstone</h1>`;
   - a Secret `site-auth` with `TOKEN=abc123`;
   - a Deployment `site` with 3 replicas of `nginx:1.27.5-alpine`, mounting the ConfigMap at `/usr/share/nginx/html`, exposing `TOKEN` as an environment variable, with `requests == limits` (`50m` CPU / `64Mi` memory), a readiness probe on `/`, and `maxUnavailable: 0`;
   - a ClusterIP Service `site` on port `80` targeting a *named* container port.
3. Apply it with `--server-side --field-manager=capstone`.
4. Verify: 3 ready endpoints, the correct QoS class, the served body matches the ConfigMap, and the environment variable is present.
5. Roll the image to `nginx:1.27.4-alpine`, annotate the change cause, confirm two ReplicaSets exist, then roll back and confirm the image.
6. Change the ConfigMap's `index.html`, and get the change served by all three replicas — deliberately, not by waiting.
7. Produce a one-line report:

   ```bash
   kubectl get deploy site \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas,GEN:.metadata.generation'
   ```

**Checkpoint questions**

- **Q11.1** — In step 6, why is `kubectl rollout restart` the correct instrument rather than editing the Deployment's image or deleting Pods, and what does it change in the Pod template to force the rollout?
- **Q11.2** — `.metadata.generation` and `.status.observedGeneration` differ transiently during a rollout. How would you use that pair as a machine-readable "is the rollout finished" check in a CI pipeline, and what does `kubectl rollout status` use?
- **Q11.3** — With `maxUnavailable: 0` and `maxSurge` unset (default 25%), how many Pods exist at peak during the step-5 rollout of 3 replicas?

---

## Cleanup

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace ops-lab capstone --wait=false
kind delete cluster --name lpi-703
```

```
Context "kind-lpi-703" modified.
namespace "ops-lab" deleted
namespace "capstone" deleted
Deleting cluster "lpi-703" ...
Deleted nodes: ["lpi-703-control-plane" "lpi-703-worker" "lpi-703-worker2"]
```

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 0

**A0.1** — No. The `ROLES` column is rendered by kubectl from Node **labels** matching `node-role.kubernetes.io/<role>` (plus the legacy `kubernetes.io/role`). Roles are a labelling convention, not an API field; nothing in the control plane enforces behaviour based on them. What *does* change behaviour is the taint (A0.2) and the fact that the control-plane components run there as static Pods.

**A0.2** — The taint `node-role.kubernetes.io/control-plane:NoSchedule` makes the scheduler refuse to place any Pod on that node unless the Pod carries a matching toleration. `NoSchedule` affects scheduling only — already-running Pods are not evicted (that would be `NoExecute`). A Pod lands there anyway if its spec contains, for example:

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

That is exactly what Exercise 10 step 2 added, and why `DESIRED` went from 2 to 3.

**A0.3** — kubectl embeds kustomize as a library so that `kubectl apply -k` / `kubectl kustomize` work with no extra binary. The version is reported because the vendored kustomize lags the standalone release: a `kustomization.yaml` using a newer transformer may fail against the vendored one, and knowing the number tells you whether to install standalone `kustomize` instead.

### Exercise 1

**A1.1** — Precedence: (1) the `--kubeconfig` flag; (2) the `KUBECONFIG` environment variable, which may be a colon-separated *list* that is merged, first file winning per key; (3) `$HOME/.kube/config`. For a single command: `kubectl --kubeconfig=/path/to/other.yaml get pods`, or `KUBECONFIG=/path/to/other.yaml kubectl get pods`. Use `kubectl config use-context` / `--context <name>` to switch contexts within one file.

**A1.2** — `api-versions` lists group/version strings only (`apps/v1`, `batch/v1`, `discovery.k8s.io/v1`). `api-resources` lists the *resources* served by those groups, with kind, short names, namespaced flag, and permitted verbs. To find a CRD called `Certificate` and its short name you need `api-resources` (e.g. `kubectl api-resources | grep -i certificate` → `certificates cert cert-manager.io/v1 true Certificate`). Both are served from the discovery endpoints (`/api`, `/apis`) and reflect *this* cluster, including CRDs and aggregated APIs.

**A1.3** — `kubectl explain` reads the OpenAPI schema published by the API server you are connected to. It therefore describes the exact versions installed there, including CRDs supplied by operators that have no upstream documentation at all, and it will not show you fields that were added in a newer release than the cluster runs. Public docs describe *a* version; `explain` describes *yours*.

**A1.4** — The identity in the active kubeconfig context (`AUTHINFO` column) — for kind, a cluster-admin client certificate, hence blanket `yes`. To check another subject you impersonate it: `kubectl auth can-i list secrets --as=system:serviceaccount:ops-lab:default -n ops-lab`, or `--as-group=`. Impersonation itself requires the `impersonate` verb, which cluster-admin has.

### Exercise 2

**A2.1** — `--dry-run=client` never contacts the API server for validation: it renders the object locally, so it cannot catch unknown fields against the live schema, admission-webhook rejections, defaulting, quota violations, or name collisions. `--dry-run=server` sends the object through the full request pipeline — decoding, validation, defaulting, mutating and validating admission — and returns the object the server *would* have persisted, without writing to etcd. Use server-side dry run to test admission policy; use client-side to scaffold YAML offline.

**A2.2** — `kube-scheduler`. The Pod object is written to etcd by the API server **before** any scheduling decision, with `.spec.nodeName` empty and `status.phase: Pending`. The scheduler watches for such Pods, runs its filter/score cycle, and writes the decision by creating a Binding (which sets `.spec.nodeName`). Only then does the kubelet on that node notice the Pod and start containers. This is why a Pod can exist, be listed, and be described while no container has ever run.

**A2.3** — `Always`. Omitted, `restartPolicy` defaults to `Always` on a Pod. For a bare Pod that means the kubelet restarts the container in place forever if it exits — you get `CrashLoopBackOff` rather than a terminal state. With `restartPolicy: Never` the Pod reaches `Failed` or `Succeeded` and stays there. For batch-style bare Pods, always set it explicitly; note that Jobs only permit `Never` or `OnFailure`.

**A2.4** — Deleting a namespace deletes every namespaced object inside it, cascading. The namespace object carries `spec.finalizers: ["kubernetes"]`; the namespace controller must delete all contents and then remove the finalizer before the object disappears. `Terminating` persists while any contained resource refuses to go — a Pod with a long `terminationGracePeriodSeconds`, a PVC held by a finalizer, or (classically) a CRD whose aggregated API server is down so its resources cannot be enumerated. Diagnose with `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns> --show-kind --ignore-not-found`.

**A2.5** — (1) If the node hosting the Pod is drained, dies or is deleted, nothing recreates the Pod elsewhere — it is simply gone. (2) If the container exits permanently and `restartPolicy: Never`, nothing replaces it. Also: no rolling update path, no scaling, no `pod-template-hash` history, and it will not be adopted by a Service rollout strategy. Bare Pods are for debugging and one-shot tasks only.

### Exercise 3

**A3.1** — Labels are *identifying* metadata used by selectors — the API server indexes them and controllers query on them; keep them short and low-cardinality (`app`, `tier`, `env`, `version`, `app.kubernetes.io/name`). Annotations are *non-identifying* metadata for tools and humans — never selectable, may be large and arbitrary (URLs, JSON, checksums, e-mail addresses). Real examples: label `app.kubernetes.io/component=api`; annotation `kubectl.kubernetes.io/last-applied-configuration` or `prometheus.io/scrape: "true"`.

**A3.2** — `kubectl get pods -l 'tier=backend,env=prod,app notin (cache)'` — comma is a logical AND across all terms, and equality-based and set-based requirements can be mixed in one expression.

**A3.3** — Label selectors are served from an index the API server maintains over `metadata.labels`, so a selector query does not require scanning every object; the label syntax is deliberately restricted to make that index cheap. Field selectors are *not* generically indexed — only a fixed set of fields per resource is supported (for Pods: `metadata.name`, `metadata.namespace`, `spec.nodeName`, `spec.schedulerName`, `status.phase`, `status.podIP`, `spec.restartPolicy`, `spec.serviceAccountName`). Anything else is rejected with `BadRequest` rather than silently doing a full scan. Annotations are excluded from both, by design, because they are unbounded in size and cardinality.

**A3.4** — Immutability keeps the controller's ownership set stable. If a live Deployment's selector could change, the existing ReplicaSets and Pods would instantly stop matching and become orphans that no controller manages, while the Deployment would spin up a full new set — a silent doubling of capacity with unmanaged leftovers. The procedure: create a *new* Deployment with the new selector alongside the old one, shift traffic (the Service selector is mutable), then delete the old Deployment. `kubectl replace --force` also works but deletes and recreates, causing full downtime.

**A3.5** — A label value must be 63 characters or fewer, may be empty, and if non-empty must begin and end with an alphanumeric (`[a-z0-9A-Z]`) with dashes, underscores, dots and alphanumerics in between. Keys may optionally have a DNS-subdomain prefix (≤253 chars) followed by `/`. A URL fails on `:` and `//`, which are not permitted characters — that is why the runbook URL in step 5 went into an annotation.

### Exercise 4

**A4.1** — `pod-template-hash` is a hash of the Deployment's `.spec.template`, computed by the Deployment controller and appended both to the ReplicaSet's name and to a label added to the ReplicaSet's `.spec.selector`, its `.metadata.labels`, and every Pod it creates. Without it, all ReplicaSets belonging to one Deployment would share an identical selector (`app=web`) and each would count *all* the Pods, including the other revision's — a rolling update would be impossible because scaling up the new RS would make the old RS believe it was over-replicated and delete the new Pods. The hash partitions the Pod population per revision.

**A4.2** — `maxUnavailable: 0` and `maxSurge: 1`. The controller may add exactly one extra Pod above `replicas` and may not take any existing Pod below the desired count until a replacement is Ready. Because the new Pod never becomes Ready (`ImagePullBackOff`), the controller never proceeds — 3 healthy + 1 broken, indefinitely, and `rollout status` times out. With `maxUnavailable: 1` the controller would have been permitted to terminate a healthy Pod first, so a broken image would have cost you a third of your serving capacity before the rollout stalled. `maxUnavailable: 0` is the safe production default for stateless HTTP services.

**A4.3** — From the `kubernetes.io/change-cause` annotation on the Deployment's Pod template at the time the revision was created; the Deployment controller copies the Deployment's annotations onto the new ReplicaSet, and `rollout history` reads it back from the ReplicaSet. Revision 1 was created by `kubectl apply` with no such annotation. The old `--record` flag that populated it automatically is deprecated; annotate explicitly, ideally with the Git commit SHA.

**A4.4** — `undo` does not delete anything. It reads the target ReplicaSet's Pod template (the previous revision by default, or `--to-revision=N`), writes it back into the Deployment's `.spec.template`, and lets the normal rolling-update machinery run forward. The consequence is that the *old* revision number is not reused: after undoing from revision 3 back to revision 2's template, `rollout history` shows revisions 1, 3 and a new 4 — the reverted-to revision is renumbered as the newest. `--to-revision=0` means "the previous one".

**A4.5** — Default cascade is `background`: deleting the ReplicaSet sets `deletionTimestamp` on it and the garbage collector deletes every object whose `ownerReferences` point at it — the three Pods. The Deployment controller then finds no ReplicaSet for its current template hash, creates a new one with the *same* hash (the template did not change), and that ReplicaSet creates three fresh Pods. With `--cascade=orphan`, the GC strips the `ownerReferences` from the Pods instead of deleting them. The recreated ReplicaSet then **adopts** them: a ReplicaSet adopts any Pod in its namespace that matches its selector (including `pod-template-hash`) and has no controller owner reference, so it reaches its desired count without creating anything. Note the AGE column — the Pods are the originals.

**A4.6** — The default is `10`. What is retained is the *old ReplicaSet objects* with `replicas: 0` — they hold nothing but the Pod template, which is what makes rollback possible. Setting it to `0` deletes old ReplicaSets immediately and makes `kubectl rollout undo` impossible: there is no stored template to revert to. The cost of a high value is etcd objects and clutter in `kubectl get rs`, which is trivial; keep at least 2–3.

**A4.7** — The next `apply` scales the Deployment back to 3, because `replicas` is present in the manifest and therefore in `last-applied-configuration` — the merge sees the file value as authoritative. To co-manage with an HPA, **remove `replicas` from the manifest entirely**: with client-side apply, a field absent from both the file and the last-applied annotation is left untouched on the live object. With Server-Side Apply the equivalent is to not include `replicas` in the applied configuration, leaving `.spec.replicas` owned by the HPA controller's field manager. Leaving `replicas` in the file while an HPA is active produces a fight between two controllers that manifests as periodic mass Pod churn.

### Exercise 5

**A5.1** — In the Pod template: `ports: [{name: http, containerPort: 80}]`. `targetPort` accepts either a number or the *name* of a port declared on the container. If you rename the container port to `web` without updating the Service, the EndpointSlice controller cannot resolve the name and the endpoints get no port — traffic breaks even though selectors still match. Named ports are worth it because they let heterogeneous Pods behind one Service listen on different numbers.

**A5.2** — (1) `web` has 0 dots, which is fewer than `ndots:5`, so the resolver tries the `search` suffixes first: `web.ops-lab.svc.cluster.local` matches immediately at CoreDNS (`10.96.0.10`), returning the Service's ClusterIP `10.96.183.24`. (2) The packet leaves the Pod addressed to `10.96.183.24:8080`. That address is virtual — nothing owns it, nothing answers ARP for it. `kube-proxy` has programmed rules (iptables or nftables, or an eBPF equivalent from the CNI) on every node that DNAT the destination to one of the ready endpoint addresses, chosen roughly at random. (3) The packet that reaches the wire carries destination `10.244.x.y:80` — a Pod IP and the *container* port, not the Service port. Return traffic is un-NATed by conntrack. Check the mode with `kubectl -n kube-system get cm kube-proxy -o yaml | grep -A1 mode`.

**A5.3** — `Endpoints` is a single object per Service holding *every* backend address in one list. At a few thousand endpoints that object becomes large, and any single Pod change rewrites and re-broadcasts the whole thing to every node — an O(n²) traffic pattern during rollouts. `EndpointSlice` (`discovery.k8s.io/v1`) shards the same information into slices of ~100 endpoints each, so a change touches one slice; it also adds per-endpoint `conditions` (`ready`, `serving`, `terminating`), topology hints for topology-aware routing, and dual-stack support via `addressType`. The control plane still mirrors slices back into legacy `Endpoints` objects for compatibility, but `Endpoints` is deprecated and new code should read EndpointSlices.

**A5.4** — StatefulSet workloads: databases and quorum systems (Cassandra, etcd, Kafka, PostgreSQL replicas) where a client must address a *specific* member, not a random one. A ClusterIP would load-balance a write meant for the primary onto a replica. With `clusterIP: None` the DNS query returns all Pod A records, and combined with a StatefulSet each Pod also gets a stable per-Pod name (`web-0.web-headless.ops-lab.svc.cluster.local`) that survives rescheduling. Headless Services are also how client-side load balancers (gRPC) discover the full endpoint list.

**A5.5** — `30000–32767` by default, configurable with the API server's `--service-node-port-range`. Requesting `nodePort: 8080` fails validation: `The Service "web" is invalid: spec.ports[0].nodePort: Invalid value: 8080: provided port is not in the valid range. The range of valid ports is 30000-32767`. The restriction avoids colliding with host services and with the ephemeral port range.

**A5.6** — The Service object is a stable allocation (ClusterIP and nodePort are reserved for its lifetime), but it is only a *specification*. The EndpointSlice controller recomputes the backing set whenever the selector or Pod labels change; with `app=web-typo` matching nothing, it emptied the slice. kube-proxy then removes the DNAT rules for that ClusterIP/nodePort, so connections get rejected or time out immediately, and DNS still resolves the name. "Service exists, ClusterIP assigned, zero endpoints" is the single most common Kubernetes networking failure — check `kubectl get endpointslice -l kubernetes.io/service-name=<svc>` before anything else, and remember the two causes: selector mismatch, or all Pods failing readiness.

**A5.7** — The **API server** proxied it. `kubectl port-forward` opens a streaming connection (SPDY/WebSocket) to the `pods/portforward` subresource; the API server forwards it to the kubelet on that node, which sets up the tunnel into the Pod's network namespace. kube-proxy, Services and EndpointSlices are not involved at all, and neither is the Pod's readiness state — which is why port-forward reaches a Pod that a Service refuses to route to. That is also why it is a debugging tool: it is a single-Pod, single-user, unencrypted-at-the-far-end tunnel bound to your workstation, it dies with your shell, it has no load balancing and no HA, and it requires API credentials with `create` on `pods/portforward`.

### Exercise 6

**A6.1** — Nothing is encrypted. `data` values are **base64-encoded**, which is a transport encoding, not a cipher — anyone with `get` on the Secret has the plaintext, as step 2 demonstrated. What Secrets *do* differently from ConfigMaps: they are stored with a distinct type, kubelet mounts them into `tmpfs` (never on disk), they are omitted from some log/describe paths, and they can be gated separately in RBAC. For real at-rest protection the cluster administrator must configure an `EncryptionConfiguration` on the API server (`--encryption-provider-config`) with a KMS or `aescbc`/`secretbox` provider, and re-write existing Secrets; alternatively use an external store (Vault, cloud secret manager) via CSI driver or operator.

**A6.2** — Environment variables are materialised **once**, by the kubelet, when the container is created; they are ordinary process environment and there is no mechanism to mutate a running process's environment. A ConfigMap/Secret **volume** is projected by the kubelet, which watches the object and re-writes the backing directory on change, so a process that re-reads the file sees the new content. Worst case delay ≈ kubelet sync period (default 1 minute) + the kubelet's ConfigMap/Secret cache TTL — budget on the order of one to two minutes, and note that the *application* still has to notice (inotify, SIGHUP, or polling).

**A6.3** — Nothing would have updated. A `subPath` mount resolves to a single file bind-mounted at container start; it is not part of the atomically-swapped projected directory, so it never receives updates for the lifetime of the container. This is a classic production trap: teams use `subPath` to drop a config file into a directory that already has content, then wonder why config reloads stopped working. Use `items` with a dedicated mount directory (as in step 3), or accept that you must restart.

**A6.4** — Atomicity. The kubelet writes each version into a timestamped hidden directory (`..2026_09_03_12_41_07.1839284`), then swaps a single symlink `..data` to point at it, and the visible entries are symlinks through `..data`. Because a symlink swap is atomic, an application can never observe a half-written set of keys — either all old or all new. It also means the update is a symlink change, not an in-place write, which affects how you set up inotify watches.

**A6.5** — (1) Performance and scale: the kubelet does not need to watch an immutable object, which removes a per-Pod watch from the API server — meaningful on clusters with thousands of Pods. (2) Safety: it makes accidental in-place edits impossible, so a config change cannot silently alter running Pods' mounted files with no rollout, no revision history and no rollback. The update procedure becomes: create a *new* ConfigMap with a version suffix (`web-config-v2`, or a content hash — this is what kustomize's `configMapGenerator` does automatically), point the Deployment's template at it, and roll. That change to the template triggers a normal, revertible rollout.

**A6.6** — `env.valueFrom.configMapKeyRef` imports exactly one key under a name you choose; `envFrom.configMapRef` imports *every* key using the key names verbatim. Only the explicit form is safe: with `envFrom`, a key named `PATH`, `HOME` or `LD_PRELOAD` in the ConfigMap silently overwrites the container's environment and can break or subvert the process. `envFrom` also skips keys that are not valid environment-variable names, reporting them as an `InvalidVariableNames` event rather than failing — a silent partial import. Use `envFrom` only for ConfigMaps you fully control, and prefer prefixes (`envFrom: [{prefix: APP_, configMapRef: ...}]`).

**A6.7** — It failed *after* scheduling but *before* the container was created. The Pod is bound to a node (so it is not `Pending`), the kubelet accepted it and tried to assemble the container's configuration — environment, mounts — and could not resolve a reference, so no container image was ever started. Hence `CreateContainerConfigError`, distinct from `CrashLoopBackOff` (the container started and exited) and from `Pending` (never scheduled). The kubelet retries, so fixing the ConfigMap resolves it without recreating the Pod. `CreateContainerError` is the sibling for runtime-level failures such as a bad command path.

**A6.8** — Because `get` on a Secret returns the plaintext to anyone who can decode base64 — the encoding provides zero access control. The verbs to restrict are `get`, `list` and `watch` on `secrets`; note that `list` alone is enough to read every value, since a list response embeds the full objects, so granting `list` without `get` protects nothing. Prefer per-Secret `resourceNames` in Roles, service-account-scoped access, and audit logging on the `secrets` resource.

### Exercise 7

**A7.1** — Readiness: the Pod's `Ready` condition flips to false and it is removed from every Service's endpoints, so it receives no new traffic — but the container keeps running and is not restarted, which is exactly what you want while a process is warming a cache or is temporarily overloaded. Liveness: the kubelet kills the container and restarts it in place per the Pod's `restartPolicy`; the Pod object, its name, its node and its IP are unchanged, and `RESTARTS` increments.

**A7.2** — `initialDelaySeconds` forces you to pick one number that must be larger than the *worst* boot you ever expect, which means genuine hangs also go undetected for that entire period. A `startupProbe` decouples the two: while it is failing, the liveness and readiness probes are suspended entirely; once it succeeds it never runs again and the aggressive liveness probe takes over. A JVM app that occasionally takes 4 minutes to warm up can therefore have `startupProbe: failureThreshold: 30, periodSeconds: 10` (5 minutes of grace) together with `livenessProbe: periodSeconds: 5, failureThreshold: 3` (15-second detection thereafter). Without it, you would need `initialDelaySeconds: 300` on the liveness probe and would be blind to hangs for five minutes after every restart.

**A7.3** — (a) **Guaranteed**: every container has CPU and memory limits, and requests equal limits for both. (b) **Burstable**: at least one request or limit is set but the Guaranteed conditions are not met. Note the defaulting — a container with only `limits.memory` gets `requests.memory` defaulted to the limit, but with no CPU limit set the container is not Guaranteed. (c) **BestEffort**: no requests and no limits on any container. (d) **Burstable**: the class is a property of the whole Pod, and *every* container (init containers included) must satisfy the Guaranteed conditions; one Burstable container demotes the Pod.

**A7.4** — Under node memory pressure the kubelet ranks eviction candidates by, first, whether the Pod's memory usage exceeds its request, and then by Pod priority and by how far usage exceeds the request. In practice: **BestEffort first** (no request, so any usage exceeds it), then **Burstable Pods that are over their request**, and **Guaranteed last** — a Guaranteed Pod is only evicted if nothing else can free memory, or if it exceeds its own limit (in which case the kernel OOM-kills the container rather than the kubelet evicting the Pod). A Burstable Pod using *less* than its request is treated as well-behaved and sits alongside Guaranteed at the bottom of the kill list; this is the concrete reason to set honest requests.

**A7.5** — 137 = 128 + 9, i.e. the process was terminated by signal 9 (`SIGKILL`). In step 5 the kubelet sent the kill because the liveness probe failed (it sends `SIGTERM` first and escalates to `SIGKILL` after the grace period), and the container status shows `Reason: Error`. In step 6 the **kernel's** cgroup OOM killer terminated the process for exceeding the memory limit, and the CRI reports it back so the status reads `Reason: OOMKilled`. Same exit code, entirely different remediation: fix the health endpoint versus raise the limit or fix the leak.

**A7.6** — The scheduler compares the Pod's **requests** against the node's *allocatable* capacity minus the **sum of requests** of all Pods already assigned to that node. It never looks at actual utilisation, which is why a node with 6 GiB free RAM can still report "Insufficient memory". Requests are the scheduling currency because they are the only number that is a *reservation*: limits are permissions to burst, and if the scheduler packed by limits it would either drastically under-utilise nodes (everyone reserving their peak) or over-commit unpredictably. The corollary is that a Pod with no request can be scheduled onto any node, contributes nothing to the accounting, and is the first thing evicted.

**A7.7** — Still **Guaranteed**. When a container specifies a limit but no request, the API server defaults the request to the limit. So `limits: {cpu: 50m, memory: 64Mi}` with no requests block yields requests equal to limits for both resources — the Guaranteed condition. (Contrast with A7.3(b), where only *memory* had a limit: the missing CPU limit is what prevented Guaranteed there.)

### Exercise 8

**A8.1** — `ErrImagePull` is the immediate result of a failed pull attempt — registry unreachable, tag not found, authentication rejected. `ImagePullBackOff` means the kubelet has entered exponential backoff between retries after repeated failures: it starts around 10 seconds and doubles up to a cap of 5 minutes. The practical consequence is that after you fix the underlying problem (push the tag, add the `imagePullSecret`), recovery may take up to five minutes; deleting the Pod forces an immediate retry.

**A8.2** — The kubelet retains the terminated container's log file on the node until the container is garbage-collected, so `kubectl logs` on a Pod in backoff serves the last completed container's output. `--previous` (`-p`) explicitly asks for the log of the *prior* instance, which is what you need when the container has already restarted and the current instance has produced nothing yet. It is unavailable when there has been no previous instance, or after the node's log rotation / container GC has removed it (`previous terminated container "x" in pod "y" not found`) — which is why crash diagnosis depends on shipping logs off-node.

**A8.3** — 5 minutes (300 s). The kubelet starts at 10 s and doubles on each consecutive failure: 10, 20, 40, 80, 160, 300, 300… The timer resets after the container has run successfully for 10 minutes. This is why a Pod that crashes every 3 minutes never reaches the cap and never appears in `CrashLoopBackOff` for long — and why a `RESTARTS` count that climbs slowly is often more alarming than one stuck in backoff.

**A8.4** — `kubectl logs deploy/web` resolves the Deployment to its selector, picks **one** Pod, and streams that. It is a convenience, not an aggregation. To cover all replicas use a label selector: `kubectl logs -l app=web --all-containers --prefix --max-log-requests=10`. `--prefix` is essential because without it you cannot tell which Pod emitted a line, and `--max-log-requests` (default 5) must be raised above the replica count or the command errors out.

**A8.5** — `--target=nginx`. It puts the ephemeral container in the target container's **process namespace**, so it sees and can signal the target's processes and inspect `/proc/1/`. Without `--target` the debug container shares only the Pod's network and IPC namespaces: `curl localhost` still works, but `ps` shows only the debug container's own processes. Note the target's *filesystem* is still separate — to read the target's files use `/proc/1/root/...` from the debug container.

**A8.6** — No. Ephemeral containers can be added to a running Pod but never removed or restarted; they have no probes, no resources, and no lifecycle actions, and they persist in `.spec.ephemeralContainers` for the Pod's lifetime. Consequences on production: the Pod spec is permanently annotated with the debug session (visible in audits), the debug image's resource usage is unaccounted for against the Pod's limits at the Pod QoS level, and the only way to remove it is to delete and recreate the Pod. Prefer `kubectl debug --copy-to=web-debug` on a copy for anything invasive.

**A8.7** — The `metrics-server` Deployment (or another provider of the `metrics.k8s.io` aggregated API) is not installed; `kind` does not ship it. It affects the **HorizontalPodAutoscaler** — which reads `metrics.k8s.io` and will report `unknown` for resource metrics and refuse to scale — and `kubectl top`. It does **not** affect the scheduler, which makes decisions from `requests` in the Pod spec and node allocatable, never from live utilisation. Confusing these is a common interview trap: a cluster with no metrics still schedules perfectly.

**A8.8** — (1) `kubectl describe pod <name>` — if `Events` is genuinely empty *and* `Node:` is empty, the scheduler has not even attempted it, which points at a missing/failed scheduler or a `schedulerName` referring to a scheduler that does not exist. (2) `kubectl get events -A --sort-by=.lastTimestamp | grep <name>` — events default to a 1-hour TTL, so an old Pod's `FailedScheduling` may have expired; checking cluster-wide also catches quota events on the namespace (`exceeded quota`). (3) `kubectl get pod <name> -o yaml` and read `.spec` — unschedulable `nodeSelector`/`nodeAffinity`, unsatisfiable `topologySpreadConstraints`, a `priorityClassName` that does not exist, or a PVC in `Pending` because no StorageClass can bind it (check with `kubectl get pvc`). Those three separate "nobody is scheduling", "somebody tried and failed", and "the spec is unsatisfiable".

### Exercise 9

**A9.1** — The three inputs are: (1) the **last-applied configuration**, stored in the `kubectl.kubernetes.io/last-applied-configuration` annotation on the live object — this is what the annotation holds; (2) the **new manifest** you are applying; (3) the **live object** as it currently exists on the server. The patch is computed as: fields present in (1) but absent from (2) are *deleted*; fields in (2) are *set*; fields present only in (3) are *left alone*.

**A9.2** — `replicas: 3` is present in both the last-applied annotation and the new manifest, so the merge asserts the manifest's value and overwrites the live `6`. `owner=sre` appears only in the live object — it was never in any applied configuration — so rule three applies and the field is preserved. This is the rule that lets an HPA, a service mesh injector or an operator add fields to an object that CI also applies, without a fight, *provided* the manifest never mentions those fields.

**A9.3** — No. The revert happened only because `revisionHistoryLimit: 5` was in the *previous* applied configuration, so removing it from the file made the merge compute a deletion, and the API server then re-applied its default of `10`. Had the field been set with `kubectl patch` or `kubectl edit`, it would never have entered the annotation, so removing it from the file would compute no deletion and the patched value would survive indefinitely. This asymmetry — "apply can only delete what apply previously set" — is the source of a great deal of undeleted cruft on long-lived objects.

**A9.4** — Server-Side Apply moves conflict detection into the API server and tracks, per field, *which manager owns it* in `.metadata.managedFields`. Two drawbacks of the annotation approach it fixes: (1) the annotation is a full copy of the manifest stored on the object, which doubles the object's size and can exceed the 256 KB annotation limit on large CRs; and (2) merge resolution happens on the *client*, so different kubectl versions and other tools (Helm, operators) compute different patches, and nothing detects that two actors are both writing the same field — the last writer silently wins with no error. SSA turns that silent overwrite into the explicit conflict you saw in step 6.

**A9.5** — `--force-conflicts` transfers ownership of the conflicting fields to your field manager and removes them from `hotfix-operator`'s entry in `managedFields`; your value is written. It is the right answer when you *are* the authoritative owner and the other manager was a one-off human patch. It is the **wrong** answer when the other manager is an active controller that will keep writing the field — an HPA on `.spec.replicas`, a mesh injector on the Pod template, a cert manager on a Secret. There you will just start a write-loop; the correct fix is to remove the field from your applied configuration so the controller keeps ownership.

**A9.6** — The failure: every ten minutes CI resets `replicas` to 3, the HPA observes load and scales back up, and you get a sawtooth of Pod churn — capacity oscillating, connections dropped on every scale-down, and rollout events flooding the namespace. Fix, client-side: delete `replicas` from the manifest **and** clear it from the last-applied annotation (achieved by applying the file once without the field, which triggers the deletion described in A9.3, then letting the HPA set it — or by re-establishing the baseline with `kubectl apply --server-side`). Fix, server-side: simply omit `replicas` from the applied configuration; the HPA's field manager owns `.spec.replicas` and SSA leaves it alone. Never use `--force-conflicts` here.

**A9.7** — `kubectl replace -f` does a full `PUT`: it overwrites the entire object with the file's contents, requiring `metadata.resourceVersion` for optimistic concurrency. It is correct when you want to *guarantee* the live object matches the file exactly with no merge semantics — for example, removing a field that was set by `kubectl edit` and never entered the last-applied annotation, or restoring a known-good object from a backup. What it does that apply never does: **delete fields set by other actors**, including fields a controller added. That makes it dangerous by default and the reason `apply` is the recommended workflow; `kubectl replace --force` goes further and deletes-then-recreates the object, causing downtime and a new UID.

### Exercise 10

**A10.1** — The DaemonSet controller computes the desired count as the number of nodes whose taints, `nodeSelector`, `nodeAffinity` and available resources allow the template to be scheduled — `status.desiredNumberScheduled`. Adding the toleration made the control-plane node eligible, so the count became 3. There is no `replicas` field because the replica count is not a policy you choose; it is a *derivation* from cluster membership, and it must change automatically when nodes join or leave. Scaling a DaemonSet means changing its node selector or the cluster's node set. (To suspend one without deleting it, set an impossible `nodeSelector` — the idiomatic pause.)

**A10.2** — `completions` is how many Pods must succeed for the Job to be `Complete`; `parallelism` is how many may run at once. With `completions: 6, parallelism: 2` the controller runs a rolling pair until six successes accumulate. With `completions` unset and `parallelism: 4`, the Job is a **work-queue** Job: four Pods run concurrently and the Job succeeds as soon as *any one* Pod exits successfully and no others are running — the workers are expected to coordinate through an external queue and each exit when the queue is drained.

**A10.3** — `Never` and `OnFailure` only; `Always` is rejected at validation, because a Job that restarts forever can never complete. With `Never`, a failed container means a failed **Pod**, the Job controller creates a *new* Pod, and `backoffLimit` counts those Pod failures — you get one Pod object per attempt, and the logs of each are individually retrievable. With `OnFailure`, the kubelet restarts the container **in place** in the same Pod; `.status.failed` is driven by container restarts, you see a rising `RESTARTS` count rather than new Pods, and you lose the per-attempt Pod objects. Use `Never` when you want each attempt's logs preserved.

**A10.4** — The patch did nothing useful: most of a Job's spec, including `backoffLimit`, `completions` and the Pod template, is immutable after creation (only `parallelism`, `suspend`, and the TTL/managed-by fields can be changed), so the API server rejected it and the Job kept the default `backoffLimit: 6`. Six retries plus the original attempt is seven Pods — exactly what `kubectl get pods` counted. The lesson is that a Job's retry policy must be right at creation time; to change it you delete and recreate.

**A10.5** — It is the Job's self-cleanup: the TTL-after-finished controller deletes the Job object *N* seconds after it reaches `Complete` or `Failed`. Deleting the Job cascades to its Pods, so **the Pods and their logs disappear with it** — anything you needed from those logs must already have been shipped to a log store. Without it, finished Jobs accumulate indefinitely (especially from CronJobs) and become a real source of etcd bloat.

**A10.6** — The CronJob controller compares the current time against `.status.lastScheduleTime` and enumerates the missed schedules. Behaviour is governed by `startingDeadlineSeconds`: if unset, the controller will start a missed run whenever it comes back, but it counts missed schedules and if more than 100 have accumulated it gives up and records a `FailedNeedsStart` event rather than launching a storm. If `startingDeadlineSeconds: N` is set, a missed run is only started if fewer than N seconds have elapsed since it was due; older ones are skipped permanently and counted as missed. Set it deliberately: too small and legitimate short outages drop runs; unset and a long outage can either skip everything or, worse, hit the 100-miss wall.

**A10.7** — `Allow` (default): overlapping runs are permitted — correct for short, idempotent, mutually independent work such as a metrics scrape. `Forbid`: if the previous run is still active, the new one is skipped and recorded as missed — correct for a job that mutates shared state, such as a database backup or a reindex, where two concurrent runs would corrupt or deadlock. `Replace`: the running Job is deleted and replaced by the new one — correct when only the freshest result matters and a stale in-flight run is worthless, such as recomputing a cache or a leaderboard.

**A10.8** — `--from=cronjob/heartbeat` copies the CronJob's `jobTemplate` verbatim, so the manual run uses exactly the image, command, environment, service account, resources and node constraints of the scheduled run. Hand-copying the manifest at 3 a.m. reliably diverges — a stale image tag, a missing `imagePullSecret`, the wrong service account — and produces a "manual run worked / scheduled run fails" mystery. It also does not disturb `.status.lastScheduleTime`, so the schedule continues unaffected.

### Exercise 11

**A11.1** — `kubectl rollout restart` patches `.spec.template.metadata.annotations` with `kubectl.kubernetes.io/restartedAt: <RFC3339 timestamp>`. Because the Pod template changed, the Deployment controller computes a new `pod-template-hash`, creates a new ReplicaSet, and performs a **normal rolling update honouring `maxUnavailable: 0`** — so the ConfigMap change reaches all replicas with zero downtime, and there is a revision in `rollout history` to roll back to. Editing the image would be a lie about what changed (and there is no new image); deleting Pods bypasses the rollout policy entirely, taking capacity down in whatever chunks you delete, with no record and no rollback.

**A11.2** — `.metadata.generation` increments on every change to the Deployment's *spec*; `.status.observedGeneration` records the generation the controller has finished acting on. Waiting for `observedGeneration >= generation` **and** `status.updatedReplicas == status.replicas == status.readyReplicas == spec.replicas` is the machine-readable completion test. `kubectl rollout status` does effectively this: it watches the Deployment and evaluates the `Progressing` condition — succeeding on `reason: NewReplicaSetAvailable` and failing on `ProgressDeadlineExceeded` (default 600 s, from `.spec.progressDeadlineSeconds`). In CI, `kubectl rollout status --timeout=5m` and its exit code is the correct gate; a bare `sleep` is not.

**A11.3** — 4 at peak. `maxSurge: 25%` of 3 replicas is 0.75, which is rounded **up** for surge, giving 1 extra Pod; `maxUnavailable: 25%` would round **down** to 0, but it is explicitly 0 here anyway. So the controller adds one new Pod (4 total), waits for it to be Ready, terminates one old Pod (3), adds another new one (4), and repeats — never dropping below 3 available and never exceeding 4 total. The rounding directions are deliberate: surge rounds up and unavailability rounds down, so percentages always err toward more capacity.

</details>

---

## Sources

- LPI, *DevOps Tools Engineer — Exam 701 Objectives (version 2.0)* — https://www.lpi.org/our-certifications/exam-701-objectives/
- Kubernetes, *kubectl reference* — https://kubernetes.io/docs/reference/kubectl/
- Kubernetes, *Organizing Cluster Access Using kubeconfig Files* — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes, *Labels and Selectors* — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes, *Annotations* — https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/
- Kubernetes, *Namespaces* — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes, *Deployments* — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes, *ReplicaSet* — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes, *DaemonSet* — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes, *Jobs* — https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes, *CronJob* — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes, *Garbage Collection* (owner references, cascading deletion) — https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes, *Service* — https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes, *EndpointSlices* — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Kubernetes, *DNS for Services and Pods* — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes, *ConfigMaps* — https://kubernetes.io/docs/concepts/configuration/configmap/
- Kubernetes, *Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes, *Configure Liveness, Readiness and Startup Probes* — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes, *Resource Management for Pods and Containers* — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes, *Assign Memory Resources to Containers and Pods* (the `polinux/stress` OOM exercise) — https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Kubernetes, *Pod Quality of Service Classes* — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes, *Node-pressure Eviction* — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes, *Taints and Tolerations* — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes, *Debug Running Pods* (ephemeral containers, `kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Server-Side Apply* — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes, *Declarative Management of Kubernetes Objects Using Configuration Files* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes, *Declarative Management Using Kustomize* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kubernetes, *Field Selectors* — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
- kind, *Quick Start* — https://kind.sigs.k8s.io/docs/user/quick-start/