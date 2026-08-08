# Ejercicios guiados — Tema 3.6: Audit Logging (KCSA)

El *audit log* del `kube-apiserver` es la única fuente de verdad sobre **quién** hizo **qué**, **cuándo**, **desde dónde** y con **qué resultado** contra la API de Kubernetes. Es un control de detección (no de prevención): no bloquea nada, pero es la evidencia forense que necesitás para investigar un incidente, detectar accesos anónimos, escaladas de privilegio o lectura de `Secrets`.

En estos ejercicios vas a **habilitar** el auditing desde cero editando el static pod del `kube-apiserver`, vas a **modelar políticas** por nivel y etapa, y vas a **analizar** los eventos JSON para responder preguntas de seguridad reales.

> **Requisitos**
> - Un cluster con acceso al nodo del control-plane. La forma más reproducible en un portátil es `kind`:
>   ```bash
>   kind create cluster --name kcsa-audit
>   docker exec -it kcsa-audit-control-plane bash   # te deja dentro del nodo, como si hicieras SSH a un control-plane de kubeadm
>   ```
>   En un cluster de `kubeadm` real, hacés SSH al nodo del control-plane. Todo lo que sigue asume que estás **dentro del nodo** salvo cuando se indique `# (desde tu host / kubectl)`.
> - `jq` instalado para el análisis de logs (`apt-get update && apt-get install -y jq` dentro del nodo de kind).

---

## Ejercicio 1 — Habilitar el audit backend de log

**Objetivo:** entender el flujo `request → audit handler → policy → backend` habilitando la política más simple posible (registrar todo a nivel `Metadata`) y verificando que el `kube-apiserver` la respeta.

1. Dentro del nodo del control-plane, creá el directorio de la política y el de los logs:

   ```bash
   mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
   ```

2. Escribí una política mínima que registre **todo** a nivel `Metadata`:

   ```bash
   cat > /etc/kubernetes/audit/policy.yaml <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   rules:
     - level: Metadata
   EOF
   ```

3. Editá el static pod del apiserver. `kubelet` vigila `/etc/kubernetes/manifests/` y **recrea el Pod** al detectar cualquier cambio en el archivo:

   ```bash
   vi /etc/kubernetes/manifests/kube-apiserver.yaml
   ```

   Agregá estos flags a la lista `command:` (bajo `- kube-apiserver`):

   ```yaml
       - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
       - --audit-log-path=/var/log/kubernetes/audit/audit.log
       - --audit-log-maxage=7
       - --audit-log-maxbackup=3
       - --audit-log-maxsize=50
       - --audit-log-format=json
   ```

4. En el **mismo archivo**, montá la política y el directorio de logs dentro del contenedor del apiserver. Agregá a `volumeMounts:`:

   ```yaml
       - mountPath: /etc/kubernetes/audit/policy.yaml
         name: audit-policy
         readOnly: true
       - mountPath: /var/log/kubernetes/audit/
         name: audit-logs
         readOnly: false
   ```

   Y a `volumes:` (al final del manifiesto):

   ```yaml
     - name: audit-policy
       hostPath:
         path: /etc/kubernetes/audit/policy.yaml
         type: File
     - name: audit-logs
       hostPath:
         path: /var/log/kubernetes/audit/
         type: DirectoryOrCreate
   ```

5. Guardá y salí. Observá cómo el apiserver se recrea (puede tardar 20–60 s y devolver errores de conexión transitorios):

   ```bash
   crictl ps | grep kube-apiserver      # dentro del nodo
   # (desde tu host / kubectl):
   kubectl -n kube-system get pod -l component=kube-apiserver -w
   ```

6. Generá tráfico y mirá el log crudo:

   ```bash
   # (desde tu host / kubectl):
   kubectl get pods -A
   kubectl get secrets -n default

   # dentro del nodo:
   tail -n 3 /var/log/kubernetes/audit/audit.log | jq .
   ```

   Deberías ver eventos como:

   ```json
   {
     "kind": "Event",
     "apiVersion": "audit.k8s.io/v1",
     "level": "Metadata",
     "auditID": "07ff64df-b5f3-4d1e-9b8a-6a1f2c3d4e5f",
     "stage": "ResponseComplete",
     "requestURI": "/api/v1/namespaces/default/secrets?limit=500",
     "verb": "list",
     "user": {
       "username": "kubernetes-admin",
       "groups": ["system:masters", "system:authenticated"]
     },
     "sourceIPs": ["172.18.0.1"],
     "userAgent": "kubectl/v1.29.0 (linux/amd64) kubernetes/...",
     "objectRef": { "resource": "secrets", "namespace": "default", "apiVersion": "v1" },
     "responseStatus": { "metadata": {}, "code": 200 },
     "requestReceivedTimestamp": "2026-08-07T12:00:00.123456Z",
     "stageTimestamp": "2026-08-07T12:00:00.130000Z",
     "annotations": {
       "authorization.k8s.io/decision": "allow",
       "authorization.k8s.io/reason": ""
     }
   }
   ```

**Preguntas de comprensión**

1. ¿Qué componente del control-plane genera los eventos de auditoría? ¿Por qué ningún otro componente (kubelet, controller-manager, scheduler) los produce?
2. ¿Por qué habilitar el auditing requiere `volumeMounts`/`volumes` de tipo `hostPath` y no basta con agregar los flags?
3. Con la política de este ejercicio (`level: Metadata` sin más), acabás de listar `Secrets`. ¿El **contenido** de los secrets quedó escrito en el log? ¿Por qué sí o por qué no?
4. Si escribís un flag mal (p. ej. una ruta de política inexistente) el apiserver no vuelve a arrancar y perdés `kubectl`. ¿Dónde mirarías para diagnosticarlo, dado que el Pod ni siquiera aparece?

---

## Ejercicio 2 — Niveles y etapas: modelar una política real

**Objetivo:** dominar los cuatro **levels** (`None`, `Metadata`, `Request`, `RequestResponse`) y las cuatro **stages** (`RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`), y entender que las reglas se evalúan **de arriba hacia abajo, primera coincidencia gana**.

1. Reemplazá la política por una diferenciada por recurso y por usuario:

   ```bash
   cat > /etc/kubernetes/audit/policy.yaml <<'EOF'
   apiVersion: audit.k8s.io/v1
   kind: Policy
   # No emitir el evento de la etapa RequestReceived en ninguna regla:
   omitStages:
     - "RequestReceived"
   rules:
     # 1) NUNCA registrar los health/version anónimos ni el ruido de kube-proxy
     - level: None
       users: ["system:kube-proxy"]
       verbs: ["watch"]
       resources:
         - group: ""
           resources: ["endpoints", "services"]
     - level: None
       userGroups: ["system:authenticated"]
       nonResourceURLs: ["/healthz*", "/version", "/metrics"]

     # 2) Cambios sobre RBAC: cuerpo completo de request y response
     - level: RequestResponse
       resources:
         - group: "rbac.authorization.k8s.io"
           resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

     # 3) Secrets y ConfigMaps: SOLO metadata (nunca el cuerpo)
     - level: Metadata
       resources:
         - group: ""
           resources: ["secrets", "configmaps"]

     # 4) Todo lo demás sobre pods/deployments: nivel Request
     - level: Request
       resources:
         - group: ""
           resources: ["pods"]
         - group: "apps"
           resources: ["deployments"]

     # 5) Catch-all
     - level: Metadata
   EOF
   ```

2. Forzá la recarga (tocar el manifiesto reinicia el Pod; o cambiá un espacio y volvé a guardar):

   ```bash
   touch /etc/kubernetes/manifests/kube-apiserver.yaml
   # esperá a que el apiserver vuelva a estar Ready
   ```

3. Generá acciones que peguen contra distintas reglas:

   ```bash
   # (desde tu host / kubectl):
   kubectl create clusterrole audit-demo --verb=get --resource=pods         # regla 2 -> RequestResponse
   kubectl get secret -n kube-system                                        # regla 3 -> Metadata
   kubectl run nginx --image=nginx                                          # regla 4 -> Request
   ```

4. Comprobá el nivel efectivo de cada uno:

   ```bash
   # dentro del nodo:
   grep clusterroles /var/log/kubernetes/audit/audit.log | jq 'select(.verb=="create") | {level, verb, resource: .objectRef.resource, hasRequestObject: (.requestObject!=null), hasResponseObject: (.responseObject!=null)}'
   ```

   Esperado para el `clusterrole`:

   ```json
   { "level": "RequestResponse", "verb": "create", "resource": "clusterroles", "hasRequestObject": true, "hasResponseObject": true }
   ```

5. Confirmá que la etapa `RequestReceived` **no** aparece nunca (por `omitStages`) y que las requests normales terminan en `ResponseComplete`:

   ```bash
   jq -r '.stage' /var/log/kubernetes/audit/audit.log | sort | uniq -c
   ```

**Preguntas de comprensión**

1. Ordená los cuatro niveles de menor a mayor verbosidad e indicá exactamente qué agrega cada uno respecto del anterior (`None` → `Metadata` → `Request` → `RequestResponse`).
2. En la política de arriba, ¿por qué la regla `RequestResponse` para RBAC (regla 2) está **antes** del catch-all (regla 5)? ¿Qué pasaría si estuvieran en orden inverso?
3. ¿Por qué se decidió mantener `Secrets` y `ConfigMaps` en `Metadata` y **no** en `Request`/`RequestResponse`? ¿Qué riesgo de seguridad introduce subirles el nivel?
4. Nombrá las cuatro stages. ¿Para qué tipo de request se emite `ResponseStarted` y por qué normalmente se omite `RequestReceived`?
5. Un `verb: "watch"` sobre pods, ¿en qué stage(s) genera evento? ¿Por qué un `get` puntual solo produce `ResponseComplete`?

---

## Ejercicio 3 — Análisis del log: cazar eventos relevantes para seguridad

**Objetivo:** usar el audit log como herramienta forense. Vas a detectar acceso anónimo, lectura de secrets, `exec` a Pods y peticiones denegadas.

1. Simulá un **acceso anónimo** al apiserver (sin credenciales). Necesitás la IP del apiserver:

   ```bash
   # (desde tu host / kubectl):
   APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   curl -k $APISERVER/api/v1/namespaces/default/pods       # 403 Forbidden esperado
   ```

2. Buscá ese acceso anónimo en el log. El indicador clave es el usuario `system:anonymous` / grupo `system:unauthenticated`:

   ```bash
   # dentro del nodo:
   jq 'select(.user.username=="system:anonymous")
       | {ts: .stageTimestamp, ip: .sourceIPs[0], uri: .requestURI, code: .responseStatus.code, decision: .annotations["authorization.k8s.io/decision"]}' \
       /var/log/kubernetes/audit/audit.log
   ```

   Esperado:

   ```json
   { "ts": "2026-08-07T12:10:00Z", "ip": "172.18.0.1", "uri": "/api/v1/namespaces/default/pods", "code": 403, "decision": "forbid" }
   ```

3. Buscá **toda lectura de secrets** por cualquier usuario (patrón típico de exfiltración post-compromiso):

   ```bash
   jq 'select(.objectRef.resource=="secrets" and (.verb=="get" or .verb=="list" or .verb=="watch"))
       | {ts: .stageTimestamp, user: .user.username, verb, ns: .objectRef.namespace, name: (.objectRef.name // "*")}' \
       /var/log/kubernetes/audit/audit.log
   ```

4. Detectá `kubectl exec` a un Pod (acceso interactivo a un contenedor). La marca es la **subresource** `exec`:

   ```bash
   # (desde tu host / kubectl):
   kubectl exec -it nginx -- id

   # dentro del nodo:
   jq 'select(.objectRef.subresource=="exec")
       | {ts: .stageTimestamp, user: .user.username, pod: .objectRef.name, ns: .objectRef.namespace, uri: .requestURI}' \
       /var/log/kubernetes/audit/audit.log
   ```

5. Listá todas las peticiones **denegadas por autorización** (útil para detectar reconocimiento / fuerza bruta de permisos):

   ```bash
   jq -r 'select(.annotations["authorization.k8s.io/decision"]=="forbid")
          | [.stageTimestamp, .user.username, .verb, (.objectRef.resource // "-"), .responseStatus.code] | @tsv' \
       /var/log/kubernetes/audit/audit.log
   ```

**Preguntas de comprensión**

1. ¿Qué dos campos, tomados juntos, identifican de forma inequívoca un acceso **anónimo** en un evento de auditoría?
2. La anotación `authorization.k8s.io/decision` puede valer `allow` o `forbid`. ¿Por qué esta anotación es más fiable que mirar solo `responseStatus.code` para saber si una petición fue *autorizada*? (Pista: una petición autorizada puede fallar por otras razones.)
3. Un atacante lee un `Secret` con permisos legítimos robados. Con la política del Ejercicio 2 (secrets en `Metadata`), ¿qué **sí** vas a poder afirmar desde el log y qué **no**?
4. ¿Cómo distinguís en el log un `kubectl exec` de un `kubectl get pod`? Nombrá el campo exacto.
5. Si el log muestra decenas de eventos `forbid` del mismo `sourceIP` probando verbos y recursos distintos en segundos, ¿qué patrón de ataque sugiere?

---

## Ejercicio 4 — Backend webhook: enviar los eventos fuera del nodo

**Objetivo:** entender por qué un log en el disco del control-plane no alcanza, y configurar el **webhook backend** para reenviar los eventos a un colector externo (SIEM / stack de logging). También vas a distinguir los modos de entrega.

1. El webhook se configura con un archivo en **formato kubeconfig** que apunta al colector. Crealo:

   ```bash
   cat > /etc/kubernetes/audit/audit-webhook.yaml <<'EOF'
   apiVersion: v1
   kind: Config
   clusters:
     - name: audit-sink
       cluster:
         server: https://audit-sink.monitoring.svc:443/events
         certificate-authority: /etc/kubernetes/audit/sink-ca.crt
   contexts:
     - name: audit-sink-context
       context:
         cluster: audit-sink
         user: apiserver
   current-context: audit-sink-context
   users:
     - name: apiserver
       user:
         client-certificate: /etc/kubernetes/audit/apiserver.crt
         client-key: /etc/kubernetes/audit/apiserver.key
   EOF
   ```

2. En el static pod del apiserver, agregá los flags del webhook (podés convivir con el backend de log del Ejercicio 1: los backends **no** son excluyentes):

   ```yaml
       - --audit-webhook-config-file=/etc/kubernetes/audit/audit-webhook.yaml
       - --audit-webhook-mode=batch
       - --audit-webhook-batch-max-size=400
       - --audit-webhook-batch-max-wait=5s
       - --audit-webhook-initial-backoff=10s
   ```

   > No olvides montar `audit-webhook.yaml` (y los certs) con `volumeMounts`/`volumes`, igual que la política. Si el colector no existe en tu lab, el apiserver arranca igual pero reintentará el envío con backoff; verás los reintentos en `crictl logs` del apiserver.

3. Compará conceptualmente los modos con el flag `--audit-webhook-mode`:

   | Modo | Comportamiento | Trade-off |
   |---|---|---|
   | `batch` | Acumula eventos y los envía en lotes de forma asíncrona | Máximo rendimiento; puede **perder** eventos si el apiserver muere con el buffer lleno |
   | `blocking` | Bloquea cada request de la API hasta enviar su evento | Menor pérdida; la latencia/caída del colector **degrada** la API |
   | `blocking-strict` | Como `blocking`, pero si falla el envío en la etapa `RequestReceived`, la request **se rechaza** | Máxima garantía de captura; el colector caído puede **frenar el cluster** |

**Preguntas de comprensión**

1. ¿Por qué guardar el audit log únicamente en el disco del nodo del control-plane es insuficiente desde el punto de vista de *integridad de la evidencia*? (Pensá en un atacante que ya obtuvo root en ese nodo.)
2. Explicá el trade-off central entre `batch` y `blocking-strict`. ¿En qué escenario de compliance elegirías `blocking-strict` a pesar del riesgo?
3. El backend de log y el backend webhook, ¿son mutuamente excluyentes o pueden coexistir? ¿Comparten la **misma** política de auditoría?
4. El *dynamic auditing* con el objeto `AuditSink` (`auditregistration.k8s.io`) permitía configurar backends webhook en caliente vía la API. ¿Sigue disponible? ¿Qué implica eso para cómo debés versionar y desplegar tu política?

---

## Ejercicio 5 — Endurecer la política: ruido, fuga de datos y rotación

**Objetivo:** convertir una política ingenua en una de producción: reducir volumen sin perder señal, evitar que el propio log filtre datos sensibles, y proteger/rotar el archivo.

1. Medí el **ruido**. Con la política catch-all `Metadata`, los componentes del sistema generan la mayoría de los eventos:

   ```bash
   # dentro del nodo:
   jq -r '.user.username' /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
   ```

   Vas a ver `system:apiserver`, `system:kube-scheduler`, `system:kube-controller-manager` y `system:serviceaccount:kube-system:*` dominando. Filtralos con reglas `level: None` **al principio** de la política (como en el Ejercicio 2).

2. Verificá que **ningún** evento contiene el cuerpo de un `Secret`. Con una política mal escrita (secrets en `RequestResponse`) el valor en base64 aparecería en `requestObject`/`responseObject`:

   ```bash
   jq 'select(.objectRef.resource=="secrets" and .responseObject!=null) | {level, user: .user.username, name: .objectRef.name}' \
       /var/log/kubernetes/audit/audit.log
   ```

   El resultado **debe ser vacío**. Si aparece algo, tu política está filtrando secrets al log.

3. Protegé el archivo de log en disco (solo root; no world-readable):

   ```bash
   chmod 600 /var/log/kubernetes/audit/audit.log
   ls -l /var/log/kubernetes/audit/
   ```

4. Confirmá que la rotación por tamaño/antigüedad está activa (los flags del Ejercicio 1). Al superar `--audit-log-maxsize` MB, el apiserver rota el archivo y conserva `--audit-log-maxbackup` copias, descartando las más viejas que `--audit-log-maxage` días:

   ```bash
   ls -lh /var/log/kubernetes/audit/           # esperá a ver audit-<timestamp>.log tras suficiente tráfico
   ```

**Preguntas de comprensión**

1. Nombrá dos técnicas para bajar el volumen del audit log **sin** perder los eventos relevantes para seguridad. ¿Por qué el orden de las reglas es lo que hace que funcionen?
2. ¿Cuál es la forma más común en que el propio audit log se convierte en una **fuga de datos**? ¿Qué recurso y qué nivel hay que combinar para provocarla?
3. ¿Por qué la rotación (`maxsize`/`maxbackup`/`maxage`) es tanto un requisito operativo como de seguridad? (Pensá en disponibilidad del nodo *y* en retención para compliance.)
4. `--audit-log-path=-` es un valor válido. ¿Qué hace y por qué sería útil en un cluster donde un DaemonSet de logging ya recolecta stdout de los Pods del control-plane?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

1. **Los eventos los genera exclusivamente el `kube-apiserver`.** Es el único componente por el que pasan todas las peticiones a la API (autenticación → autorización → admission → persistencia en etcd), así que es el único punto donde se puede observar "quién pidió qué". `kubelet`, `controller-manager` y `scheduler` son *clientes* del apiserver: sus acciones aparecen en el audit log **como peticiones al apiserver**, no como logs propios.
2. Porque el `kube-apiserver` corre como **static pod**: la política y el directorio de logs viven en el filesystem del nodo, no del contenedor. Sin `hostPath` volumes, el proceso dentro del contenedor no puede **leer** el archivo de política ni **escribir** el log en un lugar persistente accesible desde fuera del contenedor. Los flags solo dan las rutas; los volúmenes hacen que esas rutas existan dentro del contenedor.
3. **No.** A nivel `Metadata` se registra únicamente el *metadata* del evento (usuario, verbo, recurso, namespace, timestamp, código de respuesta), **nunca** `requestObject` ni `responseObject`. El contenido del secret solo aparecería con `Request` (cuerpo de la request) o `RequestResponse` (request + response) — por eso `Metadata` es el nivel seguro para secrets.
4. Como el static pod ni siquiera arranca, `kubectl` no lo ve. Mirás en el nodo: (a) los logs del kubelet (`journalctl -u kubelet`), que reporta por qué no puede correr el manifiesto; (b) el runtime de contenedores (`crictl ps -a`, `crictl logs <id>`) para ver el error del proceso apiserver; (c) archivos de crash bajo `/var/log/pods/` o `/var/log/kubernetes/`. El error típico es un flag mal escrito o una ruta de `hostPath` inexistente.

### Ejercicio 2

1. `None` (no registra nada) → `Metadata` (agrega el metadata del evento: usuario, verbo, recurso, IP, código) → `Request` (agrega `requestObject`, el cuerpo enviado) → `RequestResponse` (agrega también `responseObject`, el objeto devuelto por el apiserver). `Request`/`RequestResponse` **no aplican a peticiones non-resource** (p. ej. `/healthz`).
2. Porque las reglas se evalúan **de arriba hacia abajo y gana la primera coincidencia**. La regla específica de RBAC debe estar antes del catch-all para que las operaciones sobre roles se registren a `RequestResponse`. Si el catch-all `Metadata` estuviera primero, capturaría *todo* — incluidos los roles — y la regla `RequestResponse` nunca se alcanzaría; perderías el cuerpo de los cambios de RBAC.
3. Porque a `Request`/`RequestResponse` el **valor del secret/configmap quedaría escrito en el log** (`requestObject`/`responseObject`), convirtiendo el audit log en un almacén de credenciales en claro. `Metadata` deja constancia de *que* alguien accedió sin exponer el *contenido*. Es el balance recomendado.
4. Las stages son `RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`. `ResponseStarted` se emite solo para **requests long-running** (watches, `exec`, `attach`, `port-forward`), cuando ya se enviaron las cabeceras pero no el cuerpo. `RequestReceived` se suele omitir con `omitStages` porque **duplica** cada evento (uno al entrar y otro al completar) aportando poca señal adicional y mucho volumen.
5. Un `watch` es long-running: genera `ResponseStarted` (al abrir el stream) y `ResponseComplete` (al cerrarlo) — más `RequestReceived` si no se omite. Un `get` puntual se resuelve de inmediato, así que solo produce `ResponseComplete` (y `RequestReceived` si no se omite).

### Ejercicio 3

1. `user.username == "system:anonymous"` **y** `user.groups` contiene `system:unauthenticated`. Los dos juntos identifican una petición que no presentó (o no validó) credenciales.
2. Porque `authorization.k8s.io/decision` refleja específicamente la decisión de la **capa de autorización** (RBAC/Node/Webhook). Una petición *autorizada* (`decision: allow`) puede aun así devolver un código de error por otras razones: `409 Conflict`, `422` de validación, `404` si el objeto no existe, un webhook de admission que la rechaza, etc. El `responseStatus.code` mezcla todas esas causas; la anotación aísla la pregunta "¿tenía permiso?".
3. **Sí** podés afirmar: qué usuario, cuándo, desde qué IP, sobre qué secret (namespace/nombre) y con qué verbo, y que la petición fue autorizada. **No** podés afirmar qué *valor* leyó — el contenido no está en el log a nivel `Metadata`. (Eso está bien: querés la evidencia del acceso, no una copia del secret.)
4. Por el campo `objectRef.subresource`: vale `"exec"` en un `kubectl exec`. Un `get pod` no tiene subresource (o es la propia `pods`). También lo delata la stage `ResponseStarted` y el `requestURI` con `.../exec?...`.
5. Enumeración/reconocimiento de permisos: el atacante (o una credencial robada con permisos limitados) está **sondeando** qué puede hacer, probando combinaciones verbo/recurso hasta encontrar una `allow`. Una ráfaga de `forbid` desde un mismo origen es una señal temprana de post-explotación.

### Ejercicio 4

1. Porque si el atacante comprometió el nodo del control-plane (root), puede **borrar o alterar** el propio audit log para cubrir sus huellas — la evidencia y el objetivo comparten host. La integridad forense exige enviar los eventos, en tiempo casi real, a un destino **fuera del alcance** del sistema auditado (SIEM/colector con almacenamiento inmutable/append-only).
2. `batch` prioriza rendimiento: envía de forma asíncrona en lotes, pero puede **perder eventos** si el apiserver cae con el buffer sin vaciar. `blocking-strict` prioriza la garantía de captura: si no puede registrar el evento en `RequestReceived`, **rechaza la request**, garantizando que nada ocurre sin quedar auditado — a costa de que un colector caído pueda frenar el cluster. Elegís `blocking-strict` en entornos de compliance estricto (p. ej. financiero/gubernamental) donde "ninguna acción sin registro" es un requisito normativo por encima de la disponibilidad.
3. **Pueden coexistir**: podés tener a la vez `--audit-log-path` (backend de log local) y `--audit-webhook-config-file` (backend webhook). Ambos backends consumen la **misma** política de auditoría (`--audit-policy-file`); la política decide *qué* se audita, los backends deciden *a dónde* va.
4. **No, fue removido** (la API `auditregistration.k8s.io/AuditSink` / dynamic auditing salió como beta y se **eliminó** — dejó de existir a partir de v1.19). Hoy la política de auditoría es **estática**: se declara en un archivo y se aplica reiniciando/recargando el apiserver. Implica que la política es un artefacto versionado (GitOps) desplegado junto al manifiesto del apiserver, no algo que se cambia en caliente vía la API.

### Ejercicio 5

1. (a) Reglas `level: None` para el ruido predecible de componentes del sistema (`system:kube-scheduler`, `system:kube-controller-manager`, watches de `kube-proxy`, endpoints/leases) y para non-resource URLs como `/healthz`, `/metrics`, `/version`. (b) Bajar el nivel de recursos poco interesantes a `Metadata` mientras se sube solo lo sensible (RBAC, secrets-access, exec) a niveles altos. Funciona **por el orden**: las reglas `None`/específicas van arriba y ganan por "primera coincidencia" antes de llegar a un catch-all, recortando el volumen sin descartar la señal de seguridad.
2. Poniendo un recurso **sensible** (típicamente `Secrets`, también `ConfigMaps` con datos, o `certificatesigningrequests`) en nivel **`Request` o `RequestResponse`**: el cuerpo del objeto — el secret en base64 — queda escrito en `requestObject`/`responseObject`. El audit log pasa a ser un depósito de credenciales legibles. La combinación a evitar es *recurso sensible + nivel ≥ Request*.
3. Operativamente, sin rotación el archivo crece sin límite y puede **llenar el disco del control-plane**, degradando o tumbando el apiserver (problema de disponibilidad). De seguridad/compliance, `maxage`/`maxbackup` implementan la **política de retención**: conservar evidencia el tiempo exigido por la normativa y no más (minimización de datos), de forma consistente y automática.
4. `--audit-log-path=-` envía los eventos a **stdout** del `kube-apiserver` en lugar de a un archivo. Es útil cuando un **DaemonSet de logging** (Fluent Bit, Vector, etc.) ya recolecta el stdout de los Pods del control-plane: los eventos entran directo al pipeline de logs centralizado sin gestionar archivos ni rotación en el nodo, y salen del host automáticamente (buena para integridad de la evidencia).

</details>

---

### Fuentes

- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *Audit Policy / Event API reference* (`audit.k8s.io/v1`): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes — *kube-apiserver flags* (`--audit-*`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- CNCF — *KCSA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf