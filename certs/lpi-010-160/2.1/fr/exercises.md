# Exercices guidés — 2.1 Command Line Basics

> Certification : LPI Linux Essentials (010-160, version 1.6) — Poids : 3
> Référence : [LPI Learning Materials 2.1](https://learning.lpi.org/en/learning-materials/010-160/2/2.1/)

Ces exercices se font dans un **terminal** avec le shell **Bash**. Ouvrez une session avant de commencer.

---

## Exercice 1 — Découvrir son shell et la structure d'une commande

1. Ouvrez un terminal et affichez le shell que vous utilisez actuellement :
   ```bash
   echo $SHELL
   ```
2. Tapez maintenant une commande simple, sans rien d'autre :
   ```bash
   ls
   ```
3. Ajoutez une **option** (courte) à la commande :
   ```bash
   ls -l
   ```
4. Ajoutez une option **longue**, équivalente à une option courte :
   ```bash
   ls -a
   ls --all
   ```
5. Ajoutez un **argument** pour préciser sur quoi la commande travaille :
   ```bash
   ls -l /tmp
   ```
6. Combinez plusieurs options courtes en une seule :
   ```bash
   ls -al /tmp
   ```

**Questions :**

- **Q1.1** — Dans la commande `ls -l /tmp`, identifiez les trois parties : la commande, l'option et l'argument.
- **Q1.2** — Quelle est la différence de syntaxe entre une option courte et une option longue ?
- **Q1.3** — `ls -a -l` et `ls -al` produisent-elles le même résultat ? Pourquoi ?

---

## Exercice 2 — Le type d'une commande avec `type`

1. Vérifiez la nature de quelques commandes :
   ```bash
   type echo
   type cd
   type ls
   ```
2. Observez les réponses : certaines commandes sont des **shell builtins**, d'autres sont des programmes externes situés dans un répertoire du système.
3. Comparez avec :
   ```bash
   type type
   ```

**Questions :**

- **Q2.1** — Quelle est la différence entre un **shell builtin** et un programme externe ?
- **Q2.2** — D'après la sortie de `type ls`, où se trouve le programme `ls` sur votre système ?
- **Q2.3** — Pourquoi `cd` doit-il obligatoirement être un **builtin** et non un programme externe ? (Question de réflexion — pensez à ce que `cd` modifie.)

---

## Exercice 3 — Les variables du shell

1. Créez une variable locale et affichez-la :
   ```bash
   annee=2026
   echo $annee
   ```
   ⚠️ Attention : pas d'espaces autour du `=`.
2. Essayez volontairement avec des espaces pour voir l'erreur :
   ```bash
   annee = 2026
   ```
3. Créez une variable contenant du texte :
   ```bash
   salutation="Bonjour le monde"
   echo $salutation
   ```
4. Ouvrez un **sous-shell** et vérifiez si la variable y existe :
   ```bash
   bash
   echo $salutation
   exit
   ```
5. Exportez maintenant la variable comme **environment variable** et refaites le test :
   ```bash
   export salutation
   bash
   echo $salutation
   exit
   ```
6. Vous pouvez aussi créer et exporter en une seule ligne :
   ```bash
   export projet="Linux Essentials"
   ```

**Questions :**

- **Q3.1** — Pourquoi la commande de l'étape 2 échoue-t-elle ? Comment le shell l'interprète-t-il ?
- **Q3.2** — À l'étape 4, la variable `salutation` était vide dans le sous-shell. À l'étape 5, elle était visible. Qu'est-ce qui a changé ?
- **Q3.3** — Quel caractère faut-il placer devant le nom d'une variable pour lire son contenu ?

---

## Exercice 4 — La variable `PATH`

1. Affichez le contenu de la variable **PATH** :
   ```bash
   echo $PATH
   ```
2. Observez la sortie : c'est une liste de répertoires séparés par des deux-points (`:`).
3. Lancez une commande avec son chemin complet, puis sans :
   ```bash
   /usr/bin/ls
   ls
   ```
4. Essayez de lancer une commande qui n'existe dans aucun répertoire du `PATH` :
   ```bash
   macommande
   ```
5. Ajoutez temporairement un répertoire au `PATH` (sans écraser l'existant) :
   ```bash
   export PATH=$PATH:/opt/outils
   echo $PATH
   ```

**Questions :**

- **Q4.1** — À quoi sert la variable **PATH** ?
- **Q4.2** — Que se passe-t-il quand vous tapez une commande qui ne se trouve dans aucun répertoire listé dans le `PATH` ?
- **Q4.3** — À l'étape 5, pourquoi écrit-on `PATH=$PATH:/opt/outils` et pas simplement `PATH=/opt/outils` ?
- **Q4.4** — Cette modification du `PATH` survivra-t-elle à la fermeture du terminal ?

---

## Exercice 5 — Le quoting : guillemets doubles, simples et backslash

1. Affichez une phrase contenant une variable, avec des **double quotes** :
   ```bash
   utilisateur=$USER
   echo "Je suis connecté en tant que $utilisateur"
   ```
2. Refaites la même chose avec des **single quotes** :
   ```bash
   echo 'Je suis connecté en tant que $utilisateur'
   ```
3. Comparez les deux sorties. Testez aussi l'effet sur une commande substituée... euh, sur un caractère spécial comme `*` :
   ```bash
   echo *
   echo "*"
   ```
4. Protégez un seul caractère avec un **backslash** (`\`) :
   ```bash
   echo Le prix est de 5\$ environ
   echo "Le symbole \$HOME ne sera pas remplacé"
   ```
5. Créez une variable dont la valeur contient des espaces — sans quoting, ça échoue :
   ```bash
   message=Bonjour tout le monde
   message="Bonjour tout le monde"
   echo $message
   ```

**Questions :**

- **Q5.1** — Quelle est la différence de comportement entre les **double quotes** (`"`) et les **single quotes** (`'`) vis-à-vis des variables ?
- **Q5.2** — À l'étape 3, pourquoi `echo *` n'affiche-t-il pas un astérisque ? Qu'affiche-t-il à la place ?
- **Q5.3** — Que fait le **backslash** (`\`) devant un caractère spécial ?
- **Q5.4** — Pourquoi la première commande de l'étape 5 provoque-t-elle une erreur ?

---

## Exercice 6 — L'historique des commandes avec `history`

1. Affichez l'historique de vos commandes :
   ```bash
   history
   ```
2. Réexécutez la dernière commande :
   ```bash
   !!
   ```
3. Réexécutez une commande précise par son numéro (remplacez `42` par un numéro visible dans votre historique) :
   ```bash
   !42
   ```
4. Utilisez les flèches **haut** et **bas** du clavier pour naviguer dans l'historique, puis **Ctrl+R** pour faire une recherche interactive : tapez `echo` et observez.
5. Affichez le fichier où Bash conserve l'historique entre les sessions :
   ```bash
   echo $HISTFILE
   ```

**Questions :**

- **Q6.1** — Que fait la commande `!!` ?
- **Q6.2** — Dans quel fichier l'historique est-il sauvegardé par défaut pour l'utilisateur courant ?
- **Q6.3** — Quel raccourci clavier permet de rechercher interactivement dans l'historique ?

---

## Réponses

<details>
<summary>Cliquez pour afficher les réponses</summary>

### Exercice 1

- **Q1.1** — `ls` est la **commande**, `-l` est l'**option** (elle modifie le comportement : affichage au format long), `/tmp` est l'**argument** (la cible sur laquelle la commande agit).
- **Q1.2** — Une option courte commence par un seul tiret et une seule lettre (`-a`) ; une option longue commence par deux tirets et un mot complet (`--all`). Les options longues sont plus lisibles, les courtes plus rapides à taper.
- **Q1.3** — Oui, le résultat est identique : les options courtes peuvent être regroupées derrière un seul tiret. `-al` équivaut à `-a -l`.

### Exercice 2

- **Q2.1** — Un **shell builtin** est une fonctionnalité intégrée directement dans le shell (Bash) ; un programme externe est un fichier exécutable stocké sur le disque (par exemple dans `/usr/bin`) que le shell doit localiser puis lancer.
- **Q2.2** — `type ls` indique le chemin du programme, généralement `/usr/bin/ls` (ou `/bin/ls` selon la distribution). Sur certains systèmes, `type` peut aussi signaler que `ls` est un **alias** (par exemple `ls --color=auto`).
- **Q2.3** — `cd` change le répertoire courant **du shell lui-même**. Un programme externe s'exécute dans un processus séparé : il pourrait changer son propre répertoire, mais pas celui du shell qui l'a lancé. C'est pourquoi `cd` doit être un builtin.

### Exercice 3

- **Q3.1** — Avec des espaces, Bash interprète `annee` comme une **commande** à exécuter, avec `=` et `2026` comme arguments. Comme aucune commande `annee` n'existe, on obtient une erreur du type `command not found`.
- **Q3.2** — La commande `export` a transformé la variable locale en **environment variable** : elle est désormais transmise aux processus enfants, y compris le sous-shell lancé avec `bash`.
- **Q3.3** — Le signe dollar : `$`. On écrit `$salutation` (ou `${salutation}`) pour lire la valeur, mais `salutation=...` (sans `$`) pour l'affecter.

### Exercice 4

- **Q4.1** — **PATH** contient la liste des répertoires où le shell cherche les programmes quand on tape une commande sans indiquer son chemin complet. Les répertoires sont parcourus dans l'ordre, de gauche à droite.
- **Q4.2** — Le shell renvoie une erreur `command not found`, car il n'a trouvé le programme dans aucun des répertoires listés.
- **Q4.3** — `$PATH:` conserve la valeur existante et **ajoute** le nouveau répertoire à la fin. Écrire `PATH=/opt/outils` écraserait toute la liste : la plupart des commandes habituelles (`ls`, `cp`…) deviendraient introuvables.
- **Q4.4** — Non. La modification ne vaut que pour la session en cours. Pour la rendre permanente, il faudrait l'ajouter à un fichier de configuration du shell comme `~/.bashrc` ou `~/.bash_profile`.

### Exercice 5

- **Q5.1** — Les **double quotes** laissent le shell remplacer les variables (`$utilisateur` devient sa valeur) tout en protégeant les espaces et la plupart des caractères spéciaux. Les **single quotes** protègent **tout** littéralement : `$utilisateur` s'affiche tel quel, sans substitution.
- **Q5.2** — Sans quoting, `*` est un caractère de **globbing** : le shell le remplace par la liste des fichiers du répertoire courant avant d'exécuter `echo`. Entre guillemets (`"*"`), le caractère est protégé et s'affiche littéralement.
- **Q5.3** — Le **backslash** neutralise (« échappe ») le caractère spécial qui le suit, et uniquement celui-là : `\$` affiche un dollar littéral au lieu de déclencher une substitution de variable.
- **Q5.4** — Sans guillemets, le shell coupe la ligne sur les espaces : il affecte `Bonjour` à `message`, puis tente d'exécuter `tout` comme une commande avec `le monde` en arguments — d'où l'erreur. Les guillemets font de toute la phrase une seule valeur.

### Exercice 6

- **Q6.1** — `!!` réexécute la dernière commande de l'historique. C'est pratique, par exemple, pour relancer une commande précédée de `sudo` : `sudo !!`.
- **Q6.2** — Dans `~/.bash_history` (le chemin exact est donné par la variable `HISTFILE`). L'historique en mémoire y est écrit à la fermeture de la session.
- **Q6.3** — **Ctrl+R** lance la recherche incrémentale inversée (*reverse-i-search*) : on tape quelques lettres et Bash retrouve la commande la plus récente qui les contient.

</details>

---

**Sources :**
- LPI Learning Materials, Topic 2.1 — Command Line Basics : https://learning.lpi.org/en/learning-materials/010-160/2/2.1/