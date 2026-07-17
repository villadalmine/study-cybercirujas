# Exercices guidés — Topic 1.4 : ICT Skills and Working in Linux

*Certification : lpi-linux-essentials (010-160, v1.6) — Source de référence : [LPI Learning Materials 1.4](https://learning.lpi.org/en/learning-materials/010-160/1/1.4/)*

## Exercice 1 — Naviguer entre GUI et CLI

1. Allumez votre poste et connectez-vous à votre session Linux (locale, via l'écran de login du *desktop environment*).
2. Repérez sur le bureau les éléments suivants : icônes, barre des tâches, menu des applications, gestionnaire de fichiers (*file manager*).
3. Ouvrez le gestionnaire de fichiers et naviguez jusqu'à votre dossier personnel (`/home/<votre_utilisateur>`).
4. Depuis le menu des applications, ouvrez un terminal (*terminal emulator*).
5. Dans le terminal, tapez `pwd` et observez le résultat : il affiche le répertoire courant (*current working directory*).
6. Tapez `ls` pour lister le contenu de ce répertoire, puis comparez avec ce que vous voyiez dans le gestionnaire de fichiers graphique.

**Questions de compréhension**
- Quelle est la différence fondamentale entre une interaction via GUI (*graphical user interface*) et via CLI (*command line interface*) pour effectuer la même tâche ?
- Pourquoi le résultat de `ls` et le contenu affiché dans le gestionnaire de fichiers graphique devraient-ils correspondre ?

## Exercice 2 — Obtenir de l'aide en ligne de commande

1. Dans le terminal, tapez `man ls` et parcourez la *man page* avec les flèches ou la barre d'espace.
2. Quittez la *man page* en appuyant sur `q`.
3. Tapez `ls --help` et comparez la sortie avec celle de `man ls`.
4. Tapez `info ls` (si disponible) et observez la structure de navigation par nœuds.
5. Cherchez une section précise dans une *man page* avec la recherche interne : dans `man ls`, tapez `/size` puis Entrée, puis `n` pour passer à l'occurrence suivante.
6. Tapez `man -k directory` (ou `apropos directory`) pour lister les commandes liées au mot-clé « directory ».

**Questions de compréhension**
- Quand privilégier `--help` plutôt que `man` pour une commande ?
- À quoi sert la commande `apropos` (ou `man -k`) et dans quel contexte l'utiliseriez-vous ?

## Exercice 3 — Raccourcis clavier et gestion de session

1. Dans une application graphique quelconque (éditeur de texte, navigateur), testez le raccourci pour copier (`Ctrl+C`) et coller (`Ctrl+V`) un texte.
2. Ouvrez plusieurs fenêtres et utilisez `Alt+Tab` pour naviguer entre elles.
3. Verrouillez votre session avec le raccourci correspondant à votre *desktop environment* (souvent `Super+L` ou via le menu utilisateur).
4. Déverrouillez la session en saisissant votre mot de passe.
5. Dans le terminal, appuyez sur `Ctrl+C` pendant qu'une commande longue s'exécute (par exemple `ping 127.0.0.1`) et observez l'effet.
6. Utilisez les flèches haut/bas dans le terminal pour parcourir l'*command history* des commandes précédentes.

**Questions de compréhension**
- Pourquoi `Ctrl+C` a-t-il un effet différent dans un terminal (interrompre un processus) que dans une application graphique (copier) ?
- Quel est l'intérêt de verrouiller sa session plutôt que de fermer complètement sa session utilisateur ?

## Exercice 4 — Identifier le matériel et les périphériques de stockage

1. Dans le terminal, tapez `lsblk` pour lister les périphériques de bloc (disques, partitions).
2. Branchez une clé USB (*USB stick*) si vous en avez une disponible, puis relancez `lsblk` : notez le nouveau périphérique apparu.
3. Tapez `df -h` pour voir l'espace disque utilisé et disponible sur chaque système de fichiers monté.
4. Tapez `free -h` pour observer la mémoire RAM disponible et utilisée.
5. Identifiez si votre disque principal est un HDD ou un SSD via `lsblk -d -o name,rota` (`rota=1` indique un disque avec pièces mobiles, donc un HDD ; `rota=0` indique un SSD).

**Questions de compréhension**
- Quelle différence pratique y a-t-il entre un HDD et un SSD du point de vue de l'utilisateur final ?
- Pourquoi `df -h` et `free -h` mesurent-ils deux ressources différentes du système ?

## Exercice 5 — Bonnes pratiques de sécurité et sauvegardes

1. Listez les logiciels installés sur votre distribution via le gestionnaire de paquets graphique ou en ligne de commande (par exemple `dpkg -l` sur Debian/Ubuntu, ou `rpm -qa` sur Fedora/RHEL).
2. Identifiez si un antivirus ou un outil de détection de *malware* est installé (rare mais possible sur certaines distributions destinées à des environnements mixtes).
3. Créez un dossier de test `~/test-backup` contenant un fichier texte quelconque.
4. Copiez ce dossier vers un support externe (clé USB) ou un second répertoire simulant un stockage distinct, avec `cp -r ~/test-backup /chemin/de/destination`.
5. Réfléchissez à une stratégie de sauvegarde vers le *cloud* (service de stockage en ligne) : quels fichiers mériteraient d'y être copiés en priorité ?

**Questions de compréhension**
- Pourquoi une sauvegarde locale seule (sur le même disque) est-elle insuffisante en cas de panne matérielle ?
- Quels critères utiliseriez-vous pour décider quelles données sauvegarder dans le *cloud* plutôt que localement ?

---

<details>
<summary>Voir les réponses</summary>

**Exercice 1**
- La GUI repose sur des interactions visuelles et directes (clics, icônes), tandis que la CLI repose sur des commandes textuelles précises. La CLI permet souvent plus de rapidité, de précision et d'automatisation (scripts), tandis que la GUI est plus intuitive pour un débutant.
- Ils correspondent car les deux ne sont que deux façons différentes d'interroger le même système de fichiers sous-jacent : les données ne changent pas selon l'interface utilisée pour les consulter.

**Exercice 2**
- `--help` est généralement plus rapide à consulter pour un rappel bref des options d'une commande ; `man` est préférable pour une documentation complète avec des exemples et une description détaillée du comportement.
- `apropos` (ou `man -k`) sert à retrouver le nom d'une commande dont on ne connaît que la fonction approximative, en cherchant un mot-clé dans les descriptions courtes de toutes les *man pages* installées.

**Exercice 3**
- Dans un terminal, `Ctrl+C` envoie un signal d'interruption (SIGINT) au processus en cours d'exécution pour l'arrêter, alors que dans une application graphique, la même combinaison est mappée sur l'action « copier » du presse-papiers — ce sont deux conventions indépendantes définies par le contexte logiciel.
- Verrouiller la session protège l'accès physique au poste sans fermer les applications ni perdre le travail en cours, alors que fermer la session termine tous les processus utilisateur et nécessite de tout rouvrir ensuite.

**Exercice 4**
- Un HDD (*Hard Disk Drive*) contient des pièces mécaniques mobiles (plateaux, tête de lecture), ce qui le rend plus lent et plus sensible aux chocs ; un SSD (*Solid State Drive*) n'a pas de pièces mobiles, il est plus rapide et plus résistant, mais généralement plus coûteux par gigaoctet.
- `df -h` mesure l'espace de stockage disponible sur les disques (données persistantes), tandis que `free -h` mesure la mémoire vive (RAM), une ressource volatile utilisée par les processus en cours d'exécution.

**Exercice 5**
- Une sauvegarde locale sur le même disque physique disparaît en même temps que les données originales en cas de défaillance matérielle de ce disque ; une sauvegarde doit être stockée sur un support physiquement distinct pour être utile en cas de panne.
- Les critères courants incluent : l'importance/l'unicité des données (documents personnels irremplaçables vs fichiers réinstallables), la sensibilité des données (éviter d'envoyer des données confidentielles vers un service tiers sans chiffrement), et la fréquence de mise à jour des fichiers.

</details>