# LPI Linux Essentials (010-160 v1.6) — 3.2 Searching and Extracting Data from Files

> 参考来源（仅作背景参考，内容为原创编写）：
> https://learning.lpi.org/en/learning-materials/010-160/3/3.2/

本节考点权重为 **3**，核心内容包括使用 `grep`（及 `egrep`/`fgrep`）配合 regular expression 搜索文本、用 `cut`/`tr`/`sort`/`wc` 提取和整理数据、用 `sed` 做基本的查找替换（search and replace），以及用命令行工具追加（append）和查看数据。

以下练习假设你使用的是 Bash shell。

---

## 准备工作：创建实验环境

**Step 1.** 创建一个专用目录并进入：

```bash
mkdir -p ~/lab-3.2 && cd ~/lab-3.2
```

**Step 2.** 创建一个模拟的应用日志文件 `access.log`：

```bash
cat > access.log << 'EOF'
2026-07-01 10:12:33 INFO  user=alice action=login status=success
2026-07-01 10:13:02 WARN  user=bob action=login status=failed
2026-07-01 10:15:47 ERROR user=carol action=upload status=failed
2026-07-01 10:16:09 INFO  user=alice action=logout status=success
2026-07-01 10:20:58 ERROR user=dave action=login status=failed
2026-07-01 10:22:11 INFO  user=eve action=login status=success
2026-07-01 10:25:40 WARN  user=bob action=upload status=failed
2026-07-01 10:30:15 INFO  user=carol action=login status=success
EOF
```

**Step 3.** 创建一个 CSV 格式的学生成绩表 `students.csv`：

```bash
cat > students.csv << 'EOF'
name,city,score
Alice,Berlin,88
Bob,Tokyo,76
Carol,Paris,92
Dave,Berlin,65
Eve,Tokyo,81
Frank,Paris,58
EOF
```

**Step 4.** 用 `cat` 查看两个文件的内容，确认创建成功：

```bash
cat access.log
cat students.csv
```

> **检查理解**
> 1. `cat > file << 'EOF' ... EOF` 这种写法叫什么？它和 `echo "text" >> file` 相比，在追加/覆盖数据到文件方面有什么区别？
> 2. 如果只想**追加**一行新数据到 `access.log` 末尾而不覆盖已有内容，应该用什么重定向符号？

---

## 练习 1：用 grep 做基本模式匹配

**Step 1.** 搜索所有包含 `ERROR` 的行：

```bash
grep 'ERROR' access.log
```

**Step 2.** 使用 `-c` 只统计匹配的行数，而不显示内容：

```bash
grep -c 'ERROR' access.log
```

**Step 3.** 使用 `-i` 忽略大小写，搜索 `error`（小写）：

```bash
grep -i 'error' access.log
```

**Step 4.** 使用 `-v` 反向匹配，列出所有**不包含** `INFO` 的行：

```bash
grep -v 'INFO' access.log
```

**Step 5.** 使用 `-n` 显示匹配行在文件中的行号：

```bash
grep -n 'failed' access.log
```

> **检查理解**
> 1. `grep -c` 和 `grep | wc -l` 在效果上有什么共同点？两者的输出是否总是完全一致？
> 2. 如果想同时使用 `-i` 和 `-v`（忽略大小写地反向匹配），命令应该怎么写？

---

## 练习 2：regular expression 元字符

`grep` 默认使用 **BRE**（Basic Regular Expression）。

**Step 1.** 用 `^` 锚点匹配以 `2026-07-01 10:1` 开头的行：

```bash
grep '^2026-07-01 10:1' access.log
```

**Step 2.** 用 `$` 锚点匹配以 `success` 结尾的行：

```bash
grep 'success$' access.log
```

**Step 3.** 用 `.`（匹配任意单个字符）查找 `user=` 后面正好跟五个任意字符的行（如 `alice` 长度为 5）：

```bash
grep 'user=.....action' access.log
```

**Step 4.** 用字符集合 `[...]` 匹配用户名以 `a` 或 `c` 开头的行：

```bash
grep 'user=[ac]' access.log
```

**Step 5.** 用 `*`（前一个字符出现 0 次或多次）配合 `.*` 匹配同时包含 `login` 和 `failed` 的行：

```bash
grep 'login.*failed' access.log
```

> **检查理解**
> 1. 在 BRE 中，`.` 和 `*` 分别代表什么含义？和 shell 通配符（wildcard）里的 `*` 是同一个概念吗？
> 2. `^ERROR` 和 `ERROR$` 分别会匹配什么样的行？如果一行整体就是 `ERROR`，这两个 pattern 是否都能匹配？

---

## 练习 3：grep 的扩展元字符与 egrep / fgrep

BRE 中 `+`、`?`、`|`、`()` 等元字符需要用反斜杠转义才生效；**ERE**（Extended Regular Expression）则不需要转义。

**Step 1.** 用 `grep -E`（等价于 `egrep`）查找 `login` 或 `logout`：

```bash
grep -E 'login|logout' access.log
```

**Step 2.** 用转义方式在普通 `grep` 中实现同样效果，验证两者结果一致：

```bash
grep 'login\|logout' access.log
```

**Step 3.** 用 `egrep` 命令直接执行相同搜索（注意：多数发行版中 `egrep` 是 `grep -E` 的别名，且已被标记为过时用法）：

```bash
egrep 'login|logout' access.log
```

**Step 4.** 用 `fgrep`（等价于 `grep -F`）搜索一个包含正则元字符的**字面字符串** `user=bob`：

```bash
fgrep 'user=bob' access.log
```

**Step 5.** 对比：如果用普通 `grep` 搜索字面字符串 `192.168.1.1`（包含 `.`），`.` 会被当作正则元字符匹配任意字符，而 `fgrep` 会把它当作字面点号。用下面的命令观察两者差异：

```bash
echo "192.168.1.1 vs 192X168X1X1" > ip_test.txt
grep '192.168.1.1' ip_test.txt
fgrep '192.168.1.1' ip_test.txt
```

> **检查理解**
> 1. `grep`、`egrep`、`fgrep` 三者分别相当于 `grep` 加什么选项？
> 2. 为什么在搜索包含 `.`、`*`、`[` 等特殊符号的**字面字符串**时，使用 `fgrep`（或 `grep -F`）比普通 `grep` 更安全、更符合预期？

---

## 练习 4：用 cut 提取字段

`students.csv` 是以逗号 `,` 分隔的结构化数据，适合用 `cut` 按字段（field）提取。

**Step 1.** 提取第 1 列（姓名）：

```bash
cut -d',' -f1 students.csv
```

**Step 2.** 提取第 1 列和第 3 列（姓名和分数）：

```bash
cut -d',' -f1,3 students.csv
```

**Step 3.** 提取从第 2 列到最后一列：

```bash
cut -d',' -f2- students.csv
```

**Step 4.** 对 `access.log` 使用空格作为分隔符，提取第 1、2 个字段（日期和时间）：

```bash
cut -d' ' -f1,2 access.log
```

**Step 5.** 用 `-c` 按字符位置截取，只取每行的前 10 个字符（日期部分）：

```bash
cut -c1-10 access.log
```

> **检查理解**
> 1. `cut -d',' -f1,3` 与 `cut -d',' -f1-3` 输出的列有什么不同？
> 2. `cut -c` 和 `cut -f` 两种模式分别适合处理什么样的数据？为什么 `access.log` 用 `-f` 而不是简单的 `-c` 更合理？

---

## 练习 5：用 tr 转换和删除字符

`tr`（translate）只能处理**标准输入**（stdin），不能直接接文件名作为参数。

**Step 1.** 把 `students.csv` 中所有小写字母转换为大写：

```bash
tr 'a-z' 'A-Z' < students.csv
```

**Step 2.** 用 `-d` 删除所有数字字符：

```bash
tr -d '0-9' < students.csv
```

**Step 3.** 用 `-s`（squeeze）把 `access.log` 中连续多个空格压缩为一个空格：

```bash
tr -s ' ' < access.log
```

**Step 4.** 把 CSV 的逗号分隔符替换成 tab 制表符，便于后续处理：

```bash
tr ',' '\t' < students.csv
```

**Step 5.** 组合管道：先用 `cat` 输出文件，再通过管道传给 `tr` 删除所有 `,`：

```bash
cat students.csv | tr -d ','
```

> **检查理解**
> 1. 为什么 `tr file.txt` 这样的写法（不用 `<` 或管道）无法按预期工作？`tr` 的输入来源必须是什么？
> 2. `tr -d` 和 `tr -s` 的作用分别是什么？如果想把多个连续的逗号 `,,,` 压缩成一个，应该用哪个选项？

---

## 练习 6：用 sort 排序数据

**Step 1.** 按字典序（默认）对 `students.csv` 全文排序：

```bash
sort students.csv
```

**Step 2.** 跳过表头，只对数据行按第 3 列（分数）**数值**排序，使用 `-t`、`-k`、`-n`：

```bash
tail -n +2 students.csv | sort -t',' -k3 -n
```

**Step 3.** 用 `-r` 做降序排序，找出分数最高的学生排在最前：

```bash
tail -n +2 students.csv | sort -t',' -k3 -n -r
```

**Step 4.** 用 `-u` 对 `access.log` 中提取出的用户名去重并排序：

```bash
grep -oE 'user=[a-z]+' access.log | sort -u
```

**Step 5.** 按第 2 列（city）排序，city 相同的情况下再按第 3 列（score）数值升序排序：

```bash
tail -n +2 students.csv | sort -t',' -k2,2 -k3,3n
```

> **检查理解**
> 1. `sort` 默认按什么方式排序？为什么对纯数字列排序时如果不加 `-n` 可能会得到"错误"的顺序（例如 9 排在 10 后面）？
> 2. `-k3` 和 `-k3,3` 在多字段排序时有什么区别？为什么在多重排序键（multiple sort keys）场景下推荐用后者？

---

## 练习 7：用 wc 统计信息

**Step 1.** 统计 `access.log` 的行数：

```bash
wc -l access.log
```

**Step 2.** 统计单词数和字节数：

```bash
wc -w access.log
wc -c access.log
```

**Step 3.** 同时统计行数、单词数、字符数（不加选项的默认输出）：

```bash
wc access.log
```

**Step 4.** 结合管道，统计有多少行包含 `failed`：

```bash
grep 'failed' access.log | wc -l
```

**Step 5.** 统计 `students.csv` 中有多少个用逗号分隔的字段（用第一行表头计算）：

```bash
head -n1 students.csv | tr ',' '\n' | wc -l
```

> **检查理解**
> 1. `wc -l file` 和 `cat file | wc -l` 的结果是否一样？两者的性能或适用场景有什么区别？
> 2. Step 5 中为什么要先用 `tr ',' '\n'` 把逗号换成换行符，再用 `wc -l` 计数？如果直接对表头行用 `wc -w` 会得到相同结果吗？

---

## 练习 8：用 sed 做基本查找替换

`sed`（stream editor）最常见的用法是 `s/pattern/replacement/`。

**Step 1.** 把 `access.log` 中所有 `INFO` 替换为 `INFO_LEVEL`（只输出到屏幕，不修改原文件）：

```bash
sed 's/INFO/INFO_LEVEL/' access.log
```

**Step 2.** 只替换每行中**第一次**出现的 `status=failed` 为 `status=FAILED`（默认行为）：

```bash
sed 's/status=failed/status=FAILED/' access.log
```

**Step 3.** 用 `g` 标志实现**全局替换**，把一行中所有的空格都替换成下划线：

```bash
echo "a b c d" | sed 's/ /_/g'
```

**Step 4.** 用 `-i` 直接修改文件本身（in-place），把 `students.csv` 里的 `Berlin` 替换为 `Munich`（建议先备份）：

```bash
cp students.csv students.csv.bak
sed -i 's/Berlin/Munich/' students.csv
cat students.csv
```

**Step 5.** 结合行号，只删除第 1 行（表头）：

```bash
sed '1d' students.csv.bak
```

> **检查理解**
> 1. `sed 's/foo/bar/'` 和 `sed 's/foo/bar/g'` 的区别是什么？如果一行中 `foo` 出现三次，两者各会替换几处？
> 2. 为什么在使用 `sed -i` 之前，Step 4 先执行了 `cp students.csv students.csv.bak`？这体现了操作文件时的什么良好习惯？

---

## 练习 9：综合管道练习（append 与 view）

**Step 1.** 用 `>>` 向 `access.log` **追加**一条新的日志行，而不覆盖原内容：

```bash
echo "2026-07-01 10:35:22 ERROR user=frank action=login status=failed" >> access.log
```

**Step 2.** 用 `tail -f` 的静态版本 `tail -n 3` 查看最后 3 行，确认追加成功：

```bash
tail -n 3 access.log
```

**Step 3.** 用 `tee` 同时把命令输出**写入文件**并**显示在终端**——统计所有 `failed` 用户名并保存到 `failed_users.txt`：

```bash
grep 'failed' access.log | grep -oE 'user=[a-z]+' | cut -d'=' -f2 | sort -u | tee failed_users.txt
```

**Step 4.** 综合运用本节所有工具：找出 `access.log` 中所有 ERROR 级别的记录，提取用户名，转成大写，按字母排序，并统计总数：

```bash
grep 'ERROR' access.log | grep -oE 'user=[a-z]+' | cut -d'=' -f2 | tr 'a-z' 'A-Z' | sort | tee error_users.txt | wc -l
```

**Step 5.** 用 `cat -n` 查看 `failed_users.txt` 的内容并带上行号：

```bash
cat -n failed_users.txt
```

> **检查理解**
> 1. `tee` 命令在管道中起什么作用？它和单纯用 `>` 重定向到文件相比，多了什么能力？
> 2. 在 Step 4 的管道链中，一共使用了几个不同的文本处理工具？请按顺序列出它们，并说明各自的职责（例如 `grep` 负责过滤、`cut` 负责……）。

---

<details>
<summary><strong>参考答案（点击展开）</strong></summary>

**准备工作**
1. 这是 **heredoc**（here document）语法，用于把多行文本一次性写入文件，等价于批量覆盖写入（覆盖已有内容）；`echo "text" >> file` 是单行追加，不会清空原文件。
2. 使用 `>>`（双大于号）追加重定向；单个 `>` 会覆盖整个文件。

**练习 1**
1. 两者都能得到"匹配行数"，但 `grep -c` 统计的是**匹配的行数**，而 `grep | wc -l` 统计的是**输出到管道的行数**——当每行只可能匹配一次时两者相同；如果 `grep` 加了会让一行多次输出的选项（如 `-o` 配合多次匹配），二者可能不同。
2. `grep -iv 'INFO' access.log`（或 `grep -vi`，顺序不影响）。

**练习 2**
1. `.` 匹配**任意单个字符**（不含换行），`*` 表示**前一个字符出现 0 次或多次**；这与 shell 通配符中 `*` 代表"任意长度任意字符"完全不同，两者是不同的语法体系。
2. `^ERROR` 匹配以 `ERROR` **开头**的行，`ERROR$` 匹配以 `ERROR` **结尾**的行；如果一行内容恰好就是 `ERROR`，两个 pattern 都能匹配，因为它既是行首也是行尾。

**练习 3**
1. `grep` = 基本 `grep`（BRE）；`egrep` = `grep -E`（ERE，扩展正则）；`fgrep` = `grep -F`（fixed string，纯字面字符串匹配，不解释任何正则元字符）。
2. 因为 `fgrep`/`grep -F` 不会把 `.`、`*`、`[` 等符号当作正则元字符处理，而是当作普通字符逐字匹配，这样可以避免正则元字符引起的意外匹配（例如 `.` 本应只匹配字面的点号，却意外匹配了任意字符），结果更可预测。

**练习 4**
1. `-f1,3` 只输出第 1 列和第 3 列（两列，用分隔符隔开）；`-f1-3` 输出第 1 到第 3 列（连续的三列）。
2. `cut -c` 按**固定字符位置**截取，适合每行格式完全一致、列宽固定的数据；`cut -f` 按**分隔符字段**截取，适合像 CSV 这种字段宽度不固定、依赖分隔符区分列的数据。`access.log` 各字段长度不固定（用户名长度不同），所以用 `-f` 按空格分隔更合理。

**练习 5**
1. `tr` 只能从**标准输入（stdin）**读取数据，不支持像 `grep`/`cut` 那样把文件名作为参数直接传入；必须用 `<` 重定向或管道 `|` 把文件内容送入其 stdin。
2. `tr -d` 用于**删除**指定字符集合；`tr -s` 用于把**连续重复**的字符**压缩**为一个。要把连续的逗号压缩成一个，应使用 `tr -s ','`。

**练习 6**
1. `sort` 默认按**字典序（ASCII/字符串）**排序；对数字列若不加 `-n`，会按字符逐位比较，导致例如 `"9"` 排在 `"10"` 之后（因为 `'9' > '1'`），出现"字面上正确、数值上错误"的顺序。
2. `-k3` 表示从第 3 个字段开始排序到**行尾**（如果后面还有字段也会一并参与比较）；`-k3,3` 表示**仅**用第 3 个字段作为排序键。多重排序键场景下必须用 `-k3,3` 精确限定范围，否则后续的 `-k` 会被前一个未限定范围的键"吞掉"，达不到预期的多级排序效果。

**练习 7**
1. 结果通常一致，因为最终传给 `wc -l` 的都是同样的行内容；但 `wc -l file` 直接读文件，少了一次进程调用和管道开销，性能更好、更简洁，应优先使用；`cat file | wc -l` 属于不必要的 `cat` 滥用（"useless use of cat"）。
2. 因为 CSV 的字段个数等于逗号数加 1；把逗号替换成换行后，每个字段独占一行，用 `wc -l` 数行数即可得到字段数。如果直接对表头行用 `wc -w`，只有在字段之间**只有逗号、没有空格**且每个字段本身不含空格时结果才可能凑巧一致，但这不是可靠的字段计数方法（`wc -w` 是按空白符分词，而不是按字段分隔符），因此不推荐。

**练习 8**
1. 不加 `g`（默认）只替换每行中**第一次**出现的匹配；加 `g`（global）会替换该行中**所有**匹配。若一行中 `foo` 出现三次，默认只替换第 1 处，加 `g` 后三处全部替换。
2. 因为 `sed -i` 会**直接修改原文件**，操作不可逆（没有回收站）；先备份是标准的安全习惯，确保误操作后可以从 `.bak` 文件恢复原始数据。

**练习 9**
1. `tee` 会把从 stdin 读到的数据**同时**写入指定文件**并**原样输出到标准输出（stdout），因此可以在管道中间"截取一份"保存到文件的同时，让数据继续流向后面的命令或终端；单纯用 `>` 重定向只会把数据写入文件，终端不会显示，且会中断该点之后的管道。
2. 一共用了 5 个工具：`grep`（两次，负责按 `ERROR` 过滤行、再用 `-o` 提取 `user=xxx` 片段）、`cut`（负责按 `=` 分隔取出用户名字段）、`tr`（负责把小写转大写）、`sort`（负责排序去重效果的前置排序）、`tee`（负责把排序结果写入文件的同时继续传给下一个命令）、`wc`（负责统计最终行数）。

</details>