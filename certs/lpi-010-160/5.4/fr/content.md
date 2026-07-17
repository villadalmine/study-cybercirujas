# Thème 5.4 : Special Directories and Files

## Le Filesystem Hierarchy Standard (FHS)

Linux organise ses fichiers selon le **Filesystem Hierarchy Standard (FHS)**, qui définit le rôle de chaque répertoire sous la racine `/`. Connaître ces répertoires spéciaux est indispensable pour localiser rapidement les fichiers de configuration, les données temporaires ou les logiciels installés.

| Répertoire | Rôle |
|---|---|
| `/etc` | Fichiers de configuration système (texte, non exécutables) |
| `/var` | Données variables : logs (`/var/log`), spool, caches |
| `/tmp` | Fichiers temporaires, effacés au redémarrage (souvent un `tmpfs` en RAM) |
| `/var/tmp` | Fichiers temporaires persistants entre redémarrages |
| `/opt` | Logiciels tiers optionnels, installés hors du package manager |
| `/usr` | Programmes et données partagées en lecture seule (`/usr/bin`, `/usr/share`) |
| `/home` | Répertoires personnels des utilisateurs |
| `/root` | Répertoire personnel du superutilisateur `root` |
| `/dev` | Fichiers spéciaux représentant les périphériques |
| `/proc` | Filesystem virtuel exposant l'état du kernel et des processus |
| `/sys` | Filesystem virtuel exposant les périphériques et pilotes (`sysfs`) |
| `/mnt`, `/media` | Points de montage temporaires (manuel / amovibles) |
| `/run` | Données runtime volatiles depuis le dernier boot (PID files, sockets) |

```console
$ ls -ld /etc /var /tmp /opt /proc /sys /dev
drwxr-xr-x 140 root root 12288 mars   3 09:12 /etc
drwxr-xr-x  13 root root  4096 mars   3 09:12 /var
drwxrwxrwt   9 root root  4096 mars   3 10:41 /tmp
drwxr-xr-x   2 root root  4096 janv.  1 00:00 /opt
dr-xr-xr-x 245 root root     0 mars   3 08:00 /proc
drwxr-xr-x  13 root root     0 mars   3 08:00 /sys
drwxr-xr-x  20 root root  3820 mars   3 10:41 /dev
```

## Fichiers temporaires et le sticky bit

`/tmp` doit être accessible en écriture à tous les utilisateurs, mais un utilisateur ne doit pas pouvoir supprimer les fichiers d'un autre. C'est le rôle du **sticky bit** : dans un répertoire qui le possède, seul le propriétaire d'un fichier (ou `root`) peut le renommer ou le supprimer.

```console
$ ls -ld /tmp
drwxrwxrwt 9 root root 4096 mars 3 10:41 /tmp
```

Le `t` final remplace le `x` des « others » et signale le sticky bit. On l'active avec :

```console
$ chmod +t /repertoire
$ chmod 1777 /repertoire
```

## Permissions spéciales : SUID et SGID

En plus des permissions classiques (`r`, `w`, `x`), deux bits spéciaux modifient le comportement d'un exécutable :

- **SUID** (`setuid`) : le programme s'exécute avec l'identité de son **propriétaire**, pas de l'utilisateur qui le lance. Symbole `s` à la place du `x` du propriétaire.
- **SGID** (`setgid`) : sur un exécutable, le programme s'exécute avec le **groupe propriétaire** ; sur un répertoire, tout nouveau fichier créé dedans hérite du groupe du répertoire (utile pour un travail collaboratif).

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 janv.  1 2024 /usr/bin/passwd
```

Ici, `passwd` a le SUID actif : n'importe quel utilisateur peut l'exécuter avec les privilèges de `root`, nécessaires pour modifier `/etc/shadow`.

```console
$ chmod u+s fichier      # active SUID
$ chmod g+s repertoire   # active SGID
$ chmod 4755 fichier     # SUID en notation numérique (4)
$ chmod 2775 repertoire  # SGID en notation numérique (2)
```

## Hard links et symbolic links

Chaque fichier est représenté sur le disque par un **inode**, qui stocke ses métadonnées (permissions, taille, dates, emplacement des données). Un nom de fichier dans un répertoire n'est qu'un pointeur vers un inode.

- **Hard link** : un second nom pointant vers le **même inode**. Les deux noms sont strictement équivalents ; supprimer l'un ne supprime pas les données tant qu'un autre lien existe. Impossible de créer un hard link vers un répertoire ni de traverser les limites d'un filesystem.
- **Symbolic link (symlink)** : un fichier à part, possédant son propre inode, qui contient simplement le **chemin** vers la cible. Si la cible est supprimée, le lien devient « cassé » (*dangling*).

```console
$ echo "contenu" > original.txt
$ ln original.txt hardlink.txt
$ ln -s original.txt symlink.txt

$ ls -li
1234567 -rw-r--r-- 2 user user  9 mars  3 11:00 hardlink.txt
1234567 -rw-r--r-- 2 user user  9 mars  3 11:00 original.txt
1234580 lrwxrwxrwx 1 user user 12 mars  3 11:00 symlink.txt -> original.txt
```

L'option `-i` de `ls` affiche le numéro d'inode : `original.txt` et `hardlink.txt` partagent le même inode (`1234567`) et affichent un compteur de liens à `2`. `symlink.txt` a un inode différent et un type `l` en début de ligne.

```console
$ rm original.txt
$ cat hardlink.txt
contenu
$ cat symlink.txt
cat: symlink.txt: Aucun fichier ou dossier de ce type
```

## Fichiers spéciaux de périphériques (`/dev`)

Sous Linux, « tout est fichier », y compris le matériel. `/dev` contient des fichiers spéciaux gérés par **udev**, qui les crée dynamiquement selon les périphériques détectés par le kernel.

- **Block devices** (`b`) : accès par blocs, avec mise en cache (disques, partitions).
- **Character devices** (`c`) : accès en flux continu, octet par octet (terminaux, souris).

```console
$ ls -l /dev/sda /dev/null /dev/tty1
brw-rw---- 1 root disk    8,   0 mars  3 08:00 /dev/sda
crw-rw-rw- 1 root root    1,   3 mars  3 08:00 /dev/null
crw--w---- 1 root tty     4,   1 mars  3 08:00 /dev/tty1
```

Les deux nombres après le groupe (`8, 0` ou `1, 3`) sont les **numéros majeur et mineur**, qui identifient le pilote et l'instance du périphérique auprès du kernel. `/dev/null` est un exemple classique : tout ce qui y est écrit est jeté (utile pour rediriger une sortie indésirable, `commande > /dev/null`).

## Filesystems virtuels `/proc` et `/sys`

`/proc` et `/sys` n'existent pas sur le disque : ils sont générés en mémoire par le kernel et donnent une vue en temps réel de l'état du système.

```console
$ cat /proc/cpuinfo | head -3
processor : 0
vendor_id : GenuineIntel
model name: Intel(R) Core(TM) i5-8250U CPU

$ cat /proc/meminfo | head -2
MemTotal:       16265432 kB
MemFree:         8123456 kB

$ ls /proc/1
cmdline  cwd  environ  exe  fd  maps  root  status  ...
```

Chaque processus a un sous-répertoire `/proc/<PID>` avec ses informations. `/sys` expose de façon structurée les périphériques et pilotes du kernel :

```console
$ cat /sys/class/net/eth0/address
52:54:00:12:34:56
```

## `/etc/passwd`, `/etc/shadow` et `/etc/group`

Ces trois fichiers stockent les comptes locaux du système.

```console
$ grep alice /etc/passwd
alice:x:1001:1001:Alice Martin:/home/alice:/bin/bash
```

Format : `login:password:UID:GID:commentaire:répertoire_personnel:shell`. Le `x` indique que le mot de passe chiffré est stocké dans `/etc/shadow`, lisible uniquement par `root` :

```console
$ sudo grep alice /etc/shadow
alice:$6$abcd...:19700:0:99999:7:::
```

`/etc/group` liste les groupes et leurs membres :

```console
$ grep sudo /etc/group
sudo:x:27:alice,bob
```

## Références

- LPI Learning Materials, 010-160, Topic 5.4 — https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- Filesystem Hierarchy Standard — https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html
- `man ln` — https://man7.org/linux/man-pages/man1/ln.1.html
- `man chmod` — https://man7.org/linux/man-pages/man1/chmod.1.html
- `man proc` — https://man7.org/linux/man-pages/man5/proc.5.html
- `man passwd` (format du fichier) — https://man7.org/linux/man-pages/man5/passwd.5.html