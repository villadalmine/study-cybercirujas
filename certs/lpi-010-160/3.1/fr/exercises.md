# Exercices guidés — LPI Linux Essentials (010-160 v1.6) — Topic 3.1 : Archiving Files on the Command Line

*Source de référence : [learning.lpi.org — 3.1 Archiving Files on the Command Line](https://learning.lpi.org/en/learning-materials/010-160/3/3.1/)*

---

## Préparation de l'environnement de travail

**Étape 1.** Crée un répertoire de travail dédié à ces exercices et place-toi dedans.

```bash
mkdir -p ~/archiving-lab
cd ~/archiving-lab
```

**Étape 2.** Crée quelques fichiers de test avec un contenu réel, pour que la compression ait un effet mesurable.

```bash
mkdir projet
seq 1 50000 > projet/donnees.txt
cp /etc/services projet/services_copy.txt
echo "Notes de test" > projet/notes.txt
```

**Étape 3.** Vérifie la taille du répertoire avant toute opération d'archivage.

```bash
du -sh projet/
```

<details>
<summary>Vérifier ma compréhension</summary>

- `du -sh` affiche la taille totale du répertoire dans un format lisible par un humain (`h` = *human-readable*), en la calculant récursivement sur tout le contenu.
</details>

**Questions :**
1. Pourquoi utilise-t-on `du -sh` plutôt que `ls -l` pour connaître la taille d'un répertoire entier ?
2. Que fait l'option `-p` de `mkdir` dans l'étape 1 si `~/archiving-lab` existe déjà ?

---

## Exercice 1 — Créer une archive tar non compressée

Une archive `tar` (*Tape ARchive*) regroupe plusieurs fichiers et répertoires en un seul fichier, en conservant l'arborescence, les permissions et les métadonnées. Par défaut, `tar` n'effectue **aucune compression**.

**Étape 1.** Crée une archive du répertoire `projet/`.

```bash
tar -cvf projet.tar projet/
```

**Étape 2.** Compare la taille de l'archive à celle du répertoire original.

```bash
du -sh projet/ projet.tar
```

**Étape 3.** Observe les options utilisées : `c` (create), `v` (verbose), `f` (file).

```bash
tar --help | grep -E "^\s*-[cvf],"
```

**Questions :**
1. Pourquoi la taille de `projet.tar` est-elle sensiblement identique à celle du répertoire `projet/`, alors qu'on vient de créer une « archive » ?
2. Que se passerait-il si on omettait l'option `f` et son argument `projet.tar` ?
3. À quoi sert concrètement l'option `v` ? Est-elle indispensable au bon fonctionnement de la commande ?

---

## Exercice 2 — Lister le contenu d'une archive sans l'extraire

Avant d'extraire une archive reçue d'une source externe, il est recommandé d'en inspecter le contenu.

**Étape 1.** Liste le contenu de `projet.tar` sans l'extraire.

```bash
tar -tvf projet.tar
```

**Étape 2.** Compare la sortie avec celle d'un simple `ls -laR projet/`.

```bash
ls -laR projet/
```

**Étape 3.** Cherche uniquement un fichier précis dans l'archive, sans l'extraire.

```bash
tar -tvf projet.tar | grep notes.txt
```

**Questions :**
1. Quelle option de `tar` permet de lister le contenu d'une archive sans l'extraire, et en quoi cette opération diffère-t-elle de `c` ou `x` ?
2. Quelles informations la sortie de `tar -tvf` fournit-elle en plus des simples noms de fichiers ?

---

## Exercice 3 — Extraire une archive

**Étape 1.** Supprime le répertoire `projet/` original (l'archive en contient déjà une copie complète).

```bash
rm -rf projet/
```

**Étape 2.** Extrais l'archive dans le répertoire courant.

```bash
tar -xvf projet.tar
```

**Étape 3.** Vérifie que l'arborescence et le contenu ont bien été restaurés.

```bash
diff <(tar -tf projet.tar | sort) <(find projet -type f -o -type d | sed 's#^#./#' | sort)
```

**Étape 4.** Extrais un seul fichier précis de l'archive, dans un répertoire différent.

```bash
mkdir extraction_partielle
tar -xvf projet.tar -C extraction_partielle projet/notes.txt
```

**Questions :**
1. Que fait l'option `-C` dans la commande de l'étape 4 ? Que se passerait-il si on l'omettait ?
2. Si l'archive avait été créée avec des chemins absolus (par exemple `/home/user/projet/`) plutôt que relatifs, quel risque cela poserait-il lors de l'extraction ?

---

## Exercice 4 — Compresser une archive avec gzip

`tar` peut invoquer automatiquement un outil de compression via une option dédiée, ou bien on peut compresser l'archive `.tar` après coup avec `gzip`.

**Étape 1.** Compresse l'archive existante avec `gzip`.

```bash
gzip -k projet.tar
ls -lh projet.tar*
```

**Étape 2.** Crée directement une archive compressée en une seule commande, avec l'option `z`.

```bash
tar -czvf projet.tar.gz projet/
```

**Étape 3.** Compare les tailles des trois fichiers obtenus : `projet.tar`, `projet.tar.gz` (issu du gzip manuel, renommé) et la nouvelle archive.

```bash
mv projet.tar.gz projet_direct.tar.gz
du -sh projet.tar projet.tar.gz projet_direct.tar.gz
```

**Étape 4.** Extrais l'archive `.tar.gz` directement, sans étape de décompression séparée.

```bash
mkdir extraction_gz
tar -xzvf projet_direct.tar.gz -C extraction_gz
```

**Questions :**
1. Quelle est la différence entre `gzip projet.tar` (qui compresse un `.tar` déjà créé) et `tar -czvf` (qui crée et compresse en une seule commande) ? Le résultat final est-il équivalent ?
2. Que fait l'option `-k` de `gzip` dans l'étape 1, et pourquoi est-elle utile ici ?
3. Pourquoi l'extension `.tar.gz` est-elle parfois abrégée en `.tgz` ?

---

## Exercice 5 — Comparer gzip et bzip2

**Étape 1.** Crée une archive compressée avec `bzip2` via `tar`.

```bash
tar -cjvf projet.tar.bz2 projet/
```

**Étape 2.** Compare les tailles obtenues avec `gzip` (option `z`) et `bzip2` (option `j`).

```bash
du -sh projet_direct.tar.gz projet.tar.bz2
```

**Étape 3.** Mesure le temps nécessaire à chaque compression sur ce jeu de données.

```bash
time tar -czf /tmp/test_gzip.tar.gz projet/
time tar -cjf /tmp/test_bzip2.tar.bz2 projet/
```

**Questions :**
1. D'après les résultats obtenus, quel algorithme produit généralement l'archive la plus petite, `gzip` ou `bzip2` ? Quel est le compromis associé ?
2. Quelle lettre d'option de `tar` correspond à `bzip2`, et laquelle correspond à `gzip` ?
3. Dans quel contexte pratique privilégierait-on `gzip` malgré un taux de compression inférieur à `bzip2` ?

---

## Exercice 6 — Compression xz et comparaison finale

`xz` est un algorithme de compression plus récent, offrant généralement un meilleur taux de compression au prix d'un temps de traitement plus long.

**Étape 1.** Crée une archive compressée avec `xz` via `tar`.

```bash
tar -cJvf projet.tar.xz projet/
```

**Étape 2.** Compare les trois formats côte à côte.

```bash
du -sh projet_direct.tar.gz projet.tar.bz2 projet.tar.xz
```

**Étape 3.** Compresse et décompresse un fichier individuel directement avec `xz` (sans passer par `tar`), pour observer son fonctionnement autonome.

```bash
xz -k projet/donnees.txt
ls -lh projet/donnees.txt*
unxz -k projet/donnees.txt.xz
```

**Questions :**
1. Quelle lettre majuscule identifie l'option `xz` dans les commandes `tar` (par opposition à `z` pour gzip et `j` pour bzip2) ?
2. Que produit `xz -k projet/donnees.txt` et que devient le fichier original ? À quoi sert l'option `-k` ?
3. Classe les trois algorithmes vus (gzip, bzip2, xz) du plus rapide au plus lent, et du moins compressé au plus compressé.

---

## Exercice 7 — Créer et extraire une archive zip

Le format `zip`, contrairement à `tar`, combine archivage **et** compression en une seule étape et est directement compatible avec Windows et macOS.

**Étape 1.** Vérifie que les utilitaires `zip` et `unzip` sont installés (sinon, installe-les avec le gestionnaire de paquets de ta distribution).

```bash
which zip unzip
```

**Étape 2.** Crée une archive zip du répertoire `projet/`.

```bash
zip -r projet.zip projet/
```

**Étape 3.** Liste le contenu de l'archive zip sans l'extraire.

```bash
unzip -l projet.zip
```

**Étape 4.** Extrais l'archive zip dans un nouveau répertoire.

```bash
unzip projet.zip -d extraction_zip
```

**Questions :**
1. Pourquoi l'option `-r` est-elle nécessaire avec `zip` pour archiver un répertoire, alors que `tar` archive récursivement par défaut ?
2. Quelle commande permet de lister le contenu d'une archive `.zip` sans l'extraire, et quel est l'équivalent pour `tar` ?
3. Dans quel scénario choisirait-on `zip` plutôt que `tar.gz` pour partager une archive ?

---

## Exercice 8 — Filtrage et exclusion avec tar

**Étape 1.** Crée une archive en excluant un fichier précis grâce au globbing et à l'option `--exclude`.

```bash
tar -czvf projet_sans_donnees.tar.gz --exclude='donnees.txt*' projet/
tar -tzvf projet_sans_donnees.tar.gz
```

**Étape 2.** Ajoute un nouveau fichier à une archive `.tar` non compressée existante grâce à l'option `r` (append).

```bash
tar -cvf archive_simple.tar projet/notes.txt
echo "fichier ajouté après coup" > projet/extra.txt
tar -rvf archive_simple.tar projet/extra.txt
tar -tvf archive_simple.tar
```

**Étape 3.** Nettoie l'environnement de travail.

```bash
cd ~
rm -rf ~/archiving-lab
```

**Questions :**
1. Pourquoi le motif `--exclude='donnees.txt*'` utilise-t-il un astérisque, sachant qu'on a aussi produit un fichier `donnees.txt.xz` dans l'exercice 6 ?
2. Que fait l'option `r` de `tar`, et pourquoi ne peut-on **pas** l'utiliser directement sur une archive déjà compressée (`.tar.gz`, `.tar.bz2`) ?
3. Quel est le risque de lancer `rm -rf ~/archiving-lab` sans avoir vérifié au préalable le chemin affiché par `pwd` ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Préparation**
1. `ls -l` n'affiche que la taille des entrées du répertoire lui-même (souvent 4096 octets, la taille du bloc de métadonnées), pas la somme récursive du contenu des fichiers qu'il contient. `du -sh` parcourt récursivement l'arborescence et additionne la taille réelle occupée sur le disque, puis convertit le résultat en unités lisibles (K, M, G).
2. Avec `-p`, `mkdir` ne produit pas d'erreur si le répertoire existe déjà, et crée aussi les répertoires parents manquants le cas échéant. Sans `-p`, `mkdir` échouerait avec « File exists » si `~/archiving-lab` existe déjà.

**Exercice 1**
1. Parce que `tar`, employé sans option de compression (`z`, `j` ou `J`), se contente de concaténer les fichiers et leurs métadonnées dans un seul flux binaire : c'est un simple *archivage*, sans algorithme de compression appliqué. Seul un léger surcoût lié aux en-têtes de `tar` (blocs de 512 octets par fichier) s'ajoute.
2. `tar` afficherait une erreur ou, sur certains systèmes, écrirait l'archive directement sur la sortie standard / le périphérique de bande par défaut, car `f` indique explicitement le fichier archive cible. Sans lui, le comportement devient imprévisible ou erroné.
3. L'option `v` (verbose) affiche la liste des fichiers traités au fur et à mesure de l'opération. Elle est purement informative : l'archive serait créée à l'identique sans elle, mais sans retour visuel sur la progression.

**Exercice 2**
1. L'option `t` (list) affiche le contenu de l'archive sans en extraire aucun fichier sur le disque, contrairement à `x` (extract) qui écrit réellement les fichiers, ou `c` (create) qui construit une nouvelle archive.
2. Avec `v` combiné à `t`, `tar` affiche aussi les permissions, le propriétaire, le groupe, la taille et la date de modification de chaque fichier — similaire à un `ls -l`, mais lu depuis les métadonnées stockées dans l'archive elle-même.

**Exercice 3**
1. `-C extraction_partielle` indique à `tar` de changer de répertoire de travail avant d'extraire, donc le fichier `projet/notes.txt` est déposé dans `extraction_partielle/projet/notes.txt` plutôt que dans le répertoire courant. Sans cette option, l'extraction se ferait dans le répertoire courant, écrasant potentiellement des fichiers existants au même chemin.
2. Une archive avec des chemins absolus risquerait, lors de l'extraction, d'écraser des fichiers système existants à ces mêmes emplacements absolus (par exemple `/etc/...`). C'est pourquoi les outils modernes (dont `tar`) refusent par défaut les chemins absolus ou les convertissent en chemins relatifs, sauf option explicite contraire.

**Exercice 4**
1. Le résultat final est équivalent en pratique (une archive `tar` compressée avec gzip), mais `gzip projet.tar` s'exécute en deux étapes distinctes (créer l'archive, puis la compresser), en général sans le suffixe `.gz` ajouté automatiquement au fichier original s'il n'a pas été renommé, alors que `tar -czvf` combine les deux opérations en une seule commande, en un seul flux, sans fichier `.tar` intermédiaire sur le disque.
2. `-k` (keep) conserve le fichier original `projet.tar` après compression, au lieu de le remplacer par `projet.tar.gz` (comportement par défaut de `gzip`).
3. `.tgz` est une abréviation à 3 lettres équivalente à `.tar.gz`, utile sur les anciens systèmes de fichiers limitant les extensions à 3 caractères (héritage de MS-DOS/FAT), mais toujours largement utilisée par convention aujourd'hui.

**Exercice 5**
1. `bzip2` produit en général une archive plus petite que `gzip` sur ce type de données textuelles, au prix d'un temps de compression (et parfois de décompression) plus long, car son algorithme (basé sur le *Burrows-Wheeler transform*) est plus coûteux en calcul.
2. `j` correspond à `bzip2` ; `z` correspond à `gzip`.
3. `gzip` reste préféré quand la vitesse de compression/décompression prime sur le taux de compression — par exemple pour des flux réseau en temps réel, des sauvegardes fréquentes, ou des systèmes aux ressources CPU limitées.

**Exercice 6**
1. `J` (majuscule).
2. `xz -k projet/donnees.txt` crée un fichier compressé `projet/donnees.txt.xz` tout en conservant le fichier original `projet/donnees.txt`, grâce à l'option `-k` (keep). Sans `-k`, `xz` supprimerait le fichier source après compression.
3. Du plus rapide au plus lent (à taux de compression croissant) : gzip → bzip2 → xz. C'est aussi l'ordre inverse pour le taux de compression : xz compresse généralement le mieux, suivi de bzip2, puis gzip.

**Exercice 7**
1. `zip` ne descend pas récursivement dans les sous-répertoires par défaut ; `-r` (recursive) est nécessaire pour inclure tout le contenu d'un répertoire. `tar`, à l'inverse, archive toujours récursivement l'arborescence passée en argument, sans option supplémentaire.
2. `unzip -l` liste le contenu d'une archive zip sans l'extraire ; l'équivalent pour `tar` est `tar -tvf`.
3. `zip` est préférable quand l'archive doit être ouverte nativement sur Windows ou macOS sans outil supplémentaire, ces systèmes offrant un support intégré du format zip, contrairement à `.tar.gz` qui nécessite un outil tiers sur Windows.

**Exercice 8**
1. Parce que `donnees.txt.xz` (créé à l'exercice 6) commence aussi par la chaîne `donnees.txt`. Le motif `donnees.txt*` avec le globbing capture donc à la fois `donnees.txt` et toute variante portant ce préfixe, comme `donnees.txt.xz`, garantissant qu'aucune version du fichier ne se retrouve dans l'archive filtrée.
2. L'option `r` (append/replace) ajoute un ou plusieurs fichiers à la fin d'une archive `tar` existante, en modifiant son contenu sur place. Cette opération est impossible sur une archive compressée, car le flux compressé (gzip, bzip2, xz) ne peut pas être modifié partiellement : il faudrait le décompresser entièrement, ajouter le fichier au `.tar` obtenu, puis recompresser tout l'ensemble.
3. `rm -rf` supprime récursivement et sans confirmation tout le contenu du chemin indiqué. Si le répertoire de travail courant (`pwd`) n'est pas celui attendu, ou si la variable `$HOME`/le chemin `~` pointe ailleurs que prévu, la commande peut supprimer des données importantes de manière irréversible ; il est donc prudent de vérifier le chemin exact avant toute suppression récursive.

</details>