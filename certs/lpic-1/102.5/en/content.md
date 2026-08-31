# 102.5 — Use RPM and YUM Package Management

**LPIC-1 · Exam 102-500 · Objective 102.5 · Weight 4.69**

**Key Knowledge Areas:** install, re-install, upgrade and remove packages using `rpm`, `yum`/`dnf` and `zypper`; obtain package information (version, status, dependencies, integrity, signatures); determine what files a package provides and which package owns a given file.

**Terms and Utilities:** `rpm`, `rpm2cpio`, `/etc/yum.conf`, `/etc/yum.repos.d/`, `yum`, `zypper`

---

## 1. The production problem: package state is fleet state

A Linux system is not "a kernel plus some files". It is a **transactional database of installed artifacts**, and every operational property you care about in production is derived from that database:

| Production question | Answered from | Failure if the DB lies |
|---|---|---|
| Is CVE-2024-XXXX patched on all 4,000 nodes? | `rpmdb` version of the affected NEVRA | Compliance report says "patched", exploit says otherwise |
| Why did `/etc/nginx/nginx.conf` change at 03:14? | package transaction history + `rpm -V` | Root cause hunt takes hours instead of one command |
| Can I roll back last night's upgrade? | `dnf history` / `zypper` transaction log | You rebuild the host from scratch |
| Is this binary vendor-supplied or hand-copied? | `rpm -qf` + signature verification | Unattributed binary = unauditable supply chain |
| Will this container image build reproducibly? | pinned repo metadata + NEVRA | Image drifts silently between builds |

The architectural failure mode that RPM/DNF exists to prevent is **configuration drift with no provenance**. A host where somebody ran `make install`, copied a binary over `/usr/local/bin`, or edited a config in place is a host you cannot reason about, cannot patch confidently, and cannot reproduce. Every file that is *not* owned by a package is a file with no version, no checksum, no signature and no owner.

The three-layer model you must internalise:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3 — DEPOT / GOVERNANCE                                    │
│   Pulp · Katello/Satellite · Artifactory · Nexus · plain mirror │
│   content views, lifecycle envs, signing, retention             │
└───────────────────────────┬─────────────────────────────────────┘
                            │ HTTP(S) + repomd.xml + detached GPG
┌───────────────────────────▼─────────────────────────────────────┐
│ Layer 2 — DEPENDENCY RESOLVER (dnf / yum / zypper)              │
│   repo discovery, metadata cache, SAT solving, ordering,        │
│   download, GPG key trust, history/undo                         │
│   libsolv + librepo + hawkey   |   libzypp + libsolv            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ ordered list of .rpm files
┌───────────────────────────▼─────────────────────────────────────┐
│ Layer 1 — TRANSACTION ENGINE (librpm / rpm)                     │
│   header parse, signature verify, dep check, file conflict      │
│   check, tsort, %pre → unpack → %post → rpmdb commit            │
│   /var/lib/rpm (sqlite | ndb | bdb_ro)                          │
└─────────────────────────────────────────────────────────────────┘
```

**`rpm` never talks to the network and never resolves dependencies. `dnf`/`zypper` never install a file.** Every diagnostic decision starts with deciding which layer broke.

---

## 2. Layer 1 — RPM internals

### 2.1 The on-disk `.rpm` format

An RPM package is four concatenated regions:

```
  offset 0
┌──────────────────────────────────────────────┐
│ LEAD (96 bytes, legacy, ignored since rpm 4) │  magic ed ab ee db
├──────────────────────────────────────────────┤
│ SIGNATURE HEADER  (8-byte aligned)           │  RSA/SHA256 sigs, payload digests
├──────────────────────────────────────────────┤
│ HEADER            (tag → value store)        │  NEVRA, Requires, Provides,
│                                              │  FILENAMES, FILEDIGESTS,
│                                              │  scriptlets, changelog
├──────────────────────────────────────────────┤
│ PAYLOAD  (cpio archive, compressed)          │  gzip | xz | zstd
└──────────────────────────────────────────────┘
```

Verify it yourself:

```
$ hexdump -C -n 16 nginx-1.20.1-14.el9_2.1.x86_64.rpm
00000000  ed ab ee db 03 00 00 00  00 01 6e 67 69 6e 78 2d  |..........nginx-|
00000010

$ rpm -qp --qf '%{PAYLOADFORMAT} / %{PAYLOADCOMPRESSOR} / %{ARCHIVESIZE}\n' \
      nginx-1.20.1-14.el9_2.1.x86_64.rpm
cpio / zstd / 0
```

The critical consequence: **the header is self-describing and independent of the payload**. That is why `dnf` can build a complete dependency graph for 40,000 packages by downloading only `primary.xml.gz` — a projection of headers — without ever fetching a package body.

| Compressor | Typical ratio | Decompress speed | Where used |
|---|---|---|---|
| `gzip` | baseline | fast | EL5–EL6 era, max compatibility |
| `xz` | ~30 % smaller than gzip | slow (single-threaded default) | EL7/EL8, openSUSE |
| `zstd` | ≈ xz size, 3–5× faster decompress | very fast | Fedora 31+, EL9+, SUSE 15.5+ |

For a 4,000-node fleet, the zstd migration is not cosmetic: install wall-clock is dominated by payload decompression, not by download.

### 2.2 NEVRA and the version comparison algorithm

Every package identity is **`Name-[Epoch:]Version-Release.Arch`**.

```
$ rpm -q --qf '%{NAME} | %{EPOCH} | %{VERSION} | %{RELEASE} | %{ARCH}\n' nginx
nginx | 1 | 1.20.1 | 14.el9_2.1 | x86_64

$ rpm -q --qf '%{NEVRA}\n' nginx
nginx-1:1.20.1-14.el9_2.1.x86_64
```

`rpmvercmp` splits Version and Release into alternating alphabetic and numeric segments and compares segment by segment. The rules that bite in production:

| Rule | Example | Result |
|---|---|---|
| Numeric segments compare numerically, leading zeros stripped | `1.010` vs `1.9` | `1.010` newer (10 > 9) |
| Digits outrank letters | `1.0` vs `1.0a` | `1.0a` newer |
| More segments outrank fewer | `1.0` vs `1.0.1` | `1.0.1` newer |
| `~` sorts **before** everything, even empty | `2.0~rc1` vs `2.0` | `2.0` newer |
| `^` sorts **after** the base version | `2.0^git20260101` vs `2.0` | the snapshot is newer |
| **Epoch dominates absolutely** | `1:1.0-1` vs `0:9.9-1` | `1:1.0-1` newer |

```
$ rpmdev-vercmp 1:1.0-1 0:9.9-1
1:1.0-1 > 0:9.9-1
$ echo $?
11

$ rpm --eval '%{lua: print(rpm.vercmp("2.0~rc1", "2.0"))}'
-1

$ zypper vcmp 2.0^git20260101 2.0
2.0^git20260101 is newer than 2.0
```

**Architectural trap:** epoch is a one-way ratchet. Once a vendor ships `Epoch: 1`, no future `Epoch: 0` build — however high its version — will ever be seen as an upgrade. Downgrading past an epoch bump requires an explicit `dnf downgrade` or `rpm -Uvh --oldpackage`. Never introduce an epoch in an internal package to "win" a conflict; you are permanently mortgaging every future rebase.

### 2.3 The rpmdb

```
$ rpm --eval '%{_dbpath}'
/usr/lib/sysimage/rpm

$ ls -l /var/lib/rpm
lrwxrwxrwx. 1 root root 25 Aug 12 09:14 /var/lib/rpm -> ../../usr/lib/sysimage/rpm

$ rpm --eval '%{_db_backend}'
sqlite

$ ls -lh /usr/lib/sysimage/rpm/
total 142M
-rw-r--r--. 1 root root  142M Aug 24 11:02 rpmdb.sqlite
-rw-r--r--. 1 root root   32K Aug 24 11:02 rpmdb.sqlite-shm
-rw-r--r--. 1 root root  4.0M Aug 24 11:02 rpmdb.sqlite-wal
```

| Backend | Distros | Concurrency | Corruption behaviour | Verdict |
|---|---|---|---|---|
| `bdb` (Berkeley DB) | EL7, EL8 (read-only in EL9) | environment locks, `__db.00*` files | Frequent after hard reset / OOM kill; needs `--rebuilddb` | Legacy, avoid |
| `ndb` | openSUSE / SLE 15+ | single-writer, mmap | Robust, self-healing on truncation | Good |
| `sqlite` | Fedora 33+, EL9+ | WAL, atomic commit | Effectively transactional | **Default, best** |

The migration matters operationally: on EL7/EL8 an OOM-killed `yum` during a transaction routinely left a corrupt `Packages` file. On sqlite/WAL, the transaction either commits or does not — which is exactly the property you want when a node loses power mid-patch.

### 2.4 Dependency semantics

RPM dependencies are **capability-based, not package-based**. A package requires a *capability string*; any package that `Provides` it satisfies the requirement.

```
$ rpm -q --requires nginx | head -12
/bin/sh
config(nginx) = 1:1.20.1-14.el9_2.1
libc.so.6(GLIBC_2.34)(64bit)
libcrypto.so.3()(64bit)
libcrypto.so.3(OPENSSL_3.0.0)(64bit)
libpcre2-8.so.0()(64bit)
libssl.so.3()(64bit)
libz.so.1()(64bit)
nginx-filesystem = 1:1.20.1-14.el9_2.1
rtld(GNU_HASH)
system-logos-httpd
systemd

$ rpm -q --provides nginx | head -6
config(nginx) = 1:1.20.1-14.el9_2.1
nginx = 1:1.20.1-14.el9_2.1
nginx(x86-64) = 1:1.20.1-14.el9_2.1
webserver
```

Note `libcrypto.so.3(OPENSSL_3.0.0)(64bit)` — auto-generated soname *and symbol-version* dependencies extracted at build time by `/usr/lib/rpm/find-requires`. This is why an RPM-based OpenSSL 3 → OpenSSL 1.1 downgrade is refused by the solver instead of producing a host full of unstartable binaries.

| Dependency type | Meaning | Solver behaviour |
|---|---|---|
| `Requires` | hard, must be satisfied | transaction fails without it |
| `Requires(pre)` / `Requires(post)` | ordering constraint for scriptlets | affects tsort, not just presence |
| `Recommends` | weak, install by default | honoured unless `install_weak_deps=False` |
| `Suggests` | weak, not installed automatically | surfaced by UI only |
| `Supplements` | reverse-recommends ("pull me in if X present") | installs this package when X is |
| `Enhances` | reverse-suggests | informational |
| `Conflicts` | cannot coexist | transaction refused |
| `Obsoletes` | this package replaces that one | triggers automatic replacement on upgrade |
| Rich/boolean deps | `Requires: (foo if bar)`, `(a or b)` | RPM 4.13+, needs libsolv-aware resolver |

`Obsoletes` is the most dangerous tag in production. `Obsoletes: legacy-agent < 2.0` in a third-party repo will silently remove your monitoring agent during a routine `dnf upgrade`. Audit it:

```
$ dnf repoquery --qf '%{name}-%{evr}: %{obsoletes}' --obsoletes --repo=vendor-tools
```

### 2.5 Scriptlets and transaction ordering

```
$ rpm -q --scripts nginx
preinstall scriptlet (using /bin/sh):
/usr/bin/getent group nginx >/dev/null || /usr/sbin/groupadd -r nginx
/usr/bin/getent passwd nginx >/dev/null || \
    /usr/sbin/useradd -r -d /var/lib/nginx -g nginx \
    -s /sbin/nologin -c "Nginx web server" nginx
exit 0
postinstall scriptlet (using /bin/sh):
if [ $1 -eq 1 ] ; then
        systemctl preset nginx.service &>/dev/null || :
fi
preuninstall scriptlet (using /bin/sh):
if [ $1 -eq 0 ] ; then
        systemctl --no-reload disable --now nginx.service &>/dev/null || :
fi
postuninstall scriptlet (using /bin/sh):
systemctl daemon-reload &>/dev/null || :
if [ $1 -ge 1 ] ; then
        systemctl try-restart nginx.service &>/dev/null || :
fi
```

The `$1` argument is the **count of instances of this package that will exist after the operation** — the single most misunderstood fact in RPM packaging:

| Operation | `%pre` `$1` | `%post` `$1` | `%preun` `$1` | `%postun` `$1` |
|---|---|---|---|---|
| First install | 1 | 1 | — | — |
| Upgrade | 2 | 2 | 1 (old pkg) | 1 (old pkg) |
| Erase | — | — | 0 | 0 |

Therefore `if [ $1 -eq 1 ]` means "fresh install only" and `if [ $1 -eq 0 ]` means "final removal, not an upgrade". Getting this wrong is why a package disables its own service on every upgrade.

Ordering within a transaction: RPM builds a directed graph from `Requires(pre|post)` and topologically sorts it. `%posttrans` runs after *all* packages in the transaction are installed — the correct place for cache regeneration (`ldconfig`, font caches, GTK icon caches). File triggers extend this system-wide:

```
$ rpm -q --filetriggers glibc
transfiletriggerin scriptlet (using <lua>) -- /lib, /lib64, /usr/lib, /usr/lib64
posix.exec("/sbin/ldconfig")
```

One `ldconfig` per transaction instead of one per package — the reason EL8+ transactions are dramatically faster than EL7.

---

## 3. `rpm` — the complete operational command surface

### 3.1 Query mode (`-q`)

```
$ rpm -qa | wc -l
487

$ rpm -qa --last | head -5
kernel-5.14.0-427.28.1.el9_4.x86_64        Sun 24 Aug 2026 11:02:41 AM UTC
nginx-1:1.20.1-14.el9_2.1.x86_64           Sun 24 Aug 2026 11:02:38 AM UTC
nginx-core-1:1.20.1-14.el9_2.1.x86_64      Sun 24 Aug 2026 11:02:37 AM UTC
nginx-filesystem-1:1.20.1-14.el9_2.1.noarch Sun 24 Aug 2026 11:02:36 AM UTC
openssl-1:3.0.7-27.el9.x86_64              Fri 12 Aug 2026 09:14:02 PM UTC

$ rpm -qi bash
Name        : bash
Version     : 5.1.8
Release     : 9.el9
Architecture: x86_64
Install Date: Mon 12 Aug 2026 09:14:22 PM UTC
Group       : Unspecified
Size        : 7807488
License     : GPLv3+
Signature   : RSA/SHA256, Wed 24 Jan 2026 03:12:11 PM UTC, Key ID 199e2f91fd431d51
Source RPM  : bash-5.1.8-9.el9.src.rpm
Build Date  : Wed 24 Jan 2026 02:51:03 PM UTC
Build Host  : x86-64-01.build.eng.rdu2.redhat.com
Packager    : Red Hat, Inc. <http://bugzilla.redhat.com/bugzilla>
Vendor      : Red Hat, Inc.
URL         : https://www.gnu.org/software/bash
Summary     : The GNU Bourne Again shell
Description :
The GNU Bourne Again shell (Bash) is a shell or command language
interpreter that is compatible with the Bourne shell (sh).
```

| Selector | Meaning |
|---|---|
| `-q <pkg>` | query installed package by name |
| `-qa` | all installed packages |
| `-qp <file.rpm>` | query an **uninstalled** `.rpm` file |
| `-qf <path>` | which package owns this file |
| `-q --whatprovides <cap>` | which installed package provides a capability |
| `-q --whatrequires <cap>` | which installed packages require a capability |
| `-qg <group>` | by legacy group tag |

| Info flag | Output |
|---|---|
| `-i` | full metadata header |
| `-l` | file list |
| `-c` | config files only |
| `-d` | documentation files only |
| `--dump` | path, size, mtime, digest, mode, owner, group, isconfig, isdoc, rdev, symlink |
| `--requires` / `-R` | dependencies |
| `--provides` | capabilities |
| `--conflicts`, `--obsoletes`, `--recommends`, `--suggests` | remaining dependency classes |
| `--scripts`, `--triggers`, `--filetriggers` | scriptlet source |
| `--changelog` | changelog (contains CVE references — audit gold) |
| `--queryformat` / `--qf` | arbitrary tag formatting |

The two objective-mandated inverse lookups:

```
# Which package owns this file?
$ rpm -qf /usr/sbin/nginx
nginx-core-1:1.20.1-14.el9_2.1.x86_64

$ rpm -qf $(readlink -f $(which python3))
python3-3.9.18-3.el9_4.1.x86_64

# What files does this package provide?
$ rpm -ql nginx-filesystem
/etc/nginx
/etc/nginx/conf.d
/etc/nginx/default.d
/usr/share/nginx
/usr/share/nginx/html
/var/log/nginx

$ rpm -qc nginx
/etc/logrotate.d/nginx
/etc/nginx/fastcgi.conf
/etc/nginx/fastcgi_params
/etc/nginx/mime.types
/etc/nginx/nginx.conf
/etc/nginx/scgi_params
/etc/nginx/uwsgi_params

# Same, for a package that is NOT installed:
$ rpm -qlp ./acme-metrics-agent-2.4.0-1.el9.x86_64.rpm
/etc/acme/metrics-agent.yaml
/usr/bin/acme-metrics-agent
/usr/lib/systemd/system/acme-metrics-agent.service
/usr/lib/sysusers.d/acme-metrics-agent.conf
/usr/share/doc/acme-metrics-agent/README.md
/usr/share/licenses/acme-metrics-agent/LICENSE
/var/log/acme
```

`--queryformat` turns the rpmdb into a reporting engine. This is how you produce fleet inventory without any agent:

```
$ rpm -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME:date}\n' \
    | sort > /var/tmp/inventory-$(hostname -s).tsv

# Find every package NOT signed by a key you trust
$ rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' | grep -v 'Key ID 199e2f91fd431d51'
acme-metrics-agent-2.4.0-1.el9 (none)
gpg-pubkey-fd431d51-4ae0493b (none)

# Iterate over array tags with [ ]
$ rpm -q --qf '[%{FILENAMES} %{FILEMODES:perms} %{FILEUSERNAME}\n]' nginx-filesystem
/etc/nginx drwxr-xr-x root
/etc/nginx/conf.d drwxr-xr-x root
/etc/nginx/default.d drwxr-xr-x root
/usr/share/nginx drwxr-xr-x root
/usr/share/nginx/html drwxr-xr-x root
/var/log/nginx drwxr-xr-x root
```

### 3.2 Verification mode (`-V`)

`rpm -V` compares every file on disk against the digest, mode, owner, group, size, mtime and capabilities recorded in the rpmdb. It is the cheapest host-integrity check available and requires no additional tooling.

```
$ rpm -V nginx
S.5....T.  c /etc/nginx/nginx.conf

$ rpm -V openssh-server
.M.......    /etc/ssh/sshd_config
missing     /usr/share/man/man5/sshd_config.5.gz

$ rpm -Va --nomtime --nordev 2>/dev/null | grep -v '^\.\{9\}' | head
S.5....T.  c /etc/nginx/nginx.conf
.M.......    /etc/ssh/sshd_config
..5......    /usr/bin/curl        <-- INVESTIGATE IMMEDIATELY
missing   d /usr/share/man/man5/sshd_config.5.gz
```

The nine-character result string, in order:

| Pos | Char | Meaning |
|---|---|---|
| 1 | `S` | **S**ize differs |
| 2 | `M` | **M**ode (permissions/type) differs |
| 3 | `5` | Digest (MD5/SHA256) differs — **file content changed** |
| 4 | `D` | **D**evice major/minor mismatch |
| 5 | `L` | Symbolic **L**ink target mismatch |
| 6 | `U` | **U**ser ownership differs |
| 7 | `G` | **G**roup ownership differs |
| 8 | `T` | m**T**ime differs |
| 9 | `P` | ca**P**abilities differ |

`.` = test passed, `?` = test could not be performed (unreadable file). The literal string `missing` replaces all nine when the file is gone.

The attribute marker after the result string classifies the file: `c` config, `d` documentation, `g` ghost (owned but not shipped, e.g. log files), `l` license, `r` readme.

**Operational triage rule:**

| Result | Interpretation | Action |
|---|---|---|
| `S.5....T.  c /etc/...` | Config edited by an admin or config-mgmt | Expected; reconcile with Ansible/Puppet |
| `.M.......  /etc/...` | Permissions changed | Suspicious unless hardening baseline did it |
| `..5......  /usr/bin/...` | **A shipped binary's content changed** | Treat as compromise until proven otherwise |
| `missing  d ...` | Docs stripped (`--excludedocs`, container base image) | Benign |
| `missing    /usr/lib64/...` | Library deleted | Something will fail to start |
| `.......T.` alone | mtime only, often from a restore | Low signal, `--nomtime` to suppress |

Repairing metadata drift (rpm 4.16+):

```
$ rpm --setperms nginx        # restore modes only
$ rpm --setugids nginx        # restore owner/group only
$ rpm --restore nginx         # restore modes, ownership and capabilities
$ rpm -V nginx
S.5....T.  c /etc/nginx/nginx.conf     # content of a config is never "restored"
```

To restore **content**, reinstall the payload — see §5.

### 3.3 Install / upgrade / erase

```
$ sudo rpm -ivh ./acme-metrics-agent-2.4.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
Updating / installing...
   1:acme-metrics-agent-2.4.0-1.el9   ################################# [100%]

$ sudo rpm -Uvh ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
Updating / installing...
   1:acme-metrics-agent-2.5.0-1.el9   ################################# [ 50%]
Cleaning up / removing...
   2:acme-metrics-agent-2.4.0-1.el9   ################################# [100%]
```

| Mode | Behaviour if not installed | Behaviour if older version installed |
|---|---|---|
| `-i` / `--install` | installs | **fails** with "already installed" (unless install-only) |
| `-U` / `--upgrade` | installs | upgrades, removes old |
| `-F` / `--freshen` | **does nothing** | upgrades |
| `-e` / `--erase` | fails | removes (no dependency resolution) |

`-F` is the correct verb for "patch what is present, install nothing new" — the classic mass-update loop against a directory of RPMs.

**Install-only packages.** Kernels are marked `installonlypkg(kernel)` and must use `-i`, never `-U`; upgrading would remove the running kernel and leave you with no rollback. `dnf` handles this automatically via `installonly_limit`.

```
$ rpm -q --qf '[%{PROVIDES}\n]' kernel-5.14.0-427.28.1.el9_4 | grep installonly
installonlypkg(kernel)

$ rpm -q kernel
kernel-5.14.0-427.13.1.el9_4.x86_64
kernel-5.14.0-427.28.1.el9_4.x86_64
```

Flags you will reach for, and what they actually cost you:

| Flag | Effect | Risk |
|---|---|---|
| `--test` | dry run: signature, dep and file-conflict checks only | none — **use it always in change windows** |
| `-vv` | protocol-level debug | none |
| `--nodeps` | skip dependency check | **breaks the invariant the DB exists to guarantee** |
| `--force` | `--replacepkgs --replacefiles --oldpackage` | blunt; masks real conflicts |
| `--replacepkgs` | reinstall same NEVRA | safe, the correct "restore payload" tool |
| `--replacefiles` | overwrite files owned by another package | leaves two packages claiming one file |
| `--oldpackage` | allow downgrade via `-U` | fine, deliberately |
| `--justdb` | update rpmdb without touching the filesystem | for image/DB repair only; guarantees drift otherwise |
| `--noscripts` / `--notriggers` | skip scriptlets | users/services will not be created |
| `--excludedocs` | drop `%doc` files | standard in container images |
| `--root /mnt` | operate on an alternate root | chroot/rescue/image builds |
| `--dbpath <dir>` | alternate rpmdb location | forensics against a copied DB |
| `--nodigest` / `--nosignature` | skip integrity checks | **never in production** |

```
# Always rehearse:
$ sudo rpm -Uvh --test ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]

# A real conflict, caught by --test:
$ sudo rpm -ivh --test ./rogue-tools-1.0-1.el9.x86_64.rpm
Verifying...                          ################################# [100%]
Preparing...                          ################################# [100%]
	file /usr/bin/curl from install of rogue-tools-1.0-1.el9.x86_64 conflicts
	with file from package curl-7.76.1-29.el9_4.x86_64

# Rescue / offline forensics against another root:
$ sudo rpm -qa --root=/mnt/sysroot | wc -l
412
$ sudo rpm -Va --root=/mnt/sysroot --nomtime | grep -v '^\.\{9\}'
```

### 3.4 Integrity and signatures

RPM signatures are the last line of the supply chain. Three distinct checks exist and they are not interchangeable:

| Check | Command | Proves |
|---|---|---|
| Payload/header digest | `rpm -K --nosignature` | file not truncated or corrupted in transit |
| Header + payload GPG signature | `rpm -K` / `rpm --checksig` | package built and signed by the holder of the key |
| Key trust | `rpm -qa gpg-pubkey*` | that key is in *your* trust store |

```
$ sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

$ rpm -qa gpg-pubkey\* --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'
gpg-pubkey-fd431d51-4ae0493b	gpg(Red Hat, Inc. (release key 2) <security@redhat.com>)
gpg-pubkey-5a6340b3-6229229e	gpg(Red Hat, Inc. (auxiliary key 3) <security@redhat.com>)
gpg-pubkey-9b1d2a17-64b1a1c2	gpg(ACME Platform Signing Key <platform@acme.internal>)

$ rpm -qi gpg-pubkey-9b1d2a17-64b1a1c2 | head -12
Name        : gpg-pubkey
Version     : 9b1d2a17
Release     : 64b1a1c2
Architecture: (none)
Install Date: Wed 20 Aug 2026 04:41:09 PM UTC
Group       : Public Keys
Size        : 0
License     : pubkey
Signature   : (none)
Source RPM  : (none)
Summary     : gpg(ACME Platform Signing Key <platform@acme.internal>)

$ rpm -K nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK

$ rpm -Kv nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-1.20.1-14.el9_2.1.x86_64.rpm:
    Header V4 RSA/SHA256 Signature, key ID 199e2f91: OK
    Header SHA256 digest: OK
    Header SHA1 digest: OK
    Payload SHA256 digest: OK
    V4 RSA/SHA256 Signature, key ID 199e2f91: OK

# Unknown key:
$ rpm -Kv ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm:
    Header V4 RSA/SHA256 Signature, key ID 9b1d2a17: NOKEY
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
    V4 RSA/SHA256 Signature, key ID 9b1d2a17: NOKEY
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm: digests SIGNATURES NOT OK

# Not signed at all:
$ rpm -Kv ./scratch-build-0.1-1.el9.x86_64.rpm
./scratch-build-0.1-1.el9.x86_64.rpm:
    Header SHA256 digest: OK
    Payload SHA256 digest: OK
./scratch-build-0.1-1.el9.x86_64.rpm: digests OK
```

Read the summary line precisely: `digests signatures OK` (both), `digests OK` (**unsigned**), `digests SIGNATURES NOT OK` (signed, key untrusted or signature bad). A CI gate that greps for `OK` passes unsigned packages. Grep for the exact string `digests signatures OK`.

On EL9+ this is enforced by librpm itself:

```
$ rpm --eval '%{_pkgverify_level}'
all
```

Signing your own packages:

```
$ cat >> ~/.rpmmacros <<'EOF'
%_gpg_name ACME Platform Signing Key <platform@acme.internal>
%_gpg_digest_algo sha256
%_source_payload w19.zstdio
%_binary_payload w19.zstdio
EOF

$ rpmsign --addsign ./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm
Enter passphrase:
Pass phrase is good.
./acme-metrics-agent-2.5.0-1.el9.x86_64.rpm:

$ rpmsign --delsign ./old-package.rpm     # strip before re-signing with a rotated key
```

### 3.5 `rpm2cpio` — reading a package without installing it

`rpm2cpio` strips the lead, signature header and header, decompresses the payload and writes a raw cpio stream to stdout. It is the only sanctioned way to extract package content without touching the rpmdb.

```
$ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -idmv
./usr/sbin/nginx
./usr/share/man/man3/nginx.3pm.gz
./usr/share/man/man8/nginx.8.gz
1846 blocks

$ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -t | head
./usr/sbin/nginx
./usr/share/man/man3/nginx.3pm.gz
./usr/share/man/man8/nginx.8.gz

# Extract exactly one file (leading ./ matters):
$ rpm2cpio openssh-server-8.7p1-38.el9.x86_64.rpm \
    | cpio -idmv './etc/ssh/sshd_config'
./etc/ssh/sshd_config
2 blocks

# Read a config from a package without extracting anything:
$ rpm2cpio httpd-2.4.53-11.el9_2.5.x86_64.rpm \
    | cpio --to-stdout -i './etc/httpd/conf/httpd.conf' | head -5
#
# This is the main Apache HTTP server configuration file.
# It contains the configuration directives that give the server its instructions.
```

`cpio` flags: `-i` extract, `-d` create directories, `-m` preserve mtimes, `-v` verbose, `-t` list only, `--to-stdout` stream a member.

The modern alternative, `rpm2archive`, emits a tar stream and preserves things cpio cannot (large files, extended attributes):

```
$ rpm2archive -n nginx-core-1.20.1-14.el9_2.1.x86_64.rpm > nginx-core.tar
$ tar tvf nginx-core.tar | head -3
-rwxr-xr-x root/root   1352144 2026-01-24 14:51 ./usr/sbin/nginx
-rw-r--r-- root/root      1319 2026-01-24 14:51 ./usr/share/man/man3/nginx.3pm.gz
-rw-r--r-- root/root      7392 2026-01-24 14:51 ./usr/share/man/man8/nginx.8.gz

# Pipe straight into a container filesystem, no temp file:
$ rpm2archive - < nginx-core-*.rpm | tar -xzC ./rootfs
```

| Tool | Output | Preserves xattrs / caps | > 4 GB files | Availability |
|---|---|---|---|---|
| `rpm2cpio` | cpio to stdout | no | no (cpio `newc` limit) | universal, **exam-mandated** |
| `rpm2archive` | `.tgz` (or stdout with `-n -`) | yes | yes | rpm 4.14+ |

**Recovery pattern** — restore a single deleted vendor file without a full reinstall:

```
$ ls -l /usr/bin/curl
ls: cannot access '/usr/bin/curl': No such file or directory

$ rpm -qf /usr/bin/curl
curl-7.76.1-29.el9_4.x86_64

$ dnf download curl
$ rpm2cpio curl-7.76.1-29.el9_4.x86_64.rpm \
    | sudo cpio -idmv -D / './usr/bin/curl'
./usr/bin/curl
1204 blocks

$ rpm -V curl
$ echo $?
0
```

---

## 4. Layer 2 — YUM / DNF

### 4.1 What `yum` is on a modern system

```
$ ls -l /usr/bin/yum
lrwxrwxrwx. 1 root root 5 Aug 12 09:13 /usr/bin/yum -> dnf-3

$ ls -l /etc/yum.conf
lrwxrwxrwx. 1 root root 12 Aug 12 09:13 /etc/yum.conf -> dnf/dnf.conf

$ yum --version
4.14.0
  Installed: dnf-0:4.14.0-9.el9.noarch at Mon 12 Aug 2026 09:13:41 PM UTC
  Built    : Red Hat, Inc. <http://bugzilla.redhat.com/bugzilla> at ...
```

`yum` is a compatibility symlink to DNF on every current RPM distribution (`dnf-3` on EL8/EL9 and Fedora ≤ 40, `dnf5` on Fedora 41+). `/etc/yum.conf` is a symlink to `/etc/dnf/dnf.conf`, and `/etc/yum.repos.d/` remains the real, canonical repository directory — DNF did not move it. The LPI objective's terminology is therefore still exactly correct on a 2026 system.

| | yum 3 (EL6/EL7) | dnf 4 (EL8/EL9, Fedora ≤ 40) | dnf5 (Fedora 41+) |
|---|---|---|---|
| Language | Python 2 | Python 3 + libdnf (C++) | C++ with thin Python |
| Resolver | ad-hoc Python depsolver | **libsolv** (SAT) | libsolv |
| Metadata | `yum.repos.d` + own cache | librepo, zchunk deltas | librepo, zchunk |
| API stability | none | `libdnf` | `libdnf5` |
| Parallel downloads | no | `max_parallel_downloads` (≤ 20) | yes, default higher |
| `history undo` | partial | full transactional | full |
| Modularity | no | yes (AppStream) | deprecated |
| Behaviour on unsolvable | picks something | **fails by default** (`best=True`) | fails |

The move from a heuristic depsolver to a SAT solver is the most consequential change. yum 3 would happily produce a partially-satisfying transaction; libsolv either proves a solution exists or reports the exact unsatisfiable clause. This is why EL8+ error messages name the specific conflicting provider instead of "nothing to do".

### 4.2 Repository metadata

```
$ curl -s https://mirror.acme.internal/rocky/9/BaseOS/x86_64/os/repodata/repomd.xml | head -32
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo"
        xmlns:rpm="http://linux.duke.edu/metadata/rpm">
  <revision>1755993601</revision>
  <data type="primary">
    <checksum type="sha256">7b1e...c4a9</checksum>
    <open-checksum type="sha256">21fd...9e70</open-checksum>
    <location href="repodata/7b1e...c4a9-primary.xml.gz"/>
    <timestamp>1755993601</timestamp>
    <size>2841923</size>
    <open-size>28419230</open-size>
  </data>
  <data type="filelists">
    <checksum type="sha256">9a02...b311</checksum>
    <location href="repodata/9a02...b311-filelists.xml.gz"/>
    <size>18402911</size>
  </data>
  <data type="other">
    ...
  </data>
  <data type="updateinfo">
    <checksum type="sha256">c73d...1f88</checksum>
    <location href="repodata/c73d...1f88-updateinfo.xml.gz"/>
  </data>
</repomd>
```

| Metadata file | Contains | Downloaded when |
|---|---|---|
| `repomd.xml` | index + checksums of everything below; the **signed** root of trust (`repomd.xml.asc`) | always |
| `primary.xml.gz` | NEVRA, deps, summary, location, size | always |
| `filelists.xml.gz` | every file path in every package | on demand (`dnf provides`, file-based deps) |
| `other.xml.gz` | changelogs | on demand (`dnf changelog`) |
| `updateinfo.xml.gz` | errata: advisory IDs, severity, CVE mapping | for `dnf updateinfo` / `--security` |
| `modules.yaml.gz` | AppStream module streams | if repo is modular |
| `comps.xml` | groups / environments | `dnf group` |

**Production gotcha:** `filelists` is huge and is fetched lazily. On dnf5 and some minimal images it is not fetched at all unless configured, so `dnf provides /usr/bin/foo` returns nothing for packages that are not installed. Force it:

```
$ dnf --setopt=optional_metadata_types=filelists provides /usr/bin/htpasswd
```

`updateinfo` is what makes security patching auditable — and it is exactly what a naive `createrepo_c` mirror silently drops. If your internal mirror has no `updateinfo.xml`, then `dnf update --security` on every host in your fleet is a no-op that reports success.

### 4.3 `/etc/dnf/dnf.conf` (`/etc/yum.conf`) — annotated production configuration

```ini
# /etc/dnf/dnf.conf  (== /etc/yum.conf via symlink)
# Fleet baseline — managed by Ansible, do not edit by hand.

[main]
# --- integrity -------------------------------------------------------------
gpgcheck=1                     # verify package signatures (never disable)
localpkg_gpgcheck=1            # also verify local .rpm files passed on the CLI
repo_gpgcheck=1                # verify repomd.xml.asc — signs the METADATA,
                               # closing the "valid old package, replayed" hole

# --- determinism -----------------------------------------------------------
best=1                         # fail loudly rather than install an older version
obsoletes=1                    # honour Obsoletes: on upgrade
install_weak_deps=0            # servers: do not pull Recommends: (smaller
                               # attack surface, reproducible image size)
skip_if_unavailable=0          # a dead mirror must FAIL the run, not silently
                               # produce an under-patched host
clean_requirements_on_remove=1 # remove orphaned deps with their parent

# --- kernels ---------------------------------------------------------------
installonly_limit=3            # keep N kernels: current + 2 rollback targets
protect_running_kernel=1       # never let a transaction remove the running kernel

# --- performance -----------------------------------------------------------
max_parallel_downloads=10      # hard max is 20
fastestmirror=0                # deterministic mirror order beats micro-optimising;
                               # set to 1 only on roaming laptops
keepcache=0                    # do not retain .rpm bodies (disk on 4k nodes)
metadata_expire=6h             # how long cached metadata is considered fresh
timeout=30
retries=5
minrate=10k                    # abort a stalled mirror instead of hanging forever
throttle=0

# --- safety nets -----------------------------------------------------------
exclude=kernel* kmod-*         # kernels move only in a dedicated change window;
                               # override per-run with --disableexcludes=main
protected_packages=dnf,systemd,glibc,kernel-core,sudo,openssh-server
tsflags=nodocs                 # container images / minimal servers

# --- observability ---------------------------------------------------------
logdir=/var/log
history_record=1
debuglevel=2
errorlevel=2
assumeyes=0                    # NEVER globally; use -y per invocation

# --- proxy (egress-restricted estates) -------------------------------------
#proxy=http://proxy.acme.internal:3128
#proxy_auth_method=none
#sslverify=1
#sslcacert=/etc/pki/ca-trust/source/anchors/acme-root.pem
```

| Option | Default | Why the production value differs |
|---|---|---|
| `skip_if_unavailable` | `False` (EL8+) | Keep `0`. `1` turns a broken mirror into a *successful* run that installed nothing — the single most common cause of "patched" hosts that are not. |
| `install_weak_deps` | `True` | `0` on servers: `Recommends:` drags in tooling nobody audited. Costs some convenience on workstations. |
| `best` | `True` (EL8+) | Keep `1`. `0` silently downgrades to whatever is solvable, producing a fleet with heterogeneous versions. |
| `keepcache` | `False` | `0` on nodes; `1` on build hosts where re-download is the bottleneck. |
| `metadata_expire` | `48h` (repo default) | `6h` for internal repos on a fast LAN; `-1`/`never` for a **pinned** content view, which is how you get reproducible image builds. |
| `installonly_limit` | `3` | Below 2 you lose kernel rollback. Above 4 you exhaust `/boot` on default partitioning. |
| `tsflags=nodocs` | unset | Saves 100–300 MB per image; breaks `man` on the host — never on a bastion. |

### 4.4 `/etc/yum.repos.d/*.repo` — complete repository definition

```ini
# /etc/yum.repos.d/acme-platform.repo
# ACME internal platform repositories. Managed by Ansible; local edits are reverted.
#
# Variables expanded by dnf:
#   $releasever  -> 9        (from system-release provides, or /etc/dnf/vars/releasever)
#   $basearch    -> x86_64
#   $arch        -> x86_64
#   $infra       -> stock
#   custom vars  -> any file in /etc/dnf/vars/<name>, content is the value
#                   here: /etc/dnf/vars/acmeenv contains "prod" or "stage"

[acme-platform-baseos]
name=ACME Platform - BaseOS $releasever - $basearch ($acmeenv)
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
priority=10
metadata_expire=6h
skip_if_unavailable=0
sslverify=1
sslcacert=/etc/pki/ca-trust/source/anchors/acme-root.pem
sslclientcert=/etc/pki/entitlement/node.pem
sslclientkey=/etc/pki/entitlement/node-key.pem
countme=0
timeout=30
retries=5
minrate=10k

[acme-platform-appstream]
name=ACME Platform - AppStream $releasever - $basearch ($acmeenv)
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/AppStream/$basearch/os/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
priority=10
metadata_expire=6h
skip_if_unavailable=0

# Internally built packages. Higher priority (lower number) so an internal
# rebuild of an upstream package always wins the solve.
[acme-internal]
name=ACME Internal Packages - $basearch
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/acme-internal/$releasever/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
priority=5
metadata_expire=1h
skip_if_unavailable=0

# Source RPMs — disabled by default, enabled on demand for `dnf download --source`
# and for reproducing a vendor build during incident analysis.
[acme-platform-source]
name=ACME Platform - Sources $releasever
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/rocky/$releasever/BaseOS/source/tree/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

# Third-party vendor repo, tightly fenced: it may ONLY provide its own packages.
# Without `includepkgs`, a vendor Obsoletes: line can replace a system package.
[vendor-observability]
name=Vendor Observability Agent
baseurl=https://depot.acme.internal/pulp/content/$acmeenv/vendor-observability/$releasever/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-VENDOR-OBS
priority=20
includepkgs=vendor-agent vendor-agent-plugins-* 
exclude=glibc* openssl* systemd*
skip_if_unavailable=1
```

| `.repo` key | Purpose | Production note |
|---|---|---|
| `[id]` | repo id used by `--repo`, `--enablerepo` | keep stable; it appears in every log line |
| `name` | human label | include env + arch; it is what the operator reads |
| `baseurl` | explicit URL list (space/newline separated for failover) | **prefer over `mirrorlist`** for determinism |
| `metalink`/`mirrorlist` | dynamic mirror list | non-reproducible; unsuitable for pinned builds |
| `enabled` | 0/1 | keep risky repos at 0, enable per-command |
| `gpgcheck` | verify **package** signatures | always 1 |
| `repo_gpgcheck` | verify **metadata** (`repomd.xml.asc`) | closes the metadata-replay hole; requires the depot to sign metadata |
| `gpgkey` | key URI(s), `file://` or `https://` | ship keys via a package, do not fetch over plain HTTP |
| `priority` | lower number wins (requires `dnf-plugin-priorities` semantics, built into libdnf) | internal < distro < vendor |
| `includepkgs` / `exclude` | allow/deny lists per repo | the correct fence for third-party repos |
| `module_hotfixes` | let a non-modular repo override a module stream | required for many vendor repos on EL8 |
| `cost` | tiebreaker when priority equal (default 1000) | prefer local mirrors |
| `countme` | send weekly anonymous counter | set `0` in restricted estates |
| `skip_if_unavailable` | tolerate this repo being down | `1` only for genuinely optional repos |

Managing repos from the CLI rather than by editing files:

```
$ sudo dnf config-manager --add-repo https://depot.acme.internal/acme-internal.repo
Adding repo from: https://depot.acme.internal/acme-internal.repo

$ sudo dnf config-manager --set-disabled vendor-observability
$ sudo dnf config-manager --set-enabled acme-platform-source

$ dnf repolist
repo id                       repo name
acme-internal                 ACME Internal Packages - x86_64
acme-platform-appstream       ACME Platform - AppStream 9 - x86_64 (prod)
acme-platform-baseos          ACME Platform - BaseOS 9 - x86_64 (prod)
vendor-observability          Vendor Observability Agent

$ dnf repolist --all
repo id                       repo name                                 status
acme-internal                 ACME Internal Packages - x86_64           enabled: 47
acme-platform-appstream       ACME Platform - AppStream 9 - x86_64      enabled: 5,412
acme-platform-baseos          ACME Platform - BaseOS 9 - x86_64         enabled: 1,807
acme-platform-source          ACME Platform - Sources 9                 disabled
vendor-observability          Vendor Observability Agent               enabled: 12

$ dnf repoinfo acme-internal
Repo-id            : acme-internal
Repo-name          : ACME Internal Packages - x86_64
Repo-status        : enabled
Repo-revision      : 1755993601
Repo-updated       : Sun 24 Aug 2026 09:20:01 AM UTC
Repo-pkgs          : 47
Repo-available-pkgs: 47
Repo-size          : 312 M
Repo-baseurl       : https://depot.acme.internal/pulp/content/prod/acme-internal/9/x86_64/
Repo-expire        : 3,600 second(s) (last: Sun 24 Aug 2026 10:58:12 AM UTC)
Repo-filename      : /etc/yum.repos.d/acme-platform.repo
```

### 4.5 Install, upgrade, remove, reinstall

```
$ sudo dnf install nginx
Last metadata expiration check: 0:03:12 ago on Sun 24 Aug 2026 10:58:12 AM UTC.
Dependencies resolved.
================================================================================
 Package              Arch    Version                  Repository          Size
================================================================================
Installing:
 nginx                x86_64  1:1.20.1-14.el9_2.1      acme-platform-app…  36 k
Installing dependencies:
 nginx-core           x86_64  1:1.20.1-14.el9_2.1      acme-platform-app… 566 k
 nginx-filesystem     noarch  1:1.20.1-14.el9_2.1      acme-platform-app…  10 k
 rocky-logos-httpd    noarch  90.15-2.el9              acme-platform-bas…  25 k

Transaction Summary
================================================================================
Install  4 Packages

Total download size: 637 k
Installed size: 1.9 M
Is this ok [y/N]: y
Downloading Packages:
(1/4): nginx-filesystem-1.20.1-14.el9_2.1.noa…  92 kB/s |  10 kB     00:00
(2/4): nginx-1.20.1-14.el9_2.1.x86_64.rpm      312 kB/s |  36 kB     00:00
(3/4): rocky-logos-httpd-90.15-2.el9.noarch.…  198 kB/s |  25 kB     00:00
(4/4): nginx-core-1.20.1-14.el9_2.1.x86_64.r… 4.1 MB/s | 566 kB     00:00
--------------------------------------------------------------------------------
Total                                          1.2 MB/s | 637 kB     00:00
Running transaction check
Transaction check succeeded.
Running transaction test
Transaction test succeeded.
Running transaction
  Preparing        :                                                        1/1
  Installing       : nginx-filesystem-1:1.20.1-14.el9_2.1.noarch            1/4
  Installing       : rocky-logos-httpd-90.15-2.el9.noarch                   2/4
  Installing       : nginx-core-1:1.20.1-14.el9_2.1.x86_64                  3/4
  Installing       : nginx-1:1.20.1-14.el9_2.1.x86_64                       4/4
  Running scriptlet: nginx-1:1.20.1-14.el9_2.1.x86_64                       4/4
  Verifying        : nginx-1:1.20.1-14.el9_2.1.x86_64                       1/4
  Verifying        : nginx-core-1:1.20.1-14.el9_2.1.x86_64                  2/4
  Verifying        : nginx-filesystem-1:1.20.1-14.el9_2.1.noarch            3/4
  Verifying        : rocky-logos-httpd-90.15-2.el9.noarch                   4/4

Installed:
  nginx-1:1.20.1-14.el9_2.1.x86_64      nginx-core-1:1.20.1-14.el9_2.1.x86_64
  nginx-filesystem-1:1.20.1-14.el9_2.1.noarch  rocky-logos-httpd-90.15-2.el9.noarch

Complete!
```

Read the four phases: **transaction check** (dependency closure), **transaction test** (dry-run against the real filesystem — file conflicts, disk space), **transaction** (actual writes), **verify** (rpmdb readback). A failure in "transaction test" changed nothing on disk; a failure inside "Running transaction" leaves a partially-applied state that `dnf history` can undo.

The full verb surface:

| Verb | Semantics |
|---|---|
| `install <pkg\|NEVRA\|file.rpm\|@group>` | install; on EL8+ also upgrades if already present |
| `reinstall <pkg>` | re-lay the same NEVRA — repairs deleted/modified files |
| `upgrade [pkg]` | upgrade named packages, or everything |
| `upgrade-minimal` | only up to the version fixing the newest advisory |
| `downgrade <pkg>` | move to the previous available version |
| `distro-sync` | force every package to *exactly* what the repos offer, up or down |
| `remove` / `erase` | remove + orphaned deps (`clean_requirements_on_remove`) |
| `autoremove` | remove all packages no longer required by a user-installed package |
| `swap <old> <new>` | atomic replace of conflicting packages |
| `mark install\|remove\|group` | rewrite the "user installed vs dependency" flag |
| `module enable\|disable\|reset\|install` | AppStream module streams (EL8/EL9) |
| `check` | rpmdb consistency (dependencies, duplicates, obsoletes) |
| `history` | list/info/undo/redo/rollback/userinstalled |
| `needs-restarting` | which running processes use deleted/upgraded libraries |

```
# Repair a tampered binary — the correct alternative to rpm2cpio surgery:
$ sudo dnf reinstall curl
...
Reinstalled:
  curl-7.76.1-29.el9_4.x86_64
Complete!

# Version-explicit install (idempotent, reproducible):
$ sudo dnf install -y nginx-1:1.20.1-14.el9_2.1

# Security-only patching:
$ sudo dnf updateinfo list --security
RLSA-2026:5544 Important/Sec. openssl-1:3.0.7-27.el9_4.x86_64
RLSA-2026:5601 Moderate/Sec.  curl-7.76.1-31.el9_4.x86_64

$ sudo dnf upgrade --security --bugfix -y

$ sudo dnf upgrade --advisory=RLSA-2026:5544 -y
$ sudo dnf upgrade --cve=CVE-2026-2511 -y

# What must be restarted after a library upgrade:
$ sudo dnf needs-restarting -r
Core libraries or services have been updated since boot-up:
  * openssl

Reboot is required to fully utilize these updates.
More information: https://access.redhat.com/solutions/27943

$ sudo dnf needs-restarting -s
systemd-journald.service
sshd.service
nginx.service
```

### 4.6 Querying: `dnf repoquery` and `dnf provides`

`rpm -q` only sees what is installed. `dnf repoquery` queries repository metadata — installed or not — and is the tool for impact analysis.

```
# Which package provides a file that is NOT installed yet?
$ dnf provides /usr/bin/htpasswd
Last metadata expiration check: 0:12:41 ago on Sun 24 Aug 2026 10:58:12 AM UTC.
httpd-tools-2.4.53-11.el9_2.5.x86_64 : Tools for use with the Apache HTTP Server
Repo        : acme-platform-appstream
Matched from:
Filename    : /usr/bin/htpasswd

# Glob works, and is the form you want when the path is uncertain:
$ dnf provides '*/kubectl'
kubernetes-client-1.29.4-1.el9.x86_64 : Kubernetes client tools
Repo        : acme-internal
Matched from:
Filename    : /usr/bin/kubectl

# Blast radius: what breaks if I remove openssl-libs?
$ dnf repoquery --installed --whatrequires 'libcrypto.so.3()(64bit)' | head
curl-7.76.1-29.el9_4.x86_64
openssh-8.7p1-38.el9.x86_64
openssh-clients-8.7p1-38.el9.x86_64
openssh-server-8.7p1-38.el9.x86_64
python3-cryptography-36.0.1-4.el9.x86_64
systemd-252-32.el9_4.7.x86_64

# Full dependency tree with resolved providers:
$ dnf repoquery --requires --resolve nginx
nginx-core-1:1.20.1-14.el9_2.1.x86_64
nginx-filesystem-1:1.20.1-14.el9_2.1.noarch
openssl-libs-1:3.0.7-27.el9_4.x86_64
pcre2-10.40-5.el9.x86_64
rocky-logos-httpd-90.15-2.el9.noarch
systemd-252-32.el9_4.7.x86_64
zlib-1.2.11-40.el9.x86_64

# Recursive closure — what a fresh install really pulls in:
$ dnf repoquery --requires --resolve --recursive nginx | wc -l
94

# Files a non-installed package would deliver:
$ dnf repoquery -l httpd-tools
/usr/bin/ab
/usr/bin/htcacheclean
/usr/bin/htdbm
/usr/bin/htdigest
/usr/bin/htpasswd
/usr/share/man/man1/ab.1.gz
...

# Every version available across repos:
$ dnf repoquery --showduplicates openssl
openssl-1:3.0.1-43.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-24.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-27.el9.x86_64          acme-platform-baseos
openssl-1:3.0.7-27.el9_4.x86_64        acme-platform-baseos

# Orphans and duplicates — the fleet hygiene pair:
$ dnf repoquery --unneeded
$ dnf repoquery --duplicates
$ dnf repoquery --extras           # installed but in NO repo => unaccounted for
acme-metrics-agent-2.4.0-1.el9.x86_64
custom-hotfix-glibc-2.34-83.el9.x86_64

# Exact download URL, for air-gapped staging:
$ dnf repoquery --location nginx
https://depot.acme.internal/pulp/content/prod/rocky/9/AppStream/x86_64/os/Packages/n/nginx-1.20.1-14.el9_2.1.x86_64.rpm

# Custom formatting for inventory pipelines:
$ dnf repoquery --qf '%{name},%{evr},%{arch},%{reponame},%{size}' --installed \
    | sort > /var/tmp/pkg-inventory.csv
```

`dnf repoquery --extras` is the single most valuable audit command on a long-lived host: it lists packages installed from a repo that no longer offers them — decommissioned vendor repos, hand-installed RPMs, and anything an incident responder dropped in during an outage and never removed.

### 4.7 `dnf history` — the transaction ledger

```
$ sudo dnf history
ID     | Command line                | Date and time    | Action(s)      | Altered
-------------------------------------------------------------------------------
    14 | upgrade --security -y       | 2026-08-24 11:41 | Upgrade        |    7
    13 | install nginx               | 2026-08-24 11:02 | Install        |    4
    12 | remove httpd                | 2026-08-24 10:55 | Removed        |    9
    11 | install httpd               | 2026-08-22 16:20 | Install        |    9
     1 | -y install @core            | 2026-08-12 09:13 | Install        |  412

$ sudo dnf history info 13
Transaction ID : 13
Begin time     : Sun 24 Aug 2026 11:02:35 AM UTC
Begin rpmdb    : 483:1e0d3a9f5c2b7d81e4a0b9c8d7e6f5a4b3c2d1e0
End time       : Sun 24 Aug 2026 11:02:41 AM UTC (6 seconds)
End rpmdb      : 487:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c
User           : Ops Engineer <opseng>
Return-Code    : Success
Releasever     : 9
Command Line   : install nginx
Comment        : CHG-2026-08-1187 web tier rollout
Packages Altered:
    Install nginx-1:1.20.1-14.el9_2.1.x86_64            @acme-platform-appstream
    Install nginx-core-1:1.20.1-14.el9_2.1.x86_64       @acme-platform-appstream
    Install nginx-filesystem-1:1.20.1-14.el9_2.1.noarch @acme-platform-appstream
    Install rocky-logos-httpd-90.15-2.el9.noarch        @acme-platform-baseos

# Roll a bad transaction back:
$ sudo dnf history undo 14
Dependencies resolved.
================================================================================
 Package        Arch     Version                Repository               Size
================================================================================
Downgrading:
 openssl        x86_64   1:3.0.7-27.el9         acme-platform-baseos    1.2 M
 openssl-libs   x86_64   1:3.0.7-27.el9         acme-platform-baseos    2.1 M
...
Transaction Summary
================================================================================
Downgrade  7 Packages
Is which ok [y/N]:

# Return to the exact state after transaction 12 (replays 13, 14 in reverse):
$ sudo dnf history rollback 12

# Which packages did a human explicitly ask for?  (vs pulled as dependencies)
$ sudo dnf history userinstalled | head
acme-metrics-agent
bash
dnf
nginx
openssh-server
systemd

# Tie every transaction to a change ticket:
$ sudo dnf install -y --comment "CHG-2026-08-1187 web tier rollout" nginx
```

**Limits of `undo` — know them before you rely on it:** it reverses *package state*, not side effects. Data written by `%post` scriptlets, database schema migrations run by a service on first start, and config files rewritten in place are not reverted. `%config(noreplace)` files left as `.rpmnew` stay as `.rpmnew`. For anything with a stateful side effect, the rollback plan is a snapshot (LVM/Btrfs/`snapper`) or a rebuilt node — not `dnf history undo`.

### 4.8 Modularity (EL8/EL9 AppStream)

```
$ dnf module list nodejs
Name     Stream  Profiles                        Summary
nodejs   18      common [d], development, minimal, s2i   Javascript runtime
nodejs   20 [e]  common [d] [i], development, minimal, s2i  Javascript runtime
nodejs   22      common [d], development, minimal, s2i   Javascript runtime

Hint: [d]efault, [e]nabled, [x]disabled, [i]nstalled

$ sudo dnf module enable nodejs:20 -y
$ sudo dnf module install nodejs:20/common -y
$ sudo dnf module reset nodejs          # clear the stream choice before switching
```

A module stream is a **sticky global constraint** on the whole system, not a per-package choice. Enabling `nodejs:20` prevents `nodejs:22` packages from ever being solvable until you `reset`. A third-party repo shipping non-modular `nodejs` will be filtered out entirely unless that repo sets `module_hotfixes=1`. This is the origin of the classic "the package is in the repo, `dnf repolist` shows it, but `dnf install` says No match" report on EL8.

---

## 5. `zypper` — the SUSE resolver

Same `librpm` at Layer 1, same `libsolv` SAT solver, different Layer 2 (`libzypp`) and a materially different update philosophy.

```
$ zypper --version
zypper 1.14.68

$ zypper lr -uEP
Repository priorities in ascending order:
 (98) repo-oss, repo-non-oss   (90) acme-internal   (99) repo-update

# | Alias          | Name                    | Enabled | GPG Check | Refresh | Priority | URI
--+----------------+-------------------------+---------+-----------+---------+----------+----------------------------------------------
1 | acme-internal  | ACME Internal Packages  | Yes     | ( p) Yes  | Yes     |    90    | https://depot.acme.internal/suse/15.6/x86_64/
2 | repo-oss       | Main Repository         | Yes     | (r ) Yes  | Yes     |    98    | http://download.opensuse.org/distribution/leap/15.6/repo/oss/
3 | repo-update    | Main Update Repository  | Yes     | (r ) Yes  | Yes     |    99    | http://download.opensuse.org/update/leap/15.6/oss/
```

The GPG Check column reads `(r )` = repo metadata signature verified, `( p)` = package signatures verified, `(rp)` = both. **In zypper, lower priority number wins** — the inverse of nothing, the same as dnf, but the default is 99 and admins routinely get the direction backwards.

```
# Repository management
$ sudo zypper ar -f -p 90 -n "ACME Internal" \
      https://depot.acme.internal/suse/15.6/x86_64/ acme-internal
$ sudo zypper mr -p 95 acme-internal        # modify priority
$ sudo zypper mr --disable repo-non-oss
$ sudo zypper rr repo-debug                 # remove repo
$ sudo zypper ref                           # refresh metadata
$ sudo zypper ref -f acme-internal          # force full refresh, ignore cache
$ sudo zypper clean -a                      # purge metadata + package cache

# Search and inspect
$ zypper se -s nginx
Loading repository data...
Reading installed packages...

S | Name          | Type    | Version         | Arch   | Repository
--+---------------+---------+-----------------+--------+-------------
i+| nginx         | package | 1.21.6-150600.1 | x86_64 | repo-oss
  | nginx-source  | package | 1.21.6-150600.1 | x86_64 | repo-oss

$ zypper if nginx
Information for package nginx:
------------------------------
Repository     : repo-oss
Name           : nginx
Version        : 1.21.6-150600.1.5
Arch           : x86_64
Vendor         : openSUSE
Installed Size : 1.2 MiB
Installed      : Yes
Status         : up-to-date
Source package : nginx-1.21.6-150600.1.5.src
Summary        : A HTTP server and IMAP/POP3 proxy server
Description    :
    nginx [engine x] is a HTTP server and IMAP/POP3 proxy server ...

# The two file-ownership answers the objective asks for:
$ zypper se --provides --match-exact /usr/sbin/nginx
$ zypper wp /usr/bin/htpasswd
Loading repository data...
Reading installed packages...

S | Name           | Type    | Version              | Arch   | Repository
--+----------------+---------+----------------------+--------+-----------
  | apache2-utils  | package | 2.4.58-150600.3.3    | x86_64 | repo-oss

# Install / remove / update
$ sudo zypper -n in nginx                   # -n == --non-interactive
$ sudo zypper in --oldpackage nginx-1.21.6-150600.1.4
$ sudo zypper rm --clean-deps nginx
$ sudo zypper in -f nginx                   # force reinstall of the same version
$ sudo zypper source-install nginx          # fetch the SRPM + build deps
```

### 5.1 `up` vs `dup` vs `patch` — the distinction that defines SUSE operations

| Command | Scope | Vendor change | Package removal | Correct use |
|---|---|---|---|---|
| `zypper up` | upgrade installed packages to the newest version **in the same repos** | not allowed | never removes | routine patching within a service pack |
| `zypper patch` | apply only packages named by **patch (errata) metadata** | not allowed | never | compliance-driven security patching |
| `zypper dup` (`dist-upgrade`) | make the system match the enabled repos **exactly** | allowed (`--allow-vendor-change`) | **yes, will remove** | service-pack migration, Tumbleweed rolling |

```
$ sudo zypper lp                              # list-patches
Repository        | Name              | Category | Severity  | Interactive | Status
------------------+-------------------+----------+-----------+-------------+-------
repo-update       | openSUSE-2026-891 | security | important | ---         | needed
repo-update       | openSUSE-2026-902 | security | critical  | reboot      | needed

$ sudo zypper patch --category security --severity critical -y

$ sudo zypper lp --cve
Issue | No.            | Patch            | Category | Severity | Status
------+----------------+------------------+----------+----------+-------
cve   | CVE-2026-2511  | openSUSE-2026-891| security | important| needed

$ sudo zypper patch --cve=CVE-2026-2511

# Running dup by accident is how a Leap host becomes a Tumbleweed host.
$ sudo zypper --non-interactive dup --no-allow-vendor-change
```

`zypper dup` on a system with an extra third-party repo will *downgrade or remove* vendor packages to make the system match. On Tumbleweed it is the only correct update command; on Leap/SLE it is a service-pack migration operation. Never put `zypper dup` in a cron job on an enterprise SLE host.

### 5.2 zypper-only capabilities worth stealing conceptually

```
# Which running processes use deleted files (post-upgrade restart list)?
$ sudo zypper ps -s
The following running processes use deleted files:

PID   | PPID | UID | User    | Command       | Service
------+------+-----+---------+---------------+----------
1247  | 1    | 0   | root    | nginx         | nginx
1382  | 1    | 0   | root    | sshd          | sshd

You may wish to restart these processes.

# Is my installed stack still within its supported lifecycle?
$ sudo zypper lifecycle
Product end of support
Codestream: openSUSE Leap 15               2026-12-31
    Product: openSUSE Leap 15.6            2026-12-31

Package end of support if different from product:
nodejs18: Now, installed 18.20.4, update available 20.15.1

# Version locks (equivalent of dnf versionlock)
$ sudo zypper al nginx
$ zypper ll
# | Name  | Type    | Repository | Comment
--+-------+---------+------------+--------
1 | nginx | package | (any)      |
$ sudo zypper rl nginx

# Version comparison, exposed as a first-class command:
$ zypper vcmp 1.21.6-150600.1.5 1.21.6-150600.1.4
1.21.6-150600.1.5 is newer than 1.21.6-150600.1.4

# Solver debugging — force a specific resolution branch:
$ sudo zypper in --force-resolution --solver-focus Update nginx
$ sudo zypper in --dry-run --details nginx
```

### 5.3 Cross-tool command translation table

| Task | `rpm` | `dnf` / `yum` | `zypper` |
|---|---|---|---|
| Install from repo | — | `dnf install foo` | `zypper in foo` |
| Install local file | `rpm -ivh f.rpm` | `dnf install ./f.rpm` | `zypper in ./f.rpm` |
| Upgrade one package | `rpm -Uvh f.rpm` | `dnf upgrade foo` | `zypper up foo` |
| Upgrade everything | — | `dnf upgrade` | `zypper up` |
| Distribution upgrade | — | `dnf distro-sync` | `zypper dup` |
| Security-only patch | — | `dnf upgrade --security` | `zypper patch --category security` |
| Reinstall | `rpm -ivh --replacepkgs` | `dnf reinstall foo` | `zypper in -f foo` |
| Downgrade | `rpm -Uvh --oldpackage` | `dnf downgrade foo` | `zypper in --oldpackage foo-1.2` |
| Remove | `rpm -e foo` | `dnf remove foo` | `zypper rm foo` |
| Remove + orphans | — | `dnf remove foo` (default) | `zypper rm --clean-deps foo` |
| List installed | `rpm -qa` | `dnf list --installed` | `zypper se -i` |
| Package info | `rpm -qi foo` | `dnf info foo` | `zypper info foo` |
| Files in installed pkg | `rpm -ql foo` | `dnf repoquery -l foo` | `rpm -ql foo` |
| Files in a `.rpm` file | `rpm -qlp f.rpm` | — | — |
| Owner of a file | `rpm -qf /path` | `dnf provides /path` | `zypper se --provides /path` |
| Provider of a file (not installed) | — | `dnf provides '*/bin/foo'` | `zypper wp /bin/foo` |
| Dependencies | `rpm -qR foo` | `dnf repoquery --requires --resolve foo` | `zypper info --requires foo` |
| Reverse dependencies | `rpm -q --whatrequires cap` | `dnf repoquery --whatrequires cap` | `zypper se --requires cap` |
| Verify files | `rpm -V foo` | `dnf reinstall foo` (repair) | `rpm -V foo` |
| Verify dep integrity | `rpm -Va --nofiles` | `dnf check` | `zypper verify` |
| Check signature | `rpm -K f.rpm` | `dnf install` (gpgcheck) | `zypper in` (gpgcheck) |
| Import key | `rpm --import KEY` | `rpm --import KEY` | `rpm --import KEY` |
| List repos | — | `dnf repolist -v` | `zypper lr -u` |
| Refresh metadata | — | `dnf makecache` | `zypper ref` |
| Clean cache | — | `dnf clean all` | `zypper clean -a` |
| History | `rpm -qa --last` | `dnf history` | `/var/log/zypp/history` |
| Rollback | — | `dnf history undo N` | `snapper rollback` |
| Extract without installing | `rpm2cpio f.rpm \| cpio -idmv` | — | — |

---

## 6. Complete production manifests

### 6.1 RPM spec file — a fully valid, modern service package

```spec
# acme-metrics-agent.spec
# Builds with: rpmbuild -ba acme-metrics-agent.spec
# Lints  with: rpmlint acme-metrics-agent.spec

Name:           acme-metrics-agent
Version:        2.5.0
Release:        1%{?dist}
Summary:        ACME fleet metrics collection agent

License:        Apache-2.0
URL:            https://git.acme.internal/platform/metrics-agent
Source0:        %{url}/-/archive/v%{version}/metrics-agent-v%{version}.tar.gz
Source1:        %{name}.service
Source2:        %{name}.sysusers
Source3:        %{name}.yaml
Source4:        %{name}.logrotate

BuildRequires:  golang >= 1.21
BuildRequires:  systemd-rpm-macros
BuildRequires:  systemd-devel
BuildRequires:  make
BuildRequires:  git-core

# Auto-generated soname deps cover the shared libraries; these are the
# capabilities the auto-generator cannot see.
Requires:       systemd
Requires(pre):  shadow-utils
Recommends:     logrotate
# Boolean dependency (rpm >= 4.13): only pull the SELinux policy on a system
# that actually enforces SELinux.
Requires:       (%{name}-selinux if selinux-policy-targeted)
# This package supersedes the retired collector. Bounded, so a future rebuild
# of legacy-collector 3.x is not silently eaten.
Obsoletes:      legacy-collector < 3.0
Provides:       fleet-metrics-collector = %{version}-%{release}

%description
acme-metrics-agent collects host, container and systemd unit metrics and
exposes them on a local Prometheus scrape endpoint. It runs as an unprivileged
system user under a hardened systemd unit with a read-only root filesystem and
a restricted system call filter.

Configuration lives in %{_sysconfdir}/acme/metrics-agent.yaml and is marked
%%config(noreplace): local edits survive upgrades, and the packaged version is
written alongside as .rpmnew when it changes.

%package selinux
Summary:        SELinux policy module for %{name}
BuildArch:      noarch
Requires:       selinux-policy-targeted
Requires(post): policycoreutils
BuildRequires:  selinux-policy-devel

%description selinux
SELinux policy module confining %{name} to its own domain.

%prep
%autosetup -n metrics-agent-v%{version}

%build
export CGO_ENABLED=1
export GOFLAGS="-trimpath -mod=vendor"
go build \
    -ldflags "-X main.version=%{version}-%{release} -linkmode=external" \
    -o %{name} ./cmd/agent

%install
install -Dpm 0755 %{name}                %{buildroot}%{_bindir}/%{name}
install -Dpm 0644 %{SOURCE1}             %{buildroot}%{_unitdir}/%{name}.service
install -Dpm 0644 %{SOURCE2}             %{buildroot}%{_sysusersdir}/%{name}.conf
install -Dpm 0640 %{SOURCE3}             %{buildroot}%{_sysconfdir}/acme/metrics-agent.yaml
install -Dpm 0644 %{SOURCE4}             %{buildroot}%{_sysconfdir}/logrotate.d/%{name}

install -dm 0750 %{buildroot}%{_localstatedir}/log/acme
install -dm 0750 %{buildroot}%{_sharedstatedir}/acme-metrics-agent

# %ghost: the file is OWNED by the package (so `rpm -qf` answers, and removal
# cleans it up) but is NOT shipped in the payload — it is created at runtime.
touch %{buildroot}%{_localstatedir}/log/acme/agent.log

%check
go test ./... -count=1

%pre
# Fallback for systems without systemd-sysusers; on modern systems the
# sysusers.d file is processed by %sysusers_create_compat below.
getent group acme-metrics >/dev/null || groupadd -r acme-metrics
getent passwd acme-metrics >/dev/null || \
    useradd -r -g acme-metrics -d %{_sharedstatedir}/acme-metrics-agent \
            -s /sbin/nologin -c "ACME metrics agent" acme-metrics
exit 0

%post
%sysusers_create_compat %{SOURCE2}
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
# Restart the running daemon on upgrade ($1 >= 1); do nothing on final erase.
%systemd_postun_with_restart %{name}.service

%posttrans
# Runs once, after every package in the transaction is installed.
if [ -x %{_bindir}/systemctl ]; then
    %{_bindir}/systemctl daemon-reload >/dev/null 2>&1 || :
fi

%post selinux
semodule -n -i %{_datadir}/selinux/packages/%{name}/%{name}.pp.bz2
if selinuxenabled; then
    load_policy
    restorecon -R %{_bindir}/%{name} %{_localstatedir}/log/acme || :
fi

%files
%license LICENSE
%doc README.md docs/OPERATIONS.md
%{_bindir}/%{name}
%{_unitdir}/%{name}.service
%{_sysusersdir}/%{name}.conf
%dir %attr(0750,root,acme-metrics) %{_sysconfdir}/acme
%config(noreplace) %attr(0640,root,acme-metrics) %{_sysconfdir}/acme/metrics-agent.yaml
%config(noreplace) %{_sysconfdir}/logrotate.d/%{name}
%dir %attr(0750,acme-metrics,acme-metrics) %{_localstatedir}/log/acme
%dir %attr(0750,acme-metrics,acme-metrics) %{_sharedstatedir}/acme-metrics-agent
%ghost %attr(0640,acme-metrics,acme-metrics) %{_localstatedir}/log/acme/agent.log

%files selinux
%{_datadir}/selinux/packages/%{name}/%{name}.pp.bz2

%changelog
* Sun Aug 24 2026 ACME Platform <platform@acme.internal> - 2.5.0-1
- Rebase to upstream 2.5.0
- Fix CVE-2026-2511: unauthenticated read of the local scrape endpoint
- Add %%ghost ownership for /var/log/acme/agent.log so removal cleans up

* Wed Aug 12 2026 ACME Platform <platform@acme.internal> - 2.4.0-1
- Initial packaging, replaces legacy-collector
```

`%config` vs `%config(noreplace)` decides what happens to an admin-edited file on upgrade:

| Marking | File unmodified on disk | File modified on disk |
|---|---|---|
| `%config` | replaced silently | old saved as `.rpmsave`, **new file installed** |
| `%config(noreplace)` | replaced silently | **your file kept**, new one written as `.rpmnew` |
| not marked | replaced silently | **replaced silently — your edits are gone** |

Always use `%config(noreplace)` for anything an operator touches, and always audit the leftovers:

```
$ find /etc -name '*.rpmnew' -o -name '*.rpmsave' -o -name '*.rpmorig' 2>/dev/null
/etc/ssh/sshd_config.rpmnew
/etc/nginx/nginx.conf.rpmnew

$ sudo dnf install -y rpmconf && sudo rpmconf -a
```

### 6.2 Ansible — fleet-wide repository and patching policy

```yaml
---
# roles/rpm_baseline/tasks/main.yml
# Applies the ACME package-management baseline to every EL9 node.
# Idempotent, check-mode safe, and fails loudly on an unreachable depot.

- name: Assert supported platform
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] == 'RedHat'
      - ansible_facts['distribution_major_version'] is version('9', '>=')
    fail_msg: "rpm_baseline supports EL9+ only; found {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }}"

- name: Install GPG public keys before any repository is defined
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/pki/rpm-gpg/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - RPM-GPG-KEY-ACME-Platform
    - RPM-GPG-KEY-Rocky-9
    - RPM-GPG-KEY-VENDOR-OBS
  tags: [rpm, keys]

- name: Import GPG keys into the rpm trust store
  ansible.builtin.rpm_key:
    key: "/etc/pki/rpm-gpg/{{ item }}"
    state: present
  loop:
    - RPM-GPG-KEY-ACME-Platform
    - RPM-GPG-KEY-Rocky-9
    - RPM-GPG-KEY-VENDOR-OBS
  tags: [rpm, keys]

- name: Define the dnf environment variable used in repo URLs
  ansible.builtin.copy:
    content: "{{ acme_env }}\n"
    dest: /etc/dnf/vars/acmeenv
    owner: root
    group: root
    mode: "0644"
  tags: [rpm, repos]

- name: Remove any repository not declared in this role
  ansible.builtin.file:
    path: "/etc/yum.repos.d/{{ item }}"
    state: absent
  loop: "{{ discovered_repo_files.files | map(attribute='path') | map('basename') | reject('in', acme_managed_repo_files) | list }}"
  vars:
    acme_managed_repo_files:
      - acme-platform.repo
  tags: [rpm, repos]

- name: Deploy the managed repository definition
  ansible.builtin.template:
    src: acme-platform.repo.j2
    dest: /etc/yum.repos.d/acme-platform.repo
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/python3 -c \"import configparser,sys; configparser.ConfigParser().read('%s')\""
  notify: Rebuild dnf metadata cache
  tags: [rpm, repos]

- name: Deploy the dnf main configuration
  ansible.builtin.template:
    src: dnf.conf.j2
    dest: /etc/dnf/dnf.conf
    owner: root
    group: root
    mode: "0644"
    backup: true
  tags: [rpm, config]

- name: Verify every configured repository is actually reachable
  ansible.builtin.command:
    cmd: dnf --refresh repolist --assumeno
  register: repolist_check
  changed_when: false
  failed_when: repolist_check.rc != 0
  check_mode: false
  tags: [rpm, verify]

- name: Install the baseline package set
  ansible.builtin.dnf:
    name: "{{ acme_baseline_packages }}"
    state: present
    disable_gpg_check: false
    install_weak_deps: false
  register: baseline_install
  retries: 3
  delay: 15
  until: baseline_install is succeeded
  tags: [rpm, packages]

- name: Pin packages that must not move outside a change window
  ansible.builtin.dnf:
    name: python3-dnf-plugin-versionlock
    state: present
  tags: [rpm, versionlock]

- name: Apply version locks
  ansible.builtin.command:
    cmd: "dnf versionlock add {{ item }}"
  loop: "{{ acme_versionlocked_packages }}"
  register: vlock
  changed_when: "'Adding versionlock on' in vlock.stdout"
  tags: [rpm, versionlock]

- name: Apply security errata only
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
    bugfix: false
    exclude: "{{ acme_patch_exclusions }}"
  register: security_patch
  when: acme_apply_security_patches | bool
  tags: [rpm, patch]

- name: Determine whether a reboot is required
  ansible.builtin.command:
    cmd: dnf needs-restarting -r
  register: needs_reboot
  changed_when: false
  failed_when: needs_reboot.rc not in [0, 1]
  tags: [rpm, patch]

- name: Report packages installed from no known repository
  ansible.builtin.command:
    cmd: dnf repoquery --extras --qf '%{name}-%{evr}.%{arch}'
  register: extras
  changed_when: false
  tags: [rpm, audit]

- name: Fail the audit if unaccounted packages exist on a production node
  ansible.builtin.fail:
    msg: |
      Unaccounted packages present (installed but in no enabled repository):
      {{ extras.stdout_lines | join('\n') }}
  when:
    - acme_env == 'prod'
    - extras.stdout_lines | length > 0
    - extras.stdout_lines | reject('match', acme_extras_allowlist_regex) | list | length > 0
  tags: [rpm, audit]

- name: Run a full package verification and surface content-level drift
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5' || true
    executable: /bin/bash
  register: rpm_verify
  changed_when: false
  tags: [rpm, audit]

- name: Emit a drift warning for modified package content
  ansible.builtin.debug:
    msg: "PACKAGE CONTENT DRIFT on {{ inventory_hostname }}:\n{{ rpm_verify.stdout }}"
  when: rpm_verify.stdout | length > 0
  tags: [rpm, audit]
```

```yaml
---
# roles/rpm_baseline/defaults/main.yml
acme_env: prod
acme_apply_security_patches: true

acme_baseline_packages:
  - dnf-plugins-core
  - dnf-utils
  - createrepo_c
  - rpm-sign
  - yum-utils
  - acme-metrics-agent

# Kernels and the container runtime move only in a dedicated window.
acme_versionlocked_packages:
  - kernel-core-5.14.0-427.28.1.el9_4
  - containerd.io-1.7.18-3.1.el9

acme_patch_exclusions:
  - kernel*
  - kmod-*
  - containerd.io

# Packages legitimately installed outside the repos (build artefacts staged
# by CI). Anything else failing --extras is an incident.
acme_extras_allowlist_regex: '^(acme-ci-scratch|gpg-pubkey)'
```

```yaml
---
# roles/rpm_baseline/handlers/main.yml
- name: Rebuild dnf metadata cache
  ansible.builtin.command:
    cmd: dnf clean metadata && dnf makecache --refresh
  changed_when: true
```

### 6.3 `dnf-automatic` — unattended security patching

```ini
# /etc/dnf/automatic.conf
# Enabled with: systemctl enable --now dnf-automatic.timer
#
# Three unit variants ship; only ONE may be enabled:
#   dnf-automatic-notifyonly.timer  -> download_updates=no,  apply_updates=no
#   dnf-automatic-download.timer    -> download_updates=yes, apply_updates=no
#   dnf-automatic-install.timer     -> download_updates=yes, apply_updates=yes
# dnf-automatic.timer honours the settings in THIS file.

[commands]
upgrade_type = security       # security | default
random_sleep = 900            # jitter, so 4,000 nodes do not hit the depot at once
network_online_timeout = 300
download_updates = yes
apply_updates = yes           # 'no' on stateful tiers: download only, apply in a window
reboot = when-needed          # never | when-changed | when-needed
reboot_command = "shutdown -r +5 'Rebooting after applying package updates'"

[emitters]
emit_via = motd, stdio        # stdio -> captured by journald -> shipped to Loki
system_name = None

[email]
email_from = dnf-automatic@acme.internal
email_to = platform-oncall@acme.internal
email_host = smtp.acme.internal

[base]
debuglevel = 1
assumeyes = True
```

```
$ sudo systemctl enable --now dnf-automatic.timer
Created symlink /etc/systemd/system/timers.target.wants/dnf-automatic.timer → /usr/lib/systemd/system/dnf-automatic.timer.

$ systemctl list-timers dnf-automatic.timer
NEXT                         LEFT     LAST                         PASSED  UNIT                ACTIVATES
Mon 2026-08-25 06:00:00 UTC  18h left Sun 2026-08-24 06:00:00 UTC  5h ago  dnf-automatic.timer dnf-automatic.service

$ journalctl -u dnf-automatic.service -n 20 --no-pager
Aug 24 06:14:52 web-01 dnf-automatic[2841]: Updates applied on 'web-01.acme.internal':
Aug 24 06:14:52 web-01 dnf-automatic[2841]:  openssl-1:3.0.7-27.el9_4.x86_64
Aug 24 06:14:52 web-01 dnf-automatic[2841]:  openssl-libs-1:3.0.7-27.el9_4.x86_64
```

| Strategy | Blast radius | Rollback | Use where |
|---|---|---|---|
| `dnf-automatic` `apply_updates=yes` | one node at a time, uncoordinated | `dnf history undo` | stateless web/worker tiers |
| `dnf-automatic` download-only + windowed apply | controlled | `dnf history undo` | databases, stateful services |
| Config-mgmt push (Ansible/Puppet) | orchestrated, canary-able | re-run with pinned NEVRA | most enterprise fleets |
| Image rebuild (bootc / rpm-ostree) | none at runtime | reboot into previous deployment | immutable / edge fleets |

The image-based option deserves the architect's attention: `rpm-ostree`/`bootc` moves the transaction from the running host to the build pipeline. The node never runs a solver; it pulls a pre-composed, signed image and atomically switches into it, with the previous deployment retained for `rpm-ostree rollback`. You trade in-place flexibility for a guarantee that every node in a tier is byte-identical — the property `rpm -Va` was invented to approximate.

### 6.4 Container image build — reproducible and minimal

```dockerfile
# Containerfile
# Build: podman build --pull=always -t registry.acme.internal/platform/metrics-agent:2.5.0 .
#
# Reproducibility rules enforced here:
#   1. Pin the base image by DIGEST, never by tag.
#   2. Pin every package to a full NEVRA.
#   3. Point at a frozen content view, not a rolling mirror.
#   4. Verify signatures inside the build; do not disable gpgcheck.

FROM registry.access.redhat.com/ubi9/ubi-minimal@sha256:c3d3f8a3a5c9d3b2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8 AS build

ARG ACME_CONTENT_VIEW=2026-08-24
ARG AGENT_NEVRA=acme-metrics-agent-2.5.0-1.el9.x86_64

COPY acme-platform.repo /etc/yum.repos.d/acme-platform.repo
COPY RPM-GPG-KEY-ACME-Platform /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform

RUN set -eux; \
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform; \
    sed -i "s/@@CONTENT_VIEW@@/${ACME_CONTENT_VIEW}/g" /etc/yum.repos.d/acme-platform.repo; \
    microdnf install -y \
        --setopt=install_weak_deps=0 \
        --setopt=tsflags=nodocs \
        --setopt=gpgcheck=1 \
        --setopt=best=1 \
        --setopt=skip_if_unavailable=0 \
        --setopt=metadata_expire=never \
        --nodocs \
        "${AGENT_NEVRA}" \
        ca-certificates; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum /var/lib/dnf/history*; \
    # Prove what was installed and freeze it into the image as a manifest.
    rpm -qa --qf '%{NEVRA}\t%{SIGPGP:pgpsig}\n' | sort > /usr/share/acme-image-manifest.tsv; \
    # Fail the build if ANY installed package is unsigned.
    if rpm -qa --qf '%{NAME} %{SIGPGP:pgpsig}\n' | grep -v '^gpg-pubkey ' | grep -q '(none)'; then \
        echo "FATAL: unsigned package present in image" >&2; exit 1; \
    fi

FROM registry.access.redhat.com/ubi9/ubi-micro@sha256:9a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9

COPY --from=build /usr/bin/acme-metrics-agent            /usr/bin/acme-metrics-agent
COPY --from=build /etc/acme/metrics-agent.yaml           /etc/acme/metrics-agent.yaml
COPY --from=build /usr/share/acme-image-manifest.tsv     /usr/share/acme-image-manifest.tsv
COPY --from=build /etc/pki/ca-trust/extracted            /etc/pki/ca-trust/extracted

USER 65534:65534
EXPOSE 9100
ENTRYPOINT ["/usr/bin/acme-metrics-agent"]
CMD ["--config", "/etc/acme/metrics-agent.yaml"]
```

### 6.5 CI pipeline — build, sign, verify, publish

```yaml
# .gitlab-ci.yml
# Builds an RPM, signs it with the platform key, verifies the signature is
# actually trusted, publishes to Pulp, and regenerates repository metadata.

stages: [build, sign, verify, publish]

variables:
  RPM_TOPDIR: "$CI_PROJECT_DIR/rpmbuild"
  GPG_KEY_NAME: "ACME Platform Signing Key <platform@acme.internal>"
  DEPOT_URL: "https://depot.acme.internal"

.el9: &el9
  image: registry.acme.internal/ci/rpmbuild-el9:latest
  tags: [linux, x86_64]

build:rpm:
  <<: *el9
  stage: build
  script:
    - set -euo pipefail
    - mkdir -p "$RPM_TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    - cp packaging/*.spec "$RPM_TOPDIR/SPECS/"
    - cp packaging/sources/* "$RPM_TOPDIR/SOURCES/"
    - spectool -g -R --define "_topdir $RPM_TOPDIR" "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    # Install BuildRequires from the spec, resolved by dnf — never hand-maintained.
    - dnf builddep -y "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - rpmlint "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - rpmbuild --define "_topdir $RPM_TOPDIR"
               --define "dist .el9"
               -ba "$RPM_TOPDIR/SPECS/acme-metrics-agent.spec"
    - find "$RPM_TOPDIR/RPMS" "$RPM_TOPDIR/SRPMS" -name '*.rpm' -print
  artifacts:
    paths: ["rpmbuild/RPMS/", "rpmbuild/SRPMS/"]
    expire_in: 7 days

sign:rpm:
  <<: *el9
  stage: sign
  needs: ["build:rpm"]
  script:
    - set -euo pipefail
    - echo "$GPG_PRIVATE_KEY" | gpg --batch --import
    - |
      cat > "$HOME/.rpmmacros" <<EOF
      %_gpg_name ${GPG_KEY_NAME}
      %_gpg_digest_algo sha256
      %__gpg_sign_cmd %{__gpg} gpg --batch --pinentry-mode loopback \\
          --passphrase-file /run/secrets/gpg-pass --no-armor \\
          --no-secmem-warning -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
      EOF
    - find rpmbuild/RPMS rpmbuild/SRPMS -name '*.rpm' -exec rpmsign --addsign {} +
  artifacts:
    paths: ["rpmbuild/RPMS/", "rpmbuild/SRPMS/"]

verify:signature:
  <<: *el9
  stage: verify
  needs: ["sign:rpm"]
  script:
    - set -euo pipefail
    - rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform
    - |
      fail=0
      while IFS= read -r pkg; do
        out="$(rpm -K "$pkg")"
        echo "$out"
        # Match the exact success string. "digests OK" alone means UNSIGNED.
        case "$out" in
          *": digests signatures OK") : ;;
          *) echo "FATAL: $pkg is not correctly signed" >&2; fail=1 ;;
        esac
      done < <(find rpmbuild/RPMS -name '*.rpm')
      exit "$fail"
    # Structural sanity: the payload must contain the files the spec promised.
    - rpm -qlp rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm | grep -qx /usr/bin/acme-metrics-agent
    - rpm -qp --requires rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm
    - rpm -qp --scripts  rpmbuild/RPMS/x86_64/acme-metrics-agent-*.rpm

publish:pulp:
  <<: *el9
  stage: publish
  needs: ["verify:signature"]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  script:
    - set -euo pipefail
    - |
      for pkg in $(find rpmbuild/RPMS -name '*.rpm'); do
        pulp rpm content upload --file "$pkg" --repository acme-internal
      done
    - pulp rpm repository version --repository acme-internal list --limit 1
    - pulp rpm publication create --repository acme-internal
    - pulp rpm distribution update --name acme-internal-prod \
        --publication "$(pulp rpm publication list --limit 1 --field pulp_href -o json | jq -r '.[0].pulp_href')"
    # Independent post-publish check from a client's point of view.
    - dnf --disablerepo='*' --enablerepo=acme-internal --refresh \
        repoquery --qf '%{nevra}' acme-metrics-agent
```

### 6.6 Standing up a local repository by hand

```
$ sudo mkdir -p /srv/repo/acme-internal/9/x86_64/Packages
$ sudo cp *.rpm /srv/repo/acme-internal/9/x86_64/Packages/

$ sudo createrepo_c --update --database --workers 4 \
      --checksum sha256 /srv/repo/acme-internal/9/x86_64/
Directory walk started
Directory walk done - 47 packages
Temporary output repo path: /srv/repo/acme-internal/9/x86_64/.repodata/
Preparing sqlite DBs
Pool started (with 4 workers)
Pool finished

# Attach errata metadata — WITHOUT this, `dnf upgrade --security` is a no-op.
$ sudo modifyrepo_c updateinfo.xml /srv/repo/acme-internal/9/x86_64/repodata/

# Sign the metadata root, so repo_gpgcheck=1 clients can verify it.
$ sudo gpg --detach-sign --armor \
      --local-user "ACME Platform Signing Key" \
      /srv/repo/acme-internal/9/x86_64/repodata/repomd.xml

$ ls /srv/repo/acme-internal/9/x86_64/repodata/repomd.xml*
repomd.xml  repomd.xml.asc

# Mirror an upstream repo for an air-gapped estate, metadata included:
$ sudo dnf reposync --repoid=acme-platform-baseos \
      --download-metadata --newest-only --delete \
      --downloadcomps --remote-time \
      -p /srv/mirror/rocky/9/

# Client-side smoke test before rolling to the fleet:
$ dnf --disablerepo='*' --enablerepo=acme-internal --refresh repolist -v
```

| Repository backend | Metadata signing | Lifecycle promotion | Retention/GC | Operational cost |
|---|---|---|---|---|
| `createrepo_c` + nginx | manual `gpg --detach-sign` | rsync between directories | manual | lowest; fine ≤ ~50 nodes |
| Pulp 3 | built-in | repository versions + distributions | automatic orphan cleanup | medium; API-driven, the sweet spot |
| Katello / Satellite | built-in | content views + lifecycle envs | built-in | high; adds host registration and errata reporting |
| Artifactory / Nexus | built-in | repo promotion | policy-based | high; justified when you already run it for other formats |

The property that matters more than any feature: **can you re-materialise the exact package set from six months ago?** A plain `createrepo_c` mirror with `--delete` cannot. Pulp repository versions and Katello content views can, and that is what makes a build from an old tag reproducible.

### 6.7 Kickstart — package selection at provisioning time

```
# ks-el9-minimal.cfg  (excerpt)
url --url="https://depot.acme.internal/pulp/content/prod/rocky/9/BaseOS/x86_64/os/"

repo --name="appstream" \
     --baseurl="https://depot.acme.internal/pulp/content/prod/rocky/9/AppStream/x86_64/os/" \
     --install
repo --name="acme-internal" \
     --baseurl="https://depot.acme.internal/pulp/content/prod/acme-internal/9/x86_64/" \
     --install --cost=500

%packages --exclude-weakdeps --ignoremissing=no
@^minimal-environment
@core
chrony
dnf-plugins-core
openssh-server
sudo
acme-metrics-agent
-plymouth
-iwl*-firmware
-cockpit*
%end

%post --log=/root/ks-post.log
set -euxo pipefail

# Trust the platform key on first boot, before anything else runs.
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-ACME-Platform

# Prove the build produced what was asked for; halt provisioning if not.
rpm -q acme-metrics-agent chrony openssh-server
rpm -qa --qf '%{NEVRA}\n' | sort > /root/provisioned-manifest.txt

# No unsigned packages may exist on a freshly provisioned node.
if rpm -qa --qf '%{NAME} %{SIGPGP:pgpsig}\n' | grep -v '^gpg-pubkey ' | grep -q '(none)'; then
    echo "FATAL: unsigned package on a fresh install" >&2
    exit 1
fi

systemctl enable dnf-automatic.timer
%end
```

---

## 7. Verification and failure diagnosis

### 7.1 The standing verification ladder

Run these in order; each rung is cheap and each answers a different question.

```
# 1. Is the rpmdb itself consistent?
$ sudo rpmdb --verifydb
$ echo $?
0

# 2. Are there unresolved dependencies, duplicates or broken obsoletes?
$ sudo dnf check
No problems found.

# 3. Is any file drifted from what its package shipped?  (content only)
$ sudo rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5' 
..5......  c /etc/nginx/nginx.conf

# 4. Are all repositories reachable and fresh?
$ sudo dnf --refresh repolist
$ echo $?
0

# 5. Is every installed package signed by a trusted key?
$ rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' | grep -v gpg-pubkey | grep '(none)'

# 6. Is anything installed that no repository can account for?
$ dnf repoquery --extras

# 7. Are there stale kernels / orphans consuming /boot and disk?
$ dnf repoquery --unneeded
$ rpm -q kernel | wc -l

# 8. Are there unmerged config files from past upgrades?
$ find /etc -name '*.rpmnew' -o -name '*.rpmsave' 2>/dev/null

# 9. Do any running processes still map deleted libraries?
$ sudo dnf needs-restarting -s
```

Wrapped into a single audit that exits non-zero on any finding:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/pkg-audit — exits 0 only if every check is clean.
set -uo pipefail
rc=0
note() { printf '[%s] %s\n' "$1" "$2"; [ "$1" = FAIL ] && rc=1; return 0; }

rpmdb --verifydb                     >/dev/null 2>&1 \
  && note OK   "rpmdb consistent"    || note FAIL "rpmdb inconsistent — see 7.4"

dnf check                            >/dev/null 2>&1 \
  && note OK   "dependency closure"  || note FAIL "dnf check reported problems"

drift=$(rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5[^ ]*[^c]' || true)
[ -z "$drift" ] \
  && note OK   "no non-config content drift" \
  || note FAIL "content drift:"$'\n'"$drift"

unsigned=$(rpm -qa --qf '%{NAME}-%{EVR} %{SIGPGP:pgpsig}\n' \
             | grep -v '^gpg-pubkey' | grep '(none)' || true)
[ -z "$unsigned" ] \
  && note OK   "all packages signed" \
  || note FAIL "unsigned packages:"$'\n'"$unsigned"

extras=$(dnf -q repoquery --extras 2>/dev/null || true)
[ -z "$extras" ] \
  && note OK   "no unaccounted packages" \
  || note WARN "installed but in no repo:"$'\n'"$extras"

pending=$(find /etc \( -name '*.rpmnew' -o -name '*.rpmsave' \) 2>/dev/null || true)
[ -z "$pending" ] \
  && note OK   "no unmerged configs" \
  || note WARN "unmerged config files:"$'\n'"$pending"

exit "$rc"
```

```
$ sudo /usr/local/sbin/pkg-audit
[OK]   rpmdb consistent
[OK]   dependency closure
[OK]   no non-config content drift
[FAIL] unsigned packages:
acme-metrics-agent-2.5.0-1.el9 (none)
[WARN] installed but in no repo:
custom-hotfix-glibc-2.34-83.el9.x86_64
[OK]   no unmerged configs
$ echo $?
1
```

### 7.2 Failure playbook

| Symptom (verbatim) | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `Error: GPG check FAILED` | key not imported, or wrong key | `rpm -qa gpg-pubkey*`; `rpm -Kv pkg.rpm` | `rpm --import /etc/pki/rpm-gpg/KEY`; never `--nogpgcheck` |
| `Public key for X.rpm is not installed` (NOKEY) | repo's `gpgkey=` unreachable or missing | `curl -I <gpgkey URL>` | fix `gpgkey=`, or ship keys via a package |
| `repomd.xml GPG signature verification error` | `repo_gpgcheck=1` but depot does not sign metadata | `curl -sI .../repodata/repomd.xml.asc` | sign metadata at the depot, or drop `repo_gpgcheck` for that repo only |
| `Status code: 404 for .../repodata/repomd.xml` | wrong `$releasever`/`$basearch`, or repo moved | `dnf repolist -v`; `dnf --setopt=... repolist` | correct `baseurl`; `dnf clean metadata` |
| `Cannot download repomd.xml: Cannot download repodata... All mirrors were tried` | stale cache after a mirror change | `ls /var/cache/dnf` | `dnf clean all && dnf makecache` |
| `nothing provides libfoo.so.5()(64bit) needed by bar` | missing repo, or wrong arch/release | `dnf repoquery --whatprovides 'libfoo.so.5()(64bit)'` | enable the right repo; never `--nodeps` |
| `package X conflicts with Y` | two repos ship the same capability | `dnf repoquery --qf '%{name} %{reponame}' --whatprovides <cap>` | fence the third-party repo with `includepkgs`/`priority` |
| `Problem: cannot install both A and B` (libsolv) | genuine conflict | read the numbered libsolv clause list — it names the exact packages | `dnf install --allowerasing` only after understanding the trade |
| `file /usr/bin/foo conflicts between attempted installs` | two packages own one path | `rpm -qf`; `dnf repoquery --whatprovides /usr/bin/foo` | fix packaging; `--replacefiles` is a last resort |
| `error: rpmdb: BDB0113 Thread ... failed` / `cannot open Packages` | BDB rpmdb corruption (EL7/EL8) | `rpmdb --verifydb` | see §7.4 |
| `Transaction test error: installing package X needs Y MB on the /usr filesystem` | disk full | `df -h /usr /var /boot` | free space; `dnf clean packages`; `dnf remove --oldinstallonly` |
| `Depsolve Error occurred: ... but none of the providers can be installed` | module stream pinned to another version | `dnf module list <name>` | `dnf module reset <name>`, then re-solve |
| `No match for argument: <pkg>` although `dnf repolist` shows the repo | `includepkgs`/`exclude` filtering it out, or `filelists` not fetched | `dnf repoquery --disableexcludes=all <pkg>` | adjust the repo filter |
| `scriptlet failed, exit status 1` | `%post` scriptlet error | `rpm -q --scripts <pkg>`; `journalctl -t <pkg>` | package **is** recorded as installed but half-configured — fix, then `dnf reinstall` |
| Service dies after upgrade, config looks right | config replaced or `.rpmnew` ignored | `find /etc -name '*.rpmnew'`; `rpm -Vc <pkg>` | `rpmconf -a`, merge, restart |
| `dnf history undo` says `Transaction history is incomplete` | packages no longer in any repo | `dnf repoquery --showduplicates <pkg>` | restore from the depot's older content view |

### 7.3 Reading a libsolv depsolve error

```
$ sudo dnf install acme-metrics-agent-2.5.0
Last metadata expiration check: 0:01:04 ago on Sun 24 Aug 2026 12:11:03 PM UTC.
Error:
 Problem: package acme-metrics-agent-2.5.0-1.el9.x86_64 from acme-internal
          requires libsystemd.so.0(LIBSYSTEMD_252)(64bit), but none of the
          providers can be installed
  - cannot install both systemd-libs-252-32.el9_4.7.x86_64 from acme-platform-baseos
    and systemd-libs-250-12.el9_0.3.x86_64 from @System
  - problem with installed package systemd-libs-250-12.el9_0.3.x86_64
  - package systemd-libs-250-12.el9_0.3.x86_64 from @System is filtered out
    by exclude filtering
(try to add '--skip-broken' to skip uninstallable packages or '--nobest'
 to use not only best candidate packages)
```

Read it bottom-up: the terminal cause is on the **last** line. Here `systemd*` is in the `exclude=` list of `/etc/dnf/dnf.conf`, so the required `systemd-libs` upgrade cannot be selected. The fix is neither `--skip-broken` (silently installs nothing) nor `--nobest` (silently installs an older agent) — it is to lift the exclusion for this transaction, deliberately:

```
$ sudo dnf --disableexcludes=main install acme-metrics-agent-2.5.0
```

`--skip-broken` and `--nobest` are the two flags most likely to turn a loud failure into a quiet under-patched host. Treat both as incident-only tools, and never put them in automation.

### 7.4 rpmdb corruption recovery

```
$ rpm -qa
error: rpmdb: BDB0113 Thread/process 4213/140234 failed: BDB1507 Thread died in Berkeley DB library
error: db5 error(-30973) from dbenv->failchk: BDB0087 DB_RUNRECOVERY: Fatal error, run database recovery
error: cannot open Packages index using db5 - (-30973)
error: cannot open Packages database in /var/lib/rpm

# 1. Back up FIRST. Always. The rpmdb is not reconstructible from anything else.
$ sudo cp -a /var/lib/rpm /var/lib/rpm.bak-$(date +%F-%H%M)

# 2. On a BDB backend, stale environment locks alone can cause this.
$ sudo rm -f /var/lib/rpm/__db.00*
$ rpm -qa | wc -l
487                                   # if this works, you are done

# 3. Otherwise rebuild the indexes from the Packages file.
$ sudo rpm --rebuilddb -vv
D: opening  db environment /var/lib/rpm cdb:mpool
D: opening  db index       /var/lib/rpm/Packages create mode=0x42
...

$ sudo rpmdb --verifydb && rpm -qa | wc -l
487

# 4. Migrate to sqlite so this class of failure cannot recur (EL9+ / Fedora):
$ sudo rpmdb --rebuilddb --define '_db_backend sqlite'
$ rpm --eval '%{_db_backend}'
sqlite

# 5. If Packages itself is destroyed, the DB is unrecoverable in place.
#    Rebuild the host, or reconstruct from an inventory snapshot:
$ sudo rpm --root=/mnt/rescue -qa > /dev/null      # verify the rescue copy first
```

**Never** run `--rebuilddb` without a backup, and never run it concurrently with a `dnf` transaction. Take the fleet-wide inventory (`rpm -qa --qf ...` to object storage, daily) *before* you need it — it is the only artefact that makes a destroyed rpmdb recoverable as anything other than a rebuild.

### 7.5 Diagnosing "who changed this file, and when"

```
$ rpm -qf /etc/ssh/sshd_config
openssh-server-8.7p1-38.el9.x86_64

$ rpm -V openssh-server
S.5....T.  c /etc/ssh/sshd_config

$ rpm -q --qf '[%{FILENAMES} %{FILEDIGESTS} %{FILESIZES} %{FILEMTIMES:date}\n]' \
      openssh-server | grep sshd_config
/etc/ssh/sshd_config 3f5c2a...9b71 4416 Wed 24 Jan 2026 02:51:03 PM UTC

$ sha256sum /etc/ssh/sshd_config
8e1d4b...02af  /etc/ssh/sshd_config          # differs => content changed

$ stat -c '%y %U %G %a' /etc/ssh/sshd_config
2026-08-24 03:14:22.481920144 +0000 root root 600

# Recover the packaged original without touching the running config:
$ dnf download openssh-server
$ rpm2cpio openssh-server-8.7p1-38.el9.x86_64.rpm \
    | cpio --to-stdout -i './etc/ssh/sshd_config' > /tmp/sshd_config.pristine
$ diff -u /tmp/sshd_config.pristine /etc/ssh/sshd_config
--- /tmp/sshd_config.pristine    2026-08-24 12:20:11.000000000 +0000
+++ /etc/ssh/sshd_config         2026-08-24 03:14:22.481920144 +0000
@@ -37,7 +37,7 @@
-PermitRootLogin prohibit-password
+PermitRootLogin yes

# Cross-reference with the transaction ledger and the audit log:
$ sudo dnf history list openssh-server
ID     | Command line              | Date and time    | Action(s)  | Altered
--------------------------------------------------------------------------
    14 | upgrade --security -y     | 2026-08-24 11:41 | Upgrade    |    7
$ sudo ausearch -f /etc/ssh/sshd_config -ts 08/24/2026 03:00:00 | tail -20
```

The transaction at 11:41 is *after* the file's 03:14 mtime — so the change was not made by a package. That single ordering comparison is the difference between "routine upgrade" and "unexplained modification of an authentication config at 3 AM".

### 7.6 Cleanup and capacity

```
# Cache
$ du -sh /var/cache/dnf
1.4G	/var/cache/dnf
$ sudo dnf clean packages       # bodies only, keep metadata
$ sudo dnf clean metadata       # force a metadata refresh on next run
$ sudo dnf clean all            # everything
$ sudo dnf makecache --refresh

# Old kernels — /boot exhaustion is the classic 3 AM page
$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1      1014M  942M   73M  93% /boot
$ rpm -q kernel
kernel-5.14.0-427.13.1.el9_4.x86_64
kernel-5.14.0-427.20.1.el9_4.x86_64
kernel-5.14.0-427.28.1.el9_4.x86_64
kernel-5.14.0-284.30.1.el9_2.x86_64
$ sudo dnf remove --oldinstallonly --setopt installonly_limit=2 -y
$ uname -r                       # confirm the RUNNING kernel survived
5.14.0-427.28.1.el9_4.x86_64

# Orphans
$ sudo dnf autoremove
$ dnf repoquery --unneeded

# Duplicates left by an interrupted transaction
$ dnf repoquery --duplicates
openssl-1:3.0.7-24.el9.x86_64
openssl-1:3.0.7-27.el9_4.x86_64
$ sudo dnf remove --duplicates
```

`sudo dnf remove --oldinstallonly` is safe because `protect_running_kernel=1` prevents removal of the booted kernel. Verify with `uname -r` regardless — a node that boots into a removed kernel is a datacenter visit.

### 7.7 Air-gapped transfer

```
# On a connected staging host — resolve the full closure, not just the leaf:
$ dnf download --resolve --alldeps --destdir /srv/staging/nginx-bundle nginx
$ ls /srv/staging/nginx-bundle | head
nginx-1.20.1-14.el9_2.1.x86_64.rpm
nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
nginx-filesystem-1.20.1-14.el9_2.1.noarch.rpm
openssl-libs-3.0.7-27.el9_4.x86_64.rpm
pcre2-10.40-5.el9.x86_64.rpm

$ createrepo_c /srv/staging/nginx-bundle
$ tar czf nginx-bundle.tar.gz -C /srv/staging nginx-bundle
$ sha256sum nginx-bundle.tar.gz > nginx-bundle.tar.gz.sha256

# On the air-gapped host:
$ sha256sum -c nginx-bundle.tar.gz.sha256
nginx-bundle.tar.gz: OK
$ sudo tar xzf nginx-bundle.tar.gz -C /srv/
$ sudo dnf --disablerepo='*' \
           --repofrompath=bundle,file:///srv/nginx-bundle \
           --setopt=bundle.gpgcheck=1 \
           --setopt=bundle.gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9 \
           install nginx
```

---

## 8. Exam-focused summary

**The eight commands you must be able to write without hesitation:**

```
rpm -qa                       # everything installed
rpm -qi <pkg>                 # metadata: version, status, signature
rpm -ql <pkg>                 # what files does this package provide
rpm -qlp <file.rpm>           # ...for a package that is NOT installed
rpm -qf /path/to/file         # which package owns this file
rpm -V <pkg>                  # integrity: has anything changed on disk
rpm -K <file.rpm>             # signature and digest verification
rpm2cpio <file.rpm> | cpio -idmv   # extract without installing
```

**The four facts most often missed:**

1. `rpm -qp` / `-qlp` query a **file**; without `-p` you query the **installed database**. Using the wrong one is the most common exam error.
2. `rpm -i` refuses an already-installed package, `rpm -U` upgrades or installs, `rpm -F` upgrades **only if already installed**.
3. `rpm -e` does **not** resolve dependencies and will refuse to break them; `dnf remove` and `zypper rm` do resolve.
4. In `rpm -K` output, `digests OK` means the package is **unsigned**; only `digests signatures OK` means signed and trusted.

**The three files:** `/etc/yum.conf` (→ `/etc/dnf/dnf.conf`) is global resolver policy; `/etc/yum.repos.d/*.repo` is one INI section per repository; `/var/lib/rpm` (often symlinked to `/usr/lib/sysimage/rpm`) is the package database — back it up, never edit it.

**The zypper triple:** `zypper up` (upgrade within the repos, never removes), `zypper patch` (errata only), `zypper dup` (make the system match the repos exactly — **can remove packages**).

---

## 9. Referencias

**LPI**
- LPIC-1 Exam 102 objectives (v5.0), Topic 102.5 — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Exam 101 objectives (v5.0) — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**RPM**
- RPM project documentation — https://rpm.org/documentation.html
- RPM Packaging Guide (Fedora) — https://rpm-packaging-guide.github.io/
- `rpm(8)` manual — https://man7.org/linux/man-pages/man8/rpm.8.html
- `rpm2cpio(8)` manual — https://man7.org/linux/man-pages/man8/rpm2cpio.8.html
- RPM package file format (v3) — https://rpm-software-management.github.io/rpm/manual/format.html
- RPM tags reference — https://rpm-software-management.github.io/rpm/manual/tags.html
- RPM dependencies and boolean/rich dependencies — https://rpm-software-management.github.io/rpm/manual/dependencies.html
- RPM scriptlet ordering and triggers — https://rpm-software-management.github.io/rpm/manual/triggers.html
- RPM signatures and package verification — https://rpm-software-management.github.io/rpm/manual/signatures_digests.html
- RPM database backends and configuration — https://rpm-software-management.github.io/rpm/manual/dbconfig.html
- Fedora Packaging Guidelines (scriptlets, `%config`, systemd macros) — https://docs.fedoraproject.org/en-US/packaging-guidelines/

**DNF / YUM**
- DNF documentation (dnf 4) — https://dnf.readthedocs.io/en/latest/
- `dnf.conf(5)` — main and repository options — https://dnf.readthedocs.io/en/latest/conf_ref.html
- DNF command reference — https://dnf.readthedocs.io/en/latest/command_ref.html
- DNF core plugins (`config-manager`, `versionlock`, `needs-restarting`, `reposync`, `download`) — https://dnf-plugins-core.readthedocs.io/en/latest/
- DNF5 documentation — https://dnf5.readthedocs.io/en/latest/
- `dnf-automatic` — https://dnf.readthedocs.io/en/latest/automatic.html
- libsolv (SAT dependency solver) — https://github.com/openSUSE/libsolv
- `createrepo_c` — https://github.com/rpm-software-management/createrepo_c
- Red Hat Enterprise Linux 9 — Managing software with the DNF tool — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/index
- Red Hat Enterprise Linux 9 — Installing and managing software using DNF (AppStream, modules) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/managing-versions-of-appstream-content_managing-software-with-the-dnf-tool
- Rocky Linux documentation — https://docs.rockylinux.org/guides/package_management/
- Fedora — DNF system upgrade — https://docs.fedoraproject.org/en-US/quick-docs/dnf-system-upgrade/

**Zypper / SUSE**
- openSUSE — Zypper usage reference — https://en.opensuse.org/SDB:Zypper_usage
- SUSE Linux Enterprise Server 15 — Managing software with command line tools — https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-sw-cl.html
- `zypper(8)` manual — https://en.opensuse.org/SDB:Zypper_manual
- libzypp — https://github.com/openSUSE/libzypp
- openSUSE — Package signing and GPG keys — https://en.opensuse.org/openSUSE:Package_signing_keys

**Supply chain and repository management**
- Pulp 3 RPM plugin — https://docs.pulpproject.org/pulp_rpm/
- Red Hat Satellite content management — https://docs.redhat.com/en/documentation/red_hat_satellite/
- Red Hat product security — errata and CVE data — https://access.redhat.com/security/data/
- openSUSE / SUSE security advisories — https://www.suse.com/support/update/
- bootc — image-based RPM systems — https://containers.github.io/bootc/
- rpm-ostree — https://coreos.github.io/rpm-ostree/