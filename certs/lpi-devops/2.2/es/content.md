# LPI DevOps Tools Engineer (Exam 701-100, v1.0)
## Topic 2.2: Container Deployment and Orchestration (Weight: 8.33)

---

## 1. Motivación en Producción y Problema Arquitectónico

### 1.1 El Modelo de Falla Imperativo de Single-Host
En entornos contenedorizados autónomos (por ejemplo, ejecutando aplicaciones directamente a través de `docker run` en Máquinas Virtuales individuales), la gestión de la infraestructura se basa en un modelo de ciclo de vida imperativo. Esta arquitectura sufre de vulnerabilidades operativas fundamentales cuando se escala a entornos de producción de alta concurrencia:

*   **Ausencia de Reconciliación Automatizada de Estado:** Si un proceso contenedorizado se interrumpe o encuentra una excepción no controlada, el demonio del SO host puede reiniciar el contenedor localmente. Sin embargo, si el host físico o virtual subyacente sufre un kernel panic, una falla de hardware o una partición de red, el estado de la aplicación se pierde por completo sin capacidades de failover multi-host.
*   **Asignación Imperativa de Puertos y Colisiones de Vinculación Dinámica:** Las implementaciones single-host requieren mapeos de puertos host estáticos o semiestáticos (`-p 8080:80`). Ejecutar múltiples instancias del mismo servicio en un solo host crea conflictos de vinculación de sockets a menos que se implemente una lógica externa y compleja de gestión dinámica de puertos.
*   **Aislamiento de Red Estático:** Las redes bridge predeterminadas de contenedores operan en switches virtuales locales del host (`docker0`). La comunicación entre contenedores multi-host requiere enrutamiento IP estático, configuraciones NAT personalizadas o tunelización SSH manual, lo que rompe el descubrimiento de servicios estándar de microservicios.
*   **Deriva Operativa y Escalado Manual:** El escalado horizontal requiere la ejecución imperativa de comandos de despliegue a través de nodos de destino dispares. No existe un bucle de control central que audite si los estados desplegados reales coinciden con las topologías de infraestructura definidas.

### 1.2 Requisito Empresarial: Reconciliación Declarativa de Estado
La orquestación de contenedores de nivel de producción reemplaza los comandos de ciclo de vida imperativo con un **Control Loop Engine** (Reconciliation Loop) continuo.

```
                       +-------------------------+
                       |    Desired State        |
                       | (Declarative Manifest)  |
                       +------------+------------+
                                    |
                                    v
+-------------------+      +------------------+      +-------------------+
|  Observed State   | ---> |  Reconciliation  | ---> |   Corrective      |
|  (Current Cluster)|      |  Engine (Diff)   |      |   Action (Control)|
+-------------------+      +------------------+      +-------------------+
          ^                                                    |
          |                                                    v
          +----------------- Actual Infrastructure <-----------+
```

El sistema de orquestación calcula continuamente el delta $\Delta$ entre el **Desired State** $S_{desired}$ (especificado a través de esquemas declarativos YAML/JSON) y el **Observed State** $S_{observed}$ (sondeado a través de agentes de nodo):

$$\Delta = S_{desired} \setminus S_{observed}$$

Si $\Delta \neq \emptyset$, el control plane de orquestación emite mutaciones de bajo nivel para restaurar la igualdad (por ejemplo, reprogramando Pods en nodos worker saludables, iniciando réplicas faltantes o reconfigurando los objetivos del ingress load balancer).

---

## 2. Mecánica Técnica Profunda y Matriz de Trade-offs

### 2.1 Análisis Profundo de la Arquitectura

#### Docker Compose
Docker Compose es una utilidad de orquestación de múltiples contenedores single-host del lado del cliente.
*   **Mecánica:** Traduce un manifiesto multiservicio `docker-compose.yml` en llamadas directas a la API del Docker Engine a través del socket Unix (`/var/run/docker.sock`).
*   **Control Plane:** Ninguno. La herramienta CLI actúa como el motor transitorio. Una vez creados los recursos, no se ejecuta ningún bucle de reconciliación externo persistente a menos que se invoque a través de comandos CLI como `docker compose up -d`.
*   **Networking:** Automatiza la creación de redes bridge definidas por el usuario a nivel de host con resolución DNS integrada por nombre de servicio.

#### Docker Swarm
Docker Swarm proporciona una gestión de clústeres nativa e integrada en el motor con capacidades overlay multi-host.
*   **Control Plane y Consenso:** Utiliza el **Algoritmo de Consenso Raft** entre un número impar de nodos Manager (se recomiendan 3 o 5) para mantener la consistencia del estado. Los nodos Worker reciben tareas a través de streams gRPC.
*   **Ingress Mesh y Networking:** Utiliza una Ingress Overlay Network aprovechando el kernel de Linux **IPVS** (IP Virtual Server) y la encapsulación **VXLAN** (puerto UDP 4789). Las solicitudes a los puertos de servicio publicados en *cualquier* nodo Swarm se enrutan a través del Routing Mesh a tareas saludables en todo el clúster.
*   **Ciclo de Vida de Tareas:** Las definiciones de servicio se dividen en `Tasks` inmutables (contenedores), programadas en nodos worker utilizando identificadores de ranura internos.

#### Kubernetes (K8s)
Kubernetes es una plataforma de orquestación de contenedores distribuida, desacoplada y de nivel empresarial.
*   **Topología del Control Plane:** 
    *   `kube-apiserver`: Expone la API REST; actúa como el centro neurálgico para todos los cambios de estado.
    *   `etcd`: Almacén de clave-valor distribuido y fuertemente consistente que mantiene el estado del clúster.
    *   `kube-scheduler`: Asigna Pods no asignados a nodos en función de las restricciones de recursos, afinidad/antiafinidad y taints/tolerations.
    *   `kube-controller-manager`: Ejecuta los bucles de control principales (Deployment, ReplicaSet, Node Controllers).
*   **Componentes del Nodo:**
    *   `kubelet`: Agente de nodo que garantiza que los contenedores descritos en los `PodSpecs` se estén ejecutando y estén saludables.
    *   `kube-proxy` / `eBPF`: Gestiona las reglas de enrutamiento de red (iptables o IPVS) para mapear las IPs virtuales del `Service` a endpoints de `Pod`.
    *   `Container Runtime Interface (CRI)`: Interfaz de abstracción que interactúa con runtimes como `containerd` o `CRI-O`.

### 2.2 Matriz de Trade-offs de Orquestación

| Feature / Dimensión | Docker Compose | Docker Swarm | Kubernetes (K8s) |
| :--- | :--- | :--- | :--- |
| **Complejidad Operativa** | Extremadamente baja (Cero sobrecarga de clúster) | Baja (Motor integrado, inicialización con un solo comando) | Alta (Requiere gestión de ETCD, configuración del control plane, CNI, CSI) |
| **Mecanismo de Consenso** | Ninguno (Demonio de host único) | Raft integrado (Almacenamiento de estado interno) | Clúster etcd distribuido externo |
| **Arquitectura de Escalado** | Escalado de contenedores en host único | Replicación nativa de servicios a través de nodos | ReplicaSets escalables, Horizontal Pod Autoscalers (HPA/KEDA) |
| **Modelo de Networking** | Redes bridge locales del host | Overlay basado en VXLAN con Routing Mesh IPVS | Arquitectura de plugins CNI (Calico, Cilium, Flannel) con espacios de IP de Pod planos |
| **Abstracción de Almacenamiento** | Bindings de volúmenes de host y volúmenes nombrados | Volúmenes locales, plugins de volúmenes (REX-Ray) | StorageClasses, PersistentVolumes (PV), PersistentVolumeClaims (PVC), CSI |
| **Extensibilidad** | Mínima (Limitada a la especificación de Compose) | Baja (Capacidades fijas del Docker Engine) | Alta (Custom Resource Definitions - CRDs, Operators, Admission Webhooks) |
| **Objetivo de Producción** | Dev, Staging, Pruebas de Integración Local | Despliegues Multi-Host de Pequeña a Mediana Escala | Microservicios Empresariales a Gran Escala, Cargas de Trabajo Cloud-Native |

---

## 3. Manifiestos Completos Listos para Producción

### 3.1 Docker Compose Multicontenedor para Producción (`docker-compose.yml`)
```yaml
version: '3.8'

services:
  app-server:
    image: redis:7.2-alpine
    container_name: production_cache
    restart: always
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "Secr3tP@ssw0rd!"]
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - backend-network
    resources:
      limits:
        cpus: '0.50'
        memory: 512M
      reservations:
        cpus: '0.25'
        memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a Secr3tP@ssw0rd! ping | grep PONG"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  backend-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16

volumes:
  redis_data:
    driver: local
```

### 3.2 Stack de Docker Swarm para Producción (`docker-stack.yml`)
```yaml
version: '3.8'

services:
  web-service:
    image: nginx:1.25-alpine
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: ingress
    networks:
      - overlay-frontend
    environment:
      - NODE_ENV=production
    deploy:
      mode: replicated
      replicas: 4
      placement:
        constraints:
          - node.role == worker
          - node.labels.tier == frontend
        preferences:
          - spread: node.topology.zone
      update_config:
        parallelism: 2
        delay: 10s
        failure_action: rollback
        monitor: 15s
        max_failure_ratio: 0.15
        order: start-first
      rollback_config:
        parallelism: 1
        delay: 5s
        failure_action: pause
        order: stop-first
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 120s
      resources:
        limits:
          cpus: '1.00'
          memory: 1024M
        reservations:
          cpus: '0.20'
          memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:80/ || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 10s

networks:
  overlay-frontend:
    driver: overlay
    attachable: false
```

### 3.3 Manifiesto Declarativo de Kubernetes para Producción (`k8s-production-app.yaml`)
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-workloads
  labels:
    environment: production
    security-tier: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: production-workloads
data:
  LOG_LEVEL: "info"
  HTTP_PORT: "8080"
  ENABLE_METRICS: "true"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: production-workloads
type: Opaque
stringData:
  DB_PASSWORD: "SuperUnbreakableProdSecret2026!"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-api-service
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: core-api
    app.kubernetes.io/part-of: e-commerce-platform
    app.kubernetes.io/managed-by: kubectl
spec:
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: core-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: core-api
        environment: production
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/name
                      operator: In
                      values:
                        - core-api
                topologyKey: kubernetes.io/hostname
      containers:
        - name: api-container
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Core API v1 Running"
            - "-listen=:8080"
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: http-port
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: app-config
            - secretRef:
                name: app-secrets
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: core-api-svc
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: core-api
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: core-api
  ports:
    - name: http
      port: 80
      targetPort: http-port
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: core-api-ingress
  namespace: production-workloads
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  rules:
    - host: api.production.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: core-api-svc
                port:
                  name: http
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal

### 4.1 Operaciones de Docker Swarm

#### Inicialización del Clúster y Verificación de Nodos
```bash
$ docker swarm init --advertise-addr 192.168.10.10
```
```text
Swarm initialized: current node (m17xz3l899gqkhu1a462pyjtr) is now a manager.

To add a worker to this swarm, run the following command:
    docker swarm join --token SWMTKN-1-49mg50wxn35k21n23z342v0-9vj102148124981 192.168.10.10:2377

To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.
```

```bash
$ docker node ls
```
```text
ID                          HOSTNAME       STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
m17xz3l899gqkhu1a462pyjtr * node-01-mgr   Ready     Active         Leader           24.0.5
p992ks0219kskcjj1902ks018   node-02-wrk   Ready     Active                          24.0.5
z1029ksj10291029381029311   node-03-wrk   Ready     Active                          24.0.5
```

#### Despliegue del Stack y Auditoría de Tareas
```bash
$ docker stack deploy -c docker-stack.yml prod_app
```
```text
Creating network prod_app_overlay-frontend
Creating service prod_app_web-service
```

```bash
$ docker service ls
```
```text
ID             NAME                   MODE         REPLICAS   IMAGE              PORTS
z8219x01829a   prod_app_web-service   replicated   4/4        nginx:1.25-alpine   *:80->80/tcp
```

```bash
$ docker service ps prod_app_web-service
```
```text
ID             NAME                     IMAGE              NODE           DESIRED STATE   CURRENT STATE            ERROR     PORTS
1a2b3c4d5e6f   prod_app_web-service.1   nginx:1.25-alpine   node-02-wrk    Running         Running 2 minutes ago              
7g8h9i0j1k2l   prod_app_web-service.2   nginx:1.25-alpine   node-03-wrk    Running         Running 2 minutes ago              
3m4n5o6p7q8r   prod_app_web-service.3   nginx:1.25-alpine   node-02-wrk    Running         Running 2 minutes ago              
9s0t1u2v3w4x   prod_app_web-service.4   nginx:1.25-alpine   node-03-wrk    Running         Running 2 minutes ago              
```

---

### 4.2 Administración de Clústeres de Kubernetes

#### Aplicación de Manifiestos y Verificación del Estado del Despliegue
```bash
$ kubectl apply -f k8s-production-app.yaml
```
```text
namespace/production-workloads created
configmap/app-config created
secret/app-secrets created
deployment.apps/core-api-service created
service/core-api-svc created
ingress.networking.k8s.io/core-api-ingress created
```

```bash
$ kubectl get pods -n production-workloads -o wide
```
```text
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
core-api-service-6799659b8d-4k9l1   1/1     Running   0          42s   10.244.1.15   worker-node-1   <none>           <none>
core-api-service-6799659b8d-7x2zp   1/1     Running   0          42s   10.244.2.22   worker-node-2   <none>           <none>
core-api-service-6799659b8d-m8w9q   1/1     Running   0          42s   10.244.3.18   worker-node-3   <none>           <none>
```

#### Ciclo de Vida del Rolling Update y Seguimiento del Rollout
```bash
$ kubectl set image deployment/core-api-service api-container=hashicorp/http-echo:1.0.1 -n production-workloads
```
```text
deployment.apps/core-api-service image updated
```

```bash
$ kubectl rollout status deployment/core-api-service -n production-workloads
```
```text
Waiting for deployment "core-api-service" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "core-api-service" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "core-api-service" rollout to finish: 1 old replicas are pending termination...
deployment "core-api-service" successfully rolled out
```

#### Agregación de Logs a Través de Label Selectors
```bash
$ kubectl logs -n production-workloads -l app.kubernetes.io/name=core-api --tail=10
```
```text
[2026-08-07T04:45:30.102Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:32.405Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:35.101Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
[2026-08-07T04:45:37.404Z] "GET /healthz HTTP/1.1" 200 21 "-" "kube-probe/1.28"
```

---

## 5. Guía de Verificación y Resolución de Fallas (Troubleshooting)

```
                        +----------------------------------+
                        |  Container/Pod Failure Detected  |
                        +-----------------+----------------+
                                          |
                                          v
                        +----------------------------------+
                        | Exec: kubectl describe pod <pod> |
                        +-----------------+----------------+
                                          |
                  +-----------------------+-----------------------+
                  |                                               |
                  v                                               v
      [ Event: OOMKilled / Crash ]                    [ State: Pending ]
                  |                                               |
        +---------+---------+                           +---------+---------+
        | Exited with Code 137|                           | Resource Quotas |
        +---------+---------+                           | Taints & Tolerations
                  |                                     +---------+---------+
                  v                                               |
    Increase limits in PodSpec                                    v
                                                        Check `kubectl describe node`
```

### 5.1 Matriz de Diagnóstico: Fallas Comunes en Producción

#### 1. Pod In `CrashLoopBackOff` (Exit Code 137)
*   **Causa Raíz:** El proceso del contenedor superó el límite de memoria configurado en la especificación del Pod, lo que activó el Out-Of-Memory (OOM) Killer del Kernel de Linux.
*   **Comandos de Inspección:**
    ```bash
    $ kubectl describe pod core-api-service-6799659b8d-4k9l1 -n production-workloads
    ```
*   **Indicador Clave en la Salida del Log:**
    ```text
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 07 Aug 2026 04:30:00 -0400
      Finished:     Fri, 07 Aug 2026 04:31:12 -0400
    ```
*   **Remediación:** Aumentar `resources.limits.memory` en la especificación del Deployment o identificar fugas de memoria utilizando perfiles de heap.

#### 2. Pod Stuck In `Pending` State
*   **Causa Raíz:** El Scheduler no puede ubicar el Pod debido a solicitudes insuficientes de CPU/memoria, taints de nodo o reglas estrictas de PodAntiAffinity.
*   **Comandos de Inspección:**
    ```bash
    $ kubectl get events -n production-workloads --sort-by='.metadata.creationTimestamp'
    ```
*   **Indicador Clave en la Salida del Log:**
    ```text
    TYPE      REASON             OBJECT                                  MESSAGE
    Warning   FailedScheduling   pod/core-api-service-6799659b8d-9z9z9   0/3 nodes are available: 3 Insufficient memory, 3 node(s) didn't match PodAntiAffinity rules.
    ```
*   **Remediación:** Aprovisionar nodos worker adicionales, reducir `resources.requests` o ajustar las reglas de afinidad.

#### 3. Service Connectivity Failure (DNS & CNI Routing)
*   **Causa Raíz:** Falla en la resolución de CoreDNS o el plugin CNI descarta rutas de paquetes entre nodos.
*   **Flujo de Trabajo de Inspección:**
    *   Desplegar un contenedor efímero de diagnóstico de red:
        ```bash
        $ kubectl run net-debug --rm -i --tty --image=nicolaka/netshoot -n production-workloads -- bash
        ```
    *   Realizar una búsqueda DNS interna y una prueba de socket dentro del namespace de red del clúster:
        ```bash
        # Inside netshoot shell:
        $ nslookup core-api-svc.production-workloads.svc.cluster.local
        $ nc -zvw3 core-api-svc 80
        ```
    *   **Respuesta de Éxito Esperada:**
        ```text
        Server:         10.96.0.10
        Address:        10.96.0.10#53

        Name:   core-api-svc.production-workloads.svc.cluster.local
        Address: 10.108.140.91

        Connection to core-api-svc 80 port [tcp/http] succeeded!
        ```

---

## 6. Referencias

*   **Linux Professional Institute (LPI) DevOps Tools Engineer Official Overview:**
    [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
*   **Docker Compose File Specification:**
    [https://docs.docker.com/compose/compose-file/](https://docs.docker.com/compose/compose-file/)
*   **Docker Swarm Mode Overview & Architecture:**
    [https://docs.docker.com/engine/swarm/](https://docs.docker.com/engine/swarm/)
*   **Kubernetes Concepts & Production Workloads Documentation:**
    [https://kubernetes.io/docs/concepts/](https://kubernetes.io/docs/concepts/)
*   **Kubernetes Application Debugging Guide:**
    [https://kubernetes.io/docs/tasks/debug/debug-application/](https://kubernetes.io/docs/tasks/debug/debug-application/)