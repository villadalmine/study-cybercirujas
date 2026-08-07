# Tema 2.5 — Security Integration in CI/CD Pipelines · Ejercicios guiados

> Estos ejercicios construyen, etapa por etapa, un pipeline de CI/CD que trata la seguridad como un *quality gate* de primera clase y no como una revisión posterior. Vas a ejecutar cada control de forma aislada (SCA, SAST, secret scanning, image scanning, SBOM, firma, attestation, provenance) y al final los vas a unir en un workflow completo cuya salida queda verificada por *admission control* en el cluster. La idea rectora es el modelo **shift-left + supply chain security**: cuanto antes falla un artefacto inseguro, más barato es el remediarlo, y ningún artefacto llega a `kubectl apply` sin una identidad criptográfica comprobable.

---

## Prerequisitos

Instalá y verificá las siguientes herramientas (todas open source y usadas de forma estándar en la industria):

```bash
# Escáneres
trivy --version        # aquasecurity/trivy  — SCA, image scan, misconfig, secrets
grype version          # anchore/grype        — vuln scan sobre SBOM
syft version           # anchore/syft         — generación de SBOM
gitleaks version       # gitleaks/gitleaks    — secret scanning
semgrep --version      # semgrep/semgrep      — SAST

# Supply chain
cosign version         # sigstore/cosign      — firma y attestations keyless
slsa-verifier version  # slsa-framework       — verificación de provenance

# Runtime / policy
kind version && kubectl version --client
# Kyverno se instala dentro del Ejercicio 6
```

Trabajaremos sobre un repo de ejemplo con una app trivial y un `Dockerfile`. Cloná o creá una carpeta `demo-secure-pipeline/` con este contenido mínimo:

```dockerfile
# Dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
USER 1000
EXPOSE 3000
CMD ["node", "server.js"]
```

Definí una variable que reutilizaremos:

```bash
export IMAGE=ghcr.io/$GITHUB_USER/demo:1.0.0
```

---

## Ejercicio 1 — Shift-left: SCA y SAST como quality gates

**Objetivo:** detectar vulnerabilidades en dependencias (**SCA**) y patrones inseguros en tu propio código (**SAST**) *antes* de construir la imagen, y hacer que el build **falle** cuando se cruza un umbral de severidad.

1. Escaneá el filesystem del proyecto con Trivy en modo **SCA** (dependencias declaradas en lockfiles):

   ```bash
   trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 0 .
   ```

   Salida esperada (recortada):

   ```
   package-lock.json (npm)
   =======================
   Total: 3 (HIGH: 2, CRITICAL: 1)

   ┌───────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
   │    Library    │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
   ├───────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
   │ minimist      │ CVE-2021-44906 │ CRITICAL │ fixed  │ 1.2.5             │ 1.2.6         │
   │ semver        │ CVE-2022-25883 │ HIGH     │ fixed  │ 7.3.5             │ 7.5.2         │
   └───────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘
   ```

2. Convertí el mismo escaneo en un **gate** que aborta el pipeline. Notá el cambio de `--exit-code`:

   ```bash
   trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 .
   echo "exit status = $?"
   ```

   Como hay hallazgos `HIGH`/`CRITICAL`, el proceso termina con `exit status = 1` y el step del pipeline se marca como *failed*.

3. Corré un **SAST** con Semgrep sobre el código fuente (no las dependencias):

   ```bash
   semgrep --config "p/owasp-top-ten" --error --json --output semgrep.json .
   ```

   Salida esperada (recortada):

   ```
   Findings:
     server.js
        javascript.express.security.injection.tainted-sql-string
        User input flows into a raw SQL query (SQL injection)
        12┆ db.query("SELECT * FROM users WHERE id = " + req.query.id)

   ran 1240 rules on 4 files: 1 finding
   ```

   El flag `--error` hace que Semgrep devuelva exit code distinto de cero cuando hay findings, igual que Trivy.

4. Emití los hallazgos de Trivy en formato **SARIF** para integrarlos con la pestaña de *code scanning* del SCM en vez de solo verlos en el log:

   ```bash
   trivy fs --scanners vuln --format sarif --output trivy.sarif .
   ```

**Preguntas de comprensión**

- **P1.1** — ¿Qué diferencia hay entre **SCA** y **SAST**, y por qué un pipeline maduro necesita los dos aunque ambos "escaneen código"?
- **P1.2** — En los pasos 1 y 2 el comando es casi idéntico salvo `--exit-code`. ¿Por qué separar "reportar" de "romper el build" es una decisión de diseño y no un detalle?
- **P1.3** — ¿Qué agrega el formato **SARIF** frente a leer la tabla en el log del job?
- **P1.4** — El escaneo del paso 1 encontró `CVE-2021-44906` con `Status: fixed`. ¿Qué significa `fixed` acá y por qué ese estado es el que más querés priorizar en un gate?

---

## Ejercicio 2 — Container image scanning y generación de SBOM

**Objetivo:** escanear la **imagen construida** (no solo el código), generar su **SBOM** (Software Bill of Materials) y entender por qué el SBOM es un artefacto de primera clase del supply chain.

1. Construí la imagen localmente:

   ```bash
   docker build -t "$IMAGE" .
   ```

2. Escaneá la imagen ya armada. Esto detecta paquetes del **base image** (`node:18-alpine`) que el escaneo del filesystem del Ejercicio 1 no veía:

   ```bash
   trivy image --severity HIGH,CRITICAL --exit-code 1 "$IMAGE"
   ```

   Salida esperada (recortada):

   ```
   ghcr.io/…/demo:1.0.0 (alpine 3.18.4)
   ====================================
   Total: 2 (HIGH: 1, CRITICAL: 1)

   │ libcrypto3 │ CVE-2023-5678 │ HIGH │ ... │ 3.1.3-r0 │ 3.1.4-r1 │
   ```

3. Generá el **SBOM** de la imagen con Syft en formato **CycloneDX**:

   ```bash
   syft scan "$IMAGE" -o cyclonedx-json=sbom.cdx.json
   ```

   Salida esperada (stderr):

   ```
   ✔ Parsed image sha256:9f2c…
   ✔ Cataloged contents
     ├── ✔ Packages          [51 packages]
     ├── ✔ File digests      [412 files]
     └── ✔ Executables       [37 executables]
   ```

4. Ahora **desacoplá** el escaneo del build: pasale a Grype el SBOM en vez de la imagen. Escanear el SBOM es más rápido y no requiere volver a bajar la imagen:

   ```bash
   grype sbom:./sbom.cdx.json --fail-on high
   ```

   Salida esperada (recortada):

   ```
   NAME        INSTALLED  FIXED-IN  TYPE  VULNERABILITY   SEVERITY
   libcrypto3  3.1.3-r0   3.1.4-r1  apk   CVE-2023-5678   High
   ```

5. Guardá también el SBOM en formato **SPDX**, para comparar los dos estándares:

   ```bash
   syft scan "$IMAGE" -o spdx-json=sbom.spdx.json
   ```

**Preguntas de comprensión**

- **P2.1** — El escaneo del Ejercicio 1 (`trivy fs`) y el del paso 2 (`trivy image`) miran el mismo proyecto. ¿Por qué el segundo encuentra vulnerabilidades que el primero no puede ver?
- **P2.2** — ¿Qué es un **SBOM** y qué te permite hacer *después* del build que sin él sería imposible o carísimo? Nombrá al menos un escenario concreto (pensá en un CVE que se publica meses después de haber desplegado).
- **P2.3** — En el paso 4 escaneás `sbom:./sbom.cdx.json` en lugar de la imagen. ¿Qué ventaja operativa tiene escanear el SBOM en vez de la imagen, y qué **riesgo** introduce (pista: ¿el SBOM sigue siendo fiel a lo que corre en producción)?
- **P2.4** — **CycloneDX** vs **SPDX**: ambos son SBOM. ¿Por qué existe más de un estándar y qué criterio usarías para elegir uno en tu plataforma?

---

## Ejercicio 3 — Secret scanning y prevención de fugas

**Objetivo:** impedir que credenciales lleguen al historial de git y al registro de artefactos. El secret scanning es la contramedida a un patrón de ataque de supply chain muy común: robar un token committeado por error.

1. Introducí a propósito un secreto en un archivo para probar la detección:

   ```bash
   echo 'AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE' >> .env.local
   git add .env.local
   ```

2. Escaneá el estado *staged* con Gitleaks (esto es lo que correrías en un **pre-commit hook**, antes de que el secreto exista siquiera como commit):

   ```bash
   gitleaks protect --staged --verbose --redact
   ```

   Salida esperada (recortada):

   ```
   Finding:     AWS_SECRET_ACCESS_KEY=REDACTED
   Secret:      REDACTED
   RuleID:      aws-access-token
   File:        .env.local
   Fingerprint: .env.local:aws-access-token:1

   9:34AM WRN leaks found: 1
   ```

   El exit code es `1`, así que el commit se aborta.

3. Escaneá el **historial completo** del repositorio (esto es lo que correrías en CI, porque un secreto puede haber entrado hace 200 commits):

   ```bash
   gitleaks detect --source . --report-format sarif --report-path gitleaks.sarif --exit-code 1
   ```

4. Suponé que el escaneo de CI encuentra un secreto que **ya está committeado y pusheado**. Respondé (en tu cabeza, no hace falta ejecutar): ¿alcanza con borrar la línea en un nuevo commit? Volvé a esta pregunta en P3.3.

**Preguntas de comprensión**

- **P3.1** — ¿Cuál es la diferencia entre `gitleaks protect --staged` y `gitleaks detect`, y por qué querés **los dos** en momentos distintos del ciclo de vida (pre-commit vs CI)?
- **P3.2** — El secret scanning es reactivo: encuentra el secreto *después* de escribirlo. Nombrá dos controles **preventivos** que reduzcan la probabilidad de que un secreto llegue a estar en el árbol de trabajo.
- **P3.3** — Un token de producción se coló en un commit que ya está en el remoto. ¿Por qué `git rm` + nuevo commit **no** resuelve el incidente, y cuál es la única remediación que realmente cierra el riesgo?

---

## Ejercicio 4 — Firma keyless de artefactos con Sigstore (cosign)

**Objetivo:** darle a la imagen una **identidad criptográfica verificable** sin gestionar claves privadas de larga vida, usando firma **keyless** de Sigstore (identidad OIDC efímera vía **Fulcio** + registro de transparencia **Rekor**).

1. Empujá la imagen y capturá su **digest**. Firmar por tag es un antipatrón porque el tag es mutable:

   ```bash
   docker push "$IMAGE"
   DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")
   echo "$DIGEST"
   # ghcr.io/…/demo@sha256:9f2c4b8e…
   ```

2. Firmá la imagen en modo **keyless**. En una máquina interactiva esto abre el navegador para autenticar tu identidad OIDC; en CI se usa el token OIDC ambiente del runner (ver Ejercicio 7):

   ```bash
   cosign sign --yes "$DIGEST"
   ```

   Salida esperada (recortada):

   ```
   Generating ephemeral keys...
   Retrieving signed certificate from Fulcio...
   The sigstore service, hosted by sigstore a Series of LF Projects, LLC, ...
   tlog entry created with index: 84213771
   Pushing signature to: ghcr.io/…/demo
   ```

3. Verificá la firma exigiendo **qué identidad** la produjo. Sin `--certificate-identity` y `--certificate-oidc-issuer` cualquiera podría haber firmado:

   ```bash
   cosign verify \
     --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" \
     "$DIGEST" | jq '.[0].optional.Subject'
   ```

   Salida esperada:

   ```
   Verification for ghcr.io/…/demo@sha256:9f2c… --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - Existence of the claims in the transparency log was verified offline
     - The code-signing certificate was verified using trusted certificate authority certificates
   "you@example.com"
   ```

4. Probá el modo negativo: verificá con una identidad equivocada y observá el fallo:

   ```bash
   cosign verify \
     --certificate-identity "attacker@evil.com" \
     --certificate-oidc-issuer "https://accounts.google.com" \
     "$DIGEST"
   # Error: none of the expected identities matched what was in the certificate
   ```

**Preguntas de comprensión**

- **P4.1** — ¿Qué problema resuelve la firma **keyless** frente a la firma tradicional con una clave privada guardada en un secret del CI? ¿Qué desaparece de tu superficie de ataque?
- **P4.2** — Explicá el rol de **Fulcio** y el de **Rekor** en una firma keyless. ¿Por qué el registro de transparencia (Rekor) es lo que permite verificar *offline* y detectar firmas retroactivas?
- **P4.3** — En el paso 1 firmamos `@sha256:…` y no `:1.0.0`. ¿Qué ataque concreto habilitás si firmás y verificás por **tag** en lugar de por **digest**?
- **P4.4** — `cosign verify` sin `--certificate-identity` "verifica" igual. ¿Por qué eso es prácticamente inútil como control de seguridad?

---

## Ejercicio 5 — Attestations, SBOM firmado y provenance SLSA

**Objetivo:** ir más allá de "esta imagen fue firmada" hacia "esta imagen fue firmada **y afirmo cosas verificables sobre ella**": adjuntar el SBOM como **attestation** firmada y comprender la **provenance SLSA** (quién la construyó, desde qué fuente, con qué builder).

1. Adjuntá el SBOM del Ejercicio 2 como una **attestation** firmada (no como un blob suelto). Una attestation liga un *predicate* (el SBOM) a la imagen mediante una firma:

   ```bash
   cosign attest --yes \
     --predicate sbom.cdx.json \
     --type cyclonedx \
     "$DIGEST"
   ```

2. Verificá la attestation exigiendo identidad y tipo:

   ```bash
   cosign verify-attestation \
     --type cyclonedx \
     --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" \
     "$DIGEST" | jq '.payload |= @base64d | .payload | fromjson | .predicateType'
   ```

   Salida esperada:

   ```
   "https://cyclonedx.org/bom"
   ```

3. Suponé que la imagen fue construida por el generador oficial de **SLSA** en GitHub Actions. Verificá su **provenance** (que ata la imagen a un commit y a un builder de confianza) con `slsa-verifier`:

   ```bash
   slsa-verifier verify-image "$DIGEST" \
     --source-uri "github.com/$GITHUB_USER/demo" \
     --source-tag "v1.0.0"
   ```

   Salida esperada (recortada):

   ```
   Verified signature against tlog entry index 84213812 ...
   Verifying artifact ghcr.io/…/demo@sha256:9f2c…: PASSED
   PASSED: SLSA verification passed
   ```

4. Situá lo que acabás de hacer en la escala **SLSA**: relacioná cada control del pipeline con el nivel que ayuda a alcanzar (respondé en P5.4).

**Preguntas de comprensión**

- **P5.1** — ¿Qué diferencia hay entre **firmar una imagen** (Ejercicio 4) y **adjuntarle una attestation** (paso 1)? ¿Qué afirmación adicional te permite hacer y verificar una attestation?
- **P5.2** — ¿Qué es la **provenance** en el sentido de SLSA y qué preguntas responde que un SBOM firmado *no* responde?
- **P5.3** — ¿Por qué es importante que la provenance sea generada por el **builder** (la plataforma de CI) y no por un step arbitrario del propio workflow que el desarrollador controla? (pensá en un pipeline comprometido).
- **P5.4** — Ordená de menor a mayor rigor: (a) imagen firmada keyless, (b) provenance no falsificable generada por un builder aislado, (c) build reproducible desde fuente versionada. ¿Cuál se acerca más a los niveles altos de SLSA y por qué?

---

## Ejercicio 6 — Cerrar el loop: admission control con Kyverno `verifyImages`

**Objetivo:** que todo el trabajo anterior tenga consecuencias en runtime. Un pipeline que firma imágenes no sirve de nada si el cluster acepta imágenes sin firmar. Acá el cluster **rechaza** en *admission* cualquier Pod cuya imagen no tenga la firma keyless de la identidad esperada.

1. Levantá un cluster local e instalá Kyverno:

   ```bash
   kind create cluster --name secure
   kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

2. Aplicá una `ClusterPolicy` que exige firma keyless con la **identidad exacta** de tu workflow de release. Notá `background: false` (obligatorio para `verifyImages`) y que la política valida la firma contra Rekor:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-signed-images
   spec:
     validationFailureAction: Enforce
     webhookTimeoutSeconds: 30
     failurePolicy: Fail
     background: false
     rules:
       - name: verify-keyless-signature
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         verifyImages:
           - imageReferences:
               - "ghcr.io/myorg/demo:*"
             mutateDigest: true
             required: true
             attestors:
               - count: 1
                 entries:
                   - keyless:
                       subject: "https://github.com/myorg/demo/.github/workflows/release.yaml@refs/heads/main"
                       issuer: "https://token.actions.githubusercontent.com"
                       rekor:
                         url: https://rekor.sigstore.dev
   ```

   Guardalo como `verify-images.yaml` y aplicalo:

   ```bash
   kubectl apply -f verify-images.yaml
   ```

3. Intentá correr una imagen **sin firmar** y observá el rechazo en admission:

   ```bash
   kubectl run bad --image=ghcr.io/myorg/demo:unsigned
   ```

   Salida esperada:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   resource Pod/default/bad was blocked due to the following policies:
     require-signed-images:
       verify-keyless-signature: failed to verify image ghcr.io/myorg/demo:unsigned:
       .attestors[0].entries[0].keyless: no signatures found
   ```

4. Corré la imagen **firmada** por el workflow correcto y observá que, además de admitirse, Kyverno **reescribe el tag a digest** (`mutateDigest: true`):

   ```bash
   kubectl run good --image=ghcr.io/myorg/demo:1.0.0
   kubectl get pod good -o jsonpath='{.spec.containers[0].image}'
   # ghcr.io/myorg/demo:1.0.0@sha256:9f2c4b8e…
   ```

**Preguntas de comprensión**

- **P6.1** — El pipeline ya firmaba y escaneaba. ¿Qué agrega el **admission control** que el CI por sí solo no puede garantizar? (pensá en imágenes que llegan al cluster **sin pasar por tu CI**).
- **P6.2** — ¿Por qué `mutateDigest: true` es una defensa importante y no una comodidad? Relacionalo con P4.3.
- **P6.3** — `failurePolicy: Fail` significa que si el webhook de Kyverno está caído, se **rechaza** la admisión. ¿Qué trade-off de disponibilidad vs seguridad estás eligiendo, y cuándo elegirías `Ignore`?
- **P6.4** — La `subject` de la política apunta a un archivo de workflow y a un `ref` específicos. ¿Por qué anclar la identidad al *workflow* y no solo al *repositorio* cierra un vector de ataque real?

---

## Ejercicio 7 (capstone) — El pipeline completo en GitHub Actions

**Objetivo:** integrar los seis controles en un único workflow que solo firma y publa si **todos** los gates pasan. Este es el artefacto que la política del Ejercicio 6 verifica en el otro extremo.

1. Estudiá el workflow. Prestá atención a `permissions:` — `id-token: write` es lo que habilita la firma keyless sin claves, y `security-events: write` habilita la subida de SARIF:

   ```yaml
   # .github/workflows/release.yaml
   name: build-scan-sign
   on:
     push:
       branches: [main]

   permissions:
     contents: read          # checkout
     packages: write         # push a GHCR
     id-token: write         # OIDC para firma keyless (Fulcio)
     security-events: write  # subir SARIF a code scanning

   env:
     IMAGE: ghcr.io/${{ github.repository }}

   jobs:
     secure-build:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4

         # --- Gate 1: SCA + SAST (Ejercicio 1) ---
         - name: SCA (dependencias)
           run: trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 .
         - name: SAST
           run: semgrep --config p/owasp-top-ten --error .

         # --- Gate 2: secret scanning (Ejercicio 3) ---
         - name: Secret scan (historial completo)
           uses: gitleaks/gitleaks-action@v2

         # --- Build ---
         - name: Login GHCR
           uses: docker/login-action@v3
           with:
             registry: ghcr.io
             username: ${{ github.actor }}
             password: ${{ secrets.GITHUB_TOKEN }}
         - name: Build & push (por digest)
           id: build
           uses: docker/build-push-action@v6
           with:
             context: .
             push: true
             tags: ${{ env.IMAGE }}:1.0.0

         # --- Gate 3: image scan (Ejercicio 2) ---
         - name: Image scan
           run: trivy image --severity HIGH,CRITICAL --exit-code 1 ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}

         # --- SBOM (Ejercicio 2) ---
         - name: Generar SBOM
           run: syft scan ${{ env.IMAGE }}@${{ steps.build.outputs.digest }} -o cyclonedx-json=sbom.cdx.json

         # --- Firma + attestation (Ejercicios 4 y 5) ---
         - uses: sigstore/cosign-installer@v3
         - name: Firmar imagen (keyless)
           run: cosign sign --yes ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
         - name: Adjuntar SBOM como attestation
           run: |
             cosign attest --yes --type cyclonedx \
               --predicate sbom.cdx.json \
               ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
   ```

2. Trazá el flujo de un commit con una dependencia `CRITICAL`: ¿en qué step muere y por qué nunca se firma nada? (respondé en P7.1).

3. Trazá el flujo de un commit limpio: enumerá, en orden, qué artefactos verificables quedan publicados en el registro al terminar el job (respondé en P7.2).

**Preguntas de comprensión**

- **P7.1** — El orden de los steps no es casual: SCA/SAST y secret scan van **antes** del build; el image scan va **después**. Justificá ese orden desde el costo y desde la regla "content → verify → sign".
- **P7.2** — ¿Por qué es correcto que la firma (`cosign sign`) sea el **último** step y no uno intermedio? ¿Qué invariante del supply chain se rompería si firmaras antes de que pasen los gates?
- **P7.3** — El workflow no guarda ninguna clave privada de firma en `secrets`. Explicá, uniendo Ejercicio 4 y este, cómo firma entonces, y por qué `id-token: write` es el permiso crítico.
- **P7.4** — Conectá los dos extremos: la `subject` de la política Kyverno del Ejercicio 6 debía coincidir *exactamente* con la identidad de este workflow. Escribí cuál sería la `subject` correcta para este `release.yaml` en la rama `main`.

---

## Fuentes oficiales

- Trivy — https://trivy.dev/latest/docs/ · https://github.com/aquasecurity/trivy
- Syft (SBOM) — https://github.com/anchore/syft
- Grype — https://github.com/anchore/grype
- Gitleaks — https://github.com/gitleaks/gitleaks
- Semgrep — https://semgrep.dev/docs/
- Sigstore / Cosign — https://docs.sigstore.dev/ · https://github.com/sigstore/cosign
- SLSA framework — https://slsa.dev/spec/v1.0/levels
- slsa-verifier — https://github.com/slsa-framework/slsa-verifier
- Kyverno `verifyImages` — https://kyverno.io/docs/writing-policies/verify-images/
- CycloneDX — https://cyclonedx.org/ · SPDX — https://spdx.dev/
- SARIF — https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

---

## Respuestas

<details>
<summary>Mostrar respuestas</summary>

### Ejercicio 1

**P1.1** — **SCA** (Software Composition Analysis) analiza el *código que no escribiste*: las dependencias de terceros declaradas en lockfiles (`package-lock.json`, `go.sum`, etc.), cruzándolas contra bases de CVE. **SAST** (Static Application Security Testing) analiza el *código que sí escribiste*, buscando patrones inseguros (SQL injection, uso de `eval`, secretos hardcodeados, criptografía débil) mediante reglas/dataflow. Necesitás los dos porque cubren superficies disjuntas: la mayoría de las vulnerabilidades reales entran por dependencias (SCA no las ve un SAST), pero tus propios bugs de seguridad (SQLi, path traversal) no están en ningún CVE (los ve el SAST, no el SCA).

**P1.2** — Porque son dos políticas de negocio distintas montadas sobre el mismo escaneo. "Reportar" (`--exit-code 0`) da visibilidad sin bloquear —útil para inventariar deuda o en ramas legadas—; "romper el build" (`--exit-code 1`) es el *enforcement*. Separarlos te permite, por ejemplo, empezar en modo reporte, medir el volumen de hallazgos, y recién ahí endurecer el gate por severidad sin que el equipo quede bloqueado de golpe. El exit code **es** el contrato con el runner de CI: el runner no entiende la tabla, entiende el status.

**P1.3** — **SARIF** es un formato estándar (OASIS) que el SCM consume de forma nativa: los hallazgos aparecen anotados en el diff del pull request y en la pestaña de *code scanning*, con historial, deduplicación y estado (open/fixed/dismissed). El log del job es efímero y no correlaciona: se pierde entre corridas, no marca en qué línea del PR está el problema y no lleva registro de si ya fue resuelto o descartado.

**P1.4** — `Status: fixed` significa que el proveedor del paquete **ya publicó una versión corregida** (`Fixed Version`), así que la remediación es un bump de versión y nada más. Es la clase de hallazgo que más querés en un gate porque es *accionable de inmediato*: bloquear un build por un CVE con fix disponible cuesta minutos de resolver, mientras que bloquear por uno sin fix (`will_not_fix`/`affected`) solo genera fricción sin salida clara.

### Ejercicio 2

**P2.1** — `trivy fs` escanea el árbol del proyecto: ve tus lockfiles, pero **no** ve el sistema operativo del base image. `trivy image` desempaqueta las capas de la imagen ya construida y cataloga los paquetes del SO (`apk`/`apt`), del runtime y las libs del base image (`node:18-alpine` → OpenSSL, musl, etc.). La mayoría de los CVE de una imagen viven en esa capa base, invisible hasta que la imagen existe.

**P2.2** — Un **SBOM** es el inventario completo y legible por máquina de todo lo que compone el artefacto: paquetes, versiones, licencias, hashes. Lo que habilita *después* del build: cuando se publica un CVE nuevo (p. ej. un "Log4Shell" en una lib que desplegaste hace seis meses), podés responder *"¿estoy afectado y en qué imágenes?"* consultando SBOMs almacenados, en segundos y sin reconstruir ni re-escanear cada imagen. Sin SBOM esa pregunta requiere volver a escanear todo el inventario de artefactos.

**P2.3** — **Ventaja:** escanear el SBOM es rápido y no requiere pull de la imagen ni acceso al registro; podés re-escanear el mismo SBOM cada noche contra la base de CVE actualizada. **Riesgo:** el SBOM es una *foto* del momento del build; si la imagen se reconstruyó o el tag mutó y el SBOM no se regeneró, estás escaneando un inventario que ya no corresponde a lo que corre en producción. Por eso el SBOM debe atarse criptográficamente a un **digest** inmutable (Ejercicio 5).

**P2.4** — Existen dos estándares por historia y foco: **SPDX** (Linux Foundation, ISO/IEC 5962) nació con énfasis en *licensing* y compliance legal; **CycloneDX** (OWASP) nació con énfasis en *security* y supply chain (soporta VEX, dependencias transitivas, servicios). Criterio: si tu driver principal es análisis de vulnerabilidades y attestations de supply chain, CycloneDX encaja mejor y está mejor soportado por cosign/Grype; si es auditoría de licencias o un requisito regulatorio que nombra SPDX, usás SPDX. Muchas plataformas generan ambos.

### Ejercicio 3

**P3.1** — `gitleaks protect --staged` mira el *diff staged* **antes** de crear el commit: es preventivo, se corre como pre-commit hook y frena el secreto en la máquina del dev, cuando todavía no existe en ningún historial. `gitleaks detect` recorre **todo el historial** del repositorio: es la red de seguridad en CI, porque un hook se puede saltear (`--no-verify`), no todos lo tienen instalado, y un secreto pudo entrar hace cientos de commits. Los dos momentos son complementarios: el hook baja el volumen, CI garantiza que nada pasa igual.

**P3.2** — Controles preventivos, por ejemplo: (1) inyectar credenciales solo en runtime desde un **secret manager** (Vault, cloud KMS, External Secrets) de modo que nunca vivan en un archivo del repo; (2) `.gitignore` de archivos sensibles (`.env`, `*.pem`) más plantillas `*.env.example`; (3) usar **OIDC/workload identity** en vez de tokens estáticos (como la firma keyless del Ejercicio 4), eliminando el secreto de larga vida por completo.

**P3.3** — Porque git es un historial **inmutable y distribuido**: `git rm` + nuevo commit deja el secreto perfectamente accesible en el commit anterior, en cualquier clon, fork o caché del proveedor. La única remediación real es **rotar/revocar la credencial** (invalidarla en el sistema que la emitió) — eso la vuelve inútil sin importar cuántas copias del historial existan. Reescribir el historial (`filter-repo`, force-push) es higiene opcional, pero *nunca* sustituye a la rotación: asumí que el secreto ya fue leído.

### Ejercicio 4

**P4.1** — La firma keyless elimina la **clave privada de larga vida**. En el modelo tradicional guardás una clave en un secret del CI: es un objetivo permanente (si se filtra, el atacante firma malware con tu identidad) y hay que rotarla, custodiarla y auditar su acceso. Keyless usa una identidad **OIDC efímera**: Fulcio emite un certificado válido ~10 minutos atado a esa identidad, se firma, y no queda ninguna clave que robar. De tu superficie de ataque desaparece el secreto de firma entero.

**P4.2** — **Fulcio** es la CA de Sigstore: recibe tu token OIDC (que prueba *quién sos*) y emite un certificado X.509 de corta vida que liga tu identidad a la clave pública efímera con la que firmaste. **Rekor** es el *transparency log*: un log append-only, público y verificable, donde se registra la firma junto con el certificado y un timestamp. Rekor permite verificar **offline** (la prueba de inclusión viaja con el artefacto) y detectar firmas retroactivas o certificados emitidos fuera de ventana, porque la entrada del log es inmutable y con marca temporal —nadie puede fabricar una firma "vieja" a posteriori sin que el log lo delate.

**P4.3** — Un **tag es mutable**: `:1.0.0` puede reapuntarse a otra imagen después de firmar. Si firmás/verificás por tag, un atacante con acceso al registro sube una imagen maliciosa, mueve el tag `1.0.0` hacia ella, y tu firma sobre "1.0.0" pasa a "cubrir" un artefacto que nunca firmaste (o directamente la firma queda huérfana mientras el runtime baja la maliciosa). Firmando por `@sha256:…` la firma cubre exactamente ese contenido: cambiar un byte cambia el digest y rompe la verificación.

**P4.4** — Porque `cosign verify` sin `--certificate-identity`/`--certificate-oidc-issuer` solo comprueba que *existe una firma keyless válida en Rekor*, no **de quién**. Cualquiera —incluido un atacante— puede firmar keyless con *su* identidad de Google/GitHub y esa firma es "válida". El control de seguridad no es "¿está firmada?" sino "¿está firmada por la identidad que yo espero?". Sin fijar identidad y emisor, la verificación no distingue tu build legítimo de uno de un tercero.

### Ejercicio 5

**P5.1** — Firmar una imagen afirma solo "esta identidad respalda este digest". Una **attestation** liga a ese digest un *predicate* estructurado y firmado —el SBOM, un resultado de test, un reporte de scan— de modo que podés verificar no solo *que* alguien respalda la imagen sino *qué afirma* sobre ella ("este es su inventario de componentes según CycloneDX", "pasó estos controles"). Firma = autenticidad del artefacto; attestation = metadatos verificables *sobre* el artefacto.

**P5.2** — La **provenance** (SLSA) describe *cómo se produjo* el artefacto: qué **builder** lo construyó, desde qué **repositorio y commit** de origen, con qué parámetros y disparado por qué evento. Responde "¿de dónde salió esta imagen y quién la construyó?", que un SBOM firmado no responde: el SBOM te dice *qué contiene* la imagen, no *de qué fuente ni con qué proceso* nació. Provenance es la cadena de custodia; SBOM es la lista de materiales.

**P5.3** — Porque si el propio workflow (que el desarrollador controla y que puede estar comprometido) genera su propia provenance, la provenance es tan confiable como el pipeline que dice describir —un atacante con acceso al workflow fabrica una provenance que "prueba" lo que quiera. SLSA en niveles altos exige que la provenance la emita un **builder aislado y de confianza**, en un contexto que el job de usuario no puede manipular (p. ej. un reusable workflow con permisos separados y OIDC del proveedor). Eso la vuelve **no falsificable** aunque el step de build esté comprometido.

**P5.4** — De menor a mayor rigor: (a) imagen firmada keyless < (b) provenance no falsificable por un builder aislado < (c) build reproducible desde fuente versionada. (a) prueba autenticidad pero no origen; (b) sube fuerte hacia los niveles intermedios/altos de SLSA porque ata el artefacto a fuente + builder de forma resistente a manipulación; (c) la reproducibilidad permite que un tercero *re-derive* el mismo digest desde la fuente, el mayor grado de garantía. Cada control agrega una propiedad que el anterior no daba.

### Ejercicio 6

**P6.1** — El CI solo controla lo que pasa *por* el CI. El admission control es el punto donde el **cluster** —no tu pipeline— decide qué corre. Garantiza la propiedad que el CI no puede: *ninguna* imagen se ejecuta sin la firma esperada, incluidas las que un operador despliega a mano, las que trae un Helm chart de terceros, o las que un atacante intenta correr saltándose el pipeline por completo. Es la diferencia entre "mis builds firman" y "mi cluster **exige** firma".

**P6.2** — `mutateDigest: true` reescribe el tag de la imagen al **digest** que Kyverno verificó, y lo persiste en la spec del Pod. Sin eso, verificás `:1.0.0` en admission pero el kubelet podría bajar una imagen distinta si el tag mutó entre la verificación y el pull (TOCTOU / *time-of-check-to-time-of-use*). Pinneando a digest, lo que se admitió y lo que corre son bit-a-bit lo mismo. Es la misma defensa de P4.3, aplicada en runtime.

**P6.3** — `failurePolicy: Fail` (fail-closed) prioriza **seguridad sobre disponibilidad**: si el webhook está caído no se admite nada, lo que puede frenar despliegues legítimos durante una caída de Kyverno. `Ignore` (fail-open) prioriza disponibilidad: si el webhook cae, los Pods se admiten *sin verificar*, abriendo una ventana para colar imágenes sin firma. En un cluster de producción con datos sensibles elegís `Fail` (y le das HA a Kyverno); `Ignore` solo tiene sentido en entornos donde una caída del control de admisión no puede permitirse bloquear el negocio y aceptás el riesgo conscientemente.

**P6.4** — Anclar solo al repositorio permitiría que **cualquier** workflow del repo —incluido uno malicioso agregado en un PR, o un workflow de test con menos revisión— produzca una firma que la política acepta. Al fijar la `subject` al archivo de workflow *y* al `ref` (`release.yaml@refs/heads/main`), solo las firmas emitidas por ese workflow concreto corriendo en `main` son válidas. Cierra el vector de un atacante que agrega un `.github/workflows/evil.yaml` al repo y firma con la identidad OIDC del mismo repositorio.

### Ejercicio 7

**P7.1** — Los gates baratos y que no dependen de la imagen van primero para **fallar rápido y barato**: SCA, SAST y secret scanning corren sobre el checkout en segundos y evitan gastar minutos de build/push por algo que ya sabíamos que iba a romper. El image scan necesita la imagen construida, así que va después por fuerza. Y responde a la regla **content → verify → sign**: primero existe el artefacto verificado, recién entonces se lo firma; escanear la imagen *antes* de firmar garantiza que nunca firmás algo con un CVE crítico conocido.

**P7.2** — Porque la firma es la afirmación *"todo lo anterior pasó y respaldo este artefacto"*. Si firmaras antes de los gates, estarías respaldando criptográficamente una imagen que todavía no pasó el scan —y como cada step posterior puede fallar, terminarías con firmas válidas sobre imágenes que resultaron inseguras. La firma debe ser lo último para que su existencia sea prueba de que **todos** los controles se cumplieron. En un commit con dependencia `CRITICAL`, el job muere en el step "SCA" (`--exit-code 1`), antes del build: nunca se construye, ni se firma, ni se publica nada firmado.

*(Complemento a la traza del paso 3, commit limpio):* quedan publicados, atados al mismo digest inmutable: la imagen, su **firma** keyless (verificable contra Rekor) y una **attestation** de tipo CycloneDX con el SBOM.

**P7.3** — No hay clave porque la firma es **keyless**: `id-token: write` autoriza al runner a pedir un **token OIDC** de GitHub que prueba la identidad del workflow. Cosign presenta ese token a **Fulcio**, que emite un certificado efímero, se firma, y la entrada va a **Rekor**. Sin `id-token: write` el runner no puede obtener el token OIDC y la firma keyless es imposible —por eso es el permiso crítico, más que `packages: write`. Es exactamente el mecanismo del Ejercicio 4, pero con la identidad del *workflow* en vez de la de una persona.

**P7.4** — La `subject` correcta para este workflow en `main` sería:

```
https://github.com/<owner>/<repo>/.github/workflows/release.yaml@refs/heads/main
```

es decir, para el repo `${{ github.repository }}` del ejemplo: `https://github.com/myorg/demo/.github/workflows/release.yaml@refs/heads/main`, con `issuer: https://token.actions.githubusercontent.com`. Debe coincidir carácter por carácter con la `subject` de la `ClusterPolicy` del Ejercicio 6 para que las imágenes que este pipeline firma sean —y solo esas— las que el cluster admite.

</details>