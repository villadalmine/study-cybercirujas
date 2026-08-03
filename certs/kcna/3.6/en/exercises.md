# 3.6 Troubleshooting

In KCNA, troubleshooting is evaluated at a conceptual level: which command to use, what information to look for, and how to interpret the status of Kubernetes objects when something fails. These exercises assume a local cluster (`kind`, `minikube` or similar) with `kubectl` configured and pointing to the correct context.

---

## Exercise 1: Pod in `Pending` state

1. Create a `pending-pod.yaml` manifest that requests more CPU than any node in the cluster has:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-imposible
   spec:
     containers:
       - name: app
         image: nginx
         resources:
           requests:
             cpu: "100"
   ```

2. Apply the manifest:

   ```bash
   kubectl apply -f pending-pod.yaml
   ```

3. Check the Pod's status:

   ```bash
   kubectl get pod pod-imposible
   ```

4. Investigate the cause with `describe`, paying attention to the `Events` section at the end of the output:

   ```bash
   kubectl describe pod pod-imposible
   ```

5. Delete the resource once the exercise is finished:

   ```bash
   kubectl delete -f pending-pod.yaml
   ```

**Questions**
- What `Phase` does `kubectl get pod` show while the scheduler cannot place the Pod?
- What `Reason` appears in the `Events` section of `describe` and which Kubernetes component generates it?
- Name two other causes (besides insufficient resources) that can leave a Pod in `Pending`.

---

## Exercise 2: `CrashLoopBackOff`

1. Create `crash-pod.yaml` with a container that terminates immediately with an error:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-crash
   spec:
     containers:
       - name: app
         image: busybox
         command: ["sh", "-c", "echo 'fallo simulado'; exit 1"]
   ```

2. Apply the manifest and watch how the state changes over ~1 minute:

   ```bash
   kubectl apply -f crash-pod.yaml
   kubectl get pod pod-crash --watch
   ```

3. Stop the `watch` with `Ctrl+C` and check the container's logs:

   ```bash
   kubectl logs pod-crash
   ```

4. Check the exit code and previous state of the container:

   ```bash
   kubectl describe pod pod-crash
   ```

5. Clean up the resource:

   ```bash
   kubectl delete -f crash-pod.yaml
   ```

**Questions**
- Why does Kubernetes keep restarting the container instead of leaving it stopped, and which `PodSpec` field controls that behavior?
- In the `describe` output, in which fields can you see the `Exit Code` and the `Reason` of the last termination?
- If the `Exit Code` were `137` instead of `1`, which operating system signal does it suggest and what typical cause is associated with it (hint: memory)?

---

## Exercise 3: `ImagePullBackOff`

1. Create `bad-image-pod.yaml` with a nonexistent image tag:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-mala-imagen
   spec:
     containers:
       - name: app
         image: nginx:tag-que-no-existe-123
   ```

2. Apply and observe the state:

   ```bash
   kubectl apply -f bad-image-pod.yaml
   kubectl get pod pod-mala-imagen
   ```

3. Repeat the command a couple of times with a few seconds between each, and notice how the `STATUS` changes:

   ```bash
   kubectl get pod pod-mala-imagen
   ```

4. Confirm the exact cause in `Events`:

   ```bash
   kubectl describe pod pod-mala-imagen
   ```

5. Clean up the resource:

   ```bash
   kubectl delete -f bad-image-pod.yaml
   ```

**Questions**
- What is the difference between the `ErrImagePull` and `ImagePullBackOff` states in terms of order of appearance and meaning?
- If the image were private and authentication were missing, what Kubernetes resource is used to provide the registry credentials, and in which field of the Pod/ServiceAccount is it referenced?

---

## Exercise 4: Service without `Endpoints`

1. Create a Deployment and a Service with a mismatched selector (`app: web` in the Deployment but `app: webapp` in the Service):

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 2
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
             image: nginx
             ports:
               - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web-svc
   spec:
     selector:
       app: webapp
     ports:
       - port: 80
         targetPort: 80
   ```

2. Apply both objects:

   ```bash
   kubectl apply -f web-service.yaml
   ```

3. Confirm that the Pods are `Running`:

   ```bash
   kubectl get pods -l app=web
   ```

4. Check whether the Service has active targets:

   ```bash
   kubectl get endpoints web-svc
   ```

5. Fix the Service's selector (change `app: webapp` to `app: web`), reapply, and confirm that `Endpoints` appear:

   ```bash
   kubectl apply -f web-service.yaml
   kubectl get endpoints web-svc
   ```

6. Clean up the resources:

   ```bash
   kubectl delete -f web-service.yaml
   ```

**Questions**
- What intermediate object connects a Service with the actual Pods, and what command displays it?
- Besides an incorrect selector, what other Pod condition excludes them from a Service's `Endpoints` even though the selector matches?

---

## Exercise 5: Node `NotReady`

1. List the status of the cluster's nodes:

   ```bash
   kubectl get nodes
   ```

2. Choose a node and examine its `Conditions`:

   ```bash
   kubectl describe node <nombre-del-nodo>
   ```

3. Locate in the output the `Ready`, `MemoryPressure`, `DiskPressure`, and `PIDPressure` conditions, and their value (`True`/`False`/`Unknown`).

4. Check which Pods are running on that node and whether any is affected:

   ```bash
   kubectl get pods --all-namespaces --field-selector spec.nodeName=<nombre-del-nodo>
   ```

**Questions**
- What component runs on each node and is responsible for reporting its status to the control plane?
- If `Ready` switches to `Unknown` (not `False`), what does that usually indicate about the communication between the node and the control plane?
- What happens to the Pods of a node that becomes `NotReady` for longer than the configured tolerance time (`node.kubernetes.io/not-ready`)?

---

<details>
<summary>Answers</summary>

**Exercise 1**
- The Pod stays in `Phase: Pending` because the scheduler cannot assign it to any node.
- The event shows `Reason: FailedScheduling`, generated by the `kube-scheduler`, with a message like `Insufficient cpu`.
- Other common causes: a `nodeSelector`/`affinity` that doesn't match any node, or a `taint` on the nodes without the corresponding `toleration` on the Pod; also a `PersistentVolumeClaim` that cannot become `Bound`.

**Exercise 2**
- The `restartPolicy` field of the `PodSpec` (default `Always` for Pods created directly or via a Deployment) causes the kubelet to restart the container every time it terminates; Kubernetes applies an exponential backoff between retries, hence the name `CrashLoopBackOff`.
- In `describe pod`, inside `Containers > app > Last State: Terminated`, the `Reason` and `Exit Code` appear.
- Code `137` = 128 + 9 (SIGKILL). The typical cause is that the container was killed by the kernel for exceeding its memory limit (`OOMKilled`), also visible as `Reason: OOMKilled` in `describe`.

**Exercise 3**
- `ErrImagePull` is the first failed download attempt (nonexistent image, invalid tag, unreachable registry); if the failure persists, Kubernetes moves to `ImagePullBackOff`, which indicates it is waiting with exponential backoff before retrying.
- A `Secret` of type `kubernetes.io/dockerconfigjson` is used, referenced in the `imagePullSecrets` field of the `PodSpec` (or configured by default in the namespace's `ServiceAccount`).

**Exercise 4**
- The `Endpoints` object (or `EndpointSlice` in more recent versions) connects the Service with the IPs of the Pods that match its selector; it is displayed with `kubectl get endpoints <service>`.
- A Pod with a `readinessProbe` that fails is marked as `Not Ready` and Kubernetes excludes it from the Service's `Endpoints` even though its labels match the selector.

**Exercise 5**
- The `kubelet` runs on each node and is responsible for periodically reporting its status (heartbeat) to the control plane (`kube-apiserver`/`kube-controller-manager`).
- `Ready: Unknown` indicates that the control plane stopped receiving heartbeats from the node within the expected time (network problem or kubelet down), unlike `False`, which indicates that the kubelet explicitly reported a bad status.
- Once the `tolerationSeconds` of the automatic `node.kubernetes.io/not-ready` taint elapses (5 minutes by default), the control plane evicts the Pods from that node and, if they belong to a controller such as a Deployment, they get rescheduled on another available node.

</details>

---

**Fuente:** CNCF KCNA Curriculum — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf