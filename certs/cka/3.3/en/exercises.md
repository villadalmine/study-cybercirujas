# Guided Exercises — 3.3 Configure workload autoscaling (weight 2.5)

> Curriculum Reference: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

These exercises assume a working cluster with `kubectl` configured and administrative access. We focus primarily on `HorizontalPodAutoscaler` (HPA), which is fully manageable via `kubectl` without external dependencies. We also cover `VerticalPodAutoscaler` (VPA) manifests conceptually.

---

## Block 1 — Verify `metrics-server` and Deploy Test Workloads

HPA scaling based on CPU/memory depends on the Metrics API (`metrics.k8s.io`) exposed by `metrics-server`. Without it, HPA cannot evaluate resource usage.

1. Verify `metrics-server` is running in the cluster:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```
2. Confirm the Metrics API responds:
   ```bash
   kubectl top nodes
   kubectl top pods -A
   ```
3. Deploy a test Deployment with **explicit `resources.requests`** (required for HPA percent calculations):
   ```bash
   kubectl create deployment php-apache --image=registry.k8s.io/hpa-example
   kubectl set resources deployment php-apache --requests=cpu=200m,memory=100Mi --limits=cpu=500m,memory=200Mi
   kubectl expose deployment php-apache --port=80
   ```
4. Verify Pod status and metrics:
   ```bash
   kubectl get pods -l app=php-apache
   kubectl top pod -l app=php-apache
   ```

**Comprehension Questions**
1. Why can HPA not calculate CPU utilization percentages if Pods omit `resources.requests.cpu` definitions?
2. Which cluster component exposes the `metrics.k8s.io` API consumed by the HPA controller?

---

## Block 2 — Create Imperative HPAs

5. Create an HPA scaling `php-apache` based on CPU targets:
   ```bash
   kubectl autoscale deployment php-apache --cpu-percent=50 --min=1 --max=5
   ```
6. Inspect initial HPA status:
   ```bash
   kubectl get hpa php-apache
   ```
7. Inspect the generated object in detail:
   ```bash
   kubectl describe hpa php-apache
   ```

**Comprehension Questions**
1. Which API group and version does `kubectl autoscale` generate in Kubernetes 1.35?
2. What does condition `ScalingActive=False` indicate in `kubectl describe hpa`?

---

## Block 3 — Declarative HPA with `autoscaling/v2` and Multiple Metrics

`kubectl autoscale` supports CPU only. Supporting memory or multiple metrics requires `autoscaling/v2` manifests.

8. Delete the imperative HPA:
   ```bash
   kubectl delete hpa php-apache
   ```
9. Create file `hpa-php-apache.yaml`:
   ```yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: php-apache
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: php-apache
     minReplicas: 1
     maxReplicas: 5
     metrics:
     - type: Resource
       resource:
         name: cpu
         target:
           type: Utilization
           averageUtilization: 50
     - type: Resource
       resource:
         name: memory
         target:
           type: Utilization
           averageUtilization: 70
   ```
10. Apply and verify manifest:
    ```bash
    kubectl apply -f hpa-php-apache.yaml
    kubectl get hpa php-apache -o yaml
    ```

**Comprehension Questions**
1. When an HPA specifies multiple metrics (CPU and memory), how does the controller compute final target replica counts?
2. What separates `target.type: Utilization` vs `target.type: AverageValue` in `Resource` metrics?

---

## Block 4 — Configure Custom Scaling `behavior`

`autoscaling/v2` supports fine-grained control over stabilization windows and scaling velocity rules.

11. Update `hpa-php-apache.yaml` adding the `behavior` block:
    ```yaml
    spec:
      # ...previous fields...
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 120
          policies:
          - type: Pods
            value: 1
            periodSeconds: 60
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
          - type: Percent
            value: 100
            periodSeconds: 15
    ```
12. Apply changes and verify manifest updates:
    ```bash
    kubectl apply -f hpa-php-apache.yaml
    kubectl get hpa php-apache -o jsonpath='{.spec.behavior}' 
    ```

**Comprehension Questions**
1. What issue does `stabilizationWindowSeconds` prevent during `scaleDown` operations?
2. What does policy `type: Percent, value: 100, periodSeconds: 15` enforce during `scaleUp`?

---

## Block 5 — Load Generation and Real-Time Scaling Inspection

13. Monitor HPA status in one terminal session:
    ```bash
    kubectl get hpa php-apache --watch
    ```
14. Generate synthetic CPU load against `php-apache` in a separate terminal:
    ```bash
    kubectl run -i --tty load-generator --rm --image=busybox:1.36 --restart=Never -- \
      /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
    ```
15. Observe `TARGETS` utilization values and replica scaling.
16. Terminate load generation (`Ctrl+C` / `exit`) and observe replica scale-down delays matching `stabilizationWindowSeconds`.
17. Review event logs:
    ```bash
    kubectl describe hpa php-apache
    ```

**Comprehension Questions**
1. Why do replica counts remain elevated briefly after load generation stops?
2. If `kubectl top pod` reports no CPU data during load tests, what two issues should be investigated?

---

## Block 6 — VerticalPodAutoscaler (VPA) Manifests

VPA requires external custom resource definitions and controllers (`recommender`, `updater`, `admission-controller`). Understanding VPA manifests is required for CKA concepts.

18. Manifest file `vpa-php-apache.yaml`:
    ```yaml
    apiVersion: autoscaling.k8s.io/v1
    kind: VerticalPodAutoscaler
    metadata:
      name: php-apache-vpa
    spec:
      targetRef:
        apiVersion: apps/v1
        kind: Deployment
        name: php-apache
      updatePolicy:
        updateMode: "Auto"
    ```
19. Validate manifest syntax:
    ```bash
    kubectl apply -f vpa-php-apache.yaml --dry-run=client
    ```

**Comprehension Questions**
1. Why should HPA and VPA avoid targeting identical CPU/memory metrics on the same workload?
2. What separates `updateMode: "Auto"` vs `updateMode: "Initial"` in VPA specifications?

---

## Block 7 — Cluster Autoscaler Concepts

Cluster Autoscaler (CA) manages host **node counts** based on `Pending` Pod demands.

20. Inspect node annotations used by Cluster Autoscaler:
    ```bash
    kubectl get nodes -o jsonpath='{.items[*].metadata.annotations.cluster-autoscaler\.kubernetes\.io/scale-down-disabled}'
    ```

**Comprehension Questions**
1. How can restrictive `PodDisruptionBudget` rules prevent Cluster Autoscaler scale-down operations?
2. How do HPA/VPA scaling scopes differ from Cluster Autoscaler scopes?

---

<details>
<summary>View Answers</summary>

**Block 1**
1. HPA computes utilization as `current usage / requested capacity`. Omitting requests leaves no denominator, preventing utilization calculation.
2. `metrics-server` scrapes kubelet `/stats/summary` endpoints and exposes `metrics.k8s.io`.

**Block 2**
1. `autoscaling/v2` (stable HPA API version in Kubernetes 1.35).
2. Indicates HPA cannot fetch or evaluate metrics, halting active scale decisions.

**Block 3**
1. HPA evaluates target metrics independently and selects the **highest calculated replica count** across all metrics.
2. `Utilization` computes usage relative to requested capacity. `AverageValue` enforces absolute resource values per Pod.

**Block 4**
1. Prevents flapping (rapid oscillations between scale-up and scale-down).
2. Permits doubling (100% increase) active replica counts every 15 seconds.

**Block 5**
1. `stabilizationWindowSeconds` buffers scale-down evaluations to absorb transient load drops.
2. Verify `metrics-server` deployment health and confirm target Pods declare `resources.requests.cpu`.

**Block 6**
1. Simultaneous execution creates competing feedback loops over resource requests.
2. `Auto` evicts active Pods to apply recommendations. `Initial` applies recommendations strictly during Pod creation.

**Block 7**
1. Restrictive PDBs block Pod evictions during node drain operations, preventing host scale-down.
2. HPA/VPA operates on Pod/workload levels; Cluster Autoscaler operates on infrastructure node levels.

</details>
