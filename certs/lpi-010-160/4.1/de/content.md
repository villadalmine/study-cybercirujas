# 4.1 Choosing an Operating System

## Was ist ein Operating System?

Ein **Operating System** (Betriebssystem, OS) ist die Softwareschicht, die zwischen der Hardware eines Computers und den Anwendungsprogrammen (Applications) vermittelt. Es übernimmt zentrale Aufgaben:

- **Process Management**: Verwaltung laufender Programme (Prozesse), Zuteilung von CPU-Zeit
- **Memory Management**: Verwaltung von RAM und Swap-Speicher
- **Device Management**: Ansteuerung von Hardware über Treiber (Drivers)
- **File System Management**: Organisation von Daten auf Speichermedien
- **User Interface**: Bereitstellung einer Command Line Interface (CLI) und/oder Graphical User Interface (GUI)

Im Zentrum jedes Betriebssystems steht der **Kernel**. Er läuft im privilegierten Modus (Kernel Space) und stellt Systemaufrufe (System Calls) bereit, über die Anwendungen im User Space auf Hardware-Ressourcen zugreifen. Bei Linux ist der Kernel selbst nur ein Teil des Systems – Werkzeuge, Bibliotheken (z. B. **glibc**) und die Shell kommen üblicherweise vom **GNU-Projekt**, weshalb man korrekt von **GNU/Linux** spricht.

## Überblick über verbreitete Betriebssysteme

| OS-Familie | Kernel | Typische Nutzung | Lizenzmodell |
|---|---|---|---|
| Linux-Distributionen | Linux Kernel | Server, Desktop, Embedded, Cloud | überwiegend Open Source |
| Microsoft Windows | Windows NT Kernel | Desktop, Gaming, Enterprise | Proprietär |
| Apple macOS | XNU (Darwin, BSD-basiert) | Desktop, kreative Berufe | Proprietär |
| BSD-Familie (FreeBSD, OpenBSD) | BSD Kernel | Server, Networking, Security | Open Source (BSD-Lizenz) |

Linux ist kein einzelnes Produkt, sondern ein Kernel, um den herum verschiedene **Distributionen** (Distros) zusammengestellt werden. Jede Distribution kombiniert den Kernel mit Paketmanager, Standardsoftware und Konfigurationswerkzeugen.

## Linux-Distributionen im Vergleich

Gängige Distributionsfamilien und ihre Paketformate:

| Distribution | Basis | Paketformat | Paketmanager |
|---|---|---|---|
| Debian, Ubuntu, Linux Mint | Debian | `.deb` | `dpkg`, `apt` |
| Fedora, RHEL, CentOS Stream, Rocky Linux | Red Hat | `.rpm` | `rpm`, `dnf` |
| openSUSE, SUSE Linux Enterprise | SUSE | `.rpm` | `rpm`, `zypper` |
| Arch Linux, Manjaro | Arch | `.pkg.tar.zst` | `pacman` |

**Auswahlkriterien** für eine Distribution:

- **Zielsystem**: Server (z. B. Debian, RHEL) vs. Desktop (z. B. Ubuntu, Fedora Workstation)
- **Release-Zyklus**: Rolling Release (Arch) vs. Fixed Release mit Long Term Support (LTS, z. B. Ubuntu 22.04 LTS)
- **Community vs. kommerzieller Support**: Fedora (community) vs. RHEL (kommerzieller Support durch Red Hat)
- **Verfügbare Dokumentation und Paketanzahl**

### Beispiel: Die eigene Distribution identifizieren

```console
$ cat /etc/os-release
PRETTY_NAME="Ubuntu 22.04.4 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.4 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
```

```console
$ uname -a
Linux workstation 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01) x86_64 GNU/Linux
```

`uname -a` zeigt Kernel-Version und Architektur, `/etc/os-release` liefert Distributionsname und -version – nützlich beim Troubleshooting oder bei der Auswahl kompatibler Pakete.

## Free and Open Source Software (FOSS)

Linux-Distributionen bestehen größtenteils aus **Free and Open Source Software**. Wichtige Konzepte:

- **Open Source**: Der Quellcode ist öffentlich einsehbar, veränderbar und weiterverteilbar
- **Free Software**: Bezieht sich laut Free Software Foundation (FSF) auf vier Freiheiten (Ausführen, Studieren, Verändern, Weitergeben) – "free" meint hier *Freiheit*, nicht zwingend *kostenlos*
- **Copyleft**: Lizenzen wie die **GNU General Public License (GPL)** verlangen, dass abgeleitete Werke unter derselben Lizenz weitergegeben werden
- **Permissive Lizenzen**: Z. B. **MIT-Lizenz** oder **BSD-Lizenz** erlauben auch proprietäre Weiterverwendung

Abzugrenzen von Open Source Software sind andere Lizenzmodelle:

| Modell | Quellcode offen? | Kostenlos? | Beispiel |
|---|---|---|---|
| Open Source (GPL, MIT) | Ja | meist ja | Linux Kernel, LibreOffice |
| Freeware | Nein | Ja | Skype (früher), Adobe Reader |
| Shareware | Nein | zeitlich/funktional begrenzt kostenlos | ältere Trial-Software |
| Proprietär (Closed Source) | Nein | Nein | Microsoft Windows, macOS |

## Hardware-Kompatibilität

Da der Linux Kernel Treiber für eine Vielzahl von Geräten mitbringt, ist die Hardware-Unterstützung meist gut, aber nicht garantiert. Zu beachten:

- **Proprietäre Treiber**: Bestimmte Hardware (z. B. manche WLAN-Chipsätze, GPUs von NVIDIA) benötigt Closed-Source-Treiber, die separat installiert werden müssen
- **Firmware Blobs**: Binäre Firmware-Dateien, die vom Kernel geladen werden, ohne selbst Open Source zu sein
- **Kompatibilitätsprüfung vor der Installation**: Viele Distributionen bieten Hardware-Kompatibilitätslisten (HCLs) an

```console
$ lspci -k | grep -A 3 -i vga
01:00.0 VGA compatible controller: NVIDIA Corporation TU117M
        Kernel driver in use: nouveau
        Kernel modules: nouveau, nvidia_drm, nvidia
```

Der Befehl `lspci -k` zeigt, welcher Kernel-Treiber aktuell für ein Gerät verwendet wird – hilfreich, um zwischen freiem (`nouveau`) und proprietärem Treiber (`nvidia`) zu unterscheiden.

## Zusammenfassung

Ein Operating System vermittelt zwischen Hardware und Anwendungen und besteht im Kern aus einem Kernel plus Systemwerkzeugen. Linux unterscheidet sich von Windows und macOS durch seine Vielzahl an Distributionen und seine Verwurzelung im Open-Source-Modell. Bei der Wahl einer Distribution spielen Einsatzzweck, Paketmanager, Release-Zyklus und Support eine Rolle. Lizenzmodelle wie GPL, MIT oder BSD regeln, wie Software genutzt, verändert und weiterverteilt werden darf, und unterscheiden sich klar von Freeware, Shareware und proprietärer Software. Hardware-Kompatibilität hängt von der Verfügbarkeit offener oder proprietärer Treiber ab.

## Referenzen

- LPI Learning Materials, Topic 4.1 Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- GNU Operating System – Was ist Free Software: https://www.gnu.org/philosophy/free-sw.html
- GNU General Public License: https://www.gnu.org/licenses/gpl-3.0.html
- Debian Project Dokumentation: https://www.debian.org/doc/
- Fedora Project Dokumentation: https://docs.fedoraproject.org/
- Arch Linux Wiki: https://wiki.archlinux.org/
- man-Pages: `uname(1)`, `lspci(8)`, `os-release(5)`