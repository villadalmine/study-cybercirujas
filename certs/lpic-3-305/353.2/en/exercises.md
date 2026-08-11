# Guided Exercises — Topic 353.2: Packer
### LPIC-3 305 (exam 305-300, version 3.0) — Objective weight: 3.33

These exercises walk you through building system images with **HashiCorp Packer** the way it is done in production: HCL2 templates, plugin management, a real QEMU build, provisioners, post-processors, variables, and the interoperability points with Vagrant and Terraform that the exam objective calls out.

**Lab prerequisites** — a Linux host with:
- KVM available (`ls -l /dev/kvm` returns a character device; your user is in the `kvm` group)
- `qemu-system-x86_64`, `qemu-img`, `xorriso` (or `genisoimage`) installed
- ~4 GB free disk and outbound HTTPS
- Packer 1.7 or newer (this lab is written against `v1.12.0`)

Throughout, run commands from a clean working directory, e.g. `~/packer-lab`.

> Sources of reference:
> - LPI exam 305 objectives — https://www.lpi.org/our-certifications/exam-305-objectives/
> - Packer documentation — https://developer.hashicorp.com/packer/docs
> - QEMU builder plugin — https://developer.hashicorp.com/packer/integrations/hashicorp/qemu

---

## Part 1 — Install Packer and understand its architecture

**Steps**

1. Install Packer from the HashiCorp APT repository (Debian/Ubuntu) and confirm the binary:

   ```bash
   wget -O- https://apt.releases.hashicorp.com/gpg | \
     sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
     https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
     sudo tee /etc/apt/sources.list.d/hashicorp.list
   sudo apt-get update && sudo apt-get install -y packer
   packer version
   ```

   Expected:

   ```
   Packer v1.12.0
   ```

2. List the top-level subcommands and note the ones named in the objective (`build`, `fmt`, `hcl2_upgrade`, `init`, `inspect`, `validate`):

   ```bash
   packer --help
   ```

   Abbreviated output:

   ```
   Usage: packer [--version] [--help] <command> [<args>]

   Available commands are:
       build           build image(s) from template
       console         creates a console for testing variable interpolation
       fix             fixes templates from old versions of packer
       fmt             Rewrites HCL2 config files to canonical format
       hcl2_upgrade    transform a JSON template into an HCL2 configuration
       init            Install missing plugins or upgrade plugins
       inspect         see components of a template
       plugins         Interact with Packer plugins and catalog
       validate        check that a template is valid
       version         Prints the Packer version
   ```

3. List which plugins are currently installed (none yet, on a fresh install):

   ```bash
   packer plugins installed
   ```

   Expected on a clean machine: no output (exit 0).

**Comprehension questions**

- **Q1.** Name the three component types that make up a Packer build and state, in one sentence each, what they are responsible for.
- **Q2.** Since Packer 1.7, where do builders such as QEMU, Amazon EBS, or VMware actually live, and what does that mean for the `packer` binary you just installed?
- **Q3.** Packer produces *machine images*. What is the fundamental difference between what Packer does and what a configuration-management run (or Terraform) does at deploy time?

---

## Part 2 — Write your first HCL2 template and validate it (no build yet)

You will describe a build for a **Debian 12 (bookworm) cloud image** using the QEMU builder, then use `init`, `fmt`, `validate`, and `inspect` to work with it *without* running the build.

**Steps**

1. Create `debian.pkr.hcl`:

   ```hcl
   packer {
     required_plugins {
       qemu = {
         version = ">= 1.1.0"
         source  = "github.com/hashicorp/qemu"
       }
     }
   }

   variable "iso_url" {
     type    = string
     default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
   }

   variable "disk_size" {
     type    = string
     default = "10G"
   }

   source "qemu" "debian" {
     # Build FROM an existing qcow2 disk image rather than an installer ISO.
     iso_url      = var.iso_url
     iso_checksum = "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
     disk_image   = true

     output_directory = "output-debian"
     vm_name          = "debian-12.qcow2"
     format           = "qcow2"
     disk_size        = var.disk_size
     disk_interface   = "virtio"
     net_device       = "virtio-net"

     accelerator = "kvm"
     memory      = 1024
     cpus        = 2
     headless    = true

     # NoCloud seed: cloud-init creates the 'packer' login Packer will SSH into.
     cd_label = "cidata"
     cd_content = {
       "meta-data" = ""
       "user-data" = <<-EOF
         #cloud-config
         ssh_pwauth: true
         users:
           - name: packer
             groups: [sudo]
             shell: /bin/bash
             sudo: "ALL=(ALL) NOPASSWD:ALL"
             lock_passwd: false
             # Password is 'packer' (mkpasswd -m sha-512). Lab-only credential.
             passwd: "$6$rounds=4096$saltsalt$0Xq0i/EXAMPLEHASHREPLACEME."
       EOF
     }

     ssh_username = "packer"
     ssh_password = "packer"
     ssh_timeout  = "10m"

     shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
   }

   build {
     name    = "debian-cloud"
     sources = ["source.qemu.debian"]
   }
   ```

   > For a working lab, replace the `passwd` hash with your own: `mkpasswd -m sha-512 packer`.

2. Install the plugin declared in `required_plugins`:

   ```bash
   packer init .
   ```

   Expected:

   ```
   Installed plugin github.com/hashicorp/qemu v1.1.0 in ".../plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64"
   ```

3. Deliberately misformat the file (add leading spaces / misalign the `=`), then let Packer canonicalize it:

   ```bash
   packer fmt -diff .
   ```

   Expected — the changed filename is printed, preceded by a unified diff of the corrections:

   ```
   debian.pkr.hcl
   ```

   Now check that nothing remains to fix (useful in CI):

   ```bash
   packer fmt -check -diff .
   echo "exit: $?"
   ```

   Expected: no filenames printed, `exit: 0`. (When changes *are* still needed, `-check` exits non-zero and prints the offending files.)

4. Validate configuration and syntax without building:

   ```bash
   packer validate .
   ```

   Expected:

   ```
   The configuration is valid.
   ```

5. Inspect the template's components and variables:

   ```bash
   packer inspect .
   ```

   Abbreviated output:

   ```
   Packer Inspect: HCL2 mode

   > input-variables:

   var.disk_size: "10G"
   var.iso_url: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

   > builds:

     > debian-cloud:

       sources:
         source.qemu.debian
   ```

**Comprehension questions**

- **Q4.** What does `packer init` read to decide what to install, and why is running it a prerequisite for `validate` and `build`?
- **Q5.** In CI you want the pipeline to *fail* if a template is not canonically formatted, without modifying files. Which exact command achieves that, and how does the pipeline detect the failure?
- **Q6.** `packer validate` returned "valid," yet the build could still fail at runtime. Give two failure classes that `validate` cannot catch.
- **Q7.** In the template, what is the role of the `cd_content` / `cd_label = "cidata"` block, and why is it necessary when building *from a cloud qcow2* rather than from an installer ISO?

---

## Part 3 — Add provisioners and run the build

Provisioners customize the running machine after it boots and before the disk is captured.

**Steps**

1. Add a `file` provisioner and a `shell` provisioner to the `build` block (insert inside `build { ... }`, after `sources`):

   ```hcl
     provisioner "file" {
       content     = "Built by Packer on ${timestamp()}\n"
       destination = "/tmp/build-stamp.txt"
     }

     provisioner "shell" {
       # Ensure cloud-init has finished before we touch the system.
       inline = [
         "cloud-init status --wait || true",
         "sudo install -m 0644 /tmp/build-stamp.txt /etc/build-stamp",
         "sudo apt-get update",
         "sudo apt-get install -y --no-install-recommends qemu-guest-agent",
         "sudo systemctl enable qemu-guest-agent",
         "sudo cloud-init clean --logs",
         "sudo rm -f /etc/machine-id && sudo touch /etc/machine-id",
       ]
     }
   ```

2. Re-validate, then build:

   ```bash
   packer validate .
   packer build .
   ```

   Abbreviated build log:

   ```
   debian-cloud.qemu.debian: output will be in this color.

   ==> debian-cloud.qemu.debian: Retrieving ISO
   ==> debian-cloud.qemu.debian: Trying https://cloud.debian.org/.../debian-12-genericcloud-amd64.qcow2
   ==> debian-cloud.qemu.debian: Creating required virtual machine disks
   ==> debian-cloud.qemu.debian: Starting VM, booting disk image
   ==> debian-cloud.qemu.debian: Waiting 10s for boot...
   ==> debian-cloud.qemu.debian: Connecting to VM via SSH (127.0.0.1:2222)
   ==> debian-cloud.qemu.debian: Connected to SSH!
   ==> debian-cloud.qemu.debian: Uploading a file to /tmp/build-stamp.txt
   ==> debian-cloud.qemu.debian: Provisioning with shell script: /tmp/packer-shell1234
       debian-cloud.qemu.debian: status: done
       debian-cloud.qemu.debian: Reading package lists...
   ==> debian-cloud.qemu.debian: Gracefully halting virtual machine...
   ==> debian-cloud.qemu.debian: Converting hard drive...
   Build 'debian-cloud.qemu.debian' finished after 4 minutes 12 seconds.

   ==> Wait completed after 4 minutes 12 seconds

   ==> Builds finished. The artifacts of successful builds are:
   --> debian-cloud.qemu.debian: VM files in directory: output-debian
   ```

3. Confirm the artifact:

   ```bash
   ls -lh output-debian/
   qemu-img info output-debian/debian-12.qcow2
   ```

   Expected (abbreviated):

   ```
   image: output-debian/debian-12.qcow2
   file format: qcow2
   virtual size: 10 GiB (10737418240 bytes)
   ```

4. If a build fails while you are iterating, keep the VM alive so you can SSH in and debug instead of destroying it:

   ```bash
   packer build -on-error=ask .
   ```

**Comprehension questions**

- **Q8.** In what order do the `file` and `shell` provisioners run, and what determines that order?
- **Q9.** Why does the shell provisioner run `cloud-init clean` and reset `/etc/machine-id` near the end? What production problem does skipping this cause?
- **Q10.** During iteration a provisioner script fails. Compare `-on-error=ask` with the default behavior and explain why the former shortens the debug loop.
- **Q11.** You need to run *the same* shell provisioner across several different `source` blocks (QEMU and, later, an AMI). How does the `build` block let you avoid duplicating the provisioner?

---

## Part 4 — Post-processors: package a Vagrant box and a manifest

Post-processors take the build artifact and transform, upload, or repackage it. This is also the objective's **Packer ↔ Vagrant** interoperability point.

**Steps**

1. Add a post-processor chain to the `build` block (after the provisioners):

   ```hcl
     post-processor "vagrant" {
       # QEMU artifacts map to the libvirt Vagrant provider.
       output               = "debian-12.{{.Provider}}.box"
       compression_level    = 9
       keep_input_artifact  = true
     }

     post-processor "manifest" {
       output     = "manifest.json"
       strip_path = true
     }
   ```

2. Re-run the build:

   ```bash
   packer build .
   ```

   New tail of the log:

   ```
   ==> debian-cloud.qemu.debian: Running post-processor: (type vagrant)
   ==> debian-cloud.qemu.debian (vagrant): Creating Vagrant box for 'libvirt' provider
       debian-cloud.qemu.debian (vagrant): Compressing: debian-12.qcow2
   ==> debian-cloud.qemu.debian: Running post-processor: (type manifest)

   ==> Builds finished. The artifacts of successful builds are:
   --> debian-cloud.qemu.debian: VM files in directory: output-debian
   --> debian-cloud.qemu.debian: 'libvirt' provider box: debian-12.libvirt.box
   --> debian-cloud.qemu.debian: 1 files were created:
   manifest.json
   ```

3. Inspect the manifest (the machine-readable record other tools consume):

   ```bash
   cat manifest.json
   ```

   Expected shape:

   ```json
   {
     "builds": [
       {
         "name": "debian",
         "builder_type": "qemu",
         "files": [
           { "name": "debian-12.libvirt.box", "size": 512344123 }
         ],
         "artifact_id": "VM",
         "packer_run_uuid": "e2b0...",
         "custom_data": null
       }
     ],
     "last_run_uuid": "e2b0..."
   }
   ```

4. Consume the box with Vagrant to prove interoperability:

   ```bash
   vagrant box add debian-12-lab debian-12.libvirt.box
   vagrant box list | grep debian-12-lab
   ```

   Expected:

   ```
   debian-12-lab (libvirt, 0)
   ```

**Comprehension questions**

- **Q12.** Contrast a **provisioner** with a **post-processor** in terms of *where* and *when* each runs.
- **Q13.** The `vagrant` post-processor emitted a box for the `libvirt` provider without you naming a provider. How did it decide, and what does `{{.Provider}}` interpolate to?
- **Q14.** What is `keep_input_artifact` controlling, and what happens to the raw qcow2 if you leave it at its default?
- **Q15.** Post-processors can be *chained* (nested) so one feeds the next, versus listed *in sequence* so each consumes the build artifact. In the template above, are `vagrant` and `manifest` chained or sequential — and how would you write a chain?

---

## Part 5 — Variables, variable files, and environment variables

**Steps**

1. Override a variable on the command line:

   ```bash
   packer build -var 'disk_size=20G' .
   ```

2. Put overrides in a variables file and pass it explicitly:

   ```bash
   cat > lab.pkrvars.hcl <<'EOF'
   iso_url   = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
   disk_size = "16G"
   EOF

   packer build -var-file=lab.pkrvars.hcl .
   ```

   > A file named `*.auto.pkrvars.hcl` (or `variables.pkrvars.hcl`) is loaded **automatically**, with no `-var-file` flag.

3. Set the *same* variable through the environment using the `PKR_VAR_` prefix:

   ```bash
   export PKR_VAR_disk_size="24G"
   packer validate .        # picks up 24G with no flags
   ```

4. Confirm Packer's precedence by combining sources and printing the effective value with `packer console`:

   ```bash
   PKR_VAR_disk_size="24G" packer console -var 'disk_size=32G' .
   ```

   At the prompt:

   ```
   > var.disk_size
   32G
   ```

5. Turn on detailed logging to a file (operational-grade debugging):

   ```bash
   PACKER_LOG=1 PACKER_LOG_PATH=packer-debug.log packer build .
   tail -n 5 packer-debug.log
   ```

6. Point Packer's download cache elsewhere (useful on shared runners):

   ```bash
   PACKER_CACHE_DIR=/var/cache/packer packer build .
   ```

**Comprehension questions**

- **Q16.** List Packer's variable precedence from **lowest** to **highest**, given: `default`, `-var`, `PKR_VAR_*`, and an auto-loaded `*.auto.pkrvars.hcl`.
- **Q17.** You must inject a registry password without writing it into any `.hcl` file or into shell history flags. Which mechanism from this part fits, and how do you declare the variable so it is not printed in logs?
- **Q18.** What do `PACKER_LOG` and `PACKER_LOG_PATH` do, and why is directing the log to a file preferable to reading stdout during a long build?
- **Q19.** Distinguish `PKR_VAR_disk_size` (an *input variable*) from `PACKER_CACHE_DIR` (a Packer *settings* environment variable). Are both consumed the same way?

---

## Part 6 — Interoperability: JSON→HCL2, Terraform, and QEMU

The objective explicitly tests Packer's interaction with **Vagrant, Terraform, and QEMU**, and knowledge of both **JSON and HCL2** template formats.

**Steps**

1. You inherit a legacy JSON template. Convert it to HCL2:

   ```bash
   cat > old-template.json <<'EOF'
   {
     "builders": [
       {
         "type": "qemu",
         "iso_url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2",
         "iso_checksum": "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS",
         "disk_image": true,
         "output_directory": "output-legacy",
         "accelerator": "kvm",
         "ssh_username": "packer",
         "ssh_password": "packer",
         "shutdown_command": "echo packer | sudo -S shutdown -P now"
       }
     ],
     "provisioners": [
       { "type": "shell", "inline": ["echo hello from legacy"] }
     ]
   }
   EOF

   packer hcl2_upgrade old-template.json
   ls old-template.json.pkr.hcl
   ```

   Expected:

   ```
   Successfully created old-template.json.pkr.hcl
   old-template.json.pkr.hcl
   ```

2. Record the built artifact so Terraform can consume it. The `manifest.json` from Part 4 already gives you a machine-readable handle. In a Terraform stack you would read it:

   ```hcl
   # main.tf — Terraform consumes what Packer produced
   locals {
     packer_manifest = jsondecode(file("${path.module}/manifest.json"))
     image_path      = one([
       for b in local.packer_manifest.builds :
       b.files[0].name if b.builder_type == "qemu"
     ])
   }

   resource "libvirt_volume" "debian" {
     name   = "debian-base"
     source = local.image_path   # the qcow2/box Packer built
   }
   ```

   Validate the wiring (no apply needed):

   ```bash
   terraform init && terraform validate
   ```

   Expected:

   ```
   Success! The configuration is valid.
   ```

3. Confirm the QEMU build ran through real virtualization by watching for the guest during a build in another terminal:

   ```bash
   pgrep -a qemu-system-x86_64
   ```

   Expected (abbreviated) during an active build:

   ```
   34211 qemu-system-x86_64 -accel kvm -m 1024M ... -drive file=output-debian/debian-12.qcow2 ...
   ```

**Comprehension questions**

- **Q20.** Packer and Terraform are both HashiCorp tools that read HCL, yet they occupy different stages of the lifecycle. State the division of labor in one sentence and name the artifact that hands off from one to the other.
- **Q21.** After running `hcl2_upgrade`, what mapping happened to the JSON `"builders"` and `"provisioners"` arrays in the HCL2 output, and which HCL2 top-level block ties a source to its provisioners?
- **Q22.** The QEMU builder set `accelerator = "kvm"`. What is lost if you drop to the default (`tcg`) software emulation, and what host feature must be present for `kvm` to work?
- **Q23.** For the Packer→Vagrant and Packer→Terraform hand-offs, which single generated file is the reliable, machine-readable contract between the stages, and which post-processor produces it?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** (1) **Builders** create and boot a machine on a platform (QEMU, AWS, VMware, Docker, …) and, at the end, capture it as an image. (2) **Provisioners** run inside the booted machine to install and configure software (shell, file, Ansible, …). (3) **Post-processors** act on the finished artifact — repackaging it (Vagrant box), compressing it, uploading it, or writing a manifest.

**Q2.** Since 1.7 builders, provisioners, and most post-processors ship as **external plugins** (multi-component binaries such as `packer-plugin-qemu`), not inside the core binary. The `packer` binary is small and generic; the QEMU capability arrives only after `packer init` installs `github.com/hashicorp/qemu`. This is why a fresh install shows no plugins.

**Q3.** Packer performs **image bake time** work: it produces an immutable, pre-baked image once, up front. Configuration management and Terraform act at **deploy/run time** — they configure or stand up infrastructure repeatedly from that image. Packer answers "what's in the image," Terraform/CM answer "how many, where, and wired to what."

**Q4.** `packer init` reads the `packer { required_plugins { … } }` block(s) and installs/upgrades the matching plugin binaries into the plugin directory. `validate` and `build` need the actual plugin code to interpret `source "qemu"`, so they fail with "unknown source/plugin" until `init` has run.

**Q5.** `packer fmt -check -diff .`. With `-check`, Packer does **not** rewrite files; it prints the paths that are not canonically formatted and **exits non-zero** (exit code 3). CI treats that non-zero exit as a failed step.

**Q6.** Anything that depends on **runtime state**, e.g.: (a) a provisioner shell script that fails mid-build (bad `apt` package, network timeout); (b) an unreachable/incorrect `iso_url` or a checksum mismatch; (c) SSH never coming up because cloud-init didn't create the user; (d) insufficient host resources (no `/dev/kvm`). `validate` only checks configuration/syntax and plugin availability.

**Q7.** `cd_content` writes an in-memory **NoCloud (cidata) seed ISO** containing cloud-init `user-data`/`meta-data`, and `cd_label = "cidata"` is the volume label cloud-init looks for. A stock cloud qcow2 has **no interactive installer and no preset login** — it expects a cloud-init datasource to create users and enable SSH. Without the seed, Packer would boot the image but never be able to SSH in. (An installer ISO instead uses a preseed/kickstart delivered via boot commands, so it doesn't need cidata.)

**Q8.** They run **top to bottom in the order written in the `build` block**: the `file` provisioner uploads first, then the `shell` provisioner runs — which is why the shell step can `install` the file that was just uploaded. Ordering is purely lexical within the block.

**Q9.** Cloud images capture per-instance identity during first boot. Leaving cloud-init's cached state and a populated `/etc/machine-id` in the image means **every VM cloned from it shares the same machine-id and cloud-init "already ran" state** — causing duplicate DHCP leases/IPs, duplicate systemd journald identities, and cloud-init not re-running on new instances. `cloud-init clean` + truncating `machine-id` forces regeneration on first boot of each clone.

**Q10.** By default a failed provisioner makes Packer **clean up and destroy the VM**, so the failing state is gone. `-on-error=ask` **pauses and leaves the VM running**, offering to retry, clean up, or abort — you can SSH into the live machine, reproduce the failing command, and fix the script without re-running the whole build from scratch. (`-on-error=abort` leaves it without prompting.)

**Q11.** The `build` block lists **multiple `sources`** and applies the same provisioner/post-processor stanzas to all of them: `sources = ["source.qemu.debian", "source.amazon-ebs.debian"]`. The provisioners are written once and executed against each source, so there is no duplication.

**Q12.** A **provisioner** runs **inside the temporary machine while it is booted**, before the image is captured (installs packages, edits files). A **post-processor** runs **on the host, after the artifact exists** — it never touches the running guest; it transforms/uploads/records the finished image.

**Q13.** The `vagrant` post-processor **infers the Vagrant provider from the builder type**: a QEMU artifact maps to the `libvirt` provider. `{{.Provider}}` is a template variable that interpolates to that provider name, so `output = "debian-12.{{.Provider}}.box"` becomes `debian-12.libvirt.box`.

**Q14.** `keep_input_artifact` controls whether the **input to the post-processor (the raw qcow2 in `output-debian/`)** is preserved after it has been consumed. Left at its default (`false` for the vagrant post-processor), the raw qcow2 would be deleted once the box is built; setting it `true` keeps both.

**Q15.** As written they are **sequential**: each is a separate `post-processor` block, and both consume the *build's* artifact independently (the manifest records the box). A **chain** is written as a single `post-processors` (plural) block containing nested blocks, where each feeds the next:
```hcl
post-processors {
  post-processor "vagrant" { … }
  post-processor "shell-local" { … }   # receives the .box from vagrant
}
```

**Q16.** Lowest → highest: **`default`** (in the `variable` block) → **`PKR_VAR_*`** environment variables → **auto-loaded `*.auto.pkrvars.hcl`** files → **`-var` / `-var-file` on the command line** (last one wins among these, evaluated left to right). This is why the `console` in step 4 printed `32G` (the `-var`) over `24G` (the `PKR_VAR_`).

**Q17.** Use a **`PKR_VAR_`** environment variable (it never appears in a file or as a visible flag). Declare the variable with **`sensitive = true`**:
```hcl
variable "registry_password" { type = string, sensitive = true }
```
so Packer redacts it in build output and logs.

**Q18.** `PACKER_LOG=1` enables verbose internal debug logging; `PACKER_LOG_PATH=<file>` sends that log to a file instead of stderr. Directing it to a file keeps the readable colored build progress on your terminal, preserves the full trace for a multi-minute build, and gives you something to grep/attach to a ticket afterward.

**Q19.** No — they are consumed differently. `PKR_VAR_disk_size` is an **input variable** bound to a declared `variable "disk_size"` and usable as `var.disk_size` inside the template. `PACKER_CACHE_DIR` is a **Packer settings/behavior variable** read by the core tool itself (where to cache ISOs); it is *not* exposed as `var.*` and does not correspond to any `variable` block.

**Q20.** **Packer builds the immutable image; Terraform provisions infrastructure from that image.** The hand-off artifact is the **built image/its identifier** (an AMI id, a qcow2/box path) — commonly surfaced via `manifest.json` (or, in HashiCorp's ecosystem, the HCP Packer registry consumed by the `hcp_packer_*` Terraform data sources).

**Q21.** Each element of the JSON `"builders"` array became a top-level **`source "<type>" "<name>"`** block; the `"provisioners"` array became **`provisioner`** blocks. A generated **`build { sources = [...]  provisioner {...} }`** block ties the source(s) to the provisioners — the piece JSON expressed implicitly is now explicit.

**Q22.** Dropping to `tcg` uses **pure software CPU emulation**, which is dramatically slower (a build that takes minutes with KVM can take many times longer) and cannot use hardware virtualization extensions. For `accelerator = "kvm"` the host must have **hardware virtualization (Intel VT-x / AMD-V) enabled and the KVM kernel module loaded**, exposing `/dev/kvm`.

**Q23.** **`manifest.json`**, produced by the **`manifest` post-processor**. It is the stable, machine-readable record of what was built (artifact ids, file names, sizes, builder type, run UUID), so Vagrant/Terraform pipelines can locate the exact artifact without scraping build logs.

</details>