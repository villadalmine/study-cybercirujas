# Ejercicios Guiados — Tema 1.2: Major Open Source Applications

**Certificación:** LPI Linux Essentials (examen 010-160, versión 1.6) · **Peso:** 2
**Referencia:** [LPI Learning Materials 1.2](https://learning.lpi.org/en/learning-materials/010-160/1/1.2/)

> **Requisitos:** una terminal en cualquier distribución Linux (Debian/Ubuntu o Fedora/Rocky). Donde los comandos difieren entre familias de distribuciones, se indican ambas variantes.

---

## Ejercicio 1 — Identificar aplicaciones de escritorio instaladas

Las aplicaciones de escritorio más importantes del mundo open source incluyen suites de oficina (LibreOffice), navegadores (Firefox, Chromium), editores gráficos (GIMP, Inkscape) y reproductores multimedia (VLC).

1. Abrí una terminal y verificá si LibreOffice está instalado:

   ```bash
   which libreoffice
   ```

2. Consultá la versión instalada:

   ```bash
   libreoffice --version
   ```

3. Listá los componentes de LibreOffice disponibles en tu sistema buscando sus ejecutables:

   ```bash
   ls /usr/bin/ | grep -i -E "libreoffice|lowriter|localc|loimpress"
   ```

4. Verificá qué navegador web tenés instalado:

   ```bash
   which firefox chromium chromium-browser 2>/dev/null
   ```

5. Comprobá si GIMP está presente y, si no lo está, buscá información del paquete en el repositorio (sin instalarlo):

   ```bash
   # Debian/Ubuntu:
   apt show gimp

   # Fedora/Rocky:
   dnf info gimp
   ```

**Preguntas de verificación:**

**1.1.** ¿Qué componente de LibreOffice usarías para crear una hoja de cálculo, y cuál es su equivalente en Microsoft Office?

**1.2.** GIMP e Inkscape son ambos editores gráficos. ¿Cuál es la diferencia fundamental entre el tipo de imágenes que maneja cada uno?

**1.3.** El comando del paso 5 mostró información del paquete sin instalarlo. ¿De dónde obtiene esa información el gestor de paquetes?

---

## Ejercicio 2 — Explorar el gestor de paquetes y los repositorios

Una característica central de las distribuciones Linux es que el software se instala desde **repositorios** mediante un **package manager**. Las dos grandes familias son la de Debian (`.deb`, herramientas `dpkg`/`apt`) y la de Red Hat (`.rpm`, herramientas `rpm`/`dnf`).

1. Identificá a qué familia pertenece tu distribución:

   ```bash
   cat /etc/os-release
   ```

2. Contá cuántos paquetes hay instalados en tu sistema:

   ```bash
   # Debian/Ubuntu:
   dpkg -l | grep -c '^ii'

   # Fedora/Rocky:
   rpm -qa | wc -l
   ```

3. Actualizá el índice de paquetes disponibles desde los repositorios (esto **no** instala nada):

   ```bash
   # Debian/Ubuntu:
   sudo apt update

   # Fedora/Rocky:
   sudo dnf check-update
   ```

4. Buscá un paquete por palabra clave, por ejemplo el reproductor multimedia VLC:

   ```bash
   # Debian/Ubuntu:
   apt search vlc | head -20

   # Fedora/Rocky:
   dnf search vlc | head -20
   ```

5. Averiguá qué paquete es dueño de un archivo que ya existe en tu sistema:

   ```bash
   # Debian/Ubuntu:
   dpkg -S /bin/ls

   # Fedora/Rocky:
   rpm -qf /bin/ls
   ```

**Preguntas de verificación:**

**2.1.** ¿Qué formato de paquete usa Ubuntu y qué formato usa Fedora?

**2.2.** ¿Cuál es la diferencia entre `apt update` y `apt upgrade`?

**2.3.** Nombrá dos ventajas de instalar software desde un repositorio oficial en lugar de descargar un instalador desde un sitio web, como es habitual en Windows.

---

## Ejercicio 3 — Reconocer software de servidor

Gran parte de Internet corre sobre servidores Linux con aplicaciones open source: servidores web (Apache HTTP Server, NGINX), bases de datos (MariaDB, MySQL, PostgreSQL), y servicios de archivos (Samba, NFS).

1. Verificá si hay algún servidor web instalado en tu máquina:

   ```bash
   which apache2 httpd nginx 2>/dev/null
   ```

2. Consultá la información del paquete del servidor web Apache en los repositorios:

   ```bash
   # Debian/Ubuntu (fijate el nombre del paquete):
   apt show apache2 | head -15

   # Fedora/Rocky (fijate que el nombre cambia):
   dnf info httpd | head -15
   ```

3. Hacé lo mismo con una base de datos relacional:

   ```bash
   # Debian/Ubuntu:
   apt show mariadb-server | head -15

   # Fedora/Rocky:
   dnf info mariadb-server | head -15
   ```

4. Comprobá si algún servicio de servidor está corriendo ahora mismo en tu sistema:

   ```bash
   systemctl list-units --type=service --state=running | head -20
   ```

5. Buscá en los repositorios el paquete de Samba, que permite compartir archivos con redes Windows:

   ```bash
   # Debian/Ubuntu:
   apt show samba | grep -i description -A 3

   # Fedora/Rocky:
   dnf info samba | grep -i -A 3 summary
   ```

**Preguntas de verificación:**

**3.1.** Nombrá los dos servidores web open source más utilizados en Internet.

**3.2.** MariaDB nació como un *fork* de MySQL. ¿Qué significa hacer un "fork" de un proyecto open source y por qué la licencia lo permite?

**3.3.** ¿Para qué se usa Samba y con qué protocolo de red trabaja?

**3.4.** ¿Qué diferencia conceptual hay entre una aplicación de escritorio como LibreOffice y una aplicación de servidor como NGINX en cuanto a cómo interactúa el usuario con ellas?

---

## Ejercicio 4 — Lenguajes de programación y herramientas de desarrollo

Linux es la plataforma de desarrollo por excelencia. El examen espera que reconozcas los lenguajes más comunes (Shell/Bash, Python, Perl, PHP, C, Java, JavaScript) y herramientas como Git.

1. Verificá qué intérpretes y compiladores tenés disponibles:

   ```bash
   which bash python3 perl php gcc java node 2>/dev/null
   ```

2. Consultá la versión de Bash y de Python:

   ```bash
   bash --version | head -1
   python3 --version
   ```

3. Ejecutá una línea de Python directamente desde la terminal:

   ```bash
   python3 -c "print('Linux Essentials 010-160')"
   ```

4. Creá y ejecutá un mini script de shell:

   ```bash
   echo -e '#!/bin/bash\necho "Mi primer script en $(uname -s)"' > ~/hola.sh
   chmod +x ~/hola.sh
   ~/hola.sh
   ```

5. Verificá si Git, el sistema de control de versiones creado por Linus Torvalds, está instalado:

   ```bash
   git --version
   ```

6. Limpiá el archivo de prueba:

   ```bash
   rm ~/hola.sh
   ```

**Preguntas de verificación:**

**4.1.** ¿Qué lenguaje usarías para automatizar tareas administrativas encadenando comandos del sistema, y qué línea especial debe llevar el script al inicio?

**4.2.** ¿Qué es Git y quién lo creó? ¿Qué relación tiene esa persona con Linux?

**4.3.** De los lenguajes vistos, ¿cuál se asocia históricamente con el desarrollo web del lado del servidor y forma parte de la sigla "LAMP"? ¿Qué significa cada letra de LAMP?

**4.4.** En el paso 4, ¿qué hace exactamente `chmod +x` y por qué fue necesario?

---

## Ejercicio 5 — Software de nube privada y virtualización

El tema 1.2 también cubre nociones de cloud y colaboración: Nextcloud/ownCloud como nubes privadas, y la distinción entre SaaS, PaaS e IaaS.

1. Buscá información sobre Nextcloud en los repositorios (según la distribución puede estar el cliente de sincronización):

   ```bash
   # Debian/Ubuntu:
   apt search nextcloud 2>/dev/null | head -10

   # Fedora/Rocky:
   dnf search nextcloud | head -10
   ```

2. Verificá si tu CPU soporta virtualización por hardware:

   ```bash
   grep -c -E 'vmx|svm' /proc/cpuinfo
   ```

   (Un número mayor que 0 indica soporte: `vmx` es Intel, `svm` es AMD.)

3. Comprobá si el módulo de KVM, el hipervisor incluido en el kernel Linux, está cargado:

   ```bash
   lsmod | grep kvm
   ```

**Preguntas de verificación:**

**5.1.** Nextcloud nació como fork de ownCloud. ¿Qué ventaja ofrece alojar una nube privada con Nextcloud frente a usar un servicio como Google Drive o Dropbox?

**5.2.** Si contratás un servidor virtual vacío donde vos instalás el sistema operativo y todo el software, ¿estás usando SaaS, PaaS o IaaS?

**5.3.** ¿Qué es KVM y dónde está integrado?

---

<details>
<summary><strong>📝 Respuestas</strong></summary>

### Ejercicio 1

**1.1.** LibreOffice **Calc** es el componente de hojas de cálculo; su equivalente en Microsoft Office es **Excel**. (Los otros pares: Writer ↔ Word, Impress ↔ PowerPoint, Base ↔ Access.)

**1.2.** **GIMP** trabaja con gráficos **rasterizados** (bitmaps, píxeles), ideal para fotografía y retoque; **Inkscape** trabaja con gráficos **vectoriales** (formas matemáticas, formato SVG), que escalan sin perder calidad — ideal para logos e ilustraciones.

**1.3.** De los **metadatos de los repositorios** configurados en el sistema, que el package manager descarga y guarda en un índice local (actualizado con `apt update` o automáticamente por `dnf`). No hace falta tener el paquete instalado para consultar su descripción, versión y dependencias.

### Ejercicio 2

**2.1.** Ubuntu (familia Debian) usa paquetes **`.deb`**; Fedora (familia Red Hat) usa paquetes **`.rpm`**.

**2.2.** `apt update` solo **refresca el índice local** de paquetes disponibles en los repositorios (no toca el software instalado). `apt upgrade` **instala las versiones nuevas** de los paquetes ya instalados, usando ese índice. Por eso el orden habitual es `update` primero, `upgrade` después.

**2.3.** Cualquiera dos de estas: (a) el software está **firmado y verificado** por la distribución, reduciendo el riesgo de malware; (b) las **dependencias se resuelven automáticamente**; (c) las **actualizaciones de seguridad** llegan de forma centralizada para todo el sistema con un solo comando; (d) la desinstalación es limpia y trazable.

### Ejercicio 3

**3.1.** **Apache HTTP Server** y **NGINX**.

**3.2.** Un **fork** es tomar el código fuente de un proyecto y continuar su desarrollo de forma independiente, con otro nombre y otro equipo. Las licencias open source (en el caso de MySQL/MariaDB, la **GPL**) garantizan las libertades de usar, estudiar, modificar y redistribuir el código, lo que hace el fork legalmente posible. MariaDB fue creado por los desarrolladores originales de MySQL tras la compra de Sun/MySQL por Oracle.

**3.3.** **Samba** permite que un servidor Linux comparta archivos e impresoras con clientes Windows (y actúe en dominios Windows). Usa el protocolo **SMB/CIFS**, el nativo de las redes Microsoft.

**3.4.** Una aplicación de **escritorio** tiene interfaz gráfica y el usuario interactúa con ella directamente en su máquina. Una aplicación de **servidor** corre en segundo plano (como *service* o *daemon*), normalmente en una máquina remota sin pantalla, y los usuarios la consumen a través de la red (por ejemplo, con un navegador que pide páginas a NGINX). Se administra por configuración y comandos como `systemctl`, no con ventanas.

### Ejercicio 4

**4.1.** **Shell script (Bash)** es el lenguaje natural para automatizar tareas administrativas encadenando comandos. El script debe empezar con la línea **shebang**: `#!/bin/bash`, que indica al sistema qué intérprete debe ejecutarlo.

**4.2.** **Git** es un sistema de **control de versiones distribuido**: registra la historia de cambios del código y permite que muchos desarrolladores colaboren. Lo creó **Linus Torvalds** en 2005 — la misma persona que creó el **kernel Linux** — precisamente para gestionar el desarrollo del kernel.

**4.3.** **PHP**, que corresponde a la **P** de **LAMP**: **L**inux (sistema operativo) + **A**pache (servidor web) + **M**ySQL/MariaDB (base de datos) + **P**HP (lenguaje del lado del servidor; a veces la P también se lee como Perl o Python). Es el stack clásico de aplicaciones web open source como WordPress.

**4.4.** `chmod +x` agrega el **permiso de ejecución** al archivo. En Linux, un archivo de texto con comandos no es ejecutable por defecto; sin ese permiso, `~/hola.sh` fallaría con "Permission denied" al invocarlo directamente.

### Ejercicio 5

**5.1.** Con Nextcloud, **vos controlás el servidor y los datos**: los archivos quedan en tu propia infraestructura, sin depender de las políticas de privacidad, límites o costos de un proveedor externo. Es la opción preferida cuando la **soberanía de los datos** importa (empresas, organismos públicos).

**5.2.** **IaaS** (*Infrastructure as a Service*): el proveedor te da la infraestructura virtual (CPU, RAM, disco, red) y vos administrás todo lo demás. En **PaaS** el proveedor gestiona también el sistema operativo y el runtime (vos solo despliegas tu aplicación); en **SaaS** consumís una aplicación terminada (por ejemplo, un webmail).

**5.3.** **KVM** (*Kernel-based Virtual Machine*) es el **hipervisor integrado en el propio kernel Linux**, que convierte al sistema en un host de virtualización capaz de ejecutar máquinas virtuales con aceleración por hardware (Intel VT-x / AMD-V). Es la base de gran parte de la infraestructura cloud actual.

</details>

---

**Fuente de referencia:** [learning.lpi.org — Linux Essentials 1.2: Major Open Source Applications](https://learning.lpi.org/en/learning-materials/010-160/1/1.2/)