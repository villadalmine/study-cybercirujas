# Thème 2.2 — Using the Command Line to Get Help

**Certification :** LPI Linux Essentials (examen 010-160, v1.6)
**Poids dans l'examen :** 2
**Référence :** https://learning.lpi.org/en/learning-materials/010-160/2/2.2/

Ce thème couvre les mécanismes intégrés à Linux pour obtenir de la documentation sans quitter le terminal : les **man pages**, l'option `--help`, la commande `info`, ainsi que les outils permettant de localiser une commande ou un fichier de configuration sur le système (`which`, `whereis`, `locate`, `type`).

---

## Bloc 1 — Les man pages

Les **man pages** (manual pages) sont la source de documentation historique et la plus complète sous Linux. Chaque commande, chaque fichier de configuration et chaque appel système possède potentiellement sa propre page.

1. Ouvrez un terminal et affichez la page de manuel de la commande `ls` :
   ```
   man ls
   ```
2. Une fois dans le pager (généralement `less`), repérez les grandes sections de la page : `NAME`, `SYNOPSIS`, `DESCRIPTION`, `OPTIONS`, `AUTHOR`, `SEE ALSO`.
3. Utilisez `/` suivi d'un mot-clé pour rechercher un terme dans la page, par exemple `/recursive`, puis appuyez sur `n` pour passer à l'occurrence suivante.
4. Quittez le pager en appuyant sur `q`.
5. Affichez maintenant la page de manuel du fichier de configuration `passwd` :
   ```
   man passwd
   ```
   Observez que le contenu affiché concerne la commande `passwd` (changement de mot de passe), et non le fichier `/etc/passwd`.
6. Les man pages sont organisées en **sections numérotées** (1 = commandes utilisateur, 5 = formats de fichiers, 8 = commandes d'administration, etc.). Forcez l'affichage de la section 5 pour obtenir la documentation du fichier :
   ```
   man 5 passwd
   ```
7. Comparez les deux résultats : la section `NAME` de chaque page précise entre parenthèses le numéro de section consulté.

> **Vérification de compréhension**
> 1. Pourquoi `man passwd` et `man 5 passwd` n'affichent-ils pas le même contenu ?
> 2. Quelle section des man pages est utilisée pour les commandes d'administration système (par opposition aux commandes utilisateur standard) ?
> 3. Quelle touche du pager permet de rechercher un mot dans une man page en cours de lecture ?

---

## Bloc 2 — `--help` et la commande `info`

En complément des man pages, la plupart des commandes offrent une aide rapide intégrée, et le système GNU propose un système de documentation hypertextuel appelé `info`.

1. Affichez l'aide rapide de `ls` sans ouvrir de pager complet :
   ```
   ls --help
   ```
2. Comparez la longueur et le niveau de détail de cette sortie avec celle de `man ls` vue au Bloc 1. `--help` liste généralement les options disponibles de façon concise, sans les explications approfondies.
3. Certaines commandes plus anciennes utilisent un tiret simple : essayez
   ```
   ls -h
   ```
   et observez que ce n'est **pas** une aide, mais une option qui modifie l'affichage des tailles de fichiers (`--human-readable`). Cela illustre pourquoi il faut toujours vérifier la syntaxe exacte attendue par chaque commande.
4. Ouvrez maintenant la documentation `info` pour la commande `ls` :
   ```
   info ls
   ```
5. Dans `info`, déplacez-vous avec les touches suivantes : `n` (nœud suivant), `p` (nœud précédent), `u` (remonter d'un niveau), et `q` pour quitter.
6. Comparez la structure de `info ls` (organisée en nœuds/chapitres navigables) avec celle de `man ls` (un seul long document linéaire).

> **Vérification de compréhension**
> 1. Quelle différence de niveau de détail attend-on généralement entre `commande --help` et `man commande` ?
> 2. Pourquoi est-il risqué de supposer que `-h` signifie toujours « help » pour n'importe quelle commande ?
> 3. Quelle touche permet de quitter le système `info` ?

---

## Bloc 3 — Rechercher une commande avec `apropos` et `whatis`

Il arrive de connaître le but d'une commande sans en connaître le nom exact. `apropos` et `whatis` interrogent une base de données de descriptions courtes construite à partir des man pages.

1. Recherchez toutes les commandes dont la description contient le mot « copy » :
   ```
   apropos copy
   ```
2. Observez la liste retournée : chaque ligne indique le nom de la commande, son numéro de section entre parenthèses, puis une courte description.
3. Si la base de données semble vide ou obsolète, elle peut être reconstruite (nécessite les privilèges administrateur) :
   ```
   sudo mandb
   ```
4. Affichez maintenant la description courte d'une commande dont vous connaissez déjà le nom :
   ```
   whatis ls
   ```
5. Comparez `apropos` (recherche par mot-clé dans les descriptions) et `whatis` (affiche la description exacte d'un nom de commande connu).
6. Notez que `man -k` est strictement équivalent à `apropos` :
   ```
   man -k copy
   ```

> **Vérification de compréhension**
> 1. Quelle est la différence d'usage entre `apropos` et `whatis` ?
> 2. Quelle commande d'administration reconstruit la base de données utilisée par `apropos` ?
> 3. Quelle commande alternative, utilisant l'option `-k` de `man`, produit le même résultat qu'`apropos` ?

---

## Bloc 4 — Localiser une commande ou un fichier

Une fois qu'on connaît le nom d'une commande, il est souvent utile de savoir où elle se trouve réellement sur le disque, et de distinguer cela de la localisation de ses fichiers de documentation.

1. Trouvez le chemin de l'exécutable utilisé lorsque vous tapez `ls` :
   ```
   which ls
   ```
2. Affichez comment le shell interprète le mot `ls` (commande externe, alias, ou fonction intégrée) :
   ```
   type ls
   ```
3. Comparez avec un builtin du shell, par exemple `cd` :
   ```
   type cd
   ```
   Observez que `which cd` peut ne rien renvoyer ou donner un résultat trompeur, car `cd` est une fonction intégrée au shell (**builtin**) et non un exécutable séparé.
4. Listez tous les emplacements connus liés à une commande (binaire, sources, man pages) :
   ```
   whereis ls
   ```
5. Si l'utilitaire est installé sur votre distribution, recherchez rapidement un fichier par son nom grâce à une base de données pré-indexée :
   ```
   locate passwd
   ```
   Si la commande n'est pas trouvée, elle nécessite l'installation du paquet `mlocate` (ou équivalent) et une première indexation via `sudo updatedb`.
6. Comparez `locate` (recherche instantanée dans une base indexée, potentiellement obsolète) avec la commande `find` (recherche en temps réel sur le disque, plus lente mais toujours à jour) — sujet approfondi dans un autre thème.

> **Vérification de compréhension**
> 1. Pourquoi `which cd` ne fonctionne-t-il pas comme attendu ?
> 2. Quelle commande affiche à la fois l'emplacement du binaire, des sources et des man pages d'une commande ?
> 3. Quel est l'inconvénient principal de `locate` par rapport à une recherche en temps réel comme `find` ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Bloc 1 — Les man pages**
1. Parce que le nom `passwd` existe dans plusieurs sections du manuel : la section 1 documente la commande `passwd` (changer un mot de passe), tandis que la section 5 documente le format du fichier `/etc/passwd`. Sans précision, `man` affiche la première section trouvée (généralement la 1).
2. La section 8 (commandes d'administration système, souvent réservées à root).
3. La touche `/`, suivie du mot recherché puis d'Entrée ; `n` permet ensuite de naviguer vers l'occurrence suivante.

**Bloc 2 — `--help` et `info`**
1. `--help` fournit un résumé concis des options disponibles, tandis que `man` fournit une documentation complète avec description détaillée, exemples et références croisées (`SEE ALSO`).
2. Parce que `-h` est un simple caractère d'option à un seul tiret dont la signification est définie individuellement par chaque programme ; il peut signifier « help », « human-readable », ou autre chose selon la commande.
3. La touche `q`.

**Bloc 3 — `apropos` et `whatis`**
1. `apropos` effectue une recherche par mot-clé dans l'ensemble des descriptions courtes (utile quand on ne connaît pas le nom exact de la commande) ; `whatis` affiche la description courte d'un nom de commande déjà connu.
2. `sudo mandb` (reconstruit la base de données des man pages).
3. `man -k`.

**Bloc 4 — Localiser une commande ou un fichier**
1. Parce que `cd` est une fonction intégrée au shell (**shell builtin**) et non un fichier exécutable présent dans le `PATH` ; `which` ne recherche que des exécutables sur le disque, donc il ne trouve rien (ou affiche un résultat incohérent selon le shell).
2. `whereis`.
3. La base de données utilisée par `locate` est pré-indexée (généralement mise à jour par une tâche planifiée ou manuellement via `updatedb`) : elle peut donc ne pas refléter des fichiers créés, déplacés ou supprimés très récemment, contrairement à `find` qui parcourt le système de fichiers en temps réel.

</details>