# LPIC-1 · Topic 104.7 — Find System Files and Place Files in the Correct Location

**Exam:** 101-500 · **Weight:** 3.12 · **Version:** 5.0
**Key files, terms and utilities:** `find`, `locate`, `updatedb`, `whereis`, `which`, `type`, `/etc/updatedb.conf`
**Depth profile:** Principal Platform Architect / SRE — filesystem contract design, search-plane performance, fleet-wide forensics.

---

## 1. The production problem: a filesystem is an API, not a folder tree

Every automation you own — package managers, configuration management, container image builds, backup selectors, SELinux policy, systemd sandboxing, log shippers, compliance scanners — encodes assumptions about *where things live*. When those assumptions diverge from reality, the failure is never a clean crash. It is a slow, silent class of incidents:

| Failure mode | Real-world trigger | Blast radius |
|---|---|---|
| Backup restores an empty application | Vendor installed state under `/opt/app/data`; backup policy selects `/var` and `/home` | Total data loss discovered at restore time |
| `/` fills at 03:00 | Application writes logs to `/var/lib/app/` instead of `/var/log/app/`; logrotate never matches it | Node `NotReady`, kubelet eviction storm |
| Config wiped by an upgrade | Package ships defaults in `/usr/share/app/config.yaml` and the operator edited *that* file instead of `/etc/app/config.yaml` | Silent regression to defaults across the fleet |
| Read-only `/usr` rollout breaks a daemon | Daemon writes a runtime socket into `/usr/lib/app/run.sock` | Immutable/OSTree hosts refuse the workload |
| Privilege escalation | A SUID binary dropped into `/usr/local/bin` by an ad-hoc install; nobody knows it exists | CVE-grade finding at audit |
| `which` says the binary is fine, the shell runs a different one | Bash command hash cache holds the pre-upgrade path | "It works in my terminal, fails in the unit file" |
| `locate` returns paths that no longer exist | `updatedb` timer disabled on hardened images | On-call chases ghosts during triage |

The **Filesystem Hierarchy Standard (FHS)** is the contract that makes those assumptions safe to hold. `find`, `locate`, `whereis`, `which` and `type` are the query plane over that contract — and each of them queries a *different data source* with a different freshness, cost and trust model. Confusing the data sources is where engineers lose hours.

The single most important mental model in this topic:

```
type / command -v  →  asks the *shell's own* execution logic       (authoritative for "what will run")
which              →  asks $PATH via an *external program*         (blind to aliases, functions, builtins)
whereis            →  asks compiled-in path lists + $PATH/$MANPATH (binaries, sources, man pages)
locate             →  asks a *precomputed database* on disk        (fast, stale, whole-filesystem)
find               →  asks the *live filesystem*                   (slow, exact, arbitrarily expressive)
```

Answer the question with the cheapest tool that is still *correct for the question asked*. That sentence is the whole topic.

---

## 2. FHS 3.0 — the contract

FHS 3.0 was published on 2015-06-03 and is maintained by the Linux Foundation. It is normative for distributions (Debian Policy and the Fedora Packaging Guidelines both bind to it), which is exactly why it is worth memorising: it is the reason your tooling can hardcode paths at all.

### 2.1 The two orthogonal axes

FHS classifies every directory along two axes. This is the part exams ask about and the part architects actually use when designing mount layouts.

* **Shareable vs unshareable** — can this data be mounted read-only from a central server and consumed by several hosts, or is it bound to one specific machine?
* **Static vs variable** — does it change only when an administrator installs or upgrades software, or does it change during normal operation?

| | **Shareable** | **Unshareable** |
|---|---|---|
| **Static** | `/usr`, `/opt` | `/etc`, `/boot` |
| **Variable** | `/var/mail`, `/var/spool/news` | `/var/log`, `/var/lock`, `/var/run` (today `/run`) |

Design consequences you should be able to state under interrogation:

* `/usr` static + shareable ⇒ it can be mounted **read-only**, snapshotted with the OS image, and shipped as an OSTree/`composefs` commit. Anything that writes to `/usr` at runtime is a bug.
* `/etc` static + unshareable ⇒ it is the host's identity. It is what configuration management owns, what `rpm -Va` / `debsums` audits, and what must **never** contain binaries (FHS is explicit: *"No binaries may be located under /etc"*).
* `/var` variable ⇒ it is the only place a well-behaved daemon persists mutable state, which is why it gets its own filesystem on every serious node build.

### 2.2 Root hierarchy reference

| Path | FHS status | Contents | Must be on `/` at boot? | Notes for production |
|---|---|---|---|---|
| `/bin` | required | Essential user command binaries | Yes | Merged into `/usr/bin` on modern distros |
| `/boot` | required | Kernel, initramfs, bootloader | Own partition, mounted early | Often small; kernel churn fills it |
| `/dev` | required | Device nodes | Yes (`devtmpfs`) | Populated by the kernel + udev |
| `/etc` | required | Host-specific static config | Yes | **No binaries.** No subdir enforced except `/etc/opt`, `/etc/X11`, `/etc/sgml`, `/etc/xml` |
| `/home` | optional | User home directories | No | Frequently NFS/autofs; prune from `updatedb` |
| `/lib`, `/lib64` | required | Essential shared libraries + kernel modules | Yes | `/lib/modules/$(uname -r)` |
| `/media` | required | Mount points for **removable** media | No | udisks/GNOME create per-device dirs here |
| `/mnt` | required | Temporary mount point for the **admin** | No | Never used by packages |
| `/opt` | required | Add-on **third-party** software packages | No | One subtree per vendor/package |
| `/root` | optional | Home of `root` | Yes (recommended) | Must be on `/` so single-user mode works |
| `/run` | required (FHS 3.0) | Run-time variable data, cleared at boot | `tmpfs`, mounted early | Replaces `/var/run` and `/var/lock` |
| `/sbin` | required | Essential **system** binaries | Yes | Merged into `/usr/sbin` on modern distros |
| `/srv` | required | Data **served by this system** | No | e.g. `/srv/www`, `/srv/ftp`, `/srv/git` |
| `/tmp` | required | Temporary files | Yes | **May be cleared on reboot** — usually `tmpfs` |
| `/usr` | required | Second hierarchy — shareable, read-only | Mountable later | See §2.3 |
| `/var` | required | Variable data | Yes (or early) | Own filesystem on production nodes |
| `/proc` | Linux annex | Process/kernel virtual FS | Yes | `procfs` |
| `/sys` | Linux annex | Kernel object virtual FS | Yes | `sysfs` |

**Inside `/usr`:**

| Path | Contents |
|---|---|
| `/usr/bin` | The primary location for user commands |
| `/usr/sbin` | Non-essential system administration binaries |
| `/usr/lib`, `/usr/lib64`, `/usr/lib/<arch-triplet>` | Libraries and internal binaries not meant for direct invocation |
| `/usr/libexec` | Internal helper binaries (FHS 3.0 formally allows this) |
| `/usr/share` | **Architecture-independent** data: man pages, docs, icons, locale, `zoneinfo` |
| `/usr/include` | C header files |
| `/usr/src` | Source code (e.g. kernel headers) |
| `/usr/local` | Tertiary hierarchy for **locally built/installed** software |

**Inside `/var`:**

| Path | Semantics | Survives reboot? | Safe to delete? |
|---|---|---|---|
| `/var/log` | Log files | Yes | Only via rotation |
| `/var/lib` | **Persistent application state** (databases, dpkg/rpm DBs) | Yes | **No — this is your data** |
| `/var/cache` | Regenerable cached data | Yes | **Yes** — must be reconstructible |
| `/var/spool` | Queued work awaiting processing (`cron`, `cups`, `mail`) | Yes | No — pending work is lost |
| `/var/tmp` | Temporary files **preserved between reboots** | Yes | With age policy |
| `/var/opt` | Variable data for `/opt` packages | Yes | No |
| `/var/local` | Variable data for `/usr/local` programs | Yes | No |
| `/var/lock` | Lock files (now a symlink to `/run/lock`) | No | N/A |
| `/var/run` | Runtime data (now a symlink to `/run`) | No | N/A |

The `/var/cache` vs `/var/lib` distinction is a real production decision: everything under `/var/cache` should be safe to `rm -rf` during a disk-full incident. If your application cannot survive that, it does not belong there.

### 2.3 The `/usr` merge — why `/bin` is a symlink now

Fedora executed `UsrMove` in Fedora 17 (2012); Debian completed the transition in Debian 12 "bookworm" (merged-`/usr` only). On a merged system:

```
$ ls -ld /bin /sbin /lib /lib64 /usr/bin
lrwxrwxrwx.  1 root root    7 Jan 15  2026 /bin -> usr/bin
lrwxrwxrwx.  1 root root    9 Jan 15  2026 /lib -> usr/lib
lrwxrwxrwx.  1 root root   11 Jan 15  2026 /lib64 -> usr/lib64
lrwxrwxrwx.  1 root root    8 Jan 15  2026 /sbin -> usr/sbin
dr-xr-xr-x. 2 root root 61440 Aug 21 09:12 /usr/bin
```

Architectural payoff: the *entire* OS becomes one subtree (`/usr`) that is static, shareable, and therefore atomically swappable, verifiable by hash, and mountable read-only. That is the substrate for `rpm-ostree`, Flatcar, Bottlerocket and every immutable node OS in the CNCF ecosystem.

Operational consequences you must handle:

* `find / -name foo` will report **both** `/bin/foo` and `/usr/bin/foo` unless you handle the symlink — actually it will report only `/usr/bin/foo`, because `find` does **not** follow symlinks by default and `/bin` is a symlink, not a directory. `find /bin -name foo` returns nothing without `-H` or `-L`. This trips people constantly.
* Distinguishing `/bin` from `/usr/bin` in packaging is now meaningless; distinguishing `/usr` from `/usr/local` and `/opt` is more important than ever.

```
$ find /bin -maxdepth 1 -name 'ls'
$ find -H /bin -maxdepth 1 -name 'ls'
/bin/ls
$ find -L /bin -maxdepth 1 -name 'ls'
/bin/ls
```

`-H` follows symlinks **only for the command-line arguments**; `-L` follows them everywhere; `-P` (the default) never follows.

### 2.4 Where do *I* put software? `/usr` vs `/usr/local` vs `/opt` vs `/srv`

This is the decision an architect makes once per platform and then enforces in CI. Getting it wrong means package upgrades stomp your files or your config management fights the package manager forever.

| Target | Owner | Config location | Variable data | Upgrade behaviour | Use when |
|---|---|---|---|---|---|
| `/usr/bin`, `/usr/lib` | **Distribution package manager only** | `/etc/<pkg>` | `/var/lib/<pkg>` | Overwritten by `dnf`/`apt` | You are building a distro package |
| `/usr/local/{bin,lib,share,etc}` | **Local administrator**, `make install` default | `/usr/local/etc` (FHS) or `/etc` by convention | `/var/local` | Never touched by the distro | Software compiled from source on this host |
| `/opt/<vendor-or-package>` | **Third-party vendor**, self-contained | `/etc/opt/<pkg>` | `/var/opt/<pkg>` | Vendor's own installer | Shipped binary bundles, commercial agents |
| `/srv/<service>` | **Site data served outward** | n/a | n/a | n/a | Web roots, git repos, FTP trees |

Precedence in `$PATH` is what makes `/usr/local` work: on virtually every distro `/usr/local/bin` precedes `/usr/bin`, so a locally installed binary shadows the packaged one **without** touching it. That is a feature and a hazard — see §3.4.

FHS is explicit about `/opt`: a package `foo` uses `/opt/foo` for static files, `/etc/opt/foo` for configuration, and `/var/opt/foo` for variable data. Vendors that scatter into `/opt/foo/etc` and `/opt/foo/logs` are non-compliant, and you will pay for it the first time you mount `/opt` read-only.

### 2.5 `/tmp`, `/var/tmp`, and why neither is your scratch space

| | `/tmp` | `/var/tmp` | `/run` | `$XDG_RUNTIME_DIR` |
|---|---|---|---|---|
| Backing store | usually `tmpfs` (RAM) | disk | `tmpfs` | `tmpfs` (`/run/user/<uid>`) |
| Survives reboot | **No** | **Yes** | No | No |
| Cleaned by | `systemd-tmpfiles`, boot | age-based `tmpfiles` policy | boot | logout |
| Size limit | often 50% of RAM | filesystem size | 10% of RAM | 10% of RAM |
| Correct use | short-lived, small | large intermediates, resumable work | sockets, PID files | per-user sockets |

Writing a 40 GiB intermediate to a `tmpfs`-backed `/tmp` is an out-of-memory incident, not a disk-space incident. Check before you assume:

```
$ findmnt -no FSTYPE,SIZE,USE% /tmp /var/tmp
tmpfs  7.8G  3%
ext4   196G 41%
```

The **XDG Base Directory Specification** is the user-space complement to FHS; modern applications should honour it rather than dumping dotfiles into `$HOME`:

| Variable | Default | FHS analogue |
|---|---|---|
| `XDG_CONFIG_HOME` | `~/.config` | `/etc` |
| `XDG_DATA_HOME` | `~/.local/share` | `/var/lib` + `/usr/share` |
| `XDG_STATE_HOME` | `~/.local/state` | `/var/lib` |
| `XDG_CACHE_HOME` | `~/.cache` | `/var/cache` |
| `XDG_RUNTIME_DIR` | `/run/user/$UID` | `/run` |

### 2.6 Enforcing FHS mechanically with systemd

Do not rely on a daemon behaving. Declare the directories in the unit and let systemd create them with the right owner, mode and SELinux label — and, critically, let `ProtectSystem=strict` make every *other* path read-only so a misbehaving process fails loudly instead of silently writing to `/usr`.

**`/etc/systemd/system/telemetry-agent.service`**

```ini
[Unit]
Description=Telemetry Agent (FHS-compliant layout)
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=telemetry
Group=telemetry
ExecStart=/opt/telemetry-agent/bin/agent --config /etc/opt/telemetry-agent/agent.yaml

# --- FHS-mapped directories, created and labelled by systemd ---
# /etc/telemetry-agent          0750 telemetry:telemetry
ConfigurationDirectory=telemetry-agent
ConfigurationDirectoryMode=0750
# /var/lib/telemetry-agent      persistent state, survives restarts and reboots
StateDirectory=telemetry-agent
StateDirectoryMode=0700
# /var/cache/telemetry-agent    regenerable; safe to purge under disk pressure
CacheDirectory=telemetry-agent
CacheDirectoryMode=0750
# /var/log/telemetry-agent      only if the daemon insists on its own files
LogsDirectory=telemetry-agent
LogsDirectoryMode=0750
# /run/telemetry-agent          sockets and PID file; cleared at boot
RuntimeDirectory=telemetry-agent
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=no

# --- Everything else becomes read-only or invisible ---
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=yes
NoNewPrivileges=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
AmbientCapabilities=

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Verify the sandbox actually holds — this is the check that turns a claim into a fact:

```
$ sudo systemd-analyze security telemetry-agent.service | tail -5
  ✓ RestrictNamespaces=~CLONE_NEWNET                                          0.1
  ✓ RestrictSUIDSGID=                                                         0.2
  ✓ SystemCallFilter=~@privileged                                             0.2

→ Overall exposure level for telemetry-agent.service: 1.4 SAFE 😀
```

```
$ sudo -u telemetry touch /usr/lib/telemetry-agent/probe
touch: cannot touch '/usr/lib/telemetry-agent/probe': Read-only file system
```

**`/usr/lib/tmpfiles.d/telemetry-agent.conf`** — for paths systemd's per-unit directives cannot express (shared spools, age-based cleanup):

```
#Type Path                              Mode UID        GID        Age  Argument
d     /var/spool/telemetry-agent        0770 telemetry  telemetry  -    -
d     /var/spool/telemetry-agent/inbox  0770 telemetry  telemetry  30d  -
d     /var/tmp/telemetry-agent          0700 telemetry  telemetry  7d   -
L     /var/opt/telemetry-agent/state    -    -          -          -    /var/lib/telemetry-agent
z     /etc/opt/telemetry-agent/agent.yaml 0640 root     telemetry  -    -
```

```
$ sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/telemetry-agent.conf
$ ls -ld /var/spool/telemetry-agent /var/spool/telemetry-agent/inbox
drwxrws---. 2 telemetry telemetry 4096 Aug 26 11:02 /var/spool/telemetry-agent
drwxrws---. 2 telemetry telemetry 4096 Aug 26 11:02 /var/spool/telemetry-agent/inbox
```

`systemd-path` lets you query the resolved hierarchy programmatically instead of hardcoding:

```
$ systemd-path | head -12
temporary: /tmp
temporary-large: /var/tmp
system-binaries: /usr/bin
system-configuration: /etc
system-runtime: /run
system-state-cache: /var/cache
system-state-logs: /var/log
system-state-private: /var/lib
system-state-spool: /var/spool
system-shared: /usr/share
user-runtime: /run/user/1000
user-configuration: /home/sre/.config
```

### 2.7 Ansible: deploying a vendor bundle FHS-correctly

**`roles/telemetry_agent/tasks/main.yml`**

```yaml
---
- name: Ensure the service account exists
  ansible.builtin.user:
    name: telemetry
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/telemetry-agent
    create_home: false
    comment: "Telemetry agent service account"

- name: Create the FHS-compliant directory layout
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner | default('root') }}"
    group: "{{ item.group | default('root') }}"
    mode: "{{ item.mode }}"
    setype: "{{ item.setype | default(omit) }}"
  loop:
    # Static, shareable, read-only at runtime: the program itself.
    - { path: /opt/telemetry-agent,         mode: "0755" }
    - { path: /opt/telemetry-agent/bin,     mode: "0755" }
    - { path: /opt/telemetry-agent/lib,     mode: "0755" }
    # Static, unshareable: host-specific configuration.
    - { path: /etc/opt/telemetry-agent,     mode: "0750", group: telemetry, setype: etc_t }
    # Variable, unshareable: state that must survive an upgrade.
    - { path: /var/opt/telemetry-agent,     mode: "0700", owner: telemetry, group: telemetry, setype: var_lib_t }
    # Variable, regenerable: safe to purge under disk pressure.
    - { path: /var/cache/telemetry-agent,   mode: "0750", owner: telemetry, group: telemetry, setype: var_t }
    # Variable: logs, rotated externally.
    - { path: /var/log/telemetry-agent,     mode: "0750", owner: telemetry, group: telemetry, setype: var_log_t }

- name: Unpack the vendor bundle into /opt
  ansible.builtin.unarchive:
    src: "telemetry-agent-{{ agent_version }}.tar.gz"
    dest: /opt/telemetry-agent
    owner: root
    group: root
    extra_opts: ["--strip-components=1", "--no-same-owner"]
    creates: "/opt/telemetry-agent/bin/agent"
  notify: restart telemetry-agent

- name: Expose the entry point on $PATH without polluting /usr/bin
  ansible.builtin.file:
    src: /opt/telemetry-agent/bin/agent
    dest: /usr/local/bin/telemetry-agent
    state: link
    force: true

- name: Render host-specific configuration under /etc/opt
  ansible.builtin.template:
    src: agent.yaml.j2
    dest: /etc/opt/telemetry-agent/agent.yaml
    owner: root
    group: telemetry
    mode: "0640"
    validate: "/opt/telemetry-agent/bin/agent --config %s --check-config"
  notify: restart telemetry-agent

- name: Install the hardened unit file
  ansible.builtin.copy:
    src: telemetry-agent.service
    dest: /etc/systemd/system/telemetry-agent.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - reload systemd
    - restart telemetry-agent

- name: Install log rotation policy
  ansible.builtin.copy:
    dest: /etc/logrotate.d/telemetry-agent
    owner: root
    group: root
    mode: "0644"
    content: |
      /var/log/telemetry-agent/*.log {
          daily
          rotate 14
          compress
          delaycompress
          missingok
          notifempty
          create 0640 telemetry telemetry
          sharedscripts
          postrotate
              /usr/bin/systemctl kill -s HUP telemetry-agent.service 2>/dev/null || true
          endscript
      }

- name: Exclude the agent cache from the locate database
  ansible.builtin.lineinfile:
    path: /etc/updatedb.conf
    regexp: '^PRUNEPATHS\s*='
    line: 'PRUNEPATHS = "/afs /media /mnt /net /sfs /tmp /udev /var/cache/telemetry-agent /var/spool/cups /var/spool/squid /var/tmp"'
    backup: true

- name: Assert nothing was written outside the declared layout
  ansible.builtin.command:
    argv:
      - find
      - /opt/telemetry-agent
      - -xdev
      - -newer
      - /etc/opt/telemetry-agent/agent.yaml
      - -type
      - f
      - -print
  register: fhs_drift
  changed_when: false
  failed_when: fhs_drift.stdout | length > 0
```

**`roles/telemetry_agent/handlers/main.yml`**

```yaml
---
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: restart telemetry-agent
  ansible.builtin.systemd_service:
    name: telemetry-agent.service
    state: restarted
    enabled: true
```

---

## 3. Locating executables: `type`, `command -v`, `which`, `whereis`, `hash`

### 3.1 How bash actually resolves a command name

Order of resolution (this is the ordering `type -a` reports, and the reason `which` can lie):

1. **Aliases** — expanded before parsing, interactive shells only unless `shopt -s expand_aliases`
2. **Shell reserved words** — `if`, `for`, `while`, `function`, `[[`, `time`, `!`
3. **Shell functions**
4. **Shell builtins** — `cd`, `echo`, `test`, `kill`, `pwd`, `type`, `hash`
5. **`$PATH` search**, memoised in the shell's **hash table**

```
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo

$ type -a ls
ls is aliased to `ls --color=auto'
ls is /usr/bin/ls

$ type -a [
[ is a shell builtin
[ is /usr/bin/[

$ type -a if
if is a shell keyword

$ type -t if
keyword
$ type -t ls
alias
$ type -t cd
builtin
$ type -t find
file

$ type -P ls        # force the PATH lookup, ignore alias/builtin/function
/usr/bin/ls
```

`-t` prints a single machine-parsable word (`alias`, `keyword`, `function`, `builtin`, `file`) and is the correct thing to branch on in a script.

### 3.2 The comparison table you must be able to reproduce

| Tool | Kind | Sees aliases | Sees functions | Sees builtins | Sees keywords | Searches | POSIX | Exit code reliable |
|---|---|---|---|---|---|---|---|---|
| `type` | bash builtin | ✅ | ✅ | ✅ | ✅ | `$PATH` + hash | `type` yes, `-a/-t/-P` are bash | ✅ |
| `command -v` | POSIX builtin | ✅ | ✅ | ✅ | ✅ | `$PATH` | ✅ | ✅ |
| `which` | **external binary** | ❌ (unless wrapped) | ❌ | ❌ | ❌ | `$PATH` only | ❌ (not in POSIX) | distro-dependent |
| `whereis` | external binary | ❌ | ❌ | ❌ | ❌ | compiled-in dirs + `$PATH`/`$MANPATH` | ❌ | ✅ |
| `hash` | bash builtin | ❌ | ❌ | ❌ | ❌ | shows the cache | `hash` yes | ✅ |

**Rule for scripts: use `command -v`.** It is POSIX, it is a builtin (no `fork`), it respects the shell's own resolution order, and its exit status is defined.

```sh
#!/bin/sh
# Correct portable dependency check.
for dep in jq curl find; do
    command -v "$dep" >/dev/null 2>&1 || {
        printf 'fatal: required command not found: %s\n' "$dep" >&2
        exit 127
    }
done
```

The `which` version of that check is broken in three ways: it forks a process per dependency, its exit status is not portable (some implementations return 0 even on failure), and it cannot see a shell function that legitimately provides the command.

### 3.3 `which` — what it is on your distro matters

`which` is not one program. Know which one you have:

```
$ ls -l /usr/bin/which
-rwxr-xr-x. 1 root root 30536 Jul  9 14:31 /usr/bin/which

$ which --version | head -1
GNU which v2.21, Copyright (C) 1999 - 2008 Carlo Wood.
```

* **GNU which** (RHEL/Fedora historically): supports `-a` (all matches), `--read-alias`, `--read-functions`, `--skip-dot`, `--skip-tilde`. Fedora used to ship `/etc/profile.d/which2.sh` defining an alias that piped `alias; declare -f` into it so it *appeared* to know aliases; that wrapper has been dropped in recent releases.
* **debianutils `which`** (Debian/Ubuntu): a POSIX shell script. Since debianutils 5.x it emits a deprecation notice, and Debian has moved it aside as `which.debianutils`:

```
$ which python3
which: this version of `which' is deprecated; use `command -v' in scripts instead.
/usr/bin/python3
```

* **busybox `which`** (Alpine, minimal containers): no `-a`, no alias support.

`-a` is the option that matters operationally, because it exposes shadowing:

```
$ which -a python3
/usr/local/bin/python3
/usr/bin/python3
```

### 3.4 The incident: `which` and the shell disagree

Bash caches full paths of executed commands in a hash table. After an in-place upgrade that moves a binary, the cache is stale and the shell keeps invoking the old path — which may no longer exist.

```
$ hash
hits	command
   3	/usr/bin/find
  14	/usr/local/bin/kubectl
   2	/usr/bin/systemctl

$ sudo dnf -y remove kubectl-local && sudo dnf -y install kubernetes-client
...
Complete!

$ which kubectl
/usr/bin/kubectl

$ kubectl version --client
bash: /usr/local/bin/kubectl: No such file or directory
```

`which` consulted `$PATH` and answered correctly. The **shell** answered from its hash table. `type` tells you the truth, because `type` is the shell:

```
$ type kubectl
kubectl is hashed (/usr/local/bin/kubectl)

$ hash -r          # flush the entire table
$ type kubectl
kubectl is /usr/bin/kubectl

$ hash -d kubectl  # flush a single entry
$ set +h           # disable hashing entirely (debugging only — measurable slowdown)
```

**Diagnostic rule:** if a command behaves differently in your interactive shell than in a systemd unit or a `cron` job, check three things in this order — `type -a <cmd>`, the effective `$PATH` (`systemctl show -p Environment <unit>`), and the hash table.

```
$ systemctl show -p Environment telemetry-agent.service
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

$ sudo systemctl show-environment
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
LANG=en_US.UTF-8
```

Note what is *absent*: `~/.local/bin`, `/opt/*/bin`, anything your `.bashrc` adds. A unit that "works when I run it by hand" and fails as a service is almost always this.

### 3.5 `whereis` — binaries, sources and manuals in one shot

`whereis` searches a **compiled-in list** of standard directories, plus `$PATH` and `$MANPATH`, and it strips known extensions before matching. It is the fastest way to answer "is this installed, and where is its documentation?"

```
$ whereis find
find: /usr/bin/find /usr/share/man/man1/find.1.gz /usr/share/info/find.info-1.gz /usr/share/info/find.info.gz

$ whereis -b find          # binaries only
find: /usr/bin/find

$ whereis -m find          # manual pages only
find: /usr/share/man/man1/find.1.gz /usr/share/info/find.info-1.gz /usr/share/info/find.info.gz

$ whereis -s bash          # sources only
bash:

$ whereis -l | head -8     # print the directories whereis actually searches
bin: /usr/bin
bin: /usr/sbin
bin: /usr/lib
bin: /usr/lib64
bin: /etc
bin: /usr/games
man: /usr/share/man
man: /usr/local/man
```

Option reference:

| Option | Effect |
|---|---|
| `-b` | Search for **b**inaries only |
| `-m` | Search for **m**anual pages only |
| `-s` | Search for **s**ources only |
| `-B <dirs> -f` | Override the binary search path (`-f` terminates the directory list) |
| `-M <dirs> -f` | Override the manual search path |
| `-S <dirs> -f` | Override the source search path |
| `-u` | Report only **unusual** entries — items missing one of the three categories |
| `-l` | List the effective search paths and exit |

`-u` is the underrated one. It is a one-command audit for binaries shipped without documentation, which on a hardened image usually means "installed outside the package manager":

```
$ cd /usr/bin && whereis -u -m *
kube-bench: 
custom-backup.sh:
node_exporter:
```

Three binaries in `/usr/bin` with no man page. On a fleet, that is your ad-hoc-install detector.

**Limitation to state clearly:** `whereis` will not find anything outside its hardcoded list. A binary in `/opt/vendor/bin` is invisible to it. That is what `find` and `locate` are for.

---

## 4. `find` — the exact, expensive, complete answer

### 4.1 Grammar

```
find [-H | -L | -P] [-D debugopts] [-Olevel] [starting-point...] [expression]
```

The expression is composed of four kinds of terms:

| Kind | Examples | Semantics |
|---|---|---|
| **Global options** | `-maxdepth`, `-mindepth`, `-depth`, `-xdev`, `-mount`, `-files0-from` | Affect the whole traversal regardless of position; must appear before other tests to avoid a warning |
| **Tests** | `-name`, `-type`, `-mtime`, `-size`, `-perm`, `-user`, `-empty` | Return true/false per file |
| **Actions** | `-print`, `-print0`, `-printf`, `-exec`, `-execdir`, `-delete`, `-ls`, `-quit` | Have a side effect; also return true/false |
| **Operators** | `( )`, `!` / `-not`, `-a` / `-and`, `-o` / `-or`, `,` | Combine terms |

**Precedence, highest to lowest:** `( )` → `!` → `-a` (implicit between adjacent terms) → `-o` → `,`

**If the expression contains no action, `-print` is implicitly appended to the whole expression.** If it contains any action, nothing is appended. This single rule explains most surprising `find` behaviour:

```
$ find /var/log -name '*.gz' -o -name '*.1'
/var/log/dnf.librepo.log.1
/var/log/messages-20260819.gz
```

Fine. Now add an action to one branch and the implicit `-print` disappears from the other:

```
$ find /var/log -name '*.gz' -o -name '*.1' -print
/var/log/dnf.librepo.log.1
```

The `.gz` files vanished, because the expression parsed as `( -name '*.gz' ) -o ( -name '*.1' -a -print )`. The fix is always explicit grouping:

```
$ find /var/log \( -name '*.gz' -o -name '*.1' \) -print
/var/log/dnf.librepo.log.1
/var/log/messages-20260819.gz
```

**The dangerous version of this bug:**

```bash
# WRONG — deletes every *.tmp AND every *.bak?  No: deletes only *.bak.
find /srv -name '*.tmp' -o -name '*.bak' -delete

# WRONG — deletes EVERYTHING under /srv, because -delete runs first and always
# succeeds, so -name is never reached in a short-circuit sense... and -delete
# implies -depth, reordering the traversal.
find /srv -delete -name '*.tmp'

# CORRECT
find /srv -type f \( -name '*.tmp' -o -name '*.bak' \) -delete
```

Always dry-run destructive expressions by swapping `-delete` for `-print` first. Always.

### 4.2 Name and path tests

| Test | Matches against | Case | Notes |
|---|---|---|---|
| `-name PATTERN` | basename | sensitive | Shell glob, **not** regex. Quote it or the shell expands it first |
| `-iname PATTERN` | basename | insensitive | |
| `-path PATTERN` | full path | sensitive | `*` **does** cross `/` — unlike shell globbing |
| `-ipath PATTERN` | full path | insensitive | |
| `-wholename` | full path | sensitive | GNU synonym for `-path` |
| `-regex PATTERN` | full path | sensitive | Must match the **whole** path; default dialect is Emacs regex |
| `-iregex PATTERN` | full path | insensitive | |
| `-regextype TYPE` | — | — | `posix-basic`, `posix-extended`, `egrep`, `emacs`, `findutils-default` |
| `-lname` / `-ilname` | symlink target | | |

```
$ find /etc -regextype posix-extended -regex '.*/(ssh|sshd)_config$' 2>/dev/null
/etc/ssh/ssh_config
/etc/ssh/sshd_config
```

The classic quoting failure:

```
$ cd /var/log && find . -name *.log
find: paths must precede expression: `audit.log'
find: possible unquoted pattern after predicate `-name'?
```

The shell expanded `*.log` against the current directory before `find` ever saw it. **Always single-quote patterns.**

### 4.3 Type, ownership and permission tests

| Test | Meaning |
|---|---|
| `-type f` | regular file |
| `-type d` | directory |
| `-type l` | symbolic link |
| `-type b` / `-type c` | block / character device |
| `-type p` / `-type s` | FIFO (named pipe) / socket |
| `-xtype l` | symlink whose target is a symlink — with `-L`, matches **broken** symlinks |
| `-user NAME` / `-uid N` | owner |
| `-group NAME` / `-gid N` | group |
| `-nouser` / `-nogroup` | owner/group has no entry in `/etc/passwd` or `/etc/group` — **orphaned files** |
| `-readable`, `-writable`, `-executable` | tested with `access(2)` as the *invoking* user |

Permission matching has three distinct modes and confusing them produces silently wrong audits:

| Syntax | Semantics | Example | Matches |
|---|---|---|---|
| `-perm MODE` | **Exactly** these bits | `-perm 644` | mode is precisely `0644` |
| `-perm -MODE` | **All** of these bits set (others may be too) | `-perm -0644` | `0644`, `0664`, `0755`, `4755` |
| `-perm /MODE` | **Any** of these bits set | `-perm /022` | group-writable **or** world-writable |

(`+MODE` was removed in findutils 4.5.12; use `/MODE`.)

```
$ sudo find /usr -xdev -type f -perm -4000 -printf '%M %u %g %8s %p\n' | head
-rwsr-xr-x root root    72040 /usr/bin/chage
-rwsr-xr-x root root    64232 /usr/bin/chfn
-rwsr-xr-x root root    39760 /usr/bin/chsh
-rwsr-xr-x root root    75304 /usr/bin/gpasswd
-rwsr-xr-x root root    56904 /usr/bin/mount
-rwsr-xr-x root root    39144 /usr/bin/newgrp
-rwsr-xr-x root root    32040 /usr/bin/passwd
-rwsr-xr-x root root    44880 /usr/bin/su
-rwsr-xr-x root root   187152 /usr/bin/sudo
-rwsr-xr-x root root    35128 /usr/bin/umount
```

### 4.4 Time tests — the truncation rule

`find` computes `(now − timestamp)` in seconds, divides by the unit (86400 for `-*time`, 60 for `-*min`) and **discards the fractional part**. Then:

| Argument | Meaning after truncation |
|---|---|
| `-mtime n` | exactly `n` — i.e. between `n` and `n+1` units old |
| `-mtime +n` | strictly greater than `n` — i.e. **at least `n+1` units old** |
| `-mtime -n` | strictly less than `n` |

So `-mtime +1` requires a file to be **at least two days** old, and `-mtime 0` means "modified within the last 24 hours".

| Test | Timestamp | Unit |
|---|---|---|
| `-atime` / `-amin` | last **access** | days / minutes |
| `-mtime` / `-mmin` | last **content modification** | days / minutes |
| `-ctime` / `-cmin` | last **inode change** (permissions, ownership, link count, *and* content) | days / minutes |
| `-newer FILE` | mtime newer than `FILE`'s mtime | — |
| `-anewer` / `-cnewer FILE` | atime / ctime newer than `FILE`'s mtime | — |
| `-newerXY REF` | `X`,`Y` ∈ `a`,`c`,`m`,`B`(birth),`t`(literal time) | GNU |
| `-used n` | accessed `n` days after its status last changed | — |

`-newermt` is the option that removes all arithmetic guesswork — prefer it whenever your `find` is GNU:

```
$ find /var/log -xdev -type f -newermt '2026-08-25 00:00:00' ! -newermt '2026-08-26 00:00:00' -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n'
2026-08-25 04:02      12288 /var/log/audit/audit.log.2
2026-08-25 09:31    2097152 /var/log/messages-20260825
2026-08-25 22:14      88121 /var/log/dnf.rpm.log
```

A crucial caveat for `-atime`: most production filesystems are mounted `relatime` or `noatime`, so access times are unreliable or frozen. Check before you build a cleanup policy on them:

```
$ findmnt -no OPTIONS /var
rw,relatime,seclabel,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

With `relatime`, atime is updated only if the previous atime is older than mtime/ctime or older than 24 h. A "delete files not accessed in 90 days" policy on a `noatime` mount deletes files that are actively read every second.

### 4.5 Size tests — the rounding-up rule

`-size n[suffix]`, where the suffix is:

| Suffix | Unit |
|---|---|
| `b` | 512-byte blocks (**default when omitted**) |
| `c` | bytes |
| `w` | 2-byte words |
| `k` | KiB (1024) |
| `M` | MiB |
| `G` | GiB |

**Sizes are rounded up to the next whole unit before comparison.** Therefore `-size -1M` matches only files of size 0, because a 1-byte file rounds up to 1 M-unit, which is not less than 1. Use `c` when you mean bytes:

```
$ find /var/log -xdev -type f -size +100M -printf '%s\t%p\n' | sort -rn | head -5
2147483648	/var/log/journal/9f2a.../system@0005.journal
1073741824	/var/log/audit/audit.log
 419430400	/var/log/telemetry-agent/agent.log

$ find /tmp -type f -size -1M          # matches ONLY empty files
/tmp/.X0-lock

$ find /tmp -type f -size -1048576c    # what you actually meant
/tmp/.X0-lock
/tmp/systemd-private-.../tmp/session.sock
```

`-empty` is the correct test for zero-length files **and** empty directories: `find /var/log -type f -empty`.

Note that `%s` is the apparent size and `%k`/`%b` are allocated blocks. For sparse files they diverge wildly:

```
$ find /var/lib/libvirt/images -name '*.qcow2' -printf '%s apparent, %k KiB allocated: %p\n'
53687091200 apparent, 8421376 KiB allocated: /var/lib/libvirt/images/node01.qcow2
```

### 4.6 Traversal control — `-maxdepth`, `-prune`, `-xdev`, `-depth`

These are what make `find /` finish in seconds instead of minutes.

**`-xdev` / `-mount`** — do not descend into other filesystems. Mandatory on any `find /` in production, otherwise you traverse NFS mounts, every container overlay under `/var/lib/containers`, and `/proc`:

```
$ time sudo find / -type f -name '*.conf' | wc -l
178432

real	2m41.883s
user	0m4.201s
sys	0m21.774s

$ time sudo find / -xdev -type f -name '*.conf' | wc -l
9214

real	0m3.117s
user	0m0.612s
sys	0m1.883s
```

**`-prune`** — do not descend into a matched directory. `-prune` always returns true and is meaningless with `-depth`. The canonical idiom is `-path X -prune -o <real expression> -print`:

```
$ sudo find / -xdev \( -path /var/lib/containers -o -path /var/lib/docker -o -path /proc -o -path /sys \) -prune -o -type f -perm -4000 -print
/usr/bin/chage
/usr/bin/chfn
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount
/usr/libexec/openssh/ssh-keysign
/usr/sbin/pam_timestamp_check
/usr/sbin/unix_chkpwd
```

Read that as: *"if the path is one of these, prune it (and the `-o` short-circuits, so `-print` never runs); otherwise, if it is a SUID regular file, print it."* The `-print` at the end is mandatory — the implicit `-print` would attach only to the last term.

**`-maxdepth n` / `-mindepth n`** — bound the depth. Depth 0 is the starting point itself.

```
$ find /etc -maxdepth 1 -type d | head -5
/etc
/etc/ssh
/etc/systemd
/etc/pki
/etc/security

$ find /etc -mindepth 1 -maxdepth 1 -type l -printf '%p -> %l\n' | head -3
/etc/localtime -> ../usr/share/zoneinfo/Europe/Madrid
/etc/mtab -> ../proc/self/mounts
/etc/system-release -> fedora-release
```

**`-depth`** — process directory contents *before* the directory itself (post-order). Required for `-delete` (and implied by it), and required when you rename directories during traversal.

### 4.7 Actions: `-exec` vs `-exec +` vs `xargs`

| Form | Invocations | `{}` position | Filenames with spaces/newlines | Exit status propagated | Speed |
|---|---|---|---|---|---|
| `-exec cmd {} \;` | **one per file** | anywhere, multiple times | safe | no (only used as a test) | slowest |
| `-exec cmd {} +` | batched up to `ARG_MAX` | must be last, once | safe | **yes** | fastest |
| `-execdir cmd {} \;` | one per file, `cwd` = file's dir | anywhere | safe | no | slow, **safest** |
| `-execdir cmd {} +` | batched per directory | last | safe | yes | fast + safe |
| `-print0 \| xargs -0 cmd` | batched | via `-I` or appended | safe **only with `-0`** | via `xargs` exit code | fastest, parallelisable |
| `-print \| xargs cmd` | batched | appended | **BROKEN** | — | — |

```
$ getconf ARG_MAX
2097152
```

Measured difference on 20 000 files:

```
$ time find /usr/share/doc -type f -name '*.gz' -exec gzip -t {} \; 2>/dev/null

real	0m47.219s
user	0m11.043s
sys	0m28.887s

$ time find /usr/share/doc -type f -name '*.gz' -exec gzip -t {} + 2>/dev/null

real	0m4.802s
user	0m3.911s
sys	0m0.744s
```

Ten times faster for the same work, because `{} +` amortises `fork`/`exec` across thousands of arguments.

When you need `{}` in the middle of a command, `+` cannot help you directly — wrap it:

```
$ find /etc -name '*.conf' -exec sh -c 'for f; do printf "%s: %d lines\n" "$f" "$(wc -l < "$f")"; done' _ {} + | head -3
/etc/dnf/dnf.conf: 4 lines
/etc/sysctl.conf: 1 lines
/etc/nsswitch.conf: 21 lines
```

The `_` is the `$0` placeholder; without it the first filename is consumed as `$0` and silently skipped.

**`xargs` with parallelism** — the pattern for large sweeps on multi-core nodes:

```
$ find /srv/media -type f -name '*.png' -print0 \
    | xargs -0 -r -P "$(nproc)" -n 32 optipng -quiet -o2
```

| `xargs` flag | Purpose |
|---|---|
| `-0` | Input is NUL-separated (pairs with `-print0`) |
| `-r`, `--no-run-if-empty` | Do not run the command at all if input is empty — **without this, `xargs rm` with no input runs `rm` and errors, and `xargs ls` lists `$PWD`** |
| `-n N` | At most `N` arguments per invocation |
| `-P N` | Run up to `N` invocations in parallel |
| `-I {}` | Replace-string mode; implies `-n 1` and `-L 1` (kills throughput) |
| `-t` | Echo each command before running it |

**`-execdir` and the TOCTOU problem.** With `-exec`, `find` passes a full path that is resolved by the child process *after* traversal. Between `find` deciding the path is safe and the child opening it, an attacker with write access to an intermediate directory can swap a component for a symlink. `-execdir` chdirs into the containing directory and passes `./basename`, closing the window. GNU `find` also refuses `-execdir` if `$PATH` contains a relative or empty element:

```
$ PATH="$PATH:." find /tmp -type f -execdir file {} +
find: The relative path `.' is included in the PATH environment variable, which is insecure in combination with the -execdir action of find.  Please remove that entry from $PATH
```

Use `-execdir` for anything running as root over directories that non-root users can write.

**`-ok` / `-okdir`** prompt before each execution — useful for interactive cleanup, useless in automation:

```
$ find /var/tmp -maxdepth 1 -type f -mtime +90 -ok rm -f {} \;
< rm ... /var/tmp/core.12841 > ? y
< rm ... /var/tmp/build-cache.tar > ? n
```

**`-delete`** is faster than `-exec rm {} +` (it uses `unlinkat(2)` directly, no process spawn) and it implies `-depth` so it can remove directories bottom-up. It refuses to remove `.` and non-empty directories.

**`-quit`** stops traversal at the first match — the cheap "does this exist anywhere?" query:

```
$ find /usr -name 'libssl.so.3' -print -quit
/usr/lib64/libssl.so.3
```

### 4.8 `-printf` — structured output without a second process

`-ls` is human-oriented and unstable. `-printf` is your machine interface.

| Directive | Value |
|---|---|
| `%p` | full path |
| `%f` | basename |
| `%h` | dirname |
| `%P` | path with the starting-point prefix removed |
| `%s` | size in bytes |
| `%k` / `%b` | size in 1 KiB blocks / 512-byte blocks (allocated) |
| `%m` / `%M` | permission bits in octal / `ls`-style symbolic |
| `%u` / `%U` | owner name / uid |
| `%g` / `%G` | group name / gid |
| `%i` | inode number |
| `%n` | hard link count |
| `%d` | depth below the starting point |
| `%y` / `%Y` | type letter / type after following symlinks (`f d l b c p s`; `N` broken, `L` loop) |
| `%l` | symlink target |
| `%D` | device number of the containing filesystem |
| `%T@` | mtime as `seconds.nanoseconds` since epoch |
| `%TY-%Tm-%Td %TH:%TM:%TS` | formatted mtime (`%A…` atime, `%C…` ctime, `%B…` birth) |
| `%Z` | SELinux context |
| `\n \t \\ \0` | newline, tab, backslash, NUL |

```
$ find /var/log -xdev -type f -printf '%T@ %10s %M %u:%g %p\n' | sort -rn | head -5
1756193472.0000000000  524288000 -rw-r----- root:systemd-journal /var/log/journal/9f2a/system.journal
1756193401.0000000000   14680064 -rw------- root:root /var/log/audit/audit.log
1756192088.0000000000    2097152 -rw-r----- telemetry:telemetry /var/log/telemetry-agent/agent.log
1756191002.0000000000     327680 -rw-r--r-- root:root /var/log/dnf.log
1756190455.0000000000      65536 -rw-r--r-- root:root /var/log/firewalld
```

Sorting by `%T@` numerically is the reliable "what changed most recently across this whole subtree" query — vastly better than `ls -lt` because it recurses and does not depend on locale-formatted dates.

### 4.9 Performance: the optimiser, and how to help it

GNU `find` reorders tests by estimated cost. Levels:

| Level | Behaviour |
|---|---|
| `-O0` | Same as `-O1` |
| `-O1` | **Default.** Filename tests (`-name`, `-regex`) are evaluated before anything requiring `stat(2)` |
| `-O2` | Filename tests first, then `-type`/`-xtype` (satisfiable from `readdir` on filesystems supporting `d_type`), then `stat`-requiring tests |
| `-O3` | Full cost-based reordering using measured success probabilities |

```
$ find --version | tail -1
Features enabled: D_TYPE O_NOFOLLOW(enabled) LEAF_OPTIMISATION FTS(FTS_CWDFD) CBO(level=2)

$ find /usr -D rates -name '*.so' -type f 2>&1 | tail -6
Predicate success rates after completion:
[type=f] [est success rate 0.5] [name=*.so] [est success rate 0.1] -a [ -print ]
                                            ^ actual: 0.0193
                       ^ actual: 0.7712
```

Practical rules that beat the optimiser every time:

1. **`-xdev` first.** Nothing else saves as much.
2. **`-prune` the known-huge subtrees** (`/var/lib/containers`, `/var/lib/docker`, `/proc`, `/sys`, NFS mounts, build caches).
3. **`-maxdepth`** when you know the depth.
4. **Cheap tests before expensive ones** if you have disabled the optimiser or are on a POSIX `find`: `-name` (string compare on the `readdir` result) → `-type` (`d_type`, no syscall) → `-size`/`-perm`/`-*time` (needs `stat`) → `-exec` (needs `fork`).
5. **`-quit`** for existence checks.
6. **`ionice`/`nice`** on production nodes — a full-tree `find` is an I/O storm:

```
$ sudo ionice -c3 nice -n19 find / -xdev -type f -size +1G -printf '%s %p\n' | sort -rn
```

`-c3` is the idle I/O class: the sweep yields to every other reader on the node.

### 4.10 Safety and correctness checklist for `find` in automation

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Anchor to an absolute starting point that you validated exists.
readonly ROOT=/var/cache/telemetry-agent
[[ -d $ROOT ]] || { printf 'fatal: %s is not a directory\n' "$ROOT" >&2; exit 1; }

# 2. Never let a variable be the whole expression; never build find args by
#    string concatenation. Use an array.
readonly -a PRUNE=(
  -path "$ROOT/.keep" -prune -o
)

# 3. Dry-run mode is not optional for anything that deletes.
DRY_RUN=${DRY_RUN:-1}
if (( DRY_RUN )); then
    action=(-print)
else
    action=(-delete)
fi

# 4. -xdev, explicit -type, explicit grouping, NUL-safe if piping.
find "$ROOT" -xdev "${PRUNE[@]}" \
     -type f \
     -mtime +7 \
     \( -name '*.tmp' -o -name '*.partial' \) \
     "${action[@]}"

# 5. find's exit status: 0 = clean, >0 = at least one error (permission denied,
#    unreadable directory). set -e catches it. Do NOT hide it with 2>/dev/null
#    unless you have already decided that unreadable directories are acceptable.
```

Additional hazards:

* **Never pipe a `find` sweep through `tee`** and check `$?` — the pipeline's exit status is `tee`'s. Use `set -o pipefail` or `PIPESTATUS`.
* `find ... | while read -r f` breaks on filenames containing newlines. Use `find -print0 | while IFS= read -r -d '' f`.
* `find` on a directory being concurrently modified may miss or duplicate entries; it is not a consistent snapshot.
* Relative starting points combined with `-execdir` and `cd` inside `-exec sh -c` produce path-resolution bugs. Use absolute paths.

---

## 5. `locate` and `updatedb` — the indexed search plane

### 5.1 Architecture

`locate` does not touch the filesystem tree. It reads a **prebuilt database** produced by `updatedb`, typically once a day.

```
updatedb (root, via systemd timer)
   │  walks the filesystem, honouring /etc/updatedb.conf
   ▼
/var/lib/plocate/plocate.db      (plocate; mode 0640 root:plocate)
/var/lib/mlocate/mlocate.db      (mlocate; mode 0640 root:mlocate)
   ▲
   │  read by a setgid binary that filters results per calling user
locate (any user)
```

**The security model matters and is frequently misunderstood.** A naïve index leaks the existence of every file on the system to every user, including other users' home directories. Both `mlocate` and `plocate` solve this by:

1. Storing the database mode `0640`, owned by `root` and a dedicated group.
2. Installing the `locate` binary **setgid** to that group, so it — and only it — can read the database.
3. Recording directory metadata in the index and, at query time, checking whether the calling user can actually traverse the parent directories of each candidate. Entries that fail the check are silently dropped.

```
$ ls -l /usr/bin/plocate
-rwxr-sr-x. 1 root plocate 92104 Jul 22 08:11 /usr/bin/plocate

$ ls -l /var/lib/plocate/plocate.db
-rw-r-----. 1 root plocate 38914560 Aug 26 04:12 /var/lib/plocate/plocate.db

$ id -Gn
sre wheel

$ head -c 16 /var/lib/plocate/plocate.db
head: cannot open '/var/lib/plocate/plocate.db' for reading: Permission denied
```

The user cannot read the database, but `locate` can, and it filters on their behalf. Consequence for exams and for reasoning: **`locate` output differs between users on the same machine at the same instant.**

### 5.2 `mlocate` vs `plocate`

`plocate` (by Steinar H. Gunderslev) replaced `mlocate` as the default in Debian 12 and Fedora 36+. It uses a posting-list index with io_uring, giving sub-millisecond queries on multi-million-file databases.

| | `mlocate` | `plocate` |
|---|---|---|
| Database | `/var/lib/mlocate/mlocate.db` | `/var/lib/plocate/plocate.db` |
| Group | `mlocate` | `plocate` |
| Index structure | Sorted path list, linear scan | Trigram posting lists (compressed) |
| Query on ~10 M paths | ~1–2 s | ~1–10 ms |
| Database size | larger | ~30–50 % smaller |
| Incremental update | Yes (compares directory mtimes) | Yes (`updatedb --prune-bind-mounts`, can read an mlocate db) |
| Config file | `/etc/updatedb.conf` | **`/etc/updatedb.conf`** (same format) |
| Schedule | `/etc/cron.daily/mlocate` or `mlocate-updatedb.timer` | `plocate-updatedb.timer` |
| Substring match without `-r` | Yes | Yes, but requires ≥3 characters for the trigram index (shorter patterns fall back to a scan) |

Both are drop-in compatible at the CLI level for the options the exam covers, and both read the **same** `/etc/updatedb.conf`.

### 5.3 `locate` usage

Pattern semantics — the rule that catches everyone:

> If the pattern contains **no** globbing characters (`*`, `?`, `[`), `locate` matches it as `*PATTERN*` — a substring of the whole path.
> If it **does** contain globbing characters, the pattern is matched against the **entire path**, and you must supply the leading/trailing `*` yourself.

```
$ locate sshd_config
/etc/ssh/sshd_config
/usr/share/man/man5/sshd_config.5.gz
/usr/share/vim/vim91/syntax/sshdconfig.vim

$ locate '*sshd_config'          # anchored at the end
/etc/ssh/sshd_config

$ locate 'sshd_config*'          # nothing: no path STARTS with sshd_config
$ echo $?
1
```

Option reference:

| Option | Effect |
|---|---|
| `-i`, `--ignore-case` | Case-insensitive |
| `-b`, `--basename` | Match against the basename only, not the full path |
| `-w`, `--wholename` | Match the whole path (default) |
| `-r`, `--regexp REGEX` | POSIX basic regex instead of glob |
| `--regex` | Treat all *patterns* as POSIX extended regexes |
| `-e`, `--existing` | **Only print entries that still exist** — pays a `stat(2)` per hit |
| `-c`, `--count` | Print the number of matches instead of the matches |
| `-l N`, `--limit N` | Stop after `N` results |
| `-0`, `--null` | NUL-separate output (pipe to `xargs -0`) |
| `-d DB`, `--database DB` | Use an alternate database (`:`-separated list) |
| `-S`, `--statistics` | Print database statistics and exit |
| `-A`, `--all` | Print entries matching **all** patterns, not any |
| `-q`, `--quiet` | Suppress error messages |

```
$ locate -c '*.service'
2841

$ locate -i -b -l 5 'NGINX.CONF'
/etc/nginx/nginx.conf
/usr/share/doc/nginx/nginx.conf.default

$ locate -0 -b '*.crt' | xargs -0 -r openssl x509 -noout -enddate -in 2>/dev/null | head -3
notAfter=Nov 12 08:30:00 2026 GMT

$ locate -S
Database /var/lib/mlocate/mlocate.db:
	 24,811 directories
	312,904 files
	16,842,003 bytes in file names
	 7,109,884 bytes used to store database
```

### 5.4 The staleness trap — and `-e`

This is the single most common `locate` failure in an incident:

```
$ sudo rm -f /etc/opt/telemetry-agent/agent.yaml.bak
$ locate agent.yaml.bak
/etc/opt/telemetry-agent/agent.yaml.bak

$ locate -e agent.yaml.bak
$ echo $?
1
```

The index is a snapshot from the last `updatedb` run. It reports files that were deleted and misses files created since. During triage, either pass `-e`, or refresh:

```
$ stat -c '%y %n' /var/lib/plocate/plocate.db
2026-08-26 04:12:07.331884012 +0200 /var/lib/plocate/plocate.db

$ sudo systemctl list-timers plocate-updatedb.timer
NEXT                        LEFT       LAST                        PASSED   UNIT                    ACTIVATES
Thu 2026-08-27 04:12:00 CEST 17h left   Wed 2026-08-26 04:12:00 CEST 7h ago   plocate-updatedb.timer  plocate-updatedb.service

$ time sudo updatedb
real	0m38.442s
user	0m2.117s
sys	0m11.006s
```

**Rule:** `locate` is for exploration and for questions where a day-old answer is acceptable. Use `find` for anything a decision depends on, and always for anything created in the last 24 hours.

### 5.5 `/etc/updatedb.conf` — annotated, complete

The file is a shell-style `KEY = "value"` list. Whitespace-separated lists; values are matched case-insensitively for `PRUNEFS`.

```sh
# /etc/updatedb.conf — configuration for updatedb(8) (mlocate/plocate format).
# See updatedb.conf(5). Every entry here directly determines what locate(1)
# can find, and how long the nightly index build takes.

# --------------------------------------------------------------------------
# PRUNE_BIND_MOUNTS
#   "yes" -> skip bind mounts. Essential on container hosts and on any node
#   using systemd's BindPaths=/ProtectSystem= sandboxing, where the same inode
#   is visible under dozens of paths. Without it, updatedb indexes the same
#   tree once per bind mount and the database explodes.
# --------------------------------------------------------------------------
PRUNE_BIND_MOUNTS = "yes"

# --------------------------------------------------------------------------
# PRUNEFS
#   Filesystem TYPES (as reported in /proc/mounts) never to descend into.
#   Matched case-insensitively. Two categories matter operationally:
#     - Network filesystems: indexing them turns a local cron job into a
#       fleet-wide I/O storm against the NFS/CIFS server every night.
#     - Virtual/pseudo filesystems: infinite or meaningless to index.
# --------------------------------------------------------------------------
PRUNEFS = "9p afs anon_inodefs auto autofs bdev binfmt_misc cgroup cgroup2 cifs
coda configfs cpuset curlftpfs debugfs devpts devtmpfs ecryptfs exofs ftpfs
fuse fuse.ceph fuse.glusterfs fuse.gvfsd-fuse fuse.rclone fuse.s3fs fuse.sshfs
fusectl fuse.portal gfs gfs2 gpfs hugetlbfs inotifyfs iso9660 jffs2 lustre
mfs mqueue ncpfs nfs nfs4 nfsd nnpfs ocfs ocfs2 overlay pipefs proc pstore
ramfs rpc_pipefs securityfs selinuxfs sfs smbfs sockfs squashfs sysfs tmpfs
tracefs ubifs udf usbfs vboxsf"

# --------------------------------------------------------------------------
# PRUNENAMES
#   Directory BASENAMES to skip anywhere in the tree. Note: names only, never
#   paths, and wildcards are NOT supported. This is how you exclude VCS
#   metadata, which otherwise contributes millions of useless entries on a
#   developer workstation or a CI runner.
# --------------------------------------------------------------------------
PRUNENAMES = ".git .hg .svn .bzr .arch-ids {arch} CVS .terraform node_modules
.cache __pycache__ .venv target"

# --------------------------------------------------------------------------
# PRUNEPATHS
#   Absolute directory PATHS to skip, exactly as locate would report them:
#   no trailing slash, no wildcards, no symlinks. Two reasons to add a path:
#     1. Cost      - huge, churning trees (container layers, build caches).
#     2. Secrecy   - trees whose mere filenames leak information. Remember
#                    that locate's per-user filtering already hides
#                    unreadable paths, so this is defence in depth, not the
#                    primary control.
# --------------------------------------------------------------------------
PRUNEPATHS = "/afs /media /mnt /net /sfs /tmp /udev /var/tmp
/var/cache/ccache /var/cache/telemetry-agent
/var/lib/ceph /var/lib/containers /var/lib/docker /var/lib/kubelet
/var/lib/machines /var/lib/os-prober /var/lib/schroot
/var/spool/cups /var/spool/squid
/home/.ecryptfs"
```

Verify a change actually took effect. Editing the file proves nothing:

```
$ sudo updatedb -v 2>&1 | head -3
updatedb: reading config file `/etc/updatedb.conf'
updatedb: skipping `/var/lib/containers' (PRUNEPATHS)
updatedb: skipping `/proc' (PRUNEFS: proc)

$ locate -c '/var/lib/containers'
0
$ locate -c '/var/lib/docker'
0
$ locate -c 'node_modules'
0
```

`updatedb` command-line overrides (they take precedence over the config file):

| Option | Effect |
|---|---|
| `-U DIR`, `--database-root DIR` | Index only this subtree |
| `-o FILE`, `--output FILE` | Write to an alternate database |
| `-l 0`, `--require-visibility no` | Build a **world-readable** database with no per-user filtering — only for a database you will ship to unprivileged consumers, and only if it contains nothing sensitive |
| `-e DIRS`, `--prune-paths DIRS` | Additional paths to skip |
| `-f FSTYPES`, `--prune-fs FSTYPES` | Additional filesystem types to skip |
| `-n NAMES`, `--prune-names NAMES` | Additional basenames to skip |
| `-v`, `--verbose` | Print every path as it is indexed |

A useful pattern — a private, per-project index that does not require root and does not pollute the system database:

```
$ updatedb -l 0 -U /srv/media -o "$HOME/.cache/media.db"
$ locate -d "$HOME/.cache/media.db" -i -b '*.flac' | wc -l
18422
$ locate -d "$HOME/.cache/media.db":/var/lib/plocate/plocate.db 'concert'
/srv/media/audio/2026-concert-master.flac
/usr/share/backgrounds/concert.jpg
```

### 5.6 Controlling the cost of `updatedb` on production nodes

An unconstrained `updatedb` on a node with a 40 TiB NFS mount will saturate the storage network at 04:00 every day. Constrain it with a drop-in:

**`/etc/systemd/system/plocate-updatedb.service.d/10-throttle.conf`**

```ini
[Service]
# Yield to every other consumer of the disk.
IOSchedulingClass=idle
IOSchedulingPriority=7
Nice=19
CPUSchedulingPolicy=idle

# Hard ceilings, so a runaway index build cannot page out the workload.
MemoryMax=512M
MemoryHigh=256M
IOReadIOPSMax=/dev/nvme0n1 2000

# Fail loudly rather than run for hours.
TimeoutStartSec=20min
```

**`/etc/systemd/system/plocate-updatedb.timer.d/10-schedule.conf`**

```ini
[Timer]
# Fixed daily slot, spread across the fleet so N nodes do not hit shared
# storage simultaneously.
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl restart plocate-updatedb.timer
$ systemctl cat plocate-updatedb.timer | tail -6
# /etc/systemd/system/plocate-updatedb.timer.d/10-schedule.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3600
Persistent=true
AccuracySec=1min

$ systemd-analyze calendar '*-*-* 03:00:00'
  Original form: *-*-* 03:00:00
Normalized form: *-*-* 03:00:00
    Next elapse: Thu 2026-08-27 03:00:00 CEST
       From now: 15h left
```

On immutable/minimal images (Bottlerocket, Flatcar, distroless containers) `locate` is typically absent entirely. Do not build a runbook that depends on it without checking:

```
$ command -v locate || echo "locate is not available on this image"
locate is not available on this image
```

### 5.7 `find` vs `locate` — the decision table

| Dimension | `find` | `locate` |
|---|---|---|
| Data source | Live filesystem | Nightly database |
| Freshness | Exact, now | Up to 24 h stale |
| Latency on 10 M files | 30 s – 10 min | 1 ms – 2 s |
| I/O cost | High — walks every inode | Near zero |
| Privileges | Sees what the invoking user can traverse; `sudo` sees everything | Filtered per user by the setgid helper |
| Expressiveness | Size, time, permission, owner, type, links, `-exec` | Path/name substring or regex only |
| Can act on results | Yes (`-exec`, `-delete`) | No — must pipe to `xargs` |
| Works in a container | Yes | Usually not installed |
| Correct for | "Which files changed in the last hour?", "Which are SUID?", "Delete these" | "Where is `nginx.conf` again?" |

**The composed idiom** — use `locate` to narrow the candidate set for free, then `find` to answer exactly:

```
$ locate -0 -b 'nginx.conf' | xargs -0 -r find -maxdepth 0 -newermt '-1 day' -printf '%TF %TT %p\n'
2026-08-26 09:41:12.114 /etc/nginx/nginx.conf
```

---

## 6. Production runbooks

### 6.1 Runbook: `/` is 100 % full at 03:00

```
$ df -h / /var
Filesystem              Size  Used Avail Use% Mounted on
/dev/mapper/vg0-root     50G   50G     0 100% /
/dev/mapper/vg0-var     200G  118G   73G  62% /var
```

Step 1 — find the offenders **without leaving the filesystem**:

```
$ sudo find / -xdev -type f -size +200M -printf '%10s  %TF %TT  %p\n' 2>/dev/null | sort -rn | head
9663676416  2026-08-26 02:58:01  /var/lib/telemetry-agent/spool.db
2147483648  2026-08-26 01:12:44  /opt/telemetry-agent/logs/agent.log
1073741824  2026-08-25 23:40:02  /root/core.28841
```

`/opt/telemetry-agent/logs/agent.log` is the smoking gun: a vendor writing logs inside `/opt` — a **static** hierarchy — so logrotate's `/var/log/*` patterns never matched it, and it grew until `/` filled. That is an FHS violation causing a production outage, which is precisely why this topic exists.

Step 2 — quantify by directory:

```
$ sudo find / -xdev -type f -printf '%h %s\n' 2>/dev/null \
    | awk '{ sz[$1] += $2 } END { for (d in sz) printf "%12d  %s\n", sz[d], d }' \
    | sort -rn | head -8
  2147495936  /opt/telemetry-agent/logs
  1073745920  /root
   402653184  /usr/lib/modules/6.11.4-200.fc44.x86_64
   201326592  /usr/lib64
```

Step 3 — check for **deleted-but-open** files. `find` cannot see these, and this is the case where `df` and `du` disagree:

```
$ df -h / | tail -1
/dev/mapper/vg0-root  50G   50G     0 100% /
$ sudo du -shx / 2>/dev/null
19G	/

$ sudo lsof -nP +L1 / | head -5
COMMAND    PID      USER   FD   TYPE DEVICE   SIZE/OFF NLINK     NODE NAME
agent    28841 telemetry    5w   REG  253,0 32212254720     0  1180742 /opt/telemetry-agent/logs/agent.log (deleted)

$ sudo find /proc/*/fd -ls 2>/dev/null | grep '(deleted)' | head -3
1180742 0 lrwx------ 1 telemetry telemetry 64 Aug 26 03:04 /proc/28841/fd/5 -> /opt/telemetry-agent/logs/agent.log (deleted)
```

31 GiB held by a process whose log file was already `rm`'d. Truncate via `/proc` rather than restarting the service:

```
$ sudo truncate -s 0 /proc/28841/fd/5
$ df -h / | tail -1
/dev/mapper/vg0-root   50G   19G   29G  40% /
```

Step 4 — permanent fix: move the logs to `/var/log`, add `LogsDirectory=` to the unit, install a `logrotate` policy, and add a CI check (§6.5) so the layout regression cannot recur.

### 6.2 Runbook: inode exhaustion

Space free, writes failing with `ENOSPC`:

```
$ df -h /var | tail -1
/dev/mapper/vg0-var   200G   61G  130G  33% /var

$ df -i /var | tail -1
Filesystem             Inodes   IUsed IFree IUse% Mounted on
/dev/mapper/vg0-var  13107200 13107200     0  100% /var
```

Locate the directory holding millions of tiny files:

```
$ sudo find /var -xdev -printf '%h\n' 2>/dev/null | sort | uniq -c | sort -rn | head -5
9184422 /var/spool/postfix/maildrop
 481003 /var/lib/telemetry-agent/queue
  91204 /var/cache/dnf
   4211 /var/log/journal/9f2ab8c1

$ sudo find /var/spool/postfix/maildrop -xdev -type f -mtime +2 -printf '%TF %p\n' | head -3
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0B4
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0B7
2026-08-19 /var/spool/postfix/maildrop/AF31C2A0BA
```

Delete in batches, at idle I/O priority, so the cleanup itself does not cause a second incident:

```
$ sudo ionice -c3 find /var/spool/postfix/maildrop -xdev -type f -mtime +2 -delete
$ df -i /var | tail -1
/dev/mapper/vg0-var  13107200 3922778 9184422  30% /var
```

Note `-delete` rather than `-exec rm {} \;`: nine million `fork`/`exec` pairs would take hours.

### 6.3 Runbook: fleet-wide SUID/SGID and world-writable audit

**`k8s/fhs-audit.yaml`** — a `DaemonSet` that runs the sweep on every node, plus a `CronJob` for a scheduled full pass.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-audit
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fhs-audit
  namespace: node-audit
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fhs-audit-script
  namespace: node-audit
data:
  audit.sh: |
    #!/usr/bin/env bash
    # FHS and search-plane audit. Runs against the node root bind-mounted
    # read-only at /host. Emits newline-delimited JSON to stdout so a log
    # shipper can index it directly.
    set -uo pipefail

    NODE="${NODE_NAME:-unknown}"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    emit() {  # emit <check> <severity> <detail...>
        local check=$1 sev=$2; shift 2
        printf '{"ts":"%s","node":"%s","check":"%s","severity":"%s","detail":"%s"}\n' \
            "$TS" "$NODE" "$check" "$sev" "${*//\"/\\\"}"
    }

    # Subtrees that are either pseudo-filesystems or container storage. -xdev
    # already excludes other mounts; these are belt-and-braces for bind mounts.
    PRUNE=(
        -path /host/proc -o
        -path /host/sys  -o
        -path /host/var/lib/containers -o
        -path /host/var/lib/docker     -o
        -path /host/var/lib/kubelet
    )

    # --- 1. SUID / SGID binaries outside the distribution baseline -----------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         -type f \( -perm -4000 -o -perm -2000 \) \
         -printf '%m|%u|%g|%s|%p\n' 2>/dev/null \
    | while IFS='|' read -r mode owner group size path; do
        case "${path#/host}" in
            /usr/bin/*|/usr/sbin/*|/usr/libexec/*) sev=info  ;;
            /usr/local/*|/opt/*)                   sev=high  ;;
            *)                                     sev=critical ;;
        esac
        emit suid_sgid "$sev" "mode=$mode owner=$owner group=$group size=$size path=${path#/host}"
    done

    # --- 2. World-writable directories without the sticky bit ---------------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         -type d -perm -0002 ! -perm -1000 \
         -printf '%m|%u|%p\n' 2>/dev/null \
    | while IFS='|' read -r mode owner path; do
        emit world_writable_dir high "mode=$mode owner=$owner path=${path#/host}"
    done

    # --- 3. Files owned by no known user or group (orphans) -----------------
    find /host -xdev \( "${PRUNE[@]}" \) -prune -o \
         \( -nouser -o -nogroup \) \
         -printf '%U|%G|%p\n' 2>/dev/null \
    | head -200 \
    | while IFS='|' read -r uid gid path; do
        emit orphaned_file medium "uid=$uid gid=$gid path=${path#/host}"
    done

    # --- 4. FHS violations: writable content inside static hierarchies -------
    find /host/usr /host/opt -xdev -type f -newermt '-24 hours' \
         ! -path '/host/usr/local/*' \
         -printf '%TF %TT|%p\n' 2>/dev/null \
    | while IFS='|' read -r mtime path; do
        emit static_hierarchy_mutation high "mtime=$mtime path=${path#/host}"
    done

    # --- 5. Executables shipped without a man page (ad-hoc installs) --------
    find /host/usr/bin /host/usr/sbin /host/usr/local/bin -maxdepth 1 -type f \
         -perm -u+x -printf '%f\n' 2>/dev/null \
    | while read -r bin; do
        if ! compgen -G "/host/usr/share/man/man*/${bin}.*" >/dev/null 2>&1; then
            emit undocumented_binary low "name=$bin"
        fi
    done

    # --- 6. locate index freshness ------------------------------------------
    for db in /host/var/lib/plocate/plocate.db /host/var/lib/mlocate/mlocate.db; do
        [[ -e $db ]] || continue
        age_h=$(( ( $(date +%s) - $(stat -c %Y "$db") ) / 3600 ))
        if (( age_h > 48 )); then
            emit locate_db_stale medium "db=${db#/host} age_hours=$age_h"
        else
            emit locate_db_fresh info "db=${db#/host} age_hours=$age_h"
        fi
    done

    emit audit_complete info "finished"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fhs-audit
  namespace: node-audit
  labels:
    app.kubernetes.io/name: fhs-audit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fhs-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fhs-audit
    spec:
      serviceAccountName: fhs-audit
      automountServiceAccountToken: false
      hostPID: false
      hostNetwork: false
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 30
      containers:
        - name: audit
          image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
          command: ["/bin/bash", "-c"]
          args:
            - |
              microdnf install -y findutils bash coreutils >/dev/null 2>&1 || true
              while true; do
                  /scripts/audit.sh
                  sleep "${AUDIT_INTERVAL_SECONDS:-21600}"
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: AUDIT_INTERVAL_SECONDS
              value: "21600"
          securityContext:
            # Traversing the whole node root requires uid 0 and DAC_READ_SEARCH.
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            privileged: false
            capabilities:
              drop: ["ALL"]
              add: ["DAC_READ_SEARCH"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: host-root
              mountPath: /host
              readOnly: true
              mountPropagation: HostToContainer
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
        - name: scripts
          configMap:
            name: fhs-audit-script
            defaultMode: 0555
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: fhs-audit-nightly
  namespace: node-audit
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 900
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: fhs-audit
          automountServiceAccountToken: false
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
          containers:
            - name: audit
              image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
              command: ["/bin/bash", "/scripts/audit.sh"]
              env:
                - name: NODE_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: spec.nodeName
              securityContext:
                runAsUser: 0
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
                  add: ["DAC_READ_SEARCH"]
                seccompProfile:
                  type: RuntimeDefault
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits:   {cpu: "1",  memory: 256Mi}
              volumeMounts:
                - name: host-root
                  mountPath: /host
                  readOnly: true
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
          volumes:
            - name: host-root
              hostPath: {path: /, type: Directory}
            - name: scripts
              configMap: {name: fhs-audit-script, defaultMode: 0555}
```

```
$ kubectl apply -f k8s/fhs-audit.yaml
namespace/node-audit created
serviceaccount/fhs-audit created
configmap/fhs-audit-script created
daemonset.apps/fhs-audit created
cronjob.batch/fhs-audit-nightly created

$ kubectl -n node-audit logs ds/fhs-audit --tail=6 | jq -c 'select(.severity=="high" or .severity=="critical")'
{"ts":"2026-08-26T11:04:12Z","node":"worker-03","check":"suid_sgid","severity":"high","detail":"mode=4755 owner=root group=root size=1284120 path=/usr/local/bin/nsenter-helper"}
{"ts":"2026-08-26T11:04:19Z","node":"worker-03","check":"world_writable_dir","severity":"high","detail":"mode=777 owner=root path=/srv/uploads"}
{"ts":"2026-08-26T11:04:31Z","node":"worker-03","check":"static_hierarchy_mutation","severity":"high","detail":"mtime=2026-08-26 02:11:04 path=/opt/telemetry-agent/logs/agent.log"}
```

### 6.4 Runbook: configuration drift and stray files

Cross-check the package manager's own manifest against the live tree. This is the highest-signal check on any long-lived host.

**RPM-based:**

```
$ sudo rpm -Va --nomtime --nordev 2>/dev/null | head -8
S.5....T.  c /etc/ssh/sshd_config
.M.......    /var/log/telemetry-agent
missing      /usr/share/man/man1/agent.1.gz
S.5....T.    /usr/bin/kubectl
```

Verification flag legend: `S` size, `M` mode, `5` MD5 digest, `D` device, `L` symlink target, `U` user, `G` group, `T` mtime, `P` capabilities; `c` marks a config file (expected to differ), and `missing` means the file is gone entirely. `/usr/bin/kubectl` differing with **no** `c` flag means someone overwrote a packaged binary in place — a supply-chain red flag.

**Debian-based:**

```
$ sudo debsums -c 2>/dev/null
/usr/bin/kubectl
/etc/nginx/nginx.conf
```

**Files present but owned by no package** — the true "who put this here" query:

```
$ sudo find /usr/bin /usr/sbin /usr/local/bin -maxdepth 1 -type f -print0 2>/dev/null \
    | xargs -0 -r rpm -qf --qf '%{NAME}\n' 2>&1 \
    | grep 'is not owned by any package'
file /usr/local/bin/nsenter-helper is not owned by any package
file /usr/bin/custom-backup.sh is not owned by any package
```

Debian equivalent:

```
$ sudo find /usr/bin -maxdepth 1 -type f -print0 \
    | xargs -0 -r -n50 dpkg -S 2>&1 \
    | grep 'no path found'
dpkg-query: no path found matching pattern /usr/bin/custom-backup.sh
```

### 6.5 CI gate: reject FHS violations before they ship

**`.gitlab-ci.yml`** (equivalently a GitHub Actions job) that fails the build if a package would write outside its declared layout.

```yaml
stages:
  - build
  - policy

variables:
  PKG_NAME: "telemetry-agent"

build:package:
  stage: build
  image: fedora:44
  script:
    - dnf -y install rpm-build rpmdevtools findutils
    - rpmbuild -bb --define "_topdir ${CI_PROJECT_DIR}/rpmbuild" packaging/${PKG_NAME}.spec
  artifacts:
    paths: ["rpmbuild/RPMS/"]
    expire_in: 1 day

policy:fhs:
  stage: policy
  image: fedora:44
  needs: ["build:package"]
  script:
    - dnf -y install rpm findutils
    - |
      set -euo pipefail
      RPM=$(find rpmbuild/RPMS -name "${PKG_NAME}-*.rpm" -type f -print -quit)
      echo "Auditing payload of ${RPM}"
      rpm -qlp "$RPM" > /tmp/payload.txt

      fail=0
      check() {  # check <regex> <message>
        if grep -qE "$1" /tmp/payload.txt; then
          printf 'FHS VIOLATION: %s\n' "$2" >&2
          grep -E "$1" /tmp/payload.txt | sed 's/^/    /' >&2
          fail=1
        fi
      }

      check '^/etc/.*/(bin|sbin)/'          '/etc must not contain binaries (FHS 3.0 §3.7)'
      check '^/usr/(var|etc)/'              'no /usr/var or /usr/etc; use /var and /etc'
      check '^/opt/[^/]+/(etc|var|log)/'    '/opt packages must use /etc/opt and /var/opt (FHS 3.0 §3.13)'
      check '^/(bin|sbin|lib|lib64)/'       'install into /usr/* — the root dirs are symlinks on merged-/usr systems'
      check '^/usr/local/'                  '/usr/local is reserved for the local administrator, not for packages (FHS 3.0 §4.9)'
      check '^/(tmp|var/tmp|run)/'          'packages must not ship files into volatile directories; use tmpfiles.d'
      check '^/srv/'                        '/srv is site-specific; packages must not claim paths there'

      # SUID/SGID must be explicitly allow-listed.
      rpm -qplv "$RPM" | awk '$1 ~ /^-..[sS]/ || $1 ~ /^-.....[sS]/ { print $NF }' > /tmp/suid.txt
      if [ -s /tmp/suid.txt ]; then
        while read -r p; do
          grep -qxF "$p" packaging/allowed-suid.txt || {
            printf 'FHS VIOLATION: unapproved SUID/SGID file: %s\n' "$p" >&2
            fail=1
          }
        done < /tmp/suid.txt
      fi

      # Every shipped executable must have a man page.
      rpm -qlp "$RPM" | grep -E '^/usr/(bin|sbin)/' | while read -r bin; do
        base=$(basename "$bin")
        rpm -qlp "$RPM" | grep -qE "^/usr/share/man/man[0-9]/${base}\.[0-9]" \
          || printf 'WARNING: %s ships without a man page\n' "$base" >&2
      done

      exit "$fail"
```

```
$ gitlab-runner exec docker policy:fhs
Auditing payload of rpmbuild/RPMS/x86_64/telemetry-agent-2.4.1-1.fc44.x86_64.rpm
FHS VIOLATION: /opt packages must use /etc/opt and /var/opt (FHS 3.0 §3.13)
    /opt/telemetry-agent/etc/agent.yaml
    /opt/telemetry-agent/log
ERROR: Job failed: exit code 1
```

The outage from §6.1 is now impossible to reintroduce.

---

## 7. Verification and failure diagnosis

### 7.1 Symptom → cause → command

| Symptom | Most likely cause | Diagnostic command |
|---|---|---|
| `find: paths must precede expression` | Unquoted glob expanded by the shell | Quote the pattern: `find . -name '*.log'` |
| `find` returns nothing under a merged-`/usr` root dir | `/bin` is a symlink; `find` does not follow it by default | `find -H /bin ...` or use `/usr/bin` |
| `find /` takes minutes and hammers the SAN | Descending into NFS/container storage | Add `-xdev` and `-prune` the known trees |
| `-delete` removed more than intended | Missing `\( ... \)` around an `-o` chain, or `-delete` placed first | Re-run with `-print` in place of `-delete` |
| `xargs: argument line too long` | Not using `-print0`/`-n` | `find ... -print0 \| xargs -0 -n 100 ...` |
| `xargs` runs the command once with no input | Missing `-r` | Add `-r` / `--no-run-if-empty` |
| Filenames with spaces split into pieces | `find \| xargs` without `-print0`/`-0` | `find -print0 \| xargs -0` |
| `locate` prints a file that does not exist | Stale database | `locate -e PATTERN`; `stat -c %y /var/lib/plocate/plocate.db`; `sudo updatedb` |
| `locate` does not find a file you just created | Database predates the file | Use `find`, or `sudo updatedb` first |
| `locate` finds nothing anywhere | Database missing or timer disabled | `systemctl list-timers '*updatedb*'`; `sudo updatedb` |
| Two users get different `locate` results | Correct behaviour — per-user visibility filtering | `sudo locate PATTERN` to see everything |
| `locate` misses `/home` entirely | `/home` in `PRUNEPATHS`, or on a `PRUNEFS` type | `grep -E 'PRUNE' /etc/updatedb.conf`; `findmnt -no FSTYPE /home` |
| `which` finds it, running it fails `No such file` | Stale bash hash entry | `type CMD`; `hash -r` |
| Command works interactively, fails in `cron`/systemd | Different `$PATH`; alias or function only in `.bashrc` | `type -a CMD`; `systemctl show -p Environment UNIT` |
| `which` returns nothing for `cd`, `echo`, `[` | They are shell builtins; `which` cannot see builtins | `type -a cd` |
| Script's `which` check passes but the command misbehaves | An alias/function shadows the binary in the caller's shell | Use `command -v` and `command CMD` |
| `whereis` cannot find a binary in `/opt` | `whereis` searches only compiled-in dirs + `$PATH` | `whereis -l`; fall back to `find`/`locate` |
| `find: '-execdir': ... insecure ... $PATH` | `$PATH` contains `.` or an empty element | `printf '%s\n' "$PATH" \| tr ':' '\n' \| grep -n '^\.\?$'` |
| Daemon fails to start on a read-only-`/usr` host | Writing to a static hierarchy | `sudo find /usr -xdev -newermt '-1 hour'`; add `StateDirectory=` |
| `df` says full, `du` says half empty | Deleted files still held open | `sudo lsof -nP +L1 /` |
| `ENOSPC` with free space showing | Inode exhaustion | `df -i`; `find <fs> -xdev -printf '%h\n' \| sort \| uniq -c \| sort -rn` |
| Cleanup by `-atime` deletes hot files | Mount is `noatime`/`relatime` | `findmnt -no OPTIONS <mount>`; switch to `-mtime` |
| `find -mtime +1` misses yesterday's files | Truncation: `+1` means ≥ 2 days | Use `-newermt '-1 day'` |
| `find -size -1M` matches only empty files | Sizes round **up** | Use `-size -1048576c` |

### 7.2 The verification ladder

Never assert a path exists — prove it, and know which rung of the ladder your proof stands on.

| Question | Command | Cost | Proves |
|---|---|---|---|
| Will this command name run? | `type -a CMD` | free, no fork | Exactly what the shell resolves |
| Is a binary of this name on `$PATH`? | `command -v CMD` | free | Portable existence check |
| Where is its documentation? | `whereis -m CMD` | ~ms | Man/info page location |
| Might it exist anywhere on disk? | `locate -e -b CMD` | ~ms | Existed at last `updatedb`, still exists now |
| Does it exist right now, matching these criteria? | `find / -xdev ... -print -quit` | seconds–minutes | Ground truth |
| Is it the file the package shipped? | `rpm -Vf PATH` / `debsums -c` | seconds | Integrity against the vendor manifest |
| Is the path what it claims after symlinks? | `readlink -f PATH` / `realpath PATH` | free | Canonical path |
| What exactly is this file? | `stat PATH`, `file PATH` | free | Inode metadata, content type |

```
$ readlink -f /bin/sh
/usr/bin/bash

$ stat /etc/opt/telemetry-agent/agent.yaml
  File: /etc/opt/telemetry-agent/agent.yaml
  Size: 2417      	Blocks: 8          IO Block: 4096   regular file
Device: 253,0	Inode: 1182904     Links: 1
Access: (0640/-rw-r-----)  Uid: (    0/    root)   Gid: (  982/telemetry)
Context: system_u:object_r:etc_t:s0
Access: 2026-08-26 09:41:03.114882014 +0200
Modify: 2026-08-26 09:41:02.998881901 +0200
Change: 2026-08-26 09:41:03.002881905 +0200
 Birth: 2026-08-26 09:41:02.998881901 +0200

$ rpm -Vf /usr/bin/kubectl
S.5....T.    /usr/bin/kubectl
```

That last line is a finding, not a formality: the on-disk `kubectl` does not match what the package installed.

### 7.3 Exam traps worth rehearsing

1. `-mtime +1` means **at least two days** old, not "more than yesterday".
2. `-size -1M` matches **only empty files**, because sizes round up.
3. Without `-print0`/`-0`, `find | xargs` breaks on spaces.
4. `-o` binds looser than the implicit `-a`; the implicit `-print` attaches to the **whole expression only if no action is present**.
5. `which` is an external program: it cannot see aliases, functions, builtins or keywords.
6. `type` and `command -v` are shell builtins and *are* authoritative.
7. `locate` reads a database, not the filesystem; `-e` filters out entries that no longer exist.
8. `updatedb` reads `/etc/updatedb.conf`; both `mlocate` and `plocate` use that same file.
9. `PRUNEPATHS` takes absolute paths, `PRUNENAMES` takes basenames, `PRUNEFS` takes filesystem **types** — and none of them accept wildcards.
10. `/etc` must never contain binaries; `/var/lib` holds state you must back up, `/var/cache` holds data you may delete.
11. `/tmp` may be cleared on reboot; `/var/tmp` must survive it.
12. `/run` replaced `/var/run` and `/var/lock` in FHS 3.0.
13. `/media` is for removable media; `/mnt` is the administrator's temporary mount point.
14. `/opt/<pkg>` pairs with `/etc/opt/<pkg>` and `/var/opt/<pkg>`.
15. `-prune` is meaningless with `-depth`, and `-delete` implies `-depth`.
16. `whereis -u` lists entries missing a binary, source or man page.

---

## 8. Referencias

**Certification objectives**
- LPI, *Exam 101-500 Objectives (Version 5.0)* — Topic 104.7: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI, *LPIC-1 Certification Overview*: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Filesystem Hierarchy Standard**
- Linux Foundation, *Filesystem Hierarchy Standard 3.0* (2015-06-03): <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- FHS specification index and prior versions: <https://refspecs.linuxfoundation.org/fhs.shtml>
- freedesktop.org, `file-hierarchy(7)` — systemd's FHS-compatible view: <https://www.freedesktop.org/software/systemd/man/latest/file-hierarchy.html>
- freedesktop.org, *XDG Base Directory Specification*: <https://specifications.freedesktop.org/basedir-spec/latest/>
- Debian Policy Manual, Chapter 9 — *The Operating System*: <https://www.debian.org/doc/debian-policy/ch-opersys.html>
- Fedora Packaging Guidelines — *File and Directory Ownership*: <https://docs.fedoraproject.org/en-US/packaging-guidelines/>
- Fedora Project, *UsrMove feature*: <https://fedoraproject.org/wiki/Features/UsrMove>
- Debian Wiki, *UsrMerge*: <https://wiki.debian.org/UsrMerge>

**`find`, `xargs` and findutils**
- GNU, *Finding Files: GNU findutils manual*: <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- `find(1)` — Linux man-pages project: <https://man7.org/linux/man-pages/man1/find.1.html>
- `xargs(1)`: <https://man7.org/linux/man-pages/man1/xargs.1.html>
- The Open Group, POSIX.1-2017 `find`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html>
- The Open Group, POSIX.1-2017 `xargs`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/xargs.html>

**`locate` / `updatedb`**
- `plocate` upstream project: <https://plocate.sesse.net/>
- `mlocate` upstream project: <https://pagure.io/mlocate>
- `locate(1)`: <https://man7.org/linux/man-pages/man1/locate.1.html>
- `updatedb(8)`: <https://man7.org/linux/man-pages/man8/updatedb.8.html>
- `updatedb.conf(5)`: <https://man7.org/linux/man-pages/man5/updatedb.conf.5.html>

**Command lookup and the shell**
- GNU, *Bash Reference Manual* — Command Search and Execution: <https://www.gnu.org/software/bash/manual/bash.html#Command-Search-and-Execution>
- GNU, *Bash Reference Manual* — Bourne Shell Builtins (`hash`, `type`, `command`): <https://www.gnu.org/software/bash/manual/bash.html#Bourne-Shell-Builtins>
- The Open Group, POSIX.1-2017 `type`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/type.html>
- The Open Group, POSIX.1-2017 `command`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/command.html>
- `which(1)`: <https://man7.org/linux/man-pages/man1/which.1.html>
- `whereis(1)` — util-linux: <https://man7.org/linux/man-pages/man1/whereis.1.html>
- util-linux upstream documentation: <https://github.com/util-linux/util-linux/blob/master/Documentation/>

**systemd path and sandboxing directives**
- `systemd.exec(5)` — `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=`, `ConfigurationDirectory=`, `RuntimeDirectory=`, `ProtectSystem=`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- `tmpfiles.d(5)`: <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>
- `systemd-path(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-path.html>
- `systemd-analyze(1)` — `security` and `calendar` verbs: <https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html>
- `systemd.timer(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html>

**Kubernetes and infrastructure references**
- Kubernetes, *DaemonSet*: <https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/>
- Kubernetes, *CronJob*: <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/>
- Kubernetes, *Pod Security Standards*: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Ansible, `ansible.builtin.file` module: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html>
- Ansible, `ansible.builtin.systemd_service` module: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html>

**Package verification**
- `rpm(8)` — verify mode: <https://man7.org/linux/man-pages/man8/rpm.8.html>
- `debsums(1)`: <https://manpages.debian.org/stable/debsums/debsums.1.en.html>
- `dpkg-query(1)`: <https://man7.org/linux/man-pages/man1/dpkg-query.1.html>