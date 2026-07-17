# Exercices guidés — Topic 3.3 : Turning Commands into a Script

**Certification :** LPI Linux Essentials (010-160, v1.6)
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/3/3.3/

---

## Partie 1 — Du prompt au script

### Étape 1 : Reproduire une séquence de commandes au prompt

Exécutez ces commandes une par une dans votre terminal, comme si vous prépariez un rapport système :

```bash
echo "=== Rapport système ==="
date
whoami
echo "Espace disque :"
df -h /
```

**Questions :**
1. Que se passe-t-il si vous fermez le terminal après avoir tapé ces commandes ? Pouvez-vous les relancer facilement demain ?
2. Quel est l'intérêt de regrouper ces commandes dans un fichier plutôt que de les retaper à chaque fois ?

---

### Étape 2 : Créer le fichier script

Avec un éditeur de texte (`nano`, `vim`, etc.), créez un fichier nommé `rapport.sh` contenant les mêmes commandes :

```bash
nano rapport.sh
```

Contenu du fichier :

```bash
#!/bin/bash
echo "=== Rapport système ==="
date
whoami
echo "Espace disque :"
df -h /
```

**Questions :**
1. À quoi sert la première ligne `#!/bin/bash` ? Que signifie l'acronyme *shebang* pour cette ligne ?
2. Que se passerait-il si cette ligne pointait vers `#!/bin/sh` au lieu de `#!/bin/bash` ? Est-ce que cela changerait toujours le comportement du script ?

---

### Étape 3 : Tenter d'exécuter le script directement

Essayez d'exécuter le script sans lui donner de permissions particulières :

```bash
./rapport.sh
```

**Questions :**
1. Quel message d'erreur obtenez-vous, et que signifie-t-il en termes de permissions ?
2. Quelle commande utiliseriez-vous pour afficher les permissions actuelles du fichier `rapport.sh` ?

---

### Étape 4 : Rendre le script exécutable

Modifiez les permissions du fichier pour permettre son exécution :

```bash
chmod +x rapport.sh
ls -l rapport.sh
```

Puis exécutez-le à nouveau :

```bash
./rapport.sh
```

**Questions :**
1. Quel bit de permission a été ajouté par `chmod +x`, et pour quelles catégories d'utilisateurs (owner, group, other) ?
2. Quelle est la différence entre exécuter `./rapport.sh` et `bash rapport.sh` ? Le deuxième a-t-il besoin du bit exécutable ?

---

## Partie 2 — Variables et arguments

### Étape 5 : Utiliser des variables

Modifiez `rapport.sh` pour stocker le résultat d'une commande dans une variable :

```bash
#!/bin/bash
UTILISATEUR=$(whoami)
DATE_ACTUELLE=$(date +%Y-%m-%d)
echo "Rapport généré par $UTILISATEUR le $DATE_ACTUELLE"
```

Exécutez-le :

```bash
./rapport.sh
```

**Questions :**
1. Que fait la syntaxe `$(commande)` dans ce script ? Comment s'appelle ce mécanisme ?
2. Pourquoi écrit-on `$UTILISATEUR` avec un `$` pour *lire* la valeur, alors qu'on écrit `UTILISATEUR=...` sans `$` pour l'*assigner* ?

---

### Étape 6 : Passer des arguments au script

Créez un nouveau script `salutation.sh` :

```bash
#!/bin/bash
echo "Bonjour, $1 !"
echo "Ce script s'appelle $0"
echo "Vous avez fourni $# argument(s)."
```

Rendez-le exécutable et testez-le avec un argument :

```bash
chmod +x salutation.sh
./salutation.sh Marie
```

**Questions :**
1. Que représentent les variables spéciales `$0`, `$1` et `$#` dans ce script ?
2. Que s'afficherait pour `$2` si vous exécutiez `./salutation.sh Marie Dupont` ? Et pour `$#` ?

---

## Partie 3 — Logique conditionnelle et sortie

### Étape 7 : Ajouter une condition avec `if`

Modifiez `salutation.sh` pour vérifier qu'un argument a bien été fourni :

```bash
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Erreur : vous devez fournir un nom."
    exit 1
fi
echo "Bonjour, $1 !"
```

Testez les deux cas :

```bash
./salutation.sh
echo "Code de sortie : $?"

./salutation.sh Marie
echo "Code de sortie : $?"
```

**Questions :**
1. Que vérifie l'expression `[ $# -eq 0 ]` dans la condition `if` ?
2. Que signifie `exit 1` ici, et pourquoi utilise-t-on `$?` juste après pour l'observer ? Quelle convention Linux associe-t-on généralement à un code de sortie égal à `0` par opposition à une valeur non nulle ?

---

### Étape 8 : Boucler sur une liste avec `for`

Créez un script `fichiers.sh` qui liste et affiche des informations sur chaque fichier `.sh` du répertoire courant :

```bash
#!/bin/bash
for fichier in *.sh; do
    echo "Fichier : $fichier"
    wc -l "$fichier"
done
```

Rendez-le exécutable et exécutez-le :

```bash
chmod +x fichiers.sh
./fichiers.sh
```

**Questions :**
1. D'où viennent les valeurs successives prises par la variable `fichier` dans cette boucle `for` ? Quel mécanisme du shell (vu au topic 3.1/3.2) est responsable de l'expansion de `*.sh` ?
2. Pourquoi entoure-t-on `$fichier` de guillemets doubles (`"$fichier"`) dans l'appel à `wc -l` ? Que risquerait-il de se passer avec un nom de fichier contenant des espaces si on ne le faisait pas ?

---

## Partie 4 — Bonnes pratiques

### Étape 9 : Ajouter des commentaires

Ajoutez des commentaires explicatifs à `fichiers.sh` :

```bash
#!/bin/bash
# Ce script affiche le nombre de lignes de chaque script .sh du répertoire courant
for fichier in *.sh; do
    echo "Fichier : $fichier"
    wc -l "$fichier"   # wc -l compte les lignes
done
```

**Questions :**
1. Quel caractère introduit un commentaire en shell scripting, et jusqu'où s'étend-il sur la ligne ?
2. La première ligne `#!/bin/bash` commence aussi par `#`. Pourquoi n'est-elle pas traitée comme un simple commentaire par le système ?

---

### Étape 10 : Déboguer un script avec `bash -x`

Exécutez `fichiers.sh` en mode debug :

```bash
bash -x fichiers.sh
```

**Questions :**
1. Quelle différence observez-vous entre cette exécution et celle de l'étape 8 ? Que représente le symbole `+` affiché devant chaque ligne ?
2. Dans quel contexte l'option `-x` serait-elle particulièrement utile par rapport à une simple lecture du script ?

---

<details>
<summary>✅ Voir les réponses</summary>

**Étape 1**
1. Les commandes sont perdues (sauf si elles restent dans l'historique du shell via `history`) ; il faut les retaper une par une pour les relancer.
2. Regrouper les commandes dans un fichier permet de les réexécuter à l'identique, de les partager, de les versionner et d'automatiser une tâche répétitive sans erreur de frappe.

**Étape 2**
1. Le *shebang* (`#!`) indique au système quel interpréteur utiliser pour exécuter le fichier — ici `/bin/bash`. C'est ce qui permet de lancer le script comme un programme (`./rapport.sh`) plutôt que de devoir taper `bash rapport.sh`.
2. Avec `#!/bin/sh`, le script serait interprété par `sh` (qui sur beaucoup de distributions est un lien vers `dash`, un shell plus minimal que `bash`). Les fonctionnalités spécifiques à `bash` (comme certains tableaux ou `[[ ]]`) pourraient ne pas fonctionner ou provoquer des erreurs.

**Étape 3**
1. Le message typique est `Permission denied` (ou en français `Permission refusée`) car le fichier ne possède pas le bit d'exécution (`x`).
2. `ls -l rapport.sh` affiche les permissions actuelles, par exemple `-rw-r--r--`.

**Étape 4**
1. Le bit `x` (exécution) est ajouté. Sans préciser de catégorie, `chmod +x` l'ajoute pour *owner*, *group* et *other* (u, g, o).
2. `./rapport.sh` demande au shell d'exécuter le fichier directement, ce qui nécessite le bit exécutable et utilise l'interpréteur indiqué par le shebang. `bash rapport.sh` demande explicitement à `bash` de lire et interpréter le fichier comme un script : le bit exécutable n'est alors pas nécessaire, seul le droit de lecture (`r`) suffit.

**Étape 5**
1. `$(commande)` exécute la commande dans un sous-shell et remplace l'expression par sa sortie standard (*stdout*). Ce mécanisme s'appelle la *command substitution*.
2. La convention shell veut qu'on utilise `$` uniquement pour *déréférencer* (lire) la valeur d'une variable. Lors de l'assignation, `$` provoquerait une erreur de syntaxe car le shell interpréterait `$UTILISATEUR` comme une expansion de variable, pas comme un nom à définir.

**Étape 6**
1. `$0` contient le nom (ou chemin) du script tel qu'il a été invoqué ; `$1` contient le premier argument positionnel passé au script ; `$#` contient le nombre total d'arguments fournis.
2. `$2` afficherait `Dupont`, et `$#` afficherait `2`.

**Étape 7**
1. `[ $# -eq 0 ]` teste (via la commande `test`, ici sous sa forme `[ ]`) si le nombre d'arguments (`$#`) est égal (`-eq`) à zéro.
2. `exit 1` termine le script en renvoyant le code de sortie `1` au shell parent, récupérable via `$?`. Par convention Linux, un code de sortie `0` signifie que la commande/le script s'est terminé avec succès, tandis qu'une valeur non nulle indique une erreur (le code précis peut avoir une signification propre au script ou au programme).

**Étape 8**
1. Les valeurs proviennent de l'expansion des *glob patterns* (*filename/pathname expansion*) : `*.sh` est développé par le shell en la liste de tous les fichiers du répertoire courant se terminant par `.sh`, avant même que `for` ne commence à boucler.
2. Les guillemets empêchent le *word splitting* : sans eux, un nom de fichier contenant un espace (ex. `mon script.sh`) serait scindé en plusieurs arguments distincts (`mon` et `script.sh`), ce qui ferait échouer ou fausserait la commande `wc -l`.

**Étape 9**
1. Le caractère `#` introduit un commentaire ; tout ce qui suit `#` jusqu'à la fin de la ligne est ignoré par l'interpréteur.
2. La ligne `#!/bin/bash` n'est un commentaire que du point de vue strict de la syntaxe shell (elle est bien ignorée comme telle par `bash` lui-même) ; mais le noyau Linux traite spécialement les deux premiers octets `#!` d'un fichier exécutable pour déterminer l'interpréteur à utiliser, avant même que le contenu ne soit lu comme du shell. C'est une convention au niveau du système, pas du langage shell.

**Étape 10**
1. Le mode `-x` affiche chaque commande réellement exécutée (après expansion des variables et des glob patterns) précédée d'un `+`, avant de l'exécuter. C'est différent de l'exécution normale qui n'affiche que la sortie des commandes elles-mêmes.
2. L'option `-x` est utile pour déboguer un script qui produit un résultat inattendu : elle permet de voir la valeur réelle des variables et le chemin d'exécution suivi (notamment dans les conditions et boucles), sans avoir à ajouter des `echo` de débogage partout dans le code.

</details>