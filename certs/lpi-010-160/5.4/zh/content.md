# LPI Linux Essentials (010-160 v1.6) — 主题 5.4：Special Directories and Files

## 概述

本主题考察你对 Linux 系统中一些特殊目录和特殊文件类型的理解，包括：

- 具有特殊用途的目录：`/tmp`、`/var/tmp`
- 特殊权限位：SUID、SGID、sticky bit
- 链接（link）机制：hard link 与 symbolic link
- 特殊设备文件：`/dev/null`、`/dev/zero`、`/dev/random`、`/dev/urandom`

考试权重为 1，属于较轻量的知识点，但概念本身在日常系统管理和安全加固中非常常见。

---

## 1. 临时目录：`/tmp` 与 `/var/tmp`

Linux 遵循 FHS（Filesystem Hierarchy Standard），规定了两个用于存放临时文件的标准目录：

| 目录 | 用途 | 生命周期 |
|---|---|---|
| `/tmp` | 应用程序运行期间的临时文件 | 系统重启后通常会被清空 |
| `/var/tmp` | 需要在重启后仍然保留的临时文件 | 保留时间更长，清理周期更长（常见策略：超过一定天数未访问才删除） |

两者通常都对所有用户开放写入权限（`777`），但依赖 **sticky bit**（见下文）防止用户互相删除对方的文件。

```bash
$ ls -ld /tmp /var/tmp
drwxrwxrwt. 20 root root 4096 Jul 12 10:00 /tmp
drwxrwxrwt.  4 root root 4096 Jul 12 09:00 /var/tmp
```

注意末尾的 `t`（而不是 `x`），这就是 sticky bit 生效的标志。

大多数发行版通过 `systemd-tmpfiles`（配置文件位于 `/usr/lib/tmpfiles.d/` 和 `/etc/tmpfiles.d/`）或定期任务（如旧式的 `tmpwatch`/`tmpreaper`）来清理这些目录中的过期文件。

---

## 2. 特殊权限位（Special Permissions）

除了常规的 `rwx` 权限外，Linux 还提供三个特殊权限位：**SUID**、**SGID**、**sticky bit**。它们都通过给权限值加上一个额外的八进制数字（第四位，写在常规三位权限之前）来设置。

### 2.1 SUID（Set User ID）— 数字 `4`

作用于**可执行文件**：程序运行时，其**有效用户身份（effective UID）**变为**文件所有者**的身份，而不是执行它的用户。

典型例子是 `passwd` 命令——普通用户需要修改 `/etc/shadow`（该文件仅 root 可写），SUID 让程序临时获得 root 权限来完成修改：

```bash
$ ls -l /usr/bin/passwd
-rwsr-xr-x. 1 root root 27856 Mar  1  2024 /usr/bin/passwd
```

注意所有者执行位上的 `s`（原本应为 `x`）。设置方法：

```bash
$ chmod u+s /path/to/program
$ chmod 4755 /path/to/program
```

若程序不可执行（`x` 位未设置），SUID 位会显示为大写 `S`，表示配置无效（权限位设置了，但没有意义）。

### 2.2 SGID（Set Group ID）— 数字 `2`

- 作用于**可执行文件**：运行时有效组身份变为文件所属组。
- 作用于**目录**：目录内新创建的文件/子目录会自动继承该目录的组所有权，而不是创建者的主组。这在团队共享目录时非常实用。

```bash
$ mkdir /srv/teamdir
$ chgrp devteam /srv/teamdir
$ chmod g+s /srv/teamdir
$ ls -ld /srv/teamdir
drwxr-sr-x. 2 root devteam 4096 Jul 12 10:00 /srv/teamdir

$ touch /srv/teamdir/newfile
$ ls -l /srv/teamdir/newfile
-rw-r--r--. 1 alice devteam 0 Jul 12 10:05 newfile
```
即使 `alice` 的主组不是 `devteam`，新建文件的组也自动变为 `devteam`。

### 2.3 Sticky Bit — 数字 `1`

主要作用于**目录**：目录内的文件只能被**文件所有者**、**目录所有者**或 **root** 删除或重命名，即使其他用户对该目录本身拥有写权限。这正是 `/tmp` 保持 `777` 权限却依然安全的原因。

```bash
$ chmod +t /srv/shared
$ chmod 1777 /srv/shared
$ ls -ld /srv/shared
drwxrwxrwt. 2 root root 4096 Jul 12 10:00 /srv/shared
```

若目录不可执行，sticky bit 同样显示为大写 `T`。

### 2.4 三者组合的数字表示

`chmod` 的四位数字模式：**第一位**为特殊权限之和（SUID=4, SGID=2, sticky=1），后三位为常规权限：

```bash
$ chmod 4755 file    # SUID + rwxr-xr-x
$ chmod 2775 dir     # SGID + rwxrwxr-x
$ chmod 1777 dir     # sticky + rwxrwxrwx
```

---

## 3. 链接（Links）：Hard Link 与 Symbolic Link

理解链接前，先理解 **inode**：Linux 文件系统中，文件的元数据（权限、所有者、大小、数据块指针等）存储在 inode 中，而目录条目只是"文件名 → inode 号"的映射。

```bash
$ ls -i /etc/hostname
1234567 /etc/hostname
```

### 3.1 Hard Link（硬链接）

硬链接是**指向同一个 inode 的另一个目录条目**——本质上它和原文件是完全平等的，没有"谁是原件"的概念。

```bash
$ echo "hello" > original.txt
$ ln original.txt hardlink.txt

$ ls -li original.txt hardlink.txt
1234567 -rw-r--r--. 2 user user 6 Jul 12 10:00 hardlink.txt
1234567 -rw-r--r--. 2 user user 6 Jul 12 10:00 original.txt
```

两者 inode 号相同，链接数（第二列）为 `2`。删除其中一个文件名，数据依然存在，直到链接计数归零：

```bash
$ rm original.txt
$ cat hardlink.txt
hello
```

**限制：**
- 不能跨文件系统（分区）创建，因为 inode 号只在同一文件系统内唯一。
- 不能指向目录（防止产生目录树的循环引用）。

### 3.2 Symbolic Link（符号链接 / soft link）

符号链接是一个**独立的、内容为目标路径字符串的特殊文件**——类似 Windows 的快捷方式。它拥有自己独立的 inode。

```bash
$ ln -s /etc/hostname mylink

$ ls -li mylink /etc/hostname
1234567 -rw-r--r--. 1 root root   9 Jul 12 09:00 /etc/hostname
7654321 lrwxrwxrwx. 1 user user  13 Jul 12 10:10 mylink -> /etc/hostname
```

注意：
- 类型字符为 `l`（而非 `-`），权限通常显示为 `rwxrwxrwx`（符号链接本身的权限不影响访问，实际权限取决于目标文件）。
- inode 号与目标不同。
- 若目标文件被删除或移动，符号链接会变成 **dangling link**（悬空链接），访问时报错 `No such file or directory`。
- 可以跨文件系统，也可以指向目录。

```bash
$ rm /etc/hostname   # 仅作演示，实际系统请勿删除
$ cat mylink
cat: mylink: No such file or directory
```

### 3.3 Hard Link 与 Symbolic Link 对比

| 特性 | Hard Link | Symbolic Link |
|---|---|---|
| inode | 与原文件相同 | 独立的新 inode |
| 跨文件系统 | 不支持 | 支持 |
| 可链接目录 | 不支持 | 支持 |
| 原文件被删除后 | 数据仍可访问 | 链接失效（悬空） |
| 创建命令 | `ln target linkname` | `ln -s target linkname` |

---

## 4. 特殊设备文件（`/dev` 中的伪设备）

`/dev` 目录中的文件大多是**设备文件**（character device 用 `c`，block device 用 `b` 标识），其中有几个常被用作"数据生成器/黑洞"，考试中经常涉及：

```bash
$ ls -l /dev/null /dev/zero /dev/random /dev/urandom
crw-rw-rw-. 1 root root 1, 3 Jul 12 08:00 /dev/null
crw-rw-rw-. 1 root root 1, 5 Jul 12 08:00 /dev/zero
crw-rw-rw-. 1 root root 1, 8 Jul 12 08:00 /dev/random
crw-rw-rw-. 1 root root 1, 9 Jul 12 08:00 /dev/urandom
```

- **`/dev/null`**：写入的所有数据都被丢弃（"黑洞"），读取时立即返回 EOF。常用于丢弃不需要的输出：
  ```bash
  $ command > /dev/null 2>&1
  ```
- **`/dev/zero`**：读取时无限返回字节 `\0`。常用于生成指定大小的空白文件：
  ```bash
  $ dd if=/dev/zero of=testfile bs=1M count=10
  10+0 records in
  10+0 records out
  10485760 bytes (10 MB) copied
  ```
- **`/dev/random`** 与 **`/dev/urandom`**：提供随机字节流，供加密等场景使用。`/dev/random` 在熵池不足时会阻塞等待，`/dev/urandom` 则不阻塞（现代内核中两者的安全性差异已大幅缩小）。
  ```bash
  $ head -c 16 /dev/urandom | xxd
  ```

---

## 参考文档

- LPI Learning Materials — 010-160, 主题 5.4: <https://learning.lpi.org/en/learning-materials/010-160/5/5.4/>
- Filesystem Hierarchy Standard (FHS): <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- `chmod(1)` man page: <https://man7.org/linux/man-pages/man1/chmod.1.html>
- `ln(1)` man page: <https://man7.org/linux/man-pages/man1/ln.1.html>
- `inode(7)` man page: <https://man7.org/linux/man-pages/man7/inode.7.html>
- `random(4)` man page: <https://man7.org/linux/man-pages/man4/random.4.html>