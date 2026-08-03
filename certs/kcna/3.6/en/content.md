# 3.6 Troubleshooting

Troubleshooting in Kubernetes is the systematic process of diagnosing why an object (Pod, Deployment, Service, Node) is not behaving as expected. KCNA does not evaluate advanced SRE-level troubleshooting, but it does expect you to know the basic `kubectl` commands for inspecting status, logs and events, and to be able to recognize the most common causes of failures in Pods, probes, resources and networking.

## The systematic diagnostic flow

Faced with any problem, the recommended order is:

1. **View the general status** with `kubectl get`.
2. **Dig deeper** with `kubectl describe`, which shows spec, status and — crucially — the `Events` section.
3. **Review** the application's **logs** with `kubectl logs`.
4. **Inspect live** with `kubectl exec` (or `kubectl debug` if the container has no shell).
5. **Review cluster events** with `kubectl get events`.

```bash
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl logs <pod-name> [-c <container>] [--previous]
kubectl exec -it <pod-name> -- sh
kubectl get events --sort-by=.lastTimestamp
```

`--previous` in `kubectl logs` is key when the container has already restarted: it shows the logs from the previous attempt, not the current one (which may not have generated output yet).

## Common Pod states

### Pending

The Pod was accepted by the API server but was not *scheduled* (or scheduling occurred but the images/volumes are not ready). Typical causes: insufficient resources on the Nodes, `nodeSelector`/`affinity` that no Node satisfies, or a `PersistentVolumeClaim` with no `PersistentVolume` available.

```bash
$ kubectl describe pod web-7f8d9-x2k1
...
Events:
  Type     Reason            Message
  ----     ------            -------
  Warning  FailedScheduling  0/3 nodes are available: 3 Insufficient cpu.
```

### ImagePullBackOff / ErrImagePull

Kubernetes could not download the container's image: misspelled name/tag, private registry without `imagePullSecrets`, or registry rate limiting.

```bash
$ kubectl describe pod api-6c9b7-p4q2
Events:
  Warning  Failed     Failed to pull image "myrepo/api:v1.2": rpc error: code = NotFound
  Warning  BackOff    Back-off pulling image "myrepo/api:v1.2"
```

### CrashLoopBackOff

The container starts, terminates (with an error or even with exit code 0) and Kubernetes restarts it with exponential *backoff*. The cause is almost always in the app, not in Kubernetes: configuration error, a missing environment variable, or the main process exiting immediately.

```bash
$ kubectl get pods
NAME              READY   STATUS             RESTARTS   AGE
worker-5d8f-abcd  0/1     CrashLoopBackOff   6          8m

$ kubectl logs worker-5d8f-abcd --previous
Error: missing required env var DATABASE_URL
```

### OOMKilled

The container exceeded its `resources.limits.memory` and the kernel killed it. It shows up in `describe`, not necessarily in the `STATUS` of `get pods`.

```bash
$ kubectl describe pod cache-9f7b-1234
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Solution: raise the memory `limit` (if the app really needs it) or fix a memory leak. Exit code 137 = 128 + SIGKILL(9), a sign that something forcibly killed the process.

### Pod in `Unknown` or Node in `NotReady`

If a Node's `kubelet` stops reporting heartbeats (network outage, kubelet down, disk full), the control plane marks its Pods as `Unknown` and, after the `pod-eviction-timeout`, reschedules them on another Node.

```bash
$ kubectl get nodes
NAME       STATUS     ROLES    AGE   VERSION
worker-2   NotReady   <none>   30d   v1.29.1

$ kubectl describe node worker-2
Conditions:
  Type             Status  Reason
  ----             ------  ------
  MemoryPressure   True    KubeletHasInsufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  Ready            False   KubeletNotReady
```

## Troubleshooting probes

A misconfigured `livenessProbe` (too short a timeout, wrong endpoint) causes constant restarts of a healthy container; a `readinessProbe` that never passes leaves the Pod out of the Service's `Endpoints` even though it is `Running`.

```bash
$ kubectl describe pod app-3f2a-9k1m
Events:
  Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
  Normal   Killing    Container app failed liveness probe, will be restarted
```

Diagnosis: check whether `RESTARTS` is going up without any errors in the app's logs — this usually indicates that the probe points to the wrong path/port, not that the app is broken.

## Troubleshooting resources

In addition to OOM, a container can suffer **CPU throttling** if it exceeds its `limits.cpu`: it doesn't crash, but it responds slowly. This is detected by comparing actual usage against the limit:

```bash
kubectl top pod <pod-name>
```

(requires `metrics-server` installed in the cluster).

## Troubleshooting networking

Typical steps for "Pod A can't talk to Service B":

```bash
# 1. Does the Service have endpoints?
kubectl get endpoints my-service

# 2. Does DNS resolve from inside the Pod?
kubectl exec -it podA -- nslookup my-service

# 3. Is there L4 connectivity?
kubectl exec -it podA -- curl -v http://my-service:8080

# 4. Is there a NetworkPolicy blocking traffic?
kubectl get networkpolicy -A
```

If `endpoints` is empty, the problem is almost always that the Service's `selector` labels don't match the Pod's labels. If DNS fails, check the CoreDNS Pods (`kubectl -n kube-system get pods -l k8s-app=kube-dns`) and their logs.

## Ephemeral debug containers

When the container image has no shell or debug tools (*distroless* images), `kubectl debug` injects an ephemeral container with access to the same network/process namespace without modifying the original Pod:

```bash
kubectl debug -it my-pod --image=busybox:1.36 --target=my-container
```

## Key commands — summary

| Comando | Uso |
|---|---|
| `kubectl get <recurso> -o wide` | Estado rápido, incluye Node/IP |
| `kubectl describe <recurso>` | Spec completo + sección `Events` |
| `kubectl logs [-c] [--previous]` | Logs del contenedor actual o del anterior |
| `kubectl exec -it -- sh` | Shell interactiva dentro del contenedor |
| `kubectl get events --sort-by=.lastTimestamp` | Eventos recientes del cluster |
| `kubectl top pod/node` | Uso de CPU/memoria (requiere metrics-server) |
| `kubectl debug` | Contenedor efímero de debug |

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs, *Troubleshooting Applications*: https://kubernetes.io/docs/tasks/debug/debug-application/
- Kubernetes docs, *Troubleshooting Clusters*: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Kubernetes docs, *Debug Running Pods*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes docs, *Determine the Reason for Pod Failure*: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes docs, *Debug Services*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/