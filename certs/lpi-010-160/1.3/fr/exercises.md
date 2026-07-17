# 1.3 Open Source Software and Licensing

Ces exercices pratiques vous font manipuler concrètement les notions de philosophie **Open Source**, de **license** et de modèles économiques du logiciel libre, en utilisant les outils déjà présents sur un système Linux (Debian/Ubuntu) ainsi que les textes de référence officiels.

**Sources de référence :**
- https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- https://www.gnu.org/philosophy/free-sw.html
- https://opensource.org/osd
- https://www.gnu.org/licenses/license-list.html
- https://creativecommons.org/share-your-work/cclicenses/

---

## Exercice 1 — Explorer les licences fournies avec le système

1. Ouvrez un terminal sur une distribution Debian/Ubuntu.
2. Listez les textes de licence livrés avec le système :
   ```
   ls /usr/share/common-licenses/
   ```
3. Affichez le texte complet de la GPL version 3 :
   ```
   less /usr/share/common-licenses/GPL-3
   ```
4. Repérez dans le texte les sections « Preamble », « TERMS AND CONDITIONS » et, tout à la fin, « How to Apply These Terms to Your New Programs ».
5. Quittez `less` avec la touche `q`, puis affichez la LGPL version 3 :
   ```
   less /usr/share/common-licenses/LGPL-3
   ```
6. Comparez brièvement la taille et la structure des deux fichiers (`wc -l /usr/share/common-licenses/GPL-3 /usr/share/common-licenses/LGPL-3`).

**Questions de compréhension**
1. Pourquoi une distribution installe-t-elle ces textes de licence séparément, indépendamment des paquets logiciels eux-mêmes ?
2. Que remarquez-vous en ouvrant la LGPL-3 : contient-elle le texte complet de la GPL, ou fait-elle référence à un autre document ?

---

## Exercice 2 — Lire les métadonnées de copyright d'un paquet

1. Choisissez un paquet livré par défaut sur la plupart des systèmes Debian/Ubuntu, par exemple `bash`, et affichez son fichier de copyright :
   ```
   cat /usr/share/doc/bash/copyright
   ```
2. Repérez le champ `License:` et la mention du copyright holder (Free Software Foundation).
3. Faites de même avec un paquet distribué sous une **permissive license**, par exemple `zlib1g` :
   ```
   cat /usr/share/doc/zlib1g/copyright
   ```
4. Notez les obligations imposées par chacune des deux licences : la GPL impose-t-elle de republier le source code des travaux dérivés ? Le fait-elle pour la licence zlib ?
5. Utilisez `apt-cache show bash zlib1g | grep -i licen` pour voir si l'information de licence apparaît aussi dans les métadonnées du gestionnaire de paquets.

**Questions de compréhension**
1. Quelle est la différence fondamentale entre une licence **copyleft** (comme la GPL) et une **permissive license** (comme zlib/BSD/MIT) en matière d'obligations sur le code dérivé ?
2. Un développeur pourrait-il intégrer le code de `zlib1g` dans un logiciel propriétaire sans en publier le source code ? Et le code de `bash` ?

---

## Exercice 3 — Appliquer les Four Freedoms et l'Open Source Definition

1. Consultez la définition des **Four Freedoms** de la Free Software Foundation (https://www.gnu.org/philosophy/free-sw.html) et notez les numéros 0 à 3 (exécuter, étudier, redistribuer, améliorer et redistribuer les versions modifiées).
2. Consultez l'**Open Source Definition** de l'Open Source Initiative (https://opensource.org/osd) et notez au moins les trois premiers critères : redistribution libre, accès au source code, autorisation des travaux dérivés.
3. Sur votre système, choisissez trois paquets différents avec `apt-cache show <paquet> | grep -i license` : un sous GPL, un sous une licence permissive (BSD/MIT/zlib), et si possible un outil dont vous savez qu'il est **freeware** (gratuit mais sans source code disponible, par exemple un binaire propriétaire téléchargé hors des dépôts).
4. Pour chacun des trois, déterminez s'il respecte les Four Freedoms de la FSF, l'Open Source Definition de l'OSI, les deux, ou aucune.

**Questions de compréhension**
1. Un logiciel **freeware** (gratuit, closed source) peut-il être qualifié de Free Software au sens de la FSF ? Justifiez.
2. Un logiciel peut-il satisfaire l'Open Source Definition sans satisfaire les Four Freedoms, ou inversement ? Donnez un exemple de recouvrement entre les deux définitions.

---

## Exercice 4 — Comparer la famille GPL et la « force » du copyleft

1. Affichez de nouveau `/usr/share/common-licenses/GPL-3` et cherchez la section relative à la « anti-tivoization clause » (mention des « User Products » et de l'obligation de fournir les « Installation Information »).
2. Affichez `/usr/share/common-licenses/LGPL-3` et repérez la section « Combined Works », qui autorise le linkage dynamique d'une bibliothèque LGPL dans un logiciel propriétaire.
3. Recherchez en ligne le texte de l'AGPL (Affero GPL) sur https://www.gnu.org/licenses/license-list.html et lisez le paragraphe expliquant pourquoi cette licence a été créée (clause de « network use »).
4. Classez les trois licences (GPL, LGPL, AGPL) de la plus « forte » (la plus restrictive sur la redistribution) à la plus « faible » (la plus permissive), en tenant compte du linkage et de l'usage réseau.

**Questions de compréhension**
1. Pourquoi une bibliothèque logicielle est-elle souvent publiée sous LGPL plutôt que sous GPL classique ?
2. Quel problème spécifique (le « SaaS loophole », c'est-à-dire l'usage d'un logiciel modifié uniquement via un service réseau sans jamais le redistribuer) l'AGPL cherche-t-elle à résoudre, et comment ?

---

## Exercice 5 — Creative Commons et modèles économiques du FOSS

1. Consultez la page des licences Creative Commons (https://creativecommons.org/share-your-work/cclicenses/) et notez la signification des quatre éléments combinables : `BY`, `SA`, `NC`, `ND`.
2. Identifiez la licence CC utilisée par un contenu que vous consultez régulièrement (documentation, wiki, image) en cherchant la mention « Creative Commons » ou le badge de licence en bas de page.
3. Recherchez comment une entreprise comme Red Hat génère des revenus autour de logiciels publiés sous licence libre (abonnement de support, au lieu de vente de licence).
4. Recherchez un exemple de **dual licensing** (un même logiciel disponible à la fois sous une licence copyleft gratuite et sous une licence commerciale payante), par exemple le modèle historique de MySQL.

**Questions de compréhension**
1. Une licence Creative Commons `CC BY-NC-ND` autorise-t-elle un usage commercial ou la création de travaux dérivés ? Justifiez à partir des sigles.
2. Quelle est la différence entre le modèle économique « support subscription » (comme Red Hat) et le modèle « dual licensing » (comme MySQL) en matière de contrôle sur le code source ?

---

<details>
<summary>Réponses</summary>

**Exercice 1**
1. Les textes de licence sont partagés par de nombreux paquets (des centaines de paquets sont sous GPL-3, par exemple) : plutôt que de dupliquer le même texte dans chaque paquet, la distribution le fournit une seule fois de manière centralisée, et chaque paquet y fait référence dans son fichier `copyright`.
2. La LGPL-3 ne contient pas tout le texte de la GPL : elle est rédigée comme un ensemble de clauses additionnelles qui modifient et font explicitement référence à la GPL version 3, dont elle assouplit certaines obligations (notamment sur le linkage).

**Exercice 2**
1. Une licence copyleft comme la GPL impose que tout travail dérivé distribué soit lui aussi publié sous une licence compatible (généralement la même), avec son source code. Une permissive license comme zlib/BSD/MIT n'impose quasiment aucune obligation de ce type : elle autorise la réutilisation dans un logiciel propriétaire fermé, à condition de conserver la mention de copyright et l'avis de licence.
2. Oui, le code de `zlib1g` peut être intégré dans un logiciel propriétaire sans publier le source code de ce dernier. Le code de `bash`, étant sous GPL-3, ne peut pas être intégré tel quel dans un logiciel propriétaire fermé sans que celui-ci devienne lui-même soumis aux termes de la GPL.

**Exercice 3**
1. Non. La FSF distingue clairement « gratuit » (price) de « libre » (freedom) : un freeware sans source code disponible ne respecte aucune des Four Freedoms (on ne peut ni l'étudier, ni le modifier, ni redistribuer ses versions modifiées), donc il n'est pas Free Software même s'il est distribué sans frais.
2. En pratique, la quasi-totalité des licences reconnues par l'OSI comme « Open Source » sont aussi reconnues par la FSF comme « Free Software » (GPL, BSD, MIT, Apache 2.0, etc.), car les deux définitions, bien que rédigées différemment et portées par des organisations distinctes, convergent sur les mêmes critères essentiels : accès au source code, droit de modifier, droit de redistribuer. Les divergences historiques concernent surtout des cas marginaux ou des clauses jugées trop restrictives par l'une ou l'autre organisation.

**Exercice 4**
1. Une bibliothèque est souvent publiée sous LGPL pour permettre son utilisation (via linkage dynamique) par des logiciels propriétaires sans forcer ces derniers à devenir eux-mêmes libres ; cela favorise une plus large adoption de la bibliothèque, y compris dans l'écosystème commercial.
2. L'AGPL ajoute une clause imposant que, si le logiciel modifié est utilisé pour fournir un service accessible via un réseau (SaaS), le source code modifié doit être mis à disposition des utilisateurs de ce service — même s'il n'y a jamais eu de distribution binaire classique. Cela ferme la faille qui permettait de modifier un logiciel GPL et de l'exploiter uniquement via le réseau sans jamais redistribuer les modifications.

**Exercice 5**
1. Non. `NC` (NonCommercial) interdit l'usage commercial, et `ND` (NoDerivatives) interdit la création et la redistribution de travaux dérivés modifiés. Une licence `CC BY-NC-ND` n'autorise donc que le partage non modifié, avec attribution, à des fins non commerciales.
2. Dans le modèle « support subscription » (Red Hat), le code source reste ouvert et librement redistribuable ; le revenu provient de services (support, certification, intégration), et le contrôle sur le code est partagé avec la communauté. Dans le modèle « dual licensing » (MySQL), l'éditeur reste titulaire des droits et propose le même code sous deux licences distinctes : une licence copyleft gratuite pour un usage libre, et une licence commerciale payante pour les entreprises qui ne souhaitent pas se conformer aux obligations du copyleft — l'éditeur garde ainsi un contrôle centralisé sur le code source.

</details>