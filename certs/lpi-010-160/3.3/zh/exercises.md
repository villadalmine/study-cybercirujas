# LPI Linux Essentials (010-160, v1.6) — Topic 3.3: Turning Commands into a Script

> 参考来源：https://learning.lpi.org/en/learning-materials/010-160/3/3.3/ （仅作背景参考，以下内容为原创讲解）

## 练习一：写出你的第一个 script

一个 shell script 只是把一系列你原本会在命令行里逐条敲的命令，按顺序写进一个文本文件里，让 shell 一次性依次执行它们。

**步骤：**

1. 用文本编辑器创建一个新文件：

   ```bash
   nano hello.sh
   ```

2. 在文件的第一行写下 **shebang**（也叫 hashbang），告诉系统用哪个解释器来执行这个文件：

   ```bash
   #!/bin/bash
   ```

3. 在 shebang 之后添加几条普通命令，就像你在终端里输入的一样：

   ```bash
   #!/bin/bash
   echo "当前用户: $USER"
   echo "当前目录: $(pwd)"
   date
   ```

4. 保存文件并退出编辑器。

**理解检查：**

1. shebang 行 `#!/bin/bash` 必须写在文件的第几行？如果不写这一行，用 `sh hello.sh` 执行还会不会成功？
2. 如果把 shebang 改成 `#!/bin/sh`，会对脚本的执行产生什么影响？

---

## 练习二：赋予执行权限并运行 script

刚创建的文本文件默认没有 execute 权限，不能像一个真正的程序那样被直接调用。

**步骤：**

1. 查看当前文件权限：

   ```bash
   ls -l hello.sh
   ```

2. 使用 `chmod` 添加 execute 权限（仅给文件属主）：

   ```bash
   chmod u+x hello.sh
   ```

3. 再次确认权限已生效：

   ```bash
   ls -l hello.sh
   ```

4. 使用相对路径运行脚本（必须带上 `./`）：

   ```bash
   ./hello.sh
   ```

5. 对比另外两种不修改权限也能执行脚本的方式：

   ```bash
   bash hello.sh
   sh hello.sh
   ```

**理解检查：**

1. 为什么直接输入 `hello.sh`（不加 `./`）通常会得到 "command not found"？这跟 `$PATH` 变量有什么关系？
2. 用 `bash hello.sh` 执行脚本时，脚本本身的 execute 权限（`x` bit）是否是必需的？为什么？

---

## 练习三：在 script 中使用变量与位置参数（positional parameters）

Script 可以像普通 shell 一样定义变量，也可以读取运行时传入的参数。

**步骤：**

1. 创建新脚本 `greet.sh`：

   ```bash
   nano greet.sh
   ```

2. 写入以下内容：

   ```bash
   #!/bin/bash
   NAME=$1
   echo "你好, $NAME！"
   echo "脚本名: $0"
   echo "参数个数: $#"
   echo "所有参数: $@"
   ```

3. 添加执行权限并运行，带上一个参数：

   ```bash
   chmod +x greet.sh
   ./greet.sh Alice
   ```

4. 再次运行，这次带上多个参数：

   ```bash
   ./greet.sh Alice Bob Carol
   ```

**理解检查：**

1. 在 `./greet.sh Alice Bob Carol` 这次调用中，`$1`、`$#` 和 `$@` 各自的值分别是什么？
2. 变量名 `NAME=$1` 中，等号两边为什么不能有空格？如果写成 `NAME = $1` 会发生什么？

---

## 练习四：command substitution 与算术运算

Command substitution 允许把一条命令的输出直接嵌入到另一条命令或变量赋值中。

**步骤：**

1. 创建脚本 `sysinfo.sh`：

   ```bash
   nano sysinfo.sh
   ```

2. 写入以下内容，使用 `$( )` 语法做 command substitution：

   ```bash
   #!/bin/bash
   FILECOUNT=$(ls | wc -l)
   echo "当前目录共有 $FILECOUNT 个条目"

   TOTAL=$((FILECOUNT + 1))
   echo "加一之后: $TOTAL"
   ```

3. 添加权限并运行：

   ```bash
   chmod +x sysinfo.sh
   ./sysinfo.sh
   ```

4. 尝试用反引号（backtick）写法替换 `$( )`，比较两者：

   ```bash
   FILECOUNT=`ls | wc -l`
   ```

**理解检查：**

1. `$(( ))` 和 `$( )` 分别用于什么场景？两者能互换吗？
2. 为什么现代 shell script 推荐使用 `$( )` 而不是反引号来做 command substitution？（提示：考虑嵌套的情况）

---

## 练习五：exit status 与条件判断

每条命令执行完毕后都会返回一个 exit status（保存在特殊变量 `$?` 中），`0` 表示成功，非零表示失败。Script 可以用 `if` 结构根据这个状态做出不同反应。

**步骤：**

1. 在终端里先直接体验 `$?`：

   ```bash
   ls /etc
   echo $?
   ls /not_a_real_dir
   echo $?
   ```

2. 创建脚本 `checkdir.sh`：

   ```bash
   nano checkdir.sh
   ```

3. 写入以下内容：

   ```bash
   #!/bin/bash
   DIR=$1
   if [ -d "$DIR" ]; then
       echo "$DIR 存在，是一个目录"
   else
       echo "$DIR 不存在或不是目录"
   fi
   ```

4. 添加权限并分别用存在和不存在的路径测试：

   ```bash
   chmod +x checkdir.sh
   ./checkdir.sh /etc
   ./checkdir.sh /nope
   ```

**理解检查：**

1. `$?` 的值是在什么时刻确定的？如果在 `ls /etc` 和 `echo $?` 之间又插入了另一条命令，`$?` 还会是 `ls` 的返回值吗？
2. `[ -d "$DIR" ]` 这个测试表达式中，把 `$DIR` 加上双引号的作用是什么？如果 `$DIR` 的值中包含空格，去掉双引号会出现什么问题？

---

## 练习六：综合练习——把命令整理成一个可复用的 script

**步骤：**

1. 创建脚本 `backup_note.sh`：

   ```bash
   nano backup_note.sh
   ```

2. 综合前面学到的所有元素（shebang、注释、变量、command substitution、条件判断）：

   ```bash
   #!/bin/bash
   # 简单备份脚本：把指定文件复制一份并加上时间戳

   SRC=$1

   if [ -z "$SRC" ]; then
       echo "用法: $0 <文件路径>"
       exit 1
   fi

   if [ ! -f "$SRC" ]; then
       echo "错误: 文件 $SRC 不存在"
       exit 1
   fi

   TIMESTAMP=$(date +%Y%m%d_%H%M%S)
   cp "$SRC" "${SRC}.${TIMESTAMP}.bak"
   echo "已备份为: ${SRC}.${TIMESTAMP}.bak"
   ```

3. 添加执行权限：

   ```bash
   chmod +x backup_note.sh
   ```

4. 分别测试三种情况：不带参数、传入一个不存在的文件、传入一个真实存在的文件。

   ```bash
   ./backup_note.sh
   ./backup_note.sh /tmp/not_here.txt
   ./backup_note.sh hello.sh
   ```

5. 每次运行后立即检查 exit status：

   ```bash
   echo $?
   ```

**理解检查：**

1. 脚本中出现了两处 `exit 1`，它们分别对应哪两种错误场景？为什么用 `1` 而不是 `0`？
2. `[ -z "$SRC" ]` 判断的是什么条件？如果用户执行 `./backup_note.sh ""`（传入一个空字符串参数），`$SRC` 是否为空？这个判断会得到什么结果？
3. 为什么要在脚本开头写 `# 简单备份脚本...` 这样的注释？shell 是如何识别并跳过注释行的？

---

<details>
<summary>点击查看参考答案</summary>

**练习一**

1. shebang 必须是文件的第一行第一个字符开始（`#!` 前不能有空行或空格）。如果省略这一行，用 `sh hello.sh` 执行仍然会成功——因为这时你是显式告诉 shell 用哪个解释器来读这个文件，脚本内部的 shebang 只在通过 `./hello.sh` 这种"直接执行"方式调用时才会被内核用来决定解释器。
2. `/bin/sh` 在多数发行版中是 `/bin/bash` 的符号链接或一个更精简、更贴近 POSIX 标准的 shell（如 dash）。用 `/bin/sh` 运行脚本可能导致 bash 特有的语法（如某些数组、`[[ ]]`）无法使用。

**练习二**

1. 因为 shell 只会在 `$PATH` 列出的目录中查找可执行文件名，而当前目录 `.` 出于安全考虑通常不在 `$PATH` 中，所以必须用 `./hello.sh` 显式指定路径。
2. 不是必需的。因为 `bash hello.sh` 是把 `hello.sh` 作为参数传给 `bash` 解释器去读取和执行，本质上是"读文件内容"而不是"把文件当作程序调用"，所以不需要文件本身具有 execute 权限，只需要 read 权限。

**练习三**

1. `$1` 是 `Alice`；`$#` 是 `3`（参数总数）；`$@` 是 `Alice Bob Carol`（全部参数展开）。
2. Bash 中赋值语句要求变量名、等号、值之间没有空格，因为一旦出现空格，bash 会把 `NAME` 解析成一个独立的命令（尝试去执行名为 `NAME` 的程序），把 `=` 和 `$1` 当作它的参数，从而导致 "command not found" 之类的报错。

**练习四**

1. `$(( ))` 用于整数算术运算（加减乘除等），`$( )` 用于 command substitution（捕获命令的标准输出）。两者语法相似但用途不同，不能互换：把一个命令放进 `$(( ))` 不会执行它，而是尝试把它当算术表达式解析，通常会报错。
2. `$( )` 支持嵌套（`$(cmd1 $(cmd2))`）且更易读；反引号嵌套时需要用反斜杠转义内层的反引号，容易出错，可读性也差，所以现代脚本风格普遍推荐 `$( )`。

**练习五**

1. `$?` 保存的是"最近一条前台命令"的退出状态，一旦执行了新的命令（哪怕只是另一次 `echo`），`$?` 就会被覆盖为那条新命令的返回值。所以必须紧跟在要检查的命令之后立即读取。
2. 双引号防止 word splitting（单词分割）和路径名扩展（globbing）。如果 `$DIR` 的值里有空格且不加引号，`[ -d $DIR ]` 会被 shell 拆分成多个参数传给 `[`（也就是 `test` 命令），导致 "too many arguments" 之类的错误或判断结果不正确。

**练习六**

1. 第一个 `exit 1` 对应"未提供任何参数"（`$SRC` 为空）；第二个 `exit 1` 对应"提供的文件路径不存在"。用非零值（这里选 `1`）是 Unix 惯例：`0` 表示成功，任何非零值都表示某种失败，调用者（比如另一个脚本或 `&&`/`||` 链）可以据此判断这次执行是否出错。
2. `[ -z "$SRC" ]` 判断字符串长度是否为零（即变量是否为空）。执行 `./backup_note.sh ""` 时，`$1` 被赋值为空字符串，所以 `$SRC` 确实为空，`-z` 判断为真，脚本会打印用法提示并以 `exit 1` 退出——和完全不传参数的效果一致。
3. 注释帮助阅读者（包括未来的自己）快速理解脚本用途，而不影响执行，因为 shell 在解析每一行时，只要遇到不在引号内的 `#` 字符，就会忽略从该字符到行尾的全部内容，不会把它当作命令处理。

</details>