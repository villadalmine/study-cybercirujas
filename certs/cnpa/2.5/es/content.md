# Tema 2.5 — Security Integration in CI/CD Pipelines

> **CNPA · Dominio 2 · Peso 4.0**
> Perfil: Platform Architect / SRE Senior. Este material asume que ya dominás GitOps, contenedores y admission control (temas previos del dominio) y se concentra en *dónde* y *cómo* se inyecta la seguridad dentro del flujo `commit → build → artifact → deploy`, con foco en la **software supply chain**.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El pipeline ES la superficie de ataque

En una plataforma cloud-native, el CI/CD dejó de ser "un runner que hace `kubectl apply`". Es un sistema distribuido con **permisos de escritura en producción**, credenciales de registry, tokens de cloud y acceso al clúster. Un atacante que compromete un step del pipeline no necesita vulnerar la aplicación: ya está *dentro* de la cadena que la construye y la firma.

Los incidentes que definieron la disciplina:

| Incidente | Punto de compromiso (categoría SLSA) | Lección arquitectónica |
|---|---|---|
| **SolarWinds (2020)** | Build (inyección en el proceso de compilación) | El source limpio no garantiza un artifact limpio; hay que atestiguar *cómo* se construyó. |
| **Codecov (2021)** | Build/CI (script del uploader modificado) | Un step de CI de terceros ejecuta con tus secretos en memoria. |
| **event-stream (2018)** | Source/Dependencies (dependencia transitiva maliciosa) | El grafo transitivo es tu superficie real; el `package.json` directo miente. |
| **Log4Shell (2021)** | Artifact (dependencia vulnerable ya desplegada) | Sin SBOM no podés responder "¿dónde tengo log4j 2.14?" en minutos. |
| **PyPI/npm typosquatting** | Source (dependency confusion) | El resolver prioriza versiones/índices atacables. |

### 1.2 El modelo mental: cuatro categorías de amenaza (SLSA)

El framework **SLSA** (Supply-chain Levels for Software Artifacts) del OpenSSF ordena las amenazas por *dónde* ocurren, y esa taxonomía es la que estructura un pipeline seguro:

```
   [ SOURCE ]        [ BUILD ]          [ ARTIFACT/DEPS ]      [ DEPLOY ]
   ────────────────────────────────────────────────────────────────────
   commit firmado    build hermético    scan de imagen         verify signature
   branch protection  provenance         SBOM + SCA            admission policy
   secret scanning    ephemeral runner   image signing         GitOps drift
   review de 2 ojos   OIDC (no creds)    registry inmutable    least-privilege RBAC
   SAST               attestations       vuln DB fresca         runtime policy
```

**Principio rector — "shift-left" no alcanza, es "shift-everywhere":** cada gate es *necesario pero no suficiente*. Un SAST verde no dice nada de una dependencia transitiva; una imagen escaneada sin firmar puede ser sustituida en el registry (TOCTOU entre build y deploy). La seguridad del pipeline es una **cadena de custodia verificable**, no una suma de chequeos aislados.

### 1.3 El invariante que hay que defender

> **Todo artifact que corre en producción debe ser trazable, sin interrupción de la cadena, hasta un commit revisado, construido por un builder de confianza y verificado en el momento de admisión.**

Si en cualquier punto la cadena se rompe (una imagen sin provenance, un `:latest` mutable, una credencial de larga vida en el runner), el resto de los controles se vuelven decorativos. El diseño de este tema consiste en cerrar cada eslabón.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Familias de análisis estático/dinámico

| Técnica | Qué analiza | Momento | Falsos positivos | Cobertura de deps transitivas | Herramientas típicas |
|---|---|---|---|---|---|
| **SAST** | Código fuente / AST | Pre-build (PR) | Alto | No | Semgrep, CodeQL, gosec, Bandit |
| **SCA** | Dependencias declaradas + lockfile | Pre-build / build | Bajo-medio | **Sí** | Trivy, Grype, Snyk, `npm audit`, Dependabot |
| **DAST** | App corriendo (HTTP) | Post-deploy (staging) | Medio | N/A | OWASP ZAP, Nuclei |
| **IAST** | Instrumentación en runtime de tests | Durante tests | Bajo | Parcial | Contrast, comerciales |
| **IaC scan** | Manifiestos/Terraform/YAML | Pre-build | Medio | N/A | Checkov, tfsec, kube-linter, KICS |
| **Secret scan** | Historia de git / diffs | Pre-commit + CI | Medio | N/A | gitleaks, trufflehog, detect-secrets |
| **Image scan** | Capas + OS + libs del binario | Post-build | Bajo | **Sí (real)** | Trivy, Grype, Clair, Docker Scout |

**Trade-off central:** SAST corre temprano y barato pero no ve el runtime; el image scan ve *lo que realmente vas a desplegar* (incluye lo que el `Dockerfile` instaló por fuera del package manager) pero corre tarde. Producción necesita **ambos extremos**, no elegir.

### 2.2 Scanners de imágenes: cuál elegir

| Criterio | **Trivy** (Aqua) | **Grype** (Anchore) | **Clair** (Quay/RH) | **Docker Scout** |
|---|---|---|---|---|
| Modelo de despliegue | CLI / K8s operator | CLI / server | Servidor + Postgres | SaaS + CLI |
| OS + language deps | Sí | Sí | OS-céntrico | Sí |
| IaC / secret / misconfig | **Sí (todo-en-uno)** | No (solo vuln) | No | Parcial |
| SBOM nativo (SPDX/CycloneDX) | Sí | Sí (con Syft) | Vía integración | Sí |
| Modo air-gapped (DB offline) | Sí (`--offline-scan`, DB pull) | Sí | Sí | No |
| Latencia de arranque | Baja | Baja | Alta (server) | Media (red) |
| Mejor para | Gate único en CI | Pipeline con Syft/SBOM | Registry integrado (Quay) | Equipos ya en Docker Hub |

**Recomendación de arquitectura:** Trivy como gate multifunción en CI por su cobertura (vuln + secret + misconfig + SBOM en un binario), y Grype+Syft cuando querés desacoplar la generación de SBOM del scanning (SBOM como artifact firmado independiente, re-escaneable a futuro sin re-buildear).

### 2.3 Firmado de artifacts: keyed vs keyless (Sigstore/cosign)

| Aspecto | **cosign keyed** (par de claves) | **cosign keyless** (Sigstore/OIDC) |
|---|---|---|
| Gestión de clave privada | Vos la custodiás (KMS, sealed) | **No hay clave de larga vida** |
| Identidad del firmante | Implícita (quien tenga la clave) | Explícita (OIDC issuer + subject) |
| Rotación | Manual, dolorosa | Automática (cada firma usa cert efímero de Fulcio) |
| Transparencia | No inherente | **Rekor** (transparency log público/privado) |
| Riesgo principal | Robo de la clave privada | Compromiso del OIDC provider |
| Verificación offline | Fácil (clave pública) | Requiere raíz TUF + validar cert chain |
| Ideal para | Air-gapped, control total | CI en cloud con OIDC (GitHub/GitLab) |

En pipelines con OIDC (GitHub Actions, GitLab, Tekton con SPIRE) el modelo **keyless** es el estado del arte: elimina el secreto de larga vida más peligroso de todo el sistema —la clave de firma— y ata la firma a *quién y qué workflow* la produjo, registrado en Rekor.

### 2.4 Policy engines de admisión

| | **Kyverno** | **OPA/Gatekeeper** |
|---|---|---|
| Lenguaje | YAML declarativo (nativo K8s) | **Rego** (lenguaje propio) |
| Curva de aprendizaje | Baja | Alta |
| `verifyImages` (firma cosign) | **Nativo** | Requiere lógica Rego + data externa |
| Generación/mutación de recursos | Sí (generate/mutate) | Mutación sí; generación no |
| Reglas complejas cross-resource | Limitado | **Superior** (Rego es Turing-incompleto pero expresivo) |
| Reutilización de policies | ClusterPolicy | ConstraintTemplate + Constraint |
| Ecosistema de librería | Kyverno Policies | Gatekeeper Library / OPA bundles |

**Regla práctica:** para *verificar firmas y SBOM en admisión* (el gate final de este tema), Kyverno gana por su `verifyImages` nativo. Para lógica de negocio compleja y compartida con APIs no-K8s, Gatekeeper/Rego.

### 2.5 Gestión de secretos en el pipeline

| Solución | Dónde vive el secreto | Rotación | Acoplamiento a cloud | Modelo |
|---|---|---|---|---|
| **Sealed Secrets** | Cifrado en Git (asimétrico) | Manual (re-seal) | Ninguno | GitOps-friendly, cluster-scoped key |
| **External Secrets Operator (ESO)** | En un backend externo (Vault/ASM/GSM) | Delegada al backend | Alto | Sincroniza a `Secret` de K8s |
| **Vault Agent / CSI** | En Vault, inyectado en runtime | Dinámica (leases) | Medio | Nunca toca etcd como plano |
| **Secrets Store CSI Driver** | Backend externo, montado como volumen | Delegada | Alto | Fuera de etcd |
| **OIDC federation** | **No hay secreto** | N/A | Alto (pero sin credencial) | Token efímero por job |

**El salto de generación:** el patrón que elimina la clase entera de "credencial de larga vida robada del runner" es **OIDC workload identity federation**. En vez de guardar `AWS_SECRET_ACCESS_KEY` en el CI, el runner presenta un JWT firmado por el OIDC issuer del propio CI, y el cloud lo intercambia por credenciales temporales atadas a `repo:org/repo:ref:refs/heads/main`. Es la mejor práctica actual y el examen la privilegia.

---

## 3. Manifiestos e infraestructura completos

> Todos los manifiestos son sintácticamente válidos y desplegables. Ajustá `registry.example.com`, `org/app` y los issuers a tu entorno.

### 3.1 Pipeline GitHub Actions con cadena de custodia completa (OIDC keyless)

```yaml
# .github/workflows/secure-supply-chain.yml
name: secure-supply-chain

on:
  push:
    branches: [main]
    tags: ["v*"]

permissions:
  contents: read
  id-token: write        # imprescindible para OIDC keyless (cosign/Fulcio)
  packages: write        # push al registry (GHCR)

env:
  REGISTRY: ghcr.io
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build-scan-sign:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      # ── GATE 1: secretos en el diff ────────────────────────────────
      - name: Secret scan (gitleaks)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITLEAKS_ENABLE_UPLOAD_ARTIFACT: "false"

      # ── GATE 2: SAST + IaC ─────────────────────────────────────────
      - name: SAST (semgrep)
        uses: semgrep/semgrep-action@v1
        with:
          config: p/ci

      - name: IaC misconfig (trivy config)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: config
          scan-ref: .
          severity: HIGH,CRITICAL
          exit-code: "1"          # rompe el build si hay CRITICAL

      # ── BUILD determinista ─────────────────────────────────────────
      - uses: docker/setup-buildx-action@v3
      - name: Login GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build & push (by digest)
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ github.sha }}
          provenance: true        # SLSA provenance de buildkit
          sbom: true

      # ── GATE 3: scan de la imagen construida ───────────────────────
      - name: Image scan (trivy)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true    # no rompemos por CVEs sin patch upstream
          exit-code: "1"

      # ── SBOM como artifact firmado ─────────────────────────────────
      - name: Generate SBOM (syft)
        uses: anchore/sbom-action@v0
        with:
          image: ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
          format: cyclonedx-json
          output-file: sbom.cdx.json

      # ── FIRMA keyless + attestations ───────────────────────────────
      - uses: sigstore/cosign-installer@v3

      - name: Sign image (keyless)
        run: |
          cosign sign --yes \
            ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}

      - name: Attest SBOM (keyless)
        run: |
          cosign attest --yes \
            --predicate sbom.cdx.json \
            --type cyclonedx \
            ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
```

**Puntos de diseño no negociables:**
- `permissions:` es *deny-by-default* y mínimo (`id-token: write` solo por OIDC).
- Se opera **por digest** (`@sha256:...`), nunca por tag mutable, entre build y firma → cierra el TOCTOU.
- `ignore-unfixed: true` evita romper por CVEs sin fix upstream (o el pipeline queda bloqueado por algo que no podés remediar); documentá esa decisión de riesgo.
- La firma y el attestation son *keyless*: no hay un solo secreto de firma en el repo.

### 3.2 Kyverno — admisión que exige firma verificada (el gate final)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
  annotations:
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce   # Enforce = bloquea; Audit = solo reporta
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail                # si el webhook cae, se DENIEGA (fail-closed)
  rules:
    - name: check-cosign-keyless
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "ghcr.io/org/app*"
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/org/app/.github/workflows/secure-supply-chain.yml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
          # exige que exista un attestation SBOM CycloneDX firmado por la misma identidad
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/org/app/.github/workflows/secure-supply-chain.yml@refs/heads/main"
                        issuer: "https://token.actions.githubusercontent.com"
```

Este policy hace tres cosas a la vez en el momento de admisión: (1) verifica que la imagen esté **firmada** por *exactamente* ese workflow en `main` (no cualquier firma), (2) exige un **SBOM attestation** de la misma identidad, y (3) **muta la imagen a su digest** (efecto colateral de `verifyImages`: reescribe el tag al sha256 verificado, garantizando inmutabilidad en runtime). `failurePolicy: Fail` es **fail-closed**: si Kyverno no puede evaluar, no admite — la postura correcta para un gate de seguridad.

### 3.3 OPA/Gatekeeper — equivalente en Rego (bloquear imágenes no confiables)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8strustedregistries
spec:
  crd:
    spec:
      names:
        kind: K8sTrustedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items: { type: string }
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8strustedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not startswith_any(container.image, input.parameters.registries)
          msg := sprintf("image %q no proviene de un registry confiable", [container.image])
        }

        startswith_any(str, prefixes) {
          startswith(str, prefixes[_])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sTrustedRegistries
metadata:
  name: only-trusted-registries
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    registries:
      - "ghcr.io/org/"
      - "registry.example.com/prod/"
```

### 3.4 OIDC federation con AWS (eliminar credenciales de larga vida)

```yaml
# Terraform: confía en el OIDC issuer de GitHub, sin access keys
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Ata la credencial a UN repo y UNA branch — sin esto, cualquier repo asume el rol
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:org/app:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_deployer" {
  name               = "ci-deployer"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}
```

> **Error clásico de producción:** omitir el `condition` sobre `sub`. Sin él, *cualquier* workflow de *cualquier* repo con acceso al issuer asume el rol. La condición `sub` es la que convierte "OIDC" en "least privilege".

### 3.5 Tekton — pipeline in-cluster con firma automática (Tekton Chains)

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-scan-sign
spec:
  params:
    - name: image
  results:
    - name: IMAGE_DIGEST
      value: $(tasks.build.results.IMAGE_DIGEST)
    - name: IMAGE_URL
      value: $(tasks.build.results.IMAGE_URL)
  tasks:
    - name: fetch
      taskRef: { name: git-clone }
    - name: scan-deps
      runAfter: [fetch]
      taskRef: { name: trivy-scanner }
      params:
        - name: ARGS
          value: ["fs", "--severity", "HIGH,CRITICAL", "--exit-code", "1", "."]
    - name: build
      runAfter: [scan-deps]
      taskRef: { name: kaniko }        # builder sin daemon, roootless
      params:
        - name: IMAGE
          value: $(params.image)
```

Con **Tekton Chains** instalado y configurado (`artifacts.taskrun.format: slsa/v2alpha3`, `artifacts.taskrun.signer: x509` o `kms`), *cada* `TaskRun` que produce una imagen genera y firma automáticamente su **provenance SLSA** y la sube al registry como attestation, sin tocar el Pipeline. Los `results` `IMAGE_DIGEST`/`IMAGE_URL` son la convención que Chains detecta para saber qué firmar.

### 3.6 External Secrets Operator (secreto fuera de etcd/Git)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: prod
spec:
  provider:
    vault:
      server: "https://vault.example.com:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "prod-reader"
          serviceAccountRef:
            name: eso-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-db
  namespace: prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: app-db-credentials       # el Secret K8s que se crea
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: prod/db
        property: password
```

El secreto real vive en Vault; ESO lo sincroniza y lo refresca. En Git solo queda la *referencia*, nunca el valor — compatible con GitOps sin exponer material sensible.

---

## 4. Comandos CLI y salidas reales

### 4.1 Scan de dependencias y de imagen (Trivy)

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed ghcr.io/org/app@sha256:9f2a...
2026-08-06T14:22:10Z    INFO    Vulnerability scanning is enabled
2026-08-06T14:22:11Z    INFO    Detected OS: alpine (3.20.3)

ghcr.io/org/app (alpine 3.20.3)
===============================
Total: 0 (HIGH: 0, CRITICAL: 0)

app/vendor/golang.org (gobinary)
================================
Total: 1 (HIGH: 1, CRITICAL: 0)

┌───────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│      Library      │ Vulnerability  │ Severity │ Status │ Installed Version  │ Fixed Version │
├───────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ golang.org/x/net  │ CVE-2025-22870 │ HIGH     │ fixed  │ v0.34.0           │ v0.36.0       │
└───────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

$ echo $?
1
```

El `exit code 1` es lo que rompe el pipeline: es un **gate**, no un reporte informativo.

### 4.2 SBOM y su re-escaneo (Syft + Grype)

```console
$ syft ghcr.io/org/app@sha256:9f2a... -o cyclonedx-json > sbom.cdx.json
 ✔ Parsed image        sha256:9f2a...
 ✔ Cataloged contents
   ├── 142 packages
   └── 1 file digests

$ grype sbom:sbom.cdx.json --fail-on high
 ✔ Scanned for vulnerabilities  [1 vulnerability match]
NAME              INSTALLED  FIXED-IN  TYPE       VULNERABILITY   SEVERITY
golang.org/x/net  v0.34.0    v0.36.0   go-module  CVE-2025-22870  High

$ echo $?
1
```

> **Poder operativo del SBOM:** cuando salga el próximo Log4Shell, no re-buildeás nada. Corrés `grype sbom:...` contra los SBOM ya firmados y guardados, y en segundos sabés *qué imágenes* en producción contienen el paquete afectado.

### 4.3 Firma y verificación keyless (cosign)

```console
$ cosign sign --yes ghcr.io/org/app@sha256:9f2a...
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully verified SCT...
tlog entry created with index: 148820193
Pushing signature to: ghcr.io/org/app

$ cosign verify \
    --certificate-identity "https://github.com/org/app/.github/workflows/secure-supply-chain.yml@refs/heads/main" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/org/app@sha256:9f2a...

Verification for ghcr.io/org/app@sha256:9f2a... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[{"critical":{"identity":{"docker-reference":"ghcr.io/org/app"},...}]
```

### 4.4 Provenance SLSA (slsa-verifier)

```console
$ slsa-verifier verify-image ghcr.io/org/app@sha256:9f2a... \
    --source-uri github.com/org/app \
    --source-branch main
Verified signature against tlog entry index 148820201
Verified build using builder "https://github.com/slsa-framework/slsa-github-generator/..."
PASSED: SLSA verification passed
```

### 4.5 Testear los policies antes de aplicarlos (Kyverno CLI)

```console
$ kyverno apply verify-image-signature.yaml --resource unsigned-pod.yaml
Applying 1 policy rule(s) to 1 resource(s)...

policy verify-image-signature -> resource default/Pod/bad-app failed:
1. check-cosign-keyless: image verification failed for
   ghcr.io/org/app:evil: .attestors[0].entries[0].keyless: no matching signatures

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Y el intento de desplegar contra el clúster con el policy en `Enforce`:

```console
$ kubectl apply -f unsigned-pod.yaml
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/default/bad-app was blocked due to the following policies:

verify-image-signature:
  check-cosign-keyless: 'image verification failed for ghcr.io/org/app:evil:
    no matching signatures found'
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Tabla de fallas frecuentes

| Síntoma | Causa raíz probable | Diagnóstico | Remediación |
|---|---|---|---|
| `cosign verify` → `no matching signatures` | Se firmó por tag, se verifica por digest (o al revés); o `subject`/`issuer` no coinciden | `cosign tree <ref>` para ver qué firmas existen | Firmar y verificar **siempre por digest**; alinear identity |
| Kyverno admite pods no firmados | `validationFailureAction: Audit` en vez de `Enforce`, o `imageReferences` no matchea | `kubectl get cpol -o yaml`; revisar `PolicyReport` | Poner `Enforce`; corregir el glob del registry |
| Kyverno **rechaza todo** al caer el webhook | `failurePolicy: Fail` + pod de Kyverno caído | `kubectl get pods -n kyverno`; eventos de admisión | Es el comportamiento correcto (fail-closed); recuperar Kyverno con alta disponibilidad (≥3 réplicas) |
| OIDC: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Condición `sub` no matchea el `repo:...:ref:...` real | Decodificar el JWT del job (`jwt.io` / base64) y comparar el claim `sub` | Ajustar el `StringLike` del trust policy |
| Trivy no rompe el build pese a CVE crítico | Falta `--exit-code 1`, o `--ignore-unfixed` ocultó el fix disponible | Correr con `--exit-code 1` y sin ignore | Configurar exit codes; separar política unfixed |
| `cosign verify` falla offline / air-gap | Falta raíz TUF / Rekor no accesible | `COSIGN_EXPERIMENTAL`, `--offline`, `TUF_ROOT` | Sincronizar TUF root, usar Rekor privado o `--insecure-ignore-tlog` (solo con clave conocida) |
| Secret filtrado ya está en la historia de git | gitleaks corre solo sobre el diff del PR | `gitleaks detect --log-opts="--all"` | **Rotar el secreto** (borrarlo del historial NO lo invalida) + `git filter-repo` |

### 5.2 Método de diagnóstico de rechazos de admisión

Cuando un deploy es bloqueado y no sabés por qué:

```console
# 1) ¿Qué policies están activas y en qué modo?
$ kubectl get clusterpolicy
NAME                       ADMISSION   BACKGROUND   READY   AGE
verify-image-signature     true        false        True    12d

# 2) ¿Qué dijo exactamente la evaluación?
$ kubectl describe clusterpolicy verify-image-signature | grep -A5 Rule

# 3) Historia de reportes (por qué falló un recurso concreto)
$ kubectl get policyreport -A
$ kubectl get policyreport -n prod -o yaml | grep -B2 -A6 "result: fail"

# 4) ¿El webhook está sano? (fail-closed bloquea todo si no)
$ kubectl get validatingwebhookconfigurations | grep kyverno
$ kubectl get pods -n kyverno -o wide
```

### 5.3 Verificar la cadena de custodia extremo a extremo

El chequeo que un SRE corre para *demostrar* (no asumir) que el invariante de §1.3 se cumple sobre una imagen en producción:

```console
# a) La imagen está firmada por el workflow correcto
$ cosign verify --certificate-identity "$WF" --certificate-oidc-issuer "$ISS" $IMG_DIGEST

# b) Existe SBOM attestation y es re-escaneable
$ cosign verify-attestation --type cyclonedx \
    --certificate-identity "$WF" --certificate-oidc-issuer "$ISS" $IMG_DIGEST \
  | jq -r '.payload' | base64 -d | jq '.predicate' > sbom.json
$ grype sbom:sbom.json --fail-on critical

# c) La provenance SLSA ata la imagen al source
$ slsa-verifier verify-image $IMG_DIGEST --source-uri github.com/org/app

# d) Lo que corre en el clúster ES ese digest (no un tag mutado)
$ kubectl get pod app-xxx -o jsonpath='{.status.containerStatuses[0].imageID}'
ghcr.io/org/app@sha256:9f2a...     # debe coincidir con $IMG_DIGEST
```

Si los cuatro pasos pasan, la cadena está intacta. Si el paso (d) muestra un digest distinto al firmado, tenés **drift**: algo desplegó por fuera del pipeline verificado — investigá RBAC y accesos directos al clúster.

### 5.4 Anti-patrones que invalidan todo el esfuerzo

- **`:latest` en producción.** Rompe la trazabilidad; el policy debería rechazar tags mutables.
- **`validationFailureAction: Audit` "temporal" que se vuelve permanente.** Auditar no protege; es un estado de rollout, no de operación.
- **Credenciales de larga vida en el runner** "porque OIDC es complicado". Es la vulnerabilidad más explotada del pipeline.
- **`--insecure-ignore-tlog` en verificación productiva.** Desactiva la transparencia; solo válido en pruebas.
- **Escanear en CI pero no verificar en admisión.** Sin el gate de admisión (Kyverno/Gatekeeper), nada impide desplegar una imagen que nunca pasó por el pipeline.

---

## 6. Referencias

- CNCF Curriculum (CNPA) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- SLSA — Supply-chain Levels for Software Artifacts (OpenSSF) — https://slsa.dev/spec/
- Sigstore / cosign — https://docs.sigstore.dev/ · https://github.com/sigstore/cosign
- Rekor (transparency log) — https://docs.sigstore.dev/logging/overview/
- Fulcio (certificate authority) — https://docs.sigstore.dev/certificate_authority/overview/
- Kyverno — verifyImages / image verification — https://kyverno.io/docs/writing-policies/verify-images/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Trivy — https://trivy.dev/latest/docs/
- Syft (SBOM) — https://github.com/anchore/syft
- Grype — https://github.com/anchore/grype
- CycloneDX SBOM standard — https://cyclonedx.org/specification/overview/
- SPDX SBOM standard — https://spdx.dev/
- in-toto attestation framework — https://in-toto.io/
- Tekton Chains (SLSA provenance) — https://tekton.dev/docs/chains/
- slsa-verifier — https://github.com/slsa-framework/slsa-verifier
- External Secrets Operator — https://external-secrets.io/latest/
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- HashiCorp Vault (Kubernetes auth) — https://developer.hashicorp.com/vault/docs/auth/kubernetes
- GitHub Actions OIDC hardening — https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- gitleaks — https://github.com/gitleaks/gitleaks
- OpenSSF Scorecard — https://github.com/ossf/scorecard
- SLSA GitHub Generator — https://github.com/slsa-framework/slsa-github-generator