# Topic 3.3: Otras licencias de contenido abierto

**Peso:** 2.5  
**Certificación objetivo:** LPI Open Source Essentials (Exam 050-100)  
**Audiencia:** Senior SREs, Lead Platform Engineers y Cloud Infrastructure Architects  

---

## 1. Motivación y problema de arquitectura en producción

La ingeniería de plataformas cloud-native moderna se extiende mucho más allá de la compilación de binarios y el código fuente en contenedores. Las plataformas Kubernetes a gran escala, los developer portals (por ejemplo, Backstage), los API gateways, los motores de agregación de telemetría y los pipelines de machine learning ingieren, procesan y publican assets no relacionados con software. Estos assets incluyen:

- Documentación técnica (Markdown, AsciiDoc, especificaciones OpenAPI/AsyncAPI).
- Blueprints de arquitectura de plataforma, sistemas de diseño de infraestructura y diagramas visuales.
- Datasets públicos, bases de datos de geolocalización IP, feeds de threat intelligence y pesos de modelos de IA.
- Descripciones del esquema de valores de Helm charts y documentación de policy-as-code empresarial.

### El conflicto arquitectónico
Las licencias de software como Apache-2.0, MIT o GPL-3.0 fueron redactadas explícitamente para código fuente, código objeto y mecánicas de linking en tiempo de ejecución (por ejemplo, linkage dinámico vs. estático, objetivos de compilación). Aplicar licencias de software a contenido que no es software introduce ambigüedad legal con respecto a qué constituye una "obra derivada", un "ejecutable" o un "linking".

Por el contrario, las licencias de contenido abierto —principalmente **Creative Commons (CC)**, **GNU Free Documentation License (GFDL)** y **Open Data Commons (ODbL/PDDL)**— están diseñadas para medios escritos, esquemas de bases de datos, datos en bruto y obras artísticas.

```
       +-----------------------------------------------------------------------+
       |                     CLOUD PLATFORM ASSET PIPELINE                     |
       +-----------------------------------------------------------------------+
                                           |
       +-----------------------------------+-----------------------------------+
       |                                   |                                   |
       v                                   v                                   v
+------------------+              +------------------+              +------------------+
|   SOURCE CODE    |              |  DOCUMENTATION   |              | DATASETS & MODELS|
| (Go, Python, C++)|              | (OpenAPI, MD, SVG)|              | (ODbL, CC0, PDDL)|
+------------------+              +------------------+              +------------------+
       |                                   |                                   |
       v                                   v                                   v
+------------------+              +------------------+              +------------------+
| Software License |              | Creative Commons |              |  Database Rights |
| (Apache-2.0, MIT)|              | (CC BY-SA, CC0)  |              |   (ODbL, ODC-BY) |
+------------------+              +------------------+              +------------------+
```

### Vectores de riesgo en producción
1. **Bloqueos comerciales mediante CC-NC (Non-Commercial):** Si un desarrollador importa documentación o esquemas de arquitectura licenciados bajo `CC BY-NC-SA 4.0` a un Developer Portal empresarial alojado en una infraestructura SaaS comercial, la empresa se expone a infracciones de licencia debido a la monetización comercial de la plataforma.
2. **Contaminación de copyleft en builds de documentación a través de CC-BY-SA o GFDL:** Fusionar fragmentos de documentación bajo `CC BY-SA 4.0` en material de referencia de API propietario obliga a relicenciar todo el payload del portal de API bajo términos ShareAlike.
3. **Derechos sobre bases de datos (Sui Generis Database Rights - SGDR):** En jurisdicciones europeas e internacionales, los datos en bruto de una base de datos no están cubiertos por el derecho de autor estándar, pero la *disposición y extracción* de datos está protegida por los derechos sobre bases de datos. La aplicación de licencias estándar CC BY a datos en bruto puede no obligar a los usuarios a respetar las restricciones de extracción de bases de datos, mientras que la **Open Database License (ODbL 1.0)** aborda específicamente la extracción y reutilización de bases de datos.
4. **Envenenamiento de pipelines de Machine Learning y RAG:** Las bases de datos vectoriales que ingieren documentación que no es código para modelos de generación aumentada por recuperación (RAG) deben respetar las licencias de contenido para evitar salidas generadas por IA no conformes a través de endpoints de LLM en producción.

---

## 2. Mecánica técnica y matriz de trade-offs

### Familias principales de licencias de contenido abierto

#### 1. Creative Commons (CC v4.0 International)
Creative Commons modulariza los derechos utilizando cuatro condiciones distintas:
- **BY (Atribución):** Debe dar el crédito adecuado, proporcionar un enlace a la licencia e indicar si se realizaron cambios.
- **SA (CompartirIgual / ShareAlike):** Si remezcla, transforma o crea a partir del material, debe distribuir sus contribuciones bajo la misma licencia que el original.
- **NC (NoComercial / NonCommercial):** El material no puede utilizarse con fines comerciales. (No cumple con la definición de Open Source).
- **ND (SinDerivadas / NoDerivatives):** Si remezcla, transforma o crea a partir del material, no puede distribuir el material modificado.

> **NOTA CRÍTICA PARA SRE:** Las licencias que contienen cláusulas **NC** o **ND** **NO** cumplen explícitamente con las definiciones de Open Source u Open Content según la Open Source Initiative (OSI) y la Free Software Foundation (FSF). Restringen la reutilización comercial y la modificación, lo que las hace inoperables para plataformas cloud empresariales.

#### 2. CC0 1.0 Universal (Dedicación al Dominio Público)
CC0 es una herramienta legal para renunciar a todos los derechos de autor y derechos sobre bases de datos en la máxima medida permitida por la ley. En producción, CC0 es el estándar de oro para definiciones de API, plantillas de configuración, métricas de referencia y datasets de dominio público.

#### 3. GNU Free Documentation License (GFDL v1.3)
Creada por la FSF para manuales técnicos y documentación. Presenta conceptos legales únicos para el texto:
- **Secciones invariantes (Invariant Sections):** Secciones secundarias específicas que no se pueden alterar ni eliminar al redistribuir.
- **Textos de cubierta (Cover Texts):** Requisitos de texto obligatorios para la portada y contraportada en publicaciones físicas o digitales.
- **Nota de incompatibilidad:** GFDL es generalmente incompatible con CC BY-SA, creando fragmentación en repositorios de documentación a menos que se otorguen licencias dobles explícitas (por ejemplo, la migración de Wikipedia a una licencia doble CC BY-SA / GFDL).

#### 4. Open Data Commons (ODbL 1.0 y ODC-BY 1.0)
Diseñada específicamente para bases de datos. Cubre:
- **Derecho sobre bases de datos (Database Right):** Restringe la extracción y reutilización no autorizadas del contenido de la base de datos.
- **ShareAlike para datos:** Requiere que las versiones modificadas de la base de datos (o bases de datos derivadas generadas a partir de una extracción sustancial) se publiquen bajo ODbL.

---

### Matriz de trade-offs técnicos

| Identificador de licencia | Asset de destino | Cumple con OSI/FSF Open | Uso en SaaS comercial | Activador de ShareAlike / Copyleft | Derechos sobre bases de datos cubiertos | Caso de uso ideal en producción |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CC0 1.0** | Configs, APIs, Metadata | Sí | Sin restricciones | Ninguno | Sí (Renuncia explícita) | Manifests de Kubernetes, especificaciones OpenAPI, baselines de datos públicos |
| **CC BY 4.0** | Documentación, Gráficos | Sí | Permitido con atribución | Ninguno | Sí | Documentación de portal de desarrolladores interno, diagramas de arquitectura |
| **CC BY-SA 4.0** | Docs, Guías de usuario | Sí | Permitido con atribución | Sí (Debe relicenciar derivados bajo CC BY-SA) | Sí | Manuales de plataforma impulsados por la comunidad, wikis públicas |
| **CC BY-NC 4.0** | Medios, Contenido | **NO** | **BLOQUEADO** | Ninguno | Sí | Prohibido en cadenas de herramientas de producción empresarial |
| **GFDL 1.3** | Manuales, Libros | Sí | Permitido (con restricciones de Cover Text) | Sí (Requiere conservación de secciones invariantes) | No | Manuales de software legados de GNU/Linux |
| **ODbL 1.0** | Telemetría, Registros de BD | Sí | Permitido (con publicación de derivados) | Sí (Se activa con extracción sustancial de BD) | **Sí (Enfoque principal)** | BDs de geolocalización, bases de datos de threat intel, datos de OpenStreetMap |
| **PDDL 1.0** | Datos en bruto, Datasets | Sí | Sin restricciones | Ninguno | Sí (Renuncia explícita) | Datos de entrenamiento de ML, dumps de métricas en bruto |

---

## 3. Manifests de pipeline de producción y configuraciones de infraestructura

Para garantizar el cumplimiento en miles de assets que no son software en un repositorio cloud-native, las arquitecturas modernas de SRE integran escáneres automatizados de identificación SPDX (Software Package Data Exchange) en los pipelines de CI/CD.

A continuación se presenta un workflow completo y sintácticamente válido de GitHub Actions que ejecuta comprobaciones con `reuse` (estándar FSFE REUSE) y `license-detector` para hacer cumplir un licenciamiento válido de contenido abierto (CC-BY-4.0, CC0-1.0, ODbL-1.0) en documentación, especificaciones OpenAPI y archivos de datos, mientras bloquea licencias no conformes como CC-BY-NC-4.0.

### Manifest completo del pipeline de CI/CD: `.github/workflows/open-content-compliance.yaml`

```yaml
name: Open Content License & SPDX Compliance Pipeline

on:
  push:
    branches:
      - main
      - release/*
  pull_request:
    branches:
      - main

permissions:
  contents: read
  pull-requests: read
  security-events: write

jobs:
  validate-spdx-compliance:
    name: Validate Open Content & Documentation Licensing
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout Source Code and Documentation Assets
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Python 3.12 Environment
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install REUSE Engine Tooling
        run: |
          python -m pip install --upgrade pip
          pip install reuse

      - name: Execute REUSE Open Content Linting
        run: |
          echo "=== Starting REUSE License Verification for Non-Software Assets ==="
          reuse lint

      - name: Scan for Prohibited Non-Free Open Content Licenses (e.g., CC-BY-NC)
        run: |
          echo "=== Scanning Repository for Prohibited Commercial-Restriction Licenses ==="
          FAIL=0
          # Search for forbidden SPDX identifiers in documentation and asset headers
          FORBIDDEN_PATTERNS=("CC-BY-NC-4.0" "CC-BY-NC-SA-4.0" "CC-BY-ND-4.0")
          
          for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
            echo "Searching for prohibited license pattern: ${pattern}"
            MATCHES=$(grep -rn --exclude-dir={.git,.github,node_modules} "${pattern}" . || true)
            if [ -n "${MATCHES}" ]; then
              echo "ERROR: Prohibited license '${pattern}' detected in files:"
              echo "${MATCHES}"
              FAIL=1
            fi
          done
          
          if [ ${FAIL} -eq 1 ]; then
            echo "CRITICAL: Prohibited non-free open content licenses found. Failing build."
            exit 1
          fi
          echo "STATUS: No prohibited non-commercial or no-derivative licenses found."

  openapi-asset-validation:
    name: Verify OpenAPI Specification License Injection
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Validate OpenAPI Documentation License Blocks
        run: |
          echo "=== Checking OpenAPI specification metadata for CC-BY-4.0 / CC0-1.0 ==="
          python3 -c '
import yaml
import sys

try:
    with open("docs/api/openapi.yaml", "r") as f:
        spec = yaml.safe_load(f)
    
    info = spec.get("info", {})
    license_info = info.get("license", {})
    
    name = license_info.get("name")
    url = license_info.get("url")
    identifier = license_info.get("identifier")
    
    print(f"Detected API License: Name={name}, SPDX={identifier}, URL={url}")
    
    valid_spdx = ["CC-BY-4.0", "CC0-1.0", "Apache-2.0", "MIT"]
    if identifier not in valid_spdx:
        print(f"ERROR: Invalid or non-compliant API documentation license SPDX identifier: {identifier}")
        sys.exit(1)
        
    print("SUCCESS: OpenAPI documentation license is compliant.")
except Exception as e:
    print(f"ERROR: Failed to validate openapi.yaml: {e}")
    sys.exit(1)
'
```

---

### Manifest completo de OpenAPI 3.1.0 con licencia CC BY 4.0 embebida: `docs/api/openapi.yaml`

```yaml
openapi: 3.1.0
info:
  title: Enterprise Infrastructure Observability Ingestion API
  description: |
    Production API specification for high-throughput metric and trace telemetry collection.
    This specification documentation is published under the Creative Commons Attribution 4.0
    International License.
  version: 2.4.0
  termsOfService: https://platform.internal.net/terms
  contact:
    name: SRE Platform Architecture Team
    email: sre-platform@internal.net
    url: https://platform.internal.net/support
  license:
    name: Creative Commons Attribution 4.0 International
    url: https://creativecommons.org/licenses/by/4.0/
    identifier: CC-BY-4.0
paths:
  /api/v1/telemetry/metrics:
    post:
      summary: Ingest System Telemetry Metrics
      operationId: ingestMetrics
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/MetricPayload'
      responses:
        '202':
          description: Telemetry accepted for processing asynchronously.
        '400':
          description: Malformed JSON payload or invalid metric schema.
components:
  schemas:
    MetricPayload:
      type: object
      required:
        - timestamp
        - metric_name
        - value
      properties:
        timestamp:
          type: integer
          format: int64
          example: 1775510400
        metric_name:
          type: string
          example: container_cpu_usage_seconds_total
        value:
          type: number
          format: double
          example: 42.1582
```

---

### Archivo de especificación REUSE completo: `.reuse/dep5`

```ini
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Cloud Native Operations Documentation & Datasets
Upstream-Contact: Platform Architecture Team <architecture@internal.net>

# Documentation Markdown Files
Files: docs/*.md docs/**/*.md
Copyright: 2026 Cloud Native Platform Authors
License: CC-BY-4.0

# Architectural Diagrams and Vector Graphics
Files: docs/architecture/diagrams/*.svg docs/architecture/diagrams/*.png
Copyright: 2026 Platform Design Team
License: CC-BY-4.0

# Baseline Telemetry & IP Geolocation Database Files
Files: data/geolocation/*.db data/benchmarks/*.csv
Copyright: 2026 SRE Data Engineering Team
License: ODbL-1.0

# Kubernetes Configuration Manifest Templates
Files: deploy/templates/*.yaml
Copyright: 2026 Infrastructure Engineering Team
License: CC0-1.0
```

---

## 4. Comandos CLI reales y salidas de terminal ($)

### Tarea 1: Auditar el cumplimiento de licencias de contenido abierto mediante `reuse lint`

```bash
$ reuse lint
```

#### Salida esperada de la terminal:
```text
# REUSE Specification Compliance Report
# Started linting process at 2026-08-06T19:09:53Z

* Checking copyright and license information for files...
  - docs/index.md: OK (CC-BY-4.0)
  - docs/architecture/topology.svg: OK (CC-BY-4.0)
  - docs/api/openapi.yaml: OK (CC-BY-4.0)
  - data/geolocation/ip_ranges.csv: OK (ODbL-1.0)
  - deploy/templates/deployment-template.yaml: OK (CC0-1.0)

* Summary:
  - Total files scanned: 142
  - Files with valid copyright and license information: 142 / 142
  - Files missing license headers: 0
  - Unrecognized licenses: 0

Congratulations! Your project is fully compliant with the REUSE specification.
```

---

### Tarea 2: Detección de contaminación prohibida por CC-BY-NC mediante `grep` y `spdx-tools`

```bash
$ grep -E -rn "CC-BY-NC|CC-BY-ND|GFDL-1\.1" ./docs ./data
```

#### Salida esperada de la terminal (caso de fallo):
```text
./docs/runbooks/disaster-recovery.md:4:<!-- SPDX-License-Identifier: CC-BY-NC-SA-4.0 -->
./data/benchmarks/storage_latency.csv:1:# License: CC-BY-NC-4.0 Commercial Usage Prohibited
```

```bash
$ echo "Exit Code: $?"
```
```text
Exit Code: 0
```

---

### Tarea 3: Inspeccionar metadatos de documentos PDF / imágenes en busca de etiquetas de licencia mediante `exiftool`

```bash
$ exiftool -Rights -Copyright -UsageTerms docs/architecture/datacenter-topology.pdf
```

#### Salida esperada de la terminal:
```text
Rights                          : Creative Commons Attribution 4.0 International (CC BY 4.0)
Copyright                       : (c) 2026 Enterprise Platform Architecture Corp.
Usage Terms                     : https://creativecommons.org/licenses/by/4.0/
```

---

### Tarea 4: Generar un documento SPDX 2.3 para assets que no son software

```bash
$ reuse spdx --output open-content-bom.spdx
$ head -n 35 open-content-bom.spdx
```

#### Salida esperada de la terminal:
```text
SPDXVersion: SPDX-2.3
DataLicense: CC0-1.0
SPDXID: SPDXRef-DOCUMENT
DocumentName: Platform-Documentation-And-Data-Assets
DocumentNamespace: https://spdx.org/spdxdocs/platform-docs-v1.0-6a89c9e0
Creator: Tool: reuse-3.0.2
Created: 2026-08-06T19:09:53Z

FileName: ./docs/architecture/topology.svg
SPDXID: SPDXRef-File-docs-architecture-topology.svg-1
FileChecksum: SHA1: c83a9182bf9e018a7d189f38e219ba8b8e01b7a2
LicenseConcluded: CC-BY-4.0
LicenseInfoInFile: CC-BY-4.0
FileCopyrightText: 2026 Infrastructure Engineering Team

FileName: ./data/geolocation/ip_ranges.csv
SPDXID: SPDXRef-File-data-geolocation-ip-ranges.csv-2
FileChecksum: SHA1: a45b9101ef01928a7d289f48e319ba8b9e02c9b1
LicenseConcluded: ODbL-1.0
LicenseInfoInFile: ODbL-1.0
FileCopyrightText: 2026 SRE Data Engineering Team
```

---

## 5. Guía de verificación, diagnóstico y resolución de fallos

### Escenarios de fallo en producción y diagramas de flujo de diagnóstico

```
                       +----------------------------------------------------+
                       | NON-SOFTWARE ASSET LICENSE INGESTION DIAGNOSTIC    |
                       +----------------------------------------------------+
                                                 |
                                                 v
                       +----------------------------------------------------+
                       | Is the asset text documentation, graphics, data,   |
                       | or an AI model weight repository?                  |
                       +----------------------------------------------------+
                                                 |
                                 +---------------+---------------+
                                 |                               |
                                 v                               v
                        [DATASET / DATABASE]             [DOCUMENTATION / MEDIA]
                                 |                               |
                                 v                               v
                       +-------------------+           +-------------------+
                       | Does it use ODbL, |           | Does it contain   |
                       | PDDL, or ODC-BY?  |           | NC or ND clauses? |
                       +-------------------+           +-------------------+
                         |               |               |               |
                        YES              NO             YES              NO
                         |               |               |               |
                         v               v               v               v
                      [PASS]      +-------------+   [CRITICAL FAIL]   +-------------+
                                  | Check for   |   Commercial use    | Does it use |
                                  | Database    |   or modifications  | CC BY / SA  |
                                  | Extraction  |   are legally       | or CC0?     |
                                  | Violation   |   blocked.          +-------------+
                                  +-------------+                            |
                                                                             v
                                                                          [PASS]
```

---

### Matriz de fallos y acciones de remediación

| Escenario de fallo | Causa raíz | Impacto sistémico | Acción de remediación |
| :--- | :--- | :--- | :--- |
| **El pipeline de build falla en `reuse lint` con `Missing License Header`** | Se agregó un nuevo asset `.md` o `.svg` sin etiqueta de encabezado SPDX o regla `.dep5`. | Bloqueo de PR; proceso de build de documentación abortado. | Agregar `<!-- SPDX-License-Identifier: CC-BY-4.0 -->` al encabezado del archivo de texto o actualizar `.reuse/dep5`. |
| **Despliegue de SaaS comercial rechazado por auditoría legal debido a `CC BY-NC-SA`** | Runbook de proveedor externo incorporado al portal empresarial que contiene la etiqueta NC. | Monetización de la plataforma detenida; riesgo legal de infracción de derechos de autor. | Contactar al propietario del contenido para relicenciar bajo `CC BY 4.0`, o reescribir completamente el runbook de manera independiente. |
| **Discordancia de licencia en la especificación OpenAPI** | `/info/license/identifier` establecido en `GPL-3.0` para la especificación JSON/YAML en lugar de `CC0-1.0` o `CC-BY-4.0`. | Los generadores automatizados de SDK fallan con etiquetas de licencia no estándar para assets que no son software. | Actualizar el bloque de info de YAML de OpenAPI con la cadena SPDX correcta (`CC-BY-4.0` o `CC0-1.0`). |
| **Fallo en el pipeline de ingestión de datos bajo ODbL ShareAlike** | Base de datos analítica propietaria unida con un dataset externo bajo licencia ODbL. | Se crea una base de datos derivada, lo que activa la cláusula de copyleft de ODbL para los datos propietarios. | Aislar la base de datos ODbL mediante búsquedas por API independientes; evitar joins/merges físicos de bases de datos. |
| **Incompatibilidad entre bloques de texto GFDL y CC BY-SA** | Importación directa de contenido de manual de GNU a una wiki de plataforma en CC BY-SA. | Violación de licencia de derechos de autor debido a Secciones invariantes de GFDL y términos de copyleft incompatibles. | Mantener el texto GFDL en un apéndice aislado y sin modificaciones, u obtener derechos explícitos de licencia doble. |

---

### Procedimiento de diagnóstico y resolución paso a paso

Si un pipeline de SRE marca un asset de contenido abierto no conforme durante un build de despliegue automatizado:

1. **Identificar el tipo y ubicación del asset:**
   Ejecute `reuse lint` o `license-detector` para obtener la ruta relativa exacta del artefacto en infracción:
   ```bash
   $ reuse lint --file-costs
   ```

2. **Verificar la integridad del identificador SPDX:**
   Verifique si el encabezado de licencia sigue la nomenclatura estándar de SPDX (por ejemplo, `CC-BY-4.0` en lugar de la cadena legada `Creative Commons 4.0`):
   ```bash
   $ grep -i "spdx-license-identifier" path/to/failing-asset.md
   ```

3. **Verificar la compatibilidad de licencias para derivados:**
   - Si se combina texto bajo **CC BY 4.0** con **CC BY-SA 4.0**, la salida combinada **DEBE** licenciarse bajo **CC BY-SA 4.0**.
   - Si se combina **CC0-1.0** con **CC BY 4.0**, la salida puede permanecer bajo **CC BY 4.0**.
   - **NUNCA** combine **CC BY-NC-4.0** con material de producción empresarial.

4. **Remediar el mapeo SPDX mediante `.reuse/dep5`:**
   Para assets binarios que no son software (por ejemplo, `.png`, `.pdf`, `.db`) que no pueden contener encabezados de comentarios de texto, agregue coincidencias explícitas de patrones de archivo bajo `.reuse/dep5`:
   ```ini
   Files: docs/assets/architecture-overview.pdf
   Copyright: 2026 Infrastructure Engineering Team
   License: CC-BY-4.0
   ```

5. **Reejecutar la verificación automatizada del pipeline:**
   ```bash
   $ reuse lint && echo "Pipeline Pre-flight Check Successful"
   ```

---

## 6. Referencias

- **Visión general de LPI Open Source Essentials y objetivos del examen:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

- **Especificaciones oficiales de licencias Creative Commons (v4.0 Internacional):**  
  [https://creativecommons.org/licenses/by/4.0/legalcode](https://creativecommons.org/licenses/by/4.0/legalcode)

- **Dedicación al dominio público universal Creative Commons CC0 1.0:**  
  [https://creativecommons.org/publicdomain/zero/1.0/legalcode](https://creativecommons.org/publicdomain/zero/1.0/legalcode)

- **Licencia de base de datos abierta (ODbL) v1.0 de Open Data Commons:**  
  [https://opendatacommons.org/licenses/odbl/1-0/](https://opendatacommons.org/licenses/odbl/1-0/)

- **Licencia de documentación libre de GNU (GFDL) v1.3:**  
  [https://www.gnu.org/licenses/fdl-1.3.html](https://www.gnu.org/licenses/fdl-1.3.html)

- **Lista de licencias e identificadores estándar de SPDX:**  
  [https://spdx.org/licenses/](https://spdx.org/licenses/)

- **Especificación FSFE REUSE para el licenciamiento de assets de software y documentación:**  
  [https://reuse.software/spec/](https://reuse.software/spec/)