# Exercices guidés — 2.4 Creating, Moving and Deleting Files

**Certification :** LPI Linux Essentials (010-160, v1.6)
**Poids dans l'examen :** 2
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/2/2.4/

---

## Exercice 1 — Créer des fichiers et des répertoires

1. Ouvrez un terminal et déplacez-vous dans votre répertoire personnel :
   ```bash
   cd ~
   ```
2. Créez un répertoire de travail nommé `atelier` :
   ```bash
   mkdir atelier
   ```
3. Entrez dans ce répertoire :
   ```bash
   cd atelier
   ```
4. Créez un fichier vide nommé `notes.txt` :
   ```bash
   touch notes.txt
   ```
5. Créez d'un seul coup toute une arborescence de sous-répertoires imbriqués :
   ```bash
   mkdir -p projets/2024/rapports
   ```
6. Vérifiez le résultat avec :
   ```bash
   ls -R
   ```

**Questions de compréhension**
1. Que se passe-t-il si vous exécutez `touch notes.txt` alors que ce fichier existe déjà ?
2. Pourquoi la commande `mkdir projets/2024/rapports` (sans l'option `-p`) échouerait-elle si `projets` n'existe pas encore ?

---

## Exercice 2 — Copier des fichiers et des répertoires

1. Toujours dans `~/atelier`, créez une copie de `notes.txt` :
   ```bash
   cp notes.txt notes_backup.txt
   ```
2. Copiez `notes.txt` vers le sous-répertoire `projets/2024/` :
   ```bash
   cp notes.txt projets/2024/
   ```
3. Essayez de copier tout le répertoire `projets` vers un nouveau répertoire `projets_copie` :
   ```bash
   cp projets projets_copie
   ```
   Observez le message d'erreur affiché.
4. Recommencez en utilisant l'option récursive :
   ```bash
   cp -r projets projets_copie
   ```
5. Comparez les deux arborescences :
   ```bash
   ls -R projets projets_copie
   ```

**Questions de compréhension**
1. Pourquoi l'étape 3 échoue-t-elle avec `cp` seul, sans option ?
2. Quel est le rôle exact de l'option `-r` (ou `--recursive`) de `cp` ?
3. Si le fichier `notes_backup.txt` existait déjà avec un contenu différent, que se passerait-il par défaut lors de l'étape 1 ?

---

## Exercice 3 — Déplacer et renommer des fichiers

1. Renommez `notes_backup.txt` en `notes_old.txt` :
   ```bash
   mv notes_backup.txt notes_old.txt
   ```
2. Déplacez `notes_old.txt` dans `projets/2024/rapports/` :
   ```bash
   mv notes_old.txt projets/2024/rapports/
   ```
3. Déplacez tout le répertoire `projets_copie` pour le renommer `archive` :
   ```bash
   mv projets_copie archive
   ```
4. Vérifiez l'état final de `~/atelier` :
   ```bash
   ls -R
   ```

**Questions de compréhension**
1. Quelle est la différence fondamentale entre `cp` et `mv` en ce qui concerne le fichier source ?
2. Pourquoi une seule et même commande `mv` permet-elle à la fois de renommer un fichier et de le déplacer vers un autre répertoire ?

---

## Exercice 4 — Utiliser les wildcards (globbing)

1. Dans `~/atelier`, créez plusieurs fichiers de test :
   ```bash
   touch fichier1.txt fichier2.txt fichier3.log rapport_a.txt rapport_b.txt
   ```
2. Listez uniquement les fichiers `.txt` :
   ```bash
   ls *.txt
   ```
3. Copiez tous les fichiers commençant par `rapport_` vers `projets/2024/rapports/` :
   ```bash
   cp rapport_*.txt projets/2024/rapports/
   ```
4. Utilisez le wildcard `?` pour lister uniquement `fichier1.txt` et `fichier2.txt` (un seul caractère avant `.txt`) :
   ```bash
   ls fichier?.txt
   ```
5. Utilisez une classe de caractères pour sélectionner `fichier1.txt` et `fichier3.log` seulement (via le chiffre) :
   ```bash
   ls fichier[13]*
   ```

**Questions de compréhension**
1. Que sélectionne exactement le motif `*` par rapport au motif `?` dans le globbing du shell ?
2. Le globbing est-il interprété par la commande `ls` elle-même ou par le shell avant l'exécution de la commande ? Justifiez.

---

## Exercice 5 — Supprimer des fichiers et des répertoires

1. Supprimez le fichier `fichier3.log` :
   ```bash
   rm fichier3.log
   ```
2. Essayez de supprimer le répertoire vide `archive/2024/rapports` avec `rmdir` :
   ```bash
   rmdir archive/2024/rapports
   ```
3. Essayez maintenant de supprimer avec `rmdir` le répertoire `archive` (qui contient encore des fichiers ou sous-répertoires) :
   ```bash
   rmdir archive
   ```
   Observez le message d'erreur.
4. Supprimez `archive` avec toute sa hiérarchie en utilisant `rm` :
   ```bash
   rm -r archive
   ```
5. Testez le mode interactif de suppression, qui demande confirmation avant chaque suppression :
   ```bash
   rm -i rapport_a.txt rapport_b.txt
   ```

**Questions de compréhension**
1. Pourquoi `rmdir` ne peut-il jamais supprimer un répertoire non vide, contrairement à `rm -r` ?
2. Quel est l'intérêt pratique de l'option `-i` de `rm`, surtout combinée à un wildcard comme `rm -i *.txt` ?
3. Existe-t-il une corbeille par défaut lorsqu'on utilise `rm` en ligne de commande ? Quelle conséquence cela a-t-il ?

---

## Exercice 6 — Créer des liens (hard links et symbolic links)

1. Créez un fichier source :
   ```bash
   echo "contenu original" > source.txt
   ```
2. Créez un lien physique (hard link) vers ce fichier :
   ```bash
   ln source.txt lien_dur.txt
   ```
3. Créez un lien symbolique (symbolic link) vers ce même fichier :
   ```bash
   ln -s source.txt lien_symbolique.txt
   ```
4. Affichez les numéros d'inode des trois fichiers :
   ```bash
   ls -li source.txt lien_dur.txt lien_symbolique.txt
   ```
5. Supprimez le fichier original :
   ```bash
   rm source.txt
   ```
6. Vérifiez le contenu des deux liens restants :
   ```bash
   cat lien_dur.txt
   cat lien_symbolique.txt
   ```

**Questions de compréhension**
1. Après la suppression de `source.txt`, pourquoi `lien_dur.txt` contient-il toujours le texte, alors que `lien_symbolique.txt` pointe désormais vers un fichier inexistant ?
2. Comparez le numéro d'inode de `source.txt` et de `lien_dur.txt` observé à l'étape 4 : que révèle cette égalité sur la nature d'un hard link ?
3. Dans quel cas pratique préférerait-on un symbolic link à un hard link (par exemple entre systèmes de fichiers différents) ?

---

<details>
<summary><strong>Voir les réponses</strong></summary>

**Exercice 1**
1. `touch` met simplement à jour la date de dernière modification (timestamp) du fichier existant ; il ne l'écrase pas et ne perd pas son contenu.
2. Sans `-p`, `mkdir` refuse de créer un répertoire dont le parent n'existe pas encore : il faudrait créer `projets`, puis `projets/2024`, puis `projets/2024/rapports` séparément. L'option `-p` crée toute la chaîne de répertoires parents manquants automatiquement.

**Exercice 2**
1. `cp` seul ne copie pas récursivement le contenu d'un répertoire ; par défaut il refuse d'agir sur un répertoire et affiche une erreur du type « omitting directory ».
2. `-r` (ou `-R`/`--recursive`) indique à `cp` de descendre dans l'arborescence et de copier tous les sous-répertoires et fichiers qu'elle contient.
3. Par défaut, `cp` écrase silencieusement le fichier de destination sans demander de confirmation (sauf si l'option `-i` est utilisée ou activée par un alias).

**Exercice 3**
1. `cp` duplique le fichier (deux copies indépendantes existent ensuite), alors que `mv` déplace l'unique fichier existant : après un `mv`, le fichier source n'existe plus à son emplacement d'origine.
2. Parce que renommer revient techniquement à déplacer un fichier vers un nouveau nom dans le même répertoire ; `mv` ne fait pas de distinction entre changer de nom et changer de répertoire, les deux sont une opération de déplacement du chemin.

**Exercice 4**
1. `*` correspond à zéro ou plusieurs caractères quelconques, tandis que `?` correspond à exactement un seul caractère.
2. Le globbing est réalisé par le shell (bash, par exemple) avant l'exécution de la commande : le shell remplace le motif par la liste des fichiers correspondants, puis transmet cette liste déjà développée à `ls` (ou toute autre commande). `ls` elle-même ne « comprend » pas les wildcards.

**Exercice 5**
1. `rmdir` est conçu uniquement pour supprimer des répertoires vides ; c'est une mesure de sécurité qui empêche de supprimer accidentellement un répertoire contenant des données sans le vouloir explicitement.
2. L'option `-i` force une confirmation avant chaque suppression, ce qui réduit le risque de supprimer par erreur un fichier non désiré lorsqu'on utilise un motif large comme `*.txt`.
3. Non, `rm` supprime définitivement (aucune corbeille par défaut en ligne de commande) : une fois la suppression effectuée, le fichier n'est en principe pas récupérable facilement par l'utilisateur.

**Exercice 6**
1. Un hard link pointe directement vers le même inode (les mêmes données sur le disque) que le fichier original ; supprimer un des noms ne supprime les données que lorsque le compteur de liens tombe à zéro. Un symbolic link, lui, ne stocke qu'un chemin texte vers le nom du fichier cible : si ce nom disparaît, le lien devient orphelin (« broken link »).
2. Le fait que `source.txt` et `lien_dur.txt` partagent le même numéro d'inode prouve qu'un hard link n'est pas une copie, mais un second nom pointant vers les mêmes données physiques sur le disque.
3. Un symbolic link est préférable quand la cible peut se trouver sur un système de fichiers ou une partition différente, car un hard link ne peut être créé qu'à l'intérieur du même système de fichiers, alors qu'un symbolic link peut référencer n'importe quel chemin, y compris à travers des montages différents.

</details>