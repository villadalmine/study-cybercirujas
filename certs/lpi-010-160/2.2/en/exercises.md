# Guided Exercises — Topic 2.2: Using the Command Line to Get Help

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 2

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions.

---

## Exercise 1: Quick help with `--help`

Most commands ship a built-in usage summary that prints instantly, without opening any documentation system.

1. Display the built-in help for the `ls` command:
   ```bash
   ls --help
   ```
2. The output is long. Send it through a pager so you can scroll:
   ```bash
   ls --help | less
   ```
   Scroll with the **arrow keys** or **Space**, and press **q** to quit.
3. Try the short form that some commands accept:
   ```bash
   ls -h
   ```
   Notice that `-h` did **not** print help — for `ls` it means *human-readable sizes*.

**Questions**

- **1a.** When is `--help` a better first choice than `man`?
- **1b.** Why can't you assume `-h` always means "help"?

---

## Exercise 2: Reading a man page

The `man` (manual) pages are the classic reference documentation on Linux, organized into standard sections.

1. Open the manual page for `ls`:
   ```bash
   man ls
   ```
2. Identify the standard headings as you scroll: **NAME**, **SYNOPSIS**, **DESCRIPTION**, and near the bottom, **SEE ALSO**.
3. Look at the **SYNOPSIS** line:
   ```
   ls [OPTION]... [FILE]...
   ```
   Note the square brackets and the `...`.
4. Practice the pager keys inside the man page:
   - **Space** / **b** — page forward / backward
   - **g** / **G** — jump to top / bottom
   - **/word** then **Enter** — search forward for `word`; press **n** for the next match
   - **q** — quit
5. Search inside the page for the option that sorts by file size:
   ```
   /sort by
   ```
   Press **n** until you find the `-S` option.

**Questions**

- **2a.** In a SYNOPSIS, what do square brackets `[ ]` around an argument mean? What does `...` mean?
- **2b.** Which heading would you check to find related commands worth reading next?
- **2c.** Which key searches forward inside a man page, and which key repeats the search?

---

## Exercise 3: Manual sections 1–8

The manual is split into numbered sections; the same name can exist in more than one.

1. Ask where the `passwd` documentation lives:
   ```bash
   whatis passwd
   ```
   You should see at least two entries, e.g. `passwd (1)` — the command — and `passwd (5)` — the file format of `/etc/passwd`.
2. Open each one explicitly:
   ```bash
   man 1 passwd
   ```
   Quit with **q**, then:
   ```bash
   man 5 passwd
   ```
3. Confirm the default: run `man passwd` with no number and check the header line at the top of the page (e.g. `PASSWD(1)`).

**Questions**

- **3a.** What kind of content is in manual section 1? In section 5? In section 8?
- **3b.** If `man passwd` shows section 1 but you wanted the description of the `/etc/passwd` file, what exact command do you run?
- **3c.** In documentation you often see references like `crontab(5)`. What does the number in parentheses tell you?

---

## Exercise 4: Finding the right command with `apropos` and `whatis`

When you don't know the command's name, you search the manual database by keyword.

1. Search the man page descriptions for anything related to renaming:
   ```bash
   apropos rename
   ```
2. Run the equivalent long form:
   ```bash
   man -k rename
   ```
   Compare — the output is identical.
3. Now get just the one-line summary of a command you already know:
   ```bash
   whatis mv
   ```
   The equivalent is `man -f mv`.
4. If `apropos` returns `nothing appropriate`, the index database may be missing. It is rebuilt (as root) with:
   ```bash
   sudo mandb
   ```
   *(Only run this if step 1 returned nothing.)*

**Questions**

- **4a.** You need to compress a file but can't remember any tool names. Which command do you run first?
- **4b.** What is the difference between `apropos` and `whatis`?
- **4c.** Which `man` options are equivalent to `apropos` and to `whatis`?

---

## Exercise 5: The `info` system

GNU programs often have richer, book-like documentation in `info`, structured as linked nodes.

1. Open the info documentation for the GNU core utilities:
   ```bash
   info coreutils
   ```
2. Navigate:
   - **Arrow keys** move the cursor; menu entries start with `*`
   - **Enter** on a menu entry follows the link into that node
   - **u** goes up one level, **l** goes back (like a browser's Back button)
   - **n** / **p** — next / previous node at the same level
   - **q** — quit
3. Jump straight to a specific node from the shell:
   ```bash
   info ls
   ```
4. Compare `info ls` with `man ls`: notice `info` offers longer explanations and hyperlinked structure, while `man` is a single flat reference page.

**Questions**

- **5a.** Name two structural differences between info pages and man pages.
- **5b.** Inside `info`, which key follows a menu link, and which key goes back up a level?

---

## Exercise 6: Local documentation in `/usr/share/doc`

Packages install extra documentation — changelogs, examples, READMEs — under a standard directory.

1. List what documentation directories exist:
   ```bash
   ls /usr/share/doc | less
   ```
2. Pick a package you have installed (e.g. `bash`) and inspect its docs:
   ```bash
   ls /usr/share/doc/bash
   ```
3. Read one of the plain-text files you find there, for example:
   ```bash
   less /usr/share/doc/bash/README
   ```
   *(File names vary by distribution; use whatever `ls` showed. Files ending in `.gz` can be read with `zless`.)*

**Questions**

- **6a.** What kinds of documents would you expect in `/usr/share/doc/<package>/` that you will *not* find in a man page?
- **6b.** How are the directories under `/usr/share/doc` organized?

---

## Exercise 7: Locating files and programs

Finding *where* something lives is also a form of getting help.

1. Find which executable runs when you type a command:
   ```bash
   which ls
   ```
2. Get the binary, source, and man page locations in one shot:
   ```bash
   whereis ls
   ```
3. Search the whole filesystem index for files by name:
   ```bash
   locate fstab
   ```
4. `locate` reads a prebuilt database, not the live filesystem. Create a new file and prove it isn't found yet:
   ```bash
   touch ~/newfile-test.txt
   locate newfile-test.txt
   ```
   No output. Refresh the database and retry:
   ```bash
   sudo updatedb
   locate newfile-test.txt
   ```
5. Clean up:
   ```bash
   rm ~/newfile-test.txt
   ```

**Questions**

- **7a.** Why did `locate` fail to find the file you had just created?
- **7b.** Which command updates the database that `locate` uses?
- **7c.** What extra information does `whereis` give you compared to `which`?

---

<details>
<summary><strong>Answers</strong></summary>

**1a.** When you just need a quick reminder of a command's options or syntax: `--help` prints immediately in the terminal, requires no pager, and works even on minimal systems where man pages aren't installed.

**1b.** Short options are defined by each program individually. For `ls`, `-h` means *human-readable sizes*; for other tools it may mean help, or something else entirely. Only the long option `--help` is a widely followed convention (and even that isn't universal).

**2a.** Square brackets mean the argument is **optional** — the command works without it. The ellipsis `...` means the preceding element **may be repeated** (e.g. you can pass many FILE arguments).

**2b.** **SEE ALSO**, which lists related man pages and their section numbers.

**2c.** `/` followed by the search term searches forward; `n` jumps to the next match (`N` goes to the previous one). Quit with `q`.

**3a.** Section **1**: user commands (executable programs). Section **5**: file formats and configuration files. Section **8**: system administration commands, usually for root. (Others: 2 system calls, 3 library functions, 4 special files/devices, 6 games, 7 miscellanea/conventions.)

**3b.** `man 5 passwd` — the section number goes between `man` and the page name.

**3c.** The manual section the page lives in. `crontab(5)` is the file-format documentation, as opposed to `crontab(1)`, the user command.

**4a.** `apropos compress` (or `man -k compress`) — it searches the names and short descriptions of all man pages for a keyword.

**4b.** `apropos` does a keyword **search** across all man page descriptions and returns every match; `whatis` looks up **one exact command name** and prints only its one-line description.

**4c.** `man -k` ≡ `apropos`; `man -f` ≡ `whatis`.

**5a.** (1) Info documentation is **hyperlinked and hierarchical** — organized into nodes with menus you navigate like a book — while a man page is a single flat page. (2) Info pages tend to be longer, tutorial-style GNU documentation, while man pages are terse reference material. (Also acceptable: different navigation keys, different reader program.)

**5b.** **Enter** on a menu entry (`*` line) follows the link; **u** goes up a level (**l** returns to the previously visited node).

**6a.** Package-specific extras that don't fit the man page format: README files, changelogs, license texts, example configuration files, and sometimes full manuals or HTML documentation.

**6b.** One subdirectory per installed package, named after the package: `/usr/share/doc/<package-name>/`.

**7a.** Because `locate` searches a **prebuilt database** of file names, not the filesystem itself. The file was created after the last database build, so it wasn't indexed yet.

**7b.** `updatedb` (run as root; many systems also run it automatically on a schedule).

**7c.** `which` only prints the path of the executable that the shell would run. `whereis` additionally reports the locations of the command's **source code** and **man pages**, when present.

</details>

---

**Reference:** LPI Learning Materials, Lesson 2.2 — *Using the Command Line to Get Help*: <https://learning.lpi.org/en/learning-materials/010-160/2/2.2/>