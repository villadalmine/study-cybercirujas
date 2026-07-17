# 4.3 Secure your supply chain (permitted registries, sign and validate artifacts)

## Por qué importa

La supply chain de un workload en Kubernetes no termina en el código: incluye la base image, el build pipeline, el registry donde se publica la imagen y el mecanismo por el cual el cluster decide confiar en esa imagen antes de correrla. Un atacante que logra publicar (o reemplazar) una imagen en cualquier punto de esa cadena puede lograr ejecución de código arbitrario dentro del cluster sin explotar ninguna vulnerabilidad de Kubernetes en sí. CKS evalúa dos controles concretos sobre esta cadena: **restringir de qué registries se puede tirar imágenes** y **verificar criptográficamente que una imagen es la que el publisher realmente construyó** antes de admitirla.

---

## 1. Restringir registries permitidos

### 1.1 El problema

Por default, `kubelet`/`containerd` van a intentar pull de cualquier imagen que un Pod spec pida, de cualquier registry accesible por red (Docker Hub, un registry público arbitrario, etc.). Esto abre dos vectores:

- **Typosquatting / imágenes maliciosas públicas**: `nginx` vs `ngnix`, o una imagen legítima con una capa extra inyectada.
- **Bypass de controles internos**: si el registry corporativo hace scanning de vulnerabilidades y firma imágenes, pero el cluster acepta cualquier registry, ese control es opcional, no obligatorio.

La mitigación es imponer una allowlist de registries en dos capas: **admission control** (a nivel API, la más flexible y la más evaluada en el examen) y **runtime/node** (a nivel containerd/CRI-O, defensa en profundidad).

### 1.2 Enforcement vía admission control

#### ImagePolicyWebhook (built-in)

Es un admission controller nativo de Kubernetes que delega la decisión de admitir una imagen a un webhook HTTP externo. Se habilita agregando `ImagePolicyWebhook` a `--enable-admission-plugins` del `kube-apiserver` y apuntando `--admission-control-config-file` a un `AdmissionConfiguration`:

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
        defaultAllow: false   # crítico: fail-closed si el webhook no responde
```

`kubeConfigFile` apunta a la definición del backend (host/cert del webhook), igual que cualquier webhook de autenticación. `defaultAllow: false` es lo que hace que este control sea fail-closed — si el webhook cae, no se admite nada, en vez de admitir todo.

En la práctica de examen es más común (y más simple) usar un **admission controller dinámico** como Kyverno o OPA Gatekeeper.

#### Kyverno — allowlist de registries

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-registries
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "Solo se permiten imágenes de registry.empresa.io"
        pattern:
          spec:
            containers:
              - image: "registry.empresa.io/*"
```

```
$ kubectl apply -f restrict-image-registries.yaml
clusterpolicy.kyverno.io/restrict-image-registries created

$ kubectl run test --image=docker.io/nginx:latest
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource Pod/default/test was blocked due to the following policies
restrict-image-registries:
  validate-registries: 'validation error: Solo se permiten imágenes de registry.empresa.io.
    rule validate-registries failed at path /spec/containers/0/image/'
```

#### OPA Gatekeeper — `K8sAllowedRepos`

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo = input.parameters.repos[_]; good = startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("imagen '%v' no proviene de un registry permitido", [container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: repo-is-registry-empresa
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    repos:
      - "registry.empresa.io/"
```

Diferencia clave para el examen: Kyverno usa YAML declarativo (patrones/JMESPath), Gatekeeper usa Rego vía OPA. Ambos se implementan como `ValidatingWebhookConfiguration` detrás de escena.

### 1.3 Enforcement a nivel de runtime (defensa en profundidad)

Aunque el admission controller es el control principal, también conviene bloquear pulls a nivel del container runtime, para que ni siquiera un manifest aplicado bypaseando el apiserver (poco común, pero cubre casos como pulls manuales) pueda traer una imagen de un registry no autorizado.

**containerd** — `hosts.toml` por registry en `/etc/containerd/certs.d/<registry>/hosts.toml`, o restringir mirrors en `config.toml`:

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

**CRI-O** — `blocked-registries` en `/etc/containers/registries.conf`:

```toml
unqualified-search-registries = ["registry.empresa.io"]

[[registry]]
location = "docker.io"
blocked = true
```

---

## 2. Firmar y validar artifacts (image signing)

### 2.1 Sigstore / cosign

El estándar de facto para firmar OCI artifacts (imágenes de contenedor, SBOMs, attestations) es **Sigstore**, y su CLI **cosign**. Soporta dos flujos:

- **Key-based**: par de claves asimétricas gestionadas por vos (o KMS). Simple, buena para el examen.
- **Keyless**: firma efímera respaldada por OIDC (identidad del CI/CD, ej. GitHub Actions), certificado de corta vida emitido por **Fulcio**, y registro público de transparencia en **Rekor**. No hay clave privada que gestionar/rotar, pero requiere infraestructura de Sigstore (pública o self-hosted).

### 2.2 Firmar una imagen (key-based)

```
$ cosign generate-key-pair
Enter password for private key:
Enter password for private key again:
Private key written to cosign.key
Public key written to cosign.pub

$ cosign sign --key cosign.key registry.empresa.io/app:1.0.0
Enter password for private key:
Pushing signature to: registry.empresa.io/app:sha256-3b8f...c1a2.sig
```

La firma se publica como un artifact OCI adicional en el mismo repository, asociado al digest de la imagen (no al tag, que es mutable).

### 2.3 Verificar la firma

```
$ cosign verify --key cosign.pub registry.empresa.io/app:1.0.0

Verification for registry.empresa.io/app:1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"registry.empresa.io/app"},
  "image":{"docker-manifest-digest":"sha256:3b8f...c1a2"},
  "type":"cosign container image signature"},"optional":null}]
```

Un `cosign verify` con clave equivocada o imagen sin firmar falla con exit code distinto de 0 y `Error: no matching signatures` — es lo que un pipeline de CI o un admission controller usa para bloquear el deploy.

### 2.4 Firma keyless (breve)

```
$ cosign sign registry.empresa.io/app:1.0.0
Generating ephemeral keys...
Retrieving signed certificate...
   Note that there may be personally identifiable information associated with this signed artifact.
   This may include the email address associated with the account with which you authenticate.
tlog entry created with index: 123456789
Pushing signature to: registry.empresa.io/app:sha256-3b8f...c1a2.sig
```

La verificación keyless valida contra la identidad OIDC y el issuer, no una clave pública local:

```
$ cosign verify \
    --certificate-identity=ci@empresa.iam.gserviceaccount.com \
    --certificate-oidc-issuer=https://accounts.google.com \
    registry.empresa.io/app:1.0.0
```

### 2.5 Hacer cumplir la verificación en admission time

Firmar sin verificar en el cluster no bloquea nada — la verificación tiene que pasar por un admission controller. Opciones evaluables:

**Kyverno `verifyImages`**:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signature
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "registry.empresa.io/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

Con esta policy, un Pod que referencia `registry.empresa.io/app:1.0.0` sin una firma válida del `publicKeys` configurado es rechazado en el `ValidatingWebhookConfiguration` de Kyverno, antes de que el scheduler lo vea.

**Alternativas** (mencionar en el examen, no siempre requieren instalación propia):
- **sigstore policy-controller**: admission controller nativo de Sigstore, `ClusterImagePolicy` como CRD.
- **Connaisseur**: proyecto que envuelve cosign/Notary detrás de un webhook simple de configurar.

---

## 3. SBOM y attestations (el "etc." del enunciado)

`cosign` también firma y adjunta metadata que no es la imagen en sí, sino evidencia sobre cómo se construyó:

```
# adjuntar un SBOM (Software Bill of Materials)
$ cosign attach sbom --sbom app-sbom.spdx.json registry.empresa.io/app:1.0.0

# generar una attestation firmada (ej. provenance SLSA)
$ cosign attest --key cosign.key \
    --predicate provenance.json \
    --type slsaprovenance \
    registry.empresa.io/app:1.0.0

# verificar la attestation
$ cosign verify-attestation --key cosign.pub registry.empresa.io/app:1.0.0
```

Esto permite que una policy de admission no solo verifique "¿está firmada?" sino "¿tiene SBOM adjunto y viene de un pipeline con provenance verificable?" — el mismo mecanismo de `verifyImages` de Kyverno soporta `attestations` además de `keys`.

---

## Resumen para el examen

| Control | Dónde se aplica | Herramienta típica |
|---|---|---|
| Allowlist de registries | Admission (apiserver) | Kyverno `validate`, Gatekeeper `K8sAllowedRepos`, `ImagePolicyWebhook` |
| Allowlist de registries | Node/runtime | containerd `hosts.toml`, CRI-O `registries.conf` |
| Firmar imagen | Build/CI | `cosign sign` (key-based o keyless) |
| Verificar firma | Admission (apiserver) | Kyverno `verifyImages`, sigstore policy-controller, Connaisseur |
| SBOM/provenance | Build/CI + Admission | `cosign attach sbom`, `cosign attest` / `verify-attestation` |

---

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs, *ImagePolicyWebhook*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
- Sigstore, documentación general: https://docs.sigstore.dev/
- cosign (proyecto Sigstore): https://github.com/sigstore/cosign
- Kyverno, *Verify Images*: https://kyverno.io/docs/writing-policies/verify-images/
- Kyverno, *Validate Rules*: https://kyverno.io/docs/writing-policies/validate/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Gatekeeper policy library (`K8sAllowedRepos`): https://github.com/open-policy-agent/gatekeeper-library
- containerd, *Registry configuration (hosts.toml)*: https://github.com/containerd/containerd/blob/main/docs/hosts.md
- CRI-O / containers, *registries.conf*: https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md
- Notation / Notary Project (TUF-based signing): https://notaryproject.dev/
- SLSA framework: https://slsa.dev/
- in-toto attestations: https://in-toto.io/