# LPI DevOps Tools Engineer (701-100) — Tema 2.2: Despliegue y Orquestación de Contenedores

## Referencias Oficiales
* **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Docker Compose Specification**: [https://docs.docker.com/compose/compose-file/](https://docs.docker.com/compose/compose-file/)
* **Kubernetes Workload Management**: [https://kubernetes.io/docs/concepts/workloads/controllers/deployment/](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
* **Kubernetes Application Troubleshooting**: [https://kubernetes.io/docs/tasks/debug/debug-application/](https://kubernetes.io/docs/tasks/debug/debug-application/)

---

## Análisis Arquitectónico Profundo y Visión General de la Mecánica

El despliegue y la orquestación de contenedores transicionan los entornos de ejecución contenedorizados independientes hacia topologías de producción resilientes y con capacidad de auto-recuperación (self-healing). Comprender la mecánica del motor subyacente es esencial para la arquitectura de sistemas de alta disponibilidad.

### Conceptos Arquitectónicos Clave
1. **Arquitectura del Motor de Orquestación de Contenedores**:
   * **Estado del Control Plane y Consenso**: Los motores (como Kubernetes o Docker Swarm) gestionan el estado deseado a través de almacenes distribuidos clave-valor (`etcd` para Kubernetes, Raft integrado para Swarm). Los bucles de reconciliación comparan periódicamente el estado de ejecución real con las especificaciones del estado deseado.
   * **Redes y Descubrimiento de Servicios**: Las redes superpuestas (Overlay networks: VXLAN, Geneve o IPVLAN enrutado por eBPF) asignan IPs distintas a las unidades de programación (Pods/Contenedores). El DNS interno (CoreDNS) mapea identificadores lógicos de servicios a endpoints dinámicos mediante mecanismos de proxy (`kube-proxy`, `iptables` o mapas eBPF).

2. **Mecánica de Programación (Scheduling) y Gestión de Recursos**:
   * **Filtrado y Puntuación (Filtering & Scoring)**: Los schedulers filtran nodos basándose en predicados (resource requests, taints/tolerations, node affinity) y puntúan los nodos cualificados para determinar la ubicación óptima.
   * **Linux Cgroups y Namespaces**: Los límites de recursos (`requests` y `limits`) se traducen directamente a los Control Groups del kernel de Linux (`cgroups v2`). Los límites de memoria configuran `memory.max`, activando el Out-Of-Memory (OOM) Killer (`oom-kill`) cuando se exceden. Los límites de CPU se mapean a cuotas del Completely Fair Scheduler (CFS) (`cpu.max`).

3. **Gestión del Ciclo de Vida y Health Probes**:
   * **Tipos de Probes**:
     * `startupProbe`: Retrasa la ejecución de las comprobaciones de liveness y readiness hasta que la aplicación finaliza la inicialización de arranque.
     * `livenessProbe`: Determina si el contenedor del proceso necesita ser eliminado y reiniciado.
     * `readinessProbe`: Determina si el tráfico debe enrutarse al endpoint del contenedor. El fallo de readiness elimina la IP de los backends del Service sin eliminar el contenedor.

---

## Bloque 1: Orquestación Avanzada Multi-Contenedor con Docker Compose

Este ejercicio cubre la construcción de una topología multi-contenedor de nivel empresarial utilizando Docker Compose v2. Incluye comprobaciones de estado (health checks), condiciones de dependencia explícitas, segmentación de red y ejecución sin privilegios de root (non-root).

### Pasos del Ejercicio

1. Creá un directorio de trabajo y definí una configuración de stack multi-contenedor llamada `docker-compose.yml`:

```bash
mkdir -p ~/lpi-701-lab/compose-stack && cd ~/lpi-701-lab/compose-stack
cat <<'EOF' > docker-compose.yml
name: enterprise-app

services:
  redis-db:
    image: redis:7.2-alpine
    container_name: production-redis
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "SecureVaultPass2026!"]
    user: "999:999"
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a SecureVaultPass2026! ping | grep PONG"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s
    volumes:
      - redis-data:/data
    networks:
      - backend-net
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 256M
        reservations:
          cpus: '0.10'
          memory: 64M
    restart: unless-stopped

  api-service:
    image: nginx:1.25-alpine
    container_name: production-api
    depends_on:
      redis-db:
        condition: service_healthy
    ports:
      - "8080:80"
    networks:
      - frontend-net
      - backend-net
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:80/"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M
    restart: always

networks:
  frontend-net:
    driver: bridge
    internal: false
  backend-net:
    driver: bridge
    internal: true

volumes:
  redis-data:
    driver: local
EOF
```

2. Validá la sintaxis e iniciá el stack multi-contenedor en modo desatendido (detached):

```bash
docker compose config
docker compose up -d
```

*Salida esperada:*
```text
[+] Running 3/3
 ✔ Network enterprise-app_frontend-net  Created                                                   0.1s
 ✔ Network enterprise-app_backend-net   Created                                                   0.1s
 ✔ Volume "enterprise-app_redis-data"   Created                                                   0.0s
 [+] Running 2/2
 ✔ Container production-redis           Healthy                                                   5.2s
 ✔ Container production-api             Started                                                   5.3s
```

3. Inspeccioná el estado de salud y el consumo de recursos de los contenedores en ejecución:

```bash
docker compose ps
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

*Salida esperada:*
```text
NAME               IMAGE              COMMAND                  SERVICE      CREATED          STATUS                    PORTS
production-api     nginx:1.25-alpine  "/docker-entrypoint.…"   api-service  15 seconds ago   Up 10 seconds (healthy)   0.0.0.0:8080->80/tcp
production-redis   redis:7.2-alpine   "docker-entrypoint.s…"   redis-db     15 seconds ago   Up 10 seconds (healthy)   6379/tcp

NAME               CPU %               MEM USAGE / LIMIT   MEM %
production-api     0.01%               3.12MiB / 128MiB    2.44%
production-redis   0.15%               8.45MiB / 256MiB    3.30%
```

4. Verificá el aislamiento de red intentando acceder a `production-redis` desde un contenedor efímero externo conectado únicamente a `frontend-net`:

```bash
docker run --rm --network enterprise-app_frontend-net alpine ping -c 2 production-redis
```

*Salida esperada:*
```text
ping: bad address 'production-redis'
```

---

### Preguntas de Verificación — Bloque 1

**Pregunta 1.1**: ¿Qué garantía arquitectónica específica proporciona `condition: service_healthy` bajo `depends_on` en comparación con el orden de inicio de contenedores estándar?

**Pregunta 1.2**: ¿Por qué está configurado `backend-net` con `internal: true`, y qué sucede a nivel de namespace de red de Linux/capa de iptables cuando este flag está habilitado?

---

## Bloque 2: Orquestación de Cargas de Trabajo en Producción con Manifiestos de Kubernetes

Este ejercicio cubre la orquestación de cargas de trabajo con y sin estado (stateful y stateless) de alta disponibilidad en Kubernetes. Crearás rolling updates sin tiempo de inactividad, políticas de aplicación de recursos, health probes personalizados, gestión dinámica de configuración y enrutamiento de servicios.

### Pasos del Ejercicio

1. Creá un directorio de trabajo para el desarrollo de manifiestos de Kubernetes:

```bash
mkdir -p ~/lpi-701-lab/k8s-manifests && cd ~/lpi-701-lab/k8s-manifests
```

2. Creá un `ConfigMap` y un `Secret` completamente especificados para los parámetros dinámicos de la aplicación:

```bash
cat <<'EOF' > 01-config-secret.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
    app.kubernetes.io/part-of: e-commerce
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  MAX_CONNECTIONS: "5000"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-db-credentials
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
type: Opaque
stringData:
  DB_USER: "pg_admin"
  DB_PASS: "SuperComplexP@ssw0rd2026!"
EOF
kubectl apply -f 01-config-secret.yaml
```

*Salida esperada:*
```text
configmap/app-config created
secret/app-db-credentials created
```

3. Desplegá un manifiesto de `Deployment` de nivel de producción que cuente con probes explícitos, límites de recursos, estrategia de rolling update y contextos de seguridad:

```bash
cat <<'EOF' > 02-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-deployment
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
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
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
      containers:
        - name: web-container
          image: nginxinc/nginx-unprivileged:1.25-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          envFrom:
            - configMapRef:
                name: app-config
          env:
            - name: DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-db-credentials
                  key: DB_PASS
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          startupProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            successThreshold: 1
            failureThreshold: 2
EOF
kubectl apply -f 02-deployment.yaml
```

*Salida esperada:*
```text
deployment.apps/web-app-deployment created
```

4. Exponé el deployment utilizando un Service de tipo `ClusterIP` con afinidad de sesión por endpoint:

```bash
cat <<'EOF' > 03-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app-service
  namespace: default
  labels:
    app.kubernetes.io/name: web-app
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: web-app
EOF
kubectl apply -f 03-service.yaml
```

*Salida esperada:*
```text
service/web-app-service created
```

5. Verificá el estado del despliegue (rollout status) e inspeccioná los Endpoints generados:

```bash
kubectl rollout status deployment/web-app-deployment
kubectl get endpoints web-app-service
```

*Salida esperada:*
```text
deployment "web-app-deployment" successfully rolled out
NAME              ENDPOINTS                                               AGE
web-app-service   10.244.0.15:8080,10.244.0.16:8080,10.244.1.12:8080       12s
```

6. Realizá un rolling update sin tiempo de inactividad actualizando la imagen del contenedor:

```bash
kubectl set image deployment/web-app-deployment web-container=nginxinc/nginx-unprivileged:1.26-alpine --record
kubectl rollout status deployment/web-app-deployment
```

*Salida esperada:*
```text
deployment.apps/web-app-deployment image updated
Waiting for deployment "web-app-deployment" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "web-app-deployment" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "web-app-deployment" rollout to finish: 2 of 3 updated replicas are available...
deployment "web-app-deployment" successfully rolled out
```

---

### Preguntas de Verificación — Bloque 2

**Pregunta 2.1**: Con `maxSurge: 1` y `maxUnavailable: 0` configurados para un Deployment de 3 réplicas, ¿cuántos Pods en total estarán ejecutándose durante un rolling update activo, y qué beneficio ofrece `maxUnavailable: 0` a los sistemas en producción?

**Pregunta 2.2**: Si un contenedor de un Pod excede su límite de CPU (`250m`), ¿qué acción toma el kernel de Linux? ¿Cómo se compara esto con cuando un contenedor de un Pod excede su límite de Memoria (`128Mi`)?

---

## Bloque 3: Técnicas de Diagnóstico Avanzadas y Flujos de Trabajo de Solución de Problemas (Troubleshooting)

Esta sección se centra en el diagnóstico de anomalías de contenedores en producción, incluyendo estados de CrashLoopBackOff, fallos de probes, problemas de red y errores de runtime de contenedores de bajo nivel.

### Pasos del Ejercicio

1. Simulá un deployment fallido debido a una ruta de liveness probe rota e inspeccioná el estado resultante:

```bash
kubectl patch deployment web-app-deployment --patch '
spec:
  template:
    spec:
      containers:
      - name: web-container
        livenessProbe:
          httpGet:
            path: /non-existent-health-check
            port: 8080
'
```

2. Monitoreá el estado del Pod y consultá los flujos de eventos para identificar la causa raíz:

```bash
kubectl get pods -l app=web-app
kubectl get events --field-selector reason=Unhealthy --sort-by='.metadata.creationTimestamp'
```

*Salida esperada:*
```text
NAME                                  READY   STATUS    RESTARTS      AGE
web-app-deployment-789456bc-x9z12     1/1     Running   2 (20s ago)   1m
web-app-deployment-789456bc-y8w34     1/1     Running   1 (35s ago)   1m
web-app-deployment-789456bc-z7v56     1/1     Running   1 (35s ago)   1m

LAST SEEN   TYPE      REASON      OBJECT                                  MESSAGE
12s         Warning   Unhealthy   pod/web-app-deployment-789456bc-x9z12   Liveness probe failed: HTTP probe failed with statuscode: 404
```

3. Revertí (rollback) la revisión del deployment para restaurar la salud operativa:

```bash
kubectl rollout history deployment/web-app-deployment
kubectl rollout undo deployment/web-app-deployment
kubectl rollout status deployment/web-app-deployment
```

*Salida esperada:*
```text
deployment.apps/web-app-deployment 
REVISION  CHANGE-CAUSE
1         <none>
2         kubectl set image deployment/web-app-deployment web-container=nginxinc/nginx-unprivileged:1.26-alpine --record
3         <none>

rollback revision 2 has been rolled back to revision 2
deployment "web-app-deployment" successfully rolled out
```

4. Realizá una depuración de bajo nivel del runtime del contenedor. Adjuntá un contenedor de depuración efímero para inspeccionar los namespaces de red y las listas de procesos dentro de un Pod endurecido (hardened)/distroless en ejecución:

```bash
TARGET_POD=$(kubectl get pods -l app=web-app -o jsonpath='{.items[0].metadata.name}')
kubectl debug -it ${TARGET_POD} --image=nicolaka/netshoot --target=web-container -- sh
```

Dentro de la shell de depuración, ejecutá:

```bash
netstat -tulpn
ps aux
exit
```

*Salida esperada:*
```text
Targeting container "web-container". If you don't see processes from this container it may be because the container runtime doesn't support sharesProcessNamespace.
/ # netstat -tulpn
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
tcp        0      0 0.0.0.0:8080            0.0.0.0:*               LISTEN      1/nginx: master proc
/ # ps aux
PID   USER     TIME  COMMAND
    1 101       0:00 nginx: master process nginx -g daemon off;
    7 101       0:00 nginx: worker process
   15 root      0:00 sh
/ # exit
```

5. Inspeccioná los procesos de contenedor de bajo nivel del nodo host utilizando `crictl` y `cgroups` (ejecutar en el nodo control plane/worker node):

```bash
# Obtain Container ID from crictl
crictl ps --name web-container --state Running -q | head -n 1

# Read cgroup v2 memory limits directly from the kernel filesystem
CONTAINER_PID=$(crictl inspect --output json $(crictl ps --name web-container -q | head -n 1) | jq '.info.pid')
cat /proc/${CONTAINER_PID}/root/etc/os-release
cat /sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope/memory.max 2>/dev/null || cat /proc/${CONTAINER_PID}/cgroup
```

---

### Preguntas de Verificación — Bloque 3

**Pregunta 3.1**: ¿Cuál es la diferencia de diagnóstico clave entre `kubectl logs <pod-name>` y `kubectl describe pod <pod-name>` al investigar un contenedor en estado `CrashLoopBackOff`?

**Pregunta 3.2**: ¿Cómo permite la conexión de un contenedor de depuración efímero mediante `kubectl debug --target=<container-name>` la inspección de red y procesos incluso si el contenedor de la aplicación de destino no incluye una shell o utilidades (por ejemplo, una imagen distroless)?

---

## Soluciones y Explicaciones de las Respuestas

<details>
<summary>Click here to expand solutions for all verification questions</summary>

### Respuestas del Bloque 1

* **Respuesta 1.1**:
  El `depends_on` estándar solo comprueba la creación del contenedor o el inicio de la ejecución (`service_started`). No garantiza que la aplicación dentro del contenedor esté lista para aceptar conexiones de sockets. 
  Al especificar `condition: service_healthy`, Docker Compose pospone el inicio de los contenedores dependientes (`api-service`) hasta que el comando de `healthcheck` designado del contenedor de destino (`redis-db`) se ejecute con éxito y finalice con el código `0`. Esto evita cascadas de bucles de arranque con conexiones rechazadas entre microservicios.

* **Respuesta 1.2**:
  Establecer `internal: true` crea una red bridge aislada sin una interfaz de gateway predeterminada hacia el host o el internet externo. 
  A nivel del kernel de Linux, Docker crea un dispositivo bridge personalizado (por ejemplo, `br-xxxxx`) y configura reglas de `iptables` / `nftables` en la cadena `FORWARD`. Específicamente, descarta los paquetes que se originan en contenedores de este bridge con destino a subredes externas o interfaces no conectadas, permitiendo la comunicación **únicamente** entre los contenedores conectados a esa red específica.

---

### Respuestas del Bloque 2

* **Respuesta 2.1**:
  Con `replicas: 3`, `maxSurge: 1` y `maxUnavailable: 0`:
  * Durante un rolling update, Kubernetes puede escalar hasta **4 Pods** (`replicas + maxSurge` = 3 + 1).
  * Configurar `maxUnavailable: 0` garantiza que Kubernetes **nunca** elimine un Pod existente hasta que un Pod recién creado supere su `readinessProbe` e ingrese al estado `Ready`.
  * Esto garantiza que el 100% de la capacidad de tráfico base (3 Pods saludables) esté continuamente disponible a lo largo del proceso de despliegue, eliminando caídas de capacidad durante las actualizaciones.

* **Respuesta 2.2**:
  * **Límite de CPU Excedido**: La CPU es un recurso compresible. Cuando un contenedor excede su cuota CFS (`cpu.max` en cgroups v2), el scheduler CFS del kernel de Linux **limita (throttles)** el uso de CPU del contenedor congelando sus hilos de ejecución durante el resto del intervalo de aplicación del periodo. El proceso no se finaliza.
  * **Límite de Memoria Excedido**: La memoria es un recurso incompresible. Cuando un contenedor intenta asignar memoria más allá de su límite configurado (`memory.max` en cgroups v2), el OOM Killer del kernel de Linux selecciona el proceso de mayor consumo dentro de ese cgroup y lo finaliza con la señal `SIGKILL` (código de salida `137`). Kubernetes detecta este evento de salida y marca el estado del Pod como `OOMKilled`.

---

### Respuestas del Bloque 3

* **Respuesta 3.1**:
  * `kubectl logs`: Lee los flujos de stdout y stderr emitidos por el proceso del contenedor. Es útil para diagnosticar trazas de pila (stack traces) de la aplicación, excepciones no controladas y errores de lógica. Añadir `-p` (`--previous`) recupera los logs de la instancia finalizada *anterior* de un contenedor que se está reiniciando.
  * `kubectl describe pod`: Consulta el servidor de la API de Kubernetes para obtener metadatos del Pod, flags de condición, historial de estado, conteos de reinicio de contenedores y **Eventos** del ciclo de vida. Revela fallos a nivel de infraestructura, tales como fallos de probes (por ejemplo, HTTP 404/500, timeouts), códigos de terminación OOMKill, fallos de extracción de imágenes (`ErrImagePull`) y restricciones de programación (scheduling).

* **Respuesta 3.2**:
  El comando `kubectl debug --target=<container-name>` crea un Contenedor Efímero dentro de los namespaces del kernel de Linux del Pod existente. 
  Al especificar `--target`, el servidor de la API configura el contenedor de depuración para unirse al **namespace de Process ID (PID)** del contenedor de destino y compartir su **namespace de Red**. Esto permite que las herramientas del contenedor de depuración (tales como `netstat`, `tcpdump` o `ps`) inspeccionen sockets abiertos, interfaces y procesos en ejecución del contenedor de destino sin modificar su sistema de archivos ni requerir binarios instalados en la imagen de destino.

</details>