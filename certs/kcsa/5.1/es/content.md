# Guía de Estudio KCSA — Sección 5.1: Supply Chain Security

**Dominio**: Supply Chain Security  
**Examen**: CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Peso del Dominio**: ~2.29%  
**Audiencia Objetivo**: Senior SREs, Security Engineers y Platform Architects  

---

## 1. Motivación de Producción y Problema Arquitectónico

Los modelos modernos de despliegue cloud-native dependen en gran medida de dependencias de terceros, container registries públicos y entornos de compilación CI/CD automatizados. Esto introduce vectores de vulnerabilidad significativos a lo largo del ciclo de vida del software. Un **Software Supply Chain Attack** (Ataque a la Cadena de Suministro de Software) ocurre cuando un adversario compromete un componente upstream de la aplicación objetivo—como una imagen base de contenedor, una biblioteca de dependencias de código abierto, un build runner o un artefacto de despliegue—para inyectar lógica maliciosa antes de la ejecución dentro del cluster de Kubernetes.

### Vectores de Ataque a la Cadena de Suministro en Kubernetes

1. **Mutabilidad de Tags y Reemplazo de Imágenes (Tag Mutability & Image Swapping)**: Los tags de contenedor como `:latest` o `:v1.2.0` son referencias de puntero mutables dentro de los registries OCI. Un atacante que comprometa un registry o intercepte el tráfico de red puede sobrescribir una imagen etiquetada con código malicioso manteniendo el mismo nombre de tag.
2. **Pipelines de Compilación Comprometidos (CI/CD Tampering)**: Si la infraestructura de compilación (por ejemplo, runners de GitHub Actions, tareas de Tekton, nodos de Jenkins) carece de aislamiento criptográfico, un atacante puede modificar binarios durante la compilación o inyectar capas maliciosas después de la compilación.
3. **Envenenamiento de Dependencias y Typosquatting (Dependency Poisoning & Typosquatting)**: La ingesta de paquetes no verificados desde repositorios públicos (PyPI, npm, crates.io) introduce código con puertas traseras directamente en el filesystem del contenedor.
4. **Falta de Proveniencia y Atestación (Lack of Provenance & Attestation)**: Desplegar artefactos sin una prueba verificable de *quién* construyó la imagen, *cómo* se construyó y de *qué commit del código fuente* se originó hace que el no repudio sea imposible.

### Diseño Arquitectónico: Aplicación de Cadena de Suministro Zero Trust

Para prevenir la ejecución de software no verificado, los clusters de Kubernetes deben implementar una **Arquitectura de Cadena de Suministro Zero Trust**. Esto requiere desplazar los controles de seguridad a la izquierda (shift left) dentro del pipeline de compilación, mientras se aplica una verificación criptográfica dinámica en el perímetro del cluster mediante un **Admission Controller**.

```
  +-----------------------------------------------------------------------------------+
  |                                BUILD & ATTESTATION PHASE                          |
  |                                                                                   |
  |  +------------+     +-------------------+     +--------------------------------+  |
  |  | Git Commit | --> |  Hermetic Build   | --> | Build OCI Image + Syft SBOM    |  |
  |  +------------+     +-------------------+     +--------------------------------+  |
  |                                                              |                    |
  |                                                              v                    |
  |     +-------------------------+     +------------------------------------------+  |
  |     | Sigstore / Fulcio OIDC  | --> | Cosign Sign & Attest (SLSA Provenance)   |  |
  |     +-------------------------+     +------------------------------------------+  |
  |                                                              |                    |
  |                                                              v                    |
  |                                     +------------------------------------------+  |
  |                                     | Push Artifacts & Payload to Registry     |  |
  |                                     +------------------------------------------+  |
  +-------------------------------------------------------|---------------------------+
                                                          |
                                                          v
  +-----------------------------------------------------------------------------------+
  |                             KUBERNETES ADMISSION PHASE                            |
  |                                                                                   |
  |   kubectl apply -f deployment.yaml                                                |
  |                           |                                                       |
  |                           v                                                       |
  |         +-----------------------------------+                                     |
  |         |   Kubernetes API Server           |                                     |
  |         +-----------------------------------+                                     |
  |                           |                                                       |
  |                           v (Validating Webhook Call)                             |
  |         +-----------------------------------+                                     |
  |         | Kyverno / Gatekeeper Engine       |                                     |
  |         +-----------------------------------+                                     |
  |           /                               \                                       |
  |          /                                 \                                      |
  |         v                                   v                                     |
  |  Fetch Signature & Attestation      Verify Rekor Transparency Log                 |
  |  from Registry                      & OIDC Identity via Fulcio Root               |
  |         \                                   /                                     |
  |          \                                 /                                      |
  |           v                               v                                       |
  |         +-----------------------------------+                                     |
  |         |  Cryptographic Trust Decision     |                                     |
  |         +-----------------------------------+                                     |
  |                /                     \                                            |
  |         ALLOWED                       BLOCKED                                     |
  |            /                           \                                          |
  |           v                             v                                         |
  |  Pod Scheduled                API Server Rejects Request                          |
  |  to kubelet                   (HTTP Status 422 / Unprocessable)                   |
  +-----------------------------------------------------------------------------------+
```

### Abstracciones Clave de Seguridad

- **Digest Pinning**: Referenciar imágenes de contenedor mediante un hash criptográfico inmutable (`sha256:...`) en lugar de tags mutables (`:v1.0.0`).
- **Sigstore / Cosign**: Un estándar de código abierto para firmar, verificar y almacenar firmas y atestaciones de contenedores directamente dentro de registries compatibles con OCI.
- **SLSA (Supply-chain Levels for Software Artifacts)**: Un framework de seguridad que define los requisitos para la integridad de la compilación, la generación de proveniencia y el rastreo de metadatos no falsificables a lo largo de cuatro niveles progresivos (SLSA v1.0).
- **Software Bill of Materials (SBOM)**: Un inventario anidado y estructurado de componentes de software, dependencias y detalles de licencias codificados en formatos estándar como SPDX o CycloneDX.

---

## 2. Comparativas Técnicas y Análisis de Compensaciones (Trade-offs)

### 2.1 Metodologías Criptográficas de Firma de Imágenes

| Dimensión Arquitectónica | Par de Claves Asimétricas Estáticas (RSA/ECDSA) | Firma Keyless (Sigstore / Fulcio / Rekor) | Firma PKI / CA X.509 Interna |
| :--- | :--- | :--- | :--- |
| **Modelo de Identidad** | Clave privada asimétrica de larga duración almacenada en secretos de CI o KMS | Certificado X.509 efímero respaldado por la identidad de OpenID Connect (OIDC) | Certificado de cliente de larga duración emitido por una CA interna empresarial |
| **Gestión del Ciclo de Vida de Claves** | Alto costo operativo manual; procedimientos complejos de rotación y revocación | Cero costo operativo de gestión de claves; las claves expiran en minutos (típicamente 10 min) | Costo operativo medio/alto; requiere infraestructura CRL/OCSP |
| **No Repudio** | Bajo; si la clave privada se filtra, las firmas históricas se pueden falsificar retroactivamente | Alto; marcado de tiempo criptográfico vinculado al registro de transparencia inmutable de Rekor | Medio; depende de la integridad de la autoridad de sellado de tiempo de la CA |
| **Compatibilidad con Air-Gap** | Nativa; no requiere conectividad a internet ni servicios externos | Requiere instancias autoalojadas de Fulcio, Rekor y emisor Dex/OIDC | Nativa; requiere conectividad local con la CA interna |
| **Auditabilidad** | Limitada a los registros de posesión de claves | Pista de auditoría criptográfica global/interna registrada en el log append-only de Rekor | Registros internos de la CA empresarial |

---

### 2.2 Mecanismos de Motores de Políticas In-Cluster para Verificación

| Característica de Evaluación | Kyverno (`ClusterPolicy`) | OPA Gatekeeper + Ratify | Portieris |
| :--- | :--- | :--- | :--- |
| **DSL / Lenguaje** | YAML declarativo (UX nativa de K8s) | Rego (variante de Datalog) | Custom Resources (CRDs) declarativos |
| **Soporte de Verificación con Cosign** | Bloque `imageValidations` inline nativo | A través de la integración del proveedor externo Ratify | Soporte nativo para Notary v1 / Cosign |
| **Verificación de Atestación/SBOM** | Capacidad nativa (bloque `attestations` con filtrado JMESPath) | Políticas de Rego flexibles sobre consultas de payload externas | Limitado a la validación de firma de imagen |
| **Capacidad de Mutación de Políticas** | Nativa (la regla `mutate` puede reescribir tags a hashes de digest exactos) | Requiere Gatekeeper Mutations (controller separado) | Muta cadenas de imágenes a digests |
| **Curva de Aprendizaje** | Baja (Ingenieros estándar de K8s) | Alta (Requiere aprender la mecánica de Rego y OPA) | Baja/Media |

---

## 3. Manifiestos de Producción y Código de Infraestructura

### 3.1 Workflow de GitHub Actions: Compilación, Syft SBOM, Firma Keyless con Cosign y Atestación SLSA

Este workflow realiza una compilación usando `docker/build-push-action`, genera un SBOM SPDX a través de Syft, firma la imagen OCI sin clave (keyless) mediante Sigstore usando el id-token OIDC de GitHub y adjunta metadatos de proveniencia SLSA.

```yaml
name: Production Supply Chain Pipeline

on:
  push:
    branches:
      - main
    tags:
      - 'v*'

permissions:
  contents: read
  id-token: write # Required for keyless OIDC signing with Sigstore/Fulcio
  packages: write

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-sign-attest:
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3.5.0

      - name: Install Syft
        uses: anchore/sbom-action/download-syft@v0.16.0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Metadata (Tags/Labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=semver,pattern={{version}}
            type=sha,format=long

      - name: Build and Push OCI Image
        id: build-push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: false # Using custom Cosign attestation step below

      - name: Generate SPDX SBOM with Syft
        run: |
          syft ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }} \
            -o spdx-json=sbom.spdx.json

      - name: Keyless Sign OCI Image with Cosign
        run: |
          cosign sign --yes \
            -a "repo=${{ github.repository }}" \
            -a "workflow=${{ github.workflow }}" \
            -a "sha=${{ github.sha }}" \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"

      - name: Attest SBOM with Cosign
        run: |
          cosign attest --yes \
            --type spdx \
            --predicate sbom.spdx.json \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"

      - name: Attest SLSA Provenance with Cosign
        run: |
          cosign attest --yes \
            --type slsaprovenance \
            --predicate <(echo '{"builder":{"id":"https://github.com/actions/runner"}}') \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"
```

---

### 3.2 Kyverno `ClusterPolicy`: Aplicar Firmas de Imágenes, Identidad OIDC Keyless y Mutabilidad de Digest

Esta política aplica estrictamente tres invariantes de la cadena de suministro:
1. Cada imagen de contenedor debe ser referenciada utilizando un digest SHA256 explícito (regla `mutate`).
2. Cada imagen debe contener una firma keyless válida emitida por Fulcio bajo la identidad especificada del repositorio de GitHub Actions (regla `verifyImages`).
3. Cada imagen debe llevar adjunta una atestación SPDX SBOM (regla `attestations`).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-supply-chain-integrity
  annotations:
    policies.kyverno.io/title: Enforce Image Signing and Digest Resolution
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: mutate-tags-to-digests
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        mutateDigest:
          defaultWithDigest: true
          resolutionTimeoutSeconds: 10

    - name: verify-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/enterprise/production/*:*"
            - "ghcr.io/enterprise/production/*@sha256:*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main"
            rekor:
              url: "https://rekor.sigstore.dev"
          attestations:
            - type: https://spdx.dev/Document
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        issuer: "https://token.actions.githubusercontent.com"
                        subject: "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main"
```

---

### 3.3 Despliegue de Carga de Trabajo de Producción (Referencia a Digest SHA256 Fijado)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: finance
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-system
    sec.domain/supply-chain: verified
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: processor
          # Immutable SHA256 digest pinned - bypasses tag mutation vulnerabilities
          image: ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8443
              name: https
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

---

## 4. Ejecución Real de Comandos de CLI en Terminal y Salidas del Sistema

### 4.1 Inspección Local de Imágenes y Extracción de Digest

```bash
$ crane digest ghcr.io/enterprise/production/payment-processor:v1.4.2
```
```text
sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

---

### 4.2 Verificación de Firma Keyless con Cosign CLI

```bash
$ cosign verify \
  --certificate-identity="https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```
```text
Verification for ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Verification against the certificate was successful
  - The certificate was verified using the Fulcio root CA
  - The signature was verified using the payload
  - The SET verification was successful
  - The entry was verified against the Rekor log

[{"critical":{"identity":{"docker-reference":"ghcr.io/enterprise/production/payment-processor"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":{"Bundle":{"SignedEntryTimestamp":"MEUCIQDVz4K0J2...","Payload":{"body":"...","integratedTime":1723048912,"logIndex":104829104,"logID":"c0d23d...","entryUUID":"24258...\\"}}}}]
```

---

### 4.3 Extracción e Inspección de la Atestación SPDX Adjunta

```bash
$ cosign verify-attestation \
  --type spdx \
  --certificate-identity="https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
  | jq -r '.payload' | base64 --decode | jq .
```
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "ghcr.io/enterprise/production/payment-processor",
      "digest": {
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      }
    }
  ],
  "predicate": {
    "SPDXID": "SPDXRef-DOCUMENT",
    "spdxVersion": "SPDX-2.3",
    "creationInfo": {
      "created": "2026-08-07T19:42:10Z",
      "creators": [
        "Tool: Anchore Syft-v0.16.0"
      ]
    },
    "packages": [
      {
        "name": "alpine-baselayout",
        "SPDXID": "SPDXRef-Package-apk-alpine-baselayout-3.4.3-r2",
        "versionInfo": "3.4.3-r2",
        "supplier": "Organization: Alpine Linux"
      },
      {
        "name": "openssl",
        "SPDXID": "SPDXRef-Package-apk-openssl-3.1.4-r0",
        "versionInfo": "3.1.4-r0",
        "supplier": "Organization: Alpine Linux"
      }
    ]
  }
}
```

---

### 4.4 Provocación de un Fallo de Admisión Bloqueado por Kyverno

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unverified-malicious-pod
  namespace: finance
spec:
  containers:
    - name: backdoor
      image: docker.io/library/nginx:latest
EOF
```
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request:

resource Pod/finance/unverified-malicious-pod was blocked due to the following policies:

check-supply-chain-integrity:
  verify-cosign-keyless-signature:
    failed to verify signature for docker.io/library/nginx:latest:
      no matching signatures found for image docker.io/library/nginx:latest;
      certificate identity "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" did not match actual certificate SAN
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

Cuando el despliegue de una carga de trabajo falla en la etapa del admission controller debido a violaciones de políticas de la cadena de suministro, siga este flujo de trabajo diagnóstico sistemático.

### Árbol de Decisión Diagnóstico

```
                          [Pod Deployment Failed / Rejected]
                                          |
                                          v
                      Execute: kubectl get events -n <namespace>
                                          |
                        +-----------------+-----------------+
                        |                                   |
              Webhook Timeout Error               Admission Denied (403/422)
                        |                                   |
                        v                                   v
          Inspect Webhook Connectivity            Inspect Kyverno/Gatekeeper Logs
           - Check DNS resolution                  - Identify policy rule name
           - Verify Webhook latency                - Verify OIDC SAN matching
```

### 5.1 Paso 1: Consultar Eventos del API Server

Determine si el fallo se originó en webhooks de mutación/validación o en la extracción de imágenes por parte del kubelet:

```bash
$ kubectl get events -n finance --field-selector reason=FailedCreate --sort-by='.metadata.creationTimestamp'
```
```text
LAST SEEN   TYPE      REASON         OBJECT              MESSAGE
12s         Warning   FailedCreate   replica-set/pay-5   Error creating: admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: image verify failed
```

---

### 5.2 Paso 2: Extraer Logs del Webhook del Controller de Kyverno

Inspeccione los logs del contenedor del motor de políticas para extraer la razón exacta del fallo de la aserción criptográfica:

```bash
$ kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "signature verification failed"
```
```text
2026-08-07T20:05:14.281Z ERROR imageVerifier engine/image_verify.go:142 failed to verify image signature {"policy": "check-supply-chain-integrity", "rule": "verify-cosign-keyless-signature", "image": "ghcr.io/enterprise/production/payment-processor@sha256:e3b0c4...", "error": "verifying rekor entry: entry not found in transparency log index"}
```

---

### 5.3 Paso 3: Causas Raíz Comunes y Matrices de Remediación

#### Problema A: Descoincidencia de Identidad OIDC / SAN
* **Síntoma**: `certificate identity ".../deploy.yml@refs/heads/dev" did not match policy subject ".../deploy.yml@refs/heads/main"`.
* **Causa Raíz**: La imagen de contenedor se compiló y firmó en una rama de característica (feature branch, por ejemplo, la rama `dev`), pero la política de despliegue exige que las imágenes provengan strictly de la rama `main`.
* **Remediación**: Vuelva a activar el pipeline de compilación desde un ref aprobado (rama `main`) o actualice el patrón regex `keyless.subject` de Kyverno para admitir los entornos de despliegue según corresponda.

#### Problema B: Falta del Bundle del Registro de Transparencia Rekor
* **Síntoma**: `SET verification failed: entry not found in Rekor`.
* **Causa Raíz**: La firma se creó utilizando `--insecure-ignore-tlog=true` durante el comando `cosign sign`, omitiendo la publicación en el registro de transparencia.
* **Remediación**: Incluya siempre la verificación de Rekor en los pipelines de producción. Vuelva a firmar la imagen sin omitir la integración con Rekor:
  ```bash
  $ cosign sign --yes ghcr.io/enterprise/production/payment-processor@sha256:<digest>
  ```

#### Problema C: Tiempos de Espera Agotados del Webhook (`failurePolicy: Fail`)
* **Síntoma**: `API server call to webhook timed out after 30 seconds`.
* **Causa Raíz**: Kyverno no puede comunicarse con los proveedores OIDC externos (`token.actions.githubusercontent.com`) o Rekor (`rekor.sigstore.dev`) debido a una política de firewall de salida (egress) que bloquea el puerto 443 desde el namespace `kyverno`.
* **Remediación**: Aplique una NetworkPolicy que permita el tráfico de salida (egress) desde el namespace del admission controller hacia los endpoints externos de la PKI de Sigstore.

---

## 6. Referencias

* **CNCF KCSA Curriculum**:  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

* **Sigstore Cosign Documentation**:  
  [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)

* **SLSA (Supply-chain Levels for Software Artifacts) Specification v1.0**:  
  [https://slsa.dev/spec/v1.0/](https://slsa.dev/spec/v1.0/)

* **Kyverno Policy Engine — Verify Images Documentation**:  
  [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)

* **The In-toto Framework Specification**:  
  [https://in-toto.github.io/](https://in-toto.github.io/)

* **SPDX (Software Package Data Exchange) Specification**:  
  [https://spdx.dev/specifications/](https://spdx.dev/specifications/)