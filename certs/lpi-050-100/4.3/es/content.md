# LPI 050-100: Topic 4.3 – Cumplimiento y Mitigación de Riesgos
**Objetivo del examen:** 054.3 / 4.3 Cumplimiento y Mitigación de Riesgos  
**Peso:** 7.5 (Orientado a Operaciones de Producción de SRE Avanzado y Arquitectura de Plataforma)

---

## 1. Motivación Arquitectónica de Producción y Contexto del Problema

En los entornos empresariales cloud-native modernos, el software de código abierto (OSS) representa hasta el 80%–90% del código fuente en los artefactos de contenedores compilados y manifiestos de deployment. Si bien el OSS acelera la velocidad de ingeniería, introducir código de terceros sin una gobernanza sistemática crea severos riesgos legales, financieros y operacionales:

1. **Exposición Legal por Licenciamiento y Propagación Viral:**
   - **Contaminación por Copyleft:** Incluir involuntariamente software con Strong Copyleft (ej. GNU GPLv3) o Network Copyleft (ej. GNU AGPLv3) en microservicios propietarios puede obligar legalmente a una organización a liberar como código abierto su propiedad intelectual (IP) propietaria.
   - **Incompatibilidad de Licencias:** Combinar módulos de software bajo licencias incompatibles (ej. Apache 2.0 y GPLv2) crea un punto muerto legal donde el cumplimiento de una licencia viola la otra.
   - **Violaciones de Atribución y Avisos:** No conservar los avisos de copyright, textos de licencias o archivos `NOTICE` (requeridos por Apache 2.0 o BSD-3-Clause) en binarios distribuidos o aplicaciones cliente SaaS activa la terminación automática de los derechos de uso según cláusulas estrictas de las licencias.

2. **Ataques a la Cadena de Suministro y Transitividad de Vulnerabilidades:**
   - **Riesgos de Dependencias Transitivas:** Los árboles de dependencias profundos (ej. `npm` de Node.js o `PyPI` de Python) hacen que el rastreo manual de cambios de licencias o vulnerabilidades zero-day sea imposible. Los actores maliciosos aprovechan el typosquatting o cuentas de mantenedores comprometidas para insertar backdoors bajo licencias permisivas.
   - **Falta de Transparencia del Software:** Sin un Software Bill of Materials (SBOM) verificable, los equipos de Security Operations (SecOps) y Site Reliability Engineering (SRE) no pueden determinar dentro de los Service Level Objectives (SLOs) objetivo si un CVE crítico (ej. Log4Shell) afecta a las cargas de trabajo desplegadas en producción.

3. **Mandatos Regulatorios y de Cumplimiento:**
   - Marcos de trabajo como la Orden Ejecutiva 14028, la EU Cyber Resilience Act, la ISO/IEC 5230 (especificación OpenChain para el cumplimiento de código abierto) e ISO/IEC 18974 (garantía de seguridad en código abierto) exigen la verificación criptográfica de la procedencia, la generación completa de SBOM (SPDX/CycloneDX) y la gobernanza continua y automatizada de licencias a lo largo de todo el Software Development Life Cycle (SDLC).

```
 +-----------------------------------------------------------------------------------+
 |                                  CI/CD PIPELINE                                   |
 |                                                                                   |
 |  +---------------+      +------------------+      +----------------------------+  |
 |  | Developer     | ---> | Syft / Trivy     | ---> | Cosign / Sigstore          |  |
 |  | Git Commit    |      | (SBOM & License) |      | (Image & SBOM Attestation) |  |
 |  +---------------+      +------------------+      +----------------------------+  |
 +---------------------------------------|-------------------------------------------+
                                         |
                                         v
 +-----------------------------------------------------------------------------------+
 |                           KUBERNETES PRODUCTION CLUSTER                           |
 |                                                                                   |
 |  +--------------------+    +----------------------------+    +-----------------+  |
 |  | kubectl apply /    | -> | OPA Gatekeeper / Kyverno   | -> | Pod Execution   |  |
 |  | GitOps Controller  |    | (Validating Admission Rule)|    | (Compliant)     |  |
 |  +--------------------+    +----------------------------+    +-----------------+  |
 |                                         |                                         |
 |                                         v (Non-compliant: Blocked)                |
 |                                    [Rejected 403]                                 |
 +-----------------------------------------------------------------------------------+
```

---

## 2. Comparaciones Técnicas y Matriz de Compromisos (Trade-Offs)

### 2.1 Categorías de Licencias de Código Abierto

| Categoría de Licencia | Licencias Representativas | Requisito de Divulgación de Código Fuente | Protección de Concesión de Patentes | Nivel de Riesgo para SaaS Comercial | Compromiso Operacional Clave (Trade-off) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Permissive** | MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0 | Ninguno (Se permite la distribución binaria sin código fuente) | Explícita en Apache-2.0; Silenciosa en MIT/BSD | **Bajo** | Máxima libertad; baja fricción legal; requiere mantener los avisos de atribución. |
| **Weak Copyleft** | LGPL-2.1, LGPL-3.0, MPL-2.0 | Obligatorio para modificaciones a la propia librería; el enlazado dinámico preserva la confidencialidad del código propietario | Explícita en LGPL-3.0 y MPL-2.0 | **Medio** | Seguro para enlazado dinámico; el riesgo surge si se enlaza estáticamente o se modifica el código fuente de la librería. |
| **Strong Copyleft** | GPL-2.0, GPL-3.0 | Obligatorio para cualquier obra derivada distribuida a terceros | Explícita en GPL-3.0 | **Alto** (si se distribuyen binarios) | Desencadena la divulgación del código fuente tras la distribución externa; bajo riesgo para SaaS puramente interno a menos que se entregue JS en el lado del cliente. |
| **Network Copyleft** | AGPL-3.0, SSPL | Obligatorio para obras derivadas a las que se accede a través de una red (servicio SaaS/Cloud) | Explícita | **CRÍTICO** | Interactuar con código AGPL mediante APIs de red obliga a divulgar todo el código fuente de la aplicación del lado del servidor. |

---

### 2.2 Motores de Aplicación de Políticas para Kubernetes y CI/CD

| Característica / Métrica | Open Policy Agent (OPA) Gatekeeper | Kyverno | ValidatingAdmissionPolicy Nativa |
| :--- | :--- | :--- | :--- |
| **Lenguaje de Políticas** | Rego (Declarativo, basado en consultas) | YAML nativo (CRDs de Kubernetes) | Common Expression Language (CEL) |
| **Curva de Aprendizaje** | Alta (Requiere aprender la sintaxis y estructura de Rego) | Baja (Patrones YAML estándares de K8s) | Moderada (Requiere aprender expresiones CEL) |
| **Búsqueda de Datos Externos** | Soportado mediante replicación de datos en caché o sidecars de Proveedores | Soportado mediante llamadas HTTP o ConfigMaps | Limitado (Evaluación in-tree, sensible al contexto) |
| **Capacidades de Auditoría** | Evaluación continua del estado del cluster mediante el estado de `Constraint` | Reportes de escaneo en segundo plano mediante `AdmissionReport` | Métricas in-tree y modos de ejecución dry-run |
| **Impacto en el Rendimiento** | Bajo a Medio (Evaluación del motor en Go) | Bajo a Medio (Evaluación del motor en Go) | **Extremadamente Bajo** (Evaluado directamente dentro de `kube-apiserver`) |

---

### 2.3 Estándares de Software Bill of Materials (SBOM)

| Métrica | SPDX (System Package Data Exchange - ISO/IEC 5921) | CycloneDX (Estándar OWASP) |
| :--- | :--- | :--- |
| **Enfoque Principal** | Cumplimiento de licencias de código abierto, seguimiento de copyright y procedencia | Cadena de suministro de ciberseguridad, análisis de vulnerabilidades, componentes (VEX) |
| **Organismo de Gobierno** | Linux Foundation | OWASP Foundation |
| **Formatos de Datos** | Tag/Value, JSON, YAML, TV, XML, RDF | JSON, XML, Protobuf |
| **Intercambio de Vulnerabilidades (VEX)** | Soportado mediante especificaciones de extensión | Integrado nativamente (perfil VEX BOM) |
| **Adopción en la Industria** | Preferido por el kernel de Linux, estándares ISO, software de sistemas | Preferido por SecOps, herramientas de seguridad para aplicaciones cloud-native |

---

## 3. Manifiestos Completos de Producción y Configuraciones de Infraestructura

### 3.1 Workflow de GitHub Actions: SBOM Automatizado, Auditoría de Licencias y Atestación con Sigstore

Este pipeline construye una imagen de contenedor, genera un SBOM SPDX completo utilizando `syft`, audita dependencias en busca de licencias no permitidas (GPL, AGPL) utilizando `trivy` y firma la imagen y el SBOM utilizando `cosign`.

```yaml
name: Production Security & Compliance Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build-compliance-check:
    name: Build, Audit License Compliance, and Sign Attestations
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Install Sigstore Cosign
        uses: sigstore/cosign-installer@v3.5.0

      - name: Install Anchore Syft
        uses: anchore/sbom-action/download-syft@v0.16.0

      - name: Install Aqua Security Trivy
        uses: aquasecurity/trivy-action@0.20.0

      - name: Build Container Image Locally
        uses: docker/build-push-action@v5
        with:
          context: .
          load: true
          tags: ghcr.io/enterprise/secure-api:1.4.0
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Generate SPDX SBOM JSON
        run: |
          syft ghcr.io/enterprise/secure-api:1.4.0 \
            -o spdx-json=sbom.spdx.json \
            --source-version 1.4.0

      - name: Audit Open Source Licenses with Trivy
        run: |
          trivy image \
            --severity HIGH,CRITICAL \
            --scanners license \
            --ignored-licenses Apache-2.0,MIT,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0 \
            --exit-code 1 \
            ghcr.io/enterprise/secure-api:1.4.0

      - name: Log in to GitHub Container Registry
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push Container Image
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          docker push ghcr.io/enterprise/secure-api:1.4.0

      - name: Sign Container Image (Keyless OIDC)
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          cosign sign --yes ghcr.io/enterprise/secure-api:1.4.0

      - name: Attach and Sign SBOM Attestation
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          cosign attest --yes \
            --type spdxjson \
            --predicate sbom.spdx.json \
            ghcr.io/enterprise/secure-api:1.4.0
```

---

### 3.2 Política de OPA Gatekeeper: Bloquear Imágenes de Contenedores Prohibidas y Forzar Registros Aprobados

#### 3.2.1 Definiciones de ConstraintTemplate (`k8sallowedregistries.yaml`)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
  annotations:
    metadata.gatekeeper.sh/title: "Allowed Container Registries"
    description: "Requires container images to originate from pre-approved enterprise registries."
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Container image '%v' is not from an approved registry. Allowed prefixes: %v", [container.image, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Init container image '%v' is not from an approved registry. Allowed prefixes: %v", [container.image, input.parameters.registries])
        }
```

#### 3.2.2 Constraint de Aplicación (`enforce-approved-registries.yaml`)

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: enforce-approved-registries
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
  parameters:
    registries:
      - "ghcr.io/enterprise/"
      - "765432109876.dkr.ecr.us-east-1.amazonaws.com/production/"
```

---

### 3.3 ClusterPolicy de Kyverno: Forzar Firmas de Imagen Obligatorias (Verificación con Cosign)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signatures
  annotations:
    policies.kyverno.io/title: Verify Cosign Attestations
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Verifies that container images running in production namespaces have been signed by 
      the enterprise GitHub Actions CI/CD identity.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature-github-oidc
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
      verifyImages:
        - imageReferences:
            - "ghcr.io/enterprise/*"
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main"
```

---

## 4. Comandos Reales de CLI y Secuencias de Salida de Terminal

### 4.1 Generación y Análisis de Datos SBOM SPDX con `syft`

**Comando:**
```bash
$ syft alpine:3.19.1 -o spdx-json
```

**Salida de Terminal Esperada:**
```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-06T19:22:10Z",
    "creators": [
      "Tool: syft-1.3.0",
      "Organization: Enterprise Platform Security"
    ],
    "licenseListVersion": "3.22"
  },
  "name": "alpine-3.19.1",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://anchore.com/syft/image/alpine-3.19.1-3965d1d6-c870-4217-b733-4fbd3540aef5",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-apk-tools-2.14.0-r5",
      "name": "apk-tools",
      "versionInfo": "2.14.0-r5",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "GPL-2.0-only",
      "licenseDeclared": "GPL-2.0-only",
      "supplier": "Organization: Alpine Linux",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:apk/alpine/apk-tools@2.14.0-r5?arch=x86_64&distro=alpine-3.19.1"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-musl-1.2.4_git20230717-r2",
      "name": "musl",
      "versionInfo": "1.2.4_git20230717-r2",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "supplier": "Organization: Alpine Linux"
    }
  ]
}
```

---

### 4.2 Escaneo de Imágenes de Contenedores en Busca de Licencias No Conformes con `trivy`

**Comando:**
```bash
$ trivy image \
    --scanners license \
    --severity CRITICAL,HIGH \
    --ignored-licenses Apache-2.0,MIT,BSD-3-Clause \
    ghcr.io/untrusted-vendor/analytics-engine:2.1.0
```

**Salida de Terminal Esperada:**
```text
2026-08-06T19:24:45.102-0400	INFO	Need to update license DB
2026-08-06T19:24:45.103-0400	INFO	Downloading license DB...
2026-08-06T19:24:47.332-0400	INFO	License DB update successfully finished
2026-08-06T19:24:48.012-0400	INFO	License scanning is enabled
2026-08-06T19:24:48.450-0400	INFO	Detected OS: alpine
2026-08-06T19:24:48.451-0400	INFO	Number of language-specific files: 1
2026-08-06T19:24:48.451-0400	INFO	Detecting Node.js packages licenses...

ghcr.io/untrusted-vendor/analytics-engine:2.1.0 (alpine 3.19.1)
===============================================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 1, CRITICAL: 1)

┌──────────────────────┬──────────────────┬──────────┬─────────────────┬──────────────────────────────────────────┐
│       Package        │     License      │ Severity │  Category       │ File Path                                │
├──────────────────────┼──────────────────┼──────────┼─────────────────┼──────────────────────────────────────────┤
│ gnu-ghostscript      │ AGPL-3.0-only    │ CRITICAL │ NetworkCopyleft │ usr/bin/gs                               │
│ web-scraper-module   │ GPL-3.0-or-later │ HIGH     │ StrongCopyleft  │ app/node_modules/web-scraper/package.json│
└──────────────────────┴──────────────────┴──────────┴─────────────────┴──────────────────────────────────────────┘

Error: license classification violation found. Exiting with code 1
```

---

### 4.3 Verificación de la Firma de Atestación de la Imagen con `cosign`

**Comando:**
```bash
$ cosign verify \
    --certificate-identity "https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/enterprise/secure-api:1.4.0
```

**Salida de Terminal Esperada:**
```text
Verification for ghcr.io/enterprise/secure-api:1.4.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims below were verified under issuer identity 'https://token.actions.githubusercontent.com' and subject 'https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main'
  - The signatures were verified against the Rekor transparency log
  - The certificates were verified against the Fulcio root CA

[{"critical":{"identity":{"docker-reference":"ghcr.io/enterprise/secure-api"},"image":{"docker-manifest-digest":"sha256:e839e4407da5a5d2e09c855a9b0c26569ec11894d01b1c676d08006e8efdfc02"},"type":"cosign container image signature"},"optional":{"Bundle":{"SignedEntryTimestamp":"MEUCIQDVf3K2X...==","Payload":{"body":"..."}}}}]
```

---

### 4.4 Prueba de la Aplicación del Control de Admisión de Kubernetes mediante `kubectl`

**Comando:**
```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: illegal-image-test
  namespace: production
spec:
  containers:
    - name: untrusted-app
      image: docker.io/library/nginx:latest
EOF
```

**Salida de Terminal Esperada:**
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validation.gatekeeper.sh" denied the request: [enforce-approved-registries] Container image 'docker.io/library/nginx:latest' is not from an approved registry. Allowed prefixes: ["ghcr.io/enterprise/", "765432109876.dkr.ecr.us-east-1.amazonaws.com/production/"]
```

---

## 5. Guía de Verificación, Diagnóstico y Solución de Fallos

### 5.1 Workflow de Solución de Problemas: Fallo en el Control de Admisión de Kubernetes

Cuando los despliegues de contenedores fallan durante el envío a la API de Kubernetes debido a webhooks de políticas, siga esta matriz diagnóstica estructurada:

```
                      +------------------------------------------+
                      | Pod Admission Denied (HTTP 403 Forbidden) |
                      +------------------------------------------+
                                           |
                                           v
                     +-------------------------------------------+
                     | Inspect API error message from `kubectl`  |
                     +-------------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
                    v                                             v
  [Gatekeeper Policy Violation]                   [Webhook Timeout / Connection Refused]
                    |                                             |
                    v                                             v
  1. Check Constraint status:                     1. Inspect Gatekeeper Pod status:
     `kubectl describe k8sallowedregistries`         `kubectl get pods -n gatekeeper-system`
  2. Inspect Audit Logs:                          2. Check Webhook Configuration:
     `kubectl logs -n gatekeeper-system -l ...`      `kubectl describe validatingwebhookconfigurations`
  3. Validate Rego input payloads                 3. Verify APIServer -> Webhook Latency (<500ms)
```

---

### 5.2 Modos de Fallo Comunes en Producción y Remediación

#### Modo de Fallo 1: Falsos Positivos en la Identificación de Paquetes con Licencia Doble (Dual-Licensed)
- **Síntoma:** El pipeline de CI/CD falla durante el escaneo de `trivy` o `fossa` en paquetes con licencia doble bajo `(MIT OR GPL-2.0)`. El escáner marca el paquete como de alto riesgo debido a la presencia de `GPL-2.0`.
- **Causa Raíz:** Coincidencia ingenua con expresiones regulares (regex) en el motor del escáner que evalúa ambos términos de licencia en lugar de aplicar las reglas estándar de expresión disyuntiva de SPDX (lógica `OR`).
- **Remediación:** Configurar `--ignored-licenses` o un archivo `.trivyignore` explícito declarando las rutas de licencias elegidas:
  ```yaml
  # .trivyignore
  # Dual-licensed package choice: Explicitly choosing MIT over GPL-2.0
  licenses:
    - id: "GPL-2.0-only"
      package: "node-glob"
      statement: "Dual licensed under MIT OR GPL-2.0. Organization elects MIT."
  ```

#### Modo de Fallo 2: Picos de Latencia en el Webhook de Gatekeeper Causal de Timeouts en el API Server
- **Síntoma:** Los deployments de Kubernetes se bloquean y `kubectl` lanza `Internal error occurred: failed calling webhook "validation.gatekeeper.sh": deadline exceeded`.
- **Causa Raíz:** Inanición de CPU (CPU starvation) en el Pod de Gatekeeper o un caché de datos de OPA excesivamente grande (recursos de K8s replicados) que provoca que los tiempos de evaluación de la ejecución de Rego excedan los umbrales de timeout de `failurePolicy: Fail` (típicamente entre 5 y 10 segundos).
- **Comandos de Diagnóstico:**
  ```bash
  # Check Gatekeeper controller-manager resource consumption
  $ kubectl top pods -n gatekeeper-system

  # Filter logs for webhook evaluation latency > 500ms
  $ kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=1000 \
    | jq 'select(.event_type == "rego" and .latency_ms > 500)'
  ```
- **Remediación:** Incrementar las solicitudes/límites (requests/limits) de CPU para el deployment `gatekeeper-controller-manager` y excluir namespaces del sistema transitorios (ej. `kube-system`) del alcance de evaluación del webhook utilizando `namespaceSelector`.

#### Modo de Fallo 3: Identidad de Certificado OIDC Faltante durante la Verificación Keyless con Cosign
- **Síntoma:** `cosign verify` falla en el webhook de admisión del cluster de producción con `error: no matching signatures found`.
- **Causa Raíz:** El pipeline de CI/CD se ejecuta en un commit de git desencadenado por un pull request desde un fork o una rama desligada (detached branch), produciendo una identidad `subject` OIDC diferente a la esperada por la política de verificación de producción.
- **Comandos de Diagnóstico:**
  ```bash
  # Dump exact OIDC subject embedded inside the image signature bundle
  $ cosign download signature ghcr.io/enterprise/secure-api:1.4.0 \
    | jq -r '.critical.identity'
  ```
- **Remediación:** Asegurar que los trabajos de GitHub Actions establezcan permisos explícitos `id-token: write` y coincidan con la ruta de referencia (ref path) exacta del workflow en la política de control de admisión.

---

## 6. Referencias

- **Visión General de Linux Professional Institute (LPI) Open Source Essentials:**  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
- **Especificación SPDX (System Package Data Exchange) de la Linux Foundation:**  
  https://spdx.dev/
- **Estándar Software Bill of Materials CycloneDX de OWASP:**  
  https://cyclonedx.org/
- **Documentación de OPA Gatekeeper de la CNCF:**  
  https://open-policy-agent.github.io/gatekeeper/
- **Motor de Políticas Kyverno para Kubernetes de la CNCF:**  
  https://kyverno.io/
- **Firma de Imágenes Keyless y Atestación con Sigstore Cosign de la CNCF:**  
  https://www.sigstore.dev/
- **Definiciones Oficiales de Licencias de la Open Source Initiative (OSI):**  
  https://opensource.org/licenses