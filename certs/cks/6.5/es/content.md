# 6.5 — Usar los Kubernetes Audit Logs para monitorear el acceso

**Certificación:** CKS (Certified Kubernetes Security Specialist) — Versión del examen **1.34**
**Dominio:** Monitoring, Logging and Runtime Security — **peso 4**

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 Qué es realmente el audit log

El API server de Kubernetes es el **único punto de paso obligatorio** para toda mutación declarativa y toda lectura del estado del cluster. `kubectl`, controllers, operators, runners de CI, kubelets, el scheduler, los admission webhooks y cada humano — todos ellos terminan emitiendo peticiones HTTP a `kube-apiserver`. El **subsistema de auditoría** es una cadena de implementaciones de `AuditBackend` conectadas a la cadena de filtros HTTP del apiserver (`WithAudit`), que emite un objeto `Event` estructurado de `audit.k8s.io/v1` por cada petición que una policy considere interesante.

Ese solo hecho es toda la propuesta de valor arquitectónica: **si instrumentás un componente, obtenés un registro cronológico, relevante para seguridad y con evidencia de manipulación, de quién hizo qué a qué objeto, cuándo, desde dónde, y si la autorización lo permitió.**

### 1.2 El problema de producción que resuelve

Considerá las preguntas de postmortem que produce todo incidente real:

| Pregunta del incidente | Sin audit logs | Con audit logs |
|---|---|---|
| "¿Quién borró el StatefulSet de `prod` a las 03:12?" | `kubectl get events` — ya recolectado por el GC después de 1 h | `user.username`, `sourceIPs`, `userAgent`, `auditID` exactos |
| "¿El token de CI comprometido leyó nuestros Secrets?" | Imposible de saber | `get`/`list` sobre `resources: secrets` filtrado por `user.username` |
| "¿Se usó esta ServiceAccount desde fuera de la red del cluster?" | Imposible de saber | `sourceIPs` vs. el CIDR de Pods |
| "¿Alguien hizo `exec` en el Pod bajo alcance PCI?" | Imposible de saber | `objectRef.subresource == "exec"` |
| "¿Qué identidad escaló privilegios vía un ClusterRoleBinding?" | Imposible de saber | Evento de nivel `RequestResponse` con el objeto RBAC completo |
| "¿Seguimos llamando a una API removida antes del upgrade a 1.35?" | Solo desde métricas, sin atribución | `annotations["k8s.io/deprecated"] == "true"` + `userAgent` |

Los **Events** de Kubernetes (`v1.Event`) *no* son un rastro de auditoría: son best-effort, namespaced, agregados, deduplicados y con TTL (1 hora por defecto vía `--event-ttl`). Existen para debugging operativo, no para forensia ni cumplimiento. Los audit logs son el único mecanismo de primera parte que satisface los requisitos de **PCI-DSS 10.x**, **SOC 2 CC7.2**, **ISO 27001 A.12.4** y **NIST 800-53 AU-2/AU-3** para el control plane.

### 1.3 Las tres tensiones arquitectónicas que tenés que resolver

Habilitar el audit logging es trivial. Habilitarlo *correctamente en producción* fuerza tres compromisos explícitos, y la competencia a nivel CKS significa poder argumentar cada uno:

**Tensión 1 — Fidelidad vs. volumen vs. filtración de secretos.**
El nivel `RequestResponse` captura el objeto completo. Sobre un `Secret` o un `TokenRequest`, eso escribe **material de credenciales en texto plano a un archivo en el disco del nodo del control plane**, que luego se envía a tu agregador de logs, se indexa, se replica y se retiene por 400 días. Una policy `RequestResponse` aplicada a `secrets` es un *pipeline de exfiltración de credenciales que construiste vos mismo*. A la inversa, `Metadata` sobre un create de `clusterrolebindings` te dice *que* ocurrió una escalada pero no *a quién se vinculó el rol* — inútil para responder.

**Tensión 2 — Durabilidad vs. latencia del API server.**
El backend de log usa por defecto el modo `blocking`: el handler de la petición no se completa hasta que el evento se escribe. Si `/var/log` se llena o el disco se atasca, **cada petición a la API se atasca con él** — el control plane queda no disponible. El modo `batch` los desacopla al costo de una ventana acotada de pérdida de eventos ante una caída dura. El backend de webhook lo empeora: un SIEM lento en modo `blocking` inyecta su latencia de red en el p99 de cada llamada a la API.

**Tensión 3 — Localidad vs. agregación en control planes HA.**
Cada `kube-apiserver` escribe **su propio archivo local**. Un control plane apilado de tres nodos detrás de un load balancer produce tres logs parciales e intercalados. Cualquier consulta ("mostrame todo lo que hizo el usuario X") es incorrecta a menos que agregues los tres. Peor aún, la reconstrucción de un nodo destruye evidencia silenciosamente. Los audit logs solo son forensicamente útiles una vez que se envían fuera del nodo a almacenamiento de escritura única.

### 1.4 Lo que el audit log *no* ve (el límite del control)

Esta es una sonda favorita en exámenes y entrevistas. El audit log registra peticiones **a `kube-apiserver`**. Es ciego a:

- Acceso directo a la API del `kubelet` (`https://node:10250/run/...`, `/exec`, `/logs`) que evita el apiserver. Eso llega a la configuración de auditoría propia del kubelet (separada, rara vez habilitada).
- Acceso directo a `etcd` (`etcdctl get /registry/secrets/... --prefix`) — una lectura completa de todos los Secrets del cluster con **cero** eventos de auditoría.
- Actividad a nivel de nodo: SSH, escapes de contenedor, ejecución de procesos, escrituras de archivos, red saliente. Ese es territorio de Falco / eBPF / auditd.
- API servers agregados (`metrics.k8s.io`, backends `APIService` personalizados) — la petición de *proxying* es auditada por `kube-apiserver`, pero el manejo interno del extension server solo es auditado por su propia configuración.
- Peticiones rechazadas por el load balancer, el firewall, o fallos de handshake TLS.

> **Consecuencia de diseño:** los audit logs son la capa de *identidad e intención*. Falco/eBPF es la capa de *comportamiento*. Ninguna sustituye a la otra; una plataforma madura correlaciona ambas por Pod, nodo y timestamp.

---

## 2. Arquitectura del subsistema de auditoría

### 2.1 Ciclo de vida de la petición y stages de auditoría

```
                      kube-apiserver HTTP filter chain
   client
     │
     ├─► WithPanicRecovery
     ├─► WithRequestInfo
     ├─► WithAudit ◄──────── creates AuditContext, assigns auditID (UUID),
     │        │              sets response header "Audit-Id"
     │        │
     │        ├─ stage: RequestReceived      (emitted immediately, before authn)
     │        │
     ├─► WithAuthentication  ── populates event.user / event.impersonatedUser
     ├─► WithImpersonation
     ├─► WithAuthorization   ── writes annotations authorization.k8s.io/{decision,reason}
     ├─► WithPriorityAndFairness
     ├─► Admission (mutating → validating) ── writes admission annotations
     ├─► Storage / etcd
     │        │
     │        ├─ stage: ResponseStarted      (long-running only: watch, exec, portforward)
     │        └─ stage: ResponseComplete     (emitted when the response is fully written)
     │
     └─► on unrecovered panic ─ stage: Panic
                       │
                       ▼
              ┌────────────────────┐
              │   Audit Policy     │  first matching rule wins → level
              │  (audit.k8s.io/v1) │  no match → event dropped
              └────────┬───────────┘
                       │ Event (audit.k8s.io/v1)
            ┌──────────┴───────────┐
            ▼                      ▼
     log backend             webhook backend
  (file / stdout,          (POST batches of EventList
   lumberjack rotation)     to an HTTPS endpoint)
```

### 2.2 Los cuatro stages

| Stage | Cuándo se emite | ¿Contiene una respuesta? | Uso típico |
|---|---|---|---|
| `RequestReceived` | El handler recibe la petición, **antes** de authn/authz | No | Detectar peticiones que nunca se completaron (colgadas, apiserver matado). Duplica el volumen de log. **Casi siempre se omite.** |
| `ResponseStarted` | Cabeceras de respuesta escritas pero el cuerpo todavía se está transmitiendo — solo para peticiones de larga duración (`watch`, `exec`, `attach`, `portforward`) | Solo cabeceras | Capturar el *inicio* de una sesión interactiva incluso si nunca termina limpiamente |
| `ResponseComplete` | El cuerpo de la respuesta terminó | Sí (`responseStatus`, y el objeto si el nivel lo permite) | **El evento que realmente analizás** |
| `Panic` | El handler tuvo un panic | No | Forensia de bug del apiserver / DoS |

Un solo `kubectl exec` produce por lo tanto hasta **tres** eventos que comparten un mismo `auditID`: `RequestReceived`, `ResponseStarted`, `ResponseComplete`. La correlación es por `auditID` — nunca por timestamp.

### 2.3 Los cuatro niveles

| Nivel | Metadata (quién/qué/cuándo/verb/objectRef) | Cuerpo de la petición | Cuerpo de la respuesta | Notas |
|---|---|---|---|---|
| `None` | — | — | — | El evento se descarta. Se usa para silenciar ruido **antes** de una regla más amplia. |
| `Metadata` | ✅ | ❌ | ❌ | Default seguro. Nunca filtra el contenido del objeto. |
| `Request` | ✅ | ✅ | ❌ | Muestra *qué se pidió*. Para URLs no-resource degrada a `Metadata`. |
| `RequestResponse` | ✅ | ✅ | ✅ | Fidelidad completa. **Nunca para `secrets`, `configmaps` con secretos, `tokenreviews`, `serviceaccounts/token`, `certificatesigningrequests`.** Para `watch`, *no* incluye los objetos transmitidos. |

> **Filo cortante:** para `get`/`list`, `Request` no agrega esencialmente nada (no hay cuerpo de petición) mientras que `RequestResponse` vuelca el conjunto entero de objetos devueltos — un `list` de 4 000 Pods se convierte en una única línea de auditoría de varios megabytes. Esta es la causa número uno de agotamiento de disco inducido por auditoría.

---

## 3. El objeto `Policy` — referencia completa de campos y semántica de evaluación

### 3.1 Semántica de evaluación (memorizá esto)

1. Las reglas se evalúan **de arriba hacia abajo**. **Gana la primera regla que coincide**; la evaluación se detiene.
2. Si **ninguna regla coincide**, el evento se **descarta** (`None` implícito). No hay catch-all implícito.
3. Dentro de una regla, todos los selectores especificados se combinan con **AND**; los valores dentro de un selector se combinan con **OR**.
4. Un selector **omitido** coincide con todo (`verbs` omitido = todos los verbs).
5. `namespaces: [""]` (elemento de cadena vacía) coincide con recursos **cluster-scoped**. `namespaces: []` / omitido coincide con **todos** los namespaces.
6. `nonResourceURLs` soporta únicamente un wildcard `*` final (`/healthz*`), y no puede combinarse con `resources` en la misma regla.
7. Los subrecursos se expresan como `pods/exec`, `pods/log`, `serviceaccounts/token` dentro de `resources`.
8. El orden es un **control de seguridad**: una regla `None` para `system:kube-scheduler` colocada por encima de tu catch-all `Metadata` es cómo recortás el 80 % del volumen — pero colocar un `None` amplio demasiado temprano es cómo creás un punto ciego de auditoría en el que un atacante puede esconderse (p. ej. `None` para todo el grupo `system:serviceaccounts`).

### 3.2 Esquema completo

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Stages omitted for EVERY rule. Per-rule omitStages is additive to this.
omitStages:
  - "RequestReceived"

# Strip metadata.managedFields from request/response bodies (huge noise reducer).
# Available cluster-wide here, or per rule.
omitManagedFields: true

rules:
  - level: RequestResponse            # None | Metadata | Request | RequestResponse

    # ── Subject selectors (OR within each list, AND across lists) ──────────────
    users:                            # exact authenticated usernames
      - "system:serviceaccount:ci:deployer"
      - "alice@example.com"
    userGroups:                       # any group returned by the authenticator
      - "system:masters"
      - "oidc:platform-admins"

    # ── Verb selector ─────────────────────────────────────────────────────────
    verbs:                            # get list watch create update patch delete
      - create                        # deletecollection proxy impersonate
      - update
      - patch
      - delete

    # ── Resource selector (mutually exclusive with nonResourceURLs) ───────────
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
        resourceNames: []             # [] = all names; else exact names only
      - group: ""                     # core API group
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

    # ── Namespace selector ────────────────────────────────────────────────────
    namespaces:                       # [] = all; [""] = cluster-scoped only
      - "prod"
      - "payments"

    # ── Non-resource selector (mutually exclusive with resources) ─────────────
    # nonResourceURLs:
    #   - "/healthz*"
    #   - "/metrics"
    #   - "/version"

    # ── Per-rule overrides ────────────────────────────────────────────────────
    omitStages:
      - "RequestReceived"
    omitManagedFields: true
```

---

## 4. Tablas de compromisos

### 4.1 Comparación de backends

| Dimensión | **Backend de log** (`--audit-log-path`) | **Backend de webhook** (`--audit-webhook-config-file`) |
|---|---|---|
| Destino | Archivo local en el nodo del control plane, o `stdout` (`-`) | `POST` HTTPS de lotes de `audit.k8s.io/v1 EventList` |
| Modo por defecto | `blocking` | `batch` |
| Radio de impacto ante fallo | Disco lleno / atasco de IO → **las peticiones a la API se bloquean** | Endpoint caído → reintentos con backoff; en modo `blocking` → **inyección de latencia en la API** |
| Rotación | Integrada (lumberjack): `maxsize`/`maxbackup`/`maxage`/`compress` | N/A |
| Garantía de entrega | Al menos una vez a disco (blocking) | Best-effort; los eventos se descartan cuando el buffer se desborda |
| Ordenamiento | Estricto por apiserver | Por lote, no global |
| Carga operativa | Necesita un shipper (Fluent Bit / Vector / Filebeat) | Necesita un receptor de alta disponibilidad |
| Sobrevive a la pérdida del nodo | ❌ a menos que se envíe fuera | ✅ (ya está fuera del nodo) |
| Relevancia para el examen CKS | **Alta** — esto es lo que se evalúa | Baja — conocimiento de solo lectura |
| Recomendado para producción | ✅ backend de log + shipper en el nodo (desacopla el apiserver de la disponibilidad del SIEM) | Solo con un receptor local, dentro del cluster y HA |

**Veredicto del arquitecto:** usá el **backend de log en modo `batch`** con un shipper local al nodo. Nunca hagas que la disponibilidad del control plane dependa del uptime de tu SIEM. El backend de webhook es apropiado solo cuando el receptor es un sidecar/DaemonSet local con una ruta de sub-milisegundo.

### 4.2 Comparación de modos

| `--audit-log-mode` / `--audit-webhook-mode` | Semántica | Pérdida de eventos ante caída | Impacto en la latencia de la API | Usalo cuando |
|---|---|---|---|---|
| `blocking` | El handler espera la escritura del backend; **los errores del backend se registran pero la petición igual tiene éxito** | Mínima | Directo — la latencia del backend se suma a cada petición auditada | El cumplimiento requiere que no haya huecos y el backend es un SSD local |
| `blocking-strict` | Como `blocking`, **pero un fallo en `RequestReceived` hace fallar la propia petición (HTTP 500)** | Ninguna (fail-closed) | Directo, más riesgo de disponibilidad | Entornos regulados que exigen "sin auditoría ⇒ sin operación" |
| `batch` | Eventos bufferizados en memoria, volcados asincrónicamente por tamaño o temporizador | Hasta `batch-buffer-size` eventos | Insignificante | **Recomendación por defecto para clusters grandes** |

`blocking-strict` es la postura fail-closed. Es correcta para un cluster de pagos y catastrófica para un cluster de desarrollo cuyo `/var/log` es un tmpfs de 2 GiB.

### 4.3 Modelo de volumen y costo por nivel

Estimá antes de habilitar. La fórmula:

```
bytes/day = events_per_second × 86400 × avg_bytes_per_event × compression_factor
```

| Forma de la policy | Eventos/s típicos (cluster de 100 nodos, 3 000 pods) | Bytes promedio/evento | Sin comprimir/día | Notas |
|---|---|---|---|---|
| Catch-all `Metadata`, sin reglas `None` | 1 500 – 4 000 | ~1,2 KB | **150 – 400 GB** | Dominado por los `watch` del controller-manager/scheduler + `get node` del kubelet |
| Igual, con `None` para componentes del sistema + `/healthz*` + ruido de solo lectura | 150 – 400 | ~1,3 KB | **17 – 45 GB** | Reducción de ~10×; el paso de ajuste con mayor apalancamiento |
| Policy escalonada (§5.2) | 100 – 300 | ~2,5 KB | **20 – 65 GB** | `RequestResponse` solo sobre objetos RBAC + admission |
| Catch-all `RequestResponse` | 1 500 – 4 000 | 8 – 60 KB | **1 – 20 TB** | Llenará el disco y tirará abajo etcd. Nunca hagas esto. |

`--audit-log-compress` típicamente rinde **8–12×** sobre datos de auditoría JSON (claves altamente repetitivas).

### 4.4 Audit logs vs. controles adyacentes

| Capacidad | Audit log | `v1.Event` | Falco / eBPF | Log del control plane del proveedor cloud |
|---|---|---|---|---|
| Atribuye una acción a una identidad | ✅ (usuario autenticado + grupos + SA) | ❌ | Parcial (uid/pod) | ✅ |
| Registra la *intención* (objeto declarativo) | ✅ | ❌ | ❌ | ✅ |
| Registra syscalls / ejecución de procesos dentro de un contenedor | ❌ | ❌ | ✅ | ❌ |
| Detecta lecturas directas con `etcdctl` | ❌ | ❌ | ✅ (archivo/proceso) | ❌ |
| Detecta exec directo al kubelet | ❌ | ❌ | ✅ | ❌ |
| Alertado en tiempo real | Necesita un pipeline externo | ❌ | ✅ integrado | Necesita un pipeline externo |
| Retención bajo tu control | ✅ | ❌ (1 h) | ✅ | Depende del proveedor |
| Configurable en control planes gestionados (EKS/GKE/AKS) | Solo un flag del proveedor — **la policy usualmente no es personalizable** | ✅ | ✅ | ✅ |

> **Chequeo de realidad en clusters gestionados:** en EKS activás `audit` en `logging.clusterLogging` y obtenés la policy fija de AWS en CloudWatch; en GKE obtenés Cloud Audit Logs con las categorías `ADMIN_READ`/`DATA_READ`/`DATA_WRITE`. No podés proveer tu propio archivo `Policy`. El examen CKS siempre usa **kubeadm**, donde sí podés.

---

## 5. Manifiestos completos e infraestructura

### 5.1 Policy mínima (línea base de nivel examen)

`/etc/kubernetes/audit/policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Full request+response for anything touching Secrets metadata is FORBIDDEN;
  #    Secrets are logged at Metadata only, so no secret material ever lands on disk.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]

  # 2. Interactive access to workloads — the highest-signal event class.
  - level: RequestResponse
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Everything else at Metadata.
  - level: Metadata
```

### 5.2 Policy escalonada de producción (original, anotada)

`/etc/kubernetes/audit/policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# RequestReceived doubles volume and carries no outcome. Drop it globally.
omitStages:
  - "RequestReceived"

# Strip metadata.managedFields (server-side apply bookkeeping). On a busy
# cluster this alone removes 30-60% of the bytes in Request/RequestResponse events.
omitManagedFields: true

rules:
  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 0 — NOISE SUPPRESSION.
  # These MUST come first. Every rule below is a deliberate blind spot: keep the
  # selectors as tight as possible (specific user AND specific verb AND specific
  # resource) so an attacker cannot hide inside them by impersonating a group.
  # ═══════════════════════════════════════════════════════════════════════════

  # Kubelet steady-state reads. Note: writes by kubelets are NOT suppressed.
  - level: None
    users: ["system:kubelet"]
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "services", "endpoints"]
      - group: "discovery.k8s.io"
        resources: ["endpointslices"]

  # Core controllers' read/watch loops (they generate the bulk of the traffic).
  - level: None
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:apiserver"
      - "system:serviceaccount:kube-system:endpoint-controller"
      - "system:serviceaccount:kube-system:endpointslice-controller"
      - "system:serviceaccount:kube-system:generic-garbage-collector"
      - "system:serviceaccount:kube-system:namespace-controller"
      - "system:serviceaccount:kube-system:resourcequota-controller"
    verbs: ["get", "list", "watch"]

  # Leader-election churn: one write every 2s per controller, forever.
  - level: None
    verbs: ["get", "update", "patch"]
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
    namespaces: ["kube-system", "kube-node-lease"]

  # Health/discovery/metrics endpoints hit by every probe and scraper.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/openapi*"
      - "/apis*"
      - "/api"
      - "/api/v1"

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 1 — SECRET-BEARING RESOURCES: Metadata ONLY, never the body.
  # This rule MUST appear before any broad RequestResponse rule, otherwise a
  # later wildcard would dump credential material to disk.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews", "selfsubjectreviews"]
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 2 — PRIVILEGE AND POLICY CHANGES: full fidelity, both directions.
  # These objects are small, rare, and are the payload of every escalation.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "admissionregistration.k8s.io"
        resources:
          - "validatingwebhookconfigurations"
          - "mutatingwebhookconfigurations"
          - "validatingadmissionpolicies"
          - "validatingadmissionpolicybindings"
      - group: "policy"
        resources: ["poddisruptionbudgets"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies"]
      - group: "apiextensions.k8s.io"
        resources: ["customresourcedefinitions"]
      - group: "apiregistration.k8s.io"
        resources: ["apiservices"]
      - group: "node.k8s.io"
        resources: ["runtimeclasses"]

  # Namespace lifecycle and PSA label changes (a relabel to `privileged` is an
  # escalation vector and is invisible at Metadata level).
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["namespaces", "namespaces/status", "namespaces/finalize"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 3 — INTERACTIVE / DATA-PLANE ACCESS.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: RequestResponse
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/proxy"
          - "services/proxy"
          - "nodes/proxy"
          - "nodes/log"
          - "pods/eviction"
          - "pods/ephemeralcontainers"   # debug containers = code exec in a live pod

  # Reading logs can exfiltrate application data; record it, but Metadata is enough.
  - level: Metadata
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["pods/log"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 4 — ALL OTHER WRITES: request body, no response (halves the bytes and
  # avoids echoing back server-populated fields we already know).
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""                      # core
      - group: "apps"
      - group: "batch"
      - group: "autoscaling"
      - group: "storage.k8s.io"
      - group: "scheduling.k8s.io"

  # Writes to any other (including custom) API group.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # ═══════════════════════════════════════════════════════════════════════════
  # TIER 5 — CATCH-ALL. Without this, unmatched events are silently dropped.
  # ═══════════════════════════════════════════════════════════════════════════
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 5.3 Manifiesto completo del static Pod `kube-apiserver`

`/etc/kubernetes/manifests/kube-apiserver.yaml` — los agregados relevantes para auditoría están marcados con `# AUDIT`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.0.10:6443
  creationTimestamp: null
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.0.0.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    # ─────────────────────────── AUDIT ───────────────────────────
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml      # AUDIT
    - --audit-log-path=/var/log/kubernetes/audit/audit.log       # AUDIT
    - --audit-log-format=json                                    # AUDIT (default)
    - --audit-log-maxage=30                                      # AUDIT: CIS — days
    - --audit-log-maxbackup=10                                   # AUDIT: CIS — files
    - --audit-log-maxsize=100                                    # AUDIT: CIS — MiB
    - --audit-log-compress=true                                  # AUDIT: gzip rotated
    - --audit-log-mode=batch                                     # AUDIT
    - --audit-log-batch-buffer-size=20000                        # AUDIT
    - --audit-log-batch-max-size=500                             # AUDIT
    - --audit-log-batch-max-wait=5s                              # AUDIT
    - --audit-log-batch-throttle-enable=true                     # AUDIT
    - --audit-log-batch-throttle-qps=50                          # AUDIT
    - --audit-log-batch-throttle-burst=100                       # AUDIT
    - --audit-log-truncate-enabled=true                          # AUDIT: cap giant events
    - --audit-log-truncate-max-event-size=204800                 # AUDIT: 200 KiB
    - --audit-log-truncate-max-batch-size=10485760               # AUDIT: 10 MiB
    # ─────────────────────────────────────────────────────────────
    image: registry.k8s.io/kube-apiserver:v1.34.0
    imagePullPolicy: IfNotPresent
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
    name: kube-apiserver
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 10.0.0.10
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 10.0.0.10
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki
      name: etc-pki
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    # ─────────────────────────── AUDIT ───────────────────────────
    - mountPath: /etc/kubernetes/audit                           # AUDIT
      name: audit-policy                                         # AUDIT
      readOnly: true                                             # AUDIT: policy is RO
    - mountPath: /var/log/kubernetes/audit                       # AUDIT
      name: audit-logs                                           # AUDIT
      readOnly: false                                            # AUDIT: MUST be writable
    # ─────────────────────────────────────────────────────────────
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/pki
      type: DirectoryOrCreate
    name: etc-pki
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  # ─────────────────────────── AUDIT ───────────────────────────
  - hostPath:                                                    # AUDIT
      path: /etc/kubernetes/audit                                # AUDIT
      type: DirectoryOrCreate                                    # AUDIT
    name: audit-policy                                           # AUDIT
  - hostPath:                                                    # AUDIT
      path: /var/log/kubernetes/audit                            # AUDIT
      type: DirectoryOrCreate                                    # AUDIT: NOT FileOrCreate
    name: audit-logs                                             # AUDIT
  # ─────────────────────────────────────────────────────────────
status: {}
```

> **Dos modos de fallo escondidos en ese manifiesto.**
> **(a)** Montá el **directorio**, no el archivo. Si usás `hostPath.type: FileOrCreate` sobre `audit.log` y montás el archivo directamente, el contenedor ve un bind mount a un inodo específico; cuando lumberjack rota *renombrando* el archivo, el apiserver sigue escribiendo al inodo ahora desvinculado y tu `audit.log` vivo en el host deja de crecer.
> **(b)** `readOnly: true` sobre `audit-logs` produce `permission denied` en el arranque y el apiserver nunca queda ready. Solo el montaje de la *policy* es de solo lectura.

### 5.4 Sobrevivir a `kubeadm upgrade` — configuración declarativa

Editar el static Pod a mano es lo que pide el examen, pero `kubeadm upgrade apply` regenera ese archivo a partir del `ClusterConfiguration` del cluster. Persistí el cambio en el ConfigMap `kubeadm-config` en su lugar (API `v1beta4`, vigente para 1.31+ — notá que `extraArgs` es una **lista de `{name, value}`**, no un mapa):

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.0
apiServer:
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-log-compress
      value: "true"
    - name: audit-log-mode
      value: batch
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-logs
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
```

```bash
$ sudo kubeadm init phase control-plane apiserver --config /root/kubeadm-audit.yaml
W0806 09:02:11.441233   18422 common.go:101] WARNING: Usage of the --config flag with kubeadm init phase is deprecated for some phases
[control-plane] Using manifest folder "/etc/kubernetes/manifests"
[control-plane] Creating static Pod manifest for "kube-apiserver"
```

### 5.5 Backend de webhook (envío dinámico a un SIEM)

`--audit-webhook-config-file` toma un archivo **con forma de kubeconfig** cuyo `cluster.server` es la URL del receptor:

`/etc/kubernetes/audit/webhook-kubeconfig.yaml`

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      server: https://audit-sink.observability.svc.cluster.local:8443/events
      certificate-authority: /etc/kubernetes/audit/sink-ca.crt
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/pki/apiserver.crt
      client-key: /etc/kubernetes/pki/apiserver.key
current-context: audit-sink
contexts:
  - name: audit-sink
    context:
      cluster: audit-sink
      user: kube-apiserver
```

Flags correspondientes:

```
- --audit-webhook-config-file=/etc/kubernetes/audit/webhook-kubeconfig.yaml
- --audit-webhook-mode=batch
- --audit-webhook-batch-max-size=400
- --audit-webhook-batch-max-wait=30s
- --audit-webhook-initial-backoff=10s
- --audit-webhook-truncate-enabled=true
- --audit-webhook-truncate-max-event-size=102400
```

El receptor recibe cuerpos `POST` de `{"apiVersion":"audit.k8s.io/v1","kind":"EventList","items":[...]}`.

> Los backends de log y de webhook pueden habilitarse **simultáneamente** — el apiserver hace fan-out a un backend de unión. Un patrón común es: backend de log a disco para retención forense + webhook a un plugin `k8saudit` local de Falco para detección en tiempo real.

### 5.6 Enviar el log fuera del nodo — DaemonSet de Fluent Bit

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: audit-shipper
  namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: audit-shipper-config
  namespace: observability
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush             5
        Daemon            Off
        Log_Level         info
        Parsers_File      parsers.conf
        HTTP_Server       On
        HTTP_Listen       0.0.0.0
        HTTP_Port         2020
        storage.path      /var/lib/fluent-bit/state
        storage.sync      normal
        storage.backlog.mem_limit 64M

    [INPUT]
        Name              tail
        Alias             k8s_audit
        Tag               k8s.audit
        Path              /var/log/kubernetes/audit/audit.log
        Parser            audit_json
        DB                /var/lib/fluent-bit/state/audit.db
        DB.locking        true
        Mem_Buf_Limit     128MB
        storage.type      filesystem
        Refresh_Interval  5
        Skip_Long_Lines   On
        Buffer_Max_Size   2MB

    [FILTER]
        Name              record_modifier
        Match             k8s.audit
        Record            cluster prod-eu-west-1
        Record            source_node ${NODE_NAME}

    # Defence in depth: even though the policy forbids RequestResponse on
    # Secrets, strip any body that could carry credential material.
    [FILTER]
        Name              nest
        Match             k8s.audit
        Operation         lift
        Nested_under      objectRef
        Add_prefix        objectRef_

    [FILTER]
        Name              grep
        Match             k8s.audit
        Exclude           level RequestResponse
        # only applied to the redaction branch below in a real pipeline;
        # shown here to make the control explicit

    [OUTPUT]
        Name              opensearch
        Match             k8s.audit
        Host              opensearch.observability.svc.cluster.local
        Port              9200
        HTTP_User         ${OS_USER}
        HTTP_Passwd       ${OS_PASSWORD}
        tls               On
        tls.verify        On
        tls.ca_file       /etc/ssl/certs/ca-certificates.crt
        Index             k8s-audit
        Logstash_Format   On
        Logstash_Prefix   k8s-audit
        Time_Key          stageTimestamp
        Retry_Limit       False
        Replace_Dots      On

  parsers.conf: |
    [PARSER]
        Name        audit_json
        Format      json
        Time_Key    stageTimestamp
        Time_Format %Y-%m-%dT%H:%M:%S.%LZ
        Time_Keep   On
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: audit-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: audit-shipper
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: audit-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: audit-shipper
    spec:
      serviceAccountName: audit-shipper
      priorityClassName: system-node-critical
      # Control-plane nodes only: that is where the audit log lives.
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsNonRoot: false          # must read root-owned 0600 audit.log
        runAsUser: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          imagePullPolicy: IfNotPresent
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OS_USER
              valueFrom:
                secretKeyRef:
                  name: opensearch-credentials
                  key: username
            - name: OS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: opensearch-credentials
                  key: password
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]   # read 0600 audit.log without full root FS access
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              memory: 512Mi
          ports:
            - name: http
              containerPort: 2020
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/fluent-bit.conf
              subPath: fluent-bit.conf
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/parsers.conf
              subPath: parsers.conf
              readOnly: true
            - name: audit-logs
              mountPath: /var/log/kubernetes/audit
              readOnly: true
            - name: state
              mountPath: /var/lib/fluent-bit/state
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          configMap:
            name: audit-shipper-config
        - name: audit-logs
          hostPath:
            path: /var/log/kubernetes/audit
            type: Directory
        - name: state
          hostPath:
            path: /var/lib/fluent-bit/state
            type: DirectoryOrCreate
        - name: tmp
          emptyDir: {}
```

> **Nota de seguridad sobre el shipper:** monta una ruta del host que contiene cada identidad que tocó el cluster y corre en el control plane. Es en sí mismo un objetivo de alto valor. Montalo con `readOnly: true`, quitá todas las capabilities excepto `DAC_READ_SEARCH`, poné `readOnlyRootFilesystem: true`, y nunca le des una ServiceAccount con permisos de lectura sobre el cluster.

---

## 6. Aplicarlo y leer salida real

### 6.1 Preparar el nodo

```bash
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
$ sudo chmod 0700 /var/log/kubernetes/audit
$ sudo vi /etc/kubernetes/audit/policy.yaml
$ sudo chmod 0600 /etc/kubernetes/audit/policy.yaml

$ ls -la /etc/kubernetes/audit/
total 12
drwxr-xr-x  2 root root 4096 Aug  6 09:01 .
drwxr-xr-x  5 root root 4096 Aug  6 09:00 ..
-rw-------  1 root root 3187 Aug  6 09:01 policy.yaml
```

Validá el YAML **antes** de tocar el static Pod — una policy inválida es un apiserver que no va a arrancar:

```bash
$ python3 -c 'import yaml,sys; d=yaml.safe_load(open("/etc/kubernetes/audit/policy.yaml")); print(d["apiVersion"], d["kind"], len(d["rules"]), "rules")'
audit.k8s.io/v1 Policy 14 rules
```

### 6.2 Editar el static Pod y observar el reinicio

```bash
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

El kubelet detecta el cambio de mtime dentro de su `--file-check-frequency` (20 s por defecto) y recrea el Pod. Esperá que la API esté no disponible por 15–60 s:

```bash
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT   POD ID         POD
2f9a11c7d3b80  8c9a5f2ed12b4  18 seconds ago  Running   kube-apiserver   3         a71c4e2b90f13  kube-apiserver-cp-01

$ kubectl get --raw='/readyz?verbose' | tail -5
[+]shutdown ok
[+]etcd ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]autoregister-completion ok
readyz check passed
```

### 6.3 Confirmar que los flags surtieron efecto

```bash
$ kubectl -n kube-system get pod kube-apiserver-cp-01 \
    -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -- --audit
"--audit-policy-file=/etc/kubernetes/audit/policy.yaml"
"--audit-log-path=/var/log/kubernetes/audit/audit.log"
"--audit-log-format=json"
"--audit-log-maxage=30"
"--audit-log-maxbackup=10"
"--audit-log-maxsize=100"
"--audit-log-compress=true"
"--audit-log-mode=batch"
```

```bash
$ sudo ls -la /var/log/kubernetes/audit/
total 8412
drwx------ 2 root root    4096 Aug  6 09:14 .
drwxr-xr-x 3 root root    4096 Aug  6 09:03 ..
-rw------- 1 root root 8598143 Aug  6 09:16 audit.log
```

### 6.4 Generar una señal y encontrarla

```bash
$ kubectl -n prod exec -it payments-7d9c8f5b6-x2k4t -c app -- sh -c 'id'
uid=1000(app) gid=1000(app) groups=1000(app)
```

```bash
$ sudo grep -F '"subresource":"exec"' /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "b9f0c1a4-6e7a-4a1a-9b0f-2c3d4e5f6a7b",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/pods/payments-7d9c8f5b6-x2k4t/exec?command=sh&command=-c&command=id&container=app&stdin=true&stdout=true&tty=true",
  "verb": "create",
  "user": {
    "username": "alice@example.com",
    "uid": "8f2c1d90-4b77-4d2e-9a01-77c3f5e1a2b4",
    "groups": [
      "oidc:sre",
      "system:authenticated"
    ]
  },
  "sourceIPs": [
    "10.0.3.44",
    "192.0.2.17"
  ],
  "userAgent": "kubectl/v1.34.0 (linux/amd64) kubernetes/f3a4c19",
  "objectRef": {
    "resource": "pods",
    "namespace": "prod",
    "name": "payments-7d9c8f5b6-x2k4t",
    "apiVersion": "v1",
    "subresource": "exec"
  },
  "responseStatus": {
    "metadata": {},
    "code": 101
  },
  "requestReceivedTimestamp": "2026-08-06T09:14:22.118374Z",
  "stageTimestamp": "2026-08-06T09:14:24.902611Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by RoleBinding \"sre-exec\" of Role \"pod-exec\" to Group \"oidc:sre\"",
    "pod-security.kubernetes.io/enforce-policy": "restricted:latest"
  }
}
```

**Cómo leer este evento, campo por campo:**

| Campo | Significado forense |
|---|---|
| `auditID` | Correlaciona los eventos `ResponseStarted` y `ResponseComplete` de la misma petición. También se devuelve al cliente en la cabecera de respuesta HTTP `Audit-Id`. |
| `stage` | `ResponseComplete` acá — la sesión terminó. Si solo ves `ResponseStarted` para un exec, la sesión sigue abierta o el apiserver murió a mitad del stream. |
| `verb: create` sobre `pods/exec` | `exec` se modela como un **create** sobre un subrecurso, no como un `get`. Las reglas RBAC para exec deben por lo tanto otorgar `create` sobre `pods/exec`. |
| `sourceIPs` | Un **array**: el último elemento es el peer directo, los anteriores vienen de `X-Forwarded-For`. Dos entradas acá significan que la petición atravesó un proxy/LB — `192.0.2.17` es el cliente real. |
| `userAgent` | Huella de las herramientas del atacante. `kubectl/v1.20` en un cluster 1.34, o un `Go-http-client/2.0` pelado, merece una alerta. |
| `responseStatus.code: 101` | HTTP 101 Switching Protocols — upgrade SPDY/WebSocket. Normal para exec/attach/portforward. |
| `annotations["authorization.k8s.io/reason"]` | **El binding exacto que otorgó el acceso.** Esta es la forma más rápida de responder "¿por qué pudieron hacer eso?" sin reproducir RBAC a mano. |
| `stageTimestamp − requestReceivedTimestamp` | Duración de la sesión: 2,78 s. |

### 6.5 Correlacionar una petición del cliente con su evento de auditoría

```bash
$ kubectl get secrets -n prod -v=8 2>&1 | grep -i 'audit-id'
I0806 09:21:07.884213   24118 round_trippers.go:553] Response Headers:
I0806 09:21:07.884261   24118 round_trippers.go:560]     Audit-Id: 4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77
```

```bash
$ sudo jq -c 'select(.auditID=="4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77")' \
    /var/log/kubernetes/audit/audit.log
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"4c1e77b2-9a03-41d5-bc8e-0f3ab5d21e77","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/prod/secrets?limit=500","verb":"list","user":{"username":"alice@example.com","groups":["oidc:sre","system:authenticated"]},"sourceIPs":["10.0.3.44"],"userAgent":"kubectl/v1.34.0 (linux/amd64) kubernetes/f3a4c19","objectRef":{"resource":"secrets","namespace":"prod","apiVersion":"v1"},"responseStatus":{"metadata":{},"code":200},"requestReceivedTimestamp":"2026-08-06T09:21:07.871402Z","stageTimestamp":"2026-08-06T09:21:07.883901Z","annotations":{"authorization.k8s.io/decision":"allow","authorization.k8s.io/reason":"RBAC: allowed by ClusterRoleBinding \"sre-readers\" of ClusterRole \"secret-reader\" to Group \"oidc:sre\""}}
```

Notá el `level: Metadata` — la regla de Tier 1 impidió que los payloads del Secret se escribieran. Eso es la policy haciendo su trabajo.

---

## 7. Recetas de análisis (`jq`) — el manual de detección

Todos los ejemplos asumen `AUDIT=/var/log/kubernetes/audit/audit.log`.

**Todo `exec`/`attach`/`portforward`, con quién y dónde:**

```bash
$ sudo jq -r 'select(.objectRef.subresource | IN("exec","attach","portforward"))
  | select(.stage=="ResponseComplete")
  | [.stageTimestamp, .user.username, .sourceIPs[0], .objectRef.namespace,
     .objectRef.name, .objectRef.subresource] | @tsv' $AUDIT | column -t
2026-08-06T09:14:24.902611Z  alice@example.com                       10.0.3.44  prod     payments-7d9c8f5b6-x2k4t  exec
2026-08-06T09:33:02.114887Z  system:serviceaccount:ci:deployer       10.0.5.12  staging  migrate-job-2xk9d         exec
2026-08-06T10:02:41.559130Z  bob@example.com                         10.0.3.51  prod     redis-0                   portforward
```

**Quiénes leyeron Secrets, rankeados:**

```bash
$ sudo jq -r 'select(.objectRef.resource=="secrets")
  | select(.verb | IN("get","list","watch"))
  | select(.stage=="ResponseComplete")
  | .user.username' $AUDIT | sort | uniq -c | sort -rn | head
   4412 system:kube-controller-manager
    881 system:serviceaccount:kube-system:token-cleaner
    140 system:serviceaccount:argocd:argocd-application-controller
     37 alice@example.com
      6 system:serviceaccount:default:default        <-- investigate
```

Que `system:serviceaccount:default:default` lea Secrets es un indicador fuerte de una carga de trabajo comprometida usando el token por defecto automontado.

**Denegaciones de autorización (intentos fallidos de acceso / reconocimiento):**

```bash
$ sudo jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
  | [.stageTimestamp, .user.username, .verb,
     (.objectRef.resource // .requestURI), (.objectRef.namespace // "-")] | @tsv' \
  $AUDIT | tail -8 | column -t
2026-08-06T10:41:03.220914Z  system:serviceaccount:default:default  list    secrets              kube-system
2026-08-06T10:41:03.418772Z  system:serviceaccount:default:default  create  clusterrolebindings  -
2026-08-06T10:41:03.611305Z  system:serviceaccount:default:default  create  pods/exec            kube-system
2026-08-06T10:41:03.809441Z  system:serviceaccount:default:default  get     nodes/proxy          -
```

Cuatro sondeos de escalada en 600 ms desde una ServiceAccount por defecto: eso es un escáner automatizado de escalada de privilegios (enumeración estilo `kubectl auth can-i --list` o `peirates`/`kubeletmein`). **Las peticiones denegadas son la clase de mayor señal y menor volumen de todo el log — alertá sobre ellas primero.**

**Acceso anónimo y no autenticado:**

```bash
$ sudo jq -r 'select(.user.username=="system:anonymous"
              or (.user.groups // [] | index("system:unauthenticated")))
  | [.stageTimestamp, .sourceIPs[0], .verb, .requestURI, .responseStatus.code] | @tsv' \
  $AUDIT | grep -v '/healthz\|/livez\|/readyz\|/version' | head
2026-08-06T11:07:55.331902Z  198.51.100.9  get  /api/v1/namespaces/kube-system/secrets  403
2026-08-06T11:07:55.702118Z  198.51.100.9  get  /apis                                    200
```

**Impersonation (una vía de escalada legítima pero frecuentemente abusada):**

```bash
$ sudo jq -r 'select(.impersonatedUser != null)
  | [.stageTimestamp, .user.username, "->", .impersonatedUser.username,
     ((.impersonatedUser.groups // []) | join(",")), .verb,
     (.objectRef.resource // "-")] | @tsv' $AUDIT | column -t
2026-08-06T11:22:14.008412Z  ops@example.com  ->  system:serviceaccount:kube-system:clusterrole-aggregation-controller  system:serviceaccounts  create  clusterroles
```

Un humano impersonando una ServiceAccount privilegiada para crear ClusterRoles es exactamente el patrón que la revisión de RBAC pasa por alto y que el audit log captura.

**Escaladas de RBAC con el objeto completo (gracias al `RequestResponse` de Tier 2):**

```bash
$ sudo jq -r 'select(.objectRef.resource=="clusterrolebindings")
  | select(.verb=="create")
  | select(.stage=="ResponseComplete")
  | "\(.stageTimestamp)  \(.user.username)  bound  \(.requestObject.roleRef.name)  to  \(
      [.requestObject.subjects[]? | "\(.kind)/\(.namespace // "-")/\(.name)"] | join(", "))"' \
  $AUDIT
2026-08-06T11:41:07.882301Z  system:serviceaccount:default:default  bound  cluster-admin  to  ServiceAccount/default/default
```

Esa sola línea es el incidente entero.

**Escrituras a workloads en un namespace protegido, excluyendo la identidad de CI esperada:**

```bash
$ sudo jq -r 'select(.objectRef.namespace=="prod")
  | select(.verb | IN("create","update","patch","delete","deletecollection"))
  | select(.user.username != "system:serviceaccount:ci:deployer")
  | select((.user.username | startswith("system:")) | not)
  | [.stageTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name] | @tsv' \
  $AUDIT | column -t
2026-08-06T12:03:19.771204Z  carol@example.com  patch   deployments  payments
2026-08-06T12:05:02.113990Z  carol@example.com  delete  pods         payments-7d9c8f5b6-x2k4t
```

**Uso de APIs deprecadas / removidas antes de un upgrade:**

```bash
$ sudo jq -r 'select(.annotations["k8s.io/deprecated"]=="true")
  | [.userAgent, .objectRef.apiGroup, .objectRef.apiVersion, .objectRef.resource,
     (.annotations["k8s.io/removed-release"] // "-")] | @tsv' $AUDIT \
  | sort | uniq -c | sort -rn
     37  helm/v3.11.0  flowcontrol.apiserver.k8s.io  v1beta3  flowschemas  1.35
      4  legacy-operator/0.9  batch                   v1beta1  cronjobs     1.25
```

**Atribución de latencia del API server (uso SRE de los mismos datos):**

```bash
$ sudo jq -r 'select(.annotations["apiserver.latency.k8s.io/total"] != null)
  | [.verb, (.objectRef.resource // .requestURI),
     .annotations["apiserver.latency.k8s.io/total"],
     (.annotations["apiserver.latency.k8s.io/etcd"] // "-"),
     (.annotations["apiserver.latency.k8s.io/validating-admission-controller"] // "-")] | @tsv' \
  $AUDIT | sort -k3 -r | head -5 | column -t
list    pods                 4.812s  4.611s  1.2ms
create  pods                 1.944s  31ms    1.881s   <-- a slow validating webhook
```

**Los que más hablan, para ajustar la policy:**

```bash
$ sudo jq -r '"\(.user.username)|\(.verb)|\(.objectRef.resource // .requestURI)"' $AUDIT \
  | sort | uniq -c | sort -rn | head -10
  92411 system:kube-controller-manager|watch|leases
  41880 system:serviceaccount:monitoring:prometheus-k8s|list|pods
  17402 system:kubelet|patch|nodes/status
   9911 system:serviceaccount:argocd:argocd-repo-server|list|applications
```

Cada una de esas líneas es candidata a una regla `level: None` — con la advertencia de §5.2 de que cada supresión es un punto ciego deliberado.

**Tailing en tiempo real durante un incidente:**

```bash
$ sudo tail -F /var/log/kubernetes/audit/audit.log \
  | jq -r --unbuffered 'select(.stage=="ResponseComplete")
      | select(.user.username | startswith("system:") | not)
      | "\(.stageTimestamp[11:19])  \(.user.username)  \(.verb)  \(.objectRef.resource // .requestURI)/\(.objectRef.name // "")  [\(.responseStatus.code)]"'
09:41:12  alice@example.com  list    pods/                  [200]
09:41:19  alice@example.com  create  pods/exec/redis-0      [101]
09:41:44  mallory@example.com create clusterrolebindings/x  [403]
```

---

## 8. Verificación y diagnóstico de fallos

### 8.1 El protocolo de verificación de cinco pasos

```bash
# 1. The policy file exists on the HOST and is valid YAML with the right apiVersion.
$ sudo head -3 /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:

# 2. The apiserver Pod is Running and its restart count is stable.
$ kubectl -n kube-system get pod -l component=kube-apiserver -o wide
NAME                   READY   STATUS    RESTARTS      AGE   IP          NODE
kube-apiserver-cp-01   1/1     Running   3 (4m2s ago)  4m2s  10.0.0.10   cp-01

# 3. The flags are present on the running container.
$ kubectl -n kube-system get pod kube-apiserver-cp-01 -o yaml | grep -c -- '--audit'
8

# 4. The policy file is visible INSIDE the container (volumeMount, not just volume).
$ sudo crictl exec -it $(sudo crictl ps -q --name kube-apiserver) \
    ls -l /etc/kubernetes/audit/policy.yaml
-rw------- 1 root root 3187 Aug  6 09:01 /etc/kubernetes/audit/policy.yaml

# 5. The log is growing and contains a signal you just generated.
$ kubectl get secrets -A >/dev/null
$ sudo jq -c 'select(.objectRef.resource=="secrets" and .verb=="list")' \
    /var/log/kubernetes/audit/audit.log | tail -1 | jq -r .user.username
kubernetes-admin
```

### 8.2 Catálogo de fallos

| Síntoma | Línea de log / evidencia representativa | Causa raíz | Solución |
|---|---|---|---|
| El Pod del apiserver nunca aparece; `kubectl` muerto | `crictl ps -a` no muestra nada llamado kube-apiserver | El YAML del static Pod es sintácticamente inválido — el kubelet ni siquiera construye el Pod | `journalctl -u kubelet -n 50` → `failed to parse manifest`; restaurá `/root/kube-apiserver.yaml.bak` |
| CrashLoopBackOff | `Error: loading audit policy file: failed to read file path "/etc/kubernetes/audit/policy.yaml": no such file or directory` | Volumen declarado pero **falta la entrada en `volumeMounts`**, o `mountPath` incorrecto | Agregá la entrada en `volumeMounts`; las dos listas son independientes |
| CrashLoopBackOff | `error converting YAML to JSON: yaml: line 12: did not find expected key` | Error de indentación en la policy | Validá con `python3 -c 'import yaml,...'` antes de reiniciar |
| CrashLoopBackOff | `no kind "Policy" is registered for version "audit.k8s.io/v1beta1"` | `apiVersion` incorrecta (v1alpha1/v1beta1 removidas) | Usá `audit.k8s.io/v1` |
| CrashLoopBackOff | `unknown field "omitManagedField"` / `unknown field "resourceName"` | Error de tipeo en un campo — el decodificador de la policy es estricto | Corregí a `omitManagedFields` / `resourceNames` |
| CrashLoopBackOff | `failed to open audit log "/var/log/kubernetes/audit/audit.log": permission denied` | `readOnly: true` en el `volumeMount` del log, o el directorio no existe y se usó `type: Directory` | `readOnly: false`; usá `type: DirectoryOrCreate` |
| Pod Running, `audit.log` nunca se crea | Ningún error en absoluto | `--audit-policy-file` seteado pero falta `--audit-log-path` (o viceversa) — **ambos son necesarios** para el backend de log | Agregá el flag que falta |
| `audit.log` existe pero está vacío | El tamaño del archivo se mantiene en 0 | Todas las reglas son `level: None`, o ninguna regla coincide (sin catch-all) | Agregá una regla terminal `- level: Metadata` |
| `audit.log` existe pero está vacío | El tamaño del archivo se mantiene en 0 | `--audit-log-mode=batch` con un `batch-max-wait` grande y poco tráfico | Esperá el `batch-max-wait`, o hacé `kubectl get pods` unas cuantas veces |
| El log crece pero tu petición falta | — | Una regla `None` anterior coincidió primero | Releé las reglas de arriba hacia abajo; gana la primera coincidencia |
| El log crece pero tu petición falta | — | Control plane HA: el LB te ruteó a un apiserver distinto | Hacé grep en **todos** los nodos del control plane, o agregá centralmente |
| El log solo tiene `RequestReceived` para un exec | Sin `ResponseComplete` | La sesión sigue abierta, o el apiserver reinició a mitad del stream | Correlacioná por `auditID` a través de los reinicios |
| `/var` al 100 %, cluster degradado | `no space left on device` desde etcd y el apiserver | Catch-all `RequestResponse`, o faltan `maxsize`/`maxbackup` | Seteá los flags de rotación de CIS; ajustá la policy; mové `/var/log/kubernetes` a su propio volumen |
| La latencia p99 de la API saltó 10× tras habilitar auditoría | `apiserver_request_duration_seconds` en alza; `apiserver_audit_error_total` subiendo | Modo `blocking` + disco lento o webhook lento | Cambiá a `--audit-log-mode=batch`; sacá el webhook de la ruta caliente |
| Peticiones fallando con HTTP 500 | `rejected by audit backend` | `blocking-strict` + fallo del backend (fail-closed funcionando como fue diseñado) | Arreglá el backend, o reconsiderá `blocking-strict` |
| Secrets visibles en el SIEM | hacé grep en el índice por `"data":` bajo `requestObject` | Una regla `RequestResponse` coincidió con `secrets` antes que la regla de Tier 1 | Mové la regla Metadata para recursos que portan secretos **por encima** de toda regla `RequestResponse`; después **rotá todo Secret expuesto y purgá el índice** |

### 8.3 Leer errores de arranque del apiserver cuando `kubectl` está caído

El apiserver es justamente lo que rompiste, así que `kubectl logs` no está disponible. Usá el runtime de contenedores y el directorio de logs en disco del kubelet:

```bash
$ sudo crictl ps -a --name kube-apiserver --latest
CONTAINER      IMAGE          CREATED        STATE    NAME             ATTEMPT  POD ID
7d3c11ab9f042  8c9a5f2ed12b4  8 seconds ago  Exited   kube-apiserver   7        e2b1c9a70d443

$ sudo crictl logs 7d3c11ab9f042 2>&1 | tail -6
I0806 09:07:41.118203       1 options.go:221] external host was not specified, using 10.0.0.10
E0806 09:07:41.119884       1 run.go:74] "command failed" err="loading audit policy file: failed to read file path \"/etc/kubernetes/audit/policy.yaml\": open /etc/kubernetes/audit/policy.yaml: no such file or directory"

# Equivalent, without crictl:
$ sudo tail -20 /var/log/pods/kube-system_kube-apiserver-cp-01_*/kube-apiserver/*.log

# And the kubelet's view of why the Pod won't start:
$ sudo journalctl -u kubelet --since "-5 min" --no-pager | grep -i apiserver | tail -10
```

### 8.4 Señales de Prometheus sobre las que alertar

El apiserver expone métricas del subsistema de auditoría en `/metrics`:

```bash
$ kubectl get --raw /metrics | grep -E '^apiserver_audit' | grep -v '^#'
apiserver_audit_event_total 1847233
apiserver_audit_error_total{plugin="log"} 0
apiserver_audit_level_total{level="Metadata"} 1102847
apiserver_audit_level_total{level="Request"} 511209
apiserver_audit_level_total{level="RequestResponse"} 233177
apiserver_audit_requests_rejected_total{plugin="log"} 0
```

Reglas de alerta recomendadas:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-audit
  namespace: monitoring
  labels:
    role: alert-rules
spec:
  groups:
    - name: kubernetes-audit
      rules:
        # The audit trail stopped. This is a security incident, not a monitoring gap:
        # the first thing an attacker with control-plane access does is silence audit.
        - alert: KubeAuditEventsStopped
          expr: sum(rate(apiserver_audit_event_total[10m])) == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No audit events emitted for 10 minutes — audit trail is blind"

        # Backend write failures: events are being lost right now.
        - alert: KubeAuditBackendErrors
          expr: sum(rate(apiserver_audit_error_total[5m])) by (plugin) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Audit backend {{ $labels.plugin }} is dropping events"

        # blocking-strict is rejecting API requests.
        - alert: KubeAuditRequestsRejected
          expr: sum(rate(apiserver_audit_requests_rejected_total[5m])) > 0
          for: 2m
          labels:
            severity: critical

        # Volume explosion — usually a policy change that widened a level.
        - alert: KubeAuditVolumeSpike
          expr: |
            sum(rate(apiserver_audit_event_total[15m]))
              > 3 * sum(rate(apiserver_audit_event_total[15m] offset 1d))
          for: 15m
          labels:
            severity: warning

        # Disk headroom on the control-plane audit volume.
        - alert: KubeAuditDiskPressure
          expr: |
            node_filesystem_avail_bytes{mountpoint="/var/log"}
              / node_filesystem_size_bytes{mountpoint="/var/log"} < 0.15
          for: 10m
          labels:
            severity: warning
```

> **La alerta más importante de esa lista es `KubeAuditEventsStopped`.** Un adversario que pueda editar `/etc/kubernetes/manifests/kube-apiserver.yaml` va a quitar `--audit-log-path` antes de hacer cualquier otra cosa. Detectar la *ausencia* del rastro es el control que sobrevive a eso.

### 8.5 Alineación con el CIS Kubernetes Benchmark

`kube-bench` verifica la configuración de auditoría bajo la sección `kube-apiserver` (los números de control cambian entre versiones del benchmark; los requisitos no):

| Requisito | Flag | Valor exigido por CIS |
|---|---|---|
| Audit log habilitado | `--audit-log-path` | seteado (no vacío) |
| Retención | `--audit-log-maxage` | `>= 30` |
| Cantidad de backups | `--audit-log-maxbackup` | `>= 10` |
| Tamaño de archivo | `--audit-log-maxsize` | `>= 100` (MiB) |
| Policy presente | `--audit-policy-file` | seteado |

```bash
$ kube-bench run --targets master --check 1.2.19,1.2.20,1.2.21,1.2.22 2>/dev/null | head -20
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.19 Ensure that the --audit-log-path argument is set (Automated)
[PASS] 1.2.20 Ensure that the --audit-log-maxage argument is set to 30 or as appropriate (Automated)
[PASS] 1.2.21 Ensure that the --audit-log-maxbackup argument is set to 10 or as appropriate (Automated)
[PASS] 1.2.22 Ensure that the --audit-log-maxsize argument is set to 100 or as appropriate (Automated)

== Summary master ==
4 checks PASS
0 checks FAIL
```

---

## 9. Detección en tiempo real: canalizar eventos de auditoría hacia Falco

El plugin `k8saudit` de Falco consume el stream de auditoría (webhook o archivo) y evalúa reglas en tiempo real, dándote alertado sin un stack ELK.

`/etc/falco/falco.yaml` (extracto):

```yaml
load_plugins: [k8saudit, json]

plugins:
  - name: k8saudit
    library_path: libk8saudit.so
    init_config:
      maxEventSize: 262144
      webhookMaxBatchSize: 12582912
    open_params: "http://:9765/k8s-audit"   # receives the apiserver webhook backend
  - name: json
    library_path: libjson.so

rules_file:
  - /etc/falco/k8s_audit_rules.yaml
  - /etc/falco/rules.d
```

Regla personalizada — alertar sobre cualquier `exec` hacia un namespace etiquetado como regulado:

```yaml
- macro: kevt
  condition: (jevt.value[/stage] in ("ResponseComplete","ResponseStarted"))

- macro: regulated_namespace
  condition: (ka.target.namespace in (prod, payments, pci))

- rule: Exec Into Regulated Namespace Pod
  desc: >
    An interactive session (exec/attach) was opened against a Pod in a
    regulated namespace. All such access must be preceded by an approved
    change ticket.
  condition: >
    kevt and ka.verb=create and
    ka.target.subresource in (exec, attach) and
    regulated_namespace
  output: >
    Interactive session opened in regulated namespace
    (user=%ka.user.name groups=%ka.user.groups ns=%ka.target.namespace
     pod=%ka.target.name sub=%ka.target.subresource
     cmd=%ka.uri.param[command] srcip=%ka.sourceips auditid=%ka.auditid)
  priority: WARNING
  source: k8s_audit
  tags: [k8s, access, pci]

- rule: ClusterRoleBinding To Cluster Admin
  desc: A binding to cluster-admin was created outside the platform pipeline.
  condition: >
    kevt and ka.verb=create and
    ka.target.resource=clusterrolebindings and
    ka.req.binding.role=cluster-admin and
    not ka.user.name in (system:serviceaccount:platform:rbac-operator)
  output: >
    cluster-admin granted (user=%ka.user.name subjects=%ka.req.binding.subjects
     name=%ka.target.name auditid=%ka.auditid)
  priority: CRITICAL
  source: k8s_audit
  tags: [k8s, rbac, escalation]
```

**Compromiso:** Falco te da detección en menos de un segundo pero sin retención ni consulta ad-hoc. El backend de log te da retención y consulta pero sin alertado. Producción corre **ambos**: backend de log → almacenamiento de objetos (retención/cumplimiento), webhook → Falco (detección).

---

## 10. Prácticas para el examen CKS

La pregunta del examen es casi siempre una variante de: *"Habilitá el audit logging en el nodo del control plane con una policy que registre X al nivel Y; conservá 30 días / 10 backups / 100 MB; el log debe estar en `/var/log/kubernetes/audit/audit.log`."*

**Memoria muscular ordenada:**

```bash
# 0. ALWAYS back up first — a broken static Pod costs you the whole cluster.
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# 1. Create the directories.
$ sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit

# 2. Write the policy (apiVersion: audit.k8s.io/v1 — kind: Policy — rules:).
$ sudo vi /etc/kubernetes/audit/policy.yaml

# 3. Edit the static Pod: add 3 things in 3 places.
#    (a) the --audit-* flags under .spec.containers[0].command
#    (b) volumeMounts under .spec.containers[0].volumeMounts
#    (c) volumes under .spec.volumes
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# 4. Wait for the restart and verify.
$ watch -n2 'sudo crictl ps --name kube-apiserver'
$ sudo ls -l /var/log/kubernetes/audit/audit.log
```

**Los cinco errores que cuestan puntos:**

1. Agregar los `volumes` pero olvidar los `volumeMounts` (o viceversa). Tres ediciones, siempre.
2. `readOnly: true` en el montaje del **log** de auditoría.
3. `apiVersion` incorrecta — es `audit.k8s.io/v1`, no `v1beta1`, no `v1`.
4. Olvidar la regla catch-all final, con lo cual el log queda vacío.
5. No esperar lo suficiente. El kubelet necesita hasta ~20 s para notar el archivo, más ~20 s para que el apiserver quede ready. `kubectl` va a fallar durante esa ventana — eso es esperable, no un error.

**Referencia rápida del conjunto de flags que espera el examen:**

```
--audit-policy-file=/etc/kubernetes/audit/policy.yaml
--audit-log-path=/var/log/kubernetes/audit/audit.log
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
```

**Chuleta de subrecursos para reglas de policy:**

| Acción a auditar | `verbs` | `resources[].resources` |
|---|---|---|
| Abrir una shell en un Pod | `create` | `pods/exec` |
| Adjuntarse a un contenedor en ejecución | `create` | `pods/attach` |
| Port-forward | `create` | `pods/portforward` |
| Leer los logs de un Pod | `get` | `pods/log` |
| Agregar un contenedor efímero de depuración | `update`, `patch` | `pods/ephemeralcontainers` |
| Proxy hacia el kubelet de un nodo | `get`, `create` | `nodes/proxy` |
| Emitir un token de ServiceAccount | `create` | `serviceaccounts/token` |
| Borrar una colección entera | `deletecollection` | cualquiera |

---

## 11. Checklist operativo

- [ ] Archivo de policy presente, modo `0600`, propiedad de root, en **cada** nodo del control plane.
- [ ] La policy es **idéntica** en todos los nodos del control plane (drift = evidencia inconsistente).
- [ ] Ninguna regla emite `Request` o `RequestResponse` para `secrets`, `configmaps`, `tokenreviews`, `serviceaccounts/token`, ni `certificatesigningrequests`.
- [ ] `omitStages: ["RequestReceived"]` seteado globalmente.
- [ ] `omitManagedFields: true` seteado globalmente.
- [ ] Existe una regla catch-all terminal.
- [ ] `--audit-log-mode=batch` en clusters de más de ~50 nodos.
- [ ] Los flags de rotación cumplen CIS (`30` / `10` / `100`) y `--audit-log-compress=true`.
- [ ] `/var/log/kubernetes` es un **sistema de archivos separado** del directorio de datos de etcd.
- [ ] Los logs se envían fuera del nodo a almacenamiento inmutable de escritura única en minutos.
- [ ] La retención coincide con el régimen de cumplimiento (PCI-DSS: 1 año, 3 meses en caliente).
- [ ] La alerta `KubeAuditEventsStopped` está cableada y probada deteniendo deliberadamente el backend en staging.
- [ ] El alertado sobre peticiones denegadas (`authorization.k8s.io/decision == "forbid"`) está en su lugar.
- [ ] El archivo de policy en sí está bajo control de versiones y sus cambios son revisados; un PR que agrega una regla `level: None` requiere aprobación de seguridad.
- [ ] El montaje del host del shipper es `readOnly: true` con capabilities mínimas.
- [ ] Un ejercicio trimestral reconstruye una acción conocida de punta a punta a partir de los logs archivados (probá que la cadena de evidencia realmente funciona antes de necesitarla).

---

## 12. Referencias

- Documentación de Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Referencia de la API de Kubernetes — `audit.k8s.io/v1` `Policy` y `Event`: https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Documentación de Kubernetes — referencia de línea de comandos de `kube-apiserver` (todos los flags `--audit-*`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Documentación de Kubernetes — *Auditing with Audit Policy* (niveles, stages, coincidencia de reglas): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Level
- Documentación de Kubernetes — *Options for Highly Available Topology* (localidad del log por apiserver): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- Documentación de Kubernetes — *Customizing components with the kubeadm API* (`extraArgs`, `extraVolumes`): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/
- Referencia de la API de kubeadm — `kubeadm.k8s.io/v1beta4`: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Documentación de Kubernetes — *Static Pods*: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Documentación de Kubernetes — *Kubernetes API Server Bypass Risks* (lo que la auditoría **no** cubre): https://kubernetes.io/docs/concepts/security/api-server-bypass-risks/
- Documentación de Kubernetes — *Deprecated API Migration Guide* (anotación de auditoría `k8s.io/deprecated`): https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- Documentación de Kubernetes — *Pod Security Admission* (anotaciones de auditoría `pod-security.kubernetes.io/*`): https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Documentación de Kubernetes — *Validating Admission Policy* (anotaciones `validation.policy.admission.k8s.io/*`): https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Documentación de Kubernetes — *Using RBAC Authorization* (`authorization.k8s.io/decision` y `reason`): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Documentación de Kubernetes — *System Logs and Metrics*: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Código fuente de Kubernetes — verificador de audit policy y backends: https://github.com/kubernetes/apiserver/tree/master/pkg/audit
- CNCF — CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- `kube-bench` (evaluación CIS automatizada): https://github.com/aquasecurity/kube-bench
- Falco — plugin `k8saudit`: https://github.com/falcosecurity/plugins/tree/master/plugins/k8saudit
- Falco — reglas de auditoría de Kubernetes por defecto: https://github.com/falcosecurity/rules/blob/main/rules/k8s_audit_rules.yaml
- Documentación de Fluent Bit — entrada `tail` y salida `opensearch`: https://docs.fluentbit.io/manual/pipeline/inputs/tail
- NIST SP 800-53 Rev. 5 — familia de controles AU (Audit and Accountability): https://csrc.nist.gov/projects/risk-management/sp800-53-controls/release-search#!/families