# Guía de Estudio de Producción Avanzada: LPI 050-100 (Open Source Essentials)
## Tema 2.2: Licencias de Software Copyleft (Peso del Examen: 7.5)

---

### Fundamentos Arquitectónicos y Técnicos

#### 1. El Marco Legal y Mecánico del Copyleft
El copyleft es un mecanismo legal que aprovecha la ley de copyright estándar para garantizar la libertad del software. En lugar de utilizar el copyright para restringir la distribución y la modificación (como en el software propietario), el copyleft utiliza el copyright para exigir que todas las redistribuciones aguas abajo (downstream) y obras derivadas conserven las mismas libertades.

```
+-----------------------------------------------------------------------------------+
|                                 SOFTWARE LICENSES                                 |
+------------------------------------------+----------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
          [ Permissive Licenses ]                       [ Copyleft Licenses ]
          - MIT, Apache-2.0, BSD                        - Reciprocal duty triggered
          - Minimal downstream constraints               upon distribution / service
          - Relicensing allowed                          - Prevents proprietary derivative works
                    |                                             |
                    +                      +----------------------+----------------------+
                                           |                                             |
                                [ Strong / Full Copyleft ]                    [ Weak / Limited Copyleft ]
                                - GPLv2, GPLv3, AGPLv3                        - LGPLv2.1/v3, MPL-2.0, EPL-2.0
                                - Covers entire combined work                 - Scoped to library / file / module
                                - Links (static/dynamic) propagate duty       - Proprietary code can link dynamically
```

#### 2. Taxonomía de Licencias y Matriz de Comparación

| Licencia | Fuerza del Copyleft | Alcance de la Reciprocidad | ¿Vacío Legal de SaaS/Red Abordado? | Cláusula de Licencia de Patentes | Bloqueo de Hardware / Anti-Tivoización |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **GPLv2** | Fuerte | Toda la obra combinada (enlazado estático y dinámico) | No | Implícita (No clara) | No |
| **GPLv3** | Fuerte | Toda la obra combinada (enlazado estático y dinámico) | No | Explícita (§11) | Sí (§6 Información de Instalación) |
| **AGPLv3** | La más fuerte | Toda la obra combinada + Servicios accesibles por red | Sí (§13) | Explícita (§11) | Sí (§6 Información de Instalación) |
| **LGPLv3** | Débil | Binarios de biblioteca (Permite enlazado dinámico con código propietario) | No | Explícita (§11) | Sí (§6 Información de Instalación) |
| **MPL-2.0** | Débil (A nivel de archivo) | Archivos existentes modificados bajo MPL | No | Explícita (§3) | No |
| **EPL-2.0** | Débil (A nivel de módulo)| Módulos/archivos EPL modificados | No | Explícita (§2) | No |
| **Apache-2.0**| Permisiva | Ninguno | No | Explícita (§3) | No |

---

### Mecánicas Técnicas Profundas y Compromisos Legales

#### A. Obras Combinadas vs. Procesos Aislados (Dinámica de Enlazado)
De acuerdo con la interpretación de la Free Software Foundation (FSF):
1. **Enlazado Estático (`.a` / `.lib`)**: El compilador combina el código objeto copyleft dentro del binario principal. El ejecutable final es indiscutiblemente una única obra combinada sujeta a la licencia copyleft.
2. **Enlazado Dinámico (`.so` / `.dll`)**: Los símbolos se resuelven en tiempo de ejecución. La FSF afirma que los espacios de direcciones de memoria compartida crean una única obra combinada. Las aplicaciones aguas abajo que se enlazan dinámicamente con una biblioteca GPL deben publicarse bajo una licencia compatible con GPL.
3. **IPC / Microservicios (Límite de Proceso)**: Los sistemas que interactúan estrictamente a través de sockets de red (HTTP/gRPC) o sockets de dominio UNIX mediante esquemas REST/RPC bien definidos, sin compartir memoria ni estructuras internas, mantienen límites de copyright independientes bajo GPL estándar.

#### B. El Vacío Legal de SaaS y AGPLv3 §13
GPLv2 y GPLv3 estándar activan las obligaciones de liberación del código fuente **únicamente tras la distribución** (transmisión) de binarios a terceros. Si una organización aloja software GPL modificado en un entorno cloud (Software-as-a-Service) y expone sus endpoints sobre HTTP sin entregar binarios a los clientes, no ocurre ninguna "distribución".

**AGPLv3 Sección 13** cierra este vacío legal:
> *"If you modify the Program, your modified version must prominently offer to all users interacting with it remotely through a computer network [...] an opportunity to receive the Corresponding Source of your version..."*

#### C. Anti-Tivoización y DRM (GPLv2 vs. GPLv3)
La tivoización ocurre cuando los proveedores de hardware ejecutan software con licencia GPL (por ejemplo, el kernel Linux) en dispositivos de consumo, pero aplican verificaciones de claves de hardware que bloquean la ejecución si el usuario carga binarios de software modificados.
- **GPLv2 §3**: Requiere proporcionar el código fuente, pero no exige explícitamente las claves privadas de firma requeridas por los gestores de arranque (bootloaders) de hardware.
- **GPLv3 §6**: Exige la provisión de **Información de Instalación**—todas las claves, códigos de autorización y métodos de verificación necesarios para instalar y ejecutar versiones modificadas del software en el hardware objetivo.

#### D. Matriz de Compatibilidad de Licencias
La compatibilidad de licencias determina si el código bajo la Licencia A se puede combinar en un único binario con código bajo la Licencia B.

```
       +-------------------------------------------------------------+
       | Downstream Target License (Combined Binary)                 |
       +--------------------+-------------------+--------------------+
Source | GPLv2-only         | GPLv3             | Apache-2.0         |
-------+--------------------+-------------------+--------------------+
GPLv2  | Compatible         | Incompatible*     | Incompatible       |
GPLv3  | Incompatible       | Compatible        | Compatible (v3->v2)|
Apache | Incompatible       | Compatible (§11)  | Compatible         |
AGPLv3 | Incompatible       | Compatible (§13)  | Incompatible       |
+------+--------------------+-------------------+--------------------+
*Note: GPLv2 code containing the "or (at your option) any later version" clause 
 (GPLv2+) can be re-licensed under GPLv3 to allow Apache-2.0 integration.
```

---

### Ejercicios de Laboratorio Guiados de Producción

#### Ejercicio 1: Análisis de Binarios y Enlazadores a Bajo Nivel para Auditoría de Límites de Copyleft

##### Objetivo
Analizar archivos objeto ejecutables y bibliotecas compartidas utilizando las utilidades de binarios de GNU (`gcc`, `readelf`, `ldd`, `nm`) para determinar si una aplicación compilada se enlaza dinámica o estáticamente con una biblioteca de copyleft fuerte (GPL) en comparación con una biblioteca de copyleft débil (LGPL).

##### Pasos a Ejecutar

1. Preparar un espacio de trabajo aislado y construir una biblioteca simulada con licencia GPL (`libgpl.c` / `libgpl.h`) y una aplicación central propietaria (`app.c`):

```bash
mkdir -p ~/license-audit-lab/ex1 && cd ~/license-audit-lab/ex1

cat << 'EOF' > libgpl.h
#ifndef LIBGPL_H
#define LIBGPL_H
void gpl_licensed_function(void);
#endif
EOF

cat << 'EOF' > libgpl.c
#include <stdio.h>
#include "libgpl.h"

void gpl_licensed_function(void) {
    printf("[GPL CORE] Executing strong copyleft algorithm v1.0\n");
}
EOF

cat << 'EOF' > app.c
#include <stdio.h>
#include "libgpl.h"

int main(void) {
    printf("[APP CORE] Running proprietary control plane...\n");
    gpl_licensed_function();
    return 0;
}
EOF
```

2. Compilar el componente GPL tanto en un archivo estático (`libgpl.a`) como en una biblioteca compartida (`libgpl.so`):

```bash
# Compile object file
gcc -c -fPIC libgpl.c -o libgpl.o

# Create static archive (.a)
ar rcs libgpl.a libgpl.o

# Create shared library (.so)
gcc -shared -o libgpl.so libgpl.o
```

3. Construir dos binarios: `app_static` (enlazado estáticamente) y `app_dynamic` (enlazado dinámicamente):

```bash
# Static compilation
gcc app.c -L. libgpl.a -o app_static

# Dynamic compilation
gcc app.c -L. -lgpl -Wl,-rpath,'$ORIGIN' -o app_dynamic
```

4. Auditar las dependencias de bibliotecas compartidas utilizando `ldd`:

```bash
ldd app_static
ldd app_dynamic
```

*Salida Esperada (`ldd app_static`):*
```text
	statically linked
```

*Salida Esperada (`ldd app_dynamic`):*
```text
	linux-vdso.so.1 (0x00007ffd395f2000)
	libgpl.so => ./libgpl.so (0x00007f3b8a1c0000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f3b89f00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f3b8a1c8000)
```

5. Realizar la inspección de la tabla de símbolos ELF usando `readelf` y `nm` para probar la absorción de símbolos:

```bash
nm -g app_static | grep gpl_licensed_function
nm -g app_dynamic | grep gpl_licensed_function
```

*Salida Esperada (`nm app_static`):*
```text
0000000000001159 T gpl_licensed_function
```

*Salida Esperada (`nm app_dynamic`):*
```text
                 U gpl_licensed_function
```

##### Preguntas de Verificación

**Q1.1**: En `app_static`, el símbolo `gpl_licensed_function` muestra el estado `T` (sección Text), mientras que en `app_dynamic` muestra el estado `U` (símbolo no definido resuelto en tiempo de ejecución). Desde la perspectiva de la ingeniería SRE/Legal, ¿por qué la absorción del enlazado estático (`T`) representa una obra combinada única e indiscutible bajo GPLv2/GPLv3 §5, eliminando cualquier defensa legal de enlazado dinámico?

**Q1.2**: Si `libgpl` estuviera bajo la licencia LGPLv2.1 en lugar de GPLv2, ¿qué requisito debe satisfacer el desarrollador si distribuye `app_static` a los usuarios finales sin liberar el código fuente de `app.c`?

---

#### Ejercicio 2: Análisis Automatizado de SBOM de Contenedores y Aplicación de Cumplimiento en CI

##### Objetivo
Configurar un escáner automatizado de lista de materiales de software (SBOM - Software Bill of Materials) utilizando `syft` de Anchore y `trivy` de Aqua para auditar capas del sistema de archivos de contenedores en busca de paquetes de copyleft fuerte de alto riesgo (AGPLv3/GPLv3) dentro de artefactos de despliegue empresarial.

##### Pasos a Ejecutar

1. Navegar al espacio de trabajo del ejercicio y crear un proyecto Node.js simulado que contenga dependencias mixtas (Permisivas, Copyleft Débil y Copyleft AGPL):

```bash
mkdir -p ~/license-audit-lab/ex2 && cd ~/license-audit-lab/ex2

cat << 'EOF' > package.json
{
  "name": "microservice-api",
  "version": "2.4.0",
  "private": true,
  "dependencies": {
    "express": "^4.18.2",
    "agpl-pdf-generator": "1.0.0",
    "lgpl-string-utils": "2.1.0"
  }
}
EOF

mkdir -p node_modules/express node_modules/agpl-pdf-generator node_modules/lgpl-string-utils

# Mock Express (MIT)
cat << 'EOF' > node_modules/express/package.json
{ "name": "express", "version": "4.18.2", "license": "MIT" }
EOF

# Mock AGPL PDF Generator (AGPL-3.0-only)
cat << 'EOF' > node_modules/agpl-pdf-generator/package.json
{ "name": "agpl-pdf-generator", "version": "1.0.0", "license": "AGPL-3.0-only" }
EOF

# Mock LGPL String Utils (LGPL-3.0-or-later)
cat << 'EOF' > node_modules/lgpl-string-utils/package.json
{ "name": "lgpl-string-utils", "version": "2.1.0", "license": "LGPL-3.0-or-later" }
EOF
```

2. Construir una imagen de contenedor de producción utilizando Docker/Podman o un manifiesto Dockerfile:

```bash
cat << 'EOF' > Dockerfile
FROM alpine:3.19
RUN apk add --no-linux-headers --no-cache bash curl
WORKDIR /app
COPY package.json ./
COPY node_modules ./node_modules
CMD ["node", "server.js"]
EOF
```

3. Construir la imagen del contenedor localmente:

```bash
docker build -t microservice-api:2.4.0 .
```

4. Instalar `syft` (o utilizar una ejecución local de binario/contenedor) para generar un SBOM JSON SPDX estandarizado:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /tmp/bin v1.0.0
/tmp/bin/syft microservice-api:2.4.0 -o spdx-json=sbom.spdx.json
```

5. Auditar el documento SPDX generado en busca de licencias AGPL utilizando `jq`:

```bash
jq '.packages[] | select(.licenseConcluded | contains("AGPL")) | {name: .name, versionInfo: .versionInfo, licenseConcluded: .licenseConcluded}' sbom.spdx.json
```

*Salida Esperada:*
```json
{
  "name": "agpl-pdf-generator",
  "versionInfo": "1.0.0",
  "licenseConcluded": "AGPL-3.0-only"
}
```

6. Formular una configuración de cumplimiento de licencias de Trivy (`.trivyignore` o invocación de política de Trivy) para romper los pipelines de CI/CD si hay licencias AGPL-3.0 presentes:

```bash
cat << 'EOF' > trivy-license-policy.yaml
license:
  severities:
    - CRITICAL
  forbidden:
    - AGPL-1.0-only
    - AGPL-1.0-or-later
    - AGPL-3.0-only
    - AGPL-3.0-or-later
    - GPL-3.0-only
    - GPL-3.0-or-later
EOF

trivy image --config trivy-license-policy.yaml --scanners license microservice-api:2.4.0
```

*Salida de CLI Esperada:*
```text
2026-08-06T19:04:00.000Z	[INFO] License scanning is enabled
2026-08-06T19:04:00.120Z	[WARN] Number of language-specific files: 1

node_modules/agpl-pdf-generator (Node.js)
==========================================
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

CRITICAL: AGPL-3.0-only license found in agpl-pdf-generator@1.0.0
Classification: Forbidden License Category (AGPL-3.0)
Action Required: Remove dependency or isolate behind process network boundary.
```

##### Preguntas de Verificación

**Q2.1**: Un servicio backend de SaaS importa dinámicamente `agpl-pdf-generator` dentro de su proceso de contenedor Node.js para renderizar facturas. El contenedor nunca se distribuye a los clientes, pero se expone a través de API HTTP. ¿Por qué este despliegue activa una violación legal bajo AGPLv3 §13, mientras que la GPLv3 §13 estándar permanecería sin activarse en exactamente el mismo modo de despliegue en la nube?

**Q2.2**: Si el equipo de SRE reescribe la integración de `agpl-pdf-generator` en un microservicio separado e aislado que se ejecuta en su propio Pod de Kubernetes, expuesto strictly a través de gRPC sobre TCP, ¿el servicio principal de la API de Node.js hereda la obligación de divulgación del código fuente de AGPLv3? Explique la justificación arquitectónica.

---

#### Ejercicio 3: Auditoría de Aislamiento de Copyleft a Nivel de Archivo vs. Copyleft Fuerte (MPL-2.0 / EPL-2.0)

##### Objetivo
Demostrar la diferencia operativa entre el Copyleft a Nivel de Archivo (Débil) (MPL-2.0) y el Copyleft Fuerte (GPLv3) al modificar archivos de código fuente open-source upstream junto con archivos de proyectos propietarios.

##### Pasos a Ejecutar

1. Configurar la estructura de directorios del ejercicio:

```bash
mkdir -p ~/license-audit-lab/ex3 && cd ~/license-audit-lab/ex3
```

2. Crear un archivo upstream modificado bajo la Licencia Pública de Mozilla 2.0 (`mpl_utility.go`):

```bash
cat << 'EOF' > mpl_utility.go
// Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

package main

import "fmt"

// Modified Upstream Function
func MPLOptimizedBuffer() {
    fmt.Println("[MPL-2.0] High performance ring buffer v2")
}
EOF
```

3. Crear un archivo de aplicación propietaria en el mismo paquete/directorio (`proprietary_logic.go`):

```bash
cat << 'EOF' > proprietary_logic.go
// Copyright 2026 Enterprise Corp. All Rights Reserved.
// Proprietary and Confidential.

package main

import "fmt"

func ExecuteTradeEngine() {
    fmt.Println("[PROPRIETARY] Executing algorithmic trading strategy...")
    MPLOptimizedBuffer()
}

func main() {
    ExecuteTradeEngine()
}
EOF
```

4. Construir el binario y generar distribuciones de paquetes de código fuente:

```bash
go build -o trading_engine .
./trading_engine
```

*Salida Esperada:*
```text
[PROPRIETARY] Executing algorithmic trading strategy...
[MPL-2.0] High performance ring buffer v2
```

##### Preguntas de Verificación

**Q3.1**: Bajo las Secciones 3.1 y 3.2 de MPL-2.0, si Enterprise Corp distribuye el binario compilado `trading_engine` a clientes terceros, ¿qué archivos específicos deben ponerse a disposición del público bajo los términos de la licencia MPL-2.0?

**Q3.2**: Si `mpl_utility.go` estuviera licenciado bajo GPLv3, ¿cómo cambiaría la obligación de divulgación del código fuente con respecto a `proprietary_logic.go` tras la distribución de `trading_engine`?

---

#### Ejercicio 4: Validación de Identificadores de Licencia SPDX y Linters de Cumplimiento

##### Objetivo
Auditar, hacer cumplir y validar identificadores cortos estandarizados de Software Package Data Exchange (SPDX) en declaraciones de encabezados de código fuente multilenguaje utilizando la herramienta de cumplimiento `reuse`.

##### Pasos a Ejecutar

1. Instalar la herramienta `reuse` de la Free Software Foundation Europe en un entorno virtual:

```bash
mkdir -p ~/license-audit-lab/ex4 && cd ~/license-audit-lab/ex4
python3 -m venv venv
./venv/bin/pip install reuse
```

2. Crear archivos fuente conformes y no conformes:

```bash
# File A: Valid SPDX GPL-3.0 Header
cat << 'EOF' > compliant_gpl.py
# SPDX-FileCopyrightText: 2026 SRE Platform Team <sre@example.com>
# SPDX-License-Identifier: GPL-3.0-or-later

def engine_init():
    print("GPL Engine Ready")
EOF

# File B: Non-compliant missing copyright/license file
cat << 'EOF' > non_compliant.py
def orphan_function():
    pass
EOF
```

3. Ejecutar `reuse lint` para inspeccionar el cumplimiento del proyecto:

```bash
./venv/bin/reuse lint
```

*Salida Esperada:*
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: GPL-3.0-or-later
* Files with copyright information: 1 / 2
* Files with license information: 1 / 2

FAIL: The project is not REUSE compliant.
Missing information for:
- non_compliant.py
```

4. Resolver el fallo de cumplimiento agregando un encabezado SPDX explícito usando `reuse annotate`:

```bash
./venv/bin/reuse annotate --license GPL-3.0-or-later --copyright "2026 SRE Platform Team <sre@example.com>" non_compliant.py
./venv/bin/reuse lint
```

*Salida Esperada:*
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: GPL-3.0-or-later
* Files with copyright information: 2 / 2
* Files with license information: 2 / 2

Congratulations! Your project is compliant with the REUSE specification :D
```

##### Preguntas de Verificación

**Q4.1**: ¿Cuál es la diferencia semántica precisa entre `GPL-3.0-only` y `GPL-3.0-or-later` según el esquema oficial de la lista de licencias SPDX?

**Q4.2**: ¿Por qué el uso de identificadores SPDX estandarizados dentro de los encabezados del código fuente es crítico para las herramientas automatizadas de SBOM (`syft`, `trivy`, `fossology`) en los pipelines modernos de DevSecOps empresarial?

---

### Fuentes Oficiales de Referencia
- Linux Professional Institute Open Source Essentials: https://www.lpi.org/our-certifications/open-source-essentials-overview/
- Texto y preguntas frecuentes de GNU General Public License v3.0: https://www.gnu.org/licenses/gpl-3.0.html
- GNU Affero General Public License v3.0: https://www.gnu.org/licenses/agpl-3.0.html
- Licencias de Open Source Initiative (OSI): https://opensource.org/licenses
- Lista de Licencias y Especificación SPDX: https://spdx.dev/learn/handling-license-info/
- Especificación REUSE (FSFE): https://reuse.software/spec/

---

<details>
<summary>Respuestas y Explicaciones Diagnósticas</summary>

#### Respuesta a Q1.1
El enlazado estático combina las instrucciones de máquina compiladas de `libgpl.a` directamente en el segmento de texto (`T`) de `app_static`. El ejecutable no puede funcionar sin este código incrustado en su imagen binaria. Bajo la Sección 2 de GPLv2 y la Sección 5 de GPLv3, esto crea una obra combinada indiscutible. La distribución de `app_static` activa la obligación completa de copyleft: el código fuente de `app.c` debe ser divulgado bajo GPL. En el enlazado dinámico, los defensores a veces argumentan que el binario en disco es distinto hasta el tiempo de ejecución; sin embargo, con el enlazado estático, el artefacto binario físico contiene ambas partes fusionadas, destruyendo cualquier defensa de separación legal.

#### Respuesta a Q1.2
La Sección 6 de LGPLv2.1 permite el enlazado estático con código propietario (`app.c`), siempre que el proveedor distribuya los archivos objeto no enlazados (`app.o`) o el código fuente completo de `app.c` junto con la biblioteca estática (`libgpl.a`). Esto permite a los usuarios aguas abajo modificar `libgpl` y volver a enlazar el binario manualmente. Alternativamente, si se utiliza enlazado dinámico (`.so`) bajo LGPL, no se requiere que el proveedor proporcione los archivos objeto de `app.c` en absoluto.

#### Respuesta a Q2.1
La obligación de la GPLv3 §13 estándar se activa **únicamente cuando el programa es transmitido (distribuido)**. Debido a que el contenedor se ejecuta en un centro de datos en la nube y solo expone endpoints de red HTTP, no tiene lugar ninguna transmisión de binarios de software bajo GPLv3. En contraste, la Sección 13 de AGPLv3 define explícitamente la interacción remota a través de una red de computadoras como una condición de activación. Ejecutar software AGPLv3 modificado en un servidor de red requiere poner el código fuente correspondiente completo a disposición de todos los usuarios remotos que interactúen con dicho servicio a través de HTTP/gRPC para su descarga.

#### Respuesta a Q2.2
No, el servicio principal de la API de Node.js no hereda la obligación de copyleft de AGPLv3. Operar a través de sockets de red (gRPC/HTTP) entre procesos desacoplados del sistema operativo establece un límite de proceso. Como la API de Node.js y el servicio AGPL interactúan como programas independientes mediante llamadas a procedimientos remotos estándar—sin compartir espacio de direcciones de memoria, esquemas de base de datos ni estructuras de datos internas—no forman una única obra combinada bajo la interpretación legal del copyleft. Solo el microservicio AGPL aislado debe poner su código fuente a disposición.

#### Respuesta a Q3.1
Bajo las Secciones 3.1 y 3.2 de MPL-2.0, la reciprocidad del copyleft está estrictamente **delimitada a nivel de archivo**. Enterprise Corp debe divulgar públicamente las modificaciones realizadas en `mpl_utility.go` bajo los términos de la licencia MPL-2.0. Sin embargo, `proprietary_logic.go` es un archivo independiente y no es una modificación del código MPL; por lo tanto, permanece completamente propietario y su código fuente no necesita ser divulgado.

#### Respuesta a Q3.2
Si `mpl_utility.go` estuviera licenciado bajo GPLv3, compilar `mpl_utility.go` y `proprietary_logic.go` en un solo binario de Go crea una única obra combinada. El copyleft fuerte de GPLv3 se propaga a través de todos los archivos dentro de la unidad de compilación del binario. Como resultado, Enterprise Corp estaría legalmente obligada a publicar `proprietary_logic.go` bajo GPLv3 al distribuir `trading_engine`.

#### Respuesta a Q4.1
`GPL-3.0-only` restringe a los usuarios aguas abajo a los términos de la Versión 3.0 de GPL exclusivamente. `GPL-3.0-or-later` otorga a los usuarios aguas abajo la opción legal de aplicar los términos de cualquier versión futura de la Licencia Pública General de GNU publicada por la Free Software Foundation (por ejemplo, GPLv4). `GPL-3.0-or-later` mejora la compatibilidad de licencias a largo plazo con revisiones futuras del copyleft.

#### Respuesta a Q4.2
Las herramientas automatizadas de análisis de SBOM dependen de la lectura determinista de encabezados de código fuente y metadatos de paquetes. Los textos arbitrarios o ausentes fuerzan a las herramientas a depender de heurísticas pesadas de procesamiento de lenguaje natural (NLP), las cuales generan con frecuencia falsos positivos o falsos negativos durante las verificaciones de cumplimiento en CI. Los identificadores cortos SPDX estandarizados (`SPDX-License-Identifier: <ID>`) permiten a los escáneres resolver de forma instantánea claves precisas e inequívocas legibles por máquina, permitiendo que las puertas de enlace automatizadas en los pipelines apliquen con precisión las políticas de licencias empresariales.

</details>