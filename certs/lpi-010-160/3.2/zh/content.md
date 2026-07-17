# 3.2 Searching and Extracting Data from Files

## 概述

在 Linux 中，命令行工具擅长处理文本流。本节介绍如何利用 **standard streams**（标准流）、**redirection**（重定向）、**pipes**（管道），以及 `grep`、`cut`、`sort`、`uniq`、`wc`、`tr`、`head`、`tail` 等命令，从文件或命令输出中查找、提取和转换数据。这是 Linux Essentials 考试中分量较重的实操型主题，也是日常运维、日志分析、脚本编写的基础技能。

---

## 一、标准流与重定向 (Standard Streams and Redirection)

每个 Linux 进程默认拥有三个 I/O 通道：

| 名称 | 文件描述符 (file descriptor) | 默认指向 |
|---|---|---|
| **stdin** (standard input) | 0 | 键盘输入 |
| **stdout** (standard output) | 1 | 终端屏幕 |
| **stderr** (standard error) | 2 | 终端屏幕 |

### 重定向操作符

```bash
command > file      # 将 stdout 覆盖写入 file
command >> file     # 将 stdout 追加写入 file
command < file      # 将 file 作为 stdin
command 2> file     # 将 stderr 重定向到 file
command 2>> file    # 将 stderr 追加重定向到 file
command &> file     # 将 stdout 和 stderr 都重定向到 file
command > file 2>&1 # 等价写法：先重定向 stdout，再让 stderr 指向 stdout 当前指向的位置
```

示例：

```bash
$ ls /etc /nonexist > out.log 2> err.log
$ cat out.log
/etc:
hostname
passwd
...
$ cat err.log
ls: cannot access '/nonexist': No such file or directory
```

### 管道 (pipe, `|`)

管道把前一个命令的 **stdout** 直接连接到下一个命令的 **stdin**，不经过磁盘文件：

```bash
command1 | command2 | command3
```

示例：统计 `/etc/passwd` 中以 `/bin/bash` 结尾的行数：

```bash
$ grep '/bin/bash$' /etc/passwd | wc -l
3
```

---

## 二、查看文件内容

### `cat` — 拼接并输出整个文件

```bash
$ cat file1.txt file2.txt
```

### `less` / `more` — 分页查看

`less` 支持前后翻页、搜索（`/pattern`）、按 `q` 退出，功能强于只能向前翻页的 `more`：

```bash
$ less /var/log/syslog
```

### `head` / `tail` — 查看文件首尾

```bash
$ head -n 5 access.log      # 显示前 5 行
$ tail -n 5 access.log      # 显示后 5 行
$ tail -f /var/log/syslog   # -f: 持续跟踪文件新增内容（follow），常用于实时看日志
```

---

## 三、使用 grep 搜索数据

`grep`（**g**lobal **r**egular **e**xpression **p**rint）用于在文件或输入流中按 pattern 查找匹配行。

### 基本语法

```bash
grep [OPTIONS] PATTERN [FILE...]
```

示例：

```bash
$ grep "root" /etc/passwd
root:x:0:0:root:/root:/bin/bash
```

### 常用选项

| 选项 | 作用 |
|---|---|
| `-i` | 忽略大小写 (ignore case) |
| `-v` | 反向匹配，输出不匹配的行 |
| `-r` / `-R` | 递归搜索目录 |
| `-n` | 显示匹配行的行号 |
| `-c` | 只输出匹配的行数 |
| `-l` | 只输出包含匹配内容的文件名 |
| `-w` | 匹配整个单词 |
| `-E` | 使用 extended regular expressions（等价于 `egrep`） |
| `-F` | 按字面字符串匹配，不解释为正则（等价于 `fgrep`） |

示例：

```bash
$ grep -in "error" app.log
14:Error: connection timeout
27:ERROR: disk full

$ grep -v "^#" /etc/ssh/sshd_config | grep -v "^$"
# 过滤掉注释行(以 # 开头)和空行
```

### regular expressions（正则表达式）基础

`grep` 默认使用 **basic regular expressions (BRE)**；加上 `-E`（或使用 `egrep`）启用 **extended regular expressions (ERE)**，语法更接近现代脚本语言。

常用元字符：

| 符号 | 含义 | 示例 |
|---|---|---|
| `.` | 匹配任意单个字符 | `gr.p` 匹配 `grep`、`grap` |
| `*` | 前一个字符出现 0 次或多次 | `ab*c` 匹配 `ac`、`abc`、`abbc` |
| `^` | 匹配行首 | `^root` |
| `$` | 匹配行尾 | `bash$` |
| `[]` | 字符集合 | `[0-9]` 匹配任意数字 |
| `[^]` | 排除集合 | `[^0-9]` 匹配非数字字符 |
| `\` | 转义特殊字符 | `\.` 匹配字面的点号 |
| `+` (ERE) | 前一字符 1 次或多次 | `grep -E "ab+c"` |
| `?` (ERE) | 前一字符 0 次或 1 次 | `grep -E "colou?r"` |
| `\|` (ERE) | 或 | `grep -E "cat\|dog"` |
| `()` (ERE) | 分组 | `grep -E "(ab)+"` |

示例：查找以数字开头的行

```bash
$ grep -E "^[0-9]+" data.txt
2024-01-01 系统启动
```

示例：查找 IP 地址格式的行（简化版）

```bash
$ grep -E "[0-9]{1,3}(\.[0-9]{1,3}){3}" access.log
192.168.1.10 - - [12/Jul/2026:10:00:01] "GET / HTTP/1.1" 200
```

> **注意**：`egrep` 和 `fgrep` 已被标记为过时（deprecated），推荐分别用 `grep -E` 和 `grep -F` 替代，但在考试和实际系统中两者仍常见。

---

## 四、提取与转换数据

### `cut` — 按列提取字段

```bash
$ cut -d: -f1,3 /etc/passwd | head -3
root:0
daemon:1
bin:2
```

- `-d` 指定分隔符 (delimiter)
- `-f` 指定要提取的字段 (field) 编号

按字符位置提取：

```bash
$ echo "HelloWorld" | cut -c1-5
Hello
```

### `sort` — 排序

```bash
$ sort names.txt              # 按字典序升序排序
$ sort -r names.txt           # 反向排序
$ sort -n numbers.txt         # 按数值排序
$ sort -k2 -t: /etc/passwd    # 按第 2 个字段（以 : 分隔）排序
$ sort -u names.txt           # 排序并去重（等价于 sort | uniq）
```

### `uniq` — 去除相邻重复行

`uniq` 只能去除**相邻**的重复行，因此通常先 `sort` 再 `uniq`：

```bash
$ cat visits.log | sort | uniq -c | sort -rn
  12 192.168.1.10
   5 192.168.1.20
   1 10.0.0.5
```

`-c` 显示每行出现的次数（count）。

### `wc` — 统计行数/词数/字节数

```bash
$ wc -l file.txt      # 行数 (lines)
$ wc -w file.txt      # 单词数 (words)
$ wc -c file.txt      # 字节数 (bytes)
```

### `tr` — 字符转换/删除

```bash
$ echo "Hello World" | tr 'a-z' 'A-Z'
HELLO WORLD

$ echo "a,b,c" | tr ',' '\n'
a
b
c

$ echo "foo   bar" | tr -s ' '   # -s: 压缩连续重复字符
foo bar
```

---

## 五、综合示例

统计某日志文件中出现次数最多的前 3 个访问 IP：

```bash
$ cut -d' ' -f1 access.log | sort | uniq -c | sort -rn | head -3
    120 192.168.1.10
     87 192.168.1.20
     43 10.0.0.5
```

查找 `/etc/passwd` 中所有 `UID`（第三字段）大于等于 1000 的普通用户名：

```bash
$ awk -F: '$3>=1000{print $1}' /etc/passwd
```

> `awk` 属于更高级的文本处理工具，不在本节 grep/cut/sort 核心范围内，但常与它们配合使用，考试大纲中会在其他主题涉及。

---

## 六、常见易混淆点

- `grep -v` 是取反匹配，不是删除文件内容。
- `>` 会**覆盖**目标文件，`>>` 才是追加；误用 `>` 会导致数据丢失。
- `uniq` 不会对整份文件去重，只处理相邻重复行，必须配合 `sort`。
- BRE 中 `+`、`?`、`|`、`()` 需要用反斜杠转义（如 `\+`）才有特殊含义；ERE（`grep -E`）中则不需要转义。
- `2>&1` 必须写在重定向的后面（`> file 2>&1`），否则 stderr 不会跟随 stdout 的新目标。

---

## 参考资料 References

- LPI Learning Materials — Topic 3.2: [https://learning.lpi.org/en/learning-materials/010-160/3/3.2/](https://learning.lpi.org/en/learning-materials/010-160/3/3.2/)
- GNU grep Manual: [https://www.gnu.org/software/grep/manual/grep.html](https://www.gnu.org/software/grep/manual/grep.html)
- GNU Coreutils Manual (cut, sort, uniq, wc, tr, head, tail): [https://www.gnu.org/software/coreutils/manual/coreutils.html](https://www.gnu.org/software/coreutils/manual/coreutils.html)
- Bash Reference Manual — Redirections: [https://www.gnu.org/software/bash/manual/html_node/Redirections.html](https://www.gnu.org/software/bash/manual/html_node/Redirections.html)