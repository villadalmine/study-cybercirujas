# 102.3 — Manage Shared Libraries

> **Exam:** LPIC-1 / 102-500 · **Objective:** 102.3 · **Weight:** 1.56
> **Key knowledge:** identify shared libraries · identify typical locations of system libraries · load shared libraries
> **Exam-listed files, terms and utilities:** `ldd`, `ldconfig`, `/etc/ld.so.conf`, `LD_LIBRARY_PATH`

This is a low-weight objective that carries a disproportionate amount of production pain. Almost every "the binary works on the build box and dies in the pod" incident, every "we patched OpenSSL but the CVE scanner still flags us", and every GPU node that stops scheduling work is, underneath, a shared-library resolution problem. Treat the four exam items as the surface and the runtime loader as the actual subject.

---

## 1. Motivation and the production architectural problem

### 1.1 What dynamic linking buys, and what it costs

A program needs code it did not write: `printf`, `SSL_read`, `getaddrinfo`. There are three ways to get it into the process.

1. **Static linking** — copy the machine code into the executable at build time.
2. **Dynamic linking** — record a *dependency* in the executable and let a runtime component (`ld.so`, the *dynamic loader* / *interpreter*) map the library at `execve()` time.
3. **Runtime loading** — the program itself calls `dlopen()` on a path it decides at runtime (plugins, codecs, drivers).

Dynamic linking is the default on every mainstream Linux distribution because of four properties that matter at fleet scale:

| Property | Why it matters in production |
|---|---|
| **Single patch point** | One `libcrypto.so.3` on disk. Patch it once, and every process that maps it *after restart* is fixed. Static linking means rebuilding and redeploying every consumer. |
| **Physical memory sharing** | The read-only text segment of a shared object is backed by the page cache and mapped `MAP_PRIVATE` into every process. 400 containers using glibc share *one* set of physical pages for its `.text`. |
| **ABI decoupling** | The `SONAME` contract lets a library ship bugfixes (`1.2.3` → `1.2.4`) without touching consumers. |
| **Late binding of platform detail** | The same container image can bind to a host-specific `libcuda.so.1` injected at container-create time. Impossible with static linking. |

The cost is that **the dependency contract is resolved at runtime, on the target host, under the target's environment** — i.e. exactly where you have the least control and the worst observability. A statically linked binary that starts on your laptop starts everywhere. A dynamically linked one is a promise that has to be honoured by `ld.so` on a machine you may never log into.

### 1.2 The four incidents this objective actually prevents

**Incident A — the patch that wasn't.** A CVE lands in `libssl3`. You run the package update, the RPM/DEB replaces the file on disk, the scanner rescans the filesystem and reports clean. But every long-lived process (`nginx`, `postgres`, the JVM) still has the **deleted inode** mapped: the kernel keeps the old file alive as long as a mapping references it. The fleet is still vulnerable and every artifact says it is not. Detection is a shared-library question (`lsof +L1`, `needs-restarting -r`), not a package question.

**Incident B — the `GLIBC_2.38 not found` deploy.** CI builds on `ubuntu:24.04` (glibc 2.39), runtime image is `debian:12` (glibc 2.36). The build succeeds, the unit tests pass in the build image, and the pod `CrashLoopBackOff`s with a one-line error before a single log statement runs. The root cause is **symbol versioning**: glibc guarantees backward compatibility, never forward.

**Incident C — the vendored library that shadowed the system one.** An operator adds `LD_LIBRARY_PATH=/opt/vendor/lib` to a systemd unit to satisfy one proprietary agent. That directory also contains an ancient `libstdc++.so.6`. Every child process the unit spawns now inherits it, and unrelated tooling starts failing with `undefined symbol` errors. `LD_LIBRARY_PATH` is inherited across `fork`/`exec` — it is not a property of the binary, it is a property of the *process tree*.

**Incident D — GPU nodes stop working after a driver upgrade.** The container runtime injects host driver libraries into the container and runs `ldconfig` inside it. If the image has no `ldconfig`, no writable `/etc`, or a read-only root filesystem, `libcuda.so.1` is present on disk but not resolvable, and every CUDA pod fails with `cannot open shared object file`.

All four are the same question: **at the instant the process starts, which file on disk satisfies each `NEEDED` entry, and is that the file you think it is?**

---

## 2. Mechanics: what happens between `execve()` and `main()`

### 2.1 The kernel hands off to the interpreter

When you `execve()` an ELF file, the kernel parses the program headers. If it finds a `PT_INTERP` header, the kernel maps **that** file — the dynamic loader — and transfers control to it, not to your `_start`.

```bash
$ readelf -l /usr/bin/curl | head -20

Elf file type is DYN (Position-Independent Executable file)
Entry point 0xa0c0
There are 13 program headers, starting at offset 64

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  PHDR           0x0000000000000040 0x0000000000000040 0x0000000000000040
                 0x00000000000002d8 0x00000000000002d8  R      0x8
  INTERP         0x0000000000000318 0x0000000000000318 0x0000000000000318
                 0x000000000000001c 0x000000000000001c  R      0x1
      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  LOAD           0x0000000000000000 0x0000000000000000 0x0000000000000000
                 0x0000000000003000 0x0000000000003000  R      0x1000
```

That one line — `Requesting program interpreter` — is the whole handoff. If that path does not exist in the mount namespace, the kernel returns `ENOENT` and the shell prints the famously misleading:

```bash
$ ./app
bash: ./app: No such file or directory
$ ls -l ./app
-rwxr-xr-x 1 root root 16224 Aug 25 09:12 ./app
```

The file is right there. The *interpreter* is missing. This is the canonical "glibc binary in an Alpine/scratch image" failure.

### 2.2 The `.dynamic` section is the dependency contract

Everything the loader needs is in the `PT_DYNAMIC` segment:

```bash
$ readelf -d /usr/bin/curl

Dynamic section at offset 0x1a2c8 contains 30 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libcurl.so.4]
 0x0000000000000001 (NEEDED)             Shared library: [libz.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]
 0x000000000000000c (INIT)               0x9000
 0x000000000000000d (FINI)               0x15a54
 0x0000000000000019 (INIT_ARRAY)         0x19c88
 0x000000000000001b (INIT_ARRAYSZ)       8 (bytes)
 0x0000000000000004 (HASH)               0x3a0
 0x000000006ffffef5 (GNU_HASH)           0x3d8
 0x0000000000000005 (STRTAB)             0x1178
 0x0000000000000006 (SYMTAB)             0x458
 0x000000000000000a (STRSZ)              1163 (bytes)
 0x0000000000000015 (DEBUG)              0x0
 0x0000000000000003 (PLTGOT)             0x1a4b8
 0x0000000000000002 (PLTRELSZ)           1032 (bytes)
 0x0000000000000014 (PLTREL)             RELA
 0x0000000000000017 (JMPREL)             0x2058
 0x000000006ffffffe (VERNEED)            0x1fd8
 0x000000006fffffff (VERNEEDNUM)         3
 0x000000006ffffff0 (VERSYM)             0x1ea4
 0x000000006ffffff9 (RELACOUNT)          3
 0x0000000000000000 (NULL)               0x0
```

The tags that decide runtime behaviour:

| Tag | Meaning |
|---|---|
| `NEEDED` | A dependency, recorded **by SONAME, not by path**. This is why `libcurl.so.4` and not `/usr/lib/x86_64-linux-gnu/libcurl.so.4.8.0`. |
| `SONAME` | The name *this* object advertises itself as. Present on libraries, absent on most executables. |
| `RPATH` (legacy) | Hard-coded search path, checked **before** `LD_LIBRARY_PATH`, and **inherited** by the search for transitive dependencies. |
| `RUNPATH` (modern) | Hard-coded search path, checked **after** `LD_LIBRARY_PATH`, and applies **only to that object's direct dependencies**. |
| `VERNEED` / `VERSYM` | Symbol-version requirements — the source of `version 'GLIBC_2.38' not found`. |
| `FLAGS_1: NOW` | Bind everything eagerly at startup (see §2.6). |

### 2.3 The three-name scheme, and who creates which symlink

A correctly packaged shared library exists under three names:

```
libgreet.so.1.2.3   real file        "real name"       — the actual ELF object
libgreet.so.1       symlink          "soname"          — the runtime ABI contract
libgreet.so         symlink          "linker name"     — what `gcc -lgreet` resolves at build time
```

| Name | Created by | Consumed by | Lives in |
|---|---|---|---|
| `libgreet.so.1.2.3` | `make install` / the package | nothing directly | runtime package |
| `libgreet.so.1` | **`ldconfig`**, from the embedded `SONAME` | `ld.so` at runtime | runtime package |
| `libgreet.so` | the packager / `make install` — **never `ldconfig`** | `ld` (GNU linker) at build time | `-dev` / `-devel` package |

The most common exam-adjacent misconception is that `ldconfig` creates all the symlinks. It does not. It creates **only the SONAME link**, and it derives the name from the ELF header, not from the filename:

```bash
$ objdump -p /usr/local/lib/libgreet.so.1.2.3 | grep SONAME
  SONAME               libgreet.so.1
```

This is why `ldconfig` can be *right* while the filename is *wrong*, and why renaming a `.so` file never changes what the loader looks for.

### 2.4 The authoritative search order

For each `NEEDED` name that contains **no slash**, glibc's `ld.so` searches, in this exact order, and stops at the first hit:

| # | Source | Notes |
|---|---|---|
| 1 | `DT_RPATH` of the loading object, then of its loaders, transitively | **Ignored entirely if that object also has `DT_RUNPATH`.** |
| 2 | `LD_LIBRARY_PATH` | Colon-separated. **Ignored in secure-execution mode** (setuid/setgid/file capabilities). |
| 3 | `DT_RUNPATH` of the object that declares the dependency | Direct dependencies only — *not* inherited by transitive ones. |
| 4 | `/etc/ld.so.cache` | The `ldconfig`-built index. Skipped with `-z nodefaultlib` or `--inhibit-cache`. |
| 5 | Default trusted directories | `/lib`, `/usr/lib`, plus `/lib64`, `/usr/lib64` on 64-bit. Skipped with `-z nodefaultlib`. |

If the `NEEDED` name *does* contain a slash, it is used verbatim as a path (relative to CWD if relative) and none of the above applies.

Two expansions are performed inside `RPATH`/`RUNPATH`/`LD_LIBRARY_PATH`:

- `$ORIGIN` — the directory of the object being loaded. The correct way to build relocatable app bundles.
- `$LIB` and `$PLATFORM` — expand to `lib`/`lib64` and e.g. `x86_64`.

`$ORIGIN` is ignored in secure-execution mode for setuid binaries.

Finally, glibc ≥ 2.33 supports **`glibc-hwcaps`** subdirectories for micro-architecture dispatch: a library placed at `/usr/lib64/glibc-hwcaps/x86-64-v3/libfoo.so.1` is preferred over `/usr/lib64/libfoo.so.1` on a CPU that supports the `x86-64-v3` level. The much older "legacy hwcaps" mechanism (`tls/`, `sse2/`, …) was deprecated in 2.33 and **removed in glibc 2.37** — if you inherit a build system that installs into those directories, those libraries are now silently invisible.

### 2.5 `/etc/ld.so.cache` — the index, not the source of truth

Walking every directory at every process start would be intolerable, so `ldconfig` precomputes a binary index.

```bash
$ file /etc/ld.so.cache
/etc/ld.so.cache: Linux-x86-64 ld.so cache 1.1, 64-bit, 1213 entries

$ ldconfig -p | head -6
1213 libs found in cache `/etc/ld.so.cache'
	libzstd.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libzstd.so.1
	libz.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libz.so.1
	libxml2.so.2 (libc6,x86-64) => /lib/x86_64-linux-gnu/libxml2.so.2
	libuuid.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libuuid.so.1
	libudev.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libudev.so.1
```

Read the columns: **SONAME**, **(ABI flags, architecture)**, **resolved path**. The architecture tag is why a 32-bit and a 64-bit `libz.so.1` can coexist in one cache without ambiguity.

The cache is derived state. Its inputs are:

```bash
$ cat /etc/ld.so.conf
include /etc/ld.so.conf.d/*.conf

$ ls /etc/ld.so.conf.d/
fakeroot-x86_64-linux-gnu.conf  libc.conf  x86_64-linux-gnu.conf  zz_i386-biarch.conf

$ cat /etc/ld.so.conf.d/x86_64-linux-gnu.conf
# Multiarch support
/usr/local/lib/x86_64-linux-gnu
/lib/x86_64-linux-gnu
/usr/lib/x86_64-linux-gnu
```

**`ldconfig` always scans the trusted directories `/lib` and `/usr/lib` (and the `lib64` variants) even if they are not listed in any config file.** Everything else must be declared.

The whole operational rule reduces to: **editing `/etc/ld.so.conf.d/*.conf` changes nothing until you run `ldconfig`.** The file is input; the cache is what the loader reads.

### 2.6 Relocation, lazy binding, and hardening

Function calls into shared objects go through the **PLT** (Procedure Linkage Table), whose entries are backed by the **GOT** (Global Offset Table). By default glibc binds lazily: the first call to `SSL_read` traps into the loader, which resolves the symbol and patches the GOT.

| Mode | How | Startup cost | Failure timing | Security |
|---|---|---|---|---|
| Lazy (default) | `DT_BIND_NOW` absent | Lowest | An `undefined symbol` may appear **hours in**, on a rarely-taken code path | GOT stays writable for the process lifetime |
| Eager | `LD_BIND_NOW=1` env, or link with `-Wl,-z,now` | Highest — every symbol resolved at exec | **All** missing symbols surface at startup | Enables Full RELRO: GOT is `mprotect`ed read-only |

For production services, **link with `-Wl,-z,now -Wl,-z,relro`**. You convert a class of 3 a.m. incidents into a class of deploy-time failures, and you close the "overwrite a GOT entry" exploitation primitive. Verify:

```bash
$ readelf -d ./app | grep -E 'BIND_NOW|FLAGS'
 0x000000000000001e (FLAGS)              BIND_NOW
 0x000000006ffffffb (FLAGS_1)            Flags: NOW PIE

$ readelf -lW ./app | grep GNU_RELRO
  GNU_RELRO      0x00d000 0x000000000000d000 0x000000000000d000 0x000390 0x000390 R   0x1
```

### 2.7 Symbol versioning — why `libc.so.6` has been version 6 since 1997

glibc does not bump its SONAME for new APIs. Instead each exported symbol carries a *version node*:

```bash
$ objdump -T /lib/x86_64-linux-gnu/libc.so.6 | grep -w 'memcpy\|clock_gettime'
0000000000098670 g    DF .text	000000000000000e  GLIBC_2.14  memcpy
000000000010c9f0 g    DF .text	0000000000000068  GLIBC_2.17  clock_gettime
00000000000d5c10 g    DF .text	0000000000000010 (GLIBC_2.2.5) memcpy
```

A binary compiled against glibc 2.39 records `VERNEED` entries demanding, say, `GLIBC_2.38`. An older `libc.so.6` simply does not define that node, and the loader refuses to start the process. Backward compatibility is guaranteed (`memcpy@GLIBC_2.2.5` is still there for 20-year-old binaries); forward compatibility is not, and cannot be.

Inspect what a binary demands:

```bash
$ readelf -V ./app | sed -n '/Version needs/,/^$/p'
Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x0000000000000618  Offset: 0x000618  Link: 6 (.dynstr)
  000000: Version: 1  File: libc.so.6  Cnt: 3
  0x0010:   Name: GLIBC_2.38  Flags: none  Version: 4
  0x0020:   Name: GLIBC_2.14  Flags: none  Version: 3
  0x0030:   Name: GLIBC_2.2.5  Flags: none  Version: 2

$ objdump -p ./app | grep -A5 'required from libc'
  required from libc.so.6:
    0x09691974 0x00 04 GLIBC_2.38
    0x0d696914 0x00 03 GLIBC_2.14
    0x09691a75 0x00 02 GLIBC_2.2.5
```

The single highest version node in that list is your **minimum runtime glibc**. Extract it in CI:

```bash
$ objdump -p ./app | awk '/GLIBC_/ {print $NF}' | sort -V | tail -1
GLIBC_2.38
```

### 2.8 `dlopen()` — the third linkage model

Plugins bypass `NEEDED` entirely. `ldd` will not show them, the CI dependency gate will not see them, and the failure happens the first time a user enables the feature.

```c
void *h = dlopen("libfancycodec.so.2", RTLD_NOW | RTLD_LOCAL);
if (!h) { fprintf(stderr, "plugin load failed: %s\n", dlerror()); }
```

Operationally: `dlopen()` with no slash goes through the **same five-step search order**, so `ld.so.conf.d` + `ldconfig` fixes it. Since glibc 2.34, `libdl` is merged into `libc` — `-ldl` is a no-op stub and `libdl.so.2` exists only for compatibility. Audit plugin dependencies with `strace`, never with `ldd`:

```bash
$ strace -f -e trace=openat -o /tmp/plug.log ./app --enable-fancy
$ grep -E 'lib.*\.so' /tmp/plug.log | grep -v ENOENT
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/usr/local/lib/libfancycodec.so.2", O_RDONLY|O_CLOEXEC) = 4
```

---

## 3. Technical comparatives and trade-offs

### 3.1 Linkage model

| Dimension | Static (`-static`) | Dynamic (default) | `dlopen()` |
|---|---|---|---|
| CVE patching | Rebuild + redeploy every consumer | Replace one file, restart consumers | Replace one file, restart or reload |
| Startup latency | Fastest (no loader) | +1–15 ms typical; worse with many `NEEDED` | Deferred to first use |
| RSS across N processes | N × library size | ~1 × text segment (page-cache shared) | ~1 × text segment |
| Image size (container) | Large binary, empty base image | Small binary, base image with libs | Small, but plugins must ship |
| `getaddrinfo`/NSS | **Broken** — glibc NSS `dlopen`s modules regardless | Works | Works |
| Deploy-time failure detection | Total (build fails or works) | Partial (`NEEDED` checkable; versions checkable) | **None** without `strace`/tests |
| Licence exposure | LGPL static linking imposes relinking obligations | LGPL satisfied by dynamic linking | Same as dynamic |
| Best fit | `scratch`-image sidecars, initramfs tools, Go/Rust CLIs | Everything on a general-purpose distro | Codecs, DB drivers, GPU backends |

**Practical rule:** static glibc is a trap — `getaddrinfo`, `getpwnam` and `gethostbyname` still need `libnss_*.so` at runtime, and you get a warning at build time and a silent resolution failure in production. If you want a static binary, use musl or a language with its own resolver.

### 3.2 The five ways to point the loader at a directory

| Mechanism | Scope | Persistence | Honoured for setuid? | Precedence | Verdict |
|---|---|---|---|---|---|
| `/etc/ld.so.conf.d/*.conf` + `ldconfig` | System-wide, all processes | Permanent, survives reboot | Yes (via cache) | 4th | **Correct answer for system-installed libraries.** Owned by a package. |
| `DT_RUNPATH` (`-Wl,-rpath,'$ORIGIN/../lib'` ) | This binary, its direct deps | Baked into the ELF | `$ORIGIN` ignored | 3rd | **Correct answer for self-contained app bundles.** No env, no global state. |
| `DT_RPATH` (`-Wl,--disable-new-dtags,-rpath,…`) | This binary **and transitively** | Baked into ELF | `$ORIGIN` ignored | 1st | Legacy. Overrides `LD_LIBRARY_PATH`, so it cannot be debugged around. Avoid. |
| `LD_LIBRARY_PATH` | Process **and all descendants** | Until the shell/unit exits | **No** (stripped) | 2nd | Debugging and one-off runs only. Never in a persistent unit file. |
| Copy the library into `/usr/lib` | System-wide | Permanent | Yes | 5th | Only if a package owns the file. Hand-copied files break the next upgrade. |

The failure mode that keeps recurring: **`LD_LIBRARY_PATH` set in `/etc/environment` or a systemd drop-in.** It is inherited by every child, it silently reorders resolution for *unrelated* programs, and it stops working the moment a binary is setuid — producing "works as root, fails as the service user", which sends people down entirely the wrong diagnostic path.

### 3.3 `RPATH` vs `RUNPATH` in detail

| | `DT_RPATH` | `DT_RUNPATH` |
|---|---|---|
| Linker flag | `-Wl,--disable-new-dtags,-rpath,DIR` | `-Wl,--enable-new-dtags,-rpath,DIR` (default on modern binutils) |
| Position in search order | Before `LD_LIBRARY_PATH` | After `LD_LIBRARY_PATH` |
| Applies to transitive deps | **Yes** | **No** — each object needs its own |
| Overridable at runtime | No | Yes, with `LD_LIBRARY_PATH` |
| Status | Deprecated | Current |
| Coexistence | If both present, `RPATH` is **ignored** | — |

The `RUNPATH` "no transitive inheritance" rule is the one that surprises people: if `app` has `RUNPATH=$ORIGIN/../lib` and finds `libA.so.1` there, but `libA.so.1` needs `libB.so.1` in the same directory, **`libB` will not be found** unless `libA` itself carries a `RUNPATH`. Fix it at build time for every object in the bundle, or fall back to `ld.so.conf.d`.

### 3.4 glibc vs musl — different machinery entirely

| | glibc | musl (Alpine) |
|---|---|---|
| Loader path | `/lib64/ld-linux-x86-64.so.2` | `/lib/ld-musl-x86_64.so.1` |
| Cache | `/etc/ld.so.cache`, built by `ldconfig` | **No cache by default** |
| Search-path config | `/etc/ld.so.conf` + `ld.so.conf.d` | `/etc/ld-musl-x86_64.path` (one dir per line) |
| `ldd` | Wrapper script setting `LD_TRACE_LOADED_OBJECTS=1` | Symlink to the loader; `ldd` = `ld-musl-x86_64.so.1 --list` |
| `ldconfig` | Full implementation | Provided by `musl-utils`; limited, no real cache semantics |
| Symbol versioning | Yes (`GLIBC_2.x` nodes) | **No** — flat symbol namespace |
| `LD_LIBRARY_PATH` | Supported | Supported |
| Consequence | glibc binary in Alpine → `No such file or directory` | musl binary on glibc host → usually needs `musl` package |

`gcompat` on Alpine papers over the loader path but does not implement glibc symbol versions; treat it as a workaround, not a platform.

### 3.5 Inspection tools — and which are safe on untrusted binaries

| Tool | What it shows | Runs the loader? | Safe on untrusted files? |
|---|---|---|---|
| `ldd BIN` | Full **recursive** resolution with final paths | **Yes** — it executes the loader against the object | **No.** Historically, on a crafted binary with a hostile `RUNPATH`/interpreter, `ldd` could execute code. |
| `objdump -p BIN` | `NEEDED`, `SONAME`, `RPATH`, `RUNPATH`, version needs | No | Yes |
| `readelf -d BIN` | Same, raw `.dynamic` table | No | Yes |
| `/lib64/ld-linux-x86-64.so.2 --list BIN` | Same as `ldd` | Yes | No |
| `lddtree BIN` (`pax-utils`) | Recursive tree, statically computed | No | Yes |
| `scanelf -n BIN` (`pax-utils`) | `NEEDED` list, fast, bulk-scannable | No | Yes |
| `nm -D --defined-only LIB` | Symbols the library **exports** | No | Yes |
| `nm -D --undefined-only BIN` | Symbols the binary **needs** | No | Yes |

Rule for incident response and for any CI job touching artifacts you did not build: **`readelf -d` / `objdump -p`, never `ldd`.**

### 3.6 `ldconfig` options that matter

| Option | Effect | When you need it |
|---|---|---|
| *(none)* | Rescan all configured + trusted dirs, refresh symlinks, rewrite cache | After installing a library |
| `-p`, `--print-cache` | Dump the current cache; **reads only, needs no root** | Verification, diagnostics |
| `-v`, `--verbose` | Print each directory scanned and each link created | Proving a directory is actually being scanned |
| `-n DIR…` | Process **only** these dirs, no cache update, skip trusted dirs | Build-time symlink creation in a staging tree |
| `-N` | Do not rebuild the cache (links only) | Rare |
| `-X` | Do not update links (cache only) | Rare |
| `-r ROOT` | `chroot()` to ROOT first | Image builds, rescue environments, `debootstrap` |
| `-C CACHE` | Write an alternate cache file | Building images without touching the host |
| `-f CONF` | Use an alternate config file instead of `/etc/ld.so.conf` | Cross-root builds |
| `--ignore-aux-cache` | Ignore `/var/cache/ldconfig/aux-cache` | When `ldconfig` inexplicably misses a changed file |

---

## 4. Infrastructure and manifests (complete, unabridged)

The following set builds a properly versioned library, installs it correctly, exposes it through `ld.so.conf.d`, hardens the consuming service, and ships the whole thing to Kubernetes. Every file is complete and syntactically valid.

### 4.1 The library itself — correct `SONAME` and symbol versioning

`src/greet.h`

```c
#ifndef GREET_H
#define GREET_H

#ifdef __cplusplus
extern "C" {
#endif

/* ABI GREET_1.0 */
const char *greet_message(void);

/* ABI GREET_1.1 — added, does not break GREET_1.0 consumers */
int greet_message_r(char *buf, unsigned long buflen);

#ifdef __cplusplus
}
#endif

#endif /* GREET_H */
```

`src/greet.c`

```c
#include <stdio.h>
#include <string.h>
#include "greet.h"

static const char *MSG = "hello from libgreet";

const char *greet_message(void)
{
    return MSG;
}

int greet_message_r(char *buf, unsigned long buflen)
{
    if (buf == NULL || buflen == 0)
        return -1;
    if (strlen(MSG) + 1 > buflen)
        return -1;
    memcpy(buf, MSG, strlen(MSG) + 1);
    return 0;
}
```

`src/libgreet.map` — the version script. Everything not listed is `local`, i.e. not exported. This is the single highest-leverage thing you can do for ABI stability: it stops internal helpers from becoming an accidental public contract.

```
GREET_1.0 {
    global:
        greet_message;
    local:
        *;
};

GREET_1.1 {
    global:
        greet_message_r;
} GREET_1.0;
```

`Makefile`

```make
# Build a production-shaped shared library:
#   real name : libgreet.so.$(VERSION)
#   soname    : libgreet.so.$(ABI)
#   linkername: libgreet.so
ABI       := 1
VERSION   := 1.2.3
LIBNAME   := libgreet
REALNAME  := $(LIBNAME).so.$(VERSION)
SONAME    := $(LIBNAME).so.$(ABI)
LINKERNAME:= $(LIBNAME).so

PREFIX    ?= /usr/local
LIBDIR    ?= $(PREFIX)/lib
INCDIR    ?= $(PREFIX)/include
DESTDIR   ?=

CC        ?= gcc
CFLAGS    ?= -O2 -g -Wall -Wextra -Werror -fPIC -fvisibility=hidden
LDFLAGS   ?= -Wl,-z,relro -Wl,-z,now -Wl,--as-needed
LDFLAGS   += -Wl,-soname,$(SONAME)
LDFLAGS   += -Wl,--version-script=src/libgreet.map

OBJS      := src/greet.o

.PHONY: all clean install check-abi app

all: $(REALNAME) app

$(REALNAME): $(OBJS)
	$(CC) -shared $(CFLAGS) $(LDFLAGS) -o $@ $^
	ln -sf $(REALNAME) $(SONAME)
	ln -sf $(SONAME)   $(LINKERNAME)

# Consumer, built with an explicit RUNPATH so the bundle is relocatable.
app: src/main.c $(REALNAME)
	$(CC) $(CFLAGS) -o $@ $< -L. -lgreet \
	      -Wl,--enable-new-dtags -Wl,-rpath,'$$ORIGIN/../lib' \
	      -Wl,-z,relro -Wl,-z,now

install: all
	install -d $(DESTDIR)$(LIBDIR) $(DESTDIR)$(INCDIR)
	install -m 0644 $(REALNAME) $(DESTDIR)$(LIBDIR)/$(REALNAME)
	# ldconfig -n creates ONLY the soname link, from the ELF SONAME.
	ldconfig -n $(DESTDIR)$(LIBDIR)
	# The linker name is the packager's job, not ldconfig's.
	ln -sf $(REALNAME) $(DESTDIR)$(LIBDIR)/$(LINKERNAME)
	install -m 0644 src/greet.h $(DESTDIR)$(INCDIR)/greet.h

# Fails the build if the exported ABI changed incompatibly.
check-abi: $(REALNAME)
	abidiff --no-added-syms baseline/$(SONAME).abi $(REALNAME) || \
	  { echo "ABI BREAK: bump SONAME to $(LIBNAME).so.$$(( $(ABI) + 1 ))"; exit 1; }

clean:
	rm -f $(OBJS) $(REALNAME) $(SONAME) $(LINKERNAME) app
```

`src/main.c`

```c
#include <stdio.h>
#include "greet.h"

int main(void)
{
    char buf[64];
    printf("%s\n", greet_message());
    if (greet_message_r(buf, sizeof buf) == 0)
        printf("reentrant: %s\n", buf);
    return 0;
}
```

### 4.2 `/etc/ld.so.conf` and a package-owned fragment

`/etc/ld.so.conf` — leave it exactly like this. Do **not** append directories here; distribution upgrades replace the file.

```
include /etc/ld.so.conf.d/*.conf
```

`/etc/ld.so.conf.d/greet.conf` — this is the file your package owns.

```
# libgreet runtime libraries.
# Owned by: greet-runtime package. Do not edit by hand.
# Any change here requires `ldconfig` to take effect.
/opt/greet/lib
```

Verify it took effect — never assume:

```bash
$ sudo ldconfig
$ ldconfig -p | grep greet
	libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1
```

### 4.3 systemd unit — no `LD_LIBRARY_PATH`, resolution proven at start

`/etc/systemd/system/greet-api.service`

```ini
[Unit]
Description=Greet API
Documentation=https://example.internal/greet
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=greet
Group=greet
WorkingDirectory=/opt/greet
ExecStart=/opt/greet/bin/greet-api --listen 0.0.0.0:8080

# Fail fast and loudly on a missing symbol instead of hours later on a cold path.
Environment=LD_BIND_NOW=1

# Prove every NEEDED entry resolves BEFORE we claim the service started.
# `ld.so --list` exits non-zero when anything is unresolved.
ExecStartPre=/lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api

Restart=on-failure
RestartSec=5s

# Hardening. Note: NoNewPrivileges + a setuid binary would strip LD_LIBRARY_PATH,
# which is one more reason this unit does not use it.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/greet
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

### 4.4 Multi-stage `Dockerfile` — a distroless image whose dependencies are proven, not guessed

`Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7

##############################################################################
# Stage 1 — build. Pinned to the SAME glibc generation as the runtime stage.
##############################################################################
FROM debian:12-slim AS build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        pkg-config \
        libssl-dev \
        pax-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile ./
COPY src/ ./src/

RUN make all VERSION=1.2.3 ABI=1
RUN make install DESTDIR=/staging PREFIX=/opt/greet
RUN install -D -m 0755 app /staging/opt/greet/bin/greet-api

##############################################################################
# Stage 2 — dependency closure. Compute exactly which shared objects are
# needed, statically (no ldd on the artifact), and copy only those.
##############################################################################
FROM build AS deps

# lddtree resolves the full recursive closure without executing the binary.
RUN set -eux; \
    mkdir -p /rootfs; \
    lddtree --copy-to-tree /rootfs /staging/opt/greet/bin/greet-api; \
    cp -a /staging/opt/greet /rootfs/opt/greet; \
    # The dynamic loader itself is not a NEEDED entry; copy it explicitly.
    install -D /lib64/ld-linux-x86-64.so.2 /rootfs/lib64/ld-linux-x86-64.so.2; \
    # NSS modules are dlopen()ed and therefore invisible to any NEEDED scan.
    for m in /lib/x86_64-linux-gnu/libnss_files.so.2 \
             /lib/x86_64-linux-gnu/libnss_dns.so.2; do \
        install -D "$m" "/rootfs${m}"; \
    done; \
    install -D /staging/opt/greet/lib/libgreet.so.1.2.3 /rootfs/opt/greet/lib/libgreet.so.1.2.3; \
    ln -sf libgreet.so.1.2.3 /rootfs/opt/greet/lib/libgreet.so.1

# Bake the cache at build time: the runtime image has no ldconfig and a
# read-only root filesystem, so this is the only chance to build it.
RUN set -eux; \
    mkdir -p /rootfs/etc/ld.so.conf.d /rootfs/var/cache/ldconfig; \
    printf '%s\n' 'include /etc/ld.so.conf.d/*.conf' > /rootfs/etc/ld.so.conf; \
    printf '%s\n' '/opt/greet/lib' > /rootfs/etc/ld.so.conf.d/greet.conf; \
    printf '%s\n' '/lib/x86_64-linux-gnu' '/usr/lib/x86_64-linux-gnu' \
        > /rootfs/etc/ld.so.conf.d/x86_64-linux-gnu.conf; \
    ldconfig -r /rootfs -v | tail -20

# Hard gate: refuse to produce an image whose dependencies do not resolve
# inside the assembled rootfs.
RUN set -eux; \
    chroot /rootfs /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api \
      | tee /tmp/closure.txt; \
    ! grep -q 'not found' /tmp/closure.txt

##############################################################################
# Stage 3 — runtime. No shell, no package manager, no ldconfig.
##############################################################################
FROM gcr.io/distroless/base-debian12:nonroot AS runtime

COPY --from=deps /rootfs/ /

USER nonroot:nonroot
WORKDIR /opt/greet

ENV LD_BIND_NOW=1
EXPOSE 8080

ENTRYPOINT ["/opt/greet/bin/greet-api"]
CMD ["--listen", "0.0.0.0:8080"]
```

### 4.5 Kubernetes — vendored libraries via `initContainer`, with a read-only root filesystem

This is the pattern for the case you cannot avoid: a third-party library that must be injected at runtime and cannot be baked into the image (licensing, per-cluster driver version, air-gapped vendor blobs).

`k8s/greet-api.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: greet
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: greet-ldconfig
  namespace: greet
  labels:
    app.kubernetes.io/name: greet-api
    app.kubernetes.io/component: runtime-linkage
data:
  # Mounted into the init container, which runs ldconfig against the
  # emptyDir so the main container gets a prebuilt cache on a read-only
  # root filesystem.
  ld.so.conf: |
    include /etc/ld.so.conf.d/*.conf
  greet.conf: |
    # Vendored runtime libraries, injected by the init container.
    /opt/vendor/lib
  x86_64-linux-gnu.conf: |
    /lib/x86_64-linux-gnu
    /usr/lib/x86_64-linux-gnu
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: greet-api
  namespace: greet
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greet-api
  namespace: greet
  labels:
    app.kubernetes.io/name: greet-api
    app.kubernetes.io/version: "1.2.3"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: greet-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: greet-api
        app.kubernetes.io/version: "1.2.3"
      annotations:
        # Force a rollout when the linkage config changes; a stale ld.so.cache
        # in a running pod is invisible until the next restart.
        checksum/ldconfig: "REPLACED-BY-CI-WITH-SHA256-OF-CONFIGMAP"
    spec:
      serviceAccountName: greet-api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        # 1. Copy the vendor blobs out of their delivery image into an
        #    emptyDir shared with the app container.
        - name: vendor-libs
          image: registry.example.internal/vendor/libfancy:4.7.1
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "==> copying vendor libraries"
              cp -av /dist/lib/. /opt/vendor/lib/
              echo "==> creating SONAME symlinks from ELF headers"
              # ldconfig -n: process ONLY this directory, do not touch a cache,
              # do not scan the trusted directories.
              ldconfig -n -v /opt/vendor/lib
              ls -l /opt/vendor/lib
          volumeMounts:
            - name: vendor-lib
              mountPath: /opt/vendor/lib
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }

        # 2. Build an ld.so.cache that covers both the image's own libraries
        #    and the vendored ones, and write it to a writable emptyDir. The
        #    app container mounts that single file over /etc/ld.so.cache.
        - name: build-ldcache
          image: registry.example.internal/greet/api:1.2.3-toolchain
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "==> assembling loader configuration"
              mkdir -p /work/etc/ld.so.conf.d /work/var/cache/ldconfig
              cp /config/ld.so.conf            /work/etc/ld.so.conf
              cp /config/greet.conf            /work/etc/ld.so.conf.d/greet.conf
              cp /config/x86_64-linux-gnu.conf /work/etc/ld.so.conf.d/x86_64-linux-gnu.conf

              echo "==> ldconfig against the assembled root"
              ldconfig -f /work/etc/ld.so.conf \
                       -C /work/etc/ld.so.cache \
                       -v /opt/vendor/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu

              echo "==> cache contents relevant to this app"
              ldconfig -C /work/etc/ld.so.cache -p | grep -E 'fancy|greet|ssl|crypto' || true

              echo "==> preflight: every NEEDED entry must resolve"
              LD_LIBRARY_PATH= \
              /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api > /tmp/closure.txt
              cat /tmp/closure.txt
              if grep -q 'not found' /tmp/closure.txt; then
                echo "FATAL: unresolved shared libraries; refusing to start" >&2
                exit 1
              fi
              cp /work/etc/ld.so.cache /ldcache/ld.so.cache
              echo "==> ok"
          env:
            # The toolchain image resolves against the vendored dir explicitly
            # for the preflight; the app container uses the baked cache instead.
            - name: LD_LIBRARY_PATH
              value: /opt/vendor/lib
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
            - name: vendor-lib
              mountPath: /opt/vendor/lib
              readOnly: true
            - name: workdir
              mountPath: /work
            - name: ldcache
              mountPath: /ldcache
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }

      containers:
        - name: greet-api
          image: registry.example.internal/greet/api:1.2.3
          imagePullPolicy: IfNotPresent
          args: ["--listen", "0.0.0.0:8080"]
          env:
            # Resolve every symbol at exec time: a missing symbol becomes a
            # CrashLoopBackOff during rollout, not a 500 at 03:00.
            - name: LD_BIND_NOW
              value: "1"
            # Deliberately NOT setting LD_LIBRARY_PATH: the baked ld.so.cache
            # covers /opt/vendor/lib, and an env var would leak into every
            # child process this container ever spawns.
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          volumeMounts:
            - name: vendor-lib
              mountPath: /opt/vendor/lib
              readOnly: true
            # Single-file mount: replaces the image's cache without needing a
            # writable /etc.
            - name: ldcache
              mountPath: /etc/ld.so.cache
              subPath: ld.so.cache
              readOnly: true
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }

      volumes:
        - name: config
          configMap:
            name: greet-ldconfig
            defaultMode: 0444
        - name: vendor-lib
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
        - name: ldcache
          emptyDir:
            sizeLimit: 8Mi
        - name: workdir
          emptyDir:
            sizeLimit: 32Mi
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: greet-api
  namespace: greet
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: greet-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

Why this shape and not `LD_LIBRARY_PATH` on the container:

| Approach | Read-only rootfs | Leaks to child processes | Works for `dlopen` | Survives image rebuild |
|---|---|---|---|---|
| `env: LD_LIBRARY_PATH` | Yes | **Yes** | Yes | Yes |
| `initContainer` + baked cache + `subPath` mount | Yes | **No** | Yes | Yes |
| `ldconfig` in the entrypoint | **No** — needs writable `/etc` | No | Yes | Yes |
| Bake libraries into the image | Yes | No | Yes | Requires rebuild per vendor version |

### 4.6 Ansible — declarative library installation for VM fleets

`roles/shared-libs/tasks/main.yml`

```yaml
---
- name: Ensure the vendor library directory exists
  ansible.builtin.file:
    path: "{{ greet_vendor_libdir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Install versioned shared objects
  ansible.builtin.copy:
    src: "files/{{ item }}"
    dest: "{{ greet_vendor_libdir }}/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ greet_vendor_libs }}"
  notify: run ldconfig

- name: Declare the directory to the dynamic loader
  ansible.builtin.copy:
    dest: /etc/ld.so.conf.d/greet.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible (role: shared-libs). Do not edit.
      # A change here is inert until ldconfig runs.
      {{ greet_vendor_libdir }}
  notify: run ldconfig

- name: Flush handlers so verification runs against a fresh cache
  ansible.builtin.meta: flush_handlers

- name: Verify each SONAME resolves through the cache
  ansible.builtin.command:
    argv: ["ldconfig", "-p"]
  register: greet_ldcache
  changed_when: false

- name: Fail if a required SONAME is absent from the cache
  ansible.builtin.assert:
    that:
      - greet_ldcache.stdout is search(item)
    fail_msg: >-
      {{ item }} is not in /etc/ld.so.cache. Check that the file carries the
      expected SONAME (objdump -p) and that {{ greet_vendor_libdir }} is listed
      in /etc/ld.so.conf.d/.
    success_msg: "{{ item }} resolves through the loader cache."
  loop: "{{ greet_required_sonames }}"

- name: Verify the application binary has no unresolved dependencies
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      {{ greet_loader }} --list {{ greet_binary }} | grep -c 'not found' || true
    executable: /bin/bash
  register: greet_unresolved
  changed_when: false
  failed_when: greet_unresolved.stdout | trim | int > 0

- name: Report processes still mapping deleted library files
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      lsof +L1 2>/dev/null | awk '$0 ~ /\.so/ {print $1, $2, $NF}' | sort -u
    executable: /bin/bash
  register: greet_stale_maps
  changed_when: false
  failed_when: false

- name: Warn about processes that must be restarted to pick up patched libraries
  ansible.builtin.debug:
    msg: >-
      Processes still mapping deleted shared objects (restart required):
      {{ greet_stale_maps.stdout_lines }}
  when: greet_stale_maps.stdout_lines | length > 0
```

`roles/shared-libs/handlers/main.yml`

```yaml
---
- name: run ldconfig
  ansible.builtin.command:
    argv: ["ldconfig"]
  changed_when: true
```

`roles/shared-libs/defaults/main.yml`

```yaml
---
greet_vendor_libdir: /opt/greet/lib
greet_loader: /lib64/ld-linux-x86-64.so.2
greet_binary: /opt/greet/bin/greet-api
greet_vendor_libs:
  - libgreet.so.1.2.3
  - libfancycodec.so.2.4.0
greet_required_sonames:
  - libgreet.so.1
  - libfancycodec.so.2
```

### 4.7 CI gate — the script that turns runtime failures into build failures

`scripts/check-so-deps.sh`

```bash
#!/usr/bin/env bash
#
# Static shared-library gate. Runs against an ELF artifact WITHOUT executing
# it (no ldd), so it is safe on third-party binaries and in cross-builds.
#
#   check-so-deps.sh <binary> [max_glibc_version]
#
# Exit codes: 0 ok · 1 unresolved dependency · 2 glibc too new · 3 usage
set -euo pipefail

BIN=${1:?usage: check-so-deps.sh <binary> [max_glibc_version]}
MAX_GLIBC=${2:-2.36}

[[ -f $BIN ]] || { echo "no such file: $BIN" >&2; exit 3; }

echo "== artifact =================================================="
file "$BIN"

echo
echo "== interpreter ==============================================="
INTERP=$(readelf -lW "$BIN" | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p')
if [[ -z $INTERP ]]; then
    echo "statically linked (no PT_INTERP)"
else
    echo "$INTERP"
    [[ -e $INTERP ]] || { echo "FATAL: interpreter missing on this host" >&2; exit 1; }
fi

echo
echo "== declared dependencies (NEEDED) ============================"
mapfile -t NEEDED < <(objdump -p "$BIN" | awk '/NEEDED/ {print $2}')
printf '  %s\n' "${NEEDED[@]:-<none>}"

echo
echo "== embedded search paths ====================================="
objdump -p "$BIN" | awk '/RPATH|RUNPATH/ {print "  " $1 " = " $2}' || echo "  <none>"
if objdump -p "$BIN" | grep -q 'RPATH'; then
    echo "  WARNING: DT_RPATH is deprecated and cannot be overridden at runtime."
fi

echo
echo "== resolution ================================================"
rc=0
for so in "${NEEDED[@]:-}"; do
    [[ -n $so ]] || continue
    path=$(ldconfig -p | awk -v s="$so" '$1 == s {print $NF; exit}')
    if [[ -n $path && -e $path ]]; then
        printf '  %-28s -> %s\n' "$so" "$path"
    else
        printf '  %-28s -> NOT FOUND IN CACHE\n' "$so"
        rc=1
    fi
done

echo
echo "== minimum glibc required ===================================="
REQ=$(objdump -p "$BIN" | awk '/GLIBC_[0-9]/ {print $NF}' | tr -d '()' | sort -V | tail -1)
REQ=${REQ#GLIBC_}
if [[ -n $REQ ]]; then
    echo "  requires GLIBC_$REQ   (policy ceiling: $MAX_GLIBC)"
    if [[ $(printf '%s\n%s\n' "$REQ" "$MAX_GLIBC" | sort -V | tail -1) != "$MAX_GLIBC" ]]; then
        echo "  FATAL: artifact demands a newer glibc than the runtime image ships." >&2
        exit 2
    fi
else
    echo "  no versioned glibc symbols"
fi

echo
echo "== undefined symbols (informational) ========================="
nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print "  " $NF}' | head -20 || true

echo
if (( rc == 0 )); then echo "RESULT: ok"; else echo "RESULT: unresolved dependencies" >&2; fi
exit "$rc"
```

Run it:

```bash
$ ./scripts/check-so-deps.sh /opt/greet/bin/greet-api 2.36
== artifact ==================================================
/opt/greet/bin/greet-api: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=3f2a...c91, for GNU/Linux 3.2.0, not stripped

== interpreter ===============================================
/lib64/ld-linux-x86-64.so.2

== declared dependencies (NEEDED) ============================
  libgreet.so.1
  libssl.so.3
  libcrypto.so.3
  libc.so.6

== embedded search paths =====================================
  RUNPATH = [$ORIGIN/../lib]

== resolution ================================================
  libgreet.so.1                -> /opt/greet/lib/libgreet.so.1
  libssl.so.3                  -> /lib/x86_64-linux-gnu/libssl.so.3
  libcrypto.so.3               -> /lib/x86_64-linux-gnu/libcrypto.so.3
  libc.so.6                    -> /lib/x86_64-linux-gnu/libc.so.6

== minimum glibc required ====================================
  requires GLIBC_2.34   (policy ceiling: 2.36)

== undefined symbols (informational) =========================
  SSL_read
  SSL_write
  greet_message
  __libc_start_main
  printf

RESULT: ok
```

---

## 5. CLI reference session — verification and diagnosis

### 5.1 Identify a shared library and its identity

```bash
$ file /usr/lib/x86_64-linux-gnu/libssl.so.3
/usr/lib/x86_64-linux-gnu/libssl.so.3: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked, BuildID[sha1]=8c2e1d94a1f0b7c3e5d2a9f0c1b8e7d6a5f4c3b2, stripped

$ objdump -p /usr/lib/x86_64-linux-gnu/libssl.so.3 | grep -E 'SONAME|NEEDED'
  NEEDED               libcrypto.so.3
  NEEDED               libc.so.6
  SONAME               libssl.so.3

$ ls -l /usr/lib/x86_64-linux-gnu/libssl.so*
lrwxrwxrwx 1 root root      15 Jun  4 11:02 /usr/lib/x86_64-linux-gnu/libssl.so -> libssl.so.3
-rw-r--r-- 1 root root  668992 Jun  4 11:02 /usr/lib/x86_64-linux-gnu/libssl.so.3
```

Which package owns it — always confirm before touching a system library:

```bash
# Debian/Ubuntu
$ dpkg -S /usr/lib/x86_64-linux-gnu/libssl.so.3
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3

# RHEL/Fedora/SUSE
$ rpm -qf /usr/lib64/libssl.so.3
openssl-libs-3.2.2-6.el9.x86_64
```

### 5.2 `ldd` — full recursive resolution

```bash
$ ldd /usr/bin/curl
	linux-vdso.so.1 (0x00007ffd4f5f8000)
	libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4 (0x00007f2a3c1e0000)
	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f2a3c1c4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2a3bc00000)
	libnghttp2.so.14 => /lib/x86_64-linux-gnu/libnghttp2.so.14 (0x00007f2a3c197000)
	libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3 (0x00007f2a3c0f3000)
	libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3 (0x00007f2a3b800000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2a3c227000)
```

Three line shapes, three meanings:

| Line | Meaning |
|---|---|
| `linux-vdso.so.1 (0x…)` | The **vDSO** — a kernel-provided virtual object, not a file. It has no path and never will. Not a problem. |
| `libc.so.6 => /lib/… (0x…)` | Resolved. The path is the file the loader will map. |
| `/lib64/ld-linux-x86-64.so.2 (0x…)` | The interpreter itself, listed without `=>`. |
| `libfoo.so.1 => not found` | **The failure you are hunting.** |

Non-dynamic inputs:

```bash
$ ldd /bin/sh
	linux-vdso.so.1 (0x00007ffc2f7f4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8b2ec00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f8b2ee3f000)

$ ldd /usr/bin/busybox-static
	not a dynamic executable

$ ldd ./go-binary
	statically linked

$ ldd /etc/passwd
	not a dynamic executable
```

The safe, non-executing equivalent — note the *identical* output shape:

```bash
$ /lib64/ld-linux-x86-64.so.2 --list /usr/bin/curl | head -4
	linux-vdso.so.1 (0x00007ffd94dfd000)
	libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4 (0x00007f11c81e0000)
	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f11c81c4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f11c7c00000)
```

This still runs the loader. The genuinely static option:

```bash
$ lddtree /usr/bin/curl
curl => /usr/bin/curl (interpreter => /lib64/ld-linux-x86-64.so.2)
    libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4
        libnghttp2.so.14 => /lib/x86_64-linux-gnu/libnghttp2.so.14
        libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3
        libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3
    libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1
    libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
```

### 5.3 `ldconfig` — inspect, rebuild, prove

```bash
# Read the cache. No root needed.
$ ldconfig -p | wc -l
1214

$ ldconfig -p | grep -w libssl.so.3
	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3

# Install a new library and watch the cache stay stale.
$ sudo install -m 0644 libgreet.so.1.2.3 /opt/greet/lib/
$ ldconfig -p | grep greet
$ echo $?
1

# Declare the directory...
$ echo /opt/greet/lib | sudo tee /etc/ld.so.conf.d/greet.conf
/opt/greet/lib

# ...still stale. The config file is not consulted at process start.
$ ldconfig -p | grep greet
$ echo $?
1

# Rebuild. This is the step people forget.
$ sudo ldconfig

$ ldconfig -p | grep greet
	libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1

# ldconfig created the SONAME symlink from the ELF header:
$ ls -l /opt/greet/lib/
total 24
lrwxrwxrwx 1 root root    17 Aug 25 09:41 libgreet.so.1 -> libgreet.so.1.2.3
-rw-r--r-- 1 root root 16408 Aug 25 09:40 libgreet.so.1.2.3
```

Verbose mode is how you prove a directory is being scanned at all:

```bash
$ sudo ldconfig -v 2>/dev/null | grep -A3 '^/opt/greet/lib'
/opt/greet/lib:
	libgreet.so.1 -> libgreet.so.1.2.3 (changed)

$ sudo ldconfig -v 2>/dev/null | grep '^/' | head
/usr/local/lib:
/lib/x86_64-linux-gnu:
/usr/lib/x86_64-linux-gnu:
/opt/greet/lib:
/lib32:
/usr/lib32:
/lib:
/usr/lib:
```

If a directory you configured does not appear in that list, the `.conf` file is not being read — check the filename ends in `.conf` and that `/etc/ld.so.conf` still has its `include` line.

Non-invasive mode for build trees (no cache write, no trusted-dir scan):

```bash
$ ldconfig -n -v /staging/usr/local/lib
/staging/usr/local/lib:
	libgreet.so.1 -> libgreet.so.1.2.3
```

Chroot mode for image builds:

```bash
$ sudo ldconfig -r /rootfs -v | tail -5
/rootfs/usr/lib/x86_64-linux-gnu:
	libcrypto.so.3 -> libcrypto.so.3
	libssl.so.3 -> libssl.so.3
/rootfs/opt/greet/lib:
	libgreet.so.1 -> libgreet.so.1.2.3
```

### 5.4 `LD_LIBRARY_PATH` — the debugging tool, not the deployment mechanism

```bash
$ ./app
./app: error while loading shared libraries: libgreet.so.1: cannot open shared object file: No such file or directory

# Prove the hypothesis in one command, without touching system state:
$ LD_LIBRARY_PATH=/opt/greet/lib ./app
hello from libgreet
reentrant: hello from libgreet
```

Confirmed. Now make it permanent the right way (`ld.so.conf.d` + `ldconfig`), and demonstrate why the env var is not that mechanism:

```bash
# It leaks to every descendant:
$ export LD_LIBRARY_PATH=/opt/greet/lib
$ bash -c 'echo "child sees: $LD_LIBRARY_PATH"'
child sees: /opt/greet/lib

# It is stripped for setuid binaries (secure-execution mode):
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar 23 12:04 /usr/bin/passwd

$ LD_LIBRARY_PATH=/tmp/evil LD_DEBUG=libs /usr/bin/passwd --help 2>&1 | grep -c '/tmp/evil'
0

# An empty element means "current directory" — a classic privilege-escalation vector:
$ echo "$LD_LIBRARY_PATH"
/opt/greet/lib:
#                ^ trailing colon == "." — never do this
$ unset LD_LIBRARY_PATH
```

### 5.5 `LD_DEBUG` — the loader's own trace

This is the highest-value diagnostic in the whole objective and it is not in any exam objective list. It prints exactly which paths the loader tried and in what order.

```bash
$ LD_DEBUG=help ./app
Valid options for the LD_DEBUG environment variable are:

  libs        display library search paths
  reloc       display relocation processing
  files       display progress for input file
  symbols     display symbol table processing
  bindings    display information about symbol binding
  versions    display version dependencies
  scopes      display scope information
  all         all previous options combined
  statistics  display relocation statistics
  unused      determine unused DSOs
  help        display this help message and exit

To direct the debugging output into a file instead of standard output
a filename can be specified using the LD_DEBUG_OUTPUT environment variable.
```

Trace resolution of a failing binary:

```bash
$ LD_DEBUG=libs ./app 2>&1 | head -30
    294817:	find library=libgreet.so.1 [0]; searching
    294817:	 search path=/opt/greet/bin/../lib		(RUNPATH from file ./app)
    294817:	  trying file=/opt/greet/bin/../lib/libgreet.so.1
    294817:	 search cache=/etc/ld.so.cache
    294817:	 search path=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib		(system search path)
    294817:	  trying file=/lib/x86_64-linux-gnu/libgreet.so.1
    294817:	  trying file=/usr/lib/x86_64-linux-gnu/libgreet.so.1
    294817:	  trying file=/lib/libgreet.so.1
    294817:	  trying file=/usr/lib/libgreet.so.1
    294817:
    294817:	find library=libc.so.6 [0]; searching
    294817:	 search path=/opt/greet/bin/../lib		(RUNPATH from file ./app)
    294817:	  trying file=/opt/greet/bin/../lib/libc.so.6
    294817:	 search cache=/etc/ld.so.cache
    294817:	  trying file=/lib/x86_64-linux-gnu/libc.so.6
    294817:
./app: error while loading shared libraries: libgreet.so.1: cannot open shared object file: No such file or directory
```

Read that trace like a checklist: `RUNPATH` tried and missed → cache consulted and missed → four default directories tried and missed. That is a complete, unambiguous answer to "where did it look".

Find libraries you link against but never call — real image-size and attack-surface reduction:

```bash
$ LD_DEBUG=unused ./app 2>&1 | grep unused
    294903:	/lib/x86_64-linux-gnu/libm.so.6: unused direct dependency
```

Fix by rebuilding with `-Wl,--as-needed` (already in the `Makefile` above).

Startup cost measurement:

```bash
$ LD_DEBUG=statistics ./app 2>&1 | grep -E 'total startup|relocation'
    294941:	  total startup time in dynamic loader: 1421953 cycles
    294941:		    time needed for relocation: 892401 cycles (62.7%)
    294941:		   number of relocations: 1874
    294941:		number of relative relocations: 3921
    294941:	       time needed to load objects: 421077 cycles (29.6%)
```

### 5.6 `strace` — the ground truth

When `LD_DEBUG` is unavailable (secure-execution mode strips it), `strace` still shows every probe:

```bash
$ strace -e trace=openat,stat ./app 2>&1 | grep -E 'greet|ld.so'
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/opt/greet/bin/../lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/usr/lib/x86_64-linux-gnu/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/usr/lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
```

### 5.7 What a live process actually mapped

`ldd` tells you what *would* be loaded. `/proc/<pid>/maps` tells you what *was*.

```bash
$ pgrep -x nginx
2181
2182

$ awk '/\.so/ {print $6}' /proc/2181/maps | sort -u
/usr/lib/x86_64-linux-gnu/libcrypt.so.1
/usr/lib/x86_64-linux-gnu/libc.so.6
/usr/lib/x86_64-linux-gnu/libcrypto.so.3
/usr/lib/x86_64-linux-gnu/libpcre2-8.so.0
/usr/lib/x86_64-linux-gnu/libssl.so.3
/usr/lib/x86_64-linux-gnu/libz.so.1
/usr/lib64/ld-linux-x86-64.so.2
```

The **deleted-mapping** check — this is Incident A from §1.2:

```bash
$ sudo apt-get install -y --only-upgrade libssl3
...
Setting up libssl3:amd64 (3.0.15-1~deb12u1) ...

$ grep -c 'deleted' /proc/2181/maps
2

$ grep 'deleted' /proc/2181/maps
7f3c2a400000-7f3c2a460000 r--p 00000000 fd:01 1180337  /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (deleted)
7f3c2a460000-7f3c2a9c8000 r-xp 00060000 fd:01 1180337  /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (deleted)

# Fleet-wide, in one command:
$ sudo lsof +L1 2>/dev/null | awk '/\.so/ {print $1, $2, $NF}' | sort -u
nginx     2181 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
nginx     2182 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
postgres  1044 /usr/lib/x86_64-linux-gnu/libcrypto.so.3

# Distribution helpers:
$ sudo needs-restarting -r ; echo "exit=$?"          # RHEL family (dnf-utils)
Core libraries or services have been updated since boot-up:
  * openssl-libs
Reboot is required to ensure that your system benefits from these updates.
exit=1

$ sudo checkrestart                                   # Debian (debian-goodies)
Found 3 processes using old versions of upgraded files
(1 distinct program)
(1 distinct packages)

These are the packages:
nginx
```

**The patch is not applied until the process restarts.** Any compliance report that stops at the package version is wrong.

### 5.8 Repairing an ELF's linkage without rebuilding

`patchelf` is the escape hatch for vendor binaries you cannot recompile:

```bash
$ patchelf --print-rpath ./vendor-agent
/build/tmp/lib

$ patchelf --print-needed ./vendor-agent
libfancy.so.2
libc.so.6

$ patchelf --print-interpreter ./vendor-agent
/lib64/ld-linux-x86-64.so.2

# Repoint at a relocatable location.
$ cp ./vendor-agent ./vendor-agent.bak
$ patchelf --set-rpath '$ORIGIN/../lib' ./vendor-agent

$ patchelf --print-rpath ./vendor-agent
$ORIGIN/../lib

$ readelf -d ./vendor-agent | grep -E 'RPATH|RUNPATH'
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]

$ ./vendor-agent --version
vendor-agent 4.7.1
```

Keep the backup. `patchelf` rewrites program headers and, on unusual layouts, can produce a binary that no longer loads. Verify with `--list` before shipping.

---

## 6. Failure diagnosis guide

### 6.1 Symptom → cause → command → fix

| Symptom | Root cause | Diagnostic | Fix |
|---|---|---|---|
| `error while loading shared libraries: libX.so.N: cannot open shared object file` | The SONAME resolves nowhere in the five-step search | `LD_DEBUG=libs ./app` | Install the library; add its dir to `ld.so.conf.d` and run `ldconfig` |
| `bash: ./app: No such file or directory` on an existing, executable file | `PT_INTERP` missing in this mount namespace (glibc binary in Alpine/`scratch`) | `readelf -l ./app \| grep interpreter` | Match the libc of build and runtime images; or ship the loader |
| `libX.so.6: version 'GLIBC_2.38' not found` | Built against a newer glibc than the runtime provides | `objdump -p ./app \| grep GLIBC_ \| sort -V \| tail -1` | Build in the runtime image's distro; pin CI base image to runtime base image |
| `symbol lookup error: ./app: undefined symbol: foo` | Library upgraded/downgraded in place without a SONAME bump, or wrong library shadowing the right one | `nm -D --defined-only /path/libX.so.N \| grep foo` | Restore the matching version; remove the shadowing path; use `LD_BIND_NOW=1` to surface this at start |
| `wrong ELF class: ELFCLASS32` | 32-bit library found first for a 64-bit process | `file libX.so.N`; `ldconfig -p \| grep libX` | Fix directory ordering; install the correct multiarch package |
| Works as your user, fails as the service user | `LD_LIBRARY_PATH` in your shell profile; or setuid strips it | `sudo -u svc env \| grep LD_` | Move to `ld.so.conf.d` + `ldconfig` |
| Works interactively, fails from cron/systemd | Same — the env var is absent in a non-login environment | `systemctl show -p Environment greet-api` | Same |
| `ldconfig -p` shows the library but the app still cannot find it | Wrong architecture entry, or the app has `DT_RPATH` overriding everything, or `-z nodefaultlib` | `ldconfig -p \| grep libX` (check the arch tag); `objdump -p ./app \| grep RPATH` | Patch out `RPATH`; install the correct arch |
| `cannot restore segment prot after reloc: Permission denied` | Text relocations in a non-PIC library under SELinux | `readelf -d libX.so \| grep TEXTREL`; `ausearch -m avc -ts recent` | Rebuild with `-fPIC` (correct); or `chcon -t textrel_shlib_t libX.so` (workaround) |
| `failed to map segment from shared object` | `noexec` mount option on the directory holding the library | `findmnt -T /opt/greet/lib -o TARGET,OPTIONS` | Remount without `noexec`, or relocate the library |
| CVE scanner still flags a patched host | Processes still map the deleted inode | `lsof +L1 \| grep '\.so'` | Restart the mapping processes |
| A library appears/disappears depending on CPU model | `glibc-hwcaps` subdirectory dispatch (glibc ≥ 2.33) | `ld.so --help \| grep -A10 'Subdirectories'` | Install into the base dir, or into every relevant `glibc-hwcaps/` level |
| Library installed into `tls/`, `sse2/`, `x86_64/` is ignored on a new distro | Legacy hwcaps **removed in glibc 2.37** | `ldd --version`; `ldconfig -p \| grep libX` | Move the file to the plain library directory |

### 6.2 Case study — `cannot open shared object file`, worked end to end

```bash
$ /opt/greet/bin/greet-api --listen :8080
/opt/greet/bin/greet-api: error while loading shared libraries: libfancycodec.so.2: cannot open shared object file: No such file or directory
```

**Step 1 — what does the binary actually demand?** Do not execute it again.

```bash
$ objdump -p /opt/greet/bin/greet-api | grep -E 'NEEDED|RPATH|RUNPATH'
  NEEDED               libgreet.so.1
  NEEDED               libfancycodec.so.2
  NEEDED               libc.so.6
  RUNPATH              $ORIGIN/../lib
```

**Step 2 — is the cache aware of it?**

```bash
$ ldconfig -p | grep -i fancy
$ echo $?
1
```

No. Either the file is absent, or its directory is not configured, or its `SONAME` is not what the binary wants.

**Step 3 — does the file exist anywhere?**

```bash
$ sudo find / -xdev -name 'libfancycodec.so*' -printf '%p\t%l\n' 2>/dev/null
/opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2.4.0	
```

It exists. The `SONAME` symlink does not.

**Step 4 — what does the file advertise itself as?**

```bash
$ objdump -p /opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2.4.0 | grep SONAME
  SONAME               libfancycodec.so.2
```

Match. So the only missing pieces are the symlink and the configuration.

**Step 5 — confirm the hypothesis without changing system state.**

```bash
$ ln -s libfancycodec.so.2.4.0 /tmp/probe/libfancycodec.so.2
$ LD_LIBRARY_PATH=/tmp/probe:/opt/vendor/fancy-4.7.1/lib \
    /opt/greet/bin/greet-api --version
greet-api 1.2.3 (libfancycodec 4.7.1)
```

Confirmed.

**Step 6 — apply the durable fix.**

```bash
$ printf '%s\n' '# libfancycodec runtime, owned by greet-runtime' \
                '/opt/vendor/fancy-4.7.1/lib' \
    | sudo tee /etc/ld.so.conf.d/fancycodec.conf
# libfancycodec runtime, owned by greet-runtime
/opt/vendor/fancy-4.7.1/lib

$ sudo ldconfig

$ ls -l /opt/vendor/fancy-4.7.1/lib/
total 1892
lrwxrwxrwx 1 root root      23 Aug 25 10:12 libfancycodec.so.2 -> libfancycodec.so.2.4.0
-rw-r--r-- 1 root root 1936784 Jul 30 08:41 libfancycodec.so.2.4.0
```

`ldconfig` created the symlink from the ELF `SONAME`. No manual `ln` needed.

**Step 7 — verify, then restart the service.**

```bash
$ ldconfig -p | grep -i fancy
	libfancycodec.so.2 (libc6,x86-64) => /opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2

$ /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api | grep -c 'not found'
0

$ sudo systemctl restart greet-api
$ systemctl is-active greet-api
active
```

### 6.3 Case study — the shadowed library

Symptom: the service starts, then dies on the first TLS handshake with `undefined symbol: SSL_CTX_set_ciphersuites`.

```bash
$ LD_DEBUG=libs /opt/greet/bin/greet-api 2>&1 | grep -A2 'find library=libssl'
    301244:	find library=libssl.so.3 [0]; searching
    301244:	 search path=/opt/legacy/lib		(LD_LIBRARY_PATH)
    301244:	  trying file=/opt/legacy/lib/libssl.so.3
```

`LD_LIBRARY_PATH` won over the cache. Which file did it get?

```bash
$ ldconfig -p | grep -w libssl.so.3
	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3

$ nm -D --defined-only /opt/legacy/lib/libssl.so.3 | grep -c SSL_CTX_set_ciphersuites
0
$ nm -D --defined-only /lib/x86_64-linux-gnu/libssl.so.3 | grep -c SSL_CTX_set_ciphersuites
1
```

Confirmed: `/opt/legacy/lib` holds an older OpenSSL 3 build with the same SONAME. Find who set the variable:

```bash
$ systemctl show -p Environment greet-api
Environment=LD_LIBRARY_PATH=/opt/legacy/lib LD_BIND_NOW=1

$ sudo tr '\0' '\n' < /proc/$(pgrep -x greet-api)/environ | grep '^LD_'
LD_LIBRARY_PATH=/opt/legacy/lib
LD_BIND_NOW=1
```

Fix: remove the `Environment=LD_LIBRARY_PATH=` line from the unit and give the *one* binary that needs the legacy build its own `RUNPATH` via `patchelf`, so the override is scoped to that ELF instead of the whole process tree.

```bash
$ sudo systemctl edit --full greet-api      # delete the LD_LIBRARY_PATH assignment
$ sudo systemctl daemon-reload
$ sudo systemctl restart greet-api
$ sudo tr '\0' '\n' < /proc/$(pgrep -x greet-api)/environ | grep -c LD_LIBRARY_PATH
0
```

### 6.4 Security checks that belong in your baseline

```bash
# /etc/ld.so.preload is loaded into EVERY process. It is not an environment
# variable, so it survives env scrubbing — the classic userland-rootkit hook.
$ ls -l /etc/ld.so.preload 2>/dev/null || echo "absent (expected on a clean host)"
absent (expected on a clean host)

# World-writable directories in the loader's search path = arbitrary code
# execution as every user who runs a dynamically linked program.
$ ldconfig -v 2>/dev/null | sed -n 's/^\(\/[^:]*\):$/\1/p' \
    | xargs -r stat -c '%A %U %n' 2>/dev/null | grep -E '^d.......w'

# World-writable shared objects.
$ find /lib /usr/lib /usr/local/lib /opt -xdev -name '*.so*' -perm -o+w -ls 2>/dev/null

# Libraries not owned by any package.
$ for f in $(find /usr/lib/x86_64-linux-gnu -maxdepth 1 -name '*.so.*' -type f); do
>   dpkg -S "$f" >/dev/null 2>&1 || echo "UNOWNED: $f"
> done
UNOWNED: /usr/lib/x86_64-linux-gnu/libfancycodec.so.2.4.0

# Text relocations (indicate non-PIC code; blocked under SELinux, and a sign
# of a library built without -fPIC).
$ for f in /usr/local/lib/*.so*; do
>   readelf -d "$f" 2>/dev/null | grep -q TEXTREL && echo "TEXTREL: $f"
> done
```

---

## 7. Exam radar — what 102.3 actually tests

- **`/etc/ld.so.conf` contains `include /etc/ld.so.conf.d/*.conf`.** Add directories as fragments there, not by editing the main file.
- **Editing config does nothing until `ldconfig` runs.** This is the single most-tested causal chain in the objective.
- **`ldconfig -p` prints the cache; plain `ldconfig` rebuilds it** (and needs root).
- **`ldconfig` creates the SONAME symlink, from the ELF header — not the `.so` development symlink, and not from the filename.**
- **`ldd` shows resolved dependencies recursively**; `=> not found` is the failure marker; `linux-vdso.so.1` having no path is normal.
- **`LD_LIBRARY_PATH` is a colon-separated env var, searched before the cache and after `RPATH`**, inherited by children, ignored for setuid binaries.
- **Typical locations:** `/lib`, `/lib64`, `/usr/lib`, `/usr/lib64`, `/usr/local/lib`, and on Debian-family multiarch `/lib/x86_64-linux-gnu`, `/usr/lib/x86_64-linux-gnu`.
- **Naming:** `libNAME.so.MAJOR.MINOR.PATCH` (real) → `libNAME.so.MAJOR` (soname) → `libNAME.so` (linker name).
- **The cache file is `/etc/ld.so.cache`** — binary, never edited by hand, always regenerated.

Distractors to reject on sight: "run `ldd` to rebuild the cache" (no — `ldconfig`), "edit `/etc/ld.so.cache` with a text editor" (no — it is binary), "`ldconfig` creates `libfoo.so`" (no — only `libfoo.so.N`), "`LD_LIBRARY_PATH` is read from `/etc/ld.so.conf`" (no — unrelated mechanisms).

---

## 8. Practice

### 8.1 Exercises

1. Given only `readelf`/`objdump`, list every direct dependency of `/usr/sbin/sshd` and its embedded search paths, without executing the binary. What is its minimum glibc version?
2. A colleague installed `libmagic.so.1.0.0` into `/opt/tools/lib` and reports "`ldconfig` did not create the symlink". Give the two commands that determine whether the problem is the `SONAME` or the configuration.
3. Explain, in the loader's own terms, why a binary with `DT_RPATH=/opt/old/lib` cannot be redirected with `LD_LIBRARY_PATH`, and give the command that fixes it in place.
4. Your image scanner reports `libcrypto3` as patched, but the security team insists the host is vulnerable. Both are right. Produce the command that proves it and the remediation.
5. A pod with `readOnlyRootFilesystem: true` needs a vendor library injected at runtime. Explain why `ldconfig` in the entrypoint fails and give two working alternatives with their trade-offs.
6. `libfoo.so.2` is present in `/usr/local/lib`, `ldconfig -p` lists it, but a 64-bit binary still reports it as not found. Name three distinct causes and the command that distinguishes each.

### 8.2 Lab — build, break, and fix a shared-library deployment

**Setup.** Using the `Makefile` and sources in §4.1:

```bash
$ make all VERSION=1.2.3 ABI=1
$ sudo make install PREFIX=/opt/greet
$ ls -l /opt/greet/lib/
```

**Task 1 — observe the failure.** Run `/opt/greet/bin/app` (copy `./app` there first) from a directory where `$ORIGIN/../lib` does not resolve. Capture the full `LD_DEBUG=libs` trace and annotate each of the five search steps.

**Task 2 — fix it three ways, and rank them.** Make the binary work using (a) `LD_LIBRARY_PATH`, (b) `/etc/ld.so.conf.d/` + `ldconfig`, (c) `patchelf --set-rpath`. For each, record: does it survive a reboot, does it affect other processes, does it survive `chmod u+s` on the binary?

**Task 3 — break the ABI.** Edit `src/libgreet.map` to remove `greet_message` from `GREET_1.0`, rebuild, reinstall **without** bumping the SONAME, and run the existing `app` binary. Capture the exact error. Then set `LD_BIND_NOW=1` and observe how the failure timing changes.

**Task 4 — simulate the patch-and-forget incident.** Start `app` in a loop in the background. Reinstall `libgreet.so.1.2.3` with different content. Prove with `/proc/<pid>/maps` and `lsof +L1` that the running process still maps the old inode. Restart it and prove the mapping changed.

**Task 5 — containerise it.** Build the `Dockerfile` from §4.4. Then deliberately break it: change the build stage to `ubuntu:24.04` while leaving the runtime stage on `debian:12`. Capture the failure, then show which of the three CI gates in `check-so-deps.sh` catches it and why the other two do not.

**Task 6 — the multiarch trap.** Install a 32-bit `libz1:i386` on a 64-bit host. Show with `ldconfig -p` how the cache distinguishes the two entries, and construct a case where a 64-bit binary fails with `wrong ELF class`.

---

## 9. Referencias

**LPI — objetivos oficiales del examen**
- LPIC-1 Exam 101 objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives (v5.0), objective 102.3: https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Documentación de referencia de glibc y del cargador dinámico**
- `ld.so(8)` — dynamic linker/loader, search order, environment variables, secure-execution mode: https://man7.org/linux/man-pages/man8/ld.so.8.html
- `ldconfig(8)` — cache and symlink management, all options: https://man7.org/linux/man-pages/man8/ldconfig.8.html
- `ldd(1)` — including the security caveat about executing the object: https://man7.org/linux/man-pages/man1/ldd.1.html
- `dlopen(3)` — runtime loading, `RTLD_*` flags: https://man7.org/linux/man-pages/man3/dlopen.3.html
- `elf(5)` — ELF structures, `PT_INTERP`, dynamic tags: https://man7.org/linux/man-pages/man5/elf.5.html
- The GNU C Library manual — Dynamic Linker: https://www.gnu.org/software/libc/manual/html_node/Dynamic-Linker.html
- glibc `glibc-hwcaps` subdirectories and the removal of legacy hwcaps: https://sourceware.org/glibc/wiki/Release/2.33 and https://sourceware.org/glibc/wiki/Release/2.37
- glibc ABI and symbol versioning policy: https://sourceware.org/glibc/wiki/Development

**Binutils y herramientas de inspección**
- GNU `ld` documentation — `-rpath`, `-rpath-link`, `--enable-new-dtags`, `LD_RUN_PATH`: https://sourceware.org/binutils/docs/ld/Options.html
- `readelf(1)`: https://sourceware.org/binutils/docs/binutils/readelf.html
- `objdump(1)`: https://sourceware.org/binutils/docs/binutils/objdump.html
- `nm(1)`: https://sourceware.org/binutils/docs/binutils/nm.html
- `patchelf` — modify ELF interpreter, RPATH and NEEDED entries: https://github.com/NixOS/patchelf
- `pax-utils` (`lddtree`, `scanelf`): https://wiki.gentoo.org/wiki/Hardened/PaX_Utilities
- `libabigail` / `abidiff` — ABI change detection: https://sourceware.org/libabigail/manual/abidiff.html

**Estándares y guías de empaquetado**
- Filesystem Hierarchy Standard 3.0 — `/lib`, `/usr/lib`, `/usr/local/lib`: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Debian Multiarch specification (`/usr/lib/<triplet>`): https://wiki.debian.org/Multiarch/Implementation
- Debian Policy — shared libraries, SONAME and `ldconfig` in maintainer scripts: https://www.debian.org/doc/debian-policy/ch-sharedlibs.html
- Fedora Packaging Guidelines — shared libraries: https://docs.fedoraproject.org/en-US/packaging-guidelines/
- Ulrich Drepper, *How To Write Shared Libraries*: https://www.akkadia.org/drepper/dsohowto.pdf
- ELF specification (System V ABI, gABI): https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html

**musl y contenedores**
- musl libc — dynamic linking and `/etc/ld-musl-$ARCH.path`: https://wiki.musl-libc.org/functional-differences-from-glibc.html
- Alpine Linux — running glibc software: https://wiki.alpinelinux.org/wiki/Running_glibc_programs
- Kubernetes — Pod security context and `readOnlyRootFilesystem`: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — init containers: https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- NVIDIA Container Toolkit — driver library injection into containers: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html

**systemd**
- `systemd.exec(5)` — `Environment=`, `ExecStartPre=`, `NoNewPrivileges=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html