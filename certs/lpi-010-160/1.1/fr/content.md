# 1.1 Linux Evolution and Popular Operating Systems

## Introduction

Linux n'est pas né dans le vide : c'est l'héritier direct d'Unix, croisé avec le mouvement du logiciel libre porté par le projet GNU. Comprendre cette généalogie permet de comprendre pourquoi il existe aujourd'hui des centaines de *distributions* différentes, toutes basées sur le même *kernel*, mais avec des philosophies, des publics et des cas d'usage très différents.

## Des origines Unix au noyau Linux

- **Unix** est créé en 1969 aux Bell Labs (AT&T) par Ken Thompson et Dennis Ritchie. Sa réécriture en langage C (plutôt qu'en assembleur) le rend portable sur des machines différentes — une idée révolutionnaire à l'époque.
- Dans les décennies suivantes, Unix se fragmente en plusieurs branches : BSD (Berkeley Software Distribution) côté académique, et des Unix commerciaux comme AIX (IBM), HP-UX (HP) ou Solaris (Sun).
- En 1983, Richard Stallman lance le **projet GNU** ("GNU's Not Unix") avec pour objectif de construire un système d'exploitation complet, compatible Unix, mais entièrement libre. GNU produit des outils essentiels (compilateur `gcc`, shell `bash`, coreutils, éditeur `emacs`...) mais il manque une pièce centrale : le *kernel*.
- En 1991, **Linus Torvalds**, alors étudiant à l'université d'Helsinki, publie sur le forum Usenet `comp.os.minix` un message annonçant son projet de kernel personnel, inspiré de Minix. Ce kernel, nommé **Linux**, va combler le vide laissé par GNU.
- Le système obtenu en associant le kernel Linux aux outils GNU est techniquement un **GNU/Linux**, même si l'usage courant l'appelle simplement "Linux".

## Free Software vs Open Source

Deux organisations formalisent des philosophies proches mais distinctes :

- **Free Software Foundation (FSF)**, fondée par Stallman, défend le logiciel libre autour de quatre libertés fondamentales : exécuter, étudier, redistribuer et modifier un programme. L'argument est **éthique** : le contrôle de l'utilisateur sur son logiciel est une question de liberté.
- **Open Source Initiative (OSI)**, créée en 1998, promeut l'*Open Source Definition*, une approche plus **pragmatique** orientée vers les bénéfices techniques et économiques (qualité du code, collaboration, sécurité par la transparence).

Le terme **FOSS** (Free and Open Source Software) ou **FLOSS** (Free/Libre Open Source Software) est souvent utilisé pour désigner les deux courants sans prendre parti.

## Licences

- **GPL** (GNU General Public License) : licence *copyleft*. Toute œuvre dérivée distribuée doit rester sous GPL et fournir son code source. C'est la licence du kernel Linux lui-même.
- **LGPL** (Lesser GPL) : copyleft plus souple, souvent utilisée pour des bibliothèques (linkage sans obligation de libérer le programme appelant).
- **BSD / MIT** : licences permissives, sans copyleft — le code peut être réutilisé y compris dans des produits propriétaires, à condition de conserver la mention de copyright.
- **Creative Commons (CC)** : ne s'applique pas au code source mais à la documentation, aux images, aux contenus (par exemple CC-BY-SA, utilisée par Wikipédia).

## Kernel, GNU et distributions

Le kernel Linux seul n'est pas un système d'exploitation utilisable : il faut y ajouter un ensemble d'outils, un gestionnaire de paquets, un système d'init, éventuellement un environnement de bureau. C'est ce paquet complet qu'on appelle une **distribution**.

Les grandes familles de distributions :

| Famille | Gestionnaire de paquets | Exemples |
|---|---|---|
| Debian | `.deb` / `apt` | Debian, **Ubuntu**, Linux Mint |
| Red Hat | `.rpm` / `dnf` | Fedora, **RHEL**, Rocky Linux, AlmaLinux |
| SUSE | `.rpm` / `zypper` | openSUSE, SUSE Linux Enterprise |
| Indépendantes | variable | Arch Linux (`pacman`), Slackware, Gentoo |

Une distinction importante : les versions **LTS** (Long Term Support, comme Ubuntu 22.04 LTS ou RHEL) privilégient la stabilité et un support long, alors que les distributions *rolling release* (Arch) livrent en continu les dernières versions logicielles.

## Identifier sa distribution en ligne de commande

```
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="22.04.4 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.4 LTS"
VERSION_CODENAME=jammy
```

```
$ uname -a
Linux srv01 6.2.0-39-generic #40-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
```

```
$ hostnamectl
   Static hostname: srv01
         Icon name: computer-vm
           Chassis: vm
        Machine ID: 3f7b9c6e2d4a4e0a9b1e2c3d4e5f6a7b
           Boot ID: 8a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d
    Operating System: Ubuntu 22.04.4 LTS
              Kernel: Linux 6.2.0-39-generic
        Architecture: x86-64
```

`uname -a` interroge le kernel directement, alors que `/etc/os-release` et `hostnamectl` donnent l'information au niveau de la distribution — une nuance utile à distinguer à l'examen.

## Linux au-delà du poste de bureau

Linux domine largement des environnements où son adoption est moins visible pour l'utilisateur final :

- **Android** (Google) utilise le kernel Linux, mais pas les outils GNU — c'est un exemple de système basé sur Linux sans être un GNU/Linux.
- **Cloud Computing** : la grande majorité des machines virtuelles proposées par les fournisseurs cloud (AWS, Azure, GCP) tournent sous Linux.
- **Conteneurs** : des technologies comme Docker ou Kubernetes reposent directement sur des fonctionnalités du kernel Linux (*cgroups*, *namespaces*) pour isoler les processus.
- **Systèmes embarqués et IoT** : routeurs, télévisions connectées, objets connectés (souvent via des distributions minimalistes comme OpenWrt).
- **CI/CD** : la plupart des runners d'intégration continue (GitHub Actions, GitLab CI) utilisent des images Linux par défaut.

Cette omniprésence explique pourquoi Linux Essentials considère la connaissance de l'écosystème Linux comme un prérequis, même pour des profils qui ne travailleront pas uniquement sur des serveurs.

## Références

- LPI Learning Materials — 1.1 Linux Evolution and Popular Operating Systems : https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- The Linux Kernel Archives : https://www.kernel.org/
- Free Software Foundation — définition du logiciel libre : https://www.gnu.org/philosophy/free-sw.html
- GNU/Linux FAQ : https://www.gnu.org/gnu/gnu-linux-faq.html
- Open Source Initiative — The Open Source Definition : https://opensource.org/osd
- Creative Commons — À propos des licences : https://creativecommons.org/about/cclicenses/
- Debian Project : https://www.debian.org/
- Ubuntu : https://ubuntu.com/
- Fedora Project : https://getfedora.org/
- SUSE : https://www.suse.com/
- Kubernetes — Documentation officielle : https://kubernetes.io/docs/home/