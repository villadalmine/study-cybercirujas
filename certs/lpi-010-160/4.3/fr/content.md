# 4.3 Where Data is Stored

## Introduction

Sur un système Linux, l'emplacement des données suit des conventions strictes définies par le **Filesystem Hierarchy Standard (FHS)**. Comprendre où se trouvent les fichiers de configuration, les logs, les données utilisateur et les informations sur le matériel est essentiel pour administrer un système, diagnostiquer des problèmes et gérer le stockage (disques, partitions, points de montage).

## Le Filesystem Hierarchy Standard (FHS)

Le FHS définit une arborescence commune à toutes les distributions Linux, ce qui permet de prévoir où chercher un type de donnée donné.

| Répertoire | Contenu |
|---|---|
| `/etc` | Fichiers de configuration du système (texte, éditables) |
| `/home` | Répertoires personnels des utilisateurs |
| `/root` | Répertoire personnel de l'utilisateur `root` |
| `/var` | Données variables : logs, caches, files d'attente, bases de données |
| `/var/log` | Fichiers de journalisation (logs) |
| `/tmp` | Fichiers temporaires, effacés au redémarrage (ou périodiquement) |
| `/dev` | Fichiers spéciaux représentant les périphériques (devices) |
| `/proc` | Système de fichiers virtuel exposant l'état du noyau et des processus |
| `/sys` | Système de fichiers virtuel exposant les informations sur le matériel (devices, drivers) |
| `/media` | Points de montage automatiques pour supports amovibles (USB, CD/DVD) |
| `/mnt` | Point de montage temporaire pour montages manuels |
| `/usr` | Programmes et données partagées en lecture seule (binaires, bibliothèques, docs) |
| `/opt` | Logiciels tiers optionnels, installés hors gestionnaire de paquets |

Exemple de consultation rapide de la hiérarchie :

```bash
$ ls -l /
drwxr-xr-x   2 root root  4096 mars   1 10:00 bin -> usr/bin
drwxr-xr-x  40 root root  4096 mars   1 10:02 etc
drwxr-xr-x   4 root root  4096 mars   1 10:05 home
drwxr-xr-x 132 root root     0 mars   1 09:59 proc
drwxr-xr-x  13 root root  2860 mars   1 09:59 sys
drwxrwxrwt  10 root root  4096 mars   1 11:20 tmp
drwxr-xr-x  11 root root  4096 mars   1 10:00 var
```

## Points de montage : mount, umount et /etc/fstab

Un système de fichiers (filesystem) doit être **monté** sur un point de montage (mount point, un répertoire) avant que ses fichiers ne soient accessibles. Le répertoire racine `/` est le point de montage du filesystem racine, monté automatiquement au démarrage.

### La commande `mount`

Sans argument, `mount` affiche tous les filesystems actuellement montés :

```bash
$ mount
/dev/sda1 on / type ext4 (rw,relatime)
proc on /proc type proc (rw,nosuid,nodev,noexec)
sysfs on /sys type sysfs (rw,nosuid,nodev,noexec)
tmpfs on /tmp type tmpfs (rw,nosuid,nodev)
/dev/sdb1 on /media/usb type vfat (rw,nosuid,nodev,uid=1000)
```

Pour monter manuellement un périphérique sur un répertoire existant :

```bash
$ mkdir /mnt/usb
$ mount /dev/sdb1 /mnt/usb
```

### La commande `umount`

Pour démonter un filesystem (indispensable avant de retirer un support amovible en toute sécurité) :

```bash
$ umount /mnt/usb
```

Si le filesystem est occupé (fichier ouvert, répertoire courant d'un processus), `umount` renverra une erreur `target is busy` ; il faut alors identifier le processus concerné (par exemple avec `lsof` ou `fuser`).

### Le fichier `/etc/fstab`

`/etc/fstab` (« filesystem table ») décrit les filesystems à monter automatiquement au démarrage, avec leurs options. Chaque ligne comporte six champs : périphérique, point de montage, type, options, dump, ordre de fsck.

```bash
$ cat /etc/fstab
# <device>        <mount point>  <type>  <options>          <dump> <pass>
UUID=1a2b3c4d...   /              ext4    defaults           0      1
UUID=5e6f7a8b...   /home          ext4    defaults           0      2
UUID=9c0d1e2f...   swap           swap    sw                 0      0
/dev/sr0           /media/cdrom0  iso9660 ro,user,noauto      0      0
```

L'utilisation d'un `UUID` plutôt qu'un nom de périphérique (`/dev/sda1`) évite les problèmes si l'ordre de détection des disques change. Grâce à `/etc/fstab`, la commande `mount -a` (souvent exécutée au boot) monte tous les filesystems listés sans avoir à préciser leurs options manuellement.

Pour visualiser l'espace disque utilisé sur les filesystems montés :

```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        20G  8.1G   11G  43% /
/dev/sda2       100G   62G   33G  66% /home
tmpfs           2.0G     0  2.0G   0% /tmp
```

## Les systèmes de fichiers virtuels `/proc` et `/sys`

`/proc` et `/sys` ne contiennent pas de données réelles sur disque : ce sont des filesystems virtuels générés dynamiquement par le noyau (kernel), donnant accès en temps réel à son état interne.

### `/proc`

Chaque processus en cours d'exécution possède un sous-répertoire `/proc/<PID>` avec des informations sur son état, sa mémoire, ses fichiers ouverts, etc. `/proc` contient aussi des fichiers globaux sur le matériel et le noyau :

```bash
$ cat /proc/cpuinfo | head -5
processor       : 0
vendor_id       : GenuineIntel
model name      : Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz
cpu MHz         : 3600.000
cache size      : 12288 KB

$ cat /proc/meminfo | head -3
MemTotal:       16362840 kB
MemFree:         8213456 kB
MemAvailable:   12045320 kB

$ cat /proc/version
Linux version 6.1.0-generic (gcc version 12.2.0) ...
```

### `/sys`

`/sys` expose une vue structurée des périphériques (devices), pilotes (drivers) et bus reconnus par le noyau, utilisée notamment par `udev` pour la gestion dynamique des périphériques :

```bash
$ ls /sys/class/net
eth0  lo  wlan0

$ cat /sys/class/net/eth0/address
52:54:00:12:34:56
```

## Les fichiers de journalisation (log files)

Les logs système, essentiels au diagnostic, se trouvent traditionnellement dans `/var/log` :

| Fichier | Contenu typique |
|---|---|
| `/var/log/syslog` ou `/var/log/messages` | Messages système généraux |
| `/var/log/auth.log` ou `/var/log/secure` | Authentifications, usage de `sudo`, connexions SSH |
| `/var/log/kern.log` | Messages du noyau |
| `/var/log/boot.log` | Déroulement du démarrage |
| `/var/log/dmesg` | Messages du noyau au démarrage (voir aussi la commande `dmesg`) |

```bash
$ tail -5 /var/log/syslog
Mar  1 10:15:02 host systemd[1]: Starting Daily apt upgrade...
Mar  1 10:15:03 host CRON[2145]: (root) CMD (   test -x /usr/sbin/anacron)
```

Sur les systèmes utilisant `systemd`, les logs sont aussi centralisés dans le **journal binaire** (`journald`), consultable avec :

```bash
$ journalctl -xe
```

Il est important de savoir que la taille de `/var/log` peut croître rapidement ; des outils comme `logrotate` compressent et archivent les anciens logs automatiquement.

```bash
$ du -sh /var/log/*
15M  /var/log/syslog
2.3M /var/log/auth.log
1.1M /var/log/kern.log
```

## Résumé

- Le **FHS** définit une structure commune : `/etc` (config), `/home` (utilisateurs), `/var/log` (logs), `/tmp` (temporaire).
- `/proc` et `/sys` sont des filesystems **virtuels** reflétant l'état du noyau et du matériel en temps réel — rien n'y est stocké physiquement.
- `mount` et `umount` gèrent le rattachement des filesystems à l'arborescence ; `/etc/fstab` automatise ce montage au démarrage.
- Les logs dans `/var/log` (ou via `journalctl`) sont la première source d'information en cas de problème système.

## Références

- LPI Learning Materials — Topic 4.3 Where Data is Stored : https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Filesystem Hierarchy Standard : https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html
- man page `mount(8)` : https://man7.org/linux/man-pages/man8/mount.8.html
- man page `fstab(5)` : https://man7.org/linux/man-pages/man5/fstab.5.html
- man page `proc(5)` : https://man7.org/linux/man-pages/man5/proc.5.html
- man page `journalctl(1)` : https://man7.org/linux/man-pages/man1/journalctl.1.html