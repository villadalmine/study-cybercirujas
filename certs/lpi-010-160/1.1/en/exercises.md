# Guided Exercises — Topic 1.1: Linux Evolution and Popular Operating Systems

**Certification:** LPI Linux Essentials (010-160, version 1.6)
**Exam weight:** 2
**Reference:** [LPI Learning Materials — Lesson 1.1](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)

You will need access to a Linux machine (physical, virtual machine, or WSL) and a web browser. Every command is safe to run on any modern distribution.

---

## Exercise 1 — Identify the kernel your system runs

The Linux kernel is the core of every Linux operating system. It was first released by Linus Torvalds in 1991 and is still actively developed today. Let's find out which kernel you are running.

1. Open a terminal.
2. Print the kernel name:
   ```bash
   uname -s
   ```
3. Print the kernel release (version):
   ```bash
   uname -r
   ```
4. Print everything the kernel reports about itself in one line:
   ```bash
   uname -a
   ```
5. Compare your kernel version with the latest stable release listed at [https://kernel.org](https://kernel.org).

**Questions**

1.1. In a kernel version such as `6.9.3`, what do the first two numbers (`6.9`) represent, and what does the third number (`3`) usually indicate?

1.2. Strictly speaking, is "Linux" the name of a complete operating system or the name of a kernel? What term do some people use to acknowledge the GNU project's userland tools?

1.3. Your distribution's kernel version is probably older than the latest one on kernel.org. Why do distributions often ship a kernel that is not the newest available?

---

## Exercise 2 — Discover which distribution you are using

A *distribution* bundles the Linux kernel with system tools, a package manager, and (often) a desktop environment. Different distributions target different users and use cases.

1. Display the standard distribution identification file:
   ```bash
   cat /etc/os-release
   ```
2. Note the values of `NAME`, `VERSION` (if present), and `ID_LIKE` (if present).
3. Find out which package manager your distribution uses. Try each command and note which ones exist:
   ```bash
   which apt dnf yum zypper pacman 2>/dev/null
   ```
4. Visit [https://distrowatch.com](https://distrowatch.com) in a browser and look up your distribution. Read its description and check which distribution it is *based on*, if any.

**Questions**

2.1. Ubuntu is derived from another major community distribution. Which one, and which package format do both use?

2.2. Fedora, CentOS Stream, and Rocky Linux are all related to which company's enterprise distribution? Which package format does that family use?

2.3. The `ID_LIKE` field in `/etc/os-release` often reveals a distribution's ancestry. If a system shows `ID=linuxmint` and `ID_LIKE="ubuntu debian"`, describe the chain of derivation.

2.4. Name one distribution characteristic that matters when choosing a distribution for an enterprise server rather than a hobbyist desktop.

---

## Exercise 3 — Rolling vs. fixed releases and support lifecycles

Distributions follow different release models, and choosing between them is a real-world administration decision.

1. In your browser, open the Ubuntu release page: [https://ubuntu.com/about/release-cycle](https://ubuntu.com/about/release-cycle). Note how often LTS (Long Term Support) versions are published and how long they are supported.
2. Now open the Arch Linux homepage ([https://archlinux.org](https://archlinux.org)) and read how Arch describes its release model.
3. On your own system, check how long ago your installed packages were last updated:
   ```bash
   ls -l /var/log/ | grep -i -E 'apt|dnf|pacman' 2>/dev/null
   ```
   (The exact log file depends on your package manager; it is fine if you only find one.)

**Questions**

3.1. Explain the difference between a *fixed release* model (like Ubuntu LTS) and a *rolling release* model (like Arch Linux).

3.2. A hospital wants servers that change as little as possible for five years. Which release model fits better, and why?

3.3. What does "LTS" mean, and why is it attractive for production environments?

---

## Exercise 4 — Linux beyond the desktop: servers, cloud, and embedded devices

Linux dominates far more environments than the desktop: web servers, supercomputers, cloud infrastructure, Android phones, routers, and IoT devices.

1. Check whether your machine is acting as a server right now by listing programs listening for network connections:
   ```bash
   ss -tln
   ```
2. Look at the top supercomputers list at [https://top500.org](https://top500.org) and check which operating system family the top systems run.
3. If you own an Android phone, open **Settings → About phone → Android version** (the exact path varies) and find the **kernel version** entry.
4. Think of the devices in your home — router, smart TV, e-reader. Pick one and search the web for "`<device name>` GPL source code" to see whether the manufacturer publishes Linux sources for it.

**Questions**

4.1. Android runs a Linux kernel. Name two important ways Android differs from a typical desktop GNU/Linux distribution.

4.2. Why did Linux become the dominant operating system for cloud providers and supercomputers? Give at least two reasons.

4.3. What is an *embedded system*, and why is the manufacturer of a Linux-based router obliged to offer its kernel source code?

4.4. The Raspberry Pi is frequently mentioned in this exam topic. What is it, and which Debian-derived distribution is officially provided for it?

---

## Exercise 5 — Linux among other operating systems

The exam expects you to place Linux in context with other operating systems: Windows, macOS, and the Unix/BSD family.

1. From your Linux terminal, check the system's hostname and OS type, then compare mentally with how you would do it on Windows (`systeminfo`) or macOS (`sw_vers`):
   ```bash
   hostnamectl 2>/dev/null || uname -a
   ```
2. Visit [https://www.freebsd.org](https://www.freebsd.org) and read the short project description on the front page.
3. Search the web for "macOS UNIX certified" and note what you find about macOS's relationship to Unix.

**Questions**

5.1. Both Linux and FreeBSD are Unix-like and open source. Name one key difference in how the two projects are developed or licensed.

5.2. Is macOS based on the Linux kernel? If not, what is it based on?

5.3. Historically, what was Unix, and what is the relationship between Unix and Linux? (Hint: Linux is called "Unix-like" — why not simply "Unix"?)

5.4. A colleague says "Linux can't be used with Windows in the same company." Give two examples that disprove this claim.

---

## Exercise 6 — A short timeline of Linux evolution

1. Read the historical section of the reference lesson: [https://learning.lpi.org/en/learning-materials/010-160/1/1.1/](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/).
2. On paper or in a text file, build your own timeline with these events, placing the correct year next to each:
   - GNU project announced by Richard Stallman
   - Linus Torvalds announces his hobby kernel on Usenet
   - Linux kernel adopts the GPL license
   - Android is first released
3. Save your timeline as `linux-timeline.txt` using any editor:
   ```bash
   nano linux-timeline.txt
   ```

**Questions**

6.1. In which year did Linus Torvalds first announce Linux, and what did he famously say about the project's ambitions?

6.2. Why was the combination of the GNU tools (started 1983) and the Linux kernel (1991) so significant?

6.3. Which license does the Linux kernel use, and what fundamental freedom does it guarantee that proprietary operating systems do not?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1.** The first two numbers (`6.9`) identify the kernel *release series* (major and minor version); the third number (`3`) is the patch/stable level, incremented for bug and security fixes within that series. New minor versions bring features; patch releases only fix problems.

**1.2.** Strictly speaking, Linux is only the *kernel*. A complete operating system adds userland tools, much of which historically comes from the GNU project — which is why some people prefer the term *GNU/Linux*.

**1.3.** Distributions test, integrate, and stabilize a specific kernel version, then maintain it with backported security fixes. Shipping the very latest kernel would sacrifice the stability and predictability their users depend on.

### Exercise 2

**2.1.** Ubuntu is derived from **Debian**. Both use the **`.deb`** package format (managed with tools such as `apt` and `dpkg`).

**2.2.** They are related to **Red Hat** (Red Hat Enterprise Linux). That family uses the **RPM** package format (managed with `dnf`/`yum`).

**2.3.** Linux Mint is derived from Ubuntu, which in turn is derived from Debian: Debian → Ubuntu → Linux Mint.

**2.4.** Any of: length of the support/security-update lifecycle, availability of commercial support, certification for third-party enterprise software, stability of the release model. (For a hobbyist desktop, newer software and community support usually matter more.)

### Exercise 3

**3.1.** A *fixed release* publishes discrete versions on a schedule; packages within a version stay at stable versions and receive mainly security fixes. A *rolling release* has no versions: packages are continuously updated to their latest upstream releases, so the system is always current but changes constantly.

**3.2.** A fixed release with long-term support (e.g., an enterprise distribution or an LTS release). It guarantees years of security updates without behavioral changes, which suits environments where stability and predictability are critical.

**3.3.** LTS means **Long Term Support**: the release receives security and maintenance updates for an extended period (five years for Ubuntu LTS, ten for RHEL). Production environments value this because they can stay secure without frequent, risky major upgrades.

### Exercise 4

**4.1.** Any two of: Android uses its own userland and does not include the GNU tools or a standard shell environment for users; applications are written for the Android runtime (Java/Kotlin APIs) rather than as native Linux programs; software is distributed through app stores rather than a distribution package manager; Google maintains a modified kernel and stack rather than a community distribution.

**4.2.** Any two of: no license costs and freedom to modify the source; excellent scalability from tiny devices to supercomputer clusters; strong stability and remote administration via the command line; huge ecosystem of server software and automation tooling; vendors can customize it for their hardware.

**4.3.** An embedded system is a computer built into a device to perform a dedicated function (router, TV, car system), typically with constrained resources. Because the Linux kernel is licensed under the **GPL**, anyone who distributes it (including inside a router) must make the corresponding source code available to their users.

**4.4.** The Raspberry Pi is a low-cost, credit-card-sized single-board computer widely used for education, hobby projects, and embedded/IoT applications. Its official distribution is **Raspberry Pi OS**, derived from Debian.

### Exercise 5

**5.1.** Possible answers: FreeBSD develops the kernel and base userland together as one project, while Linux distributions assemble a kernel and userland from separate projects; FreeBSD uses the permissive **BSD license**, whereas the Linux kernel uses the **GPL**, which requires derivative works distributed to others to remain open source.

**5.2.** No. macOS is built on Darwin, whose kernel (XNU) descends from Mach and BSD — the Unix lineage, not Linux. Recent macOS versions are certified UNIX products.

**5.3.** Unix was a proprietary operating system created at AT&T Bell Labs in the late 1960s/1970s, which spawned many commercial variants. Linux shares Unix's design and behaves like it, but was written from scratch and contains no original Unix code — hence "Unix-like" rather than Unix.

**5.4.** Any two of: Linux servers commonly serve Windows desktop clients (file sharing with Samba, web applications, databases); mixed networks authenticate against shared directory services; Windows itself ships WSL (Windows Subsystem for Linux) to run Linux environments; Microsoft's Azure cloud runs a large share of Linux virtual machines.

### Exercise 6

**Timeline:** GNU project announced — **1983**; Linus Torvalds' Usenet announcement — **1991**; Linux adopts the GPL — **1992**; first Android release — **2008**.

**6.1.** In **1991**. He described it as "just a hobby, won't be big and professional like gnu" — a famously modest prediction for what became the world's most widely deployed kernel.

**6.2.** The GNU project had built nearly all components of a free operating system (compiler, shell, core utilities) but lacked a finished kernel. Linux supplied the missing kernel, and together they formed a complete, free Unix-like operating system.

**6.3.** The Linux kernel uses the **GNU General Public License, version 2 (GPLv2)**. It guarantees the freedom to use, study, modify, and redistribute the software — and requires that distributed modified versions remain under the same license, keeping the source code open.

</details>