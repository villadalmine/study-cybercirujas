# 4.2 Understanding Computer Hardware

## Introduction

Ce topic couvre les composants matériels fondamentaux d'un ordinateur et les commandes Linux permettant de les identifier, de vérifier leur état et de diagnostiquer les problèmes matériels. Un administrateur Linux doit savoir reconnaître le hardware disponible sur une machine sans avoir à l'ouvrir physiquement, en s'appuyant sur les interfaces que le kernel expose.

## Les composants principaux d'un ordinateur

### CPU (Central Processing Unit)

Le CPU exécute les instructions des programmes. Les caractéristiques importantes sont le nombre de *cores* (physiques et logiques via *hyper-threading*), la fréquence d'horloge (en GHz), l'architecture (x86_64, ARM) et la taille des caches (L1, L2, L3).

```
$ lscpu
Architecture:            x86_64
CPU(s):                  8
Thread(s) per core:      2
Core(s) per socket:      4
Model name:              Intel(R) Core(TM) i5-8400
CPU MHz:                 2800.000
```

On peut aussi consulter directement `/proc/cpuinfo` :

```
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i5-8400 CPU @ 2.80GHz
```

### RAM (Random Access Memory)

La RAM stocke temporairement les données utilisées par les processus en cours d'exécution. Elle est volatile : son contenu disparaît à l'extinction de la machine.

```
$ free -h
              total        used        free      shared  buff/cache   available
Mem:           15Gi       3.2Gi       8.1Gi       412Mi       4.0Gi        11Gi
Swap:         2.0Gi          0B       2.0Gi
```

Le fichier `/proc/meminfo` fournit un détail plus fin (MemTotal, MemFree, Buffers, Cached, etc.).

### Stockage : HDD, SSD, NVMe

- **HDD** (Hard Disk Drive) : disque mécanique avec plateaux magnétiques, plus lent mais moins cher au Go.
- **SSD** (Solid State Drive) : mémoire flash, sans pièces mobiles, accès beaucoup plus rapide.
- **NVMe** (Non-Volatile Memory Express) : protocole utilisant directement le bus PCIe pour connecter des SSD, offrant des débits nettement supérieurs au SATA classique.

```
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda           8:0    0 465.8G  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
└─sda2        8:2    0 465.3G  0 part /
nvme0n1     259:0    0 931.5G  0 disk
```

`lsblk` liste les *block devices* (disques et partitions), tandis que `df -h` affiche l'utilisation de l'espace sur les systèmes de fichiers montés.

### Carte mère (motherboard) et BIOS/UEFI

La carte mère (*motherboard*) relie tous les composants entre eux via des bus et des connecteurs. Le **BIOS** (Basic Input/Output System) ou son successeur **UEFI** (Unified Extensible Firmware Interface) initialise le matériel au démarrage avant de passer la main au *bootloader*.

```
$ sudo dmidecode -t bios
BIOS Information
        Vendor: American Megatrends Inc.
        Version: F.20
```

### Bus et interfaces d'extension

- **PCIe** (Peripheral Component Interconnect Express) : bus utilisé par les cartes graphiques, cartes réseau, contrôleurs NVMe.
- **USB** (Universal Serial Bus) : périphériques externes (clavier, souris, clés USB, disques externes).
- **SATA** (Serial ATA) : connexion classique pour disques HDD/SSD.

```
$ lspci | grep -i vga
01:00.0 VGA compatible controller: NVIDIA Corporation GP107 [GeForce GTX 1050]

$ lsusb
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
```

`lspci` liste les périphériques connectés sur le bus PCI/PCIe, `lsusb` fait de même pour l'USB.

### Autres périphériques

- **Carte graphique (GPU)** : traitement de l'affichage et calcul parallèle.
- **Carte réseau (NIC)** : interface réseau filaire (Ethernet) ou sans fil (Wi-Fi).
- **Périphériques d'entrée/sortie** : clavier, souris, écran, imprimante.

## Découvrir et diagnostiquer le matériel sous Linux

Le kernel Linux expose les informations matérielles via le système de fichiers virtuel `/proc` et `/sys`, ainsi que via des commandes dédiées :

| Commande      | Usage                                                  |
|---------------|---------------------------------------------------------|
| `lscpu`       | Informations sur le(s) CPU                              |
| `lsblk`       | Liste des disques et partitions                          |
| `lspci`       | Périphériques sur le bus PCI/PCIe                        |
| `lsusb`       | Périphériques USB connectés                              |
| `free -h`     | Utilisation de la RAM et du swap                         |
| `dmesg`       | Messages du kernel, y compris la détection du hardware  |
| `lshw`        | Vue détaillée de l'ensemble du hardware (souvent nécessite `sudo`) |

```
$ sudo lshw -short
H/W path       Device      Class          Description
=======================================================
                           system         Latitude 5490
/0                         bus            0Y2H1H
/0/0                       memory         64KiB BIOS
/0/4                       processor      Intel(R) Core(TM) i5-8350U
```

Lors du démarrage, le kernel détecte automatiquement le matériel et affiche des messages consultables avec `dmesg`, par exemple pour repérer une clé USB fraîchement branchée :

```
$ dmesg | tail -5
[12345.678] usb 1-2: new high-speed USB device number 5 using xhci_hcd
[12345.789] usb-storage 1-2:1.0: USB Mass Storage device detected
[12345.790] sd 6:0:0:0: [sdb] Attached SCSI removable disk
```

## Références

- LPI Learning Materials — Topic 4.2 Understanding Computer Hardware : https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- `man lscpu`, `man lsblk`, `man lspci`, `man lsusb`, `man dmesg`, `man free`