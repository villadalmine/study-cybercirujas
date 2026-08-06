# LPI 050-100: Open Source Essentials
## Tema 3.3: Otras Licencias de Contenido Abierto (Peso: 2.5)

### Fuentes de Referencia y Oficiales
- **Linux Professional Institute (LPI) Open Source Essentials**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Especificación de Licencias Creative Commons**: [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
- **GNU Free Documentation License (GFDL v1.3)**: [https://www.gnu.org/licenses/fdl-1.3.html](https://www.gnu.org/licenses/fdl-1.3.html)
- **Open Data Commons Open Database License (ODbL)**: [https://opendatacommons.org/licenses/odbl/](https://opendatacommons.org/licenses/odbl/)
- **Lista y Especificaciones de Licencias SPDX**: [https://spdx.org/licenses/](https://spdx.org/licenses/)
- **Especificación REUSE para la Cadena de Suministro de Software y Contenido**: [https://reuse.software/](https://reuse.software/)

---

### Resumen Arquitectónico y Mecánica

Las licencias de software tradicionales (por ejemplo, GNU GPL, MIT, Apache 2.0) están diseñadas para código fuente ejecutable y binarios de software. Sin embargo, las arquitecturas de plataformas empresariales modernas manejan un gran número de activos que no son código: documentación técnica, conjuntos de datos de entrenamiento (datasets), modelos de IA, esquemáticos de infraestructura y bases de datos relacionales/de grafos. 

Aplicar licencias de software tradicionales a contenido que no es código introduce compensaciones (trade-offs) legales y operacionales significativas:
1. **Código fuente vs. Contenido renderizado**: Las licencias de software se basan en conceptos como "disponibilidad del código fuente" y "compilación/enlazado", los cuales no se traducen limpiamente a medios, documentación (Markdown/AsciiDoc/PDF) o datasets crudos.
2. **Derechos de Bases de Datos Sui Generis**: En jurisdicciones como la Unión Europea y el Reino Unido, las bases de datos están protegidas por un derecho legal específico (derecho de base de datos *sui generis*) separado del derecho de autor (copyright) estándar. Las licencias de software no abordan la estructura de la base de datos versus la extracción del contenido de la base de datos.
3. **Restricciones de Atribución y Modificación**: La documentación y los medios educativos a menudo requieren un formato estricto de atribución, la preservación de secciones históricas invariantes o la prohibición de la reutilización comercial; mecanismos que no están presentes en las licencias de software permisivas.

```
+-----------------------------------------------------------------------------------+
|                            OPEN CONTENT LICENSE TAXONOMY                          |
+------------------------------------------------------+----------------------------+
| MEDIA & DOCUMENTATION                                | DATASETS & DATABASES       |
+-----------------------+------------------------------+----------------------------+
| Creative Commons      | GNU Free Documentation (GFDL)| Open Data Commons          |
| - CC BY 4.0           | - Invariant Sections         | - PDDL (Public Domain)     |
| - CC BY-SA 4.0        | - Front-Cover Texts          | - ODC-BY (Attribution)     |
| - CC BY-NC / ND       | - Back-Cover Texts           | - ODbL (ShareAlike Data)   |
+-----------------------+------------------------------+----------------------------+
```

---

### Ejercicios Prácticos Guiados

#### Ejercicio 1: Arquitectura de Creative Commons e Identificación SPDX

##### Escenario
Estás diseñando la arquitectura de un pipeline de documentación automatizado para una plataforma cloud empresarial. La documentación contiene guías técnicas (texto), diagramas de arquitectura (vectores) y datasets de muestra. Debes configurar encabezados de identificadores SPDX, establecer el cumplimiento bajo la definición de **Aprobado para Obras Culturales Libres** (Approved for Free Cultural Works) y validar los rasgos de la licencia utilizando herramientas CLI.

##### Paso 1.1: Configuración del Entorno y Verificación de Herramientas
Ejecutá los siguientes comandos en tu shell de Linux para instalar `reuse` (el motor de cumplimiento de la cadena de suministro de SPDX) e inicializar la estructura de directorio de destino:

```bash
mkdir -p ~/open-content-lab/docs ~/open-content-lab/media
cd ~/open-content-lab

# Verify python3 and pip are available, then install reuse tool
python3 -m pip install --quiet reuse
reuse --version
```

**Salida Esperada:**
```text
reuse, version 5.0.0 (or higher)
```

##### Paso 1.2: Construcción de Encabezados SPDX Sintácticamente Válidos para Activos CC
Crea un archivo de documentación `docs/architecture-guide.md` con un encabezado SPDX embebido bajo **CC-BY-4.0** (Creative Commons Attribution 4.0 International) y un descriptor de metadatos de diagrama bajo **CC-BY-SA-4.0** (Creative Commons Attribution-ShareAlike 4.0 International).

Crea `docs/architecture-guide.md`:
```markdown
<!--
SPDX-FileCopyrightText: 2026 Cloud Platform Architecture Team <arch@example.com>
SPDX-License-Identifier: CC-BY-4.0
-->

# Cloud Platform Storage Architecture

## Overview
This document outlines the distributed block storage mechanism for enterprise workloads.

## License Matrix
- Narrative Documentation: CC-BY-4.0 (Free Cultural Work)
- Vector Diagrams: CC-BY-SA-4.0 (Free Cultural Work)
```

Crea el archivo `.reuse/dep5` para el mapeo automatizado de licencias de la cadena de suministro de archivos multimedia:
```ini
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Enterprise Open Content Assets
Source: https://git.example.com/platform/docs

Files: media/*.png
Copyright: 2026 Graphics Engineering Group <design@example.com>
License: CC-BY-SA-4.0
```

##### Paso 1.3: Verificación del Cumplimiento de la Cadena de Suministro REUSE
Ejecutá la herramienta de verificación de cumplimiento contra tu repositorio de documentación:

```bash
reuse lint
```

**Salida Esperada:**
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: CC-BY-4.0, CC-BY-SA-4.0
* Status: OK
```

---

##### Preguntas de Verificación (Ejercicio 1)

**Pregunta 1.1:** ¿Cuál de las siguientes combinaciones de licencias Creative Commons cumple con los criterios para la **Definición de Obras Culturales Libres**?
- A) CC BY-NC-SA 4.0
- B) CC BY-ND 4.0
- C) CC BY-SA 4.0
- D) CC BY-NC 4.0

**Pregunta 1.2:** Si un ingeniero DevOps modifica un diagrama licenciado bajo `CC-BY-SA-4.0` y lo embebe dentro de un manual de capacitación comercial propietario, ¿qué requisito legal impone la cláusula CompartirIgual (ShareAlike - SA) sobre el diagrama modificado resultante?
- A) El manual propietario completo debe licenciamiento dual bajo GPL v3.
- B) El diagrama modificado en sí debe distribuirse bajo `CC-BY-SA-4.0` o una licencia compatible si se distribuye.
- C) El diagrama modificado no se puede utilizar en ningún contexto comercial.
- D) El ingeniero debe pagar una tarifa de regalías al titular del copyright original.

---

#### Ejercicio 2: Mecánica de la Licencia de Documentación Libre de GNU (GFDL v1.3)

##### Escenario
Tu equipo de infraestructura mantiene manuales de sistemas heredados (legacy) gobernados por la **Licencia de Documentación Libre de GNU (GFDL v1.3)**. Debes estructurar un documento que contenga **Secciones Invariantes** (Invariant Sections) y **Textos de Cubierta / Contracubierta** (Front-Cover / Back-Cover Texts), inspeccionar sus restricciones de licenciamiento y evaluar su compatibilidad con las licencias Creative Commons.

##### Paso 2.1: Redacción del Encabezado de un Manual Compatible con GFDL
Crea `docs/legacy-storage-manual.adoc` con avisos formales de GFDL 1.3 que especifiquen las Secciones Invariantes:

```asciidoc
= Enterprise SAN Infrastructure Management Manual
:author: Systems Engineering Group
:revdate: 2026-08-06

== License Notice
Copyright (C) 2026 Systems Engineering Group.
Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with the Invariant Sections being "Section 1: Architectural History",
with the Front-Cover Texts being "Enterprise Systems Manual", and
with the Back-Cover Texts being "Supported by Cloud SRE Dept".

== Section 1: Architectural History
[NOTE]
This section is INVARIANT. It cannot be altered, removed, or modified
in secondary derivative versions.

== Section 2: Operational CLI Reference
Run the following command to check storage pool health:
$ zpool status storage-pool-01
```

##### Paso 2.2: Análisis Programático de las Restricciones Invariantes de GFDL
Escribí un script ligero de verificación en Python `verify_gfdl.py` para auditar archivos de documentación Markdown/AsciiDoc en busca de declaraciones de cláusulas invariantes:

```python
#!/usr/bin/env python3
import sys
import re

def audit_gfdl_invariants(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    gfdl_match = re.search(r'GNU Free Documentation License', content, re.IGNORECASE)
    invariant_match = re.search(r'with the Invariant Sections being ([^\n,]+)', content)
    
    print(f"[*] Auditing File: {filepath}")
    if gfdl_match:
        print("    [+] License Detected: GFDL")
        if invariant_match:
            print(f"    [!] Invariant Sections Enforced: {invariant_match.group(1)}")
            print("    [!] Trade-Off Warning: File contains Invariant Sections. Incompatible with strict CC-BY-SA 4.0 compliance.")
        else:
            print("    [+] No Invariant Sections declared.")
    else:
        print("    [-] GFDL not detected.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        audit_gfdl_invariants(sys.argv[1])
    else:
        print("Usage: python3 verify_gfdl.py <file-path>")
```

Ejecutá el script de verificación contra `docs/legacy-storage-manual.adoc`:

```bash
chmod +x verify_gfdl.py
./verify_gfdl.py docs/legacy-storage-manual.adoc
```

**Salida Esperada:**
```text
[*] Auditing File: docs/legacy-storage-manual.adoc
    [+] License Detected: GFDL
    [!] Invariant Sections Enforced: "Section 1: Architectural History"
    [!] Trade-Off Warning: File contains Invariant Sections. Incompatible with strict CC-BY-SA 4.0 compliance.
```

---

##### Preguntas de Verificación (Ejercicio 2)

**Pregunta 2.1:** ¿Qué es una "Sección Invariante" (Invariant Section) bajo la Licencia de Documentación Libre de GNU (GFDL), y qué restricción impone a los autores secundarios?
- A) Una sección de código que debe compilar sin advertencias (warnings).
- B) Una sección designada del documento que maneja el título/historia y que no puede ser modificada ni eliminada al redistribuir o modificar el documento.
- C) Una sección legal obligatoria que bloquea el documento para su uso exclusivo comercial.
- D) Una sección que contiene checksums criptográficos del binario del documento.

**Pregunta 2.2:** ¿Son los manuales GFDL v1.3 que contienen Secciones Invariantes compatibles para un licenciamiento dual directo o un re-licenciamiento hacia `CC BY-SA 4.0`?
- A) Sí, GFDL v1.3 y CC BY-SA 4.0 son 100% compatibles bidireccionalmente bajo cualquier circunstancia.
- B) No, CC BY-SA 4.0 no permite secciones invariantes ni restricciones secundarias que prohíban la modificación de partes del texto.
- C) Sí, siempre y cuando el autor pague a la FSF una tarifa de re-licenciamiento.
- D) No, porque GFDL solo se aplica a archivos binarios.

---

#### Ejercicio 3: Licenciamiento de Datos Abiertos y Bases de Datos (ODbL, ODC-BY, PDDL)

##### Escenario
Estás desplegando una plataforma de recolección de datos de telemetría que extrae datos de topología de red y publica bases de datos de topología agregadas. Debes comprender el límite legal entre los **Derechos de Bases de Datos Sui Generis**, puntos de datos individuales y estructuras de esquemas utilizando licencias Open Data Commons (ODbL, ODC-BY, PDDL).

##### Paso 3.1: Definición del Alcance de la Licencia para la Infraestructura de Bases de Datos
Crea un archivo de especificación de licenciamiento de base de datos empresarial `database-license-manifest.yaml` que represente un despliegue de dataset en producción:

```yaml
apiVersion: data.enterprise.io/v1alpha1
kind: DatabaseLicenseManifest
metadata:
  name: network-topology-db
spec:
  databaseName: "global-mesh-telemetry"
  licensingFramework: "Open Data Commons"
  components:
    - target: "Database Structure & Schema"
      license: "ODc-BY-1.0"
      spdxID: "ODC-By-1.0"
      description: "Attribution required for database structural usage."
    - target: "Aggregated Topological Data Contents"
      license: "ODbL-1.0"
      spdxID: "ODbL-1.0"
      description: "Open Database License - ShareAlike enforced on database modifications and extractions."
    - target: "Raw Sensor Fact Records (Individual Data Points)"
      license: "PDDL-1.0"
      spdxID: "PDDL-1.0"
      description: "Public Domain Dedication and License - Factual data points devoid of copyright."
```

##### Paso 3.2: Consulta de Metadatos Oficiales de Licencias de Open Data Commons
Utilizá `curl` y `jq` para verificar los identificadores de licencia SPDX y metadatos para las licencias Open Data Commons a través de la API REST oficial de SPDX:

```bash
# Query ODbL 1.0 details from SPDX API
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses/ODbL-1.0.json | jq '{licenseId: .licenseId, name: .name, isOsiApproved: .isOsiApproved, isFsfLibre: .isFsfLibre}'

# Query ODC-By 1.0 details from SPDX API
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses/ODC-By-1.0.json | jq '{licenseId: .licenseId, name: .name, isOsiApproved: .isOsiApproved}'
```

**Salida Esperada:**
```json
{
  "licenseId": "ODbL-1.0",
  "name": "Open Data Commons Open Database License v1.0",
  "isOsiApproved": false,
  "isFsfLibre": true
}
{
  "licenseId": "ODC-By-1.0",
  "name": "Open Data Commons Attribution License v1.0",
  "isOsiApproved": false
}
```

##### Paso 3.3: Análisis de las Compensaciones Operacionales del Licenciamiento de Bases de Datos
Ejecutá un script de simulación en Python `db_compliance_check.py` para evaluar si una tarea propuesta de enriquecimiento de datos activa la cláusula CompartirIgual (ShareAlike / Derivative Database) de ODbL:

```python
#!/usr/bin/env python3

def check_odbl_trigger(action_type, distribution_scope):
    print(f"[+] Action: {action_type} | Scope: {distribution_scope}")
    if action_type == "PUBLIC_DERIVATIVE_DATABASE" and distribution_scope == "EXTERNAL":
        return ("RESULT: ODbL ShareAlike Triggered! You MUST release the modified/enhanced "
                "database under ODbL 1.0 and provide access to the raw data/updates.")
    elif action_type == "INTERNAL_DATA_MINING" and distribution_scope == "INTERNAL_ONLY":
        return ("RESULT: Compliant. Internal use of an ODbL database does not trigger "
                "public ShareAlike distribution requirements.")
    elif action_type == "PRODUCED_WORK" and distribution_scope == "EXTERNAL":
        return ("RESULT: Compliant with Attribution. Generating a visual map (Produced Work) "
                "from ODbL data requires notice/attribution, but does NOT require releasing "
                "the underlying rendering software code under ODbL.")
    else:
        return "RESULT: Requires manual legal assessment."

print("Scenario A: Internal analytics pipeline")
print(check_odbl_trigger("INTERNAL_DATA_MINING", "INTERNAL_ONLY"))
print("\nScenario B: Public map image rendered from DB")
print(check_odbl_trigger("PRODUCED_WORK", "EXTERNAL"))
print("\nScenario C: Merging proprietary dataset with ODbL dataset & redistributing DB")
print(check_odbl_trigger("PUBLIC_DERIVATIVE_DATABASE", "EXTERNAL"))
```

Ejecutá el script:
```bash
python3 db_compliance_check.py
```

**Salida Esperada:**
```text
Scenario A: Internal analytics pipeline
[+] Action: INTERNAL_DATA_MINING | Scope: INTERNAL_ONLY
RESULT: Compliant. Internal use of an ODbL database does not trigger public ShareAlike distribution requirements.

Scenario B: Public map image rendered from DB
[+] Action: PRODUCED_WORK | Scope: EXTERNAL
RESULT: Compliant with Attribution. Generating a visual map (Produced Work) from ODbL data requires notice/attribution, but does NOT require releasing the underlying rendering software code under ODbL.

Scenario C: Merging proprietary dataset with ODbL dataset & redistributing DB
[+] Action: PUBLIC_DERIVATIVE_DATABASE | Scope: EXTERNAL
RESULT: ODbL ShareAlike Triggered! You MUST release the modified/enhanced database under ODbL 1.0 and provide access to the raw data/updates.
```

---

##### Preguntas de Verificación (Ejercicio 3)

**Pregunta 3.1:** ¿Qué distinción hace la Licencia de Base de Datos Abierta (ODbL) entre una **Base de Datos Derivada** (Derivative Database) y una **Obra Producida** (Produced Work)?
- A) Una Obra Producida es un ejecutable binario compilado, mientras que una Base de Datos Derivada es un archivo JSON plano.
- B) Una Base de Datos Derivada modifica o enriquece los datos/estructura subyacentes (lo que requiere CompartirIgual al distribuirla públicamente), mientras que una Obra Producida (por ejemplo, una imagen, informe o mapa generado a partir de datos) solo requiere un aviso de atribución.
- C) Una Obra Producida requiere la divulgación completa del código fuente bajo GNU GPL v3.
- D) ODbL trata tanto las Bases de Datos Derivadas como las Obras Producidas de manera idéntica, requiriendo acceso completo a la base de datos cruda en ambos casos.

**Pregunta 3.2:** ¿Por qué las licencias de software estándar como GPL v2 o MIT son a menudo inadecuadas para gobernar grandes bases de datos relacionales en jurisdicciones con Derechos de Bases de Datos *Sui Generis*?
- A) Las licencias de software solo compilan en plataformas Linux.
- B) Las licencias de software gobiernan el derecho de autor (copyright) en la ejecución del código/texto fuente, pero no abordan específicamente los derechos sobre la extracción, reutilización o derechos estructurales de bases de datos de forma independiente del derecho de autor.
- C) Las licencias de software estándar convierten automáticamente las bases de datos al dominio público.
- D) Los sistemas de gestión de bases de datos (DBMS) se rehúsan a analizar licencias sin formato YAML.

---

<details>
<summary><strong>Hacé clic para expandir la Clave de Respuestas Completa y las Explicaciones Arquitectónicas Profundas</strong></summary>

### Soluciones Detalladas e Inmersión Teórica Profunda

#### Respuestas del Ejercicio 1
- **Pregunta 1.1: Respuesta Correcta = C (CC BY-SA 4.0)**
  - **Explicación Arquitectónica**: La *Definición de Obras Culturales Libres* (Definition of Free Cultural Works, mantenida por Freedom Defined) requiere que una licencia otorgue cuatro libertades fundamentales: libertad de usar/ejecutar, libertad de estudiar/aplicar, libertad de redistribuir copias y libertad de modificar/mejorar y distribuir derivadas.
  - **CC BY 4.0** y **CC BY-SA 4.0** están reconocidas oficialmente como **Aprobado para Obras Culturales Libres**.
  - Las cláusulas **NC (NoComercial / NonCommercial)** restringen el uso comercial, violando la Libertad 1 (libertad de usar para cualquier propósito).
  - Las cláusulas **ND (SinDerivadas / NoDerivatives)** prohíben la modificación, violando la Libertad 4 (libertad de adaptar y redistribuir modificaciones).

- **Pregunta 1.2: Respuesta Correcta = B (El diagrama modificado en sí debe distribuirse bajo CC-BY-SA-4.0 o una licencia compatible si se distribuye)**
  - **Explicación Arquitectónica**: CompartirIgual (ShareAlike - SA) opera como un mecanismo de copyleft específicamente dirigido al activo y a sus adaptaciones directas. Si un ingeniero modifica un activo CC BY-SA, el activo modificado en sí hereda los términos de CC BY-SA. Embeberlo dentro de una obra más grande (como un manual) no fuerza automáticamente todo el texto del manual a estar bajo CC BY-SA si el manual es una obra colectiva, pero el componente de diagrama adaptado debe permanecer licenciado bajo CC BY-SA 4.0.

---

#### Respuestas del Ejercicio 2
- **Pregunta 2.1: Respuesta Correcta = B (Una sección designada del documento que maneja el título/historia y que no puede ser modificada ni eliminada al redistribuir o modificar el documento)**
  - **Explicación Arquitectónica**: La Licencia de Documentación Libre de GNU (GFDL) fue creada por la Free Software Foundation (FSF) principalmente para manuales de software. Incluye una disposición específica que permite a los autores declarar secciones secundarias (como reconocimientos históricos, avisos legales o ensayos filosóficos) como **Secciones Invariantes** (Invariant Sections). A los editores secundarios se les prohíbe legalmente alterar, actualizar o eliminar estas secciones.

- **Pregunta 2.2: Respuesta Correcta = B (No, CC BY-SA 4.0 no permite secciones invariantes ni restricciones secundarias que prohíban la modificación de partes del texto)**
  - **Explicación Arquitectónica**: Las licencias Creative Commons (incluida CC BY-SA 4.0) prohíben explícitamente restricciones adicionales a los usuarios posteriores o bloques de texto inmodificables. Un documento GFDL que contiene Secciones Invariantes impone restricciones que CC BY-SA 4.0 prohíbe. Aunque GFDL v1.3 incluyó una cláusula limitada de re-licenciamiento para plataformas wiki que cumplían con criterios históricos específicos (migrar a CC BY-SA antes de 2009), los manuales generales de GFDL con Secciones Invariantes no se pueden licenciar de forma dual ni convertir a CC BY-SA 4.0.

---

#### Respuestas del Ejercicio 3
- **Pregunta 3.1: Respuesta Correcta = B (Una Base de Datos Derivada modifica o enriquece los datos/estructura subyacentes requiriendo CompartirIgual al distribuirla públicamente, mientras que una Obra Producida solo requiere aviso de atribución)**
  - **Explicación Arquitectónica**: Las licencias de Open Data Commons (específicamente ODbL) fueron diseñadas explícitamente para resolver el problema de las bases de datos.
    - **Estructura/Contenido de la Base de Datos**: Cubierto por los derechos de ODbL.
    - **Base de Datos Derivada**: Si extraes, combinas o alteras los datos y publicas la base de datos resultante, CompartirIgual (ShareAlike) exige publicar el dataset actualizado bajo ODbL.
    - **Obra Producida**: Si usas los datos para crear un artefacto que no sea una base de datos (por ejemplo, renderizar un mapa en PDF a partir de datos geoespaciales de OpenStreetMap), el mapa es una *Obra Producida*. NO tienes que liberar tu motor de renderizado de mapas ni el código fuente crudo; solo necesitas incluir un aviso de atribución (por ejemplo, "Contiene datos de OpenStreetMap, licenciado bajo ODbL").

- **Pregunta 3.2: Respuesta Correcta = B (Las licencias de software gobiernan el derecho de autor en la ejecución del código/texto fuente, pero no abordan específicamente los derechos sobre la extracción, reutilización o derechos estructurales de bases de datos de forma independiente del derecho de autor)**
  - **Explicación Arquitectónica**: La ley de derecho de autor (copyright) protege la expresión creativa original. Los datos de hechos crudos dentro de una base de datos (por ejemplo, lecturas de temperatura, precios de acciones, tablas de enrutamiento IP) a menudo carecen de expresión creativa original bajo el derecho común (por ejemplo, la doctrina *Feist Publications* en EE. UU.). Sin embargo, jurisdicciones como la UE aplican *Derechos de Bases de Datos Sui Generis* (Directiva de la UE 96/9/CE), que otorgan derechos basados en la inversión sustancial para obtener, verificar o presentar el contenido de la base de datos, independientemente del derecho de autor. Las licencias de software tradicionales (MIT, GPL) solo se enfocan en código sujeto a derecho de autor y no abordan los derechos *sui generis* de extracción/reutilización. Licencias como **ODbL**, **ODC-BY** y **PDDL** licencian explícitamente tanto el derecho de autor como los derechos de base de datos.

---

### Matriz Comparativa: Selección de Licencia por Tipo de Activo

| Tipo de Activo | Licencia Recomendada | Mecanismo Principal | Consideraciones Clave / Compensaciones (Trade-offs) |
| :--- | :--- | :--- | :--- |
| **Medios / Redacción Técnica** | `CC BY 4.0` | Atribución Permisiva | Ideal para la máxima adopción; compatible con Obras Culturales Libres. |
| **Documentación Comunitaria** | `CC BY-SA 4.0` | Contenido Copyleft | Garantiza que la documentación modificada permanezca abierta para la comunidad. |
| **Documentación Legada de la FSF** | `GFDL v1.3` | Protección Invariante | Protege la historia/avisos del autor; compensación: potencial incompatibilidad con CC. |
| **Datasets Públicos / Hechos** | `PDDL` / `CC0` | Dedicación al Dominio Público | Renuncia a todos los derechos de autor y de base de datos; cero fricción para modelos de ML/IA. |
| **Datos Relacionales / Espaciales** | `ODbL 1.0` | Derecho de Base de Datos CompartirIgual | Obliga a que las bases de datos derivadas públicas permanezcan abiertas (ej., OpenStreetMap). |

</details>