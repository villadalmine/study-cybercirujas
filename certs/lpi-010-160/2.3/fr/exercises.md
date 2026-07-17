# LPI Linux Essentials (010-160, v1.6) — Sujet 2.3 : Using Directories and Listing Files

*Poids dans l'examen : 2*
*Source de référence : https://learning.lpi.org/en/learning-materials/010-160/2/2.3/*

---

## Exercice 1 — Localiser sa position dans le filesystem

1. Ouvrez un terminal. Vous démarrez normalement dans votre **home directory**.
2. Affichez le **working directory** actuel :
   ```
   pwd
   ```
3. Notez le chemin affiché, par exemple `/home/etudiant`.
4. Déplacez-vous vers la racine du système avec un **absolute path** :
   ```
   cd /
   ```
5. Vérifiez votre nouvelle position :
   ```
   pwd
   ```
6. Listez le contenu de la racine :
   ```
   ls
   ```
7. Revenez directement à votre home directory avec le raccourci `~` :
   ```
   cd ~
   ```

<details>
<summary>Questions de compréhension — Exercice 1</summary>

- Que renvoie la commande `pwd` ?
- Que signifie le symbole `~` quand il est utilisé avec `cd` ?
- Quelle est la différence entre exécuter `cd` sans argument et exécuter `cd ~` ?

</details>

---

## Exercice 2 — Absolute paths vs relative paths

1. Depuis votre home directory, créez une arborescence de test :
   ```
   mkdir -p projets/documents
   ```
2. Déplacez-vous dans `documents` en utilisant un **relative path** :
   ```
   cd projets/documents
   ```
3. Vérifiez le chemin complet avec `pwd`.
4. Remontez d'un niveau grâce à l'entrée spéciale `..` :
   ```
   cd ..
   ```
5. Revenez directement dans `documents`, mais cette fois avec un **absolute path** complet (utilisez le résultat de l'étape 3).
6. Retournez au répertoire précédent visité grâce au raccourci :
   ```
   cd -
   ```

<details>
<summary>Questions de compréhension — Exercice 2</summary>

- Qu'est-ce qui distingue un absolute path d'un relative path ?
- Que représentent les entrées spéciales `.` et `..` dans un répertoire ?
- Que fait exactement `cd -` ?

</details>

---

## Exercice 3 — Explorer `ls` et ses options

1. Retournez à votre home directory (`cd ~`).
2. Listez le contenu avec le format détaillé :
   ```
   ls -l
   ```
3. Observez les colonnes affichées : type de fichier/directory, permissions, propriétaire, groupe, taille, date de modification, nom.
4. Affichez les tailles dans un format lisible pour un humain :
   ```
   ls -lh
   ```
5. Affichez également les **hidden files** (ceux dont le nom commence par un point) :
   ```
   ls -la
   ```
6. Triez la liste par date de modification, la plus récente en premier :
   ```
   ls -lt
   ```
7. Triez la liste par taille décroissante :
   ```
   ls -lS
   ```

<details>
<summary>Questions de compréhension — Exercice 3</summary>

- Quel caractère apparaît en première position dans la sortie de `ls -l` pour indiquer qu'une entrée est un directory plutôt qu'un fichier régulier ?
- Pourquoi `ls -a` affiche-t-il toujours au moins deux entrées supplémentaires (`.` et `..`) même dans un directory « vide » ?
- Quelle option de `ls` faut-il combiner avec `-l` pour obtenir des tailles en Ko/Mo/Go plutôt qu'en octets ?

</details>

---

## Exercice 4 — Hidden files et exploration récursive

1. Dans votre home directory, créez un fichier caché :
   ```
   touch .config_test
   ```
2. Vérifiez qu'il n'apparaît pas avec un `ls` simple, mais qu'il apparaît avec `ls -a`.
3. Créez une petite arborescence sur plusieurs niveaux :
   ```
   mkdir -p projets/documents/rapports
   touch projets/documents/rapports/notes.txt
   ```
4. Affichez tout le contenu du directory `projets`, y compris ses sous-répertoires, en une seule commande :
   ```
   ls -R projets
   ```
5. Si l'utilitaire `tree` est installé, comparez le résultat avec :
   ```
   tree projets
   ```

<details>
<summary>Questions de compréhension — Exercice 4</summary>

- Pourquoi un fichier comme `.config_test` est-il qualifié de « caché » alors qu'il n'a aucune permission spéciale ?
- Que fait l'option `-R` de `ls` par rapport à un `ls` normal ?
- Quel avantage offre la commande `tree` par rapport à `ls -R` pour visualiser une arborescence ?

</details>

---

## Exercice 5 — Créer et supprimer des directories

1. Depuis votre home directory, créez un directory simple :
   ```
   mkdir test_dir
   ```
2. Essayez de créer un directory à plusieurs niveaux sans l'option adéquate :
   ```
   mkdir sans_option/sous_dossier
   ```
3. Observez le message d'erreur, puis recommencez avec l'option qui crée les parents manquants :
   ```
   mkdir -p avec_option/sous_dossier
   ```
4. Supprimez le directory vide `test_dir` :
   ```
   rmdir test_dir
   ```
5. Essayez de supprimer `avec_option` avec `rmdir` (il n'est pas vide) et observez l'échec.
6. Nettoyez l'arborescence complète avec :
   ```
   rm -r avec_option
   ```

<details>
<summary>Questions de compréhension — Exercice 5</summary>

- Pourquoi la commande `mkdir sans_option/sous_dossier` échoue-t-elle sans l'option `-p` ?
- Que fait précisément l'option `-p` de `mkdir` ?
- Pourquoi `rmdir` refuse-t-il de supprimer un directory non vide, et quelle commande faut-il utiliser à la place ?

</details>

---

<details>
<summary><strong>Réponses — toutes les questions</strong></summary>

**Exercice 1**
- `pwd` (print working directory) affiche le chemin absolu du directory dans lequel se trouve actuellement le shell.
- `~` est un raccourci qui représente le home directory de l'utilisateur courant.
- `cd` sans argument et `cd ~` produisent le même résultat : ils ramènent l'utilisateur dans son home directory.

**Exercice 2**
- Un absolute path part toujours de la racine `/` et décrit l'emplacement complet d'un fichier ou d'un directory, quel que soit le working directory courant. Un relative path est interprété par rapport au working directory actuel.
- `.` représente le directory courant lui-même ; `..` représente son directory parent.
- `cd -` ramène l'utilisateur dans le directory précédemment visité (le `OLDPWD`), et affiche son chemin.

**Exercice 3**
- Le caractère `d` en première position indique un directory (un `-` indique un fichier régulier).
- Parce que tout directory du filesystem contient toujours ces deux entrées spéciales, `.` (lui-même) et `..` (son parent), même s'il ne contient aucun autre fichier.
- L'option `-h` (human-readable), utilisée en combinaison avec `-l`, par exemple `ls -lh`.

**Exercice 4**
- Par convention Unix/Linux, tout fichier ou directory dont le nom commence par un point (`.`) est considéré comme caché et n'est pas affiché par défaut par `ls` ; ce n'est qu'une convention de nommage, pas une permission particulière.
- L'option `-R` (recursive) fait descendre `ls` dans tous les sous-répertoires et affiche leur contenu également.
- `tree` présente l'arborescence sous une forme graphique hiérarchique (avec des branches), ce qui est souvent plus lisible que la sortie à plat, répertoire par répertoire, de `ls -R`.

**Exercice 5**
- Parce que `mkdir` refuse de créer un sous-directory si son directory parent (`sans_option`) n'existe pas encore.
- L'option `-p` crée automatiquement tous les directories parents manquants nécessaires au chemin demandé, sans générer d'erreur si certains existent déjà.
- `rmdir` ne supprime que des directories vides, par sécurité. Pour supprimer un directory contenant des fichiers ou d'autres directories, il faut utiliser `rm -r` (recursive), voire `rm -rf` pour forcer sans confirmation.

</details>