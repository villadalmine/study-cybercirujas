# 3.3 Turning Commands into a Script

## 什么是 Shell Script

Shell script（shell 脚本）是一个包含一系列 shell 命令的文本文件，按顺序执行，就像把你在命令行中逐条输入的命令保存起来，之后可以重复运行，而不用每次都手动敲一遍。脚本的核心价值在于自动化：将重复性任务、复杂的命令组合固化成一个文件，提高效率并减少出错。

在 Linux Essentials 的语境中，一个 shell script 通常是：

- 一个纯文本文件
- 包含一行或多行 shell 命令
- 第一行通常是 shebang（解释器声明）
- 拥有可执行权限后可以像普通程序一样运行

## Shebang（`#!`）

脚本的第一行通常以 `#!` 开头，后面跟解释器的绝对路径，这被称为 shebang（也叫 hashbang）。它告诉内核用哪个程序来解释执行这个文件。

```bash
#!/bin/bash
```

也可能看到：

```bash
#!/bin/sh
#!/usr/bin/env bash
```

`#!/usr/bin/env bash` 的优点是会在 `PATH` 中查找 `bash`，而不是写死路径，可移植性更好。如果脚本没有 shebang，用 `./script.sh` 直接执行时，系统会尝试用当前 shell（通常是 `/bin/sh`）来解释，这可能导致语法不兼容的问题。

## 创建脚本

用任意文本编辑器（如 `nano`、`vi`）创建脚本文件：

```bash
$ nano hello.sh
```

写入内容：

```bash
#!/bin/bash
# 这是注释：打印问候语
echo "Hello, Linux Essentials!"
```

以 `#` 开头（除了 shebang 那一行）的内容是注释，shell 会忽略它，注释用于解释脚本逻辑，方便日后维护。

## 赋予可执行权限并运行

新建的脚本默认没有执行权限，需要用 `chmod` 添加：

```bash
$ ls -l hello.sh
-rw-r--r-- 1 user user 58 Jul 12 10:00 hello.sh

$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 user user 58 Jul 12 10:00 hello.sh
```

运行脚本有几种方式：

```bash
$ ./hello.sh
Hello, Linux Essentials!
```

`./` 表示在当前目录下查找该文件，因为出于安全考虑，当前目录通常不在 `PATH` 中。

也可以不加执行权限，直接把脚本作为参数传给解释器：

```bash
$ bash hello.sh
Hello, Linux Essentials!
```

还可以用 `source`（或简写 `.`）在**当前 shell**中执行脚本，而不是开启一个子 shell：

```bash
$ source hello.sh
Hello, Linux Essentials!
```

`source`/`.` 常用于加载环境变量或函数定义（例如 `.bashrc`），因为这样设置的变量会保留在当前 shell 会话中；而 `./hello.sh` 或 `bash hello.sh` 是在子 shell 中运行，脚本执行完毕后子 shell 中设置的变量不会影响父 shell。

## 变量

Shell 脚本中可以定义和使用变量，赋值时等号两边不能有空格：

```bash
#!/bin/bash
NAME="World"
echo "Hello, $NAME!"
```

```bash
$ ./greet.sh
Hello, World!
```

也可以把命令的输出赋给变量（command substitution）：

```bash
TODAY=$(date +%Y-%m-%d)
echo "Today is $TODAY"
```

## 位置参数（Positional Parameters）

脚本可以像命令一样接收参数，脚本内部通过特殊变量访问它们：

| 变量 | 含义 |
|------|------|
| `$0` | 脚本自身的名字/路径 |
| `$1`, `$2`, ... | 第 1、2 个位置参数，`${10}` 用于第 10 个及以后（需要花括号） |
| `$#` | 参数的个数 |
| `$@` | 所有参数，各自作为独立字符串（推荐在循环中使用） |
| `$*` | 所有参数合并为一个字符串 |
| `$?` | 上一条命令的退出状态码（exit status） |
| `$$` | 当前 shell 的 PID |

示例：

```bash
#!/bin/bash
echo "Script name: $0"
echo "First argument: $1"
echo "All arguments: $@"
echo "Number of arguments: $#"
```

```bash
$ ./args.sh foo bar baz
Script name: ./args.sh
First argument: foo
All arguments: foo bar baz
Number of arguments: 3
```

## 退出状态（Exit Status）

每条命令执行结束后都会返回一个退出状态码，`0` 表示成功，非 `0` 表示失败，可以用 `$?` 查看：

```bash
$ ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
$ echo $?
2
```

脚本可以用 `exit N` 显式指定自己的退出状态，供调用者（比如另一个脚本或 CI 流程）判断成功与否：

```bash
#!/bin/bash
if [ -f /etc/hostname ]; then
    echo "File exists"
    exit 0
else
    echo "File not found"
    exit 1
fi
```

## 从 `read` 获取交互式输入

`read` 可以从标准输入读取用户输入并保存到变量：

```bash
#!/bin/bash
echo -n "Enter your name: "
read NAME
echo "Hello, $NAME!"
```

```bash
$ ./ask.sh
Enter your name: Ana
Hello, Ana!
```

## 条件判断：`if` 与 `test`

`test` 命令（等价于 `[ ]`）用于判断条件，常与 `if` 搭配：

```bash
#!/bin/bash
if [ -d /tmp ]; then
    echo "/tmp is a directory"
fi

if [ "$1" = "start" ]; then
    echo "Starting..."
elif [ "$1" = "stop" ]; then
    echo "Stopping..."
else
    echo "Usage: $0 {start|stop}"
fi
```

```bash
$ ./service.sh start
Starting...
```

## 循环：`for` 与 `while`

`for` 循环常用于遍历一组值：

```bash
#!/bin/bash
for i in 1 2 3 4 5; do
    echo "Number: $i"
done
```

结合 `seq` 生成序列：

```bash
for i in $(seq 1 5); do
    echo "Count: $i"
done
```

`while` 循环在条件为真时持续执行：

```bash
#!/bin/bash
COUNT=1
while [ $COUNT -le 3 ]; do
    echo "Iteration $COUNT"
    COUNT=$((COUNT + 1))
done
```

```bash
$ ./loop.sh
Iteration 1
Iteration 2
Iteration 3
```

## 综合示例

把上述元素组合成一个实用的小脚本，用于备份指定目录：

```bash
#!/bin/bash
# backup.sh -- 简单的目录打包备份脚本
# 用法: ./backup.sh <目录>

if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

SRC="$1"
DATE=$(date +%Y%m%d)
DEST="${SRC%/}_backup_${DATE}.tar.gz"

if [ ! -d "$SRC" ]; then
    echo "Error: $SRC is not a directory"
    exit 1
fi

tar -czf "$DEST" "$SRC"
echo "Backup created: $DEST"
exit 0
```

```bash
$ ./backup.sh /home/user/docs
Backup created: /home/user/docs_backup_20260712.tar.gz
```

## 最佳实践

- 始终在第一行写清楚 shebang（`#!/bin/bash`）。
- 用 `chmod +x` 赋予执行权限，而不是每次都用 `bash script.sh` 调用。
- 给脚本文件起有意义的名字，通常以 `.sh` 结尾（非强制，但有助于识别）。
- 用注释（`#`）说明脚本用途和关键步骤，尤其是复杂逻辑。
- 处理用户输入和参数前先做基本检查（如 `$#` 是否符合预期），避免脚本在缺少参数时报错退出。
- 用 `exit` 明确返回状态码，方便脚本被其他脚本或自动化流程调用时判断成功/失败。

## 参考文献

- [LPI Learning Materials — 010-160, Topic 3.3: Turning Commands into a Script](https://learning.lpi.org/en/learning-materials/010-160/3/3.3/)
- [GNU Bash Reference Manual](https://www.gnu.org/software/bash/manual/bash.html)
- [GNU Coreutils Manual (seq, test, etc.)](https://www.gnu.org/software/coreutils/manual/coreutils.html)