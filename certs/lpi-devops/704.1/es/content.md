# 704.1 Cloud Native Security

**Examen:** LPI DevOps Tools Engineer 701-100, versión 2.0.0
**Peso:** 6.67

---

## 1. El problema arquitectónico

La seguridad de infraestructura clásica es una disciplina de *perímetro*: un firewall separa lo confiable de lo no confiable, los hosts son de larga vida, y la postura de seguridad de una máquina es el resultado acumulado de años de parcheo. Cada una de esas suposiciones se rompe en una plataforma cloud native.

Considerá la forma concreta de un incidente en producción que este objetivo existe para prevenir:

> Un equipo despacha `api:latest` a un cluster compartido. La imagen se construyó hace cuatro meses en la laptop de un desarrollador; nadie puede reproducirla. Corre como UID 0 porque el entrypoint de la imagen base escribe en `/etc`. El pod monta un token de service account por defecto, y ese service account quedó vinculado a `cluster-admin` durante una sesión de depuración de un chart de Helm que nunca se revirtió. No hay NetworkPolicy, así que todo pod del cluster puede alcanzar a cualquier otro pod, incluida la API interna de administración respaldada por etcd. Una dependencia de la imagen arrastra una escalada de privilegios local conocida. Un atacante que logra RCE en la aplicación obtiene root en el contenedor, escala a root en el nodo a través de la glibc sin parchear, lee los secretos de todos los demás contenedores desde el sistema de archivos del kubelet, y pivotea lateralmente con un token de API sin límites.

Cada eslabón de esa cadena es una falla de control distinta, y cada uno pertenece a una capa diferente del stack. Por eso la seguridad cloud native se organiza como **defensa en profundidad a través de capas**, y no como una frontera única:

| Capa | Frontera de confianza | Se controla mediante | Modo de fallo si falta |
|---|---|---|---|
| **Nube / infraestructura** | Tenant ↔ proveedor | IAM, política de metadatos de instancia, diseño de VPC/subredes, cifrado de discos, endurecimiento del SO del nodo | Robo de credenciales del servicio de metadatos (`169.254.169.254`) desde cualquier pod |
| **Cluster** | API server ↔ cliente; namespace ↔ namespace | RBAC, admission control, cifrado en reposo, política de auditoría, authn/authz del kubelet | Una carga de trabajo comprometida se convierte en cluster-admin |
| **Contenedor / carga de trabajo** | Contenedor ↔ kernel del host | `securityContext`, seccomp, LSM (AppArmor/SELinux), capabilities, user namespaces, RuntimeClass | Escape del contenedor mediante un bug del kernel o un `CAP_SYS_ADMIN` permisivo |
| **Código / cadena de suministro** | Sistema de build ↔ artefacto ↔ runtime | Firma, atestación, SBOM, escaneo, fijado por digest, builds reproducibles | Desplegás algo que nadie puede atribuir ni reproducir |

Las capas no son decorativas. Determinan *dónde puede aplicarse un control siquiera*. No podés arreglar una dependencia vulnerable en tiempo de admisión; no podés arreglar un RoleBinding con comodín en el Dockerfile. El trabajo de un arquitecto de plataforma en este objetivo es ubicar cada control en la capa más barata que realmente pueda aplicarlo, y hacer que esa aplicación sea *no opcional* — una política que los desarrolladores pueden esquivar agregando un flag es documentación, no un control.

Dos propiedades distinguen la seguridad cloud native del endurecimiento tradicional:

1. **La inmutabilidad reemplaza al parcheo.** No hacés `apt upgrade` sobre un contenedor en ejecución; reconstruís la imagen y rotás el Deployment. Esto convierte un problema de *runtime* en un problema de *pipeline*, lo cual es bueno — los pipelines son testeables —, pero significa que el pipeline en sí ahora es un sistema de producción con requisitos de disponibilidad de producción.
2. **La identidad reemplaza a la ubicación de red.** En una red plana de pods, "la IP vino de adentro del cluster" no prueba nada. La autorización debe basarse en identidad criptográfica de la carga de trabajo (un token de service account, un SVID, un certificado de par mTLS), no en la dirección de origen.

**Referencia de modelo de amenazas:** NIST SP 800-190 enumera los riesgos específicos de contenedores (imagen, registry, orquestador, contenedor, SO del host) y sigue siendo la línea base más citable para un registro formal de riesgos. La guía de seguridad cloud native del CNCF TAG Security cubre el mismo terreno con el encuadre de ciclo de vida (desarrollar → distribuir → desplegar → runtime) que se usa más abajo.

---

## 2. Capa: cadena de suministro — procedencia antes que permisos

### 2.1 Qué significa "procedencia" operativamente

Una imagen de producción debe responder cuatro preguntas, de forma mecánica, sin preguntarle a un humano:

| Pregunta | Artefacto que la responde | Herramienta de verificación |
|---|---|---|
| ¿Qué hay *dentro* de esta imagen? | SBOM (SPDX o CycloneDX) | `syft`, `trivy sbom` |
| ¿Lo que contiene tiene vulnerabilidades conocidas? | Informe de vulnerabilidades contra el SBOM | `trivy`, `grype` |
| ¿Quién la construyó, desde qué fuente, en qué builder? | Atestación de procedencia SLSA (predicado in-toto) | `cosign verify-attestation`, `slsa-verifier` |
| ¿Esta bolsa exacta de bytes es la que se firmó? | Firma sobre el digest del manifiesto | `cosign verify` |

Notá la dependencia de orden: una firma sobre un *tag* no vale nada, porque los tags son mutables. Las firmas y la política siempre deben atarse a `@sha256:...`.

### 2.2 Endurecimiento de la imagen base y del Dockerfile

```dockerfile
# syntax=docker/dockerfile:1.7

########################################
# Stage 1 — build
########################################
FROM golang:1.22.6-bookworm AS build

WORKDIR /src

# Dependency layer: cached independently of source changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

# Reproducibility: static binary, no cgo, stripped, trimmed paths,
# version stamped from the build argument (never from `git` inside the image).
ARG VERSION=dev
ARG COMMIT=unknown
ARG SOURCE_DATE_EPOCH=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/api ./cmd/api

########################################
# Stage 2 — runtime
########################################
FROM gcr.io/distroless/static-debian12:nonroot

# Distroless "static" contains: ca-certificates, /etc/passwd with a `nonroot`
# user (65532), tzdata, and nothing else. No shell, no package manager,
# no libc for a dynamically linked payload to abuse.
COPY --from=build --chown=65532:65532 /out/api /usr/local/bin/api

USER 65532:65532
WORKDIR /
EXPOSE 8080

# Exec form: PID 1 is the application, so SIGTERM reaches it directly and
# graceful shutdown works. Shell form would insert /bin/sh, which does not
# exist here anyway.
ENTRYPOINT ["/usr/local/bin/api"]
```

Decisiones de diseño que vale la pena defender en una revisión:

* **Multi-stage** deja el compilador, la caché de módulos y el árbol de fuentes fuera del artefacto que se despacha. La imagen de runtime contiene un binario; la superficie de ataque es el binario más el kernel.
* **`USER 65532`** en la imagen es un duplicado de defensa en profundidad de `runAsUser` en la spec del Pod. El `runAsNonRoot: true` de Kubernetes hace fallar el contenedor en el *arranque* si el usuario declarado de la imagen resuelve a UID 0 — que es exactamente la falla temprana y ruidosa que querés.
* **La ausencia de shell** rompe la mayoría de los payloads publicados de escape de contenedor y de criptominado, que son scripts de shell. También rompe `kubectl exec -it -- sh`, lo cual es un compromiso deliberado: usá contenedores efímeros de depuración en su lugar (§7.4).
* **`SOURCE_DATE_EPOCH`** y `-trimpath` te acercan a builds reproducibles byte a byte, que es lo que hace que una reconstrucción independiente sea una verificación significativa sobre el sistema de build.

### 2.3 Escaneo: elegir una herramienta y, más importante, una política

| | Trivy | Grype | Clair |
|---|---|---|---|
| Alcance | Paquetes del SO, dependencias de lenguaje, IaC, manifiestos de K8s, secretos, licencias | Paquetes del SO, dependencias de lenguaje | Paquetes del SO (centrado en contenedores) |
| SBOM | Genera y consume SPDX + CycloneDX | Consume SBOM de Syft de forma nativa | Consume, basado en indexador |
| Modelo de despliegue | Un binario estático único, u operador de K8s | Un binario único, se combina con `syft` | Servidor + indexador + matcher, orientado a API |
| Distribución de la BD | Artefacto OCI descargado del registry | Artefacto OCI (Grype DB) | Actualizadores del lado del servidor |
| Mejor encaje | Una herramienta para CI + IaC + cluster | Pipeline emparejado con un flujo SBOM-first de Syft | Reescaneo continuo integrado al registry |

La herramienta importa menos que estas tres decisiones de política:

1. **`--ignore-unfixed`.** Una CRITICAL sin arreglo upstream no es accionable por el build; hacer fallar el pipeline por eso entrena a la gente a agregar ignores generalizados. Seguila, no bloquees por ella.
2. **Reescaneá continuamente, no una sola vez.** Una imagen que escaneó limpia el lunes no está limpia el viernes; la CVE se publicó, no se introdujo. Por eso el reescaneo del lado del registry o dentro del cluster (Trivy Operator, Clair) importa más que la compuerta en CI.
3. **Las excepciones deben expirar.** Usá entradas de `.trivyignore` con fecha de vencimiento, revisadas, no una lista de permitidos permanente.

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    registry.example.com/platform/api:1.24.3

2026-09-03T14:02:11Z    INFO    Vulnerability scanning is enabled
2026-09-03T14:02:11Z    INFO    Detected OS: debian
2026-09-03T14:02:11Z    INFO    Detecting Debian vulnerabilities...
2026-09-03T14:02:12Z    INFO    Number of language-specific files: 1

registry.example.com/platform/api:1.24.3 (debian 12.6)
======================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌────────────────┬────────────────┬──────────┬────────┬───────────────────┬────────────────────┬─────────────────────────────────────────┐
│    Library     │ Vulnerability  │ Severity │ Status │ Installed Version │   Fixed Version    │                  Title                  │
├────────────────┼────────────────┼──────────┼────────┼───────────────────┼────────────────────┼─────────────────────────────────────────┤
│ libc6          │ CVE-2023-4911  │ HIGH     │ fixed  │ 2.36-9+deb12u4    │ 2.36-9+deb12u7     │ glibc: buffer overflow in ld.so via     │
│                │                │          │        │                   │                    │ GLIBC_TUNABLES (local privesc)          │
├────────────────┼────────────────┼──────────┼────────┼───────────────────┼────────────────────┼─────────────────────────────────────────┤
│ openssh-server │ CVE-2024-6387  │ CRITICAL │ fixed  │ 1:9.2p1-2+deb12u2 │ 1:9.2p1-2+deb12u3  │ openssh: signal handler race leading    │
│                │                │          │        │                   │                    │ to pre-auth RCE as root (regreSSHion)   │
└────────────────┴────────────────┴──────────┴────────┴───────────────────┴────────────────────┴─────────────────────────────────────────┘

api (gobinary)
==============
Total: 1 (HIGH: 1, CRITICAL: 0)

┌───────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┬──────────────────────────────────────┐
│      Library      │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │                Title                 │
├───────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┼──────────────────────────────────────┤
│ golang.org/x/net  │ CVE-2023-39325 │ HIGH     │ fixed  │ v0.14.0           │ v0.17.0       │ net/http: HTTP/2 rapid reset DoS     │
└───────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┴──────────────────────────────────────┘

$ echo $?
1
```

Leé esa salida como arquitecto, no como una cola de tickets. `openssh-server` en una imagen de aplicación no es una CVE, es un *defecto de diseño*: no hay razón para que un contenedor de API despache un demonio SSH. El arreglo no es `apt upgrade`, es la base distroless de §2.2, que elimina el hallazgo de forma permanente en lugar de reiniciarle el reloj.

### 2.4 Generación de SBOM

```console
$ syft registry.example.com/platform/api:1.24.3 -o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json
 ✔ Loaded image                    registry.example.com/platform/api:1.24.3
 ✔ Parsed image                    sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
 ✔ Cataloged contents
   ├── ✔ Packages                        [148 packages]
   ├── ✔ File digests                    [412 files]
   └── ✔ Executables                     [1 executables]

$ jq '.packages | length' sbom.spdx.json
148

$ jq -r '.packages[] | select(.name=="golang.org/x/net") | "\(.name) \(.versionInfo)"' sbom.spdx.json
golang.org/x/net v0.14.0
```

El SBOM es lo que abarata la próxima CVE. Cuando salga el siguiente aviso de `golang.org/x/net`, la pregunta "¿cuáles de nuestras 300 imágenes están afectadas?" se convierte en una consulta `jq` sobre SBOMs almacenados en lugar de 300 reconstrucciones.

### 2.5 Firma y atestación con Sigstore

La firma sin claves (keyless) elimina la peor parte de la firma de código: las claves privadas de larga vida. `cosign` solicita un certificado efímero a Fulcio atado a una identidad OIDC (la identidad del workflow de CI), firma, descarta la clave, y registra el evento de firma en el log de transparencia Rekor. La verificación comprueba la cadena de certificados, la identidad y la prueba de inclusión en el log.

```console
$ cosign sign --yes registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
Generating ephemeral keys...
Retrieving signed certificate...
Successfully verified SCT...
tlog entry created with index: 148392017
Pushing signature to: registry.example.com/platform/api

$ cosign attest --yes --predicate sbom.spdx.json --type spdxjson \
    registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
Using payload from: sbom.spdx.json
tlog entry created with index: 148392018
```

Verificación, con la restricción de identidad que es la que realmente aporta el valor de seguridad:

```console
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/example-org/platform-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840

Verification for registry.example.com/platform/api@sha256:9b2f1c7a... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[{"critical":{"identity":{"docker-reference":"registry.example.com/platform/api"},"image":{"docker-manifest-digest":"sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840"},"type":"cosign container image signature"},"optional":{"1.3.6.1.4.1.57264.1.9":"https://github.com/example-org/platform-api/.github/workflows/release.yaml@refs/tags/v1.24.3","Bundle":{"SignedEntryTimestamp":"MEUCIQD...","Payload":{"logIndex":148392017,"logID":"c0d23d6a...","integratedTime":1788442931}}}}]
```

Y el fallo que *querés* ver cuando alguien firma desde el workflow equivocado:

```console
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/example-org/platform-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:11aa22bb33cc44dd55ee66ff7788990011223344556677889900aabbccddeeff

Error: no matching signatures:
none of the expected identities matched what was in the certificate, got subjects
[https://github.com/example-org/platform-api/.github/workflows/nightly.yaml@refs/heads/main]
with issuer https://token.actions.githubusercontent.com
main.go:74: error during command execution: no matching signatures
```

> **Antipatrón:** `cosign verify <image>` sin `--certificate-identity*` ni `--certificate-oidc-issuer` no es verificación. Prueba que *alguien* firmó la imagen. Cualquiera con una cuenta de GitHub puede hacerlo. La restricción de identidad es la política.

### 2.6 Los niveles de SLSA como objetivo de madurez

| Nivel | Requisito | Implementación práctica |
|---|---|---|
| **Build L1** | La procedencia existe y se distribuye | CI emite una atestación de procedencia in-toto con el repositorio fuente, el commit y el builder |
| **Build L2** | La procedencia está firmada por una plataforma de build alojada | Atestación firmada por la identidad de la plataforma de CI (OIDC → Fulcio), no por una clave de desarrollador |
| **Build L3** | Los builds corren en entornos aislados y efímeros; la procedencia no puede falsificarse desde los propios pasos del build | Material de clave de firma inaccesible para los pasos de build controlados por el usuario; workflow reutilizable y fijado; sin reutilización de runners autoalojados |

L2 se alcanza en un día con firma keyless sobre runners alojados. L3 es un programa organizacional: requiere que un *paso* de build comprometido no pueda falsificar la procedencia, lo que significa sacar la firma del job que controla el desarrollador.

### 2.7 El pipeline, de punta a punta

```yaml
# .github/workflows/release.yaml
name: release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  build-sign-attest:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write        # REQUIRED: mints the OIDC token cosign exchanges at Fulcio
      attestations: write
    env:
      REGISTRY: registry.example.com
      IMAGE: platform/api
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Registry login
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          provenance: mode=max
          sbom: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE }}:${{ github.ref_name }}
          build-args: |
            VERSION=${{ github.ref_name }}
            COMMIT=${{ github.sha }}
            SOURCE_DATE_EPOCH=0
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Install cosign
        uses: sigstore/cosign-installer@v3

      - name: Install trivy
        uses: aquasecurity/setup-trivy@v0.2.0

      - name: Generate SBOM (SPDX)
        run: |
          set -euo pipefail
          trivy image \
            --format spdx-json \
            --output sbom.spdx.json \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Vulnerability gate
        run: |
          set -euo pipefail
          trivy image \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            --exit-code 1 \
            --format table \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Sign image by digest
        run: |
          set -euo pipefail
          cosign sign --yes "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Attach SBOM attestation
        run: |
          set -euo pipefail
          cosign attest --yes \
            --predicate sbom.spdx.json \
            --type spdxjson \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Emit digest for GitOps
        run: |
          echo "digest=${{ steps.build.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"
```

Tres detalles son estructurales:

* **`id-token: write`** es lo que hace posible la firma keyless. Sin eso, `cosign sign` falla con `error getting signer: getting key from Fulcio: retrieving cert: no identity token provided`.
* **Todo lo que viene después del build referencia `${{ steps.build.outputs.digest }}`, nunca el tag.** Escanear el tag `v1.24.3` y firmar el tag `v1.24.3` puede, en una condición de carrera o con un tag mutable, operar sobre dos imágenes distintas.
* **La compuerta corre antes de la firma.** Una firma afirma "respaldamos esto"; firmar una imagen que todavía no escaneaste invierte el significado.

El equivalente en GitLab CI usa `id_tokens:` con `aud: sigstore` y por lo demás es idéntico.

---

## 3. Capa: configuración del cluster

### 3.1 RBAC — mínimo privilegio que sobrevive al contacto con un chart de Helm

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: production
# Deny the legacy auto-mounted token at the identity level. Any pod that
# genuinely needs API access opts in explicitly with a projected volume.
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-config-reader
  namespace: production
rules:
  # Named resources only. `resourceNames` is the difference between
  # "read one ConfigMap" and "read every ConfigMap in the namespace",
  # and the latter is how config-borne credentials leak.
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-runtime-config", "api-feature-flags"]
    verbs: ["get", "watch"]
  # `list` is deliberately absent: `list` cannot be constrained by
  # resourceNames, so granting it grants read access to the whole collection.
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    resourceNames: ["api-leader"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-config-reader
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: api-config-reader
subjects:
  - kind: ServiceAccount
    name: api
    namespace: production
```

Los tres hechos de RBAC que deciden la mayoría de los resultados en el mundo real:

| Hecho | Consecuencia |
|---|---|
| RBAC es puramente aditivo; no existe la regla `deny` | No podés "restar" un permiso otorgado por otro binding. Auditá *todos* los bindings de un sujeto, no solo el que escribiste. |
| `resourceNames` no restringe `list`, `watch` sobre colecciones, `deletecollection` ni `create` | Un Role con `list` sobre `secrets` es un Role con acceso de lectura a todos los secretos del namespace. |
| `escalate`, `bind` e `impersonate` son verbos de escalada de privilegios | `bind` sobre ClusterRoles le permite a un sujeto otorgarse cualquier cosa. Tratalos como equivalentes a cluster-admin. |

Cazando otorgamientos excesivos existentes:

```console
$ kubectl get clusterrolebindings -o json | \
    jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
           .metadata.name as $n | (.subjects // [])[] |
           "\($n)\t\(.kind)/\(.namespace // "-")/\(.name)"'
cluster-admin	Group/-/system:masters
gitlab-runner-admin	ServiceAccount/ci/gitlab-runner
monitoring-debug	ServiceAccount/monitoring/prom-debug

$ kubectl auth can-i --list --as=system:serviceaccount:ci:gitlab-runner
Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             []                  []               [*]
                                                [*]                 []               [*]
```

`*.*` con `[*]` es la firma de una primitiva de toma de control del cluster sentada en tu namespace de CI. Cualquiera que pueda enviar un job de pipeline es dueño del cluster.

```console
$ kubectl auth can-i --list --as=system:serviceaccount:production:api -n production
Resources                                       Non-Resource URLs   Resource Names                        Verbs
selfsubjectreviews.authentication.k8s.io        []                  []                                    [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []                                    [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []                                    [create]
leases.coordination.k8s.io                      []                  []                                    [create]
leases.coordination.k8s.io                      []                  [api-leader]                          [get update patch]
configmaps                                      []                  [api-runtime-config api-feature-flags] [get watch]

$ kubectl auth can-i get secrets --as=system:serviceaccount:production:api -n production
no
```

### 3.2 Tokens de service account: atados, con audiencia y de vida corta

Los tokens de service account respaldados por `Secret` heredados nunca expiran, no tienen audiencia, y son legibles por cualquier cosa que pueda leer Secrets. Los clusters modernos emiten **tokens proyectados y atados**: JWTs firmados con vencimiento, una audiencia y una vinculación al objeto Pod, de modo que el token queda invalidado cuando el Pod se elimina.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-token-demo
  namespace: production
spec:
  serviceAccountName: api
  automountServiceAccountToken: false
  containers:
    - name: api
      image: registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
      volumeMounts:
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: vault-token
      projected:
        defaultMode: 0444
        sources:
          - serviceAccountToken:
              # `audience` is the anti-replay control: a token minted for
              # "vault" is rejected by the Kubernetes API server, and vice versa.
              audience: vault
              expirationSeconds: 3600
              path: vault-token
```

```console
$ kubectl create token api -n production --audience=vault --duration=10m \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq
{
  "aud": [
    "vault"
  ],
  "exp": 1788446531,
  "iat": 1788445931,
  "iss": "https://oidc.example.com/clusters/leloir",
  "jti": "d9a1f0c2-7b44-4f18-9a03-1c6e5b28d7aa",
  "kubernetes.io": {
    "namespace": "production",
    "serviceaccount": {
      "name": "api",
      "uid": "5c3f2a91-0e84-4d77-b6a2-9f1c0d38e4b5"
    }
  },
  "nbf": 1788445931,
  "sub": "system:serviceaccount:production:api"
}
```

Ese `iss` es el emisor OIDC del cluster. Publicarlo (`kubectl get --raw /.well-known/openid-configuration`) es lo que permite que un proveedor de IAM en la nube o Vault federen directamente contra la identidad de carga de trabajo de Kubernetes — sin ninguna credencial estática de nube en el cluster. Esta es la respuesta correcta a "cómo obtiene mi pod una credencial de S3".

### 3.3 Pod Security Admission

PSA es la aplicación integrada, etiquetada por namespace, de los tres Pod Security Standards. Es estable desde Kubernetes 1.25 y no cuesta nada ejecutarlo — corre en proceso dentro del API server.

| Perfil | Bloquea | Uso típico |
|---|---|---|
| `privileged` | nada | Solo componentes de sistema a nivel de nodo (CNI, CSI, agentes de monitoreo) |
| `baseline` | contenedores privilegiados, namespaces del host, hostPath, hostPort, agregar capabilities no predeterminadas, cambios de enmascaramiento de `/proc` | Objetivo de migración para cargas de trabajo heredadas |
| `restricted` | todo lo de `baseline`, más: debe usar `runAsNonRoot`, debe descartar `ALL` capabilities, debe definir `allowPrivilegeEscalation: false`, debe definir un `seccompProfile`, tipos de volumen limitados a un conjunto seguro | Todo namespace de aplicaciones |

Tres modos independientes por namespace — este es el mecanismo de migración:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    # Hard rejection at admission.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Returns a warning to the client (kubectl prints it) but admits.
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    # Emits an audit annotation on the API server audit event.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
```

Fijá `*-version` explícitamente. `latest` significa que el perfil se endurece silenciosamente cuando actualizás el plano de control, y cargas de trabajo que se admitían la semana pasada empiezan a fallar durante una actualización del cluster — una forma genuinamente dolorosa de descubrir un cambio de política.

El orden seguro de despliegue es `warn` → `audit` → `enforce`, y el dry-run del lado del servidor te dice el radio de impacto *antes* de comprometerte:

```console
$ kubectl label --dry-run=server --overwrite ns production \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "production" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-batch-9f7c4d8b6-t4kzn (and 3 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/production labeled (server dry run)
```

Y el mensaje de aplicación cuando se envía un Pod que viola el perfil:

```console
$ kubectl apply -f bad-pod.yaml
Error from server (Forbidden): error when creating "bad-pod.yaml": pods "legacy" is forbidden:
violates PodSecurity "restricted:v1.30":
allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**Limitación crítica:** PSA valida el objeto **Pod**. Un Deployment con una plantilla que viola el perfil es *aceptado*; la falla aparece después, en los eventos del ReplicaSet, como pods que nunca llegan a crearse. Por eso importa la etiqueta `warn` — es lo que hace que `kubectl apply -f deployment.yaml` imprima la advertencia en el momento en que el humano está mirando.

```console
$ kubectl -n production describe rs legacy-batch-9f7c4d8b6 | tail -6
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  12s (x4 over 31s)  replicaset-controller  Error creating: pods "legacy-batch-9f7c4d8b6-" is forbidden: violates PodSecurity "restricted:v1.30": runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 3.4 Admission control más allá de PSA

PSA cubre un conjunto fijo de verificaciones a nivel de Pod. Todo lo demás — etiquetas obligatorias, registries permitidos, verificación de firmas, límites de recursos, propiedad del hostname de un ingress — necesita admisión de propósito general.

| | Pod Security Admission | ValidatingAdmissionPolicy (CEL) | Kyverno | OPA Gatekeeper |
|---|---|---|---|---|
| Dónde se ejecuta | En proceso en `kube-apiserver` | En proceso en `kube-apiserver` | Webhook externo (deployment) | Webhook externo (deployment) |
| Lenguaje | ninguno (perfiles fijos) | CEL | YAML (DSL nativo de K8s) | Rego |
| Alcance | Solo Pods | Cualquier recurso, solo validación¹ | Cualquier recurso: validar, mutar, generar, limpiar, verificar imágenes | Cualquier recurso: validar, mutar |
| Verificación de firma de imágenes | ✗ | ✗ (sin egreso de red desde CEL) | ✓ `verifyImages` nativo | vía datos externos / `gator` + proveedor |
| Riesgo de disponibilidad | ninguno | ninguno | Webhook caído + `failurePolicy: Fail` ⇒ escrituras de API bloqueadas | igual |
| Curva de aprendizaje | ninguna | baja | baja–media | media–alta (Rego) |
| Mejor para | La línea base que todo cluster debe tener | Reglas estructurales baratas y sin dependencias | Plataforma de políticas completa, aplicación de la cadena de suministro | Organizaciones ya estandarizadas en Rego/OPA |

¹ Las políticas de admisión mutantes en CEL son un agregado más nuevo y todavía en maduración; la validación es el camino GA.

**Composición recomendada, no selección:** PSA para la línea base de cargas de trabajo (gratis, no puede fallar abierto), `ValidatingAdmissionPolicy` para invariantes estructurales que deben sobrevivir a una caída del webhook, y un motor de políticas (Kyverno *o* Gatekeeper) para la cadena de suministro y las políticas entre recursos.

**Política CEL in-tree — fijado por digest, sin dependencias externas:**

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-digest-pinned-images
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allImages
      expression: >-
        (object.spec.containers.map(c, c.image)) +
        (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
  validations:
    - expression: "variables.allImages.all(i, i.contains('@sha256:'))"
      message: "every container image must be pinned by digest, e.g. registry.example.com/app@sha256:<64-hex>"
      reason: Forbidden
    - expression: "variables.allImages.all(i, i.startsWith('registry.example.com/'))"
      message: "images must come from registry.example.com"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-digest-pinned-images-binding
spec:
  policyName: require-digest-pinned-images
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

```console
$ kubectl -n production run probe --image=nginx:1.27 --restart=Never
Error from server (Forbidden): admission webhook denied the request:
ValidatingAdmissionPolicy 'require-digest-pinned-images' with binding 'require-digest-pinned-images-binding' denied request:
every container image must be pinned by digest, e.g. registry.example.com/app@sha256:<64-hex>
```

**Kyverno — verificación de firmas en admisión.** Este es el control que cierra el círculo de la cadena de suministro: una imagen que nunca fue firmada por el workflow de release no puede ejecutarse, sin importar quién tenga RBAC para crear Pods.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-platform-image-signatures
  annotations:
    policies.kyverno.io/title: Verify image signatures (keyless)
    policies.kyverno.io/severity: critical
spec:
  # NOTE: schema drift — `spec.validationFailureAction` is the Kyverno 1.11/1.12
  # field. From 1.13 it is deprecated in favour of per-rule `failureAction`.
  # Pin your Kyverno version and match the schema to it.
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-signed-by-release-workflow
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
                - staging
      verifyImages:
        - imageReferences:
            - "registry.example.com/platform/*"
          # Resolve the tag to a digest and rewrite the Pod spec, so what is
          # verified is exactly what is run. Closes the TOCTOU gap between
          # admission and image pull.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example-org/*/.github/workflows/release.yaml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

```console
$ kubectl -n production apply -f deploy-unsigned.yaml
Error from server: error when creating "deploy-unsigned.yaml": admission webhook
"mutate.kyverno.svc-fail" denied the request:
resource Pod/production/scratch-7f6b was blocked due to the following policies

verify-platform-image-signatures:
  verify-signed-by-release-workflow: 'failed to verify image registry.example.com/platform/scratch:dev:
    .attestors[0].entries[0].keyless: no signatures found'
```

**Equivalente en Gatekeeper** para la regla de registry permitido, para equipos estandarizados en Rego:

```yaml
---
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
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("container <%v> has disallowed image <%v>", [container.name, container.image])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("initContainer <%v> has disallowed image <%v>", [container.name, container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: only-corporate-registry
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    repos:
      - "registry.example.com/"
```

> **Compromiso de disponibilidad que tenés que decidir deliberadamente.** `failurePolicy: Fail` en un webhook que cubre `pods` significa: si el motor de políticas no está disponible, **no se puede crear ningún pod en todo el cluster** — incluidos los propios pods del motor de políticas después de una falla de nodo. Mitigaciones: excluir el namespace propio del motor y `kube-system` vía `namespaceSelector`, correr ≥3 réplicas con un PodDisruptionBudget y antiafinidad, y poner `timeoutSeconds` bajo. `failurePolicy: Ignore` convierte una caída dura en un bypass de seguridad silencioso. Para verificación de firmas, `Fail` es lo correcto; para una regla de "debe tener una etiqueta de propietario", lo correcto es `Ignore`.

### 3.5 Secretos: cifrado en reposo, y dónde deberían vivir realmente los secretos

Los objetos `Secret` de Kubernetes están **codificados en base64, no cifrados**, por defecto. Cualquiera con acceso al disco de etcd, a un backup de etcd, o con RBAC de `get secrets` los lee en texto plano.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml  (kube-apiserver: --encryption-provider-config=...)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
      - events.events.k8s.io
    providers:
      # First provider encrypts; all providers are tried, in order, to decrypt.
      # KMS v2 (GA in 1.29) uses a hierarchical DEK/KEK scheme: the API server
      # caches a local KEK, so it does not call the external KMS per object.
      - kms:
          apiVersion: v2
          name: vault-kms
          endpoint: unix:///opt/kms/vault-kms.sock
          timeout: 3s
      # `identity` last = plaintext fallback for objects written before
      # encryption was enabled. Remove it only AFTER a full rewrite (below).
      - identity: {}
```

Habilitar el cifrado **no** cifra los objetos existentes. Se reescriben en la próxima escritura:

```console
$ kubectl get secrets --all-namespaces -o json \
  | kubectl replace -f - >/dev/null
$ echo "rewrite complete"
rewrite complete
```

Comprobalo en la capa de almacenamiento — esta es la única verificación que realmente cuenta:

```console
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/production/db-credentials | hexdump -C | head -5
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 72 6f 64 75 63  74 69 6f 6e 2f 64 62 2d  |s/production/db-|
00000020  63 72 65 64 65 6e 74 69  61 6c 73 0a 6b 38 73 3a  |credentials.k8s:|
00000030  65 6e 63 3a 6b 6d 73 3a  76 32 3a 76 61 75 6c 74  |enc:kms:v2:vault|
00000040  2d 6b 6d 73 3a 0a ac 02  1f 9d 44 7b 61 e0 3c 55  |-kms:.....D{a.<U|
```

El prefijo `k8s:enc:kms:v2:vault-kms:` es la prueba. Si en cambio ves un `postgres://user:hunter2@...` legible, el cifrado no está activo para ese objeto.

**Dónde deberían vivir los secretos — compromisos:**

| Enfoque | Material secreto en reposo en Git | Rotación | Dependencia del cluster | Notas |
|---|---|---|---|---|
| `Secret` plano en Git | **texto plano** | manual | ninguna | Nunca. |
| Sealed Secrets | cifrado con una clave específica del cluster | resellar + commitear | controlador en el cluster | GitOps simple; la clave privada está atada al cluster, así que la recuperación ante desastres exige respaldarla |
| SOPS + age/KMS | cifrado, por valor | recifrar + commitear | ninguna en runtime (descifra en el CD) o `ksops`/Flux | Amigable al diff (solo cambian los valores modificados); la gestión de claves es tuya |
| External Secrets Operator + Vault/cloud SM | **ausente** — solo una referencia | central, automática | disponibilidad de ESO + almacén externo | Los secretos nunca entran a Git; el `ExternalSecret` es un puntero |
| Secrets Store CSI Driver | **ausente** | central; soporta reconciliación de rotación | driver CSI + proveedor | Monta como volumen tmpfs; puede evitar crear un `Secret` de K8s del todo |

Para un equipo de plataforma, ESO o el driver CSI es el estado objetivo: la propiedad más fuerte no es "el secreto está cifrado" sino "el secreto no está en el repositorio en absoluto, así que una filtración del repo no es una filtración de credenciales".

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault
  namespace: production
spec:
  provider:
    vault:
      server: https://vault.example.com:8200
      path: kv
      version: v2
      auth:
        # Vault validates the projected token against the cluster's OIDC
        # issuer. No static Vault token is stored anywhere in the cluster.
        kubernetes:
          mountPath: kubernetes
          role: production-api
          serviceAccountRef:
            name: api
            audiences:
              - vault
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: production
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      engineVersion: v2
      data:
        DATABASE_URL: "postgres://{{ .username }}:{{ .password }}@db.production.svc.cluster.local:5432/api?sslmode=verify-full"
  data:
    - secretKey: username
      remoteRef:
        key: production/api/db
        property: username
    - secretKey: password
      remoteRef:
        key: production/api/db
        property: password
```

```console
$ kubectl -n production get externalsecret db-credentials
NAME             STORE   REFRESH INTERVAL   STATUS         READY
db-credentials   vault   15m                SecretSynced   True

$ kubectl -n production describe externalsecret db-credentials | tail -5
Events:
  Type    Reason   Age   From              Message
  ----    ------   ----  ----              -------
  Normal  Updated  22s   external-secrets  Updated Secret
```

**Consumí los secretos como archivos, no como variables de entorno.** Las variables de entorno se filtran a `/proc/<pid>/environ`, a los volcados de fallo, a `kubectl describe pod` para cualquier cosa que use `envFrom` con un ConfigMap de respaldo, y a la herencia de procesos hijos. Un archivo en un montaje `tmpfs` con modo `0400` no.

### 3.6 Registro de auditoría

La admisión te dice qué se bloqueó; la auditoría te dice qué se permitió. Sin ella, la respuesta a incidentes no tiene fuente primaria.

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Do not record the request/response body for these resources at all.
omitStages:
  - RequestReceived
rules:
  # 1. Never log Secret/ConfigMap bodies — that would write plaintext
  #    credentials into the audit log, which is usually shipped off-cluster.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 2. Drop high-volume, low-value read noise from system components.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"

  # 3. Full request bodies for RBAC changes — the most security-relevant
  #    writes in the cluster.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 4. Exec/attach/portforward: who got a shell into which pod.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]

  # 5. All other writes at Request level.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # 6. Everything else: metadata only.
  - level: Metadata
```

```console
$ sudo jq -c 'select(.objectRef.subresource=="exec")
              | {t:.requestReceivedTimestamp, u:.user.username,
                 ns:.objectRef.namespace, pod:.objectRef.name}' \
    /var/log/kubernetes/audit.log | tail -3
{"t":"2026-09-03T13:41:02.118Z","u":"alice@example.com","ns":"production","pod":"api-7d9f8c5b64-x2wqp"}
{"t":"2026-09-03T13:52:47.903Z","u":"system:serviceaccount:ci:gitlab-runner","ns":"production","pod":"api-7d9f8c5b64-x2wqp"}
{"t":"2026-09-03T14:06:12.550Z","u":"bob@example.com","ns":"staging","pod":"worker-6b5c9f7d84-mnq2t"}
```

Un service account de CI ejecutando un shell dentro de un pod de producción es una alerta, no una línea de log.

### 3.7 Verificación con el benchmark CIS

```console
$ kubectl run kube-bench-node --rm -it --restart=Never \
    --image=docker.io/aquasec/kube-bench:v0.8.0 \
    --overrides='{"spec":{"hostPID":true,"nodeName":"worker-03","containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:v0.8.0","command":["kube-bench","run","--targets","node"],"volumeMounts":[{"name":"var-lib-kubelet","mountPath":"/var/lib/kubelet","readOnly":true},{"name":"etc-kubernetes","mountPath":"/etc/kubernetes","readOnly":true}]}],"volumes":[{"name":"var-lib-kubelet","hostPath":{"path":"/var/lib/kubelet"}},{"name":"etc-kubernetes","hostPath":{"path":"/etc/kubernetes"}}]}}'

[INFO] 4 Worker Node Security Configuration
[INFO] 4.1 Worker Node Configuration Files
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive (Automated)
[PASS] 4.1.2 Ensure that the kubelet service file ownership is set to root:root (Automated)
[PASS] 4.1.9 Ensure that the kubelet --config configuration file has permissions set to 600 (Automated)
[INFO] 4.2 Kubelet
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[PASS] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate (Automated)
[FAIL] 4.2.6 Ensure that the --protect-kernel-defaults argument is set to true (Automated)
[WARN] 4.2.10 Ensure that the --rotate-server-certificates argument is set to true (Manual)

== Remediations node ==
4.2.6 If using a Kubelet config file, edit /var/lib/kubelet/config.yaml to set protectKernelDefaults: true.
Then restart the kubelet: systemctl daemon-reload && systemctl restart kubelet

== Summary node ==
21 checks PASS
1 checks FAIL
1 checks WARN
0 checks INFO
```

Tratá la salida de `kube-bench` como un *disparador de conversación*, no como un veredicto de cumplimiento: varias verificaciones son informativas, y los planos de control gestionados fallan legítimamente controles del plano de control a los que no podés llegar. Lo que importa es que la lista de FAIL se revise y que cada entrada esté arreglada o tenga una excepción documentada y fechada.

---

## 4. Capa: aislamiento de cargas de trabajo y runtime

### 4.1 Las primitivas de Linux por debajo

Un contenedor no es una frontera de seguridad de la forma en que lo es una VM. Es un proceso con una vista restringida, ensamblado a partir de:

| Primitiva | Qué aísla / restringe | Superficie en Kubernetes |
|---|---|---|
| Namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `cgroup`, `user`) | Qué puede *ver* el proceso | `hostPID`, `hostNetwork`, `hostIPC`, `hostUsers` |
| cgroups v2 | Qué puede *consumir* | `resources.requests` / `resources.limits` |
| Capabilities | Qué operaciones exclusivas de root puede realizar | `securityContext.capabilities` |
| seccomp | Qué **syscalls** puede emitir | `securityContext.seccompProfile` |
| LSM: AppArmor / SELinux | Qué **archivos, sockets y operaciones** puede tocar | `securityContext.appArmorProfile`, `seLinuxOptions` |
| `no_new_privs` | Si los binarios setuid pueden elevar privilegios | `allowPrivilegeEscalation: false` |
| User namespaces | Mapea el UID 0 del contenedor a un UID no privilegiado del host | `spec.hostUsers: false` |

La línea más importante de todas: **`privileged: true` desactiva esencialmente todo eso.** Un contenedor privilegiado tiene todas las capabilities, un perfil de seccomp y AppArmor sin restricciones, y acceso completo a `/dev`. Es root en el host con pasos extra. Tratá cada `privileged: true` de tus manifiestos como una concesión de confianza a nivel de nodo, y enumeralos:

```console
$ kubectl get pods -A -o json | jq -r '
    .items[] |
    .metadata.namespace as $ns | .metadata.name as $n |
    (.spec.containers[] | select(.securityContext.privileged == true) | .name) as $c |
    "\($ns)/\($n)\tcontainer=\($c)"'
kube-system/cilium-8xk4d	container=cilium-agent
kube-system/csi-node-9m2pq	container=node-driver-registrar
legacy/build-agent-6f7d8c9b4-vt3kw	container=dind
```

Los dos primeros son esperables. El tercero — un agente de build Docker-in-Docker — es un compromiso total del cluster esperando a ser descubierto, y el arreglo es un builder rootless (BuildKit rootless, Kaniko, Buildah) en lugar de un demonio privilegiado.

### 4.2 Un Deployment completamente endurecido

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: production
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/component: backend
      annotations:
        # Roll pods when the config changes; unrelated to security but
        # prevents "the fix is deployed" while old pods hold old config.
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543"
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      # No host namespaces. hostPID would expose every process on the node
      # (and their command lines, which often contain credentials).
      hostNetwork: false
      hostPID: false
      hostIPC: false
      # User namespaces (beta): container UID 0 maps to an unprivileged
      # host UID, so a container escape lands as nobody, not as root.
      # Requires a runtime with idmap-mount support (containerd >= 1.7,
      # runc >= 1.2) and the UserNamespacesSupport feature gate.
      hostUsers: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        supplementalGroups: []
      terminationGracePeriodSeconds: 30
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
      containers:
        - name: api
          # Digest-pinned. The tag is kept only as a human-readable comment
          # in the GitOps repo; the API server resolves nothing at runtime.
          image: registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
          imagePullPolicy: IfNotPresent
          args:
            - "--listen=:8080"
            - "--metrics-listen=:9090"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop:
                - ALL
              # Nothing is added back. If the app needed to bind :443 the
              # correct fix is a Service on 443 -> containerPort 8443,
              # NOT capabilities.add: ["NET_BIND_SERVICE"].
            seccompProfile:
              type: RuntimeDefault
            appArmorProfile:
              type: RuntimeDefault
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            # Credentials arrive as a file, never as an env var.
            - name: DATABASE_URL_FILE
              value: /var/run/secrets/db/DATABASE_URL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/api
            - name: db-credentials
              mountPath: /var/run/secrets/db
              readOnly: true
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              # No CPU limit on latency-sensitive services (CFS throttling);
              # a memory limit is mandatory — it is the only defence against
              # one workload OOM-killing its neighbours on the node.
              memory: "512Mi"
              ephemeral-storage: "1Gi"
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
      volumes:
        # readOnlyRootFilesystem: true means every writable path must be an
        # explicit, size-bounded volume. Unbounded emptyDir is a node-filling
        # DoS primitive.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 512Mi
        - name: db-credentials
          secret:
            secretName: db-credentials
            defaultMode: 0400
            optional: false
      nodeSelector:
        kubernetes.io/os: linux
```

Verificación de que el contexto de seguridad está realmente en vigor — leé el contenedor *en ejecución*, no el manifiesto:

```console
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- id
uid=65532(nonroot) gid=65532(nonroot) groups=65532(nonroot)

$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- grep -E 'Cap(Prm|Eff|Bnd)|Seccomp|NoNewPrivs' /proc/1/status
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1

$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- touch /etc/probe
touch: /etc/probe: Read-only file system
command terminated with exit code 1
```

Descifrado: `CapBnd: 0` significa que el *bounding set* está vacío — el proceso no puede adquirir ninguna capability, nunca, ni siquiera vía un binario setuid. `NoNewPrivs: 1` es `allowPrivilegeEscalation: false`. `Seccomp: 2` es `SECCOMP_MODE_FILTER` (el modo 1 es estricto, el 0 es desactivado). Si ves `Seccomp: 0`, el perfil no se aplicó y deberías averiguar por qué antes de despachar.

### 4.3 Perfiles de seccomp personalizados

`RuntimeDefault` bloquea aproximadamente entre 40 y 60 syscalls que ninguna aplicación ordinaria necesita (`kexec_load`, `mount`, `pivot_root`, `bpf`, `perf_event_open`, `userfaultfd`, …). Un perfil personalizado va más lejos, pero solo construí uno si podés medir el conjunto de syscalls.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clock_gettime", "clone",
        "close", "connect", "epoll_create1", "epoll_ctl", "epoll_pwait",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "getsockname", "getsockopt",
        "gettid", "listen", "lseek", "madvise", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "prctl", "pread64", "read",
        "readlinkat", "recvfrom", "rt_sigaction", "rt_sigprocmask",
        "rt_sigreturn", "sched_getaffinity", "sched_yield", "sendto",
        "set_robust_list", "set_tid_address", "setsockopt", "shutdown",
        "sigaltstack", "socket", "tgkill", "uname", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Desplegalo en `/var/lib/kubelet/seccomp/profiles/api.json` en cada nodo (con un DaemonSet, o el Security Profiles Operator), y después referencialo:

```yaml
        securityContext:
          seccompProfile:
            type: Localhost
            localhostProfile: profiles/api.json
```

**Nunca escribas uno a mano a partir de una lista de syscalls.** Construilo empíricamente: corré con `"defaultAction": "SCMP_ACT_LOG"` bajo carga representativa, recolectá los registros de auditoría del kernel, y después ajustá.

```console
$ sudo journalctl -k --since "10 min ago" | grep -m3 'type=1326'
kernel: audit: type=1326 audit(1788445102.417:882): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=284119 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=318 compat=0 ip=0x4a1b2c code=0x7ffc0000
kernel: audit: type=1326 audit(1788445103.902:883): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=284119 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=302 compat=0 ip=0x4a3f10 code=0x7ffc0000

$ ausyscall --dump | awk '$1==318 || $1==302'
302	prlimit64
318	getrandom
```

`code=0x7ffc0000` es `SECCOMP_RET_LOG` — registrado y permitido. Bajo `SCMP_ACT_ERRNO` la misma syscall devolvería `EPERM`, y en cambio estarías depurando una aplicación que misteriosamente no logra sembrar su generador de números aleatorios. Ese es exactamente el camino de diagnóstico de §7.3.

### 4.4 Aislamiento más fuerte: RuntimeClass

Cuando un kernel compartido no es una frontera aceptable — código de inquilinos no confiables, CI ejecutando scripts de build arbitrarios, plugins provistos por clientes — cambiá el runtime en vez de agregar más filtros de syscalls.

| Runtime | Frontera | Compatibilidad de syscalls | Arranque | Sobrecarga | Usalo cuando |
|---|---|---|---|---|---|
| `runc` | Kernel del host compartido + namespaces/cgroups | completa | ~50–100 ms | ~0 | Cargas de trabajo propias y confiables |
| `gVisor` (runsc) | Un kernel en espacio de usuario intercepta las syscalls | alta, pero no completa (algunos `ioctl`, syscalls de nicho, comportamientos directos de `/proc` difieren) | ~150–300 ms | notable en rutas intensivas en syscalls y en E/S | Cargas multi-inquilino que son mayormente de red/CPU |
| `Kata Containers` | Virtualización por hardware — un kernel real por pod | completa (*es* Linux) | ~300–800 ms | memoria por VM; CPU casi nativa | Código hostil o no confiable; frontera dura de cumplimiento |

```yaml
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    example.com/runtime: gvisor
  tolerations:
    - key: example.com/runtime
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed:
    cpu: "50m"
    memory: "64Mi"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata-qemu
scheduling:
  nodeSelector:
    example.com/runtime: kata
overhead:
  podFixed:
    cpu: "250m"
    memory: "160Mi"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: untrusted-build
  namespace: tenant-builds
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      runtimeClassName: gvisor
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: build
          image: registry.example.com/platform/builder@sha256:4c81a3e0f2d97b6a5e18c04d3b7f92ae61c0d85fb437291ea6cf0d3b8e24571c
          command: ["/usr/local/bin/build.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              memory: "4Gi"
          volumeMounts:
            - name: workspace
              mountPath: /workspace
      volumes:
        - name: workspace
          emptyDir:
            sizeLimit: 8Gi
```

El campo `overhead` no es cosmético: le dice al planificador que un pod de Kata realmente cuesta 160 MiB más de lo que solicitan sus contenedores, lo que evita una sobresuscripción sistemática de los nodos.

Confirmando que el sandbox es real, desde adentro:

```console
$ kubectl -n tenant-builds exec untrusted-build-7v9kx -- cat /proc/version
Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016

$ kubectl -n tenant-builds exec untrusted-build-7v9kx -- dmesg | head -2
[    0.000000] Starting gVisor...
[    0.325841] Feeding the init monster...
```

Esa cadena sintética de versión del kernel es el kernel en espacio de usuario de gVisor respondiendo, no el host. En un pod con `runc` el mismo comando devuelve el kernel real del nodo.

### 4.5 Detección de amenazas en runtime

La prevención falla tarde o temprano; la detección es lo que acota el tiempo de permanencia. Falco (reglas a nivel de syscall, módulo de kernel o sonda eBPF moderna) es la implementación de referencia de la CNCF.

```yaml
# /etc/falco/rules.d/platform.yaml
- macro: platform_images
  condition: (container.image.repository startswith "registry.example.com/platform/")

- macro: known_build_tools
  condition: (proc.name in (git, go, make, buildkitd, buildctl))

- rule: Shell spawned in production container
  desc: >
    An interactive shell was executed inside a production application
    container. Distroless images have no shell, so this indicates either an
    ephemeral debug container or an intrusion.
  condition: >
    spawned_process
    and container
    and shell_procs
    and platform_images
    and k8s.ns.name in (production)
    and not known_build_tools
  output: >
    Shell in production container
    (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname image=%container.image.repository:%container.image.tag
     ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]

- rule: Service account token read by unexpected process
  desc: Reading the projected service account token outside the app binary.
  condition: >
    open_read
    and container
    and fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount
    and not proc.name in (api, kubelet)
  output: >
    SA token read (proc=%proc.name file=%fd.name ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, credentials, mitre_credential_access, T1552]

- rule: Outbound connection to cloud metadata endpoint
  desc: A container attempted to reach the instance metadata service.
  condition: >
    outbound
    and container
    and fd.sip = "169.254.169.254"
    and not k8s.ns.name in (kube-system)
  output: >
    Metadata service contacted from container
    (proc=%proc.name cmdline=%proc.cmdline ns=%k8s.ns.name pod=%k8s.pod.name
     dest=%fd.sip:%fd.sport)
  priority: CRITICAL
  tags: [network, cloud, mitre_credential_access, T1552.005]
```

```console
$ kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20 | grep -E 'Warning|Critical'
14:07:22.481233591: Warning Shell in production container (user=root uid=0 proc=bash cmdline=bash -i parent=runc image=registry.example.com/platform/api:1.24.3 ns=production pod=api-7d9f8c5b64-x2wqp container=api)
14:07:41.902117034: Critical SA token read (proc=curl file=/var/run/secrets/kubernetes.io/serviceaccount/token ns=production pod=api-7d9f8c5b64-x2wqp)
14:07:44.115880226: Critical Metadata service contacted from container (proc=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ ns=production pod=api-7d9f8c5b64-x2wqp dest=169.254.169.254:80)
```

Tres líneas, cuarenta segundos, y podés leer la intrusión entera: shell, robo de token, pivote a credenciales de nube. Esa secuencia es la razón completa por la que existe este objetivo.

---

## 5. Capa: red

### 5.1 NetworkPolicy — denegar por defecto es el único punto de partida correcto

El modelo de red de Kubernetes es plano: todo pod alcanza a todo pod. NetworkPolicy tiene semántica de *lista de permitidos*, y solo aplica una vez que al menos una política selecciona un pod. Un namespace con cero políticas tiene cero aplicación, sin importar lo que soporte tu CNI.

```yaml
---
# 1. Deny all ingress and egress in the namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}          # empty selector = every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
---
# 2. DNS is not optional. Without this, every name resolution fails and the
#    symptom is a generic connection timeout, which sends people hunting the
#    wrong layer for an hour. This is the single most common NetworkPolicy bug.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# 3. Ingress: only the ingress controller may reach the API on 8080,
#    and only Prometheus may scrape 9090.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
---
# 4. Egress: the database, and nothing else on the pod network.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-egress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgres
      ports:
        - protocol: TCP
          port: 5432
---
# 5. Explicitly deny the cloud metadata endpoint for every pod.
#    `except` carves a hole out of an allowed CIDR — this is how you permit
#    general internet egress while still blocking 169.254.169.254.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-except-metadata
  namespace: production
spec:
  podSelector:
    matchLabels:
      egress.example.com/internet: "true"
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16     # link-local, incl. cloud metadata
              - 10.0.0.0/8         # internal RFC1918
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

**Semánticas con las que la gente tropieza:**

| Comportamiento | Detalle |
|---|---|
| Las políticas son **aditivas, con OR** | Dos políticas que seleccionan el mismo pod producen la unión de sus permisos. No hay orden ni regla de denegación. |
| El `podSelector` dentro de un bloque `from`/`to` es **local al namespace** salvo que se combine con `namespaceSelector` | `{namespaceSelector: X, podSelector: Y}` en **un solo elemento de la lista** = "pods que coinciden con Y en namespaces que coinciden con X". Como **dos elementos de la lista** significa "cualquier pod en X" **O** "el pod Y en este namespace" — un permiso mucho más amplio. La indentación es el control de seguridad. |
| `ipBlock` coincide con el origen del paquete tal como lo ve el CNI | Para tráfico que sufrió SNAT (algunas rutas de ingress, algunos LB de nube), `ipBlock` no coincidirá con el cliente original. |
| Seleccionar el destino no alcanza | El egreso en el cliente **y** el ingreso en el servidor deben permitir el flujo. Las denegaciones son silenciosas en el cable. |

### 5.2 Matriz de capacidades de los CNI

NetworkPolicy es una API; la aplicación es tarea del CNI. Verificá qué hace el tuyo.

| Característica | Calico | Cilium | Weave / kindnet | AWS VPC CNI (solo) |
|---|---|---|---|---|
| NetworkPolicy `networking.k8s.io/v1` | ✓ | ✓ | ✓ / ✗ | ✗ (necesita un add-on) |
| CRD de política a nivel de cluster | ✓ (`GlobalNetworkPolicy`) | ✓ (`CiliumClusterwideNetworkPolicy`) | ✗ | ✗ |
| L7 (método/ruta HTTP, gRPC, Kafka) | ✓ (con integración Envoy/Istio) | ✓ (Envoy nativo) | ✗ | ✗ |
| Egreso basado en DNS/FQDN | ✓ | ✓ (`toFQDNs`) | ✗ | ✗ |
| Observabilidad de denegaciones de política | `calicoctl`, logs de flujo | `hubble observe` | ✗ | ✗ |
| Cifrado transparente | WireGuard | WireGuard / IPsec | ✓ (Weave) | ✗ |

La NetworkPolicy estándar no puede expresar "este pod puede llamar a `api.stripe.com` sobre HTTPS pero nada más" porque trabaja sobre CIDRs y las IPs del destino son dinámicas. El CRD del CNI sí puede:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-egress-l7
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: api
  egress:
    # Cilium must proxy DNS to learn which IPs a name resolves to.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # L7 HTTP: only these methods and paths against the internal billing API.
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: billing
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/v1/invoices(/[0-9]+)?$"
              - method: "POST"
                path: "/v1/invoices$"
```

### 5.3 Identidad de carga de trabajo y mTLS

NetworkPolicy responde "¿puede esta IP hablar con aquella IP?". No responde "¿es el que llama quien dice ser?". Para eso necesitás identidad criptográfica: **SPIFFE** define el documento de identidad (un SVID — un certificado X.509 o un JWT cuyo sujeto es una URI `spiffe://`), **SPIRE** es el emisor de referencia, y las service meshes empaquetan ambos detrás de mTLS.

```
spiffe://example.com/ns/production/sa/api
```

Esa identidad se atesta a partir de las propiedades reales de la carga de trabajo (su namespace de Kubernetes, su service account, y el nodo en el que corre), no la afirma la carga de trabajo. Registrar una:

```console
$ kubectl -n spire exec -it spire-server-0 -c spire-server -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID spiffe://example.com/ns/production/sa/api \
      -parentID spiffe://example.com/spire/agent/k8s_psat/leloir/9f2c1a0e-7b34-4d18-8a03-1c6e5b28d7aa \
      -selector k8s:ns:production \
      -selector k8s:sa:api \
      -ttl 3600
Entry ID         : 4b1f0a92-3c77-4e56-91d2-8a0e7c4b61f3
SPIFFE ID        : spiffe://example.com/ns/production/sa/api
Parent ID        : spiffe://example.com/spire/agent/k8s_psat/leloir/9f2c1a0e-7b34-4d18-8a03-1c6e5b28d7aa
Revision         : 0
TTL              : 3600
Selector         : k8s:ns:production
Selector         : k8s:sa:api
```

Los dos selectores son la política de autorización: solo un pod en `production` corriendo como el service account `api` puede obtener ese SVID. Un pod en `staging` que presente el mismo manifiesto no obtiene nada. Combinalo con autorización de pares aplicada por mTLS y el movimiento lateral requiere robar una clave que rota cada hora y nunca se escribe a disco.

---

## 6. Juntando las capas: un namespace completo

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    kubernetes.io/metadata.name: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.memory: 120Gi
    persistentvolumeclaims: "20"
    services.loadbalancers: "2"
    services.nodeports: "0"          # NodePort bypasses the ingress security path
    count/secrets: "40"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: production-defaults
  namespace: production
spec:
  limits:
    - type: Container
      default:
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        memory: 8Gi
      min:
        memory: 32Mi
```

Resumen de capas para este namespace, y qué frena realmente cada control:

| Control | Qué frena |
|---|---|
| PSA `restricted` | Contenedores como root, escalada de privilegios, namespaces del host, montajes hostPath, seccomp sin restricciones |
| Fijado por digest con `ValidatingAdmissionPolicy` | Tags mutables; un registry comprometido intercambiando silenciosamente la imagen detrás de `:1.24.3` |
| `verifyImages` de Kyverno | Cualquier imagen no producida por el workflow de release |
| NetworkPolicy `default-deny-all` | Movimiento lateral desde un pod comprometido |
| `except: 169.254.0.0/16` | Robo de credenciales de IAM en la nube vía el endpoint de metadatos |
| `automountServiceAccountToken: false` | Que una RCE se convierta en acceso al API server por defecto |
| `readOnlyRootFilesystem` + sin shell | Persistencia: el atacante no puede escribir un payload en ningún lado donde el runtime lo ejecute |
| ESO + cifrado KMS en reposo | Credenciales en Git; credenciales en un backup de etcd |
| `services.nodeports: "0"` | Un rodeo accidental al WAF/terminación TLS del ingress |
| Reglas de Falco | Convertir una brecha silenciosa en una detección de 40 segundos |

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Una pasada de verificación que podés correr en cualquier cluster

```console
# --- Supply chain -----------------------------------------------------------
$ kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u | grep -v '@sha256:'
registry.example.com/platform/legacy-cron:latest
docker.io/busybox:1.36
# ^ unpinned images: mutable, unverifiable, and `:latest` is unrollbackable

# --- Identity ---------------------------------------------------------------
$ kubectl get sa -A -o json \
  | jq -r '.items[] | select(.automountServiceAccountToken != false)
           | "\(.metadata.namespace)/\(.metadata.name)"' | head
default/default
production/legacy-worker

$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select([.subjects[]?.name] | index("system:anonymous") or index("system:unauthenticated"))
           | .metadata.name'
# (empty is the correct answer)

# --- Workload hardening -----------------------------------------------------
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(
      (.spec.containers[]?.securityContext.privileged == true) or
      (.spec.hostNetwork == true) or (.spec.hostPID == true) or
      ((.spec.volumes // [])[]? | has("hostPath"))
    ) | "\(.metadata.namespace)/\(.metadata.name)"' | sort -u
kube-system/cilium-8xk4d
legacy/build-agent-6f7d8c9b4-vt3kw

# --- Network ----------------------------------------------------------------
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    n=$(kubectl -n "$ns" get netpol --no-headers 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && echo "NO NETWORKPOLICY: $ns"
  done
NO NETWORKPOLICY: default
NO NETWORKPOLICY: legacy

# --- Secrets ----------------------------------------------------------------
$ kubectl get pods -A -o json | jq -r '
    .items[] | .metadata.namespace as $ns | .metadata.name as $n |
    .spec.containers[] | select((.env // [])[]? | .name | test("PASS|SECRET|TOKEN|KEY"; "i"))
    | select((.env[] | select(.valueFrom == null)) != null)
    | "\($ns)/\($n) container=\(.name)"' | sort -u
legacy/build-agent-6f7d8c9b4-vt3kw container=dind
# ^ a literal credential in the pod spec: readable by anyone with `get pods`
```

### 7.2 Tabla de firmas de falla

| Síntoma | Causa más probable | Confirmar con |
|---|---|---|
| `Error from server (Forbidden): ... violates PodSecurity "restricted:..."` | PSA rechazando el Pod | Leé el mensaje — lista textualmente cada campo faltante |
| El Deployment muestra `0/3 READY`, **ningún pod en absoluto** | PSA/admisión rechazando a nivel del ReplicaSet | `kubectl describe rs <rs>` → eventos `FailedCreate` |
| `CreateContainerConfigError` | Falta una clave de Secret/ConfigMap, o `runAsNonRoot` con una imagen que corre como root | `kubectl describe pod` → Events |
| `container has runAsNonRoot and image will run as root` | El `USER` de la imagen es 0 y no hay override de `runAsUser` | `docker inspect --format '{{.Config.User}}' <image>` |
| `CreateContainerError: ... unable to find user` | El UID de `runAsUser` no tiene entrada en `/etc/passwd` y la app la requiere | `runAsUser` + definir `HOME`, o agregar el usuario a la imagen |
| `ErrImagePull` / `unauthorized` después de habilitar la política | El `mutateDigest` de Kyverno reescribió la referencia; el imagePullSecret está acotado a la ruta del tag | `kubectl get pod -o jsonpath='{.spec.containers[*].image}'` |
| `admission webhook ... denied the request` | Denegación del motor de políticas | `kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller` |
| Toda escritura a la API se cuelga y después da `context deadline exceeded` | Webhook de política caído con `failurePolicy: Fail` | `kubectl get validatingwebhookconfigurations` y revisar los pods que lo respaldan |
| Aplicación: "connection timed out" hacia un Service | Denegación de NetworkPolicy (descarte silencioso, sin RST) | §7.5 |
| Aplicación: "no such host" / `SERVFAIL` de DNS | Egreso con denegación por defecto sin regla de permiso para DNS | Verificar que exista la política `allow-dns-egress` |
| La app funciona, después falla con `EPERM` en una operación poco común | seccomp o descarte de capabilities | §7.3 |
| `permission denied` al leer un Secret montado | Desajuste de `fsGroup` frente a `defaultMode` | `kubectl exec -- ls -ln <mountpath>` |
| El pod corre pero `readOnlyRootFilesystem` lo rompe | La app escribe fuera de los volúmenes declarados | `kubectl logs` para la ruta exacta, agregar un `emptyDir` |
| `cosign verify`: `no matching signatures` | Identidad/emisor equivocados, o genuinamente sin firmar | Volvé a correr con `--certificate-identity-regexp '.*'` para ver el sujeto real |

### 7.3 Diagnosticar una denegación de seccomp / capability

El síntoma es un error a nivel de aplicación sin ningún evento de Kubernetes. Trabajá capa por capa hacia abajo:

```console
# 1. Is a filter even loaded?
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- grep -E 'Seccomp|CapEff' /proc/1/status
CapEff:	0000000000000000
Seccomp:	2
Seccomp_filters:	1

# 2. Which profile did the runtime apply? (run on the node)
$ sudo crictl ps --name api -q
3f2b1c8a9d44e7160b5a2f0c81d93e64af720b1c5d83e9f04a6b2c71d8e05f39

$ sudo crictl inspect 3f2b1c8a9d44 \
  | jq '.info.runtimeSpec.linux.seccomp | {defaultAction, syscallGroups: (.syscalls | length)}'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscallGroups": 1
}

# 3. Watch the kernel refuse it, live.
$ sudo journalctl -kf | grep --line-buffered 'type=1326'
kernel: audit: type=1326 audit(1788446012.771:1204): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=291447 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=41 compat=0 ip=0x4a08f1 code=0x50001

# 4. Translate the syscall number.
$ ausyscall --dump | awk '$1==41'
41	socket
```

`code=0x50001` es `SECCOMP_RET_ERRNO` devolviendo errno 1 (`EPERM`); el perfil está denegando `socket(2)`. Como el perfil de §4.3 se recolectó bajo una carga de trabajo que nunca abrió una nueva familia de sockets, la aplicación falla solo en una ruta de código que se ejercita en producción. **La lección es procedimental:** un perfil de seccomp acotado a mano debe validarse bajo la mezcla *completa* de tráfico de producción en modo `SCMP_ACT_LOG` durante al menos un ciclo de negocio completo antes de pasarlo a `SCMP_ACT_ERRNO`.

Las denegaciones de capabilities se ven parecidas pero con una causa distinta. `CapEff: 0000000000000000` significa que toda operación privilegiada devuelve `EPERM`. El reflejo de `capabilities.add` es casi siempre incorrecto; el caso clásico es escuchar en el puerto 80:

```console
$ kubectl -n production logs api-7d9f8c5b64-x2wqp
listen tcp :80: bind: permission denied
```

El arreglo correcto es `containerPort: 8080` con `Service.port: 80`. El segundo mejor arreglo es `net.ipv4.ip_unprivileged_port_start=0` como sysctl inseguro. Agregar `NET_BIND_SERVICE` es el peor de los tres y de todos modos está prohibido por `restricted`.

### 7.4 Depurar un pod distroless

Sacaste el shell a propósito. Los contenedores efímeros restauran la depurabilidad sin debilitar la imagen:

```console
$ kubectl -n production debug -it api-7d9f8c5b64-x2wqp \
    --image=busybox:1.36 \
    --target=api \
    --profile=general \
    -- sh
Defaulting debug container name to debugger-t9k2c.
If you don't see a command prompt, try pressing enter.
/ # ls /proc/1/root/usr/local/bin
api
/ # cat /proc/1/environ | tr '\0' '\n' | grep -c PASSWORD
0
```

`--target=api` se une a los namespaces de procesos y de red del contenedor objetivo, así que `/proc/1` es la aplicación. `--profile=general` es importante: sin un perfil, las versiones más viejas de `kubectl` no copiaban nada y el contenedor de depuración podía terminar *más* privilegiado que el objetivo — en un namespace `restricted` simplemente sería rechazado por PSA. Notá que cada `kubectl debug` sobre un Pod crea una escritura al subrecurso `ephemeralcontainers`, que tu política de auditoría (§3.6) registra.

### 7.5 Diagnosticar un descarte de NetworkPolicy

Las denegaciones de NetworkPolicy descartan paquetes en silencio: sin ICMP unreachable, sin TCP RST. Toda falla parece un timeout, que es por lo que la gente le echa la culpa al DNS, al Service o a la app antes de culpar a la política.

```console
# Symptom
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- \
    wget -qO- --timeout=3 http://payments.production.svc.cluster.local:8080/healthz
wget: download timed out
command terminated with exit code 1

# Is it DNS or is it the connection?
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- nslookup payments.production.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	payments.production.svc.cluster.local
Address: 10.104.22.187
# DNS resolves -> not the DNS egress rule. Now check policy.

# Which policies select each side?
$ kubectl -n production get netpol -o custom-columns=\
NAME:.metadata.name,PODSELECTOR:.spec.podSelector.matchLabels,TYPES:.spec.policyTypes
NAME                 PODSELECTOR                                 TYPES
default-deny-all     map[]                                       [Ingress Egress]
allow-dns-egress     map[]                                       [Egress]
api-ingress          map[app.kubernetes.io/name:api]             [Ingress]
api-egress           map[app.kubernetes.io/name:api]             [Egress]
payments-ingress     map[app.kubernetes.io/name:payments]        [Ingress]

$ kubectl -n production get netpol api-egress -o jsonpath='{.spec.egress}' | jq
[
  {
    "ports": [{"port": 5432, "protocol": "TCP"}],
    "to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "postgres"}}}]
  }
]
# api may egress to postgres:5432 only. payments:8080 is not allowed.
```

Con Cilium, salteá el razonamiento y leé el veredicto directamente:

```console
$ hubble observe --namespace production --verdict DROPPED --last 10
Sep  3 14:22:31.117: production/api-7d9f8c5b64-x2wqp:44120 (ID:23814)
  -> production/payments-6b4c8d9f75-h2ln8:8080 (ID:41093)
  policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  3 14:22:32.141: production/api-7d9f8c5b64-x2wqp:44120 (ID:23814)
  -> production/payments-6b4c8d9f75-h2ln8:8080 (ID:41093)
  policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
```

`policy-verdict:none EGRESS DENIED` nombra la dirección y el lado. Sin observabilidad a nivel de flujo este mismo diagnóstico lleva un orden de magnitud más de tiempo, que es el argumento operativo más fuerte para elegir un CNI que la provea.

### 7.6 Diagnosticar una caída provocada por un webhook

El peor modo de falla de este objetivo es autoinfligido: un webhook de política tira abajo la ruta de escritura del cluster.

```console
$ kubectl -n production scale deploy/api --replicas=4
Error from server (InternalError): Internal error occurred: failed calling webhook
"mutate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/mutate/fail?timeout=30s": context deadline exceeded

$ kubectl -n kyverno get pods
NAME                                             READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-6d9c7f8b54-4nq2x    0/1     CrashLoopBackOff   7          14m
kyverno-admission-controller-6d9c7f8b54-8ktdw    0/1     CrashLoopBackOff   7          14m

$ kubectl get validatingwebhookconfigurations \
    -o custom-columns=NAME:.metadata.name,FAILUREPOLICY:.webhooks[*].failurePolicy
NAME                              FAILUREPOLICY
kyverno-policy-validating-webhook-cfg   Fail,Fail
kyverno-resource-validating-webhook-cfg Fail
```

Rompé el vidrio (de forma deliberada, registrada y reversible) — la configuración del webhook en sí no está sujeta al webhook:

```console
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o yaml > /tmp/break-glass-backup.yaml
$ kubectl delete validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg
validatingwebhookconfiguration.admissionregistration.k8s.io "kyverno-resource-validating-webhook-cfg" deleted
```

Prevenir la recurrencia es un cambio de diseño, no una entrada de runbook: excluí el namespace propio del motor de políticas y `kube-system` con un `namespaceSelector`, corré ≥3 réplicas repartidas en dominios de falla con un PodDisruptionBudget, mantené `timeoutSeconds` en 5–10 en lugar de 30, y mové las reglas que deben sobrevivir a una caída del motor a `ValidatingAdmissionPolicy` in-tree, que no puede caerse independientemente del API server.

---

## 8. Hechos clave para retener

* Los objetos `Secret` de Kubernetes están **codificados en base64, no cifrados**, salvo que `EncryptionConfiguration` esté habilitado en el API server — y habilitarlo no toca los objetos ya almacenados hasta que se reescriben.
* **RBAC es solo aditivo.** No hay regla de denegación; auditá cada binding de un sujeto.
* `resourceNames` no restringe `list`, `watch` sobre colecciones, ni `create`.
* **PSA valida Pods, no Deployments.** Usá la etiqueta `warn` para que `kubectl apply` haga aflorar las violaciones al momento de escribir.
* Fijá `pod-security.kubernetes.io/*-version` — `latest` se endurece en silencio entre actualizaciones del cluster.
* **NetworkPolicy es solo lista de permitidos y aditiva**; un namespace sin política no tiene aplicación, y una denegación por defecto sin regla de egreso para DNS rompe todo con un timeout, no con un error de DNS.
* Las firmas y la política de admisión deben atarse a **digests `@sha256:`**, nunca a tags.
* `cosign verify` sin `--certificate-identity*` ni `--certificate-oidc-issuer` prueba únicamente que *alguien* la firmó.
* `privileged: true` neutraliza capabilities, seccomp y AppArmor simultáneamente — es root en el host.
* `allowPrivilegeEscalation: false` activa `no_new_privs`; verificalo con `NoNewPrivs: 1` en `/proc/1/status`. `Seccomp: 2` confirma que hay un filtro cargado.
* `failurePolicy: Fail` en un webhook de admisión es una **dependencia de disponibilidad del cluster**; `Ignore` es un bypass de seguridad silencioso. Elegí por regla.
* SLSA Build L2 (procedencia firmada desde un builder alojado) es barato; L3 requiere que los propios pasos del build no puedan falsificar la procedencia.

---

## 9. Referencias

**Objetivos del examen**
* Objetivos del examen LPI 701 (lista autoritativa de objetivos y pesos) — https://www.lpi.org/our-certifications/exam-701-objectives/

**Kubernetes — conceptos de seguridad y referencia de la API**
* Documentación de seguridad de Kubernetes — https://kubernetes.io/docs/concepts/security/
* Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
* Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
* Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
* Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
* Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
* User Namespaces — https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
* Runtime Class — https://kubernetes.io/docs/concepts/containers/runtime-class/
* Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
* Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
* Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
* Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
* Encrypting Confidential Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
* Using KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
* Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
* Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
* Projected Volumes — https://kubernetes.io/docs/concepts/storage/projected-volumes/
* Debug Running Pods (contenedores efímeros) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
* Secrets — https://kubernetes.io/docs/concepts/configuration/secret/

**Cadena de suministro**
* Documentación de Sigstore — https://docs.sigstore.dev/
* Cosign — https://github.com/sigstore/cosign
* Log de transparencia Rekor — https://docs.sigstore.dev/logging/overview/
* Especificación SLSA, niveles v1.0 — https://slsa.dev/spec/v1.0/levels
* Framework de atestaciones in-toto — https://github.com/in-toto/attestation
* Especificación SPDX — https://spdx.dev/
* Especificación CycloneDX — https://cyclonedx.org/specification/overview/
* Syft — https://github.com/anchore/syft
* Grype — https://github.com/anchore/grype
* Trivy — https://trivy.dev/
* Imágenes base distroless — https://github.com/GoogleContainerTools/distroless
* BuildKit — https://github.com/moby/buildkit

**Motores de políticas**
* Documentación de Kyverno — https://kyverno.io/docs/
* Verificación de imágenes en Kyverno — https://kyverno.io/docs/writing-policies/verify-images/
* OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
* Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/

**Runtime, aislamiento y detección**
* OCI Runtime Specification — https://github.com/opencontainers/runtime-spec
* OCI Image Specification — https://github.com/opencontainers/image-spec
* gVisor — https://gvisor.dev/docs/
* Kata Containers — https://katacontainers.io/docs/
* Falco — https://falco.org/docs/
* Cilium Tetragon — https://tetragon.io/docs/
* Página de manual de capabilities de Linux — https://man7.org/linux/man-pages/man7/capabilities.7.html
* Página de manual de seccomp — https://man7.org/linux/man-pages/man2/seccomp.2.html

**Redes e identidad**
* Documentación de Cilium — https://docs.cilium.io/
* Política de red de Calico — https://docs.tigera.io/calico/latest/network-policy/
* Observabilidad con Hubble — https://docs.cilium.io/en/stable/observability/hubble/
* SPIFFE — https://spiffe.io/docs/latest/spiffe-about/overview/
* SPIRE — https://spiffe.io/docs/latest/spire-about/

**Gestión de secretos**
* External Secrets Operator — https://external-secrets.io/latest/
* Secrets Store CSI Driver — https://secrets-store-csi-driver.sigs.k8s.io/
* Método de autenticación de Kubernetes en HashiCorp Vault — https://developer.hashicorp.com/vault/docs/auth/kubernetes
* SOPS — https://github.com/getsops/sops
* Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets

**Benchmarks y modelos de amenazas**
* NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/pubs/sp/800/190/final
* CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
* kube-bench — https://github.com/aquasecurity/kube-bench
* CNCF TAG Security — https://tag-security.cncf.io/
* OWASP Kubernetes Top Ten — https://owasp.org/www-project-kubernetes-top-ten/
* MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/