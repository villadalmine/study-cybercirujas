# Geführte Übungen – Thema 3.3: Turning Commands into a Script

> Alle Übungen können in einem normalen Terminal mit der **Bash-Shell** durchgeführt werden. Es werden keine Root-Rechte benötigt. Arbeite am besten in einem eigenen Übungsverzeichnis.

## Vorbereitung

1. Öffne ein Terminal und erstelle ein Übungsverzeichnis:
   ```bash
   mkdir ~/scripting-uebung
   cd ~/scripting-uebung
   ```
2. Prüfe, welche Shell du verwendest:
   ```bash
   echo $SHELL
   ```

---

## Übung 1: Das erste Script erstellen und ausführen

1. Erstelle mit einem Texteditor (z. B. `nano`) eine neue Datei:
   ```bash
   nano hallo.sh
   ```
2. Schreibe folgenden Inhalt in die Datei und speichere sie (`Ctrl+O`, `Enter`, `Ctrl+X`):
   ```bash
   #!/bin/bash
   # Mein erstes Script
   echo "Hallo, Welt!"
   ```
3. Versuche, das Script direkt auszuführen:
   ```bash
   ./hallo.sh
   ```
   Du erhältst die Fehlermeldung `Permission denied`.
4. Sieh dir die Permissions der Datei an:
   ```bash
   ls -l hallo.sh
   ```
5. Mache die Datei mit `chmod` ausführbar und prüfe die Permissions erneut:
   ```bash
   chmod +x hallo.sh
   ls -l hallo.sh
   ```
6. Führe das Script jetzt aus:
   ```bash
   ./hallo.sh
   ```
7. Führe das Script zusätzlich auf diese Weise aus – auch ohne Execute-Permission würde das funktionieren:
   ```bash
   bash hallo.sh
   ```

**Fragen zum Verständnis**

- **1.1** Wofür steht die erste Zeile `#!/bin/bash` und wie heißt sie?
- **1.2** Warum schlägt `./hallo.sh` in Schritt 3 fehl, obwohl die Datei existiert?
- **1.3** Warum muss man `./hallo.sh` schreiben und nicht einfach `hallo.sh`?
- **1.4** Warum funktioniert `bash hallo.sh` auch ohne Execute-Permission?

---

## Übung 2: Kommentare und Ausgabe mit `echo`

1. Erstelle ein neues Script `info.sh` mit folgendem Inhalt:
   ```bash
   #!/bin/bash
   # Dieses Script zeigt Systeminformationen an.
   echo "Benutzer:"
   whoami          # gibt den aktuellen Benutzernamen aus
   echo            # leere Zeile
   echo "Aktuelles Verzeichnis:"
   pwd
   ```
2. Mache es ausführbar und starte es:
   ```bash
   chmod +x info.sh
   ./info.sh
   ```
3. Ändere die Zeile mit `whoami` so, dass sie mit `#` beginnt, und führe das Script erneut aus. Beobachte den Unterschied.

**Fragen zum Verständnis**

- **2.1** Welche Wirkung hat das Zeichen `#` innerhalb eines Scripts (außerhalb der ersten Zeile)?
- **2.2** Was gibt der Befehl `echo` ohne Argumente aus?
- **2.3** Warum sind Kommentare in Scripts sinnvoll, obwohl die Shell sie ignoriert?

---

## Übung 3: Variablen verwenden

1. Erstelle ein Script `variablen.sh`:
   ```bash
   #!/bin/bash
   NAME="Tux"
   DISTRO="Linux"
   echo "Hallo $NAME, willkommen bei $DISTRO!"
   ```
2. Mache es ausführbar und führe es aus.
3. Ergänze am Ende des Scripts eine Zeile, die den Wert eines Befehls in einer Variable speichert (**command substitution**):
   ```bash
   HEUTE=$(date)
   echo "Heute ist: $HEUTE"
   ```
4. Führe das Script erneut aus.
5. Probiere im Script absichtlich einen Fehler aus: Schreibe `NAME = "Tux"` (mit Leerzeichen um das `=`) und führe das Script aus. Notiere die Fehlermeldung und mach die Änderung danach rückgängig.

**Fragen zum Verständnis**

- **3.1** Wie greift man auf den Wert einer Variable zu?
- **3.2** Warum verursacht `NAME = "Tux"` einen Fehler?
- **3.3** Was bewirkt die Syntax `$(befehl)`?

---

## Übung 4: Argumente an ein Script übergeben

1. Erstelle ein Script `gruss.sh`:
   ```bash
   #!/bin/bash
   echo "Scriptname:        $0"
   echo "Erstes Argument:   $1"
   echo "Zweites Argument:  $2"
   echo "Anzahl Argumente:  $#"
   echo "Alle Argumente:    $@"
   ```
2. Mache es ausführbar und rufe es mit unterschiedlichen Argumenten auf:
   ```bash
   ./gruss.sh Anna
   ./gruss.sh Anna Bernd
   ./gruss.sh Anna Bernd Carla
   ```
3. Rufe das Script einmal ganz ohne Argumente auf und beobachte die Ausgabe.

**Fragen zum Verständnis**

- **4.1** Welche Bedeutung haben `$0`, `$1` und `$2`?
- **4.2** Was ist der Unterschied zwischen `$#` und `$@`?
- **4.3** Was enthält `$1`, wenn das Script ohne Argumente aufgerufen wird?

---

## Übung 5: Exit Status auswerten

1. Führe einen Befehl aus, der erfolgreich ist, und prüfe direkt danach den **exit status**:
   ```bash
   ls /etc
   echo $?
   ```
2. Führe nun einen Befehl aus, der fehlschlägt, und prüfe wieder den exit status:
   ```bash
   ls /gibt-es-nicht
   echo $?
   ```
3. Erstelle ein Script `check.sh`:
   ```bash
   #!/bin/bash
   ls /etc/hostname
   echo "Exit status von ls: $?"
   exit 3
   ```
4. Mache es ausführbar, führe es aus und prüfe anschließend den exit status des Scripts selbst:
   ```bash
   ./check.sh
   echo $?
   ```

**Fragen zum Verständnis**

- **5.1** Welcher exit status signalisiert Erfolg, welche Werte signalisieren einen Fehler?
- **5.2** In welcher speziellen Variable steht der exit status des zuletzt ausgeführten Befehls?
- **5.3** Was bewirkt der Befehl `exit 3` im Script?
- **5.4** Warum zeigt `echo $?` in Schritt 4 den Wert `3` und nicht `0`?

---

## Übung 6: Entscheidungen mit `if` und `test`

1. Erstelle ein Script `pruefe-datei.sh`:
   ```bash
   #!/bin/bash
   if [ -f "$1" ]
   then
       echo "$1 ist eine reguläre Datei."
   else
       echo "$1 ist keine reguläre Datei."
   fi
   ```
2. Mache es ausführbar und teste es mit einer existierenden Datei und mit einem Verzeichnis:
   ```bash
   ./pruefe-datei.sh /etc/hostname
   ./pruefe-datei.sh /etc
   ```
3. Erweitere das Script um einen Zahlenvergleich. Erstelle dazu `vergleich.sh`:
   ```bash
   #!/bin/bash
   if [ "$#" -eq 0 ]
   then
       echo "Bitte mindestens ein Argument angeben."
       exit 1
   fi
   echo "Du hast $# Argument(e) übergeben."
   ```
4. Führe `vergleich.sh` einmal ohne und einmal mit Argumenten aus und prüfe jeweils den exit status mit `echo $?`.

**Fragen zum Verständnis**

- **6.1** Was prüft der Test `-f` in eckigen Klammern? 
- **6.2** Mit welchem Schlüsselwort wird ein `if`-Block abgeschlossen?
- **6.3** Was bedeutet der Operator `-eq` und worin unterscheidet er sich von `=`?
- **6.4** Warum ist es sinnvoll, im Fehlerfall `exit 1` statt gar nichts zu verwenden?

---

## Übung 7: Wiederholungen mit der `for`-Schleife

1. Erstelle ein Script `schleife.sh`:
   ```bash
   #!/bin/bash
   for OBST in Apfel Banane Kirsche
   do
       echo "Ich mag: $OBST"
   done
   ```
2. Mache es ausführbar und führe es aus.
3. Erstelle ein zweites Script `dateien.sh`, das über alle Argumente iteriert:
   ```bash
   #!/bin/bash
   for DATEI in "$@"
   do
       echo "Verarbeite: $DATEI"
   done
   ```
4. Führe es mit mehreren Argumenten aus:
   ```bash
   ./dateien.sh eins.txt zwei.txt drei.txt
   ```
5. Erstelle ein paar Testdateien und benutze eine Schleife mit einem **wildcard**-Muster direkt auf der Kommandozeile:
   ```bash
   touch a.txt b.txt c.txt
   for F in *.txt; do echo "Gefunden: $F"; done
   ```

**Fragen zum Verständnis**

- **7.1** Welche Schlüsselwörter markieren Anfang und Ende des Schleifenkörpers bei `for`?
- **7.2** Wie oft wird der Schleifenkörper in `schleife.sh` ausgeführt und warum?
- **7.3** Was bewirkt `"$@"` in `dateien.sh`?

---

## Übung 8: Ein Script ohne `./` aufrufen (PATH)

1. Zeige den Inhalt der Variable `PATH` an:
   ```bash
   echo $PATH
   ```
2. Erstelle ein Verzeichnis `bin` in deinem Home-Verzeichnis und kopiere ein Script hinein:
   ```bash
   mkdir -p ~/bin
   cp hallo.sh ~/bin/hallo
   ```
3. Füge das Verzeichnis für die aktuelle Sitzung zum `PATH` hinzu:
   ```bash
   PATH="$PATH:$HOME/bin"
   ```
4. Rufe das Script jetzt von einem beliebigen Verzeichnis aus nur mit seinem Namen auf:
   ```bash
   cd /tmp
   hallo
   ```

**Fragen zum Verständnis**

- **8.1** Welche Aufgabe hat die Variable `PATH`?
- **8.2** Warum konnte `hallo.sh` in Übung 1 nicht einfach mit `hallo.sh` aufgerufen werden, `hallo` hier aber schon?
- **8.3** Ist die Änderung an `PATH` in Schritt 3 dauerhaft? Begründe.

---

## Antworten

<details>
<summary>Antworten anzeigen</summary>

### Übung 1

- **1.1** Die Zeile heißt **shebang** (auch *hashbang*). Sie teilt dem System mit, welcher **interpreter** das Script ausführen soll – hier `/bin/bash`. Sie muss die allererste Zeile der Datei sein.
- **1.2** Der Datei fehlt die **execute permission** (`x`). Neu erstellte Dateien sind standardmäßig nicht ausführbar; erst `chmod +x` macht sie zu einem ausführbaren Programm.
- **1.3** Das aktuelle Verzeichnis (`.`) ist aus Sicherheitsgründen normalerweise nicht in der Variable `PATH` enthalten. Mit `./hallo.sh` gibt man den Pfad zur Datei explizit an.
- **1.4** Bei `bash hallo.sh` wird das Programm `bash` ausgeführt, und die Datei ist nur dessen Eingabe. Es reicht daher die **read permission**; die execute permission der Script-Datei spielt keine Rolle. Auch der shebang wird in diesem Fall nicht benötigt.

### Übung 2

- **2.1** Alles von `#` bis zum Zeilenende ist ein **comment** und wird von der Shell ignoriert. (Ausnahme: `#!` in der ersten Zeile, der shebang.)
- **2.2** `echo` ohne Argumente gibt eine leere Zeile aus (nur einen Zeilenumbruch).
- **2.3** Kommentare dokumentieren, was das Script tut und warum. Das hilft anderen Personen – und einem selbst nach längerer Zeit – den Code zu verstehen und zu warten.

### Übung 3

- **3.1** Mit einem `$` vor dem Variablennamen, z. B. `$NAME` (oder `${NAME}`). Ohne `$` würde nur der Name als Text ausgegeben.
- **3.2** Bei einer Zuweisung dürfen **keine Leerzeichen** um das `=` stehen. Die Shell interpretiert `NAME = "Tux"` als Befehl `NAME` mit den Argumenten `=` und `"Tux"` und meldet `command not found`.
- **3.3** `$(befehl)` ist **command substitution**: Der Befehl wird ausgeführt und seine Ausgabe an dieser Stelle eingesetzt – hier wird die Ausgabe von `date` in der Variable `HEUTE` gespeichert.

### Übung 4

- **4.1** `$0` enthält den Namen (bzw. Aufrufpfad) des Scripts selbst, `$1` das erste und `$2` das zweite übergebene Argument. Diese Variablen heißen **positional parameters**.
- **4.2** `$#` enthält die **Anzahl** der übergebenen Argumente (eine Zahl), `$@` enthält **alle Argumente selbst** als Liste.
- **4.3** Nichts – `$1` ist dann leer (ein leerer String), und `$#` hat den Wert `0`.

### Übung 5

- **5.1** `0` bedeutet Erfolg; jeder Wert ungleich `0` (1–255) signalisiert einen Fehler.
- **5.2** In der speziellen Variable `$?`.
- **5.3** `exit 3` beendet das Script sofort und setzt dessen exit status auf `3`.
- **5.4** `echo $?` zeigt den exit status des **zuletzt ausgeführten Befehls** – das ist hier das gesamte Script `./check.sh`, das sich mit `exit 3` beendet hat. Deshalb erscheint `3`.

### Übung 6

- **6.1** `[ -f "$1" ]` prüft, ob das erste Argument eine existierende **reguläre Datei** ist (kein Verzeichnis, kein Device usw.). Die eckigen Klammern sind eine Schreibweise für den Befehl `test`.
- **6.2** Mit `fi` (also `if` rückwärts geschrieben).
- **6.3** `-eq` (*equal*) vergleicht zwei **ganze Zahlen** auf Gleichheit. `=` vergleicht dagegen **Strings**. Für Zahlenvergleiche gibt es außerdem `-ne`, `-lt`, `-le`, `-gt` und `-ge`.
- **6.4** Ein exit status ungleich `0` teilt dem Aufrufer (einem anderen Script, einem Benutzer, einem Automatisierungstool) mit, dass etwas schiefgelaufen ist. So können Fehler programmgesteuert erkannt und behandelt werden.

### Übung 7

- **7.1** `do` markiert den Anfang und `done` das Ende des Schleifenkörpers.
- **7.2** Dreimal – einmal pro Element der Liste (`Apfel`, `Banane`, `Kirsche`). Bei jedem Durchlauf enthält die Variable `OBST` das aktuelle Element.
- **7.3** `"$@"` steht für alle an das Script übergebenen Argumente; die Schleife durchläuft sie der Reihe nach. Die Anführungszeichen sorgen dafür, dass Argumente mit Leerzeichen als einzelne Elemente erhalten bleiben.

### Übung 8

- **8.1** `PATH` enthält eine durch `:` getrennte Liste von Verzeichnissen, in denen die Shell nach ausführbaren Programmen sucht, wenn ein Befehl ohne Pfad eingegeben wird.
- **8.2** In Übung 1 lag das Script in einem Verzeichnis, das nicht in `PATH` enthalten war. Nachdem `~/bin` zu `PATH` hinzugefügt wurde, findet die Shell `hallo` dort automatisch – ganz ohne Pfadangabe.
- **8.3** Nein. Die Zuweisung gilt nur für die aktuelle Shell-Sitzung. Damit sie dauerhaft wirkt, müsste man sie z. B. in `~/.bashrc` oder `~/.profile` eintragen.

</details>

---

**Quellen (als Referenz verwendet):**

- LPI Learning Materials, Lektion 3.3 „Turning Commands into a Script": https://learning.lpi.org/en/learning-materials/010-160/3/3.3/