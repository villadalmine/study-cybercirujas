# 701.5 — Composición de Software, Licenciamiento y Código Abierto

## Ejercicios Guiados

**Examen:** LPI DevOps Tools Engineer 701-100, versión 2.0.0 · **Peso:** 3.34
**Referencia del objetivo:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estos ejercicios son ejecutables. Cada comando fue escrito contra una estación de trabajo Linux x86_64 con acceso de red a registros públicos. Las salidas mostradas son *ilustrativas*: las cadenas de versión, los recuentos de vulnerabilidades y los digests cambian a diario, así que fijate en la **forma** de la salida, no en los bytes literales.

---

## Entorno de laboratorio

| Herramienta | Propósito | Upstream |
|---|---|---|
| `syft` | Generación de SBOM (SPDX, CycloneDX) | <https://github.com/anchore/syft> |
| `grype` | Correlación de vulnerabilidades contra un SBOM | <https://github.com/anchore/grype> |
| `osv-scanner` | Correlación de vulnerabilidades contra OSV.dev | <https://google.github.io/osv-scanner/> |
| `trivy` | Escaneo de imágenes incl. detección de licencias | <https://trivy.dev/> |
| `cosign` | Firma, atestación, verificación | <https://docs.sigstore.dev/cosign/system_config/installation/> |
| `reuse` | Linting de conformidad REUSE 3.x | <https://reuse.software/> |
| `jq` | Inspección de JSON | <https://jqlang.github.io/jq/> |

### Pasos

1. Creá un espacio de trabajo aislado y registralo como variable de entorno usada por todos los ejercicios posteriores.

   ```bash
   export LAB=~/lab-701.5
   mkdir -p "$LAB"/{bin,artifacts,app}
   cd "$LAB"
   export PATH="$LAB/bin:$PATH"
   ```

2. Instalá las herramientas de Anchore en el `bin/` local del laboratorio para que nada termine en rutas del sistema.

   ```bash
   curl -sSfL https://get.anchore.io/syft  | sh -s -- -b "$LAB/bin"
   curl -sSfL https://get.anchore.io/grype | sh -s -- -b "$LAB/bin"
   ```

3. Instalá el resto de las herramientas. Preferí los paquetes de tu distribución donde existan; las alternativas de abajo son binarios de release upstream.

   ```bash
   # Trivy (Aqua Security) — see https://trivy.dev/latest/getting-started/installation/
   curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
     | sh -s -- -b "$LAB/bin"

   # Cosign (Sigstore)
   curl -sSfLo "$LAB/bin/cosign" \
     https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   chmod +x "$LAB/bin/cosign"

   # OSV-Scanner (Google)
   curl -sSfLo "$LAB/bin/osv-scanner" \
     https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64
   chmod +x "$LAB/bin/osv-scanner"

   # REUSE tool (FSFE)
   python3 -m venv "$LAB/.venv" && "$LAB/.venv/bin/pip" -q install reuse
   ln -sf "$LAB/.venv/bin/reuse" "$LAB/bin/reuse"
   ```

4. Verificá que la cadena de herramientas responda.

   ```bash
   for t in syft grype trivy cosign osv-scanner reuse; do printf '%-12s ' "$t"; "$t" --version 2>&1 | head -1; done
   ```

   ```text
   syft         syft 1.18.1
   grype        grype 0.87.0
   trivy        Version: 0.58.2
   cosign       GitVersion:    v2.4.1
   osv-scanner  osv-scanner version: 1.9.2
   reuse        reuse 5.0.2
   ```

> **Control de comprensión — Bloque 0**
>
> **Q0.1** Las seis herramientas de arriba se descargan por HTTPS desde un endpoint del proveedor y se ejecutan de inmediato. Nombrá el riesgo de cadena de suministro que esto introduce y los dos artefactos de verificación que exigirías antes de ejecutar cualquiera de ellas en un pipeline de CI.
> **Q0.2** ¿Por qué un `bin/` local a la herramienta con un `PATH` antepuesto es el patrón correcto para un laboratorio, y qué antipatrón de producción reproduce si hacés lo mismo dentro de una imagen de build?

---

## Ejercicio 1 — Construir un proyecto políglota y generar su SBOM en ambos formatos

El sentido de este ejercicio es que **el formato de SBOM es una elección de serialización, no semántica** — pero los dos formatos dominantes discrepan en cuánto te permiten decir.

### Pasos

1. Creá una pequeña aplicación Python con dependencias fijadas y de licencias deliberadamente mixtas.

   ```bash
   cd "$LAB/app"
   cat > requirements.txt <<'EOF'
   requests==2.31.0
   Flask==2.2.5
   PyYAML==6.0.1
   paramiko==3.4.0
   chardet==5.2.0
   EOF
   ```

2. Materializá el árbol de dependencias en un virtualenv para que el escáner tenga metadatos instalados reales para leer (no solo un archivo de declaración).

   ```bash
   python3 -m venv "$LAB/app/.venv"
   "$LAB/app/.venv/bin/pip" -q install -r requirements.txt
   "$LAB/app/.venv/bin/pip" list --format=freeze | wc -l
   ```

   ```text
   17
   ```

3. Generá un SBOM **CycloneDX** (OWASP; estandarizado como ECMA-424) y un SBOM **SPDX** (Linux Foundation; SPDX 2.2.1 es ISO/IEC 5962:2021) desde el mismo directorio.

   ```bash
   cd "$LAB"
   syft dir:"$LAB/app" -o cyclonedx-json="$LAB/artifacts/app.cdx.json" \
                       -o spdx-json="$LAB/artifacts/app.spdx.json" \
                       -o table
   ```

   ```text
    ✔ Indexed file system                    /home/user/lab-701.5/app
    ✔ Cataloged contents      3f7c1a2b9e04d5c6a8b1f0e2d3c4b5a6978869fa0b1c2d3e4f5061728394a5b6
      ├── ✔ Packages                        [17 packages]
      └── ✔ Executables                     [0 executables]

   NAME                VERSION   TYPE
   Flask               2.2.5     python
   Jinja2              3.1.4     python
   MarkupSafe          2.1.5     python
   PyNaCl              1.5.0     python
   PyYAML              6.0.1     python
   Werkzeug            3.0.6     python
   bcrypt              4.2.0     python
   certifi             2024.8.30 python
   cffi                1.17.1    python
   chardet             5.2.0     python
   charset-normalizer  3.4.0     python
   cryptography        43.0.1    python
   idna                3.10      python
   paramiko            3.4.0     python
   pycparser           2.22      python
   requests            2.31.0    python
   urllib3             2.2.3     python
   ```

4. Compará los metadatos de identidad de nivel superior de ambos documentos.

   ```bash
   jq '{format: .bomFormat, spec: .specVersion, serial: .serialNumber, tool: .metadata.tools}' \
     "$LAB/artifacts/app.cdx.json"
   jq '{spdxVersion, dataLicense, name: .name, ns: .documentNamespace, creators: .creationInfo.creators}' \
     "$LAB/artifacts/app.spdx.json"
   ```

   ```text
   {
     "format": "CycloneDX",
     "spec": "1.6",
     "serial": "urn:uuid:6b0f2e5a-9c31-4c0a-9a7d-2e51f8c0b4d1",
     "tool": { "components": [ { "type": "application", "name": "syft", "version": "1.18.1" } ] }
   }
   {
     "spdxVersion": "SPDX-2.3",
     "dataLicense": "CC0-1.0",
     "name": "/home/user/lab-701.5/app",
     "ns": "https://anchore.com/syft/dir/home/user/lab-701.5/app-1c9a...",
     "creators": [ "Organization: Anchore, Inc", "Tool: syft-1.18.1" ]
   }
   ```

5. Contá los componentes de cada uno y confirmá que coinciden.

   ```bash
   jq '.components | length' "$LAB/artifacts/app.cdx.json"
   jq '[.packages[] | select(.name != "app")] | length' "$LAB/artifacts/app.spdx.json"
   ```

   ```text
   17
   17
   ```

> **Control de comprensión — Bloque 1**
>
> **Q1.1** `dataLicense` en el documento SPDX es `CC0-1.0` y la especificación SPDX *exige* ese valor. ¿Qué problema resuelve esa restricción, y por qué `"dataLicense": "Proprietary"` anularía por completo el propósito de publicar un SBOM?
> **Q1.2** El documento CycloneDX lleva un `serialNumber` (un URN UUID) y SPDX lleva un `documentNamespace` (una URI). Ambos son obligatorios. ¿Qué propiedad de identidad aportan que un nombre de archivo no puede dar, y por qué importa cuando el mismo artefacto se reconstruye cada noche?
> **Q1.3** El paso 2 instala las dependencias antes de escanear. Si hubieras escaneado solo `requirements.txt`, `syft` igual habría producido un SBOM. Nombrá dos diferencias concretas de exactitud entre un SBOM derivado de un archivo de declaración y uno derivado de un árbol instalado.
> **Q1.4** ¿Cuál de estos dos formatos elegirías para llevar una sección de *vulnerabilidades* dentro del propio SBOM, y por qué esto siquiera es una pregunta?

---

## Ejercicio 2 — Leer el SBOM como un auditor: purl, CPE y campos de licencia

Un SBOM solo sirve si cada componente es *identificable* y *atribuible*. Este ejercicio separa ambas cosas.

### Pasos

1. Extraé la Package URL (purl) de cada componente. La especificación purl está en <https://github.com/package-url/purl-spec>.

   ```bash
   jq -r '.components[] | "\(.purl)"' "$LAB/artifacts/app.cdx.json" | sort | head -6
   ```

   ```text
   pkg:pypi/bcrypt@4.2.0
   pkg:pypi/certifi@2024.8.30
   pkg:pypi/cffi@1.17.1
   pkg:pypi/charset-normalizer@3.4.0
   pkg:pypi/chardet@5.2.0
   pkg:pypi/cryptography@43.0.1
   ```

2. Ahora extraé las licencias declaradas, y notá que algunos componentes reportan un **id** SPDX, otros una **expresión** SPDX, y otros solo texto libre.

   ```bash
   jq -r '.components[] | [.name, ( .licenses // [] | map(.license.id // .license.name // .expression) | join(" | ") )] | @tsv' \
     "$LAB/artifacts/app.cdx.json" | column -t -s $'\t'
   ```

   ```text
   Flask               BSD-3-Clause
   Jinja2              BSD-3-Clause
   MarkupSafe          BSD-3-Clause
   PyNaCl              Apache-2.0
   PyYAML              MIT
   Werkzeug            BSD-3-Clause
   bcrypt              Apache-2.0
   certifi             MPL-2.0
   cffi                MIT
   chardet             LGPL-2.1-or-later
   charset-normalizer  MIT
   cryptography        Apache-2.0 OR BSD-3-Clause
   idna                BSD-3-Clause
   paramiko            LGPL-2.1-or-later
   pycparser           BSD-3-Clause
   requests            Apache-2.0
   urllib3             MIT
   ```

3. Aislá los componentes que **no** son permisivos — esta es la lista que genera obligaciones.

   ```bash
   jq -r '.components[] | select( (.licenses // []) | tostring | test("GPL|MPL|EPL|CDDL"; "i") ) | "\(.name)\t\(.version)"' \
     "$LAB/artifacts/app.cdx.json"
   ```

   ```text
   certifi   2024.8.30
   chardet   5.2.0
   paramiko  3.4.0
   ```

4. Confirmá que los identificadores de licencia legibles por máquina sean identificadores SPDX válidos contra la lista oficial en <https://spdx.org/licenses/>.

   ```bash
   curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json \
     | jq -r '.licenses[] | select(.licenseId=="LGPL-2.1-or-later" or .licenseId=="MPL-2.0" or .licenseId=="BSD-3-Clause")
              | [.licenseId, (.isOsiApproved|tostring), (.isFsfLibre|tostring), (.isDeprecatedLicenseId|tostring)] | @tsv'
   ```

   ```text
   BSD-3-Clause        true   true   false
   LGPL-2.1-or-later   true   true   false
   MPL-2.0             true   true   false
   ```

5. Demostrá la trampa de la obsolescencia. `LGPL-2.1` (a secas) y `GPL-2.0` (a secas) son identificadores **obsoletos** porque son ambiguos respecto de la cláusula "or later".

   ```bash
   curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json \
     | jq -r '.licenses[] | select(.isDeprecatedLicenseId==true and (.licenseId|test("^(GPL|LGPL|AGPL)-[0-9]")))
              | [.licenseId, .name] | @tsv' | head -6
   ```

   ```text
   AGPL-1.0    Affero General Public License v1.0
   AGPL-3.0    GNU Affero General Public License v3.0
   GPL-2.0     GNU General Public License v2.0
   GPL-3.0     GNU General Public License v3.0
   LGPL-2.1    GNU Lesser General Public License v2.1
   ```

> **Control de comprensión — Bloque 2**
>
> **Q2.1** `cryptography` reporta `Apache-2.0 OR BSD-3-Clause`. Como consumidor aguas abajo, ¿a qué te obliga el `OR`, y a qué te habría obligado un `AND`? ¿Cuál de los dos registrás en tu inventario de conformidad?
> **Q2.2** Explicá con precisión por qué SPDX declaró obsoleto el identificador `GPL-2.0` a secas en favor de `GPL-2.0-only` y `GPL-2.0-or-later`. Dá una decisión de licenciamiento que cambie según cuál de los dos sea verdadero.
> **Q2.3** Una purl es `pkg:pypi/requests@2.31.0`; una CPE para el mismo componente podría ser `cpe:2.3:a:python:requests:2.31.0:*:*:*:*:*:*:*`. ¿Cuál identificador impulsa la resolución de *dependencias* y cuál la correlación de *vulnerabilidades*, y qué modo de falla aparece cuando una herramienta tiene solo uno de ellos?
> **Q2.4** `isOsiApproved` e `isFsfLibre` son booleanos separados en la lista de licencias SPDX. ¿Por qué no son el mismo campo?

---

## Ejercicio 3 — Hacer que *tu propio* repositorio sea conforme: encabezados SPDX y REUSE

Consumir código abierto es la mitad del objetivo. Publicarlo correctamente es la otra mitad.

### Pasos

1. Inicializá un repositorio para tu aplicación y escribí un archivo fuente **sin** información de licenciamiento — el estado inicial de la mayoría de los proyectos.

   ```bash
   cd "$LAB/app"
   git init -q
   cat > server.py <<'EOF'
   from flask import Flask
   app = Flask(__name__)

   @app.get("/healthz")
   def healthz():
       return {"status": "ok"}, 200
   EOF
   reuse lint
   ```

   ```text
   # MISSING COPYRIGHT AND LICENSING INFORMATION

   The following files have no copyright and licensing information:
   * requirements.txt
   * server.py

   # SUMMARY

   * Bad licenses: 0
   * Deprecated licenses: 0
   * Licenses without file extension: 0
   * Missing licenses: 0
   * Unused licenses: 0
   * Used licenses:
   * Read errors: 0
   * Files with copyright information: 0 / 2
   * Files with license information: 0 / 2

   Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(
   ```

2. Descargá el texto completo de la licencia en el directorio `LICENSES/` que exige la especificación REUSE (<https://reuse.software/spec/>).

   ```bash
   reuse download Apache-2.0
   ls LICENSES/
   ```

   ```text
   Successfully downloaded LICENSES/Apache-2.0.txt.
   Apache-2.0.txt
   ```

3. Anotá cada archivo con una línea de copyright legible por máquina y una etiqueta `SPDX-License-Identifier`.

   ```bash
   reuse annotate --copyright="ACME Platform Engineering <platform@acme.example>" \
                  --license=Apache-2.0 --year=2026 \
                  server.py requirements.txt
   head -3 server.py
   ```

   ```text
   # SPDX-FileCopyrightText: 2026 ACME Platform Engineering <platform@acme.example>
   #
   # SPDX-License-Identifier: Apache-2.0
   ```

4. Manejá un archivo que no puede llevar un encabezado de comentario — un recurso binario — usando `REUSE.toml` (el reemplazo desde REUSE 3.2+ de `.reuse/dep5`).

   ```bash
   mkdir -p assets && head -c 512 /dev/urandom > assets/logo.png
   cat > REUSE.toml <<'EOF'
   version = 1

   [[annotations]]
   path = "assets/**"
   precedence = "aggregate"
   SPDX-FileCopyrightText = "2026 ACME Platform Engineering <platform@acme.example>"
   SPDX-License-Identifier = "CC-BY-4.0"
   EOF
   reuse download CC-BY-4.0
   reuse lint | tail -12
   ```

   ```text
   * Bad licenses: 0
   * Deprecated licenses: 0
   * Licenses without file extension: 0
   * Missing licenses: 0
   * Unused licenses: 0
   * Used licenses: Apache-2.0, CC-BY-4.0
   * Read errors: 0
   * Files with copyright information: 4 / 4
   * Files with license information: 4 / 4

   Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)
   ```

5. Emití un SBOM **del licenciamiento de tu propio proyecto** — REUSE puede producir un documento SPDX directamente, que es el artefacto que adjuntás a un release.

   ```bash
   reuse spdx -o "$LAB/artifacts/reuse.spdx"
   grep -E '^(PackageName|LicenseInfoInFile|FileName)' "$LAB/artifacts/reuse.spdx" | head -8
   ```

   ```text
   PackageName: app
   FileName: ./server.py
   LicenseInfoInFile: Apache-2.0
   FileName: ./requirements.txt
   LicenseInfoInFile: Apache-2.0
   FileName: ./assets/logo.png
   LicenseInfoInFile: CC-BY-4.0
   ```

6. Agregá el control de procedencia de contribuciones. Configurá el sign-off DCO (<https://developercertificate.org/>) y probá que quede en el objeto commit.

   ```bash
   git config user.name "Platform Engineer"
   git config user.email "platform@acme.example"
   git add -A && git commit -q -s -m "feat: add health endpoint and REUSE compliance"
   git log -1 --format='%B'
   ```

   ```text
   feat: add health endpoint and REUSE compliance

   Signed-off-by: Platform Engineer <platform@acme.example>
   ```

7. Aplicalo mecánicamente, como lo haría una compuerta de CI.

   ```bash
   git log --format='%H %(trailers:key=Signed-off-by,valueonly)' -1 \
     | awk 'NF<2 {print "DCO MISSING on "$1; exit 1} {print "DCO OK"}'
   ```

   ```text
   DCO OK
   ```

> **Control de comprensión — Bloque 3**
>
> **Q3.1** Una única línea `SPDX-License-Identifier: Apache-2.0` al inicio de un archivo es una *etiqueta*, no una licencia. ¿Qué más debe estar presente en el repositorio para que la etiqueta tenga sentido legal, y qué regla de REUSE lo hace cumplir?
> **Q3.2** Tu entrada de `assets/` usa `precedence = "aggregate"`. ¿Qué cambiaría si existiera al mismo tiempo un archivo sidecar `logo.png.license`, y por qué REUSE define una precedencia en primer lugar?
> **Q3.3** Distinguí un **sign-off DCO** de un **CLA**. Para cada uno, indicá quién hace una afirmación, qué se afirma, y si el copyright se transfiere o se licencia.
> **Q3.4** `git commit -s` y `git commit -S` difieren en un bit de mayúscula. Explicá qué hace cada uno y por qué una compuerta DCO que acepta solo `-s` sigue dejando un agujero de falsificación de autoría.

---

## Ejercicio 4 — Análisis de composición: correlacionar el SBOM contra datos de vulnerabilidades

El análisis de composición de software (SCA) es el *join* entre "qué contiene" y "qué se sabe al respecto". Mantené esos dos conjuntos de datos separados — ese es todo el sentido arquitectónico de un SBOM.

### Pasos

1. Correlacioná tu SBOM existente contra la base de datos de Grype. Notá que escaneás el **SBOM**, no el sistema de archivos: sin rebuild, sin necesidad de acceso al código fuente.

   ```bash
   grype sbom:"$LAB/artifacts/app.cdx.json" -o table
   ```

   ```text
   NAME        INSTALLED   FIXED-IN   TYPE    VULNERABILITY        SEVERITY
   Werkzeug    3.0.6       3.0.6      python  GHSA-f9vj-2wh5-fj8j  Medium
   requests    2.31.0      2.32.0     python  GHSA-9wx4-h78v-vm56  Medium
   requests    2.31.0      2.32.4     python  GHSA-9hjg-9r4m-mvj7  Medium
   cryptography 43.0.1     44.0.1     python  GHSA-79v4-65xg-pq4g  Medium
   paramiko    3.4.0       (none)     python  GHSA-...             Low
   ```

2. Verificá de forma cruzada con una segunda base de datos de origen independiente — OSV.dev (<https://osv.dev/>) — porque los feeds de vulnerabilidades discrepan entre sí.

   ```bash
   osv-scanner --sbom="$LAB/artifacts/app.cdx.json" 2>/dev/null | head -20
   ```

   ```text
   ╭─────────────────────────────────────┬──────┬───────────┬─────────┬─────────┬──────────────╮
   │ OSV URL                             │ CVSS │ ECOSYSTEM │ PACKAGE │ VERSION │ SOURCE       │
   ├─────────────────────────────────────┼──────┼───────────┼─────────┼─────────┼──────────────┤
   │ https://osv.dev/GHSA-9wx4-h78v-vm56 │ 6.1  │ PyPI      │ requests│ 2.31.0  │ app.cdx.json │
   │ https://osv.dev/GHSA-9hjg-9r4m-mvj7 │ 5.3  │ PyPI      │ requests│ 2.31.0  │ app.cdx.json │
   ╰─────────────────────────────────────┴──────┴───────────┴─────────┴─────────┴──────────────╯
   ```

3. Traé el registro autoritativo de un hallazgo y leé el **vector** CVSS, no el número. CVSS está especificado por FIRST en <https://www.first.org/cvss/>.

   ```bash
   curl -s https://api.osv.dev/v1/vulns/GHSA-9wx4-h78v-vm56 \
     | jq '{id, aliases, severity, affected: [.affected[].ranges[].events]}'
   ```

   ```text
   {
     "id": "GHSA-9wx4-h78v-vm56",
     "aliases": ["CVE-2024-35195"],
     "severity": [
       { "type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:H/PR:H/UI:N/S:U/C:H/I:N/A:N" }
     ],
     "affected": [[ {"introduced": "0"}, {"fixed": "2.32.0"} ]]
   }
   ```

4. Decidí si el hallazgo es *alcanzable* en tu despliegue, y después suprimilo honestamente con una declaración **VEX** (OpenVEX: <https://github.com/openvex/spec>) en vez de editando la configuración del escáner.

   ```bash
   cat > "$LAB/artifacts/app.openvex.json" <<'EOF'
   {
     "@context": "https://openvex.dev/ns/v0.2.0",
     "@id": "https://acme.example/vex/app-2026-09-01",
     "author": "ACME Platform Engineering <platform@acme.example>",
     "timestamp": "2026-09-01T10:00:00Z",
     "version": 1,
     "statements": [
       {
         "vulnerability": { "name": "CVE-2024-35195" },
         "products": [ { "@id": "pkg:pypi/requests@2.31.0" } ],
         "status": "not_affected",
         "justification": "vulnerable_code_not_in_execute_path",
         "impact_statement": "The application never sets Session.verify=False; the affected code path is unreachable."
       }
     ]
   }
   EOF
   grype sbom:"$LAB/artifacts/app.cdx.json" --vex "$LAB/artifacts/app.openvex.json" \
         --show-suppressed -o table | grep -i -A1 suppressed | head -4
   ```

   ```text
   requests  2.31.0  2.32.0  python  GHSA-9wx4-h78v-vm56  Medium (suppressed by VEX)
   ```

5. Hacé que la compuerta sea determinista para CI: que falle solo con severidad igual o superior a un umbral, y que emita salida legible por máquina para el almacén de artefactos del pipeline.

   ```bash
   grype sbom:"$LAB/artifacts/app.cdx.json" \
         --vex "$LAB/artifacts/app.openvex.json" \
         --fail-on high -o json > "$LAB/artifacts/grype.json"
   echo "exit=$?"
   jq '[.matches[] | .vulnerability.severity] | group_by(.) | map({sev: .[0], n: length})' "$LAB/artifacts/grype.json"
   ```

   ```text
   exit=0
   [ {"sev":"Low","n":1}, {"sev":"Medium","n":3} ]
   ```

> **Control de comprensión — Bloque 4**
>
> **Q4.1** Grype reportó `Werkzeug 3.0.6` como vulnerable con `FIXED-IN 3.0.6` — la versión instalada es igual a la versión corregida. Nombrá dos mecanismos que producen esta aparente contradicción y decí cuál de ellos es un defecto en los *datos*, no en la herramienta.
> **Q4.2** Decodificá `CVSS:3.1/AV:N/AC:H/PR:H/UI:N/S:U/C:H/I:N/A:N` métrica por métrica. Después argumentá por qué esta puntuación base *no* alcanza para priorizar el hallazgo en tu backlog, y nombrá dos conjuntos de datos que mejorarían la decisión.
> **Q4.3** Una declaración VEX `not_affected` y una regla de ignore del escáner eliminan ambas un hallazgo del reporte. Indicá tres propiedades que VEX tiene y la regla de ignore no.
> **Q4.4** `--fail-on high` devolvió código de salida 0 con cuatro hallazgos abiertos. Explicá qué propiedad de seguridad garantiza realmente esta compuerta, y qué explícitamente no garantiza.
> **Q4.5** ¿Por qué el SBOM debe generarse en tiempo de *build* pero el escaneo de vulnerabilidades debe re-ejecutarse *continuamente* contra el SBOM almacenado?

---

## Ejercicio 5 — Copyleft dentro de una imagen de contenedor: obligaciones que heredás al distribuir

Las imágenes base traen obligaciones de licencia que el código de tu aplicación nunca tuvo. Este es el ejercicio que la mayoría de los ingenieros hace mal en producción.

### Pasos

1. Generá un SBOM para dos imágenes base comunes y contá los componentes. Usá digests fijados para que el ejercicio sea reproducible.

   ```bash
   syft alpine:3.20 -o spdx-json="$LAB/artifacts/alpine.spdx.json" -q
   syft debian:12-slim -o spdx-json="$LAB/artifacts/debian.spdx.json" -q
   jq '.packages | length' "$LAB/artifacts/alpine.spdx.json" "$LAB/artifacts/debian.spdx.json"
   ```

   ```text
   15
   93
   ```

2. Extraé la licencia declarada de cada paquete del SO en la imagen Alpine.

   ```bash
   jq -r '.packages[] | [.name, (.licenseDeclared // "NOASSERTION")] | @tsv' \
      "$LAB/artifacts/alpine.spdx.json" | sort | column -t -s $'\t'
   ```

   ```text
   alpine-baselayout        GPL-2.0-only
   alpine-baselayout-data   GPL-2.0-only
   alpine-keys              MIT
   apk-tools                GPL-2.0-only
   busybox                  GPL-2.0-only
   busybox-binsh            GPL-2.0-only
   ca-certificates-bundle   MPL-2.0 AND MIT
   libcrypto3               Apache-2.0
   libssl3                  Apache-2.0
   musl                     MIT
   musl-utils               MIT AND BSD-3-Clause AND GPL-2.0-or-later
   scanelf                  GPL-2.0-only
   ssl_client               GPL-2.0-only
   zlib                     Zlib
   ```

3. Usá una segunda herramienta para corroborar, y para detectar licencias que aparecen solo en encabezados de archivo y no en los metadatos del paquete.

   ```bash
   trivy image --scanners license --license-full --severity HIGH,CRITICAL debian:12-slim 2>/dev/null | head -18
   ```

   ```text
   debian:12-slim (debian 12.8)
   ============================
   OS Packages (license)
   ┌──────────────┬──────────────┬──────────────────────────┬──────────┐
   │   Package    │   License    │      Classification      │ Severity │
   ├──────────────┼──────────────┼──────────────────────────┼──────────┤
   │ bash         │ GPL-3.0      │ restricted               │ HIGH     │
   │ coreutils    │ GPL-3.0      │ restricted               │ HIGH     │
   │ gpgv         │ GPL-3.0      │ restricted               │ HIGH     │
   │ libgcrypt20  │ LGPL-2.1     │ reciprocal               │ MEDIUM   │
   │ tar          │ GPL-3.0      │ restricted               │ HIGH     │
   └──────────────┴──────────────┴──────────────────────────┴──────────┘
   ```

4. Producí el artefacto que realmente satisface la obligación: un inventario de atribución por componente distribuido junto con la imagen.

   ```bash
   jq -r '["component","version","license","supplier"], (.packages[] |
          [.name, .versionInfo, (.licenseDeclared // "NOASSERTION"), (.supplier // "NOASSERTION")]) | @csv' \
      "$LAB/artifacts/alpine.spdx.json" > "$LAB/artifacts/THIRD-PARTY-NOTICES.csv"
   head -4 "$LAB/artifacts/THIRD-PARTY-NOTICES.csv"
   ```

   ```text
   "component","version","license","supplier"
   "busybox","1.36.1-r29","GPL-2.0-only","Organization: Alpine Linux"
   "musl","1.2.5-r0","MIT","Organization: Alpine Linux"
   "libssl3","3.3.2-r0","Apache-2.0","Organization: Alpine Linux"
   ```

5. Verificá que el código fuente correspondiente sea realmente recuperable — la obligación es la *disponibilidad* del fuente, no una URL que esperás que siga funcionando.

   ```bash
   curl -sI https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/busybox-1.36.1-r29.apk \
     | head -1
   ```

   ```text
   HTTP/2 200
   ```

> **Control de comprensión — Bloque 5**
>
> **Q5.1** Tu aplicación Python propietaria corre en un contenedor construido `FROM alpine:3.20`. Esa imagen contiene `busybox` bajo `GPL-2.0-only`. ¿La GPL te obliga a liberar el código fuente de tu aplicación? Justificá la respuesta usando los conceptos de *agregación* y *obra derivada*.
> **Q5.2** Publicar esa imagen en un registro público — ¿es "distribución" en el sentido de la licencia? ¿Qué debés poner a disposición concretamente en ese momento, y por cuánto tiempo obliga la GPL-2.0 §3(b) a una oferta escrita?
> **Q5.3** `musl-utils` es `MIT AND BSD-3-Clause AND GPL-2.0-or-later`. Contrastá la obligación creada por esta expresión `AND` con el `OR` que viste en el Ejercicio 2.
> **Q5.4** Trivy clasifica GPL-3.0 como `restricted` y LGPL-2.1 como `reciprocal`. Explicá la diferencia de ingeniería entre las dos para un binario contra el que enlazás, y qué exigen la LGPL §6 / LGPL-3 §4 que habilites para tus usuarios.
> **Q5.5** Tu servicio es una API SaaS pública. Nunca entrega un binario a nadie. ¿Qué única familia de licencias destruye la suposición de que "no distribuimos, así que no aplican obligaciones de copyleft", y por qué cláusula?
> **Q5.6** Un componente reporta `licenseDeclared: NOASSERTION`. ¿Por qué esto es *peor* que un componente que declara GPL-3.0, desde la perspectiva de una compuerta de release?

---

## Ejercicio 6 — Procedencia: firmar el artefacto y atestar el SBOM

Un SBOM que no podés autenticar es un archivo de texto que alguien te mandó. Esto cierra el círculo entre composición e integridad de la cadena de suministro.

### Pasos

1. Verificá una firma keyless existente para ver el modelo de confianza antes de producir una. Sigstore documenta este ejemplo en <https://docs.sigstore.dev/>.

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-identity=keyless@distroless.iam.gserviceaccount.com \
     --certificate-oidc-issuer=https://accounts.google.com 2>&1 | head -8
   ```

   ```text
   Verification for gcr.io/distroless/static-debian12:latest --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - Existence of the claims in the transparency log was verified offline
     - The code-signing certificate was verified using trusted certificate authority certificates
   ```

2. Fijate en lo que hacen las dos banderas obligatorias. Quitá una y observá el fallo — esta es la mala configuración más común en la verificación con cosign.

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-oidc-issuer=https://accounts.google.com 2>&1 | tail -2
   ```

   ```text
   Error: --certificate-identity or --certificate-identity-regexp is required for verification in keyless mode
   main.go:74: error during command execution: ...
   ```

3. Inspeccioná la entrada del log de transparencia que respalda una firma. Rekor es el log de solo anexado (<https://docs.sigstore.dev/logging/overview/>).

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-identity=keyless@distroless.iam.gserviceaccount.com \
     --certificate-oidc-issuer=https://accounts.google.com -o json 2>/dev/null \
     | jq -r '.[0].optional | {logIndex: .Bundle.Payload.logIndex, integratedTime: .Bundle.Payload.integratedTime, issuer: .Issuer, subject: .Subject}'
   ```

   ```text
   {
     "logIndex": 148903771,
     "integratedTime": 1735689421,
     "issuer": "https://accounts.google.com",
     "subject": "keyless@distroless.iam.gserviceaccount.com"
   }
   ```

4. Producí tu propia **atestación** firmada que vincule el SBOM a un digest de imagen. Usá un par de claves local para que el ejercicio corra sin un flujo OIDC; los pipelines de producción usan keyless con una identidad de carga de trabajo en su lugar.

   ```bash
   cd "$LAB/artifacts"
   COSIGN_PASSWORD="" cosign generate-key-pair
   # Attest an SBOM as an in-toto predicate against a digest you control:
   # cosign attest --key cosign.key --predicate app.cdx.json \
   #               --type cyclonedx ghcr.io/acme/app@sha256:<digest>
   ls cosign.key cosign.pub
   ```

   ```text
   Private key written to cosign.key
   Public key written to cosign.pub
   cosign.key
   cosign.pub
   ```

5. Verificá una atestación y extraé el predicado de vuelta — el viaje de ida y vuelta que realiza un consumidor.

   ```bash
   # cosign verify-attestation --key cosign.pub --type cyclonedx \
   #   ghcr.io/acme/app@sha256:<digest> \
   #   | jq -r '.payload' | base64 -d | jq '{type: .predicateType, subject: .subject[0].name}'
   echo '{"predicateType":"https://cyclonedx.org/bom","subject":"ghcr.io/acme/app"}' | jq .
   ```

   ```text
   {
     "predicateType": "https://cyclonedx.org/bom",
     "subject": "ghcr.io/acme/app"
   }
   ```

6. Mapeá tu pipeline contra los niveles de build de SLSA (<https://slsa.dev/spec/v1.0/levels>) y registrá la respuesta honesta.

   ```bash
   cat > "$LAB/artifacts/slsa-self-assessment.md" <<'EOF'
   | Requirement                                   | Level | Status |
   |-----------------------------------------------|-------|--------|
   | Provenance exists and is distributed          | L1    | YES — cosign attest on every push |
   | Build runs on a hosted, isolated build service | L2    | YES — ephemeral CI runner |
   | Provenance signed by the build service         | L2    | YES — OIDC keyless, no long-lived key |
   | Build platform hardened; secrets non-forgeable | L3    | NO  — runners share a cache volume |
   EOF
   cat "$LAB/artifacts/slsa-self-assessment.md"
   ```

> **Control de comprensión — Bloque 6**
>
> **Q6.1** En el paso 2, omitir `--certificate-identity` es un error fatal. Explicá qué probaría realmente una verificación que solo comprobara "un certificado Sigstore válido firmó esto", y por qué eso no vale casi nada.
> **Q6.2** La firma keyless emite un certificado válido por unos diez minutos. Si el certificado venció hace meses, ¿cómo puede la firma seguir verificándose hoy? Nombrá el componente que hace esto posible y la propiedad que aporta.
> **Q6.3** Distinguí `cosign sign` de `cosign attest`. ¿Cuál es el *sujeto* en cada caso y qué información adicional lleva una atestación?
> **Q6.4** Una atestación vincula un SBOM a `sha256:<digest>`, no a la etiqueta `:latest`. Indicá el ataque que esto previene.
> **Q6.5** Tu autoevaluación afirma SLSA L2 pero no L3. ¿Qué amenaza específica aborda L3 que L2 deja abierta, y por qué un volumen de caché compartido entre runners lo rompe?
> **Q6.6** Verificás con éxito la firma de una imagen y su atestación de SBOM lista un componente con un CVE crítico. ¿Falló la verificación de firma? Explicá la relación entre *integridad* y *calidad* en los controles de cadena de suministro.

---

## Limpieza

```bash
deactivate 2>/dev/null
rm -rf "$LAB"
docker image rm alpine:3.20 debian:12-slim 2>/dev/null || true
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

**A0.1** El riesgo es la **ejecución de código no autenticado desde un endpoint remoto** — un vector clásico de compromiso de la cadena de suministro: quien controle el CDN, el nombre DNS o el pipeline de release controla lo que tu máquina ejecuta como tu usuario. `curl | sh` también se lleva mal con las descargas parciales, ya que el shell puede ejecutar un script truncado. Antes de ejecutar cualquiera de ellas en CI deberías exigir (1) un **archivo de checksums más una firma separada** sobre él (`*_checksums.txt` + `*_checksums.txt.sig`, verificada contra la clave pública publicada del proveedor o vía `cosign verify-blob` con un `--certificate-identity` fijado), y (2) una **versión y digest fijados**, nunca `latest` — para que el artefacto que auditaste sea el artefacto que ejecutás. En la práctica vas un paso más allá: incorporás el binario verificado a un registro interno o a una imagen de herramientas dedicada, y hacés que CI lo baje desde ahí.

**A0.2** En un laboratorio es correcto porque hace que toda la instalación sea **autocontenida y reversible** — `rm -rf "$LAB"` elimina todo rastro, nada colisiona con binarios gestionados por la distribución, y el ejercicio es reproducible en una máquina que no es tuya. Dentro de una imagen de build el mismo patrón se vuelve un antipatrón: binarios sin versionar traídos en tiempo de build a un directorio ad-hoc del `PATH` significan que la imagen **no es reproducible** (el mismo Dockerfile produce distintas versiones de herramientas en distintos días), las herramientas son **invisibles para tus propios escáneres de SBOM** (no llevan metadatos de gestor de paquetes, así que `syft` las cataloga como ejecutables sueltos en el mejor de los casos), y has insertado una dependencia de red sin fijar en cada build.

### Bloque 1

**A1.1** `CC0-1.0` es una dedicación al dominio público. La especificación SPDX fija `dataLicense` en `CC0-1.0` para que **el documento SBOM en sí mismo** — a diferencia del software que describe — siempre pueda ser copiado, republicado, agregado y procesado por máquina por cualquiera, sin necesidad de permiso. Todo el valor de un SBOM está en que fluye aguas abajo: a través de tu cliente, su auditor, un CERT, un regulador. `"dataLicense": "Proprietary"` haría el documento no redistribuible, lo que significa que tu cliente no podría reenviarlo a *su* cliente, un agregador automatizado no podría ingerirlo, y la transparencia que el artefacto existe para brindar se detendría en el primer receptor. También violaría la especificación, así que las herramientas conformes deberían rechazar el documento.

**A1.2** Aportan **identidad globalmente única para una instancia específica de documento**. Un nombre de archivo no es ni único ni estable — cada build nocturno escribe `sbom.json`, y los `sbom.json` de dos equipos distintos colisionan en el momento en que se guardan juntos. El UUID/URI le permite a un consumidor decir "este triaje de vulnerabilidades aplica al SBOM `urn:uuid:6b0f…`", permite que un documento *referencie* a otro (SPDX `ExternalDocumentRef`, CycloneDX `externalReferences`/BOM-Link), y te permite distinguir "el SBOM se regeneró" de "el software cambió". Para un rebuild nocturno esto es exactamente lo que necesitás: conjuntos de componentes idénticos en dos builds igual producen dos identidades de documento distintas, así que podés probar qué escaneo corrió contra qué build.

**A1.3** (1) **Completitud transitiva.** `requirements.txt` en este laboratorio lista 5 dependencias directas; el árbol instalado tiene 17 paquetes. Un escaneo del archivo de declaración se pierde los 12 componentes transitivos, que es donde viven la mayoría de las vulnerabilidades y la mayoría de las sorpresas de copyleft. (2) **Resolución de versiones.** Una declaración puede contener rangos (`Flask>=2.2`), así que el escáner registra una restricción en vez de un hecho; el árbol instalado registra la versión exacta que efectivamente se resolvió en esa plataforma, en ese momento, para esa versión de Python — incluidas dependencias condicionales de plataforma que nunca aparecerían en la declaración. Una tercera diferencia real: un árbol instalado expone los metadatos reales de la distribución (`METADATA`, `RECORD`) con licencias declaradas y hashes de archivos, que un `requirements.txt` simplemente no tiene.

**A1.4** **CycloneDX**, porque fue diseñado como un BOM orientado a seguridad y define un array `vulnerabilities` de primera clase (además de semántica VEX) dentro del documento. Es una pregunta en absoluto porque se trata de un desacuerdo arquitectónico genuino: el modelo de SPDX trata al SBOM como un registro de *composición y licenciamiento* cuyos hechos son estables durante toda la vida del artefacto, y a los datos de vulnerabilidades como un conjunto de datos separado y en cambio continuo, unido a él en tiempo de consulta. La posición de SPDX es el default más seguro en la práctica — un SBOM con las vulnerabilidades incorporadas queda obsoleto al día siguiente de firmarse, y volver a firmarlo en cada actualización del NVD no es viable. Usá las vulnerabilidades en línea de CycloneDX para un reporte puntual; mantené el SBOM distribuido y atestado libre de ellas.

### Bloque 2

**A2.1** `OR` es una **elección que se te concede**: podés usar `cryptography` bajo Apache-2.0 *o* bajo BSD-3-Clause, y cumplís con exactamente una. `AND` habría sido **acumulativo**: debés satisfacer simultáneamente las condiciones de cada licencia listada. En tu inventario de conformidad registrás **la licencia que efectivamente elegiste**, no la expresión cruda — porque las obligaciones que fluyen aguas abajo (texto de atribución, propagación del NOTICE, alcance de la concesión de patentes) difieren entre las dos. Acá la elección no es cosmética: Apache-2.0 §3 lleva una concesión expresa de patentes con cláusula de terminación y §4 te exige propagar el archivo `NOTICE`; BSD-3-Clause no tiene ninguna de las dos, pero agrega una cláusula de no-respaldo. La mayoría de las organizaciones estandarizan en una para todo el inventario y documentan la decisión.

**A2.2** `GPL-2.0` a secas era ambiguo respecto de la cláusula **"or (at your option) any later version"**. El propio texto de la GPL en §9/§14 distingue una obra licenciada estrictamente bajo la versión 2 de una licenciada bajo "versión 2 o posterior", y esa distinción es del licenciatario, no un detalle estilístico — así que SPDX la dividió en `GPL-2.0-only` y `GPL-2.0-or-later` y declaró obsoleta la forma ambigua. La decisión que cambia: **combinar el componente con código licenciado bajo GPL-3.0.** GPL-2.0-only es *incompatible* con GPL-3.0 — las dos no pueden enlazarse en una sola obra, porque cada una impone condiciones que la otra prohíbe agregar. `GPL-2.0-or-later` le permite al receptor optar por GPL-3.0 y combinar libremente. Lo mismo con Apache-2.0: es incompatible con GPL-2.0-only (sus términos de terminación de patentes e indemnización son "restricciones adicionales" bajo la GPLv2) pero explícitamente compatible en un sentido con GPL-3.0.

**A2.3** **purl impulsa la resolución de dependencias**: es una coordenada nativa del gestor de paquetes (`pkg:pypi/requests@2.31.0`) que nombra sin ambigüedad de dónde vino el artefacto y cómo obtenerlo. **CPE impulsa la correlación de vulnerabilidades** contra el NVD, cuyos registros están indexados por CPE. El modo de falla cuando una herramienta tiene solo uno: con **solo purl**, podés consultar feeds nativos del ecosistema (OSV, GitHub Advisory) pero te perdés entradas del NVD que nunca fueron mapeadas a una purl. Con **solo CPE**, obtenés cobertura del NVD pero sufrís la notoria ambigüedad de CPE — las cadenas de vendor/product las asignan humanos, la misma biblioteca aparece bajo múltiples CPEs, y productos no relacionados colisionan en un nombre — produciendo tanto falsos positivos como falsos negativos silenciosos. Los escáneres serios llevan ambos y los reconcilian, que es por lo que `syft` emite ambos campos.

**A2.4** Porque **la OSI y la FSF son organizaciones distintas que aplican criterios distintos a definiciones distintas.** La OSI aprueba licencias contra la *Open Source Definition*; la FSF las evalúa contra la *Free Software Definition* y además pregunta si una licencia es **compatible con la GPL**. Los conjuntos se solapan fuertemente pero no del todo — algunas licencias están aprobadas por la OSI y la FSF las considera no libres o incompatibles con la GPL, y unas pocas licencias libres según la FSF nunca fueron sometidas a la OSI. Modelarlas como dos booleanos le permite a un motor de políticas expresar reglas organizacionales con precisión ("solo aprobadas por OSI" vs. "solo compatibles con GPL") en vez de colapsarlas en una única noción equivocada de "código abierto".

### Bloque 3

**A3.1** El **texto completo de la licencia debe existir en el repositorio**, en `LICENSES/Apache-2.0.txt`. Un identificador corto es una referencia; la concesión de derechos es el texto de la licencia en sí, y un receptor que recibe tu tarball solo con la etiqueta ha recibido un puntero a un documento que no le entregaron. REUSE lo hace cumplir con su verificación *Missing licenses* — un archivo etiquetado `SPDX-License-Identifier: Apache-2.0` sin `LICENSES/Apache-2.0.txt` falla en `reuse lint`. (La verificación inversa, *Unused licenses*, detecta textos de licencia que distribuís pero que ningún archivo reclama — peso legal muerto que confunde a los auditores.) Apache-2.0 además tiene obligaciones en §4 sobre conservar avisos y propagar cualquier archivo `NOTICE`.

**A3.2** Un archivo sidecar `logo.png.license` **siempre gana** sobre `REUSE.toml`. La precedencia existe porque el mismo archivo puede estar cubierto por información de varias fuentes — un encabezado de comentario, un sidecar, y una o más entradas de `REUSE.toml` — y una herramienta de conformidad debe producir una única respuesta determinista. `precedence = "aggregate"` (el default) significa que la entrada de `REUSE.toml` aplica solo donde el archivo no tiene información propia; `precedence = "override"` hace que la entrada de `REUSE.toml` gane incluso sobre las etiquetas en el archivo, que es la vía de escape para código de terceros que incorporaste y no debés modificar; `precedence = "closest"` elige la ruta coincidente más específica. Equivocarse acá significa que tu documento SPDX publicado afirma una licencia que el propio archivo contradice.

**A3.3** **DCO** (Developer Certificate of Origin 1.1): el **contribuyente** afirma, por commit, que escribió la contribución o que tiene derecho a enviarla bajo la licencia existente del proyecto, y que la contribución es un registro público. Nada se transfiere y no se concede ninguna licencia nueva — es una *atestación de procedencia*, liviana, verificable solo desde el trailer del commit. **CLA** (Contributor License Agreement): el contribuyente **firma un acuerdo legal separado con el administrador del proyecto**, típicamente concediéndole una licencia de copyright *y de patentes* amplia e irrevocable (un CLA de licencia) o, en su forma agresiva, **cediendo el copyright** al administrador (un CAA). La consecuencia práctica es que un CLA le permite al administrador relicenciar o dual-licenciar el proyecto unilateralmente; un DCO no. Esa asimetría es por lo que los CLAs son controvertidos y por lo que el kernel de Linux, GitLab y los proyectos de la CNCF usan el DCO.

**A3.4** `git commit -s` agrega un trailer textual `Signed-off-by:` al mensaje del commit — texto plano, sin criptografía. `git commit -S` crea una **firma criptográfica GPG/SSH** sobre el objeto commit, verificable con `git log --show-signature`. El agujero: `Signed-off-by:` es una cadena que cualquiera puede tipear, y `git commit --author` le permite a cualquiera fijar un autor arbitrario. Así que una compuerta DCO que solo hace grep del trailer puede satisfacerse con un commit que falsifica el nombre y el correo de otro desarrollador — la atestación nombra a una persona que nunca la hizo. Cerrarlo requiere vincular la identidad criptográficamente: `-S` con una clave registrada en la cuenta, o un control del lado de la forja (commits verificados / firmas obligatorias de GitHub, o una identidad de push autenticada por OIDC contrastada con el trailer).

### Bloque 4

**A4.1** (1) **Correcciones backporteadas en una distribución reempaquetada.** Una distro o proveedor parchea la vulnerabilidad sin subir la versión upstream; el escáner compara cadenas de versión upstream y no puede ver el parche. Esto es la herramienta comportándose como fue diseñada frente a datos incompletos. (2) **Un advisory cuyos metadatos de rango afectado son incorrectos** — el evento `fixed` se registró como `3.0.6` cuando la corrección en realidad llegó en `3.0.6` *más* una restricción posterior, o el rango se publicó como inclusivo cuando debía ser exclusivo. Ese sí es un **defecto en los datos**, en el propio registro del advisory, y el remedio es presentar una corrección ante la fuente del advisory (GHSA/OSV) y no ajustar tu escáner. Una tercera causa, menos común: dos advisories distintos para el mismo paquete donde la herramienta fusiona filas.

**A4.2** `AV:N` vector de ataque Red — explotable remotamente. `AC:H` complejidad de ataque Alta — el atacante necesita condiciones fuera de su control (acá, una configuración específica de redirección/proxy). `PR:H` privilegios requeridos Altos — el atacante ya debe poseer privilegios elevados sobre el componente. `UI:N` sin interacción del usuario. `S:U` alcance Sin cambios — el impacto queda dentro de la autoridad de seguridad del componente vulnerable. `C:H` confidencialidad Alta, `I:N` sin impacto de integridad, `A:N` sin impacto de disponibilidad. Puntuación base ≈ 6.1 (Media).
Es insuficiente para priorizar porque el CVSS **base** describe deliberadamente la vulnerabilidad en abstracto, sin conocimiento de tu despliegue: no sabe si la ruta de código es alcanzable, si el componente está expuesto a internet, si existen controles compensatorios, o si alguien la está explotando efectivamente. Dos conjuntos de datos que mejoran la decisión: **EPSS** (<https://www.first.org/epss/>), una probabilidad de que la vulnerabilidad sea explotada en los próximos 30 días, y el **catálogo KEV de CISA** (<https://www.cisa.gov/known-exploited-vulnerabilities-catalog>), una lista de vulnerabilidades con explotación confirmada en el mundo real. El análisis de alcanzabilidad (basado en grafo de llamadas) y tus propios datos de exposición de activos son el tercero y el cuarto.

**A4.3** (1) **Es un documento portable y estandarizado, con autor y timestamp** — viaja con el artefacto hacia los consumidores aguas abajo, que pueden actuar sobre tu análisis; una regla de ignore vive en la configuración de tu escáner y no le sirve a nadie más. (2) **Declara una *justificación* legible por máquina** de un vocabulario fijo (`vulnerable_code_not_in_execute_path`, `component_not_present`, `inline_mitigations_already_exist`, …) más una declaración de impacto legible por humanos, de modo que el razonamiento sea auditable — una regla de ignore solo registra que alguien silenció algo. (3) **Está acotado a una identidad de producto y puede firmarse y atestarse** (cosign `--type openvex`), convirtiéndolo en una afirmación no repudiable; y como es agnóstico de la herramienta, la misma declaración aplica en Grype, Trivy y el escáner de tu cliente, mientras que las reglas de ignore son sintaxis específica de cada herramienta. Una cuarta: las declaraciones VEX están versionadas y pueden ser reemplazadas cuando el análisis cambia, dándote un historial.

**A4.4** Garantiza exactamente una cosa: **ningún hallazgo no suprimido de severidad `high` o superior estaba presente en este SBOM en el momento en que corrió el escaneo.** No garantiza que el software sea seguro, y específicamente no dice nada sobre (a) los cuatro hallazgos Medium/Low que siguen abiertos — los umbrales de severidad son una política de aceptación de riesgo, no una ausencia de riesgo; (b) vulnerabilidades divulgadas *después* del escaneo, que es por lo que el escaneo debe re-ejecutarse continuamente; (c) cualquier cosa que el SBOM haya omitido — un SBOM incompleto produce un escaneo limpio trivialmente; (d) la corrección de la supresión VEX, ya que `--vex` eliminó un hallazgo sobre la base de tu propia afirmación; y (e) cualquier clase de vulnerabilidad que no sea un CVE conocido en una dependencia catalogada, que son la mayoría — los bugs de tu propio código, mala configuración, secretos en la imagen.

**A4.5** El SBOM es un registro de **lo que se construyó**, y solo puede producirse con exactitud en el momento del build, cuando la salida del resolvedor, la plataforma de build y el árbol de archivos real están todos presentes. Reconstruirlo después es adivinar. El **conjunto de vulnerabilidades conocidas no es una propiedad del artefacto en absoluto** — es una propiedad del conocimiento del mundo en un día dado, y cambia continuamente a medida que se publican advisories. Un artefacto construido y escaneado limpio en enero no está limpio en marzo, aunque no haya cambiado ni un byte. Separar ambos te permite escanear miles de SBOMs almacenados cada noche, en segundos, sin reconstruir ni siquiera retener las imágenes — y es por lo que incorporar vulnerabilidades a un SBOM firmado es un error de diseño (ver A1.4).

### Bloque 5

**A5.1** **No.** BusyBox y tu aplicación están en una **agregación** — programas separados, distribuidos juntos en el mismo medio (acá, la misma imagen), comunicándose solo a través de interfaces distantes (`exec`, archivos, sockets). La GPL-2.0 §2 aborda esto explícitamente: "la mera agregación de otra obra no basada en el Programa … en un volumen de un medio de almacenamiento o distribución no pone a la otra obra bajo el alcance de esta Licencia." Tu aplicación Python no es una **obra derivada** de BusyBox — no enlaza contra él, no incorpora su código fuente ni lo extiende. Lo que *sí* cambiaría la respuesta es la combinación en vez de la co-ubicación: enlazar estáticamente una biblioteca GPL dentro de tu binario, importar código fuente GPL, o construir tu programa como un plugin que comparte el espacio de direcciones y las estructuras de datos de un programa GPL. Notá la trampa aparte en esta misma imagen: `musl` es MIT, así que enlazar contra libc acá no está gravado — pero sobre una base con `glibc`, glibc es LGPL, lo que trae sus propias obligaciones (mucho más débiles), tratadas en A5.4.

**A5.2** **Sí — publicar en un registro donde otros pueden hacer pull es distribución**, y es el momento en que tus obligaciones se activan. Debés, para cada componente GPL/LGPL de la imagen, poner a disposición el **código fuente completo correspondiente** — es decir, el código exacto usado para construir esos binarios, incluidos los parches que la distribución haya aplicado, más los scripts usados para controlar la compilación y la instalación. Las vías prácticas bajo GPL-2.0 §3: (a) distribuir el fuente junto con el binario, (b) acompañarlo con una **oferta escrita, válida por al menos tres años**, de proveer el fuente a cualquier tercero por no más que el costo de la distribución física, o (c) solo para redistribución no comercial, transmitir la oferta que recibiste. La GPL-3.0 §6 moderniza esto y agrega la opción (d): un servidor de red que ofrezca el fuente sin cargo, junto al binario. Como un archivo `THIRD-PARTY-NOTICES` más una URL vale solo lo que valga esa URL, el paso 5 del ejercicio verifica que el fuente sea genuinamente recuperable — apuntar a un mirror upstream que puede rotar paquetes fuera es una falla de conformidad común y real.

**A5.3** `AND` es **acumulativo e innegociable**: `musl-utils` contiene partes constituyentes bajo MIT, bajo BSD-3-Clause, *y* bajo GPL-2.0-or-later, y debés satisfacer cada una de esas licencias a la vez. En la práctica el término más fuerte gobierna la obra combinada, así que este componente arrastra obligaciones de GPL-2.0-or-later (disponibilidad del fuente, sin restricciones adicionales) a tu imagen, encima de los requisitos de atribución de MIT y BSD. El `OR` del Ejercicio 2 era lo contrario: un menú del que elegís uno y cumplís solo las condiciones de esa licencia. Una regla práctica de conformidad: `OR` es una oportunidad de *reducir* obligaciones eligiendo bien; `AND` es una acumulación de la que no podés salirte.

**A5.4** **GPL-3.0 (`restricted`)** es copyleft fuerte: enlazala dentro de tu programa y la obra combinada debe distribuirse bajo GPL-3.0, con el fuente incluido — para la mayoría de los productos propietarios esto es un bloqueo duro, que es por lo que la clasificación es "restricted". **LGPL-2.1 (`reciprocal`)** es copyleft débil/a nivel de archivo: podés enlazar un programa propietario contra la biblioteca LGPL y mantener tu propio código cerrado, pero las modificaciones *a la biblioteca en sí* deben liberarse bajo la LGPL. La obligación de ingeniería es el **derecho de re-enlazado** — la LGPL-2.1 §6 y la LGPL-3.0 §4(d)/(e) exigen que le permitas al receptor **reemplazar la biblioteca por una versión modificada y aun así ejecutar tu programa**. Lo satisfacés enlazando dinámicamente (distribuyendo la biblioteca como un `.so` que el usuario puede intercambiar) o, si enlazás estáticamente, proveyendo tus archivos objeto o un mecanismo suficiente para re-enlazar. Esto es precisamente por lo que enlazar estáticamente glibc o una biblioteca LGPL dentro de un contenedor scratch es una mina de conformidad y el enlazado dinámico es el default seguro.

**A5.5** **La AGPL** — GNU Affero General Public License — vía **§13 ("Remote Network Interaction")**. La AGPL-3.0 define la interacción con el software *a través de una red* como disparador de la obligación de proveer el fuente: si los usuarios interactúan remotamente con un programa AGPL modificado, debés ofrecerles el Código Fuente Correspondiente de tu versión modificada. Esto cierra deliberadamente la "laguna del SaaS" que la GPL-2.0 y la GPL-3.0 dejan abierta, donde ejecutar software como servicio no es distribución y por lo tanto no dispara nada. En la práctica: una sola biblioteca AGPL incorporada a tu servicio de API puede obligarte a publicar el código fuente de tu servicio. Es por esto que la AGPL casi siempre aparece en la lista de denegación de una política corporativa de dependencias, y por lo que `grep -i agpl` sobre tu SBOM es una verificación de compuerta de release y no de tiempo de auditoría.

**A5.6** Porque `NOASSERTION` significa que **la licencia es desconocida**, y desconocida no es lo mismo que libre de cargas — es un pasivo sin límite. Una declaración GPL-3.0 es una restricción *conocida*: podés evaluarla, decidir si el componente está agregado o enlazado, cumplir las obligaciones y publicar. `NOASSERTION` significa que el escáner no encontró ninguna licencia legible por máquina, así que el componente podría ser cualquier cosa: AGPL, una licencia comercial a medida, código propietario que alguien incorporó, o código genuinamente sin licencia (que por defecto **no te otorga derecho alguno** — la ausencia de licencia significa copyright exclusivo, no dominio público). Una compuerta de release debería tratar `NOASSERTION` como un hallazgo bloqueante que requiere resolución humana, exactamente igual que un CVE crítico. Notá también que SPDX distingue `NOASSERTION` ("la herramienta no hace ninguna afirmación") de `NONE` ("definitivamente no hay licencia"), y ambos exigen investigación.

### Bloque 6

**A6.1** Probaría solamente que **alguien con un certificado emitido por Sigstore firmó este artefacto** — y la CA Fulcio de Sigstore le emite un certificado a *cualquiera* que pueda completar un login OIDC con cualquier proveedor soportado. Cualquier atacante con una cuenta de Google o GitHub puede firmar una imagen maliciosa y obtener una firma Sigstore perfectamente válida con una entrada válida en el log de transparencia. La verificación no tiene sentido hasta que afirmás **quién** esperás: `--certificate-identity` (o `-regexp`) fija la identidad del firmante y `--certificate-oidc-issuer` fija qué proveedor de identidad respondió por ella. Ambos son obligatorios porque una cadena de identidad solo tiene sentido en relación con su emisor — `platform@acme.example` desde el IdP corporativo y la misma cadena autoafirmada en un emisor controlado por el atacante son principales distintos. En CI la identidad que fijás es típicamente el SAN del propio workflow, p. ej. `https://github.com/acme/app/.github/workflows/release.yml@refs/heads/main` con el emisor `https://token.actions.githubusercontent.com`.

**A6.2** A través de **Rekor, el log de transparencia de solo anexado**. Cuando se crea la firma, el evento de firma — firma, certificado y digest del artefacto — se registra en Rekor, que devuelve un **timestamp firmado** que prueba que la entrada existía en ese momento. La verificación entonces comprueba que el certificado era **válido al momento de la firma**, según lo atestado por el log, en vez de requerir que sea válido ahora. La propiedad que aporta es **prueba de tiempo no repudiable**, que es lo que le permite a Sigstore usar certificados efímeros de diez minutos en lugar de claves de larga vida. Ese intercambio es todo el punto del diseño: no existe una clave privada de larga vida que pueda ser robada, rotada o depositada en custodia, y la estructura de solo anexado del log (verificable mediante pruebas de inclusión y una cabeza de árbol firmada) significa que un evento de firma no puede borrarse silenciosamente ni antedatarse.

**A6.3** `cosign sign` produce una **firma sobre el digest del artefacto** — afirma "esta identidad responde por este blob exacto" y esencialmente no lleva ninguna otra información. `cosign attest` produce una **atestación in-toto** firmada: un sobre (DSSE) cuyo *sujeto* es el digest del artefacto y cuyo *predicado* es un documento estructurado arbitrario con un `predicateType` declarado — un SBOM (`https://cyclonedx.org/bom`), procedencia de build SLSA (`https://slsa.dev/provenance/v1`), una declaración VEX, un reporte de pruebas. En ambos casos el sujeto es el digest; la diferencia es que una atestación vincula **una afirmación verificable sobre el artefacto** con él, no meramente un respaldo de sus bytes. Eso es lo que le permite a un motor de políticas (Kyverno, Gatekeeper, `cosign verify-attestation --policy`) admitir o rechazar una carga de trabajo basándose en *lo que dice la atestación*, no solo en quién firmó.

**A6.4** Previene la **mutación de etiquetas** — el ataque de sustitución donde un atacante (o un release descuidado) reapunta `:latest`, o cualquier etiqueta, a una imagen distinta después de que tu SBOM fue producido y firmado. Las etiquetas en los registros OCI son punteros mutables; los digests son direccionables por contenido e inmutables. Si la atestación nombrara la etiqueta, la firma seguiría siendo válida mientras los bytes debajo cambian por completo, y tu controlador de admisión admitiría alegremente una imagen maliciosa que lleva un SBOM limpio y genuinamente firmado. Vincularla a `sha256:<digest>` hace que la afirmación sea inseparable de los bytes exactos que describe, que es también por lo que los manifiestos de despliegue deberían fijar digests en vez de etiquetas.

**A6.5** SLSA **L3 aborda la manipulación del build en sí** — exige que la plataforma de build esté endurecida de manera tal que un build no pueda influir sobre otro, y que la procedencia sea **infalsificable**: el material secreto usado para firmar la procedencia debe ser inaccesible para los pasos de build definidos por el usuario. L2 solo exige que la procedencia exista, esté autenticada y provenga de un servicio de build alojado — asume que el servicio de build es honesto pero no defiende contra un *inquilino* de build malicioso. Un **volumen de caché compartido entre runners** rompe L3 directamente: el build A puede escribir en la caché una dependencia, un compilador o un binario de toolchain envenenado, y el build B — perteneciente a otro proyecto, posiblemente a otro dominio de confianza — lo consumirá. La procedencia del build B sería entonces *exacta y correctamente firmada* mientras describe un build comprometido, que es exactamente la clase de ataque (Codecov, staging de xz-utils) que el requisito de aislamiento de L3 existe para detener.

**A6.6** **No, la verificación no falló, y no se suponía que lo hiciera.** La verificación de firma establece **integridad y procedencia**: el artefacto no fue modificado desde la firma, y una identidad específica y fijada responde por él. No dice nada sobre la **calidad** — si el código es correcto, está bien configurado o libre de vulnerabilidades conocidas. Los dos controles son ortogonales y complementarios, y de hecho un SBOM correctamente firmado que lista un CVE crítico es el sistema *funcionando*: la cadena de suministro te dijo honesta y verificablemente qué hay adentro, y la atestación te da fundamento para confiar en ese inventario. Los controles de integridad hacen que los datos de composición sean confiables; el análisis de composición los vuelve accionables. Confundir ambos produce el peor resultado en la práctica — tratar "firmado" como sinónimo de "seguro", y admitir una imagen verificada-pero-vulnerable porque el chequeo de firma dio verde.

</details>

---

## Fuentes

- LPI Exam 701 Objectives (DevOps Tools Engineer) — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Especificación SPDX y lista de licencias — <https://spdx.dev/> · <https://spdx.org/licenses/>
- Especificación CycloneDX (OWASP / ECMA-424) — <https://cyclonedx.org/specification/overview/>
- Especificación Package URL (purl) — <https://github.com/package-url/purl-spec>
- REUSE Specification 3.x (FSFE) — <https://reuse.software/spec/>
- Licencias GNU y matriz de compatibilidad — <https://www.gnu.org/licenses/license-list.html> · <https://www.gnu.org/licenses/gpl-faq.html>
- Apache License 2.0 — <https://www.apache.org/licenses/LICENSE-2.0>
- Open Source Definition (OSI) — <https://opensource.org/osd>
- Developer Certificate of Origin 1.1 — <https://developercertificate.org/>
- Base de datos y esquema de vulnerabilidades OSV — <https://osv.dev/> · <https://ossf.github.io/osv-schema/>
- NVD — <https://nvd.nist.gov/> · CVSS (FIRST) — <https://www.first.org/cvss/> · EPSS — <https://www.first.org/epss/>
- Catálogo de Vulnerabilidades Explotadas Conocidas (KEV) de CISA — <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>
- Especificación OpenVEX — <https://github.com/openvex/spec>
- Documentación de Sigstore (Cosign, Fulcio, Rekor) — <https://docs.sigstore.dev/>
- Framework de atestación in-toto — <https://github.com/in-toto/attestation>
- Niveles de build SLSA v1.0 — <https://slsa.dev/spec/v1.0/levels>
- Syft — <https://github.com/anchore/syft> · Grype — <https://github.com/anchore/grype> · Trivy — <https://trivy.dev/> · OSV-Scanner — <https://google.github.io/osv-scanner/>