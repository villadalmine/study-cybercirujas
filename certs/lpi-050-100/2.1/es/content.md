# Guía de Estudio LPI 050-100 — Tema 2.1: Conceptos de Licencias de Software de Código Abierto

**Certificación Objetivo:** LPI Open Source Essentials (Examen 050-100)  
**Tema:** 2.1 Conceptos de Licencias de Software de Código Abierto (Ponderación: 7.5)  
**Audiencia Objetivo:** SREs, Platform Architects y Cloud Native Security Engineers  

---

## 1. Motivación Arquitectónica de Producción e Ingeniería de Riesgos Legales

### El Problema de Producción: Contaminación de la Cadena de Suministro e Infección por Copyleft
En entornos empresariales cloud-native, las arquitecturas de software modernas dependen en gran medida de la contenedorización, árboles de dependencias dinámicos y componentes de software de código abierto (OSS). Una sola imagen de contenedor en un cluster de Kubernetes de producción a menudo contiene cientos de paquetes a nivel de sistema operativo (por ejemplo, `apt`, `apk`) y dependencias de tiempo de ejecución de lenguajes (por ejemplo, `npm`, `Go modules`, `PyPI`).

Sin una gobernanza automatizada, las cadenas de suministro de software se enfrentan a severos riesgos legales y operacionales:
1. **Contaminación por Copyleft (Efecto Viral):** Incluir una biblioteca licenciada bajo una licencia de copyleft fuerte (por ejemplo, GNU General Public License v3 / GPL-3.0) dentro de un código fuente propietario o vincularse a ella de forma dinámica/estática puede exigir legalmente que *toda la aplicación empresarial* sea relicenciada y distribuida públicamente bajo la GPL-3.0.
2. **Disparadores de Copyleft de Red (Fuga en SaaS):** Bajo la GNU Affero General Public License v3 (AGPL-3.0), interactuar con el software a través de una red (por ejemplo, mediante una REST API, gRPC o RPC de microservicios) sin distribución física aún activa el requisito de copyleft. Alojar un componente AGPL modificado o no modificado como un microservicio backend obliga al operador a hacer que el código fuente completo del servicio que interactúa sea accesible para todos los usuarios de la red.
3. **Riesgo de Represalias por Patentes:** Las licencias permisivas sin concesiones explícitas de patentes (como las primeras licencias BSD o MIT) dejan a las empresas vulnerables a demandas por infracción de patentes por parte de colaboradores upstream. Por el contrario, las licencias modernas con cláusulas explícitas de rescisión de patentes (por ejemplo, Apache-2.0 sección 3) anulan automáticamente los derechos de licencia si un licenciatario presenta una demanda de patente contra el proyecto.

```
+-----------------------------------------------------------------------------------+
|                        ENTERPRISE MICROSERVICE ARCHITECTURE                        |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  +--------------------------+          +---------------------------------------+  |
|  | Proprietary App Service  |  gRPC    | AGPL-3.0 Microservice (e.g., DB/Cache)|  |
|  | (Closed-Source Binary)   |--------->| (Triggers source code release request |  |
|  +------------+-------------+          |  to all end-users via Network Clause) |  |
|               |                        +---------------------------------------+  |
|               | Dynamic Linking                                                   |
|               v                                                                   |
|  +--------------------------+          +---------------------------------------+  |
|  | GPL-3.0 Shared Library   |          | Apache-2.0 / MIT Component            |  |
|  | (Triggers Copyleft for   |          | (Permissive: Requires Notice/Attrib)  |  |
|  |  entire host binary)     |          +---------------------------------------+  |
|  +--------------------------+                                                     |
+-----------------------------------------------------------------------------------+
```

### Primitivas de Propiedad Intelectual: El Copyright como Mecanismo de Aplicación
Todas las licencias de código abierto derivan su exigibilidad legal del **Derecho de Autor** (por ejemplo, Título 17 del Código de EE. UU., Convenio de Berna). Bajo la ley de derecho de autor:
* **Derechos por Defecto:** El creador de una obra de software posee derechos exclusivos para copiar, modificar, distribuir, ejecutar y mostrar el código. Sin una concesión explícita de derechos, todo uso por parte de terceros constituye una **infracción de derechos de autor**.
* **El Rol de la Licencia:** Una licencia de código abierto es un contrato/concesión legal en el que el titular de los derechos de autor renuncia a ciertos derechos exclusivos en favor del público, sujeto a **condiciones** y **obligaciones** específicas.
* **Condiciones vs. Pactos:** Las obligaciones de cumplimiento (por ejemplo, conservar archivos `LICENSE`, divulgar el código fuente) operan como condiciones previas a la concesión del derecho de autor. Si un SRE despliega software violando estas condiciones, la concesión de la licencia se termina automáticamente, transformando el despliegue operacional en una infracción activa de derechos de autor.

### Marcos Institucionales: OSI OSD vs. FSF Cuatro Libertades

Los arquitectos de plataformas deben diferenciar entre los marcos de gobernanza definidos por la **Open Source Initiative (OSI)** y la **Free Software Foundation (FSF)**.

```
                     +---------------------------------------+
                     |         SOFTWARE FREEDOM SPACE        |
                     |                                       |
                     |   +-------------------------------+   |
                     |   |    FSF "Free Software"        |   |
                     |   |  Focus: Ethical User Liberty  |   |
                     |   |    (Four Essential Freedoms)  |   |
                     |   +---------------+---------------+   |
                     |                   |                   |
                     |                   | Intersection      |
                     |                   v                   |
                     |   +---------------+---------------+   |
                     |   |    OSI "Open Source"          |   |
                     |   |  Focus: Pragmatic Legal &     |   |
                     |   |  Development Methodology (OSD)|   |
                     |   +-------------------------------+   |
                     +---------------------------------------+
```

#### 1. FSF Cuatro Libertades Esenciales
La FSF se centra en la autonomía del usuario y la distribución ética del software:
* **Libertad 0:** La libertad de ejecutar el programa para cualquier propósito.
* **Libertad 1:** La libertad de estudiar cómo funciona el programa y cambiarlo para que haga su cómputo como usted desee (el acceso al código fuente es una condición previa).
* **Libertad 2:** La libertad de redistribuir copias para que pueda ayudar a su vecino.
* **Libertad 3:** La libertad de distribuir copias de sus versiones modificadas a terceros (el acceso al código fuente es una condición previa).

#### 2. Definición de Código Abierto de la OSI (OSD)
La OSI mantiene una lista de verificación de 10 puntos que garantiza que el software cumpla con los estándares comerciales y operacionales:
1. **Libre Redistribución:** Sin restricciones para vender o regalar el software.
2. **Código Fuente:** El código fuente no ofuscado debe distribuirse o ponerse a disposición explícitamente.
3. **Obras Derivadas:** Las modificaciones y obras derivadas deben permitirse bajo los mismos términos.
4. **Integridad del Código Fuente del Autor:** Se pueden requerir archivos de parche, pero la ejecución no debe restringirse.
5. **No Discriminación contra Personas o Grupos:** Garantías de acceso universal.
6. **No Discriminación contra Campos de Trabajo:** No se puede restringir el uso en entornos comerciales, militares o de investigación.
7. **Distribución de la Licencia:** Los derechos se aplican a todos los receptores secundarios sin contratos adicionales.
8. **La Licencia No Debe Ser Específica de un Producto:** La licencia no puede depender de la inclusión en una distribución específica.
9. **La Licencia No Debe Restringir Otro Software:** No puede exigir que el software agregado en el mismo medio sea de código abierto.
10. **La Licencia Debe Ser Tecnológicamente Neutra:** No puede requerir una conformidad específica de la interfaz (por ejemplo, contratos tipo click-through).

---

## 2. Taxonomía Técnica y Matriz de Trade-offs

### Matriz de Comparación Arquitectónica

| Categoría de Licencia | IDs de SPDX Representativos | Divulgación Recíproca de Código Fuente (Copyleft) | Concesión / Protección de Patentes | Exención de SaaS Comercial | ¿El Límite de Vinculación Aísla el Copyleft? |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Permissive** | `MIT`, `BSD-3-Clause`, `Apache-2.0` | Ninguna | `Apache-2.0` (Sí, Sec 3); `MIT`/`BSD` (Sin concesión explícita) | Sí | Sí (No existe copyleft) |
| **Weak Copyleft** | `LGPL-3.0-only`, `MPL-2.0`, `EPL-2.0` | Limitada a archivos modificados o código directo de la biblioteca | `LGPL-3.0` (Sí); `MPL-2.0` (Sí) | Sí (Si es una llamada a biblioteca no modificada) | Sí (La vinculación dinámica o el aislamiento a nivel de archivo protege al host) |
| **Strong Copyleft** | `GPL-2.0-only`, `GPL-3.0-only` | Total (Todas las obras derivadas y binarios vinculados) | `GPL-3.0` (Sí); `GPL-2.0` (Implícita/No clara) | Sí (Si se aloja a través de API de red sin distribución binaria) | No (La vinculación estática y dinámica infecta la aplicación host) |
| **Network Copyleft** | `AGPL-3.0-only` | Total (Incluye interacciones remotas en red) | Sí (Cláusula a través de la base GPLv3) | **NO** (Se activa en el consumo de API / SaaS) | No (El límite IPC/Red **no** protege al host de la divulgación) |
| **Source-Available / Business** | `SSPL-1.0`, `BSL-1.1` | Extrema (Requiere código de infraestructura de gestión) | Varía | **NO** (Prohíbe explícitamente ofertas cloud competidoras) | No aprobada por la OSI; la licencia se activa bajo despliegue cloud |

---

### Análisis Profundo de los Mecanismos de Licencia

```
+---------------------------------------------------------------------------------------+
|                              COPYLEFT EXTENSION BOUNDARIES                             |
+---------------------------------------------------------------------------------------+
|                                                                                       |
|  PERMISSIVE (MIT/Apache):                                                             |
|  [ Your Proprietary Code ] ===(Imports/Links)===> [ MIT Code ]                        |
|  Result: Entire binary remains Proprietary.                                           |
|                                                                                       |
|  WEAK COPYLEFT (LGPL/MPL):                                                            |
|  [ Your Proprietary Code ] ---(Dynamic Link/Header)---> [ LGPL Library ]              |
|  Result: Your code remains Proprietary. Modifications to LGPL Library MUST be shared. |
|                                                                                       |
|  STRONG COPYLEFT (GPL):                                                               |
|  [ Your Proprietary Code ] ===(Static/Dynamic Link)===> [ GPL Library ]               |
|  Result: Entire binary MUST be licensed under GPL and source code disclosed.          |
|                                                                                       |
|  NETWORK COPYLEFT (AGPL):                                                             |
|  [ Your App Front-End ] -----(gRPC / REST API)-----> [ AGPL Backend Service ]         |
|  Result: Entire App Front-End source code MUST be released to end-users.              |
+---------------------------------------------------------------------------------------+
```

#### 1. Licencia Apache 2.0 (`Apache-2.0`)
* **Mecanismo:** Licencia permisiva con fuertes primitivas de protección corporativa.
* **Protección de Patentes:** Contiene una concesión explícita de derechos de patente de cada colaborador hacia el usuario. La Sección 3 incluye una **Cláusula de Patentes de Represalia**: si una entidad inicia un litigio de patentes contra cualquier colaborador alegando que la obra constituye una infracción de patentes, todas las licencias de patentes concedidas bajo `Apache-2.0` para esa obra finalizan inmediatamente.
* **Cambios de Estado:** La Sección 4(b) exige que los archivos modificados lleven avisos destacados indicando que el código fue cambiado.

#### 2. GNU General Public License v3 (`GPL-3.0-only`)
* **Mecanismo:** Copyleft fuerte que requiere la relicenciación completa de obras derivadas.
* **Cláusula de Tivoización (Sección 6):** Promulgada para evitar que los proveedores de hardware ejecuten software GPLv3 en sistemas embebidos que aplican verificaciones de firma para bloquear software modificado (una práctica llamada así por TiVo). Requiere proporcionar Información de Instalación completa (claves, firmas) junto con el código fuente.
* **Rescisión de Patentes (Sección 11):** Asegura a los usuarios secundarios que los distribuidores upstream que transmiten código GPLv3 otorgan automáticamente licencias de cualquier patente que posean y que cubra el software.

#### 3. GNU Affero General Public License v3 (`AGPL-3.0-only`)
* **Mecanismo:** Copyleft fuerte de red diseñado específicamente para plataformas SaaS.
* **Sección 13 (Interacción Remota en Red):** Cierra el "vacío legal de SaaS" de GPLv3. Si una versión modificada de software AGPL-3.0 se ejecuta en un servidor e interactúa con los usuarios remotamente a través de una red informática, el operador **debe** ofrecer a esos usuarios acceso al código fuente correspondiente a través de la red sin cargo (típicamente a través de un enlace destacado `Download Source` en la UI o endpoint de la API).

#### 4. Licencias de Código Disponible / No OSI (`SSPL-1.0`, `BSL-1.1`)
* **Server Side Public License (SSPL-1.0):** Creada por MongoDB. Extiende la Sección 13 de AGPL-3.0 de modo que si una entidad ofrece el software como un servicio comercial, debe liberar el código fuente de **todo** el software de gestión, scripts de automatización, software de respaldo, capas de almacenamiento y herramientas de monitoreo utilizadas para ejecutar el servicio. **No aprobada por la OSI** porque viola el Criterio 1 (Libre Redistribución) y el Criterio 6 (Campo de Trabajo) de la OSD.
* **Business Source License (BSL-1.1 / BUSL):** Utilizada por HashiCorp (Terraform, Vault) y CockroachDB. Otorga derechos para copiar, modificar y redistribuir, pero prohíbe el uso en producción para micro-casos de uso comerciales especificados (por ejemplo, plataformas de servicios gestionados) durante un tiempo determinado (Change Date, máximo 4 años), después del cual se convierte automáticamente en una licencia aprobada por la OSI (por ejemplo, Apache-2.0 o GPL-2.0). **No es una licencia de código abierto durante el período con licencia inicial.**

---

## 3. Manifiestos de Producción Completos e Infraestructura de Pipelines

### A. Pipeline Automatizado de Cumplimiento CI/CD
Archivo: `.github/workflows/license-compliance-sbom.yml`

```yaml
name: Production FOSS License Compliance and SBOM Generation

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  pull-requests: write
  security-events: write

jobs:
  license-compliance:
    name: Audit FOSS Licenses & Generate SPDX SBOM
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Go Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Install Compliance CLI Tools
        run: |
          set -euo pipefail
          echo "=== Installing Syft (SBOM Generator) ==="
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v1.3.0
          
          echo "=== Installing Trivy (License Scanner) ==="
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.50.1
          
          echo "=== Installing REUSE (Header Auditor) ==="
          python3 -m pip install --no-cache-dir reuse==3.0.2
          
          syft --version
          trivy --version
          reuse --version

      - name: Audit File Header License Compliance (REUSE Standard)
        run: |
          set -euo pipefail
          echo "=== Checking REUSE Specification Compliance ==="
          reuse lint

      - name: Generate Machine-Readable SPDX v2.3 SBOM
        run: |
          set -euo pipefail
          echo "=== Generating SPDX JSON SBOM for Workspace ==="
          syft dir:. --output spdx-json=sbom.spdx.json

      - name: Enforce Policy Gates via Trivy License Scanning
        run: |
          set -euo pipefail
          echo "=== Executing License Enforcement Scan ==="
          # Severities mapped to prohibited license categories:
          # AGPL-3.0, SSPL-1.0, BSL-1.1 generate CRITICAL violations.
          # GPL-3.0, LGPL-3.0 generate HIGH violations.
          trivy fs \
            --security-checks license \
            --severity HIGH,CRITICAL \
            --exit-code 1 \
            --format table \
            .

      - name: Upload SPDX SBOM Artifact
        uses: actions/upload-artifact@v4
        with:
          name: sbom-spdx-json
          path: sbom.spdx.json
          retention-days: 90
```

---

### B. Software Bill of Materials (SBOM) SPDX v2.3 Válido
Archivo: `sbom.spdx.json`

```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-06T19:00:00Z",
    "creators": [
      "Organization: Enterprise Platform Architecture Team",
      "Tool: Anchore Syft-v1.3.0"
    ],
    "licenseListVersion": "3.23"
  },
  "name": "payment-gateway-service-container",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://spdx.org/spdxdocs/payment-gateway-service-v1.4.2-7a8f9e0d-8c4b",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-ContainerImage-payment-gateway",
      "name": "payment-gateway-service",
      "versionInfo": "v1.4.2",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright 2026 Enterprise Financial Corp",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:oci/payment-gateway-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-GoModule-gin-gonic",
      "name": "github.com/gin-gonic/gin",
      "versionInfo": "v1.9.1",
      "downloadLocation": "https://github.com/gin-gonic/gin",
      "filesAnalyzed": false,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "copyrightText": "Copyright (c) 2014 Manuel Martinez-Almeida",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:golang/github.com/gin-gonic/gin@v1.9.1"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-Debian-libc6",
      "name": "libc6",
      "versionInfo": "2.36-9+deb12u4",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "LGPL-2.1-or-later",
      "licenseDeclared": "LGPL-2.1-or-later",
      "copyrightText": "Copyright (C) 1991-2022 Free Software Foundation, Inc.",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/libc6@2.36-9+deb12u4?arch=amd64"
        }
      ]
    }
  ],
  "relationships": [
    {
      "spdxElementId": "SPDXRef-DOCUMENT",
      "relatedSpdxElement": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relationshipType": "DESCRIBES"
    },
    {
      "spdxElementId": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relatedSpdxElement": "SPDXRef-Package-GoModule-gin-gonic",
      "relationshipType": "DEPENDS_ON"
    },
    {
      "spdxElementId": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relatedSpdxElement": "SPDXRef-Package-Debian-libc6",
      "relationshipType": "DEPENDS_ON"
    }
  ]
}
```

---

### C. Política de Licencias para Control de Admisión Kyverno en Kubernetes
Archivo: `license-compliance-policy.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-container-license-compliance
  annotations:
    policies.kyverno.io/title: Block Unapproved Open Source Licenses
    policies.kyverno.io/category: Supply Chain Security & Governance
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Container Image
    policies.kyverno.io/description: >-
      Scans container images entering the cluster to block execution of software
      carrying high-risk licenses (AGPL-3.0, SSPL-1.0, BSL-1.1, GPL-3.0) 
      violating corporate legal compliance policy.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-no-banned-licenses
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Deployment rejected: Image contains dependencies under prohibited licenses (AGPL-3.0, SSPL-1.0, BSL-1.1, or GPL-3.0)."
        foreach:
          - list: "request.object.spec.containers"
            elementScope: true
            deny:
              conditions:
                all:
                  - key: "{{ image_licenses(element.image) }}"
                    operator: AnyIn
                    value:
                      - "AGPL-3.0-only"
                      - "AGPL-3.0-or-later"
                      - "SSPL-1.0"
                      - "BSL-1.1"
                      - "GPL-3.0-only"
                      - "GPL-3.0-or-later"
```

---

## 4. Orquestación CLI en el Mundo Real y Salidas de Terminal

### Escenario 1: Generación e Inspección de un SBOM a través de `syft`

```bash
$ syft dir:. -o table
```

**Expected Terminal Output:**

```text
[0000]  INFO Syft version: 1.3.0
[0000]  INFO loading metadata for source: .
[0001]  INFO cataloging packages
 [Packages] 📦 3 packages identified

NAME                    VERSION        TYPE          LICENSE           
github.com/gin-gonic/gin v1.9.1        go-module     MIT               
github.com/mattn/go-isatty v0.0.19       go-module     MIT               
golang.org/x/net        v0.17.0        go-module     BSD-3-Clause      

✔ Cataloged packages [3 packages]
```

---

### Escenario 2: Bloqueo de una Construcción de CI debido a un Disparador de Contaminación AGPL-3.0

```bash
$ trivy fs --security-checks license --severity CRITICAL --exit-code 1 .
```

**Expected Terminal Output:**

```text
2026-08-06T19:05:12.102Z	INFO	[license] License scanning is enabled
2026-08-06T19:05:12.441Z	INFO	Number of language-specific files: 1
2026-08-06T19:05:12.441Z	INFO	Detecting Go dependencies licenses...

go.mod (gomod)

Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

+-----------------------+------------------+----------+---------------+----------------------------------+
|        PACKAGE        | LICENSE CATEGORY | SEVERITY |  LICENSE NAME |             CAPTION              |
+-----------------------+------------------+----------+---------------+----------------------------------+
| github.com/affero/db  | Restricted       | CRITICAL | AGPL-3.0-only | Forbidden license in commercial  |
|                       |                  |          |               | SaaS application deployment      |
+-----------------------+------------------+----------+---------------+----------------------------------+

Error: exit status 1
```

---

### Escenario 3: Validación de Encabezados de Copyright y Licencia a través de `reuse`

```bash
$ reuse lint
```

**Expected Terminal Output:**

```text
# Synthesis of lint result
Summary of compliance checks:
* Compliant: 42 files
* Non-compliant: 2 files
* Total files: 44

The following files have missing copyright or license information:
* pkg/payment/processor.go
* scripts/deploy-production.sh

================================================================================
FAILURE: Project does not conform to the REUSE specification version 3.0.
================================================================================
```

---

## 5. Guía de Verificación y Resolución de Problemas de Diagnóstico

```
+-----------------------------------------------------------------------------------+
|                        FOSS LICENSE TRIAGE & DIAGNOSTIC TREE                      |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|                   [ CI/CD Pipeline License Gate Failed ]                          |
|                                     |                                             |
|                                     v                                             |
|               What type of License Violation was reported?                        |
|                                     |                                             |
|        +----------------------------+----------------------------+                |
|        |                                                         |                |
|        v                                                         v                |
| [ Missing Header / Notice ]                             [ Prohibited License ]    |
|        |                                                         |                |
|        v                                                         v                |
| Fix: Add SPDX header to file:                         Is it a direct or           |
| // SPDX-License-Identifier: Apache-2.0                transitive dependency?      |
| // SPDX-FileCopyrightText: 2026 Corp                             |                |
|                                            +---------------------+----------------+
|                                            |                                      |
|                                            v                                      v
|                                    [ Direct Dep ]                 [ Transitive Dep ]
|                                            |                                      |
|                                            v                                      v
|                                    Replace library or             Use go.mod replace /
|                                    isolate via network RPC        npm override / vendor
|                                    sidecar container.             patch & update tree.
+-----------------------------------------------------------------------------------+
```

### Matriz de Triaje para Fallos de Cumplimiento

| Síntoma de Error | Causa Raíz | Comando de Diagnóstico | Acción de Remediación |
| :--- | :--- | :--- | :--- |
| **`CRITICAL: AGPL-3.0-only detected`** | Inclusión directa o transitiva de un paquete con copyleft de red. | `go mod why -m github.com/vendor/agpl-pkg` o `npm ls <pkg>` | 1. Reemplazar con un equivalente permisivo.<br>2. Si es irreemplazable, aislar la ejecución en un microservicio externo delimitado puramente por APIs de red (RPC/HTTP) y liberar como código abierto ese subservicio específico. |
| **`HIGH: GPL-3.0 detected in shared library`** | Vinculación directa de una biblioteca dinámica/estática GPL-3.0 en un binario propietario. | `ldd /path/to/binary` o `syft image:<image-tag>` | 1. Reemplazar con una alternativa `LGPL-3.0` o `MIT`/`Apache-2.0`.<br>2. Recompilar la biblioteca con límites de vinculación dinámica si es LGPL, asegurando que el usuario pueda sustituir el archivo objeto. |
| **`REUSE Lint Missing License/Copyright`** | El archivo de código fuente carece de encabezado de etiqueta SPDX. | `reuse lint` | Ejecutar `reuse annotate --license Apache-2.0 --copyright "Enterprise Corp" path/to/file.go`. |
| **`SPDX Parsing Error: Unknown License`** | Cadena de licencia personalizada o no estándar encontrada en el manifiesto de dependencias. | `syft dir:. -o json \| jq '.packages[] \| select(.licenseDeclared == "NOASSERTION")'` | Inspeccionar el archivo `LICENSE` del repositorio del paquete. Mapear manualmente en la configuración de escaneo mediante reglas personalizadas de anulación de SPDX. |

---

### Protocolo de Remediación de Incidentes Paso a Paso

#### Problema: Una dependencia transitiva profunda introduce un componente GPL-3.0 en un servicio empresarial escrito en Go.

1. **Rastrear la Ruta de la Dependencia:**
   ```bash
   $ go mod why -m github.com/gpl-author/copyleft-lib
   ```
   *Output:*
   ```text
   # github.com/gpl-author/copyleft-lib
   main-service/pkg/telemetry
   github.com/intermediate/framework
   github.com/gpl-author/copyleft-lib
   ```

2. **Aislar o Reemplazar mediante Anulaciones (Overrides) de Dependencias:**
   Si el framework intermedio se puede actualizar o forzar a usar un fork permisivo, configure el manifiesto de su gestor de paquetes (`go.mod`):
   ```go
   module main-service

   go 1.22

   require (
       github.com/intermediate/framework v1.4.0
   )

   // Override copyleft transitive dependency with permissive maintained fork
   replace github.com/gpl-author/copyleft-lib v1.0.0 => github.com/enterprise-forks/copyleft-lib-mit v1.0.1-mit
   ```

3. **Volver a Ejecutar la Puerta de Verificación Automatizada:**
   ```bash
   $ syft dir:. -o json | jq '.packages[] | select(.name | contains("copyleft-lib"))'
   $ trivy fs --security-checks license --severity HIGH,CRITICAL --exit-code 1 .
   ```

---

## 6. Referencias

* **Sitio Oficial del Linux Professional Institute (LPI):**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **La Definición de Código Abierto de la Open Source Initiative (OSI):**  
  [https://opensource.org/osd](https://opensource.org/osd)
* **La Definición de Software Libre de la Free Software Foundation (FSF):**  
  [https://www.gnu.org/philosophy/free-sw.html](https://www.gnu.org/philosophy/free-sw.html)
* **Lista de Licencias y Especificación SPDX (Linux Foundation):**  
  [https://spdx.org/licenses/](https://spdx.org/licenses/)
* **Especificación REUSE para Metadatos de Licencias de Software:**  
  [https://reuse.software/spec/](https://reuse.software/spec/)
* **Anchore Syft (Documentación del Generador de SBOM):**  
  [https://github.com/anchore/syft](https://github.com/anchore/syft)
* **Escáner de Licencias Trivy (Aqua Security):**  
  [https://aquasecurity.github.io/trivy/latest/docs/coverage/license/](https://aquasecurity.github.io/trivy/latest/docs/coverage/license/)
* **Motor de Políticas de Cluster Kyverno (Proyecto Graduado de la CNCF):**  
  [https://kyverno.io/docs/policies/](https://kyverno.io/docs/policies/)