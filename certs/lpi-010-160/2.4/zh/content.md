# 2.4 创建、移动和删除文件 (Creating, Moving and Deleting Files)

在 Linux 系统中，文件和目录的创建、复制、移动、重命名与删除是每天都会用到的基本操作。本节介绍如何使用 `touch`、`mkdir`、`cp`、`mv`、`rm`、`rmdir` 等 command，如何用 wildcard（通配符）一次操作多个文件，以及 hard link 和 symbolic link 的区别。

## 使用 touch 创建空文件

`touch` command 的主要作用有两个：如果文件不存在，就创建一个内容为空的新文件；如果文件已存在，就把它的 modification time（修改时间）更新为当前时间，而不改变文件内容。

```bash
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 user user 0 Jul 12 10:15 notes.txt
```

可以一次创建多个文件：

```bash
$ touch report.md draft.md summary.md
$ ls
draft.md  report.md  summary.md
```

再次对已存在的文件执行 `touch`，文件大小不变，但时间戳会刷新：

```bash
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 user user 0 Jul 12 10:22 notes.txt
```

## 使用 mkdir 创建目录

`mkdir`（make directory）用来创建新目录。

```bash
$ mkdir project
$ ls -l
drwxr-xr-x 2 user user 4096 Jul 12 10:25 project
```

如果要一次创建多层嵌套目录，父目录（parent directory）尚不存在时，直接执行 `mkdir` 会报错：

```bash
$ mkdir project/src/main
mkdir: cannot create directory 'project/src/main': No such file or directory
```

这时需要加上 `-p`（parents）选项，`mkdir` 会自动创建路径中缺失的所有中间目录：

```bash
$ mkdir -p project/src/main
$ ls -R project
project:
src

project/src:
main
```

`-p` 还有一个额外好处：如果目标目录已经存在，`mkdir -p` 不会报错，这在写脚本时非常实用。

## 通配符（Wildcards / Globbing）

Shell（如 bash）支持用通配符匹配一组文件名，这个机制叫 globbing。它由 shell 在执行 command 之前展开（expand），command 本身看到的其实是展开后的文件名列表。常用符号：

| 符号 | 含义 |
|------|------|
| `*` | 匹配任意数量（包括零个）的任意字符 |
| `?` | 匹配单个任意字符 |
| `[...]` | 匹配方括号中列出的任意一个字符，如 `[abc]`、`[0-9]` |

示例：

```bash
$ ls
file1.txt  file2.txt  fileA.log  report.md

$ ls *.txt
file1.txt  file2.txt

$ ls file?.txt
file1.txt  file2.txt

$ ls file[0-9].txt
file1.txt  file2.txt
```

通配符对 `cp`、`mv`、`rm` 同样有效，因为展开工作是 shell 做的，与具体 command 无关：

```bash
$ rm *.log
$ ls
file1.txt  file2.txt  report.md
```

> 提示：以 `.` 开头的隐藏文件（hidden file）默认不会被 `*` 匹配到，需要显式使用 `.*` 或 `ls -a` 查看。

## 使用 cp 复制文件和目录

`cp`（copy）用于复制文件或目录。

```bash
$ cp report.md report_backup.md
$ ls
report.md  report_backup.md
```

复制到目录（目录必须已存在）：

```bash
$ cp report.md project/
```

复制目录本身需要加 `-r`（或 `-R`，recursive），否则 `cp` 会拒绝执行：

```bash
$ cp project project_copy
cp: -r not specified; omitting directory 'project'

$ cp -r project project_copy
```

常用选项：

- `-i`（interactive）：目标文件已存在时先询问是否覆盖
- `-v`（verbose）：显示每个被复制的文件
- `-p`（preserve）：保留原文件的权限、所有者、时间戳等属性

```bash
$ cp -iv notes.txt project/
overwrite 'project/notes.txt'? y
'notes.txt' -> 'project/notes.txt'
```

也可以一次复制多个文件到同一个目录：

```bash
$ cp file1.txt file2.txt report.md project/
```

## 使用 mv 移动和重命名文件

`mv`（move）既可以移动文件/目录，也可以用来重命名（rename）——在 Linux 里，重命名本质上就是把文件"移动"到同一目录下的新文件名。

重命名：

```bash
$ mv draft.md final.md
$ ls
final.md  report.md
```

移动到另一个目录：

```bash
$ mv final.md project/
```

与 `cp` 不同，`mv` 不需要 `-r` 就能处理目录，因为它不是逐个复制内容，而是（在同一文件系统内）直接修改目录项：

```bash
$ mv project_copy /tmp/
```

同样支持 `-i`（覆盖前询问）和 `-v`（显示操作过程）：

```bash
$ mv -iv report.md project/
'report.md' -> 'project/report.md'
```

> 注意：当源和目标位于不同的文件系统（filesystem）或分区时，`mv` 在底层会退化为"复制后删除原文件"，操作耗时会明显变长，这一点在处理大文件或跨磁盘/跨挂载点操作时值得留意。

## 使用 rm 和 rmdir 删除文件和目录

`rm`（remove）用于删除文件：

```bash
$ rm file2.txt
```

常用选项：

- `-i`：删除前逐个确认
- `-f`（force）：强制删除，不提示、忽略不存在的文件
- `-r`（recursive）：递归删除目录及其所有内容

```bash
$ rm -r project_old
```

`rmdir`（remove directory）只能删除**空目录**，如果目录非空会报错：

```bash
$ rmdir project
rmdir: failed to remove 'project': Directory not empty

$ rmdir empty_dir
```

> ⚠️ 重要提示：Linux command line 的删除操作没有"回收站"（trash），`rm -rf` 一旦执行，文件基本无法通过普通方式恢复。在生产环境或不确定的场景下，建议先用 `rm -i` 或用 `ls` 确认目标范围，再执行删除。

## 硬链接与符号链接（Hard Links and Symbolic Links）

Linux 文件系统中，每个文件的数据在磁盘上有一个 inode（记录权限、大小、数据块位置等元信息），文件名只是指向某个 inode 的一个"标签"。`ln` command 可以为同一份数据创建额外的标签或引用。

### Hard Link

Hard link 是指向同一个 inode 的另一个文件名，两者完全等价，删除其中一个不影响另一个（只有当所有 hard link 都被删除后，数据才真正释放）。

```bash
$ echo "hello" > original.txt
$ ln original.txt hardlink.txt
$ ls -i original.txt hardlink.txt
1234567 hardlink.txt   1234567 original.txt
```

`-i` 选项显示 inode 号，可以看到两个文件名指向同一个 inode。Hard link 有限制：不能跨文件系统创建，也不能对目录创建（普通用户）。

### Symbolic Link（Symlink / Soft Link）

Symbolic link（用 `ln -s` 创建）是一个独立的小文件，内容是指向目标路径的文本，类似 Windows 的快捷方式：

```bash
$ ln -s original.txt softlink.txt
$ ls -l softlink.txt
lrwxrwxrwx 1 user user 12 Jul 12 10:40 softlink.txt -> original.txt
```

`ls -l` 输出开头的 `l` 表示这是一个链接类型，箭头 `->` 指向目标文件。Symbolic link 可以跨文件系统，也可以指向目录；但如果目标文件被删除或移动，symlink 会变成"悬挂链接"（broken link/dangling link），此时访问会报错：

```bash
$ rm original.txt
$ cat softlink.txt
cat: softlink.txt: No such file or directory
```

而 hard link 因为共享同一个 inode，即使原始文件名被删除，只要还有一个 hard link 存在，数据依然可以正常访问。

## 常见注意事项

- 通配符匹配是 shell 在执行前完成的，`rm *` 会删除当前目录下所有非隐藏文件，务必谨慎，最好先用 `echo *` 或 `ls *` 预览会匹配到哪些文件。
- 文件名含空格或特殊字符时，应使用引号（`"my file.txt"`）或转义（`my\ file.txt`），否则 command 会把它当作多个参数处理。
- `mkdir -p` 和 `rm -f`（以及 `cp`/`mv` 的 `-i`）都是脚本中常用来保证幂等性（idempotency）和避免交互式阻塞的选项。

## 参考文献 (References)

- LPI Learning Materials, Linux Essentials (010-160), Topic 2.4: <https://learning.lpi.org/en/learning-materials/010-160/2/2.4/>
- GNU Coreutils Manual — `cp`, `mv`, `rm`, `mkdir`, `rmdir`, `touch`, `ln`: <https://www.gnu.org/software/coreutils/manual/html_node/index.html>