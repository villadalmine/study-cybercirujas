# 1.2 Major Open Source Applications

**Exam weight: 2** — Linux Essentials 010-160, version 1.6

## Overview

Linux is only the kernel of the operating system; almost everything users interact with is application software layered on top of it. This topic covers the most important open source applications you should be able to recognize and classify: desktop programs, server software, programming languages, and the package management tools used to install and maintain all of them.

For the exam you need to know **what each application does** and **which category it belongs to** — not how to administer it in depth.

---

## Desktop Applications

Open source desktop software covers every common productivity need and is often cross-platform (available for Windows and macOS as well).

### Office suites

- **LibreOffice** — the leading open source office suite, a fork of the older OpenOffice.org project. Its components mirror proprietary suites:
  - *Writer* (word processing), *Calc* (spreadsheets), *Impress* (presentations), *Draw* (vector drawing), *Base* (databases), *Math* (formula editing).
  - Uses the **Open Document Format (ODF)** as its native file format (`.odt`, `.ods`, `.odp`), an open ISO standard, while also reading and writing Microsoft Office formats (`.docx`, `.xlsx`, `.pptx`).

### Web browsers

- **Mozilla Firefox** — fully open source browser developed by the Mozilla Foundation.
- **Google Chrome / Chromium** — *Chromium* is the open source project on which the proprietary *Chrome* browser is built. Many other browsers (Edge, Opera, Brave) also derive from Chromium.

### Email clients

- **Mozilla Thunderbird** — full-featured desktop mail client supporting **IMAP**, **POP3**, and **SMTP**, plus calendars, contacts, and news feeds.
- Webmail is common today, but desktop clients remain relevant in corporate environments.

### Multimedia and graphics

- **GIMP** (GNU Image Manipulation Program) — raster image editor, the open source counterpart to Adobe Photoshop.
- **Inkscape** — vector graphics editor (counterpart to Adobe Illustrator).
- **Blender** — 3D modeling, animation, and rendering.
- **VLC** — media player that handles virtually any audio/video format.
- **Audacity** — audio recording and editing.
- **ImageMagick** — command-line image conversion and manipulation:

```bash
$ convert photo.png -resize 800x600 photo-small.jpg
$ identify photo.png
photo.png PNG 1920x1080 1920x1080+0+0 8-bit sRGB 2.1MiB 0.000u 0:00.000
```

---

## Server Applications

Linux dominates the server market, and most of the Internet's infrastructure runs on the open source applications below.

### Web servers

- **Apache HTTP Server (httpd)** — historically the most widely deployed web server; extensible through modules (e.g. `mod_ssl`, `mod_rewrite`).
- **NGINX** — newer web server designed for high concurrency; also commonly used as a **reverse proxy** and load balancer.

A running web server is easy to spot:

```bash
$ ss -tlnp | grep :80
LISTEN 0  511  0.0.0.0:80  0.0.0.0:*  users:(("nginx",pid=1234,fd=6))
```

### Databases

Web applications typically store their data in a relational database (the classic **LAMP** stack = Linux + Apache + MySQL + PHP):

- **MySQL / MariaDB** — MariaDB is a community fork of MySQL, created after MySQL was acquired by Oracle; it is a drop-in replacement and the default on many distributions.
- **PostgreSQL** — advanced, standards-focused relational database, valued for data integrity and SQL feature completeness.
- **SQLite** — lightweight embedded database stored in a single file, used inside countless applications rather than as a standalone server.

```bash
$ mysql -u root -p
Enter password:
Welcome to the MariaDB monitor.  Commands end with ; or \g.
MariaDB [(none)]> SHOW DATABASES;
```

### File sharing and network services

- **Samba** — implements the **SMB/CIFS** protocol, letting a Linux server share files and printers with Windows clients, and even act as an Active Directory domain controller.
- **NFS** (Network File System) — the traditional UNIX/Linux protocol for sharing filesystems between Linux/UNIX machines.
- **OpenSSH** — secure remote shell access and file transfer (`ssh`, `scp`, `sftp`).
- **Postfix** and **Exim** — mail transfer agents (**MTA**) that route email between servers via SMTP (successors to the older *Sendmail*).
- **Dovecot** — IMAP/POP3 server that delivers stored mail to clients.
- **Nextcloud / ownCloud** — self-hosted file synchronization and collaboration platforms (open source alternative to Dropbox/Google Drive).

### Cloud and virtualization

- **KVM** — the Linux kernel's built-in virtualization hypervisor.
- **Docker / Podman** — container engines for packaging and running applications in isolated environments.
- **OpenStack** — a platform for building private clouds (Infrastructure as a Service).
- **Kubernetes** — orchestration of containers across clusters of machines.

---

## Development Languages

Linux systems ship with, or make easily available, many programming languages. The exam expects you to recognize the major ones:

| Language | Type | Typical use on Linux |
|---|---|---|
| **Shell (Bash)** | Interpreted | System automation, glue scripts, the default interactive shell |
| **C** | Compiled | The kernel itself and most core system utilities |
| **C++** | Compiled | Desktop environments, browsers, performance-critical software |
| **Python** | Interpreted | Automation, scientific computing, web backends, system tools (e.g. `dnf` is written in Python) |
| **Perl** | Interpreted | Text processing, legacy system scripts |
| **PHP** | Interpreted | Server-side web development (the "P" in LAMP; powers WordPress) |
| **JavaScript** | Interpreted | Web frontends in the browser; server-side via Node.js |
| **Java** | Compiled to bytecode | Enterprise applications, Android development |

A first shell script illustrates the interpreted model — the `#!` (*shebang*) line names the interpreter:

```bash
$ cat hello.sh
#!/bin/bash
echo "Hello, $USER"
$ chmod +x hello.sh
$ ./hello.sh
Hello, carol
```

Compiled languages instead go through a compiler such as **GCC** (GNU Compiler Collection) before they can run:

```bash
$ gcc hello.c -o hello
$ ./hello
Hello, world
```

---

## Package Management

Almost all software on a Linux system is installed from **packages**: archives containing the program's files plus metadata (version, dependencies, checksums). Packages come from **repositories** — servers maintained by the distribution that host thousands of tested packages. The package manager downloads packages, resolves **dependencies** automatically, and tracks every installed file.

There are two dominant package families:

### Debian family (`.deb`) — Debian, Ubuntu, Linux Mint

- **`dpkg`** — the low-level tool that installs individual `.deb` files.
- **`apt`** — the high-level tool that talks to repositories and resolves dependencies.

```bash
$ sudo apt update                # refresh repository metadata
$ sudo apt install firefox       # install with dependencies
$ sudo apt upgrade               # update all installed packages
$ apt search image editor        # find packages
$ sudo apt remove firefox        # uninstall
```

### Red Hat family (`.rpm`) — RHEL, Fedora, CentOS Stream, openSUSE

- **`rpm`** — the low-level tool for individual `.rpm` files.
- **`dnf`** — the high-level repository tool on Fedora/RHEL (successor of `yum`); openSUSE uses **`zypper`**.

```bash
$ sudo dnf install gimp
$ sudo dnf upgrade
$ dnf search gimp
$ sudo dnf remove gimp
```

### Distribution-independent formats

Newer formats bundle an application together with its dependencies so a single package runs on any distribution: **Snap**, **Flatpak**, and **AppImage**.

**Key point for the exam:** match the tool to the family — `dpkg`/`apt` ↔ Debian/Ubuntu, `rpm`/`dnf`/`yum`/`zypper` ↔ Red Hat/SUSE. Mixing package formats across families is not supported.

---

## Quick Review

- **LibreOffice** = office suite (ODF native format); **GIMP** = image editing; **Firefox/Chromium** = browsers; **Thunderbird** = email client.
- **Apache** and **NGINX** serve the web; **MariaDB/MySQL** and **PostgreSQL** store its data; **Samba** shares files with Windows; **NFS** shares files between Linux systems.
- **LAMP** = Linux, Apache, MySQL, PHP — the classic open source web stack.
- Interpreted languages (Bash, Python, Perl, PHP, JavaScript) run through an interpreter; compiled languages (C, C++) are built with GCC.
- Packages + repositories + dependency resolution = how Linux installs software; know both package families and their tools.

---

## Referencias

- LPI Learning Materials — Topic 1.2 Major Open Source Applications: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- LPI Linux Essentials exam objectives (010-160 v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- LibreOffice documentation: https://documentation.libreoffice.org/
- GIMP documentation: https://docs.gimp.org/
- Apache HTTP Server documentation: https://httpd.apache.org/docs/
- NGINX documentation: https://nginx.org/en/docs/
- MariaDB documentation: https://mariadb.org/documentation/
- PostgreSQL documentation: https://www.postgresql.org/docs/
- Samba documentation: https://www.samba.org/samba/docs/
- Debian package management (apt): https://www.debian.org/doc/manuals/debian-faq/pkgtools.en.html
- Fedora DNF documentation: https://docs.fedoraproject.org/en-US/quick-docs/dnf/