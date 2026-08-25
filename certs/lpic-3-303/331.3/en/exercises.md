# 331.3 — Encrypted File Systems
## Guided Exercises · LPIC-3 303 (exam 303-300, v3.0.0) · Exam weight 5

> **Lab safety.** Every command below operates on **loop devices backed by sparse files** inside a disposable VM or container with a real kernel. Never point `cryptsetup luksFormat`, `tune2fs -O encrypt` or `dd` at a device path you have not verified with `lsblk` first — `luksFormat` overwrites the header unconditionally and there is no undo. Run the whole document as `root` (or prefix with `sudo`) unless a step says otherwise.

**Reference environment used for the expected outputs**

| Component | Version |
|---|---|
| Kernel | 6.6 (LTS) |
| `cryptsetup` | 2.6.1 |
| `ecryptfs-utils` | 111 |
| `fscrypt` | 0.3.4 |
| `clevis` / `tang` | 19 / 14 |
| `cryptmount` | 6.2.0 |

Numeric values (UUIDs, salts, iteration counts, MiB/s) **will differ on your machine**. What must match is the *structure* of the output — that is what the questions test.

**Packages**

```bash
# Debian/Ubuntu
apt-get install -y cryptsetup cryptsetup-bin ecryptfs-utils fscrypt \
                   keyutils clevis clevis-luks clevis-systemd tang jose \
                   cryptmount gdisk

# RHEL/Fedora/openSUSE
dnf install -y cryptsetup ecryptfs-utils fscrypt keyutils \
               clevis clevis-luks clevis-dracut tang jose
```

**Reference sources**

- LPI 303-300 objectives — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- `cryptsetup` project & LUKS2 on-disk format spec — <https://gitlab.com/cryptsetup/cryptsetup> · <https://gitlab.com/cryptsetup/LUKS2-docs>
- `cryptsetup` FAQ (authoritative on threat model and recovery) — <https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions>
- Kernel `dm-crypt` — <https://docs.kernel.org/admin-guide/device-mapper/dm-crypt.html>
- Kernel `dm-integrity` — <https://docs.kernel.org/admin-guide/device-mapper/dm-integrity.html>
- Kernel `fscrypt` — <https://docs.kernel.org/filesystems/fscrypt.html>
- Kernel `eCryptfs` — <https://docs.kernel.org/filesystems/ecryptfs.html>
- `systemd` `crypttab(5)` — <https://www.freedesktop.org/software/systemd/man/latest/crypttab.html>
- `systemd-cryptsetup-generator(8)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup-generator.html>
- Clevis — <https://github.com/latchset/clevis> · Tang — <https://github.com/latchset/tang>
- `cryptmount` — <https://cryptmount.sourceforge.net/>

---

## Exercise 0 — Build the lab block devices

### Steps

1. Create a working directory and four sparse backing files.

    ```bash
    mkdir -p /root/cryptolab && cd /root/cryptolab
    for n in 1 2 3 4; do
        truncate -s 256M disk${n}.img
    done
    ls -lh
    du -sh --apparent-size disk1.img
    du -sh disk1.img
    ```

2. Confirm the files are sparse — apparent size 256 MiB, allocated size 0.

    ```
    256M	disk1.img      # --apparent-size
    0	disk1.img          # actually allocated
    ```

3. Attach each file to a loop device and list the mapping.

    ```bash
    for n in 1 2 3 4; do
        losetup --find --show /root/cryptolab/disk${n}.img
    done
    losetup -a
    ```

    ```
    /dev/loop0
    /dev/loop1
    /dev/loop2
    /dev/loop3
    /dev/loop0: [2049]:1179651 (/root/cryptolab/disk1.img)
    /dev/loop1: [2049]:1179652 (/root/cryptolab/disk2.img)
    /dev/loop2: [2049]:1179653 (/root/cryptolab/disk3.img)
    /dev/loop3: [2049]:1179654 (/root/cryptolab/disk4.img)
    ```

4. Verify the crypto stack the kernel actually offers you.

    ```bash
    modprobe dm_crypt dm_integrity ecryptfs
    dmsetup targets
    grep -E 'name|driver|module' /proc/crypto | grep -A2 -i 'xts' | head -20
    ```

    ```
    integrity        v1.10.0
    crypt            v1.24.0
    striped          v1.6.0
    linear           v1.4.0
    ```

5. Baseline the machine's KDF and cipher performance. This is the number that decides your `--pbkdf-*` tuning later.

    ```bash
    cryptsetup benchmark
    ```

    ```
    # Tests are approximate using memory only (no storage IO).
    PBKDF2-sha1      1975431 iterations per second for 256-bit key
    PBKDF2-sha256    2612088 iterations per second for 256-bit key
    PBKDF2-sha512    1010774 iterations per second for 256-bit key
    PBKDF2-ripemd160  920330 iterations per second for 256-bit key
    PBKDF2-whirlpool  481902 iterations per second for 256-bit key
    argon2i       4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
    argon2id      4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
    #     Algorithm |       Key |      Encryption |      Decryption
            aes-cbc        128b      1012.4 MiB/s      3210.5 MiB/s
        serpent-cbc        128b        88.6 MiB/s       630.2 MiB/s
        twofish-cbc        128b       190.3 MiB/s       360.1 MiB/s
            aes-cbc        256b       760.2 MiB/s      2540.8 MiB/s
            aes-xts        256b      2810.3 MiB/s      2802.1 MiB/s
            aes-xts        512b      2350.6 MiB/s      2341.0 MiB/s
        serpent-xts        512b       582.1 MiB/s       571.3 MiB/s
        twofish-xts        512b       351.2 MiB/s       353.0 MiB/s
    ```

### Check your understanding

- **Q0.1** — Why does `cryptsetup benchmark` report AES-CBC *decryption* several times faster than encryption, while AES-XTS is symmetric?
- **Q0.2** — In the benchmark table, `aes-xts 512b` means AES-256, not AES-512. Explain the factor of two.
- **Q0.3** — A sparse backing file makes a subtle security point in this lab that would not apply to a real disk. What is it?
- **Q0.4** — `argon2id` reports `1048576 memory`. What unit is that, and what attack class does that parameter target that PBKDF2 iterations do not?

---

## Exercise 1 — LUKS1 vs LUKS2: format the containers and read the headers

### Steps

1. Format `/dev/loop0` as **LUKS1**, forcing every parameter explicitly so nothing depends on the distro default.

    ```bash
    cryptsetup luksFormat \
        --type luks1 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --iter-time 2000 \
        --use-urandom \
        --batch-mode \
        /dev/loop0 <<< 'LabPass-LUKS1'
    ```

2. Format `/dev/loop1` as **LUKS2** with the modern defaults plus a 4096-byte encryption sector.

    ```bash
    cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --pbkdf argon2id \
        --sector-size 4096 \
        --label VAULT \
        --use-urandom \
        --batch-mode \
        /dev/loop1 <<< 'LabPass-LUKS2'
    ```

3. Dump the LUKS1 header.

    ```bash
    cryptsetup luksDump /dev/loop0
    ```

    ```
    LUKS header information for /dev/loop0

    Version:       	1
    Cipher name:   	aes
    Cipher mode:   	xts-plain64
    Hash spec:     	sha256
    Payload offset:	4096
    MK bits:       	512
    MK digest:     	c1 9d 4f 0a 22 6e 3b 77 1a 84 d0 5c 9e 31 aa 62 08 b4 7f d3
    MK salt:       	3f 82 1c 55 a9 0e 6b 24 d7 90 4e 11 c8 3a 5f 6d
                   	e2 71 08 bb 94 3c 5a 17 f0 62 8d 49 21 ce 7b 30
    MK iterations: 	187500
    UUID:          	4b0f8a12-7c3e-4d55-9f21-6ab08e3c17d9

    Key Slot 0: ENABLED
    	Iterations:         	2998421
    	Salt:               	7a 41 d9 3e 08 c2 66 5b 1f 90 ad 74 32 e8 5c 0b
    	                      	95 d3 27 6a 4e 8f 11 c0 3b 72 de 59 a4 06 8c 1d
    	Key material offset:	8
    	AF stripes:            	4000
    Key Slot 1: DISABLED
    Key Slot 2: DISABLED
    Key Slot 3: DISABLED
    Key Slot 4: DISABLED
    Key Slot 5: DISABLED
    Key Slot 6: DISABLED
    Key Slot 7: DISABLED
    ```

4. Dump the LUKS2 header and then the raw JSON metadata.

    ```bash
    cryptsetup luksDump /dev/loop1
    ```

    ```
    LUKS header information
    Version:       	2
    Epoch:         	3
    Metadata area: 	16384 [bytes]
    Keyslots area: 	16744448 [bytes]
    UUID:          	9d2c71fa-05be-4e83-b6a7-c4180e29f5b1
    Label:         	VAULT
    Subsystem:     	(no subsystem)
    Flags:       	(no flags)

    Data segments:
      0: crypt
    	offset: 16777216 [bytes]
    	length: (whole device)
    	cipher: aes-xts-plain64
    	sector: 4096 [bytes]

    Keyslots:
      0: luks2
    	Key:        512 bits
    	Priority:   normal
    	Cipher:     aes-xts-plain64
    	Cipher key: 512 bits
    	PBKDF:      argon2id
    	Time cost:  7
    	Memory:     1048576
    	Threads:    4
    	Salt:       6e 03 b1 7d 4a 22 98 ef 55 c7 10 3b 8d 64 f9 02
    	            a1 5e 37 cb 80 12 6f d4 29 b3 7a 0c e6 41 95 8b
    	AF stripes: 4000
    	AF hash:    sha256
    	Area offset:32768 [bytes]
    	Area length:258048 [bytes]
    	Digest ID:  0
    Tokens:
    Digests:
      0: pbkdf2
    	Hash:       sha256
    	Iterations: 129774
    	Salt:       b7 2a 6c 91 03 de 48 f5 1c 87 30 a9 62 4b ff 15
    	            0d 93 71 e8 5a 24 c6 3f 8e b0 47 92 d1 6a 35 cc
    	Digest:     4f 81 a3 20 7b 9c 5e 16 d8 03 62 af 7d 41 e9 58
    	            30 cb 74 2a
    ```

    ```bash
    cryptsetup luksDump --dump-json-metadata /dev/loop1 | jq '.keyslots, .segments, .config'
    ```

    ```json
    {
      "0": {
        "type": "luks2",
        "key_size": 64,
        "af": { "type": "luks1", "stripes": 4000, "hash": "sha256" },
        "area": { "type": "raw", "offset": "32768", "size": "258048",
                  "encryption": "aes-xts-plain64", "key_size": 64 },
        "kdf": { "type": "argon2id", "time": 7, "memory": 1048576, "cpus": 4,
                 "salt": "bgOxfUoimO9Vxx..." }
      }
    }
    {
      "0": { "type": "crypt", "offset": "16777216", "size": "dynamic",
             "iv_tweak": "0", "encryption": "aes-xts-plain64", "sector_size": 4096 }
    }
    { "json_size": "12288", "keyslots_size": "16744448" }
    ```

5. Prove where the plaintext data actually starts, in bytes, on each container.

    ```bash
    echo "LUKS1 payload offset: $(( 4096 * 512 )) bytes"
    cryptsetup luksDump /dev/loop1 | awk '/offset:/ {print "LUKS2 data offset: " $2 " bytes"; exit}'
    blkid /dev/loop0 /dev/loop1
    ```

    ```
    LUKS1 payload offset: 2097152 bytes
    LUKS2 data offset: 16777216 bytes
    /dev/loop0: UUID="4b0f8a12-7c3e-4d55-9f21-6ab08e3c17d9" TYPE="crypto_LUKS" VERSION="1"
    /dev/loop1: UUID="9d2c71fa-05be-4e83-b6a7-c4180e29f5b1" LABEL="VAULT" TYPE="crypto_LUKS" VERSION="2"
    ```

### Check your understanding

- **Q1.1** — LUKS1 reserves 2 MiB before the payload; LUKS2 reserves 16 MiB. Where does the extra 14 MiB go, and which LUKS2 feature makes it necessary?
- **Q1.2** — The LUKS1 dump shows both `MK iterations: 187500` and `Key Slot 0 → Iterations: 2998421`. Why are these two numbers different by an order of magnitude, and what is each one protecting?
- **Q1.3** — `AF stripes: 4000` appears in both headers. Explain anti-forensic splitting and what concrete attack it defeats.
- **Q1.4** — The LUKS2 container was created with `--sector-size 4096`. Name one performance benefit and one hard constraint this imposes on the underlying device.
- **Q1.5** — `blkid` prints `TYPE="crypto_LUKS"` for both devices. Why can `blkid` read this while the filesystem inside remains unreadable?

---

## Exercise 2 — Key slots, passphrase lifecycle and key files

### Steps

1. Open the LUKS2 container, put a filesystem on it, write a marker file, and inspect the active mapping.

    ```bash
    echo -n 'LabPass-LUKS2' | cryptsetup open /dev/loop1 vault -
    mkfs.ext4 -q -L vaultfs /dev/mapper/vault
    mkdir -p /mnt/vault && mount /dev/mapper/vault /mnt/vault
    echo "topic 331.3 marker $(date -u +%FT%TZ)" > /mnt/vault/marker.txt
    cryptsetup status vault
    ```

    ```
    /dev/mapper/vault is active and is in use.
      type:    LUKS2
      cipher:  aes-xts-plain64
      keysize: 512 bits
      key location: keyring
      device:  /dev/loop1
      loop:    /root/cryptolab/disk2.img
      sector size:  4096
      offset:  32768 sectors
      size:    491520 sectors
      mode:    read/write
    ```

2. Look at the device-mapper table. Note that the master key is **not** printed.

    ```bash
    dmsetup table vault
    dmsetup table --showkeys vault
    ```

    ```
    0 491520 crypt aes-xts-plain64 :64:logon:cryptsetup:9d2c71fa-05be-4e83-b6a7-c4180e29f5b1-d0 0 7:1 32768 1 sector_size:4096
    0 491520 crypt aes-xts-plain64 :64:logon:cryptsetup:9d2c71fa-05be-4e83-b6a7-c4180e29f5b1-d0 0 7:1 32768 1 sector_size:4096
    ```

3. Generate a high-entropy key file and add it to a **specific** slot.

    ```bash
    mkdir -p /etc/luks-keys && chmod 700 /etc/luks-keys
    dd if=/dev/urandom of=/etc/luks-keys/vault.key bs=512 count=8 status=none
    chmod 400 /etc/luks-keys/vault.key

    echo -n 'LabPass-LUKS2' | cryptsetup luksAddKey \
        --key-file=- \
        --key-slot 3 \
        /dev/loop1 /etc/luks-keys/vault.key
    ```

4. Add a second human passphrase to slot 1, then list slot usage compactly.

    ```bash
    printf 'LabPass-LUKS2\nBackupPass-2026\nBackupPass-2026\n' | \
        cryptsetup luksAddKey --key-slot 1 /dev/loop1

    cryptsetup luksDump /dev/loop1 | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -E '^\s+[0-9]+:'
    ```

    ```
      0: luks2
      1: luks2
      3: luks2
    ```

5. Test each credential **without** activating the device.

    ```bash
    echo -n 'LabPass-LUKS2'  | cryptsetup open --test-passphrase --key-file=- /dev/loop1 && echo "slot ok: primary"
    echo -n 'BackupPass-2026'| cryptsetup open --test-passphrase --key-file=- /dev/loop1 && echo "slot ok: backup"
    cryptsetup open --test-passphrase --key-file /etc/luks-keys/vault.key /dev/loop1 && echo "slot ok: keyfile"
    echo -n 'wrong' | cryptsetup open --test-passphrase --key-file=- /dev/loop1 ; echo "exit=$?"
    ```

    ```
    slot ok: primary
    slot ok: backup
    slot ok: keyfile
    No key available with this passphrase.
    exit=2
    ```

6. Determine *which* slot a given passphrase opens.

    ```bash
    echo -n 'BackupPass-2026' | cryptsetup open --test-passphrase --key-file=- --verbose /dev/loop1
    ```

    ```
    Key slot 1 unlocked.
    Command successful.
    ```

7. Rotate: change the primary passphrase in place, then revoke the backup passphrase's slot.

    ```bash
    printf 'LabPass-LUKS2\nRotated-2026-Q3\nRotated-2026-Q3\n' | \
        cryptsetup luksChangeKey --key-slot 0 /dev/loop1

    echo -n 'Rotated-2026-Q3' | cryptsetup luksKillSlot --key-file=- /dev/loop1 1
    cryptsetup luksDump /dev/loop1 | grep -cE '^\s+[0-9]+: luks2'
    ```

    ```
    2
    ```

8. Set slot priorities so the key file is tried first at boot and the emergency passphrase never is, unless requested.

    ```bash
    cryptsetup config --key-slot 3 --priority prefer /dev/loop1
    cryptsetup config --key-slot 0 --priority normal /dev/loop1
    cryptsetup luksDump /dev/loop1 | grep -A2 -E '^\s+[03]: luks2' | grep -E 'Priority|luks2'
    ```

    ```
      0: luks2
    	Priority:   normal
      3: luks2
    	Priority:   prefer
    ```

### Check your understanding

- **Q2.1** — `dmsetup table --showkeys` printed `:64:logon:cryptsetup:<uuid>-d0` instead of hex key material, even though you asked for keys. What changed in cryptsetup 2.x to cause this, and what is the security gain?
- **Q2.2** — You added a key file at slot 3 and killed slot 1. Does killing a slot re-encrypt any data? Explain what actually happens on disk, in terms of the master key.
- **Q2.3** — `cryptsetup luksChangeKey --key-slot 0` versus `luksAddKey` followed by `luksKillSlot 0`: name the operational difference that matters during an unattended rotation, and which one you should prefer.
- **Q2.4** — The key file is 4096 bytes of `/dev/urandom`. LUKS reads the whole file by default. What goes wrong if an administrator later "cleans up" that file by appending a newline, and which `crypttab`/CLI option is the standard defence?
- **Q2.5** — Slot priority `prefer` was set on the key-file slot. What does `prefer` actually change at unlock time — is it a security control or a latency control?

---

## Exercise 3 — Header backup, header destruction, detached headers

### Steps

1. Back up the LUKS2 header before you break it.

    ```bash
    cryptsetup luksHeaderBackup /dev/loop1 \
        --header-backup-file /root/cryptolab/vault-header-$(date -u +%Y%m%d).img
    ls -l /root/cryptolab/vault-header-*.img
    chmod 400 /root/cryptolab/vault-header-*.img
    ```

    ```
    -rw------- 1 root root 16777216 Aug 20 11:04 /root/cryptolab/vault-header-20260820.img
    ```

2. Unmount, close, and destroy the first 4 MiB of the container — simulating a stray `dd` or a partitioner writing a new GPT.

    ```bash
    umount /mnt/vault
    cryptsetup close vault
    dd if=/dev/urandom of=/dev/loop1 bs=1M count=4 conv=notrunc status=none
    cryptsetup luksDump /dev/loop1 ; echo "exit=$?"
    ```

    ```
    Device /dev/loop1 is not a valid LUKS device.
    exit=1
    ```

3. Restore the header and confirm the data survived intact.

    ```bash
    cryptsetup luksHeaderRestore /dev/loop1 \
        --header-backup-file /root/cryptolab/vault-header-20260820.img --batch-mode
    echo -n 'Rotated-2026-Q3' | cryptsetup open --key-file=- /dev/loop1 vault
    mount /dev/mapper/vault /mnt/vault
    cat /mnt/vault/marker.txt
    ```

    ```
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

4. Build a **detached header** container on `/dev/loop2`: the header lives in a separate file, the block device holds nothing but ciphertext.

    ```bash
    truncate -s 16M /root/cryptolab/hidden.hdr
    cryptsetup luksFormat --type luks2 \
        --header /root/cryptolab/hidden.hdr \
        --batch-mode /dev/loop2 <<< 'DetachedPass'

    blkid /dev/loop2 ; echo "blkid exit=$?"
    file /root/cryptolab/hidden.hdr
    ```

    ```
    blkid exit=2
    /root/cryptolab/hidden.hdr: LUKS encrypted file, ver 2 [aes, xts-plain64, sha256] UUID: 1c74e0b9-...
    ```

5. Open it, note the data offset, and close it.

    ```bash
    echo -n 'DetachedPass' | cryptsetup open --header /root/cryptolab/hidden.hdr \
        --key-file=- /dev/loop2 hidden
    cryptsetup status hidden | grep -E 'offset|device|type'
    cryptsetup close hidden
    ```

    ```
      type:    LUKS2
      device:  /dev/loop2
      offset:  0 sectors
    ```

6. Demonstrate the irreversible operation: wipe all key slots on the (now unused) `/dev/loop3` after formatting it.

    ```bash
    cryptsetup luksFormat --type luks2 --batch-mode /dev/loop3 <<< 'Doomed'
    cryptsetup luksErase --batch-mode /dev/loop3
    cryptsetup luksDump /dev/loop3 | grep -A1 '^Keyslots:'
    echo -n 'Doomed' | cryptsetup open --test-passphrase --key-file=- /dev/loop3; echo "exit=$?"
    ```

    ```
    Keyslots:
    Digests:
    No usable keyslot is available.
    exit=1
    ```

### Check your understanding

- **Q3.1** — After `luksHeaderRestore`, the passphrase `BackupPass-2026` that you killed in Exercise 2 would work again if the backup predated the kill. State the operational rule this implies for header backups.
- **Q3.2** — With a detached header, `cryptsetup status` reports `offset: 0 sectors`. Why, and what does that mean for the usable capacity of `/dev/loop2` compared to `/dev/loop1`?
- **Q3.3** — Detached headers are often described as giving "plausible deniability". Give one reason that claim is weaker than it sounds against a competent forensic examiner.
- **Q3.4** — `luksErase` completed in milliseconds on a 256 MiB device. Explain why the *data* is nevertheless unrecoverable, and name the property this exploits (the same one that makes LUKS "instant wipe" possible on a 20 TB array).
- **Q3.5** — Why is a header backup file more sensitive than the encrypted disk itself, and what must you do to a header backup when you decommission a passphrase?

---

## Exercise 4 — `/etc/crypttab`, `systemd-cryptsetup` and boot-time unlock

### Steps

1. Collect the UUIDs you will reference. **Never** put `/dev/loopN` or `/dev/sdX` in `crypttab` on a real system.

    ```bash
    VAULT_UUID=$(cryptsetup luksUUID /dev/loop1)
    echo "$VAULT_UUID"
    ```

    ```
    9d2c71fa-05be-4e83-b6a7-c4180e29f5b1
    ```

2. Write a `crypttab` covering the four canonical cases: passphrase prompt, key file, detached header, and random-key swap.

    ```bash
    cat > /etc/crypttab <<EOF
    # <name>   <source device>                  <key file>                  <options>
    vault      UUID=${VAULT_UUID}               /etc/luks-keys/vault.key    luks,discard,nofail,x-systemd.device-timeout=10s
    archive    UUID=00000000-0000-0000-0000-000000000001  none              luks,tries=3,timeout=30s,noauto
    hidden     /dev/loop2                       none                        luks,header=/root/cryptolab/hidden.hdr,noauto
    cryptswap  /dev/vg0/swap                    /dev/urandom                swap,cipher=aes-xts-plain64,size=512,sector-size=4096,hash=sha256
    EOF
    ```

3. Ask systemd to translate `crypttab` into units and inspect the generated unit.

    ```bash
    systemctl daemon-reload
    ls /run/systemd/generator/*.service | grep cryptsetup
    systemctl cat systemd-cryptsetup@vault.service | head -30
    ```

    ```
    /run/systemd/generator/systemd-cryptsetup@vault.service
    /run/systemd/generator/systemd-cryptsetup@archive.service
    /run/systemd/generator/systemd-cryptsetup@hidden.service
    /run/systemd/generator/systemd-cryptsetup@cryptswap.service

    # /run/systemd/generator/systemd-cryptsetup@vault.service
    [Unit]
    Description=Cryptography Setup for vault
    Documentation=man:crypttab(5) man:systemd-cryptsetup-generator(8) man:systemd-cryptsetup@.service(8)
    SourcePath=/etc/crypttab
    DefaultDependencies=no
    IgnoreOnIsolate=true
    After=cryptsetup-pre.target systemd-udevd-kernel.socket
    Before=blockdev@dev-mapper-vault.target
    Wants=blockdev@dev-mapper-vault.target
    BindsTo=dev-disk-by\x2duuid-9d2c71fa...device
    Before=umount.target cryptsetup.target
    Conflicts=umount.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    TimeoutSec=0
    ExecStart=/usr/lib/systemd/systemd-cryptsetup attach 'vault' '/dev/disk/by-uuid/9d2c71fa...' '/etc/luks-keys/vault.key' 'luks,discard,nofail,x-systemd.device-timeout=10s'
    ExecStop=/usr/lib/systemd/systemd-cryptsetup detach 'vault'
    ```

4. Exercise the unit path manually.

    ```bash
    umount /mnt/vault 2>/dev/null
    cryptsetup close vault 2>/dev/null
    systemctl start systemd-cryptsetup@vault.service
    systemctl is-active systemd-cryptsetup@vault.service
    lsblk -o NAME,FSTYPE,MOUNTPOINT /dev/loop1
    ```

    ```
    active
    NAME    FSTYPE      MOUNTPOINT
    loop1   crypto_LUKS
    └─vault ext4
    ```

5. Add the matching `fstab` line so the filesystem follows the mapping.

    ```bash
    printf '/dev/mapper/vault  /mnt/vault  ext4  defaults,nofail,x-systemd.requires=systemd-cryptsetup@vault.service  0 2\n' >> /etc/fstab
    systemctl daemon-reload
    mount /mnt/vault
    findmnt /mnt/vault
    ```

    ```
    TARGET     SOURCE            FSTYPE OPTIONS
    /mnt/vault /dev/mapper/vault ext4   rw,relatime
    ```

6. Turn on TRIM pass-through persistently at the LUKS layer instead of via `crypttab`.

    ```bash
    cryptsetup close vault && umount /mnt/vault 2>/dev/null
    cryptsetup --allow-discards --persistent open --key-file /etc/luks-keys/vault.key /dev/loop1 vault
    cryptsetup luksDump /dev/loop1 | grep -i flags
    ```

    ```
    Flags:       	allow-discards
    ```

### Check your understanding

- **Q4.1** — The `cryptswap` line uses `/dev/urandom` as key file and omits `luks`. What mode is that, and why is a fresh random key per boot *correct* for swap but catastrophic for `/home`?
- **Q4.2** — The `archive` entry uses `none` as key file with `tries=3,timeout=30s`. Where does the prompt appear during boot, and which systemd component collects the answer?
- **Q4.3** — What breaks if you write `/dev/mapper/vault /mnt/vault ext4 defaults 0 2` in `fstab` without `nofail` or `x-systemd.requires=`, and the key file is on a filesystem that mounts later?
- **Q4.4** — `--persistent` wrote `allow-discards` into the LUKS2 header. State the information-leak trade-off of enabling discards on an encrypted SSD, and why the flag cannot be stored this way on LUKS1.
- **Q4.5** — For a LUKS volume unlocked over the network (Exercise 7), which single `crypttab` option is mandatory, and what would happen without it?

---

## Exercise 5 — plain dm-crypt: no header, no safety net

### Steps

1. Detach the loop device you erased and reuse it for plain mode.

    ```bash
    cryptsetup close hidden 2>/dev/null
    wipefs -a /dev/loop3 >/dev/null 2>&1
    ```

2. Open `/dev/loop3` in **plain** mode with every parameter pinned. There is no format step — plain mode has nothing to write.

    ```bash
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --offset 0 \
        --skip 0 \
        --key-file=- \
        /dev/loop3 plainmap

    cryptsetup status plainmap
    ```

    ```
    /dev/mapper/plainmap is active.
      type:    PLAIN
      cipher:  aes-xts-plain64
      keysize: 512 bits
      key location: dm-crypt
      device:  /dev/loop3
      sector size:  512
      offset:  0 sectors
      size:    524288 sectors
      mode:    read/write
    ```

3. Create a filesystem, write a marker, close.

    ```bash
    mkfs.ext4 -q /dev/mapper/plainmap
    mkdir -p /mnt/plain && mount /dev/mapper/plainmap /mnt/plain
    echo 'plain-mode marker' > /mnt/plain/marker.txt
    umount /mnt/plain && cryptsetup close plainmap
    ```

4. Reopen with the **wrong** passphrase. Observe that `cryptsetup` succeeds anyway.

    ```bash
    echo -n 'WrongSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --key-file=- /dev/loop3 plainmap
    echo "cryptsetup exit=$?"
    mount /dev/mapper/plainmap /mnt/plain ; echo "mount exit=$?"
    ```

    ```
    cryptsetup exit=0
    mount: /mnt/plain: wrong fs type, bad option, bad superblock on /dev/mapper/plainmap, missing codepage or helper program, or other error.
    mount exit=32
    ```

5. Reopen with the *right* passphrase but a **different hash**, to show that the hash is part of the key derivation.

    ```bash
    cryptsetup close plainmap
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
        --key-file=- /dev/loop3 plainmap
    mount /dev/mapper/plainmap /mnt/plain ; echo "mount exit=$?"
    cryptsetup close plainmap
    ```

    ```
    mount: /mnt/plain: wrong fs type, bad option, bad superblock ...
    mount exit=32
    ```

6. Restore the correct combination and confirm.

    ```bash
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --key-file=- /dev/loop3 plainmap
    mount /dev/mapper/plainmap /mnt/plain && cat /mnt/plain/marker.txt
    umount /mnt/plain && cryptsetup close plainmap
    ```

    ```
    plain-mode marker
    ```

7. Confirm the device is indistinguishable from random data.

    ```bash
    blkid /dev/loop3; echo "blkid exit=$?"
    hexdump -C -n 64 /dev/loop3
    ```

    ```
    blkid exit=2
    00000000  d1 5b 8a 3f 07 c2 96 44  ae 21 f0 6d 39 bb 5c 82  |.[.?...D.!.m9.\.|
    00000010  1e 74 c9 05 60 d3 47 aa  8f 12 3b e6 70 95 2c 4d  |.t..`.G...;.p.,M|
    ...
    ```

### Check your understanding

- **Q5.1** — In step 4, `cryptsetup` returned 0 with a wrong passphrase. Explain precisely why plain mode cannot detect this, and what LUKS structure provides the check that is missing here.
- **Q5.2** — Steps 4 and 5 both fail at `mount`. Why is *silently mounting* a plain volume with the wrong key the more dangerous outcome, and what would happen if the volume held raw data with no superblock (e.g. a database raw device)?
- **Q5.3** — The exercise pinned `--cipher`, `--key-size`, `--hash`, `--offset` and `--skip`. Historically, cryptsetup changed its plain-mode defaults (cipher `aes-cbc-essiv:sha256` → `aes-xts-plain64`, hash `ripemd160` → `sha256`). What operational rule follows for anyone using plain mode?
- **Q5.4** — Name two legitimate production uses of plain dm-crypt where the absence of a header is an advantage rather than a defect.
- **Q5.5** — Plain mode derives the key by hashing the passphrase once. Compare that with LUKS2's Argon2id keyslot against an offline brute-force attacker.

---

## Exercise 6 — LUKS2 features: authenticated encryption, PBKDF tuning, reencryption, conversion

### Steps

1. Free `/dev/loop3` and create an **authenticated** LUKS2 volume with dm-integrity underneath. This wipes integrity tags across the whole device, so it takes a moment.

    ```bash
    cryptsetup close plainmap 2>/dev/null
    cryptsetup luksFormat --type luks2 \
        --cipher aes-gcm-random \
        --integrity aead \
        --key-size 256 \
        --sector-size 4096 \
        --batch-mode /dev/loop3 <<< 'AeadPass'
    ```

    ```
    Wiping device to initialize integrity checksum.
    You can interrupt this by pressing CTRL+c (rest of not wiped device will contain invalid checksum).
    Finished, time 00m07s,  240 MiB written, speed  32.8 MiB/s
    ```

2. Open it and observe the **stacked** device-mapper devices.

    ```bash
    echo -n 'AeadPass' | cryptsetup open --key-file=- /dev/loop3 sealed
    dmsetup ls --tree
    cryptsetup status sealed
    ```

    ```
    sealed (253:2)
     └─sealed_dif (253:1)
        └─ (7:3)

    /dev/mapper/sealed is active.
      type:    LUKS2
      cipher:  aes-gcm-random
      keysize: 256 bits
      integrity: aead
      integrity keysize: 0 bits
      device:  /dev/mapper/sealed_dif
      sector size:  4096
      offset:  0 sectors
      size:    465920 sectors
      mode:    read/write
    ```

3. Write data, then corrupt one ciphertext sector directly on the backing device and try to read it back.

    ```bash
    mkfs.ext4 -q /dev/mapper/sealed
    mkdir -p /mnt/sealed && mount /dev/mapper/sealed /mnt/sealed
    dd if=/dev/urandom of=/mnt/sealed/payload.bin bs=1M count=8 status=none
    sha256sum /mnt/sealed/payload.bin | tee /root/cryptolab/payload.sha
    sync; umount /mnt/sealed

    # flip bytes deep inside the data area
    dd if=/dev/urandom of=/dev/loop3 bs=4096 count=1 seek=20000 conv=notrunc status=none

    mount /dev/mapper/sealed /mnt/sealed
    sha256sum -c /root/cryptolab/payload.sha ; echo "exit=$?"
    dmesg | tail -4
    ```

    ```
    /mnt/sealed/payload.bin: FAILED open or read
    sha256sum: WARNING: 1 computed checksum did NOT match
    exit=1
    [  912.443100] device-mapper: crypt: sealed: INTEGRITY AEAD ERROR, sector 81920
    [  912.443118] Buffer I/O error on dev dm-2, logical block 10240, async page read
    ```

    > Compare: repeat the same corruption on `/dev/mapper/vault` (plain AES-XTS, no integrity) and the read **succeeds**, returning 4096 bytes of garbage with no error anywhere.

4. Tune the KDF for a memory-constrained target (a router, an embedded appliance) — Argon2 with 1 GiB is not viable there.

    ```bash
    umount /mnt/sealed; cryptsetup close sealed
    printf 'AeadPass\nLowMem\nLowMem\n' | cryptsetup luksAddKey \
        --pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 1 --pbkdf-force-iterations 8 \
        --key-slot 5 /dev/loop3
    cryptsetup luksDump /dev/loop3 | grep -A6 '^  5: luks2'
    ```

    ```
      5: luks2
    	Key:        256 bits
    	Priority:   normal
    	Cipher:     aes-gcm-random
    	Cipher key: 256 bits
    	PBKDF:      argon2id
    	Time cost:  8
    	Memory:     65536
    ```

5. Rotate the **master key** of the `vault` volume with online reencryption — the data stays mounted and readable throughout.

    ```bash
    mount /dev/mapper/vault /mnt/vault 2>/dev/null
    cryptsetup luksDump /dev/loop1 | grep -A3 '^Digests:' | grep Digest:
    cryptsetup reencrypt --active-name vault --key-file /etc/luks-keys/vault.key /dev/loop1
    cryptsetup luksDump /dev/loop1 | grep -A3 '^Digests:' | grep Digest:
    cat /mnt/vault/marker.txt
    ```

    ```
    	Digest:     4f 81 a3 20 7b 9c 5e 16 d8 03 62 af 7d 41 e9 58 30 cb 74 2a
    Progress:  100,0%, ETA 00:00, 240 MiB written, speed  61,3 MiB/s
    Finished, time 00m03s,  240 MiB written, speed  61,3 MiB/s
    	Digest:     9c 27 e0 4b 15 8a 63 d1 fe 40 39 b7 2c 8e 05 7a 61 d4 93 08
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

6. Attempt to convert the LUKS2 vault down to LUKS1 and read the failure carefully.

    ```bash
    cryptsetup convert --type luks1 /dev/loop1 ; echo "exit=$?"
    ```

    ```
    Cannot convert to LUKS1 format - keyslot 0 is not LUKS1 compatible.
    exit=1
    ```

7. Build a LUKS2 volume that *is* convertible, and convert it both ways.

    ```bash
    cryptsetup close sealed 2>/dev/null
    truncate -s 64M /root/cryptolab/conv.img
    CONV=$(losetup --find --show /root/cryptolab/conv.img)
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --sector-size 512 \
        --luks2-metadata-size 16k --luks2-keyslots-size 2048k \
        --batch-mode "$CONV" <<< 'ConvPass'
    cryptsetup convert --type luks1 "$CONV" --batch-mode && cryptsetup luksDump "$CONV" | head -3
    cryptsetup convert --type luks2 "$CONV" --batch-mode && cryptsetup luksDump "$CONV" | head -3
    ```

    ```
    LUKS header information for /dev/loop4

    Version:       	1
    LUKS header information
    Version:       	2
    Epoch:         	5
    ```

8. Suspend a live volume: keys are wiped from kernel memory, I/O freezes, the mount stays.

    ```bash
    cryptsetup luksSuspend vault
    cryptsetup status vault | grep -E 'is active|key location'
    timeout 3 cat /mnt/vault/marker.txt ; echo "read exit=$? (124 = blocked)"
    cryptsetup luksResume --key-file /etc/luks-keys/vault.key vault
    cat /mnt/vault/marker.txt
    ```

    ```
    /dev/mapper/vault is active and is in use.
    read exit=124 (124 = blocked)
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

### Check your understanding

- **Q6.1** — `dmsetup ls --tree` showed `sealed` stacked on `sealed_dif`. Describe the responsibility of each layer and where the authentication tags physically live.
- **Q6.2** — Authenticated LUKS2 detected the corruption; plain AES-XTS did not. Explain why XTS alone cannot detect tampering, and give the security property XTS *does* provide against an attacker who rewrites sectors.
- **Q6.3** — dm-integrity in LUKS2 defaults to journalled writes. What is the performance cost, and under what circumstance is `--integrity-no-journal` (or the bitmap mode) an acceptable trade?
- **Q6.4** — In step 4 you used `--pbkdf-force-iterations` instead of `--iter-time`. Why does `--iter-time` produce the wrong result when provisioning an image on a fast build server for a slow target?
- **Q6.5** — `cryptsetup reencrypt` changed the master-key digest. Did every passphrase you set earlier still work afterwards? Explain in terms of the keyslot/master-key indirection.
- **Q6.6** — Conversion to LUKS1 failed for the Argon2id volume but succeeded for the PBKDF2 one. List the three properties a LUKS2 header must have to be convertible, and name the real-world reason (bootloader-related) someone would still want LUKS1 or PBKDF2-only LUKS2 today.
- **Q6.7** — `luksSuspend` left the device "active and in use" but reads hung. Which concrete attack does suspending defend against, and why is `luksSuspend` on the *root* filesystem a way to lock yourself out?

---

## Exercise 7 — Network-Bound Disk Encryption with Clevis and Tang

### Steps

1. Start a Tang server on the lab host. Tang is socket-activated and listens on TCP/7500 by default.

    ```bash
    systemctl enable --now tangd.socket
    ss -lntp | grep 7500
    ls -l /var/db/tang/
    ```

    ```
    LISTEN 0  4096  *:7500  *:*  users:(("systemd",pid=1,fd=42))
    -rw-r--r-- 1 root root 354 Aug 20 11:20 8kEQ2Qk3xQ8Jw1n7NfR0lC5FnUk.jwk
    -rw-r--r-- 1 root root 178 Aug 20 11:20 pT9x0wKuVn3sYb2LdG7oQmHrEaI.jwk
    ```

2. Fetch the advertisement and record the key thumbprint you will pin.

    ```bash
    curl -fsS http://127.0.0.1:7500/adv | jq -r '.payload' | head -c 80; echo
    tang-show-keys 7500
    ```

    ```
    eyJrZXlzIjpbeyJhbGciOiJFUzUxMiIsImNydiI6IlAtNTIxIiwia2V5X29wcyI6WyJ2ZXJpZnki...
    x8kQ2Qk3xQ8Jw1n7NfR0lC5FnUkYtHb9vZpQ3mR4sTc
    ```

3. Prove the Clevis primitive independently of LUKS.

    ```bash
    THP=$(tang-show-keys 7500)
    echo "the master key never leaves this host" | \
        clevis encrypt tang "{\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"}" > /tmp/secret.jwe
    wc -c /tmp/secret.jwe
    clevis decrypt < /tmp/secret.jwe
    ```

    ```
    892 /tmp/secret.jwe
    the master key never leaves this host
    ```

4. Bind the `vault` LUKS2 volume to Tang. Clevis consumes an existing passphrase, provisions a **new random** keyslot, and stores the JWE in a LUKS2 token.

    ```bash
    clevis luks bind -d /dev/loop1 tang \
        "{\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"}" \
        -k /etc/luks-keys/vault.key
    ```

    ```
    Updating binding...
    Binding succeeded.
    ```

5. Inspect what changed in the header.

    ```bash
    clevis luks list -d /dev/loop1
    cryptsetup luksDump /dev/loop1 | sed -n '/^Tokens:/,/^Digests:/p'
    ```

    ```
    2: tang '{"url":"http://127.0.0.1:7500"}'

    Tokens:
      0: clevis
    	Keyslot:    2
    ```

6. Unlock without any passphrase at all.

    ```bash
    umount /mnt/vault 2>/dev/null; cryptsetup close vault
    clevis luks unlock -d /dev/loop1 -n vault
    cryptsetup status vault | head -2
    ```

    ```
    /dev/mapper/vault is active.
      type:    LUKS2
    ```

7. Show the failure mode: stop Tang, and try again.

    ```bash
    cryptsetup close vault
    systemctl stop tangd.socket
    clevis luks unlock -d /dev/loop1 -n vault ; echo "exit=$?"
    systemctl start tangd.socket
    ```

    ```
    Error communicating with server http://127.0.0.1:7500
    /dev/loop1 could not be opened.
    exit=1
    ```

8. Build a resilient policy with **Shamir Secret Sharing**: 1-of-2 Tang servers, so one outage does not brick the boot.

    ```bash
    clevis luks bind -d /dev/loop1 sss \
      "{\"t\":1,\"pins\":{\"tang\":[
          {\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"},
          {\"url\":\"http://tang2.lab.example:7500\",\"thp\":\"PLACEHOLDER\"}
       ]}}" -k /etc/luks-keys/vault.key 2>&1 | tail -2
    clevis luks list -d /dev/loop1
    ```

    ```
    2: tang '{"url":"http://127.0.0.1:7500"}'
    4: sss '{"t":1,"pins":{"tang":[{"url":"http://127.0.0.1:7500"},{"url":"http://tang2.lab.example:7500"}]}}'
    ```

9. Wire automatic unlock at boot and mark the volume network-dependent.

    ```bash
    systemctl enable clevis-luks-askpass.path
    sed -i 's|^vault\(.*\)luks,discard|vault\1luks,discard,_netdev|' /etc/crypttab
    grep '^vault' /etc/crypttab
    # initramfs: Debian/Ubuntu -> update-initramfs -u -k all ; RHEL/Fedora -> dracut -f
    ```

    ```
    vault      UUID=9d2c71fa-...  /etc/luks-keys/vault.key  luks,discard,_netdev,nofail,x-systemd.device-timeout=10s
    ```

10. Audit and unbind.

    ```bash
    clevis luks report -d /dev/loop1 -s 2
    clevis luks unbind -d /dev/loop1 -s 4 -f
    clevis luks list -d /dev/loop1
    ```

    ```
    Keyslot 2 is bound to a Tang server with the current advertised key. No rebinding needed.
    2: tang '{"url":"http://127.0.0.1:7500"}'
    ```

### Check your understanding

- **Q7.1** — During `clevis luks bind`, the Tang server never learns the LUKS key. Sketch the McCallum–Relyea exchange in three sentences: what the client generates, what it sends, what it discards.
- **Q7.2** — You passed `"thp"` (thumbprint) explicitly. What attack becomes possible if you bind without it, in an interactive session where you blindly accept the advertised key?
- **Q7.3** — NBDE is often summarised as "the disk unlocks only inside the datacenter". Precisely which threat does that address, and which threat does it explicitly *not* address?
- **Q7.4** — The `sss` pin was created with `"t":1` over two Tang servers. What changes operationally with `"t":2`, and what would `{"t":2,"pins":{"tang":[...],"tpm2":[...]}}` express as a security policy?
- **Q7.5** — After rotating keys on the Tang server (moving the old `.jwk` to a filename starting with `.` and generating new ones), what must be run on every bound client, and what happens if you *delete* the old keys instead of hiding them?
- **Q7.6** — Why is `_netdev` insufficient on its own for a **root** filesystem bound to Tang, and what additional artefact must be regenerated?

---

## Exercise 8 — eCryptfs: stacked, per-file, per-user encryption

### Steps

1. Confirm the module and create a test user.

    ```bash
    modprobe ecryptfs
    grep ecryptfs /proc/filesystems
    useradd -m -s /bin/bash alice
    echo 'alice:AlicePass123' | chpasswd
    ```

    ```
    	ecryptfs
    ```

2. As `alice`, set up the encrypted private directory.

    ```bash
    su - alice -c 'ecryptfs-setup-private --nopwcheck' <<'EOF'
    AlicePass123

    EOF
    ```

    ```
    Enter your login passphrase [alice]:
    Enter your mount passphrase [leave blank to generate one]:

    ************************************************************************
    YOU SHOULD RECORD YOUR MOUNT PASSPHRASE AND STORE IT IN A SAFE LOCATION.
      ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase > (some file)
    THIS WILL BE REQUIRED IF YOU NEED TO RECOVER YOUR DATA AT A LATER TIME.
    ************************************************************************

    Done configuring.
    ```

3. Inspect the artefacts eCryptfs created.

    ```bash
    ls -la /home/alice/.ecryptfs/
    ls -la /home/alice/ | grep -E 'Private|\.Private'
    cat /home/alice/.ecryptfs/Private.sig
    cat /home/alice/.ecryptfs/Private.mnt
    ```

    ```
    -rw------- 1 alice alice   16 Aug 20 11:40 Private.mnt
    -rw------- 1 alice alice   33 Aug 20 11:40 Private.sig
    lrwxrwxrwx 1 alice alice   28 Aug 20 11:40 auto-mount -> /home/alice/.ecryptfs/...
    -rw------- 1 alice alice   84 Aug 20 11:40 wrapped-passphrase
    drwx------ 2 alice alice 4096 Aug 20 11:40 .Private
    drwx------ 2 alice alice 4096 Aug 20 11:40 Private

    d4f2a1c9e07b3856
    d4f2a1c9e07b3856
    /home/alice/Private
    ```

4. Mount the private directory, write a file, and look at both views.

    ```bash
    su - alice -c 'ecryptfs-mount-private' <<< 'AlicePass123'
    su - alice -c 'echo "salary: classified" > ~/Private/hr.txt; ls -l ~/Private/'
    ls -l /home/alice/.Private/
    ```

    ```
    -rw-rw-r-- 1 alice alice 19 Aug 20 11:42 hr.txt

    -rw-rw-r-- 1 alice alice 12288 Aug 20 11:42 ECRYPTFS_FNEK_ENCRYPTED.FWaHZ5xVQ7pKmT2nB8dLuXcS9eRvY0jgIoP3--
    ```

5. Confirm the ciphertext is real and read the per-file header.

    ```bash
    head -c 64 /home/alice/.Private/ECRYPTFS_FNEK_ENCRYPTED.* | hexdump -C | head -3
    ecryptfs-stat /home/alice/.Private/ECRYPTFS_FNEK_ENCRYPTED.*
    ```

    ```
    00000000  00 00 00 00 00 00 00 13  03 00 00 00 00 00 30 00  |..............0.|
    00000010  00 00 00 00 00 00 00 00  0f 3a 2c 00 00 00 00 00  |.........:,.....|
    00000020  01 62 b1 4d 8c 07 a3 5f  29 e6 10 74 db 3f 98 c5  |.b.M..._)..t.?..|

    Version: 0
    Header Extent Size: 8192
    Extent Size: 4096
    flags
    	SIG_IN_HEADER
    	ENCRYPTED
    	METADATA_IN_XATTR: 0
    Root IV:
    	1 62 b1 4d 8c 7 a3 5f 29 e6 10 74 db 3f 98 c5
    ```

6. Look at the mount options actually in force and the keys in the keyring.

    ```bash
    findmnt -t ecryptfs -o TARGET,SOURCE,OPTIONS
    su - alice -c 'keyctl list @u'
    ```

    ```
    TARGET               SOURCE                  OPTIONS
    /home/alice/Private  /home/alice/.Private    rw,nosuid,nodev,relatime,ecryptfs_fnek_sig=d4f2a1c9e07b3856,
                                                 ecryptfs_sig=d4f2a1c9e07b3856,ecryptfs_cipher=aes,
                                                 ecryptfs_key_bytes=16,ecryptfs_unlink_sigs

    2 keys in keyring:
     93847261: --alswrv  1001  1001 user: d4f2a1c9e07b3856
    418273649: --alswrv  1001  1001 user: 8e1b0c74a9d5f236
    ```

7. Unmount and prove the plaintext view is gone.

    ```bash
    su - alice -c 'ecryptfs-umount-private'
    su - alice -c 'ls -la ~/Private/'
    ```

    ```
    total 8
    drwx------ 2 alice alice 4096 Aug 20 11:40 .
    drwxr-xr-x 8 alice alice 4096 Aug 20 11:42 ..
    ```

8. Recover the mount passphrase (the disaster-recovery step every deployment must document).

    ```bash
    su - alice -c 'ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase' <<< 'AlicePass123'
    ```

    ```
    2f7c91a4e0b8d63510ac47f92be8d1c3
    ```

9. Mount an arbitrary directory manually — no `ecryptfs-utils` helpers, all options explicit.

    ```bash
    mkdir -p /srv/lower /srv/upper
    SIG=$(printf 'ManualPass' | ecryptfs-add-passphrase --fnek 2>/dev/null | \
          grep -oP '(?<=\[)[0-9a-f]{16}(?=\])' | head -1)
    echo "sig=$SIG"

    mount -t ecryptfs /srv/lower /srv/upper -o \
      key=passphrase:passphrase_passwd=ManualPass,\
    ecryptfs_cipher=aes,ecryptfs_key_bytes=32,\
    ecryptfs_enable_filename_crypto=y,ecryptfs_fnek_sig=${SIG},ecryptfs_sig=${SIG},\
    ecryptfs_passthrough=n,ecryptfs_unlink_sigs,no_sig_cache

    echo "manual mount works" > /srv/upper/proof.txt
    ls /srv/lower/
    umount /srv/upper
    ls /srv/lower/
    ```

    ```
    sig=8a3f0c71e92b45d6
    ECRYPTFS_FNEK_ENCRYPTED.FXbQ8mZvR4tKpL7nD2sYcW9eUhJgI0oPa3--
    ECRYPTFS_FNEK_ENCRYPTED.FXbQ8mZvR4tKpL7nD2sYcW9eUhJgI0oPa3--
    ```

10. Inspect the PAM integration that makes login-time unwrapping automatic.

    ```bash
    grep -rn pam_ecryptfs /etc/pam.d/
    ```

    ```
    /etc/pam.d/common-auth:26:auth     optional  pam_ecryptfs.so unwrap
    /etc/pam.d/common-session:31:session optional pam_ecryptfs.so unwrap
    /etc/pam.d/common-password:29:password optional pam_ecryptfs.so
    ```

### Check your understanding

- **Q8.1** — A 19-byte plaintext became a 12288-byte ciphertext file. Account for the size, and state what an attacker with only `.Private` can still infer about `hr.txt`.
- **Q8.2** — Explain the two-key design: FEK, FEKEK and FNEK. Which one is stored inside each file, which one is derived from alice's login passphrase, and where does the *wrapped passphrase* fit?
- **Q8.3** — `pam_ecryptfs.so` appears in `common-auth`, `common-session` **and** `common-password`. State the job of each occurrence, and predict the exact breakage if the `common-password` line is removed.
- **Q8.4** — Why is `pam_ecryptfs` fundamentally unable to unlock alice's Private directory when she logs in via SSH public key instead of a password? Name the standard mitigation.
- **Q8.5** — Compare eCryptfs and LUKS/dm-crypt across four axes: what is hidden, granularity of the key, whether the container must be pre-sized, and behaviour on backup with `rsync`.
- **Q8.6** — `ecryptfs_passthrough=n` was set explicitly. What does `=y` allow, and why is it a hazard in a home-directory deployment?
- **Q8.7** — What is the single reason `ecryptfs-unwrap-passphrase` output must be stored offline before the deployment goes live?

---

## Exercise 9 — `fscrypt`: native ext4 file-level encryption

### Steps

1. Prepare a filesystem with the `encrypt` feature.

    ```bash
    truncate -s 256M /root/cryptolab/fscrypt.img
    FSD=$(losetup --find --show /root/cryptolab/fscrypt.img)
    mkfs.ext4 -q -O encrypt "$FSD"
    mkdir -p /mnt/fsc && mount "$FSD" /mnt/fsc
    tune2fs -l "$FSD" | grep -i 'features'
    ```

    ```
    Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                              extent 64bit flex_bg encrypt sparse_super large_file
                              huge_file dir_nlink extra_isize metadata_csum
    ```

    > On an existing filesystem the feature is added offline: `umount`, `tune2fs -O encrypt /dev/sdX`, `e2fsck -f /dev/sdX`.

2. Initialise `fscrypt` globally and on this mount point.

    ```bash
    fscrypt setup --quiet
    fscrypt setup /mnt/fsc --quiet
    ls -la /mnt/fsc/.fscrypt/
    ```

    ```
    drwxr-xr-x 2 root root 4096 Aug 20 12:01 policies
    drwxr-xr-x 2 root root 4096 Aug 20 12:01 protectors
    ```

3. Encrypt an **empty** directory with a custom passphrase protector.

    ```bash
    mkdir /mnt/fsc/confidential
    fscrypt encrypt /mnt/fsc/confidential \
        --source=custom_passphrase --name=lab-331-3 --quiet <<'EOF'
    FscryptPass!
    FscryptPass!
    EOF
    fscrypt status /mnt/fsc/confidential
    ```

    ```
    "/mnt/fsc/confidential" is encrypted with fscrypt.

    Policy:   7c1e0a95b3d62f48
    Options:  padding:32 contents:AES_256_XTS filenames:AES_256_CTS policy_version:2
    Unlocked: Yes

    Protected with 1 protector:
    PROTECTOR         LINKED  DESCRIPTION
    3f8b02d7ae51c964  No      custom protector "lab-331-3"
    ```

4. Write data, lock the directory, and observe the encrypted-filename view.

    ```bash
    echo 'board minutes 2026-Q3' > /mnt/fsc/confidential/minutes.txt
    ls -l /mnt/fsc/confidential/
    fscrypt lock /mnt/fsc/confidential
    ls -l /mnt/fsc/confidential/
    cat /mnt/fsc/confidential/* 2>&1 | head -2
    ```

    ```
    -rw-r--r-- 1 root root 22 Aug 20 12:03 minutes.txt

    -rw-r--r-- 1 root root 22 Aug 20 12:03 g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o
    cat: /mnt/fsc/confidential/g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o: Required key not available
    ```

5. Unlock and confirm.

    ```bash
    fscrypt unlock /mnt/fsc/confidential --quiet <<< 'FscryptPass!'
    cat /mnt/fsc/confidential/minutes.txt
    fscrypt status
    ```

    ```
    board minutes 2026-Q3

    filesystems supporting encryption: 1
    MOUNTPOINT  DEVICE     FILESYSTEM  ENCRYPTION     FSCRYPT
    /mnt/fsc    /dev/loop5  ext4        supported      Yes
    ```

6. Read the policy straight from the kernel, bypassing `fscrypt(1)`.

    ```bash
    fscryptctl get_policy /mnt/fsc/confidential
    ```

    ```
    Encryption policy for /mnt/fsc/confidential:
    	Policy version: 2
    	Master key identifier: 7c1e0a95b3d62f48a012cd8b4e6f7309
    	Contents encryption mode: AES-256-XTS
    	Filenames encryption mode: AES-256-CTS
    	Flags: PAD_32
    ```

7. Demonstrate the metadata that is *not* protected.

    ```bash
    fscrypt lock /mnt/fsc/confidential
    stat -c '%n size=%s mode=%a uid=%u mtime=%y' /mnt/fsc/confidential/*
    ```

    ```
    /mnt/fsc/confidential/g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o size=22 mode=644 uid=0 mtime=2026-08-20 12:03:11
    ```

### Check your understanding

- **Q9.1** — In step 7, with the key evicted, `stat` still reported exact size, mode, uid and mtime. List everything fscrypt does *not* encrypt, and give one realistic scenario where that leakage matters.
- **Q9.2** — `fscrypt encrypt` refuses to run on a non-empty directory. Why is that a kernel-level constraint rather than a tool limitation?
- **Q9.3** — `padding:32` appears in the policy. What is padded, and which attack does it blunt?
- **Q9.4** — Contrast v1 and v2 fscrypt policies with respect to *who* can unlock and where the key lives (`@s` session keyring vs. filesystem keyring).
- **Q9.5** — On a laptop that needs full-disk protection including `/etc`, `/var` and swap, is fscrypt sufficient? Justify the answer and state the correct layering.
- **Q9.6** — fscrypt has no integrity protection either. What would you stack underneath to get authenticated storage while keeping fscrypt's per-directory keys?

---

## Exercise 10 — `cryptmount`: user-mountable encrypted containers

### Steps

1. Create a container file and a mount point owned by a normal user.

    ```bash
    id alice
    mkdir -p /home/alice/vault && chown alice:alice /home/alice/vault
    truncate -s 128M /srv/alice-crypt.fs
    ```

2. Write the `cmtab` entry by hand (the interactive alternative is `cryptmount-setup`).

    ```bash
    cat > /etc/cryptmount/cmtab <<'EOF'
    alicevault {
        dev=/srv/alice-crypt.fs
        dir=/home/alice/vault
        fstype=ext4
        mountoptions=defaults,nosuid,nodev
        cipher=aes-xts-plain64
        keyformat=luks
        keyfile=/srv/alice-crypt.fs
        keymaxlen=32
        supath=/sbin:/bin:/usr/sbin:/usr/bin
    }
    EOF
    cryptmount -l
    ```

    ```
    alicevault  [to be mounted on /home/alice/vault]
    ```

3. Generate the key and the filesystem (root does this once).

    ```bash
    cryptmount --generate-key 32 alicevault <<'EOF'
    AliceVaultPass
    AliceVaultPass
    EOF

    cryptmount --prepare alicevault <<< 'AliceVaultPass'
    mkfs.ext4 -q /dev/disk/by-id/dm-name-alicevault
    cryptmount --release alicevault
    ```

4. Hand ownership to alice and let *her* mount it, unprivileged.

    ```bash
    cryptmount -m alicevault <<< 'AliceVaultPass'
    chown alice:alice /home/alice/vault
    cryptmount -u alicevault

    su - alice -c 'cryptmount -m alicevault' <<< 'AliceVaultPass'
    su - alice -c 'touch ~/vault/mine.txt; ls -l ~/vault/'
    findmnt /home/alice/vault
    su - alice -c 'cryptmount -u alicevault'
    ```

    ```
    -rw-rw-r-- 1 alice alice 0 Aug 20 12:20 mine.txt

    TARGET             SOURCE                  FSTYPE OPTIONS
    /home/alice/vault  /dev/mapper/alicevault  ext4   rw,nosuid,nodev,relatime
    ```

5. Change the container password without touching the data.

    ```bash
    cryptmount --change-password alicevault <<'EOF'
    AliceVaultPass
    NewVaultPass2026
    NewVaultPass2026
    EOF
    cryptmount --status alicevault
    ```

    ```
    Target "alicevault" is not mounted
      device: /srv/alice-crypt.fs
      key file: /srv/alice-crypt.fs (luks format)
    ```

### Check your understanding

- **Q10.1** — `cryptmount` let a non-root user run `cryptmount -m`. What mechanism on the `cryptmount` binary makes that possible, and which two `cmtab` fields are the security boundary that keeps alice from mounting someone else's container?
- **Q10.2** — `mountoptions=defaults,nosuid,nodev` — explain why omitting `nosuid` on a user-mountable container is a straightforward local privilege-escalation path.
- **Q10.3** — `keyformat=luks` with `keyfile` pointing at the container itself. What is stored where in that arrangement, and what would `keyformat=builtin` with a separate `keyfile` change?
- **Q10.4** — Compare `cryptmount` with `/etc/crypttab` + `systemd-cryptsetup`: for which single requirement is `cryptmount` clearly the right tool?

---

## Exercise 11 — Diagnostics: reading the failure

### Steps

1. Build a reference table of the live crypto stack.

    ```bash
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT
    dmsetup ls --tree -o blkdevname
    dmsetup info -c -o name,major,minor,open,segments,tables_loaded
    ```

    ```
    NAME        SIZE FSTYPE      TYPE  MOUNTPOINT
    loop1       256M crypto_LUKS loop
    └─vault     240M ext4        crypt /mnt/vault
    loop3       256M crypto_LUKS loop
    └─sealed_dif      crypt
      └─sealed        ext4       crypt

    Name             Maj Min Open Seg  Tables
    vault            253   0    1   1  LIVE
    sealed_dif       253   1    1   1  LIVE
    sealed           253   2    0   1  LIVE
    ```

2. Reproduce and read each classic error.

    ```bash
    # (a) device busy on close
    cryptsetup close vault ; echo "exit=$?"
    ```
    ```
    Device vault is still in use.
    exit=5
    ```

    ```bash
    # (b) source already mapped
    cryptsetup open --key-file /etc/luks-keys/vault.key /dev/loop1 vault2 ; echo "exit=$?"
    ```
    ```
    Cannot use device /dev/loop1, name is invalid or still in use.
    exit=5
    ```

    ```bash
    # (c) not a LUKS device
    cryptsetup luksDump /dev/loop3 --header /dev/null 2>&1 | head -1
    cryptsetup luksAddKey /dev/zero 2>&1 | head -1
    ```
    ```
    Device /dev/null is not a valid LUKS device.
    Device /dev/zero is not a valid LUKS device.
    ```

    ```bash
    # (d) all slots consumed
    for i in $(seq 1 40); do
      printf 'AeadPass\nfill%02d\nfill%02d\n' "$i" "$i" | cryptsetup luksAddKey /dev/loop3 2>&1 | tail -1
    done | sort -u | tail -2
    ```
    ```
    All key slots full.
    ```

    ```bash
    # (e) ecryptfs without the module
    rmmod ecryptfs 2>/dev/null
    mount -t ecryptfs /srv/lower /srv/upper -o key=passphrase 2>&1 | head -1
    modprobe ecryptfs
    ```
    ```
    mount: /srv/upper: unknown filesystem type 'ecryptfs'.
    ```

3. Turn on verbose/debug output when the message is not enough.

    ```bash
    cryptsetup --debug --verbose open --test-passphrase \
        --key-file /etc/luks-keys/vault.key /dev/loop1 2>&1 | grep -E 'Trying|Keyslot|Digest|Activating' | head -8
    ```

    ```
    # Trying to open and read device /dev/loop1 with direct-io.
    # Reading LUKS header of size 16384 from device /dev/loop1
    # Trying to open key slot 3 [ACTIVE_LAST].
    # Reading key slot 3 area.
    # Verifying key digest 0.
    Key slot 3 unlocked.
    ```

4. Confirm the whole-stack view for auditing.

    ```bash
    for d in /dev/loop1 /dev/loop3; do
      printf '== %s\n' "$d"
      cryptsetup isLuks "$d" && echo "  isLuks: yes (v$(cryptsetup luksDump "$d" | awk '/^Version/{print $2}'))"
      cryptsetup luksUUID "$d"
      cryptsetup luksDump "$d" | grep -cE '^\s+[0-9]+: luks[12]?' | xargs printf '  active keyslots: %s\n'
    done
    ```

### Check your understanding

- **Q11.1** — Error (a) returned exit 5 with `Device vault is still in use`. Give the two-command sequence that resolves it, and name the tool that identifies *which* process holds it.
- **Q11.2** — In (d), LUKS2 ran out of slots long before 40. What limits the number of LUKS2 keyslots, and how does that limit differ from LUKS1's fixed 8?
- **Q11.3** — The `--debug` trace shows `Trying to open key slot 3 [ACTIVE_LAST]` first. Relate this to the slot priority you set in Exercise 2, and explain the cost of *not* setting priorities on a volume with many slots and a slow Argon2 KDF.
- **Q11.4** — A colleague reports "LUKS asks for a password but always rejects it after a kernel upgrade". Given the tools in this document, list — in order — the three checks you would run before concluding the header is damaged.
- **Q11.5** — `dmsetup ls --tree` showed `sealed` on top of `sealed_dif`. If `sealed` were removed with `dmsetup remove` but `sealed_dif` left behind, what would `cryptsetup open` report on the next attempt, and how do you clean up?

---

## Exercise 12 — Teardown

### Steps

1. Unmount and close everything, in reverse dependency order.

    ```bash
    umount /mnt/vault /mnt/sealed /mnt/fsc /mnt/plain /srv/upper 2>/dev/null
    su - alice -c 'ecryptfs-umount-private' 2>/dev/null
    cryptmount -u alicevault 2>/dev/null

    for m in vault sealed plainmap hidden alicevault; do
        cryptsetup close "$m" 2>/dev/null
    done
    dmsetup ls
    ```

    ```
    No devices found
    ```

2. Detach loop devices and remove the lab, including the `crypttab`/`fstab` lines you added.

    ```bash
    losetup -D
    sed -i '/cryptolab\|alicevault\|^vault \|^archive \|^hidden \|^cryptswap /d' /etc/fstab /etc/crypttab
    systemctl daemon-reload
    rm -rf /root/cryptolab /srv/lower /srv/upper /srv/alice-crypt.fs /etc/luks-keys /etc/cryptmount/cmtab
    userdel -r alice 2>/dev/null
    systemctl disable --now tangd.socket
    ```

### Check your understanding

- **Q12.1** — You deleted `/etc/luks-keys/vault.key` in teardown. On a production system, what must you verify *before* deleting a LUKS key file, and what is the recovery position if you get it wrong?
- **Q12.2** — Order matters in step 1: `umount` → `cryptsetup close` → `losetup -D`. Explain what fails, and with which error, if you invert the first two.

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every question</summary>

### Exercise 0

**A0.1** — AES-CBC decryption is parallelisable across blocks (each ciphertext block only needs its predecessor, which is already known), so the CPU pipelines it and AES-NI processes multiple blocks per cycle. CBC *encryption* is inherently serial: block *n* cannot start until block *n−1*'s ciphertext exists. XTS has no inter-block chaining in either direction — each 16-byte block gets an independent tweak derived from the sector number and block index — so both directions parallelise equally and the numbers match. This is one of the reasons XTS, not CBC, is the disk-encryption default.

**A0.2** — XTS splits the supplied key into two halves: one for the data cipher and one for the tweak cipher. A 512-bit XTS key is therefore AES-256 for data plus AES-256 for the tweak. `aes-xts 256b` is AES-128 twice over. `cryptsetup`'s `--key-size 512` with `aes-xts-plain64` means AES-256-XTS, and `--key-size 256` means AES-128-XTS — a frequent source of accidental key-strength downgrades.

**A0.3** — A sparse file only allocates blocks that were actually written. Because unallocated ranges read back as zeros rather than pre-existing random data, the *allocation map itself* reveals which regions of the "disk" hold data — usage patterns leak even though contents do not. On a real block device, a properly initialised LUKS volume (or a `dd if=/dev/urandom` pre-wipe) makes free space indistinguishable from used space. This is exactly why the FAQ recommends wiping a disk with random data before `luksFormat` if you care about hiding how much data you store.

**A0.4** — The unit is kibibytes, so 1048576 KiB = 1 GiB of memory per derivation attempt. Argon2 is a *memory-hard* KDF: the parameter targets attackers who parallelise password guessing on GPUs and ASICs, where compute is cheap but per-core high-bandwidth memory is not. PBKDF2 iterations only raise the arithmetic cost, which GPUs absorb almost for free; that is the concrete reason LUKS2 moved to Argon2id.

### Exercise 1

**A1.1** — LUKS2 stores two redundant copies of the binary header plus two JSON metadata areas (16 KiB default each, holding keyslot descriptors, digests, segments, tokens and config), and then a much larger **keyslots area** (~16 MiB) so that up to 32 keyslots, each holding a 4000-stripe anti-forensic split of a 512-bit key, fit with room to grow. The redundancy is the key point: LUKS2 can recover from a corrupted primary header using the secondary copy, something LUKS1 cannot do. The larger area also leaves headroom for tokens (Clevis JWE, systemd-tpm2, systemd-fido2) and for reencryption bookkeeping.

**A1.2** — `MK iterations` is the PBKDF2 count used to derive the *master-key digest* — the checksum that verifies "the master key I just recovered is the right one". `Key Slot 0 → Iterations` is the PBKDF2 count used to derive the *slot key* from your passphrase. The slot value must be large because a passphrase is low-entropy and directly brute-forceable; the digest value can be smaller because it operates on a 512-bit random master key that is not guessable at all. Attacking the digest is pointless; attacking the slot is the actual threat, so that is where the work factor goes.

**A1.3** — Anti-forensic splitting expands the master key into `stripes × keylength` bytes (4000 × 64 = 256000 bytes) using a diffusion function, and *all* of it is required to reconstruct the key — losing any part destroys it. Its purpose is defeating data remanence on magnetic and flash media: when a keyslot is wiped, an attacker who recovers a few surviving sectors of the old keyslot area from unerased flash pages or magnetic residue still gets nothing, because partial AF material is useless. Without it, recovering a single 64-byte fragment would recover the key.

**A1.4** — Benefit: with a 4096-byte encryption sector, dm-crypt performs one crypto operation per 4 KiB instead of eight per 4 KiB, cutting per-I/O overhead noticeably on modern NVMe and on filesystems that already use 4 KiB blocks; it is also required for authenticated modes to be efficient. Constraint: every I/O must be aligned to and a multiple of 4096 bytes, so the underlying device's logical block size and the data offset must both be compatible; a 512-byte-logical device with an unaligned partition start will refuse the format, and legacy tooling that issues 512-byte I/O directly to the mapping breaks.

**A1.5** — `blkid` reads only the *unencrypted LUKS header*, which is deliberately plaintext: magic string `LUKS\xba\xbe`, version, UUID, label, cipher spec and keyslot metadata. None of that reveals the master key or the payload. The design is intentional — the header must be self-describing so that any machine can identify the volume and know how to ask for a passphrase, without the header itself being a secret. Its consequence is that LUKS provides **no** hiddenness: an examiner immediately knows an encrypted volume is present.

### Exercise 2

**A2.1** — Since cryptsetup 2.0, the volume key is loaded into the **kernel keyring** (as a `logon`-type key, which is not readable from userspace even by root) and dm-crypt is given a keyring reference of the form `:<size>:logon:cryptsetup:<uuid>-d<n>` instead of the raw hex key. The gain is that the key no longer appears in the device-mapper table, so it cannot be extracted by any process reading `/dev/mapper` ioctls, does not land in `dmsetup table` output pasted into a support ticket, and is not exposed in a crash dump of userspace. It also means `--showkeys` is now a no-op for such mappings.

**A2.2** — No data is re-encrypted. LUKS is built on a two-level indirection: the *master key* (also called the volume key) encrypts the data and never changes; each *keyslot* stores an AF-split, passphrase-encrypted copy of that master key. Killing a slot wipes that slot's area — the encrypted copy of the master key — so that passphrase can no longer *recover* the master key. The master key, and therefore all data on disk, is untouched. This is why a stolen header backup taken before the kill still works, and why only `cryptsetup reencrypt` genuinely rotates the master key.

**A2.3** — `luksChangeKey --key-slot 0` wipes the old slot and writes the new one; there is a window in which slot 0 contains neither the old nor the new material, so an interruption (power loss, killed process) can leave you unable to open the volume with that slot. `luksAddKey` to a *free* slot, verify the new credential with `--test-passphrase`, then `luksKillSlot` the old one, is strictly safer because there is never a moment with zero usable credentials. Prefer add-verify-kill for anything unattended; `luksChangeKey` is acceptable only interactively when another working slot exists.

**A2.4** — LUKS uses the key file's *entire contents* as the passphrase by default. Appending a newline changes the byte string, so the derived slot key changes and the passphrase silently stops working — with the completely unhelpful `No key available with this passphrase`. The standard defence is to pin the length explicitly: `--keyfile-size 4096` on the CLI and `keyfile-size=4096` in `/etc/crypttab`, so only the first 4096 bytes are ever read and trailing edits are ignored. (`--keyfile-offset` / `keyfile-offset=` similarly pin the start when the key is embedded in a larger blob.)

**A2.5** — It is a latency/UX control, not a security control. At unlock, cryptsetup tries slots in priority order: `prefer` slots first, then `normal`, and `ignore` slots are skipped entirely unless the slot is named explicitly with `--key-slot`. With an expensive Argon2id KDF, trying five wrong slots before the right one costs five full derivations — potentially many seconds at boot. Setting `prefer` on the slot the boot process actually uses removes that. `ignore` is genuinely useful for emergency/recovery slots you never want probed automatically, but it does not make them weaker or stronger.

### Exercise 3

**A3.1** — A LUKS header backup is a **complete, permanent snapshot of every credential that existed at backup time**. Restoring it resurrects revoked passphrases, because the keyslots it contains still decrypt the same unchanged master key. Operational rule: a header backup must be treated as equivalent to *all* the passphrases it contains, retained under the same controls as the passphrases themselves, and **securely destroyed the moment any credential in it is revoked** — then a fresh backup taken. If a credential compromise is suspected, revoking the slot is not enough; you must `cryptsetup reencrypt` to change the master key, which invalidates every old header backup at once.

**A3.2** — `offset: 0 sectors` because the header is not on the device, so the ciphertext payload starts at byte 0 of `/dev/loop2`. The whole 256 MiB is usable, versus 240 MiB for `/dev/loop1` where 16 MiB is consumed by the LUKS2 header. The trade is severe: lose or corrupt the detached header file and the data is unrecoverable, with no on-disk copy and no secondary header to fall back on. Detached headers demand a backup discipline at least as rigorous as the passphrase itself.

**A3.3** — The device contains high-entropy data with no filesystem signature, and that itself is anomalous: a disk region that is neither zeros, nor a recognisable filesystem, nor a known partition type is a strong statistical indicator of encryption. Additional traces routinely survive elsewhere: `/etc/crypttab` or shell history referencing `--header`, the header file's mtime and path, `journalctl` entries from `systemd-cryptsetup`, filesystem metadata about the header file, and the mount point in `/etc/fstab`. Plausible deniability requires removing all of those consistently, which is far harder than creating the detached header. LUKS is designed for confidentiality, not for hiddenness.

**A3.4** — Nothing about the payload was touched. `luksErase` overwrites only the keyslot areas — a few hundred kibibytes — destroying every encrypted copy of the master key. Since the master key is a 512-bit random value that exists *only* inside those keyslots (and, transiently, in kernel memory), destroying them destroys the sole path to it, and the ciphertext becomes computationally indistinguishable from random noise. The property exploited is the **master-key indirection**: securely destroying a fixed-size key destroys arbitrarily large amounts of data. This is the standard mechanism for instant crypto-shredding of a multi-terabyte array, and the reason the FAQ insists you cannot "un-erase" a LUKS volume.

**A3.5** — The disk is protected by whatever passphrase strength you chose; the header backup is a *separate* copy of the same keyslots that an attacker can brute-force **offline**, at full speed, without touching the machine, and without any rate limiting or tamper evidence. It also survives after you have wiped the disk. On decommissioning a passphrase you must destroy every header backup containing that slot (`shred`/`wipefs` on the file plus removal from any offsite/backup system) and generate a new backup from the current header — otherwise the revocation is cosmetic.

### Exercise 4

**A4.1** — Omitting `luks` and giving `/dev/urandom` as the key file selects **plain dm-crypt** with a fresh random key generated at every boot; the `swap` option tells `systemd-cryptsetup` to run `mkswap` on the resulting mapping after activation. For swap this is exactly right: swap contents are per-boot scratch data, and a key that exists only in kernel memory and is never persisted means that anything paged out — including plaintext keys, session tokens and decrypted document buffers — is unrecoverable after a power cycle, with no key management burden at all. For `/home` it is catastrophic: a new random key each boot means the previous boot's data is permanently undecryptable, and `mkswap`/`mkfs` would destroy it anyway. Note the corollary: **hibernation is incompatible** with random-key swap, because resume needs the previous boot's key.

**A4.2** — The prompt is issued through the systemd password agent framework: `systemd-cryptsetup` calls `systemd-ask-password`, which writes a request into `/run/systemd/ask-password/` and any registered agent (the console agent `systemd-ask-password-console.service`, plasma/gnome agents, or a remote agent over `systemd-tty-ask-password-agent`) can answer it. `tries=3` bounds the attempts before the unit fails; `timeout=30s` bounds how long it waits for an answer. `noauto` in the example means it is not attempted at boot at all — it is activated on demand by `systemctl start systemd-cryptsetup@archive.service` or by a `x-systemd.requires=` dependency.

**A4.3** — Without `x-systemd.requires=systemd-cryptsetup@vault.service`, systemd only knows the mount depends on `/dev/mapper/vault` existing; the ordering is discovered via udev, and the mount unit can be scheduled before the crypt unit has finished — or, worse, `local-fs.target` fails and the boot drops to emergency mode. Without `nofail`, that failure is fatal: a missing or unopenable volume prevents a successful boot, requiring console access to recover. On a headless server, that combination turns a degraded disk into an outage. The correct pattern is `nofail` plus an explicit `x-systemd.requires=` (or `_netdev` for network-unlocked volumes, which pulls in the network ordering automatically).

**A4.4** — With discards enabled, TRIM/UNMAP commands pass from the filesystem through dm-crypt to the SSD, so the drive learns *which LBAs contain no live data*. That reveals the filesystem's used/free pattern and its evolution over time — how full the volume is, roughly where data is, and that certain regions were deleted — none of which should be visible on an encrypted device. It can also weaken the deniability of a hidden container and, in the worst case, expose filesystem-level structure. The benefit is SSD wear levelling and sustained write performance. LUKS1's header has no general-purpose flags field — persistent activation flags (`allow-discards`, `no-journal`, `no-read-workqueue`, `no-write-workqueue`, `same-cpu-crypt`) are a LUKS2-only feature stored in the JSON `config.flags`; on LUKS1 you must pass `--allow-discards` at every `open`, or set `discard` in `crypttab`.

**A4.5** — `_netdev`. It marks the volume as requiring the network, which makes systemd order the unit after `network-online.target` and `remote-fs-pre.target` and place the corresponding mount under `remote-fs.target` rather than `local-fs.target`. Without it, `systemd-cryptsetup` runs before the network is up, Clevis cannot reach the Tang server, the unit fails, and boot either falls back to the interactive passphrase prompt or drops to emergency mode.

### Exercise 5

**A5.1** — Plain mode has **no header at all** — it stores nothing on disk. The key is derived from your passphrase by a single hash (here SHA-512) and handed straight to dm-crypt, which will happily set up a mapping with *any* key because there is nothing to compare against. LUKS provides the missing check via the **master-key digest**: a PBKDF2 hash of the master key stored in the header. After unwrapping a keyslot, cryptsetup hashes the recovered master key and compares it to the stored digest; a mismatch produces `No key available with this passphrase`. No digest, no verification.

**A5.2** — `mount` failed only because ext4's superblock magic did not decrypt to a valid value — an accident of the filesystem having a recognisable header. On a raw device with no superblock (an Oracle ASM disk, a raw LVM PV, a database raw device, a swap partition, an LVM header at an unexpected offset), nothing would object. Writes made under the wrong key are encrypted with that wrong key and land on top of the real data; every such write **permanently destroys** the plaintext underneath, and the damage is silent and irreversible. This is the single largest operational hazard of plain mode and the reason LUKS should be the default for anything a human types a passphrase into.

**A5.3** — Plain-mode parameters are **not recorded anywhere**, so they are part of the key. If you rely on defaults, a `cryptsetup` upgrade, a different distribution, or a rescue ISO with a different build will derive a different key from the same passphrase and your data becomes unreadable — with no error message explaining why. The rule: for plain dm-crypt, always specify `--cipher`, `--key-size`, `--hash`, `--offset`, `--skip` (and `--sector-size` where relevant) explicitly, on every single invocation, and record that exact command line with the same care you give the passphrase. It is effectively part of the credential.

**A5.4** — (i) **Encrypted swap and other ephemeral volumes** keyed from `/dev/urandom` at every boot: no header to manage, no key to protect, and the absence of persistence is precisely the desired property. (ii) **Hidden/deniable volumes and steganographic layouts**, where the requirement is that the device be byte-for-byte indistinguishable from random data — a LUKS header would announce itself. (iii) Interoperability with legacy or non-LUKS layouts where an external system dictates the on-disk format (e.g. opening a volume created by another OS, or a fixed-offset mapping inside a larger container). (iv) Scratch/tmpfs-like volumes on ephemeral cloud instances that are reformatted every boot.

**A5.5** — Plain mode applies **one** hash iteration, so an attacker testing candidate passphrases pays essentially the cost of one SHA-512 per guess — billions per second on a GPU. LUKS2's Argon2id keyslot applies a tunable, memory-hard derivation (in this lab: 7 passes over 1 GiB with 4 threads, ~2 s per attempt on the target CPU), so the same attacker pays seconds and gigabytes of high-bandwidth memory per guess, which does not parallelise cheaply on GPUs or ASICs. The practical difference against a low-entropy passphrase is many orders of magnitude. Plain mode is only defensible when the "passphrase" is itself a full-entropy key (e.g. from `/dev/urandom`), where KDF strengthening is irrelevant.

### Exercise 6

**A6.1** — `sealed_dif` is the **dm-integrity** layer sitting directly on `/dev/loop3`. It carves the device into data sectors plus interleaved *tag* space (and, by default, a journal), exposing a virtual device whose sectors each carry an extra authentication tag. `sealed` is the **dm-crypt** layer on top of it, running an AEAD cipher (`aes-gcm-random`): for each sector it produces ciphertext plus an authentication tag, writes the ciphertext into the data area and hands the tag to dm-integrity, which stores it in the tag area. On read, dm-crypt asks dm-integrity for the tag, verifies it, and returns `-EILSEQ` (surfacing as an I/O error and the `INTEGRITY AEAD ERROR` kernel message) if it does not match. Physically the tags live in dedicated tag regions interleaved with data on the same backing device, which is why the usable size shrank from 240 MiB to ~227 MiB.

**A6.2** — XTS is a *length-preserving, unauthenticated* mode: every 512- or 4096-byte sector maps to exactly the same amount of ciphertext, with no room for a MAC. Any ciphertext therefore "decrypts" to *some* plaintext, so an attacker can flip, replace or replay sectors and the layer above receives plausible-looking garbage with no error. What XTS *does* guarantee is that the attacker has no control over the resulting plaintext (the tweak makes each block's transformation position-dependent, so a modification randomises the whole 16-byte block) and that identical plaintext at different offsets produces different ciphertext. It defends confidentiality against a passive attacker; it offers nothing against an **active** attacker who can write to the disk — the classic evil-maid bootloader-patching or config-file-flipping scenario. Authenticated encryption is what closes that.

**A6.3** — Journalling means every write is written **twice**: once to the integrity journal (data or tags, depending on mode) and once to its final location, roughly halving sequential write throughput and adding latency, plus extra flushes. It exists so that a crash cannot leave a sector whose data and tag disagree, which would produce a permanent, unrecoverable integrity error on an otherwise healthy sector. `--integrity-no-journal` (or `--integrity-bitmap-mode`, which tracks dirty regions instead of journalling) is acceptable when a crash-induced mismatch is tolerable and cheaply repaired: on a device that is fully rewritten after every unclean shutdown, behind a battery- or capacitor-backed write cache that makes torn writes impossible, or where a higher layer (a replicated database, a Ceph OSD, a RAID with its own consistency mechanism) will re-sync the affected extents anyway. Bitmap mode is the usual middle ground.

**A6.4** — `--iter-time` is a *benchmark on the machine running the command*: cryptsetup measures how many iterations (or how much Argon2 work) fits in the requested wall-clock time **on that CPU**, and records the resulting parameters. Provisioning a golden image on a fast 32-core build server with `--iter-time 2000` yields parameters that take 2 s there but might take 30–60 s on a low-power ARM appliance — turning boot into a timeout. Worse, if the target has less RAM than the recorded Argon2 memory cost, unlocking fails outright with an out-of-memory error. `--pbkdf-force-iterations` (with `--pbkdf-memory` and `--pbkdf-parallel`) pins the exact parameters regardless of the building machine, so the cost is deterministic on the target. The same reasoning applies in reverse: never let a slow machine set parameters for a fast fleet, or you under-protect the passphrase.

**A6.5** — Yes, every passphrase still works. `cryptsetup reencrypt` generates a **new master key**, rewrites the entire data area from old-key ciphertext to new-key ciphertext, and *re-wraps that new master key into every existing active keyslot* — so each passphrase, key file and Clevis token continues to unlock, but now unwraps the new master key. This is precisely the keyslot/master-key indirection at work: the credentials are decoupled from the data key, so the data key can be rotated without touching the credentials. The visible evidence is that the master-key digest changed, which is also why every header backup taken before the reencryption is now useless — the single most effective response to a suspected master-key or header-backup compromise.

**A6.6** — A LUKS2 header is convertible to LUKS1 only if: (i) every active keyslot uses **PBKDF2**, not Argon2i/Argon2id (LUKS1 has no Argon2 support); (ii) there are **no tokens, no integrity/AEAD segment, no multiple data segments, no reencryption in progress**, and no more than 8 keyslots — LUKS1 has exactly 8 fixed slots; (iii) the **data offset and metadata size are compatible**, i.e. the LUKS1 header (typically 2 MiB payload offset) must fit in the space available and the resulting alignment must be valid; a 4096-byte sector size also blocks conversion, since LUKS1 is fixed at 512. The real-world motivation is **bootloader compatibility**: GRUB2 gained LUKS2 support in 2.06 but only for keyslots using PBKDF2 — Argon2 support landed later (2.12). A `/boot` on LUKS therefore historically required LUKS1, and still today requires either LUKS1 or LUKS2-with-PBKDF2 on any system whose GRUB predates 2.12. The same constraint applies to some firmware and rescue environments.

**A6.7** — `luksSuspend` freezes all I/O to the mapping and **wipes the volume key from kernel memory**, while leaving the device-mapper device and every mount in place. It defends against attacks that read RAM from a running-but-unattended machine: DMA attacks over Thunderbolt/PCIe/FireWire, cold-boot memory extraction, and forensic acquisition of a suspended-to-RAM laptop — in all of which the key would otherwise be sitting in kernel memory. On the **root** filesystem it is a self-inflicted deadlock: `cryptsetup luksResume` itself needs to read binaries, libraries and possibly the key file from the very filesystem whose I/O is frozen, so the resume command blocks forever. The correct approach is to run the suspend/resume pair from a fully preloaded, memory-resident context (an initramfs shell, a statically linked binary with everything `mlock`ed, or systemd's own `systemd-cryptsetup` suspend integration used for suspend-then-hibernate), which is exactly what distributions do when they wipe keys across suspend.

### Exercise 7

**A7.1** — Tang publishes a signed advertisement containing an ECDH public key `S = sS·G`. During bind, the **client** generates an ephemeral key pair `(eC, EC = eC·G)`, computes the shared point `K = eC·S`, derives the LUKS keyslot passphrase from `K`, and then **discards `eC` and `K`**, keeping only `EC` (stored in the JWE inside the LUKS2 token). Tang never receives `eC`, `K` or the passphrase — it only ever saw its own public key being fetched. To recover, the client generates a *fresh* ephemeral `eR`, sends `EC + eR·G` to Tang, which multiplies by its private `sS` and returns the result; the client subtracts `eR·S` (computable from the public advertisement) and recovers `K` exactly. Tang sees only a blinded point and learns nothing about `K` — this is the McCallum–Relyea exchange, and it is why a Tang server needs no per-client state, no database, and no confidentiality of its stored keys beyond the private signing/exchange key itself.

**A7.2** — Without a pinned thumbprint, the client trusts whatever advertisement it receives over plain HTTP. An attacker able to intercept, spoof DNS for, or ARP-poison the path to the Tang server can serve **their own** advertisement; the client then binds the keyslot to the attacker's key. Later, that attacker can decrypt the JWE at will — meaning they can unlock the disk from anywhere they can present that key, and the binding is invisible in normal operation because everything appears to work. The thumbprint (`thp`) is the trust anchor that must be obtained out of band — typically via `tang-show-keys` run on the Tang server itself over SSH, then baked into configuration management. Note that HTTPS alone is not the answer Clevis relies on; the thumbprint is the designed mechanism, and it protects even against a compromised transport.

**A7.3** — NBDE binds decryption capability to **network location**: the disk unlocks only where it can reach the Tang server. It therefore addresses **theft of the physical medium** — a stolen laptop, a disk pulled from a decommissioned server, a drive returned under RMA, a whole chassis removed from the rack — because outside the network the keyslot cannot be recovered and there is no passphrase to coerce out of anyone. It explicitly does **not** address an attacker who has any presence on that network or on the host: a compromised host can unlock its own disk on demand; anyone who can boot the machine on the trusted LAN gets a decrypted disk; a malicious insider with rack access and network access has full capability; and it provides no protection at all while the system is running. NBDE is about unattended reboots of *physically* protected machines, not about defending a live host.

**A7.4** — `"t":1` means any **one** of the listed pins suffices (a 1-of-2 threshold), so either Tang server alone can unlock — the availability-oriented configuration, tolerating one server's outage. `"t":2` requires **both**, converting the policy from redundancy to conjunction: it raises the bar for an attacker (both servers must be reachable and honest) but any single outage now blocks boot entirely. `{"t":2,"pins":{"tang":[...],"tpm2":[...]}}` expresses "unlock only if the machine is **both** on the trusted network **and** running with the expected TPM PCR state" — i.e. correct location *and* unmodified boot chain. That combination defeats both disk theft (no network) and evil-maid firmware/bootloader tampering (PCR mismatch), at the cost of failing to boot after any legitimate firmware or bootloader update until the TPM pin is re-bound with `clevis luks regen`.

**A7.5** — Every bound client must run `clevis luks report -d <dev> -s <slot>`, which detects that the keyslot is bound to a key no longer advertised and offers to re-bind (`clevis luks regen -d <dev> -s <slot>` does it non-interactively). The rotation procedure is deliberately two-phase: you *hide* the old keys by renaming them to filenames beginning with `.` in `/var/db/tang` (e.g. `mv /var/db/tang/OLD.jwk /var/db/tang/.OLD.jwk`) and generate new ones. Hidden keys are **no longer advertised** to new bindings but are **still usable for recovery**, so existing clients continue to boot while you migrate them. If you *delete* the old keys instead, every client still bound to them is immediately and permanently unable to unlock via Tang — they fall back to whatever passphrase keyslot remains, and if none exists, the data is lost. Delete old keys only after `clevis luks report` confirms every client has re-bound.

**A7.6** — `_netdev` is a **systemd** ordering directive, and systemd from the root filesystem is not yet running when the root filesystem needs to be unlocked. Root unlock happens in the **initramfs**, which must therefore contain the Clevis binaries, the `jose` library, a network stack, and a DHCP/static network configuration — plus the `clevis-luks-askpass` hook that answers the initramfs password prompt from the Tang binding. That means regenerating the initramfs after installing the Clevis integration packages: `dracut -fv --regenerate-all` on RHEL/Fedora (with `clevis-dracut` installed) or `update-initramfs -u -k all` on Debian/Ubuntu (with `clevis-initramfs`), and configuring the initramfs to bring up networking (`ip=dhcp` on the kernel command line, or `rd.neednet=1` for dracut). `_netdev` in `crypttab` remains correct and necessary for *non-root* network-unlocked volumes.

### Exercise 8

**A8.1** — eCryptfs writes an **8192-byte header** (two 4096-byte extents by default) at the start of every file, holding the format marker, flags, the original file size, the root IV, and the **encrypted FEK** wrapped by the FEKEK. Content is then encrypted in 4096-byte extents, so a 19-byte file becomes 8192 (header) + 4096 (one padded extent) = 12288 bytes. An attacker holding only `.Private` still learns: the **number of files and directories**, the **directory tree structure**, each file's **size rounded up to the extent granularity** (which for large files is near-exact), all **timestamps**, **ownership and permissions**, **access patterns over time**, and the approximate **length of each filename** (the encrypted name length is a deterministic function of the plaintext length). Only the file contents and the filename characters are protected.

**A8.2** — Three keys, two levels of wrapping:
 - **FEK** (File Encryption Key) — a *random* symmetric key generated per file, used to encrypt that file's contents. It is stored, encrypted, inside that file's own 8 KiB header. Per-file keys are why eCryptfs files are individually portable and why `rsync` of a single ciphertext file is meaningful.
 - **FEKEK** (File Encryption Key Encryption Key) — the *mount passphrase*, derived once and inserted into the user keyring; it wraps every FEK. Its 8-hex-digit signature is what appears in `Private.sig` and in the `ecryptfs_sig=` mount option.
 - **FNEK** (FileName Encryption Key) — used to encrypt filenames, producing the `ECRYPTFS_FNEK_ENCRYPTED.` prefix; identified by `ecryptfs_fnek_sig=`. By default `ecryptfs-setup-private` uses the same passphrase for both, hence the identical signatures in the lab output.

 The **wrapped passphrase** (`~/.ecryptfs/wrapped-passphrase`) is the FEKEK encrypted with the user's *login* passphrase. That is the whole point of the design: the login passphrase is not itself the FEKEK, so changing the login passphrase only requires re-wrapping (cheap) rather than re-encrypting every file (impossible). `pam_ecryptfs` unwraps it at login and inserts the FEKEK into the session keyring.

**A8.3** —
 - `auth ... pam_ecryptfs.so unwrap` — captures the plaintext login passphrase during authentication (the only moment it is available) and uses it to unwrap `wrapped-passphrase`, inserting the FEKEK into the kernel keyring.
 - `session ... pam_ecryptfs.so unwrap` — at session start, performs the actual `mount.ecryptfs_private` of `~/.Private` onto `~/Private` using the key placed in the keyring; on session close it unmounts and evicts the key.
 - `password ... pam_ecryptfs.so` — on **passphrase change**, re-wraps the FEKEK with the *new* login passphrase.

 Remove the `common-password` line and password changes stop re-wrapping: the FEKEK remains encrypted under the *old* login passphrase. The user changes their password successfully, logs out, logs back in with the new password — and `auth` fails to unwrap, so `~/Private` silently mounts empty (or does not mount at all). The data is still there and still recoverable, but **only** with the old login passphrase or the recorded mount passphrase. This is the single most common eCryptfs data-loss incident.

**A8.4** — `pam_ecryptfs` needs the **plaintext login passphrase** to unwrap `wrapped-passphrase`, and public-key SSH authentication never transmits or reveals it — `pam_sm_authenticate` for `pam_unix` is bypassed entirely by `PubkeyAuthentication`, so there is nothing to capture. The session therefore starts with an empty keyring and `~/Private` stays locked (typically showing only the `Access-Your-Private-Data.desktop` stub). Standard mitigations: (i) have the user run `ecryptfs-mount-private` manually after login and enter the passphrase interactively; (ii) use `ssh` with password or keyboard-interactive authentication for accounts that need the automatic mount; (iii) abandon per-user eCryptfs and move to **full-disk LUKS**, which is exactly the transition Ubuntu made when it deprecated encrypted-home in 18.04 — the SSH-key case being one of the motivating failures.

**A8.5** —
 | Axis | eCryptfs | LUKS / dm-crypt |
 |---|---|---|
 | **What is hidden** | File *contents* and *filenames* only. Directory structure, file count, sizes (to extent granularity), timestamps, ownership and permissions are all in the clear. | Everything above the block layer: the entire filesystem, including all metadata, structure, free-space layout and file count. Only the LUKS header is plaintext. |
 | **Key granularity** | Per-file FEK, wrapped by a per-user FEKEK. Different users on the same machine have genuinely independent keys; a single file can be shared with its key. | One master key per volume. Multiple passphrases unlock the *same* master key — they are credentials, not separate keys. No per-user or per-file separation. |
 | **Pre-sizing** | None. It stacks on an existing filesystem and grows with it; no container to size, no resizing, no wasted space. | The container is a block device of fixed size. Growing means growing the underlying device/partition/LV *and* `cryptsetup resize` *and* the filesystem. |
 | **`rsync` backup** | Ciphertext files in `.Private` are individually syncable and individually restorable — incremental backup works naturally, and the backup target never sees plaintext. Each file carries its own wrapped FEK, so restoring one file is meaningful. | The mapping must be *open* to back up file-by-file, which means the backup sees plaintext. Backing up the closed container means copying the whole block device (or using LVM snapshots + block-level tools); incrementals are coarse and a single changed byte dirties a whole extent. |

 Practical summary: eCryptfs fits multi-user shared machines, per-user home encryption, and cloud-sync scenarios (encrypt locally, sync ciphertext). LUKS fits full-disk protection, laptop theft, decommissioning, and anything where metadata leakage is unacceptable. They compose — LUKS underneath for the metadata, eCryptfs or fscrypt on top for per-user key separation.

**A8.6** — `ecryptfs_passthrough=y` allows **unencrypted files to be read and written through the eCryptfs mount**: files in the lower directory that lack the eCryptfs header are passed through verbatim instead of producing an error. It exists for migration — mounting an existing directory and encrypting files gradually. In a home-directory deployment it is a hazard because it removes the guarantee that everything under `~/Private` is encrypted: any file written by a process that bypasses the upper mount, or any file restored from an old backup, is silently readable in the lower directory forever, with no warning and no visible difference from the user's side. `ecryptfs-setup-private` therefore sets `=n` so that the invariant "everything in `.Private` is ciphertext" actually holds.

**A8.7** — Because the **wrapped passphrase is the only copy of the FEKEK**, and it is protected by the user's login passphrase. If the login passphrase is forgotten, if `/etc/shadow` is restored from an inconsistent backup, if the `password` PAM line is removed and a password change de-synchronises the wrapping (see A8.3), or if `~/.ecryptfs/wrapped-passphrase` is itself lost or corrupted, then **every file is unrecoverable** — there is no master key escrow, no recovery slot, no equivalent of a second LUKS keyslot. The raw mount passphrase printed by `ecryptfs-unwrap-passphrase` bypasses all of that: with it, `ecryptfs-recover-private` can mount `.Private` from a rescue environment regardless of the account's state. Recording it offline before go-live is the only escrow eCryptfs offers.

### Exercise 9

**A9.1** — fscrypt encrypts **file contents** and **filenames**, and nothing else. Left in the clear: file **sizes** (exact, not padded), **timestamps** (atime/mtime/ctime/crtime), **ownership** (uid/gid), **permissions and ACLs**, **link counts and inode numbers**, **directory structure and the number of entries**, **extended attributes**, and the **filesystem's block allocation map**. Realistic leakage scenario: an encrypted directory of medical or legal documents where the exact byte size of each file, combined with a public corpus of known document sizes, fingerprints the documents — the classic size-correlation attack. Another: mtime patterns across an encrypted mail spool reveal communication timing and volume, which for many threat models is the interesting part. A third: a `git` working tree's file count and size distribution identifies the repository.

**A9.2** — The encryption policy is stored in the **inode of the directory** and is inherited by every file and subdirectory created inside it — it is applied at file-creation time, when the per-file key is derived and the extents are laid down. The kernel has no mechanism to retroactively encrypt already-written extents: doing so would mean rewriting every file's data and renaming every entry under a new key while maintaining consistency, which is a filesystem-level rewrite operation ext4 simply does not implement. `FS_IOC_SET_ENCRYPTION_POLICY` therefore returns `ENOTEMPTY` on a non-empty directory. The correct migration is: create a new empty encrypted directory, `mv`/`cp` the data in, then securely erase the original (which on an SSD means you should have encrypted at the block layer to begin with — the old plaintext extents may survive in unmapped flash pages).

**A9.3** — `padding:32` pads **encrypted filenames** up to a multiple of 32 bytes before encryption. Filename encryption is length-revealing by nature — AES-CTS preserves length — so without padding the ciphertext filename discloses the exact plaintext filename length. That blunts a real attack: filename lengths in a known directory layout (a source tree, a mail Maildir, an application's data directory) act as a fingerprint identifying the contents. Padding to 32 collapses many distinct lengths into the same bucket, at the cost of longer names on disk. Options are 4, 8, 16 and 32; 32 is the strongest and the fscrypt default.

**A9.4** —
 - **v1 policies** identify the master key by an 8-byte *descriptor* and look it up in the calling process's **session keyring** (`@s`), keyed as `logon` type `fscrypt:<descriptor>`. Consequences: the key is per-process-keyring, so every process that wants access must have it in its own keyring; there is no reliable way to *remove* the key from all users at once (`fscrypt lock` on v1 is best-effort and needs `root` plus cache dropping); and any user who can guess or obtain the descriptor and inject a key can attack the policy. v1 has no real access control and no proof that the supplied key is the right one — a wrong key produces garbage rather than an error.
 - **v2 policies** identify the master key by a 16-byte **identifier that is a cryptographic hash of the key itself**, and the key is added to a per-**filesystem** keyring via the `FS_IOC_ADD_ENCRYPTION_KEY` ioctl. Consequences: adding a wrong key is *detected* (the identifier will not match); the key is owned by the filesystem, not by a process, so `FS_IOC_REMOVE_ENCRYPTION_KEY` genuinely evicts it and invalidates all cached inodes at once; unprivileged users can add keys for their own use and the kernel tracks per-user claims so one user's removal does not break another's; and the per-file keys use HKDF-SHA512 with a per-file nonce rather than the weaker v1 derivation. v2 requires kernel 5.4+ and is the default for `fscrypt(1)` today. **Use v2** unless you must interoperate with an older kernel.

**A9.5** — No, fscrypt alone is not sufficient. It only encrypts *files inside directories you explicitly marked*, on filesystems that support it. It cannot encrypt: the filesystem's own metadata and journal, `/etc` and `/var` in the general case (system directories must be readable at boot before any key exists, and many contain files created by the installer), the **swap** partition (not a filesystem at all), hibernation images, the kernel and initramfs in `/boot`, or any filesystem type without native encryption support. It also leaks all the metadata listed in A9.1. The correct layering is **LUKS/dm-crypt underneath for whole-device confidentiality**, providing the metadata protection and covering swap and `/`, with **fscrypt on top** only where you additionally need per-user or per-directory key separation — e.g. multi-user home directories where you want one user's data to stay locked while another is logged in, or a shared server where you want to lock a project directory without unmounting anything. LUKS handles theft-of-medium; fscrypt handles separation-between-users on a running system. They solve different problems.

**A9.6** — Put **LUKS2 with `--integrity`** (dm-integrity, as in Exercise 6) underneath the ext4 filesystem that hosts the fscrypt policies. dm-integrity authenticates every sector of the block device, so any tampering with the ext4 metadata, the fscrypt policy xattrs, or the encrypted file extents is detected and reported as an I/O error — closing exactly the gap fscrypt leaves open. fscrypt continues to provide per-directory keys and per-user locking above it. The alternatives are `dm-verity` (read-only, so it fits an immutable system image but not user data) or a filesystem with native checksumming and authentication (btrfs/ZFS checksums detect corruption but not *authenticated* tampering, since an attacker who rewrites data can rewrite the checksum too — you need a keyed MAC, which is what dm-integrity in AEAD mode provides).

### Exercise 10

**A10.1** — The `cryptmount` binary is installed **setuid root**, and it drops privileges after doing only the specific work that requires them (creating the device-mapper node and calling `mount(2)`). The security boundary is enforced by the `cmtab`, which is root-owned and not user-writable: the `dir=` field pins the mount point, and `dev=` pins the container, so alice can only mount the exact target she is named for at the exact path the administrator chose. The additional gate is the **ownership of the mount point directory** — `cryptmount` requires the invoking user to own `dir` (and, for `--change-password`, to know the existing password), so alice cannot mount `bob`'s target even by naming it. Optional `cmtab` fields tighten this further: `passwdretries`, `supath` (the PATH used while privileged), and per-target restrictions. As with any setuid binary, the `cmtab` must never be writable by non-root — that would be a direct root escalation.

**A10.2** — Without `nosuid`, the kernel honours the setuid bit on executables inside the mounted filesystem. Alice controls the *contents* of her container completely: she can create it, put a root-owned setuid-root shell inside it (obtaining one is easy — copy `/bin/bash` in, then use any brief root access, a container image, or simply craft the ext4 image offline with `debugfs`/`e2tools` and set the mode and owner bits directly), then mount it with `cryptmount -m` and execute it. That is an immediate, unconditional local root shell. `nodev` closes the analogous hole with device nodes: a `mknod`-ed `/dev/sda` inside the image would give raw disk access. Any user-mountable filesystem must carry `nosuid,nodev` — and `noexec` too where the workload permits. This is the same reason `mount(8)` forces `nosuid,nodev` for `user`/`users` entries in `fstab`.

**A10.3** — With `keyformat=luks` and `keyfile` pointing at the container file itself, the arrangement is exactly a standard LUKS volume: the **LUKS header (with its keyslots) lives at the start of the container**, and `cryptmount` simply drives `cryptsetup`'s LUKS path — the passphrase unwraps a keyslot, which yields the master key, which decrypts the payload after the header. Everything is self-contained in one file, which is portable and can equally be opened with plain `cryptsetup open`. With `keyformat=builtin` (or `openssl`/`openssl-compat`/`raw`) and a *separate* `keyfile=` path, the encrypted master key is stored **outside** the container in cryptmount's own key file format, and the container holds nothing but ciphertext. That is effectively a detached header: the container becomes indistinguishable from random data (no LUKS signature), and you can keep the key file on removable media so the container is inert without it — at the cost that losing the key file loses the data, and that you can no longer open the volume with stock `cryptsetup`.

**A10.4** — When **unprivileged users must mount and unmount their own encrypted containers on demand**, without `sudo`, without a polkit rule, and without a running systemd session. `crypttab` + `systemd-cryptsetup` is fundamentally a *system* facility: entries are administrator-defined, activation is root-privileged, and it is oriented around boot-time and system-lifecycle volumes. `cryptmount` was written precisely for the multi-user shell-server case — the administrator provisions the target once in `cmtab`, and thereafter the user manages the lifecycle themselves. It also works on systems without systemd, and it handles the mount and the crypto in a single atomic user-facing command. For anything that must come up at boot, be managed by configuration management, or participate in systemd's dependency graph, `crypttab` is the right tool.

### Exercise 11

**A11.1** — `umount /mnt/vault && cryptsetup close vault`. The mapping cannot be torn down while anything holds a reference to it — a mount, an open file descriptor, a swap activation, an LVM PV, or a stacked device-mapper target. To find the holder: `lsof /mnt/vault` or `fuser -vm /mnt/vault` for processes; `dmsetup info -c -o name,open` to see the open count on the mapping itself; `dmsetup ls --tree` to spot a device stacked on top; and `lsblk /dev/mapper/vault` to see mounts and holders. If a process refuses to release it, `umount -l` (lazy) detaches the tree immediately and completes when the last descriptor closes — but note the mapping stays busy until then, so `cryptsetup close` will still fail right after a lazy unmount.

**A11.2** — LUKS2 keyslots are limited by the **size of the keyslots area** rather than by a fixed count: each slot must hold an AF-split copy of the master key (stripes × key length, here 4000 × 64 = 250 KiB, rounded to the 258048-byte area length seen in the dump), so the default ~16 MiB keyslots area accommodates **32 slots** at a 512-bit key — and fewer if you increase the key size or the stripe count. The count is also capped at 32 by the LUKS2 specification regardless of available space. LUKS1, by contrast, has exactly **8 slots** hard-coded into a fixed-layout binary header with fixed key-material offsets; there is no way to add a ninth. The practical consequences: LUKS2 gives you room for per-admin passphrases, several key files, and Clevis/TPM/FIDO2 token slots on the same volume; and on LUKS2 you can enlarge the keyslots area at format time with `--luks2-keyslots-size`.

**A11.3** — `[ACTIVE_LAST]` here reflects the priority ordering: slot 3 was marked `prefer` in Exercise 2, so cryptsetup attempts it before the `normal` slots. Without priorities, cryptsetup tries slots in index order until one succeeds. On a volume with, say, six Argon2id slots each costing ~2 s and 1 GiB of RAM, unlocking with the credential in slot 5 means five failed derivations first — roughly **10 seconds of pure waste** on every single boot, plus 1 GiB of memory pressure per attempt (which on a small initramfs can itself fail). Setting `prefer` on the boot credential's slot and `ignore` on emergency/recovery slots eliminates both. It matters most exactly where it hurts most: unattended reboots of memory-constrained appliances.

**A11.4** — In order:
 1. **Is the header intact and readable?** `cryptsetup isLuks -v /dev/sdX` and `cryptsetup luksDump /dev/sdX`. If the dump prints a sane version, UUID, cipher and at least one active keyslot, the header is structurally fine and the problem is elsewhere — go to step 2. If it fails, check whether the device path is even correct (`lsblk`, `blkid`) before concluding damage.
 2. **Does the credential itself still verify?** `cryptsetup open --test-passphrase --verbose /dev/sdX` (add `--key-file` for key files). This separates "wrong credential" from "cannot activate". If a key file is involved, this is where the A2.4 trap surfaces — compare `sha256sum` of the key file against a known-good value and confirm `keyfile-size`/`keyfile-offset` match what `crypttab` specifies. `Key slot N unlocked` here means the crypto is fine and the failure is at activation.
 3. **Can the kernel provide the cipher?** `cryptsetup --debug open ...` and look for where it stops; `dmsetup targets` to confirm `crypt` is present; `modprobe dm_crypt` plus the specific cipher modules; `cat /proc/crypto | grep -A2 xts`; and `journalctl -k | grep -i crypt`. A kernel upgrade that dropped a module (or a FIPS-mode kernel refusing a non-approved cipher, or a missing `aes_generic`/`xts`/`sha256` in a stripped initramfs) produces exactly the reported symptom — the passphrase is accepted, then activation fails and the tool re-prompts. Also check whether the *initramfs* was regenerated after the upgrade, which is the most common root cause.

 Only after all three do you reach for the header backup.

**A11.5** — `cryptsetup open` on `/dev/loop3` would fail with `Cannot use device /dev/loop3, name is invalid or still in use` (or `Device or resource busy`), because the orphaned `sealed_dif` integrity mapping still holds an exclusive claim on the backing device — cryptsetup opens the source with `O_EXCL` and the claim is still live even though the top-level crypt device is gone. Clean up by removing the leftover explicitly: `dmsetup remove sealed_dif` (or `cryptsetup close sealed_dif`), verify with `dmsetup ls --tree` that nothing remains, then reopen normally. The general lesson is that **stacked device-mapper devices must be torn down top-down**; `cryptsetup close` on an integrity-protected LUKS2 volume removes both layers for you, which is exactly why you should use it rather than `dmsetup remove` on the individual targets.

### Exercise 12

**A12.1** — Verify that **at least one other credential is known-good and tested** on that volume before deleting the key file — run `cryptsetup open --test-passphrase /dev/sdX` with the interactive passphrase (or with a second key file) and confirm it returns success, and check `cryptsetup luksDump` shows more than one active keyslot. Also confirm that anything automated (a `crypttab` entry, an Ansible role, a backup job) is not still pointing at the file you are about to remove. If you get it wrong and that key file was the **only** credential for an active keyslot: as long as the volume is still **open**, you can recover completely — `cryptsetup luksDump --dump-volume-key /dev/sdX` is not available without a credential, but `cryptsetup luksHeaderBackup` plus, critically, extracting the volume key from the running mapping (`dmsetup table --showkeys` if the key is not in the keyring, or `cryptsetup luksDump --dump-master-key` with any working credential) lets you re-add a keyslot with `cryptsetup luksAddKey --master-key-file`. Once the volume is **closed**, with no keyslot recoverable, the data is gone — there is no recovery path, which is the same crypto-shredding property from A3.4 working against you. In production, delete key material only after a verified fallback, and keep an offline emergency passphrase in a slot marked `--priority ignore`.

**A12.2** — Calling `cryptsetup close vault` while `/mnt/vault` is still mounted fails with `Device vault is still in use` and exit status 5, because the mounted filesystem holds an open reference on `/dev/mapper/vault` (`dmsetup info -c -o open` would show `1`). Nothing is damaged — the mapping stays active and the data stays consistent — but the teardown script silently leaves state behind, and the subsequent `losetup -D` then fails too (or, worse, on some kernels detaching a loop device still claimed by an active mapping leaves a dangling device-mapper target whose backing store is gone, producing I/O errors and a mapping that cannot be cleanly removed). The rule is that the stack unwinds in reverse of how it was built: **filesystem → device-mapper → loop/backing device**, and each step should be checked (`findmnt`, `dmsetup ls`, `losetup -a`) rather than assumed.

</details>