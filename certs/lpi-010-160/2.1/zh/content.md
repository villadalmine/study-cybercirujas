# 2.1 Command Line Basics

## 概述

Linux 系统的核心交互方式之一就是 **command line**（命令行），通过 **shell**（一个命令解释器程序）来执行。在 Linux Essentials 考试中，最常见的 shell 是 **Bash**（Bourne Again SHell）。本章介绍如何组织和执行命令、如何使用 shell variables 和 environment variables、如何利用 command history 提高效率，以及如何正确使用 quoting 和 escaping 来控制字符串和特殊字符的解释方式。

## Shell 是什么

Shell 是一个程序，负责读取用户输入的命令、解析并执行它们，然后把结果显示给用户。当你打开一个终端窗口（terminal emulator）时，系统会启动一个 shell 进程，通常表现为一个 **prompt**（提示符），例如：

```
[student@localhost ~]$
```

这个提示符的格式由环境变量 `PS1` 控制。常见的 shell 除了 Bash，还有 `sh`、`dash`、`zsh`、`ksh` 等，但 Linux Essentials 考试主要聚焦于 Bash 的行为。

可以用以下命令确认当前使用的 shell：

```
$ echo $SHELL
/bin/bash
```

## 命令的基本结构

一条命令的一般格式是：

```
command [options] [arguments]
```

- **command**：要执行的程序或内建命令的名字
- **options**（选项）：通常以 `-`（短选项）或 `--`（长选项）开头，用于改变命令的行为
- **arguments**（参数）：命令操作的对象，比如文件名

示例：

```
$ ls -l /etc/passwd
-rw-r--r-- 1 root root 2894 Mar  3 09:12 /etc/passwd
```

这里 `ls` 是命令，`-l` 是选项（以长格式列出），`/etc/passwd` 是参数。

多个短选项通常可以合并书写：

```
$ ls -la
```

等价于：

```
$ ls -l -a
```

## Internal（内建）命令与 External（外部）命令

Shell 中的命令分为两类：

- **Builtin commands**（内建命令）：由 shell 自身实现，不是独立的可执行文件，例如 `cd`、`echo`、`exit`、`history`、`export`、`type`
- **External commands**（外部命令）：是磁盘上独立的可执行文件，比如 `/bin/ls`、`/usr/bin/grep`

使用 `type` 命令可以判断一个命令属于哪一种：

```
$ type cd
cd is a shell builtin

$ type ls
ls is /usr/bin/ls

$ type echo
echo is a shell builtin
```

如果一个命令名同时存在内建版本和外部版本（例如某些系统上的 `echo`），shell 默认会优先使用内建版本。

## 常用内建命令

### echo

`echo` 用于把文本输出到标准输出（stdout），常用于查看变量值或在脚本中打印提示信息。

```
$ echo Hello Linux Essentials
Hello Linux Essentials

$ echo $HOME
/home/student
```

### exit

`exit` 用于终止当前的 shell 会话，并可以指定一个退出状态码（exit status），0 表示成功，非 0 表示某种错误：

```
$ exit 0
```

在脚本或命令执行后，可以用特殊变量 `$?` 查看上一条命令的退出状态：

```
$ ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
$ echo $?
2
```

### history

`history` 显示当前 shell 会话中执行过的命令列表，每条命令前有一个编号：

```
$ history
  501  cd /var/log
  502  ls -l
  503  cat syslog
  504  history
```

历史记录默认保存在用户家目录下的 `~/.bash_history` 文件中，会话结束时写入磁盘。相关环境变量：

- `HISTSIZE`：内存中保留的历史命令条数
- `HISTFILESIZE`：历史文件中保存的最大条数

## 复用命令历史

Bash 提供了多种方式复用之前执行过的命令，提高效率：

| 用法 | 说明 |
|---|---|
| `!!` | 重新执行上一条命令 |
| `!n` | 执行历史记录中编号为 `n` 的命令 |
| `!string` | 执行最近一条以 `string` 开头的命令 |
| `Ctrl+R` | 反向搜索（reverse search）历史命令，输入关键字实时匹配 |
| `↑` / `↓` 箭头键 | 在历史命令中逐条前后翻阅 |

示例：

```
$ echo test
test
$ !!
echo test
test

$ !502
ls -l
```

## Shell Variables 与 Environment Variables

Shell 支持两种变量：

- **Shell variable**（shell 变量）：只在当前 shell 进程中有效，不会传递给子进程
- **Environment variable**（环境变量）：会被导出（export）到子进程，供其他程序读取

创建一个 shell 变量并赋值（等号两边不能有空格）：

```
$ MYVAR=hello
$ echo $MYVAR
hello
```

此时 `MYVAR` 只是 shell 变量。用 `export` 将其提升为环境变量，使其对子进程可见：

```
$ export MYVAR
```

也可以合并成一步：

```
$ export MYVAR=hello
```

### 查看变量

- `set`：列出当前 shell 中所有的变量（包括 shell 变量和环境变量）以及 shell functions
- `env` 或 `printenv`：只列出已导出的环境变量

```
$ env | grep MYVAR
MYVAR=hello
```

### 删除变量

```
$ unset MYVAR
$ echo $MYVAR

```

### 常见的预定义环境变量

| 变量 | 含义 |
|---|---|
| `HOME` | 当前用户的家目录 |
| `PATH` | shell 查找可执行文件的目录列表，用 `:` 分隔 |
| `USER` | 当前登录用户名 |
| `PWD` | 当前工作目录 |
| `PS1` | 主提示符（primary prompt）的显示格式 |

`PATH` 尤为重要：当输入一个外部命令时，shell 会依次在 `PATH` 中列出的目录里查找同名可执行文件。

```
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
```

## Quoting 与 Escaping

Shell 中有些字符具有特殊含义（如 `$`、`*`、`"`、`'`、空格等），如果想让它们被当作普通字符处理，需要用 quoting（引用）或 escaping（转义）。

### 单引号（Single Quotes）

单引号内的所有字符都会被当作字面量（literal），包括 `$` 和 `\`，不会做任何变量替换：

```
$ echo '价格是 $5'
价格是 $5
```

### 双引号（Double Quotes）

双引号会保留大部分特殊字符的字面含义，但仍然允许变量替换（variable expansion）和命令替换（command substitution）：

```
$ NAME=Alice
$ echo "Hello, $NAME"
Hello, Alice
```

### 反斜杠（Backslash Escaping）

反斜杠用于转义紧跟其后的单个字符，让它失去特殊含义：

```
$ echo 价格是 \$5
价格是 $5

$ echo 这是一个\ 空格
这是一个 空格
```

### 反引号与 `$()`：命令替换

两种写法都可以把一条命令的输出结果替换到另一条命令中，推荐使用更现代、可嵌套的 `$()` 语法：

```
$ echo "今天是 $(date +%Y-%m-%d)"
今天是 2026-07-12
```

## Compound Commands（复合命令）

Bash 允许用特殊符号把多条命令组合在一行中执行：

| 运算符 | 行为 |
|---|---|
| `;` | 顺序执行，不管前一条命令是否成功 |
| `&&` | 只有前一条命令**成功**（退出码为 0）才执行后一条 |
| `\|\|` | 只有前一条命令**失败**（退出码非 0）才执行后一条 |
| `\|` | 管道（pipe），把前一条命令的标准输出作为后一条命令的标准输入 |

示例：

```
$ mkdir testdir; cd testdir; pwd
/home/student/testdir

$ mkdir /root/forbidden && echo "创建成功"
mkdir: cannot create directory '/root/forbidden': Permission denied

$ ls /nonexistent || echo "目录不存在"
ls: cannot access '/nonexistent': No such file or directory
目录不存在
```

## 小结

- Command line 的基本形式是 `command [options] [arguments]`
- 用 `type` 区分 builtin 与 external 命令
- `echo`、`exit`、`history` 是常用内建命令，`$?` 记录上一条命令的退出状态
- `!!`、`!n`、`Ctrl+R` 可高效复用命令历史
- Shell variable 只在当前 shell 有效，用 `export` 使其成为对子进程可见的 environment variable；`set` 查看所有变量，`env` 只查看已导出的变量，`unset` 删除变量
- 单引号完全禁止替换，双引号允许变量替换但阻止大部分特殊字符，反斜杠转义单个字符
- `;`、`&&`、`||`、`|` 用于把多条命令组合成 compound command

## Referencias

- LPI Learning Materials — Topic 2.1 Command Line Basics: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash Manual — Shell Parameters (Variables): https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameters
- GNU Bash Manual — Quoting: https://www.gnu.org/software/bash/manual/bash.html#Quoting
- GNU Bash Manual — Lists of Commands (Compound Commands with `;`, `&&`, `||`): https://www.gnu.org/software/bash/manual/bash.html#Lists
- GNU Bash Manual — Bash History Facilities: https://www.gnu.org/software/bash/manual/bash.html#Bash-History-Facilities
- LPI Linux Essentials Exam Objectives v1.6: https://www.lpi.org/our-certifications/linux-essentials-overview