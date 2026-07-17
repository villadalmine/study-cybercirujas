# 1.2 Major Open Source Applications

**Examen :** LPI Linux Essentials (010-160, version 1.6) · **Poids :** 2

---

## 1. Applications de bureau (Desktop Applications)

Le kernel Linux n'est qu'une petite partie de ce que l'utilisateur voit au quotidien. La grande majorité des logiciels avec lesquels on interagit sont des applications open source, souvent multiplateformes (disponibles aussi sous Windows et macOS).

### Suites bureautiques

- **LibreOffice** : la suite bureautique open source de référence, née d'un *fork* du projet OpenOffice.org. Elle regroupe :
  - *Writer* (traitement de texte), *Calc* (tableur), *Impress* (présentations), *Draw* (dessin vectoriel), *Base* (bases de données), *Math* (édition de formules).
  - Format natif : **Open Document Format (ODF)**, un standard ouvert ISO (`.odt`, `.ods`, `.odp`), avec compatibilité de lecture/écriture des formats Microsoft Office (`.docx`, `.xlsx`, `.pptx`).

### Navigateurs web

- **Mozilla Firefox** : navigateur entièrement open source, développé par la Mozilla Foundation.
- **Chromium** : projet open source à la base du navigateur propriétaire **Google Chrome** ; d'autres navigateurs (Edge, Opera, Brave) en dérivent également.

### Clients de messagerie

- **Mozilla Thunderbird** : client de messagerie de bureau complet, compatible **IMAP**, **POP3** et **SMTP**, avec calendrier, carnet d'adresses et flux RSS.
- Le webmail est aujourd'hui très répandu, mais les clients de bureau restent courants en entreprise.

### Multimédia et graphisme

- **GIMP** (*GNU Image Manipulation Program*) : éditeur d'images matricielles (*raster*), équivalent open source de Photoshop.
- **Inkscape** : éditeur de graphisme vectoriel, équivalent open source d'Illustrator.
- **Blender** : modélisation 3D, animation et rendu.
- **VLC** : lecteur multimédia capable de lire pratiquement tous les formats audio/vidéo.
- **Audacity** : enregistrement et édition audio.
- **ImageMagick** : conversion et manipulation d'images en ligne de commande.

```bash
$ convert photo.png -resize 800x600 photo-small.jpg
$ identify photo.png
photo.png PNG 1920x1080 1920x1080+0+0 8-bit sRGB 2.1MiB 0.000u 0:00.000
```

---

## 2. Applications serveur (Server Applications)

Linux domine le marché des serveurs, et une grande partie de l'infrastructure d'Internet repose sur les logiciels open source suivants.

### Serveurs web

- **Apache HTTP Server (httpd)** : historiquement le serveur web le plus déployé au monde ; extensible par modules (`mod_ssl`, `mod_rewrite`, etc.).
- **NGINX** : serveur web plus récent, conçu pour une forte concurrence de connexions ; très utilisé aussi comme **reverse proxy** et répartiteur de charge.

```bash
$ ss -tlnp | grep :80
LISTEN 0  511  0.0.0.0:80  0.0.0.0:*  users:(("nginx",pid=1234,fd=6))
```

### Bases de données

Les applications web stockent généralement leurs données dans une base relationnelle (la pile classique **LAMP** = Linux + Apache + MySQL + PHP) :

- **MySQL / MariaDB** : MariaDB est un *fork* communautaire de MySQL, créé après le rachat de MySQL par Oracle ; c'est un remplacement direct (*drop-in replacement*), installé par défaut sur de nombreuses distributions.
- **PostgreSQL** : base de données relationnelle avancée, réputée pour son intégrité des données et sa conformité au standard SQL.
- **SQLite** : base de données embarquée légère, stockée dans un seul fichier, utilisée à l'intérieur de nombreuses applications plutôt que comme serveur autonome.

```bash
$ mysql -u root -p
Enter password:
Welcome to the MariaDB monitor.  Commands end with ; or \g.
MariaDB [(none)]> SHOW DATABASES;
```

### Partage de fichiers et services réseau

- **Samba** : implémente le protocole **SMB/CIFS**, permettant à un serveur Linux de partager fichiers et imprimantes avec des clients Windows, voire de jouer le rôle de contrôleur de domaine Active Directory.
- **NFS** (*Network File System*) : protocole traditionnel UNIX/Linux pour partager des systèmes de fichiers entre machines Linux/UNIX.
- **OpenSSH** : accès distant sécurisé et transfert de fichiers (`ssh`, `scp`, `sftp`).
- **Postfix** et **Exim** : agents de transfert de courrier (**MTA**, *Mail Transfer Agent*) qui acheminent les emails entre serveurs via SMTP (successeurs de l'ancien *Sendmail*).
- **Dovecot** : serveur IMAP/POP3 qui livre le courrier stocké aux clients.
- **Nextcloud / ownCloud** : plateformes auto-hébergées de synchronisation de fichiers et de collaboration (alternative open source à Dropbox/Google Drive).

### Cloud et virtualisation

- **KVM** : hyperviseur de virtualisation intégré au kernel Linux.
- **Docker / Podman** : moteurs de conteneurs pour empaqueter et exécuter des applications dans des environnements isolés.
- **OpenStack** : plateforme pour construire des clouds privés (*Infrastructure as a Service*).
- **Kubernetes** : orchestration de conteneurs à travers des clusters de machines.

---

## 3. Langages de développement

Les systèmes Linux embarquent, ou mettent facilement à disposition, de nombreux langages de programmation. L'examen attend qu'on sache reconnaître les principaux.

| Langage | Type | Usage typique sous Linux |
|---|---|---|
| **Shell (Bash)** | Interprété | Automatisation système, scripts de liaison (*glue scripts*), shell interactif par défaut |
| **C** | Compilé | Le kernel lui-même et la plupart des utilitaires système de base |
| **C++** | Compilé | Environnements de bureau, navigateurs, logiciels critiques en performance |
| **Python** | Interprété | Automatisation, calcul scientifique, backends web, outils système (`dnf` est écrit en Python) |
| **Perl** | Interprété | Traitement de texte, scripts système historiques |
| **PHP** | Interprété | Développement web côté serveur (le « P » de LAMP ; utilisé par WordPress) |
| **JavaScript** | Interprété | Frontends web dans le navigateur ; côté serveur via Node.js |
| **Java** | Compilé en bytecode | Applications d'entreprise, développement Android |

Un premier script shell illustre le modèle interprété — la ligne `#!` (*shebang*) indique l'interpréteur à utiliser :

```bash
$ cat hello.sh
#!/bin/bash
echo "Hello, $USER"
$ chmod +x hello.sh
$ ./hello.sh
Hello, carol
```

Les langages compilés passent au contraire par un compilateur comme **GCC** (*GNU Compiler Collection*) avant de pouvoir s'exécuter :

```bash
$ gcc hello.c -o hello
$ ./hello
Hello, world
```

---

## 4. Gestion de paquets (Package Management)

Presque tous les logiciels d'un système Linux sont installés sous forme de **paquets** : des archives contenant les fichiers du programme ainsi que des métadonnées (version, dépendances, sommes de contrôle). Les paquets proviennent de **dépôts** (*repositories*) : des serveurs maintenus par la distribution, hébergeant des milliers de paquets testés. Le gestionnaire de paquets télécharge les paquets, résout automatiquement les **dépendances**, et garde la trace de chaque fichier installé.

Deux grandes familles dominent l'écosystème.

### Famille Debian (`.deb`) — Debian, Ubuntu, Linux Mint

- **`dpkg`** : outil de bas niveau qui installe des fichiers `.deb` individuels.
- **`apt`** : outil de haut niveau qui interroge les dépôts et résout les dépendances.

```bash
$ sudo apt update                # rafraîchit les métadonnées des dépôts
$ sudo apt install firefox       # installe avec les dépendances
$ sudo apt upgrade               # met à jour tous les paquets installés
$ apt search image editor        # recherche de paquets
$ sudo apt remove firefox        # désinstalle
```

### Famille Red Hat (`.rpm`) — RHEL, Fedora, CentOS Stream, openSUSE

- **`rpm`** : outil de bas niveau pour les fichiers `.rpm` individuels.
- **`dnf`** : outil de haut niveau pour les dépôts sur Fedora/RHEL (successeur de `yum`) ; openSUSE utilise **`zypper`**.

```bash
$ sudo dnf install gimp
$ sudo dnf upgrade
$ dnf search gimp
$ sudo dnf remove gimp
```

### Formats indépendants de la distribution

Des formats plus récents empaquettent une application avec toutes ses dépendances, pour qu'un seul paquet fonctionne sur n'importe quelle distribution : **Snap**, **Flatpak** et **AppImage**.

**Point clé pour l'examen :** associer le bon outil à la bonne famille — `dpkg`/`apt` ↔ Debian/Ubuntu, `rpm`/`dnf`/`yum`/`zypper` ↔ Red Hat/SUSE. Mélanger des formats de paquets entre familles n'est pas pris en charge.

---

## Résumé pour l'examen

- **LibreOffice** = suite bureautique (format natif ODF) ; **GIMP** = édition d'images ; **Firefox/Chromium** = navigateurs ; **Thunderbird** = client de messagerie.
- **Apache** et **NGINX** servent le web ; **MariaDB/MySQL** et **PostgreSQL** stockent ses données ; **Samba** partage des fichiers avec Windows ; **NFS** partage des fichiers entre systèmes Linux.
- **LAMP** = Linux, Apache, MySQL, PHP — la pile web open source classique.
- Langages interprétés (Bash, Python, Perl, PHP, JavaScript) s'exécutent via un interpréteur ; langages compilés (C, C++) sont construits avec GCC.
- Paquets + dépôts + résolution de dépendances = comment Linux installe ses logiciels ; il faut connaître les deux familles de paquets et leurs outils respectifs.

---

## Références

- LPI Learning Materials — Topic 1.2 Major Open Source Applications : https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- Objectifs officiels de l'examen Linux Essentials 010-160 : https://www.lpi.org/our-certifications/exam-010-objectives/
- Documentation LibreOffice : https://documentation.libreoffice.org/
- Documentation GIMP : https://docs.gimp.org/
- Documentation Apache HTTP Server : https://httpd.apache.org/docs/
- Documentation NGINX : https://nginx.org/en/docs/
- Documentation MariaDB : https://mariadb.org/documentation/
- Documentation PostgreSQL : https://www.postgresql.org/docs/
- Documentation Samba : https://www.samba.org/samba/docs/
- Gestion de paquets Debian (apt) : https://www.debian.org/doc/manuals/debian-faq/pkgtools.en.html
- Documentation Fedora DNF : https://docs.fedoraproject.org/en-US/quick-docs/dnf/
