# LPIC‑1 — 102.2 Install a boot manager
## Guided exercises (production depth)

**Exam:** LPI 101‑500 (LPIC‑1 v5.0) · **Objective 102.2** · **Weight:** 3.13
**Official objectives:** https://www.lpi.org/our-certifications/exam-101-objectives/

---

### Lab requirements and safety

Every destructive step in this material happens **inside a throwaway loop‑back disk image or a disposable virtual machine**. Never run `grub-install`, `dd` to a boot sector, or `parted` against the disk your workstation boots from.

| Requirement | Notes |
|---|---|
| A Linux VM you can break | Debian 12/13, Ubuntu 22.04+, Fedora 39+, or openSUSE. Snapshot it first. |
| Root access | All commands prefixed `#` require root (`sudo -i`). |
| Packages | `grub2-common`/`grub-common`, `grub-pc-bin` (Debian) or `grub2-pc-modules` (Fedora), `util-linux` ≥ 2.37, `parted`, `gdisk`, `efibootmgr` (UEFI hosts), `xxd`/`bsdextrautils`. |
| Console access | For Exercises 8 and 9 you must reach the GRUB menu — VM console, IPMI/serial, or physical keyboard. SSH is not enough. |

**Conventions used below**

* `#` → command run as root · `$` → unprivileged · `grub>` → the GRUB command shell.
* Distribution split: Debian/Ubuntu use `grub-*` binaries and `/boot/grub/`; Red Hat/Fedora/SUSE use `grub2-*` binaries and `/boot/grub2/`. Where they differ, both are shown.
* Outputs are representative. Yours will differ in UUIDs, kernel versions and device names — that is the point of the questions.

---

## Exercise 1 — Establish which boot path your system actually uses

Before touching a boot loader you must know *which* boot loader is running and *how* the firmware reaches it. BIOS/CSM and UEFI are different code paths with different failure modes, and `grub-install` behaves differently on each.

1. Ask the kernel whether the firmware handed it EFI runtime services:

   ```bash
   # [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
   UEFI
   ```

2. Confirm from the kernel ring buffer, which records the handoff at boot:

   ```bash
   # dmesg | grep -iE 'efi|bios' | head -5
   [    0.000000] efi: EFI v2.70 by EDK II
   [    0.000000] efi: ACPI=0x7f9de000 ACPI 2.0=0x7f9de014 SMBIOS=0x7f9cc000
   [    0.000000] efi: Remapping runtime services memory map
   ```

3. Identify the running kernel and the command line the boot loader passed to it:

   ```bash
   $ uname -r
   6.1.0-18-amd64
   $ cat /proc/cmdline
   BOOT_IMAGE=/boot/vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro quiet
   ```

4. Locate the GRUB directory and the generated configuration in use:

   ```bash
   # ls -l /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null
   -r--r--r-- 1 root root 7412 Aug 20 09:14 /boot/grub/grub.cfg
   # readlink -f /boot/grub2/grub.cfg 2>/dev/null
   /boot/efi/EFI/fedora/grub.cfg
   ```

5. Ask GRUB's own probe tooling what it thinks about `/boot`:

   ```bash
   # grub-probe --target=device /boot
   /dev/vda2
   # grub-probe --target=fs /boot
   ext2
   # grub-probe --target=fs_uuid /boot
   a1b2c3d4-0000-4444-8888-aabbccddeeff
   # grub-probe --target=drive /boot
   (hd0,gpt2)
   ```

**Check your understanding**

* **Q1.1** — Why is the presence of `/sys/firmware/efi` a reliable test, and what does it *not* tell you about the machine's hardware capability?
* **Q1.2** — `/proc/cmdline` shows `BOOT_IMAGE=/boot/vmlinuz-...`. Which component wrote that parameter, and what is it useful for?
* **Q1.3** — On a Fedora UEFI system, `readlink -f /boot/grub2/grub.cfg` may resolve into `/boot/efi/EFI/fedora/`. What operational mistake does that layout invite when an administrator "edits the GRUB config"?
* **Q1.4** — `grub-probe --target=fs /boot` returned `ext2` on a filesystem you created with `mkfs.ext4`. Is this a bug? Explain.

---

## Exercise 2 — Map the boot chain on the disk itself

GRUB 2 for `i386-pc` (BIOS) does not fit in the 446‑byte boot code area of an MBR. Only `boot.img` lives there; it contains an LBA pointer to `core.img`, which lives either in the *MBR gap* (msdos label) or in a dedicated **BIOS boot partition** (GPT label). Understanding this is the difference between fixing a broken boot and reinstalling the OS.

1. Print the partition layout with partition *types*, not just filesystems:

   ```bash
   # lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS
   NAME    SIZE TYPE FSTYPE PARTTYPENAME       MOUNTPOINTS
   vda      40G disk
   ├─vda1    1M part        BIOS boot
   ├─vda2  512M part vfat   EFI System         /boot/efi
   └─vda3 39.5G part ext4   Linux filesystem   /
   ```

   On util-linux older than 2.37, use `lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPE,MOUNTPOINT` and resolve the GUID by hand.

2. Read the disk label type and the first usable sector:

   ```bash
   # fdisk -l /dev/vda
   Disk /dev/vda: 40 GiB, 42949672960 bytes, 83886080 sectors
   Units: sectors of 1 * 512 = 512 bytes
   Disklabel type: gpt
   Disk identifier: 3F2504E0-4F89-41D3-9A0C-0305E82C3301

   Device       Start      End  Sectors  Size Type
   /dev/vda1     2048     4095     2048    1M BIOS boot
   /dev/vda2     4096  1052671  1048576  512M EFI System
   /dev/vda3  1052672 83884031 82831360 39.5G Linux filesystem
   ```

3. On a **msdos**‑labelled disk there is no BIOS boot partition; measure the gap instead:

   ```bash
   # fdisk -l /dev/vdb | grep -A3 '^Device'
   Device     Boot Start      End  Sectors Size Id Type
   /dev/vdb1  *     2048 41943039 41940992  20G 83 Linux
   ```

   The first partition starts at sector 2048, so sectors 1–2047 (1 MiB minus one sector) are free for `core.img`.

4. Look at the first 512 bytes of the disk and confirm the boot signature:

   ```bash
   # dd if=/dev/vdb bs=512 count=1 status=none | xxd | tail -3
   000001d0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
   000001e0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
   000001f0: 0000 0000 0000 0000 0000 0000 0000 55aa  ..............U.
   ```

5. Confirm GRUB's stage‑1 strings and read the pointer it embedded:

   ```bash
   # dd if=/dev/vdb bs=512 count=1 status=none | strings
   ZRr=
   GRUB
   Geom
   Hard Disk
   Read
    Error
   # hexdump -C -s 0x5c -n 8 /dev/vdb
   0000005c  01 00 00 00 00 00 00 00                           |........|
   ```

   On `i386-pc`, offset `0x5c` of `boot.img` holds an 8‑byte little‑endian LBA: the first sector of `core.img`. `01` means sector 1 — immediately after the MBR, i.e. the embedding area.

6. List the modules GRUB installed on disk for this platform:

   ```bash
   # ls /boot/grub/i386-pc/ | head -6
   acpi.mod
   adler32.mod
   affs.mod
   ahci.mod
   all_video.mod
   at_keyboard.mod
   # ls /boot/grub/x86_64-efi/ 2>/dev/null | wc -l
   0
   ```

**Check your understanding**

* **Q2.1** — Why does a GPT disk booted via BIOS require a 1 MiB partition of type `EF02` (`21686148-6449-6E6F-744E-656564454649`), while an MBR disk does not?
* **Q2.2** — An administrator aligns the first partition at sector 63 (the old CHS convention) on an MBR disk and then runs `grub-install /dev/sda`. What happens, and what is the error message you should expect?
* **Q2.3** — What are the two bytes `55 aa` at offset `0x1FE`, and what happens if they are missing?
* **Q2.4** — Of the 512 bytes of the MBR, how many are boot code, how many are the partition table, and how many are the signature?
* **Q2.5** — `/boot/grub/i386-pc/` exists but `/boot/grub/x86_64-efi/` is empty. What does that tell you about how this system boots, regardless of what the firmware setup screen says?

---

## Exercise 3 — Read `grub.cfg` without editing it

`grub.cfg` is **generated output**. Treating it as a config file is the single most common operational error in this objective — your edits are silently destroyed by the next kernel package upgrade, which runs `grub-mkconfig` from a package hook.

1. Confirm the warning banner the generator writes:

   ```bash
   # head -6 /boot/grub/grub.cfg
   #
   # DO NOT EDIT THIS FILE
   #
   # It is automatically generated by grub-mkconfig using templates
   # from /etc/grub.d and settings from /etc/default/grub
   #
   ```

2. List the generator fragments and note that they are numbered and executable:

   ```bash
   # ls -l /etc/grub.d/
   -rwxr-xr-x 1 root root  10046 Jan 15 2024 00_header
   -rwxr-xr-x 1 root root   6260 Jan 15 2024 10_linux
   -rwxr-xr-x 1 root root  12894 Jan 15 2024 20_linux_xen
   -rwxr-xr-x 1 root root  12059 Jan 15 2024 30_os-prober
   -rwxr-xr-x 1 root root   1416 Jan 15 2024 30_uefi-firmware
   -rwxr-xr-x 1 root root    214 Jan 15 2024 40_custom
   -rwxr-xr-x 1 root root    216 Jan 15 2024 41_custom
   -rw-r--r-- 1 root root    483 Jan 15 2024 README
   ```

3. Extract the menu entries as the user will see them:

   ```bash
   # grep -E "^\s*(menuentry|submenu)" /boot/grub/grub.cfg
   menuentry 'Debian GNU/Linux' --class debian --class gnu-linux ... $menuentry_id_option 'gnulinux-simple-6f2c1a7e-...' {
   submenu 'Advanced options for Debian GNU/Linux' $menuentry_id_option 'gnulinux-advanced-6f2c1a7e-...' {
   ```

4. Read one entry in full and identify each command:

   ```bash
   # sed -n '/^menuentry .Debian/,/^}/p' /boot/grub/grub.cfg
   menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class os \
       $menuentry_id_option 'gnulinux-simple-6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60' {
       load_video
       insmod gzio
       insmod part_gpt
       insmod ext2
       search --no-floppy --fs-uuid --set=root a1b2c3d4-0000-4444-8888-aabbccddeeff
       echo    'Loading Linux 6.1.0-18-amd64 ...'
       linux   /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro quiet
       echo    'Loading initial ramdisk ...'
       initrd  /initrd.img-6.1.0-18-amd64
   }
   ```

5. Validate the syntax of the generated file (this parses it with GRUB's own script parser, without booting):

   ```bash
   # grub-script-check /boot/grub/grub.cfg && echo "syntax OK"
   syntax OK
   ```

6. Inspect the persistent environment block, which is *not* in `grub.cfg`:

   ```bash
   # grub-editenv list
   saved_entry=Debian GNU/Linux
   boot_success=1
   ```

**Check your understanding**

* **Q3.1** — In the entry above, `linux /vmlinuz-6.1.0-18-amd64` has no `/boot` prefix, yet `/proc/cmdline` said `BOOT_IMAGE=/boot/vmlinuz-...`. Why do the two paths differ?
* **Q3.2** — What does `search --no-floppy --fs-uuid --set=root <uuid>` accomplish, and why is it more robust than `set root=(hd0,gpt2)`?
* **Q3.3** — The entry passes `root=UUID=...` to the kernel *and* sets GRUB's own `root`. Are these the same thing? What does each one refer to?
* **Q3.4** — Files in `/etc/grub.d/` are numbered. What is the significance of the number, and what happens if you remove the executable bit from `30_os-prober`?
* **Q3.5** — Where does `grub-editenv` store `saved_entry`, and why can that file not live on an LVM logical volume or a Btrfs subvolume in some configurations?

---

## Exercise 4 — Change GRUB 2 behaviour the supported way

The supported change path is: edit `/etc/default/grub` → run `grub-mkconfig -o <path>` → verify the generated file.

1. Snapshot the current state so you can prove what changed:

   ```bash
   # cp -a /etc/default/grub /root/grub.default.bak
   # cp -a /boot/grub/grub.cfg /root/grub.cfg.bak
   ```

2. Read the current settings:

   ```bash
   # grep -vE '^\s*(#|$)' /etc/default/grub
   GRUB_DEFAULT=0
   GRUB_TIMEOUT=5
   GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
   GRUB_CMDLINE_LINUX_DEFAULT="quiet"
   GRUB_CMDLINE_LINUX=""
   ```

3. Apply a production‑oriented change set. This makes the menu visible for 10 seconds, sends the console to both VGA and serial (essential on headless servers), and disables the collapsing submenu:

   ```bash
   # cat >> /etc/default/grub <<'EOF'

   # --- lab 102.2 ---
   GRUB_TIMEOUT=10
   GRUB_TIMEOUT_STYLE=menu
   GRUB_DISABLE_SUBMENU=y
   GRUB_TERMINAL="console serial"
   GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
   GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
   GRUB_RECORDFAIL_TIMEOUT=10
   EOF
   ```

4. Regenerate the configuration. **Note the different command and output path per distribution:**

   ```bash
   # Debian / Ubuntu
   # grub-mkconfig -o /boot/grub/grub.cfg
   Generating grub configuration file ...
   Found linux image: /boot/vmlinuz-6.1.0-18-amd64
   Found initrd image: /boot/initrd.img-6.1.0-18-amd64
   Warning: os-prober will not be executed to detect other bootable partitions.
   done

   # Red Hat / Fedora (BIOS)
   # grub2-mkconfig -o /boot/grub2/grub.cfg

   # Red Hat / Fedora (UEFI, RHEL 8 layout)
   # grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
   ```

   `update-grub` on Debian/Ubuntu is a two-line wrapper around `grub-mkconfig -o /boot/grub/grub.cfg`. Prefer the real command — it is what the exam asks for and what exists everywhere.

5. Prove the change reached the generated file:

   ```bash
   # diff /root/grub.cfg.bak /boot/grub/grub.cfg | head -20
   < set timeout=5
   > set timeout=10
   > serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
   > terminal_input console serial
   > terminal_output console serial
   ```

6. Set which entry boots next time — without editing anything:

   ```bash
   # grub-set-default "Debian GNU/Linux"     # persistent default
   # grub-reboot 2                            # ONE-TIME override, next boot only
   # grub-editenv list
   saved_entry=Debian GNU/Linux
   next_entry=2
   ```

   `grub-set-default`/`grub-reboot` require `GRUB_DEFAULT=saved` in `/etc/default/grub`.

**Check your understanding**

* **Q4.1** — What is the practical difference between `GRUB_CMDLINE_LINUX` and `GRUB_CMDLINE_LINUX_DEFAULT`? Which one would you use to add `console=ttyS0,115200n8`, and why?
* **Q4.2** — The `os-prober` warning appeared. Which GRUB 2 version changed this default, what is the security rationale, and which setting re‑enables it?
* **Q4.3** — Your headless server is configured with `GRUB_TIMEOUT=0`. After a power cut it never comes back and the console shows the GRUB menu waiting indefinitely. What mechanism did this, and which variable fixes it?
* **Q4.4** — You set `GRUB_TIMEOUT=10` but the menu still does not appear. Which other variable is overriding it, and what are its accepted values?
* **Q4.5** — After `grub-mkconfig -o /boot/grub/grub.cfg`, is it also necessary to re‑run `grub-install`? Justify your answer in terms of what each command writes.

---

## Exercise 5 — Add a custom menu entry and a boot‑time password

1. Look at the skeleton of `40_custom`:

   ```bash
   # cat /etc/grub.d/40_custom
   #!/bin/sh
   exec tail -n +3 $0
   # This file provides an easy way to add custom menu entries.  Simply type the
   # menu entries you want to add after this comment.  Be careful not to change
   # the 'exec tail' line above.
   ```

2. Append a rescue entry that boots the current kernel straight into a shell, plus a firmware entry:

   ```bash
   # KVER=$(uname -r)
   # RUUID=$(findmnt -no UUID /)
   # BUUID=$(grub-probe --target=fs_uuid /boot)
   # cat >> /etc/grub.d/40_custom <<EOF

   menuentry 'Emergency shell (no init)' --class recovery {
       insmod part_gpt
       insmod ext2
       search --no-floppy --fs-uuid --set=root ${BUUID}
       linux /vmlinuz-${KVER} root=UUID=${RUUID} ro init=/bin/bash
       initrd /initrd.img-${KVER}
   }

   menuentry 'Reboot into firmware setup' {
       fwsetup
   }
   EOF
   ```

3. Verify that the fragment is executable and syntactically valid *before* regenerating:

   ```bash
   # test -x /etc/grub.d/40_custom && echo executable
   executable
   # /etc/grub.d/40_custom | grub-script-check && echo "fragment OK"
   fragment OK
   ```

4. Generate a PBKDF2 hash for a GRUB superuser:

   ```bash
   # grub-mkpasswd-pbkdf2
   Enter password:
   Reenter password:
   PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.9B2C...F1A3.4D7E...0C88
   ```

5. Restrict *editing* the menu without restricting normal boot — the correct posture for a server, since the alternative is a machine nobody can boot unattended:

   ```bash
   # cat >> /etc/grub.d/40_custom <<'EOF'

   set superusers="gadmin"
   password_pbkdf2 gadmin grub.pbkdf2.sha512.10000.9B2C...F1A3.4D7E...0C88
   EOF
   # sed -i 's/^CLASS="/CLASS="--unrestricted /' /etc/grub.d/10_linux
   ```

6. Regenerate and confirm both the entry and the superuser reached `grub.cfg`:

   ```bash
   # grub-mkconfig -o /boot/grub/grub.cfg
   # grep -E "Emergency shell|superusers|unrestricted" /boot/grub/grub.cfg
   set superusers="gadmin"
   menuentry 'Debian GNU/Linux' --class debian ... --unrestricted {
   menuentry 'Emergency shell (no init)' --class recovery {
   ```

**Check your understanding**

* **Q5.1** — Why is `exec tail -n +3 $0` at the top of `40_custom`, and what breaks if you delete that line?
* **Q5.2** — Why did the exercise pass `${BUUID}` to `search` but `${RUUID}` to the kernel's `root=`? On a system with no separate `/boot` partition, what would those two values be?
* **Q5.3** — `init=/bin/bash` gives you a root shell with no password prompt. What does this imply about the value of a root password on a machine whose GRUB menu is unprotected, and what is the mitigation *below* the boot loader?
* **Q5.4** — Without `--unrestricted` on the normal entries, what is the operational consequence of `set superusers=` on an unattended server?
* **Q5.5** — `/etc/grub.d/40_custom` versus `/boot/grub/custom.cfg`: what is the difference in how each reaches the boot menu?

---

## Exercise 6 — Install GRUB into an MBR with `grub-install` (safe, loop‑back)

This is the core hands‑on skill of the objective. Everything happens inside a file.

1. Create a 2 GiB sparse image and attach it as a block device with partition scanning:

   ```bash
   # truncate -s 2G /var/tmp/lab-disk.img
   # LOOP=$(losetup --find --show --partscan /var/tmp/lab-disk.img)
   # echo $LOOP
   /dev/loop0
   ```

2. Write an **msdos** label with one bootable partition, leaving the 1 MiB gap:

   ```bash
   # parted -s $LOOP mklabel msdos
   # parted -s $LOOP mkpart primary ext4 1MiB 100%
   # parted -s $LOOP set 1 boot on
   # partprobe $LOOP; lsblk $LOOP
   NAME      SIZE TYPE MOUNTPOINTS
   loop0       2G loop
   └─loop0p1   2G part
   ```

3. Make a filesystem and mount it:

   ```bash
   # mkfs.ext4 -q -L LABDISK ${LOOP}p1
   # mkdir -p /mnt/lab && mount ${LOOP}p1 /mnt/lab
   # mkdir -p /mnt/lab/boot
   ```

4. Install the BIOS boot loader, pointing it at this image's `/boot` rather than your own:

   ```bash
   # grub-install --target=i386-pc --boot-directory=/mnt/lab/boot --no-floppy $LOOP
   Installing for i386-pc platform.
   Installation finished. No error reported.
   ```

   If this fails with `cannot find a device for /mnt/lab/boot`, install `grub-pc-bin` (Debian) / `grub2-pc-modules` (Fedora) and add `--recheck`.

5. Confirm what was written **into the file** — three places, not one:

   ```bash
   # dd if=$LOOP bs=512 count=1 status=none | strings | head -4
   ZRr=
   GRUB
   Geom
   Hard Disk
   # hexdump -C -s 0x5c -n 8 $LOOP
   0000005c  01 00 00 00 00 00 00 00                           |........|
   # ls /mnt/lab/boot/grub/
   fonts  grubenv  i386-pc  locale
   # ls /mnt/lab/boot/grub/i386-pc/ | wc -l
   287
   ```

6. Look at the embedding area between the MBR and partition 1, where `core.img` now lives:

   ```bash
   # dd if=$LOOP bs=512 skip=1 count=8 status=none | strings | grep -m3 .
   loading
   .
   grub_
   ```

7. Provide the loader with a configuration and a kernel to chain to, then verify the tree:

   ```bash
   # cp /boot/vmlinuz-$(uname -r) /boot/initrd.img-$(uname -r) /mnt/lab/boot/
   # cat > /mnt/lab/boot/grub/grub.cfg <<EOF
   set timeout=5
   set default=0
   menuentry 'Lab kernel' {
       search --no-floppy --fs-label --set=root LABDISK
       linux /boot/vmlinuz-$(uname -r) root=LABEL=LABDISK ro
       initrd /boot/initrd.img-$(uname -r)
   }
   EOF
   # grub-script-check /mnt/lab/boot/grub/grub.cfg && echo OK
   OK
   ```

8. (Optional) Boot the image to prove it works, then tear the lab down:

   ```bash
   $ qemu-system-x86_64 -m 1024 -drive file=/var/tmp/lab-disk.img,format=raw -nographic
   # umount /mnt/lab
   # losetup -d $LOOP
   ```

**Check your understanding**

* **Q6.1** — `grub-install` was given `$LOOP` (the whole device), not `${LOOP}p1`. What would happen if you pointed it at the partition instead, and why does GRUB refuse or warn?
* **Q6.2** — What exactly does `--boot-directory` control, and what is its default? Name the older option it replaced.
* **Q6.3** — Name the three distinct locations `grub-install` wrote to on this image, and state what each one contains.
* **Q6.4** — Why does `grub-install` need `--target=i386-pc` here even though your host may be a UEFI machine?
* **Q6.5** — `grub-install` on a UEFI system additionally runs `efibootmgr`. Which two options let you skip that — one for cloning to removable media, one for chroots where EFI variables are unavailable?
* **Q6.6** — Installing GRUB's `core.img` into a partition boot sector (`--force` on a partition) is documented as unreliable. Why? Give the filesystem‑level reason.

---

## Exercise 7 — Back up and restore boot code and configuration

1. Back up the whole first sector (boot code **and** partition table):

   ```bash
   # dd if=/dev/vdb of=/root/vdb-mbr-full.bin bs=512 count=1
   1+0 records in
   1+0 records out
   512 bytes copied, 0.000241 s, 2.1 MB/s
   ```

2. Back up only the boot code area, leaving the partition table out of the file:

   ```bash
   # dd if=/dev/vdb of=/root/vdb-bootcode.bin bs=446 count=1
   1+0 records in
   1+0 records out
   446 bytes copied, 0.000187 s, 2.4 MB/s
   ```

3. Back up the embedding area as well — the MBR alone is useless without `core.img`:

   ```bash
   # dd if=/dev/vdb of=/root/vdb-gap.bin bs=512 count=2048
   2048+0 records in
   2048+0 records out
   1048576 bytes (1.0 MB, 1.0 MiB) copied, 0.0041 s, 256 MB/s
   ```

4. Back up the partition table in a *textual*, reviewable form:

   ```bash
   # sfdisk --dump /dev/vdb > /root/vdb-parttable.txt
   # sgdisk --backup=/root/vda-gpt.bin /dev/vda        # GPT disks
   The operation has completed successfully.
   ```

5. Back up the configuration inputs (the outputs are regenerable; the inputs are not):

   ```bash
   # tar czf /root/grub-config-$(date +%F).tar.gz \
       /etc/default/grub /etc/grub.d/ /boot/grub/grub.cfg
   ```

6. Simulate damage and repair it **on the lab image only**:

   ```bash
   # dd if=/dev/zero of=$LOOP bs=446 count=1        # wipe boot code, keep table
   # dd if=$LOOP bs=512 count=1 status=none | strings | grep -c GRUB
   0
   # grub-install --target=i386-pc --boot-directory=/mnt/lab/boot $LOOP
   Installing for i386-pc platform.
   Installation finished. No error reported.
   ```

7. Or restore from the byte backup rather than reinstalling:

   ```bash
   # dd if=/root/vdb-bootcode.bin of=/dev/vdb bs=446 count=1 conv=notrunc
   ```

**Check your understanding**

* **Q7.1** — Why does step 2 use `bs=446` while step 1 uses `bs=512`? Describe a concrete scenario in which restoring the 512‑byte backup destroys data.
* **Q7.2** — What does `conv=notrunc` do, and what happens if you omit it when the output is a regular file rather than a block device?
* **Q7.3** — You restored a 446‑byte boot code backup to a disk that was later re‑partitioned and re‑installed. The machine now drops to `error: unknown filesystem` / `grub rescue>`. Why did a byte‑perfect restore fail?
* **Q7.4** — On a GPT disk, why is `dd` of the first sector an inadequate backup, and which two additional structures must be captured?
* **Q7.5** — Which of these files is worth backing up and which is regenerable: `/etc/default/grub`, `/boot/grub/grub.cfg`, `/etc/grub.d/40_custom`, `/boot/grub/i386-pc/`?

---

## Exercise 8 — Interact with the boot loader at run time

Do this on the VM console. Everything here is transient: nothing is written to disk.

1. Reboot and hold **Shift** (BIOS) or tap **Esc** (UEFI) to force the menu if it is hidden.

2. Highlight the default entry and press **`e`**. You are now in a full‑screen editor of a *copy* of the entry.

3. Navigate to the line beginning `linux`, move to end of line, and append a rescue target:

   ```
   linux /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-... ro quiet systemd.unit=rescue.target
   ```

4. Press **Ctrl‑x** (or **F10**) to boot the edited entry. Press **Esc** instead to discard the edit and return to the menu.

5. After the system reaches the rescue shell, verify where you landed and return to normal operation:

   ```bash
   # systemctl get-default
   graphical.target
   # cat /proc/cmdline
   BOOT_IMAGE=/boot/vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-... ro quiet systemd.unit=rescue.target
   # systemctl isolate default.target
   ```

6. Reboot again, and this time press **`c`** at the menu for the GRUB command shell. Explore the device tree:

   ```
   grub> set pager=1
   grub> echo $prefix
   (hd0,gpt2)/grub
   grub> ls
   (hd0) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (fd0)
   grub> ls (hd0,gpt2)/
   lost+found/ vmlinuz-6.1.0-18-amd64 initrd.img-6.1.0-18-amd64 grub/ config-6.1.0-18-amd64
   grub> ls -l (hd0,gpt2)
   Partition hd0,gpt2: Filesystem type ext2, UUID a1b2c3d4-..., Partition start at 2048KiB, Total size 512000KiB
   ```

7. Boot the system entirely by hand, with no menu entry at all:

   ```
   grub> set root=(hd0,gpt2)
   grub> linux /vmlinuz-6.1.0-18-amd64 root=UUID=6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60 ro
   grub> initrd /initrd.img-6.1.0-18-amd64
   grub> boot
   ```

8. Simulate the `grub rescue>` prompt (the minimal loader, with almost no commands available) and recover from it:

   ```
   grub rescue> ls
   (hd0) (hd0,gpt1) (hd0,gpt2) (hd0,gpt3)
   grub rescue> ls (hd0,gpt2)/grub
   error: unknown filesystem.
   grub rescue> ls (hd0,gpt2)/
   grub/ vmlinuz-6.1.0-18-amd64 ...
   grub rescue> set prefix=(hd0,gpt2)/grub
   grub rescue> set root=(hd0,gpt2)
   grub rescue> insmod normal
   grub rescue> normal
   ```

   You are now back at the full menu — but only in memory. The fix must be made permanent from the running system with `grub-install` + `grub-mkconfig`.

**Check your understanding**

* **Q8.1** — Are edits made with `e` persistent? Where are they stored, and what is the exam‑relevant consequence?
* **Q8.2** — Distinguish `grub>` from `grub rescue>`. What causes each, and why does `insmod normal` fail at the `grub>` prompt but is required at `grub rescue>`?
* **Q8.3** — In `(hd0,gpt2)`, decode each component. Which parts are 0‑indexed and which are 1‑indexed?
* **Q8.4** — Give four kernel parameters usable from the GRUB editor to reach a shell on a broken system, and describe what each gives you.
* **Q8.5** — You appended `init=/bin/bash` and got a shell, but `passwd` fails with "Read-only file system". What single command fixes it?
* **Q8.6** — In step 7, if you type `linux` and `initrd` but forget `boot`, nothing happens. Why does GRUB not boot automatically after `initrd`?

---

## Exercise 9 — Repair an unbootable system from live media (chroot)

The scenario: another OS installer overwrote the MBR, or `/boot` was restored from backup with no boot loader. You have a live ISO.

1. Boot the live medium and identify the partitions:

   ```bash
   # lsblk -f
   NAME   FSTYPE FSVER LABEL UUID                                 MOUNTPOINTS
   vda
   ├─vda1 vfat   FAT32       AB12-CD34
   ├─vda2 ext4   1.0         a1b2c3d4-0000-4444-8888-aabbccddeeff
   └─vda3 ext4   1.0         6f2c1a7e-9b31-42d4-8f0a-1c2b3d4e5f60
   ```

2. Mount the root filesystem, then anything that is a separate filesystem, **in order**:

   ```bash
   # mount /dev/vda3 /mnt
   # mount /dev/vda2 /mnt/boot           # separate /boot
   # mount /dev/vda1 /mnt/boot/efi       # UEFI only
   ```

3. Bind the kernel's virtual filesystems so the chrooted tools can see real hardware:

   ```bash
   # for d in dev dev/pts proc sys run; do mount --rbind /$d /mnt/$d; mount --make-rslave /mnt/$d; done
   # mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars   # UEFI only, if not already rbound
   ```

4. Enter the chroot and confirm you are inside the target system:

   ```bash
   # chroot /mnt /bin/bash
   # cat /etc/os-release | head -1
   PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
   # findmnt -no SOURCE /
   /dev/vda3
   ```

5. Reinstall the boot loader for the correct platform:

   ```bash
   # BIOS
   # grub-install --target=i386-pc --recheck /dev/vda
   Installing for i386-pc platform.
   Installation finished. No error reported.

   # UEFI
   # grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
   Installing for x86_64-efi platform.
   Installation finished. No error reported.
   ```

6. Regenerate the menu, verify, and leave cleanly:

   ```bash
   # grub-mkconfig -o /boot/grub/grub.cfg
   # grub-script-check /boot/grub/grub.cfg && echo OK
   OK
   # exit
   # umount -R /mnt
   # reboot
   ```

**Check your understanding**

* **Q9.1** — Why must `/dev`, `/proc` and `/sys` be bind‑mounted before the chroot? Name one command in step 5 that fails without each.
* **Q9.2** — What is the purpose of `--make-rslave`, and what goes wrong at `umount -R /mnt` without it?
* **Q9.3** — In a UEFI repair, why is `efivarfs` required, and which `grub-install` option lets you proceed without it?
* **Q9.4** — You are repairing an x86‑64 system from a 32‑bit live ISO. Which step fails and why?
* **Q9.5** — The chroot succeeds and `grub-install` reports no error, but the machine still boots the other OS. Name two causes unrelated to GRUB itself.
* **Q9.6** — On a Secure Boot system, `grub-install` succeeds but the firmware refuses to load the loader. Which component is missing from the chain, and which command reports Secure Boot state?

---

## Exercise 10 — GRUB Legacy: read `menu.lst` / `grub.conf`

GRUB Legacy (0.97) is still on the objective list and still found on RHEL/CentOS 5–6 and long‑lived appliances. You will read it far more often than you will install it.

1. Locate the configuration. On Red Hat systems the file is `grub.conf` with a symlink:

   ```bash
   # ls -l /boot/grub/menu.lst /boot/grub/grub.conf /etc/grub.conf
   lrwxrwxrwx 1 root root 11 Mar  3  2019 /boot/grub/menu.lst -> ./grub.conf
   -rw------- 1 root root 852 Mar  3  2019 /boot/grub/grub.conf
   lrwxrwxrwx 1 root root 22 Mar  3  2019 /etc/grub.conf -> ../boot/grub/grub.conf
   ```

2. Read it:

   ```
   default=0
   timeout=5
   fallback=1
   splashimage=(hd0,0)/grub/splash.xpm.gz
   hiddenmenu
   password --md5 $1$Xy3Kz$8pQ2mR7vN0hL4dW1sE6tB.

   title CentOS (2.6.32-754.el6.x86_64)
       root (hd0,0)
       kernel /vmlinuz-2.6.32-754.el6.x86_64 ro root=UUID=6f2c1a7e-... rhgb quiet
       initrd /initramfs-2.6.32-754.el6.x86_64.img

   title Windows Server 2008
       rootnoverify (hd1,0)
       chainloader +1
   ```

3. Inspect the device map, which GRUB Legacy uses to translate BIOS drive numbers to Linux device nodes:

   ```bash
   # cat /boot/grub/device.map
   (fd0)   /dev/fd0
   (hd0)   /dev/sda
   (hd1)   /dev/sdb
   ```

4. List the stage files:

   ```bash
   # ls /boot/grub/
   device.map  e2fs_stage1_5  grub.conf  menu.lst  splash.xpm.gz  stage1  stage2
   ```

5. Install GRUB Legacy from its interactive shell (the equivalent of `grub-install`):

   ```
   # grub
   grub> root (hd0,0)
    Filesystem type is ext2fs, partition type 0x83
   grub> setup (hd0)
    Checking if "/boot/grub/stage1" exists... yes
    Checking if "/boot/grub/stage2" exists... yes
    Checking if "/boot/grub/e2fs_stage1_5" exists... yes
    Running "embed /boot/grub/e2fs_stage1_5 (hd0)"...  27 sectors are embedded.
   succeeded
    Running "install /boot/grub/stage1 (hd0) (hd0)1+27 p (hd0,0)/boot/grub/stage2 /boot/grub/grub.conf"... succeeded
   Done.
   ```

6. Translate the device names to GRUB 2 syntax. Write out the GRUB 2 equivalent of each line before checking the answers:

   | GRUB Legacy | GRUB 2 (msdos label) | GRUB 2 (gpt label) |
   |---|---|---|
   | `(hd0,0)` | ? | ? |
   | `(hd0,4)` | ? | — |
   | `(hd1,2)` | ? | ? |

**Check your understanding**

* **Q10.1** — Give the full GRUB 2 equivalent of `(hd0,0)`, `(hd0,4)` and `(hd1,2)`. State the indexing rule for disks and for partitions in each generation.
* **Q10.2** — Map each GRUB Legacy directive to its GRUB 2 counterpart: `title`, `root`, `kernel`, `initrd`, `default`, `timeout`, `hiddenmenu`.
* **Q10.3** — What is `stage1_5`, where does it live, and which GRUB 2 component replaced it?
* **Q10.4** — What is the difference between `root` and `rootnoverify`, and why does the Windows entry need the latter plus `chainloader +1`?
* **Q10.5** — GRUB Legacy has no `grub-mkconfig`. What is the operational consequence after a kernel package upgrade, and what did Red Hat use to compensate?
* **Q10.6** — The Legacy file is mode `0600`. What is it protecting, and what is the GRUB 2 equivalent protection?

---

## Exercise 11 — UEFI: alternative boot locations and `efibootmgr`

1. List the firmware boot entries and the boot order:

   ```bash
   # efibootmgr -v
   BootCurrent: 0001
   Timeout: 3 seconds
   BootOrder: 0001,0002,0000
   Boot0000* UiApp   FvVol(7cb8bdc9-...)/FvFile(462caa21-...)
   Boot0001* debian  HD(1,GPT,ab12cd34-...,0x800,0x100000)/File(\EFI\debian\shimx64.efi)
   Boot0002* UEFI QEMU DVD-ROM  PciRoot(0x0)/Pci(0x1,0x1)/Ata(1,0,0)
   ```

2. Inspect the ESP contents — this is where "install a boot manager" actually happens on UEFI:

   ```bash
   # find /boot/efi -maxdepth 3 -type f | sort
   /boot/efi/EFI/BOOT/BOOTX64.EFI
   /boot/efi/EFI/BOOT/fbx64.efi
   /boot/efi/EFI/debian/BOOTX64.CSV
   /boot/efi/EFI/debian/grub.cfg
   /boot/efi/EFI/debian/grubx64.efi
   /boot/efi/EFI/debian/mmx64.efi
   /boot/efi/EFI/debian/shimx64.efi
   # cat /boot/efi/EFI/debian/grub.cfg
   search.fs_uuid a1b2c3d4-0000-4444-8888-aabbccddeeff root
   set prefix=($root)'/grub'
   configfile $prefix/grub.cfg
   ```

3. Create a **backup boot entry** pointing at the same loader, so a corrupted NVRAM entry is not fatal:

   ```bash
   # efibootmgr -c -d /dev/vda -p 1 -L "debian-backup" -l '\EFI\debian\grubx64.efi'
   BootCurrent: 0001
   BootOrder: 0003,0001,0002,0000
   Boot0003* debian-backup
   ```

4. Install to the **removable/fallback path**, which every UEFI firmware tries when NVRAM has no usable entry:

   ```bash
   # grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
   Installing for x86_64-efi platform.
   Installation finished. No error reported.
   # ls /boot/efi/EFI/BOOT/
   BOOTX64.EFI  fbx64.efi  grubx64.efi
   ```

5. Manage boot order and one‑time boots, then clean up the lab entry:

   ```bash
   # efibootmgr -o 0001,0003,0002,0000     # set persistent order
   # efibootmgr -n 0002                    # BootNext: one boot from DVD
   # efibootmgr -b 0003 -B                 # delete entry 0003
   ```

**Check your understanding**

* **Q11.1** — On a UEFI system, which component plays the role that the MBR boot code plays on BIOS? Where does `core.img` go?
* **Q11.2** — Why does `\EFI\debian\` use backslashes in `efibootmgr -l` while `/boot/efi/EFI/debian/` uses forward slashes?
* **Q11.3** — What is the significance of `/EFI/BOOT/BOOTX64.EFI`, and in which two situations does `--removable` save you?
* **Q11.4** — Explain the chain `shimx64.efi → grubx64.efi → vmlinuz` on a Secure Boot machine. What is `mmx64.efi` for?
* **Q11.5** — The tiny `grub.cfg` on the ESP contains only `search`/`set prefix`/`configfile`. Why is the real configuration not stored on the ESP?
* **Q11.6** — `efibootmgr` fails with `EFI variables are not supported on this system`. Give the two most likely causes.

---

<details>
<summary><strong>Answers</strong> (open only after attempting every exercise)</summary>

### Exercise 1

**A1.1** — The kernel creates `/sys/firmware/efi` only when it was entered through the EFI stub or an EFI boot loader and EFI runtime services are available. It reflects **how this boot happened**, not what the hardware supports: a UEFI‑capable machine booted through CSM/legacy mode has no `/sys/firmware/efi`, and installing GRUB there requires `--target=i386-pc`. Always trust the running state, not the firmware setup screen.

**A1.2** — GRUB 2's `linux` command appends `BOOT_IMAGE=` automatically, recording the path of the kernel image it loaded, expressed relative to GRUB's `root`. It is diagnostic gold: on a machine with several `/boot` filesystems it tells you which kernel image file actually ran, independently of what `uname -r` reports.

**A1.3** — There are then two files named `grub.cfg` — one on the ESP, one under `/boot/grub2/` — and an administrator who edits the wrong one sees no effect at all, or edits the right one and has it overwritten by the next `grub2-mkconfig`. Always resolve the path with `readlink -f` first, and always regenerate rather than edit. (RHEL 9/Fedora unified this: `/boot/grub2/grub.cfg` is the real file on both firmware types, with a small stub on the ESP.)

**A1.4** — Not a bug. GRUB's `ext2` module reads ext2, ext3 and ext4; `grub-probe` names the module, not the on‑disk feature set. The value matters because it is what gets written as `insmod ext2` into `grub.cfg`.

### Exercise 2

**A2.1** — On an MBR disk, sectors 1 through the start of the first partition (conventionally 2047, giving ~1 MiB) are unallocated and GRUB embeds `core.img` there. GPT has no such guaranteed gap — the partition table and its entries occupy the sectors right after the protective MBR — so GRUB needs an explicitly reserved, unformatted partition of type `EF02` to embed into. Without it, `grub-install` fails with `embedding is not possible, but this is required for cross-disk install`.

**A2.2** — Only 62 sectors (~31 KiB) are available before sector 63, which is too small for a modern `core.img` (typically 25–40 KiB with the needed modules, more with LVM/RAID/crypto). `grub-install` fails with:
`error: embedding is not possible, but this is required when the root device is on a RAID array or LVM volume` or `warning: your core.img is unusually large. It won't fit in the embedding area.` The fix is to re‑align the partition at 1 MiB, or use a separate unencrypted `/boot`.

**A2.3** — The boot signature (also called the magic number), at offset `0x1FE`–`0x1FF`. BIOS reads sector 0 into memory at `0x7C00` and only transfers control to it if those two bytes are `0x55 0xAA`. Without them the BIOS treats the disk as non‑bootable and moves to the next device in the boot order.

**A2.4** — 446 bytes of boot code (offsets 0–445), 64 bytes of partition table (446–509: four 16‑byte entries), 2 bytes of signature (510–511). Within the boot code area, modern tooling further reserves offsets 440–443 for the 32‑bit disk signature and 444–445 as nulls, which is why some documentation says "440 bytes of boot code."

**A2.5** — GRUB was installed for the BIOS/`i386-pc` platform, so this machine boots through CSM/legacy, not native UEFI. If someone later disables CSM in the firmware, the machine will not boot until GRUB is reinstalled with `--target=x86_64-efi`. The module directory is the most reliable on‑disk evidence of which platform is in use.

### Exercise 3

**A3.1** — GRUB paths are relative to **GRUB's own root**, which here is the separate `/boot` partition — so the kernel is at `/vmlinuz-...` from GRUB's perspective. Once Linux mounts that partition at `/boot`, the same file is at `/boot/vmlinuz-...`. If there were no separate `/boot` partition, both paths would read `/boot/vmlinuz-...`. This mismatch is the number‑one cause of hand‑written menu entries failing with `error: file not found`.

**A3.2** — It searches every device GRUB can see for a filesystem with that UUID and assigns the first match to the variable `root`. It is robust because UUIDs travel with the filesystem: adding a disk, changing the SATA/NVMe controller, or moving the disk to another port renumbers `(hd0)`/`(hd1)` but does not change the UUID. Hard‑coded `(hd0,gpt2)` breaks the moment the BIOS enumerates drives differently.

**A3.3** — No, they are two different roots.
* GRUB's `root` (`set root=` / `search --set=root`) tells **GRUB** where to load `vmlinuz` and `initrd` from — it is the `/boot` filesystem.
* `root=UUID=...` on the `linux` line is a **kernel** parameter telling the kernel which filesystem to mount as `/` after the initramfs hands over.
On a system with a separate `/boot` these are two different filesystems with two different UUIDs.

**A3.4** — `grub-mkconfig` runs the scripts in `LC_ALL=C` sort order, so the number controls the position of each fragment's output in `grub.cfg` — and therefore the numeric index of the menu entries. Removing the executable bit from `30_os-prober` makes `grub-mkconfig` skip it entirely: no other operating systems are detected, and the dual‑boot entries vanish from the menu on the next regeneration. This is the supported way to disable a fragment.

**A3.5** — In `/boot/grub/grubenv`, a fixed 1024‑byte file that GRUB rewrites **in place**. GRUB must be able to write it without a filesystem driver capable of allocation, so it requires a static, contiguous block mapping. Filesystems that relocate blocks — Btrfs with COW, some LVM/RAID layouts — break that assumption, which is why GRUB prints `sparse file not allowed` or `environment block too small` and why `GRUB_DEFAULT=saved` is unreliable on Btrfs roots.

### Exercise 4

**A4.1** — `GRUB_CMDLINE_LINUX` is appended to **every** generated entry, including the recovery/single‑user ones. `GRUB_CMDLINE_LINUX_DEFAULT` is appended only to the normal entries and is deliberately omitted from recovery entries. Serial console parameters belong in `GRUB_CMDLINE_LINUX`: on a headless machine you need console output most in recovery mode, which is exactly where `..._DEFAULT` would not apply.

**A4.2** — GRUB 2.06 disabled `os-prober` by default (Debian 12, Ubuntu 22.04+, Fedora 36+). The rationale is that `os-prober` mounts every filesystem it finds and executes probing logic against untrusted foreign filesystems during a privileged operation — a real attack surface on multi‑tenant and VM hosts. Re‑enable it with `GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub`, then regenerate.

**A4.3** — Ubuntu's **recordfail** logic. `/etc/grub.d/00_header` writes `recordfail=1` into `grubenv` before handing off to the kernel, and a systemd unit clears it after a successful boot. If the previous boot did not complete, GRUB sets the timeout to `-1` (wait forever) so a human can intervene — which is precisely wrong for a headless server. `GRUB_RECORDFAIL_TIMEOUT=<seconds>` caps that wait.

**A4.4** — `GRUB_TIMEOUT_STYLE`. Accepted values: `menu` (show the menu for the full timeout), `countdown` (show only a countdown, no menu), and `hidden` (show nothing; the timeout is a silent grace period during which a keypress reveals the menu). With `hidden` or `countdown`, `GRUB_TIMEOUT` still elapses but no menu is drawn.

**A4.5** — Not necessary. The two commands write to different places and solve different problems:
* `grub-mkconfig -o <path>` regenerates the **menu configuration** — a text file on a normal filesystem.
* `grub-install` writes the **boot loader binaries**: `boot.img` to the MBR, `core.img` to the embedding area or ESP, and the module directory under `/boot/grub/`.
Re‑run `grub-install` only when the boot loader binaries themselves must change: after a GRUB package upgrade, after replacing or re‑partitioning the boot disk, or when adding a disk to a boot mirror.

### Exercise 5

**A5.1** — The script's own output becomes part of `grub.cfg`. `exec tail -n +3 $0` replaces the shell with `tail`, which prints the file starting at line 3 — i.e. everything after the shebang and the `exec` line itself. Delete it and the script produces no output, so your custom entries never appear in the menu; make the file non‑executable and `grub-mkconfig` skips it entirely.

**A5.2** — `search` locates the filesystem **GRUB** must read the kernel and initrd from — that is `/boot`, hence `BUUID`. `root=` tells the **kernel** which filesystem to mount as `/`, hence `RUUID`. On a system with no separate `/boot`, `grub-probe --target=fs_uuid /boot` and `findmnt -no UUID /` return the *same* UUID, and the distinction disappears — which is why it goes unnoticed until someone deploys a machine with a separate `/boot`.

**A5.3** — Physical or console access to an unprotected GRUB menu is equivalent to root: `init=/bin/bash` bypasses every userspace authentication mechanism, including PAM and the root password. The mitigation below the boot loader is **full‑disk encryption** (LUKS on `/` and ideally `/boot` too) so the attacker gets a shell over ciphertext, backed by firmware password + Secure Boot to stop them booting their own media instead. A GRUB password alone stops the casual attack; only encryption stops the disk being removed and mounted elsewhere.

**A5.4** — Every menu entry becomes password‑protected, including the default one, so the machine cannot boot unattended after a power cut or a scheduled reboot — the console sits at a username/password prompt forever. `--unrestricted` on the normal entries yields the correct posture: anyone may boot the default configuration, only `gadmin` may edit an entry or use the GRUB shell.

**A5.5** — `/etc/grub.d/40_custom` is an **input** to `grub-mkconfig`: its output is copied into `grub.cfg` at generation time and survives regeneration. `/boot/grub/custom.cfg` is read by `grub.cfg` at **boot time** via a `source`/`configfile` stanza emitted by `41_custom`; it never passes through `grub-mkconfig`, so it can be changed without regenerating anything — useful in images and on read‑only `/etc`, but invisible to `grub-script-check` on `grub.cfg` and easy to forget during audits.

### Exercise 6

**A6.1** — Installing to the whole device writes `boot.img` into the MBR, which is what the BIOS actually executes. Pointing `grub-install` at a partition writes `core.img` into that partition's boot sector, which GRUB documents as unsupported; it refuses unless you pass `--force`, and warns `Attempting to install GRUB to a partition instead of the MBR. This is a BAD idea.` The BIOS will not execute a partition boot sector unless something in the MBR chainloads it.

**A6.2** — `--boot-directory=DIR` sets where GRUB writes its module directory, fonts, locale and `grubenv` — it creates `DIR/grub/`, defaulting to `/boot`, hence `/boot/grub/`. It replaced the older `--root-directory`, which took the mount point (`--root-directory=/mnt/lab` meant `/mnt/lab/boot/grub`) and was ambiguous when `/boot` was itself a mount point.

**A6.3** — (1) The **MBR** (sector 0): `boot.img`, 446 bytes, containing the LBA of `core.img`. (2) The **embedding area** (sectors 1–2047): `core.img`, the compressed kernel image plus exactly the modules needed to read `/boot`'s filesystem and partition scheme. (3) `/mnt/lab/boot/grub/`: the module directory (`i386-pc/*.mod`), `grubenv`, fonts and locale — everything `core.img` loads afterwards.

**A6.4** — `grub-install` defaults to the platform of the *running* system. On a UEFI host it would try `x86_64-efi`, look for an ESP, and fail with `--efi-directory not specified` — or worse, touch your host's real EFI variables. `--target` decouples the target platform from the build host, which is exactly what image building and cross‑installation require.

**A6.5** — `--removable` (writes to the fallback path `/EFI/BOOT/BOOTX64.EFI` and creates no NVRAM entry — correct for USB media and cloned images) and `--no-nvram` (installs to the vendor directory but skips the `efibootmgr` call — correct inside a chroot where `efivarfs` is not mounted or is read‑only).

**A6.6** — A partition boot sector holds only the first sector; `core.img` is tens of kilobytes. GRUB must therefore store the rest in blocks it locates by **absolute block list**, embedded at install time. Any operation that relocates those blocks — a filesystem defragmentation, a `tar`/`rsync` restore, ext4 delayed allocation moving the file, a Btrfs COW rewrite, an fsck repair — invalidates the list, and the machine fails at boot with `error: unknown filesystem` even though nothing visibly changed. The embedding area on a whole disk has no such problem because it is unallocated space no filesystem will ever touch.

### Exercise 7

**A7.1** — 446 bytes copies only the boot code; the partition table at offsets 446–509 is left untouched on the target. Restoring the 512‑byte backup rewrites the partition table too. Concrete scenario: you back up the MBR, then add a fourth partition and put a filesystem on it. Weeks later the boot code is damaged and you restore the 512‑byte file — the partition table reverts to three entries and the fourth partition, still full of data, becomes invisible free space that the next `parted` operation will happily overwrite.

**A7.2** — `conv=notrunc` tells `dd` not to truncate the output file after writing. It is a no‑op on a block device but essential when the output is a regular file — for example when patching a disk image — because without it `dd` truncates the image to 446 bytes and destroys everything after the MBR.

**A7.3** — Because the MBR is only a pointer. `boot.img` contains the LBA of `core.img` and `core.img` contains the block list of `/boot/grub`; after a re‑partition and re‑install, neither the embedding area contents nor `/boot`'s location match what the restored 446 bytes expect. Byte‑level boot backups are only valid against the exact disk layout they were taken from. The correct repair is `grub-install`, not `dd`.

**A7.4** — GPT keeps a **primary header + entry array** at LBA 1 and following, and a **backup header + entry array** in the last sectors of the disk; the first sector is only a protective MBR that exists to stop MBR‑only tools from clobbering the disk. Capturing sector 0 preserves none of the real table. Use `sgdisk --backup=file /dev/sdX` (or `sfdisk --dump`) to capture both copies plus the disk GUID.

**A7.5** —
* `/etc/default/grub` — **back up**: hand‑maintained input, not reproducible.
* `/etc/grub.d/40_custom` — **back up**: hand‑maintained input.
* `/boot/grub/grub.cfg` — **regenerable** from the two above with `grub-mkconfig`; keep a copy anyway as a diff reference to prove what changed.
* `/boot/grub/i386-pc/` — **regenerable**: reinstalled from `/usr/lib/grub/i386-pc/` by `grub-install`.

### Exercise 8

**A8.1** — Not persistent. The edited text lives only in GRUB's memory for that single boot; nothing is written to disk, and the next boot uses the unmodified `grub.cfg`. This is the reason the `e` key is both safe (you cannot brick the system with it) and insufficient (a fix you need every boot must go into `/etc/default/grub` + `grub-mkconfig`).

**A8.2** —
* `grub>` — the **normal** shell. `core.img` found its prefix, loaded `normal.mod` and the rest of the module directory, but there was no usable `grub.cfg` (missing, empty, or a syntax error). The full command set is available, so `insmod normal` is redundant — `normal` is already loaded.
* `grub rescue>` — the **rescue** shell built into `core.img`. GRUB could not find `$prefix`/`/boot/grub` at all: wrong partition, moved filesystem, deleted directory, or a filesystem type its embedded modules cannot read. Only a handful of built‑in commands exist (`ls`, `set`, `unset`, `insmod`, `boot`). You must set `prefix` correctly, then `insmod normal` to load the module from disk, then `normal` to enter the full shell.

**A8.3** — `hd0` = first hard disk as enumerated by GRUB, **0‑indexed** (`fd0` for floppies, `cd0` for optical). `gpt2` = second partition, **1‑indexed**, with the partition‑table type spelled out (`gpt` or `msdos`). So disks count from 0 and partitions count from 1 in GRUB 2. GRUB Legacy counted **both** from 0, which is the classic exam trap.

**A8.4** —
* `systemd.unit=rescue.target` — single‑user equivalent: local filesystems mounted, no network, root shell after authentication.
* `systemd.unit=emergency.target` — minimal: `/` mounted read‑only, almost nothing started. Use when `rescue.target` itself fails.
* `init=/bin/bash` — replaces PID 1 entirely; no systemd, no services, no authentication, `/` read‑only.
* `rd.break` — dracut‑specific (Red Hat/Fedora/SUSE): stops in the initramfs *before* `switch_root`, with the real root at `/sysroot`. This is the only one that works when the root filesystem itself or SELinux relabelling is the problem.
* Also useful: `single`, `s` or `1` (systemd maps these to `rescue.target`), `enforcing=0` (SELinux in permissive mode), `nomodeset` (blank‑screen graphics failures).

**A8.5** — `mount -o remount,rw /`. With `init=/bin/bash` there is no init system to remount the root filesystem read‑write, so it stays as the kernel mounted it — read‑only, per the `ro` on the kernel command line. Everything that writes (`passwd`, `vipw`, `fsck` metadata updates) fails until you remount.

**A8.6** — `linux` and `initrd` only *load* images into memory and record their parameters; `boot` is the command that actually transfers control. The separation is deliberate — it lets you load, inspect, adjust variables, load a second initrd, or change your mind and press Esc. The same rule applies inside a `menuentry` block, where GRUB supplies an implicit `boot` at the end of the block.

### Exercise 9

**A9.1** —
* `/dev` — `grub-install` must open the real block device (`/dev/vda`) to write the MBR, and `grub-probe` must stat device nodes to map filesystems to drives. Without it: `cannot find a device for /boot (is /dev mounted?)`.
* `/proc` — `grub-probe` and `os-prober` read `/proc/self/mountinfo` and `/proc/devices` to resolve mount points and device‑mapper targets. Without it: `failed to get canonical path` or wrong `root=`.
* `/sys` — GRUB reads `/sys/block/*` for device topology (partition offsets, MD/LVM members) and, on UEFI, `efibootmgr` reads `/sys/firmware/efi/efivars`.

**A9.2** — `--rbind` recursively binds a mount and all its submounts; `--make-rslave` sets propagation so mount and unmount events travel *from* the host *into* the chroot but not back. Without it, the chroot's mounts share a peer group with the host's, and `umount -R /mnt` propagates outward — unmounting the live system's own `/dev`, `/proc` or `/sys` and rendering the rescue environment unusable.

**A9.3** — `efibootmgr` reads and writes UEFI NVRAM boot variables (`BootOrder`, `Boot####`) exclusively through the `efivarfs` filesystem at `/sys/firmware/efi/efivars`; `grub-install` invokes it to register the new loader. Without efivarfs it fails with `EFI variables are not supported on this system`. Pass `--no-nvram` to install the binaries and skip the NVRAM update, or `--removable` to install to the fallback path that needs no NVRAM entry at all.

**A9.4** — `chroot` itself fails, or every binary inside fails, with `Exec format error`: a 32‑bit kernel cannot execute the 64‑bit `/bin/bash` of the target system. The chroot's architecture must be executable by the running kernel. A 64‑bit live ISO can chroot into a 32‑bit system (with the right multilib libraries present in the target), but never the reverse.

**A9.5** — (1) **Firmware boot order**: on UEFI the NVRAM `BootOrder` still lists the other OS first — fix with `efibootmgr -o`. On BIOS, the firmware is booting a different physical disk than the one you installed to. (2) **Wrong disk**: you installed to `/dev/vda` while the firmware boots `/dev/vdb`; in a chroot the device names may not match what the firmware enumerates. Also possible: the machine boots via UEFI while you installed `i386-pc`, so the new loader is never reached.

**A9.6** — **shim** (`shimx64.efi`), the Microsoft‑signed first‑stage loader that validates and loads `grubx64.efi`. `grub-install` installs GRUB but does not provide shim; you need the distribution's `shim-signed` package and an NVRAM entry pointing at `\EFI\<vendor>\shimx64.efi`, not at `grubx64.efi` directly. Check Secure Boot state with `mokutil --sb-state` (or `bootctl status`, which also reports the loader chain).

### Exercise 10

**A10.1** —

| GRUB Legacy | GRUB 2 (msdos) | GRUB 2 (gpt) |
|---|---|---|
| `(hd0,0)` | `(hd0,msdos1)` | `(hd0,gpt1)` |
| `(hd0,4)` | `(hd0,msdos5)` — first logical partition | — (GPT has no extended/logical partitions) |
| `(hd1,2)` | `(hd1,msdos3)` | `(hd1,gpt3)` |

Rule: **GRUB Legacy counts disks and partitions from 0.** **GRUB 2 counts disks from 0 but partitions from 1**, and prefixes the partition number with the table type. GRUB 2 also accepts the bare `(hd0,1)`, treating it as `msdos1`.

**A10.2** —

| GRUB Legacy | GRUB 2 |
|---|---|
| `title X` | `menuentry 'X' { ... }` |
| `root (hd0,0)` | `set root=(hd0,msdos1)` — or, preferably, `search --fs-uuid --set=root <uuid>` |
| `kernel /vmlinuz ...` | `linux /vmlinuz ...` (`linux16` for legacy 16‑bit boot protocol) |
| `initrd /initrd.img` | `initrd /initrd.img` (unchanged; `initrd16` for the 16‑bit variant) |
| `default=0` | `set default=0` — from `GRUB_DEFAULT` |
| `timeout=5` | `set timeout=5` — from `GRUB_TIMEOUT` |
| `hiddenmenu` | `set timeout_style=hidden` — from `GRUB_TIMEOUT_STYLE` |

**A10.3** — `stage1_5` is a small filesystem‑specific driver (`e2fs_stage1_5`, `reiserfs_stage1_5`, `xfs_stage1_5`, …) embedded in the MBR gap. It exists because `stage1` fits in 446 bytes — enough to load a fixed block list, not enough to understand a filesystem — so `stage1_5` provides just enough filesystem knowledge to locate `/boot/grub/stage2` **by path** rather than by block list. GRUB 2 replaced the whole `stage1_5`/`stage2` split with a single `core.img` assembled at install time from exactly the modules that system needs, which is why GRUB 2 has one embedding artefact instead of a per‑filesystem zoo.

**A10.4** — `root` sets the device *and* mounts/verifies the filesystem, printing its type — GRUB Legacy must read Linux kernels from it. `rootnoverify` sets the device without attempting to read a filesystem, which is required for filesystems GRUB does not understand (NTFS on old builds) and for chainloading generally. `chainloader +1` loads the first sector of that partition (`+1` is a block list meaning "1 block starting at block 0") and jumps to it, handing control to the other OS's own boot loader. GRUB 2 merged these: `set root=` never verifies, and `chainloader +1` is unchanged.

**A10.5** — Nothing regenerates the menu, so a new kernel package must edit `menu.lst` itself — and if that edit is wrong or skipped, the system boots the old kernel or nothing at all. Red Hat compensated with `/sbin/new-kernel-pkg` (called from the kernel RPM's `%post` scriptlet), plus `grubby`, a command‑line tool that patches boot loader configs in place (`grubby --default-kernel`, `grubby --update-kernel=ALL --args=...`). `grubby` survives today on RHEL/Fedora as the supported way to modify entries without regenerating.

**A10.6** — The `password --md5` hash line. Mode `0600` prevents unprivileged local users reading the hash and attacking it offline. GRUB 2's equivalent is that `grub.cfg` on Red Hat systems is likewise restricted when `GRUB_PASSWORD` is in use, and more importantly that GRUB 2 uses `password_pbkdf2` with a salted PBKDF2‑SHA512 hash rather than unsalted MD5 — so exposure of the hash is far less immediately damaging. Best practice is to keep the credential in `/etc/grub.d/01_users` (mode `0700`) rather than in the world‑readable generated file.

### Exercise 11

**A11.1** — Nothing does — the chain is shorter. UEFI firmware understands FAT32 and reads an executable **EFI application** directly from the EFI System Partition, so there is no 446‑byte stage and no embedding area. `core.img` is written as a PE/COFF file, `grubx64.efi`, into `/boot/efi/EFI/<vendor>/` on the ESP, with the modules it needs either built in or alongside in `/boot/grub/x86_64-efi/`. This is why UEFI boot repair is a file copy plus an NVRAM entry, while BIOS boot repair is a raw sector write.

**A11.2** — The UEFI specification defines device paths using the FAT/DOS convention, with backslash as the path separator, and `efibootmgr` writes the path verbatim into the NVRAM variable. `/boot/efi/EFI/debian/` is the Linux **mount point** of that same FAT filesystem, so it follows POSIX conventions. Same file, two namespaces. Quote the backslash path in the shell (`'\EFI\debian\grubx64.efi'`) or it will be mangled by backslash processing.

**A11.3** — It is the **fallback / removable media path** defined by the UEFI specification: when the firmware finds no valid `Boot####` entry, or is booting removable media, it looks for `\EFI\BOOT\BOOTX64.EFI` on the ESP of each device. `--removable` saves you (1) when NVRAM has been cleared or corrupted — a CMOS reset, a firmware update, a motherboard replacement — and (2) when producing an image or USB stick that must boot on a machine whose NVRAM has never heard of it. The cost: no vendor‑specific entry, and a second OS installing to the same fallback path will overwrite it.

**A11.4** — The firmware verifies `shimx64.efi` against a Microsoft‑signed certificate in its db. Shim then verifies `grubx64.efi` against the distribution's own embedded certificate — this is what lets a distro ship updates without Microsoft re‑signing every build. GRUB in turn verifies the kernel's signature before calling `linux`, and the kernel enforces module signatures and lockdown. `mmx64.efi` is **MokManager**: the UI invoked at boot to enrol Machine Owner Keys, so a site can sign its own kernel or out‑of‑tree modules (NVIDIA, VirtualBox, DKMS builds) and have shim trust them.

**A11.5** — Because the ESP is FAT32, which has no ownership, permissions, symlinks or journalling, and is shared with other operating systems that may rewrite or reformat it. Keeping only a three‑line locator there — `search` for `/boot`'s UUID, `set prefix`, `configfile` — means the real `grub.cfg`, the module directory, `grubenv` and the kernels all live on a proper Linux filesystem, and `grub-mkconfig` never has to touch the ESP. It also means the same GRUB binary works after `/boot` moves to a different disk.

**A11.6** — (1) The system booted in **BIOS/CSM mode**, so no EFI runtime services exist at all — verify with `[ -d /sys/firmware/efi ]`. (2) **`efivarfs` is not mounted**, typically inside a chroot or a minimal rescue environment — fix with `mount -t efivarfs efivarfs /sys/firmware/efi/efivars`. A third, rarer cause: the kernel was booted with `noefi` or `efi=noruntime`, or the firmware exposes the variables read‑only.

</details>

---

## References

* LPI — Exam 101‑500 Objectives (v5.0), Topic 102.2: https://www.lpi.org/our-certifications/exam-101-objectives/
* GNU GRUB Manual 2.x — Installation, Configuration, Command shell, Network/rescue: https://www.gnu.org/software/grub/manual/grub/grub.html
* GNU GRUB Manual — `grub-install` invocation: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dinstall
* GNU GRUB Legacy Manual (0.97) — `menu.lst`, `setup`, stage files: https://www.gnu.org/software/grub/manual/legacy/grub.html
* The Linux Kernel — The kernel's command-line parameters: https://docs.kernel.org/admin-guide/kernel-parameters.html
* systemd — `bootup(7)`, boot process and targets: https://www.freedesktop.org/software/systemd/man/latest/bootup.html
* systemd — `systemd(1)`, kernel command line options (`systemd.unit=`): https://www.freedesktop.org/software/systemd/man/latest/systemd.html
* UEFI Forum — UEFI Specification (boot manager, device paths, fallback path): https://uefi.org/specifications
* util-linux — `fdisk(8)`, `lsblk(8)`, `sfdisk(8)`: https://github.com/util-linux/util-linux/blob/master/Documentation/
* GNU coreutils — `dd` invocation: https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
* rhboot/efibootmgr — usage and options: https://github.com/rhboot/efibootmgr
* rhboot/shim — Secure Boot chain and MokManager: https://github.com/rhboot/shim