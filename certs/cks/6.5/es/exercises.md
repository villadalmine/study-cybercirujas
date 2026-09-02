# CKS 6.5 — Usar los Audit Logs de Kubernetes para Monitorizar el Acceso

## Ejercicios Guiados

> **Peso en el examen:** 4 · **Versión del cluster:** v1.34 · **Tiempo estimado:** 120–150 min
>
> El audit logging es el único mecanismo en Kubernetes que responde *"¿quién hizo qué, sobre qué objeto, desde dónde, y fue permitido?"* después del hecho. RBAC te dice qué está *permitido*; el audit log te dice qué se *intentó*. En el examen CKS este tema casi siempre aparece como una edición de static pod bajo presión de tiempo, así que cada ejercicio de abajo termina con la misma disciplina: **cambiar → reiniciar → probar que funciona → probar que no rompiste el API server.**

---

### Prerrequisitos del lab

* Un **cluster provisionado con kubeadm** donde tengas SSH como `root` en el nodo del control plane. El API server debe correr como **static Pod** (`/etc/kubernetes/manifests/kube-apiserver.yaml`). Los control planes gestionados (EKS/GKE/AKS) **no** sirven para estos ejercicios — no podés editar los flags de su API server.
* `jq` instalado en el nodo del control plane (`apt-get install -y jq` / `dnf install -y jq`).
* `crictl` configurado (`crictl` ya está presente en los nodos kubeadm; si `crictl ps` avisa sobre el endpoint, ejecutá `crictl config runtime-endpoint unix:///run/containerd/containerd.sock`).
* Un snapshot o backup del manifiesto antes de empezar. No negociable:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.orig
```

En todo el documento, `controlplane` es el hostname del nodo del control plane; sustituilo por el tuyo.

---

## Ejercicio 1 — Habilitar el backend de log con una política base

**Objetivo:** conseguir eventos de auditoría en disco con la configuración correcta más pequeña posible, y entender cada una de las cuatro piezas móviles (archivo de política, ruta del log, montajes hostPath, reinicio del static pod).

1. Creá el directorio que va a contener el log y el directorio para la política. El directorio del log **debe existir en el host** antes de montarlo, salvo que uses `type: DirectoryOrCreate`:

```bash
sudo mkdir -p /var/log/kubernetes/audit
sudo mkdir -p /etc/kubernetes/audit
```

2. Escribí una política deliberadamente ingenua, de tipo catch-all:

```bash
sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
EOF
```

3. Editá el manifiesto del static Pod del API server:

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

4. Agregá los flags de auditoría a `spec.containers[0].command` (cada flag es su propio elemento de la lista, alineado con el `- --advertise-address=...` existente):

```yaml
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

5. Agregá los dos `volumeMounts` dentro de `spec.containers[0]`:

```yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/audit
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
      readOnly: false
```

6. Agregá los `volumes` correspondientes bajo `spec` (al mismo nivel de indentación que `containers`):

```yaml
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

7. Guardá y salí. El kubelet detecta el cambio del manifiesto y recrea el Pod. Observá cómo vuelve el contenedor — **no** uses `kubectl` para esto, porque el API server es justamente lo que está caído:

```bash
sudo crictl ps -a --name kube-apiserver --latest
```

Esperado una vez sano:

```
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT   POD ID
9f2b1c7a4e8d1  8a9c1f0d7e21b  18 seconds ago  Running   kube-apiserver   1         3ab77c9e1f2a4
```

8. Confirmá que la API vuelve a responder y que el archivo de log fue creado:

```bash
kubectl get nodes
sudo ls -lh /var/log/kubernetes/audit/
```

```
total 3.4M
-rw------- 1 root root 3.4M Aug  6 09:14 audit.log
```

9. Generá un evento que puedas encontrar de forma determinista, y después buscalo:

```bash
kubectl create namespace audit-demo
sudo grep -c '"kind":"Event"' /var/log/kubernetes/audit/audit.log
sudo grep 'audit-demo' /var/log/kubernetes/audit/audit.log | head -1 | jq .
```

**Preguntas**

* **Q1.** Agregaste `--audit-policy-file` pero olvidaste `--audit-log-path` y no configuraste un webhook. El API server arranca normalmente. ¿A dónde van los eventos de auditoría, y por qué esta es la mala configuración más peligrosa de todo este tema?
* **Q2.** ¿Por qué el volumen `audit-policy` usa `readOnly: true` mientras que `audit-log` usa `readOnly: false`? ¿Qué pasa en tiempo de ejecución si los invertís?
* **Q3.** El archivo de política vive en el host en `/etc/kubernetes/audit/policy.yaml` y el flag apunta a `/etc/kubernetes/audit/policy.yaml`. Explicá con precisión por qué ambas rutas deben escribirse aunque parezcan idénticas.
* **Q4.** En esta política base, ¿aproximadamente cuántos eventos produce un solo `kubectl create namespace`, y por qué el número es mayor que uno?

---

## Ejercicio 2 — Diseccionar un Event de auditoría

**Objetivo:** leer el esquema con fluidez, porque toda investigación es un filtro `jq` sobre estos campos.

1. Extraé un evento completo de una lectura de Secret. Primero, creá algo para leer:

```bash
kubectl -n audit-demo create secret generic db-credentials \
  --from-literal=password='S3cr3t-Rotate-Me'
kubectl -n audit-demo get secret db-credentials -o yaml >/dev/null
```

2. Traé el evento correspondiente:

```bash
sudo jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="db-credentials" and .verb=="get")' \
  /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

Forma esperada (los valores van a diferir):

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "4f8b0d47-2c6a-4a9d-9a41-2ec8f2a1c0d3",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-demo/secrets/db-credentials",
  "verb": "get",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["kubeadm:cluster-admins", "system:authenticated"]
  },
  "sourceIPs": ["192.168.178.20"],
  "userAgent": "kubectl/v1.34.0 (linux/amd64) kubernetes/f9a2c1e",
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-demo",
    "name": "db-credentials",
    "apiVersion": "v1"
  },
  "responseStatus": { "metadata": {}, "code": 200 },
  "requestReceivedTimestamp": "2026-08-06T09:14:22.118374Z",
  "stageTimestamp": "2026-08-06T09:14:22.121905Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" of ClusterRole \"cluster-admin\" to Group \"kubeadm:cluster-admins\""
  }
}
```

3. Producí un informe de acceso compacto — una línea por evento — que es el formato que realmente querés durante un incidente:

```bash
sudo jq -r 'select(.stage=="ResponseComplete")
  | [.stageTimestamp, .user.username, .verb,
     (.objectRef.resource // .requestURI), (.objectRef.namespace // "-"),
     (.objectRef.name // "-"), (.responseStatus.code|tostring)]
  | @tsv' /var/log/kubernetes/audit/audit.log | tail -20
```

4. Encontrá cada request que fue **denegado** por autorización — la consulta de mayor señal de todo el log:

```bash
sudo jq -r 'select(.annotations."authorization.k8s.io/decision"=="forbid")
  | "\(.stageTimestamp) \(.user.username) \(.verb) \(.requestURI) :: \(.annotations."authorization.k8s.io/reason")"' \
  /var/log/kubernetes/audit/audit.log
```

5. Identificá cuántas identidades distintas tocaron la API en el log actual, ordenadas por volumen:

```bash
sudo jq -r 'select(.stage=="ResponseComplete") | .user.username' \
  /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn | head
```

```
  48213 system:apiserver
  19077 system:kube-scheduler
  16552 system:node:controlplane
   9814 system:kube-controller-manager
    412 kubernetes-admin
     37 system:serviceaccount:audit-demo:reporting
```

**Preguntas**

* **Q5.** El evento de arriba tiene `level: Metadata` y `verb: get`. ¿Subir esa regla a `level: Request` revelaría el campo `data` del Secret? ¿Y `RequestResponse`? Justificá ambas respuestas con la semántica de cada nivel.
* **Q6.** `requestReceivedTimestamp` es `09:14:22.118374Z` y `stageTimestamp` es `09:14:22.121905Z`. ¿Qué mide la diferencia, y cómo la usarías para cazar un admission webhook lento?
* **Q7.** ¿Cuál es la diferencia entre `user.username` e `impersonatedUser`, y sobre qué campo debe filtrar una investigación para atrapar a un operador que ejecutó `kubectl --as=system:serviceaccount:kube-system:default`?
* **Q8.** `sourceIPs` es un array, no un escalar. ¿Bajo qué topología contiene más de una entrada, y qué significa el orden?

---

## Ejercicio 3 — Una política quirúrgica: orden de reglas, niveles, `omitStages`, `omitManagedFields`

**Objetivo:** reemplazar el catch-all por una política de producción. El catch-all es inusable en producción: en un cluster ocioso de tres nodos escribe ~1–2 GB/día, y registra los bucles ruidosos del control plane que nunca vas a investigar.

1. Medí tu volumen actual antes de cambiar nada:

```bash
sudo ls -l /var/log/kubernetes/audit/audit.log
sleep 60
sudo ls -l /var/log/kubernetes/audit/audit.log
```

2. Escribí la política de producción. **Leé los comentarios — el orden de las reglas es todo el ejercicio:**

```bash
sudo tee /etc/kubernetes/audit/policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy

# Global: never emit the RequestReceived stage. It roughly halves log volume
# and carries no information that ResponseComplete does not already have,
# except for requests that never complete.
omitStages:
  - "RequestReceived"

# Global: strip .metadata.managedFields from logged bodies. Server-Side Apply
# metadata can be larger than the object itself and has no forensic value.
omitManagedFields: true

rules:
  # ---- 1. DROP: high-volume, low-value control-plane chatter -------------
  - level: None
    users:
      - "system:kube-scheduler"
      - "system:kube-controller-manager"
      - "system:apiserver"
    verbs: ["get", "list", "watch"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status", "pods", "pods/status", "endpoints"]

  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"
      - "/openapi/*"
      - "/apis*"
      - "/api*"

  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # ---- 2. SENSITIVE: metadata ONLY, never bodies ------------------------
  # Bodies of these objects contain credentials in cleartext. Logging them at
  # Request/RequestResponse converts the audit log into a secret store.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # ---- 3. HIGH VALUE: full request+response on privilege changes ---------
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
      - group: "admissionregistration.k8s.io"
      - group: "policy"
        resources: ["podsecuritypolicies"]
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # ---- 4. Workload mutations: request body, not response -----------------
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "services", "persistentvolumeclaims"]
      - group: "apps"
      - group: "batch"

  # ---- 5. Exec / attach / port-forward: always, always logged ------------
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/eviction"]

  # ---- 6. Catch-all ------------------------------------------------------
  - level: Metadata
    omitStages:
      - "ResponseStarted"
EOF
```

3. Validá el YAML **antes** de que el kubelet lo lea (una política malformada impide que el API server arranque):

```bash
python3 -c 'import yaml,sys; yaml.safe_load(open("/etc/kubernetes/audit/policy.yaml")); print("YAML OK")'
```

4. Forzá un reinicio del API server. Editar solo el archivo de política **no** alcanza — la política se parsea una única vez, al arrancar:

```bash
sudo crictl rm -f $(sudo crictl ps -q --name kube-apiserver)
```

Como alternativa, tocá el manifiesto para que el kubelet recree el Pod:

```bash
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
```

5. Esperá a que esté listo y confirmá que las reglas de descarte funcionan — las lecturas de kube-scheduler ahora deberían estar ausentes:

```bash
sudo truncate -s 0 /var/log/kubernetes/audit/audit.log
sleep 60
sudo jq -r '.user.username' /var/log/kubernetes/audit/audit.log | sort | uniq -c | sort -rn
```

6. Verificá que cada nivel se comporta como fue diseñado:

```bash
# Metadata only — no data field must appear
kubectl -n audit-demo get secret db-credentials -o yaml >/dev/null
sudo jq -c 'select(.objectRef.resource=="secrets") | {level, verb, hasBody: (has("responseObject"))}' \
  /var/log/kubernetes/audit/audit.log | tail -3

# RequestResponse on RBAC — full object must appear
kubectl -n audit-demo create role reader --verb=get --resource=pods
sudo jq -c 'select(.objectRef.resource=="roles") | {level, verb, rules: .responseObject.rules}' \
  /var/log/kubernetes/audit/audit.log | tail -1

# RequestResponse on exec
kubectl -n audit-demo run probe --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n audit-demo wait --for=condition=Ready pod/probe --timeout=60s
kubectl -n audit-demo exec probe -- id
sudo jq -c 'select(.objectRef.subresource=="exec") | {user: .user.username, uri: .requestURI}' \
  /var/log/kubernetes/audit/audit.log | tail -1
```

Esperado para el evento de exec:

```json
{"user":"kubernetes-admin","uri":"/api/v1/namespaces/audit-demo/pods/probe/exec?command=id&container=probe&stderr=true&stdout=true"}
```

7. Compará el volumen contra el paso 1 — deberías ver una reducción de aproximadamente un orden de magnitud.

**Preguntas**

* **Q9.** Mové la regla catch-all `- level: Metadata` del final al principio de `rules` y reiniciá. ¿Qué le pasa a la regla `RequestResponse` de RBAC, y cuál es el algoritmo general de coincidencia?
* **Q10.** La regla de exec (`pods/exec`) está en la posición 5, *después* de la regla `level: None` para `system:nodes`. ¿Podría un `kubectl exec` ser descartado silenciosamente por esa regla anterior? Explicá usando los campos sobre los que coinciden las reglas.
* **Q11.** La política define `omitManagedFields: true` de forma global. Escribí el cambio de dos líneas que conserva los managed fields **solo** para la regla de RBAC, y explicá la semántica de override (global vs. a nivel de regla) para `omitManagedFields` frente a `omitStages`.
* **Q12.** La regla 6 usa `omitStages: ["ResponseStarted"]` mientras que el encabezado de la política ya omite `RequestReceived`. ¿Qué stages emite realmente un `kubectl get pods` que coincide con la regla 6?
* **Q13.** La regla 3 declara `- group: "admissionregistration.k8s.io"` sin clave `resources`. ¿Qué significa una lista `resources` vacía, y por qué eso es a la vez conveniente y riesgoso?

---

## Ejercicio 4 — Investigación de un incidente desde el audit log

**Objetivo:** ejecutar las cuatro consultas que realmente vas a necesitar a las 03:00: *quién leyó el secret*, *quién borró el objeto*, *quién está enumerando*, *qué tocó la ServiceAccount comprometida*.

1. Preparar el incidente. Creá una ServiceAccount con un Role acotado, y después usala:

```bash
kubectl -n audit-demo create serviceaccount reporting
kubectl -n audit-demo create role secret-reader --verb=get,list --resource=secrets
kubectl -n audit-demo create rolebinding reporting-secret-reader \
  --role=secret-reader --serviceaccount=audit-demo:reporting

TOKEN=$(kubectl -n audit-demo create token reporting --duration=1h)
APISERVER=https://$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}'):6443

# Allowed
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/audit-demo/secrets/db-credentials" >/dev/null

# Denied — enumeration attempt across the cluster
for r in pods deployments nodes secrets serviceaccounts; do
  curl -sk -o /dev/null -w "%{http_code} $r\n" -H "Authorization: Bearer $TOKEN" \
    "$APISERVER/api/v1/$r"
done
```

Esperado:

```
403 pods
404 deployments
403 nodes
403 secrets
403 serviceaccounts
```

2. **¿Quién leyó el Secret?** — cada principal que tocó algún Secret, con el resultado:

```bash
sudo jq -r 'select(.objectRef.resource=="secrets" and (.verb|test("get|list|watch")))
  | "\(.stageTimestamp)\t\(.user.username)\t\(.verb)\t\(.objectRef.namespace)/\(.objectRef.name // "*")\t\(.responseStatus.code)\t\(.annotations."authorization.k8s.io/decision")"' \
  /var/log/kubernetes/audit/audit.log | sort | tail -20
```

3. **¿Quién lo borró?** — simulá y después rastreá una acción destructiva:

```bash
kubectl -n audit-demo delete pod probe --now
sudo jq -r 'select(.verb=="delete" or .verb=="deletecollection")
  | "\(.stageTimestamp) \(.user.username) via \(.userAgent | split(" ")[0]) from \(.sourceIPs[0]) -> \(.objectRef.resource)/\(.objectRef.name) in \(.objectRef.namespace // "-") [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log | tail -10
```

4. **Detección de enumeración** — contá los 403 por identidad en una ventana móvil. Cualquier identidad no humana con una ráfaga de denegaciones es una señal de credencial comprometida:

```bash
sudo jq -r 'select(.responseStatus.code==403)
  | "\(.user.username)"' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head
```

```
      4 system:serviceaccount:audit-demo:reporting
      1 system:anonymous
```

5. **Radio de impacto de una identidad** — todo lo que hizo un solo principal, en orden:

```bash
sudo jq -r 'select(.user.username=="system:serviceaccount:audit-demo:reporting")
  | "\(.stageTimestamp) \(.verb) \(.requestURI) [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log | sort
```

6. **Detectar abuso de impersonation** — el campo que la mayoría de los equipos olvida monitorizar:

```bash
kubectl --as=system:serviceaccount:kube-system:default get pods -A 2>/dev/null | head -2
sudo jq -r 'select(has("impersonatedUser"))
  | "\(.stageTimestamp) REAL=\(.user.username) AS=\(.impersonatedUser.username) \(.verb) \(.requestURI) [\(.responseStatus.code)]"' \
  /var/log/kubernetes/audit/audit.log
```

7. Observá el estado de rotación del log. El API server rota in-process, no usa `logrotate`:

```bash
sudo ls -la /var/log/kubernetes/audit/
```

```
-rw------- 1 root root  42M Aug  6 09:52 audit.log
-rw------- 1 root root 100M Aug  6 08:31 audit-2026-08-06T08-31-04.117.log
```

**Preguntas**

* **Q14.** En el paso 1, el request de `deployments` devolvió **404** mientras que los demás devolvieron **403**. Explicá por qué, y cómo se ve el evento de auditoría de ese request en términos de `objectRef` y `annotations`.
* **Q15.** Tu política registra los Secrets en `Metadata`. Un auditor pregunta: *"probá que la ServiceAccount `reporting` nunca vio el valor de `db-credentials`."* ¿Podés probarlo desde este log? ¿Qué podés probar realmente, y cuál es la respuesta arquitectónica correcta para el auditor?
* **Q16.** Alguien borró un Deployment y solo encontrás un evento con `user.username: system:serviceaccount:kube-system:generic-garbage-collector`. ¿Qué pasó, y qué campo del evento *original* identifica al humano que realmente lo disparó?
* **Q17.** El log rotó y el archivo que necesitás es `audit-2026-08-06T08-31-04.117.log`. Con `--audit-log-maxbackup=10` y `--audit-log-maxsize=100`, ¿cuál es la huella máxima en disco y la ventana de retención en el peor caso en un cluster ocupado? ¿Por qué `--audit-log-maxage=30` es engañoso acá?
* **Q18.** Tenés un control plane HA de tres nodos detrás de un load balancer. Ejecutás la consulta del paso 5 en `controlplane-1` y no encontrás nada. ¿La identidad está limpia?

---

## Ejercicio 5 — El backend webhook: enviar eventos de auditoría fuera del nodo

**Objetivo:** entender por qué el backend de log por sí solo no satisface un requisito de auditoría, y configurar el sink dinámico.

1. En el nodo del control plane, ejecutá un receptor mínimo que imprima lo que recibe. El API server corre con `hostNetwork: true`, así que `127.0.0.1` en el nodo es alcanzable desde adentro del Pod:

```bash
sudo tee /root/audit-sink.py >/dev/null <<'EOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        payload = json.loads(body)
        for ev in payload.get('items', []):
            print(f"{ev.get('stageTimestamp')} {ev['user']['username']} "
                  f"{ev.get('verb')} {ev.get('requestURI')} "
                  f"[{ev.get('responseStatus', {}).get('code')}]", flush=True)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', 9900), Sink).serve_forever()
EOF

sudo nohup python3 /root/audit-sink.py >/var/log/audit-sink.log 2>&1 &
```

2. Escribí la configuración del webhook. Es un archivo en **formato kubeconfig** — esto confunde a la mayoría de la gente, porque describe un endpoint HTTP externo, no un cluster:

```bash
sudo tee /etc/kubernetes/audit/webhook.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: audit-sink
  cluster:
    server: http://127.0.0.1:9900/events
users:
- name: kube-apiserver
contexts:
- name: default
  context:
    cluster: audit-sink
    user: kube-apiserver
current-context: default
EOF
```

3. Agregá los flags del webhook al manifiesto del API server, junto a los flags de log existentes:

```yaml
    - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
    - --audit-webhook-mode=batch
    - --audit-webhook-batch-max-size=100
    - --audit-webhook-batch-max-wait=5s
    - --audit-webhook-initial-backoff=10s
```

El archivo `webhook.yaml` ya vive bajo `/etc/kubernetes/audit`, que está montado, así que **no hace falta ningún volumen nuevo**.

4. Guardá, esperá el reinicio, y observá el sink:

```bash
sudo tail -f /var/log/audit-sink.log
```

En una segunda shell:

```bash
kubectl -n audit-demo get secrets
kubectl -n audit-demo create configmap probe-cm --from-literal=a=b
```

Esperado en el sink:

```
2026-08-06T10:22:41.882913Z kubernetes-admin list /api/v1/namespaces/audit-demo/secrets [200]
2026-08-06T10:22:44.019447Z kubernetes-admin create /api/v1/namespaces/audit-demo/configmaps [201]
```

5. Probá el modo de fallo. Matá el sink y observá que el cluster sigue funcionando:

```bash
sudo pkill -f audit-sink.py
kubectl -n audit-demo get pods     # still works
sudo crictl logs $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i webhook | tail -5
```

```
E0806 10:24:11.774218  1 metrics.go:120] "Failed to post latency metrics" err="Post \"http://127.0.0.1:9900/events\": dial tcp 127.0.0.1:9900: connect: connection refused"
```

6. Ahora cambiá `--audit-webhook-mode=batch` por `--audit-webhook-mode=blocking-strict`, reiniciá, y repetí el paso 5 con el sink todavía caído. Observá el efecto sobre los requests de la API, y después **volvé a `batch`**.

**Preguntas**

* **Q19.** Ambos backends estuvieron activos simultáneamente en este ejercicio. ¿Eso está soportado, y ambos usan el mismo archivo de política?
* **Q20.** Explicá la diferencia operativa entre `--audit-webhook-mode=batch`, `blocking` y `blocking-strict`. ¿Cuál puede tirar abajo tu cluster, y sobre qué exactamente bloquea `blocking-strict` que `blocking` no?
* **Q21.** La configuración del webhook de arriba usa `http://` plano sin credenciales de cliente. Nombrá los tres riesgos concretos que esto crea, y cómo arreglarías cada uno con campos disponibles en ese mismo kubeconfig.
* **Q22.** Un colega te pide configurar el objeto de API `AuditSink` para que la política de auditoría pueda gestionarse dinámicamente con `kubectl` en lugar de editando el static Pod. ¿Qué le decís?

---

## Ejercicio 6 — Break/fix: el API server no vuelve

**Objetivo:** el modo de fallo que *vas* a encontrar en el examen. Practicá recuperarte sin `kubectl`.

1. Introducí una falla realista — una ruta de política que no está montada:

```bash
sudo cp /etc/kubernetes/audit/policy.yaml /root/policy-elsewhere.yaml
sudo sed -i 's#--audit-policy-file=.*#--audit-policy-file=/root/policy-elsewhere.yaml#' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

2. Confirmá que el cluster está caído:

```bash
kubectl get nodes
```

```
E0806 10:41:02.113 The connection to the server 192.168.178.20:6443 was refused - did you specify the right host or port?
```

3. Diagnosticá. Dado que el contenedor sale inmediatamente, `crictl ps` no muestra nada — necesitás `-a`:

```bash
sudo crictl ps -a --name kube-apiserver --latest
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver --latest) 2>&1 | tail -20
```

```
Error: error while parsing file: open /root/policy-elsewhere.yaml: no such file or directory
```

4. La otra fuente confiable, que sobrevive a la recolección de basura de contenedores:

```bash
sudo ls /var/log/pods/kube-system_kube-apiserver-controlplane_*/kube-apiserver/
sudo tail -20 /var/log/pods/kube-system_kube-apiserver-controlplane_*/kube-apiserver/*.log
```

5. Corregí la ruta y confirmá la recuperación:

```bash
sudo sed -i 's#--audit-policy-file=.*#--audit-policy-file=/etc/kubernetes/audit/policy.yaml#' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sudo crictl ps -a --name kube-apiserver --latest
kubectl get nodes
```

6. Repetí el ejercicio con una **segunda** clase de falla — un documento de política inválido:

```bash
sudo sed -i 's/^  - level: Metadata$/  - level: MetaData/' /etc/kubernetes/audit/policy.yaml
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 15
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver --latest) 2>&1 | tail -5
```

```
Error: loading audit policy file: failed to decode: strict decoding error: invalid policy level "MetaData"
```

Después reparalo:

```bash
sudo sed -i 's/^  - level: MetaData$/  - level: Metadata/' /etc/kubernetes/audit/policy.yaml
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
```

7. Tercera clase de falla — el bloque `volumes` ausente mientras `volumeMounts` está presente. Eliminá solo la entrada `audit-log` de `spec.volumes`, después reiniciá y leé la vista del kubelet:

```bash
sudo journalctl -u kubelet --since "2 min ago" | grep -i -A3 'kube-apiserver'
```

**Preguntas**

* **Q23.** En el paso 3 usaste `crictl ps -a`. ¿Por qué el `-a` es obligatorio acá, y por qué `crictl logs` a veces no devuelve absolutamente nada para este Pod?
* **Q24.** El kubelet sigue reiniciando el contenedor del API server. ¿Hay un backoff, y cómo cambia eso tu ritmo de troubleshooting (es decir, cuánto deberías esperar antes de concluir que tu arreglo falló)?
* **Q25.** Ordená estas tres fallas por cómo se presentan: (a) ruta del archivo de política no montada, (b) valor de `level` inválido, (c) `volumeMounts` referenciando un `name` que no tiene entrada correspondiente en `volumes`. ¿Cuál produce un error del *kubelet* en lugar del *API server*, y por qué?
* **Q26.** No tenés `crictl` ni acceso a `journalctl`, solo una shell en el nodo. Nombrá un lugar más donde buscar la razón por la que murió el API server.

---

## Ejercicio 7 — Anotaciones de auditoría generadas por admission (avanzado)

**Objetivo:** enriquecer los eventos de auditoría desde el admission control, para que el audit log registre *veredictos de política*, no solo llamadas a la API. Este es el reemplazo moderno de "correr un mutating webhook que loguea".

1. Creá una `ValidatingAdmissionPolicy` que marque los contenedores privilegiados **sin bloquearlos**, y que adjunte una anotación de auditoría:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: privileged-container-audit
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
  - expression: >-
      !object.spec.containers.exists(c,
        has(c.securityContext) &&
        has(c.securityContext.privileged) &&
        c.securityContext.privileged == true)
    message: "privileged containers are not allowed"
    reason: Forbidden
  auditAnnotations:
  - key: "privileged-request"
    valueExpression: >-
      object.spec.containers.exists(c,
        has(c.securityContext) &&
        has(c.securityContext.privileged) &&
        c.securityContext.privileged == true)
      ? "pod " + object.metadata.name + " requested a privileged container"
      : null
EOF
```

2. Vinculala en modo **solo auditoría**:

```bash
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: privileged-container-audit-binding
spec:
  policyName: privileged-container-audit
  validationActions: ["Audit"]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: audit-demo
EOF
```

3. Disparala:

```bash
kubectl -n audit-demo apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
EOF
```

El Pod **se crea** (`validationActions: ["Audit"]` no deniega).

4. Leé las anotaciones que admission escribió en el evento de auditoría:

```bash
sudo jq -c 'select(.objectRef.resource=="pods" and .objectRef.name=="bad-pod" and .verb=="create")
  | .annotations' /var/log/kubernetes/audit/audit.log | tail -1 | jq .
```

```json
{
  "authorization.k8s.io/decision": "allow",
  "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"kubeadm:cluster-admins\" ...",
  "privileged-container-audit/privileged-request": "pod bad-pod requested a privileged container",
  "validation.policy.admission.k8s.io/validation_failure": "[{\"expressionIndex\":0,\"message\":\"privileged containers are not allowed\",\"reason\":\"Forbidden\",\"binding\":\"privileged-container-audit-binding\",\"policy\":\"privileged-container-audit\",\"validationActions\":[\"Audit\"]}]"
}
```

5. Construí la consulta de detección sobre la que realmente alertarías:

```bash
sudo jq -r 'select(.annotations."validation.policy.admission.k8s.io/validation_failure" != null)
  | "\(.stageTimestamp) \(.user.username) \(.verb) \(.objectRef.namespace)/\(.objectRef.name) :: \(.annotations."validation.policy.admission.k8s.io/validation_failure")"' \
  /var/log/kubernetes/audit/audit.log
```

6. Chequeá también qué escribe Pod Security Admission por su cuenta — habilitá el modo audit en el namespace y repetí:

```bash
kubectl label ns audit-demo pod-security.kubernetes.io/audit=restricted --overwrite
kubectl -n audit-demo run bad-pod-2 --image=busybox:1.36 --restart=Never -- sleep 3600
sudo jq -c 'select(.objectRef.name=="bad-pod-2") | .annotations
  | with_entries(select(.key|startswith("pod-security")))' \
  /var/log/kubernetes/audit/audit.log | tail -1
```

```json
{"pod-security.kubernetes.io/audit-violations":"would violate PodSecurity \"restricted:latest\": allowPrivilegeEscalation != false (container \"bad-pod-2\" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (...), runAsNonRoot != true (...), seccompProfile (...)"}
```

**Preguntas**

* **Q27.** Tu política registra las creaciones de Pods en `level: Request`. ¿Estas anotaciones seguirían apareciendo si esa regla fuera `level: Metadata`? ¿Cuál es el nivel más bajo en el que se registran las `annotations`, y qué implica eso para las reglas de "descartar ruido" del Ejercicio 3?
* **Q28.** El `valueExpression` devuelve `null` para los Pods que cumplen. ¿Cuál es el efecto práctico sobre el audit log, y por qué eso es mejor que devolver `"ok"`?
* **Q29.** Querés la misma visibilidad pero con enforcement. ¿Qué único campo cambiás, y cómo se va a ver el evento de auditoría después — específicamente `responseStatus.code` y si la anotación `validation_failure` sigue presente?

---

## Ejercicio 8 — Simulacro cronometrado de examen (12 minutos, sin apuntes)

**Objetivo:** reproducir desde cero la forma exacta de la tarea del examen.

> **Tarea.** En `controlplane`, habilitá el audit logging del API server de modo que:
> 1. Los eventos se escriban en `/var/log/kubernetes/audit/audit.log`, rotados a los 100 MB, conservando 5 archivos, descartando archivos de más de 7 días.
> 2. El stage `RequestReceived` nunca se registre.
> 3. Los cambios a `Secrets` en **cualquier** namespace se registren en nivel `Metadata`.
> 4. `get`/`list`/`watch` sobre `ConfigMaps` en el namespace `kube-system` **no** se registren en absoluto.
> 5. Todo lo demás se registre en `Metadata`.
> 6. La política viva en `/etc/kubernetes/audit-policy.yaml`.

1. Poné un temporizador de 12 minutos.
2. Escribí la política, editá el manifiesto, reiniciá, y verificá con un comando que pruebe *cada* uno de los requisitos 2, 3 y 4 de forma independiente.
3. Pará el temporizador. Después comprobá tu trabajo contra la solución de referencia en la sección de respuestas.

**Preguntas**

* **Q30.** El requisito 3 dice "cambios a Secrets". ¿Restringiste los `verbs`? ¿Cuál es la diferencia en volumen de log resultante y en corrección entre restringirlos y no hacerlo?
* **Q31.** Los requisitos 4 y 5 están en tensión. ¿Cuál es el único orden de reglas que satisface ambos, y qué comando `jq` de una línea prueba que el requisito 4 está realmente en efecto?

---

## Limpieza

```bash
kubectl delete ns audit-demo --ignore-not-found
kubectl delete validatingadmissionpolicybinding privileged-container-audit-binding --ignore-not-found
kubectl delete validatingadmissionpolicy privileged-container-audit --ignore-not-found
sudo pkill -f audit-sink.py 2>/dev/null
sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 20 && kubectl get nodes
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.** A ningún lado. La política se evalúa y los eventos se generan, pero sin backend configurado se descartan. El API server **no** avisa de esto en ningún nivel de log significativo, y arranca perfectamente sano. Esto es peligroso porque toda verificación que se te ocurra correr — "el API server está arriba", "el archivo de política parsea", "el flag está presente" — pasa, así que la configuración parece correcta en una revisión de cambios mientras produce cero cobertura forense. La única verificación válida es la del paso 8/9: probar que el archivo existe **y** crece **y** contiene un evento que causaste deliberadamente. La misma trampa existe al revés: `--audit-log-path` sin `--audit-policy-file` hace que el API server se niegue a arrancar.

**A2.** El API server solo lee la política, así que montarla read-only es mínimo privilegio y evita que un proceso de API server comprometido reescriba sus propias reglas de auditoría. Debe *escribir* el log, así que ese montaje no puede ser read-only. Si los invertís: el API server igual arrancaría (nunca escribe la política), pero en el primer evento de auditoría falla al abrir el archivo de log para escritura y sale — `open /var/log/kubernetes/audit/audit.log: read-only file system`. Notá que este es uno de los pocos casos en los que la falla es diferida en lugar de inmediata.

**A3.** Son dos sistemas de archivos distintos. La ruta en `hostPath.path` se resuelve en el **nodo**; la ruta en `--audit-policy-file` y en `mountPath` se resuelve dentro del **mount namespace del contenedor del API server**. Acá coinciden solo porque elegimos montar en la misma ruta — una convención deliberada que hace legible el manifiesto. Nada la obliga: podrías montar el `/etc/kubernetes/audit` del host en `/policies` dentro del contenedor y pasar `--audit-policy-file=/policies/policy.yaml`. La falla del Ejercicio 6 paso 1 es exactamente esta distinción: `/root/policy-elsewhere.yaml` existe en el host pero no en el contenedor.

**A4.** Como mínimo **dos**, y típicamente más. Sin `omitStages`, cada request produce un evento `RequestReceived` y un evento `ResponseComplete`. Los requests de larga duración (watches) emiten además `ResponseStarted`. Encima de la llamada `create namespace` en sí, `kubectl` realiza requests de discovery contra `/api`, `/apis` y `/apis/<group>/<version>`, y el controlador de namespaces empieza a reconciliar de inmediato — así que el conteo práctico para un solo `kubectl create namespace` con una política catch-all es de decenas. Por eso la política catch-all es únicamente un recurso didáctico.

### Ejercicio 2

**A5.** Ninguno lo revela para un `get`.
- `Request` registra los metadatos del evento más el cuerpo del **request**. Un `get` no tiene cuerpo de request, así que `Request` es informacionalmente idéntico a `Metadata` para las lecturas. Sí *revelaría* el Secret en un `create`/`update`, porque ahí el cuerpo del request es el objeto.
- `RequestResponse` registra los metadatos más los cuerpos de request **y response**. Para un `get secrets`, el cuerpo de la respuesta es el Secret, incluyendo `.data` — base64, que es codificación, no cifrado. Así que `RequestResponse` sobre Secrets escribe cada credencial del cluster en un archivo de texto plano en el nodo del control plane, y en cualquier SIEM al que lo envíes.

Por eso la política recomendada upstream fija Secrets, ConfigMaps y TokenReviews en `Metadata`. El audit log se convertiría entonces en un *nuevo* almacén de secretos con un control de acceso más débil que el de etcd — lo opuesto a la intención del control.

**A6.** ~3.5 ms — la latencia del lado del servidor desde el momento en que el API server recibió el request hasta el momento en que se completó el stage dado. Abarca la autenticación, la autorización, **todos los admission webhooks**, y el round-trip a etcd. Para cazar un webhook lento, compará el delta de los verbos de mutación (que atraviesan admission) contra los verbos de lectura (que no) sobre el mismo recurso:

```bash
sudo jq -r 'select(.stage=="ResponseComplete" and (.verb=="create" or .verb=="update"))
  | [((.stageTimestamp|fromdateiso8601) - (.requestReceivedTimestamp|fromdateiso8601)),
     .objectRef.resource, .user.username] | @tsv' /var/log/kubernetes/audit/audit.log \
  | sort -rn | head
```

Cualquier cosa por encima de ~1 s en un create es casi siempre un webhook, y el `objectRef.resource` te dice qué `rules` de qué webhook inspeccionar. Advertencia: `fromdateiso8601` trunca la precisión sub-segundo; para trabajar a nivel de milisegundos, parseá la parte fraccionaria o usá en su lugar la métrica `apiserver_request_duration_seconds`.

**A7.** `user` es la identidad **autenticada** — quién presentó realmente la credencial. `impersonatedUser` es la identidad como la que pidió actuar al API server, y solo se completa cuando están presentes las cabeceras `Impersonate-User`/`Impersonate-Group` (que es lo que envía `kubectl --as`). La autorización se verifica **dos veces**: el usuario real debe tener el verbo `impersonate`, y al usuario suplantado se le debe permitir realizar la acción.

Una investigación debe filtrar sobre **ambos**. Filtrar solo por `user.username` se pierde lo que el operador hizo mientras suplantaba; filtrar solo por `impersonatedUser` pierde al humano responsable. La consulta correcta los une, como en el Ejercicio 4 paso 6. La impersonation es un camino común de escalada de privilegios precisamente porque la mayoría de las reglas de detección ignoran el campo.

**A8.** `sourceIPs` contiene más de una entrada cuando el request atravesó proxies que agregaron `X-Forwarded-For`, y el API server fue iniciado con `--requestheader-allowed-names`/confianza de proxy configurada. El orden es **cliente originante primero, proxy más cercano último** — así que `sourceIPs[0]` es el origen declarado y el último elemento es el par del que el API server aceptó realmente la conexión TCP. Solo el último elemento es confiable sin una cadena de proxies de confianza; de lo contrario `X-Forwarded-For` lo puede fijar el cliente.

### Ejercicio 3

**A9.** La regla de RBAC queda muerta. **La primera regla que coincide con un evento determina su nivel, y la evaluación se detiene ahí** — no hay "gana la más específica", no hay fusión de reglas, y no hay advertencia sobre reglas inalcanzables. Un catch-all arriba deja inalcanzable a toda regla posterior, así que la política entera colapsa a `Metadata` para todo. El corolario es la regla de diseño de toda política de auditoría: **primero las reglas de descarte `None`, después las reglas `RequestResponse` más específicas, y el catch-all último, siempre.**

**A10.** No. Esa regla coincide sobre `userGroups: ["system:nodes"]` **y** `resources` limitados a `nodes`, `pods`, `endpoints` y sus subrecursos de estado — y la coincidencia es un AND entre los campos presentes en la regla. `pods/exec` es una entrada de recurso *distinta* (`resources: ["pods"]` **no** cubre `pods/exec`; los subrecursos deben nombrarse explícitamente como `pods/exec` o con comodín como `pods/*`). Además, `kubectl exec` es un verbo `create`, y esa regla restringe los verbos a `get`/`list`/`watch`. Dos razones independientes por las que no puede coincidir — pero notá que la seguridad acá viene de la semántica explícita de subrecursos, no de la suerte: si esa regla hubiera dicho `resources: ["pods/*"]` sin restricción de verbos, *sí* se habría tragado los eventos de exec provenientes de los kubelets.

**A11.** Agregá un override a nivel de regla:

```yaml
  - level: RequestResponse
    omitManagedFields: false          # <-- keep managedFields for RBAC objects
    resources:
      - group: "rbac.authorization.k8s.io"
      ...
```

Los dos campos tienen semánticas de composición **opuestas**, y esta es una trampa clásica de examen:
- `omitManagedFields`: el valor a nivel de regla **sobrescribe** el valor global.
- `omitStages`: la lista a nivel de regla se **une** (unión) con la lista global. Por lo tanto una regla solo puede omitir *más* stages que el encabezado de la política, nunca menos — no hay forma de re-habilitar `RequestReceived` para una regla una vez que el encabezado lo omite globalmente.

**A12.** Solo `ResponseComplete`. `RequestReceived` se omite globalmente, `ResponseStarted` lo omite la regla, y la unión de las dos listas deja `ResponseComplete` (y `Panic`, que se emite solo cuando el handler entra en pánico). Para un `get pods` corto, este es exactamente el único evento que querés.

**A13.** Una lista `resources` vacía o ausente dentro de una entrada de `group` significa **todos los recursos de ese grupo de API**, en todas las versiones. Es conveniente porque un recurso nuevo agregado a `admissionregistration.k8s.io` en una release futura (un nuevo kind de política, por ejemplo) queda cubierto automáticamente sin editar la política. Es riesgoso exactamente por la misma razón: una release upstream puede multiplicar silenciosamente tu volumen de log, y si el grupo alguna vez incorpora un recurso de alta cardinalidad o portador de credenciales, ya optaste por registrarlo en `RequestResponse` sin revisión. La regla es segura acá solo porque la lista `verbs` que la acompaña excluye las lecturas. Para cualquier grupo que pueda contener material secreto, enumerá los recursos explícitamente.

### Ejercicio 4

**A14.** `/api/v1/deployments` no es una ruta válida — los Deployments viven en el grupo `apps`, en `/apis/apps/v1/deployments`. El enrutamiento del API server rechaza la ruta antes de que RBAC llegue a ejecutarse, así que devuelve **404**, y el evento de auditoría es un evento de **no-recurso**: `objectRef` está ausente o vacío, `requestURI` es `/api/v1/deployments`, y **no** hay anotación `authorization.k8s.io/decision` porque nunca se consultó la autorización.

La lección forense es que 404 y 403 significan cosas muy distintas: un 403 prueba que la identidad se autenticó y RBAC la denegó (un intento de acceso real); un 404 sobre una ruta inexistente muchas veces solo significa un cliente roto — pero una *ráfaga* de 404 sobre muchas rutas es fingerprinting, y es invisible para cualquier regla de detección que solo cuente 403.

**A15.** **No, y este es el compromiso central del tema.** En nivel `Metadata` podés probar que ocurrió un `get` sobre `secrets/db-credentials`, por quién, desde dónde, a qué hora, y que devolvió `200`. No podés probar qué valor se devolvió — pero un `200` en un `get` de un Secret significa que quien llamó *sí* recibió los datos. Así que podés probar lo opuesto de lo que quiere el auditor: el log muestra que la SA **sí** lo obtuvo.

La respuesta correcta al auditor es que el audit log no es el control adecuado para esta pregunta, y que subir el nivel a `RequestResponse` para "probarlo" sería activamente dañino — escribiría la credencial en el log. Los controles correctos son: rotar la credencial, quitar el RoleBinding, usar tokens de ServiceAccount proyectados de corta duración con un audience, cifrar los Secrets en reposo (`EncryptionConfiguration`), y migrar a un almacén de secretos externo con su propio log de acceso. La auditoría te dice que *el acceso ocurrió*; la confidencialidad del valor es un control diferente.

**A16.** Borrado en cascada. El humano borró un objeto propietario (el Deployment), y el garbage collector después borró los dependientes (ReplicaSet, Pods) bajo su propia identidad. Estás mirando el evento del *dependiente*, no el del disparador.

Correlacioná sobre el evento **original**: encontrá el `delete` sobre el recurso propietario donde `user.username` es el humano. Dos campos hacen confiable el join — `objectRef.uid` del evento del propietario coincide con `metadata.ownerReferences[].uid` de los dependientes, y `requestReceivedTimestamp` ordena la cascada. En la práctica: buscá hacia atrás en el tiempo desde el evento del garbage collector el `delete` más cercano sobre el recurso propietario por parte de una identidad que no sea `system:`.

**A17.** La huella máxima es **`maxsize × (maxbackup + 1)` = 100 MB × 11 ≈ 1.1 GB** — 10 archivos rotados más el activo. `--audit-log-maxage=30` es engañoso porque es un *techo*, no una garantía: la rotación se dispara **primero por tamaño**. En un cluster que produce 500 MB/día, 11 × 100 MB se consume en aproximadamente 2.2 días, así que los archivos se borran por el límite de `maxbackup` mucho antes de llegar a los 30 días de antigüedad. Tu retención efectiva es `1.1 GB ÷ volumen diario`, y se encoge en el momento en que el tráfico aumenta — lo que significa que tu ventana forense colapsa silenciosamente durante exactamente el incidente que genera tráfico extra de API. El arreglo no son números más grandes en el nodo; es enviar los eventos fuera del nodo (backend webhook, o un colector de logs que lea el archivo) para que la retención quede desacoplada del disco del nodo.

**A18.** No — solo probaste que no habló con *esa* instancia del API server. **La configuración de auditoría y los audit logs son por proceso de API server.** En HA, el load balancer distribuye los requests entre los tres, así que la actividad de una sola identidad queda dispersa en tres archivos en tres nodos. Tenés que (a) desplegar la política y los flags idénticos en cada nodo del control plane — un drift acá crea un punto ciego que parece logs limpios — y (b) agregar centralmente antes de consultar. Hasta que ambas cosas sean ciertas, "no encontré nada" no es un hallazgo. Este es el argumento práctico más fuerte a favor del backend webhook por sobre el backend de log.

### Ejercicio 5

**A19.** Sí, ambos backends pueden estar habilitados simultáneamente y esa es la forma recomendada en producción: el backend de log como buffer de registro local al nodo, el webhook para agregación central y alertas. **Ambos consumen la misma política única** — hay exactamente un `--audit-policy-file` y él gobierna qué eventos se generan en absoluto. No podés mandar `Metadata` al webhook y `RequestResponse` al disco; el filtrado por backend tiene que hacerse aguas abajo, en el colector.

**A20.**
- `batch` (default para el backend webhook): los eventos se bufferean y se envían por POST de forma asíncrona en lotes. Los requests de la API nunca esperan al sink. Si el sink está caído, los eventos se reintentan con backoff y después se **descartan** cuando el buffer se llena.
- `blocking`: el request de la API se bloquea hasta que el evento haya sido enviado. Un sink lento suma su latencia a cada llamada de API; un sink que falla causa errores en los requests.
- `blocking-strict`: como `blocking`, y además, si el evento del stage **`RequestReceived`** no logra registrarse, el request de la API en sí **falla** en lugar de permitírsele continuar.

`blocking` y `blocking-strict` pueden ambos tirar abajo un cluster cuando el sink se degrada; `blocking-strict` es estrictamente peor operativamente y estrictamente mejor para cumplimiento, porque hace imposible que ocurra una acción sin un registro de auditoría correspondiente. Ese es el trade real: `batch` puede perder evidencia, `blocking-strict` puede perder disponibilidad. Elegí deliberadamente, y si elegís `blocking-strict`, el sink debe tener tanta alta disponibilidad como el propio control plane. (El backend de log tiene el análogo `--audit-log-mode`, con default `blocking`.)

**A21.**
1. **Texto plano en el cable** — los eventos de auditoría contienen nombres de usuario, nombres de recursos, y en `RequestResponse` cuerpos completos de objetos. Arreglo: `https://` más `certificate-authority-data` en la sección `cluster` para que el API server verifique al sink.
2. **Sin autenticación del servidor** — cualquier cosa que pueda tomar el puerto o ganar una carrera de DNS/ARP recibe tu flujo de auditoría. Arreglo: igual que arriba; el pinning de CA es lo que le da significado a la identidad del endpoint.
3. **Sin autenticación del cliente** — el sink no puede distinguir tu API server de cualquier otro emisor, así que cualquiera puede inyectar eventos de auditoría falsificados para enterrar uno real. Arreglo: `client-certificate-data`/`client-key-data` en la sección `users` (mTLS), o un `token` bearer.

Los tres son campos del esquema estándar de kubeconfig, que es precisamente por qué la configuración del webhook usa ese formato. Notá también que el archivo debe estar montado dentro del contenedor del API server y su clave privada protegida en `0600` y propiedad de root.

**A22.** La API `AuditSink` (`auditregistration.k8s.io/v1alpha1`, "configuración dinámica de auditoría") fue deprecada y **eliminada en Kubernetes 1.19**. No existe en v1.34 y no va a volver. La política de auditoría es configuración del control plane, no datos del cluster, y se configura únicamente mediante flags y archivos del API server — lo cual es una propiedad de seguridad, no un descuido: si la política de auditoría fuera un objeto de API con alcance de cluster, cualquiera con el RBAC para editarla podría deshabilitar su propio logging antes de actuar. Gestionar el manifiesto del static Pod y el archivo de política con gestión de configuración (o con las opciones de logging del control plane de un proveedor gestionado) es el camino soportado.

### Ejercicio 6

**A23.** `crictl ps` lista solo los contenedores **en ejecución**. Un contenedor que crashea durante el arranque queda en estado `Exited` en menos de un segundo, así que sin `-a` (todos los estados) ves una lista vacía y podrías concluir erróneamente que el contenedor nunca se creó. `crictl logs` no devuelve nada cuando el contenedor ya fue recolectado por el kubelet — en un crash loop rápido, el ID que capturaste hace un momento puede que ya no exista, y por eso importa `--latest` y por eso `/var/log/pods/.../*.log` (paso 4) es la fuente más durable: esos archivos sobreviven a la eliminación del contenedor y retienen los intentos previos.

**A24.** Sí — el kubelet aplica **backoff exponencial** a los contenedores en crash loop, empezando alrededor de 10 s y duplicando hasta un tope de 5 minutos. En la práctica esto significa que después de un arreglo, un contenedor que ya crasheó muchas veces puede tardar minutos en ser reintentado, y un operador impaciente va a concluir que el arreglo falló y va a empezar a cambiar más cosas — convirtiendo una falla en tres. El ritmo correcto: aplicá el arreglo, y después **forzá** un intento nuevo en lugar de esperar a que pase el backoff. `sudo crictl rm -f <id>` sobre el contenedor salido, o mover el manifiesto fuera de `/etc/kubernetes/manifests` y de vuelta adentro, hace que el kubelet lo trate como un Pod nuevo y reinicia el backoff.

**A25.**
- (a) Ruta no montada → error del **API server**, el contenedor arranca y sale: `open /root/policy-elsewhere.yaml: no such file or directory`.
- (b) `level` inválido → error del **API server** al parsear la política, el contenedor arranca y sale: `invalid policy level "MetaData"`.
- (c) Nombre en `volumeMounts` sin entrada correspondiente en `volumes` → error del **kubelet**; el contenedor **nunca se crea**.

(c) es el que hay que saber reconocer, porque su firma es distinta en naturaleza: `crictl ps -a` no muestra ningún contenedor nuevo y `crictl logs` no tiene nada que mostrar, así que el reflejo habitual produce cero información. La razón es que la referencia del montaje la resuelve el kubelet mientras construye el Pod, antes de que se le pida siquiera al runtime crear un contenedor. La evidencia vive en `journalctl -u kubelet` como un error de validación sobre el spec del Pod. Regla práctica: **ningún contenedor en absoluto → kubelet; contenedor que arranca y muere → API server.**

**A26.** Varios, en orden de utilidad:
1. `/var/log/pods/kube-system_kube-apiserver-<node>_<uid>/kube-apiserver/*.log` — el stdout/stderr crudo del contenedor, retenido entre reinicios, incluidos los intentos previos.
2. `/var/log/containers/kube-apiserver-*.log` — symlinks hacia lo anterior.
3. El status del mirror Pod una vez que el API server se recupera: `kubectl -n kube-system describe pod kube-apiserver-<node>` muestra `Last State: Terminated` con la razón y el mensaje de salida.
4. `sudo ctr -n k8s.io containers ls` / `ctr -n k8s.io tasks ls` si `crictl` no está disponible pero containerd sí.

### Ejercicio 7

**A27.** Sí, seguirían apareciendo. **Las `annotations` son parte de los metadatos del evento y se registran en nivel `Metadata` y superiores** — no necesitás `Request` ni `RequestResponse` para capturar veredictos de admission, decisiones de RBAC, o violaciones de PSA. Ese es un resultado de eficiencia significativo: obtenés visibilidad completa de los veredictos de política en el nivel de logging más barato.

La implicación para las reglas de descarte es la punzante: **`level: None` descarta también las anotaciones.** Cualquier recurso o identidad que descartes por razones de volumen se vuelve invisible para las alertas de veredictos de admission, sin importar cuán fuerte se quejen tus políticas de admission. Así que antes de agregar una regla `None`, verificá que ninguna política de admission de la que dependas para detección coincida con ese mismo tráfico — una regla `None` sobre las escrituras de `system:nodes` es una optimización de apariencia plausible que te dejaría ciego en silencio ante las violaciones de política originadas en los kubelets.

**A28.** Que `valueExpression` devuelva `null` significa que la anotación **no se registra en absoluto**. Cada creación de Pod que cumple produce entonces un evento de auditoría sin anotación extra, y la consulta de alerta del paso 5 es una simple verificación de existencia sin falsos positivos que filtrar.

Devolver `"ok"` adjuntaría una anotación a cada creación de Pod del cluster — inflando el tamaño de los eventos, costando almacenamiento e ingesta de SIEM en el 99.9% de los eventos que no son interesantes, y forzando a cada consulta aguas abajo a filtrar por *valor* en lugar de por *presencia*. El principio general: **las anotaciones de auditoría deben ser escasas y significar "algo pasó", no densas y significar "acá va un estado".**

**A29.** Cambiá `validationActions: ["Audit"]` por `["Deny"]` (o `["Deny", "Audit"]`) en el **binding** — la política en sí no cambia, que es justamente el punto de la división política/binding: una misma política puede aplicarse con enforcement en un namespace y solo auditarse en otro.

Después:
- `responseStatus.code` pasa a ser **403** y `responseStatus.message` lleva el `message` de la política, porque `reason: Forbidden` mapea a un 403.
- Tus `auditAnnotations` (`privileged-container-audit/privileged-request`) **siguen presentes** — las anotaciones de auditoría se emiten independientemente de si el request fue admitido.
- La anotación `validation.policy.admission.k8s.io/validation_failure` se emite cuando `Audit` está entre las acciones. Con `["Deny"]` solo, la denegación es visible por el 403 y el mensaje de respuesta; incluí `["Deny","Audit"]` si querés además la anotación estructurada, que es la mejor opción porque te da una única consulta de detección uniforme entre namespaces con y sin enforcement.

Notá también que `Warn` es una tercera acción, que muestra el mensaje en el stderr del cliente — útil durante el rollout, invisible para el audit log.

### Ejercicio 8 — solución de referencia

`/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 4. Drop reads of ConfigMaps in kube-system — MUST come first
  - level: None
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["configmaps"]
    namespaces: ["kube-system"]

  # 3. Secret changes at Metadata
  - level: Metadata
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["secrets"]

  # 5. Everything else at Metadata
  - level: Metadata
```

Flags agregados a `spec.containers[0].command`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxsize=100
    - --audit-log-maxbackup=5
    - --audit-log-maxage=7
```

Volúmenes — notá que la política es un **archivo** en `/etc/kubernetes/audit-policy.yaml`, no un directorio, así que `type: File`:

```yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit/
      name: audit-log
      readOnly: false
```

```yaml
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit/
      type: DirectoryOrCreate
```

Verificación independiente, un comando por requisito:

```bash
# req 2 — must return 0
sudo jq -r 'select(.stage=="RequestReceived")' /var/log/kubernetes/audit/audit.log | wc -l

# req 3 — must show the create at Metadata level
kubectl -n default create secret generic drill --from-literal=a=b
sudo jq -c 'select(.objectRef.resource=="secrets" and .objectRef.name=="drill")
  | {level, verb, ns: .objectRef.namespace}' /var/log/kubernetes/audit/audit.log

# req 4 — must return 0
kubectl -n kube-system get configmaps >/dev/null
sudo jq -r 'select(.objectRef.resource=="configmaps" and .objectRef.namespace=="kube-system"
  and (.verb|test("get|list|watch")))' /var/log/kubernetes/audit/audit.log | wc -l
```

**A30.** Sí — `verbs: ["create","update","patch","delete","deletecollection"]` es obligatorio. "Cambios" excluye las lecturas, y un cluster con muchos Secrets realiza muchos más `get`/`watch` sobre Secrets que escrituras (cada kubelet observa los Secrets montados en sus Pods, cada controlador vuelve a leer sus credenciales). Omitir `verbs` no es solo más ruidoso — es *incorrecto* frente al requisito planteado, y los correctores revisan la regla, no el log.

El matiz de corrección en la otra dirección: `patch` y `deletecollection` son fáciles de olvidar, y ambos son mutaciones genuinas. Una regla con solo `create,update,delete` se pierde silenciosamente un `kubectl patch secret` — que es lo que emite realmente un `create --dry-run | apply` o una rotación manejada por un controlador.

**A31.** La regla `level: None` para los ConfigMaps de `kube-system` debe ir **antes** del catch-all `level: Metadata`. Como gana la primera coincidencia y el catch-all coincide con todo, cualquier orden con el catch-all por encima de la regla de descarte reduce la política entera a "loguear todo en Metadata" y falla silenciosamente el requisito 4 — mientras sigue pareciendo una política de tres reglas que menciona kube-system.

La prueba de que el descarte está vivo (el tercer comando de arriba): generá el tráfico, y después contá los eventos coincidentes. Un conteo distinto de cero significa que la regla es inalcanzable. Que `wc -l` devuelva `0` después de un `kubectl -n kube-system get configmaps` *deliberado* es toda la verificación — contar cero sin haber generado antes el tráfico no prueba nada.

</details>

---

## Referencias

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes Documentation, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes API Reference, *Audit Configuration (`audit.k8s.io/v1`)* — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes Documentation, *kube-apiserver command-line reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes Documentation, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes Documentation, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Documentation, *User impersonation* — https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- Kubernetes Documentation, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes Documentation, *Debugging Kubernetes Nodes With Crictl* — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/