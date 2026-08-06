# LPI 050-100: Open Source Essentials
## Topic 3.1: Conceptos de licencias de contenido abierto (Peso: 5)

---

### Documentación de referencia oficial
* **LPI Open Source Essentials Overview & Objectives**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Creative Commons Licensing Framework & Legal Code**: [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
* **GNU Free Documentation License (GFDL v1.3)**: [https://www.gnu.org/licenses/fdl-1.3.html](https://www.gnu.org/licenses/fdl-1.3.html)
* **Free Art License 1.3 (Licence Art Libre)**: [https://artlibre.org/licence/lal/en/](https://artlibre.org/licence/lal/en/)
* **Software Package Data Exchange (SPDX) Specification**: [https://spdx.dev/specifications/](https://spdx.dev/specifications/)
* **FSFE REUSE Specification for Machine-Readable Licensing**: [https://reuse.software/spec/](https://reuse.software/spec/)

---

### Mecánica técnica profunda y marco de arquitectura

Las licencias de contenido abierto (Open Content Licensing) adaptan los principios de gobernanza de código abierto—diseñados originalmente para código ejecutable—a activos digitales que no son código, incluyendo documentación técnica, diagramas de arquitectura de sistemas, esquemas de API, especificaciones de diseño y activos multimedia.

#### 1. Mecánica de licencias de software vs. contenido
* **Licencias de Software de Código Abierto (OSS)** (ej., GPL, Apache-2.0, MIT) se dirigen a binarios de código fuente, mecánicas de enlazado, salida del compilador y cláusulas de represalia de patentes.
* **Licencias de Contenido Abierto** se dirigen a obras textuales, estructuras de datos, activos artísticos y documentación. Abordan derechos de autor tales como reproducción, distribución, representación pública, derechos morales y obras derivadas sin requerir modelos de compilación binaria.

#### 2. La arquitectura modular de Creative Commons (CC)
Las licencias Creative Commons utilizan cuatro cláusulas legales modulares principales combinadas en seis suites de licencias primarias, junto con la dedicación al dominio público `CC0`:

| Componente | Código corto | Mecánica e implicaciones de producción |
| :--- | :--- | :--- |
| **Attribution** | `BY` | Exige crédito a los autores originales, enlaces URI a la licencia e indicadores de modificación. Obligatorio en todas las licencias estándar CC v4.0. |
| **ShareAlike** | `SA` | **Cláusula Copyleft**: Las obras derivadas *deben* ser distribuidas bajo la exacta misma licencia o una compatible. Fuerza el cumplimiento aguas abajo (downstream). |
| **NonCommercial** | `NC` | Restringe la utilización a fines no comerciales. **Incompatible con la Definición de Código Abierto (OSD) y la definición de Obras Culturales Libres**, ya que prohíbe el uso comercial en producción. |
| **NoDerivatives** | `ND` | Permite la redistribución pero **prohíbe la modificación o creación de obras derivadas**. Viola los principios de la OSD sobre los derechos de modificación. |

```
                       ┌──────────────────────────────────────────────┐
                       │              CC0 (Public Domain)             │
                       └──────────────────────┬───────────────────────┘
                                              │
                       ┌──────────────────────▼───────────────────────┐
                       │                CC BY (Permissive)            │
                       └──────┬────────────────────────────────┬──────┘
                              │                                │
            ┌─────────────────▼────────┐           ┌───────────▼────────────────┐
            │   CC BY-SA (Copyleft)    │           │    CC BY-NC (Restricted)    │
            │   [Free Cultural Work]   │           │    [Non-Free Content]      │
            └──────────────────────────┘           └───────────┬────────────────┘
                                                               │
                                                   ┌───────────▼────────────────┐
                                                   │ CC BY-NC-SA / CC BY-NC-ND  │
                                                   │    [Strict Commercial Ban] │
                                                   └────────────────────────────┘
```

#### 3. Licencias de contenido abierto legadas y alternativas
* **GNU Free Documentation License (GFDL)**: Diseñada por la FSF para documentación de manuales. Incluye **Invariant Sections**, **Cover Texts**, y **Front/Back Cover Texts** que no pueden alterarse. Esto crea fricción legal al intentar fusionar contenido GFDL con contenido CC BY-SA.
* **Free Art License (FAL 1.3 / Licence Art Libre)**: Una licencia copyleft para obras artísticas y textuales compatible con CC BY-SA 4.0.
* **Open Publication License (OPL)**: Una licencia de contenido abierto anterior que ofrece opciones para restricción comercial o prohibición de versiones modificadas.

#### 4. Cumplimiento legible por máquina (Metadatos SPDX & XMP)
En la automatización de SRE y pipelines de GitOps, los archivos legales legibles por humanos (`LICENSE.txt`) se complementan con anotaciones legibles por máquina:
* **Identificadores de Licencia SPDX**: Cadenas cortas estandarizadas (ej., `CC-BY-4.0`, `CC-BY-SA-4.0`, `GFDL-1.3-or-later`, `CC0-1.0`).
* **Extensible Metadata Platform (XMP)**: Metadatos XML incrustados directamente dentro de contenedores de medios binarios (PNG, SVG, PDF, WebP) que fuerzan la procedencia digital.

---

### Ejercicios prácticos guiados

---

#### Ejercicio 1: Auditoría y aplicación de licencias de contenido abierto con `reuse` CLI & validación SPDX

En este ejercicio, configurarás un repositorio de documentación técnica, aplicarás encabezados SPDX legibles por máquina en archivos Markdown y de medios, y validarás el cumplimiento utilizando la herramienta `reuse` de la Free Software Foundation Europe (`FSFE`).

##### Paso 1.1: Configuración del entorno e instalación de herramientas
Ejecutá los siguientes comandos en tu shell de Linux para instalar `python3-pip`, `git` y el motor de cumplimiento `reuse`:

```bash
sudo apt-get update -y && sudo apt-get install -y python3-pip git jq exiftool
pip3 install reuse
reuse --version
```

*Salida esperada:*
```text
reuse, version 3.0.2
```

##### Paso 1.2: Construcción del repositorio
Creá un árbol simulado de documentación de arquitectura de plataforma:

```bash
mkdir -p ~/platform-docs/docs/diagrams
mkdir -p ~/platform-docs/.reuse
cd ~/platform-docs
git init

cat <<'EOF' > docs/index.md
# Platform Architecture Guide
This document describes the Kubernetes cluster deployment pipeline.
EOF

cat <<'EOF' > docs/diagrams/network-topology.svg
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <circle cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
</svg>
EOF
```

##### Paso 1.3: Aplicar encabezados de contenido abierto SPDX a la documentación
Anotá `docs/index.md` bajo la licencia **Creative Commons Attribution 4.0 International (`CC-BY-4.0`)** y `docs/diagrams/network-topology.svg` bajo **Creative Commons Zero 1.0 Universal (`CC0-1.0`)**.

```bash
reuse annotate --license CC-BY-4.0 --copyright "Platform Engineering Team <sre@example.com>" docs/index.md
reuse annotate --license CC0-1.0 --copyright "Platform Engineering Team <sre@example.com>" docs/diagrams/network-topology.svg
```

##### Paso 1.4: Descargar textos oficiales de licencias y auditar el cumplimiento
Descargá archivos de texto legal en la carpeta estándar `LICENSES/` automáticamente y ejecutá `reuse lint`:

```bash
reuse download --all
reuse lint
```

*Salida esperada:*
```text
# Linting ...
# Result: SUCCESS
# Congratulations! Your project is compliant with the REUSE specification.
```

##### Paso 1.5: Inspeccionar el formato del encabezado autogenerado
Visualizá las modificaciones realizadas en `docs/index.md` para verificar la sintaxis:

```bash
head -n 6 docs/index.md
```

*Salida esperada:*
```markdown
<!--
SPDX-FileCopyrightText: 2026 Platform Engineering Team <sre@example.com>

SPDX-License-Identifier: CC-BY-4.0
-->
```

---

##### Preguntas de verificación — Ejercicio 1

**Pregunta 1.1**: ¿Qué identificador SPDX se debe aplicar si el equipo de ingeniería de plataforma exige que cualquier equipo aguas abajo (downstream) que modifique `docs/index.md` DEBE publicar sus modificaciones bajo los mismos términos exactos de la licencia copyleft?
A) `CC-BY-4.0`  
B) `CC-BY-NC-4.0`  
C) `CC-BY-SA-4.0`  
D) `CC-BY-ND-4.0`  

**Pregunta 1.2**: ¿Por qué agregar un encabezado de licencia `CC-BY-NC-4.0` a la documentación técnica hace que el repositorio no cumpla con la Definición de Código Abierto (OSD)?
A) Prohíbe la distribución de la documentación a través de protocolos SSH.  
B) Restringe el uso comercial, violando el Ítem 6 de la OSD (No discriminación contra campos de trabajo).  
C) Requiere pagar regalías a Creative Commons.  
D) Obliga a que los binarios del código fuente tengan licencia bajo GNU GPLv2.  

---

#### Ejercicio 2: Incrustación de metadatos de contenido abierto XMP en activos de medios y automatización en CI/CD

En los pipelines de producción, las compilaciones de documentación procesan imágenes binarias (PNG/PDF). Estos archivos binarios no pueden albergar encabezados de comentarios estándar (`<!-- SPDX ... -->`). En su lugar, los SREs incrustan etiquetas XMP (Extensible Metadata Platform) legibles por máquina.

##### Paso 2.1: Convertir SVG a PNG e incrustar metadatos de licencia XMP
Usá `exiftool` para insertar metadatos de licencia SPDX en un activo gráfico PNG:

```bash
cd ~/platform-docs

# Create a sample binary file
convert docs/diagrams/network-topology.svg docs/diagrams/network-topology.png 2>/dev/null || cp docs/diagrams/network-topology.svg docs/diagrams/network-topology.png

# Write XMP metadata tags for CC-BY-SA-4.0
exiftool -XMP-dc:Rights="Attribution-ShareAlike 4.0 International" \
         -XMP-cc:License="https://creativecommons.org/licenses/by-sa/4.0/" \
         -XMP-plus:LicenseID="CC-BY-SA-4.0" \
         -overwrite_original docs/diagrams/network-topology.png
```

##### Paso 2.2: Verificar metadatos XMP incrustados mediante inspección de shell
Extraé e inspeccioná los metadatos de licencia XMP incrustados:

```bash
exiftool -XMP-cc:License -XMP-plus:LicenseID docs/diagrams/network-topology.png
```

*Salida esperada:*
```text
URL License                     : https://creativecommons.org/licenses/by-sa/4.0/
License ID                      : CC-BY-SA-4.0
```

##### Paso 2.3: Construir un script de cumplimiento pre-commit automatizado
Creá un script de validación bash de producción (`scripts/audit-licenses.sh`) que inspeccione todas las imágenes del repositorio y rechace los archivos que carezcan de metadatos de licencia XMP válidos o que contengan licencias no aprobadas (por ejemplo, variantes `NC` o `ND`):

```bash
mkdir -p scripts

cat <<'EOF' > scripts/audit-licenses.sh
#!/usr/bin/env bash
set -euo pipefail

FAILED=0
echo "=== Starting SRE Open Content License Audit ==="

for img in $(find docs/diagrams -type f \( -name "*.png" -o -name "*.jpg" \)); do
    LICENSE_ID=$(exiftool -s -s -s -XMP-plus:LicenseID "$img" || true)
    
    if [ -z "$LICENSE_ID" ]; then
        echo "[ERROR] File $img is missing embedded XMP LicenseID metadata!"
        FAILED=1
    elif [[ "$LICENSE_ID" =~ (NC|ND) ]]; then
        echo "[ERROR] File $img contains restricted license: $LICENSE_ID (NC/ND prohibited)!"
        FAILED=1
    else
        echo "[OK] File $img verified with LicenseID: $LICENSE_ID"
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "=== Audit FAILED: Non-compliant assets detected ==="
    exit 1
else
    echo "=== Audit PASSED: All media assets comply with Open Content standards ==="
    exit 0
fi
EOF

chmod +x scripts/audit-licenses.sh
./scripts/audit-licenses.sh
```

*Salida esperada:*
```text
=== Starting SRE Open Content License Audit ===
[OK] File docs/diagrams/network-topology.png verified with LicenseID: CC-BY-SA-4.0
=== Audit PASSED: All media assets comply with Open Content standards ===
```

##### Paso 2.4: Crear un manifiesto de flujo de trabajo de GitHub Actions para el cumplimiento automatizado
Escribí un manifiesto de flujo de trabajo de GitHub Actions sintácticamente válido `.github/workflows/content-compliance.yml`:

```bash
mkdir -p .github/workflows

cat <<'EOF' > .github/workflows/content-compliance.yml
name: Open Content License Compliance

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

jobs:
  license-audit:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v4

      - name: Install Audit Dependencies
        run: |
          sudo apt-get update -y
          sudo apt-get install -y exiftool python3-pip
          pip3 install reuse

      - name: Validate REUSE/SPDX Syntax
        run: |
          reuse lint

      - name: Validate Embedded XMP Media Metadata
        run: |
          bash ./scripts/audit-licenses.sh
EOF
```

---

##### Preguntas de verificación — Ejercicio 2

**Pregunta 2.1**: Ejecutás `exiftool` en un manual PDF de producción y descubrís la etiqueta `XMP-cc:License="https://creativecommons.org/licenses/by-nd/4.0/"`. ¿Qué restricción aplica esto a tu equipo de SRE?
A) No podés ejecutar el software generador de PDF dentro de un contenedor Docker.  
B) Podés leer y redistribuir el manual, pero no podés modificar, traducir ni adaptar el contenido para runbooks internos.  
C) Debés pagar una cuota de suscripción a Creative Commons cada vez que se descarga el documento.  
D) El código fuente del PDF debe compilarse utilizando GCC.  

**Pregunta 2.2**: ¿Por qué se prefieren los metadatos XMP sobre los archivos de texto adicionales (*sidecar* `.txt`) para activos binarios en pipelines de contenido nativos de la nube (cloud-native)?
A) Los metadatos XMP están encriptados con claves RSA.  
B) Los archivos de texto sidecar duplican la huella de almacenamiento en los repositorios de Git.  
C) Los metadatos XMP se incrustan directamente en el contenedor del archivo binario, preservando la procedencia legal cuando los activos se cargan, transforman o mueven a través de pipelines de CDN.  
D) Los kernels de Linux requieren encabezados XMP para renderizar archivos PNG en entornos POSIX.  

---

#### Ejercicio 3: Evaluación de la compatibilidad de licencias y gestión de incompatibilidades legales (GFDL vs. CC BY-SA)

En este ejercicio, analizarás conflictos de compatibilidad de licencias al combinar documentación abierta de terceros (GFDL v1.3 con Invariant Sections vs CC BY-SA 4.0 vs licencias de software permisivas).

##### Paso 3.1: Simular un escenario de fricción de licencias de documentación
Creá dos archivos de referencia que contengan fragmentos de documentación externa bajo diferentes regímenes legales:

```bash
mkdir -p ~/platform-docs/external

# File A: GFDL 1.3 with Invariant Sections
cat <<'EOF' > ~/platform-docs/external/gfdl-manual.md
<!--
SPDX-FileCopyrightText: 2021 Free Software Foundation
SPDX-License-Identifier: GFDL-1.3-invariants-or-later
-->
# GNU System Administration Manual
Invariant Section: "Secondary History of GNU System"
This section cannot be altered or removed under GFDL v1.3 terms.
EOF

# File B: Creative Commons Attribution-ShareAlike 4.0
cat <<'EOF' > ~/platform-docs/external/cc-by-sa-guide.md
<!--
SPDX-FileCopyrightText: 2023 Open Docs Author
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Cloud Native Storage Walkthrough
This text is licensed under CC BY-SA 4.0. Derivative works must be redistributed under CC BY-SA 4.0.
EOF
```

##### Paso 3.2: Inspeccionar expresiones de licencia SPDX y restricciones de compatibilidad
Ejecutá un script de Python utilizando la lógica de parseo estándar de `spdx-tools` para evaluar las expresiones de licencia e identificar conflictos:

```bash
pip3 install spdx-tools

cat <<'EOF' > scripts/evaluate_compatibility.py
import sys

def check_compatibility(doc_a_spdx, doc_b_spdx):
    print(f"Analyzing compatibility between '{doc_a_spdx}' and '{doc_b_spdx}'...")
    
    # Conflict Rule 1: GFDL with Invariant Sections vs CC-BY-SA 4.0
    if "GFDL" in doc_a_spdx and "invariants" in doc_a_spdx and "CC-BY-SA" in doc_b_spdx:
        print("[CRITICAL CONFLICT] Incompatible License Aggregation!")
        print("Reason: GFDL Invariant Sections prohibit modification of specific text blocks.")
        print("CC-BY-SA 4.0 mandates that all derivative text must be licensed under CC BY-SA without unalterable sections.")
        return False
    elif "CC0-1.0" in doc_a_spdx or "MIT" in doc_a_spdx:
        print("[COMPATIBLE] Permissive assets can be incorporated into Copyleft documents.")
        return True
    else:
        print("[NOTICE] Conditional aggregation permitted via separate modules.")
        return True

if __name__ == "__main__":
    res = check_compatibility("GFDL-1.3-invariants-or-later", "CC-BY-SA-4.0")
    if not res:
        sys.exit(1)
EOF

python3 scripts/evaluate_compatibility.py
```

*Salida esperada:*
```text
Analyzing compatibility between 'GFDL-1.3-invariants-or-later' and 'CC-BY-SA-4.0'...
[CRITICAL CONFLICT] Incompatible License Aggregation!
Reason: GFDL Invariant Sections prohibit modification of specific text blocks.
CC-BY-SA 4.0 mandates that all derivative text must be licensed under CC BY-SA without unalterable sections.
```

##### Paso 3.3: Resolver la doble atribución de licencias para código en documentación
Cuando la documentación técnica contiene fragmentos de código ejecutable de shell o Python, puede surgir ambigüedad con las licencias. Las mejores prácticas de SRE dictan licenciar doblemente el repositorio mediante expresiones SPDX:

```bash
cat <<'EOF' > ~/platform-docs/docs/runbook.md
<!--
SPDX-FileCopyrightText: 2026 Platform Team <sre@example.com>
SPDX-License-Identifier: CC-BY-4.0 AND MIT
-->
# Kubernetes Troubleshooting Runbook

The prose in this runbook is licensed under CC-BY-4.0.
The embedded executable bash code snippets are licensed under the MIT license.

```bash
kubectl get pods --all-namespaces -o json | jq '.items[] | select(.status.phase!="Running")'
```
EOF

reuse lint
```

*Salida esperada:*
```text
# Linting ...
# Result: SUCCESS
```

---

##### Preguntas de verificación — Ejercicio 3

**Pregunta 3.1**: ¿Creative Commons modificó la versión 4.0 del texto legal de CC BY-SA para establecer compatibilidad oficial con qué licencia de documentación externa?
A) Apache-2.0  
B) GNU Free Documentation License (GFDL) v1.3 (bajo condiciones específicas sin Invariant Sections)  
C) Microsoft Public License (MS-PL)  
D) JSON License  

**Pregunta 3.2**: Un ingeniero extrae scripts de Python de un manual de documentación licenciado estrictamente bajo `CC-BY-NC-SA-4.0` y los importa en una herramienta de automatización de producción comercial. ¿Por qué esto viola los principios de código abierto?
A) `CC-BY-NC-SA-4.0` requiere compilar Python en extensiones de C.  
B) La cláusula `NC` (NonCommercial) prohíbe la ejecución comercial, haciéndola una licencia no libre para el uso de software según la Definición de Código Abierto.  
C) `CC-BY-NC-SA-4.0` requiere que todos los scripts se ejecuten en Windows OS.  
D) Los scripts de Python solo pueden licenciarse bajo BSD-3-Clause.  

---

### Respuestas y explicaciones

<details>
<summary>Hacé clic para ver las Respuestas y Explicaciones</summary>

#### Respuestas del Ejercicio 1

* **1.1 Respuesta correcta: C (`CC-BY-SA-4.0`)**
  * **Explicación**: El componente `SA` (ShareAlike) es el mecanismo copyleft de la suite Creative Commons. Requiere que cualquier obra derivada o versión modificada del material licenciado se distribuya bajo los mismos términos exactos de la licencia (`CC-BY-SA-4.0` o una licencia compatible). `CC-BY-4.0` es permisiva (solo requiere atribución), `CC-BY-NC-4.0` agrega una restricción no comercial, y `CC-BY-ND-4.0` prohíbe en su totalidad las obras derivadas.
* **1.2 Respuesta correcta: B (Restringe el uso comercial, violando el Ítem 6 de la OSD)**
  * **Explicación**: La cláusula explícita Ítem 6 de la Definición de Código Abierto (OSD) ("No discriminación contra campos de trabajo") establece que una licencia no debe restringir a nadie de hacer uso del programa o contenido en un campo de trabajo específico, incluyendo empresas comerciales. Las licencias `NC` (NonCommercial) prohíben el uso comercial en producción, categorizándolas como contenido restringido "No libre" o "Source-Available" en lugar de verdadero Contenido Abierto / Código Abierto.

---

#### Respuestas del Ejercicio 2

* **2.1 Respuesta correcta: B (Podés leer y redistribuir, pero no podés modificar, traducir ni adaptar)**
  * **Explicación**: La cláusula `ND` (NoDerivatives) permite explícitamente copiar y redistribuir en cualquier medio o formato para cualquier propósito (incluso comercial, a menos que se combine con NC). Sin embargo, si remezclás, transformás o construís sobre el material, **no podés distribuir el material modificado**. Esto impide crear manuales traducidos, runbooks actualizados o diagramas de arquitectura modificados.
* **2.2 Respuesta correcta: C (Los metadatos XMP se incrustan en el contenedor binario, preservando la procedencia legal)**
  * **Explicación**: Los formatos de imagen binarios (PNG, JPG, WebP) y los documentos (PDF) no admiten bloques de comentarios de texto en línea como los archivos `.md` o `.py`. Si bien los archivos sidecar pueden separarse fácilmente de los activos de imagen durante la distribución por CDN, los pasos de compilación de pipelines de activos o las descargas, XMP (Extensible Metadata Platform) escribe metadatos directamente en los bytes de encabezado binarios. Esto garantiza que los metadatos de copyright y licencias legibles por máquina viajen junto con el archivo de medios.

---

#### Respuestas del Ejercicio 3

* **3.1 Respuesta correcta: B (GNU Free Documentation License v1.3)**
  * **Explicación**: CC BY-SA 4.0 se actualizó para permitir mecanismos de compatibilidad unidireccional o bidireccional con GFDL v1.3, siempre que el documento GFDL no tenga **Invariant Sections** ni **Cover Texts**. Esto permite que los ecosistemas de wikis (como Wikipedia) vuelvan a licenciar o intercambiar activos de documentación legalmente entre repositorios GFDL y CC BY-SA.
* **3.2 Respuesta correcta: B (La cláusula NC prohíbe la ejecución comercial, haciéndola no libre bajo la OSD)**
  * **Explicación**: Aplicar licencias Creative Commons —especialmente variantes `NC` (NonCommercial)— a código de software funcional crea graves problemas operativos y legales. La restricción `NC` bloquea el despliegue comercial, la ejecución de SaaS comercial y los wrappers de soporte comercial, contradiciendo directamente los principios de Código Abierto. Para el código de software incrustado dentro de la documentación, se recomienda como patrón de producción el doble licenciamiento con una licencia de software aprobada por la OSI (por ejemplo, `MIT`, `Apache-2.0`, o `GPL-3.0`) mediante expresiones SPDX (por ejemplo, `CC-BY-4.0 AND MIT`).

</details>