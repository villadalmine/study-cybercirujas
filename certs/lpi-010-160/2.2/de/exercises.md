# LPI Linux Essentials (010-160, v1.6) – Thema 2.2: Using the Command Line to Get Help

*Quelle (nur als Referenz verwendet, kein Text übernommen): https://learning.lpi.org/en/learning-materials/010-160/2/2.2/*

---

## Übung 1: Die `--help`-Option

Viele Kommandos bringen eine eingebaute Kurzhilfe mit, die per Konvention über die Option `--help` (bei manchen älteren Tools auch `-h`) aufgerufen wird.

1. Öffne ein Terminal.
2. Rufe die Kurzhilfe von `ls` auf:
   ```
   ls --help
   ```
3. Beobachte den Aufbau der Ausgabe: eine Zeile mit der `usage`-Syntax, gefolgt von einer Liste der verfügbaren Optionen mit kurzer Beschreibung.
4. Leite die Ausgabe an `less` weiter, um sie seitenweise zu lesen, falls sie den Bildschirm überschreitet:
   ```
   ls --help | less
   ```
5. Beende `less` mit `q`.

<details>
<summary>Verständnisfragen zu Übung 1 (im Text beantworten, Lösungen unten)</summary>

- Frage 1.1: Welche Art von Information liefert `--help` typischerweise – eine vollständige Referenz oder eine kompakte Kurzübersicht?
- Frage 1.2: Warum ist es sinnvoll, `--help` mit `| less` zu kombinieren?
</details>

---

## Übung 2: `man`-Pages lesen und navigieren

Das `man`-System (manual pages) ist die zentrale Dokumentationsquelle für die meisten Kommandos, Konfigurationsdateien und System-Calls unter Linux.

1. Öffne die Manual-Page von `ls`:
   ```
   man ls
   ```
2. Der Pager (üblicherweise `less`) zeigt die Seite an. Beachte den Kopf der Seite: Dort steht der Name des Kommandos und die **Section-Nummer** in Klammern, z. B. `LS(1)`.
3. Navigiere innerhalb der Seite:
   - Eine Zeile weiter: `Enter` oder `↓`
   - Eine Seite weiter: `Leertaste` (`Space`) oder `f`
   - Eine Seite zurück: `b`
4. Suche innerhalb der Seite nach dem Begriff `sort`:
   ```
   /sort
   ```
   Drücke danach `n`, um zum nächsten Treffer zu springen, und `N`, um rückwärts zu springen.
5. Verlasse die Man-Page mit `q`.

<details>
<summary>Verständnisfragen zu Übung 2</summary>

- Frage 2.1: Mit welcher Taste startest du eine Vorwärtssuche innerhalb einer Man-Page, und mit welcher springst du zum nächsten Treffer?
- Frage 2.2: Welches Programm zeigt die Man-Page standardmäßig an (der sogenannte *pager*)?
</details>

---

## Übung 3: Man-Page-Sections verstehen

Manche Begriffe existieren in mehreren Sections gleichzeitig – zum Beispiel gibt es sowohl ein Kommando `passwd` als auch eine Konfigurationsdatei `passwd`. Die Section-Nummer legt fest, um welche Art von Dokumentation es sich handelt (1 = User Commands, 5 = File Formats, 8 = System Administration Commands, u. a.).

1. Rufe die Standard-Man-Page zu `passwd` auf:
   ```
   man passwd
   ```
   Prüfe im Kopf der Seite, welche Section angezeigt wird.
2. Fordere explizit die Section 5 (File Formats) an, um die Dokumentation der Datei `/etc/passwd` zu lesen:
   ```
   man 5 passwd
   ```
3. Vergleiche den Inhalt beider Aufrufe – die erste zeigt das Kommando zum Ändern von Passwörtern, die zweite das Dateiformat.
4. Liste alle verfügbaren Man-Pages zu `passwd` über alle Sections auf:
   ```
   man -f passwd
   ```
   (entspricht `whatis passwd`, siehe Übung 4)

<details>
<summary>Verständnisfragen zu Übung 3</summary>

- Frage 3.1: Warum kann `man passwd` ohne Section-Angabe zu einem anderen Ergebnis führen als `man 5 passwd`?
- Frage 3.2: Nenne zwei Section-Nummern des `man`-Systems und wofür sie stehen.
</details>

---

## Übung 4: Mit `whatis` und `apropos` suchen

`whatis` zeigt die einzeilige Kurzbeschreibung (aus dem `NAME`-Abschnitt) einer Man-Page. `apropos` durchsucht dagegen alle Kurzbeschreibungen nach einem Stichwort – nützlich, wenn du den genauen Kommandonamen nicht kennst.

1. Zeige die Kurzbeschreibung von `cp` an:
   ```
   whatis cp
   ```
2. Suche nach allen Kommandos, deren Kurzbeschreibung das Wort `copy` enthält:
   ```
   apropos copy
   ```
3. Führe denselben Suchvorgang mit der äquivalenten `man`-Option aus:
   ```
   man -k copy
   ```
4. Falls `apropos` eine leere oder unvollständige Ausgabe liefert, aktualisiere die `whatis`-Datenbank (Root-Rechte erforderlich):
   ```
   sudo mandb
   ```

<details>
<summary>Verständnisfragen zu Übung 4</summary>

- Frage 4.1: Worin unterscheidet sich `whatis` von `apropos` in Bezug auf die Art der Suche?
- Frage 4.2: Welches Kommando aktualisiert die Datenbank, auf der `whatis` und `apropos` basieren?
</details>

---

## Übung 5: Die `info`-Seiten nutzen

Für manche GNU-Tools (z. B. `tar`, `grep`, `coreutils`) existiert zusätzlich zur Man-Page ein ausführlicheres, hypertext-artiges `info`-Dokument mit verlinkten Kapiteln (*nodes*).

1. Öffne die Info-Seite von `ls`:
   ```
   info ls
   ```
2. Navigiere zwischen den Nodes:
   - Zum nächsten Node: `n`
   - Zum vorherigen Node: `p`
   - Eine Ebene nach oben: `u`
3. Springe zu einem verlinkten Menüpunkt, indem du den Cursor mit `↓`/`↑` darauf bewegst und `Enter` drückst.
4. Verlasse `info` mit `q`.

<details>
<summary>Verständnisfragen zu Übung 5</summary>

- Frage 5.1: Was ist der wesentliche strukturelle Unterschied zwischen einer `man`-Page und einem `info`-Dokument?
- Frage 5.2: Mit welcher Taste gelangst du innerhalb von `info` eine Hierarchieebene nach oben?
</details>

---

## Übung 6: Zusätzliche Dokumentation in `/usr/share/doc`

Viele installierte Pakete legen ergänzende Dokumentation (README-Dateien, Changelogs, Beispielkonfigurationen) unter `/usr/share/doc/<paketname>/` ab.

1. Liste den Inhalt des Verzeichnisses für ein installiertes Paket, z. B. `bash`:
   ```
   ls /usr/share/doc/bash/
   ```
   (Der genaue Verzeichnisname kann je nach Distribution leicht abweichen, z. B. Groß-/Kleinschreibung.)
2. Zeige eine eventuell vorhandene README-Datei an:
   ```
   less /usr/share/doc/bash/README
   ```
3. Suche systemweit nach allen Verzeichnissen unter `/usr/share/doc`, die eine `changelog`-Datei (unabhängig von Groß-/Kleinschreibung) enthalten:
   ```
   find /usr/share/doc -iname "changelog*" 2>/dev/null | head
   ```

<details>
<summary>Verständnisfragen zu Übung 6</summary>

- Frage 6.1: Welche Art von Information findest du eher in `/usr/share/doc` als in einer Man-Page?
- Frage 6.2: Warum wird im `find`-Befehl `2>/dev/null` angehängt?
</details>

---

<details>
<summary><strong>Lösungen zu allen Übungen (aufklappen)</strong></summary>

**Übung 1**
- 1.1: Eine kompakte Kurzübersicht der wichtigsten Optionen und der grundlegenden Syntax – keine vollständige, erklärende Dokumentation wie eine Man-Page.
- 1.2: Weil die `--help`-Ausgabe bei manchen Kommandos (z. B. `ls`, `find`) länger als eine Bildschirmseite ist; `less` erlaubt seitenweises Lesen und Suchen.

**Übung 2**
- 2.1: `/suchbegriff` startet die Suche vorwärts, `n` springt zum nächsten Treffer (`N` springt rückwärts zum vorherigen Treffer).
- 2.2: Standardmäßig `less` (der `PAGER`, den `man` verwendet, kann aber über die Umgebungsvariable `PAGER` angepasst werden).

**Übung 3**
- 3.1: `man` durchsucht die Sections in einer festgelegten Standardreihenfolge und zeigt die erste passende Seite. Da `passwd` sowohl in Section 1 (Kommando) als auch in Section 5 (Dateiformat) existiert, liefert der Aufruf ohne Section-Angabe standardmäßig die Section-1-Seite.
- 3.2: Beispiele: Section 1 = User Commands, Section 5 = File Formats, Section 8 = System Administration Commands (weitere: 2 = System Calls, 3 = Library Functions, 4 = Special Files, 6 = Games, 7 = Miscellaneous).

**Übung 4**
- 4.1: `whatis` sucht nur nach einer exakten Übereinstimmung des Kommandonamens und zeigt dessen Kurzbeschreibung. `apropos` durchsucht den Text der Kurzbeschreibungen selbst (Volltextsuche über die `NAME`-Zeilen), auch wenn der gesuchte Begriff nicht der Kommandoname ist.
- 4.2: `mandb` (meist mit `sudo` ausgeführt, da die Datenbank in einem systemweiten Verzeichnis liegt).

**Übung 5**
- 5.1: Eine Man-Page ist ein einzelnes, lineares Dokument. Ein Info-Dokument ist in mehrere verlinkte *nodes* (Kapitel/Unterkapitel) gegliedert, zwischen denen man wie in einem Hypertext-System navigieren kann.
- 5.2: Die Taste `u` (up).

**Übung 6**
- 6.1: Paketspezifische Zusatzinformationen wie Lizenztexte, Changelogs, Beispielkonfigurationen, ausführliche READMEs oder Hinweise zu bekannten Problemen – Inhalte, die über den Umfang einer klassischen Man-Page hinausgehen.
- 6.2: Um Fehlermeldungen wie „Permission denied" (bei Verzeichnissen ohne Leserecht) zu unterdrücken und nur die tatsächlichen Treffer in der Standardausgabe zu sehen.

</details>