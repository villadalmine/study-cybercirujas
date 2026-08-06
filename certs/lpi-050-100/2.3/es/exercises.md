# LPI 050-100 | Topic 2.3: Permissive Software Licenses
**Certificación Objetivo:** LPI Open Source Essentials (Exam 050-100)  
**Ponderación del Tema:** 7.5  
**Nivel:** Advanced Production & Platform Architecture  

---

## 1. Deep Technical Architecture & Legal Mechanics

Las licencias de software permisivas (a menudo denominadas licencias *académicas* o *de solo atribución*) otorgan amplios derechos a los usuarios finales y desarrolladores downstream con mínimas restricciones. A diferencia de las licencias Copyleft (como GNU GPL o AGPL) que exigen un licenciamiento recíproco para obras derivadas, las licencias permisivas permiten la integración downstream en sistemas de código cerrado, propietarios o con licencias de código abierto diferentes, siempre que se conserven la atribución y las exenciones de responsabilidad de garantía.

```
                      +------------------------------------------+
                      |        Permissive Source Code            |
                      |   (MIT, BSD-3-Clause, Apache-2.0)       |
                      +--------------------+---------------------+
                                           |
                   +-----------------------+-----------------------+
                   |                                               |
                   v                                               v
     +---------------------------+                   +---------------------------+
     |   Downstream Proprietary  |                   |   Downstream Copyleft     |
     |   Commercial Product      |                   |   (GPLv3 / AGPLv3)        |
     +-------------+-------------+                   +-------------+-------------+
                   |                                               |
                   v                                               v
     +---------------------------+                   +---------------------------+
     | Retain Copyright Notice & |                   | Retain Copyright Notice,  |
     | Disclaimer; Code can be   |                   | Source must be opened     |
     | kept closed-source.       |                   | under Copyleft terms.     |
     +---------------------------+                   +---------------------------+
```

### Componentes Legales y de Ingeniería Principales de las Licencias Permisivas

1. **Preservación del Aviso de Copyright y Atribución:**  
   Los redistribuidores downstream deben conservar el encabezado de copyright original, la atribución del autor y el texto completo de la licencia (o enlace, según los términos específicos de la licencia).
2. **Exención de Garantía y Limitación de Responsabilidad:**  
   Protege a los autores y colaboradores contra responsabilidades legales o daños derivados de fallas del software (condición "AS IS").
3. **Concesiones de Patentes (Explícitas vs. Implícitas):**  
   - **MIT / BSD:** Silenciosas sobre los derechos de patentes. Otorgan derechos para "use, copy, modify, merge, publish, distribute, sublicense", lo que implica una licencia de patente, pero carecen de una cláusula explícita de concesión de patentes.
   - **Apache-2.0:** Incluye una licencia de patente explícita, perpetua, mundial, no exclusiva y libre de regalías (Sección 3). De manera crucial, incluye una **Cláusula de Retaliación / Terminación de Patentes**: si una parte inicia un litigio de patentes contra cualquier entidad alegando que el software constituye una infracción de patente, cualquier licencia de patente otorgada a esa parte bajo Apache-2.0 finaliza automáticamente.
4. **Requisito del Archivo `NOTICE` (Apache-2.0 Sección 4d):**  
   Si el proyecto original incluye un archivo de texto `NOTICE`, los redistribuidores deben incluir una copia legible de los avisos de atribución contenidos dentro de dicho archivo `NOTICE` en las distribuciones downstream (en código fuente, documentación o pantallas de visualización generadas).
5. **Cambios de Estado y Registro de Modificaciones (Apache-2.0 Sección 4b):**  
   Requiere que los archivos modificados lleven avisos prominentes que indiquen que los archivos han sido alterados, asegurando que los consumidores downstream puedan distinguir el código original upstream de las modificaciones de terceros.
6. **La Cláusula Histórica de Publicidad (BSD 4-Clause):**  
   La licencia original BSD 4-Clause incluía la Cláusula 3, que requería que todos los materiales publicitarios que mencionaran características o el uso del software mostraran un reconocimiento a la organización original. Esta cláusula causó una incompatibilidad generalizada de licencias con las licencias Copyleft (GPLv2/v3) y fue rescindida oficialmente por UC Berkeley en 1999, dando lugar a las variantes BSD 3-Clause ("Revised") y BSD 2-Clause ("Simplified").

---

## 2. Technical Comparison Matrix: Permissive Software Licenses

| Característica / Propiedad de la Licencia | MIT License | BSD 2-Clause (Simplified) | BSD 3-Clause (New/Revised) | BSD 4-Clause (Original) | Apache License 2.0 | ISC License |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **SPDX Identifier** | `MIT` | `BSD-2-Clause` | `BSD-3-Clause` | `BSD-4-Clause` | `Apache-2.0` | `ISC` |
| **Aprobado por la OSI** | Sí | Sí | Sí | No (Obsoleto/Incompatible) | Sí | Sí |
| **Concesión Explícita de Patentes** | No | No | No | No | **Sí (Sección 3)** | No |
| **Cláusula de Retaliación de Patentes** | No | No | No | No | **Sí** | No |
| **Cláusula de No Respaldo** | No | No | **Sí (Cláusula 3)** | Sí | **Sí (Sección 6)** | No |
| **Cláusula de Publicidad** | No | No | No | **Sí (Cláusula 3)** | No | No |
| **Rastreo de Modificaciones** | No | No | No | No | **Sí (Sección 4b)** | No |
| **Propagación del Archivo `NOTICE`**| No | No | No | No | **Sí (Sección 4d)** | No |
| **Compatibilidad con GPLv3** | Compatible | Compatible | Compatible | **Incompatible** | Compatible | Compatible |

---

## 3. Official References & Citations

- **LPI Open Source Essentials (Exam 050-100) Objectives:** [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Open Source Initiative (OSI) Licenses Standard:** [https://opensource.org/licenses](https://opensource.org/licenses)
- **The MIT License (OSI Specification):** [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)
- **The BSD 3-Clause License:** [https://opensource.org/licenses/BSD-3-Clause](https://opensource.org/licenses/BSD-3-Clause)
- **The Apache License, Version 2.0:** [https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)
- **SPDX (Software Package Data Exchange) License List:** [https://spdx.org/licenses/](https://spdx.org/licenses/)
- **FSFE REUSE Software Compliance Specification:** [https://reuse.software/spec/](https://reuse.software/spec/)

---

## 4. Production Guided Exercises

### Exercise 1: SPDX Standard Header Validation & REUSE Compliance Audit

En pipelines empresariales de DevSecOps, el cumplimiento automatizado de licencias requiere marcadores de encabezado estandarizados en cada activo de código fuente de acuerdo con la especificación SPDX de la Linux Foundation y el protocolo FSFE REUSE.

#### Step 1: Create a mock microservice workspace with mixed permissive components

Ejecutá los siguientes comandos en tu terminal para inicializar la estructura del repositorio del proyecto:

```bash
mkdir -p ~/permissive-compliance-lab/src
cd ~/permissive-compliance-lab

# Create LICENSE files for sub-modules
cat << 'EOF' > LICENSE.MIT
MIT License

Copyright (c) 2026 Enterprise Platform Corp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

cat << 'EOF' > src/auth.py
# SPDX-FileCopyrightText: 2026 Enterprise Platform Corp <dev@platform.internal>
# SPDX-License-Identifier: MIT

def authenticate_user(token: str) -> bool:
    """Validates incoming OAuth2 token."""
    return token.startswith("bearer_valid_")
EOF

cat << 'EOF' > src/crypto_utils.c
/*
 * SPDX-FileCopyrightText: 2026 Security Core Authors
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <stdio.h>

void initialize_crypto_context(void) {
    printf("Initializing AES-256 GCM engine...\n");
}
EOF

cat << 'EOF' > src/legacy_banner.c
/*
 * Copyright (c) 1991 Old Systems Software Inc.
 * All rights reserved.
 * 
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *    This product includes software developed by Old Systems Software Inc.
 */

#include <stdio.h>

void print_banner(void) {
    printf("Starting Legacy Telemetry System...\n");
}
EOF
```

#### Step 2: Install and run the `reuse` compliance linter

Ejecutá la verificación de cumplimiento de REUSE en el workspace para verificar las anotaciones de licencia a nivel de código fuente:

```bash
# Install the reuse tool using pip/uv
python3 -m pip install --quiet reuse

# Run compliance linting
reuse lint
```

**Salida Esperada de la Terminal:**

```text
# REUSE Version: 3.0.0
# Starting linting process...

# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 1
  - src/legacy_banner.c
* Missing LICENSES:
  - BSD-3-Clause.txt
  - MIT.txt
* Unused licenses: 0
* Used licenses: BSD-3-Clause, MIT

FAIL: The repository is NOT REUSE compliant.
```

#### Step 3: Remediate the non-compliant file and missing license texts

Ejecutá los pasos de remediación para aplicar una identificación SPDX válida:

```bash
# Download official SPDX license texts into LICENSES/ directory
mkdir -p LICENSES
curl -s -o LICENSES/MIT.txt https://raw.githubusercontent.com/spdx/license-list-data/main/text/MIT.txt
curl -s -o LICENSES/BSD-3-Clause.txt https://raw.githubusercontent.com/spdx/license-list-data/main/text/BSD-3-Clause.txt
curl -s -o LICENSES/BSD-4-Clause.txt https://raw.githubusercontent.com/spdx/license-list-data/main/text/BSD-4-Clause.txt

# Add correct SPDX header to the legacy file
cat << 'EOF' > src/legacy_banner.c
/*
 * SPDX-FileCopyrightText: 1991 Old Systems Software Inc.
 * SPDX-License-Identifier: BSD-4-Clause
 */

#include <stdio.h>

void print_banner(void) {
    printf("Starting Legacy Telemetry System...\n");
}
EOF

# Re-run REUSE linting
reuse lint
```

**Salida Esperada de la Terminal:**

```text
# REUSE Version: 3.0.0
# Starting linting process...

# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Missing LICENSES: 0
* Unused licenses: 0
* Used licenses: BSD-3-Clause, BSD-4-Clause, MIT

Congratulations! Your project is compliant with version 3.0 of the REUSE Specification!
```

---

#### Exercise 1 Verification Questions

1. ¿Por qué la inclusión de `src/legacy_banner.c` bajo `BSD-4-Clause` presenta un alto riesgo legal si la empresa decide combinar este código base con un componente Copyleft GPLv2/GPLv3 en una compilación binaria unificada?
2. ¿Qué línea de etiqueta de encabezado específica legible por máquina permite que herramientas como `reuse`, `syft` y `scancode-toolkit` mapeen archivos fuente directamente a la base de datos oficial de licencias SPDX?

---

### Exercise 2: Auditing Apache-2.0 Patent Terms, `NOTICE` File Requirements, and Dependency Parsing

La Licencia Apache 2.0 introduce requisitos operativos con respecto a los avisos de modificación y la propagación obligatoria downstream del contenido del archivo `NOTICE`.

#### Step 1: Create an Apache-2.0 Upstream Engine with a `NOTICE` file

Creá una estructura de librería upstream que cumpla con los términos de Apache 2.0:

```bash
mkdir -p ~/apache-audit-lab/upstream_lib
cd ~/apache-audit-lab/upstream_lib

cat << 'EOF' > LICENSE
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
   [... Full Apache 2.0 License Text ...]
EOF

cat << 'EOF' > NOTICE
=========================================================================
==  NOTICE file corresponding to section 4(d) of the Apache License,   ==
==  Version 2.0, in this case for CloudData Pipeline Core.             ==
=========================================================================

CloudData Pipeline Core
Copyright 2026 CloudData Infrastructure Authors

This product includes software developed at
The Apache Software Foundation (http://www.apache.org/).

Portions of this software were developed by ThirdParty Analytics Engine Inc.
EOF

cat << 'EOF' > engine.py
# SPDX-FileCopyrightText: 2026 CloudData Infrastructure Authors
# SPDX-License-Identifier: Apache-2.0

def process_stream(data_chunk):
    """Core data stream engine."""
    return [d.strip() for d in data_chunk if d]
EOF
```

#### Step 2: Simulate a Modified Downstream Product

Creá un producto derivado modificado a partir de la librería Apache-2.0:

```bash
cd ~/apache-audit-lab
mkdir -p downstream_app
cp upstream_lib/engine.py downstream_app/engine.py
cp upstream_lib/NOTICE downstream_app/NOTICE.upstream

# Modify engine.py in compliance with Apache 2.0 Section 4(b)
cat << 'EOF' > downstream_app/engine.py
# SPDX-FileCopyrightText: 2026 CloudData Infrastructure Authors
# SPDX-FileCopyrightText: 2026 Enterprise Downstream Inc (Modifications)
# SPDX-License-Identifier: Apache-2.0
#
# LOG OF MODIFICATION (Apache-2.0 Section 4b):
# Modified on 2026-08-06 by Enterprise Platform Team:
# - Added secondary memory cache layer to process_stream()

def process_stream(data_chunk):
    """Core data stream engine with caching modification."""
    # Modified implementation
    cached_results = []
    for item in data_chunk:
        if item:
            cached_results.append(item.strip().upper())
    return cached_results
EOF
```

#### Step 3: Install `pip-licenses` and generate an automated License & Notice Audit Report

```bash
# Set up a python environment and install pip-licenses
python3 -m venv ~/apache-audit-lab/venv
source ~/apache-audit-lab/venv/bin/activate
pip install --quiet pip-licenses flask pyyaml

# Run dependency license audit targeting permissive compliance
pip-licenses --format=markdown --with-urls
```

**Salida Esperada de la Terminal:**

```markdown
| Name | Version | License | URL |
| :--- | :--- | :--- | :--- |
| Flask | 3.0.2 | BSD-3-Clause | https://palletsprojects.com/p/flask/ |
| PyYAML | 6.0.1 | MIT | https://pyyaml.org/ |
| Werkzeug | 3.0.1 | BSD-3-Clause | https://palletsprojects.com/p/werkzeug/ |
| MarkupSafe | 2.1.5 | BSD-3-Clause | https://palletsprojects.com/p/markupsafe/ |
```

---

#### Exercise 2 Verification Questions

1. Si un desarrollador empresarial modifica un archivo fuente con licencia Apache-2.0, ¿qué requisito explícito exige la Sección 4(b) de la Licencia Apache 2.0?
2. Si un competidor presenta una demanda de patentes contra una empresa que utiliza una librería Apache-2.0, alegando que la librería Apache-2.0 infringe la patente del competidor, ¿qué sucede con los derechos de licencia de patente del competidor bajo la cláusula de Retaliación de Patentes de Apache 2.0 (Sección 3)?
3. ¿Cuál es la consecuencia legal bajo la Sección 4(d) de Apache-2.0 si un paquete de software downstream omite el contenido del archivo `NOTICE` de un componente upstream en su documentación de distribución?

---

### Exercise 3: Automated Enforcement of Permissive-Only Policies via `cargo-deny`

Los Platform Engineers deben configurar guardrails automatizados en CI/CD para bloquear licencias no permisivas o incompatibles (por ejemplo, GPL, AGPL, BSD-4-Clause) antes de que el código llegue a las ramas de despliegue en producción.

#### Step 1: Initialize a Rust workspace with `cargo-deny` guardrails

```bash
mkdir -p ~/deny-lab && cd ~/deny-lab

# Install cargo-deny binary (or simulate configuration)
cat << 'EOF' > deny.toml
# Cargo-Deny Policy Configuration: Permissive Licensing Guardrail

[licenses]
# Reject any license not explicitly allowed in this list
unlicensed-with-unknown-reasons = "deny"
default-confidence = 0.8
private = { ignore = true }

# Explicitly allow ONLY compliant permissive licenses
allow = [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC"
]

# Explicitly block non-permissive or restricted licenses
deny = [
    "GPL-2.0-only",
    "GPL-2.0-or-later",
    "GPL-3.0-only",
    "GPL-3.0-or-later",
    "AGPL-3.0-only",
    "AGPL-3.0-or-later",
    "BSD-4-Clause",
    "SSPL-1.0"
]

[licenses.clarify]
# Exception handling rules if needed
EOF
```

#### Step 2: Validate Policy Enforcement Matrix against standard SPDX license IDs

Creá un script de verificación de shell para probar la validación de la política frente al bill-of-materials (BOM) estándar del paquete:

```bash
cat << 'EOF' > test_policy.py
import sys
import tomllib

def check_license(license_id, config_path="deny.toml"):
    with open(config_path, "rb") as f:
        config = tomllib.load(f)
    
    allowed = config["licenses"]["allow"]
    denied = config["licenses"]["deny"]
    
    if license_id in denied:
        print(f"FAILED: License '{license_id}' is explicitly DENIED by enterprise security policy.")
        return False
    elif license_id in allowed:
        print(f"PASSED: License '{license_id}' is PERMISSIVE and APPROVED for production use.")
        return True
    else:
        print(f"FAILED: License '{license_id}' is NOT listed in permissive allow-list.")
        return False

if __name__ == "__main__":
    test_cases = ["MIT", "Apache-2.0", "BSD-3-Clause", "BSD-4-Clause", "GPL-3.0-only", "AGPL-3.0-or-later"]
    results = [check_license(lic) for lic in test_cases]
    if not all([results[0], results[1], results[2]]) or any([results[3], results[4], results[5]]):
        sys.exit(1)
EOF

python3 test_policy.py
```

**Salida Esperada de la Terminal:**

```text
PASSED: License 'MIT' is PERMISSIVE and APPROVED for production use.
PASSED: License 'Apache-2.0' is PERMISSIVE and APPROVED for production use.
PASSED: License 'BSD-3-Clause' is PERMISSIVE and APPROVED for production use.
FAILED: License 'BSD-4-Clause' is explicitly DENIED by enterprise security policy.
FAILED: License 'GPL-3.0-only' is explicitly DENIED by enterprise security policy.
FAILED: License 'AGPL-3.0-or-later' is explicitly DENIED by enterprise security policy.
```

---

#### Exercise 3 Verification Questions

1. ¿Por qué la licencia `ISC` se trata como estructuralmente equivalente a `BSD-2-Clause` y `MIT` cuando es auditada por motores de políticas como `cargo-deny` o `license-checker`?
2. ¿Cuál es la diferencia operativa fundamental entre un **enfoque de lista de permitidos (Allow-list)** (permitiendo solo MIT, Apache-2.0, BSD-3-Clause) frente a un **enfoque de lista de bloqueados (Deny-list)** (bloqueando solo GPL/AGPL) en pipelines de seguridad de plataformas empresariales?

---

<details>
<summary><b>Haz clic para desplegar: Respuestas detalladas y explicaciones a las preguntas de verificación</b></summary>

### Exercise 1 Answers

1. **Mecánica de Incompatibilidad entre GPL / BSD-4-Clause:**  
   La licencia `BSD-4-Clause` contiene la Cláusula 3 (la "Cláusula de Publicidad"), que requiere que todos los materiales promocionales que mencionen características o el uso del software muestren un texto de crédito específico para el titular del copyright. 
   - GNU GPL (tanto v2 como v3) prohíbe explícitamente imponer *restricciones adicionales* a los usuarios downstream más allá de las que la propia GPL impone (GPLv2 Sección 6 / GPLv3 Sección 10). 
   - Debido a que el requisito de publicidad de BSD 4-Clause constituye una restricción adicional no presente en la GPL, las dos licencias son **legalmente incompatibles**. No podés combinar código fuente BSD 4-Clause y código fuente GPL en un único ejecutable binario enlazado sin infringir una de las dos licencias.

2. **Identificadores de Encabezado SPDX:**  
   La línea de etiqueta estandarizada legible por máquina es `SPDX-License-Identifier: <SPDX-ID>` (por ejemplo, `SPDX-License-Identifier: MIT` o `SPDX-License-Identifier: Apache-2.0`), a menudo acompañada de `SPDX-FileCopyrightText: <Año> <Titular>`. Esta sintaxis estandarizada permite que las herramientas de análisis estático de código (como `reuse`, `syft`, `scancode-toolkit` y `github-license-detector`) analicen los encabezados de los archivos fuente sin depender de coincidencias de texto difusas (fuzzy matching) de bloques de licencia completos.

---

### Exercise 2 Answers

1. **Requisito de Cambio de Estado de la Sección 4(b) de Apache-2.0:**  
   La Sección 4(b) de la Licencia Apache 2.0 exige explícitamente que si un usuario modifica cualquier archivo dentro de la obra licenciada, debe hacer que los archivos modificados lleven **avisos prominentes que indiquen que los archivos han sido cambiados**. Esto garantiza que los usuarios posteriores, distribuidores y autores originales sepan que el archivo ya no representa la versión upstream sin modificar.

2. **Mecanismo de Retaliación / Terminación de Patentes de Apache-2.0 (Sección 3):**  
   Si una entidad inicia un litigio de patentes contra cualquier colaborador o usuario alegando que el software con licencia Apache-2.0 constituye una infracción de patente directa o contributiva, **todas las licencias de patentes otorgadas a esa entidad bajo la licencia Apache-2.0 para ese software finalizan automáticamente a partir de la fecha en que se presenta dicho litigio**. Este mecanismo legal disuade los litigios agresivos de patentes al amenazar el derecho del litigante a continuar usando o distribuyendo el software.

3. **Consecuencias de Omitir el Archivo `NOTICE` (Sección 4d):**  
   Bajo la Sección 4(d) de Apache-2.0, si la Obra original incluye un archivo de texto `NOTICE` como parte de su distribución, cualquier redistribución downstream debe incluir una copia legible de los avisos de atribución contenidos dentro de ese archivo `NOTICE`. Omitir este archivo durante la redistribución constituye un incumplimiento de las condiciones de la licencia, revocando los derechos otorgados al redistribuidor hasta que se remedie.

---

### Exercise 3 Answers

1. **Estructura de la Licencia ISC:**  
   La **Licencia ISC (Internet Systems Consortium)** es funcionalmente idéntica a la Licencia MIT y a la Licencia BSD 2-Clause, con un lenguaje simplificado desprovisto de texto introductorio histórico innecesario. Otorga permiso para usar, copiar, modificar y distribuir el software para cualquier propósito con o sin costo, siempre que el aviso de copyright y el aviso de permiso aparezcan en todas las copias. Por lo tanto, las herramientas de políticas la clasifican en el nivel permisivo de menor riesgo junto con MIT y BSD-2-Clause.

2. **Aplicación de Lista de Permitidos (Allow-List) vs. Lista de Bloqueados (Deny-List) en CI/CD:**  
   - **Estrategia de Lista de Permitidos (Zero Trust):** Solo se permiten en los artefactos de compilación las dependencias que tengan licencias permisivas explícitamente aprobadas (por ejemplo, MIT, Apache-2.0, BSD-3-Clause). Cualquier licencia desconocida, con doble licencia, no clasificada o recién lanzada falla inmediatamente el pipeline de CI/CD. Esta es la **arquitectura de producción recomendada** para la ingeniería de plataformas empresariales.
   - **Estrategia de Lista de Bloqueados:** Permite todo de forma predeterminada excepto las licencias prohibidas enumeradas explícitamente (por ejemplo, GPL, AGPL). Esto expone a la empresa a un riesgo legal cuando nuevas dependencias de terceros utilizan licencias propietarias/copyleft novedosas, no estándar, personalizadas o no clasificadas que aún no se han agregado manualmente a la lista de bloqueados.

</details>