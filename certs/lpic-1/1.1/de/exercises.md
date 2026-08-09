# LPIC-1 (101-500) — Topic 101: Systemarchitektur
## Angeleitete Laborübungen

**Abgedeckte Teilziele**

| ID | Ziel | Gewichtung |
|----|-----------|--------|
| 101.1 | Hardware-Einstellungen bestimmen und konfigurieren | 2 |
| 101.2 | Das System booten | 3 |
| 101.3 | Runlevel / Boot-Targets ändern und das System herunterfahren oder neu starten | 3 |

**Referenzquellen**
- LPI, *LPIC-1 Exam 101 Objectives, Version 5.0* — https://www.lpi.org/our-certifications/lpic-1-overview/
- Linux kernel documentation, *procfs* and *sysfs* — https://docs.kernel.org/filesystems/proc.html and https://docs.kernel.org/filesystems/sysfs.html
- Linux kernel documentation, *The kernel's command-line parameters* — https://docs.kernel.org/admin-guide/kernel-parameters.html
- freedesktop.org, *systemd* manual pages — https://www.freedesktop.org/software/systemd/man/
- GNU GRUB Manual 2.x — https://www.gnu.org/software/grub/manual/grub/grub.html

---

## Laborumgebung

> **Führe jede Übung in einer entbehrlichen virtuellen Maschine aus, nicht auf einer Workstation, die dir wichtig ist.**
> Die Übungen 3, 4, 8, 9 und 10 entladen Kernel-Module, wechseln Targets, beenden Benutzersitzungen und brechen den Boot-Vorgang absichtlich ab. Auf einem Produktionshost sind das Operationen, die Ausfälle verursachen.

Anforderungen:

- Eine systemd-basierte Distribution (Debian 12+, Ubuntu 22.04+, Rocky/Alma 9, openSUSE Leap 15+, Fedora 38+).
- `root`-Zugriff (alle folgenden Befehle setzen `sudo` voraus, wo nötig).
- Ein VM-Snapshot, aufgenommen **vor** Beginn von Übung 10.
- Pakete: `pciutils`, `usbutils`, `kmod`, `udev`/`systemd-udev`, `dmidecode`, `efibootmgr` (nur UEFI-Gäste), sowie `dracut`/`initramfs-tools`, abhängig von der Familie.

```bash
# Debian / Ubuntu
sudo apt install -y pciutils usbutils kmod dmidecode efibootmgr initramfs-tools

# RHEL family
sudo dnf install -y pciutils usbutils kmod dmidecode efibootmgr dracut
```

Notiere deine Baseline einmal; mehrere Übungen beziehen sich darauf zurück:

```bash
uname -r; uname -m; cat /etc/os-release | head -2
```

---

# Übung 1 — Die drei Kernel-Schnittstellen: `/proc`, `/sys` und `/dev`

**Ziel:** unterscheiden, *was der Kernel meldet* (`procfs`), *wie der Kernel Geräte modelliert* (`sysfs`), und *wie der Userspace mit Geräten spricht* (Device Nodes). Diese Unterscheidung ist das Rückgrat von Objective 101.1 und der Punkt, an dem die meisten Kandidaten Punkte verlieren.

### Schritte

1. Beweise, dass `/proc` und `/sys` nicht auf der Festplatte liegen:

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /proc /sys /dev /run
```

Erwartete Ausgabe (gekürzt):

```text
TARGET SOURCE   FSTYPE   OPTIONS
/proc  proc     proc     rw,nosuid,nodev,noexec,relatime
/sys   sysfs    sysfs    rw,nosuid,nodev,noexec,relatime
/dev   devtmpfs devtmpfs rw,nosuid,size=4096k,nr_inodes=1013210,mode=755
/run   tmpfs    tmpfs    rw,nosuid,nodev,size=812584k,mode=755
```

2. Lies die klassischen 101.1-Dateien. Beachte, dass sie alle **null Bytes auf der Festplatte** haben und beim Lesen generiert werden:

```bash
ls -l /proc/cpuinfo /proc/meminfo /proc/interrupts /proc/ioports /proc/dma
head -12 /proc/cpuinfo
grep -E '^(MemTotal|MemAvailable|SwapTotal)' /proc/meminfo
```

3. Untersuche die veralteten Hardware-Ressourcen-Dateien. Auf modernen x86-Systemen sind sie immer noch die kanonische Antwort auf "welchen IRQ / I/O-Port / DMA-Kanal verwendet dieses Gerät?":

```bash
sudo cat /proc/interrupts | head -15
sudo cat /proc/ioports  | head -15
sudo cat /proc/iomem    | head -10
cat /proc/dma
```

Erwartete `/proc/interrupts`-Form:

```text
           CPU0       CPU1
  0:         28          0   IO-APIC   2-edge      timer
  1:          0         10   IO-APIC   1-edge      i8042
  9:          0          0   IO-APIC   9-fasteoi   acpi
 11:          0      15522   IO-APIC  11-fasteoi   virtio0
 12:          0        154   IO-APIC  12-edge      i8042
NMI:          0          0   Non-maskable interrupts
```

4. Durchlaufe das sysfs-Gerätemodell für die Boot-Festplatte. `sysfs` legt die Kernel-Objekthierarchie offen: `devices/` ist die physische Topologie, `bus/` und `class/` sind Index-Ansichten darauf:

```bash
ls /sys
ls -l /sys/block/ | head
ls -l /sys/class/net/
readlink -f /sys/class/net/$(ls /sys/class/net | grep -v lo | head -1)
```

Erwartete `readlink`-Ausgabe:

```text
/sys/devices/pci0000:00/0000:00:03.0/virtio0/net/enp0s3
```

5. Lies Attribute, statt Befehlsausgaben zu parsen — dies ist die produktionsreife Gewohnheit:

```bash
DISK=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || echo sda)
cat /sys/block/$DISK/size            # size in 512-byte sectors, always
cat /sys/block/$DISK/queue/rotational # 1 = spinning disk, 0 = SSD/virtual
cat /sys/block/$DISK/queue/scheduler
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor
```

6. Stelle Vergleich mit `/dev` her. Device Nodes sind *keine* Daten — sie sind (Typ, Major, Minor)-Tripel, die `read()`/`write()` zu einem Treiber leiten:

```bash
ls -l /dev/sda /dev/null /dev/tty0 /dev/random 2>/dev/null
grep -E ' (sd|nvme|tty|mem)$' /proc/devices
stat -c '%n %F major=%t minor=%T' /dev/null /dev/sda 2>/dev/null
```

Erwartet:

```text
brw-rw---- 1 root disk    8,  0 Aug  6 09:12 /dev/sda
crw-rw-rw- 1 root root    1,  3 Aug  6 09:12 /dev/null
crw--w---- 1 root tty     4,  0 Aug  6 09:12 /dev/tty0
```

> Beachte: `/proc/devices` druckt Major-Nummern in hexadezimal? **Nein** — es druckt sie dezimal. `stat -c '%t'` ist derjenige, der hex ausgibt. Überprüfe beide mit `/dev/null` (Major 1, Minor 3).

### Verständniskontrolle — Block 1

- **Q1.1** `/proc/cpuinfo` meldet bei `ls -l` eine Größe von 0, aber `wc -c` liefert mehrere tausend Bytes. Erkläre den Mechanismus.
- **Q1.2** Ein Kollege bittet dich, den vom NIC verwendeten IRQ zu finden. Gib zwei unabhängige Befehlspfade an — einen über `/proc`, einen über `/sys`.
- **Q1.3** `/dev` ist als `devtmpfs` gemountet, nicht als `tmpfs`. Was tut der Kernel bei `devtmpfs`, das er bei `tmpfs` nicht tut, und welche Komponente fügt dann Berechtigungen und Symlinks hinzu?
- **Q1.4** Welches von `/proc`, `/sys`, `/dev` überlebt, wenn du mit `init=/bin/bash` und sonst nichts bootest? Warum ist das für Rescue-Arbeiten wichtig?

---

# Übung 2 — Bus-Enumeration: PCI, USB und Treiberbindung

**Ziel:** von "ein unbekanntes Gerät befindet sich in dieser Maschine" zu "genau dieser Treiber ist daran gebunden" gelangen, was der Diagnosepfad für jedes "Hardware funktioniert nicht"-Ticket ist.

### Schritte

1. Enumeriere PCI-Geräte mit numerischen IDs **und** Treiberbindung. `-nnk` ist der nützlichste Aufruf im gesamten Objective:

```bash
lspci -nnk | head -30
```

Erwartet (QEMU/KVM-Gast, gekürzt):

```text
00:01.1 IDE interface [0101]: Intel Corporation 82371SB PIIX3 IDE [Natoma/Triton II] [8086:7010]
	Subsystem: Red Hat, Inc. QEMU Virtual Machine [1af4:1100]
	Kernel driver in use: ata_piix
	Kernel modules: ata_piix, pata_acpi, ata_generic
00:03.0 Ethernet controller [0200]: Red Hat, Inc. Virtio network device [1af4:1000]
	Subsystem: Red Hat, Inc. Device [1af4:0001]
	Kernel driver in use: virtio-pci
```

2. Entschlüssele die Adressnotation und überprüfe sie im sysfs. `00:03.0` ist `domain:bus:device.function` = `0000:00:03.0`:

```bash
lspci -s 00:03.0 -vv | head -20
ls -l /sys/bus/pci/devices/0000:00:03.0/driver
cat /sys/bus/pci/devices/0000:00:03.0/{vendor,device,class}
```

3. Tue dasselbe für USB. `lsusb -t` liefert den physischen Baum mit dem Treiber pro Interface, was `lsusb` allein nicht tut:

```bash
lsusb
lsusb -t
lsusb -v -d 1d6b:0002 2>/dev/null | head -20
```

Erwarteter Baum:

```text
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 5000M
/:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
    |__ Port 002: Dev 002, If 0, Class=Human Interface Device, Driver=usbhid, 12M
```

4. Finde die Roh-USB-Gerätedateien, die `lsusb` tatsächlich liest:

```bash
ls -l /dev/bus/usb/001/
lsusb | awk '{print "Bus "$2" Device "$4}' | tr -d ':'
```

5. Frage das Firmware-Level-Inventar (DMI/SMBIOS) ab — die Quelle der Wahrheit für "welches Motherboard / wie viele DIMM-Slots":

```bash
sudo dmidecode -t system | sed -n '1,15p'
sudo dmidecode -s bios-version
sudo dmidecode -t memory | grep -E 'Size|Locator' | head -8
```

### Verständniskontrolle — Block 2

- **Q2.1** `lspci -nnk` zeigt `Kernel modules: ata_piix, pata_acpi`, aber keine `Kernel driver in use:`-Zeile. Was ist die operative Bedeutung, und was sind zwei plausible Ursachen?
- **Q2.2** Du musst einen Vendor-Bugreport für einen NIC einreichen. Welche exakte Zeichenkette identifiziert die Hardware eindeutig, und welcher Befehl gibt sie aus?
- **Q2.3** Warum zeigt `lsusb -t` einen `Driver=` pro *Interface* statt pro *Gerät*? Nenne ein konkretes Gerät, das zwei verschiedene Treiber gleichzeitig bindet.
- **Q2.4** `lsusb` in einem minimalen Container gibt nichts aus, während `lspci` funktioniert. Was fehlt?

---

# Übung 3 — Kernel-Module: Abhängigkeiten, Parameter, Blacklists

**Ziel:** kontrollieren, welche Treiber der Kernel lädt. Objective 101.1 erwartet `lsmod`, `modprobe`, `modinfo`, `/etc/modprobe.d/`.

> **Nur VM.** Das Entfernen eines Moduls, das dein Root-Dateisystem oder deinen einzigen NIC unterstützt, wird die Maschine trennen oder zum Einfrieren bringen.

### Schritte

1. Lies die Tabelle der geladenen Module und beweise, woher sie stammt:

```bash
lsmod | head
head -3 /proc/modules
```

Die Spalten der `lsmod`-Ausgabe sind `Module | Size | Used by`:

```text
Module                  Size  Used by
vfat                   20480  1
fat                    86016  1 vfat
xfs                  1990656  1
libcrc32c              16384  1 xfs
```

2. Frage ein Modul ab, bevor du es anfasst:

```bash
modinfo vfat | head -12
modinfo -F depends vfat
modinfo -p loop        # parameters this module accepts
modinfo -n loop        # absolute path of the .ko file
```

3. Lade ein harmloses Modul und beobachte die Abhängigkeitsauflösung. `dm_mod` oder `loop` sind sichere Optionen:

```bash
lsmod | grep -c '^loop' || true
sudo modprobe -v loop max_loop=8
lsmod | grep '^loop'
cat /sys/module/loop/parameters/max_loop
```

`modprobe -v` gibt jedes durchgeführte `insmod` aus, einschließlich Abhängigkeiten:

```text
insmod /lib/modules/6.1.0-18-amd64/kernel/drivers/block/loop.ko max_loop=8
```

4. Zeige, warum `insmod` kein Ersatz für `modprobe` ist:

```bash
sudo modprobe -r loop
sudo insmod $(modinfo -n vfat)      # fails: unknown symbol / unresolved deps
sudo modprobe -v vfat               # succeeds: pulls in fat first
lsmod | grep -E '^(vfat|fat)'
```

5. Mache einen Parameter persistent, und blockiere einen Treiber:

```bash
echo 'options loop max_loop=16' | sudo tee /etc/modprobe.d/loop.conf
echo -e 'blacklist pcspkr\ninstall pcspkr /bin/false' | sudo tee /etc/modprobe.d/blacklist-pcspkr.conf
sudo modprobe -r loop && sudo modprobe loop
cat /sys/module/loop/parameters/max_loop     # -> 16
```

6. Zwinge ein Modul, **beim Booten** geladen zu werden (die entgegengesetzte Richtung), und baue die Abhängigkeitsdatenbank neu auf:

```bash
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo depmod -a
grep -m3 'loop.ko' /lib/modules/$(uname -r)/modules.dep
```

7. Räume auf:

```bash
sudo modprobe -r loop
sudo rm -f /etc/modprobe.d/loop.conf /etc/modules-load.d/br_netfilter.conf
```

### Verständniskontrolle — Block 3

- **Q3.1** `lsmod` zeigt `fat 86016 1 vfat`. Schreibe den exakten Befehl, der scheitern wird, und erkläre den Grund auf Kernel-Ebene.
- **Q3.2** `blacklist foo` in `/etc/modprobe.d/foo.conf` verhindert nicht, dass `foo` geladen wird. Nenne zwei unterschiedliche Gründe, warum dies in der Praxis vorkommt, und die Lösung für jeden.
- **Q3.3** Was ist der Unterschied in der Wirkung zwischen `/etc/modprobe.d/x.conf` und `/etc/modules-load.d/x.conf`?
- **Q3.4** Nach dem Kopieren einer `.ko` in `/lib/modules/$(uname -r)/extra/` meldet `modprobe` immer noch "Module not found". Was hast du vergessen?

---

# Übung 4 — udev: von uevent zu Device Node

**Ziel:** die Kette *Kernel-uevent → udevd → Device Node + Berechtigungen + persistente Symlinks* verstehen und eine Regel schreiben. Objective 101.1 nennt udev und D-Bus explizit.

### Schritte

1. Beobachte den Event-Stream live. Öffne zwei Terminals; im ersten:

```bash
sudo udevadm monitor --udev --kernel --property
```

Im zweiten, generiere Events (schließe ein USB-Gerät in der VM an, oder benutze ein Loop-Device):

```bash
sudo modprobe loop
truncate -s 64M /tmp/lab.img
sudo losetup -f --show /tmp/lab.img       # e.g. /dev/loop0
```

Erwartet im Monitor (gekürzt):

```text
KERNEL[812.114] add      /devices/virtual/block/loop0 (block)
ACTION=add
DEVNAME=/dev/loop0
DEVTYPE=disk
SUBSYSTEM=block
UDEV  [812.147] add      /devices/virtual/block/loop0 (block)
ID_FS_TYPE=
```

Beachte die zwei Zeilen pro Event: `KERNEL[...]` ist das rohe uevent, `UDEV[...]` ist nach der Regelverarbeitung.

2. Lies alles, was udev über einen Node weiß, in beiden Formen:

```bash
udevadm info -q property -n /dev/loop0
udevadm info -a -n /dev/loop0 | head -25     # attribute walk, parent by parent
```

Der `-a`-Walk ist das, wovon du `ATTR{}`/`ATTRS{}`-Schlüssel kopierst, wenn du Regeln schreibst:

```text
  looking at device '/devices/virtual/block/loop0':
    KERNEL=="loop0"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{ro}=="0"
    ATTR{size}=="131072"
```

3. Untersuche die persistenten Namensverzeichnisse, die udev aufbaut — diese sind der Grund, warum `/etc/fstab` niemals `/dev/sda1` sagen sollte:

```bash
ls -l /dev/disk/by-uuid/ /dev/disk/by-id/ /dev/disk/by-path/ 2>/dev/null | head -20
blkid
findmnt -no SOURCE,UUID /
```

4. Schreibe deine eigene Regel. Erstelle `/etc/udev/rules.d/99-lab.rules`:

```bash
sudo tee /etc/udev/rules.d/99-lab.rules >/dev/null <<'EOF'
# Give every loop device a stable alias and a lab-writable group
SUBSYSTEM=="block", KERNEL=="loop[0-9]*", SYMLINK+="lab/%k", GROUP="disk", MODE="0660"
EOF
```

5. Lade neu und re-triggere ohne Neustart, dann überprüfe:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block --action=add
ls -l /dev/lab/
udevadm test /sys/class/block/loop0 2>&1 | grep -E 'SYMLINK|MODE|GROUP'
```

6. Schau kurz in D-Bus, den *anderen* im Objective genannten IPC-Bus (udev bewegt Geräteevents; D-Bus bewegt Dienstnachrichten):

```bash
busctl list | head -10
busctl introspect org.freedesktop.systemd1 /org/freedesktop/systemd1 | head -10
```

7. Räume auf:

```bash
sudo losetup -d /dev/loop0; rm -f /tmp/lab.img
sudo rm /etc/udev/rules.d/99-lab.rules && sudo udevadm control --reload-rules
```

### Verständniskontrolle — Block 4

- **Q4.1** In einer Regel: wann verwendet man `ATTR{...}` im Gegensatz zu `ATTRS{...}`, und warum schlägt das Mischen von Parents in einer Regel fehl?
- **Q4.2** Regeln befinden sich in `/lib/udev/rules.d` (oder `/usr/lib/udev/rules.d`) und `/etc/udev/rules.d`. Welche gewinnt, und wie genau überschreibst du eine Vendor-Regel namens `60-net.rules`?
- **Q4.3** Deine Regel funktioniert nach `udevadm trigger`, aber das Gerät ist beim Booten nicht vorhanden. Nenne die häufigste Ursache.
- **Q4.4** Erkläre, warum `SYMLINK+=` statt `NAME=` für Disks auf modernen systemd-Systemen verwendet wird.

---

# Übung 5 — Firmware und Bootloader: BIOS/MBR versus UEFI/ESP

**Ziel:** bestimmen, welchen Boot-Pfad die Maschine tatsächlich genommen hat, und die GRUB-2-Konfiguration korrekt untersuchen. Objective 101.2.

### Schritte

1. Bestimme den Firmware-Modus **vom laufenden System** — niemals durch Annahme:

```bash
[ -d /sys/firmware/efi ] && echo "Booted UEFI" || echo "Booted BIOS/CSM"
ls /sys/firmware/efi/efivars 2>/dev/null | head -5
mokutil --sb-state 2>/dev/null || echo "mokutil not installed"
```

2. **UEFI-Pfad.** Lies die Firmware-Boot-Manager-Einträge — diese liegen im NVRAM, nicht auf der Festplatte:

```bash
sudo efibootmgr -v
findmnt /boot/efi
sudo find /boot/efi/EFI -maxdepth 2 -name '*.efi'
```

Erwartet:

```text
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0000
Boot0000* UiApp         FvVol(7cb8bdc9-...)/FvFile(462caa21-...)
Boot0001* debian        HD(1,GPT,7f3a...,0x800,0x100000)/File(\EFI\debian\shimx64.efi)
```

3. **BIOS-Pfad.** Untersuche den MBR. Die ersten 446 Bytes sind Bootcode, dann 64 Bytes Partitionstabelle, dann die `55 AA`-Signatur:

```bash
sudo dd if=/dev/sda bs=512 count=1 status=none | hexdump -C | head -4
sudo dd if=/dev/sda bs=512 count=1 status=none | tail -c 2 | hexdump -C
```

4. Lies das GRUB-2-Layout. Beachte die Familienaufteilung — **bearbeite niemals die generierte Datei manuell**:

```bash
ls -l /boot/grub/grub.cfg 2>/dev/null || ls -l /boot/grub2/grub.cfg
grep -v '^#' /etc/default/grub | grep -v '^$'
ls /etc/grub.d/
sudo awk '/^menuentry|^submenu/ {print NR": "$0}' /boot/grub/grub.cfg 2>/dev/null | head
```

Typische `/etc/default/grub`:

```text
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
```

5. Regeneriere die Konfiguration auf dem unterstützten Weg (sicher — sie reproduziert die aktuelle Datei):

```bash
# Debian/Ubuntu
sudo update-grub          # wrapper for: grub-mkconfig -o /boot/grub/grub.cfg
# RHEL family
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

6. Identifiziere den im Objective genannten alternativen Bootloader:

```bash
bootctl status 2>/dev/null | head -12    # systemd-boot; also reports firmware + ESP
```

### Verständniskontrolle — Block 5

- **Q5.1** Wie beweist du, dass ein laufendes System im UEFI-Modus gebootet hat, mit einem einzigen Test, der nicht durch das Vorhandensein einer ESP in `/etc/fstab` getäuscht werden kann?
- **Q5.2** Du hast `/boot/grub/grub.cfg` bearbeitet, um `nomodeset` hinzuzufügen, und es hat funktioniert. Zwei Wochen später hat ein Kernel-Update es entfernt. Was ist der richtige Ort, und welcher Befehl wendet ihn an?
- **Q5.3** Im BIOS-Modus passt GRUB 2 nicht in 446 Bytes. Wo befindet sich Stage 1.5 auf einer MSDOS-partitionierten Festplatte, und was ist das Äquivalent auf einer GPT/BIOS-Festplatte?
- **Q5.4** `efibootmgr` scheitert mit "EFI variables are not supported on this system". Gib die zwei wahrscheinlichsten Erklärungen an.

---

# Übung 6 — Kernel-Kommandozeile und die initramfs

**Ziel:** die Parameter lesen und ändern, mit denen der Kernel gestartet wurde, und erklären, warum überhaupt eine initramfs existiert. Objective 101.2.

### Schritte

1. Lies die exakte Kommandozeile des laufenden Kernels:

```bash
cat /proc/cmdline
```

Erwartet:

```text
BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=6f1c-...-9ab2 ro quiet
```

2. Ordne jedes Token seinem Konsumenten zu:

```bash
tr ' ' '\n' < /proc/cmdline | nl
findmnt -no SOURCE,UUID /       # confirm root= matches the real root
systemd-analyze cat-config systemd/system.conf | head -5
```

3. Bestätige, dass nicht erkannte Parameter an PID 1 als Umgebung/Argumente weitergegeben werden:

```bash
sudo dmesg | grep -i 'command line' | head -2
sudo dmesg | grep -i 'unknown kernel command line' | head -5
```

4. Untersuche die initramfs — hier wird "cannot mount root filesystem" diagnostiziert:

```bash
ls -lh /boot/initr*

# Debian / Ubuntu (initramfs-tools)
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'bin/(sh|init)$|/init$' | head
lsinitramfs /boot/initrd.img-$(uname -r) | grep -cE '\.ko(\.[a-z]+)?$'

# RHEL family (dracut)
sudo lsinitrd /boot/initramfs-$(uname -r).img | head -20
sudo lsinitrd -f etc/cmdline.d/*.conf /boot/initramfs-$(uname -r).img 2>/dev/null
```

5. Extrahiere sie vollständig und schau dir den Einstiegspunkt an:

```bash
mkdir -p /tmp/initrd && cd /tmp/initrd
# Debian/Ubuntu:
unmkinitramfs /boot/initrd.img-$(uname -r) . 2>/dev/null && ls
# Generic fallback for a plain gzip+cpio image:
# zcat /boot/initrd.img-$(uname -r) | cpio -idmv 2>/dev/null | tail -3
head -20 main/init 2>/dev/null || head -20 init 2>/dev/null
```

6. Baue sie neu auf (idempotent, sicher) und beachte, dass dies nach Änderung von Storage-Treibern oder `/etc/crypttab` obligatorisch ist:

```bash
# Debian / Ubuntu
sudo update-initramfs -u -k $(uname -r)
# RHEL family
sudo dracut -f /boot/initramfs-$(uname -r).img $(uname -r)
```

7. Übe eine temporäre Parameteränderung **ohne sie persistent zu machen**: neu starten, im GRUB-Menü `e` drücken, `systemd.unit=rescue.target` an die `linux`-Zeile anhängen, `Ctrl+X` drücken. Melde dich als root an, dann:

```bash
cat /proc/cmdline
systemctl get-default
systemctl default        # leave rescue, continue to the default target
```

### Verständniskontrolle — Block 6

- **Q6.1** Warum kann der Kernel `root=UUID=...` nicht einfach direkt mounten und die initramfs überspringen? Gib zwei konkrete Konfigurationen an, die die initramfs obligatorisch machen.
- **Q6.2** Was ist die letzte Aktion, die die initramfs `/init` ausführt, bevor der reale Userspace startet, und was passiert danach mit dem Inhalt der initramfs?
- **Q6.3** `/proc/cmdline` enthält `quiet splash single`. Welche Komponente konsumiert jeden der drei Parameter, und was ist die moderne systemd-Schreibweise für `single`?
- **Q6.4** Du hast einen Storage-Treiber zu `/etc/modprobe.d/` hinzugefügt und neu gestartet, dann kam es zu einer Kernel-Panic "VFS: Unable to mount root fs". Welcher Schritt wurde ausgelassen?

---

# Übung 7 — Den Boot lesen: `dmesg`, `journalctl`, `systemd-analyze`

**Ziel:** Boot-Forensik auf einer Maschine durchführen, die bereits neu gestartet ist. Objective 101.2 nennt `dmesg`, `journalctl -k` und die `/var/log/`-Dateien.

### Schritte

1. Lies den Kernel-Ringpuffer mit menschenlesbaren Zeitstempeln und Schweregradfilterung:

```bash
sudo dmesg -T | head -20
sudo dmesg --level=err,warn -T
sudo dmesg -H --facility=kern | tail -20
```

2. Verstehe, warum `dmesg` als normaler Benutzer die Ausführung verweigern könnte:

```bash
sysctl kernel.dmesg_restrict
dmesg 2>&1 | head -2       # as non-root
```

3. Vergleiche den Ringpuffer mit dem Journal. Der Ringpuffer ist ein fester zirkulärer Puffer im Kernel-Speicher; das Journal kann persistent sein:

```bash
journalctl -k | head -5
journalctl -k -b | wc -l
journalctl --list-boots | tail -5
journalctl -b -1 -p err --no-pager | head -20   # previous boot, errors only
```

Erwartete `--list-boots`:

```text
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 3a0f9f1c...                      Mon 2026-08-04 08:12:03 UTC Mon 2026-08-04 19:44:51 UTC
 -1 91b2c7de...                      Tue 2026-08-05 08:03:12 UTC Tue 2026-08-05 18:20:07 UTC
  0 c44e1a02...                      Wed 2026-08-06 09:11:44 UTC Wed 2026-08-06 09:39:02 UTC
```

4. Wenn `journalctl --list-boots` nur Boot `0` zeigt, ist das Journal flüchtig. Mache es persistent:

```bash
grep -E '^#?Storage' /etc/systemd/journald.conf
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

5. Überprüfe die klassischen Textlogs, die noch im Objective genannt werden (vorhanden auf Nicht-systemd- und auf Systemen, auf denen rsyslog läuft):

```bash
ls -l /var/log/dmesg /var/log/boot.log /var/log/messages /var/log/syslog 2>/dev/null
sudo tail -5 /var/log/boot.log 2>/dev/null
```

6. Quantifiziere den Boot, statt ihn zu beschreiben:

```bash
systemd-analyze time
systemd-analyze blame | head -10
systemd-analyze critical-chain
systemd-analyze critical-chain multi-user.target
```

Erwartet:

```text
Startup finished in 3.412s (firmware) + 231ms (loader) + 1.905s (kernel) + 4.117s (userspace) = 9.666s
graphical.target reached after 4.081s in userspace.
```

```text
graphical.target @4.081s
└─multi-user.target @4.080s
  └─nginx.service @3.902s +176ms
    └─network-online.target @3.898s
```

7. Identifiziere Units, die während des Boots fehlgeschlagen sind:

```bash
systemctl --failed
systemctl list-units --state=failed --no-legend
journalctl -b -u systemd-udev-settle.service --no-pager | tail -5
```

### Verständniskontrolle — Block 7

- **Q7.1** `dmesg` zeigt nichts über einen Festplattenfehler, den ein Kollege gestern gesehen hat, aber `journalctl` findet ihn. Erkläre beide Verhaltensweisen.
- **Q7.2** `dmesg`-Zeitstempel sind standardmäßig Sekunden seit dem Booten. Warum ist `dmesg -T` ungenau auf einer Maschine, die im Standby war, und was ist stattdessen exakt?
- **Q7.3** Unterscheide `systemd-analyze blame` von `systemd-analyze critical-chain`. Welches verwendet man, um die Bootzeit zu verkürzen, und warum ist das andere irreführend?
- **Q7.4** Welcher einzelne Befehl zeigt nur Kernel-Meldungen mit Priorität `err` oder schlimmer vom vorherigen Boot?

---

# Übung 8 — Targets, Runlevel und die SysVinit-Äquivalenz

**Ziel:** den aktuellen Systemzustand abfragen und wechseln, und sicher zwischen SysVinit-Runlevels und systemd-Targets übersetzen. Objective 101.3.

> **Nur VM.** Schritt 4 beendet grafische und SSH-Sitzungen.

### Schritte

1. Stelle den aktuellen und den Standardzustand fest:

```bash
systemctl get-default
systemctl list-units --type=target --state=active --no-pager
runlevel
who -r
```

Erwartet:

```text
graphical.target
N 5
         run-level 5  2026-08-06 09:11
```

2. Beweise, dass das Mapping als Symlinks implementiert ist, nicht als Übersetzungscode:

```bash
ls -l /usr/lib/systemd/system/runlevel?.target
systemctl cat runlevel3.target | head -5
```

Erwartet:

```text
lrwxrwxrwx 1 root root 15 ... /usr/lib/systemd/system/runlevel0.target -> poweroff.target
lrwxrwxrwx 1 root root 13 ... /usr/lib/systemd/system/runlevel1.target -> rescue.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel2.target -> multi-user.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel3.target -> multi-user.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel4.target -> multi-user.target
lrwxrwxrwx 1 root root 16 ... /usr/lib/systemd/system/runlevel5.target -> graphical.target
lrwxrwxrwx 1 root root 13 ... /usr/lib/systemd/system/runlevel6.target -> reboot.target
```

3. Untersuche, was ein Target tatsächlich hereinzieht:

```bash
systemctl list-dependencies multi-user.target | head -20
systemctl show -p Wants,Requires,AllowIsolate multi-user.target
```

4. Wechsle den Zustand zur Laufzeit (**Konsolenzugriff erforderlich**):

```bash
sudo systemctl isolate multi-user.target
runlevel                     # -> 5 3
systemctl get-default        # unchanged: isolate is not persistent
sudo systemctl isolate graphical.target
```

5. Ändere den Zustand, der über Neustarts hinweg persistent bleibt:

```bash
sudo systemctl set-default multi-user.target
ls -l /etc/systemd/system/default.target
sudo systemctl set-default graphical.target      # restore
```

6. Übe die SysVinit-Kompatibilitätsbefehle, die die Prüfung immer noch testet:

```bash
sudo telinit 3               # accepted by systemd, equivalent to isolate runlevel3.target
runlevel
sudo init 5
ls -l /etc/inittab 2>/dev/null || echo "no /etc/inittab — systemd system"
```

7. Erreiche die zwei Rescue-Zustände und beachte den Unterschied:

```bash
systemctl cat rescue.target    | grep -E 'Requires|After|Description'
systemctl cat emergency.target | grep -E 'Requires|After|Description'
```

`rescue.target` erfordert `sysinit.target` (Dateisysteme gemountet, grundlegende Dienste laufen, Single-User-Shell). `emergency.target` erfordert fast nichts: Root ist read-only gemountet, eine Shell, nichts weiter.

### Verständniskontrolle — Block 8

- **Q8.1** `runlevel` gibt `N 3` aus. Was bedeuten die beiden Felder, und was würde `3 5` bedeuten?
- **Q8.2** Gib das systemd-Äquivalent jedes SysVinit-Runlevels 0–6 an, und erkläre, warum 2, 3 und 4 alle zu einem Target zusammenfallen.
- **Q8.3** `systemctl isolate` scheitert bei manchen Units mit "Operation refused, unit may not be isolated". Welche Unit-Eigenschaft steuert dies, und warum existiert sie?
- **Q8.4** Unterscheide `rescue.target` von `emergency.target` hinsichtlich dessen, was gemountet ist und was läuft. Wann brauchst du das zweite?
- **Q8.5** Nach `systemctl set-default multi-user.target`, welche Datei hat sich geändert, und was ist sie?

---

# Übung 9 — Shutdown, Neustart, Benachrichtigung und Inhibitoren

**Ziel:** eine Maschine korrekt anhalten, ihre Benutzer warnen, einen Fehler abbrechen und verstehen, was ein Shutdown veto-en kann. Objective 101.3 nennt `shutdown`, `wall`, `acpid`.

> **Nur VM, und benutze ein zweites Terminal**, da einige Schritte ein tatsächliches Poweroff planen.

### Schritte

1. Plane ein Shutdown mit Verzögerung und Nachricht, und beobachte die zwei Nebeneffekte:

```bash
sudo shutdown -h +10 "Kernel maintenance — save your work"
ls -l /run/systemd/shutdown/scheduled 2>/dev/null
cat /run/nologin 2>/dev/null
who
```

Erwartete Broadcast auf jedem Terminal:

```text
Broadcast message from root@lab01 (Wed 2026-08-06 09:44:02 UTC):

Kernel maintenance — save your work
The system is going down for poweroff at Wed 2026-08-06 09:54:02 UTC!
```

2. Brich es ab — das nützlichste Flag in diesem Objective:

```bash
sudo shutdown -c
ls /run/nologin 2>/dev/null || echo "nologin removed"
```

3. Vergleiche den Nur-Benachrichtigungs-Modus und den manuellen Broadcast:

```bash
sudo shutdown -k +5 "Drill only — no shutdown will occur"
sudo shutdown -c
echo "Maintenance window opens in 15 minutes" | sudo wall
sudo wall -n "No banner header on this one"
```

4. Lerne die Äquivalenzen genau:

```bash
# All of the following halt/power off:
#   shutdown -h now        systemctl poweroff        init 0        poweroff
# All of the following reboot:
#   shutdown -r now        systemctl reboot          init 6        reboot
systemctl cat poweroff.target | grep -E 'Description|Requires'
```

5. Untersuche Inhibitoren — den Mechanismus, mit dem ein Paketmanager oder eine Benutzersitzung einen Shutdown verzögert oder blockiert:

```bash
systemd-inhibit --list
sudo systemd-inhibit --what=shutdown --who="lab" --why="demo" sleep 30 &
sleep 2; systemd-inhibit --list
kill %1
```

Erwartet:

```text
WHO           UID USER PID  COMM            WHAT                          WHY                       MODE
ModemManager  0   root 712  ModemManager    sleep                         ModemManager needs to...  delay
lab           0   root 4411 sleep           shutdown                      demo                      block
```

6. Konfiguriere das Verhalten der Hardware-Power-Taste — den modernen Ersatz für `acpid`-Handling auf einem systemd-System:

```bash
grep -E '^#?Handle(PowerKey|LidSwitch|SuspendKey)' /etc/systemd/logind.conf
systemctl status acpid 2>/dev/null | head -5
# Legacy path, still present on non-systemd systems:
ls /etc/acpi/events/ 2>/dev/null && cat /etc/acpi/events/powerbtn 2>/dev/null
```

7. Zeige die Eskalationsleiter für eine Maschine, die nicht sauber anhält (kenne sie, benutze sie zuletzt):

```bash
# 1. clean:      systemctl poweroff
# 2. skip units: systemctl poweroff --force          (equivalent to two Ctrl+Alt+Del)
# 3. immediate:  systemctl poweroff --force --force  (no unmount, no sync — data loss risk)
sysctl kernel.sysrq
```

### Verständniskontrolle — Block 9

- **Q9.1** Was genau tut `shutdown -k`, und wie unterscheidet es sich von `wall`?
- **Q9.2** Ein geplanter Shutdown muss abgebrochen werden. Gib den Befehl an, und nenne die Datei, deren Entfernung beweist, dass es funktioniert hat.
- **Q9.3** `systemctl poweroff` hängt für 90 Sekunden und fährt dann fort. Welcher Mechanismus hat die Verzögerung erzeugt, und welche zwei Befehle würdest du *vor* dem nächsten Neustart ausführen?
- **Q9.4** Erkläre den Unterschied zwischen einem Inhibitor im `block`-Modus und einem im `delay`-Modus, und welcher davon vom `ModemManager` eines Laptops verwendet wird.
- **Q9.5** Warum ist `systemctl poweroff --force --force` gefährlich, und was ist der eine legitime Anwendungsfall?

---

# Übung 10 — Abschlussübung: einen kaputten Boot diagnostizieren und reparieren

**Ziel:** 101.2 und 101.3 unter Fehlerbedingungen kombinieren. **Nimm einen VM-Snapshot auf, bevor du beginnst.**

### Schritte

1. Brich es absichtlich ab. Setze ein Standard-Target, das nicht erreicht werden kann, weil eine erforderliche Unit fehlschlagen wird:

```bash
sudo systemctl set-default graphical.target
sudo tee /etc/systemd/system/lab-broken.service >/dev/null <<'EOF'
[Unit]
Description=Deliberately failing lab unit
Before=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/false
RemainAfterExit=yes
[Install]
RequiredBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable lab-broken.service
sudo reboot
```

2. Die Maschine stoppt kurz vor einem Login-Prompt. Erhole dich **ohne** die Festplatte: im GRUB-Menü `e` drücken, an die `linux`-Zeile anhängen:

```text
systemd.unit=emergency.target
```

`Ctrl+X` drücken. An der Emergency-Shell:

```bash
mount -o remount,rw /
systemctl --failed
journalctl -b -p err --no-pager | tail -20
journalctl -b -u lab-broken.service --no-pager
```

3. Reparieren, verifizieren und zum Normalbetrieb zurückkehren, ohne blind neu zu starten:

```bash
systemctl disable lab-broken.service
rm /etc/systemd/system/lab-broken.service
systemctl daemon-reload
systemctl default
systemctl --failed
```

4. Zweiter Fehlermodus — ein unerreichbares Root-Gerät. Simuliere es, indem du den GRUB-Eintrag beim Booten zu `root=UUID=00000000-0000-0000-0000-000000000000` bearbeitest. Beobachte:

```text
Gave up waiting for root file system device.
ALERT!  UUID=00000000-... does not exist.  Dropping to a shell!
(initramfs)
```

Am `(initramfs)`-Prompt, diagnostiziere von innerhalb der initramfs:

```text
(initramfs) cat /proc/cmdline
(initramfs) blkid
(initramfs) ls /dev/sd* /dev/vd* /dev/nvme*
(initramfs) exit
```

Neu starten und den `root=`-Wert vom GRUB-Editor korrigieren; dann permanent machen:

```bash
findmnt -no UUID /
sudo grep -n 'root=UUID' /boot/grub/grub.cfg | head -3
sudo update-grub        # or: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

5. Bestätige, dass das System wirklich gesund ist, nicht nur gebootet:

```bash
systemctl is-system-running
systemctl --failed
systemd-analyze time
journalctl -b -p warning --no-pager | wc -l
```

`systemctl is-system-running` gibt `running`, `degraded`, `maintenance`, `starting` oder `stopping` zurück — und setzt den Exit-Code entsprechend, was ihn zur richtigen Prüfung innerhalb von Automatisierung macht.

### Verständniskontrolle — Block 10

- **Q10.1** Warum ist `systemd.unit=emergency.target` hier der richtige erste Schritt und nicht `init=/bin/bash`? Nenne eine Sache, die jedes davon gibt, die das andere nicht gibt.
- **Q10.2** Warum musst du im Emergency-Modus `mount -o remount,rw /` ausführen, bevor du irgendetwas bearbeitest?
- **Q10.3** Du hast einen `(initramfs)`-Prompt erreicht. Stelle definitiv fest, welche Stufen der Boot-Kette erfolgreich waren und welche fehlgeschlagen ist.
- **Q10.4** `systemctl is-system-running` gibt `degraded` zurück, obwohl du dich normal anmelden kannst. Was bedeutet das, und was ist der Folgebefehl?
- **Q10.5** Eine Unit, die als `RequiredBy=multi-user.target` deklariert ist, hat den Boot blockiert; eine Unit mit `WantedBy=multi-user.target` hätte das nicht getan. Erkläre die Abhängigkeitssemantik.

---

<details>
<summary><strong>Antworten — klicken zum Aufklappen</strong></summary>

## Übung 1 — `/proc`, `/sys`, `/dev`

**A1.1** `/proc` ist ein *virtuelles* Dateisystem (`procfs`), das von Kernel-Funktionen unterstützt wird, nicht von Blöcken auf einem Gerät. `stat()` meldet Größe 0, weil der Kernel keine billige Möglichkeit hat, die Länge vor der Generierung des Inhalts zu kennen; der Inhalt wird von einem `seq_file`-Handler zur `read()`-Zeit produziert. `wc -c` liest die Datei tatsächlich, sodass es die vom Handler ausgegebenen Bytes zählt. Konsequenz: `/proc`-Dateien müssen gelesen, niemals `stat`et werden, und ein Snapshot einer solchen Datei ist nur für den Moment gültig, in dem sie gelesen wurde.

**A1.2**
- procfs: `grep -i <ifname_driver> /proc/interrupts` — z.B. `grep virtio0 /proc/interrupts`; die erste Spalte ist der IRQ.
- sysfs: `cat /sys/class/net/enp0s3/device/irq`, oder über die PCI-Adresse `cat /sys/bus/pci/devices/0000:00:03.0/irq`.
(Ein dritter Pfad existiert für PCI-Hardware: `lspci -vv -s 00:03.0 | grep IRQ`.)

**A1.3** `devtmpfs` wird *vom Kernel selbst* befüllt: sobald ein Treiber ein Gerät registriert, erstellt der Kernel den entsprechenden Node mit Standardbesitz `root:root` und einem Standardmodus. Das garantiert, dass `/dev/console`, `/dev/null` und der Root-Disk-Node existieren, bevor der Userspace läuft — was genau das ist, was die initramfs braucht. `tmpfs` würde leer starten. `udevd` läuft dann darauf und wendet Besitz, Gruppe, Modus und die persistenten `SYMLINK+=`-Aliase aus den Regeln an. Kernel = Existenz; udev = Richtlinie.

**A1.4** Alle drei, solange sie gemountet sind. In der Praxis mit `init=/bin/bash` hat der Kernel das reale Root gemountet, aber die normalen Mount-Units *nicht* ausgeführt, sodass man typischerweise `/dev` (devtmpfs, gemountet vom Kernel oder der initramfs) bekommt, aber die anderen selbst mounten muss:

```bash
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -o remount,rw /
```

Das ist wichtig, weil ohne gemountetes `/proc` `ps`, `mount` (das `/proc/self/mounts` liest), `free` und `uname -a` sich falsch verhalten oder scheitern — das Erste, was man in dieser Shell tun sollte, ist, sie zu mounten.

## Übung 2 — PCI und USB

**A2.1** Es bedeutet, dass die Hardware vorhanden und enumeriert ist, aber **kein Treiber gebunden ist**, sodass das Gerät nicht funktionsfähig ist. Die `Kernel modules:`-Zeile ist `modprobe`s *Kandidatenliste* aus `modules.alias`, kein Beweis für eine Bindung. Häufige Ursachen: (a) das Modul ist blockiert oder fehlt in der initramfs/installierten Kernel-Paket; (b) das Modul hat sich verweigert zu binden — überprüfe `dmesg | grep -i <module>` auf einen Probe-Fehler, fehlende Firmware (`/lib/firmware`), oder das Gerät wird von `vfio-pci` für Passthrough beansprucht. Verifiziere mit `ls -l /sys/bus/pci/devices/<addr>/driver` — der Symlink fehlt, wenn nicht gebunden.

**A2.2** Das numerische `vendor:device`-ID-Paar (plus Subsystem-ID und Revision), z.B. `[1af4:1000] (rev 01)`, Subsystem `[1af4:0001]`. Befehl: `lspci -nn -s <addr>`, oder maschinenlesbar `lspci -nn -mm -s <addr>`. Menschenlesbare Namen kommen aus `/usr/share/hwdata/pci.ids` und ändern sich zwischen Distro-Versionen — die numerische ID nicht.

**A2.3** USB ist ein Interface-orientierter Bus: ein physisches Gerät stellt eine oder mehrere *Interfaces* bereit, jedes mit eigener Klasse, und der Kernel bindet einen Treiber **pro Interface**. Ein USB-Headset ist das Standardbeispiel — ein Interface bindet `snd-usb-audio` (Audio-Klasse) und ein anderes bindet `usbhid` (HID-Klasse, für die Lautstärketasten). Ein USB-WLAN-Dongle mit eingebautem Kartenleser ist ein weiteres: `rtl8xxxu` plus `usb-storage`.

**A2.4** `/dev/bus/usb` ist nicht vorhanden. `lsusb` liest die usbfs-Nodes unter `/dev/bus/usb/<bus>/<dev>` (und `/sys/bus/usb`), die ein Container normalerweise nicht erhält; `lspci` kann auf `/proc/bus/pci` und `/sys/bus/pci` zurückgreifen, die üblicherweise sichtbar sind. Fix in einem Container: privilegiert ausführen oder `/dev/bus/usb` bind-mounten.

## Übung 3 — Kernel-Module

**A3.1** `sudo modprobe -r fat` (oder `rmmod fat`) schlägt fehl mit `FATAL: Module fat is in use by: vfat`. Die "Used by"-Spalte ist der *Referenzzähler* des Moduls plus die Liste der Halter. Der Kernel verweigert das Entladen eines Moduls, dessen Symbole noch von einem anderen geladenen Modul referenziert werden, weil dies baumelnde Funktionszeiger im geladenen `vfat`-Code hinterlassen würde. Richtige Reihenfolge: zuerst `modprobe -r vfat` — oder einfach `modprobe -r vfat`, das mit `-r` unbenutzte Abhängigkeiten automatisch entfernt.

**A3.2**
1. **Das Modul befindet sich in der initramfs und lädt, bevor `/etc/modprobe.d/` auf dem realen Root lesbar ist** — oder die initramfs enthält eine veraltete Kopie der Konfiguration. Fix: initramfs neu aufbauen (`update-initramfs -u` / `dracut -f`).
2. **Etwas lädt es explizit statt per Alias.** `blacklist` unterdrückt nur *aliasbasiertes* automatisches Laden; ein direktes `modprobe foo`, ein Eintrag in `/etc/modules-load.d/`, oder ein anderes Modul, das es als Abhängigkeit aufführt, lädt es trotzdem. Fix: `install foo /bin/false` (oder `/bin/true`) in `/etc/modprobe.d/`, was den Install-Befehl selbst überschreibt. Füge `modprobe.blacklist=foo` an die Kernel-Kommandozeile an, um auch die initramfs-Stufe abzudecken.

**A3.3** `/etc/modprobe.d/*.conf` konfiguriert, **wie** sich ein Modul verhält, *wenn und falls* es geladen wird — `options`, `alias`, `blacklist`, `install`, `softdep`. Es lädt niemals etwas selbst. `/etc/modules-load.d/*.conf` (gelesen von `systemd-modules-load.service`) ist eine einfache Liste von Modulnamen, die **beim Booten unbedingt geladen werden**. Das Debian-Legacy-Äquivalent des Letzteren ist `/etc/modules`.

**A3.4** `sudo depmod -a`. `modprobe` löst Namen und Abhängigkeiten über `/lib/modules/$(uname -r)/modules.dep` und `modules.alias` auf, die generierte Dateien sind. Bis `depmod` sie neu generiert, ist eine neu kopierte `.ko` für `modprobe` unsichtbar (obwohl `insmod /full/path/foo.ko` trotzdem funktionieren würde, ohne Abhängigkeitsauflösung).

## Übung 4 — udev

**A4.1** `ATTR{...}` matcht ein Attribut **des Geräts, um das es beim Event geht**; `ATTRS{...}` matcht ein Attribut **dieses Geräts oder eines seiner Vorfahren**, indem es die Kette nach oben durchläuft. Die Falle: alle `ATTRS{}`-Schlüssel in einer einzelnen Regel müssen auf **demselben Vorfahren-Gerät** matchen — udev kombiniert keine Attribute von verschiedenen Vorfahren. Das Schreiben von `ATTRS{idVendor}=="8086", ATTRS{serial}=="ABC"` scheitert, wenn `idVendor` auf dem USB-Gerät liegt und `serial` auf der SCSI-Disk. Benutze `udevadm info -a` und nimm alle deine `ATTRS{}`-Schlüssel aus einem "looking at parent device"-Block.

**A4.2** `/etc/udev/rules.d` gewinnt. udev vereint alle Regelverzeichnisse in **einen einzigen, nach Dateiname sortierten Namensraum**, und eine Datei in `/etc` überschattet eine gleichnamige Datei in `/lib` (oder `/usr/lib`) vollständig. Um `60-net.rules` zu überschreiben: erstelle `/etc/udev/rules.d/60-net.rules` (gleicher Name — ersetzt sie vollständig, auch als leere Datei oder als Symlink auf `/dev/null`, um sie zu deaktivieren), oder erstelle eine höher nummerierte Datei wie `/etc/udev/rules.d/99-my-net.rules`, um *nach* ihr zu laufen und das Ergebnis zu ändern. Die Nummerierung ist wichtiger als der Ort für die Reihenfolge; der Ort entscheidet über das Überschatten.

**A4.3** Die Regeldatei befindet sich nicht in der initramfs, oder das gematchte Attribut ist zum Zeitpunkt des Boot-Time-Events noch nicht populiert. Die häufige praktische Ursache sind Regeln, die für das Root-Gerät benötigt werden (Multipath, Crypt, benutzerdefinierter Storage), die zu `/etc/udev/rules.d` hinzugefügt wurden, ohne die initramfs neu zu erstellen — `update-initramfs -u` / `dracut -f` behebt das. Eine zweite Ursache ist eine Regel, die von einem Programm abhängt (`PROGRAM=`/`IMPORT{program}=`), dessen Binärdatei in der initramfs nicht vorhanden ist.

**A4.4** `NAME=` *benennt* den Kernel-Device-Node um, was jeden anderen Konsumenten bricht, der den Kernelnamen erwartet (`/proc/partitions`, `lsblk`, `dmesg`-Korrelation) und wird von modernem systemd-udev für Block-Geräte kategorisch verweigert. `SYMLINK+=` fügt einen *zusätzlichen* stabilen Pfad hinzu, während der Kernel-Node intakt bleibt, und `+=` hängt an, statt zu ersetzen, sodass mehrere Regeln Aliase beitragen können. Genau so werden `/dev/disk/by-uuid/…` und `/dev/disk/by-id/…` erstellt.

## Übung 5 — Firmware und Bootloader

**A5.1** `[ -d /sys/firmware/efi ]`. Dieses Verzeichnis wird vom Kernel **nur** erstellt, wenn er beim Booten eine EFI-System-Tabelle von der Firmware erhalten hat. Eine ESP kann partitioniert, formatiert und auf einer BIOS-gebooteten Maschine gemountet werden, sodass `/etc/fstab`, `findmnt /boot/efi` und das Vorhandensein von `\EFI\...\*.efi`-Dateien nichts über den Boot-Modus beweisen. `bootctl status` meldet dieselbe Tatsache in Worten.

**A5.2** `/boot/grub/grub.cfg` wird von `grub-mkconfig` generiert und überschrieben, wann immer ein Kernel-Paket den Hook ausführt. Der richtige Ort ist `GRUB_CMDLINE_LINUX_DEFAULT` (gilt nur für normale Einträge) oder `GRUB_CMDLINE_LINUX` (gilt für normale **und** Recovery-Einträge) in `/etc/default/grub`. Anwenden mit `update-grub` auf Debian/Ubuntu oder `grub2-mkconfig -o /boot/grub2/grub.cfg` auf der RHEL-Familie. Pro-Eintrag-Anpassung, die eine Regenerierung überleben muss, kommt in `/etc/grub.d/40_custom`.

**A5.3** Auf einer MSDOS-partitionierten BIOS-Festplatte wird GRUB 2s `core.img` in die **MBR-Lücke** geschrieben — die unbenutzten Sektoren zwischen dem MBR (LBA 0) und der ersten Partition (traditionell LBA 63, modern LBA 2048). Auf einer GPT-Festplatte, die per BIOS gebootet wird, existiert diese Lücke nicht zuverlässig, daher benötigt GRUB eine dedizierte **BIOS-Boot-Partition** mit der GUID-Type `21686148-6449-6E6F-744E-656564454649` (`ef02` in `gdisk`), typischerweise 1 MiB, die `core.img` enthält. Unter UEFI gibt es überhaupt kein Stage 1.5: `grubx64.efi` ist eine vollständige EFI-Anwendung, die von der Firmware von der ESP geladen wird.

**A5.4** (a) Das System hat im BIOS/Legacy/CSM-Modus gebootet, sodass keine EFI-Runtime-Dienste und kein `/sys/firmware/efi/efivars` existieren. (b) Das System hat tatsächlich per UEFI gebootet, aber `efivarfs` ist nicht gemountet, oder der Kernel wurde mit `noefi`/`efi=noruntime` gebootet, oder du befindest dich in einem Container/Chroot ohne `/sys/firmware/efi/efivars` als Bind-Mount. Überprüfe mit `ls /sys/firmware/efi/efivars` und `mount | grep efivarfs`.

## Übung 6 — Kernel-Kommandozeile und initramfs

**A6.1** Der Kernel muss das Root-Dateisystem mounten, aber die Treiber, um es zu erreichen, sind möglicherweise nicht ins vmlinuz eingebaut — ein generischer Distributions-Kernel ist von Design modular. Konfigurationen, die die initramfs obligatorisch machen: (a) **Root auf LVM, RAID oder LUKS** — das Block-Gerät existiert nicht, bis `lvm`/`mdadm`/`cryptsetup` es im Userspace zusammengesetzt oder entsperrt hat; (b) **Root-Dateisystem oder Storage-Controller-Treiber als Modul gebaut** (z.B. XFS, Btrfs, NVMe oder ein Vendor-RAID-HBA), da das Modul auf genau dem Dateisystem liegt, das noch nicht gemountet werden kann; (c) **Root über das Netzwerk** (iSCSI, NFS), das zunächst NIC-Treiber und DHCP benötigt; (d) **`root=UUID=`/`LABEL=`-Auflösung**, die eine `blkid`-artige Abtastung im Userspace benötigt.

**A6.2** Die initramfs `/init` mountet das reale Root unter `/root` (oder `/sysroot`), ruft dann **`switch_root`** auf (`pivot_root` in älteren Schemata): es verschiebt das neue Root nach `/`, löscht den Inhalt der initramfs aus dem RAM, um diesen Speicher freizugeben, und `exec`t das reale `/sbin/init` — weshalb das neue init **PID 1** behält. Danach bleibt nichts von der initramfs im Speicher; deshalb kann man sie nicht vom laufenden System aus inspizieren und muss `lsinitrd`/`lsinitramfs` gegen die Image-Datei verwenden.

**A6.3**
- `quiet` — konsumiert vom **Kernel**: erhöht die Konsolen-Log-Level, sodass nur Fehler den Bildschirm erreichen (die Meldungen gehen trotzdem in den Ringpuffer).
- `splash` — konsumiert von der **initramfs/Userspace-Plymouth**-Bootsplash, nicht vom Kernel.
- `single` — konsumiert von **init/PID 1**. Unter systemd ist die moderne Schreibweise `systemd.unit=rescue.target`; `single`, `s` und `1` werden immer noch als Kompatibilitäts-Aliase akzeptiert, die auf `rescue.target` abbilden.

**A6.4** Die initramfs wurde nicht neu aufgebaut. `/etc/modprobe.d/` auf dem realen Root ist für die initramfs unsichtbar, und der Treiber selbst muss möglicherweise ins Image *eingebunden* werden. Führe `update-initramfs -u -k all` (Debian/Ubuntu) oder `dracut -f --regenerate-all` (RHEL-Familie) aus. Wiederherstellung in der Zwischenzeit: den vorherigen Kernel aus dem "Advanced options"-Untermenü von GRUB booten.

## Übung 7 — Boot-Forensik

**A7.1** Der Kernel-Ringpuffer ist ein **fester zirkulärer Puffer im Kernel-Speicher** (`CONFIG_LOG_BUF_SHIFT`, üblicherweise 128 KiB–1 MiB), der (a) bei einem Neustart gelöscht wird und (b) von neueren Meldungen überschrieben wird, sobald er voll ist — ein geschwätziger Treiber kann den Festplattenfehler von gestern innerhalb von Minuten verdrängen. `journalctl` liest dieselben Meldungen von `systemd-journald`, das sie aus `/dev/kmsg` kopiert und, falls `/var/log/journal/` existiert, **persistent über Neustarts hinweg** speichert. Richtige Gewohnheit: benutze `journalctl -k -b -1` für alles, was älter als der aktuelle Boot ist.

**A7.2** `dmesg`-Zeitstempel werden als **monotone Uhr** (Sekunden seit dem Booten) aufgezeichnet. `dmesg -T` rendert sie als Wall-Clock, indem es den monotonen Offset von der aktuellen Zeit subtrahiert — aber die monotone Uhr läuft während des Standbys bei manchen Konfigurationen nicht weiter, und die Wall-Clock kann nach dem Booten von NTP versetzt worden sein, sodass die beiden auseinanderdriften und die gerenderten Daten um den Drift-Betrag falsch sind. Was exakt ist: `journalctl -k`, weil journald jede Meldung sowohl mit `_SOURCE_MONOTONIC_TIMESTAMP` als auch mit einem Realtime-Zeitstempel beim Empfang stempelt.

**A7.3** `systemd-analyze blame` listet jede Unit sortiert nach ihrer eigenen Initialisierungszeit auf — aber eine langsame Unit, auf die nichts wartet, kostet Null Wallclock-Zeit, sodass die Optimierung des oberen Endes von `blame` oft nichts ändert. `critical-chain` zeigt die **Abhängigkeitskette, die tatsächlich bestimmt hat, wann das Target erreicht wurde**, mit `@` = Zeitpunkt, an dem die Unit aktiv wurde, und `+` = benötigte Zeit. Benutze `critical-chain`, um die Bootzeit zu verkürzen; behandle `blame` erst nach Bestätigung, dass die Unit in der Kette auftaucht, als Kandidatenliste.

**A7.4** `journalctl -k -b -1 -p err` (füge `--no-pager` für Skripting hinzu). `-k` = nur Kernel-Meldungen, `-b -1` = vorheriger Boot, `-p err` = Priorität `err` (3) und schwerwiegender.

## Übung 8 — Targets und Runlevel

**A8.1** Die Ausgabe ist `<vorheriger> <aktueller>`. `N` bedeutet "None" — es gab keinen vorherigen Runlevel, d.h. dies ist der erste Zustand seit dem Booten. `3 5` bedeutet, das System war in Runlevel 3 und ist jetzt in Runlevel 5 (jemand hat `systemctl isolate graphical.target` oder `init 5` ausgeführt). Die Daten kommen aus dem `utmp`-Datensatz, der bei jedem Übergang geschrieben wird, weshalb `who -r` dieselbe Information zeigt.

**A8.2**

| Runlevel | systemd-Target | Bedeutung |
|---|---|---|
| 0 | `poweroff.target` | Halt/Ausschalten |
| 1, `s`, `single` | `rescue.target` | Single-User, Root-Shell |
| 2 | `multi-user.target` | Multi-User (Debian: mit Netzwerk) |
| 3 | `multi-user.target` | Multi-User, Text, vernetzt |
| 4 | `multi-user.target` | undefiniert / standortspezifisch |
| 5 | `graphical.target` | Multi-User + Display-Manager |
| 6 | `reboot.target` | Neustart |

2, 3 und 4 fallen zusammen, weil die SysVinit-Unterscheidung zwischen ihnen **nie standardisiert** war — Debian benutzte 2 als seinen normalen Multi-User-Level mit Netzwerk, Red Hat benutzte 3 für Text und reservierte 2 für "Multi-User ohne NFS" und 4 für lokale Verwendung. systemd hat die numerische Ordnung durch einen expliziten Abhängigkeitsgraphen ersetzt, sodass ein einzelnes `multi-user.target` plus Unit-spezifisches `Wants=`/`After=` alles ausdrückt, was die drei Levels taten, ohne die Ambiguität.

**A8.3** `AllowIsolate=`. `systemctl isolate X` startet `X` und **stoppt jede Unit, die nicht von X benötigt wird**, sodass es nur für Units sinnvoll ist, die einen vollständigen Systemzustand beschreiben (Targets). Es zu erlauben für eine beliebige Dienst-Unit würde `systemctl isolate sshd.service` erlauben, das gesamte System herunterzureißen. Targets, die als Isolationspunkte gedacht sind, setzen `AllowIsolate=yes`; überprüfe mit `systemctl show -p AllowIsolate <unit>`.

**A8.4**
- `rescue.target` zieht `sysinit.target` und `local-fs.target` hinein: **alle lokalen Dateisysteme sind gemountet**, `systemd-journald`, udev und die grundlegende Systeminitialisierung sind gelaufen, Swap ist an, und man bekommt eine einzige Root-Shell. Netzwerk und Multi-User-Dienste werden nicht gestartet.
- `emergency.target` zieht im Wesentlichen nichts hinein: **nur das Root-Dateisystem, read-only gemountet**, plus eine Shell auf der Konsole. Keine anderen Dateisysteme, keine Garantie für Journald-Flush, kein udev-gesteuertes Setup.

Man braucht `emergency.target`, wenn der Fehler beim Mounten selbst liegt — ein fehlerhafter `/etc/fstab`-Eintrag, ein korruptes `/var`, ein fehlendes LVM-Volume — weil `rescue.target` selbst beim Versuch, diese Dateisysteme zu mounten, scheitern würde. Erste Aktionen dort: `mount -o remount,rw /`, dann `/etc/fstab` reparieren, dann `systemctl default`.

**A8.5** `/etc/systemd/system/default.target` — ein **Symlink**, der auf `/usr/lib/systemd/system/multi-user.target` zeigt. `set-default` tut nichts weiter, als diesen Symlink zu ersetzen; `get-default` liest ihn. Deshalb bleibt die Änderung über Neustarts hinweg bestehen, während `isolate` das nicht tut.

## Übung 9 — Shutdown und Benachrichtigung

**A9.1** `shutdown -k` sendet die Shutdown-Warnmeldung per Wall und erstellt `/run/nologin` (blockiert neue Nicht-Root-Anmeldungen), **fährt aber niemals tatsächlich herunter** — es ist der "Drill"-Modus. `wall` broadcastet nur eine beliebige Nachricht an alle angemeldeten Terminals: kein Zeitplan, kein `/run/nologin`, keine Shutdown-Semantik. Benutze `wall` für Ankündigungen, `shutdown -k`, um den Benachrichtigungspfad deiner Wartungsprozedur zu testen.

**A9.2** `sudo shutdown -c` (äquivalent `systemctl cancel-shutdown` auf neuerem systemd). Beweis: `/run/nologin` wird entfernt, und `/run/systemd/shutdown/scheduled` existiert nicht mehr. `shutdown -c` kann auch eine eigene Wall-Nachricht tragen: `shutdown -c "Maintenance postponed"`.

**A9.3** Eine Unit hat es nicht geschafft, innerhalb ihres `TimeoutStopSec` zu stoppen (Standard 90 s in `DefaultTimeoutStopSec=`), sodass systemd gewartet und dann `SIGKILL` gesendet hat. Vor dem nächsten Neustart: `systemctl list-jobs` während des Stillstands, um zu sehen, was ausstehend ist, und danach `journalctl -b -1 | grep -iE 'timed out|killing|stop'`, um die Unit zu benennen. Dann behebe die `ExecStop`/`KillMode` der Unit, oder verringere ihr `TimeoutStopSec=`. Eine häufige reale Ursache ist ein NFS-Mount, dessen Server unerreichbar ist — überprüfe `systemd-analyze blame --order` und die `*.mount`-Units.

**A9.4** Ein `block`-Inhibitor **verhindert** die Operation vollständig, bis er freigegeben wird — `systemctl poweroff` verweigert (root kann mit `--force` oder `-i`/`--ignore-inhibitors` überschreiben). Ein `delay`-Inhibitor verhindert die Operation nicht; er verschiebt sie um höchstens `InhibitDelayMaxSec` (Standard 5 s, in `/etc/systemd/logind.conf`), sodass der Halter kritische Arbeit wie das Speichern des Zustands abschließen kann. `ModemManager` nimmt einen **`delay`**-Inhibitor auf `sleep`, sodass es das Modem vor dem Suspend sauber trennen kann, ohne jemals ein Suspend unbegrenzt blockieren zu können.

**A9.5** Ein einzelnes `--force` überspringt das Stoppen von Units und das saubere Unmounten, versucht aber immer noch zu synchronisieren; ein doppeltes `--force` ruft den Reboot/Poweroff-Syscall **sofort** auf — kein Unit-Shutdown, kein Dateisystem-Unmount, kein `sync()`. Jeglicher dirty Page Cache geht verloren, was Dateisystemkorruption und Datenverlust beim nächsten Boot bedeutet (ein Journaling-Dateisystem wird seine Metadaten wiederherstellen, nicht die Schreibvorgänge deiner Anwendung). Legitime Verwendung: eine Maschine, die bereits so verkeilt ist, dass ein sauberer Shutdown nicht fortgesetzt werden kann und man nur Konsolenzugriff hat — die Alternative wäre ein physischer Stromausfall, was strikt schlimmer ist, da er auch die eigenen Barrieren des Syscalls überspringt. Die `SysRq`-Sequenz `R E I S U B` ist die kontrolliertere Variante derselben Idee, weil `S` synchronisiert und `U` read-only remountet, bevor `B` neu startet.

## Übung 10 — Abschlussübung

**A10.1** `systemd.unit=emergency.target` behält systemd als PID 1, sodass `systemctl`, `journalctl -b`, `systemctl --failed` und Unit-Manipulation alle funktionieren — was genau das ist, was man braucht, um einen *Unit*-Fehler zu diagnostizieren, und es erlaubt, mit `systemctl default` zu gehen, statt blind neu zu starten. `init=/bin/bash` ersetzt PID 1 durch eine Shell: systemd läuft nie, sodass es kein Journal von diesem Boot gibt und kein `systemctl` — aber das ist genau, was man will, wenn **systemd selbst oder seine Konfiguration** das Kaputte ist (korruptes `/etc/systemd`, ein defektes `systemd`-Paket, oder ein Root-Passwort-Reset mit SELinux-Relabeling). Faustregel: Unit-Fehler → `emergency.target`; PID 1- oder Dateisystem-Fehler → `init=/bin/bash`.

**A10.2** `emergency.target` mountet das Root-Dateisystem **read-only** (und unter `init=/bin/bash` respektiert der Kernel das `ro`-Flag von `/proc/cmdline`). Jede Reparatur — Bearbeiten von `/etc/fstab`, Löschen einer defekten Unit, Ausführen von `passwd`, `systemctl disable` — schreibt auf `/etc` und scheitert mit `Read-only file system`, bis man remountet. `systemctl daemon-reload` nach der Bearbeitung ist ebenso nötig, damit Unit-Änderungen gesehen werden.

**A10.3** Erfolgreich: Firmware-POST und Boot-Device-Auswahl; der Bootloader (GRUB) hat sowohl den Kernel als auch die initramfs gefunden und geladen; der Kernel hat dekomprimiert, initialisiert, die initramfs in ein tmpfs entpackt und deren `/init` ausgeführt. Fehlgeschlagen: die initramfs konnte das durch `root=` benannte Gerät nicht finden oder mounten, sodass sie nie `switch_root` erreichte und niemals das reale `/sbin/init` ausführte. Das schränkt den Fehler auf genau drei Kandidaten ein: einen falschen `root=`-Wert, einen fehlenden Storage-/Dateisystem-Treiber in der initramfs, oder ein Gerät, das tatsächlich nicht existiert (nicht zusammengesetztes RAID/LVM, gesperrtes LUKS, fehlende Disk).

**A10.4** `degraded` bedeutet, dass der Boot abgeschlossen wurde und das Standard-Target erreicht wurde, aber **mindestens eine Unit im `failed`-Zustand** ist. Das System ist benutzbar; etwas darauf funktioniert nicht. Folge mit `systemctl --failed`, um sie aufzulisten, dann `journalctl -b -u <unit>` für jede. Es gibt einen Nicht-Null-Exit-Status zurück, was `systemctl is-system-running --wait` zum richtigen Health-Gate in Provisioning-Skripten und CI-Images macht — eine einfache "hat es gebootet?"-Prüfung würde eine still defekte Maschine bestehen lassen.

**A10.5** `WantedBy=` erstellt eine **`Wants=`**-Abhängigkeit vom Target zu deiner Unit: das Target *versucht*, sie zu starten, und wenn die Unit scheitert, erreicht das Target trotzdem `active`. `RequiredBy=` erstellt eine **`Requires=`**-Abhängigkeit: wenn deine Unit nicht startet, wird das Target als fehlgeschlagen betrachtet und nicht aktiviert, sodass der Boot kurz vor einem Login-Prompt stoppt. Beide werden erst nach `systemctl enable` wirksam (sie liegen im `[Install]`-Abschnitt und werden als Symlinks in `.wants/`- oder `.requires/`-Verzeichnissen realisiert). Praktischer Ratschlag: benutze `WantedBy=multi-user.target` für praktisch jeden gewöhnlichen Dienst; reserviere `RequiredBy=`/`Requires=` für echte harte Voraussetzungen, und kombiniere es mit `After=` — `Requires=` allein spezifiziert *ob*, nicht *wann*, und ohne Ordering starten beide Units parallel.

</details>