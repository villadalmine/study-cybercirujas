# 1.1 Linux Evolution and Popular Operating Systems

**Examen:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2

---

## 1. Orígenes y evolución de Linux

### UNIX como antecedente

Linux no nació de la nada: su diseño se inspira en **UNIX**, un sistema operativo desarrollado a fines de los años 60 en los Bell Labs de AT&T. UNIX introdujo ideas que Linux hereda directamente: sistema multiusuario y multitarea, jerarquía única de archivos, herramientas pequeñas que se combinan entre sí, y la filosofía de "todo es un archivo".

### El proyecto GNU (1983)

En 1983, **Richard Stallman** lanzó el proyecto **GNU** (*GNU's Not Unix*) con el objetivo de crear un sistema operativo completamente libre. GNU produjo componentes esenciales: el compilador **GCC**, la shell **Bash**, las utilidades básicas (**coreutils**) y la licencia **GPL** (*GNU General Public License*). Sin embargo, al proyecto le faltaba una pieza clave: el **kernel**.

### El kernel Linux (1991)

En 1991, **Linus Torvalds**, entonces estudiante en Finlandia, anunció que estaba desarrollando un kernel libre como hobby. Ese kernel, llamado **Linux**, se combinó con las herramientas GNU y dio lugar al sistema operativo completo que hoy conocemos (por eso a veces se lo llama **GNU/Linux**). Torvalds liberó el código bajo la licencia **GPLv2**, lo que permitió que miles de desarrolladores de todo el mundo contribuyeran.

Puntos clave para el examen:

- **Linux es solo el kernel**; una distribución agrega las herramientas GNU, software adicional y un instalador.
- El desarrollo es **abierto y colaborativo**: cualquiera puede leer, modificar y redistribuir el código respetando la licencia.
- Linus Torvalds sigue supervisando el desarrollo del kernel, hoy respaldado por la **Linux Foundation**.

Podés ver la versión del kernel en cualquier sistema Linux con:

```bash
$ uname -r
6.8.0-45-generic

$ uname -a
Linux servidor01 6.8.0-45-generic #45-Ubuntu SMP x86_64 GNU/Linux
```

---

## 2. Distribuciones de Linux

Una **distribución** (o *distro*) empaqueta el kernel Linux junto con software GNU, un sistema de gestión de paquetes, documentación y soporte. Para el examen conviene conocer las principales familias.

### Familia Debian

- **Debian**: distribución comunitaria, muy estable, base de muchas otras. Usa paquetes **.deb** y las herramientas **dpkg** y **apt**.
- **Ubuntu**: desarrollada por **Canonical** sobre la base de Debian. Orientada a la facilidad de uso, con lanzamientos regulares cada 6 meses y versiones **LTS** (*Long Term Support*) cada 2 años, con 5 años de soporte.
- **Linux Mint**: basada en Ubuntu, popular en escritorios por su interfaz amigable para quienes vienen de Windows.
- **Raspberry Pi OS** (antes Raspbian): derivada de Debian, optimizada para la placa **Raspberry Pi**.

Ejemplo de gestión de paquetes en la familia Debian:

```bash
$ sudo apt update
$ sudo apt install htop
```

### Familia Red Hat

- **Red Hat Enterprise Linux (RHEL)**: distribución comercial de **Red Hat** orientada a empresas, con soporte pago y ciclos de vida largos. Usa paquetes **.rpm** con las herramientas **rpm**, **yum** y **dnf**.
- **Fedora**: distribución comunitaria patrocinada por Red Hat; funciona como campo de pruebas de tecnologías que luego llegan a RHEL. Ciclo de lanzamiento rápido (~6 meses).
- **CentOS / CentOS Stream**: históricamente una reconstrucción gratuita de RHEL; hoy CentOS Stream es una versión "rolling" previa a RHEL. Alternativas actuales compatibles con RHEL: **Rocky Linux** y **AlmaLinux**.

```bash
$ sudo dnf install htop
```

### Familia SUSE

- **SUSE Linux Enterprise Server (SLES)**: distribución empresarial de origen alemán, también basada en paquetes **.rpm**, con la herramienta de administración **YaST** y el gestor de paquetes **zypper**.
- **openSUSE**: la variante comunitaria, en ediciones **Leap** (estable) y **Tumbleweed** (*rolling release*).

### Distribuciones independientes

- **Arch Linux**: *rolling release*, minimalista, orientada a usuarios avanzados; usa el gestor **pacman**.
- **Gentoo**: el software se compila desde el código fuente, permitiendo máxima personalización.
- **Slackware**: una de las distribuciones más antiguas aún activas (1993).

Para identificar qué distribución corre un sistema:

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.1 LTS"
```

### ¿Cómo elegir una distribución?

Criterios que el examen espera que entiendas:

| Criterio | Ejemplo |
|---|---|
| Estabilidad y soporte a largo plazo | RHEL, Ubuntu LTS, Debian, SLES |
| Novedades y software reciente | Fedora, Arch, openSUSE Tumbleweed |
| Escritorio para principiantes | Ubuntu, Linux Mint |
| Soporte comercial para empresas | RHEL, SLES, Ubuntu (Canonical) |
| Hardware limitado o embebido | Raspberry Pi OS, distribuciones ligeras |

---

## 3. Linux en sistemas embebidos y dispositivos

Linux domina mucho más allá de servidores y escritorios:

- **Android**: el sistema operativo móvil más usado del mundo está construido sobre el **kernel Linux**, aunque su capa de usuario (bibliotecas y aplicaciones) es distinta a la de una distribución GNU/Linux tradicional. Es desarrollado por Google bajo el proyecto **AOSP** (*Android Open Source Project*).
- **Raspberry Pi**: computadora de placa única (*single-board computer*) de bajo costo con procesador **ARM**, muy usada en educación, prototipos y proyectos **IoT** (*Internet of Things*). Corre Raspberry Pi OS y muchas otras distros.
- **Dispositivos de red y hogar**: routers (muchos con **OpenWrt**), Smart TVs (**webOS**, **Tizen** usan kernel Linux), automóviles, drones y electrodomésticos inteligentes.
- **ChromeOS**: el sistema de los Chromebooks de Google también se basa en el kernel Linux, con el navegador Chrome como interfaz principal; hoy permite ejecutar aplicaciones Linux en contenedores.

---

## 4. Linux en servidores y en la nube

- La gran mayoría de los **servidores web** del mundo corren Linux (con software como **Apache HTTP Server** y **nginx**).
- Los **500 supercomputadoras más potentes** del mundo (lista TOP500) ejecutan Linux.
- Los principales proveedores de **cloud computing** — Amazon Web Services (AWS), Google Cloud, Microsoft Azure — ofrecen Linux como sistema principal para máquinas virtuales; gran parte de su propia infraestructura corre sobre Linux.
- Tecnologías nativas de la nube como **Docker** (contenedores) y **Kubernetes** (orquestación) dependen de características del kernel Linux (*namespaces*, *cgroups*).
- Incluso Microsoft integra Linux en Windows mediante **WSL** (*Windows Subsystem for Linux*).

---

## 5. Otros sistemas operativos (contexto comparativo)

El objetivo pide reconocer cómo se relaciona Linux con otros sistemas:

- **Windows**: sistema propietario de Microsoft, dominante en escritorios corporativos. Ciclos de versiones largos, API propia, no derivado de UNIX.
- **macOS**: sistema de Apple, **certificado como UNIX**; comparte con Linux la herencia de herramientas de línea de comandos (shell, utilidades similares), pero es propietario.
- **BSD** (FreeBSD, OpenBSD, NetBSD): descendientes directos de UNIX de Berkeley, de código abierto pero con licencia **BSD** (más permisiva que la GPL: permite redistribuir sin liberar el código fuente).

Diferencia de licencias que suele aparecer en el examen: la **GPL** obliga a que las obras derivadas se distribuyan también bajo GPL (*copyleft*), mientras que la licencia **BSD** permite usar el código en productos cerrados.

---

## 6. El ciclo de vida y las versiones

- El **kernel** tiene lanzamientos frecuentes (cada ~2-3 meses) y versiones **LTS** mantenidas por varios años.
- Las **distribuciones** definen sus propios ciclos: lanzamientos fijos con soporte definido (Debian, Ubuntu, RHEL) o **rolling release**, donde el sistema se actualiza continuamente sin "versiones" (Arch, openSUSE Tumbleweed).
- En entornos empresariales importa el concepto de **EOL** (*End of Life*): fecha en que una versión deja de recibir actualizaciones de seguridad.

---

## Resumen para el examen

- Linux = **kernel** creado por **Linus Torvalds** en **1991**, licenciado bajo **GPLv2**; combinado con el software del proyecto **GNU** de **Richard Stallman** forma un sistema operativo completo.
- Una **distribución** = kernel + herramientas GNU + gestor de paquetes + software adicional.
- Familias principales: **Debian** (Ubuntu, Mint, Raspberry Pi OS — paquetes `.deb`), **Red Hat** (RHEL, Fedora, CentOS/Rocky/Alma — paquetes `.rpm`), **SUSE** (SLES, openSUSE).
- **Android** y **ChromeOS** usan el kernel Linux; **Raspberry Pi** popularizó Linux en sistemas embebidos e IoT.
- Linux domina en **servidores, supercomputadoras y la nube**; Docker y Kubernetes se apoyan en el kernel Linux.
- **macOS** y los **BSD** derivan de UNIX; **Windows** no. GPL es *copyleft*; BSD es permisiva.

---

## Referencias

- LPI Learning Materials — Lesson 1.1 Linux Evolution and Popular Operating Systems: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- Objetivos oficiales del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- Documentación del kernel Linux: https://www.kernel.org/doc/html/latest/
- Proyecto GNU y licencia GPL: https://www.gnu.org/licenses/gpl-3.0.html
- Debian: https://www.debian.org/ · Ubuntu: https://ubuntu.com/ · Fedora: https://fedoraproject.org/ · openSUSE: https://www.opensuse.org/
- Android Open Source Project: https://source.android.com/
- Raspberry Pi: https://www.raspberrypi.com/documentation/