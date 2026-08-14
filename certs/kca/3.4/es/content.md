# 3.4 — Instalando la Kyverno CLI

> **Dominio 3 · Kyverno CLI** — Peso en el examen para esta competencia: **3.0**
> Perfil objetivo: SRE / Platform Engineer que opera Kyverno como sistema de admission-control y policy-as-code en muchos clústeres y pipelines de CI.

---

## 1. Motivación: el problema arquitectónico que la CLI existe para resolver

El runtime primario de Kyverno es un **admission controller in-cluster**. Las policies (`ClusterPolicy`, `Policy`, `ValidatingPolicy`, `ImageValidatingPolicy`, más las variantes generate/mutate) son reconciliadas por los controllers de Kyverno, conectadas al API server mediante objetos `ValidatingWebhookConfiguration` y `MutatingWebhookConfiguration`, y evaluadas **sincrónicamente en cada admission request que coincida**.

Ese runtime es exactamente el lugar equivocado para *desarrollar y probar* una policy:

- **El feedback loop pasa por el API server.** Para averiguar si una policy `require-run-as-nonroot` realmente rechaza un Deployment defectuoso, tenés que hacer `kubectl apply` sobre un clúster en vivo cuyo webhook ya está reconciliado — un round trip de varios segundos que depende de RBAC, del TLS del webhook y de la salud del controller.
- **El blast radius es producción.** Una policy en modo `Enforce` que está sutilmente mal no falla en un test harness; falla bloqueando la admisión de workloads reales, o mutando objetos en vivo. No existe un dry run que sea a la vez *offline* e *idéntico* al camino de admisión.
- **CI/CD no puede hacer gating sobre eso.** Un pull request que cambia una policy necesita un veredicto *antes* del merge, en un runner que no tiene clúster, ni `kubeconfig`, ni egress de red hacia el API server.
- **No es reproducible.** "¿Pasa esta policy?" debe tener una respuesta determinista y versionada que un pipeline pueda afirmar en un entorno air-gapped, independiente del estado en vivo de cualquier clúster.

La **Kyverno CLI** (`kyverno`) resuelve esto embebiendo el *mismo policy engine* que usan los controllers in-cluster dentro de un binario standalone. Evalúa policies contra manifiestos estáticos en disco — sin API server, sin webhook, sin clúster — y devuelve veredictos pass/fail/skip/error. Esto es lo que hace posible el **policy-as-code shift-left**: los autores iteran localmente en milisegundos, CI hace gating sobre cada PR, y se puede fijar la misma versión exacta del engine en el pipeline y en el clúster, de modo que "pasa en CI" signifique "pasa en admisión".

**Instalar la CLI no es, por lo tanto, un paso de conveniencia — es el punto de entrada a todo el workflow test/apply/jp (`kyverno test`, `kyverno apply`, `kyverno jp`, `kyverno json`, `kyverno oci`, `kyverno fix`).** Toda otra competencia de CLI en el Dominio 3 depende de poner este binario en el host correcto, en la versión correcta, desde una supply chain verificada.

### El invariante de version-skew

La restricción de producción más importante: **la CLI es un build específico del engine de Kyverno, y el engine cambia entre releases.** Una policy que usa una función JMESPath, un constructo `matchExpressions`, o un campo `ValidatingPolicy` introducido en el engine v1.13 será *mal juzgada* por una CLI v1.11. La regla que hace que CI sea significativo:

> Fijá la versión de la CLI a la **misma línea minor** que el controller de Kyverno que corre en el clúster objetivo. Si el clúster corre `v1.13.x`, hacé gating de los PRs con una CLI `v1.13.x`. De lo contrario, "verde en CI" es una mentira que el admission webhook contradirá después.

---

## 2. Métodos de instalación — trade-offs técnicos

Hay cinco caminos de adquisición soportados. Difieren en **superficie de invocación**, **precisión del version-pinning**, **verificabilidad de la supply chain** y **aptitud para air-gap** — las cuatro dimensiones que le importan a un platform team.

| Método | Invocación | Version pinning | Verificación de supply chain | Air-gap / offline | Toolchain requerido | Mejor encaje |
|---|---|---|---|---|---|---|
| **Krew** (`kubectl krew install kyverno`) | `kubectl kyverno …` | Manifiesto del Krew-index; **va por detrás de upstream**, grueso | SHA256 del krew-index sobre el archivo | Necesita krew + un index espejado | `kubectl` + krew | Laptops de ingenieros ya estandarizadas en plugins de kubectl |
| **Homebrew** (`brew install kyverno`) | `kyverno …` | Versión de la formula; **va por detrás de upstream** | SHA del bottle (gestionado por Homebrew) | No | Homebrew | Laptops de dev macOS / Linux, arranque rápido |
| **Binario de release directo** (tarball del release de GitHub) | `kyverno …` | **Tag exacto que elijas** | **cosign keyless + `checksums.txt`** | **Sí** — espejá el tarball | `curl`, `tar`, (`cosign` recomendado) | Runners de CI, pipelines reproducibles / regulados |
| **`go install`** | `kyverno …` | Versión del módulo de Go | sumdb del módulo de Go (`go.sum`) | Necesita Go + un module proxy | Toolchain de Go | Contribuidores compilando desde el fuente; bleeding edge |
| **Imagen de contenedor** (`ghcr.io/kyverno/kyverno-cli`) | `docker run … kyverno …` | **Tag o `@sha256` digest** | **Imagen firmada con cosign + SBOM** | **Sí** — espejá la imagen | Container runtime | CI sin instalaciones en el host; runners efímeros, herméticos |

### 2.1 Por qué la CLI le gana a "simplemente aplicarlo a un clúster"

La razón por la que la CLI es una competencia de primera clase, expresada como tabla de decisión:

| Dimensión | Admisión in-cluster (aplicar a clúster en vivo) | Kyverno CLI (evaluación offline) |
|---|---|---|
| Latencia del feedback | Segundos; a través del API server + TLS del webhook | Milisegundos; proceso local |
| Blast radius | Puede bloquear/mutar workloads **reales** | **Ninguno** — evaluación estática pura |
| Prerrequisitos | Clúster alcanzable, `kubeconfig` válido, RBAC, webhook sano | Un binario y archivos en disco |
| Gating de CI/CD | Necesita un clúster efímero (kind/k3d) por corrida | Corre en cualquier runner, sin clúster |
| Determinismo | Depende del estado en vivo del clúster | Determinista para una CLI fijada + inputs |
| Air-gap | Requiere clúster + red | Solo binario + manifiestos |

### 2.2 Superficie de invocación — la que hace tropezar a la gente

Krew instala el **mismo binario** pero lo expone como un plugin de `kubectl`, así que el comando es **`kubectl kyverno …`**. Todo otro método instala un binario standalone invocado como **`kyverno …`**. Los scripts y pasos de CI escritos para una forma se rompen silenciosamente con la otra. Estandarizá en una por entorno y documentala.

---

## 3. Infraestructura de instalación completa, grado producción

Los ejemplos de abajo fijan un **release concreto** (`v1.13.4` se usa a modo ilustrativo). En producción, *nunca* hardcodees "latest" — resolvé y congelá un tag explícito. El mecanismo para descubrir el tag latest actual (para que el material se mantenga correcto entre releases):

```bash
$ curl -sSL https://api.github.com/repos/kyverno/kyverno/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+'
v1.13.4
```

### 3.1 Instalación de binario directo verificada (el método de referencia para CI)

Este es el camino endurecido en supply chain: descargar → **verificar checksum** → **verificar firma cosign** → instalar en `PATH`.

```bash
#!/usr/bin/env bash
# install-kyverno-cli.sh — reproducible, verified Kyverno CLI install
set -euo pipefail

VERSION="v1.13.4"
OS="linux"           # linux | darwin | windows
ARCH="x86_64"        # x86_64 | arm64  (NOTE: x86_64, not amd64)
BASE="https://github.com/kyverno/kyverno/releases/download/${VERSION}"
ARCHIVE="kyverno-cli_${VERSION}_${OS}_${ARCH}.tar.gz"

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT; cd "$workdir"

# 1. Fetch the archive and the release checksum + cosign artifacts
curl -fsSLO "${BASE}/${ARCHIVE}"
curl -fsSLO "${BASE}/checksums.txt"
curl -fsSLO "${BASE}/checksums.txt.pem"
curl -fsSLO "${BASE}/checksums.txt.sig"

# 2. Integrity: the archive must match its published SHA-256
sha256sum -c checksums.txt --ignore-missing

# 3. Provenance: keyless cosign signature over the checksum file
#    (proves the checksums were produced by Kyverno's release workflow)
cosign verify-blob \
  --certificate       checksums.txt.pem \
  --signature         checksums.txt.sig \
  --certificate-identity-regexp='^https://github.com/kyverno/kyverno' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  checksums.txt

# 4. Extract and install
tar -xzf "${ARCHIVE}"                       # yields: LICENSE  README.md  kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno

# 5. Prove the engine version
kyverno version
```

Sesión de terminal esperada:

```console
$ ./install-kyverno-cli.sh
kyverno-cli_v1.13.4_linux_x86_64.tar.gz: OK
Verified OK
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

Los dos pasos de verificación son la diferencia entre "corremos un binario cualquiera de internet en nuestro release pipeline" y una supply chain defendible. `sha256sum -c` atrapa corrupción/truncamiento; `cosign verify-blob` atrapa un archivo *intercambiado* al probar que el propio manifiesto de checksums vino del workflow de release de GitHub Actions de Kyverno (identidad keyless de Sigstore).

### 3.2 Krew

```console
$ kubectl krew install kyverno
Updated the local copy of plugin index.
Installing plugin: kyverno
Installed plugin: kyverno
\
 | Use this plugin:
 | 	kubectl kyverno
 | Documentation:
 | 	https://github.com/kyverno/kyverno
/
WARNING: You installed plugin "kyverno" from the krew-index plugin repository.
   These plugins are not audited for security by the Krew maintainers.
   Run them at your own risk.

$ kubectl kyverno version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

> ¿`kubectl kyverno: command not found`? Krew instala en `~/.krew/bin`, que debe estar en `PATH`. Ver §5.

### 3.3 Homebrew (laptops de dev macOS / Linux)

```console
$ brew install kyverno
==> Fetching kyverno
==> Downloading https://ghcr.io/v2/homebrew/core/kyverno/manifests/1.13.4
==> Pouring kyverno--1.13.4.arm64_sonoma.bottle.tar.gz
🍺  /opt/homebrew/Cellar/kyverno/1.13.4: 6 files, 46.1MB
$ kyverno version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

Homebrew sigue a upstream con retraso; cuando necesitás una versión *exacta* del engine para coincidir con un clúster, preferí §3.1.

### 3.4 `go install` (contribuidores / compilando desde el fuente)

```console
$ go install github.com/kyverno/kyverno/cmd/cli/kyverno@v1.13.4
go: downloading github.com/kyverno/kyverno v1.13.4
$ kyverno version
Version:
Time:
Git commit ID:
```

**Gotcha de diagnóstico — esperado y correcto:** `go install` **no** inyecta los `ldflags` del release, así que `kyverno version` imprime metadata de versión **vacía**. El binario funciona, pero no puede reportar su propia versión. Esto rompe cualquier aserción de CI de la forma `kyverno version | grep 1.13`. Para pipelines que deben *probar* la versión del engine, usá §3.1 o §3.6, no `go install`.

### 3.5 GitHub Actions — la action oficial de instalación (gate de CI)

Kyverno publica una action de primera parte, `kyverno/action-install-cli`, para que los pipelines no reimplementen §3.1:

```yaml
# .github/workflows/policy-gate.yaml
name: kyverno-policy-gate
on:
  pull_request:
    paths: ["policies/**", "manifests/**"]

permissions:
  contents: read

jobs:
  validate-policies:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          # Pin to the SAME minor line as the in-cluster controller.
          release: v1.13.4

      - name: Verify installed version (fail closed on skew)
        run: |
          set -euo pipefail
          kyverno version
          kyverno version | grep -q 'Version: 1.13' \
            || { echo "::error::Kyverno CLI version skew"; exit 1; }

      - name: Run policy test suites
        run: kyverno test ./policies --detailed-results

      - name: Evaluate policies against candidate manifests
        run: |
          kyverno apply ./policies \
            --resource ./manifests \
            --policy-report \
            --warn-exit-code 0 \
            --fail-exit-code 1
```

### 3.6 Imagen de contenedor — CI hermético, sin instalación en el host

Para runners donde no podés (o no querés) instalar binarios en el host, corré la CLI como una imagen fijada y firmada. **Fijá por digest**, no solo por tag, para inmutabilidad:

```console
$ docker run --rm \
    ghcr.io/kyverno/kyverno-cli:v1.13.4@sha256:9f2c...e41 \
    version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

Montando el workspace para evaluar policies/manifiestos locales:

```console
$ docker run --rm -v "$PWD:/work" -w /work \
    ghcr.io/kyverno/kyverno-cli:v1.13.4 \
    test ./policies --detailed-results
```

Verificá la imagen del mismo modo en que verificarías cualquier artefacto firmado por Kyverno:

```console
$ cosign verify \
    --certificate-identity-regexp='^https://github.com/kyverno/kyverno' \
    --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
    ghcr.io/kyverno/kyverno-cli:v1.13.4 | jq '.[0].optional.Subject'
"https://github.com/kyverno/kyverno/.github/workflows/release.yaml@refs/tags/v1.13.4"
```

Un `Dockerfile` multi-stage que hornea una CLI fijada dentro de una imagen de policy-tooling:

```dockerfile
# syntax=docker/dockerfile:1
FROM ghcr.io/kyverno/kyverno-cli:v1.13.4 AS cli

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=cli /ko-app/kyverno /usr/local/bin/kyverno
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/kyverno"]
```

### 3.7 Instalación air-gapped

Sin internet en el host objetivo. Hacé el trabajo de red una sola vez, en una máquina de staging conectada, luego transportá:

```bash
# --- on a connected host: fetch, verify, and stage the artifact ---
VERSION="v1.13.4"
BASE="https://github.com/kyverno/kyverno/releases/download/${VERSION}"
for f in \
    "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" \
    checksums.txt checksums.txt.pem checksums.txt.sig ; do
  curl -fsSLO "${BASE}/${f}"
done
sha256sum -c checksums.txt --ignore-missing
tar -czf kyverno-cli-airgap-${VERSION}.tgz \
    "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" \
    checksums.txt checksums.txt.pem checksums.txt.sig
sha256sum kyverno-cli-airgap-${VERSION}.tgz > transfer.sha256
# --- transport kyverno-cli-airgap-*.tgz + transfer.sha256 across the boundary ---
```

En el host aislado, re-verificá `transfer.sha256`, extraé, re-ejecutá `sha256sum -c checksums.txt --ignore-missing`, luego `install -m 0755 kyverno /usr/local/bin/`. Para el camino de contenedor, `docker pull … && docker save` de la imagen fijada por digest, transportá el tarball, `docker load` del otro lado, y espejala en el registry interno.

---

## 4. `kyverno version` — leyendo la salida como un operador

```console
$ kyverno version
Version: 1.13.4                      # engine build; MUST align with the cluster controller's minor line
Time: 2024-11-12T10:30:42Z           # build timestamp (empty for `go install` builds)
Git commit ID: main/3d3a9c7f1b2e...  # exact source revision
```

Comparalo contra el controller in-cluster para detectar el skew antes de que te muerda:

```console
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
ghcr.io/kyverno/kyverno:v1.13.4
```

Si la CLI reporta `1.13.x` y la imagen del controller es `v1.13.x`, tus veredictos de CI son confiables. Si divergen a través de una línea minor, tratá cada "pass" como no verificado.

---

## 5. Verificación & diagnóstico de fallas

| Síntoma (terminal) | Causa raíz | Solución |
|---|---|---|
| `kyverno: command not found` | Binario no en `PATH` | Confirmá el dir de instalación (`/usr/local/bin`); `echo $PATH`; `command -v kyverno` |
| `kubectl kyverno: command not found` (después de krew) | `~/.krew/bin` no en `PATH` | `export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"` en el shell profile |
| `bash: .../kyverno: cannot execute binary file: Exec format error` | Arquitectura de CPU equivocada (ej. tarball `x86_64` en `arm64`) | Hacé coincidir `ARCH`; verificá con `uname -m` |
| `kyverno-cli_..._linux_x86_64.tar.gz: FAILED` de `sha256sum -c` | Descarga corrupta/truncada o asset equivocado | Re-descargá; confirmá `Content-Length`; revisá mangling de proxy/CDN |
| `cosign verify-blob` → `Error: … no matching signatures` | Regexp de identity/issuer equivocado, o checksum manipulado | Usá el identity-regexp/issuer de §3.1; asegurate de que `.pem`/`.sig` correspondan al mismo release |
| `kyverno version` imprime `Version:` vacío | Compilado vía `go install` (sin ldflags de release) | Usá el binario de release de §3.1 o la imagen de §3.6 cuando la versión deba ser afirmable |
| El veredicto de la CLI difiere de la admisión del clúster | **Version skew** CLI ↔ controller | Fijá la CLI a la línea minor del controller (§4) |
| `kyverno test` da error en un campo que los docs describen | CLI más vieja que el schema de la policy usado | Actualizá la CLI al release que introdujo el campo |
| `kubectl krew: command not found` | Krew mismo no instalado | Instalá Krew según krew.sigs.k8s.io, luego `kubectl krew install kyverno` |

**Smoke test post-instalación** — prueba que el binario no solo corre sino que *evalúa* correctamente, de punta a punta:

```console
$ cat > /tmp/pol.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "The label 'team' is required."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF

$ cat > /tmp/good.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: ok
  labels: { team: platform }
spec:
  containers: [{ name: app, image: nginx:1.27 }]
EOF

$ cat > /tmp/bad.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: missing-label
spec:
  containers: [{ name: app, image: nginx:1.27 }]
EOF

$ kyverno apply /tmp/pol.yaml --resource /tmp/good.yaml --resource /tmp/bad.yaml

Applying 1 policy rule(s) to 2 resource(s)...

policy require-labels -> resource default/Pod/ok passed
policy require-labels -> resource default/Pod/missing-label failed:
1. require-team-label: validation error: The label 'team' is required.

pass: 1, fail: 1, warn: 0, error: 0, skip: 0

$ echo "exit: $?"
exit: 1
```

Un exit no-cero en el recurso que falla confirma que el engine está cableado correctamente y puede confiarse como gate de CI (el exit code del proceso es sobre lo que un pipeline hace su aserción).

---

## 6. Referencias

- Kyverno CLI — instalación & uso: https://kyverno.io/docs/kyverno-cli/
- Kyverno CLI — métodos de instalación: https://kyverno.io/docs/kyverno-cli/install/
- Kyverno releases (binarios, `checksums.txt`, cosign `.pem`/`.sig`): https://github.com/kyverno/kyverno/releases
- Kyverno fuente — paquete de la CLI (`cmd/cli/kyverno`): https://github.com/kyverno/kyverno
- Imagen de contenedor de Kyverno (CLI): https://github.com/kyverno/kyverno/pkgs/container/kyverno-cli
- GitHub Action oficial install-CLI: https://github.com/kyverno/action-install-cli
- Krew — gestor de plugins de kubectl: https://krew.sigs.k8s.io/
- Entrada del Krew index (kyverno): https://krew.sigs.k8s.io/plugins/
- Sigstore cosign — verificando blobs e imágenes: https://docs.sigstore.dev/
- Currículum KCA (Kyverno Certified Associate): https://github.com/cncf/curriculum
- Raíz de la documentación de Kyverno: https://kyverno.io/docs/