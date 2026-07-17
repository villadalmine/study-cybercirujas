# TP guidés — Sujet 3.2 : Searching and Extracting Data from Files

**Certification :** LPI Linux Essentials (010-160, v1.6)
**Poids à l'examen :** 3

Exécutez chaque étape vous-même dans un terminal — ne copiez-collez pas — et observez le résultat avant de répondre aux questions.

---

## Exercice 1 — Préparer un terrain de jeu

Pour s'entraîner à chercher et extraire des données, il faut d'abord du texte à explorer.

1. Créez un répertoire de travail et placez-vous dedans :
   ```bash
   mkdir ~/search-lab
   cd ~/search-lab
   ```
2. Créez une liste de mots simple :
   ```bash
   cat > fruits.txt << EOF
   apple
   Banana
   cherry
   banana
   Apple
   date
   EOF
   ```
3. Créez une « base d'utilisateurs » séparée par des deux-points, sur le modèle de `/etc/passwd` :
   ```bash
   cat > users.txt << EOF
   ana:1001:developer
   bruno:1002:designer
   carla:1003:developer
   diego:1004:manager
   elena:1005:developer
   EOF
   ```
4. Créez un petit fichier de log :
   ```bash
   cat > app.log << EOF
   2026-07-01 10:02 INFO  service started
   2026-07-01 10:05 ERROR disk almost full
   2026-07-01 10:07 INFO  user ana logged in
   2026-07-01 10:12 WARN  slow response time
   2026-07-01 10:15 ERROR connection refused
   2026-07-01 10:20 INFO  user bruno logged in
   EOF
   ```
5. Vérifiez que tout est en place :
   ```bash
   ls -l
   cat fruits.txt users.txt app.log
   ```

**Questions**

- **1a.** `cat` signifie *concatenate*. D'après l'étape 5, que fait `cat` lorsqu'on lui donne plusieurs noms de fichiers ?
- **1b.** À l'étape 2, `cat > fruits.txt << EOF` capture ce que vous tapez et l'écrit dans le fichier. Quel caractère indique au shell d'envoyer la sortie de `cat` vers un fichier plutôt que vers l'écran ?

---

## Exercice 2 — Regarder la bonne portion d'un fichier : head, tail, less

Les fichiers réels (les logs en particulier) sont souvent trop longs pour être lus en entier. Ces outils affichent uniquement la tranche qui vous intéresse.

1. Affichez seulement les deux premières lignes du log :
   ```bash
   head -n 2 app.log
   ```
2. Affichez seulement les deux dernières lignes :
   ```bash
   tail -n 2 app.log
   ```
   Par défaut, `head` et `tail` affichent 10 lignes ; `-n` change ce nombre.
3. Observez un fichier qui grossit en temps réel — la façon classique de surveiller un log actif. Dans ce terminal, lancez :
   ```bash
   tail -f app.log
   ```
   Ouvrez un **second** terminal et ajoutez une ligne :
   ```bash
   echo "2026-07-01 10:25 INFO  user carla logged in" >> ~/search-lab/app.log
   ```
   La nouvelle ligne apparaît immédiatement dans le premier terminal. Appuyez sur `Ctrl+C` là-bas pour arrêter le suivi.
4. Ouvrez un fichier plus long dans le pager et naviguez dedans :
   ```bash
   less /etc/services
   ```
   Déplacez-vous avec les flèches, `Espace` (page suivante), `b` (page précédente). Tapez `/tcp` puis Entrée pour chercher vers l'avant ; `n` passe au résultat suivant. `q` quitte.

**Questions**

- **2a.** Quelle commande montre le *début* d'un fichier et laquelle montre la *fin* ? Quelle option contrôle le nombre de lignes affichées ?
- **2b.** Que fait `tail -f`, et pourquoi est-ce particulièrement utile avec les fichiers de log ?
- **2c.** Dans `less`, comment cherche-t-on un mot, passe-t-on au résultat suivant, et quitte-t-on ?

---

## Exercice 3 — Redirection : envoyer la sortie où vous voulez

Chaque commande dispose de trois flux standards : **stdin** (0, entrée), **stdout** (1, sortie normale) et **stderr** (2, messages d'erreur). Le shell peut rediriger chacun d'eux indépendamment.

1. Redirigez stdout vers un fichier, puis vérifiez le résultat :
   ```bash
   ls -l > listing.txt
   cat listing.txt
   ```
2. Constatez la différence entre écraser et ajouter :
   ```bash
   echo "first line" > notes.txt
   echo "second line" > notes.txt
   cat notes.txt
   echo "third line" >> notes.txt
   cat notes.txt
   ```
3. Provoquez une erreur volontairement et observez que `>` ne la capture *pas* :
   ```bash
   ls nosuchfile > out.txt
   cat out.txt
   ```
   Le message d'erreur est quand même apparu à l'écran — il a voyagé sur stderr, pas sur stdout.
4. Redirigez maintenant le flux d'erreur, puis les deux flux ensemble :
   ```bash
   ls nosuchfile 2> errors.txt
   cat errors.txt
   ls fruits.txt nosuchfile > all.txt 2>&1
   cat all.txt
   ```
5. Jetez une sortie indésirable dans le vide :
   ```bash
   ls nosuchfile 2> /dev/null
   ```
6. Redirigez un fichier *vers* l'entrée standard d'une commande :
   ```bash
   wc -l < fruits.txt
   ```

**Questions**

- **3a.** Quelle est la différence entre `>` et `>>` ?
- **3b.** À l'étape 3, pourquoi le message d'erreur est-il apparu à l'écran alors que la sortie était redirigée avec `>` ?
- **3c.** Que signifient respectivement `2>`, `2>&1` et `/dev/null` ?
- **3d.** Remarquez que `wc -l < fruits.txt` affiche un compte sans nom de fichier, alors que `wc -l fruits.txt` affiche les deux. Pourquoi ?

---

## Exercice 4 — Les pipes : enchaîner des commandes

Le pipe (`|`) connecte le stdout d'une commande au stdin de la suivante, ce qui permet de combiner de petits outils en lignes de commande puissantes.

1. Comptez combien d'entrées contient votre base d'utilisateurs :
   ```bash
   cat users.txt | wc -l
   ```
   (`wc -l users.txt` donne le même résultat — l'intérêt du pipe apparaît quand il y a plusieurs étapes.)
2. Triez la liste de fruits et observez attentivement l'ordre obtenu :
   ```bash
   sort fruits.txt
   ```
   Selon la locale, majuscules et minuscules peuvent être regroupées ou séparées. Comparez avec un tri inversé :
   ```bash
   sort -r fruits.txt
   ```
3. Enchaînez trois commandes : triez les fruits, puis ne gardez que les trois premiers du résultat trié :
   ```bash
   sort fruits.txt | head -n 3
   ```
4. Comptez mots et caractères, pas seulement les lignes :
   ```bash
   wc app.log
   wc -w app.log
   wc -c app.log
   ```
   Les trois nombres affichés par `wc` seul sont : lignes, mots, octets.
5. Combinez un pipe avec une redirection — sauvegardez un résultat trié dans un fichier :
   ```bash
   sort fruits.txt | tail -n 2 > last-fruits.txt
   cat last-fruits.txt
   ```

**Questions**

- **4a.** Avec vos propres mots, que fait l'opérateur `|` ?
- **4b.** Quels trois nombres affiche `wc fichier` seul, et dans quel ordre ?
- **4c.** À l'étape 5, les données ont traversé `sort`, puis `tail`, puis un fichier. Quelle partie de la ligne est un pipe, et quelle partie est une redirection ?

---

## Exercice 5 — Extraire des colonnes avec cut

`cut` découpe chaque ligne en champs et ne garde que ceux que vous demandez — idéal pour des fichiers structurés comme `users.txt` ou `/etc/passwd`.

1. Extrayez uniquement les noms d'utilisateur (champ 1, champs séparés par `:`) :
   ```bash
   cut -d ':' -f 1 users.txt
   ```
   `-d` fixe le **d**élimiteur, `-f` choisit le ou les **f**ield(s) (champs).
2. Extrayez deux champs à la fois — nom et rôle :
   ```bash
   cut -d ':' -f 1,3 users.txt
   ```
3. Appliquez-le à un vrai fichier système — le nom de connexion et le shell de chaque compte :
   ```bash
   cut -d ':' -f 1,7 /etc/passwd
   ```
4. Construisez un pipeline : listez tous les rôles présents dans le fichier, triés :
   ```bash
   cut -d ':' -f 3 users.txt | sort
   ```

**Questions**

- **5a.** Que signifient les options `-d` et `-f` de `cut` ?
- **5b.** Quel est le délimiteur par défaut de `cut` quand `-d` n'est pas précisé ? (Essayez `cut -f 1 users.txt` et observez le résultat.)
- **5c.** Écrivez un seul pipeline qui affiche les noms d'utilisateur de `users.txt` en ordre alphabétique inverse.

---

## Exercice 6 — Chercher dans un fichier avec grep

`grep` affiche les lignes d'un fichier qui correspondent à un motif — l'outil de base de l'analyse de logs et du dépannage au quotidien.

1. Trouvez toutes les lignes d'erreur du log :
   ```bash
   grep ERROR app.log
   ```
2. Cherchez sans tenir compte de la casse, et affichez les numéros de ligne :
   ```bash
   grep -i error app.log
   grep -n ERROR app.log
   ```
3. Inversez la correspondance — tout ce qui n'est *pas* une ligne INFO :
   ```bash
   grep -v INFO app.log
   ```
4. Comptez les correspondances plutôt que de les afficher :
   ```bash
   grep -c ERROR app.log
   ```
5. Utilisez grep à la fin d'un pipeline — quels utilisateurs de la base sont développeurs ?
   ```bash
   cut -d ':' -f 1,3 users.txt | grep developer
   ```
6. Essayez un motif qui ne correspond à rien et observez l'absence de sortie :
   ```bash
   grep FATAL app.log
   ```

**Questions**

- **6a.** Que font respectivement les options `-i`, `-v`, `-n` et `-c` de grep ?
- **6b.** Combien de lignes affiche `grep -v INFO app.log` sur le log original de six lignes, et lesquelles ?
- **6c.** À l'étape 5, pourquoi grep fonctionne-t-il alors qu'aucun nom de fichier ne lui a été donné ?

---

## Exercice 7 — Expressions régulières de base

Les motifs de grep sont des **expressions régulières** (regex) — un mini-langage où certains caractères ont un sens spécial : `.` correspond à n'importe quel caractère unique, `[...]` correspond à un caractère parmi un ensemble, `*` signifie « l'élément précédent, zéro fois ou plus », `^` ancre au début de la ligne, et `$` ancre à la fin.

1. Ancrez au début de ligne — les fruits qui commencent par un `b` minuscule :
   ```bash
   grep '^b' fruits.txt
   ```
   Notez que `Banana` n'est pas trouvé. Mettez vos motifs entre guillemets simples (comme ici) pour que le shell n'interprète pas lui-même les caractères spéciaux.
2. Ancrez à la fin — les fruits qui finissent par `e` :
   ```bash
   grep 'e$' fruits.txt
   ```
3. Utilisez un ensemble de caractères — les lignes commençant par `a` ou `A` :
   ```bash
   grep '^[aA]' fruits.txt
   ```
4. Utilisez le point (n'importe quel caractère) — un `d`, puis deux caractères quelconques, puis `e` :
   ```bash
   grep 'd..e' fruits.txt
   ```
5. Utilisez `*` pour la répétition — `an` suivi de zéro ou plusieurs `a`, en fin de ligne :
   ```bash
   grep 'ana*$' fruits.txt
   ```
6. Combinez les ancres pour trouver les lignes vides (il ne devrait pas y en avoir — ajoutez-en une avec `echo "" >> fruits.txt` puis relancez) :
   ```bash
   grep -c '^$' fruits.txt
   ```
7. Faites correspondre un point littéral en l'échappant. Observez d'abord le problème, puis la solution :
   ```bash
   echo "version 2.5 released" > release.txt
   echo "version 245 released" >> release.txt
   grep '2.5' release.txt
   grep '2\.5' release.txt
   ```

**Questions**

- **7a.** Que signifient respectivement `^`, `$`, `.`, `[...]` et `*` dans une expression régulière ?
- **7b.** À l'étape 7, pourquoi `grep '2.5'` correspond-il aux *deux* lignes, et comment `2\.5` corrige-t-il cela ?
- **7c.** Parmi ces lignes, lesquelles correspondent au motif `^[bB]anana$` : `banana`, `Banana`, `bananas`, `a banana` ?
- **7d.** Pourquoi faut-il entourer les motifs regex de guillemets simples sur la ligne de commande ?

---

## Exercice 8 — Tout combiner, puis nettoyer

1. Une mini-tâche réaliste : à partir du log, extrayez les horodatages (les deux premiers champs, séparés par des espaces) de chaque ERROR, triés :
   ```bash
   grep ERROR app.log | cut -d ' ' -f 1,2 | sort
   ```
2. Comptez combien de niveaux de sévérité distincts apparaissent — extrayez le champ 3, triez-le, inspectez visuellement :
   ```bash
   cut -d ' ' -f 3 app.log | sort
   ```
3. Supprimez le lab :
   ```bash
   cd ~
   rm -r ~/search-lab
   ```

**Questions**

- **8a.** Décrivez, étape par étape, ce qui circule dans le pipeline de l'étape 1.
- **8b.** En utilisant uniquement les outils de ce sujet, comment compteriez-vous le nombre de comptes de votre système dont le shell est `/bin/bash` ? (Indice : `/etc/passwd`, `grep`, `wc`.)

---

<details>
<summary><strong>Réponses</strong></summary>

- **1a.** `cat` lit chaque fichier dans l'ordre donné et écrit leur contenu sur la sortie standard, l'un après l'autre — il les concatène en un seul flux.
- **1b.** Le caractère `>`. Il redirige la sortie standard de la commande vers le fichier indiqué au lieu du terminal.

- **2a.** `head` affiche le début, `tail` affiche la fin ; les deux affichent 10 lignes par défaut, et `-n <nombre>` change ce nombre.
- **2b.** `tail -f` garde le fichier ouvert et affiche les nouvelles lignes au fur et à mesure qu'elles sont ajoutées (mode « follow »). Les logs grossissent en continu, ce qui permet de suivre les événements en temps réel.
- **2c.** On tape `/motif` puis Entrée pour chercher vers l'avant, `n` pour le résultat suivant, et `q` pour quitter.

- **3a.** `>` tronque le fichier cible et écrit depuis le début (écrasement) ; `>>` ajoute à la fin, en conservant le contenu existant.
- **3b.** `>` ne redirige que stdout (flux 1). Les messages d'erreur voyagent sur stderr (flux 2), qui restait connecté au terminal — d'où l'affichage à l'écran et le fichier `out.txt` resté vide.
- **3c.** `2>` redirige stderr vers un fichier ; `2>&1` redirige stderr vers l'endroit où pointe actuellement stdout, ce qui fusionne les deux flux ; `/dev/null` est un périphérique spécial qui ignore et détruit tout ce qu'on y écrit.
- **3d.** Avec `< fruits.txt`, le shell ouvre le fichier et le fournit à `wc` sur stdin — `wc` ne voit jamais de nom de fichier, donc il ne peut pas en afficher. Avec `wc -l fruits.txt`, `wc` ouvre lui-même le fichier et en connaît le nom.

- **4a.** `|` connecte la sortie standard de la commande à gauche à l'entrée standard de la commande à droite, ce qui fait circuler les données entre elles sans fichier intermédiaire.
- **4b.** Lignes, puis mots, puis octets.
- **4c.** `sort fruits.txt | tail -n 2` est le pipe (commande vers commande) ; `> last-fruits.txt` est la redirection (commande vers fichier).

- **5a.** `-d` fixe le délimiteur de champ (le caractère qui sépare les colonnes) ; `-f` sélectionne le ou les numéros de champ à afficher.
- **5b.** Le délimiteur par défaut est la tabulation. Comme `users.txt` ne contient aucune tabulation, `cut -f 1 users.txt` affiche chaque ligne entière sans modification.
- **5c.** `cut -d ':' -f 1 users.txt | sort -r`

- **6a.** `-i` ignore la casse, `-v` inverse la correspondance (affiche les lignes qui ne correspondent pas), `-n` préfixe chaque résultat avec son numéro de ligne, `-c` n'affiche que le compte de lignes correspondantes.
- **6b.** Trois lignes : les deux lignes ERROR et la ligne WARN — toute ligne qui ne contient pas `INFO`.
- **6c.** Sans nom de fichier, grep lit l'entrée standard ; le pipe lui fournit la sortie de `cut`. C'est précisément ce qui rend grep composable dans des pipelines.

- **7a.** `^` ancre la correspondance au début de la ligne ; `$` ancre à la fin ; `.` correspond à un caractère quelconque ; `[...]` correspond à exactement un caractère parmi ceux listés ; `*` répète l'élément précédent zéro fois ou plus.
- **7b.** Dans une regex, `.` signifie « n'importe quel caractère », donc `2.5` correspond aussi bien à `2.5` qu'à `245`. L'échapper en `2\.5` retire ce sens spécial, et le motif ne correspond plus qu'à un point littéral.
- **7c.** Seulement `banana` et `Banana`. Les ancres exigent que la ligne entière soit exactement `banana` ou `Banana` ; `bananas` a un caractère de trop après le `a`, et `a banana` a du texte avant le `b`.
- **7d.** Des caractères comme `*`, `$` et `[` ont aussi un sens spécial pour le shell (globbing, variables). Les guillemets simples livrent le motif à grep sans modification ; sans eux, le shell pourrait l'étendre ou le transformer avant même que grep ne le reçoive.

- **8a.** `grep ERROR app.log` ne garde que les deux lignes contenant `ERROR` ; `cut -d ' ' -f 1,2` réduit chacune de ces lignes à ses champs date et heure ; `sort` ordonne les horodatages obtenus ; le résultat final s'affiche à l'écran.
- **8b.** `grep '/bin/bash$' /etc/passwd | wc -l` — ou de façon équivalente `grep -c '/bin/bash$' /etc/passwd`. Ancrer avec `$` évite de faire correspondre la chaîne au milieu d'une ligne.

</details>

---

**Référence :** LPI Learning Materials, Linux Essentials Sujet 3.2 — *Searching and Extracting Data from Files* : https://learning.lpi.org/en/learning-materials/010-160/3/3.2/