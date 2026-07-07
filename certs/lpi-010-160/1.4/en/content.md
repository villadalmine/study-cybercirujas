# 1.4 ICT Skills and Working in Linux

**Exam:** LPI Linux Essentials 010-160 (version 1.6) · **Weight:** 2

## Objective Overview

This topic covers the basic Information and Communication Technology (ICT) skills you need to work productively and safely on a Linux system. The exam expects you to know:

- **Desktop skills** — working with a graphical desktop environment and common open source applications.
- **Getting to the command line** — the difference between a terminal, a console, and a shell, and how to reach each one.
- **Industry uses of Linux** — where Linux runs in the real world, including cloud computing and virtualization.
- Practical **privacy and security awareness**: browser configuration, cookies, passwords, and encryption tools.

---

## 1. Desktop Skills

Linux offers several desktop environments — complete graphical interfaces with a window manager, panels, and a suite of applications. The most common are:

| Desktop environment | Notes |
|---|---|
| **GNOME** | Default on Fedora, Ubuntu, RHEL; minimalist workflow |
| **KDE Plasma** | Highly configurable; default on Kubuntu, openSUSE |
| **Xfce / LXDE / LXQt** | Lightweight; good for older hardware |
| **Cinnamon / MATE** | Traditional desktop layout; default on Linux Mint |

Unlike Windows or macOS, the desktop is a replaceable component: the same distribution can run any of these. Regardless of which one you use, the core skills are the same — launching applications, managing windows and workspaces, browsing files with a file manager (e.g., GNOME Files/Nautilus, Dolphin), and logging in through a **display manager** (the graphical login screen, such as GDM or SDDM).

### Common Open Source Applications

For everyday productivity, projects, and presentations you should recognize these applications:

- **LibreOffice** — full office suite: Writer (documents), Calc (spreadsheets), Impress (presentations), Base (databases), Draw (diagrams). Uses the OpenDocument Format (`.odt`, `.ods`, `.odp`) and can read/write Microsoft Office formats.
- **Mozilla Firefox** and **Chromium** — web browsers.
- **Mozilla Thunderbird** — email client.
- **GIMP** — raster image editing (a Photoshop alternative); **Inkscape** for vector graphics.
- **VLC** — media player.

Knowing these lets you produce documents, slides, and graphics for a project entirely with open source software.

## 2. Getting to the Command Line

Much of the power of Linux is in its command line. Three terms are frequently confused; the exam expects you to distinguish them:

- **Shell** — the program that interprets your commands. The default on most distributions is **Bash** (`/bin/bash`).
- **Terminal (terminal emulator)** — a graphical application that gives you access to a shell inside the desktop. Examples: GNOME Terminal, Konsole, xterm.
- **Console (virtual console/terminal)** — a full-screen text session provided directly by the system, no GUI needed. Linux typically provides several, reachable with `Ctrl`+`Alt`+`F1` through `F6` (the graphical session usually occupies one of these, often F1 or F7 depending on the distribution).

A shell **prompt** ends in `$` for a regular user and `#` for the root user:

```
user@mainbox:~$ whoami
user
user@mainbox:~$ echo $SHELL
/bin/bash
```

### Remote Access with SSH

Administrators rarely sit in front of the servers they manage. The standard tool for remote command-line access is **OpenSSH** (Secure Shell), which encrypts the whole session:

```
$ ssh user@server.example.com
user@server.example.com's password:
Last login: Mon Jul  6 09:12:44 2026 from 192.168.1.10
user@server:~$
```

SSH replaced older, insecure protocols such as Telnet, which transmitted passwords in plain text.

## 3. Industry Uses of Linux, Cloud Computing and Virtualization

Linux is everywhere in industry, even where it is not visible:

- **Servers** — the majority of web servers, DNS servers, and database servers run Linux.
- **Cloud computing** — Linux dominates public cloud infrastructure. Providers like AWS, Google Cloud, and Azure run enormous fleets of Linux machines, and most virtual machine instances customers launch are Linux.
- **Virtualization** — one physical machine runs many **virtual machines (VMs)** on a **hypervisor**. Linux includes its own hypervisor, **KVM** (Kernel-based Virtual Machine); other examples are Xen and VirtualBox.
- **Containers** — a lighter-weight alternative to VMs. Technologies such as **Docker** and orchestration with **Kubernetes** are built on Linux kernel features (namespaces, cgroups).
- **Embedded devices and mobile** — Android is based on the Linux kernel; routers, smart TVs, and IoT devices commonly run Linux.
- **Supercomputers** — effectively all of the TOP500 supercomputers run Linux.

The key idea for the exam: cloud computing means renting computing resources (servers, storage, services) that run in a provider's data center, and virtualization is the technology that makes it efficient — many isolated systems sharing one physical machine.

## 4. Privacy and Security Basics

### Browser Privacy

When you browse the web, sites store **cookies** — small pieces of data used for sessions and preferences, but also for tracking you across sites (**third-party cookies**). You should know how to:

- Review and delete cookies and browsing history in the browser settings.
- Block third-party cookies.
- Use **private/incognito mode**, which discards history and cookies when the window closes — note that it does *not* make you anonymous to websites or your network provider.
- Recognize **HTTPS** (the padlock icon): the connection to the site is encrypted with **TLS**. Prefer HTTPS sites whenever you submit any data.
- Use search engines and save web content (bookmarks, page downloads) responsibly.

### Passwords

Good password hygiene is an exam-relevant skill:

- Use **long passwords or passphrases** — length matters more than exotic symbols.
- Never reuse the same password across services.
- Use a **password manager** (e.g., KeePassXC) to generate and store unique passwords.
- Change a password on Linux with the `passwd` command:

```
$ passwd
Changing password for user.
Current password:
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
```

- Enable **two-factor authentication (2FA)** where available.

### Encryption

Two encryption tools you should be able to name and describe:

- **GnuPG (GPG)** — encrypts and signs files and email using public-key cryptography. Example, encrypting a file symmetrically with a passphrase:

```
$ gpg -c secret-notes.txt
$ ls
secret-notes.txt  secret-notes.txt.gpg
```

- **OpenSSH** — besides remote login, it encrypts file transfers with `scp` and `sftp`.

Encryption protects data **in transit** (TLS/HTTPS, SSH) and **at rest** (GPG-encrypted files, encrypted disks with LUKS).

---

## Quick Review

- A **shell** interprets commands; a **terminal emulator** runs a shell in the GUI; a **virtual console** (`Ctrl`+`Alt`+`F1`–`F6`) is a text session outside the GUI.
- `$` prompt = regular user; `#` prompt = root.
- **LibreOffice** = office suite; **GIMP** = image editing; **Firefox/Thunderbird** = browsing/email.
- Linux dominates **servers, cloud, containers, embedded, and supercomputers**; **KVM** is the Linux kernel's hypervisor.
- Private browsing deletes local traces only; **HTTPS** encrypts traffic to the site.
- Use **strong unique passwords**, a **password manager**, `passwd` to change your password, and **GPG/SSH** for encryption.

## Referencias

- LPI Learning Materials, Topic 1.4 — ICT Skills and Working in Linux: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- LPI Linux Essentials Exam 010-160 Objectives: https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Manual: https://www.gnu.org/software/bash/manual/
- OpenSSH Documentation: https://www.openssh.com/manual.html
- GnuPG Documentation: https://gnupg.org/documentation/
- LibreOffice Documentation: https://documentation.libreoffice.org/en/english-documentation/
- KVM (Kernel-based Virtual Machine): https://linux-kvm.org/page/Main_Page
- Mozilla Firefox Privacy Settings: https://support.mozilla.org/en-US/kb/enhanced-tracking-protection-firefox-desktop