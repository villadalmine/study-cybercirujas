# 4.2 Understanding Computer Hardware

## Einführung

Bevor man ein Linux-System administrieren kann, muss man verstehen, welche Hardware-Komponenten in einem Computer zusammenarbeiten und wie Linux diese Komponenten dem Anwender und dem Kernel gegenüber repräsentiert. Dieses Thema behandelt die grundlegenden Hardware-Bausteine eines Rechners (CPU, RAM, Storage, Busse, Peripheriegeräte) sowie die Linux-Bordmittel, mit denen man diese Hardware identifizieren, überprüfen und ihren Status abfragen kann.

## Grundlegende Hardware-Komponenten

### CPU (Central Processing Unit)

Die CPU führt Instruktionen aus und ist über den **system bus** mit den restlichen Komponenten verbunden. Wichtige Eigenschaften sind Architektur (z. B. `x86_64`, `aarch64`), Anzahl der Cores/Threads sowie Taktfrequenz. Unter Linux liefert die Datei `/proc/cpuinfo` detaillierte Informationen über jede logische CPU:

```console
$ cat /proc/cpuinfo | head -n 12
processor       : 0
vendor_id       : GenuineIntel
model name      : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
cpu MHz         : 1801.000
cache size      : 8192 KB
physical id     : 0
siblings        : 8
core id         : 0
cpu cores       : 4
```

Übersichtlicher und leichter lesbar ist das Kommando `lscpu`, das dieselben Daten aus `/proc/cpuinfo` und `sysfs` zusammenfasst:

```console
$ lscpu
Architecture:        x86_64
CPU(s):               8
Thread(s) per core:   2
Core(s) per socket:   4
Model name:           Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

### Arbeitsspeicher (RAM)

Der **Random Access Memory** ist flüchtiger Speicher, in dem der Kernel und laufende Prozesse ihre Daten halten. Informationen dazu liefert `/proc/meminfo`, meist aber praktischer über den Befehl `free`:

```console
$ free -h
              total        used        free      shared  buff/cache   available
Mem:           15Gi       4.2Gi       6.1Gi       412Mi       5.0Gi        10Gi
Swap:         2.0Gi          0B       2.0Gi
```

`buff/cache` zeigt Speicher, den der Kernel für Caching nutzt, aber bei Bedarf wieder freigeben kann – wichtig, um `free`-Werte korrekt zu interpretieren.

### Massenspeicher (Storage Devices)

Klassische Festplatten (**HDD**, magnetisch, rotierende Scheiben) und **SSDs** (Flash-Speicher, ohne bewegliche Teile) werden im Kernel als Block Devices unter `/dev` repräsentiert, z. B. `/dev/sda` für das erste SATA/SCSI-Laufwerk oder `/dev/nvme0n1` für ein NVMe-SSD. Der Befehl `lsblk` zeigt alle Block Devices inklusive Partitionen als Baum:

```console
$ lsblk
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda      8:0    0 238.5G  0 disk
├─sda1   8:1    0   512M  0 part /boot/efi
└─sda2   8:2    0   238G  0 part /
```

`lsblk -f` zeigt zusätzlich Dateisystem-Typ, Label und UUID.

## Busse und Erweiterungskarten

### PCI (Peripheral Component Interconnect)

Interne Erweiterungskarten (Grafikkarte, Netzwerkkarte, Controller) hängen typischerweise am **PCI**- bzw. **PCI Express (PCIe)**-Bus. Der Befehl `lspci` listet alle erkannten PCI-Geräte auf:

```console
$ lspci
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620
00:14.0 USB controller: Intel Corporation Sunrise Point-LP USB 3.0 xHCI
02:00.0 Network controller: Intel Corporation Wireless-AC 9260
```

Mit `lspci -v` erhält man ausführlichere Informationen (u. a. verwendete **IRQ** und Kernel-Treiber), mit `lspci -k` zusätzlich den geladenen Kernel-Treiber pro Gerät.

### USB (Universal Serial Bus)

Externe Peripheriegeräte (Tastatur, Maus, USB-Sticks, Webcams) werden meist über **USB** angeschlossen. USB ist ein **hot-pluggable** Bus: Geräte können im laufenden Betrieb angeschlossen und entfernt werden, ohne das System neu zu starten. Der Befehl `lsusb` zeigt die USB-Topologie:

```console
$ lsusb
Bus 001 Device 003: ID 0781:5567 SanDisk Corp. Cruzer Blade
Bus 001 Device 002: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
```

`lsusb -v` liefert Detailinformationen aus den USB-Deskriptoren (Vendor ID, Product ID, unterstützte Konfigurationen).

## Ressourcen-Zuweisung: IRQ, I/O-Ports, DMA

Jedes Hardware-Gerät benötigt Systemressourcen, um mit der CPU zu kommunizieren:

- **IRQ (Interrupt Request)** – ein Signal, mit dem ein Gerät die CPU unterbricht, um Aufmerksamkeit anzufordern. Sichtbar über `/proc/interrupts`.
- **I/O-Ports** – Adressbereiche, über die die CPU direkt mit einem Gerät kommuniziert. Sichtbar über `/proc/ioports`.
- **DMA (Direct Memory Access)** – erlaubt Geräten, Daten direkt in den RAM zu schreiben, ohne die CPU dafür zu belasten. Sichtbar über `/proc/dma`.

```console
$ cat /proc/interrupts | head -n 5
           CPU0       CPU1
  0:         34          0   IO-APIC   2-edge      timer
  8:          1          0   IO-APIC   8-edge      rtc0
  9:          0          0   IO-APIC   9-fasteoi   acpi
```

## Kernel-Sichten auf Hardware: /proc und /sys

Linux stellt Hardware- und Kernel-Informationen als virtuelle, dateibasierte Schnittstellen bereit:

- **`/proc`** – Pseudo-Dateisystem mit Laufzeitinformationen über Kernel, Prozesse und Hardware (z. B. `/proc/cpuinfo`, `/proc/meminfo`, `/proc/interrupts`).
- **`/sys`** – strukturierter Baum, der das Kernel-**Device Model** abbildet: jedes erkannte Gerät, jeder Treiber und jeder Bus hat hier einen Eintrag.

```console
$ ls /sys/class/net
enp3s0  lo  wlp2s0
```

Beide Verzeichnisse enthalten keine echten Dateien auf der Festplatte, sondern werden vom Kernel dynamisch generiert.

## Hotplug und udev

Moderne Busse wie USB oder PCIe unterstützen **hotplug**: Wird ein Gerät angeschlossen, erkennt der Kernel es sofort, lädt bei Bedarf ein passendes Kernel-Modul und der **udev**-Daemon legt automatisch den passenden Geräteknoten unter `/dev` an (z. B. `/dev/sdb` für einen neu eingesteckten USB-Stick). Das Kernel-Log lässt sich dabei live mit `dmesg` verfolgen:

```console
$ dmesg | tail -n 5
[12345.678901] usb 1-2: new high-speed USB device number 4 using xhci_hcd
[12345.812345] sd 4:0:0:0: [sdb] Attached SCSI removable disk
```

## Referenzen

- LPI Learning Materials – Topic 4.2: Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- LPI Learning Materials – Linux Essentials (010-160) Übersicht: https://learning.lpi.org/en/learning-materials/010-160/
- man7.org – lspci(8): https://man7.org/linux/man-pages/man8/lspci.8.html
- man7.org – lsusb(8): https://man7.org/linux/man-pages/man8/lsusb.8.html
- man7.org – lsblk(8): https://man7.org/linux/man-pages/man8/lsblk.8.html
- man7.org – free(1): https://man7.org/linux/man-pages/man1/free.1.html
- man7.org – proc(5): https://man7.org/linux/man-pages/man5/proc.5.html