# Guided Exercises — Topic 1.3: Open Source Software and Licensing

**Certification:** LPI Linux Essentials (010-160, version 1.6) · **Exam weight:** 1

These exercises work on any Debian/Ubuntu or Fedora/RHEL-based system. Where commands differ between distribution families, both variants are shown.

---

## Exercise 1: Find the license texts already on your system

Every Linux distribution ships thousands of software packages, and each one carries a license. Let's find them.

1. List the common license texts that Debian-based systems keep in a shared directory:

   ```bash
   ls /usr/share/common-licenses/
   ```

   On Fedora/RHEL-based systems, look here instead:

   ```bash
   ls /usr/share/licenses/ | head -20
   ```

2. Open the GPL version 3 text and skim the preamble (press `q` to quit):

   ```bash
   less /usr/share/common-licenses/GPL-3      # Debian/Ubuntu
   less /usr/share/licenses/*/COPYING 2>/dev/null | head -50   # Fedora/RHEL alternative
   ```

3. Count how long the GPL-3 text is, in lines:

   ```bash
   wc -l /usr/share/common-licenses/GPL-3
   ```

4. Now compare it with a *permissive* license. Search your system for an MIT or BSD license file and count its lines:

   ```bash
   find /usr/share/doc -iname "*copyright*" | head -5
   wc -l /usr/share/common-licenses/BSD 2>/dev/null
   ```

**Questions**

- **1.1** The GPL text is dramatically longer than the BSD/MIT texts. What does the GPL regulate that permissive licenses deliberately do not?
- **1.2** GPL is called a *copyleft* license. In one sentence, what does copyleft require from someone who distributes a modified version of the program?
- **1.3** Which of these licenses would let a company embed the code in a closed-source, proprietary product without releasing their changes: GPLv3, MIT, or both?

---

## Exercise 2: Check the license of installed packages

Package managers record license metadata. Let's query it.

1. On Debian/Ubuntu, read the copyright file of the `bash` package:

   ```bash
   less /usr/share/doc/bash/copyright
   ```

   On Fedora/RHEL, query the license field directly from RPM metadata:

   ```bash
   rpm -qi bash | grep -i license
   ```

2. Do the same for a permissively licensed tool — `curl` is a good example:

   ```bash
   less /usr/share/doc/curl/copyright        # Debian/Ubuntu
   rpm -qi curl | grep -i license            # Fedora/RHEL
   ```

3. On an RPM-based system, get a quick overview of the license diversity on your machine:

   ```bash
   rpm -qa --qf '%{LICENSE}\n' | sort | uniq -c | sort -rn | head -10
   ```

**Questions**

- **2.1** `bash` is a GNU project. Which organization sponsors the GNU project and publishes the GPL family of licenses?
- **2.2** The `curl` license is a very short, MIT-style text. Name the *category* this license belongs to, as opposed to copyleft.
- **2.3** Your distribution combines GPL, MIT, BSD, Apache, and many other licenses in one system. Who defines the criteria for what counts as an "open source" license and maintains the list of approved ones?

---

## Exercise 3: The Four Freedoms in practice

The Free Software Foundation (FSF) defines free software by four freedoms, numbered 0 to 3. Let's exercise them literally.

1. **Freedom 0 — run the program for any purpose.** Run a GPL-licensed program for a purpose its authors never anticipated:

   ```bash
   date +"Grocery list generated on %A"
   ```

2. **Freedom 1 — study how it works.** Download the source code of a small GNU package (this uses `apt` on Debian/Ubuntu; on Fedora use `dnf download --source hello`):

   ```bash
   mkdir ~/freedom1 && cd ~/freedom1
   apt-get source hello 2>/dev/null || curl -LO https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz
   tar xf hello-*.tar.gz 2>/dev/null; ls
   ```

3. Look inside the source you just obtained:

   ```bash
   less hello-*/src/hello.c
   ```

4. **Freedom 2 — redistribute copies.** Copy the source archive somewhere else (this is legally redistribution, even to yourself):

   ```bash
   cp hello-*.tar.gz /tmp/
   ```

5. **Freedom 3 — improve and share improvements.** Edit the source (change a string in `hello.c` with any editor), which you are fully entitled to do:

   ```bash
   nano hello-*/src/hello.c
   ```

**Questions**

- **3.1** Match each step above (1, 2–3, 4, 5) to its freedom number (0, 1, 2, 3).
- **3.2** Why is access to the *source code* a precondition for freedoms 1 and 3?
- **3.3** "Free software" refers to freedom, not price. What Spanish/Latin-derived phrase do English speakers use to disambiguate "free as in freedom" from "free as in no cost"?
- **3.4** The terms "free software" (FSF) and "open source" (OSI) describe largely the same set of licenses. What is the main difference between the two movements' *emphasis*?

---

## Exercise 4: Compare license obligations — a thought experiment you can verify

1. Print the key copyleft clause of the GPL (section 5 of GPLv3, "Conveying Modified Source Versions"):

   ```bash
   grep -n -A 4 "Conveying Modified Source" /usr/share/common-licenses/GPL-3
   ```

2. Now look at what the Apache License 2.0 requires. If it isn't on your system, fetch it:

   ```bash
   less /usr/share/common-licenses/Apache-2.0 2>/dev/null || curl -s https://www.apache.org/licenses/LICENSE-2.0.txt | less
   ```

3. Note the section in Apache-2.0 about "Grant of Patent License" — search for it:

   ```bash
   grep -n -i "patent" /usr/share/common-licenses/Apache-2.0 2>/dev/null || curl -s https://www.apache.org/licenses/LICENSE-2.0.txt | grep -n -i patent
   ```

**Questions**

- **4.1** A company ships a router whose firmware includes a modified Linux kernel (GPLv2). What must the company make available to its customers?
- **4.2** The same company also uses an Apache-2.0-licensed library, which they modified heavily. Must they publish those modifications?
- **4.3** What extra protection does Apache-2.0 offer over MIT/BSD, as you saw in step 3?
- **4.4** The Linux kernel uses GPLv2 (not v3). Android device makers combine that kernel with mostly Apache-2.0-licensed userland code. Why might a company prefer Apache-2.0 for code it wants industry-wide adoption of?

---

## Exercise 5: Creative Commons — licensing beyond software

Open licensing is not only for code. Documentation, images, courses, and data often use Creative Commons (CC) licenses.

1. Check the license of the very learning materials you are studying — open this page in a browser and scroll to the footer, or fetch it and search:

   ```bash
   curl -s https://learning.lpi.org/en/learning-materials/010-160/1/1.3/ | grep -o -i "CC BY[^<\"]*" | head -3
   ```

2. Decode a CC license identifier by hand. Write down what each module means in `CC BY-NC-ND 4.0`:

   ```
   BY = ?
   NC = ?
   ND = ?
   ```

3. Compare with `CC BY-SA 4.0`, the license used by Wikipedia.

**Questions**

- **5.1** What do the modules **BY**, **SA**, **NC**, and **ND** each require or forbid?
- **5.2** Which CC module is the Creative Commons equivalent of software copyleft?
- **5.3** Why are **NC** and **ND** licensed works *not* considered "free culture" or open in the same sense as open source software?
- **5.4** What is **CC0** and when would an author choose it?

---

## Exercise 6: Open source business models

1. Look at the operating system release information on your machine:

   ```bash
   cat /etc/os-release
   ```

2. Note the `NAME` and `HOME_URL` fields. Visit (or recall) how the company or community behind your distribution funds itself.

3. Research check (no command needed): consider these real pairs — Red Hat Enterprise Linux / Fedora, SUSE Linux Enterprise / openSUSE, Ubuntu Pro / Ubuntu.

**Questions**

- **6.1** If the software is freely redistributable, what do companies like Red Hat, SUSE, and Canonical actually sell?
- **6.2** Name at least three business models built around open source software.
- **6.3** MySQL is offered under GPL *and* under a paid commercial license. What is this model called, and why does it work legally?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

- **1.1** The GPL regulates *redistribution conditions in detail*: it requires that anyone who distributes the program (modified or not) must provide the source code and pass on the same license and freedoms to recipients. It also covers patents, installation information ("anti-tivoization" in GPLv3), and termination rules. Permissive licenses like MIT/BSD only require attribution and a warranty disclaimer, so they are a few paragraphs long.
- **1.2** Copyleft requires that modified versions, when distributed, must be released under the *same license*, with the source code made available — the freedoms attached to the code are preserved "downstream."
- **1.3** Only **MIT**. GPLv3 code embedded in a distributed product obliges the distributor to release the corresponding source under GPLv3. MIT permits proprietary redistribution with only an attribution notice.

### Exercise 2

- **2.1** The **Free Software Foundation (FSF)**, founded by Richard Stallman, sponsors the GNU project and publishes the GPL, LGPL, and AGPL.
- **2.2** It is a **permissive** license (also called "non-copyleft" or informally "BSD-style").
- **2.3** The **Open Source Initiative (OSI)** maintains the Open Source Definition (OSD) and reviews/approves licenses against it. (The FSF maintains a parallel list of *free software* licenses; the two lists overlap almost completely.)

### Exercise 3

- **3.1** Step 1 → Freedom 0 (run for any purpose). Steps 2–3 → Freedom 1 (study the source). Step 4 → Freedom 2 (redistribute copies). Step 5 → Freedom 3 (modify and share improvements).
- **3.2** Without human-readable source code you can neither meaningfully study how a program works nor change it — a compiled binary is practically opaque. That is why the FSF states that source access is a precondition for freedoms 1 and 3.
- **3.3** *"Libre"* — as in "libre software," distinguishing freedom from *gratis* (zero price).
- **3.4** The FSF's free software movement emphasizes **ethics and user freedom** as a social issue; the OSI's open source movement emphasizes **practical and business advantages** of open development (quality, security, collaboration). The umbrella term **FOSS/FLOSS** covers both.

### Exercise 4

- **4.1** The **complete corresponding source code** of the modified GPLv2 kernel (and the license text), so customers can rebuild and modify it themselves. Shipping the binary in a product counts as distribution and triggers this obligation.
- **4.2** **No.** Apache-2.0 is permissive: modifications may stay private even when the product ships, provided the license text, notices, and a statement of significant changes accompany the distribution.
- **4.3** An **explicit patent grant**: every contributor licenses their patents covering their contribution to all users, and the grant terminates for anyone who initiates patent litigation over the software. MIT/BSD are silent on patents.
- **4.4** Because permissive licensing removes the source-disclosure obligation, companies can adopt and embed the code in proprietary products without legal risk to their own code, which maximizes adoption of the platform.

### Exercise 5

- **5.1** **BY** (Attribution): credit the author. **SA** (ShareAlike): derivatives must carry the same license. **NC** (NonCommercial): no commercial use. **ND** (NoDerivatives): the work may be shared only unmodified.
- **5.2** **SA (ShareAlike)** — like copyleft, it forces derivatives to keep the same license.
- **5.3** Because they restrict two core freedoms: **NC** forbids use for any purpose (commercial use is excluded), and **ND** forbids making modified versions. Open source definitions require both freedoms.
- **5.4** **CC0** is a public-domain dedication: the author waives all copyright to the maximum extent the law allows, imposing no conditions at all — chosen when the author wants zero restrictions, e.g., for scientific data or reference material.

### Exercise 6

- **6.1** They sell what surrounds the software: **subscriptions with support, certified/tested builds, security updates and long-term maintenance, training and certification, consulting, and hosted services** — not the code itself.
- **6.2** Any three of: paid support/subscriptions (Red Hat, SUSE); dual licensing (MySQL, Qt); "open core" — open base product with proprietary add-ons (GitLab); SaaS/hosting of open software (managed databases, cloud services); donations and foundations (Wikimedia, Blender); paid development/consulting; hardware sales bundled with open software.
- **6.3** **Dual licensing.** The copyright holder owns all the code, so it can offer the same code under GPL (free, but copyleft obligations apply) *and* sell a separate commercial license to customers who want to embed it in proprietary products without GPL obligations.

</details>

---

## References

- LPI Learning Materials, Topic 1.3 — Open Source Software and Licensing: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- GNU Project — What is Free Software? (the Four Freedoms): https://www.gnu.org/philosophy/free-sw.html
- Open Source Initiative — The Open Source Definition: https://opensource.org/osd
- GNU General Public License v3: https://www.gnu.org/licenses/gpl-3.0.html
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- Creative Commons — About the Licenses: https://creativecommons.org/licenses/