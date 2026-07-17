# Geführte Übungen – Thema 1.1: Linux Evolution and Popular Operating Systems

> **Voraussetzungen:** Ein Linux-System mit Terminal-Zugang (eine virtuelle Maschine, WSL, ein Live-USB-Stick oder ein Raspberry Pi genügen). Alle Befehle sind rein lesend und verändern nichts am System.

---

## Übung 1: Den Linux Kernel auf deinem System identifizieren

Linux ist streng genommen nur der **Kernel** – der Kern des Betriebssystems, den Linus Torvalds 1991 als Student in Helsinki startete. Alles andere (Shell, Tools, grafische Oberfläche) kommt aus anderen Projekten dazu. Schauen wir uns den Kernel direkt an.

1. Öffne ein Terminal und zeige den Namen des Kernels an:
   ```bash
   uname -s
   ```
2. Zeige die Version des laufenden Kernels an:
   ```bash
   uname -r
   ```
3. Zeige alle Informationen auf einmal an, inklusive Architektur:
   ```bash
   uname -a
   ```
4. Lies dieselbe Information direkt aus dem `/proc`-Dateisystem – dort siehst du zusätzlich, mit welchem Compiler der Kernel gebaut wurde:
   ```bash
   cat /proc/version
   ```

**Frage 1.1:** Der Befehl `uname -r` liefert z. B. `6.8.0-45-generic`. Welcher Teil davon ist die eigentliche Kernel-Version, und woher stammt der Rest?

**Frage 1.2:** Wer hat den Linux Kernel ursprünglich entwickelt, in welchem Jahr, und was war die Motivation dahinter?

**Frage 1.3:** Warum ist die Ausgabe von `uname -s` (`Linux`) allein noch kein vollständiges Betriebssystem?

---

## Übung 2: Kernel vs. Distribution – was läuft hier eigentlich?

Ein nutzbares System entsteht erst, wenn jemand den Kernel mit Software zu einem Gesamtpaket schnürt: einer **Distribution**. Finde heraus, welche du benutzt.

1. Zeige die Standard-Datei an, die jede moderne Distribution über sich selbst bereitstellt:
   ```bash
   cat /etc/os-release
   ```
2. Achte in der Ausgabe besonders auf die Felder `NAME`, `VERSION`, `ID` und – falls vorhanden – `ID_LIKE`.
3. Viele Systeme bieten zusätzlich dieses Kommando an (wenn es fehlt, ist das auch ein Ergebnis – notiere es):
   ```bash
   lsb_release -a
   ```
4. Vergleiche: Die Kernel-Version aus Übung 1 und der Distributionsname aus dieser Übung sind zwei verschiedene Dinge mit getrennten Versionsnummern.

**Frage 2.1:** Was ist der Unterschied zwischen dem Linux Kernel und einer Linux Distribution? Nenne je zwei Beispiele für Dinge, die eine Distribution zusätzlich zum Kernel mitliefert.

**Frage 2.2:** Auf einem System zeigt `/etc/os-release` das Feld `ID_LIKE=debian`. Was sagt dir das über die Herkunft dieser Distribution?

**Frage 2.3:** Ubuntu 24.04 kann mit Kernel 6.8 laufen, Debian 12 mit Kernel 6.1. Warum haben Distribution und Kernel unabhängige Versionsnummern?

---

## Übung 3: Distributionsfamilien am Package Manager erkennen

Distributionen lassen sich in Familien gruppieren, und das zuverlässigste Erkennungszeichen ist der **package manager**. Prüfe, welcher auf deinem System vorhanden ist.

1. Teste der Reihe nach, welche der großen Paketverwaltungen installiert sind (`command -v` gibt den Pfad aus, wenn das Programm existiert, und nichts, wenn nicht):
   ```bash
   command -v apt
   command -v dnf
   command -v yum
   command -v zypper
   command -v pacman
   ```
2. Notiere, welcher Befehl einen Pfad zurückgegeben hat.
3. Frage den gefundenen package manager nach seiner Version, z. B.:
   ```bash
   apt --version    # bzw. dnf --version, zypper --version, pacman -V
   ```

**Frage 3.1:** Ordne zu: Welche Distributionsfamilie gehört typischerweise zu `apt`, welche zu `dnf`/`yum`, welche zu `zypper`?

**Frage 3.2:** Nenne zu jeder der beiden großen Familien (Debian-Familie und Red Hat-Familie) mindestens zwei bekannte Distributionen.

**Frage 3.3:** Für das Beispiel im Prüfungsstil: Ein Administrator arbeitet auf einem System mit `dnf` und Paketen im `.rpm`-Format. Welche Distributionen kommen infrage – Ubuntu, Fedora, Linux Mint oder Rocky Linux?

---

## Übung 4: Free Software und die GPL-Lizenz aufspüren

Linux existiert nur, weil Software unter **Free Software**-Lizenzen geteilt wird. Der Kernel steht unter der **GNU General Public License (GPL)**, Version 2. Solche Lizenztexte liegen auf deinem System – finde sie.

1. Suche nach Lizenztexten auf deinem System (je nach Distribution liegt es an einem anderen Ort; probiere beide):
   ```bash
   ls /usr/share/common-licenses/ 2>/dev/null
   ls /usr/share/licenses/ 2>/dev/null | head -20
   ```
2. Öffne einen GPL-Lizenztext, falls vorhanden (mit `q` beendest du die Anzeige):
   ```bash
   less /usr/share/common-licenses/GPL-2 2>/dev/null || less /usr/share/licenses/*/COPYING 2>/dev/null
   ```
3. Lies die ersten Absätze der Präambel: Es geht um *freedom to share and change*, nicht um den Preis.
4. Sieh dir zum Vergleich an, unter welcher Lizenz der Kernel offiziell steht – die Datei `COPYING` im Kernel-Quellcode ist online einsehbar: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/COPYING

**Frage 4.1:** „Free“ in Free Software bedeutet nicht „kostenlos“. Was bedeutet es stattdessen? Nenne die vier Freiheiten in eigenen Worten.

**Frage 4.2:** Was verlangt die GPL von jemandem, der ein verändertes GPL-Programm weiterverbreitet?

**Frage 4.3:** Welches Projekt startete Richard Stallman 1983, und warum war es für Linux so wichtig, dass es schon vor 1991 existierte?

---

## Übung 5: Linux überall – Server, Cloud, Android und Embedded

Linux läuft längst nicht nur auf Desktops. Diese Übung ist eine Recherche-Aufgabe mit einem kleinen praktischen Teil.

1. Prüfe, wie lange dein System schon läuft – ein Hinweis darauf, warum Linux im Server-Bereich beliebt ist (Stabilität, kein Neustart-Zwang):
   ```bash
   uptime
   ```
2. Wenn du ein Android-Smartphone besitzt: Öffne dort *Einstellungen → Über das Telefon → Android-Version*. Viele Geräte zeigen dort auch die **Kernel-Version** an – vergleiche sie mit deiner aus Übung 1.
3. Recherchiere kurz auf der LPI-Lernplattform, welche Einsatzgebiete dort genannt werden: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
4. Wirf einen Blick auf https://distrowatch.com/ und notiere drei Distributionsnamen, die dir noch nie begegnet sind.

**Frage 5.1:** Basiert Android auf Linux? Und ist Android deshalb eine typische Linux Distribution wie Debian oder Fedora? Begründe.

**Frage 5.2:** Nenne vier verschiedene Gerätekategorien oder Einsatzgebiete (außer Desktop-PCs), in denen Linux heute läuft.

**Frage 5.3:** Ein Kollege sagt: „Für den Raspberry Pi gibt es kein richtiges Linux.“ Stimmt das? Wie heißt die offizielle Distribution für den Raspberry Pi?

---

## Übung 6: Die richtige Distribution wählen – ein Praxisszenario

In der Prüfung wird erwartet, dass du Distributionen grob nach Einsatzzweck einordnen kannst. Bearbeite dieses Szenario auf Papier oder in einer Textdatei.

1. Lege eine Notizdatei an:
   ```bash
   nano ~/distro-szenario.txt
   ```
2. Beantworte darin für jedes der folgenden Profile, welche Distribution (oder Familie) du empfehlen würdest und warum – ein bis zwei Sätze genügen:
   - **a)** Ein Unternehmen braucht einen Server mit kommerziellem Hersteller-Support und langen Support-Zeiträumen.
   - **b)** Eine Einsteigerin möchte einen einfach zu bedienenden Desktop, ohne viel zu konfigurieren.
   - **c)** Ein Entwickler will immer die allerneueste Software und akzeptiert dafür gelegentliche Instabilität.
   - **d)** Eine Schule sucht ein kostenloses, stabiles System für alte Rechner ohne kommerzielle Bindung.
3. Speichere mit `Ctrl+O`, `Enter` und verlasse den Editor mit `Ctrl+X`.

**Frage 6.1:** Welche Distributionen hast du für a) bis d) gewählt? (Musterlösung in den Antworten – Abweichungen sind in Ordnung, wenn die Begründung stimmt.)

**Frage 6.2:** Was unterscheidet ein „Enterprise“-Modell wie Red Hat Enterprise Linux von einem Community-Modell wie Debian?

**Frage 6.3:** Was bedeutet die Abkürzung **LTS** (z. B. bei Ubuntu 24.04 LTS), und warum ist das für Unternehmen relevant?

---

<details>
<summary><strong>Antworten</strong></summary>

### Übung 1

**Antwort 1.1:** Die eigentliche Kernel-Version ist der vordere Teil `6.8.0` (Schema *major.minor.patch*). Der Rest (z. B. `-45-generic`) wird von der Distribution angehängt: eine Build-Nummer und eine Variante des Distributions-Kernels. Der Upstream-Kernel von kernel.org kennt diese Zusätze nicht.

**Antwort 1.2:** Linus Torvalds, 1991, damals Student an der Universität Helsinki. Er wollte ein frei verfügbares, Unix-artiges Betriebssystem für seinen eigenen PC schaffen – als Alternative zum lehrbuchorientierten Minix – und stellte den Code offen ins Internet, damit andere mitentwickeln konnten.

**Antwort 1.3:** Der Kernel verwaltet nur Hardware, Speicher und Prozesse. Ohne Shell, Systemprogramme, Bibliotheken und Anwendungen kann ein Benutzer damit nichts anfangen. Erst die Kombination aus Kernel und Userland-Software (großteils aus dem GNU-Projekt) ergibt ein benutzbares Betriebssystem.

### Übung 2

**Antwort 2.1:** Der Kernel ist die Kernkomponente, die Hardware und Prozesse verwaltet. Eine Distribution ist ein Gesamtpaket aus Kernel **plus** z. B.: package manager, Shell und Kommandozeilen-Tools, Desktop-Umgebung, Installationsprogramm, Standard-Konfiguration und Sicherheits-Updates. (Zwei Beispiele genügen.)

**Antwort 2.2:** Die Distribution ist von Debian abgeleitet bzw. kompatibel zur Debian-Familie. Sie nutzt also typischerweise `.deb`-Pakete und `apt`. Ein klassisches Beispiel ist Ubuntu (`ID=ubuntu`, `ID_LIKE=debian`) oder Linux Mint.

**Antwort 2.3:** Weil Distribution und Kernel getrennte Projekte mit eigenen Release-Zyklen sind. Die Distribution wählt für jedes Release eine bestimmte Kernel-Version aus, testet sie und pflegt sie – oft länger, als der Upstream-Kernel selbst gepflegt wird.

### Übung 3

**Antwort 3.1:** `apt` → Debian-Familie (Debian, Ubuntu, Linux Mint, Raspberry Pi OS). `dnf`/`yum` → Red Hat-Familie (Fedora, RHEL, CentOS Stream, Rocky Linux, AlmaLinux). `zypper` → SUSE-Familie (openSUSE, SUSE Linux Enterprise). (`pacman` gehört zu Arch Linux.)

**Antwort 3.2:** Debian-Familie: Debian, Ubuntu, Linux Mint, Raspberry Pi OS. Red Hat-Familie: Fedora, Red Hat Enterprise Linux (RHEL), CentOS Stream, Rocky Linux, AlmaLinux. Je zwei genügen.

**Antwort 3.3:** Fedora und Rocky Linux – beide gehören zur Red Hat-Familie und nutzen `.rpm`-Pakete mit `dnf`. Ubuntu und Linux Mint gehören zur Debian-Familie (`.deb`, `apt`).

### Übung 4

**Antwort 4.1:** „Free“ meint Freiheit (*free as in freedom*), nicht Preis. Die vier Freiheiten: (0) das Programm für jeden Zweck ausführen, (1) untersuchen, wie es funktioniert, und es anpassen (setzt Zugang zum Quellcode voraus), (2) Kopien weitergeben, (3) veränderte Versionen weitergeben, damit die Gemeinschaft profitiert.

**Antwort 4.2:** Die GPL ist eine *copyleft*-Lizenz: Wer ein verändertes GPL-Programm weiterverbreitet, muss den Quellcode der Änderungen unter derselben Lizenz zugänglich machen. Die Freiheiten dürfen beim Weitergeben nicht entzogen werden.

**Antwort 4.3:** Das **GNU-Projekt** (GNU's Not Unix), mit dem Ziel eines komplett freien Unix-artigen Betriebssystems; dazu gründete er später die Free Software Foundation (FSF). Als Torvalds 1991 seinen Kernel veröffentlichte, existierten die GNU-Werkzeuge (Compiler, Shell, Core-Utilities) bereits – dem GNU-Projekt fehlte umgekehrt ein fertiger Kernel. Die Kombination beider ergab das erste vollständig freie System, weshalb man oft von „GNU/Linux“ spricht.

### Übung 5

**Antwort 5.1:** Ja, Android verwendet den Linux Kernel (in einer von Google angepassten Form). Trotzdem ist es keine typische Distribution: Das Userland ist komplett anders – keine GNU-Tools als Basis, eigene Laufzeitumgebung für Apps, Verteilung über App-Stores statt package manager. Kernel ja, klassisches „GNU/Linux“ nein.

**Antwort 5.2:** Vier von z. B.: Server und Rechenzentren, Cloud-Infrastruktur, Smartphones (Android), Netzwerkgeräte wie Router, Embedded-Geräte (Smart-TVs, Autos, IoT), Supercomputer, Einplatinencomputer wie der Raspberry Pi.

**Antwort 5.3:** Das stimmt nicht. Die offizielle Distribution heißt **Raspberry Pi OS** (früher Raspbian) und basiert auf Debian. Daneben laufen auch viele andere Distributionen auf dem Raspberry Pi.

### Übung 6

**Antwort 6.1 (Musterlösung):**
- **a)** Red Hat Enterprise Linux (RHEL) oder SUSE Linux Enterprise – kommerzieller Support, ~10 Jahre Support-Zeitraum.
- **b)** Ubuntu oder Linux Mint – einsteigerfreundlich, große Community, funktioniert weitgehend ohne Konfiguration.
- **c)** Fedora oder Arch Linux – sehr aktuelle Software (bei Arch als *rolling release*), dafür häufigere Änderungen.
- **d)** Debian – kostenlos, sehr stabil, community-getrieben, läuft auch auf älterer Hardware gut.

Andere Antworten sind richtig, wenn die Begründung zur Familie und zum Einsatzzweck passt.

**Antwort 6.2:** Beim Enterprise-Modell verkauft ein Unternehmen Subskriptionen mit garantiertem Support, Zertifizierungen und langen, planbaren Lebenszyklen; die Software selbst bleibt Open Source. Beim Community-Modell (Debian, Arch) entwickeln Freiwillige die Distribution, es gibt keinen Hersteller-Support-Vertrag, dafür keinerlei Kosten und offene Entscheidungsprozesse.

**Antwort 6.3:** **LTS** = *Long Term Support*. Solche Releases erhalten über einen langen Zeitraum (bei Ubuntu 5 Jahre Standard-Support) Sicherheits-Updates, ohne dass ein Versions-Upgrade nötig ist. Für Unternehmen bedeutet das planbare Wartung und weniger riskante Migrationen.

</details>

---

**Quellen:**
- LPI Learning Materials, Topic 1.1 – Linux Evolution and Popular Operating Systems: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- Linux Kernel Source, Lizenzdatei `COPYING`: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/COPYING
- DistroWatch (Übersicht über Distributionen): https://distrowatch.com/