# Study Guide: LPI 702-100 (v1.0) – Topic 711.2: BSD Software and Package Management

**Target Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic Code:** 711.2 (BSD Software and Package Management)  
**Topic Weight:** 6.67  
**Role Target:** Principal Platform Architect / Senior Site Reliability Engineer (SRE)

---

## 1. Architectural Motivation & Production Problem Statement

In enterprise production environments, managing third-party software across heterogeneous BSD fleets (FreeBSD, OpenBSD, NetBSD) requires balancing two competing operational paradigms: **Source-based compilation** (Ports framework, `pkgsrc`) and **Pre-compiled binary package distribution** (`pkg`, `pkg_add`, `pkgin`).

### Production Problem 1: Build-time Customization vs. Deployment Velocity
Standard binary distribution mirrors supply baseline package builds using default compile-time knobs. In high-performance SRE workloads, off-the-shelf binaries introduce security risks and operational overhead:
* **Bloat & Attack Surface:** Default builds often include unused modules (e.g., compiling X11, GUI bindings, or legacy modules into headless edge routers or containerized micro-services).
* **Optimization Gaps:** Generic binaries miss CPU instruction extensions (`AVX512`, `AES-NI`) and custom memory allocators (`jemalloc` flags, `tcmalloc`) required for ultra-low latency services.
* **Security Hardening:** Enterprise compliance requires disabling insecure features (e.g., SSLv3/TLS1.0 fallback, weak ciphers, unneeded protocol handlers) globally across all built artifacts.

*Architectural Solution:* Implement a centralized, automated build farm (e.g., FreeBSD Poudriere or NetBSD pkgsrc bulk build system) that converts customized source ports into signed, version-pinned binary packages for fleet-wide distribution.

### Production Problem 2: Package Integrity, ABI Drift, and Supply Chain Security
Modern infrastructure deployment pipelines must defend against unauthorized package tampering, ABI breakage during rolling upgrades, and software vulnerability exposure (CVEs).
* Operating systems with decoupled base systems and third-party packages (the traditional BSD design) can experience library version mismatches (`libssl.so.30` vs `libssl.so.32`) if binary packages are updated asynchronously across nodes.
* Third-party mirror compromised payloads present direct remote execution vectors if cryptographically unsigned.

*Architectural Solution:* Enforce cryptographic signature validation (`pkg` RSA/ED25519 repository signatures, OpenBSD `signify`), maintain immutable local package repositories, and run automated CVE scanning (`pkg audit`, `pkg_admin audit`) during deployment pipelines.

---

## 2. Deep-Dive Technical Comparisons & Trade-Off Analysis

### Table 2.1: BSD Binary Package Management Frameworks

| Technical Dimension | FreeBSD (`pkg` / Next Generation `pkgng`) | OpenBSD (`pkg_add`, `pkg_delete`, `pkg_info`) | NetBSD (`pkgin` over `pkg_install`) |
| :--- | :--- | :--- | :--- |
| **Local Database Engine** | SQLite3 (`/var/db/pkg/local.sqlite`) | File-based meta-tree (`/var/db/pkg/`) | File-based (`/var/db/pkg/`) + SQLite (`pkgin.db`) |
| **Repo Meta Storage** | Signed Tarball containing `meta.conf`, `packagesite.yaml`, `digests` | Text lists on HTTP/FTP mirror via `installurl` | Compressed repository database `pkg_summary.gz` |
| **Cryptographic Model** | RSA/Ed25519 Signatures, OpenSSL / SSH keypairs | `signify(1)` public key cryptographic verification | GPG / SHA512 digest verification via `pkg_admin` |
| **Locking Mechanism** | Database-level lock flags (`pkg lock`) | Manual package pinning / version freeze | Exclusion rules in `pkgin.conf` |
| **Dependency Resolution** | Advanced solver (SAT-based solver engine) | Deterministic sequential parser (`pkg_add -u`) | Dependency graph resolver using SQLite local cache |
| **ABI Guard Rails** | Enforces OS kernel/userland version match (`ABI` string) | Enforces precise OS release tag matching (`%M`) | Uses `PKGPATH` and explicit library version checks |

### Table 2.2: Source-Based Build Frameworks

| Feature / Architecture | FreeBSD Ports (`/usr/ports`) | OpenBSD Ports (`/usr/ports`) | NetBSD `pkgsrc` (`/usr/pkgsrc`) |
| :--- | :--- | :--- | :--- |
| **Primary Build File** | `Makefile` + `bsd.port.mk` | `Makefile` + `bsd.port.mk` | `Makefile` + `mk/bsd.pkg.mk` |
| **Global Tuning File** | `/etc/make.conf` | `/etc/mk.conf` | `/etc/mk.conf` |
| **Cross-Platform Support** | FreeBSD-centric (limited DragonFly BSD) | OpenBSD-centric | Highly Portable (NetBSD, macOS, Linux, SmartOS, Solaris) |
| **Interactive Config** | `make config` (Dialog-based ncurses GUI) | Manual `FLAVORS` and `MULTI_PACKAGES` env flags | `make config` or explicit `PKG_OPTIONS.pkgname` in `mk.conf` |
| **Isolated Build System** | Poudriere (Uses `jail(8)` and ZFS snapshots) | `dpb(1)` (Distributed Ports Builder with `chroot`) | `pbulk` (Parallel Bulk Build in `chroot`/sandbox) |

---

## 3. Production Configuration Manifests & Infrastructure Configurations

### 3.1 FreeBSD Enterprise Package Repository Configuration
Location: `/usr/local/etc/pkg/repos/EnterpriseSRE.conf`

```yaml
# /usr/local/etc/pkg/repos/EnterpriseSRE.conf
# Enterprise FreeBSD Package Repository Specification
# Enforces TLS enforcement, cryptographic signature validation, and custom mirrors.

EnterpriseSRE: {
  url: "pkg+https://pkg-mirror.internal.netops.zone/freebsd/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/ssl/certs/pkg-repository.pub",
  enabled: true,
  priority: 100,
  ip_version: 4
}

FreeBSD: {
  enabled: false
}
```

---

### 3.2 FreeBSD System-Wide Port Build Overrides
Location: `/etc/make.conf`

```make
# /etc/make.conf
# Production Build Environment Global Overrides

# Global compiler optimization and CPU architecture targeting
CFLAGS= -O2 -pipe -march=x86-64-v3 -fstack-protector-strong
CXXFLAGS= -O2 -pipe -march=x86-64-v3 -fstack-protector-strong

# Disable GUI/X11 bindings globally across all builds
WITHOUT_X11= yes
WITHOUT_GUI= yes

# Enforce modern SSL provider selection
DEFAULT_VERSIONS+= ssl=openssl python=3.11 perl5=5.36

# Port-specific default options overrides
www_nginx_SET= HTTP2 HTTP_GZIP_STATIC HTTP_REALIP MODULES VTS
www_nginx_UNSET= DEBUG HTTP_AUTOINDEX HTTP_DAV HTTP_SSI XSLT

security_openssl_UNSET= SSL3 TLS1 TLS1_1
```

---

### 3.3 FreeBSD Poudriere Isolated Build Farm Configuration
Location: `/usr/local/etc/poudriere.conf`

```ini
# /usr/local/etc/poudriere.conf
# Isolated Package Build Farm Architecture Settings

ZPOOL=tank
ZROOTFS=/poudriere
FREEBSD_HOST=https://ftp.freebsd.org
RESOLV_CONF=/etc/resolv.conf
BASEFS=/usr/local/poudriere
USE_PORTLINT=no
USE_TMPFS=yes
TMPFS_LIMIT=16
MAX_MEMORY=32
PARALLEL_JOBS=8
PREPARE_PARALLEL_JOBS=4
ALLOW_MAKE_JOBS=yes
NLISTJOBS=4

# Cryptographic Signatures for generated pkg repositories
PKG_REPO_SIGNING_KEY=/etc/ssl/keys/poudriere_pkg.key

# Path to custom make.conf passed to jails
DEFAULT_POUDRIERE_BUILD_MAKEFILE=/usr/local/etc/poudriere-make.conf

# Log formatting
HTML_TYPE="hosted"
```

---

### 3.4 OpenBSD Network Package Mirror Configuration
Location: `/etc/installurl`

```text
# /etc/installurl
# Production Mirror Endpoint for OpenBSD pkg_add(1) and syspatch(8)
https://cdn.openbsd.org/pub/OpenBSD
```

---

### 3.5 NetBSD Package Source (`pkgsrc`) & `pkgin` Configuration Manifests
Location: `/etc/mk.conf` (NetBSD Port Source Tuning)

```make
# /etc/mk.conf - NetBSD pkgsrc global configuration
.ifdef PKG_SYSCONFDIR
  ACCEPTABLE_LICENSES+= MIT bsdtar-license gnu-gpl-v2 gnu-gpl-v3
.endif

# Infrastructure Directories
PKG_DBDIR=           /var/db/pkg
LOCALBASE=            /usr/pkg
VARBASE=              /var
PKGINFODIR=           info
PKGMANDIR=            man

# Compiler & Hardening
CFLAGS+=              -O2 -fPIC -fstack-protector-all
PKGSRC_USE_SSP=       yes
PKGSRC_USE_FORTIFY=   strong
PKGSRC_USE_RELRO=     full

# Package-specific customization
PKG_OPTIONS.nginx=    http2 ssl pcre IPv6
PKG_OPTIONS.curl=     gssapi openssl -gnutls
```

Location: `/usr/pkg/etc/pkgin/repositories.conf` (NetBSD `pkgin` Binary Repo Setup)

```text
# /usr/pkg/etc/pkgin/repositories.conf
# Direct binary repository configuration for pkgin
https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All
```

---

### 3.6 Automated Shell Script: Custom Signed Package Repository Builder (FreeBSD)
Location: `/usr/local/sbin/build-custom-repo.sh`

```bash
#!/bin/sh
# Production script: Packages compiled ports into a cryptographically signed repo
set -e

REPO_ROOT="/usr/local/www/packages"
PKG_KEY="/etc/ssl/keys/pkg_repo.key"
PKG_PUB="/usr/local/etc/ssl/certs/pkg-repository.pub"
STAGING_DIR="/tmp/pkg-stage"

mkdir -p "${REPO_ROOT}" "${STAGING_DIR}"

echo "[+] Creating Package Repository Metadata..."
# Generate repository metadata DB using RSA key for signing
pkg repo ${REPO_ROOT} ${PKG_KEY}

echo "[+] Verifying Repository Integrity..."
pkg repo-check ${REPO_ROOT}

echo "[+] Updating Repository Permissions..."
chmod -R 755 ${REPO_ROOT}
chown -R www:www ${REPO_ROOT}

echo "[SUCCESS] Package repository ready at ${REPO_ROOT}."
```

---

## 4. Step-by-Step CLI Workflows & Production Terminal Outputs

### 4.1 FreeBSD Modern Binary Package Management (`pkg`)

#### Command: Remote Package Search and Detailed Information Inspection
```shell
$ pkg search -F name -S description -e nginx
```
```text
nginx-1.26.1,2                 Robust, small and high performance http and reverse proxy server
```

```shell
$ pkg info --remote --full nginx
```
```text
name: "nginx"
version: "1.26.1,2"
origin: "www/nginx"
comment: "Robust, small and high performance http and reverse proxy server"
arch: "FreeBSD:14:amd64"
www: "https://nginx.org"
maintainer: "osa@FreeBSD.org"
prefix: "/usr/local"
licenselogic: "single"
licenses: ["BSD2CLAUSE"]
flatsize: 2.45MiB
pkgsize: 812KiB
desc: |
  NGINX is an HTTP and reverse proxy server, a mail proxy server, and a generic
  TCP/UDP proxy server.
deps:
  pcre2: 10.43
  libxml2: 2.11.7
  openssl: 3.0.13,1
```

#### Command: Installing Package with Strict Dependency Checks
```shell
# pkg install -y www/nginx
```
```text
Updating EnterpriseSRE repository catalogue...
Fetching meta.conf: 100%    178 B   0.2kB/s    00:01    
Fetching packagesite.pkg: 100%  7.12MiB   3.55MiB/s    00:02    
Processing entries: 100%
EnterpriseSRE repository update completed. 34120 packages processed.
Checking integrity... done (0 conflicting)
The following 3 package(s) will be affected (of 0 checked):

New packages to be INSTALLED:
	libxml2: 2.11.7
	nginx: 1.26.1,2
	pcre2: 10.43

Number of packages to be installed: 3

The process will require 8 MiB more space.
2 MiB to be downloaded.
[1/3] Fetching libxml2-2.11.7.pkg: 100%  850 KiB 850.0kB/s    00:01
[2/3] Fetching pcre2-10.43.pkg: 100%  620 KiB 620.0kB/s    00:01
[3/3] Fetching nginx-1.26.1,2.pkg: 100%  812 KiB 812.0kB/s    00:01
Checking integrity... done (0 conflicting)
[1/3] Installing pcre2-10.43...
[1/3] Extracting pcre2-10.43: 100%
[2/3] Installing libxml2-2.11.7...
[2/3] Extracting libxml2-2.11.7: 100%
[3/3] Installing nginx-1.26.1,2...
===> Creating groups.
Creating group 'www' with gid '80'.
===> Creating users
Creating user 'www' with uid '80'.
[3/3] Extracting nginx-1.26.1,2: 100%
Message from nginx-1.26.1,2:

--
Recent version of NGINX introduces strict URI validation rules.
Ensure configuration compliance before restarting rc daemon.
```

#### Command: Securing Core Production Packages (Locking)
To prevent accidental updates or automated removal during `pkg autoremove`:
```shell
# pkg lock nginx
```
```text
nginx-1.26.1,2: lock which package? [y/N]: y
Locking nginx-1.26.1,2
```

```shell
# pkg lock -l
```
```text
Currently locked packages:
nginx-1.26.1,2
```

#### Command: Vulnerability Audit Scan (`pkg audit`)
```shell
$ pkg audit -F
```
```text
Fetching vulndbx.tar.xz: 100%  512 KiB 512.0kB/s    00:01    
curl-8.7.1 is vulnerable:
  curl -- heap-based buffer overflow in HTTP/2 frame handling
  CVE: CVE-2024-2398
  WWW: https://vuxml.freebsd.org/freebsd/8f4c2c1a-0518-11ef-8b87-00155d006802.html

1 problem(s) in 1 installed package(s) found.
```

---

### 4.2 FreeBSD Ports Source-Based Compilation Workflow

#### Command: Fetching and Updating the Ports Tree via Git
```shell
# git clone --branch main https://git.freebsd.org/ports.git /usr/ports
```
```text
Cloning into '/usr/ports'...
remote: Enumerating objects: 5412901, done.
remote: Counting objects: 100% (5412901/5412901), done.
remote: Compressing objects: 100% (982011/982011), done.
remote: Total 5412901 (delta 3412091), reused 5409800 (delta 3409112)
Receiving objects: 100% (5412901/5412901), 1.18 GiB | 18.42 MiB/s, done.
Resolving deltas: 100% (3412091/3412091), done.
Updating files: 100% (154012/154012), done.
```

#### Command: Configuring and Compiling a Port
```shell
# cd /usr/ports/www/nginx
# make config
```
*(Dialog interface renders choices saved to `/var/db/ports/www_nginx/options`)*

```shell
# make BATCH=yes install clean
```
```text
===>  License BSD2CLAUSE accepted by the user
===>  Found saved configuration for nginx-1.26.1,2
===>   nginx-1.26.1,2 depends on file: /usr/local/sbin/pkg - found
===> Fetching all distfiles required by nginx-1.26.1,2 for building
=> SHA256 Checksum OK for nginx-1.26.1.tar.gz.
===>  Extracting for nginx-1.26.1,2
=> SHA256 Checksum OK for nginx-1.26.1.tar.gz.
===>  Patching for nginx-1.26.1,2
===>   nginx-1.26.1,2 depends on shared library: libpcre2-8.so - found (/usr/local/lib/libpcre2-8.so)
===>  Configuring for nginx-1.26.1,2
configuring additional modules
configuring version 1.26.1
...
Configuration summary
  + using system PCRE2 library
  + OpenSSL library support is enabled
  + using system zlib library

===>  Building for nginx-1.26.1,2
cc -c -O2 -pipe -march=x86-64-v3 -fstack-protector-strong -I src/core \
	-I src/event -I src/os/unix -o objs/src/core/nginx.o src/core/nginx.c
cc -o objs/nginx objs/src/core/nginx.o ... -L/usr/local/lib -lpcre2-8 -lcrypto -lssl
===>  Installing for nginx-1.26.1,2
===>   Registering installation for nginx-1.26.1,2
Installing nginx-1.26.1,2...
===>  Cleaning for nginx-1.26.1,2
```

---

### 4.3 OpenBSD Package Management (`pkg_add`, `pkg_info`, `pkg_delete`)

#### Command: Installing Software via OpenBSD `pkg_add`
```shell
# export PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/7.5/packages/amd64/
# pkg_add -v rsync
```
```text
Update infrastructure refreshed to 7.5
rsync-3.3.0: pcre2-10.42p0: ok
rsync-3.3.0: ok
Read shared items: ok
```

#### Command: Searching Packages via OpenBSD Ports Query (`sqlports`)
OpenBSD provides a structured SQLite database (`sqlports`) for querying port metadata:
```shell
$ sqlite3 /usr/local/share/sqlports "SELECT FULLPKGPATH, COMMENT FROM PORTS WHERE PKGNAME LIKE 'curl%';"
```
```text
net/curl|curl open-source transfer tool using Internet protocols
net/curl,-main|curl open-source transfer tool using Internet protocols
net/curl,-psl|Public Suffix List support library for curl
```

#### Command: Performing System-Wide Package Upgrades
```shell
# pkg_add -u -v
```
```text
Update infrastructure refreshed to 7.5
Running check-substitutions
Upgrading rsync-3.3.0 to rsync-3.3.1
rsync-3.3.0->rsync-3.3.1: ok
Read shared items: ok
```

---

### 4.4 NetBSD Binary Package Management (`pkgin` & `pkg_install`)

#### Command: Initializing and Updating Database Index
```shell
# pkgin update
```
```text
reading repository descriptors ...
downloading pkg_summary.gz done
processing pkg_summary.gz done
database for https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All is up-to-date
```

#### Command: Installing Package with `pkgin`
```shell
# pkgin -y install htop
```
```text
calculating dependencies...done.

1 package to install:
  htop-3.3.0

0 to refresh, 0 to upgrade, 1 to install
0B to download, 412KiB to install

installing htop-3.3.0...
pkg_add: Package `htop-3.3.0' registered successfully
marking htop-3.3.0 as non auto-removable
```

#### Command: Auditing Installed Packages for Known Security Vulnerabilities (`pkg_admin`)
```shell
# pkg_admin fetch-pkg-vulnerabilities
```
```text
pkg_vulnerabilities size 245109 bytes received OK.
```

```shell
# pkg_admin audit
```
```text
Package python310-3.10.11 has a vulnerable-ge vulnerability, see https://nvd.nist.gov/vuln/detail/CVE-2023-24329
```

---

## 5. Verification & Troubleshooting Guide

### Diagnostic Flowchart: Resolving Package / Port Breakages

```
               [Package Failure Encountered]
                             │
            Is it a Binary or Source Failure?
              ┌──────────────┴──────────────┐
           [Binary]                      [Source]
              │                             │
    Run Cryptographic Check       Inspect Build Log & Env
     `pkg check -s -a`            `make missing` / `pkg-config`
              │                             │
    Has Shared Lib Drifted?        Verify /etc/make.conf
     `pkg check -d -a`             Check CFLAGS / Options
              │                             │
    ┌─────────┴─────────┐         ┌─────────┴─────────┐
[Corrupted DB]    [Missing Lib] [Fetch Failed] [Lib Mismatch]
      │                 │              │              │
 Rebuild DB       Reinstall Dep   Update URL     Rebuild Ports
`pkg backup`      `pkg install -f` Check SHA256  in dependency
`pkg-static`                      Distfile        order
```

---

### Failure Matrix: Production Issue Diagnosis & Remediation

| Symptom / Error Message | Root Cause | Remediation Command / Workflow |
| :--- | :--- | :--- |
| `pkg: Signature mismatched` | Local public key mismatch or mirror repository payload has been corrupted/tampered. | 1. Verify key: `openssl rsa -in /etc/ssl/keys/pkg.key -pubout`<br>2. Force repository refresh: `pkg update -f`<br>3. Check `/usr/local/etc/pkg/repos/*.conf` |
| `pkg: sqlite error: database disk image is malformed` | Abrupt host hard reset or I/O failure corrupted SQLite local database (`local.sqlite`). | `# pkg-static backup -r /var/backups/pkg-backup-latest.sqlite`<br>OR restore schema:<br>`# sqlite3 /var/db/pkg/local.sqlite ".recover" \| sqlite3 /var/db/pkg/local_fix.sqlite && mv local_fix.sqlite local.sqlite` |
| `Shared object "libssl.so.30" not found, required by "nginx"` | Base OS major version upgraded without re-compiling/updating third-party packages. | `# pkg check -d -a`<br>Or force rebuild all dependent packages:<br>`# pkg upgrade -f` |
| `OpenBSD pkg_add: Can't find package for <pkg>` | Invalid `PKG_PATH`, incorrect release branch, or mirror out of sync. | 1. Check `/etc/installurl`<br>2. Export exact path: `export PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/$(uname -r)/packages/$(uname -m)/` |
| `NetBSD pkgin: pkg_summary.gz fetch failed` | Network connectivity failure, expired TLS root certificates, or invalid repo string. | 1. Verify HTTPS fetch: `ftp https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All/pkg_summary.gz`<br>2. Update `/usr/pkg/etc/pkgin/repositories.conf` |

---

### Step-by-Step Diagnostic Scenarios

#### Scenario 1: Repairing Broken Shared Library Dependencies on FreeBSD (`pkg check`)

*Issue:* A baseline FreeBSD OS patch updated a core library, causing third-party binaries to fail with dynamic linker errors (`ld-elf.so.1: Shared object not found`).

1. **Scan for broken shared library dependencies across all installed packages:**
```shell
# pkg check -d -a
```
```text
Checking all packages: 100%
nginx-1.26.1,2 is missing a required shared library: libssl.so.30
curl-8.7.1 is missing a required shared library: libssl.so.30
```

2. **Force-reinstall affected binaries from the configured enterprise repository:**
```shell
# pkg install -f www/nginx ftp/curl
```
```text
Updating EnterpriseSRE repository catalogue...
EnterpriseSRE repository is up to date.
The following 2 package(s) will be reinstalled:
	nginx-1.26.1,2
	curl-8.7.1

Proceed with this action? [y/N]: y
[1/2] Reinstalling nginx-1.26.1,2...
[2/2] Reinstalling curl-8.7.1...
Re-checking shared library dependencies...
Checking all packages: 100%
[SUCCESS] No missing shared library dependencies detected.
```

---

#### Scenario 2: Recovering from Corrupted FreeBSD Package Database

*Issue:* SQLite package database corrupted following an out-of-memory kernel panic.

1. **Verify failure using the standalone statically compiled binary `pkg-static`:**
```shell
# pkg-static info
```
```text
pkg-static: sqlite error sqlite3_exec /usr/src/lib/libpkg/pkgdb.c:1240: database disk image is malformed
```

2. **Execute recovery sequence via `pkg-static` shell tools:**
```shell
# cd /var/db/pkg
# cp local.sqlite local.sqlite.bak
# pkg-static shell .dump | pkg-static shell "sqlite3 local_recovered.sqlite"
# mv local_recovered.sqlite local.sqlite
# pkg-static check -s -a
```
```text
Checking checksums: 100%
Database recovery verified. 142 packages registered cleanly.
```

---

## 6. References & Official Documentation

* **LPI BSD Specialist Certification Overview:**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Handbook – Installing Applications: Packages and Ports:**  
  [https://docs.freebsd.org/en/books/handbook/ports/](https://docs.freebsd.org/en/books/handbook/ports/)

* **FreeBSD `pkg(8)` Manual Page:**  
  [https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8)

* **FreeBSD Poudriere Official Documentation:**  
  [https://wiki.freebsd.org/Poudriere](https://wiki.freebsd.org/Poudriere)

* **OpenBSD Package Management Guide (`pkg_add`):**  
  [https://www.openbsd.org/faq/faq15.html](https://www.openbsd.org/faq/faq15.html)

* **OpenBSD `pkg_add(1)` Manual Page:**  
  [https://man.openbsd.org/pkg_add.1](https://man.openbsd.org/pkg_add.1)

* **NetBSD `pkgsrc` Official Guide:**  
  [https://www.netbsd.org/docs/pkgsrc/](https://www.netbsd.org/docs/pkgsrc/)

* **NetBSD `pkgin` Package Manager Manual:**  
  [https://man.netbsd.org/pkgin.1](https://man.netbsd.org/pkgin.1)