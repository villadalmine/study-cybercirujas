# 1.1 Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El rol del **Cloud Native Platform Engineer** (CNPE) abarca el diseño e implementación de la infraestructura subyacente para plataformas de contenedores escalables y resilientes. En este tema exploraremos las mejores prácticas de arquitectura de plataforma enfocándonos en las tres columnas fundamentales: **Networking**, **Storage** y **Compute**.

---

## 1. Networking de Plataforma (CNI, Service Mesh y Overlay Networks)

La capa de red de la plataforma debe proporcionar alta disponibilidad, baja latencia, aislamiento multi-tenant y observabilidad integrada.

### Container Network Interface (CNI)
- **eBPF vs Iptables**: Soluciones modernas basadas en eBPF (como Cilium) reemplazan las reglas masivas de `iptables` por programas eBPF cargados directamente en el kernel Linux. Esto optimiza el ruteo de paquetes a nivel de socket y reduce la latencia en clústeres a gran escala.
- **Network Policies Declarativas**: Enforce de microsegmentación L3/L4 (IPs/Puertos) y L7 (HTTP/gRPC).

#### Ejemplo de CiliumNetworkPolicy (L7 HTTP Filter)
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-policy
  namespace: platform-prod
spec:
  endpointSelector:
    matchLabels:
      app: backend-api
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend-ui
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/.*"
```

---

## 2. Storage de Plataforma (CSI, StorageClasses y Repartición de I/O)

El almacenamiento para aplicaciones cloud native debe abstraerse mediante el estándar **CSI (Container Storage Interface)**.

### Estrategia de StorageClasses y Quality of Service (QoS)
- **Dynamic Provisioning**: Uso de aprovisionamiento dinámico con metadatos ajustados según el workload (bases de datos vs logs efímeros).
- **Volume Binding Mode**: Usar `WaitForFirstConsumer` para asegurar que el almacenamiento en volumen de bloque (EBS, Longhorn, Ceph) se cree en la misma Zona de Disponibilidad (AZ) donde el Pod es programado por el Kubernetes Scheduler.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd-az
provisioner: driver.longhorn.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
```

---

## 3. Compute y Topology-Aware Scheduling

La capa de cómputo requiere un aislamiento eficiente entre tenants y resiliencia ante fallos de nodos o zonas.

### Node Selectors, Affinity y Tolerations
- **Topology Spread Constraints**: Garantiza la distribución equitativa de Pods a través de nodos, racks y Zonas de Disponibilidad (AZs).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-platform-service
  namespace: platform-system
spec:
  replicas: 6
  selector:
    matchLabels:
      app: core-service
  template:
    metadata:
      labels:
        app: core-service
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: core-service
      containers:
      - name: app
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Architecture & Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Cilium eBPF Architecture — https://docs.cilium.io/en/stable/overview/intro/
- Kubernetes Storage Classes & CSI — https://kubernetes.io/docs/concepts/storage/storage-classes/