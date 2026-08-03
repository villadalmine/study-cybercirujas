# 2.2 Debugging

## Introduction

Debugging in Kubernetes is the process of diagnosing why a `Pod`, `Node`, or cluster component is not working as expected. Unlike debugging a monolithic application, in Kubernetes the failure can originate in multiple layers: the manifest definition, the scheduler, the kubelet, the container runtime, the network (CNI), or the application itself inside the container. That is why the troubleshooting approach is always "from the outside in": first look at the object's status at a high level, then the cluster events, and finally the logs and the inside of the container.

The main tools are `kubectl` subcommands: `describe`, `logs`, `exec`, `get events`, `top`, and `debug`.

## `kubectl describe`: object status and events

It is the first command to run when facing any problem. It shows spec, status, and — most importantly for debugging — the `Events` section at the end, with the recent history of what the scheduler and kubelet did with that object.

```bash
kubectl describe pod my-app-7d9f8c6b5-x2n4k
```

Output (trimmed, focusing on the useful part for debugging):

```
Status:       Pending
Conditions:
  Type           Status
  PodScheduled   False
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  30s   default-scheduler   0/3 nodes are available:
                                                          3 Insufficient cpu.
```

This example indicates a scheduling problem: the Pod cannot be placed on any Node because the requested `resources.requests.cpu` exceeds the available capacity. `describe` also works on `node`, `deployment`, `service`, etc., and in each case the `Events` section is the main source of clues.

## Common Pod failure statuses

| `STATUS` reported by `kubectl get pods` | Typical cause |
|---|---|
| `Pending` | Lack of resources (CPU/memory) on Nodes, unbound PVC, taints without toleration |
| `ImagePullBackOff` / `ErrImagePull` | Non‑existent image, mistyped tag, missing `imagePullSecrets` for a private registry |
| `CrashLoopBackOff` | The main container process terminates (crashes) repeatedly; kubelet retries with exponential backoff |
| `Error` / `OOMKilled` | Container exited with an error code, often due to exceeding `resources.limits.memory` |
| `Running` but `READY 0/1` | Readiness probe fails; the Pod is up but does not receive traffic from the Service |

```bash
kubectl get pods
```
```
NAME                     READY   STATUS             RESTARTS   AGE
my-app-7d9f8c6b5-x2n4k   0/1     CrashLoopBackOff   5          4m
```

## `kubectl logs`: container logs

Once the problematic Pod is identified, the next step is to check stdout/stderr of the container.

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k
```

If the Pod has multiple containers, you must specify which one:

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k -c sidecar
```

Special case for `CrashLoopBackOff`: the current container may not have useful logs because it has already restarted. In that case `--previous` shows the logs of the previously terminated container:

```bash
kubectl logs my-app-7d9f8c6b5-x2n4k --previous
```

To follow logs in real time (equivalent to `tail -f`):

```bash
kubectl logs -f my-app-7d9f8c6b5-x2n4k
```

## `kubectl exec`: interactive inspection inside the container

When logs are not enough, you can open a shell inside the container (if the image has one) to inspect the filesystem, environment variables, or connectivity:

```bash
kubectl exec -it my-app-7d9f8c6b5-x2n4k -- /bin/sh
```

It also works for running a specific command without an interactive session, for example to check the cluster’s internal DNS:

```bash
kubectl exec my-app-7d9f8c6b5-x2n4k -- nslookup my-service.default.svc.cluster.local
```

`exec` requires the container to be `Running` and to have a shell available; in `distroless` or `scratch` images this is not possible, for which ephemeral containers exist (see below).

## `kubectl get events`

Shows the event stream of the cluster, useful for seeing the full picture (not only of a single Pod) sorted chronologically:

```bash
kubectl get events --sort-by='.lastTimestamp'
```

```
LAST SEEN   TYPE      REASON      OBJECT                        MESSAGE
2m          Warning   BackOff     pod/my-app-7d9f8c6b5-x2n4k    Back-off restarting failed container
1m          Normal    Pulled      pod/my-app-7d9f8c6b5-x2n4k    Container image already present on machine
```

## `kubectl debug`: ephemeral containers

To debug Pods whose image lacks diagnostic tools (no shell, no `curl`, etc.), Kubernetes allows injecting an **ephemeral container**: a temporary container that is added to an already running Pod, shares its network/process namespace, and brings its own tools.

```bash
kubectl debug -it my-app-7d9f8c6b5-x2n4k \
  --image=busybox:1.36 \
  --target=my-app
```

`--target` makes the debug container share the process namespace with the target container, allowing you to see its processes (`ps aux`) from the outside even if the original image does not have those utilities.

It is also possible to debug an entire Node, which creates a privileged Pod with access to the Node’s filesystem via `/host`:

```bash
kubectl debug node/worker-01 -it --image=busybox:1.36
```

## Resource checks and probes

A frequent failure is `OOMKilled`, visible in `describe`:

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

This indicates that the container exceeded `resources.limits.memory`. The solution is not "debugging" per se, but adjusting limits or fixing a memory leak in the app.

To check current resource usage (requires metrics-server):

```bash
kubectl top pod my-app-7d9f8c6b5-x2n4k
```

Failures of `livenessProbe`/`readinessProbe` also appear in `Events` as `Unhealthy`:

```
Warning  Unhealthy  10s  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
```

## Typical troubleshooting flow

1. `kubectl get pods` → identify the Pod and its `STATUS`.
2. `kubectl describe pod <name>` → check `Events` and `Conditions`.
3. `kubectl logs <name> [--previous] [-c container]` → check application logs.
4. `kubectl exec -it <name> -- sh` or `kubectl debug` → internal inspection if logs are not enough.
5. `kubectl get events --sort-by='.lastTimestamp'` → cluster‑level context if the problem is not Pod‑specific (e.g., Node or networking issues).

## References

- Official KCNA curriculum: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Debug Running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Debug Pods and ReplicationControllers: https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods-replication-controller/
- Debugging with an ephemeral debug container: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Debug a Node: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- Determine the Reason for Pod Failure: https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- kubectl Cheat Sheet: https://kubernetes.io/docs/reference/kubectl/cheatsheet/