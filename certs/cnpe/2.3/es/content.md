# Tema 2.3 — Diagnosing and Remediating Platform Issues and Incident Scenarios

> **Certificación:** CNPE (Cloud Native Platform Engineer) · **Dominio 2:** Platform Operations & Observability · **Peso:** 6.67 %
> **Perfil:** SRE Senior / Platform Architect · **Nivel:** producción

---

## 1. Motivación y problema arquitectónico de producción

Un *platform engineer* no opera una aplicación: opera el **sustrato compartido** sobre el que corren decenas o cientos de equipos tenant. Esto cambia radicalmente la naturaleza de un incidente. Cuando falla el CNI, el CoreDNS, el ingress controller, el CSI driver o el control plane, **no cae un servicio — cae la capacidad de todos los tenants de operar sus servicios**. El *blast radius* es la plataforma entera, y el equipo de plataforma es el responsable último aunque el síntoma se manifieste como "mi Pod no arranca" reportado por un tenant que no tiene visibilidad de las capas inferiores.

### 1.1 El modelo de capas y la propagación de fallas

Un incidente en una plataforma cloud native casi nunca se diagnostica en la capa donde se **observa**. El síntoma sube; la causa raíz baja.

```
┌─────────────────────────────────────────────────────────────┐
│ Capa 5 · Tenant workloads (Deployments, StatefulSets, Jobs)  │  ← donde se OBSERVA el síntoma
├─────────────────────────────────────────────────────────────┤
│ Capa 4 · Platform services (ingress, cert-manager, mesh,     │
│          external-dns, GitOps controllers, secrets operator) │
├─────────────────────────────────────────────────────────────┤
│ Capa 3 · Cluster add-ons (CNI, CoreDNS, CSI, kube-proxy,     │
│          metrics-server, autoscaler)                         │
├─────────────────────────────────────────────────────────────┤
│ Capa 2 · Control plane (kube-apiserver, etcd, scheduler,     │
│          controller-manager)                                 │
├─────────────────────────────────────────────────────────────┤
│ Capa 1 · Infraestructura (nodes, kernel, kubelet, container  │  ← donde suele estar la CAUSA RAÍZ
│          runtime, red física, storage backend)               │
└─────────────────────────────────────────────────────────────┘
```

Ejemplo canónico de *propagación ascendente*: un disco de etcd con latencia de fsync elevada (Capa 1/2) → el apiserver responde lento y aparecen timeouts en watches (Capa 2) → los controllers dejan de reconciliar (Capa 3/4) → los HPA no escalan y los Pods nuevos quedan `Pending` (Capa 5). El tenant abre un ticket "no escala mi app"; la causa está cuatro capas abajo. **Diagnosticar es el arte de bajar por esta pila sin saltarse escalones.**

### 1.2 Las métricas que gobiernan la respuesta

La disciplina SRE define el incidente en términos medibles, no anecdóticos:

- **MTTD** (Mean Time To Detect): tiempo desde que la falla ocurre hasta que la alerta dispara. Lo optimiza la observabilidad (Tema 2.1/2.2).
- **MTTA** (Mean Time To Acknowledge): detección → toma de la guardia.
- **MTTR** (Mean Time To Remediate/Restore): reconocimiento → servicio restaurado. Lo optimiza **este tema** — diagnóstico y remediación.
- **MTBF** (Mean Time Between Failures): mide resiliencia arquitectónica.

El objetivo de una plataforma madura **no es MTBF infinito** (imposible en sistemas distribuidos) sino **MTTR bajo y predecible**. Se asume que las cosas fallan; se diseña para restaurar rápido.

### 1.3 El error budget como gatillo de decisión

El **SLO** (Service Level Objective) sobre los SLIs de la plataforma (p. ej. "el 99.9 % de los `PodScheduled` ocurren en < 10 s") define un **error budget** — el margen tolerable de fallo. Durante un incidente, el error budget responde una pregunta operativa concreta: *¿esto justifica despertar a la guardia y frenar todos los deploys?* Un incidente que consume budget rápido escala; uno que roza el margen se maneja en horario. El error budget convierte una decisión emocional ("¿es grave?") en una **decisión aritmética**.

| Concepto | Fórmula / definición | Uso en el incidente |
|---|---|---|
| SLI | Métrica de calidad observada (p. ej. success rate del apiserver) | Detecta la degradación |
| SLO | Objetivo sobre el SLI (99.9 %) | Define "sano" vs "degradado" |
| Error budget | `1 − SLO` sobre la ventana (0.1 % → 43.2 min/mes) | Gatillo de severidad y de freeze |
| Burn rate | Velocidad de consumo del budget (× tasa nominal) | Prioriza y clasifica la alerta |

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Señales de observabilidad para diagnóstico

No existe una señal "mejor": cada una responde una pregunta distinta durante el diagnóstico, y el error clásico es intentar diagnosticar un problema de una capa con la señal de otra.

| Señal | Pregunta que responde | Cardinalidad | Costo de retención | Cuándo es la herramienta correcta | Punto ciego |
|---|---|---|---|---|---|
| **Metrics** (Prometheus) | *¿Cuánto? ¿Está degradado ahora?* | Baja (agregada) | Bajo | Detección, alerting, tendencias, saturación | No dice *por qué* una request concreta falló |
| **Logs** (Loki/EFK) | *¿Qué pasó exactamente en este evento?* | Alta | Alto | Causa raíz puntual, stack traces, errores de app | Difícil correlacionar entre servicios sin trace_id |
| **Traces** (OTel/Jaeger/Tempo) | *¿Dónde, en la cadena de servicios, está la latencia/error?* | Muy alta | Muy alto (muestreado) | Fallas distribuidas, latencia entre hops | Requiere instrumentación; sampling pierde el caso raro |
| **Events** (`kube-events`) | *¿Qué decidió el control plane sobre este objeto?* | Media | Bajo (TTL 1 h por defecto) | Scheduling, probes, evictions, image pull | Efímeros; se pierden si no se exportan |
| **Profiles** (Pyroscope/Parca) | *¿Qué función/línea consume CPU/heap?* | Muy alta | Alto | Regresiones de performance, memory leaks | Overhead; no apto para todo el fleet continuamente |

**Regla de oro del diagnóstico**: se navega de baja a alta cardinalidad. Métrica dispara la alerta → trace localiza el hop culpable → log del span concreto da la línea exacta. Saltar directo a `grep` en logs de un cluster de 500 nodos es el antipatrón más común y caro.

### 2.2 Herramientas de diagnóstico en Kubernetes

| Herramienta | Capa que inspecciona | Requiere privilegios | Impacto en producción | Caso de uso primario |
|---|---|---|---|---|
| `kubectl describe` / `get events` | Control plane ↔ objeto | Solo RBAC lectura | Nulo | Primer vistazo: scheduling, probes, condiciones |
| `kubectl logs [--previous]` | App / container | RBAC lectura | Nulo | Errores de aplicación, crash del proceso |
| `kubectl debug` (ephemeral container) | Pod en ejecución | RBAC `pods/ephemeralcontainers` | Bajo (no reinicia el Pod) | Debug de Pod sin shell / `distroless` |
| `kubectl debug node/<n>` | Nodo (host namespace) | Privilegiado | Medio (Pod en el host) | Kubelet, runtime, filesystem, red del host |
| `crictl` | Container runtime (CRI) | Acceso al nodo | Medio | Runtime no responde al apiserver; containers zombie |
| `nsenter` / `ip netns` | Kernel / network namespace | root en nodo | Alto | Debug de CNI, iptables/eBPF, rutas |
| `etcdctl` | etcd | Certs de etcd | **Alto** | Salud del quorum, tamaño de DB, defrag |
| Node Problem Detector | Kernel/hardware → condiciones de nodo | DaemonSet privilegiado | Bajo (pasivo) | Detección proactiva de fallas de nodo |

### 2.3 Estrategias de remediación

| Estrategia | MTTR típico | Reversibilidad | Riesgo | Cuándo aplicarla |
|---|---|---|---|---|
| **Rollback** (`kubectl rollout undo` / revert GitOps) | Minutos | Alta | Bajo | Regresión introducida por un deploy reciente |
| **Restart / delete Pod** | Segundos | N/A | Bajo | Estado corrupto en memoria, deadlock, leak |
| **Cordon + drain** de nodo | Minutos | Alta | Medio (presión de scheduling) | Nodo insano; mantenimiento de infra |
| **Scale up manual / HPA** | Segundos–minutos | Alta | Bajo | Saturación por demanda legítima |
| **Circuit breaking / rate limit** (mesh) | Segundos | Alta | Medio | Falla en cascada, thundering herd |
| **Feature flag / kill switch** | Segundos | Alta | Bajo | Aislar código sin redeploy |
| **Failover** (multi-AZ/región) | Minutos | Media | Alto | Falla de zona/región completa |
| **Hotfix + redeploy** | Horas | Media | Alto | Bug sin rollback posible (migración de datos) |

**Principio de remediación**: durante el incidente se **mitiga**, no se arregla. Restaurar servicio (rollback, failover, restart) tiene prioridad absoluta sobre entender la causa raíz. El *root cause analysis* va al postmortem; el error budget que se quema no espera al diagnóstico perfecto.

### 2.4 Filosofías de alerting

| Enfoque | Base | Ventaja | Desventaja |
|---|---|---|---|
| **Threshold estático** (`cpu > 80%`) | Valor fijo | Simple | Ruido; no distingue síntoma de causa |
| **Symptom-based (SLO burn rate)** | Consumo de error budget | Alerta solo lo que afecta al usuario | Requiere SLOs definidos |
| **Multi-window multi-burn-rate** | 2 ventanas (rápida+lenta) | Baja falsos positivos y detecta rápido | Más complejo de configurar |
| **Predictivo / anomaly detection** | ML sobre baseline | Detecta lo desconocido | Caja negra; difícil de accionar |

El estándar de la industria (Google SRE Workbook) es **multi-window multi-burn-rate sobre SLOs**: la alerta se dispara solo cuando el consumo de error budget es tal que, de continuar, se agotaría el SLO — es decir, cuando **duele al usuario**, no cuando un número técnico cruza un umbral.

---

## 3. Manifiestos YAML e infraestructura completos

### 3.1 Alertas de burn-rate multi-ventana (`PrometheusRule`)

Esta es la pieza que convierte observabilidad en detección accionable. Implementa el patrón de dos ventanas: una rápida (para detectar quemados agudos) y una lenta (para confirmar y evitar falsos positivos).

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-apiserver-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
    role: alert-rules
spec:
  groups:
    - name: apiserver-availability-slo
      rules:
        # SLI de disponibilidad del apiserver: ratio de requests NO-5xx
        - record: apiserver:request_error_ratio:rate5m
          expr: |
            sum(rate(apiserver_request_total{code=~"5.."}[5m]))
              /
            sum(rate(apiserver_request_total[5m]))
        - record: apiserver:request_error_ratio:rate1h
          expr: |
            sum(rate(apiserver_request_total{code=~"5.."}[1h]))
              /
            sum(rate(apiserver_request_total[1h]))
        # Página (fast burn): quema 2% del budget mensual en 1h.
        # Con SLO 99.9% (budget 0.1%), un burn rate de 14.4x agota el mes en ~2 días.
        - alert: APIServerErrorBudgetBurnFast
          expr: |
            apiserver:request_error_ratio:rate5m > (14.4 * 0.001)
              and
            apiserver:request_error_ratio:rate1h > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            page: "true"
          annotations:
            summary: "apiserver quema error budget a 14.4x (fast burn)"
            runbook_url: "https://runbooks.internal/platform/apiserver-error-budget"
            description: "El error ratio del apiserver ({{ $value | humanizePercentage }}) agota el SLO de disponibilidad a ritmo crítico."
        # Ticket (slow burn): 6h/3d de ventana, burn rate 6x.
        - alert: APIServerErrorBudgetBurnSlow
          expr: |
            (sum(rate(apiserver_request_total{code=~"5.."}[6h])) / sum(rate(apiserver_request_total[6h]))) > (6 * 0.001)
              and
            (sum(rate(apiserver_request_total{code=~"5.."}[3d])) / sum(rate(apiserver_request_total[3d]))) > (6 * 0.001)
          for: 15m
          labels:
            severity: warning
            page: "false"
          annotations:
            summary: "apiserver quema error budget a 6x (slow burn)"
            runbook_url: "https://runbooks.internal/platform/apiserver-error-budget"
```

### 3.2 Ruteo de alertas por severidad (`Alertmanager`)

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: platform-routing
  namespace: monitoring
spec:
  route:
    receiver: default-slack
    groupBy: ["alertname", "cluster", "namespace"]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    routes:
      # Todo lo que paginA va a PagerDuty y silencia lo demás durante el incidente
      - receiver: pagerduty-critical
        matchers:
          - name: page
            value: "true"
        groupWait: 10s
        repeatInterval: 1h
        continue: false
      - receiver: default-slack
        matchers:
          - name: severity
            value: warning
  inhibitRules:
    # Si el cluster entero está caído (critical), no spamees con warnings derivados
    - sourceMatch:
        - name: alertname
          value: KubeAPIDown
      targetMatch:
        - name: severity
          value: warning
      equal: ["cluster"]
  receivers:
    - name: pagerduty-critical
      pagerdutyConfigs:
        - routingKey:
            name: pagerduty-secret
            key: routingKey
          severity: critical
    - name: default-slack
      slackConfigs:
        - apiURL:
            name: slack-secret
            key: url
          channel: "#platform-alerts"
          sendResolved: true
```

Nota sobre **inhibition**: es la defensa contra la "tormenta de alertas". Cuando el apiserver cae, cien alertas derivadas dispararían a la vez y ahogarían la señal real. La regla `inhibitRules` suprime los warnings mientras el critical padre esté activo — el operador ve *la causa*, no *cien síntomas*.

### 3.3 Deployment con self-healing correcto (probes + resources)

La primera línea de remediación es **automática**. Un Deployment bien configurado se auto-repara sin intervención humana. Los tres probes tienen roles distintos que suelen confundirse:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0      # nunca reduce capacidad durante el rollout
      maxSurge: 1
  selector:
    matchLabels: { app: payments-api }
  template:
    metadata:
      labels: { app: payments-api }
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: api
          image: registry.internal/payments-api:v2.14.1
          ports:
            - containerPort: 8080
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }   # memory limit == request evita OOM sorpresa por overcommit
          # startupProbe: protege el arranque lento; deshabilita liveness/readiness hasta que pasa
          startupProbe:
            httpGet: { path: /healthz, port: 8080 }
            failureThreshold: 30
            periodSeconds: 5        # tolera hasta 150s de arranque
          # livenessProbe: ¿el proceso está vivo o en deadlock? Fallo => RESTART
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          # readinessProbe: ¿puede recibir tráfico? Fallo => sale del Service, NO reinicia
          readinessProbe:
            httpGet: { path: /readyz, port: 8080 }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]  # drena conexiones antes de SIGTERM
```

> **Antipatrón crítico**: usar el mismo endpoint para liveness y readiness. Si `/healthz` verifica la DB y la DB cae, la liveness falla → Kubernetes reinicia el Pod en loop (`CrashLoopBackOff`) por un problema *externo*, empeorando la cascada. Liveness debe verificar **solo el proceso**; readiness verifica **las dependencias**.

### 3.4 `PodDisruptionBudget` — proteger disponibilidad durante remediaciones

Cuando drenás un nodo o el cluster-autoscaler compacta, el PDB garantiza que la remediación no cause *ella misma* un outage.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api-pdb
  namespace: payments
spec:
  minAvailable: 3          # de 4 réplicas, siempre 3 disponibles durante drain/eviction
  selector:
    matchLabels: { app: payments-api }
```

### 3.5 Node Problem Detector — detección proactiva de fallas de nodo (Capa 1)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-problem-detector
  namespace: kube-system
spec:
  selector:
    matchLabels: { app: node-problem-detector }
  template:
    metadata:
      labels: { app: node-problem-detector }
    spec:
      serviceAccountName: node-problem-detector
      hostNetwork: true
      tolerations:
        - operator: Exists   # corre en TODOS los nodos, incluso los cordoneados
      containers:
        - name: node-problem-detector
          image: registry.k8s.io/node-problem-detector/node-problem-detector:v0.8.20
          securityContext:
            privileged: true
          resources:
            requests: { cpu: 10m, memory: 80Mi }
            limits:   { memory: 160Mi }
          volumeMounts:
            - { name: log,          mountPath: /var/log,       readOnly: true }
            - { name: kmsg,         mountPath: /dev/kmsg,      readOnly: true }
            - { name: localtime,    mountPath: /etc/localtime, readOnly: true }
      volumes:
        - { name: log,       hostPath: { path: /var/log } }
        - { name: kmsg,      hostPath: { path: /dev/kmsg } }
        - { name: localtime, hostPath: { path: /etc/localtime } }
```

NPD traduce eventos del kernel (`KernelOops`, `OOMKilling`, `TaskHung`, corrupción de filesystem) en **Node Conditions** y **Events** que el scheduler y las alertas pueden consumir — convierte una falla silenciosa de Capa 1 en una señal accionable de Capa 2/3.

### 3.6 Runbook automatizado como `Job` (remediación auto-documentada)

La madurez operativa transforma runbooks en código. Este `Job` captura un bundle de diagnóstico cuando dispara una alerta de nodo, sin depender de que la guardia recuerde los comandos a las 3 AM.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: node-diag-bundle
  namespace: sre-tools
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      nodeName: worker-07          # nodo bajo investigación
      hostPID: true
      hostNetwork: true
      tolerations: [{ operator: Exists }]
      containers:
        - name: diag
          image: registry.internal/sre/netshoot:v0.13
          securityContext: { privileged: true }
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -x
              echo "=== kubelet status ==="; systemctl status kubelet --no-pager | tail -20
              echo "=== container runtime ==="; crictl info | jq '.status.conditions'
              echo "=== disk pressure ==="; df -h /var/lib/kubelet /var/lib/containerd
              echo "=== memory ==="; free -m; cat /proc/pressure/memory
              echo "=== dmesg (OOM/kernel) ==="; dmesg -T | grep -iE 'oom|hung|error' | tail -30
              echo "=== conntrack ==="; conntrack -C; cat /proc/sys/net/netfilter/nf_conntrack_max
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 El barrido de triage inicial (los primeros 90 segundos)

```console
$ kubectl get pods -n payments -o wide
NAME                           READY   STATUS             RESTARTS      AGE   IP            NODE
payments-api-7d9f8c6b4-2xk9p   0/1     CrashLoopBackOff   6 (2m ago)    14m   10.244.3.17   worker-07
payments-api-7d9f8c6b4-8vhz2   1/1     Running            0             14m   10.244.1.42   worker-03
payments-api-7d9f8c6b4-jq4mn   0/1     CrashLoopBackOff   6 (90s ago)   14m   10.244.3.19   worker-07
payments-api-7d9f8c6b4-wl2rk   1/1     Running            0             14m   10.244.2.51   worker-05
```

Señal inmediata: **los dos Pods que crashean están en el mismo nodo, `worker-07`**. Esto no es un bug de la app (los otros dos corren bien) — es un problema de nodo (Capa 1). El diagnóstico ya bajó tres capas con un solo comando.

```console
$ kubectl get events -n payments --sort-by='.lastTimestamp' | tail -8
LAST SEEN   TYPE      REASON      OBJECT                              MESSAGE
3m12s       Warning   Unhealthy   pod/payments-api-...-2xk9p          Liveness probe failed: Get "http://10.244.3.17:8080/healthz": dial tcp 10.244.3.17:8080: connect: connection refused
2m45s       Warning   BackOff     pod/payments-api-...-2xk9p          Back-off restarting failed container api
90s         Warning   OOMKilling  node/worker-07                      Memory cgroup out of memory: Killed process 24817 (payments-api)
```

El `OOMKilling` reportado por NPD sobre `worker-07` confirma la hipótesis: presión de memoria a nivel de nodo.

### 4.2 Diagnóstico de `OOMKilled`

```console
$ kubectl describe pod payments-api-7d9f8c6b4-2xk9p -n payments | sed -n '/Last State/,/Ready/p'
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 07 Aug 2026 14:22:10 +0000
      Finished:     Thu, 07 Aug 2026 14:24:02 +0000
    Ready:          False
```

`Exit Code: 137` = `128 + 9` (SIGKILL) → el kernel OOM killer terminó el proceso. La pregunta clave: **¿el container excedió su limit, o el nodo entero está sin memoria?** Se distingue así:

```console
$ kubectl top pod -n payments --containers
POD                            NAME   CPU(cores)   MEMORY(bytes)
payments-api-7d9f8c6b4-8vhz2   api    180m         498Mi          # límite es 512Mi → al borde

$ kubectl top node worker-07
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-07   3820m        95%    15420Mi         96%              # nodo saturado: overcommit

$ kubectl get node worker-07 -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}'
True
```

`MemoryPressure=True` en el nodo → el kubelet empezará a **evictar** Pods (Capa 3). Es una falla de *capacidad*, no de la app. Remediación inmediata: cordonar el nodo y redistribuir; remediación de fondo: ajustar `requests`/`limits` o el autoscaler.

### 4.3 Debug de un Pod sin shell (`distroless`) con ephemeral container

Las imágenes de producción hardened (`distroless`, `scratch`) no tienen `sh`, `curl` ni `ps`. `kubectl debug` inyecta un container efímero que comparte los namespaces del target **sin reiniciarlo**:

```console
$ kubectl debug -it payments-api-7d9f8c6b4-8vhz2 -n payments \
    --image=nicolaka/netshoot --target=api -- bash
Defaulting debug container name to debugger-x7k2p.
root@payments-api-7d9f8c6b4-8vhz2:/# ss -tlnp
State    Recv-Q   Send-Q   Local Address:Port   Peer Address:Port   Process
LISTEN   0        128            0.0.0.0:8080        0.0.0.0:*
root@payments-api-7d9f8c6b4-8vhz2:/# curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/readyz
503
root@payments-api-7d9f8c6b4-8vhz2:/# nslookup postgres.payments.svc.cluster.local
;; connection timed out; no servers could be reached
```

Diagnóstico: el proceso escucha (`8080` LISTEN) pero `/readyz` da 503 y **el DNS del cluster no resuelve**. El problema no es la app — es CoreDNS (Capa 3). Confirmar:

```console
$ kubectl -n kube-system get pods -l k8s-app=kube-dns
NAME                       READY   STATUS    RESTARTS   AGE
coredns-5d78c9869d-4mtwq   0/1     Running   0          8m
coredns-5d78c9869d-p9xbt   1/1     Running   0          62d

$ kubectl -n kube-system logs coredns-5d78c9869d-4mtwq --tail=5
[ERROR] plugin/errors: 2 payments.svc.cluster.local. A: read udp 10.244.3.8:41823->10.96.0.10:53: i/o timeout
[ERROR] plugin/kubernetes: Kubernetes API connection failure: Get "https://10.96.0.1:443/api/v1/...": dial tcp 10.96.0.1:443: i/o timeout
```

CoreDNS no llega al apiserver → el problema baja aún más, a la red (Capa 3 CNI) o al apiserver (Capa 2).

### 4.4 Debug del nodo (host namespace)

```console
$ kubectl debug node/worker-07 -it --image=nicolaka/netshoot
Creating debugging pod node-debugger-worker-07-fx8k2 with container debugger...
root@worker-07:/# chroot /host
root@worker-07:/# crictl ps --state Running | wc -l
23
root@worker-07:/# journalctl -u kubelet --no-pager --since "10 min ago" | grep -iE 'error|fail' | tail -5
Aug 07 14:23:51 worker-07 kubelet[1832]: E0807 14:23:51 kubelet.go:2419] "Container runtime network not ready" networkReady="NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized"
root@worker-07:/# ls /etc/cni/net.d/
# (vacío) → el CNI perdió su config
```

Causa raíz encontrada: el plugin CNI perdió su configuración en `worker-07`. La cascada completa reconstruida de arriba a abajo: CNI caído (Capa 3) → CoreDNS sin red → readiness 503 → Pods sin tráfico + presión de memoria por acumulación de retries.

### 4.5 Salud del control plane y etcd (Capa 2)

```console
$ kubectl get --raw='/readyz?verbose' | grep -vE 'ok$'
[+]etcd ok
[-]etcd-readiness failed: reason withheld
readyz check failed

$ kubectl -n kube-system exec etcd-cp-01 -- etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --write-out=table
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT INDEX |
+------------------------+------------------+---------+---------+-----------+------------+
| https://10.0.1.10:2379 | 8e9e05c52164694d |  3.5.15 |  7.8 GB |     true  |   48291043 |
+------------------------+------------------+---------+---------+-----------+------------+
```

`DB SIZE 7.8 GB` con quota por defecto de 8 GiB → etcd está por alcanzar `NOSPACE` y pasará a modo read-only, tumbando todas las escrituras del cluster. Remediación:

```console
$ kubectl -n kube-system exec etcd-cp-01 -- etcdctl ... defrag --cluster
Finished defragmenting etcd member[https://10.0.1.10:2379]

$ kubectl -n kube-system exec etcd-cp-01 -- etcdctl ... alarm list
memory alarm:NOSPACE   # todavía activo tras defrag
$ kubectl -n kube-system exec etcd-cp-01 -- etcdctl ... alarm disarm
```

### 4.6 Remediación por rollback

```console
$ kubectl rollout history deployment/payments-api -n payments
REVISION  CHANGE-CAUSE
6         kubectl set image ... payments-api=registry.internal/payments-api:v2.14.1
7         kubectl set image ... payments-api=registry.internal/payments-api:v2.15.0  ← degradación

$ kubectl rollout undo deployment/payments-api -n payments --to-revision=6
deployment.apps/payments-api rolled back

$ kubectl rollout status deployment/payments-api -n payments --timeout=120s
Waiting for deployment "payments-api" rollout to finish: 2 of 4 updated replicas are available...
deployment "payments-api" successfully rolled out
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Metodología sistemática de triage

Dos frameworks complementarios estructuran el diagnóstico para no perderse en un cluster grande:

- **USE (Brendan Gregg)** — para **recursos** (nodos, disco, red): para cada recurso, chequear **U**tilization, **S**aturation, **E**rrors. Ideal cuando el síntoma es "está lento / se satura".
- **RED (Tom Wilkie)** — para **servicios/requests**: **R**ate (req/s), **E**rrors (fallos/s), **D**uration (latencia). Ideal cuando el síntoma es "las requests fallan / tardan".

La secuencia operativa disciplinada:

1. **Confirmar el impacto** — ¿el usuario está afectado? (RED sobre el servicio) → decide severidad vía burn rate.
2. **Delimitar el blast radius** — ¿un Pod, un nodo, un namespace, una zona, el cluster? `kubectl get pods -o wide` correlacionando por `NODE`, `ZONE`, `namespace`.
3. **Localizar la capa** — bajar la pila 5→1 con la señal correcta de cada capa (§2.1).
4. **Mitigar primero** — restaurar servicio (§2.3) antes de entender la causa.
5. **Verificar la restauración** — SLI de vuelta dentro del SLO, no solo "el Pod está Running".
6. **Postmortem** — causa raíz, timeline, action items (§5.4).

### 5.2 Árbol de decisión por escenario de Pod

| STATUS observado | Primer comando | Causa probable | Remediación |
|---|---|---|---|
| `Pending` | `kubectl describe pod` → Events | Sin recursos / taint / PVC no bound / affinity | Escalar nodos, revisar `requests`, tolerations, StorageClass |
| `ImagePullBackOff` | `describe` → `Failed to pull image` | Tag inexistente / registry auth / red | Corregir tag, `imagePullSecrets`, egress al registry |
| `CrashLoopBackOff` | `logs --previous` | Crash de app / config errónea / dep caída | Fix config, rollback, arreglar liveness (§3.3) |
| `OOMKilled` (137) | `describe` + `top` | Limit bajo / leak / overcommit de nodo | Subir limit, arreglar leak, cordon nodo |
| `Running` pero `0/1` READY | `logs` + probe `/readyz` | Readiness falla → dependencia caída | Diagnosticar dep (DNS, DB, mesh) |
| `Terminating` colgado | `describe` → finalizers | Finalizer bloqueado / volumen no desmonta | Investigar operator; **nunca** `--force` a ciegas |
| `Evicted` | `describe node` → conditions | DiskPressure / MemoryPressure | Liberar recurso en el nodo, ajustar `requests` |

> **Nota sobre `--grace-period=0 --force`**: elimina el objeto del apiserver sin confirmar que el kubelet terminó el container. En un StatefulSet con almacenamiento `ReadWriteOnce`, esto puede producir **doble escritura** (split-brain) si el Pod original sigue vivo en un nodo particionado. Es una remediación de último recurso, no un atajo.

### 5.3 Checklist de verificación post-remediación

```console
# 1. El SLI volvió al SLO (no basta con "Running")
$ kubectl get --raw '/metrics' | grep apiserver_request_total   # o consulta Prometheus del burn rate

# 2. Sin Pods insanos residuales en el blast radius
$ kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 3. Nodos sin conditions de presión
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
MEM:.status.conditions[?\(@.type==\"MemoryPressure\"\)].status,\
DISK:.status.conditions[?\(@.type==\"DiskPressure\"\)].status,\
PID:.status.conditions[?\(@.type==\"PIDPressure\"\)].status

# 4. Alertas resueltas en Alertmanager
$ amtool alert query --alertmanager.url=http://alertmanager.monitoring:9093 severity=critical
# (salida vacía = sin criticals activos)

# 5. Sin eventos Warning nuevos tras la remediación
$ kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail
```

### 5.4 El postmortem sin culpa (blameless)

La remediación cierra el incidente; el postmortem cierra el **ciclo de aprendizaje**. Un postmortem CNPE-grade contiene:

- **Timeline** con timestamps UTC: detección (MTTD), ACK (MTTA), mitigación, resolución (MTTR).
- **Impacto cuantificado**: error budget consumido, requests fallidas, tenants afectados.
- **Causa raíz** (los 5 porqués), separando la *causa técnica* de la *causa sistémica* (por qué el sistema permitió que ocurriera).
- **Detección**: ¿la alerta disparó a tiempo? Si el MTTD fue alto, hay un action item de observabilidad.
- **Action items** con dueño y fecha, priorizados: *contención* (evitar recurrencia) vs *mitigación* (bajar el MTTR la próxima vez).
- **Blameless**: se analiza el sistema, no a la persona. Un humano que ejecutó un comando peligroso revela que el sistema **permitía** ese comando peligroso — ese es el bug.

---

## 6. Referencias

- CNCF — *CNPE (Cloud Native Platform Engineer) Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Google — *SRE Book*, cap. "Effective Troubleshooting" y "Managing Incidents": https://sre.google/sre-book/effective-troubleshooting/
- Google — *SRE Workbook*, cap. "Alerting on SLOs" (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- Kubernetes — *Debug Running Pods* (ephemeral containers, `kubectl debug`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — *Debug a Kubernetes Node*: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- Kubernetes — *Configure Liveness, Readiness and Startup Probes*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — *Specifying a Disruption Budget (PDB)*: https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Kubernetes — *Node Problem Detector*: https://kubernetes.io/docs/tasks/debug/debug-cluster/monitor-node-health/
- Kubernetes — *Operating etcd clusters* (defrag, quota, alarms): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — *Troubleshooting Clusters*: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Prometheus Operator — *PrometheusRule / AlertmanagerConfig API*: https://prometheus-operator.dev/docs/developer/alerting/
- Prometheus — *Alerting rules*: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- CoreDNS — *Debugging DNS Resolution* (Kubernetes docs): https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Brendan Gregg — *The USE Method*: https://www.brendangregg.com/usemethod.html
- Weaveworks / Tom Wilkie — *The RED Method*: https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- etcd — *Maintenance (defragmentation, space quota)*: https://etcd.io/docs/latest/op-guide/maintenance/