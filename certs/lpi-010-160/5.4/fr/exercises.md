# Exercices guidés – 5.4 Special Directories and Files

*Source de référence : https://learning.lpi.org/en/learning-materials/010-160/5/5.4/*

Ces exercices supposent un accès à un terminal Linux (idéalement avec les droits `sudo`) et couvrent quatre notions clés du topic 5.4 : les fichiers de configuration système liés aux comptes (`/etc/passwd`, `/etc/shadow`, `/etc/group`), les liens (hard links et symbolic links), le sticky bit, ainsi que les bits SUID et SGID.

---

## Exercice 1 : Explorer `/etc/passwd`, `/etc/shadow` et `/etc/group`

1. Affichez le contenu de `/etc/passwd` :
   ```bash
   cat /etc/passwd
   ```
2. Isolez la ligne correspondant à votre utilisateur courant :
   ```bash
   grep "^$(whoami):" /etc/passwd
   ```
   Repérez les sept champs séparés par `:` — nom d'utilisateur, mot de passe (`x`), UID, GID, commentaire (GECOS), répertoire personnel (`home directory`), shell de connexion.
3. Vérifiez les permissions du fichier :
   ```bash
   ls -l /etc/passwd
   ```
4. Tentez d'afficher `/etc/shadow` avec votre utilisateur normal :
   ```bash
   cat /etc/shadow
   ```
5. Refaites la même opération avec les privilèges administrateur :
   ```bash
   sudo cat /etc/shadow
   ```
   Observez le champ du mot de passe chiffré (haché) ainsi que les champs liés à l'expiration du mot de passe.
6. Consultez `/etc/group` et repérez un groupe dont vous êtes membre :
   ```bash
   grep "$(whoami)" /etc/group
   groups
   ```

**Questions de compréhension**

- Pourquoi le champ « mot de passe » de `/etc/passwd` contient-il généralement un simple `x` plutôt qu'un mot de passe réel ?
- Quelle différence de permissions observez-vous entre `/etc/passwd` et `/etc/shadow`, et pourquoi cette différence est-elle nécessaire du point de vue sécurité ?
- Dans `/etc/group`, à quoi correspond le dernier champ (la liste après le GID) ?

---

## Exercice 2 : Hard links vs symbolic links

1. Créez un répertoire de travail et un fichier original :
   ```bash
   mkdir -p ~/links-lab && cd ~/links-lab
   echo "contenu original" > fichier.txt
   ```
2. Créez un hard link vers ce fichier :
   ```bash
   ln fichier.txt hardlink.txt
   ```
3. Créez un symbolic link (lien symbolique) vers ce même fichier :
   ```bash
   ln -s fichier.txt symlink.txt
   ```
4. Comparez les trois entrées avec leurs inodes :
   ```bash
   ls -li
   ```
   Notez le numéro d'inode et le compteur de liens (deuxième colonne) pour `fichier.txt` et `hardlink.txt`.
5. Modifiez le contenu via le hard link, puis vérifiez le fichier original :
   ```bash
   echo "modification via hardlink" >> hardlink.txt
   cat fichier.txt
   ```
6. Supprimez le fichier original et observez ce qui arrive à chaque lien :
   ```bash
   rm fichier.txt
   cat hardlink.txt
   cat symlink.txt
   ```

**Questions de compréhension**

- Pourquoi `hardlink.txt` et `fichier.txt` partageaient-ils le même numéro d'inode avant la suppression ?
- Après la suppression de `fichier.txt`, pourquoi `symlink.txt` devient-il inutilisable (« broken link ») alors que `hardlink.txt` reste parfaitement lisible ?
- Un hard link peut-il pointer vers un fichier situé sur un autre système de fichiers (une autre partition) ? Justifiez.

---

## Exercice 3 : Le sticky bit sur `/tmp`

1. Vérifiez les permissions actuelles de `/tmp` :
   ```bash
   ls -ld /tmp
   ```
   Repérez le `t` final dans la chaîne de permissions (ex. `drwxrwxrwt`).
2. Créez un fichier de test dans `/tmp` :
   ```bash
   touch /tmp/mon_fichier_test
   ls -l /tmp/mon_fichier_test
   ```
3. Dans un répertoire personnel de test, reproduisez ce comportement :
   ```bash
   mkdir -p ~/sticky-lab && cd ~
   chmod 1777 sticky-lab
   ls -ld sticky-lab
   ```
4. Comparez la notation symbolique (`chmod 1777`) avec sa notation numérique en identifiant le chiffre représentant le sticky bit.
5. Retirez le sticky bit et observez le changement :
   ```bash
   chmod -t sticky-lab
   ls -ld sticky-lab
   ```

**Questions de compréhension**

- À quoi sert le sticky bit sur un répertoire partagé en écriture par plusieurs utilisateurs, comme `/tmp` ?
- Sans sticky bit, quel problème de sécurité pourrait survenir dans un répertoire où `others` a la permission d'écriture ?
- Quelle est la valeur numérique (octale) associée au sticky bit seul, avant de l'ajouter aux permissions classiques ?

---

## Exercice 4 : SUID et SGID

1. Repérez un exécutable système classique disposant du bit SUID, par exemple `passwd` :
   ```bash
   ls -l $(which passwd)
   ```
   Observez le `s` à la place du `x` dans les permissions du propriétaire.
2. Recherchez tous les fichiers SUID du système (cette commande peut prendre un moment) :
   ```bash
   sudo find / -xdev -perm -4000 -type f 2>/dev/null
   ```
3. Recherchez maintenant les fichiers SGID :
   ```bash
   sudo find / -xdev -perm -2000 -type f 2>/dev/null
   ```
4. Créez un script de test et positionnez le bit SUID dessus :
   ```bash
   cd ~/links-lab
   echo -e '#!/bin/bash\nwhoami' > test_suid.sh
   chmod +x test_suid.sh
   chmod u+s test_suid.sh
   ls -l test_suid.sh
   ```
5. Exécutez le script et observez le résultat de `whoami` :
   ```bash
   ./test_suid.sh
   ```

**Questions de compréhension**

- Concrètement, que change le bit SUID lors de l'exécution d'un programme, par rapport à une exécution sans ce bit ?
- Pourquoi la commande `passwd` a-t-elle besoin du bit SUID pour fonctionner correctement pour un utilisateur non privilégié ?
- Quelle est la différence fonctionnelle entre le bit SUID (appliqué à un fichier exécutable) et le bit SGID appliqué à un répertoire ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Exercice 1**

- Le `x` remplace l'ancien emplacement du mot de passe haché : celui-ci a été déplacé vers `/etc/shadow`, un fichier non lisible par les utilisateurs ordinaires, afin d'éviter qu'un hash de mot de passe (potentiellement cassable par force brute) soit accessible à tout le monde, puisque `/etc/passwd` doit rester lisible par tous (`world-readable`) pour que des commandes comme `ls -l` puissent résoudre les UID en noms d'utilisateur.
- `/etc/passwd` est lisible par tous (permissions typiques `644`), alors que `/etc/shadow` n'est lisible que par `root` (permissions typiques `640` ou `600`, appartenant souvent au groupe `shadow`). Cette restriction protège les hashs de mots de passe contre une lecture par des utilisateurs non privilégiés.
- Ce dernier champ liste les membres additionnels du groupe (des utilisateurs qui appartiennent à ce groupe en tant que groupe secondaire), séparés par des virgules.

**Exercice 2**

- Parce qu'un hard link n'est pas une copie : c'est une deuxième entrée de répertoire (un deuxième nom) qui pointe vers le même inode, donc vers les mêmes données sur le disque.
- Un symbolic link ne contient qu'un chemin texte vers la cible ; quand la cible disparaît, le lien symbolique pointe vers un chemin inexistant (« lien cassé »). Un hard link, lui, pointe directement sur les données via l'inode ; tant qu'il reste au moins un nom (un lien) pointant vers cet inode, les données restent accessibles, même après suppression du nom original.
- Non. Un hard link doit résider sur le même système de fichiers (même partition) que sa cible, car les numéros d'inode ne sont uniques qu'au sein d'un même système de fichiers. Un symbolic link, en revanche, peut traverser les systèmes de fichiers puisqu'il ne fait que stocker un chemin.

**Exercice 3**

- Le sticky bit empêche un utilisateur de supprimer ou renommer les fichiers appartenant à un autre utilisateur dans ce répertoire, même s'il a la permission d'écriture sur le répertoire lui-même. Seul le propriétaire du fichier (ou root) peut le supprimer.
- Sans sticky bit, n'importe quel utilisateur ayant un accès en écriture au répertoire pourrait supprimer ou renommer les fichiers créés par d'autres utilisateurs, ce qui poserait un risque évident dans un répertoire partagé comme `/tmp`.
- La valeur octale du sticky bit seul est `1000` (c'est le chiffre le plus à gauche dans une notation à quatre chiffres, comme dans `1777`).

**Exercice 4**

- Avec le bit SUID activé, le programme s'exécute avec les privilèges du propriétaire du fichier (souvent `root`) plutôt qu'avec les privilèges de l'utilisateur qui le lance. C'est pour cela que la commande `whoami` exécutée depuis `test_suid.sh` peut afficher un identifiant différent de celui de l'utilisateur réel selon le propriétaire du script.
- `passwd` doit pouvoir écrire dans `/etc/shadow`, un fichier réservé à `root`. Grâce au SUID, un utilisateur normal qui exécute `passwd` obtient temporairement les privilèges du propriétaire du binaire (`root`) le temps de modifier son propre mot de passe, sans avoir besoin d'un accès root permanent.
- Sur un fichier exécutable, le SUID fait s'exécuter le programme avec l'identité du propriétaire du fichier. Sur un répertoire, le SGID fait en sorte que tout nouveau fichier ou sous-répertoire créé à l'intérieur hérite automatiquement du groupe propriétaire du répertoire parent, plutôt que du groupe principal de l'utilisateur créateur — utile pour le travail collaboratif entre membres d'un même groupe.

</details>