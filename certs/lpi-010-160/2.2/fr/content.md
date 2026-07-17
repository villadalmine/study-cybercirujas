# Thème 2.2 : Using the Command Line to Get Help

## Introduction

Sur un système Linux, la documentation est intégrée au système lui-même : chaque commande, chaque fichier de configuration et chaque appel système possède (en principe) sa propre page de documentation consultable directement depuis le shell. Ce thème couvre les principaux outils permettant d'obtenir de l'aide en ligne de commande : `man`, `info`, `--help`, ainsi que la localisation de la documentation complémentaire dans `/usr/share/doc`.

## La commande `man`

`man` (*manual*) affiche les pages de manuel installées sur le système. C'est l'outil de référence le plus utilisé.

```
$ man ls
```

Ceci ouvre la page de manuel de `ls` dans un pager (généralement `less`). Navigation typique :

- `Espace` ou `Page Down` : page suivante
- `b` ou `Page Up` : page précédente
- `/motif` : rechercher *motif* vers l'avant
- `n` / `N` : occurrence suivante / précédente
- `q` : quitter

### Structure d'une page de manuel

Une page de manuel typique comporte plusieurs sections standard :

- **NAME** : nom de la commande et description en une ligne
- **SYNOPSIS** : syntaxe d'utilisation
- **DESCRIPTION** : explication détaillée
- **OPTIONS** : liste des options disponibles
- **EXAMPLES** : exemples d'utilisation
- **FILES** : fichiers associés
- **SEE ALSO** : références croisées vers d'autres pages
- **AUTHOR** / **BUGS** : informations complémentaires

### Les sections de `man`

Les pages de manuel sont organisées en sections numérotées, car un même nom peut désigner à la fois une commande shell et un appel système, par exemple :

| Section | Contenu |
|---|---|
| 1 | Commandes utilisateur exécutables |
| 2 | Appels système (*system calls*) |
| 3 | Fonctions de bibliothèque (*library calls*) |
| 4 | Fichiers spéciaux (généralement dans `/dev`) |
| 5 | Formats de fichiers et conventions |
| 6 | Jeux (*games*) |
| 7 | Divers (macros, conventions, protocoles) |
| 8 | Commandes d'administration système |

Pour choisir explicitement une section, on précise son numéro avant le nom :

```
$ man 5 passwd
```

Cela affiche la page décrivant le **format** du fichier `/etc/passwd`, alors que :

```
$ man 1 passwd
```

affiche la page de la **commande** `passwd` utilisée pour changer un mot de passe.

### Rechercher une page de manuel : `man -k` et `apropos`

Quand on ne connaît pas le nom exact d'une commande, on peut rechercher par mot-clé dans les descriptions (champ NAME) :

```
$ man -k partition
fdisk (8)            - manipulate disk partition table
parted (8)           - a partition manipulation program
partprobe (8)         - inform the OS of partition table changes
```

`apropos` fait exactement la même chose que `man -k` :

```
$ apropos partition
```

Ces deux commandes s'appuient sur une base de données (`mandb`), qu'il faut parfois régénérer avec `mandb` (en root) si des pages viennent d'être installées et n'apparaissent pas encore dans les recherches.

### Trouver la localisation d'un fichier avec `whereis`

`whereis` cherche l'exécutable, le code source et la page de manuel d'une commande :

```
$ whereis ls
ls: /usr/bin/ls /usr/share/man/man1/ls.1.gz
```

### Résumé en une ligne avec `whatis`

`whatis` affiche uniquement la description courte (ligne NAME) d'une commande, sans ouvrir la page complète :

```
$ whatis ls
ls (1)               - list directory contents
```

Si plusieurs pages existent pour un même nom (dans des sections différentes), `whatis` les liste toutes :

```
$ whatis passwd
passwd (1)           - update user's authentication tokens
passwd (5)           - password file
```

## L'option `--help`

La plupart des commandes GNU/Linux acceptent l'option `--help` (ou parfois `-h`), qui affiche un résumé rapide de la syntaxe et des options directement dans le terminal, sans passer par un pager :

```
$ ls --help
Usage: ls [OPTION]... [FILE]...
List information about the FILEs (the current directory by default).
...
  -a, --all                  do not ignore entries starting with .
  -l                         use a long listing format
...
```

C'est en général plus rapide que `man` pour un simple rappel de syntaxe, mais moins détaillé — pas d'exemples ni d'explications approfondies.

## La commande `info`

Le projet GNU fournit un système de documentation alternatif, plus riche et hypertextuel : `info`. Certains outils GNU (comme `tar`, `gcc`, `bash`) documentent en détail leurs fonctionnalités dans `info` plutôt que dans `man`.

```
$ info coreutils
```

Les pages `info` sont organisées en **nœuds** (*nodes*) navigables :

- `Espace` / `Backspace` : défiler dans le nœud
- `n` : nœud suivant (*next*)
- `p` : nœud précédent (*previous*)
- `u` : remonter d'un niveau (*up*)
- `Entrée` sur un lien souligné : suivre le lien
- `q` : quitter

Beaucoup de pages `man` de commandes GNU renvoient explicitement à `info` pour une documentation plus complète, via une note du type :

```
The full documentation for ls is maintained as a Texinfo manual.
If the info and ls programs are properly installed at your site,
the command
       info coreutils 'ls invocation'
should give you access to the complete manual.
```

## Documentation complémentaire dans `/usr/share/doc`

Chaque paquet installé dépose généralement de la documentation supplémentaire (README, changelogs, exemples de configuration, licences) dans un sous-répertoire de `/usr/share/doc` :

```
$ ls /usr/share/doc/bash/
CHANGES.gz  COPYING  README  README.Debian  changelog.Debian.gz
```

Cette documentation contient souvent des informations que les pages `man` n'abordent pas : notes de version, exemples de configuration avancée, avertissements spécifiques à la distribution.

## Quand utiliser quel outil ?

| Besoin | Outil recommandé |
|---|---|
| Rappel rapide de la syntaxe et des options | `commande --help` |
| Documentation complète et détaillée d'une commande | `man commande` |
| Ne pas connaître le nom exact de la commande | `man -k mot-clé` / `apropos mot-clé` |
| Résumé en une ligne | `whatis commande` |
| Localiser binaire + man page + sources | `whereis commande` |
| Documentation GNU hypertextuelle et détaillée | `info commande` |
| Notes spécifiques au paquet, exemples, changelog | `/usr/share/doc/<paquet>/` |

## Références

- LPI Learning Materials — 2.2 Using the Command Line to Get Help : https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- man-pages project (Linux man-pages documentation) : https://www.kernel.org/doc/man-pages/
- GNU Info documentation system : https://www.gnu.org/software/texinfo/manual/info/
- GNU Coreutils manual : https://www.gnu.org/software/coreutils/manual/