# LPI Open Source Essentials (Exam 050-100) — Topic 1.1: Software Components
**Exam Topic Weight:** 5  
**Target Role:** Senior SRE / Platform Architect  
**Official Reference:** [Linux Professional Institute — Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## Visión General Técnica y Análisis Arquitectónico Profundo

Los componentes de software forman los bloques de construcción fundamentales de las distribuciones Linux modernas y de los entornos de ejecución cloud-native. Comprender cómo el software se transforma desde código fuente legible por humanos hasta formatos binarios ejecutables, cómo las librerías compartidas se vinculan dinámicamente en tiempo de ejecución, cómo los sistemas de paquetes gestionan los grafos de dependencias y cómo las restricciones de licenciamiento impactan en la arquitectura de la cadena de suministro es vital para los SRE y Platform Engineers.

```
+-----------------------------------------------------------------------------------+
|                               SOURCE CODE (.c / .h)                               |
+-----------------------------------------------------------------------------------+
                                          |
                                          v  [ Preprocessor & Compiler: gcc -S ]
+-----------------------------------------------------------------------------------+
|                               ASSEMBLY CODE (.s)                                  |
+-----------------------------------------------------------------------------------+
                                          |
                                          v  [ Assembler: gcc -c ]
+-----------------------------------------------------------------------------------+
|                         RELOCATABLE OBJECT FILE (.o)                              |
+-----------------------------------------------------------------------------------+
                      /                                      \
                     /                                        \
   [ Static Archiver: ar rcs ]                  [ Dynamic Linker: gcc -shared -fPIC ]
                    v                                          v
+----------------------------------------+   +--------------------------------------+
|       STATIC LIBRARY (.a archive)      |   |       SHARED OBJECT (.so library)    |
+----------------------------------------+   +--------------------------------------+
                    \                                          /
                     \                                        /
                      v  [ Linker: ld / gcc ]                v  [ Dynamic Linker: ld-linux.so ]
+-----------------------------------------------------------------------------------+
|                           EXECUTABLE BINARY (ELF Format)                          |
|  +-------------------+  +-------------------+  +-------------------------------+  |
|  | GOT (Global Offset|  | PLT (Procedure    |  | .text / .data / .rodata       |  |
|  | Table)            |  | Linkage Table)    |  | Sections                      |  |
|  +-------------------+  +-------------------+  +-------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Conceptos Arquitectónicos Clave

1. **Pipeline de Compilación**:
   - **Preprocesamiento (`cpp`)**: Expande macros (`#define`), resuelve includes (`#include`), elimina comentarios.
   - **Compilación (`cc1`)**: Traduce código de alto nivel a lenguaje ensamblador.
   - **Ensamblado (`as`)**: Convierte ensamblador a código máquina relocalizable (Object File `.o`).
   - **Enlazado (`ld`)**: Combina archivos objeto, resuelve referencias a símbolos externos, construye tablas GOT/PLT, genera el binario final en formato ELF (Executable and Linkable Format).

2. **Mecanismos de Enlazado y Compromisos (Trade-offs)**:
   - **Static Linking (`.a`)**: Copia el código objeto directamente en el binario objetivo en tiempo de compilación.
     - *Pros*: Autocontenido, cero dependencias de librerías de tiempo de ejecución externas, inmune a fallos por rotura de librerías en tiempo de ejecución ("DLL Hell").
     - *Contras*: Mayor tamaño de binario, mayor consumo de memoria (sin compartición de memoria entre procesos), requiere una recompilación completa para aplicar parches de CVEs en dependencias de terceros.
   - **Dynamic Linking (`.so`)**: Almacena referencias a símbolos; el cargador dinámico (`ld-linux.so`) mapea páginas compartidas en el espacio de memoria durante el arranque.
     - *Pros*: Eficiente en memoria mediante páginas `.text` de solo lectura compartidas, parcheo en un solo punto para vulnerabilidades de seguridad.
     - *Contras*: Latencia en tiempo de ejecución durante la búsqueda inicial de símbolos, vulnerabilidad en tiempo de ejecución ante versiones de librerías faltantes o incompatibles.

3. **Internos de ELF y Resolución de Símbolos**:
   - **PLT (Procedure Linkage Table)** & **GOT (Global Offset Table)**: Facilitan el Código Independiente de la Posición (PIC). La GOT almacena direcciones absolutas de datos globales y funciones, mientras que la PLT proporciona trampolines stub que invocan la vinculación diferida (lazy binding) de `ld-linux.so` en la primera llamada.
   - **RPATH vs RUNPATH**: Rutas de búsqueda de librerías codificadas directamente (hardcoded) embebidas en el encabezado ELF (`DT_RPATH` / `DT_RUNPATH`). `DT_RPATH` tiene prioridad sobre `LD_LIBRARY_PATH`, mientras que `DT_RUNPATH` puede ser sobrescrito por `LD_LIBRARY_PATH`.

4. **Mecánica de Gestión de Paquetes**:
   - Los componentes de software se distribuyen mediante archivos comprimidos que contienen payloads binarios, metadatos, scripts de mantenedores (`preinst`, `postinst`, `prerm`, `postrm`) y especificaciones de dependencias (`Depends`, `Provides`, `Recommends`).
   - Los gestores de paquetes (`dpkg`/`apt` en Debian/Ubuntu, `rpm`/`dnf` en RHEL/Fedora) mantienen una base de datos de estado local para validar la propiedad de archivos, árboles de dependencias e integridad de transacciones.

---

## Ejercicios Prácticos Guiados

### Ejercicio 1: Compilación, Archivados y Diagnóstico de Enlazado Dinámico

En este ejercicio, crearás una librería C modular personalizada, construirás versiones estáticas (`.a`) y compartidas (`.so`), compilarás ejecutables contra ambas y utilizarás herramientas de análisis binario de bajo nivel para inspeccionar tablas de símbolos y estructuras de segmentos.

#### Paso 1: Crear la Estructura de Código Fuente
Crea un directorio de trabajo `/tmp/sre_lab` y construye los archivos fuente para un componente de cálculo simple (`calculator.c`, `calculator.h`) y una aplicación llamadora (`main.c`).

```bash
mkdir -p /tmp/sre_lab && cd /tmp/sre_lab

cat <<'EOF' > calculator.h
#ifndef CALCULATOR_H
#define CALCULATOR_H

int add_metrics(int val1, int val2);
int multiply_metrics(int val1, int val2);

#endif
EOF

cat <<'EOF' > calculator.c
#include "calculator.h"

int add_metrics(int val1, int val2) {
    return val1 + val2;
}

int multiply_metrics(int val1, int val2) {
    return val1 * val2;
}
EOF

cat <<'EOF' > main.c
#include <stdio.h>
#include "calculator.h"

int main() {
    int count = add_metrics(1024, 2048);
    int throughput = multiply_metrics(count, 2);
    printf("[SYSTEM STATUS] Processed Count: %d | Throughput: %d\n", count, throughput);
    return 0;
}
EOF
```

#### Paso 2: Construir una Librería Estática (`.a`) y un Binario Enlazado Estáticamente
Compila `calculator.c` a un archivo objeto, archívalo en `libcalculator.a` y enlaza `main.c` contra él.

```bash
gcc -c calculator.c -o calculator.o
ar rcs libcalculator.a calculator.o
gcc main.c -L. -lcalculator -o app_static
```

Verifica las propiedades del binario y su ejecución:
```bash
./app_static
ls -lh app_static libcalculator.a
```
*Salida Esperada:*
```text
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
-rwxr-xr-x 1 root root 16K Aug  6 18:50 app_static
-rw-r--r-- 1 root root 1.7K Aug  6 18:50 libcalculator.a
```

#### Paso 3: Construir un Objeto Compartido (`.so`) con Código Independiente de la Posición (PIC)
Compila `calculator.c` con `-fPIC` para permitir la ejecución en memoria relocalizable, compila el objeto compartido y enlaza `main.c` dinámicamente.

```bash
gcc -c -fPIC calculator.c -o calculator_pic.o
gcc -shared calculator_pic.o -o libcalculator.so
gcc main.c -L. -lcalculator -o app_dynamic
```

#### Paso 4: Diagnosticar Errores del Cargador Dinámico y Resolver Rutas de Librerías
Intenta ejecutar `./app_dynamic` directamente:
```bash
./app_dynamic
```
*Salida Esperada:*
```text
./app_dynamic: error while loading shared libraries: libcalculator.so: cannot open shared object file: No such file or directory
```

Analiza las dependencias faltantes usando `ldd`:
```bash
ldd app_dynamic
```
*Salida Esperada:*
```text
	linux-vdso.so.1 (0x00007ffe015b7000)
	libcalculator.so => not found
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f311c000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f311c27e000)
```

Suministra temporalmente la ruta de búsqueda de librerías mediante una variable de entorno y ejecuta:
```bash
LD_LIBRARY_PATH=. ./app_dynamic
```
*Salida Esperada:*
```text
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
```

#### Paso 5: Inspeccionar las Tablas de Símbolos del Binario y los Encabezados ELF
Inspecciona los símbolos dinámicos dentro de `app_dynamic` vs `app_static` usando `nm` y `readelf`.

```bash
nm -D app_dynamic | grep _metrics
readelf -d app_dynamic | grep NEEDED
```
*Salida Esperada:*
```text
                 U add_metrics
                 U multiply_metrics
 0x0000000000000001 (NEEDED)             Shared library: [libcalculator.so]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
```

---

### Preguntas de Verificación — Ejercicio 1

1. **Pregunta 1.1**: ¿Por qué `nm -D app_dynamic` listó `add_metrics` con el tipo de símbolo `U` (Undefined), mientras que `app_static` incluye el código del símbolo compilado directamente dentro de su segmento `.text`?
2. **Pregunta 1.2**: ¿Qué riesgo de seguridad o desafío de mantenimiento surge al desplegar binarios enlazados estáticamente que contienen dependencias centrales como `openssl` o `glibc` en pods de Kubernetes en producción?

---

### Ejercicio 2: Interposición Avanzada de Símbolos, Embebido de RPATH y Parcheo en Tiempo de Ejecución

En operaciones de plataforma, es posible que necesites sobrescribir funciones de librerías compartidas dinámicamente para depuración o embeber rutas de búsqueda dinámicas (`RUNPATH`) directamente dentro de binarios ELF durante las pipelines de construcción.

#### Paso 1: Embeber `RUNPATH` para Eliminar los Requerimientos Externos de `LD_LIBRARY_PATH`
Vuelve a enlazar `app_dynamic` embebiendo un `$ORIGIN` absoluto o una etiqueta `RUNPATH` basada en ruta dentro del encabezado ELF utilizando `gcc -Wl,-rpath`.

```bash
gcc main.c -L. -lcalculator -Wl,-rpath,'$ORIGIN' -o app_rpath
ldd app_rpath
./app_rpath
```
*Salida Esperada:*
```text
	linux-vdso.so.1 (0x00007ffe67351000)
	libcalculator.so => ./libcalculator.so (0x00007f45a2c14000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f45a2a00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f45a2c1b000)
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
```

Verifica los detalles del encabezado embebido utilizando `readelf`:
```bash
readelf -d app_rpath | grep -E 'RUNPATH|RPATH'
```
*Salida Esperada:*
```text
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
```

#### Paso 2: Interposición de Funciones en Tiempo de Ejecución usando `LD_PRELOAD`
Construye una librería de diagnóstico (`hook.c`) para interceptar llamadas a `add_metrics` sin modificar ni recompilar `app_rpath` ni `libcalculator.so`.

```bash
cat <<'EOF' > hook.c
#include <stdio.h>

int add_metrics(int val1, int val2) {
    printf("[SRE HOOK TRACE] Intercepted add_metrics(%d, %d)\n", val1, val2);
    return (val1 + val2) + 10000; // Inject modified return payload
}
EOF

gcc -c -fPIC hook.c -o hook.o
gcc -shared hook.o -o libhook.so
```

Ejecuta el binario precargando `libhook.so`:
```bash
LD_PRELOAD=./libhook.so ./app_rpath
```
*Salida Esperada:*
```text
[SRE HOOK TRACE] Intercepted add_metrics(1024, 2048)
[SYSTEM STATUS] Processed Count: 13072 | Throughput: 26144
```

---

### Preguntas de Verificación — Ejercicio 2

1. **Pregunta 2.1**: ¿Cuál es la jerarquía de precedencia de búsqueda utilizada por `ld-linux.so` al resolver referencias a objetos compartidos durante la ejecución de binarios ELF? Clasifica: `LD_LIBRARY_PATH`, `DT_RPATH`, `DT_RUNPATH`, `/etc/ld.so.cache`.
2. **Pregunta 2.2**: ¿Por qué `LD_PRELOAD` está comúnmente deshabilitado por los controles de seguridad del kernel de Linux para binarios que se ejecutan con los flags `setuid` / `setgid`?

---

### Ejercicio 3: Inspección de Componentes de Gestión de Paquetes de Linux y Análisis del Árbol de Dependencias

Los gestores de paquetes encapsulan binarios compilados, objetos estáticos/compartidos, archivos de configuración y hooks de scripts en archivos distribuibles individuales (`.deb` / `.rpm`). En este ejercicio, inspeccionarás bases de datos de paquetes del sistema, analizarás árboles de dependencias y extraerás contenidos de paquetes manualmente.

#### Paso 1: Consultar Paquetes del Sistema y Propiedad de Archivos
Identifica qué paquete es propietario de una librería compartida específica en un entorno Debian/Ubuntu o RHEL/CentOS.

Para un sistema Debian/Ubuntu:
```bash
dpkg -S /lib/x86_64-linux-gnu/libc.so.6
```
*Salida Esperada:*
```text
libc6:amd64: /lib/x86_64-linux-gnu/libc.so.6
```

Inspecciona metadatos de control detallados para `libc6`:
```bash
dpkg -s libc6 | grep -E 'Package|Version|Architecture|Status|Depends'
```
*Salida Esperada:*
```text
Package: libc6
Status: install ok installed
Architecture: amd64
Version: 2.35-0ubuntu3.8
Depends: libgcc-s1, cryptsetup
```

#### Paso 2: Desempaquetar y Auditar el Payload Manual de un Componente `.deb`
Descarga un paquete de utilidad de bajo nivel (`curl`), inspecciona su estructura de archivo y extrae manualmente los metadatos de control sin ejecutar scripts de mantenedores.

```bash
cd /tmp/sre_lab
apt-get download curl
ls -l curl*.deb
```

Extrae los componentes del archivo `.deb` utilizando `ar` (los archivos deb son archivos Ar estándar):
```bash
ar x curl_*.deb
ls -l
```
*Salida Esperada:*
```text
-rw-r--r-- 1 root root      4 Aug  6 18:52 debian-binary
-rw-r--r-- 1 root root  14120 Aug  6 18:52 control.tar.xz
-rw-r--r-- 1 root root 210432 Aug  6 18:52 data.tar.xz
```

Inspecciona los archivos de control del paquete y los scripts de mantenedores posteriores a la instalación:
```bash
tar -xf control.tar.xz
cat control | grep -E 'Package|Depends|Architecture'
```
*Salida Esperada:*
```text
Package: curl
Architecture: amd64
Depends: libc6 (>= 2.34), libcurl4 (= 7.81.0-1ubuntu1.16), zlib1g (>= 1:1.1.4)
```

#### Paso 3: Analizar Cascadas en el Grafo de Dependencias
Analiza las dependencias inversas (qué se rompe si se elimina un componente) utilizando `apt-cache rdepends`.

```bash
apt-cache rdepends --installed libcurl4 | head -n 12
```
*Salida Esperada:*
```text
libcurl4
Reverse Depends:
  curl
  cmake
  git
  python3-pycurl
  systemd-journal-remote
```

---

### Preguntas de Verificación — Ejercicio 3

1. **Pregunta 3.1**: ¿Cuál es el propósito estructural de los miembros `debian-binary`, `control.tar.xz` y `data.tar.xz` dentro de un archivo de componente de software `.deb` estándar?
2. **Pregunta 3.2**: Si un nodo de producción sufre corrupción de dependencias debido a una instalación de paquete interrumpida, ¿cuál es la diferencia arquitectónica entre ejecutar `apt-get install -f` frente a forzar manualmente la sobrescritura de archivos usando `dpkg --force-all`?

---

### Ejercicio 4: Auditoría de Licencias de Código Abierto y Verificación de SBOM

Comprender los modelos de licenciamiento (Permisivo vs Copyleft) y generar manifiestos de Lista de Materiales de Software (SBOM por sus siglas en inglés) son requisitos clave al ensamblar plataformas cloud-native.

#### Paso 1: Categorización de Licencias de Componentes de Software
Analiza los tres arquetipos principales de licenciamiento de código abierto utilizados en componentes de software de Linux empresarial:

| Arquetipo de Licencia | Licencias Representativas | Impacto Arquitectónico / Restricciones |
| :--- | :--- | :--- |
| **Permisivo** | MIT, Apache 2.0, BSD-3-Clause | Otorga permiso completo para modificar, re-licenciar, redistribuir e integrar en bases de código propietarias de código cerrado sin revelar el código fuente modificado. |
| **Weak Copyleft (Copyleft Débil)** | LGPLv2.1 / LGPLv3, MPL 2.0 | Requiere que las modificaciones a la librería *en sí misma* sean publicadas bajo la LGPL. El enlazado dinámico contra una librería LGPL **no** fuerza a la aplicación anfitriona a liberar su código como código abierto. |
| **Strong Copyleft (Copyleft Fuerte)** | GPLv2, GPLv3, AGPLv3 | Exige que cualquier trabajo derivado o distribución de binarios enlazados estática o dinámicamente deba liberar su código fuente completo bajo la misma licencia GPL. AGPL extiende esto con el activador de servicio de red (modelo SaaS). |

#### Paso 2: Auditar Encabezados de Licencias en Paquetes del Sistema
Consulta los componentes de software del sistema instalados para verificar la atribución de licencias utilizando la base de datos de gestión de paquetes.

```bash
cat /usr/share/doc/curl/copyright | head -n 20
```
*Salida Esperada:*
```text
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: curl
Source: https://curl.se/

Files: *
Copyright: 1996 - 2024, Daniel Stenberg, <daniel@haxx.se>, and many contributors
License: curl

License: curl
  Permission to use, copy, modify, and distribute this software for any purpose
  with or without fee is hereby granted...
```

---

### Preguntas de Verificación — Ejercicio 4

1. **Pregunta 4.1**: Si un microservicio empresarial propietario se enlaza estáticamente (`.a`) contra una librería con licencia GPLv3, ¿qué requisito legal y técnico se activa bajo los términos de la licencia GPLv3?
2. **Pregunta 4.2**: ¿Cómo protege la licencia LGPLv3 a las aplicaciones anfitrionas de los requisitos de copyleft fuerte cuando se enlazan dinámicamente (`.so`) frente a estáticamente (`.a`)?

---

## Clave de Respuestas Detallada y Explicaciones de Verificación

<details>
<summary><strong>Haz clic para expandir la Clave de Soluciones y Explicaciones Técnicas Exhaustivas</strong></summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1**:  
  Al compilar `app_dynamic`, el enlazador (`gcc`/`ld`) encuentra referencias a las funciones `add_metrics` y `multiply_metrics`. Debido a que `-lcalculator` se proporcionó como una librería compartida (`libcalculator.so`), el enlazador no embebe el cuerpo de la función dentro de `app_dynamic`. En su lugar, emite entradas de símbolos indefinidos (`U`) en la Tabla de Símbolos Dinámicos ELF (`.dynsym`) junto con una entrada de encabezado `NEEDED` que apunta a `libcalculator.so`. La resolución real del símbolo `U` a un desplazamiento de memoria física se pospone hasta el tiempo de ejecución, gestionado por `ld-linux.so` utilizando la Tabla de Enlazado de Procedimientos (PLT) y la Tabla de Desplazamiento Global (GOT). Por el contrario, `app_static` absorbió las instrucciones directas en código máquina de `libcalculator.a` en su segmento `.text` durante la fase de enlazado estático; por lo tanto, el símbolo está definido localmente dentro del propio binario.

* **Respuesta 1.2**:  
  El enlazado estático empaqueta el código de las dependencias directamente dentro de cada imagen de contenedor binaria.
  1. **Sobrecarga en Parches de Seguridad**: Si se descubre una vulnerabilidad crítica (CVE) dentro de una dependencia compartida (por ejemplo, `OpenSSL` o `zlib`), cada binario de microservicio enlazado estáticamente contra esa librería debe ser recompilado completamente, reconstruido en imágenes de contenedor y redesplegado en los despliegues del clúster de Kubernetes. El enlazado dinámico permite actualizar un solo paquete de librería compartida en la imagen base o en el host del sistema operativo para solucionar vulnerabilidades a nivel de todo el sistema.
  2. **Huella de Memoria (Memory Footprint)**: Los binarios enlazados estáticamente no pueden compartir páginas de memoria de solo lectura (segmentos `.text`) en RAM a través de los límites de procesos del kernel, lo que incrementa el uso de memoria en hosts de contenedores de alta densidad.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1**:  
  El orden exacto de resolución evaluado por el cargador dinámico `ld-linux.so` es:
  1. **`DT_RPATH`** (embebido en el encabezado ELF), **SOLO SI** `DT_RUNPATH` **no** está presente en el binario.
  2. Variable de entorno **`LD_LIBRARY_PATH`** (a menos que se ejecute en modo de ejecución segura `setuid`/`setgid`).
  3. **`DT_RUNPATH`** (embebido en el encabezado ELF). (Si `DT_RUNPATH` existe, las entradas `DT_RPATH` se ignoran por completo).
  4. **`/etc/ld.so.cache`** (caché compilada que contiene el índice de librerías del sistema declaradas en `/etc/ld.so.conf`).
  5. Rutas de búsqueda de librerías del sistema por defecto: `/lib64`, `/usr/lib64`, `/lib`, `/usr/lib`.

* **Respuesta 2.2**:  
  `LD_PRELOAD` permite cargar librerías dinámicas arbitrarias antes de todas las demás librerías, habilitando la sobrescritura de funciones (interposición de símbolos). Si se permitiera `LD_PRELOAD` en binarios que se ejecutan con flags de privilegios elevados (`setuid`/`setgid`, como `/usr/bin/passwd` o `sudo`), un usuario sin privilegios podría escribir una librería maliciosa interceptando llamadas a la librería estándar como `getuid()` o `fopen()`, ejecutar el binario `setuid` con `LD_PRELOAD` y lograr una escalada arbitraria de privilegios a root. El cargador dinámico del kernel ignora automáticamente `LD_PRELOAD` y `LD_LIBRARY_PATH` cuando el contexto de ejecución del proceso detecta `AT_SECURE` (setuid/setgid/capabilities).

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1**:  
  Un componente de software `.deb` estándar es un archivo en formato `ar` que contiene tres archivos distintos:
  1. **`debian-binary`**: Un archivo de texto plano que define la versión del formato del paquete (típicamente `2.0`).
  2. **`control.tar.xz`** (o `.gz`): Contiene metadatos del paquete, declaraciones de dependencias (`control`), checksums de archivos (`md5sums`), scripts de disparadores del sistema y hooks del ciclo de vida del mantenedor (`preinst`, `postinst`, `prerm`, `postrm`).
  3. **`data.tar.xz`** (o `.gz`/`.zst`): Contiene el payload real del sistema de archivos (ejecutables, objetos compartidos, archivos de configuración, páginas man) que se extraerán en la raíz del sistema `/` al instalar el paquete.

* **Respuesta 3.2**:  
  - **`apt-get install -f`** (`--fix-broken`): Invoca el motor de resolución de grafos de APT para resolver estados incompletos, árboles de dependencias rotos o prerrequisitos faltantes de manera segura, obteniendo paquetes faltantes o limpiando estados no configurados de acuerdo con las reglas de los mantenedores.
  - **`dpkg --force-all`**: Omite las comprobaciones de dependencias, la protección contra sobrescritura de archivos y las restricciones de versión, alterando por la fuerza los archivos de estado local. Esto puede provocar inestabilidad en el sistema, bases de datos de paquetes corrompidas (`dpkg status`), librerías compartidas faltantes o la sobrescritura de componentes críticos del sistema.

---

### Soluciones del Ejercicio 4

* **Respuesta 4.1**:  
  GPLv3 es una licencia de **Copyleft Fuerte (Strong Copyleft)**. Bajo la sección 6 de GPLv3, si una aplicación se enlaza estáticamente contra un componente GPLv3 y se distribuye a terceros, toda la obra combinada se convierte en un trabajo derivado sujeto a GPLv3. La organización está legalmente obligada a hacer público el código fuente completo de su microservicio empresarial propietario bajo GPLv3, junto con las instrucciones de instalación (protecciones anti-tivoización) y las concesiones de patentes.

* **Respuesta 4.2**:  
  Las disposiciones explícitas de la LGPLv3 (Lesser General Public License) permiten que las aplicaciones anfitrionas se enlacen dinámicamente contra una librería LGPL sin forzar a la aplicación anfitriona a liberar su código fuente propietario. El requisito es que los usuarios deben poder modificar la librería LGPL y volver a enlazar la aplicación contra la librería modificada. El enlazado dinámico satisface esta condición al mantener el objeto compartido separado (`.so`), permitiendo a los usuarios reemplazar la librería compartida en el disco. El enlazado estático contra LGPL requiere proporcionar archivos objeto (`.o`) del código propietario para que el usuario pueda volver a enlazar manualmente la aplicación.

</details>

---

## Resumen de Tareas Completadas

- **Desglose Técnico Profundo**: Pipeline de compilación ELF detallado, mecánica de enlazado estático vs dinámico, trampolines GOT/PLT, búsquedas RPATH/RUNPATH, estructuras de paquetes (internos de `.deb`) y arquetipos de licenciamiento de código abierto.
- **Laboratorios Prácticos**: Construcción de aplicaciones C modulares, creación de archivos estáticos `.a` u objetos compartidos `.so` con PIC, análisis de fallos del cargador dinámico usando `ldd`/`nm`/`readelf`, embebido de `RUNPATH`, intercepción de símbolos mediante `LD_PRELOAD`, desempaquetado de estructuras de paquetes Debian con `ar`/`tar`, análisis de árboles de dependencias y auditoría de copyrights del sistema.
- **Verificación y Soluciones**: Preguntas de arquitectura detalladas tras cada módulo de laboratorio y una clave de respuestas completa y expandida que detalla compromisos de seguridad, orden de búsqueda del cargador dinámico, protecciones de seguridad setuid y reglas de cumplimiento de licencias.