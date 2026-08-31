# LPIC-1 102.5 — Use RPM and YUM Package Management
## Guided Exercises

> **Exam weight:** 4.69 (Exam 102-500, version 5.0)
> **Scope covered here:** `rpm`, `rpm2cpio`, `/etc/yum.conf`, `/etc/yum.repos.d/`, `yum`, `dnf`, `zypper`, package integrity and signatures, file↔package reverse lookups, dependency inspection, transaction history and recovery.

---

## How to use this document

Every exercise is a numbered command sequence you type on a real system, followed by **Checkpoint questions**. Do not read ahead to the answers: run the block, look at *your* output, then answer. The expected outputs shown are from a Rocky Linux 9.3 x86_64 system; version-release strings on your machine will differ, and that difference is itself informative.

Commands prefixed `#` require root. Commands prefixed `$` do not — and one of the recurring lessons is that **every query operation in RPM and DNF works unprivileged**; only transactions need root.

---

## Exercise 0 — Building a disposable lab

Never learn package management on a machine you care about. You will deliberately corrupt files, force-install broken packages and roll transactions back.

### Steps

1. Create the RPM/DNF lab container. Podman is used here; `docker` works identically.

   ```bash
   $ podman run -it --name lpic-rpm --hostname rpmlab \
       quay.io/rockylinux/rockylinux:9 /bin/bash
   ```

2. Inside the container, install the tooling the exercises need and a few harmless victims:

   ```bash
   # dnf -y install dnf-plugins-core rpm-build vim-enhanced cpio \
        which findutils procps-ng diffutils python3-dnf-plugin-versionlock
   ```

3. Confirm the RPM stack version — behaviour differs materially between RPM 4.14 (RHEL 8), 4.16 (RHEL 9) and 4.19+/5 (Fedora 40+):

   ```bash
   $ rpm --version
   RPM version 4.16.1.3

   $ dnf --version
   4.14.0
   Installed: dnf-0:4.14.0-9.el9.noarch at Thu 12 Oct 2023 07:41:02 PM UTC
   ...
   ```

4. In a **second terminal**, create the zypper lab (needed only from Exercise 14 onward):

   ```bash
   $ podman run -it --name lpic-zypper --hostname zyplab \
       registry.opensuse.org/opensuse/leap:15.6 /bin/bash
   ```

5. Record a baseline you can diff against later:

   ```bash
   # rpm -qa | sort > /root/baseline-packages.txt
   # wc -l /root/baseline-packages.txt
   243 /root/baseline-packages.txt
   ```

### Checkpoint questions

- **Q0.1** — Why does `rpm -qa` work as an unprivileged user, while `rpm -i` does not? Name the two filesystem locations that make the difference.
- **Q0.2** — You ran `rpm --version` and got `4.16.1.3`. Which RPM database backend does that release use by default, and what command proves it without looking at `/var/lib/rpm`?
- **Q0.3** — Your baseline file lists NEVRA strings such as `bash-5.1.8-6.el9_1.x86_64`. Decompose that string into its five fields and state which one is *not* present.

---

## Exercise 1 — Where the truth lives: the RPM database

RPM has no daemon and no network layer. It is a local transactional database plus a file format. Everything else — DNF, YUM, Zypper, PackageKit — is a *depsolver and downloader* bolted on top.

### Steps

1. Ask RPM where its database is, instead of assuming:

   ```bash
   $ rpm -E '%{_dbpath}'
   /var/lib/rpm

   $ rpm -E '%{_db_backend}'
   sqlite
   ```

2. Look at the actual files:

   ```bash
   $ ls -l /var/lib/rpm/
   total 12288
   -rw-r--r--. 1 root root 12587008 Aug 20 09:14 rpmdb.sqlite
   -rw-r--r--. 1 root root    32768 Aug 20 09:14 rpmdb.sqlite-shm
   -rw-r--r--. 1 root root  4136432 Aug 20 09:14 rpmdb.sqlite-wal
   ```

   On RHEL 8 / CentOS 8 you would instead see `Packages`, `Name`, `Basenames`, `Providename` … — Berkeley DB tables. On systems built with `ndb` you would see `Packages.db`, `Index.db`.

3. Count and sort installed packages by installation time — the single most useful forensic query on a machine you did not build:

   ```bash
   $ rpm -qa --last | head -5
   python3-dnf-plugin-versionlock-4.3.0-11.el9.noarch  Wed 20 Aug 2026 09:14:22 AM UTC
   vim-enhanced-8.2.2637-20.el9_1.x86_64               Wed 20 Aug 2026 09:14:21 AM UTC
   rpm-build-4.16.1.3-25.el9.x86_64                    Wed 20 Aug 2026 09:14:18 AM UTC
   cpio-2.13-16.el9.x86_64                             Wed 20 Aug 2026 09:13:57 AM UTC
   dnf-plugins-core-4.3.0-11.el9.noarch                Wed 20 Aug 2026 09:13:57 AM UTC
   ```

4. Build a custom report with `--queryformat` (`--qf`). This is the difference between reading package data and *scripting* it:

   ```bash
   $ rpm -qa --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{ARCH}|%{SIZE}|%{VENDOR}\n' \
       | sort -t'|' -k4 -rn | head -3
   rpm-build|4.16.1.3-25.el9|x86_64|54280192|Rocky Enterprise Software Foundation
   vim-enhanced|8.2.2637-20.el9_1|x86_64|3320672|Rocky Enterprise Software Foundation
   glibc|2.34-60.el9|x86_64|6710092|Rocky Enterprise Software Foundation
   ```

5. Format a timestamp tag correctly — raw tags are epoch seconds:

   ```bash
   $ rpm -q --qf '%{NAME} %{INSTALLTIME}\n' bash
   bash 1755680037

   $ rpm -q --qf '%{NAME} %{INSTALLTIME:date}\n' bash
   bash Wed 20 Aug 2026 09:13:57 AM UTC
   ```

6. Discover every queryable tag on this system:

   ```bash
   $ rpm --querytags | wc -l
   276
   $ rpm --querytags | grep -i -E 'sig|size|time' | head
   ```

### Checkpoint questions

- **Q1.1** — A colleague says "the RPM database is in `/var/lib/rpm`, everybody knows that". Give two concrete scenarios in this course where that assumption is wrong, and the flag that handles each.
- **Q1.2** — Write a single `rpm` command that prints only the **names** of packages that have no vendor set (`%{VENDOR}` = `(none)`). Why are such packages security-relevant on a production host?
- **Q1.3** — `rpm -qa --last` is sorted newest first. Why can this ordering be misleading immediately after a `dnf upgrade` of 200 packages, and what would you use instead to reconstruct *what operation* happened?
- **Q1.4** — What is the difference between `%{SIZE}` and the size of the `.rpm` file the package came from?

---

## Exercise 2 — Interrogating an installed package

The `-q` mode has *selection* options (which package) and *information* options (what to print). Mixing up the two is the classic exam trap.

### Steps

1. The five queries you will use daily:

   ```bash
   $ rpm -qi bash        # Info: metadata header
   $ rpm -ql bash        # List: every file the package owns
   $ rpm -qc bash        # Config files only (%config)
   $ rpm -qd bash        # Documentation files only (%doc)
   $ rpm -qs bash        # State of each file (normal / not installed / replaced)
   ```

2. Read the info header carefully — several fields matter operationally:

   ```bash
   $ rpm -qi bash
   Name        : bash
   Version     : 5.1.8
   Release     : 6.el9_1
   Architecture: x86_64
   Install Date: Wed 20 Aug 2026 09:13:57 AM UTC
   Group       : Unspecified
   Size        : 7739624
   License     : GPLv3+
   Signature   : RSA/SHA256, Tue 07 Feb 2023 05:07:32 PM UTC, Key ID 15af5dac6d745a60
   Source RPM  : bash-5.1.8-6.el9_1.src.rpm
   Build Date  : Tue 07 Feb 2023 05:00:24 PM UTC
   Build Host  : ...
   Packager    : releng@rockylinux.org
   Vendor      : Rocky Enterprise Software Foundation
   URL         : https://www.gnu.org/software/bash
   Summary     : The GNU Bourne Again shell
   Description :
   The GNU Bourne Again shell (Bash) is a shell or command language
   interpreter that is compatible with the Bourne shell (sh)...
   ```

3. Compare the file lists. Note that `-qc` and `-qd` are strict subsets of `-ql`:

   ```bash
   $ rpm -ql bash | wc -l
   211
   $ rpm -qc bash
   /etc/skel/.bash_logout
   /etc/skel/.bash_profile
   /etc/skel/.bashrc
   $ rpm -qd bash | head -3
   /usr/share/doc/bash/AUTHORS
   /usr/share/doc/bash/CHANGES
   /usr/share/doc/bash/COMPAT
   ```

4. Get the file list *with its recorded attributes* — the raw material RPM verification uses:

   ```bash
   $ rpm -q --dump bash | grep '/etc/skel/.bashrc'
   /etc/skel/.bashrc 141 1675789224 40c2ac1e1f0b8...  0100644 root root 1 0 0 X
   ```

   Field order: `path size mtime digest mode owner group isconfig isdoc rdev symlink`.

5. Inspect the dependency face of the package:

   ```bash
   $ rpm -q --provides bash
   bash = 5.1.8-6.el9_1
   bash(x86-64) = 5.1.8-6.el9_1
   config(bash) = 5.1.8-6.el9_1
   /bin/sh

   $ rpm -q --requires bash | head -6      # -qR is the short form
   /bin/sh
   config(bash) = 5.1.8-6.el9_1
   filesystem >= 3
   libc.so.6()(64bit)
   libc.so.6(GLIBC_2.11)(64bit)
   ...

   $ rpm -q --conflicts filesystem
   $ rpm -q --obsoletes systemd | head -3
   $ rpm -q --recommends vim-enhanced       # weak dependency, RPM >= 4.12
   ```

6. Read the maintainer scripts — this is where "why did installing that package restart my service?" is answered:

   ```bash
   $ rpm -q --scripts openssh-server | head -20
   preinstall scriptlet (using /bin/sh):
   ...
   postinstall scriptlet (using /bin/sh):
   %systemd_post sshd.service sshd.socket
   ...
   ```

7. Read the changelog to date a fix without leaving the box:

   ```bash
   $ rpm -q --changelog openssl | head -8
   * Tue Feb 07 2023 Dmitry Belyavskiy <dbelyavs@redhat.com> 3.0.7-6
   - Fixed CVE-2023-0286 ...
   ```

### Checkpoint questions

- **Q2.1** — `rpm -qc bash` returns three files under `/etc/skel/`, but not `/etc/bashrc`. Which package owns `/etc/bashrc`, and what does that tell you about how Red Hat–family distributions split shell configuration?
- **Q2.2** — Distinguish these two commands precisely: `rpm -qi bash` and `rpm -qip bash-5.1.8-6.el9_1.x86_64.rpm`. Which one can fail with "package not installed" and why?
- **Q2.3** — `bash` provides `/bin/sh` and also *requires* `/bin/sh`. Explain how RPM resolves this without an infinite loop, and what it means for `rpm -e bash`.
- **Q2.4** — You need to know, on a fleet of 400 hosts, which of them shipped an `openssl` build predating a specific CVE fix. Give a one-line command using only `rpm` that answers it, and explain why `--changelog` grep is a weaker method than comparing version-release.
- **Q2.5** — What is `config(bash) = 5.1.8-6.el9_1` for? Why does a package depend on a virtual provide named after itself?

---

## Exercise 3 — Reverse lookups: which package owns this file?

### Steps

1. The core reverse query:

   ```bash
   $ rpm -qf /bin/ls
   coreutils-8.32-34.el9.x86_64

   $ rpm -qf /etc/passwd
   setup-2.13.7-10.el9.noarch

   $ rpm -qf /usr/bin/dnf
   dnf-4.14.0-9.el9.noarch
   ```

2. Combine `-qf` with information options — selection and information are orthogonal:

   ```bash
   $ rpm -qif /usr/sbin/sshd | head -4
   $ rpm -qlf /usr/bin/vim | wc -l
   $ rpm -qcf /usr/sbin/sshd
   /etc/pam.d/sshd
   /etc/ssh/sshd_config
   /etc/sysconfig/sshd
   ```

3. Prove what "unowned" means:

   ```bash
   $ touch /root/notes.txt
   $ rpm -qf /root/notes.txt
   file /root/notes.txt is not owned by any package
   $ echo $?
   1
   ```

4. Resolve a *capability* rather than a path:

   ```bash
   $ rpm -q --whatprovides /bin/sh
   bash-5.1.8-6.el9_1.x86_64

   $ rpm -q --whatprovides 'libc.so.6()(64bit)'
   glibc-2.34-60.el9.x86_64
   ```

5. Ask the inverse — who would break if this package went away:

   ```bash
   $ rpm -q --whatrequires zlib | head
   dnf-data-4.14.0-9.el9.noarch
   ...
   ```

   Then compare with the DNF-side answer, which sees the whole repository, not only what is installed:

   ```bash
   $ dnf repoquery --whatrequires zlib --installed | head
   ```

6. A real triage pattern — find every unowned file in a system directory (candidates for configuration drift or an intruder):

   ```bash
   # find /usr/bin -type f -print0 \
       | xargs -0 rpm -qf 2>/dev/null \
       | grep 'not owned' | head
   ```

### Checkpoint questions

- **Q3.1** — `rpm -qf $(which java)` returns "not owned by any package" on a host where Java clearly works. List three legitimate explanations.
- **Q3.2** — `rpm -q --whatrequires bash` returns a short list, but removing `bash` would obviously destroy the system. Why is `--whatrequires` an *incomplete* impact analysis, and what capability should you query instead?
- **Q3.3** — What is the exit status of `rpm -qf` for an unowned file, and why does that matter in a shell script that pipes many paths through it?
- **Q3.4** — Two packages both claim to own `/usr/share/man/man1/foo.1.gz`. Is that possible in RPM? Under what declaration, and what does `rpm -qf` print then?

---

## Exercise 4 — Interrogating a package *file* before you trust it

Everything so far queried the database. Add `-p` and the same options read an `.rpm` file on disk — local or remote, installed or not.

### Steps

1. Download a package without installing it:

   ```bash
   # dnf download --resolve --destdir=/tmp/pkgs nginx
   ...
   nginx-1.20.1-14.el9_2.1.x86_64.rpm            1.6 MB/s | 617 kB   00:00
   nginx-core-1.20.1-14.el9_2.1.x86_64.rpm       4.1 MB/s | 566 kB   00:00
   nginx-filesystem-1.20.1-14.el9_2.1.noarch.rpm 118 kB/s | 8.5 kB   00:00
   $ ls /tmp/pkgs
   ```

2. Read it without touching the system:

   ```bash
   $ cd /tmp/pkgs
   $ rpm -qip nginx-1.20.1-14.el9_2.1.x86_64.rpm
   $ rpm -qlp nginx-1.20.1-14.el9_2.1.x86_64.rpm | head
   $ rpm -qcp nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
   /etc/logrotate.d/nginx
   /etc/nginx/fastcgi.conf
   /etc/nginx/nginx.conf
   ...
   $ rpm -qp --requires nginx-1.20.1-14.el9_2.1.x86_64.rpm
   $ rpm -qp --scripts nginx-1.20.1-14.el9_2.1.x86_64.rpm
   ```

3. Query a package straight off the network — RPM speaks HTTP/FTP natively:

   ```bash
   $ rpm -qip https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/b/bash-5.1.8-6.el9_1.x86_64.rpm
   ```

4. Compare a candidate against what is installed, mechanically:

   ```bash
   $ rpm -qp --qf '%{VERSION}-%{RELEASE}\n' nginx-1.20.1-14.el9_2.1.x86_64.rpm
   1.20.1-14.el9_2.1
   $ rpm -q --qf '%{VERSION}-%{RELEASE}\n' nginx
   package nginx is not installed
   ```

5. Use RPM's own version comparator instead of `sort -V` guesswork:

   ```bash
   $ rpmdev-vercmp 1.20.1-14.el9_2.1 1.20.1-9.el9
   1.20.1-14.el9_2.1 > 1.20.1-9.el9
   $ echo $?
   11
   ```

   (`rpmdev-vercmp` ships in `rpm-build`/`rpmdevtools`. Exit 0 = equal, 11 = first is newer, 12 = second is newer.)

### Checkpoint questions

- **Q4.1** — Why does `rpm -ql nginx-1.20.1-14.el9_2.1.x86_64.rpm` (no `-p`) fail, and what exactly does RPM think you asked for?
- **Q4.2** — You must audit a vendor-supplied RPM in an air-gapped environment before it is allowed on the network. List four `rpm -qp` invocations that constitute a minimum review, and say what each one is looking for.
- **Q4.3** — `rpmdev-vercmp` says `1.20.1-14.el9_2.1 > 1.20.1-9.el9`. Explain why `14` sorts above `9` here but a naive lexicographic `sort` would disagree. What is the role of the `el9_2` release suffix?
- **Q4.4** — What does an `Epoch` of `1` do to version comparison, and why is it described as a one-way door for a package maintainer?

---

## Exercise 5 — Signatures and trust

A downloaded RPM is executable code that runs as root at install time via scriptlets. Signature verification is not optional in production.

### Steps

1. Check a package's signature:

   ```bash
   $ rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK
   ```

   `rpm -K` is an alias of `rpm --checksig`; the standalone binary `rpmkeys --checksig` does the same.

2. See what "OK" actually verified:

   ```bash
   $ rpm -Kv /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm:
       Header V4 RSA/SHA256 Signature, key ID 350d275d: OK
       Header SHA256 digest: OK
       Header SHA1 digest: OK
       Payload SHA256 digest: OK
       V4 RSA/SHA256 Signature, key ID 350d275d: OK
       MD5 digest: OK
   ```

3. List the trusted keys. Keys are stored *as pseudo-packages* in the RPM database:

   ```bash
   $ rpm -qa gpg-pubkey\* --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'
   gpg-pubkey-350d275d-63db5ec2 Rocky Enterprise Software Foundation - Release Engineering <releng@rockylinux.org> public key
   ```

4. Inspect one key in full:

   ```bash
   $ rpm -qi gpg-pubkey-350d275d-63db5ec2
   ```

5. Simulate the untrusted case. Remove the key, re-check, then re-import:

   ```bash
   # rpm -e gpg-pubkey-350d275d-63db5ec2
   # rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   warning: /tmp/pkgs/nginx-...rpm: Header V4 RSA/SHA256 Signature, key ID 350d275d: NOKEY
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests SIGNATURES NOT OK
   # echo $?
   1

   # rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   # rpm -K /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm
   /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm: digests signatures OK
   ```

6. Demonstrate tamper detection on the payload:

   ```bash
   # cp /tmp/pkgs/nginx-1.20.1-14.el9_2.1.x86_64.rpm /tmp/tampered.rpm
   # printf 'X' | dd of=/tmp/tampered.rpm bs=1 seek=400000 conv=notrunc 2>/dev/null
   # rpm -Kv /tmp/tampered.rpm
   /tmp/tampered.rpm:
       Header V4 RSA/SHA256 Signature, key ID 350d275d: OK
       Header SHA256 digest: OK
       Header SHA1 digest: OK
       Payload SHA256 digest: BAD (Expected 8b1e...  != 4f39...)
       V4 RSA/SHA256 Signature, key ID 350d275d: BAD
       MD5 digest: BAD (Expected 6b0d... != a2c1...)
   ```

7. Observe where the repository-level policy lives:

   ```bash
   $ grep -r gpgcheck /etc/dnf/dnf.conf /etc/yum.repos.d/*.repo
   /etc/dnf/dnf.conf:gpgcheck=1
   /etc/yum.repos.d/rocky.repo:gpgcheck=1
   /etc/yum.repos.d/rocky.repo:gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   ```

### Checkpoint questions

- **Q5.1** — In step 6, the *header* signature stayed `OK` while the payload digest went `BAD`. Explain RPM's two-part signing model and why a header-only signature is still meaningful.
- **Q5.2** — `rpm -K` on an unsigned but intact package prints `digests OK` — note the missing word. Write the exact difference between that output and `digests signatures OK`, and say which one a CI gate should require.
- **Q5.3** — Why are GPG keys stored as packages named `gpg-pubkey-<keyid>-<timestamp>`? What operational advantage does that give you over a keyring file?
- **Q5.4** — A junior engineer fixes a failing install with `dnf install --nogpgcheck`. Describe the precise attack this disables, and give the correct fix for the two most common root causes of that failure.
- **Q5.5** — `gpgcheck=1` in `/etc/dnf/dnf.conf` versus `gpgcheck=1` inside a `[repo]` stanza: which wins, and what is `localpkg_gpgcheck` for?

---

## Exercise 6 — Verification: what changed since install

`rpm -V` compares the filesystem against the metadata stored at install time. It is the cheapest host-integrity check you already own.

### Steps

1. Verify a clean package — silence means success:

   ```bash
   $ rpm -V bash
   $ echo $?
   0
   ```

2. Break things deliberately:

   ```bash
   # echo '# tampered' >> /etc/skel/.bashrc          # config file: content + size + mtime
   # chmod 777 /usr/bin/passwd                        # mode
   # chown nobody /usr/bin/wc                         # owner
   # rm -f /usr/share/doc/bash/AUTHORS                # missing doc file
   ```

3. Verify again and read the output as a fixed-width flag field:

   ```bash
   # rpm -V bash
   S.5....T.  c /etc/skel/.bashrc
   missing     /usr/share/doc/bash/AUTHORS

   # rpm -V passwd
   .M.......    /usr/bin/passwd

   # rpm -V coreutils
   .....U...    /usr/bin/wc
   ```

   The nine positions, in order:

   | Pos | Code | Meaning |
   |---|---|---|
   | 1 | `S` | file **S**ize differs |
   | 2 | `M` | **M**ode differs (permissions + type) |
   | 3 | `5` | digest (MD5/SHA) differs |
   | 4 | `D` | **D**evice major/minor mismatch |
   | 5 | `L` | read**L**ink path mismatch |
   | 6 | `U` | **U**ser ownership differs |
   | 7 | `G` | **G**roup ownership differs |
   | 8 | `T` | m**T**ime differs |
   | 9 | `P` | ca**P**abilities differ |

   A `.` means that test passed; a `?` means the test could not be performed (usually unreadable file). The letter after the flags is the file's attribute marker: `c` config, `d` doc, `g` ghost, `l` license, `r` readme.

4. Verify by file rather than by package:

   ```bash
   # rpm -Vf /usr/bin/passwd
   .M.......    /usr/bin/passwd
   ```

5. Verify the whole system, filtering the expected noise:

   ```bash
   # rpm -Va --nomtime --nordev 2>/dev/null | grep -v '^\.\{8\}' | head -20
   ```

6. Repair permissions and ownership from metadata — this is the correct fix, not `chmod` from memory:

   ```bash
   # rpm --setperms passwd
   # rpm --setugids coreutils
   # rpm -V passwd coreutils
   # echo $?
   0
   ```

7. Restore missing/altered non-config content by reinstalling the payload:

   ```bash
   # dnf -y reinstall bash
   # rpm -V bash
   S.5....T.  c /etc/skel/.bashrc
   ```

   Note that the config file stayed modified. That is deliberate.

8. Confirm what `reinstall` did with your edited config:

   ```bash
   # ls -l /etc/skel/.bashrc*
   ```

### Checkpoint questions

- **Q6.1** — Decode `S.5....T.  c /etc/skel/.bashrc` flag by flag, and explain why `M`, `U` and `G` are dots.
- **Q6.2** — After `dnf reinstall bash`, `/usr/share/doc/bash/AUTHORS` came back but `/etc/skel/.bashrc` kept your edit. Explain the `%config` versus `%config(noreplace)` mechanism and the `.rpmnew` / `.rpmsave` naming rule — including which operation produces which suffix.
- **Q6.3** — `rpm -Va` on a long-lived production host prints hundreds of lines. Name three categories of finding that are *expected* and harmless, and explain why `rpm -Va` alone is not a substitute for AIDE or a signed-baseline HIDS.
- **Q6.4** — Why is `rpm --setperms` safe to run but `rpm --setugids` occasionally dangerous? Consider a package whose files were intentionally chowned to a service account by a site policy.
- **Q6.5** — An attacker with root modifies `/usr/bin/sshd` **and** the RPM database. What does `rpm -V` report, and what is the architectural lesson about where an integrity baseline must live?

---

## Exercise 7 — Installing, upgrading, freshening and removing with `rpm(8)`

`rpm` does not resolve dependencies. It reports them and stops. Understanding this is the whole point of DNF's existence.

### Steps

1. Dry-run first. `--test` performs the full transaction check and commits nothing:

   ```bash
   # cd /tmp/pkgs
   # rpm -ivh --test nginx-1.20.1-14.el9_2.1.x86_64.rpm
   error: Failed dependencies:
           nginx-core = 1:1.20.1-14.el9_2.1 is needed by nginx-1:1.20.1-14.el9_2.1.x86_64
           nginx-filesystem = 1:1.20.1-14.el9_2.1 is needed by nginx-1:1.20.1-14.el9_2.1.x86_64
   ```

2. Satisfy the dependencies yourself by naming every RPM in one transaction:

   ```bash
   # rpm -ivh nginx-*.rpm
   Verifying...                       ################################# [100%]
   Preparing...                       ################################# [100%]
   Updating / installing...
      1:nginx-filesystem-1:1.20.1-14.el9 ################################# [ 33%]
      2:nginx-core-1:1.20.1-14.el9_2.1   ################################# [ 67%]
      3:nginx-1:1.20.1-14.el9_2.1        ################################# [100%]
   ```

   `-i` install, `-v` verbose, `-h` hash progress bar.

3. Understand `-i` versus `-U` versus `-F` empirically. First, downgrade-then-upgrade:

   ```bash
   # rpm -q nginx
   nginx-1.20.1-14.el9_2.1.x86_64

   # rpm -Uvh nginx-1.20.1-14.el9_2.1.x86_64.rpm
   package nginx-1:1.20.1-14.el9_2.1.x86_64 is already installed

   # rpm -Uvh --replacepkgs nginx-1.20.1-14.el9_2.1.x86_64.rpm    # forces re-install
   ```

4. Freshen. `-F` upgrades a package **only if an older version is already installed**:

   ```bash
   # rpm -Fvh /tmp/pkgs/*.rpm          # silently skips anything not installed
   # rpm -q httpd
   package httpd is not installed
   # rpm -Fvh httpd-2.4.53-11.el9_2.5.x86_64.rpm   # no output, nothing installed
   ```

   This is the tool for "patch what this machine has, install nothing new".

5. Removal, and the dependency wall:

   ```bash
   # rpm -e nginx-core
   error: Failed dependencies:
           nginx-core = 1:1.20.1-14.el9_2.1 is needed by (installed) nginx-1:1.20.1-14.el9_2.1.x86_64

   # rpm -e nginx nginx-core nginx-filesystem      # correct: one transaction
   ```

6. See the escape hatches — and why they are last resorts:

   ```bash
   # rpm -ivh --nodeps somepkg.rpm      # install a package whose deps are unmet
   # rpm -e  --nodeps somepkg           # remove a package others depend on
   # rpm -Uvh --oldpackage older.rpm    # deliberate downgrade
   # rpm -Uvh --force newpkg.rpm        # = --replacepkgs --replacefiles --oldpackage
   # rpm -ivh --noscripts pkg.rpm       # skip %pre/%post
   ```

7. The kernel exception. Kernels are *install-only*, never upgraded in place:

   ```bash
   $ grep -E 'installonly' /etc/dnf/dnf.conf
   installonly_limit=3
   $ rpm -q kernel                # on a real VM, expect several versions
   kernel-5.14.0-284.11.1.el9_2.x86_64
   kernel-5.14.0-284.18.1.el9_2.x86_64
   ```

8. Install into an alternate root — the technique behind image builds and rescue:

   ```bash
   # mkdir -p /tmp/altroot
   # rpm -ivh --root /tmp/altroot --nodeps filesystem-3.16-2.el9.x86_64.rpm
   # rpm -qa --root /tmp/altroot
   filesystem-3.16-2.el9.x86_64
   ```

### Checkpoint questions

- **Q7.1** — State the behaviour of `-i`, `-U` and `-F` for each of these three starting states: package absent, older version installed, same version installed. A 3×3 table is the expected answer.
- **Q7.2** — Why does `rpm -Uvh kernel-5.14.0-284.18.1.el9_2.x86_64.rpm` constitute an outage risk, and what makes `installonlypkgs` the correct mechanism rather than administrator discipline?
- **Q7.3** — `rpm -e --nodeps glibc` will run. Describe what state the machine is in one second later and why no `rpm` command can recover it.
- **Q7.4** — You installed three nginx RPMs in a single `rpm -ivh nginx-*.rpm`. Why did that work when installing them one at a time in the same order would also have worked, but installing `nginx` first would not?
- **Q7.5** — `--force` is documented as the union of three flags. Name them and give one scenario in which `--replacefiles` alone is the right, narrow choice.
- **Q7.6** — What does `rpm -ivh --justdb` do, and name a legitimate recovery scenario for it.

---

## Exercise 8 — `rpm2cpio`: extraction without installation

You need one file out of a package, on a host you must not modify, or from a package for another distribution entirely.

### Steps

1. List a package's payload as an archive:

   ```bash
   $ cd /tmp/pkgs
   $ rpm2cpio nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -t | head
   ./etc/logrotate.d/nginx
   ./etc/nginx/fastcgi.conf
   ./etc/nginx/fastcgi_params
   ./etc/nginx/mime.types
   ./etc/nginx/nginx.conf
   ...
   ```

   Note the leading `./` — payload paths are **relative**. This is what keeps extraction from overwriting the live filesystem.

2. Extract everything into a scratch directory:

   ```bash
   $ mkdir -p /tmp/extract && cd /tmp/extract
   $ rpm2cpio /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | cpio -idmv
   ./etc/logrotate.d/nginx
   ./etc/nginx/fastcgi.conf
   ...
   3204 blocks
   ```

   `-i` extract, `-d` create directories, `-m` preserve mtimes, `-v` verbose.

3. Extract a single file with a pattern:

   ```bash
   $ cd /tmp/extract && rm -rf etc usr var
   $ rpm2cpio /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm \
       | cpio -idmv './etc/nginx/nginx.conf'
   ./etc/nginx/nginx.conf
   3204 blocks
   $ find . -type f
   ./etc/nginx/nginx.conf
   ```

4. The recovery pattern: restore one clobbered binary without a full reinstall:

   ```bash
   # rpm -qf /usr/bin/wc
   coreutils-8.32-34.el9.x86_64
   # dnf download --destdir=/tmp/pkgs coreutils
   # cd /tmp/extract && rpm2cpio /tmp/pkgs/coreutils-8.32-34.el9.x86_64.rpm \
       | cpio -idmv './usr/bin/wc'
   # install -o root -g root -m 0755 /tmp/extract/usr/bin/wc /usr/bin/wc
   # rpm -Vf /usr/bin/wc
   ```

5. The modern alternative, `rpm2archive` (RPM ≥ 4.14) — emits a tar stream, which handles paths > 110 characters and large files that ancient cpio formats cannot:

   ```bash
   $ rpm2archive - < /tmp/pkgs/coreutils-8.32-34.el9.x86_64.rpm | tar -tzf - | head -3
   ./usr/bin/[
   ./usr/bin/arch
   ./usr/bin/b2sum
   ```

6. Prove that extraction bypasses everything RPM does:

   ```bash
   $ rpm -q --scripts /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm 2>/dev/null
   $ rpm -qp --scripts /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm | head
   ```

   The scriptlets live in the **header**, not the payload. `rpm2cpio` gives you only the payload.

### Checkpoint questions

- **Q8.1** — Name four things that `rpm2cpio | cpio -idmv` does **not** do that `rpm -i` does. Which one most often causes "I extracted it and the service still won't start"?
- **Q8.2** — Why does `cpio -idmv '/etc/nginx/nginx.conf'` (leading slash) extract nothing, while `'./etc/nginx/nginx.conf'` works?
- **Q8.3** — RPM 4.14+ packages may use a `zstd` payload compressor. Does `rpm2cpio` still work? What does that tell you about where the decompression happens, and why does `cpio` never need to know?
- **Q8.4** — You are on a Debian rescue system with no `rpm` binary at all, and you need one file from an `.rpm`. Give a viable approach.
- **Q8.5** — After the step-4 recovery, `rpm -Vf /usr/bin/wc` reports clean. Explain why `dnf reinstall coreutils` would nonetheless have been the better answer in production.

---

## Exercise 9 — Repository configuration: `/etc/yum.conf` and `/etc/yum.repos.d/`

### Steps

1. Establish what `yum` even is on a modern system:

   ```bash
   $ ls -l /usr/bin/yum
   lrwxrwxrwx. 1 root root 5 Jan 11 2023 /usr/bin/yum -> dnf-3
   $ ls -l /etc/yum.conf
   lrwxrwxrwx. 1 root root 12 Jan 11 2023 /etc/yum.conf -> dnf/dnf.conf
   ```

2. Read the global configuration:

   ```bash
   $ cat /etc/dnf/dnf.conf
   [main]
   gpgcheck=1
   installonly_limit=3
   clean_requirements_on_remove=True
   best=True
   skip_if_unavailable=False
   ```

   Every option is documented in `dnf.conf(5)`. Options that matter in production:

   | Option | Effect |
   |---|---|
   | `gpgcheck` | global signature policy for repository packages |
   | `localpkg_gpgcheck` | signature policy for `dnf install ./file.rpm` (default `False`) |
   | `installonly_limit` | how many kernels to retain |
   | `clean_requirements_on_remove` | auto-remove orphaned dependencies on `remove` |
   | `best` | fail rather than install an older version to satisfy a solve |
   | `skip_if_unavailable` | continue when a repo is unreachable (dangerous: silent partial views) |
   | `keepcache` | retain downloaded RPMs under `/var/cache/dnf` |
   | `exclude` | global package blacklist |
   | `max_parallel_downloads` | 1–20, default 3 |

3. Examine repository definitions:

   ```bash
   $ ls /etc/yum.repos.d/
   rocky-addons.repo  rocky-devel.repo  rocky-extras.repo  rocky.repo
   $ sed -n '1,12p' /etc/yum.repos.d/rocky.repo
   [baseos]
   name=Rocky Linux $releasever - BaseOS
   #baseurl=http://dl.rockylinux.org/$contentdir/$releasever/BaseOS/$basearch/os/
   mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=$basearch&repo=BaseOS-$releasever
   gpgcheck=1
   enabled=1
   countme=1
   metadata_expire=6h
   gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
   ```

4. Resolve the variables:

   ```bash
   $ python3 -c "import dnf; b=dnf.Base(); print(b.conf.substitutions)"
   {'arch': 'x86_64', 'basearch': 'x86_64', 'releasever': '9', ...}
   $ ls /etc/dnf/vars/
   contentdir  releasever
   $ cat /etc/dnf/vars/contentdir
   pub/rocky
   ```

   Any file in `/etc/dnf/vars/` becomes `$filename`, usable in `baseurl`. This is how you parameterise a mirror per datacentre.

5. List and inspect repositories:

   ```bash
   $ dnf repolist
   repo id      repo name
   appstream    Rocky Linux 9 - AppStream
   baseos       Rocky Linux 9 - BaseOS
   extras       Rocky Linux 9 - Extras

   $ dnf repolist --all | head
   $ dnf repoinfo baseos
   Repo-id            : baseos
   Repo-name          : Rocky Linux 9 - BaseOS
   Repo-revision      : 1692...
   Repo-updated       : Sun 20 Aug 2026 04:11:32 AM UTC
   Repo-pkgs          : 6 289
   Repo-available-pkgs: 6 289
   Repo-size          : 7.4 G
   Repo-mirrors       : https://mirrors.rockylinux.org/mirrorlist?...
   Repo-baseurl       : http://mirror.example.net/rocky/9/BaseOS/x86_64/os/
   Repo-expire        : 21 600 second(s) (last: Wed 20 Aug 2026 09:12:00 AM UTC)
   Repo-filename      : /etc/yum.repos.d/rocky.repo
   ```

6. Add a repository by hand — the authoritative method, and the only one guaranteed present:

   ```bash
   # cat > /etc/yum.repos.d/local-lab.repo <<'EOF'
   [local-lab]
   name=Local lab packages
   baseurl=file:///srv/repo/$releasever/$basearch/
   enabled=1
   gpgcheck=1
   gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-lab
   priority=10
   metadata_expire=60
   EOF
   ```

7. Build that local repository so it actually resolves:

   ```bash
   # dnf -y install createrepo_c
   # mkdir -p /srv/repo/9/x86_64 && cp /tmp/pkgs/*.rpm /srv/repo/9/x86_64/
   # createrepo_c /srv/repo/9/x86_64/
   # dnf --disablerepo='*' --enablerepo='local-lab' --nogpgcheck list available
   ```

8. Toggle repositories persistently and per-invocation:

   ```bash
   # dnf config-manager --set-disabled local-lab       # writes enabled=0 into the .repo file
   # dnf config-manager --set-enabled  local-lab
   # dnf --enablerepo=devel --disablerepo=extras list available kernel   # this run only
   ```

   On Fedora 41+ / DNF 5 the equivalent is `dnf config-manager setopt local-lab.enabled=0`.

9. Manage the metadata cache:

   ```bash
   # du -sh /var/cache/dnf
   # dnf clean all
   38 files removed
   # dnf makecache
   # dnf --refresh check-update      # force metadata refresh regardless of metadata_expire
   ```

### Checkpoint questions

- **Q9.1** — Given `/etc/yum.conf -> dnf/dnf.conf`, will an exam question about "editing `/etc/yum.conf`" still be correct on RHEL 9? Explain what the symlink preserves and what it does not (name one YUM 3 option DNF ignores).
- **Q9.2** — A repo stanza has both `baseurl` and `mirrorlist` uncommented. Which does DNF use? Now explain the *operational* reason a `.repo` file ships with `baseurl` commented out.
- **Q9.3** — `skip_if_unavailable=True` is set globally on a fleet. Describe the failure mode where this turns a network blip into a silent security regression.
- **Q9.4** — You must point 300 hosts at a regional mirror without editing 300 `.repo` files. Describe the `/etc/dnf/vars/` approach, including the exact file you create and the `baseurl` you write.
- **Q9.5** — `priority=10` appears in your stanza. Is that honoured by stock DNF? What must be installed, and what is the difference between `priority` and `cost`?
- **Q9.6** — What is the practical difference between `dnf clean all` and `dnf --refresh <cmd>`? Which is safe to run in a cron job on a metered link?

---

## Exercise 10 — Everyday `dnf`/`yum` operations

### Steps

1. Search and identify:

   ```bash
   $ dnf search nginx
   $ dnf info httpd
   Available Packages
   Name         : httpd
   Version      : 2.4.53
   Release      : 11.el9_2.5
   Architecture : x86_64
   Size         : 45 k
   Source       : httpd-2.4.53-11.el9_2.5.src.rpm
   Repository   : appstream
   Summary      : Apache HTTP Server
   URL          : https://httpd.apache.org/
   License      : ASL 2.0
   ```

2. The reverse lookup that spans the whole repository, not just installed packages:

   ```bash
   $ dnf provides /usr/sbin/semanage
   policycoreutils-python-utils-3.5-1.el9.noarch : SELinux policy core python utilities
   Repo        : appstream
   Matched from:
   Filename    : /usr/sbin/semanage

   $ dnf provides '*/bin/htpasswd'
   httpd-tools-2.4.53-11.el9_2.5.x86_64 : Tools for use with the Apache HTTP Server
   ```

   This is the single most valuable DNF subcommand: it answers "command not found" definitively.

3. Listing modes:

   ```bash
   $ dnf list --installed 'kernel*'
   $ dnf list --available 'nginx*'
   $ dnf list --upgrades
   $ dnf list --extras        # installed, but in no enabled repository
   $ dnf list --obsoletes
   $ dnf list --recent
   ```

4. Check for updates, and read the exit code — this is how monitoring integrates:

   ```bash
   $ dnf check-update
   ...
   $ echo $?
   100
   ```

   `0` = no updates, `100` = updates available, `1` = error. `dnf check-update` never modifies anything.

5. Install, reinstall, upgrade, downgrade, remove:

   ```bash
   # dnf -y install httpd
   # dnf -y reinstall httpd
   # dnf -y upgrade httpd            # upgrade, not update; 'update' is a kept alias
   # dnf -y downgrade httpd
   # dnf -y remove httpd
   ```

6. Watch `clean_requirements_on_remove` in action, then find real orphans:

   ```bash
   # dnf -y install httpd
   # dnf -y remove httpd | grep -A20 'Removing dependent\|Removing unused'
   # dnf -y autoremove
   ```

7. Control the solver:

   ```bash
   # dnf install --setopt=install_weak_deps=False vim-enhanced     # skip Recommends
   # dnf install --nobest nginx                                    # accept an older version
   # dnf install --allowerasing some-conflicting-pkg               # permit removals to solve
   # dnf install --downloadonly --downloaddir=/tmp/stage nginx
   # dnf install /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm  # local file, deps from repos
   ```

8. Correct the "installed by user vs pulled as dependency" flag, which drives `autoremove`:

   ```bash
   # dnf mark install nginx-core     # protect from autoremove (DNF5: dnf mark user)
   # dnf mark remove nginx-core      # demote to dependency (DNF5: dnf mark dependency)
   $ dnf repoquery --userinstalled | head
   ```

9. Distribution-synchronise — force every package to exactly what the repos publish, including downgrades:

   ```bash
   # dnf distro-sync --assumeno
   ```

### Checkpoint questions

- **Q10.1** — Give the precise semantic difference between `dnf upgrade foo`, `dnf install foo` (when `foo` is already installed) and `dnf distro-sync foo`.
- **Q10.2** — `dnf check-update` exits `100`. Why was a non-zero code chosen for the *normal* "there are updates" case, and what does that break in a naive `set -e` script?
- **Q10.3** — `dnf list --extras` returns `zabbix-agent`. Enumerate three ways a package can end up in that state, and say which one is a supply-chain concern.
- **Q10.4** — Explain `best=True` (the default on RHEL 9) using a concrete conflict, and say what `--nobest` trades away.
- **Q10.5** — After `dnf remove httpd`, `/etc/httpd/conf/httpd.conf` is gone but `/etc/httpd/conf.d/myapp.conf` survives. Explain both outcomes from RPM's file-ownership rules.
- **Q10.6** — Why is `dnf install ./local.rpm` categorically different from `rpm -i ./local.rpm`, and which `dnf.conf` option governs signature checking for that case?

---

## Exercise 11 — `repoquery`: reading the dependency graph

`dnf repoquery` is `rpm -q` extended over repository metadata for packages that are not installed. It is read-only and requires no root.

### Steps

1. Query files in a package you have never installed:

   ```bash
   $ dnf repoquery -l httpd | head
   /etc/httpd
   /etc/httpd/conf
   /etc/httpd/conf.d
   /etc/httpd/conf.d/README
   /etc/httpd/conf.d/autoindex.conf
   ...
   ```

2. Walk dependencies in both directions:

   ```bash
   $ dnf repoquery --requires httpd
   $ dnf repoquery --requires --resolve httpd | head     # capability -> package name
   apr-1.7.0-11.el9.x86_64
   apr-util-1.6.1-20.el9.x86_64
   httpd-core-2.4.53-11.el9_2.5.x86_64
   ...
   $ dnf repoquery --whatrequires httpd-tools
   $ dnf repoquery --whatprovides '/usr/sbin/httpd'
   ```

3. Compute the full recursive closure — what actually lands on disk:

   ```bash
   $ dnf repoquery --requires --resolve --recursive httpd | wc -l
   64
   ```

4. Query weak dependencies, which explain surprise packages:

   ```bash
   $ dnf repoquery --recommends httpd
   $ dnf repoquery --supplements '*'  | head
   ```

5. Constrain to the installed set, or to a specific repository:

   ```bash
   $ dnf repoquery --installed --qf '%{name} %{evr} %{from_repo}\n' | head
   $ dnf repoquery --repo=appstream --qf '%{name}\n' | wc -l
   ```

6. Find installed packages that no longer come from any enabled repo, and duplicates:

   ```bash
   $ dnf repoquery --extras
   $ dnf repoquery --duplicates
   $ dnf repoquery --unsatisfied
   ```

7. Trace a source RPM back to its binaries — essential when a CVE advisory names the SRPM:

   ```bash
   $ dnf repoquery --qf '%{name}-%{evr}.%{arch} <- %{sourcerpm}\n' httpd
   httpd-0:2.4.53-11.el9_2.5.x86_64 <- httpd-2.4.53-11.el9_2.5.src.rpm
   $ dnf repoquery --whatrequires 'httpd-core' --alldeps
   ```

8. Answer an impact question end to end: *"if I upgrade `openssl-libs`, which installed packages link against it?"*

   ```bash
   $ dnf repoquery --installed --whatrequires 'libssl.so.3()(64bit)' | head
   ```

### Checkpoint questions

- **Q11.1** — Contrast `rpm -q --whatrequires foo` with `dnf repoquery --whatrequires foo`. Which sees packages that are not installed, and which sees *provides* satisfied by a different package name?
- **Q11.2** — `dnf repoquery --requires httpd` lists capabilities like `libapr-1.so.0()(64bit)`. What does adding `--resolve` change, and why is the unresolved form still the more accurate representation of the dependency?
- **Q11.3** — `dnf repoquery --duplicates` returns two `kernel-devel` versions. Is that a problem? Now suppose it returns two `glibc` versions — is *that* a problem, and what caused it?
- **Q11.4** — A security advisory says "fixed in `nginx-1.20.1-14.el9_2.1.src.rpm`". Give the command that tells you which installed binary packages are affected on this host.

---

## Exercise 12 — Transaction history and rollback

DNF records every transaction in `/var/lib/dnf/history.sqlite`. This is the audit log and the undo stack.

### Steps

1. Read the history:

   ```bash
   # dnf history list | head
   ID     | Command line             | Date and time    | Action(s)      | Altered
   -------------------------------------------------------------------------------
        8 | -y install httpd         | 2026-08-20 09:31 | Install        |   12
        7 | -y remove nginx          | 2026-08-20 09:28 | Removed        |    3
        6 | -y install nginx         | 2026-08-20 09:25 | Install        |    3
   ```

2. Inspect one transaction in full:

   ```bash
   # dnf history info 8
   Transaction ID : 8
   Begin time     : Wed 20 Aug 2026 09:31:02 AM UTC
   Begin rpmdb    : 243:5f2a...
   End time       : Wed 20 Aug 2026 09:31:14 AM UTC (12 seconds)
   End rpmdb      : 255:9b1c...
   User           : root <root>
   Return-Code    : Success
   Releasever     : 9
   Command Line   : -y install httpd
   Packages Altered:
       Install httpd-2.4.53-11.el9_2.5.x86_64        @appstream
       Install httpd-core-2.4.53-11.el9_2.5.x86_64   @appstream
       ...
   ```

3. Query history by package — "who installed this and when":

   ```bash
   # dnf history list httpd
   # dnf history userinstalled | head
   ```

4. Undo, redo and roll back:

   ```bash
   # dnf history undo 8          # invert transaction 8 only
   # dnf history redo 8          # repeat transaction 8
   # dnf history rollback 6      # revert everything after ID 6
   ```

5. Confirm the effect, then re-establish a known state:

   ```bash
   # dnf history undo last
   # rpm -qa | sort > /root/current-packages.txt
   # diff /root/baseline-packages.txt /root/current-packages.txt
   ```

6. Note where `undo` cannot help:

   ```bash
   # dnf history info 8 | grep -i 'Return-Code'
   ```

### Checkpoint questions

- **Q12.1** — Distinguish `dnf history undo 8`, `dnf history rollback 8` and `dnf history redo 8` on a system currently at transaction 12.
- **Q12.2** — `dnf history undo` of an upgrade transaction reinstalls the older packages. Name three things it does **not** restore, and explain why "rollback" is a misleading word for it.
- **Q12.3** — What are `Begin rpmdb` and `End rpmdb` checksums for, and what does it mean when `dnf history` reports the database was altered outside DNF?
- **Q12.4** — A `dnf history undo` refuses to run because the older packages are no longer in any repository. Give two ways to proceed, and state the `dnf.conf` setting that would have prevented the situation.

---

## Exercise 13 — Groups, modules and version locking

### Steps

1. Groups — a repository-defined bundle, not an RPM concept:

   ```bash
   $ dnf group list
   Available Environment Groups:
      Server with GUI
      Minimal Install
   Available Groups:
      Container Management
      Development Tools
      ...
   $ dnf group info "Development Tools" | head -20
   # dnf -y group install "Development Tools"
   # dnf group list --installed
   # dnf -y group remove "Development Tools"
   ```

   Note that `dnf install @"Development Tools"` is the equivalent shorthand.

2. Modular content (RHEL 8/9 AppStream) — parallel versions of the same application:

   ```bash
   $ dnf module list nodejs
   Name     Stream   Profiles                     Summary
   nodejs   18 [d]   common [d], development,...  Javascript runtime
   nodejs   20       common [d], development,...  Javascript runtime
   # dnf -y module enable nodejs:20
   # dnf -y module install nodejs:20/common
   $ dnf module list --enabled
   # dnf -y module reset nodejs
   ```

3. Version locking — pin a package against upgrades:

   ```bash
   # dnf versionlock add nginx
   Adding versionlock on: nginx-1:1.20.1-14.el9_2.1
   # dnf versionlock list
   nginx-1:1.20.1-14.el9_2.1.*
   $ cat /etc/dnf/plugins/versionlock.list
   # dnf upgrade nginx
   Package nginx is excluded by versionlock.
   Nothing to do.
   # dnf versionlock delete nginx
   ```

4. The blunt alternative — global excludes:

   ```bash
   # grep -n '^exclude' /etc/dnf/dnf.conf
   # dnf --disableexcludes=all upgrade kernel
   ```

### Checkpoint questions

- **Q13.1** — Where do group definitions live? Prove they are not stored in the RPM database, and explain what breaks when a repository is disabled after you installed one of its groups.
- **Q13.2** — Explain the difference between `dnf module reset nodejs` and `dnf module disable nodejs`. Which is the correct precursor to switching streams, and why does the other cause a solve failure?
- **Q13.3** — `versionlock` versus `exclude=` in `dnf.conf` versus `--exclude=` on the command line: rank the three by scope and persistence, and say which one still allows a *security* patch through.
- **Q13.4** — A pinned `nginx` blocks a `dnf upgrade` of the whole system with a dependency conflict. What is the exact failure the solver reports, and what is the least-damaging resolution?

---

## Exercise 14 — `zypper` on openSUSE

Switch to the `lpic-zypper` container. Zypper is a different front end over the same RPM back end — the `rpm` half of this objective transfers unchanged.

### Steps

1. Locate the configuration. Note the paths are *not* `/etc/yum*`:

   ```bash
   $ ls /etc/zypp/
   credentials.d  locks  repos.d  services.d  systemCheck.d  zypp.conf  zypper.conf
   $ ls /etc/zypp/repos.d/
   repo-oss.repo  repo-non-oss.repo  repo-update.repo
   $ cat /etc/zypp/repos.d/repo-oss.repo
   [repo-oss]
   name=Main Repository
   enabled=1
   autorefresh=1
   baseurl=http://download.opensuse.org/distribution/leap/$releasever/repo/oss/
   type=rpm-md
   gpgcheck=1
   gpgkey=http://download.opensuse.org/distribution/leap/$releasever/repo/oss/repodata/repomd.xml.key
   ```

2. Repository management:

   ```bash
   # zypper lr -uEP                       # list: URI, Enabled only, Priority
   #  | Alias       | Name              | Enabled | GPG Check | Refresh | Priority | URI
   # --+-------------+-------------------+---------+-----------+---------+----------+-----
   #  1| repo-oss    | Main Repository   | Yes     | (r ) Yes  | Yes     |   99     | http://...
   #
   # zypper ar -f -n "Packman" https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Leap_15.6/ packman
   # zypper mr -p 90 packman              # modify priority (lower number = higher priority)
   # zypper mr -d packman                 # disable
   # zypper mr -e packman                 # enable
   # zypper ref                           # refresh metadata
   # zypper rr packman                    # remove repository
   ```

3. Search and inspect:

   ```bash
   $ zypper se nginx                      # search
   $ zypper se -s -i bash                 # detailed, installed only
   $ zypper if bash                       # info
   $ zypper wp /bin/bash                  # what-provides
   $ zypper pa -r repo-oss | head         # packages in a repo
   ```

4. Transactions:

   ```bash
   # zypper -n in nginx                   # -n = --non-interactive
   # zypper in -f nginx                   # force reinstall
   # zypper rm --clean-deps nginx
   # zypper up                            # upgrade installed packages, keep vendor/arch
   # zypper dup                           # distribution upgrade: allows vendor change, removals
   # zypper in --dry-run nginx
   ```

5. Patches — the SUSE concept with no DNF equivalent:

   ```bash
   # zypper lp                            # list-patches
   # zypper patch-check
   # zypper patch --category security
   ```

6. Health and locks:

   ```bash
   # zypper ve                            # verify dependency consistency, offer repairs
   # zypper ps                            # processes still using deleted libraries
   # zypper al nginx                      # addlock (equivalent of versionlock)
   # zypper ll                            # list locks -> /etc/zypp/locks
   # zypper rl nginx                      # removelock
   ```

7. Read the exit codes, which are richer than DNF's:

   ```bash
   # zypper patch-check; echo "exit=$?"
   ```

   | Code | Meaning |
   |---|---|
   | 0 | success / nothing to do |
   | 100 | patches available |
   | 101 | security patches available |
   | 102 | reboot required |
   | 103 | zypper itself was updated — restart it |
   | 104 | capability not found |
   | 106 | some repository could not be refreshed |

### Checkpoint questions

- **Q14.1** — Map each of these DNF commands to its zypper equivalent: `dnf provides`, `dnf repolist`, `dnf list --installed`, `dnf config-manager --set-disabled`, `dnf autoremove`.
- **Q14.2** — Explain the difference between `zypper up` and `zypper dup` in terms of vendor changes and package removals. Which one do you use after adding Packman, and why is the other one wrong?
- **Q14.3** — Zypper priorities: a repository with `priority=90` versus one with `priority=99`. Which wins, and how does that convention differ from the DNF `priority` plugin? (Careful — this is a common cross-distribution error.)
- **Q14.4** — `zypper ps` reports `httpd` using deleted files after an upgrade. What happened at the filesystem level, and why is a service restart mandatory rather than cosmetic?
- **Q14.5** — Exit code 103 has a specific operational meaning. What must an unattended patching script do when it sees it?

---

## Exercise 15 — Diagnostics under pressure

Four realistic incidents. Work each one before reading the answer.

### Incident A — corrupted RPM database

1. Reproduce (in the container only):

   ```bash
   # cp -a /var/lib/rpm /var/lib/rpm.bak
   # dd if=/dev/urandom of=/var/lib/rpm/rpmdb.sqlite bs=1 count=512 seek=8192 conv=notrunc
   # rpm -qa | head
   error: rpmdbNextIterator: skipping h#     ...
   ```

2. Recover:

   ```bash
   # rm -f /var/lib/rpm/.rpm.lock
   # rpm --rebuilddb
   # rpm -qa | wc -l
   ```

3. If `--rebuilddb` cannot help, restore from the copy DNF keeps:

   ```bash
   # ls /var/lib/rpm/  /usr/lib/sysimage/rpm/ 2>/dev/null
   # ls -d /var/lib/dnf/history.sqlite*
   ```

4. Restore your backup and move on:

   ```bash
   # rm -rf /var/lib/rpm && mv /var/lib/rpm.bak /var/lib/rpm && rpm -qa | wc -l
   ```

### Incident B — "conflicts with file from package"

1. Reproduce:

   ```bash
   # dnf -y install httpd
   # rpm -ivh --force --nodeps /tmp/pkgs/nginx-core-1.20.1-14.el9_2.1.x86_64.rpm
   ```

2. Diagnose a real file conflict:

   ```bash
   # rpm -qf /usr/share/man/man8/httpd.8.gz
   # rpm -qp --qf '[%{FILENAMES}\n]' /tmp/pkgs/nginx-core-*.rpm | sort > /tmp/new.txt
   # rpm -ql httpd | sort > /tmp/old.txt
   # comm -12 /tmp/old.txt /tmp/new.txt
   ```

### Incident C — a package that will not go away

1. Reproduce a database/filesystem divergence:

   ```bash
   # rpm -q --qf '%{NAME}\n' nginx-filesystem
   # rm -f $(rpm -ql nginx-filesystem | head -1)
   # rpm -V nginx-filesystem
   ```

2. Consider the two repairs and choose:

   ```bash
   # dnf -y reinstall nginx-filesystem      # correct
   # rpm -e --justdb nginx-filesystem       # database-only removal: leaves files orphaned
   ```

### Incident D — disk full from package cache and old kernels

1. Measure:

   ```bash
   # du -sh /var/cache/dnf /var/cache/PackageKit 2>/dev/null
   # rpm -q kernel | wc -l
   ```

2. Reclaim:

   ```bash
   # dnf clean packages
   # dnf remove --oldinstallonly --setopt=installonly_limit=2 kernel
   # grep -n 'keepcache\|installonly_limit' /etc/dnf/dnf.conf
   ```

### Checkpoint questions

- **Q15.1** — `rpm --rebuilddb` fixed Incident A. Explain exactly what it rebuilds and what it cannot recover. Why is it a no-op for a truly destroyed `Packages`/`rpmdb.sqlite`?
- **Q15.2** — In Incident B, you used `--force --nodeps` to *create* the problem. Explain why `dnf` could never have produced this state, and name the transaction-check phase that would have stopped it.
- **Q15.3** — Incident C: after `rpm -e --justdb nginx-filesystem`, what does `rpm -qf /etc/nginx` report, and what is the cleanest path back to a consistent system?
- **Q15.4** — Incident D: why does `dnf remove kernel` without qualification carry an outage risk, and what makes `--oldinstallonly` safe? What protects you at the bootloader level?
- **Q15.5** — On a host where `dnf` itself is broken (its Python stack is half-upgraded), you still have `rpm` and network access. Outline a recovery that uses only `rpm`, `rpm2cpio` and a mirror URL.

---

## Cleanup

```bash
$ exit
$ podman rm -f lpic-rpm lpic-zypper
```

---

## Official sources

- LPI — *Exam 102-500 Objectives, version 5.0* (objective 102.5): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — *Exam 101-500 Objectives, version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- RPM Project — *RPM Documentation* (`rpm(8)`, `rpm2cpio(8)`, `rpmkeys(8)`, query formats, verification flags): <https://rpm-software-management.github.io/rpm/manual/>
- RPM Project — *Package signing and verification*: <https://rpm-software-management.github.io/rpm/manual/signatures_digests.html>
- DNF Project — *DNF Command Reference*: <https://dnf.readthedocs.io/en/latest/command_ref.html>
- DNF Project — *DNF Configuration Reference (`dnf.conf(5)`)*: <https://dnf.readthedocs.io/en/latest/conf_ref.html>
- DNF Project — *DNF 5 documentation*: <https://dnf5.readthedocs.io/en/latest/>
- Red Hat — *Managing software with the DNF tool (RHEL 9)*: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_software_with_the_dnf_tool/index>
- openSUSE — *Managing Software with Command Line Tools* (zypper), openSUSE Leap Reference: <https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-sw-cl.html>
- openSUSE Wiki — *SDB:Zypper usage*: <https://en.opensuse.org/SDB:Zypper_usage>
- Fedora Project — *createrepo_c*: <https://github.com/rpm-software-management/createrepo_c>

---

<details>
<summary><strong>▶ Answers</strong> — open only after attempting every checkpoint</summary>

### Exercise 0

**A0.1** — Queries read `/var/lib/rpm/`, which is world-readable, so any user can open the database read-only. Transactions need write access to `/var/lib/rpm/` (to record the change and take `.rpm.lock`) **and** write access to the target paths under `/usr`, `/etc`, `/var` — both root-owned. Additionally, scriptlets run as root and RPM must be able to set arbitrary owner/group/capabilities on extracted files, which requires `CAP_CHOWN`/`CAP_FOWNER`/`CAP_SETFCAP`.

**A0.2** — RPM 4.16 (RHEL 9, Fedora 33+) defaults to the **sqlite** backend. `rpm -E '%{_db_backend}'` prints it — `-E` (`--eval`) expands an rpm macro, so it reports the configured value rather than what you infer from a directory listing. RHEL 8 / RPM 4.14 defaults to `bdb`.

**A0.3** — NEVRA = **N**ame `bash`, **E**poch (absent, therefore implicitly `0`), **V**ersion `5.1.8`, **R**elease `6.el9_1`, **A**rchitecture `x86_64`. Epoch is the missing one: it is omitted from display when zero. This is precisely why `rpm -qa` output cannot be fed back into a version comparison without care — use `%{EVR}` or `%{EPOCH}:%{VERSION}-%{RELEASE}` explicitly.

---

### Exercise 1

**A1.1** — (1) A different distribution or build configuration: SUSE and Fedora 41+ place the database at `/usr/lib/sysimage/rpm` with `/var/lib/rpm` as a compatibility symlink; use `rpm -E '%{_dbpath}'` and `--dbpath <path>` to point at a specific one. (2) Rescue or container-image work where the target filesystem is mounted elsewhere: use `rpm --root /mnt/sysimage -qa`, which relocates *both* the database path and the file paths.

**A1.2** —
```bash
rpm -qa --qf '%{VENDOR}|%{NAME}\n' | awk -F'|' '$1=="(none)"{print $2}'
```
Packages without a vendor were typically built locally, downloaded from an unofficial source, or produced by `alien`/`fpm`. They fall outside the distribution's signing and CVE-tracking pipeline, so no security team is watching them and no `dnf upgrade` will ever patch them.

**A1.3** — All 200 packages in a single transaction get essentially identical `INSTALLTIME` values (seconds apart, in RPM's internal ordering, not the order you'd expect), so `--last` degenerates into an arbitrary sort within that block, and it cannot distinguish "upgraded" from "freshly installed" — RPM only stores the install time of the *current* version. Use `dnf history list` / `dnf history info <id>` instead: that records the command line, the user, the action per package and the before/after rpmdb checksums.

**A1.4** — `%{SIZE}` is the **uncompressed, installed** size: the sum of the payload files' byte sizes as they land on disk. The `.rpm` file is the compressed payload (gzip/xz/zstd) plus signature and header sections. A 617 kB `nginx` RPM commonly installs 1.6 MB. Neither figure accounts for filesystem block rounding, so actual disk consumption differs again.

---

### Exercise 2

**A2.1** — `/etc/bashrc` is owned by `setup` (`rpm -qf /etc/bashrc` → `setup-2.13.7-10.el9.noarch`). Red Hat–family distributions separate the *shell binary* (`bash`) from the *system-wide shell environment* (`setup`, which also owns `/etc/profile`, `/etc/passwd`, `/etc/group`, `/etc/hosts`, `/etc/shells`). The practical consequence: a `bash` upgrade never touches `/etc/bashrc`, and site customisation of the login environment survives shell updates.

**A2.2** — `rpm -qi bash` queries the **installed** database by package name; it fails with `package bash is not installed` if it is absent. `rpm -qip <file>.rpm` adds `-p`, which reads the header directly from a **file** (or URL) and never consults the database; it fails only if the file is missing or unreadable. The first can report "not installed"; the second cannot.

**A2.3** — There is no loop because RPM resolves *capabilities*, not packages, and a package satisfies its own requirements. During the transaction check, `bash`'s `Requires: /bin/sh` is matched against the set of provides that will exist *after* the transaction, which includes `bash`'s own `Provides: /bin/sh`. For `rpm -e bash`, the erasure check finds every *other* installed package requiring `/bin/sh` — typically dozens of `%post` scriptlets and shell scripts — so the removal is refused. Self-dependency does not block it; everyone else's dependency does.

**A2.4** —
```bash
rpm -q --qf '%{NAME}-%{EVR}\n' openssl
```
compared against the known-fixed EVR (mechanically with `rpmdev-vercmp`, or `rpm --eval` on both). Version-release is authoritative because Red Hat and derivatives *backport* fixes: the upstream version number does not move, only the release does. Grepping `--changelog` for a CVE identifier is weaker because the changelog is free-form text, entries can be truncated by `%changelog` pruning at build time, and a rebuilt or third-party package may carry the fix without the text — or the text without the fix.

**A2.5** — `config(bash)` is a virtual capability whose version tracks the package's own EVR. It exists so that a **sub-package split** stays coherent: if the configuration files are later moved into a separate `bash-config` package, that package provides `config(bash) = <same EVR>`, and every consumer's dependency continues to resolve to a matching version. It also lets other packages depend on "the configuration of bash at this exact version" without depending on the binary package by name.

---

### Exercise 3

**A3.1** — (1) It was installed from a tarball or vendor installer into `/opt` or `/usr/local`, outside RPM's control. (2) `which java` resolved a symlink managed by `alternatives`; the symlink itself under `/etc/alternatives` may be unowned even though the real binary is owned — query the resolved target with `rpm -qf $(readlink -f $(which java))`. (3) It is a Snap/Flatpak/container or a language-manager install (SDKMAN, asdf) that RPM never sees.

**A3.2** — `rpm -q --whatrequires bash` matches only dependencies expressed literally as the string `bash`. Most packages depend on the *capability* `/bin/sh` instead, which `bash` provides. So the correct impact query is `rpm -q --whatrequires /bin/sh`, and in general you must union the results over every capability in `rpm -q --provides bash`. This is exactly why `dnf remove` — which resolves against the full provide set — is the right tool for impact analysis, and `rpm -q --whatrequires` is only a first look.

**A3.3** — `1`. In a script, that means `set -e` aborts on the first unowned path, and a naive `if rpm -qf "$f"` treats "unowned" identically to "rpm failed" or "no such file". Distinguish by capturing stderr, or drive the loop with `rpm -qf "$f" >/dev/null 2>&1 || echo "unowned: $f"` so the non-zero status is the expected branch rather than an error.

**A3.4** — Yes, when both packages declare the file with identical content, mode, owner and group, and at least one is not marked `%config`; RPM permits this as a shared file and installs one copy. `rpm -qf` then prints **both** package NEVRAs, one per line. If the file contents differ, the second install fails with `file ... conflicts between attempted installs` unless `--replacefiles` is given — which is the mechanism behind Incident B.

---

### Exercise 4

**A4.1** — Without `-p`, `rpm -ql` treats the argument as a **package name** to look up in the installed database. It searches for a package literally named `nginx-1.20.1-14.el9_2.1.x86_64.rpm`, finds nothing, and reports `package nginx-...rpm is not installed`. The `-p` flag is what switches the selection source from database to file.

**A4.2** — A minimum review:
1. `rpm -Kv pkg.rpm` — is it signed, by a key you trust, and is the payload intact?
2. `rpm -qp --scripts pkg.rpm` — what code runs as root at install/remove time? This is the single highest-risk surface.
3. `rpm -qlp pkg.rpm` — where does it write? Look for anything under `/etc/cron*`, `/etc/sudoers.d`, `/usr/lib/systemd/system`, `/etc/ld.so.conf.d`, or paths owned by another package.
4. `rpm -qp --requires pkg.rpm` and `rpm -qip pkg.rpm` — does it drag in unexpected dependencies, and are `Vendor`, `Packager`, `URL` and `Source RPM` consistent with the claimed origin?

A fifth worth adding: `rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' pkg.rpm | grep -E '^-..s' ` to spot setuid files.

**A4.3** — RPM's comparison algorithm splits each string into runs of digits and runs of letters, then compares run by run; **digit runs compare numerically**, so `14 > 9`. Lexicographic `sort` compares character by character, where `'1' < '9'`, giving the wrong answer. The `el9_2` suffix marks the RHEL 9.2 minor-release stream (a Z-stream build); it participates in the same segmented comparison, which is why `-14.el9_2.1` sorts above `-14.el9` — the extra `.1` segment makes it longer and therefore newer when all preceding segments are equal.

**A4.4** — Epoch is compared **first** and dominates version and release entirely: `1:1.0-1` is newer than `0:9.9-9`. It exists to escape a versioning mistake, such as upstream renumbering from `2020.05` to `1.0`. It is a one-way door because epoch can never be lowered — a package with `Epoch: 1` outranks every future `Epoch: 0` build forever, so every downstream rebuild, every derivative distribution and every third-party repository must carry the epoch from then on. Bumping it is a permanent commitment.

---

### Exercise 5

**A5.1** — RPM signs twice. The **header signature** covers the header region (all metadata, file lists, dependencies and scriptlets) plus a digest of the payload. The **payload signature/digest** (`MD5 digest`, and in V4 the combined header+payload signature) covers the compressed archive. Tampering with a payload byte breaks the payload digest and the header+payload signature, but the header itself is untouched, so its signature still verifies. The header-only signature is meaningful because everything that decides *what RPM will do* — file paths, permissions, capabilities, scriptlets — lives in the header. It also enables signature checking on packages streamed from a repository before the payload has finished downloading.

**A5.2** — `digests OK` means only that the internal checksums are self-consistent: the file is not corrupt, and nothing more. Anyone can build such a package. `digests signatures OK` means the checksums verified **and** a cryptographic signature validated against a key already imported into the RPM keyring. A CI gate must require the second, and must additionally assert *which* key ID signed it — `rpm -Kv` output containing an unexpected key ID is a failure even though it reads `OK`.

**A5.3** — Storing keys as `gpg-pubkey-<keyid>-<creation-timestamp>` pseudo-packages means the keyring inherits the whole RPM tooling for free: `rpm -qa gpg-pubkey\*` lists trust, `rpm -qi` shows the full key metadata and expiry, `rpm -e gpg-pubkey-<id>` revokes it, and the set of trusted keys is part of the same transactional database that everything else lives in — so it is captured by backups, by `dnf history` rpmdb checksums, and by configuration management that already reasons about installed packages. A separate keyring file would need its own tooling, its own auditing and its own backup story.

**A5.4** — `--nogpgcheck` disables verification that the package was signed by a trusted key, which means an attacker who can serve or modify the RPM — a compromised mirror, a hijacked DNS entry, an on-path attacker on plain HTTP, a poisoned internal repository — can ship arbitrary `%pre`/`%post` scriptlets that execute as root. The two common root causes and their correct fixes: (1) the repository's signing key is not imported → `rpm --import <gpgkey URL or file>`, or fix the `gpgkey=` line in the `.repo` stanza; (2) the package is genuinely unsigned because it is a locally built artefact → sign it (`rpm --addsign`) with an internal key and import that key, rather than disabling the check fleet-wide.

**A5.5** — The per-repository setting wins for packages from that repository; `[main]` in `dnf.conf` only supplies the default for repositories that do not state one. `localpkg_gpgcheck` is a separate switch governing packages installed from a **local file path** (`dnf install ./foo.rpm`); it defaults to `False`, which is the surprising and dangerous default — set it to `True` on production hosts.

---

### Exercise 6

**A6.1** — `S` size differs (you appended a line), `.` mode unchanged, `5` digest differs (contents changed), `.` no device mismatch, `.` not a symlink, `.` user unchanged, `.` group unchanged, `T` mtime differs (the append updated it), `.` capabilities unchanged. Then `c` marks it a `%config` file and `/etc/skel/.bashrc` is the path. `M`, `U` and `G` are dots because `echo >>` changes only content and metadata timestamps, never the mode or ownership of an existing file.

**A6.2** — `%config` files are administrator-editable, so RPM will not silently discard local changes. On **upgrade**: if you modified the file and the new package's version also differs, RPM installs the new version as `<file>.rpmnew` and leaves yours in place — for `%config(noreplace)`. For plain `%config`, RPM installs the new file and saves yours as `<file>.rpmsave`. Mnemonic: **`.rpmnew` = the new file was set aside** (your version won); **`.rpmsave` = your file was saved aside** (the package version won). On **erase**, a modified `%config` file is preserved as `.rpmsave`. `dnf reinstall` restores non-config payload files unconditionally, which is why `AUTHORS` came back, while your `.bashrc` edit was protected by the same `noreplace` logic.

**A6.3** — Expected and harmless: (1) `%config` files that you or configuration management legitimately edited — `S.5....T.  c /etc/ssh/sshd_config`; (2) `.T` mtime-only differences from backup/restore, `rsync` without `-t`, or container layer rebuilds; (3) files deliberately modified by post-install tooling — `prelink`, `authselect`, `alternatives` symlinks, `ldconfig`-generated caches, and `%ghost` files that are supposed to be absent or regenerated. `rpm -Va` is not a HIDS because its baseline — the digests in `/var/lib/rpm` — lives on the same host, mutable by the same root the attacker now has. AIDE stores a signed baseline off-host or on read-only media, covers unowned files that RPM knows nothing about, and detects the database tampering RPM cannot.

**A6.4** — `--setperms` restores modes from package metadata; modes are almost never intentionally customised per site, and getting them wrong is itself a security problem, so restoring them is the conservative act. `--setugids` restores owner and group, and that *is* commonly customised: a site may chown `/var/log/nginx` or a spool directory to a service account, or hardening may narrow a group. Running `--setugids` blindly reverts those decisions and can hand file access back to a broader group, or break a service that no longer owns its own state. Additionally, `--setugids` on a package containing setuid binaries can produce a transient window with incorrect ownership. Verify the intended deviation with `rpm -V` first, then fix targeted files.

**A6.5** — `rpm -V` reports **clean**. The verification compares the filesystem against digests stored in the very database the attacker just rewrote, so a root-level attacker closes the loop trivially (and `rpm --justdb`/`rpm --rebuilddb` make it easy). The architectural lesson: an integrity baseline is only meaningful if it is outside the trust boundary of the thing it measures — signed and stored off-host, on read-only media, or anchored in hardware (IMA/EVM with a TPM-sealed key). `rpm -V` is a good *drift* detector and a poor *intrusion* detector.

---

### Exercise 7

**A7.1** —

| | package absent | older version installed | same version installed |
|---|---|---|---|
| `rpm -i` | installs | installs **alongside** (both versions present; usually a file conflict, or two entries for install-only packages) | fails: `package ... is already installed` |
| `rpm -U` | installs | upgrades, removing the old version | fails: `already installed` (unless `--replacepkgs`) |
| `rpm -F` | **does nothing** | upgrades, removing the old version | does nothing |

The essential distinctions: `-U` installs when absent, `-F` does not; `-i` never removes the old version, `-U` and `-F` do.

**A7.2** — `-U` erases the old version, which deletes `/lib/modules/<oldver>/` while the running system is using it. Every subsequent module load fails — no new filesystem, no new network driver, no `nvidia.ko` after a hardware event — and if the new kernel does not boot, you have no previous entry to fall back to. `installonlypkgs` (with `installonly_limit`) is the correct mechanism because it makes the safety a **property of the package set enforced by the depsolver**, applied identically by every administrator, every automation run and every unattended `dnf-automatic` job. Discipline fails the first time someone types `-U` at 3 a.m.; configuration does not.

**A7.3** — `glibc` is removed from the database and its files — `/lib64/libc.so.6`, `ld-linux-x86-64.so.2`, `/lib64/libm.so.6` — are deleted. Every dynamically linked binary on the system stops working immediately: `ls`, `bash`, `rpm` itself. Already-running processes survive on their open file descriptors until they exec. No `rpm` command can recover because `rpm` is dynamically linked against the library it just deleted, so it cannot even start. Recovery requires an external root: boot rescue media, chroot into the filesystem, and reinstall glibc from there — or a statically linked busybox that was already present.

**A7.4** — RPM performs its dependency check across the **entire transaction set**, not per package. Naming all three RPMs makes them one transaction, so `nginx`'s requirement on `nginx-core` is satisfied by another member of the same set. Installing them one at a time works *only in dependency order* — `nginx-filesystem`, then `nginx-core`, then `nginx` — because each individual transaction can then be satisfied by what is already installed. Installing `nginx` first is a single-package transaction whose dependencies are unmet, so it fails. This is the entire argument for a depsolver: it computes that ordering, and the correct set, for you.

**A7.5** — `--force` = `--replacepkgs` (reinstall a package already installed) + `--replacefiles` (overwrite files owned by another package) + `--oldpackage` (permit installing an older version over a newer one). `--replacefiles` alone is right when two packages legitimately ship the same file and you have verified the contents are identical or that the conflict is a known packaging bug — for example a documentation file duplicated between a split package and its predecessor during a rename, where the vendor has confirmed the overwrite is safe. Narrow it further by checking the conflict first with `comm -12` over the two file lists, as in Incident B.

**A7.6** — `--justdb` updates the RPM database only: it records the package as installed (or removed) without touching any file on disk. Legitimate use: you restored a filesystem from a backup or an image that already contains a package's files, but the database — restored from a different point in time — does not know about it; `rpm -ivh --justdb` reconciles the two without rewriting files that are already correct. It is also used when building images layer by layer. It is dangerous precisely because it makes the database assert something it did not verify.

---

### Exercise 8

**A8.1** — Extraction does **not**: (1) run `%pre`/`%post` scriptlets — no user/group creation, no `systemctl daemon-reload`, no `ldconfig`, no alternatives registration; (2) record anything in the RPM database, so the files are unowned, unverifiable and invisible to upgrades; (3) apply SELinux file contexts from the policy, or file capabilities (`setcap`) declared in the header; (4) check dependencies or signatures. The scriptlets are the usual culprit for "the service still won't start" — the service account was never created, the unit file was never picked up by systemd, or the shared library cache was never refreshed.

**A8.2** — `cpio -i` matches its pattern against the archive member names **exactly as stored**, and RPM stores them relative with a `./` prefix. `/etc/nginx/nginx.conf` never matches `./etc/nginx/nginx.conf`, so cpio extracts zero members and reports only the block count. The relative encoding is deliberate: it makes extraction land under the current directory and makes it impossible for a stray `cpio -i` to overwrite `/etc` by accident.

**A8.3** — Yes, `rpm2cpio` still works. Decompression happens inside `rpm2cpio` itself, which reads the header, discovers the `PAYLOADCOMPRESSOR` tag (`gzip`, `xz`, `zstd`, or `none`), and streams the decompressed cpio archive to stdout. `cpio` therefore never sees compression at all — it receives a plain cpio stream. The corollary is that `rpm2cpio` from an older RPM release cannot read a payload compressed with an algorithm it does not know; the fix is a newer `rpm` package, not a different `cpio`.

**A8.4** — Options, roughly in order of preference: (1) `rpm2archive` if available, or `bsdtar -xf pkg.rpm` — libarchive reads RPM natively, and `bsdtar` ships in Debian's `libarchive-tools`; (2) `7z x pkg.rpm` (p7zip understands the RPM container, then the inner cpio); (3) `apt-get install rpm2cpio` — Debian packages a standalone Perl implementation with no RPM database dependency; (4) manually, by locating the payload offset after the lead+signature+header and piping through the right decompressor into `cpio -idmv`. `bsdtar` is the pragmatic answer on a rescue system.

**A8.5** — `rpm -Vf` reports clean only because you happened to restore identical content with matching mode and ownership; it does not certify that the *rest* of the package is coherent, and if the original damage had a cause (a partial upgrade, a failed transaction, a filesystem error) other files from the same package are likely affected too. `dnf reinstall coreutils` re-extracts the whole payload, re-runs scriptlets, re-applies SELinux contexts and file capabilities, verifies signatures on the way in, and records the operation in `dnf history` so the change is auditable. Manual `install(1)` does none of that — and it silently drops file capabilities, which for setuid-adjacent binaries is a real regression.

---

### Exercise 9

**A9.1** — Yes, still correct in the sense that the path exists and editing it edits the effective configuration — the symlink is a deliberate compatibility shim so that documentation, muscle memory and configuration-management recipes targeting `/etc/yum.conf` keep working. What it does **not** preserve is option compatibility: DNF silently ignores a number of YUM 3 options, `alwaysprompt` and `group_package_types` among them, and most visibly **`plugins=`, `deltarpm`-era options and `distroverpkg`** — DNF derives `$releasever` from the `system-release` provider rather than from `distroverpkg`. Writing an ignored option produces no warning, which is the trap.

**A9.2** — `baseurl` and `mirrorlist`/`metalink` are mutually exclusive per stanza; when both are present DNF uses **`baseurl`** and disregards the mirror list. Shipping `baseurl` commented out is deliberate: the mirror list gives geographic mirror selection, automatic failover when one mirror is stale or down, and integrity assurance via `metalink` (which carries the expected `repomd.xml` checksum). A hardcoded `baseurl` is the right choice only when you run your own mirror or are behind a proxy that must see a stable hostname.

**A9.3** — With `skip_if_unavailable=True`, a repository that fails to refresh is dropped from the transaction with a warning instead of an error. If the repository that fails is the **updates/security** repository, `dnf upgrade` reports `Nothing to do` or applies only a subset — and exits `0`. Automation reads success, monitoring reads "patched", and the host silently sits on unpatched packages until someone reads the warning line. Worse, if the failing repo was the one supplying the *newest* version of a package, the solver may install an older version from another repo and consider the system up to date. Keep it `False` (the RHEL 9 default) and let failures be loud.

**A9.4** — Create one file per host or per host-group via configuration management:
```bash
echo 'mirror.emea.example.net' > /etc/dnf/vars/sitemirror
```
Then ship one `.repo` file, identical everywhere, referencing it:
```ini
baseurl=http://$sitemirror/rocky/$releasever/BaseOS/$basearch/os/
```
DNF substitutes any `$name` from a file named `name` in `/etc/dnf/vars/` (contents = value, first line, newline stripped). Changing a region becomes a one-line file write, and the `.repo` files stay uniform and reviewable.

**A9.5** — `priority=` is **not** honoured by stock DNF; it requires the `dnf-plugin-priorities` package (`dnf-plugins-extras-priorities`, historically `yum-plugin-priorities`). Without it the line is silently ignored — a very common production surprise. The distinction: `priority` is a **strict** ordering — a package available in a higher-priority (lower number) repository is used even if a lower-priority repository has a *newer* version, which is how you prevent a third-party repo from replacing base packages. `cost` (default 1000, honoured by stock DNF) is a **tiebreaker** used only when the same package-version exists in multiple repositories, expressing relative expense of fetching; it never overrides version comparison. If your goal is "never let Packman/EPEL shadow BaseOS", `priority` plus `excludepkgs`/`includepkgs` is the mechanism, not `cost`.

**A9.6** — `dnf clean all` **deletes** the local cache — metadata and, depending on `keepcache`, downloaded packages — forcing a full re-download of every repository's metadata on the next operation. `dnf --refresh <cmd>` only marks the existing metadata as expired so it is revalidated, which for `repomd.xml`-based repositories means a small conditional request that re-downloads the large primary/filelists databases **only if the repository revision changed**. On a metered link, `--refresh` is the safe one; `clean all` in cron is a recurring bandwidth bill and belongs only in break-glass procedures.

---

### Exercise 10

**A10.1** — `dnf upgrade foo` moves `foo` to the newest available version and does nothing if `foo` is not installed. `dnf install foo` when `foo` is already installed behaves as an upgrade if a newer version exists, and reports `Package foo is already installed. Nothing to do.` otherwise — it will not downgrade. `dnf distro-sync foo` synchronises `foo` to exactly the version the enabled repositories currently publish, which means it **will downgrade** if the installed version is newer than anything available (the case after removing a third-party repo, or after a manual `rpm -U`).

**A10.2** — `check-update` is designed as a *predicate* for scripts: exit `0` means "nothing to do", `100` means "action needed", `1` means "I could not tell you". Reserving `0` for the no-op case lets `dnf check-update || run_patching` read naturally, and lets monitoring distinguish "up to date" from "broken repository" — which a boolean could not. Under `set -e`, the `100` terminates the script at the very moment updates exist, i.e. exactly when you wanted it to continue. Guard it explicitly:
```bash
dnf check-update; rc=$?
case $rc in 0) ;; 100) do_upgrade ;; *) exit "$rc" ;; esac
```

**A10.3** — `--extras` means "installed, but provided by no currently enabled repository". Causes: (1) the repository that supplied it was disabled or removed — common with third-party repos after an OS minor upgrade; (2) the package was upgraded past what the repos carry, or installed from a local `.rpm` never present in any repo; (3) the distribution retired or renamed the package across a major-version upgrade (leftovers). The supply-chain concern is (2): a locally installed RPM from an unverified source shows up here, and because no repository tracks it, it will never receive a security update and no CVE scanner keyed on repository metadata will flag it. `dnf list --extras` is therefore a cheap and underused audit.

**A10.4** — `best=True` tells the solver: if the newest version of a requested package cannot be installed, **fail and explain**, rather than quietly installing an older one. Concrete case: you run `dnf upgrade nginx`; nginx 1.22 requires `openssl-libs >= 3.0.7`, but `openssl-libs` is pinned by `versionlock` at 3.0.1. With `best=True` the transaction aborts with the unresolvable dependency named. With `--nobest`, DNF installs nginx 1.20 instead and exits `0` — so the operator believes nginx was upgraded and the CVE fixed, when it was not. `--nobest` trades **truthfulness for progress**; it is the right choice only when you knowingly accept a partial upgrade and will verify versions afterwards.

**A10.5** — `/etc/httpd/conf/httpd.conf` is owned by the `httpd`/`httpd-core` package and marked `%config(noreplace)`. On erase, RPM removes owned config files — preserving a modified one as `httpd.conf.rpmsave`; check for it. `/etc/httpd/conf.d/myapp.conf` survives because **no package owns it**: you created it, so it is outside RPM's file manifest entirely and RPM will never delete it. The directory `/etc/httpd/conf.d` is owned by the package, but RPM refuses to remove a directory that still has unowned content in it — which is exactly the drop-in-directory design intent.

**A10.6** — `rpm -i ./local.rpm` performs a dependency *check* and aborts if anything is unmet; it will not fetch anything. `dnf install ./local.rpm` adds the local file to the transaction as a package source and then **resolves its dependencies against the enabled repositories**, downloading whatever else is needed — the local RPM plus a complete, consistent transaction. It also records the operation in `dnf history`, making it undoable. Signature checking for that local file is governed by **`localpkg_gpgcheck`** in `dnf.conf`, which defaults to `False` — set it to `True`.

---

### Exercise 11

**A11.1** — `rpm -q --whatrequires foo` queries only the **installed** database, and only for dependencies expressed as the literal string `foo`. `dnf repoquery --whatrequires foo` queries the **repository metadata**, so it sees packages that are not installed, and — with `--alldeps` — it resolves through provides, finding packages that depend on a capability `foo` supplies under a different name. For "what would break on this host", use `dnf repoquery --installed --whatrequires --alldeps`. For "what would break anywhere in the distribution", drop `--installed`.

**A11.2** — Unresolved, `--requires` prints the dependency exactly as the package declares it: a capability such as `libapr-1.so.0()(64bit)` or `webserver`. `--resolve` maps each capability to a concrete package name that currently provides it, in the enabled repositories, right now. The unresolved form is more accurate as a statement about the package because the mapping is not a property of the package at all — it is a property of the repository set at a moment in time. A different repository, a different release, or a compatible alternative provider yields a different resolution while the package is unchanged. `--resolve` answers "what will be installed"; `--requires` answers "what does this need".

**A11.3** — Two `kernel-devel` versions is normal and expected: `kernel-devel` is in `installonlypkgs`, kept in parallel so DKMS modules can be built against each installed kernel. Two `glibc` versions is a **broken system**: `glibc` is not install-only, so both versions own the same file paths, meaning an interrupted transaction, a `rpm -i` where `-U` was meant, or a `--force` install left the database with duplicate entries and the filesystem with whichever files were written last. Diagnose with `dnf repoquery --duplicates` / `package-cleanup --dupes`, and repair with `dnf remove <older-NEVRA>` — naming the full NEVRA, not the bare name — or `dnf distro-sync`. Never resolve it with `rpm -e --nodeps`.

**A11.4** —
```bash
dnf repoquery --installed --qf '%{name}-%{evr}.%{arch} %{sourcerpm}\n' \
  | grep 'nginx-1.20.1-14.el9_2.1.src.rpm'
```
This maps the SRPM named in the advisory to the binary sub-packages actually installed here — which is the question that matters, since one SRPM commonly produces a dozen binary packages and you may have only two of them. `dnf updateinfo list --cve CVE-XXXX-YYYY` is the complementary command when the repository ships errata metadata.

---

### Exercise 12

**A12.1** — At transaction 12: `undo 8` inverts **only** transaction 8 (installs what 8 removed, removes what 8 installed, downgrades what 8 upgraded), leaving 9–12 in place — which can fail if a later transaction depends on 8's result. `rollback 8` reverts **everything after 8**, i.e. transactions 9 through 12, returning the package set to its state at the end of transaction 8. `redo 8` re-applies transaction 8's operations as a new transaction 13.

**A12.2** — It does not restore: (1) **configuration file contents** — `%config(noreplace)` files edited since, and any `.rpmnew`/`.rpmsave` reconciliation you performed; (2) **data and state** outside the package manifest — database schemas migrated by a `%post` scriptlet, files created at runtime, log rotation state, generated certificates; (3) **service and system state** — a unit that was enabled or masked, a SELinux boolean set, a firewall rule opened, a kernel module now loaded. It is misleading to call it "rollback" because it reverts the *package set only*, treating the transaction as reversible when its side effects generally are not. A downgraded application that already migrated its database forward is a common, painful example.

**A12.3** — They are checksums over the RPM database contents at the start and end of the transaction, stored so DNF can detect changes made **outside** its knowledge. If the `Begin rpmdb` of transaction N+1 does not match the `End rpmdb` of transaction N, something modified the package set without going through DNF — a bare `rpm -i`/`rpm -e`, a configuration-management tool driving `rpm` directly, a container image layer, or a restored backup. DNF flags this and it degrades the reliability of `undo`/`rollback`, because the recorded inverse operation may no longer apply to the current state.

**A12.4** — Two ways: (1) point DNF at an archive of the older packages — enable a vault/archive repository (`dnf --releasever=9.2 --enablerepo=...`, or a vault mirror such as an internal snapshot repo) so the old NEVRAs resolve again; (2) obtain the RPMs directly (from `/var/cache/dnf` on a peer host, an internal artifact store, or a vault mirror) and install them explicitly with `dnf downgrade ./old-*.rpm`. The `dnf.conf` setting that would have prevented it is **`keepcache=1`**, which retains the downloaded RPMs under `/var/cache/dnf` after a successful transaction so the previous versions are still on disk. The more robust production answer is a **snapshotted internal mirror**, so "the version we ran last Tuesday" is always resolvable.

---

### Exercise 13

**A13.1** — Group definitions live in the repository metadata — the `comps.xml` (`group_gz`/`comps` entry in `repomd.xml`), cached under `/var/cache/dnf/<repo>-<hash>/repodata/`; DNF additionally records which groups you installed in its own group persistor (`/var/lib/dnf/groups.json` in DNF 4). Proof they are not in the RPM database: `rpm -q "Development Tools"` reports `package Development Tools is not installed`, and `rpm -qa | grep -i development.tools` returns nothing — RPM has no notion of groups beyond the vestigial `%{GROUP}` tag, which is a free-text category, not a bundle. When the defining repository is disabled, `dnf group list` stops showing the group and `dnf group remove` can no longer determine its membership; the individual packages remain installed and become ordinary packages.

**A13.2** — `dnf module reset nodejs` clears the enabled-stream state entirely, returning the module to "no stream selected" — it does not remove packages. `dnf module disable nodejs` marks the module as disabled, hiding **all** its streams' packages from the solver. `reset` is the correct precursor to switching streams (`reset` → `enable nodejs:20` → `distro-sync` or `install`). Using `disable` instead causes a solve failure because the currently installed `nodejs` packages come from the module you just hid: the solver sees installed packages provided by no available module stream, and any subsequent transaction touching them has no valid resolution.

**A13.3** — Ranked by scope and persistence:
1. **`exclude=` in `/etc/dnf/dnf.conf`** — widest and most persistent: applies to every repository, every command, every user, until edited. Blocks security patches too.
2. **`versionlock`** — persistent (stored in `/etc/dnf/plugins/versionlock.list`), package-scoped, and pins to a specific EVR. Also blocks security patches for that package, but it is explicit, listable (`dnf versionlock list`) and auditable — which is why it is the right tool when a pin is genuinely required.
3. **`--exclude=` on the command line** — narrowest and non-persistent: this invocation only.

None of the three lets a security patch through automatically — that is the point of a pin. The nearest thing is `exclude=` with `--disableexcludes=all` on the patching run, or scoping the versionlock to a version prefix (`dnf versionlock add 'nginx-1.20.*'`) so Z-stream security rebuilds within that branch are still allowed. That last form is the one to reach for.

**A13.4** — The solver reports an unresolvable dependency naming both sides — typically `Problem: package X requires nginx >= 1.22, but none of the providers can be installed` followed by `package nginx-1.22 is filtered out by exclude filtering` or `... is excluded by versionlock`. The least-damaging resolution, in order: (1) determine whether the pin is still justified — pins outlive their reasons more often than not; if not, `dnf versionlock delete nginx` and upgrade normally. (2) If the pin must stay, narrow the transaction: `dnf upgrade --exclude=<the dependent package>` so the rest of the system patches, and track the excluded package as accepted risk. (3) Only as a last resort `--nobest`, and then verify afterwards exactly which versions landed. Never `--allowerasing` here: it will happily remove the dependent package to satisfy the solve.

---

### Exercise 14

**A14.1** —

| DNF | zypper |
|---|---|
| `dnf provides <path>` | `zypper what-provides <path>` (`zypper wp`) |
| `dnf repolist` | `zypper repos` (`zypper lr`) |
| `dnf list --installed` | `zypper search --installed-only` (`zypper se -i`), or `zypper packages -i` |
| `dnf config-manager --set-disabled <repo>` | `zypper modifyrepo -d <alias>` (`zypper mr -d`) |
| `dnf autoremove` | `zypper remove --clean-deps <pkg>` (at removal time); `zypper packages --unneeded` to list orphans |

**A14.2** — `zypper up` upgrades installed packages to newer versions **within the same vendor and architecture**, and will not remove packages or change vendors to complete the solve; it is the conservative "patch what I have" operation. `zypper dup` performs a full distribution upgrade: it synchronises the installed set to what the enabled repositories publish, **permits vendor changes, downgrades and package removals**, and is the mechanism behind openSUSE Tumbleweed's rolling model and Leap version upgrades. After adding Packman — whose whole purpose is to *replace* openSUSE multimedia packages with differently-built ones — you need `zypper dup --from packman` (or `--allow-vendor-change`) precisely because a vendor change is required. `zypper up` is wrong there: it refuses the vendor change and silently leaves you on the original packages, which is the classic "I added Packman and nothing happened" report.

**A14.3** — **Lower number wins** in zypper: `priority=90` beats `priority=99` (the default). The scale runs 1 (highest) to 200 (lowest). This is the opposite convention from many people's intuition and — critically — the DNF `priority` plugin uses the *same* lower-is-higher convention (default 99), so the trap is not the direction but the assumption that priorities work at all: zypper honours `priority` **natively**, whereas DNF needs `dnf-plugin-priorities` installed or the setting is silently ignored. A configuration copied conceptually from zypper to DNF will appear to work and will not.

**A14.4** — During the upgrade, RPM replaced the shared library files on disk. On Linux, unlinking a file that a process holds open does not free it: the old inode persists, and `httpd` keeps executing the **old, unpatched** code from the deleted inode while `/proc/<pid>/maps` shows entries marked `(deleted)`. That is what `zypper ps` detects. A restart is mandatory, not cosmetic, for two reasons: the vulnerability the upgrade fixed is still live in the running process, and the old inode's disk space is not reclaimed until the last reference closes. On the DNF side, the equivalent is `dnf needs-restarting` (`-r` for "does the whole system need a reboot").

**A14.5** — Exit code 103 means zypper (or its libzypp stack) was itself updated as part of the transaction, so the running process is now stale and the transaction is **incomplete**. An unattended script must **re-invoke zypper** to finish the remaining work — typically loop: run the patch command, and if it exits 103, run it again (with a bounded retry count) until it returns 0, 100 or 102. Treating 103 as success leaves patches unapplied; treating it as a hard failure aborts a run that was actually progressing. Handle 102 separately by scheduling a reboot.

---

### Exercise 15

**A15.1** — `rpm --rebuilddb` reads the existing package headers out of the database and writes a fresh set of **index** structures around them — with the BDB backend, the `Name`, `Basenames`, `Providename`, `Requirename`, `Dirnames` and related secondary tables; with sqlite, it rewrites and reindexes the database file. It repairs index corruption, stale locks and BDB environment damage. It cannot recover **header data** that is gone: if `Packages` (BDB) or `rpmdb.sqlite` (sqlite) is destroyed, there is nothing left to index — the headers *are* the primary store — and `--rebuilddb` produces a valid, empty database. That is why it is a no-op in the truly destroyed case, and why the real recovery paths are a filesystem-level backup of `/var/lib/rpm`, a snapshot, or reconstruction from `/var/lib/dnf/history.sqlite` plus a mass reinstall.

**A15.2** — DNF runs a full **transaction check** (the `rpm` transaction-check phase, `rpmtsCheck`, plus libsolv's own solve) before committing. Two guards would have stopped it: the dependency check (which `--nodeps` bypassed) and the **file conflict check** during `rpmtsRun`'s prepare stage, which detects that two installed packages claim the same path with different content and aborts with `file ... from install of X conflicts with file from package Y` (that is `--replacefiles`, implied by `--force`, being bypassed). DNF exposes no equivalent of `--force`; the closest, `--allowerasing`, resolves conflicts by *removing* a package, never by overwriting another package's files. The state you created is unreachable through DNF by design.

**A15.3** — `rpm -qf /etc/nginx` reports `file /etc/nginx is not owned by any package` — the files are still on disk but the database entry that claimed them is gone, so they are orphaned: invisible to `rpm -V`, not removed by any future erase, and a guaranteed file conflict the next time something tries to install a package owning those paths. Cleanest path back: `dnf install nginx-filesystem` will now fail or conflict on the existing files, so either (a) `rpm -ivh --justdb --replacepkgs` the same NEVRA to restore the database entry, then `dnf reinstall nginx-filesystem` to re-lay the files properly; or (b) remove the orphaned paths by hand — after confirming with `rpm -qlp` exactly which they are and that nothing else owns them — and then `dnf install nginx-filesystem` normally. Option (a) is preferable because it never deletes anything.

**A15.4** — `dnf remove kernel` matches **every installed kernel**, including the running one, and DNF will remove them all — leaving a system with no bootable kernel that dies at the next reboot (and immediately loses `/lib/modules/<running>`, so no further module loads). `--oldinstallonly` selects only install-only packages beyond `installonly_limit`, explicitly **excluding the running kernel and the newest one**, which is why it is safe. At the bootloader level, `dnf`'s `%posttrans` scriptlets regenerate the GRUB configuration and BLS entries under `/boot/loader/entries/`, so removing an old kernel also removes its boot entry — meaning the protection is only as good as the exclusion logic. Belt and braces: `dnf remove --oldinstallonly --setopt=installonly_limit=2 kernel` and verify with `rpm -q kernel` and `uname -r` before rebooting.

**A15.5** — Recovery using only `rpm`, `rpm2cpio` and a mirror:
1. Identify the damaged packages: `rpm -Va python3-dnf python3-libdnf python3-hawkey libdnf` and `rpm -q --qf '%{NEVRA}\n' dnf python3-dnf libdnf librepo libsolv rpm-libs`.
2. Fetch the correct RPMs directly from a mirror with `curl -O` (the mirror path is visible in `dnf repoinfo` output captured earlier, or reconstruct it from the `.repo` file's `baseurl`). If `curl` is also broken, `rpm -qip <URL>` proves RPM's own HTTP client works and you can drive the download some other way.
3. Verify before trusting: `rpm -Kv *.rpm` — this still works, since `rpmkeys` does not depend on DNF.
4. Reinstall with RPM in **one transaction**: `rpm -Uvh --replacepkgs libsolv-*.rpm librepo-*.rpm libdnf-*.rpm python3-*.rpm dnf-*.rpm dnf-data-*.rpm`. Naming them together lets RPM's dependency check resolve the set internally.
5. If `rpm` itself is impaired (a broken `rpm-libs`), use `rpm2cpio | cpio -idmv` into a scratch directory and copy the required `.so` files into place *just far enough* to make `rpm` run, then immediately redo step 4 properly so the database and scriptlets are correct.
6. Confirm: `dnf --version`, then `dnf check` and `rpm -Va --nomtime` on the affected packages.

The ordering principle throughout: use extraction only to bootstrap the tool back to life, never as the final state.

</details>