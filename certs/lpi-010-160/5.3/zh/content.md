# 5.3 Managing File Permissions and Ownership

## 概述

Linux 是多用户系统，每一个文件和目录都归属于一个 owner（属主）和一个 group（属组），并且带有一组决定谁能做什么的 permissions（权限）。理解并正确设置这些权限，是保障系统安全、避免误删除或未授权访问的基础技能，也是 Linux Essentials 考试中的核心内容之一。

## 权限的三个维度：Owner / Group / Others

每个文件在文件系统层面都记录着：

- **owner**：创建该文件的用户（也可以通过 `chown` 转移）
- **group**：与该文件关联的用户组
- **others**：既不是 owner 也不属于该 group 的其他所有用户

用 `ls -l` 查看时可以看到这三类主体各自的权限：

```console
$ ls -l notes.txt
-rw-r--r-- 1 alice devs 1024 Jul  10 09:15 notes.txt
```

拆解这一串字符 `-rw-r--r--`：

| 位置 | 含义 |
|---|---|
| 第 1 位 | 文件类型：`-` 普通文件、`d` 目录、`l` symbolic link |
| 第 2-4 位 | owner 权限：`rw-` |
| 第 5-7 位 | group 权限：`r--` |
| 第 8-10 位 | others 权限：`r--` |

## 三种基本权限：read / write / execute

| 符号 | 对**文件**的含义 | 对**目录**的含义 |
|---|---|---|
| `r` (read) | 可以读取文件内容 | 可以列出目录内容（如 `ls`） |
| `w` (write) | 可以修改/覆盖文件内容 | 可以在目录中新建、删除、重命名条目 |
| `x` (execute) | 可以将文件作为程序/脚本执行 | 可以进入该目录（如 `cd`），或访问其中文件的属性 |

一个常见的易混点：目录上的 `x` 权限并不等同于 `r`。没有 `x` 的目录，即使有 `r`，也无法 `cd` 进去访问其中的文件；没有 `r` 的目录（但有 `x`），可以 `cd` 进去，但不能 `ls` 列出内容——只有在已知文件名的情况下才能访问。

## chmod：修改权限

`chmod` (change mode) 有两种表示法。

### 1. Symbolic mode（符号模式）

语法：`chmod [ugoa][+-=][rwx] file`

- `u` = user (owner)，`g` = group，`o` = others，`a` = all（三者都改）
- `+` 增加权限，`-` 移除权限，`=` 直接设为指定权限（清空未列出的位）

```console
$ chmod g+w notes.txt      # 给 group 增加写权限
$ chmod o-r notes.txt      # 移除 others 的读权限
$ chmod u=rwx,g=rx,o= script.sh   # 精确设置三组权限
```

也可以用逗号一次性设置多组：

```console
$ chmod u+x,g+x script.sh
```

### 2. Numeric (octal) mode（数字/八进制模式）

把 `r`、`w`、`x` 分别当作二进制位，对应数值 `4`、`2`、`1`，三者相加得到一个 0-7 的数字，分别代表 owner、group、others：

| 权限组合 | 二进制 | 数值 |
|---|---|---|
| `rwx` | 111 | 7 |
| `rw-` | 110 | 6 |
| `r-x` | 101 | 5 |
| `r--` | 100 | 4 |
| `---` | 000 | 0 |

```console
$ chmod 644 notes.txt   # owner: rw-, group: r--, others: r--
$ chmod 755 script.sh   # owner: rwx, group: r-x, others: r-x
$ chmod 700 secret.sh   # 只有 owner 可读写执行
```

常见组合速记：`755` 用于可执行脚本/目录，`644` 用于普通数据文件，`700`/`600` 用于仅属主可访问的私密文件。

### 递归修改

对目录及其内容批量修改，加 `-R`（recursive）：

```console
$ chmod -R 750 /srv/webapp
```

## chown 与 chgrp：修改所有权

`chown` (change owner) 修改文件的 owner，也可以同时修改 group：

```console
$ chown bob notes.txt              # 只改 owner
$ chown bob:devs notes.txt         # 同时改 owner 和 group
$ chown :devs notes.txt            # 只改 group（等价于 chgrp devs notes.txt）
```

`chgrp` (change group) 专门用于修改 group：

```console
$ chgrp devs notes.txt
```

递归修改同样支持 `-R`：

```console
$ chown -R www-data:www-data /var/www/html
```

**注意**：普通用户通常无法把文件的 owner 改为别人（会得到 `Operation not permitted`），这一操作一般需要 `root` 权限（常通过 `sudo` 执行）。而修改 group，只要用户本身属于目标 group，就可以自行操作。

## Special permissions：setuid / setgid / sticky bit

除了 `rwx`，还有三个特殊权限位，常出现在 `ls -l` 输出的 execute 位上，用 `s` 或 `t` 表示：

| 权限 | 作用于文件 | 作用于目录 | 数字前缀 |
|---|---|---|---|
| **setuid** | 执行时以该文件 owner 的身份运行（例如 `/usr/bin/passwd`） | 通常无意义 | `4` |
| **setgid** | 执行时以该文件 group 的身份运行 | 目录内新建的文件自动继承该目录的 group | `2` |
| **sticky bit** | 一般无意义 | 目录内的文件只能被其 owner（或 root）删除，即使其他用户对目录有写权限 | `1` |

示例：

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar  1 2024 /usr/bin/passwd
```

owner 位上的 `s` 表示 setuid：普通用户执行 `passwd` 时，进程会临时获得 root 权限，从而能够写入受保护的 `/etc/shadow`。

```console
$ chmod 4755 /usr/local/bin/tool     # 设置 setuid
$ chmod g+s /shared/project          # 设置 setgid（新文件自动继承目录 group）
$ chmod +t /tmp                      # 设置 sticky bit
$ ls -ld /tmp
drwxrwxrwt 14 root root 4096 Jul 12 09:00 /tmp
```

`/tmp` 是 sticky bit 最典型的应用：所有人都能写入，但只有文件的创建者才能删除自己的文件。

数字模式下，特殊权限是在常规三位数字前多加一位（如 `chmod 2775 dir` 表示 setgid + `rwxrwxr-x`）。

## umask：新建文件/目录的默认权限

`umask` 决定新建文件和目录时**默认排除**哪些权限。系统的基准值是：文件 `666`，目录 `777`（普通文件默认不给 execute）。umask 值会从基准值中"减去"对应的位。

```console
$ umask
0022
```

计算方式：`基准值 & ~umask`。以 `umask 022` 为例：

- 新目录：`777 - 022 = 755`（`rwxr-xr-x`）
- 新文件：`666 - 022 = 644`（`rw-r--r--`），因为文件基准值没有 execute 位

验证：

```console
$ umask 027
$ touch a.txt && mkdir b
$ ls -l a.txt; ls -ld b
-rw-r----- 1 alice devs    0 Jul 12 09:20 a.txt
drwxr-x--- 2 alice devs 4096 Jul 12 09:20 b
```

`umask` 一般在 shell 启动脚本（如 `/etc/profile`、`~/.bashrc`）中设置，对当前 shell 及其子进程生效。

## 常见组合示例

```console
$ ls -l
drwxr-xr-x  2 alice devs 4096 Jul 12 08:00 project
-rw-rw-r--  1 alice devs  512 Jul 12 08:01 project/report.md
-rwxr-xr-x  1 alice devs 2048 Jul 12 08:02 project/build.sh
lrwxrwxrwx  1 alice devs    9 Jul 12 08:03 project/latest -> report.md
```

- `project` 目录：owner 可读写执行（能进入并管理内容），group/others 只能进入和列出
- `report.md`：owner 和 group 都能编辑，others 只读
- `build.sh`：所有人都能执行，只有 owner 能修改
- `latest`：symbolic link 本身的权限位（`rwxrwxrwx`）在大多数系统上没有实际意义，真正生效的是它所指向目标文件的权限

## 小结

| 命令 | 作用 |
|---|---|
| `ls -l` / `ls -ld` | 查看文件/目录权限、owner、group |
| `chmod` | 修改 rwx 权限（symbolic 或 octal） |
| `chown` | 修改 owner（可同时修改 group） |
| `chgrp` | 修改 group |
| `umask` | 设置新建文件/目录的默认权限掩码 |

## Referencias

- LPI Learning Materials, Topic 5.3 — Managing File Permissions and Ownership: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- `chmod(1)` man page: https://man7.org/linux/man-pages/man1/chmod.1.html
- `chown(1)` man page: https://man7.org/linux/man-pages/man1/chown.1.html
- `umask(1p)` man page (POSIX): https://man7.org/linux/man-pages/man1/umask.1p.html