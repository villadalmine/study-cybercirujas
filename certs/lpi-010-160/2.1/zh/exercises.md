# 2.1 Command Line Basics — 引导式练习

> 参考资料 / Reference:
> - https://learning.lpi.org/en/learning-materials/010-160/2/2.1/

## 练习 1：Shell 与命令语法（Command Syntax）

1. 打开一个 terminal，观察当前的 shell 提示符（prompt），通常以 `$`（普通用户）或 `#`（root 用户）结尾。
2. 输入以下命令并按 Enter 执行，查看当前登录的用户名：
   ```bash
   whoami
   ```
3. 输入以下命令，查看当前使用的 shell 程序：
   ```bash
   echo $SHELL
   ```
4. 输入一个带有 option（选项）和 argument（参数）的命令：
   ```bash
   ls -l /etc
   ```
   这里 `ls` 是 command（命令），`-l` 是 option，`/etc` 是 argument。
5. 尝试只输入 command 本身，不带任何 option 或 argument：
   ```bash
   ls
   ```
   对比输出结果与上一步的区别。

**理解检查问题：**
- Linux 命令的基本语法结构是什么？请用一句话描述 command、option、argument 三者的关系。
- `ls -l` 和 `ls -l /etc` 这两条命令的 argument 有什么不同？

## 练习 2：Quoting（引号与转义）

1. 定义一个包含空格的字符串并直接 echo，不使用任何引号：
   ```bash
   echo Hello   World
   ```
   观察多个空格是否被保留。
2. 使用双引号（double quote）包裹同样的内容：
   ```bash
   echo "Hello   World"
   ```
   对比输出结果。
3. 创建一个环境变量并分别用单引号和双引号输出：
   ```bash
   MYVAR=teach-plat
   echo "MYVAR is $MYVAR"
   echo 'MYVAR is $MYVAR'
   ```
4. 使用反斜杠（backslash）转义（escape）一个 `$` 符号，使其不被 shell 当作变量引用：
   ```bash
   echo \$MYVAR
   ```

**理解检查问题：**
- 在 double quote 中，变量（variable）是否会被展开（expand）？在 single quote 中呢？
- 反斜杠 `\` 在 shell 中的作用是什么，与 single quote 的效果有何相似之处？

## 练习 3：Environment Variables（环境变量）

1. 查看当前所有已导出的 environment variable：
   ```bash
   env
   ```
   或者：
   ```bash
   printenv
   ```
2. 查看单个变量的值，例如 `$HOME`：
   ```bash
   echo $HOME
   ```
3. 在当前 shell 中定义一个 shell variable（局部变量，尚未导出）：
   ```bash
   COURSE=lpi-linux-essentials
   echo $COURSE
   ```
4. 使用 `export` 命令把它变为 environment variable，使其能传递给子进程（child process）：
   ```bash
   export COURSE
   bash -c 'echo $COURSE'
   ```
5. 删除该变量：
   ```bash
   unset COURSE
   echo $COURSE
   ```

**理解检查问题：**
- shell variable 和 environment variable 之间最主要的区别是什么？
- 执行 `unset COURSE` 之后，再执行 `echo $COURSE` 会输出什么？为什么？

## 练习 4：PATH 与命令查找

1. 查看当前的 `$PATH` 变量：
   ```bash
   echo $PATH
   ```
   观察其中以冒号（`:`）分隔的多个目录。
2. 使用 `which` 命令查看某个命令实际所在的位置：
   ```bash
   which ls
   which bash
   ```
3. 尝试查找一个不存在的命令：
   ```bash
   which foobarbaz
   ```
   观察输出或返回的 exit status。
4. 使用绝对路径（absolute path）直接执行同一个命令，不依赖 `$PATH`：
   ```bash
   /bin/ls
   ```

**理解检查问题：**
- `$PATH` 变量的作用是什么？shell 是如何利用它来查找命令的？
- 如果两个不同目录下都有同名的可执行文件，shell 会优先执行哪一个，依据是什么？

## 练习 5：Command History（命令历史）

1. 依次执行几条不同的命令，例如：
   ```bash
   pwd
   whoami
   echo test
   ```
2. 查看历史命令列表：
   ```bash
   history
   ```
3. 使用 `!!` 重新执行上一条命令：
   ```bash
   !!
   ```
4. 使用 `!n`（`n` 为 history 列表中的编号）重新执行某条指定的历史命令，例如：
   ```bash
   !1
   ```
5. 使用向上/向下箭头键（arrow key）在历史记录中来回浏览。

**理解检查问题：**
- `!!` 和 `!n` 分别代表什么含义？
- history 记录默认保存在哪个文件中（提示：与 `$HISTFILE` 变量相关）？

## 练习 6：命令行编辑与自动补全（Command Line Editing & Tab Completion）

1. 输入部分命令名，然后按 Tab 键，观察自动补全（completion）效果：
   ```bash
   ech<Tab>
   ```
2. 输入部分文件路径后按 Tab 键，例如：
   ```bash
   cd /et<Tab>
   ```
3. 使用 `Ctrl+R` 进入 reverse-i-search 模式，搜索之前执行过的包含 "echo" 的命令，输入：
   ```
   echo
   ```
   然后观察终端提示的匹配结果。
4. 使用 `Ctrl+A` 将光标移到当前行开头，`Ctrl+E` 移到行尾，练习无需删除整行即可编辑已输入的命令。

**理解检查问题：**
- Tab 补全在只有唯一匹配结果和存在多个匹配结果时，行为分别是什么？
- `Ctrl+R` 的作用是什么，它与直接使用 `history` 命令查找相比有什么优势？

---

<details>
<summary>点击查看答案 / Click to expand answers</summary>

**练习 1**
- Linux 命令的基本语法是 `command [options] [arguments]`：command 指定要执行的程序，option（通常以 `-` 或 `--` 开头）用来改变命令的行为，argument 是命令操作的对象（如文件或目录）。
- `ls -l` 没有指定 argument，默认对当前目录（current directory）执行；`ls -l /etc` 的 argument 是 `/etc`，因此只列出该目录下的内容。

**练习 2**
- 在 double quote 中，`$VAR` 形式的变量会被展开为其值；在 single quote 中，所有字符（包括 `$`）都会被当作字面量（literal），不会被展开。
- 反斜杠会转义紧跟其后的单个字符，使 shell 将其当作普通字符处理而非特殊字符；这一点与 single quote 屏蔽变量展开的效果类似，但 backslash 只作用于紧邻的一个字符，而 single quote 作用于其包裹的整段内容。

**练习 3**
- shell variable 只在当前 shell 进程内有效，不会传递给子进程；environment variable 是通过 `export` 标记后，会被复制到所有由当前 shell 启动的 child process 的环境中。
- `unset COURSE` 后再执行 `echo $COURSE` 会输出空行，因为该变量已被删除，不再存在。

**练习 4**
- `$PATH` 是一个以冒号分隔的目录列表；当用户输入一个不含路径的命令名时，shell 会按顺序在这些目录中查找同名的可执行文件（executable）。
- shell 会执行在 `$PATH` 中排在最前面的那个目录下找到的可执行文件，即按 `$PATH` 中目录的先后顺序进行匹配。

**练习 5**
- `!!` 表示重新执行上一条命令；`!n` 表示重新执行 history 列表中编号为 `n` 的那条命令。
- history 记录默认保存在用户家目录下的 `~/.bash_history` 文件中（具体文件名由 `$HISTFILE` 变量决定，bash 默认值为 `.bash_history`）。

**练习 6**
- 只有唯一匹配时，Tab 补全会直接补全剩余部分；存在多个匹配时，第一次按 Tab 通常只会补全公共前缀，再次按 Tab 会列出所有可能的匹配项供选择。
- `Ctrl+R` 提供的是增量式（incremental）反向搜索，输入的字符越多匹配越精确，无需像浏览 `history` 输出那样手动查找编号，效率更高。

</details>