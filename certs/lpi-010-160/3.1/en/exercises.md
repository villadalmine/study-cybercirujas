# Guided Exercises — Topic 3.1: Archiving Files on the Command Line

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 2

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions.

---

## Exercise 1: Setting up a playground

Archiving means bundling many files into a single file; compression means making data smaller. On Linux these are traditionally two separate steps, handled by two separate kinds of tools. Before exploring either, build some files worth archiving.

1. Create a working directory in your home directory and move into it:
   ```bash
   mkdir ~/archive-lab
   cd ~/archive-lab
   ```
2. Create a small project tree with a few text files:
   ```bash
   mkdir -p project/docs project/scripts
   echo "Project notes, version 1" > project/README
   echo "Meeting minutes go here" > project/docs/minutes.txt
   echo "echo hello" > project/scripts/hello.sh
   ```
3. Create one larger, highly compressible file — 1 MB of zero bytes:
   ```bash
   dd if=/dev/zero of=project/bigfile.dat bs=1024 count=1024
   ```
4. Confirm what you built and note the sizes:
   ```bash
   ls -lR project
   du -sh project
   ```

**Questions**

- **1a.** In your own words, what is the difference between *archiving* and *compressing*?
- **1b.** Why is a file full of zero bytes a good candidate for compression?

---

## Exercise 2: Creating a tar archive

`tar` (originally *tape archiver*) is the standard Unix tool for bundling files and directories into one file, commonly called a **tarball**.

1. Create an archive of the whole `project` directory:
   ```bash
   tar -cvf project.tar project
   ```
   The options mean: `-c` **c**reate an archive, `-v` be **v**erbose (list files as they are processed), `-f project.tar` write to this **f**ile.
2. Compare the size of the archive with the size of the original directory:
   ```bash
   ls -lh project.tar
   du -sh project
   ```
   Notice the archive is roughly the same size as its contents — `tar -cvf` alone does **not** compress anything.
3. List the contents of the archive without extracting it:
   ```bash
   tar -tvf project.tar
   ```
   `-t` lis**t**s the contents; with `-v` you also see permissions, owner, size, and timestamps.
4. Try the same command without the `-` (tar accepts old-style options too):
   ```bash
   tar tvf project.tar
   ```

**Questions**

- **2a.** What do the options `-c`, `-t`, `-v`, and `-f` each do?
- **2b.** Why is `project.tar` about as large as the `project` directory itself?
- **2c.** The `-f` option must be followed immediately by the archive filename. What do you think `tar -cfv project.tar project` would try to do?

---

## Exercise 3: Extracting a tar archive

Extraction is the reverse operation: unpacking an archive's contents into the filesystem.

1. Make a destination directory and extract the archive into it:
   ```bash
   mkdir restore
   tar -xvf project.tar -C restore
   ```
   `-x` e**x**tracts, and `-C restore` tells tar to **c**hange into the `restore` directory before unpacking.
2. Verify the restored copy matches the original:
   ```bash
   ls -lR restore/project
   diff -r project restore/project
   ```
   `diff -r` producing no output means the trees are identical.
3. Extract just a single file from the archive. First find its exact path as stored in the archive, then extract it:
   ```bash
   tar -tf project.tar
   tar -xvf project.tar project/README -C restore
   ```

**Questions**

- **3a.** Which option extracts an archive, and which option controls *where* it is extracted?
- **3b.** The archive stored paths starting with `project/`, not `/home/you/archive-lab/project/`. Why is storing *relative* paths in an archive generally safer than storing absolute ones?
- **3c.** How can you check what an archive contains *before* extracting it, and why is that a good habit?

---

## Exercise 4: Compressing files with gzip, bzip2, and xz

Linux offers three common general-purpose compressors. Each works on a *single file* and, by default, replaces the original with a compressed version bearing a new extension.

1. Make three identical copies of the big file to experiment on:
   ```bash
   cp project/bigfile.dat test1.dat
   cp project/bigfile.dat test2.dat
   cp project/bigfile.dat test3.dat
   ```
2. Compress one copy with each tool:
   ```bash
   gzip test1.dat
   bzip2 test2.dat
   xz test3.dat
   ```
   (If `bzip2` or `xz` is missing, install it with your distribution's package manager.)
3. Look at what happened to the files:
   ```bash
   ls -lh test*
   ```
   The originals are gone; in their place you have `test1.dat.gz`, `test2.dat.bz2`, and `test3.dat.xz`. Compare the three sizes.
4. Decompress the gzip file and confirm the original comes back intact:
   ```bash
   gunzip test1.dat.gz
   ls -lh test1.dat
   ```
   The equivalent commands for the others are `bunzip2` and `unxz` (or `gzip -d`, `bzip2 -d`, `xz -d`).
5. Peek inside a compressed file *without* decompressing it on disk:
   ```bash
   gzip project/docs/minutes.txt
   zcat project/docs/minutes.txt.gz
   gunzip project/docs/minutes.txt.gz
   ```

**Questions**

- **4a.** What happens to the original file when you run `gzip` on it, and what filename extension does each of the three tools add?
- **4b.** Rank gzip, bzip2, and xz by the compression they achieved on your test files. What is the usual trade-off for stronger compression?
- **4c.** Which command lets you view the contents of a `.gz` text file without creating a decompressed copy on disk?

---

## Exercise 5: Compressed tarballs — tar and compression together

Because each compressor only handles one file, the standard Linux workflow is: tar bundles the tree, then a compressor shrinks the tarball. `tar` can invoke the compressor for you with a single extra option.

1. Create three compressed tarballs of the same directory, one per compressor:
   ```bash
   tar -czvf project.tar.gz project
   tar -cjvf project.tar.bz2 project
   tar -cJvf project.tar.xz project
   ```
   The mapping is: `-z` → gzip, `-j` → bzip2, `-J` (capital) → xz.
2. Compare all four archives you have made so far:
   ```bash
   ls -lh project.tar project.tar.gz project.tar.bz2 project.tar.xz
   ```
3. List and extract a compressed tarball — the same `-t` and `-x` work, adding the matching compression option:
   ```bash
   tar -tzvf project.tar.gz
   mkdir restore-gz
   tar -xzvf project.tar.gz -C restore-gz
   ```
4. Modern GNU tar can usually detect the compression automatically when reading, so this also works:
   ```bash
   tar -xvf project.tar.xz -C restore-gz
   ```
   When *creating* an archive, though, you must state the compression option yourself.

**Questions**

- **5a.** Match each tar option — `-z`, `-j`, `-J` — to its compression program and typical file extension.
- **5b.** You often see the extension `.tgz`. What is it shorthand for?
- **5c.** Why can't you just run `gzip project` on the directory directly, skipping tar?

---

## Exercise 6: zip and unzip

The `zip` format, common on Windows and macOS, combines archiving and compression in a single tool — useful when exchanging files with users of other operating systems.

1. Create a zip archive of the project tree. Unlike tar, `zip` needs `-r` to descend into directories:
   ```bash
   zip -r project.zip project
   ```
   (Install `zip` and `unzip` via your package manager if needed.)
2. List the archive's contents without extracting:
   ```bash
   unzip -l project.zip
   ```
3. Extract it into its own directory:
   ```bash
   mkdir restore-zip
   unzip project.zip -d restore-zip
   ls -lR restore-zip
   ```
4. Try zipping the directory *without* `-r` and inspect the result:
   ```bash
   zip flat.zip project
   unzip -l flat.zip
   ```
   Only the directory entry itself was stored — none of the files inside it.

**Questions**

- **6a.** What does `-r` do in `zip -r project.zip project`, and what happens if you leave it out?
- **6b.** Which options list a zip archive's contents and choose the extraction directory?
- **6c.** Name one practical reason to choose zip over a `.tar.gz` file, and one reason to prefer `.tar.gz` on Linux.

---

## Exercise 7: Cleaning up

1. Make sure you are still in the lab directory, then remove it:
   ```bash
   cd ~/archive-lab
   cd ..
   rm -r archive-lab
   ```

**Questions**

- **7a.** If you had extracted a tarball containing `project/...` while sitting in a directory that already had a `project` subdirectory, what would have happened to files with the same names?

---

<details>
<summary><strong>Answers</strong></summary>

- **1a.** Archiving bundles multiple files and directories into a single file while preserving their structure and metadata; compressing reduces the size of data. They are independent operations: an archive need not be compressed, and a compressed file need not be an archive.
- **1b.** Compression works by finding and encoding redundancy. A file that is nothing but repeated zero bytes is almost pure redundancy, so it compresses to a tiny fraction of its original size.

- **2a.** `-c` creates a new archive, `-t` lists an archive's contents, `-v` prints each filename as it is processed (verbose), and `-f` names the archive file to write to or read from.
- **2b.** Because `tar -cvf` only concatenates the files (plus metadata headers) into one file — no compression is applied unless you add a compression option or compress afterwards.
- **2c.** Since `-f` takes the *next* word as the filename, `tar -cfv project.tar project` would try to create an archive named `v` containing `project.tar` and `project` — a classic option-ordering mistake.

- **3a.** `-x` extracts; `-C <dir>` makes tar change into `<dir>` before extracting, so the contents land there.
- **3b.** Relative paths unpack under your current directory, wherever you choose. Absolute paths would try to write to fixed locations like `/home/you/...` or `/etc/...`, potentially overwriting live files on someone else's system.
- **3c.** `tar -tf archive.tar` (add `-v` for details). Checking first tells you whether the contents are wrapped in a top-level directory or will spill loose files into your current directory, and lets you spot anything unexpected before it touches your filesystem.

- **4a.** The original file is removed and replaced by the compressed version. gzip adds `.gz`, bzip2 adds `.bz2`, and xz adds `.xz`.
- **4b.** Typically gzip compresses least, bzip2 more, and xz most (on the all-zeros file the differences are small since everything shrinks dramatically). The trade-off is time and memory: stronger compression generally runs slower, with gzip fastest and xz slowest.
- **4c.** `zcat` (equivalently `gzip -dc`) writes the decompressed contents to standard output without creating a file. Counterparts exist for the others: `bzcat` and `xzcat`.

- **5a.** `-z` → gzip → `.tar.gz`; `-j` → bzip2 → `.tar.bz2`; `-J` → xz → `.tar.xz`.
- **5b.** `.tgz` is a shortened form of `.tar.gz` — a gzip-compressed tar archive.
- **5c.** gzip, bzip2, and xz operate on single files only; they cannot bundle a directory tree. tar provides the bundling, after which the result is one file the compressor can handle.

- **6a.** `-r` makes zip recurse into the directory and include everything inside it. Without it, zip stores only the directory entry itself, so the archive is essentially empty.
- **6b.** `unzip -l archive.zip` lists the contents; `unzip archive.zip -d <dir>` extracts into `<dir>`.
- **6c.** Choose zip when sharing with Windows or macOS users, since those systems open zip files natively. Prefer `.tar.gz` on Linux because tar preserves Unix permissions and ownership more faithfully and is the ecosystem's standard format.

- **7a.** Extraction would merge into the existing `project` directory, and any files with matching names would be silently overwritten by the archive's versions — another reason to list an archive with `-t` before extracting.

</details>

---

**Reference:** LPI Learning Materials, Linux Essentials Topic 3.1 — *Archiving Files on the Command Line*: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/