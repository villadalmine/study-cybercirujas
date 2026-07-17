# 3.1 Archiving Files on the Command Line

## 概述

在 Linux 系统管理中，**archiving**（归档）指的是把多个文件和目录打包成一个单一文件，便于备份、传输或分发；**compression**（压缩）则是缩小文件体积以节省磁盘空间或网络带宽。这两个操作在概念上是独立的，但在实际工作中经常结合使用：先用 `tar` 把文件打包成一个 archive，再用 `gzip`、`bzip2` 或 `xz` 对这个 archive 进行压缩。

本主题涉及的核心命令工具（terms and utilities）包括：

- `tar` —— 最常用的归档工具（tape archive 的缩写，历史上用于磁带备份）
- `gzip` / `gunzip` —— 基于 DEFLATE 算法的压缩工具，速度快，压缩率一般
- `bzip2` / `bunzip2` —— 基于 Burrows-Wheeler 算法，压缩率比 gzip 高，速度较慢
- `xz` / `unxz` —— 基于 LZMA2 算法，压缩率最高，速度最慢
- `zip` / `unzip` —— 与 Windows 兼容的归档+压缩工具（DOS/Windows 世界常见格式）
- `cpio` —— 另一种传统的 UNIX 归档工具，常用于处理文件列表（如配合 `find`）

---

## tar 命令

`tar` 是 LPI Linux Essentials 考试中最重要的归档工具，几乎所有系统的 backup、软件源码分发（例如 `.tar.gz` 源码包）都依赖它。

### 基本语法

```bash
tar [OPTIONS] [ARCHIVE_FILE] [FILE_OR_DIRECTORY...]
```

`tar` 支持两种风格的参数：GNU 风格（不带短横线，如 `tar cvf`）和 POSIX 风格（带短横线，如 `tar -cvf`）。两种写法在考试和实际使用中都很常见。

### 三个核心操作模式

| 选项 | 含义 |
|------|------|
| `-c` (`--create`) | 创建一个新的 archive |
| `-x` (`--extract`) | 从 archive 中解压文件 |
| `-t` (`--list`) | 列出 archive 中的内容，不解压 |

### 常用修饰选项

| 选项 | 含义 |
|------|------|
| `-f FILE` (`--file=FILE`) | 指定 archive 文件名（几乎总是必须的，且要放在选项列表最后） |
| `-v` (`--verbose`) | 显示处理过程中的文件名（verbose 模式） |
| `-z` (`--gzip`) | 通过 gzip 压缩/解压 |
| `-j` (`--bzip2`) | 通过 bzip2 压缩/解压 |
| `-J` (`--xz`) | 通过 xz 压缩/解压 |
| `-C DIR` (`--directory=DIR`) | 解压到指定目录，而不是当前目录 |
| `-p` (`--preserve-permissions`) | 保留文件权限 |
| `--exclude=PATTERN` | 排除匹配的文件 |

### 创建 archive

```bash
$ tar -cvf backup.tar Documents/
Documents/
Documents/notes.txt
Documents/report.pdf
```

`-c` 表示创建，`-v` 表示显示过程，`-f backup.tar` 指定输出文件名为 `backup.tar`。注意：`.tar` 文件本身**不压缩**，只是把多个文件合并成一个文件。

### 查看 archive 内容（不解压）

```bash
$ tar -tvf backup.tar
drwxr-xr-x user/user 0 2026-07-10 10:20 Documents/
-rw-r--r-- user/user 512 2026-07-10 10:15 Documents/notes.txt
-rw-r--r-- user/user 20480 2026-07-10 10:18 Documents/report.pdf
```

在解压之前先用 `-t` 查看内容是一个好习惯，可以避免 archive 中的文件覆盖当前目录下的同名文件。

### 解压 archive

```bash
$ tar -xvf backup.tar
Documents/
Documents/notes.txt
Documents/report.pdf
```

解压到指定目录：

```bash
$ tar -xvf backup.tar -C /tmp/restore/
```

### 只解压 archive 中的某个文件

```bash
$ tar -xvf backup.tar Documents/notes.txt
```

### 追加文件到已存在的 archive

```bash
$ tar -rvf backup.tar newfile.txt
```

`-r` (`--append`) 只能用于未压缩的 `.tar` 文件；已经压缩过的 archive（如 `.tar.gz`）不能直接追加。

---

## 压缩工具：gzip、bzip2、xz

`tar` 本身只负责打包，不负责压缩。真正的压缩由独立的压缩工具完成，`tar` 通过 `-z`/`-j`/`-J` 选项调用它们。这三个工具也可以单独使用，压缩单个文件（不打包多个文件）。

### gzip / gunzip

```bash
$ gzip file.txt
$ ls
file.txt.gz
```

`gzip` 压缩后会**替换原文件**，生成 `.gz` 后缀的文件；原文件被删除。解压使用 `gunzip`，或 `gzip -d`：

```bash
$ gunzip file.txt.gz
$ ls
file.txt
```

常用选项：

| 选项 | 含义 |
|------|------|
| `-k` (`--keep`) | 压缩/解压后保留原文件 |
| `-1` 到 `-9` | 压缩级别，`-1` 最快（压缩率低），`-9` 最慢（压缩率高），默认 `-6` |
| `-c` (`--stdout`) | 输出到标准输出，不覆盖原文件 |
| `-l` (`--list`) | 显示压缩文件的信息（压缩前后大小、压缩率） |

```bash
$ gzip -l file.txt.gz
         compressed        uncompressed  ratio uncompressed_name
                842                2048  58.9% file.txt
```

### bzip2 / bunzip2

用法与 `gzip` 几乎一致，但压缩算法不同（Burrows-Wheeler transform），通常压缩率更高，速度更慢：

```bash
$ bzip2 file.txt
$ ls
file.txt.bz2

$ bunzip2 file.txt.bz2
```

同样支持 `-k`（保留原文件）和 `-1` 到 `-9`（压缩级别）。

### xz / unxz

`xz` 使用 LZMA2 算法，在三者中通常能获得**最高的压缩率**，但消耗的 CPU 时间和内存也最多：

```bash
$ xz file.txt
$ ls
file.txt.xz

$ unxz file.txt.xz
```

同样支持 `-k` 保留原文件，`-0` 到 `-9` 调整压缩级别（`-9` 压缩率最高最慢）。

### 三者对比（考试重点）

| 工具 | 后缀 | 算法 | 压缩率 | 速度 |
|------|------|------|--------|------|
| gzip | `.gz` | DEFLATE | 低 | 快 |
| bzip2 | `.bz2` | Burrows-Wheeler | 中 | 中 |
| xz | `.xz` | LZMA2 | 高 | 慢 |

一般规律：**压缩率越高，速度越慢，消耗资源越多**。选择哪个工具取决于场景——需要快速处理选 `gzip`，需要节省磁盘/带宽选 `xz`。

---

## tar 与压缩工具结合使用

这是实际工作和考试中最常见的用法：一步完成"打包 + 压缩"。

### 创建 .tar.gz（或 .tgz）

```bash
$ tar -czvf backup.tar.gz Documents/
```

### 创建 .tar.bz2

```bash
$ tar -cjvf backup.tar.bz2 Documents/
```

### 创建 .tar.xz

```bash
$ tar -cJvf backup.tar.xz Documents/
```

### 解压对应格式

`tar` 现代版本（GNU tar）能够**自动识别压缩格式**，即使不指定 `-z`/`-j`/`-J` 也能正确解压：

```bash
$ tar -xvf backup.tar.gz
$ tar -xvf backup.tar.bz2
$ tar -xvf backup.tar.xz
```

但显式指定压缩选项仍是推荐做法，尤其是在旧版本 `tar` 或非 GNU 实现中：

```bash
$ tar -xzvf backup.tar.gz
$ tar -xjvf backup.tar.bz2
$ tar -xJvf backup.tar.xz
```

### 常见文件扩展名对照表

| 扩展名 | 含义 |
|--------|------|
| `.tar` | 未压缩的 tar archive |
| `.tar.gz` / `.tgz` | tar + gzip |
| `.tar.bz2` / `.tbz2` | tar + bzip2 |
| `.tar.xz` / `.txz` | tar + xz |
| `.gz` | 单个文件用 gzip 压缩（不是 archive） |
| `.zip` | zip 归档（自带压缩，跨平台常见） |

---

## cpio 命令

`cpio`（copy in / copy out）是另一种历史悠久的归档工具，与 `tar` 不同的是它从**标准输入读取文件名列表**，常与 `find` 配合使用。

### 创建 archive（copy-out 模式，`-o`）

```bash
$ find Documents/ -print | cpio -ov > backup.cpio
```

`find` 生成文件路径列表，通过管道传给 `cpio -o`（输出/打包模式），`-v` 显示处理过程。

### 解压 archive（copy-in 模式，`-i`）

```bash
$ cpio -iv < backup.cpio
```

### 列出 archive 内容

```bash
$ cpio -tv < backup.cpio
```

`cpio` 在考试中出现频率低于 `tar`，但需要记住它是"从标准输入读取文件列表"这一特点，这是它与 `tar` 最大的区别。

---

## zip / unzip

`zip` 格式在 Windows 世界中最常见，Linux 也提供了兼容工具，特点是**打包和压缩是同一步完成**（不像 tar 需要额外调用压缩工具）。

### 创建 zip 归档

```bash
$ zip -r backup.zip Documents/
  adding: Documents/ (stored 0%)
  adding: Documents/notes.txt (deflated 45%)
  adding: Documents/report.pdf (deflated 12%)
```

`-r` (`--recurse-paths`) 用于递归打包目录，是压缩目录时的必选项（否则只会压缩空目录条目）。

### 解压 zip 归档

```bash
$ unzip backup.zip
```

### 查看 zip 内容而不解压

```bash
$ unzip -l backup.zip
Archive:  backup.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-07-10 10:20   Documents/
      512  2026-07-10 10:15   Documents/notes.txt
    20480  2026-07-10 10:18   Documents/report.pdf
```

---

## 常见考点提示

1. **`-f` 选项必须紧跟文件名**，且在 GNU 风格连写选项（如 `-cvf`）中，`f` 必须是最后一个字母，因为它后面要接文件名参数：`tar -cvf archive.tar file` 正确，`tar -fcv archive.tar file` 错误。
2. **`tar` 单独不做压缩**，压缩是 `-z`/`-j`/`-J` 调用外部工具实现的；现代 GNU tar 在解压时可以自动检测压缩格式。
3. **`gzip`/`bzip2`/`xz` 默认会删除原文件**，替换为压缩后的文件；用 `-k` 保留原文件。
4. **压缩率与速度成反比**：xz > bzip2 > gzip（压缩率），gzip > bzip2 > xz（速度）。
5. **`cpio` 从标准输入读取文件名**，通常与 `find` 配合，这是它区别于 `tar` 的关键特征。
6. **`zip` 是打包+压缩一体化**的格式，跨平台（尤其与 Windows）兼容性好；`zip -r` 中的 `-r` 用于递归目录。

---

## Referencias

- LPI Learning Materials — Topic 3.1 Archiving Files on the Command Line: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- GNU tar Manual: https://www.gnu.org/software/tar/manual/tar.html
- gzip 官方手册: https://www.gnu.org/software/gzip/manual/gzip.html
- bzip2 官方文档: https://sourceware.org/bzip2/
- XZ Utils 官方文档: https://tukaani.org/xz/
- Info-ZIP (zip/unzip) 项目主页: http://infozip.sourceforge.net/
- cpio GNU Manual: https://www.gnu.org/software/cpio/manual/cpio.html
- Linux man pages: `man tar`, `man gzip`, `man bzip2`, `man xz`, `man cpio`, `man zip`, `man unzip`