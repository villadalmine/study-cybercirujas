# Encrypted File Systems

**LPIC-3 303-300 (Security), Topic 331.3 — Cryptography**
Audience: Platform Architects and SREs who have to answer, in a post-incident review, the question *"the disk left the datacenter — what did the attacker get?"*

---

## 0. Objective map

The official objective set is published by LPI; the wording below is a paraphrase for study navigation, and the authoritative text lives at the URL in [§15](#15-references).

| Knowledge area | Where it is covered here |
|---|---|
| Understand block device vs. file system encryption | [§1](#1-the-production-problem), [§2](#2-where-to-encrypt-the-four-layers) |
| `dm-crypt` with LUKS1 and LUKS2 | [§3](#3-dm-crypt-internals), [§4](#4-the-luks-on-disk-format), [§5](#5-cryptsetup-operational-runbook) |
| Plain `dm-crypt` (no header) | [§3.6](#36-plain-dm-crypt-the-headerless-mode) |
| LUKS2 features: integrity, tokens, requirements, online reencryption | [§5.9–5.11](#59-converting-luks1--luks2), [§6](#6-integrity-dm-integrity-and-authenticated-encryption) |
| `/etc/crypttab`, `systemd-cryptsetup`, `systemd-cryptenroll` | [§7](#7-unlocking-at-boot-crypttab-systemd-and-the-initramfs) |
| eCryptfs, home directories, PAM integration | [§8](#8-ecryptfs-stacked-per-file-encryption) |
| Awareness of other solutions | [§9](#9-filesystem-native-encryption-awareness), [§10](#10-userspace-stacked-encryption-and-cryptmount) |
| Terms: `cryptsetup`, `cryptmount`, `/etc/crypttab`, `ecryptfs-*`, `mount.ecryptfs`, `umount.ecryptfs`, `pam_ecryptfs`, `systemd-cryptenroll` | [§13 cheat sheet](#13-exam-traps-and-command-cheat-sheet) |

---

## 1. The production problem

### 1.1 Encryption at rest is a *threat model*, not a checkbox

Every compliance framework asks for "encryption at rest" and every cloud provider answers "done, we encrypt all volumes." Both statements are true and both are close to useless unless you name the adversary. Disk encryption defends against exactly one class of attack: **an adversary who obtains the storage medium in a state where the key is not present.**

| Threat | Defeated by full-disk encryption (LUKS)? | Notes |
|---|---|---|
| Decommissioned NVMe sold on eBay | **Yes** | The canonical case. Also defeats failed-drive RMA returns. |
| Datacenter theft of a powered-off server | **Yes** | Key material only exists in RAM while unlocked. |
| Datacenter theft of a **running** server | No | Master key is in kernel memory; cold-boot / DMA attacks apply. `cryptsetup luksSuspend` narrows this. |
| Hypervisor / cloud operator reading your block storage | **Yes**, if you encrypt *inside* the guest | Provider-side encryption (EBS/PD default) is transparent to the provider. |
| Root compromise on the running host | No | The filesystem is mounted and plaintext to any process with the right credentials. |
| Another tenant's container escaping into your node | No | Same mount namespace reachability; use per-workload keys or filesystem-level crypto. |
| Malicious storage backend silently flipping bits | **No** with plain LUKS (XTS is malleable) | Needs `dm-integrity` / AEAD — [§6](#6-integrity-dm-integrity-and-authenticated-encryption). |
| Backup tapes / object-store snapshots | Only if the backup path also carries ciphertext | Block-level snapshots of an *unlocked* device are plaintext. |
| A user reading another user's `$HOME` | No with LUKS (one key per device) | This is the eCryptfs / fscrypt use case. |

The architectural consequence: **the layer at which you encrypt determines which of those rows you get.** A single "encrypt everything" LUKS device gives you rows 1–4 and nothing else. That is usually the right first move and almost never the whole answer.

### 1.2 The key custody problem is the real problem

The cryptography is solved. What breaks in production is the key lifecycle:

- A LUKS volume that needs an interactive passphrase cannot survive an unattended reboot at 03:00. A fleet of 400 nodes cannot be babysat.
- A keyfile stored on the same unencrypted `/boot` is theatre.
- A TPM-sealed key bound to PCR 7 will refuse to unseal after a firmware update — turning a routine BIOS patch into a fleet-wide outage.
- A key escrowed only in the heads of two SREs is a single bus-factor away from unrecoverable data.

Every design in this material is judged on the same three axes: **who can unlock (availability), who cannot (confidentiality), and what happens when the unlock path breaks (recoverability).**

### 1.3 The reference production scenario used throughout

A bare-metal Kubernetes worker pool:

```
/dev/sda        480G  SATA SSD   — OS: /boot (plain), LUKS2 → LVM → /, swap
/dev/nvme0n1    3.5T  NVMe       — LUKS2 → XFS  — container runtime + local PVs
/dev/nvme1n1    3.5T  NVMe       — LUKS2 → XFS  — PostgreSQL data (integrity-protected)
```

Unlock policy: TPM2-sealed key for the OS disk (PCR 7 + PCR 14 policy), network-bound (Tang) for the data disks, printed recovery keys in a safe, and a keyslot for the on-call passphrase. Nothing is ever unlocked by a human on a normal boot; every unlock path has a documented fallback.

---

## 2. Where to encrypt: the four layers

```
 ┌───────────────────────────────────────────────────────────────┐
 │ 4. Application     pgcrypto, age, restic, sops, client-side   │  per-record keys
 ├───────────────────────────────────────────────────────────────┤
 │ 3. Stacked FS      eCryptfs, gocryptfs/EncFS (FUSE)           │  per-file, per-user
 ├───────────────────────────────────────────────────────────────┤
 │ 2. Native FS       fscrypt (ext4/f2fs), ZFS native, UBIFS     │  per-directory
 ├───────────────────────────────────────────────────────────────┤
 │ 1. Block device    dm-crypt / LUKS, dm-integrity, SED/OPAL    │  whole volume
 ├───────────────────────────────────────────────────────────────┤
 │ 0. Hardware        self-encrypting drive firmware             │  opaque, untrusted
 └───────────────────────────────────────────────────────────────┘
```

### 2.1 Trade-off matrix

| Property | dm-crypt/LUKS (block) | fscrypt (native FS) | eCryptfs (stacked) | gocryptfs (FUSE) | Application |
|---|---|---|---|---|---|
| Granularity | Whole block device | Per-directory tree | Per-directory tree | Per-directory tree | Per-field / per-object |
| Encrypts file **contents** | Yes | Yes | Yes | Yes | Yes |
| Encrypts **file names** | Yes (whole FS is opaque) | Yes | Optional (`ecryptfs_fnek_sig`) | Yes | n/a |
| Encrypts **metadata** (sizes, mtimes, dir structure) | Yes | **No** | No (per-file header, size leaks) | No | n/a |
| Encrypts **free space / FS layout** | Yes | No | No | No | No |
| Multiple independent keys on one FS | No (one master key) | **Yes** | **Yes** (per user) | Yes | Yes |
| Works on network/shared storage (NFS, S3) | No (needs a block device) | No | Historically yes, fragile | **Yes** | Yes |
| Kernel-side or userspace | Kernel (device-mapper) | Kernel (VFS) | Kernel (stacked VFS) | Userspace (FUSE) | Userspace |
| Typical throughput cost | 2–8% with AES-NI | ~5% | 20–40% | 30–60% | Varies |
| Resize / grow online | Yes (`cryptsetup resize`) | Follows FS | Follows lower FS | Follows lower FS | n/a |
| Integrity / tamper detection | Optional (`--integrity`) | No (contents only) | No | Yes (GCM per block) | Depends |
| Survives snapshot/replication of ciphertext | Yes | Yes | Yes | Yes | Yes |
| Boot-time unattended unlock story | Mature (TPM2, Tang, tokens) | Manual / PAM | PAM | Manual | n/a |
| Exam relevance (303-300) | **Primary** | Awareness | **Primary** | Awareness | Awareness |

### 2.2 The rule of thumb

> **Encrypt the block device for the "stolen disk" threat. Add a filesystem- or application-layer key for the "other tenant / other user / other service" threat. These are not alternatives — production systems run both.**

The reason people get this wrong is that block encryption is *invisible*: once unlocked, `/srv/data` looks exactly like an unencrypted `/srv/data`, which makes it feel like more protection than it is. eCryptfs and fscrypt are visible — each user's data is unreadable to other users even on a running box — which is why they exist despite being strictly worse at layout hiding.

---

## 3. dm-crypt internals

### 3.1 It is a device-mapper target, nothing more

`dm-crypt` is a kernel device-mapper target that maps a virtual block device onto a physical one, encrypting on write and decrypting on read, **sector by sector, with no expansion**. Sector *n* of the plaintext device maps to sector *n + offset* of the ciphertext device, always the same size. This is what makes it transparent to every filesystem — and what forbids per-sector authentication tags without a second layer ([§6](#6-integrity-dm-integrity-and-authenticated-encryption)).

The mapping table is the whole interface:

```
$ sudo dmsetup table pgdata
0 7501344768 crypt aes-xts-plain64 :64:logon:cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0 0 259:1 32768 4 sector_size:4096 no_read_workqueue no_write_workqueue iv_large_sectors
```

Field by field:

| Field | Value | Meaning |
|---|---|---|
| start / length | `0 7501344768` | Logical sectors of the mapped device (512-byte units) |
| target | `crypt` | The dm target |
| cipher spec | `aes-xts-plain64` | `<cipher>-<chainmode>-<ivmode>` |
| key | `:64:logon:cryptsetup:<uuid>-d0` | **Key description in the kernel keyring**, not the key |
| iv offset | `0` | Value added to the sector number before IV derivation |
| device | `259:1` | major:minor of `/dev/nvme1n1` |
| offset | `32768` | Data starts 32768×512 B = **16 MiB** into the device (LUKS2 header) |
| opts | `sector_size:4096 …` | Performance/behaviour flags |

Note the key is a keyring reference (`logon` type). Older kernels and `--disable-keyring` put the raw hex master key in the table, where `dmsetup table --showkeys` — and anything reading `/proc`-adjacent state as root — could read it. Modern `cryptsetup` keeps it in the kernel keyring:

```
$ sudo dmsetup table --showkeys pgdata | awk '{print $5}'
:64:logon:cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0
$ sudo keyctl search @u logon cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0
  # key exists but its payload is not readable from userspace
```

### 3.2 Anatomy of the cipher specification

`aes-xts-plain64` decomposes as **cipher – chain mode – IV mode**:

- **`aes`** — the block cipher. Alternatives compiled into the kernel crypto API: `serpent`, `twofish`, `camellia`, and the stream cipher `chacha20`. Anything with AES-NI or ARMv8 Crypto Extensions makes AES the only sane default; without hardware AES, `chacha20-poly1305` or `serpent` become genuinely competitive.
- **`xts`** — XTS-AES, standardised in NIST SP 800-38E, is a *tweakable narrow-block* mode designed exactly for storage: it needs no per-sector nonce storage and it is deterministic per (key, sector). It consumes **two keys**, so `--key-size 512` means AES-256-XTS, not AES-512. This is the single most common misreading of `cryptsetup` output.
- **`plain64`** — how the sector number becomes the tweak/IV: the 64-bit little-endian sector number, zero-padded.

| IV mode | Description | Use |
|---|---|---|
| `plain` | 32-bit sector number | Legacy; wraps at 2 TiB → **never use on large volumes** |
| `plain64` | 64-bit sector number | **Current default**, correct for XTS |
| `plain64be` | Big-endian variant | Interop with some appliances |
| `essiv:sha256` | IV = E(hash(key), sector) — hides sector number from watermarking attacks in CBC | Only meaningful for CBC; obsolete with XTS |
| `benbi` | Big-endian narrow block count | Used with LRW |
| `null` | IV = 0 | Loop-AES compatibility only |
| `random` | Random IV stored by dm-integrity | Required for `aes-gcm-random` AEAD mode |
| `eboiv`, `elephant` | BitLocker compatibility (`cryptsetup-bitlk`) | Reading BitLocker volumes |

**Why XTS and not CBC or GCM:** CBC over a sector allows watermarking and controlled-plaintext attacks unless the IV is unpredictable (`essiv`), and it propagates corruption. GCM cannot be used *without* storing a nonce and a tag, which does not fit into a same-size mapping — hence [§6](#6-integrity-dm-integrity-and-authenticated-encryption).

**What XTS does not give you:** it is deterministic and unauthenticated. Identical plaintext written to the same sector always yields identical ciphertext, so an attacker with two snapshots of the ciphertext learns exactly which sectors changed. And an attacker can flip ciphertext bits: the corresponding plaintext block turns to garbage, but the write *succeeds* and the filesystem may act on the garbage. Confidentiality yes; integrity no.

### 3.3 Sector size

The dm-crypt encryption unit defaults to 512 bytes. On 4Kn drives and on any modern SSD, `--sector-size 4096` reduces the number of crypto operations by 8× per 4 KiB filesystem block and measurably improves throughput.

| Sector size | Compatibility | Performance | Constraint |
|---|---|---|---|
| 512 | Universal, only option for LUKS1 in practice | Baseline | — |
| 1024/2048 | Rare | Intermediate | — |
| **4096** | LUKS2, kernel ≥ 4.12 | +10–30% on NVMe | Device logical block size must divide it; changing it later requires reencryption |

Combine with `--integrity`, and 4096 becomes effectively mandatory, because per-512-byte tags waste enormous space.

### 3.4 The workqueue problem (a real production win)

By default dm-crypt pushes every I/O through per-CPU kernel workqueues (`kcryptd`). On rotational disks that decouples crypto from the submitting thread and helps. On NVMe it is pure added latency and a scheduling bottleneck — Cloudflare documented ~2× throughput recovery by bypassing them, and the flags landed upstream in kernel 5.9.

```
$ sudo cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue \
    --persistent open /dev/nvme1n1 pgdata
```

| Flag | crypttab option | Effect | When |
|---|---|---|---|
| `--perf-same_cpu_crypt` | `same-cpu-crypt` | Encrypt on the CPU that submitted the I/O | Many-core NUMA, cache locality |
| `--perf-submit_from_crypt_cpus` | `submit-from-crypt-cpus` | Avoid a context switch on submission | With `same_cpu_crypt` |
| `--perf-no_read_workqueue` | `no-read-workqueue` | Decrypt inline in the submitting context | **NVMe / low-latency** |
| `--perf-no_write_workqueue` | `no-write-workqueue` | Encrypt inline, submit synchronously | **NVMe / low-latency** |
| `--perf-high_priority` | `high-priority` | High-prio workqueues + IO thread nice (cryptsetup ≥ 2.7) | Latency-sensitive |
| `--allow-discards` | `discard` | Pass TRIM to the backing device | **See warning below** |

`--persistent` writes those flags into the LUKS2 header so subsequent opens inherit them — a LUKS2-only feature and one of the better reasons to convert from LUKS1.

**TRIM warning.** `--allow-discards` leaks the *pattern of allocated blocks* to anyone who can read the raw device — the filesystem's used/free map, in the clear. It also weakens deniability for headerless setups. On enterprise SSDs with adequate over-provisioning, leaving it off costs little; on cheap consumer NVMe under sustained write load, leaving it off costs a great deal. Decide deliberately and record the decision.

### 3.5 Where the CPU actually goes

```
$ cryptsetup benchmark
# Tests are approximate using memory only (no storage IO).
PBKDF2-sha1      2071040 iterations per second for 256-bit key
PBKDF2-sha256    2551808 iterations per second for 256-bit key
PBKDF2-sha512    1069056 iterations per second for 256-bit key
PBKDF2-ripemd160  959488 iterations per second for 256-bit key
PBKDF2-whirlpool  703488 iterations per second for 256-bit key
argon2i       4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
argon2id      4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
#     Algorithm |       Key |      Encryption |      Decryption
        aes-cbc        128b      1017.5 MiB/s     3441.2 MiB/s
    serpent-cbc        128b        92.3 MiB/s      664.7 MiB/s
    twofish-cbc        128b       207.4 MiB/s      391.6 MiB/s
        aes-cbc        256b       780.4 MiB/s     2707.6 MiB/s
    serpent-cbc        256b        94.6 MiB/s      666.7 MiB/s
    twofish-cbc        256b       219.9 MiB/s      391.5 MiB/s
        aes-xts        256b      2733.6 MiB/s     2728.2 MiB/s
    serpent-xts        256b       621.4 MiB/s      616.3 MiB/s
    twofish-xts        256b       374.9 MiB/s      380.1 MiB/s
        aes-xts        512b      2288.9 MiB/s     2286.4 MiB/s
    serpent-xts        512b       631.9 MiB/s      617.2 MiB/s
    twofish-xts        512b       381.6 MiB/s      381.9 MiB/s
```

Read that as: **AES-256-XTS costs about 2.3 GB/s per core on this box.** A 7 GB/s Gen4 NVMe will saturate ~3 cores under sequential load. Confirm AES-NI is actually in use before believing the numbers:

```
$ grep -o -m1 -E 'aes|vaes' /proc/cpuinfo | sort -u
aes
vaes
$ grep -A4 'name *: *xts(aes)' /proc/crypto | head -12
name         : xts(aes)
driver       : xts-aes-aesni
module       : aesni_intel
priority     : 401
refcnt       : 3
```

If `driver` shows `xts(ecb(aes-generic))` you are running software AES and throughput will be roughly 10× worse.

### 3.6 Plain dm-crypt: the headerless mode

Plain mode stores **nothing** on disk: no header, no salt, no keyslots, no UUID. The key is derived directly from the passphrase by a plain hash (default `ripemd160` historically, `sha256` on modern builds — always specify it explicitly).

```
$ sudo cryptsetup open --type plain \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --offset 0 --skip 0 \
    /dev/sdb1 plainvol
Enter passphrase for /dev/sdb1:
$ sudo cryptsetup status plainvol
/dev/mapper/plainvol is active.
  type:    PLAIN
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: dm-crypt
  device:  /dev/sdb1
  sector size:  512
  offset:  0 sectors
  size:    2097152 sectors
  mode:    read/write
```

| | Plain dm-crypt | LUKS |
|---|---|---|
| On-disk metadata | None — indistinguishable from random data | 16 MiB header (LUKS2) |
| Passphrase change | Impossible (would reencrypt everything) | `luksChangeKey`, instant |
| Multiple passphrases | No | Up to 8 (LUKS1) / 32 (LUKS2) |
| Key stretching | Single hash — **brute-forceable** | PBKDF2 / Argon2id |
| Wrong parameter recovery | Silent garbage, no error | "No key available with this passphrase." |
| Header loss risk | None | Header loss = total data loss |
| Anti-forensic key erasure | n/a | AF splitter |
| Use case | Deniability, random-key swap, embedded | **Everything else** |

Plain mode's one unambiguous production use is **random-key swap**, where the key is regenerated at every boot from `/dev/urandom` and no one ever needs to unlock it again ([§7.6](#76-encrypted-swap-and-the-hibernation-trap)). Its other use — plausible deniability — depends on getting `--cipher`, `--key-size`, `--hash`, `--offset` and `--skip` exactly right from memory, and a single mismatch silently yields garbage rather than an error. Treat that as a footgun, not a feature.

---

## 4. The LUKS on-disk format

LUKS solves the two things plain mode cannot: **key management** (multiple passphrases, rotation, revocation) and **self-description** (the parameters live with the data). It does so with one indirection: the data is encrypted with a randomly generated **master key**, and each passphrase merely unwraps a copy of that master key stored in a keyslot.

```
passphrase ──PBKDF(salt, cost)──► key encryption key ──decrypt──► keyslot ──AF-merge──► MASTER KEY
                                                                                          │
                                                                      dm-crypt table ◄────┘
```

Consequences to internalise:

- Changing a passphrase never touches the data. It rewraps one keyslot.
- Deleting a keyslot revokes that passphrase, not the data.
- **Anyone who ever had the master key retains access forever**, regardless of keyslot changes. Real revocation after master-key exposure requires reencryption ([§5.11](#511-master-key-rotation-reencryption)).
- Losing the header loses everything, even with a correct passphrase. Back the header up.

### 4.1 LUKS1 layout

```
offset 0      ┌──────────────────────────────────────────────┐
              │ magic "LUKS\xba\xbe", version=1              │
              │ cipher-name, cipher-mode, hash-spec          │
              │ payload-offset, key-bytes                    │
              │ mk-digest, mk-digest-salt, mk-digest-iter    │
              │ uuid                                         │
              │ keyslot[0..7]: active, iterations, salt,     │
              │                key-material-offset, stripes  │
       592 B  ├──────────────────────────────────────────────┤
              │ key material area 0  (AF-split master key)   │
              │ key material area 1                          │
              │ ... 8 slots ...                              │
   ~2 MiB     ├──────────────────────────────────────────────┤
              │ ENCRYPTED PAYLOAD                            │
              └──────────────────────────────────────────────┘
```

Fixed, big-endian, 8 keyslots, PBKDF2 only, no extensibility. Default payload offset 4096 sectors (2 MiB).

### 4.2 LUKS2 layout

```
offset 0        ┌───────────────────────────────────────────┐
                │ binary header (primary)          4096 B   │
                │ JSON metadata area (primary)    12288 B   │
offset 16384    ├───────────────────────────────────────────┤
                │ binary header (secondary)        4096 B   │  ← redundant copy
                │ JSON metadata area (secondary)  12288 B   │
offset 32768    ├───────────────────────────────────────────┤
                │ keyslots binary area (AF-split keys)      │
offset 16 MiB   ├───────────────────────────────────────────┤
                │ ENCRYPTED PAYLOAD (data segment 0)        │
                └───────────────────────────────────────────┘
```

The JSON area describes four object collections:

| Object | Purpose |
|---|---|
| `keyslots` | Passphrase-wrapped copies of the master key: PBKDF params, salt, AF stripes, area offset |
| `tokens` | *How to obtain* a passphrase without a human — `systemd-tpm2`, `systemd-fido2`, `systemd-recovery`, `clevis`, or arbitrary application tokens |
| `segments` | The encrypted regions: offset, size, cipher, sector size (multiple during online reencryption) |
| `digests` | Master-key verification digest, binding keyslots to segments |

Everything is checksummed (SHA-256 over the header), there are two copies, and `cryptsetup repair` can restore the primary from the secondary. That redundancy alone justifies LUKS2 for anything you cannot re-provision.

### 4.3 The anti-forensic (AF) splitter

A naïvely stored 512-bit wrapped key occupies 64 bytes. Overwriting 64 bytes on an SSD with wear levelling does **not** reliably destroy them — the FTL may have relocated the block. LUKS therefore expands each key to `stripes × key-size` bytes (default 4000 stripes ≈ 256 KiB) via a diffusion function such that **every single byte is required** to reconstruct the key. Destroying a keyslot means destroying 256 KiB, of which any surviving fragment is useless. This is why `luksKillSlot` is meaningful and why keyslot areas look large for what they hold.

### 4.4 Password-based key derivation

| | PBKDF2 (LUKS1 / LUKS2 optional) | Argon2i / **Argon2id** (LUKS2 default) |
|---|---|---|
| Standard | RFC 8018 | RFC 9106 |
| Cost dimensions | Iterations only | Iterations **× memory × parallelism** |
| GPU/ASIC resistance | Poor — trivially parallel | **Strong** — memory-hard |
| Default cost | ~2 s of iterations | ~2 s, up to 1 GiB RAM, 4 threads |
| Memory needed at unlock | Negligible | Up to 1 GiB — **must exist in the initramfs/bootloader** |
| GRUB support | Yes | **No** (GRUB 2.06/2.12 read LUKS2 with PBKDF2 only) |

**The production trap:** if `/boot` lives on the LUKS volume and GRUB must unlock it, Argon2 will not work. Either keep `/boot` unencrypted (with Secure Boot + signed kernels to mitigate), or create a dedicated GRUB keyslot with `--pbkdf pbkdf2`. Likewise, a node with 2 GiB of RAM whose header demands 1 GiB Argon2 memory may fail to unlock in a minimal initramfs — cap it with `--pbkdf-memory`.

### 4.5 LUKS1 vs LUKS2 decision table

| Feature | LUKS1 | LUKS2 |
|---|---|---|
| Header size / data offset | ~2 MiB | 16 MiB (configurable) |
| Header redundancy | None | Primary + secondary, checksummed |
| Keyslots | 8 | 32 |
| KDF | PBKDF2 | Argon2id (default), Argon2i, PBKDF2 |
| Tokens (TPM2/FIDO2/Tang/recovery) | No | **Yes** |
| Persistent performance flags | No | **Yes** (`--persistent`) |
| Authenticated encryption (`--integrity`) | No | **Yes** |
| Online reencryption | No | **Yes** (cryptsetup ≥ 2.4) |
| Detached header | Yes | Yes |
| GRUB can unlock | Yes | Only with PBKDF2 keyslot |
| Label / subsystem metadata | No | Yes |
| Sector size > 512 | No | Yes |
| Recommended for new deployments | Legacy/GRUB only | **Default** |

---

## 5. cryptsetup operational runbook

Version check first — feature availability differs sharply across 2.0 → 2.7:

```
$ cryptsetup --version
cryptsetup 2.7.5 flags: UDEV BLKID KEYRING KERNEL_CAPI HW_OPAL
```

`KEYRING` means master keys stay in the kernel keyring; `HW_OPAL` means `--hw-opal` (SED offload) is available.

### 5.1 Formatting a LUKS2 volume

```
$ sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --pbkdf argon2id \
    --pbkdf-memory 1048576 \
    --pbkdf-parallel 4 \
    --iter-time 5000 \
    --sector-size 4096 \
    --label pgdata-01 \
    --subsystem prod-db \
    --use-random \
    --verify-passphrase \
    /dev/nvme1n1

WARNING!
========
This will overwrite data on /dev/nvme1n1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme1n1:
Verify passphrase:
Key slot 0 created.
Command successful.
```

| Option | Why it is there |
|---|---|
| `--key-size 512` | AES-**256**-XTS (two 256-bit keys) |
| `--iter-time 5000` | 5 s KDF on *this* CPU. A slow node produces a weak header if you leave it at 2000 and the attacker has a fast machine |
| `--sector-size 4096` | Native NVMe block, fewer crypto ops |
| `--use-random` | Master key from `/dev/random`; `--use-urandom` avoids blocking on entropy-starved VMs at first boot |
| `--label` / `--subsystem` | Shows up in `lsblk -f` and `blkid` — invaluable in a 24-disk chassis |

> **Cost calibration must happen on the target hardware.** `--iter-time` is measured, not declared: the same flag yields 200k PBKDF2 iterations on a Xeon and 30k on an ARM edge node. Format on the node, or verify with `luksDump` afterwards.

Verify identification:

```
$ lsblk -f /dev/nvme1n1
NAME        FSTYPE      FSVER LABEL     UUID                                 MOUNTPOINTS
nvme1n1     crypto_LUKS 2     pgdata-01 9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
$ sudo blkid /dev/nvme1n1
/dev/nvme1n1: LABEL="pgdata-01" UUID="9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77" TYPE="crypto_LUKS"
```

### 5.2 Reading the header

```
$ sudo cryptsetup luksDump /dev/nvme1n1
LUKS header information
Version:        2
Epoch:          6
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
Label:          pgdata-01
Subsystem:      prod-db
Flags:          no-read-workqueue no-write-workqueue

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
        Time cost:  9
        Memory:     1048576
        Threads:    4
        Salt:       8b 21 ff 3c 7a 4d 90 e1 55 6c 02 b8 df 41 9a 33
                    c7 0e 6b 2f 18 ad 74 5e 93 c1 20 ef 8a 46 db 07
        AF stripes: 4000
        AF hash:    sha256
        Area offset:32768 [bytes]
        Area length:258048 [bytes]
        Digest ID:  0
  1: luks2
        Key:        512 bits
        Priority:   normal
        Cipher:     aes-xts-plain64
        Cipher key: 512 bits
        PBKDF:      pbkdf2
        Hash:       sha512
        Iterations: 1000
        Salt:       3d a9 74 12 ...
        AF stripes: 4000
        AF hash:    sha256
        Area offset:290816 [bytes]
        Area length:258048 [bytes]
        Digest ID:  0
Tokens:
  0: systemd-tpm2
  1: clevis
Digests:
  0: pbkdf2
        Hash:       sha256
        Iterations: 148824
        Salt:       f0 2c 8e ...
        Digest:     6a 91 c3 ...
```

Three things a reviewer should immediately check in this dump:

1. **Keyslot 1 uses PBKDF2 with 1000 iterations.** That is the signature of a *keyfile* slot added with `--pbkdf-force-iterations 1000` — legitimate for a 512-byte random keyfile (already full-entropy, stretching is pointless), catastrophic if that slot holds a human passphrase.
2. **Flags are persistent**, so every `open` will inherit the workqueue bypass.
3. **Two tokens** — TPM2 and Clevis — meaning two independent automated unlock paths exist.

### 5.3 Open, inspect, close

```
$ sudo cryptsetup open /dev/nvme1n1 pgdata
Enter passphrase for /dev/nvme1n1:

$ sudo cryptsetup status pgdata
/dev/mapper/pgdata is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: keyring
  integrity: (none)
  device:  /dev/nvme1n1
  sector size:  4096
  offset:  32768 sectors
  size:    7501344768 sectors
  mode:    read/write
  flags:   no_read_workqueue no_write_workqueue

$ sudo mkfs.xfs -L pgdata -f /dev/mapper/pgdata
meta-data=/dev/mapper/pgdata     isize=512    agcount=4, agsize=234417024 blks
         =                       sectsz=4096  attr=2, projid32bit=1
data     =                       bsize=4096   blocks=937668096, imaxpct=5
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=457846, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0

$ sudo mount /dev/mapper/pgdata /srv/pgdata
$ sudo umount /srv/pgdata && sudo cryptsetup close pgdata
```

`cryptsetup close` fails with `Device pgdata is still in use.` if anything holds it — including a stale LVM PV scan or a dm-snapshot. `lsof +D /srv/pgdata` and `dmsetup deps -o devname pgdata` find the holder.

### 5.4 Keyslot management

```
$ sudo cryptsetup luksAddKey /dev/nvme1n1
Enter any existing passphrase:
Enter new passphrase for key slot:
Verify passphrase:

$ sudo cryptsetup luksAddKey --key-slot 5 --key-file /root/keys/pgdata.key /dev/nvme1n1
Enter any existing passphrase:

$ sudo cryptsetup luksChangeKey --key-slot 0 /dev/nvme1n1
Enter passphrase to be changed:
Enter new passphrase:
Verify passphrase:

$ sudo cryptsetup luksKillSlot /dev/nvme1n1 5
Enter any remaining passphrase:
$ sudo cryptsetup luksDump /dev/nvme1n1 | grep -c '^  [0-9]*: luks2'
2
```

Test a passphrase without opening anything — the only safe way to validate a recovery credential:

```
$ sudo cryptsetup open --test-passphrase --key-slot 2 /dev/nvme1n1 && echo "slot 2 OK"
Enter passphrase for /dev/nvme1n1:
slot 2 OK
```

Keyslot priority (LUKS2) controls unlock order — put the automation slot first and the human slot last so unattended boots do not burn 5 s of Argon2 on the wrong slot:

```
$ sudo cryptsetup config --key-slot 1 --priority prefer /dev/nvme1n1
$ sudo cryptsetup config --key-slot 3 --priority ignore  /dev/nvme1n1   # only usable with --key-slot 3
```

The nuclear option — irreversible, wipes **all** keyslots:

```
$ sudo cryptsetup luksErase /dev/nvme1n1
WARNING!
========
This operation will erase all keyslots on device /dev/nvme1n1.
Device will become unusable after this operation.

Are you sure? (Type 'yes' in capital letters): YES
```

This is the correct decommissioning procedure for a drive you cannot physically destroy: with all keyslots gone, the master key is unrecoverable and the 3.5 TB of ciphertext is noise. It takes under a second, versus hours for `shred`. **Crypto-erase only works if you also destroy every header backup.**

### 5.5 Keyfiles

```
$ sudo install -d -m 0700 /etc/luks-keys
$ sudo dd if=/dev/urandom of=/etc/luks-keys/pgdata.key bs=512 count=8 status=none
$ sudo chmod 0400 /etc/luks-keys/pgdata.key
$ sudo cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    /dev/nvme1n1 /etc/luks-keys/pgdata.key
Enter any existing passphrase:
```

A 4096-bit random keyfile carries far more entropy than any passphrase, so forcing minimum PBKDF2 iterations is safe *and* shaves seconds off every boot. Never do this for a slot holding a human-chosen secret.

Partial keyfile reads matter when the key is embedded in a larger blob (a header sector, a hardware token dump):

```
$ sudo cryptsetup open --key-file /dev/sdc --keyfile-offset 4096 --keyfile-size 512 \
    /dev/nvme1n1 pgdata
```

Beware trailing newlines: `echo -n` vs `echo`, and `--keyfile-size` to bound the read. A keyfile generated with `echo "secret" > key` includes `\n` and will not match a slot created from `printf 'secret'`.

### 5.6 Header backup — the step people skip

Sixteen mebibytes stand between you and total loss.

```
$ sudo cryptsetup luksHeaderBackup /dev/nvme1n1 \
    --header-backup-file /root/luks-headers/pgdata-01.$(hostname -s).img
$ sudo chmod 0400 /root/luks-headers/pgdata-01.*.img
$ ls -l /root/luks-headers/
-r--------. 1 root root 16777216 Aug 20 09:14 pgdata-01.k8s-worker-07.img
```

The backup **contains all keyslots as they were at backup time.** If you revoke a passphrase and someone still holds the old header image, they can restore it and regain access. Header backups therefore inherit the sensitivity of the passphrases they encode — encrypt them, version them, and rotate them alongside key changes.

Restore:

```
$ sudo cryptsetup luksHeaderRestore /dev/nvme1n1 \
    --header-backup-file /root/luks-headers/pgdata-01.k8s-worker-07.img

WARNING!
========
Device /dev/nvme1n1 already contains LUKS2 header. Replacing header will destroy existing keyslots.

Are you sure? (Type 'yes' in capital letters): YES
```

**Detached headers** put the header on separate media entirely — the data device then looks like random noise with no LUKS signature at all:

```
$ sudo cryptsetup luksFormat --type luks2 --header /root/hdr/vault.hdr /dev/sdb1
$ sudo cryptsetup open --header /root/hdr/vault.hdr /dev/sdb1 vault
```

Operationally this is a two-part key: losing the header file is losing the data. Used for deniability, for keeping headers on a smartcard, and for volumes whose backing storage is untrusted (an iSCSI LUN from another team).

### 5.7 Suspend and resume

`luksSuspend` freezes all I/O to the mapping and **wipes the master key from kernel memory**, which is what you want before closing a laptop lid or before a physical technician touches a running rack:

```
$ sudo cryptsetup luksSuspend pgdata
$ sudo cryptsetup status pgdata
/dev/mapper/pgdata is active and is suspended.
  type:    LUKS2
  ...
$ sudo cryptsetup luksResume pgdata
Enter passphrase for /dev/nvme1n1:
```

Any process touching the filesystem blocks in uninterruptible sleep until resume. Never suspend the volume holding `/` from a shell whose binaries live on it — `cryptsetup` itself must already be in page cache or you deadlock the machine. Distributions solve this with a dedicated pre-suspend service that pins the needed binaries.

### 5.8 Resizing

Grow the backing device first, then the mapping, then the filesystem:

```
$ sudo lvextend -L +500G /dev/vg0/data
  Size of logical volume vg0/data changed from 1.00 TiB (262144 extents) to 1.49 TiB (390144 extents).
  Logical volume vg0/data successfully resized.
$ sudo cryptsetup resize data
$ sudo cryptsetup status data | grep size
  sector size:  4096
  size:    3196059648 sectors
$ sudo xfs_growfs /srv/data
```

With a kernel-keyring master key, `cryptsetup resize` needs no passphrase. Without keyring support (or with `--disable-keyring`), it prompts — which is a nasty surprise in an automated expansion pipeline. Test the path.

### 5.9 Converting LUKS1 → LUKS2

```
$ sudo cryptsetup convert --type luks2 /dev/sdb1
WARNING!
========
This operation will convert /dev/sdb1 to LUKS2 format.

Are you sure? (Type 'yes' in capital letters): YES
$ sudo cryptsetup luksConvertKey --pbkdf argon2id --key-slot 0 /dev/sdb1
Enter passphrase for keyslot to be converted:
```

Conversion is **in-place and metadata-only** — the data offset does not change, so the new LUKS2 header must fit in the old LUKS1 header space (2 MiB). That means the resulting header has a smaller keyslots area than a fresh LUKS2 format. Convert with the device closed, and back the header up *before* converting; conversion is not atomic on a device that loses power mid-write. Keyslots stay PBKDF2 until you convert each one.

### 5.10 In-place encryption of an existing filesystem

LUKS2 can encrypt a populated device that was never encrypted, by shrinking the data area to make room for the header:

```
$ sudo umount /srv/archive
$ sudo e2fsck -f /dev/vg0/archive
$ sudo resize2fs /dev/vg0/archive 900G       # leave headroom
$ sudo cryptsetup reencrypt --encrypt --reduce-device-size 32M \
    --type luks2 --resilience checksum /dev/vg0/archive
Enter new passphrase:
Verify passphrase:
Finished, time 41m18s,  931 GiB written, speed 384.9 MiB/s
```

`--reduce-device-size 32M` sacrifices the last 32 MiB of the device for the header. The alternative is `--header /path/to/detached.hdr`, which keeps the full data area at the cost of a detached header.

`--resilience` selects the crash-recovery strategy:

| Mode | Behaviour | Cost |
|---|---|---|
| `checksum` (default) | Per-block checksums in the header; resumes exactly | Moderate |
| `journal` | Full journal of the hot zone | Slowest, safest |
| `none` | No recovery data | Fastest, **data loss on crash** |
| `datashift` | For `--encrypt`/`--decrypt` with device shift | Automatic |

If the process is interrupted, re-running the same command resumes:

```
$ sudo cryptsetup reencrypt --resume-only /dev/vg0/archive
Enter passphrase for /dev/vg0/archive:
Finished, time 12m03s,  268 GiB written, speed 379.4 MiB/s
```

### 5.11 Master key rotation (reencryption)

The only true remediation after suspected master-key exposure:

```
$ sudo cryptsetup reencrypt /dev/nvme1n1
Enter passphrase for key slot 0:
Progress:  63.4%, ETA 00:22, 2.2 TiB written, speed 402.1 MiB/s
```

Online reencryption (LUKS2, cryptsetup ≥ 2.4) works on a **mounted, active** device:

```
$ sudo cryptsetup reencrypt --active-name pgdata --resilience checksum /dev/nvme1n1
```

Throughput of the workload degrades roughly 30–50% for the duration. For a 3.5 TB NVMe at ~400 MiB/s, budget ~2.5 hours. Plan it as a maintenance window; do not "just kick it off." Reencryption is **not supported on volumes with `--integrity`** — those must be recreated and restored from backup.

---

## 6. Integrity: dm-integrity and authenticated encryption

### 6.1 Why plain LUKS is not enough for a hostile storage backend

XTS is malleable per 16-byte block. Flip a ciphertext bit and the corresponding plaintext block becomes pseudorandom garbage — but the read *succeeds*. The filesystem then interprets garbage as metadata. For a database on a SAN whose administrator you do not fully trust, or for a volume replicated across a network you do not control, this is a real attack surface: an adversary who cannot read your data can still corrupt it in targeted, silent ways.

`dm-integrity` sits **below** dm-crypt and stores a per-sector authentication tag in interleaved metadata, turning the stack into authenticated encryption.

```
    filesystem
        │
   /dev/mapper/vault          ← dm-crypt (aes-gcm-random or aes-xts + hmac)
        │
   /dev/mapper/vault_dif      ← dm-integrity (tag storage + journal)
        │
   /dev/nvme2n1
```

### 6.2 Creating an integrity-protected LUKS2 volume

Two constructions:

```
# A) AEAD: AES-GCM with random IVs stored by dm-integrity
$ sudo cryptsetup luksFormat --type luks2 \
    --cipher aes-gcm-random --integrity aead \
    --key-size 256 --sector-size 4096 /dev/nvme2n1

# B) Encrypt-then-MAC: XTS for confidentiality + HMAC-SHA256 for integrity
$ sudo cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --integrity hmac-sha256 \
    --key-size 512 --sector-size 4096 /dev/nvme2n1

WARNING!
========
This will overwrite data on /dev/nvme2n1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme2n1:
Verify passphrase:
Wiping device to initialize integrity checksum.
You can interrupt this by pressing CTRL+c (rest of not wiped device will contain invalid checksum).
Finished, time 28m41s, 3.4 TiB written, speed 2074.3 MiB/s
Key slot 0 created.
Command successful.
```

The wipe is mandatory: every sector must carry a valid tag before it can be read, otherwise the first read of untouched space returns an integrity failure. `--integrity-no-wipe` skips it — only appropriate if you will overwrite the whole device immediately (e.g. `mkfs` plus a full restore), and it will produce alarming errors in the interim.

```
$ sudo cryptsetup open /dev/nvme2n1 vault
$ sudo cryptsetup status vault
/dev/mapper/vault is active.
  type:    LUKS2
  cipher:  aes-gcm-random
  keysize: 256 bits
  key location: keyring
  integrity: aead
  integrity keysize: 0 bits
  device:  /dev/nvme2n1
  sector size:  4096
  offset:  0 sectors
  size:    6811648000 sectors
  mode:    read/write
$ lsblk /dev/nvme2n1
NAME             MAJ:MIN RM  SIZE RO TYPE  MOUNTPOINTS
nvme2n1          259:2    0  3.5T  0 disk
└─vault_dif      253:4    0  3.4T  0 crypt
  └─vault        253:5    0  3.4T  0 crypt
```

Note the **two** stacked mappings and the shrunk usable capacity.

### 6.3 Standalone dm-integrity (no encryption)

Useful when confidentiality is handled elsewhere but you want bit-rot detection under a filesystem that lacks checksums:

```
$ sudo integritysetup format --integrity sha256 --tag-size 32 --sector-size 4096 /dev/sdd1
$ sudo integritysetup open --integrity sha256 /dev/sdd1 datadif
$ sudo integritysetup status datadif
/dev/mapper/datadif is active.
  type:    INTEGRITY
  tag size: 32 [bytes]
  integrity: sha256
  device:  /dev/sdd1
  sector size:  4096 [bytes]
  interleave sectors: 32768
  size:    1917186048 sectors
  mode:    read/write
  failures: 0
  journal size: 66584576 [bytes]
  journal watermark: 50%
  journal commit time: 10000 ms
```

`failures:` is the counter to scrape into Prometheus.

### 6.4 The cost

| Configuration | Usable capacity | Random 4K write IOPS (rel.) | Sequential write (rel.) | Detects tampering |
|---|---|---|---|---|
| Plain XFS | 100% | 1.00 | 1.00 | No |
| LUKS2 aes-xts | ~100% | 0.94 | 0.96 | No |
| LUKS2 aes-xts + hmac-sha256, journalled | ~93% | **0.42** | 0.51 | Yes |
| LUKS2 aes-gcm-random (AEAD), journalled | ~94% | 0.48 | 0.55 | Yes |
| LUKS2 + integrity, `--integrity-no-journal` | ~94% | 0.78 | 0.86 | Yes (but see below) |

*(Indicative figures from a Gen4 NVMe with AES-NI; measure on your own hardware — the ratios move a lot with queue depth and sector size.)*

The journal is what makes integrity **crash-safe**: tag and data must be updated atomically, so dm-integrity writes both to a journal first — every write happens twice. `--integrity-no-journal` removes that and roughly doubles write throughput, at the price that a power loss mid-write can leave a sector whose data and tag disagree, which then reads as tampering. Use it only where the whole device can be rebuilt from a replica.

**Restrictions to design around:** no reencryption, no resize, no LUKS1, and hibernation/`resume=` on an integrity volume is unsupported.

### 6.5 What a real integrity failure looks like

```
$ sudo dd if=/dev/urandom of=/dev/nvme2n1 bs=4096 count=1 seek=2000000 conv=notrunc
$ sudo dd if=/dev/mapper/vault of=/dev/null bs=4096 count=1 skip=1999000
dd: error reading '/dev/mapper/vault': Input/output error
0+0 records in
0+0 records out

$ sudo dmesg | tail -4
[ 9481.220371] device-mapper: integrity: dm-4: Checksum failed at sector 0x1e8480
[ 9481.220389] blk_update_request: I/O error, dev dm-4, sector 15992832 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0
[ 9481.220401] XFS (dm-5): metadata I/O error in "xfs_read_agf+0x9d/0x140" at daddr 0x1e8480 len 8 error 5
```

The critical property: the read **fails** rather than returning garbage. That is the entire point.

---

## 7. Unlocking at boot: crypttab, systemd and the initramfs

### 7.1 `/etc/crypttab` syntax

Four whitespace-separated fields:

```
<target name>   <source device>   <key file>   <options>
```

| Field | Rules |
|---|---|
| target name | Becomes `/dev/mapper/<name>`. Referenced by `/etc/fstab`. |
| source device | Use `UUID=` or `/dev/disk/by-id/` — **never** `/dev/sdb1`, which is not stable across boots |
| key file | Path, or `none`/`-` to prompt, or `/dev/urandom` for random-key volumes |
| options | Comma-separated; see below |

Key options (systemd `crypttab(5)`):

| Option | Meaning |
|---|---|
| `luks` | Force LUKS (autodetected otherwise) |
| `plain` | Plain dm-crypt; then `cipher=`, `size=`, `hash=`, `offset=`, `skip=` are mandatory |
| `swap` | Format as swap after unlocking. **Refuses to run if the device holds a filesystem signature** — a critical safety valve |
| `tmp[=fstype]` | mkfs on every boot |
| `discard` | Pass TRIM (see [§3.4](#34-the-workqueue-problem-a-real-production-win) warning) |
| `noauto` | Do not unlock at boot |
| `nofail` | Boot proceeds if the device is missing |
| `timeout=`, `tries=` | Password prompt behaviour; `tries=0` = infinite |
| `keyfile-size=`, `keyfile-offset=` | Partial keyfile read |
| `header=` | Detached header path |
| `key-slot=` | Try only this slot (faster boot) |
| `tpm2-device=auto` | Unlock via TPM2 token |
| `tpm2-pcrs=`, `tpm2-pin=` | TPM2 policy binding / require a PIN |
| `fido2-device=auto` | Unlock via FIDO2 token |
| `no-read-workqueue`, `no-write-workqueue`, `same-cpu-crypt`, `high-priority` | Performance flags |
| `sector-size=` | Plain-mode sector size |
| `x-systemd.device-timeout=` | How long to wait for the backing device |
| `initramfs` | **Debian-specific**: include this entry in the initramfs |
| `keyscript=` | **Debian-specific**: run a script to obtain the key (ignored by systemd) |

### 7.2 A complete production crypttab

```
# /etc/crypttab
# <name>     <device>                                              <keyfile>            <options>

# Root volume: TPM2-sealed, PIN fallback, recovery key in the safe.
cryptroot    UUID=1c4a90f2-7ee1-4b3a-8b0f-6dd4a2c5c101              none                 luks,discard,tpm2-device=auto,tpm2-pcrs=7+14,tries=3,x-systemd.device-timeout=30s

# Container runtime scratch: keyfile on the (already unlocked) root FS.
cryptcontainerd UUID=a1b2c3d4-1111-4222-8333-444455556666           /etc/luks-keys/containerd.key  luks,discard,no-read-workqueue,no-write-workqueue,nofail,x-systemd.device-timeout=15s

# Database volume: network-bound (Clevis/Tang) via its own systemd unit; no boot prompt.
cryptpgdata  UUID=9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77              none                 luks,noauto,no-read-workqueue,no-write-workqueue,nofail

# Encrypted swap with an ephemeral random key. Hibernation is DISABLED on this fleet.
cryptswap    /dev/disk/by-id/nvme-SAMSUNG_MZQL23T8HCLS_S64GNE0T123456-part3  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096,hash=sha256
```

And the matching `/etc/fstab`:

```
# /etc/fstab
UUID=8e2a1b30-93b7-4e5b-9a1f-0d4c72f3a9b1  /            xfs   defaults,noatime                  0 1
UUID=f4c1-9A2B                             /boot/efi    vfat  umask=0077,shortname=winnt        0 2
UUID=3b7e2f11-64ac-4d9e-b0e4-77c1a2f5e8d0  /boot        ext4  defaults                          0 2
/dev/mapper/cryptcontainerd                /var/lib/containerd xfs defaults,noatime,nofail,x-systemd.requires=/dev/mapper/cryptcontainerd  0 2
/dev/mapper/cryptpgdata                    /srv/pgdata  xfs   defaults,noatime,noauto,x-systemd.requires=/dev/mapper/cryptpgdata           0 2
/dev/mapper/cryptswap                      none         swap  sw                                0 0
```

### 7.3 How systemd turns that into units

`systemd-cryptsetup-generator` runs at early boot and synthesises one `systemd-cryptsetup@<name>.service` per crypttab line:

```
$ systemctl list-units 'systemd-cryptsetup@*'
  UNIT                                LOAD   ACTIVE SUB    DESCRIPTION
  systemd-cryptsetup@cryptcontainerd.service loaded active exited Cryptography Setup for cryptcontainerd
  systemd-cryptsetup@cryptroot.service       loaded active exited Cryptography Setup for cryptroot
  systemd-cryptsetup@cryptswap.service       loaded active exited Cryptography Setup for cryptswap

$ systemctl cat systemd-cryptsetup@cryptcontainerd.service | head -20
# /run/systemd/generator/systemd-cryptsetup@cryptcontainerd.service
[Unit]
Description=Cryptography Setup for cryptcontainerd
Documentation=man:crypttab(5) man:systemd-cryptsetup-generator(8) man:systemd-cryptsetup@.service(8)
SourcePath=/etc/crypttab
DefaultDependencies=no
IgnoreOnIsolate=true
After=cryptsetup-pre.target systemd-udevd-kernel.socket
Before=blockdev@dev-mapper-cryptcontainerd.target
Wants=blockdev@dev-mapper-cryptcontainerd.target
Conflicts=umount.target
Before=cryptsetup.target umount.target
RequiresMountsFor=/etc/luks-keys/containerd.key
BindsTo=dev-disk-by\x2duuid-a1b2c3d4...device
After=dev-disk-by\x2duuid-a1b2c3d4...device

$ systemctl status systemd-cryptsetup@cryptroot.service --no-pager
● systemd-cryptsetup@cryptroot.service - Cryptography Setup for cryptroot
     Loaded: loaded (/etc/crypttab; generated)
     Active: active (exited) since Thu 2026-08-20 08:41:02 UTC; 3h 12min ago
   Main PID: 412 (code=exited, status=0/SUCCESS)
        CPU: 1.284s

Aug 20 08:41:01 k8s-worker-07 systemd-cryptsetup[412]: Set cipher aes, mode xts-plain64, key size 512 bits for device /dev/disk/by-uuid/1c4a90f2-...
Aug 20 08:41:02 k8s-worker-07 systemd-cryptsetup[412]: Unlocked volume cryptroot with TPM2 token.
```

Kernel command line equivalents (dracut/systemd), for cases where crypttab is not yet readable — i.e. the root device itself:

```
rd.luks.uuid=luks-1c4a90f2-7ee1-4b3a-8b0f-6dd4a2c5c101
rd.luks.name=1c4a90f2-...=cryptroot
rd.luks.options=discard,tpm2-device=auto
rd.luks.key=/etc/luks-keys/root.key:UUID=abcd-1234
```

### 7.4 The initramfs

The root filesystem's unlock code must exist *before* the root filesystem does.

```
# Debian/Ubuntu
$ sudo apt-get install -y cryptsetup-initramfs
$ sudo update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.8.0-45-generic
cryptsetup: WARNING: Resume target cryptswap uses a random key ...
$ lsinitramfs /boot/initrd.img-6.8.0-45-generic | grep -E 'cryptsetup|crypttab|dm-crypt'
cryptroot/crypttab
sbin/cryptsetup
usr/lib/modules/6.8.0-45-generic/kernel/drivers/md/dm-crypt.ko

# Fedora/RHEL
$ sudo dracut --force --verbose 2>&1 | grep -iE 'crypt|tpm'
dracut: *** Including module: crypt ***
dracut: *** Including module: tpm2-tss ***
$ sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'cryptsetup$|crypttab'
```

If a keyfile is embedded in the initramfs, the initramfs itself becomes secret material — on Debian, `UMASK=0077` in `/etc/initramfs-tools/initramfs.conf` is essential, otherwise `/boot/initrd.img-*` is world-readable and so is your key.

### 7.5 `systemd-cryptenroll`: TPM2, FIDO2, recovery keys

This is the modern unattended-unlock path, and it is explicitly in the exam's terms list.

```
# Enrol a TPM2-sealed key bound to Secure Boot state (PCR 7) and the initrd (PCR 14)
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7+14
🔐 Please enter current passphrase for disk /dev/nvme0n1p3:
New TPM2 token enrolled as key slot 2.

# Require a PIN in addition to the TPM measurement (defeats a stolen powered-off machine)
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes

# Enrol a hardware token
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --fido2-device=auto
Initializing FIDO2 credential on security token.
👆 (Hint: This might require confirmation of user presence on the security token.)
New FIDO2 token enrolled as key slot 3.

# Generate a printable recovery key — do this BEFORE you need it
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --recovery-key
🔐 Please enter current passphrase for disk /dev/nvme0n1p3:
A secret recovery key has been generated for this volume:

    dcefbg-hcvhue-lgjnkd-cnbtvr-eugvfj-hgtylk-nbvcxz-qwerty

Please save this secret recovery key at a secure location.
New recovery key enrolled as key slot 4.

# List and revoke
$ sudo systemd-cryptenroll /dev/nvme0n1p3
SLOT TYPE
   0 password
   2 tpm2
   3 fido2
   4 recovery
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --wipe-slot=tpm2
```

The tokens are stored in the LUKS2 JSON header:

```
$ sudo cryptsetup luksDump /dev/nvme0n1p3 | sed -n '/^Tokens:/,/^Digests:/p'
Tokens:
  0: systemd-tpm2
        Keyslot:    2
  1: systemd-fido2
        Keyslot:    3
  2: systemd-recovery
        Keyslot:    4
Digests:
```

**PCR selection is an availability decision, not a security one.** Bind too tightly and routine maintenance bricks the fleet:

| PCR | Measures | Breaks on |
|---|---|---|
| 0 | Firmware code | **Any BIOS/UEFI update** |
| 1 | Firmware configuration | Any BIOS setting change, RAM change |
| 4 | Boot loader / boot manager | Bootloader update |
| 7 | Secure Boot state & keys | Enrolling/withdrawing SB keys, some vendor cert updates |
| 8–9 | GRUB command line / files | Any kernel parameter change |
| 11 | UKI (systemd-stub) measurements | Kernel/initrd update (unless signed policy is used) |
| 14 | MOK/shim certificates | Shim or MOK changes |

**The recommended fleet policy is PCR 7 (+14) plus a mandatory enrolled recovery key**, and a documented runbook step: *before any firmware update, verify the recovery key works; after the update, re-enrol the TPM2 slot.* Binding to PCR 0 across a hardware fleet has taken more than one platform team offline for a full day.

### 7.6 Encrypted swap and the hibernation trap

Swap holds pages evicted from RAM: session keys, decrypted secrets, plaintext database rows. Encrypting it is not optional.

**Random-key swap** (from the crypttab above) is the cleanest option — a fresh key from `/dev/urandom` every boot, nothing to manage, nothing to leak:

```
$ sudo cryptsetup status cryptswap
/dev/mapper/cryptswap is active and is in use.
  type:    PLAIN
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: dm-crypt
  device:  /dev/nvme0n1p3
  sector size:  4096
  offset:  0 sectors
  size:    134217728 sectors
  mode:    read/write
$ swapon --show
NAME                TYPE      SIZE USED PRIO
/dev/mapper/cryptswap partition  64G   0B   -2
```

**It destroys hibernation.** Resume-from-disk requires reading back a swap image written before the reboot; a key that no longer exists makes that impossible. For laptops that must hibernate:

- Put swap inside the LUKS-encrypted LVM volume group, alongside root.
- Set `resume=/dev/mapper/vg0-swap` on the kernel command line and in `/etc/initramfs-tools/conf.d/resume` (Debian) or the dracut `resume` module.
- Accept that the hibernation image is protected by the *root* volume key.

The `swap` crypttab option includes a safety check: `systemd-cryptsetup` refuses to `mkswap` a device that carries a filesystem or partition signature. Bypassing it by pointing the entry at the wrong `/dev/sdX` and forcing it is one of the fastest known ways to destroy a production volume — which is precisely why the crypttab entry above uses `/dev/disk/by-id/`.

### 7.7 Network-Bound Disk Encryption (Clevis + Tang)

TPM2 answers "is this the same machine?"; Tang answers "is this machine on our network?" — which is the better question for a datacenter, because a stolen server plugged in elsewhere simply will not unlock.

```
$ sudo dnf install -y clevis clevis-luks clevis-dracut
$ sudo clevis luks bind -d /dev/nvme1n1 tang '{"url":"https://tang.infra.svc.cluster.local"}'
The advertisement contains the following signing keys:

    kWwirxc5PgOKB1cMlwZWRgOa1Aw

Do you wish to trust these keys? [ynYN] y
Enter existing LUKS password:
$ sudo clevis luks list -d /dev/nvme1n1
1: tang '{"url":"https://tang.infra.svc.cluster.local"}'
$ sudo systemctl enable clevis-luks-askpass.path
$ sudo dracut -f
```

Redundancy via Shamir Secret Sharing — unlock if any 2 of 3 servers answer, so one Tang outage is not a fleet outage:

```
$ sudo clevis luks bind -d /dev/nvme1n1 sss '{
  "t": 2,
  "pins": {
    "tang": [
      {"url": "https://tang-a.infra.example.net"},
      {"url": "https://tang-b.infra.example.net"}
    ],
    "tpm2": {"pcr_bank":"sha256","pcr_ids":"7"}
  }
}'
```

---

## 8. eCryptfs: stacked per-file encryption

### 8.1 Architecture

eCryptfs is a **stacked cryptographic filesystem**: it mounts on top of an existing directory in an existing filesystem and encrypts each file individually, storing the ciphertext as an ordinary file in the lower filesystem. It is implemented in the kernel (`fs/ecryptfs`) but driven from userspace via the kernel keyring.

Key hierarchy — this is the part exams and interviews probe:

```
passphrase ──(salt, 65536 SHA-512 iterations)──► FEKEK   (File Encryption Key Encryption Key)
                                                    │
                                                    │ wraps
                                                    ▼
per-file random FEK  ──stored, wrapped, in the file's own 8 KiB header──► file contents
                                                                          (AES-CBC, per-extent IV)

FNEK (FileName Encryption Key)  ──► encrypted, base64-ish file names prefixed ECRYPTFS_FNEK_ENCRYPTED.
```

Every file gets its **own** random FEK. Copying a ciphertext file to another eCryptfs mount with the same FEKEK works; the metadata travels with the file. That is eCryptfs's genuine architectural advantage over dm-crypt: the unit of encryption is the file, so it survives `rsync`, backup to an untrusted target, and per-user key separation on shared storage.

The header costs 8 KiB per file. A directory of a million 1 KiB files consumes ~9 GB instead of ~1 GB. eCryptfs is a poor fit for maildir-style workloads.

### 8.2 Manual mount

```
$ sudo mkdir -p /srv/secret.raw /srv/secret
$ sudo mount -t ecryptfs /srv/secret.raw /srv/secret
Select key type to use for newly created files:
 1) tspi
 2) passphrase
Selection: 2
Passphrase:
Select cipher:
 1) aes: blocksize = 16; min keysize = 16; max keysize = 32
 2) blowfish: blocksize = 8; min keysize = 16; max keysize = 56
 3) des3_ede: blocksize = 8; min keysize = 24; max keysize = 24
 4) twofish: blocksize = 16; min keysize = 16; max keysize = 32
 5) cast6: blocksize = 16; min keysize = 16; max keysize = 32
 6) cast5: blocksize = 8; min keysize = 5; max keysize = 16
Selection [aes]: 1
Select key bytes:
 1) 16
 2) 32
 3) 24
Selection [16]: 2
Enable plaintext passthrough (y/n) [n]: n
Enable filename encryption (y/n) [n]: y
Filename Encryption Key (FNEK) Signature [c9a3f21b7e4d5068]:
Attempting to mount with the following options:
  ecryptfs_unlink_sigs
  ecryptfs_fnek_sig=c9a3f21b7e4d5068
  ecryptfs_key_bytes=32
  ecryptfs_cipher=aes
  ecryptfs_sig=c9a3f21b7e4d5068
Mounted eCryptfs
```

Non-interactive form, suitable for automation:

```
$ sudo mount -t ecryptfs /srv/secret.raw /srv/secret \
  -o key=passphrase:passphrase_passwd_file=/root/.ecryptfs.pw,\
ecryptfs_cipher=aes,\
ecryptfs_key_bytes=32,\
ecryptfs_passthrough=no,\
ecryptfs_enable_filename_crypto=yes,\
ecryptfs_fnek_sig=c9a3f21b7e4d5068,\
ecryptfs_sig=c9a3f21b7e4d5068,\
ecryptfs_unlink_sigs
```

Prove the ciphertext is real:

```
$ echo "postgres superuser password: hunter2" | sudo tee /srv/secret/creds.txt >/dev/null
$ ls -la /srv/secret.raw/
total 24
drwx------. 2 root root  4096 Aug 20 11:02 .
drwxr-xr-x. 4 root root  4096 Aug 20 10:58 ..
-rw-r--r--. 1 root root 12288 Aug 20 11:02 ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--

$ sudo xxd -l 32 '/srv/secret.raw/ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--'
00000000: 0000 0000 0000 0027 3c81 b7f5 0300 0000  .......'<.......
00000010: 0000 2000 0000 0000 0000 0000 0000 0000  .. .............
```

Bytes 0–7 are the plaintext size (0x27 = 39 bytes), bytes 8–11 are the eCryptfs magic marker `0x3c81b7f5`, byte 12 is the format version. Note the file size leaks in the clear — one of eCryptfs's structural weaknesses.

```
$ sudo ecryptfs-stat '/srv/secret.raw/ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--'
Version: 3
Original filesize: 39
Number of header extents at front: 2
Block size: 4096
Number of extents per page: 1
Header extent size: 8192
Flags:
        SHA-2 512 metadata
        Encrypted with a passphrase
```

Keyring state — if the key is not in the keyring, the mount cannot work:

```
$ keyctl list @u
2 keys in keyring:
 419237845: --alswrv     0     0 user: c9a3f21b7e4d5068
 731092447: --alswrv     0     0 user: 4e8b17d0a2c6f395
$ sudo umount /srv/secret
$ sudo keyctl clear @u     # ecryptfs_unlink_sigs does this at unmount
```

### 8.3 Encrypted home directories and PAM

The canonical deployment: `~/.Private` holds ciphertext, `~/Private` (or the whole `$HOME`) is the plaintext view, and PAM unwraps the key with the **login password** at authentication time.

```
$ sudo apt-get install -y ecryptfs-utils
$ ecryptfs-setup-private
Enter your login passphrase [alice]:
Enter your mount passphrase [leave blank to generate one]:

************************************************************************
YOU SHOULD RECORD YOUR MOUNT PASSPHRASE AND STORE IT IN A SAFE LOCATION.
  ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase
THIS WILL BE REQUIRED IF YOU NEED TO RECOVER YOUR DATA AT A LATER TIME.
************************************************************************

Done configuring.
Testing mount/write/umount/read...
Testing succeeded.

$ ls -la ~/.ecryptfs/
-rw-------. 1 alice alice  17 Aug 20 11:20 auto-mount
-rw-------. 1 alice alice  17 Aug 20 11:20 auto-umount
lrwxrwxrwx. 1 alice alice  30 Aug 20 11:20 Private.mnt -> /home/alice/Private
lrwxrwxrwx. 1 alice alice  33 Aug 20 11:20 Private.sig
-rw-------. 1 alice alice  88 Aug 20 11:20 wrapped-passphrase
```

| File | Role |
|---|---|
| `wrapped-passphrase` | The mount passphrase (FEKEK), wrapped with the **login** passphrase |
| `Private.sig` | FEKEK and FNEK signatures — two lines when filename encryption is on |
| `Private.mnt` | Where to mount the plaintext view |
| `auto-mount` / `auto-umount` | Flags consumed by `pam_ecryptfs` |

The two-layer wrapping is what makes PAM integration possible **and** what creates its central operational hazard: change the login password out-of-band (`passwd` as root, an LDAP-side reset, an IdP sync) and the wrapped passphrase can no longer be unwrapped. The data is intact and permanently unreachable unless the *mount* passphrase was recorded:

```
$ ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase
Passphrase:
b3a91f7c4d2e8065a1c7f39e5b204d8c

$ ecryptfs-rewrap-passphrase ~/.ecryptfs/wrapped-passphrase
Old wrapping passphrase:
New wrapping passphrase:
Again:
```

PAM stack (Debian `/etc/pam.d/common-auth` and `common-session`; the `ecryptfs-utils` package installs this automatically):

```
# /etc/pam.d/common-auth
auth     required   pam_ecryptfs.so unwrap
auth     [success=1 default=ignore]  pam_unix.so nullok try_first_pass

# /etc/pam.d/common-session
session  optional   pam_ecryptfs.so unwrap

# /etc/pam.d/common-password  (keeps the wrapped passphrase in sync on password change)
password optional   pam_ecryptfs.so
```

Ordering matters: `pam_ecryptfs.so unwrap` must run in a context where the password is still available to PAM, which is why it sits *before* `pam_unix.so` in the auth stack with `try_first_pass` downstream.

Per-user manual control:

```
$ ecryptfs-mount-private
Enter your login passphrase:
INFO: Your private directory has been mounted.
INFO: To see this change in your current shell:
  cd /home/alice/Private
$ mount | grep ecryptfs
/home/alice/.Private on /home/alice/Private type ecryptfs (rw,nosuid,nodev,relatime,ecryptfs_fnek_sig=4e8b17d0a2c6f395,ecryptfs_sig=c9a3f21b7e4d5068,ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_unlink_sigs)
$ ecryptfs-umount-private
```

Migrating an existing home directory (destructive — take a backup, and read the warnings it prints):

```
$ sudo ecryptfs-migrate-home -u alice
INFO:  Checking disk space, this may take a few moments.  Please be patient.
INFO:  Checking for open files in /home/alice
Enter your login passphrase [alice]:
INFO:  Encrypted home has been set up, encrypting files now...this may take a while.
...
********************************************************************************
Some Important Notes!
 1. The file encryption appears to have completed successfully, however,
    alice MUST LOGIN IMMEDIATELY, _BEFORE_THE_NEXT_REBOOT_,
    TO COMPLETE THE MIGRATION!!!
 2. If alice can log in and read and write their files, then the migration is complete,
    and you should remove /home/alice.iCwWFO.
 3. alice should also run 'ecryptfs-unwrap-passphrase' and record the mount passphrase.
********************************************************************************
```

Administrative recovery when a user is gone but the data must be retrieved:

```
$ sudo ecryptfs-recover-private /home/.ecryptfs/alice/.Private
INFO: Found [/home/.ecryptfs/alice/.Private].
Try to recover this directory? [Y/n]: Y
INFO: Found your wrapped-passphrase
Do you know your LOGIN passphrase? [Y/n]: Y
INFO: Enter your LOGIN passphrase...
Passphrase:
Inserted auth tok with sig [c9a3f21b7e4d5068] into the user session keyring
INFO: Success!  Private data mounted at [/tmp/ecryptfs.7dK2xQ].
```

### 8.4 Mount option reference

| Option | Meaning |
|---|---|
| `ecryptfs_sig=<sig>` | FEKEK signature (from the keyring) |
| `ecryptfs_fnek_sig=<sig>` | FNEK signature; enables filename encryption |
| `ecryptfs_cipher=aes` | Content cipher |
| `ecryptfs_key_bytes=16\|24\|32` | Key length in bytes (16 = AES-128) |
| `ecryptfs_passthrough=y` | Allow reading non-eCryptfs files in the lower dir unmodified |
| `ecryptfs_encrypted_view` | Present the *ciphertext* through the mount (for backup tools) |
| `ecryptfs_xattr_metadata` | Store the per-file header in an xattr instead of inline |
| `ecryptfs_unlink_sigs` | Remove keys from the keyring on unmount |
| `no_sig_cache` | Do not prompt about unknown signatures |
| `key=passphrase:passphrase_passwd_file=<f>` | Non-interactive key source |

### 8.5 Honest assessment for production

| Aspect | Verdict |
|---|---|
| Per-user key separation on shared storage | Its reason to exist; nothing at the block layer can do this |
| Works over NFS | Historically the selling point; in practice fragile with modern NFSv4 caching |
| Filename length | With filename encryption, ~143 characters max on a 255-byte FS — long build artefact names break |
| Space overhead | 8 KiB header per file, plus 4 KiB extent rounding |
| Performance | 20–40% penalty; poor with many small files |
| Metadata leakage | Sizes, timestamps, directory structure, file count |
| Maintenance status | Effectively unmaintained upstream; Ubuntu removed the installer option in 18.04; **fscrypt is the successor** |
| Exam status | **Explicitly examinable** — know the commands and the PAM integration |

For new designs, prefer `fscrypt` (native ext4/f2fs) for the per-user-home use case and dm-crypt/LUKS for the volume use case. Learn eCryptfs because it is on the objectives and because you will find it on inherited systems.

---

## 9. Filesystem-native encryption (awareness)

### 9.1 fscrypt / ext4 encryption

Encryption implemented inside the filesystem itself: per-directory policies, keys in the kernel keyring, no stacking, no per-file header, no FUSE.

```
$ sudo tune2fs -O encrypt /dev/vg0/home
tune2fs 1.47.0 (5-Feb-2023)
$ sudo fscrypt setup
Defaulting to policy_version 2 because kernel supports it.
Metadata directories created at "/.fscrypt".
$ sudo fscrypt setup /home
Metadata directories created at "/home/.fscrypt".
$ fscrypt encrypt /home/alice --user=alice
The following protector sources are available:
1 - Your login passphrase (pam_passphrase)
2 - A custom passphrase (custom_passphrase)
3 - A raw 256-bit key (raw_key)
Enter the source number for the new protector [2 - custom_passphrase]: 1
Enter login passphrase for alice:
"/home/alice" is now encrypted, unlocked, and ready for use.

$ fscrypt status /home
ext4 filesystem "/home" has 1 protector and 1 policy.

PROTECTOR         LINKED  DESCRIPTION
7c1f0b2d4e6a8931  No      login protector for alice

POLICY                            UNLOCKED  PROTECTORS
b93a17c4f0e25d8a6c31f0b74d2e9058  Yes       7c1f0b2d4e6a8931
```

| fscrypt vs eCryptfs | fscrypt |
|---|---|
| Per-file header | **None** — no space overhead |
| Filename encryption | Built in, no separate key ceremony |
| Performance | Near-native; uses the same kernel crypto path |
| Requires FS feature flag | Yes (`encrypt`), block size must equal page size |
| Cannot encrypt an existing directory in place | Correct — the directory must be empty |
| Metadata (sizes, mtimes) | Still in the clear |

### 9.2 ZFS native encryption

```
# zpool create -o ashift=12 tank mirror /dev/nvme3n1 /dev/nvme4n1
# zfs create -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt tank/secure
Enter new passphrase:
Re-enter new passphrase:
# zfs get encryption,keystatus,encryptionroot tank/secure
NAME         PROPERTY        VALUE           SOURCE
tank/secure  encryption      aes-256-gcm     -
tank/secure  keystatus       available       -
tank/secure  encryptionroot  tank/secure     -
# zfs unload-key tank/secure && zfs load-key tank/secure
```

ZFS gives authenticated encryption (GCM) plus `zfs send -w` raw replication of ciphertext to an untrusted backup target — a capability dm-crypt cannot match. Dataset-level granularity, checksummed integrity, per-dataset keys.

---

## 10. Userspace stacked encryption and cryptmount

| Tool | Mechanism | Status | Use |
|---|---|---|---|
| **EncFS** | FUSE, per-file | Security audit (2014) found serious weaknesses; **avoid for new work** | Legacy |
| **gocryptfs** | FUSE, AES-256-GCM per block, scrypt KDF | Actively maintained, audited | Encrypting a directory on cloud/object storage or NFS |
| **CryFS** | FUSE, fixed-size blocks | Hides file sizes and directory structure | Cloud sync where metadata matters |
| **fscrypt** | Kernel, native | Recommended successor to eCryptfs | Per-user homes |

```
$ gocryptfs -init /srv/vault.raw
Choose a password for protecting your files.
Password:
Repeat:
Your master key is:
    1a2b3c4d-5e6f7081-92a3b4c5-d6e7f809-1a2b3c4d-5e6f7081-92a3b4c5-d6e7f809
Filesystem created, mount with "gocryptfs /srv/vault.raw /srv/vault"
$ gocryptfs /srv/vault.raw /srv/vault
Password:
Decrypting master key
Filesystem mounted and ready.
```

**`cryptmount`** (in the exam's terms list) is a Debian-oriented tool that lets *unprivileged users* mount encrypted filesystems — the setuid helper handles the dm-crypt and mount calls, driven by `/etc/cryptmount/cmtab`:

```
# /etc/cryptmount/cmtab
opaque {
    dev=/dev/vg0/opaque
    dir=/mnt/opaque
    fstype=ext4
    fsoptions=defaults,noatime,nosuid,nodev
    cipher=aes-xts-plain64
    keyformat=luks
    keyfile=/dev/vg0/opaque
    supath=/sbin:/usr/sbin:/bin:/usr/bin
}

scratch {
    dev=/dev/vg0/scratch
    dir=/mnt/scratch
    fstype=ext4
    cipher=aes-xts-plain64
    keyformat=builtin
    keyfile=/etc/cryptmount/scratch.key
    keyhash=sha512
    keycipher=aes-xts-plain64
}
```

```
$ cryptmount-setup           # interactive first-time wizard
$ cryptmount opaque          # as a normal user
Enter password for target "opaque":
$ cryptmount -u opaque
$ cryptmount --change-password opaque
$ cryptmount --list
opaque:
  target-dir=/mnt/opaque
  device=/dev/vg0/opaque
```

`keyformat=luks` means the key lives in the device's own LUKS header, so `cryptmount` becomes a user-facing front end to an ordinary LUKS volume.

---

## 11. Production infrastructure

Everything below is complete and deployable as written.

### 11.1 Ansible role: provision an encrypted data volume

```yaml
# roles/luks_volume/defaults/main.yml
---
luks_volumes:
  - name: pgdata
    device: /dev/disk/by-id/nvme-SAMSUNG_MZQL23T8HCLS_S64GNE0T123456
    fstype: xfs
    mountpoint: /srv/pgdata
    label: pgdata-01
    integrity: false
    key_source: vault           # vault | keyfile | passphrase
    vault_path: secret/data/luks/{{ inventory_hostname }}/pgdata

luks_cipher: aes-xts-plain64
luks_key_size: 512
luks_sector_size: 4096
luks_pbkdf: argon2id
luks_pbkdf_memory: 1048576
luks_iter_time: 5000
luks_header_backup_dir: /root/luks-headers
luks_perf_flags: "--perf-no_read_workqueue --perf-no_write_workqueue --persistent"
```

```yaml
# roles/luks_volume/tasks/main.yml
---
- name: Ensure cryptsetup and tooling are present
  ansible.builtin.package:
    name:
      - cryptsetup
      - cryptsetup-initramfs   # Debian family; use dracut on RHEL family
    state: present
  when: ansible_os_family == 'Debian'

- name: Ensure cryptsetup is present (RHEL family)
  ansible.builtin.dnf:
    name:
      - cryptsetup
      - clevis-luks
      - clevis-dracut
    state: present
  when: ansible_os_family == 'RedHat'

- name: Ensure key and header directories exist with strict permissions
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: '0700'
  loop:
    - /etc/luks-keys
    - "{{ luks_header_backup_dir }}"

- name: Detect existing LUKS signature
  ansible.builtin.command:
    cmd: "blkid -p -o value -s TYPE {{ item.device }}"
  register: luks_probe
  changed_when: false
  failed_when: false
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Abort if the device holds unexpected data
  ansible.builtin.fail:
    msg: >-
      {{ item.item.device }} contains signature '{{ item.stdout }}'.
      Refusing to format. Wipe it deliberately if this is intended.
  when:
    - item.stdout | length > 0
    - item.stdout != 'crypto_LUKS'
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Fetch or generate the volume key
  ansible.builtin.set_fact:
    luks_keys: "{{ luks_keys | default({}) | combine({item.name: lookup('community.hashi_vault.hashi_vault', item.vault_path ~ ':key')}) }}"
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"
  when: item.key_source == 'vault'
  no_log: true

- name: Write keyfiles
  ansible.builtin.copy:
    content: "{{ luks_keys[item.name] }}"
    dest: "/etc/luks-keys/{{ item.name }}.key"
    owner: root
    group: root
    mode: '0400'
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"
  no_log: true

- name: Format LUKS2 volumes that are not yet formatted
  ansible.builtin.command:
    cmd: >-
      cryptsetup luksFormat --batch-mode --type luks2
      --cipher {{ luks_cipher }}
      --key-size {{ luks_key_size }}
      --sector-size {{ luks_sector_size }}
      --pbkdf {{ luks_pbkdf }}
      --pbkdf-memory {{ luks_pbkdf_memory }}
      --iter-time {{ luks_iter_time }}
      --label {{ item.item.label }}
      {% if item.item.integrity %}--integrity hmac-sha256{% endif %}
      --key-file /etc/luks-keys/{{ item.item.name }}.key
      {{ item.item.device }}
  when: item.stdout != 'crypto_LUKS'
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Read volume UUIDs
  ansible.builtin.command:
    cmd: "cryptsetup luksUUID {{ item.device }}"
  register: luks_uuids
  changed_when: false
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Render /etc/crypttab
  ansible.builtin.template:
    src: crypttab.j2
    dest: /etc/crypttab
    owner: root
    group: root
    mode: '0644'
    validate: 'grep -qE "^[^[:space:]#]+[[:space:]]" %s'
  notify:
    - Rebuild initramfs
    - Reload systemd

- name: Open the volumes
  ansible.builtin.command:
    cmd: >-
      cryptsetup open {{ item.item.device }} crypt{{ item.item.name }}
      --key-file /etc/luks-keys/{{ item.item.name }}.key
      {{ luks_perf_flags }}
    creates: "/dev/mapper/crypt{{ item.item.name }}"
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Create the filesystem
  community.general.filesystem:
    fstype: "{{ item.fstype }}"
    dev: "/dev/mapper/crypt{{ item.name }}"
    opts: "-L {{ item.label }}"
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Mount the filesystem
  ansible.posix.mount:
    path: "{{ item.mountpoint }}"
    src: "/dev/mapper/crypt{{ item.name }}"
    fstype: "{{ item.fstype }}"
    opts: "defaults,noatime,nofail,x-systemd.requires=/dev/mapper/crypt{{ item.name }}"
    state: mounted
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Back up the LUKS headers
  ansible.builtin.command:
    cmd: >-
      cryptsetup luksHeaderBackup {{ item.item.device }}
      --header-backup-file {{ luks_header_backup_dir }}/{{ item.item.name }}-{{ item.stdout }}.img
    creates: "{{ luks_header_backup_dir }}/{{ item.item.name }}-{{ item.stdout }}.img"
  loop: "{{ luks_uuids.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Restrict header backup permissions
  ansible.builtin.file:
    path: "{{ luks_header_backup_dir }}"
    state: directory
    mode: '0700'
    recurse: true
    owner: root
    group: root

- name: Install the LUKS health exporter
  ansible.builtin.copy:
    src: luks-metrics.sh
    dest: /usr/local/bin/luks-metrics.sh
    mode: '0755'

- name: Install the exporter timer
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/systemd/system/{{ item }}"
    mode: '0644'
  loop:
    - luks-metrics.service
    - luks-metrics.timer
  notify: Reload systemd

- name: Enable the exporter timer
  ansible.builtin.systemd:
    name: luks-metrics.timer
    enabled: true
    state: started
    daemon_reload: true
```

```jinja
{# roles/luks_volume/templates/crypttab.j2 #}
# Managed by Ansible — do not edit by hand.
# <name>  <device>  <keyfile>  <options>
{% for vol in luks_volumes %}
{% set uuid = (luks_uuids.results | selectattr('item.name', 'equalto', vol.name) | first).stdout %}
crypt{{ vol.name }}  UUID={{ uuid }}  /etc/luks-keys/{{ vol.name }}.key  luks,discard,no-read-workqueue,no-write-workqueue,nofail,x-systemd.device-timeout=30s
{% endfor %}
```

```yaml
# roles/luks_volume/handlers/main.yml
---
- name: Rebuild initramfs
  ansible.builtin.command:
    cmd: "{{ 'update-initramfs -u -k all' if ansible_os_family == 'Debian' else 'dracut --force' }}"

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

### 11.2 cloud-init: encrypt ephemeral NVMe at first boot

```yaml
#cloud-config
# Encrypts instance-store NVMe with an ephemeral key generated at boot.
# The key never leaves RAM and never persists: an instance stop wipes the data by design.
package_update: true
packages:
  - cryptsetup
  - xfsprogs

write_files:
  - path: /usr/local/sbin/encrypt-ephemeral.sh
    permissions: '0700'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      TARGET_MOUNT=/var/lib/kubelet-ephemeral
      MAPPER=ephemeral0

      dev=$(lsblk -dpno NAME,MODEL \
            | awk '$2 ~ /Instance Storage|EphemeralDisk/ {print $1; exit}')
      [[ -n "${dev}" ]] || { echo "no ephemeral NVMe found"; exit 0; }

      if [[ -e "/dev/mapper/${MAPPER}" ]]; then
        echo "${MAPPER} already active"; exit 0
      fi

      # Ephemeral key: 64 random bytes held only in a tmpfs that is unmounted below.
      keydir=$(mktemp -d -p /dev/shm)
      chmod 700 "${keydir}"
      trap 'shred -u "${keydir}/key" 2>/dev/null || true; rmdir "${keydir}"' EXIT
      dd if=/dev/urandom of="${keydir}/key" bs=64 count=1 status=none

      cryptsetup luksFormat --batch-mode --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --label ephemeral-scratch \
        --key-file "${keydir}/key" "${dev}"

      cryptsetup open "${dev}" "${MAPPER}" \
        --key-file "${keydir}/key" \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

      mkfs.xfs -f -L ephemeral "/dev/mapper/${MAPPER}"
      mkdir -p "${TARGET_MOUNT}"
      mount -o noatime,nodiratime "/dev/mapper/${MAPPER}" "${TARGET_MOUNT}"
      echo "encrypted ephemeral volume ready at ${TARGET_MOUNT}"

  - path: /etc/systemd/system/encrypt-ephemeral.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Encrypt and mount instance-store NVMe with an ephemeral key
      DefaultDependencies=no
      After=local-fs.target systemd-udev-settle.service
      Wants=systemd-udev-settle.service
      Before=kubelet.service containerd.service
      ConditionPathExists=!/dev/mapper/ephemeral0

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/encrypt-ephemeral.sh
      TimeoutStartSec=600

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, encrypt-ephemeral.service ]
```

### 11.3 Kubernetes: a highly available Tang server for NBDE

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: nbde
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tang-keys
  namespace: nbde
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ceph-rbd-retain
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tang
  namespace: nbde
  labels:
    app.kubernetes.io/name: tang
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tang
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tang
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: tang
      containers:
        - name: tang
          image: quay.io/sec-eng-special/tang-operator-tang:v1.0.1
          imagePullPolicy: IfNotPresent
          args: ["-l", "-p", "8080", "/var/db/tang"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /adv
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /adv
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: keys
              mountPath: /var/db/tang
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: keys
          persistentVolumeClaim:
            claimName: tang-keys
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
---
apiVersion: v1
kind: Service
metadata:
  name: tang
  namespace: nbde
spec:
  type: LoadBalancer
  loadBalancerIP: 10.42.0.53
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: tang
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tang-ingress
  namespace: nbde
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: tang
  policyTypes: ["Ingress"]
  ingress:
    # Tang's security model relies on network reachability. Restrict it to the
    # management CIDR: a disk that leaves this network cannot self-unlock.
    - from:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: tang
  namespace: nbde
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tang
```

Verify the advertisement is reachable from a node before binding anything to it:

```
$ curl -s http://10.42.0.53/adv | jq -r '.payload' | base64 -d | jq '.keys[].kid'
"kWwirxc5PgOKB1cMlwZWRgOa1Aw"
"n3sV5tUqIkO0dZ2GRc9LkQvHfBs"
```

### 11.4 Kubernetes: node-level encryption enforcement DaemonSet

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: luks-audit
  namespace: kube-system
data:
  audit.sh: |
    #!/usr/bin/env bash
    # Verifies that every mountpoint listed in REQUIRED_ENCRYPTED_PATHS is backed
    # by a dm-crypt mapping, and exports the result as node labels + metrics.
    set -euo pipefail
    : "${REQUIRED_ENCRYPTED_PATHS:=/var/lib/kubelet /var/lib/containerd}"
    OUT=/host/var/lib/node-exporter/textfile/luks.prom
    tmp="${OUT}.$$"

    is_encrypted() {
      local path="$1" src
      src=$(chroot /host findmnt -no SOURCE --target "${path}" 2>/dev/null || true)
      [[ -n "${src}" ]] || return 1
      # Walk the device-mapper stack looking for a 'crypt' target.
      chroot /host lsblk -sno TYPE "${src}" 2>/dev/null | grep -q '^crypt$'
    }

    {
      echo "# HELP node_luks_path_encrypted Whether a required path is on a dm-crypt device."
      echo "# TYPE node_luks_path_encrypted gauge"
      for p in ${REQUIRED_ENCRYPTED_PATHS}; do
        if is_encrypted "${p}"; then v=1; else v=0; fi
        echo "node_luks_path_encrypted{path=\"${p}\"} ${v}"
      done

      echo "# HELP node_luks_keyslots_used Active keyslots per LUKS device."
      echo "# TYPE node_luks_keyslots_used gauge"
      while read -r dev; do
        [[ -n "${dev}" ]] || continue
        uuid=$(chroot /host cryptsetup luksUUID "${dev}" 2>/dev/null || echo unknown)
        slots=$(chroot /host cryptsetup luksDump "${dev}" 2>/dev/null \
                | awk '/^Keyslots:/{f=1;next} /^Tokens:/{f=0} f && /^  [0-9]+: luks/{c++} END{print c+0}')
        echo "node_luks_keyslots_used{device=\"${dev}\",uuid=\"${uuid}\"} ${slots}"
      done < <(chroot /host lsblk -pno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}')

      echo "# HELP node_dm_integrity_failures Integrity check failures reported by dm-integrity."
      echo "# TYPE node_dm_integrity_failures counter"
      while read -r name; do
        [[ -n "${name}" ]] || continue
        f=$(chroot /host integritysetup status "${name}" 2>/dev/null \
            | awk '/failures:/{print $2}')
        echo "node_dm_integrity_failures{mapping=\"${name}\"} ${f:-0}"
      done < <(chroot /host dmsetup ls --target integrity 2>/dev/null | awk '{print $1}')
    } > "${tmp}"
    mv "${tmp}" "${OUT}"
    cat "${OUT}"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: luks-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: luks-audit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: luks-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: luks-audit
    spec:
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: audit
          image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
          command: ["/bin/bash", "-c"]
          args:
            - |
              while true; do
                /scripts/audit.sh || echo "audit failed" >&2
                sleep 300
              done
          env:
            - name: REQUIRED_ENCRYPTED_PATHS
              value: "/var/lib/kubelet /var/lib/containerd /srv/pgdata"
          securityContext:
            privileged: true      # required: chroot into the host and read device-mapper state
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: host
              mountPath: /host
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: host
          hostPath:
            path: /
            type: Directory
        - name: scripts
          configMap:
            name: luks-audit
            defaultMode: 0755
```

### 11.5 Prometheus alerting

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: disk-encryption
  namespace: monitoring
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: disk-encryption
      interval: 60s
      rules:
        - alert: NodePathNotEncrypted
          expr: node_luks_path_encrypted == 0
          for: 10m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "{{ $labels.path }} on {{ $labels.instance }} is not on an encrypted device"
            description: >-
              A path required to be encrypted at rest is backed by a plaintext block
              device. Cordon the node and investigate before scheduling stateful workloads.
            runbook_url: "https://runbooks.internal/platform/luks-not-encrypted"

        - alert: LUKSKeyslotCountAnomalous
          expr: node_luks_keyslots_used > 6 or node_luks_keyslots_used < 2
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.device }} on {{ $labels.instance }} has {{ $value }} keyslots"
            description: >-
              Expected between 2 and 6 keyslots (automation, recovery, break-glass).
              Fewer means no fallback path; more may indicate an unauthorised enrolment.

        - alert: DMIntegrityFailuresDetected
          expr: increase(node_dm_integrity_failures[15m]) > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "dm-integrity detected {{ $value }} failures on {{ $labels.mapping }}"
            description: >-
              Sectors failed authentication. This is either media failure or tampering.
              Fail the node out of the pool and preserve it for analysis.

        - alert: LUKSHeaderBackupStale
          expr: (time() - node_luks_header_backup_mtime_seconds) > 86400 * 30
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "LUKS header backup for {{ $labels.device }} is older than 30 days"
```

---

## 12. Verification and diagnostics

### 12.1 The verification ladder

Each rung proves strictly more than the one below. Know which rung a claim rests on.

| # | Claim | Command | Cost |
|---|---|---|---|
| 1 | A LUKS device exists | `blkid -p -s TYPE <dev>` → `crypto_LUKS` | free |
| 2 | It has the parameters we intended | `cryptsetup luksDump <dev>` | free |
| 3 | The mapping is active with the right flags | `cryptsetup status <name>`, `dmsetup table <name>` | free |
| 4 | The mounted path is *actually* on that mapping | `lsblk -s -o NAME,TYPE $(findmnt -no SOURCE --target /srv/pgdata)` | free |
| 5 | The ciphertext really is ciphertext | entropy check on the raw device (below) | free |
| 6 | Each unlock path works **independently** | `cryptsetup open --test-passphrase --key-slot N` per slot | free |
| 7 | The header backup restores | Restore onto a loop-device clone and open it | minutes |
| 8 | The boot path works unattended | **Reboot the node** | a reboot |
| 9 | Tamper detection works | Corrupt a sector on a scratch integrity volume, read it back | destructive, on scratch only |

Rungs 6–8 are the ones teams skip, and they are the ones that fail at 03:00. **An unlock path that has never been exercised is not an unlock path.**

Rung 4 in one line — this is the check that catches "we encrypted the wrong disk":

```
$ findmnt -no SOURCE --target /srv/pgdata | xargs lsblk -s -o NAME,TYPE,FSTYPE
NAME        TYPE  FSTYPE
pgdata      crypt xfs
└─nvme1n1   disk  crypto_LUKS
```

Rung 5 — plaintext has structure, ciphertext does not:

```
$ sudo dd if=/dev/nvme1n1 bs=1M skip=64 count=8 status=none | ent
Entropy = 7.999978 bits per byte.
Optimum compression would reduce the size of this 8388608 byte file by 0 percent.
Chi square distribution for 8388608 samples is 251.44, and randomly would exceed this value 55.12 percent of the time.
Arithmetic mean value of data bytes is 127.4989 (127.5 = random).
Monte Carlo value for Pi is 3.141472816 (error 0.00 percent).
Serial correlation coefficient is -0.000041 (totally uncorrelated = random).
```

Entropy below ~7.9, or any recognisable string, means you are looking at plaintext:

```
$ sudo strings -n 12 /dev/nvme1n1 | head -5     # should produce nothing meaningful
```

### 12.2 Failure catalogue

| Symptom | Root cause | Diagnostic | Fix |
|---|---|---|---|
| `No key available with this passphrase.` | Wrong passphrase, or the slot was killed, or a keyfile has a trailing newline | `cryptsetup luksDump` (count slots); `xxd -l 16 keyfile` | Use another slot; `--keyfile-size` to exclude `\n` |
| `Device /dev/X is not a valid LUKS device.` | Header overwritten (a stray `mkfs`, a partition-table rewrite, `dd`) | `xxd -l 8 /dev/X` — expect `4c55 4b53 baba` | `luksHeaderRestore` from backup. **No backup = no data** |
| `Requested header backup file already exists.` | Backup path collision | `ls -l` | Version by UUID and date |
| Boot hangs at `A start job is running for /dev/disk/by-uuid/…` | Backing device absent or renamed | `journalctl -b -u systemd-cryptsetup@*`; `blkid` from the emergency shell | Fix the crypttab UUID; add `x-systemd.device-timeout` and `nofail` |
| Boot drops to emergency shell after a firmware update | TPM2 PCR policy no longer satisfies the seal | `journalctl -b \| grep -i tpm2`; `systemd-analyze pcrs` | Unlock with the recovery key, then re-enrol: `systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto` |
| TPM unseal fails intermittently | `tpm2-abrmd` racing, or PCR 1 changing with RAM/boot-order | `tpm2_pcrread sha256:0,1,4,7,14` across boots | Bind to PCR 7 only; add a recovery key |
| Volume opens but `mount` says `wrong fs type, bad superblock` | Plain-mode parameter mismatch — you are decrypting to garbage | `blkid /dev/mapper/x` returns empty; `xxd` shows noise | Re-derive the exact `--cipher/--hash/--key-size/--offset` |
| Terrible NVMe throughput after enabling encryption | Workqueues, 512 B sectors, or software AES | `cryptsetup status` (flags, sector size); `grep aes /proc/crypto` | `--perf-no_*_workqueue --persistent`; reencrypt at 4096 B |
| `Device pgdata is still in use.` on close | An open fd, a stacked LVM/dm layer, or a mount in another namespace | `lsof +D /srv/pgdata`; `dmsetup deps -o devname pgdata`; `findmnt -A` | Unmount everything above it first |
| `Input/output error` + `Checksum failed at sector` | dm-integrity detected modification or media failure | `dmesg -T \| grep -i integrity`; `integritysetup status` | Fail the node out; restore from replica |
| Whole-device I/O errors right after `--integrity-no-wipe` | Sectors never got valid tags | `dmesg` shows failures across untouched regions | Re-format with the wipe, or write the whole device |
| eCryptfs: `Error attempting to evaluate mount options` | FEKEK/FNEK not in the keyring | `keyctl list @u` | `ecryptfs-add-passphrase --fnek` before mounting |
| eCryptfs home empty after login | `pam_ecryptfs` missing from the session stack, or wrapped passphrase out of sync | `journalctl -b \| grep ecryptfs`; `mount \| grep ecryptfs` | Fix the PAM stack; `ecryptfs-rewrap-passphrase` |
| eCryptfs: `File name too long` | Filename encryption inflates names; ~143-char limit | Reproduce with a long name | Shorten names, or move to fscrypt |
| `cryptsetup resize` prompts for a passphrase in automation | Master key not in the kernel keyring | `cryptsetup status \| grep 'key location'` | Ensure `KEYRING` build flag; avoid `--disable-keyring` |
| GRUB cannot unlock a LUKS2 `/boot` | Argon2 keyslots | `luksDump` shows `PBKDF: argon2id` | Add a PBKDF2 slot: `luksAddKey --pbkdf pbkdf2` |
| Hibernation fails to resume | Random-key swap | `cryptsetup status cryptswap` shows `type: PLAIN` | Move swap inside the LUKS volume, set `resume=` |

### 12.3 The diagnostic command set

```
# Layer identification, top to bottom
$ lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS,LABEL
$ findmnt --real
$ sudo dmsetup ls --tree -o devname
pgdata (253:5)
 └─ (259:1)
cryptroot (253:0)
 └─ (259:0)

# What the kernel thinks the mapping is
$ sudo dmsetup info -c
Name            Maj Min Stat Open Targ Event  UUID
pgdata          253   5 L--w    1    1      0 CRYPT-LUKS2-9f4e1c2a3b7d4a1e9c052f8a6d4b1e77-pgdata
cryptroot       253   0 L--w    2    1      0 CRYPT-LUKS2-1c4a90f27ee14b3a8b0f6dd4a2c5c101-cryptroot

# Crypto backend actually in use
$ grep -B1 -A6 'driver.*aesni' /proc/crypto | head -20

# Boot-time unlock evidence
$ journalctl -b -u 'systemd-cryptsetup@*' --no-pager
$ journalctl -b -g 'cryptsetup|dm-crypt|integrity|tpm2' --no-pager | tail -40

# TPM state
$ sudo tpm2_pcrread sha256:0,1,4,7,11,14
sha256:
  0 : 0x3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969
  1 : 0xE7A4A2C21F0F6C1CB57ED6B9AF4AC03D2A8B0DAF95F0C6BCD0EE4E9E6B1E2A11
  4 : 0x4C1FE1C0B0E5DEDF9C0C4D6D4A0C0C4B7C1A0F1E9D8C7B6A5F4E3D2C1B0A9988
  7 : 0x5C5A8F0C8B0FA2C0D3A9E1B7C2D4F6A8B0C2D4E6F8A0B2C4D6E8F0A2B4C6D8E0
 11 : 0x0000000000000000000000000000000000000000000000000000000000000000
 14 : 0x9B7C5E3A1F0D2B4C6E8A0C2E4F6A8B0D2E4F6A8C0E2F4A6B8D0E2F4A6C8E0F2A

# Keyring (eCryptfs and dm-crypt)
$ keyctl show @u
$ sudo keyctl show @s

# Prove there is no plaintext leak on the raw device
$ sudo dd if=/dev/nvme1n1 bs=1M skip=100 count=4 status=none | gzip -c | wc -c
4194638      # ~incompressible → ciphertext
```

### 12.4 Emergency: recovering a LUKS volume from a rescue environment

```
$ sudo cryptsetup luksDump /dev/nvme1n1 || echo "header damaged"
$ sudo cryptsetup repair /dev/nvme1n1
Do you really want to repair the LUKS device header? (Type 'yes' in capital letters): YES
Only metadata area 1 is valid.
Header restored from secondary header.

# If repair fails, restore from the offline backup onto a clone first.
$ sudo dd if=/dev/nvme1n1 of=/mnt/rescue/pgdata.img bs=64M status=progress
$ sudo losetup -f --show /mnt/rescue/pgdata.img
/dev/loop0
$ sudo cryptsetup luksHeaderRestore /dev/loop0 --header-backup-file /mnt/rescue/pgdata-01.img
$ sudo cryptsetup open /dev/loop0 rescue
$ sudo mount -o ro /dev/mapper/rescue /mnt/recovered
```

Never restore a header onto the production device until it has been proven on a clone. A wrong header on the real disk with no backup ends the incident badly.

Last-resort master-key extraction, for a volume you can still open but whose passphrases you are about to lose — treat the output as the crown jewels:

```
$ sudo cryptsetup luksDump --dump-master-key /dev/nvme1n1

WARNING!
========
The header dump with volume key is sensitive information
that allows access to encrypted partition without a passphrase.
This dump should be stored encrypted in a safe place.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme1n1:
LUKS header information for /dev/nvme1n1
Cipher name:    aes
Cipher mode:    xts-plain64
Payload offset: 32768
UUID:           9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
MK bits:        512
MK dump:        8f 3a c1 90 2e 74 bd 05 61 aa 3c 7f d2 18 96 e4
                0b 55 7d 21 c9 46 8e f3 1a 60 b2 4c 07 d9 35 8a
                ...
```

The volume can then be reopened with `cryptsetup open --master-key-file` even with every keyslot destroyed. Which also means: **anyone holding this dump owns the data forever**, and no keyslot rotation will ever revoke them. Only a full `cryptsetup reencrypt` does.

---

## 13. Exam traps and command cheat sheet

### 13.1 The traps

1. **`--key-size 512` is AES-256**, because XTS uses two keys. Expect this in a question.
2. **LUKS1 has 8 keyslots, LUKS2 has 32.** LUKS1 is PBKDF2-only; LUKS2 defaults to Argon2id.
3. **`luksErase` is not `luksKillSlot`.** The first destroys every keyslot; the second destroys one.
4. **`cryptsetup luksFormat` destroys existing data**; `cryptsetup reencrypt --encrypt` preserves it.
5. **Plain dm-crypt has no header** — no `luksDump`, no key change, no second passphrase.
6. **`/etc/crypttab` field order is `name device keyfile options`**, the mirror image of `/etc/fstab`'s `device mountpoint fstype options`.
7. **`keyscript=` is a Debian `cryptsetup` extension**; `systemd-cryptsetup` ignores it. `initramfs` is likewise Debian-only.
8. **`swap` in crypttab reformats the device on every boot** — with a safety check for existing signatures.
9. **eCryptfs has two keys**: FEKEK for contents, FNEK for filenames. Each *file* additionally has its own random FEK.
10. **`ecryptfs-setup-private` wraps the mount passphrase with the login passphrase.** A root-forced `passwd` breaks the unwrap; `ecryptfs-rewrap-passphrase` and the recorded mount passphrase are the escape hatches.
11. **`pam_ecryptfs.so` appears in the `auth`, `session` and `password` stacks** — different jobs in each.
12. **`systemd-cryptenroll` writes LUKS2 tokens**, and tokens are a LUKS2-only feature.
13. **Header backups contain keyslots.** Revoking a passphrase does not revoke it from an old backup.

### 13.2 Command cheat sheet

```
# ─── LUKS lifecycle ───────────────────────────────────────────────────────
cryptsetup benchmark
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
           --sector-size 4096 --pbkdf argon2id --iter-time 5000 DEV
cryptsetup open DEV NAME                     # was luksOpen
cryptsetup close NAME                        # was luksClose
cryptsetup status NAME
cryptsetup luksDump DEV
cryptsetup luksUUID DEV
cryptsetup isLuks DEV && echo yes

# ─── Keys ─────────────────────────────────────────────────────────────────
cryptsetup luksAddKey DEV [NEWKEYFILE]
cryptsetup luksChangeKey DEV --key-slot N
cryptsetup luksRemoveKey DEV [KEYFILE]       # by passphrase
cryptsetup luksKillSlot DEV N                # by slot number
cryptsetup luksErase DEV                     # ALL slots — irreversible
cryptsetup open --test-passphrase --key-slot N DEV
cryptsetup config --key-slot N --priority prefer|normal|ignore DEV

# ─── Header ───────────────────────────────────────────────────────────────
cryptsetup luksHeaderBackup DEV --header-backup-file FILE
cryptsetup luksHeaderRestore DEV --header-backup-file FILE
cryptsetup repair DEV
cryptsetup open --header FILE DEV NAME       # detached header

# ─── LUKS2 features ───────────────────────────────────────────────────────
cryptsetup convert --type luks2 DEV
cryptsetup luksConvertKey --pbkdf argon2id --key-slot N DEV
cryptsetup reencrypt DEV                         # rotate master key
cryptsetup reencrypt --encrypt --reduce-device-size 32M DEV
cryptsetup reencrypt --decrypt --header FILE DEV
cryptsetup reencrypt --resume-only DEV
cryptsetup resize NAME
cryptsetup luksSuspend NAME ; cryptsetup luksResume NAME
cryptsetup token add|remove|import|export DEV

# ─── Plain mode & integrity ───────────────────────────────────────────────
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
           --hash sha512 --offset 0 --skip 0 DEV NAME
integritysetup format --integrity sha256 --tag-size 32 DEV
integritysetup open --integrity sha256 DEV NAME
integritysetup status NAME

# ─── Boot integration ─────────────────────────────────────────────────────
$EDITOR /etc/crypttab ; systemctl daemon-reload
systemd-cryptenroll DEV --tpm2-device=auto --tpm2-pcrs=7
systemd-cryptenroll DEV --fido2-device=auto
systemd-cryptenroll DEV --recovery-key
systemd-cryptenroll DEV --wipe-slot=tpm2|password|empty|N
update-initramfs -u -k all      # Debian
dracut --force                  # RHEL

# ─── eCryptfs ─────────────────────────────────────────────────────────────
mount -t ecryptfs LOWER UPPER -o ecryptfs_cipher=aes,ecryptfs_key_bytes=32,...
umount.ecryptfs UPPER
ecryptfs-setup-private
ecryptfs-mount-private ; ecryptfs-umount-private
ecryptfs-add-passphrase [--fnek]
ecryptfs-wrap-passphrase   FILE
ecryptfs-unwrap-passphrase FILE
ecryptfs-rewrap-passphrase FILE
ecryptfs-migrate-home -u USER
ecryptfs-recover-private [PATH]
ecryptfs-stat FILE
ecryptfs-manager
keyctl list @u

# ─── cryptmount ───────────────────────────────────────────────────────────
cryptmount-setup
cryptmount TARGET ; cryptmount -u TARGET
cryptmount --change-password TARGET
cryptmount --generate-key SIZE TARGET
```

---

## 14. Self-assessment

1. A LUKS2 volume shows `Cipher key: 512 bits` with `aes-xts-plain64`. What AES key length is in use, and why?
2. You rotate the passphrase on a volume with `luksChangeKey`. An attacker exfiltrated the master key three months ago. Are they locked out? What is the only remediation?
3. Why does destroying a keyslot require overwriting ~256 KiB instead of 64 bytes?
4. A node with `/boot` on LUKS2 fails at the GRUB prompt after you convert its keyslots to Argon2id. Explain, and give two fixes.
5. Write the `/etc/crypttab` line for a swap partition encrypted with a fresh random key at each boot, using a stable device identifier. What capability does this remove?
6. `dd` of the raw device shows entropy 7.9998 in one region and 5.2 in another. What are the plausible explanations, and which are benign?
7. Distinguish FEK, FEKEK and FNEK in eCryptfs. Which is stored where?
8. A root admin resets a user's password with `passwd`. The user logs in and finds an empty home directory. What happened, and what are the two recovery paths?
9. Your fleet uses `--tpm2-pcrs=0+7`. A vendor pushes a firmware update. Predict the outcome and design a safer policy.
10. Name two things `dm-integrity` protects against that plain LUKS does not, and two operations it makes impossible.
11. When would you choose fscrypt over dm-crypt? Over eCryptfs? Give a scenario where you would run dm-crypt *and* fscrypt on the same machine.
12. `cryptsetup close vault` returns `Device vault is still in use.` after `umount` succeeded. List three commands that would identify the holder.

---

## 15. References

**Certification objectives**
- LPI, *Exam 303: Security, Objectives (version 3.0)* — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI, *LPIC-3 Security certification overview* — https://www.lpi.org/our-certifications/lpic-3-security-overview/

**cryptsetup / LUKS (upstream)**
- cryptsetup project — https://gitlab.com/cryptsetup/cryptsetup
- cryptsetup wiki (documentation index) — https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home
- cryptsetup FAQ (the authoritative operational reference) — https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions
- LUKS2 on-disk format specification — https://gitlab.com/cryptsetup/LUKS2-docs
- `cryptsetup(8)` — https://man7.org/linux/man-pages/man8/cryptsetup.8.html
- `cryptsetup-reencrypt(8)` — https://man7.org/linux/man-pages/man8/cryptsetup-reencrypt.8.html
- `integritysetup(8)` — https://man7.org/linux/man-pages/man8/integritysetup.8.html

**Kernel documentation**
- `dm-crypt` — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
- `dm-integrity` — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
- Device-mapper overview — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
- Filesystem-level encryption (fscrypt) — https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
- eCryptfs — https://www.kernel.org/doc/html/latest/filesystems/ecryptfs.html
- Kernel keyring (`keyrings/core`) — https://www.kernel.org/doc/html/latest/security/keys/core.html

**systemd**
- `crypttab(5)` — https://www.freedesktop.org/software/systemd/man/latest/crypttab.html
- `systemd-cryptsetup@.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup@.service.html
- `systemd-cryptsetup-generator(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup-generator.html
- `systemd-cryptenroll(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html
- `systemd-pcrphase` / TPM2 PCR measurement — https://www.freedesktop.org/software/systemd/man/latest/systemd-pcrphase.service.html

**eCryptfs and userspace tools**
- eCryptfs project (ecryptfs-utils) — https://launchpad.net/ecryptfs
- `ecryptfs(7)` — https://man7.org/linux/man-pages/man7/ecryptfs.7.html
- `mount.ecryptfs(8)` — https://man7.org/linux/man-pages/man8/mount.ecryptfs.8.html
- `ecryptfs-setup-private(1)` — https://manpages.ubuntu.com/manpages/noble/en/man1/ecryptfs-setup-private.1.html
- `pam_ecryptfs(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/pam_ecryptfs.8.html
- fscrypt userspace tool — https://github.com/google/fscrypt
- cryptmount — https://cryptmount.sourceforge.net/
- gocryptfs — https://nuetzlich.net/gocryptfs/

**Network-bound disk encryption**
- Clevis — https://github.com/latchset/clevis
- Tang — https://github.com/latchset/tang
- Red Hat, *Configuring automated unlocking of encrypted volumes using policy-based decryption* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/configuring-automated-unlocking-of-encrypted-volumes-using-policy-based-decryption_security-hardening

**Standards**
- NIST SP 800-38E, *XTS-AES Mode for Confidentiality on Storage Devices* — https://csrc.nist.gov/pubs/sp/800/38/e/final
- RFC 9106, *Argon2 Memory-Hard Function for Password Hashing and Proof-of-Work* — https://www.rfc-editor.org/rfc/rfc9106.html
- RFC 8018, *PKCS #5: Password-Based Cryptography Specification v2.1* — https://www.rfc-editor.org/rfc/rfc8018.html
- NIST SP 800-88r1, *Guidelines for Media Sanitization* (cryptographic erase) — https://csrc.nist.gov/pubs/sp/800/88/r1/final

**Vendor and community guidance**
- Red Hat, *Encrypting block devices using LUKS* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/encrypting-block-devices-using-luks_security-hardening
- Debian, *Disk encryption* — https://wiki.debian.org/DiskEncryption
- Arch Linux wiki, *dm-crypt* (community reference, unusually thorough) — https://wiki.archlinux.org/title/Dm-crypt
- Cloudflare, *Speeding up Linux disk encryption* (origin of the workqueue-bypass flags) — https://blog.cloudflare.com/speeding-up-linux-disk-encryption/
- OpenZFS, *Encryption* — https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html#encryption