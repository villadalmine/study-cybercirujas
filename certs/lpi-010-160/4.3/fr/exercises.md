# Exercices guidés — 4.3 Where Data is Stored

**Certification** : LPI Linux Essentials (examen 010-160, v1.6)
**Objectif** : 4.3 Where Data is Stored — poids : 3
**Source de référence** : https://learning.lpi.org/en/learning-materials/010-160/4/4.3/

---

## Exercice 1 — Explorer le pseudo-filesystem /proc

Le kernel Linux expose son état interne via `/proc`, un filesystem virtuel généré en mémoire : ses fichiers n'existent pas sur le disque.

1. Affichez la version du kernel :
   ```bash
   cat /proc/version
   ```
2. Affichez les informations sur le ou les CPU :
   ```bash
   cat /proc/cpuinfo
   ```
3. Affichez l'état de la mémoire (RAM et swap) :
   ```bash
   cat /proc/meminfo
   ```
4. Affichez le temps écoulé depuis le boot :
   ```bash
   cat /proc/uptime
   ```
5. Affichez les paramètres passés au kernel au démarrage :
   ```bash
   cat /proc/cmdline
   ```
6. Listez les répertoires numérotés à la racine de `/proc` :
   ```bash
   ls -d /proc/[0-9]*
   ```

**Questions**
- Que renvoie `ls -l /proc/cpuinfo` pour la taille du fichier, et pourquoi ?
- Que représente chaque répertoire numéroté sous `/proc` (ex. `/proc/1`) ?

---

## Exercice 2 — Explorer /sys

`/sys` expose la hiérarchie des devices et des drivers gérés par le kernel ; c'est la source utilisée par `udev` pour peupler `/dev`.

1. Listez les catégories disponibles :
   ```bash
   ls /sys/class
   ```
2. Affichez l'adresse MAC des interfaces réseau détectées :
   ```bash
   cat /sys/class/net/*/address
   ```
3. Listez les block devices connus du kernel :
   ```bash
   ls /sys/block
   ```

**Question**
- Quelle est la différence principale entre `/proc` (processus, état runtime du kernel) et `/sys` (devices, drivers) ?

---

## Exercice 3 — Consulter les logs système dans /var/log

1. Listez les fichiers de log présents :
   ```bash
   ls -l /var/log
   ```
2. Affichez les derniers messages du kernel depuis le ring buffer :
   ```bash
   sudo dmesg | tail -n 20
   ```
3. Sur un système avec systemd, consultez le journal persistant :
   ```bash
   journalctl -xe | tail -n 20
   ```
4. Cherchez les tentatives d'authentification récentes (le nom du fichier varie selon la distribution : `auth.log` sur Debian/Ubuntu, `secure` sur RHEL/Fedora) :
   ```bash
   sudo tail -n 20 /var/log/auth.log   # ou /var/log/secure
   ```

**Questions**
- Quelle commande affiche les messages du kernel accumulés depuis le boot, avant qu'ils ne soient éventuellement écrits sur disque ?
- Pourquoi `journalctl` peut-il afficher des logs de boots précédents alors que `dmesg` ne le peut pas ?

---

## Exercice 4 — Identifier disques et partitions

1. Affichez l'arborescence des block devices :
   ```bash
   lsblk
   ```
2. Affichez l'UUID et le type de filesystem de chaque partition :
   ```bash
   sudo blkid
   ```
3. Affichez la table de partitions de chaque disque :
   ```bash
   sudo fdisk -l
   ```
4. Affichez l'espace utilisé et disponible par filesystem monté :
   ```bash
   df -h
   ```
5. Affichez la taille d'un répertoire donné :
   ```bash
   du -sh /home
   ```

**Questions**
- Quelle commande utiliseriez-vous pour connaître l'espace libre restant sur `/` ?
- Quelle est la différence entre un device comme `/dev/sda` et une partition comme `/dev/sda1` ?

---

## Exercice 5 — Monter et démonter un filesystem

1. Branchez une clé USB et repérez le device node créé :
   ```bash
   dmesg | tail -n 10
   ```
2. Créez un point de montage (mount point) dédié :
   ```bash
   sudo mkdir -p /mnt/usb
   ```
3. Montez la partition (remplacez `sdX1` par le nom réel) :
   ```bash
   sudo mount /dev/sdX1 /mnt/usb
   ```
4. Vérifiez le contenu monté :
   ```bash
   ls /mnt/usb
   ```
5. Démontez proprement avant de retirer la clé :
   ```bash
   sudo umount /mnt/usb
   ```
6. Inspectez les montages automatiques déclarés au boot :
   ```bash
   cat /etc/fstab
   ```

**Questions**
- Que se passe-t-il si vous exécutez `umount` alors qu'un terminal a son répertoire courant (`cwd`) à l'intérieur de `/mnt/usb` ?
- Quel est le rôle de `/etc/fstab`, et quelle commande permet de monter d'un coup toutes les entrées qui n'ont pas l'option `noauto` ?

---

## Exercice 6 — Détecter le matériel et les périphériques hotplug

1. Listez les devices connectés au bus PCI :
   ```bash
   lspci
   ```
2. Listez les devices connectés au bus USB :
   ```bash
   lsusb
   ```
3. Affichez la hiérarchie des hubs et devices USB :
   ```bash
   lsusb -t
   ```
4. Débranchez puis rebranchez un device USB et observez les événements en temps réel :
   ```bash
   dmesg -w
   ```

**Questions**
- Que signifie « hotplug » pour un périphérique, et quel composant système (daemon) réagit à ces événements pour créer les entrées dans `/dev` ?
- `lspci` et `lsusb` interrogent-ils `/proc`, `/sys`, ou directement le matériel ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Exercice 1**
- `/proc/cpuinfo` a une taille de 0 octet dans `ls -l` : c'est un fichier virtuel généré à la volée par le kernel au moment de la lecture, il n'occupe pas d'espace disque réel.
- Chaque répertoire numéroté sous `/proc` correspond au PID d'un processus en cours d'exécution (ex. `/proc/1` est presque toujours le processus init/systemd) ; il contient des informations comme `cmdline`, `status`, `fd/`, etc. pour ce processus.

**Exercice 2**
- `/proc` reflète surtout l'état runtime du kernel et des processus (mémoire, CPU, processus actifs), tandis que `/sys` expose la structure des devices et des drivers telle que le kernel model object la représente ; c'est la source que `udev` utilise pour peupler dynamiquement `/dev`.

**Exercice 3**
- `dmesg` affiche le contenu du kernel ring buffer, un tampon en mémoire alimenté depuis le boot, indépendamment de son écriture éventuelle vers un fichier de log.
- `journalctl` lit le journal binaire de systemd, qui peut être configuré en mode persistant (stocké sous `/var/log/journal`) et conserve donc les logs à travers les redémarrages ; `dmesg` ne montre que le ring buffer du kernel actuel, réinitialisé à chaque boot.

**Exercice 4**
- `df -h /` (ou simplement `df -h` et lire la ligne correspondant à `/`) indique l'espace utilisé et disponible sur la partition racine.
- `/dev/sda` désigne le disque entier (le device), tandis que `/dev/sda1` désigne une partition individuelle sur ce disque ; un disque peut contenir plusieurs partitions.

**Exercice 5**
- La commande `umount` échoue avec une erreur du type « target is busy », car le kernel refuse de démonter un filesystem tant qu'un processus a un fichier ouvert ou son répertoire courant dessus.
- `/etc/fstab` déclare les filesystems à monter automatiquement au démarrage (device, point de montage, type, options, dump, pass) ; la commande `mount -a` monte toutes les entrées de `/etc/fstab` qui ne portent pas l'option `noauto`.

**Exercice 6**
- Un périphérique « hotplug » est un device qui peut être branché ou débranché pendant que le système fonctionne, sans redémarrage ; c'est le daemon `udev`, en écoutant les événements du kernel, qui crée ou supprime dynamiquement les entrées correspondantes dans `/dev`.
- `lspci` et `lsusb` lisent les informations exposées par le kernel via `/sys` (et les bases de données locales `pci.ids`/`usb.ids` pour traduire les identifiants en noms lisibles) ; ils n'interrogent pas directement le matériel bas niveau.

</details>