# CKS 4.3 — Asegurá tu Cadena de Suministro

## Ejercicios Guiados: Registries Permitidos, Firma y Validación de Artefactos

> **Dominio del examen:** Supply Chain Security (20% de CKS v1.34) — competencia *"Secure your supply chain (permitted registries, sign and validate artifacts, etc.)"*
> **Referencia:** [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

---

## Topología del laboratorio y fijado de versiones

Cada ejercicio de abajo asume este entorno. Fijá estas versiones — la sintaxis de las políticas CEL, la ruta del plugin de registry de containerd y el esquema de políticas de Kyverno se movieron entre releases menores, y correr silenciosamente una versión distinta es la razón número uno por la que estos labs "no funcionan".

| Componente | Versión | Notas |
|---|---|---|
| Kubernetes | v1.34.x, `kubeadm` | 1 control-plane (`cp01`, `10.0.1.10`), 2 workers (`w01`, `w02`) |
| Container runtime | containerd 2.0+ | La ruta del plugin CRI difiere de 1.7 — ver Ejercicio 7 |
| cosign | v2.4.x | La sintaxis de v1 (`COSIGN_EXPERIMENTAL=1`) ya no existe |
| Kyverno | v1.14.x | Helm chart `kyverno/kyverno` |
| syft | v1.x | Generación de SBOM |
| Registry | `registry:2.8.3` | corre in-cluster como static Pod en `registry.internal:5000` |

```
                         ┌──────────────────────────────────────────────┐
                         │              cp01 (control plane)            │
   kubectl apply ──────► │  kube-apiserver                              │
                         │    ├─ ImagePolicyWebhook ──► image-policy    │  Exercise 3
                         │    ├─ ValidatingAdmissionPolicy (CEL)        │  Exercise 2
                         │    └─ ValidatingWebhook ──► Kyverno          │  Exercise 5
                         │  registry.internal:5000 (static Pod)         │  Exercise 0
                         └──────────────────────────────────────────────┘
                                         │ scheduled Pod
                                         ▼
                         ┌──────────────────────────────────────────────┐
                         │              w01 / w02 (kubelet)             │
                         │   containerd ─ /etc/containerd/certs.d/      │  Exercise 7
                         │     ├─ registry.internal:5000/hosts.toml     │
                         │     └─ _default/hosts.toml  (deny fallback)  │
                         └──────────────────────────────────────────────┘
```

Los cuatro puntos de control están deliberadamente estratificados. La admisión (Ejercicios 2, 3, 5) es *política*; el allowlist del runtime (Ejercicio 7) es *aplicación de último recurso* para cualquier cosa que evada el API server — static Pods, un controller comprometido, un kubelet que descarga directamente.

---

## Ejercicio 0 — Levantar un registry privado con una cadena TLS real

Los ejercicios de firma no valen nada contra un registry en texto plano, porque no podés demostrar la distinción entre *confianza de transporte* y *confianza de artefacto*. Construí el registry como corresponde.

**Pasos**

1. En `cp01`, creá una CA de laboratorio y un certificado de servidor para el registry:

```bash
mkdir -p /etc/registry/certs && cd /etc/registry/certs

# Lab CA
openssl req -x509 -newkey rsa:4096 -sha256 -days 90 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=teach-plat-lab-ca"

# Registry server key + CSR
openssl req -newkey rsa:4096 -nodes \
  -keyout registry.key -out registry.csr -subj "/CN=registry.internal"

# Sign it, with the SANs that actually matter
openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out registry.crt -days 90 -sha256 \
  -extfile <(printf "subjectAltName=DNS:registry.internal,IP:10.0.1.10\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth")

openssl x509 -in registry.crt -noout -text | grep -A1 "Subject Alternative Name"
```

Esperado:

```console
            X509v3 Subject Alternative Name:
                DNS:registry.internal, IP Address:10.0.1.10
```

2. Agregá la resolución de nombres en **los tres nodos** (`cp01`, `w01`, `w02`):

```bash
echo "10.0.1.10 registry.internal" >> /etc/hosts
```

3. Corré el registry como static Pod en `cp01` para que sobreviva a los reinicios sin depender del scheduler:

```yaml
# /etc/kubernetes/manifests/registry.yaml
apiVersion: v1
kind: Pod
metadata:
  name: registry
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  containers:
    - name: registry
      image: registry:2.8.3
      env:
        - name: REGISTRY_HTTP_ADDR
          value: "0.0.0.0:5000"
        - name: REGISTRY_HTTP_TLS_CERTIFICATE
          value: /certs/registry.crt
        - name: REGISTRY_HTTP_TLS_KEY
          value: /certs/registry.key
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
      volumeMounts:
        - { name: certs, mountPath: /certs, readOnly: true }
        - { name: data,  mountPath: /var/lib/registry }
      resources:
        requests: { cpu: 100m, memory: 128Mi }
  volumes:
    - name: certs
      hostPath: { path: /etc/registry/certs, type: Directory }
    - name: data
      hostPath: { path: /var/lib/registry, type: DirectoryOrCreate }
```

4. Verificá que el registry responde sobre TLS y que la cadena valida:

```bash
curl --cacert /etc/registry/certs/ca.crt https://registry.internal:5000/v2/ -i
```

Esperado:

```console
HTTP/2 200
content-type: application/json; charset=utf-8
docker-distribution-api-version: registry/2.0
...
{}
```

5. Enseñale a containerd a confiar en la CA en cada nodo. Creá el directorio por host (el nombre del directorio **debe** incluir el puerto cuando la referencia lo incluye):

```bash
mkdir -p /etc/containerd/certs.d/registry.internal:5000
cp /etc/registry/certs/ca.crt /etc/containerd/certs.d/registry.internal:5000/ca.crt

cat > /etc/containerd/certs.d/registry.internal:5000/hosts.toml <<'EOF'
server = "https://registry.internal:5000"

[host."https://registry.internal:5000"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/registry.internal:5000/ca.crt"
EOF
```

6. Apuntá containerd a ese directorio. **containerd 2.x** usa una clave de plugin distinta a la de 1.7 — verificá primero:

```bash
containerd --version
```

```toml
# containerd 2.x — /etc/containerd/config.toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

# containerd 1.7.x — /etc/containerd/config.toml
# [plugins."io.containerd.grpc.v1.cri".registry]
#   config_path = "/etc/containerd/certs.d"
```

```bash
systemctl restart containerd
crictl pull registry.internal:5000/library/busybox:1.36 2>&1 | tail -2
```

En este punto el pull va a fallar con un 404 — todavía no hay nada pusheado. Ese es el fallo correcto; un error de TLS acá significa que el paso 5/6 está mal.

### Preguntas de control — bloque 0

- **Q0.1** — Copiaste `ca.crt` en `certs.d` y también en el trust store del sistema operativo con `update-ca-certificates`. ¿Cuál consulta containerd realmente cuando descarga de `registry.internal:5000`, y por qué importa la distinción en un cluster air-gapped?
- **Q0.2** — El Pod del registry es un static Pod. Nombrá dos consecuencias relevantes para la cadena de suministro de esa elección — una que te ayuda y una que es una debilidad de seguridad que tenés que compensar en otro lado.
- **Q0.3** — Tu compañero "arregla" un fallo de pull agregando `skip_verify = true` a `hosts.toml`. ¿Exactamente qué ataque vuelve a habilitar eso, y la firma de imágenes (Ejercicio 4) lo compensa?

---

## Ejercicio 1 — Mapear la superficie de la cadena de suministro y fijar por digest

No podés asegurar una cadena de suministro que no enumeraste. Esto es lo primero que hay que hacer en cualquier cluster que heredes, y es un hábito de examen rápido y de alto valor.

**Pasos**

1. Enumerá cada imagen distinta *solicitada* a lo largo del cluster, agrupada por registry:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Esperado (abreviado):

```console
registry.k8s.io/coredns/coredns:v1.12.1
registry.k8s.io/etcd:3.6.4-0
registry.k8s.io/kube-apiserver:v1.34.1
docker.io/library/registry:2.8.3
docker.io/calico/node:v3.29.1
```

2. Extraé solo los hosts de registry — este es tu allowlist *de facto*, la entrada para el Ejercicio 2:

```bash
kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | sed -E 's|^([^/]*\.[^/]*(:[0-9]+)?)/.*|\1|; t; s|^.*$|docker.io (implicit)|' \
  | sort | uniq -c | sort -rn
```

Esperado:

```console
     18 registry.k8s.io
      6 docker.io (implicit)
      3 quay.io
```

3. Ahora compará la imagen *solicitada* contra la imagen *resuelta*. `.spec` es lo que pidió el autor; `.status.containerStatuses[].imageID` es lo que el nodo realmente corrió:

```bash
kubectl run drift --image=nginx:1.27 --restart=Never
kubectl wait --for=condition=Ready pod/drift --timeout=60s

kubectl get pod drift -o jsonpath='requested: {.spec.containers[0].image}{"\n"}resolved:  {.status.containerStatuses[0].imageID}{"\n"}'
```

Esperado:

```console
requested: nginx:1.27
resolved:  docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

4. Re-fijá la misma carga de trabajo por digest y probá que el tag ahora es irrelevante:

```bash
DIGEST=$(kubectl get pod drift -o jsonpath='{.status.containerStatuses[0].imageID}' | cut -d@ -f2)
kubectl delete pod drift

kubectl run pinned --restart=Never \
  --image="docker.io/library/nginx@${DIGEST}" \
  --image-pull-policy=IfNotPresent
kubectl get pod pinned -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Esperado:

```console
docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

5. Inspeccioná lo que el runtime cree sobre esa imagen, evadiendo por completo el API server:

```bash
NODE=$(kubectl get pod pinned -o jsonpath='{.spec.nodeName}')
ssh "$NODE" 'crictl images --digests | grep nginx'
ssh "$NODE" 'crictl inspecti docker.io/library/nginx@'"$DIGEST"' | jq ".status.repoDigests, .status.repoTags"'
```

Esperado:

```console
["docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c"]
["docker.io/library/nginx:1.27"]
```

### Preguntas de control — bloque 1

- **Q1.1** — Un Deployment especifica `image: internal/app:v2.3.1` con `imagePullPolicy: IfNotPresent`. Un atacante con permisos de push al registry sobrescribe `v2.3.1`. ¿Qué Pods existentes están comprometidos, qué Pods nuevos están comprometidos, y por qué la respuesta es "depende del nodo"?
- **Q1.2** — Fijar por digest derrota la mutación de tags. Nombrá dos costos operativos concretos que introduce, y el mecanismo que usarías para mantener los digests actualizados sin abandonar el fijado.
- **Q1.3** — `.status.containerStatuses[].imageID` devolvió un digest. ¿Es ese digest el digest del manifest de la imagen que referenció el autor, o algo distinto? ¿Qué cambia para una imagen multi-arch?
- **Q1.4** — ¿Por qué enumerar solo `.spec.containers[*].image` es un inventario incompleto de la cadena de suministro del cluster? Listá al menos tres fuentes de imágenes que se pierde.

---

## Ejercicio 2 — Allowlist de registries con ValidatingAdmissionPolicy (CEL, in-tree)

Esta es la forma moderna y sin dependencias de restringir registries: sin webhook externo, sin Pod extra, sin riesgo de disponibilidad por un controller de terceros. Es GA y está disponible en v1.34 como `admissionregistration.k8s.io/v1`.

**Pasos**

1. Guardá el allowlist como parámetros para que la política sea orientada a datos — vas a editar un ConfigMap, no una política, cuando la lista cambie:

```yaml
# allowlist-params.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: kube-system
data:
  # newline-separated prefixes; matched with startsWith()
  prefixes: |
    registry.internal:5000/
    registry.k8s.io/
```

```bash
kubectl apply -f allowlist-params.yaml
```

2. Escribí la política. Prestá atención al manejo de `initContainers` / `ephemeralContainers`: son campos opcionales, así que una expresión ingenua `object.spec.initContainers` lanza error en tiempo de evaluación y — con `failurePolicy: Fail` — deja inservible toda creación de Pods en el cluster.

```yaml
# vap-allowed-registries.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries.supplychain.local
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # never gate the control plane's own bootstrap path
    - name: exclude-system-namespaces
      expression: >-
        !(request.namespace in ['kube-system', 'kube-node-lease'])
  variables:
    - name: prefixes
      expression: >-
        params.data['prefixes'].split('\n').filter(p, p != '')
    - name: allImages
      expression: >-
        object.spec.containers.map(c, c.image) +
        (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
    - name: violations
      expression: >-
        variables.allImages.filter(img,
          !variables.prefixes.exists(p, img.startsWith(p)))
  validations:
    - expression: "size(variables.violations) == 0"
      messageExpression: >-
        'image(s) from a non-permitted registry: ' + variables.violations.join(', ') +
        ' — permitted prefixes: ' + variables.prefixes.join(', ')
      reason: Forbidden
```

3. Vinculala. El binding es lo que efectivamente enciende la política; una política sin binding es inerte.

```yaml
# vap-allowed-registries-binding.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries.supplychain.local
  validationActions: ["Deny", "Audit"]
  paramRef:
    name: registry-allowlist
    namespace: kube-system
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system"]
```

```bash
kubectl apply -f vap-allowed-registries.yaml -f vap-allowed-registries-binding.yaml
```

4. Probá el camino de denegación:

```bash
kubectl create namespace app
kubectl -n app run bad --image=docker.io/library/nginx:1.27 --restart=Never
```

Esperado:

```console
The pods "bad" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.supplychain.local'
with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted
registry: docker.io/library/nginx:1.27 — permitted prefixes: registry.internal:5000/, registry.k8s.io/
```

5. Probá el camino de permitido, y después el caso sutil — un `initContainer` de un registry malo con un container principal bueno:

```bash
kubectl -n app run good --image=registry.k8s.io/pause:3.10 --restart=Never
# → pod/good created

kubectl -n app apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: sneaky }
spec:
  initContainers:
    - name: fetch
      image: docker.io/library/busybox:1.36
      command: ["true"]
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
EOF
```

Esperado:

```console
Error from server (Forbidden): error when creating "STDIN": pods "sneaky" is forbidden:
ValidatingAdmissionPolicy '...' denied request: image(s) from a non-permitted registry:
docker.io/library/busybox:1.36 — ...
```

6. Ahora la trampa que agarra a la mayoría. Creá un **Deployment** con una imagen prohibida:

```bash
kubectl -n app create deployment ghost --image=docker.io/library/redis:7
```

Esperado:

```console
deployment.apps/ghost created
```

El Deployment se acepta. Averiguá dónde aterrizó realmente la aplicación de la política:

```bash
kubectl -n app get deploy ghost
kubectl -n app describe replicaset -l app=ghost | tail -8
```

Esperado:

```console
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
ghost   0/1     0            0           25s

Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  10s   replicaset-controller  Error creating: pods "ghost-7d9c..."
    is forbidden: ValidatingAdmissionPolicy 'allowed-registries.supplychain.local' ...
```

7. Confirmá que el rastro de auditoría existe incluso para peticiones permitidas, verificando que la política se está evaluando:

```bash
kubectl get validatingadmissionpolicy allowed-registries.supplychain.local \
  -o jsonpath='{.status.typeChecking}{"\n"}'
```

Un resultado vacío (`{}` o nada) significa que el type-checker de CEL no encontró problemas contra los tipos coincidentes. Una salida no vacía lista advertencias de expresiones — leelas siempre antes de confiar en la política.

### Preguntas de control — bloque 2

- **Q2.1** — En el paso 6 el Deployment se creó y solo falló el ReplicaSet. Explicá con precisión por qué, y dá dos formas distintas de hacer que el fallo aparezca en el momento de `kubectl create deployment`. Indicá el trade-off de cada una.
- **Q2.2** — Tu entrada del allowlist es `registry.internal:5000/`. Un atacante pushea a `registry.internal:5000.evil.com/team/app:v1`. ¿La política lo permite? Ahora cambiá el prefijo a `registry.internal` (sin barra) y respondé de nuevo. ¿Cuál es la lección general sobre el matching por prefijo en referencias de imagen?
- **Q2.3** — ¿Por qué es necesario acá que `matchConditions` excluya `kube-system`, y qué pasaría en el próximo reinicio del control plane si pusieras `failurePolicy: Fail` sin esa exclusión *y* el ConfigMap fuera eliminado?
- **Q2.4** — `parameterNotFoundAction: Deny` versus `Allow`: describí el comportamiento exacto del cluster en cada caso si alguien ejecuta `kubectl -n kube-system delete cm registry-allowlist`.
- **Q2.5** — La política verifica `object.spec.containers`. Un usuario actualiza el campo `image` de un Pod en ejecución vía `kubectl set image pod/...`. ¿Se dispara la política? ¿Y con `kubectl debug` inyectando un ephemeral container?
- **Q2.6** — VAP no puede reescribir la petición. Nombrá un control de cadena de suministro que por lo tanto *no podés* implementar solo con `ValidatingAdmissionPolicy`, y qué usarías en su lugar.

---

## Ejercicio 3 — ImagePolicyWebhook: la compuerta del lado del API server

`ImagePolicyWebhook` es el plugin de admisión in-tree que le pregunta a un servicio externo "¿puedo correr esta imagen?". Es el ejercicio canónico de CKS para este tema porque requiere editar correctamente el manifest del static Pod del API server — incluidos los volume mounts que todos se olvidan.

**Pasos**

1. Construí un backend de política mínimo en `cp01`. Deniega cualquier cosa que no venga de `registry.internal:5000` y cualquier cosa etiquetada `:latest`:

```python
# /opt/imagepolicy/server.py
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ALLOWED_PREFIX = "registry.internal:5000/"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        review = json.loads(body)
        images = [c["image"] for c in review["spec"].get("containers", [])]
        denied = [i for i in images
                  if not i.startswith(ALLOWED_PREFIX) or i.endswith(":latest")]

        # Break-glass: only annotations matching *.image-policy.k8s.io/* reach us
        ann = review["spec"].get("annotations", {}) or {}
        breakglass = ann.get("lab.image-policy.k8s.io/break-glass") == "true"

        allowed = (not denied) or breakglass
        status = {"allowed": allowed}
        if not allowed:
            status["reason"] = ("images rejected by policy backend: "
                                + ", ".join(denied))
        status["auditAnnotations"] = {"policy-backend": "v1", "evaluated": str(len(images))}

        resp = json.dumps({"apiVersion": "imagepolicy.k8s.io/v1alpha1",
                           "kind": "ImageReview", "status": status}).encode()
        sys.stderr.write(f"review ns={review['spec'].get('namespace')} "
                         f"images={images} allowed={allowed}\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, *a): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/opt/imagepolicy/tls.crt", "/opt/imagepolicy/tls.key")
srv = HTTPServer(("127.0.0.1", 8443), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
```

2. Emití su certificado de servicio desde la CA del laboratorio y arrancalo:

```bash
mkdir -p /opt/imagepolicy && cd /opt/imagepolicy
openssl req -newkey rsa:2048 -nodes -keyout tls.key -out tls.csr -subj "/CN=image-policy"
openssl x509 -req -in tls.csr -CA /etc/registry/certs/ca.crt -CAkey /etc/registry/certs/ca.key \
  -CAcreateserial -out tls.crt -days 90 -sha256 \
  -extfile <(printf "subjectAltName=IP:127.0.0.1,DNS:image-policy\nextendedKeyUsage=serverAuth")

nohup python3 /opt/imagepolicy/server.py >/var/log/imagepolicy.log 2>&1 &
ss -ltnp | grep 8443
```

Esperado:

```console
LISTEN 0  5   127.0.0.1:8443   0.0.0.0:*   users:(("python3",pid=4711,fd=4))
```

3. Escribí el kubeconfig que el API server va a usar para llegar al backend:

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-policy-backend
    cluster:
      certificate-authority: /etc/kubernetes/admission/ca.crt
      server: https://127.0.0.1:8443/image-policy
users:
  - name: kube-apiserver
    user: {}
contexts:
  - name: webhook
    context:
      cluster: image-policy-backend
      user: kube-apiserver
current-context: webhook
preferences: {}
```

```bash
mkdir -p /etc/kubernetes/admission
cp /etc/registry/certs/ca.crt /etc/kubernetes/admission/ca.crt
```

4. Escribí el archivo de configuración de admisión. **`defaultAllow` es acá toda la decisión de seguridad:**

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: false
```

5. Conectalo al API server. Editá `/etc/kubernetes/manifests/kube-apiserver.yaml` — **tres** ediciones, y las últimas dos son donde los candidatos pierden el punto:

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        # (1) enable the plugin — append, never replace the existing list
        - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
        # (2) point it at the config
        - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
        ...
      volumeMounts:
        # (3a) the API server container cannot see host paths unless you mount them
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
  volumes:
    # (3b)
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

6. El kubelet reinicia el static Pod cuando cambia el archivo. Miralo volver — y sabé cómo depurarlo si no vuelve:

```bash
watch -n2 'crictl ps -a --name kube-apiserver --latest'
# once Running:
kubectl get --raw='/readyz?verbose' | tail -5
```

Si el API server nunca vuelve, `kubectl` está muerto y tenés que meterte por debajo:

```bash
crictl ps -a --name kube-apiserver --latest -q | xargs crictl logs 2>&1 | tail -20
```

Fallo típico y su significado:

```console
Error: unknown admission plugin: ImagePolicyWebhook   → typo in --enable-admission-plugins
error reading admission control config: open /etc/kubernetes/admission/admission-config.yaml:
  no such file or directory                           → you forgot the volume / volumeMount
```

7. Probá la compuerta:

```bash
kubectl -n app run bad2 --image=docker.io/library/alpine:3.20 --restart=Never -- sleep 3600
```

Esperado:

```console
Error from server (Forbidden): pods "bad2" is forbidden: image policy webhook backend denied
one or more images: images rejected by policy backend: docker.io/library/alpine:3.20
```

8. Ejercitá el camino de break-glass y observá que la anotación llegó al backend:

```bash
kubectl -n app apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: breakglass
  annotations:
    lab.image-policy.k8s.io/break-glass: "true"
spec:
  containers:
    - name: c
      image: docker.io/library/alpine:3.20
      command: ["sleep", "3600"]
EOF

tail -3 /var/log/imagepolicy.log
```

Esperado:

```console
pod/breakglass created
review ns=app images=['docker.io/library/alpine:3.20'] allowed=True
```

*(Si el `ValidatingAdmissionPolicy` del Ejercicio 2 sigue vinculado, este Pod es rechazado por esa política en su lugar — una demostración útil de que la admisión de validación es un AND de todas las compuertas. Borrá temporalmente el binding para aislar este ejercicio.)*

9. Probá el comportamiento fail-closed, que es toda la razón por la que pusiste `defaultAllow: false`:

```bash
kill %1                      # stop the policy backend
kubectl -n app run any --image=registry.internal:5000/library/pause:3.10 --restart=Never
```

Esperado:

```console
Error from server (Forbidden): pods "any" is forbidden: Post
"https://127.0.0.1:8443/image-policy": dial tcp 127.0.0.1:8443: connect: connection refused
```

```bash
nohup python3 /opt/imagepolicy/server.py >>/var/log/imagepolicy.log 2>&1 &
```

### Preguntas de control — bloque 3

- **Q3.1** — `defaultAllow: true` versus `false`. Describí el modo de fallo de cada uno con el backend caído, e indicá el único escenario de producción en el que `true` es la elección defendible.
- **Q3.2** — El API server recibió `connection refused` y denegó. ¿Qué dos campos de configuración determinan *cuánto tiempo* y *con qué frecuencia* reintentó antes de rendirse, y cuál es el riesgo de ponerlos demasiado altos?
- **Q3.3** — Solo las anotaciones cuyas claves contienen `.image-policy.k8s.io/` se reenvían al backend. Dado el diseño de break-glass del paso 8, escribí el control a nivel RBAC que impide que cualquier usuario de namespace evada la compuerta. ¿Por qué el break-glass basado en anotaciones es estructuralmente distinto de una excepción de RBAC?
- **Q3.4** — `allowTTL: 50` cachea una decisión de permitido. Un tag de imagen se re-pushea con contenido malicioso y el digest cambia. ¿El caché lo deja pasar? ¿Cuál es la clave del caché?
- **Q3.5** — `ImagePolicyWebhook` solo inspecciona recursos de tipo `Pod`, y no puede mutar. Enumerá tres evasiones de cadena de suministro que se desprenden directamente de esas dos propiedades.
- **Q3.6** — Agregaste `--enable-admission-plugins=ImagePolicyWebhook` y el cluster perdió las protecciones de `NodeRestriction`. Explicá qué salió mal y cómo interactúa `--enable-admission-plugins` con el conjunto de plugins por defecto.

---

## Ejercicio 4 — Firmar y verificar artefactos con cosign

El allowlist de registries responde *de dónde* vino una imagen. La firma responde *quién la construyó y si cambió*. Los dos son ortogonales; necesitás ambos.

**Pasos**

1. Instalá cosign y confirmá la versión:

```bash
curl -sSLo /usr/local/bin/cosign \
  https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64
chmod +x /usr/local/bin/cosign
cosign version --json | jq -r '.gitVersion, .goVersion'
```

Esperado:

```console
v2.4.1
go1.23.2
```

2. Sembrá el registry privado con una imagen real, y después anotá el *digest*, que es lo que vas a firmar:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt   # cosign/crane must trust the lab CA

crane copy docker.io/library/nginx:1.27 registry.internal:5000/prod/nginx:1.27
DIGEST=$(crane digest registry.internal:5000/prod/nginx:1.27)
echo "$DIGEST"
```

Esperado:

```console
sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

3. Generá un par de claves y firmá **por digest, nunca por tag**:

```bash
cd /root/keys
COSIGN_PASSWORD='' cosign generate-key-pair
ls -l cosign.key cosign.pub

COSIGN_PASSWORD='' cosign sign --key cosign.key --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${DIGEST}"
```

Esperado:

```console
Pushing signature to: registry.internal:5000/prod/nginx
```

4. Mirá *dónde* vive físicamente la firma. Es un artefacto OCI común y corriente en el mismo repositorio, bajo un tag derivado:

```bash
cosign triangulate "registry.internal:5000/prod/nginx@${DIGEST}"
crane ls registry.internal:5000/prod/nginx
cosign tree "registry.internal:5000/prod/nginx@${DIGEST}"
```

Esperado:

```console
registry.internal:5000/prod/nginx:sha256-d2b2f2b2ee1a...9a1c.sig

1.27
sha256-d2b2f2b2ee1a...9a1c.sig

📦 Supply Chain Security Related artifacts for an image: registry.internal:5000/prod/nginx@sha256:d2b2...
└── 🔐 Signatures for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.sig
   └── 🍒 sha256:6d1f...
```

5. Verificá, y leé el payload en lugar de confiar solo en el código de salida:

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  "registry.internal:5000/prod/nginx@${DIGEST}" | jq '.[0].critical'
```

Esperado:

```console
Verification for registry.internal:5000/prod/nginx@sha256:d2b2... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

{
  "identity": { "docker-reference": "registry.internal:5000/prod/nginx" },
  "image": { "docker-manifest-digest": "sha256:d2b2f2b2ee1a...9a1c" },
  "type": "cosign container image signature"
}
```

6. Demostrá que la firma está ligada al contenido, no a un nombre. Pusheá una imagen *distinta* bajo el mismo tag y re-verificá:

```bash
crane copy docker.io/library/nginx:1.25 registry.internal:5000/prod/nginx:1.27
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  registry.internal:5000/prod/nginx:1.27
```

Esperado:

```console
Error: no matching signatures:
  ...
main.go:74: error during command execution: no matching signatures
```

```bash
echo $?
```

```console
1
```

7. Verificá con la clave *equivocada* para ver el texto de fallo distinto — tenés que poder distinguir "sin firmar" de "firmado por otro" durante un incidente:

```bash
COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix attacker
cosign verify --key attacker.pub --insecure-ignore-tlog=true \
  "registry.internal:5000/prod/nginx@${DIGEST}"
```

Esperado:

```console
Error: no matching signatures:
searching log query: [POST /api/v1/log/entries/retrieve] ... (or, offline)
  crypto/rsa: verification error
```

8. Ahora el flujo keyless, que es lo que usa el CI real. En una workstation con acceso a navegador:

```bash
cosign sign --yes docker.io/youruser/demo@sha256:...
# → opens an OIDC flow, mints a 10-minute Fulcio certificate,
#   records the entry in the Rekor transparency log

cosign verify docker.io/youruser/demo@sha256:... \
  --certificate-identity-regexp='^https://github\.com/youruser/demo/\.github/workflows/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' | jq '.[0].optional'
```

Esperado (abreviado):

```console
{
  "Bundle": { "SignedEntryTimestamp": "MEUCIQ...", "Payload": { "logIndex": 152893441, ... } },
  "Issuer": "https://token.actions.githubusercontent.com",
  "Subject": "https://github.com/youruser/demo/.github/workflows/release.yml@refs/tags/v1.0.0"
}
```

9. Guardá la clave de verificación donde un controller in-cluster pueda consumirla, y confirmá que cosign puede firmar directamente desde un Secret:

```bash
kubectl create namespace cosign-system
COSIGN_PASSWORD='' cosign generate-key-pair k8s://cosign-system/prod-signing-key
kubectl -n cosign-system get secret prod-signing-key -o jsonpath='{.data}' | jq 'keys'
```

Esperado:

```console
["cosign.key","cosign.password","cosign.pub"]
```

### Preguntas de control — bloque 4

- **Q4.1** — En el paso 6 el tag fue reapuntado y la verificación falló, sin embargo el artefacto `.sig` quedó intacto en el registry. Explicá el mecanismo: ¿qué calcula y compara cosign exactamente?
- **Q4.2** — Firmaste con `--tlog-upload=false` y verificaste con `--insecure-ignore-tlog=true`. ¿Qué propiedad de seguridad resignaste, y describí el ataque concreto que el transparency log de Rekor está diseñado para detectar.
- **Q4.3** — La firma keyless produce un certificado válido por ~10 minutos, y sin embargo la verificación funciona meses después. Explicá cómo es posible eso, y nombrá los dos servicios de Sigstore involucrados y sus roles distintos.
- **Q4.4** — `cosign verify` sobre un *tag* es peligroso incluso cuando tiene éxito. Describí la ventana TOCTOU entre `cosign verify nginx:1.27` en un paso de CI y el kubelet descargando `nginx:1.27`, y dá las dos soluciones.
- **Q4.5** — Un atacante gana acceso de push a `registry.internal:5000` pero no a tu clave de firma. Listá todo lo que puede y no puede hacerle a un consumidor que impone verificación de firmas. Incluí la denegación de servicio en tu respuesta.
- **Q4.6** — `cosign generate-key-pair k8s://ns/name` puso la clave *privada* en un Secret. Justificá o rechazá esta práctica para una clave de firma de producción, y nombrá las alternativas.

---

## Ejercicio 5 — Imponer firmas en la admisión con Kyverno

`ImagePolicyWebhook` no puede verificar firmas y no puede mutar. Kyverno hace las dos cosas: verifica contra tu clave pública y reescribe el tag al digest verificado en el mismo pase de admisión, cerrando la ventana TOCTOU de Q4.4.

**Pasos**

1. Instalá Kyverno y dale confianza en la CA del laboratorio (un registry privado con una CA privada es la causa número uno de errores `failed to fetch image` en `verifyImages`):

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update

kubectl create namespace kyverno
kubectl -n kyverno create configmap lab-ca --from-file=ca.crt=/etc/registry/certs/ca.crt

helm install kyverno kyverno/kyverno -n kyverno --version 3.4.x \
  --set admissionController.container.extraEnvVars[0].name=SSL_CERT_DIR \
  --set admissionController.container.extraEnvVars[0].value=/etc/ssl/lab \
  --set admissionController.extraVolumes[0].name=lab-ca \
  --set admissionController.extraVolumes[0].configMap.name=lab-ca \
  --set admissionController.extraVolumeMounts[0].name=lab-ca \
  --set admissionController.extraVolumeMounts[0].mountPath=/etc/ssl/lab

kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

2. Escribí la política de verificación de imágenes:

```yaml
# kyverno-verify-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-internal-registry-signatures
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-prod-images
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kyverno"]
      verifyImages:
        - imageReferences:
            - "registry.internal:5000/prod/*"
          # rewrite tag → verified digest, atomically, in this same request
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...REPLACE_WITH_cosign.pub...
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true      # lab only — no public tlog entry
                    ctlog:
                      ignoreSCT: true       # lab only
```

> El esquema de Kyverno se corre entre versiones menores. Antes de aplicar, confirmá los nombres de los campos en *tu* build:
> `kubectl explain clusterpolicy.spec.validationFailureAction` y `kubectl explain clusterpolicy.spec.rules.verifyImages`. En versiones recientes `spec.validationFailureAction` y `spec.failurePolicy` están deprecados en favor de `spec.rules[].validate.failureAction` y `spec.webhookConfiguration.failurePolicy`.

```bash
sed -i "s|MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...REPLACE_WITH_cosign.pub...|$(grep -v -- '-----' /root/keys/cosign.pub | tr -d '\n')|" kyverno-verify-images.yaml
kubectl apply -f kyverno-verify-images.yaml
kubectl get cpol verify-internal-registry-signatures
```

Esperado:

```console
NAME                                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
verify-internal-registry-signatures  true        false        Enforce           True    8s
```

3. Re-firmá el tag `1.27` actual (lo reapuntaste en el paso 6 del Ejercicio 4) y desplegá por tag:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
D=$(crane digest registry.internal:5000/prod/nginx:1.27)
COSIGN_PASSWORD='' cosign sign --key /root/keys/cosign.key --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"

kubectl -n app run signed --restart=Never --image=registry.internal:5000/prod/nginx:1.27
kubectl -n app get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Esperado — notá que el tag **desapareció**, reemplazado por el digest que Kyverno verificó:

```console
pod/signed created
registry.internal:5000/prod/nginx@sha256:d2b2f2b2ee1a...9a1c
```

4. Pusheá una imagen sin firmar e intentá correrla:

```bash
crane copy docker.io/library/redis:7 registry.internal:5000/prod/redis:7
kubectl -n app run unsigned --restart=Never --image=registry.internal:5000/prod/redis:7
```

Esperado:

```console
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/app/unsigned was blocked due to the following policies

verify-internal-registry-signatures:
  verify-prod-images: 'failed to verify image registry.internal:5000/prod/redis:7:
    .attestors[0].entries[0].keys: no matching signatures'
```

5. Inspeccioná el registro legible por máquina de cada decisión de verificación:

```bash
kubectl -n app get policyreport -o wide
kubectl -n app get policyreport -o jsonpath='{.items[0].results[?(@.result=="fail")].message}{"\n"}'
```

6. Verificá que la mutación *no* es evadible pre-suministrando un digest distinto:

```bash
BAD=$(crane digest registry.internal:5000/prod/redis:7)
kubectl -n app run forged --restart=Never \
  --image="registry.internal:5000/prod/nginx@${BAD}"
```

Esperado:

```console
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
... failed to verify image registry.internal:5000/prod/nginx@sha256:...: no matching signatures
```

### Preguntas de control — bloque 5

- **Q5.1** — `mutateDigest: true` cambió el spec del Pod. ¿En qué fase de admisión ocurre eso, y por qué debe ocurrir *antes* de la validación en lugar de después? Explicá cómo esto cierra la ventana TOCTOU de Q4.4.
- **Q5.2** — `failurePolicy: Fail` en el webhook de Kyverno. Los propios Pods de Kyverno viven en el namespace `kyverno`, y la política hace `exclude` de ese namespace. Recorré qué pasa en un arranque en frío completo del cluster si falta esa exclusión.
- **Q5.3** — `required: true` versus `false` en `verifyImages`. Describí el comportamiento para una imagen que coincide con `imageReferences` pero no tiene ninguna firma, bajo cada configuración.
- **Q5.4** — La política solo coincide con `registry.internal:5000/prod/*`. Un atacante pushea a `registry.internal:5000/staging/app`. ¿Qué los detiene, y cuál de las capas que construiste en los Ejercicios 2, 3, 5 y 7 es la responsable?
- **Q5.5** — Kyverno necesitó `SSL_CERT_DIR` y una CA montada. Explicá la relación de confianza que esto establece y por qué es *separada* de la confianza de firma establecida por `publicKeys`. ¿Cuál, si se compromete, es peor?
- **Q5.6** — `count: 1` bajo `attestors`. Diseñá el cambio de política para "debe estar firmado por el sistema de build **y** contrafirmado por el release manager", y explicá qué significa `count` en relación a `entries`.

---

## Ejercicio 6 — Atestaciones SBOM y políticas sobre predicados

Una firma dice "este bloque de bytes es mío". Una *atestación* dice "acá hay una afirmación firmada *sobre* este bloque de bytes" — su SBOM, su procedencia de build, su resultado de escaneo. En esto se convierte operativamente "entendé tu cadena de suministro".

**Pasos**

1. Generá un SBOM CycloneDX para la imagen que firmaste:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
D=$(crane digest registry.internal:5000/prod/nginx:1.27)

syft "registry.internal:5000/prod/nginx@${D}" -o cyclonedx-json > sbom.cdx.json
jq '{bomFormat, specVersion, components: (.components|length)}' sbom.cdx.json
```

Esperado:

```console
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": 148
}
```

2. Adjuntalo como una **atestación firmada** (no un adjunto pelado):

```bash
COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key \
  --type cyclonedx --predicate sbom.cdx.json \
  --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"

cosign tree "registry.internal:5000/prod/nginx@${D}"
```

Esperado:

```console
📦 Supply Chain Security Related artifacts for an image: registry.internal:5000/prod/nginx@sha256:d2b2...
├── 🔐 Signatures for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.sig
│  └── 🍒 sha256:6d1f...
└── 💾 Attestations for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.att
   └── 🍒 sha256:9ab3...
```

3. Leé la atestación como lo hace un motor de políticas — decodificá el Statement in-toto envuelto en el sobre DSSE:

```bash
cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true "registry.internal:5000/prod/nginx@${D}" 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject: .subject[0].name, bomFormat: .predicate.bomFormat}'
```

Esperado:

```console
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://cyclonedx.org/bom",
  "subject": "registry.internal:5000/prod/nginx",
  "bomFormat": "CycloneDX"
}
```

4. Escribí una política CUE que afirme propiedades del predicado, no solo de la firma:

```cue
// sbom-policy.cue
predicateType: "https://cyclonedx.org/bom"
predicate: {
  bomFormat: "CycloneDX"
  // components must exist — an empty SBOM is a common CI failure that silently passes
  components: [_, ...]
}
```

```bash
cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true --policy sbom-policy.cue \
  "registry.internal:5000/prod/nginx@${D}" >/dev/null && echo "POLICY OK"
```

Esperado:

```console
will be validating against CUE policies: [sbom-policy.cue]
Verification for registry.internal:5000/prod/nginx@sha256:d2b2... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
POLICY OK
```

5. Probá que la política realmente muerde. Atestá un SBOM deliberadamente vacío a una segunda imagen y mirala fallar:

```bash
crane copy docker.io/library/busybox:1.36 registry.internal:5000/prod/busybox:1.36
D2=$(crane digest registry.internal:5000/prod/busybox:1.36)
jq '.components = []' sbom.cdx.json > sbom-empty.json

COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key --type cyclonedx \
  --predicate sbom-empty.json --tlog-upload=false --yes \
  "registry.internal:5000/prod/busybox@${D2}"

cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true --policy sbom-policy.cue \
  "registry.internal:5000/prod/busybox@${D2}"
```

Esperado:

```console
Error: 1 validation errors occurred
predicate.components: incomplete value [_, ...]
```

6. Adjuntá una atestación de *escaneo de vulnerabilidades*, que es lo que en la práctica controla un release:

```bash
trivy image --format cyclonedx --output vuln.cdx.json "registry.internal:5000/prod/nginx@${D}"
COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key \
  --type vuln --predicate vuln.cdx.json --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"
```

7. Requerí la atestación en la admisión extendiendo la política de Kyverno:

```yaml
      verifyImages:
        - imageReferences: ["registry.internal:5000/prod/*"]
          mutateDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
                    rekor: { ignoreTlog: true }
                    ctlog: { ignoreSCT: true }
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keys:
                        publicKeys: |-
                          -----BEGIN PUBLIC KEY-----
                          ...
                          -----END PUBLIC KEY-----
                        rekor: { ignoreTlog: true }
                        ctlog: { ignoreSCT: true }
              conditions:
                - all:
                    - key: "{{ bomFormat }}"
                      operator: Equals
                      value: "CycloneDX"
```

```bash
kubectl apply -f kyverno-verify-images.yaml
kubectl -n app run attested --restart=Never --image=registry.internal:5000/prod/nginx:1.27
kubectl -n app run notattested --restart=Never --image=registry.internal:5000/prod/redis:7
```

Esperado:

```console
pod/attested created
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
... image attestations verification failed, .attestations[0]: no matching attestations
```

### Preguntas de control — bloque 6

- **Q6.1** — Distinguí con precisión: una firma, una atestación y un *adjunto* (`cosign attach sbom`). ¿Cuál de los tres no está autenticado, y cuál es la consecuencia práctica?
- **Q6.2** — El Statement in-toto tiene un array `subject` con un digest. ¿Por qué ese campo es la parte que sostiene todo el esquema? ¿Qué se rompería si un motor de políticas verificara solo `predicateType` y la firma?
- **Q6.3** — Tu política de Kyverno requiere una atestación CycloneDX firmada con la misma clave que la imagen. Argumentá a favor y en contra de usar una clave *distinta* para las atestaciones, y describí qué nivel de build SLSA soporta esa separación ([slsa.dev/spec/v1.0/levels](https://slsa.dev/spec/v1.0/levels)).
- **Q6.4** — Una atestación SBOM se firma en tiempo de build y es inmutable. Un CVE se publica dos semanas después. Explicá por qué la atestación SBOM sigue siendo valiosa y por qué la atestación *vuln* del paso 6 debe tratarse de manera completamente distinta en política.
- **Q6.5** — Alguien propone imponer "cero vulnerabilidades CRITICAL" vía la atestación `vuln` en tiempo de admisión. Dá las dos objeciones técnicas más fuertes y el diseño que usarías en su lugar.

---

## Ejercicio 7 — Defensa en profundidad en el nodo: allowlist de containerd e higiene de credenciales

Todo lo anterior corre en el API server. Un static Pod, un kubelet comprometido, o `crictl` en el nodo evade todo eso. Cerrá ese camino.

**Pasos**

1. Demostrá primero la evasión — ese es el punto del ejercicio:

```bash
ssh w01 'crictl pull docker.io/library/alpine:3.20 && crictl images | grep alpine'
```

Esperado — las capas de admisión nunca fueron consultadas:

```console
Image is up to date for sha256:a8560b36e8b8...
docker.io/library/alpine   3.20   a8560b36e8b8   3.62MB
```

2. Ahora instalá un fallback de denegación por defecto en la configuración de registries de containerd. containerd ≥1.7 consulta `_default` cuando ningún directorio específico de host coincide:

```bash
ssh w01 'mkdir -p /etc/containerd/certs.d/_default'
ssh w01 'cat > /etc/containerd/certs.d/_default/hosts.toml' <<'EOF'
# Any registry without an explicit certs.d directory resolves here.
# 127.0.0.1:1 is a closed port: pulls fail fast and loudly.
server = "https://127.0.0.1:1"

[host."https://127.0.0.1:1"]
  capabilities = ["pull", "resolve"]
EOF
ssh w01 'systemctl restart containerd'
```

3. Creá las entradas de permiso explícitas para los registries que *sí* permitís (`registry.internal:5000` ya existe del Ejercicio 0):

```bash
ssh w01 'mkdir -p /etc/containerd/certs.d/registry.k8s.io'
ssh w01 'cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml' <<'EOF'
server = "https://registry.k8s.io"
[host."https://registry.k8s.io"]
  capabilities = ["pull", "resolve"]
EOF
ssh w01 'systemctl restart containerd'
```

4. Verificá el allowlist desde ambas direcciones:

```bash
ssh w01 'crictl rmi docker.io/library/alpine:3.20 >/dev/null 2>&1; crictl pull docker.io/library/alpine:3.20' 2>&1 | tail -2
ssh w01 'crictl pull registry.k8s.io/pause:3.10' 2>&1 | tail -1
ssh w01 'crictl pull registry.internal:5000/prod/nginx:1.27' 2>&1 | tail -1
```

Esperado:

```console
E... PullImage "docker.io/library/alpine:3.20" failed: rpc error: code = Unknown
  desc = failed to pull and unpack image ...: dial tcp 127.0.0.1:1: connect: connection refused

Image is up to date for sha256:873ed750...    # registry.k8s.io — allowed
Image is up to date for sha256:d2b2f2b2...    # registry.internal:5000 — allowed
```

5. Confirmá que el efecto se propaga a Kubernetes, y aprendé cómo se ve el fallo desde el lado de la API:

```bash
kubectl -n app run runtime-blocked --restart=Never \
  --image=docker.io/library/alpine:3.20 --overrides='{"spec":{"nodeName":"w01"}}' -- sleep 3600
sleep 15
kubectl -n app describe pod runtime-blocked | grep -A3 Events:
```

Esperado:

```console
Events:
  Type     Reason   Age   From     Message
  ----     ------   ----  ----     -------
  Warning  Failed   5s    kubelet  Failed to pull image "docker.io/library/alpine:3.20":
    ... dial tcp 127.0.0.1:1: connect: connection refused
  Warning  Failed   5s    kubelet  Error: ErrImagePull
```

6. Auditá las credenciales de registry — los pull secrets filtrados son la forma en que los atacantes obtienen acceso de *push*:

```bash
kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'

# decode one and check the scope of the credential
kubectl -n app get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'
```

7. Encontrá cada ServiceAccount que inyecta silenciosamente un pull secret en cada Pod que la usa:

```bash
kubectl get sa -A -o json | jq -r '
  .items[] | select(.imagePullSecrets != null)
  | "\(.metadata.namespace)/\(.metadata.name): \([.imagePullSecrets[].name]|join(","))"'
```

8. Preferí proveedores de credenciales a nivel de nodo por sobre Secrets de larga duración para registries en la nube — el kubelet obtiene un token de corta duración por cada pull:

```yaml
# /etc/kubernetes/credential-provider-config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages: ["*.dkr.ecr.*.amazonaws.com"]
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
```

```bash
# kubelet flags
--image-credential-provider-config=/etc/kubernetes/credential-provider-config.yaml
--image-credential-provider-bin-dir=/opt/kubelet/credential-providers
```

### Preguntas de control — bloque 7

- **Q7.1** — Ahora tenés restricciones de registry en la admisión (Ejercicio 2) *y* en containerd (este ejercicio). Dá un ataque concreto que solo detiene la capa de containerd, y un cambio legítimo concreto que solo atrapa la capa de admisión. ¿Por qué ninguna alcanza por sí sola?
- **Q7.2** — El fallback `_default` apunta a un puerto muerto. Nombrá el riesgo operativo que esto crea al reconstruir un nodo, y cómo detectarías la mala configuración antes de que tire abajo un cluster.
- **Q7.3** — Un Secret `kubernetes.io/dockerconfigjson` en el namespace `app` otorga acceso de push a `registry.internal:5000`. Trazá el camino completo de compromiso desde "el atacante puede hacer `exec` en un Pod de `app`" hasta "el atacante controla las imágenes de producción", y nombrá los dos controles que rompen la cadena.
- **Q7.4** — `imagePullSecrets` en un ServiceAccount versus en un Pod. ¿Cuál es más difícil de auditar y por qué? ¿Cuál obtiene gratis un atacante con alcance de namespace y permisos de `create pods`?
- **Q7.5** — El proveedor de credenciales del kubelet emite credenciales cacheadas por 12 horas. Compará su radio de impacto con el de un Secret `dockerconfigjson` estático a lo largo de tres ejes: rotación, alcance y valor de exfiltración.

---

## Ejercicio 8 — Simulacro de modos de fallo

Los controles de cadena de suministro fallan cerrados por diseño, lo que significa que tiran producción abajo cuando se portan mal. Poder diagnosticarlos bajo presión de tiempo es la habilidad real.

**Pasos**

1. Rompé la compuerta y diagnosticá sin pistas. Corrompé la ruta de la config de admisión:

```bash
sed -i 's|/etc/kubernetes/admission/admission-config.yaml|/etc/kubernetes/admission/typo.yaml|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 30
kubectl get nodes
```

Esperado:

```console
The connection to the server 10.0.1.10:6443 was refused - did you specify the right host or port?
```

Diagnosticá desde debajo del API server:

```bash
crictl ps -a --name kube-apiserver --latest
crictl ps -a --name kube-apiserver --latest -q | xargs crictl logs 2>&1 | tail -5
```

Esperado:

```console
CONTAINER      IMAGE       STATE    NAME             ATTEMPT
9f2c1a...      c2e17b...   Exited   kube-apiserver   4

Error: failed to create admission plugin config: open
/etc/kubernetes/admission/typo.yaml: no such file or directory
```

```bash
sed -i 's|typo.yaml|admission-config.yaml|' /etc/kubernetes/manifests/kube-apiserver.yaml
```

2. Rompé Kyverno y observá la diferencia entre un fallo interno del API server y un fallo de webhook:

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=0
kubectl -n app run whatever --restart=Never --image=registry.internal:5000/prod/nginx:1.27
```

Esperado:

```console
Error from server (InternalError): Internal error occurred: failed calling webhook
"mutate.kyverno.svc-fail": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/...":
no endpoints available for service "kyverno-svc"
```

Encontrá el webhook exacto responsable y su timeout/política de fallo:

```bash
kubectl get mutatingwebhookconfigurations -o custom-columns=\
'NAME:.metadata.name,WEBHOOK:.webhooks[*].name,POLICY:.webhooks[*].failurePolicy,TIMEOUT:.webhooks[*].timeoutSeconds'
```

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=1
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

3. Simulá la emergencia que realmente vas a enfrentar — una rotación de clave de firma que invalida la firma de cada imagen en ejecución. Determiná, sin borrar nada, exactamente qué cargas de trabajo fallarían al reprogramarse:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
for img in $(kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
             | grep '^registry.internal:5000/prod/' | sort -u); do
  if cosign verify --key /root/keys/cosign.pub --insecure-ignore-tlog=true "$img" >/dev/null 2>&1; then
    echo "OK      $img"
  else
    echo "UNSIGNED $img"
  fi
done
```

Esperado:

```console
OK      registry.internal:5000/prod/nginx@sha256:d2b2f2b2ee1a...9a1c
UNSIGNED registry.internal:5000/prod/redis:7
```

4. Practicá el bypass controlado. Pasá Kyverno de bloquear a reportar *sin* borrar la política, para conservar visibilidad:

```bash
kubectl patch cpol verify-internal-registry-signatures --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
kubectl -n app run emergency --restart=Never --image=registry.internal:5000/prod/redis:7
kubectl -n app get policyreport -o jsonpath='{.items[*].results[?(@.result=="fail")].policy}{"\n"}'
```

Esperado:

```console
pod/emergency created
verify-internal-registry-signatures
```

Restaurá:

```bash
kubectl patch cpol verify-internal-registry-signatures --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

### Preguntas de control — bloque 8

- **Q8.1** — En el paso 1 `kubectl` estaba completamente muerto. Ordená, en secuencia, los tres comandos que ejecutás en el nodo del control plane para encontrar la causa, y explicá qué te dice cada uno que el anterior no te dijo.
- **Q8.2** — El error del paso 2 fue `InternalError`, mientras que el fallo de firma anterior fue `Forbidden`. ¿Por qué esos mapean a códigos de estado HTTP distintos, y qué te dice cada uno sobre dónde mirar?
- **Q8.3** — Durante un incidente real tenés que desplegar un fix y el pipeline de firma está caído. Ordená estos cuatro bypasses de menos a más peligroso, y justificá: (a) `validationFailureAction: Audit`, (b) borrar el ClusterPolicy, (c) agregar el namespace a `exclude`, (d) poner el `failurePolicy: Ignore` del webhook.
- **Q8.4** — Rotás la clave de firma. Diseñá la migración de modo que cero cargas de trabajo en ejecución corran riesgo de fallar al reprogramarse, usando solo los mecanismos de este documento.
- **Q8.5** — ¿Cuáles de los controles que construiste (VAP, ImagePolicyWebhook, Kyverno, allowlist de containerd) sobreviven a una caída total del control plane, y qué te dice eso sobre dónde ubicar el control que más necesitás que sea inevadible?

---

## Desmontaje

```bash
kubectl delete ns app cosign-system --ignore-not-found
kubectl delete cpol verify-internal-registry-signatures --ignore-not-found
kubectl delete validatingadmissionpolicybinding allowed-registries-binding --ignore-not-found
kubectl delete validatingadmissionpolicy allowed-registries.supplychain.local --ignore-not-found
kubectl -n kube-system delete cm registry-allowlist --ignore-not-found
helm uninstall kyverno -n kyverno; kubectl delete ns kyverno --ignore-not-found
rm -f /etc/kubernetes/manifests/registry.yaml
# revert kube-apiserver.yaml: remove ImagePolicyWebhook from --enable-admission-plugins,
# remove --admission-control-config-file, remove the admission-config volume/volumeMount
rm -rf /etc/containerd/certs.d/_default && systemctl restart containerd
```

---

## Respuestas

<details>
<summary><strong>Clic para revelar todas las respuestas (Q0.1 – Q8.5)</strong></summary>

### Bloque 0 — Registry privado y confianza del runtime

**Q0.1** — containerd consulta la entrada `ca` dentro de `/etc/containerd/certs.d/registry.internal:5000/hosts.toml` para ese host específico. Si ahí no se especifica ninguna `ca`, cae de vuelta al pool de confianza del sistema de Go, que *sí* incluye la salida de `update-ca-certificates`. Así que ambas pueden funcionar, pero se comportan distinto: la entrada de `certs.d` está **acotada a un solo host de registry**, el almacén del sistema es **confianza a nivel de todo el nodo para cada cliente TLS** — incluida cualquier otra cosa que salga a la red. En un cluster air-gapped la distinción importa porque típicamente ponés un único mirror interno delante de todos los pulls; poner la CA de ese mirror solo en `certs.d` significa que un compromiso de esa CA no puede usarse para suplantar ningún otro endpoint TLS con el que hable el nodo. Principio: otorgá la confianza más estrecha que funcione.

**Q0.2** — *Ayuda:* un static Pod lo gestiona directamente el kubelet desde `/etc/kubernetes/manifests`, así que arranca antes de (y de forma independiente al) scheduler, la cadena de admisión del API server, y cualquier controller dependiente del CNI. Tu registry por lo tanto sobrevive a una caída del control plane y no puede quedar en deadlock contra las mismísimas políticas que lo necesitan. *Debilidad:* los static Pods **evaden todo controlador de admisión**. El mirror Pod en el API server es un reflejo de solo lectura; nada validó su imagen, su registry, su firma ni su security context. Compensás en otro lado: monitoreo de integridad de archivos sobre `/etc/kubernetes/manifests`, restricción de root/SSH en los nodos del control plane, y el plugin de admisión `NodeRestriction` (que impide que un kubelet mute los objetos de *otros* nodos pero **no** impide que corra sus propios static Pods).

**Q0.3** — `skip_verify = true` deshabilita la verificación del certificado TLS para ese host de registry, rehabilitando el **machine-in-the-middle activo en los pulls de imágenes**: cualquiera que pueda responder por `registry.internal:5000` (spoofing de ARP/DNS, un nodo pirata, un balanceador de carga comprometido) puede servir contenido de imagen arbitrario y el runtime lo acepta. La firma de imágenes **sí** compensa la mitad de integridad de contenido — un MITM no puede producir una firma cosign válida para capas sustituidas, así que un consumidor que impone firmas rechaza la falsificación. **No** compensa la mitad de confidencialidad (las credenciales de pull enviadas por un canal no verificado se cosechan) ni la disponibilidad. Y críticamente, la verificación de firmas solo ayuda *donde se impone*: `crictl pull` en el nodo no está controlado por Kyverno. Nunca despliegues `skip_verify`.

### Bloque 1 — Inventario y fijado por digest

**Q1.1** — *Pods existentes:* no afectados. Sus containers ya están corriendo desde las capas resueltas previamente; el contenido de la imagen en disco no cambia debajo de ellos. *Pods nuevos:* depende del nodo, porque `IfNotPresent` solo hace pull cuando el tag está ausente del almacén de imágenes de ese nodo. Un nodo que ya cacheó `internal/app:v2.3.1` va a arrancar la imagen **vieja y buena**; un nodo recién incorporado, o uno donde la imagen fue recolectada por el image GC del kubelet, descarga el contenido **nuevo y malicioso**. El resultado es un cluster en un estado mixto, no reproducible, extremadamente difícil de diagnosticar — tenés un Deployment, un tag, y dos binarios distintos corriendo. Esta es exactamente la clase de fallo que elimina el fijado por digest.

**Q1.2** — *Costos:* (1) Manifests ilegibles para humanos — nadie puede decir a partir de `image: app@sha256:9f3c...` qué versión está desplegada, así que tenés que llevar la versión en una label o annotation. (2) Cada actualización se convierte en un cambio de manifest, así que el flujo de "simplemente re-desplegar para tomar la imagen base parcheada" desaparece; necesitás una máquina que calcule y commitee el nuevo digest. *Mecanismo:* automatizalo — un actualizador de imágenes en el pipeline de GitOps (Flux `ImagePolicy`/`ImageUpdateAutomation`, Renovate con fijado por digest, Argo CD Image Updater) que resuelve tag→digest, abre un commit, y deja que la misma política de firma/atestación controle el cambio. Alternativamente, dejá que un mutador en tiempo de admisión lo haga (`mutateDigest: true` de Kyverno, Ejercicio 5), lo que te da inmutabilidad a nivel de digest sin manifests ilegibles para humanos — al costo de que el manifest en Git deje de ser la fuente de verdad de lo que corre.

**Q1.3** — Para una imagen de arquitectura única, `imageID` es el digest del **manifest** de la imagen tal como lo almacena el runtime. Para una imagen **multi-arch** la referencia que usó el autor (`nginx:1.27`) resuelve a un digest de *índice* (manifest list), pero el nodo corre un manifest específico de plataforma — así que `imageID` típicamente reporta el **digest del manifest específico de plataforma**, no el digest del índice que el autor obtendría con `crane digest`. Por eso comparar `imageID` contra un digest que calculaste en tu laptop puede no coincidir en un cluster heterogéneo, y por eso la firma debería apuntar al digest del **índice** (cosign sigue el índice y la verificación del índice cubre a los hijos a través de la relación `subject`/firma adjunta — verificalo con `cosign tree` sobre ambos digests).

**Q1.4** — Se pierde: (1) **initContainers y ephemeralContainers** — `kubectl debug` inyecta una imagen en un Pod en ejecución. (2) **Static Pods y mirror Pods**, y cualquier cosa que corra en el nodo enteramente por fuera de Kubernetes. (3) **Plantillas que todavía no produjeron Pods** — Deployments/StatefulSets/CronJobs/DaemonSets cuyos Pods están escalados a cero o todavía no programados, más cargas de trabajo gestionadas por operadores cuyas imágenes viven en CRs. (4) Webhooks que inyectan sidecars (service mesh, inyectores de secretos) que agregan imágenes en tiempo de admisión y por lo tanto aparecen en los Pods pero nunca en el manifest del autor. (5) Campos `image` dentro de CRDs (`spec.image` de operadores), valores de Helm, e imágenes a nivel de nodo cacheadas por el runtime. Un inventario real consulta `crictl images` en cada nodo *y* cada recurso que contenga una plantilla de pod.

### Bloque 2 — ValidatingAdmissionPolicy

**Q2.1** — Los `matchConstraints` solo coincidían con `resources: ["pods"]`. `kubectl create deployment` crea un objeto **Deployment**, con el que la política no coincide; el controller del Deployment después crea un ReplicaSet, cuyo controller crea Pods — y *esas* peticiones son las que se deniegan. El usuario ve una salida de `kubectl` de apariencia sana y un Deployment estancado en 0 réplicas. *Soluciones:* (a) Agregá los recursos de controller a `matchConstraints` — `apiGroups: ["apps","batch"]`, `resources: ["deployments","statefulsets","daemonsets","replicasets","jobs","cronjobs"]` — y reescribí el CEL para que lea `object.spec.template.spec.containers` (la ruta difiere por kind, así que necesitás políticas por regla o `variables` que ramifiquen según `request.resource.resource`). Trade-off: mucho más CEL que mantener, y tenés que conservar también la regla de Pod, o los Pods pelados se escapan. (b) Usá el patrón incorporado **al estilo Pod Security Admission** de coincidir solo con Pods y confiar en el tooling/CI para hacer aflorar los fallos a nivel de controller. Trade-off: mala UX, pero una sola expresión correcta. En producción, hacé las dos: coincidí con pod-controllers para feedback rápido *y* con Pods para la aplicación real.

**Q2.2** — Con el prefijo `registry.internal:5000/`, la referencia `registry.internal:5000.evil.com/team/app:v1` **no** empieza con `registry.internal:5000/` (el carácter después de `5000` es `.`, no `/`), así que se **deniega** correctamente. Con el prefijo `registry.internal` (sin barra y sin puerto), `registry.internal:5000.evil.com/...` **sí** empieza con esa cadena y se **permite** erróneamente — igual que `registry.internal.evil.com/...`. *Lección:* el matching por prefijo sobre referencias de imagen siempre debe terminar en un **delimitador estructural** — incluí la barra final `/` (y el puerto cuando el registry usa uno). Mejor todavía, parseá la referencia: dividí en la primera `/` y compará el componente de host por igualdad exacta, por ejemplo `img.split('/')[0] in ['registry.internal:5000','registry.k8s.io']`, recordando que los nombres cortos de Docker Hub (`nginx:1.27`) no tienen componente de host en absoluto y deben manejarse explícitamente.

**Q2.3** — `kube-system` aloja los propios static Pods del control plane y los DaemonSets de CNI/CoreDNS/kube-proxy, cuyas imágenes vienen de `registry.k8s.io` y del registry del proveedor del CNI. Controlarlos arriesga un deadlock y, como mínimo, bloquea actualizaciones legítimas del control plane. Con `failurePolicy: Fail` **y** `parameterNotFoundAction: Deny`, borrar el ConfigMap deja a la política sin poder resolver sus params, así que **toda** creación de Pod coincidente se deniega. En el próximo reinicio del control plane, los mirror Pods de los static Pods del control plane igual levantan (los static Pods evaden la admisión), pero cada Pod de DaemonSet — CNI, kube-proxy, CoreDNS — es rechazado, y el cluster se queda sin red. La recuperación requiere borrar el binding a través de un API server que está corriendo pero rechazando toda creación de Pods. La exclusión (más nunca controlar `kube-system`) es lo que hace que el fallo sea recuperable.

**Q2.4** — Con `parameterNotFoundAction: Deny`: el binding no puede resolver su `paramRef`, y la petición de admisión se **deniega** para cada recurso con el que coincide el binding — fail-closed. Con `Allow`: la política simplemente se **omite** para esas peticiones y todo se admite — fail-open. La elección de seguridad es `Deny`; la de operabilidad es `Allow`. La respuesta correcta en producción es `Deny` *más* proteger el ConfigMap: restringí `delete`/`update` sobre él vía RBAC, y tratalo como un objeto del control plane bajo GitOps, no como algo que un operador edita a mano.

**Q2.5** — Sí, la política se dispara: `matchConstraints` incluye `UPDATE`, y `kubectl set image pod/...` es una actualización al objeto Pod cuyo nuevo `object.spec.containers[].image` se re-evalúa. (Nota: el kubelet solo respeta cambios de imagen para containers de formas limitadas, pero la admisión igual corre.) Para `kubectl debug`, el ephemeral container se agrega a través del **subrecurso `pods/ephemeralcontainers`**, que es un recurso *distinto* de `pods` en `matchConstraints`. La política tal como está escrita **no** coincide con él — la rama `has(object.spec.ephemeralContainers)` solo ayuda en actualizaciones de pod comunes. Para controlar `kubectl debug` tenés que agregar `resources: ["pods/ephemeralcontainers"]` a los `resourceRules`. Esta es una evasión real y vale la pena probarla explícitamente.

**Q2.6** — No podés **reescribir** la petición, así que no podés implementar *fijado de tag a digest en la admisión*, inyección de sidecars/labels, ni establecer por defecto `imagePullPolicy: Always`. `ValidatingAdmissionPolicy` solo puede aceptar o rechazar. Para mutación necesitás o bien `MutatingAdmissionPolicy` (la contraparte de mutación in-tree basada en CEL, todavía madurando) o una `MutatingWebhookConfiguration` respaldada por un controller como Kyverno (Ejercicio 5). Tampoco podés hacer **llamadas de red** desde CEL — así que la verificación de firmas, que requiere descargar el artefacto `.sig` del registry, es estructuralmente imposible en un VAP.

### Bloque 3 — ImagePolicyWebhook

**Q3.1** — `defaultAllow: true` → cuando el backend es inalcanzable (o se agotan todos los reintentos), el API server **admite** el Pod. Fail-open: se preserva la disponibilidad, el control de seguridad desaparece silenciosamente, y puede que no lo notes durante semanas. `defaultAllow: false` → el API server **deniega**. Fail-closed: el control es real, pero una caída de un webhook de instancia única detiene toda creación de Pods en el cluster, incluidos los Pods que podrían arreglarlo. *Uso defendible de `true`:* una fase inicial de despliegue/rodaje donde estás midiendo qué *bloquearía* la política (acompañado de alertas sobre indisponibilidad del backend), o un cluster donde el webhook es genuinamente enriquecimiento de mejor esfuerzo y un control más fuerte (allowlist de containerd, imposición de imágenes firmadas) es la compuerta real. Más allá de esa fase, `false` más un backend altamente disponible e independiente del cluster.

**Q3.2** — `retryBackoff: 500` (milisegundos) es el backoff inicial entre reintentos, y `allowTTL`/`denyTTL` (segundos) controlan cuánto tiempo se cachean las decisiones, lo que indirectamente determina con qué frecuencia se consulta al backend siquiera. Poner `retryBackoff` demasiado alto alarga cuánto tiempo bloquea una sola petición de admisión al handler del API server; combinado con un backend lento consume slots de peticiones del API server y puede degradar todo el control plane — una caída del webhook de admisión convirtiéndose en una caída del API server. Poner los TTLs demasiado altos (ver Q3.4) mantiene vivas decisiones obsoletas más allá del punto en que son seguras.

**Q3.3** — Control RBAC: impedí que los usuarios sin privilegios puedan siquiera poner la anotación. Como el RBAC de Kubernetes es de alcance por recurso y no puede restringir *campos* individuales, lo imponés con una segunda compuerta de admisión — una `ValidatingAdmissionPolicy` que deniega cualquier Pod que lleve una clave coincidente con `*.image-policy.k8s.io/*` a menos que el solicitante esté en un grupo permitido:

```yaml
validations:
  - expression: >-
      !object.metadata.?annotations.orValue({}).exists(k, k.contains('.image-policy.k8s.io/')) ||
      ('system:masters' in request.userInfo.groups)
```

*Diferencia estructural:* una excepción de RBAC es **de alcance por sujeto y auditable en un solo lugar** — podés enumerar quién la tiene y revocarla de forma centralizada. Un break-glass basado en anotaciones es **de alcance por objeto**: el privilegio se lo confiere la capacidad de escribir un campo en un recurso sobre el que ya tenés `create`, así que cualquiera con `create pods` en cualquier namespace lo posee por defecto. Es una evasión disfrazada de control, salvo que agregues la segunda compuerta de arriba.

**Q3.4** — El caché se indexa por el **contenido de la petición `ImageReview`** — principalmente la cadena de imagen tal como está escrita en el spec del Pod, más el namespace y las anotaciones. Si el spec dice `app:v1` y el tag se re-pushea con contenido distinto, la *cadena de imagen no cambia*, así que un permitido cacheado (hasta `allowTTL` segundos) admite el contenido nuevo y malicioso sin volver a consultar al backend. El digest nunca entra en escena, porque `ImagePolicyWebhook` solo ve la referencia sin resolver. Esta es una razón concreta de por qué `ImagePolicyWebhook` es insuficiente por sí solo y de por qué existe la verificación basada en digest (Ejercicios 4–5). TTLs cortos reducen pero no eliminan la ventana.

**Q3.5** — De "solo Pods": (1) Un **Deployment/DaemonSet/Job** con una imagen prohibida se acepta en el nivel superior; la aplicación de la política solo aparece como eventos del controller — la misma trampa que Q2.1. (2) Los **static Pods** nunca atraviesan la admisión en absoluto. (3) El **subrecurso `pods/ephemeralcontainers`** — verificá si el plugin de tu versión lo inspecciona; si no, `kubectl debug --image=evil` entra derecho. De "no puede mutar": (4) Sin fijado tag→digest, así que la ventana TOCTOU entre la decisión de permitido y el pull del kubelet queda abierta de par en par — el backend aprueba `app:v1`, y para cuando el nodo hace el pull, `app:v1` son bytes distintos. (5) Ninguna capacidad de forzar `imagePullPolicy: Always`, así que los nodos pueden correr contenido cacheado obsoleto que nunca fue re-evaluado.

**Q3.6** — `--enable-admission-plugins` **agrega al** conjunto habilitado por defecto en lugar de reemplazarlo, así que `NodeRestriction` — que *sí* está activo por defecto en versiones recientes — no debería haberse perdido solo por esa flag. Lo que realmente rompe a la gente es la flag vecina **`--disable-admission-plugins`**, o sobrescribir una línea `--enable-admission-plugins=NodeRestriction` generada por kubeadm *reemplazándola* en lugar de agregar `,ImagePolicyWebhook`. kubeadm escribe `--enable-admission-plugins=NodeRestriction` explícitamente, y si le hacés `sed` a esa línea para dejar `--enable-admission-plugins=ImagePolicyWebhook`, `NodeRestriction` vuelve a lo que sea el valor por defecto de esa versión — que históricamente estaba *apagado*. Siempre agregá, y siempre verificá después:
`kubectl -n kube-system get pod kube-apiserver-cp01 -o yaml | grep admission-plugins`.

### Bloque 4 — cosign

**Q4.1** — cosign nunca firma un tag. Resuelve la referencia a un **digest de manifest**, construye un pequeño payload de "simple signing" que contiene ese digest (`critical.image.docker-manifest-digest`), firma *ese payload*, y almacena la firma como un artefacto OCI etiquetado `sha256-<digest>.sig` en el mismo repositorio. En la verificación, cosign resuelve la referencia **de nuevo** para obtener el digest actual, busca firmas en `sha256-<digest-actual>.sig`, y verifica la firma sobre el payload. Después de reapuntar `1.27` a nginx 1.25, el tag resuelve a un digest *distinto*, así que cosign busca bajo un tag `.sig` *distinto* — que está vacío — y reporta `no matching signatures`. La firma vieja sigue siendo perfectamente válida; simplemente describe bytes que ya nadie está pidiendo.

**Q4.2** — Resignaste la **transparencia y el no repudio a lo largo del tiempo**. Rekor es un log de solo-anexar, auditable públicamente, de eventos de firma con prueba de inclusión y una marca de tiempo firmada. Sin él, el ataque que detecta es: un atacante que roba tu clave privada firma una imagen maliciosa y no antedata nada — la verificación contra tu clave pública tiene éxito, y **no hay registro en ninguna parte** de que la firma se creó después del compromiso. Con una entrada en el tlog, cada firma legítima es descubrible, así que (a) podés enumerar todo lo que se firmó alguna vez con tu clave y detectar entradas que no creaste, y (b) tras un compromiso de clave podés confiar en las firmas cuyas entradas de log preceden a la ventana de compromiso y rechazar el resto. También habilita la verificación keyless de certificados expirados (Q4.3). `--tlog-upload=false` es aceptable solo en un laboratorio genuinamente air-gapped o con una instancia privada de Rekor.

**Q4.3** — La firma keyless acuña un par de claves efímero, prueba una identidad OIDC ante **Fulcio**, y recibe un certificado X.509 de corta duración (~10 min) que vincula la clave pública efímera a esa identidad. La firma y el certificado quedan registrados entonces en **Rekor**, que contrafirma con una marca de tiempo confiable (el Signed Entry Timestamp). En el momento de la verificación, cosign comprueba que el certificado era **válido en el momento registrado en el transparency log**, no en el momento de la verificación. Así que la expiración del certificado es irrelevante — Rekor es lo que hace demostrable la validez histórica. *Roles:* Fulcio = autoridad certificadora de corta duración que vincula identidad OIDC → clave; Rekor = log de transparencia a prueba de manipulación que provee la marca de tiempo confiable y la descubribilidad pública. La confianza en ambos se arranca desde la raíz TUF que `cosign initialize` descarga.

**Q4.4** — `cosign verify nginx:1.27` resuelve el tag al digest **D1** y valida una firma para D1. Algún tiempo después — minutos o días — el kubelet resuelve `nginx:1.27` de forma independiente. Si el tag fue reapuntado en el medio, el kubelet obtiene **D2**, que nadie verificó. El CI reportó verde; producción corre bytes no verificados. *Soluciones:* (1) Hacé que el CI verifique por tag, después **emita el digest** y despliegue `image: repo@sha256:D1` para que la referencia sea inmutable de punta a punta. (2) Verificá **en la admisión**, y mutá el tag al digest verificado en la misma transacción de admisión — `mutateDigest: true` en Kyverno (Ejercicio 5), lo que hace que la verificación y el fijado sean atómicos. La solución (2) es estrictamente más fuerte porque además cubre Pods creados fuera del CI.

**Q4.5** — *Puede:* pushear imágenes nuevas y tags nuevos; reapuntar tags existentes a contenido arbitrario; **borrar** imágenes, firmas y atestaciones (si el borrado está habilitado); pushear artefactos `.sig` maliciosos firmados con su propia clave; consumir almacenamiento. Los dos últimos importan — borrar tus artefactos `.sig` es una **denegación de servicio contra un verificador fail-closed**: cada despliegue y cada reprogramación de una carga de trabajo legítima empieza a fallar en la admisión. Ese suele ser el ataque más práctico que falsificar contenido. *No puede:* producir una firma que verifique contra tu clave pública, así que ningún contenido sustituido será admitido por un consumidor que imponga verificación, y ninguna atestación falsificada satisfará una política. Notá la asimetría: la imposición de firmas convierte un compromiso de **integridad** en un compromiso de **disponibilidad**. Planificá para eso — backups del registry, tags inmutables del lado del servidor, y credenciales separadas para push versus borrado.

**Q4.6** — **Rechazar** para una clave de firma de producción. Un Secret de Kubernetes es base64, no cifrado, almacenado en etcd; cualquiera con `get secrets` en ese namespace, cualquiera que pueda leer un backup de etcd, y cualquiera que pueda programar un Pod que lo monte posee tu identidad de firma. La forma `k8s://` es una conveniencia para controllers que deben *firmar* dentro del cluster (por ejemplo un sistema de build in-cluster), e incluso entonces requiere cifrado de etcd en reposo, RBAC estricto, y auditoría sobre ese Secret. *Alternativas, en orden creciente de garantía:* (1) una clave respaldada por KMS — cosign soporta `--key awskms://`, `gcpkms://`, `azurekms://`, `hashivault://`, así que la clave privada nunca sale del HSM/KMS; (2) un HSM o token PKCS#11 para una clave raíz/de release; (3) firma **keyless** en el CI, que elimina por completo la clave de larga duración y reemplaza "quién tiene la clave" por "qué identidad de workflow corrió" — usualmente la respuesta correcta para un pipeline de build.

### Bloque 5 — Imposición con Kyverno

**Q5.1** — Ocurre en la fase de **admisión de mutación**, que el API server ejecuta *antes* de la admisión de validación y antes de persistir el objeto. Debe ser primero porque el punto entero es que el digest que Kyverno *verificó* sea el digest que se **escribe en etcd** y por lo tanto el digest que el kubelet descarga. Si la reescritura ocurriera después de la validación (o, peor, en un controller después de la persistencia), el objeto ya llevaría un tag mutable y cualquier re-resolución posterior podría dar contenido distinto. Respecto del TOCTOU: la "verificación" (descargar `.sig`, verificar la firma para el digest D) y el "uso" (escribir `image: repo@sha256:D` en el spec del Pod) ocurren dentro de una única petición de admisión, así que no hay ventana en la que el tag pueda reapuntarse entre ambos. Todo lo que sigue río abajo — programación, pull del kubelet, reinicios de nodo, GC de imágenes — opera sobre un digest inmutable.

**Q5.2** — Sin la exclusión, al webhook de admisión de Kyverno se le pide validar la creación de los propios Pods de Kyverno. En un arranque en frío no hay nada corriendo para responder, `failurePolicy: Fail` convierte eso en una denegación, y el Deployment de Kyverno nunca puede producir Pods — un deadlock permanente que además bloquea CoreDNS, el CNI y todo lo demás si esos namespaces tampoco están excluidos. Recuperarse requiere borrar a mano el `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration`. Por eso todo controlador de admisión serio viene con exclusiones de namespace para `kube-system` y su propio namespace, y por eso el Helm chart de Kyverno configura exclusiones por `namespaceSelector` por defecto. Regla general: **un webhook fail-closed nunca debe estar en la ruta de dependencias de su propio arranque**.

**Q5.3** — `required: true` (el valor por defecto): una imagen que coincide con `imageReferences` y que **no tiene ninguna firma** se rechaza — la ausencia de evidencia se trata como fallo. Esto es lo que querés. `required: false`: una imagen sin firma **se deja pasar**; la regla solo rechaza imágenes que tienen firmas que no verifican. Eso convierte el control en "verificamos firmas cuando casualmente existen", que un atacante derrota simplemente no firmando — pushear una imagen sin firmar es más fácil que falsificar una. `required: false` solo es apropiado durante una migración en la que estás incorporando repositorios de forma incremental, y debería acompañarse de un reporte de cuántas imágenes siguen sin firmar.

**Q5.4** — Nada en *esta* política los detiene — `registry.internal:5000/staging/app` no coincide con `registry.internal:5000/prod/*`, así que `verifyImages` nunca se evalúa y la imagen corre sin firmar. Lo que impediría que el Pod corra es la capa que controla por **registry** en lugar de por ruta de repositorio: el `ValidatingAdmissionPolicy` del Ejercicio 2 permite `registry.internal:5000/` como un todo, así que lo *permite*; el backend de `ImagePolicyWebhook` del Ejercicio 3 también permite todo el registry; y el allowlist de containerd del Ejercicio 7 también permite todo el registry. **Así que la respuesta es: nada los detiene.** Esa es la lección — las políticas de firma con alcance por ruta dejan un agujero exactamente del tamaño de cada ruta que no enumeraste. Arreglalo haciendo que el *default* sea denegar: `imageReferences: ["registry.internal:5000/*"]` con excepciones por ruta, en lugar de un allowlist de rutas que deben estar firmadas.

**Q5.5** — La CA montada establece **confianza de transporte**: Kyverno va a aceptar una conexión TLS a `registry.internal:5000` y descargar el manifest y el artefacto `.sig`. El bloque `publicKeys` establece **confianza de artefacto**: la firma sobre el digest del manifest debe verificar contra esa clave. Son independientes — una conexión TLS válida no te dice nada sobre quién construyó la imagen, y una firma válida es verificable sobre un canal no confiable. *Si se compromete:* la **clave de firma** es mucho peor. Una CA de registry comprometida le permite a un atacante hacer MITM sobre la descarga — pero el artefacto que sirva igual tiene que llevar una firma que verifique contra tu clave pública, así que el control se sostiene (obtienen DoS, no ejecución de código). Una clave de firma comprometida le permite a un atacante firmar cualquier cosa, y cada consumidor que impone verificación en toda la flota lo acepta, sobre una conexión TLS perfectamente válida. Protegé la clave de firma con una clase de control distinta (KMS/HSM/keyless) de la que usás para la CA.

**Q5.6** — `count: N` significa **al menos N de las `entries` en este bloque de attestor deben verificar**. `count: 1` con dos entradas = "cualquiera de las firmas alcanza" (OR). Para "sistema de build Y release manager", usá **dos bloques de attestor**, porque los bloques se combinan con AND mientras que las entradas dentro de un bloque se cuentan:

```yaml
attestors:
  - count: 1
    entries:
      - keys: { publicKeys: "<build-system-key>", rekor: {...} }
  - count: 1
    entries:
      - keys: { publicKeys: "<release-manager-key>", rekor: {...} }
```

Entradas dentro de un solo bloque con `count: 2` también requerirían ambas — pero la forma de dos bloques es más clara y le permite a cada parte tener su propio conjunto de rotación de claves (por ejemplo, el bloque uno con `count: 1` sobre tres claves válidas del sistema de build). Así es como expresás una regla de dos personas o una compuerta de promoción entre staging y producción.

### Bloque 6 — Atestaciones

**Q6.1** — Una **firma** (`cosign sign`) es una afirmación firmada sobre el digest del manifest de la imagen y nada más: "estos bytes son míos". Una **atestación** (`cosign attest`) es un **Statement in-toto** firmado — un sobre DSSE que contiene `{_type, subject: [{name, digest}], predicateType, predicate}` — es decir, una *afirmación firmada sobre* esos bytes: su SBOM, su procedencia, su resultado de escaneo. Un **adjunto** (`cosign attach sbom`) pushea un SBOM como artefacto OCI junto a la imagen **sin ninguna firma**. El adjunto es el no autenticado, y la consecuencia es decisiva: cualquiera con acceso de push puede reemplazar el SBOM adjunto por una fabricación de apariencia limpia, así que un adjunto nunca puede ser entrada de una política. `cosign attach sbom` está deprecado en favor de `cosign attest` exactamente por esta razón. Regla: si una decisión de política depende de eso, tiene que ser una atestación.

**Q6.2** — `subject[].digest` es lo que **liga la afirmación al artefacto**. Sin él, una atestación es un documento firmado flotando en el aire. Si un motor de políticas verificara solo `predicateType` y la validez de la firma, un atacante con cualquier atestación válida firmada con la clave confiable — digamos el SBOM de una imagen hello-world benigna que el mismo pipeline construyó el año pasado — podría adjuntarla a una imagen maliciosa, y la política pasaría: la firma verifica, el tipo de predicado coincide, y nadie preguntó *qué artefacto describe esto*. El motor debe afirmar `subject[].digest == <digest de la imagen que se está admitiendo>`. cosign hace esto en `verify-attestation` (busca las atestaciones bajo `sha256-<digest>.att` y verifica el subject), y por eso tenés que verificar por digest y por eso la resolución del digest debe ser atómica con la verificación (Q5.1).

**Q6.3** — *A favor de una clave distinta:* separa los roles de "quién construyó este artefacto" y "quién afirma cosas sobre él". Un escáner produce atestaciones de vulnerabilidades continuamente y debe tener una clave con un ciclo de vida y un radio de impacto muy distintos de la clave de firma de releases; si la clave del escáner se filtra, el atacante puede falsificar resultados de escaneo pero no artefactos de release. Además te permite exigir atestaciones **independientes** de sistemas separados (Q5.6), lo que es un control genuino de dos partes en lugar de una sola clave con dos sombreros. *En contra:* más claves es más gestión de claves, más rotación, más lugares de donde filtrarse, y más superficie de política — un equipo chico tiene más chances de hacer bien una clave que cuatro. *SLSA:* la separación soporta **Build L2 y superiores**, que requieren que la procedencia sea generada y firmada por el *servicio de build* en lugar de por la persona o proceso que aporta el código fuente — y **L3**, que además requiere que la plataforma de build impida que el build mismo influya sobre la procedencia o acceda al material de firma. Una sola clave en manos del script de build es estructuralmente incompatible con L3. Ver [slsa.dev/spec/v1.0/levels](https://slsa.dev/spec/v1.0/levels).

**Q6.4** — La atestación SBOM es un **inventario en un punto del tiempo de lo que hay dentro del artefacto**, y ese inventario no cambia cuando se publica un CVE — la imagen sigue conteniendo `openssl 3.0.11` sepa o no el mundo que es vulnerable. Precisamente ahí está su valor: cuando aparece CVE-2026-XXXX, consultás cada atestación SBOM de la flota y respondés "cuáles de mis 400 imágenes contienen el paquete y la versión afectados" en segundos, sin re-escanear nada. Es un registro de *activos*. La **atestación vuln** es un registro de *juicio*, y los juicios se degradan: dice "según la base de datos de vulnerabilidades del 2026-08-04, esta imagen tenía cero críticas". Dos semanas después esa afirmación sigue siendo cierta y es completamente inútil. En política, se puede exigir indefinidamente que una atestación SBOM exista y esté bien formada; una atestación vuln debe exigirse **fresca** (predicado `scanFinishedOn` dentro de N días) o es teatro de seguridad.

**Q6.5** — *Objeción 1 — impone lo que no corresponde.* La admisión corre en la creación del Pod, que para un Deployment de larga vida puede ser meses después de que la imagen se construyó. Imponer "cero críticas al momento del build" no bloquea nada que importe y bloquea un montón que no; mientras tanto, las imágenes que ya están corriendo, que acumularon CVEs reales, quedan intactas porque la admisión nunca las re-evalúa. *Objeción 2 — hace que la disponibilidad dependa de un feed externo de vulnerabilidades.* Un nuevo CVE crítico en glibc va a hacer, de un día para el otro, que cada imagen de la flota falle la admisión. Los nodos se reinician, los Pods se reprograman, y el cluster no puede levantar las cargas de trabajo — una actualización de la base de datos de vulnerabilidades se convierte en una caída de todo el cluster, y la presión por evadir el control (Q8.3) se vuelve irresistible. *Diseño alternativo:* imponé la política de vulnerabilidades en **CI**, donde un build fallido bloquea un release y nada en producción está en riesgo; en la admisión, exigí solo que *exista* una atestación vuln *fresca y firmada* (probando que el artefacto pasó por el escáner) sin controlar su contenido; y corré escaneo **continuo** contra el inventario de SBOMs para las imágenes ya desplegadas, alimentando un SLA de remediación en lugar de una denegación de admisión.

### Bloque 7 — Defensa a nivel de nodo

**Q7.1** — *Solo containerd detiene:* un atacante con root en un nodo, o con la capacidad de escribir en `/etc/kubernetes/manifests`, crea un **static Pod** que descarga `docker.io/attacker/miner:latest`. Ningún controlador de admisión ve jamás la petición — el kubelet hace el pull directamente. El deny de `_default` en containerd hace que el pull falle. Lo mismo para un `crictl pull` directo, o un kubelet comprometido. *Solo la admisión atrapa:* un desarrollador commitea un Deployment que referencia `quay.io/somevendor/tool:v3` al repo de GitOps. containerd lo descargaría felizmente si `quay.io` estuviera en `certs.d` y fallaría de forma oscura como `ImagePullBackOff` si no — pero la capa de *admisión* lo rechaza en el `kubectl apply` con un mensaje que nombra la política y los registries permitidos, así que el desarrollador se entera de qué está mal en segundos en lugar de depurar un nodo. *Ninguna alcanza sola:* la admisión es evadible por cualquier cosa que no pase por el API server; la aplicación en containerd es deriva de configuración por nodo esperando a suceder, da diagnósticos pésimos, y no puede expresar nada más rico que un allowlist de hosts (sin firmas, sin alcance por namespace, sin identidad).

**Q7.2** — *Riesgo:* el deny `_default` es configuración de archivo local del nodo, no estado del cluster. Un nodo reconstruido desde una imagen más vieja, agregado por otra vía de automatización, o aprovisionado antes del cambio simplemente no lo tiene — y no hay ningún objeto a nivel de cluster que lo diga. Obtenés un control silencioso y parcial: 9 nodos imponen, 1 no, y la carga de trabajo del atacante aterriza en el décimo. El riesgo espejo es el fallo opuesto: un nodo que *sí* tiene `_default` pero al que le falta una entrada en `certs.d` para un registry legítimo falla cada pull desde él con un confuso `connection refused`, y si ese registry sirve la imagen del CNI, el nodo nunca llega a Ready. *Detección:* (1) gestioná `certs.d` con la misma gestión de configuración que aprovisiona el nodo y alertá ante deriva; (2) corré un DaemonSet que lea `/etc/containerd/certs.d` desde un hostPath y reporte la configuración de registries del nodo como métrica/anotación, y después alertá ante cualquier nodo cuya configuración difiera de la flota; (3) un Job canario sintético por nodo que intente un pull desde un registry conocido como bloqueado y reporte el éxito como un fallo.

**Q7.3** — Cadena: el atacante hace `exec` en un Pod de `app` → lee el token de ServiceAccount montado en `/var/run/secrets/kubernetes.io/serviceaccount/token` → si esa SA tiene `get secrets` en el namespace (o el Pod ya tiene `regcred` proyectado como volumen/variable de entorno), lee el `dockerconfigjson` → la credencial otorga **push**, así que pushea una capa maliciosa a `registry.internal:5000/prod/nginx` y reapunta el tag `1.27` → cada nodo que haga un pull fresco, y cada Pod reprogramado, corre su código con la identidad de producción. *Dos controles que rompen la cadena:* (1) **Separá las credenciales por verbo.** El cluster solo necesita **pull**; el push pertenece exclusivamente al CI. Una cuenta robot de solo-pull en el cluster hace que la credencial robada sea inútil para el ataque. (2) **Imposición de firmas en la admisión** (Ejercicio 5) — incluso con acceso de push, el atacante no puede producir una firma que verifique contra tu clave, así que el tag reapuntado se rechaza y el compromiso degrada a un DoS (Q4.5). Controles de apoyo: ServiceAccounts de mínimo privilegio (`automountServiceAccountToken: false`), inmutabilidad de tags del lado del registry, y alcance de credenciales por namespace.

**Q7.4** — La de **ServiceAccount** es más difícil de auditar, por dos razones: es *invisible en el manifest del Pod* — nada en el YAML del Deployment le dice a un revisor que se está inyectando una credencial de registry — y es *transitiva*, aplicándose a cada Pod actual y futuro que use esa SA, incluidos los creados por controllers que nadie revisó. Un `imagePullSecrets` a nivel de Pod al menos está declarado donde se usa. El atacante con alcance de namespace y `create pods` obtiene gratis la de **ServiceAccount**: simplemente crea un Pod con `serviceAccountName: <la-que-tiene-el-secret>` y el kubelet obtiene la credencial en su nombre — nunca necesita `get secrets` en absoluto, y su Pod puede armarse de modo que el pull ocurra contra un registry que ellos controlan, capturando la credencial en el header `Authorization`. Por eso `imagePullSecrets` en la ServiceAccount `default` es un hallazgo genuino, no una nimiedad.

**Q7.5** — *Rotación:* el proveedor de credenciales acuña un token fresco por cada pull (cacheado ≤12 h) sin humanos en el medio; un Secret estático rota solo cuando alguien se acuerda, lo que en la práctica significa nunca — auditá cualquier cluster y vas a encontrar Secrets `dockerconfigjson` de años. *Alcance:* la credencial del proveedor se deriva de la identidad de nube del **nodo** y está restringida por `matchImages` a patrones de registry específicos y típicamente a acceso de solo lectura a ECR/GCR/ACR; un Secret estático es una credencial al portador con los permisos que se le hayan otorgado al crearla, usable desde cualquier lugar de internet por cualquiera que la obtenga. *Valor de exfiltración:* un token robado del proveedor vale como mucho 12 horas de acceso de pull desde un contexto que ya podía descargar; un `dockerconfigjson` robado es una credencial duradera, portátil, a menudo con capacidad de push, que un atacante puede usar desde su propia laptop meses después. El proveedor además nunca coloca la credencial en etcd ni en el sistema de archivos de un Pod, eliminando toda la clase de ataque de Q7.3. Ver [kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/).

### Bloque 8 — Modos de fallo

**Q8.1** — (1) `crictl ps -a --name kube-apiserver --latest` — te dice si el container existe siquiera y su estado/cantidad de reinicios. `Exited` con un `ATTEMPT` que se incrementa significa que el proceso arranca y muere (error de configuración); *ningún container* significa que el kubelet ni siquiera lo está creando (error de parseo del manifest o kubelet caído). (2) `crictl logs <id>` — te da la cadena de error real del API server, que para problemas de admisión nombra el archivo o el plugin. Este es el que normalmente lo resuelve. (3) `journalctl -u kubelet -n 50 --no-pager` — te dice lo que no podés aprender del container, porque si el paso (1) no encontró container el fallo está *por encima* de él: YAML inválido en `/etc/kubernetes/manifests/kube-apiserver.yaml`, un `hostPath` que no existe con `type: Directory`, o un fallo al descargar la imagen. Cada paso responde una pregunta que el anterior no pudo: ¿existe el container? → ¿por qué murió el proceso? → ¿por qué nunca se creó el container?

**Q8.2** — `Forbidden` es HTTP **403**: una política se evaluó con éxito y su veredicto fue *no*. La petición está bien formada, el sistema está sano, y la respuesta es una denegación deliberada — mirá la **política**. `InternalError` es HTTP **500**: el API server no pudo *completar* la admisión porque falló un componente del que depende — el webhook estaba inalcanzable, dio timeout, o devolvió basura. El sistema está roto, nunca se alcanzó un veredicto — mirá la **infraestructura** (Endpoints, readiness del Pod, network policy entre el API server y el Service del webhook, validez del certificado, timeout). El atajo práctico: 403 significa leer el texto del mensaje, nombra la política; 500 significa correr `kubectl -n <ns> get endpoints <webhook-svc>` y trabajar hacia afuera desde ahí.

**Q8.3** — De menos a más peligroso:

1. **(a) `validationFailureAction: Audit`** — el más acotado y reversible. La política sigue corriendo, sigue evaluando cada imagen, y sigue escribiendo entradas de `PolicyReport`, así que conservás un registro completo de exactamente qué se dejó pasar durante el incidente y podés remediarlo después. Nada más cambia.
2. **(c) Agregar el namespace a `exclude`** — acotado a un namespace, así que el resto del cluster sigue con imposición, pero perdés *toda* la visibilidad de ese namespace: sin reportes, sin registro de qué corrió. Peor que (a) porque la evidencia desaparece, mejor que (b)/(d) porque el radio de impacto está acotado.
3. **(b) Borrar el ClusterPolicy** — pérdida del control y de todo el reporte a nivel de todo el cluster. La recuperación requiere re-aplicar el manifest, lo cual es fácil si está en Git e imposible de recordar si se aplicó a mano. Alto riesgo de que nunca se restaure.
4. **(d) `failurePolicy: Ignore` en el webhook** — el más peligroso por lejos, y por una razón no obvia: no solo deshabilita *esta* política, deshabilita **todas las políticas de Kyverno** del cluster, incluidas las que no tienen nada que ver con imágenes (seguridad de pods, límites de recursos, network policies por defecto). Además falla **silenciosamente** — no hay denegación, no hay reporte, no hay señal de que algo esté mal — y es el cambio con más probabilidad de quedar puesto para siempre porque nunca nada se queja. Nunca recurras a él bajo presión de tiempo.

**Q8.4** — Rotación de clave de riesgo cero, usando solo lo construido arriba:

1. **Agregar antes de quitar.** Extendé el bloque de attestor de la política de Kyverno para que acepte *ambas* claves — una sola lista `entries` con dos entradas `keys` bajo `count: 1` (semántica OR, según Q5.6). Aplicala y confirmá que cada imagen actualmente en ejecución sigue verificando. Nada puede romperse, porque la clave vieja sigue siendo confiable.
2. **Inventario.** Corré el bucle del paso 3 de este ejercicio sobre cada imagen de cada Pod *y* de cada plantilla de pod (Q1.4), produciendo la lista exacta de artefactos que necesitan una firma nueva.
3. **Contrafirmar en el lugar.** Para cada digest de esa lista, `cosign sign --key <clave-nueva>` **el digest existente** — firmar no reconstruye ni modifica la imagen, solo agrega otro artefacto `.sig`. Ninguna carga de trabajo se toca, ningún Pod se reinicia, ningún rollout.
4. **Verificar la convergencia.** Volvé a correr el bucle de inventario usando *solo* la nueva clave pública. No avances hasta que devuelva cero `UNSIGNED`. Incluí las imágenes referenciadas por Deployments escalados a cero y por CronJobs que todavía no se dispararon.
5. **Quitar la clave vieja** de la política, y recién entonces revocarla en el origen (deshabilitar en el KMS, o agregar las entradas de Rekor de la clave comprometida a una lista de denegación si la rotación fue por compromiso y no por vencimiento de rutina).
6. **Demostralo.** Forzá la reprogramación de una carga de trabajo canaria y confirmá que se admite. Mantené el material de la clave vieja archivado (no activo) para poder reagregarla si el inventario del paso 4 se perdió algo.

El orden es toda la respuesta: **confiá en la clave nueva en todas partes antes de firmar con ella, y firmá todo antes de dejar de confiar en la vieja.** Invertir dos pasos cualesquiera produce una caída.

**Q8.5** — Con el control plane caído: **VAP, ImagePolicyWebhook y Kyverno dejan todos de imponer**, porque los tres son mecanismos de admisión del API server y no hay API server que los ejecute. Pero notá *qué significa eso* — con el API server caído tampoco se crean Pods nuevos a través de la API, así que la ausencia de imposición es mayormente irrelevante para las cargas de trabajo dirigidas por la API. Lo que sí sigue ocurriendo es la parte peligrosa: **los kubelets siguen corriendo, siguen reiniciando containers, y siguen arrancando static Pods desde `/etc/kubernetes/manifests`** — enteramente por fuera de la admisión, haya control plane o no. El único control que sobrevive es el **allowlist de registries de containerd**, porque lo impone el runtime en el nodo mismo. *Qué te dice eso:* colocá el control que más necesitás que sea inevadible en la **capa más baja que pueda imponerlo**. La admisión es donde obtenés buena expresividad de política, buenos mensajes de error y gestión centralizada — así que poné ahí tus controles *primarios* — pero entendé que son advertencias respecto de cualquiera que tenga root en un nodo. La imposición a nivel de nodo (allowlist de containerd, imágenes de nodo inmutables, `/etc/kubernetes/manifests` de solo lectura con monitoreo de integridad de archivos, y un agente de seguridad en runtime como Falco vigilando pulls de imágenes inesperados) es lo que queda cuando el control plane no está o un atacante ya está dentro de él. La defensa en profundidad acá no es redundancia porque sí — las dos capas fallan bajo condiciones genuinamente distintas.

</details>

---

## Fuentes oficiales

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Admission Controllers Reference — ImagePolicyWebhook* — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Images* (pull policy, digests, imagePullSecrets) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Configure a kubelet image credential provider* — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/
- Kubernetes, *Security Checklist* — https://kubernetes.io/docs/concepts/security/security-checklist/
- Sigstore, *cosign documentation* — https://docs.sigstore.dev/ · https://github.com/sigstore/cosign
- in-toto, *Attestation Framework* — https://github.com/in-toto/attestation
- SLSA, *Security Levels v1.0* — https://slsa.dev/spec/v1.0/levels
- containerd, *Registry Configuration — hosts.toml* — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- Kyverno, *Verify Images* — https://kyverno.io/docs/writing-policies/verify-images/
- OPA Gatekeeper, *Policy Library* (`K8sAllowedRepos`) — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Anchore syft — https://github.com/anchore/syft · Trivy — https://trivy.dev/

> **Nota de estrategia de examen.** El entorno del CKS solo permite `kubernetes.io/docs`, `kubernetes.io/blog`, y una lista corta de sitios de proyectos — la documentación de Sigstore, Kyverno y Gatekeeper **no** está entre ellos. Bajo condiciones de examen, las soluciones alcanzables para esta competencia son `ImagePolicyWebhook` (Ejercicio 3, completamente documentado en el enlace de kubernetes.io de arriba), `ValidatingAdmissionPolicy` (Ejercicio 2), y el trabajo de inventario de imágenes/digests (Ejercicio 1). Practicá el Ejercicio 3 hasta que puedas editar `kube-apiserver.yaml` — flag del plugin, flag del archivo de configuración, **volume y volumeMount** — y dejar el API server sano de nuevo en menos de cuatro minutos sin consultar nada.