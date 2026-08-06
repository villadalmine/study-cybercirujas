# Guía de estudio LPI 050-100: Tema 3.2 – Licencias Creative Commons

**Certificación:** LPI Open Source Essentials (Examen 050-100)  
**Tema 3.2:** Licencias Creative Commons  
**Peso:** 5  

---

## Official Reference Sources
* **LPI Open Source Essentials Overview:** [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Creative Commons Official License Descriptions:** [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
* **Creative Commons CC0 Public Domain Dedication:** [https://creativecommons.org/publicdomain/zero/1.0/](https://creativecommons.org/publicdomain/zero/1.0/)
* **SPDX License List (Creative Commons Identifiers):** [https://spdx.org/licenses/](https://spdx.org/licenses/)
* **FSFE REUSE Specification for Software & Media Compliance:** [https://reuse.software/](https://reuse.software/)

---

## Architectural Context & SRE Principles

En la ingeniería de plataformas de producción, el licenciamiento se extiende más allá de los binarios de código fuente. Los planos de arquitectura, runbooks, documentación de infraestructura como código, esquemas de API y conjuntos de datos de benchmark están gobernados por licencias de contenido. Creative Commons (CC) es el marco legal estándar para artefactos que no son código. 

Los ingenieros deben comprender la mecánica interna de las capas de Creative Commons:
1. **Legal Code:** El contrato legal tradicional ejecutable ante la ley.
2. **Human-Readable Deed:** Resumen de los derechos y permisos clave.
3. **Machine-Readable Metadata (CC REL / SPDX):** Metadatos estructurados consumibles por escáneres automatizados de CI/CD y motores de búsqueda.

```
+-----------------------------------------------------------------------+
|                         HUMAN-READABLE DEED                           |
|      (Commons Deed: Summary of rights, obligations, and scope)        |
+-----------------------------------------------------------------------+
|                         MACHINE-READABLE METADATA                     |
|    (SPDX Headers, RDF/XML, CC REL, HTML microdata, REUSE .dep5)      |
+-----------------------------------------------------------------------+
|                           LEGAL CODE                                  |
|   (Enforceable legal contract drafted by international legal team)   |
+-----------------------------------------------------------------------+
```

---

## Exercise 1: Deconstructing CC License Building Blocks and SPDX Validation via CLI

### Objective
Inspeccionar y consultar identificadores SPDX para licencias Creative Commons utilizando REST APIs y pipelines de shell para establecer estándares de metadatos base para repositorios de documentación técnica.

### Context & Mechanics
Creative Commons utiliza cuatro designadores principales:
* `BY` (**Attribution**): Debe dar el crédito adecuado, proporcionar un enlace a la licencia e indicar si se realizaron cambios.
* `SA` (**ShareAlike**): Si remezclas, transformas o creas a partir del material, debes distribuir tus contribuciones bajo la misma licencia que el original.
* `NC` (**NonCommercial**): El uso comercial está prohibido.
* `ND` (**NoDerivatives**): Si remezclas, transformas o creas a partir del material, no puedes distribuir el material modificado.
* `CC0` (**Public Domain Dedication**): Renuncia a todos los derechos de autor y derechos relacionados a nivel global.

### Execution Steps

1. Crear un directorio de trabajo y obtener el inventario oficial de licencias SPDX para las licencias Creative Commons 4.0 utilizando `curl` y `jq`:

```bash
mkdir -p ~/cc-compliance-lab && cd ~/cc-compliance-lab

curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json | \
jq '.licenses[] | select(.licenseId | startswith("CC-")) | {licenseId, name, isOsiApproved, isFsfLibre}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-4.0",
  "name": "Creative Commons Attribution 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": true
}
{
  "licenseId": "CC-BY-NC-4.0",
  "name": "Creative Commons Attribution Non Commercial 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-NC-ND-4.0",
  "name": "Creative Commons Attribution Non Commercial No Derivatives 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-NC-SA-4.0",
  "name": "Creative Commons Attribution Non Commercial Share Alike 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-ND-4.0",
  "name": "Creative Commons Attribution No Derivatives 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-SA-4.0",
  "name": "Creative Commons Attribution Share Alike 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": true
}
```

2. Consultar detalles específicos de la licencia para extraer los requisitos legales para `CC-BY-SA-4.0` utilizando la JSON API de SPDX:

```bash
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/details/CC-BY-SA-4.0.json | \
jq '{licenseId, name, seeAlso: .seeAlso[0], standardLicenseHeader: .standardLicenseHeader}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-SA-4.0",
  "name": "Creative Commons Attribution Share Alike 4.0 International",
  "seeAlso": "https://creativecommons.org/licenses/by-sa/4.0/legalcode",
  "standardLicenseHeader": ""
}
```

3. Comparar los metadatos de `CC0-1.0` frente a `CC-BY-4.0`:

```bash
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json | \
jq '.licenses[] | select(.licenseId == "CC0-1.0" or .licenseId == "CC-BY-4.0") | {licenseId, isFsfLibre}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-4.0",
  "isFsfLibre": true
}
{
  "licenseId": "CC0-1.0",
  "isFsfLibre": true
}
```

---

### Verification Questions (Exercise 1)

1. **¿Qué combinación de elementos de Creative Commons crea la licencia más restrictiva que impide el uso comercial y las modificaciones mientras exige la atribución?**
   * A) `CC BY-NC`
   * B) `CC BY-NC-ND`
   * C) `CC BY-NC-SA`
   * D) `CC BY-ND`

2. **¿Por qué las licencias Creative Commons están marcadas como `isOsiApproved: false` en el registro SPDX?**
   * A) OSI (Open Source Initiative) solo aprueba licencias diseñadas para código de software, mientras que las licencias CC (excepto CC0/BY) están diseñadas para contenido creativo/documentación y a menudo contienen restricciones no abiertas como NC o ND.
   * B) Creative Commons no presentó su texto legal para revisión a la OSI antes de la versión 4.0.
   * C) Las licencias CC violan la ley de derechos de autor al permitir dedicaciones al dominio público sin contratos legales.
   * D) Los registros SPDX solo rastrean licencias aprobadas por la FSF (Free Software Foundation).

3. **¿Cuál es la distinción legal clave entre `CC0-1.0` y `CC-BY-4.0` respecto a los usuarios derivados (downstream consumers)?**
   * A) `CC0-1.0` requiere atribución solo en aplicaciones comerciales, mientras que `CC-BY-4.0` la requiere siempre.
   * B) `CC0-1.0` renuncia a todos los derechos de autor en la máxima medida permitida por la ley (sin requerir atribución), mientras que `CC-BY-4.0` conserva los derechos de autor y obliga legalmente a los usuarios derivados a dar crédito al creador.
   * C) `CC-BY-4.0` obliga a que las modificaciones derivadas se publiquen bajo una licencia idéntica, mientras que `CC0-1.0` permite el licenciamiento propietario.
   * D) `CC0-1.0` se aplica exclusivamente a binarios de software, mientras que `CC-BY-4.0` se aplica exclusivamente a documentación.

---

## Exercise 2: Implementing Automated CC Compliance and REUSE Validation in CI/CD

### Objective
Configurar un pipeline automatizado de cumplimiento de encabezados de licencia para un repositorio de documentación que contiene guías Markdown, diagramas de arquitectura SVG y datos de benchmark JSON utilizando el estándar FSFE REUSE.

### Context & Mechanics
En los repositorios GitOps modernos, cada archivo debe expresar metadatos claros de copyright y licencia. Para archivos binarios/creativos (como diagramas PNG o SVG) donde los comentarios de encabezado inline rompen la sintaxis del archivo, REUSE utiliza archivos `.license` separados o un archivo `.reuse/dep5` centralizado utilizando la sintaxis de copyright de Debian.

### Configuration Manifest

Crear `.reuse/dep5` para mapear artefactos de arquitectura que no son código a licencias Creative Commons:

```ini
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Platform-Architecture-Docs
Source: https://github.com/example-org/platform-docs

Files: docs/*
Copyright: 2026 Platform Engineering Team <sre@example.com>
License: CC-BY-4.0

Files: architecture/diagrams/*
Copyright: 2026 Enterprise Architecture Guild <arch@example.com>
License: CC-BY-SA-4.0

Files: benchmarks/data/*.json
Copyright: 2026 SRE Performance Group <perf@example.com>
License: CC0-1.0
```

### Execution Steps

1. Instalar la herramienta CLI `reuse` de Python dentro de un entorno virtual:

```bash
cd ~/cc-compliance-lab
python3 -m venv venv
source venv/bin/activate
pip install reuse
```

2. Crear archivos de documentación de muestra que coincidan con la estructura de repositorio especificada:

```bash
mkdir -p docs architecture/diagrams benchmarks/data .reuse

cat << 'EOF' > docs/sre-runbook.md
# Kubernetes Out-of-Memory (OOM) Troubleshooting Runbook
This document outlines standard operational procedures for SRE teams handling Pod OOMKilled events.
EOF

cat << 'EOF' > architecture/diagrams/cluster-topology.svg
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <circle cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
</svg>
EOF

cat << 'EOF' > benchmarks/data/latency-metrics.json
{
  "p99_latency_ms": 12.4,
  "p95_latency_ms": 4.1,
  "throughput_rps": 45000
}
EOF
```

3. Escribir el manifiesto `.reuse/dep5` creado anteriormente:

```bash
cat << 'EOF' > .reuse/dep5
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Platform-Architecture-Docs
Source: https://github.com/example-org/platform-docs

Files: docs/*
Copyright: 2026 Platform Engineering Team <sre@example.com>
License: CC-BY-4.0

Files: architecture/diagrams/*
Copyright: 2026 Enterprise Architecture Guild <arch@example.com>
License: CC-BY-SA-4.0

Files: benchmarks/data/*.json
Copyright: 2026 SRE Performance Group <perf@example.com>
License: CC0-1.0
EOF
```

4. Descargar los archivos de texto de licencia requeridos por REUSE en `LICENSES/`:

```bash
mkdir -p LICENSES

# Fetch official license texts via REUSE CLI tool
reuse download CC-BY-4.0 CC-BY-SA-4.0 CC0-1.0
```

**Expected CLI Output:**
```text
Successfully downloaded CC-BY-4.0.txt
Successfully downloaded CC-BY-SA-4.0.txt
Successfully downloaded CC0-1.0.txt
```

5. Ejecutar `reuse lint` para verificar el cumplimiento automatizado en todos los activos:

```bash
reuse lint
```

**Expected CLI Output:**
```text
# Summary

* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: CC-BY-4.0, CC-BY-SA-4.0, CC0-1.0
* Read files: 4
* Total files: 4

Congratulations! Your project is compliant with version 3.0 of the REUSE Specification!
```

---

### Verification Questions (Exercise 2)

1. **¿Por qué es preferible usar `.reuse/dep5` para archivos de datos SVG y JSON en comparación con agregar encabezados inline?**
   * A) `.reuse/dep5` cifra las declaraciones de copyright para que terceros no puedan manipularlas.
   * B) Los comentarios de encabezado inline en formatos estructurados como JSON hacen que el archivo sea sintácticamente inválido, mientras que los comentarios SVG pueden degradar el rendimiento de renderizado. `.reuse/dep5` proporciona un mapeo externo sin modificar los binarios de los activos.
   * C) `.reuse/dep5` traduce automáticamente las licencias a jurisdicciones internacionales.
   * D) Las reglas de Creative Commons exigen que las licencias CC nunca deben colocarse directamente dentro de archivos fuente.

2. **Si un miembro del equipo agrega un nuevo diagrama en `architecture/diagrams/new-mesh.svg` sin actualizar `.reuse/dep5` ni agregar un archivo `.license`, ¿qué mostrará la salida de `reuse lint`?**
   * A) Convierte automáticamente el archivo a `CC0-1.0`.
   * B) Devuelve un código de salida distinto de cero notificando `Missing licensing information` para `architecture/diagrams/new-mesh.svg`.
   * C) Ignora las extensiones que no son código como `.svg` por defecto.
   * D) Genera un error de sintaxis en Python y aborta la ejecución.

---

## Exercise 3: Resolving Remix Compatibility Matrix & Derivative Works Rules

### Objective
Evaluar matrices de compatibilidad de licencias para derivados de documentación y construir directrices operativas para equipos de plataforma que agregan documentación externa en runbooks.

### Context & Mechanics
Mezclar obras con licencia Creative Commons en una sola obra derivada se rige por la **Matriz de compatibilidad de CC**.

Restricciones clave al crear una **Obra derivada** (Remezcla):
* El contenido **ND (NoDerivatives)** **no se puede remezclar** ni incluir en absoluto en una obra derivada. Solo se puede distribuir en su forma original como parte de una colección.
* **SA (ShareAlike)** requiere que *toda la obra derivada* esté licenciada bajo exactamente la misma licencia o una licencia compatible explícita (por ejemplo, `CC BY-SA 4.0` se puede adaptar a `CC BY-SA 4.0`).
* **NC (NonCommercial)** obliga a que la obra derivada resultante conserve una cláusula NC.
* Los elementos **BY** deben acumular crédito para todos los autores de origen (upstream).

```
       UPSTREAM ASSET 1                       UPSTREAM ASSET 2
    +--------------------+                 +--------------------+
    |     CC BY 4.0      |                 |    CC BY-SA 4.0    |
    +---------+----------+                 +---------+----------+
              |                                      |
              +-------------------+------------------+
                                  |
                                  v
                    +---------------------------+
                    |  REMIX / DERIVATIVE WORK  |
                    |     MUST BE LICENSED      |
                    |      CC BY-SA 4.0         |
                    +---------------------------+
```

### Compatibility Rules Matrix for Adapting Two Works

| Licencia de origen 1 | Licencia de origen 2 | Licencia derivada resultante | ¿Permitido? |
| :--- | :--- | :--- | :--- |
| `CC BY` | `CC BY` | `CC BY` | Sí |
| `CC BY` | `CC BY-SA` | `CC BY-SA` | Sí (SA se propaga) |
| `CC BY` | `CC BY-NC` | `CC BY-NC` | Sí (NC se propaga) |
| `CC BY-SA` | `CC BY-NC-SA` | **Incompatible** | **NO** (Conflicto de SA: una requiere NC, la otra permite uso comercial) |
| Cualquier licencia | `CC BY-ND` | **Incompatible** | **NO** (ND prohíbe la adaptación) |
| `CC0` | `CC BY` | `CC BY` | Sí |

---

### Execution Steps

1. Crear un script de validación `validate_remix.sh` para simular un pipeline que compruebe si la combinación de dos activos de documentación viola las reglas de CC:

```bash
cat << 'EOF' > validate_remix.sh
#!/usr/bin/env bash
set -euo pipefail

LICENSE_A="$1"
LICENSE_B="$2"

echo "Evaluating compatibility for Remix: [$LICENSE_A] + [$LICENSE_B]"

if [[ "$LICENSE_A" == *"ND"* ]] || [[ "$LICENSE_B" == *"ND"* ]]; [[ "$LICENSE_A" != "$LICENSE_B" ]]; then
    echo "ERROR: Violation of NoDerivatives (ND). Cannot create derivative work."
    exit 1
fi

if [[ "$LICENSE_A" == *"SA"* ]] && [[ "$LICENSE_B" == *"NC-SA"* ]]; then
    echo "ERROR: ShareAlike conflict! CC-BY-SA requires downstream to be CC-BY-SA (allowing commercial), while CC-BY-NC-SA forces NonCommercial."
    exit 1
fi

if [[ "$LICENSE_A" == "CC-BY" ]] && [[ "$LICENSE_B" == "CC-BY-SA" ]]; then
    echo "SUCCESS: Compatible. Output work must be licensed as CC-BY-SA."
    exit 0
fi

if [[ "$LICENSE_A" == "CC0" ]]; then
    echo "SUCCESS: Compatible. Output inherits [$LICENSE_B]."
    exit 0
fi

echo "SUCCESS: Combination permitted under standard CC compatibility terms."
EOF

chmod +x validate_remix.sh
```

2. Probar una adaptación válida (`CC-BY` + `CC-BY-SA`):

```bash
./validate_remix.sh "CC-BY" "CC-BY-SA"
```

**Expected CLI Output:**
```text
Evaluating compatibility for Remix: [CC-BY] + [CC-BY-SA]
SUCCESS: Compatible. Output work must be licensed as CC-BY-SA.
```

3. Probar una adaptación inválida (`CC-BY-SA` + `CC-BY-NC-SA`):

```bash
./validate_remix.sh "CC-BY-SA" "CC-BY-NC-SA" || echo "Execution failed as expected."
```

**Expected CLI Output:**
```text
Evaluating compatibility for Remix: [CC-BY-SA] + [CC-BY-NC-SA]
ERROR: ShareAlike conflict! CC-BY-SA requires downstream to be CC-BY-SA (allowing commercial), while CC-BY-NC-SA forces NonCommercial.
Execution failed as expected.
```

---

### Verification Questions (Exercise 3)

1. **Un ingeniero quiere tomar un runbook interno licenciado bajo `CC BY-SA 4.0` y fusionar secciones de una guía de terceros licenciada bajo `CC BY-NC-SA 4.0`. ¿Se puede publicar legalmente el documento combinado resultante? ¿Por qué sí o por qué no?**
   * A) Sí, siempre que el autor otorgue crédito a ambos repositorios de origen bajo `CC BY`.
   * B) No. `CC BY-SA 4.0` requiere que las obras derivadas se publiquen bajo `CC BY-SA 4.0` (lo que permite el uso comercial), mientras que `CC BY-NC-SA 4.0` requiere que las obras derivadas se publiquen bajo una licencia no comercial (`CC BY-NC-SA`). Estas obligaciones ShareAlike entran en conflicto mutuamente.
   * C) Sí, porque las licencias ShareAlike son universalmente compatibles entre sí independientemente de las marcas NC.
   * D) No, porque Creative Commons prohíbe combinar dos documentos cualesquiera con licencias diferentes.

2. **¿Cuál es la restricción operativa al alojar una imagen licenciada bajo `CC BY-ND 4.0` dentro de un portal de documentación licenciado bajo `CC BY 4.0`?**
   * A) La imagen no se puede incluir en el portal bajo ninguna circunstancia.
   * B) La imagen se puede mostrar en su estado original y sin modificaciones como parte de una colección (inclusión textual/literal), pero sus elementos visuales no se pueden editar, recortar ni alterar para crear una obra derivada.
   * C) Incluir la imagen obliga a que todo el portal de documentación pase a ser `CC BY-ND 4.0`.
   * D) El portal debe pagar regalías a Creative Commons para alojar contenido ND.

3. **¿Por qué generalmente se desaconseja el uso de licencias Creative Commons (como CC BY-SA 4.0) para el código fuente de software, y qué se debería usar en su lugar?**
   * A) Las licencias CC no contienen concesiones explícitas de derechos de patentes ni disposiciones adaptadas para la entrega y compilación de código fuente de software; en su lugar, se deben usar licencias de software de código abierto como GPL, Apache 2.0 o MIT.
   * B) Las licencias Creative Commons son inválidas bajo el derecho internacional cuando se aplican a archivos de texto ASCII.
   * C) El código de software no se puede proteger por derechos de autor bajo las leyes de propiedad intelectual modernas.
   * D) La OSI prohíbe el uso de cualquier licencia registrada en SPDX para repositorios de código fuente.

---

<details>
<summary>Clave de respuestas y explicaciones de los ejercicios</summary>

### Exercise 1 Answer Key

1. **Respuesta correcta: B (`CC BY-NC-ND`)**
   * **Explicación:** `CC BY-NC-ND` es la licencia Creative Commons más restrictiva. Requiere Atribución (`BY`), restringe el uso a No Comercial (`NC`) y prohíbe adaptaciones/remezclas (`ND`).
2. **Respuesta correcta: A**
   * **Explicación:** La Open Source Initiative (OSI) define la Open Source Definition específicamente para licencias de software. Las licencias Creative Commons (excepto CC0, que es una dedicación al dominio público, y CC BY/CC BY-SA que se consideran licencias de cultura libre) contienen cláusulas como `NC` (NonCommercial) o `ND` (NoDerivatives) que violan explícitamente el Criterio 3 de la OSD (No discriminación por campos de aplicación) y el Criterio 4 de la OSD (Permitir obras derivadas).
3. **Respuesta correcta: B**
   * **Explicación:** `CC0-1.0` es una herramienta legal diseñada para renunciar a todos los derechos de autor y de bases de datos en la máxima medida permitida por la ley local, funcionando como una dedicación al dominio público. Los usuarios derivados no tienen la obligación legal de atribuir al autor. `CC-BY-4.0` conserva los derechos de autor y crea un requisito legal obligatorio para que los usuarios derivados proporcionen atribución, un enlace a la licencia e indiquen cambios.

---

### Exercise 2 Answer Key

1. **Respuesta correcta: B**
   * **Explicación:** Los archivos que no son código, como JSON, PNG o SVG, pueden romper los parsers o sufrir problemas de renderizado si se inyectan comentarios de texto directamente en sus estructuras de archivo. La especificación FSFE REUSE resuelve esto colocando metadatos de copyright/licenciamiento en `.reuse/dep5` (o archivos `.license` adyacentes), manteniendo la integridad del archivo y garantizando el cumplimiento legible por máquina.
2. **Respuesta correcta: B**
   * **Explicación:** `reuse lint` comprueba cada archivo en el repositorio con respecto a las declaraciones de licencia. Si se agrega un archivo sin la regla correspondiente en `.reuse/dep5` o un archivo `.license` adjunto, la herramienta falla con un código de salida distinto de cero notificando la falta de cobertura de licencia asignada.

---

### Exercise 3 Answer Key

1. **Respuesta correcta: B**
   * **Explicación:** `CC BY-SA 4.0` exige que cualquier obra derivada debe licenciarse bajo `CC BY-SA 4.0` (o una licencia compatible listada), lo que permite la reutilización comercial. Por el contrario, `CC BY-NC-SA 4.0` exige que las obras derivadas deben publicarse bajo `CC BY-NC-SA 4.0`, prohibiendo la reutilización comercial. Una sola obra derivada no puede ser simultáneamente comercial y no comercial; por lo tanto, sus requisitos ShareAlike no se pueden reconciliar.
2. **Respuesta correcta: B**
   * **Explicación:** `ND` (NoDerivatives) impide la creación de *obras derivadas* (adaptaciones/remezclas). Sin embargo, incrustar una imagen no alterada junto a texto diferenciado constituye un *Agregado/Colección*, lo cual está permitido siempre que la imagen en sí no se modifique y se dé el crédito adecuado.
3. **Respuesta correcta: A**
   * **Explicación:** Las licencias Creative Commons fueron diseñadas para obras creativas, artísticas y literarias (documentación, audio, video, imágenes). Carecen de disposiciones que aborden la concesión de patentes de software, mecanismos de distribución de código fuente frente a binarios, declaraciones de encabezado y vinculación de dependencias. Los proyectos de software deben utilizar licencias de software dedicadas (por ejemplo, Apache-2.0, MIT, GPL-3.0).

</details>