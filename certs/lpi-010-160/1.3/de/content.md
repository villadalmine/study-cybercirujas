# 1.3 Open Source Software and Licensing

## Was bedeutet "Open Source"?

Open Source Software (OSS) ist Software, deren Source Code öffentlich zugänglich ist und die unter einer Lizenz verteilt wird, die es erlaubt, den Code zu lesen, zu verändern und weiterzugeben. Zwei Organisationen prägen die Bewegung mit leicht unterschiedlicher Motivation:

- **Free Software Foundation (FSF)**, gegründet 1985 von Richard Stallman, argumentiert ethisch/philosophisch. Software soll dem Nutzer vier Freiheiten garantieren:
  - **Freedom 0**: das Programm für jeden Zweck auszuführen
  - **Freedom 1**: den Source Code zu studieren und anzupassen
  - **Freedom 2**: Kopien weiterzugeben
  - **Freedom 3**: modifizierte Versionen zu veröffentlichen

- **Open Source Initiative (OSI)**, gegründet 1998, argumentiert eher pragmatisch/wirtschaftlich (bessere Qualität, Sicherheit, Kooperation) und pflegt die **Open Source Definition (OSD)**, den Kriterienkatalog, den eine Lizenz erfüllen muss, um als "Open Source" (OSI-approved) zu gelten.

**Free Software** und **Open Source** meinen in der Praxis fast dieselbe Menge an Lizenzen, unterscheiden sich aber in der Begründung. Um diesen Streit zu umgehen, verwendet man oft die neutralen Sammelbegriffe **FOSS** (Free and Open Source Software) oder **FLOSS** (Free/Libre and Open Source Software).

Wichtig für die Prüfung: "Open Source" ist nicht dasselbe wie "kostenlos" (gemeint ist "free as in freedom", nicht "free as in beer") und nicht dasselbe wie "Public Domain" (bei OSS behält der Autor i. d. R. das Copyright, erteilt aber Nutzungsrechte über die Lizenz).

## Lizenzkategorien

Man unterscheidet OSS-Lizenzen grob nach dem Grad an Copyleft:

| Kategorie | Prinzip | Beispiele |
|---|---|---|
| **Copyleft (strong)** | Abgeleitete Werke müssen unter derselben Lizenz veröffentlicht werden | GPLv2, GPLv3 |
| **Copyleft (weak)** | Nur Änderungen an der Bibliothek selbst müssen offengelegt werden, verlinkende Programme nicht | LGPL |
| **Copyleft (network)** | Wie GPL, aber greift auch, wenn Software nur über ein Netzwerk (SaaS) angeboten wird | AGPL |
| **Permissive** | Kaum Auflagen, Code darf auch in proprietäre Produkte übernommen werden | MIT, BSD, Apache 2.0 |
| **Public-Domain-ähnlich** | Praktisch keine Rechte behalten | CC0, Unlicense |

Für nicht-Software-Werke (Dokumentation, Kursmaterial, Bilder) sind die **Creative Commons**-Lizenzen (z. B. CC BY, CC BY-SA) verbreitet, aber technisch keine Software-Lizenzen.

## Konkrete Lizenzen

- **GNU GPL (GNU General Public License)**: Copyleft. Wer GPL-Code verändert und weitergibt, muss den Source Code unter GPL mitliefern. Beispiel: der Linux-Kernel steht unter **GPLv2**.
- **LGPL (Lesser GPL)**: für Bibliotheken gedacht, damit auch proprietäre Software dagegen linken kann, ohne selbst GPL zu werden. Beispiel: glibc.
- **BSD/MIT**: sehr kurze, permissive Lizenzen. Erlauben Verwendung fast ohne Auflagen (nur Copyright-Hinweis muss erhalten bleiben). Beispiel: die meisten Komponenten des X Window System, viele npm-Pakete.
- **Apache License 2.0**: permissiv wie MIT/BSD, enthält zusätzlich einen expliziten Patent-Grant. Beispiel: Kubernetes, Apache HTTP Server.
- **AGPL (Affero GPL)**: schließt die sogenannte "SaaS-Lücke" der GPL — wer eine AGPL-Anwendung nur über ein Netzwerk anbietet (ohne Binary weiterzugeben), muss trotzdem den Source Code bereitstellen. Beispiel: MongoDB (frühere Versionen).

## Lizenz eines installierten Pakets prüfen

Auf Debian/Ubuntu-Systemen liegt zu jedem Paket eine Copyright-Datei bei:

```
$ dpkg -L bash | grep copyright
/usr/share/doc/bash/copyright

$ head -n 8 /usr/share/doc/bash/copyright
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: bash
Source: https://ftp.gnu.org/gnu/bash/

Files: *
Copyright: 1988-2022 Free Software Foundation, Inc.
License: GPL-3+
```

Auch Sprachpaketmanager zeigen die Lizenz eines Pakets an:

```
$ pip show requests | grep -i license
License: Apache 2.0

$ npm view lodash license
MIT
```

Ein Tool wie **licensecheck** (Paket `devscripts`) durchsucht ganze Quellbäume nach Lizenzhinweisen:

```
$ licensecheck -r src/
src/main.c: GPL (v2 or later)
src/utils.py: MIT/X11 (BSD like)
```

## Warum Open Source in der Praxis wichtig ist

- **Distributionen und Forking**: Weil der Code offen ist, kann jeder ein Projekt forken. Bekanntes Beispiel: **LibreOffice** entstand 2010 als Fork von OpenOffice.org, nachdem die Community mit Oracles Verwaltung des Projekts unzufrieden war.
- **Ökosystem proprietär vs. Open Source**: Für viele proprietäre Programme gibt es etablierte FOSS-Alternativen:

| Proprietär | Open-Source-Alternative |
|---|---|
| Microsoft Office | LibreOffice |
| Adobe Photoshop | GIMP |
| Windows | Linux-Distributionen (Debian, Fedora, …) |
| Microsoft SQL Server | PostgreSQL, MySQL/MariaDB |

- **Unternehmensrelevanz**: Beim Einsatz fremder OSS-Komponenten in eigener Software muss man die jeweilige Lizenz beachten (Compliance), z. B. ob Copyleft-Pflichten (Source-Offenlegung) entstehen, wenn man den Code modifiziert und weitergibt.

## Referenzen

- LPI Learning Materials, Topic 1.3: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- Free Software Foundation, The Four Freedoms: https://www.gnu.org/philosophy/free-sw.html
- Open Source Initiative, The Open Source Definition: https://opensource.org/osd
- GNU General Public License, Version 3: https://www.gnu.org/licenses/gpl-3.0.html
- GNU Lesser General Public License: https://www.gnu.org/licenses/lgpl-3.0.html
- GNU Affero General Public License: https://www.gnu.org/licenses/agpl-3.0.html
- Open Source Initiative, Approved Licenses (Übersicht MIT, BSD, Apache 2.0 etc.): https://opensource.org/licenses
- Debian Machine-Readable Copyright Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
- Creative Commons Licenses: https://creativecommons.org/licenses/