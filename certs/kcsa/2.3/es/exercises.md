# Guía de Estudio KCSA: Tema 2.3 – Mecánica y Hardening de Seguridad del Scheduler de Kubernetes

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 2.0:** Arquitectura y Seguridad de Kubernetes  
**Tema 2.3:** Scheduler  
**Peso:** 2.0%  

---

## Documentación Oficial de Referencia
- **Currículum KCSA de CNCF:** [KCSA Curriculum v1.0.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Arquitectura del Scheduler de Kubernetes:** [kube-scheduler Concepts](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
- **Aislamiento de Nodos con Taints & Tolerations:** [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- **Node Affinity y Selección:** [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- **Pod Anti-Affinity y Distribución de Skew:** [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- **Prioridad de Pods y Seguridad de Preemption:** [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- **Configuración de Seguridad de Kube-Scheduler:** [Scheduler Configuration API (v1)](https://kubernetes.io/docs/reference/scheduling/config/)
- **Plugin de Admisión NodeRestriction:** [NodeRestriction Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction)

---

## Visión General de Arquitectura y Seguridad

El `kube-scheduler` es un componente central del control plane responsable de asignar Pods no programados (`spec.nodeName: ""`) a worker nodes óptimos basándose en la disponibilidad de recursos, restricciones de políticas, affinities de seguridad y taints de nodos.

```
                  +-------------------------------------------------------+
                  |                  kube-apiserver                       |
                  +-------------------------------------------------------+
                                   ^                    |
                   Watch Unbound   |                    | Bind Pod to Node
                   Pods            |                    v
             +-----------------------------------------------------------------+
             |                        kube-scheduler                           |
             |                                                                 |
             |  +-----------------------------------------------------------+  |
             |  |                     Scheduling Cycle                      |  |
             |  |                                                           |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  |  | Filter Phase  | -> | Scoring Phase | -> |  Reserve  |  |  |
             |  |  | (Node fit?)   |    | (Rank nodes)  |    |  Plugin   |  |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  +-----------------------------------------------------------+  |
             |                                 |                               |
             |  +------------------------------v----------------------------+  |
             |  |                       Binding Cycle                       |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  |  |  Permit/Pre   | -> |  Bind Plugin  | -> | Post-Bind |  |  |
             |  |  |  Bind Plugins |    | (Set nodeName)|    |   Plugin  |  |  |
             |  |  +---------------+    +---------------+    +-----------+  |  |
             |  +-----------------------------------------------------------+  |
             +-----------------------------------------------------------------+
```

### Implicaciones de Seguridad en Clusters Multi-Tenant
1. **Riesgos de Co-ubicación de Cargas de Trabajo:** Los contenedores maliciosos o no confiables co-ubicados en el mismo nodo físico que cargas de trabajo sensibles pueden intentar ataques de canal lateral (ej. Spectre/Meltdown, DoS por vecino ruidoso [noisy-neighbor], exploits de IPC local/sistema de archivos).
2. **Agotamiento de Recursos y Preemption No Controlada:** Los pods maliciosos de alta prioridad pueden forzar la preemption de pods críticos del sistema o de seguridad si `PriorityClass` y `preemptionPolicy` no están gestionados.
3. **Spoofing de Identidad de Kubelet:** Los worker nodes comprometidos que intenten alterar los node labels para atraer pods de alta seguridad son frustrados por el admission controller `NodeRestriction`.
4. **Exposición del Control Plane:** Los endpoints de métricas de `kube-scheduler` no asegurados (`10259/tcp`) pueden filtrar metadata sensible de la topología de las cargas de trabajo si no están autenticados.

---

## Ejercicios Prácticos de Laboratorio Guiado

### Prerrequisitos
Un cluster de Kubernetes en ejecución (v1.28+) con al menos 3 worker nodes. Asegurate de que `kubectl` esté configurado con privilegios de `cluster-admin`.

---

### Módulo 1: Hardening del Aislamiento de Nodos Multi-Tenant mediante Taints, Tolerations y Node Affinity

#### Escenario
Desplegar un pool de nodos dedicado y conforme a PCI-DSS. Asegurar que solo las cargas de trabajo de Payment Gateway con tolerations explícitas puedan ejecutarse en estos nodos, al tiempo que se aplica node affinity estricta (hard node affinity) para que las cargas de trabajo de PCI nunca caigan en nodos no seguros.

#### Paso 1.1: Etiquetar y Aplicar Taint al Nodo Seguro Dedicado
Aplicar un taint de seguridad y un node label a `worker-node-01`.

```bash
kubectl label node worker-node-01 security-zone=pci-dss --overwrite
kubectl taint nodes worker-node-01 security-zone=pci-dss:NoSchedule --overwrite
```

**Salida Esperada:**
```text
node/worker-node-01 labeled
node/worker-node-01 tainted
```

Verificar la configuración del taint:
```bash
kubectl get node worker-node-01 -o jsonpath='{.spec.taints}' | jq .
```

**Salida Esperada:**
```json
[
  {
    "effect": "NoSchedule",
    "key": "security-zone",
    "value": "pci-dss"
  }
]
```

#### Paso 1.2: Desplegar una Carga de Trabajo No Confiable para Verificar el Rechazo
Crear `untrusted-app.yaml` para asegurar que las cargas de trabajo estándar no puedan programarse en `worker-node-01`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: untrusted
  template:
    metadata:
      labels:
        app: untrusted
    spec:
      containers:
      - name: nginx
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Aplicar y verificar la ubicación de los pods:
```bash
kubectl apply -f untrusted-app.yaml
kubectl get pods -o wide -l app=untrusted
```

**Salida Esperada:**
```text
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
untrusted-app-76b9f485b-24g8q    1/1     Running   0          5s    10.244.1.5   worker-node-02   <none>           <none>
untrusted-app-76b9f485b-9jxlp    1/1     Running   0          5s    10.244.2.8   worker-node-03   <none>           <none>
untrusted-app-76b9f485b-kld92    1/1     Running   0          5s    10.244.2.9   worker-node-03   <none>           <none>
```
*Notá que `worker-node-01` fue completamente excluido por el plugin de filtrado del scheduler (`TaintToleration`).*

#### Paso 1.3: Desplegar un Pod de Pago Hardened mediante Aislamiento de Dos Vías
El aislamiento de dos vías requiere:
1. **Tolerations**: Permite que el pod tolere el taint del nodo (permite la programación en `worker-node-01`).
2. **Node Affinity (`requiredDuringSchedulingIgnoredDuringExecution`)**: Evita que el pod se programe en cualquier nodo *diferente* de `worker-node-01`.

Crear `payment-processor.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
        tier: secure
    spec:
      tolerations:
      - key: "security-zone"
        operator: "Equal"
        value: "pci-dss"
        effect: "NoSchedule"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: security-zone
                operator: In
                values:
                - pci-dss
      containers:
      - name: payment-app
        image: registry.k8s.io/pause:3.9
        resources:
          limits:
            cpu: 200m
            memory: 256Mi
          requests:
            cpu: 200m
            memory: 256Mi
```

Aplicar el deployment y verificar el estado:
```bash
kubectl apply -f payment-processor.yaml
kubectl get pods -o wide -l app=payment-processor
```

**Salida Esperada:**
```text
NAME                                 READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
payment-processor-6df958c89b-8vkw2   1/1     Running   0          12s   10.244.1.80  worker-node-01   <none>           <none>
payment-processor-6df958c89b-x9pz4   1/1     Running   0          12s   10.244.1.81  worker-node-01   <none>           <none>
```

#### Preguntas para el Módulo 1
1. **Pregunta 1.1:** Si un deployment especifica las `tolerations` correctas para `security-zone=pci-dss:NoSchedule` pero NO especifica `nodeAffinity`, ¿dónde puede ubicar sus pods el scheduler?
2. **Pregunta 1.2:** ¿Cuál es el riesgo operativo crítico de seguridad al usar `preferredDuringSchedulingIgnoredDuringExecution` en lugar de `requiredDuringSchedulingIgnoredDuringExecution` para la node affinity en cargas de trabajo reguladas?

---

### Módulo 2: Mitigación del Radio de Impacto de Co-Ubicación mediante Pod Anti-Affinity & Topology Spread Constraints

#### Escenario
Aplicar un aislamiento físico estricto entre pods de diferentes niveles de seguridad utilizando `podAntiAffinity`, y garantizar una distribución equilibrada de alta disponibilidad (skew) entre nodos usando `topologySpreadConstraints` para mitigar los riesgos de Denegación de Servicio (DoS).

#### Paso 2.1: Aplicar Pod Anti-Affinity Estricta
Crear un deployment para el servicio de vault seguro (`vault-service.yaml`) que rechace ejecutarse en cualquier nodo que ya ejecute otra instancia de `vault-service` o cualquier pod de app no confiable.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-service
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vault-service
  template:
    metadata:
      labels:
        app: vault-service
        security-level: high
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - vault-service
                - untrusted
            topologyKey: "kubernetes.io/hostname"
      containers:
      - name: vault
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

Aplicar el deployment:
```bash
kubectl apply -f vault-service.yaml
kubectl get pods -o wide -l app=vault-service
```

#### Paso 2.2: Diagnosticar Fallas en el Filtrado de Anti-Affinity del Scheduler
Inspeccionar los pods cuando los nodos disponibles sean insuficientes para satisfacer las restricciones estrictas de anti-affinity.

```bash
kubectl scale deployment vault-service --replicas=5
kubectl get pods -l app=vault-service
```

**Salida Esperada:**
```text
NAME                             READY   STATUS    RESTARTS   AGE
vault-service-595b76686-2nm49    1/1     Running   0          40s
vault-service-595b76686-7x9kl    1/1     Running   0          40s
vault-service-595b76686-m9z8p    0/1     Pending   0          10s
vault-service-595b76686-q4w12    0/1     Pending   0          10s
vault-service-595b76686-v8p5x    0/1     Pending   0          10s
```

Ejecutar `kubectl describe` para extraer los registros de eventos del plugin de filtrado del scheduler:
```bash
kubectl describe pod -l app=vault-service --field-selector status.phase=Pending | grep -A 5 "Events:"
```

**Salida Esperada:**
```text
Events:
  Type     Reason            Age   From              Message
  ----     ------            ----  ----              -------
  Warning  FailedScheduling  24s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint {security-zone: pci-dss}, 2 node(s) didn't match pod anti-affinity rules. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Reducir la escala nuevamente:
```bash
kubectl scale deployment vault-service --replicas=2
```

#### Paso 2.3: Aplicar Topology Spread Constraints Seguros
Crear un deployment de agente de seguridad tolerante a fallas en múltiples zonas utilizando `topologySpreadConstraints` para asegurar una distribución de skew estricta y evitar un único punto de falla por radio de impacto en un solo nodo.

Crear `security-agent.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: security-agent
  namespace: default
spec:
  replicas: 4
  selector:
    matchLabels:
      app: security-agent
  template:
    metadata:
      labels:
        app: security-agent
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: "kubernetes.io/hostname"
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: security-agent
      containers:
      - name: agent
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
```

Aplicar e inspeccionar la distribución en los nodos:
```bash
kubectl apply -f security-agent.yaml
kubectl get pods -o wide -l app=security-agent
```

#### Preguntas para el Módulo 2
1. **Pregunta 2.1:** ¿Cuál es la diferencia en la evaluación del scheduler entre `whenUnsatisfiable: DoNotSchedule` y `whenUnsatisfiable: ScheduleAnyway` en `topologySpreadConstraints` desde el punto de vista de disponibilidad vs límite de seguridad?
2. **Pregunta 2.2:** ¿Por qué `topologyKey: "kubernetes.io/hostname"` es crítico al configurar anti-affinity contra pods de tenants no confiables?

---

### Módulo 3: PriorityClasses, Seguridad de Preemption y Mitigación de DoS

#### Escenario
Evitar que los pods de tenants no confiables desalojen (preempt) componentes críticos de seguridad del cluster durante eventos de escasez de recursos en los nodos.

#### Paso 3.1: Crear PriorityClasses de Seguridad Estándar
Definir dos `PriorityClasses`:
1. `critical-security-sys`: Alta prioridad, permite la preemption de pods de menor prioridad.
2. `untrusted-tenant-workload`: Baja prioridad, desactiva explícitamente la preemption para evitar desencadenar cascadas de desalojo.

Crear `priority-classes.yaml`:

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-security-sys
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Used exclusively for mission-critical security controllers and daemonsets."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: untrusted-tenant-workload
value: 5000
globalDefault: false
preemptionPolicy: Never
description: "Non-critical tenant workloads. Cannot trigger preemption of existing pods."
```

Aplicar los manifiestos:
```bash
kubectl apply -f priority-classes.yaml
kubectl get priorityclasses | grep -E "critical-security-sys|untrusted-tenant-workload"
```

**Salida Esperada:**
```text
critical-security-sys      1000000     false   10s
untrusted-tenant-workload  5000        false   10s
```

#### Paso 3.2: Verificar el Comportamiento de Seguridad de Preemption
Desplegar un pod de tenant con `preemptionPolicy: Never` que solicite CPU alta durante límites de capacidad del nodo.

Crear `high-resource-tenant.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: high-resource-tenant
  namespace: default
spec:
  priorityClassName: untrusted-tenant-workload
  containers:
  - name: stress
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: "32"
```

Aplicar y verificar:
```bash
kubectl apply -f high-resource-tenant.yaml
kubectl get pod high-resource-tenant
```

Inspeccionar los detalles de los eventos para confirmar el comportamiento de preemption:
```bash
kubectl describe pod high-resource-tenant | grep -A 4 "Events:"
```

**Salida Esperada:**
```text
Events:
  Type     Reason            Age   From              Message
  ----     ------            ----  ----              -------
  Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available: 3 Insufficient cpu. preemption: 0/3 nodes are available: 3 Preemption is not eligible due to preemptionPolicy=Never.
```

Limpiar el pod de prueba:
```bash
kubectl delete pod high-resource-tenant
```

#### Preguntas para el Módulo 3
1. **Pregunta 3.1:** ¿Qué vulnerabilidad de seguridad se introduce si se permite que todas las cargas de trabajo de tenants usen las PriorityClasses integradas `system-cluster-critical` o `system-node-critical`?
2. **Pregunta 3.2:** ¿Cómo ayuda el establecer `preemptionPolicy: Never` en una `PriorityClass` a proteger a un cluster de una Denegación de Servicio (DoS) por vecino ruidoso?

---

### Módulo 4: Hardening de Seguridad de Kube-Scheduler y Auditoría de Diagnóstico

#### Escenario
Auditar la configuración del componente de control plane `kube-scheduler`, verificar la autenticación/autorización del endpoint de métricas y depurar la ejecución de plugins del framework del scheduler.

#### Paso 4.1: Inspeccionar los Parámetros de Seguridad del Componente del Control Plane
Acceder al nodo de control plane (o examinar `/etc/kubernetes/manifests/kube-scheduler.yaml`) para verificar los parámetros de hardening en la línea de comandos.

```bash
kubectl get pod -n kube-system -l component=kube-scheduler -o yaml | grep -A 20 "command:"
```

**Salida Esperada:**
```yaml
    - command:
      - kube-scheduler
      - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
      - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
      - --bind-address=127.0.0.1
      - --kubeconfig=/etc/kubernetes/scheduler.conf
      - --leader-elect=true
      - --config=/etc/kubernetes/kube-scheduler.yaml
```

**Checklist de Auditoría de Seguridad:**
- `--bind-address=127.0.0.1`: Asegura que los endpoints no autenticados de healthz/metrics no estén expuestos públicamente.
- `--authentication-kubeconfig` & `--authorization-kubeconfig`: Aplica RBAC en el endpoint HTTPS de métricas (`10259/tcp`).

#### Paso 4.2: Inspeccionar KubeSchedulerConfiguration (API v1)
Examinar el ConfigMap de `KubeSchedulerConfiguration` o el archivo de configuración del control plane para entender la ejecución del pipeline de plugins.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
clientConnection:
  kubeconfig: "/etc/kubernetes/scheduler.conf"
profiles:
  - schedulerName: default-scheduler
    plugins:
      filter:
        enabled:
          - name: NodeResourcesFit
          - name: NodeName
          - name: NodePorts
          - name: NodeAffinity
          - name: VolumeRestrictions
          - name: TaintToleration
        disabled:
          - name: "*"
      score:
        enabled:
          - name: NodeResourcesBalancedAllocation
            weight: 1
          - name: ImageLocality
            weight: 1
```

#### Paso 4.3: Consultar Métricas del Scheduler para Auditoría de Diagnóstico
Obtener las métricas de diagnóstico del scheduler a través de la interfaz HTTPS segura utilizando credenciales de service account o certificados locales del control plane.

Ejecutar localmente en el nodo de control plane:
```bash
sudo curl -k --cert /etc/kubernetes/pki/scheduler.crt --key /etc/kubernetes/pki/scheduler.key \
  https://127.0.0.1:10259/metrics | grep -E "scheduler_scheduling_attempt_attempts_total|scheduler_pod_scheduling_duration_seconds"
```

**Salida Esperada:**
```text
# HELP scheduler_scheduling_attempt_attempts_total [ALPHA] Number of attempts to schedule pods, broken down by result (scheduled, unschedulable, error).
# TYPE scheduler_scheduling_attempt_attempts_total counter
scheduler_scheduling_attempt_attempts_total{result="scheduled"} 42
scheduler_scheduling_attempt_attempts_total{result="unschedulable"} 3
```

#### Preguntas para el Módulo 4
1. **Pregunta 4.1:** ¿Qué fase del framework de Extension Points del `kube-scheduler` determina si un nodo tiene suficiente capacidad y satisface todas las reglas de seguridad (NodeAffinity, TaintToleration)?
2. **Pregunta 4.2:** ¿Por qué exponer las métricas de `kube-scheduler` en `0.0.0.0:10251` (HTTP no autenticado) se considera un problema de seguridad de alto riesgo?

---

### Módulo 5: Límites de Seguridad & Admission Controller NodeRestriction

#### Escenario
Evaluar el límite de seguridad entre los node labels del Kubelet y el Kube-Scheduler. Entender cómo el admission controller `NodeRestriction` evita que los kubelets de nodos worker comprometidos modifiquen las etiquetas utilizadas por el scheduler para el aislamiento de nodos.

```
+------------------+         Modified Node Labels       +-------------------+
| Compromised Node | ---------------------------------> |  kube-apiserver   |
|     Kubelet      |   (e.g., security-zone=pci-dss)    +-------------------+
+------------------+                                              |
                                                                  v
                                                        +-------------------+
                                                        |  NodeRestriction  |
                                                        |    Admission      |
                                                        +-------------------+
                                                                  |
                                              REJECTED 403        |  (Kubelets cannot
                                          <-----------------------+   modify node labels
                                                                      in node.kubernetes.io/
                                                                      or restricted prefixes)
```

#### Paso 5.1: Entender las Reglas de Etiquetas de NodeRestriction
El admission plugin `NodeRestriction` evita que los Kubelets creen o modifiquen etiquetas bajo el prefijo reservado `node.kubernetes.io/` o `node-role.kubernetes.io/`, así como modificar sus propios taints de nodo.

Verificar que `NodeRestriction` esté activo en el API Server:
```bash
kubectl get pod -n kube-system -l component=kube-apiserver -o yaml | grep -- "--enable-admission-plugins"
```

**Salida Esperada:**
```text
    - --enable-admission-plugins=NodeRestriction,NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota
```

#### Preguntas para el Módulo 5
1. **Pregunta 5.1:** Si las credenciales del kubelet de un nodo worker (`system:node:<node-name>`) son comprometidas por un atacante, ¿puede el atacante etiquetar manualmente su propio nodo con `node-role.kubernetes.io/infrastructure=""` o `node.kubernetes.io/secure="true"` para interceptar pods sensibles a través de NodeAffinity?
2. **Pregunta 5.2:** ¿Qué prefijos de etiquetas específicos están protegidos por `NodeRestriction` contra modificaciones no autorizadas del Kubelet?

---

## Soluciones & Respuestas

<details>
<summary>Hacé clic para expandir las respuestas de todos los módulos</summary>

### Respuestas del Módulo 1
- **Respuesta 1.1:** Si un pod tiene `tolerations` para el taint de un nodo pero carece de `nodeAffinity` (o `nodeSelector`), el scheduler puede ubicar el pod en **cualquier nodo** del cluster que cumpla con sus requerimientos de recursos, incluidos nodos de propósito general sin taints o el nodo con taint. Las tolerations **no** fuerzan la programación en nodos con taints; simplemente eliminan el filtro de exclusión.
- **Respuesta 1.2:** Usar `preferredDuringSchedulingIgnoredDuringExecution` (soft affinity) significa que si el pool de nodos seguros objetivo está a su máxima capacidad de recursos o temporalmente no disponible, el scheduler recurrirá como alternativa a ubicar el pod en **worker nodes no seguros y no confiables**. Para cargas de trabajo reguladas (PCI-DSS, HIPAA), esto viola los límites de cumplimiento normativo.

---

### Respuestas del Módulo 2
- **Respuestas 2.1:**
  - `whenUnsatisfiable: DoNotSchedule` (Requerimiento estricto): Mantiene el pod en estado `Pending` si la restricción de skew no puede satisfacerse. Esto prioriza el aislamiento de seguridad y los límites de tolerancia a fallas por sobre la disponibilidad del pod.
  - `whenUnsatisfiable: ScheduleAnyway` (Requerimiento flexible): Fuerza al scheduler a programar el pod en nodos que aumenten la desproporción (skew) si no existe un nodo ideal. Esto prioriza la disponibilidad por sobre el aislamiento topológico estricto.
- **Respuesta 2.2:** `topologyKey: "kubernetes.io/hostname"` evalúa la pod anti-affinity a nivel de **nodo físico/virtual individual**. Si `topologyKey` estuviera configurado en `topology.kubernetes.io/zone`, el scheduler evitaría que los pods se ejecuten en la misma *zona de disponibilidad de la nube*, en lugar de evitar que se ejecuten exactamente en el mismo host de nodo físico.

---

### Respuestas del Módulo 3
- **Respuesta 3.1:** Permitir que las cargas de trabajo de tenants no confiables hereden las PriorityClasses integradas `system-cluster-critical` o `system-node-critical` habilita un vector de **Denegación de Servicio (DoS)**. Un atacante puede desplegar pods de alta prioridad solicitando grandes volúmenes de recursos, haciendo que el scheduler desaloje y termine servicios críticos del cluster (como CoreDNS, plugins CNI Calico/Cilium o ingress controllers).
- **Respuesta 3.2:** Establecer `preemptionPolicy: Never` asegura que cuando un pod de tenant no pueda programarse debido a recursos insuficientes en el cluster, permanezca en estado `Pending` **sin desencadenar desalojos** o preemption de pods de menor prioridad.

---

### Respuestas del Módulo 4
- **Respuesta 4.1:** La **Fase de Filtrado (Filter Phase)** (Plugins que implementan la interfaz `FilterPlugin`, tales como `NodeAffinity`, `TaintToleration`, `NodeResourcesFit`). Si cualquier plugin de filtrado devuelve un estado diferente de Success, el nodo se remueve de la lista de candidatos antes de la puntuación (scoring).
- **Respuesta 4.2:** Los endpoints de métricas HTTP no autenticados exponen metadata detallada sobre las cargas de trabajo en ejecución, nombres de namespaces, volumen de programación de pods, métricas de capacidad de nodos y la topología de IP interna. Los atacantes pueden aprovechar estos datos de reconocimiento interno para realizar ataques dirigidos.

---

### Respuestas del Módulo 5
- **Respuesta 5.1:** **No.** El admission controller `NodeRestriction` valida las peticiones de las credenciales de nodo (`system:nodes`) y bloquea cualquier intento de un kubelet de agregar o modificar etiquetas prefijadas con `node.kubernetes.io/` o `node-role.kubernetes.io/`, así como modificar taints de nodo.
- **Respuesta 5.2:** `NodeRestriction` restringe el auto-etiquetado del kubelet para:
  - Etiquetas prefijadas con `node.kubernetes.io/`
  - Etiquetas prefijadas con `node-role.kubernetes.io/`
  - Etiquetas específicas como `kubernetes.io/hostname` y `kubernetes.io/arch`
  - Modificaciones del Kubelet a los taints del nodo (`spec.taints`)

</details>

---

## Puntos Clave para el Examen KCSA
1. **Aislamiento de Nodos de Dos Vías:** Requiere TANTO Taints/Tolerations COMO Hard Node Affinity (`requiredDuringSchedulingIgnoredDuringExecution`) para un aislamiento completo de nodos multi-tenant.
2. **Topología de Anti-Affinity:** `topologyKey: "kubernetes.io/hostname"` evita la co-ubicación a nivel de nodo; `topologySpreadConstraints` con `DoNotSchedule` aplica una distribución de alta disponibilidad estricta.
3. **Hardening de Preemption:** Usar `preemptionPolicy: Never` en clases de prioridad no confiables para mitigar ataques de DoS por desalojo de pods.
4. **Seguridad del Control Plane del Scheduler:** Siempre vincular con `--bind-address=127.0.0.1` y aplicar autenticación/autorización RBAC para las métricas en el puerto `10259/tcp`.
5. **Límite de NodeRestriction:** Las credenciales de nodo de Kubelet no pueden modificar etiquetas reservadas `node.kubernetes.io/` ni taints.