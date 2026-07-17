# 3.1 Archiving Files on the Command Line

## Introduction

Sur les systèmes Linux, l'**archivage** consiste à regrouper plusieurs fichiers et répertoires en un seul fichier (une *archive*), tout en préservant leur structure, leurs permissions et leurs métadonnées. C'est une compétence fondamentale pour les sauvegardes, la distribution de logiciels (tarballs) et le transfert de données. L'archivage est une opération distincte de la **compression**, même si les deux sont souvent combinées en une seule commande.

Les outils principaux à connaître pour ce topic sont `tar`, `cpio`, ainsi que les utilitaires de compression `gzip`, `bzip2`, `xz` et `zip`/`unzip`.

## `tar` (Tape Archive)

`tar` est l'outil d'archivage standard sur Linux. Il crée un seul fichier `.tar` à partir de plusieurs fichiers/répertoires, sans les compresser par défaut.

### Syntaxe de base

```bash
tar [options] fichier.tar fichiers_ou_répertoires...
```

### Options essentielles

| Option | Signification |
|---|---|
| `-c` | *create* — créer une nouvelle archive |
| `-x` | *extract* — extraire une archive |
| `-t` | *list* — lister le contenu sans extraire |
| `-f fichier` | *file* — indique le nom du fichier archive (presque toujours nécessaire) |
| `-v` | *verbose* — affiche les fichiers traités |
| `-z` | compression/décompression **gzip** |
| `-j` | compression/décompression **bzip2** |
| `-J` | compression/décompression **xz** |
| `-C répertoire` | change de répertoire avant l'opération |
| `--exclude=motif` | exclut les fichiers correspondant au motif |
| `-r` | *append* — ajoute des fichiers à une archive existante |
| `-p` | préserve les permissions (important en root) |

### Exemples

**Créer une archive non compressée :**

```bash
$ tar -cvf backup.tar documents/
documents/
documents/rapport.odt
documents/notes.txt
```

**Créer une archive compressée avec gzip :**

```bash
$ tar -czvf backup.tar.gz documents/
```

**Créer une archive compressée avec bzip2 (meilleure compression, plus lent) :**

```bash
$ tar -cjvf backup.tar.bz2 documents/
```

**Créer une archive compressée avec xz (meilleure compression, encore plus lent) :**

```bash
$ tar -cJvf backup.tar.xz documents/
```

**Lister le contenu sans extraire :**

```bash
$ tar -tvf backup.tar.gz
drwxr-xr-x user/user   0 2026-07-10 10:00 documents/
-rw-r--r-- user/user 512 2026-07-10 10:00 documents/rapport.odt
-rw-r--r-- user/user  64 2026-07-10 10:00 documents/notes.txt
```

**Extraire une archive dans le répertoire courant :**

```bash
$ tar -xzvf backup.tar.gz
```

**Extraire dans un répertoire spécifique :**

```bash
$ tar -xzvf backup.tar.gz -C /tmp/restore/
```

**Extraire un seul fichier d'une archive :**

```bash
$ tar -xzvf backup.tar.gz documents/notes.txt
```

> `tar` peut généralement **détecter automatiquement** le type de compression à l'extraction (`-x`), même sans préciser `-z`, `-j` ou `-J`. En revanche, à la **création**, il faut spécifier explicitement l'option de compression voulue.

### Conventions de nommage

| Extension | Compression |
|---|---|
| `.tar` | aucune |
| `.tar.gz` / `.tgz` | gzip |
| `.tar.bz2` / `.tbz2` | bzip2 |
| `.tar.xz` / `.txz` | xz |

## `cpio` (Copy In/Out)

`cpio` est un outil d'archivage plus ancien, souvent utilisé dans des contextes spécifiques (initramfs, paquets RPM). Contrairement à `tar`, il lit la liste des fichiers à archiver depuis l'entrée standard (souvent générée avec `find`).

### Modes de fonctionnement

- `-o` (*copy-out*) : crée une archive
- `-i` (*copy-in*) : extrait une archive
- `-p` (*pass-through*) : copie des fichiers directement vers un autre répertoire, sans passer par une archive intermédiaire

### Exemples

**Créer une archive avec `cpio` :**

```bash
$ find documents/ -print | cpio -ov > backup.cpio
```

**Extraire une archive `cpio` :**

```bash
$ cpio -idv < backup.cpio
```

**Copier une arborescence directement (pass-through) :**

```bash
$ find documents/ -print | cpio -pdv /tmp/copie/
```

## Compression avec `gzip`, `bzip2` et `xz`

Ces outils compressent **un seul fichier à la fois** — c'est pourquoi ils sont typiquement combinés avec `tar` pour compresser des répertoires entiers. Utilisés seuls, ils remplacent le fichier original par sa version compressée.

### `gzip` / `gunzip`

```bash
$ gzip fichier.txt        # crée fichier.txt.gz, supprime fichier.txt
$ gunzip fichier.txt.gz   # restaure fichier.txt
$ gzip -k fichier.txt     # -k : garde (keep) le fichier original
$ gzip -9 fichier.txt     # -9 : compression maximale (-1 = rapide, peu compressé)
```

### `bzip2` / `bunzip2`

Fonctionne de manière similaire à `gzip`, mais offre généralement un meilleur taux de compression au prix d'une vitesse plus lente.

```bash
$ bzip2 fichier.txt
$ bunzip2 fichier.txt.bz2
```

### `xz` / `unxz`

Offre le meilleur taux de compression des trois, mais est le plus lent et le plus gourmand en mémoire.

```bash
$ xz fichier.txt
$ unxz fichier.txt.xz
```

### Comparaison rapide

| Outil | Extension | Vitesse | Taux de compression |
|---|---|---|---|
| `gzip` | `.gz` | rapide | modéré |
| `bzip2` | `.bz2` | moyen | bon |
| `xz` | `.xz` | lent | excellent |

## `zip` / `unzip`

Format d'archivage **et** de compression combinés (contrairement à `tar`), très utilisé pour l'interopérabilité avec Windows/macOS.

```bash
$ zip -r archive.zip documents/       # -r : récursif, nécessaire pour les répertoires
$ unzip archive.zip
$ unzip -l archive.zip                # -l : liste le contenu sans extraire
$ unzip archive.zip -d /tmp/restore/  # extraction dans un répertoire spécifique
```

## Points clés à retenir pour l'examen

- `tar` n'est **pas** compressé par défaut ; il faut ajouter `-z`, `-j` ou `-J`.
- Ordre typique des options : `-cvf`, `-xvf`, `-tvf` (l'ordre des lettres importe peu, mais `f` doit être suivi immédiatement du nom de fichier).
- `gzip`, `bzip2` et `xz` compressent un fichier unique et **suppriment l'original** sauf avec `-k`.
- `zip` est à la fois un outil d'archivage et de compression, contrairement à `tar` seul.
- `cpio` lit la liste des fichiers depuis `stdin`, généralement via `find`.

## Références

- LPI Learning Materials — Archiving Files on the Command Line : https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- GNU tar Manual : https://www.gnu.org/software/tar/manual/
- gzip Home Page : https://www.gnu.org/software/gzip/
- bzip2 Documentation : https://sourceware.org/bzip2/
- XZ Utils : https://tukaani.org/xz/
- Info ZIP : http://infozip.sourceforge.net/