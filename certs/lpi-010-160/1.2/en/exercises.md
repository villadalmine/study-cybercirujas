# Guided Exercises — Topic 1.2: Major Open Source Applications

**Certification:** LPI Linux Essentials (010-160, version 1.6)
**Exam weight:** 2
**Reference:** [LPI Learning Materials — Lesson 1.2](https://learning.lpi.org/en/learning-materials/010-160/1/1.2/)

You will need a Linux machine (physical, virtual machine, or WSL) with an internet connection. All commands are read-only or clearly marked as optional installs — nothing here breaks your system.

---

## Exercise 1 — Discover which package family your system belongs to

Almost all software on Linux is installed from **repositories** using a **package manager**. Before exploring applications, find out which packaging tools your distribution uses.

1. Open a terminal.
2. Check for the Debian-family tools:
   ```bash
   which dpkg apt
   ```
3. Check for the Red Hat–family tools:
   ```bash
   which rpm dnf yum
   ```
4. Whichever family matched, ask the package manager for its version:
   ```bash
   apt --version      # Debian family
   dnf --version      # Red Hat family
   ```
5. Count how many packages are currently installed on your system:
   ```bash
   dpkg -l | wc -l         # Debian family
   rpm -qa | wc -l         # Red Hat family
   ```

**Questions**

- **1a.** Which package *file format* does each family use, and name two distributions in each family.
- **1b.** What is a repository, and why is installing from one generally safer than downloading an installer from a random website?
- **1c.** Your colleague on Fedora types `apt install gimp` and gets "command not found". Why?

---

## Exercise 2 — Explore desktop applications and their file formats

The exam expects you to recognize the major open source desktop applications and what they replace.

1. Check whether LibreOffice is installed and which version:
   ```bash
   libreoffice --version
   ```
   If it is not installed, query the repository instead (no installation happens):
   ```bash
   apt show libreoffice-writer     # Debian family
   dnf info libreoffice-writer    # Red Hat family
   ```
2. List the LibreOffice-related binaries available on your system:
   ```bash
   ls /usr/bin | grep -i -E 'libre|soffice'
   ```
3. Query your package manager for information about three more desktop applications:
   ```bash
   apt show gimp inkscape thunderbird      # Debian family
   dnf info gimp inkscape thunderbird     # Red Hat family
   ```
   Read the `Description` field of each one.
4. If you have a desktop environment, open LibreOffice Writer, type a sentence, and use *File → Save As* to look at the default file extension offered. Close without saving if you prefer.

**Questions**

- **2a.** Match each LibreOffice component to its purpose: **Writer**, **Calc**, **Impress**, **Base**, **Draw**, **Math**.
- **2b.** What is the **Open Document Format (ODF)**, and which extensions do Writer, Calc and Impress documents use?
- **2c.** Which open source application would you recommend for: (i) editing a photo, (ii) creating vector graphics such as a logo, (iii) 3D modeling and animation, (iv) reading email on the desktop?
- **2d.** Firefox and Chromium are both open source browsers. Which organization develops Firefox?

---

## Exercise 3 — Investigate server applications without installing them

Most Linux systems in production are servers. You can learn a lot about server software just by querying repository metadata.

1. Look up the two dominant open source web servers:
   ```bash
   apt show apache2 nginx        # Debian family
   dnf info httpd nginx         # Red Hat family
   ```
   Note that the Apache HTTP Server package is called `apache2` on Debian-family systems and `httpd` on Red Hat–family systems.
2. Look up the file-sharing server that lets Linux talk to Windows networks:
   ```bash
   apt show samba       # or: dnf info samba
   ```
3. Check which network services are *actually* listening on your machine right now:
   ```bash
   ss -tln
   ```
   On a desktop system this list is usually short; on a server you might see ports like 80 (HTTP), 443 (HTTPS), or 445 (SMB).
4. *(Optional, if you want a hands-on web server and your system uses `apt`)* Install NGINX, verify it serves a page, then remove it:
   ```bash
   sudo apt install nginx
   curl http://localhost
   sudo apt remove nginx
   ```

**Questions**

- **3a.** Name the two most widely deployed open source web servers.
- **3b.** Which protocol does **Samba** implement, and what is its main use case?
- **3c.** A company wants to run its own private file-synchronization and collaboration cloud instead of using a proprietary service. Name an open source application designed for exactly this.
- **3d.** Which mail transfer agents (MTAs) from the open source world can you name? (The exam expects you to recognize at least one.)

---

## Exercise 4 — Get hands-on with an open source database

Relational databases power most dynamic websites and business applications. **SQLite** is a tiny, serverless SQL database that is perfect for a first contact — it is usually installed by default or available in every repository.

1. Check whether SQLite is available:
   ```bash
   sqlite3 --version
   ```
   If not, install it (`sudo apt install sqlite3` or `sudo dnf install sqlite`) — it is only a few hundred kilobytes.
2. Start an **in-memory** database (nothing is written to disk):
   ```bash
   sqlite3 :memory:
   ```
3. At the `sqlite>` prompt, create a table and insert data:
   ```sql
   CREATE TABLE apps (name TEXT, category TEXT);
   INSERT INTO apps VALUES ('GIMP', 'graphics'), ('Apache', 'web server'), ('MariaDB', 'database');
   SELECT * FROM apps WHERE category = 'database';
   ```
4. Exit with `.quit`.
5. Now query your package manager for the two big client-server open source databases:
   ```bash
   apt show mariadb-server postgresql      # Debian family
   dnf info mariadb-server postgresql-server   # Red Hat family
   ```

**Questions**

- **4a.** MariaDB was created as a *fork* of another famous database. Which one, and why did the fork happen?
- **4b.** What is the main architectural difference between SQLite and MariaDB/PostgreSQL?
- **4c.** In the classic **LAMP** stack, what do the four letters stand for?

---

## Exercise 5 — Find the programming languages already on your system

Linux distributions ship with several programming languages out of the box, because much of the system itself is written in them.

1. Check which interpreters and compilers are present:
   ```bash
   bash --version
   python3 --version
   perl -v | head -2
   gcc --version 2>/dev/null || echo "no C compiler installed"
   ```
2. Run a one-line **shell script**:
   ```bash
   echo 'Hello from the shell'
   ```
3. Run a one-line **Python** program without creating a file:
   ```bash
   python3 -c 'print("Hello from Python")'
   ```
4. Create and execute a real shell script:
   ```bash
   cat > /tmp/hello.sh <<'EOF'
   #!/bin/bash
   echo "This system runs kernel $(uname -r)"
   EOF
   chmod +x /tmp/hello.sh
   /tmp/hello.sh
   rm /tmp/hello.sh
   ```

**Questions**

- **5a.** The Linux kernel itself is written almost entirely in one language. Which one?
- **5b.** What is the difference between a **compiled** language and an **interpreted** language? Classify C, Python, and shell script.
- **5c.** Which language runs *inside the web browser* and is essential for interactive websites?
- **5d.** What is the purpose of the `#!/bin/bash` line at the top of the script in step 4?

---

## Answers

<details>
<summary><strong>Click to reveal the answers</strong></summary>

### Exercise 1

- **1a.** The Debian family uses **`.deb`** packages (managed with `dpkg` and `apt`) — e.g. Debian, Ubuntu, Linux Mint, Raspberry Pi OS. The Red Hat family uses **`.rpm`** packages (managed with `rpm` and `dnf`/`yum`) — e.g. RHEL, Fedora, CentOS Stream, Rocky Linux. (openSUSE also uses `.rpm`, with the `zypper` tool.)
- **1b.** A repository is an online, distribution-maintained collection of packages. Packages in it are curated, cryptographically signed, tested against your distribution's versions, and receive security updates through the same channel — unlike an arbitrary download, which you must trust and update manually.
- **1c.** `apt` is a Debian-family tool. Fedora belongs to the Red Hat family, so the equivalent command is `dnf install gimp`.

### Exercise 2

- **2a.** **Writer** — word processing; **Calc** — spreadsheets; **Impress** — presentations; **Base** — desktop databases; **Draw** — drawings and diagrams; **Math** — mathematical formulas.
- **2b.** ODF (Open Document Format) is the **open, standardized (ISO/IEC 26300) file format** used natively by LibreOffice. Extensions: `.odt` (text/Writer), `.ods` (spreadsheet/Calc), `.odp` (presentation/Impress). Being an open standard means any vendor can implement it, so your documents are not locked to one product.
- **2c.** (i) **GIMP** (GNU Image Manipulation Program) for raster/photo editing; (ii) **Inkscape** for vector graphics; (iii) **Blender** for 3D modeling, animation and rendering; (iv) **Thunderbird** as a desktop email client.
- **2d.** Firefox is developed by the **Mozilla Foundation** (and Mozilla Corporation).

### Exercise 3

- **3a.** The **Apache HTTP Server** and **NGINX**. Together they serve a large share of all websites on the internet.
- **3b.** Samba implements the **SMB/CIFS** protocol. It lets a Linux machine share files and printers with Windows clients (and even act as a domain controller), making Linux a drop-in file server in Windows networks.
- **3c.** **Nextcloud** (or its predecessor **ownCloud**) — a self-hosted platform for file sync, sharing, calendars, contacts and collaborative editing.
- **3d.** Common open source MTAs include **Postfix**, **Sendmail**, and **Exim** (with **Dovecot** frequently paired with them as an IMAP/POP3 server for mailbox access).

### Exercise 4

- **4a.** MariaDB is a fork of **MySQL**. When Oracle acquired MySQL (via Sun Microsystems, 2010), the original developers — worried about the project's future under a single commercial owner — forked the code and continued it as MariaDB under an open source license. This ability to fork is a core freedom of open source software.
- **4b.** SQLite is a **serverless, embedded** library: the database is a single file (or memory) accessed directly by the application, with no separate process. MariaDB and PostgreSQL are **client-server** systems: a dedicated server daemon manages the data, handles many concurrent clients over the network, and enforces users and permissions.
- **4c.** **L**inux, **A**pache, **M**ySQL (or MariaDB), and **P**HP (sometimes Perl or Python) — the classic open source stack for dynamic websites.

### Exercise 5

- **5a.** **C** (with small amounts of assembly, and more recently some Rust in specific subsystems).
- **5b.** A **compiled** language is translated ahead of time by a compiler into machine code that the CPU executes directly (e.g. **C**, compiled with `gcc`). An **interpreted** language is read and executed at runtime by an interpreter, with no separate build step (e.g. **Python** and **shell script**). Interpreted programs are easier to modify and run anywhere the interpreter exists; compiled programs generally run faster.
- **5c.** **JavaScript** — the only language natively executed by web browsers, used to make web pages interactive. (Server-side JavaScript also exists, e.g. Node.js.)
- **5d.** It is the **shebang** line. When the file is executed, the kernel reads `#!/bin/bash` and launches `/bin/bash` as the interpreter for the script — so the script runs the same way regardless of which shell the user typed the command from.

</details>