# 1.2 Major Open Source Applications

**Peso en el examen:** 2
**Examen:** LPI Linux Essentials 010-160 (versión 1.6)

---

## Introducción

Uno de los pilares del ecosistema Linux es la enorme variedad de aplicaciones *open source* disponibles. Este tema repasa las aplicaciones más importantes en cuatro áreas: **escritorio**, **servidor**, **lenguajes de programación** y **gestión de paquetes**. Para el examen no hace falta dominar cada herramienta en profundidad, pero sí saber **qué hace cada una, a qué categoría pertenece y cuáles son sus alternativas**.

---

## 1. Aplicaciones de escritorio (Desktop Applications)

### Suites de oficina

- **LibreOffice**: la suite de oficina *open source* más difundida en Linux. Es un *fork* de OpenOffice.org mantenido por The Document Foundation. Sus componentes son:

| Componente | Función | Equivalente en MS Office |
|---|---|---|
| Writer | Procesador de texto | Word |
| Calc | Hoja de cálculo | Excel |
| Impress | Presentaciones | PowerPoint |
| Draw | Dibujo vectorial / diagramas | Visio |
| Base | Base de datos | Access |
| Math | Editor de fórmulas | Editor de ecuaciones |

LibreOffice usa por defecto el formato abierto **ODF (Open Document Format)**: `.odt` (texto), `.ods` (hoja de cálculo), `.odp` (presentación). También puede abrir y guardar formatos de Microsoft (`.docx`, `.xlsx`, `.pptx`).

### Navegadores web

- **Mozilla Firefox**: navegador *open source* desarrollado por la Mozilla Foundation.
- **Chromium**: la base *open source* sobre la que se construye Google Chrome (Chrome en sí incluye componentes propietarios).

### Multimedia y gráficos

- **GIMP (GNU Image Manipulation Program)**: edición de imágenes rasterizadas (mapa de bits). Alternativa a Adobe Photoshop.
- **Inkscape**: gráficos vectoriales (formato SVG). Alternativa a Adobe Illustrator.
- **Blender**: modelado, animación y renderizado 3D.
- **VLC**: reproductor multimedia que soporta prácticamente cualquier formato de audio y video.
- **Audacity**: grabación y edición de audio.
- **ImageMagick**: manipulación de imágenes desde la línea de comandos. Ejemplo:

```bash
$ convert foto.png -resize 800x600 foto_chica.jpg
```

### Correo electrónico

- **Mozilla Thunderbird**: cliente de correo de escritorio con soporte para IMAP, POP3, calendarios y feeds RSS.

---

## 2. Aplicaciones de servidor (Server Applications)

Linux domina el mundo de los servidores, y estas son las aplicaciones que hay que reconocer:

### Servidores web

- **Apache HTTP Server (httpd)**: históricamente el servidor web más usado del mundo, mantenido por la Apache Software Foundation.
- **NGINX**: servidor web y *reverse proxy* de alto rendimiento, muy popular en sitios de alto tráfico y como balanceador de carga.

### Bases de datos

- **MariaDB**: base de datos relacional (RDBMS), *fork* comunitario de **MySQL** creado tras la compra de MySQL por Oracle. Usa el lenguaje **SQL**.
- **PostgreSQL**: RDBMS avanzado, reconocido por su cumplimiento de estándares y robustez.

Ejemplo de consulta SQL (válida en ambos):

```sql
SELECT nombre, email FROM usuarios WHERE activo = 1;
```

### Compartición de archivos e impresión

- **Samba**: implementa el protocolo **SMB/CIFS**, lo que permite que un servidor Linux comparta archivos e impresoras con clientes Windows, e incluso actúe como controlador de dominio Active Directory.
- **NFS (Network File System)**: protocolo nativo de Unix/Linux para compartir sistemas de archivos por red.
- **CUPS**: sistema de impresión estándar en Linux.

### Correo (MTA — Mail Transfer Agent)

- **Postfix**: el MTA más usado hoy en día; diseñado como reemplazo seguro y simple de Sendmail.
- **Sendmail**: el MTA histórico de Unix.
- **Exim**: otro MTA popular, usado por defecto en Debian durante muchos años.

### Nube privada y virtualización

- **Nextcloud / ownCloud**: plataformas de almacenamiento y colaboración en la nube autoalojadas (Nextcloud es un *fork* de ownCloud). Alternativa *open source* a Dropbox o Google Drive.
- **OpenStack**: plataforma para construir nubes IaaS (Infrastructure as a Service).

---

## 3. Lenguajes de programación

Para el examen conviene distinguir entre lenguajes **compilados** e **interpretados**:

| Lenguaje | Tipo | Uso típico |
|---|---|---|
| C | Compilado | El kernel de Linux y la mayoría de las utilidades del sistema |
| C++ | Compilado | Aplicaciones de escritorio, juegos, software de alto rendimiento |
| Java | Compilado a *bytecode* (JVM) | Aplicaciones empresariales |
| Python | Interpretado | Scripting, automatización, ciencia de datos, web |
| Perl | Interpretado | Procesamiento de texto, administración de sistemas |
| PHP | Interpretado | Desarrollo web del lado del servidor (WordPress, etc.) |
| JavaScript | Interpretado | Desarrollo web (navegador y servidor con Node.js) |
| Shell (Bash) | Interpretado | Automatización de tareas del sistema |

Ejemplo de script en **Bash**:

```bash
#!/bin/bash
for archivo in *.log; do
    echo "Comprimiendo $archivo"
    gzip "$archivo"
done
```

Ejemplo en **Python**:

```python
#!/usr/bin/env python3
for i in range(3):
    print(f"Iteración {i}")
```

Salida:

```
Iteración 0
Iteración 1
Iteración 2
```

---

## 4. Gestión de paquetes (Package Management)

El software en Linux se instala normalmente desde **repositorios** mediante un **gestor de paquetes**, que resuelve dependencias automáticamente. Existen dos grandes familias:

### Familia Debian (Debian, Ubuntu, Linux Mint)

- Formato de paquete: **`.deb`**
- Herramienta de bajo nivel: **`dpkg`**
- Herramienta de alto nivel (resuelve dependencias y descarga de repositorios): **`apt`** (o `apt-get`)

```bash
$ sudo apt update              # actualiza la lista de paquetes
$ sudo apt install gimp        # instala GIMP con sus dependencias
$ sudo apt remove gimp         # desinstala el paquete
$ dpkg -l | grep gimp          # lista paquetes instalados que coinciden
```

Salida de ejemplo:

```
ii  gimp    2.10.34-1    amd64    GNU Image Manipulation Program
```

### Familia Red Hat (RHEL, Fedora, CentOS Stream, openSUSE*)

- Formato de paquete: **`.rpm`**
- Herramienta de bajo nivel: **`rpm`**
- Herramienta de alto nivel: **`dnf`** (sucesor de `yum`); en openSUSE se usa **`zypper`**

```bash
$ sudo dnf install gimp        # instala GIMP
$ sudo dnf upgrade             # actualiza todo el sistema
$ rpm -qa | grep gimp          # consulta paquetes instalados
```

**Regla nemotécnica para el examen:** `.deb` ↔ `dpkg`/`apt` (Debian/Ubuntu); `.rpm` ↔ `rpm`/`dnf`/`yum` (Red Hat/Fedora).

### Formatos universales

También existen formatos de paquete independientes de la distribución: **Flatpak**, **Snap** y **AppImage**, que incluyen sus propias dependencias y funcionan en casi cualquier distribución.

---

## Puntos clave para el examen

- Saber **asociar cada aplicación con su categoría**: LibreOffice → oficina; GIMP → edición de imágenes; Apache/NGINX → servidor web; MariaDB/PostgreSQL → base de datos; Samba → compartir archivos con Windows; Postfix → correo.
- Reconocer los **formatos ODF** de LibreOffice (`.odt`, `.ods`, `.odp`).
- Distinguir lenguajes **compilados** (C, C++) de **interpretados** (Python, Perl, PHP, Bash, JavaScript).
- Dominar la correspondencia **distribución ↔ formato de paquete ↔ herramienta** (`apt`/`.deb` vs. `dnf`/`.rpm`).
- Recordar los *forks* famosos: **MariaDB** (de MySQL), **LibreOffice** (de OpenOffice.org), **Nextcloud** (de ownCloud).

---

## Referencias

- LPI Learning Materials — Topic 1.2: Major Open Source Applications: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- Objetivos del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- LibreOffice — Documentación oficial: https://documentation.libreoffice.org/
- GIMP — Documentación: https://docs.gimp.org/
- Apache HTTP Server — Documentación: https://httpd.apache.org/docs/
- NGINX — Documentación: https://nginx.org/en/docs/
- MariaDB — Documentación: https://mariadb.com/kb/en/documentation/
- PostgreSQL — Documentación: https://www.postgresql.org/docs/
- Samba — Documentación: https://www.samba.org/samba/docs/
- Postfix — Documentación: https://www.postfix.org/documentation.html
- Python — Documentación oficial: https://docs.python.org/3/
- Manual de APT (Debian): https://wiki.debian.org/Apt
- Documentación de DNF (Fedora): https://docs.fedoraproject.org/en-US/quick-docs/dnf/