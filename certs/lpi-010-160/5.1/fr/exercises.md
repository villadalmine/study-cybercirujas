# 5.1 Basic Security and Identifying User Types

Source : https://learning.lpi.org/en/learning-materials/010-160/5/5.1/

## Exercice 1 : Identifier son utilisateur et ses privilèges

1. Ouvrez un terminal sur votre machine Linux.
2. Affichez le nom de l'utilisateur actuellement connecté :
   ```
   whoami
   ```
3. Affichez les informations complètes de votre identité (UID, GID, groupes) :
   ```
   id
   ```
4. Listez les groupes auxquels vous appartenez :
   ```
   groups
   ```
5. Comparez la valeur de votre UID à 0. Sur la quasi-totalité des distributions Linux, l'UID 0 est réservé à un seul compte : le superuser, appelé root.

**Questions**
- Quelle est la différence fondamentale entre le compte root et un compte utilisateur standard (standard user) en termes de privilèges ?
- Si la commande `id` renvoie `uid=0(root)`, qu'est-ce que cela implique pour les actions que cet utilisateur peut effectuer sur le système ?

## Exercice 2 : Distinguer les types de comptes dans /etc/passwd

1. Affichez le contenu du fichier `/etc/passwd` :
   ```
   cat /etc/passwd
   ```
2. Observez la structure de chaque ligne, séparée par des deux-points (`:`) : nom d'utilisateur, mot de passe (placeholder), UID, GID, commentaire (GECOS), répertoire personnel (home directory), shell.
3. Repérez la ligne correspondant à root (UID 0).
4. Repérez des lignes avec un UID inférieur à 1000 (souvent entre 1 et 999) : ce sont des system users ou service accounts, créés automatiquement par des paquets ou services (par exemple `daemon`, `bin`, `sshd`).
5. Repérez votre propre ligne, avec un UID généralement supérieur ou égal à 1000 : c'est un compte utilisateur standard (regular user).
6. Filtrez les comptes dont le shell est `/bin/false` ou `/usr/sbin/nologin` :
   ```
   grep -E '/false|nologin' /etc/passwd
   ```

**Questions**
- Pourquoi le champ mot de passe de `/etc/passwd` affiche-t-il un simple `x` plutôt qu'un mot de passe réel ou son hash ?
- À quoi sert un shell comme `/usr/sbin/nologin` associé à un compte système ?

## Exercice 3 : Explorer /etc/shadow et la politique de mots de passe

1. Essayez d'afficher le fichier `/etc/shadow` en tant qu'utilisateur standard :
   ```
   cat /etc/shadow
   ```
2. Observez le message d'erreur (Permission denied) : ce fichier n'est lisible que par root, contrairement à `/etc/passwd`.
3. Affichez maintenant son contenu avec des privilèges élevés :
   ```
   sudo cat /etc/shadow
   ```
4. Repérez votre propre ligne. Le deuxième champ contient le hash du mot de passe (ou `!`, `*` si le compte est verrouillé ou n'a pas de mot de passe défini).
5. Consultez les informations de vieillissement (aging) de votre mot de passe :
   ```
   sudo chage -l $(whoami)
   ```

**Questions**
- Pourquoi le fait de séparer les hashs de mots de passe dans `/etc/shadow`, fichier restreint, constitue-t-il une amélioration de sécurité par rapport à les stocker dans `/etc/passwd` ?
- Que signifie une valeur `!` ou `*` dans le champ mot de passe de `/etc/shadow` ?

## Exercice 4 : Élever ses privilèges avec su et sudo

1. Essayez d'exécuter une commande réservée à root sans privilège élevé :
   ```
   apt update
   ```
   (ou `dnf check-update` selon votre distribution). Observez l'erreur de permission.
2. Exécutez la même commande précédée de `sudo` :
   ```
   sudo apt update
   ```
3. Vérifiez quelles commandes votre compte est autorisé à exécuter via sudo :
   ```
   sudo -l
   ```
4. Ouvrez une session shell complète en tant que root avec `su` (nécessite le mot de passe root) :
   ```
   su -
   ```
5. Vérifiez votre nouvelle identité, puis quittez la session root :
   ```
   whoami
   exit
   ```

**Questions**
- Quelle est la différence d'usage entre `su -` et `sudo <commande>` en matière de traçabilité (accountability) ?
- Pourquoi est-il recommandé, sur la plupart des distributions modernes, de privilégier `sudo` plutôt que de se connecter directement en tant que root ?

---

<details>
<summary>Réponses</summary>

**Exercice 1**
- Le compte root (superuser, UID 0) n'est soumis à aucune restriction de permissions : il peut lire, modifier ou supprimer n'importe quel fichier, gérer tous les processus et comptes. Un compte standard (standard user) est limité par les permissions attachées aux fichiers et ne peut agir que dans son propre espace (home directory) et sur les ressources qui lui sont explicitement ouvertes.
- Cela signifie que l'utilisateur courant possède les pleins pouvoirs administratifs (full administrative privileges) sur le système : aucune vérification de permission ne s'applique à ses actions.

**Exercice 2**
- Le `x` est un placeholder indiquant que le hash réel du mot de passe est stocké ailleurs, dans `/etc/shadow`, lisible uniquement par root. `/etc/passwd` doit rester world-readable pour que des commandes comme `ls -l` puissent résoudre les UID en noms, donc il ne doit pas contenir de données sensibles.
- Un shell `/usr/sbin/nologin` (ou `/bin/false`) empêche toute connexion interactive avec ce compte : il est utilisé par des comptes de service (service accounts) qui n'ont besoin d'exécuter qu'un démon, jamais d'ouvrir une session shell.

**Exercice 3**
- Séparer les hashs dans `/etc/shadow`, lisible uniquement par root, réduit la surface d'attaque : même si un utilisateur non privilégié ou un programme compromis peut lire `/etc/passwd`, il ne peut pas récupérer les hashs pour tenter une attaque hors ligne (offline brute-force ou dictionary attack).
- Un `!` ou `*` indique que le compte n'a pas de mot de passe valide utilisable pour une authentification par mot de passe (compte verrouillé, accès prévu uniquement par clé SSH, ou compte système sans connexion interactive).

**Exercice 4**
- `sudo <commande>` exécute une seule commande avec élévation de privilège tout en journalisant (logging) qui a exécuté quoi, sous l'identité de l'utilisateur d'origine ; `su -` ouvre une session complète sous l'identité root, où les actions ultérieures perdent la trace de l'utilisateur initial tant que la session dure.
- Privilégier `sudo` permet une meilleure traçabilité (accountability) et un contrôle plus fin des privilèges (on peut autoriser un utilisateur à exécuter seulement certaines commandes via `/etc/sudoers`), alors qu'une connexion directe en root donne un accès total sans distinction entre utilisateurs ni journal détaillé des actions.

</details>