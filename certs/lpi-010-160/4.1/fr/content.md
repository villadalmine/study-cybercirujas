# 4.1 Choosing an Operating System

## Qu'est-ce qu'un système d'exploitation ?

Un **operating system** (OS) est la couche logicielle qui fait le lien entre le hardware (CPU, RAM, disques, périphériques) et les applications que l'utilisateur exécute. Il gère :

- l'ordonnancement des processus (**process scheduling**) ;
- la gestion de la mémoire (**memory management**) ;
- l'accès aux périphériques via des **device drivers** ;
- le système de fichiers (**filesystem**) ;
- l'interface avec l'utilisateur, en ligne de commande (**CLI**) ou graphique (**GUI**).

Le cœur de l'OS s'appelle le **kernel** : c'est le programme qui tourne en mode privilégié et qui contrôle directement le hardware. Autour du kernel s'organisent des bibliothèques système, des utilitaires et des applications qui, ensemble, forment ce qu'on appelle un **operating system** complet.

## Les grandes familles de systèmes d'exploitation

### Windows

**Microsoft Windows** est un OS propriétaire (**proprietary software**), dominant sur le marché des postes de travail (**desktop**) en entreprise et chez les particuliers. Le code source n'est pas public, et les licences sont payantes (**closed source, commercial license**).

### macOS

**macOS** (Apple) repose sur un kernel appelé **XNU**, lui-même basé sur des composants **BSD** (Unix) et **Mach**. C'est un système hybride entre logiciel propriétaire et composants open source (le projet **Darwin** est publié en open source, mais l'environnement graphique et les applications ne le sont pas).

### Linux

**Linux** désigne, au sens strict, uniquement le **kernel**, créé par Linus Torvalds en 1991 et publié sous licence **GPL** (**GNU General Public License**). Ce kernel est combiné avec des outils du projet **GNU** (bash, coreutils, gcc...) et d'autres composants pour former une **distribution** complète et utilisable (Debian, Ubuntu, Fedora, Red Hat Enterprise Linux, Arch Linux, openSUSE, etc.).

Chaque distribution choisit :
- un **package manager** (`apt`, `dnf`, `pacman`, `zypper`...) ;
- un cycle de publication (**release cycle**) : rolling release ou versions fixes ;
- un public cible : usage desktop, server, embedded.

### Systèmes mobiles et embarqués

- **Android** (Google) utilise le kernel Linux, mais avec une couche applicative (**Android Runtime**) très différente d'une distribution GNU/Linux classique.
- **iOS** (Apple) est dérivé de macOS/Darwin, donc du monde Unix/BSD, mais n'utilise pas le kernel Linux.
- De nombreux systèmes **embedded** (routeurs, télévisions connectées, systèmes industriels) utilisent des variantes légères de Linux, comme **OpenWrt** ou **Yocto Project**.

## Free software vs proprietary software

Un critère essentiel pour choisir un OS est le modèle de licence :

- **Free and Open Source Software (FOSS)** : le code source est disponible, modifiable et redistribuable, sous des licences comme la **GPL**, la **MIT License** ou la **Apache License**. Exemple : le kernel Linux, la majorité des distributions Linux.
- **Proprietary software** : le code source est fermé, l'usage est encadré par une licence commerciale. Exemple : Microsoft Windows, macOS (pour la partie non-Darwin).

Cette distinction est indépendante de la gratuité : un logiciel peut être gratuit (**freeware**) sans être open source, et inversement un logiciel open source peut être vendu avec un support payant (c'est le modèle économique de Red Hat, par exemple).

## Environnements de bureau (Desktop Environments)

Sous Linux, contrairement à Windows ou macOS, l'interface graphique n'est pas imposée par l'OS lui-même. On distingue plusieurs couches :

- le **display server** (historiquement **X11**, aujourd'hui de plus en plus **Wayland**) ;
- le **window manager**, qui gère la position et l'apparence des fenêtres ;
- le **desktop environment (DE)** complet, qui regroupe window manager, panneau, gestionnaire de fichiers, thèmes... Exemples : **GNOME**, **KDE Plasma**, **Xfce**, **Cinnamon**.

C'est une des raisons pour lesquelles on parle de « choisir » un système d'exploitation Linux : au-delà du kernel et de la distribution, l'utilisateur peut aussi choisir son environnement graphique.

## Identifier son système avec des commandes

### `uname` — informations sur le kernel

```console
$ uname -a
Linux fedora-workstation 6.8.9-300.fc40.x86_64 #1 SMP PREEMPT_DYNAMIC Thu May 9 15:19:34 UTC 2024 x86_64 GNU/Linux
```

- `uname -s` : nom du kernel (`Linux`)
- `uname -r` : version du kernel (`6.8.9-300.fc40.x86_64`)
- `uname -m` : architecture matérielle (`x86_64`)

### `/etc/os-release` — informations sur la distribution

```console
$ cat /etc/os-release
NAME="Fedora Linux"
VERSION="40 (Workstation Edition)"
ID=fedora
VERSION_ID=40
PRETTY_NAME="Fedora Linux 40 (Workstation Edition)"
```

Ce fichier standardisé (défini par le **freedesktop.org** standard) permet à des scripts de détecter la distribution de façon fiable, quel que soit le système.

### `lsb_release` — norme Linux Standard Base

```console
$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.1 LTS
Release:        24.04
Codename:       noble
```

### `hostnamectl` — vue d'ensemble sur les systèmes avec systemd

```console
$ hostnamectl
 Static hostname: study-vm
       Icon name: computer-vm
         Chassis: vm
      Machine ID: 8f3c1d2a9b4e4a1e8a2f0c1d2e3f4a5b
         Boot ID: 1a2b3c4d5e6f4a5b8c9d0e1f2a3b4c5d
  Virtualization: kvm
Operating System: Debian GNU/Linux 12 (bookworm)
          Kernel: Linux 6.1.0-18-amd64
    Architecture: x86-64
```

Ces commandes sont typiquement utilisées pour vérifier la compatibilité d'un logiciel, adapter un script d'installation, ou simplement documenter l'environnement avant un support technique.

## Résumé des critères de choix d'un OS

| Critère | Windows | macOS | Linux |
|---|---|---|---|
| Licence | Proprietary | Mixte (Darwin open, reste fermé) | Open source (GPL et autres) |
| Coût | Payant | Lié au hardware Apple | Généralement gratuit |
| Personnalisation | Limitée | Limitée | Très forte (kernel, DE, distribution) |
| Usage serveur | Windows Server | Rare | Très répandu (majorité des serveurs cloud) |
| Usage mobile | Windows (marginal) | iOS | Android |

## Références

- LPI Learning Materials — *4.1 Choosing an Operating System* : https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- The Linux Kernel Archives : https://www.kernel.org/
- GNU Project — *What is Free Software?* : https://www.gnu.org/philosophy/free-sw.en.html
- freedesktop.org — *os-release specification* : https://www.freedesktop.org/software/systemd/man/latest/os-release.html
- Debian Project : https://www.debian.org/
- Red Hat — *What is an operating system?* : https://www.redhat.com/en/topics/linux/what-is-an-operating-system