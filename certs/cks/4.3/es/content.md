# CKS 4.3 — Asegurá tu cadena de suministro

**Certificación:** Certified Kubernetes Security Specialist (CKS), currículum v1.34
**Dominio:** Supply Chain Security (20 %) · **Peso del sub-tema:** 5
**Alcance:** registries permitidos, procedencia de imágenes, firma y validación de artefactos (firmas, attestations, SBOMs), enforcement en admission, enforcement a nivel de nodo (containerd).

---

## 1. El problema arquitectónico

### 1.1 La brecha de confianza

La spec de un `Pod` de Kubernetes contiene una cadena de texto:

```yaml
containers:
- name: api
  image: acme/api:v2.7.1
```

Esa cadena es un **pedido de resolución de nombre**, no la prueba de nada. Entre el commit de código fuente y el proceso corriendo bajo un kubelet, el control atraviesa al menos siete fronteras de confianza:

```
   developer          CI runner            registry            cluster
   ─────────          ─────────            ────────            ───────
   git commit ──► build (Dockerfile) ──► push manifest ──► kube-apiserver
        │              │                      │                 │  admission
        │              │                      │                 ▼
        │              │                      │            scheduler
        │              │                      │                 │
        ▼              ▼                      ▼                 ▼
   [1] identity   [2] build env         [3] registry      [4] kubelet
       of author       + dependencies       mutability        image pull
                       (base image,         (tag → digest)         │
                        packages)                                  ▼
                                                            [5] containerd
                                                                resolve + unpack
```

Cada frontera tiene un modo de fallo documentado y explotado:

| # | Frontera | Ataque | Precedente real |
|---|---|---|---|
| 1 | Identidad del autor | Credenciales robadas de un maintainer, co-maintainer malicioso | `xz-utils`/CVE-2024-3094 (2024) |
| 2 | Entorno de build | Un CI comprometido inyecta el payload en tiempo de build; el código fuente queda limpio | SolarWinds Orion (2020), Codecov bash uploader (2021) |
| 3 | Registry / naming | Typosquatting, dependency confusion, re-push de un tag, toma de control de una cuenta del registry | Campañas de cryptominers en `docker.io/*`; namespace confusion (Birsan, 2021) |
| 4 | Camino del pull | MITM sobre un mirror en texto plano, secuestro de DNS del hostname del registry | `insecure-registries` mal configurado |
| 5 | Caché del nodo | Capa maliciosa pre-sembrada con un tag legítimo en un nodo comprometido | `imagePullPolicy: IfNotPresent` en nodos multi-tenant |

**Un tag no es una identidad.** `acme/api:v2.7.1` es un puntero mutable en la base de datos de otra persona. El único identificador inmutable en OCI es el digest del manifest — `sha256:…` — porque es la dirección de contenido del manifest, que a su vez direcciona por contenido el blob de configuración y cada capa.

### 1.2 Qué significa "asegurar la cadena de suministro" en tiempo de admission

No podés verificar un build desde adentro de un cluster. Lo que *sí* podés hacer es negarte a correr cualquier cosa cuya procedencia no puedas verificar, y reducir el conjunto de cosas que estás dispuesto a verificar. Eso se descompone en exactamente tres preguntas ejecutables, en orden:

1. **¿De dónde vino esto?** → *registries permitidos* (allowlist por host del registry / ruta del repositorio).
2. **¿Es exactamente lo que se publicó?** → *pinning por digest* (rechazar tags mutables, o resolver tag → digest en admission y fijarlo).
3. **¿Quién responde por esto, y qué afirma?** → *verificación de firmas y attestations* (cosign/Sigstore, SLSA provenance, SBOM).

La pregunta 1 es barata, offline, y frena el 80 % de la exposición accidental. La pregunta 3 es la única que sobrevive al compromiso de un registry. **La allowlist de registries sin verificación de firmas es un perímetro; la verificación de firmas sin allowlist es trabajo ilimitado.** Los clusters de producción necesitan ambas, en ese orden, porque las políticas de firma son por glob de imagen y un glob solo significa algo si el namespace de imágenes posibles está cerrado.

### 1.3 Dónde puede vivir el enforcement

```
kubectl create -f pod.yaml
        │
        ▼
  ┌──────────────────────── kube-apiserver ────────────────────────┐
  │ authn ─► authz ─► MUTATING admission ─► object schema ─►       │
  │                    │                    VALIDATING admission   │
  │                    │                     │                     │
  │                    │  Kyverno mutate     │  ValidatingAdmissionPolicy (CEL, in-process)
  │                    │  (resolve digest)   │  ImagePolicyWebhook (in-tree plugin)
  │                    │                     │  Gatekeeper / Kyverno validate (webhook)
  │                    │                     │  policy-controller (webhook)
  │                    └─────────────────────┴──► etcd
  └────────────────────────────────────────────────────────────────┘
        │
        ▼  (scheduler binds)
  ┌─────────── kubelet ───────────┐
  │ imagePullPolicy               │
  │ imagePullSecrets              │
  │ CRI ImagePull ────────────────┼──► containerd
  └───────────────────────────────┘        │  /etc/containerd/certs.d/*/hosts.toml
                                           │  registry mirrors, capabilities, TLS pinning
                                           ▼
                                        registry
```

Dos capas independientes, y querés las dos:

* **Admission** es la autoridad en materia de política y produce buenos mensajes de error, pero solo ve la *cadena de texto*. Si un nodo está comprometido o el hostname de un registry fue secuestrado, admission ya dijo que sí.
* **containerd** es la autoridad sobre qué bytes llegan realmente, pero no tiene noción de namespace, tenant ni workload. No puede decir "team-a puede hacer pull del repo X".

---

## 2. Análisis comparativo de los mecanismos de enforcement

### 2.1 Enforcement de registries permitidos

| Mecanismo | Dónde corre | Capaz de verificar firmas | Llamadas de red | Latencia | Sobrevive a una caída del webhook | Costo operativo | Relevante para el examen CKS |
|---|---|---|---|---|---|---|---|
| **ValidatingAdmissionPolicy** (CEL) | En el propio proceso del kube-apiserver | ❌ (CEL no puede hacer criptografía ni salidas de red) | ninguna | ~µs | N/A — no puede caerse | Muy bajo (sin componentes) | Alto (GA desde 1.30) |
| **ImagePolicyWebhook** (plugin in-tree) | apiserver → backend HTTPS externo | ✅ si el backend lo hace | sí, por Pod | 1–50 ms + backoff | lo decide `defaultAllow` | Alto: flags del static Pod, certificados, sin DNS del cluster | **Muy alto** — tarea clásica del CKS |
| **OPA Gatekeeper** | Webhook (Rego) | ⚠️ solo vía external data / providers | salto al webhook | 5–30 ms | `failurePolicy` | Medio; requiere saber Rego | Medio |
| **Kyverno** | Webhook (YAML/JMESPath/CEL) | ✅ `verifyImages` nativo | webhook + registry | 20 ms–2 s (ida y vuelta al registry) | `failurePolicy` | Medio | Medio |
| **sigstore policy-controller** | Webhook | ✅ hecho específicamente para esto | webhook + Fulcio/Rekor | 50 ms–2 s | `failurePolicy` | Medio | Bajo, pero estándar en producción |
| **containerd `hosts.toml`** | Nodo | ❌ | solo en el pull | 0 | Siempre activo | Gestión de configuración por nodo | Medio |
| **NetworkPolicy / firewall de egress** | Nodo/CNI | ❌ | n/a | 0 | Siempre activo | Bajo | Medio |

**Heurística de selección:**

* Solo allowlist de registries, sin querer dependencias externas → **ValidatingAdmissionPolicy**. Es la respuesta correcta más barata en ≥1.30 y no puede fallar abierto porque no puede fallar.
* Escenario de examen que menciona `--admission-control-config-file` o `AdmissionConfiguration` → **ImagePolicyWebhook**. Nada más usa ese archivo.
* Verificación de firmas/attestations → **Kyverno** o **policy-controller**. VAP no puede hacerlo: CEL no tiene primitivas criptográficas ni salida de red, por diseño.

### 2.2 Modelos de firma (Sigstore/cosign)

| Modelo | Material de clave | Anclaje de identidad | Revocación | Rotación | Airgap | Mejor encaje |
|---|---|---|---|---|---|---|
| **Con clave** (`cosign.key`) | Par de claves ECDSA P-256 de larga vida | La clave misma | Rotar + volver a firmar; no hay CRL | Manual, dolorosa | ✅ funciona totalmente offline | Equipos chicos, airgapped, regulados |
| **Respaldado por KMS** (`awskms://`, `gcpkms://`, `hashivault://`, PKCS#11) | La clave privada nunca sale del HSM/KMS | Identidad IAM sobre la clave del KMS | Deshabilitar la clave del KMS | Versiones de la clave en el KMS | ⚠️ necesita el KMS alcanzable | Default empresarial |
| **Keyless** (Fulcio + Rekor) | Clave efímera, certificado X.509 de 10 minutos ligado a una identidad OIDC | Subject + issuer OIDC (p. ej. la ref de un workflow de GitHub Actions) | No hace falta — el certificado ya expiró; la confianza está anclada a la identidad | N/A (no hay nada que rotar) | ❌ necesita Fulcio/Rekor (o un Sigstore privado) | Pipelines públicos/SaaS manejados por CI |

Keyless no es "sin clave" — es *"la clave existió durante 10 minutos, fue ligada a una identidad OIDC verificada por Fulcio, y esa ligadura está en un log de transparencia a prueba de manipulación (Rekor)"*. La verificación chequea la cadena de certificados **y** la prueba de inclusión en Rekor, y luego afirma que el SAN del certificado coincide con una identidad que vos permitís. La consecuencia crítica: **`cosign verify` sin `--certificate-identity` no significa nada** — cualquiera con una cuenta de Google puede producir una firma keyless válida.

### 2.3 Tag vs digest

| Propiedad | `acme/api:v2.7.1` | `acme/api@sha256:9f2a…` |
|---|---|---|
| Inmutable | ❌ (el registry puede re-apuntarlo) | ✅ (direccionado por contenido) |
| Sobrevive al compromiso del registry | ❌ | ✅ (los bytes fallan el chequeo de digest en el pull) |
| La firma se liga a esto | ❌ (cosign firma el digest; el tag es una búsqueda) | ✅ |
| Legible por humanos / amigable con GitOps | ✅ | ❌ (necesita automatización: Renovate, Flux image automation, `mutateDigest` de Kyverno) |
| Envenenamiento del caché del nodo (`IfNotPresent`) | ❌ vulnerable | ✅ el mismatch de digest aborta |

**Posición de producción:** los desarrolladores escriben tags; un paso de mutating admission (`mutateDigest: true` de Kyverno) o el pipeline de promoción de CI/CD los reescribe a digests antes de que el objeto se persista. Imponer "solo digests" a los humanos sin un paso de mutación es una fábrica de tickets.

---

## 3. Registries permitidos — implementaciones completas

Política objetivo para todos los ejemplos:

> Toda imagen de container, initContainer y ephemeralContainer debe venir de `registry.internal.acme.io/` o `registry.k8s.io/`. `kube-system` está exento. Las denegaciones deben nombrar la imagen infractora.

### 3.1 ValidatingAdmissionPolicy (línea base recomendada, K8s ≥ 1.30)

```yaml
# vap-allowed-registries.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries.acme.io
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
    - apiGroups:   ["apps"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["deployments", "statefulsets", "daemonsets", "replicasets"]
    - apiGroups:   ["batch"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["jobs", "cronjobs"]
  variables:
  # Normalise: a bare Pod exposes .spec, workloads expose .spec.template.spec,
  # CronJob exposes .spec.jobTemplate.spec.template.spec.
  - name: podSpec
    expression: >-
      has(object.spec.template) ? object.spec.template.spec :
      (has(object.spec.jobTemplate) ? object.spec.jobTemplate.spec.template.spec :
       object.spec)
  - name: allImages
    expression: >-
      variables.podSpec.containers.map(c, c.image) +
      (has(variables.podSpec.initContainers) ?
        variables.podSpec.initContainers.map(c, c.image) : []) +
      (has(variables.podSpec.ephemeralContainers) ?
        variables.podSpec.ephemeralContainers.map(c, c.image) : [])
  - name: allowedPrefixes
    expression: >-
      ['registry.internal.acme.io/', 'registry.k8s.io/']
  - name: badImages
    expression: >-
      variables.allImages.filter(i,
        !variables.allowedPrefixes.exists(p, i.startsWith(p)))
  validations:
  - expression: "size(variables.badImages) == 0"
    messageExpression: >-
      'image(s) from a non-permitted registry: ' + variables.badImages.join(', ') +
      '. Permitted prefixes: ' + variables.allowedPrefixes.join(', ')
    reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries.acme.io
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-node-lease"]
```

Notas que importan en producción:

* **Hacer match de los controladores de workload además de `pods` no es redundante** — es la diferencia entre que un desarrollador reciba un error inmediato en `kubectl apply -f deployment.yaml` y un Deployment silenciosamente en `0/3 READY` cuyo error real está enterrado en `kubectl describe replicaset`.
* Las guardas `has()` son obligatorias: `initContainers` y `ephemeralContainers` tienen semántica `omitempty`, así que `object.spec.initContainers` en un Pod que no los tiene lanza `no such key` y — con `failurePolicy: Fail` — deniega todos los Pods del cluster.
* Empezá con `validationActions: ["Audit", "Warn"]`, leé el audit log, y recién ahí pasá a `Deny`.

Despliegue y verificación:

```console
$ kubectl apply -f vap-allowed-registries.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/allowed-registries.acme.io created
validatingadmissionpolicybinding.admissionregistration.k8s.io/allowed-registries-binding created

$ kubectl get validatingadmissionpolicy allowed-registries.acme.io
NAME                         VALIDATIONS   PARAMKIND   AGE
allowed-registries.acme.io   1             <unset>     12s

$ kubectl run rogue --image=docker.io/library/nginx:1.27 -n default
Error from server (Forbidden): pods "rogue" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: docker.io/library/nginx:1.27. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/

$ kubectl run ok --image=registry.internal.acme.io/library/nginx:1.27 -n default
pod/ok created
```

Probá el camino de un Deployment sin crear nada:

```console
$ kubectl create deployment bad --image=quay.io/prometheus/node-exporter:v1.8.2 \
    --dry-run=server -o yaml
error: failed to create deployment: admission webhook denied the request: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: quay.io/prometheus/node-exporter:v1.8.2. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/
```

### 3.2 ImagePolicyWebhook (plugin de admission in-tree)

Este es el mecanismo al que apunta explícitamente el currículum del CKS, y el único que se configura mediante `--admission-control-config-file`. También es el más frágil, así que entendé cada archivo.

**Paso 1 — AdmissionConfiguration en el nodo del control plane**

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
      allowTTL: 50          # seconds to cache an "allow" decision
      denyTTL: 50           # seconds to cache a "deny" decision
      retryBackoff: 500     # MILLISECONDS between retries
      defaultAllow: false   # fail CLOSED — the only correct production value
```

> `defaultAllow: true` significa "si mi motor de políticas está inalcanzable, admitir cualquier cosa". Ese es un control de seguridad que se deshabilita a sí mismo justo cuando algo anda mal. Las tareas del examen casi siempre quieren `false`.

**Paso 2 — el kubeconfig que usa el apiserver para llegar al backend**

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
- name: image-policy-backend
  cluster:
    certificate-authority: /etc/kubernetes/admission/webhook-ca.crt
    server: https://10.96.71.14:443/image_policy     # ClusterIP or host endpoint, NOT a *.svc name
users:
- name: kube-apiserver
  user:
    client-certificate: /etc/kubernetes/admission/apiserver-client.crt
    client-key: /etc/kubernetes/admission/apiserver-client.key
contexts:
- name: image-policy
  context:
    cluster: image-policy-backend
    user: kube-apiserver
current-context: image-policy
```

**Trampa crítica de producción:** a diferencia de `ValidatingWebhookConfiguration` (que soporta una referencia `service:` resuelta internamente por el apiserver), `ImagePolicyWebhook` toma una URL cruda desde un kubeconfig. El kube-apiserver corre en la red del host y **no** usa el DNS del cluster, así que `https://image-policy.image-policy.svc:443` no va a resolver. Usá la ClusterIP del Service, un endpoint local del nodo, o corré el backend como servicio de systemd / static Pod en el nodo del control plane.

**Paso 3 — conectarlo al manifest del static Pod**

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml   (excerpt — edit in place)
spec:
  containers:
  - command:
    - kube-apiserver
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
    # ... existing flags unchanged ...
    volumeMounts:
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
  volumes:
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

Olvidarse del par `volumeMounts`/`volumes` es el fallo más común: el container del apiserver no puede ver el archivo y entra en crash-loop con `open /etc/kubernetes/admission/admission-config.yaml: no such file or directory`.

**Paso 4 — el contrato del backend (`imagepolicy.k8s.io/v1alpha1`)**

Petición que hace POST el apiserver:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [
      { "image": "docker.io/library/nginx:1.27" },
      { "image": "registry.internal.acme.io/tools/busybox@sha256:9ae97d3…" }
    ],
    "annotations": {
      "policy.image-policy.k8s.io/ticket-1234": "break-glass"
    },
    "namespace": "team-a"
  }
}
```

Solo se reenvían las annotations que hacen match con `*.image-policy.k8s.io/*` — todo lo demás se descarta, así que un tenant no puede contrabandear pistas al backend a través de labels arbitrarias.

Respuesta esperada:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": {
    "allowed": false,
    "reason": "image docker.io/library/nginx:1.27 is not from a permitted registry"
  }
}
```

Un backend de referencia mínimo, desplegable como Deployment + Service (TLS terminado por el container, certificado de cliente verificado contra la CA del apiserver):

```yaml
# imagepolicy-backend.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: image-policy
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: imagepolicy-code
  namespace: image-policy
data:
  server.py: |
    import json, ssl
    from http.server import BaseHTTPRequestHandler, HTTPServer

    ALLOWED_PREFIXES = ("registry.internal.acme.io/", "registry.k8s.io/")
    REQUIRE_DIGEST = True

    def evaluate(images):
        for image in images:
            if not image.startswith(ALLOWED_PREFIXES):
                return False, f"image {image} is not from a permitted registry"
            if REQUIRE_DIGEST and "@sha256:" not in image:
                return False, f"image {image} must be pinned to a digest"
        return True, ""

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            review = json.loads(self.rfile.read(length) or b"{}")
            images = [c.get("image", "") for c in review.get("spec", {}).get("containers", [])]
            allowed, reason = evaluate(images)
            body = json.dumps({
                "apiVersion": "imagepolicy.k8s.io/v1alpha1",
                "kind": "ImageReview",
                "status": {"allowed": allowed, "reason": reason},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            print("image-policy %s" % (fmt % args), flush=True)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    context.load_verify_locations("/tls/client-ca.crt")
    context.verify_mode = ssl.CERT_REQUIRED

    server = HTTPServer(("0.0.0.0", 8443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("image-policy backend listening on :8443", flush=True)
    server.serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-policy
  namespace: image-policy
spec:
  replicas: 2
  selector:
    matchLabels: { app: image-policy }
  template:
    metadata:
      labels: { app: image-policy }
    spec:
      # The backend must be schedulable even when the cluster is unhealthy.
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: { app: image-policy }
      containers:
      - name: server
        image: registry.internal.acme.io/library/python:3.12-slim
        command: ["python3", "/code/server.py"]
        ports:
        - containerPort: 8443
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 10001
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { memory: 128Mi }
        volumeMounts:
        - { name: code, mountPath: /code, readOnly: true }
        - { name: tls,  mountPath: /tls,  readOnly: true }
      volumes:
      - name: code
        configMap: { name: imagepolicy-code }
      - name: tls
        secret: { secretName: image-policy-tls }   # tls.crt, tls.key, client-ca.crt
---
apiVersion: v1
kind: Service
metadata:
  name: image-policy
  namespace: image-policy
spec:
  clusterIP: 10.96.71.14        # pin it: the apiserver kubeconfig hardcodes this address
  selector: { app: image-policy }
  ports:
  - port: 443
    targetPort: 8443
```

Aplicalo, y después reiniciá el apiserver tocando el manifest del static Pod:

```console
$ sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f imagepolicy-backend.yaml
namespace/image-policy created
configmap/imagepolicy-code created
deployment.apps/image-policy created
service/image-policy created

$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml     # add the two flags + volume
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             POD ID
0c31f9a7c1b2e  0f4b02c4e6d1a  9 seconds ago   Running   kube-apiserver   4a1e0b9c7d3f2

$ kubectl run rogue --image=docker.io/library/alpine:3.20 --restart=Never -- sleep 3600
Error from server (Forbidden): pods "rogue" is forbidden: image policy webhook backend denied one or more images: image docker.io/library/alpine:3.20 is not from a permitted registry
```

### 3.3 Equivalente en Kyverno (con mutación a digest)

```yaml
# kyverno-registry-and-digest.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist
  annotations:
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce   # Kyverno >=1.12: prefer per-rule validate.failureAction
  background: true
  failurePolicy: Fail
  rules:
  - name: only-permitted-registries
    match:
      any:
      - resources:
          kinds: ["Pod"]
    exclude:
      any:
      - resources:
          namespaces: ["kube-system", "kyverno"]
    validate:
      message: >-
        Images must come from registry.internal.acme.io or registry.k8s.io.
        Found: {{ request.object.spec.containers[].image | join(', ', @) }}
      pattern:
        spec:
          =(ephemeralContainers):
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
          =(initContainers):
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
          containers:
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
```

El prefijo `=( )` es el *anchor condicional* de Kyverno: "si esta clave existe, tiene que hacer match". Sin él, un Pod sin `initContainers` falla el pattern.

---

## 4. Enforcement a nivel de nodo: containerd

La política de admission la esquiva cualquier cosa que hable directamente con el socket del CRI (un nodo comprometido, un DaemonSet con el socket montado, `crictl`). Cerrá el conjunto de registries también en el nodo.

**containerd 1.7 (`/etc/containerd/config.toml`)**

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

**containerd 2.x** — el plugin de CRI se dividió; la mitad de imágenes es dueña de la configuración de registries:

```toml
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

Después, archivos por host. Redirigí Docker Hub al mirror interno de pull-through y *eliminá* el fallback upstream:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry.internal.acme.io"

[host."https://registry.internal.acme.io/v2/dockerhub-remote"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "/etc/containerd/certs.d/acme-root-ca.crt"
```

Como ninguna entrada `[host]` apunta a `registry-1.docker.io`, containerd nunca contacta a Docker Hub — incluso si se esquiva admission.

Fijá la CA del registry interno y prohibí el texto plano:

```toml
# /etc/containerd/certs.d/registry.internal.acme.io/hosts.toml
server = "https://registry.internal.acme.io"

[host."https://registry.internal.acme.io"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/acme-root-ca.crt"
  skip_verify = false
```

```console
$ sudo systemctl restart containerd
$ sudo crictl pull docker.io/library/alpine:3.20
FATA[0002] pulling image: failed to pull and unpack image "docker.io/library/alpine:3.20": failed to resolve reference "docker.io/library/alpine:3.20": failed to do request: Head "https://registry.internal.acme.io/v2/dockerhub-remote/library/alpine/manifests/3.20": x509: certificate signed by unknown authority

$ sudo crictl pull registry.internal.acme.io/library/alpine:3.20
Image is up to date for sha256:beefc9f9a5a3f52c2b0c9b0f4d31d9c5b78e3f8a2d1e6c4b9a0f7e2d3c1b5a48
```

### 4.1 `AlwaysPullImages` — el corolario de multi-tenancy

Con `imagePullPolicy: IfNotPresent`, cualquier Pod en un nodo puede correr una imagen *privada* que algún otro tenant ya trajo a ese nodo, sin credenciales. En clusters compartidos, habilitá el plugin in-tree para que el kubelet se re-autentique en cada pull:

```yaml
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ImagePolicyWebhook
```

Contrapartida: cada arranque de Pod hace una ida y vuelta al registry (un HEAD del manifest si las capas están cacheadas). En un cluster de 500 nodos reiniciando después de una caída, esto es una estampida contra el registry — dimensioná el caché de pull-through en consecuencia, o acotá el comportamiento con una mutación de Kyverno limitada a los namespaces multi-tenant.

---

## 5. Firma y validación de artefactos

### 5.1 Qué escribe realmente cosign en el registry

Firmar `registry.internal.acme.io/team-a/api@sha256:9f2a…` no modifica la imagen. cosign hace push de un *segundo* artefacto OCI:

* **Convención de tags (OCI 1.0, por defecto):** un nuevo tag `sha256-9f2a….sig` en el *mismo repositorio*, cuyas capas son los payloads de la firma y cuyas annotations contienen la firma (`dev.cosignproject.cosign/signature`) y, para keyless, la cadena de certificados de Fulcio y el bundle SET de Rekor.
* **Referrers API (OCI 1.1):** `cosign sign --registry-referrers-mode oci-1-1 …` adjunta la firma como referrer con `subject` apuntando al digest de la imagen. Requiere soporte del registry (`GET /v2/<name>/referrers/<digest>`).

Consecuencias que vas a encontrar en producción:

1. **Copiar una imagen entre registries con `docker pull`/`docker push` descarta la firma en silencio.** Usá `crane copy`/`skopeo copy --all` sobre el repositorio, o `cosign copy`.
2. Las políticas de retención/GC a nivel de repositorio que borran artefactos "sin tag o con tags raros" van a borrar tus firmas.
3. La verificación requiere acceso de **pull** al mismo repositorio — el descubrimiento de firmas es una lectura del registry, no una lectura de Rekor.

### 5.2 Firma con clave — transcripción completa

```console
$ cosign version
  ______   ______        _______. __    _______ .__   __.
 /      | /  __  \      /       ||  |  /  _____||  \ |  |
|  ,----'|  |  |  |    |   (----`|  | |  |  __  |   \|  |
|  |     |  |  |  |     \   \    |  | |  | |_ | |  . `  |
|  `----.|  `--'  | .----)   |   |  | |  |__| | |  |\   |
 \______| \______/  |_______/    |__|  \______| |__| \__|
cosign: A tool for Container Signing, Verification and Storage in an OCI registry.

GitVersion:    v2.4.1
GitCommit:     8b1a2fd05a0b1b3b4a92f1f8fcb0f2e7f4c9c3a1
GoVersion:     go1.23.2
Platform:      linux/amd64

$ export COSIGN_PASSWORD='<from vault>'
$ cosign generate-key-pair
Private key written to cosign.key
Public key written to cosign.pub

$ IMAGE=registry.internal.acme.io/team-a/api
$ DIGEST=$(crane digest ${IMAGE}:v2.7.1)
$ echo $DIGEST
sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ cosign sign --key cosign.key ${IMAGE}@${DIGEST}
Pushing signature to: registry.internal.acme.io/team-a/api

$ cosign tree ${IMAGE}@${DIGEST}
📦 Supply Chain Security Related artifacts for an image: registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47
└── 🔐 Signatures for an image tag: registry.internal.acme.io/team-a/api:sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.sig
   └── 🍒 sha256:5c1d0b7e3a92f846d5b0c7e2a1f39d84b6c0e5a273f1d8b4c9e0a6f2d3b7c518

$ cosign verify --key cosign.pub ${IMAGE}@${DIGEST} | jq '.[0].optional, .[0].critical'
Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
{
  "Subject": "",
  "Issuer": ""
}
{
  "identity": {
    "docker-reference": "registry.internal.acme.io/team-a/api"
  },
  "image": {
    "docker-manifest-digest": "sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47"
  },
  "type": "cosign container image signature"
}
```

Variante con KMS — la clave privada nunca existe en disco:

```console
$ cosign sign --key awskms:///arn:aws:kms:eu-west-1:111122223333:key/8f0c-…-a91b ${IMAGE}@${DIGEST}
$ cosign public-key --key awskms:///arn:aws:kms:eu-west-1:111122223333:key/8f0c-…-a91b > kms.pub
```

### 5.3 Firma keyless (Fulcio + Rekor)

```console
$ cosign sign ${IMAGE}@${DIGEST}
Generating ephemeral keys...
Retrieving signed certificate...

        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.

By typing 'y', you attest that you grant (or have permission to grant) and agree to have this information stored permanently in transparency logs.
Are you sure you would like to continue? [y/N] y
Your browser will now be opened to:
https://oauth2.sigstore.dev/auth/auth?access_type=online&client_id=sigstore&…
Successfully verified SCT...
tlog entry created with index: 148920371
Pushing signature to: registry.internal.acme.io/team-a/api
```

La verificación **debe** fijar la identidad:

```console
$ cosign verify \
    --certificate-identity 'https://github.com/acme/platform/.github/workflows/release.yaml@refs/heads/main' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    ${IMAGE}@${DIGEST}

Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

El job de CI correspondiente (GitHub Actions, sin ningún secreto de larga vida en ningún lado):

```yaml
# .github/workflows/release.yaml
name: release
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write          # REQUIRED: mints the OIDC token Fulcio exchanges for a cert

jobs:
  build-sign-attest:
    runs-on: ubuntu-24.04
    steps:
    - uses: actions/checkout@v4

    - uses: sigstore/cosign-installer@v3
      with:
        cosign-release: 'v2.4.1'

    - name: Log in to registry
      uses: docker/login-action@v3
      with:
        registry: registry.internal.acme.io
        username: ${{ secrets.REGISTRY_USER }}
        password: ${{ secrets.REGISTRY_TOKEN }}

    - name: Build and push
      id: build
      uses: docker/build-push-action@v6
      with:
        context: .
        push: true
        tags: registry.internal.acme.io/team-a/api:${{ github.sha }}
        provenance: mode=max
        sbom: true

    - name: Sign the image (keyless)
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        cosign sign --yes "registry.internal.acme.io/team-a/api@${DIGEST}"

    - name: Generate and attach an SBOM attestation
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        syft "registry.internal.acme.io/team-a/api@${DIGEST}" \
          -o spdx-json > sbom.spdx.json
        cosign attest --yes \
          --predicate sbom.spdx.json \
          --type spdxjson \
          "registry.internal.acme.io/team-a/api@${DIGEST}"

    - name: Attach a vulnerability-scan attestation
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        trivy image --format cosign-vuln \
          --output vuln.json "registry.internal.acme.io/team-a/api@${DIGEST}"
        cosign attest --yes \
          --predicate vuln.json \
          --type vuln \
          "registry.internal.acme.io/team-a/api@${DIGEST}"
```

### 5.4 Attestations — firmar *afirmaciones*, no solo bytes

Una firma dice "vi este digest". Una **attestation** es una declaración in-toto: una afirmación firmada y tipada *sobre* ese digest.

```console
$ cosign verify-attestation --key cosign.pub --type spdxjson ${IMAGE}@${DIGEST} \
    | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject}'
{
  "_type": "https://in-toto.io/Statement/v1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "registry.internal.acme.io/team-a/api",
      "digest": {
        "sha256": "9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47"
      }
    }
  ]
}
```

Imponé una *propiedad* de la provenance, no solo su presencia:

```rego
# policy/provenance.rego  — cosign evaluates data.signature.allow
package signature

default allow = false

allow {
  input.predicateType == "https://slsa.dev/provenance/v1"
  input.predicate.buildDefinition.buildType == "https://actions.github.io/buildtypes/workflow/v1"
  startswith(input.predicate.buildDefinition.externalParameters.workflow.repository,
             "https://github.com/acme/")
  input.predicate.runDetails.builder.id == "https://github.com/actions/runner/github-hosted"
}
```

```console
$ cosign verify-attestation \
    --certificate-identity-regexp 'https://github.com/acme/.*' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    --type slsaprovenance1 \
    --policy policy/provenance.rego \
    ${IMAGE}@${DIGEST}
will use provided policy policy/provenance.rego
policy checked
Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

### 5.5 Verificación del lado del cluster — Kyverno

```yaml
# kyverno-verify-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false            # verifyImages requires registry access; not a background check
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
  # ---- Internal images: keyed signature, key held in the cluster ----------
  - name: verify-internal-keyed
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
      - "registry.internal.acme.io/*"
      required: true
      verifyDigest: true       # fail if the tag cannot be resolved to a signed digest
      mutateDigest: true       # rewrite tag -> digest in the admitted object
      imageRegistryCredentials:
        secrets: ["regcred"]
      attestors:
      - count: 1
        entries:
        - keys:
            publicKeys: |-
              -----BEGIN PUBLIC KEY-----
              MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
              8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
              -----END PUBLIC KEY-----
            signatureAlgorithm: sha256
            ctlog:
              ignoreSCT: true          # private PKI: no Certificate Transparency SCT to check
            rekor:
              ignoreTlog: true         # keyed + airgapped: no transparency log entry expected

  # ---- Vendor images: keyless, pinned to the vendor's CI identity ---------
  - name: verify-vendor-keyless
    match:
      any:
      - resources:
          kinds: ["Pod"]
    verifyImages:
    - imageReferences:
      - "ghcr.io/acme-vendor/*"
      required: true
      mutateDigest: true
      attestors:
      - count: 1
        entries:
        - keyless:
            subject: "https://github.com/acme-vendor/*/.github/workflows/release.yaml@refs/tags/*"
            issuer: "https://token.actions.githubusercontent.com"
            rekor:
              url: https://rekor.sigstore.dev

  # ---- Require a recent, clean vulnerability attestation ------------------
  - name: require-vuln-attestation
    match:
      any:
      - resources:
          kinds: ["Pod"]
    verifyImages:
    - imageReferences:
      - "registry.internal.acme.io/*"
      required: true
      attestations:
      - type: https://cosign.sigstore.dev/attestation/vuln/v1
        attestors:
        - count: 1
          entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
                8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
                -----END PUBLIC KEY-----
        conditions:
        - all:
          - key: "{{ metadata.scanFinishedOn }}"
            operator: GreaterThanOrEquals
            value: "{{ time_before_now('720h') }}"     # scanned within 30 days
          - key: "{{ scanner.result.summary.critical || `0` }}"
            operator: Equals
            value: 0
```

> Kyverno ≥ 1.12 deprecia `spec.validationFailureAction` a favor de `failureAction` por regla; ambos se aceptan a lo largo de la línea 1.1x. Verificá con `kubectl get clusterpolicy -o yaml` después de aplicar — Kyverno reporta la depreciación en `status.conditions`.

`mutateDigest: true` es el flag operativamente importante: convierte a Kyverno en el resolvedor tag→digest, así los desarrolladores siguen escribiendo tags mientras etcd solo llega a almacenar digests.

### 5.6 Verificación del lado del cluster — sigstore policy-controller

Hecho específicamente para esto, con un radio de impacto menor que un motor de políticas general, y con **opt-in por namespace** en vez de opt-out.

```yaml
# clusterimagepolicy.yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: acme-signed-images
spec:
  images:
  - glob: "registry.internal.acme.io/**"
  - glob: "ghcr.io/acme-vendor/**"
  authorities:
  - name: internal-release-key
    key:
      hashAlgorithm: sha256
      data: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
        8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
        -----END PUBLIC KEY-----
  - name: ci-keyless
    keyless:
      url: https://fulcio.sigstore.dev
      identities:
      - issuer: https://token.actions.githubusercontent.com
        subjectRegExp: "^https://github\\.com/acme/platform/\\.github/workflows/release\\.yaml@refs/heads/main$"
      trustRootRef: default
    ctlog:
      url: https://rekor.sigstore.dev
    attestations:
    - name: must-have-slsa-provenance
      predicateType: slsaprovenance1
      policy:
        type: cue
        data: |
          predicateType: "https://slsa.dev/provenance/v1"
          predicate: {
            buildDefinition: {
              buildType: "https://actions.github.io/buildtypes/workflow/v1"
            }
          }
  policy:
    # Both authorities must be satisfied — internal key AND CI identity.
    type: cue
    data: |
      authorityMatches: {
        "internal-release-key": { signatures: [...{}] }
        "ci-keyless": { attestations: { "must-have-slsa-provenance": [...{}] } }
      }
  mode: enforce
```

```console
$ kubectl label namespace team-a policy.sigstore.dev/include=true
namespace/team-a labeled

$ kubectl -n team-a run unsigned --image=registry.internal.acme.io/team-a/api:dirty
Error from server (BadRequest): admission webhook "policy.sigstore.dev" denied the request: validation failed: failed policy: acme-signed-images: spec.containers[0].image
registry.internal.acme.io/team-a/api@sha256:11ab…: none of the attached signatures matched the authorities
```

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Primera pregunta: ¿admission o pull?

Las dos clases de fallo no se parecen en nada y se confunden con frecuencia.

| Señal | Rechazo en admission | Fallo al hacer pull de la imagen |
|---|---|---|
| Dónde aparece | Sincrónicamente en `kubectl apply` (Pod suelto) o en `kubectl describe rs/<name>` (creado por un controlador) | `kubectl get pod` muestra `ErrImagePull` / `ImagePullBackOff` |
| Existe el objeto Pod | **No** (Pod suelto) | Sí, `Pending` |
| Fuente del mensaje | apiserver / webhook | evento `Failed` del kubelet |
| Dónde se arregla | política, RBAC, salud del webhook | auth del registry, mirror, DNS, TLS |

```console
$ kubectl -n team-a get deploy api
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
api    0/3     0            0           94s

$ kubectl -n team-a describe rs api-6d4f8c7b59 | tail -6
Events:
  Type     Reason        Age               From                   Message
  ----     ------        ----              ----                   -------
  Warning  FailedCreate  12s (x6 over 94s)  replicaset-controller  Error creating: admission webhook "mutate.kyverno.svc-fail" denied the request: resource Pod/team-a/api-6d4f8c7b59- was blocked due to the following policies

verify-image-signatures:
  verify-internal-keyed: 'failed to verify image registry.internal.acme.io/team-a/api:v2.7.1:
    .attestors[0].entries[0].keys: no matching signatures'
```

**Regla:** un Deployment trabado en `0/N` sin ningún Pod es *siempre* un problema de admission. Andá directo a los eventos del ReplicaSet; los eventos propios del Deployment no dicen nada útil.

### 6.2 Tabla síntoma → causa raíz

| Texto del error | Capa | Causa raíz | Confirmalo con |
|---|---|---|---|
| `ValidatingAdmissionPolicy '…' denied request: …` | VAP | Funcionando según lo diseñado | `kubectl get validatingadmissionpolicybinding -o yaml` |
| Todos los Pods denegados, el mensaje menciona `no such key: initContainers` | VAP | CEL desreferenció un campo opcional no definido; `failurePolicy: Fail` convierte el error de evaluación en una denegación | `kubectl get validatingadmissionpolicy X -o jsonpath='{.status}'` |
| La política existe pero no se deniega nada | VAP | No hay binding, el binding tiene solo `validationActions: [Audit]`, o el `namespaceSelector` excluye al objetivo | `kubectl get vapb -o yaml \| grep -A5 matchResources` |
| `pods "x" is forbidden: image policy webhook backend denied one or more images: <reason>` | ImagePolicyWebhook | El backend devolvió `allowed:false` | Logs del backend |
| `pods "x" is forbidden: Post "https://10.96.71.14:443/image_policy": dial tcp 10.96.71.14:443: connect: connection refused` | ImagePolicyWebhook | Backend caído + `defaultAllow: false` (comportamiento correcto) | `kubectl -n image-policy get pod,ep` |
| Pod admitido con la annotation `alpha.image-policy.k8s.io/failed-open: "true"` | ImagePolicyWebhook | Backend inalcanzable **y** `defaultAllow: true` — la política se esquivó en silencio | `kubectl get pod X -o jsonpath='{.metadata.annotations}'` |
| apiserver en CrashLoopBackOff después de habilitar el plugin | ImagePolicyWebhook | Archivo de configuración no montado, o error de tipeo en el YAML/`apiVersion` | `sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q \| head -1)` |
| `x509: certificate signed by unknown authority` desde el apiserver hacia el backend | ImagePolicyWebhook | El `certificate-authority` del kubeconfig no encadena con el certificado de servidor del backend | `openssl s_client -connect 10.96.71.14:443 -showcerts` |
| Los logs del apiserver dicen `dial tcp: lookup image-policy.image-policy.svc: no such host` | ImagePolicyWebhook | Nombre `*.svc` en el kubeconfig — el apiserver no usa el DNS del cluster | Reemplazalo por la ClusterIP |
| `no matching signatures` | cosign / Kyverno / policy-controller | Clave pública equivocada, la imagen se volvió a pushear después de firmarla, o la firma no se copió entre registries | `cosign tree <img>@<digest>` |
| `no signatures found` / `MANIFEST_UNKNOWN` en `…​.sig` | cosign | La imagen nunca se firmó, o el GC/retención del registry borró el tag `.sig`, o la imagen se copió con `docker push` | `crane ls <repo> \| grep '^sha256-'` |
| `error verifying bundle: verifying signature: invalid signature when validating ASN.1 encoded signature` | cosign keyless | El digest del payload ≠ el digest firmado; normalmente se está verificando un *tag* que desde entonces se movió | Volvé a resolverlo con `crane digest` |
| `certificate signed by unknown authority` en una verificación keyless | cosign | Root TUF vencido/ausente, o un Sigstore privado sin `TUF_ROOT` configurado | `cosign initialize --mirror https://tuf-repo-cdn.sigstore.dev --root root.json` |
| `updating local metadata and targets: … expired` | cosign | Metadata TUF expirada o reloj del host desfasado | `timedatectl status`; volvé a correr `cosign initialize` |
| `error during command execution: no provider found for … OIDC` | cosign sign | Falta el permiso `id-token: write` en el job de CI | Bloque `permissions:` del job |
| `failed to verify image …: Get "https://registry…": unauthorized` | Kyverno | El motor de políticas no tiene credenciales de pull para el repo privado | `verifyImages[].imageRegistryCredentials.secrets` |
| Timeout del webhook de Kyverno, Pods rechazados de manera intermitente | Kyverno | Latencia del registry > `webhookTimeoutSeconds`; cada admission hace una ida y vuelta de red | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i timeout` |
| `ImagePullBackOff` justo después de habilitar `hosts.toml` | containerd | Ruta del mirror equivocada, falta `override_path`, o la CA no es de confianza | `sudo crictl pull <img>` en el nodo |

### 6.3 Runbook de diagnóstico

**Confirmá el objeto que realmente se persistió (digest, no tag):**

```console
$ kubectl -n team-a get pod api-6d4f8c7b59-2xk4q \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
api	registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ kubectl -n team-a get pod api-6d4f8c7b59-2xk4q \
    -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}'
api	registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47
```

`spec.containers[].image` es lo que pediste; `status.containerStatuses[].imageID` es lo que el nodo realmente corre. **Si difieren, el tag se movió.** Este one-liner es la detección más rápida en un cluster vivo de un incidente de tag mutable.

**Rollout en modo audit — leé las denegaciones antes de imponerlas:**

```console
$ sudo grep -h 'validation.policy.admission.k8s.io/validation_failure' \
    /var/log/kubernetes/audit.log | tail -1 | jq -r '.annotations'
{
  "validation.policy.admission.k8s.io/validation_failure": "[{\"message\":\"image(s) from a non-permitted registry: docker.io/library/redis:7\",\"policy\":\"allowed-registries.acme.io\",\"binding\":\"allowed-registries-binding\",\"expressionIndex\":0,\"validationActions\":[\"Audit\"]}]"
}
```

**Verificá una firma igual que lo hace el cluster, desde tu laptop:**

```console
$ IMG=registry.internal.acme.io/team-a/api
$ D=$(crane digest ${IMG}:v2.7.1) && echo $D
sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ crane ls registry.internal.acme.io/team-a/api | grep '^sha256-'
sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.att
sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.sig

$ cosign verify --key cosign.pub ${IMG}@${D} >/dev/null && echo OK
OK
```

Si `cosign verify` funciona en tu laptop pero Kyverno reporta `no matching signatures`, la diferencia casi siempre son las **credenciales o la alcanzabilidad desde adentro del cluster** — el motor de políticas hace pull del artefacto `.sig` por su cuenta.

**Probá que existe la entrada en el log de transparencia (keyless):**

```console
$ rekor-cli search --sha $(echo -n "$D" | sed 's/sha256://')
Found matching entries (listed by UUID):
24296fb24b8ad77a9e1c8f0d2b3a4f5e6c7d8a9b0e1f2a3b4c5d6e7f8091a2b3c

$ rekor-cli get --uuid 24296fb24b8ad77a9e1c8f0d2b3a4f5e6c7d8a9b0e1f2a3b4c5d6e7f8091a2b3c \
    --format json | jq -r '.Body.HashedRekordObj.signature.publicKey.content' \
    | base64 -d | openssl x509 -noout -text | grep -A2 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:https://github.com/acme/platform/.github/workflows/release.yaml@refs/heads/main
```

**Comprobá que la guardia esté realmente armada** (el modo de fallo que nadie nota — una política que dejó de aplicar en silencio):

```console
$ kubectl -n team-a run canary-unsigned \
    --image=docker.io/library/busybox:1.36 --restart=Never --command -- sleep 1
Error from server (Forbidden): pods "canary-unsigned" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: docker.io/library/busybox:1.36. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/
```

Corré esto como CronJob y alertá si *tiene éxito*. Un control negativo es el único monitoreo que detecta un webhook cambiado en silencio a `failurePolicy: Ignore`, un binding borrado por un upgrade de Helm defectuoso, o un namespace que perdió su label `policy.sigstore.dev/include`.

### 6.4 Compensaciones de la política de fallo

| Configuración | Comportamiento cuando el componente de enforcement está caído | Impacto en el cluster | Cuándo elegirla |
|---|---|---|---|
| `failurePolicy: Fail` / `defaultAllow: false` | Todas las creaciones que hacen match se deniegan | El cluster no puede auto-repararse; una caída de Kyverno bloquea los propios Pods de Kyverno salvo que estén excluidos | Regulado / alta garantía. **Obligatorio**: excluir `kube-system` y el namespace propio del motor de políticas |
| `failurePolicy: Ignore` / `defaultAllow: true` | Se admite todo, sin verificar | El cluster sobrevive; el control está silenciosamente ausente | Solo durante el rollout, con una alerta sobre el control negativo |
| VAP (in-process) | No puede estar caído independientemente del apiserver | Ninguno | Default para cualquier cosa que CEL pueda expresar |

Este es el argumento práctico más fuerte para poner la allowlist de registries en una `ValidatingAdmissionPolicy` y reservar los webhooks para la verificación de firmas: el chequeo barato no tiene ningún acoplamiento de disponibilidad, así que una caída del webhook de firmas te degrada a "solo registries de confianza" en vez de "cualquier cosa vale".

---

## 7. Checklist de producción

1. Allowlist de registries como `ValidatingAdmissionPolicy`, haciendo match de Pods **y** de todos los controladores de workload, `Deny` + `Audit`, con `kube-system` excluido.
2. `hosts.toml` de containerd en cada nodo: solo el mirror interno, hosts upstream ausentes, CA fijada, `skip_verify = false`. Firewall de egress bloqueando el `:443` hacia registries públicos desde las subredes de nodos.
3. Verificación de firmas (Kyverno o policy-controller) con `mutateDigest: true`, para que etcd solo llegue a contener digests.
4. Keyless en el CI con `id-token: write`; identidades fijadas por `subject` **y** `issuer` — nunca `--insecure-ignore-tlog` ni un `cosign verify` sin identidad fijada.
5. Attestations de SBOM + vulnerabilidades producidas en tiempo de build; admission exige un escaneo limpio más nuevo que N días.
6. `AlwaysPullImages` en clusters multi-tenant, con un caché de pull-through bien dimensionado.
7. Las reglas de retención del registry preservan explícitamente los tags `sha256-*.sig` / `.att`; la promoción entre registries usa `cosign copy` o `crane copy`, nunca `docker pull && docker push`.
8. Un CronJob de control negativo que intente correr una imagen sin firmar desde un registry no permitido y avise si tiene éxito.
9. Camino de break-glass documentado: qué annotation o label de namespace esquiva la política, quién puede ponerla, y la regla de auditoría que alerta cuando se usa.

---

## 8. Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- CEL en Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Referencia de Admission Controllers (`ImagePolicyWebhook`, `AlwaysPullImages`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- API `AdmissionConfiguration` (`apiserver.config.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-config.v1/
- API `ImageReview` (`imagepolicy.k8s.io/v1alpha1`) — https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.34/#imagereview-v1alpha1-imagepolicy-k8s-io
- Imágenes y política de pull de imágenes — https://kubernetes.io/docs/concepts/containers/images/
- Hacer pull de una imagen desde un registry privado — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Configuración de hosts de registry en containerd (`hosts.toml`) — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- Configuración del plugin CRI de containerd — https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- Documentación de Sigstore — https://docs.sigstore.dev/
- Firma de containers con cosign — https://docs.sigstore.dev/cosign/signing/signing_with_containers/
- Firma keyless / OIDC con cosign — https://docs.sigstore.dev/cosign/signing/overview/
- Attestations de cosign — https://docs.sigstore.dev/cosign/verifying/attestation/
- Sigstore policy-controller — https://docs.sigstore.dev/policy-controller/overview/
- Log de transparencia Rekor — https://docs.sigstore.dev/logging/overview/
- Autoridad certificante Fulcio — https://docs.sigstore.dev/certificate_authority/overview/
- Reglas `verifyImages` de Kyverno — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Políticas de verificación de imágenes de Kyverno — https://kyverno.io/policies/?policytypes=Image%2520Verification
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Especificación SLSA v1.0 — https://slsa.dev/spec/v1.0/
- Framework de attestations in-toto — https://github.com/in-toto/attestation
- OCI Distribution Specification (referrers API) — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- Especificación SPDX — https://spdx.dev/use/specifications/
- Especificación CycloneDX — https://cyclonedx.org/specification/overview/
- Syft (generación de SBOM) — https://github.com/anchore/syft
- Trivy (escaneo y salida `cosign-vuln`) — https://trivy.dev/latest/docs/
- go-containerregistry / `crane` — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- skopeo — https://github.com/containers/skopeo