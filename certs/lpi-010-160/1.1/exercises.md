# Ejercicios guiados — Tema 1.1: Linux Evolution and Popular Operating Systems

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2
**Fuente de referencia:** [LPI Learning Materials 1.1](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)

> Para estos ejercicios necesitás acceso a una terminal en cualquier distribución Linux (una máquina virtual, WSL o un *live USB* sirven perfectamente).

---

## Ejercicio 1 — ¿Qué es exactamente "Linux"? Distinguir kernel de distribución

Linux, en sentido estricto, es solo el **kernel**: el componente que administra hardware, memoria y procesos. Lo que instalás y usás a diario es una **distribución** (*distribution* o *distro*): el kernel más herramientas GNU, un gestor de paquetes, entorno gráfico y configuración. En este ejercicio vas a ver ambas capas por separado.

1. Abrí una terminal y consultá la versión del kernel:

   ```bash
   uname -r
   ```

2. Pedí la información completa del kernel (nombre, versión, arquitectura):

   ```bash
   uname -a
   ```

3. Ahora consultá la información de la **distribución**, que vive en un archivo de texto plano:

   ```bash
   cat /etc/os-release
   ```

4. Compará las dos salidas: anotá el valor de `uname -r` y los campos `NAME`, `VERSION` e `ID_LIKE` (si existe) de `/etc/os-release`.

**Preguntas de verificación**

- **1.a)** ¿Por qué la versión que muestra `uname -r` no coincide con la versión que aparece en `/etc/os-release`? ¿Qué versiona cada una?
- **1.b)** ¿Quién creó el kernel Linux, en qué año lo anunció y bajo qué licencia se distribuye hoy?
- **1.c)** Si el campo `ID_LIKE` de tu sistema dice `debian`, ¿qué te dice eso sobre la distribución que estás usando?

---

## Ejercicio 2 — Identificar la familia de tu distribución por su gestor de paquetes

Las distribuciones se agrupan en **familias**, y la pista más confiable para reconocerlas es el sistema de paquetes: la familia **Debian** usa paquetes `.deb` con `apt`/`dpkg`, y la familia **Red Hat** usa paquetes `.rpm` con `dnf`/`yum`/`rpm`.

1. Averiguá qué gestores de paquetes existen en tu sistema:

   ```bash
   which apt dpkg dnf yum rpm zypper pacman 2>/dev/null
   ```

2. Según cuál haya aparecido, listá algunos paquetes instalados (ejecutá **solo** la línea que corresponda a tu sistema):

   ```bash
   dpkg -l | head        # familia Debian (Debian, Ubuntu, Mint, Raspberry Pi OS)
   rpm -qa | head        # familia Red Hat (Fedora, RHEL, CentOS Stream, openSUSE)
   pacman -Q | head      # Arch Linux y derivadas
   ```

3. Verificá que el gestor "contrario" no funciona: si estás en Ubuntu, probá `rpm -qa`; si estás en Fedora, probá `dpkg -l`. Observá el error.

4. Como investigación complementaria, visitá [https://distrowatch.com](https://distrowatch.com) y buscá tu distribución: fijate en el campo *Based on* de su ficha.

**Preguntas de verificación**

- **2.a)** Uniendo cada distribución con su familia: Ubuntu, CentOS Stream, Linux Mint, Fedora, Raspberry Pi OS — ¿cuáles derivan de Debian y cuáles pertenecen al ecosistema Red Hat?
- **2.b)** ¿Qué diferencia práctica hay entre una distribución con *release* fijo (por ejemplo, Debian *stable*) y una *rolling release* (por ejemplo, Arch Linux)?
- **2.c)** Una empresa necesita soporte comercial con contrato y ciclos de vida largos. ¿Qué distribuciones del temario encajan mejor: Debian, Red Hat Enterprise Linux, SUSE Linux Enterprise o Arch Linux? Justificá.

---

## Ejercicio 3 — Linux más allá del escritorio: servidores, cloud y sistemas embebidos

Linux domina en servidores, supercomputadoras, dispositivos embebidos (*embedded systems*) y la nube. Android, el sistema operativo móvil más usado del mundo, también corre sobre el kernel Linux. En este ejercicio vas a comprobarlo con evidencia real.

1. Si tenés un teléfono Android a mano: entrá en **Ajustes → Acerca del teléfono → Versión de Android** (a veces dentro de *Información de software*) y tocá en la sección de versión del kernel. Anotá el número: es una versión del kernel Linux.

2. Desde tu terminal, consultá qué kernel usan servidores reales en Internet. Muchos servidores web se identifican en sus cabeceras HTTP:

   ```bash
   curl -sI https://www.kernel.org | head -5
   ```

3. Visitá [https://www.kernel.org](https://www.kernel.org) en un navegador y anotá cuál es la versión *stable* actual del kernel y cuál es la versión *longterm* (LTS) más reciente.

4. Investigá un caso de Linux embebido: buscá qué sistema operativo usa por defecto una Raspberry Pi ([https://www.raspberrypi.com/software/](https://www.raspberrypi.com/software/)) y de qué distribución deriva.

**Preguntas de verificación**

- **3.a)** ¿Es correcto decir que "Android es una distribución Linux como Ubuntu"? Matizá la respuesta: ¿qué comparte Android con una distro tradicional y qué no?
- **3.b)** ¿Qué significa que una versión del kernel sea **LTS** (*Long Term Support*) y por qué es especialmente importante en sistemas embebidos y empresariales?
- **3.c)** Nombrá al menos tres ámbitos, además del escritorio, donde Linux tiene presencia dominante o muy fuerte.

---

## Ejercicio 4 — Probar una distribución sin instalar nada: el modo *live*

Una gran ventaja del software libre es que podés evaluar una distribución completa sin tocar tu disco, usando una imagen *live*.

1. Entrá en la página de descargas de dos distribuciones de familias distintas, por ejemplo:
   - Ubuntu: [https://ubuntu.com/download/desktop](https://ubuntu.com/download/desktop)
   - Fedora: [https://fedoraproject.org/workstation/](https://fedoraproject.org/workstation/)

2. Anotá para cada una: el tamaño de la imagen ISO, la política de versiones (¿cada cuánto sale una nueva? ¿cuánto dura el soporte?) y si ofrecen una edición LTS o de soporte extendido.

3. **Opcional (recomendado):** descargá una de las ISO y arrancala en una máquina virtual (VirtualBox, GNOME Boxes o similar) seleccionando la opción *Try / Live* en el menú de arranque. Explorá el escritorio sin instalar.

4. Dentro de la sesión *live* (o en tu sistema habitual), identificá el **entorno de escritorio** (*desktop environment*):

   ```bash
   echo $XDG_CURRENT_DESKTOP
   ```

**Preguntas de verificación**

- **4.a)** ¿Qué es una imagen *live* y qué ventaja ofrece frente a una instalación tradicional a la hora de elegir distribución?
- **4.b)** El entorno de escritorio (GNOME, KDE Plasma, Xfce…) ¿forma parte del kernel? ¿Qué papel cumple dentro de una distribución?
- **4.c)** Ubuntu publica versiones **LTS** cada dos años. ¿Qué tipo de usuario u organización debería preferir una LTS frente a una versión intermedia?

---

## Ejercicio 5 — Linux frente a otros sistemas operativos

Para el examen tenés que poder situar a Linux junto a otros sistemas operativos populares: Windows, macOS y los Unix propietarios/derivados (incluidos los BSD).

1. Armá una tabla comparativa en un archivo de texto. Creala desde la terminal:

   ```bash
   nano comparativa-so.txt
   ```

   Incluí filas para: **modelo de licencia** (¿código abierto o propietario?), **origen/parentesco con Unix**, **ciclo de versiones** y **ámbito de uso principal**. Completala para Linux, Windows, macOS y FreeBSD, investigando en los sitios oficiales de cada proyecto.

2. Comprobá el parentesco Unix de tu sistema: el estándar de jerarquía de archivos y muchas herramientas vienen de esa tradición:

   ```bash
   ls /
   man intro
   ```

   Observá directorios clásicos de Unix como `/etc`, `/usr`, `/home` y `/var`.

3. Investigá brevemente qué relación tiene macOS con Unix (pista: buscá "macOS UNIX certified" y la base *Darwin*/BSD en [https://opensource.apple.com](https://opensource.apple.com)).

**Preguntas de verificación**

- **5.a)** ¿Cuál es la diferencia fundamental de modelo de desarrollo y licencia entre Linux y Windows?
- **5.b)** macOS y Linux comparten herencia Unix, pero ¿en qué se diferencian en cuanto a licencia y hardware soportado?
- **5.c)** ¿Qué es FreeBSD y en qué se diferencia su origen del de Linux, si ambos "se parecen a Unix"?
- **5.d)** ¿Qué rol cumplió el proyecto **GNU** de Richard Stallman en lo que hoy llamamos "Linux"?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** `uname -r` muestra la versión del **kernel Linux**, mientras que `/etc/os-release` describe la **distribución** (por ejemplo, Ubuntu 24.04 o Fedora 42). Son productos con numeración independiente: la distro empaqueta un kernel concreto junto con miles de programas más, y sus versiones no tienen por qué coincidir.
- **1.b)** El kernel Linux fue creado por **Linus Torvalds**, quien lo anunció públicamente en **1991** como un proyecto personal. Se distribuye bajo la licencia **GPLv2** (GNU General Public License, versión 2), lo que garantiza que su código fuente sea libre de usar, estudiar, modificar y redistribuir.
- **1.c)** `ID_LIKE=debian` indica que la distribución **deriva de Debian** (como Ubuntu o Linux Mint): comparte su formato de paquetes `.deb`, sus herramientas (`apt`, `dpkg`) y gran parte de su estructura.

### Ejercicio 2

- **2.a)** Familia **Debian**: Ubuntu, Linux Mint y Raspberry Pi OS (Mint deriva de Ubuntu, que a su vez deriva de Debian). Ecosistema **Red Hat**: Fedora (proyecto comunitario patrocinado por Red Hat, base de futuras versiones de RHEL) y CentOS Stream (rama de desarrollo previa a RHEL).
- **2.b)** Una distribución de *release* fijo publica versiones cerradas y estables que solo reciben correcciones de seguridad durante su ciclo de vida: predecible, ideal para servidores. Una *rolling release* actualiza los paquetes continuamente sin "versiones": siempre tenés el software más nuevo, a cambio de más riesgo de roturas y más mantenimiento.
- **2.c)** **Red Hat Enterprise Linux** y **SUSE Linux Enterprise**: son distribuciones comerciales con contratos de soporte, certificaciones de hardware/software y ciclos de vida de 10 años o más. Debian es excelente y estable, pero su soporte es comunitario; Arch es *rolling* y sin soporte comercial, orientada a usuarios avanzados.

### Ejercicio 3

- **3.a)** Es parcialmente correcto. Android **usa el kernel Linux** (modificado por Google), pero **no** es una distribución tradicional: no usa las herramientas GNU ni glibc estándar (usa Bionic), no tiene un gestor de paquetes tipo `apt`/`dnf` sino tiendas de aplicaciones, y su *userland* (máquina virtual ART, framework de apps en Java/Kotlin) es completamente distinto. Comparte el kernel; casi nada más.
- **3.b)** Una versión **LTS** del kernel recibe correcciones de errores y de seguridad durante varios años (típicamente 2 a 6), en lugar de unos pocos meses. En sistemas embebidos (routers, autos, electrodomésticos) y servidores empresariales el hardware queda en producción durante años sin poder cambiar de kernel fácilmente, así que necesitan una base mantenida a largo plazo.
- **3.c)** Cualquiera de estos vale: **servidores web y de Internet**, **supercomputadoras** (el 100% del TOP500 corre Linux), **cloud computing** (la mayoría de las instancias en AWS, Azure y Google Cloud), **dispositivos móviles** (Android), **sistemas embebidos e IoT** (routers, Smart TVs, Raspberry Pi), y **redes** (switches, firewalls).

### Ejercicio 4

- **4.a)** Una imagen *live* es un sistema completo que arranca desde USB/DVD y corre en memoria RAM, **sin modificar el disco**. Permite probar el hardware, el escritorio y las aplicaciones de una distribución antes de decidir instalarla — algo posible gracias a que el software es libre y gratuito de redistribuir.
- **4.b)** No, el entorno de escritorio **no es parte del kernel**: es una capa de software de usuario (ventanas, paneles, aplicaciones gráficas) que la distribución elige y empaqueta. Por eso una misma distro puede ofrecerse con GNOME, KDE Plasma o Xfce ("sabores" o *spins*), todos sobre el mismo kernel.
- **4.c)** Organizaciones y usuarios que priorizan **estabilidad y soporte prolongado** sobre novedades: empresas, escuelas, servidores en producción. Una LTS de Ubuntu recibe actualizaciones de seguridad por 5 años (extensibles), mientras que las versiones intermedias solo por 9 meses.

### Ejercicio 5

- **5.a)** Linux es **software de código abierto** (kernel bajo GPLv2): cualquiera puede leer, modificar y redistribuir el código, y lo desarrolla una comunidad global junto con empresas. Windows es **propietario y de código cerrado**: solo Microsoft lo desarrolla y lo licencia, generalmente pagando, sin acceso al código fuente.
- **5.b)** macOS es un Unix **certificado** pero **propietario**: su base Darwin es de código abierto (herencia BSD), pero el sistema completo es cerrado y **solo se licencia para hardware de Apple**. Linux es abierto en su totalidad y corre en prácticamente cualquier arquitectura, desde una Raspberry Pi hasta un mainframe.
- **5.c)** FreeBSD es un sistema operativo **descendiente directo del Unix de Berkeley (BSD)**: heredó código real de esa base, mientras que Linux fue escrito **desde cero** en 1991 "a imagen de" Unix, sin usar su código. Además, FreeBSD se distribuye bajo la licencia BSD (más permisiva) y desarrolla kernel y *userland* como un solo proyecto integrado.
- **5.d)** El proyecto **GNU** (iniciado por Richard Stallman en 1983) creó las herramientas esenciales de un sistema tipo Unix libre: compilador (GCC), shell (Bash), utilidades básicas (coreutils) y la licencia GPL. Cuando apareció el kernel de Torvalds en 1991, encajó como la pieza que le faltaba a GNU; por eso muchas distribuciones se describen como sistemas **GNU/Linux**.

</details>

---

**Fuentes consultadas:**
- LPI Learning Materials, Lesson 1.1: [https://learning.lpi.org/en/learning-materials/010-160/1/1.1/](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)
- The Linux Kernel Archives: [https://www.kernel.org](https://www.kernel.org)
- DistroWatch: [https://distrowatch.com](https://distrowatch.com)
- Raspberry Pi Software: [https://www.raspberrypi.com/software/](https://www.raspberrypi.com/software/)