# 1.1 Linux Evolution and Popular Operating Systems

**Exam:** LPI Linux Essentials (010-160, version 1.6) — **Weight: 2**

---

## What Linux Is

Strictly speaking, **Linux is a kernel** — the core piece of software that manages hardware (CPU, memory, disks, network interfaces) and provides services to programs. What most people call "Linux" is really a **Linux distribution**: the kernel packaged together with system tools (largely from the **GNU project**), a package manager, documentation and, often, a graphical desktop.

A quick timeline:

- **1983** — Richard Stallman launches the **GNU Project** to build a free Unix-like operating system. By the early 1990s GNU had compilers, shells and utilities, but no finished kernel.
- **1991** — **Linus Torvalds**, a student in Helsinki, announces a hobby kernel inspired by MINIX. Combined with GNU userland tools, it forms a complete free operating system.
- **1992** — Linux is relicensed under the **GNU General Public License (GPL)**, which guarantees the freedom to use, study, modify and redistribute the code (a model known as **copyleft**).
- **Today** — Linux runs on everything from supercomputers (all of the TOP500 list) and cloud servers to Android phones, routers, TVs and Raspberry Pi boards.

You can always check which kernel a system runs:

```
$ uname -sr
Linux 6.8.0-45-generic
```

## Distributions

A **distribution (distro)** bundles the kernel with a package manager and a selected set of software. Distros form "families" that share packaging tools:

| Family | Key members | Package manager / format |
|---|---|---|
| Debian | Debian, **Ubuntu**, Linux Mint, Raspberry Pi OS | `apt` / `.deb` |
| Red Hat | RHEL, **Fedora**, CentOS Stream, Rocky, AlmaLinux | `dnf` (`yum`) / `.rpm` |
| SUSE | SLES, openSUSE | `zypper` / `.rpm` |
| Independent | Arch Linux, Gentoo, Slackware | `pacman`, `portage`, etc. |

Points worth remembering for the exam:

- **Debian** is community-driven and known for stability; **Ubuntu** (by Canonical) is derived from it and popular on desktops and cloud servers, with **LTS (Long Term Support)** releases every two years.
- **Red Hat Enterprise Linux (RHEL)** is a commercial, subscription-supported distro; **Fedora** is its fast-moving community upstream; Rocky and AlmaLinux are free rebuilds of RHEL.
- **Enterprise vs. consumer focus:** enterprise distros (RHEL, SLES, Ubuntu LTS) prioritize long support cycles and stability; others (Fedora, Arch) ship the latest software faster ("rolling" or short release cycles).

Identify the distribution on a running system:

```
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="22.04.4 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.4 LTS"
```

## Embedded Systems and Android

Linux dominates the **embedded** world — devices where the OS is invisible to the user:

- **Android** uses a modified Linux kernel with Google's own userland (no GNU tools by default; apps run on the Android Runtime). It is the world's most widely deployed Linux-kernel system.
- **Raspberry Pi** is a low-cost single-board computer commonly running Raspberry Pi OS (Debian-based); widely used for education and IoT projects.
- Routers, smart TVs, car infotainment systems and NAS devices typically run stripped-down Linux (e.g., **OpenWrt** on routers).

## Linux in the Cloud and on Servers

Linux is the standard platform for servers and cloud computing:

- Major cloud providers (AWS, Azure, Google Cloud) run most guest workloads on Linux virtual machines.
- **Virtualization** (KVM) and **containers** (Docker, Kubernetes) are Linux-native technologies that made the cloud model practical: containers share the host's Linux kernel, making them much lighter than full VMs.
- The classic **LAMP** stack (Linux, Apache, MySQL/MariaDB, PHP/Python/Perl) still powers a huge share of the web.

## Other Operating Systems (Comparison)

The exam expects you to place Linux among its neighbors:

- **Unix**: the 1970s Bell Labs OS that inspired Linux. Linux is "Unix-like" but shares no original code. Commercial Unixes (AIX, HP-UX, Solaris) still exist in niches.
- **BSD family** (FreeBSD, OpenBSD, NetBSD): also Unix-like and open source, but a complete OS (kernel + userland) under the permissive **BSD license**, which — unlike the GPL — allows proprietary derivatives (Apple's macOS has BSD roots).
- **macOS**: proprietary Apple OS built on Darwin (BSD/Mach heritage); POSIX-compliant, with a familiar Unix shell environment.
- **Windows**: proprietary Microsoft OS, dominant on corporate desktops; not Unix-like, though **WSL (Windows Subsystem for Linux)** now lets it run Linux distributions.

## Choosing an Operating System

Key decision factors the objective mentions:

1. **Release cycle and support lifetime** — an LTS/enterprise release for servers; a faster cycle if you need current software.
2. **Hardware and purpose** — embedded board, desktop, server, or cloud image.
3. **Cost and licensing** — free software vs. commercial subscriptions and proprietary licenses.
4. **Available skills and ecosystem** — package manager familiarity, vendor support, community documentation.

---

## Key Terms to Review

`kernel`, `distribution`, `GNU`, `GPL`, `open source`, `LTS`, `Android`, `Raspberry Pi`, `embedded systems`, `cloud computing`, `virtualization`, `containers`, `BSD`, `Unix-like`.

## Referencias

- LPI Learning Materials, Topic 1.1 — Linux Evolution and Popular Operating Systems: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- LPI Linux Essentials Exam 010-160 Objectives: https://www.lpi.org/our-certifications/exam-010-objectives/
- The Linux Kernel Archives: https://www.kernel.org/
- GNU Project — What is GNU?: https://www.gnu.org/
- GNU General Public License: https://www.gnu.org/licenses/gpl-3.0.html
- Debian: https://www.debian.org/ · Ubuntu: https://ubuntu.com/ · Fedora: https://fedoraproject.org/ · openSUSE: https://www.opensuse.org/
- Android Open Source Project: https://source.android.com/
- Raspberry Pi Foundation: https://www.raspberrypi.org/