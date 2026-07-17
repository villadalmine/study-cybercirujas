# LPI Linux Essentials (010-160 v1.6) — Thème 4.2 : Understanding Computer Hardware

**Poids dans l'examen : 2**
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/4/4.2/

Ces exercices guidés vous font explorer, via le terminal, les composants matériels d'une machine Linux et les outils qui permettent de les identifier. Exécutez chaque commande sur une distribution Linux (idéalement dans une VM ou un conteneur privilégié, car certaines informations dépendent de l'accès au matériel réel).

---

## Exercice 1 — Identifier le CPU

1. Affichez les informations brutes du processeur exposées par le noyau :
   ```
   cat /proc/cpuinfo
   ```
2. Repérez dans la sortie les champs `model name`, `cpu cores` et `flags`.
3. Obtenez un résumé plus lisible avec l'utilitaire dédié :
   ```
   lscpu
   ```
4. Comparez le nombre de lignes `processor` dans `/proc/cpuinfo` avec le champ `CPU(s)` de `lscpu`.

**Questions de compréhension**
- Pourquoi `/proc/cpuinfo` peut-il afficher plusieurs blocs `processor` même sur une machine à un seul CPU physique ?
- À quoi correspond le champ `flags` (ou `Flags` sous `lscpu`) et pourquoi un instructeur en virtualisation s'y intéresserait-il particulièrement (ex. `vmx` ou `svm`) ?

---

## Exercice 2 — Explorer la mémoire (RAM)

1. Affichez l'usage mémoire courant :
   ```
   free -h
   ```
2. Consultez la vue détaillée fournie par le noyau :
   ```
   cat /proc/meminfo
   ```
3. Identifiez dans `/proc/meminfo` les lignes `MemTotal`, `MemFree` et `MemAvailable`.
4. Comparez `MemAvailable` avec la colonne `available` de `free -h`.

**Questions de compréhension**
- Quelle est la différence conceptuelle entre `MemFree` et `MemAvailable` ?
- Pourquoi la mémoire dite « libre » sur un système Linux qui tourne depuis longtemps est-elle souvent proche de zéro, sans que ce soit un problème ?

---

## Exercice 3 — Lister les périphériques connectés au bus PCI

1. Listez tous les périphériques PCI/PCIe détectés :
   ```
   lspci
   ```
2. Repérez la carte graphique (ligne contenant `VGA compatible controller`) et le contrôleur réseau (`Ethernet controller` ou `Network controller`).
3. Obtenez une sortie plus détaillée, avec les identifiants fabricant/périphérique :
   ```
   lspci -nn
   ```
4. Affichez des informations verbeuses sur un seul périphérique repéré à l'étape 2, en remplaçant `XX:YY.Z` par son adresse de bus :
   ```
   lspci -v -s XX:YY.Z
   ```

**Questions de compréhension**
- Quel est le rôle des identifiants entre crochets (ex. `[8086:1234]`) affichés par `lspci -nn`, et à quoi servent-ils lors de la recherche d'un driver ?
- Pourquoi `lspci` peut-il lister un périphérique alors même qu'aucun driver n'est chargé pour celui-ci ?

---

## Exercice 4 — Lister les périphériques USB (hot-pluggable devices)

1. Listez les périphériques USB actuellement détectés :
   ```
   lsusb
   ```
2. Branchez un périphérique USB (clé, souris, etc.) puis relancez `lsusb` pour observer la nouvelle ligne apparue.
3. Affichez la hiérarchie des bus et hubs USB sous forme d'arborescence :
   ```
   lsusb -t
   ```
4. Débranchez le périphérique et relancez `lsusb` pour confirmer sa disparition.

**Questions de compréhension**
- Que signifie le terme *hot-pluggable* appliqué à l'USB, par opposition à un bus comme la RAM qui ne peut pas être modifié à chaud ?
- Dans la sortie de `lsusb -t`, que représentent les niveaux d'indentation (`Bus`, `Port`, `Dev`) ?

---

## Exercice 5 — Lister le stockage et les systèmes de fichiers

1. Listez les périphériques de bloc (disques, partitions) présents sur le système :
   ```
   lsblk
   ```
2. Ajoutez les informations de systèmes de fichiers et d'UUID :
   ```
   lsblk -f
   ```
3. Retrouvez les mêmes informations avec un outil dédié à l'identification des systèmes de fichiers :
   ```
   sudo blkid
   ```
4. Comparez la sortie de `lsblk -f` et de `blkid` pour un même périphérique (ex. `/dev/sda1`).

**Questions de compréhension**
- Pourquoi `blkid` nécessite-t-il généralement les privilèges root alors que `lsblk` ne les nécessite pas toujours ?
- Quelle information présente dans `lsblk -f` mais absente de `lsblk` simple serait utile pour retrouver un disque après un changement de nom de périphérique (`/dev/sdX`) ?

---

## Exercice 6 — Modules noyau et drivers

1. Listez les modules actuellement chargés dans le noyau :
   ```
   lsmod
   ```
2. Choisissez un module lié à un périphérique repéré dans les exercices précédents (par exemple un module réseau ou USB) et affichez ses informations détaillées :
   ```
   modinfo <nom_du_module>
   ```
3. Observez la colonne `Used by` dans la sortie de `lsmod` pour ce module.
4. (Optionnel, avec précaution) Affichez les messages noyau récents liés au chargement de matériel :
   ```
   dmesg | tail -50
   ```

**Questions de compréhension**
- Quelle relation existe entre un *device driver* et un *kernel module* sous Linux ?
- Que signifie une valeur différente de zéro dans la colonne `Used by` de `lsmod`, et pourquoi cela empêche-t-il généralement de décharger ce module avec `modprobe -r` ?

---

## Exercice 7 — Synthèse : relier matériel, bus et driver

1. Choisissez un périphérique PCI de l'exercice 3 (ex. la carte réseau) et notez son adresse de bus.
2. Retrouvez le driver associé :
   ```
   lspci -k -s XX:YY.Z
   ```
3. Repérez la ligne `Kernel driver in use:` dans la sortie.
4. Vérifiez que ce driver apparaît bien dans la liste produite par `lsmod` (exercice 6, étape 1).

**Questions de compréhension**
- Pourquoi un périphérique listé par `lspci` peut-il n'avoir *aucun* driver associé (`Kernel driver in use` absent) ?
- Sur cette base, comment expliqueriez-vous à un débutant le chemin complet allant du matériel physique jusqu'à sa visibilité pour les applications (bus → driver/module → périphérique dans `/dev` ou interface système) ?

---

<details>
<summary>Réponses</summary>

**Exercice 1**
- Chaque bloc `processor` dans `/proc/cpuinfo` correspond à un *logical CPU* (cœur physique ou thread produit par l'Hyper-Threading/SMT), pas nécessairement à un CPU physique distinct.
- `flags` liste les fonctionnalités matérielles supportées par le CPU (jeux d'instructions, extensions). `vmx` (Intel) ou `svm` (AMD) indiquent le support de la virtualisation matérielle, indispensable pour lancer des hyperviseurs comme KVM.

**Exercice 2**
- `MemFree` est la mémoire strictement inutilisée à cet instant. `MemAvailable` estime la mémoire réellement disponible pour de nouvelles applications, en tenant compte du cache et des buffers qui peuvent être libérés instantanément si besoin.
- Linux utilise agressivement la RAM libre pour le cache disque (page cache), ce qui améliore les performances. Cette mémoire n'est pas « perdue » : elle est reprise automatiquement dès qu'une application en a besoin, d'où l'importance de regarder `available` plutôt que `free`.

**Exercice 3**
- Ce sont les identifiants numériques *vendor ID* et *device ID* attribués par le PCI-SIG. Ils permettent d'identifier précisément un matériel indépendamment de son nom commercial, et de rechercher le driver correspondant dans la base de données du noyau ou sur le site du fabricant.
- `lspci` lit les informations exposées par le bus PCI lui-même (énumération matérielle), indépendamment du fait qu'un driver soit chargé ou non. Le matériel est donc « vu » même sans pilote fonctionnel.

**Exercice 4**
- *Hot-pluggable* signifie qu'un périphérique peut être connecté ou déconnecté pendant que le système fonctionne, sans redémarrage, le bus USB gérant la détection et l'initialisation à la volée. La RAM, à l'inverse, doit être installée machine éteinte.
- `Bus` identifie le contrôleur USB physique, `Port` la position physique sur ce bus/hub, et `Dev` le numéro attribué au périphérique connecté ; l'indentation reflète la hiérarchie des hubs USB imbriqués.

**Exercice 5**
- `blkid` doit lire directement les superblocs des systèmes de fichiers sur les périphériques bruts, ce qui requiert un accès privilégié ; `lsblk` s'appuie principalement sur les métadonnées déjà exposées par le noyau via `/sys` et `udev`, accessibles en lecture à tout utilisateur.
- L'`UUID` (identifiant unique du système de fichiers) est la donnée clé : il reste stable même si le nom `/dev/sdX` change (ex. après ajout/retrait d'un disque), ce qui le rend préférable dans `/etc/fstab`.

**Exercice 6**
- Un module noyau (*kernel module*) est la forme sous laquelle un driver est chargé dynamiquement dans un noyau Linux moderne : le driver est le code qui pilote le matériel, le module est le mécanisme de chargement/déchargement à chaud de ce code.
- Une valeur différente de zéro indique que d'autres modules ou composants du noyau dépendent de celui-ci (dépendances listées après le nombre). Le noyau refuse de décharger un module encore utilisé afin d'éviter de casser une dépendance active.

**Exercice 7**
- Cela arrive lorsque le matériel est présent mais qu'aucun driver compatible n'est installé ou chargé (matériel non supporté, module manquant, ou driver propriétaire non installé) : le périphérique reste visible au niveau du bus mais reste inutilisable par le système.
- Le chemin est : le bus (PCI, USB, etc.) détecte et énumère le matériel → le noyau associe un driver (chargé comme module) à ce matériel selon son identifiant → une fois le driver actif, le périphérique devient exploitable via une interface système (fichier dans `/dev`, interface réseau `ethX`/`enpXsY`, point de montage, etc.).

</details>