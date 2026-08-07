# LPI 702: BSD Specialist Certification — Hands-On Lab Guide
## Topic 711.2: BSD Software and Package Management
**Exam Version:** 702-100 (v1.0) | **Exam Weight:** 6.67  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/) | [FreeBSD Handbook: Packages and Ports](https://docs.freebsd.org/en/books/handbook/ports/) | [NetBSD pkgsrc Guide](https://www.netbsd.org/docs/pkgsrc/) | [OpenBSD Package Management](https://www.openbsd.org/faq/faq15.html)

---

## Architecture & Internal Mechanics Blueprint

Modern BSD operating systems maintain a strict decoupling between the base operating system kernel/userland (managed via `freebsd-update`, `syspatch`, or source trees) and third-party software applications. Third-party software management across FreeBSD, OpenBSD, and NetBSD relies on two distinct paradigms: pre-compiled binary packages and source-based port frameworks.

```
+-----------------------------------------------------------------------------------+
|                            BSD THIRD-PARTY SOFTWARE LAYER                         |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|   +-------------------------------+       +-----------------------------------+   |
|   |   Binary Package Paradigm     |       |     Source / Ports Paradigm       |   |
|   +-------------------------------+       +-----------------------------------+   |
|   |  - FreeBSD: pkg (libpkg/sqlite)|      |  - FreeBSD: Ports (/usr/ports)    |   |
|   |  - OpenBSD: pkg_add (OpenBSD) |       |  - OpenBSD: Ports Framework       |   |
|   |  - NetBSD:  pkgin / pkg_add   |       |  - NetBSD:  pkgsrc (/usr/pkgsrc)  |   |
|   +---------------+---------------+       +-----------------+-----------------+   |
|                   |                                         |                     |
|                   v                                         v                     |
|   +-------------------------------+       +-----------------------------------+   |
|   | Automated Repositories &      |       | Cleanroom Build Engines           |   |
|   | Cryptographic Verification    |       | (Poudriere / dpb / pbulk)         |   |
|   +-------------------------------+       +-----------------------------------+   |
+-----------------------------------------------------------------------------------+
```

### Architectural Comparison Matrix

| OS Feature / Mechanism | FreeBSD (`pkg`) | OpenBSD (`pkg_add`) | NetBSD / Multi-OS (`pkgsrc` & `pkgin`) |
| :--- | :--- | :--- | :--- |
| **Primary Binary Tool** | `pkg` | `pkg_add`, `pkg_delete`, `pkg_info` | `pkgin`, `pkg_add`, `pkg_admin` |
| **Backend Metadata** | SQLite DB (`/var/db/pkg/local.sqlite`) | File-based specs (`/var/db/pkg/`) | File-based specs (`/var/db/pkg/`) |
| **Source Engine** | FreeBSD Ports Collection | OpenBSD Ports Infrastructure | `pkgsrc` (Portable Makefile engine) |
| **Cleanroom Build Tool**| `ports-mgmt/poudriere` | `dpb` (Distributed Ports Builder) | `pkgtools/pbulk` or `pkgtools/pkg_comp`|
| **Vulnerability Audit**| `pkg audit` (VuXML feed) | Errata / `pkg_info -q -U` | `pkg_admin audit` (pkg-vulnerabilities)|
| **Custom Flavors** | PORT_OPTIONS / Flavors | `FLAVOR` / `SUBPACKAGE` | Options Framework (`PKG_OPTIONS`) |

---

## Lab Exercises & Comprehension Checks

---

### Exercise 1: FreeBSD Binary Package Management (`pkg`), Repository Mirroring, and Security Auditing

#### Scenario
As a Senior SRE, you must configure a fleet of FreeBSD enterprise servers to fetch packages from an internal, cryptographically signed repository mirror rather than the public FreeBSD CDN. You must also implement automated vulnerability auditing using the VuXML database and safely manage package locks on critical production dependencies.

#### Step 1.1: Inspect Existing Repository Configuration and Local SQLite Metadata
Examine the active repository configuration and the local package database schema.

```bash
# Display active package repository configuration
pkg -vv | grep -A 15 "Repositories:"
```

*Expected Output:*
```text
Repositories:
  FreeBSD: { 
    url             : "pkg+http://pkg.FreeBSD.org/FreeBSD:14:amd64/quarterly",
    enabled         : yes,
    priority        : 0,
    mirror_type     : "SRV",
    signature_type  : "FINGERPRINTS",
    fingerprints    : "/usr/share/keys/pkg"
  }
```

```bash
# Query detailed package database status and count installed packages
pkg info -a | wc -l
pkg stats
```

*Expected Output:*
```text
Local package database:
	Installed packages: 142
	Disk space occupied: 2.1 GiB

Remote package database(s):
	Number of repositories: 1
	Packages available: 34120
```

#### Step 1.2: Override the Default Repository with a Custom Infrastructure Config
Create an enterprise repository override file in `/usr/local/etc/pkg/repos/CompanyRepo.conf` to disable default public fetching and route requests to an internal mirror with TLS and explicit fingerprint pinning.

```bash
# Create the override directory
mkdir -p /usr/local/etc/pkg/repos/

# Write the production repository override manifest
cat <<'EOF' > /usr/local/etc/pkg/repos/CompanyRepo.conf
FreeBSD: { enabled: false }

CompanyRepo: {
  url: "pkg+https://pkg-mirror.internal.net/FreeBSD:14:amd64/latest",
  mirror_type: "HTTP",
  signature_type: "PUBKEY",
  pubkey: "/etc/ssl/pkg-mirror.pub",
  enabled: true,
  priority: 100
}
EOF
```

```bash
# Test database updates against the new configuration endpoint
pkg update -f
```

#### Step 1.3: Package Lifecycle, Dependency Tracing, and Locking
Install the `nginx` web server, lock it to prevent accidental upgrades during routine maintenance, and inspect its reverse dependencies.

```bash
# Install nginx using binary package manager
pkg install -y www/nginx

# Lock nginx to prevent automated upgrades by batch SRE maintenance jobs
pkg lock www/nginx
```

*Expected Output:*
```text
www/nginx-1.26.1,1: locking package... Done
```

```bash
# Verify locked packages in the system
pkg lock -l
```

*Expected Output:*
```text
Currently locked packages:
www/nginx-1.26.1,1
```

```bash
# Trace shared library dependencies and required packages for nginx
pkg info -d www/nginx
pkg info -B www/nginx
```

*Expected Output:*
```text
www/nginx-1.26.1,1:
Depends on     :
	pcre2-10.43
	indexinfo-0.3.1
	libxml2-2.11.8

www/nginx-1.26.1,1:
Shared Libraries Required:
	libpcre2-8.so.0
	libssl.so.30
	libcrypto.so.30
	libz.so.6
```

#### Step 1.4: Execute Vulnerability Auditing via VuXML
Download the latest VuXML vulnerability definitions and audit all installed packages.

```bash
# Fetch latest vulnerability database and run full audit
pkg audit -F
```

*Expected Output:*
```text
Fetching vuln.xml.xz: 100%    512 KiB 1.2MiB/s    00:00    
0 problem(s) in 143 installed package(s) found.
```

---

#### Verification Questions — Exercise 1

1. **Question 1:** Why is it considered an SRE anti-pattern to modify `/etc/pkg/FreeBSD.conf` directly when configuring custom repositories, and what mechanism does `pkg` use to merge repository manifests?
2. **Question 2:** If `pkg audit -F` flags a critical vulnerability in `openssl` on a production FreeBSD host, but `pkg upgrade` reports "No packages available to upgrade", what are the two most common root causes in an enterprise environment using `quarterly` vs `latest` branches?
3. **Question 3:** What command line flag allows an administrator to run `pkg autoremove` in dry-run mode to inspect unreferenced dynamic dependencies without modifying the system state?

---

### Exercise 2: FreeBSD Ports Framework, Cleanroom Builds (`poudriere`), and `/etc/make.conf`

#### Scenario
Certain production microservices require custom compile-time flags (e.g., enabling HTTP/2, SSL ALPN support, disabling unwanted modules in Nginx) not present in standard binary packages. You must configure the FreeBSD Ports tree infrastructure, define centralized build flags via `/etc/make.conf`, and set up a Poudriere cleanroom build environment.

#### Step 2.1: Fetch and Extract the FreeBSD Ports Tree
Initialize the official FreeBSD ports tree using `git` or `portsnap`.

```bash
# Clone the latest ports tree into /usr/ports via Git
git clone --depth 1 https://git.FreeBSD.org/ports.git /usr/ports
```

```bash
# Verify ports tree structure
ls -ld /usr/ports/Mk /usr/ports/www/nginx
```

#### Step 2.2: Configure Centralized Port Options via `/etc/make.conf`
Configure `/etc/make.conf` to enforce system-wide compiler flags (`CFLAGS`), default software variants (e.g., Python 3.11, OpenSSL from ports), and custom port options.

```bash
# Write production build rules to /etc/make.conf
cat <<'EOF' > /etc/make.conf
# Optimization and CPU tuning
CFLAGS+= -O2 -pipe -fstack-protector-strong

# Force default language/runtime versions across all built ports
DEFAULT_VERSIONS+= python=3.11 ssl=openssl

# Global port knobs: Disable X11 GUI bindings, enable HTTP2
WITHOUT_X11=yes
www_nginx_SET= HTTP2 HTTP_PORTAL TLS SSL
www_nginx_UNSET= DEBUG XSLT DOCS
EOF
```

#### Step 2.3: Configure and Build a Port Manually
Navigate to the port directory, inspect options, configure knobs via a text UI dialog, and execute the build pipeline.

```bash
cd /usr/ports/www/nginx

# Non-interactively check configured options based on make.conf
make showconfig
```

*Expected Output:*
```text
===> The following configuration options for nginx-1.26.1,1 are currently set:
     DSD=off: Dynamic Seamless Diagnostic
     HTTP=on: Enable HTTP module
     HTTP2=on: Enable HTTP/2 protocol support
     HTTP_PORTAL=on: Internal portal extension
     SSL=on: Enable SSL module support
====> Options available for the group MODULES
     DEBUG=off: Build with debugging support
     XSLT=off: Enable XSLT module
```

```bash
# Run clean building, packaging, and installation pipeline
make clean
make BATCH=yes stage
make BATCH=yes install clean
```

#### Step 2.4: Configure Poudriere Cleanroom Bulk Build Environment
In production SRE operations, compiling software directly on production systems is prohibited. You must configure `poudriere` to build packages in an isolated `jail` environment using ZFS snapshots.

```bash
# Install poudriere
pkg install -y ports-mgmt/poudriere

# Create poudriere main configuration file
cat <<'EOF' > /usr/local/etc/poudriere.conf
ZPOOL=zroot
NO_ZFS=no
FREEBSD_HOST=https://download.FreeBSD.org
RESOLV_CONF=/etc/resolv.conf
BASEFS=/usr/local/poudriere
USE_PORTLINT=no
USE_TMPFS=yes
DISTFILES_CACHE=/usr/ports/distfiles
CHECK_CHANGED_DATA=yes
CHECK_CHANGED_DEPS=yes
EOF
```

```bash
# Initialize a Poudriere Jail for FreeBSD 14.1-RELEASE amd64
poudriere jail -c -j 141rel -v 14.1-RELEASE

# Create a ports tree inside Poudriere
poudriere ports -c -p enterprise_ports

# Verify Poudriere isolated environment status
poudriere jail -l
```

*Expected Output:*
```text
JAILNAME VERSION      ARCH  METHOD TIMESTAMP           PATH
141rel   14.1-RELEASE amd64 http   2026-08-06 18:30:00 /usr/local/poudriere/jails/141rel
```

---

#### Verification Questions — Exercise 2

1. **Question 1:** What is the primary operational advantage of using `poudriere` over executing `make install clean` directly inside `/usr/ports` on a production host?
2. **Question 2:** In `/etc/make.conf`, what is the precise syntax difference between setting a global option (e.g., `WITHOUT_X11=yes`) vs. setting a port-specific option for `net/haproxy` to enable LUA support?
3. **Question 3:** What ZFS filesystem features does `poudriere` leverage during bulk package builds to ensure build isolation and rapid teardown between job runs?

---

### Exercise 3: OpenBSD Package Ecosystem (`pkg_add`, `PKG_PATH`, `/etc/installurl`, and Flavors)

#### Scenario
OpenBSD utilizes a security-hardened, declarative package management system integrated with system security primitives (`pledge(2)` and `unveil(2)`). You need to configure mirror resolution via `/etc/installurl`, manage package installation with explicit flavors and subpackages, and perform automated, safe system-wide updates.

#### Step 3.1: Configure Mirror Resolution via `/etc/installurl`
Configure the system-wide repository URL for `pkg_add` and `syspatch`.

```bash
# Inspect or set the OpenBSD mirror URL
cat /etc/installurl
```

*If missing or needing modification, configure an official CDN mirror:*
```bash
echo "https://cdn.openbsd.org/pub/OpenBSD" > /etc/installurl
```

#### Step 3.2: Inspect Package Flavors and Install Multi-Variant Packages
OpenBSD packages often support `FLAVOR` options (e.g., no_x11, lite, hardened) and `SUBPACKAGE` options compiled from a single port tree.

```bash
# Search for Available PostgreSQL Server packages and examine Flavors
pkg_info -Q postgresql
```

*Expected Output:*
```text
postgresql-client-16.3
postgresql-docs-16.3
postgresql-server-16.3
```

```bash
# Search specifically for packages matching flavors (e.g., Python or Nginx flavors)
pkg_info -Q nginx
```

*Expected Output:*
```text
nginx-1.26.1-main
nginx-1.26.1-no_eval
nginx-1.26.1-passthrough
```

```bash
# Install nginx explicitly selecting the main flavor in verbose mode
pkg_add -vv nginx--main
```

*Expected Output snippet:*
```text
Update targets select nginx-1.26.1-main
Installing nginx-1.26.1-main...
...
Extracted 2841920 bytes in 0.4 seconds
```

#### Step 3.3: Manage Installed Packages, Query Files, and Audit System
Perform queries on package metadata, inspect file manifests registered in `/var/db/pkg`, and check for installed packages requiring updates.

```bash
# List all installed packages concisely
pkg_info -q
```

```bash
# Inspect all files installed by the nginx package
pkg_info -L nginx-1.26.1-main
```

*Expected Output:*
```text
Files installed by nginx-1.26.1-main:
/usr/local/sbin/nginx
/usr/local/man/man8/nginx.8
/etc/nginx/nginx.conf.sample
/usr/local/share/doc/nginx/README
```

```bash
# Perform a dry-run check of all packages against the active remote repository mirror
pkg_add -u -n
```

---

#### Verification Questions — Exercise 3

1. **Question 1:** In OpenBSD, how does `pkg_add` differentiate between installing two distinct flavors of the same package (for instance, `lua` bindings vs `no_x11` build), and what is the syntax required on the command line?
2. **Question 2:** What environment variable can override `/etc/installurl` during a single invocation of `pkg_add` in OpenBSD automation scripts?
3. **Question 3:** How does OpenBSD's architecture guarantee that binary packages built by third parties cannot modify arbitrary core operating system binaries during extraction?

---

### Exercise 4: NetBSD & Cross-Platform `pkgsrc` Engine (`pkgin`, `pkg_admin`, and `bmake`)

#### Scenario
`pkgsrc` is the native package management framework of NetBSD, highly portable across SmartOS, macOS, Linux, and FreeBSD. You must configure the binary package manager `pkgin`, perform database integrity validation via `pkg_admin`, and build a package from source using `bmake`.

#### Step 4.1: Configure Repository Mirrors and Initialize `pkgin`
Configure `/usr/pkg/etc/pkgin/repositories.conf` to fetch pre-compiled binaries for NetBSD.

```bash
# Display repository configuration for pkgin
cat /usr/pkg/etc/pkgin/repositories.conf
```

*Expected Output:*
```text
# NetBSD 10.0 x86_64 binary packages URL
https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.0/All
```

```bash
# Update local pkgin database cache
pkgin update
```

#### Step 4.2: Binary Package Operations with `pkgin` and Low-Level `pkg_add`
Search, install, and query software packages using both high-level (`pkgin`) and low-level (`pkg_info`/`pkg_admin`) commands.

```bash
# Search for curl in the binary repository
pkgin search curl
```

*Expected Output:*
```text
curl-8.7.1           Client that downloads or uploads files using URL syntax
```

```bash
# Install curl via pkgin
pkgin -y install curl
```

```bash
# Verify low-level registration in /var/db/pkg using pkg_info
pkg_info -e curl
```

*Expected Output:*
```text
curl-8.7.1
```

#### Step 4.3: Package Vulnerability Auditing with `pkg_admin`
Download the security vulnerability list and perform an audit on all installed packages.

```bash
# Download official vulnerabilities database file
pkg_admin fetch-pkg-vulnerabilities

# Audit all installed packages against the security database
pkg_admin audit
```

*Expected Output:*
```text
Package curl-8.7.1 has a low severity vulnerability: CVE-2024-XXXX (see http://curl.se/docs/adv_...)
```

#### Step 4.4: Source Compilation via `pkgsrc` and `/usr/pkg/etc/mk.conf`
Configure `pkgsrc` global build knobs in `mk.conf` and compile a package using NetBSD's `bmake`.

```bash
# Inspect / Create /usr/pkg/etc/mk.conf
cat <<'EOF' > /usr/pkg/etc/mk.conf
SPKGSRC_COMPILER= gcc
PKG_DBDIR= /var/db/pkg
LOCALBASE= /usr/pkg
VARBASE= /usr/pkg/var
ACCEPTABLE_LICENSES+= gnu-gpl-v3 MIT BSD
PKG_OPTIONS.curl= inet6 gnutls -openssl
EOF
```

```bash
# Navigate to a port directory in pkgsrc and execute bmake
cd /usr/pkgsrc/net/curl
bmake show-options
```

```bash
# Clean, compile, and package via bmake
bmake package
```

---

#### Verification Questions — Exercise 4

1. **Question 1:** What is the relationship between `pkgin` and `pkg_add`/`pkg_info` in NetBSD, and which tool maintains the binary repository dependency tree state?
2. **Question 2:** In `pkgsrc`, what configuration file serves the equivalent functional purpose of FreeBSD's `/etc/make.conf`, and where is it located by default?
3. **Question 3:** What command must be executed in NetBSD/pkgsrc to repair or rebuild the package dependency index database if `/var/db/pkg` metadata becomes corrupted?

---

### Exercise 5: Advanced SRE Troubleshooting: Dependency Auditing, Database Repair, and Conflict Resolution

#### Scenario
A production database server running FreeBSD experienced an unexpected power failure during a batch `pkg upgrade` execution. The local SQLite database (`/var/db/pkg/local.sqlite`) is out of sync with actual binaries on the filesystem, dynamic libraries (`.so`) are missing for critical applications, and several package files failed checksum validation. You must diagnose and repair the system state.

#### Step 5.1: Diagnose Missing Shared Library Dependencies (ABI Breakdown)
Run a system-wide check for missing shared libraries across all installed binary packages.

```bash
# Scan binary ELF headers against installed library paths
pkg check -d -a
```

*Expected Output:*
```text
Checking all packages: 100%
(www/nginx) /usr/local/sbin/nginx - Required library libpcre2-8.so.0 not found!
```

```bash
# Verify shared library dependencies of the specific broken binary using ldd
ldd /usr/local/sbin/nginx
```

*Expected Output:*
```text
/usr/local/sbin/nginx:
	libpcre2-8.so.0 => not found (0x0)
	libssl.so.30 => /usr/lib/libssl.so.30 (0x3b2a9e00000)
	libcrypto.so.30 => /usr/lib/libcrypto.so.30 (0x3b2aa200000)
	libc.so.7 => /lib/libc.so.7 (0x3b2aa800000)
```

#### Step 5.2: Detect File Corruption and Missing Files via Checksum Auditing
Audit the checksums of files on disk against SHA-256 hashes stored in SQLite.

```bash
# Run file integrity and checksum audit across all packages
pkg check -s -a
```

*Expected Output:*
```text
Checking checksums: 100%
pkg: /usr/local/etc/nginx/mime.types checksum mismatch
pkg: /usr/local/libexec/nginx/ngx_http_geoip_module.so is missing
```

#### Step 5.3: Repair Database Metadata and Force Package Re-installation
Fix missing dependencies, recalculate database metadata, and force-reinstall corrupted packages.

```bash
# Recalculate package metadata dependencies in local SQLite DB
pkg check -R
```

```bash
# Force reinstall the affected broken package and its missing libraries without touching configuration files
pkg install -f -y devel/pcre2 www/nginx
```

```bash
# Confirm shared library resolution is completely restored
ldd /usr/local/sbin/nginx
```

*Expected Output:*
```text
/usr/local/sbin/nginx:
	libpcre2-8.so.0 => /usr/local/lib/libpcre2-8.so.0 (0x3b2a9900000)
	libssl.so.30 => /usr/lib/libssl.so.30 (0x3b2a9e00000)
	libcrypto.so.30 => /usr/lib/libcrypto.so.30 (0x3b2aa200000)
	libc.so.7 => /lib/libc.so.7 (0x3b2aa800000)
```

---

#### Verification Questions — Exercise 5

1. **Question 1:** What does `pkg check -B` do on FreeBSD, and how does it differ from `pkg check -s`?
2. **Question 2:** If `/var/db/pkg/local.sqlite` becomes completely corrupted or zeroed out during an unclean shutdown, how can an SRE reconstruct the installed package list if ZFS snapshots are unavailable?
3. **Question 3:** In OpenBSD, if `pkg_add` fails due to conflicting shared library versions (`libfoo.so.1.0` vs `libfoo.so.2.0`) during an inline OS upgrade, what flag forces package replacement while recording broken dependencies for immediate post-fixup?

---

## Solutions & Deep-Dive Explanations

<details>
<summary>Click to Expand Answers and Technical Explanations</summary>

### Exercise 1 Answers

1. **Answer 1:** Modifying `/etc/pkg/FreeBSD.conf` directly is an SRE anti-pattern because `/etc/pkg/` is managed by the base operating system and can be overwritten during `freebsd-update` or OS upgrades. `pkg` uses a modular directory scheme `/usr/local/etc/pkg/repos/` where `.conf` files are parsed in alphabetical order. Files placed in `/usr/local/etc/pkg/repos/` override settings in `/etc/pkg/FreeBSD.conf` based on matching repository names (e.g., `FreeBSD: { enabled: false }`) and repository `priority` directives.
2. **Answer 2:** First, the host might be configured to track the `quarterly` branch (which receives security backports every 3 months) while the vulnerability fix was committed to `latest` and has not yet been backported to `quarterly`. Second, the package might be locked (`pkg lock`), preventing `pkg upgrade` from evaluating or modifying the package until explicitly unlocked with `pkg unlock`.
3. **Answer 3:** The command is `pkg autoremove -n` (or `--dry-run`). The `-n` flag simulates the action without deleting any packages from disk or removing entries from `/var/db/pkg/local.sqlite`.

---

### Exercise 2 Answers

1. **Answer 1:** `poudriere` runs builds in clean, isolated ZFS-backed `jail` environments containing no unstated dependencies. Building directly on host system ports (`/usr/ports`) risks contamination from libraries installed on the host host, non-reproducible build states, and potential downtime if build failures alter system configuration files mid-compilation.
2. **Answer 2:** Global options apply system-wide using predefined variables (e.g., `WITHOUT_X11=yes`). Port-specific options use the port's category and name formatted as `category_portname_SET` or `category_portname_UNSET` (e.g., `net_haproxy_SET= LUA` or `www_nginx_SET= HTTP2`).
3. **Answer 3:** `poudriere` leverages ZFS clone (`zfs clone`), snapshot (`zfs snapshot`), and fast rollback functionality. Before starting a build job, it clones a clean base jail ZFS dataset instantly. Once compilation finishes, it destroys the build workspace clone without leaving residual build artifacts or altering the pristine base jail.

---

### Exercise 3 Answers

1. **Answer 1:** OpenBSD package names follow the convention `stem-version-flavor`. When multiple flavors exist, `pkg_add` requires appending `--flavor` or selecting the explicit string. For example, `pkg_add nginx--main` installs the `main` flavor of Nginx, whereas `pkg_add nginx--no_eval` installs the evaluation-disabled flavor. The double dash (`--`) acts as a separator indicating specified flavor traits.
2. **Answer 2:** The `PKG_PATH` environment variable overrides `/etc/installurl`. For example: `export PKG_PATH="https://mirror.openbsd.br/pub/OpenBSD/7.5/packages/amd64/"`.
3. **Answer 3:** OpenBSD's `pkg_add` executes under strict `pledge(2)` system call restrictions and uses `unveil(2)` to restrict filesystem access exclusively to permitted paths (such as `/var/db/pkg`, `/usr/local`, and temporary extraction paths in `/tmp`). It cannot write to core system paths like `/sbin`, `/usr/libexec`, or `/usr/bin`.

---

### Exercise 4 Answers

1. **Answer 1:** `pkgin` is a high-level package manager (similar to `apt` or `dnf`) that performs dependency resolution, HTTP/HTTPS downloads, and repository metadata management. Low-level execution of actual binary extraction, registration, and file tracking is delegated to `pkg_add`, `pkg_delete`, and `pkg_info`. `pkgin` maintains an SQLite cache of remote package trees located at `/usr/pkg/var/db/pkgin/pkgin.db`.
2. **Answer 2:** In `pkgsrc`, global build options and configuration variables are declared in `mk.conf`. On NetBSD systems using standard `pkgsrc`, this file is located at `/usr/pkg/etc/mk.conf` (or `/etc/mk.conf`).
3. **Answer 3:** The command is `pkg_admin rebuild`. This command parses all package metadata files stored under `/var/db/pkg/` and regenerates the fast binary database index (`/var/db/pkg/pkgdb.byfile.db`).

---

### Exercise 5 Answers

1. **Answer 1:** `pkg check -B` recalculates and verifies all shared library dependencies (`ABI` dynamic linking requirements) for all installed ELF executables against libraries registered in the database. `pkg check -s` verifies filesystem file integrity by calculating SHA-256 hashes of installed files on disk and comparing them to records in `/var/db/pkg/local.sqlite`.
2. **Answer 2:** If the SQLite DB is missing or unrecoverable, an SRE can inspect `/var/db/pkg/` (if text backups exist), parse leftover binaries in `/usr/local/` using `pkg-static` or rebuild the list by scanning ELF binaries with `scanelf`/`objdump` to identify installed applications, then re-seed the package database via `pkg register` or `pkg install -fy`.
3. **Answer 3:** The `-D update` or `-F update` (or `pkg_add -r -F replace`) flag forces `pkg_add` to replace packages despite dependency conflicts or shared library version mismatches, allowing the administrator to bring binaries up to date before manually resolving broken dependencies.

</details>