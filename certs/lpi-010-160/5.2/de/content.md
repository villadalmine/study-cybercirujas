# 5.2 Creating Users and Groups

## Warum Users und Groups?

Linux ist ein Multi-User-System: Jeder Prozess läuft im Kontext eines Users, und jede Datei gehört einem Owner und einer Group. Über Users und Groups steuert das System, wer welche Ressourcen lesen, schreiben oder ausführen darf. Als Systemadministrator legst du Accounts an, ordnest sie Groups zu und verwaltest ihren Lifecycle — vom Anlegen bis zum Löschen.

Man unterscheidet grob:

- **Normale User**: für Menschen, die sich interaktiv einloggen (meist UID ≥ 1000).
- **System-User**: für Dienste und Daemons (z. B. `www-data`, `sshd`), üblicherweise UID < 1000, kein interaktives Login nötig.
- **root**: der Superuser mit UID 0, uneingeschränkte Rechte.

## Die relevanten Dateien

Alle User- und Group-Verwaltungstools sind letztlich nur Frontends, die diese Dateien konsistent verändern.

### /etc/passwd

Enthält die grundlegenden Account-Informationen, lesbar für alle:

```
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
sshd:x:105:65534::/run/sshd:/usr/sbin/nologin
mia:x:1001:1001:Mia Fischer,,,:/home/mia:/bin/bash
```

Sieben Felder, getrennt durch `:`:

| Feld | Bedeutung | Beispiel |
|---|---|---|
| 1 | Login-Name | `mia` |
| 2 | Password-Placeholder (`x` = liegt in `/etc/shadow`) | `x` |
| 3 | UID | `1001` |
| 4 | GID der primären Group | `1001` |
| 5 | GECOS-Feld (Kommentar, meist Full Name) | `Mia Fischer,,,` |
| 6 | Home-Directory | `/home/mia` |
| 7 | Login-Shell | `/bin/bash` |

### /etc/shadow

Enthält die verschlüsselten Passwörter und Aging-Informationen. Nur für `root` lesbar:

```
$ sudo cat /etc/shadow
mia:$6$rZ1k...:19700:0:90:7:14:19800:
```

Felder: Login-Name, Password-Hash, Datum der letzten Änderung (Tage seit 1970-01-01), Minimum-Age, Maximum-Age, Warn-Periode, Inactive-Periode, Expire-Datum, reserviert.

### /etc/group

Definiert Groups und ihre zusätzlichen (sekundären) Mitglieder:

```
$ cat /etc/group
sudo:x:27:mia
docker:x:998:mia,leon
mia:x:1001:
```

Felder: Group-Name, Password-Placeholder, GID, Kommagetrennte Liste zusätzlicher Members. Die **primäre** Group eines Users steht nicht hier, sondern im GID-Feld von `/etc/passwd`.

### /etc/gshadow

Analog zu `/etc/shadow`, aber für Group-Passwörter und Group-Admins — in der Praxis selten genutzt.

## User-Verwaltung

### useradd — User anlegen

```
$ sudo useradd -m -c "Mia Fischer" -s /bin/bash mia
```

Wichtige Optionen:

- `-m` — Home-Directory anlegen (kopiert Skeleton-Files aus `/etc/skel`)
- `-c "..."` — GECOS/Comment-Feld
- `-s /bin/bash` — Login-Shell
- `-g GROUP` — primäre Group explizit setzen
- `-G group1,group2` — zusätzliche (sekundäre) Groups
- `-u UID` — UID explizit vergeben
- `-d /pfad` — abweichendes Home-Directory
- `-r` — System-User anlegen (keine Home-Directory-Erstellung standardmäßig, niedrige UID)

Ohne `-m` wird auf manchen Distributionen kein Home-Directory erzeugt — Debian/Ubuntu haben das per `useradd` Defaults (`/etc/default/useradd`) teils anders konfiguriert als z. B. Fedora/RHEL, wo `-m` oft implizit ist. Verlass dich nie auf das Default-Verhalten, sondern setz `-m` explizit.

Direkt danach muss ein Passwort gesetzt werden — ohne Passwort ist der Account gesperrt (`!` in `/etc/shadow`).

### passwd — Passwort setzen/ändern

```
$ sudo passwd mia
New password:
Retype new password:
passwd: password updated successfully
```

Ein normaler User kann sein eigenes Passwort ohne `sudo` ändern (`passwd` ohne Argument). `root` kann jedes Passwort setzen.

Nützliche `passwd`-Optionen für Account-Aging:

- `passwd -l mia` — Account sperren (lock, setzt `!` vor den Hash)
- `passwd -u mia` — Account entsperren
- `passwd -e mia` — Passwort sofort als abgelaufen markieren (User muss bei nächstem Login ändern)
- `passwd -S mia` — Status anzeigen

### usermod — User ändern

```
$ sudo usermod -aG docker mia
```

`-aG` (append + Groups) ist der wichtigste Stolperstein: `-G` allein **ersetzt** die komplette Liste sekundärer Groups. Ohne `-a` fliegt der User aus allen bisherigen Zusatz-Groups, außer der neu angegebenen.

Weitere Optionen:

- `-l neuername` — Login-Name ändern
- `-d /neues/home -m` — Home-Directory verschieben
- `-s /bin/zsh` — Shell ändern
- `-L` / `-U` — Account sperren/entsperren (äquivalent zu `passwd -l/-u`)
- `-e YYYY-MM-DD` — Expire-Datum setzen

### userdel — User löschen

```
$ sudo userdel -r mia
```

`-r` entfernt zusätzlich das Home-Directory und die Mail-Spool. Ohne `-r` bleiben diese Dateien als verwaiste UID-Objekte liegen — ein häufiger Grund für „komische" Berechtigungsprobleme nach dem Löschen von Usern.

## Group-Verwaltung

### groupadd

```
$ sudo groupadd -g 2000 projektteam
```

`-g` vergibt eine explizite GID; ohne Angabe wird die nächste freie GID genutzt.

### groupmod

```
$ sudo groupmod -n team-neu projektteam
```

`-n` benennt die Group um, `-g` ändert die GID.

### groupdel

```
$ sudo groupdel projektteam
```

Schlägt fehl, wenn die Group noch die primäre Group eines existierenden Users ist — vorher `usermod -g` auf allen betroffenen Accounts anpassen.

## Informationen abfragen

### id — UID, GID und Group-Memberships eines Users

```
$ id mia
uid=1001(mia) gid=1001(mia) groups=1001(mia),27(sudo),998(docker)
```

### who und w — wer ist gerade eingeloggt

```
$ who
mia      pts/0        2026-07-13 09:12 (10.0.0.5)

$ w
 09:20:03 up 3 days,  4:11,  1 user,  load average: 0.12, 0.08, 0.05
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
mia      pts/0    10.0.0.5         09:12    0.00s  0.04s  0.00s w
```

`w` zeigt zusätzlich Uptime, Load und die aktuell laufenden Prozesse pro Session.

### last — Login-Historie

```
$ last mia
mia      pts/0        10.0.0.5         Mon Jul 13 09:12   still logged in
```

Liest aus `/var/log/wtmp`.

### chage — Passwort-Aging anzeigen/setzen

```
$ sudo chage -l mia
Last password change                    : Jul 10, 2026
Password expires                        : Oct 08, 2026
Password inactive                       : Oct 15, 2026
Account expires                         : never
```

## Praxisbeispiel: kompletter Workflow

```
$ sudo groupadd projektteam
$ sudo useradd -m -c "Leon Bauer" -s /bin/bash -g projektteam -G sudo leon
$ sudo passwd leon
$ id leon
uid=1002(leon) gid=2000(projektteam) groups=2000(projektteam),27(sudo)
```

Hier bekommt `leon` `projektteam` als **primäre** Group (`-g`) und zusätzlich `sudo` als **sekundäre** Group (`-G`).

## Zusammenfassung

| Aufgabe | Command |
|---|---|
| User anlegen | `useradd -m -s /bin/bash name` |
| Passwort setzen | `passwd name` |
| User zu Group hinzufügen (ohne bestehende zu verlieren) | `usermod -aG group name` |
| User löschen inkl. Home | `userdel -r name` |
| Group anlegen | `groupadd name` |
| Group löschen | `groupdel name` |
| Account-Details anzeigen | `id name` |
| Eingeloggte User anzeigen | `who`, `w` |
| Login-Historie | `last name` |

## Referenzen

- LPI Learning Materials — 5.2 Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- `useradd(8)` man page: https://man7.org/linux/man-pages/man8/useradd.8.html
- `usermod(8)` man page: https://man7.org/linux/man-pages/man8/usermod.8.html
- `userdel(8)` man page: https://man7.org/linux/man-pages/man8/userdel.8.html
- `groupadd(8)` man page: https://man7.org/linux/man-pages/man8/groupadd.8.html
- `passwd(1)` man page: https://man7.org/linux/man-pages/man1/passwd.1.html
- `passwd(5)` — Format von `/etc/passwd`: https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` — Format von `/etc/shadow`: https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` — Format von `/etc/group`: https://man7.org/linux/man-pages/man5/group.5.html
- `chage(1)` man page: https://man7.org/linux/man-pages/man1/chage.1.html