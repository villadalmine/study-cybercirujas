# 2.3 Using Directories and Listing Files

## Introduction

Ce topic couvre les bases de la navigation dans le filesystem Linux : comprendre l'arborescence des répertoires (**directory tree**), distinguer les **absolute paths** des **relative paths**, lister le contenu des répertoires, afficher les **hidden files**, et créer/supprimer des répertoires. Ce sont des compétences quotidiennes indispensables pour tout utilisateur ou administrateur Linux.

## L'arborescence des répertoires

Linux organise tous les fichiers dans une seule arborescence hiérarchique, dont la racine (**root directory**) est notée `/`. Il n'y a pas de notion de lettres de lecteur comme sous Windows (`C:`, `D:`) : tout — disques, partitions, périphériques — est monté quelque part sous `/`.

Chaque utilisateur possède un **home directory**, l'endroit où il stocke ses fichiers personnels et sa configuration :

- Pour un utilisateur normal, le home directory est généralement `/home/<username>` (par exemple `/home/alice`).
- Pour le **superuser** (`root`), le home directory est `/root`, situé directement sous la racine et non sous `/home`.

```
$ echo $HOME
/home/alice
```

## Absolute paths et relative paths

Un **absolute path** décrit l'emplacement d'un fichier ou répertoire en partant toujours de la racine `/`. Il commence donc toujours par `/` et fonctionne quel que soit le répertoire courant.

```
$ ls /var/log/syslog
```

Un **relative path** décrit un emplacement par rapport au répertoire courant (**current working directory**). Il ne commence pas par `/`.

```
$ pwd
/home/alice
$ ls Documents/rapport.txt
```

Ici `Documents/rapport.txt` est interprété comme `/home/alice/Documents/rapport.txt`.

### Notations spéciales

| Notation | Signification |
|---|---|
| `.` | le répertoire courant |
| `..` | le répertoire parent |
| `/` | la racine (root directory), ou séparateur de composants de path |
| `~` | le home directory de l'utilisateur courant |
| `~user` | le home directory de l'utilisateur `user` |
| `-` | le répertoire précédent (previous working directory), utilisable avec `cd` |

Exemples :

```
$ cd ..          # remonte d'un niveau
$ cd ../..       # remonte de deux niveaux
$ cd ~           # va au home directory de l'utilisateur courant
$ cd ~bob        # va au home directory de bob
$ cd -           # retourne au répertoire précédent
```

## Naviguer : `pwd` et `cd`

`pwd` (**print working directory**) affiche l'absolute path du répertoire courant.

```
$ pwd
/home/alice/Documents
```

`cd` (**change directory**) change le répertoire courant. Sans argument, `cd` ramène au home directory.

```
$ cd /var/log
$ pwd
/var/log
$ cd
$ pwd
/home/alice
```

Combiner `cd` avec un relative path :

```
$ pwd
/home/alice
$ cd Documents/rapports
$ pwd
/home/alice/Documents/rapports
```

## Lister le contenu : `ls`

La commande `ls` liste le contenu d'un répertoire (par défaut, le répertoire courant).

```
$ ls
Documents  Downloads  Images  notes.txt
```

### Options principales de `ls`

| Option | Effet |
|---|---|
| `-a` | affiche tous les fichiers, y compris les **hidden files** (`.` et `..` inclus) |
| `-A` | comme `-a` mais sans afficher `.` ni `..` |
| `-d` | affiche l'entrée d'un répertoire lui-même plutôt que son contenu |
| `-F` | ajoute un indicateur au nom (`/` pour un répertoire, `*` pour un exécutable, `@` pour un symbolic link) |
| `-h` | affiche les tailles en format lisible par un humain (**human-readable**, ex. `1.2M`) avec `-l` |
| `-l` | format long : permissions, owner, group, taille, date de modification |
| `-r` | inverse l'ordre du tri (**reverse**) |
| `-R` | liste récursivement (**recursive**) tous les sous-répertoires |
| `-S` | trie par taille (**size**), du plus grand au plus petit |
| `-t` | trie par date de modification (**time**), du plus récent au plus ancien |

### Fichiers cachés (hidden files)

Sous Linux, un fichier ou répertoire dont le nom commence par un point `.` est un **hidden file** : il n'apparaît pas avec un `ls` simple.

```
$ ls
Documents  Downloads  notes.txt

$ ls -a
.  ..  .bash_history  .bashrc  .config  .profile  Documents  Downloads  notes.txt
```

Le fichier `.bashrc`, présent dans le home directory, est un exemple classique de hidden file : il contient la configuration du shell `bash` (aliases, variables, prompt) exécutée à chaque ouverture d'un interactive shell.

```
$ cat ~/.bashrc | head -3
# ~/.bashrc: executed by bash for non-login shells
alias ll='ls -l'
export PATH=$PATH:/opt/tools/bin
```

### Format long (`-l`)

```
$ ls -l /etc/hostname /etc
-rw-r--r-- 1 root root   12 Feb 20 09:15 /etc/hostname

$ ls -l
total 24
drwxr-xr-x 2 alice alice 4096 Mar  3 10:22 Documents
drwxr-xr-x 2 alice alice 4096 Feb 28 18:04 Downloads
-rw-r--r-- 1 alice alice  512 Mar  3 09:01 notes.txt
```

Le premier caractère de chaque ligne indique le type d'entrée : `d` pour un directory, `-` pour un fichier régulier, `l` pour un symbolic link.

### `-F` : distinguer les types d'entrées

```
$ ls -F
Documents/  Downloads/  notes.txt  script.sh*  link_to_data@
```

### `-h` : tailles lisibles

```
$ ls -lh /var/log
-rw-r----- 1 root adm 3.2M Mar 10 08:15 syslog
-rw-r----- 1 root adm  128K Mar 10 07:00 auth.log
```

### `-d` : afficher le répertoire lui-même

```
$ ls -ld Documents
drwxr-xr-x 2 alice alice 4096 Mar  3 10:22 Documents
```

Sans `-d`, `ls Documents` afficherait le contenu de `Documents` plutôt que son entrée propre.

### `-R` : listing récursif

```
$ ls -R Documents
Documents:
rapports  notes.txt

Documents/rapports:
2024  2025
```

### `-S` et `-t` : trier par taille ou par date

```
$ ls -lS /var/log | head -3
total 1204
-rw-r----- 1 root adm 3.2M Mar 10 08:15 syslog
-rw-r----- 1 root adm  512K Mar  9 22:00 kern.log

$ ls -lt /var/log | head -3
total 1204
-rw-r----- 1 root adm 3.2M Mar 10 08:15 syslog
-rw-r----- 1 root adm  128K Mar 10 07:00 auth.log
```

`-r` combiné avec `-t` ou `-S` inverse l'ordre :

```
$ ls -ltr /var/log | head -3
```

## Créer et supprimer des répertoires : `mkdir` et `rmdir`

`mkdir` (**make directory**) crée un nouveau répertoire.

```
$ mkdir projet
$ ls
projet
```

L'option `-p` (**parents**) crée automatiquement tous les répertoires parents nécessaires, sans erreur s'ils existent déjà :

```
$ mkdir -p projets/2025/rapports
$ ls -R projets
projets:
2025

projets/2025:
rapports
```

`rmdir` (**remove directory**) supprime un répertoire, mais uniquement s'il est vide.

```
$ rmdir projet
$ ls
$ rmdir projets
rmdir: failed to remove 'projets': Directory not empty
```

Pour supprimer un répertoire non vide avec son contenu, on utilise `rm -r` (voir topic 2.4), car `rmdir` refuse volontairement de le faire, ce qui protège contre les suppressions accidentelles.

## Résumé

- L'ensemble du filesystem forme une seule arborescence enracinée à `/`.
- Chaque utilisateur a un home directory (`/home/<user>`, ou `/root` pour root), accessible via `~` ou `cd` sans argument.
- Un absolute path commence par `/` ; un relative path est interprété depuis le répertoire courant.
- `pwd` affiche le répertoire courant, `cd` permet de naviguer.
- `ls` liste le contenu d'un répertoire ; ses options (`-a`, `-l`, `-F`, `-h`, `-R`, `-S`, `-t`, `-r`, `-d`) modifient l'affichage et le tri.
- Les hidden files (noms commençant par `.`) comme `.bashrc` ne sont visibles qu'avec `ls -a`.
- `mkdir` crée des répertoires (`-p` pour créer les parents), `rmdir` en supprime, mais seulement s'ils sont vides.

## Références

- LPI Learning Materials — Topic 2.3: Using Directories and Listing Files : https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual — `ls` invocation : https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- Linux man-pages — `ls(1)` : https://man7.org/linux/man-pages/man1/ls.1.html
- Linux man-pages — `cd` (Bash builtin), `pwd(1)` : https://man7.org/linux/man-pages/man1/pwd.1.html
- Linux man-pages — `mkdir(1)` : https://man7.org/linux/man-pages/man1/mkdir.1.html
- Linux man-pages — `rmdir(1)` : https://man7.org/linux/man-pages/man1/rmdir.1.html
- Filesystem Hierarchy Standard (FHS) : https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html