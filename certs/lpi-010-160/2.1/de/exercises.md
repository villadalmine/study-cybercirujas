# Geführte Übungen: Command Line Basics

**Zertifizierung:** LPI Linux Essentials (010-160, Version 1.6) · **Thema 2.1** · **Gewichtung:** 3

Diese Übungen führen Sie Schritt für Schritt durch die Grundlagen der Shell: den Aufbau einer Command Line, Variables, Quoting und die Command History. Führen Sie jeden Schritt selbst in einem Terminal aus — nur so prägen sich die Konzepte ein.

> **Referenz:** LPI Learning Materials, Lesson 2.1 — https://learning.lpi.org/en/learning-materials/010-160/2/2.1/

---

## Übung 1: Die Shell kennenlernen

Die **Shell** ist das Programm, das Ihre Eingaben liest, interpretiert und ausführt. Unter Linux ist die **Bash** (Bourne Again Shell) die am weitesten verbreitete Shell.

1. Öffnen Sie ein Terminal. Sie sehen einen **Prompt**, der typischerweise so aussieht:
   ```
   user@hostname:~$
   ```
2. Finden Sie heraus, welche Shell Sie gerade verwenden:
   ```bash
   echo $SHELL
   ```
3. Prüfen Sie, was für eine Art von Command `echo` ist:
   ```bash
   type echo
   ```
4. Vergleichen Sie das mit einem externen Programm:
   ```bash
   type ls
   ```
5. Geben Sie einen Command ein, der nicht existiert, und beobachten Sie die Fehlermeldung:
   ```bash
   diesegibtsnicht
   ```

**Fragen zum Verständnis:**

- **1a)** Was bedeutet das Zeichen `~` im Prompt?
- **1b)** Was ist der Unterschied zwischen einem **shell builtin** wie `echo` und einem externen Command wie `ls`?
- **1c)** Woran erkennen Sie am Prompt üblicherweise, ob Sie als normaler User oder als `root` arbeiten?

---

## Übung 2: Aufbau einer Command Line

Eine Command Line besteht in der Regel aus drei Teilen: **command**, **options** und **arguments**.

1. Führen Sie den Command ohne Zusätze aus:
   ```bash
   ls
   ```
2. Fügen Sie eine **option** hinzu, die das Ausgabeformat ändert:
   ```bash
   ls -l
   ```
3. Fügen Sie ein **argument** hinzu, das angibt, *worauf* der Command wirken soll:
   ```bash
   ls -l /tmp
   ```
4. Kombinieren Sie mehrere kurze options zu einer Gruppe:
   ```bash
   ls -lh /tmp
   ```
5. Verwenden Sie eine **long option** (mit doppeltem Bindestrich):
   ```bash
   ls --all /tmp
   ```
6. Vergleichen Sie: `-a` und `--all` bewirken dasselbe:
   ```bash
   ls -a /tmp
   ```

**Fragen zum Verständnis:**

- **2a)** Benennen Sie in der Zeile `ls -lh /tmp` den command, die options und das argument.
- **2b)** Was ist der formale Unterschied zwischen einer short option und einer long option?
- **2c)** Ist `ls -lh` identisch mit `ls -l -h`?

---

## Übung 3: Variables

Die Shell kennt zwei Arten von Variables: **shell variables** (nur in der aktuellen Shell sichtbar) und **environment variables** (werden an gestartete Programme vererbt).

1. Erstellen Sie eine shell variable — wichtig: **kein Leerzeichen** um das `=`:
   ```bash
   greeting=hello
   ```
2. Lesen Sie den Wert mit `$` aus:
   ```bash
   echo $greeting
   ```
3. Starten Sie eine neue Shell innerhalb der aktuellen und prüfen Sie, ob die Variable dort existiert:
   ```bash
   bash
   echo $greeting
   ```
   Die Ausgabe ist leer. Verlassen Sie die Sub-Shell wieder:
   ```bash
   exit
   ```
4. Machen Sie die Variable mit `export` zu einer environment variable:
   ```bash
   export greeting
   bash
   echo $greeting
   exit
   ```
   Jetzt ist der Wert auch in der Sub-Shell sichtbar.
5. Sehen Sie sich einige vordefinierte environment variables an:
   ```bash
   echo $USER
   echo $HOME
   env | grep greeting
   ```
6. Löschen Sie die Variable:
   ```bash
   unset greeting
   echo $greeting
   ```

**Fragen zum Verständnis:**

- **3a)** Warum schlägt `greeting = hello` (mit Leerzeichen) fehl?
- **3b)** Was genau ändert `export` am Verhalten einer Variable?
- **3c)** Mit welchem Command listen Sie alle environment variables auf?

---

## Übung 4: Die Variable PATH

Die environment variable **PATH** enthält die Liste der Verzeichnisse, in denen die Shell nach ausführbaren Programmen sucht.

1. Zeigen Sie den Inhalt von PATH an:
   ```bash
   echo $PATH
   ```
2. Finden Sie heraus, aus welchem Verzeichnis `ls` ausgeführt wird:
   ```bash
   which ls
   ```
3. Erstellen Sie ein kleines Script in Ihrem Home Directory:
   ```bash
   cd
   echo 'echo Hallo von meinem Script' > meinscript.sh
   chmod +x meinscript.sh
   ```
4. Versuchen Sie, es nur mit dem Namen zu starten:
   ```bash
   meinscript.sh
   ```
   Die Shell meldet „command not found", obwohl die Datei existiert.
5. Starten Sie es mit explizitem Pfad:
   ```bash
   ./meinscript.sh
   ```

**Fragen zum Verständnis:**

- **4a)** Warum findet die Shell `meinscript.sh` in Schritt 4 nicht?
- **4b)** Was bedeutet das `./` vor dem Dateinamen?
- **4c)** Durch welches Zeichen werden die Verzeichnisse in PATH voneinander getrennt?

---

## Übung 5: Quoting

**Quoting** steuert, ob die Shell Sonderzeichen wie `$`, `*` oder Leerzeichen interpretiert oder wörtlich übernimmt.

1. Beobachten Sie die Ausgabe ohne Quotes:
   ```bash
   echo Mein User ist $USER
   ```
2. Verwenden Sie **double quotes** — Variables werden weiterhin ersetzt:
   ```bash
   echo "Mein User ist $USER"
   ```
3. Verwenden Sie **single quotes** — alles wird wörtlich übernommen:
   ```bash
   echo 'Mein User ist $USER'
   ```
4. Schützen Sie ein einzelnes Zeichen mit einem **backslash** (escape character):
   ```bash
   echo "Der Wert von \$USER ist $USER"
   ```
5. Sehen Sie, warum Quoting bei Dateinamen mit Leerzeichen wichtig ist:
   ```bash
   touch "meine notizen.txt"
   ls -l "meine notizen.txt"
   rm "meine notizen.txt"
   ```

**Fragen zum Verständnis:**

- **5a)** Was ist der zentrale Unterschied zwischen double quotes und single quotes?
- **5b)** Was würde `touch meine notizen.txt` (ohne Quotes) erzeugen?
- **5c)** Welche Ausgabe liefert `echo '$HOME'`?

---

## Übung 6: Command History

Die Shell speichert ausgeführte Commands in der **history**, damit Sie sie wiederverwenden können.

1. Zeigen Sie die zuletzt ausgeführten Commands an:
   ```bash
   history
   ```
2. Drücken Sie mehrmals die **Pfeiltaste nach oben** (↑), um durch frühere Commands zu blättern, und **Enter**, um einen davon erneut auszuführen.
3. Wiederholen Sie den letzten Command mit:
   ```bash
   !!
   ```
4. Führen Sie einen bestimmten Command aus der history erneut aus — ersetzen Sie `42` durch eine Nummer aus Ihrer eigenen `history`-Ausgabe:
   ```bash
   !42
   ```
5. Drücken Sie **Ctrl+R** und tippen Sie einen Suchbegriff (z. B. `echo`), um rückwärts in der history zu suchen. Mit **Enter** führen Sie den Treffer aus, mit **Ctrl+C** brechen Sie ab.
6. Sehen Sie sich an, wo die history dauerhaft gespeichert wird:
   ```bash
   echo $HISTFILE
   ```

**Fragen zum Verständnis:**

- **6a)** Was bewirkt `!!` und wann ist es besonders praktisch?
- **6b)** In welcher Datei speichert die Bash die history standardmäßig?
- **6c)** Was macht die Tastenkombination Ctrl+R?

---

<details>
<summary><strong>Antworten</strong></summary>

**1a)** Das `~` steht für das **Home Directory** des angemeldeten Users, z. B. `/home/user`. Es zeigt an, dass dies das aktuelle Arbeitsverzeichnis ist.

**1b)** Ein **shell builtin** ist direkt in die Shell eingebaut und benötigt kein separates Programm auf der Festplatte. Ein externer Command wie `ls` ist eine eigene ausführbare Datei (z. B. `/usr/bin/ls`), die die Shell über PATH findet und als neuen Prozess startet.

**1c)** Am letzten Zeichen des Prompts: `$` kennzeichnet üblicherweise einen normalen User, `#` den User `root`.

**2a)** `ls` ist der **command**, `-lh` sind zwei kombinierte **options** (`-l` und `-h`), `/tmp` ist das **argument**.

**2b)** Short options bestehen aus einem Bindestrich und einem einzelnen Zeichen (`-a`) und lassen sich gruppieren. Long options beginnen mit zwei Bindestrichen und einem Wort (`--all`) und können nicht gruppiert werden.

**2c)** Ja. Mehrere short options dürfen hinter einem einzelnen Bindestrich zusammengefasst werden; `ls -lh` und `ls -l -h` verhalten sich identisch.

**3a)** Mit Leerzeichen interpretiert die Shell `greeting` als Command und `=` sowie `hello` als dessen arguments. Da es keinen Command namens `greeting` gibt, erscheint „command not found". Eine Zuweisung muss ohne Leerzeichen geschrieben werden: `greeting=hello`.

**3b)** `export` markiert die Variable als **environment variable**. Dadurch wird sie an alle Prozesse (und Sub-Shells) vererbt, die aus dieser Shell heraus gestartet werden. Ohne `export` bleibt sie eine shell variable, die nur in der aktuellen Shell existiert.

**3c)** Mit `env` (oder `printenv`). Beide zeigen alle environment variables der aktuellen Sitzung an.

**4a)** Die Shell sucht Commands nur in den Verzeichnissen, die in der Variable **PATH** aufgelistet sind. Das Home Directory (und das aktuelle Verzeichnis `.`) gehören aus Sicherheitsgründen nicht dazu — deshalb wird das Script nicht gefunden.

**4b)** `./` gibt den Pfad explizit an: `.` steht für das aktuelle Verzeichnis. Damit umgeht man die PATH-Suche und sagt der Shell genau, wo die Datei liegt.

**4c)** Durch den Doppelpunkt `:`, z. B. `/usr/local/bin:/usr/bin:/bin`.

**5a)** Innerhalb von **double quotes** (`"..."`) führt die Shell weiterhin die Ersetzung von Variables (`$USER`) und command substitution aus; Leerzeichen und die meisten Sonderzeichen verlieren aber ihre Spezialbedeutung. Innerhalb von **single quotes** (`'...'`) wird *alles* wörtlich übernommen — auch `$` bleibt ein normales Zeichen.

**5b)** Es entstünden **zwei** Dateien: eine namens `meine` und eine namens `notizen.txt`, weil die Shell das Leerzeichen als Trennzeichen zwischen arguments interpretiert.

**5c)** Die wörtliche Zeichenkette `$HOME` — die Variable wird wegen der single quotes nicht ersetzt.

**6a)** `!!` führt den zuletzt eingegebenen Command erneut aus. Besonders praktisch ist es, wenn ein Command Root-Rechte benötigt hätte: `sudo !!` wiederholt ihn sofort mit `sudo`.

**6b)** In der Datei `~/.bash_history` im Home Directory des Users (der Pfad steht in der Variable `HISTFILE`). Geschrieben wird sie in der Regel beim Beenden der Shell.

**6c)** Ctrl+R startet die **reverse incremental search**: Die Shell durchsucht die history rückwärts nach dem eingegebenen Text und zeigt den letzten passenden Command an, den man direkt ausführen oder weiter bearbeiten kann.

</details>