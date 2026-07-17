# Exercices guidés — Thème 1.1 : Linux Evolution and Popular Operating Systems

**Certification :** LPI Linux Essentials (examen 010-160, v1.6)
**Poids à l'examen :** 2
**Source de référence :** https://learning.lpi.org/en/learning-materials/010-160/1/1.1/

---

## Exercice 1 — Identifier le kernel et la distribution utilisés

1. Ouvrez un terminal sur votre machine Linux.
2. Exécutez la commande `uname -a` et notez la version du kernel affichée.
3. Exécutez `cat /etc/os-release` et notez le champ `NAME` ainsi que le champ `ID`.
4. Comparez les deux résultats : le premier concerne le kernel, le second concerne la distribution.

**Questions :**
- Quelle différence fondamentale existe-t-il entre le kernel Linux et une distribution (distro) comme Debian, Fedora ou Arch Linux ?
- Pourquoi deux distributions différentes peuvent-elles afficher exactement la même version de kernel avec `uname -a` ?

---

## Exercice 2 — Observer la frontière entre kernel space et user space

1. Exécutez `ps aux | head -n 10` pour lister quelques processus en cours d'exécution.
2. Exécutez `ps -ef | grep -i "\[.*\]"` pour repérer les processus dont le nom apparaît entre crochets (ce sont des kernel threads).
3. Exécutez `htop` (ou `top` si `htop` n'est pas installé) et observez la colonne `%CPU`/`%MEM` d'un processus utilisateur ordinaire, par exemple votre shell ou un navigateur.
4. Quittez avec la touche `q`.

**Questions :**
- Que représentent les processus affichés entre crochets à l'étape 2, et en quoi diffèrent-ils des processus utilisateurs classiques ?
- Le kernel est souvent décrit comme l'intermédiaire entre le matériel (hardware) et les applications. Illustrez ce rôle à partir de ce que vous avez observé.

---

## Exercice 3 — Comparer des distributions populaires (recherche guidée)

1. Rendez-vous sur un site de comparaison de distributions tel que distrowatch.com.
2. Recherchez trois distributions parmi : Debian, Fedora, openSUSE, Arch Linux, Ubuntu.
3. Pour chacune, notez : le package manager utilisé (ex. `apt`, `dnf`, `pacman`, `zypper`), le modèle de release (rolling release ou fixed release), et l'organisation ou communauté qui la maintient.
4. Identifiez laquelle de ces distributions sert de base à une autre (par exemple, une distribution dérivée d'une autre via un processus de fork ou de rebasing).

**Questions :**
- Quelle distribution utilise un modèle rolling release, et qu'est-ce que cela implique concrètement pour un utilisateur en termes de mises à jour ?
- Donnez un exemple de distribution communautaire (community-driven) et un exemple de distribution soutenue commercialement par une entreprise. Quelle différence cela peut-il faire sur le rythme de développement ?

---

## Exercice 4 — Identifier la licence d'un logiciel installé

1. Choisissez un paquet installé sur votre système, par exemple `bash`.
2. Si vous êtes sur une distribution basée sur Debian/Ubuntu, exécutez `apt-cache show bash | grep -i licen` ou consultez directement `/usr/share/doc/bash/copyright`.
3. Si vous êtes sur une distribution basée sur Fedora/RHEL, exécutez `rpm -qi bash` puis repérez le champ `License`.
4. Notez le nom exact de la licence trouvée (par exemple GPL, LGPL, ou BSD).

**Questions :**
- Quelle est la différence essentielle entre une licence de type copyleft (comme la GPL) et une licence permissive (comme la BSD ou la licence MIT) ?
- Le kernel Linux lui-même est distribué sous une licence précise. Laquelle, et pourquoi ce choix a-t-il été déterminant pour l'essor du logiciel libre (free software) ?

---

## Exercice 5 — Repérer Linux au-delà du desktop

1. Sur un smartphone Android, ouvrez les paramètres et cherchez la section "À propos du téléphone" / "Version d'Android" (ou recherchez en ligne "Android kernel Linux" si vous n'avez pas d'appareil sous la main).
2. Recherchez en ligne le nom du système d'exploitation utilisé par le supercalculateur (supercomputer) le mieux classé au TOP500 (top500.org).
3. Recherchez si votre routeur domestique ou une Smart TV que vous possédez utilise un firmware basé sur Linux (souvent mentionné dans les mentions légales de l'appareil, sous forme de licences open source incluses).
4. Listez au moins quatre catégories différentes de dispositifs (devices) où Linux est présent : desktop, server, mobile, embedded systems, cloud computing, mainframe.

**Questions :**
- Pourquoi peut-on dire que Linux n'est pas un simple "système d'exploitation de bureau" mais une plateforme omniprésente (ubiquitous) ?
- Citez deux raisons techniques ou économiques qui expliquent pourquoi les fabricants de dispositifs embedded choisissent souvent Linux plutôt qu'un système propriétaire.

---

## Exercice 6 — Situer les organisations clés de l'écosystème open source

1. Recherchez en ligne le rôle de la Free Software Foundation (FSF) et celui de l'Open Source Initiative (OSI).
2. Recherchez le rôle de la Linux Foundation, qui héberge notamment le développement du kernel Linux.
3. Recherchez ce qu'est le Linux Professional Institute (LPI) et en quoi son rôle diffère de celui des organisations précédentes.
4. Notez, pour chacune de ces quatre organisations, une phrase résumant sa mission principale.

**Questions :**
- Quelle différence de philosophie sépare historiquement la FSF (mettant l'accent sur les libertés de l'utilisateur, free as in freedom) et l'OSI (mettant l'accent sur les avantages pratiques du modèle de développement open source) ?
- En quoi le rôle de la Linux Foundation (soutien technique et financier au développement du kernel) diffère-t-il de celui du LPI (certification des compétences professionnelles) ?

---

<details>
<summary>Réponses</summary>

**Exercice 1**
- Le kernel est le cœur du système d'exploitation : il gère le matériel (CPU, mémoire, périphériques) et fournit les services de base aux programmes. Une distribution (distro) est un ensemble complet construit autour de ce kernel : elle y ajoute un package manager, des bibliothèques système, des utilitaires, parfois un environnement graphique, et des choix de configuration par défaut.
- Le kernel Linux est développé de façon centralisée et versionné indépendamment des distributions. Plusieurs distributions peuvent donc empaqueter et distribuer exactement la même version de kernel, tout en différant totalement par le reste du système (userland, outils, philosophie).

**Exercice 2**
- Les processus entre crochets sont des kernel threads : ils s'exécutent en kernel space, n'ont pas d'espace mémoire utilisateur propre et n'ont généralement pas de fichier exécutable associé sur le disque. Les processus utilisateurs classiques s'exécutent en user space, avec leur propre espace mémoire isolé et protégé.
- Le kernel arbitre l'accès de tous les processus utilisateurs au matériel : quand une application (user space) a besoin de lire un fichier ou d'utiliser le réseau, elle passe par un appel système (syscall) traité par le kernel, qui seul dialogue directement avec le hardware.

**Exercice 3**
- Arch Linux est un exemple typique de rolling release : il n'existe pas de "version" figée à installer puis mettre à jour majeure par majeure ; le système reçoit un flux continu de mises à jour, ce qui donne accès à des logiciels très récents mais demande davantage de vigilance de la part de l'utilisateur.
- Exemple communautaire : Debian, gouvernée par ses développeurs volontaires et le Debian Social Contract. Exemple soutenu commercialement : Fedora, sponsorisée par Red Hat (elle-même propriété d'IBM), qui sert de terrain d'essai pour Red Hat Enterprise Linux. Le soutien commercial peut accélérer le rythme de développement et garantir un support à long terme, tandis qu'un projet purement communautaire dépend du rythme et des priorités de ses contributeurs bénévoles.

**Exercice 4**
- Une licence copyleft comme la GPL impose que toute œuvre dérivée distribuée soit publiée sous la même licence, avec le code source disponible : elle garantit que la liberté se transmet. Une licence permissive comme la BSD ou la MIT autorise la réutilisation, y compris dans un logiciel propriétaire fermé, sans obligation de republier le code source.
- Le kernel Linux est distribué sous la GPLv2. Ce choix a garanti que toute amélioration ou dérivation du kernel reste ouverte et partagée avec la communauté, ce qui a fortement encouragé les contributions d'entreprises et de développeurs individuels sans crainte qu'un tiers ne s'approprie le code de façon fermée.

**Exercice 5**
- Linux fonctionne à la fois sur des smartphones (via Android), des serveurs, des supercalculateurs, des équipements réseau, des systèmes embedded (routeurs, télévisions, voitures) et dans le cloud computing. Cette diversité montre que Linux est une plateforme universelle bien au-delà de l'usage desktop, qui reste d'ailleurs son usage le moins répandu en proportion.
- Deux raisons courantes : le coût (pas de royalties de licence à payer par unité produite) et la flexibilité (le code source est modifiable pour s'adapter à du matériel très spécifique ou à des contraintes de ressources limitées propres à l'embedded).

**Exercice 6**
- FSF : mission — Free Software Foundation. OSI : mission — Open Source Initiative. Linux Foundation : mission — héberger et financer le développement du kernel Linux et de nombreux projets open source associés. LPI : mission — Linux Professional Institute, certifier les compétences professionnelles des individus sur Linux.
- La FSF met l'accent sur une dimension éthique : garantir aux utilisateurs les libertés d'exécuter, étudier, modifier et redistribuer le logiciel (free as in freedom). L'OSI met plutôt en avant les bénéfices pratiques et techniques du développement ouvert (qualité, sécurité, collaboration), sans nécessairement insister sur l'argument moral.
- La Linux Foundation opère au niveau des projets et du code (financement d'infrastructure, coordination des contributeurs, hébergement de projets comme le kernel Linux ou Kubernetes), tandis que le LPI opère au niveau des individus, en délivrant des certifications qui valident des compétences professionnelles standardisées.

</details>