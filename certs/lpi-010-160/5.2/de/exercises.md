# Übung: Creating Users and Groups

**LPI Linux Essentials (010-160, v1.6) – Thema 5.2**
Quelle zur Orientierung: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/

---

## Teil 1: Aktuellen Status prüfen

1. Öffne ein Terminal und stelle fest, mit welchem User du gerade angemeldet bist:
   ```bash
   whoami
   ```
2. Zeige deine User-ID (UID), Group-ID (GID) und alle Gruppen an, denen du angehörst:
   ```bash
   id
   ```
3. Schau dir die Liste aller vorhandenen User-Accounts an, indem du die Datei `/etc/passwd` betrachtest:
   ```bash
   cat /etc/passwd
   ```
4. Zähle, wie viele Zeilen die Datei hat:
   ```bash
   wc -l /etc/passwd
   ```

**Verständnisfragen:**
- Aus welchen Feldern besteht eine Zeile in `/etc/passwd` (durch `:` getrennt)?
- Warum stehen in `/etc/passwd` auch System-Accounts wie `daemon` oder `bin`, obwohl sich dort niemand einloggt?

---

## Teil 2: Einen neuen User anlegen

1. Lege als `root` (bzw. mit `sudo`) einen neuen User namens `anna` an:
   ```bash
   sudo useradd -m anna
   ```
2. Prüfe, ob ein Home-Verzeichnis für `anna` erstellt wurde:
   ```bash
   ls -ld /home/anna
   ```
3. Vergib ein Passwort für den neuen Account:
   ```bash
   sudo passwd anna
   ```
4. Kontrolliere den neuen Eintrag in `/etc/passwd`:
   ```bash
   grep anna /etc/passwd
   ```
5. Kontrolliere den zugehörigen Eintrag in `/etc/shadow`:
   ```bash
   sudo grep anna /etc/shadow
   ```

**Verständnisfragen:**
- Was bewirkt die Option `-m` bei `useradd` genau?
- Welche Information steht im verschlüsselten Passwort-Feld von `/etc/shadow`, wenn für den User noch kein Passwort gesetzt wurde?
- Warum ist `/etc/shadow` nur für `root` lesbar, `/etc/passwd` aber für alle?

---

## Teil 3: Eine Gruppe anlegen und Mitglieder hinzufügen

1. Lege eine neue Gruppe namens `projekt` an:
   ```bash
   sudo groupadd projekt
   ```
2. Prüfe den neuen Eintrag in `/etc/group`:
   ```bash
   grep projekt /etc/group
   ```
3. Füge den User `anna` als zusätzliches Mitglied (secondary group) zur Gruppe `projekt` hinzu:
   ```bash
   sudo usermod -aG projekt anna
   ```
4. Bestätige die Mitgliedschaft:
   ```bash
   groups anna
   id anna
   ```

**Verständnisfragen:**
- Was würde passieren, wenn du in Schritt 3 die Option `-a` weglässt und stattdessen nur `usermod -G projekt anna` ausführst?
- Was ist der Unterschied zwischen der **primary group** und einer **secondary group** eines Users?

---

## Teil 4: User-Eigenschaften ändern

1. Ändere die Login-Shell von `anna` auf `/bin/bash` (falls noch nicht gesetzt):
   ```bash
   sudo usermod -s /bin/bash anna
   ```
2. Setze einen Kommentar (GECOS-Feld) mit dem vollen Namen des Users:
   ```bash
   sudo usermod -c "Anna Musterfrau" anna
   ```
3. Zeige den aktualisierten Eintrag in `/etc/passwd`:
   ```bash
   grep anna /etc/passwd
   ```
4. Setze eine Ablauffrist (expiry date) für den Account auf den 31.12. des aktuellen Jahres:
   ```bash
   sudo chage -E $(date -d "2026-12-31" +%Y-%m-%d) anna
   ```
5. Zeige die Account-Ageing-Informationen an:
   ```bash
   sudo chage -l anna
   ```

**Verständnisfragen:**
- In welchem Feld von `/etc/passwd` wird das GECOS-Feld gespeichert?
- Welchen Befehl könntest du alternativ zu `usermod -s` verwenden, um nur die Shell eines Users zu ändern?

---

## Teil 5: User und Gruppe entfernen

1. Entferne den User `anna`, aber behalte sein Home-Verzeichnis:
   ```bash
   sudo userdel anna
   ```
2. Prüfe, dass `anna` nicht mehr in `/etc/passwd` steht:
   ```bash
   grep anna /etc/passwd
   ```
3. Prüfe, dass das Home-Verzeichnis noch existiert:
   ```bash
   ls -ld /home/anna
   ```
4. Entferne nun auch die Gruppe `projekt`:
   ```bash
   sudo groupdel projekt
   ```

**Verständnisfragen:**
- Welche Option müsstest du bei `userdel` zusätzlich angeben, damit das Home-Verzeichnis mit gelöscht wird?
- Warum lässt sich eine Gruppe mit `groupdel` nicht entfernen, solange sie noch die primary group eines existierenden Users ist?

---

<details>
<summary><strong>Lösungen anzeigen</strong></summary>

**Teil 1**
- Die sieben Felder sind: `username:password:UID:GID:GECOS:home_directory:shell`. Das `password`-Feld enthält heute meist nur ein `x`, da die eigentlichen Hashes in `/etc/shadow` liegen.
- System-Accounts existieren, damit Dienste (daemons) und Prozesse mit eigenen, eingeschränkten Rechten laufen können, statt als `root` – das erhöht die Sicherheit, auch wenn sich niemand interaktiv einloggt.

**Teil 2**
- `-m` (`--create-home`) sorgt dafür, dass `useradd` automatisch ein Home-Verzeichnis für den neuen User anlegt und die Dateien aus `/etc/skel` dorthin kopiert.
- Ohne gesetztes Passwort steht dort meist `!` oder `!!` – das kennzeichnet den Account als gesperrt (locked), ein Login per Passwort ist nicht möglich.
- `/etc/shadow` enthält die Passwort-Hashes; wäre die Datei für alle lesbar, könnten Angreifer Offline-Angriffe (z. B. Brute-Force) gegen die Hashes fahren. `/etc/passwd` enthält keine sensiblen Hashes mehr und muss für viele Tools (z. B. `ls -l` zur Anzeige von Usernamen) lesbar bleiben.

**Teil 3**
- Ohne `-a` (`--append`) ersetzt `usermod -G` **alle** bisherigen secondary groups des Users durch die neu angegebene Liste – `anna` würde also aus allen anderen Gruppen entfernt, in denen sie vorher war.
- Die primary group ist die Gruppe, die beim Anlegen neuer Dateien standardmäßig als Gruppeneigentümer verwendet wird (Eintrag im GID-Feld von `/etc/passwd`). Secondary groups sind zusätzliche Gruppenmitgliedschaften, die zusätzliche Rechte gewähren, ohne die primary group zu ändern.

**Teil 4**
- Es ist das fünfte Feld in `/etc/passwd` (GECOS), das üblicherweise den vollen Namen und weitere Kontaktinformationen enthält.
- Der Befehl `chsh -s /bin/bash anna` (change shell) ändert gezielt nur die Login-Shell.

**Teil 5**
- Die Option `-r` (`--remove`), also `userdel -r anna`, löscht zusätzlich das Home-Verzeichnis und die Mail-Spool des Users.
- `groupdel` verweigert das Löschen, weil jeder User zwingend eine gültige primary group benötigt; würde die Gruppe gelöscht, gäbe es einen User-Eintrag mit einer GID, die auf keine existierende Gruppe mehr verweist.

</details>