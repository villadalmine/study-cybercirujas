# 5.1 Basic Security and Identifying User Types

## Introduction

Sous Linux, chaque processus et chaque fichier appartient à un utilisateur (*user*) et à un groupe (*group*). Comprendre qui peut faire quoi sur le système est la base de la sécurité (*security*) : un système mal configuré au niveau des comptes utilisateurs expose des risques d'élévation de privilèges (*privilege escalation*) ou d'accès non autorisé. Ce chapitre couvre les types de comptes existants, les fichiers qui les décrivent, et les mécanismes de base pour agir en tant qu'un autre utilisateur.

## Les types de comptes utilisateurs

### Le compte root (superuser)

`root` est le compte administrateur, aussi appelé *superuser*. Son UID (*User ID*) est toujours **0**. Il n'est soumis à aucune restriction de permissions : il peut lire, écrire, exécuter n'importe quel fichier, tuer n'importe quel processus, et configurer le système entièrement. Pour cette raison, la bonne pratique (*best practice*) est de ne jamais travailler directement en tant que `root`, mais d'utiliser des mécanismes d'élévation temporaire de privilèges comme `sudo`.

### Les comptes utilisateurs standards (regular users)

Ce sont les comptes créés pour les personnes physiques qui utilisent la machine. Sur la majorité des distributions modernes (Debian, Ubuntu), ils reçoivent un UID à partir de **1000**. Ils ont un répertoire personnel (*home directory*, typiquement `/home/<user>`) et un shell interactif (souvent `/bin/bash`).

### Les comptes système (system accounts)

Ce sont des comptes créés automatiquement pour faire fonctionner des services (`daemon`, `www-data`, `sshd`, `mysql`, etc.). Ils ne correspondent pas à des personnes et n'ont généralement pas de shell interactif : leur shell est `/usr/sbin/nologin` ou `/bin/false`, ce qui empêche toute connexion interactive avec ce compte. Leur UID se situe dans une plage intermédiaire, entre `root` et les utilisateurs standards. Cette plage est définie dans `/etc/login.defs` :

```
$ grep -E '^(UID_MIN|UID_MAX|SYS_UID_MIN|SYS_UID_MAX)' /etc/login.defs
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN                100
SYS_UID_MAX                999
```

## Le fichier /etc/passwd

Ce fichier liste tous les comptes du système, un par ligne, avec 7 champs séparés par `:` :

```
$ head -5 /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
alice:x:1000:1000:Alice Martin,,,:/home/alice:/bin/bash
sshd:x:120:65534::/run/sshd:/usr/sbin/nologin
```

Ordre des champs : `login:password:UID:GID:GECOS(commentaire):home:shell`. Le champ *password* contient aujourd'hui toujours `x`, car le mot de passe réel (haché) est stocké séparément dans `/etc/shadow`, un fichier lisible uniquement par `root` (permissions `640`, propriétaire `root:shadow`).

```
$ ls -l /etc/shadow
-rw-r----- 1 root shadow 1520 Jul 12 09:00 /etc/shadow
$ sudo head -1 /etc/shadow
root:$6$Xy...:19500:0:99999:7:::
```

Champs : `login:hash:dernier_changement:min:max:avertissement:inactif:expiration:réservé`. Ces valeurs pilotent le vieillissement des mots de passe (*password aging*), consultable et modifiable avec `chage` :

```
$ sudo chage -l alice
Last password change  : Jul 10, 2026
Password expires      : Oct 08, 2026
Password inactive     : never
Account expires        : never
```

## Identifier son propre compte et les sessions actives

```
$ whoami
alice

$ id
uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo),24(cdrom)

$ groups alice
alice : alice sudo cdrom
```

Pour voir qui est actuellement connecté :

```
$ who
alice    tty7         2026-07-12 09:14 (:0)

$ w
 09:20:01 up 2 days,  3:45,  1 user,  load average: 0.15, 0.10, 0.05
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
alice    tty7     :0               09:14    2:15   0.30s  0.05s gnome-shell

$ last -3
alice   tty7         :0               Sun Jul 12 09:14   still logged in
reboot  system boot  6.8.0-generic    Sun Jul 12 09:12   still running
alice   tty7         :0               Fri Jul 10 18:02 - down (14:22)
```

`w` montre en plus la charge système et l'activité de chaque session, utile pour repérer une connexion suspecte.

## Élévation de privilèges : su et sudo

**`su`** (*substitute user*) ouvre une nouvelle session sous l'identité d'un autre utilisateur, en général `root`, en demandant son mot de passe :

```
$ su -
Password:
# whoami
root
```

L'option `-` (équivalent à `su -l`) charge l'environnement complet de l'utilisateur cible.

**`sudo`** (*superuser do*) exécute une seule commande avec des privilèges élevés, en demandant le mot de passe **de l'utilisateur courant** (pas celui de `root`) :

```
$ sudo apt update
[sudo] password for alice:
...
```

Les autorisations `sudo` sont définies dans `/etc/sudoers`, à éditer uniquement avec `visudo` (qui valide la syntaxe avant sauvegarde et évite de casser le fichier) :

```
$ sudo visudo
```

Sur Debian/Ubuntu, appartenir au groupe `sudo` suffit généralement pour avoir tous les droits (`%sudo ALL=(ALL:ALL) ALL`) ; sur RHEL/Fedora, c'est le groupe `wheel` qui joue ce rôle. `sudo` est préférable à `su` car il journalise chaque commande exécutée (dans `/var/log/auth.log` ou via `journalctl`) et permet un contrôle fin (autoriser un utilisateur à ne lancer que certaines commandes précises).

## Bonnes pratiques de sécurité de base

- Ne jamais utiliser le compte `root` pour un usage quotidien ; préférer `sudo`.
- Verrouiller un compte inutilisé plutôt que de le supprimer : `sudo passwd -l alice` (ajoute `!` devant le hash dans `/etc/shadow`).
- Garder les comptes système sans shell interactif (`/usr/sbin/nologin`).
- Vérifier régulièrement `/etc/passwd` pour repérer un compte avec UID 0 qui ne serait pas `root` (signe de compromission).
- Appliquer les mises à jour de sécurité (*patches*) régulièrement, car les CVE non corrigées sont un vecteur classique d'accès non autorisé.

## Références

- LPI Learning Materials — 5.1 Basic Security and Identifying User Types : https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- Linux manual page — passwd(5) : https://man7.org/linux/man-pages/man5/passwd.5.html
- Linux manual page — shadow(5) : https://man7.org/linux/man-pages/man5/shadow.5.html
- Linux manual page — sudo(8) : https://man7.org/linux/man-pages/man8/sudo.8.html
- Linux manual page — su(1) : https://man7.org/linux/man-pages/man1/su.1.html
- Linux manual page — login.defs(5) : https://man7.org/linux/man-pages/man5/login.defs.5.html