# Dominio 2.3: Seguridad de Kube-Scheduler y Mecánicas de Aislamiento de Cargas de Trabajo

## 1. Arquitectura de Producción y Motivación Técnica

En un clúster de Kubernetes en producción, `kube-scheduler` actúa como el motor de ubicación determinista del control plane. Evalúa los Pods no asignados (`spec.nodeName == ""`) y selecciona los worker nodes óptimos basándose en la disponibilidad de recursos, las restricciones de políticas y los requerimientos topológicos. Desde la perspectiva de un Cloud Native Security Associate (KCSA), el scheduler representa tanto un **límite de seguridad del control plane** crítico como el mecanismo principal para aplicar **políticas de aislamiento de cargas de trabajo y multi-tenancy**.

```
                           +-------------------------------------------------------+
                           |              KUBERNETES CONTROL PLANE                 |
                           |                                                       |
                           |   +-----------------------+     +-----------------+   |
                           |   |   kube-apiserver      |     |  etcd Database  |   |
                           |   | (Authentication/RBAC) |     |  (Etcd Encrypt) |   |
                           |   +-----------+-----------+     +-----------------+   |
                           |               |                                       |
                           |               | Watch / Watch Pods (spec.nodeName="") |
                           |               v                                       |
                           |   +-----------------------------------------------+   |
                           |   |             kube-scheduler                    |   |
                           |   |  - mTLS Endpoint (Port 10259)                 |   |
                           |   |  - TLS 1.3 Strict Ciphers                     |   |
                           |   |  - Scheduling Framework Profiles              |   |
                           |   +-------------------+---------------------------+   |
                           +-----------------------|-------------------------------+
                                                   |
                                                   | POST /api/v1/namespaces/$NS/pods/$POD/binding
                                                   v
                           +-------------------------------------------------------+
                           |                WORKLOAD ISOLATION LAYER               |
                           |                                                       |
                           |  +------------------------+  +---------------------+  |
                           |  | PCI-DSS Node Pool      |  | Shared Tenant Pool  |  |
                           |  | - Taint: pci=true:NoSched|  | - Untrusted Workload|  |
                           |  | - Restricted NodeLabels|  | - Standard Labels   |  |
                           |  +-----------+------------+  +----------+----------+  |
                           |              |                          |             |
                           |              v                          v             |
                           |  +------------------------+  +---------------------+  |
                           |  | Dedicated Worker Node  |  | Shared Worker Node  |  |
                           |  +------------------------+  +---------------------+  |
                           +-------------------------------------------------------+
```

### Vectores de Ataque Técnicos y Riesgos de Seguridad

1. **Compromiso del Control Plane a través de Endpoints del Scheduler No Asegurados:**
   Históricamente, `kube-scheduler` exponía métricas HTTP sin autenticación en el puerto `10251`. En clústeres endurecidos, exponer endpoints de `kube-scheduler` a través de interfaces no cifradas o débilmente autenticadas permite a actores no autorizados extraer metadatos sensibles o manipular la configuración del scheduler. El endurecimiento requiere vincular estrictamente a `127.0.0.1` o forzar mTLS autenticado en el puerto `10259`.

2. **Co-ubicación entre Inquilinos (Cross-Tenant) y Escalación por Container Breakout:**
   En clústeres multi-tenant, colocar un contenedor de baja confianza (ej. aplicación web pública) en el mismo host físico que un contenedor de alta seguridad (ej. servicio de procesamiento de pagos, agente de vault) abre severos vectores de ataque por canales laterales (side-channel attacks). Vulnerabilidades tales como CPU Spectre/Meltdown, L1 Terminal Fault (L1TF), o breakouts del runtime de contenedores (ej. `CVE-2019-5736`, `CVE-2024-21626`) pueden permitir que un atacante en un nodo compartido acceda a secretos a través de los límites de los namespaces.

3. **Manipulación de Etiquetas de Nodos (Node Label Tampering) y Evasión de Límites:**
   Si los worker nodes (a través de Kubelets comprometidos) pueden mutar sus propias etiquetas de nodo (ej. cambiando `environment=untrusted` a `environment=pci-dss`), podrían engañar a `kube-scheduler` para programar Pods sensibles y de alto privilegio en un worker node controlado por el atacante. Mitigar este vector requiere aplicar el admission controller `NodeRestriction` junto con reglas estrictas de afinidad del scheduler.

4. **Agotamiento de Recursos y DoS por Punto Único de Falla:**
   Sin restricciones de distribución de topología de Pods (Pod Topology Spread Constraints) o reglas de Anti-Affinity, `kube-scheduler` puede colocar todas las réplicas de un microservicio de seguridad crítico (ej. validador de Open Policy Agent) en un solo worker node o dominio de falla. Una falla de host o un ataque dirigido de vecino ruidoso (noisy-neighbor) causa una denegación de servicio total para los controles de seguridad en todo el clúster.

---

## 2. Comparativas Técnicas y Tablas de Balance (Trade-offs)

### Comparativa de Primitivas de Aislamiento de Cargas de Trabajo

| Primitiva de Aislamiento | Mecanismo de Aplicación | Control Estricto (Hard) vs. Flexible (Soft) | Nivel de Límite de Seguridad | Sobrecarga Operativa y SRE |
| :--- | :--- | :--- | :--- | :--- |
| **`nodeSelector`** | Coincide con pares Clave-Valor exactos en etiquetas de Node. | Restricción estricta (`DoNotSchedule`). | Selección básica de host; sin lógica de separación lógica. | Baja. Mantenimiento mínimo, pero inflexible para reglas complejas. |
| **`nodeAffinity`** | Coincide con operaciones de selector expresables (`In`, `NotIn`, `Exists`). | Admite tanto estricto (`requiredDuringScheduling...`) como flexible (`preferredDuringScheduling...`). | Medio. Evita la ubicación en grupos de nodos no autorizados. | Medio. Requiere esquemas estandarizados de etiquetado de nodos en la infraestructura. |
| **`Taints & Tolerations`** | Los nodos rechazan Pods no deseados a menos que el Pod tolere explícitamente el taint. | Estricto (`NoSchedule`, `NoExecute`) o flexible (`PreferNoSchedule`). | Alto. Repele cargas de trabajo no conformes de nodos dedicados. | Medio-Alto. Requiere gestión del ciclo de vida de taints en los node pools. |
| **`PodAntiAffinity`** | Evalúa etiquetas de Pods co-ubicados en nodos dentro del dominio topológico. | Estricto (`requiredDuringScheduling...`) o flexible (`preferredDuringScheduling...`). | Alto. Evita la co-ubicación entre inquilinos (cross-tenant) en kernels compartidos. | Alto. Incrementa la complejidad del algoritmo del scheduler (escala $O(N \times M)$). |
| **`TopologySpreadConstraints`** | Controla la distribución de Pods a través de zonas/dominios de falla. | Estricto (`whenUnsatisfiable: DoNotSchedule`) o flexible (`ScheduleAnyway`). | Alto. Garantiza alta disponibilidad y aislamiento del radio de impacto (blast radius). | Medio. Depende de un etiquetado preciso de la clave de topología del nodo (`topology.kubernetes.io/zone`). |

### Modos de Configuración de Endurecimiento de `kube-scheduler`

| Parámetro de Endurecimiento | Modo Predeterminado / Legado | Estándar SRE Endurecido Empresarial | Impacto de Seguridad y Balances (Trade-offs) |
| :--- | :--- | :--- | :--- |
| **Dirección de Escucha (`--bind-address`)** | `0.0.0.0` (Expuesto en todas las interfaces). | `127.0.0.1` (Solo loopback localhost). | Reduce la superficie de ataque; evita el acceso a nivel de red a métricas/salud desde fuera del nodo. |
| **Puerto Seguro (`--secure-port`)** | `10259` (Expuesto con certificados por defecto). | `10259` aplicado con mTLS y CA dedicada. | Protege la integridad de datos del endpoint de métricas y la autenticación del endpoint. |
| **Suites de Cifrado TLS (`--tls-cipher-suites`)** | Lista estándar de suites de cifrado de Go. | Restringido a cifrados TLS 1.3 y TLS 1.2 con secreción hacia adelante (forward secrecy). | Mitiga ataques de degradación (downgrade) de TLS; exige el cumplimiento de NIST SP 800-52 Rev. 2. |
| **Autenticación y Autorización** | Delegado vía token de kubeconfig. | CA de cliente mTLS dedicada + RBAC Token Review. | Previene el acceso anónimo; restringe los permisos RBAC de `pods/binding` estrictamente a la identidad del scheduler. |
| **Perfiles de Programación (`KubeSchedulerConfiguration`)** | Perfil monolítico predeterminado único. | Separación multi-perfil (`default` vs. `hardened-pci`). | Permite filtros granulares de ejecución de plugins para diferentes niveles de seguridad sin ejecutar múltiples binarios. |

---

## 3. Manifiestos de Grado de Producción y Configuraciones de Infraestructura

### 3.1 Manifiesto de Pod Estático de `kube-scheduler` Endurecido
File: `/etc/kubernetes/manifests/kube-scheduler.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --secure-port=10259
    - --config=/etc/kubernetes/scheduler-config.yaml
    - --tls-cert-file=/etc/kubernetes/pki/scheduler.crt
    - --tls-private-key-file=/etc/kubernetes/pki/scheduler.key
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS12
    - --v=2
    image: registry.k8s.io/kube-scheduler:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-scheduler
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: true
      runAsGroup: 65534
      runAsNonRoot: true
      runAsUser: 65534
      seccompProfile:
        type: RuntimeDefault
    volumeMounts:
    - mountPath: /etc/kubernetes/scheduler.conf
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/kubernetes/scheduler-config.yaml
      name: scheduler-config
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext: {}
  volumes:
  - hostPath:
      path: /etc/kubernetes/scheduler.conf
      type: FileOrCreate
    name: kubeconfig
  - hostPath:
      path: /etc/kubernetes/scheduler-config.yaml
      type: FileOrCreate
    name: scheduler-config
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
```

### 3.2 Archivo de Configuración Avanzado de `KubeSchedulerConfiguration`
File: `/etc/kubernetes/scheduler-config.yaml`

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
  resourceName: kube-scheduler
  resourceNamespace: kube-system
  leaseDuration: 15s
  renewDeadline: 10s
  retryPeriod: 2s
clientConnection:
  kubeconfig: "/etc/kubernetes/scheduler.conf"
  acceptContentTypes: "application/vnd.kubernetes.protobuf,application/json"
  contentType: "application/vnd.kubernetes.protobuf"
  qps: 100
  burst: 200
profiles:
  - schedulerName: default-scheduler
    plugins:
      multiPoint:
        enabled:
          - name: NodeResourcesFit
          - name: NodeName
          - name: NodePorts
          - name: NodeAffinity
          - name: PodTopologySpread
          - name: TaintToleration
          - name: ImageLocality
          - name: DefaultBinder
    pluginConfig:
      - name: PodTopologySpread
        args:
          defaultConstraints:
            - maxSkew: 1
              topologyKey: "topology.kubernetes.io/zone"
              whenUnsatisfiable: DoNotSchedule
          defaultingType: List
  - schedulerName: hardened-high-security-scheduler
    plugins:
      filter:
        enabled:
          - name: NodeResourcesFit
          - name: NodeAffinity
          - name: TaintToleration
          - name: PodTopologySpread
        disabled:
          - name: "*"
      score:
        enabled:
          - name: NodeResourcesBalancedAllocation
            weight: 100
          - name: PodTopologySpread
            weight: 200
        disabled:
          - name: "*"
```

### 3.3 Manifiesto de Pod con Aislamiento Estricto de Cargas de Trabajo (Conforme a PCI-DSS)
File: `pci-isolated-workload.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pci-payment-processor
  namespace: payment-secure
  labels:
    app.kubernetes.io/name: payment-processor
    security.tier: pci-dss
    tenant: sensitive-data
spec:
  schedulerName: default-scheduler
  priorityClassName: high-priority-service
  containers:
  - name: processor
    image: internal-registry.enterprise.io/finance/processor:v2.4.1
    imagePullPolicy: Always
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
    resources:
      requests:
        cpu: "2"
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 8Gi
  # 1. Node Selection Criteria: Restrict to dedicated physical hardware
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: environment.zone/security-tier
            operator: In
            values:
            - pci-dss-isolated
          - key: kubernetes.io/arch
            operator: In
            values:
            - amd64
    # 2. Prevent co-location with any untrusted or generic workloads on the same physical host
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: security.tier
            operator: NotIn
            values:
            - pci-dss
        topologyKey: "kubernetes.io/hostname"
  # 3. Taints & Tolerations: Repel all non-PCI workloads from these nodes
  tolerations:
  - key: "dedicated.workload/pci-dss"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  - key: "dedicated.workload/pci-dss"
    operator: "Equal"
    value: "true"
    effect: "NoExecute"
  # 4. Topology Spread: Guarantee multi-AZ redundancy without single-node blast radius
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: "topology.kubernetes.io/zone"
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: payment-processor
  - maxSkew: 1
    topologyKey: "kubernetes.io/hostname"
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: payment-processor
```

### 3.4 ClusterRole RBAC Mínimo para `system:kube-scheduler`
File: `kube-scheduler-rbac.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-scheduler-custom
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["", "events.k8s.io"]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["endpoints"]
  resourceNames: ["kube-scheduler"]
  verbs: ["get", "update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete", "get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/binding", "pods/status"]
  verbs: ["create", "patch", "update"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims", "persistentvolumes"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  resourceNames: ["kube-scheduler"]
  verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-scheduler-custom
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-scheduler-custom
subjects:
- kind: ServiceAccount
  name: kube-scheduler
  namespace: kube-system
```

---

## 4. Comandos CLI Reales y Salidas Esperadas de la Terminal

### 4.1 Auditoría de Flags de Seguridad del Control Plane de `kube-scheduler`
Ejecutar en el nodo del control plane para verificar la dirección de bind, los parámetros mTLS y las suites de cifrado:

```bash
$ ps aux | grep kube-scheduler | tr ' ' '\n' | grep -E '^--'
```

**Salida Esperada:**
```text
--authentication-kubeconfig=/etc/kubernetes/scheduler.conf
--authorization-kubeconfig=/etc/kubernetes/scheduler.conf
--bind-address=127.0.0.1
--secure-port=10259
--config=/etc/kubernetes/scheduler-config.yaml
--tls-cert-file=/etc/kubernetes/pki/scheduler.crt
--tls-private-key-file=/etc/kubernetes/pki/scheduler.key
--client-ca-file=/etc/kubernetes/pki/ca.crt
--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
--tls-min-version=VersionTLS12
--v=2
```

### 4.2 Verificación del Endpoint mTLS Localhost de `kube-scheduler`
Verificar que el endpoint de métricas HTTPS requiera certificados de cliente mTLS válidos y rechace el tráfico HTTP que no sea TLS:

```bash
$ curl -k -s -o /dev/null -w "%{http_code}\n" https://127.0.0.1:10259/healthz
```

**Salida Esperada:**
```text
401
```

Ahora autenticarse utilizando los certificados de cliente autorizados del scheduler:

```bash
$ curl -s --cacert /etc/kubernetes/pki/ca.crt \
    --cert /etc/kubernetes/pki/scheduler.crt \
    --key /etc/kubernetes/pki/scheduler.key \
    https://127.0.0.1:10259/healthz
```

**Salida Esperada:**
```text
ok
```

### 4.3 Auditoría de Taints, Etiquetas y Distribución de Cargas de Trabajo en Nodos
Inspeccionar los node pools de los worker nodes para verificar la configuración de taints en las zonas de aislamiento dedicadas:

```bash
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
SECURITY_ZONE:.metadata.labels.'environment\.zone/security-tier',\
TAINTS:.spec.taints
```

**Salida Esperada:**
```text
NAME           SECURITY_ZONE      TAINTS
worker-node-1  pci-dss-isolated   [map[effect:NoSchedule key:dedicated.workload/pci-dss value:true] map[effect:NoExecute key:dedicated.workload/pci-dss value:true]]
worker-node-2  pci-dss-isolated   [map[effect:NoSchedule key:dedicated.workload/pci-dss value:true] map[effect:NoExecute key:dedicated.workload/pci-dss value:true]]
worker-node-3  general-shared     <none>
worker-node-4  general-shared     <none>
```

### 4.4 Inspección de Eventos de Decisión de Programación por Restricciones No Satisfechas
Desencadenar un deployment con tolerations que no coincidan para verificar la aplicación por parte del scheduler:

```bash
$ kubectl get events -n payment-secure --field-selector reason=FailedScheduling --sort-by='.metadata.creationTimestamp'
```

**Salida Esperada:**
```text
LAST SEEN   TYPE      REASON             OBJECT                       MESSAGE
12s         Warning   FailedScheduling   pod/untrusted-app-7d9f-x82   0/4 nodes are available: 2 node(s) had untolerated taint {dedicated.workload/pci-dss: true}, 2 node(s) didn't match Pod's node affinity label selector. preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling..
```

### 4.5 Pruebas de Autorización del Subrecurso Binding Directo de Pod (Defensa contra Evasión de RBAC)
Intentar enviar una solicitud a la API de `Binding` sin procesar directamente a `kube-apiserver` utilizando un token de cuenta de servicio no autorizado para verificar la protección RBAC en el subrecurso `pods/binding`:

```bash
$ curl -k -X POST https://127.0.0.1:6443/api/v1/namespaces/payment-secure/pods/pci-payment-processor/binding \
  -H "Authorization: Bearer $UNAUTHORIZED_SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Binding",
    "metadata": { "name": "pci-payment-processor" },
    "target": { "apiVersion": "v1", "kind": "Node", "name": "worker-node-3" }
  }'
```

**Salida Esperada:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "pods \"pci-payment-processor/binding\" is forbidden: User \"system:serviceaccount:payment-secure:unauthorized-sa\" cannot create resource \"pods/binding\" in API group \"\" in the namespace \"payment-secure\"",
  "reason": "Forbidden",
  "details": {
    "name": "pci-payment-processor/binding",
    "kind": "pods"
  },
  "code": 403
}
```

---

## 5. Guía de Verificación y Solución de Problemas (Troubleshooting) para SRE

```
+-----------------------------------------------------------------------------------+
|                         SCHEDULER TROUBLESHOOTING FLOWCHART                      |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                              [Pod stuck in Pending state]
                                          |
                                          v
                       +-------------------------------------+
                       | Run `kubectl describe pod <pod-name>`|
                       +------------------+------------------+
                                          |
                        +-----------------+-----------------+
                        |                                   |
                        v                                   v
             [FailedScheduling Event]               [No Events / Unknown]
                        |                                   |
          +-------------+-------------+                     v
          |                           |         +-----------------------+
          v                           v         | Check Scheduler Pod   |
  [Taint / Affinity]       [Topology / Skew]    | Health & Logs         |
          |                           |         +-----------+-----------+
          v                           v                     |
+-------------------+   +--------------------+              v
| Verify Node       |   | Check Zone Labels  |   +--------------------------+
| Labels & Taints   |   | & Node Topology    |   | Check APIServer RBAC &   |
+-------------------+   +--------------------+   | Client Certificate Expiry|
                                                 +--------------------------+
```

### Procedimiento de Diagnóstico 1: Pod atascado en `Pending` debido a `FailedScheduling`

**Síntoma:** El Pod permanece en estado `Pending` indefinidamente. `kubectl get pod` muestra 0 nodos disponibles.

**Investigación SRE paso a paso:**

1. **Extraer la razón detallada del scheduler:**
   ```bash
   $ kubectl describe pod <pod-name> -n <namespace> | grep -A 10 "Events:"
   ```
2. **Analizar Fallas de Predicados (Predicate Failures):**
   * `untolerated taint`: Indica que el nodo de destino tiene un taint (`spec.taints`) que el Pod no coincide explícitamente en `spec.tolerations`. Verificar los taints del nodo usando:
     ```bash
     $ kubectl get node <node-name> -o jsonpath='{.spec.taints}' | jq .
     ```
   * `node(s) didn't match Pod's node affinity label selector`: El nodo carece de las etiquetas requeridas enumeradas en `spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution`.
3. **Verificar las Etiquetas de Nodo contra el Admission Plugin NodeRestriction:**
   * Si un Kubelet intentó etiquetarse a sí mismo en un nodo para atraer a un Pod pero la etiqueta fue rechazada, verificar los registros de auditoría de `kube-apiserver` para denegaciones de `NodeRestriction`:
     ```bash
     $ grep "NodeRestriction" /var/log/kubernetes/kube-apiserver-audit.log | grep "denied"
     ```

### Procedimiento de Diagnóstico 2: `kube-scheduler` No Saludable / Degradación del Control Plane

**Síntoma:** Los Pods creados en el clúster no están siendo asignados a nodos. `spec.nodeName` permanece vacío y `kubectl get componentstatuses` o los chequeos de salud fallan.

1. **Verificar los Registros del Pod Estático de `kube-scheduler`:**
   ```bash
   $ crictl logs $(crictl ps --name kube-scheduler -q)
   ```
2. **Causa Raíz Común 1: Expiración de Certificado o Falla de Autorización:**
   * *Firma del Registro (Log):* `http: TLS handshake error` o `Unauthorized` / `403 Forbidden` al llamar a `kube-apiserver`.
   * *Resolución:* Verificar la validez del certificado de cliente de `/etc/kubernetes/scheduler.conf`:
     ```bash
     $ openssl x509 -in /etc/kubernetes/pki/scheduler.crt -noout -dates -issuer -subject
     ```
3. **Causa Raíz Común 2: Bloqueo de Elección de Liderazgo (Leadership Election Lockout):**
   * *Firma del Registro (Log):* `failed to acquire lease kube-system/kube-scheduler: leader election lost`
   * *Resolución:* Verificar la desviación del reloj (clock drift) del control plane a través de los nodos master usando `chronyc tracking` o `ntpstat`. Verificar la conectividad a `coordination.k8s.io/leases` a través de `kube-apiserver`.

### Métricas Clave de Prometheus en Producción para Monitoreo SRE

* `scheduler_scheduling_attempt_duration_seconds_bucket`: Distribución de latencia de los ciclos de programación. Alta latencia indica restricciones excesivamente complejas de PodAntiAffinity o TopologySpread.
* `scheduler_pod_scheduling_attempts_count{result="unschedulable"}`: Contador de intentos de Pods no programables. Los picos indican saturación de recursos o malas configuraciones de políticas.
* `scheduler_leader_election_master_status`: Gauge binario (1/0) que indica el estado de liderazgo activo por instancia de scheduler.

---

## 6. Referencias

* **Documentación Oficial de Kubernetes - Referencia de kube-scheduler:**  
  https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
* **Documentación Oficial de Kubernetes - Endurecimiento de Kube-Scheduler:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
* **Documentación Oficial de Kubernetes - KubeSchedulerConfiguration (v1):**  
  https://kubernetes.io/docs/reference/config-api/kube-scheduler-config.v1/
* **Documentación Oficial de Kubernetes - Asignación de Pods a Nodos:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
* **Documentación Oficial de Kubernetes - Taints y Tolerations:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
* **Documentación Oficial de Kubernetes - Pod Topology Spread Constraints:**  
  https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
* **Documentación Oficial de Kubernetes - Admission Plugin NodeRestriction:**  
  https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
* **Plan de Estudios del Examen CNCF KCSA:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf