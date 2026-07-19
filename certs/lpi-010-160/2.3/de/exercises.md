# Geführte Übungen — Thema 2.3: Using Directories and Listing Files

**Zertifizierung:** LPI Linux Essentials (010-160, Version 1.6) · **Gewichtung:** 2

Für diese Übungen brauchst du nur ein Terminal. Alle Befehle sind gefahrlos — es wird nichts gelöscht oder überschrieben.

---

## Übung 1: Wo bin ich? — `pwd`, Home Directory und `~`

Wenn du ein Terminal öffnest, landest du in deinem **Home Directory**. Jeder Benutzer hat ein eigenes; dort darf er Dateien anlegen und ändern.

1. Öffne ein Terminal und zeige dein aktuelles Verzeichnis an:
   ```bash
   pwd
   ```
2. Notiere die Ausgabe — sie sollte etwa `/home/deinname` lauten (für `root` wäre es `/root`).
3. Wechsle in das Wurzelverzeichnis des Systems und prüfe erneut deine Position:
   ```bash
   cd /
   pwd
   ```
4. Kehre mit einem einzigen kurzen Befehl in dein Home Directory zurück und bestätige es:
   ```bash
   cd
   pwd
   ```
5. Wechsle noch einmal nach `/tmp` und kehre diesmal mit der Tilde zurück:
   ```bash
   cd /tmp
   cd ~
   pwd
   ```

**Fragen zum Verständnis:**

- **1a.** Wofür steht die Abkürzung `pwd`, und was genau zeigt der Befehl an?
- **1b.** Welche zwei Schreibweisen hast du benutzt, um ins Home Directory zurückzukehren? Gibt es einen Unterschied im Ergebnis?
- **1c.** Was würde `cd ~/Dokumente` bedeuten, ausgeschrieben als absoluter Pfad?

---

## Übung 2: Eine Übungsstruktur anlegen

Wir bauen einen kleinen Verzeichnisbaum, mit dem alle folgenden Übungen arbeiten.

1. Stelle sicher, dass du im Home Directory bist:
   ```bash
   cd
   ```
2. Lege die Struktur in einem Schritt an (die Option `-p` erzeugt auch die Zwischenverzeichnisse):
   ```bash
   mkdir -p uebung/projekte/alpha uebung/projekte/beta uebung/notizen
   ```
3. Erzeuge ein paar leere Dateien darin:
   ```bash
   touch uebung/projekte/alpha/plan.txt
   touch uebung/projekte/beta/bericht.txt
   touch uebung/notizen/ideen.txt
   ```
4. Verschaffe dir einen Überblick:
   ```bash
   ls uebung
   ```

Die Struktur sieht jetzt so aus:

```
uebung/
├── notizen/
│   └── ideen.txt
└── projekte/
    ├── alpha/
    │   └── plan.txt
    └── beta/
        └── bericht.txt
```

**Frage zum Verständnis:**

- **2a.** In der Ausgabe von `ls uebung` erscheinen `notizen` und `projekte`, aber nicht `plan.txt`. Warum nicht?

---

## Übung 3: Absolute und relative Pfade

Ein **absolute path** beginnt immer mit `/` und beschreibt den Weg vom Wurzelverzeichnis aus. Ein **relative path** beginnt beim aktuellen Verzeichnis.

1. Wechsle mit einem relativen Pfad in das Verzeichnis `alpha`:
   ```bash
   cd
   cd uebung/projekte/alpha
   pwd
   ```
2. Wechsle jetzt mit einem **absoluten** Pfad in das Verzeichnis `notizen` (ersetze `deinname` durch deinen Benutzernamen — die Ausgabe von `pwd` aus Schritt 1 hilft dir):
   ```bash
   cd /home/deinname/uebung/notizen
   pwd
   ```
3. Von `notizen` aus: wechsle mit einem relativen Pfad nach `beta`. Dafür musst du zuerst eine Ebene nach oben (`..`) und dann wieder hinab:
   ```bash
   cd ../projekte/beta
   pwd
   ```
4. Probiere die zwei Spezialeinträge aus, die es in jedem Verzeichnis gibt:
   ```bash
   cd .
   pwd
   cd ..
   pwd
   ```
5. Springe zwei Ebenen auf einmal nach oben und prüfe, wo du gelandet bist:
   ```bash
   cd beta
   cd ../..
   pwd
   ```

**Fragen zum Verständnis:**

- **3a.** Woran erkennst du auf einen Blick, ob ein Pfad absolut oder relativ ist?
- **3b.** Was bedeuten `.` und `..`?
- **3c.** Du stehst in `~/uebung/projekte/alpha`. Nenne einen relativen **und** einen absoluten Pfad, um `~/uebung/notizen/ideen.txt` zu erreichen.
- **3d.** Warum hat `cd .` in Schritt 4 nichts verändert?

---

## Übung 4: Dateien auflisten mit `ls` und seinen Optionen

`ls` ist das wichtigste Werkzeug, um den Inhalt von Verzeichnissen zu untersuchen. Seine Optionen lassen sich kombinieren.

1. Wechsle in das Übungsverzeichnis:
   ```bash
   cd ~/uebung
   ```
2. Einfache Auflistung:
   ```bash
   ls
   ```
3. Das **long listing** zeigt Details wie Rechte, Besitzer, Größe und Änderungsdatum:
   ```bash
   ls -l
   ```
4. Schau dir eine große Datei mit und ohne *human-readable* Größen an:
   ```bash
   ls -l /var/log
   ls -lh /var/log
   ```
   Vergleiche die Spalte mit der Dateigröße in beiden Ausgaben.
5. Liste ein Verzeichnis auf, ohne hineinzuwechseln — `ls` akzeptiert Pfade als Argument:
   ```bash
   ls -l projekte/alpha
   ls -l /etc
   ```
6. Was passiert, wenn das Argument ein Verzeichnis ist, du aber Informationen über das Verzeichnis **selbst** willst (nicht über seinen Inhalt)? Vergleiche:
   ```bash
   ls -l projekte
   ls -ld projekte
   ```

**Fragen zum Verständnis:**

- **4a.** Welche Information steht in der ersten Spalte von `ls -l`, und was bedeutet ein `d` als erstes Zeichen?
- **4b.** Was bewirkt die Option `-h`, und warum ist sie nur in Kombination mit `-l` sinnvoll?
- **4c.** Worin unterscheiden sich `ls -l projekte` und `ls -ld projekte`?

---

## Übung 5: Versteckte Dateien

Dateien und Verzeichnisse, deren Name mit einem Punkt beginnt, sind **hidden files** — `ls` zeigt sie standardmäßig nicht an. Sie enthalten meist Konfiguration.

1. Lege im Übungsverzeichnis eine versteckte Datei an:
   ```bash
   cd ~/uebung
   touch .geheim.txt
   ```
2. Liste das Verzeichnis normal auf — die Datei fehlt:
   ```bash
   ls
   ```
3. Zeige jetzt **alle** Einträge an:
   ```bash
   ls -a
   ```
4. Kombiniere das mit dem long listing und sieh dir auch dein Home Directory an:
   ```bash
   ls -la
   ls -la ~
   ```
   In deinem Home Directory findest du typische Beispiele wie `.bashrc` oder `.profile`.

**Fragen zum Verständnis:**

- **5a.** Was macht einen Dateinamen unter Linux zu einem "versteckten" Namen?
- **5b.** In der Ausgabe von `ls -a` erscheinen immer die Einträge `.` und `..`, obwohl du sie nie angelegt hast. Was sind sie?
- **5c.** Sind versteckte Dateien ein Sicherheitsmechanismus? Begründe kurz.

---

## Übung 6: Rekursive Auflistung

Mit `-R` (**recursive listing**) zeigt `ls` nicht nur das angegebene Verzeichnis, sondern auch alle Unterverzeichnisse.

1. Liste den gesamten Übungsbaum auf einmal auf:
   ```bash
   cd
   ls -R uebung
   ```
2. Beobachte die Ausgabe: jedes Unterverzeichnis wird mit seinem Pfad und einem Doppelpunkt eingeleitet, danach folgt sein Inhalt.
3. Kombiniere die Rekursion mit dem long listing:
   ```bash
   ls -lR uebung
   ```
4. Prüfe, ob die versteckte Datei aus Übung 5 in der rekursiven Ausgabe auftaucht:
   ```bash
   ls -R uebung | grep geheim
   ls -Ra uebung | grep geheim
   ```

**Fragen zum Verständnis:**

- **6a.** Erscheint `.geheim.txt` in der Ausgabe von `ls -R`? Warum bzw. warum nicht?
- **6b.** Warum sollte man `ls -R /` nur mit Vorsicht ausführen?
- **6c.** Bei `ls` ist die Option für Rekursion das große `-R`. Ist die Groß-/Kleinschreibung von Optionen unter Linux generell egal?

---

## Aufräumen (optional)

```bash
rm -r ~/uebung
```

---

## Antworten

<details>
<summary><strong>Antworten anzeigen</strong></summary>

**1a.** `pwd` steht für *print working directory*. Der Befehl gibt den absoluten Pfad des Verzeichnisses aus, in dem du dich gerade befindest (das *current working directory*).

**1b.** `cd` ohne Argument und `cd ~`. Das Ergebnis ist identisch: beide wechseln ins Home Directory des aktuellen Benutzers. Die Tilde ist vor allem nützlich, um Pfade **unterhalb** des Home Directory abzukürzen (z. B. `~/uebung`).

**1c.** Die Shell ersetzt `~` durch den Pfad des Home Directory. `cd ~/Dokumente` entspricht also `cd /home/deinname/Dokumente`.

**2a.** `ls uebung` zeigt nur den direkten Inhalt von `uebung` — also die Verzeichnisse `notizen` und `projekte`. `plan.txt` liegt eine Ebene tiefer (in `uebung/projekte/alpha`) und erscheint erst bei einer rekursiven Auflistung (`ls -R`) oder wenn man das Unterverzeichnis direkt auflistet.

**3a.** Ein absoluter Pfad beginnt mit `/` (dem *root directory*). Alles andere ist ein relativer Pfad und wird vom aktuellen Verzeichnis aus interpretiert.

**3b.** `.` ist das aktuelle Verzeichnis selbst; `..` ist das übergeordnete Verzeichnis (*parent directory*). Beide existieren als Einträge in jedem Verzeichnis.

**3c.** Relativ: `../../notizen/ideen.txt` (zwei Ebenen hoch von `alpha` nach `uebung`, dann hinab). Absolut: `/home/deinname/uebung/notizen/ideen.txt`. Auch `~/uebung/notizen/ideen.txt` ist gültig — die Shell expandiert es zu einem absoluten Pfad.

**3d.** `cd .` wechselt in das aktuelle Verzeichnis — also dorthin, wo du schon bist. Die Position ändert sich nicht.

**4a.** Die erste Spalte zeigt Dateityp und Zugriffsrechte (*permissions*), z. B. `drwxr-xr-x`. Das erste Zeichen ist der Typ: `d` bedeutet *directory*, `-` eine reguläre Datei.

**4b.** `-h` (*human-readable*) zeigt Dateigrößen in lesbaren Einheiten wie `4,0K`, `1,2M` oder `2,5G` statt in Bytes. Ohne `-l` wird die Größe gar nicht angezeigt, daher hat `-h` allein keine sichtbare Wirkung.

**4c.** `ls -l projekte` listet den **Inhalt** des Verzeichnisses auf (`alpha`, `beta`). `ls -ld projekte` zeigt dank `-d` den Eintrag des Verzeichnisses **selbst** — nützlich, um z. B. die Rechte des Verzeichnisses zu prüfen.

**5a.** Der Name beginnt mit einem Punkt, z. B. `.geheim.txt` oder `.bashrc`. Mehr braucht es nicht — es gibt kein spezielles "hidden"-Attribut.

**5b.** `.` (das Verzeichnis selbst) und `..` (das übergeordnete Verzeichnis). Sie sind in jedem Verzeichnis automatisch vorhanden; weil ihre Namen mit einem Punkt beginnen, erscheinen sie nur mit `ls -a`.

**5c.** Nein. Verstecken bedeutet nur, dass `ls` und Dateimanager die Einträge standardmäßig nicht anzeigen — jeder Benutzer kann sie mit `ls -a` sofort sehen. Es dient der Übersichtlichkeit (Konfigurationsdateien stören nicht im Alltag), nicht dem Schutz. Zugriffsschutz regeln ausschließlich die *permissions*.

**6a.** Nein, mit `ls -R` allein nicht. Die Rekursion ändert nichts daran, dass versteckte Dateien standardmäßig ausgeblendet werden. Erst die Kombination `ls -Ra` zeigt sie.

**6b.** `ls -R /` durchläuft das gesamte Dateisystem ab dem Wurzelverzeichnis. Das erzeugt eine riesige Ausgabe, dauert lange und produziert viele Fehlermeldungen für Verzeichnisse, die ein normaler Benutzer nicht lesen darf.

**6c.** Nein — Linux unterscheidet strikt zwischen Groß- und Kleinschreibung, auch bei Optionen. Bei `ls` bedeutet `-R` *recursive*, während `-r` die Sortierreihenfolge umkehrt (*reverse*). Zwei völlig verschiedene Dinge.

</details>

---

## Quellen

- LPI Learning Materials, Thema 2.3 "Using Directories and Listing Files": https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- Manpages: `man ls`, `man pwd`, `man cd` (bzw. `help cd`, da `cd` ein Shell-Builtin ist)