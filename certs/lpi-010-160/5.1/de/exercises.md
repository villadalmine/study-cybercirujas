# Übung 5.1: Basic Security and Identifying User Types

## Voraussetzungen
Ein Linux-System mit Terminal-Zugriff und einem regulären user-Account.

## Block 1: Den eigenen User identifizieren

1. Öffne ein Terminal und führe `whoami` aus.
2. Führe zusätzlich `id` aus und beobachte die Ausgabe.
3. Notiere dir die UID (user ID) und GID (group ID), die `id` anzeigt.
4. Falls möglich, führe `id root` aus und vergleiche die UID mit deiner eigenen.

**Fragen:**
- Welche UID hat der root user immer?
- Was zeigt `id` zusätzlich an, das `whoami` nicht anzeigt?

## Block 2: /etc/passwd erkunden

1. Zeige den Inhalt der Datei an: `cat /etc/passwd`
2. Suche deinen eigenen Eintrag: `grep "^$(whoami):" /etc/passwd`
3. Analysiere die sieben durch Doppelpunkt getrennten Felder (username:password-placeholder:UID:GID:comment:home directory:login shell).
4. Suche einen system user, z. B. `grep "^daemon:" /etc/passwd` oder `grep "^nobody:" /etc/passwd`.
5. Vergleiche dessen login shell mit deiner eigenen.

**Fragen:**
- Warum steht im password-Feld von /etc/passwd meist nur ein „x"?
- Woran erkennst du, ob ein Eintrag ein system user statt ein regulärer user ist?
- Welchen typischen UID-Bereich haben system user im Vergleich zu regulären usern?

## Block 3: Angemeldete User anzeigen

1. Führe `who` aus und sieh dir an, welche user aktuell angemeldet sind.
2. Führe `w` aus und vergleiche die zusätzlichen Informationen.
3. Öffne eine zweite Terminal-Session (oder SSH-Verbindung) und melde dich erneut an.
4. Führe `who` im ersten Terminal erneut aus.

**Fragen:**
- Welche Information liefert `w`, die `who` nicht liefert?
- Wie könntest du herausfinden, wie lange ein user bereits inaktiv (idle) ist?

## Block 4: Privilege escalation mit sudo

1. Versuche, eine root-geschützte Datei zu lesen: `cat /etc/shadow`. Beobachte die Fehlermeldung.
2. Wiederhole den Befehl mit sudo: `sudo cat /etc/shadow`.
3. Gib bei Aufforderung dein eigenes Passwort ein.
4. Führe `sudo whoami` aus und beobachte die Ausgabe.
5. Prüfe deine Berechtigungen mit `sudo -l`.

**Fragen:**
- Wessen Passwort fragt `sudo` ab: das des aktuellen users oder das von root?
- Wie unterstützt die „permission denied"-Meldung aus Schritt 1 das Prinzip der geringsten Rechte (least privilege)?

## Block 5: su vs. sudo

1. Führe `su -` aus (root-Passwort erforderlich; falls nicht verfügbar, beantworte die Fragen konzeptionell).
2. Führe in der root-Shell `whoami` und `id` aus.
3. Verlasse die root-Shell mit `exit`.
4. Vergleiche: Wie oft musstest du bei `su -` ein Passwort eingeben, im Vergleich zu mehreren `sudo`-Befehlen kurz hintereinander?

**Fragen:**
- Was ist der grundlegende Unterschied zwischen `su -` und `sudo <command>` bezüglich der Session?
- Warum gilt `sudo` in vielen Distributionen als sicherer als ein aktiviertes root-Passwort?

## Block 6: System user identifizieren

1. Liste alle Einträge mit UID kleiner als 1000: `awk -F: '$3 < 1000 {print $1, $3}' /etc/passwd`
2. Wähle drei system user aus der Liste (z. B. `www-data`, `sshd`, `mail`) und überlege, wofür sie verwendet werden.
3. Prüfe die login shell eines dieser user, z. B. `grep "^www-data:" /etc/passwd`.

**Fragen:**
- Warum haben viele system user als login shell `/usr/sbin/nologin`?
- Welchen Sicherheitsvorteil bietet es, dass services unter eigenen system usern statt unter root laufen?

---

<details>
<summary>Lösungen</summary>

**Block 1**
- root hat immer die UID 0.
- `id` zeigt zusätzlich UID, GID und alle supplementary groups des users an.

**Block 2**
- Das „x" ist ein Platzhalter; das eigentliche verschlüsselte Passwort liegt aus Sicherheitsgründen in /etc/shadow, das nur für root lesbar ist (im Gegensatz zu /etc/passwd, das für alle lesbar ist).
- System user haben meist eine niedrige UID und eine login shell wie `/usr/sbin/nologin` oder `/bin/false`, die einen interaktiven Login verhindert.
- Reguläre user haben typischerweise UIDs ab 1000 (je nach Distribution ab 500); system user liegen im Bereich 1–999.

**Block 3**
- `w` zeigt zusätzlich laufende Prozesse, idle-Zeit und die Systemauslastung (load average) an.
- Über die idle-Spalte in der Ausgabe von `w`.

**Block 4**
- `sudo` fragt das Passwort des aktuellen (aufrufenden) users ab, nicht das von root.
- Sie zeigt, dass reguläre user standardmäßig keine root-Rechte besitzen; erst eine explizite, protokollierte Rechteausweitung über sudo gewährt temporär erweiterte Rechte für genau diesen Befehl.

**Block 5**
- `su -` startet eine vollständige neue Login-Shell als root, die bestehen bleibt, bis sie mit `exit` verlassen wird. `sudo <command>` führt nur einen einzelnen Befehl mit erhöhten Rechten aus und kehrt danach zur eigenen Shell zurück.
- Bei `sudo` muss kein separates root-Passwort existieren oder bekannt sein (root ist bei vielen Distributionen sogar gesperrt), jede Rechteausweitung wird protokolliert, und der Zugriff lässt sich über /etc/sudoers granular auf bestimmte Befehle und user beschränken.

**Block 6**
- `/usr/sbin/nologin` verhindert einen interaktiven Login, da system user ausschließlich für den Betrieb von services existieren.
- Läuft ein service unter einem eigenen, eingeschränkten system user statt unter root, bleibt der Schaden bei einer Kompromittierung begrenzt – ein zentrales Element des principle of least privilege.

</details>

---

**Quelle:** https://learning.lpi.org/en/learning-materials/010-160/5/5.1/