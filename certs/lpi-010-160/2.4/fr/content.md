# 2.4 Creating, Moving and Deleting Files

## Introduction

La gestion des fichiers en ligne de commande est une compétence fondamentale sous Linux. Ce chapitre couvre la création, la copie, le déplacement et la suppression de fichiers et de répertoires, l'usage des wildcards (globbing), la commande `find` pour localiser des fichiers selon des critères précis, ainsi que les utilitaires d'archivage `tar`, `cpio` et `dd`.

## Créer des fichiers et des répertoires

### `touch`

`touch` crée un fichier vide s'il n'existe pas, ou met à jour sa date de modification (mtime) s'il existe déjà.

```console
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 user user 0 Jul 13 10:02 notes.txt
```

Options utiles :

- `-t` : imposer un timestamp précis (`touch -t 202601011200 fichier`)
- `-a` : ne modifier que l'access time
- `-m` : ne modifier que le modification time

### `mkdir`

`mkdir` crée un répertoire.

```console
$ mkdir projet
```

Pour créer une arborescence complète en une seule commande, on utilise `-p` (parents), qui crée aussi les répertoires parents manquants sans erreur si le chemin existe déjà :

```console
$ mkdir -p projet/src/config
$ tree projet
projet
└── src
    └── config
```

`-v` (verbose) affiche chaque répertoire créé, utile en combinaison avec `-p` :

```console
$ mkdir -pv projet/docs/{fr,en}
mkdir: created directory 'projet/docs'
mkdir: created directory 'projet/docs/fr'
mkdir: created directory 'projet/docs/en'
```

## Copier des fichiers et des répertoires

### `cp`

```console
$ cp source.txt destination.txt
$ cp fichier.txt /tmp/
```

Options essentielles :

- `-r` (ou `-R`) : copie récursive, obligatoire pour copier un répertoire
- `-i` : mode interactif, demande confirmation avant d'écraser un fichier existant
- `-v` : verbose, affiche chaque copie effectuée
- `-p` : préserve les permissions, le propriétaire et les timestamps
- `-a` : mode archive, équivalent à `-dR --preserve=all` — préserve tout (permissions, liens symboliques, timestamps) et copie récursivement ; c'est l'option recommandée pour dupliquer une arborescence à l'identique

```console
$ cp -r projet/ projet_backup/
$ cp -av /etc/nginx /root/nginx_backup
```

Copier plusieurs fichiers vers un répertoire :

```console
$ cp fichier1.txt fichier2.txt fichier3.txt /tmp/backup/
```

## Déplacer et renommer : `mv`

`mv` sert à la fois à déplacer et à renommer, selon que la destination change de répertoire ou seulement de nom.

```console
$ mv notes.txt notes-2026.txt        # renommage
$ mv notes-2026.txt archives/         # déplacement
$ mv old_name.txt archives/new_name.txt   # déplacement + renommage
```

Options :

- `-i` : demande confirmation avant d'écraser
- `-v` : verbose
- `-n` : n'écrase jamais un fichier existant (no-clobber)

```console
$ mv -iv rapport.txt archives/
mv: overwrite 'archives/rapport.txt'? y
'rapport.txt' -> 'archives/rapport.txt'
```

## Supprimer des fichiers et des répertoires

### `rm`

```console
$ rm fichier.txt
```

Options :

- `-r` : suppression récursive, nécessaire pour un répertoire
- `-f` : force, ignore les fichiers inexistants et ne demande jamais confirmation
- `-i` : demande confirmation pour chaque fichier
- `-v` : verbose

```console
$ rm -r projet_backup/
$ rm -rf /tmp/cache/    # ⚠ suppression sans confirmation, irréversible
```

> **Attention** : `rm -rf` ne passe pas par la corbeille — les fichiers supprimés ne sont pas récupérables facilement. Toujours vérifier le chemin (surtout après un `cd` récent) avant d'exécuter cette commande, en particulier avec des variables ou des wildcards.

### `rmdir`

`rmdir` supprime un répertoire, mais uniquement s'il est **vide**.

```console
$ rmdir dossier_vide
$ rmdir dossier_plein
rmdir: failed to remove 'dossier_plein': Directory not empty
```

## Liens : `ln`

### Lien physique (hard link)

Un hard link est une deuxième entrée de répertoire pointant vers le même inode. Les deux noms sont équivalents ; supprimer l'un des deux ne supprime pas les données tant qu'il reste au moins un lien.

```console
$ ln fichier.txt fichier_hardlink.txt
$ ls -li fichier.txt fichier_hardlink.txt
123456 -rw-r--r-- 2 user user 0 Jul 13 10:10 fichier.txt
123456 -rw-r--r-- 2 user user 0 Jul 13 10:10 fichier_hardlink.txt
```

Le même numéro d'inode (`123456`) et un compteur de liens à `2` confirment qu'il s'agit du même contenu physique. Les hard links ne peuvent pas traverser des systèmes de fichiers différents et ne peuvent pas pointer vers un répertoire.

### Lien symbolique (symlink)

Un lien symbolique est un fichier spécial contenant le chemin vers une autre cible ; il peut traverser des filesystems et pointer vers un répertoire.

```console
$ ln -s /var/log/nginx/access.log access.log
$ ls -l access.log
lrwxrwxrwx 1 user user 24 Jul 13 10:12 access.log -> /var/log/nginx/access.log
```

Si le fichier cible est supprimé, le symlink devient un « lien mort » (broken link).

## Wildcards (globbing)

Le shell développe certains caractères spéciaux avant d'exécuter la commande :

| Motif | Signification |
|---|---|
| `*` | zéro ou plusieurs caractères quelconques |
| `?` | exactement un caractère |
| `[abc]` | un caractère parmi `a`, `b`, `c` |
| `[a-z]` | un caractère dans l'intervalle |
| `[!abc]` | un caractère qui n'est pas `a`, `b`, `c` |
| `{a,b,c}` | brace expansion : génère un mot pour chaque élément |

```console
$ ls *.txt
$ rm rapport?.log
$ cp fichier[1-3].txt /tmp/
$ mkdir -p site/{css,js,img}
```

## Localiser des fichiers avec `find`

`find` parcourt une arborescence et applique des tests et des actions.

```console
$ find /home/user -name "*.txt"
$ find . -type f              # uniquement des fichiers
$ find . -type d              # uniquement des répertoires
$ find /var/log -size +10M    # fichiers de plus de 10 Mo
$ find . -mtime -7            # modifiés il y a moins de 7 jours
$ find . -mmin -30            # modifiés il y a moins de 30 minutes
```

Combiner un test avec une action via `-exec` (l'expression `{}` représente le fichier trouvé, `\;` termine la commande) :

```console
$ find . -name "*.log" -exec rm {} \;
$ find . -type f -name "*.tmp" -exec chmod 644 {} \;
```

Supprimer directement les fichiers correspondants, sans passer par `-exec rm` :

```console
$ find /tmp -name "*.cache" -delete
```

## `xargs`

`xargs` construit et exécute des commandes à partir de l'entrée standard, en regroupant les arguments — plus efficace que `find -exec` quand un grand nombre de fichiers est concerné, car il évite de lancer une nouvelle commande par fichier.

```console
$ find . -name "*.bak" | xargs rm
$ find . -name "*.txt" -print0 | xargs -0 grep -l "TODO"
```

`-print0` / `xargs -0` séparent les noms par un octet nul plutôt qu'un espace ou un saut de ligne, ce qui évite les erreurs avec des noms de fichiers contenant des espaces.

## Identifier un type de fichier : `file`

`file` détermine la nature d'un fichier en examinant son contenu (magic bytes), indépendamment de son extension.

```console
$ file rapport.pdf
rapport.pdf: PDF document, version 1.4
$ file script.sh
script.sh: Bourne-Again shell script, ASCII text executable
```

## Archivage : `tar`

`tar` (tape archive) regroupe plusieurs fichiers en une seule archive, généralement combinée à une compression.

Options principales : `-c` (create), `-x` (extract), `-t` (list), `-v` (verbose), `-f` (fichier archive, toujours en dernier avant le nom du fichier).

Compression : `-z` (gzip, `.tar.gz`), `-j` (bzip2, `.tar.bz2`), `-J` (xz, `.tar.xz`).

```console
$ tar czvf archive.tar.gz projet/       # créer une archive gzip
$ tar xzvf archive.tar.gz               # extraire
$ tar tvf archive.tar.gz                # lister le contenu sans extraire
$ tar xzvf archive.tar.gz -C /tmp/dest  # extraire vers un autre répertoire
```

## `cpio`

`cpio` est un autre outil d'archivage, plus ancien que `tar`, qui lit la liste des fichiers à archiver depuis l'entrée standard (souvent produite par `find`).

```console
$ find . -name "*.conf" | cpio -ov > config.cpio    # créer une archive
$ cpio -idv < config.cpio                            # extraire (-i import, -d crée les répertoires)
```

## `dd`

`dd` copie des blocs de données brutes entre un fichier source et une destination, utile pour créer des images disque ou copier un périphérique bloc par bloc.

```console
$ dd if=/dev/sdb of=disque.img bs=4M status=progress
```

`if` (input file), `of` (output file), `bs` (block size). `dd` opère au niveau bloc sans interprétation du contenu, ce qui en fait un outil puissant mais dangereux : une erreur sur `of=` peut écraser un disque entier de façon irréversible. Toujours vérifier le périphérique cible (`lsblk`) avant exécution.

## Références

- LPI Learning Materials — Topic 2.4 : https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- GNU Coreutils Manual (cp, mv, rm, mkdir, touch, ln) : https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU Findutils Manual (find, xargs) : https://www.gnu.org/software/findutils/manual/html_mono/find.html
- GNU Tar Manual : https://www.gnu.org/software/tar/manual/tar.html
- man7.org — dd(1) : https://man7.org/linux/man-pages/man1/dd.1.html
- man7.org — cpio(1) : https://man7.org/linux/man-pages/man1/cpio.1.html
- man7.org — file(1) : https://man7.org/linux/man-pages/man1/file.1.html