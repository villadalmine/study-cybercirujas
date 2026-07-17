# 3.2 Searching and Extracting Data from Files

**Examen :** LPI Linux Essentials (010-160, version 1.6) · **Poids :** 3
**Domaines clés :** *pipes* en ligne de commande, redirection d'entrée-sortie (*I/O redirection*), expressions régulières de base (*basic regular expressions*)
**Commandes concernées :** `cat`, `less`, `head`, `tail`, `sort`, `cut`, `wc`, `grep`, ainsi que les opérateurs `>`, `>>`, `<`, `2>`, `|`

---

La philosophie Unix tient en une phrase : des programmes qui font une seule chose, la font bien, et communiquent entre eux via du texte brut. Ce thème couvre les trois mécanismes qui rendent cette philosophie utilisable au quotidien : la **redirection** (rediriger l'entrée ou la sortie d'une commande vers un fichier), les ***pipes*** (relier directement la sortie d'une commande à l'entrée d'une autre) et la **recherche de motifs** avec `grep` et les expressions régulières. Ensemble, ils permettent de répondre à des questions comme « quels comptes ont un shell interactif ? » ou « combien d'erreurs y a-t-il eu cette nuit ? » en une seule ligne de commande.

## 1. Les trois flux standards

Tout programme lancé sous Linux hérite automatiquement de trois canaux de communication, appelés ***file descriptors*** :

| Flux | Nom | Numéro | Destination par défaut |
|------|-----|--------|-------------------------|
| *stdin* | entrée standard | 0 | le clavier |
| *stdout* | sortie standard | 1 | l'écran du terminal |
| *stderr* | sortie d'erreur | 2 | l'écran du terminal |

`stdout` transporte les résultats normaux, `stderr` transporte les messages d'erreur. Les deux s'affichent à l'écran par défaut, mais ce sont des canaux **indépendants** : on peut donc les rediriger séparément. C'est cette séparation qui rend possible tout ce qui suit.

## 2. La redirection des flux

### 2.1 Rediriger *stdout* : `>` et `>>`

L'opérateur `>` envoie la sortie standard vers un fichier au lieu de l'écran. **Il écrase le fichier s'il existe déjà.**

```
$ echo "première ligne" > memo.txt
$ cat memo.txt
première ligne
$ echo "remplacé !" > memo.txt
$ cat memo.txt
remplacé !
```

L'opérateur `>>` **ajoute** à la fin du fichier au lieu de l'écraser :

```
$ echo "un" >> journal.txt
$ echo "deux" >> journal.txt
$ cat journal.txt
un
deux
```

Les deux opérateurs créent le fichier s'il n'existe pas encore.

### 2.2 Rediriger *stderr* : `2>` et `2>&1`

Les messages d'erreur voyagent sur le descripteur 2 : `>` seul ne les capture donc pas.

```
$ ls /repertoire/inexistant > sortie.txt
ls: impossible d'accéder à '/repertoire/inexistant' : Aucun fichier ou dossier de ce type
```

L'erreur s'est quand même affichée à l'écran, et `sortie.txt` est vide. Pour capturer l'erreur, il faut rediriger explicitement le descripteur 2 :

```
$ ls /repertoire/inexistant 2> erreurs.txt
$ cat erreurs.txt
ls: impossible d'accéder à '/repertoire/inexistant' : Aucun fichier ou dossier de ce type
```

On peut rediriger les deux flux vers deux fichiers différents en même temps :

```
$ find /etc -name shadow > trouves.txt 2> refuses.txt
```

Pour fusionner les deux flux dans un seul fichier, on redirige `stderr` vers l'endroit où pointe déjà `stdout`, avec `2>&1` :

```
$ find /etc -name shadow > tout.txt 2>&1
```

**Attention à l'ordre :** `commande > fichier 2>&1` fonctionne, mais `commande 2>&1 > fichier` ne fusionne pas les flux — au moment où `2>&1` s'exécute, `stdout` pointe encore vers le terminal.

Une astuce courante consiste à jeter les erreurs indésirables vers `/dev/null`, un périphérique spécial qui absorbe silencieusement tout ce qu'on y écrit :

```
$ find / -name "*.conf" 2> /dev/null
```

### 2.3 Rediriger *stdin* : `<`

L'opérateur `<` fait lire à une commande le contenu d'un fichier comme entrée standard, plutôt que de le passer en argument. Certaines commandes se comportent différemment selon le cas — `wc` en est un bon exemple :

```
$ wc -l /etc/passwd
38 /etc/passwd
$ wc -l < /etc/passwd
38
```

Avec `<`, `wc` ne connaît jamais le nom du fichier : elle n'affiche que le nombre, sans nom de fichier à côté. C'est utile quand on veut réutiliser cette valeur telle quelle, par exemple dans une variable.

### 2.4 Le *here document* : `<<`

Un ***here document*** permet de fournir un bloc de texte multi-lignes directement en entrée, jusqu'à un mot délimiteur choisi :

```
$ wc -l << FIN
> première ligne
> deuxième ligne
> troisième ligne
> FIN
3
```

### Résumé des opérateurs de redirection

| Opérateur | Effet |
|-----------|-------|
| `> fichier` | *stdout* vers un fichier (écrase) |
| `>> fichier` | *stdout* vers un fichier (ajoute) |
| `2> fichier` | *stderr* vers un fichier (écrase) |
| `2>> fichier` | *stderr* vers un fichier (ajoute) |
| `2>&1` | fusionne *stderr* dans *stdout* |
| `< fichier` | le fichier devient *stdin* |
| `<< MOT` | *here document* (entrée en ligne) |

## 3. Les *pipes* (`|`)

L'opérateur *pipe* `|` connecte la sortie standard d'une commande directement à l'entrée standard de la suivante, sans passer par un fichier intermédiaire.

```
$ cat /etc/passwd | wc -l
38
```

On peut enchaîner autant de *pipes* que nécessaire pour former un **pipeline**, chaque étape affinant un peu plus le résultat :

```
$ cat /etc/passwd | grep bash | cut -d: -f1 | sort
alice
bob
root
```

Ce pipeline lit la base des comptes, ne garde que les lignes mentionnant `bash`, extrait le premier champ séparé par `:` (le nom d'utilisateur), puis trie le résultat par ordre alphabétique.

Seul **`stdout`** transite par un *pipe* : `stderr` continue de s'afficher à l'écran, même au milieu d'un pipeline. Pour envoyer les deux flux dans un pipeline, il faut d'abord les fusionner : `commande 2>&1 | less`.

## 4. Commandes de visualisation et d'extraction

Ces utilitaires sont les briques de base qu'on assemble à l'intérieur des pipelines.

### 4.1 `cat` — concaténer et afficher

```
$ cat /etc/hostname
serveur-web
```

`cat fichier1 fichier2` affiche les fichiers l'un après l'autre — d'où le nom, contraction de *concatenate*.

### 4.2 `less` — parcourir un contenu long page par page

`less` affiche un fichier (ou une entrée reçue par *pipe*) un écran à la fois. Navigation : les flèches ou `Espace` (page suivante), `/motif` (rechercher vers l'avant), `n` (occurrence suivante), `q` (quitter).

```
$ less /var/log/syslog
$ dmesg | less
```

### 4.3 `head` et `tail` — début et fin d'un fichier

Les deux affichent 10 lignes par défaut ; l'option `-n` change ce nombre.

```
$ head -n 3 /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin

$ tail -n 2 /etc/passwd
alice:x:1000:1000:Alice:/home/alice:/bin/bash
bob:x:1001:1001:Bob:/home/bob:/bin/bash
```

`tail -f` (*follow*) continue d'afficher les nouvelles lignes au fur et à mesure qu'elles sont ajoutées au fichier — précieux pour surveiller un journal en direct :

```
$ tail -f /var/log/syslog
```

### 4.4 `sort` — trier des lignes

```
$ sort noms.txt          # ordre alphabétique
$ sort -r noms.txt       # ordre inverse
$ sort -n tailles.txt    # tri numérique (10 après 9, pas après 1)
$ sort -u noms.txt       # trie et supprime les doublons
```

Pourquoi `-n` compte :

```
$ printf "10\n9\n2\n" | sort
10
2
9
$ printf "10\n9\n2\n" | sort -n
2
9
10
```

Sans `-n`, `sort` compare les lignes comme du texte, caractère par caractère : `"10"` passe avant `"2"` parce que `1` précède `2` dans l'ordre des caractères.

### 4.5 `cut` — extraire des colonnes

`cut` découpe chaque ligne selon un délimiteur et un numéro de champ (`-d` et `-f`), ou selon une position de caractère (`-c`).

```
$ cut -d: -f1,7 /etc/passwd | head -n 3
root:/bin/bash
daemon:/usr/sbin/nologin
bin:/usr/sbin/nologin

$ echo "20260711" | cut -c 1-4
2026
```

### 4.6 `wc` — compter lignes, mots et octets

Par défaut, `wc` affiche lignes, mots puis octets. Options individuelles : `-l` (lignes), `-w` (mots), `-c` (octets).

```
$ wc /etc/passwd
 38  59 2014 /etc/passwd
$ grep bash /etc/passwd | wc -l
3
```

## 5. Rechercher avec `grep`

`grep` lit des lignes depuis un fichier ou depuis `stdin`, et n'affiche que celles qui correspondent à un **motif** (*pattern*).

```
$ grep bash /etc/passwd
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000:Alice:/home/alice:/bin/bash
bob:x:1001:1001:Bob:/home/bob:/bin/bash
```

Options fréquemment demandées à l'examen :

| Option | Signification |
|--------|----------------|
| `-i` | ignore la casse (*case-insensitive*) |
| `-v` | inverse : n'affiche que les lignes qui **ne** correspondent **pas** |
| `-c` | affiche uniquement le nombre de lignes correspondantes |
| `-n` | préfixe chaque résultat par son numéro de ligne |
| `-r` | recherche récursive dans un répertoire |
| `-w` | ne fait correspondre que des mots entiers |
| `-E` | active les expressions régulières étendues (*extended regex*) |

Exemples :

```
$ grep -i erreur /var/log/syslog        # ERREUR, Erreur, erreur...
$ grep -v nologin /etc/passwd            # comptes avec un vrai shell
$ grep -c bash /etc/passwd
3
$ grep -rn "PermitRootLogin" /etc/ssh/
/etc/ssh/sshd_config:34:#PermitRootLogin prohibit-password
```

## 6. Les expressions régulières de base (*Basic Regular Expressions*)

Une **expression régulière** (*regex*) est un motif qui décrit un ensemble de chaînes de caractères possibles. Par défaut, `grep` interprète son motif comme une *basic regular expression* (BRE). L'examen attend la maîtrise des métacaractères suivants :

| Métacaractère | Signification |
|----------------|----------------|
| `.` | un caractère quelconque, exactement un |
| `[abc]` | un caractère parmi ceux listés |
| `[a-z]` | un caractère dans l'intervalle donné |
| `[^abc]` | un caractère **absent** de la liste |
| `*` | zéro ou plusieurs répétitions de l'élément **précédent** |
| `^` | ancre : début de ligne |
| `$` | ancre : fin de ligne |
| `?` | zéro ou une occurrence (*extended regex*, avec `grep -E`) |

> **Piège classique :** le `*` d'une regex n'a rien à voir avec le *globbing* du shell. En *globbing*, `*` seul veut dire « n'importe quoi » ; en regex, `*` est un quantificateur qui s'applique à l'élément juste avant lui. « N'importe quelle suite de caractères » s'écrit `.*` en regex.

### Exemples avec un fichier d'exemple

```
$ cat mots.txt
tag
trag
traag
trg
bag
```

**`.` — un caractère quelconque :**

```
$ grep 't.g' mots.txt
tag
trg
```

(`t.g` cherche un `t`, puis n'importe quel caractère, puis un `g` : cela correspond à `tag` — avec `a` au milieu — et à `trg` — avec `r` au milieu — mais pas à `trag` ni `traag`, où plus d'un caractère sépare le `t` du `g`.)

**`*` — zéro ou plusieurs répétitions de l'élément précédent :**

```
$ grep 'tra*g' mots.txt
trag
traag
trg
```

(Le motif cherche `t`, `r`, puis zéro ou plusieurs `a`, puis `g`. `trg` correspond avec zéro `a` ; `trag` avec un `a` ; `traag` avec deux `a`. `tag` et `bag` ne correspondent pas : il n'y a pas de `r` littéral dedans.)

**`^` et `$` — ancrer en début et fin de ligne :**

```
$ grep '^tr' mots.txt
trag
traag
trg
$ grep 'g$' mots.txt
tag
trag
traag
trg
bag
```

Utilisation pratique de ces ancres — retrouver les comptes dont le shell est Bash, en s'assurant que la correspondance se fait bien en fin de ligne :

```
$ grep ':/bin/bash$' /etc/passwd
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000:Alice:/home/alice:/bin/bash
```

**`[ ]` — ensemble de caractères :**

```
$ grep '[tb]ag' mots.txt
tag
bag
```

**`?` — zéro ou une occurrence (nécessite l'*extended regex*, `grep -E`) :**

```
$ printf "http://exemple.com\nhttps://exemple.com\n" | grep -E 'https?://'
http://exemple.com
https://exemple.com
```

**Astuce de *quoting* :** toujours entourer le motif de guillemets simples (`grep 'motif' fichier`) pour empêcher le shell d'interpréter des métacaractères comme `*` avant même que `grep` ne voie le motif.

## 7. Tout assembler

Quelques lignes de commande réalistes qui combinent redirection, *pipes* et recherche :

```
# Compter les comptes qui ne peuvent pas ouvrir de session interactive
$ grep -c 'nologin$' /etc/passwd
31

# Les 5 premiers noms d'utilisateur, triés, enregistrés dans un fichier
$ cut -d: -f1 /etc/passwd | sort | head -n 5 > premiers_users.txt

# Surveiller un journal en direct et ne garder que les erreurs
$ tail -f /var/log/syslog | grep -i erreur

# Compter les fichiers .conf sous /etc, sans afficher les refus d'accès
$ find /etc -name '*.conf' 2> /dev/null | wc -l
97
```

## 8. Résumé pour l'examen

- Trois flux : `stdin` (0), `stdout` (1), `stderr` (2) — l'écran par défaut pour les deux derniers.
- `>` **écrase**, `>>` **ajoute** — distinction classique à l'examen.
- `2>` redirige les erreurs ; `2>&1` fusionne `stderr` dans `stdout` ; `< fichier` fournit l'entrée.
- Un *pipe* `|` ne transporte que **`stdout`** vers l'entrée de la commande suivante.
- `head`/`tail` affichent **10 lignes** par défaut ; `tail -f` suit un fichier qui grandit.
- `cut -d: -f1 /etc/passwd` est l'exemple canonique d'extraction de champ.
- En BRE : `.` = un caractère, `[ ]` = ensemble de caractères, `*` = zéro ou plusieurs répétitions de l'élément **précédent**, `^`/`$` = ancres de ligne, `?` = optionnel (nécessite `grep -E`).
- `/dev/null` absorbe tout ce qu'on y écrit — utilisé couramment en `2> /dev/null` pour ignorer des erreurs attendues.

## Références

- LPI Learning Materials, Linux Essentials 010-160, Topic 3.2 — Searching and Extracting Data from Files : https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- LPI Linux Essentials Exam Objectives (version 1.6) : https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Grep Manual : https://www.gnu.org/software/grep/manual/grep.html
- GNU Coreutils Manual (`cat`, `head`, `tail`, `sort`, `cut`, `wc`) : https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU Bash Manual — Redirections : https://www.gnu.org/software/bash/manual/html_node/Redirections.html