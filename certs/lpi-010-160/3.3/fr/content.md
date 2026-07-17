# 3.3 Turning Commands into a Script

## Introduction

Un **script shell** est un fichier texte contenant une séquence de commandes que le shell peut exécuter comme un seul programme. L'objectif de ce topic est de transformer une suite de commandes tapées manuellement dans le terminal en un fichier réutilisable, versionnable et automatisable. C'est la porte d'entrée du *scripting* sous Linux.

## Créer un script avec un éditeur de texte

On écrit un script avec n'importe quel éditeur (`nano`, `vim`, `vi`...). Par convention, le fichier porte l'extension `.sh`, bien que ce ne soit pas obligatoire sous Linux (contrairement à Windows, l'extension n'a pas de valeur fonctionnelle — c'est le contenu et les permissions qui comptent).

```bash
$ nano hello.sh
```

Contenu du fichier :

```bash
#!/bin/bash
echo "Hello, World!"
```

## Le shebang (`#!`)

La première ligne d'un script commence toujours par `#!` suivi du chemin absolu vers l'interpréteur à utiliser. C'est ce qu'on appelle le **shebang** (ou *hashbang*).

```bash
#!/bin/bash
```

Cela indique au noyau : « exécute ce fichier avec `/bin/bash` ». Sans shebang, le script sera exécuté par le shell courant (comportement parfois imprévisible selon le shell actif), donc il est fortement recommandé de toujours le spécifier.

Autres shebangs courants :

```bash
#!/bin/sh          # POSIX shell
#!/usr/bin/env bash # trouve bash via le PATH (plus portable)
```

Toute ligne commençant par `#` (autre que le shebang en première ligne) est un **commentaire** et est ignorée par l'interpréteur.

## Rendre le script exécutable

Un fichier script n'est exécutable que si le bit `x` (execute) est positionné. On utilise `chmod` :

```bash
$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 user user 34 Jul 12 10:00 hello.sh
```

## Exécuter le script

Il existe plusieurs façons d'exécuter un script :

```bash
$ ./hello.sh        # nécessite le bit +x et que le script soit dans le PATH ou référencé par chemin
Hello, World!

$ bash hello.sh      # exécute explicitement via bash, sans nécessiter +x
Hello, World!

$ sh hello.sh        # exécute via sh
Hello, World!
```

Le préfixe `./` est nécessaire si le répertoire courant n'est pas dans la variable `PATH` (ce qui est le cas par défaut sur la plupart des distributions, pour des raisons de sécurité).

## Variables

On déclare une variable **sans espace** autour du `=`, et on la lit avec le préfixe `$` :

```bash
#!/bin/bash
name="Alice"
echo "Bonjour, $name"
```

```
$ ./greet.sh
Bonjour, Alice
```

Attention : `name = "Alice"` (avec espaces) provoque une erreur, car le shell interprète `name` comme une commande.

Pour rendre une variable disponible aux processus enfants (sous-shells), on utilise `export` :

```bash
export EDITOR="vim"
```

## Paramètres positionnels

Un script peut recevoir des arguments depuis la ligne de commande. Ces arguments sont accessibles via des variables spéciales :

| Variable | Signification |
|---|---|
| `$0` | Nom du script |
| `$1`, `$2`, ... | Premier, deuxième argument, etc. |
| `$#` | Nombre d'arguments |
| `$@` | Tous les arguments (chacun séparé) |
| `$*` | Tous les arguments (comme une seule chaîne) |
| `$?` | Code de sortie de la dernière commande |
| `$$` | PID du script en cours |

Exemple :

```bash
#!/bin/bash
echo "Script : $0"
echo "Premier argument : $1"
echo "Nombre d'arguments : $#"
echo "Tous les arguments : $@"
```

```
$ ./args.sh foo bar baz
Script : ./args.sh
Premier argument : foo
Nombre d'arguments : 3
Tous les arguments : foo bar baz
```

## Substitution de commande

On peut capturer la sortie d'une commande dans une variable avec `$(...)` (syntaxe moderne) ou les backticks `` `...` `` (syntaxe historique) :

```bash
#!/bin/bash
today=$(date +%Y-%m-%d)
echo "Aujourd'hui : $today"
```

```
$ ./date.sh
Aujourd'hui : 2026-07-12
```

## Le code de sortie (`exit status`)

Chaque commande retourne un **code de sortie** (0 = succès, tout autre valeur entre 1 et 255 = échec), stocké dans `$?`.

```bash
$ ls /tmp
$ echo $?
0

$ ls /repertoire-inexistant
ls: cannot access '/repertoire-inexistant': No such file or directory
$ echo $?
2
```

Dans un script, on utilise `exit N` pour terminer avec un code précis :

```bash
#!/bin/bash
if [ -f "/etc/hostname" ]; then
    exit 0
else
    exit 1
fi
```

## Enchaîner des commandes : `;`, `&&`, `||`

| Opérateur | Comportement |
|---|---|
| `cmd1 ; cmd2` | Exécute `cmd2` après `cmd1`, quel que soit le résultat |
| `cmd1 && cmd2` | Exécute `cmd2` seulement si `cmd1` réussit (code 0) |
| `cmd1 \|\| cmd2` | Exécute `cmd2` seulement si `cmd1` échoue (code ≠ 0) |

```bash
$ mkdir /tmp/test && cd /tmp/test && echo "OK"
OK

$ cd /repertoire-inexistant || echo "échec du cd"
bash: cd: /repertoire-inexistant: No such file or directory
échec du cd
```

## Tests conditionnels : `if` et `test`

La commande `test` (ou sa forme équivalente `[ ]`) évalue une condition et retourne un code de sortie 0 (vrai) ou 1 (faux).

```bash
#!/bin/bash
if [ -f "/etc/passwd" ]; then
    echo "Le fichier existe"
else
    echo "Le fichier n'existe pas"
fi
```

Opérateurs de test fréquents :

| Test | Signification |
|---|---|
| `-f fichier` | le fichier existe et est régulier |
| `-d rép` | le répertoire existe |
| `-x fichier` | le fichier est exécutable |
| `-z chaîne` | la chaîne est vide |
| `"$a" = "$b"` | égalité de chaînes |
| `$a -eq $b` | égalité numérique |

Exemple avec des arguments :

```bash
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Usage: $0 <nom>"
    exit 1
fi
echo "Bonjour, $1"
```

```
$ ./check.sh
Usage: ./check.sh <nom>
$ ./check.sh Bob
Bonjour, Bob
```

## Boucles simples : `for`

```bash
#!/bin/bash
for fichier in *.txt; do
    echo "Traitement de $fichier"
done
```

```
$ ./loop.sh
Traitement de notes.txt
Traitement de rapport.txt
```

On peut aussi itérer sur les arguments du script :

```bash
#!/bin/bash
for arg in "$@"; do
    echo "Argument : $arg"
done
```

## Lire une entrée utilisateur : `read`

```bash
#!/bin/bash
read -p "Quel est votre nom ? " name
echo "Bienvenue, $name"
```

```
$ ./ask.sh
Quel est votre nom ? Léa
Bienvenue, Léa
```

## Exemple complet

```bash
#!/bin/bash
# Vérifie si un répertoire existe et compte ses fichiers

if [ $# -ne 1 ]; then
    echo "Usage: $0 <répertoire>"
    exit 1
fi

dir="$1"

if [ ! -d "$dir" ]; then
    echo "Erreur : $dir n'est pas un répertoire valide"
    exit 1
fi

count=$(ls "$dir" | wc -l)
echo "Le répertoire $dir contient $count élément(s)"
exit 0
```

```
$ chmod +x check_dir.sh
$ ./check_dir.sh /etc
Le répertoire /etc contient 214 élément(s)
$ echo $?
0
```

## Bonnes pratiques

- Toujours mettre les variables entre guillemets doubles (`"$var"`) pour éviter les problèmes de *word splitting* avec des noms contenant des espaces.
- Commencer chaque script par un shebang explicite.
- Utiliser `exit` avec un code cohérent pour signaler le succès ou l'échec à l'appelant (utile dans des pipelines ou d'autres scripts).
- Commenter les sections non triviales du script avec `#`.

## Références

- LPI Learning Materials — 010-160, 3.3 Turning Commands into a Script : https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- GNU Bash Reference Manual : https://www.gnu.org/software/bash/manual/bash.html
- GNU Coreutils — `test` invocation : https://www.gnu.org/software/coreutils/manual/html_node/test-invocation.html