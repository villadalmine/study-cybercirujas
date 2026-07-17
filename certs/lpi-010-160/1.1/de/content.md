# 1.1 Linux Evolution and Popular Operating Systems

**Gewichtung im Examen: 2**

## Einführung

Linux ist heute das am weitesten verbreitete Betriebssystem der Welt — es läuft auf Servern, Smartphones, Routern, Supercomputern und in der Cloud. Um zu verstehen, was Linux ist und warum es so viele Varianten gibt, muss man zwischen drei Begriffen unterscheiden:

- **Kernel**: der Kern des Betriebssystems, der Hardware, Prozesse und Speicher verwaltet. *Linux* im engeren Sinn ist nur dieser Kernel.
- **GNU Tools**: die grundlegenden Programme (Shell, Compiler, Core Utilities), die vom GNU-Projekt stammen. Deshalb spricht man oft von *GNU/Linux*.
- **Distribution**: ein komplettes, installierbares System aus Kernel, GNU Tools, Package Manager und zusätzlicher Software.

## Kurze Geschichte

Die Wurzeln von Linux reichen bis zu **Unix** zurück, das 1969 in den Bell Labs von Ken Thompson und Dennis Ritchie entwickelt wurde. Unix etablierte Konzepte, die Linux bis heute prägt: hierarchisches Dateisystem, Multiuser-Betrieb und kleine Programme, die sich kombinieren lassen.

Wichtige Meilensteine:

| Jahr | Ereignis |
|------|----------|
| 1969 | Unix entsteht in den Bell Labs |
| 1983 | Richard Stallman startet das **GNU-Projekt** mit dem Ziel eines freien, Unix-ähnlichen Systems |
| 1991 | **Linus Torvalds** veröffentlicht die erste Version des Linux Kernels als Hobbyprojekt |
| 1992 | Der Kernel wird unter der **GNU General Public License (GPL)** lizenziert |
| 2000er | Linux dominiert Server, Supercomputer und Embedded Systems |
| 2008 | **Android** (mit Linux Kernel) erscheint und bringt Linux auf Milliarden Smartphones |

Dem GNU-Projekt fehlte Anfang der 1990er noch ein fertiger Kernel — der Linux Kernel füllte genau diese Lücke. Die Kombination aus GNU Userland und Linux Kernel ergab ein vollständiges freies Betriebssystem.

Die GPL ist entscheidend für die Evolution von Linux: Jeder darf den Quellcode nutzen, verändern und weitergeben, muss Änderungen aber unter derselben Lizenz veröffentlichen. Das ermöglichte die weltweite, gemeinschaftliche Entwicklung — und die Vielfalt an Distributionen.

## Was ist eine Distribution?

Niemand installiert „den Linux Kernel" allein. Eine **Distribution** (kurz *Distro*) bündelt:

- den Linux Kernel,
- System- und Anwendungssoftware (GNU Tools, Desktop Environment, Server-Dienste),
- einen **Package Manager** zur Installation und Aktualisierung von Software,
- einen Installer und Standardkonfigurationen.

Distributionen unterscheiden sich vor allem in Zielgruppe, Release-Modell und Package Manager.

### Die großen Distributionsfamilien

**Debian-Familie** — Package Manager: `dpkg` / `apt`, Paketformat `.deb`

- **Debian**: gemeinschaftlich entwickelt, sehr stabil, Basis vieler anderer Distros.
- **Ubuntu**: von Canonical, benutzerfreundlich, feste Releases alle 6 Monate, **LTS**-Versionen (Long Term Support) alle 2 Jahre mit 5 Jahren Support.
- **Linux Mint**: basiert auf Ubuntu, beliebt für Desktop-Einsteiger.
- **Raspberry Pi OS**: Debian-Variante für den Raspberry Pi.

**Red Hat-Familie** — Package Manager: `rpm` / `dnf`, Paketformat `.rpm`

- **Red Hat Enterprise Linux (RHEL)**: kommerzielle Enterprise-Distribution mit Support-Verträgen.
- **Fedora**: gemeinschaftliches „Upstream"-Projekt von Red Hat, aktuelle Software, Testfeld für RHEL.
- **CentOS Stream**: Entwicklungszweig zwischen Fedora und RHEL.
- **Rocky Linux / AlmaLinux**: kostenlose, binärkompatible RHEL-Alternativen.

**SUSE-Familie** — Package Manager: `rpm` / `zypper`

- **SUSE Linux Enterprise Server (SLES)**: kommerziell, verbreitet im Enterprise-Umfeld.
- **openSUSE**: Community-Variante (Leap: feste Releases, Tumbleweed: Rolling Release).

**Unabhängige Distributionen**

- **Arch Linux**: Rolling Release, minimalistisch, für erfahrene Nutzer.
- **Gentoo**: Software wird aus dem Quellcode kompiliert.
- **Alpine Linux**: extrem klein, Standard in vielen **Containern**.

### Release-Modelle

- **Fixed Release**: Versionen erscheinen in festen Zyklen (z. B. Ubuntu 24.04 LTS). Vorhersehbar und stabil — bevorzugt auf Servern.
- **Rolling Release**: kontinuierliche Updates ohne Versionssprünge (z. B. Arch, openSUSE Tumbleweed). Immer aktuell, aber weniger konservativ.

## Linux in Embedded Systems

**Embedded Systems** sind Computer, die in Geräte eingebaut sind. Linux dominiert diesen Bereich, weil es frei anpassbar, lizenzkostenfrei und auf schwacher Hardware lauffähig ist:

- **Android**: das meistgenutzte Betriebssystem der Welt. Es verwendet den Linux Kernel, ersetzt aber das GNU Userland durch eigene Bibliotheken und die Android Runtime. Entwickelt von Google, Quellcode über das **Android Open Source Project (AOSP)** verfügbar.
- **Raspberry Pi**: Einplatinencomputer für Bildung, Prototyping und IoT-Projekte.
- **Netzwerkgeräte**: viele Router laufen mit Linux (z. B. **OpenWrt** als freie Router-Firmware).
- **Smart TVs, Autos, Industriesteuerungen**: häufig Linux-basiert.

## Linux in der Cloud

Cloud Computing ist einer der wichtigsten Wachstumsbereiche von Linux. Die großen Anbieter (Amazon Web Services, Google Cloud, Microsoft Azure) betreiben ihre Infrastruktur überwiegend mit Linux, und die Mehrheit der virtuellen Maschinen in der Cloud läuft unter Linux. Auch moderne Cloud-Technologien bauen direkt auf Linux auf:

- **Virtualization**: mehrere virtuelle Maschinen teilen sich physische Hardware (z. B. mit **KVM**, dem Hypervisor im Linux Kernel).
- **Container**: leichtgewichtige, isolierte Umgebungen (z. B. **Docker**), die Kernel-Funktionen wie Namespaces und cgroups nutzen.
- **Kubernetes**: Orchestrierung von Containern — läuft auf Linux-Knoten.

## Andere populäre Betriebssysteme

Für das Examen sollte man Linux im Vergleich einordnen können:

- **Microsoft Windows**: proprietär, dominiert den Desktop-Markt. Eigene Konzepte (Registry, Laufwerksbuchstaben wie `C:`), nicht Unix-basiert. Mit dem **Windows Subsystem for Linux (WSL)** lässt sich Linux unter Windows ausführen.
- **Apple macOS**: proprietär, aber Unix-zertifiziert — es basiert auf **Darwin**, einem BSD-Abkömmling. Das Terminal unter macOS verhält sich daher sehr ähnlich wie eine Linux Shell.
- **BSD-Familie** (FreeBSD, OpenBSD, NetBSD): freie Unix-Nachfahren mit eigener Lizenz (BSD License, freizügiger als die GPL) und eigenem Kernel — kein Linux, aber eng verwandt.
- **Kommerzielle Unix-Systeme** (AIX von IBM, HP-UX, Oracle Solaris): historisch bedeutend im Enterprise-Bereich, heute weitgehend von Linux verdrängt.

## Praxis: Welches System läuft hier?

Die eigene Distribution und Kernel-Version lassen sich direkt abfragen. Die Datei `/etc/os-release` enthält Informationen zur Distribution:

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.1 LTS"
VERSION_ID="24.04"
```

Das Feld `ID_LIKE=debian` zeigt hier die Distributionsfamilie: Ubuntu basiert auf Debian.

Der Befehl `uname` zeigt Informationen zum Kernel:

```bash
$ uname -a
Linux server01 6.8.0-45-generic #45-Ubuntu SMP x86_64 GNU/Linux
```

Die Ausgabe enthält den Kernel-Namen (`Linux`), den Hostname, die Kernel-Version (`6.8.0-45-generic`) und die Architektur (`x86_64`).

Alternativ liefert `lsb_release` (falls installiert) eine Zusammenfassung:

```bash
$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.1 LTS
Release:        24.04
Codename:       noble
```

## Zusammenfassung für das Examen

- **Linux** ist streng genommen nur der **Kernel**; ein nutzbares System entsteht erst als **Distribution**.
- Linus Torvalds veröffentlichte den Kernel **1991**; die **GPL** ermöglichte die gemeinschaftliche Entwicklung.
- Die wichtigsten Distributionsfamilien: **Debian** (Ubuntu, Mint, Raspberry Pi OS), **Red Hat** (RHEL, Fedora, Rocky/Alma) und **SUSE** (SLES, openSUSE).
- **Android** nutzt den Linux Kernel und ist das verbreitetste Betriebssystem überhaupt.
- Linux dominiert **Server, Cloud, Embedded Systems und Supercomputer**; Windows dominiert den Desktop; macOS ist ein Unix-System.
- `cat /etc/os-release` und `uname -a` identifizieren Distribution und Kernel.

## Referenzen

- LPI Learning Materials, Lesson 1.1 — Linux Evolution and Popular Operating Systems: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- LPI Linux Essentials Exam Objectives (Version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- The Linux Kernel Archives: https://www.kernel.org/
- GNU-Projekt und GPL: https://www.gnu.org/ und https://www.gnu.org/licenses/gpl-3.0.html
- Debian: https://www.debian.org/ · Ubuntu: https://ubuntu.com/ · Fedora: https://fedoraproject.org/ · openSUSE: https://www.opensuse.org/
- Android Open Source Project: https://source.android.com/
- FreeBSD: https://www.freebsd.org/