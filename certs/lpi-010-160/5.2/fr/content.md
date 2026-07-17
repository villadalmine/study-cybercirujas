# 5.2 Creating Users and Groups

## Introduction

Sur un système Linux, chaque processus et chaque fichier appartient à un `user` et à un `group`. Créer, modifier et supprimer des comptes est une tâche d'administration de base : c'est ce qui permet de séparer les privilèges entre plusieurs personnes (ou services) qui utilisent la même machine. Ce topic couvre les commandes et fichiers nécessaires pour gérer le cycle de vie complet d'un `user account` et d'un `group`.

## Les fichiers système

Trois (quatre) fichiers texte dans `/etc` constituent la base de données locale des comptes.

### `/etc/passwd`

Une ligne par utilisateur, sept champs séparés par `:` :

```
alice:x:1001:1001:Alice Dupont,,,:/home/alice:/bin/bash
```

| Champ | Signification |
|---|---|
| `alice` | `login name` |
| `x` | placeholder — le hash du mot de passe est dans `/etc/shadow` |
| `1001` | `UID` (User ID) |
| `1001` | `GID` du groupe primaire |
| `Alice Dupont,,,` | `GECOS` (commentaire, souvent le nom complet) |
| `/home/alice` | `home directory` |
| `/bin/bash` | `login shell` |

Les `UID` de 0 à 999 (ou 1 à 999 selon la distribution) sont en général réservés aux comptes système (`root` a toujours `UID 0`). Les comptes humains commencent typiquement à `1000`.

### `/etc/shadow`

Contient les mots de passe chiffrés (hash), lisible uniquement par `root` :

```
alice:$6$rounds=...hash...:19500:0:90:7:::
```

Champs clés : login, hash du mot de passe (`!` ou `*` = compte verrouillé, vide = pas de mot de passe), date du dernier changement (en jours depuis epoch), âge minimum, âge maximum, période d'avertissement, période d'inactivité, date d'expiration.

### `/etc/group`

Une ligne par groupe :

```
developers:x:1010:alice,bob
```

Champs : nom du groupe, placeholder, `GID`, liste des membres secondaires séparés par `,`.

### `/etc/gshadow`

Équivalent de `/etc/shadow` pour les groupes (mots de passe de groupe, administrateurs de groupe) — peu utilisé en pratique.

## Créer un utilisateur : `useradd`

```
useradd -m -c "Alice Dupont" -s /bin/bash alice
```

- `-m` : crée le `home directory` (et copie `/etc/skel` dedans)
- `-c` : commentaire (`GECOS`)
- `-s` : `login shell`
- `-u` : force un `UID` spécifique
- `-g` : `group` primaire (nom ou `GID`)
- `-G` : liste de `groups` secondaires supplémentaires
- `-d` : chemin du `home directory` personnalisé

Sur Debian/Ubuntu, la commande interactive `adduser` est souvent préférée à `useradd` car elle pose des questions et gère `-m` automatiquement, mais `useradd` reste le standard POSIX/LPI.

Après création, il faut définir un mot de passe :

```
passwd alice
New password:
Retype new password:
passwd: password updated successfully
```

## Modifier un utilisateur : `usermod`

```
usermod -aG developers alice
```

- `-aG group` : **append** l'utilisateur à un groupe secondaire (sans `-a`, `-G` remplace toute la liste des groupes secondaires — piège classique d'examen)
- `-l nouveaunom` : renomme le login
- `-L` / `-U` : verrouille / déverrouille le compte (place/enlève un `!` devant le hash dans `/etc/shadow`)
- `-s` : change le shell
- `-d -m` : déplace le `home directory`
- `-e YYYY-MM-DD` : fixe une date d'expiration du compte

## Supprimer un utilisateur : `userdel`

```
userdel -r alice
```

- `-r` : supprime aussi le `home directory` et la `mail spool`
- Sans `-r`, le compte disparaît mais les fichiers restent (utile pour ne pas perdre de données)

## Gestion des groupes

```
groupadd developers
groupmod -n devs developers
groupdel devs
```

- `groupadd -g 2000 nom` : force un `GID`
- `groupmod -n` : renomme un groupe
- `groupdel` : refuse de supprimer un groupe qui est encore le groupe **primaire** d'un utilisateur existant

## Vérifier l'identité et l'appartenance

```
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),1010(developers)

$ groups alice
alice : alice developers

$ whoami
alice
```

`who` et `w` montrent qui est connecté (et depuis où) ; `last` affiche l'historique des connexions à partir de `/var/log/wtmp`.

## Suspendre un compte sans le supprimer

Deux approches courantes, souvent demandées à l'examen :

1. **Verrouiller le mot de passe** : `usermod -L alice` (ou `passwd -l alice`) — préfixe le hash d'un `!`, empêche la connexion par mot de passe mais laisse les clés SSH fonctionner.
2. **Expirer le compte** : `chage -E 0 alice` ou `usermod -e 1970-01-01` — désactive complètement le compte à une date donnée, y compris SSH.

`chage -l alice` affiche les informations d'expiration et de vieillissement du mot de passe pour un compte.

## Résumé

| Action | Utilisateur | Groupe |
|---|---|---|
| Créer | `useradd` | `groupadd` |
| Modifier | `usermod` | `groupmod` |
| Supprimer | `userdel` | `groupdel` |
| Mot de passe | `passwd` | — |
| Info compte | `id`, `chage -l` | — |

Points à retenir pour l'examen :
- `-aG` vs `-G` dans `usermod` (append vs remplacer)
- L'`UID 0` est toujours `root`
- Le hash est dans `/etc/shadow`, jamais dans `/etc/passwd`
- `userdel -r` supprime le `home directory`
- `usermod -L` verrouille, `chage -E 0` expire le compte

## Références

- LPI Learning Materials — 010-160, Topic 5.2 Creating Users and Groups : https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- `man useradd`, `man usermod`, `man userdel`, `man groupadd`, `man groupmod`, `man groupdel`, `man passwd`, `man chage`, `man shadow` (formats de `/etc/passwd`, `/etc/shadow`, `/etc/group`)