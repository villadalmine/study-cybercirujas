# Exercices guidés — 4.1 Choosing an Operating System

**Certification :** LPI Linux Essentials (010-160, v1.6)
**Poids à l'examen :** 1
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/4/4.1/

---

## Exercice 1 — Identifier le système d'exploitation en cours d'utilisation

1. Ouvrez un terminal.
2. Affichez les informations du kernel avec la commande suivante :
   ```
   uname -a
   ```
3. Affichez les informations de la distribution :
   ```
   cat /etc/os-release
   ```
4. Si l'utilitaire est disponible, exécutez :
   ```
   hostnamectl
   ```
5. Comparez les champs `NAME`, `ID`, `ID_LIKE` et `VERSION_ID` retournés par `/etc/os-release`.

**Question 1.1 :** Quelle est la différence entre le *kernel* (affiché par `uname`) et la *distribution* (affichée par `/etc/os-release`) ?

**Question 1.2 :** À quoi sert le champ `ID_LIKE` dans `/etc/os-release`, et pourquoi est-il utile pour choisir un *package manager* compatible ?

---

## Exercice 2 — Reconnaître l'architecture matérielle (hardware compatibility)

1. Affichez l'architecture du processeur :
   ```
   uname -m
   ```
2. Affichez des informations détaillées sur le CPU :
   ```
   lscpu
   ```
3. Listez les périphériques PCI détectés :
   ```
   lspci
   ```
4. Listez les périphériques USB détectés :
   ```
   lsusb
   ```

**Question 2.1 :** Pourquoi une distribution Linux compilée pour `x86_64` ne peut-elle pas être installée telle quelle sur une machine `aarch64` (ARM) ?

**Question 2.2 :** En quoi la sortie de `lspci` et `lsusb` peut-elle influencer le choix d'une distribution avant l'installation (notion de *hardware compatibility*) ?

---

## Exercice 3 — Détecter la virtualisation et les environnements *live*

1. Vérifiez si le système actuel s'exécute dans une machine virtuelle :
   ```
   systemd-detect-virt
   ```
   (si l'utilitaire n'est pas disponible, notez-le et passez à l'étape suivante)
2. Recherchez des indices de virtualisation dans les logs du kernel :
   ```
   dmesg | grep -i -E "hypervisor|virtual"
   ```
3. Vérifiez si le système actuel a été démarré depuis un support *live* (clé USB) en consultant le point de montage racine :
   ```
   findmnt /
   ```

**Question 3.1 :** Quel est l'intérêt d'un *live boot* (démarrage depuis une clé USB sans installation) lorsqu'on évalue une distribution avant de choisir un système d'exploitation ?

**Question 3.2 :** Citez un scénario dans lequel exécuter Linux dans une machine virtuelle plutôt qu'en *dual-boot* serait préférable.

---

## Exercice 4 — Explorer le Desktop Environment actif

1. Affichez la variable d'environnement qui identifie le *Desktop Environment* courant :
   ```
   echo $XDG_CURRENT_DESKTOP
   ```
2. Si le système utilise `systemd`, affichez le type de session graphique :
   ```
   loginctl show-session $(loginctl | grep $(whoami) | awk '{print $1}') -p Type -p Desktop
   ```
3. Listez les sessions graphiques disponibles au login (sans vous déconnecter), en consultant :
   ```
   ls /usr/share/xsessions/ /usr/share/wayland-sessions/ 2>/dev/null
   ```

**Question 4.1 :** Quelle est la différence entre un *Desktop Environment* (par exemple GNOME ou KDE Plasma) et un *Window Manager* ?

**Question 4.2 :** Pourquoi le choix du *Desktop Environment* fait-il partie des critères de sélection d'un système d'exploitation, alors qu'il n'est pas propre au kernel Linux lui-même ?

---

## Exercice 5 — Comparer les familles de gestionnaires de paquets

1. Vérifiez la présence de chacun des gestionnaires de paquets suivants sur votre système (ignorez ceux qui ne sont pas installés) :
   ```
   which apt dnf yum pacman zypper 2>/dev/null
   ```
2. Associez le résultat obtenu à la valeur du champ `ID_LIKE` relevée à l'exercice 1.

**Question 5.1 :** Pourquoi le choix d'une distribution influence-t-il directement le *package manager* utilisé, et donc la manière d'installer des applications ?

**Question 5.2 :** Donnez un exemple de distribution appartenant à la famille Debian et un exemple appartenant à la famille Red Hat.

---

<details>
<summary>Réponses</summary>

**1.1** Le *kernel* est le cœur du système d'exploitation : il gère le matériel, la mémoire, les processus et les périphériques. La *distribution* (ou *distro*) est un ensemble complet construit autour du kernel Linux, comprenant un *package manager*, des bibliothèques système, des outils et souvent un *Desktop Environment*. Deux distributions différentes (par ex. Ubuntu et Fedora) peuvent utiliser des versions proches du même kernel tout en offrant une expérience très différente.

**1.2** `ID_LIKE` indique de quelle famille de distributions dérive la distribution actuelle (par ex. `ID_LIKE=debian` pour Ubuntu). Cela permet de savoir quel *package manager* et quel format de paquet (`.deb`, `.rpm`, etc.) sont compatibles, ce qui est utile lorsqu'on écrit des scripts ou de la documentation censés fonctionner sur plusieurs distributions apparentées.

**2.1** Un binaire compilé pour `x86_64` contient des instructions machine spécifiques au jeu d'instructions Intel/AMD 64 bits. Un processeur `aarch64` (ARM) utilise un jeu d'instructions différent et ne peut pas exécuter directement ce code : il faut soit une version du système compilée pour ARM, soit une couche d'émulation.

**2.2** La sortie de `lspci` et `lsusb` révèle le matériel réellement présent (cartes graphiques, cartes réseau, contrôleurs Wi-Fi, etc.). Avant de choisir un système d'exploitation, on vérifie que des *drivers* existent pour ce matériel dans le kernel ou la distribution visée, afin d'éviter des périphériques non fonctionnels après l'installation.

**3.1** Le *live boot* permet de tester une distribution (interface, matériel détecté, applications incluses) sans rien installer ni modifier le disque dur, ce qui facilite la comparaison entre plusieurs systèmes avant de faire un choix définitif.

**3.2** Par exemple, tester ou développer sous Linux depuis un poste Windows sans repartitionner le disque ni redémarrer la machine : une machine virtuelle permet de faire tourner les deux systèmes simultanément, alors que le *dual-boot* impose de choisir un seul OS à la fois au démarrage.

**4.1** Un *Window Manager* gère uniquement l'affichage, le déplacement et la décoration des fenêtres. Un *Desktop Environment* est un ensemble plus complet qui inclut un *Window Manager* ainsi que d'autres composants : gestionnaire de fichiers, barre des tâches, panneau de configuration, thèmes, applications par défaut, etc.

**4.2** Le kernel Linux ne fournit aucune interface graphique par lui-même : le *Desktop Environment* est une couche applicative ajoutée par la distribution. Deux utilisateurs sous le même kernel Linux peuvent avoir des expériences radicalement différentes selon le DE choisi (GNOME, KDE Plasma, XFCE, etc.), ce qui en fait un critère important lors du choix d'un système d'exploitation.

**5.1** Chaque distribution adopte un format de paquet et un outil associé pour installer, mettre à jour et supprimer des logiciels (par ex. `.deb` avec `apt`, `.rpm` avec `dnf`/`yum`). Ce choix détermine où et comment on trouve les logiciels disponibles, ainsi que la syntaxe des commandes à apprendre.

**5.2** Famille Debian : Ubuntu (ou Debian lui-même). Famille Red Hat : Fedora (ou CentOS/RHEL).

</details>