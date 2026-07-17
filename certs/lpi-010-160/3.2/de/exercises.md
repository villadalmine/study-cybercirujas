# Übungen zu Thema 3.2 – Searching and Extracting Data from Files

**Zertifizierung:** LPI Linux Essentials (Exam 010-160, Version 1.6)
**Thema:** 3.2 Searching and Extracting Data from Files
**Gewichtung:** 3
**Quelle (Referenz, keine wörtliche Übernahme):** https://learning.lpi.org/en/learning-materials/010-160/3/3.2/

In diesem Thema lernst du, wie man mit `grep`, `egrep`, `fgrep`, `cut`, `sort`, `uniq`, `tr`, `wc`, `sed` und `awk` Textdaten durchsucht, filtert und extrahiert, und wie man Streams mit Pipes (`|`) und Redirects (`>`, `>>`, `<`, `2>`) kombiniert. Öffne ein Terminal mit einer Bash-Shell und arbeite die Übungen der Reihe nach durch.

---

## Übung 1: Testdaten anlegen und mit `head`, `tail`, `wc` erkunden

1. Lege eine Arbeitsdatei mit Mitarbeiterdaten an (Felder getrennt durch `:`):

   ```bash
   cat > mitarbeiter.txt << 'EOF'
   Anna Schmidt:Entwicklung:4200:Berlin
   Ben Krueger:Vertrieb:3800:Muenchen
   Clara Fischer:Entwicklung:4600:Berlin
   David Wolf:Support:3200:Hamburg
   Anna Schmidt:Entwicklung:4200:Berlin
   Elena Vogel:Vertrieb:3900:Muenchen
   Frank Bauer:Support:3300:Hamburg
   EOF
   ```

2. Gib die ersten 3 Zeilen der Datei aus:

   ```bash
   head -n 3 mitarbeiter.txt
   ```

3. Gib die letzten 2 Zeilen der Datei aus:

   ```bash
   tail -n 2 mitarbeiter.txt
   ```

4. Zähle Zeilen, Wörter und Zeichen der Datei:

   ```bash
   wc mitarbeiter.txt
   ```

5. Zähle nur die Zeilen:

   ```bash
   wc -l mitarbeiter.txt
   ```

**Verständnisfragen 1**
1.1 Was ist der Unterschied zwischen `wc -l`, `wc -w` und `wc -c`?
1.2 Warum zählt `wc -w` bei dieser Datei mehr "Wörter" als es tatsächlich Namen gibt, obwohl Vor- und Nachname durch ein Leerzeichen getrennt sind?

---

## Übung 2: `grep`, `egrep`, `fgrep` – Suchen mit Mustern

1. Suche alle Zeilen, die "Entwicklung" enthalten:

   ```bash
   grep "Entwicklung" mitarbeiter.txt
   ```

2. Suche case-insensitive nach "berlin":

   ```bash
   grep -i "berlin" mitarbeiter.txt
   ```

3. Zähle, wie viele Zeilen auf das Muster passen, ohne sie anzuzeigen:

   ```bash
   grep -c "Vertrieb" mitarbeiter.txt
   ```

4. Zeige alle Zeilen, die NICHT auf "Support" passen:

   ```bash
   grep -v "Support" mitarbeiter.txt
   ```

5. Verwende `egrep` (extended regex), um Zeilen mit "Vertrieb" ODER "Support" zu finden:

   ```bash
   egrep "Vertrieb|Support" mitarbeiter.txt
   ```

6. Verwende `fgrep`, um exakt nach dem literalen String `4200:Berlin` zu suchen (ohne Regex-Interpretation):

   ```bash
   fgrep "4200:Berlin" mitarbeiter.txt
   ```

**Verständnisfragen 2**
2.1 Warum liefert `egrep "Vertrieb|Support"` ein anderes Ergebnis als `grep "Vertrieb|Support"` (ohne `-E`)?
2.2 In welcher Situation ist `fgrep` gegenüber `grep` im Vorteil, wenn dein Suchmuster Zeichen wie `.` oder `*` enthält?

---

## Übung 3: Reguläre Ausdrücke – Anchors, Character Classes, Quantifiers

1. Finde Zeilen, die mit "A" beginnen (Anchor `^`):

   ```bash
   grep "^A" mitarbeiter.txt
   ```

2. Finde Zeilen, die mit "Hamburg" enden (Anchor `$`):

   ```bash
   grep "Hamburg$" mitarbeiter.txt
   ```

3. Finde Zeilen mit einem Gehalt, das mit "3" oder "4" beginnt, gefolgt von genau drei Ziffern (Character Class `[0-9]` bzw. `[34]`):

   ```bash
   egrep ":[34][0-9][0-9][0-9]:" mitarbeiter.txt
   ```

4. Finde Zeilen, in denen ein Name aus zwei oder mehr Buchstaben gefolgt von einem Leerzeichen besteht (Quantifier `+`):

   ```bash
   egrep "^[A-Za-z]+ " mitarbeiter.txt
   ```

5. Finde Zeilen, bei denen der Nachname optional ein "e" vor dem Doppelpunkt hat (Quantifier `?`):

   ```bash
   egrep "e?:" mitarbeiter.txt
   ```

**Verständnisfragen 3**
3.1 Was bewirkt der Anchor `^` und was bewirkt `$` in einem regulären Ausdruck?
3.2 Was ist der Unterschied zwischen den Quantifiers `*`, `+` und `?`?

---

## Übung 4: Streams, Pipes und Redirects

1. Leite die Ausgabe von `grep` in eine neue Datei um (Redirect `>`, überschreibt):

   ```bash
   grep "Entwicklung" mitarbeiter.txt > entwicklung.txt
   cat entwicklung.txt
   ```

2. Hänge weitere Zeilen an dieselbe Datei an (Redirect `>>`, überschreibt NICHT):

   ```bash
   grep "Vertrieb" mitarbeiter.txt >> entwicklung.txt
   cat entwicklung.txt
   ```

3. Lies den Inhalt einer Datei als Standard Input ein (Redirect `<`):

   ```bash
   wc -l < entwicklung.txt
   ```

4. Provoziere einen Fehler und leite die Fehlermeldung (stderr) in eine eigene Datei um (Redirect `2>`):

   ```bash
   grep "Test" nicht_vorhanden.txt 2> fehler.txt
   cat fehler.txt
   ```

5. Kombiniere zwei Befehle mit einer Pipe (`|`), um die Anzahl der eindeutigen Städte zu zählen:

   ```bash
   cut -d: -f4 mitarbeiter.txt | sort | uniq | wc -l
   ```

**Verständnisfragen 4**
4.1 Was ist der Unterschied zwischen `>` und `>>`?
4.2 Warum landet die Fehlermeldung aus Schritt 4 in `fehler.txt` und nicht in der Standardausgabe des Terminals?
4.3 Was macht eine Pipe (`|`) im Unterschied zu einem Redirect (`>`)?

---

## Übung 5: `cut` – Spalten extrahieren

1. Extrahiere nur die Namen (erste Spalte, getrennt durch `:`):

   ```bash
   cut -d: -f1 mitarbeiter.txt
   ```

2. Extrahiere Abteilung und Stadt (Spalten 2 und 4):

   ```bash
   cut -d: -f2,4 mitarbeiter.txt
   ```

3. Extrahiere einen Zeichenbereich statt eines Felds, z. B. die ersten 4 Zeichen jeder Zeile:

   ```bash
   cut -c1-4 mitarbeiter.txt
   ```

**Verständnisfragen 5**
5.1 Wofür steht die Option `-d` bei `cut`, und was passiert, wenn du sie bei dieser Datei weglässt?
5.2 Was ist der Unterschied zwischen `cut -f` und `cut -c`?

---

## Übung 6: `sort` – Zeilen sortieren

1. Sortiere die Datei alphabetisch nach der ersten Spalte (Standardverhalten):

   ```bash
   sort mitarbeiter.txt
   ```

2. Sortiere numerisch nach dem Gehalt (Spalte 3, Feldtrenner `:`):

   ```bash
   sort -t: -k3 -n mitarbeiter.txt
   ```

3. Sortiere absteigend nach Gehalt:

   ```bash
   sort -t: -k3 -n -r mitarbeiter.txt
   ```

**Verständnisfragen 6**
6.1 Warum ist die Option `-n` bei `sort` nötig, wenn man Zahlen wie Gehälter korrekt sortieren will?
6.2 Was bewirkt `-k3` in Kombination mit `-t:`?

---

## Übung 7: `sort` + `uniq` – Duplikate finden und entfernen

1. Zeige die Datei ohne aufeinanderfolgende doppelte Zeilen (dazu muss vorher sortiert werden):

   ```bash
   sort mitarbeiter.txt | uniq
   ```

2. Zeige, wie oft jede Zeile vorkommt:

   ```bash
   sort mitarbeiter.txt | uniq -c
   ```

3. Zeige nur die Zeilen, die als Duplikat vorkommen:

   ```bash
   sort mitarbeiter.txt | uniq -d
   ```

**Verständnisfragen 7**
7.1 Warum muss die Datei vor `uniq` mit `sort` sortiert werden, damit Duplikate zuverlässig erkannt werden?
7.2 Was zeigt die Option `-d` bei `uniq` an, im Gegensatz zur Standardausgabe?

---

## Übung 8: `tr` – Zeichen übersetzen oder löschen

1. Wandle alle Kleinbuchstaben der Datei in Großbuchstaben um:

   ```bash
   tr 'a-z' 'A-Z' < mitarbeiter.txt
   ```

2. Ersetze alle Doppelpunkte durch Tabulatoren:

   ```bash
   tr ':' '\t' < mitarbeiter.txt
   ```

3. Lösche alle Ziffern aus der Ausgabe:

   ```bash
   tr -d '0-9' < mitarbeiter.txt
   ```

**Verständnisfragen 8**
8.1 Warum benötigt `tr` in diesen Beispielen immer ein Redirect (`<`) oder eine Pipe als Input, statt einen Dateinamen als Argument?
8.2 Was bewirkt die Option `-d` bei `tr`, im Vergleich zum normalen Übersetzungsmodus?

---

## Übung 9: `sed` – Zeilenweise Textersetzung

1. Ersetze das erste Vorkommen von "Muenchen" durch "München" pro Zeile:

   ```bash
   sed 's/Muenchen/München/' mitarbeiter.txt
   ```

2. Ersetze global (`g`) alle Vorkommen von "Entwicklung" durch "Dev":

   ```bash
   sed 's/Entwicklung/Dev/g' mitarbeiter.txt
   ```

3. Lösche alle Zeilen, die "Support" enthalten:

   ```bash
   sed '/Support/d' mitarbeiter.txt
   ```

**Verständnisfragen 9**
9.1 Was bewirkt das Suffix `g` am Ende eines `sed`-Substitutionsbefehls `s/.../.../`?
9.2 Wie unterscheidet sich `sed '/Muster/d'` von `grep -v "Muster"` im Ergebnis?

---

## Übung 10: `awk` – Felder gezielt verarbeiten

1. Gib nur die erste Spalte (Name) mit `awk` aus, Feldtrenner `:`:

   ```bash
   awk -F: '{print $1}' mitarbeiter.txt
   ```

2. Gib Name und Gehalt aus, formatiert mit eigenem Trenner:

   ```bash
   awk -F: '{print $1 " verdient " $3}' mitarbeiter.txt
   ```

3. Zeige nur Zeilen, in denen das Gehalt (Spalte 3) größer als 4000 ist:

   ```bash
   awk -F: '$3 > 4000 {print $1, $3}' mitarbeiter.txt
   ```

**Verständnisfragen 10**
10.1 Wofür steht `$1` bzw. `$3` in einem `awk`-Programm, und wofür steht `$0`?
10.2 Warum kann `awk` in Schritt 3 einen numerischen Vergleich (`$3 > 4000`) direkt im Suchmuster ausführen, ohne dass man vorher wie bei `sort -n` explizit "numerisch" angeben muss?

---

<details>
<summary><strong>Lösungen anzeigen</strong></summary>

**1.1** `wc -l` zählt Zeilen, `wc -w` zählt durch Whitespace getrennte Wörter, `wc -c` zählt Bytes/Zeichen insgesamt.

**1.2** Weil jede Zeile mehrere durch Leerzeichen getrennte Tokens enthält (Vorname und Nachname zählen als zwei "Wörter" für `wc -w`, da es rein auf Whitespace-Trennung basiert, nicht auf semantischer Bedeutung wie "ein Name").

**2.1** Ohne `-E` (bzw. ohne `egrep`) interpretiert `grep` das Zeichen `|` standardmäßig als literales Zeichen (Basic Regular Expression), sodass nach dem String `Vertrieb|Support` gesucht wird und nichts gefunden wird. `egrep` (Extended Regular Expression) interpretiert `|` als Alternation-Operator ("oder").

**2.2** `fgrep` (fixed strings) behandelt das Suchmuster komplett literal, ohne Regex-Metazeichen zu interpretieren. Das ist von Vorteil, wenn man z. B. nach einem Dateipfad wie `/var/log/app.log` suchen will und nicht möchte, dass `.` als "beliebiges Zeichen" interpretiert wird.

**3.1** `^` verankert das Muster am Zeilenanfang, `$` verankert es am Zeilenende.

**3.2** `*` bedeutet "null oder mehr" Vorkommen des vorangehenden Zeichens, `+` bedeutet "ein oder mehr" Vorkommen, `?` bedeutet "null oder ein" Vorkommen (optional).

**4.1** `>` überschreibt die Zieldatei komplett mit der neuen Ausgabe. `>>` hängt die Ausgabe an das Ende der bestehenden Datei an, ohne den vorhandenen Inhalt zu löschen.

**4.2** Weil `2>` speziell den Standard-Error-Stream (Filedeskriptor 2) umleitet, nicht den Standard-Output-Stream (Filedeskriptor 1). `grep` schreibt Fehlermeldungen (z. B. "Datei nicht gefunden") nach stderr, während normale Treffer nach stdout gehen.

**4.3** Eine Pipe verbindet die Standardausgabe eines Befehls direkt mit der Standardeingabe des nächsten Befehls, ohne eine Datei auf der Festplatte anzulegen. Ein Redirect leitet einen Stream stattdessen in eine Datei (oder aus einer Datei) um.

**5.1** `-d` gibt das Trennzeichen (Delimiter) zwischen den Feldern an. Ohne `-d` verwendet `cut` standardmäßig Tabulator als Trenner, wodurch bei dieser Datei (Trenner `:`) keine Felder erkannt und die ganze Zeile ausgegeben würde.

**5.2** `cut -f` extrahiert Felder basierend auf einem Trennzeichen (Delimiter-basiert), während `cut -c` einen Zeichenbereich anhand von Positionen extrahiert, unabhängig von irgendeinem Trennzeichen.

**6.1** Ohne `-n` sortiert `sort` lexikografisch (als Zeichenketten), sodass z. B. "3900" vor "4200" aber auch "300" vor "4" einsortiert werden könnte, was bei Zahlen zu falscher Reihenfolge führt. `-n` erzwingt eine numerische Sortierung.

**6.2** `-t:` legt `:` als Feldtrenner fest, `-k3` gibt an, dass nach dem dritten Feld sortiert werden soll (statt nach der ganzen Zeile bzw. dem ersten Feld).

**7.1** `uniq` vergleicht nur direkt benachbarte Zeilen miteinander. Sind gleiche Zeilen nicht unmittelbar aufeinanderfolgend, werden sie nicht als Duplikate erkannt. `sort` bringt gleiche Zeilen nebeneinander, damit `uniq` sie korrekt zusammenfasst.

**7.2** `-d` zeigt ausschließlich Zeilen an, die mindestens zweimal vorkommen (also tatsächliche Duplikate), während die Standardausgabe von `uniq` alle Zeilen (jede nur einmal) anzeigt, egal ob sie Duplikate waren oder nicht.

**8.1** `tr` liest ausschließlich von der Standardeingabe (stdin) und akzeptiert keinen Dateinamen als Argument. Deshalb muss der Dateiinhalt entweder per `<` als stdin umgeleitet oder per Pipe von einem anderen Befehl (z. B. `cat datei | tr ...`) übergeben werden.

**8.2** Im normalen Modus ersetzt `tr` jedes Zeichen aus der ersten Zeichenmenge durch das entsprechende Zeichen aus der zweiten Zeichenmenge (Übersetzung). Mit `-d` werden alle Zeichen aus der angegebenen Menge stattdessen komplett aus der Ausgabe gelöscht, ohne Ersatz.

**9.1** `g` (global) sorgt dafür, dass alle Vorkommen des Musters innerhalb einer Zeile ersetzt werden. Ohne `g` ersetzt `sed` standardmäßig nur das erste Vorkommen pro Zeile.

**9.2** Beide entfernen im Ergebnis Zeilen mit dem Muster aus der sichtbaren Ausgabe, aber `sed '/Muster/d'` löscht die Zeilen aktiv aus dem verarbeiteten Datenstrom (die restlichen Zeilen bleiben unverändert erhalten), während `grep -v "Muster"` die Eingabedatei filtert und nur die nicht-passenden Zeilen ausgibt – im Endergebnis für diesen Anwendungsfall funktional gleichwertig, aber `sed` kann zusätzlich noch weitere Bearbeitungsschritte im selben Aufruf kombinieren (z. B. gleichzeitig ersetzen).

**10.1** `$1` und `$3` referenzieren das erste bzw. dritte Feld der aktuellen Zeile (basierend auf dem mit `-F` gesetzten Feldtrenner). `$0` referenziert die gesamte aktuelle Zeile unverändert.

**10.2** `awk` erkennt bei einem Vergleich wie `$3 > 4000` automatisch anhand des Kontexts (Vergleich mit einer Zahl), dass numerisch statt lexikografisch verglichen werden soll. `sort` hingegen sortiert standardmäßig immer als Zeichenketten und benötigt die explizite Option `-n`, um stattdessen numerisch zu vergleichen.

</details>

---

Nota: no tengo herramientas de archivo disponibles en esta sesión (Bash/Read/Write no están habilitadas), así que no pude guardar esto directamente en `certs/lpi-010-160/3.2/de/exercises.md`. Si querés que lo persista ahí, decime y lo intento con las herramientas que tengas habilitadas, o pegalo vos manualmente.