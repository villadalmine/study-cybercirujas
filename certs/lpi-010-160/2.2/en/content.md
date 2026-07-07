# 2.2 Using the Command Line to Get Help

**Exam weight:** 2

Linux systems ship with extensive built-in documentation. Knowing how to find help locally — without a browser — is a core skill: it works on servers with no GUI, offline machines, and rescue environments. This topic covers the main help systems (`--help`, `man`, `info`), the search tools around them (`apropos`, `whatis`), the documentation directory `/usr/share/doc`, and the commands used to locate programs and files (`which`, `type`, `whereis`, `locate`, `find`).

---

## 1. Quick Help: the `--help` Option

Most commands accept `--help` (and sometimes `-h`) to print a short usage summary directly to the terminal. It is the fastest way to recall a command's syntax and most common options.

```bash
$ mkdir --help
Usage: mkdir [OPTION]... DIRECTORY...
Create the DIRECTORY(ies), if they do not already exist.

Mandatory arguments to long options are mandatory for short options too.
  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask
  -p, --parents     no error if existing, make parent directories as needed
  -v, --verbose     print a message for each created directory
      --help        display this help and exit
      --version     display version information and exit
```

The output follows a common convention:

- **Usage line** — the general syntax. Items in square brackets `[...]` are optional; `...` means the item can be repeated; UPPERCASE words are placeholders you replace with real values.
- **Option list** — short options (`-p`) and their long equivalents (`--parents`).

`--help` is a summary, not full documentation. For details, use `man`.

## 2. Manual Pages: `man`

The **man pages** (manual pages) are the traditional Unix/Linux reference documentation, installed locally with the software itself. To read the manual for a command:

```bash
$ man mkdir
```

### Structure of a man page

Man pages follow a standard layout. The most common sections inside a page are:

| Heading | Content |
|---|---|
| `NAME` | Command name and one-line description |
| `SYNOPSIS` | Syntax of the command |
| `DESCRIPTION` | Detailed explanation of what it does |
| `OPTIONS` | Every option and its meaning |
| `FILES` | Related configuration files |
| `EXAMPLES` | Usage examples (not always present) |
| `SEE ALSO` | Related man pages |

### Manual sections

The whole manual is divided into numbered **sections** by content type:

| Section | Contains |
|---|---|
| 1 | User commands |
| 2 | System calls |
| 3 | Library functions |
| 4 | Device files and drivers |
| 5 | File formats and configuration files |
| 6 | Games |
| 7 | Miscellaneous (conventions, standards) |
| 8 | System administration commands |

The same name can exist in several sections. For example, `passwd` is both a command (section 1) and a configuration file (section 5). You choose the section by putting its number before the name:

```bash
$ man 1 passwd    # the passwd command
$ man 5 passwd    # the /etc/passwd file format
```

The section number appears in the page header, e.g. `PASSWD(1)`. When no section is given, `man` shows the first match (usually section 1).

### Navigating a man page

Man pages open in a **pager** (normally `less`). Key bindings worth memorizing:

| Key | Action |
|---|---|
| `Space` / `PgDn` | Next page |
| `b` / `PgUp` | Previous page |
| `↑` / `↓` | Scroll one line |
| `/pattern` | Search forward for *pattern* |
| `?pattern` | Search backward |
| `n` / `N` | Next / previous search match |
| `g` / `G` | Jump to beginning / end |
| `h` | Help on the pager itself |
| `q` | Quit |

## 3. Searching the Manuals: `apropos` and `whatis`

When you don't know the command's name, search the man page names and short descriptions:

```bash
$ apropos "copy files"
cp (1)               - copy files and directories
cpio (1)             - copy files to and from archives
install (1)          - copy files and set attributes
```

`man -k` is equivalent to `apropos`:

```bash
$ man -k "copy files"
```

If you know the name and only want the one-line description, use `whatis` (equivalent to `man -f`):

```bash
$ whatis ls
ls (1)               - list directory contents
```

These tools query a pre-built index database. On a fresh system, if `apropos` returns "nothing appropriate", the database may need to be generated with `mandb` (run as root).

## 4. Info Pages: `info`

The GNU project documents many of its tools with **info pages**, which are often longer and more tutorial-like than man pages. Unlike man pages, info documents are structured as a tree of **nodes** connected by hyperlinks.

```bash
$ info coreutils
```

Basic navigation inside `info`:

| Key | Action |
|---|---|
| `Space` | Scroll forward |
| `n` / `p` | Next / previous node at the same level |
| `u` | Up one level |
| `Enter` | Follow the hyperlink under the cursor |
| `Tab` | Jump to the next hyperlink |
| `l` | Go back (last visited node) |
| `q` | Quit |

Running `info` with no arguments shows the top-level directory of all available info documents.

## 5. The `/usr/share/doc` Directory

Beyond man and info, most packages install extra documentation under `/usr/share/doc/`, in a subdirectory named after the package:

```bash
$ ls /usr/share/doc/bash
CHANGES.gz  COPYING  README  changelog.Debian.gz  ...
```

Typical contents include `README` files, changelogs, license texts, and example configuration files — often details that don't fit in a man page. Files ending in `.gz` are compressed and can be read with `zless` or `zcat`.

## 6. Locating Programs and Files

Part of "getting help" is discovering *where* things are on the system.

### `which` — where is the executable?

Shows the full path of the program the shell would execute, by searching the directories in the `PATH` variable:

```bash
$ which mkdir
/usr/bin/mkdir
```

### `type` — what kind of command is it?

A shell builtin that tells you whether a name is an external program, a shell builtin, an alias, or a function:

```bash
$ type cd
cd is a shell builtin
$ type ll
ll is aliased to 'ls -alF'
$ type mkdir
mkdir is /usr/bin/mkdir
```

### `whereis` — binary, source, and man page

Locates the executable and also its man pages and source, if installed:

```bash
$ whereis mkdir
mkdir: /usr/bin/mkdir /usr/share/man/man1/mkdir.1.gz
```

### `locate` — fast filename search

Searches a database of filenames, so it is very fast:

```bash
$ locate fstab
/etc/fstab
/usr/share/man/man5/fstab.5.gz
```

Because it reads a database (not the live filesystem), results can be stale: files created after the last index run won't appear. The database is refreshed periodically by the system, or manually with `updatedb` (as root). Useful options: `-i` (case-insensitive) and `-c` (count matches only).

### `find` — real-time search

Searches the filesystem directly, so results are always current but slower. General form: `find STARTING_DIR CRITERIA`:

```bash
$ find /etc -name "*.conf"        # files ending in .conf under /etc
$ find ~ -type d -name "Doc*"     # directories in HOME starting with Doc
$ find . -mtime -1                # files modified in the last 24 hours
```

Unlike `locate`, `find` can filter by type, size, owner, permissions, and modification time — not just name.

---

## Key Points to Remember

- `--help` gives a quick syntax summary; `man` gives the full reference; `info` gives GNU's hyperlinked, in-depth docs.
- Man pages are organized in numbered sections: **1** = user commands, **5** = file formats, **8** = admin commands. `man 5 passwd` ≠ `man 1 passwd`.
- `apropos` / `man -k` search descriptions when you don't know the command name; `whatis` / `man -f` show the one-line description of a known name.
- Extra package documentation lives in `/usr/share/doc/<package>`.
- `which` and `type` tell you what will run; `whereis` adds man pages; `locate` is fast but database-based (`updatedb` refreshes it); `find` searches live with rich criteria.

## Referencias

- LPI Learning Materials — Topic 2.2, Using the Command Line to Get Help: https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- LPI Linux Essentials Objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- Linux man-pages project: https://www.kernel.org/doc/man-pages/
- `man` manual page (man-pages): https://man7.org/linux/man-pages/man1/man.1.html
- GNU Texinfo (info system) documentation: https://www.gnu.org/software/texinfo/manual/info-stnd/
- GNU findutils (`find`) documentation: https://www.gnu.org/software/findutils/manual/html_mono/find.html