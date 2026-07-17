# Exercises — Topic 4.1: Choosing an Operating System

**Certification:** LPI Linux Essentials (010-160, v1.6)
**Objective weight:** 1

These exercises use hands-on commands on a running Linux system (a real machine, a VM, or a cloud instance) to reinforce the concepts behind Objective 4.1: what an operating system is, how Linux distributions differ from one another, how Linux compares to other OS families, and where Linux runs.

---

## Exercise 1 — Identify your distribution and kernel

1. Open a terminal.
2. Print the contents of the distribution identification file:
   ```
   cat /etc/os-release
   ```
3. Print detailed kernel and system information:
   ```
   uname -a
   ```
4. If available, print a human-readable summary:
   ```
   hostnamectl
   ```

**Check your understanding**
- In the output of `uname -a`, which field identifies the *kernel*, and which field(s) come from the *distribution* rather than the kernel itself?
- Two different distributions (for example Ubuntu and Fedora) can report the exact same kernel version. What does that tell you about the relationship between "Linux" and a "distribution"?

---

## Exercise 2 — Distinguish the OS kernel from the complete system

1. Check which shell you are using:
   ```
   echo $SHELL
   ```
2. Check which core utilities package provides basic commands like `ls` and `cp`:
   ```
   ls --version
   ```
   (the first line usually names the package, e.g. "GNU coreutils")
3. Compare this to the kernel version reported by:
   ```
   uname -r
   ```

**Check your understanding**
- `ls` reported it comes from a "GNU" package, while `uname -r` reported a version number for "Linux." Why do many people argue the OS should be called "GNU/Linux" rather than just "Linux"?
- Is the shell (`bash`, `zsh`, etc.) part of the kernel, part of the GNU toolset, or a separate component entirely?

---

## Exercise 3 — Explore your distribution's package manager

1. Determine which package manager your distribution uses by trying the commands relevant to your system:
   - Debian/Ubuntu family:
     ```
     apt --version
     dpkg --version
     ```
   - Red Hat/Fedora family:
     ```
     dnf --version
     rpm --version
     ```
   - openSUSE family:
     ```
     zypper --version
     ```
2. List a small number of installed packages using the tool you identified (e.g. `dpkg -l | head` or `rpm -qa | head`).

**Check your understanding**
- Package managers and package formats (`.deb` vs `.rpm`) differ between distribution families even though the underlying kernel is the same Linux kernel. Why does this happen?
- Name one distribution from the Debian family and one from the Red Hat family.

---

## Exercise 4 — Check interoperability with other operating system families

1. Check whether your system can read a common cross-platform file format by inspecting a file's type:
   ```
   file /bin/ls
   ```
2. Check whether Samba client tools are available, which let Linux interoperate with Windows file/print sharing:
   ```
   which smbclient
   ```
   (if not installed, just note that this tool exists for this purpose — no need to install it)
3. Check whether your system can resolve and reach a host on the local network, simulating access to a mixed-OS environment:
   ```
   ping -c 3 <a hostname or IP on your network>
   ```

**Check your understanding**
- Why is it useful for a Linux machine to be able to speak the SMB/CIFS protocol used natively by Microsoft Windows?
- Give one example of how Linux, Windows, and macOS machines can coexist and share resources on the same network.

---

## Exercise 5 — Identify the devices and environments Linux can run on

1. Check your system's CPU architecture:
   ```
   uname -m
   ```
2. Check whether you are running inside a virtual machine or container (useful for understanding cloud deployments):
   ```
   systemd-detect-virt
   ```
   (if the tool reports "none," you are on bare metal)
3. Check the number of CPUs and basic virtualization support flags:
   ```
   lscpu | grep -i virtualization
   ```

**Check your understanding**
- `uname -m` might report `x86_64`, `aarch64`, or `armv7l`. Which of these architectures is most associated with embedded devices and smartphones?
- Android phones run a modified Linux kernel. Based on what you observed about kernel vs. distribution vs. package manager in Exercises 1–3, explain why Android is considered Linux-based but is *not* a traditional Linux distribution.
- Name three different classes of devices (besides a desktop PC) that can run Linux.

---

## References

- LPI Learning Materials, Topic 4.1 — Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- In `uname -a`, the kernel is identified by the `Linux` name plus the version string right after it (e.g. `5.15.0-91-generic`). The rest of the line — machine hardware name, and especially anything from `/etc/os-release` (`NAME`, `VERSION`, `PRETTY_NAME`) — describes the *distribution*, not the kernel.
- This shows that the kernel and the distribution are independent layers: the kernel is the shared core, while the distribution is the collection of software, defaults, and tools built around that kernel. Different distributions can ship the same kernel version.

**Exercise 2**
- Many core command-line tools (`ls`, `cp`, `bash`, etc.) come from the GNU Project, while the kernel itself is developed separately by Linus Torvalds and the kernel community. Since a working system needs both the GNU userland tools and the Linux kernel, "GNU/Linux" is a more complete description of the whole operating system, while "Linux" strictly refers only to the kernel.
- The shell is not part of the kernel. It is a separate userland program (often provided by GNU, as with `bash`) that runs on top of the kernel.

**Exercise 3**
- Each distribution family chose its own packaging format and tooling early in its history (Debian created `.deb`/`dpkg`/`apt`; Red Hat created `.rpm`/`rpm`/`dnf`). These tools manage software installation, dependencies, and updates at the distribution level — a layer above the shared Linux kernel — so different distributions can diverge here even while running the same kernel.
- Examples: Debian family — Debian, Ubuntu, Linux Mint. Red Hat family — Fedora, Red Hat Enterprise Linux, CentOS/Rocky Linux/AlmaLinux.

**Exercise 4**
- SMB/CIFS interoperability lets Linux machines participate in Windows-centric networks: browsing shared folders, accessing shared printers, and exchanging files with Windows systems without needing a Windows machine as an intermediary.
- Example: a small office network with a Windows desktop, a macOS laptop, and a Linux file server, all accessing shared folders on the Linux server over SMB, and all print jobs sent to a shared printer configured on that same server via CUPS/Samba.

**Exercise 5**
- `armv7l` (and `aarch64`) architectures are most associated with embedded devices and smartphones, since ARM processors dominate mobile and low-power embedded hardware, while `x86_64` is typical of desktops, laptops, and most servers.
- Android uses a modified Linux kernel, but it does not use the standard GNU userland tools, does not use a traditional distribution package manager (`apt`/`dnf`/`zypper`), and applications are built and distributed differently (APKs, a Java/Kotlin-based runtime). Because it replaces the userland layer entirely, it is "Linux-based" (kernel level) but not a conventional Linux distribution.
- Three examples: smartphones/tablets (Android), embedded/IoT devices (routers, smart TVs, industrial controllers), and cloud server instances/containers (virtual machines running Linux distributions in a data center).

</details>