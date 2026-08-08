# Guía de estudio KCSA — Tema 6.3: Cumplimiento de la cadena de suministro (Supply Chain Compliance)

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El vector de ataque a la cadena de suministro de software en Kubernetes
Las aplicaciones modernas nativas de la nube dependen en gran medida de pipelines de compilación multietapa, imágenes base externas, dependencias binarias de terceros y paquetes de código abierto. Este complejo grafo de dependencias expone las cargas de trabajo del cluster a severos vectores de ataque a la cadena de suministro, incluyendo:

- **Source Code Tampering:** Commits no intencionados o maliciosos introducidos en dependencias upstream o repositorios de origen.
- **CI/CD Build Pipeline Compromise:** Secuestro de agentes de build para inyectar puertas traseras o binarios alterados en imágenes de contenedores después de la compilación sin cambiar el historial del control de versiones.
- **Registry & Image Tampering:** Modificación no autorizada o sobrescritura de tags de imagen (`latest`, `v1.2.0`) dentro de registries de contenedores.
- **Dependency Confusion & Typosquatting:** Obtención de paquetes públicos maliciosos que eclipsan a los paquetes de ámbito privado interno durante el tiempo de build.

```
+---------------------------------------------------------------------------------------------------+
|                                 SOFTWARE SUPPLY CHAIN THREAT MODEL                                 |
+---------------------------------------------------------------------------------------------------+
|  [Source Code] ---> [Build / CI Pipeline] ---> [Container Registry] ---> [Kubernetes Admission]   |
|        |                    |                         |                          |                |
|  * Malicious Code    * Build Tampering         * Image Overwriting       * Deployment of Untrusted|
|  * Compromised Deps  * Key Exfiltration        * Registry Poisoning        / Non-compliant Artifacts|
+---------------------------------------------------------------------------------------------------+
```

### 1.2 Mandatos de cumplimiento y motores regulatorios
Las organizaciones que despliegan cargas de trabajo en producción se rigen por estrictos marcos regulatorios y directivas de seguridad:
- **Orden Ejecutiva de EE. UU. 14028 y NIST SP 800-218 (SSDF):** Exige procedencia criptográfica verificable y una lista explícita de materiales de software (Software Bill of Materials - SBOM) para todo el software que se ejecute en entornos críticos.
- **SLSA (Supply-chain Levels for Software Artifacts):** Define una lista de verificación inquebrantable de estándares (Niveles 1 a 3+) que garantizan la integridad de la compilación, la hermeticidad y la trazabilidad de la fuente.
- **PCI-DSS 4.0 y SOC 2 Tipo II:** Requiere auditabilidad de la integridad del software, gestión automatizada de vulnerabilidades y controles de acceso strictly sobre los despliegues en producción.

### 1.3 El problema arquitectónico
El principal desafío arquitectónico para los equipos de SRE y Plataforma es establecer la **ingestión de software de cero confianza (zero-trust software ingestion)**. Escanear simplemente las imágenes de contenedores en reposo en busca de vulnerabilidades conocidas (CVEs) es insuficiente. 

Una arquitectura resiliente de cumplimiento de la cadena de suministro debe garantizar que:
1. **Cada imagen de contenedor que se ejecuta en Kubernetes está firmada criptográficamente** por una identidad autorizada y verificable (Keyless OIDC / PKI).
2. **La lista de materiales de software (SBOM)** existe, está firmada y está vinculada al digest criptográfico exacto (`sha256:...`) de la imagen.
3. **La procedencia de compilación (Build Provenance)** (como la procedencia SLSA Nivel 3) es generada por una plataforma de build aislada e infalsificable y se valida en tiempo de ejecución.
4. **Los Dynamic Admission Webhooks de Kubernetes** rechazan de forma determinista cualquier despliegue de Pod que intente ejecutar imágenes que carezcan de firmas válidas, atestaciones requeridas o certificados de cumplimiento, sin degradar el rendimiento del API server ni causar caídas en cascada del despliegue.

---

## 2. Comparaciones técnicas y tablas de balance (Trade-offs)

### 2.1 Estándares de Software Bill of Materials (SBOM)

| Característica / Criterio | SPDX (Software Package Data Exchange) | CycloneDX | SWID (Software Identification Tags) |
| :--- | :--- | :--- | :--- |
| **Organismo rector** | Linux Foundation (ISO/IEC 5962:2021) | OWASP Foundation | ISO/IEC 19770-2:2015 / NIST |
| **Enfoque principal de diseño** | Cumplimiento de licencias, gobernanza de código abierto, análisis de propiedad intelectual. | Seguridad de aplicaciones (AppSec), seguimiento de vulnerabilidades, análisis de dependencias, seguimiento criptográfico. | Gestión de activos de software, seguimiento de inventario de software instalado. |
| **Soporte JSON/YAML/XML** | JSON, YAML, TV (Tag:Value), RDF/XML. | JSON, XML, Protobuf. | XML nativo. |
| **Formato de intercambio de vulnerabilidades (VEX)** | Integrado a través de OpenVEX o perfiles de extensión SPDX 3.0. | Integración nativa (especificación CycloneDX VEX). | Requiere extensiones de mapeo externas. |
| **Ecosistema de herramientas** | Syft, Trivy, Kubernetes `bom`, herramientas SPDX. | Syft, Trivy, Dependency-Check, suite OWASP. | Integraciones de gestión de paquetes de SO Windows/Linux. |
| **Recomendación para producción** | **Alta** para auditoría legal/de licencias y amplia compatibilidad con código abierto. | **Alta** para operaciones de seguridad activas, AppSec y correlación de CVE en tiempo real. | Baja para cadenas de suministro modernas nativas de la nube en contenedores. |

---

### 2.2 Protocolos de firma criptográfica y modelos de confianza

| Característica / Criterio | Firma tradicional con clave privada (GPG / Static RSA) | Keyless Sigstore (Fulcio + Rekor + OIDC) | Cosign Static KMS (AWS KMS, GCP KMS, Vault) |
| :--- | :--- | :--- | :--- |
| **Ciclo de vida de la clave** | Pares de claves asimétricas de larga duración; alto riesgo de exposición o pérdida de claves. | Claves efímeras de corta duración (válidas por minutos); sin gestión de claves privadas. | Claves KMS administradas; clave asimétrica rotada a través del proveedor de la nube. |
| **Proveedor de identidad** | Cadenas de certificados CA internas o autofirmadas. | Tokens de identidad OIDC (GitHub Actions, SPIFFE/SPIRE, Google/Microsoft Workplace). | Vinculaciones (bindings) de Roles / Políticas de IAM en la nube. |
| **No repudio y auditabilidad**| Verificación de firma local; el registro de auditoría depende de logs privados. | **Registro público inmutable (Rekor)** proporciona transparencia verificable criptográficamente. | Logs de auditoría en la nube (CloudTrail / Cloud Logging). |
| **Manejo de revocaciones** | Complejidad de CRL / OCSP; difícil en entornos aislados (air-gapped). | Manejado a través de expiración de certificados de corta duración + marcas de tiempo de transparencia de Rekor. | Administrado mediante revocación de políticas de IAM y deshabilitación de claves KMS. |
| **Sobrecarga operativa** | Extremadamente alta (distribución segura de claves, HSMs, procedimientos de rotación). | **Muy baja** para ingenieros de plataforma (automatiza PKI mediante certificados de corta duración). | Media (Requiere acceso a credenciales de la nube durante el tiempo de CI/CD). |

---

### 2.3 Motores de políticas de admisión de Kubernetes para verificación de la cadena de suministro

| Métrica / Dimensión | Kyverno | OPA Gatekeeper | Cosign CLI / Policy Controller |
| :--- | :--- | :--- | :--- |
| **Lenguaje de políticas** | YAML declarativo de Kubernetes (CRDs nativos). | Rego (Lenguaje de consultas declarativo). | CRDs de políticas YAML (enfocado en Cosign). |
| **Parsing de atestaciones (Cosign/in-toto)** | Tipo de regla nativo `verifyImages`; parsing de payload de atestación JMESPath integrado. | Requiere extracción de datos externos o sidecar `cosign-gatekeeper-provider` / parsing de Rego personalizado. | Diseñado específicamente para firmas y atestaciones de Cosign. |
| **Curva de aprendizaje** | Baja para SREs de K8s familiarizados con YAML estándar. | Alta (Requiere aprender Rego y la mecánica de ejecución de OPA). | Baja (Sintaxis diseñada a medida para el ecosistema Sigstore). |
| **Aplicación de umbrales de vulnerabilidad** | Coincidencia nativa en payloads de atestación de vulnerabilidades de Cosign. | Scripts de Rego personalizados complejos que evalúan blobs de atestación JSON. | Soportado mediante coincidencia de CRD de políticas de imagen. |
| **Validación multirrecurso** | Excelente (Valida, muta y genera recursos de K8s). | Excelente (Valida objetos a través de contextos arbitrarios de K8s). | Limitado principalmente a la verificación de la cadena de suministro de imágenes de contenedor. |

---

## 3. Manifiestos y configuraciones listos para producción

### 3.1 Pipeline automatizado de cadena de suministro CI/CD (GitHub Actions)
Este pipeline de producción compila una imagen de contenedor, genera un **SBOM CycloneDX**, firma la imagen usando **Sigstore Keyless** y adjunta una **atestación de procedencia SLSA Nivel 3 de in-toto** al registry OCI.

```yaml
name: Supply Chain Compliance Pipeline

on:
  push:
    branches:
      - main
    tags:
      - 'v*'

permissions:
  contents: read
  packages: write
  id-token: write # Required for Sigstore OIDC keyless signing

jobs:
  build-sign-attest:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3.5.0

      - name: Install Syft
        uses: anchore/sbom-action/download-syft@v0.16.0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry (GHCR)
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Image Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=semver,pattern={{version}}
            type=sha,format=long

      - name: Build and Push OCI Container Image
        id: build-image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

      - name: Generate CycloneDX SBOM with Syft
        run: |
          IMAGE_DIGEST="ghcr.io/${{ github.repository }}@${{ steps.build-image.outputs.digest }}"
          syft "${IMAGE_DIGEST}" -o cyclonedx-json=sbom.cyclonedx.json

      - name: Sign Container Image (Keyless Sigstore)
        run: |
          IMAGE_DIGEST="ghcr.io/${{ github.repository }}@${{ steps.build-image.outputs.digest }}"
          cosign sign --yes "${IMAGE_DIGEST}"

      - name: Attest SBOM to OCI Registry
        run: |
          IMAGE_DIGEST="ghcr.io/${{ github.repository }}@${{ steps.build-image.outputs.digest }}"
          cosign attest --yes \
            --type cyclonedx \
            --predicate sbom.cyclonedx.json \
            "${IMAGE_DIGEST}"

      - name: Attest SLSA Provenance to OCI Registry
        run: |
          IMAGE_DIGEST="ghcr.io/${{ github.repository }}@${{ steps.build-image.outputs.digest }}"
          cosign attest --yes \
            --type slsaprovenance \
            --predicate <(cat <<EOF
          {
            "builder": { "id": "https://github.com/actions/runner" },
            "buildType": "https://actions.github.io/build-types/v1",
            "invocation": {
              "configSource": {
                "uri": "git+https://github.com/${{ github.repository }}@${{ github.sha }}",
                "digest": { "sha1": "${{ github.sha }}" }
              }
            }
          }
          EOF
          ) "${IMAGE_DIGEST}"
```

---

### 3.2 Kyverno ClusterPolicy: Exigir firma de imagen, procedencia SLSA y verificación de SBOM
Esta `ClusterPolicy` lista para producción valida que todas las cargas de trabajo dirigidas al namespace `production` cumplan con tres criterios no negociables:
1. **Firma válida de Keyless Sigstore** emitida por el workflow específico del repositorio de GitHub.
2. **Atestación de procedencia SLSA** verificada.
3. **Atestación de SBOM CycloneDX** verificada y adjunta a la imagen del contenedor.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-supply-chain-compliance
  annotations:
    policies.kyverno.io/title: Enforce Image Signatures, Provenance, and SBOM
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Deployment, StatefulSet
    description: >-
      Verifies that container images deployed to production namespaces are signed via
      Sigstore Keyless OIDC, contain an authenticated SLSA Provenance attestation,
      and have an attached CycloneDX SBOM attestation.
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 15
  failurePolicy: Fail
  rules:
    - name: verify-image-signature-and-attestations
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
      verifyImages:
        - imageReferences:
            - "ghcr.io/my-org/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/my-org/*/.github/workflows/*@refs/heads/main"
            rekor:
              url: "https://rekor.sigstore.dev"
          attestations:
            - type: https://slsa.dev/provenance/v0.2
              attestors:
                - entries:
                    - keyless:
                        issuer: "https://token.actions.githubusercontent.com"
                        subject: "https://github.com/my-org/*/.github/workflows/*@refs/heads/main"
                        rekor:
                          url: "https://rekor.sigstore.dev"
            - type: https://cyclonedx.org/schema/bom-1.4.json
              attestors:
                - entries:
                    - keyless:
                        issuer: "https://token.actions.githubusercontent.com"
                        subject: "https://github.com/my-org/*/.github/workflows/*@refs/heads/main"
                        rekor:
                          url: "https://rekor.sigstore.dev"
```

---

### 3.3 Gatekeeper OPA Constraint y ConstraintTemplate para verificación de la cadena de suministro
Para los clusters que utilizan **OPA Gatekeeper**, el siguiente `ConstraintTemplate` define un mecanismo de aserción para bloquear tags de imágenes no resueltas/sin hash, exigiendo referencias a digests inmutables (`sha256:`).

```yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8sdisallowtagsonly
  annotations:
    metadata.gatekeeper.sh/title: Disallow Mutable Image Tags
    description: Requires all container images to specify an explicit sha256 digest reference to protect against image mutation attacks.
spec:
  crd:
    spec:
      names:
        kind: K8sDisallowTagsOnly
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdisallowtagsonly

        violation[{"msg": msg}] {
          container := input.review.object.spec.template.spec.containers[_]
          not contains(container.image, "@sha256:")
          msg := sprintf("Container '%v' uses a mutable image reference '%v'. Supply chain compliance requires pinned immutable sha256 digests.", [container.name, container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDisallowTagsOnly
metadata:
  name: enforce-immutable-digests-production
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet", "DaemonSet"]
    namespaces:
      - "production"
```

---

## 4. Comandos reales de CLI y salidas esperadas de la terminal

### 4.1 Generación y firma de un SBOM usando Syft y Cosign
Generación de un archivo SBOM CycloneDX a partir del digest de una imagen compilada y su atestación en un registry OCI mediante Cosign.

```bash
$ export IMAGE_URI="ghcr.io/my-org/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

$ syft ${IMAGE_URI} -o cyclonedx-json > sbom.json
 ✔ Loaded image        [sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855]
 ✔ Parsed image        [28 layers]
 ✔ Cataloged packages  [142 packages]

$ head -n 15 sbom.json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.4.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "serialNumber": "urn:uuid:7f3b6c2d-9e1a-4d2b-8a5c-112233445566",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-07T20:35:15Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.4.0"
      }
    ]
  }
}

$ cosign attest --yes --type cyclonedx --predicate sbom.json ${IMAGE_URI}
Generating ephemeral certification key...
Retrieving signed certificate from Fulcio...
Successfully obtained OIDC token from issuer: https://token.actions.githubusercontent.com
Building attestation predicate...
Submitting signature to transparency log (Rekor)...
Successfully logged entry to Rekor with log index: 89452103
Pushing attestation payload to ghcr.io/my-org/payment-service:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.att
```

---

### 4.2 Verificación de firmas de imágenes Keyless con Cosign CLI
Ejecución de la verificación contra el registro de transparencia público Rekor y la raíz de confianza de Fulcio.

```bash
$ cosign verify \
  --certificate-identity-regexp="https://github.com/my-org/*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/my-org/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

Verification for ghcr.io/my-org/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --
The following checks were performed on each of these signatures:
  - The Cosign claims were validated
  - Claims below were verified against verification engine policies:
    - Subject: https://github.com/my-org/payment-service/.github/workflows/deploy.yml@refs/heads/main
    - Issuer: https://token.actions.githubusercontent.com
  - The signature was verified against the specified certificate
  - The certificate was verified using the Sigstore root certificate authority
  - The certificate was checked for revocation
  - The signed claim was verified against the transparency log (Rekor)
  - The signature timestamp was verified against the transparency log

[{"critical":{"identity":{"docker-reference":"ghcr.io/my-org/payment-service"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":{"Bundle":{"SignedEntryTimestamp":"MEUCIQD2g4k...=","Payload":{"body":"...","integratedTime":1754598915,"logIndex":89452103,"logID":"c0d23d6..."},"GitHubWorkflowName":"Deploy Pipeline"}}]
```

---

### 4.3 Consulta y verificación de atestaciones (SLSA y SBOM)
Extracción y decodificación del payload de atestación in-toto directamente desde el registry de contenedores.

```bash
$ cosign verify-attestation \
  --type cyclonedx \
  --certificate-identity-regexp="https://github.com/my-org/*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/my-org/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 | jq '.payload | @base64d | fromjson'

{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://cyclonedx.org/schema/bom-1.4.json",
  "subject": [
    {
      "name": "ghcr.io/my-org/payment-service",
      "digest": {
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      }
    }
  ],
  "predicate": {
    "bomFormat": "CycloneDX",
    "specVersion": "1.4",
    "components": [
      {
        "name": "openssl",
        "version": "3.0.2-0ubuntu1.12",
        "type": "library"
      }
    ]
  }
}
```

---

### 4.4 Prueba de la aplicación de admisión de Kubernetes a través de `kubectl`
Intento de desplegar una imagen de contenedor no atestada o manipulada dentro del namespace `production` protegido por Kyverno.

```bash
$ kubectl run untrusted-test \
  --image=ghcr.io/my-org/payment-service:untrusted-tag \
  -n production

Error from server (Forbidden): admission webhook "mutate.kyverno.before-validation" denied the request: 
resource Pod/production/untrusted-test was blocked due to the following policies:

enforce-supply-chain-compliance:
  verify-image-signature-and-attestations:
    - failed to verify image ghcr.io/my-org/payment-service:untrusted-tag: 
      no matching signatures found for target image.
    - attestation verification failed: missing required in-toto predicate type https://cyclonedx.org/schema/bom-1.4.json
```

---

## 5. Guía de verificación y diagnóstico de fallas

```
+---------------------------------------------------------------------------------------------------+
|                               SUPPLY CHAIN DIAGNOSTIC FLOWCHART                                   |
+---------------------------------------------------------------------------------------------------+
| Pod Admission Rejected                                                                            |
|        |                                                                                          |
|        +---> 1. Check Image Reference: Is it using tag or @sha256 digest?                         |
|        |                                                                                          |
|        +---> 2. Run Cosign CLI: `cosign verify --certificate-identity ...`                        |
|        |       |-- Failure: Signature missing or Rekor entry non-existent                          |
|        |       +-- Failure: OIDC SAN Mismatch (Workflow/Repo mismatch)                             |
|        |                                                                                          |
|        +---> 3. Run Cosign Attestation: `cosign verify-attestation --type ...`                    |
|        |       |-- Failure: Predicate schema invalid (e.g. SPDX vs CycloneDX spec)               |
|        |                                                                                          |
|        +---> 4. Inspect Admission Controller Logs (Kyverno/Gatekeeper Webhook)                    |
|                +-- Failure: Webhook timeout (Check API server latency / Rekor availability)       |
+---------------------------------------------------------------------------------------------------+
```

### 5.1 Fallas comunes en producción y causas raíz

#### 1. Falla: `no matching signatures found` / OIDC Subject Mismatch
- **Síntoma:** El admission controller bloquea el despliegue; `cosign verify` devuelve el código de salida `1`.
- **Causa raíz:** La identidad del sujeto OIDC impresa en el certificado de Fulcio (`https://github.com/my-org/repo/.github/workflows/main.yml@refs/heads/main`) no coincide con la regex estricta definida en la política de Kyverno/Gatekeeper.
- **Comando de diagnóstico:**
  ```bash
  # Inspect exact SAN certificate extensions embedded in the signature bundle
  cosign verify-option \
    --keyless \
    ghcr.io/my-org/payment-service@sha256:e3b0c... | jq '.[].optional.Subject'
  ```

#### 2. Falla: Timeout del Admission Webhook (`webhookTimeoutSeconds`)
- **Síntoma:** La creación del Pod se congela durante 10 a 15 segundos y devuelve `Internal error occurred: failed calling webhook`.
- **Causa raíz:** El admission controller está realizando llamadas HTTP externas síncronas a servidores públicos de Rekor/Fulcio (`rekor.sigstore.dev`) o al registry OCI para obtener manifiestos de imagen `.att` o `.sig`, alcanzando latencia de red o límites de tasa (rate limits).
- **Remediación:** 
  1. Almacenar en caché los bundles de claves/certificados públicos localmente dentro del cluster mediante la configuración de almacenamiento en caché de `imageVerification` de Kyverno.
  2. Incrementar la configuración de timeout del webhook a 15 segundos (`webhookTimeoutSeconds: 15`).
  3. Desplegar una instancia privada y autohospedada de Sigstore (TUF root, Rekor, Fulcio) dentro de los límites de la infraestructura empresarial.

#### 3. Falla: `Attestation Predicate Type Mismatch`
- **Síntoma:** La firma de la imagen es válida, pero la verificación de la atestación falla.
- **Causa raíz:** La herramienta generó una declaración `slsaprovenance/v0.1`, pero la política de admisión exige strictly `https://slsa.dev/provenance/v0.2` o la versión de esquema `1.4` de `CycloneDX`.
- **Comando de diagnóstico:**
  ```bash
  # Query registry for all attached attestations and inspect predicateType
  cosign tree ghcr.io/my-org/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  ```

---

### 5.2 Guía paso a paso (Runbook) de diagnóstico para SREs

1. **Verificar la resolución del digest de imagen local:**
   Asegurar que la máquina local y el API server del cluster resuelvan exactamente el mismo digest de imagen de contenedor:
   ```bash
   crane digest ghcr.io/my-org/payment-service:v1.2.0
   ```

2. **Validar la existencia de la entrada en el log de Sigstore Rekor:**
   Consultar a Rekor directamente utilizando el UUID del bundle de firma:
   ```bash
   rekor-cli search --sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   ```

3. **Inspeccionar los logs de admisión de Kyverno en tiempo real:**
   ```bash
   kubectl logs -n kyverno -l app=kyverno -f --tail=100 | grep -i "imageverify"
   ```

4. **Auditar cargas de trabajo en ejecución no conformes:**
   Identificar cualquier carga de trabajo que se esté ejecutando actualmente en el cluster y que viole la política de la cadena de suministro:
   ```bash
   kubectl get clusterpolicyreport -o json | jq '.reports[].results[] | select(.result=="fail")'
   ```

---

## 6. Referencias

- **Plan de estudios oficial de CNCF KCSA (CNCF KCSA Official Curriculum):**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Documento de mejores prácticas para la cadena de suministro de software de CNCF (TAG Security):**  
  https://tag-security.cncf.io/supply-chain-security/
- **Marco de trabajo SLSA (Supply-chain Levels for Software Artifacts Framework):**  
  https://slsa.dev/
- **Documentación de Sigstore Cosign:**  
  https://docs.sigstore.dev/
- **Especificación del marco de atestación in-toto:**  
  https://in-toto.io/
- **Documentación de verificación de imágenes y atestación de Kyverno:**  
  https://kyverno.io/docs/user-guide/enforce-executables/image-verify/
- **NIST SP 800-218 (Secure Software Development Framework - SSDF):**  
  https://csrc.nist.gov/pubs/sp/800/218/final
- **Especificación OWASP CycloneDX:**  
  https://cyclonedx.org/
- **Anchore Syft (Herramienta de generación de SBOM):**  
  https://github.com/anchore/syft