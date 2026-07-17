# Open Source Software and Licensing

## 1. Introduction : deux philosophies, un même code

Le mouvement du logiciel libre distingue deux courants historiques qui se recoupent largement dans la pratique mais diffèrent dans leur discours :

- **Free Software** (logiciel libre), porté par la **Free Software Foundation (FSF)** fondée par Richard Stallman en 1985. L'accent est mis sur la **liberté** de l'utilisateur, considérée comme une question éthique.
- **Open Source**, porté par l'**Open Source Initiative (OSI)** créée en 1998. L'accent est mis sur les avantages **pratiques** du développement collaboratif : qualité, sécurité, rapidité d'innovation.

Dans les deux cas, le code source doit être accessible, modifiable et redistribuable — ce qui explique pourquoi on utilise souvent le terme **FOSS** (Free and Open Source Software) ou **FLOSS** pour regrouper les deux approches sans trancher le débat philosophique.

## 2. Les quatre libertés du logiciel libre (FSF)

La FSF définit le logiciel libre par quatre libertés fondamentales, numérotées de 0 à 3 :

- **Liberté 0** : exécuter le programme pour n'importe quel usage.
- **Liberté 1** : étudier le fonctionnement du programme et l'adapter à ses besoins (accès au code source obligatoire).
- **Liberté 2** : redistribuer des copies pour aider son entourage.
- **Liberté 3** : distribuer des versions modifiées, pour que la communauté en bénéficie.

Un logiciel qui ne respecte pas l'une de ces quatre libertés n'est pas considéré comme libre, même s'il est gratuit.

## 3. L'Open Source Definition (OSI)

L'OSI propose une définition plus orientée « ingénierie », avec dix critères, dont les plus testés à l'examen sont :

- **Free redistribution** : pas de restriction à la revente ou à la redistribution.
- **Source code** disponible : le code source doit être inclus ou facilement accessible.
- **Derived works** autorisés, sous les mêmes termes de licence.
- **No discrimination** contre des personnes, groupes, ou domaines d'usage (ex : pas d'interdiction d'usage commercial).
- **License must not be specific to a product** : les droits s'appliquent même si le logiciel est extrait de sa distribution d'origine.

## 4. Copyleft vs licences permissives

C'est la distinction la plus importante à retenir pour l'examen.

### 4.1 Copyleft

Une licence **copyleft** exige que toute œuvre dérivée soit distribuée sous la **même licence** (ou une licence compatible). C'est le principe du « partage à l'identique ».

- **GPL (GNU General Public License)** : copyleft fort. Si vous distribuez un binaire lié à du code GPL, vous devez fournir le code source sous GPL.
- **LGPL (Lesser GPL)** : copyleft « faible », pensé pour les bibliothèques (libraries) — permet de lier dynamiquement du code propriétaire sans devoir libérer ce dernier.
- **AGPL (Affero GPL)** : étend le copyleft aux logiciels utilisés via un réseau (SaaS), pour combler le « ASP loophole » (utiliser du code GPL modifié sur un serveur sans jamais le redistribuer).

### 4.2 Licences permissives

Une licence **permissive** autorise la réutilisation dans des projets propriétaires, sans obligation de reverser les modifications.

- **MIT License** : très courte, permissive, quasiment aucune contrainte hormis la mention de copyright.
- **BSD License** (2-clause ou 3-clause) : proche de MIT, historiquement liée aux systèmes BSD.
- **Apache License 2.0** : permissive, mais ajoute une clause explicite de concession de brevets (patent grant), utile pour les projets d'entreprise.

## 5. Exemple pratique : consulter la licence d'un paquet

Sur un système Debian/Ubuntu, chaque paquet installé documente sa licence dans `/usr/share/doc/<paquet>/copyright` :

```console
$ cat /usr/share/doc/bash/copyright | head -n 15
This package was debianized by Matthias Klose <doko@debian.org>

Files: *
Copyright: 1989-2023 Free Software Foundation, Inc.
License: GPL-3+

...
```

Le texte intégral des licences courantes est disponible localement :

```console
$ ls /usr/share/common-licenses/
Apache-2.0  BSD  GPL-2  GPL-3  LGPL-2.1  LGPL-3  MIT ...
```

Sur un système basé RPM (Fedora, RHEL), l'information de licence est intégrée aux métadonnées du paquet :

```console
$ rpm -qi bash | grep -i license
License     : GPLv3+
```

## 6. Logiciel libre vs logiciel propriétaire, freeware, shareware et domaine public

Il est essentiel de ne pas confondre ces catégories :

| Catégorie | Code source disponible | Modifiable/redistribuable | Gratuit |
|---|---|---|---|
| **Open Source / Free Software** | Oui | Oui | Pas nécessairement (le prix et la liberté sont deux choses différentes) |
| **Proprietary software** | Non (closed source) | Non, sauf accord contractuel | Non en général |
| **Freeware** | Non | Non | Oui (gratuit à l'usage) |
| **Shareware** | Non | Non | Essai gratuit, puis payant |
| **Public Domain** | Oui (souvent) | Oui, sans aucune restriction, même pas d'attribution | Oui |

Un point piège classique de l'examen : **« gratuit » (free as in beer) ≠ « libre » (free as in speech)**. Un logiciel peut être gratuit sans être open source (freeware), et un logiciel open source peut être vendu commercialement.

## 7. Modèles économiques autour de l'Open Source

Le fait que le code soit libre n'empêche pas un modèle d'affaires viable :

- **Dual licensing** : le même code est distribué sous une licence copyleft (ex. GPL) pour la communauté, et sous une licence commerciale pour les entreprises qui ne veulent pas se soumettre au copyleft (ex. MySQL historiquement chez MySQL AB).
- **Support et services** : le logiciel est gratuit, l'entreprise vend du support, du consulting, de la formation (modèle Red Hat).
- **Open core / freemium** : un cœur open source, des fonctionnalités avancées propriétaires (« enterprise edition »).
- **SaaS** : hébergement du logiciel comme service, souvent motivant l'usage de l'AGPL par les auteurs pour empêcher la concurrence de revendre le service sans contribuer.
- **Dons et sponsoring** : modèle communautaire (ex. Wikimedia Foundation, fondations comme la FSF ou l'Apache Software Foundation).

## 8. Open Standards

Une notion connexe testée dans ce topic : les **Open Standards** (formats et protocoles ouverts, ex. HTML, ODF, PDF/A) garantissent l'interopérabilité indépendamment de l'éditeur, évitant le **vendor lock-in**. Un standard ouvert n'implique pas forcément que les implémentations soient open source, mais les deux notions se renforcent mutuellement dans l'écosystème Linux.

## 9. Creative Commons : au-delà du logiciel

Bien que pensées pour les œuvres non logicielles (documentation, images, musique), les licences **Creative Commons (CC)** appliquent des principes similaires :

- **CC BY** : attribution simple.
- **CC BY-SA** : attribution + partage à l'identique (équivalent du copyleft).
- **CC BY-NC** : interdiction d'usage commercial.
- **CC0** : équivalent du domaine public, aucune restriction.

## Références

- LPI Learning Materials — *Open Source Software and Licensing* (010-160, section 1.3) : https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- Free Software Foundation — *The Free Software Definition* : https://www.gnu.org/philosophy/free-sw.html
- Open Source Initiative — *The Open Source Definition* : https://opensource.org/osd
- GNU Project — *Licences GNU* (GPL, LGPL, AGPL) : https://www.gnu.org/licenses/licenses.html
- Open Source Initiative — *Licenses & Standards* : https://opensource.org/licenses
- Creative Commons — *About the Licenses* : https://creativecommons.org/licenses/