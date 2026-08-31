# LPIC-1 102.6 — Linux as a Virtualization Guest
## Guided Exercises (Exam 102-500, syllabus version 5.0 — weight 1)

> **Objective scope.** Virtual machines vs. containers; IaaS elements (compute instances, block storage, networking); properties that must be made unique when a system is cloned or used as a template; system images; guest integration extensions (guest drivers); `cloud-init`.
> Official objective text: <https://www.lpi.org/our-certifications/exam-102-objectives/> (102.6). Exam-101 objectives, for the companion exam: <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

### Lab environment

| Requirement | Notes |
|---|---|
| One **disposable** Linux guest with `systemd` ≥ 245 | Any hypervisor: KVM/QEMU (libvirt), VMware, VirtualBox, Hyper-V, or a public-cloud instance. Several steps destroy the machine's identity — never run them on a system you care about. |
| `root` / `sudo` | Required from Exercise 2 onward. |
| Packages | `systemd`, `util-linux`, `pciutils`, `dmidecode`, `kmod`, `cloud-init`, `cloud-image-utils` or `genisoimage`/`xorriso`, `jq`, `podman` (or `docker`), `libcap-ng-utils` (`capsh`), `cloud-guest-utils` (`growpart`). |
| Optional but recommended | Shell access to the **hypervisor host** (libvirt) for the hot-plug and seed-ISO blocks. Where host access is impossible, an inspection-only alternative is given. |

Take a snapshot before Exercise 3:

```bash
# on the KVM host
virsh snapshot-create-as --domain lab-guest pre-102-6 --atomic
```

---

## Exercise 1 — Fingerprinting the platform from inside the guest

**Goal:** determine, from the guest alone, *whether* you are virtualized, *by what*, and *how* (full virtualization, paravirtualization, container). This is the first thing you do on any host you did not build.

### Block 1.A — The `systemd` one-liners

1. Ask `systemd` what it thinks it is running on, and inspect the exit status:

   ```bash
   systemd-detect-virt; echo "exit=$?"
   ```

   Expected on a KVM guest:

   ```
   kvm
   exit=0
   ```

   Expected on bare metal:

   ```
   none
   exit=1
   ```

2. Separate the two questions — *am I in a VM?* and *am I in a container?*

   ```bash
   systemd-detect-virt --vm
   systemd-detect-virt --container
   systemd-detect-virt --chroot; echo "chroot exit=$?"
   ```

   On a KVM guest that is **not** containerized:

   ```
   kvm
   none
   chroot exit=1
   ```

3. Get the same information plus the firmware-declared chassis type:

   ```bash
   hostnamectl
   ```

   ```
    Static hostname: lab-guest
          Icon name: computer-vm
            Chassis: vm 🖴
         Machine ID: 4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
            Boot ID: 9c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e
     Virtualization: kvm
   Operating System: Debian GNU/Linux 12 (bookworm)
             Kernel: Linux 6.1.0-18-amd64
       Architecture: x86-64
   ```

4. Write a guard clause you can reuse in provisioning scripts:

   ```bash
   if systemd-detect-virt --quiet --container; then
       echo "container: skip kernel tuning, skip NTP, skip firmware updates"
   elif systemd-detect-virt --quiet --vm; then
       echo "VM: install guest agent, enable virtio, disable host-only services"
   else
       echo "bare metal: enable IPMI/BMC monitoring, firmware update policy applies"
   fi
   ```

> **Q1.** `systemd-detect-virt` returned `none` and exited `1`. Give two distinct scenarios in which this output is *wrong* — the system is in fact virtualized.
> **Q2.** Why does `systemd-detect-virt` deliberately expose the VM answer and the container answer through separate flags instead of a single value? What nesting scenario makes this necessary?
> **Q3.** Which of the three exit codes/values would you rely on in a configuration-management module, and why is parsing `hostnamectl` a worse idea?

### Block 1.B — Firmware (SMBIOS/DMI) evidence

5. Read the DMI tables that the hypervisor's virtual firmware exposes:

   ```bash
   sudo dmidecode -s system-manufacturer
   sudo dmidecode -s system-product-name
   sudo dmidecode -s system-uuid
   sudo dmidecode -s bios-vendor
   ```

   Representative values:

   | Platform | `system-manufacturer` | `system-product-name` |
   |---|---|---|
   | QEMU/KVM (libvirt) | `QEMU` or `Red Hat` | `Standard PC (Q35 + ICH9, 2009)` / `KVM` |
   | VMware ESXi | `VMware, Inc.` | `VMware Virtual Platform` / `VMware20,1` |
   | VirtualBox | `innotek GmbH` | `VirtualBox` |
   | Hyper-V | `Microsoft Corporation` | `Virtual Machine` |
   | Amazon EC2 (Nitro) | `Amazon EC2` | `m5.large` |

6. Read the same data without `root` and without `dmidecode`, straight from sysfs:

   ```bash
   cat /sys/class/dmi/id/sys_vendor
   cat /sys/class/dmi/id/product_name
   cat /sys/class/dmi/id/bios_vendor
   ls -l /sys/class/dmi/id/product_uuid
   ```

   ```
   QEMU
   Standard PC (Q35 + ICH9, 2009)
   SeaBIOS
   -r-------- 1 root root 4096 Aug 26 09:12 /sys/class/dmi/id/product_uuid
   ```

7. Compare the guest's `system-uuid` with the domain UUID the hypervisor assigned:

   ```bash
   # in the guest
   sudo dmidecode -s system-uuid
   # on the KVM host
   virsh domuuid lab-guest
   ```

> **Q4.** `product_name` is world-readable but `product_uuid` is mode `0400`. What is the security reasoning, and which class of cloud tooling depends on that UUID?
> **Q5.** You run `dmidecode` and get `# No SMBIOS nor DMI entry point found`. Name two legitimate virtualization scenarios that produce this, and say how you would identify the platform in each.

### Block 1.C — CPU, clocksource and kernel-ring evidence

8. Look for the CPUID hypervisor-present bit and the vendor leaf:

   ```bash
   grep -o ' hypervisor' /proc/cpuinfo | head -1
   lscpu | grep -Ei 'hypervisor|virtualization|model name'
   ```

   ```
    hypervisor
   Model name:            Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
   Virtualization:        VT-x
   Hypervisor vendor:     KVM
   Virtualization type:   full
   ```

9. Check the clocksource — a paravirtualized clock is proof of guest-side enlightenment:

   ```bash
   cat /sys/devices/system/clocksource/clocksource0/current_clocksource
   cat /sys/devices/system/clocksource/clocksource0/available_clocksource
   ```

   ```
   kvm-clock
   kvm-clock tsc acpi_pm
   ```

10. Read what the kernel decided during early boot:

    ```bash
    sudo dmesg | grep -Ei 'hypervisor|kvm|vmware|xen|hyper-v|virtio' | head -20
    ```

    ```
    [    0.000000] Hypervisor detected: KVM
    [    0.000005] kvm-clock: Using msrs 4b564d01 and 4b564d00
    [    0.000009] kvm-clock: using sched offset of 1443789 cycles
    [    0.360121] virtio_blk virtio2: [vda] 41943040 512-byte logical blocks (21.5 GB/20.0 GiB)
    ```

11. Handle the Xen special case (a Xen PV guest has no DMI at all):

    ```bash
    cat /sys/hypervisor/type      2>/dev/null   # -> xen
    cat /sys/hypervisor/uuid      2>/dev/null
    cat /proc/xen/capabilities    2>/dev/null   # -> control_d only on dom0
    ```

> **Q6.** `lscpu` reports `Virtualization: VT-x` **and** `Hypervisor vendor: KVM` on the same machine. Explain both lines — they are not contradictory. What does each one tell you about what you can do on this host?

---

## Exercise 2 — Guest drivers: paravirtualized devices and integration services

**Goal:** inventory the driver stack that makes a Linux guest fast and manageable, and reproduce the single most common image-migration outage: an initramfs without `virtio`.

### Block 2.A — virtio inventory

1. List the virtio devices on the virtual PCI bus:

   ```bash
   lspci -nn | grep -i -e virtio -e 'red hat'
   ```

   ```
   00:02.0 SCSI storage controller [0100]: Red Hat, Inc. Virtio block device [1af4:1001]
   00:03.0 Ethernet controller [0200]: Red Hat, Inc. Virtio network device [1af4:1000]
   00:05.0 Unclassified device [00ff]: Red Hat, Inc. Virtio memory balloon [1af4:1002]
   00:06.0 Unclassified device [00ff]: Red Hat, Inc. Virtio RNG [1af4:1005]
   00:07.0 Communication controller [0780]: Red Hat, Inc. Virtio console [1af4:1003]
   ```

2. Map devices to loaded modules:

   ```bash
   lsmod | grep -E '^virtio|^vmw|^hv_|^vbox'
   lspci -k -s 00:03.0
   ```

   ```
   virtio_net             57344  0
   virtio_blk             20480  3
   virtio_balloon         24576  0
   virtio_rng             16384  0
   virtio_pci             28672  0
   virtio_ring            32768  5 virtio_blk,virtio_net,virtio_pci,virtio_balloon,virtio_rng
   virtio                 16384  5 virtio_blk,virtio_net,virtio_pci,virtio_balloon,virtio_rng

   00:03.0 Ethernet controller: Red Hat, Inc. Virtio network device
           Subsystem: Red Hat, Inc. Device 0001
           Kernel driver in use: virtio-pci
           Kernel modules: virtio_pci
   ```

3. Confirm the device-naming consequences of the storage driver in use:

   ```bash
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
   ls -l /dev/disk/by-id/ | head
   ```

   ```
   NAME   SIZE TYPE FSTYPE MOUNTPOINTS MODEL
   vda     20G disk
   ├─vda1  19G part ext4   /
   ├─vda2   1K part
   └─vda5  976M part swap  [SWAP]
   ```

4. Verify the entropy source and the balloon:

   ```bash
   cat /sys/devices/virtual/misc/hw_random/rng_available
   cat /sys/devices/virtual/misc/hw_random/rng_current
   grep -E 'MemTotal|MemAvailable' /proc/meminfo
   ```

> **Q7.** The listing shows `/dev/vda`, not `/dev/sda`. Which virtio storage device is in use, and name two capabilities you give up by choosing it over the alternative.
> **Q8.** `virtio_balloon` is loaded. Describe what the host can do to this guest through it, and the failure mode you must plan for in a memory-overcommitted cluster.
> **Q9.** Why does the absence of `virtio_rng` matter specifically at *first boot* of a freshly deployed image?

### Block 2.B — The initramfs trap (do this before you ever convert an image)

5. Inspect which storage/network drivers are actually inside your initramfs:

   ```bash
   # Debian/Ubuntu
   lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'virtio|vmw_pvscsi|hv_storvsc' | sort

   # RHEL/Fedora/SUSE (dracut)
   sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'virtio|vmw_pvscsi|hv_storvsc'
   ```

   ```
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/block/virtio_blk.ko
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/net/virtio_net.ko
   usr/lib/modules/6.1.0-18-amd64/kernel/drivers/virtio/virtio_pci.ko
   ```

6. Force the drivers of *every* hypervisor you might land on into the image:

   ```bash
   # Debian/Ubuntu
   printf '%s\n' virtio_pci virtio_blk virtio_scsi virtio_net vmw_pvscsi vmxnet3 hv_storvsc hv_netvsc \
     | sudo tee -a /etc/initramfs-tools/modules
   sudo update-initramfs -u -k all

   # RHEL/Fedora (host-only mode is the default and is the trap)
   sudo dracut --force --no-hostonly \
     --add-drivers "virtio_pci virtio_blk virtio_scsi virtio_net vmw_pvscsi vmxnet3 hv_storvsc hv_netvsc" \
     /boot/initramfs-$(uname -r).img $(uname -r)
   ```

7. Re-verify, then confirm the root device is referenced by UUID and not by kernel name:

   ```bash
   sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -c virtio
   grep -E '^\s*[^#]' /etc/fstab
   sudo grep -o 'root=[^ ]*' /proc/cmdline
   ```

   ```
   UUID=6d1b0a7c-...  /      ext4  errors=remount-ro 0 1
   root=UUID=6d1b0a7c-9f2e-4a11-8b30-1c7d5e2f8a44
   ```

> **Q10.** A VM image built on VMware boots on ESXi but panics with `VFS: Unable to mount root fs on unknown-block(0,0)` after being imported into KVM. Give the precise cause and the two-command fix (assume you can mount the image with `guestmount` or boot a rescue ISO).
> **Q11.** Why does `root=/dev/sda1` in `/etc/fstab` and the kernel command line make an image non-portable across hypervisors, while `root=UUID=…` survives?

### Block 2.C — Integration services / guest agents

8. Identify and start the agent that matches your platform:

   ```bash
   # KVM/QEMU
   sudo systemctl enable --now qemu-guest-agent
   systemctl is-active qemu-guest-agent
   ls -l /dev/virtio-ports/
   ```

   ```
   active
   lrwxrwxrwx 1 root root 11 Aug 26 09:20 org.qemu.guest_agent.0 -> ../vport1p1
   ```

   ```bash
   # VMware
   sudo systemctl status vmtoolsd
   vmware-toolbox-cmd -v
   vmware-toolbox-cmd stat balloon

   # Hyper-V
   systemctl status hv-kvp-daemon hv-vss-daemon hv-fcopy-daemon
   lsmod | grep hv_

   # VirtualBox
   systemctl status vboxadd vboxadd-service; lsmod | grep vbox
   ```

9. From the **host**, exercise the KVM agent and see that it works with no guest networking:

   ```bash
   virsh qemu-agent-command lab-guest '{"execute":"guest-info"}' | jq -r '.return.version'
   virsh domifaddr lab-guest --source agent
   virsh domfsfreeze lab-guest && virsh domfsthaw lab-guest
   ```

10. Restrict what the host may ask the agent to do:

    ```bash
    # RHEL-family: /etc/sysconfig/qemu-ga
    BLOCK_RPCS=guest-exec,guest-exec-status,guest-file-open,guest-file-read,guest-file-write
    # equivalently, on the command line:
    # /usr/bin/qemu-ga --block-rpcs=guest-exec,guest-file-open
    sudo systemctl restart qemu-guest-agent
    ```

> **Q12.** `qemu-guest-agent` communicates over a virtio-serial port, not over the network. State one operational advantage and one security consequence of that design, and name the specific backup operation that becomes correct only when the agent is installed.

---

## Exercise 3 — Turning a running system into a template (the uniqueness problem)

**Goal:** enumerate and neutralize everything that must not be identical across clones. This is the heart of objective 102.6.

> ⚠️ These steps deliberately destroy this machine's identity. Snapshot first. After Block 3.A your current SSH session may survive, but a reboot is required for regeneration.

### Block 3.A — `/etc/machine-id` and the D-Bus machine ID

1. Record the current identity:

   ```bash
   cat /etc/machine-id
   ls -l /var/lib/dbus/machine-id
   systemd-id128 machine-id
   ls -d /var/log/journal/*/
   ```

   ```
   4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
   lrwxrwxrwx 1 root root 15 Jun  4 12:00 /var/lib/dbus/machine-id -> /etc/machine-id
   4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11
   /var/log/journal/4f1a2c9e6b0d4a1f8e2c7b5d3a9f0e11/
   ```

2. Check whether the DHCP client identity is derived from it (systemd-networkd):

   ```bash
   networkctl status 2>/dev/null | grep -Ei 'duid|client'
   grep -rE 'ClientIdentifier|DUIDType' /etc/systemd/network/ /usr/lib/systemd/network/ 2>/dev/null
   ```

3. Reset it the documented way — **truncate, do not delete**:

   ```bash
   sudo truncate -s 0 /etc/machine-id
   sudo rm -f /var/lib/dbus/machine-id
   sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
   ls -l /etc/machine-id
   ```

   ```
   -rw-r--r-- 1 root root 0 Aug 26 09:31 /etc/machine-id
   ```

4. (Optional, to see regeneration without rebooting the template) On a *clone*, after first boot:

   ```bash
   cat /etc/machine-id      # a new 32-hex-digit value
   systemd-analyze | head -1
   systemctl status systemd-firstboot.service
   ```

> **Q13.** Why is `truncate -s 0 /etc/machine-id` preferred over `rm /etc/machine-id`? Give the two distinct reasons — one about `systemd` semantics and one about read-only `/etc` images.
> **Q14.** Two clones of the same template boot on the same L2 segment and repeatedly steal each other's IP address, even though their MAC addresses differ. Explain the mechanism and name the file responsible.
> **Q15.** What is the relationship between `/etc/machine-id` and `/var/lib/dbus/machine-id`, and what breaks if the two hold *different* values?

### Block 3.B — SSH host keys

5. Record the host key fingerprints before wiping them:

   ```bash
   for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
   ```

   ```
   256 SHA256:8Kj2s9dQ... root@lab-guest (ED25519)
   3072 SHA256:pQ0z4Xn... root@lab-guest (RSA)
   256 SHA256:vT7m1Lc... root@lab-guest (ECDSA)
   ```

6. Remove them and confirm regeneration behaviour:

   ```bash
   sudo rm -f /etc/ssh/ssh_host_*
   systemctl list-unit-files | grep -E 'ssh.*keygen|sshd-keygen'
   ```

   ```
   sshd-keygen@.service          static
   ssh-host-keys-migration.service enabled
   ```

7. Force regeneration now (what the clone's first boot will do for you):

   ```bash
   sudo ssh-keygen -A
   for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
   ```

8. Have `cloud-init` own this instead, if the image is cloud-managed:

   ```bash
   sudo tee /etc/cloud/cloud.cfg.d/99-hostkeys.cfg >/dev/null <<'EOF'
   ssh_deletekeys: true
   ssh_genkeytypes: [ed25519, rsa]
   EOF
   ```

> **Q16.** A team clones a template with the host keys baked in. Describe the concrete attack this enables, and why `StrictHostKeyChecking` will *not* warn the users.
> **Q17.** `ssh-keygen -A` and `cloud-init`'s `ssh_deletekeys` both solve this. When is each the right tool?

### Block 3.C — The rest of the identity surface

9. Sweep for leftover per-machine state:

   ```bash
   # network identity
   sudo grep -rIl -e HWADDR -e 'mac-address' /etc/sysconfig/network-scripts/ \
        /etc/NetworkManager/system-connections/ 2>/dev/null
   ls -l /etc/udev/rules.d/70-persistent-net.rules 2>/dev/null
   sudo ls -l /var/lib/NetworkManager/*.lease /var/lib/dhcp/*.leases 2>/dev/null

   # entropy and credentials
   sudo ls -l /var/lib/systemd/random-seed /var/lib/systemd/credential.secret

   # storage identity (fatal when two clones attach to one host)
   sudo blkid
   cat /etc/iscsi/initiatorname.iscsi 2>/dev/null

   # agent/CM identity
   ls /etc/salt/minion_id /var/lib/puppet/ssl 2>/dev/null
   ```

10. Change duplicated filesystem UUIDs on a cloned disk (run from a rescue environment, filesystem **unmounted**):

    ```bash
    # ext4
    sudo tune2fs -U random /dev/vdb1
    # XFS (log must be clean)
    sudo xfs_admin -U generate /dev/vdb1
    # swap
    sudo mkswap -U random /dev/vdb5
    # then fix the references
    sudo blkid /dev/vdb1
    # update /etc/fstab and the kernel cmdline / GRUB accordingly
    ```

11. Clear history and logs the template should not ship:

    ```bash
    sudo rm -rf /var/log/journal/*      # journald recreates per new machine-id
    sudo truncate -s 0 /var/log/wtmp /var/log/lastlog /var/log/btmp
    sudo rm -f /root/.bash_history /home/*/.bash_history
    sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/instance
    ```

> **Q18.** Two clones of the same disk image are attached to the same hypervisor host. `mount UUID=6d1b0a7c-… /mnt` mounts the *wrong* one. Explain what UUID uniqueness guarantees actually are, and why `PARTUUID=` does not save you here either.
> **Q19.** Name three items in the sweep above that are *not* covered by `cloud-init clean` and must be handled explicitly.

### Block 3.D — Automating the whole sweep

12. Inspect what a purpose-built tool considers "identity" — this list is a study aid in itself:

    ```bash
    virt-sysprep --list-operations | head -40
    ```

    ```
    abrt-data * Remove the crash data generated by ABRT
    bash-history * Remove the bash history in the guest
    ...
    dhcp-client-state * Remove DHCP client leases
    machine-id * Remove the local machine ID
    ssh-hostkeys * Remove the SSH host keys in the guest
    ssh-userdir * Remove ".ssh" directories in the guest
    udev-persistent-net * Remove udev persistent net rules
    ...
    ```

13. Run it against a **shut-down** domain:

    ```bash
    virsh shutdown lab-guest
    sudo virt-sysprep -d lab-guest \
      --enable machine-id,ssh-hostkeys,dhcp-client-state,udev-persistent-net,logfiles,bash-history \
      --hostname template
    ```

14. Or, for a cloud image, the `cloud-init` equivalent:

    ```bash
    sudo cloud-init clean --logs --seed --machine-id
    sudo shutdown -h now
    ```

---

## Exercise 4 — `cloud-init`: the standard first-boot contract

**Goal:** read an instance's provisioning state, author and inject a `NoCloud` datasource, validate it before it costs you a boot, and re-run it deterministically.

Reference: <https://docs.cloud-init.io/en/latest/>

### Block 4.A — Inspect the state of a provisioned instance

1. Overall status and per-stage timing:

   ```bash
   cloud-init status --long
   cloud-init analyze blame | head -10
   ```

   ```
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   last_update: Tue, 26 Aug 2026 09:12:41 +0000
   detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]

   -- Boot Record 01 --
        00.84300s (init-network/config-growpart)
        00.51100s (modules-config/config-apt-configure)
        00.19200s (init-network/config-ssh)
   ```

2. Which datasource won, and what did it provide?

   ```bash
   cloud-init query --all | jq '{ds: .v1.platform, id: .v1.instance_id, region: .v1.region, hostname: .v1.local_hostname}'
   cloud-init query ds.meta_data 2>/dev/null | head
   sudo grep -E 'Datasource|datasource' /var/log/cloud-init.log | tail -5
   sudo cat /run/cloud-init/ds-identify.log | tail -20
   ```

3. Walk the on-disk state machine:

   ```bash
   ls -l /var/lib/cloud/
   ls -l /var/lib/cloud/instance          # symlink -> instances/<instance-id>
   ls /var/lib/cloud/instance/sem/        # per-instance semaphores
   ls /var/lib/cloud/sem/                 # per-once semaphores
   cat /var/lib/cloud/instance/user-data.txt
   ```

   ```
   /var/lib/cloud/instance -> /var/lib/cloud/instances/iid-lab-102-6-0001
   config_scripts_users_groups.once
   config_ssh.once
   config_growpart.once
   ```

4. Map stages to units (note the 24.3+ rename):

   ```bash
   systemctl list-units --all 'cloud-*'
   systemd-analyze critical-chain cloud-final.service | head -12
   ```

   ```
   cloud-init-local.service     Local stage   (datasource discovery, network config)
   cloud-init-network.service   Network stage (formerly cloud-init.service: disks, mounts, users, ssh)
   cloud-config.service         Config stage  (packages, apt, timezone, ntp)
   cloud-final.service          Final stage   (runcmd, user scripts, phone-home)
   ```

> **Q20.** Order the four stages and state, for each, the one thing you must *not* try to do in it. Why can `runcmd` reach the network but `bootcmd` cannot be assumed to?
> **Q21.** `/var/lib/cloud/instance` is a symlink whose target is named after the `instance-id`. Derive from that fact alone the mechanism by which `cloud-init` decides to re-run per-instance modules.

### Block 4.B — Author and inject a `NoCloud` datasource

5. Write `meta-data`:

   ```yaml
   # meta-data
   instance-id: iid-lab-102-6-0001
   local-hostname: guest-lab
   ```

6. Write `user-data` (note: the `#cloud-config` line is mandatory and must be line 1):

   ```yaml
   #cloud-config
   hostname: guest-lab
   fqdn: guest-lab.lab.internal
   prefer_fqdn_over_hostname: true

   users:
     - name: sre
       gecos: Lab operator
       # Debian/Ubuntu: sudo | RHEL/Fedora/SUSE: wheel
       groups: [sudo, adm]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       shell: /bin/bash
       lock_passwd: true
       ssh_authorized_keys:
         - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceMe sre@bastion

   ssh_pwauth: false
   ssh_deletekeys: true
   ssh_genkeytypes: [ed25519, rsa]

   write_files:
     - path: /etc/sysctl.d/60-lab.conf
       owner: root:root
       permissions: "0644"
       content: |
         vm.swappiness = 10
         net.ipv4.tcp_slow_start_after_idle = 0

   growpart:
     mode: auto
     devices: ["/"]
     ignore_growroot_disabled: false
   resize_rootfs: true

   package_update: true
   packages:
     - qemu-guest-agent
     - jq

   bootcmd:
     - [ cloud-init-per, once, mkdir-data, mkdir, -p, /srv/data ]

   runcmd:
     - [ systemctl, enable, --now, qemu-guest-agent ]
     - [ sysctl, --system ]

   final_message: "cloud-init $version finished at $timestamp, after $UPTIME seconds; datasource $datasource"
   ```

7. Validate **before** spending a boot on it:

   ```bash
   cloud-init schema --config-file user-data --annotate
   ```

   ```
   Valid schema user-data
   ```

   Now break it on purpose and observe the diagnostic:

   ```bash
   sed -i 's/^packages:/package:/' user-data
   cloud-init schema --config-file user-data --annotate
   ```

   ```
   #cloud-config
   ...
   package:		# E1
   ...
   # E1: Additional properties are not allowed ('package' was unexpected)
   ```

   Restore it: `sed -i 's/^package:/packages:/' user-data`

8. Build the seed medium (the filesystem **label must be `CIDATA`**):

   ```bash
   # simplest, if cloud-image-utils is installed
   cloud-localds seed.iso user-data meta-data

   # explicit equivalent
   genisoimage -output seed.iso -volid CIDATA -joliet -rock user-data meta-data
   # or
   xorriso -as mkisofs -o seed.iso -V CIDATA -J -r user-data meta-data

   blkid seed.iso
   ```

   ```
   seed.iso: UUID="2026-08-26-09-40-00-00" LABEL="CIDATA" TYPE="iso9660"
   ```

9. Attach it and boot:

   ```bash
   virt-install --name lab-guest2 --memory 2048 --vcpus 2 \
     --disk /var/lib/libvirt/images/lab-guest2.qcow2,bus=virtio \
     --disk /var/lib/libvirt/images/seed.iso,device=cdrom \
     --import --os-variant debian12 --network network=default,model=virtio --noautoconsole
   ```

   *No hypervisor host?* Seed the running system directly instead:

   ```bash
   sudo mkdir -p /var/lib/cloud/seed/nocloud-net
   sudo cp user-data meta-data /var/lib/cloud/seed/nocloud-net/
   sudo cloud-init clean --logs
   sudo reboot
   ```

> **Q22.** Why must `#cloud-config` be the *first* line, and what happens if the file starts with `---` instead?
> **Q23.** What is the difference between the `NoCloud` and `NoCloudNet` (`nocloud-net`) variants, and which kernel command-line parameter selects the latter?
> **Q24.** You put `groups: [sudo]` in a template used on both Debian and RHEL. What is the observable failure on RHEL, and how do you write this portably?

### Block 4.C — Re-run, debug, constrain

10. Re-run one module without rebooting:

    ```bash
    sudo cloud-init single --name cc_write_files --frequency always
    sudo cloud-init single --name cc_runcmd --frequency always
    ```

11. Force a full re-provision:

    ```bash
    sudo cloud-init clean --logs --seed
    sudo cloud-init init --local && sudo cloud-init init
    sudo cloud-init modules --mode=config && sudo cloud-init modules --mode=final
    cloud-init status --long
    ```

12. Disable `cloud-init` permanently in a golden image that is *not* cloud-managed:

    ```bash
    sudo touch /etc/cloud/cloud-init.disabled
    # or, at the kernel command line: cloud-init=disabled
    ```

13. Stop `cloud-init` from rewriting your network configuration:

    ```bash
    sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null <<'EOF'
    network: {config: disabled}
    EOF
    ```

14. Pin the datasource so `ds-identify` does not probe (saves seconds of boot time and removes a class of surprise):

    ```bash
    sudo tee /etc/cloud/cloud.cfg.d/90-datasource.cfg >/dev/null <<'EOF'
    datasource_list: [ NoCloud, None ]
    EOF
    ```

> **Q25.** `cloud-init clean` without `--seed` leaves the instance re-runnable but the *same* instance. Explain what `--seed` removes and why omitting it is usually correct on a real cloud instance.
> **Q26.** A module you added to `cloud_final_modules` never runs, and `cloud-init status` says `done`. List the three checks you perform, in order.

---

## Exercise 5 — Virtual machines vs. containers, demonstrated

**Goal:** show empirically that a container shares the host kernel while a VM does not, and distinguish an *application* container from a *system* container.

### Block 5.A — Detection from inside

1. Start an application container and interrogate it:

   ```bash
   podman run --rm -it --name probe registry.access.redhat.com/ubi9/ubi:latest bash
   ```

   Inside:

   ```bash
   systemd-detect-virt --container ; echo "exit=$?"
   cat /proc/1/cgroup
   tr '\0' '\n' < /proc/1/environ | grep -i '^container='
   ls -la /run/.containerenv /.dockerenv 2>/dev/null
   uname -r
   ```

   ```
   podman
   exit=0
   0::/
   container=podman
   -rw-r--r-- 1 root root 0 Aug 26 09:50 /run/.containerenv
   6.1.0-18-amd64
   ```

2. Exit and compare with the host:

   ```bash
   uname -r
   systemd-detect-virt --container
   ```

   ```
   6.1.0-18-amd64
   none
   ```

> **Q27.** The kernel release string is byte-identical inside and outside the container. State the single architectural fact this proves, and derive from it two things a container **cannot** do that a VM can.
> **Q28.** `systemd-detect-virt` inside a container running on a KVM guest prints `podman` for `--container` and `kvm` for `--vm`. What is the practical name for this arrangement, and which of the two answers should a "should I tune `vm.swappiness`?" script trust?

### Block 5.B — Build the isolation by hand

3. Look at the namespaces the kernel is currently maintaining:

   ```bash
   lsns -o NS,TYPE,NPROCS,PID,COMMAND | head
   ls -l /proc/self/ns/
   ```

   ```
   4026531835 cgroup     241     1 /sbin/init
   4026531836 pid        241     1 /sbin/init
   4026531837 user       241     1 /sbin/init
   4026531840 net        241     1 /sbin/init
   4026532191 mnt          2  1842 /usr/lib/systemd/systemd-udevd
   ```

4. Create an unprivileged "container" with nothing but `util-linux`:

   ```bash
   unshare --user --map-root-user --mount --pid --fork --uts --ipc --mount-proc bash
   ```

   Inside:

   ```bash
   id
   hostname mini-container && hostname
   ps -ef
   readlink /proc/self/ns/pid
   cat /proc/self/status | grep -E 'CapEff|Seccomp|NoNewPrivs'
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root),65534(nogroup)
   mini-container
   UID  PID  PPID  C STIME TTY  TIME     CMD
   root   1     0  0 09:55 pts/0 00:00:00 bash
   root   9     1  0 09:55 pts/0 00:00:00 ps -ef
   pid:[4026532285]
   CapEff: 000001ffffffffff
   NoNewPrivs: 1
   ```

5. Prove the "root" is not the host's root:

   ```bash
   touch /etc/proof-of-root      # -> Permission denied
   exit
   grep -E '^(uid|gid) ' /proc/self/uid_map 2>/dev/null
   ```

6. Inspect the resource half of the story (cgroups v2):

   ```bash
   cat /sys/fs/cgroup/cgroup.controllers
   systemd-run --scope -p MemoryMax=64M -p CPUQuota=20% --user bash -c 'cat /sys/fs/cgroup/$(awk -F: "{print \$3}" /proc/self/cgroup)/memory.max'
   ```

> **Q29.** Namespaces and cgroups solve two different problems. Name each problem, and say which of the two a `--memory=512m` flag manipulates.
> **Q30.** Inside the `unshare` session `CapEff` shows a full capability set, yet `touch /etc/proof-of-root` fails. Explain this apparent contradiction precisely.

### Block 5.C — Application container vs. system container

7. Run a **system** container — a full init inside a namespace:

   ```bash
   sudo systemd-nspawn --directory=/var/lib/machines/deb12 --boot --network-veth
   # from the host:
   machinectl list
   machinectl shell deb12
   ```

   ```
   MACHINE CLASS     SERVICE        OS     VERSION ADDRESSES
   deb12   container systemd-nspawn debian 12      169.254.31.7…
   ```

8. Contrast the process trees:

   ```bash
   # application container
   podman run --rm registry.access.redhat.com/ubi9/ubi:latest ps -ef
   # system container
   machinectl shell deb12 /bin/ps -ef | head
   ```

> **Q31.** Define *application container* and *system container* in one sentence each, and give the deciding question you ask to choose between a system container and a full VM.

---

## Exercise 6 — IaaS building blocks: compute instance, block storage, networking

**Goal:** operate the three primitives every IaaS platform exposes, from the guest side.

### Block 6.A — The instance metadata service

1. Query the link-local metadata endpoint. **EC2 (IMDSv2, token-required):**

   ```bash
   TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone
   ```

   **OpenStack / config-drive-compatible:**

   ```bash
   curl -s http://169.254.169.254/openstack/latest/meta_data.json | jq '{uuid, name, availability_zone}'
   ```

2. If there is no metadata service (private KVM, `NoCloud`), read the same abstractions locally:

   ```bash
   jq '.v1' /run/cloud-init/instance-data.json
   cloud-init query v1.instance_id v1.platform v1.subplatform
   ```

3. Confirm the route that makes `169.254.169.254` reachable:

   ```bash
   ip route get 169.254.169.254
   ```

   ```
   169.254.169.254 via 10.0.0.1 dev enp1s0 src 10.0.0.42 uid 1000
   ```

> **Q32.** IMDSv2 requires a `PUT` to obtain a token and enforces a low IP TTL on the response. Which specific vulnerability class does that defeat, and why did IMDSv1 not?
> **Q33.** Why is `169.254.169.254` a link-local address rather than a routable one, and what does that imply for a guest running its own NAT or container overlay?

### Block 6.B — Block storage: attach, discover, grow

4. Baseline the block layer:

   ```bash
   lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS,SERIAL
   df -hT /
   ```

5. Hot-attach a volume from the **host**:

   ```bash
   qemu-img create -f qcow2 /var/lib/libvirt/images/data.qcow2 10G
   virsh attach-disk lab-guest /var/lib/libvirt/images/data.qcow2 vdb \
     --subdriver qcow2 --targetbus virtio --persistent
   ```

6. Observe discovery in the guest — with `virtio-blk` no rescan is needed:

   ```bash
   sudo dmesg | tail -5
   lsblk /dev/vdb
   ```

   ```
   [ 8123.441] virtio_blk virtio4: [vdb] 20971520 512-byte logical blocks (10.7 GB/10.0 GiB)
   NAME SIZE TYPE MOUNTPOINTS
   vdb   10G disk
   ```

   For a `virtio-scsi` or VMware `pvscsi` backend, discovery is manual:

   ```bash
   ls /sys/class/scsi_host/
   echo "- - -" | sudo tee /sys/class/scsi_host/host2/scan
   lsblk
   ```

7. Format, label and mount persistently by UUID:

   ```bash
   sudo mkfs.xfs -L data /dev/vdb
   sudo blkid /dev/vdb
   echo "UUID=$(sudo blkid -s UUID -o value /dev/vdb) /srv/data xfs defaults,nofail,x-systemd.device-timeout=10s 0 2" \
     | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload && sudo mkdir -p /srv/data && sudo mount -a
   findmnt /srv/data
   ```

8. Grow the **root** volume online — the exact sequence a cloud instance performs on resize:

   ```bash
   # host: enlarge the backing device
   virsh blockresize lab-guest vda 40G

   # guest: 1) re-read the size (virtio-scsi/SCSI only; virtio-blk is automatic)
   echo 1 | sudo tee /sys/class/block/sda/device/rescan

   # guest: 2) grow the partition (moves the GPT backup header, updates the table)
   sudo growpart /dev/vda 1
   sudo partx -u /dev/vda

   # guest: 3) grow the filesystem
   sudo xfs_growfs /            # XFS: online only, cannot shrink
   # sudo resize2fs /dev/vda1   # ext4
   df -hT /
   ```

9. Confirm `cloud-init` would have done steps 2–3 for you:

   ```bash
   grep -n -A4 'growpart' /etc/cloud/cloud.cfg
   ls /var/lib/cloud/instance/sem/ | grep -i growpart
   ```

> **Q34.** Why is `nofail` non-negotiable in the `/etc/fstab` entry of a *detachable* cloud volume? Describe the exact boot failure it prevents.
> **Q35.** Distinguish "block storage volume" from "instance store / ephemeral disk" in an IaaS platform, and name one workload that belongs on each.
> **Q36.** You grew the disk and ran `xfs_growfs /`, but `df` still shows the old size. Which of the three steps was skipped, and how do you confirm it from `lsblk` output alone?

### Block 6.C — Networking

10. Inspect the interface as the platform presents it:

    ```bash
    ip -br link show
    ip -br addr show
    ip route show default
    cat /sys/class/net/enp1s0/address
    ethtool -i enp1s0 | head -3
    ip link show enp1s0 | grep -o 'mtu [0-9]*'
    ```

    ```
    enp1s0  UP  52:54:00:9a:3f:12 <BROADCAST,MULTICAST,UP,LOWER_UP>
    enp1s0  UP  10.0.0.42/24 fe80::5054:ff:fe9a:3f12/64
    default via 10.0.0.1 dev enp1s0 proto dhcp src 10.0.0.42 metric 100
    driver: virtio_net
    mtu 1450
    ```

11. Pin the interface name to the MAC so a PCI-topology change cannot rename it:

    ```bash
    sudo tee /etc/systemd/network/10-uplink.link >/dev/null <<'EOF'
    [Match]
    MACAddress=52:54:00:9a:3f:12

    [Link]
    Name=uplink0
    EOF
    sudo update-initramfs -u   # or: dracut --force
    ```

12. Or the opposite, for a portable image — disable predictable naming entirely:

    ```bash
    # append to the kernel command line
    net.ifnames=0 biosdevname=0
    ```

> **Q37.** The MAC begins with `52:54:00`. What does that prefix tell you, and why does a template that hard-codes a MAC in a NetworkManager connection profile fail on the first clone?

---

<details>
<summary><strong>Answers</strong> — expand only after attempting the exercises</summary>

### Exercise 1

**Q1.** Two independent failure modes:
1. **Nested or "invisible" virtualization with hidden enlightenments.** A hypervisor can be configured to hide itself: with libvirt/QEMU, `<feature policy='disable' name='hypervisor'/>` (or `-cpu host,-hypervisor`) clears the CPUID hypervisor-present bit, and the DMI strings can be overridden with `<sysinfo type='smbios'>` to impersonate a Dell or HP server. Anti-detection is a supported configuration (used for GPU passthrough and licence-locked software), so `none` is not proof of bare metal.
2. **A paravirtualized platform with no DMI and no CPUID leaf** — classically a Xen PV guest, and on other architectures a KVM guest with no SMBIOS. Detection there requires `/sys/hypervisor/type` or the device-tree. Historically also relevant: running inside a `chroot` on a virtualized host, where `--vm` may still answer correctly but tooling that only checks one axis is fooled.

The operational takeaway: use detection to *optimize*, never to enforce a security boundary.

**Q2.** Because the two are orthogonal and routinely stacked. A container on a KVM guest on bare metal is the standard cloud arrangement (managed Kubernetes = pods in containers, on VMs, on physical hosts). A single scalar value would have to pick one answer and would lie about the other. `--vm` answers "is there a hypervisor beneath my kernel?"; `--container` answers "is my PID 1 the kernel's PID 1?" — different questions with different consequences. `systemd-detect-virt` with no flag reports the **container** answer preferentially when both apply, precisely because the container boundary is the more restrictive one for the code that is asking.

**Q3.** Use the **exit status** with `--quiet`: `systemd-detect-virt --quiet --container`. It is a stable, documented contract (0 = detected, 1 = not detected), needs no parsing, and does not change with locale or `systemd` version. `hostnamectl` output is human-oriented: field labels are translatable, ordering is not guaranteed, the icon glyph varies, and the `Virtualization:` line is simply omitted on bare metal — so a naive `grep`/`awk` silently produces an empty string rather than a defined answer.

**Q4.** `product_uuid` is the SMBIOS System UUID — on a hypervisor it equals the domain/instance UUID, and on many platforms it is the value used as (or derived into) the **instance identity** that entitlement, licensing and metadata services trust. Leaking it to unprivileged local processes hands them a machine-identifying token; on Xen-based EC2, `cloud-init`'s `DataSourceEc2` derives the instance ID from `/sys/hypervisor/uuid`, and licence managers key on the DMI UUID. `product_name` is merely a model string, so it stays world-readable. The dependent tooling: cloud metadata/datasource discovery, subscription and licence managers, and inventory/CMDB agents.

**Q5.** Two legitimate cases:
1. **Xen PV guest** — there is no emulated firmware at all, so no SMBIOS entry point exists. Identify via `cat /sys/hypervisor/type` (`xen`), `/sys/hypervisor/uuid`, and the presence of `xen_blkfront`/`xen_netfront` in `lsmod`. `/proc/xen/capabilities` containing `control_d` means you are in **dom0**, not a guest.
2. **Non-x86 architecture (aarch64, ppc64le, s390x)** or a container. On ARM/POWER the platform is described by a **device tree**: `cat /proc/device-tree/hypervisor/compatible`, `cat /proc/device-tree/model`. On s390x use `/proc/sysinfo` (`read_values -s`). Inside a container, `/sys/class/dmi` is typically not mounted at all — identify with `systemd-detect-virt --container` and `/proc/1/environ`.

**Q6.** They describe two different layers:
- `Virtualization: VT-x` is a **CPU feature exposed to you**: the `vmx` flag is present in your virtual CPU, meaning this guest can itself run a hypervisor — i.e. **nested virtualization** is enabled by the parent. You could run KVM, VirtualBox or a Kubernetes KubeVirt workload *inside* this VM.
- `Hypervisor vendor: KVM` / `Virtualization type: full` is the **layer above you**: the CPUID hypervisor leaf identifies KVM as your parent, and `full` (as opposed to `para`) says the platform presents a complete emulated machine rather than requiring a PV-aware kernel entry path.

Practical consequence: you can build VMs here (nested), but expect a measurable performance penalty at the second level, and check that the parent set `kvm_intel.nested=1`.

### Exercise 2

**Q7.** `/dev/vda` means **`virtio-blk`** (each disk is its own virtio PCI device, driven by `virtio_blk`). Choosing it over **`virtio-scsi`** costs you:
1. **SCSI command passthrough** — no `sg`/`SG_IO`, so no persistent reservations (a hard requirement for shared-disk clusters), no direct pass-through of a physical LUN's SCSI semantics, and no tape/changer devices.
2. **Device density and hot-plug economics** — `virtio-blk` consumes one PCI slot per disk (roughly 25–30 disks before you exhaust the bus and need extra PCIe root ports), whereas one `virtio-scsi` HBA addresses thousands of LUNs. You also lose the richer `virtio-scsi` feature set (multiqueue per LUN with mature `UNMAP`/discard and WWN reporting, and `/dev/disk/by-id` serial visibility).

`virtio-blk` is chosen for the shortest I/O path and lowest per-request latency — it is the right default for a single root disk.

**Q8.** Through `virtio_balloon` the host can **inflate the balloon**: it asks the guest kernel to allocate pages and hand their physical frames back to the host, which then reuses them for other guests. Deflating returns them. This is how a hypervisor overcommits memory without swapping at the host level, and it is how `virsh setmem --live` shrinks a running guest.

The failure mode to plan for: **guest-side OOM under host memory pressure.** The guest's own `MemTotal` does not shrink to reflect the ballooned-away memory in the way applications expect — a JVM sized from `MemTotal` at start-up, or any process that has already touched its heap, will be pushed into reclaim and then into the OOM killer while the host believes it "freed" memory. Mitigations: enable `deflate-on-oom` (`<memballoon model='virtio'><... />` with the QEMU `deflate-on-oom=on` property) so the balloon shrinks before the OOM killer fires; set a hard `<memory>` floor per guest; do not overcommit latency-sensitive tiers at all; and monitor with `virsh dommemstat` (which requires the balloon stats polling period to be set: `virsh dommemstat <dom> --period 5`).

**Q9.** At first boot the image performs exactly the operations that consume the most entropy and cannot be deferred: **generating SSH host keys** (`ssh-keygen -A`), generating a `machine-id`, seeding TLS/PKI material, and initialising the kernel CRNG before `getrandom(2)` will return. On a freshly cloned image `/var/lib/systemd/random-seed` has been (correctly) removed, and a VM has almost no entropy sources — no real disk seek timing, no keyboard, no genuine interrupt jitter. Without `virtio_rng` feeding the host's entropy in, boot can **block for minutes** at the key-generation step, and — historically worse — implementations that fell back to weak sources produced **predictable keys across a fleet of clones**. `virtio_rng` (plus `rngd` bound to `/dev/hwrng`) removes both problems.

**Q10.** **Cause:** the image's initramfs was built in `dracut`'s default **host-only** mode on VMware, so it contains only `vmw_pvscsi`/`mptspi` and not `virtio_blk`/`virtio_pci`. Booted on KVM, the kernel reaches the point of mounting the real root, has no driver for the virtio block controller, finds no device for the root UUID, and panics with `unknown-block(0,0)`.

**Fix** (from a rescue boot or `guestmount`, chrooted into the image):

```bash
dracut --force --no-hostonly --add-drivers "virtio_pci virtio_blk virtio_scsi virtio_net" \
  /boot/initramfs-$(uname -r).img $(uname -r)
grub2-mkconfig -o /boot/grub2/grub.cfg     # Debian/Ubuntu: update-initramfs -u -k all && update-grub
```

The durable prevention is to build golden images with `--no-hostonly` (or `hostonly=no` in `/etc/dracut.conf.d/`), and on Debian `MODULES=most` in `/etc/initramfs-tools/initramfs.conf`.

**Q11.** Kernel device names are **assignment-order artifacts of the driver stack**, not properties of the storage. The same disk is `/dev/sda` behind an emulated IDE/SATA or SCSI controller, `/dev/vda` behind `virtio-blk`, `/dev/xvda` behind Xen `blkfront`, and `/dev/nvme0n1` behind an NVMe controller — and even within one driver the letter depends on probe order, which changes when you add or reorder controllers. Moving the image to another hypervisor changes the driver, and therefore the name, and the reference dangles.

A **filesystem UUID** is written *inside the superblock*, so it travels with the data regardless of which driver presents the block device. `udev` builds `/dev/disk/by-uuid/<uuid>` from the superblock contents after probing whatever devices exist, so the mapping is re-derived correctly on every boot on every platform. (`LABEL=` has the same property but is not unique by construction; `PARTUUID=` lives in the GPT and survives reformatting but not re-partitioning.)

**Q12.** *Advantage:* the channel is **out-of-band** — a virtio-serial port between QEMU and the guest. It works when the guest has no IP address, when the network configuration is broken, when a firewall rule locked you out, and during early boot and shutdown. It also needs no listening port, so it adds no network attack surface and works identically in an air-gapped network.

*Security consequence:* the channel is authenticated only by "you are the hypervisor". Anyone with libvirt/QEMU access on the host holds an **unauthenticated root-equivalent execution path into the guest** — `guest-exec` runs arbitrary commands, `guest-file-read`/`guest-file-write` read and write arbitrary files, `guest-set-user-password` resets credentials. There is no guest-side consent, no logging you control, and no way to require a key. Hence step 10: block the dangerous RPCs (`--block-rpcs=guest-exec,guest-file-read,…`) on any guest whose host administrators are not already inside its trust boundary. This is also why a compromised hypervisor is game over for every guest on it.

*The backup operation:* **application-consistent (quiesced) snapshots.** Without the agent, a snapshot is *crash-consistent* — it captures whatever was on disk mid-write, and a database restored from it must run recovery and may lose in-flight transactions. With the agent, `virsh domfsfreeze` invokes `FIFREEZE` on every mounted filesystem (flushing the page cache and pausing writes) — and, via `/etc/qemu/fsfreeze-hook`, lets you quiesce the database itself — so the snapshot is taken at a consistent point and `domfsthaw` resumes I/O. VMware's equivalent is `open-vm-tools`' VSS/sync driver path; on Hyper-V it is `hv_vss_daemon`.

### Exercise 3

**Q13.** Two reasons, both documented in `machine-id(5)`:
1. **`systemd` semantics.** An empty `/etc/machine-id` is a defined state meaning "uninitialized" — `systemd` provisions a fresh ID into it at early boot and, crucially, treats the boot as a **first boot** (`ConditionFirstBoot=yes`), so `systemd-firstboot.service`, preset application and first-boot units run as intended for a newly deployed instance. A deleted file mostly produces the same result on modern `systemd`, but the empty file is the state the tooling and the manual page contract on.
2. **Read-only `/etc`.** If `/etc` is read-only (immutable/golden images, `ostree`, appliance builds), `systemd` cannot *create* a file — but it **can bind-mount** a transient `/run/machine-id` over an existing zero-length file. Keeping the empty file present is therefore the only way the mechanism works at all on a read-only root. Delete the file and such a system boots without a machine ID, breaking `journald`, D-Bus and anything that calls `sd_id128_get_machine()`.

**Q14.** `systemd-networkd`'s default DHCP client identifier is an RFC 4361 **DUID derived from `/etc/machine-id`** (`ClientIdentifier=duid`, `DUIDType=vendor`). The DHCP server keys its lease database on the **client identifier (option 61)** in preference to the MAC address when option 61 is present. Two clones that shipped with the *same* `/etc/machine-id` therefore present the *same* client ID with different MACs — the server sees one client that appears to have changed hardware, hands both machines the same lease, and the address ping-pongs between them as each renews.

The file responsible is **`/etc/machine-id`**. The fixes: truncate it in the template (Block 3.A), or set `ClientIdentifier=mac` in the `[DHCPv4]` section of the `.network` file. Note this is a `systemd-networkd` default; ISC `dhclient` and NetworkManager may key on the MAC instead, which is why the symptom appears on some distributions and not others from the identical image.

**Q15.** `/var/lib/dbus/machine-id` is the historical D-Bus machine identifier, predating `systemd`. On modern distributions it is a **symlink to `/etc/machine-id`** so that both subsystems agree on one value — `dbus-uuidgen --ensure` and `systemd-machine-id-setup` both maintain the same 32-hex-digit ID.

If they hold different values, you get a split identity: `sd_id128_get_machine()` and `dbus_get_local_machine_id()` return different answers, so any application that keys per-machine state, licence activation, or D-Bus session addressing off "the machine ID" sees two machines on one host. Symptoms range from duplicated per-machine configuration (GNOME/keyring state, telemetry deduplication) to D-Bus autolaunch failures. This is exactly why the template procedure removes the file and recreates the **symlink** rather than truncating both independently.

**Q16.** The attack is a **fleet-wide man-in-the-middle on SSH**. Every clone presents the identical host key, so the private key is present on every VM built from that template. Anyone who obtains root on *one* clone — or who simply downloads the template/AMI if it was ever published — holds the private key that authenticates *all* of them, and can stand up a rogue server (or ARP/DNS-spoof an existing address) that clients accept as genuine, capturing passwords, agent-forwarded credentials and session content.

`StrictHostKeyChecking` does not warn because it is working correctly and there is nothing anomalous to report: on first contact with each new host the client sees a key it has not recorded and, at the default `ask`, prompts once — a prompt operators approve routinely. Where the fingerprint is already in `known_hosts` from a sibling clone under a shared name or IP, the key *matches*, so no warning is possible at all. The check verifies key continuity, not key uniqueness or key secrecy — and a leaked key satisfies continuity perfectly.

**Q17.**
- **`ssh-keygen -A`** is the imperative, immediate fix: generate any missing host key type, now, on this machine. Use it when you are hand-preparing a system, repairing a clone that already booted with duplicate keys, or writing a first-boot script for a system with no `cloud-init` (an image-build step, a `systemd` `ExitType`/`ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key` oneshot unit, a Packer provisioner).
- **`ssh_deletekeys: true` / `ssh_genkeytypes:`** is the declarative, per-instance policy for cloud-managed images: `cloud-init`'s `cc_ssh` module deletes any keys present in the image and regenerates them at each *new instance*, then optionally reports the fingerprints to the console and to the datasource (`phone_home`, EC2 console output) so the operator can verify them out-of-band on first login — which closes the trust-on-first-use gap that `ssh-keygen -A` alone leaves open.

Use `cloud-init` when the platform provides a datasource; use `ssh-keygen -A` when it does not, and use `virt-sysprep --enable ssh-hostkeys` when sanitizing a stopped disk image offline.

**Q18.** A filesystem UUID guarantees uniqueness only **by generation convention** — `mkfs` draws a random (v4) UUID with negligible collision probability — not by enforcement. Nothing in the kernel, `udev` or `blkid` prevents two block devices from carrying identical superblock UUIDs, and **cloning a disk image copies the superblock verbatim**, so the "unique" identifier is duplicated by construction.

When two devices share a UUID, `udev` creates a single `/dev/disk/by-uuid/<uuid>` symlink and the **last device to be probed wins** — probe order varies with hot-plug timing, so the winner is not stable across boots. `mount UUID=…` resolves through that symlink and mounts whichever device won the race. Worse failure modes follow: a mirrored LVM PV UUID collision, an `fsck` run against the wrong device, or a root filesystem that mounts from the *other* clone's disk.

`PARTUUID=` does not help because it is stored in the **GPT partition entry**, which a block-level clone copies just as faithfully as the superblock. The same applies to `PARTLABEL=`, `LABEL=`, LVM PV/VG UUIDs, and mdadm array UUIDs. The only fixes are to re-stamp the identifiers on the clone (`tune2fs -U random`, `xfs_admin -U generate`, `mkswap -U random`, `pvchange -u`, `xfs_admin`/`sgdisk -G` for the GPT disk GUID) and to update every reference (`/etc/fstab`, `/etc/crypttab`, the kernel command line, GRUB), or to avoid attaching two clones to one host in the first place.

**Q19.** `cloud-init clean` removes `/var/lib/cloud` (instance state, semaphores, cached datasource) and, with flags, the logs, the seed and the machine-id. It does **not** touch:
1. **SSH host keys** in `/etc/ssh/` — regeneration is a *boot-time module* (`cc_ssh` with `ssh_deletekeys`), not part of `clean`. If the image never boots with `cloud-init` enabled, the keys ship.
2. **Filesystem / partition / LVM UUIDs** — `tune2fs -U`, `xfs_admin -U`, `mkswap -U`, `pvchange -u`. `cloud-init` has no concept of storage identity collisions.
3. **`systemd`'s random seed and credential secret** — `/var/lib/systemd/random-seed`, `/var/lib/systemd/credential.secret`.

Also outside its scope: shell histories and `~/.ssh/authorized_keys` left by the builder; `/etc/iscsi/initiatorname.iscsi`; configuration-management identities (`/etc/salt/minion_id`, `/var/lib/puppet/ssl`, Chef `client.pem`); monitoring-agent host identifiers (Zabbix, Datadog, Wazuh); `/etc/udev/rules.d/70-persistent-net.rules`; NetworkManager profiles with a pinned `mac-address`; Kerberos keytabs; TPM-sealed secrets and LUKS headers; subscription-manager/entitlement certificates; and `/var/log/*` in general. `virt-sysprep --list-operations` is the closest thing to a canonical checklist — read it as one.

### Exercise 4

**Q20.** In order:

| Stage | Unit | Runs | Must **not** |
|---|---|---|---|
| **Local** | `cloud-init-local.service` (`Before=network-pre.target`) | Datasource discovery from local media (`ds-identify`), writes network configuration | Assume **any** networking exists — it runs precisely so that networking can be configured. No package installs, no HTTP. |
| **Network** | `cloud-init-network.service` (named `cloud-init.service` before 24.3) | Fetches remote user-data, disk setup, partitioning, `growpart`, mounts, users, groups, SSH keys | Assume the **package manager metadata** is refreshed or repositories configured — that is the next stage. |
| **Config** | `cloud-config.service` | `apt`/`yum` configuration, package installation, timezone, NTP, locale, Puppet/Chef/Ansible bootstrap | Assume **user scripts** have run, or that services declared by installed packages are already started. |
| **Final** | `cloud-final.service` (`After=multi-user.target` semantics) | `runcmd`, `scripts-user`, `phone_home`, `final_message`, `power_state` | Assume it is early — the system is essentially up, so anything needing to precede a service start is already too late. |

`runcmd` executes in the **Final** stage, long after the Network stage brought interfaces up and the Config stage configured repositories — so DNS, routes and package repos are all available. `bootcmd` executes very early in the **Network** stage (and on *every* boot, not once), before mounts and, on some datasources, before the network is guaranteed to be usable; it exists for things like partition-table fixes and `cloud-init-per`-guarded one-shots, not for network calls.

**Q21.** `cloud-init` compares the `instance-id` it reads from the datasource on this boot against the one recorded in the state directory that `/var/lib/cloud/instance` points at.
- **Same `instance-id`** → the symlink target already exists and its `sem/` directory already contains `config_<module>.once` semaphores → every module with the default `per-instance` frequency is skipped. This is what makes a normal reboot cheap and idempotent.
- **Different `instance-id`** (fresh launch, or you changed `meta-data`) → no such directory exists, so `cloud-init` creates `instances/<new-id>/`, repoints the symlink, and finds an empty `sem/` → all `per-instance` modules run again.

Hence the two ways to force re-provisioning: change the `instance-id` in `meta-data`, or delete the state with `cloud-init clean`. `per-always`/`per-boot` modules ignore `sem/` entirely; `per-once` modules record into `/var/lib/cloud/sem/` (outside the instance directory) and therefore survive an instance-id change.

**Q22.** `cloud-init` accepts several user-data formats on the *same* channel — cloud-config YAML, `#!` shell scripts, `#include` URL lists, `#cloud-boothook`, gzipped payloads, and multipart MIME. It distinguishes them by sniffing the **first line** (or the MIME `Content-Type` for multipart), exactly the way the kernel dispatches on a shebang. `#cloud-config` is that magic marker, and it must be the literal first line — no leading blank line, no BOM, no comment above it.

If the file begins with `---`, `cloud-init` finds no recognized marker. It classifies the payload as `text/x-not-multipart` and **silently ignores it**: the boot succeeds, `cloud-init status` reports `done`, and none of your configuration is applied. `/var/log/cloud-init.log` records something like `Unhandled non-multipart (text/x-not-multipart) userdata`. This is the single most common "my user-data did nothing" cause — and the reason step 7's `cloud-init schema --config-file` is worth the ten seconds it takes.

**Q23.** Both are the `NoCloud` datasource; they differ in where the seed comes from and, consequently, in which stage they can complete:
- **`NoCloud`** reads the seed from **local media**: a filesystem labelled `CIDATA`/`cidata` (the ISO from step 8, or a partition on a vFAT stick), or the local directory `/var/lib/cloud/seed/nocloud/`. It resolves entirely in the **Local** stage, before networking — which is why it can supply the network configuration itself.
- **`NoCloudNet`** (`nocloud-net`) fetches `user-data`/`meta-data` over **HTTP(S)** from a URL you supply, so it necessarily needs the network up first and completes in the **Network** stage. Its local seed directory is `/var/lib/cloud/seed/nocloud-net/`.

The kernel command line selects it with the `ds=` parameter:

```
ds=nocloud-net;s=http://10.0.0.5/seed/
ds=nocloud;s=/dev/sr0          # local variant, for comparison
```

(The `seedfrom` key in `meta-data`, and `-smbios type=1,serial=ds=nocloud-net;s=http://…` on the QEMU command line, are equivalent injection routes.)

**Q24.** On RHEL/CentOS/Fedora there is no `sudo` group — the administrative group is `wheel`, enabled through `/etc/sudoers`' `%wheel` rule. `cc_users_groups` tries to add the user to a group that does not exist: the user **is created** but the group assignment fails, so `sre` exists, can log in with its SSH key, and has **no sudo access at all**. The failure is logged in `/var/log/cloud-init.log` and does not abort the boot, so `cloud-init status` still reports `done` — a silently half-provisioned instance.

Portable forms, in increasing robustness:
1. Rely on the built-in abstraction and grant sudo explicitly, letting the distro default group come from `/etc/cloud/cloud.cfg`'s `default_user`:
   ```yaml
   users:
     - default
     - name: sre
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       ssh_authorized_keys: [ "ssh-ed25519 AAAA… sre@bastion" ]
   ```
   The `sudo:` key writes `/etc/sudoers.d/90-cloud-init-users` directly and does not depend on any group existing.
2. Create the group first, so membership is guaranteed:
   ```yaml
   groups: [ sre-admins ]
   users:
     - name: sre
       primary_group: sre
       groups: [ sre-admins ]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
   ```
3. Keep one user-data per distro family, or template it — but never hard-code `sudo`/`wheel` in an image claimed to be portable.

**Q25.** `cloud-init clean` removes `/var/lib/cloud` — the instance state directory, the semaphores, and the **cached datasource** — so the next boot re-detects its datasource and re-runs every module. `--logs` additionally removes `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`. `--seed` additionally removes `/var/lib/cloud/seed`, i.e. the **locally injected seed data itself** (`nocloud`/`nocloud-net` directories).

Omitting `--seed` is usually correct on a real cloud instance because there is no local seed to remove: the user-data lives in the platform's metadata service, and `cloud-init` will fetch it again on the next boot. Removing `/var/lib/cloud/seed` there is a no-op at best. Include `--seed` when you are **building a template from a seeded lab VM** — otherwise your golden image ships the previous instance's user-data (including its SSH authorized keys and any credential you wrote into it) and every future clone silently re-applies it. For the same reason, `--machine-id` (newer releases) is a template-build flag, not an operations flag.

**Q26.** In order, cheapest first:
1. **Is the module *listed*, in the right list, and spelled with its module name?** `grep -n cc_yourmodule /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg`. A `/etc/cloud/cloud.cfg.d/` drop-in that redefines `cloud_final_modules` **replaces** the list rather than appending to it — the most common cause. Confirm the effective, merged configuration with `cloud-init query --all` and by reading the log's `config-…` run lines rather than trusting the file you edited.
2. **Did its semaphore already exist?** `ls /var/lib/cloud/instance/sem/ | grep yourmodule`. A `per-instance` module that ran on a previous boot of the *same* instance-id is skipped by design and reports nothing. Force it with `cloud-init single --name cc_yourmodule --frequency always`, or set `frequency: always` in the module's list entry (`[cc_yourmodule, always]`).
3. **Did the stage run at all, and did the module raise?** `grep -iE 'cc_yourmodule|Traceback|WARNING|ERROR' /var/log/cloud-init.log` and `cloud-init analyze show | grep -A2 yourmodule`. Note that `cloud-init status` reporting `done` says the *stages* completed — individual module exceptions are logged as warnings and do **not** change the top-level status unless they are fatal. `cloud-init status --long` surfaces recorded errors in newer releases; `/var/log/cloud-init-output.log` holds the module's own stdout/stderr.

If all three pass and the module still does nothing, verify the user-data actually reached the instance (`cat /var/lib/cloud/instance/user-data.txt`) and that its first line is `#cloud-config` — see Q22.

### Exercise 5

**Q27.** It proves that **the container shares the host's kernel** — there is exactly one kernel, and the container is a set of namespaced, cgroup-limited processes running on it, not a separate machine. A VM boots its own kernel, so `uname -r` inside it is independent of the host's.

Two consequences, i.e. things a container cannot do:
1. **Run a different kernel, or a different kernel version/OS family.** You cannot run a Windows container on a Linux kernel, cannot run a 6.6 kernel workload on a 4.18 host, and cannot use a kernel feature (a cgroup controller, an `io_uring` opcode, an eBPF program type, a filesystem) that the host kernel lacks — the "userspace is CentOS 7" illusion does not extend to the kernel ABI.
2. **Load kernel modules, or modify global kernel state, independently.** `insmod`/`modprobe` affects the *host*; non-namespaced `sysctl`s (`vm.*`, most of `kernel.*`) are global; `/dev/mem`, `kexec`, the system clock (`CLOCK_REALTIME` is not namespaced), and the kernel log buffer are host-wide. Hence the Exercise 1 guard clause: skip kernel tuning and NTP inside containers, because attempting them either fails or silently affects every other tenant on the host.

The corollary is the security one: a kernel vulnerability is a container escape but not, by itself, a VM escape — the VM boundary is enforced by hardware virtualization plus the hypervisor, a much smaller and differently shaped attack surface than the ~400-call Linux syscall interface.

**Q28.** The arrangement is **nested isolation** — colloquially "containers on VMs", the standard topology of every managed Kubernetes service (pods inside containers, inside cloud VM worker nodes, inside the provider's physical fleet).

A `vm.swappiness` script must trust the **container** answer. `vm.swappiness` is a **non-namespaced** kernel tunable: writing it inside the container either fails with `EPERM` (read-only `/proc/sys` in a normal container) or, in a `--privileged` container, succeeds and changes it **for the host kernel and every other container on that node** — a cross-tenant side effect. The correct behaviour is exactly the branch order in Exercise 1 step 4: test `--container` first and bail out, and only reach the VM branch when PID 1 is the kernel's.

The general rule: the **innermost** boundary determines what you may do, so detection logic must check the innermost first.

**Q29.**
- **Namespaces solve *visibility / naming*.** They partition the kernel's global identifier spaces so that a process sees only its own slice: PID, mount, network, UTS (hostname/domainname), IPC, user (UID/GID mapping), cgroup, and time namespaces. A namespaced process cannot *see* or *name* resources outside its namespace — it cannot signal a PID it cannot see, cannot access a mount it does not have, cannot reach a network interface in another netns.
- **Cgroups solve *quantity / accounting*.** They bound and account for how much of a shared resource a set of processes may consume: memory, CPU time and weight, block I/O bandwidth and IOPS, PIDs, and devices. A cgroup does not hide anything — it throttles and caps.

`--memory=512m` manipulates a **cgroup** — specifically `memory.max` (cgroup v2) or `memory.limit_in_bytes` (v1) in the container's cgroup, as shown by step 6's `systemd-run -p MemoryMax=64M`.

The pair is the point: namespaces without cgroups gives you an isolated view with no resource protection (one container can OOM the node); cgroups without namespaces gives you resource fairness with full mutual visibility. A container is the conjunction, plus capability dropping, seccomp and LSM policy.

**Q30.** `CapEff: 000001ffffffffff` is genuine — inside a **user namespace** you hold the full capability set, but those capabilities are **scoped to that namespace**. A capability is only meaningful against a resource whose owning user namespace you have the capability *in*.

`/etc` is on a filesystem mounted in — and owned by — the **initial** user namespace, and its inode is owned by the *real, host* UID 0. Your "root" is host UID 1000 mapped to 0 inside (`/proc/self/uid_map` shows `0 1000 1`). When the kernel checks permission to write `/etc`, it asks: does this process have `CAP_DAC_OVERRIDE` *in the user namespace that owns this filesystem's superblock*? It does not — its capabilities exist only in the child namespace — so the check falls back to ordinary DAC against the mapped identity, and `touch /etc/proof-of-root` returns `EPERM`.

Inside namespace-owned resources the capabilities are real: you *can* set the hostname (UTS namespace is owned by your user namespace), mount a `tmpfs`, create network interfaces in a new netns, and chown files whose ownership falls inside your ID map. This is precisely the mechanism that makes **rootless containers** (`podman` as a non-root user) safe and useful — and it is why `CapEff` alone is never a sufficient answer to "am I privileged?"; the question is always "privileged *with respect to which namespace*?".

**Q31.**
- **Application container:** a container whose payload is a **single application process tree with no init system**, packaged with just its runtime dependencies in a layered OCI image, designed to be immutable, disposable and horizontally replicated — PID 1 is the application itself (nginx, a JVM, a Go binary), lifecycle is `run to exit`, and logs go to stdout/stderr. This is the Docker/Podman/Kubernetes model.
- **System container:** a container that boots a **full init system (`systemd`, `openrc`) and a complete userland**, behaving like a lightweight long-lived machine you can log into, run multiple services in, and manage with normal system tooling — LXC/LXD, `systemd-nspawn`, OpenVZ. `machinectl list` in step 7 exists precisely because these are "machines" to the host.

**The deciding question between a system container and a VM:** *does this workload require a kernel of its own?* Concretely — does it need a different kernel version or a non-Linux OS; does it load kernel modules or use non-namespaced kernel features; does it need a hard security boundary against a hostile tenant (where a kernel LPE must not become an escape); does it need independent kernel tuning, its own clock discipline, live migration, or hardware passthrough? If **yes** to any, it needs a VM. If **no** — you want the density, the ~0 boot time and the shared page cache — a system container is the cheaper correct answer. (The middle ground exists too: Kata Containers, Firecracker microVMs and gVisor give an OCI-compatible interface over a per-workload kernel, buying the VM boundary at container ergonomics.)

### Exercise 6

**Q32.** IMDSv2 defeats **SSRF (Server-Side Request Forgery)** and, by extension, the reflected-proxy/open-redirect variants of it.

Under IMDSv1 the metadata service answered a plain unauthenticated `GET http://169.254.169.254/…`. Any application on the instance that could be coaxed into fetching an attacker-supplied URL — a webhook, an image thumbnailer, a PDF renderer, a misconfigured reverse proxy, a URL-preview feature — would fetch the metadata endpoint on the attacker's behalf and return the body, including the instance's **IAM role credentials** at `/latest/meta-data/iam/security-credentials/<role>`. That single-GET shape is what made it exploitable, and it is the mechanism behind several large cloud breaches.

IMDSv2 breaks it with two changes:
1. **A `PUT` is required to obtain the session token**, and the token must then be echoed in an `X-aws-ec2-metadata-token` header. Nearly every SSRF primitive can only issue a `GET` (and generally cannot set arbitrary headers), so the attacker cannot even acquire a token.
2. **The token response carries IP TTL = 1** (and the service refuses `X-Forwarded-For`-bearing requests). A packet with TTL 1 cannot cross a router — so if a *proxy or container NAT hop* forwards the request outward, the response dies in transit. This specifically kills the "reverse proxy on the instance relays to the metadata service" and "container escape via the host's routing" variants.

Operationally: enforce `HttpTokens=required` on every instance (`aws ec2 modify-instance-metadata-options`), and set `HttpPutResponseHopLimit=1` on hosts that do not need containers to reach the IMDS — or `2` when they do, deliberately.

**Q33.** `169.254.0.0/16` is the IPv4 **link-local** range (RFC 3927). By definition, packets to a link-local destination are never forwarded by a router — they are valid only on the directly attached L2 segment. The metadata service uses it for three reasons: it needs a **fixed, well-known address usable before the instance knows anything about its own network**; it must be identical across every VPC, subnet and tenant without colliding with any customer address space (any RFC 1918 choice would collide with someone); and its non-routability is itself the security property — the endpoint is intrinsically unreachable from off the host, and the "server" is in fact the hypervisor or the local virtual switch intercepting the packet, not a real host on the wire.

Implications for a guest running its own NAT or overlay:
- **Containers and nested VMs must be given an explicit path.** A container in its own netns behind a bridge/NAT has no link-local route to `169.254.169.254`; either you deliberately provide one (Docker's default bridge does forward it — which is exactly the exposure IMDSv2's hop limit addresses) or you block it. The security default should be to **block container access to the IMDS** (`iptables -I FORWARD -d 169.254.169.254 -j DROP`, or a CNI network policy) and inject credentials properly instead — IRSA/Workload Identity, or a credential proxy that enforces per-pod identity.
- **Do not SNAT or proxy it.** Traffic to a link-local address that transits a NAT or an on-host reverse proxy is precisely the SSRF-relay pattern of Q32, and the IMDSv2 hop limit will drop it anyway.
- **Do not assume the route exists.** On multi-homed instances or with custom routing tables, verify with `ip route get 169.254.169.254`; if it is missing, the datasource lookup fails and `cloud-init` falls through to `DataSourceNone` with a long timeout.

**Q34.** Without `nofail`, the mount is treated as **required for boot**. If the volume is detached (deliberately, or because the platform failed to reattach it, or because it was moved to another instance), `systemd`'s generated `srv-data.mount` unit has a `Requires=` on a device unit that never appears; the unit fails after the device timeout, `local-fs.target` fails, and the system **drops into emergency mode demanding the root password on the console** — on a headless cloud instance with no console password set, that is an unbootable machine reachable only by attaching the root disk to a rescue instance. This is the single most common self-inflicted cloud outage from `/etc/fstab`.

`nofail` marks the mount non-essential: `local-fs.target` no longer depends on it, boot proceeds, and the filesystem is mounted if and when the device appears. `x-systemd.device-timeout=10s` bounds the additional wait (the default is 90 s per device, which otherwise adds 90 s to every boot when the volume is absent). For a volume that legitimately arrives late, add `x-systemd.automount` so the mount is triggered on first access rather than at boot. The corollary rule: **only the root filesystem and, arguably, `/var` belong in `fstab` without `nofail` on a cloud instance.**

**Q35.**
- **Block storage volume** (EBS, Cinder, Persistent Disk, Azure Managed Disk): a **network-attached, independently-lifecycled** virtual block device. It survives instance stop/start and instance termination (subject to `DeleteOnTermination`), can be detached and reattached to a different instance, can be snapshotted and restored, is typically replicated for durability, and its performance is provisioned (IOPS/throughput tiers) and bounded by the network path. Latency is higher and more variable than local media.
- **Instance store / ephemeral disk**: **physically local** NVMe/SSD attached to the host the instance runs on. It offers the lowest latency and highest raw throughput available, costs nothing extra, and is **destroyed** when the instance stops, hibernates, terminates, or is live-migrated/recovered onto different hardware. There is no snapshot, no reattach, and — importantly — a *stop/start*, not just a termination, loses it.

Workload placement:
- **Block volume:** a **PostgreSQL/MySQL data directory** — anything where durability across an instance lifecycle, point-in-time snapshots, and the ability to reattach to a replacement instance are the requirements.
- **Instance store:** a **Kafka/Elasticsearch/Cassandra data directory in a replicated cluster**, a build cache or CI scratch space, `/tmp`, a database's temporary/spill area, or a caching tier (Varnish, Redis with replicas) — workloads that already replicate at the application layer and value latency over per-node durability. Also correct for `swap`.

**Q36.** The skipped step is **(2), growing the partition** — `growpart /dev/vda 1` plus `partx -u`. The disk got bigger, but partition 1 still ends where it did, so the filesystem is already at the size of its container and `xfs_growfs` legitimately reports nothing to do (`data blocks changed from X to X` or simply no change).

Confirming from `lsblk` alone: the **disk row's `SIZE` exceeds the sum of its partition rows**, leaving unallocated space at the end.

```
NAME   SIZE TYPE MOUNTPOINTS
vda     40G disk          <-- the device grew
└─vda1  20G part /        <-- the partition did not
```

After `growpart /dev/vda 1; partx -u /dev/vda` the partition row reads `40G` while `df` still shows 20 G — that is the state where `xfs_growfs /` (or `resize2fs /dev/vda1`) is finally meaningful.

Two related traps worth knowing: on a GPT disk the **backup header sits at the old end of the device** and must be relocated (`growpart` and `sgdisk -e` do this; a hand-edited partition table will make the kernel complain about a corrupt GPT), and if the partition is not the last one on the disk there is no adjacent free space at all — you must add a new partition and extend via LVM instead. Note also the asymmetry: **XFS grows online and never shrinks**; ext4 grows online and shrinks only when unmounted.

**Q37.** `52:54:00` is the OUI **QEMU/KVM assigns to virtio (and emulated) NICs by default** — libvirt generates addresses in `52:54:00:xx:xx:xx` with the last three octets random. Seeing it tells you immediately: this is a QEMU/KVM guest, and the address is **locally administered and hypervisor-assigned**, not burned into hardware. (Compare `00:50:56` / `00:0c:29` for VMware, `08:00:27` for VirtualBox, `00:15:5d` for Hyper-V, `02:…` for AWS ENIs — the OUI is a fast platform fingerprint in its own right, complementing Exercise 1.)

A template that hard-codes the MAC in a NetworkManager profile fails on the first clone because **the hypervisor assigns each clone a new, random MAC** (it must — two guests with the same MAC on one L2 segment break switching outright). The profile's `[ethernet] mac-address=52:54:00:9a:3f:12` is a **match condition**: NetworkManager activates that connection only on an interface whose permanent address equals it. On the clone no interface matches, the profile is never activated, and the instance boots **with no IP address and no default route** — unreachable, with the only diagnosis path being the hypervisor console. The same trap exists in `ifcfg-*` files with `HWADDR=`, in `/etc/udev/rules.d/70-persistent-net.rules`, and in a `.link` file whose `[Match] MACAddress=` no longer matches.

The template-safe forms:
- Drop `mac-address` from the profile entirely and match on the **interface name** or on nothing at all (`connection.multi-connect`, or a catch-all `[match] interface-name=en*`).
- Remove `/etc/udev/rules.d/70-persistent-net.rules` — `virt-sysprep --enable udev-persistent-net` does exactly this.
- If you want a *stable name* across hardware changes, pin by name from a property that survives cloning (PCI path) rather than by MAC, or disable predictable names altogether with `net.ifnames=0 biosdevname=0` and accept `eth0`.
- Let `cloud-init` write the network configuration at first boot from the datasource, which is MAC-aware *at runtime* and therefore always correct — and disable it (`network: {config: disabled}`) only when you have taken over that responsibility deliberately.

Note the tension with step 11 of the exercise: pinning `Name=uplink0` by `MACAddress=` is the right answer for a **long-lived, individually-managed VM** whose PCI topology may change, and the *wrong* answer for a **template**. Know which artifact you are building.

</details>

---

## Sources

- LPI — LPIC-1 Exam 102-500 Objectives, v5.0, objective 102.6: <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — LPIC-1 Exam 101-500 Objectives, v5.0: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `systemd` — `machine-id(5)`: <https://www.freedesktop.org/software/systemd/man/latest/machine-id.html>
- `systemd` — `systemd-machine-id-setup(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html>
- `systemd` — `systemd-detect-virt(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html>
- `systemd` — `systemd.link(5)` and `systemd.network(5)` (`ClientIdentifier=`, `DUIDType=`): <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `systemd` — `systemd-nspawn(1)` and `machinectl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html>
- cloud-init documentation (Canonical) — datasources, boot stages, modules, `NoCloud`: <https://docs.cloud-init.io/en/latest/>
- cloud-init — module reference (`cc_ssh`, `cc_growpart`, `cc_users_groups`, `cc_runcmd`): <https://docs.cloud-init.io/en/latest/reference/modules.html>
- libvirt — Domain XML format (memballoon, virtio devices, `sysinfo`): <https://libvirt.org/formatdomain.html>
- libvirt — `virt-sysprep(1)`, guestfs tools: <https://libguestfs.org/virt-sysprep.1.html>
- QEMU — Guest Agent protocol reference: <https://www.qemu.org/docs/master/interop/qemu-ga.html>
- OASIS — Virtual I/O Device (VIRTIO) Specification v1.2: <https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html>
- Linux kernel documentation — namespaces overview (`namespaces(7)`), `user_namespaces(7)`, `capabilities(7)`: <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- Linux kernel documentation — Control Group v2: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- Linux kernel documentation — Hyper-V guest drivers: <https://docs.kernel.org/virt/hyperv/overview.html>
- `open-vm-tools` (VMware/Broadcom, open source): <https://github.com/vmware/open-vm-tools>
- `dracut` documentation (host-only mode, `--add-drivers`): <https://man7.org/linux/man-pages/man8/dracut.8.html>
- IETF RFC 3927 — Dynamic Configuration of IPv4 Link-Local Addresses: <https://www.rfc-editor.org/rfc/rfc3927>
- IETF RFC 4361 — Node-specific Client Identifiers for DHCPv4: <https://www.rfc-editor.org/rfc/rfc4361>
- AWS — Instance Metadata Service Version 2 (IMDSv2): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- OpenStack — Metadata service: <https://docs.openstack.org/nova/latest/admin/metadata-service.html>