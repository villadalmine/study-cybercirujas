# LPIC-1 · Topic 102.4 — Use Debian Package Management
## Guided Lab Exercises

**Exam:** LPIC-1 101-500 (Topic 102) · **Weight:** 4.69
**Reference distribution:** Debian 12 *bookworm* (all outputs shown were taken on `amd64`). Everything applies to Ubuntu/Devuan/Raspberry Pi OS with the noted differences.
**Key utilities exercised:** `dpkg`, `dpkg-query`, `dpkg-deb`, `dpkg-reconfigure`, `apt`, `apt-get`, `apt-cache`, `apt-mark`, `apt-file`, `/etc/apt/sources.list`.

---

## Block 0 — Disposable lab environment

Never run these exercises on a machine you care about: several steps deliberately break the dpkg database and force-remove essential-adjacent packages.

1. Create a throwaway container (Podman or Docker, either works):

```bash
podman run --rm -it --name lpic102-4 --hostname deb-lab debian:12 bash
```

2. Inside the container, install the tooling the exercises need and record a baseline:

```bash
apt-get update
apt-get install -y --no-install-recommends \
    tree file less vim-tiny debsums apt-file apt-utils
```

3. Take a baseline snapshot of the package set so you can diff against it later:

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
    | sort > /root/baseline.tsv
wc -l /root/baseline.tsv
```

Expected shape:

```
280 /root/baseline.tsv
```

4. Confirm the architecture the dpkg database considers native, and any foreign architectures enabled:

```bash
dpkg --print-architecture
dpkg --print-foreign-architectures
```

```
amd64
```

(The second command prints nothing on a single-architecture system — that is the correct output, not an error.)

> **Questions — Block 0**
> 1. Why does `dpkg --print-foreign-architectures` produce empty output rather than an error on a fresh install?
> 2. `apt-get install` was used with `--no-install-recommends`. What is the difference between a `Depends`, a `Recommends` and a `Suggests` relationship, and which of the three does APT install by default?
> 3. `dpkg-query -W` was used instead of `dpkg -l`. Give one concrete reason a script in production should prefer the former.

---

## Block 1 — The dpkg database and the status/flag encoding

`dpkg` maintains its own database, entirely independent of APT, under `/var/lib/dpkg/`. APT is a client of that database, not a replacement for it.

1. Inspect the database layout:

```bash
ls -la /var/lib/dpkg/
```

```
drwxr-xr-x 2 root root   4096 Aug 25 09:11 alternatives
-rw-r--r-- 1 root root      0 Aug 25 09:10 available
drwxr-xr-x 2 root root  36864 Aug 25 09:12 info
-rw-r----- 1 root root      0 Aug 25 09:12 lock
-rw-r----- 1 root root      0 Aug 25 09:12 lock-frontend
drwxr-xr-x 2 root root   4096 Aug 25 09:12 parts
-rw-r--r-- 1 root root 512348 Aug 25 09:12 status
-rw-r--r-- 1 root root 511902 Aug 25 09:11 status-old
drwxr-xr-x 2 root root   4096 Aug 25 09:12 triggers
drwxr-xr-x 2 root root   4096 Aug 25 09:12 updates
```

2. Look at the raw stanza for a single package in `/var/lib/dpkg/status` — this is the authoritative record:

```bash
awk 'BEGIN{RS=""} /^Package: tree$/' /var/lib/dpkg/status
```

```
Package: tree
Status: install ok installed
Priority: optional
Section: utils
Installed-Size: 116
Maintainer: Guillem Jover <guillem@debian.org>
Architecture: amd64
Multi-Arch: foreign
Version: 2.1.0-1
Depends: libc6 (>= 2.34)
Description: displays an indented directory tree, in color
 Tree is a recursive directory listing command that produces a depth
 indented listing of files, which is colorized ala dircolors if the
 LS_COLORS environment variable is set and output is to tty.
Homepage: https://gitlab.com/OldManProgrammer/unix-tree
```

3. Read the header legend that `dpkg -l` prints, then a single record:

```bash
dpkg -l tree
```

```
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name           Version      Architecture Description
+++-==============-============-============-===============================
ii  tree           2.1.0-1      amd64        displays an indented directory tree, in color
```

4. Ask `dpkg` for the parsed status of the same package, and for its file manifest:

```bash
dpkg -s tree | head -5
dpkg -L tree
```

```
Package: tree
Status: install ok installed
Priority: optional
Section: utils
Installed-Size: 116
```

```
/.
/usr
/usr/bin
/usr/bin/tree
/usr/share
/usr/share/doc
/usr/share/doc/tree
/usr/share/doc/tree/changelog.Debian.gz
/usr/share/doc/tree/copyright
/usr/share/man
/usr/share/man/man1
/usr/share/man/man1/tree.1.gz
```

5. Now produce a state you will meet in the field. Remove without purging, then re-inspect:

```bash
apt-get remove -y tree
dpkg -l tree
ls /etc/apt/apt.conf.d/ >/dev/null; dpkg-query -f='${db:Status-Abbrev}\n' -W tree
```

```
rc  tree           2.1.0-1      amd64        displays an indented directory tree, in color
```

```
rc
```

6. Confirm that files were removed but the package record survives, then purge:

```bash
ls /usr/bin/tree            # expect: No such file or directory
dpkg -L tree                # expect: the conffile list only, or an explicit note
apt-get purge -y tree
dpkg -l tree                # expect: dpkg-query: no packages found matching tree
```

> **Questions — Block 1**
> 1. Decode each of these two-letter states: `ii`, `rc`, `iU`, `iF`, `hi`, `pn`. Which of them indicate a *broken* system that needs operator intervention?
> 2. `/var/lib/dpkg/available` was 0 bytes. Which command populates it, and why is it effectively obsolete on an APT-managed system?
> 3. A package sits at `rc`. What exactly is still on disk, and which single command clears it?
> 4. Why does `dpkg -L` on an `rc` package not list `/usr/bin/tree`?
> 5. `/var/lib/dpkg/status-old` exists. What operational use does it have during an incident?

---

## Block 2 — `dpkg-query` format strings and file ownership

This is the block that turns dpkg from an interactive tool into something you can drive from a script or a config-management run.

1. Build a machine-readable inventory sorted by installed size — a standard first step when a `/` partition fills up:

```bash
dpkg-query -W -f='${Installed-Size}\t${binary:Package}\t${Version}\n' \
    | sort -nr | head -10
```

```
28934	libc6:amd64	2.36-9+deb12u7
19122	perl-base	5.36.0-7+deb12u1
9781	dpkg	1.21.22
7288	libgcc-s1:amd64	12.2.0-14
6112	gcc-12-base:amd64	12.2.0-14
...
```

2. Extract only packages that are *not* in the clean `installed` state — the single most useful health query on an inherited server:

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
    | grep -v '^ii ' || echo "all packages fully installed"
```

3. Ask which package owns a given path. Note that `dpkg -S` searches the *installed* file lists in `/var/lib/dpkg/info/*.list`:

```bash
dpkg -S /usr/bin/dpkg
dpkg -S /etc/passwd
```

```
dpkg: /usr/bin/dpkg
base-passwd, passwd: /etc/passwd
```

4. Observe the merged-`/usr` trap. On bookworm `/bin` is a symlink to `usr/bin`, but the recorded file lists are not normalized, so a literal path can miss:

```bash
ls -ld /bin
dpkg -S /bin/ls
dpkg -S "$(realpath "$(command -v ls)")"
```

```
lrwxrwxrwx 1 root root 7 Aug 14 12:00 /bin -> usr/bin
coreutils: /bin/ls
coreutils: /usr/bin/ls
```

(On Debian 13 *trixie* and later, only the `/usr/bin/ls` form is recorded. Always resolve with `realpath` in portable scripts.)

5. Search for a file belonging to a package that is **not** installed. `dpkg -S` cannot do this — it only knows installed packages. Use `apt-file`:

```bash
apt-file update
apt-file search bin/htpasswd
apt-file list apache2-utils | head -5
```

```
apache2-utils: /usr/bin/htpasswd
```

```
apache2-utils: /usr/bin/ab
apache2-utils: /usr/bin/checkgid
apache2-utils: /usr/bin/dbmmanage
apache2-utils: /usr/bin/htcacheclean
apache2-utils: /usr/bin/htdbm
```

6. Resolve a shared-library dependency the way you would when a binary fails to start:

```bash
apt-get install -y --no-install-recommends nginx-core >/dev/null 2>&1 || true
ldd "$(command -v tree)" 2>/dev/null || ldd /usr/bin/dpkg
dpkg -S /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null \
    || dpkg -S "$(realpath /lib/x86_64-linux-gnu/libc.so.6)"
```

```
libc6:amd64: /usr/lib/x86_64-linux-gnu/libc.so.6
```

> **Questions — Block 2**
> 1. `dpkg -S /etc/passwd` returned two packages. How is that possible, and which Debian Policy mechanism makes it legal?
> 2. What is the exact functional boundary between `dpkg -S` and `apt-file search`? Name the data source each one reads.
> 3. `apt-file update` was required before searching. Which files does it download, and where do they land?
> 4. Write a one-liner that prints every installed package whose name starts with `libssl`, showing package, version and architecture, without using `grep`.
> 5. Why can `${binary:Package}` differ from `${Package}` in `dpkg-query` format strings?

---

## Block 3 — Anatomy of a `.deb` archive

1. Download a package without installing it, so you have an archive to dissect:

```bash
cd /tmp
apt-get download tree
ls -l tree_*.deb
```

```
-rw-r--r-- 1 root root 51372 Aug 25 09:20 tree_2.1.0-1_amd64.deb
```

2. Prove that a `.deb` is an `ar` archive with exactly three members:

```bash
file tree_2.1.0-1_amd64.deb
ar t tree_2.1.0-1_amd64.deb
```

```
tree_2.1.0-1_amd64.deb: Debian binary package (format 2.0), with control.tar.xz, data.tar.xz
```

```
debian-binary
control.tar.xz
data.tar.xz
```

3. Read the control metadata and the payload listing with `dpkg-deb`'s options (also reachable as `dpkg -I` / `dpkg -c`):

```bash
dpkg-deb --info tree_2.1.0-1_amd64.deb
dpkg-deb --contents tree_2.1.0-1_amd64.deb
```

```
 new Debian package, version 2.0.
 size 51372 bytes: control archive=1044 bytes.
     452 bytes,    12 lines      control
     249 bytes,     4 lines      md5sums
 Package: tree
 Version: 2.1.0-1
 Architecture: amd64
 Maintainer: Guillem Jover <guillem@debian.org>
 Installed-Size: 116
 Depends: libc6 (>= 2.34)
 Section: utils
 Priority: optional
 Multi-Arch: foreign
 Homepage: https://gitlab.com/OldManProgrammer/unix-tree
 Description: displays an indented directory tree, in color
```

```
drwxr-xr-x root/root         0 2023-01-15 20:11 ./
drwxr-xr-x root/root         0 2023-01-15 20:11 ./usr/
drwxr-xr-x root/root         0 2023-01-15 20:11 ./usr/bin/
-rwxr-xr-x root/root    103648 2023-01-15 20:11 ./usr/bin/tree
...
```

4. Extract both halves separately — the technique for recovering a single file from a package without installing it:

```bash
mkdir -p /tmp/deb/{ctrl,data}
dpkg-deb --control  tree_2.1.0-1_amd64.deb /tmp/deb/ctrl
dpkg-deb --extract  tree_2.1.0-1_amd64.deb /tmp/deb/data
ls /tmp/deb/ctrl
find /tmp/deb/data -type f
```

```
control  md5sums
```

```
/tmp/deb/data/usr/bin/tree
/tmp/deb/data/usr/share/man/man1/tree.1.gz
/tmp/deb/data/usr/share/doc/tree/copyright
/tmp/deb/data/usr/share/doc/tree/changelog.Debian.gz
```

5. Inspect a package that ships maintainer scripts and conffiles, so you can see the rest of the control archive:

```bash
apt-get download openssh-server
dpkg-deb --control openssh-server_*.deb /tmp/deb/ssh-ctrl
ls -l /tmp/deb/ssh-ctrl
head -3 /tmp/deb/ssh-ctrl/conffiles
```

```
-rw-r--r-- 1 root root   612 Feb 20 10:02 conffiles
-rw-r--r-- 1 root root  2185 Feb 20 10:02 control
-rw-r--r-- 1 root root 12048 Feb 20 10:02 md5sums
-rwxr-xr-x 1 root root  6031 Feb 20 10:02 postinst
-rwxr-xr-x 1 root root  2144 Feb 20 10:02 postrm
-rwxr-xr-x 1 root root  1877 Feb 20 10:02 preinst
-rwxr-xr-x 1 root root  1103 Feb 20 10:02 prerm
-rw-r--r-- 1 root root   455 Feb 20 10:02 templates
```

```
/etc/default/ssh
/etc/init.d/ssh
/etc/pam.d/sshd
```

6. Compare package versions the way `dpkg` itself does — indispensable in idempotent automation:

```bash
dpkg --compare-versions 1:2.1.0-1 gt 2.1.0-1 && echo "epoch wins"
dpkg --compare-versions 1.10 gt 1.9 && echo "1.10 > 1.9"
dpkg --compare-versions 2.1.0-1~bpo12+1 lt 2.1.0-1 && echo "backport sorts lower"
```

```
epoch wins
1.10 > 1.9
backport sorts lower
```

> **Questions — Block 3**
> 1. Name the three `ar` members of a `.deb` and state what each contains. What is the entire content of `debian-binary`?
> 2. `dpkg-deb --extract` versus `dpkg --unpack`: both write the payload to the filesystem. Give two things `--unpack` does that `--extract` does not.
> 3. What is the purpose of the `conffiles` file in the control archive, and how does it change `dpkg`'s behaviour on upgrade?
> 4. In what order does `dpkg` invoke `preinst`, `postinst`, `prerm` and `postrm` during an upgrade of an already-installed package?
> 5. Why does `2.1.0-1~bpo12+1` sort *lower* than `2.1.0-1`? Which character drives that, and why is it deliberate for backports?

---

## Block 4 — APT sources: `sources.list`, deb822, and the lists cache

1. Read the classic one-line format:

```bash
cat /etc/apt/sources.list
ls -l /etc/apt/sources.list.d/
```

```
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org/debian-security bookworm-security main
```

2. Decompose one line field by field. For `deb http://deb.debian.org/debian bookworm main contrib non-free-firmware`:

| Field | Value | Meaning |
|---|---|---|
| type | `deb` | binary packages (`deb-src` = source packages) |
| URI | `http://deb.debian.org/debian` | repository root |
| suite | `bookworm` | suite or codename (may also be `stable`, or a path ending in `/` for a flat repo) |
| components | `main contrib non-free-firmware` | archive areas, license-based |

3. Add a source in the modern deb822 format, which is the only format that cleanly expresses per-source signing keys:

```bash
mkdir -p /etc/apt/keyrings
cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes
EOF
apt-get update
```

```
Get:1 http://deb.debian.org/debian bookworm-backports InRelease [59.4 kB]
Get:2 http://deb.debian.org/debian bookworm-backports/main amd64 Packages [289 kB]
...
Reading package lists... Done
```

4. Inspect what `apt-get update` actually materialised on disk:

```bash
ls /var/lib/apt/lists/ | head
du -sh /var/lib/apt/lists/
```

```
deb.debian.org_debian_dists_bookworm-backports_InRelease
deb.debian.org_debian_dists_bookworm-backports_main_binary-amd64_Packages.lz4
deb.debian.org_debian_dists_bookworm_InRelease
deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages.lz4
lock
partial
security.debian.org_debian-security_dists_bookworm-security_InRelease
```

```
48M	/var/lib/apt/lists/
```

5. Verify which sources APT considers active, and their trust status:

```bash
apt-cache policy | head -20
```

```
Package files:
 100 /var/lib/dpkg/status
     release a=now
 100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
     release o=Debian Backports,a=bookworm-backports,n=bookworm-backports,l=Debian Backports,c=main,b=amd64
     origin deb.debian.org
 500 http://deb.debian.org/debian bookworm/main amd64 Packages
     release v=12.11,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64
     origin deb.debian.org
```

6. Reproduce and then fix the classic "unsigned repository" failure:

```bash
echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/broken.list
apt-get update 2>&1 | tail -4
rm /etc/apt/sources.list.d/broken.list
apt-get update >/dev/null && echo "sources clean"
```

> **Questions — Block 4**
> 1. In `deb http://deb.debian.org/debian bookworm main contrib`, name every field and say what happens if `main` is omitted entirely.
> 2. Backports appeared with priority `100` in `apt-cache policy` while `bookworm/main` has `500`. What is the practical consequence, and which command installs a package *from* backports anyway?
> 3. `apt-get update` failed on an unsigned repository. Which file inside `dists/<suite>/` carries the signature, and what is the difference between `Release` + `Release.gpg` and `InRelease`?
> 4. Why is `Signed-By:` per-source strictly better than the deprecated `apt-key add`?
> 5. You need to run `apt-get source nginx`. What must you add to your sources configuration first, and what three files does APT fetch?
> 6. Which directory would you clear to force APT to re-download every index from scratch, and which command does it safely?

---

## Block 5 — Querying the cache: `apt-cache`, `apt show`, `apt policy`

1. Search the package descriptions, then narrow to names only:

```bash
apt-cache search 'directory tree' | head -5
apt-cache search --names-only '^tree$'
```

```
tree - displays an indented directory tree, in color
mtree-netbsd - Utility to map a directory hierarchy
...
```

```
tree - displays an indented directory tree, in color
```

2. Read full metadata for the candidate version:

```bash
apt-cache show tree | head -12
apt show tree 2>/dev/null | head -12
```

```
Package: tree
Version: 2.1.0-1
Installed-Size: 116
Maintainer: Guillem Jover <guillem@debian.org>
Architecture: amd64
Depends: libc6 (>= 2.34)
Description-en: displays an indented directory tree, in color
Homepage: https://gitlab.com/OldManProgrammer/unix-tree
Section: utils
Priority: optional
Filename: pool/main/t/tree/tree_2.1.0-1_amd64.deb
Size: 51372
```

3. Compare installed version, candidate version and every available version:

```bash
apt-cache policy nginx-core
apt-cache madison nginx-core
```

```
nginx-core:
  Installed: (none)
  Candidate: 1.22.1-9+deb12u2
  Version table:
     1.24.0-2~bpo12+1 100
        100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
     1.22.1-9+deb12u2 500
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
```

```
nginx-core | 1.24.0-2~bpo12+1 | http://deb.debian.org/debian bookworm-backports/main amd64 Packages
nginx-core | 1.22.1-9+deb12u2 | http://deb.debian.org/debian bookworm/main amd64 Packages
```

4. Walk the dependency graph in both directions:

```bash
apt-cache depends nginx-core
apt-cache rdepends --installed libc6 | head -10
```

```
nginx-core
  Depends: libc6
  Depends: libpcre2-8-0
  Depends: libssl3
  Depends: zlib1g
  Depends: nginx-common
  Conflicts: <nginx-extras>
    nginx-extras
  Replaces: <nginx-extras>
```

5. Use `showpkg` when you need the raw provider/reverse-provider tables — the view that explains virtual packages:

```bash
apt-cache showpkg mail-transport-agent | head -20
```

```
Package: mail-transport-agent
Versions:

Reverse Depends:
  mailutils,mail-transport-agent
  logwatch,mail-transport-agent
  ...
Dependencies:
Provides:
Reverse Provides:
postfix 3.7.11-0+deb12u1
exim4-daemon-light 4.96-15+deb12u6
msmtp-mta 1.8.23-1
```

6. Check the size of the cache and where it lives:

```bash
apt-cache stats | head -8
ls -l /var/cache/apt/*.bin
```

```
Total package names: 118429 (2371 k)
Total package structures: 118429 (6634 k)
  Normal packages: 91302
  Pure virtual packages: 682
  Single virtual packages: 5344
  Mixed virtual packages: 1049
  Missing: 20052
Total distinct versions: 122870 (9829 k)
```

> **Questions — Block 5**
> 1. Which of `apt`, `apt-get` and `apt-cache` is documented as *not* having a stable CLI interface, and what does that mean for a `cron` job or an Ansible task?
> 2. `apt-cache policy` reported `Candidate:` different from the highest listed version. Explain the mechanism that decides the candidate.
> 3. `mail-transport-agent` appeared with no `Versions:` but several `Reverse Provides:`. What kind of package is it, and how does APT satisfy a dependency on it?
> 4. What is the difference between `apt-cache depends` and `apt-cache rdepends`, and why is `--installed` important on the latter?
> 5. `apt show` printed a warning to stderr in some releases. Which one, and what is the scripting-safe equivalent of `apt show <pkg>`?
> 6. The `Filename:` field pointed at `pool/main/t/tree/...`. Reconstruct the complete download URL from the `sources.list` line in Block 4.

---

## Block 6 — Install, remove, purge, and the auto/manual mark

1. Simulate before you act. `-s` (`--simulate`, `--dry-run`) never touches the system:

```bash
apt-get -s install nginx-core
```

```
NOTE: This is only a simulation!
      apt-get needs root privileges for real execution.
The following additional packages will be installed:
  libpcre2-8-0 libssl3 nginx-common
Suggested packages:
  fcgiwrap nginx-doc ssl-cert
The following NEW packages will be installed:
  libpcre2-8-0 libssl3 nginx-common nginx-core
0 upgraded, 4 newly installed, 0 to remove and 0 not upgraded
Inst libssl3 (3.0.17-1~deb12u2 Debian:12/stable [amd64])
Conf libssl3 (3.0.17-1~deb12u2 Debian:12/stable [amd64])
...
```

2. Install for real, then inspect how each package was marked:

```bash
apt-get install -y nginx-core
apt-mark showmanual | grep -E 'nginx|libssl' || true
apt-mark showauto  | grep -E 'nginx|libssl' || true
```

```
nginx-core
```

```
libssl3
nginx-common
libpcre2-8-0
```

3. Watch the auto-mark do its job:

```bash
apt-get remove -y nginx-core
apt-get -s autoremove
```

```
The following packages will be REMOVED:
  libpcre2-8-0 libssl3 nginx-common
0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded
```

4. Flip a mark by hand and observe the effect — the standard fix for "autoremove wants to delete something I still need":

```bash
apt-mark manual libssl3
apt-get -s autoremove | grep -A2 REMOVED
```

```
The following packages will be REMOVED:
  libpcre2-8-0 nginx-common
```

5. Distinguish `remove` from `purge` on a package with conffiles:

```bash
apt-get install -y --no-install-recommends openssh-server >/dev/null
ls /etc/ssh/sshd_config
apt-get remove -y openssh-server >/dev/null
ls -l /etc/ssh/sshd_config          # still present
dpkg -l openssh-server | tail -1
apt-get purge -y openssh-server >/dev/null
ls /etc/ssh/sshd_config             # now gone
```

```
rc  openssh-server 1:9.2p1-2+deb12u7 amd64  secure shell (SSH) server, ...
```

```
ls: cannot access '/etc/ssh/sshd_config': No such file or directory
```

6. Install a local `.deb` two ways and note the difference:

```bash
cd /tmp
apt-get download tree
dpkg -i tree_2.1.0-1_amd64.deb       # no dependency resolution
apt-get purge -y tree >/dev/null
apt-get install -y ./tree_2.1.0-1_amd64.deb   # resolves deps from the repos
```

7. Clean the download cache:

```bash
du -sh /var/cache/apt/archives/
apt-get autoclean          # removes only packages no longer downloadable
apt-get clean              # removes everything
du -sh /var/cache/apt/archives/
```

> **Questions — Block 6**
> 1. State precisely what distinguishes `apt-get remove` from `apt-get purge`, and which dpkg state each one leaves behind.
> 2. Where is the auto/manual mark stored? (Give the file.) Why is it APT state and not dpkg state?
> 3. `apt-get autoremove` is dangerous on inherited servers. Describe the exact failure mode and the two commands that let you audit it before running it.
> 4. `dpkg -i ./tree.deb` and `apt-get install ./tree.deb` both installed the same file. Name two behaviours that differ.
> 5. What does `apt-get autoclean` keep that `apt-get clean` deletes?
> 6. `apt-get install pkg=1.2.3-1` and `apt-get install pkg/bookworm-backports` are both valid. Explain what each one pins, and what happens to the dependencies in each case.

---

## Block 7 — Low-level `dpkg`: unpacked states and recovery

This block deliberately breaks the system. Run it only in the throwaway container.

1. Force a dependency failure by installing a package whose dependency is absent:

```bash
cd /tmp
apt-get download nginx-core libpcre2-8-0 libssl3 nginx-common
dpkg -i nginx-core_*.deb
```

```
Selecting previously unselected package nginx-core.
(Reading database ... 8214 files and directories currently installed.)
Preparing to unpack nginx-core_1.22.1-9+deb12u2_amd64.deb ...
Unpacking nginx-core (1.22.1-9+deb12u2) ...
dpkg: dependency problems prevent configuration of nginx-core:
 nginx-core depends on libpcre2-8-0 (>= 10.22); however:
  Package libpcre2-8-0 is not installed.
 nginx-core depends on nginx-common (= 1.22.1-9+deb12u2); however:
  Package nginx-common is not installed.

dpkg: error processing package nginx-core (--install):
 dependency problems - leaving unconfigured
Errors were encountered while processing:
 nginx-core
```

2. Read the resulting state — this is `iU`, "desired install / status unpacked":

```bash
dpkg -l nginx-core | tail -1
dpkg --audit
```

```
iU  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

```
The following packages are only half configured, probably due to problems
configuring them the first time.  The configuration should be retried using
dpkg --configure <package> or the configure menu in dselect:
 nginx-core        nginx web/proxy server (standard version)
```

3. Repair with APT, which is the correct tool for the job:

```bash
apt-get --fix-broken install -y
dpkg -l nginx-core | tail -1
```

```
ii  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

4. Now produce the other half-state by hand, using `--unpack` without `--configure`:

```bash
apt-get purge -y nginx-core nginx-common >/dev/null 2>&1
dpkg --unpack nginx-common_*.deb
dpkg -l nginx-common | tail -1
dpkg --configure nginx-common
dpkg -l nginx-common | tail -1
```

```
iU  nginx-common   1.22.1-9+deb12u2 all    small, powerful, scalable web/proxy server - common files
```

```
Setting up nginx-common (1.22.1-9+deb12u2) ...
ii  nginx-common   1.22.1-9+deb12u2 all    small, powerful, scalable web/proxy server - common files
```

5. Learn the blanket recovery command used after an interrupted upgrade (power loss, OOM kill during `apt-get dist-upgrade`):

```bash
dpkg --configure -a
```

6. Read the two authoritative logs. `dpkg.log` records every state transition; `apt/history.log` records the operator's intent:

```bash
tail -8 /var/log/dpkg.log
grep -A4 'Start-Date' /var/log/apt/history.log | tail -12
```

```
2026-08-25 09:41:02 status half-installed nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:02 status unpacked nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:07 configure nginx-core:amd64 1.22.1-9+deb12u2 <none>
2026-08-25 09:41:07 status half-configured nginx-core:amd64 1.22.1-9+deb12u2
2026-08-25 09:41:07 status installed nginx-core:amd64 1.22.1-9+deb12u2
```

```
Start-Date: 2026-08-25  09:41:03
Commandline: apt-get --fix-broken install -y
Install: libpcre2-8-0:amd64 (10.42-1, automatic), nginx-common:amd64 (1.22.1-9+deb12u2, automatic)
End-Date: 2026-08-25  09:41:09
```

> **Questions — Block 7**
> 1. Explain, in dpkg's own vocabulary, the difference between *unpacked*, *half-configured* and *half-installed*.
> 2. `dpkg -i` failed on dependencies but still modified the filesystem. Why is that by design, and why is it not a bug?
> 3. What exactly does `dpkg --configure -a` do, and when is it the right first command after a server comes back from an unclean shutdown mid-upgrade?
> 4. `apt-get --fix-broken install` has a shorthand. What is it, and what does APT do that `dpkg --configure -a` cannot?
> 5. You need to answer "who installed `nginx-core` on this box, when, and with what command". Which file answers it, and which file answers "what state transitions did the package go through"?
> 6. `dpkg --audit` printed nothing on a healthy system. Name two distinct conditions it *would* report.

---

## Block 8 — Integrity verification

1. Verify a package against the checksums recorded at install time:

```bash
dpkg -V coreutils && echo "coreutils intact"
```

```
coreutils intact
```

2. Tamper with a conffile and re-verify:

```bash
apt-get install -y --no-install-recommends nano >/dev/null
echo "set tabsize 2" >> /etc/nanorc
dpkg -V nano
```

```
??5?????? c /etc/nanorc
```

3. Tamper with a *program* file — the case that actually matters for incident response:

```bash
cp /usr/bin/tree /root/tree.orig 2>/dev/null || apt-get install -y tree >/dev/null
printf '\x00' >> /usr/bin/tree
dpkg -V tree
```

```
??5??????   /usr/bin/tree
```

4. Read the raw checksum database that `dpkg -V` consults:

```bash
head -3 /var/lib/dpkg/info/tree.md5sums
cat /var/lib/dpkg/info/nano.conffiles
```

```
9e9f6a...c31  usr/bin/tree
2c4d1b...af7  usr/share/man/man1/tree.1.gz
b7f0e2...19d  usr/share/doc/tree/copyright
```

```
/etc/nanorc
```

5. Run a full-system sweep with `debsums`, which is the batch version of the same check:

```bash
debsums -c 2>/dev/null | head
debsums -ce            # changed conffiles only
```

```
/usr/bin/tree
```

```
/etc/nanorc
```

6. Restore the tampered binary the way you would in production:

```bash
apt-get install -y --reinstall tree >/dev/null
dpkg -V tree && echo "restored"
```

```
restored
```

> **Questions — Block 8**
> 1. Decode the verification string `??5?????? c /etc/nanorc`. What does the `5` mean, what does the trailing `c` mean, and why are the other positions `?`?
> 2. `dpkg -V` compares against `/var/lib/dpkg/info/<pkg>.md5sums`. State the security limitation this creates if the host is already compromised, and name the correct tool for a trustworthy audit.
> 3. Why does `dpkg -V` intentionally treat modified conffiles as expected rather than as corruption?
> 4. What is the difference between `debsums -c` and `debsums -ce`?
> 5. A package ships no `.md5sums` file. What does `debsums` report, and which flag regenerates checksums from the archive?
> 6. `apt-get install --reinstall` restored the binary but left `/etc/nanorc` alone. Which option forces conffiles back to the package default in a non-interactive run?

---

## Block 9 — `debconf` and `dpkg-reconfigure`

1. Install a package that asks questions, non-interactively:

```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata locales >/dev/null
cat /etc/timezone
```

```
Etc/UTC
```

2. Inspect the answers currently stored in the debconf database:

```bash
apt-get install -y debconf-utils >/dev/null
debconf-show tzdata
debconf-show locales | head -5
```

```
* tzdata/Areas: Etc
* tzdata/Zones/Etc: UTC
  tzdata/Zones/Europe:
```

3. Re-ask the questions at a chosen priority. `-plow` shows every question, including ones normally suppressed:

```bash
dpkg-reconfigure -plow tzdata
```

(A `whiptail`/`dialog` menu appears. Choose `Europe` → `Madrid`.)

```
Current default time zone: 'Europe/Madrid'
Local time is now:      Tue Aug 25 11:52:31 CEST 2026.
Universal Time is now:  Tue Aug 25 09:52:31 UTC 2026.
```

4. Preseed an answer instead of answering interactively — the scriptable path:

```bash
echo 'tzdata tzdata/Areas select America' | debconf-set-selections
echo 'tzdata tzdata/Zones/America select Argentina/Buenos_Aires' | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata
cat /etc/timezone
```

```
America/Argentina/Buenos_Aires
```

5. Export every stored answer on the system, the way you would capture a golden image's configuration:

```bash
debconf-get-selections | grep '^tzdata'
```

```
tzdata	tzdata/Areas	select	America
tzdata	tzdata/Zones/America	select	Argentina/Buenos_Aires
```

6. Confirm that `dpkg-reconfigure` re-runs maintainer scripts, not merely a settings file:

```bash
dpkg-reconfigure -f noninteractive openssh-server 2>&1 | head -4
tail -3 /var/log/dpkg.log
```

> **Questions — Block 9**
> 1. What does `dpkg-reconfigure <pkg>` actually execute? Name the control-archive script(s) involved.
> 2. Name the four debconf priorities from lowest to highest. Which one is the default, and what is the effect of `-plow`?
> 3. Where does debconf persist answers, and why is that database separate from `/var/lib/dpkg/status`?
> 4. Give the two mechanisms that make a package installation fully non-interactive, and explain why `DEBIAN_FRONTEND=noninteractive` alone is not always sufficient.
> 5. `dpkg-reconfigure` fails with "package is not installed". What state must a package be in for it to work, and would `rc` qualify?
> 6. Why is preseeding with `debconf-set-selections` preferable to editing `/etc/timezone` directly?

---

## Block 10 — Holds, selections, and controlled upgrades

1. Pin a package at its current version with APT's mechanism:

```bash
apt-mark hold nginx-core
apt-mark showhold
apt-get -s upgrade | head -6
```

```
nginx-core set on hold.
nginx-core
```

```
Calculating upgrade...
The following packages have been kept back:
  nginx-core
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
```

2. Observe the same hold from dpkg's side — `apt-mark hold` writes the dpkg selection:

```bash
dpkg -l nginx-core | tail -1
dpkg --get-selections | grep nginx-core
```

```
hi  nginx-core     1.22.1-9+deb12u2 amd64  nginx web/proxy server (standard version)
```

```
nginx-core					hold
```

3. Set and clear a hold using only `dpkg`:

```bash
echo "nginx-common hold" | dpkg --set-selections
dpkg --get-selections | grep -E 'nginx'
echo "nginx-common install" | dpkg --set-selections
apt-mark unhold nginx-core
apt-mark showhold || echo "(no holds)"
```

4. Back up and restore the entire selection set — the classic rebuild-this-box procedure:

```bash
dpkg --get-selections '*' > /root/selections.txt
wc -l /root/selections.txt
# On the target machine:
#   dpkg --set-selections < /root/selections.txt
#   apt-get dselect-upgrade
```

5. Understand `upgrade` vs `full-upgrade` by simulating both:

```bash
apt-get -s upgrade      | tail -3
apt-get -s dist-upgrade | tail -3
```

```
0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
```

```
1 upgraded, 2 newly installed, 1 to remove and 0 not upgraded.
```

6. Add a version pin with `apt_preferences` — beyond the literal objective, but the correct answer when a hold is too blunt:

```bash
cat > /etc/apt/preferences.d/99-backports-nginx <<'EOF'
Package: nginx nginx-core nginx-common
Pin: release a=bookworm-backports
Pin-Priority: 600
EOF
apt-cache policy nginx-core | head -6
rm /etc/apt/preferences.d/99-backports-nginx
```

```
nginx-core:
  Installed: 1.22.1-9+deb12u2
  Candidate: 1.24.0-2~bpo12+1
  Version table:
     1.24.0-2~bpo12+1 600
        100 http://deb.debian.org/debian bookworm-backports/main amd64 Packages
```

> **Questions — Block 10**
> 1. `apt-mark hold` and `dpkg --set-selections ... hold` both produced `hi`. Are they the same mechanism? Where is the hold actually recorded?
> 2. `apt-get upgrade` reported a package "kept back" even with no hold set. Give the two most common causes.
> 3. Explain the difference between `apt-get upgrade`, `apt-get dist-upgrade` and `apt full-upgrade`. Which is safe to run unattended on a production host, and why?
> 4. What does `apt-get dselect-upgrade` do that `apt-get install $(cat list)` does not?
> 5. A hold prevents upgrades. Does it prevent *removal*? Test it and explain.
> 6. Pin-Priority `600` beat the archive's `500`. State what happens at priorities `< 0`, `100`, `500`, `990` and `1001`.

---

## Block 11 — Locks, force flags, and knowing when to stop

1. Reproduce the most common APT failure on a busy host:

```bash
# terminal 1
apt-get install -y --download-only nginx-core &
# terminal 2, immediately
apt-get install -y tree
```

```
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4412 (apt-get)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

2. Identify the holder correctly instead of deleting the lock file:

```bash
apt-get install -y lsof >/dev/null
lsof /var/lib/dpkg/lock-frontend
ps -o pid,ppid,etime,cmd -p "$(lsof -t /var/lib/dpkg/lock-frontend)"
```

```
COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
apt-get 4412 root    4uW  REG   0,58        0  524 /var/lib/dpkg/lock-frontend
```

3. Learn the four lock files and what each guards:

| Lock | Guarded resource |
|---|---|
| `/var/lib/dpkg/lock-frontend` | the right to run a package-management *session* |
| `/var/lib/dpkg/lock` | the dpkg database itself |
| `/var/cache/apt/archives/lock` | the download cache |
| `/var/lib/apt/lists/lock` | the index cache (`apt-get update`) |

4. Explore the force machinery — read it, do not memorise it as a habit:

```bash
dpkg --force-help | head -20
```

```
dpkg forcing options - control behaviour when problems found:
  warn but continue:  --force-<thing>,<thing>,...
  stop with error:    --refuse-<thing>,<thing>,... | --no-force-<thing>,...
 Forcing things:
  [!] all                    Set all force options
  [*] downgrade              Replace a package with a lower version
      configure-any          Configure any package which may help this one
      hold                   Process packages even when marked "hold"
      not-root               Try to install things even if not root
      bad-path               PATH is missing important programs
  [!] overwrite              Overwrite a file from one package with another
  [!] depends                Turn all dependency problems into warnings
  [!] remove-essential       Remove an essential package
```

5. Demonstrate a legitimate use — resolving a file conflict introduced by a broken third-party package:

```bash
# The safe diagnostic first:
dpkg -i /tmp/conflicting.deb 2>&1 | grep 'trying to overwrite'
# Identify the true owner before deciding:
dpkg -S /usr/share/doc/example/README
# Only then, and only with a written reason:
# dpkg -i --force-overwrite /tmp/conflicting.deb
```

6. Demonstrate the flag that should almost never be used, and observe the guard rail:

```bash
dpkg --purge coreutils
```

```
dpkg: error processing package coreutils (--purge):
 this is an essential package; it should not be removed
Errors were encountered while processing:
 coreutils
```

7. Verify the system is back to baseline:

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
    | sort > /root/final.tsv
diff /root/baseline.tsv /root/final.tsv | head
dpkg --audit && echo "database clean"
apt-get check
```

```
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
```

> **Questions — Block 11**
> 1. Why does APT use *two* locks (`lock` and `lock-frontend`) rather than one? What race does the frontend lock prevent?
> 2. `rm /var/lib/dpkg/lock*` is widely posted online. Describe the specific damage it can cause and give the correct procedure instead.
> 3. Which force flags are marked `[!]` in `--force-help`, and what does that marker mean?
> 4. `dpkg --purge coreutils` was refused. Which control field triggers that refusal, and which force flag overrides it? Under what circumstance is that ever justified?
> 5. What does `apt-get check` verify, and how does it differ from `dpkg --audit`?
> 6. You must install a package whose dependency is genuinely satisfied by a locally built library that dpkg does not know about. Name the *correct* solution and explain why `--force-depends` is the wrong one.

---

<details>
<summary><strong>Answers</strong> — click to expand</summary>

### Block 0

1. Foreign architectures are an opt-in multiarch feature. `dpkg --print-foreign-architectures` lists the contents of `/var/lib/dpkg/arch`, which is empty until you run `dpkg --add-architecture <arch>`. An empty list is a valid answer, so the command exits `0` with no output. (Adding `i386` on an `amd64` host and running `apt-get update` is the usual reason to populate it.)

2. From Debian Policy §7.2:
   - **`Depends`** — the package will not be *configured* until the dependency is configured; `dpkg` refuses to complete the install without it. Hard requirement.
   - **`Recommends`** — a strong but not absolute dependency; found in "all but unusual installations". **APT installs these by default** (`APT::Install-Recommends "true"`).
   - **`Suggests`** — may enhance the package; APT never installs these automatically.
   `--no-install-recommends` disables only the middle one. `--install-suggests` enables the last.

3. `dpkg -l` output is a fixed-width table with a three-line legend header, and the columns are *truncated to terminal width* (`Description` gets cut; long package names get cut when `COLUMNS` is small). `dpkg-query -W -f='...'` emits exactly the fields you ask for, tab-separated, with no header and no truncation, so parsing is deterministic. This is the difference between a script that works and one that silently breaks on a 80-column terminal.

### Block 1

1. First letter = **desired action**, second = **current status**, third (usually blank) = **error flag**.
   - `ii` — desired *install*, status *installed*. Normal, healthy.
   - `rc` — desired *remove*, status *config-files*. Binaries gone, conffiles retained. Not broken, but untidy.
   - `iU` — desired *install*, status *unpacked*. **Broken**: files are on disk but `postinst` never ran.
   - `iF` — desired *install*, status *half-configured*. **Broken**: `postinst` started and failed.
   - `hi` — desired *hold*, status *installed*. Healthy, but pinned against upgrades.
   - `pn` — desired *purge*, status *not-installed*. Effectively absent; nothing to do.
   `iU` and `iF` (and anything with an uppercase status letter, or `R` in the error column) demand intervention: `dpkg --configure -a` or `apt-get -f install`.

2. `/var/lib/dpkg/available` is populated by `dpkg --update-avail` / `dpkg --merge-avail`, historically fed by `dselect`. It backs `dpkg -p` / `dpkg --print-avail`. APT keeps its own binary caches in `/var/cache/apt/*.bin` built from `/var/lib/apt/lists/`, so on an APT-managed system `available` is never written and stays at 0 bytes. Do not use `dpkg -p` to ask "what version is available" — use `apt-cache policy`.

3. Only **conffiles** (files listed in the package's `conffiles` control file, essentially `/etc/...`) plus the dpkg status stanza itself. All other payload files, and the `.list`/`.md5sums` entries in `/var/lib/dpkg/info/`, are gone. `apt-get purge <pkg>` (equivalently `dpkg --purge <pkg>`) clears it. To sweep every `rc` package at once: `dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt-get purge -y`.

4. Because `/var/lib/dpkg/info/tree.list` is deleted during removal. `dpkg -L` reads that file. On an `rc` package, only the conffile list survives, so `dpkg -L` reports either just those paths or that the package is not installed but has conffiles.

5. `status-old` is the previous generation of the database, rotated on each transaction. If `/var/lib/dpkg/status` is truncated or corrupted (interrupted write, full filesystem), `status-old` — together with the journal fragments in `/var/lib/dpkg/updates/` — is what you restore from before running `dpkg --configure -a`.

### Block 2

1. Two packages legitimately list the same path when one **`Replaces`** the other for that file, or when both ship it and Policy's file-conflict rules are handled via `Replaces`/`Conflicts`. `/etc/passwd` is shipped by `base-passwd` and managed by `passwd`; `dpkg -S` reports every package whose `.list` contains the path. It is a search across file lists, not a uniqueness assertion.

2. `dpkg -S` searches `/var/lib/dpkg/info/*.list` — the file manifests of **installed** packages only, entirely offline. `apt-file search` searches the `Contents-<arch>` indices downloaded from the repository, covering **every package in the archive whether installed or not**. Use `dpkg -S` for "which installed package owns this file on my disk"; use `apt-file` for "which package would I have to install to get this file".

3. `apt-file update` (or `apt-get update` on modern apt, which fetches Contents when `apt-file` is installed) downloads `dists/<suite>/<component>/Contents-<arch>.gz` for each configured source. They land in `/var/lib/apt/lists/` alongside the `Packages` indices, as `*_Contents-amd64.lz4`.

4. ```bash
   dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' 'libssl*'
   ```
   `dpkg-query` accepts shell-style glob patterns directly; no `grep` needed. (Quote the pattern so the shell does not expand it against the CWD.)

5. `${Package}` is the bare source-ish package name. `${binary:Package}` includes the architecture qualifier when the package is **Multi-Arch: same** and a foreign architecture is enabled — e.g. `libc6:i386` versus `libc6`. On a multiarch host, `${Package}` alone can produce duplicate, ambiguous rows.

### Block 3

1. - `debian-binary` — a plain text file containing exactly `2.0\n`, the package format version.
   - `control.tar.{gz,xz,zst}` — metadata: `control`, and optionally `md5sums`, `conffiles`, `templates`, `triggers`, and the maintainer scripts `preinst`/`postinst`/`prerm`/`postrm`.
   - `data.tar.{gz,xz,zst}` — the actual filesystem payload, rooted at `./`.
   The members must appear in that order; that is what makes streaming installation possible.

2. `dpkg --unpack` additionally (a) runs `preinst`, (b) registers the package in `/var/lib/dpkg/status` and writes `/var/lib/dpkg/info/<pkg>.list` and `.md5sums`, (c) handles conffile prompting and diversions, (d) removes files from a previously installed version. `dpkg-deb --extract` is a pure archive extraction with no database side effects — which is exactly why it is the safe way to pull one file out of a package.

3. `conffiles` lists paths dpkg must treat as **user-editable configuration**. On upgrade, for each listed path dpkg compares the on-disk checksum, the old package's checksum and the new package's: if you never edited it, it is silently replaced; if you edited it *and* the package changed it, dpkg prompts (`keep / replace / diff / shell`) instead of clobbering your change. Files not listed as conffiles are overwritten unconditionally.

4. For an upgrade of an installed package:
   `new-preinst upgrade` → *unpack new files* → `old-postrm upgrade` → `new-postinst configure`.
   (Precisely: `prerm upgrade` of the **old** package runs first, then `preinst upgrade` of the new, then unpack, then `postrm upgrade` of the old, then `postinst configure` of the new.)

5. The tilde `~` sorts **before everything, including the empty string**, in dpkg's version comparison algorithm. So `2.1.0-1~bpo12+1 < 2.1.0-1`. This is deliberate: a backport must be superseded automatically when the user upgrades to the next stable release that ships the real `2.1.0-1`, with no manual intervention.

### Block 4

1. `deb` = archive type (binary; `deb-src` for sources). `http://deb.debian.org/debian` = repository root URI. `bookworm` = suite/codename → the repository is read from `<URI>/dists/bookworm/`. `main contrib` = components. If **no** component is given, APT treats the entry as a *flat repository*: the suite field must then end in `/` and APT looks for `Packages` directly at `<URI>/<suite>/` rather than under `dists/`. Omitting components on a non-flat line makes `apt-get update` fail.

2. Priority `100` means "only install if the package is not installed at all, and never as an automatic upgrade" — so backports never upgrade you silently. To install from backports explicitly: `apt-get install -t bookworm-backports nginx-core` (or `apt-get install nginx-core/bookworm-backports`).

3. Inside `dists/<suite>/` the file is `Release` (the manifest of checksums for every index) plus `Release.gpg` (a **detached** OpenPGP signature over it). `InRelease` is the same manifest **inline-signed** in a single file. `InRelease` is preferred because it is atomic — a mirror cannot serve you a new `Release` with a stale `Release.gpg`.

4. `apt-key add` installed a key into a *global* trusted keyring, meaning that key could then authenticate **any** repository configured on the system — a third-party vendor key could sign packages claiming to be `libc6` from Debian. `Signed-By:` scopes a key to exactly one source entry, so a compromised vendor key can only vouch for that vendor's suite. `apt-key` is deprecated since apt 2.2 and removed in Debian 12+.

5. Add a matching `deb-src` entry (one-line format) or `Types: deb deb-src` (deb822), then `apt-get update`. `apt-get source` then fetches three files: the `.dsc` (signed source control file), the `.orig.tar.*` (upstream tarball) and the `.debian.tar.*` (Debian packaging delta) — and unpacks them, unless `--download-only` is given.

6. `/var/lib/apt/lists/`. Do not `rm -rf` it — that also removes the `lock` and `partial/` directory that APT expects. The supported command is:
   ```bash
   apt-get clean          # optional: also clears /var/cache/apt/archives
   rm -rf /var/lib/apt/lists/*        # leaves the directory itself
   apt-get update
   ```
   Cleaner still: `apt-get update -o Acquire::Retries=3 --allow-releaseinfo-change` for the common "suite changed" case.

### Block 5

1. **`apt`**. Its man page states: *"The `apt` command is meant to be pleasant for end users and does not need to be backward compatible like `apt-get`."* It prints `WARNING: apt does not have a stable CLI interface. Use with caution in scripts.` when stdout is not a terminal. In `cron`, Ansible, Dockerfiles and shell scripts, use `apt-get` / `apt-cache` / `apt-mark`, whose output and options are contractually stable.

2. The candidate is the version with the **highest pin priority**, and among equal priorities the highest version. Priorities come from `apt_preferences` defaults (500 for a configured non-target release, 100 for NotAutomatic sources such as backports and for the installed version, 990 for the release named by `-t`/`APT::Default-Release`) plus any explicit `Pin-Priority` in `/etc/apt/preferences.d/`. So a numerically higher version at priority 100 loses to a lower version at 500.

3. A **pure virtual package**: no real package of that name exists. Several real packages declare `Provides: mail-transport-agent`. A `Depends: mail-transport-agent` is satisfied by installing any one of the providers; if more than one provider exists and none is installed, APT cannot choose and reports the ambiguity, so packages normally use `Depends: default-mta | mail-transport-agent` to give a preferred first choice.

4. `depends` walks *forward*: what this package requires. `rdepends` walks *backward*: what requires this package. Without `--installed`, `rdepends libc6` prints tens of thousands of archive-wide entries, most irrelevant to your host; `--installed` restricts it to packages actually present, which is the answer you want before removing something.

5. `apt show` in apt 1.x–2.0 printed `WARNING: apt does not have a stable CLI interface...` to stderr, and additionally warned when a package had multiple records. The scripting-safe equivalent is `apt-cache show <pkg>` (all versions) or `apt-cache policy <pkg>` (installed vs candidate).

6. Repository root + `Filename`:
   `http://deb.debian.org/debian` + `/pool/main/t/tree/tree_2.1.0-1_amd64.deb`
   → `http://deb.debian.org/debian/pool/main/t/tree/tree_2.1.0-1_amd64.deb`
   Note that `Filename` is relative to the **repository root**, not to `dists/<suite>/`. The `t/tree` fragment is the standard pool hashing: first letter of the source package name (or `libX` for `lib*` packages).

### Block 6

1. `remove` deletes the package's payload files but **keeps its conffiles** and its status stanza, leaving state `rc`. `purge` deletes the payload *and* the conffiles *and* runs `postrm purge` (which is where packages drop their `/var/lib/<pkg>` state, users, and debconf answers), leaving state `pn` or no record at all.

2. `/var/lib/apt/extended_states`, in RFC-822 stanzas:
   ```
   Package: libssl3
   Architecture: amd64
   Auto-Installed: 1
   ```
   It is APT state because dpkg has no concept of *why* a package is present — dpkg only records that it is. "Installed only to satisfy another package's dependency" is a resolver-level fact, so APT owns it. Consequence: `dpkg -i` installs a package with **no** mark, and it defaults to manual.

3. Failure mode: a package that was originally pulled in as a dependency, but is now genuinely required by something APT cannot see — a systemd unit you wrote, a script, a locally compiled binary linking a `-dev` library, a kernel module. Nothing declares that need, so APT removes it. Audit with:
   ```bash
   apt-get -s autoremove            # exact list, no changes made
   apt-mark showauto                # everything currently at risk
   ```
   Then `apt-mark manual <pkg>` for anything you actually depend on, before running the real command.

4. (a) `dpkg -i` performs **no dependency resolution** — it unpacks and then refuses to configure if `Depends` are missing, leaving `iU`. `apt-get install ./file.deb` reads the local file's control data, resolves its dependencies against the configured repositories and downloads them.
   (b) `dpkg -i` leaves the package **manually** marked with no `extended_states` entry; `apt-get install ./file.deb` records the mark and marks the pulled-in dependencies as automatic. `apt-get` also refuses if the local file would break the system, whereas `dpkg -i` proceeds and breaks it.

5. `autoclean` deletes only `.deb` files in `/var/cache/apt/archives/` that can **no longer be downloaded** from any configured source (superseded versions). It keeps the `.deb` files corresponding to versions still in the archive, so a reinstall stays offline-capable. `clean` deletes every `.deb` unconditionally.

6. - `apt-get install pkg=1.2.3-1` pins **that exact version** of `pkg`. Dependencies are resolved normally against the candidate versions — so you can end up with a package pinned to an old version alongside new dependencies, which may be unsatisfiable.
   - `apt-get install pkg/bookworm-backports` selects the version of `pkg` from that **release**, equivalent to a one-shot pin at priority 990 for `pkg` only. Its dependencies still come from the default release unless you use `-t bookworm-backports`, which raises the whole transaction's target release and lets dependencies come from backports too.
   In both cases the package is *not* held — the next `dist-upgrade` may move it.

### Block 7

1. - **unpacked** — the payload has been written to disk and `preinst` has run, but `postinst configure` has not. The package's files exist; its services are not set up.
   - **half-configured** — `postinst configure` was invoked and **failed** (non-zero exit). More alarming than *unpacked*, because side effects may be partially applied.
   - **half-installed** — the install/removal was interrupted **during** the file operations themselves. The filesystem is in an indeterminate state; this is the one that may require `--force-reinstreq` or a reinstall.

2. dpkg is intentionally a low-level tool with a single-package view: it unpacks first, then configures, because a set of interdependent packages can only be made consistent by unpacking all of them and configuring afterwards (that is exactly how `dpkg -i a.deb b.deb c.deb` resolves a circular dependency). Stopping before unpack would make multi-package transactions impossible. Dependency *resolution across the archive* is APT's job, not dpkg's.

3. It attempts `postinst configure` for **every** package currently in the *unpacked* or *half-configured* state, in dependency order. It is the correct first command after an interrupted `dist-upgrade` because the payloads are already on disk — what is missing is the configuration step — and it needs no network access, which matters when the interruption itself broke networking.

4. Shorthand: `apt-get -f install` (and in modern apt, `apt --fix-broken install`). Beyond `dpkg --configure -a`, APT can **download and install missing dependencies** from the repositories, and can propose removing packages to resolve an unsatisfiable set. `dpkg` can only work with `.deb` files you hand it.

5. - **Who/when/what command:** `/var/log/apt/history.log` (and `history.log.*.gz`), which records `Start-Date`, `Commandline`, `Requested-By` (the invoking user via sudo), `Install`/`Upgrade`/`Remove`/`Purge` lists, and `End-Date`. `/var/log/apt/term.log` holds the raw terminal output of the same transactions.
   - **State transitions:** `/var/log/dpkg.log`, which logs every `status <state> <pkg>:<arch> <version>` change including `half-installed`, `unpacked`, `half-configured`, `installed`, plus `configure`, `trigproc`, `remove`, `purge`, `upgrade` and `conffile` decisions.

6. `dpkg --audit` reports packages that are (a) partially installed — *unpacked* or *half-configured*, i.e. `postinst` never completed, and (b) partially removed / `half-installed`, i.e. the operation was interrupted mid-file-operation. It also flags packages whose *reinstallation is required* (`R` in the error column) and, with a package argument, missing files.

### Block 8

1. The nine positions mirror the RPM `-V` convention; dpkg currently implements only the checksum check, so everything except position 3 is `?` ("not checked"). Position 3 = `5` means the **MD5 checksum differs** from the one recorded at install time. The separate column after the flags is the file type: `c` = conffile, blank = ordinary file. So: *"this conffile's content no longer matches the packaged version"*. `missing` appears in place of the flag string when the file is absent entirely.

2. The `.md5sums` files live on the same filesystem, writable by root. An attacker who replaced `/usr/bin/sshd` will also rewrite `/var/lib/dpkg/info/openssh-server.md5sums`, and `dpkg -V` will then report the system as clean. For a trustworthy audit you must compare against an **off-host** source of truth: re-download the `.deb` from the repository (whose `Packages` index is GPG-signed) and compare, e.g. `debsums --generate=all` against a fresh download, or use a host-independent IDS (AIDE, Tripwire) whose database is stored off the machine. Even then, only the repository signature chain is authoritative.

3. Because editing files under `/etc` is the *intended* administrative workflow, guaranteed by Debian Policy §10.7. If a modified conffile counted as corruption, every configured server on Earth would fail verification. The `c` marker exists precisely so tooling can filter those lines out — which is what `debsums -c` (all changed files) versus `debsums -ce` (changed conffiles only) is for.

4. `debsums -c` lists **all** files whose checksum no longer matches — binaries, libraries, docs and conffiles alike. `debsums -ce` restricts the report to **conffiles only**, i.e. the expected administrative changes. In incident response you want `debsums -c` and then subtract the `-ce` set: what remains is unexplained.

5. `debsums` reports the package as having **no checksums available** (with `-s` it stays silent; without it, one line per missing package). `debsums --generate=missing` (or `-g missing`) regenerates checksums, but it must download the `.deb` from the archive or read it from `/var/cache/apt/archives/` — regenerating from the *installed* files would be circular and prove nothing. `--generate=all` regenerates for every package.

6. ```bash
   apt-get install -y --reinstall \
       -o Dpkg::Options::="--force-confask,confnew" nano
   ```
   or, non-interactively forcing the package default:
   ```bash
   apt-get install -y --reinstall \
       -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" nano
   ```
   `--force-confnew` takes the package's version, `--force-confold` keeps yours, `--force-confdef` lets dpkg pick the default action when it has one. Reinstall alone never touches an unchanged-by-the-package conffile, which is why `/etc/nanorc` survived.

### Block 9

1. `dpkg-reconfigure` (a) unregisters the package's debconf answers so the questions become unseen again, (b) re-runs the package's **`config`** script (from the control archive) to ask the questions, and (c) re-runs **`postinst configure`** with the new answers so the configuration is actually applied. It is not a settings editor — it re-executes real maintainer code, which is why it can restart services.

2. Lowest → highest: **`low`, `medium`, `high`, `critical`**. The default threshold is `high`, so only `high` and `critical` questions are shown. `-plow` lowers the threshold to `low`, meaning **every** question, including ones the maintainer considered safe to answer automatically, is presented. (`-pcritical` shows almost nothing.)

3. In the debconf database, by default `/var/cache/debconf/config.dat` (answers) and `/var/cache/debconf/templates.dat` (question text), with `/var/cache/debconf/passwords.dat` for password-type answers, and the backend configured in `/etc/debconf.conf`. It is separate from `/var/lib/dpkg/status` because debconf is an independent configuration-management layer with its own lifecycle: answers must survive package removal, be preseedable *before* the package exists, and be shared between packages.

4. (a) `DEBIAN_FRONTEND=noninteractive`, which selects a frontend that never prompts and accepts every default; (b) **preseeding** the answers with `debconf-set-selections` (or a preseed file) before installing, so the defaults are the values you want.
   `DEBIAN_FRONTEND=noninteractive` alone is insufficient because it only suppresses the *asking* — you get the maintainer's defaults, not your values. It also does not cover **dpkg's own** conffile prompt, which is not a debconf question; that needs `-o Dpkg::Options::="--force-confold"` (or `confnew`). And a badly written `postinst` that calls `read` directly will still hang.

5. The package must be at least **unpacked and configured** — in practice `ii`. `rc` does **not** qualify: `dpkg-reconfigure` refuses with `Package <pkg> is not installed`, because the `config` and `postinst` scripts were removed along with the payload. You must reinstall first.

6. Because `dpkg-reconfigure`/preseeding drives the package's own logic. For `tzdata`, setting `/etc/timezone` by hand leaves `/etc/localtime` pointing at the old zone and leaves debconf's recorded answer stale — so the next `tzdata` upgrade, which runs `postinst configure` with the stored answer, silently reverts your change. Preseeding sets the value at the layer that owns it, so it is idempotent and survives upgrades. It is also the only approach that works in an image build with no TTY.

### Block 10

1. They are the **same mechanism**. `apt-mark hold` sets the dpkg *selection* to `hold` in `/var/lib/dpkg/status` (the `Status:` line becomes `hold ok installed`), which is exactly what `echo "pkg hold" | dpkg --set-selections` does. That is why `apt-mark showhold` and `dpkg --get-selections | grep hold` agree, and why both produce `hi` in `dpkg -l`. (Note: this is *not* the auto/manual mark, which lives in `/var/lib/apt/extended_states` — different concept entirely.)

2. (a) The upgrade would require **installing a new package or removing an existing one** — `apt-get upgrade` refuses to do either, so it keeps the package back. `apt-get dist-upgrade` will do it. (b) **Phased updates** (`Phased-Update-Percentage`, prominent on Ubuntu): the machine has not yet been selected for the rollout. Also common: an unsatisfiable dependency from a pinned or third-party source.

3. - `apt-get upgrade` — upgrades installed packages only. Never installs a new package, never removes one. Conservative.
   - `apt-get dist-upgrade` — may install new packages and remove existing ones to satisfy changed dependencies. Required for release upgrades and for transitional packages.
   - `apt full-upgrade` — the `apt` front-end's name for `dist-upgrade`. Identical behaviour, unstable CLI.
   For unattended production use, `apt-get upgrade` (or better, `unattended-upgrades` restricted to `-security`), because it can never remove a package — a `dist-upgrade` that removes your MTA at 03:00 with no operator present is an outage.

4. `apt-get dselect-upgrade` reads the **selections** already recorded in the dpkg database (`install` / `hold` / `deinstall` / `purge`) and makes the system match them — including *removing* packages marked `deinstall` and *purging* those marked `purge`. `apt-get install $(cat list)` only ever adds; it cannot express removal, and it marks everything manual. The pair `dpkg --get-selections '*' > f` / `dpkg --set-selections < f` + `apt-get dselect-upgrade` is the classic full-system replication procedure.

5. A hold does **not** prevent removal. `apt-get remove nginx-core` on a held package proceeds normally (APT warns in some versions but complies), and `dpkg -r` removes it — only `dpkg`'s own dependency-driven *automatic* processing respects the hold, which is what `--force-hold` overrides. The hold protects against *upgrade*, not against an explicit operator command. To block removal you need `apt_preferences` or, properly, an `Essential`-like arrangement or configuration management.

6. From `apt_preferences(5)`:
   - **`< 0`** — the version will never be installed.
   - **`0–99`** — installed only if no version of the package is currently installed.
   - **`100`** — installed only if no version is installed, *or* it is the currently installed version (this is the default priority of the installed version and of `NotAutomatic` sources like backports).
   - **`101–499`** — installed unless a version from a higher-priority source is available; can upgrade.
   - **`500`** — the default for a normal configured source; installed unless a newer version is available elsewhere at equal or higher priority.
   - **`990`** — the default for the target release (`-t` / `APT::Default-Release`); preferred even over a numerically newer version elsewhere.
   - **`> 1000`** — the version is installed **even if it means downgrading**. This is the only band that permits an automatic downgrade.

### Block 11

1. `/var/lib/dpkg/lock` protects a **single dpkg database transaction**. `/var/lib/dpkg/lock-frontend` protects the **whole front-end session**, which spans many dpkg invocations plus the resolver, the download phase and the debconf interaction. Without the frontend lock, a second `apt-get` could slip in between two of the first one's dpkg calls, compute a plan against a database state that is about to change, and produce an inconsistent transaction. The frontend lock also lets a front-end hold the session while dpkg itself briefly releases the database lock during maintainer scripts.

2. Deleting the lock while another process is mid-transaction lets a second dpkg run concurrently against `/var/lib/dpkg/status`. Two writers to the status database produce a corrupted or truncated file, half-installed packages, and lost `.list` manifests — a state that can require restoring from `status-old` or reinstalling by hand. Correct procedure:
   ```bash
   lsof /var/lib/dpkg/lock-frontend            # or: fuser -v /var/lib/dpkg/lock*
   ps -o pid,ppid,etime,stat,cmd -p <PID>      # is it running or stuck?
   # If it is a legitimate run (unattended-upgrades is the usual culprit): wait.
   # If it is genuinely dead:
   systemctl stop unattended-upgrades          # stop the source, not the symptom
   kill <PID>                                  # SIGTERM, let it clean up
   dpkg --configure -a                         # then repair
   apt-get -f install
   ```
   Only if the process is confirmed gone and the lock file is stale does removing it become defensible — and it must be followed by `dpkg --configure -a`.

3. `[!]` marks options that are **extremely dangerous** and are not enabled by `--force-all`'s "safe" subset in the way `[*]` (enabled by default) ones are. In `dpkg --force-help`, `[*]` = enabled by default, `[!]` = dangerous, will produce a loud warning, and may leave the system in a state dpkg cannot repair. `--force-depends`, `--force-overwrite`, `--force-remove-essential` and `--force-all` all carry it.

4. The **`Essential: yes`** control field (Debian Policy §3.8) — packages that must be functional at all times for the system to work; dpkg refuses to remove them. `--force-remove-essential` overrides it. Legitimate uses are essentially limited to: repairing a broken essential package inside a `chroot`/container image build where you immediately reinstall it, or a deliberate cross-grade under recovery. On a running system it is how you make a machine unbootable and unreachable in one command. (Related: `Protected: yes`, guarding the boot path, overridden by `--force-remove-protected`.)

5. `apt-get check` updates the package cache and then verifies that the **dependency tree is consistent** — that every installed package's `Depends`, `Pre-Depends`, `Conflicts` and `Breaks` are satisfied. It answers "is the *dependency graph* sound?". `dpkg --audit` answers a different question: "is any package in a *partial state*?" — unpacked, half-configured, half-installed. A system can pass `dpkg --audit` and fail `apt-get check` (all packages fully configured but a dependency was force-removed), and vice versa.

6. The correct solution is to make the dependency **declarable**: build a proper `.deb` for the local library (`dpkg-deb --build`, `checkinstall`, or `fpm`) so it registers in the dpkg database and satisfies the `Depends` legitimately; or, when you only need to satisfy the relationship, build an `equivs` dummy package (`equivs-control` / `equivs-build`) that declares `Provides:` the required name and version.
   `--force-depends` is wrong because it turns the dependency error into a warning **permanently in the database**: the package configures, but dpkg now records an unsatisfied dependency. Every subsequent `apt-get install`, `upgrade` and `dist-upgrade` will see a broken tree, `apt-get check` will fail, and APT's resolver may propose removals to "fix" it. You have not solved the problem — you have hidden it from the only tool that could have told you about it, and left a trap for the next operator.

</details>

---

## Official Sources

- LPI — Exam 101-500 Objectives (Topic 102.4): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Debian Policy Manual — Chapter 3 (Binary packages), 7 (Declaring relationships), 10.7 (Configuration files): <https://www.debian.org/doc/debian-policy/>
- `dpkg(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html>
- `dpkg-query(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html>
- `dpkg-deb(1)`: <https://manpages.debian.org/bookworm/dpkg/dpkg-deb.1.en.html>
- `deb(5)` — archive format: <https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html>
- `apt(8)` / `apt-get(8)` / `apt-cache(8)` / `apt-mark(8)`: <https://manpages.debian.org/bookworm/apt/>
- `sources.list(5)`: <https://manpages.debian.org/bookworm/apt/sources.list.5.en.html>
- `apt_preferences(5)` — pinning: <https://manpages.debian.org/bookworm/apt/apt_preferences.5.en.html>
- `dpkg-reconfigure(8)` and `debconf(7)`: <https://manpages.debian.org/bookworm/debconf/dpkg-reconfigure.8.en.html>
- Debian Repository Format: <https://wiki.debian.org/DebianRepository/Format>
- Debian merged-`/usr` (DEP-17): <https://wiki.debian.org/UsrMerge>
- The Debian Administrator's Handbook — Chapters 5 (Packaging System) and 6 (Maintenance and Updates): <https://www.debian.org/doc/manuals/debian-handbook/>