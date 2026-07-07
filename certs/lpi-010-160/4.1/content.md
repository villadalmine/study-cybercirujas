# 4.1 – Choosing an Operating System (Elección de un Sistema Operativo)

**Peso en el examen:** 1
**Objetivo:** Conocer los principales sistemas operativos, entender las diferencias entre distribuciones Linux y saber cómo se gestiona su ciclo de vida (lifecycle).

---

## 1. ¿Qué es un sistema operativo?

Un **sistema operativo (OS)** es el software que administra el hardware de la computadora y provee servicios a las aplicaciones: gestión de memoria, procesos, dispositivos, sistemas de archivos y usuarios. Al elegir un OS hay que considerar:

- **Propósito:** desktop, server, dispositivo móvil, sistema embebido (embedded), cloud.
- **Costo y licenciamiento:** software libre/open source vs. propietario.
- **Soporte:** duración del ciclo de vida, actualizaciones de seguridad, soporte comercial.
- **Compatibilidad:** aplicaciones y hardware disponibles.

## 2. Los grandes actores

### Linux

Linux es un **kernel** open source (licencia GPLv2). Combinado con herramientas GNU, un gestor de paquetes y otro software forma una **distribución (distro)**. Corre en casi cualquier plataforma: servidores, desktops, supercomputadoras, routers, autos y teléfonos (Android usa el kernel Linux).

### Windows

Sistema operativo propietario de Microsoft, dominante en el desktop corporativo y hogareño. Se distingue por:

- Versiones desktop (Windows 11) y server (Windows Server).
- Ciclo de releases regular y soporte extendido pago.
- Gran catálogo de software comercial y juegos.

### macOS

Sistema propietario de Apple, exclusivo para su hardware. Es un **UNIX certificado**: bajo la interfaz gráfica hay una línea de comandos muy parecida a la de Linux (shell `zsh`, comandos como `ls`, `grep`, `ssh`). Esto lo hace popular entre desarrolladores.

### Otros UNIX y BSD

- **FreeBSD, OpenBSD, NetBSD:** sistemas open source derivados de BSD UNIX, comunes en firewalls, appliances y servidores.
- **AIX (IBM), HP-UX, Oracle Solaris:** UNIX comerciales, hoy en nichos empresariales.

## 3. Distribuciones Linux

Una distribución empaqueta kernel + software + gestor de paquetes + configuración. Las principales familias:

| Familia | Distros destacadas | Gestor de paquetes | Uso típico |
|---|---|---|---|
| Debian | Debian, Ubuntu, Linux Mint, Raspberry Pi OS | `apt` / `.deb` | Desktop, server, educación |
| Red Hat | RHEL, Fedora, CentOS Stream, AlmaLinux, Rocky Linux | `dnf` / `.rpm` | Empresas, server |
| SUSE | SUSE Linux Enterprise, openSUSE | `zypper` / `.rpm` | Empresas (Europa) |
| Independientes | Arch Linux, Gentoo, Slackware | `pacman`, `portage`, etc. | Usuarios avanzados |

Ejemplo para identificar la distribución instalada:

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.2 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.2 LTS"
VERSION_ID="24.04"
```

Y para ver la versión del kernel:

```bash
$ uname -r
6.8.0-57-generic
```

### Enterprise vs. comunitarias

- **Enterprise (RHEL, SLES):** suscripción paga, soporte comercial, ciclos de vida de ~10 años. Ideales para producción.
- **Comunitarias (Debian, Fedora, Arch):** gratuitas, soporte de la comunidad. Fedora sirve además como "upstream" de pruebas para RHEL.

## 4. Ciclo de vida y modelos de release

Concepto clave del examen: cómo una distro publica versiones y por cuánto tiempo las mantiene.

- **Standard release (releases fijas):** versiones publicadas periódicamente con fecha de fin de soporte (EOL, *End of Life*). Ejemplo: Debian saca una versión mayor cada ~2 años.
- **LTS (Long Term Support):** releases con soporte extendido. Ubuntu LTS sale cada 2 años (24.04, 26.04…) con 5 años de soporte estándar; las versiones intermedias solo tienen 9 meses.
- **Rolling release:** no hay versiones; los paquetes se actualizan continuamente. Ejemplos: Arch Linux, openSUSE Tumbleweed. Software siempre reciente, pero menor previsibilidad — poco recomendable para servidores de producción.

Regla práctica: **estabilidad y soporte largo para servers (LTS/enterprise); software más nuevo para desktops de entusiastas (rolling o releases frecuentes como Fedora).**

## 5. Linux más allá del server y el desktop

- **Android:** el OS móvil más usado del mundo; usa el kernel Linux, aunque el resto del sistema (bionic, ART) difiere de una distro tradicional.
- **Sistemas embebidos e IoT:** routers (OpenWrt), Raspberry Pi (Raspberry Pi OS), Smart TVs, autos. Linux domina por ser gratuito, adaptable y de código abierto.
- **Cloud:** la mayoría de las instancias en AWS, Azure y Google Cloud corren Linux; existen imágenes optimizadas (Amazon Linux, Ubuntu Cloud Images).
- **ChromeOS:** el OS de Google para Chromebooks, basado en Linux (Gentoo), centrado en el navegador.

## 6. Criterios de decisión (resumen para el examen)

1. **¿Server o desktop?** Server → estabilidad y soporte largo (RHEL, Ubuntu LTS, Debian). Desktop → usabilidad y software actual (Ubuntu, Fedora, Mint).
2. **¿Presupuesto y soporte?** Con contrato de soporte → enterprise. Sin presupuesto → comunitaria.
3. **¿Ciclo de vida?** Verificar fechas de EOL antes de desplegar: correr un OS sin actualizaciones de seguridad es un riesgo.
4. **¿Compatibilidad?** Aplicaciones que solo existen en Windows/macOS pueden forzar la elección, o resolverse con virtualización/Wine.

---

## Referencias

- LPI Learning Materials – Tema 4.1 "Choosing an Operating System": https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- Objetivos oficiales del examen Linux Essentials (010-160 v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Documentación de Debian: https://www.debian.org/doc/
- Ciclo de vida de Ubuntu (releases y LTS): https://ubuntu.com/about/release-cycle
- Ciclo de vida de Red Hat Enterprise Linux: https://access.redhat.com/support/policy/updates/errata
- Arch Linux (modelo rolling release): https://wiki.archlinux.org/title/Arch_Linux
- Proyecto FreeBSD: https://www.freebsd.org/
- Kernel de Linux: https://www.kernel.org/