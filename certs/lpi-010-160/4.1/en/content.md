# 4.1 Choosing an Operating System

## What Is an Operating System

An **operating system (OS)** is the software layer that manages hardware resources (CPU, memory, storage, peripherals) and provides a common interface for applications to run on. It handles process scheduling, memory management, file systems, device drivers, and user interaction (via a shell, GUI, or both). Every computer, phone, server, or embedded device needs one to be usable.

## Major Operating System Families

| Family | Examples | Typical use |
|---|---|---|
| Windows | Windows 10, Windows 11, Windows Server | Desktop, gaming, enterprise servers |
| macOS | macOS Sonoma, macOS Sequoia | Apple desktops/laptops |
| Unix / Unix-like | FreeBSD, OpenBSD, Solaris | Servers, appliances, research |
| Linux | Debian, Fedora, Ubuntu, Arch, openSUSE | Servers, desktops, embedded, cloud, mobile (via Android) |
| Android | Android (AOSP) | Smartphones, tablets, TVs, IoT — built on a Linux kernel |

Linux is not a single product but a **kernel** (created by Linus Torvalds in 1991) combined with GNU userland tools and other software to form a complete, usable system — commonly referred to as GNU/Linux.

## Understanding Linux Distributions

A **distribution** (distro) bundles the Linux kernel, system libraries, a package manager, and a curated set of applications into an installable, maintained product. Different distributions target different audiences, release philosophies, and package formats, but they all share the same kernel lineage.

### Distribution families

- **Debian-based**: Debian, Ubuntu, Linux Mint — use `.deb` packages, managed with `dpkg`/`apt`.
- **Red Hat-based**: Fedora, RHEL, Rocky Linux, AlmaLinux — use `.rpm` packages, managed with `rpm`/`dnf`.
- **SUSE-based**: openSUSE, SLES — `.rpm` packages, managed with `zypper`.
- **Arch-based**: Arch Linux, Manjaro — use `.pkg.tar.zst`, managed with `pacman`.

### Release models

- **Point release / fixed release**: a numbered version is frozen and receives only security/bug fixes until the next major version (e.g., Debian 12 "Bookworm", Ubuntu 22.04 LTS). Stable, predictable — favored for servers.
- **Rolling release**: packages are continuously updated to their latest versions with no fixed version number (e.g., Arch Linux, openSUSE Tumbleweed). Always current, but more prone to breakage — favored by users who want the newest software.

### Package manager comparison

```
# Debian/Ubuntu family
$ sudo apt install vim

# Fedora/RHEL family
$ sudo dnf install vim

# openSUSE
$ sudo zypper install vim

# Arch Linux
$ sudo pacman -S vim
```

## Desktop vs Server Distributions

The same distribution family often ships both **desktop** editions (GUI, desktop environment like GNOME or KDE preinstalled, drivers for consumer hardware) and **server** editions (minimal footprint, no GUI by default, optimized for reliability and long-term support). Example: Ubuntu Desktop vs Ubuntu Server, or Fedora Workstation vs Fedora Server. Servers typically favor LTS (Long Term Support) releases for extended patching windows.

## Choosing the Right OS for a Use Case

- **Desktop end users**: prioritize hardware support, application availability, and ease of use — Ubuntu, Fedora, Linux Mint are common choices.
- **Servers**: prioritize stability and long support cycles — Debian stable, Ubuntu LTS, RHEL/Rocky/AlmaLinux.
- **Embedded systems / IoT**: minimal, resource-constrained builds — Yocto-built images, OpenWrt, Raspberry Pi OS.
- **Cloud instances**: lightweight, cloud-init-ready images — Ubuntu Cloud, Amazon Linux, Fedora CoreOS.
- **Mobile**: Android (Linux kernel-based) dominates non-Apple mobile devices.

## Identifying the OS on a Running System

```
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.3 LTS"
VERSION_ID="22.04"
```

```
$ cat /etc/os-release
NAME="Fedora Linux"
VERSION="39 (Workstation Edition)"
ID=fedora
VERSION_ID=39
PRETTY_NAME="Fedora Linux 39 (Workstation Edition)"
```

```
$ uname -a
Linux server01 5.15.0-91-generic #101-Ubuntu SMP x86_64 GNU/Linux
```

```
$ hostnamectl
   Static hostname: server01
         Icon name: computer-vm
           Chassis: vm
    Virtualization: kvm
  Operating System: Ubuntu 22.04.3 LTS
            Kernel: Linux 5.15.0-91-generic
      Architecture: x86-64
```

- `/etc/os-release` — standardized file (freedesktop.org spec) identifying the distribution and version; the most reliable script-friendly source.
- `uname -a` — shows kernel name, version, and architecture (works on any Unix-like system, not distribution-specific).
- `hostnamectl` — on systemd-based distros, summarizes hostname, OS, kernel, and virtualization type in one command.

## Cloud Computing and Virtualization

Choosing an OS today often also means choosing a **deployment model**:

- **Virtualization**: a hypervisor (e.g., KVM, VMware, Hyper-V) runs one or more guest OS instances, each isolated with its own kernel, on shared hardware.
- **Containers**: share the host kernel and isolate only the userland (e.g., Docker, Podman) — lighter weight than full VMs, and why the base OS choice for a container image (Debian slim, Alpine, etc.) still matters.
- **Cloud service models**:
  - **IaaS** (Infrastructure as a Service): the provider supplies raw compute/storage/network; the customer chooses and manages the OS (e.g., AWS EC2, Azure VMs).
  - **PaaS** (Platform as a Service): the provider manages the OS and runtime; the customer only deploys application code (e.g., Heroku, AWS Elastic Beanstalk).
  - **SaaS** (Software as a Service): the provider manages everything, including the application (e.g., Google Workspace).

## Key Takeaways

- An OS manages hardware and provides the platform applications run on; Linux is a kernel around which many distributions are built.
- Distributions differ mainly in package management, release cycle, and target audience — not in the underlying kernel.
- Match the distribution to the task: LTS/stable for servers, rolling or desktop-focused for workstations, minimal images for embedded/cloud/containers.
- `/etc/os-release`, `uname -a`, and `hostnamectl` are the standard commands to identify OS and kernel details on a running Linux system.

## Referencias

- LPI Learning Materials — 4.1 Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- Debian Project: https://www.debian.org/
- Fedora Project: https://getfedora.org/
- openSUSE: https://www.opensuse.org/
- Arch Linux: https://archlinux.org/
- `os-release` specification (freedesktop.org / systemd): https://www.freedesktop.org/software/systemd/man/latest/os-release.html
- The Linux Kernel Archives: https://www.kernel.org/
- DistroWatch (distribution comparison): https://distrowatch.com/