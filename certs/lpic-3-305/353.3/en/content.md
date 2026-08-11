# Topic 353.3: cloud-init

> **Certification:** LPIC-3 Virtualization and Containerization (Exam 305-300, v3.0)
> **Objective weight:** 5
> **Scope:** cloud-init concepts, datasources, boot stages, user-data / meta-data / vendor-data, `cloud-config`, filesystem and account provisioning, package installation, `growpart`, the NoCloud and config-drive datasources, and image integration.

---

## 1. The architectural problem: late-binding a generic image

A production fleet cannot afford one golden image per role. If you bake `web-nginx-eu-west`, `web-nginx-us-east`, `db-primary`, `db-replica`, and a hundred combinations of hostname, SSH trust, disk layout and package set into distinct images, you inherit a combinatorial build matrix, a slow release cadence, and drift the moment any single fact changes. The opposite extreme — a bare distro image plus a post-boot configuration-management run — pays a full converge cycle on every launch and depends on the network, a control plane, and secrets being reachable *before* the node is even usable.

cloud-init is the industry-standard **late-binding specialization layer** that sits between those two. You publish **one** generic, cleaned image. At first boot, the platform hands the instance a small, per-instance payload (identity, credentials, disk intents, a package list), and cloud-init applies it *before* SSH is offered and before any orchestrator touches the node. The image stays immutable and reusable; the specialization is data, not a rebuild.

The contract has three inputs and one guarantee:

| Input | Author | Mutable per boot? | Typical content |
|---|---|---|---|
| **meta-data** | The platform / operator | Fixed per instance | `instance-id`, `local-hostname`, network, placement (region/AZ) |
| **user-data** | The end user / operator | Fixed per instance | `#cloud-config` or a script — *what the user wants done* |
| **vendor-data** | The cloud provider | Fixed per instance | Provider defaults, agents, mirrors — user-overridable |

**The guarantee:** work keyed to a given `instance-id` runs **exactly once**. cloud-init records the `instance-id` under `/var/lib/cloud/instances/<id>/`. On the next boot, if the id is unchanged, per-instance modules are skipped; if the datasource reports a *new* id (a clone, a re-provision), they run again. This idempotency is the whole reason a snapshot of a running node re-personalizes correctly instead of colliding with its parent.

### Where cloud-init is the wrong tool

cloud-init is **first-boot instance initialization**, not ongoing configuration management. It is not a convergence loop — it does not detect drift, does not re-apply on a schedule, and its per-instance semantics mean editing `user-data` on a running node changes nothing until the id changes. Use it to bring a node to a known baseline and to hand off to Ansible/Puppet/Salt (or to a container runtime); do not use it as a substitute for them.

| Approach | First-boot latency | Immutable image | Per-instance data | Drift management | Cross-platform |
|---|---|---|---|---|---|
| **N golden images** | Lowest | ❌ (that's the point) | Baked in | ❌ | ❌ (rebuild per cloud) |
| **cloud-init** | Low (one boot) | ✅ | ✅ (datasource) | ❌ (not its job) | ✅ (broad datasource support) |
| **Ignition (CoreOS/FCOS)** | Low (initramfs) | ✅ | ✅ | ❌ | Narrow (FCOS/RHCOS) |
| **Config mgmt pull (Ansible/Puppet)** | High (full converge) | ✅ | ✅ | ✅ | ✅ |
| **Hand-rolled first-boot script** | Low | ✅ | ⚠️ ad-hoc | ❌ | ❌ (you reinvent datasources) |

> **Ignition vs cloud-init** is the exam-relevant contrast: Ignition runs *once*, early in the initramfs, before the root pivot, cannot run on later boots, and only writes files/units/disks (no package installs, no ongoing agents). cloud-init runs in the booted system across several stages and has a rich module set. Different philosophies: Ignition is deliberately minimal and one-shot; cloud-init is a staged provisioning engine.

---

## 2. Internal architecture

### 2.1 Boot stages

cloud-init is not a single service. A systemd **generator** decides at boot whether cloud-init should run at all (checking `/etc/cloud/cloud-init.disabled`, the kernel command line `cloud-init=disabled`, and datasource hints), and if so wires four ordered units into the boot. Understanding *which stage a given piece of config runs in* is the single most useful mental model for debugging.

| Stage | systemd unit | CLI equivalent | Network up? | Runs |
|---|---|---|---|---|
| **Generator** | `cloud-init-generator` | — | n/a | Enables/disables the whole pipeline; writes `cloud-init.target` |
| **Local** | `cloud-init-local.service` | `cloud-init init --local` | **No** | Finds a *local* datasource; applies network config so networking can come up correctly |
| **Network** | `cloud-init.service` (a.k.a. `cloud-init-network.service`) | `cloud-init init` | **Yes** | Finds network datasources; processes user-data; runs `bootcmd`, `write_files`, `growpart`, `resizefs`, `disk_setup`, `mounts`, users, SSH keys |
| **Config** | `cloud-config.service` | `cloud-init modules --mode=config` | Yes | `runcmd` staging, `ntp`, `timezone`, `locale`, `set-passwords`, `apt`/`yum` config |
| **Final** | `cloud-final.service` | `cloud-init modules --mode=final` | Yes | Package install/upgrade, `runcmd` execution, user scripts, `phone_home`, `final_message`, `power_state_change` |

The critical ordering fact: **network configuration is decided in the Local stage, before the network exists.** That is why a broken `network-config` bricks a node into an unreachable state that no later stage can fix — the failure precedes SSH.

The module-to-stage mapping lives in `/etc/cloud/cloud.cfg` under three keys — `cloud_init_modules`, `cloud_config_modules`, `cloud_final_modules` — and this is editable. Moving a module between lists moves *when* it runs.

### 2.2 Datasources

A **datasource** is the platform-specific adapter that locates and reads the meta-data/user-data/vendor-data. cloud-init probes a candidate list (`datasource_list`) and picks the first that reports data. On known clouds detection is automatic via SMBIOS/DMI, metadata endpoints, or disk labels.

| Datasource | Discovery mechanism | Metadata source | Primary use |
|---|---|---|---|
| **EC2** | DMI / IMDS `169.254.169.254` | HTTP metadata service | AWS and EC2-compatible |
| **Azure** | DMI + IMDS + reprovision protocol | HTTP + OVF in a disk | Microsoft Azure |
| **GCE** | DMI + metadata server | HTTP metadata service | Google Cloud |
| **OpenStack** | DMI + IMDS | HTTP metadata service | OpenStack clouds |
| **ConfigDrive** | Disk labeled `config-2` | Files on an attached ISO/disk | OpenStack **without** a metadata network; offline testing |
| **NoCloud** | Disk labeled `cidata`/`CIDATA`, seed dir, or `ds=nocloud` on cmdline | Plain files (`user-data`, `meta-data`, `network-config`) | Bare metal, libvirt/KVM, homelab, CI, image testing |
| **OVF** | VMware guestinfo / OVF environment | XML properties | VMware / vSphere |
| **None** | Fallback | — | No datasource; applies defaults only |

Constrain probing in the image with an explicit list — it speeds boot and prevents a hang waiting for a metadata endpoint that will never answer:

```yaml
# /etc/cloud/cloud.cfg.d/90_datasource.cfg
datasource_list: [ NoCloud, ConfigDrive, None ]
```

### 2.3 user-data formats

`user-data` is dispatched by its first line. Getting this wrong is the most common cause of "cloud-init did nothing."

| First line / magic | Format | Behavior |
|---|---|---|
| `#cloud-config` | **cloud-config** (YAML) | Declarative; consumed by modules. The main path. |
| `#!` (e.g. `#!/bin/bash`) | **User-data script** | Executed verbatim in the Final stage, once per instance |
| `#cloud-boothook` | Boot hook | Executed **very early, every boot** (you must guard idempotency yourself) |
| `#include` | Include file | Each line is a URL whose body is fetched and processed as user-data |
| `Content-Type: multipart/mixed` | **MIME multipart** | Combine several of the above in one payload |
| `#part-handler` | Part handler | Register a handler for a custom MIME type |
| *(gzip magic bytes)* | Compressed | Any of the above, gzip-compressed (metadata size limits) |

### 2.4 Instance data and Jinja templating

Everything the datasource learned is normalized into `/run/cloud-init/instance-data.json`, with vendor-agnostic keys under `v1` (`v1.cloud_name`, `v1.region`, `v1.instance_id`, `v1.local_hostname`, …) and raw datasource keys under `ds`. Any `#cloud-config` or script may begin with `## template: jinja` and reference these keys, so one payload adapts to placement without editing:

```yaml
## template: jinja
#cloud-config
hostname: {{ v1.local_hostname }}
fqdn: {{ v1.local_hostname }}.{{ v1.region | default("local") }}.example.internal
runcmd:
  - echo "Booted on {{ v1.cloud_name }} in {{ v1.availability_zone }}" > /etc/motd.d/50-placement
```

---

## 3. Complete, syntactically valid manifests

### 3.1 A production `#cloud-config`

This is a single, complete payload exercising the objective's required capabilities: users with SSH keys, `write_files`, package installation, a full disk lifecycle (`disk_setup` → `fs_setup` → `mounts`), root filesystem growth (`growpart`/`resizefs`), NTP, CA certificates, and ordered commands. Every block is valid and non-truncated.

```yaml
#cloud-config
# ---------------------------------------------------------------------------
# Base identity
# ---------------------------------------------------------------------------
hostname: app-node
fqdn: app-node.svc.example.internal
prefer_fqdn_over_hostname: true
manage_etc_hosts: true

# ---------------------------------------------------------------------------
# Accounts and SSH trust
#   - lock the default distro user; create an operator with sudo + a key
#   - no password auth on the wire
# ---------------------------------------------------------------------------
ssh_pwauth: false
disable_root: true
users:
  - name: sre
    gecos: Site Reliability Engineer
    groups: [sudo, adm]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIObExampleKeyReplaceMe sre@bastion

# Deterministic host keys are generated per-instance; do NOT bake them into the image
ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]

# ---------------------------------------------------------------------------
# Files written before services start (Network stage)
# ---------------------------------------------------------------------------
write_files:
  - path: /etc/sysctl.d/80-fleet.conf
    owner: root:root
    permissions: "0644"
    content: |
      net.core.somaxconn = 4096
      vm.swappiness = 10
  - path: /etc/app/config.yaml
    owner: root:root
    permissions: "0640"
    content: |
      listen: 0.0.0.0:8080
      log_level: info
  # base64 payload example (binary-safe)
  - path: /usr/local/bin/healthcheck.sh
    owner: root:root
    permissions: "0755"
    encoding: b64
    content: IyEvYmluL2Jhc2gKY3VybCAtc2YgaHR0cDovL2xvY2FsaG9zdDo4MDgwL2hlYWx0aHogfHwgZXhpdCAxCg==

# ---------------------------------------------------------------------------
# Time sync (config stage) — chrony, explicit servers
# ---------------------------------------------------------------------------
ntp:
  enabled: true
  ntp_client: chrony
  servers:
    - 0.pool.ntp.org
    - 1.pool.ntp.org

# ---------------------------------------------------------------------------
# Trust store — add an internal CA
# ---------------------------------------------------------------------------
ca_certs:
  remove_defaults: false
  trusted:
    - |
      -----BEGIN CERTIFICATE-----
      MIIB...internal-ca-in-full...IDAQAB
      -----END CERTIFICATE-----

# ---------------------------------------------------------------------------
# Storage lifecycle on the second disk (/dev/sdb)
#   partition -> format -> mount ; survives reboots via nofail
# ---------------------------------------------------------------------------
disk_setup:
  /dev/sdb:
    table_type: gpt
    layout: true          # single partition spanning the disk
    overwrite: false      # NEVER re-partition a disk that already has a table

fs_setup:
  - label: appdata
    filesystem: ext4
    device: /dev/sdb
    partition: auto
    overwrite: false

mounts:
  - [ "LABEL=appdata", "/var/lib/app", "ext4", "defaults,nofail,x-systemd.growfs", "0", "2" ]

# ---------------------------------------------------------------------------
# Grow the ROOT filesystem to fill the (possibly resized) root disk
# ---------------------------------------------------------------------------
growpart:
  mode: auto
  devices: ["/"]
  ignore_growroot_disabled: false
resize_rootfs: true

# ---------------------------------------------------------------------------
# Packages from the distro repositories
# ---------------------------------------------------------------------------
package_update: true
package_upgrade: false      # deliberate: pin upgrades to a controlled channel
packages:
  - nginx
  - jq
  - htop

# ---------------------------------------------------------------------------
# bootcmd  : very early, EVERY boot     (guard your own idempotency)
# runcmd   : Final stage, once per instance, in order
# ---------------------------------------------------------------------------
bootcmd:
  - [ cloud-init-per, once, disable-thp, sh, -c, "echo never > /sys/kernel/mm/transparent_hugepage/enabled" ]

runcmd:
  - [ systemctl, enable, --now, nginx ]
  - [ sh, -c, "install -d -m 0750 -o root -g adm /var/lib/app/data" ]
  - [ /usr/local/bin/healthcheck.sh ]

# ---------------------------------------------------------------------------
# Completion signalling and optional power state
# ---------------------------------------------------------------------------
final_message: "cloud-init done: $INSTANCE_ID up after $UPTIME s (version $VERSION)"
# power_state:
#   mode: reboot
#   condition: test -f /var/run/reboot-required
#   timeout: 30
#   message: Rebooting to apply kernel/initramfs changes
```

**Note on `disk_setup` safety:** `overwrite: false` is not decoration. With `overwrite: true`, cloud-init will *repartition and reformat a disk that already holds data* — on a re-run against a real datasource this destroys volumes. The `nofail` mount option is equally load-bearing: without it, a missing/renamed data disk drops the boot into emergency mode.

### 3.2 The NoCloud datasource — a complete seed for KVM/libvirt and image testing

NoCloud is the datasource you use on bare metal, in a homelab, in CI, and to test an image *without* any cloud. It reads three plain files. You deliver them via a small ISO labeled `cidata`.

**`meta-data`** (YAML/JSON; the `instance-id` is what drives once-per-instance semantics):

```yaml
instance-id: app-node-0001
local-hostname: app-node
```

**`user-data`** — reuse the full `#cloud-config` from §3.1.

**`network-config`** (v2, netplan-style) — static addressing decided in the Local stage:

```yaml
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:12:34:56"
    set-name: eth0
    addresses: [10.20.30.11/24]
    routes:
      - to: default
        via: 10.20.30.1
    nameservers:
      addresses: [10.20.30.2, 1.1.1.1]
      search: [svc.example.internal]
```

**Build the seed ISO** — two equivalent routes:

```console
$ ls
meta-data  network-config  user-data

# Route A: cloud-localds (from the cloud-image-utils / cloud-utils package)
$ cloud-localds --network-config=network-config seed.img user-data meta-data
$ file seed.img
seed.img: ISO 9660 CD-ROM filesystem data 'cidata'

# Route B: build the labeled ISO by hand (genisoimage or mkisofs / xorriso)
$ genisoimage -output seed.iso -volid cidata -joliet -rock \
      user-data meta-data network-config
I: -input-charset not specified, using utf-8 (detected in locale settings)
Total translation table size: 0
Total rockridge attributes bytes: 1543
Total directory bytes: 0
Path table size(bytes): 10
Max brk space used 0
183 extents written (0 MB)
```

**Boot a KVM guest against a cleaned base image + the seed:**

```console
$ qemu-img create -f qcow2 -F qcow2 -b debian-12-generic.qcow2 app-node.qcow2 20G
Formatting 'app-node.qcow2', fmt=qcow2 cluster_size=65536 ... backing_file=debian-12-generic.qcow2

$ virt-install --name app-node --memory 2048 --vcpus 2 \
    --disk path=app-node.qcow2,device=disk,bus=virtio \
    --disk path=seed.iso,device=cdrom \
    --os-variant debian12 --import --graphics none --noautoconsole
Starting install...
Domain creation completed.
```

Alternative discovery mechanisms (no ISO needed):

- **Seed directory inside the image:** drop the files in `/var/lib/cloud/seed/nocloud/` (Local stage) or `/var/lib/cloud/seed/nocloud-net/` (Network stage).
- **Kernel command line:** `ds=nocloud;s=http://10.0.0.5/seed/` (or `ds=nocloud-net;s=...`) to fetch `meta-data`/`user-data` over HTTP.

### 3.3 The config-drive datasource — offline testing of OpenStack semantics

Config drive is OpenStack's no-metadata-network path and a clean way to exercise the same code path as a real cloud offline. The disk is labeled **`config-2`** and carries a JSON tree.

```console
$ mkdir -p cfgdrive/openstack/latest
$ cat > cfgdrive/openstack/latest/meta_data.json <<'EOF'
{
  "uuid": "app-node-0001",
  "hostname": "app-node",
  "name": "app-node",
  "public_keys": { "operator": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIObExampleKey operator@bastion" }
}
EOF
$ cp user-data cfgdrive/openstack/latest/user_data

$ genisoimage -output config.iso -volid config-2 -joliet -rock cfgdrive
...
$ blkid config.iso
config.iso: UUID="2026-08-11-00-00-00-00" LABEL="config-2" TYPE="iso9660"
```

Attach `config.iso` as a CD-ROM exactly as with the NoCloud seed; cloud-init detects the `config-2` label and consumes it via the ConfigDrive datasource.

### 3.4 MIME multipart — combining a boothook, a cloud-config and a script

When one payload must carry heterogeneous parts, use the helper rather than assembling MIME by hand:

```console
$ cloud-init devel make-mime \
    -a boothook.sh:cloud-boothook \
    -a base.yaml:cloud-config \
    -a bootstrap.sh:x-shellscript > user-data
$ head -5 user-data
Content-Type: multipart/mixed; boundary="===============1234567890=="
MIME-Version: 1.0

--===============1234567890==
Content-Type: text/cloud-boothook; charset="us-ascii"
```

### 3.5 Integrating cloud-init into an image

The requirement for a reusable image is that it carry **no instance identity**. Install cloud-init, drop a datasource-restricting drop-in, then *clean* so the next boot is treated as first boot:

```console
# inside the image (chroot, virt-customize, or a live build VM)
$ apt-get install -y cloud-init
$ printf 'datasource_list: [ NoCloud, ConfigDrive, None ]\n' \
    > /etc/cloud/cloud.cfg.d/90_datasource.cfg

# Remove instance state, SSH host keys, and logs so the image is generic
$ cloud-init clean --logs --machine-id --seed
$ rm -f /etc/ssh/ssh_host_*
$ truncate -s 0 /etc/machine-id      # regenerated per boot
$ shutdown -h now
```

`cloud-init clean` deletes `/var/lib/cloud/`, so the persisted `instance-id` is gone and every per-instance module fires again on the next real boot. This is the step that turns a configured VM back into a template.

---

## 4. CLI: commands and real terminal output

### 4.1 Status — the first thing you ever run

`--wait` blocks until cloud-init reaches a terminal state; script your provisioning gates on it rather than on `sleep`.

```console
$ cloud-init status --wait --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Tue, 11 Aug 2026 14:03:21 +0000
detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]
errors: []
recoverable_errors: {}
```

Machine-readable form for a health gate — note the distinction between `status` (`done`) and `extended_status`, which surfaces `degraded done` when recoverable errors occurred:

```console
$ cloud-init status --format json
{
 "boot_status_code": "enabled-by-generator",
 "datasource": "nocloud",
 "detail": "DataSourceNoCloud [seed=/dev/sr0][dsmode=net]",
 "errors": [],
 "extended_status": "done",
 "last_update": "Tue, 11 Aug 2026 14:03:21 +0000",
 "recoverable_errors": {},
 "status": "done"
}

$ echo $?
0
```

`cloud-init status` exit codes: `0` = done, `1` = error, `2` = recoverable error (degraded), plus not-run/disabled states — usable directly in a pipeline.

Which datasource won?

```console
$ cloud-id
nocloud
```

### 4.2 Query the instance data

```console
$ cloud-init query --list-keys
availability_zone
base64_encoded_keys
cloud_name
ds
merged_cfg
platform
region
sensitive_keys
subplatform
userdata
v1
vendordata

$ cloud-init query v1.local_hostname
app-node

$ cloud-init query ds.meta_data.instance_id
app-node-0001

$ cloud-init query --format 'name={{ v1.cloud_name }} host={{ v1.local_hostname }}'
name=nocloud host=app-node

# The raw user-data as cloud-init received it
$ sudo cloud-init query userdata | head -3
#cloud-config
hostname: app-node
fqdn: app-node.svc.example.internal
```

### 4.3 Validate `cloud-config` **before** you boot

Schema validation is free and catches the majority of "silent no-op" payloads. Do it in CI on every change.

```console
$ cloud-init schema --config-file user-data --annotate
Valid schema user-data
```

A deliberately broken payload — `--annotate` points at the offending line:

```console
$ cloud-init schema --config-file bad.yaml --annotate
#cloud-config
packages: nginx		# E1
runcmd:
  - echo hi		# E2

# Errors: -------------
# E1: 'nginx' is not of type 'array'
# E2: Cloud config schema errors: runcmd.0: 'echo hi' is not of type 'array'
```

Validate the running system's merged config:

```console
$ sudo cloud-init schema --system
Valid schema user-data
```

### 4.4 Timing analysis — `cloud-init analyze`

Where did boot time go? `blame` sorts modules by wall-clock cost — the first place to look when first boot is slow.

```console
$ cloud-init analyze blame
-- Boot Record 01 --
     08.4032100s (modules-final/config-package-update-upgrade-install)
     01.2204000s (init-network/config-growpart)
     00.5310400s (init-network/config-resizefs)
     00.2410900s (modules-config/config-ntp)
     00.1042300s (init-network/config-ssh)
     00.0421700s (init-network/config-write-files)
1 boot records analyzed
```

`show` is the ordered event timeline per stage:

```console
$ cloud-init analyze show
-- Boot Record 01 --
The total time elapsed since completing an event is printed after the "@" character.
The time the event takes is printed after the "+" character.

Starting stage: init-local
|`->no cache found @00.003s +00.000s
|`->found local data from DataSourceNoCloud @00.006s +00.152s
Finished stage: (init-local) 00.201 seconds

Starting stage: init-network
|`->restored from cache with run check: DataSourceNoCloud @00.520s +00.040s
|`->config-growpart ran successfully @01.100s +01.220s
|`->config-resizefs ran successfully @02.320s +00.531s
Finished stage: (init-network) 02.900 seconds
...
```

`boot` separates kernel time from cloud-init activation — useful when you must prove whether slowness is cloud-init or the platform handing over late:

```console
$ cloud-init analyze boot
-- Most Recent Boot Record --
    Kernel Started at: 2026-08-11 14:03:00.123456
    Kernel ended boot at: 2026-08-11 14:03:03.456789
    Kernel time to boot (seconds): 3.333333
    Cloud-init activated by systemd at: 2026-08-11 14:03:04.000000
    Time between Kernel end boot and Cloud-init activation (seconds): 0.543211
    Cloud-init start: 2026-08-11 14:03:04.100000
```

---

## 5. Verification and failure diagnosis

### 5.1 The evidence trail

| Artifact | Purpose |
|---|---|
| `/var/log/cloud-init.log` | The full internal log — module dispatch, datasource probing, tracebacks |
| `/var/log/cloud-init-output.log` | **stdout/stderr of `runcmd`, `bootcmd`, package installs, scripts** — where your commands' output actually lands |
| `/run/cloud-init/status.json` | Per-stage status and errors (source of `cloud-init status`) |
| `/run/cloud-init/result.json` | Final datasource + errors list |
| `/run/cloud-init/instance-data.json` | Normalized metadata (source of `cloud-init query`) |
| `/var/lib/cloud/instance/` | Symlink to the current instance's state dir; per-instance "already ran" markers |
| `/run/cloud-init/cloud-init-generator.log` | Why the pipeline was enabled/disabled |

### 5.2 A methodical triage

```console
# 1. Terminal state and datasource
$ cloud-init status --long
status: error
extended_status: error
detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]
errors:
 - 'Failed to run module package-update-upgrade-install ...'

# 2. Extract just the errors and warnings from the log
$ sudo grep -E 'WARNING|ERROR|Traceback' /var/log/cloud-init.log | tail -20
2026-08-11 14:03:12,455 - cc_package_update_upgrade_install.py[WARNING]: 1 failed with exceptions, ...
2026-08-11 14:03:12,455 - util.py[WARNING]: Package upgrade failed: E: Unable to locate package ngnix

# 3. See the actual command/stdout that failed
$ sudo tail -30 /var/log/cloud-init-output.log
E: Unable to locate package ngnix        # <- typo in `packages:`

# 4. Confirm the datasource actually delivered your user-data
$ sudo cloud-init query userdata | head -1
#cloud-config
```

### 5.3 Common failure modes

| Symptom | Likely cause | Diagnosis / fix |
|---|---|---|
| "cloud-init did nothing" | `user-data` missing the `#cloud-config` first line, or first line indented | `cloud-init query userdata`; the magic line must be column 0 |
| Config ignored, no error | Invalid schema silently skipped | `cloud-init schema --config-file …` **before** boot |
| Node unreachable after boot | Broken `network-config` (applied in Local stage, before SSH) | Console access only; check `/var/log/cloud-init.log` for network apply |
| Package install fails | Typo in `packages:`, or repos not yet reachable | `cloud-init-output.log`; ensure mirrors resolvable at Final stage |
| Data disk breaks boot | `mounts` entry without `nofail` and disk absent/renamed | Add `nofail`; use `LABEL=`/`UUID=`, never volatile `/dev/sdX` |
| Changes to user-data have no effect on a running node | Same `instance-id` → per-instance modules skipped by design | Change the id, or `cloud-init clean --logs` then reboot |
| Second boot re-partitions a disk | `disk_setup … overwrite: true` | Set `overwrite: false`; it is destructive on re-run |

### 5.4 Re-running for iteration (test/image prep only)

Force a full re-run as if first boot — the correct way to iterate on a payload in a throwaway VM:

```console
$ sudo cloud-init clean --logs --reboot
```

Re-run a **single** module against live user-data without a reboot, to bisect a failing block (`--frequency always` overrides once-per-instance):

```console
$ sudo cloud-init single --name cc_write_files --frequency always
$ sudo cloud-init single --name cc_runcmd --frequency always
```

> **Never** run `cloud-init clean` on a live production node you intend to keep: it discards `/var/lib/cloud/` state, and the next boot re-applies every per-instance action (re-creating users, re-running `runcmd`, potentially re-touching disks).

### 5.5 Package a support bundle

```console
$ sudo cloud-init collect-logs
Wrote /root/cloud-init.tar.gz
$ tar tzf /root/cloud-init.tar.gz | head
cloud-init-logs-2026-08-11/
cloud-init-logs-2026-08-11/cloud-init.log
cloud-init-logs-2026-08-11/cloud-init-output.log
cloud-init-logs-2026-08-11/run/cloud-init/status.json
cloud-init-logs-2026-08-11/run/cloud-init/instance-data.json
cloud-init-logs-2026-08-11/dmesg.txt
cloud-init-logs-2026-08-11/journal.txt
```

---

## References

- LPI — Exam 305-300 Objectives (Objective 353.3, cloud-init): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- cloud-init — Official documentation (home): <https://cloudinit.readthedocs.io/en/latest/>
- cloud-init — Boot stages: <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html>
- cloud-init — Datasources reference: <https://cloudinit.readthedocs.io/en/latest/reference/datasources.html>
- cloud-init — NoCloud datasource: <https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html>
- cloud-init — ConfigDrive datasource: <https://cloudinit.readthedocs.io/en/latest/reference/datasources/configdrive.html>
- cloud-init — User-data formats: <https://cloudinit.readthedocs.io/en/latest/explanation/format.html>
- cloud-init — Modules reference (all `cc_*` keys): <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>
- cloud-init — Cloud config examples: <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- cloud-init — CLI reference (`status`, `query`, `analyze`, `schema`, `clean`, `single`, `collect-logs`): <https://cloudinit.readthedocs.io/en/latest/reference/cli.html>
- cloud-init — Instance metadata (`instance-data.json`, Jinja): <https://cloudinit.readthedocs.io/en/latest/reference/instancedata.html>
- cloud-init — Network configuration (v1/v2): <https://cloudinit.readthedocs.io/en/latest/reference/network-config.html>
- cloud-init — Debugging and support: <https://cloudinit.readthedocs.io/en/latest/howto/debugging.html>