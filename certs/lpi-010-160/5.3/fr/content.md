# Managing File Permissions and Ownership

## Introduction

Sous Linux, chaque fichier et chaque répertoire possède un **owner** (utilisateur propriétaire), un **group** (groupe propriétaire), et un ensemble de permissions qui déterminent qui peut faire quoi. Ce modèle Discretionary Access Control (DAC) est simple mais fondamental : c'est la base de la sécurité d'un système multi-utilisateurs, et c'est un sujet incontournable de l'examen 010-160.

## Le modèle owner / group / others

Chaque fichier a trois catégories de « sujets » auxquels s'appliquent des permissions :

- **user (u)** : le owner du fichier.
- **group (g)** : le groupe associé au fichier.
- **others (o)** : tous les autres utilisateurs du système.

Et trois types de permissions possibles pour chaque catégorie :

- **read (r)** : lire le contenu.
- **write (w)** : modifier le contenu.
- **execute (x)** : exécuter le fichier (ou traverser un répertoire).

On visualise tout ça avec `ls -l` :

```console
$ ls -l notes.txt
-rw-r--r-- 1 alice devs 2048 Jul 12 09:14 notes.txt
```

Décomposition du champ de permissions `-rw-r--r--` :

| Position | Signification         | Valeur ici |
|----------|------------------------|------------|
| 1        | type de fichier (`-` fichier régulier, `d` directory, `l` symlink) | `-` |
| 2-4      | permissions **user**   | `rw-` |
| 5-7      | permissions **group**  | `r--` |
| 8-10     | permissions **others** | `r--` |

Ici, `alice` peut lire et écrire, le groupe `devs` peut seulement lire, et tout le monde peut seulement lire.

## Permissions sur les répertoires : une sémantique différente

Sur un directory, `r`, `w` et `x` ne signifient pas exactement la même chose que sur un fichier :

- **r** : lister le contenu du répertoire (`ls`).
- **w** : créer, supprimer ou renommer des entrées dans le répertoire — **indépendamment** des permissions du fichier lui-même. Un fichier en lecture seule peut être supprimé si son répertoire parent a `w` pour vous.
- **x** : « traverser » le répertoire, c'est-à-dire y entrer (`cd`) ou accéder aux fichiers qu'il contient via un chemin.

```console
$ ls -ld /home/alice/private
drwx------ 2 alice alice 4096 Jul 12 09:14 /home/alice/private
```

Sans `x`, même `cd private` échoue avec `Permission denied`, même si vous avez `r`.

## Notation octale

Chaque permission correspond à une valeur binaire, regroupée en un chiffre octal par catégorie :

| Permission | Valeur |
|------------|--------|
| read (r)   | 4      |
| write (w)  | 2      |
| execute (x)| 1      |

On additionne les valeurs pour chaque catégorie (user, group, others). Exemples courants :

| Octal | Symbolique   | Usage typique                          |
|-------|--------------|------------------------------------------|
| 644   | `rw-r--r--`  | fichier texte classique                  |
| 755   | `rwxr-xr-x`  | script ou binaire exécutable, répertoire |
| 700   | `rwx------`  | répertoire ou script privé               |
| 664   | `rw-rw-r--`  | fichier partagé en écriture dans un groupe |
| 600   | `rw-------`  | fichier sensible (clé privée, etc.)      |

## La commande `chmod`

`chmod` (**ch**ange **mod**e) modifie les permissions. Elle accepte deux syntaxes.

### Mode numérique (octal)

```console
$ chmod 755 deploy.sh
$ ls -l deploy.sh
-rwxr-xr-x 1 alice devs 512 Jul 12 09:20 deploy.sh
```

### Mode symbolique

Syntaxe : `chmod [ugoa][+-=][rwx] fichier`

```console
$ chmod u+x deploy.sh        # ajoute execute au owner
$ chmod g-w notes.txt        # retire write au group
$ chmod o=r notes.txt        # fixe others exactement à read
$ chmod a+x script.sh        # ajoute execute à tout le monde (a = all)
$ chmod u+rw,g+r,o-rwx secret.txt   # plusieurs changements en une commande
```

Le mode symbolique est pratique quand on veut **ajouter ou retirer** une permission précise sans toucher aux autres ; le mode numérique est plus rapide quand on connaît déjà la combinaison finale voulue.

### Options utiles

```console
$ chmod -R 755 scripts/       # applique récursivement à tout un répertoire
$ chmod --reference=modele.txt cible.txt   # copie les permissions d'un autre fichier
```

Attention avec `-R` sur des répertoires contenant à la fois des fichiers et des sous-dossiers : appliquer un seul mode numérique risque de retirer `x` à des fichiers qui en avaient besoin (scripts) ou de l'ajouter à des fichiers qui n'en ont pas besoin. Dans ce cas, `find` combiné à `chmod` est plus précis :

```console
$ find scripts/ -type d -exec chmod 755 {} \;
$ find scripts/ -type f -exec chmod 644 {} \;
```

## Changer la propriété : `chown` et `chgrp`

Seul **root** peut changer le owner d'un fichier ; un utilisateur ordinaire peut changer le group d'un fichier qui lui appartient, s'il est membre du groupe cible.

```console
$ sudo chown bob rapport.txt              # change le owner
$ sudo chown bob:devs rapport.txt         # change owner ET group
$ sudo chown :devs rapport.txt            # change seulement le group
$ chgrp devs rapport.txt                  # équivalent pour le group seul
$ sudo chown -R bob:devs /srv/app/        # récursif
```

Vérification :

```console
$ ls -l rapport.txt
-rw-r--r-- 1 bob devs 1024 Jul 12 09:30 rapport.txt
```

## `umask` : les permissions par défaut

Quand un fichier ou un répertoire est créé, ses permissions initiales ne sont pas arbitraires : elles résultent d'une valeur de départ à laquelle on **soustrait** le `umask`.

- Valeur de départ pour un fichier : `666` (`rw-rw-rw-`, jamais `x` par défaut).
- Valeur de départ pour un répertoire : `777` (`rwxrwxrwx`).

Le `umask` (souvent `022` par défaut) « masque » les bits correspondants :

```console
$ umask
0022
$ touch nouveau.txt
$ ls -l nouveau.txt
-rw-r--r-- 1 alice devs 0 Jul 12 09:35 nouveau.txt
$ mkdir nouveau_dossier
$ ls -ld nouveau_dossier
drwxr-xr-x 2 alice devs 4096 Jul 12 09:35 nouveau_dossier
```

Calcul : `666 - 022 = 644` pour le fichier, `777 - 022 = 755` pour le répertoire.

Changer le `umask` pour la session courante :

```console
$ umask 077
$ touch confidentiel.txt
$ ls -l confidentiel.txt
-rw------- 1 alice devs 0 Jul 12 09:36 confidentiel.txt
```

Pour rendre un `umask` permanent, on l'ajoute typiquement dans `~/.bashrc` ou `/etc/profile` (configuration système), mais retenir la mécanique de calcul suffit pour l'examen.

## Points clés à retenir

- `ls -l` affiche type, owner, group, others dans cet ordre.
- Sur un directory, `w` contrôle la création/suppression d'entrées, `x` contrôle la traversée.
- `chmod` accepte le mode symbolique (`u+x`) et le mode numérique (`755`).
- `chown user:group` change owner et group ; seul root change le owner.
- `chgrp` change uniquement le group.
- `umask` définit ce qui est **retiré** des permissions par défaut (`666` fichiers, `777` répertoires) à la création.
- root (uid 0) contourne toutes les vérifications de permissions DAC.

## Références

- LPI Learning Materials — Topic 5.3, Managing File Permissions and Ownership : https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- `chmod(1)` — Linux man-pages : https://man7.org/linux/man-pages/man1/chmod.1.html
- `chown(1)` — Linux man-pages : https://man7.org/linux/man-pages/man1/chown.1.html
- `umask(1p)` — Linux man-pages (POSIX) : https://man7.org/linux/man-pages/man1/umask.1p.html
- GNU Coreutils Manual — File permissions : https://www.gnu.org/software/coreutils/manual/html_node/File-permissions.html