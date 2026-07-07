# Guided Exercises — Topic 1.4: ICT Skills and Working in Linux

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 2

These exercises are hands-on. Work through them on any Linux machine — a physical install, a virtual machine, or a live USB session. A desktop environment (GNOME, KDE Plasma, Xfce, etc.) and a web browser are assumed for some blocks.

---

## Exercise 1 — Finding Your Way to the Command Line

Linux gives you more than one way to reach a shell. In this exercise you will try the two most common ones: a **terminal emulator** running inside the graphical desktop, and a **virtual terminal (console)** running outside of it.

### Steps

1. Log in to your Linux desktop session.
2. Open the application launcher/menu and search for an application named **Terminal**, **Konsole**, **GNOME Terminal**, or **xterm**. Launch it.
3. In the window that opens, type the following command and press **Enter**:

   ```bash
   tty
   ```

   Note the output (something like `/dev/pts/0`).
4. Now switch to a virtual terminal by pressing **Ctrl+Alt+F3** (on some systems **Ctrl+Alt+F2** through **Ctrl+Alt+F6** all work). You should see a full-screen text login prompt.
5. Log in with your username and password, then run `tty` again. Note the output (something like `/dev/tty3`).
6. Log out of the virtual terminal by typing:

   ```bash
   exit
   ```

7. Return to your graphical session by pressing **Ctrl+Alt+F1** or **Ctrl+Alt+F2** (which one holds the GUI varies by distribution — try both).

### Check your understanding

**Q1.1** — What is the difference between a *terminal emulator* and a *virtual terminal*?

**Q1.2** — The `tty` command printed `/dev/pts/0` in one case and `/dev/tty3` in the other. What does this difference tell you?

**Q1.3** — A server administrator often works on machines that have no graphical desktop installed at all. Why is this common practice on servers?

---

## Exercise 2 — Exploring Desktop Productivity Tools

Linux desktops ship with open source applications covering the same tasks as proprietary office suites. In this exercise you will identify what is installed on your system.

### Steps

1. Open your application menu and look for an office suite. On most distributions this is **LibreOffice**. Identify which of its components are installed by finding the applications for:
   - word processing (**LibreOffice Writer**)
   - spreadsheets (**LibreOffice Calc**)
   - presentations (**LibreOffice Impress**)
2. Open **LibreOffice Writer**, type a sentence, and save the file. Note the default file extension it offers (`.odt`).
3. Use **Save As** and look through the file-type dropdown. Confirm that you could also save in Microsoft Word format (`.docx`).
4. Open your web browser (commonly **Firefox** or **Chromium**). In the address bar type `about:` and press Enter (Firefox) or open the **About** entry in the menu to see the exact browser name and version.
5. From the terminal, verify the same information without the GUI:

   ```bash
   firefox --version
   ```

   (Substitute `chromium --version` or `google-chrome --version` if that is your browser.)

### Check your understanding

**Q2.1** — `.odt` files follow the **OpenDocument Format (ODF)**. Why is an open, standardized document format important, beyond the fact that LibreOffice is free of charge?

**Q2.2** — Name one open source application for each task: web browsing, email, and image editing.

**Q2.3** — Can a LibreOffice user exchange documents with a Microsoft Office user? Explain briefly.

---

## Exercise 3 — Linux in Industry: Cloud and Virtualization

Most of the world's cloud infrastructure runs on Linux. In this exercise you will find out whether *your* system is itself running inside a virtual machine, and reason about where Linux shows up in industry.

### Steps

1. Open a terminal and run:

   ```bash
   systemd-detect-virt
   ```

   The output is either the name of a virtualization technology (e.g. `kvm`, `oracle`, `vmware`, `microsoft`) or `none` if you are on bare metal.
2. Look at basic information about the hardware (real or virtual) your kernel sees:

   ```bash
   lscpu | head -n 15
   ```

   Find the line `Hypervisor vendor:` if present — it appears only in virtualized environments.
3. Check how long the system has been running and how many users are logged in:

   ```bash
   uptime
   ```

4. Think of three devices or services you used today that likely run Linux without you seeing it (routers, Android phones, websites, smart TVs, cloud services…). Write them down.

### Check your understanding

**Q3.1** — In your own words, what is a *virtual machine*, and why do cloud providers rely on virtualization so heavily?

**Q3.2** — What is the relationship between Linux and Android?

**Q3.3** — Give two reasons why Linux dominates on servers and embedded devices even though it has a smaller share on desktop PCs.

---

## Exercise 4 — Password Security

Weak or reused passwords are one of the most common causes of compromised accounts. In this exercise you will examine password quality in practice.

### Steps

1. In a terminal, check when your own password was last changed:

   ```bash
   chage -l $USER
   ```

   Look at the line `Last password change`.
2. Change your password (you can set it right back afterwards, or genuinely improve it):

   ```bash
   passwd
   ```

   First try a deliberately weak password such as `abc123` and observe the warning or rejection the system gives you. Then set a strong one.
3. Build a strong passphrase using the "several unrelated words" method: pick four or more random, unrelated words and join them, e.g. `plaza-otter-violin-cloud9`. Do **not** use the example itself.
4. If your distribution includes the `pwscore` utility (package `libpwquality-tools`), test candidate passwords by running:

   ```bash
   pwscore
   ```

   Type a candidate password and press Enter; you get a score from 0 to 100 (or an error explaining why it is too weak). Press **Ctrl+C** to quit.

### Check your understanding

**Q4.1** — List three properties of a strong password or passphrase.

**Q4.2** — Why is *reusing* a strong password across several websites still dangerous?

**Q4.3** — What is a *password manager*, and how does it change the practical trade-off between password strength and memorability?

---

## Exercise 5 — Privacy in the Web Browser

Browsers store history, cookies, and cache data, and websites use cookies to track users across the web. In this exercise you will inspect and control that data.

### Steps

1. Open your browser and visit any website you use regularly.
2. Open the cookie/storage view:
   - **Firefox:** menu → **Settings** → **Privacy & Security** → section **Cookies and Site Data** → **Manage Data…**
   - **Chromium/Chrome:** **Settings** → **Privacy and security** → **Third-party cookies** / **See all site data and permissions**
3. Search for the site you just visited and note that it stored cookies. Remove the cookies for one site you don't recognize.
4. Open a **private/incognito window** (**Ctrl+Shift+P** in Firefox, **Ctrl+Shift+N** in Chrome/Chromium). Visit a website, then close the private window.
5. Check your normal browsing history (**Ctrl+H**) and confirm the private-window visit is not listed.
6. Back in the normal window, look at the address bar of any site you visit and find the padlock (or "secure" indicator). Click it and view the connection information: it should say the connection uses **HTTPS** and show the site's certificate.

### Check your understanding

**Q5.1** — What is a *cookie*, and what is the specific privacy concern with *third-party* cookies?

**Q5.2** — Private/incognito mode prevented the visit from appearing in your local history. Name two things private mode does **not** hide.

**Q5.3** — What does the padlock/HTTPS indicator guarantee — and what does it *not* guarantee about the website itself?

---

## Exercise 6 — Encryption Basics: Protecting Data in Transit and at Rest

Encryption protects data **in transit** (moving across a network, e.g. TLS/HTTPS or SSH) and **at rest** (stored on disk, e.g. encrypted files or partitions). In this exercise you will encrypt a file with GnuPG and confirm your system can make encrypted remote connections.

### Steps

1. Create a small text file:

   ```bash
   echo "This is my secret note." > secret.txt
   ```

2. Encrypt it symmetrically (with a passphrase) using **GnuPG**:

   ```bash
   gpg -c secret.txt
   ```

   Enter a passphrase when prompted. This creates `secret.txt.gpg`.
3. Look at the encrypted file's contents and confirm it is unreadable:

   ```bash
   cat secret.txt.gpg
   ```

4. Delete the original and recover it by decrypting:

   ```bash
   rm secret.txt
   gpg -d secret.txt.gpg > secret.txt
   cat secret.txt
   ```

5. Verify that the OpenSSH client — the standard tool for encrypted remote logins — is installed:

   ```bash
   ssh -V
   ```

6. Clean up:

   ```bash
   rm secret.txt secret.txt.gpg
   ```

### Check your understanding

**Q6.1** — Explain the difference between encrypting data *in transit* and *at rest*, giving one tool or protocol for each.

**Q6.2** — In step 2 you used *symmetric* encryption. What is the key difference between symmetric and public-key (asymmetric) encryption?

**Q6.3** — Older remote-access tools like `telnet` have been replaced by `ssh` almost everywhere. Why?

---

## Exercise 7 — Open Source Collaboration Tools

Open source development happens in the open, using tools anyone can join. In this exercise you will visit real collaboration platforms used by Linux-related projects.

### Steps

1. In your browser, visit a public **wiki**: <https://wiki.archlinux.org/> — search for an article about a program you know (e.g. "Firefox") and skim it.
2. Visit a public **code hosting / version control** platform: open <https://gitlab.com/explore> or <https://github.com/explore> and open any project. Find the **Issues** section, where users report bugs and request features.
3. Visit a public **mailing list archive**: open <https://lore.kernel.org/> and observe that Linux kernel development discussions are public email threads.
4. Identify one **real-time chat** system used by open source communities (IRC networks such as Libera.Chat, or Matrix at <https://matrix.org/>). You do not need to create an account — just find which channels/rooms exist for a distribution you use.

### Check your understanding

**Q7.1** — Match each collaboration need with a tool category: (a) documenting how software works so anyone can improve the docs, (b) tracking bugs and coordinating code changes, (c) asynchronous long-form technical discussion, (d) instant conversation.

**Q7.2** — Why does open, public collaboration (public bug trackers, public mailing lists) tend to improve software quality and security?

**Q7.3** — What is *version control*, and why is it essential when many people edit the same code?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** — A *terminal emulator* is a graphical application (a window) running inside the desktop environment that provides a shell. A *virtual terminal* (console) is a full-screen text interface provided directly by the system, independent of any graphical session — it works even when no GUI is running.

**A1.2** — `/dev/pts/N` devices are *pseudo-terminals*, created dynamically for terminal emulators (and remote sessions like SSH). `/dev/ttyN` devices are the system's virtual consoles. The output therefore tells you *what kind* of terminal you are on: emulated inside a GUI/session versus a real virtual console.

**A1.3** — Servers usually run "headless" (no GUI) because a graphical environment consumes memory, CPU, and disk, adds attack surface and updates to manage, and is unnecessary: administration is done remotely over SSH at the command line, which is scriptable and works over slow connections.

### Exercise 2

**A2.1** — An open standard format means the document's structure is publicly documented, so any software — now or in the future — can implement it. Users are not locked in to one vendor, archives remain readable long-term, and governments/organizations can guarantee access to their own documents.

**A2.2** — Examples: web browsing — **Firefox** (or Chromium); email — **Thunderbird** (or Evolution); image editing — **GIMP**. (Other valid answers exist.)

**A2.3** — Yes. LibreOffice can open and save Microsoft formats such as `.docx`, `.xlsx`, and `.pptx`. Compatibility is good for typical documents, though very complex formatting or macros may not convert perfectly — for guaranteed fidelity both sides can standardize on one format (e.g. ODF).

### Exercise 3

**A3.1** — A virtual machine is a software-emulated computer: a *hypervisor* running on physical hardware presents virtual CPUs, memory, disks, and network interfaces to a guest operating system, which runs as if on real hardware. Cloud providers rely on virtualization because it lets one physical server safely host many isolated customer systems, provisioned in seconds, resized on demand, and moved between hosts — maximizing hardware utilization and flexibility.

**A3.2** — Android uses the **Linux kernel** at its core. On top of that kernel, Google builds a different userland (its own libraries, runtime, and application framework), so Android apps and desktop Linux applications are not interchangeable, but the operating system foundation is Linux.

**A3.3** — Any two of: no license cost at any scale; source code can be audited and customized (critical for embedded devices); excellent stability and remote administration over SSH; runs on a huge range of hardware architectures; strong performance for networking and multi-user server workloads; the dominant platform for cloud and container tooling.

### Exercise 4

**A4.1** — Any three of: sufficient length (the most important factor — e.g. 12+ characters or a multi-word passphrase); not based on dictionary words, names, or personal data in guessable form; unique (not reused on other accounts); a mix of character classes or, alternatively, several truly random unrelated words; not shared or written where others can find it.

**A4.2** — Because of *credential stuffing*: if any one site is breached and leaks your password, attackers automatically try that same email/password pair on many other services. The password's strength is irrelevant once it has leaked — uniqueness is what limits the damage.

**A4.3** — A password manager is a program that stores all your credentials in an encrypted database unlocked by one master passphrase (e.g. KeePassXC, Bitwarden). Since you no longer need to memorize individual passwords, every account can have a long, random, unique password — you only have to remember (and make very strong) the single master passphrase.

### Exercise 5

**A5.1** — A cookie is a small piece of data a website stores in your browser, which the browser sends back on later requests — used for logins, preferences, and shopping carts. *Third-party* cookies are set by a domain other than the site you are visiting (e.g. an ad network embedded on many sites); because the same third party is present across thousands of sites, it can correlate your visits and build a profile of your browsing across the web.

**A5.2** — Any two of: your IP address and identity as seen by the websites you visit; your traffic as seen by your ISP, employer, or network administrator; anything you actively log in to (the site still knows it's you); malware or monitoring software on the computer itself. Private mode only avoids storing history, cookies, and cache *locally* after the window closes.

**A5.3** — HTTPS guarantees the connection is *encrypted* between your browser and that server, and that the server presented a valid certificate for that domain name — so the traffic cannot be read or tampered with in transit. It does **not** guarantee the site is honest, safe, or the one you intended: a phishing site can serve valid HTTPS too.

### Exercise 6

**A6.1** — *In transit*: protecting data while it moves over a network, so eavesdroppers on the path cannot read it — e.g. **TLS/HTTPS** for web traffic or **SSH** for remote logins. *At rest*: protecting data where it is stored, so someone who obtains the disk or file cannot read it — e.g. **GnuPG**-encrypted files or **LUKS** full-disk encryption.

**A6.2** — Symmetric encryption uses the *same* key (passphrase) to encrypt and decrypt, so both parties must already share that secret. Asymmetric (public-key) encryption uses a *key pair*: anyone can encrypt with the public key, but only the holder of the private key can decrypt — no shared secret needs to be exchanged in advance, which also enables digital signatures.

**A6.3** — `telnet` transmits everything — including usernames and passwords — in plain text, so anyone able to observe the network can capture credentials and session contents. `ssh` encrypts the entire session and also authenticates the server (host keys), preventing both eavesdropping and man-in-the-middle attacks.

### Exercise 7

**A7.1** — (a) → **wiki** (e.g. the Arch Wiki); (b) → **code hosting platform with issue tracker / version control** (e.g. GitLab, GitHub); (c) → **mailing list** (e.g. kernel mailing lists on lore.kernel.org); (d) → **real-time chat** (IRC, Matrix).

**A7.2** — Because anyone can read the code, reproduce and report bugs, and audit fixes, problems are found and corrected by a much larger pool of reviewers than any single company employs ("many eyes"). Public trackers and archives also create transparency: known issues and their fixes are documented and searchable rather than hidden.

**A7.3** — Version control (e.g. **Git**) records every change to a set of files: who changed what, when, and why. With many contributors it is essential because it lets people work in parallel on branches, merge their work, detect conflicts, review changes before they are accepted, and roll back mistakes to any previous state.

</details>

---

## References

- LPI Learning Materials, Linux Essentials Topic 1.4 — *ICT Skills and Working in Linux*: <https://learning.lpi.org/en/learning-materials/010-160/1/1.4/>
- LPI Linux Essentials Exam 010-160 Objectives (version 1.6): <https://www.lpi.org/our-certifications/exam-010-objectives/>
- GnuPG documentation: <https://gnupg.org/documentation/>
- Mozilla Firefox privacy documentation: <https://support.mozilla.org/en-US/products/firefox/privacy-and-security>