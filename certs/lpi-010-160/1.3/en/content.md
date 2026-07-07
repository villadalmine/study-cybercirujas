# 1.3 Open Source Software and Licensing

**Exam weight:** 1
**Key knowledge areas:** open source philosophy and licensing, Free Software vs. Open Source, copyleft vs. permissive licenses, common licenses (GPL, BSD, Creative Commons), open source business models, the roles of the FSF and OSI.

---

## 1. What Makes Software "Free" or "Open Source"?

Software is more than the program you run: it starts as **source code**, human-readable instructions that are compiled or interpreted into a working application. Whether you may read, change, and share that source code is not a technical question — it is a **legal** one, decided by the software's **license**.

### The Free Software definition (FSF)

The **Free Software Foundation (FSF)**, founded by Richard Stallman in 1985, defines Free Software by **four essential freedoms**:

| Freedom | Description |
|---------|-------------|
| **Freedom 0** | Run the program for any purpose |
| **Freedom 1** | Study how the program works and change it (requires access to the source code) |
| **Freedom 2** | Redistribute copies to help others |
| **Freedom 3** | Distribute copies of your modified versions (requires access to the source code) |

"Free" refers to **liberty, not price** — the common phrase is *"free as in freedom, not free as in beer."* Free Software may be sold commercially; what matters is that the four freedoms are preserved.

### The Open Source definition (OSI)

In 1998, the **Open Source Initiative (OSI)** introduced the term **Open Source** to promote the same development model with a more business-friendly, pragmatic framing. The OSI maintains the **Open Source Definition** (10 criteria, including free redistribution, source code availability, no discrimination against persons or fields of endeavor) and formally **approves licenses** that comply with it.

### FLOSS / FOSS

In practice, almost all Free Software is Open Source and vice versa. The philosophical emphasis differs (ethics vs. practical advantages), so neutral umbrella terms are used:

- **FOSS** — Free and Open Source Software
- **FLOSS** — Free/Libre and Open Source Software ("libre" avoids the price ambiguity of English "free")

### What FOSS is *not*

- **Proprietary (closed source) software** — source code is not available, or use/modification/redistribution is restricted (e.g., Microsoft Windows, Adobe Photoshop).
- **Freeware** — gratis to use, but without source code or the four freedoms (e.g., many free-of-charge downloads).
- **Shareware** — distributed free for trial, payment expected for continued use.

Being able to *see* the source is not enough: if the license forbids modification or redistribution, it is not Free Software or Open Source.

---

## 2. Copyleft vs. Permissive Licenses

FOSS licenses fall into two broad families, differing in what they require from **derivative works**.

### Copyleft licenses ("share-alike")

A **copyleft** license uses copyright law to guarantee that the freedoms attached to a work are preserved downstream: if you distribute a modified version, you **must license it under the same terms** and provide the source code.

- **GNU GPL (General Public License)** — the classic strong copyleft license, written by the FSF. The Linux kernel uses **GPLv2**; many GNU tools use **GPLv3** (which added clauses on patents and "tivoization" — hardware that blocks modified software from running).
- **GNU LGPL (Lesser GPL)** — weak copyleft for libraries: the library itself stays copyleft, but programs that merely *link* to it may remain proprietary.
- **GNU AGPL (Affero GPL)** — like the GPL, but the source-sharing obligation also triggers when the software is offered as a **network service** (SaaS), not only when binaries are distributed.

### Permissive licenses

A **permissive** license imposes minimal conditions — typically just preserving the copyright notice and disclaimer. Derivative works may be relicensed, even as proprietary software.

- **BSD licenses** (2-clause and 3-clause) — very short; the 3-clause variant adds a non-endorsement clause.
- **MIT License** — extremely popular for its simplicity; requires only attribution.
- **Apache License 2.0** — permissive, with an explicit **patent grant** protecting users from patent claims by contributors.

### Quick comparison

| Aspect | Copyleft (GPL) | Permissive (MIT/BSD/Apache) |
|--------|----------------|------------------------------|
| Modified versions must stay under the same license | Yes | No |
| Can be incorporated into proprietary products | No (source must be released) | Yes |
| Typical goal | Keep software free forever | Maximize adoption and reuse |

**License compatibility** matters when combining code: e.g., code under GPLv2-only cannot be merged with GPLv3 code, and permissively licensed code can flow *into* GPL projects but GPL code cannot flow into a proprietary product.

---

## 3. Creative Commons — Licensing Beyond Software

Software licenses fit poorly for documentation, images, music, or courseware. **Creative Commons (CC)** provides modular licenses for creative works, built from four elements:

| Element | Meaning |
|---------|---------|
| **BY** (Attribution) | Credit the original author |
| **SA** (ShareAlike) | Derivatives must use the same license (copyleft-like) |
| **NC** (NonCommercial) | No commercial use |
| **ND** (NoDerivatives) | No modified versions may be distributed |

Common combinations range from the very open **CC BY** to the most restrictive **CC BY-NC-ND**. There is also **CC0**, a public-domain dedication waiving all rights. Note that **NC** and **ND** variants are *not* considered "free culture" licenses, because they restrict reuse.

---

## 4. Inspecting Licenses on a Linux System

You can verify the license of installed software directly from the package manager.

On **RPM-based** systems (Fedora, RHEL, openSUSE):

```bash
$ rpm -qi bash | grep -i license
License     : GPL-3.0-or-later
```

On **Debian/Ubuntu** systems, each package ships a copyright file:

```bash
$ head -n 5 /usr/share/doc/bash/copyright
This is Debian GNU/Linux's prepackaged version of the FSF's GNU Bash,
the Bourne Again SHell.
...
```

Debian also stores the full text of common licenses locally:

```bash
$ ls /usr/share/common-licenses/
Apache-2.0  BSD  GPL-2  GPL-3  LGPL-2  LGPL-2.1  LGPL-3  ...
```

Many GPL programs display license information with `--version`:

```bash
$ bash --version
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
Copyright (C) 2022 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
```

---

## 5. Open Source Business Models

"Open source" does not mean "no revenue." Sustainable models built on FOSS include:

- **Support and services** — selling subscriptions, consulting, training, and certified support for free software (e.g., Red Hat with RHEL, SUSE).
- **Dual licensing** — the same code offered under a copyleft license *and* a commercial license for customers who cannot comply with copyleft (e.g., MySQL historically).
- **Open core** — a free base product plus proprietary add-ons or enterprise features.
- **SaaS / hosting** — running open source software as a managed cloud service.
- **Donations, sponsorship, and foundations** — projects funded by users and companies (e.g., the Linux Foundation, Apache Software Foundation).
- **Hardware bundling** — selling devices whose value comes partly from the FOSS they run (routers, Android phones).

For the exam, remember: the GPL explicitly **allows selling** copies of the software — the obligation is to provide source code to recipients, not to give the software away at zero cost.

---

## 6. Key Points to Remember

- The **four freedoms** (run, study, redistribute, distribute modifications) define Free Software; **source code access** is a precondition for freedoms 1 and 3.
- **FSF** = philosophical/ethical movement, author of the **GPL** family; **OSI** = pragmatic movement, approves licenses against the **Open Source Definition**.
- **Copyleft** (GPL, LGPL, AGPL) forces derivatives to remain free; **permissive** (MIT, BSD, Apache 2.0) allows proprietary reuse.
- **Creative Commons** licenses cover non-software works; BY/SA/NC/ND are the building blocks.
- Freeware/shareware ≠ Free Software: price is irrelevant, **rights** are what count.

---

## Referencias

- LPI Learning Materials — Topic 1.3, Open Source Software and Licensing: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- GNU Project — What is Free Software? (the four freedoms): https://www.gnu.org/philosophy/free-sw.html
- GNU Project — Licenses (GPL, LGPL, AGPL): https://www.gnu.org/licenses/licenses.html
- Open Source Initiative — The Open Source Definition: https://opensource.org/osd
- Open Source Initiative — Approved Licenses: https://opensource.org/licenses
- Creative Commons — About the Licenses: https://creativecommons.org/licenses/
- Free Software Foundation: https://www.fsf.org/