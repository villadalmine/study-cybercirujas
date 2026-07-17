# LPI Linux Essentials (010-160, v1.6) — 主题 2.2:Using the Command Line to Get Help

> 参考来源:LPI Learning Materials, https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
> 考试权重:2

---

## 练习 1:用 man 查阅命令手册

1. 打开终端,运行:
   ```bash
   man ls
   ```
   进入 `ls` 命令的 man page。
2. 使用空格键(Space)或 `f` 向下翻页,使用 `b` 向上翻页。
3. 按 `/`,输入 `SIZE`,回车,在页面内向前(forward)搜索该关键字;按 `n` 跳到下一个匹配,按 `N` 跳到上一个匹配(反方向)。
4. 按 `q` 退出 man page,回到 shell 提示符。
5. 运行:
   ```bash
   man man
   ```
   查看 man 命令自身的手册,留意其中的 `NAME`、`SYNOPSIS`、`DESCRIPTION` 等区段标题(section headings)。

**检查理解:**
- Q1:man page 里的 `SYNOPSIS` 区段起什么作用?
- Q2:在 man page 内搜索时,`n` 和 `N` 分别做什么?

---

## 练习 2:man 的 sections 与同名歧义

1. 运行:
   ```bash
   man passwd
   ```
   注意页面左上角显示 `PASSWD(1)`,数字 `1` 表示这是 section 1(user commands,可执行命令)的手册。
2. 再运行:
   ```bash
   man 5 passwd
   ```
   这次显示 `PASSWD(5)`,section 5 记录的是文件格式(file formats),说明的是 `/etc/passwd` 文件里各字段的含义,而不是 `passwd` 命令本身。
3. 若发行版支持,运行:
   ```bash
   man -a passwd
   ```
   会依次显示同名的所有 section,按 `q` 退出当前页即可进入下一个 section。
4. 分别运行 `man 1 intro` 和 `man 7 man`,对比 section 1 的概述页与 section 7(miscellaneous,杂项与约定说明)的内容差异。

**检查理解:**
- Q3:为什么同一个名字(如 `passwd`)会对应多个 man page?如何指定查看某个特定 section?
- Q4:section 5 一般用来记录哪类内容?

---

## 练习 3:apropos 与 whatis — 按关键字搜索命令

1. 运行:
   ```bash
   whatis passwd
   ```
   查看该命令的一行简介(one-line description),并留意可能同时列出多个 section。
2. 运行:
   ```bash
   apropos partition
   ```
   在手册摘要数据库中搜索所有包含 "partition" 关键字的条目,这等价于:
   ```bash
   man -k partition
   ```
3. 如果输出提示 `nothing appropriate` 或结果为空,以 root 权限运行:
   ```bash
   mandb
   ```
   (较旧系统上可能是 `makewhatis`)重建索引数据库后再重试。
4. 运行 `man partition` 验证该名字是否真的存在独立的手册页,对比 apropos 搜到的结果里哪些是可以直接执行的命令。

**检查理解:**
- Q5:apropos 与 whatis 在搜索范围上的核心区别是什么?
- Q6:为什么 apropos 有时会返回 "nothing appropriate",应该怎样解决?

---

## 练习 4:--help 选项快速查看用法

1. 运行:
   ```bash
   ls --help
   ```
   查看其支持的选项列表和简要用法(usage syntax),对比 `man ls` 的详细程度。
2. 运行:
   ```bash
   mkdir --help
   ```
   留意输出中的 `Usage:` 一行,它展示了命令的语法结构(参数位置、方括号表示可选项等)。
3. 运行:
   ```bash
   grep --help | less
   ```
   把较长的输出通过管道交给 `less` 分页查看。
4. 思考:并非所有命令的 `-h` 都代表 "help"。例如 `ls -h` 表示以人类可读的单位显示文件大小(human-readable),而不是显示帮助信息。

**检查理解:**
- Q7:`--help` 输出相比 man page,通常缺少哪些内容?
- Q8:为什么不能假设所有命令的 `-h` 都表示 "help"?

---

## 练习 5:info 手册与 /usr/share/doc

1. 运行:
   ```bash
   info coreutils
   ```
   或
   ```bash
   info ls
   ```
   进入基于节点(node-based)的超文本文档系统。
2. 使用方向键在条目间移动,按 `Enter` 跟随菜单项(menu entry)进入子节点,按 `u` 返回上一级(up),按 `l` 回到刚才访问过的节点(last)。
3. 按 `q` 退出 info 阅读器。
4. 运行:
   ```bash
   ls /usr/share/doc/
   ```
   浏览已安装软件包自带的文档目录。
5. 进入某个具体包的目录,例如:
   ```bash
   ls /usr/share/doc/bash/
   ```
   查看是否存在 `README`、`CHANGELOG.gz` 等文件。
6. 对于以 `.gz` 结尾的压缩文档,运行:
   ```bash
   zless CHANGELOG.gz
   ```
   (或 `zcat CHANGELOG.gz | less`)直接查看内容,无需先手动解压。

**检查理解:**
- Q9:info 文档的组织结构和 man page 相比有什么不同?
- Q10:若 `/usr/share/doc` 里的文件以 `.gz` 结尾,应该怎样查看而不用先解压?

---

<details>
<summary>参考答案(点击展开)</summary>

**Q1.** `SYNOPSIS` 区段用简洁的语法格式列出命令支持的选项与参数结构(例如 `ls [OPTION]... [FILE]...`),帮助用户快速了解调用方式,不必阅读完整的 `DESCRIPTION`。

**Q2.** `n` 沿着当前搜索方向跳到下一个匹配项;`N` 跳到上一个匹配项,即反方向查找,两者互为相反操作。

**Q3.** 因为 man page 按内容类型划分为不同的 section(如 1 = user commands,5 = file formats,8 = system administration commands 等),同一个名字可能在多个 section 都有含义不同的页面。查看指定 section 时,在 `man` 后加上对应数字,例如 `man 5 passwd`。

**Q4.** section 5 记录的是文件格式与约定(file formats and conventions),例如配置文件里各字段的含义,而不是可执行程序的用法。

**Q5.** `whatis` 只在手册的 `NAME` 一行做精确的整词匹配(exact match),仅返回同名命令的简介;`apropos`(等价于 `man -k`)在整个摘要/描述文本中做关键字的模糊匹配,因此能找到名字里不含该词、但功能相关的命令。

**Q6.** 这通常是因为本地的 whatis 索引数据库(mandb database)尚未建立或已经过期,新安装的手册页还没被收录进索引。以 root 权限运行 `mandb` 重新生成索引即可解决。

**Q7.** `--help` 通常只输出选项列表与简短用法说明,缺少 man page 里的详细描述(`DESCRIPTION`)、使用示例(`EXAMPLES`)、相关命令(`SEE ALSO`)、退出状态(`EXIT STATUS`)等背景信息。

**Q8.** 因为 `-h` 是单字符短选项,不同命令可以自行定义其含义,例如 `ls -h` 表示以人类可读的单位显示文件大小(human-readable),而不是显示帮助。是否支持 `--help` 或把 `-h` 用作帮助选项,取决于具体命令的实现,不能一概而论。

**Q9.** man page 每条命令是一篇相对独立、扁平的文档;info 文档则组织成有层级关系的节点(nodes),节点之间通过菜单(menu)以及上一级/下一级链接(up / next / previous)相互跳转,更适合长篇、结构化的说明书。

**Q10.** 可以用支持读取 gzip 压缩内容的工具直接查看,例如 `zless CHANGELOG.gz` 或 `zcat CHANGELOG.gz | less`,无需先用 `gunzip` 解压出普通文件。

</details>