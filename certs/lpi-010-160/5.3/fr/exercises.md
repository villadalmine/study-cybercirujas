# Thème 5.3 – Managing File Permissions and Ownership

*Source de référence : https://learning.lpi.org/en/learning-materials/010-160/5/5.3/*

---

## Exercice 1 – Lire les permissions avec `ls -l`

1. Ouvrez un terminal et déplacez-vous dans votre répertoire personnel :
   ```bash
   cd ~
   ```
2. Créez un fichier vide et un répertoire de test :
   ```bash
   touch demo.txt
   mkdir demo_dir
   ```
3. Affichez le détail de ces deux objets :
   ```bash
   ls -l demo.txt demo_dir
   ```
4. Observez la première colonne (par exemple `-rw-r--r--` ou `drwxr-xr-x`) et identifiez les trois groupes de trois caractères qui la composent.
5. Affichez votre identité (user ID, group ID et groupes secondaires) :
   ```bash
   id
   ```

**Questions :**
- À quoi correspond le tout premier caractère de la colonne des permissions (`-` ou `d`) ?
- Une permission `rwxr-xr-x` : quels droits ont respectivement le owner, le group et les others sur cet objet ?

---

## Exercice 2 – Modifier les permissions en mode symbolique (chmod)

1. Vérifiez les permissions actuelles de `demo.txt` :
   ```bash
   ls -l demo.txt
   ```
2. Retirez le droit de lecture au group et aux others :
   ```bash
   chmod go-r demo.txt
   ```
3. Ajoutez le droit d'exécution pour le owner :
   ```bash
   chmod u+x demo.txt
   ```
4. Définissez exactement `rw-r--r--` en une seule commande :
   ```bash
   chmod u=rw,g=r,o=r demo.txt
   ```
5. Vérifiez le résultat après chaque commande avec `ls -l demo.txt`.

**Questions :**
- Quelle est la différence entre les opérateurs `+`, `-` et `=` en mode symbolique ?
- Que fait la lettre `a` dans une expression comme `chmod a+x script.sh` ?

---

## Exercice 3 – Modifier les permissions en mode numérique (octal)

1. Rappelez-vous la valeur numérique de chaque droit : `read = 4`, `write = 2`, `execute = 1`.
2. Donnez à `demo.txt` les permissions `rw-r--r--` en octal :
   ```bash
   chmod 644 demo.txt
   ```
3. Donnez à `demo_dir` les permissions `rwxr-xr-x` :
   ```bash
   chmod 755 demo_dir
   ```
4. Retirez tout accès aux others sur `demo.txt` :
   ```bash
   chmod 640 demo.txt
   ```
5. Confirmez chaque changement avec `ls -l`.

**Questions :**
- Quelle valeur octale correspond à la permission `rwx------` ?
- Pourquoi les répertoires ont-ils presque toujours le bit `execute` activé, contrairement à beaucoup de fichiers texte ?

---

## Exercice 4 – Changer le owner et le group (chown, chgrp)

1. Affichez la liste des groupes existants sur le système :
   ```bash
   cat /etc/group | head
   ```
2. Vérifiez le owner et le group actuels de `demo.txt` :
   ```bash
   ls -l demo.txt
   ```
3. En tant que root (ou avec `sudo`), changez le group de `demo.txt` :
   ```bash
   sudo chgrp adm demo.txt
   ```
4. Changez simultanément le owner et le group avec `chown` :
   ```bash
   sudo chown root:adm demo.txt
   ```
5. Appliquez un changement de owner de façon récursive sur `demo_dir` :
   ```bash
   sudo chown -R root:adm demo_dir
   ```

**Questions :**
- Pourquoi `chown` et `chgrp` nécessitent-ils en général les privilèges de root ?
- Quelle option de `chown` permet de propager le changement à tout le contenu d'un répertoire ?

---

## Exercice 5 – Comprendre et modifier l'umask

1. Affichez la valeur actuelle de l'umask :
   ```bash
   umask
   ```
2. Créez un nouveau fichier et un nouveau répertoire, puis observez leurs permissions par défaut :
   ```bash
   touch test_umask.txt
   mkdir test_umask_dir
   ls -l test_umask.txt test_umask_dir
   ```
3. Changez temporairement l'umask pour la session courante :
   ```bash
   umask 027
   ```
4. Recréez un fichier et un répertoire, puis comparez leurs permissions avec celles de l'étape 2 :
   ```bash
   touch test_umask2.txt
   mkdir test_umask2_dir
   ls -l test_umask2.txt test_umask2_dir
   ```

**Questions :**
- Pourquoi un fichier créé avec `umask 022` obtient-il `rw-r--r--` alors qu'un répertoire obtient `rwxr-xr-x` ?
- Que représente concrètement la valeur de l'umask : des permissions à accorder, ou des permissions à soustraire ?

---

## Exercice 6 – Reconnaître setuid, setgid et le sticky bit

1. Repérez un exécutable système possédant le setuid bit :
   ```bash
   ls -l /usr/bin/passwd
   ```
2. Identifiez dans la sortie le caractère `s` à la place du `x` du owner.
3. Repérez un répertoire possédant le sticky bit, comme `/tmp` :
   ```bash
   ls -ld /tmp
   ```
4. Sur un fichier vous appartenant, essayez d'ajouter le setgid bit en mode symbolique :
   ```bash
   chmod g+s demo_dir
   ls -ld demo_dir
   ```
5. Ajoutez cette fois le sticky bit sur `demo_dir` en mode octal (valeur du bit spécial en préfixe) :
   ```bash
   chmod 1755 demo_dir
   ls -ld demo_dir
   ```

**Questions :**
- Quel est l'effet du setuid bit lorsqu'il est positionné sur un exécutable comme `/usr/bin/passwd` ?
- Dans un répertoire partagé possédant le sticky bit (comme `/tmp`), qui a le droit de supprimer un fichier appartenant à un autre utilisateur ?
- Quelle est la différence de comportement entre le setgid bit posé sur un fichier et le même bit posé sur un répertoire ?

---

<details>
<summary>Réponses</summary>

**Exercice 1**
- Le premier caractère indique le type d'objet : `-` pour un fichier régulier, `d` pour un répertoire (aussi `l` pour un lien symbolique, etc.).
- `rwxr-xr-x` : le owner a read, write et execute ; le group a read et execute ; les others ont read et execute.

**Exercice 2**
- `+` ajoute un droit, `-` le retire, `=` fixe exactement l'ensemble des droits indiqués (en supprimant les autres non mentionnés pour cette classe).
- `a` signifie "all" : elle applique le changement au owner, au group et aux others simultanément.

**Exercice 3**
- `rwx------` correspond à `700` (4+2+1 = 7 pour le owner, 0 pour group et others).
- Le bit execute sur un répertoire permet d'y entrer (`cd`) et d'accéder à son contenu (le traverser) ; beaucoup de fichiers texte n'ont pas besoin d'être "exécutés", donc ce bit reste inutile pour eux, contrairement aux scripts ou binaires.

**Exercice 4**
- Parce que changer le owner ou le group d'un fichier est une opération sensible pour la sécurité (cela peut donner accès à des ressources à un autre utilisateur) ; par défaut seul root peut réattribuer un fichier à un owner arbitraire.
- L'option `-R` (récursive) applique le changement à un répertoire et à tout son contenu.

**Exercice 5**
- L'umask soustrait des droits aux permissions maximales par défaut : `666` pour les fichiers et `777` pour les répertoires. Avec `umask 022`, on soustrait `022` à `666`, ce qui donne `644` (`rw-r--r--`) pour un fichier, et `022` à `777`, ce qui donne `755` (`rwxr-xr-x`) pour un répertoire.
- L'umask représente des permissions à soustraire (un masque de restriction), pas des permissions à accorder.

**Exercice 6**
- Le setuid bit fait que l'exécutable s'exécute avec les privilèges du owner du fichier (souvent root) plutôt qu'avec ceux de l'utilisateur qui le lance ; c'est ce qui permet à `passwd` de modifier `/etc/shadow` bien qu'il soit lancé par un utilisateur normal.
- Avec le sticky bit, dans un répertoire partagé en écriture, seul le owner du fichier (ou root, ou le owner du répertoire) peut supprimer ou renommer ce fichier, même si d'autres utilisateurs ont un accès en écriture au répertoire.
- Sur un fichier exécutable, le setgid bit fait que le programme s'exécute avec les privilèges du group du fichier. Sur un répertoire, il fait que tout nouveau fichier ou sous-répertoire créé à l'intérieur hérite automatiquement du group du répertoire parent plutôt que du group primaire de l'utilisateur créateur.

</details>