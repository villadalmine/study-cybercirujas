# Exercices guidés — 5.2 Creating Users and Groups

*LPI Linux Essentials (010-160 v1.6) — Sources de référence : [learning.lpi.org/en/learning-materials/010-160/5/5.2/](https://learning.lpi.org/en/learning-materials/010-160/5/5.2/)*

> Les commandes suivantes doivent être exécutées en tant que `root` ou via `sudo`, idéalement dans une VM ou un conteneur jetable pour ne pas perturber un système de production.

## Bloc 1 — Explorer les fichiers de comptes existants

1. Affichez le contenu du fichier qui liste tous les comptes utilisateurs du système :
   ```bash
   cat /etc/passwd
   ```
2. Repérez votre propre ligne dans la sortie (cherchez votre nom de login) et identifiez ses sept champs séparés par `:` (login, mot de passe, UID, GID, commentaire/GECOS, home directory, shell).
3. Affichez le fichier qui stocke les mots de passe chiffrés :
   ```bash
   sudo cat /etc/shadow
   ```
4. Affichez le fichier qui liste les groupes du système :
   ```bash
   cat /etc/group
   ```

**Questions de compréhension**
- Que signifie le caractère `x` dans le deuxième champ d'une ligne de `/etc/passwd` ?
- Pourquoi `/etc/shadow` n'est-il lisible que par `root`, contrairement à `/etc/passwd` qui est lisible par tous ?
- Dans `/etc/group`, à quoi sert la liste de noms d'utilisateurs qui apparaît en dernier champ ?

---

## Bloc 2 — Créer un utilisateur avec `useradd`

1. Créez un nouvel utilisateur nommé `stagiaire`, avec création automatique de son home directory :
   ```bash
   sudo useradd -m stagiaire
   ```
2. Vérifiez que la ligne correspondante a bien été ajoutée à `/etc/passwd` :
   ```bash
   grep stagiaire /etc/passwd
   ```
3. Vérifiez que le home directory a été créé, avec les fichiers de configuration par défaut copiés depuis `/etc/skel` :
   ```bash
   ls -la /home/stagiaire
   ```
4. Définissez un mot de passe pour ce compte :
   ```bash
   sudo passwd stagiaire
   ```
5. Consultez l'entrée correspondante dans `/etc/shadow` pour observer que le mot de passe est bien stocké sous forme chiffrée :
   ```bash
   sudo grep stagiaire /etc/shadow
   ```

**Questions de compréhension**
- Que se serait-il passé si vous aviez exécuté `useradd stagiaire` sans l'option `-m` ?
- D'où proviennent les fichiers que vous observez dans `/home/stagiaire` juste après la création du compte ?
- À quoi correspond le champ `UID` attribué automatiquement à `stagiaire` — est-il probable qu'il soit inférieur à 1000 ?

---

## Bloc 3 — Créer un groupe et gérer l'appartenance

1. Créez un nouveau groupe nommé `formation` :
   ```bash
   sudo groupadd formation
   ```
2. Vérifiez son ajout dans `/etc/group` :
   ```bash
   grep formation /etc/group
   ```
3. Ajoutez l'utilisateur `stagiaire` à ce groupe en tant que groupe secondaire, sans perdre ses autres appartenances :
   ```bash
   sudo usermod -aG formation stagiaire
   ```
4. Confirmez l'appartenance au groupe :
   ```bash
   groups stagiaire
   id stagiaire
   ```

**Questions de compréhension**
- Que risquez-vous si vous utilisez `usermod -G formation stagiaire` sans l'option `-a` alors que l'utilisateur appartenait déjà à d'autres groupes secondaires ?
- Quelle est la différence entre le groupe primaire et un groupe secondaire visible dans la sortie de `id stagiaire` ?
- Quelle commande alternative à `usermod -aG` permet aussi d'ajouter un utilisateur à un groupe existant ?

---

## Bloc 4 — Consulter l'activité des comptes

1. Affichez l'historique des connexions récentes sur le système :
   ```bash
   last
   ```
2. Filtrez cet historique pour ne voir que les connexions de l'utilisateur `stagiaire` :
   ```bash
   last stagiaire
   ```

**Question de compréhension**
- Quel fichier journal la commande `last` consulte-t-elle pour produire son résultat ?

---

## Bloc 5 — Modifier et supprimer utilisateur et groupe

1. Modifiez le commentaire (champ GECOS) de `stagiaire` pour y indiquer son nom complet :
   ```bash
   sudo usermod -c "Jean Dupont" stagiaire
   ```
2. Vérifiez le changement :
   ```bash
   grep stagiaire /etc/passwd
   ```
3. Supprimez le compte `stagiaire`, en supprimant également son home directory :
   ```bash
   sudo userdel -r stagiaire
   ```
4. Confirmez que l'utilisateur n'apparaît plus dans `/etc/passwd` ni son home directory sur le disque :
   ```bash
   grep stagiaire /etc/passwd
   ls /home/stagiaire
   ```
5. Supprimez enfin le groupe `formation`, devenu inutile :
   ```bash
   sudo groupdel formation
   ```

**Questions de compréhension**
- Que se passe-t-il si vous exécutez `userdel stagiaire` (sans `-r`) : le home directory est-il conservé ou supprimé ?
- Pourquoi `groupdel` peut-il échouer si le groupe ciblé est encore le groupe primaire d'un utilisateur existant ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Bloc 1**
- Le `x` indique que le mot de passe chiffré n'est pas stocké dans `/etc/passwd` mais délégué à `/etc/shadow`, un fichier protégé.
- `/etc/passwd` doit rester lisible par tous les processus et utilitaires du système (par exemple pour résoudre un UID en nom de login), alors que `/etc/shadow` contient les hachages de mots de passe et doit rester confidentiel pour limiter les attaques hors ligne (offline cracking).
- Cette liste ajoute des membres secondaires au groupe : des utilisateurs dont ce groupe n'est pas le groupe primaire, mais qui en héritent tout de même les permissions.

**Bloc 2**
- Sans `-m`, le compte aurait été créé dans `/etc/passwd` mais aucun home directory n'aurait été créé automatiquement sur le disque.
- Ils proviennent du répertoire modèle `/etc/skel`, copié automatiquement dans le home directory lors de la création du compte avec `-m`.
- Oui, généralement les comptes créés par `useradd` reçoivent un UID à partir de 1000 (selon `/etc/login.defs`), les UID inférieurs à 1000 étant réservés aux comptes système.

**Bloc 3**
- Sans `-a`, `usermod -G` remplace entièrement la liste des groupes secondaires par celle fournie, ce qui retire l'utilisateur de tous les groupes secondaires auxquels il appartenait auparavant.
- Le groupe primaire est celui indiqué par le GID dans `/etc/passwd` et apparaît en premier dans la sortie de `id` (`gid=...`) ; les groupes secondaires apparaissent dans la liste `groups=...`.
- La commande `gpasswd -a stagiaire formation` permet aussi d'ajouter un utilisateur à un groupe existant.

**Bloc 4**
- `last` lit le fichier binaire `/var/log/wtmp`, qui enregistre l'historique des connexions et déconnexions.

**Bloc 5**
- Sans `-r`, `userdel` supprime uniquement l'entrée du compte dans `/etc/passwd` (et `/etc/shadow`), mais conserve le home directory et son contenu sur le disque.
- `groupdel` refuse de supprimer un groupe qui est encore défini comme groupe primaire (GID) d'un utilisateur existant, car cela laisserait cet utilisateur sans groupe primaire valide ; il faut d'abord changer son groupe primaire.

</details>