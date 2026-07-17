# 1.4 ICT Skills and Working in Linux

## Introduction

Ce sujet couvre les compétences de base nécessaires pour travailler efficacement dans un environnement Linux : utiliser le *shell*, se connecter à un système en local ou à distance, gérer des fichiers, chercher de l'aide, et arrêter ou redémarrer une machine correctement. Ces compétences sont transversales à toute la certification et servent de fondation pour les sujets suivants.

## Le shell et les commandes de base

Le **shell** (ou terminal) est l'interface en ligne de commande (CLI) qui interprète les commandes tapées par l'utilisateur. Les émulateurs de terminal les plus courants sont `xterm`, `konsole` (KDE) et `gnome-terminal` (GNOME). Le shell par défaut sur la plupart des distributions est `bash` (Bourne Again SHell).

Quelques commandes de base pour s'orienter dans le système :

```bash
$ whoami
etudiant

$ pwd
/home/etudiant

$ date
Mon Jul 13 09:42:11 CEST 2026

$ echo $SHELL
/bin/bash
```

La commande `history` affiche l'historique des commandes précédemment exécutées :

```bash
$ history | tail -5
  501  cd /var/log
  502  ls -l
  503  pwd
  504  whoami
  505  history
```

### Raccourcis clavier utiles dans le shell

| Raccourci | Effet |
|---|---|
| `Tab` | Autocomplétion des commandes et des noms de fichiers |
| `Ctrl+C` | Interrompt (kill) le processus en cours |
| `Ctrl+D` | Termine la session shell (équivalent à `exit`) |
| `Ctrl+A` / `Ctrl+E` | Va au début / à la fin de la ligne |
| `Ctrl+R` | Recherche interactive dans l'historique des commandes |
| `Ctrl+L` | Efface l'écran (équivalent à `clear`) |

Ces raccourcis sont essentiels pour travailler efficacement sans dépendre uniquement de la souris.

## Se connecter au système, en local et à distance

### Connexion locale

Sur un système avec interface graphique, l'utilisateur se connecte via un **display/login manager** (par exemple GDM, LightDM ou SDDM) en entrant son nom d'utilisateur et mot de passe. Sur un système sans interface graphique (ou via une console texte accessible avec `Ctrl+Alt+F2` à `F6`), la connexion se fait directement dans un **TTY** :

```
Debian GNU/Linux 12 tty1

hostname login: etudiant
Password:
```

### Connexion distante

La commande `ssh` (Secure Shell) permet de se connecter à un système distant de façon chiffrée :

```bash
$ ssh etudiant@192.168.1.50
etudiant@192.168.1.50's password:
Linux server01 6.1.0-amd64 #1 SMP Debian
Last login: Mon Jul 13 08:15:02 2026 from 192.168.1.10
etudiant@server01:~$
```

À l'inverse, `telnet` est une méthode historique de connexion distante mais **non chiffrée** : elle transmet les identifiants en clair et ne doit pas être utilisée sur des réseaux non sécurisés. C'est un premier exemple concret de bonne pratique de sécurité ICT : préférer systématiquement `ssh` à `telnet`.

## Gestion de fichiers de base

Naviguer et manipuler des fichiers est une compétence ICT fondamentale :

```bash
$ ls -l /home/etudiant
total 8
drwxr-xr-x 2 etudiant etudiant 4096 Jul 10 10:00 Documents
-rw-r--r-- 1 etudiant etudiant  220 Jul 10 10:00 notes.txt

$ cp notes.txt notes.bak
$ mv notes.bak Documents/
$ mkdir Projets
$ rm Documents/notes.bak
```

Pour localiser un fichier dans l'arborescence :

```bash
$ find /home/etudiant -name "*.txt"
/home/etudiant/notes.txt

$ locate notes.txt
/home/etudiant/notes.txt
```

`find` parcourt le système de fichiers en temps réel (plus lent, toujours à jour), tandis que `locate` interroge une base de données préconstruite (`updatedb`), plus rapide mais potentiellement obsolète.

## Rechercher de l'information et de l'aide

Une compétence ICT essentielle est de savoir **s'auto-former** en utilisant la documentation intégrée au système plutôt que de dépendre uniquement d'une recherche web :

```bash
$ man ls
LS(1)                    User Commands                   LS(1)

NAME
       ls - list directory contents
...

$ ls --help
Usage: ls [OPTION]... [FILE]...
List information about the FILEs...
```

La commande `apropos` (ou `man -k`) recherche une commande par mot-clé lorsqu'on ne connaît pas son nom exact :

```bash
$ apropos "list directory"
ls (1)               - list directory contents
```

`info` fournit une documentation plus détaillée que `man` pour certains outils GNU :

```bash
$ info coreutils
```

## Arrêter et redémarrer le système correctement

Un arrêt brutal (coupure d'alimentation, appui long sur le bouton) risque de corrompre le système de fichiers. Il faut toujours utiliser les commandes prévues :

```bash
$ sudo shutdown -h now      # arrêt immédiat
$ sudo shutdown -r now      # redémarrage immédiat
$ sudo shutdown -h +10      # arrêt dans 10 minutes
$ sudo reboot               # redémarrage
$ sudo poweroff             # extinction

# Sur les systèmes utilisant systemd :
$ sudo systemctl poweroff
$ sudo systemctl reboot
```

## Bonnes pratiques ICT et sensibilisation à la sécurité

Au-delà des commandes, les compétences ICT incluent une sensibilisation de base à la sécurité :

- **Ingénierie sociale (social engineering)** : ne jamais communiquer son mot de passe par téléphone ou email, même si l'interlocuteur se présente comme membre du support technique.
- **Hygiène des mots de passe** : utiliser des mots de passe uniques et robustes ; la commande `passwd` permet de changer son mot de passe local :

```bash
$ passwd
Changing password for etudiant.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

- **Mises à jour** : maintenir le système à jour réduit la surface d'attaque (couvert plus en détail dans les sujets de gestion de paquets).
- **Verrouillage de session** : verrouiller son poste (`Ctrl+Alt+L` sous GNOME) avant de s'absenter.

## Références

- LPI Learning Materials — 010-160 — 1.4 ICT Skills and Working in Linux : https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- GNU Coreutils Manual : https://www.gnu.org/software/coreutils/manual/coreutils.html
- OpenSSH Manual Pages : https://www.openssh.com/manual.html
- Linux man-pages project : https://www.kernel.org/doc/man-pages/
- systemd System and Service Manager Documentation : https://www.freedesktop.org/software/systemd/man/systemctl.html