# LPI Open Source Essentials (Exam 050-100) — Guía de estudio

## Tema 2.1: Conceptos de Licencias de Software Open Source
* **Peso del examen:** 7.5
* **Audiencia objetivo:** DevOps Engineers, SREs, Platform Architects y Compliance Engineers.
* **URLs de referencia oficial:**
  * LPI Open Source Essentials Overview: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
  * Open Source Initiative (OSI) — Open Source Definition: [https://opensource.org/osd](https://opensource.org/osd)
  * Free Software Foundation (FSF) — The Free Software Definition: [https://www.gnu.org/philosophy/free-sw.html](https://www.gnu.org/philosophy/free-sw.html)
  * SPDX License List & Specification: [https://spdx.org/licenses/](https://spdx.org/licenses/)
  * GNU Licenses & Compatibility Matrix: [https://www.gnu.org/licenses/gpl-faq.html](https://www.gnu.org/licenses/gpl-faq.html)

---

## Mecánica Arquitectónica y Teórica

### 1. FSF Four Essential Freedoms vs. OSI Open Source Definition (OSD)
La gobernanza del licenciamiento de software se basa en dos definiciones fundamentales:

```
                      ┌─────────────────────────────────────────┐
                      │    Free & Open Source Software (FOSS)   │
                      └────────────────────┬────────────────────┘
                                           │
             ┌─────────────────────────────┴─────────────────────────────┐
             ▼                                                           ▼
┌─────────────────────────┐                                 ┌─────────────────────────┐
│     FSF (Free Software) │                                 │  OSI (Open Source)      │
├─────────────────────────┤                                 ├─────────────────────────┤
│ Focus: Ethical Liberty  │                                 │ Focus: Practical Dev    │
│ - Freedom 0: Run        │                                 │ - 10 OSD Criteria       │
│ - Freedom 1: Study      │                                 │ - No Commercial/Field   │
│ - Freedom 2: Share      │                                 │   Discrimination        │
│ - Freedom 3: Improve    │                                 │ - License Neutrality    │
└─────────────────────────┘                                 └─────────────────────────┘
```

* **FSF Four Freedoms (Free Software Foundation):**
  * **Freedom 0:** La libertad de ejecutar el programa para cualquier propósito.
  * **Freedom 1:** La libertad de estudiar cómo funciona el programa y cambiarlo (requiere acceso al código fuente).
  * **Freedom 2:** La libertad de redistribuir copias para que puedas ayudar a tu vecino.
  * **Freedom 3:** La libertad de distribuir copias de tus versiones modificadas a terceros.

* **OSI 10 Criteria (Open Source Initiative):**
  Incluye redistribución libre, disponibilidad del código fuente, permitir obras derivadas, integridad del código fuente del autor, no discriminación contra personas/grupos (Criterio 5), no discriminación contra campos de trabajo (Criterio 6 — por ejemplo, no se puede prohibir el uso comercial o militar), distribución de la licencia, no especificidad del producto, no restricción de otro software y neutralidad tecnológica.

---

### 2. License Taxonomy Spectrum

| License Category | Examples | Distribution Trigger Reciprocity | Linking Boundary Effect | Patent Grants |
| :--- | :--- | :--- | :--- | :--- |
| **Permissive** | `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `Apache-2.0` | Mínima (solo retención de aviso/Notice) | Sin restricciones | `Apache-2.0` incluye concesión expresa de patentes y cláusula de retaliación. `MIT`/`BSD` no se pronuncian. |
| **Weak Copyleft** | `LGPL-2.1`, `LGPL-3.0`, `MPL-2.0`, `EPL-2.0` | Recíproca para modificaciones de librerías/archivos | El enlace dinámico (Dynamic linking) permite el enlace propietario; el enlace estático (Static linking) requiere archivos objeto para reenlazar (relink). | `MPL-2.0`/`EPL-2.0`/`LGPL-3.0` contienen cláusulas explícitas de patentes. |
| **Strong Copyleft** | `GPL-2.0-only`, `GPL-3.0-only` | Recíproca para todo el trabajo combinado/derivado | El enlace estático y dinámico propagan copyleft al código dependiente. | `GPL-3.0` contiene terminación explícita de patentes; `GPL-2.0` se apoya en concesiones implícitas. |
| **Network Copyleft** | `AGPL-3.0-only` | Se activa por binarios **y** por ejecución SaaS/Network (Sección 13) | Expande la definición de distribución para incluir llamadas a API a través de una red. | Disposiciones explícitas de concesión de patentes y retaliación. |

---

## Ejercicios Guiados de Producción

### Ejercicio 1: Inspección de License Headers, SPDX Expressions y generación de SBOMs mediante CLI

En este ejercicio, crearás un root de microservicio multilenguaje de muestra, aplicarás declaraciones estándar de cabecera SPDX y analizarás el árbol de dependencias utilizando herramientas de CLI (`syft` y `jq`) para auditar el cumplimiento de licencias.

#### Paso 1.1: Configuración del entorno y simulación del microservicio
Ejecutá los siguientes comandos en tu shell para construir un workspace con licencias declaradas:

```bash
mkdir -p ~/license-audit-lab/src
cd ~/license-audit-lab

# Create a Permissive python entrypoint with SPDX identifier
cat << 'EOF' > src/app.py
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Platform Engineering Team

import requests

def main():
    print("Microservice initialized under MIT License.")

if __name__ == "__main__":
    main()
EOF

# Create a Go helper with Copyleft SPDX identifier
cat << 'EOF' > src/core.go
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Infrastructure Core Team

package main

import "fmt"

func CoreLogic() {
    fmt.Println("Executing core logic governed by GPL-3.0-or-later")
}
EOF

# Create a package.json referencing external dependencies
cat << 'EOF' > package.json
{
  "name": "edge-router",
  "version": "1.0.0",
  "license": "Apache-2.0",
  "dependencies": {
    "express": "^4.18.2",
    "lodash": "^4.17.21"
  }
}
EOF
```

**Salida esperada del comando:**
```text
Files created under ~/license-audit-lab
```

#### Paso 1.2: Generar un Software Bill of Materials (SBOM) compatible con SPDX
Instalá o ejecutá `syft` (o simulá la generación de SBOM mediante python/jq si syft no está disponible) para emitir un manifiesto JSON SPDX 2.3:

```bash
# Executing syft to scan the directory and generate an SPDX JSON SBOM
syft dir:. -o spdx-json=sbom.spdx.json
```

**Salida esperada del comando:**
```text
 ✔ Scanned application                       [3 packages]
 ✔ Created SBOM                              [spdx-json]
```

#### Paso 1.3: Inspeccionar el manifiesto SPDX generado
Filtrá el SBOM generado para procesar expresiones de licencias usando `jq`:

```bash
jq '{spdxVersion, name, packages: [.packages[] | {name: .name, version: .versionDeclared, license: .licenseConcluded}]}' sbom.spdx.json
```

**Salida esperada del comando:**
```json
{
  "spdxVersion": "SPDX-2.3",
  "name": "license-audit-lab",
  "packages": [
    {
      "name": "express",
      "version": "4.18.2",
      "license": "MIT"
    },
    {
      "name": "lodash",
      "version": "4.17.21",
      "license": "MIT"
    }
  ]
}
```

---

#### Preguntas de Verificación — Bloque 1
1. **Q1.1:** ¿Por qué el Criterio 6 de la OSI ("No discriminación contra campos de trabajo / No Discrimination Against Fields of Endeavor") impide que una licencia que establece *"Este software no se puede utilizar para alojamiento en la nube comercial o aplicaciones militares"* sea certificada como Open Source?
2. **Q1.2:** ¿Cuál es el mecanismo técnico de un encabezado `SPDX-License-Identifier` en archivos de código fuente y cómo reduce la ambigüedad de lectura/análisis por máquina (machine-parsing) en comparación con los bloques de licencia de texto libre heredados (legacy)?

---

### Ejercicio 2: Análisis de compatibilidad de grafos de dependencias y límites de reciprocidad

En este ejercicio, analizarás una arquitectura de software combinada que consta de binarios dinámicos, librerías enlazadas estáticamente y microservicios accedidos a través de límites de API HTTP para determinar las obligaciones de cumplimiento de licencias.

#### Paso 2.1: Analizar escenarios de integración de arquitectura

Considerá el siguiente diagrama de despliegue arquitectónico:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          User Application Stack                             │
│                                                                             │
│  ┌──────────────────────┐    Dynamic Link    ┌───────────────────────────┐  │
│  │ Proprietary Codebase │ ─────────────────> │ LGPL-3.0 Dynamic Library  │  │
│  └──────────┬───────────┘                    └───────────────────────────┘  │
│             │                                                               │
│             │ Static Link                                                   │
│             ▼                                                               │
│  ┌──────────────────────┐                    ┌───────────────────────────┐  │
│  │  GPL-3.0 Engine Lib  │                    │ AGPL-3.0 Microservice     │  │
│  └──────────────────────┘                    │ (Hosted across HTTP API)  │  │
│                                              └─────────────▲─────────────┘  │
│                                                            │ Network Call   │
│                                                            │ (gRPC / REST)  │
│                                              ──────────────┴──────────────  │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Paso 2.2: Evaluar límites de enlace dinámico frente a estático
Ejecutá un rastreo de dependencias de archivos locales para simular cómo los enlaces binarios dinámicos y estáticos propagan los requisitos de copyleft en sistemas Linux:

```bash
# Simulating ldd inspection on a binary linking against LGPL vs GPL libraries
cat << 'EOF' > trace_linking.sh
#!/usr/bin/env bash
echo "=== Analyzing ELF Binary Dynamic Dependencies ==="
echo "Linking target: libcrypto.so (Permissive/Apache-Style)"
echo "Linking target: libglib-2.0.so (LGPL-2.1-or-later)"
echo "Linking target: libgengine.a (Statically Compiled GPL-3.0)"
echo ""
echo "RESULT:"
echo "1. Dynamic linkage to LGPL-2.1 does NOT force the host binary to become LGPL/GPL."
echo "2. Static linkage to GPL-3.0 archive propagates GPL-3.0 copyleft to host binary."
EOF

chmod +x trace_linking.sh
./trace_linking.sh
```

**Salida esperada del comando:**
```text
=== Analyzing ELF Binary Dynamic Dependencies ===
Linking target: libcrypto.so (Permissive/Apache-Style)
Linking target: libglib-2.0.so (LGPL-2.1-or-later)
Linking target: libgengine.a (Statically Compiled GPL-3.0)

RESULT:
1. Dynamic linkage to LGPL-2.1 does NOT force the host binary to become LGPL/GPL.
2. Static linkage to GPL-3.0 archive propagates GPL-3.0 copyleft to host binary.
```

---

#### Preguntas de Verificación — Bloque 2
1. **Q2.1:** Si una empresa despliega internamente una base de datos con licencia `GPL-v3.0` sin modificar para procesar transacciones de backend para un Web SaaS público sin distribuir binarios a los usuarios, ¿está obligada según la `GPL-v3.0` a publicar el código fuente de su front-end SaaS? ¿Cómo cambiaría la respuesta si la base de datos tuviera licencia `AGPL-3.0-only`?
2. **Q2.2:** ¿Qué requisito operativo impone la `LGPL-3.0` a un desarrollador de aplicaciones que enlaza estáticamente una librería LGPL-3.0 en una aplicación propietaria, en comparación con enlazarla dinámicamente?

---

### Ejercicio 3: Implementación de enforzadores de políticas de cumplimiento de licencias automatizados en CI/CD

En este ejercicio, crearás un manifiesto Policy-as-Code sintácticamente válido utilizando sintaxis de estilo Open Policy Agent (OPA) / configuración YAML para bloquear automáticamente licencias no conformes (por ejemplo, `GPL-3.0-only`, `AGPL-3.0-only`, `SSPL-1.0`) durante las compilaciones de integración continua (CI).

#### Paso 3.1: Escribir el archivo de configuración de la política de licencias
Creá una definición de política `license-policy.yaml` que imponga los requisitos de cumplimiento de la empresa:

```bash
cat << 'EOF' > license-policy.yaml
version: "1.0"
policy:
  name: Enterprise-Software-Compliance
  action_on_violation: FAIL_BUILD
  allowed_licenses:
    - MIT
    - Apache-2.0
    - BSD-2-Clause
    - BSD-3-Clause
    - MPL-2.0
  conditional_licenses:
    LGPL-2.1-or-later:
      allow_if: DYNAMIC_LINKING_ONLY
    LGPL-3.0-or-later:
      allow_if: DYNAMIC_LINKING_ONLY
  banned_licenses:
    - GPL-2.0-only
    - GPL-3.0-only
    - AGPL-3.0-only
    - SSPL-1.0
    - Commons-Clause
EOF
```

**Salida esperada del comando:**
```text
File license-policy.yaml created.
```

#### Paso 3.2: Construir el script del motor de verificación
Escribí un script validador en Python `check_compliance.py` que procese el SBOM generado contra `license-policy.yaml`:

```bash
cat << 'EOF' > check_compliance.py
#!/usr/bin/env python3
import json
import yaml
import sys

def audit():
    with open('license-policy.yaml', 'r') as f:
        policy = yaml.safe_load(f)
    
    with open('sbom.spdx.json', 'r') as f:
        sbom = json.load(f)

    allowed = set(policy['policy']['allowed_licenses'])
    banned = set(policy['policy']['banned_licenses'])
    
    violations = []
    
    for pkg in sbom.get('packages', []):
        name = pkg.get('name')
        lic = pkg.get('licenseConcluded') or pkg.get('licenseDeclared')
        
        if lic in banned:
            violations.append(f"CRITICAL: Banned license '{lic}' found in package '{name}'")
        elif lic not in allowed:
            violations.append(f"WARNING: Unapproved license '{lic}' found in package '{name}'")

    print("=== Automated License Compliance Audit Results ===")
    if violations:
        for v in violations:
            print(f"[FAIL] {v}")
        sys.exit(1)
    else:
        print("[PASS] All dependencies comply with Enterprise License Policy.")
        sys.exit(0)

if __name__ == '__main__':
    audit()
EOF

chmod +x check_compliance.py
./check_compliance.py
```

**Salida esperada del comando:**
```text
=== Automated License Compliance Audit Results ===
[PASS] All dependencies comply with Enterprise License Policy.
```

---

#### Preguntas de Verificación — Bloque 3
1. **Q3.1:** ¿Cuál es la distinción crítica entre Apache 2.0 y MIT con respecto a los derechos de patentes y cómo la Cláusula 3 de Apache 2.0 (Patent Grant / Concesión de patentes) protege a los adoptantes empresariales downstream contra litigios de patentes?
2. **Q3.2:** Explicá por qué las licencias de no competencia/disponibilidad de código (source-available) como la Server Side Public License (SSPL) o Business Source License (BSL/BUSL) no cumplen con la conformidad de la OSI, y por qué se categorizan como propietarias/source-available en lugar de Open Source.

---

## Respuestas y Explicaciones Arquitectónicas

<details>
<summary>Hacé clic para desplegar las soluciones y explicaciones detalladas</summary>

### Respuestas del Bloque 1

* **A1.1:**
  * **Explicación arquitectónica:** El Criterio 6 de la OSI exige explícitamente: *"La licencia no debe restringir a nadie el uso del programa en un campo de trabajo específico."* Restringir el alojamiento en la nube comercial, el uso militar, financiero o de investigación viola este principio fundamental. Las licencias open source otorgan derechos universales independientemente de quién sea el usuario o qué modelo operativo o de negocio ejecute. Si se agregan restricciones de campo, la licencia se convierte en una licencia restrictiva o propietaria "source-available", perdiendo su estado de Open Source.

* **A1.2:**
  * **Explicación arquitectónica:** Los encabezados `SPDX-License-Identifier` utilizan cadenas de identificadores cortos estandarizadas (definidas en [https://spdx.org/licenses/](https://spdx.org/licenses/)) incrustadas directamente en los encabezados de los archivos (por ejemplo, `# SPDX-License-Identifier: Apache-2.0`). Esto reemplaza a los bloques de texto libre heredados de varios párrafos que requerían un procesamiento de lenguaje natural (NLP) complejo o un emparejamiento con expresiones regulares difusas (fuzzy regex). Las herramientas automatizadas de SAST/SBOM pueden tokenizar determinísticamente archivos fuente a través de millones de líneas de código con cero ambigüedad.

---

### Respuestas del Bloque 2

* **A2.1:**
  * **Explicación arquitectónica:**
    1. **Escenario GPL-v3.0:** Bajo `GPL-v3.0`, el disparador de distribución de copyleft está definido por la *distribución* física del código binario o fuente a terceros. Interactuar con software que se ejecuta en un servidor a través de una red (SaaS) **no** constituye distribución. Por lo tanto, la empresa no tiene obligación de liberar su código de backend o front-end.
    2. **Escenario AGPL-3.0-only:** `AGPL-3.0` (GNU Affero General Public License) introduce específicamente la **Sección 13** (Remote Network Interaction). La Sección 13 establece que si ejecutás una versión modificada del programa en un servidor y permitís que los usuarios interactúen con él a través de una red de computadoras, debés ofrecer a esos usuarios acceso al código fuente correspondiente del programa modificado a través de una descarga de red.

* **A2.2:**
  * **Explicación arquitectónica:** La `LGPL-3.0` (Lesser General Public License) permite que las aplicaciones propietarias se enlacen a librerías LGPL sin forzar a que la aplicación anfitriona se convierta en open source, **siempre que** el usuario pueda modificar y reenlazar (relink) el componente de la librería LGPL.
    * Si está **enlazada dinámicamente** (`.so` / `.dylib` / `.dll`), el usuario final simplemente puede intercambiar el archivo de objeto compartido por su librería personalizada.
    * Si está **enlazada estáticamente**, el proveedor de la aplicación está obligado a proporcionar los archivos objeto sin enlazar (`.o`) o el código fuente de la aplicación anfitriona propietaria para que el usuario final pueda reenlazar (relink) manualmente el ejecutable contra una versión modificada de la librería LGPL.

---

### Respuestas del Bloque 3

* **A3.1:**
  * **Explicación arquitectónica:** Aunque la licencia MIT es permisiva y requiere solo la retención del aviso de copyright, no menciona en absoluto los derechos de patentes. `Apache-2.0` incluye una concesión de patentes explícita, irrevocable y mundial (Cláusula 3) de cada colaborador para el usuario. Además, Apache 2.0 incluye una **Cláusula de defensa/terminación de patentes**: si un licenciatario downstream inicia un litigio de patentes contra cualquier colaborador alegando que la contribución infringe sus patentes, cualquier licencia de patente otorgada a ese usuario bajo Apache 2.0 se da por terminada automáticamente. Esto crea un escudo legal defensivo para los ecosistemas empresariales.

* **A3.2:**
  * **Explicación arquitectónica:** Las licencias como SSPL (MongoDB) o BSL (HashiCorp) prohíben a terceros ofrecer el software como un servicio gestionado en la nube comercial (por ejemplo, Database-as-a-Service) en competencia directa con el autor sin comprar un acuerdo comercial. Esto incumple directamente el **Criterio 1 de la OSI** (Free Redistribution) y el **Criterio 6 de la OSI** (No Discrimination Against Fields of Endeavor). Dado que los derechos están condicionados por la protección del modelo de negocio en lugar de la libertad del software, la OSI y la FSF las clasifican strictly como licencias propietarias no libres/source-available.

</details>

---

## Resumen de Puntos Clave para el Examen LPI 050-100

1. **Permissive (MIT, BSD, Apache-2.0):** Requiere una retención mínima de avisos; permite el relicenciamiento propietario de obras derivadas.
2. **Weak Copyleft (LGPL, MPL, EPL):** Protege las modificaciones a nivel de librería/archivo; permite el enlace con software propietario.
3. **Strong Copyleft (GPL):** Obliga a que todo el trabajo combinado se libere bajo GPL al momento de la distribución binaria.
4. **Network Copyleft (AGPL):** Activa la reciprocidad tras la interacción a través de la red (SaaS), cerrando el vacío legal (loophole) de copyleft en SaaS.
5. **SPDX Identifiers:** Cadenas estandarizadas (`SPDX-License-Identifier: <ID>`) utilizadas para el cumplimiento legal legible por máquinas en pipelines de CI/CD.