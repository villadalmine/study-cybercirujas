# Tema 3.6 — Audit Logging

## 1. Motivación y problema arquitectónico de producción

En un cluster de Kubernetes, el `kube-apiserver` es el **único punto de entrada** a la superficie de control: cada `kubectl apply`, cada reconciliación de un controller, cada `exec` a un Pod, cada lectura de un `Secret` y cada intento de escalada de privilegios pasa por su cadena de handlers (`authentication → authorization → admission → validation → etcd`). Esto lo convierte en el lugar canónico —y prácticamente el único fiable— para responder la pregunta forense fundamental:

> **¿Quién hizo qué, cuándo, desde dónde, sobre qué objeto, y con qué resultado?**

Sin audit logging, un cluster comprometido es una caja negra. Los logs de aplicación no cuentan que un `ServiceAccount` sospechoso listó todos los `Secrets` del namespace `kube-system`; los eventos de Kubernetes (`kubectl get events`) se retienen por defecto solo **1 hora** (`--event-ttl=1h`) y describen el ciclo de vida del cluster, no la intención del actor. El **audit log** es el registro inmutable, estructurado y attribuible que sostiene tres capacidades de producción no negociables:

| Capacidad | Pregunta que responde | Dependencia del audit log |
|---|---|---|
| **Detección (Threat Detection)** | ¿Se está ejecutando un ataque *ahora*? | Streaming en tiempo casi real vía webhook a un motor de detección (Falco, SIEM) |
| **Forense (Incident Response)** | ¿Qué hizo el atacante y qué tocó? | Historial retenido, íntegro y con `auditID` correlacionable |
| **Cumplimiento (Compliance)** | ¿Puedo demostrar control de acceso? | Evidencia auditable para PCI-DSS, SOC 2, HIPAA, CIS Benchmark 3.2 |

### El trade-off arquitectónico central

El audit logging no es gratis. Cada request puede generar hasta 4 eventos (uno por *stage*), y capturar el cuerpo (`Request`/`RequestResponse`) de un `LIST` de miles de objetos genera eventos de megabytes. El diseño obliga a balancear tres tensiones en conflicto directo:

1. **Verbosidad vs. costo** — cuánto capturar (level) determina el volumen de I/O y almacenamiento.
2. **Latencia del API server vs. garantía de entrega** — el *mode* (`blocking` vs `batch`) determina si un backend lento degrada *todo* el plano de control.
3. **Cobertura de seguridad vs. filtración de secretos** — capturar `RequestResponse` sobre `Secrets` graba la data sensible *en claro* dentro del propio audit log, moviendo el problema en vez de resolverlo.

La política de auditoría (`Policy`) es precisamente la herramienta declarativa para resolver estas tensiones regla por regla. El resto del tema es cómo se expresa y opera ese balance.

> Fuente primaria: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/

---

## 2. Anatomía del subsistema de auditoría

### 2.1 Stages (etapas del ciclo de vida de un request)

Cada request atraviesa hasta cuatro etapas; la política decide en cuáles se emite un evento.

| Stage | Momento de emisión | Uso típico |
|---|---|---|
| `RequestReceived` | Apenas el handler recibe el request, antes de procesarlo | Ruido alto; suele omitirse. Detecta intentos aunque fallen luego |
| `ResponseStarted` | Headers de respuesta enviados, antes del body | **Solo** requests long-running (`watch`, `exec`, `port-forward`) |
| `ResponseComplete` | Body de respuesta completado | El evento **más valioso**: contiene el `responseStatus.code` final |
| `Panic` | El API server sufrió un `panic` procesando el request | Fallos internos / posibles exploits |

Un `GET` normal produce `RequestReceived` + `ResponseComplete`. Un `watch` produce `RequestReceived` + `ResponseStarted` + `ResponseComplete` (al cerrarse). Por eso `omitStages: ["RequestReceived"]` recorta ~50 % del volumen sin perder información de resultado.

### 2.2 Levels (niveles de captura) — trade-off de verbosidad

El nivel define **cuánto** del request/response se persiste. Se aplica *por regla*, no globalmente.

| Level | Metadata (user, verb, objectRef, sourceIP, timestamp) | `requestObject` (body enviado) | `responseObject` (body devuelto) | Volumen relativo | Riesgo de secretos |
|---|:---:|:---:|:---:|:---:|:---:|
| `None` | ❌ (evento suprimido) | ❌ | ❌ | 0 | Ninguno |
| `Metadata` | ✅ | ❌ | ❌ | 1× | Bajo |
| `Request` | ✅ | ✅ | ❌ | ~3–10× | **Alto** (graba el body) |
| `RequestResponse` | ✅ | ✅ | ✅ | ~5–20× | **Muy alto** |

**Regla de oro de producción:** `Metadata` como piso universal; `Request`/`RequestResponse` solo sobre recursos donde el *contenido* de la operación importa para la seguridad (por ejemplo, `configmaps` o `rbac`), y **`Metadata` o `None`** sobre `secrets`, `tokenreviews`, `certificatesigningrequests` para no filtrar material sensible al propio log.

### 2.3 Backends — dónde aterrizan los eventos

| Backend | Flag principal | Entrega | Latencia sobre el API server | Caso de uso |
|---|---|---|---|---|
| **Log (file)** | `--audit-log-path` | Escritura local a fichero (JSON por línea) | Muy baja | Retención local, recolección posterior por `Fluentd`/`Vector` |
| **Webhook** | `--audit-webhook-config-file` | HTTP POST a servicio externo | Depende del `mode` | Streaming a SIEM / detección en tiempo real |

> El *dynamic audit backend* (`auditregistration.k8s.io/v1alpha1`, `AuditSink`) fue deprecado en v1.19 y **eliminado**. No aparece en clusters modernos; configurarlo dinámicamente sin reiniciar el API server ya no es posible. La configuración es **estática** y requiere reiniciar el `kube-apiserver`.

### 2.4 Modes — trade-off latencia vs. entrega

Aplica a ambos backends (`--audit-log-mode`, `--audit-webhook-mode`):

| Mode | Comportamiento | Riesgo | Cuándo usar |
|---|---|---|---|
| `blocking` | El API server espera a que cada evento se escriba/envíe | Un backend lento **añade latencia a cada request de la API** | Nunca en webhook sobre red |
| `blocking-strict` | Como `blocking`, pero si falla la escritura en `RequestReceived`, **el request del cliente se rechaza** | Máxima integridad; un backend caído puede **tumbar el cluster** | Entornos regulados que exigen "no acción sin auditoría" |
| `batch` | Buffer en memoria, envío por lotes asíncrono | Puede **perder eventos** si el proceso muere con buffer lleno | Default y recomendado para webhook |

El default del webhook es `batch`; el del log file es `blocking`. La pérdida potencial de eventos en `batch` es el precio por desacoplar la latencia del plano de control de la salud del backend de auditoría.

---

## 3. Manifiestos completos de producción

### 3.1 Política de auditoría estratificada (`/etc/kubernetes/audit-policy.yaml`)

Política real de producción: minimiza ruido, protege secretos, captura RBAC completo y da máxima verbosidad a las operaciones de mayor riesgo.

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Nunca registrar la etapa RequestReceived: reduce ~50% del volumen sin perder
# el resultado final (que llega en ResponseComplete).
omitStages:
  - "RequestReceived"
# No inflar los eventos con managedFields (metadata de server-side apply).
omitManagedFields: true
rules:
  # 1) Secrets, ConfigMaps y tokens: SOLO metadata. Nunca el body, para no
  #    grabar material sensible en claro dentro del propio audit log.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 2) Cambios de RBAC: RequestResponse completo. Un cambio de permisos es
  #    el evento de escalada de privilegios por excelencia.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources:
          ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 3) exec, attach, port-forward: RequestResponse. Acceso interactivo a Pods
  #    = principal vector de intrusión y de exfiltración.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 4) Silenciar ruido de alto volumen y bajo valor de los componentes del
  #    sistema (health checks, leases del controller-manager/scheduler).
  - level: None
    users: ["system:kube-controller-manager", "system:kube-scheduler"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # 5) No auditar endpoints no-recurso de solo lectura (health, metrics, version).
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"
      - "/swagger*"

  # 6) Escrituras (create/update/patch/delete) sobre cualquier recurso:
  #    Request (body enviado), para reconstruir el "qué" del cambio.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "" # core
      - group: "apps"
      - group: "batch"
      - group: "networking.k8s.io"
      - group: "policy"
      - group: "admissionregistration.k8s.io"

  # 7) Regla de cierre (catch-all): todo lo demás, al menos Metadata.
  #    Sin esto, cualquier request no cubierto arriba NO se auditaría.
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

**Semántica crítica de evaluación:** las reglas se recorren **de arriba hacia abajo y la primera que matchea gana** (fija el level y no se sigue evaluando). Por eso el orden importa: la protección de `secrets` (regla 1) debe ir *antes* que la regla de escrituras (regla 6), o un `update` a un secret caería en `Request` y grabaría el body. La regla catch-all al final es obligatoria: sin ella, un request que no matchea ninguna regla obtiene level `None` implícito y desaparece del log.

### 3.2 Backend webhook (`/etc/kubernetes/audit-webhook.yaml`)

Formato `kubeconfig`: el `cluster` es el receptor de eventos (SIEM/Falco); el `context` `current-context` es obligatorio.

```yaml
# /etc/kubernetes/audit-webhook.yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      # Endpoint del colector (por ejemplo Falco, Fluentd, o un servicio SIEM).
      server: https://audit-collector.security.svc.cluster.local:8443/audit
      certificate-authority: /etc/kubernetes/pki/audit-ca.crt
contexts:
  - name: audit-sink-context
    context:
      cluster: audit-sink
      user: apiserver-audit-client
current-context: audit-sink-context
users:
  - name: apiserver-audit-client
    user:
      client-certificate: /etc/kubernetes/pki/audit-client.crt
      client-key: /etc/kubernetes/pki/audit-client.key
```

### 3.3 Integración con el static Pod del API server (kubeadm)

En un cluster kubeadm, el `kube-apiserver` corre como **static Pod**. Los ficheros de política y webhook deben montarse como `hostPath` porque el API server no puede leer objetos del cluster para arrancar (problema del huevo y la gallina). Se edita `/etc/kubernetes/manifests/kube-apiserver.yaml`; kubelet detecta el cambio y recrea el Pod.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (fragmentos relevantes)
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        # --- Backend de log a fichero ---
        - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30      # días de retención por fichero
        - --audit-log-maxbackup=10   # nº de ficheros rotados a conservar
        - --audit-log-maxsize=100    # MB antes de rotar
        - --audit-log-mode=batch
        # --- Backend webhook (streaming a SIEM) ---
        - --audit-webhook-config-file=/etc/kubernetes/audit-webhook.yaml
        - --audit-webhook-mode=batch
        - --audit-webhook-batch-max-size=400
        - --audit-webhook-batch-max-wait=5s
        - --audit-webhook-batch-throttle-qps=10
        - --audit-webhook-batch-throttle-burst=15
        - --audit-webhook-initial-backoff=10s
        # ... (resto de flags existentes) ...
      volumeMounts:
        - name: audit-policy
          mountPath: /etc/kubernetes/audit-policy.yaml
          readOnly: true
        - name: audit-webhook
          mountPath: /etc/kubernetes/audit-webhook.yaml
          readOnly: true
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
          readOnly: false   # el API server ESCRIBE aquí; no puede ser readOnly
  volumes:
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit-policy.yaml
        type: File
    - name: audit-webhook
      hostPath:
        path: /etc/kubernetes/audit-webhook.yaml
        type: File
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

**Errores frecuentes de montaje:**
- Montar el directorio de logs como `readOnly: true` → el API server no arranca (no puede escribir `audit.log`).
- Usar `type: File` sobre un path que aún no existe → kubelet no crea el Pod. La política debe existir *antes* de guardar el manifiesto.
- Olvidar el volumen del log path pero sí pasar `--audit-log-path` → el evento se escribiría dentro del contenedor efímero y se perdería al reiniciarse.

### 3.4 Estructura de un evento de auditoría (salida real)

Un evento `audit.k8s.io/v1` en el log, tras un `kubectl get secret db-credentials`:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "07ac3d2e-9d1e-4c6b-8f2a-1b7e5c9d4a11",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/production/secrets/db-credentials",
  "verb": "get",
  "user": {
    "username": "dev-alice",
    "groups": ["developers", "system:authenticated"]
  },
  "sourceIPs": ["10.0.4.17"],
  "userAgent": "kubectl/v1.31.0 (linux/amd64)",
  "objectRef": {
    "resource": "secrets",
    "namespace": "production",
    "name": "db-credentials",
    "apiVersion": "v1"
  },
  "responseStatus": { "metadata": {}, "code": 200 },
  "requestReceivedTimestamp": "2026-08-07T14:22:07.115332Z",
  "stageTimestamp": "2026-08-07T14:22:07.119874Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by RoleBinding \"dev-secrets-read/production\" of Role \"secret-reader\" to User \"dev-alice\""
  }
}
```

Los campos de mayor valor forense: `user.username`, `sourceIPs`, `objectRef` (qué objeto), `responseStatus.code`, y sobre todo la annotation **`authorization.k8s.io/decision`** (`allow`/`forbid`) con su `reason`, que muestra *qué regla RBAC* concedió o denegó el acceso — oro puro para investigar escaladas de privilegios.

---

## 4. Comandos CLI, verificación y diagnóstico

### 4.1 Confirmar que el audit logging está activo

```console
$ sudo grep -E 'audit-policy-file|audit-log-path|audit-webhook' /etc/kubernetes/manifests/kube-apiserver.yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-webhook-config-file=/etc/kubernetes/audit-webhook.yaml

$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep audit
"--audit-policy-file=/etc/kubernetes/audit-policy.yaml"
"--audit-log-path=/var/log/kubernetes/audit/audit.log"
"--audit-log-mode=batch"
```

### 4.2 Verificar que el API server reinició sano tras el cambio

```console
$ kubectl -n kube-system get pods -l component=kube-apiserver
NAME                    READY   STATUS    RESTARTS      AGE
kube-apiserver-cp-01    1/1     Running   1 (42s ago)   42s

$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT
a1b2c3d4e5f6   f6a8...        48 seconds ago  Running   kube-apiserver   1
```

Un `RESTARTS` que sigue subiendo o un Pod en `CrashLoopBackOff` casi siempre significa política YAML inválida o path de montaje incorrecto (ver §4.5).

### 4.3 Explorar el log crudo con `jq`

```console
$ sudo tail -n 1 /var/log/kubernetes/audit/audit.log | jq '{user:.user.username, verb, res:.objectRef.resource, code:.responseStatus.code}'
{
  "user": "dev-alice",
  "verb": "get",
  "res": "secrets",
  "code": 200
}
```

**Caza de amenazas — accesos denегados por RBAC (posibles intentos de escalada):**

```console
$ sudo jq -c 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
    | {t:.stageTimestamp, user:.user.username, ip:.sourceIPs[0], verb, uri:.requestURI}' \
    /var/log/kubernetes/audit/audit.log
{"t":"2026-08-07T14:31:02.7Z","user":"svc-ci","ip":"10.0.9.33","verb":"list","uri":"/api/v1/secrets"}
{"t":"2026-08-07T14:31:03.1Z","user":"svc-ci","ip":"10.0.9.33","verb":"create","uri":"/apis/rbac.authorization.k8s.io/v1/clusterrolebindings"}
```

Ese patrón —un `ServiceAccount` de CI intentando listar todos los secrets y crear un `ClusterRoleBinding`, ambos denegados— es la firma clásica de un pod comprometido probando escalada.

**Quién accedió a un `Secret` concreto (forense de exfiltración):**

```console
$ sudo jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="db-credentials")
    | {t:.stageTimestamp, user:.user.username, verb, ip:.sourceIPs[0]}' \
    /var/log/kubernetes/audit/audit.log
{"t":"2026-08-07T14:22:07.1Z","user":"dev-alice","verb":"get","ip":"10.0.4.17"}
{"t":"2026-08-07T15:47:55.9Z","user":"system:serviceaccount:default:web","verb":"get","ip":"10.0.4.88"}
```

### 4.4 Validar la política *antes* de aplicarla (evita el CrashLoop)

No hay un `--dry-run` nativo para la política, pero se valida el YAML y su schema con `kubectl`:

```console
$ kubectl create --dry-run=client -f /etc/kubernetes/audit-policy.yaml -o yaml >/dev/null && echo OK
error: unable to recognize "audit-policy.yaml": no matches for kind "Policy" in version "audit.k8s.io/v1"
```

> El `Policy` de auditoría **no** es un recurso del API (no vive en etcd), por lo que `kubectl create` no lo reconoce — eso es esperado. La validación real es sintáctica:

```console
$ python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1])); print("YAML válido")' /etc/kubernetes/audit-policy.yaml
YAML válido
```

Y la validación semántica definitiva es observar el arranque del API server en un nodo de staging antes de tocar producción.

### 4.5 Diagnóstico de fallas comunes

| Síntoma | Causa raíz probable | Verificación / arreglo |
|---|---|---|
| `kube-apiserver` en `CrashLoopBackOff` tras el cambio | Política con schema inválido (`apiVersion`/`kind`/`level` mal escrito) | `sudo crictl logs <id>` → `failed to read audit policy` / `invalid audit level` |
| API server no arranca, sin logs útiles | `hostPath` con `type: File` sobre path inexistente | Crear el fichero de política *antes* de guardar el manifiesto |
| `audit.log` vacío pese a tráfico | Falta la regla catch-all; todo cae en `None` implícito | Añadir la regla final `level: Metadata` |
| Latencia alta en *toda* la API | Webhook en `mode: blocking` con backend lento/caído | Cambiar a `--audit-webhook-mode=batch` |
| Pérdida de eventos bajo carga | Buffer de batch pequeño; throttle bajo | Subir `--audit-webhook-batch-max-size` y `--audit-webhook-batch-throttle-qps` |
| Secretos en claro dentro del log | Regla `Request`/`RequestResponse` matchea `secrets` antes que la de protección | Reordenar: regla de `secrets → Metadata` *arriba* de la de escrituras |
| Disco del nodo lleno | `--audit-log-maxsize`/`maxbackup`/`maxage` sin fijar | Definir rotación; recolectar y expulsar con Fluentd/Vector |

**Leer el error de arranque cuando el Pod no existe todavía en la API:**

```console
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      STATE      NAME             ATTEMPT
9f8e7d6c5b4a   Exited     kube-apiserver   3

$ sudo crictl logs 9f8e7d6c5b4a 2>&1 | tail -3
E0807 15:02:11.442  Error: unknown audit level "MetaData"
F0807 15:02:11.442  error while parsing audit policy file: invalid policy at rules[0]
```

(El level es `Metadata`, no `MetaData`: los valores son case-sensitive.)

### 4.6 Auditoría en clusters gestionados (managed control plane)

En EKS/GKE/AKS **no** se editan flags del API server; el proveedor gestiona el plano de control y expone la auditoría vía su plataforma de logging:

| Proveedor | Habilitación | Destino |
|---|---|---|
| **Amazon EKS** | Control plane logging, tipo `audit` | CloudWatch Logs (`/aws/eks/<cluster>/cluster`) |
| **Google GKE** | Cloud Audit Logs (Admin Activity siempre on; Data Access opt-in) | Cloud Logging |
| **Azure AKS** | Diagnostic settings, categorías `kube-audit` / `kube-audit-admin` | Log Analytics / Event Hub |

```console
$ aws eks update-cluster-config --name prod-cluster \
    --logging '{"clusterLogging":[{"types":["audit","authenticator"],"enabled":true}]}'
{
    "update": { "id": "b1e...", "status": "InProgress", "type": "LoggingUpdate" }
}
```

`kube-audit-admin` en AKS es un subconjunto que **excluye los verbos de solo lectura** (`get`/`list`/`watch`), reduciendo drásticamente el volumen y el costo cuando solo interesan las mutaciones — el equivalente gestionado a filtrar por `verbs` en la `Policy`.

---

## 5. Modelo de amenaza y buenas prácticas (relevancia KCSA)

- **El audit log es un objetivo del atacante.** Un intruso con acceso al nodo del control plane borrará o alterará `/var/log/kubernetes/audit/`. Mitigación: **shipping inmediato** vía webhook/agent a un almacén *fuera* del cluster (SIEM, bucket con object-lock/WORM). Un log solo en el nodo comprometido no es evidencia confiable.
- **Integridad y no repudio:** conservar los `auditID` permite correlacionar los eventos de un mismo request; almacenamiento inmutable (append-only) sostiene el valor legal/forense.
- **No filtrar secretos:** `secrets`, `tokenreviews`, `serviceaccounts/token` y CSRs nunca en level `Request`/`RequestResponse`. El CIS Kubernetes Benchmark (control 3.2) exige política mínima y verifica precisamente estas exclusiones.
- **Detección accionable:** las annotations `authorization.k8s.io/decision: forbid` en ráfaga desde una misma `sourceIP`/`ServiceAccount` son la señal temprana de reconocimiento y escalada; alertar sobre ese patrón.
- **`system:anonymous` / `system:unauthenticated`** en cualquier evento con `code: 200` es una anomalía grave: acceso no autenticado concedido.
- **Costo bajo control:** `Metadata` como piso, `omitStages: ["RequestReceived"]`, silenciar leases/health de componentes del sistema y aplicar rotación. La verbosidad indiscriminada satura disco y presupuesto de SIEM sin aumentar la cobertura real.

---

## 6. Referencias

- Kubernetes — Auditing (documentación oficial del subsistema, políticas, backends y flags): https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes API Reference — `audit.k8s.io/v1` `Policy` y `Event` (schema completo de campos): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes — `kube-apiserver` command-line reference (todos los flags `--audit-*`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- CNCF — KCSA Curriculum (dominio y objetivos del examen): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- CIS Kubernetes Benchmark — control 3.2 "Logging" (política mínima de auditoría): https://www.cisecurity.org/benchmark/kubernetes
- Amazon EKS — Control plane logging: https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
- Google GKE — Cloud Audit Logs: https://cloud.google.com/kubernetes-engine/docs/how-to/audit-logging
- Azure AKS — Monitor control plane / `kube-audit` logs: https://learn.microsoft.com/en-us/azure/aks/monitor-aks