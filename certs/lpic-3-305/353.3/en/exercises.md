# 353.3 cloud-init — Guided Exercises

> **Certification:** LPIC-3 305-300 (Virtualization and Containerization), v3.0 · **Objective 353.3 — cloud-init** (weight 5)
>
> **What you build:** a self-contained lab that provisions a real VM from a `NoCloud` seed, then dissects every stage cloud-init runs. No cloud account is needed — everything runs locally under QEMU/KVM with an official Ubuntu cloud image.
>
> **Prerequisites:** a Linux host with `qemu-system-x86_64`, KVM enabled (`/dev/kvm` present), and the packages `cloud-image-utils` (for `cloud-localds`) or `genisoimage`, plus `cloud-init` installed inside the guest (all official cloud images ship it). Run host commands as your normal user; guest commands are shown with the guest prompt.

---

## Exercise 1 — Provision a VM with the NoCloud datasource

You will hand cloud-init its `user-data` and `meta-data` on a tiny ISO labeled `cidata`. This is the `NoCloud` datasource — the exact mechanism the exam expects you to reproduce by hand.

1. Create a working directory and fetch the official Ubuntu 22.04 (Jammy) cloud image:

   ```bash
   mkdir -p ~/cloudinit-lab && cd ~/cloudinit-lab
   curl -fLO https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
   ```

2. Never boot the pristine image directly — create a copy-on-write overlay so the base stays reusable:

   ```bash
   qemu-img create -f qcow2 -F qcow2 \
       -b jammy-server-cloudimg-amd64.img instance.qcow2 10G
   ```

   ```text
   Formatting 'instance.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off
   compression_type=zlib size=10737418240
   backing_file=jammy-server-cloudimg-amd64.img backing_fmt=qcow2
   refcount_bits=16
   ```

3. Write the two seed files. `meta-data` must at minimum carry an `instance-id`; `local-hostname` is conventional:

   ```bash
   cat > meta-data <<'EOF'
   instance-id: iid-lab-0001
   local-hostname: cloudinit-lab
   EOF
   ```

4. Write a minimal `user-data`. The first line **must** be exactly `#cloud-config` — cloud-init dispatches on that header:

   ```bash
   cat > user-data <<'EOF'
   #cloud-config
   password: labpass
   chpasswd: { expire: false }
   ssh_pwauth: true
   EOF
   ```

5. Pack both files into a seed image. The ISO **must** have the volume label `cidata`:

   ```bash
   cloud-localds seed.img user-data meta-data
   file seed.img
   ```

   ```text
   seed.img: ISO 9660 CD-ROM filesystem data 'cidata'
   ```

   > No `cloud-localds`? Do it by hand — same label, same result:
   > `genisoimage -output seed.img -volid cidata -joliet -rock user-data meta-data`

6. Boot the VM, attaching the overlay disk and the seed as a second disk, and forwarding host port 2222 to guest SSH:

   ```bash
   qemu-system-x86_64 \
     -machine accel=kvm,type=q35 -cpu host -m 2048 -nographic \
     -drive if=virtio,format=qcow2,file=instance.qcow2 \
     -drive if=virtio,format=raw,file=seed.img \
     -netdev user,id=n0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=n0
   ```

   Watch the console — the four service units are the boot stages made visible:

   ```text
   [  OK  ] Finished cloud-init-local.service - Initial cloud-init job (pre-networking).
   [  OK  ] Finished cloud-init-network.service - Initial cloud-init job (metadata service crawler).
   [  OK  ] Finished cloud-config.service - Apply the settings specified in cloud-config.
   [  OK  ] Finished cloud-final.service - Execute cloud user/final scripts.
   ```

7. At the `login:` prompt log in as `ubuntu` / `labpass` (or from the host: `ssh -p 2222 ubuntu@localhost`). Keep this VM running for the next exercises.

**Check your understanding**

- **1a.** What are the two seed files, and what is the single mandatory key inside `meta-data`?
- **1b.** What volume label must the seed filesystem carry so `ds-identify` recognizes NoCloud? Name two *other* ways NoCloud can be seeded without an ISO.
- **1c.** Why the qcow2 overlay in step 2 instead of booting `jammy-server-cloudimg-amd64.img` directly?
- **1d.** What does `hostfwd=tcp::2222-:22` accomplish, and why is it needed with `-netdev user`?

---

## Exercise 2 — Read the boot stages, status, and instance data

Now inspect what cloud-init actually did. Run everything **inside the guest**.

1. Block until cloud-init finishes, then read the long status:

   ```bash
   sudo cloud-init status --wait --long
   ```

   ```text
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   last_update: Tue, 11 Aug 2026 14:03:22 +0000
   detail: DataSourceNoCloud [seed=/dev/vdb][dsmode=net]
   errors: []
   recoverable_errors: {}
   ```

2. Confirm which datasource was selected:

   ```bash
   cloud-id
   ```

   ```text
   nocloud
   ```

3. Render the ordered timeline of every event, per stage:

   ```bash
   sudo cloud-init analyze show | head -n 20
   ```

   ```text
   -- Boot Record 01 --
   The total time elapsed since completing an event is printed after the "@" character.
   The time the event takes is printed after the "+" character.

   Starting stage: init-local
   |`->no cache found @00.005s +00.001s
   |`->found local data from DataSourceNoCloud @00.102s +00.305s
   Finished stage: (init-local) 00.410 seconds

   Starting stage: init-network
   ...
   ```

4. Find the *slowest* operations (this is what you profile in production when a boot drags):

   ```bash
   sudo cloud-init analyze blame | head -n 8
   ```

   ```text
   -- Boot Record 01 --
        01.234s (modules-config/config-grub-dpkg)
        00.531s (init-network/config-growpart)
        00.240s (init-network/config-resizefs)
        00.061s (modules-final/config-package-update-upgrade-install)
        ...
   ```

5. Query the merged, machine-readable instance data. First list the top-level keys, then pull one value:

   ```bash
   cloud-init query --list-keys
   cloud-init query v1.local_hostname
   cloud-init query ds.meta_data.instance_id
   ```

   ```text
   _beta_keys
   base64_encoded_keys
   cloud_name
   ...
   cloudinit-lab
   iid-lab-0001
   ```

6. Try to read the raw user-data as a normal user, then as root — note the redaction:

   ```bash
   cloud-init query userdata
   sudo cloud-init query userdata | head -n 3
   ```

   ```text
   <redacted for non-root user> set the --debug flag or run as root
   #cloud-config
   password: labpass
   chpasswd: { expire: false }
   ```

7. Locate the on-disk artifacts:

   ```bash
   ls -l /var/lib/cloud/instance
   ls /run/cloud-init/
   ```

   ```text
   lrwxrwxrwx 1 root root 34 ... /var/lib/cloud/instance -> /var/lib/cloud/instances/iid-lab-0001
   cloud-init.log  ds-identify.log  instance-data.json  instance-data-sensitive.json  result.json  status.json
   ```

**Check your understanding**

- **2a.** Name the five cloud-init boot stages in order, and the systemd unit (or generator) that backs each.
- **2b.** `cloud-init status` shows `status: running`. Which single command blocks until completion, and what does its exit code tell you?
- **2c.** What does `analyze blame` give you that `analyze show` does not?
- **2d.** Which JSON file under `/run/cloud-init/` is safe to expose (world-readable, secrets stripped), and which one is not? Which cloud-init object does `/var/lib/cloud/instance` symlink to, and why is it keyed that way?

---

## Exercise 3 — Author and validate a real cloud-config

Replace the toy `user-data` with a production-shaped one exercising the modules the exam names: `users`/`groups`, `write_files`, `packages`, `runcmd`, `bootcmd`.

1. On the **host**, in `~/cloudinit-lab`, generate a key pair for the new user and capture the public key:

   ```bash
   ssh-keygen -t ed25519 -N '' -f lab_key
   PUBKEY=$(cat lab_key.pub)
   ```

2. Write the richer `user-data`:

   ```bash
   cat > user-data <<EOF
   #cloud-config
   package_update: true
   packages:
     - htop
     - jq

   users:
     - default
     - name: sre
       gecos: SRE Operator
       groups: [sudo, adm]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       shell: /bin/bash
       lock_passwd: false
       ssh_authorized_keys:
         - ${PUBKEY}

   write_files:
     - path: /etc/motd.d/10-lab
       owner: root:root
       permissions: '0644'
       content: |
         *** Provisioned by cloud-init / NoCloud lab ***
     - path: /etc/profile.d/lab_marker.sh
       defer: true
       permissions: '0644'
       content: |
         export LAB_STAGE="written in final stage"

   bootcmd:
     - [ cloud-init-per, once, tag-boot, sh, -c, "echo booted >> /var/log/lab-boot.log" ]

   runcmd:
     - [ systemctl, enable, --now, qemu-guest-agent ]
     - "echo runcmd fired at \$(date -Is) >> /var/log/lab-runcmd.log"
   EOF
   ```

3. **Validate before you ever boot it.** This is the free "quality floor" for cloud-config:

   ```bash
   cloud-init schema --config-file user-data --annotate
   ```

   ```text
   Valid cloud-config: user-data
   ```

4. Prove the validator earns its keep — introduce a typo (`packages` mistyped) and re-run:

   ```bash
   sed 's/^packages:/package:/' user-data > bad-user-data
   cloud-init schema --config-file bad-user-data --annotate
   ```

   ```text
   #cloud-config
   package:          # E1
   ...
   # Errors: -------------
   # E1: Additional properties are not allowed ('package' was unexpected)
   ```

5. Because per-instance modules only run once per `instance-id`, bump it so cloud-init treats the next boot as a brand-new instance:

   ```bash
   sed -i 's/iid-lab-0001/iid-lab-0002/' meta-data
   cloud-localds seed.img user-data meta-data
   ```

6. Reboot the VM (re-run the `qemu-system-x86_64` command from Exercise 1). Once up, verify each module inside the guest:

   ```bash
   id sre
   grep -c '' /etc/motd.d/10-lab
   dpkg -l htop jq | grep '^ii'
   cat /var/log/lab-runcmd.log
   echo "$LAB_STAGE"        # sourced from /etc/profile.d on a fresh login
   ```

   ```text
   uid=1001(sre) gid=1001(sre) groups=1001(sre),4(adm),27(sudo)
   1
   ii  htop  3.0.5-7build2  amd64  interactive processes viewer
   ii  jq    1.6-2.1ubuntu3 amd64  lightweight command-line JSON processor
   runcmd fired at 2026-08-11T14:31:07+00:00
   written in final stage
   ```

**Check your understanding**

- **3a.** In which boot stage does `write_files` run by default? What does `defer: true` change, and which module handles the deferred file?
- **3b.** `runcmd` vs `bootcmd`: which runs once per instance vs on every boot, and in which stage is each *executed*? (Careful — for `runcmd`, "authored" and "executed" are different stages.)
- **3c.** A `runcmd` entry can be a YAML list (`[systemctl, enable, ...]`) or a plain string. What is the execution difference between the two forms?
- **3d.** `cloud-init schema` reported *Valid* but the VM still misbehaved at runtime. Name two classes of error schema validation cannot catch.

---

## Exercise 4 — Datasources, vendor-data, and re-running / debugging

1. Inspect how the datasource was *identified*, then see the configured search order:

   ```bash
   sudo cat /run/cloud-init/ds-identify.log | tail -n 5
   grep -rh datasource_list /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/ 2>/dev/null
   ```

   ```text
   DS_FOUND = NoCloud
   ...
   datasource_list: [ NoCloud, ConfigDrive, ..., None ]
   ```

2. Pin the datasource explicitly with a drop-in (highest-numbered file wins the merge):

   ```bash
   sudo tee /etc/cloud/cloud.cfg.d/99-force-nocloud.cfg <<'EOF'
   datasource_list: [ NoCloud ]
   EOF
   ```

3. Inspect vendor-data — supplied by the platform, not the user. On NoCloud there is none, which is itself the answer:

   ```bash
   cloud-init query vendordata
   ```

   ```text
   <redacted for non-root user> set the --debug flag or run as root
   ```

   ```bash
   sudo cloud-init query vendordata
   ```

   ```text
   null
   ```

4. Re-run **one** module on demand, without a reboot, forcing it regardless of its run-once semaphore:

   ```bash
   sudo cloud-init single --name write_files --frequency always
   ls -l /etc/motd.d/10-lab
   ```

5. Simulate a full re-provision from scratch. `clean` wipes the per-instance cache and logs so the next boot re-runs *every* stage:

   ```bash
   sudo cloud-init clean --logs
   ls /var/lib/cloud/instances/       # the iid-lab-0002 dir is gone
   ```

   ```text
   ls: cannot access '/var/lib/cloud/instances/': No such file or directory
   ```

6. Read the two log files that matter when a boot goes wrong — one is cloud-init's internal trace, the other is the captured stdout/stderr of the scripts it ran:

   ```bash
   sudo tail -n 3 /var/log/cloud-init.log
   sudo tail -n 3 /var/log/cloud-init-output.log
   ```

7. (Optional) Prove you can disable cloud-init entirely — the generator honors this on the *next* boot:

   ```bash
   sudo touch /etc/cloud/cloud-init.disabled
   # or, at the bootloader: append  cloud-init=disabled  to the kernel cmdline
   ```

**Check your understanding**

- **4a.** If vendor-data and user-data both set `packages`, which takes precedence? How does an operator disable vendor-data completely?
- **4b.** You edited `user-data` on the seed but kept the same `instance-id`; on reboot the changes are ignored. Why? Give the two ways to force cloud-init to re-apply.
- **4c.** `cloud-id` prints `nocloud` but you expected `ConfigDrive`. Which file(s) decide the datasource search order, and how does merge precedence among them work?
- **4d.** Contrast `cloud-init single --name X --frequency always` with `cloud-init clean --logs` followed by a reboot. When would you reach for each?

---

## Answers

<details>
<summary><strong>Show solutions — Exercises 1–4</strong></summary>

### Exercise 1

**1a.** `meta-data` and `user-data`. The only strictly required key is `instance-id` in `meta-data`; cloud-init uses its *change* to decide when a machine is a "new instance" and per-instance modules must re-run. `local-hostname` is conventional but optional.

**1b.** The seed filesystem must be labeled **`cidata`** (case-insensitive; `CIDATA` also works). Other ways to seed NoCloud without an ISO: (1) drop the files in a seed directory — `/var/lib/cloud/seed/nocloud/` or `/var/lib/cloud/seed/nocloud-net/`; (2) pass them via the kernel command line, e.g. `ds=nocloud;s=/dev/sr0` or the network form `ds=nocloud-net;s=http://10.0.0.1/seed/`; (3) SMBIOS serial `ds=nocloud`. Any of these lets `ds-identify` select NoCloud.

**1c.** The overlay (`qemu-img create -b …`) is copy-on-write: all guest writes land in `instance.qcow2` while `jammy-server-cloudimg-amd64.img` stays pristine and reusable for the next VM. Booting the base directly would mutate it — and, worse, cloud-init would find its `instance-id` already cached and skip per-instance provisioning on subsequent boots.

**1d.** `-netdev user` is QEMU's user-mode (SLIRP) NAT: the guest can reach outbound, but nothing on the host network can reach *in*. `hostfwd=tcp::2222-:22` punches a port-forward so `host:2222 → guest:22`, letting you `ssh -p 2222 ubuntu@localhost`.

### Exercise 2

**2a.** In order:
| Stage | Backed by |
|---|---|
| **generator** | the `cloud-init-generator` systemd generator (enables/disables the `cloud-init.target`) |
| **local** | `cloud-init-local.service` (runs pre-network; finds local datasources, writes network config) |
| **network** | `cloud-init-network.service` (formerly `cloud-init.service`; runs `cloud_init_modules`) |
| **config** | `cloud-config.service` (runs `cloud_config_modules`) |
| **final** | `cloud-final.service` (runs `cloud_final_modules`) |

**2b.** `cloud-init status --wait` — it blocks (printing dots) until cloud-init reaches a terminal state, then exits **0** on `done`, **non-zero** on `error`/`degraded`. That makes it safe to gate a script or a readiness probe on.

**2c.** `analyze show` prints the full *ordered timeline* — every event grouped by stage with start offset (`@`) and duration (`+`). `analyze blame` re-sorts the same events by **duration descending**, so the slowest modules float to the top — the view you want when profiling a slow boot.

**2d.** `instance-data.json` is world-readable with sensitive values stripped; `instance-data-sensitive.json` is `0600`/root-only and contains the unredacted data (which is why `cloud-init query userdata` redacts for non-root). `/var/lib/cloud/instance` symlinks to `/var/lib/cloud/instances/<instance-id>` — keyed by `instance-id` so each distinct instance keeps its own cache and per-instance semaphores.

### Exercise 3

**3a.** By default `write_files` runs in the **network (init) stage** (`cloud_init_modules`), *before* users, packages, and runcmd. `defer: true` pushes that single file to the **final stage**, handled by the `write_files_deferred` module — useful when the file's content or target depends on something created later (a user's home dir, an installed package's config path).

**3b.** `bootcmd` runs **every boot**, early, in the **network (init) stage**; wrap it in `cloud-init-per once …` if you want once-only semantics. `runcmd` runs **once per instance**. Subtlety: the `runcmd` *module* runs in the **config stage** but only *writes* the script to `/var/lib/cloud/instance/scripts/runcmd`; the `scripts-user` module *executes* it in the **final stage**. So `runcmd` is authored in config, executed in final.

**3c.** A **YAML list** (`[systemctl, enable, --now, qemu-guest-agent]`) is passed as an `argv` array directly to `exec` — **no shell**, so `$VAR`, `|`, `>`, globbing, and `&&` are *not* interpreted. A **plain string** is run through `/bin/sh -c`, so shell features work. That is why the timestamped `echo … >> …` entry is a string (it needs `$(date)` and `>>`) while `systemctl enable` is a list.

**3d.** Schema validation is a *structural/syntactic* check only. It cannot catch: (1) semantic/runtime failures — a package name that doesn't exist, a `runcmd` command that exits non-zero, a bad SSH key, a service that fails to start; (2) logic errors that are valid YAML — wrong path, wrong permissions, a module whose *effect* is not what you intended. It answers "is this well-formed cloud-config?", never "is this correct?"

### Exercise 4

**4a.** **user-data wins.** Vendor-data is applied first and user-data can override it (the merge is per-module, but user-supplied directives take precedence). Disable vendor-data entirely by setting `vendor_data: {enabled: false}` in `/etc/cloud/cloud.cfg` (or a `cloud.cfg.d/` drop-in); an instance's own cloud-config can also opt out.

**4b.** Per-instance modules run **once per `instance-id`**, and the result is cached under `/var/lib/cloud/instances/<instance-id>/`. Same `instance-id` ⇒ cloud-init thinks it already provisioned this machine and skips. Force a re-apply by either (1) **changing `instance-id`** in `meta-data` (cloud-init sees a new instance and re-runs everything — what step 5 does), or (2) running **`cloud-init clean --logs`** and rebooting (wipes the cache/semaphores so the next boot re-runs all stages).

**4c.** `datasource_list` decides the search order, read from `/etc/cloud/cloud.cfg` and every drop-in under `/etc/cloud/cloud.cfg.d/`. Drop-ins are merged in **lexical order**, so a higher-numbered file (e.g. `99-force-nocloud.cfg`) overrides the vendor default (`90_dpkg.cfg`). Pinning the list to a single entry both speeds up `ds-identify` and removes ambiguity when a host could match more than one datasource.

**4d.** `cloud-init single --name X --frequency always` re-runs **one module immediately**, in place, ignoring its run-once semaphore — surgical, no reboot, nothing else re-runs. `cloud-init clean --logs` + reboot is the **full reset**: it deletes the instance cache and logs so *every* stage and module re-executes from a clean slate, as if the machine were freshly provisioned. Use `single` to iterate on one module during development; use `clean` + reboot to validate an end-to-end first-boot exactly as production will see it.

</details>

---

### Sources

- LPI — Exam 305-300 Objectives (353.3): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- cloud-init — Boot stages: <https://docs.cloud-init.io/en/latest/explanation/boot.html>
- cloud-init — NoCloud datasource: <https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html>
- cloud-init — Module reference (`write_files`, `runcmd`, `users_groups`, `bootcmd`, …): <https://docs.cloud-init.io/en/latest/reference/modules.html>
- cloud-init — CLI (`status`, `query`, `analyze`, `schema`, `single`, `clean`): <https://docs.cloud-init.io/en/latest/reference/cli.html>
- cloud-init — Example cloud-config: <https://docs.cloud-init.io/en/latest/reference/examples.html>
- Ubuntu cloud images: <https://cloud-images.ubuntu.com/>