# 4.1 Choosing an Operating System

**Exam weight: 1** — a light topic. Expect one or two questions on the differences between Linux, Windows, and macOS, the concept of a distribution, the role of the kernel, and how release/support cycles influence the choice of an OS.

---

## 1. What Is an Operating System?

An **operating system (OS)** is the software layer that sits between the hardware and the applications. Its core, the **kernel**, manages the CPU, memory, storage, and devices, and provides services that programs use instead of talking to the hardware directly. Around the kernel, an OS ships system libraries, command-line tools, and usually a graphical interface.

Strictly speaking, **Linux is only a kernel**. What people install is a **distribution** (distro): the Linux kernel packaged together with the GNU tools, a package manager, an installer, and a selection of applications.

## 2. The Main Operating System Families

### 2.1 Linux

- **Open source** (mostly GPL-licensed): anyone can read, modify, and redistribute the code.
- Runs on everything from supercomputers and cloud servers to phones (Android uses the Linux kernel), routers, TVs, and embedded devices (IoT).
- Hundreds of distributions exist because anyone can build one; they differ mainly in package format, release model, default software, and support.

### 2.2 Unix and Unix-like systems

Linux is *Unix-like*: it follows the design and standards (POSIX) of the original AT&T Unix without sharing its code. Other members of the family:

- **BSD variants** — FreeBSD, OpenBSD, NetBSD: open source, permissively licensed, common in firewalls, storage appliances, and servers.
- **Commercial Unix** — AIX (IBM), HP-UX, Oracle Solaris: proprietary, tied to specific vendor hardware, declining but still present in legacy enterprise environments.

### 2.3 macOS

Apple's desktop OS. It is a certified Unix built on the Darwin/XNU kernel with BSD userland components, so the Terminal feels familiar to Linux users (`ls`, `grep`, `ssh` all work). It is **proprietary** and only licensed to run on Apple hardware.

### 2.4 Windows

Microsoft's proprietary OS, dominant on corporate and home desktops. Key contrasts with Linux:

| Aspect | Linux | Windows |
|---|---|---|
| License | Open source (GPL and others) | Proprietary, paid licenses |
| Configuration | Plain-text files (e.g., `/etc/`) | Registry + GUI tools |
| Path separator | `/home/user/file` | `C:\Users\user\file` |
| Default shell | Bash (or similar) | PowerShell / cmd.exe |
| Case sensitivity | `File` ≠ `file` | `File` = `file` |
| Line endings | LF (`\n`) | CRLF (`\r\n`) |

Windows has narrowed the gap with **WSL** (Windows Subsystem for Linux), which runs a real Linux environment inside Windows.

## 3. Linux Distributions

A distribution bundles kernel + package manager + tooling + support policy. The major families:

| Family | Package format / manager | Representative distros | Typical use |
|---|---|---|---|
| **Debian** | `.deb` — `apt`, `dpkg` | Debian, **Ubuntu**, Linux Mint, Raspberry Pi OS | Desktops, servers, education, SBCs |
| **Red Hat** | `.rpm` — `dnf`, `rpm` | RHEL, **Fedora**, CentOS Stream, Rocky, AlmaLinux | Enterprise servers, workstations |
| **SUSE** | `.rpm` — `zypper` | SUSE Linux Enterprise, openSUSE | Enterprise (strong in Europe) |
| **Independent / rolling** | varies — `pacman`, `emerge` | Arch Linux, Gentoo | Enthusiasts, bleeding-edge |

You can identify the running distribution from the shell:

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.2 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.2 LTS"
VERSION_ID="24.04"
```

And the kernel version with:

```bash
$ uname -r
6.8.0-57-generic
```

### 3.1 Android

Android is the most widely deployed Linux-based OS. It uses the Linux kernel but replaces the GNU userland with its own libraries and a Java/Kotlin application framework, so it doesn't behave like a typical desktop distribution.

## 4. Criteria for Choosing an OS

The exam expects you to reason about *why* an organization picks one system over another:

1. **Purpose** — desktop productivity, server workload, embedded device, or mobile. Linux dominates servers and embedded; Windows/macOS dominate office desktops.
2. **Cost** — license fees (Windows, commercial Unix) vs. free software with optional **paid support subscriptions** (RHEL, SLES, Ubuntu Pro).
3. **Application availability** — some commercial applications only exist for Windows or macOS; most server-side software targets Linux first.
4. **Hardware support** — drivers for very new or very exotic hardware may lag on Linux; macOS runs only on Apple machines.
5. **Skills available** — the OS your team can administer is cheaper to operate than a theoretically better one nobody knows.
6. **Support lifecycle** — how long the vendor ships security updates (see below).

## 5. Release Models and Support Lifecycles

This is the most exam-relevant part of the topic:

- **Fixed releases** — a new version ships on a schedule and receives updates for a defined period. Example: Ubuntu publishes an **LTS (Long Term Support)** release every two years (24.04, 26.04, …) with **5 years** of standard support, plus interim releases supported only 9 months. RHEL major versions get about **10 years**.
- **Rolling releases** — no versions; packages update continuously (Arch Linux, openSUSE Tumbleweed). Always current, but requires more frequent maintenance and carries more regression risk — rarely chosen for production servers.
- **Beta / stable / backports**:
  - A **beta** version is a preview for testing; never for production.
  - A **stable** release changes as little as possible; it receives **security fixes**, not new features.
  - A **backport** is a fix or feature from a newer version recompiled for an older stable release, so users get the fix without upgrading the whole system.

**Rule of thumb:** servers favor long-support stable releases (Ubuntu LTS, RHEL, Debian stable); developers and enthusiasts who want the latest software favor rapid or rolling releases (Fedora, Arch).

## 6. Quick Exam Checkpoints

- Linux = kernel; distribution = kernel + tools + package manager.
- Android runs the Linux kernel; macOS is a proprietary certified Unix.
- Debian family uses `.deb`/`apt`; Red Hat family uses `.rpm`/`dnf`.
- LTS = long-term support: fewer features, longer security updates — the server choice.
- Beta = testing only; backport = newer fix applied to an older stable release.
- Windows differs from Linux in paths (`\` vs `/`), case sensitivity, line endings, and text-file configuration.

---

## Referencias

- LPI Learning Materials, Topic 4.1 — Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- LPI Linux Essentials Objectives (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Ubuntu release cycle: https://ubuntu.com/about/release-cycle
- Red Hat Enterprise Linux life cycle: https://access.redhat.com/support/policy/updates/errata
- Debian releases: https://www.debian.org/releases/
- The Linux Kernel Archives: https://www.kernel.org/
- `os-release` specification (freedesktop.org): https://www.freedesktop.org/software/systemd/man/latest/os-release.html