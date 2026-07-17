# 2.2 使用命令行获取帮助（Using the Command Line to Get Help）

## 概述

在 Linux 系统中，几乎每一个命令、每一个配置文件格式都自带官方文档。掌握如何在命令行（command line）中快速查找和阅读帮助信息，是 Linux 用户最基础也是最重要的技能之一。本节主要介绍以下几种获取帮助的方式：`man` 命令及其手册页系统（man pages）、`--help` 选项、`info` 系统，以及系统中自带的其它文档资源（`/usr/share/doc`）。

---

## 1. `--help` 选项

绝大多数命令行程序都支持 `--help`（部分程序也支持简写 `-h`）选项，用于快速打印该命令的用法摘要（usage summary），包括可用的选项（options）和简单说明。这是获取帮助最快、最直接的方式，适合已经大致了解命令用途、只是想确认某个选项拼写或用法的场景。

示例：

```bash
$ cp --help
Usage: cp [OPTION]... [-T] SOURCE DEST
  or:  cp [OPTION]... SOURCE... DIRECTORY
  or:  cp [OPTION]... -t DIRECTORY SOURCE...
Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.

Mandatory arguments to long options are mandatory for short options too.
  -a, --archive                same as -dR --preserve=all
  -b                            like --backup but does not accept an argument
  -f, --force                   if an existing destination file cannot be
                                  opened, remove it and try again
  ...
```

`--help` 的输出通常比 man page 简短很多，只列出选项而不做详细展开，适合快速查阅（quick reference），而不是系统学习。

> 注意：`--help` 是命令自身实现的功能（大多数 GNU 工具都支持），并非所有程序都保证提供该选项；一些老旧或非 GNU 的工具可能不支持，此时应改用 `man`。

---

## 2. `man` 命令与手册页（man pages）

`man`（manual 的缩写）是 Linux 系统最核心的文档系统，几乎所有的命令、系统调用（system call）、库函数（library function）、配置文件格式都有对应的 man page。

### 2.1 基本用法

```bash
$ man ls
```

执行后会通过分页程序（pager，通常是 `less`）展示 `ls` 命令的完整手册页，通常包含以下几个标准部分（section）：

- **NAME** — 命令名称及一句话简介
- **SYNOPSIS** — 命令的语法格式
- **DESCRIPTION** — 详细描述
- **OPTIONS** — 各个选项的说明
- **EXAMPLES** — 使用示例（不是所有 man page 都有）
- **FILES** — 相关的配置文件
- **SEE ALSO** — 相关命令或文档
- **AUTHOR** / **BUGS** / **REPORTING BUGS** 等

在 `less` 分页界面中常用的导航键：

| 按键 | 作用 |
|---|---|
| `空格`（Space）/ `f` | 向下翻一页 |
| `b` | 向上翻一页 |
| `/关键词` | 向下搜索关键词 |
| `n` | 跳到下一个搜索结果 |
| `N` | 跳到上一个搜索结果 |
| `q` | 退出 man page |

### 2.2 man 的分卷（sections）

man page 按主题划分为多个卷（section），因为同一个名字可能在不同分类下都有文档。例如 `passwd` 既是一个命令，也是一个配置文件：

| Section | 内容 |
|---|---|
| 1 | 用户命令（User commands） |
| 2 | 系统调用（System calls） |
| 3 | 库函数（Library calls） |
| 4 | 特殊文件，如设备文件（Special files） |
| 5 | 文件格式与约定（File formats） |
| 6 | 游戏（Games） |
| 7 | 杂项，包括宏包与约定（Miscellaneous） |
| 8 | 系统管理命令（System administration commands） |

查看指定分卷的手册页，需要在命令前加上卷号：

```bash
$ man 5 passwd    # 查看 /etc/passwd 文件格式的说明
$ man 1 passwd    # 查看 passwd 命令本身的说明
```

如果不指定卷号，`man` 会按照内部预设顺序查找并显示第一个匹配的分卷。

### 2.3 `man -k`（等价于 `apropos`）

当你不记得确切的命令名，只知道大概的功能关键词时，可以使用 `man -k`（keyword search）在所有 man page 的 NAME 描述行中做关键词搜索：

```bash
$ man -k partition
fdisk (8)            - manipulate disk partition table
parted (8)           - a partition manipulation program
partprobe (8)         - inform the OS of partition table changes
...
```

`man -k` 等价于独立命令 `apropos`：

```bash
$ apropos partition
```

> 该功能依赖本地的 man page 索引数据库（`mandb` 生成），如果搜索无结果，可能需要以管理员权限运行 `mandb` 更新索引。

### 2.4 `whatis`

`whatis` 用于查询某个命令的一句话简介（即 man page 中的 NAME 一行），比 `man -k` 更精确，只匹配命令名而非全文关键词：

```bash
$ whatis ls
ls (1)               - list directory contents
```

`man -f` 与 `whatis` 效果相同。

---

## 3. `info` 系统

`info` 是 GNU 项目提供的另一套文档系统，通常比对应的 man page 内容更详细、结构更清晰（以超文本节点 node 的形式组织，可以在章节间跳转）。部分 GNU 工具（例如 `tar`、`grep`、`gcc`）的 info 文档比 man page 更完整。

```bash
$ info coreutils
$ info tar
```

`info` 界面内常用导航键：

| 按键 | 作用 |
|---|---|
| `Space` / `Backspace` | 向下 / 向上翻页 |
| `n` | 下一个节点（node） |
| `p` | 上一个节点（node） |
| `u` | 返回上一级（up） |
| `l` | 返回上一次访问的节点 |
| `/关键词` | 搜索 |
| `q` | 退出 |

对于某些命令，也可以直接查看其特定子命令的 info 文档，例如：

```bash
$ info ls
```

---

## 4. 系统本地文档：`/usr/share/doc`

除了 man 和 info，很多软件包在安装后会在 `/usr/share/doc/<package-name>/` 目录下放置额外的文档，通常包括：

- `README` — 一般性说明
- `CHANGELOG` 或 `changelog.gz` — 版本变更记录
- `INSTALL` — 安装说明
- 示例配置文件、许可证（`LICENSE`/`COPYING`）等

示例：

```bash
$ ls /usr/share/doc/bash/
AUTHORS  bashref.txt.gz  CHANGES.gz  COPYING  README  ...
```

由于这些文件很多是被 gzip 压缩的（`.gz` 后缀），可以用 `zcat` 或 `zless` 直接查看而无需先手动解压：

```bash
$ zless /usr/share/doc/bash/CHANGES.gz
```

---

## 小结

| 工具 | 特点 | 适用场景 |
|---|---|---|
| `command --help` | 简短、内建于命令本身 | 快速确认某个选项 |
| `man command` | 标准、结构化、覆盖面最广 | 系统学习命令用法 |
| `man -k` / `apropos` | 关键词全文搜索 | 不记得命令名，只知道功能 |
| `whatis` | 一句话简介 | 快速确认命令用途 |
| `info command` | 超文本、内容通常更详尽 | 深入学习 GNU 工具 |
| `/usr/share/doc` | 软件包附带的额外文档 | 查看 changelog、示例配置等 |

---

## Referencias

- LPI Learning Materials — Topic 2.2: Using the Command Line to Get Help: https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- GNU `man-db` 项目（man, whatis, apropos, mandb 手册）: https://www.gnu.org/software/man-db/
- GNU `info` / Texinfo 官方文档: https://www.gnu.org/software/texinfo/
- GNU Coreutils 手册（`ls`、`cp` 等命令的官方文档）: https://www.gnu.org/software/coreutils/manual/coreutils.html
- Linux man-pages 项目（内核与 glibc 相关 man page 的官方来源）: https://www.kernel.org/doc/man-pages/