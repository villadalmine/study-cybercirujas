# 1.1 Applying Platform Architecture Best Practices for Networking, Storage, and Compute

## Introducción

El diseño de una **Internal Developer Platform (IDP)** sobre Kubernetes requiere decisiones de arquitectura consistentes en tres capas fundamentales: **networking**, **storage** y **compute**. Estas decisiones determinan la escalabilidad, seguridad, portabilidad y experiencia de desarrollador (**DevEx**) de la plataforma. El objetivo de un Platform Engineer es abstraer la complejidad subyacente ofreciendo **golden paths** (<PERSON> y opinados) sin sacrificar flexibilidad ni cumplimiento de buenas prácticas de infraestructura cloud native.

---

## Networking

### Principios de diseño

- **Desacoplar la red de la aplicación**: usar el modelo de **CNI (Container Network Interface)** para que cualquier workload obtenga IP y conectividad sin lógica específica de infraestructura.
- **Segmentación por defecto**: aplicar **NetworkPolicies** con enfoque *deny-all* y permitir tráfico explícito (least privilege).
- **Multi-tenancy**: aislar namespaces/tenants mediante policies, service mesh o proyectos (ej. `Hierarchical Namespaces`, `vCluster`).
- **Service discovery y observabilidad**: DNS interno (CoreDNS), métricas de latencia y trazabilidad end-to-end.
- **Ingress/Egress controlado**: exponer servicios mediante **Ingress Controllers** o **Gateway API**, y controlar egress con políticas explícitas o proxies (ej. Istio egress gateway).
- **Elección del CNI según requerimientos**: Calico/Cilium (policy <PERSON>, eBPF), <PERSON> (simplicidad), <PERSON> (observabilidad L3-L7 con Hubble).

### Ejemplo: NetworkPolicy deny-all + permitir tráfico específico

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: backend
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  policyTypes:
  - Ingress
```

### Comando: verificar CNI y estado de conectividad

```bash
kubectl get pods -n kube-system -o wide | grep -i cni

kubectl get networkpolicies -A
```

Salida esperada (ejemplo):

```
cilium-agent-4xk2p   1/1     Running   0   2d   <IP_ADDRESS>   node-1
cilium-agent-9jq1z   1/1     Running   0   2d   <IP_ADDRESS>   node-2
```

### Buenas prácticas adicionales

| Área | Recomendación |
|---|---|
| Ingress | Usar `Gateway API` para desacoplar routing de implementación específica |
| DNS | Configurar `NodeLocal DNSCache` para reducir latencia |
| Service Mesh | Adoptar mTLS automático (Istio, Linkerd) para tráfico interno |
| Egress | Restringir salida a internet mediante `EgressFirewall` o proxies |
| Observabilidad | <PERSON> métricas vía Prometheus/Hubble/Kiali |

---

## Storage

### Principios de diseño

- **Desacoplamiento vía CSI (Container Storage Interface)**: cualquier backend de storage (bloque, archivo, objeto) debe integrarse sin modificar el core de Kubernetes.
- **Dynamic Provisioning**: usar `StorageClass` para evitar aprovisionamiento manual de `PersistentVolumes`.
- **Clases de storage por perfil de rendimiento/costo**: separar SSD/HDD, replicación, IOPS.
- **Data lifecycle**: definir `reclaimPolicy` (Retain/Delete) según criticidad de los datos.
- **Backup y DR**: integrar herramientas como Velero para snapshotting y recuperación.
- **StatefulSets** para workloads con identidad estable y storage persistente (bases de datos, colas).

### Ejemplo: StorageClass + PVC dinámico

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "5000"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 20Gi
```

### Comando: verificar CSI drivers y volúmenes

```bash
kubectl get csidrivers
kubectl get pv,pvc -A
```

Salida esperada:

```
NAME                          ATTACHREQUIRED   PODINFOONMOUNT
ebs.csi.aws.com               true             true

NAME       STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS
db-data    Bound    pvc-1234   20Gi       RWO            fast-ssd
```

### Buenas prácticas adicionales

- Usar `volumeBindingMode: WaitForFirstConsumer` para respetar zonas de disponibilidad del pod.
- Definir cuotas de storage por namespace (`ResourceQuota` con `requests.storage`).
- Automatizar backups programados con Velero + object storage (S3/MinIO).
- Evitar `hostPath` en producción por falta de portabilidad y riesgos de seguridad.

---

## Compute

### Principios de diseño

- **Right-sizing**: definir `requests` y `limits` de CPU/memoria basados en perfiles reales de uso (evitar over/under-provisioning).
- **Autoscaling en múltiples niveles**:
  - **HPA (Horizontal Pod Autoscaler)**: escala réplicas según métricas.
  - **VPA (Vertical Pod Autoscaler)**: ajusta requests/limits automáticamente.
  - **Cluster Autoscaler / Karpenter**: escala nodos según demanda.
- **Scheduling avanzado**: usar `nodeAffinity`, `podAntiAffinity`, `taints/tolerations` para distribuir workloads según criticidad, hardware (GPU) o zonas.
- **QoS Classes**: `Guaranteed`, `Burstable`, `BestEffort` según configuración de requests/limits, impactando prioridad de eviction.
- **Node pools diferenciados**: separar workloads por tipo (general, GPU, spot/preemptible) para optimizar costo.
- **PodDisruptionBudgets (PDB)**: garantizar disponibilidad mínima durante mantenimientos/upgrades.

### Ejemplo: requests/limits y HPA

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: api
        image: myorg/api:1.0
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  <PERSON>: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

### Comando: verificar autoscaling y QoS

```bash
kubectl get hpa
kubectl describe pod api-7d9f8 | grep "QoS Class"
```

Salida esperada:

```
NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS
api-hpa   Deployment/api       45%/70%   3         10        3

QoS Class:  Burstable
```

### Ejemplo: taints/tolerations para node pools dedicados

```bash
kubectl taint nodes gpu-node-1 workload=<PERSON>:NoSchedule
```

```yaml
tolerations:
- key: "workload"
  operator: "Equal"
  value: "<PERSON>"
  effect: "NoSchedule"
nodeSelector:
  workload-type: gpu
```

### Buenas prácticas adicionales

| Área | Recomendación |
|---|---|
| Resource management | Siempre definir requests/limits; usar `LimitRange` por namespace |
| Autoscaling | Combinar HPA + Cluster Autoscaler/Karpenter para elasticidad completa |
| Disponibilidad | Configurar PDB en workloads críticos antes de upgrades |
| Costos | Usar spot/preemptible nodes para workloads tolerantes a interrupciones |
| Seguridad | Evitar `privileged: true`; aplicar `PodSecurity Admission` |

---

## Integración como plataforma (Platform Engineering)

Un IDP maduro combina estos tres pilares detrás de **abstracciones self-service**:

- **Golden paths** con plantillas (<PERSON> charts, Crossplane Compositions, Terraform modules) <PERSON>, StorageClass y resource limits correctos por defecto.
- **Policy as Code** (OPA/Gatekeeper, Kyverno) para validar que los manifiestos cumplan las best practices antes de llegar al cluster (admission control).
- **GitOps** (Argo CD, Flux) para garantizar que la configuración <PERSON>storage/compute sea la fuente de verdad y esté auditada.

```bash
# Ejemplo: validar policy con Kyverno antes del deploy
kubectl apply -f policy-require-limits.yaml
kubectl apply -f deployment-sin-limits.yaml
# Error: admission webhook denied the request: CPU/memory limits required
```

---

## Referencias

- CNCF CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Networking: https://kubernetes.io/docs/concepts/services-networking/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Gateway API: https://gateway-api.sigs.k8s.io/
- Container Storage Interface (CSI): https://kubernetes-csi.github.io/docs/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Velero Backup: https://velero.io/docs/
- Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Cluster Autoscaler: https://github.com/kubernetes/autoscaler
- Karpenter: https://karpenter.sh/docs/
- Taints and <PERSON>: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod Disruption Budgets: https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Kyverno Policies: https://kyverno.io/docs/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/