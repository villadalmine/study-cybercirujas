# 1.1 Platform Architecture Best Practices for Networking, Storage, and Compute

## Motivación y Principios de Arquitectura de Plataforma

El diseño de una **Internal Developer Platform (IDP)** sobre Kubernetes requiere tomar decisiones de arquitectura estructurales en tres capas fundamentales: **Networking**, **Storage** y **Compute**. La responsabilidad del Platform Engineer no es simplemente instalar componentes, sino diseñar e implementar **Golden Paths** (rutas automatizadas, pre-configuradas y opinadas) que permitan a los equipos de desarrollo entregar software de forma autónoma sin comprometer la seguridad, la resiliencia ni el gobierno de la infraestructura.

A diferencia del aprovisionamiento ad-hoc, una arquitectura de plataforma cloud native debe cumplir con cuatro principios cardinales:
1. **Self-Service con Guardrails**: Acceso autoservicio para los desarrolladores mediante APIs declarativas, acotado por políticas automáticas de seguridad y cuotas.
2. **Paridad de Entornos (Dev/Staging/Prod)**: Consistencia total en el plano de control, plugins de red y almacenamiento entre entornos.
3. **Abstracción Progresiva**: Ocultar la complejidad de bajo nivel de Kubernetes mediante abstracciones de alto nivel (como Helm Charts curados, Crossplane Compositions o especificaciones de aplicaciones).
4. **Resiliencia por Diseño**: Garantizar tolerancia a fallas a nivel de zona de disponibilidad, nodo y contenedor.

---

## Capa 1: Networking de Plataforma (CNI, Ingress y Mesh)

El plano de red de la plataforma debe soportar alta densidad de Pods, aislamiento estricto entre tenants y observabilidad detallada de los flujos de tráfico.

### 1.1 Selección del CNI: eBPF vs IPTables

| Criterio | Calico (IPTables/IPVS) | Cilium (eBPF) | Flannel |
|---|---|---|---|
| **Mecanismo de Datapath** | Filtros del kernel vía iptables/IPVS | Programas eBPF cargados en el kernel | VXLAN básico / Host-gw |
| **Rendimiento de Red** | Degrada a escala (>10,000 reglas) | Rendimiento casi nativo a cualquier escala | Alto, pero sin políticas |
| **NetworkPolicies** | L3/L4 completo | L3/L4 y L7 (HTTP/gRPC/Kafka) | No soporta NetworkPolicies |
| **Cifrado Transparente** | IPsec manual | WireGuard y IPsec nativos | No soporta cifrado |
| **Observabilidad** | Logs de iptables | Hubble (trazado L3-L7 en tiempo real) | Nula |

Para plataformas modernas orientadas a producción, **Cilium** es la opción estándar de la industria debido a su visibilidad eBPF sin sobrecarga de proxy.

### 1.2 Configuración Recomendada de Cilium para Plataformas Multi-Tenant

El siguiente manifiesto Helm refleja una instalación de Cilium orientada a la plataforma con observabilidad Hubble y cifrado WireGuard activados:

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.16.0 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.0.0.1 \
  --set k8sServicePort=6443 \
  --set bpf.masquerade=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

Verificación del estado del CNI y del cifrado:

```bash
$ cilium status --wait
KVStore:                Ok   Disabled
Kubernetes:             Ok   1.30 (v1.30.2)
Kubernetes APIs:        ["core/v1", "networking.k8s.io/v1", ...]
Cilium:                 Ok   1.16.0 (v1.16.0-4a8b9c)
NodeMonitor:            Listening for events on 2 LNs with levels [Normal, Warning]
Hubble Relay:           Ok   1.16.0
Encryption:             Wireguard [cilium_wg0]
Containers:             cilium            Running (2/2)
                        cilium-operator   Running (1/1)
                        hubble-relay      Running (1/1)
```

### 1.3 Ingress Controllers y Service Mesh

El tráfico Ingress debe ingresar a través de un controlador escalable (ej. Envoy Gateway o Ingress-Nginx) y distribuirse mediante un Service Mesh (Istio o Linkerd) cuando se requiera mTLS estricto e inyección de encabezados de trazabilidad (OpenTelemetry W3C Trace Context).

```yaml
# Ingress opinado para la plataforma
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-api-ingress
  namespace: platform-services
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.platform.example.com
    secretName: platform-api-tls
  rules:
  - host: api.platform.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: platform-api-svc
            port:
              number: 8080
```

---

## Capa 2: Storage de Plataforma (CSI, StorageClasses y Retención)

El almacenamiento persistente debe abstrarse para que los desarrolladores soliciten capacidad sin conocer los detalles específicos de las LUNs o volúmenes en la nube pública.

### 2.1 Matriz de Clasificación de StorageClasses

```yaml
# StorageClass para cargas de alta velocidad (Bases de datos)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebspcsi.csi.aws.com # o csi.hetzner.cloud / pd.csi.storage.gcp.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
---
# StorageClass para cargas estándar (Logs, Cachés)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-hdd
provisioner: ebspcsi.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: gp2
```

### 2.2 Buenas Prácticas de Storage en la Plataforma

1. **`volumeBindingMode: WaitForFirstConsumer`**: Atrasa la creación del volumen físico hasta que el Pod que lo consume sea asignado a un nodo específico. Esto evita que el volumen se aprovisione en la Zona de Disponibilidad A cuando el Pod termina en la Zona B.
2. **`reclaimPolicy: Retain`**: Garantiza que si un desarrollador borra un `PersistentVolumeClaim` (PVC) por accidente, el volumen subyacente en la nube NO se borre automáticamente, permitiendo la recuperación de desastres.
3. **Expansión de Volúmenes (`allowVolumeExpansion: true`)**: Permite aumentar el tamaño de un PVC en caliente sin reiniciar los workloads.

---

## Capa 3: Compute, Aislamiento y Planificación de Cargas de Trabajo

La capa de cómputo debe balancear el aislamiento de seguridad con la máxima eficiencia de empaquetado de recursos (*Bin-Packing*).

### 3.1 Aislamiento de Nodos con Taints y Tolerations

Para reservar nodos con hardware especializado (GPUs o procesadores de alta memoria) únicamente para servicios autorizados:

```bash
# Aplicar un taint al nodo especializado
kubectl taint nodes node-gpu-01 hardware=nvidia-a100:NoSchedule
```

Manifiesto de la aplicación que tolera el taint y solicita el recurso exclusivo:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-inference-service
  namespace: data-team
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ml-inference
  template:
    metadata:
      labels:
        app: ml-inference
    spec:
      tolerations:
      - key: "hardware"
        operator: "Equal"
        value: "nvidia-a100"
        effect: "NoSchedule"
      nodeSelector:
        hardware: nvidia-a100
      containers:
      - name: model-server
        image: myregistry.io/ml/model-server:v1.2.0
        resources:
          requests:
            cpu: "4"
            memory: "16Gi"
            nvidia.com/gpu: "1"
          limits:
            cpu: "8"
            memory: "32Gi"
            nvidia.com/gpu: "1"
```

### 3.2 Distribución de Alta Disponibilidad con TopologySpreadConstraints

Para asegurar que las réplicas de un microservicio crítico de la plataforma no se concentren en el mismo nodo o en la misma zona de disponibilidad:

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: platform-core-api
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: platform-core-api
```

---

## Verificación y Diagnóstico del Plano de Plataforma

### Verificación del Estado de Nodos y Recursos

```bash
# Inspección de nodos y etiquetas de topología
$ kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
NAME          STATUS   ROLES    AGE   VERSION   ZONE         INSTANCE-TYPE
node-az-a-1   Ready    <none>   12d   v1.30.2   us-east-1a   t3.xlarge
node-az-b-1   Ready    <none>   12d   v1.30.2   us-east-1b   t3.xlarge
node-gpu-01   Ready    <none>   5d    v1.30.2   us-east-1a   g4dn.xlarge

# Verificar el consumo real de cómputo por nodo
$ kubectl top nodes
NAME          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
node-az-a-1   450m         11%    3420Mi          42%
node-az-b-1   620m         15%    4100Mi          51%
node-gpu-01   1200m        30%    8900Mi          55%
```

### Diagnóstico de Problemas Comunes

1. **Pod en estado `Pending` debido a Taints no tolerados**:
   - *Síntoma*: `0/3 nodes are available: 1 node(s) had untolerated taint {hardware: nvidia-a100}`.
   - *Solución*: Agregar la sección `tolerations` correspondiente en la spec del Pod.
2. **PVC trabado en `Pending`**:
   - *Síntoma*: `waiting for first consumer to be created before binding`.
   - *Causa*: Es el comportamiento normal de `volumeBindingMode: WaitForFirstConsumer`. El PVC se vinculará únicamente cuando el Pod que lo requiere sea programado.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Networking Best Practices — https://kubernetes.io/docs/concepts/services-networking/
- Cilium eBPF Documentation — https://docs.cilium.io/en/stable/
- Kubernetes Storage Classes & Dynamic Provisioning — https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes Assigning Pods to Nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/