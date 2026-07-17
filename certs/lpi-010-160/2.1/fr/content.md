# 2.1 Command Line Basics

## Introduction : le shell

Sous Linux, le **shell** est le programme qui fait le lien entre l'utilisateur et le système d'exploitation. Il lit les commandes tapées au clavier, les interprète, demande au kernel de les exécuter, puis affiche le résultat. On parle d'**interpréteur de commandes** ou de **CLI** (*command line interface*), par opposition à la **GUI** (*graphical user interface*).

Le shell le plus répandu sur les distributions Linux est **Bash** (*Bourne Again Shell*), successeur libre du *Bourne Shell* (`sh`) historique d'Unix. D'autres shells existent — `zsh`, `ksh`, `csh`, `dash` — mais l'examen Linux Essentials se concentre sur Bash.

Quand vous ouvrez un terminal, le shell affiche une **invite de commande** (*prompt*) et attend votre saisie :

```
utilisateur@machine:~$
```

Le prompt donne généralement trois informations : le nom de l'utilisateur, le nom de la machine et le répertoire courant (`~` désigne le *home directory*). Le caractère final indique le type de session :

- `$` : utilisateur normal
- `#` : superutilisateur (**root**)

Une session shell est dite **interactive** quand l'utilisateur tape des commandes une par une. Le shell peut aussi exécuter des suites de commandes enregistrées dans un fichier : c'est un **shell script** (abordé dans le thème 3.3).

Pour savoir quel shell est en cours d'exécution, on peut consulter la variable `SHELL` :

```
$ echo $SHELL
/bin/bash
```

## La structure d'une commande

Une ligne de commande suit presque toujours la même syntaxe générale :

```
commande [options] [arguments]
```

Les trois parties sont séparées par des espaces :

1. **La commande** : le nom du programme ou de la fonctionnalité interne à exécuter (`ls`, `echo`, `cp`…).
2. **Les options** (aussi appelées *switches* ou *flags*) : elles modifient le comportement de la commande.
3. **Les arguments** : les objets sur lesquels la commande agit, le plus souvent des fichiers ou des répertoires.

Exemple avec `ls`, qui liste le contenu d'un répertoire :

```
$ ls
Documents  Images  Musique  notes.txt

$ ls -l /tmp
total 8
drwx------ 2 marie marie 4096 juil. 14 09:12 ssh-XXXXXX
-rw-r--r-- 1 marie marie  214 juil. 14 08:47 rapport.log
```

Dans la seconde commande, `-l` (*long listing*) est une option et `/tmp` est un argument.

### Options courtes et options longues

Les options existent sous deux formes :

- **Forme courte** : un tiret suivi d'une lettre, par exemple `-a`. Plusieurs options courtes peuvent être combinées : `ls -la` équivaut à `ls -l -a`.
- **Forme longue** : deux tirets suivis d'un mot, par exemple `--all`. Plus lisible, mais non combinable.

```
$ ls -a
.  ..  .bashrc  .profile  Documents  notes.txt

$ ls --all
.  ..  .bashrc  .profile  Documents  notes.txt
```

Ici `-a` et `--all` produisent le même résultat : afficher aussi les fichiers cachés (ceux dont le nom commence par un point).

### Commandes internes et externes

Le shell distingue deux types de commandes :

- Les **builtins** (commandes internes) : intégrées au shell lui-même, comme `cd`, `echo`, `export` ou `history`.
- Les **commandes externes** : des programmes stockés sous forme de fichiers exécutables sur le disque, comme `ls` (`/usr/bin/ls`) ou `cp`.

La commande `type` indique la nature d'une commande :

```
$ type echo
echo is a shell builtin

$ type ls
ls is /usr/bin/ls
```

La commande `which` cherche uniquement les exécutables externes dans le `PATH` :

```
$ which ls
/usr/bin/ls

$ which cd
$
```

`which cd` ne renvoie rien, car `cd` est un *builtin* et n'existe pas comme fichier sur le disque. C'est une nuance classique à l'examen : **`type` connaît les builtins, `which` non**.

### Enchaîner des commandes

Plusieurs commandes peuvent être écrites sur une même ligne, séparées par `;` :

```
$ cd /tmp ; ls
rapport.log
```

## Les variables

Une **variable** est un nom associé à une valeur, stockée en mémoire par le shell. On distingue deux catégories :

- Les **shell variables** (variables locales) : visibles uniquement dans le shell courant.
- Les **environment variables** (variables d'environnement) : transmises aux programmes lancés depuis ce shell (les *child processes*).

### Créer et lire une variable

L'affectation se fait avec `=`, **sans espaces** autour du signe :

```
$ salutation="Bonjour le monde"
$ echo $salutation
Bonjour le monde
```

Points importants :

- Pour lire la valeur, on préfixe le nom avec `$`.
- Les noms de variables sont sensibles à la casse (*case sensitive*) ; par convention, les variables d'environnement sont en MAJUSCULES.
- `salutation = "Bonjour"` (avec espaces) est une erreur : le shell croirait que `salutation` est une commande.

La commande `echo` affiche du texte ou le contenu de variables :

```
$ echo "L'utilisateur $USER travaille dans $PWD"
L'utilisateur marie travaille dans /home/marie
```

### Exporter une variable : export

Une variable locale n'est **pas** visible par les programmes lancés depuis le shell. Pour la transmettre, on utilise le builtin `export` :

```
$ editeur=nano
$ bash              # on lance un shell enfant
$ echo $editeur
                    # vide : la variable locale n'a pas été transmise
$ exit

$ export editeur
$ bash
$ echo $editeur
nano                # cette fois la variable est héritée
$ exit
```

On peut affecter et exporter en une seule étape :

```
$ export EDITOR=vim
```

### Afficher l'environnement : env

La commande `env` liste toutes les variables d'environnement du shell courant :

```
$ env
SHELL=/bin/bash
USER=marie
PWD=/home/marie
HOME=/home/marie
LANG=fr_FR.UTF-8
PATH=/usr/local/bin:/usr/bin:/bin
...
```

Quelques variables d'environnement importantes :

| Variable | Contenu |
|----------|---------|
| `HOME` | Le répertoire personnel de l'utilisateur |
| `USER` | Le nom de l'utilisateur connecté |
| `PWD` | Le répertoire de travail courant (*present working directory*) |
| `SHELL` | Le shell par défaut de l'utilisateur |
| `LANG` | La langue et l'encodage de la session |
| `PATH` | La liste des répertoires où chercher les exécutables |

Pour supprimer une variable, on utilise `unset` :

```
$ unset salutation
$ echo $salutation

$
```

## La variable PATH

Quand vous tapez `ls`, le shell doit trouver le fichier exécutable correspondant. Il ne parcourt pas tout le disque : il cherche uniquement dans les répertoires listés dans la variable **`PATH`**, dans l'ordre, séparés par des deux-points (`:`) :

```
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Le premier exécutable trouvé est utilisé. Si aucun répertoire du `PATH` ne contient la commande, le shell renvoie :

```
$ monprogramme
bash: monprogramme: command not found
```

C'est pourquoi un programme situé dans le répertoire courant doit être appelé avec un chemin explicite — le répertoire courant (`.`) n'est pas dans le `PATH` par défaut, pour des raisons de sécurité :

```
$ ./monprogramme
```

Pour ajouter un répertoire au `PATH` (par exemple `~/bin`), on étend la valeur existante :

```
$ export PATH=$PATH:$HOME/bin
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/marie/bin
```

Cette modification ne dure que le temps de la session ; pour la rendre permanente, on la place dans un fichier d'initialisation comme `~/.bashrc`.

## Le quoting

Le shell attribue une signification spéciale à de nombreux caractères : `$` (variables), `*` et `?` (*globbing*, thème 2.3), l'espace (séparateur d'arguments), `!` (historique), etc. Le **quoting** permet de contrôler si ces caractères sont interprétés ou pris littéralement. C'est un point fort de l'examen : il faut connaître les trois mécanismes.

### Les guillemets doubles (double quotes)

Les `"…"` suppriment la signification spéciale de la plupart des caractères, **mais conservent** l'expansion des variables (`$`), la substitution de commande et le backslash :

```
$ echo "Mon répertoire est $HOME et j'ai * fichiers"
Mon répertoire est /home/marie et j'ai * fichiers
```

Ici `$HOME` est remplacé par sa valeur, mais `*` reste littéral (sans guillemets, il aurait été remplacé par la liste des fichiers du répertoire).

Les guillemets sont indispensables pour manipuler des noms contenant des espaces :

```
$ mkdir "Mes documents"     # crée UN répertoire
$ mkdir Mes documents       # crée DEUX répertoires : "Mes" et "documents"
```

### Les guillemets simples (single quotes)

Les `'…'` suppriment la signification spéciale de **tous** les caractères, y compris `$` :

```
$ echo 'Mon répertoire est $HOME'
Mon répertoire est $HOME
```

La différence entre les deux types de guillemets est une question d'examen classique :

```
$ prix=100
$ echo "Le prix est $prix"
Le prix est 100
$ echo 'Le prix est $prix'
Le prix est $prix
```

### Le backslash (échappement)

Le caractère `\` (*escape character*) neutralise la signification spéciale du seul caractère qui le suit :

```
$ echo "Le fichier coûte \$100"
Le fichier coûte $100

$ touch mon\ fichier.txt      # crée "mon fichier.txt" (l'espace est échappé)
```

En fin de ligne, `\` permet de continuer une commande sur la ligne suivante :

```
$ echo "une commande très longue" \
> "qui continue ici"
une commande très longue qui continue ici
```

## L'historique des commandes : history

Bash enregistre les commandes tapées dans un historique, conservé en mémoire pendant la session puis écrit dans le fichier `~/.bash_history` à la déconnexion.

Le builtin `history` affiche la liste numérotée :

```
$ history
  495  ls -l /tmp
  496  echo $PATH
  497  export PATH=$PATH:$HOME/bin
  498  history
```

Manipulations utiles :

- **Flèches haut/bas** : naviguer dans les commandes précédentes.
- `!497` : réexécuter la commande numéro 497.
- `!!` : réexécuter la dernière commande (très utile après un oubli de `sudo` : `sudo !!`).
- `!echo` : réexécuter la dernière commande commençant par `echo`.
- **Ctrl+R** : recherche interactive dans l'historique (*reverse search*).
- `history -c` : effacer l'historique de la session en cours.

Le nombre de commandes conservées est contrôlé par les variables `HISTSIZE` (en mémoire) et `HISTFILESIZE` (dans le fichier) :

```
$ echo $HISTSIZE
1000
```

## Aides rapides à la saisie

Deux réflexes de productivité attendus d'un utilisateur de la ligne de commande :

- **Tab completion** : la touche Tabulation complète automatiquement les noms de commandes et de fichiers. Deux appuis successifs affichent toutes les possibilités.
- **Ctrl+C** : interrompt la commande en cours d'exécution.
- **Ctrl+L** ou `clear` : efface l'écran du terminal.

```
$ ls Doc<Tab>
$ ls Documents/
```

## Points clés pour l'examen

- Syntaxe générale : `commande [options] [arguments]` ; options courtes (`-a`, combinables) vs longues (`--all`).
- `type` identifie builtins et commandes externes ; `which` ne trouve que les exécutables du `PATH`.
- Affectation de variable sans espaces (`var=valeur`) ; lecture avec `$var` ; `export` la transmet aux processus enfants ; `env` liste l'environnement.
- `PATH` détermine où le shell cherche les commandes, dans l'ordre des répertoires listés.
- Quoting : `"…"` conserve l'expansion de `$`, `'…'` rend tout littéral, `\` échappe un seul caractère.
- `history`, `!!`, `!n` et Ctrl+R pour réutiliser les commandes précédentes.

## Références

- LPI Learning Materials — Objectif 2.1, *Command Line Basics* : https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- GNU Bash Reference Manual : https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash Reference Manual — *Quoting* : https://www.gnu.org/software/bash/manual/html_node/Quoting.html
- GNU Bash Reference Manual — *Bash History Facilities* : https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html
- GNU Coreutils Manual (`ls`, `echo`, etc.) : https://www.gnu.org/software/coreutils/manual/coreutils.html
- Objectifs officiels de l'examen 010-160 : https://www.lpi.org/our-certifications/exam-010-objectives/