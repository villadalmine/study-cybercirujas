# LPIC-1 · Thema 1.1 — Systemarchitektur

**Prüfung:** 101-500 (LPIC-1 v5.0) · **Abgedeckte Ziele:** 101.1, 101.2, 101.3 · **Gewichtung:** 10

---

## 1. Motivation: das architektonische Problem

Jedes andere Subsystem, das Sie jemals betreiben werden — die Container-Runtime, das kubelet, die Datenbank, der Service-Mesh — läuft *innerhalb* einer Maschine, die etwas anderes zum Leben erwecken musste. Dieses "etwas andere" ist der einzige Codepfad im Stack **ohne Supervisor, ohne Retry-Loop und ohne Observability-Ebene**. Wenn `containerd` abstürzt, startet systemd es neu und Prometheus informiert Sie. Wenn die initramfs das Root-Dateisystem nicht finden kann, gibt es kein systemd, kein Journal, keinen Metrik-Endpunkt, kein SSH — es gibt nur einen `dracut:/#`-Prompt auf einer seriellen Konsole, die Sie möglicherweise nicht verkabelt haben.

Der konkrete Produktionsausfall, den dieses Thema verhindern soll, sieht so aus:

> Ein 240-Knoten-Bare-Metal-Kubernetes-Cluster führt unbeaufsichtigt `dnf upgrade` in einem Wartungsfenster aus. Das neue Kernel-Paket regeneriert die initramfs. Auf 19 Knoten wurde das multipath-Modul vor Jahren von einem inzwischen ausgeschiedenen Ingenieur über `/etc/modprobe.d/local.conf` auf die Blacklist gesetzt, sodass die neue initramfs *ohne* `dm-multipath` erstellt wird. Diese Knoten booten neu, können das SAN-gestützte Root-LV nicht zusammensetzen und fallen in die dracut-Notfallshell. Der Cluster verliert 8 % seiner Kapazität, die Pods werden neu geplant, die verbleibenden Knoten geraten unter Speicherdruck, und der Vorfall wird nun zu einem kaskadierenden Ausfall. Nichts im Bootpfad hat auch nur eine einzige Metrik ausgegeben.

Drei architektonische Eigenschaften ergeben sich aus dieser Geschichte, und genau diese kodieren die Ziele 101.1–101.3:

| Eigenschaft | Frage, die sie beantwortet | Ziel |
|---|---|---|
| **Hardware-Erkennung ist dynamisch** | Wie erfährt der Kernel, dass ein Gerät existiert, und wie benennen/konfigurieren Sie es deterministisch? | 101.1 |
| **Die Boot-Kette ist eine Übergabesequenz ohne Rollback** | Welche Komponente besitzt die Maschine zum Zeitpunkt *t*, was übergibt sie, und wo protokolliert sie? | 101.2 |
| **Zustandsübergänge müssen absichtlich und ausleerbar sein** | Wie bewegen Sie eine laufende Maschine zwischen Service-Ebenen oder fahren sie herunter, ohne den Zustand zu beschädigen? | 101.3 |

Der Rest dieses Dokuments behandelt den Bootpfad als **verteiltes System mit fünf sequenziellen Eigentümern**, jeder mit seinem eigenen Konfigurationsspeicher, seiner eigenen Fehlerfläche und seinem eigenen Debug-Kanal.

---

## 2. Die Boot-Kette, von Anfang bis Ende

```
┌──────────┐   ┌──────────────┐   ┌────────┐   ┌───────────┐   ┌────────┐
│ Firmware │──▶│ Boot loader  │──▶│ Kernel │──▶│ initramfs │──▶│ PID 1  │
│ BIOS/UEFI│   │ GRUB2/sd-boot│   │ vmlinuz│   │  (dracut) │   │systemd │
└──────────┘   └──────────────┘   └────────┘   └───────────┘   └────────┘
  NVRAM /        grub.cfg /         cmdline      /init,          units,
  CMOS           loader/entries     modules      switch_root     targets

  ▲ no logs      ▲ no logs          ▲ dmesg      ▲ dmesg+rdsosreport  ▲ journald
```

Jeder Pfeil ist eine **irreversible Übergabe**. Der Zustand des Vorgängers (Speicherzuordnung, Device-Tree, Befehlszeile) wird weitergegeben; der Vorgänger selbst wird verworfen. Deshalb können Sie den "Boot-Loader nicht neu starten" — Sie können nur einen Reboot durchführen.

### 2.1 Phase 1 — Firmware

Die Firmware führt POST durch, initialisiert den Speicher-Controller, und muss dann ausführbaren Code auf einem persistenten Speicher finden. Dafür gibt es zwei grundlegend unterschiedliche Verträge.

**Legacy BIOS.** Die Firmware liest **LBA 0** (die ersten 512 Byte) des Boot-Geräts in den Speicher an Adresse `0x7C00` und springt im 16-Bit-Real-Mode dorthin. Dieser 512-Byte-MBR ist wie folgt aufgebaut:

| Offset | Größe | Inhalt |
|---|---|---|
| `0x000` | 446 B | Bootstrap-Code (GRUB `boot.img`) |
| `0x1BE` | 64 B | Partitionstabelle — 4 primäre Einträge × 16 B |
| `0x1FE` | 2 B | Boot-Signatur `0x55 0xAA` |

446 Byte reichen nicht für einen Dateisystemtreiber, daher speichert GRUB `core.img` anderswo: in der **Post-MBR-Lücke** (MBR-partitionierte Festplatten) oder in einer dedizierten **BIOS Boot Partition** (`ef02`, GUID `21686148-6449-6E6F-744E-656564454649`) auf GPT-Festplatten. Diese Partition zu vergessen ist die häufigste Ursache für "GPT-Festplatte installiert einwandfrei, dann `Missing operating system`".

**UEFI.** Die Firmware enthält einen FAT-Treiber, liest die **EFI System Partition** (ESP, Typ `ef00`, GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`) und führt eine PE/COFF-Binärdatei im 64-Bit-Modus aus. Welche Binärdatei ausgewählt wird, kommt aus **NVRAM-Boot-Variablen**, nicht von der Festplatte — ein zustandsbehaftete, maschinenspezifische Konfiguration, die einen Festplattenaustausch überlebt und bei einem Hauptplatinenaustausch *verloren* geht.

```console
$ ls /sys/firmware/efi
config_table  efivars  esrt  fw_platform_size  fw_vendor  runtime  runtime-map  systab
```

> **Diagnoseregel:** Die Existenz von `/sys/firmware/efi` ist der maßgebliche Test für "läuft ich unter UEFI". `dmidecode` wird es Ihnen nicht sagen; `efibootmgr` wird einfach fehlschlagen.

```console
$ efibootmgr -v
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0003,0000
Boot0000* UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0001* rocky	HD(1,GPT,3f2a9c11-7b04-4f7e-9a1d-2c8f5b0e11aa,0x800,0x12c000)/File(\EFI\rocky\shimx64.efi)
Boot0003* UEFI PXEv4 (MAC:5254001a2b3c)	PciRoot(0x0)/Pci(0x2,0x0)/MAC(5254001a2b3c,1)/IPv4(0.0.0.0,0,0)
```

Secure Boot fügt eine Signaturverifizierungskette ein: Firmware → `shimx64.efi` (signiert von Microsofts UEFI-CA) → `grubx64.efi` (signiert von der Distribution) → Kernel (signiert von der Distribution). Out-of-tree-Module (NVIDIA, DKMS, einige CNI-Datapath-Module) müssen dann mit einem bei `mokutil` registrierten **Machine Owner Key** signiert werden.

```console
$ mokutil --sb-state
SecureBoot enabled

$ mokutil --list-enrolled | head -n 5
[key 1]
SHA1 Fingerprint: 5d:c8:9f:...:2a
Certificate:
    Data:
        Version: 3 (0x2)
```

**Kompromisse:**

| Dimension | Legacy BIOS + MBR | UEFI + GPT |
|---|---|---|
| Max. adressierbare Festplatte | 2 TiB (32-Bit-LBA) | 8 ZiB (64-Bit-LBA) |
| Primäre Partitionen | 4 (erweitert/logischer Hack darüber hinaus) | Standardmäßig 128, kein Erweiterungskonzept |
| Standort des Boot-Codes | 446 B MBR + Lücke/`ef02`-Partition | Dateien auf einer FAT32-ESP |
| Boot-Eintragsstatus | Nur festplattenresident | Festplatte **und** NVRAM (`efibootmgr`) |
| Vertrauenskette | Keine | Secure Boot (shim → MOK) |
| Multi-OS-Koexistenz | Bootloader muss chainloaden | Firmware-Menü wählt nativ aus |
| Redundanz der Partitionstabelle | Keine | Primär + Backup GPT-Header/CRC32 |
| Wiederherstellungskomplexität | 446 B neu schreiben | ESP-Dateien **und** NVRAM-Variablen wiederherstellen |
| Netzwerk-Boot | PXE via Option-ROM | HTTP(S)-Boot, PXE, native Treiber-Stacks |
| Typische Fleet-Rolle | Legacy-/Edge-Appliances | Alles Aktuelle; erforderlich für Secure Boot |

**Architektenentscheidung:** Für jede Fleet, die Sie voraussichtlich >3 Jahre betreiben, ist UEFI + GPT nicht optional — Secure Boot und Boot-Geräte >2 TiB sind beide harte Anforderungen. Kalkulieren Sie die operativen Kosten: NVRAM ist ein zustandsbehaftetes Chassis-spezifisches Element, das Ihre Provisioning-Automatisierung wiederherstellen können muss (`efibootmgr -c`), sonst wird eine ausgetauschte Hauptplatine zu einem nicht bootbaren Knoten.

### 2.2 Phase 2 — Boot-Loader

Die Aufgabe des Boot-Loaders ist eng gefasst: `vmlinuz` und `initramfs` in den RAM laden, die **Kernel-Befehlszeile** zusammenstellen, die Boot-Protokoll-Struktur befüllen und zum Kernel-Einstiegspunkt springen.

**GRUB2** ist der universelle Standard. Seine kritische architektonische Eigenschaft ist, dass **`grub.cfg` generiert, niemals von Hand bearbeitet wird**:

| Distributionsfamilie | Generator | Vorlagen-Eingaben | Ausgabe |
|---|---|---|---|
| Debian/Ubuntu | `update-grub` (Wrapper für `grub-mkconfig`) | `/etc/default/grub`, `/etc/grub.d/*` | `/boot/grub/grub.cfg` |
| RHEL/Rocky/Alma/Fedora | `grub2-mkconfig` | `/etc/default/grub`, `/etc/grub.d/*` | `/boot/grub2/grub.cfg` |
| RHEL 8+/Fedora (pro Kernel) | `grubby` | — | `/boot/loader/entries/*.conf` (BLS) |
| SUSE | `grub2-mkconfig` | `/etc/default/grub` | `/boot/grub2/grub.cfg` |

Systeme der Red-Hat-Familie verwenden seit RHEL 8 die **Boot Loader Specification (BLS)**: eine kleine Datei pro installiertem Kernel unter `/boot/loader/entries/`, sodass die Installation eines Kernels nicht mehr die gesamte `grub.cfg` neu schreibt.

```console
$ cat /boot/loader/entries/3f2a9c117b044f7e9a1d2c8f5b0e11aa-5.14.0-427.el9.x86_64.conf
title Rocky Linux (5.14.0-427.el9.x86_64) 9.4 (Blue Onyx)
version 5.14.0-427.el9.x86_64
linux /vmlinuz-5.14.0-427.el9.x86_64
initrd /initramfs-5.14.0-427.el9.x86_64.img
options root=/dev/mapper/rl-root ro crashkernel=1G-4G:192M rd.lvm.lv=rl/root rd.lvm.lv=rl/swap
grub_users $grub_users
grub_arg --unrestricted
grub_class rocky
```

Die Befehlszeile flottenweit korrekt ändern, je nach Familie:

```console
# RHEL-Familie — aktualisiert jeden BLS-Eintrag, keine vollständige Neugenerierung
$ sudo grubby --update-kernel=ALL --args="net.ifnames=0 transparent_hugepage=never"
$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.el9.x86_64"
args="ro crashkernel=1G-4G:192M rd.lvm.lv=rl/root net.ifnames=0 transparent_hugepage=never"
root="/dev/mapper/rl-root"
initrd="/boot/initramfs-5.14.0-427.el9.x86_64.img"
title="Rocky Linux (5.14.0-427.el9.x86_64) 9.4 (Blue Onyx)"
id="3f2a9c117b044f7e9a1d2c8f5b0e11aa-5.14.0-427.el9.x86_64"
```

```console
# Debian-Familie — Vorlage bearbeiten, dann neu generieren
$ sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet net.ifnames=0"/' /etc/default/grub
$ sudo update-grub
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-45-generic
Found initrd image: /boot/initrd.img-6.8.0-45-generic
done
```

Wichtige `/etc/default/grub`-Direktiven:

| Direktive | Wirkung | Produktionshinweis |
|---|---|---|
| `GRUB_TIMEOUT` | Menü-Wartezeit in Sekunden | `0` in der Cloud, `5` auf Bare Metal — Sie benötigen das Menü, wenn es keine andere Konsole gibt |
| `GRUB_DEFAULT` | Index, Titel oder `saved` | Verwenden Sie `saved` + `grub-set-default` für atomare A/B-Kernel-Beförderung |
| `GRUB_CMDLINE_LINUX` | Argumente für **alle** Einträge, einschließlich Recovery | Persistente Optimierungen hier eintragen |
| `GRUB_CMDLINE_LINUX_DEFAULT` | Argumente nur für normale Einträge | `quiet`/`splash` hier eintragen |
| `GRUB_DISABLE_RECOVERY` | Single-User-Einträge unterdrücken | Niemals `true` auf Bare Metal |
| `GRUB_TERMINAL` | `console`, `serial` oder beides | `serial` ist für kopflose Fleets obligatorisch |
| `GRUB_SERIAL_COMMAND` | Serielle Leitungsparameter | Muss genau zu Ihren BMC/SOL-Einstellungen passen |
| `GRUB_ENABLE_BLSCFG` | BLS-Einträge verwenden (RH-Familie) | Auf `true` lassen; `false` kehrt zu monolithischer `grub.cfg` zurück |

Boot-Loader-Vergleich:

| | GRUB2 | systemd-boot | EFI-Stub (direkt) | U-Boot |
|---|---|---|---|---|
| Firmware-Unterstützung | BIOS + UEFI + andere | Nur UEFI | Nur UEFI | Embedded/ARM |
| Konfigurationsformat | Generiertes Shell-ähnliches Skript | `.conf` pro Eintrag, BLS | Nur NVRAM-Eintrag | Umgebungsvariablen / FIT-Image |
| Dateisystemtreiber | Umfangreich (ext, XFS, Btrfs, LVM, LUKS, ZFS) | Nur ESP FAT | Nur ESP FAT | Mehrere |
| Verschlüsseltes `/boot` | Ja (LUKS1, LUKS2 teilweise) | Nein | Nein | Nein |
| Komplexität / Angriffsfläche | Hoch | Niedrig | Minimal | Mittel |
| Interaktive Rescue-Shell | Ja (`grub>`) | Begrenzt | Nein | Ja |
| Typische Verwendung | Allzweck, alle Distributionen | Minimal/unveränderliche UEFI-Hosts | Unified Kernel Images, vertrauliche VMs | SBCs, Appliances |

**Architektenentscheidung:** GRUB2, außer Sie bauen ein unveränderliches, nur-UEFI, measured-boot-Image — in diesem Fall eliminiert ein **Unified Kernel Image** (Kernel + initramfs + cmdline in einer signierten PE-Binärdatei, gebootet vom EFI-Stub) den Angriff mit "unsignierter Befehlszeile" und entfernt eine ganze Komponente aus der Kette.

### 2.3 Phase 3 — Kernel

Der Kernel dekomprimiert sich selbst, richtet das Paging ein, initialisiert integrierte Treiber und mountet die initramfs als `tmpfs`-Root. Alles, was ihm mitgeteilt wurde, befindet sich an einer Stelle:

```console
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro \
crashkernel=1G-4G:192M rd.lvm.lv=rl/root net.ifnames=0 transparent_hugepage=never
```

> `/proc/cmdline` ist die maßgebliche Wahrheit. Wenn ein `sysctl`-artiges Tuning "nicht angewendet wird", prüfen Sie hier, bevor Sie irgendetwas anderes prüfen — ein `grubby`/`update-grub`-Lauf, dem kein Reboot folgte, ist die häufigste Ursache.

Wesentliche Befehlszeilenparameter für den Betrieb:

| Parameter | Zweck |
|---|---|
| `root=UUID=… \| /dev/mapper/…` | Reales Root-Gerät für `switch_root` |
| `ro` / `rw` | Anfänglicher Mount-Modus des Root (fsck läuft bei `ro`) |
| `init=/bin/bash` | PID 1 ersetzen — die letzte Rettung für Passwort-/`fstab`-Recovery |
| `systemd.unit=rescue.target` | Zu einem bestimmten Target booten |
| `rd.break[=pre-mount\|mount\|pre-pivot]` | In eine Shell *innerhalb* von dracut in einer gewählten Stufe wechseln |
| `rd.debug` / `debug` | Ausführliches initramfs- und Kernel-Logging |
| `nomodeset` | KMS deaktivieren — GPU-/Konsolen-Fehlersuche |
| `net.ifnames=0 biosdevname=0` | Zurück zu `eth0`-artigen Namen |
| `console=ttyS0,115200n8 console=tty0` | Serielle Konsole; das **letzte** `console=` erhält `/dev/console` |
| `systemd.log_level=debug` | Ausführliches PID 1 |
| `crashkernel=…` | Speicher für den kdump-Capture-Kernel reservieren |

Das frühe Kernel-Log ist der einzige Diagnosekanal in dieser Phase:

```console
$ sudo dmesg -T --level=err,warn | head
[Wed Aug  5 09:14:02 2026] ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PCI0.SAT0], AE_NOT_FOUND
[Wed Aug  5 09:14:03 2026] i40e 0000:3b:00.0: Error I40E_AQ_RC_ENOSPC adding RX filters
[Wed Aug  5 09:14:05 2026] EXT4-fs (sda3): mounted filesystem with ordered data mode
```

### 2.4 Phase 4 — initramfs

Die initramfs ist ein **komprimiertes cpio-Archiv**, das einen minimalen Userspace enthält, dessen einziger Zweck es ist, das reale Root-Dateisystem mountbar zu machen: Speichertreiber laden, MD/LVM/multipath zusammensetzen, LUKS entsperren, Netzwerk für NFS/iSCSI-Root aktivieren. Es endet mit `switch_root`, das das tmpfs-Root durch das reale ersetzt und `/sbin/init` per `exec` startet.

| | dracut (RHEL, SUSE, Fedora, Arch) | initramfs-tools (Debian, Ubuntu) |
|---|---|---|
| Konfiguration | `/etc/dracut.conf`, `/etc/dracut.conf.d/*.conf` | `/etc/initramfs-tools/initramfs.conf`, `conf.d/`, `modules` |
| Neu erstellen | `dracut -f`, `dracut -f --regenerate-all` | `update-initramfs -u -k all` |
| Inspizieren | `lsinitrd /boot/initramfs-$(uname -r).img` | `lsinitramfs /boot/initrd.img-$(uname -r)` |
| Inhaltsrichtlinie | `hostonly=yes` (Standard) — nur die Treiber dieses Hosts | Gesteuert durch `MODULES=most\|dep\|list\|netboot` |
| Erweiterbarkeit | Module unter `/usr/lib/dracut/modules.d/` | Hooks in `/etc/initramfs-tools/{hooks,scripts}/` |
| Debug-Break | `rd.break=<Stufe>`, `rd.debug` | `break=<Stufe>`, `debug` |
| Größe (typisch) | 30–45 MB host-only, 90 MB+ generisch | 40–80 MB |

`hostonly=yes` ist die Falle im Eingangsszenario: ein auf einem Hardwareprofil erstelltes Image wird auf einem anderen nicht booten. Golden Images und jeder Host, dessen Speicher-Controller sich ändern könnte, benötigen `hostonly=no`.

```console
$ lsinitrd /boot/initramfs-5.14.0-427.el9.x86_64.img | grep -E 'multipath|dm-mod|nvme'
drwxr-xr-x   2 root     root            0 Aug  5 09:02 usr/lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/md/dm-multipath.ko.xz
-rw-r--r--   1 root     root        41236 Aug  5 09:02 usr/lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/nvme/host/nvme.ko.xz

$ lsinitrd -f /etc/cmdline.d/90lvm.conf /boot/initramfs-5.14.0-427.el9.x86_64.img
rd.lvm.lv=rl/root rd.lvm.lv=rl/swap
```

```console
# Aufnahme unabhängig von der Host-only-Erkennung erzwingen, dann jeden Kernel neu erstellen
$ printf 'add_drivers+=" dm-multipath dm-round-robin nvme_tcp "\n' | sudo tee /etc/dracut.conf.d/99-storage.conf
$ sudo dracut -f --regenerate-all -v
dracut: Executing: /usr/bin/dracut -f --regenerate-all -v
dracut: *** Including module: dm ***
dracut: *** Including module: multipath ***
dracut: *** Creating image file '/boot/initramfs-5.14.0-427.el9.x86_64.img' ***
dracut: *** Creating initramfs image file '/boot/initramfs-5.14.0-427.el9.x86_64.img' done ***
```

### 2.5 Phase 5 — PID 1

`switch_root` startet PID 1 per `exec`, das für den Rest der Betriebszeit die Maschine besitzt.

| | SysVinit | Upstart | systemd |
|---|---|---|---|
| Modell | Sequenzielle Shell-Skripte | Ereignisgesteuert | Abhängigkeitsgraph, parallel |
| Konfiguration | `/etc/inittab`, `/etc/init.d/`, `rc?.d/` | `/etc/init/*.conf` | Unit-Dateien (`.service`, `.target`, …) |
| Reihenfolge | Numerische Präfixe `S20`, `K80` | Ereignisemission | `Before=`/`After=`/`Requires=`/`Wants=` |
| Service-Zustandsmodell | PID-Dateien, Best-Effort | PID-Tracking | cgroup-basiert — **maßgebend** |
| Boot-Zeit (typischer Server) | 60–120 s | 30–60 s | 8–25 s |
| Logging | Nur syslog | syslog | journald, strukturiert, indiziert |
| Socket-/D-Bus-Aktivierung | Nein | Teilweise | Ja |
| Ressourcenkontrolle | Externes `ulimit` | Extern | Native cgroup-v2-Delegation |
| Status | Legacy, noch auf einigen Appliances | Faktisch tot | Universeller Standard |

Die cgroup-basierte Verfolgung ist die Eigenschaft, die operativ zählt: SysVinit konnte einen doppelt forkenden Daemon verlieren und Orphans zurücklassen; systemd kann das nicht, weil jeder von einer Unit erzeugte Prozess in der cgroup dieser Unit verbleibt und `KillMode` den gesamten Slice erntet.

```console
$ systemd-analyze
Startup finished in 2.114s (kernel) + 5.882s (initrd) + 10.446s (userspace) = 18.442s
graphical.target reached after 10.398s in userspace.

$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

graphical.target @10.398s
└─multi-user.target @10.397s
  └─kubelet.service @9.204s +1.190s
    └─containerd.service @8.771s +425ms
      └─network-online.target @8.766s
        └─NetworkManager-wait-online.service @2.910s +5.854s
          └─NetworkManager.service @2.611s +291ms
            └─basic.target @2.600s
```

Diese Ausgabe ist ein reales Ergebnis: `NetworkManager-wait-online.service` macht 5,85 s der 10,4 s Userspace-Bootzeit aus. Bei einer Fleet mit rollenden Neustarts sind das Minuten kumulierter Nichtverfügbarkeit, behebbar durch Einschränkung des Wartens auf die tatsächlich relevanten Schnittstellen.

---

## 3. Runlevels, Targets und kontrolliertes Herunterfahren (101.3)

### 3.1 Die Zuordnung, die Sie auswendig kennen müssen

| SysV-Runlevel | systemd-Target | Bedeutung |
|---|---|---|
| 0 | `poweroff.target` | Anhalten und Ausschalten |
| 1, `s`, `S` | `rescue.target` | Single-User, lokales FS gemountet, kein Netzwerk |
| 2 | `multi-user.target` | Debian: Multi-User ohne Netzwerk (historisch) |
| 3 | `multi-user.target` | Multi-User, mit Netzwerk, textbasiert — **das Server-Target** |
| 4 | `multi-user.target` | Ungenutzt / standortspezifisch definiert |
| 5 | `graphical.target` | Multi-User + Display-Manager |
| 6 | `reboot.target` | Neustart |
| — | `emergency.target` | Root-FS **nur lesend** gemountet, nur `/bin/sh`; unterhalb von rescue |
| — | `default.target` | Symlink zu dem Target, das standardmäßig gebootet wird |

Unter SysVinit befindet sich der Standard in `/etc/inittab` (`id:3:initdefault:`); unter systemd ist es ein Symlink.

```console
$ systemctl get-default
multi-user.target

$ ls -l /etc/systemd/system/default.target
lrwxrwxrwx. 1 root root 41 Jul 12 16:20 /etc/systemd/system/default.target -> /usr/lib/systemd/system/multi-user.target

$ sudo systemctl set-default multi-user.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target
```

Die Legacy-Befehle funktionieren weiterhin und sind weiterhin prüfungsrelevant:

```console
$ runlevel
N 3
$ who -r
         run-level 3  2026-08-05 09:14
```

`N` bedeutet "kein vorheriger Runlevel" — das System bootete direkt in Runlevel 3 und wechselte nie den Zustand.

`systemctl isolate` ist das moderne `telinit N`: Es startet das benannte Target und **stoppt jede Unit, die es nicht benötigt**.

```console
$ sudo systemctl isolate rescue.target      # equivalent to: telinit 1
$ sudo systemctl isolate multi-user.target  # equivalent to: telinit 3
```

> **Produktionswarnung:** `isolate` auf einem laufenden Knoten stoppt Units, die das Target nicht mit einbezieht. Das Ausführen von `systemctl isolate multi-user.target` auf einer grafischen Workstation beendet die Sitzung; auf einem Kubernetes-Knoten mit einer manuell gestarteten Unit außerhalb des Abhängigkeitsgraphen wird auch diese beendet. Nur Units mit `AllowIsolate=yes` können Isolate-Targets sein — deshalb schlägt `systemctl isolate sshd.service` fehl.

### 3.2 Semantik des Herunterfahrens

```console
$ sudo shutdown -h +10 "Kernel maintenance — draining now, back at 03:20 UTC"

Broadcast message from root@node-17 (Wed 2026-08-05 03:05:00 UTC):

Kernel maintenance — draining now, back at 03:20 UTC
The system is going down for poweroff at Wed 2026-08-05 03:15:00 UTC!
```

Zwei operativ relevante Nebeneffekte eines geplanten `shutdown`:

1. `/run/nologin` wird ~5 Minuten vor dem Zeitpunkt erstellt, was neue Nicht-Root-Anmeldungen über PAM blockiert.
2. Ein Shutdown-**Job** wird in die Warteschlange gestellt und ist abbrechbar.

```console
$ sudo shutdown -c
Broadcast message from root@node-17 (Wed 2026-08-05 03:07:41 UTC):

The system shutdown has been cancelled at Wed 2026-08-05 03:08:41 UTC!
```

| Befehl | Wirkung | Sync/Unmount? | Hinweise |
|---|---|---|---|
| `shutdown -h now` | Anhalten (meist Ausschalten) | Ja | Kanonische Form; unterstützt Zeitangaben und Nachrichten |
| `shutdown -r +5` | Neustart in 5 Min. | Ja | Sendet eine `wall`-Nachricht |
| `shutdown -c` | Ausstehendes Herunterfahren abbrechen | — | Nur für geplante Jobs |
| `halt` | CPU anhalten, kann eingeschaltet bleiben | Ja | `-p` zum Ausschalten |
| `poweroff` | Ausschalten via ACPI | Ja | `systemctl poweroff` |
| `reboot` | Warmstart | Ja | `systemctl reboot` |
| `reboot -f` / `--force --force` | Sofortiger `reboot(2)`-Syscall | **Nein** | Datenverlustrisiko; letztes Mittel |
| `systemctl kexec` | Sprung zu einem vorgeladenen Kernel | Ja | Überspringt Firmware/POST — Sekunden statt Minuten |
| `telinit 6` | Legacy-Neustart | Ja | Kompatibilitätsschicht zu systemd |

**kexec** ist der Hebel für Fleet-Skalierung: Auf Servern, bei denen POST + Option-ROM-Init 3–5 Minuten dauert, startet `kexec` in unter 20 Sekunden in einen neuen Kernel neu. Der Preis ist, dass Firmware und Hardware *nicht* neu initialisiert werden, sodass es keinen hängenden HBA wiederherstellen und keine Firmware-Updates anwenden kann.

```console
$ sudo kexec -l /boot/vmlinuz-5.14.0-427.el9.x86_64 \
      --initrd=/boot/initramfs-5.14.0-427.el9.x86_64.img --reuse-cmdline
$ sudo systemctl kexec
```

### 3.3 Inhibitoren — wie man ein Herunterfahren warten lässt

`systemd-inhibit` ist der unterstützte Mechanismus für "Nicht neu starten, während ich mitten in einer Transaktion bin". Alles, was vor Stromausfall abgeschlossen sein muss, sollte eine Sperre halten, anstatt sich allein auf die Unit-Reihenfolge zu verlassen.

```console
$ systemd-inhibit --list
WHO                          UID  USER  PID   COMM            WHAT                                   WHY                                MODE
NetworkManager               0    root  1204  NetworkManager  sleep                                  NetworkManager needs to turn off…  delay
etcd-defrag.sh               0    root  88231 systemd-inhibi  shutdown:sleep:idle                    etcd compaction in progress        block

2 inhibitors listed.
```

```console
$ sudo systemd-inhibit --what=shutdown --who="etcd-defrag" \
      --why="etcd compaction in progress" --mode=block \
      /usr/local/bin/etcd-defrag.sh
```

Physische Power-/Deckel-Ereignisse sind Richtlinie, nicht Hardware-Schicksal — sie werden über `logind` geleitet:

```console
$ grep -E '^Handle|^Idle' /etc/systemd/logind.conf
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
```

`HandlePowerKey=ignore` auf Servern verhindert, dass ein versehentlicher Frontplatten-Druck — oder ein spuriöses ACPI-Ereignis von einem instabilen BMC — einen Knoten herunterfährt.

---

## 4. Hardware-Erkennung und -Konfiguration (101.1)

### 4.1 Die drei vom Kernel exportierten Namespaces

| Pfad | Backend | Semantik | Verwendung für |
|---|---|---|---|
| `/proc` | `procfs` | Prozess- + Legacy-Kernel-Schnittstellen | `cmdline`, `interrupts`, `cpuinfo`, `modules`, `ioports`, `dma` |
| `/sys` | `sysfs` | Objektmodell des Device-Trees | Moderne Geräteattribute, Treiberbindung, Tuning-Parameter |
| `/dev` | `devtmpfs` + `udev` | Geräteknoten und Symlinks | Tatsächliche I/O, persistente Benennung |
| `/run` | `tmpfs` | Flüchtiger Laufzeitzustand | Sockets, PID-Dateien, `nologin` |

```console
$ head -n 8 /proc/interrupts
           CPU0       CPU1       CPU2       CPU3
  0:         17          0          0          0   IO-APIC    2-edge      timer
  1:          0          0          9          0   IO-APIC    1-edge      i8042
  8:          0          0          0          1   IO-APIC    8-edge      rtc0
  9:          0          0          0          0   IO-APIC    9-fasteoi   acpi
 24:          0    1284471          0          0   PCI-MSI 1572864-edge   nvme0q0
 25:     882110          0          0          0   PCI-MSI 3670016-edge   i40e-eth0-TxRx-0
```

Dieser letzte Block ist ein Interrupt-Affinity-Befund: `nvme0q0` und `i40e-eth0-TxRx-0` sind an unterschiedliche CPUs gebunden. Auf einem latenzsensiblen Knoten würden Sie dies gegen Ihre `irqbalance`-Richtlinie und die NUMA-Lokalität des PCIe-Root-Ports überprüfen.

```console
$ cat /proc/ioports | head -n 6
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0070-0071 : rtc0
```

`/proc/ioports` und `/proc/dma` sind die modernen Überreste der ISA-Ära und bleiben prüfungsrelevant: I/O-Ports sind ein 16-Bit-Adressraum für portgemappte I/O, und Legacy-DMA-Kanäle sind eine knappe, statisch zugewiesene Ressource. Auf PCIe-Hardware haben MSI/MSI-X und Bus-Mastering-DMA beide ersetzt, weshalb `/proc/dma` auf jedem aktuellen Server nahezu leer ist.

### 4.2 Das Erkennungs-Toolkit

```console
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         46 bits physical, 48 bits virtual
  Byte Order:            Little Endian
CPU(s):                  64
  On-line CPU(s) list:   0-63
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
    Thread(s) per core:  2
    Core(s) per socket:  16
    Socket(s):           2
NUMA:
  NUMA node(s):          2
  NUMA node0 CPU(s):     0-15,32-47
  NUMA node1 CPU(s):     16-31,48-63
Vulnerabilities:
  Mds:                   Not affected
  Spectre v2:            Mitigation; Enhanced IBRS, IBPB conditional, RSB filling
```

```console
$ lspci -nnk | grep -A3 -i ethernet
3b:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0007]
	Kernel driver in use: i40e
	Kernel modules: i40e
```

Das `[8086:1572]`-Vendor:Device-Paar ist der Primärschlüssel des gesamten Treiberbindungsproblems: Es ist das, gegen was `modprobe` Modul-Aliase abgleicht, mit dem Sie Vendor-Firmware-Matrizen durchsuchen und wogegen Sie Bugs melden.

```console
$ lsusb -t
/:  Bus 02.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 2: Dev 2, If 0, Class=Mass Storage, Driver=usb-storage, 5000M
/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/16p, 480M
    |__ Port 5: Dev 3, If 0, Class=Human Interface Device, Driver=usbhid, 1.5M

$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
NAME          SIZE TYPE FSTYPE      MOUNTPOINTS       MODEL
nvme0n1     894.3G disk                               SAMSUNG MZQL2960HCJR-00A07
├─nvme0n1p1     1G part vfat        /boot/efi
├─nvme0n1p2     1G part xfs         /boot
└─nvme0n1p3   892G part LVM2_member
  ├─rl-root    70G lvm  xfs         /
  ├─rl-swap     4G lvm  swap        [SWAP]
  └─rl-var    818G lvm  xfs         /var

$ sudo dmidecode -t system | sed -n '4,12p'
System Information
	Manufacturer: Dell Inc.
	Product Name: PowerEdge R650
	Version: Not Specified
	Serial Number: J7K2M93
	UUID: 4c4c4544-0037-4b10-8032-b7c04f4d3933
	Wake-up Type: Power Switch
	SKU Number: SKU=NotProvided;ModelName=PowerEdge R650
	Family: PowerEdge
```

`dmidecode` liest SMBIOS-Tabellen aus der Firmware — so erfährt die Automatisierung Chassis-Seriennummer und Modell ohne Inventar-API, und so leitet `systemd` den `Hardware Vendor`/`Model` der Maschine in `hostnamectl` ab.

### 4.3 Kernel-Module: die Bindungsschicht

```console
$ lsmod | head -n 6
Module                  Size  Used by
nf_conntrack          200704  4 xt_conntrack,nf_nat,xt_MASQUERADE,nf_conntrack_netlink
overlay               172032  86
i40e                  581632  0
dm_multipath           45056  2 dm_service_time
nvme                   61440  3
nvme_core             204800  5 nvme

$ modinfo i40e | head -n 8
filename:       /lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.xz
version:        2.22.20
license:        GPL v2
description:    Intel(R) Ethernet Connection XL710 Network Driver
alias:          pci:v00008086d00001572sv*sd*bc*sc*i*
depends:        
retpoline:      Y
parms:          debug:Debug level (0=none,...,16=all), Debug mask (0x8XXXXXXX) (uint)
```

Modulverwaltungsfläche:

| Datei / Verzeichnis | Zweck | Angewendet durch |
|---|---|---|
| `/etc/modules-load.d/*.conf` | Diese Module beim Boot laden (eines pro Zeile) | `systemd-modules-load.service` |
| `/etc/modprobe.d/*.conf` | `options`, `alias`, `blacklist`, `install` | `modprobe` zur Ladezeit |
| `/lib/modules/$(uname -r)/modules.dep` | Abhängigkeitsgraph | Generiert von `depmod` |
| `/etc/modules` (Debian) | Legacy-Lade-beim-Boot-Liste | `kmod`-Init-Skript |

Die **Blacklist-Falle**, es lohnt sich, sie sich zu merken, denn sie produziert "Ich habe es auf die Blacklist gesetzt und es hat trotzdem geladen":

```console
# blacklist: verhindert nur ALIAS-basiertes Autoloading.
# Das Modul wird weiterhin durch expliziten `modprobe` oder als Abhängigkeit eines anderen Moduls geladen.
$ cat /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0

# install <mod> /bin/false: die harte Blockade. modprobe führt diesen Befehl aus, anstatt zu laden.
$ cat /etc/modprobe.d/hard-block-firewire.conf
install firewire_ohci /bin/false
install firewire_core /bin/false
```

Da `/etc/modprobe.d` beim Erstellen der initramfs *konsumiert* wird, erfordert jede Änderung dort einen Neuaufbau der initramfs, damit sie sich auf den frühen Boot auswirkt:

```console
$ sudo dracut -f --regenerate-all          # RHEL family
$ sudo update-initramfs -u -k all          # Debian family
```

Dies ist genau der Fehler aus §1: eine `blacklist`-Zeile hat die Menge der Treiber verändert, die dracut in das Host-Only-Image eingebettet hat.

### 4.4 udev: vom Kernel-uevent zum stabilen Namen

Der Kernel gibt bei der Geräteerkennung ein `uevent` aus; `systemd-udevd` empfängt es über netlink, gleicht Regeln ab und erstellt Knoten, Symlinks und Eigenschaften in `/dev`.

Regel-Priorität: `/etc/udev/rules.d/` **überschreibt** `/run/udev/rules.d/`, was `/usr/lib/udev/rules.d/` überschreibt (gleicher Dateiname gewinnt). Dateien werden in lexikalischer Reihenfolge über alle Verzeichnisse hinweg verarbeitet.

```console
$ udevadm info --query=all --name=/dev/nvme0n1 | head -n 12
P: /devices/pci0000:00/0000:00:1d.0/0000:65:00.0/nvme/nvme0/nvme0n1
N: nvme0n1
L: 0
S: disk/by-id/nvme-SAMSUNG_MZQL2960HCJR-00A07_S64HNE0R500123
S: disk/by-path/pci-0000:65:00.0-nvme-1
E: DEVPATH=/devices/pci0000:00/0000:00:1d.0/0000:65:00.0/nvme/nvme0/nvme0n1
E: DEVNAME=/dev/nvme0n1
E: DEVTYPE=disk
E: ID_SERIAL=SAMSUNG_MZQL2960HCJR-00A07_S64HNE0R500123
E: ID_MODEL=SAMSUNG MZQL2960HCJR-00A07
E: ID_WWN=eui.34483045523030313233
E: SUBSYSTEM=block
```

```console
$ udevadm monitor --udev --property --subsystem-match=block
monitor will print the received events for:
UDEV - the event which udev sends out after rule processing

UDEV  [184213.005112] add      /devices/pci0000:00/.../block/sdb (block)
ACTION=add
DEVNAME=/dev/sdb
DEVTYPE=disk
ID_BUS=scsi
ID_SERIAL=36001405f2a9c1170b044f7e9
SUBSYSTEM=block
```

Eine Regel schreiben und testen, ohne Hardware zu berühren:

```console
$ sudo tee /etc/udev/rules.d/70-storage-tuning.rules >/dev/null <<'EOF'
# Stable symlink + I/O scheduler + queue depth for the SAN data LUN
SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_SERIAL}=="36001405f2a9c1170b044f7e9", \
  SYMLINK+="san/data0", OWNER="root", GROUP="disk", MODE="0660"

# NVMe: no I/O scheduler, deep queue — the device reorders better than we do
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", \
  ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023", \
  ATTR{queue/read_ahead_kb}="128"

# Rotational SAS behind multipath: deadline-style scheduler
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", \
  ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF

$ sudo udevadm control --reload-rules
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E 'ATTR|SYMLINK|Reading rules'
Reading rules file: /etc/udev/rules.d/70-storage-tuning.rules
ATTR '/sys/devices/.../nvme0n1/queue/scheduler' writing 'none'
ATTR '/sys/devices/.../nvme0n1/queue/nr_requests' writing '1023'

$ sudo udevadm trigger --subsystem-match=block --action=change
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq
```

**Vorhersagbare Netzwerkschnittstellennamen** sind das sichtbarste Produkt von udev. `systemd-udevd` leitet Namen von Firmware/Topologie ab statt von der Sondierungsreihenfolge, was den klassischen "`eth0` und `eth1` nach Neustart getauscht"-Ausfall eliminiert:

| Präfix | Herleitung | Beispiel |
|---|---|---|
| `eno` | Onboard-Index aus Firmware (SMBIOS/ACPI) | `eno1` |
| `ens` | PCI-Hotplug-Slot-Index | `ens3` |
| `enp` | PCI-Bus/Slot/Funktions-Geometrie | `enp59s0f0` |
| `enx` | MAC-Adresse | `enx5254001a2b3c` |
| `eth` | Kernel-Sondierungsreihenfolge — **nicht deterministisch** | `eth0` |

```console
$ udevadm test-builtin net_id /sys/class/net/enp59s0f0 2>/dev/null
ID_NET_NAMING_SCHEME=v252
ID_NET_NAME_MAC=enx3cecef1a2b3c
ID_NET_NAME_PATH=enp59s0f0
ID_NET_NAME_SLOT=ens1f0
```

Das Deaktivieren der vorhersagbaren Benennung (tun Sie dies nur, um Legacy-Konfigurationen zu erfüllen, die Sie nicht ändern können) erfordert **sowohl** `net.ifnames=0` auf der Befehlszeile **als auch** das Maskieren der Generator-Regel:

```console
$ sudo ln -sf /dev/null /etc/systemd/network/99-default.link
$ sudo grubby --update-kernel=ALL --args="net.ifnames=0 biosdevname=0"
$ sudo dracut -f --regenerate-all
```

### 4.5 Hot-Plug-Rescan ohne Neustart

```console
# Rescan every SCSI/SAS host for new LUNs — "channel target lun", '-' = wildcard
$ for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee "$h/scan" >/dev/null; done
$ sudo rescan-scsi-bus.sh -a          # sg3_utils, does the same plus resize handling

# Pick up a LUN that grew on the array side
$ echo 1 | sudo tee /sys/class/block/sdb/device/rescan

# Remove a device cleanly before the storage team unmaps it
$ echo 1 | sudo tee /sys/class/block/sdb/device/delete

$ sudo nvme list
Node          SN              Model                        Namespace Usage                      Format           FW Rev
------------- --------------- ---------------------------- --------- -------------------------- ---------------- --------
/dev/nvme0n1  S64HNE0R500123  SAMSUNG MZQL2960HCJR-00A07   1         960.20  GB / 960.20  GB    512   B +  0 B   GDC5302Q
```

---

## 5. Vollständige Infrastruktur-Manifeste

Dies sind die Artefakte, die alles Obige über eine Fleet hinweg reproduzierbar machen. Sie sind vollständig und wie geschrieben syntaktisch gültig.

### 5.1 `cloud-init` — Knoten-Bootstrap mit Bootpfad-Konfiguration

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Provisions kernel cmdline, module policy, udev rules and boot targets on first boot.
hostname: node-17
fqdn: node-17.rack04.dc-mad.example.net
prefer_fqdn_over_hostname: true

write_files:
  # ---- Kernel module policy -------------------------------------------------
  - path: /etc/modules-load.d/10-platform.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Loaded unconditionally at boot by systemd-modules-load.service
      br_netfilter
      overlay
      nf_conntrack
      dm_multipath
      dm_round_robin
      nvme_tcp

  - path: /etc/modprobe.d/10-platform-options.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Connection tracking table sized for a busy node (~512k flows)
      options nf_conntrack hashsize=131072
      # Bond in 802.3ad; miimon in ms
      options bonding max_bonds=0 miimon=100
      # Hard-block legacy DMA-capable buses (physical attack surface)
      install firewire_ohci /bin/false
      install firewire_core /bin/false
      install thunderbolt /bin/false
      # Prevent the open GPU driver from binding before the vendor module
      blacklist nouveau
      options nouveau modeset=0

  # ---- Storage naming and queue tuning --------------------------------------
  - path: /etc/udev/rules.d/70-storage-tuning.rules
    permissions: '0644'
    owner: root:root
    content: |
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", \
        ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023", \
        ATTR{queue/read_ahead_kb}="128", ATTR{queue/rq_affinity}="2"
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", \
        ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"

  # ---- initramfs content policy ---------------------------------------------
  - path: /etc/dracut.conf.d/99-platform.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Golden image: never host-only, the image must boot on any SKU in the fleet
      hostonly="no"
      add_drivers+=" dm_multipath dm_round_robin nvme_tcp i40e ixgbe mlx5_core "
      add_dracutmodules+=" multipath network-legacy "
      compress="zstd"

  # ---- Power-button and idle policy -----------------------------------------
  - path: /etc/systemd/logind.conf.d/10-server.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Login]
      HandlePowerKey=ignore
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
      HandleLidSwitch=ignore
      IdleAction=ignore

  # ---- Bounded shutdown ------------------------------------------------------
  - path: /etc/systemd/system.conf.d/10-timeouts.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Manager]
      DefaultTimeoutStartSec=90s
      DefaultTimeoutStopSec=45s
      # Never let one hung unit hold a rolling reboot hostage
      DefaultRestartSec=2s

bootcmd:
  - [ cloud-init-per, once, grubby-args, /usr/sbin/grubby, --update-kernel=ALL,
      --args=net.ifnames=0 transparent_hugepage=never intel_iommu=on iommu=pt console=ttyS0,115200n8 ]

runcmd:
  - [ systemctl, set-default, multi-user.target ]
  - [ udevadm, control, --reload-rules ]
  - [ udevadm, trigger, --subsystem-match=block, --action=change ]
  - [ dracut, -f, --regenerate-all ]
  - [ systemctl, enable, --now, node-boot-audit.service ]

power_state:
  mode: reboot
  message: "cloud-init: applying kernel cmdline and initramfs policy"
  timeout: 60
  condition: true
```

### 5.2 Ansible-Rolle — idempotente Bootpfad-Durchsetzung fleet-weit

```yaml
---
# roles/boot_architecture/tasks/main.yml
- name: Detect firmware type
  ansible.builtin.stat:
    path: /sys/firmware/efi
  register: efi_dir

- name: Record firmware facts
  ansible.builtin.set_fact:
    boot_firmware: "{{ 'uefi' if efi_dir.stat.isdir | default(false) else 'bios' }}"
    grub_cfg_path: >-
      {{ '/boot/grub2/grub.cfg'
         if ansible_facts['os_family'] == 'RedHat'
         else '/boot/grub/grub.cfg' }}

- name: Assert Secure Boot state matches policy
  ansible.builtin.command: mokutil --sb-state
  register: sb_state
  changed_when: false
  failed_when: false
  when: boot_firmware == 'uefi'

- name: Fail when Secure Boot is disabled on a node that requires it
  ansible.builtin.assert:
    that:
      - "'SecureBoot enabled' in sb_state.stdout"
    fail_msg: >-
      Secure Boot is disabled on {{ inventory_hostname }} but boot_require_secureboot
      is true. Enrol the platform key via the BMC before continuing.
  when:
    - boot_firmware == 'uefi'
    - boot_require_secureboot | bool

- name: Deploy kernel module load list
  ansible.builtin.copy:
    dest: /etc/modules-load.d/10-platform.conf
    owner: root
    group: root
    mode: '0644'
    content: |
      {% for m in boot_required_modules %}
      {{ m }}
      {% endfor %}
  notify:
    - Rebuild initramfs
    - Reload modules-load

- name: Deploy modprobe options and hard blocks
  ansible.builtin.template:
    src: modprobe-platform.conf.j2
    dest: /etc/modprobe.d/10-platform-options.conf
    owner: root
    group: root
    mode: '0644'
    validate: '/usr/bin/test -r %s'
  notify: Rebuild initramfs

- name: Deploy dracut content policy (RedHat family)
  ansible.builtin.copy:
    dest: /etc/dracut.conf.d/99-platform.conf
    owner: root
    group: root
    mode: '0644'
    content: |
      hostonly="{{ 'yes' if boot_initramfs_hostonly else 'no' }}"
      add_drivers+=" {{ boot_initramfs_drivers | join(' ') }} "
      compress="zstd"
  when: ansible_facts['os_family'] == 'RedHat'
  notify: Rebuild initramfs

- name: Set kernel command line (RedHat family, BLS-aware)
  ansible.builtin.command:
    argv:
      - /usr/sbin/grubby
      - --update-kernel=ALL
      - "--args={{ boot_kernel_args | join(' ') }}"
  register: grubby_result
  changed_when: true
  when: ansible_facts['os_family'] == 'RedHat'

- name: Set kernel command line (Debian family)
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: 'GRUB_CMDLINE_LINUX="{{ boot_kernel_args | join(" ") }}"'
    owner: root
    group: root
    mode: '0644'
  when: ansible_facts['os_family'] == 'Debian'
  notify: Regenerate grub config

- name: Deploy udev storage rules
  ansible.builtin.copy:
    src: 70-storage-tuning.rules
    dest: /etc/udev/rules.d/70-storage-tuning.rules
    owner: root
    group: root
    mode: '0644'
  notify: Reload udev rules

- name: Enforce the default boot target
  ansible.builtin.file:
    src: "/usr/lib/systemd/system/{{ boot_default_target }}"
    dest: /etc/systemd/system/default.target
    state: link
    force: true

- name: Verify the running command line already carries the policy
  ansible.builtin.slurp:
    src: /proc/cmdline
  register: live_cmdline

- name: Report nodes whose running kernel predates the policy
  ansible.builtin.debug:
    msg: >-
      {{ inventory_hostname }} needs a reboot: missing
      {{ boot_kernel_args | reject('in', live_cmdline.content | b64decode) | list }}
  when: >-
    boot_kernel_args
    | reject('in', live_cmdline.content | b64decode)
    | list | length > 0
```

```yaml
---
# roles/boot_architecture/handlers/main.yml
- name: Reload modules-load
  ansible.builtin.systemd:
    name: systemd-modules-load.service
    state: restarted

- name: Reload udev rules
  ansible.builtin.shell:
    cmd: udevadm control --reload-rules && udevadm trigger --subsystem-match=block --action=change
  changed_when: true

- name: Rebuild initramfs
  ansible.builtin.command:
    argv: "{{ ['/usr/bin/dracut', '-f', '--regenerate-all']
              if ansible_facts['os_family'] == 'RedHat'
              else ['/usr/sbin/update-initramfs', '-u', '-k', 'all'] }}"
  changed_when: true

- name: Regenerate grub config
  ansible.builtin.command:
    argv:
      - "{{ '/usr/sbin/grub2-mkconfig' if ansible_facts['os_family'] == 'RedHat' else '/usr/sbin/grub-mkconfig' }}"
      - -o
      - "{{ grub_cfg_path }}"
  changed_when: true
```

```yaml
---
# roles/boot_architecture/defaults/main.yml
boot_require_secureboot: true
boot_default_target: multi-user.target
boot_initramfs_hostonly: false
boot_required_modules:
  - br_netfilter
  - overlay
  - nf_conntrack
  - dm_multipath
  - dm_round_robin
boot_initramfs_drivers:
  - dm_multipath
  - dm_round_robin
  - nvme_tcp
  - i40e
  - mlx5_core
boot_kernel_args:
  - net.ifnames=0
  - transparent_hugepage=never
  - intel_iommu=on
  - iommu=pt
  - console=ttyS0,115200n8
  - console=tty0
```

### 5.3 systemd-Units — ein Bootpfad-Auditor mit einem harten Fehlermodus

```ini
# /etc/systemd/system/node-boot-audit.service
[Unit]
Description=Assert node boot-path invariants (cmdline, modules, initramfs, target)
Documentation=man:systemd.service(5)
DefaultDependencies=no
After=sysinit.target systemd-modules-load.service local-fs.target
Before=multi-user.target
Wants=systemd-modules-load.service
# Do not let a failed audit take down an in-service node silently
OnFailure=node-boot-audit-alert.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/boot-audit.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=boot-audit
TimeoutStartSec=60s

# Hardening — this unit reads state, it never needs to write outside /run
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
RuntimeDirectory=boot-audit
ReadWritePaths=/run/boot-audit
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/node-boot-audit-alert.service
[Unit]
Description=Report a failed boot-path audit to the fleet alerting endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/boot-audit-alert.sh
TimeoutStartSec=30s
```

```ini
# /etc/systemd/system/kubelet.service.d/10-boot-ordering.conf
# Drop-in: never start the kubelet before the boot-path invariants are proven.
[Unit]
After=node-boot-audit.service containerd.service
Requires=node-boot-audit.service

[Service]
# Bound the drain window during a rolling reboot
TimeoutStopSec=120s
KillMode=mixed
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/boot-audit.sh — invariants that must hold on every booted node.
set -euo pipefail

fail=0
note() { printf '%-6s %s\n' "$1" "$2"; }

required_args=(net.ifnames=0 transparent_hugepage=never intel_iommu=on)
cmdline="$(</proc/cmdline)"
for arg in "${required_args[@]}"; do
    if [[ $cmdline == *"$arg"* ]]; then
        note "OK" "cmdline carries ${arg}"
    else
        note "FAIL" "cmdline missing ${arg} — grubby/update-grub ran without a reboot?"
        fail=1
    fi
done

required_modules=(br_netfilter overlay dm_multipath)
for mod in "${required_modules[@]}"; do
    if lsmod | awk '{print $1}' | grep -qx "$mod"; then
        note "OK" "module ${mod} loaded"
    else
        note "FAIL" "module ${mod} not loaded — check /etc/modules-load.d and modprobe.d blocks"
        fail=1
    fi
done

# The initramfs must be newer than the modprobe policy that shapes it
initrd="/boot/initramfs-$(uname -r).img"
[[ -f $initrd ]] || initrd="/boot/initrd.img-$(uname -r)"
newest_policy="$(find /etc/modprobe.d /etc/dracut.conf.d -type f -newer "$initrd" 2>/dev/null | head -n1 || true)"
if [[ -n $newest_policy ]]; then
    note "FAIL" "initramfs older than ${newest_policy} — rebuild required before next reboot"
    fail=1
else
    note "OK" "initramfs newer than module policy"
fi

want_target="multi-user.target"
have_target="$(systemctl get-default)"
if [[ $have_target == "$want_target" ]]; then
    note "OK" "default target is ${want_target}"
else
    note "FAIL" "default target is ${have_target}, expected ${want_target}"
    fail=1
fi

printf '%s\n' "$fail" > /run/boot-audit/status
exit "$fail"
```

### 5.4 Kubernetes-DaemonSet — Bootpfad-Tuning clusterweit angewendet

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-tuning
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-boot-tuner
  namespace: node-tuning
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-boot-tuner
  namespace: node-tuning
data:
  tune.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    echo "[tuner] kernel: $(uname -r)"
    echo "[tuner] cmdline: $(cat /host/proc/cmdline)"

    # 1. Kernel modules the CNI and CSI datapaths require.
    for mod in br_netfilter overlay nf_conntrack dm_multipath; do
      if ! grep -qx "$mod" /host/proc/modules 2>/dev/null \
         && ! awk '{print $1}' /host/proc/modules | grep -qx "$mod"; then
        echo "[tuner] loading ${mod}"
        chroot /host /sbin/modprobe "$mod"
      fi
    done

    # 2. Persist the module list so it survives a reboot.
    cat > /host/etc/modules-load.d/20-k8s-datapath.conf <<'EOF'
    br_netfilter
    overlay
    nf_conntrack
    dm_multipath
    EOF

    # 3. Block-layer tuning for every NVMe namespace on the node.
    for q in /host/sys/block/nvme*/queue; do
      [ -e "$q/scheduler" ] || continue
      echo none  > "$q/scheduler"      || true
      echo 1023  > "$q/nr_requests"    || true
      echo 2     > "$q/rq_affinity"    || true
      echo "[tuner] tuned $(dirname "$q")"
    done

    # 4. Report the boot-path facts this node actually has.
    echo "[tuner] firmware: $([ -d /host/sys/firmware/efi ] && echo uefi || echo bios)"
    echo "[tuner] default target: $(chroot /host /usr/bin/systemctl get-default)"
    echo "[tuner] uptime: $(cut -d' ' -f1 /host/proc/uptime)s"
    echo "[tuner] done; sleeping"
    exec sleep infinity
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-boot-tuner
  namespace: node-tuning
  labels:
    app.kubernetes.io/name: node-boot-tuner
    app.kubernetes.io/component: node-tuning
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-boot-tuner
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-boot-tuner
    spec:
      serviceAccountName: node-boot-tuner
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      containers:
        - name: tuner
          image: registry.example.net/platform/node-tuner:1.7.2
          command: ["/bin/bash", "/scripts/tune.sh"]
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            capabilities:
              add: ["SYS_ADMIN", "SYS_MODULE"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: host
              mountPath: /host
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: modules
              mountPath: /lib/modules
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: host
          hostPath:
            path: /
            type: Directory
        - name: modules
          hostPath:
            path: /lib/modules
            type: Directory
        - name: scripts
          configMap:
            name: node-boot-tuner
            defaultMode: 0755
        - name: tmp
          emptyDir: {}
```

---

## 6. Verifikation und Fehlerdiagnose

### 6.1 Standard-Verifikationsbatterie

Führen Sie dies auf jedem Knoten aus, dessen Bootpfad Sie nicht persönlich vertrauen:

```console
$ cat /proc/cmdline                                   # what the kernel was actually told
$ systemd-analyze                                     # phase timing
$ systemd-analyze blame | head -n 10                  # slowest units
$ systemd-analyze critical-chain                      # the serialized path, not just totals
$ systemctl --failed                                  # anything that did not come up
$ systemctl get-default                               # intended service level
$ journalctl --list-boots                             # boot history
$ journalctl -b -1 -p err                             # errors from the previous boot
$ sudo dmesg --level=err,warn -T                      # hardware/driver complaints
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS          # storage topology as mounted
$ findmnt --verify --verbose                          # validate /etc/fstab BEFORE rebooting
$ sudo systemd-analyze verify multi-user.target       # unit-graph sanity check
```

```console
$ systemctl --failed
  UNIT                       LOAD   ACTIVE SUB    DESCRIPTION
● multipathd.service         loaded failed failed Device-Mapper Multipath Device Controller

LOAD   = Reflects whether the unit definition was properly loaded.
ACTIVE = The high-level unit activation state, i.e. generalization of SUB.
SUB    = The low-level unit activation state, values depend on unit type.
1 loaded units listed.

$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 8f21c9a4d1b34e6f8a2c5d7e91b04f33 Mon 2026-08-03 14:02:11 UTC Wed 2026-08-05 02:58:40 UTC
 -1 b30e77c25a9f4d1e8c66a4f2b7d19e01 Wed 2026-08-05 03:16:02 UTC Wed 2026-08-05 03:16:44 UTC
  0 c9d4e1f8a2b74c3e95a1d6b0f8e27c14 Wed 2026-08-05 03:20:09 UTC Wed 2026-08-05 09:41:22 UTC
```

Boot `-1` dauerte 42 Sekunden — das ist ein fehlgeschlagener Boot, gefolgt von einer manuellen Wiederherstellung. Es ist das Erste, was zu lesen ist.

> **Persistente Journale sind eine Voraussetzung.** Standardmäßig lebt das Journal auf vielen Distributionen in `/run/log/journal` und verschwindet bei einem Neustart — genau die Daten, die Sie nach einem Boot-Fehler benötigen. Beheben Sie es einmalig, fleet-weit:
> ```console
> $ sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
> $ sudo systemctl restart systemd-journald
> ```

### 6.2 Fehler-Entscheidungsbaum

```
Node does not come up
│
├─ No POST output / no firmware splash ───────────▶ Hardware, PSU, BMC. Not a Linux problem.
│
├─ Firmware splash, then "No bootable device" ────▶ Boot ENTRY problem
│    ├─ UEFI: efibootmgr -v from a live ISO — is the entry present? Is the ESP mounted?
│    └─ BIOS: is the ef02 BIOS boot partition present? Rerun grub2-install /dev/sdX.
│
├─ "grub rescue>" or "grub>" ─────────────────────▶ Boot LOADER can't find its config/modules
│    └─ set prefix=(hd0,gpt2)/grub2 ; set root=(hd0,gpt2) ; insmod normal ; normal
│
├─ GRUB menu appears, kernel panics immediately ──▶ KERNEL/initramfs mismatch
│    └─ "VFS: Unable to mount root fs on unknown-block(0,0)" = initramfs lacks the storage driver
│
├─ "dracut:/#" or "(initramfs)" prompt ───────────▶ initramfs can't assemble the real root
│    └─ Root device missing, LUKS unlocked, LVM not activated, multipath absent
│
├─ "Give root password for maintenance" ──────────▶ Root mounted, but a local-fs unit failed
│    └─ Almost always /etc/fstab: bad UUID, missing device, no `nofail`
│
├─ Login prompt but a service is missing ─────────▶ Userspace unit failure — systemctl --failed
│
└─ Boots, but takes minutes ──────────────────────▶ systemd-analyze critical-chain
     └─ Usually *-wait-online.service or a device unit hitting its 90 s timeout
```

### 6.3 Symptom → Ursache → Behebung

| Symptom | Wahrscheinlichste Ursache | Diagnose | Behebung |
|---|---|---|---|
| `VFS: Unable to mount root fs on unknown-block(0,0)` | initramfs lacks the storage driver (host-only build on new hardware) | `lsinitrd $img \| grep <driver>` | Boot old kernel, add `add_drivers+=`, `dracut -f --regenerate-all` |
| `dracut-initqueue timeout — starting timeout scripts` | `root=` device never appeared: wrong UUID, LVM/multipath not activated | `rd.break=pre-mount` then `lvs`, `blkid`, `dmsetup ls` | Correct `root=`/`rd.lvm.lv=`, include the module, rebuild |
| Boot stalls exactly 90 s then drops to emergency | A `/etc/fstab` entry whose device is absent | `journalctl -b -p err`, `systemctl list-units --type=mount --failed` | Add `nofail,x-systemd.device-timeout=10` or remove the entry |
| `grub rescue>` after a disk clone | `prefix`/UUID points at the old disk | `ls` at the rescue prompt to find the partition | `set prefix=…`, `insmod normal`, `normal`, then `grub2-install` + `grub2-mkconfig` |
| UEFI machine boots to firmware setup after motherboard swap | NVRAM boot variables lost with the board | `efibootmgr -v` from a live image | `efibootmgr -c -d /dev/nvme0n1 -p 1 -L rocky -l '\EFI\rocky\shimx64.efi'` |
| Out-of-tree module fails to load, `Required key not available` | Secure Boot rejecting an unsigned module | `mokutil --sb-state`, `dmesg \| grep -i 'key'` | Sign with a MOK and `mokutil --import`, or disable Secure Boot |
| NIC renamed after a kernel upgrade; network dead | Predictable-naming scheme version changed | `udevadm test-builtin net_id /sys/class/net/<if>` | Pin with a `.link` file matching on MAC, or set `net.ifnames=0` fleet-wide |
| Blacklisted module still loads | `blacklist` blocks alias autoload only | `modprobe --show-depends <mod>`, `lsmod \| grep <mod>` | Use `install <mod> /bin/false`, then rebuild the initramfs |
| Kernel arg "doesn't apply" | Config changed but never regenerated, or never rebooted | Compare `/proc/cmdline` with `grubby --info=DEFAULT` | Regenerate (`grubby`/`update-grub`) **and** reboot |
| Node reboots on its own at night | ACPI power-key event, or a BMC/watchdog action | `journalctl -b -1 -u systemd-logind`, `last -x reboot shutdown` | `HandlePowerKey=ignore`, audit BMC power policy |
| `systemctl isolate` killed unrelated services | Isolate stops everything outside the target's dependency graph | `systemctl list-dependencies <target>` | Use `systemctl start/stop` for individual units, never `isolate` on a live node |
| Shutdown hangs at "A stop job is running (1min 30s)" | Unit ignoring SIGTERM; `DefaultTimeoutStopSec` at 90 s | `systemd-analyze blame` on shutdown, `journalctl -b -1 -e` | Set unit `TimeoutStopSec=`, fix signal handling, lower the default |

### 6.4 Die vier Wiederherstellungseinstiegspunkte, nach Schweregrad geordnet

```
1. systemd.unit=rescue.target      ← root mounted rw, all local FS, no network. Password required.
2. systemd.unit=emergency.target   ← root mounted RO, /bin/sh only. Password required.
3. rd.break=pre-mount              ← inside dracut, real root NOT yet mounted, at /sysroot.
4. init=/bin/bash                  ← no init at all. Root mounted RO. Nothing else runs.
```

**Wiederherstellung nach einem defekten `/etc/fstab` — der häufigste Boot-Fehler überhaupt:**

```console
# At the GRUB menu: press 'e', append to the linux line, Ctrl-X to boot
linux ($root)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro systemd.unit=emergency.target

Give root password for maintenance
(or press Control-D to continue):

[root@node-17 ~]# mount -o remount,rw /
[root@node-17 ~]# findmnt --verify --verbose
/mnt/data
   [W] unreachable source: UUID=deadbeef-0000-4000-8000-000000000000: No such file or directory
   [W] non-bind mount source UUID=deadbeef-… is a directory or regular file
1 parse error, 2 errors, 0 warnings

[root@node-17 ~]# sed -i '/deadbeef/s/defaults/nofail,x-systemd.device-timeout=10/' /etc/fstab
[root@node-17 ~]# findmnt --verify
Success, no errors or warnings detected
[root@node-17 ~]# systemctl daemon-reload
[root@node-17 ~]# systemctl default
```

**Wiederherstellung eines nicht mountbaren Root aus dracut heraus:**

```console
# Append to the kernel line: rd.break=pre-mount rd.debug

Entering emergency mode. Exit the shell to continue.

dracut:/# lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0 894.3G  0 disk
├─nvme0n1p1 259:1    0     1G  0 part
├─nvme0n1p2 259:2    0     1G  0 part
└─nvme0n1p3 259:3    0   892G  0 part

dracut:/# lvm vgscan
  Found volume group "rl" using metadata type lvm2
dracut:/# lvm vgchange -ay rl
  3 logical volume(s) in volume group "rl" now active
dracut:/# lsblk /dev/mapper/rl-root
NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
rl-root 253:0    0  70G  0 lvm
dracut:/# mount -o ro /dev/mapper/rl-root /sysroot && echo MOUNT-OK
MOUNT-OK
dracut:/# rdsosreport                # writes a full diagnostic bundle to /run/initramfs
dracut:/# exit                       # continue the boot
```

Die Lektion aus diesem Transkript: das Root-LV war in Ordnung; die LVM-Autoaktivierung innerhalb der initramfs war es nicht. Die Behebung ist `rd.lvm.lv=rl/root` auf der Befehlszeile plus ein Neuaufbau der initramfs — keine Neuinstallation.

**Wiederherstellung eines verlorenen Root-Passworts (physischer/Konsolenzugriff impliziert):**

```console
# Append to the kernel line: rw init=/bin/bash
bash-5.1# mount -o remount,rw /
bash-5.1# passwd root
Changing password for user root.
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
bash-5.1# touch /.autorelabel        # required when SELinux is enforcing
bash-5.1# exec /sbin/init            # or: reboot -f
```

> `init=/bin/bash` ist genau der Grund, warum unbeaufsichtigter physischer Zugriff gleich Root bedeutet, und warum GRUB-Passwortschutz (`grub2-setpassword`) plus ein BIOS/BMC-Passwort grundlegende Kontrollen für jede Maschine außerhalb eines abgeschlossenen Käfigs sind.

### 6.5 Checkliste vor dem Neustart — die Disziplin, die §1 verhindert

Vor dem Neustart eines Knotens, an dessen Bootpfad Sie Änderungen vorgenommen haben:

```console
$ findmnt --verify                                    # fstab is parseable and reachable
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg         # (or update-grub) — config regenerated
$ grubby --info=DEFAULT                               # the entry says what you think it says
$ sudo dracut -f --regenerate-all                     # initramfs matches current module policy
$ lsinitrd /boot/initramfs-$(uname -r).img | grep -c . # non-empty, plausible size
$ ls -l --time-style=full-iso /boot/initramfs-*.img /etc/modprobe.d/*  # initramfs is NEWER
$ sudo systemd-analyze verify default.target          # no dangling unit references
$ df -h /boot                                         # a full /boot silently truncates the initramfs
```

Der letzte Punkt verdient Betonung: ein zu 100 % gefülltes `/boot` führt dazu, dass `dracut` eine **abgeschnittene** initramfs schreibt, und auf vielen Distributionen beendet sich das Paket-Scriptlet trotzdem mit Exit-Code 0. Der Knoten bootet dann ohne vorherige Warnung in den dracut-Notfallmodus. Prüfen Sie den freien Speicherplatz auf `/boot` vor jeder Kernel-Operation und alarmieren Sie darauf in Ihrem Fleet-Monitoring.

---

## 7. Befehls- und Dateireferenz

| Bereich | Befehle | Schlüsseldateien |
|---|---|---|
| Firmware | `efibootmgr`, `mokutil`, `bootctl`, `dmidecode` | `/sys/firmware/efi/`, `/boot/efi/EFI/` |
| Boot-Loader | `grub2-mkconfig`, `update-grub`, `grubby`, `grub2-install`, `grub2-setpassword` | `/etc/default/grub`, `/etc/grub.d/`, `/boot/grub2/grub.cfg`, `/boot/loader/entries/` |
| Kernel | `uname -r`, `dmesg`, `sysctl` | `/proc/cmdline`, `/proc/version`, `/boot/config-$(uname -r)` |
| initramfs | `dracut`, `lsinitrd`, `update-initramfs`, `lsinitramfs` | `/etc/dracut.conf.d/`, `/etc/initramfs-tools/` |
| Module | `lsmod`, `modinfo`, `modprobe`, `insmod`, `rmmod`, `depmod` | `/etc/modprobe.d/`, `/etc/modules-load.d/`, `/lib/modules/$(uname -r)/modules.dep`, `/proc/modules` |
| Hardware | `lspci`, `lsusb`, `lscpu`, `lsblk`, `lsdev`, `hwinfo` | `/proc/interrupts`, `/proc/ioports`, `/proc/dma`, `/proc/cpuinfo`, `/sys/bus/`, `/sys/class/` |
| udev | `udevadm info\|monitor\|trigger\|test\|control` | `/etc/udev/rules.d/`, `/usr/lib/udev/rules.d/`, `/dev/disk/by-*/` |
| init / Targets | `systemctl`, `systemd-analyze`, `runlevel`, `who -r`, `telinit` | `/etc/systemd/system/default.target`, `/usr/lib/systemd/system/`, `/etc/inittab` (SysV) |
| Herunterfahren | `shutdown`, `halt`, `poweroff`, `reboot`, `wall`, `kexec`, `systemd-inhibit` | `/run/nologin`, `/etc/systemd/logind.conf` |
| Logs | `journalctl`, `dmesg`, `rdsosreport` | `/var/log/journal/`, `/run/log/journal/`, `/var/log/boot.log` |

---

## 8. Referenzen

**Zertifizierung und Ziele**
- LPIC-1-Zertifizierungsübersicht — https://www.lpi.org/our-certifications/lpic-1-overview/
- LPIC-1-Prüfung-101-Ziele, Version 5.0 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1-Prüfung-102-Ziele, Version 5.0 — https://www.lpi.org/our-certifications/exam-102-objectives/

**Kernel und Bootprozess**
- Die Kernel-Befehlszeilenparameter — https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Kernel-Module-Signing-Facility — https://www.kernel.org/doc/html/latest/admin-guide/module-signing.html
- Linux Filesystem Hierarchy Standard 3.0 — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- sysfs — das Dateisystem zum Exportieren von Kernel-Objekten — https://www.kernel.org/doc/html/latest/filesystems/sysfs.html
- initramfs / früher Userspace — https://www.kernel.org/doc/html/latest/driver-api/early-userspace/early_userspace_support.html

**Boot-Loader und Firmware**
- GNU-GRUB-Handbuch 2.12 — https://www.gnu.org/software/grub/manual/grub/grub.html
- Boot Loader Specification — https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification — https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- UEFI-Spezifikation (aktuelle Version) — https://uefi.org/specifications
- `efibootmgr` — https://github.com/rhboot/efibootmgr
- `shim` (Secure-Boot-Erststufen-Loader) — https://github.com/rhboot/shim

**Init-System**
- systemd-Man-Pages-Index — https://www.freedesktop.org/software/systemd/man/latest/
- `systemd.unit(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.target(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
- `systemctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `systemd-analyze(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `bootup(7)` — der Bootprozess — https://www.freedesktop.org/software/systemd/man/latest/bootup.html
- `systemd-inhibit(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-inhibit.html
- `logind.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
- `kernel-command-line(7)` — https://www.freedesktop.org/software/systemd/man/latest/kernel-command-line.html

**Geräteverwaltung**
- `udev(7)` — https://www.freedesktop.org/software/systemd/man/latest/udev.html
- `udevadm(8)` — https://www.freedesktop.org/software/systemd/man/latest/udevadm.html
- `systemd.link(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- Vorhersagbare Netzwerkschnittstellennamen — https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- `modprobe.d(5)` — https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- `modprobe(8)` — https://man7.org/linux/man-pages/man8/modprobe.8.html

**Distributionsdokumentation**
- Red Hat Enterprise Linux 9 — Verwalten, Überwachen und Aktualisieren des Kernels — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- Red Hat Enterprise Linux 9 — Konfigurieren grundlegender Systemeinstellungen (Targets, Boot) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/index
- `dracut.conf(5)` — https://man7.org/linux/man-pages/man5/dracut.conf.5.html
- `dracut(8)` — https://man7.org/linux/man-pages/man8/dracut.8.html
- Debian Administrator's Handbook — Booten und Init — https://debian-handbook.info/browse/stable/sect.system-boot.html
- `initramfs-tools(8)` — https://manpages.debian.org/stable/initramfs-tools-core/initramfs-tools.8.en.html
- SUSE Linux Enterprise Server — Booten eines Linux-Systems — https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-boot.html

**Automatisierungswerkzeuge**
- cloud-init-Modulreferenz — https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible-`ansible.builtin`-Modulindex — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/index.html
- Kubernetes-DaemonSet — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/