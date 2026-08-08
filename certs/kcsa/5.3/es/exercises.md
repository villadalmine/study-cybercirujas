# Certificación CNCF KCSA: Tema 5.3 – Observabilidad (Peso en el examen: 2.29%)

## Análisis técnico profundo y visión general de la arquitectura

La observabilidad de seguridad en Kubernetes va más allá del monitoreo de rendimiento de aplicaciones (APM) estándar. Mientras que la telemetría se centra tradicionalmente en métricas, logs y trazas para confiabilidad y rendimiento, la **Observabilidad de Seguridad** se centra en identificar límites de seguridad, detectar violaciones de políticas, descubrir intentos de acceso no autorizados y auditar cambios de estado del sistema en tiempo real.

En un cluster de Kubernetes en producción, la observabilidad de seguridad opera a través de tres capas principales del stack:

```
+-------------------------------------------------------------------------+
|                         API Server & Control Plane                       |
|  - Audit Logging Engine (Stages: RequestReceived, ResponseComplete, etc.)|
|  - Audit Levels: None, Metadata, Request, RequestResponse               |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        Kernel & Runtime Layer                           |
|  - eBPF / Kernel Tracepoints / Syscall Hooking                          |
|  - Runtime Threat Detection Engines (e.g., Falco, Tetragon)            |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                      Network & Workload Layer                           |
|  - L4/L7 Flow Logs (Cilium/Hubble, Service Mesh / Envoy Access Logs)     |
|  - Security Telemetry Metrics (RBAC 401/403 rate, anomaly detection)    |
+-------------------------------------------------------------------------+
```

### 1. Arquitectura de Audit Logging del API Server de Kubernetes

El motor de Audit Logging del API Server registra cada solicitud procesada por `kube-apiserver`. Cada evento pasa por cuatro etapas de auditoría:

1. `RequestReceived`: Registrado inmediatamente cuando el manejador de solicitudes recibe la solicitud, antes de la delegación en la cadena de manejadores.
2. `ResponseStarted`: Registrado una vez que se envían los encabezados de respuesta, pero antes de que se transmita el cuerpo de la respuesta (utilizado para solicitudes de larga duración como `watch` o `exec`).
3. `ResponseComplete`: Registrado después de que el cuerpo de la respuesta se completa o se cierra.
4. `Panic`: Registrado cuando se genera un panic durante el procesamiento de la solicitud.

#### Niveles de auditoría y compromisos de rendimiento

| Nivel de auditoría | Datos registrados | Impacto en el rendimiento | Caso de uso principal de seguridad |
| :--- | :--- | :--- | :--- |
| `None` | Nada | Cero | Excluir ruido de alta frecuencia (ej. actualizaciones de estado de `kubelet`, barridos de endpoints). |
| `Metadata` | Marca de tiempo de la solicitud, URI, información del usuario, verbo, recurso, namespace, código de estado de respuesta. | Bajo | Cumplimiento general de auditoría, monitoreo de fallas de autorización (`401`/`403`). |
| `Request` | `Metadata` + Payload de la solicitud (spec de `Object`). | Medio | Auditoría de cambios de configuración (ej. modificación de `RoleBinding` o `PodDisruptionBudget`). |
| `RequestResponse` | `Metadata` + Payload de la solicitud + Cuerpo de la respuesta (status y payload de `Object`). | Alto (Intensivo en memoria/E-S) | Recursos de alta seguridad (ej. seguimiento de payloads de lectura de `Secret`, solicitudes de token de `ServiceAccount`). |

> [!WARNING]
> Configurar el nivel de auditoría en `RequestResponse` globalmente en recursos como `ConfigMap` o `Secret` puede provocar graves cuellos de botella de E/S de disco y saturación de memoria en los nodos del control plane, además de exponer datos sensibles en texto plano en los archivos de logs.

---

## Ejercicio 1: Configuración avanzada de Audit Policy y diagnósticos en Kubernetes

### Objetivos
1. Diseñar y desplegar un manifiesto `AuditPolicy` sintácticamente válido para grado de producción.
2. Configurar reglas para auditar operaciones sensibles (`exec`, `port-forward`, `secrets`, `rbac`) omitiendo el ruido del sistema de alto volumen.
3. Analizar logs de auditoría JSON generados utilizando diagnósticos CLI.

### Paso 1: Crear el manifiesto de Audit Policy de producción
Creá un archivo llamado `audit-policy.yaml` con la siguiente configuración:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Never log authentication/authorization checks from node lease or health endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/livez*"
      - "/readyz*"
    
  - level: None
    users:
      - "system:kube-proxy"
      - "system:nodes"
    verbs:
      - "get"
      - "list"
      - "watch"
    resources:
      - group: ""
        resources: ["endpoints", "services", "configmaps"]

  # 2. Audit Pod Exec, Attach, and Port-Forward at ResponseStatus / Metadata level
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Audit Secret and ConfigMap modifications at Request level; read actions at Metadata level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]
    verbs:
      - "get"
      - "list"
      - "watch"

  - level: Request
    resources:
      - group: ""
        resources: ["secrets"]
    verbs:
      - "create"
      - "update"
      - "patch"
      - "delete"

  # 4. Audit RBAC changes at RequestResponse level to capture exactly what privileges were granted
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 5. Default rule for all other namespace-scoped resources
  - level: Metadata
    resources:
      - group: ""
      - group: "apps"
      - group: "batch"
```

### Paso 2: Validar la integración del flag de auditoría del API Server
Verificá cómo está configurado `kube-apiserver` para ingerir esta política en los nodos del control plane. Inspeccioná el manifiesto del Pod estático `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```bash
sudo grep -E "audit-policy-file|audit-log-path|audit-log-maxbackup|audit-log-maxage|audit-log-maxsize" /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Salida esperada:**
```text
    - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxbackup=10
    - --audit-log-maxage=30
    - --audit-log-maxsize=100
```

### Paso 3: Disparar eventos de seguridad y analizar logs JSON
Simulá una acción sensible o no autorizada intentando ejecutar una shell dentro de un pod y leyendo un Secret.

```bash
# Generate a Pod exec audit event
kubectl run security-test-pod --image=nginx:alpine --restart=Never
kubectl exec -it security-test-pod -- id

# Query the audit log for exec operations
sudo jq -r 'select(.verb=="create" and .objectRef.subresource=="exec") | {timestamp: .stageTimestamp, user: .user.username, pod: .objectRef.name, namespace: .objectRef.namespace}' /var/log/kubernetes/audit/audit.log
```

**Salida esperada:**
```json
{
  "timestamp": "2026-08-07T20:25:12Z",
  "user": "kubernetes-admin",
  "pod": "security-test-pod",
  "namespace": "default"
}
```

### Paso 4: Auditar eventos de escalación de privilegios de RBAC
Creá un cluster role binding y auditá el evento resultante en tiempo real.

```bash
kubectl create clusterrolebinding suspicious-admin-binding --clusterrole=cluster-admin --user=dev-user

# Parse audit logs for RBAC clusterrolebinding creation
sudo jq -r 'select(.objectRef.resources=="clusterrolebindings" and .verb=="create") | {user: .user.username, binding: .objectRef.name, stage: .stage, level: .level}' /var/log/kubernetes/audit/audit.log
```

**Salida esperada:**
```json
{
  "user": "kubernetes-admin",
  "binding": "suspicious-admin-binding",
  "stage": "ResponseComplete",
  "level": "RequestResponse"
}
```

---

### Preguntas de verificación (Ejercicio 1)

1. **Pregunta 1.1**: Un ingeniero configura una `AuditPolicy` con una regla que coincide con `verbs: ["get"]`, `resources: ["secrets"]` en el nivel de auditoría `RequestResponse`. ¿Qué riesgo operativo crítico introduce esto en el rendimiento del control plane durante la operación de aplicaciones de alto rendimiento?
2. **Pregunta 1.2**: ¿Por qué la etapa `RequestReceived` se agrega con frecuencia a `omitStages` en las políticas de auditoría en producción?
3. **Pregunta 1.3**: En un entorno donde la alteración de logs por parte de un atacante con acceso al nodo es una amenaza, ¿qué modificación de arquitectura se debe realizar en el backend de audit logging del API server?

---

## Ejercicio 2: Observabilidad de seguridad en tiempo de ejecución con Falco y eBPF

### Objetivos
1. Configurar reglas personalizadas de Falco para observar anomalías de ejecución del sistema a nivel de host y de contenedor.
2. Sintetizar eventos de eBPF y syscalls del kernel en alertas de seguridad estructuradas.
3. Validar la detección de escapes de contenedores (container breakouts) y la ejecución de shells interactivas en cargas de trabajo de producción.

### Paso 1: Escribir reglas de seguridad personalizadas de Falco
Creá `/etc/falco/rules.d/custom-security-rules.yaml`:

```yaml
- rule: Unauthorized Shell Spawned in Container
  desc: Detects interactive shell execution inside a running container context
  condition: >
    spawned_process and 
    container and 
    proc.name in (bash, sh, zsh, ksh, ash) and 
    not user_known_shell_execution_activities
  output: >
    Security Alert: Shell spawned in container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container_id=%container.id image=%container.image.repository process=%proc.name cmdline=%proc.cmdline)
  priority: WARNING
  tags: [container, security, process, mitre_execution]

- rule: Sensitive File Access Below /etc in Container
  desc: Detects attempt to read or modify sensitive authentication files inside a container
  condition: >
    open_write or open_read and
    container and
    fd.name startswith /etc/shadow or fd.name startswith /etc/sudoers
  output: >
    Critical Violation: Sensitive file accessed in container
    (user=%user.name command=%proc.cmdline file=%fd.name pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: CRITICAL
  tags: [container, security, filesystem, mitre_credential_access]
```

### Paso 2: Validar el estado del DaemonSet / Servicio Systemd de Falco
Verificá que Falco esté operando con el motor de eBPF probe en lugar de hooks de módulos del kernel para un monitoreo no intrusivo de alto rendimiento.

```bash
# Verify falco engine status via falco-driver-loader or systemctl
systemctl status falco --no-pager
```

**Salida esperada:**
```text
● falco.service - Falco: Container Native Runtime Security
     Loaded: loaded (/lib/systemd/system/falco.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-08-07 19:00:00 UTC; 1h ago
       Docs: https://falco.org/docs/
   Main PID: 41200 (falco)
      Tasks: 11 (limit: 4915)
     Memory: 84.2M
        CPU: 1.254s
     CGroup: /system.slice/falco.service
             └─41200 /usr/bin/falco -U -o json_output=true
```

### Paso 3: Disparar señales de amenaza y capturar la salida de observabilidad
Simulá un actor malicioso ejecutando una shell no autorizada e intentando leer `/etc/shadow` dentro de un pod de aplicación objetivo.

```bash
# Run test pod
kubectl run web-app --image=nginx --restart=Never

# Trigger violation 1: Spawn shell
kubectl exec -it web-app -- /bin/sh -c "cat /etc/shadow"

# Inspect Falco JSON alerts from system log or stdout
journalctl -u falco -n 20 --no-pager | grep "Unauthorized Shell Spawned in Container"
```

**Salida esperada:**
```json
{"severity":"Warning","time":"2026-08-07T20:28:44.102938472Z","rule":"Unauthorized Shell Spawned in Container","output":"Security Alert: Shell spawned in container (user=root user_loginuid=-1 pod=web-app ns=default container_id=a8f9c1e2b3d4 image=nginx process=sh cmdline=/bin/sh -c cat /etc/shadow)","output_fields":{"container.id":"a8f9c1e2b3d4","container.image.repository":"nginx","fd.name":null,"k8s.ns.name":"default","k8s.pod.name":"web-app","proc.cmdline":"/bin/sh -c cat /etc/shadow","proc.name":"sh","user.loginuid":-1,"user.name":"root"}}
```

---

### Preguntas de verificación (Ejercicio 2)

1. **Pregunta 2.1**: ¿En qué se diferencia el uso de un driver eBPF en Falco del enfoque heredado basado en módulos del kernel en términos de seguridad del kernel, sobrecarga de rendimiento y operaciones de actualización de nodos del cluster?
2. **Pregunta 2.2**: Si un atacante ejecuta un binario compilado estáticamente inyectado a través de `kubectl cp` que se llama `/usr/bin/custom-tool` (el cual invoca internamente `execve` sobre `/bin/sh`), ¿la regla `Unauthorized Shell Spawned in Container` anterior capturará el evento? Explicá el mecanismo de syscall (`proc.name` vs `proc.cmdline`).

---

## Ejercicio 3: Observabilidad del flujo de red y auditoría de microsegmentación

### Objetivos
1. Utilizar registro de flujo basado en eBPF (ej. Cilium/Hubble) o logs de acceso proxy de Service Mesh para auditar flujos de red de salida (egress) y entrada (ingress).
2. Detectar comunicaciones no autorizadas entre namespaces e intentos de conexión descartados.
3. Construir filtros de observabilidad de red para verificar el cumplimiento de NetworkPolicy.

### Paso 1: Desplegar una NetworkPolicy Deny-All con Logging/Auditoría
Desplegar un manifiesto de `NetworkPolicy` base restrictivo:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: secure-space
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

Creá el namespace objetivo y desplegá una carga de trabajo de prueba:

```bash
kubectl create namespace secure-space
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: isolated-workload
  namespace: secure-space
  labels:
    app: secure-api
spec:
  containers:
  - name: alpine
    image: alpine
    command: ["sleep", "3600"]
EOF
```

### Paso 2: Observar flujos de tráfico de red a través de la CLI eBPF de Hubble
Utilizá la herramienta CLI de Hubble para inspeccionar eventos de traza de red eBPF a nivel de kernel en tiempo real.

```bash
# Query network flows for dropped packets due to NetworkPolicy enforcement
hubble observe --namespace secure-space --verdict DROP --output json
```

Ahora dispará una violación desde el interior del contenedor aislado:

```bash
# Attempt unauthorized external egress connection
kubectl exec -n secure-space isolated-workload -- nc -zw2 8.8.8.8 53
```

**Salida esperada de la CLI de Hubble:**
```json
{
  "flow": {
    "time": "2026-08-07T20:31:05.819231920Z",
    "verdict": "DROP",
    "drop_reason": 133,
    "auth_type": "DISABLED",
    "ethernet": {
      "source": "aa:bb:cc:dd:ee:ff",
      "destination": "00:11:22:33:44:55"
    },
    "IP": {
      "source": "10.244.1.45",
      "destination": "8.8.8.8",
      "ipVersion": "IPv4"
    },
    "l4": {
      "TCP": {
        "source_port": 49202,
        "destination_port": 53
      }
    },
    "source": {
      "id": 1204,
      "namespace": "secure-space",
      "labels": ["k8s:app=secure-api", "k8s:io.kubernetes.pod.namespace=secure-space"],
      "pod_name": "isolated-workload"
    },
    "destination": {
      "id": 2,
      "identity": 2,
      "labels": ["reserved:world"]
    },
    "Type": "TO_STACK",
    "node_name": "worker-node-1",
    "summary": "TCP Flags: SYN"
  }
}
```

### Paso 3: Analizar los logs de acceso L7 del proxy Envoy para auditoría de mTLS y políticas HTTP
En una arquitectura Service Mesh (ej. Istio/Envoy), verificá el estado de mTLS y las fallas de autorización (`403 RBAC access denied`) a través de los logs del sidecar del proxy:

```bash
kubectl logs -n secure-space isolated-workload -c istio-proxy --tail=100 | grep "rbac_access_denied"
```

**Salida esperada:**
```text
[2026-08-07T20:33:12.112Z] "GET /api/v1/admin HTTP/1.1" 403 rbac_access_denied - "-" 0 19 1 - "-" "curl/7.88.1" "a1b2c3d4-e5f6-7890" "api.secure-space.svc.cluster.local" "10.244.1.50:8080" inbound|8080|| 10.244.1.45:51234 10.244.1.50:8080 10.244.1.45:49812 outbound_.8080_._.api.secure-space.svc.cluster.local TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
```

---

### Preguntas de verificación (Ejercicio 3)

1. **Pregunta 3.1**: ¿Qué limitación clave de observabilidad de seguridad existe al inspeccionar descartes estándar de `NetworkPolicy` en Kubernetes en comparación con el uso de recolectores de flujo eBPF como Cilium/Hubble?
2. **Pregunta 3.2**: En la línea de log del proxy Envoy del Paso 3, ¿qué campo exacto confirma que la sesión entre pods fue cifrada mediante mutual TLS (mTLS), y por qué es esto crítico para la validación de la postura de zero-trust?

---

## Ejercicio 4: Métricas de telemetría de seguridad y alertas de Prometheus

### Objetivos
1. Extraer métricas de seguridad directamente del API server de Kubernetes y de los controladores en tiempo de ejecución.
2. Construir consultas PromQL para detectar fallas anómalas de autenticación/autorización.
3. Configurar manifiestos de `AlertingRule` de Prometheus para la escalación automatizada de eventos de seguridad.

### Paso 1: Consultar métricas de seguridad del API Server directamente a través del endpoint raw de la API
Ejecutá una consulta raw contra el endpoint de métricas del control plane para inspeccionar los conteos de denegaciones de autorización.

```bash
kubectl get --raw /metrics | grep "apiserver_audit_requests_total" | head -n 10
```

**Salida esperada:**
```text
# HELP apiserver_audit_requests_total [ALPHA] Counter of apiserver requests audited.
# TYPE apiserver_audit_requests_total counter
apiserver_audit_requests_total{level="Metadata"} 481023
apiserver_audit_requests_total{level="Request"} 12044
apiserver_audit_requests_total{level="RequestResponse"} 3102
```

Consultá las métricas de respuesta HTTP del API Server para tasas de error 401 (Unauthorized) y 403 (Forbidden):

```bash
kubectl get --raw /metrics | grep -E 'apiserver_request_total\{.*code="(401|403)"'
```

**Salida esperada:**
```text
apiserver_request_total{code="401",component="apiserver",contentType="application/json",dry_run="",group="",resource="pods",subresource="",verb="list",version="v1"} 14
apiserver_request_total{code="403",component="apiserver",contentType="application/json",dry_run="",group="rbac.authorization.k8s.io",resource="clusterrolebindings",subresource="",verb="create",version="v1"} 3
```

### Paso 2: Desplegar reglas de alerta de seguridad en producción
Creá un manifiesto llamado `security-prometheus-rules.yaml` definiendo alertas PromQL para la detección de amenazas:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: security-observability-alerts
  namespace: monitoring
  labels:
    role: alert-rules
spec:
  groups:
    - name: KubernetesSecurityOperations
      rules:
        # Alert 1: Spike in Unauthorized (401/403) API Server Requests (Potential Brute-force / Probe)
        - alert: HighAPIServerAuthorizationFailures
          expr: >
            sum(rate(apiserver_request_total{code=~"401|403"}[5m])) 
            / 
            sum(rate(apiserver_request_total[5m])) * 100 > 5
          for: 2m
          labels:
            severity: critical
            category: security
          annotations:
            summary: "High rate of API server authorization denials detected"
            description: "API server requests resulting in 401 or 403 status code exceeded 5% of overall traffic over the last 5 minutes. Current value: {{ $value }}%"

        # Alert 2: Container Exec Activity Spike
        - alert: ExcessivePodExecOperations
          expr: >
            sum(rate(apiserver_audit_requests_total{level=~"Request|RequestResponse"}[5m])) > 10
          for: 1m
          labels:
            severity: warning
            category: security-audit
          annotations:
            summary: "Abnormal volume of kubectl exec operations"
            description: "More than 10 pod exec requests per second recorded over 5 minutes."
```

### Paso 3: Verificar el despliegue y evaluación de las reglas de Prometheus
Aplicá el manifiesto de reglas y verificá su estado:

```bash
kubectl apply -f security-prometheus-rules.yaml
kubectl get prometheusrule -n monitoring security-observability-alerts -o jsonpath='{.status}'
```

---

### Preguntas de verificación (Ejercicio 4)

1. **Pregunta 4.1**: ¿Por qué medir recuentos brutos de `apiserver_request_total{code="403"}` es menos confiable para alertas de seguridad que calcular la proporción de 403 en comparación con la tasa total de solicitudes (`rate(apiserver_request_total{code="403"}[5m]) / rate(apiserver_request_total[5m])`)?
2. **Pregunta 4.2**: Nombrá dos vectores métricos específicos que puedan indicar un posible escape de contenedor (container breakout) o intento de escalación de privilegios a nivel de host cuando se analizan junto con los logs de Falco.

---

## Referencias y fuentes oficiales

- **CNCF KCSA Curriculum Blueprint**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Documentación de Audit Logging de Kubernetes**: [https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- **Referencia de la arquitectura de reglas de seguridad de Falco**: [https://falco.org/docs/rules/](https://falco.org/docs/rules/)
- **Documentación de observabilidad de red con eBPF de Cilium & Hubble**: [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/)
- **Buenas prácticas de seguridad para monitoreo en Prometheus**: [https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

---

<details>
<summary><strong>Soluciones y explicaciones técnicas exhaustivas</strong></summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1**:
  Configurar `RequestResponse` para operaciones `get` en `secrets` fuerza al motor de auditoría del API server a capturar, serializar y escribir el payload completo (campos spec y data) de cada Secret recuperado. 
  
  **Mecánica y riesgos**:
  1. **Saturación de memoria y E/S**: Cada bucle de controlador, ciclo de inicio de pod (montando secrets) o búsqueda de aplicaciones hace que grandes payloads JSON se serialicen en memoria y se envíen a disco o backends de webhook. Esto conduce a una alta latencia del API server, estrangulamiento de disco (disk throttling) y posibles caídas por OOM (Out-Of-Memory) en el control plane.
  2. **Exposición de credenciales**: Los valores de los secrets en texto plano (codificados en base64 dentro del payload del Secret) se escriben directamente en archivos de logs de auditoría sin cifrar o agregadores de logs, violando el principio de menor privilegio y creando un riesgo masivo de filtración de credenciales.

* **Respuesta 1.2**:
  La etapa `RequestReceived` ocurre antes de que el API Server autentique, autorice o procese la solicitud. Si se registra junto con `ResponseComplete`, cada solicitud individual genera al menos dos entradas distintas de log de auditoría. Omitir `RequestReceived` reduce el volumen de logs de auditoría aproximadamente a la mitad sin sacrificar el cumplimiento de seguridad, ya que `ResponseComplete` registra el estado final, la identidad del usuario, el recurso objetivo y el código de respuesta.

* **Respuesta 1.3**:
  La configuración de auditoría debe cambiar de (o complementar) el backend de `log` al **Webhook Audit Backend** (`--audit-webhook-config-file`). El backend de webhook transmite eventos de auditoría fuera de banda sobre mTLS a un SIEM remoto o recolector de logs externo configurado de forma inmutable (ej. Elasticsearch, AWS CloudWatch, Splunk). Esto evita que un atacante que obtenga acceso root en un nodo del control plane modifique o elimine archivos locales `/var/log/kubernetes/audit/audit.log` para cubrir sus huellas.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1**:
  - **Seguridad del kernel**: Los módulos del kernel heredados se ejecutan directamente en el espacio del kernel; un error o una desreferencia de puntero nulo en el driver puede colapsar el kernel del host (Kernel Panic). El bytecode de eBPF se valida antes de cargarse mediante el verificador integrado del kernel, garantizando que no pueda colapsar el sistema host, acceder a memoria no autorizada o entrar en bucles infinitos.
  - **Sobrecarga de rendimiento**: eBPF ejecuta programas altamente optimizados directamente dentro de los tracepoints del kernel utilizando ring buffers eficientes, evitando costosos cambios de contexto entre el espacio del kernel y el espacio de usuario.
  - **Actualizaciones de nodos y portabilidad**: Los módulos del kernel deben recompilarse para cada actualización específica de la versión del kernel del host (`dkms`). eBPF utiliza CO-RE (Compile Once – Run Everywhere) a través de BTF (BPF Type Format), lo que permite actualizaciones fluidas del kernel del host sin romper la instrumentación de seguridad en tiempo de ejecución.

* **Respuesta 2.2**:
  Sí, la regla capturará el evento. 
  - `proc.name` evalúa el basename del binario ejecutado (`sh`). 
  - `proc.cmdline` registra la invocación completa de la línea de comandos, incluidos los argumentos. 
  Cuando `/usr/bin/custom-tool` ejecuta `execve("/bin/sh", ...)`, el kernel emite un evento de tracepoint de la llamada al sistema `sys_enter_execve`. Falco intercepta esta llamada al sistema a través de eBPF. Dado que `execve` actualiza la imagen ejecutable del proceso a `/bin/sh`, `proc.name` se convierte en `sh`, cumpliendo la condición `proc.name in (bash, sh, zsh, ksh, ash)` independientemente de qué proceso padre haya iniciado el binario.

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1**:
  Las implementaciones estándar de `NetworkPolicy` en Kubernetes aplican el descarte de paquetes silenciosamente en la interfaz del kernel (a través de iptables, IPVS o eBPF básico) sin escribir de forma nativa eventos de descarte estructurados en los logs estándar del contenedor o archivos del sistema. Sin una capa de observabilidad de red eBPF como Cilium/Hubble o plugins de logging de CNI especializados, los descartes de red se presentan a los operadores de aplicaciones simplemente como errores genéricos de "Connection Timed Out". Hubble se conecta a los tracepoints de descarte de eBPF (`kfree_skb`, `cilium_drop_tp`) para extraer encabezados de paquetes, metadatos e IDs de NetworkPolicy coincidentes en tiempo real.

* **Respuesta 3.2**:
  El campo `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` (o la cadena moderna de cipher suite `TLS_AES_128_GCM_SHA256`) presente al final de la línea de log verifica explícitamente que el sidecar de Envoy negoció con éxito mTLS para la sesión HTTP entrante. En una arquitectura Zero-Trust, validar este campo de métrica/log confirma que el tráfico en tránsito no se puede interceptar mediante inspección de paquetes (man-in-the-middle) y que la identidad criptográfica de la carga de trabajo (SPIFFE/SPIRE ID o SAN URI) se aplicó antes de la evaluación de las reglas de autorización RBAC L7.

---

### Soluciones del Ejercicio 4

* **Respuesta 4.1**:
  Las métricas de recuento bruto (ej. `apiserver_request_total{code="403"} = 500`) son engañosas porque un aumento en los 403 podría ser simplemente un subproducto de la expansión del cluster o un alto volumen general de tráfico (ej. 500 solicitudes fallidas de un total de 10.000.000 de solicitudes es el 0,005%, lo cual es ruido de fondo operativo normal). Calcular la **proporción** (`rate(403) / rate(total)`) proporciona una métrica de porcentaje normalizada. Un aumento abrupto en la proporción de denegaciones (ej. superando el 5% del total de solicitudes del cluster) aísla con precisión las anomalías de seguridad (como un token comprometido que intenta una escalación de privilegios o un escáner automatizado sondeando endpoints) mientras minimiza las alertas de falsos positivos.

* **Respuesta 4.2**:
  1. `container_cpu_usage_seconds_total` (o métricas de cambios de contexto del kernel): Picos anómalos en la utilización de CPU o la creación de hilos (threads) sin los correspondientes picos de tráfico en la aplicación pueden indicar minería de criptomonedas no autorizada o la ejecución de herramientas de fuerza bruta dentro de un contenedor.
  2. `node_namespace_processes` / `container_processes` (Métricas de recuento de procesos): Un pico repentino en el recuento de procesos dentro de un contenedor cuyo número base de procesos es fijo (ej. un solo proceso worker de Nginx saltando a 50 procesos activos) indica la ejecución de una shell, escalación de privilegios o actividad de fork-bomb.

</details>