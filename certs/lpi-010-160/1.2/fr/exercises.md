# TP guidés — Sujet 1.2 : Major Open Source Applications

**Certification :** LPI Linux Essentials (010-160, v1.6)
**Poids à l'examen :** 2
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/1/1.2/

Vous aurez besoin d'une machine Linux (physique, VM ou WSL) avec accès à Internet. Toutes les commandes sont soit en lecture seule, soit clairement marquées comme installation optionnelle — rien ici ne modifie durablement votre système.

---

## Exercice 1 — Identifier la famille de paquets de votre système

1. Ouvrez un terminal.
2. Vérifiez la présence des outils de la famille Debian :
   ```bash
   which dpkg apt
   ```
3. Vérifiez la présence des outils de la famille Red Hat :
   ```bash
   which rpm dnf yum
   ```
4. Selon la famille identifiée, affichez la version du gestionnaire de paquets :
   ```bash
   apt --version      # famille Debian
   dnf --version      # famille Red Hat
   ```
5. Comptez le nombre de paquets actuellement installés :
   ```bash
   dpkg -l | wc -l         # famille Debian
   rpm -qa | wc -l         # famille Red Hat
   ```

**Questions de compréhension**
- Quel format de fichier utilise chaque famille de paquets, et citez deux distributions par famille.
- Qu'est-ce qu'un **dépôt** (*repository*), et pourquoi installer depuis un dépôt est-il généralement plus sûr que de télécharger un installeur sur un site quelconque ?
- Un collègue sous Fedora tape `apt install gimp` et obtient « command not found ». Pourquoi ?

---

## Exercice 2 — Explorer les applications de bureau et leurs formats de fichiers

1. Vérifiez si LibreOffice est installé et quelle version :
   ```bash
   libreoffice --version
   ```
   S'il n'est pas installé, interrogez plutôt le dépôt (sans rien installer) :
   ```bash
   apt show libreoffice-writer     # famille Debian
   dnf info libreoffice-writer    # famille Red Hat
   ```
2. Listez les binaires liés à LibreOffice disponibles sur votre système :
   ```bash
   ls /usr/bin | grep -i -E 'libre|soffice'
   ```
3. Interrogez le gestionnaire de paquets sur trois autres applications de bureau :
   ```bash
   apt show gimp inkscape thunderbird      # famille Debian
   dnf info gimp inkscape thunderbird     # famille Red Hat
   ```
   Lisez le champ `Description` de chacune.
4. Si vous disposez d'un environnement graphique, ouvrez LibreOffice Writer, tapez une phrase, puis utilisez *Fichier → Enregistrer sous* pour observer l'extension proposée par défaut. Fermez sans enregistrer si vous préférez.

**Questions de compréhension**
- Associez chaque composant de LibreOffice à son usage : **Writer**, **Calc**, **Impress**, **Base**, **Draw**, **Math**.
- Qu'est-ce que l'**Open Document Format (ODF)**, et quelles extensions utilisent les documents Writer, Calc et Impress ?
- Quelle application open source recommanderiez-vous pour : (i) retoucher une photo, (ii) créer un graphisme vectoriel comme un logo, (iii) faire de la modélisation et de l'animation 3D, (iv) lire ses emails sur le bureau ?
- Firefox et Chromium sont tous deux des navigateurs open source. Quelle organisation développe Firefox ?

---

## Exercice 3 — Enquêter sur les applications serveur sans les installer

1. Recherchez les deux serveurs web open source dominants :
   ```bash
   apt show apache2 nginx        # famille Debian
   dnf info httpd nginx         # famille Red Hat
   ```
   Notez que le paquet Apache HTTP Server s'appelle `apache2` sous Debian/Ubuntu et `httpd` sous Red Hat/Fedora.
2. Recherchez le serveur de partage de fichiers qui permet à Linux de dialoguer avec des réseaux Windows :
   ```bash
   apt show samba       # ou : dnf info samba
   ```
3. Vérifiez quels services réseau écoutent réellement sur votre machine en ce moment :
   ```bash
   ss -tln
   ```
   Sur un poste de bureau, la liste est généralement courte ; sur un serveur, vous pourriez voir des ports comme 80 (HTTP), 443 (HTTPS) ou 445 (SMB).
4. *(Optionnel, si vous voulez tester un vrai serveur web et que votre système utilise `apt`)* Installez NGINX, vérifiez qu'il sert une page, puis désinstallez-le :
   ```bash
   sudo apt install nginx
   curl http://localhost
   sudo apt remove nginx
   ```

**Questions de compréhension**
- Citez les deux serveurs web open source les plus déployés au monde.
- Quel protocole implémente **Samba**, et quel est son usage principal ?
- Une entreprise veut héberger elle-même un cloud privé de synchronisation et de collaboration de fichiers plutôt que d'utiliser un service propriétaire. Citez une application open source conçue exactement pour cela.
- Quels agents de transfert de courrier (**MTA**, *Mail Transfer Agent*) open source connaissez-vous ? (L'examen attend d'en reconnaître au moins un.)

---

## Exercice 4 — Prendre en main une base de données open source

**SQLite** est une base de données SQL minuscule et *serverless*, parfaite pour un premier contact — elle est généralement déjà installée ou disponible dans tout dépôt.

1. Vérifiez si SQLite est disponible :
   ```bash
   sqlite3 --version
   ```
   Sinon, installez-la (`sudo apt install sqlite3` ou `sudo dnf install sqlite`) — elle ne pèse que quelques centaines de kilo-octets.
2. Démarrez une base de données **en mémoire** (rien n'est écrit sur le disque) :
   ```bash
   sqlite3 :memory:
   ```
3. Au prompt `sqlite>`, créez une table et insérez des données :
   ```sql
   CREATE TABLE apps (name TEXT, category TEXT);
   INSERT INTO apps VALUES ('GIMP', 'graphics'), ('Apache', 'web server'), ('MariaDB', 'database');
   SELECT * FROM apps WHERE category = 'database';
   ```
4. Quittez avec `.quit`.
5. Interrogez maintenant le gestionnaire de paquets pour les deux grandes bases de données client-serveur open source :
   ```bash
   apt show mariadb-server postgresql      # famille Debian
   dnf info mariadb-server postgresql-server   # famille Red Hat
   ```

**Questions de compréhension**
- MariaDB est né comme un *fork* d'une autre base de données célèbre. Laquelle, et pourquoi ce fork a-t-il eu lieu ?
- Quelle est la différence architecturale principale entre SQLite et MariaDB/PostgreSQL ?
- Dans la pile classique **LAMP**, que signifient les quatre lettres ?

---

## Exercice 5 — Retrouver les langages de programmation déjà présents sur votre système

1. Vérifiez quels interpréteurs et compilateurs sont présents :
   ```bash
   bash --version
   python3 --version
   perl -v | head -2
   gcc --version 2>/dev/null || echo "aucun compilateur C installé"
   ```
2. Exécutez une commande **shell** en une ligne :
   ```bash
   echo 'Hello from the shell'
   ```
3. Exécutez un programme **Python** en une ligne, sans créer de fichier :
   ```bash
   python3 -c 'print("Hello from Python")'
   ```
4. Créez puis exécutez un vrai script shell :
   ```bash
   cat > /tmp/hello.sh <<'EOF'
   #!/bin/bash
   echo "Ce système exécute le kernel $(uname -r)"
   EOF
   chmod +x /tmp/hello.sh
   /tmp/hello.sh
   rm /tmp/hello.sh
   ```

**Questions de compréhension**
- Le kernel Linux lui-même est écrit presque entièrement dans un seul langage. Lequel ?
- Quelle est la différence entre un langage **compilé** et un langage **interprété** ? Classez C, Python et le shell script.
- Quel langage s'exécute *à l'intérieur du navigateur web* et est indispensable aux sites interactifs ?
- À quoi sert la ligne `#!/bin/bash` en haut du script de l'étape 4 ?

---

<details>
<summary><strong>Réponses</strong></summary>

**Exercice 1**
- La famille Debian utilise des paquets **`.deb`** (gérés avec `dpkg` et `apt`) — par exemple Debian, Ubuntu, Linux Mint, Raspberry Pi OS. La famille Red Hat utilise des paquets **`.rpm`** (gérés avec `rpm` et `dnf`/`yum`) — par exemple RHEL, Fedora, CentOS Stream, Rocky Linux (openSUSE utilise aussi `.rpm`, avec l'outil `zypper`).
- Un dépôt est une collection de paquets en ligne, maintenue par la distribution. Les paquets qui s'y trouvent sont sélectionnés, signés cryptographiquement, testés avec les versions de la distribution, et reçoivent des mises à jour de sécurité via ce même canal — contrairement à un téléchargement isolé, qu'il faut faire confiance manuellement et mettre à jour soi-même.
- `apt` est un outil de la famille Debian. Fedora appartient à la famille Red Hat, donc la commande équivalente est `dnf install gimp`.

**Exercice 2**
- **Writer** — traitement de texte ; **Calc** — tableur ; **Impress** — présentations ; **Base** — bases de données de bureau ; **Draw** — dessin et diagrammes ; **Math** — édition de formules mathématiques.
- L'ODF (Open Document Format) est le **format de fichier ouvert et normalisé (ISO/IEC 26300)** utilisé nativement par LibreOffice. Extensions : `.odt` (texte/Writer), `.ods` (tableur/Calc), `.odp` (présentation/Impress). Être un standard ouvert signifie que n'importe quel éditeur peut l'implémenter, donc vos documents ne sont pas enfermés dans un seul produit.
- (i) **GIMP** (GNU Image Manipulation Program) pour l'édition d'images matricielles/photo ; (ii) **Inkscape** pour le graphisme vectoriel ; (iii) **Blender** pour la modélisation, l'animation et le rendu 3D ; (iv) **Thunderbird** comme client de messagerie de bureau.
- Firefox est développé par la **Mozilla Foundation** (et Mozilla Corporation).

**Exercice 3**
- **Apache HTTP Server** et **NGINX**. À eux deux, ils servent une grande part de tous les sites web sur Internet.
- Samba implémente le protocole **SMB/CIFS**. Il permet à une machine Linux de partager fichiers et imprimantes avec des clients Windows (et même de jouer le rôle de contrôleur de domaine), faisant de Linux un serveur de fichiers directement compatible dans un réseau Windows.
- **Nextcloud** (ou son prédécesseur **ownCloud**) — une plateforme auto-hébergée de synchronisation, partage de fichiers, calendriers, contacts et édition collaborative.
- Les MTA open source courants incluent **Postfix**, **Sendmail** et **Exim** (souvent accompagnés de **Dovecot** comme serveur IMAP/POP3 pour l'accès aux boîtes de messagerie).

**Exercice 4**
- MariaDB est un fork de **MySQL**. Lors du rachat de MySQL par Oracle (via Sun Microsystems, en 2010), les développeurs d'origine — inquiets pour l'avenir du projet sous un seul propriétaire commercial — ont *forké* le code et l'ont poursuivi sous le nom de MariaDB, sous licence open source. Cette possibilité de fork est une liberté fondamentale du logiciel open source.
- SQLite est une bibliothèque **serverless et embarquée** : la base de données est un seul fichier (ou de la mémoire) accédé directement par l'application, sans processus séparé. MariaDB et PostgreSQL sont des systèmes **client-serveur** : un processus serveur dédié gère les données, sert de nombreux clients simultanés via le réseau, et applique des utilisateurs et permissions.
- **L**inux, **A**pache, **M**ySQL (ou MariaDB), et **P**HP (parfois Perl ou Python) — la pile open source classique pour les sites web dynamiques.

**Exercice 5**
- **C** (avec un peu d'assembleur, et plus récemment un peu de Rust dans certains sous-systèmes).
- Un langage **compilé** est traduit à l'avance par un compilateur en code machine que le CPU exécute directement (ex. **C**, compilé avec `gcc`). Un langage **interprété** est lu et exécuté au moment de l'exécution par un interpréteur, sans étape de compilation séparée (ex. **Python** et le shell script). Les programmes interprétés sont plus faciles à modifier et s'exécutent partout où l'interpréteur est présent ; les programmes compilés sont généralement plus rapides.
- **JavaScript** — le seul langage nativement exécuté par les navigateurs web, utilisé pour rendre les pages interactives. (JavaScript existe aussi côté serveur, par exemple avec Node.js.)
- C'est la ligne **shebang**. Lors de l'exécution du fichier, le kernel lit `#!/bin/bash` et lance `/bin/bash` comme interpréteur du script — le script s'exécute donc de la même façon quel que soit le shell utilisé par l'utilisateur au moment de le lancer.

</details>
