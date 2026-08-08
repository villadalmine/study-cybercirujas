# Tema 3.5: Integrating Security Scanning and Compliance Checks into Deployment Pipelines

> **Dominio:** Security & Compliance en Platform Engineering · **Peso en el examen:** 3
> **Perfil:** Este material asume que ya operás pipelines de despliegue (Tekton, Argo Workflows, GitHub Actions o GitLab CI) y un cluster Kubernetes con admission control. El foco es *cómo el platform engineer construye el golden path que hace obligatorio el escaneo de seguridad y la verificación de compliance sin frenar al equipo de producto*.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Qué falla cuando la seguridad vive fuera del pipeline

El modelo clásico "gate de seguridad al final" (un pentest trimestral, un scan manual antes de la release) tiene tres fallas estructurales que un Platform Engineer debe resolver de raíz:

1. **Latencia de feedback.** Una vulnerabilidad detectada seis semanas después de mergear cuesta órdenes de magnitud más que una detectada en el `pull request`. El costo no es solo dinero: es *contexto perdido*. El autor ya no recuerda el código.
2. **No es determinista ni reproducible.** Un scan manual no versiona su configuración, su base de datos de vulnerabilidades ni su umbral de decisión. Dos releases del mismo artefacto pueden dar veredictos distintos y nadie puede explicar por qué.
3. **No cubre la supply chain.** El 80–90% de una imagen de contenedor moderna es código de terceros (base image, librerías transitivas). Los ataques de cadena de suministro reales —SolarWinds (2020), Codecov (2021), la explotación masiva de **Log4Shell** (CVE-2021-44228), la puerta trasera en **xz-utils** (CVE-2024-3094)— no atacan *tu* código: atacan lo que *heredás*.

El principio rector es **shift-left**: mover cada control al punto más temprano donde sea *decidible*. Pero shift-left sin **shift-right** (verificación en admisión y en runtime) es incompleto: un artefacto puede pasar todos los gates y aun así desplegarse una imagen distinta a la escaneada. La arquitectura correcta es **defensa en profundidad a lo largo del ciclo de vida del artefacto**.

### 1.2 El ciclo de vida del artefacto y sus puntos de control

```
  commit ──► build ──► scan ──► sign ──► push ──► admission ──► runtime
    │          │         │        │        │          │            │
  gitleaks   SAST      SCA +    cosign   registry   Kyverno /    Falco
  (secrets)  (Semgrep) image    + SBOM   (Harbor)   Gatekeeper   (behavior)
             IaC scan  scan     attest              verifica     detecta
             (Checkov) (Trivy)  (SLSA)              firma+policy  runtime
```

Cada flecha es una **transición de confianza**. La pregunta arquitectónica central de este tema es: **¿dónde pongo cada control, y qué controles son *blocking* (rompen el build) versus *advisory* (informan pero no frenan)?**

### 1.3 El problema del gate: blocking vs. advisory vs. break-glass

La tensión de producción es *developer velocity* contra *security posture*. Un gate demasiado estricto genera:

- **Alert fatigue** y bypass masivo (todos aprenden el flag `--skip-security`).
- **Bloqueo por CVEs sin fix disponible** (no podés arreglar lo que upstream no parcheó).
- **Falsos positivos** que erosionan la confianza en el sistema entero.

La respuesta madura no es "todo bloquea" ni "todo informa", sino una **matriz de política graduada**:

| Control | Etapa | Severidad que bloquea | Justificación |
|---|---|---|---|
| Secret scanning | pre-commit + CI | Cualquier secreto detectado | Un secreto commiteado ya está comprometido; rotación obligatoria |
| SCA / dependencias | PR | `CRITICAL` con fix disponible | Bloquear sin fix solo genera deuda de excepciones |
| Image scan | build | `CRITICAL`/`HIGH` con fix, no en `.trivyignore` con VEX | Base image parcheable |
| IaC misconfig | PR | Reglas de política de seguridad "high" | Deriva de configuración es prevenible |
| SLSA provenance | admission | Firma ausente o no verificable | Sin firma no hay cadena de custodia |
| Runtime policy | admission | Violación de baseline (Pod Security) | Última línea antes de exponer |

El **break-glass** (mecanismo de excepción auditado) es obligatorio: toda política que bloquea debe tener una vía de excepción *versionada, con vencimiento y con owner*, nunca un flag silencioso. Lo veremos con VEX y con `PolicyException` de Kyverno.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Familias de análisis: qué detecta cada una

| Familia | Qué analiza | Momento | No detecta |
|---|---|---|---|
| **SAST** (Static Application Security Testing) | Código fuente propio: inyección, path traversal, uso inseguro de crypto | pre-build | Vulnerabilidades en dependencias; problemas de runtime |
| **SCA** (Software Composition Analysis) | Dependencias declaradas y transitivas contra bases de CVE/advisories | PR/build | Bugs en tu propio código |
| **Image / container scan** | Paquetes del OS + libs dentro de la imagen final | post-build | Lógica de la app |
| **IaC scanning** | Terraform, CloudFormation, manifiestos K8s, Dockerfile | PR | Estado real desplegado (drift) |
| **Secret scanning** | Credenciales embebidas en el árbol git y en la historia | pre-commit/CI | Secretos inyectados en runtime |
| **DAST** (Dynamic) | App corriendo, caja negra | staging | Requiere entorno vivo; lento |

Un platform golden path maduro compone **SCA + image scan + IaC + secrets** como mínimo obligatorio, y ofrece SAST/DAST como capacidades opt-in por criticidad del servicio.

### 2.2 Escáneres de imágenes y filesystem: Trivy vs. Grype vs. Clair vs. Snyk

| Criterio | **Trivy** (Aqua) | **Grype** (Anchore) | **Clair** (Quay) | **Snyk** |
|---|---|---|---|---|
| Modelo | Binario único, self-contained | Binario, pareado con Syft (SBOM) | Servicio (API + DB), arquitectura pull | SaaS/CLI, comercial |
| Cobertura | OS pkgs + lang deps + IaC + secrets + licencias | OS pkgs + lang deps | OS pkgs (foco registry) | Deps + código + IaC |
| SBOM | Genera y consume (CycloneDX/SPDX) | Consume Syft SBOM | Limitado | Sí |
| Modo air-gapped | `trivy --offline-scan` + DB mirror | DB descargable | Nativo (self-hosted) | Requiere conectividad |
| Integración registry | Harbor lo embebe | Harbor (pluggable) | Quay nativo | Propio |
| Licencia | Apache 2.0 | Apache 2.0 | Apache 2.0 | Comercial |
| Fortaleza | "Navaja suiza" one-stop | SBOM-first, arquitectura limpia | Escalable como servicio | Prioritización + fix advice |

**Recomendación de plataforma:** Trivy como default en el pipeline por su cobertura amplia y cero infra; Harbor+Trivy o Harbor+Clair como escaneo continuo en el registry (detecta CVEs que aparecen *después* del push). Grype+Syft cuando el requisito primario es SBOM canónico y separación de responsabilidades scan/SBOM.

### 2.3 IaC / misconfiguration scanning: Checkov vs. tfsec vs. KICS vs. Trivy-config

| Criterio | **Checkov** (Prisma) | **tfsec** (→ Trivy) | **KICS** (Checkmarx) | **Trivy config** |
|---|---|---|---|---|
| Lenguajes | TF, CFN, K8s, Helm, ARM, Dockerfile | Terraform (fusionándose en Trivy) | TF, K8s, Docker, Ansible, CFN, Helm | TF, K8s, Docker, Helm |
| Custom policy | Python + YAML | Rego/JSON | Rego-like | Rego (via Trivy) |
| Graph de recursos | Sí (evalúa relaciones) | Parcial | No | No |
| Estado | Muy activo | En deprecación → Trivy | Activo | Activo |

**Nota de plataforma:** `tfsec` está siendo absorbido por Trivy; para greenfield preferí **Trivy config** o **Checkov**. Checkov gana cuando necesitás evaluación *graph-aware* (p. ej., "este SG permite 0.0.0.0/0 *y* está adjunto a una instancia pública").

### 2.4 Policy-as-code: Conftest/OPA vs. Kyverno vs. Gatekeeper

Este es el trade-off más importante del tema porque define **dónde** se aplica la política.

| Criterio | **Conftest (OPA)** en pipeline | **Kyverno** en admisión | **OPA Gatekeeper** en admisión |
|---|---|---|---|
| Lenguaje de política | Rego | YAML (declarativo) | Rego (via ConstraintTemplate) |
| Dónde corre | CI/CD (shift-left) | Admission webhook (cluster) | Admission webhook (cluster) |
| Curva de aprendizaje | Alta (Rego) | Baja (K8s-native) | Alta (Rego + CRDs) |
| Mutación de recursos | No | Sí (mutate) | No (solo valida) |
| Generación de recursos | No | Sí (generate) | No |
| Fuera de K8s | Sí (cualquier JSON/YAML) | No (solo K8s) | No |
| Verificación de imágenes | No nativo | Sí (`verifyImages`, cosign) | Vía external data |

**Patrón de plataforma correcto:** **los dos, no uno.** Conftest/OPA valida en el pipeline (feedback rápido, corta antes de gastar recursos de cluster). Kyverno o Gatekeeper **re-valida en admisión** porque *el pipeline no es un límite de confianza*: alguien puede `kubectl apply` directo saltándose CI. La política de admisión es el enforcement real; el pipeline es UX de feedback temprano. Kyverno tiende a ganar en plataformas nuevas por ser declarativo y soportar `verifyImages` (firma cosign) nativamente.

### 2.5 SBOM y firma: la cadena SLSA

- **SBOM** (Software Bill of Materials): inventario de todo lo que compone el artefacto. Formatos: **SPDX** (Linux Foundation, ISO/IEC 5962) y **CycloneDX** (OWASP). Generado con **Syft** o `trivy sbom`.
- **Firma y attestation**: **Sigstore/cosign** firma la imagen y adjunta *attestations* (SBOM, provenance SLSA, resultado del scan) como objetos co-localizados en el registry, verificables sin gestión de claves gracias a **keyless signing** (OIDC + Fulcio + Rekor transparency log).
- **SLSA** (Supply-chain Levels for Software Artifacts): framework de niveles (L1–L3+) que exige *provenance* verificable — quién construyó el artefacto, con qué fuente, en qué builder. L3 exige builder aislado y provenance no falsificable.

---

## 3. Manifiestos e infraestructura completos

### 3.1 Configuración de Trivy: `trivy.yaml` y política de ignore con VEX

`.trivy.yaml` (config del escáner, versionada en el repo):

```yaml
# .trivy.yaml — configuración central del escaneo, versionada con el código
severity:
  - CRITICAL
  - HIGH
scan:
  security-checks:
    - vuln
    - secret
    - misconfig
    - license
  offline-scan: false          # true en entornos air-gapped con DB mirror
vulnerability:
  ignore-unfixed: true         # no bloquear por CVEs sin parche disponible
  type:
    - os
    - library
misconfiguration:
  include-non-failures: false
exit-code: 1                   # 0 hallazgos => salida 0; cualquier hallazgo => 1
timeout: 10m
db:
  repository: ghcr.io/aquasecurity/trivy-db
cache:
  dir: /tmp/.trivycache
```

`.trivyignore` — excepciones auditables (nunca silenciosas):

```
# .trivyignore — cada línea DEBE llevar owner y fecha de revisión
# CVE-2023-45853 zlib — no explotable: no exponemos MiniZip. Rev: 2026-09-01 @sre-team
CVE-2023-45853
# CVE-2024-6119 openssl — fixed en base image next sprint. Rev: 2026-08-20 @platform
CVE-2024-6119
```

**VEX (Vulnerability Exploitability eXchange)** — la forma moderna, machine-readable, de decir "presente pero no explotable" (`openvex.json`):

```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://example.com/vex/teach-plat-api-2026-08-07",
  "author": "Platform Security Team <security@example.com>",
  "timestamp": "2026-08-07T10:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2023-45853" },
      "products": [
        { "@id": "pkg:oci/teach-plat-api@sha256:9f2a...c1" }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path",
      "impact_statement": "MiniZip no se compila en el binario final; código muerto."
    }
  ]
}
```

Se consume con `trivy image --vex openvex.json ...`, y a diferencia de `.trivyignore` es *portable* entre escáneres y auditable por terceros.

### 3.2 Políticas OPA/Rego para Conftest (shift-left en el pipeline)

`policy/kubernetes.rego` — valida manifiestos antes de aplicarlos:

```rego
package main

import future.keywords.in
import future.keywords.contains
import future.keywords.if

# --- Deny: contenedores sin límites de recursos ---
deny contains msg if {
	input.kind == "Deployment"
	some container in input.spec.template.spec.containers
	not container.resources.limits.memory
	msg := sprintf("[CRITICAL] container '%s' no declara resources.limits.memory", [container.name])
}

# --- Deny: privilege escalation ---
deny contains msg if {
	input.kind == "Deployment"
	some container in input.spec.template.spec.containers
	container.securityContext.allowPrivilegeEscalation != false
	msg := sprintf("[CRITICAL] container '%s' permite privilege escalation", [container.name])
}

# --- Deny: correr como root ---
deny contains msg if {
	input.kind == "Deployment"
	not input.spec.template.spec.securityContext.runAsNonRoot == true
	msg := "[HIGH] el pod no fuerza runAsNonRoot=true"
}

# --- Deny: imagen con tag mutable :latest ---
deny contains msg if {
	input.kind == "Deployment"
	some container in input.spec.template.spec.containers
	endswith(container.image, ":latest")
	msg := sprintf("[HIGH] container '%s' usa tag mutable ':latest'; usá digest o tag inmutable", [container.name])
}

# --- Warn: sin readOnlyRootFilesystem ---
warn contains msg if {
	input.kind == "Deployment"
	some container in input.spec.template.spec.containers
	not container.securityContext.readOnlyRootFilesystem == true
	msg := sprintf("[MEDIUM] container '%s' sin readOnlyRootFilesystem", [container.name])
}
```

Test unitario de la política (`policy/kubernetes_test.rego`) — **las políticas también se testean**:

```rego
package main

import future.keywords.if

test_deny_latest_tag if {
	deny with input as {
		"kind": "Deployment",
		"spec": {"template": {"spec": {"containers": [
			{"name": "api", "image": "registry.example.com/api:latest"},
		]}}},
	}
}

test_allow_pinned_digest if {
	count(deny) == 0 with input as {
		"kind": "Deployment",
		"spec": {"template": {"spec": {
			"securityContext": {"runAsNonRoot": true},
			"containers": [{
				"name": "api",
				"image": "registry.example.com/api@sha256:abc123",
				"securityContext": {"allowPrivilegeEscalation": false},
				"resources": {"limits": {"memory": "256Mi"}},
			}],
		}}},
	}
}
```

### 3.3 Pipeline Tekton completo con scanning y firma

`tekton/pipeline-secure-build.yaml` — pipeline de plataforma que encadena build → SBOM → scan → firma → gate de política:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: secure-supply-chain
  namespace: platform-ci
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
    - name: image-ref
      type: string
      description: registry.example.com/app (sin tag)
  workspaces:
    - name: shared
    - name: cosign-keys
    - name: dockerconfig
  results:
    - name: image-digest
      value: $(tasks.build.results.IMAGE_DIGEST)
  tasks:
    # 1. Clonar
    - name: clone
      taskRef: { name: git-clone }
      params:
        - name: url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)
      workspaces:
        - name: output
          workspace: shared

    # 2. Secret scanning — corta si hay credenciales
    - name: secret-scan
      runAfter: [clone]
      taskSpec:
        workspaces:
          - name: source
        steps:
          - name: gitleaks
            image: zricethezav/gitleaks:v8.18.4
            workingDir: $(workspaces.source.path)
            script: |
              #!/bin/sh
              set -e
              gitleaks detect --source . --redact --exit-code 1 \
                --report-format sarif --report-path gitleaks.sarif
      workspaces:
        - name: source
          workspace: shared

    # 3. IaC / misconfig sobre manifiestos y Dockerfile
    - name: iac-scan
      runAfter: [clone]
      taskSpec:
        workspaces:
          - name: source
        steps:
          - name: trivy-config
            image: aquasec/trivy:0.55.0
            workingDir: $(workspaces.source.path)
            script: |
              #!/bin/sh
              set -e
              trivy config --config .trivy.yaml \
                --exit-code 1 --severity CRITICAL,HIGH .
      workspaces:
        - name: source
          workspace: shared

    # 4. Build (Kaniko) — produce digest inmutable
    - name: build
      runAfter: [secret-scan, iac-scan]
      taskRef: { name: kaniko }
      params:
        - name: IMAGE
          value: $(params.image-ref):$(params.revision)
      workspaces:
        - name: source
          workspace: shared
        - name: dockerconfig
          workspace: dockerconfig

    # 5. SBOM (Syft) como attestation
    - name: sbom
      runAfter: [build]
      taskSpec:
        params:
          - name: image
        steps:
          - name: syft
            image: anchore/syft:v1.11.0
            script: |
              #!/bin/sh
              set -e
              syft "$(params.image)@$(tasks.build.results.IMAGE_DIGEST)" \
                -o cyclonedx-json=/workspace/shared/sbom.cdx.json
      params:
        - name: image
          value: $(params.image-ref)

    # 6. Image vuln scan — GATE de severidad
    - name: image-scan
      runAfter: [build]
      taskSpec:
        params:
          - name: image
        steps:
          - name: trivy
            image: aquasec/trivy:0.55.0
            script: |
              #!/bin/sh
              set -e
              trivy image \
                --exit-code 1 \
                --severity CRITICAL,HIGH \
                --ignore-unfixed \
                --vex /workspace/shared/openvex.json \
                --format sarif --output /workspace/shared/trivy.sarif \
                "$(params.image)@$(tasks.build.results.IMAGE_DIGEST)"
      params:
        - name: image
          value: $(params.image-ref)

    # 7. Firma keyless + attestation (cosign) — solo si el scan pasó
    - name: sign
      runAfter: [image-scan, sbom]
      taskSpec:
        params:
          - name: image
        workspaces:
          - name: cosign-keys
        steps:
          - name: cosign-sign
            image: gcr.io/projectsigstore/cosign:v2.4.0
            env:
              - name: COSIGN_EXPERIMENTAL
                value: "1"
            script: |
              #!/bin/sh
              set -e
              REF="$(params.image)@$(tasks.build.results.IMAGE_DIGEST)"
              cosign sign --yes "$REF"
              cosign attest --yes --type cyclonedx \
                --predicate /workspace/shared/sbom.cdx.json "$REF"
      params:
        - name: image
          value: $(params.image-ref)
      workspaces:
        - name: cosign-keys
          workspace: cosign-keys
```

### 3.4 GitHub Actions equivalente (para golden path multi-plataforma)

`.github/workflows/secure-release.yaml`:

```yaml
name: secure-release
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write   # OIDC para cosign keyless — imprescindible

jobs:
  build-scan-sign:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Secret scan
        uses: gitleaks/gitleaks-action@v2
        env:
          GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}

      - name: IaC misconfig scan
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: deploy/
          framework: kubernetes
          soft_fail: false        # rompe el build ante hallazgos "high"

      - name: Build image
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          # digest se expone en steps.build.outputs.digest

      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          image: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
          format: cyclonedx-json
          output-file: sbom.cdx.json

      - name: Vulnerability scan (gate)
        uses: aquasecurity/trivy-action@0.24.0
        with:
          image-ref: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          exit-code: '1'          # rompe el job si hay hallazgos bloqueantes
          format: sarif
          output: trivy.sarif

      - name: Upload SARIF a code scanning
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy.sarif

      - name: Install cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign + attest (keyless)
        run: |
          IMG="ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}"
          cosign sign --yes "$IMG"
          cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$IMG"
```

### 3.5 Kyverno: enforcement en admisión (el límite de confianza real)

`kyverno/verify-images.yaml` — **rechaza cualquier imagen no firmada por nuestro pipeline**:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
  annotations:
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce   # Enforce = bloquea; Audit = solo reporta
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false
  rules:
    - name: verify-signature-keyless
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "registry.example.com/*"
          mutateDigest: true          # reescribe tag → digest inmutable
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

`kyverno/require-hardening.yaml` — baseline de compliance (subconjunto Pod Security "restricted"):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pod-hardening
spec:
  validationFailureAction: Enforce
  rules:
    - name: disallow-privileged
      match:
        any:
          - resources: { kinds: [Pod] }
      validate:
        message: "Privileged containers no están permitidos."
        pattern:
          spec:
            =(securityContext):
              =(runAsNonRoot): "true"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  =(allowPrivilegeEscalation): "false"
    - name: require-ro-rootfs
      match:
        any:
          - resources: { kinds: [Pod] }
      validate:
        message: "readOnlyRootFilesystem debe ser true."
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true
```

`kyverno/exception.yaml` — el **break-glass auditable** (excepción con scope acotado):

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: legacy-nginx-rootfs-exception
  namespace: legacy-apps
  annotations:
    owner: platform-team@example.com
    expires: "2026-10-01"
    ticket: SEC-1421
spec:
  exceptions:
    - policyName: require-pod-hardening
      ruleNames: [require-ro-rootfs]
  match:
    any:
      - resources:
          kinds: [Pod]
          namespaces: [legacy-apps]
          names: ["legacy-nginx-*"]
```

### 3.6 Trivy Operator: escaneo continuo dentro del cluster (shift-right)

El pipeline escanea *una vez*, en build. Pero aparecen CVEs *nuevos* para imágenes ya desplegadas. El **Trivy Operator** re-escanea continuamente y expone los resultados como CRDs:

```yaml
# values.yaml para helm install trivy-operator aquasecurity/trivy-operator
operator:
  scannerReportTTL: "24h"
  vulnerabilityScannerScanOnlyCurrentRevisions: true
  metricsVulnIdEnabled: true          # exporta CVE-id como métrica Prometheus
trivy:
  ignoreUnfixed: true
  severity: "CRITICAL,HIGH"
  slow: false
  resources:
    requests: { cpu: 100m, memory: 100M }
    limits:   { cpu: 500m, memory: 500M }
compliance:
  specs:
    - k8s-cis-1.23         # CIS Kubernetes Benchmark
    - k8s-nsa-1.0          # NSA/CISA hardening guide
    - k8s-pss-restricted-0.1
```

---

## 4. Comandos CLI y salidas reales de terminal

### 4.1 Escaneo de imagen con gate de severidad

```console
$ trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 \
    registry.example.com/teach-plat-api:1.4.2
2026-08-07T10:14:03Z INFO  Vulnerability scanning is enabled
2026-08-07T10:14:03Z INFO  Detected OS: debian (version 12.6)
2026-08-07T10:14:05Z INFO  Number of language-specific files num=2

teach-plat-api:1.4.2 (debian 12.6)
==================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌────────────┬───────────────┬──────────┬────────┬───────────────┬───────────────┬─────────────────────────────┐
│  Library   │ Vulnerability │ Severity │ Status │ Installed Ver │  Fixed Ver    │            Title            │
├────────────┼───────────────┼──────────┼────────┼───────────────┼───────────────┼─────────────────────────────┤
│ libssl3    │ CVE-2024-6119 │ HIGH     │ fixed  │ 3.0.13-1      │ 3.0.14-1      │ openssl: denial of service  │
│ zlib1g     │ CVE-2023-45853│ CRITICAL │ fixed  │ 1:1.2.13.dfsg │ 1:1.2.13-1.1  │ zlib: integer overflow      │
└────────────┴───────────────┴──────────┴────────┴───────────────┴───────────────┴─────────────────────────────┘

$ echo $?
1
```

El `exit-code 1` es lo que hace **fallar el job de CI**. Sin él, Trivy imprime y devuelve 0 (modo advisory).

### 4.2 Suprimir un falso positivo con VEX y re-escanear

```console
$ trivy image --severity CRITICAL,HIGH --ignore-unfixed \
    --vex openvex.json --exit-code 1 \
    registry.example.com/teach-plat-api:1.4.2
...
teach-plat-api:1.4.2 (debian 12.6)
Total: 1 (HIGH: 1, CRITICAL: 0)
   ↑ CVE-2023-45853 suprimido por VEX (status: not_affected)

$ echo $?
1     # sigue fallando por el HIGH de openssl — correcto, ese tiene fix
```

### 4.3 SBOM: generar, versionar, diffear

```console
$ syft registry.example.com/teach-plat-api:1.4.2 -o cyclonedx-json=sbom-1.4.2.json
 ✔ Parsed image        sha256:9f2a...c1
 ✔ Cataloged contents
   ├── ✔ Packages     [312 packages]
   └── ✔ File digests [1.2k files]

$ syft registry.example.com/teach-plat-api:1.4.3 -o cyclonedx-json=sbom-1.4.3.json

$ syft diff sbom-1.4.2.json sbom-1.4.3.json 2>/dev/null || \
    diff <(jq -r '.components[].purl' sbom-1.4.2.json | sort) \
         <(jq -r '.components[].purl' sbom-1.4.3.json | sort)
< pkg:deb/debian/libssl3@3.0.13-1
> pkg:deb/debian/libssl3@3.0.14-1
> pkg:deb/debian/zlib1g@1:1.2.13-1.1
```

El **diff de SBOM entre releases** es la herramienta forense clave: responde "¿qué cambió en mi supply chain?" sin recompilar.

### 4.4 Firma keyless y verificación

```console
$ COSIGN_EXPERIMENTAL=1 cosign sign --yes \
    registry.example.com/teach-plat-api@sha256:9f2a...c1
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully verified SCT...
tlog entry created with index: 84213709
Pushing signature to: registry.example.com/teach-plat-api

$ cosign verify \
    --certificate-identity-regexp "https://github.com/example/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/teach-plat-api@sha256:9f2a...c1

Verification for registry.example.com/teach-plat-api@sha256:9f2a...c1 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority
[{"critical":{"identity":{"docker-reference":"registry.example.com/teach-plat-api"},
  "image":{"docker-manifest-digest":"sha256:9f2a...c1"},"type":"cosign container image signature"}}]
```

### 4.5 Verificar la attestation SBOM adjunta

```console
$ cosign verify-attestation --type cyclonedx \
    --certificate-identity-regexp "https://github.com/example/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/teach-plat-api@sha256:9f2a...c1 \
    | jq '.payload | @base64d | fromjson | .predicate.Data' -r | jq '.metadata.component.name'
"teach-plat-api"
```

### 4.6 Compliance del cluster: kube-bench (CIS) y kubescape (NSA)

```console
$ kubectl run kube-bench --rm -it --restart=Never \
    --image=aquasec/kube-bench:latest -- run --targets node
[INFO] 4 Worker Node Security Configuration
[PASS] 4.1.1 Ensure that the kubelet service file permissions are 600 or more restrictive
[FAIL] 4.2.6 Ensure that the --protect-kernel-defaults argument is set to true
[WARN] 4.2.9 Ensure that the --event-qps argument is set to 0 or a level which ensures...

== Summary node ==
21 checks PASS
1 checks FAIL
2 checks WARN

$ kubescape scan framework nsa --format json --output nsa-report.json
[info] Scanning cluster against framework: nsa
[info] Control: C-0057 Privileged container ............... FAILED (3 resources)
[info] Control: C-0016 Allow privilege escalation ......... FAILED (2 resources)

  Framework scanned: NSA
  Controls: 24 (Failed: 6, Passed: 15, Skipped: 3)
  Compliance score: 68.42%
```

### 4.7 Validar política shift-left con Conftest

```console
$ conftest test --policy policy/ deploy/deployment.yaml
FAIL - deploy/deployment.yaml - main - [HIGH] container 'api' usa tag mutable ':latest'
FAIL - deploy/deployment.yaml - main - [CRITICAL] container 'api' no declara resources.limits.memory
WARN - deploy/deployment.yaml - main - [MEDIUM] container 'api' sin readOnlyRootFilesystem

3 tests, 0 passed, 1 warning, 2 failures

$ echo $?
1
```

Y el **test de la política en sí** (verificás que tu Rego hace lo que creés):

```console
$ opa test policy/ -v
policy/kubernetes_test.rego:
data.main.test_deny_latest_tag: PASS (1.2ms)
data.main.test_allow_pinned_digest: PASS (0.9ms)
--------------------------------------------------
PASS: 2/2
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 "El scan pasó en CI pero Kyverno rechaza el Pod en el cluster"

Síntoma:

```console
$ kubectl apply -f deploy/deployment.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource Deployment/default/teach-plat-api was blocked due to the following policies:
  verify-image-signatures:
    verify-signature-keyless: 'failed to verify image registry.example.com/teach-plat-api:1.4.2:
    no matching signatures'
```

**Diagnóstico paso a paso:**

1. ¿La imagen está firmada?
   ```console
   $ cosign tree registry.example.com/teach-plat-api:1.4.2
   📦 Supply Chain Security Related artifacts
   └── (no signatures found)     ← causa raíz
   ```
2. Causa típica: el pipeline firmó por **digest** pero el Deployment referencia por **tag**, y el tag fue reescrito por otro push. Kyverno con `mutateDigest: true` lo resuelve, pero si la policy corre en modo `Audit` no mutó. **Verificá el modo:**
   ```console
   $ kubectl get clusterpolicy verify-image-signatures -o jsonpath='{.spec.validationFailureAction}'
   Enforce
   ```
3. Verificá que el issuer/subject de la policy coincide con el del pipeline real:
   ```console
   $ cosign verify --certificate-identity-regexp ... registry.example.com/teach-plat-api:1.4.2
   Error: no matching signatures: none of the expected identities matched what was in the certificate
   ```
   Esto significa que el `subject`/`issuer` en la `ClusterPolicy` no coincide con quién firmó (ej.: firmaste desde GitLab pero la policy espera GitHub OIDC). **Corregí el `issuer` en la policy, no relajes la verificación.**

### 5.2 "El pipeline se rompe por un CVE que no puedo arreglar"

Árbol de decisión:

```
CVE bloqueante detectado
        │
        ├─ ¿Hay fixed version upstream?
        │       ├─ Sí → bump de dependencia / base image. FIN.
        │       └─ No → ¿es explotable en NUESTRO contexto?
        │                    ├─ Sí → no desplegar; mitigación compensatoria (NetPol, WAF)
        │                    └─ No → emitir statement VEX "not_affected" con justificación
        │                            + owner + fecha de revisión. Re-escanear con --vex.
        └─ ¿ignore-unfixed activo? → los sin-fix ya no bloquean (evita deuda de excepciones)
```

**Anti-patrón a evitar:** agregar el CVE a `.trivyignore` sin owner ni fecha. Toda supresión debe ser auditable y caducar. VEX es preferible porque es machine-readable y portable entre escáneres.

### 5.3 "Los resultados divergen entre el scan de CI y el registry (Harbor)"

Causa casi siempre: **desfase de la base de datos de vulnerabilidades**. La NVD/advisories se actualizan continuamente; un CVE publicado *entre* el scan de CI y el del registry aparece solo en el segundo.

```console
$ trivy image --download-db-only
2026-08-07T10:40:12Z INFO  Downloading vulnerability DB
2026-08-07T10:40:15Z INFO  Vulnerability DB updated  UpdatedAt=2026-08-07T06:00:00Z
```

**Verificá la fecha de la DB en ambos lados.** El scan de CI no es la última palabra: por eso el Trivy Operator re-escanea en runtime. Un artefacto "limpio en build" puede volverse vulnerable sin recompilarse — este es exactamente el gap que cierra el shift-right.

Consultar el estado de vulnerabilidades vivas en el cluster:

```console
$ kubectl get vulnerabilityreports -A \
    -o custom-columns='NS:.metadata.namespace,POD:.metadata.labels.trivy-operator\.resource\.name,CRIT:.report.summary.criticalCount'
NS         POD               CRIT
default    teach-plat-api    2
payments   ledger            0

$ kubectl get clustercompliancereports cis -o jsonpath='{.status.summary}'
{"failCount":1,"passCount":21}
```

### 5.4 Checklist de verificación del golden path

| Verificación | Comando | Esperado |
|---|---|---|
| Secretos ausentes en la historia | `gitleaks detect --exit-code 1` | exit 0 |
| Manifiestos sin misconfig high | `trivy config --exit-code 1 --severity HIGH,CRITICAL .` | exit 0 |
| Imagen sin CVE bloqueante | `trivy image --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed <img>` | exit 0 |
| SBOM generado | `syft <img> -o cyclonedx-json` | 1 componente raíz + deps |
| Firma verificable | `cosign verify --certificate-identity-regexp ... <img>` | veredicto OK |
| Attestation SBOM presente | `cosign verify-attestation --type cyclonedx ... <img>` | payload válido |
| Política testeada | `opa test policy/` | PASS n/n |
| Admisión enforce | `kubectl get cpol -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction` | Enforce |
| Compliance de cluster | `kubescape scan framework nsa` | score sobre umbral |

**Regla de oro operativa:** un control que corre solo en el pipeline no es enforcement, es UX. El enforcement real vive en admisión (Kyverno/Gatekeeper) y en runtime (Trivy Operator, Falco), porque `kubectl apply` directo saltea CI. Diseñá el golden path para que el camino fácil sea el seguro, y para que saltear el camino fácil sea *imposible*, no solo *desaconsejado*.

---

## 6. Referencias

- CNCF Curriculum — Cloud Native Platform Engineering (CNPE): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Trivy — documentación oficial (Aqua Security): https://trivy.dev/latest/docs/
- Syft (SBOM) — Anchore: https://github.com/anchore/syft
- Grype (vulnerability scanner) — Anchore: https://github.com/anchore/grype
- Sigstore / cosign — firma y attestation: https://docs.sigstore.dev/
- Rekor (transparency log): https://docs.sigstore.dev/logging/overview/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/spec/v1.0/
- OpenVEX specification: https://github.com/openvex/spec
- CycloneDX (OWASP): https://cyclonedx.org/specification/overview/
- SPDX (Linux Foundation, ISO/IEC 5962): https://spdx.dev/
- Kyverno — policy engine para Kubernetes: https://kyverno.io/docs/
- OPA / Rego — Open Policy Agent: https://www.openpolicyagent.org/docs/latest/
- Conftest: https://www.conftest.dev/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Checkov (Prisma Cloud): https://www.checkov.io/
- Gitleaks: https://github.com/gitleaks/gitleaks
- Trivy Operator: https://aquasecurity.github.io/trivy-operator/latest/
- kube-bench (CIS Kubernetes Benchmark): https://github.com/aquasecurity/kube-bench
- Kubescape (NSA/CISA hardening, MITRE): https://kubescape.io/docs/
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA Kubernetes Hardening Guidance: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- Tekton Pipelines: https://tekton.dev/docs/pipelines/
- Tekton Chains (supply chain security): https://tekton.dev/docs/chains/
- SARIF (Static Analysis Results Interchange Format): https://sarifweb.azurewebsites.net/