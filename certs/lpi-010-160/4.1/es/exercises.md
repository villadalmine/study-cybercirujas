# Ejercicios guiados — Tema 4.1: Choosing an Operating System

**Certificación:** LPI Linux Essentials (010-160, v1.6) · **Peso:** 1

> Para estos ejercicios necesitás acceso a una terminal en cualquier distribución Linux (física, máquina virtual o WSL). Algunos pasos incluyen investigación en el navegador.

---

## Ejercicio 1: Identificar tu distribución y su ciclo de vida

Cada distribución Linux combina el kernel con un conjunto de software y define su propio ciclo de lanzamientos (*release cycle*) y de soporte (*support lifecycle*). Vamos a identificar qué estás usando.

1. Abrí una terminal y mostrá el contenido del archivo que identifica tu distribución:

   ```bash
   cat /etc/os-release
   ```

2. Anotá los valores de los campos `NAME`, `VERSION_ID` y, si existe, `VERSION_CODENAME`.

3. Consultá la versión del kernel que estás ejecutando:

   ```bash
   uname -r
   ```

4. Buscá en el sitio web oficial de tu distribución (por ejemplo, wiki.debian.org, ubuntu.com/about/release-cycle o docs.fedoraproject.org) hasta qué fecha tiene soporte la versión que anotaste en el paso 2.

**Preguntas:**

- **1.a)** ¿Qué diferencia hay entre la versión de la distribución (paso 2) y la versión del kernel (paso 3)? ¿Por qué son dos números distintos?
- **1.b)** ¿Qué significa que una versión de una distribución llegue a su *End of Life* (EOL)? ¿Qué riesgo implica seguir usándola?
- **1.c)** Ubuntu publica versiones marcadas como **LTS** (*Long Term Support*). ¿Qué ventaja ofrece una versión LTS frente a una versión intermedia, y en qué escenario elegirías cada una?

---

## Ejercicio 2: Rolling release vs. lanzamientos fijos

Las distribuciones siguen dos modelos principales: lanzamientos con versión fija (*point releases*, como Debian o Ubuntu) o actualización continua (*rolling release*, como openSUSE Tumbleweed o Arch Linux).

1. Volvé a mirar la salida de `cat /etc/os-release` del ejercicio anterior. Fijate si tu distribución tiene un número de versión definido (por ejemplo, `VERSION_ID="12"`) o no.

2. Investigá en el navegador cómo se actualiza **Debian Stable** de una versión mayor a la siguiente (por ejemplo, de 11 a 12).

3. Investigá cómo se actualiza **Arch Linux**: buscá si existe el concepto de "versión 2024" o similar en su wiki (wiki.archlinux.org).

4. Armá en un papel o archivo de texto una tabla de dos columnas: "fixed release" y "rolling release", y anotá al menos dos distribuciones en cada columna.

**Preguntas:**

- **2.a)** ¿Cuál es la diferencia fundamental entre un modelo *fixed release* y uno *rolling release*?
- **2.b)** Para el servidor de una empresa que necesita máxima estabilidad y cambios predecibles, ¿qué modelo recomendarías y por qué?
- **2.c)** Un desarrollador quiere siempre las últimas versiones de sus herramientas apenas se publican. ¿Qué modelo le conviene más?

---

## Ejercicio 3: Familias de distribuciones y gestores de paquetes

Las distribuciones se agrupan en familias, y una pista clave para reconocerlas es su gestor de paquetes (*package manager*).

1. Verificá cuál de estos comandos existe en tu sistema (los que no existan van a devolver un error, y está bien que así sea):

   ```bash
   which apt
   which dnf
   which zypper
   which pacman
   ```

2. Con el gestor que sí exista, buscá un paquete conocido. Por ejemplo, en una distribución basada en Debian:

   ```bash
   apt search htop
   ```

   O en una basada en Red Hat / Fedora:

   ```bash
   dnf search htop
   ```

3. Investigá en el navegador de qué distribución "madre" derivan: **Ubuntu**, **Linux Mint**, **Rocky Linux** y **AlmaLinux**.

**Preguntas:**

- **3.a)** Relacioná cada gestor de paquetes con su familia de distribuciones: `apt`, `dnf`, `zypper`, `pacman`.
- **3.b)** Ubuntu deriva de Debian, y Linux Mint deriva de Ubuntu. ¿Qué ventaja práctica tiene que una distribución derive de otra?
- **3.c)** ¿Por qué surgieron Rocky Linux y AlmaLinux, y qué relación tienen con Red Hat Enterprise Linux (RHEL)?

---

## Ejercicio 4: Linux más allá del escritorio — servidores, embebidos y móviles

Linux no vive solo en computadoras de escritorio: domina en servidores, dispositivos embebidos (*embedded systems*) y móviles.

1. Si tenés un teléfono Android a mano, entrá en **Ajustes → Acerca del teléfono → Versión de Android** (la ruta exacta varía según el fabricante) y buscá también la opción "Versión del kernel". Anotá lo que veas.

2. En tu terminal Linux, ejecutá de nuevo `uname -r` y compará el formato del número con la versión del kernel de Android.

3. Investigá en el navegador qué sistema operativo usa una **Raspberry Pi** por defecto (raspberrypi.com) y de qué distribución deriva.

4. Investigá qué sistema operativo corre en la mayoría de los 500 supercomputadores más potentes del mundo (podés consultar top500.org).

**Preguntas:**

- **4.a)** ¿Qué relación tiene Android con Linux? ¿Se considera una distribución Linux tradicional? Justificá.
- **4.b)** Mencioná tres ejemplos de dispositivos embebidos donde probablemente corra Linux sin que el usuario lo note.
- **4.c)** ¿Por qué Linux es tan dominante en servidores y supercomputación? Nombrá al menos dos motivos.

---

## Ejercicio 5: Comparar Linux con Windows y macOS

Al elegir un sistema operativo también hay que considerar las alternativas no-Linux y sus diferencias de diseño.

1. Investigá (o recordá, si los usaste) cómo se organiza el almacenamiento en Windows: ¿cómo se identifican los discos y particiones? Compará con la salida de este comando en Linux:

   ```bash
   df -h /
   ```

   Observá que en Linux todo cuelga de la raíz `/`, sin letras de unidad.

2. Investigá en qué sistema operativo se basa **macOS** y qué relación tiene con la familia **Unix**.

3. Ejecutá en tu Linux:

   ```bash
   echo $SHELL
   ```

   y anotá qué shell estás usando. Investigá cuál es la shell por defecto en macOS moderno y cuáles son las opciones de línea de comandos en Windows (CMD y PowerShell).

**Preguntas:**

- **5.a)** Nombrá dos diferencias técnicas entre Windows y Linux (pensá en el sistema de archivos, las letras de unidad, la distinción entre mayúsculas y minúsculas, o el modelo de licencias).
- **5.b)** ¿Por qué se dice que macOS está "más cerca" de Linux que Windows en cuanto a la línea de comandos?
- **5.c)** ¿Qué significa que Linux sea *open source* y qué implicancia práctica tiene frente al modelo de licencias de Windows y macOS?

---

## Ejercicio 6: Elegir una distribución para un escenario concreto

Este es el corazón del tema: no existe "la mejor" distribución, sino la adecuada para cada caso.

1. Leé estos cuatro escenarios:
   - **A)** Una escuela con computadoras viejas y poco presupuesto necesita equipos de escritorio fáciles de usar.
   - **B)** Un banco necesita servidores con soporte comercial, certificaciones y contratos de asistencia.
   - **C)** Un hobbista quiere armar un centro multimedia con una Raspberry Pi.
   - **D)** Un administrador de sistemas quiere un entorno de pruebas con el software más reciente posible.

2. Para cada escenario, elegí una distribución candidata. Podés apoyarte en lo investigado en los ejercicios anteriores o en distrowatch.com.

3. Escribí una línea de justificación por cada elección: qué criterio pesó más (costo, soporte, hardware, estabilidad, novedad del software).

**Preguntas:**

- **6.a)** ¿Qué criterios generales hay que evaluar al elegir un sistema operativo o distribución? Listá al menos cuatro.
- **6.b)** ¿Qué diferencia hay entre el soporte comunitario (foros, wikis) y el soporte comercial (contratos con empresas como Red Hat, SUSE o Canonical)?
- **6.c)** ¿Por qué el costo de la licencia no es el único costo a considerar al elegir un sistema operativo? (Pista: pensá en el concepto de *Total Cost of Ownership*).

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** La versión de la distribución identifica el conjunto completo de software empaquetado (kernel + utilidades + gestor de paquetes + configuración) que el proyecto publicó en un momento dado. La versión del kernel identifica solo el núcleo del sistema. Son independientes: una misma versión de distribución puede recibir actualizaciones de kernel, y dos distribuciones distintas pueden usar la misma versión de kernel.
- **1.b)** EOL significa que el proyecto deja de publicar actualizaciones, incluidas las de seguridad. Seguir usando una versión EOL expone el sistema a vulnerabilidades conocidas sin corrección, lo cual es especialmente grave en servidores conectados a Internet.
- **1.c)** Una versión LTS recibe soporte extendido (en Ubuntu, 5 años estándar frente a 9 meses de las versiones intermedias). LTS conviene para servidores y entornos de producción donde importa la estabilidad; las versiones intermedias convienen a quienes quieren software más nuevo y no les molesta actualizar seguido.

### Ejercicio 2

- **2.a)** En un modelo *fixed release* el software se congela en versiones numeradas que se publican periódicamente y se mantienen estables (solo reciben correcciones); pasar a la versión siguiente es un salto planificado. En un *rolling release* no hay versiones: los paquetes se actualizan continuamente a medida que se publican, y el sistema siempre está "al día".
- **2.b)** *Fixed release*, idealmente con soporte extendido (Debian Stable, Ubuntu LTS, RHEL). La empresa gana previsibilidad: los cambios grandes solo llegan cuando el administrador decide migrar de versión, y mientras tanto solo recibe correcciones de seguridad.
- **2.c)** *Rolling release* (Arch Linux, openSUSE Tumbleweed), porque las nuevas versiones de las herramientas llegan a los repositorios casi de inmediato, sin esperar al próximo lanzamiento de la distribución.

### Ejercicio 3

- **3.a)** `apt` → familia Debian (Debian, Ubuntu, Linux Mint, Raspberry Pi OS). `dnf` → familia Red Hat / Fedora (Fedora, RHEL, Rocky, AlmaLinux). `zypper` → familia SUSE (openSUSE, SLES). `pacman` → Arch Linux y derivadas (Manjaro).
- **3.b)** La derivada reutiliza el trabajo de la distribución madre (paquetes, infraestructura, correcciones de seguridad) y se concentra en aportar su valor diferencial: escritorio más amigable, ciclos de lanzamiento propios, herramientas adicionales. El usuario hereda la compatibilidad y la documentación de la madre.
- **3.c)** Surgieron cuando CentOS (la reconstrucción gratuita de RHEL) cambió su modelo a CentOS Stream en 2020-2021. Rocky Linux y AlmaLinux son reconstrucciones compatibles binariamente con RHEL: ofrecen el mismo comportamiento sin el costo de la suscripción, aunque sin el soporte comercial de Red Hat.

### Ejercicio 4

- **4.a)** Android usa el kernel Linux, pero encima de él corre un stack de software propio de Google (bibliotecas, máquina virtual/ART, framework de aplicaciones) en lugar de las herramientas GNU y los gestores de paquetes habituales. Por eso se dice que Android "está basado en Linux" pero no se lo considera una distribución Linux tradicional.
- **4.b)** Ejemplos válidos: routers y access points Wi-Fi, smart TVs, autos (sistemas de infoentretenimiento), cámaras IP, NAS domésticos, lectores de e-books, electrodomésticos inteligentes, sistemas de peaje o cartelería digital.
- **4.c)** Motivos válidos: es gratuito y de código abierto (sin costo de licencia por servidor), es estable y eficiente, es altamente personalizable (se puede recortar a lo mínimo necesario), tiene excelente soporte de red y automatización, y escala desde hardware modesto hasta supercomputadoras — de hecho, el 100% del TOP500 corre Linux.

### Ejercicio 5

- **5.a)** Diferencias válidas: Windows usa letras de unidad (`C:`, `D:`) mientras Linux monta todo en un único árbol bajo `/`; los sistemas de archivos de Linux distinguen mayúsculas de minúsculas y los de Windows típicamente no; Windows usa `\` como separador de rutas y Linux `/`; Windows es software propietario con licencia paga y Linux es open source; los formatos de sistema de archivos difieren (NTFS vs. ext4/XFS/Btrfs).
- **5.b)** Porque macOS desciende de Unix (está certificado como UNIX, basado en Darwin/BSD), así que su terminal ofrece las mismas shells (zsh, bash) y comandos clásicos (`ls`, `grep`, `ssh`) que Linux. Windows, en cambio, tiene su propia línea de comandos (CMD, PowerShell) con sintaxis distinta, aunque hoy ofrece WSL para ejecutar Linux dentro de Windows.
- **5.c)** Open source significa que el código fuente está disponible y la licencia permite usarlo, estudiarlo, modificarlo y redistribuirlo. En la práctica: no se paga licencia por copia instalada, cualquiera puede auditar el código o adaptarlo, y no hay dependencia de un único proveedor. Windows y macOS son propietarios: el código es cerrado y el uso está limitado por la licencia del fabricante.

### Ejercicio 6

- **6.a)** Criterios: costo (licencias y soporte), duración del ciclo de soporte (LTS/EOL), estabilidad vs. novedad del software, compatibilidad con el hardware disponible, disponibilidad de las aplicaciones necesarias, facilidad de uso para los usuarios finales, soporte disponible (comunitario o comercial) y conocimientos previos del equipo que lo va a administrar.
- **6.b)** El soporte comunitario es gratuito y se basa en foros, wikis, listas de correo y documentación mantenida por voluntarios: puede ser excelente, pero sin garantías de respuesta. El soporte comercial es un contrato con una empresa (Red Hat, SUSE, Canonical) que garantiza tiempos de respuesta, actualizaciones certificadas y responsabilidad legal — algo que muchas empresas exigen para sistemas críticos.
- **6.c)** Porque al costo de licencia se suman los costos de administración, capacitación del personal, migración de aplicaciones, soporte, tiempo de inactividad y mantenimiento a lo largo de los años. Un sistema "gratis" puede resultar caro si nadie del equipo sabe administrarlo, y uno pago puede resultar económico si reduce esos otros costos. Ese total es el *Total Cost of Ownership* (TCO).

**Ejemplos de soluciones para los escenarios del paso 1 (hay más de una respuesta válida):**
- **A)** Linux Mint, Lubuntu o Xubuntu: gratuitas, livianas para hardware viejo y con escritorios amigables.
- **B)** Red Hat Enterprise Linux o SUSE Linux Enterprise Server: soporte comercial, certificaciones y contratos de asistencia.
- **C)** Raspberry Pi OS (derivada de Debian) o una distribución multimedia como LibreELEC.
- **D)** Fedora (software muy reciente con lanzamientos semestrales) o una rolling release como Arch Linux u openSUSE Tumbleweed.

</details>

---

**Fuente de referencia:** [LPI Learning Materials — Tema 4.1: Choosing an Operating System](https://learning.lpi.org/en/learning-materials/010-160/4/4.1/)