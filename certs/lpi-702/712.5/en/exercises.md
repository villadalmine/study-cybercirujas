# LPI BSD Specialist (Exam 702-100) — Topic 712.5: Create and Change Hard and Symbolic Links

## Architectural Foundations & Internal Mechanics

Understanding file linkage in BSD systems (FreeBSD, OpenBSD, NetBSD) requires inspecting how the Virtual File System (VFS), Unix File System (UFS/FFS), and ZFS handle namespace management, inode allocation, and pointer resolution.

```
       Directory Entry A               Directory Entry B
    +---------------------+         +---------------------+
    | Name: app.log       |         | Name: app.log.hard  |
    | Inode: 1048580      |         | Inode: 1048580      |
    +----------+----------+         +----------+----------+
               |                               |
               +---------------+---------------+
                               |
                               v
               +-------------------------------+
               | Inode 1048580 (UFS / ZFS dnode)|
               |-------------------------------|
               | Type: REGULAR FILE            |
               | Link Count (st_nlink): 2      |
               | Permissions: -rw-r--r--       |
               | Data Pointers -> [ Blk 98412 ] |
               +-------------------------------+

       Directory Entry C
    +---------------------+
    | Name: app.log.sym   |
    | Inode: 1048581      |
    +----------+----------+
               |
               v
    +------------------------------------------+
    | Inode 1048581                            |
    |------------------------------------------|
    | Type: SYMBOLIC LINK                      |
    | Link Count (st_nlink): 1                 |
    | Target Path String: "app.log"            |
    | Storage: Inode payload (Fast Symlink)    |
    |          or Data Block (Slow Symlink)    |
    +------------------------------------------+
```

### 1. Inodes and Hard Links (`st_nlink`)
- **Directory Entry Mapping**: A directory in UNIX is simply a structured file mapping human-readable filename strings to inode numbers.
- **Hard Link Topology**: Creating a hard link creates an additional directory entry pointing to an *existing* inode number.
- **Reference Counting**: The inode metadata contains an integer field `st_nlink`. Each hard link increments `st_nlink`. Executing `rm` or `unlink(2)` removes a directory entry and decrements `st_nlink`. Physical data blocks are released back to the free storage pool **only** when `st_nlink` drops to `0` **and** no active process holds an open file descriptor (`st_refcnt == 0`) for that inode.
- **Constraints**:
  - **Cross-Mount Limitation**: Hard links cannot cross filesystem mount boundaries because inode numbers are strictly local to a specific filesystem instance/pool.
  - **Directory Prohibition**: Hard-linking directories is restricted to prevent structural cycles in the directory graph (which break traversal algorithms like `pwd` or recursive directory cleanup).

### 2. Symbolic Links (Soft Links)
- **Separate Inode & Mode**: A symbolic link allocates a brand-new inode with file mode `S_IFLNK`.
- **Target Storage**: The payload of a symbolic link is a path string pointing to another target path (relative or absolute).
  - **Fast Symlink**: If the path string fits within the inode's direct block pointer space (typically $< 60$ bytes in UFS), the path string is stored inline within the inode itself, eliminating a disk read block lookup.
  - **Slow Symlink**: If the path string exceeds the inline buffer size, external disk data blocks are allocated.
- **Resolution & Dangling Links**: Symlinks are resolved at path lookup time by VFS (`namei`). If the target path is moved, renamed, or deleted, the symlink remains, resulting in a **dangling (broken) symbolic link**.

### 3. BSD Flag Trade-Offs (`ln`)

| Flag | Description | BSD Behavioral Nuance |
| :--- | :--- | :--- |
| `-s` | Create a symbolic link instead of a hard link. | Allocates a new inode containing the target path string. |
| `-f` | Force removal of existing destination file targets. | Unlinks the target name before creating the new link. |
| `-h` / `-n` | Do not resolve target if it is a symbolic link to a directory. | **Critical BSD Behavior**: When updating a symlink pointing to a directory, `-h` prevents `ln` from entering the target directory and placing the symlink inside it. |
| `-v` | Verbose output. | Outputs `link_name -> target_name` confirmation on `stdout`. |
| `-i` | Interactive mode. | Prompts before overwriting existing destination files. |

---

## Official References

- **LPI BSD Specialist (Exam 702-100)**: [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- **FreeBSD System Manager's Manual**: [`ln(1)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=ln&sektion=1)
- **FreeBSD Programmer's Manual**: [`symlink(7)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=symlink&sektion=7)
- **FreeBSD System Calls Manual**: [`link(2)` FreeBSD Manual Page](https://man.freebsd.org/cgi/man.cgi?query=link&sektion=2)

---

## Guided Exercises

### Exercise 1: Inode Topology & Hard Link Mechanics

In this exercise, you will investigate inode allocation, `st_nlink` reference counter dynamics, and hard link boundaries across filesystems.

#### Step 1: Create a isolated workspace and inspect initial inode state
```bash
mkdir -p /tmp/sre_link_lab && cd /tmp/sre_link_lab
echo "PRIMARY_PAYLOAD_V1" > master_config.conf
stat -f "Inode: %i | Links: %l | Access: %Sp | Size: %z bytes" master_config.conf
```
*Expected Output:*
```text
Inode: 1402941 | Links: 1 | Access: -rw-r--r-- | Size: 19 bytes
```

#### Step 2: Create a hard link and verify inode identity
```bash
ln master_config.conf hard_config.conf
ls -i1 master_config.conf hard_config.conf
stat -f "File: %N | Inode: %i | Links: %l" master_config.conf hard_config.conf
```
*Expected Output:*
```text
 1402941 master_config.conf
 1402941 hard_config.conf
File: master_config.conf | Inode: 1402941 | Links: 2
File: hard_config.conf | Inode: 1402941 | Links: 2
```

#### Step 3: Test data mutation and deletion persistence
```bash
echo "APPENDED_PRODUCTION_MUTATION" >> hard_config.conf
cat master_config.conf
rm master_config.conf
stat -f "File: %N | Inode: %i | Links: %l" hard_config.conf
cat hard_config.conf
```
*Expected Output:*
```text
PRIMARY_PAYLOAD_V1
APPENDED_PRODUCTION_MUTATION
File: hard_config.conf | Inode: 1402941 | Links: 1
PRIMARY_PAYLOAD_V1
APPENDED_PRODUCTION_MUTATION
```

#### Step 4: Attempt cross-filesystem hard link generation
```bash
# Attempt to create a hard link pointing to /tmp from /dev/fd or /var/run (assuming separate mounts)
ln hard_config.conf /var/run/hard_config.conf
```
*Expected Output:*
```text
ln: /var/run/hard_config.conf: Cross-device link
```

---

#### Verification Questions — Exercise 1
1. Why did appending data to `hard_config.conf` modify the contents read from `master_config.conf`?
2. What happened to the actual data blocks on disk when `rm master_config.conf` was executed in Step 3?
3. Why does `ln` fail with `Cross-device link` when linking files across different mounted filesystems?

---

### Exercise 2: Symbolic Links, Relative vs Absolute Targets, and BSD `-h` Flag Mechanics

In this exercise, you will create relative and absolute symbolic links, analyze fast vs. slow symlink storage, and master the BSD `-h` (no-dereference) flag when replacing directory symlinks.

#### Step 1: Prepare directory structure and create relative vs absolute symbolic links
```bash
mkdir -p /tmp/sre_link_lab/app/v1 /tmp/sre_link_lab/app/v2
echo "ENGINE_V1" > /tmp/sre_link_lab/app/v1/engine.sh
echo "ENGINE_V2" > /tmp/sre_link_lab/app/v2/engine.sh

cd /tmp/sre_link_lab
ln -s app/v1 current_rel
ln -s /tmp/sre_link_lab/app/v1 current_abs

ls -la current_rel current_abs
```
*Expected Output:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:30 current_rel -> app/v1
lrwxr-xr-x  1 root  wheel  23 Aug  6 20:30 current_abs -> /tmp/sre_link_lab/app/v1
```

#### Step 2: Compare Inode numbers and file modes
```bash
stat -f "Name: %N | Inode: %i | Type/Mode: %HT (%Sp) | Size: %z" app/v1 current_rel
```
*Expected Output:*
```text
Name: app/v1 | Inode: 1402945 | Type/Mode: Directory (drwxr-xr-x) | Size: 512
Name: current_rel | Inode: 1402948 | Type/Mode: Symbolic Link (lrwxr-xr-x) | Size: 6
```

#### Step 3: Demonstrate the BSD `ln -sf` dereference trap (WITHOUT `-h`)
```bash
# We want to point current_rel to app/v2 instead of app/v1.
# Watch what happens if we omit the -h flag on BSD:
ln -sf app/v2 current_rel
ls -la current_rel
ls -la app/v1
```
*Expected Output:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:30 current_rel -> app/v1
total 2
drwxr-xr-x  2 root  wheel  512 Aug  6 20:31 .
drwxr-xr-x  4 root  wheel  512 Aug  6 20:30 ..
-rw-r--r--  1 root  wheel   10 Aug  6 20:30 engine.sh
lrwxr-xr-x  1 root  wheel    6 Aug  6 20:31 v2 -> app/v2
```

#### Step 4: Correctly update a directory symlink using BSD `ln -sfn` or `ln -sfh`
```bash
# Clean up the nested symlink created inside app/v1 by mistake
rm app/v1/v2

# Now use the -h (no-dereference) flag
ln -sfh app/v2 current_rel
ls -la current_rel
cat current_rel/engine.sh
```
*Expected Output:*
```text
lrwxr-xr-x  1 root  wheel   6 Aug  6 20:32 current_rel -> app/v2
ENGINE_V2
```

---

#### Verification Questions — Exercise 2
1. In Step 3, why did `ln -sf app/v2 current_rel` create a symlink inside `app/v1/` instead of updating `current_rel`?
2. What is the specific function of the `-h` (or `-n`) option in BSD `ln` when operating on symbolic links?
3. If `/tmp/sre_link_lab/current_rel` is moved to `/var/tmp/`, will it still resolve correctly? What about `current_abs`?

---

### Exercise 3: Production Diagnostics & Broken Link Auditing

In this exercise, you will practice advanced SRE diagnostic techniques to detect broken symbolic links, identify all hard links associated with a critical inode, and inspect symbolic link target strings using system utilities.

#### Step 1: Environment Setup — Generating production edge cases
```bash
cd /tmp/sre_link_lab
mkdir -p storage/data
touch storage/data/db.sqlite
ln storage/data/db.sqlite storage/data/db_backup.sqlite
ln -s storage/data/db.sqlite live_db.sq3
ln -s /tmp/sre_link_lab/storage/data/ghost.file broken_link.conf

# Delete the underlying primary database file
rm storage/data/db.sqlite
```

#### Step 2: Audit broken symbolic links using `find` and `readlink`
```bash
# Find all broken symbolic links under the current workspace
find -L . -type l -exec ls -la {} +
```
*Expected Output:*
```text
lrwxr-xr-x  1 root  wheel  35 Aug  6 20:35 ./broken_link.conf -> /tmp/sre_link_lab/storage/data/ghost.file
lrwxr-xr-x  1 root  wheel  19 Aug  6 20:35 ./live_db.sq3 -> storage/data/db.sqlite
```

#### Step 3: Inspect raw target paths using `readlink`
```bash
readlink live_db.sq3 broken_link.conf
```
*Expected Output:*
```text
storage/data/db.sqlite
/tmp/sre_link_lab/storage/data/ghost.file
```

#### Step 4: Locate all hard links matching a specific inode
```bash
# Find inode number of surviving hard link
TARGET_INODE=$(stat -f "%i" storage/data/db_backup.sqlite)
echo "Target Inode: ${TARGET_INODE}"

# Search filesystem by Inode number
find . -inum ${TARGET_INODE} -exec ls -li {} +
```
*Expected Output:*
```text
Target Inode: 1402952
1402952 -rw-r--r--  1 root  wheel  0 Aug  6 20:35 ./storage/data/db_backup.sqlite
```

---

#### Verification Questions — Exercise 3
1. Why does `live_db.sq3` show up as a broken link in Step 2 even though `storage/data/db_backup.sqlite` still exists with the exact original database data?
2. What flag in BSD `find` forces it to follow symbolic links during traversal to detect dangling references (`-L` vs `-P`)?
3. How does `readlink` differ from `cat` when invoked on a symbolic link file?

---

## Solutions & Diagnostic Explanations

<details>
<summary>Click here to view detailed solutions and answers</summary>

### Answers to Exercise 1
1. **Inode Sharing**: `master_config.conf` and `hard_config.conf` share the **exact same inode** (`1402941`). A hard link does not duplicate data; it simply creates a second directory entry referencing the same disk storage pointers. Any write operation on either file name mutates the underlying blocks referenced by that shared inode.
2. **Reference Counter (`st_nlink`)**: The data blocks were **not** deleted. Executing `rm master_config.conf` removed the directory entry `master_config.conf` and decremented the inode's link count (`st_nlink`) from `2` to `1`. Because `st_nlink > 0`, the VFS retained the inode and its data blocks.
3. **Cross-Device Limitation**: Inode indexes are local to a specific filesystem instance or ZFS dataset. Inode `1402941` on `/tmp` (e.g., a memory-backed `tmpfs` or standard UFS partition) has no context or meaning on `/var/run` if `/var/run` is mounted on a separate block device or dataset. Creating a hard link across mount boundaries is disallowed by VFS to prevent filesystem corruption and ambiguous inode routing.

---

### Answers to Exercise 2
1. **Symlink Dereference Behavior**: When `ln -sf app/v2 current_rel` was run without `-h`, `ln` inspected `current_rel`. Since `current_rel` was a symlink pointing to an existing directory (`app/v1`), `ln` dereferenced `current_rel`, resolved the target directory `app/v1`, and placed the new symlink (`v2`) *inside* `/tmp/sre_link_lab/app/v1/`.
2. **BSD `-h` / `-n` Option**: The `-h` (no-dereference) option instructs `ln` to treat the target destination string (`current_rel`) as a plain symbolic link file itself rather than resolving the directory it points to. This allows `ln -sfh app/v2 current_rel` to atomically overwrite the existing symlink pointer.
3. **Relative vs. Absolute Resolution**:
   - `current_rel` points to `app/v1` (a relative path). If moved to `/var/tmp/`, it will attempt to resolve `/var/tmp/app/v1`. If `/var/tmp/app/v1` does not exist, it will break.
   - `current_abs` points to `/tmp/sre_link_lab/app/v1` (an absolute path). If moved to `/var/tmp/`, it will continue resolving `/tmp/sre_link_lab/app/v1` successfully as long as that absolute path remains intact.

---

### Answers to Exercise 3
1. **Path-Based Symlink Binding**: Symbolic links point to **path names**, not inodes. `live_db.sq3` stored the string `storage/data/db.sqlite`. When `storage/data/db.sqlite` was removed, the directory entry matching that exact string path disappeared. Even though `storage/data/db_backup.sqlite` retains the original inode and data, the symlink cannot resolve because its target path string is missing.
2. **BSD `find` Traversal Logic**:
   - `-L` (Logical): Follows symbolic links. When `-type l` is combined with `-L`, `find` evaluates the *target* of the link. If the target does not exist, `find` treats the link as a broken reference.
   - `-P` (Physical): Does not follow symbolic links (default behavior). Evaluates the link file itself without dereferencing its target.
3. **`readlink` vs. `cat`**:
   - `cat` attempts to open and read the target file referenced by the symlink via `open(2)` (dereferencing the link). If the link is broken, `cat` outputs `No such file or directory`.
   - `readlink` executes the `readlink(2)` system call directly on the symbolic link inode to inspect the raw stored target string without dereferencing or resolving the target path.

</details>