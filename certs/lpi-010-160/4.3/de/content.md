# 4.3 Where Data is Stored

## Einleitung

Linux organisiert alle Daten in einem einzigen, hierarchischen Verzeichnisbaum, der bei `/` (root) beginnt. Es gibt keine Laufwerksbuchstaben wie unter Windows (`C:`, `D:`) – jedes Filesystem, egal ob interne Festplatte, USB-Stick oder Netzwerkfreigabe, wird an einer bestimmten Stelle in diesen einen Baum eingehängt (gemountet). Die Struktur dieses Baums folgt größtenteils dem **Filesystem Hierarchy Standard (FHS)**, einer Konvention, an die sich die meisten Distributionen halten, damit Programme und Administratoren wissen, wo bestimmte Arten von Dateien zu finden sind.

## Der Filesystem Hierarchy Standard (FHS)

Der FHS definiert Zweck und Inhalt der wichtigsten Top-Level-Verzeichnisse. Eine Übersicht:

| Verzeichnis | Zweck |
|---|---|
| `/` | Root, Ausgangspunkt des gesamten Baums |
| `/bin`, `/sbin` | Essentielle Binaries für alle User bzw. für root (auf modernen Systemen meist Symlinks nach `/usr/bin`, `/usr/sbin`) |
| `/etc` | Systemweite Konfigurationsdateien |
| `/home` | Home-Verzeichnisse der normalen User |
| `/root` | Home-Verzeichnis des root-Users |
| `/tmp` | Temporäre Dateien, oft bei Neustart geleert |
| `/var` | Variable Daten: Logs, Spool, Caches |
| `/usr` | Programme, Bibliotheken und Dokumentation, die von mehreren Usern geteilt werden |
| `/opt` | Optionale Third-Party-Software-Pakete |
| `/boot` | Kernel-Images und Bootloader-Dateien |
| `/dev` | Device-Files, repräsentieren Hardware |
| `/media`, `/mnt` | Mount-Points für Wechseldatenträger bzw. temporäre manuelle Mounts |
| `/proc`, `/sys` | Virtuelle Filesysteme mit Kernel- und Hardware-Informationen |
| `/lib` | Shared Libraries, die von Binaries in `/bin` und `/sbin` benötigt werden |

## Wichtige Verzeichnisse im Detail

### `/etc` – Konfiguration

Enthält reine Textdateien zur Systemkonfiguration, z. B. `/etc/passwd` (User-Accounts), `/etc/fstab` (permanente Mounts) oder `/etc/hostname`. Hier liegt nie ausführbarer Programmcode, nur Konfiguration.

### `/var` – Variable Daten

Alles, was sich zur Laufzeit ändert und nicht zum eigentlichen Programm gehört:

```
$ ls /var
cache  lib  local  log  lock  mail  opt  run  spool  tmp
```

- `/var/log` – Logfiles, z. B. `/var/log/syslog` oder `/var/log/journal`
- `/var/spool` – Warteschlangen, z. B. für Print- oder Mail-Jobs
- `/var/tmp` – Temporäre Dateien, die im Gegensatz zu `/tmp` einen Neustart überleben sollen

### `/home` und `/root`

Jeder User hat unter `/home/<username>` sein eigenes Home-Verzeichnis mit persönlichen Dateien und Dotfiles (`~/.bashrc`, `~/.config`). Der Superuser `root` hat davon getrennt sein eigenes Home unter `/root`, damit es auch dann erreichbar bleibt, wenn `/home` (z. B. auf einer separaten Partition) nicht gemountet ist.

### `/usr` – Shareable, Read-Only Data

`/usr` enthält den Großteil der installierten Software:

```
$ ls /usr
bin  games  include  lib  local  sbin  share  src
```

- `/usr/bin`, `/usr/sbin` – Programme für normale User bzw. Admin-Tools
- `/usr/local` – manuell installierte Software, die nicht vom Paketmanager verwaltet wird
- `/usr/share` – architekturunabhängige Daten wie Man-Pages, Icons, Dokumentation

### `/boot`, `/dev`, `/opt`

- `/boot` enthält den Kernel (`vmlinuz-*`), die initramfs sowie Bootloader-Konfiguration (z. B. GRUB).
- `/dev` enthält Device-Nodes wie `/dev/sda` (erste Festplatte) oder `/dev/null`.
- `/opt` wird für in sich geschlossene, optionale Softwarepakete von Drittanbietern genutzt (z. B. `/opt/google/chrome`).

## Virtuelle Filesysteme: `/proc` und `/sys`

`/proc` und `/sys` sind keine echten Daten auf der Festplatte, sondern **virtuelle Filesysteme**, die der Kernel zur Laufzeit im RAM erzeugt. Sie erlauben es, Kernel- und Hardware-Informationen wie normale Dateien zu lesen (und teils zu schreiben).

```
$ cat /proc/cpuinfo | head -3
processor       : 0
vendor_id       : GenuineIntel
model name      : Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz

$ cat /proc/meminfo | head -3
MemTotal:       16321364 kB
MemFree:         2103244 kB
MemAvailable:    9871232 kB

$ cat /proc/version
Linux version 6.8.0 (gcc version 13.2.0) #1 SMP PREEMPT_DYNAMIC
```

Jeder laufende Prozess hat außerdem ein eigenes Verzeichnis `/proc/<PID>/` mit Details zu seinem Status, offenen Filedescriptors usw.:

```
$ cat /proc/1/status | head -2
Name:   systemd
State:  S (sleeping)
```

`/sys` (sysfs) liefert ähnlich strukturierte Informationen speziell zu Geräten und Kernel-Subsystemen, z. B. `/sys/class/net` für Netzwerkinterfaces.

## Mount Points und das Konzept des Mountens

Da es unter Linux nur einen Verzeichnisbaum gibt, muss jedes zusätzliche Filesystem (eine Partition, ein USB-Stick, ein Netzlaufwerk) an einem leeren Verzeichnis "angehängt" werden – diesen Vorgang nennt man **mounten**, das Zielverzeichnis heißt **mount point**.

### Aktuelle Mounts anzeigen

```
$ lsblk
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda      8:0    0   500G  0 disk
├─sda1   8:1    0   512M  0 part /boot
└─sda2   8:2    0 499.5G  0 part /
sdb      8:16   1    32G  0 disk
└─sdb1   8:17   1    32G  0 part

$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       499G   87G  387G  19% /
/dev/sda1       512M  120M  380M  24% /boot
```

### Manuell mounten und unmounten

```
$ sudo mount /dev/sdb1 /mnt/usb
$ df -h /mnt/usb
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1        32G   14G   18G  45% /mnt/usb

$ sudo umount /mnt/usb
```

Wichtig: `umount` (nicht "unmount") lässt sich nicht ausführen, solange eine Shell oder ein Prozess das Verzeichnis noch als aktuelles Arbeitsverzeichnis verwendet oder offene Dateien darauf liegen – das Filesystem gilt dann als "busy".

### `/etc/fstab` – permanente Mounts

Damit wichtige Filesystems bei jedem Boot automatisch gemountet werden, trägt man sie in `/etc/fstab` ein. Jede Zeile hat sechs Felder: Device, Mount Point, Filesystem-Typ, Mount-Optionen, Dump-Flag, fsck-Reihenfolge.

```
# <device>                              <mount point>  <type>  <options>       <dump> <pass>
UUID=8f3a1c2e-...                       /              ext4    defaults        0      1
UUID=1a2b3c4d-...                       /boot          ext4    defaults        0      2
/dev/sdb1                               /mnt/data      xfs     defaults,noauto 0      0
```

Devices werden meist über ihre **UUID** statt über Namen wie `/dev/sdb1` referenziert, da sich die Zuordnung `/dev/sdX` je nach Erkennungsreihenfolge der Hardware beim Boot ändern kann, während die UUID fest an das Filesystem gebunden bleibt. Die Option `noauto` verhindert, dass ein Eintrag automatisch beim Boot gemountet wird – nützlich für Wechseldatenträger, die nicht immer angeschlossen sind, aber trotzdem einen festen Mount-Befehl (`mount /mnt/data`) haben sollen.

### Automatisches Mounten von Wechseldatenträgern

Auf Desktop-Systemen übernimmt in der Regel `udisks`/`udisksctl` (im Hintergrund von der Desktop-Umgebung angestoßen) das automatische Mounten, sobald ein USB-Stick eingesteckt wird – typischerweise unter `/media/<username>/<label>`:

```
$ udisksctl mount -b /dev/sdb1
Mounted /dev/sdb1 at /media/anna/USB_STICK
```

## `/media` vs. `/mnt`

Der FHS unterscheidet zwischen beiden Verzeichnissen nach Verwendungszweck:

- **`/media`** – Mount-Points für Wechseldatenträger (USB-Sticks, CDs), typischerweise automatisch verwaltet
- **`/mnt`** – temporäre, manuelle Mounts durch den Administrator (z. B. um kurzfristig ein Backup-Volume einzuhängen)

## Prüfungsrelevante Punkte

- Der Linux-Verzeichnisbaum ist einheitlich; alles hängt unter `/`
- FHS definiert Zweck der Top-Level-Verzeichnisse (`/etc`, `/var`, `/usr`, `/home`, …)
- `/proc` und `/sys` sind virtuelle Filesysteme mit Live-Kernel-Informationen, keine echten Dateien auf Platte
- **`mount`** hängt ein Filesystem manuell ein, **`umount`** löst es wieder
- **`/etc/fstab`** steuert, welche Filesystems beim Boot automatisch gemountet werden
- **`/media`** für automatisch gemountete Wechseldatenträger, **`/mnt`** für manuelle Admin-Mounts

## Referenzen

- LPI Learning Materials – Where Data is Stored: https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Filesystem Hierarchy Standard (FHS) 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- man mount(8): https://man7.org/linux/man-pages/man8/mount.8.html
- man umount(8): https://man7.org/linux/man-pages/man8/umount.8.html
- man fstab(5): https://man7.org/linux/man-pages/man5/fstab.5.html
- Kernel-Dokumentation zu `/proc`: https://www.kernel.org/doc/html/latest/filesystems/proc.html
- Arch Wiki – fstab: https://wiki.archlinux.org/title/Fstab