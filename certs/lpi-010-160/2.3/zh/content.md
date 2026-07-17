# 2.3 Using Directories and Listing Files

## 概述

本主题聚焦于 Linux 文件系统中 directory（目录）的基本操作：如何知道自己"身处何处"（`pwd`）、如何在目录树中移动（`cd`）、如何列出目录内容（`ls`），以及 absolute path 与 relative path 的区别。这是日常使用命令行最基础也是使用频率最高的一组技能，几乎所有后续操作（复制、编辑、执行脚本）都建立在"能准确定位文件"这个前提之上。

## 目录树（Directory Tree）基础

Linux 采用单一的、以 `/`（root directory）为根的树状目录结构，所有存储设备最终都会被挂载（mount）到这棵树的某个节点下，而不是像 Windows 那样使用 `C:`、`D:` 等盘符。

一些考试中常涉及的重要目录：

| 目录 | 用途 |
|---|---|
| `/` | root directory，整个目录树的起点 |
| `/home` | 普通用户的 home directory 所在位置，例如 `/home/emma` |
| `/root` | root 用户（超级用户）的 home directory |
| `/etc` | 系统级配置文件（configuration files） |
| `/bin` | 基本的可执行命令（binaries），如 `ls`、`cp` |
| `/dev` | 设备文件（device files），如 `/dev/sda`、`/dev/null` |
| `/proc` | 虚拟文件系统，反映内核（kernel）与进程（process）的运行时信息 |
| `/var` | 经常变化的数据，如日志文件（logs）、缓存（cache） |
| `/tmp` | 临时文件，系统重启后通常会被清空 |
| `/usr` | 用户级应用程序与共享资源 |
| `/media`、`/mnt` | 可移动介质（如 USB）或临时挂载点 |

理解这张表有助于在做题时判断"某类文件应该出现在哪个目录"。

## Home Directory 与 Working Directory

- **Home directory**：每个用户登录后默认所在的目录，通常是 `/home/<username>`（root 用户是 `/root`）。可以用波浪号 `~` 表示，例如 `~/Documents` 等价于 `/home/emma/Documents`。
- **Working directory（当前工作目录）**：shell 会话此刻所在的目录，是所有 relative path 的计算基准。

### 查看 Working Directory：`pwd`

`pwd`（print working directory）不带参数使用即可显示当前所在的 absolute path：

```console
$ pwd
/home/emma/projects
```

常用选项：

- `pwd -P`：显示 physical path（解析所有 symbolic link 之后的真实路径）
- `pwd -L`（默认行为）：显示 logical path（保留 symbolic link，不做解析）

例如若 `/home/emma/shortcut` 是指向 `/data/real_dir` 的软链接：

```console
$ cd /home/emma/shortcut
$ pwd
/home/emma/shortcut
$ pwd -P
/data/real_dir
```

## 切换目录：`cd`

`cd`（change directory）用于切换 working directory。

```console
$ cd /etc
$ pwd
/etc
```

### Absolute Path vs Relative Path

- **Absolute path**：从 root directory `/` 开始的完整路径，无论当前在哪里都能唯一定位，例如 `/home/emma/projects/report.txt`。
- **Relative path**：相对于当前 working directory 的路径，例如若当前在 `/home/emma`，则 `projects/report.txt` 就指向同一个文件。

```console
$ pwd
/home/emma
$ cd projects           # relative path
$ pwd
/home/emma/projects
$ cd /etc                # absolute path
$ pwd
/etc
```

### `cd` 的常用快捷符号

| 写法 | 含义 |
|---|---|
| `cd`（不带参数） | 回到当前用户的 home directory |
| `cd ~` | 同上，明确回到 home directory |
| `cd -` | 回到上一次所在的目录（并打印该路径） |
| `cd .` | 停留在当前目录（`.` 代表自身） |
| `cd ..` | 回到上一级目录（`..` 代表 parent directory） |
| `cd ~user` | 切换到指定用户 `user` 的 home directory（需有权限） |

```console
$ cd /var/log
$ cd
$ pwd
/home/emma
$ cd -
/var/log
$ cd ..
$ pwd
/var
```

## 列出目录内容：`ls`

`ls`（list）是查看目录内容最核心的命令，不带参数时列出 working directory 中的非隐藏文件与子目录：

```console
$ ls
Documents  Downloads  Music  Pictures  report.txt
```

也可以直接指定目标路径（absolute 或 relative）：

```console
$ ls /etc
$ ls ../
```

### 常用选项

**`-a`（all）— 显示所有文件，包括 hidden file**

```console
$ ls -a
.  ..  .bashrc  .config  Documents  report.txt
```

**`-d`（directory）— 只显示目录本身的信息，不展开其内容**

对比：

```console
$ ls /etc          # 会列出 /etc 目录下所有条目
$ ls -d /etc        # 只输出 /etc 本身这一行
/etc
```

`-d` 常与 `-l` 搭配，用来只查看某个目录条目自身的属性，而不深入其内容。

**`-F`（classify）— 在文件名末尾追加符号，标识文件类型**

| 后缀符号 | 含义 |
|---|---|
| `/` | directory |
| `*` | 可执行文件（executable） |
| `@` | symbolic link |
| `\|` | named pipe（FIFO） |
| `=` | socket |

```console
$ ls -F
Documents/  backup.sh*  notes.txt  link_to_conf@
```

**`-R`（recursive）— 递归列出所有子目录的内容**

```console
$ ls -R Documents
Documents:
notes  work

Documents/work:
report.txt  draft.txt
```

**`-l`（long format）— 显示详细信息**

```console
$ ls -l
total 16
drwxr-xr-x 2 emma emma 4096 Mar  3 10:15 Documents
-rw-r--r-- 1 emma emma  220 Mar  1 09:00 report.txt
lrwxrwxrwx 1 emma emma   11 Mar  2 14:30 link_to_conf -> /etc/conf
```

`ls -l` 每一列的含义：

1. **文件类型 + 权限位**（第 1 个字符为类型，如 `d`=directory、`-`=普通文件、`l`=symbolic link，其余 9 位为 owner/group/other 的 rwx 权限）
2. **hard link 数量**
3. **owner（属主）**
4. **group（属组）**
5. **文件大小**（字节）
6. **最后修改时间**
7. **文件名**（若为 symbolic link，会以 `-> target` 显示指向目标）

选项可以组合使用，例如查看 home directory 下所有文件（含隐藏文件）的详细信息：

```console
$ ls -la ~
```

## Hidden File（隐藏文件）

在 Linux 中，文件名以英文句点 `.` 开头的文件或目录即为 hidden file，`ls` 默认不显示它们，必须加 `-a`（或 `-A`，后者会排除 `.` 和 `..` 这两个特殊条目）才能看到。常见的隐藏文件多为用户级配置文件，例如 `~/.bashrc`、`~/.ssh/`、`~/.config/`。

```console
$ ls -A ~
.bashrc  .config  .ssh  Documents  report.txt
```

## 小结与实践建议

- `pwd` 回答"我在哪"，`cd` 回答"我要去哪"，`ls` 回答"这里有什么"。
- Relative path 依赖当前 working directory，写脚本或跨目录操作时优先考虑使用 absolute path 以避免歧义。
- `ls -l` 输出的第一列字符（文件类型）是判断一个条目究竟是普通文件、目录还是链接的关键，考试中常以此类输出让考生判断文件类型。
- 多练习组合选项，如 `ls -la`、`ls -ld`、`ls -lR`，理解每个选项单独和组合后的效果差异。

## Referencias

- LPI Learning Materials — Topic 2.3: Using Directories and Listing Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual — `pwd`: https://www.gnu.org/software/coreutils/manual/html_node/pwd-invocation.html
- GNU Coreutils Manual — `cd`（Bash Builtin Commands）: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
- GNU Coreutils Manual — `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- Filesystem Hierarchy Standard (FHS): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html