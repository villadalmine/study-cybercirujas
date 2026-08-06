# LPI Open Source Essentials (Exam 050-100) — Topic 1.1: Software Components
**Exam Topic Weight:** 5  
**Target Role:** Senior SRE / Platform Architect  
**Official Reference:** [Linux Professional Institute — Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## Technical Overview & Architectural Deep-Dive

Software components form the foundational building blocks of modern Linux distributions and cloud-native runtime environments. Understanding how software transitions from human-readable source code into executable binary formats, how shared libraries link dynamically at execution time, how dependency graphs are managed by package systems, and how licensing constraints impact supply-chain architecture is vital for SREs and Platform Engineers.

```
+-----------------------------------------------------------------------------------+
|                               SOURCE CODE (.c / .h)                               |
+-----------------------------------------------------------------------------------+
                                          |
                                          v  [ Preprocessor & Compiler: gcc -S ]
+-----------------------------------------------------------------------------------+
|                               ASSEMBLY CODE (.s)                                  |
+-----------------------------------------------------------------------------------+
                                          |
                                          v  [ Assembler: gcc -c ]
+-----------------------------------------------------------------------------------+
|                         RELOCATABLE OBJECT FILE (.o)                              |
+-----------------------------------------------------------------------------------+
                      /                                      \
                     /                                        \
   [ Static Archiver: ar rcs ]                  [ Dynamic Linker: gcc -shared -fPIC ]
                    v                                          v
+----------------------------------------+   +--------------------------------------+
|       STATIC LIBRARY (.a archive)      |   |       SHARED OBJECT (.so library)    |
+----------------------------------------+   +--------------------------------------+
                    \                                          /
                     \                                        /
                      v  [ Linker: ld / gcc ]                v  [ Dynamic Linker: ld-linux.so ]
+-----------------------------------------------------------------------------------+
|                           EXECUTABLE BINARY (ELF Format)                          |
|  +-------------------+  +-------------------+  +-------------------------------+  |
|  | GOT (Global Offset|  | PLT (Procedure    |  | .text / .data / .rodata       |  |
|  | Table)            |  | Linkage Table)    |  | Sections                      |  |
|  +-------------------+  +-------------------+  +-------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Key Architectural Concepts

1. **Compilation Pipeline**:
   - **Preprocessing (`cpp`)**: Expands macros (`#define`), resolves includes (`#include`), strips comments.
   - **Compilation (`cc1`)**: Translates high-level code to assembly language.
   - **Assembly (`as`)**: Converts assembly to relocatable machine code (Object File `.o`).
   - **Linking (`ld`)**: Merges object files, resolves external symbol references, constructs GOT/PLT tables, generates final Executable and Linkable Format (ELF) binary.

2. **Linking Mechanisms & Trade-offs**:
   - **Static Linking (`.a`)**: Copies object code directly into target binary at build time.
     - *Pros*: Self-contained, zero external runtime library dependencies, immune to runtime library breakage ("DLL Hell").
     - *Cons*: Larger binary size, higher memory footprint (no memory sharing across processes), requires full rebuild to patch CVEs in vendor dependencies.
   - **Dynamic Linking (`.so`)**: Stores references to symbols; dynamic loader (`ld-linux.so`) maps shared pages into memory space during startup.
     - *Pros*: Memory efficient via shared read-only `.text` pages, single-point patching for security vulnerabilities.
     - *Cons*: Runtime latency during initial symbol lookup, runtime vulnerability to missing/incompatible library versions.

3. **ELF Internals & Symbol Resolution**:
   - **PLT (Procedure Linkage Table)** & **GOT (Global Offset Table)**: Facilitate Position Independent Code (PIC). The GOT stores absolute addresses of global data and functions, while the PLT provides stub trampolines that invoke `ld-linux.so` lazy binding upon first call.
   - **RPATH vs RUNPATH**: Hardcoded library search paths embedded in the ELF header (`DT_RPATH` / `DT_RUNPATH`). `DT_RPATH` takes precedence over `LD_LIBRARY_PATH`, whereas `DT_RUNPATH` can be overridden by `LD_LIBRARY_PATH`.

4. **Package Management Mechanics**:
   - Software components are distributed via compressed archives containing binary payloads, metadata, maintainer scripts (`preinst`, `postinst`, `prerm`, `postrm`), and dependency specifications (`Depends`, `Provides`, `Recommends`).
   - Package managers (`dpkg`/`apt` on Debian/Ubuntu, `rpm`/`dnf` on RHEL/Fedora) maintain a local state database to validate file ownership, dependency trees, and transaction integrity.

---

## Guided Hands-On Exercises

### Exercise 1: Compiling, Archiving, and Dynamic Linking Diagnostics

In this exercise, you will create a custom modular C library, build both static (`.a`) and shared (`.so`) versions, compile executables against both, and use low-level binary analysis tools to inspect symbol tables and segment layouts.

#### Step 1: Create the Source Structure
Create a working directory `/tmp/sre_lab` and construct the source files for a simple calculation component (`calculator.c`, `calculator.h`) and a caller app (`main.c`).

```bash
mkdir -p /tmp/sre_lab && cd /tmp/sre_lab

cat <<'EOF' > calculator.h
#ifndef CALCULATOR_H
#define CALCULATOR_H

int add_metrics(int val1, int val2);
int multiply_metrics(int val1, int val2);

#endif
EOF

cat <<'EOF' > calculator.c
#include "calculator.h"

int add_metrics(int val1, int val2) {
    return val1 + val2;
}

int multiply_metrics(int val1, int val2) {
    return val1 * val2;
}
EOF

cat <<'EOF' > main.c
#include <stdio.h>
#include "calculator.h"

int main() {
    int count = add_metrics(1024, 2048);
    int throughput = multiply_metrics(count, 2);
    printf("[SYSTEM STATUS] Processed Count: %d | Throughput: %d\n", count, throughput);
    return 0;
}
EOF
```

#### Step 2: Build a Static Library (`.a`) and Statically-Linked Binary
Compile `calculator.c` to an object file, archive it into `libcalculator.a`, and link `main.c` against it.

```bash
gcc -c calculator.c -o calculator.o
ar rcs libcalculator.a calculator.o
gcc main.c -L. -lcalculator -o app_static
```

Verify binary properties and execution:
```bash
./app_static
ls -lh app_static libcalculator.a
```
*Expected Output:*
```text
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
-rwxr-xr-x 1 root root 16K Aug  6 18:50 app_static
-rw-r--r-- 1 root root 1.7K Aug  6 18:50 libcalculator.a
```

#### Step 3: Build a Shared Object (`.so`) with Position Independent Code (PIC)
Compile `calculator.c` with `-fPIC` to allow relocatable memory execution, compile the shared object, and link `main.c` dynamically.

```bash
gcc -c -fPIC calculator.c -o calculator_pic.o
gcc -shared calculator_pic.o -o libcalculator.so
gcc main.c -L. -lcalculator -o app_dynamic
```

#### Step 4: Diagnose Dynamic Linker Errors and Resolve Library Paths
Attempt to run `./app_dynamic` directly:
```bash
./app_dynamic
```
*Expected Output:*
```text
./app_dynamic: error while loading shared libraries: libcalculator.so: cannot open shared object file: No such file or directory
```

Analyze missing dependencies using `ldd`:
```bash
ldd app_dynamic
```
*Expected Output:*
```text
	linux-vdso.so.1 (0x00007ffe015b7000)
	libcalculator.so => not found
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f311c000000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f311c27e000)
```

Temporarily supply the library search path via environment variable and execute:
```bash
LD_LIBRARY_PATH=. ./app_dynamic
```
*Expected Output:*
```text
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
```

#### Step 5: Inspect Binary Symbol Tables and ELF Headers
Inspect dynamic symbols inside `app_dynamic` vs `app_static` using `nm` and `readelf`.

```bash
nm -D app_dynamic | grep _metrics
readelf -d app_dynamic | grep NEEDED
```
*Expected Output:*
```text
                 U add_metrics
                 U multiply_metrics
 0x0000000000000001 (NEEDED)             Shared library: [libcalculator.so]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
```

---

### Verification Questions — Exercise 1

1. **Question 1.1**: Why did `nm -D app_dynamic` list `add_metrics` with symbol type `U` (Undefined), whereas `app_static` includes the compiled symbol code directly inside its `.text` segment?
2. **Question 1.2**: What security risk or maintenance challenge arises when deploying statically linked binaries containing core dependencies like `openssl` or `glibc` in production Kubernetes pods?

---

### Exercise 2: Advanced Symbol Interposition, RPATH Embeddings, and Runtime Patching

In platform operations, you may need to override shared library functions dynamically for debugging or embed dynamic search paths (`RUNPATH`) directly inside ELF binaries during build pipelines.

#### Step 1: Embed `RUNPATH` to Eliminate External `LD_LIBRARY_PATH` Requirements
Re-link `app_dynamic` embedding an absolute `$ORIGIN` or path-based `RUNPATH` tag into the ELF header using `gcc -Wl,-rpath`.

```bash
gcc main.c -L. -lcalculator -Wl,-rpath,'$ORIGIN' -o app_rpath
ldd app_rpath
./app_rpath
```
*Expected Output:*
```text
	linux-vdso.so.1 (0x00007ffe67351000)
	libcalculator.so => ./libcalculator.so (0x00007f45a2c14000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f45a2a00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f45a2c1b000)
[SYSTEM STATUS] Processed Count: 3072 | Throughput: 6144
```

Verify embedded header details using `readelf`:
```bash
readelf -d app_rpath | grep -E 'RUNPATH|RPATH'
```
*Expected Output:*
```text
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
```

#### Step 2: Runtime Function Interposition using `LD_PRELOAD`
Construct a diagnostic library (`hook.c`) to intercept calls to `add_metrics` without modifying or recompiling `app_rpath` or `libcalculator.so`.

```bash
cat <<'EOF' > hook.c
#include <stdio.h>

int add_metrics(int val1, int val2) {
    printf("[SRE HOOK TRACE] Intercepted add_metrics(%d, %d)\n", val1, val2);
    return (val1 + val2) + 10000; // Inject modified return payload
}
EOF

gcc -c -fPIC hook.c -o hook.o
gcc -shared hook.o -o libhook.so
```

Execute the binary preloading `libhook.so`:
```bash
LD_PRELOAD=./libhook.so ./app_rpath
```
*Expected Output:*
```text
[SRE HOOK TRACE] Intercepted add_metrics(1024, 2048)
[SYSTEM STATUS] Processed Count: 13072 | Throughput: 26144
```

---

### Verification Questions — Exercise 2

1. **Question 2.1**: What is the lookup precedence hierarchy used by `ld-linux.so` when resolving shared object references during ELF binary execution? Rank: `LD_LIBRARY_PATH`, `DT_RPATH`, `DT_RUNPATH`, `/etc/ld.so.cache`.
2. **Question 2.2**: Why is `LD_PRELOAD` commonly disabled by Linux kernel security controls for binaries executing with `setuid` / `setgid` flags?

---

### Exercise 3: Inspection of Linux Package Management Components & Dependency Tree Analysis

Package managers encapsulate compiled binaries, static/shared objects, configuration files, and script hooks into single distributable archives (`.deb` / `.rpm`). In this exercise, you will inspect system package databases, analyze dependency trees, and extract package contents manually.

#### Step 1: Query System Packages and File Ownership
Identify which package owns a specific shared library on a Debian/Ubuntu or RHEL/CentOS environment.

For Debian/Ubuntu system:
```bash
dpkg -S /lib/x86_64-linux-gnu/libc.so.6
```
*Expected Output:*
```text
libc6:amd64: /lib/x86_64-linux-gnu/libc.so.6
```

Inspect detailed control metadata for `libc6`:
```bash
dpkg -s libc6 | grep -E 'Package|Version|Architecture|Status|Depends'
```
*Expected Output:*
```text
Package: libc6
Status: install ok installed
Architecture: amd64
Version: 2.35-0ubuntu3.8
Depends: libgcc-s1, cryptsetup
```

#### Step 2: Unpack and Audit a `.deb` Component Manual Payload
Download a low-level utility package (`curl`), inspect its archive structure, and manually extract control metadata without running maintainer scripts.

```bash
cd /tmp/sre_lab
apt-get download curl
ls -l curl*.deb
```

Extract the `.deb` archive components using `ar` (deb files are standard Ar archives):
```bash
ar x curl_*.deb
ls -l
```
*Expected Output:*
```text
-rw-r--r-- 1 root root      4 Aug  6 18:52 debian-binary
-rw-r--r-- 1 root root  14120 Aug  6 18:52 control.tar.xz
-rw-r--r-- 1 root root 210432 Aug  6 18:52 data.tar.xz
```

Inspect package control files and post-installation maintainer scripts:
```bash
tar -xf control.tar.xz
cat control | grep -E 'Package|Depends|Architecture'
```
*Expected Output:*
```text
Package: curl
Architecture: amd64
Depends: libc6 (>= 2.34), libcurl4 (= 7.81.0-1ubuntu1.16), zlib1g (>= 1:1.1.4)
```

#### Step 3: Analyze Dependency Graph Cascades
Analyze reverse dependencies (what breaks if a component is removed) using `apt-cache rdepends`.

```bash
apt-cache rdepends --installed libcurl4 | head -n 12
```
*Expected Output:*
```text
libcurl4
Reverse Depends:
  curl
  cmake
  git
  python3-pycurl
  systemd-journal-remote
```

---

### Verification Questions — Exercise 3

1. **Question 3.1**: What is the structural purpose of the `debian-binary`, `control.tar.xz`, and `data.tar.xz` members inside a standard `.deb` software component archive?
2. **Question 3.2**: If a production node experiences dependency corruption due to an interrupted package installation, what is the architectural difference between executing `apt-get install -f` vs manually forcing file overwrites using `dpkg --force-all`?

---

### Exercise 4: Open Source Licensing Audit and SBOM Verification

Understanding licensing models (Permissive vs Copyleft) and generating Software Bill of Materials (SBOM) manifests are key requirements when assembling cloud-native platforms.

#### Step 1: Software Component License Categorization
Analyze the three primary open-source licensing archetypes used in enterprise Linux software components:

| License Archetype | Representative Licenses | Architectural Impact / Constraints |
| :--- | :--- | :--- |
| **Permissive** | MIT, Apache 2.0, BSD-3-Clause | Grants full permission to modify, re-license, redistribute, and integrate into proprietary closed-source codebases without disclosing modified source code. |
| **Weak Copyleft** | LGPLv2.1 / LGPLv3, MPL 2.0 | Requires modifications to the library *itself* to be published under the LGPL. Dynamic linking against an LGPL library does **not** force the host application to open-source its code. |
| **Strong Copyleft** | GPLv2, GPLv3, AGPLv3 | Mandates that any derivative work or statically/dynamically linked binary distribution must release its full source code under the same GPL license. AGPL extends this network-service trigger (SaaS model). |

#### Step 2: Audit License Headers in System Packages
Query installed system software components for license attribution using the package management database.

```bash
cat /usr/share/doc/curl/copyright | head -n 20
```
*Expected Output:*
```text
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: curl
Source: https://curl.se/

Files: *
Copyright: 1996 - 2024, Daniel Stenberg, <daniel@haxx.se>, and many contributors
License: curl

License: curl
  Permission to use, copy, modify, and distribute this software for any purpose
  with or without fee is hereby granted...
```

---

### Verification Questions — Exercise 4

1. **Question 4.1**: If a proprietary enterprise microservice links statically (`.a`) against a GPLv3-licensed library, what legal and technical requirement is triggered under the GPLv3 license terms?
2. **Question 4.2**: How does the LGPLv3 license protect host applications from strong copyleft requirements when linking dynamically (`.so`) versus statically (`.a`)?

---

## Detailed Answer Key & Verification Explanations

<details>
<summary><strong>Click to expand Solution Key & Comprehensive Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1**:  
  When compiling `app_dynamic`, the linker (`gcc`/`ld`) encounters function references to `add_metrics` and `multiply_metrics`. Because `-lcalculator` was provided as a shared library (`libcalculator.so`), the linker does not embed the function body into `app_dynamic`. Instead, it emits undefined (`U`) symbol entries in the ELF Dynamic Symbol Table (`.dynsym`) along with a `NEED` header entry pointing to `libcalculator.so`. The actual resolution of symbol `U` to a physical memory offset is deferred until runtime, handled by `ld-linux.so` using the Procedure Linkage Table (PLT) and Global Offset Table (GOT). Conversely, `app_static` absorbed the raw machine code instructions from `libcalculator.a` directly into its `.text` segment during the static linking phase; hence, the symbol is defined locally inside the binary itself.

* **Answer 1.2**:  
  Static linking bundles dependency code directly inside each binary container image. 
  1. **Security Patching Overhead**: If a critical vulnerability (CVE) is discovered inside a shared dependency (e.g., `OpenSSL` or `zlib`), every single microservice binary statically linked against that library must be fully re-compiled, re-built into container images, and re-deployed across Kubernetes cluster deployments. Dynamic linking allows updating a single shared library package on the base image/OS host to fix vulnerabilities system-wide.
  2. **Memory Footprint**: Statically linked binaries cannot share read-only memory pages (`.text` segments) in RAM across kernel process boundaries, leading to increased memory utilization across high-density container hosts.

---

### Exercise 2 Solutions

* **Answer 2.1**:  
  The exact resolution order evaluated by the dynamic linker `ld-linux.so` is:
  1. **`DT_RPATH`** (embedded in ELF header), **ONLY IF** `DT_RUNPATH` is **not** present in the binary.
  2. **`LD_LIBRARY_PATH`** environment variable (unless running in `setuid`/`setgid` secure-execution mode).
  3. **`DT_RUNPATH`** (embedded in ELF header). (If `DT_RUNPATH` exists, `DT_RPATH` entries are completely ignored).
  4. **`/etc/ld.so.cache`** (compiled cache containing index of system libraries declared in `/etc/ld.so.conf`).
  5. Default system library search paths: `/lib64`, `/usr/lib64`, `/lib`, `/usr/lib`.

* **Answer 2.2**:  
  `LD_PRELOAD` allows arbitrary dynamic libraries to be loaded prior to all other libraries, enabling function overriding (symbol interposition). If `LD_PRELOAD` were permitted on binaries running with elevated privilege flags (`setuid`/`setgid`, such as `/usr/bin/passwd` or `sudo`), an unprivileged user could write a malicious library hooking standard library calls like `getuid()` or `fopen()`, execute the `setuid` binary with `LD_PRELOAD`, and achieve arbitrary privilege escalation to root. The kernel dynamic linker automatically ignores `LD_PRELOAD` and `LD_LIBRARY_PATH` when the process execution context detects `AT_SECURE` (setuid/setgid/capabilities).

---

### Exercise 3 Solutions

* **Answer 3.1**:  
  A standard `.deb` software component is an `ar` format archive containing three distinct files:
  1. **`debian-binary`**: A plain text file defining the package format version (typically `2.0`).
  2. **`control.tar.xz`** (or `.gz`): Contains package metadata, dependency declarations (`control`), file checksums (`md5sums`), system trigger scripts, and maintainer lifecycle hooks (`preinst`, `postinst`, `prerm`, `postrm`).
  3. **`data.tar.xz`** (or `.gz`/`.zst`): Contains the actual filesystem payload (executables, shared objects, configuration files, man pages) that will be extracted to the system root `/` upon package installation.

* **Answer 3.2**:  
  - **`apt-get install -f`** (`--fix-broken`): Invokes APT's graph solver engine to resolve incomplete state, broken dependency trees, or missing pre-requisites safely by fetching missing packages or cleaning unconfigured state in alignment with maintainer rules.
  - **`dpkg --force-all`**: Bypasses dependency checks, file overwrite protection, and version constraints, forcefully altering local state files. This can lead to system instability, corrupted package databases (`dpkg status`), missing shared libraries, or overwritten critical system components.

---

### Exercise 4 Solutions

* **Answer 4.1**:  
  GPLv3 is a **Strong Copyleft** license. Under GPLv3 section 6, if an application links statically against a GPLv3 component and is distributed to third parties, the entire combined work becomes a derivative work subject to GPLv3. The organization is legally obligated to make the complete source code of their proprietary enterprise microservice available under GPLv3, along with installation instructions (anti-tivoization protections) and patent grants.

* **Answer 4.2**:  
  LGPLv3 (Lesser General Public License) explicit provisions permit host applications to link dynamically against an LGPL library without forcing the host application to release its proprietary source code. The requirement is that users must be able to modify the LGPL library and re-link the application against the modified library. Dynamic linking satisfies this condition by keeping the shared object separate (`.so`), allowing users to replace the shared library on disk. Static linking against LGPL requires providing object files (`.o`) of the proprietary code so the user can manually re-link the application.

</details>

---

## Summary of Completed Tasks

- **Deep Technical Breakdown**: Detailed ELF compilation pipeline, static vs dynamic linking mechanics, GOT/PLT trampolines, RPATH/RUNPATH lookups, package structures (`.deb` internals), and open-source licensing archetypes.
- **Hands-on Laboratories**: Built modular C applications, constructed `.a` static archives and `.so` shared objects with PIC, analyzed dynamic loader failures using `ldd`/`nm`/`readelf`, embedded `RUNPATH`, hooked symbols via `LD_PRELOAD`, unpacked Debian package structures with `ar`/`tar`, analyzed dependency trees, and audited system copyrights.
- **Verification & Solutions**: Provided probing architectural questions after each lab module and a complete expanded answer key detailing security tradeoffs, dynamic loader lookup order, setuid security protections, and licensing compliance rules.