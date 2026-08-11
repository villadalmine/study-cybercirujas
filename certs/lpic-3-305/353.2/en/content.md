# 353.2 Packer

> **LPIC-3 305 · Exam 305-300 (v3.0) · Topic 353.2 — Weight: 3.33**
> Profile: Platform Architect / SRE — image-as-code for the KVM/libvirt and container fleet.

---

## 1. Motivation: the architectural problem Packer solves

In a production virtualization estate you have two ways to get from "bare distro ISO" to "a VM that runs your workload":

1. **Boot-time configuration** — spin a generic base image, then let `cloud-init`, Ansible, or a config-management agent converge it on first boot.
2. **Bake-time configuration (immutable images / golden images)** — pre-build a fully-provisioned artifact *once*, version it, and boot N identical copies with near-zero convergence work.

The first path is seductive because it needs no build pipeline, but it fails at scale in three concrete ways an SRE feels every week:

- **Boot-storm amplification.** If 200 VMs each `apt-get update && apt-get install` on boot, you multiply download volume, mirror load, and time-to-ready by 200. A boot that pulls 400 MB of packages turns a 15-second start into a 4-minute start, and every autoscaling event pays it again.
- **Non-determinism / drift.** Convergence at boot means the artifact is a *function of the upstream repository state at boot time*. Two VMs booted an hour apart from the "same" template can get different package versions. Root-cause analysis becomes archaeology.
- **No atomic rollback.** If a bad package lands, you cannot "roll back the boot script" — the damage already ran on every instance. With immutable images you redeploy `image v41` and you are done.

**Packer** (HashiCorp) is the tool that makes path 2 practical: it is a single Go binary that automates the *creation of machine images* from a source, drives a temporary VM/container through a provisioning phase, and emits one or more artifacts (a `qcow2`, an AMI, a Docker image, an OVA, a Vagrant box). It is the "compile" step of **image-as-code**: source text in → versioned binary artifact out.

Packer's design principle: **it does not manage running machines and it does not replace a provisioner.** It orchestrates a *throwaway* build machine, hands off the OS-level configuration to a provisioner (shell/Ansible), and then freezes the result. This separation is why Packer composes cleanly with Terraform (which consumes the image) and with cloud-init (which handles per-instance data at boot). Immutable *base*, mutable *instance data* — the two are not in conflict.

```
  ┌────────────┐   builder    ┌──────────────┐  provisioner  ┌──────────────┐  post-processor  ┌───────────┐
  │  source    │ ───────────▶ │ temporary VM │ ────────────▶ │  configured  │ ───────────────▶ │  artifact │
  │ (ISO/image)│   boots &     │  or container│  shell/ansible│    machine   │  compress/tag/   │ qcow2/AMI/│
  └────────────┘   connects    └──────────────┘  copy files   └──────────────┘  push/box        │  image    │
                   via SSH/WinRM                                    │ shutdown & snapshot         └───────────┘
```

---

## 2. Architecture and the plugin model

Packer's runtime is a **core** plus a set of **plugins**. Since Packer **1.7** the plugins that used to ship inside the monolith (QEMU, VirtualBox, Docker, Amazon, vSphere…) live in **separate versioned binaries** that you declare and fetch with `packer init`. This is the single most exam-relevant modernization: the community-maintained builders are no longer "built in."

Four plugin component types exist:

| Component | Role | Examples |
|---|---|---|
| **Builder** | Creates the throwaway machine and the base artifact. One per source. | `qemu`, `virtualbox-iso`, `vmware-iso`, `docker`, `amazon-ebs`, `vsphere-iso`, `lxc`, `proxmox` |
| **Provisioner** | Runs *inside* the machine to configure the OS. | `shell`, `file`, `ansible`, `ansible-local`, `powershell`, `breakpoint` |
| **Post-processor** | Transforms/ships the finished artifact. Runs *after* build. | `docker-tag`, `docker-push`, `compress`, `vagrant`, `manifest`, `shell-local`, `checksum` |
| **Data source** | Fetches external data at parse time (HCL2 only). | `amazon-ami`, `git-commit`, `http` |

### Configuration languages: HCL2 vs JSON

Packer accepts two template formats. **HCL2 is the current, recommended format** (Packer ≥ 1.7); JSON is the legacy format retained for backward compatibility. The exam expects you to read both.

| Dimension | HCL2 (`.pkr.hcl`) | JSON (`.json`) — legacy |
|---|---|---|
| Status | Recommended, actively developed | Maintained for compatibility only |
| Comments | `#`, `//`, `/* */` | None (JSON has no comments) |
| Variables | `variable`/`local` blocks, typed, validated | `variables` map, string-only |
| Expressions/functions | Full HCL functions (`templatefile`, `env`, `regex`…) | Limited `{{ }}` template engine |
| Multiple sources per build | `build { sources = [...] }` — first-class parallel builds | `builders` array | 
| `required_plugins` / `packer init` | Yes | **No** — cannot pin plugins declaratively |
| Loops / conditionals | `dynamic` blocks, `for` expressions | None |

**Trade-off summary:** JSON is only correct when you must maintain an existing template that predates 1.7 and cannot be migrated (`packer hcl2_upgrade` converts it). For anything new, HCL2 — because `required_plugins` + `packer init` is the reproducibility mechanism, and JSON literally cannot express it.

### Bake-time vs boot-time (the decision that precedes Packer)

| Criterion | Golden image (Packer) | Boot-time config (cloud-init/Ansible-pull) |
|---|---|---|
| Time-to-ready | Fast (work already done) | Slow (converge on every boot) |
| Determinism | High (frozen at build) | Low (depends on repo state at boot) |
| Rollback | Atomic (redeploy prior image) | Hard (script already ran) |
| Storage cost | Higher (many full images) | Lower (one thin base) |
| Build pipeline needed | Yes | No |
| Best for | Autoscaled fleets, regulated/repeatable builds | Rarely-booted or highly-heterogeneous hosts |

The mature answer is **both**: Packer bakes the base (kernel, packages, hardening, agent), cloud-init injects per-instance data (hostname, SSH keys, secrets) at boot. Never bake secrets or per-instance identity into the image.

---

## 3. Complete, unabridged templates

### 3.1 QEMU/KVM golden image — Debian 12, HCL2

This is the canonical LPIC-3 305 scenario: build a `qcow2` for the libvirt/KVM fleet. It uses an **autoinstall/preseed served over Packer's built-in HTTP server**, boots headless, provisions over SSH, and compresses the result.

Directory layout:

```
debian-qemu/
├── debian.pkr.hcl
├── variables.pkr.hcl
├── http/
│   └── preseed.cfg
└── scripts/
    └── provision.sh
```

`variables.pkr.hcl`:

```hcl
variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
  description = "Location of the Debian netinst ISO (local path or URL)."
}

variable "iso_checksum" {
  type        = string
  default     = "file:https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
  description = "Checksum or a checksum-file URL; Packer refuses to boot on mismatch."
}

variable "ssh_username" {
  type    = string
  default = "packer"
}

variable "ssh_password" {
  type      = string
  default   = "packer"
  sensitive = true
}

variable "disk_size" {
  type    = string
  default = "10240M"
}

variable "headless" {
  type        = bool
  default     = true
  description = "Set false to watch the install over the SDL/GTK console during debugging."
}
```

`debian.pkr.hcl`:

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "debian" {
  # --- Source media ---
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # --- Machine shape ---
  accelerator  = "kvm"        # falls back to "tcg" (software) if /dev/kvm is absent
  cpus         = 2
  memory       = 2048
  disk_size    = var.disk_size
  disk_interface = "virtio"
  net_device   = "virtio-net"
  format       = "qcow2"

  # --- Boot & unattended install ---
  http_directory = "http"     # served at http://{{ .HTTPIP }}:{{ .HTTPPort }}/
  boot_wait      = "5s"
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "hostname=debian domain=local ",
    "interface=auto ",
    "<enter>"
  ]

  # --- Connection back into the guest ---
  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"        # generous: covers the whole preseed install

  # --- Shutdown & output ---
  headless         = var.headless
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  output_directory = "output-debian"
  vm_name          = "debian-12-golden.qcow2"

  # --- Post-install disk optimization ---
  disk_compression = true
  qemuargs = [
    ["-display", "none"]
  ]
}

build {
  name    = "debian-golden"
  sources = ["source.qemu.debian"]

  # 1) Copy a systemd unit into the image
  provisioner "file" {
    source      = "files/node-agent.service"
    destination = "/tmp/node-agent.service"
  }

  # 2) Run the hardening/package script with elevated privileges
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true                      # a kernel upgrade may drop SSH
    scripts           = ["scripts/provision.sh"]
    environment_vars  = ["DEBIAN_FRONTEND=noninteractive"]
  }

  # 3) Inline cleanup: shrink the image before it is frozen
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash -eux -c '{{ .Path }}'"
    inline = [
      "apt-get -y autoremove --purge",
      "apt-get -y clean",
      "rm -rf /var/lib/apt/lists/*",
      "cloud-init clean --logs || true",
      "truncate -s 0 /etc/machine-id",            # regenerated per boot -> unique DHCP/identity
      "rm -f /var/lib/dbus/machine-id",
      "dd if=/dev/zero of=/EMPTY bs=1M || true",   # zero free space so compression is effective
      "rm -f /EMPTY",
      "sync"
    ]
  }

  # 4) Emit a build manifest and a compressed artifact
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      distro = "debian-12"
      role   = "base"
    }
  }

  post-processor "compress" {
    output = "output-debian/debian-12-golden.qcow2.gz"
  }
}
```

`http/preseed.cfg` (Debian installer answer file — served in-memory over HTTP, never persisted into the image):

```
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string local

d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i passwd/root-login boolean false
d-i passwd/user-fullname string Packer
d-i passwd/username string packer
d-i passwd/user-password password packer
d-i passwd/user-password-again password packer

d-i clock-setup/utc boolean true
d-i time/zone string UTC

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i pkgsel/include string openssh-server sudo qemu-guest-agent cloud-init
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

# Give packer's user passwordless sudo so the shell provisioner works
d-i preseed/late_command string \
    in-target sh -c 'echo "packer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/packer'; \
    in-target chmod 440 /etc/sudoers.d/packer

d-i finish-install/reboot_in_progress note
```

`scripts/provision.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating base and installing fleet baseline"
apt-get update
apt-get -y install --no-install-recommends \
    chrony curl gnupg jq unattended-upgrades

echo "==> Installing the node agent unit"
install -m 0644 /tmp/node-agent.service /etc/systemd/system/node-agent.service
systemctl enable node-agent.service || true

echo "==> Minimal hardening"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "==> Done"
```

### 3.2 Docker image built with Packer, HCL2

Relevant to the containerization half of LPIC-3 305. Packer is *not* a Dockerfile replacement, but it lets you provision a container with the **same shell/Ansible code** used for VMs and then commit + push it — one provisioning source of truth for both worlds.

```hcl
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "registry" {
  type    = string
  default = "registry.example.com/platform"
}

source "docker" "ubuntu" {
  image  = "ubuntu:24.04"
  commit = true                    # commit the container to an image (vs. export to tar)
  changes = [
    "USER app",
    "WORKDIR /srv",
    "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
    "EXPOSE 8080"
  ]
}

build {
  name    = "app-container"
  sources = ["source.docker.ubuntu"]

  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get -y install --no-install-recommends ca-certificates curl",
      "useradd -r -u 10001 -m -d /srv app",
      "rm -rf /var/lib/apt/lists/*"
    ]
  }

  provisioner "file" {
    source      = "entrypoint.sh"
    destination = "/usr/local/bin/entrypoint.sh"
  }

  # Chained post-processors: tag, then push. Note the nested block form.
  post-processors {
    post-processor "docker-tag" {
      repository = "${var.registry}/app"
      tags       = ["latest", "1.4.0"]
    }
    post-processor "docker-push" {
      # credentials come from the docker CLI's credential store / login
    }
  }
}
```

> **Key syntax detail:** a **single `post-processor`** runs on the original build artifact. A **`post-processors { … }`** block (plural) defines a *chain* where each post-processor consumes the previous one's output — mandatory when you must tag *before* you push.

### 3.3 Legacy JSON equivalent (for reading comprehension)

The exam may show JSON. Same QEMU build, pre-1.7 style — note there is **no** `required_plugins`:

```json
{
  "builders": [
    {
      "type": "qemu",
      "iso_url": "debian-12.5.0-amd64-netinst.iso",
      "iso_checksum": "sha256:013f5b44670d81280b5b1bc02455842b250df2f0c6763398feb69af1a805a14f",
      "accelerator": "kvm",
      "disk_size": "10240M",
      "format": "qcow2",
      "headless": true,
      "http_directory": "http",
      "boot_command": ["<esc><wait>auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg<enter>"],
      "ssh_username": "packer",
      "ssh_password": "packer",
      "ssh_timeout": "30m",
      "shutdown_command": "echo packer | sudo -S shutdown -P now",
      "output_directory": "output-debian"
    }
  ],
  "provisioners": [
    { "type": "shell", "scripts": ["scripts/provision.sh"] }
  ],
  "post-processors": [
    { "type": "compress", "output": "output-debian/debian.qcow2.gz" }
  ]
}
```

Convert JSON → HCL2:

```
$ packer hcl2_upgrade -output-file debian.pkr.hcl debian.json
Successfully created debian.pkr.hcl
```

---

## 4. CLI workflow with real terminal output

The canonical order is **`init` → `fmt` → `validate` → `build`**. Never skip `init`/`validate` in a pipeline — they are free and catch the majority of failures before you burn a 20-minute install.

### 4.1 Install the declared plugins

```
$ packer version
Packer v1.11.2

$ packer init .
Installed plugin github.com/hashicorp/qemu v1.1.0 in "/home/sre/.config/packer/plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64"

$ packer plugins installed
/home/sre/.config/packer/plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64
```

`packer init` is idempotent — a second run with satisfied constraints prints nothing and exits 0. Plugins can also be installed explicitly:

```
$ packer plugins install github.com/hashicorp/docker
Installed plugin github.com/hashicorp/docker v1.1.0 ...
```

### 4.2 Format and validate

```
$ packer fmt -check -diff .
debian.pkr.hcl
--- old/debian.pkr.hcl
+++ new/debian.pkr.hcl
@@ -12,7 +12,7 @@
-  cpus         =2
+  cpus         = 2

$ packer fmt .
debian.pkr.hcl

$ packer validate .
The configuration is valid.
```

A validation failure is explicit and points at the line:

```
$ packer validate .
Error: Unsupported argument

  on debian.pkr.hcl line 18:
  18:   memroy       = 2048

An argument named "memroy" is not expected here. Did you mean "memory"?
```

### 4.3 Inspect the parsed template

```
$ packer inspect .
Packer Inspect: HCL2 mode

> input-variables:
var.disk_size: "10240M"
var.headless: "true"
var.iso_url: "https://cdimage.debian.org/.../debian-12.5.0-amd64-netinst.iso"
var.ssh_password: "packer"
var.ssh_username: "packer"

> builds:
  > <unnamed build 0>:
    sources:
      source.qemu.debian
    provisioners:
      file
      shell
      shell
    post-processors:
      <no post-processor group 0>:
        manifest
      <no post-processor group 1>:
        compress
```

### 4.4 Build

```
$ packer build -var 'headless=true' .
debian-golden.qemu.debian: output will be in this color.

==> debian-golden.qemu.debian: Retrieving ISO
==> debian-golden.qemu.debian: Trying https://cdimage.debian.org/.../debian-12.5.0-amd64-netinst.iso
==> debian-golden.qemu.debian: Verifying checksum
==> debian-golden.qemu.debian: Starting HTTP server on port 8341
==> debian-golden.qemu.debian: Found port for communicator (SSH): 3213.
==> debian-golden.qemu.debian: Starting VM, booting disk image
==> debian-golden.qemu.debian: Waiting 5s for boot...
==> debian-golden.qemu.debian: Typing the boot command over VNC...
==> debian-golden.qemu.debian: Waiting for SSH to become available...
==> debian-golden.qemu.debian: Connected to SSH!
==> debian-golden.qemu.debian: Uploading files/node-agent.service => /tmp/node-agent.service
==> debian-golden.qemu.debian: Provisioning with shell script: scripts/provision.sh
    debian-golden.qemu.debian: ==> Updating base and installing fleet baseline
    debian-golden.qemu.debian: ==> Done
==> debian-golden.qemu.debian: Gracefully halting virtual machine...
==> debian-golden.qemu.debian: Converting hard drive...
==> debian-golden.qemu.debian: Running post-processor: manifest
==> debian-golden.qemu.debian: Running post-processor: compress
Build 'debian-golden.qemu.debian' finished after 11 minutes 42 seconds.

==> Wait completed after 11 minutes 42 seconds

==> Builds finished. The artifacts of successful builds are:
--> debian-golden.qemu.debian: VM files in directory: output-debian
--> debian-golden.qemu.debian: compressed artifacts in: output-debian/debian-12-golden.qcow2.gz
```

Useful build-time flags:

| Flag | Effect |
|---|---|
| `-only='qemu.debian'` | Run only the matching source(s) in a multi-source build |
| `-except='docker.*'` | Run everything *except* the matching sources |
| `-var 'k=v'` / `-var-file=prod.pkrvars.hcl` | Override variables |
| `-on-error=ask` | On failure, pause so you can SSH into the still-running build VM |
| `-on-error=abort` | Leave the machine as-is (don't clean up) for forensics |
| `-parallel-builds=1` | Serialize sources (default is parallel) |
| `-debug` | Step through each stage on keypress; prints the temp SSH key path |
| `-force` | Overwrite a pre-existing artifact/output directory |
| `-timestamp-ui` | Prefix every log line with a timestamp (pipeline-friendly) |

---

## 5. Verification and failure diagnosis

### 5.1 The diagnostic ladder

```
$ PACKER_LOG=1 PACKER_LOG_PATH=./packer.log packer build .
```

`PACKER_LOG=1` turns on core + plugin debug logging; `PACKER_LOG_PATH` sends it to a file so the colored UI stays readable. Inside the log you see the exact `qemu-system-x86_64` invocation, the VNC typing, and every SSH handshake attempt — this is where 90 % of QEMU builds are actually debugged.

For interactive forensics on a stuck build:

```
$ packer build -debug -on-error=ask .
...
==> Pausing after run of step 'StepTypeBootCommand'. Press enter to continue.
==> Waiting for SSH to become available...
==> Build paused. Press enter to continue, or type 'exit' to abort.
```

`-debug` also writes the throwaway SSH private key to the working directory (`qemu.debian.pem` etc.), so you can `ssh -i` into the build VM while it is paused and inspect state by hand.

### 5.2 Common failures → root cause → fix

| Symptom in output | Root cause | Fix |
|---|---|---|
| `Bad checksum ... expected X got Y` | Wrong/stale `iso_checksum`, or a truncated download | Use `iso_checksum = "file:.../SHA256SUMS"` so Packer reads the official sums; re-download |
| `Waiting for SSH to become available...` then timeout | Preseed/autoinstall never completed, or user/sudo not created | Boot with `headless=false` and watch the installer; verify `preseed/late_command` creates the sudoers file; raise `ssh_timeout` |
| `install plugin ... could not be found` on `build` | `packer init` not run, or `source` mismatch in `required_plugins` | Run `packer init .`; confirm the `source` string matches `github.com/hashicorp/<name>` |
| Boot command types garbage into installer | Host keyboard timing; missing `<wait>` tokens | Add `<wait>`/`<waitNs>` between keystrokes; increase `boot_wait` |
| `Error launching VM: ... /dev/kvm permission denied` | User not in the `kvm` group / nested-virt off | `usermod -aG kvm $USER`; enable KVM; Packer will fall back to slow TCG otherwise |
| `sudo: no tty present and no askpass program` | Provisioner runs sudo but no NOPASSWD | Add passwordless sudo in preseed, or use the `echo pass | sudo -S` `execute_command` shown above |
| Post-processor `docker-push` → `denied` | Not logged in to the registry | `docker login registry.example.com` before `packer build`; Packer reuses the CLI credential store |
| Image huge after build | Free space not zeroed before snapshot | Add the `dd if=/dev/zero … && rm` + `disk_compression = true` step |

### 5.3 Verifying the artifact after the build

The build finishing successfully proves Packer *ran*, not that the image is *correct*. Verify independently:

```
$ qemu-img info output-debian/debian-12-golden.qcow2
image: output-debian/debian-12-golden.qcow2
file format: qcow2
virtual size: 10 GiB (10737418240 bytes)
disk size: 1.42 GiB
cluster_size: 65536

$ qemu-img check output-debian/debian-12-golden.qcow2
No errors were found on the image.

$ jq '.builds[0] | {name, artifact_id, packer_run_uuid}' manifest.json
{
  "name": "debian-golden",
  "artifact_id": "output-debian/debian-12-golden.qcow2",
  "packer_run_uuid": "6d3c1e0a-..."
}
```

Smoke-boot the golden image in an isolated network and confirm the baked baseline:

```
$ qemu-system-x86_64 -enable-kvm -m 2048 -nographic \
    -drive file=output-debian/debian-12-golden.qcow2,if=virtio \
    -netdev user,id=n0 -device virtio-net,netdev=n0
...
debian login: packer
$ systemctl is-enabled node-agent.service
enabled
$ dpkg -l | grep -c qemu-guest-agent
1
$ cat /etc/machine-id        # should be EMPTY in the image -> regenerated on first boot
$
```

An empty `/etc/machine-id` in the frozen image is the signal that you correctly de-duplicated instance identity — every clone gets a fresh ID (and thus a distinct DHCP lease/systemd machine identity) on first boot.

### 5.4 CI gate

The exam-worthy pipeline pattern — fail fast, cheap checks first:

```bash
#!/usr/bin/env bash
set -euo pipefail
packer init .                       # pin/fetch plugins
packer fmt -check -diff .           # style gate (fails if unformatted)
packer validate .                   # semantic gate
packer build -timestamp-ui \
             -var-file=prod.pkrvars.hcl .
qemu-img check output-debian/*.qcow2 # artifact integrity gate
```

`fmt -check` returns non-zero when files are unformatted, and `validate` returns non-zero on any semantic error, so both work directly as CI gates without extra parsing.

---

## 6. References

- LPI — Exam 305-300 Objectives (353.2 Packer): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Packer documentation (HashiCorp Developer): <https://developer.hashicorp.com/packer/docs>
- Packer templates — HCL2 syntax and blocks: <https://developer.hashicorp.com/packer/docs/templates/hcl_templates>
- Packer `required_plugins` and `packer init`: <https://developer.hashicorp.com/packer/docs/plugins>
- QEMU builder plugin reference: <https://developer.hashicorp.com/packer/integrations/hashicorp/qemu>
- Docker builder plugin reference: <https://developer.hashicorp.com/packer/integrations/hashicorp/docker>
- Provisioners (shell, file, ansible): <https://developer.hashicorp.com/packer/docs/provisioners>
- Post-processors (compress, manifest, docker-tag/push, vagrant): <https://developer.hashicorp.com/packer/docs/post-processors>
- Packer CLI commands (`init`, `fmt`, `validate`, `inspect`, `build`, `hcl2_upgrade`): <https://developer.hashicorp.com/packer/docs/commands>
- Debugging Packer builds & environment variables (`PACKER_LOG`): <https://developer.hashicorp.com/packer/docs/debugging>
- Debian Installer preseed reference: <https://www.debian.org/releases/stable/amd64/apb.en.html>
- QEMU disk image utility (`qemu-img`): <https://www.qemu.org/docs/master/tools/qemu-img.html>