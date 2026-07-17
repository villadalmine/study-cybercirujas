# Thema 5.1: Basic Security and Identifying User Types

## Einführung

Linux ist von Grund auf als **Multiuser-System** konzipiert: Mehrere Accounts können gleichzeitig auf demselben System arbeiten, jeder mit eigenen Rechten, eigenem Home-Verzeichnis und eigener Umgebung. Grundlegendes Sicherheitsverständnis beginnt damit, zu wissen, welche Arten von Usern es gibt, welche Rechte sie haben und wie das System diese Unterscheidung technisch umsetzt.

## Benutzerarten (User Types)

Auf einem typischen Linux-System lassen sich drei Kategorien von Accounts unterscheiden:

### 1. Der Superuser (root)

- Hat die **UID 0**.
- Unterliegt keinen Zugriffsbeschränkungen: kann jede Datei lesen/schreiben, jeden Prozess beenden, Kernel-Module laden, Netzwerkschnittstellen konfigurieren usw.
- Aus Sicherheitsgründen sollte man sich **nicht dauerhaft als root** einloggen oder arbeiten, sondern nur gezielt privilegierte Befehle ausführen (Prinzip der geringsten Rechte / *principle of least privilege*).

### 2. System-User (System Accounts)

- Werden bei der Installation von Paketen/Diensten automatisch angelegt (z. B. `www-data`, `mysql`, `sshd`, `nobody`).
- Dienen dazu, Dienste (*daemons*) mit eingeschränkten Rechten laufen zu lassen, statt sie als root auszuführen.
- Haben meist **kein reguläres Login-Shell** (`/usr/sbin/nologin` oder `/bin/false`) und kein eigenes Passwort für den interaktiven Login.
- UID-Bereich ist distributionsabhängig, typischerweise **1–999** (Debian/Ubuntu) bzw. **1–499** (ältere RedHat-Systeme).

### 3. Reguläre User (Normal/Regular Users)

- Werden für echte Personen angelegt, die sich interaktiv einloggen.
- Haben ein eigenes Home-Verzeichnis (`/home/<username>`) und eine Login-Shell (z. B. `/bin/bash`).
- UID-Bereich beginnt meist bei **1000** (Debian/Ubuntu, viele moderne Distros) oder **500** (ältere RedHat/CentOS).

```bash
$ id
uid=1000(anna) gid=1000(anna) groups=1000(anna),27(sudo),1001(developers)

$ id root
uid=0(root) gid=0(root) groups=0(root)

$ id www-data
uid=33(www-data) gid=33(www-data) groups=33(www-data)
```

## Wichtige Konfigurationsdateien

Die Verwaltung von Usern basiert auf einigen zentralen Textdateien in `/etc`.

### `/etc/passwd`

Enthält die grundlegenden Informationen zu jedem Account: Username, UID, GID, Kommentarfeld (GECOS), Home-Verzeichnis und Login-Shell. Trotz des Namens stehen hier **keine Passwörter** (mehr) – das Passwort-Feld ist historisch bedingt und zeigt heute nur ein Platzhalterzeichen (`x`).

```bash
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
anna:x:1000:1000:Anna Mustermann,,,:/home/anna:/bin/bash
```

Format der Felder (durch `:` getrennt):
`username:password:UID:GID:GECOS:home:shell`

### `/etc/shadow`

Enthält die tatsächlichen (gehashten) Passwörter sowie Informationen zur Passwort-Aging-Policy. Diese Datei ist nur für root lesbar (Rechte `640` oder `600`), was einen wichtigen Sicherheitsmechanismus darstellt – ohne Shadow-Passwörter könnte jeder Benutzer die Hashes in `/etc/passwd` (weltweit lesbar) auslesen und offline angreifen.

```bash
$ sudo cat /etc/shadow
anna:$6$rZ1k...hashvalue...:19500:0:99999:7:::
```

Felder: `username:hash:letzte_Änderung:min_Tage:max_Tage:Warnung:Inaktivität:Ablaufdatum`

### `/etc/group`

Definiert Gruppen und deren Mitglieder.

```bash
$ cat /etc/group
sudo:x:27:anna
developers:x:1001:anna,ben
```

## Root-Rechte kontrolliert nutzen: `su` und `sudo`

Da dauerhaftes Arbeiten als root riskant ist (jeder Tippfehler kann das System beschädigen), gibt es zwei Standardwerkzeuge:

- **`su`** (*substitute user*): wechselt komplett zu einem anderen User (meist root), erfordert dessen Passwort.

```bash
$ su -
Password:
# whoami
root
```

- **`sudo`** (*superuser do*): führt **einen einzelnen Befehl** mit den Rechten eines anderen Users (üblicherweise root) aus, erfordert das **eigene** Passwort und protokolliert die Aktion (z. B. in `/var/log/auth.log`). Wer `sudo`-Rechte hat, wird in `/etc/sudoers` (bzw. per Gruppenmitgliedschaft, z. B. Gruppe `sudo` oder `wheel`) festgelegt.

```bash
$ sudo apt update
[sudo] password for anna:
...
$ sudo whoami
root
```

`sudo` ist die empfohlene Methode, weil sie granularer ist: Man kann einzelnen Usern nur bestimmte Befehle mit root-Rechten erlauben, statt volle root-Zugangsdaten zu teilen.

## Grundlegende Security-Prinzipien

- **Least Privilege**: Jeder Account (Mensch oder Dienst) sollte nur die minimal nötigen Rechte besitzen.
- **Trennung von Rollen**: Interaktive Arbeit über einen regulären User, administrative Aufgaben gezielt über `sudo`.
- **Keine geteilten Accounts**: Jede Person sollte einen eigenen Account haben (Nachvollziehbarkeit/Accountability über Logs).
- **Starke Passwort-Policy**: Passwort-Aging über `chage` bzw. Felder in `/etc/shadow`, Mindestlänge/Komplexität über PAM-Module (`/etc/pam.d/`).
- **Unnötige Accounts deaktivieren/entfernen**: Nicht mehr benötigte System- oder Benutzer-Accounts sind ein Angriffsvektor.

```bash
$ sudo passwd -l gastuser      # Account sperren (lock)
$ sudo chage -l anna           # Passwort-Aging-Infos anzeigen
Last password change : Jan 15, 2026
Password expires     : Apr 15, 2026
```

## Zusammenfassung (prüfungsrelevant)

| Aspekt | root | System-User | Regulärer User |
|---|---|---|---|
| UID | 0 | 1–999 (bzw. 1–499) | ab 1000 (bzw. 500) |
| Login interaktiv | ja | i. d. R. nein | ja |
| Home-Verzeichnis | `/root` | oft `/nonexistent` o. Ä. | `/home/<user>` |
| Shell | `/bin/bash` | `/usr/sbin/nologin` | `/bin/bash` o. Ä. |
| Zweck | Systemverwaltung | Dienste ausführen | Menschliche Nutzer |

## Referenzen

- LPI Learning Materials, Topic 5.1: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- `passwd(5)` man page: https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` man page: https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` man page: https://man7.org/linux/man-pages/man5/group.5.html
- `sudo(8)` man page: https://man7.org/linux/man-pages/man8/sudo.8.html
- `su(1)` man page: https://man7.org/linux/man-pages/man1/su.1.html
- `chage(1)` man page: https://man7.org/linux/man-pages/man1/chage.1.html