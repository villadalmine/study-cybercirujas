# 102.4 — Use Debian Package Management

**LPIC-1 · Exam 101-500 / 102-500 · Version 5.0 · Objective weight: 4.69**

---

## 1. The production problem: why package management is a control plane, not a convenience

A Debian-family system is not a filesystem with programs copied into it. It is a **transactional database of declared state** (`/var/lib/dpkg/status`) plus a **constraint solver** (APT) that computes the transitions between states. Every file under `/usr` on a correctly managed host is owned, versioned, checksummed and attributable to a signed artifact from a signed index. That property is what makes the following operations possible at fleet scale:

| Production requirement | What the package system provides | What breaks without it |
|---|---|---|
| Reproducible builds of golden images | Pinned versions + snapshot archives + `Packages` indices | Image drift between build N and N+1; "works on the old AMI" |
| Supply-chain attestation | Detached OpenPGP signature over `Release`, SHA256 over every index and `.deb` | Any MITM or compromised mirror injects arbitrary root-level code |
| Incident forensics | `dpkg -S`, `dpkg -V`, `/var/log/dpkg.log`, `/var/log/apt/history.log` | "Where did `/usr/local/bin/agent` come from?" is unanswerable |
| Safe rollback | Versioned archives + `apt-get install pkg=version` + conffile preservation | Rollback means reimaging |
| CVE response inside an SLA | `debsecan`, `apt list --upgradable`, security suite separated from the main suite | Manual inventory spreadsheets |
| Immutable / container builds | `--no-install-recommends`, deterministic `sources.list`, `apt-mark showmanual` | 900 MB images with a compiler toolchain in production |

The architectural failure mode this objective exists to prevent is **untracked state**. The moment an operator runs `curl … | tar -C /usr -xz`, the host leaves the model: no file ownership, no checksum, no upgrade path, no removal path, no CVE mapping. Every technique below exists to keep changes inside the transactional model — or, when a third-party artifact is unavoidable, to wrap it in a `.deb` so it re-enters the model.

### 1.1 The layer model

```
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 3 — Front ends / policy                                       │
│  apt (interactive), aptitude (own resolver + TUI),                   │
│  unattended-upgrades, synaptic, ansible/apt module, cloud-init       │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 2 — APT: acquisition + dependency resolution                  │
│  apt-get, apt-cache, apt-mark, apt-file, apt-config                  │
│  Reads:  /etc/apt/sources.list{,.d}, /etc/apt/preferences{,.d},      │
│          /etc/apt/apt.conf{,.d}, /etc/apt/trusted.gpg.d, keyrings    │
│  Writes: /var/lib/apt/lists/, /var/cache/apt/archives/               │
│  Output: an ordered list of .deb files handed to dpkg                │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 1 — dpkg: the local transaction engine                        │
│  dpkg, dpkg-deb, dpkg-query, dpkg-divert, dpkg-statoverride,         │
│  dpkg-trigger, dpkg-reconfigure (via debconf)                        │
│  State:  /var/lib/dpkg/status, /var/lib/dpkg/info/*                  │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 0 — the .deb artifact  (an `ar` archive)                      │
└──────────────────────────────────────────────────────────────────────┘
```

**The single most important operational consequence of this diagram:** `dpkg` has *no* concept of a repository, *no* network access and *no* dependency resolver. It only verifies that dependencies are satisfied and refuses otherwise. APT never touches the filesystem under `/usr`; it downloads and orders. Almost every "package management" incident is a mis-attribution of a symptom to the wrong layer.

---

## 2. Layer 0 — the `.deb` artifact, dissected

A `.deb` is a plain `ar(1)` archive with exactly three members in a fixed order.

```console
$ apt-get download nginx-light
Get:1 http://deb.debian.org/debian bookworm/main amd64 nginx-light amd64 1.22.1-9 [509 kB]
Fetched 509 kB in 0s (3,412 kB/s)

$ ar t nginx-light_1.22.1-9_amd64.deb
debian-binary
control.tar.xz
data.tar.xz

$ ar p nginx-light_1.22.1-9_amd64.deb debian-binary
2.0
```

| Member | Content | Purpose |
|---|---|---|
| `debian-binary` | The literal string `2.0\n` | Format version; guards against future incompatibility |
| `control.tar.{gz,xz,zst}` | `control`, `md5sums`, `conffiles`, maintainer scripts, `triggers`, `templates`, `shlibs`, `symbols` | Metadata + the executable logic dpkg runs |
| `data.tar.{gz,xz,zst,bz2}` | The payload, rooted at `/` | The files actually installed |

Debian 12 uses `xz` for both tarballs; Ubuntu ≥ 21.10 defaults to `zstd` for `data.tar` (faster decompression, marginally larger). A `zstd`-compressed `.deb` is **not installable by dpkg < 1.21.18**, which is a real cross-distribution portability trap when copying artifacts between an Ubuntu build agent and a Debian target.

### 2.1 Inspecting an artifact without installing it

```console
$ dpkg-deb -I nginx-light_1.22.1-9_amd64.deb
 new Debian package, version 2.0.
 size 508984 bytes: control archive=1868 bytes.
     996 bytes,    21 lines      control
    1183 bytes,    18 lines      md5sums
     167 bytes,     6 lines      conffiles
    1421 bytes,    47 lines   *  postinst             #!/bin/sh
     853 bytes,    28 lines   *  postrm               #!/bin/sh
     371 bytes,    15 lines   *  prerm                #!/bin/sh
 Package: nginx-light
 Source: nginx
 Version: 1.22.1-9
 Architecture: amd64
 Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
 Installed-Size: 1387
 Depends: nginx-common (= 1.22.1-9), libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0), libpcre2-8-0 (>= 10.22), libssl3 (>= 3.0.0), zlib1g (>= 1:1.1.4)
 Recommends: nginx-doc
 Conflicts: nginx-core, nginx-extras, nginx-full
 Provides: httpd, httpd-cgi, nginx
 Replaces: nginx-core, nginx-extras, nginx-full
 Section: httpd
 Priority: optional
 Homepage: https://nginx.org
 Description: small, powerful, scalable web/proxy server
```

```console
$ dpkg-deb -c nginx-light_1.22.1-9_amd64.deb | head -12
drwxr-xr-x root/root         0 2023-06-11 20:14 ./
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/nginx/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./etc/nginx/modules-enabled/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/sbin/
-rwxr-xr-x root/root   1204584 2023-06-11 20:14 ./usr/sbin/nginx
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/doc/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/doc/nginx-light/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/man/
drwxr-xr-x root/root         0 2023-06-11 20:14 ./usr/share/man/man8/
```

**Auditing a vendor `.deb` before it ever touches a host** — extract control and payload to a scratch directory. This is the mandatory review step for any third-party package in a regulated environment, because `preinst`/`postinst` run as root:

```console
$ mkdir -p /tmp/audit/{control,data}
$ dpkg-deb -e vendor-agent_4.2.0_amd64.deb /tmp/audit/control   # control files only
$ dpkg-deb -x vendor-agent_4.2.0_amd64.deb /tmp/audit/data      # payload, quiet
$ dpkg-deb -X vendor-agent_4.2.0_amd64.deb /tmp/audit/data      # payload, verbose listing

$ cat /tmp/audit/control/postinst
#!/bin/sh
set -e
case "$1" in
  configure)
    curl -sS https://updates.vendor.example/enroll | sh    # <-- reject this package
    ;;
esac
#DEBHELPER#
exit 0
```

| Flag | Meaning | Note |
|---|---|---|
| `dpkg-deb -I` / `--info` | Show `control` + list control files | Never executes anything |
| `dpkg-deb -f pkg.deb Depends` | Print one control field | Scriptable, exact |
| `dpkg-deb -c` / `--contents` | List payload with modes, owners, sizes | Same as `tar tvf data.tar` |
| `dpkg-deb -e` / `--control` | Extract control files to a directory | Read maintainer scripts here |
| `dpkg-deb -x` / `--extract` | Extract payload (silent) | Does **not** run scripts, does **not** register in the dpkg DB |
| `dpkg-deb -X` / `--vextract` | Extract payload, listing files | |
| `dpkg-deb -b dir pkg.deb` | Build a `.deb` from a tree | Basis of `fpm`, `checkinstall` |

> `dpkg -I`, `dpkg -c`, `dpkg -e`, `dpkg -x` are aliases that dpkg forwards to `dpkg-deb`. In the exam either spelling is valid.

### 2.2 Dependency field semantics — the trade-off table

Getting these wrong is the root cause of both bloated images and broken upgrades.

| Field | Strength | Enforced by dpkg? | Production meaning |
|---|---|---|---|
| `Depends` | Must be **configured** before this package is configured | Yes — refuses to configure | Hard runtime requirement |
| `Pre-Depends` | Must be fully installed before this package is even **unpacked** | Yes — refuses to unpack | Needed by `preinst`; forces an extra dpkg run; used sparingly (e.g. `init-system-helpers`) |
| `Recommends` | "Would be found together in all but unusual installations" | No | **Installed by default by APT.** Primary source of image bloat |
| `Suggests` | Enhances but is unrelated | No | Never auto-installed |
| `Enhances` | Reverse `Suggests`, declared by the enhancer | No | Used by plugin packages |
| `Breaks` | This package breaks the named versions | Yes — target must be de-configured/upgraded | Preferred modern form; allows co-installation after upgrade |
| `Conflicts` | Cannot be unpacked at the same time at all | Yes — target must be removed | Heavier hammer; use only for genuine file/namespace clashes |
| `Replaces` | May overwrite files of the named package | Yes — permits file takeover | Paired with `Breaks`/`Conflicts` during package renames |
| `Provides` | Declares a virtual package name | Yes — satisfies `Depends` | `httpd`, `mail-transport-agent`, `awk` |

Version relations: `(<< v)` strictly earlier, `(<= v)`, `(= v)`, `(>= v)`, `(>> v)` strictly later. Alternatives use `|`: `Depends: nginx-core | nginx-light | nginx-full` — APT picks the **first** satisfiable alternative unless one is already installed.

**Killer detail for images:** `Recommends` are pulled in by default. One line changes a 120 MB image into a 480 MB image:

```console
$ apt-get install -y --no-install-recommends nginx-light
```

Or globally, which is the correct choice for a container base:

```console
$ cat /etc/apt/apt.conf.d/99no-recommends
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
```

### 2.3 Version strings and the comparison algorithm

Format: `[epoch:]upstream_version[-debian_revision]`

```
1:9.2p1-2+deb12u3
│ │      │
│ │      └── Debian revision — packaging changes only
│ └───────── upstream version
└─────────── epoch (default 0, rarely displayed)
```

Comparison rules that produce real-world surprises:

1. Epoch dominates everything. `1:1.0` > `2.0`. Epochs are the escape hatch when upstream *lowers* its version number; they can never be removed.
2. Strings are split into alternating non-digit and digit runs; digit runs compare numerically (`1.10` > `1.9`), non-digit runs compare by a modified ASCII order.
3. **`~` sorts before everything, including the empty string.** This is what makes `1.0~rc1 < 1.0` and `1.0~~a < 1.0~`. It is the mechanism behind pre-release packaging and behind backport version suffixes.
4. Letters sort before non-letters, so `1.0a < 1.0+b`.

Never guess — `dpkg` exposes the algorithm directly, and it is exit-code driven, so it composes into scripts:

```console
$ dpkg --compare-versions "1.0~rc1" lt "1.0" && echo "true"
true
$ dpkg --compare-versions "1.10" gt "1.9" && echo "true"
true
$ dpkg --compare-versions "2.0" gt "1:1.0" || echo "false — epoch wins"
false — epoch wins
$ dpkg --compare-versions "1.22.1-9" ge "1.22.1-9+deb12u1"; echo $?
1
```

Operators: `lt le eq ne ge gt` (and the deprecated `lt-nl`, `gt-nl`, `<`, `>` forms). Use this in health checks instead of shell string comparison — a `[ "$v" \> "1.9" ]` test is wrong for `1.10`.

---

## 3. Layer 1 — `dpkg`: the local transaction engine

### 3.1 The database on disk

| Path | Content | Operational relevance |
|---|---|---|
| `/var/lib/dpkg/status` | The authoritative record: one RFC822 stanza per known package, with `Status`, `Version`, `Conffiles` | **Back this up.** Corrupting it is the one dpkg failure that is genuinely hard to recover from |
| `/var/lib/dpkg/status-old` | Previous copy, rotated on write | First recovery target |
| `/var/backups/dpkg.status.*` | Daily rotated backups (via cron) | Second recovery target |
| `/var/lib/dpkg/info/<pkg>.list` | Every path the package owns | Source of `dpkg -L` and `dpkg -S` |
| `/var/lib/dpkg/info/<pkg>.md5sums` | Checksums of shipped files | Source of `dpkg -V` and `debsums` |
| `/var/lib/dpkg/info/<pkg>.conffiles` | Files under `/etc` under conffile protection | Determines upgrade prompts |
| `/var/lib/dpkg/info/<pkg>.{preinst,postinst,prerm,postrm,config,templates,triggers}` | Maintainer logic | Read these when an upgrade hangs |
| `/var/lib/dpkg/available` | Legacy `dselect` index | Feeds `dpkg --set-selections` sanity; largely vestigial |
| `/var/lib/dpkg/lock`, `lock-frontend` | Advisory locks | Source of the most common APT error |
| `/var/lib/dpkg/triggers/` | Pending deferred triggers | Explains `trig-pend` / `trig-aWait` states |
| `/var/log/dpkg.log` | Per-action audit trail with timestamps | Forensics: exactly when a version changed |

```console
$ grep -A2 '^Package: openssh-server$' /var/lib/dpkg/status | head -3
Package: openssh-server
Status: install ok installed
Priority: optional
```

The `Status` field is three tokens: **desired selection**, **error flag**, **current state**.

### 3.2 Reading `dpkg -l` — the state machine

```console
$ dpkg -l openssh-server nginx-light nonexistent-pkg
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name            Version            Architecture Description
+++-===============-==================-============-=====================================
ii  nginx-light     1.22.1-9           amd64        small, powerful, scalable web/proxy server
ii  openssh-server  1:9.2p1-2+deb12u3  amd64        secure shell (SSH) server, for secure access
dpkg-query: no packages found matching nonexistent-pkg
```

| Column 1 — Desired | Meaning |
|---|---|
| `u` | Unknown — no selection ever recorded |
| `i` | Install |
| `r` | Remove (keep conffiles) |
| `p` | Purge |
| `h` | **Hold** — dpkg will refuse to upgrade it |

| Column 2 — Current status | Meaning | Healthy? |
|---|---|---|
| `n` | Not installed | ✅ |
| `i` | Installed and configured | ✅ |
| `c` | Only config files remain (removed, not purged) | ⚠️ leftover state |
| `U` | **Unpacked** — files present, `postinst` not run | ❌ |
| `F` | **halF-configured** — `postinst` failed | ❌ |
| `H` | **Half-installed** — unpack aborted mid-way | ❌ |
| `W` | Trigger-aWaited | transient |
| `t` | Trigger-pending | transient |

| Column 3 — Error | Meaning |
|---|---|
| *(space)* | No error |
| `R` | **Reinst-required** — package is so broken it must be reinstalled; `dpkg -r` will refuse |

**The rule for the exam and for the runbook: uppercase in columns 2 or 3 means bad.** `iU`, `iF`, `iH`, `iR` all indicate an interrupted transaction. The remediation is in §7.

The two states operators most often misread:

- `rc` — the package was removed but its conffiles under `/etc` survive. It still occupies a stanza in `status`. `apt purge` (or `dpkg -P`) clears it. A fleet with thousands of `rc` entries is usually a symptom of `apt remove` used where `apt purge` was intended, and it leaves stale configuration that a *reinstall* will silently pick up months later — an extremely common source of "the new node behaves differently".
- `hi`/`hold` — set deliberately (`apt-mark hold`) or, dangerously, inherited from a `dpkg --set-selections` blob. A held security-critical package silently defeats `unattended-upgrades`.

```console
$ dpkg -l | awk '$1 ~ /^rc/ {print $2}'
libxcb-shape0:amd64
python3-cryptography

$ dpkg -l | grep -Ev '^(ii|un) ' | grep -E '^[a-z]{2}'
rc  libxcb-shape0:amd64  1.15-1  amd64  X C Binding, shape extension
iU  vendor-agent         4.2.0   amd64  Vendor observability agent
```

### 3.3 The dpkg command surface

```console
$ sudo dpkg -i ./vendor-agent_4.2.0_amd64.deb
Selecting previously unselected package vendor-agent.
(Reading database ... 41287 files and directories currently installed.)
Preparing to unpack vendor-agent_4.2.0_amd64.deb ...
Unpacking vendor-agent (4.2.0) ...
dpkg: dependency problems prevent configuration of vendor-agent:
 vendor-agent depends on libcurl4 (>= 7.68.0); however:
  Package libcurl4 is not installed.

dpkg: error processing package vendor-agent (--install):
 dependency problems - leaving unconfigured
Errors were encountered while processing:
 vendor-agent
```

That output is the layer boundary made visible: dpkg detected the unmet dependency, refused to configure, and left the package in state `iU`. It cannot fetch `libcurl4` — it has no idea where packages come from. The fix is to escalate to layer 2:

```console
$ sudo apt-get -f install
Reading package lists... Done
Building dependency tree... Done
Correcting dependencies... Done
The following additional packages will be installed:
  libcurl4
The following NEW packages will be installed:
  libcurl4
0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.
1 not fully installed or removed.
Need to get 391 kB of archives.
After this operation, 1,032 kB of additional disk space will be used.
Do you want to continue? [Y/n] y
...
Setting up libcurl4:amd64 (7.88.1-10+deb12u5) ...
Setting up vendor-agent (4.2.0) ...
```

| Command | Effect | Caveats |
|---|---|---|
| `dpkg -i pkg.deb` | Unpack **and** configure | No dependency resolution; leaves `iU` on failure |
| `dpkg --unpack pkg.deb` | Unpack only | Used to break circular dependency deadlocks |
| `dpkg --configure pkg` | Run `postinst` for an unpacked package | `--configure -a` = all pending |
| `dpkg -r pkg` | Remove, keep conffiles → state `rc` | Refuses if others depend on it |
| `dpkg -P pkg` / `--purge` | Remove including conffiles → state `un`/gone | The correct default for decommissioning |
| `dpkg -L pkg` | List files the package owns | Reads `.list`; installed packages only |
| `dpkg -S /path/to/file` | Which installed package owns this path | Installed packages only — see §5 |
| `dpkg -s pkg` | Show the `status` stanza | Includes `Status:` line; `dpkg -p` shows the *available* stanza instead |
| `dpkg -l [glob]` | Tabular listing | Glob is shell-style: `dpkg -l 'linux-image-*'` |
| `dpkg -C` / `--audit` | Report packages in a broken state | First command in any triage |
| `dpkg -V pkg` | Verify installed files against `md5sums` | §6 |
| `dpkg --get-selections` / `--set-selections` | Dump/restore desired states | §4.4 — mass rebuild |
| `dpkg --add-architecture arch` | Enable multi-arch | Requires `apt update` afterwards |
| `dpkg --print-architecture` | Native architecture | `amd64`, `arm64`, … |

```console
$ dpkg -L nginx-light | grep -E '^/usr/sbin|^/etc'
/etc/nginx
/etc/nginx/modules-enabled
/usr/sbin/nginx

$ dpkg -s nginx-light | head -8
Package: nginx-light
Status: install ok installed
Priority: optional
Section: httpd
Installed-Size: 1387
Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
Architecture: amd64
Version: 1.22.1-9

$ dpkg -S /usr/sbin/sshd
openssh-server: /usr/sbin/sshd

$ dpkg -S /usr/lib/x86_64-linux-gnu/libssl.so.3
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3
```

`dpkg-query` is the scriptable, stable interface — prefer it in automation because `dpkg -l` output is column-truncated to terminal width:

```console
$ dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' openssh-server nginx-light
openssh-server	1:9.2p1-2+deb12u3	install ok installed
nginx-light	1.22.1-9	install ok installed

$ dpkg-query -W -f='${binary:Package} ${Installed-Size}\n' | sort -k2 -rn | head -5
linux-image-6.1.0-18-amd64 361447
libreoffice-core 267334
python3.11 12894
perl-base 7443
libc6:amd64 13165
```

> **Truncation trap:** `dpkg -l | grep foo` inside a CI job with `COLUMNS` unset can silently cut the version column. Always use `dpkg-query -W -f=…` in scripts.

### 3.4 Conffiles: the one place dpkg negotiates with you

Any file listed in `<pkg>.conffiles` is checksummed at install time. On upgrade dpkg compares three hashes: shipped-old, shipped-new, on-disk. If the admin modified it *and* the package ships a different new version, dpkg **prompts**:

```console
Configuration file '/etc/ssh/sshd_config'
 ==> Modified (by you or by a script) since installation.
 ==> Package distributor has shipped an updated version.
   What would you like to do about it ?  Your options are:
    Y or I  : install the package maintainer's version
    N or O  : keep your currently-installed version
      D     : show the differences between the versions
      Z     : start a shell to examine the situation
 The default action is to keep your current version.
*** sshd_config (Y/I/N/O/D/Z) [default=N] ?
```

In unattended automation this prompt is a **hang, not an error** — the single most common cause of a stuck `apt-get upgrade` in CI or in `unattended-upgrades`. The deterministic policy must be declared:

| Option | Behaviour | When to use |
|---|---|---|
| `--force-confold` | Keep the on-disk file | Config is managed by Ansible/Puppet — the source of truth is elsewhere |
| `--force-confnew` | Take the maintainer's file | Config is not managed and you want upstream defaults |
| `--force-confdef` | Take the default action when there *is* one; otherwise fall through to `confold`/`confnew` | Always combine with one of the two above |
| `--force-confmiss` | Restore a conffile the admin deleted | Repair path |

```console
$ sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
```

Set it once, globally, on every managed host:

```console
$ cat /etc/apt/apt.conf.d/99local-conffiles
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
};
```

After an upgrade, `.dpkg-dist` (maintainer's version, yours kept) and `.dpkg-old` (your version, maintainer's taken) files appear. A fleet-wide sweep for drift:

```console
$ find /etc -name '*.dpkg-dist' -o -name '*.dpkg-old' -o -name '*.ucf-dist' | head
/etc/ssh/sshd_config.dpkg-dist
/etc/sysctl.conf.dpkg-old
```

### 3.5 `dpkg-reconfigure` and debconf

`debconf` is a separate database (`/var/cache/debconf/config.dat`) holding answers to maintainer-script questions. `dpkg-reconfigure` replays a package's `config` script and re-runs `postinst` with those answers.

```console
$ sudo dpkg-reconfigure -plow tzdata
Current default time zone: 'Europe/Madrid'
Local time is now:      Tue Aug 25 11:04:12 CEST 2026.
Universal Time is now:  Tue Aug 25 09:04:12 UTC 2026.

$ sudo dpkg-reconfigure -f noninteractive locales
Generating locales (this might take a while)...
  en_US.UTF-8... done
Generation complete.
```

| Flag | Meaning |
|---|---|
| `-p, --priority=<low\|medium\|high\|critical>` | Show questions at or above this priority. `-plow` shows *everything* |
| `-f, --frontend=<dialog\|readline\|noninteractive\|text>` | Which UI to use |
| `-u, --unseen-only` | Only ask questions never answered before |
| `--force` | Reconfigure even a package in a broken state |

Inspect and pre-seed answers (`debconf-utils` package):

```console
$ sudo debconf-show tzdata
* tzdata/Areas: Europe
* tzdata/Zones/Europe: Madrid
  tzdata/Zones/Etc: UTC

$ sudo debconf-get-selections | grep ^postfix
postfix	postfix/main_mailer_type	select	Internet Site
postfix	postfix/mailname	string	mail.example.internal
```

Pre-seeding is how you install interactive packages non-interactively in a golden image:

```console
$ cat postfix.preseed
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string mail.example.internal
postfix postfix/destinations string mail.example.internal, localhost.localdomain, localhost
postfix postfix/mynetworks string 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 10.0.0.0/8

$ sudo debconf-set-selections < postfix.preseed
$ sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
```

---

## 4. Layer 2 — APT: sources, policy, resolution

### 4.1 Repository layout on the wire

Understanding the on-disk layout of an archive is what turns "GPG error" and "404 Not Found" from mysteries into two-minute fixes.

```
http://deb.debian.org/debian/
├── dists/
│   └── bookworm/
│       ├── InRelease              ← index of indices, inline-signed (clearsigned)
│       ├── Release                ← same content, unsigned
│       ├── Release.gpg            ← detached signature over Release (legacy path)
│       ├── main/
│       │   ├── binary-amd64/
│       │   │   ├── Packages.gz    ← every package stanza for this component/arch
│       │   │   ├── Packages.xz
│       │   │   └── Release
│       │   ├── binary-arm64/…
│       │   ├── source/Sources.gz
│       │   └── Contents-amd64.gz  ← path → package map, consumed by apt-file
│       ├── contrib/…
│       └── non-free/…
└── pool/
    └── main/
        └── n/nginx/
            ├── nginx-light_1.22.1-9_amd64.deb
            └── nginx-common_1.22.1-9_all.deb
```

`InRelease` carries SHA256 sums of every `Packages`/`Sources`/`Contents` file, and each `Packages` stanza carries the SHA256 of the `.deb` in `pool/`. Verifying the OpenPGP signature on `InRelease` therefore transitively authenticates every artifact — a hash chain rooted in one key. This is why an unsigned repository is a root-equivalent compromise vector and why `[trusted=yes]` must never appear in production.

`Release` also carries `Date:` and `Valid-Until:`. An index past `Valid-Until` is refused — the defence against an attacker freezing your mirror to withhold security updates. It is also why a two-year-old container image fails `apt-get update` (see §7.4).

### 4.2 `sources.list`: both syntaxes

**One-line format** (`/etc/apt/sources.list`, `/etc/apt/sources.list.d/*.list`):

```
deb [ options ] URI suite [component1] [component2] …
deb-src [ options ] URI suite [component …]
```

```console
$ cat /etc/apt/sources.list
deb     http://deb.debian.org/debian           bookworm            main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian           bookworm            main contrib non-free non-free-firmware
deb     http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb     http://deb.debian.org/debian           bookworm-updates    main contrib non-free non-free-firmware
```

| Token | Meaning |
|---|---|
| `deb` | Binary packages (`.deb`) |
| `deb-src` | Source packages — needed for `apt-get source` / `build-dep`, adds index download cost otherwise |
| URI | `http://`, `https://`, `ftp://`, `file:/`, `cdrom:`, `copy:`, `tor+http://`, `mirror+file:` |
| suite | `bookworm`, or a *class* alias: `stable`, `testing`, `unstable`, `oldstable`. **Never use class aliases on a server** — the host silently dist-upgrades itself on release day |
| component | `main` (DFSG-free), `contrib` (free but depends on non-free), `non-free`, `non-free-firmware` (split out in Debian 12) |
| `[ options ]` | `arch=amd64,arm64`, `signed-by=/path/to.gpg`, `trusted=yes` (never), `by-hash=yes`, `allow-insecure=yes` (never) |

**deb822 format** (`/etc/apt/sources.list.d/*.sources`) — the modern form. Multi-line, comment-friendly, and it can carry the signing key inline, which removes a whole class of bootstrap ordering problems:

```console
$ cat /etc/apt/sources.list.d/debian.sources
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main contrib non-free non-free-firmware
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes

Types: deb
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Enabled: yes
```

| Aspect | One-line `.list` | deb822 `.sources` |
|---|---|---|
| Readability / diffability | One long line; config-management templating is fragile | One field per line; clean diffs |
| Multiple suites per entry | No — one line each | Yes — `Suites:` takes a list |
| Inline key | No | Yes — `Signed-By:` can hold an ASCII-armored block |
| Disable an entry | Comment out with `#` | `Enabled: no` |
| Tooling support | Universal | apt ≥ 1.1; default in Debian 12 for new sources, standard in Debian 13 |
| Verdict | Legacy; keep for compatibility | **Default for new automation** |

> Files in `sources.list.d/` must end in `.list` or `.sources`. A file named `internal.list.bak` or `internal.repo` is **silently ignored** — a recurring cause of "my repository disappeared after the config-management run".

### 4.3 Repository trust: keyrings, not `apt-key`

`apt-key` added keys to a single global keyring, which meant **any** key in it could sign **any** repository. A compromised third-party vendor key could then sign a fake `libc6`. `apt-key` is deprecated (it warns loudly on modern apt and is being removed from the archive) — do not use it, and remove it from any runbook that still mentions it.

The correct pattern scopes one key to one repository:

```console
# 1. Fetch the key and de-armor it into a binary keyring under /usr/share/keyrings
$ curl -fsSL https://download.example.com/gpg.key \
    | sudo gpg --dearmor -o /usr/share/keyrings/example-archive-keyring.gpg

# 2. Verify the fingerprint out-of-band BEFORE trusting it
$ gpg --no-default-keyring --keyring /usr/share/keyrings/example-archive-keyring.gpg \
      --list-keys --with-fingerprint
/usr/share/keyrings/example-archive-keyring.gpg
-----------------------------------------------
pub   rsa4096 2024-01-15 [SC]
      A1B2 C3D4 E5F6 0718 2939  4A5B 6C7D 8E9F A0B1 C2D3
uid           [ unknown] Example Platform Archive <archive@example.com>

# 3. Bind the key to exactly that repository
$ sudo tee /etc/apt/sources.list.d/example.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.example.com/debian
Suites: bookworm
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/example-archive-keyring.gpg
EOF

$ sudo apt-get update
Hit:1 http://deb.debian.org/debian bookworm InRelease
Get:2 https://download.example.com/debian bookworm InRelease [3,182 B]
Get:3 https://download.example.com/debian bookworm/main amd64 Packages [12.4 kB]
Fetched 15.6 kB in 1s (18.9 kB/s)
Reading package lists... Done
```

| Mechanism | Scope of trust | Verdict |
|---|---|---|
| `apt-key add` → `/etc/apt/trusted.gpg` | Global — signs anything | ❌ Deprecated, removed |
| Drop `.gpg` into `/etc/apt/trusted.gpg.d/` | Global — signs anything | ⚠️ Works, but same over-trust flaw |
| `Signed-By:` → `/usr/share/keyrings/*.gpg` | One repository | ✅ Correct |
| `Signed-By:` with inline armored key in deb822 | One repository, no extra file | ✅ Correct, best for cloud-init |
| `[trusted=yes]` | No verification at all | ❌ Never in production |

Audit which keys a host actually trusts:

```console
$ apt-key list 2>/dev/null | head -5
Warning: apt-key is deprecated. Manage keyring files in trusted.gpg.d instead (see apt-key(8)).
$ ls -l /etc/apt/trusted.gpg.d/ /usr/share/keyrings/
/etc/apt/trusted.gpg.d/:
total 16
-rw-r--r-- 1 root root 8138 Mar 12  2023 debian-archive-bookworm-automatic.asc
-rw-r--r-- 1 root root 2263 Mar 12  2023 debian-archive-bookworm-security-automatic.asc

/usr/share/keyrings/:
total 12
-rw-r--r-- 1 root root 4162 Mar 12  2023 debian-archive-keyring.gpg
-rw-r--r-- 1 root root 2795 Aug 20 09:11 example-archive-keyring.gpg
```

### 4.4 The apt command surface

**Update the indices** — this touches no packages; it refreshes `/var/lib/apt/lists/`:

```console
$ sudo apt-get update
Hit:1 http://deb.debian.org/debian bookworm InRelease
Get:2 http://security.debian.org/debian-security bookworm-security InRelease [48.0 kB]
Get:3 http://deb.debian.org/debian bookworm-updates InRelease [55.4 kB]
Get:4 http://security.debian.org/debian-security bookworm-security/main amd64 Packages [186 kB]
Fetched 289 kB in 1s (243 kB/s)
Reading package lists... Done
```

`Hit` = unchanged (validated by ETag/Last-Modified), `Get` = downloaded, `Ign` = ignored, `Err` = failed.

**Upgrade semantics — the distinction that gets asked and that breaks production:**

| Command | Installs new packages? | Removes packages? | Use |
|---|---|---|---|
| `apt-get upgrade` | **No** | **No** | Most conservative. Held-back packages simply stay behind |
| `apt upgrade` | **Yes** | No | Interactive convenience |
| `apt-get dist-upgrade` | Yes | **Yes** | Release upgrades, kernel ABI transitions |
| `apt full-upgrade` | Yes | **Yes** | Identical to `dist-upgrade` |

```console
$ sudo apt-get upgrade
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
Calculating upgrade... Done
The following packages have been kept back:
  linux-image-amd64
The following packages will be upgraded:
  openssl libssl3
2 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.
Need to get 2,764 kB of archives.
After this operation, 0 B of additional disk space will be used.
```

"Kept back" here means the upgrade would require installing a *new* package (`linux-image-6.1.0-19-amd64`), which `apt-get upgrade` refuses by design. This is not a bug; it is the reason kernel updates never land from `apt-get upgrade` alone, and it is a genuine, repeatedly-observed cause of unpatched kernels on hosts whose automation only runs `upgrade`.

**Install, remove, purge, and the manual/auto flag:**

```console
$ sudo apt-get install nginx-light=1.22.1-9
$ sudo apt-get install -t bookworm-backports linux-image-amd64
$ sudo apt-get remove nginx-light      # leaves /etc/nginx → state rc
$ sudo apt-get purge nginx-light       # removes conffiles too
$ sudo apt-get autoremove --purge      # drop orphaned auto-installed deps + their conffiles
$ sudo apt autopurge                   # apt(8) shorthand for the above
```

APT records *why* each package is present. `manual` = you asked for it; `auto` = pulled in as a dependency and eligible for `autoremove` once nothing needs it. This flag is the basis of minimal-image auditing:

```console
$ apt-mark showmanual | head
apt
bash
ca-certificates
libc6
linux-image-amd64
nginx-light
openssh-server
systemd

$ apt-mark showauto | wc -l
327
```

```console
$ sudo apt-mark hold openssh-server
openssh-server set on hold.
$ apt-mark showhold
openssh-server
$ sudo apt-mark unhold openssh-server
Canceled hold on openssh-server.
```

`apt-mark hold` writes the hold into the dpkg selection, so `dpkg -l` shows `hi` and even a raw `dpkg -i` refuses. The dpkg-native equivalent, useful when apt is unavailable:

```console
$ echo "openssh-server hold" | sudo dpkg --set-selections
$ dpkg --get-selections | grep -v '^\S*\s*install$'
openssh-server					hold
libxcb-shape0:amd64				deinstall
```

**Fleet cloning** — reproduce a host's package set on a fresh machine:

```console
# On the reference host
$ dpkg --get-selections '*' > selections.txt
$ apt-mark showauto > auto.txt

# On the new host
$ sudo dpkg --set-selections < selections.txt
$ sudo apt-get dselect-upgrade
$ sudo xargs apt-mark auto < auto.txt
```

**Cache and disk hygiene:**

```console
$ sudo apt-get clean          # empty /var/cache/apt/archives entirely
$ sudo apt-get autoclean      # drop only .debs no longer downloadable
$ du -sh /var/cache/apt/archives
412M	/var/cache/apt/archives
```

In a `Dockerfile`, `rm -rf /var/lib/apt/lists/*` in the *same* `RUN` layer is mandatory — a separate `RUN rm` leaves the data in the earlier layer and saves nothing.

**Source and build-dependency operations** (require `deb-src` lines):

```console
$ apt-get source nginx
Reading package lists... Done
NOTICE: 'nginx' packaging is maintained in the 'Git' version control system at:
https://salsa.debian.org/nginx-team/nginx.git
Need to get 1,608 kB of source archives.
Get:1 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (dsc) [3,081 B]
Get:2 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (tar) [1,338 kB]
Get:3 http://deb.debian.org/debian bookworm/main nginx 1.22.1-9 (diff) [267 kB]
dpkg-source: info: extracting nginx in nginx-1.22.1

$ sudo apt-get build-dep nginx
$ apt-get download nginx-light          # fetch the .deb without installing
$ apt-get --print-uris install nginx-light   # just print the URLs — for air-gapped mirroring
```

**`apt` vs `apt-get` vs `aptitude` — choose deliberately:**

| Dimension | `apt-get` / `apt-cache` | `apt` | `aptitude` |
|---|---|---|---|
| CLI stability guarantee | **Yes** — documented as script-safe | **No** — `apt` prints `WARNING: apt does not have a stable CLI interface. Use with caution in scripts.` | Reasonably stable |
| Progress bar / colour / paging | Minimal | Yes | TUI + CLI |
| Dependency resolver | APT internal (EDSP-pluggable) | Same as `apt-get` | **Its own**, offers ranked alternative solutions interactively |
| `upgrade` installs new packages | No | Yes | Yes |
| Auto-removes on upgrade | No | No (`full-upgrade` does) | Yes, more aggressively |
| Search-pattern language | Basic regex | Basic regex | Rich patterns (`~i`, `~M`, `~n`, `~D`) |
| "Why is this installed?" | Indirect | Indirect | `aptitude why` / `why-not` — best-in-class |
| Installed by default | Yes | Yes | No (`apt install aptitude`) |
| **Verdict** | **Scripts, CI, config management** | **Interactive shells** | **Untangling hard dependency knots** |

```console
$ aptitude why libssl3
i   openssh-server Depends libssl3 (>= 3.0.0)

$ aptitude why-not nginx-full
i   nginx-light Conflicts nginx-full

$ aptitude search '~i~M~nlib' | head -3       # installed AND auto AND name matches 'lib'
i A libacl1                       - access control list - shared library
i A libaom3                       - AV1 Video Codec Library
i A libapparmor1                  - changehat AppArmor library
```

`aptitude`'s alternative resolver is genuinely useful during a dist-upgrade knot: where `apt-get` reports an unsatisfiable set and stops, `aptitude` offers successive solutions and lets you reject individual actions. That is its one irreplaceable capability; everything else is better served by `apt-get` in automation.

### 4.5 Querying: `apt-cache`, `apt`, and policy

```console
$ apt-cache policy nginx-light
nginx-light:
  Installed: 1.22.1-9
  Candidate: 1.22.1-9
  Version table:
 *** 1.22.1-9 500
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
        100 /var/lib/dpkg/status
```

Reading this: `***` marks the installed version; the left number is the *pin priority* of that version; each indented line is a source that offers it. `100 /var/lib/dpkg/status` is the pseudo-source representing "already installed" — its default priority of 100 is exactly why an installed version is never spontaneously downgraded.

```console
$ apt-cache policy
Package files:
 100 /var/lib/dpkg/status
     release a=now
 500 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
     release v=12,o=Debian,a=stable-security,n=bookworm-security,l=Debian-Security,c=main,b=amd64
     origin security.debian.org
 500 http://deb.debian.org/debian bookworm/main amd64 Packages
     release v=12.5,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=amd64
     origin deb.debian.org
Pinned packages:
```

Those `a=`, `o=`, `n=`, `l=`, `c=` tokens are exactly the selectors available to pinning rules in §4.6.

```console
$ apt-cache show nginx-light | head -6
Package: nginx-light
Version: 1.22.1-9
Installed-Size: 1387
Maintainer: Debian Nginx Maintainers <pkg-nginx-maintainers@alioth-lists.debian.net>
Architecture: amd64
Depends: nginx-common (= 1.22.1-9), libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0)

$ apt-cache depends nginx-light
nginx-light
  Depends: nginx-common
  Depends: libc6
  Depends: libcrypt1
  Depends: libpcre2-8-0
  Depends: libssl3
  Depends: zlib1g
  Recommends: nginx-doc
  Conflicts: nginx-core
  Conflicts: nginx-extras
  Conflicts: nginx-full
  Replaces: nginx-core

$ apt-cache rdepends --installed libssl3 | head -8
libssl3
Reverse Depends:
  openssh-server
  openssh-client
  curl
  wget
  python3.11
  systemd

$ apt-cache madison openssl
    openssl | 3.0.11-1~deb12u2 | http://security.debian.org/debian-security bookworm-security/main amd64 Packages
    openssl |    3.0.9-1 | http://deb.debian.org/debian bookworm/main amd64 Packages
    openssl |    3.0.9-1 | http://deb.debian.org/debian bookworm/main Sources

$ apt-cache stats
Total package names: 63871 (1,277 k)
Total package structures: 63871 (3,576 k)
  Normal packages: 49417
  Pure virtual packages: 663
  Single virtual packages: 4991
  Mixed virtual packages: 480

$ apt-cache showpkg nginx-light | head -12
Package: nginx-light
Versions:
1.22.1-9 (/var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages)
 Description Language:
                 File: /var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_main_binary-amd64_Packages
                  MD5: 9b47c0f83e3a4e79b1c1f4a89e2d3b12

Reverse Depends:
  nginx,nginx-light
Dependencies:
1.22.1-9 - nginx-common (5 1.22.1-9) libc6 (2 2.34) libcrypt1 (2 1:4.1.0)
```

| Query | `apt-cache` (script-safe) | `apt` (interactive) |
|---|---|---|
| Full metadata | `apt-cache show pkg` | `apt show pkg` |
| Search names + descriptions | `apt-cache search regex` | `apt search regex` |
| Search names only | `apt-cache search --names-only regex` | `apt search --names-only regex` |
| Forward deps | `apt-cache depends pkg` | `apt depends pkg` |
| Reverse deps | `apt-cache rdepends pkg` | `apt rdepends pkg` |
| Which versions, from where | `apt-cache policy pkg` | `apt policy pkg` |
| Version/suite matrix | `apt-cache madison pkg` | — |
| Installed list | `dpkg-query -W` | `apt list --installed` |
| Pending upgrades | — | `apt list --upgradable` |
| Cache statistics | `apt-cache stats` | — |
| Unsatisfiable deps in the cache | `apt-cache unmet` | — |

```console
$ apt list --upgradable
Listing... Done
libssl3/bookworm-security 3.0.11-1~deb12u2 amd64 [upgradable from: 3.0.9-1]
openssl/bookworm-security 3.0.11-1~deb12u2 amd64 [upgradable from: 3.0.9-1]
```

### 4.6 Pinning: `/etc/apt/preferences.d/`

Pinning is the declarative policy layer. Every candidate version gets a priority; APT installs the highest.

| Priority | Effect |
|---|---|
| `P >= 1000` | Install even if it is a **downgrade** |
| `990 ≤ P < 1000` | Install even from a non-target release, unless the installed version is newer |
| `500 ≤ P < 990` | Install unless a target-release version exists, or the installed one is newer |
| `100 ≤ P < 500` | Install unless a version from another distribution exists, or the installed one is newer |
| `0 < P < 100` | Install only if the package is not installed at all |
| `P <= 0` | **Never install** this version |

Defaults: 100 for the installed version, 500 for anything else available, 1 for archives marked `NotAutomatic` (e.g. `experimental`, `*-backports`), 100 for `NotAutomatic` + `ButAutomaticUpgrades` (e.g. `*-updates`).

**Complete, production-grade preferences set** — three separate files, because `preferences.d` entries are cheaper to reason about than one monolith:

```console
$ cat /etc/apt/preferences.d/10-security-priority
# Security updates always win, even over a locally-pinned vendor archive.
Package: *
Pin: release o=Debian,a=stable-security
Pin-Priority: 990

$ cat /etc/apt/preferences.d/20-vendor-archive
# The vendor archive may ONLY provide its own packages. Without this,
# a compromised or careless vendor mirror could shadow libc6 or openssl.
Package: *
Pin: origin download.example.com
Pin-Priority: -1

Package: vendor-agent vendor-agent-plugins vendor-cli
Pin: origin download.example.com
Pin-Priority: 700

$ cat /etc/apt/preferences.d/30-backports-optin
# Backports stay opt-in via `apt-get -t bookworm-backports install`,
# EXCEPT the kernel metapackage, which we want tracking backports.
Package: *
Pin: release a=bookworm-backports
Pin-Priority: 100

Package: linux-image-amd64 linux-headers-amd64 firmware-linux-free
Pin: release a=bookworm-backports
Pin-Priority: 550
```

Pin selectors: `a=` archive/suite, `n=` codename, `v=` version, `c=` component, `o=` origin, `l=` label, `b=` architecture. `Pin: version 1.22.*` matches by glob; `Pin: origin ""` matches local files.

Always verify a pin — a typo produces silence, not an error:

```console
$ apt-cache policy vendor-agent
vendor-agent:
  Installed: 4.2.0
  Candidate: 4.3.1
  Version table:
     4.3.1 700
        700 https://download.example.com/debian bookworm/main amd64 Packages
 *** 4.2.0 100
        100 /var/lib/dpkg/status

$ apt-cache policy libssl3
libssl3:
  Installed: 3.0.11-1~deb12u2
  Candidate: 3.0.11-1~deb12u2
  Version table:
 *** 3.0.11-1~deb12u2 990
        990 http://security.debian.org/debian-security bookworm-security/main amd64 Packages
        100 /var/lib/dpkg/status
        500 http://deb.debian.org/debian bookworm/main amd64 Packages
     -1 3.0.9-2~vendor1 
        -1 https://download.example.com/debian bookworm/main amd64 Packages
```

That last block is the vendor-shadowing attack neutralised: the vendor's `libssl3` is present in the index but pinned to `-1` and can never be installed.

### 4.7 `apt.conf` — runtime behaviour

```console
$ apt-config dump | grep -E '^(APT::Install-Recommends|Acquire::Retries|Dir::Cache)'
APT::Install-Recommends "0";
Acquire::Retries "3";
Dir::Cache "var/cache/apt/";
```

A complete, opinionated configuration for hosts behind a flaky link and a caching proxy:

```console
$ cat /etc/apt/apt.conf.d/00aptitude-platform
// Network resilience — a transient DNS blip must not fail a whole rollout.
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ForceIPv4 "false";

// Route through the on-prem caching proxy; bypass it for the internal archive.
Acquire::http::Proxy "http://apt-cache.example.internal:3142";
Acquire::http::Proxy::apt.example.internal "DIRECT";

// Fetch indices by content hash: immune to a mirror rotating mid-download.
Acquire::By-Hash "yes";

// Non-interactive defaults.
APT::Get::Assume-Yes "false";       // leave explicit -y to the caller
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Use-Pty "false";              // clean, line-buffered logs in CI

// Keep the cache bounded on nodes with small root volumes.
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
```

Logs written by APT, and what each answers:

| File | Answers |
|---|---|
| `/var/log/apt/history.log` | *What* transactions ran, when, by which command line, requested by which user |
| `/var/log/apt/term.log` | The full terminal output of dpkg during those transactions |
| `/var/log/dpkg.log` | Per-package state transitions with timestamps |
| `/var/log/unattended-upgrades/` | Automatic-upgrade decisions and outcomes |

```console
$ tail -12 /var/log/apt/history.log
Start-Date: 2026-08-24  03:17:02
Commandline: /usr/bin/unattended-upgrade
Upgrade: libssl3:amd64 (3.0.9-1, 3.0.11-1~deb12u2), openssl:amd64 (3.0.9-1, 3.0.11-1~deb12u2)
End-Date: 2026-08-24  03:17:19

$ grep ' status installed openssh-server' /var/log/dpkg.log
2026-08-19 04:12:44 status installed openssh-server:amd64 1:9.2p1-2+deb12u3
```

---

## 5. Finding which package owns — or would own — a file

This is one third of the objective and the single most useful skill in incident response. There are **two different questions** and they need two different tools.

| Question | Tool | Requires | Scope |
|---|---|---|---|
| Which **installed** package owns `/usr/sbin/sshd`? | `dpkg -S` | Nothing | Only installed packages; only files shipped in `data.tar` |
| Which package **would** provide `/usr/bin/dig`, installed or not? | `apt-file search` | `apt-file` + `apt-file update` | The whole archive, via `Contents-<arch>.gz` |

```console
$ dpkg -S /usr/sbin/sshd
openssh-server: /usr/sbin/sshd

$ dpkg -S /usr/bin/dig
dpkg-query: no path found matching pattern /usr/bin/dig

$ sudo apt-get install -y apt-file && sudo apt-file update
$ apt-file search /usr/bin/dig
dnsutils: /usr/bin/dig
bind9-dnsutils: /usr/bin/dig

$ sudo apt-get install -y bind9-dnsutils
$ dpkg -S /usr/bin/dig
bind9-dnsutils: /usr/bin/dig
```

`dpkg -S` takes a substring/glob, not just an exact path, which is both convenient and a source of noise:

```console
$ dpkg -S nginx.conf
nginx-common: /etc/nginx/nginx.conf
nginx-common: /usr/share/nginx/conf/nginx.conf

$ dpkg -S '*/libssl.so.3'
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3
```

**The four cases where `dpkg -S` legitimately finds nothing** — recognising which one you are in *is* the diagnosis:

1. **The file is not from a package at all.** Someone installed it by hand. This is untracked state; it must be packaged or removed.
2. **The file was created at runtime**, by a maintainer script, a systemd unit, or the application itself. `/etc/ssh/ssh_host_ed25519_key` is generated by `openssh-server`'s `postinst`, so it has no owner.
3. **The path is a symlink resolved differently.** With usr-merge, `/bin/ls` and `/usr/bin/ls` refer to the same inode but the `.list` records only one. Use `dpkg -S "$(readlink -f /bin/ls)"`.
4. **The package is not installed.** Use `apt-file`.

```console
$ dpkg -S /etc/ssh/ssh_host_ed25519_key
dpkg-query: no path found matching pattern /etc/ssh/ssh_host_ed25519_key
$ dpkg -S /bin/ls
dpkg-query: no path found matching pattern /bin/ls
$ dpkg -S "$(readlink -f /bin/ls)"
coreutils: /usr/bin/ls
```

**Finding the package behind a missing shared library** — the classic "error while loading shared libraries" triage:

```console
$ ./vendor-binary
./vendor-binary: error while loading shared libraries: libpcre2-8.so.0: cannot open shared object file: No such file or directory

$ ldd ./vendor-binary | grep 'not found'
	libpcre2-8.so.0 => not found

$ apt-file search --regexp '/libpcre2-8\.so\.0$'
libpcre2-8-0: /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0

$ sudo apt-get install -y libpcre2-8-0
$ ldd ./vendor-binary | grep pcre2
	libpcre2-8.so.0 => /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0 (0x00007f3a9c1f2000)
```

**The full audit sweep** — enumerate every unowned executable on a host. Run this on any machine before declaring it "under configuration management":

```console
$ for f in $(find /usr/local/bin /usr/bin /usr/sbin -maxdepth 1 -type f -perm -u+x 2>/dev/null); do
    dpkg -S "$f" >/dev/null 2>&1 || echo "UNOWNED: $f"
  done
UNOWNED: /usr/local/bin/deploy.sh
UNOWNED: /usr/local/bin/kubectl
UNOWNED: /usr/bin/vendor-agent-shim
```

Other `apt-file` modes:

```console
$ apt-file list bind9-dnsutils | head -5
bind9-dnsutils: /usr/bin/delv
bind9-dnsutils: /usr/bin/dig
bind9-dnsutils: /usr/bin/mdig
bind9-dnsutils: /usr/bin/nslookup
bind9-dnsutils: /usr/bin/nsupdate

$ apt-file search --package-only ldconfig
libc-bin
```

---

## 6. Integrity verification

Three layers of assurance, with increasing cost and coverage:

| Level | Tool | What it proves | Cost | Blind spot |
|---|---|---|---|---|
| Transport | `apt-get update` OpenPGP verification | The index (and hence every `.deb` hash) came from the key holder | Free | Compromised signing key |
| Artifact | `Packages` SHA256 vs downloaded `.deb` | The file on disk is bit-identical to what the archive published | Free, automatic | An artifact that was malicious upstream |
| Post-install | `dpkg -V` / `debsums` | Files on disk still match the shipped MD5 sums | Seconds to minutes | Files with no recorded checksum; conffiles (legitimately edited) |

```console
$ dpkg -V openssh-server
??5?????? c /etc/ssh/sshd_config

$ dpkg -V coreutils
$ echo $?
0

$ sudo dpkg -V
??5?????? c /etc/ssh/sshd_config
??5?????? c /etc/sysctl.conf
missing     /usr/share/doc/vendor-agent/changelog.gz
??5??????   /usr/sbin/nginx
```

The 9-character mask mirrors RPM's format; dpkg currently only implements the MD5 check, so in practice you read column 3:

| Position | Meaning |
|---|---|
| 3 | `5` — MD5 checksum differs |
| any | `?` — not checked / not verifiable |
| trailing letter | `c` — the file is a **conffile** (a difference here is expected and normal) |

The line that must trigger an investigation is `??5??????` **without** a `c` — a modified binary or library, i.e. a file that only an intruder or an out-of-band installation could have changed. `/usr/sbin/nginx` in the output above is exactly that case.

`debsums` covers more ground, including detecting *missing* files and checking against freshly-downloaded archives:

```console
$ sudo apt-get install -y debsums

$ sudo debsums -c                       # print only files that FAILED
/usr/sbin/nginx
debsums: checksum mismatch nginx-light file /usr/sbin/nginx

$ sudo debsums -s                       # silent except errors — ideal for cron/monitoring
debsums: no md5sums for vendor-agent

$ sudo debsums -ca                      # include conffiles in the check
/etc/ssh/sshd_config
/usr/sbin/nginx

$ sudo debsums -l                       # packages that ship NO md5sums at all
vendor-agent
```

`debsums -l` output is a security finding in its own right: a package with no `md5sums` file can never be verified. Third-party `.deb`s built with `fpm` frequently land here. Require `md5sums` in your vendor-package acceptance criteria.

**Restoring a tampered file to its packaged state** — a reinstall rewrites the payload without touching modified conffiles:

```console
$ sudo apt-get install --reinstall nginx-light
Reading package lists... Done
Building dependency tree... Done
0 upgraded, 0 newly installed, 1 reinstalled, 0 to remove and 0 not upgraded.
Need to get 509 kB of archives.
After this operation, 0 B of additional disk space will be used.
Get:1 http://deb.debian.org/debian bookworm/main amd64 nginx-light amd64 1.22.1-9 [509 kB]
Fetched 509 kB in 0s (2,884 kB/s)
(Reading database ... 41287 files and directories currently installed.)
Preparing to unpack .../nginx-light_1.22.1-9_amd64.deb ...
Unpacking nginx-light (1.22.1-9) over (1.22.1-9) ...
Setting up nginx-light (1.22.1-9) ...

$ dpkg -V nginx-light
$ echo $?
0
```

**Cross-checking the archive itself** — verify a `.deb` you were handed matches what the archive published:

```console
$ apt-cache show nginx-light | grep -E '^(SHA256|Filename|Size)'
Filename: pool/main/n/nginx/nginx-light_1.22.1-9_amd64.deb
Size: 508984
SHA256: 4f8a2b91c73de5a0189f2c4b6e7d3a9c05f18b2e6d4a7c93f0b1e8d25a6c4739

$ sha256sum nginx-light_1.22.1-9_amd64.deb
4f8a2b91c73de5a0189f2c4b6e7d3a9c05f18b2e6d4a7c93f0b1e8d25a6c4739  nginx-light_1.22.1-9_amd64.deb
```

---

## 7. Failure diagnosis: the runbook

### 7.1 Triage order

Run these four commands, in this order, before changing anything. They are all read-only.

```console
$ sudo dpkg -C
$ sudo apt-get check
$ apt-cache policy
$ sudo lsof /var/lib/dpkg/lock-frontend 2>/dev/null
```

### 7.2 The lock

```console
$ sudo apt-get install nginx
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 3421 (unattended-upgr)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

| Lock file | Held by |
|---|---|
| `/var/lib/dpkg/lock-frontend` | Any front end holding a *user-visible* transaction (apt, aptitude, unattended-upgrades) |
| `/var/lib/dpkg/lock` | dpkg itself, during the actual unpack/configure |
| `/var/lib/apt/lists/lock` | `apt-get update` |
| `/var/cache/apt/archives/lock` | Package downloads |

```console
$ sudo lsof /var/lib/dpkg/lock-frontend
COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
unattended 3421 root    4uW  REG  254,1        0  262 /var/lib/dpkg/lock-frontend

$ systemctl list-units --type=service --state=running | grep -Ei 'apt|unattended'
  apt-daily-upgrade.service   loaded active running   Daily apt upgrade and clean activities
```

**Wait for it.** Deleting the lock while dpkg is mid-transaction produces a genuinely corrupted `status` database. If you must serialise around it — the correct pattern for CI and config management:

```console
$ sudo systemd-run --property=After=apt-daily.service --wait --pipe \
    apt-get -y install nginx-light
```

Or, in a provisioning script:

```bash
#!/bin/bash
set -euo pipefail
for i in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  echo "waiting for dpkg frontend lock (${i}/60)"
  sleep 5
done
DEBIAN_FRONTEND=noninteractive apt-get -y install "$@"
```

In cloud images the standard fix is to disable the timers entirely before provisioning:

```console
$ sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
```

### 7.3 Interrupted transaction: `iU`, `iF`, `iH`

```console
$ sudo dpkg -C
The following packages are in a mess due to serious problems during
installation.  They must be reinstalled for them (and any packages
that depend on them) to function properly:
 vendor-agent   Vendor observability agent

The following packages are only half configured, probably due to problems
configuring them the first time.  The configuration should be retried using
dpkg --configure <package> or the configure menu option in dselect:
 nginx-core     nginx web/proxy server (standard version)
```

The escalation ladder, least destructive first:

```console
# 1. Finish what was interrupted
$ sudo dpkg --configure -a

# 2. Let APT repair unmet dependencies
$ sudo apt-get -f install
$ sudo apt-get check

# 3. Force a clean re-unpack of the specific package
$ sudo apt-get install --reinstall vendor-agent

# 4. Package in state iR that dpkg refuses to remove
$ sudo dpkg --remove --force-remove-reinstreq vendor-agent

# 5. Failing postrm blocking removal — neutralise it, then purge
$ sudo ls -l /var/lib/dpkg/info/vendor-agent.*
$ sudo mv /var/lib/dpkg/info/vendor-agent.postrm /root/vendor-agent.postrm.bak
$ sudo dpkg --purge vendor-agent
```

Step 5 is a genuine last resort and it *is* a departure from the transactional model: you are lying to dpkg about the package having cleaned up after itself. Record it in the change ticket and verify manually that the package's files, users and systemd units are gone.

**Force options — the trade-off table.** Every one of these buys progress with a loss of guarantee:

| Option | Buys | Costs |
|---|---|---|
| `--force-confdef,confold,confnew` | Non-interactive upgrades | A config decision made without review |
| `--force-overwrite` | Installs past a file conflict | Two packages now claim one path; removal of either breaks the other |
| `--force-depends` | Configures with unmet deps | The package may not run at all |
| `--force-remove-reinstreq` | Removes an `iR` package | Its `prerm`/`postrm` cleanup never ran |
| `--force-remove-essential` | Removes an `Essential: yes` package | Can render the system unbootable — effectively never correct |
| `--force-all` | Everything above | Do not use. Enumerate the specific forces you need |

```console
$ dpkg --force-help | head -20
dpkg forcing options - control behaviour when problems found:
  warn but continue:  --force-<thing>,<thing>,...
  stop with error:    --refuse-<thing>,<thing>,... | --no-force-<thing>,...
 Forcing things:
  [!] all                    Set all force options
  [*] downgrade              Replace a package with a lower version
      configure-any          Configure any package which may help this one
      hold                   Process even when marked "hold"
      remove-reinstreq       Remove package which requires installation
  [!] remove-essential       Remove an essential package
      depends                Turn all dependency problems into warnings
      depends-version        Turn dependency version problems into warnings
      confnew                Always use the new config files, don't prompt
      confold                Always use the old config files, don't prompt
      confdef                Use the default option for new config files
```

### 7.4 Index and signature failures

**Expired `Release`** — the archetypal stale-container failure:

```console
$ sudo apt-get update
E: Release file for http://deb.debian.org/debian/dists/bookworm/InRelease is not valid yet (invalid for another 2d 4h 11min 6s). Updates for this repository will not be applied.
```

"Not valid **yet**" means the *clock is wrong*, not the archive. Fix the clock, never the check:

```console
$ timedatectl
               Local time: Sat 2026-08-22 09:14:03 UTC
           Universal time: Sat 2026-08-22 09:14:03 UTC
                System clock synchronized: no
              NTP service: inactive
$ sudo timedatectl set-ntp true && sleep 5 && timedatectl | grep synchronized
                System clock synchronized: yes
```

The opposite message — `Release file … is not valid anymore (invalid since …)` — means the *mirror* is stale, or you are running a genuinely archived suite. For an archived release the correct answer is `snapshot.debian.org` or `archive.debian.org`, not `Acquire::Check-Valid-Until "false"`.

**Missing key:**

```console
$ sudo apt-get update
Get:2 https://download.example.com/debian bookworm InRelease [3,182 B]
Err:2 https://download.example.com/debian bookworm InRelease
  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 648ACFD622F3D138
Reading package lists... Done
W: GPG error: https://download.example.com/debian bookworm InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 648ACFD622F3D138
E: The repository 'https://download.example.com/debian bookworm InRelease' is not signed.
N: Updating from such a repository can't be done securely, and is therefore disabled by default.
```

Fix by installing the key with `Signed-By` (§4.3) after verifying the fingerprint out of band. Do **not** add `[trusted=yes]`.

**404 on the index** — almost always a wrong suite or a component that does not exist for that suite:

```console
$ sudo apt-get update
Err:3 https://download.example.com/debian bookwrom Release
  404  Not Found [IP: 203.0.113.10 443]
E: The repository 'https://download.example.com/debian bookwrom Release' does not have a Release file.
```

Confirm the archive's real layout before editing anything:

```console
$ curl -sSI https://download.example.com/debian/dists/bookworm/InRelease | head -1
HTTP/1.1 200 OK
$ curl -sS https://download.example.com/debian/dists/bookworm/Release | grep -E '^(Suite|Codename|Components|Architectures):'
Suite: stable
Codename: bookworm
Components: main
Architectures: amd64 arm64
```

**Hash sum mismatch** — a truncated download, a caching proxy serving a stale index, or a mirror rotating mid-sync:

```console
$ sudo apt-get update
E: Failed to fetch http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz
   Hash Sum mismatch
   Hashes of expected file:
    - SHA256:9c2b4f...
   Hashes of received file:
    - SHA256:e7a013...

$ sudo rm -rf /var/lib/apt/lists/*
$ sudo apt-get update
```

If it recurs, the proxy is the suspect — set `Acquire::By-Hash "yes"` and/or bypass the proxy for that host.

### 7.5 Unsatisfiable dependency sets

```console
$ sudo apt-get install vendor-agent
The following packages have unmet dependencies:
 vendor-agent : Depends: libssl1.1 (>= 1.1.0) but it is not installable
E: Unable to correct problems, you have held broken packages.
```

Two distinct root causes, distinguished by one command:

```console
$ apt-cache policy libssl1.1
libssl1.1:
  Installed: (none)
  Candidate: (none)
  Version table:
```

Empty version table ⇒ the package **does not exist in any configured suite**. `libssl1.1` was Debian 11; the vendor `.deb` was built for `bullseye` and is simply the wrong artifact for `bookworm`. The fix is a correctly-built package, not force-installing across the ABI boundary.

If instead a candidate exists but is pinned out:

```console
$ apt-cache policy libssl1.1
libssl1.1:
  Installed: (none)
  Candidate: (none)
  Version table:
     1.1.1w-0+deb11u1 -1
        -1 https://download.example.com/debian bookworm/main amd64 Packages
```

Candidate `(none)` with a `-1` entry ⇒ your own pinning rule is blocking it (§4.6). That is policy working as designed; change the policy consciously or reject the package.

Let APT explain its reasoning:

```console
$ sudo apt-get -s -o Debug::pkgProblemResolver=true install vendor-agent 2>&1 | head -20
$ aptitude why-not vendor-agent
Unable to find a reason to remove vendor-agent.
$ apt-get -s install vendor-agent          # -s = simulate, changes nothing
```

`apt-get -s` (`--simulate` / `--dry-run`) is the mandatory first step for any change on a production host. It prints the exact plan without touching the filesystem.

### 7.6 File conflicts between packages

```console
$ sudo apt-get install vendor-cli
Unpacking vendor-cli (2.1.0) ...
dpkg: error processing archive /var/cache/apt/archives/vendor-cli_2.1.0_amd64.deb (--unpack):
 trying to overwrite '/usr/bin/kubectl', which is also in package kubectl 1.29.4-1
Errors were encountered while processing:
 /var/cache/apt/archives/vendor-cli_2.1.0_amd64.deb
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

The packaging bug is that `vendor-cli` fails to declare `Conflicts`/`Replaces` for `kubectl`. Correct resolutions, in order of preference:

1. Remove the conflicting package: `sudo apt-get remove kubectl`.
2. Use `dpkg-divert` to relocate the incumbent file, preserving both packages:

```console
$ sudo dpkg-divert --add --rename --divert /usr/bin/kubectl.distrib /usr/bin/kubectl
Adding 'local diversion of /usr/bin/kubectl to /usr/bin/kubectl.distrib'
$ sudo apt-get install vendor-cli
$ dpkg-divert --list
local diversion of /usr/bin/kubectl to /usr/bin/kubectl.distrib
```

3. `--force-overwrite` — last resort, and it leaves the system with two packages claiming one path:

```console
$ sudo apt-get -o Dpkg::Options::="--force-overwrite" install vendor-cli
```

### 7.7 Disk exhaustion mid-transaction

```console
$ sudo apt-get -y dist-upgrade
dpkg: unrecoverable fatal error, aborting:
 unable to write to '/var/lib/dpkg/status': No space left on device
E: Sub-process /usr/bin/dpkg returned an error code (2)
```

Recovery sequence — reclaim space, then complete the interrupted transaction:

```console
$ df -h /var /
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda2        20G   20G     0 100% /

$ sudo apt-get clean                                    # /var/cache/apt/archives
$ sudo journalctl --vacuum-size=200M
Vacuuming done, freed 3.1G of archived journals.
$ dpkg -l 'linux-image-*' | awk '/^ii/ {print $2}'
linux-image-6.1.0-16-amd64
linux-image-6.1.0-17-amd64
linux-image-6.1.0-18-amd64
linux-image-amd64
$ sudo apt-get purge linux-image-6.1.0-16-amd64         # never the running one
$ uname -r
6.1.0-18-amd64

$ sudo dpkg --configure -a
$ sudo apt-get -f install
$ sudo dpkg -C && echo "clean"
clean
```

If `/var/lib/dpkg/status` itself was truncated:

```console
$ sudo cp -a /var/lib/dpkg/status /root/status.broken
$ sudo cp -a /var/lib/dpkg/status-old /var/lib/dpkg/status
$ ls -la /var/backups/dpkg.status*
-rw-r--r-- 1 root root 1893214 Aug 24 06:25 /var/backups/dpkg.status.0
-rw-r--r-- 1 root root  312884 Aug 17 06:25 /var/backups/dpkg.status.1.gz
$ sudo dpkg --audit
```

### 7.8 Diagnostic decision table

| Symptom | Layer | First command | Likely cause |
|---|---|---|---|
| `Could not get lock` | 2 | `lsof /var/lib/dpkg/lock-frontend` | `apt-daily.timer` / another operator |
| `dependency problems - leaving unconfigured` | 1 | `apt-get -f install` | `dpkg -i` used without resolving deps |
| Package shows `iU`/`iF`/`iH` | 1 | `dpkg --configure -a` | Interrupted transaction, failed `postinst` |
| `NO_PUBKEY` / `is not signed` | 2 | `apt-cache policy` + check `Signed-By` | Missing/rotated repository key |
| `not valid yet` | Host | `timedatectl` | Wrong system clock |
| `not valid anymore` | 2 | `curl .../Release \| grep Date` | Stale mirror or archived suite |
| `404 … does not have a Release file` | 2 | `curl -I .../dists/<suite>/InRelease` | Typo in suite/component, or suite retired |
| `Hash Sum mismatch` | 2 | `rm -rf /var/lib/apt/lists/*` | Truncated fetch or stale caching proxy |
| `held broken packages` | 2 | `apt-cache policy <dep>` | Wrong-release artifact, or a pin |
| `trying to overwrite … also in package` | 1 | `dpkg -S <path>` | Missing `Conflicts`/`Replaces` in packaging |
| `kept back` on upgrade | 2 | `apt-get -s dist-upgrade` | New dependency required; `upgrade` won't add packages |
| Upgrade hangs with no output | 1 | `ps -ef \| grep -E 'dpkg\|debconf'` | Conffile or debconf prompt awaiting input |
| `dpkg -V` shows `??5??????` without `c` | 6 | `apt-get install --reinstall` | Tampering or out-of-band install |
| File exists but `dpkg -S` finds nothing | — | `apt-file search` | Untracked state, or runtime-generated file |

---

## 8. Infrastructure manifests

### 8.1 `cloud-init` — deterministic first boot

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Provisions APT before ANY package operation: sources, keys, pinning, policy.

apt:
  preserve_sources_list: false
  primary:
    - arches: [default]
      uri: http://deb.debian.org/debian
  security:
    - arches: [default]
      uri: http://security.debian.org/debian-security
  # Route all fetches through the on-prem cache to survive an upstream outage.
  http_proxy: http://apt-cache.example.internal:3142
  conf: |
    Acquire::Retries "5";
    Acquire::http::Timeout "30";
    Acquire::By-Hash "yes";
    APT::Install-Recommends "false";
    APT::Install-Suggests "false";
    Dpkg::Options {
       "--force-confdef";
       "--force-confold";
    };
  sources:
    example-internal.sources:
      source: |
        Types: deb
        URIs: https://apt.example.internal/debian
        Suites: bookworm
        Components: main platform
        Architectures: amd64
      # Inline key: no bootstrap ordering problem, no extra file to ship.
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        mQINBGXFqZ0BEADQ8k2Vw3nJ7yTt0oQ9L1x4mZ8bR2cH5vN6dK1jP0wE3sA7fY9u
        REPLACE_WITH_THE_REAL_ARMORED_PUBLIC_KEY_OF_YOUR_ARCHIVE
        =AbCd
        -----END PGP PUBLIC KEY BLOCK-----

write_files:
  - path: /etc/apt/preferences.d/10-security-priority
    owner: root:root
    permissions: '0644'
    content: |
      Package: *
      Pin: release o=Debian,a=stable-security
      Pin-Priority: 990

  - path: /etc/apt/preferences.d/20-internal-archive
    owner: root:root
    permissions: '0644'
    content: |
      # The internal archive may ONLY supply platform packages.
      Package: *
      Pin: origin apt.example.internal
      Pin-Priority: -1

      Package: platform-agent platform-cli platform-node-exporter
      Pin: origin apt.example.internal
      Pin-Priority: 700

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root:root
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  - path: /etc/apt/apt.conf.d/52unattended-upgrades-local
    owner: root:root
    permissions: '0644'
    content: |
      Unattended-Upgrade::Origins-Pattern {
              "origin=Debian,codename=${distro_codename},label=Debian-Security";
              "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
      };
      Unattended-Upgrade::Package-Blacklist {
              "^linux-image-";
              "^linux-headers-";
      };
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
      Unattended-Upgrade::Automatic-Reboot "false";
      Unattended-Upgrade::MailReport "on-change";
      Unattended-Upgrade::Mail "platform-alerts@example.internal";
      Unattended-Upgrade::SyslogEnable "true";

package_update: true
package_upgrade: false

packages:
  - apt-file
  - ca-certificates
  - curl
  - debsums
  - gnupg
  - needrestart
  - unattended-upgrades
  - platform-agent

runcmd:
  # Provisioning must not race the daily timers.
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer]
  - [apt-file, update]
  # Prove the pinning actually took effect; fail the boot loudly if it did not.
  - |
    set -e
    if apt-cache policy libssl3 | grep -qE '^\s+700 https://apt\.example\.internal'; then
      echo "FATAL: internal archive is shadowing a base package" >&2
      exit 1
    fi
  - [systemctl, enable, --now, apt-daily.timer, apt-daily-upgrade.timer]

final_message: "APT control plane provisioned after $UPTIME seconds"
```

### 8.2 Ansible — converging APT state on an existing fleet

```yaml
---
# playbooks/apt-baseline.yml
# Converges the APT control plane. Idempotent; safe to run on every schedule.
- name: Converge Debian package-management baseline
  hosts: debian_fleet
  become: true
  gather_facts: true

  vars:
    internal_archive_url: "https://apt.example.internal/debian"
    internal_archive_key_url: "https://apt.example.internal/keys/platform.asc"
    internal_archive_fingerprint: "A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3"
    platform_packages:
      - platform-agent
      - platform-cli
      - platform-node-exporter
    held_packages:
      - openssh-server

  pre_tasks:
    - name: Fail fast on non-Debian hosts
      ansible.builtin.assert:
        that:
          - ansible_facts['os_family'] == 'Debian'
        fail_msg: "This playbook targets Debian-family hosts only."

  tasks:
    - name: Ensure prerequisite tooling is present
      ansible.builtin.apt:
        name:
          - apt-file
          - ca-certificates
          - debsums
          - gnupg
        state: present
        install_recommends: false
        update_cache: true
        cache_valid_time: 3600

    - name: Install the internal archive signing key into its own keyring
      ansible.builtin.get_url:
        url: "{{ internal_archive_key_url }}"
        dest: /etc/apt/keyrings/platform-archive.asc
        mode: "0644"
        owner: root
        group: root

    - name: Verify the key fingerprint before trusting it
      ansible.builtin.command:
        cmd: >-
          gpg --with-colons --import-options show-only --import
          /etc/apt/keyrings/platform-archive.asc
      register: key_show
      changed_when: false

    - name: Abort if the fingerprint does not match the expected value
      ansible.builtin.assert:
        that:
          - internal_archive_fingerprint in key_show.stdout
        fail_msg: >-
          Fingerprint mismatch on the internal archive key.
          Expected {{ internal_archive_fingerprint }}. Refusing to configure the repository.

    # ansible.builtin.deb822_repository requires ansible-core >= 2.15.
    - name: Configure the internal archive (deb822)
      ansible.builtin.deb822_repository:
        name: platform-internal
        types: [deb]
        uris: "{{ internal_archive_url }}"
        suites: "{{ ansible_facts['distribution_release'] }}"
        components: [main, platform]
        architectures: ["{{ ansible_facts['architecture'] | replace('x86_64', 'amd64') }}"]
        signed_by: /etc/apt/keyrings/platform-archive.asc
        enabled: true
        state: present
      notify: Refresh apt indices

    - name: Constrain the internal archive to platform packages only
      ansible.builtin.copy:
        dest: /etc/apt/preferences.d/20-internal-archive
        owner: root
        group: root
        mode: "0644"
        content: |
          # MANAGED BY ANSIBLE — manual edits will be reverted.
          Package: *
          Pin: origin apt.example.internal
          Pin-Priority: -1

          Package: {{ platform_packages | join(' ') }}
          Pin: origin apt.example.internal
          Pin-Priority: 700
      notify: Refresh apt indices

    - name: Enforce non-interactive conffile policy and no recommends
      ansible.builtin.copy:
        dest: /etc/apt/apt.conf.d/99platform
        owner: root
        group: root
        mode: "0644"
        content: |
          // MANAGED BY ANSIBLE
          APT::Install-Recommends "false";
          APT::Install-Suggests "false";
          Acquire::Retries "5";
          Dpkg::Options {
             "--force-confdef";
             "--force-confold";
          };
      notify: Refresh apt indices

    - name: Flush handlers so the cache is fresh before installing
      ansible.builtin.meta: flush_handlers

    - name: Install platform packages
      ansible.builtin.apt:
        name: "{{ platform_packages }}"
        state: present
        install_recommends: false

    - name: Apply security updates only
      ansible.builtin.apt:
        upgrade: safe          # maps to apt-get upgrade — never removes packages
        update_cache: true
        cache_valid_time: 3600
      register: apt_upgrade
      retries: 3
      delay: 30
      until: apt_upgrade is succeeded

    - name: Hold packages that must never move outside a change window
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop: "{{ held_packages }}"

    - name: Remove orphaned automatically-installed dependencies
      ansible.builtin.apt:
        autoremove: true
        purge: true

    - name: Detect files that no longer match their package checksums
      ansible.builtin.command:
        cmd: debsums -s
      register: debsums_result
      changed_when: false
      failed_when: false

    - name: Report integrity violations
      ansible.builtin.debug:
        msg: "INTEGRITY: {{ debsums_result.stderr_lines }}"
      when: debsums_result.stderr_lines | length > 0

    - name: Detect packages left in a broken dpkg state
      ansible.builtin.command:
        cmd: dpkg --audit
      register: dpkg_audit
      changed_when: false

    - name: Fail the run if any package is in a broken state
      ansible.builtin.assert:
        that:
          - dpkg_audit.stdout | trim | length == 0
        fail_msg: "Broken dpkg state on {{ inventory_hostname }}:\n{{ dpkg_audit.stdout }}"

  handlers:
    - name: Refresh apt indices
      ansible.builtin.apt:
        update_cache: true
```

### 8.3 Kubernetes — scheduled mirror synchronisation

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: apt-mirror
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: apt-mirror-data
  namespace: apt-mirror
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 400Gi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: aptly-config
  namespace: apt-mirror
data:
  aptly.conf: |
    {
      "rootDir": "/srv/aptly",
      "downloadConcurrency": 8,
      "downloadSpeedLimit": 0,
      "downloadRetries": 3,
      "architectures": ["amd64", "arm64"],
      "dependencyFollowSuggests": false,
      "dependencyFollowRecommends": false,
      "dependencyFollowAllVariants": false,
      "dependencyFollowSource": false,
      "dependencyVerboseResolve": true,
      "gpgDisableSign": false,
      "gpgDisableVerify": false,
      "gpgProvider": "gpg",
      "skipLegacyPool": true,
      "ppaDistributorID": "debian",
      "FileSystemPublishEndpoints": {
        "internal": {
          "rootDir": "/srv/aptly/public",
          "linkMethod": "hardlink"
        }
      }
    }
  sync.sh: |
    #!/bin/bash
    # Mirror upstream Debian, snapshot it, and publish atomically.
    # A snapshot is immutable: rolling back a bad upstream push is a
    # switch back to the previous snapshot, not a re-download.
    set -euo pipefail

    SUITE="${SUITE:-bookworm}"
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    export GNUPGHOME=/etc/aptly-gpg

    for M in "${SUITE}" "${SUITE}-security" "${SUITE}-updates"; do
      if ! aptly mirror show "${M}" >/dev/null 2>&1; then
        case "${M}" in
          *-security)
            aptly mirror create -architectures=amd64,arm64 \
              "${M}" http://security.debian.org/debian-security "${M}" main contrib ;;
          *)
            aptly mirror create -architectures=amd64,arm64 \
              "${M}" http://deb.debian.org/debian "${M}" main contrib ;;
        esac
      fi
      echo "==> updating mirror ${M}"
      aptly mirror update "${M}"
      aptly snapshot create "${M}-${STAMP}" from mirror "${M}"
    done

    aptly snapshot merge -latest "merged-${STAMP}" \
      "${SUITE}-${STAMP}" "${SUITE}-updates-${STAMP}" "${SUITE}-security-${STAMP}"

    if aptly publish list -raw | grep -q "^internal:. ${SUITE}\$"; then
      aptly publish switch -batch -passphrase-file=/etc/aptly-gpg/passphrase \
        "${SUITE}" "filesystem:internal:" "merged-${STAMP}"
    else
      aptly publish snapshot -batch -passphrase-file=/etc/aptly-gpg/passphrase \
        -distribution="${SUITE}" -component=main \
        "merged-${STAMP}" "filesystem:internal:"
    fi

    # Retain 14 snapshots for rollback; drop the rest and reclaim pool space.
    aptly snapshot list -raw | sort | head -n -14 | while read -r s; do
      aptly snapshot drop "${s}" || true
    done
    aptly db cleanup

    echo "==> published ${SUITE} from merged-${STAMP}"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: apt-mirror-sync
  namespace: apt-mirror
spec:
  schedule: "17 2 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 21600
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: aptly
              image: registry.example.internal/platform/aptly:1.5.0
              command: ["/bin/bash", "/config/sync.sh"]
              env:
                - name: SUITE
                  value: bookworm
                - name: HOME
                  value: /srv/aptly
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "1Gi"
                limits:
                  cpu: "4"
                  memory: "4Gi"
              volumeMounts:
                - name: data
                  mountPath: /srv/aptly
                - name: config
                  mountPath: /config
                  readOnly: true
                - name: aptly-conf
                  mountPath: /srv/aptly/.aptly.conf
                  subPath: aptly.conf
                  readOnly: true
                - name: gpg
                  mountPath: /etc/aptly-gpg
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: apt-mirror-data
            - name: config
              configMap:
                name: aptly-config
                defaultMode: 0555
            - name: aptly-conf
              configMap:
                name: aptly-config
            - name: gpg
              secret:
                secretName: aptly-signing-key
                defaultMode: 0400
            - name: tmp
              emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apt-mirror-web
  namespace: apt-mirror
spec:
  replicas: 2
  selector:
    matchLabels:
      app: apt-mirror-web
  template:
    metadata:
      labels:
        app: apt-mirror-web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: registry.example.internal/platform/nginx-autoindex:1.24
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /dists/bookworm/InRelease
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 15
            periodSeconds: 30
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: "100m", memory: "64Mi"}
            limits:   {cpu: "1",    memory: "256Mi"}
          volumeMounts:
            - name: data
              mountPath: /usr/share/nginx/html
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: apt-mirror-data
        - name: cache
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: apt-mirror
  namespace: apt-mirror
spec:
  selector:
    app: apt-mirror-web
  ports:
    - name: http
      port: 80
      targetPort: http
```

The readiness probe on `/dists/bookworm/InRelease` is deliberate: a replica whose PVC has not mounted, or whose publish is mid-switch, must not receive traffic. Serving a partially-written index to a fleet is exactly the `Hash Sum mismatch` storm you are trying to prevent.

### 8.4 `reprepro` — the lightweight alternative

```console
$ cat /srv/repo/conf/distributions
Origin: Example Platform
Label: example-platform
Codename: bookworm
Suite: stable
Version: 12
Architectures: amd64 arm64 source
Components: main platform
UDebComponents: main
Description: Internal package archive for platform services
SignWith: A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3
Contents: . .gz .xz
Tracking: minimal
Log: bookworm.log

Origin: Example Platform
Label: example-platform
Codename: bookworm-staging
Suite: testing
Version: 12
Architectures: amd64 arm64 source
Components: main platform
Description: Staging archive — promoted to bookworm after soak
SignWith: A1B2C3D4E5F6071829394A5B6C7D8E9FA0B1C2D3
Contents: . .gz .xz
Tracking: minimal

$ cat /srv/repo/conf/options
verbose
basedir /srv/repo
outdir /srv/repo/public
ask-passphrase
```

```console
$ reprepro -b /srv/repo includedeb bookworm-staging platform-agent_5.1.0_amd64.deb
Exporting indices...
Successfully created 'dists/bookworm-staging/Release.gpg.new'
Successfully created 'dists/bookworm-staging/InRelease.new'

$ reprepro -b /srv/repo list bookworm-staging platform-agent
bookworm-staging|platform|amd64: platform-agent 5.1.0

# Promotion from staging to stable is a metadata copy — the pool file is shared.
$ reprepro -b /srv/repo copy bookworm bookworm-staging platform-agent
Exporting indices...

$ reprepro -b /srv/repo checkpool
Checking pool...

$ reprepro -b /srv/repo remove bookworm platform-agent=5.0.9
$ reprepro -b /srv/repo deleteunreferenced
```

| Property | `reprepro` | `aptly` |
|---|---|---|
| Model | One live version per distribution | Immutable snapshots + publish points |
| Rollback | Re-add the old `.deb` | `aptly publish switch` to a prior snapshot — seconds |
| Upstream mirroring | Limited (`update` rules) | First-class (`aptly mirror`) |
| Disk footprint | Minimal; single pool | Larger; snapshots share the pool but metadata multiplies |
| API | None | REST API |
| Best for | Small internal archive of your own packages | Full mirror + staged promotion + rollback |

### 8.5 GitLab CI — build, sign, publish, and verify a `.deb`

```yaml
# .gitlab-ci.yml
stages: [build, verify, publish, smoke]

variables:
  DEBIAN_FRONTEND: noninteractive
  DEB_BUILD_OPTIONS: "nocheck parallel=4"
  APT_PROXY: "http://apt-cache.example.internal:3142"

default:
  image: debian:bookworm-slim
  before_script:
    - echo "Acquire::http::Proxy \"${APT_PROXY}\";" > /etc/apt/apt.conf.d/01proxy
    - echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/99no-recommends
    - echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/99retries
    - apt-get update

build:package:
  stage: build
  script:
    - apt-get install -y --no-install-recommends build-essential devscripts debhelper dpkg-dev lintian
    - apt-get build-dep -y .
    - dpkg-buildpackage -us -uc -b
    - mkdir -p artifacts && mv ../*.deb ../*.buildinfo ../*.changes artifacts/
    - ls -la artifacts/
  artifacts:
    paths: [artifacts/]
    expire_in: 30 days

verify:lintian:
  stage: verify
  needs: [build:package]
  script:
    - apt-get install -y --no-install-recommends lintian
    # Errors fail the pipeline; warnings are reported but tolerated.
    - lintian --fail-on error --display-info artifacts/*.changes

verify:metadata:
  stage: verify
  needs: [build:package]
  script:
    - apt-get install -y --no-install-recommends dpkg-dev
    - |
      set -euo pipefail
      DEB=$(ls artifacts/*.deb | head -1)
      echo "--- control ---"
      dpkg-deb -I "$DEB"
      echo "--- payload ---"
      dpkg-deb -c "$DEB"

      # Gate 1: a package with no md5sums can never be verified in the field.
      dpkg-deb -e "$DEB" /tmp/ctrl
      test -s /tmp/ctrl/md5sums || { echo "FATAL: package ships no md5sums"; exit 1; }

      # Gate 2: nothing may land outside the paths we own.
      if dpkg-deb -c "$DEB" | awk '{print $6}' \
           | grep -Ev '^\./(usr|etc|lib|var|opt/platform)(/|$)|^\./$'; then
        echo "FATAL: package writes outside permitted paths"; exit 1
      fi

      # Gate 3: maintainer scripts must not fetch code at install time.
      for s in preinst postinst prerm postrm; do
        [ -f "/tmp/ctrl/$s" ] || continue
        if grep -Eq '(curl|wget|nc)\s' "/tmp/ctrl/$s"; then
          echo "FATAL: $s performs network I/O"; exit 1
        fi
      done
      echo "all metadata gates passed"

publish:staging:
  stage: publish
  needs: [verify:lintian, verify:metadata]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - apt-get install -y --no-install-recommends curl ca-certificates
    - |
      set -euo pipefail
      for f in artifacts/*.deb; do
        curl -fsS --retry 5 --retry-delay 5 \
             -u "ci:${APTLY_TOKEN}" \
             -X POST -F "file=@${f}" \
             "https://apt.example.internal/api/files/${CI_PIPELINE_ID}"
      done
      curl -fsS -u "ci:${APTLY_TOKEN}" \
           -X POST "https://apt.example.internal/api/repos/bookworm-staging/file/${CI_PIPELINE_ID}"
      curl -fsS -u "ci:${APTLY_TOKEN}" \
           -X PUT -H 'Content-Type: application/json' \
           -d '{"Snapshots":[{"Component":"platform","Name":"staging-'"${CI_PIPELINE_ID}"'"}]}' \
           "https://apt.example.internal/api/publish/filesystem:internal:/bookworm-staging"

smoke:install:
  stage: smoke
  needs: [publish:staging]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - apt-get install -y --no-install-recommends ca-certificates curl gnupg
    - install -d -m 0755 /etc/apt/keyrings
    - curl -fsSL https://apt.example.internal/keys/platform.asc
        | gpg --dearmor -o /etc/apt/keyrings/platform-archive.gpg
    - |
      cat > /etc/apt/sources.list.d/platform-staging.sources <<'EOF'
      Types: deb
      URIs: https://apt.example.internal/debian
      Suites: bookworm-staging
      Components: platform
      Architectures: amd64
      Signed-By: /etc/apt/keyrings/platform-archive.gpg
      EOF
    - apt-get update
    # Prove the freshly published version is what APT actually selects.
    - apt-cache policy platform-agent
    - apt-get install -y platform-agent
    - dpkg -l platform-agent
    - dpkg -V platform-agent
    - dpkg --audit
    - test -z "$(dpkg --audit)"
```

### 8.6 Container images — deterministic apt in a `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim AS base

# Every apt setting that affects reproducibility, declared once.
RUN <<'EOF' bash
set -euxo pipefail
cat > /etc/apt/apt.conf.d/99docker <<'CONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Retries "5";
Acquire::Languages "none";
Dpkg::Use-Pty "false";
CONF
EOF

# Pin to a snapshot so a rebuild six months from now produces the same layer.
# snapshot.debian.org serves the archive as it existed at a point in time.
ARG SNAPSHOT=20260801T000000Z
RUN <<'EOF' bash
set -euxo pipefail
cat > /etc/apt/sources.list.d/debian.sources <<CONF
Types: deb
URIs: https://snapshot.debian.org/archive/debian/${SNAPSHOT}
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://snapshot.debian.org/archive/debian-security/${SNAPSHOT}
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
CONF
rm -f /etc/apt/sources.list
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
EOF

# Cache mounts keep /var/cache/apt out of the image entirely.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF' bash
set -euxo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    tini
EOF

FROM base AS runtime
COPY --chmod=0755 ./platform-agent /usr/bin/platform-agent

# Fail the build if any packaged file was modified after installation,
# and if any package is in a broken dpkg state.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF' bash
set -euxo pipefail
apt-get install -y --no-install-recommends debsums
debsums -s
test -z "$(dpkg --audit)"
apt-get purge -y debsums
apt-get autoremove -y --purge
EOF

USER 65534:65534
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/bin/platform-agent"]
```

Three points that separate this from the usual `RUN apt-get update && apt-get install`:

- **`Acquire::Check-Valid-Until "false"` is set *only* for snapshot sources.** A snapshot is by definition a frozen point in time, so its `Valid-Until` is always in the past. Disabling the check anywhere else re-opens the freeze attack.
- **Cache mounts, not `rm -rf`.** `--mount=type=cache` keeps `/var/cache/apt` out of every layer while still reusing downloads between builds.
- **`debsums -s` and `dpkg --audit` are build gates.** A build that produces a broken package state should never reach a registry.

### 8.7 `systemd` — bounded, observable automatic security updates

```ini
# /etc/systemd/system/apt-security-upgrade.service
[Unit]
Description=Apply Debian security updates only
Documentation=man:unattended-upgrade(8)
After=network-online.target apt-daily.service
Wants=network-online.target
ConditionACPower=true

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
# Never let a stuck conffile prompt hang a host indefinitely.
TimeoutStartSec=45min
Nice=19
IOSchedulingClass=idle
ExecStartPre=/usr/bin/apt-get update
ExecStart=/usr/bin/unattended-upgrade --verbose
ExecStartPost=/usr/bin/dpkg --audit
# needrestart reports services still running against deleted libraries.
ExecStartPost=/usr/sbin/needrestart -b -r l
SuccessExitStatus=0
```

```ini
# /etc/systemd/system/apt-security-upgrade.timer
[Unit]
Description=Nightly security-update window

[Timer]
OnCalendar=*-*-* 03:00:00
# Spread the fleet across a 45-minute window so the mirror is not stampeded.
RandomizedDelaySec=45min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```console
$ sudo systemctl enable --now apt-security-upgrade.timer
$ systemctl list-timers apt-security-upgrade.timer
NEXT                        LEFT     LAST                        PASSED UNIT                        ACTIVATES
Wed 2026-08-26 03:22:14 UTC 16h left Tue 2026-08-25 03:07:51 UTC 8h ago apt-security-upgrade.timer  apt-security-upgrade.service

$ sudo unattended-upgrade --dry-run --debug 2>&1 | tail -8
Checking: openssl (["<Origin component:'main' archive:'stable-security' origin:'Debian' label:'Debian-Security' site:'security.debian.org' isTrusted:True>"])
Checking: libssl3 (["<Origin component:'main' archive:'stable-security' origin:'Debian' label:'Debian-Security' site:'security.debian.org' isTrusted:True>"])
pkgs that look like they should be upgraded: libssl3 openssl
Packages blacklisted: ['^linux-image-', '^linux-headers-']
Option --dry-run given, *not* performing real actions
Packages that will be upgraded: libssl3 openssl
```

---

## 9. Multi-arch: a brief but load-bearing note

```console
$ dpkg --print-architecture
amd64
$ dpkg --print-foreign-architectures
$ sudo dpkg --add-architecture arm64
$ sudo apt-get update
$ apt-get install -s libc6:arm64
```

`Multi-Arch:` in the control file controls co-installability:

| Value | Meaning |
|---|---|
| `same` | Co-installable across architectures; all shipped paths must be arch-qualified (typical for libraries) |
| `foreign` | Satisfies dependencies from any architecture (arch-independent tools) |
| `allowed` | Dependers may request either the native or a foreign copy via `pkg:any` |
| *(absent)* | Native architecture only |

The visible consequence in every listing is the `:amd64` suffix: `libssl3:amd64` and `libssl3:arm64` are distinct entries in `dpkg -l`, and `dpkg -S`/`dpkg -L` accept the qualified name. In cross-build and emulation pipelines, forgetting `dpkg --add-architecture` before `apt-get update` is why `apt-get install libc6:arm64` reports "Unable to locate package" even though the mirror carries it.

---

## 10. Verification checklist and command reference

### 10.1 Health check — run it as a monitoring probe

```bash
#!/bin/bash
# /usr/local/sbin/apt-health-check
# Exit 0 = healthy. Non-zero = a specific, actionable condition.
set -uo pipefail
rc=0

# 1. No package in a broken dpkg state.
if [ -n "$(dpkg --audit)" ]; then
  echo "CRIT: broken dpkg state"; dpkg --audit; rc=2
fi

# 2. No package left in the 'iU/iF/iH/iR' family.
broken=$(dpkg-query -W -f='${Package} ${Status}\n' \
         | grep -Ev ' (install ok installed|deinstall ok config-files|unknown ok not-installed|install ok config-files)$' || true)
if [ -n "$broken" ]; then
  echo "WARN: unexpected package states:"; echo "$broken"; rc=$(( rc > 1 ? rc : 1 ))
fi

# 3. Indices refreshed within the last 48 h.
if [ -e /var/lib/apt/periodic/update-success-stamp ]; then
  age=$(( ($(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp)) / 3600 ))
  [ "$age" -gt 48 ] && { echo "WARN: apt indices ${age}h old"; rc=$(( rc > 1 ? rc : 1 )); }
fi

# 4. No pending security upgrades.
sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null \
      | grep -c '^Inst.*Debian-Security' || true)
[ "$sec" -gt 0 ] && { echo "WARN: ${sec} pending security upgrades"; rc=$(( rc > 1 ? rc : 1 )); }

# 5. No unexpected holds (a hold silently defeats security automation).
holds=$(apt-mark showhold)
[ -n "$holds" ] && echo "INFO: held packages: $(echo "$holds" | tr '\n' ' ')"

# 6. Integrity: modified non-conffile files.
if command -v debsums >/dev/null; then
  mods=$(debsums -c 2>/dev/null | grep -v '^/etc/' || true)
  [ -n "$mods" ] && { echo "CRIT: modified packaged files:"; echo "$mods"; rc=2; }
fi

# 7. Every configured source is signed and reachable.
if ! apt-get update -o Debug::NoLocking=1 2>&1 | grep -qE '^(W|E):'; then
  :
else
  echo "WARN: apt-get update emitted warnings/errors"; rc=$(( rc > 1 ? rc : 1 ))
fi

# 8. Every executable in /usr/local/bin is untracked by design — enumerate it.
for f in /usr/local/bin/*; do
  [ -f "$f" ] || continue
  dpkg -S "$f" >/dev/null 2>&1 || echo "INFO: untracked binary $f"
done

exit "$rc"
```

```console
$ sudo /usr/local/sbin/apt-health-check; echo "exit=$?"
INFO: held packages: openssh-server
INFO: untracked binary /usr/local/bin/kubectl
exit=0
```

### 10.2 Command reference

| Task | Command |
|---|---|
| Install a local `.deb` | `dpkg -i pkg.deb` then `apt-get -f install` |
| Install from the archive | `apt-get install pkg` |
| Install a specific version | `apt-get install pkg=1.22.1-9` |
| Install from a specific suite | `apt-get install -t bookworm-backports pkg` |
| Simulate any change | `apt-get -s <action>` |
| Remove, keep config | `apt-get remove pkg` / `dpkg -r pkg` |
| Remove including config | `apt-get purge pkg` / `dpkg -P pkg` |
| Drop orphaned deps | `apt-get autoremove --purge` |
| Refresh indices | `apt-get update` |
| Conservative upgrade | `apt-get upgrade` |
| Full upgrade (may remove) | `apt-get dist-upgrade` |
| List installed | `dpkg -l` / `dpkg-query -W -f=…` / `apt list --installed` |
| List pending upgrades | `apt list --upgradable` |
| Package status stanza | `dpkg -s pkg` |
| Files owned by a package | `dpkg -L pkg` |
| Owner of an installed file | `dpkg -S /path` |
| Owner of any file in the archive | `apt-file search /path` |
| Metadata of an available package | `apt-cache show pkg` |
| Metadata of a `.deb` file | `dpkg-deb -I pkg.deb` |
| Contents of a `.deb` file | `dpkg-deb -c pkg.deb` |
| Extract a `.deb` without installing | `dpkg-deb -x pkg.deb dir/` |
| Extract control files | `dpkg-deb -e pkg.deb dir/` |
| Forward / reverse dependencies | `apt-cache depends pkg` / `apt-cache rdepends pkg` |
| Why is this installed? | `aptitude why pkg` |
| Candidate version and its source | `apt-cache policy pkg` |
| Version/suite matrix | `apt-cache madison pkg` |
| Search by name/description | `apt-cache search regex` |
| Freeze / unfreeze a package | `apt-mark hold pkg` / `apt-mark unhold pkg` |
| List held | `apt-mark showhold` / `dpkg --get-selections \| grep hold` |
| Mark manual / auto | `apt-mark manual pkg` / `apt-mark auto pkg` |
| Dump / restore selections | `dpkg --get-selections` / `dpkg --set-selections` |
| Reconfigure a package | `dpkg-reconfigure -plow pkg` |
| Pre-seed answers | `debconf-set-selections < file` |
| Audit broken states | `dpkg -C` / `dpkg --audit` |
| Finish an interrupted install | `dpkg --configure -a` |
| Repair unmet dependencies | `apt-get -f install` |
| Verify dependency consistency | `apt-get check` |
| Verify file integrity | `dpkg -V pkg` / `debsums -c` |
| Restore packaged files | `apt-get install --reinstall pkg` |
| Compare versions | `dpkg --compare-versions A op B` |
| Clean the download cache | `apt-get clean` / `apt-get autoclean` |
| Effective APT configuration | `apt-config dump` |
| Fetch a `.deb` without installing | `apt-get download pkg` |
| Fetch build dependencies | `apt-get build-dep pkg` |
| Fetch upstream source | `apt-get source pkg` |
| Enable a foreign architecture | `dpkg --add-architecture arm64` |
| Relocate a file owned by a package | `dpkg-divert --add --rename --divert /new /old` |

### 10.3 File reference

| Path | Role |
|---|---|
| `/etc/apt/sources.list` | Primary repository list, one-line format |
| `/etc/apt/sources.list.d/*.list` | Additional one-line sources |
| `/etc/apt/sources.list.d/*.sources` | Additional deb822 sources |
| `/etc/apt/preferences`, `/etc/apt/preferences.d/*` | Pinning policy |
| `/etc/apt/apt.conf`, `/etc/apt/apt.conf.d/*` | APT and dpkg runtime options |
| `/etc/apt/auth.conf.d/*` | Per-repository credentials (mode `0600`) |
| `/etc/apt/trusted.gpg.d/*.{gpg,asc}` | Globally trusted archive keys (legacy pattern) |
| `/usr/share/keyrings/*.gpg`, `/etc/apt/keyrings/*` | Per-repository keys referenced by `Signed-By` |
| `/var/lib/apt/lists/` | Downloaded `InRelease` / `Packages` indices |
| `/var/cache/apt/archives/` | Downloaded `.deb` files |
| `/var/cache/apt/{pkgcache,srcpkgcache}.bin` | Binary caches built by `apt-get update` |
| `/var/lib/dpkg/status` | **The** installed-package database |
| `/var/lib/dpkg/info/<pkg>.*` | Per-package file lists, checksums, maintainer scripts |
| `/var/lib/dpkg/available` | `dselect` availability index |
| `/var/cache/debconf/config.dat` | debconf answer database |
| `/var/log/apt/history.log`, `term.log` | APT transaction history and full terminal output |
| `/var/log/dpkg.log` | Per-package state transitions |
| `/var/backups/dpkg.status.*` | Rotated backups of the dpkg database |

### 10.4 Practice drills

Each drill has a single verifiable answer produced by the tools above. Do them on a disposable VM or container.

1. Download `nginx-light` without installing it, list its payload, extract its `postinst`, and confirm from the control fields whether it would pull `nginx-doc` under default APT settings.
2. Install a package with `dpkg -i` whose dependencies are absent. Record the exact `dpkg -l` status flags. Repair it with a single command and confirm the flags return to `ii`.
3. Modify `/etc/ssh/sshd_config` and then a file under `/usr/sbin/`. Run `dpkg -V openssh-server` and explain why only one of the two produces a line you should escalate.
4. Configure a pin that makes a locally-added repository able to supply exactly one package and nothing else. Prove it with `apt-cache policy` on both that package and `libc6`.
5. Determine which package would provide `/usr/bin/tcpdump` on a host where it is not installed — without installing anything but `apt-file`.
6. Put a package on hold, then attempt `apt-get dist-upgrade` and `dpkg -i` of a newer version. Record both refusal messages.
7. Given `1:2.0~rc1-1` and `2.0-1`, predict which is newer, then verify with `dpkg --compare-versions`.
8. Reproduce a conffile prompt during an upgrade, then re-run the same upgrade non-interactively with a declared policy so it completes without input.

---

## 11. References

**Exam objectives**
- LPI — Exam 101-500 Objectives (v5.0), Topic 102.4: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification Overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Debian official documentation**
- Debian Policy Manual — Control files and their fields (Ch. 5): https://www.debian.org/doc/debian-policy/ch-controlfields.html
- Debian Policy Manual — Declaring relationships between packages (Ch. 7): https://www.debian.org/doc/debian-policy/ch-relationships.html
- Debian Policy Manual — Configuration files / conffiles (§10.7): https://www.debian.org/doc/debian-policy/ch-files.html#configuration-files
- Debian Policy Manual — Version numbers and comparison (§5.6.12): https://www.debian.org/doc/debian-policy/ch-controlfields.html#version
- Debian Administrator's Handbook — Ch. 5, Packaging System: dpkg: https://debian-handbook.info/browse/stable/packaging-system.html
- Debian Administrator's Handbook — Ch. 6, Maintenance and Updates: The APT Tools: https://debian-handbook.info/browse/stable/sect.apt-get.html
- Debian Wiki — DebianRepository/Format: https://wiki.debian.org/DebianRepository/Format
- Debian Wiki — DebianRepository/UseThirdParty (keyring best practice): https://wiki.debian.org/DebianRepository/UseThirdParty
- Debian Wiki — SecureApt: https://wiki.debian.org/SecureApt
- Debian Wiki — Multiarch/HOWTO: https://wiki.debian.org/Multiarch/HOWTO
- Debian Wiki — AptConfiguration: https://wiki.debian.org/AptConfiguration
- Debian Wiki — UnattendedUpgrades: https://wiki.debian.org/UnattendedUpgrades
- Debian snapshot archive: https://snapshot.debian.org/
- Debian security information and advisories: https://www.debian.org/security/

**Manual pages (upstream, authoritative)**
- `dpkg(1)`: https://manpages.debian.org/stable/dpkg/dpkg.1.en.html
- `dpkg-query(1)`: https://manpages.debian.org/stable/dpkg/dpkg-query.1.en.html
- `dpkg-deb(1)`: https://manpages.debian.org/stable/dpkg/dpkg-deb.1.en.html
- `deb(5)` — the binary package format: https://manpages.debian.org/stable/dpkg-dev/deb.5.en.html
- `deb-control(5)`: https://manpages.debian.org/stable/dpkg-dev/deb-control.5.en.html
- `dpkg-divert(1)`: https://manpages.debian.org/stable/dpkg/dpkg-divert.1.en.html
- `dpkg-reconfigure(8)`: https://manpages.debian.org/stable/debconf/dpkg-reconfigure.8.en.html
- `debconf-set-selections(1)`: https://manpages.debian.org/stable/debconf-utils/debconf-set-selections.1.en.html
- `apt(8)`: https://manpages.debian.org/stable/apt/apt.8.en.html
- `apt-get(8)`: https://manpages.debian.org/stable/apt/apt-get.8.en.html
- `apt-cache(8)`: https://manpages.debian.org/stable/apt/apt-cache.8.en.html
- `apt-mark(8)`: https://manpages.debian.org/stable/apt/apt-mark.8.en.html
- `sources.list(5)`: https://manpages.debian.org/stable/apt/sources.list.5.en.html
- `apt_preferences(5)` — pinning: https://manpages.debian.org/stable/apt/apt_preferences.5.en.html
- `apt.conf(5)`: https://manpages.debian.org/stable/apt/apt.conf.5.en.html
- `apt-secure(8)`: https://manpages.debian.org/stable/apt/apt-secure.8.en.html
- `apt-file(1)`: https://manpages.debian.org/stable/apt-file/apt-file.1.en.html
- `aptitude(8)`: https://manpages.debian.org/stable/aptitude/aptitude.8.en.html
- `debsums(1)`: https://manpages.debian.org/stable/debsums/debsums.1.en.html

**Related tooling**
- APT source repository and release notes: https://salsa.debian.org/apt-team/apt
- aptly — repository management: https://www.aptly.info/doc/overview/
- reprepro documentation: https://salsa.debian.org/brlink/reprepro
- cloud-init — `apt` configuration module: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#apt-configure
- Ansible — `ansible.builtin.apt` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html
- Ansible — `ansible.builtin.deb822_repository` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/deb822_repository_module.html
- Ubuntu Server documentation — Package management: https://documentation.ubuntu.com/server/howto/software/package-management/