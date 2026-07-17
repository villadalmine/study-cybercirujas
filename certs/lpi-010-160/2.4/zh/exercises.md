# LPI Linux Essentials (010-160, v1.6) — 2.4 Creating, Moving and Deleting Files

**主题权重：2**
**参考来源（仅作参考，不含逐字引用）：** https://learning.lpi.org/en/learning-materials/010-160/2/2.4/

本练习面向 LPI Linux Essentials 考试 2.4 小节，围绕 `touch`、`mkdir`、`cp`、`mv`、`rm`、`rmdir` 等命令，通过一套连续的操作场景，帮助你掌握在命令行中创建、复制、移动、重命名和删除文件与目录的方法。建议在一个可以自由试验的临时目录中完成全部步骤。

---

## 练习一：创建目录与文件（`mkdir`、`touch`）

**目标：** 掌握用 `mkdir` 创建目录（包括嵌套目录）、用 `touch` 创建空文件或更新时间戳。

1. 打开终端，确认当前工作目录（working directory）：
   ```
   pwd
   ```
2. 在你的 home directory 下创建一个名为 `lab24` 的目录，并进入该目录：
   ```
   mkdir lab24
   cd lab24
   ```
3. 一次性创建一个多层嵌套目录结构 `projects/reports/2024`：
   ```
   mkdir projects/reports/2024
   ```
4. 观察上一步是否报错，然后使用带 `-p`（parent）选项的写法重新创建：
   ```
   mkdir -p projects/reports/2024
   ```
5. 在当前目录（`lab24`）下用 `touch` 创建三个空文件：
   ```
   touch notes.txt draft.txt todo.txt
   ```
6. 用 `ls -l` 查看这些文件的时间戳，然后再次运行 `touch notes.txt`，并再次用 `ls -l` 对比时间戳的变化。

**检查理解：**

1. 第 3 步为什么会报错？第 4 步中的 `-p` 选项解决了什么问题？
2. 如果目标文件已经存在，`touch` 命令会做什么？它会不会覆盖文件内容？

---

## 练习二：复制文件和目录（`cp`）

**目标：** 掌握 `cp` 的基本用法，以及复制目录时为什么需要 `-r`（recursive）选项。

1. 在 `lab24` 目录下，把 `notes.txt` 复制为 `notes_backup.txt`：
   ```
   cp notes.txt notes_backup.txt
   ```
2. 把 `draft.txt` 复制到 `projects/reports/2024/` 目录下，保持原文件名不变：
   ```
   cp draft.txt projects/reports/2024/
   ```
3. 尝试直接复制整个 `projects` 目录到一个新目录 `projects_copy`：
   ```
   cp projects projects_copy
   ```
4. 观察报错信息后，改用带 `-r` 选项的写法：
   ```
   cp -r projects projects_copy
   ```
5. 用 `ls -lR projects_copy` 确认目录结构与文件是否被完整复制。
6. 使用 `-v`（verbose）选项重复一次复制操作，观察输出的变化：
   ```
   cp -rv projects projects_copy2
   ```

**检查理解：**

1. 第 3 步为什么会失败？`cp` 默认能不能复制目录？
2. `-r` 和 `-v` 这两个选项分别的作用是什么？它们可以合并成 `-rv` 一起使用吗？

---

## 练习三：移动和重命名文件（`mv`）

**目标：** 理解 `mv` 命令在 Linux 中同时承担"移动"与"重命名"两种功能的原因。

1. 把 `todo.txt` 重命名为 `tasks.txt`（仍在 `lab24` 目录下）：
   ```
   mv todo.txt tasks.txt
   ```
2. 把 `tasks.txt` 移动到 `projects/` 目录下，文件名不变：
   ```
   mv tasks.txt projects/
   ```
3. 把 `projects/tasks.txt` 移动回 `lab24` 目录，同时改名为 `tasks_final.txt`：
   ```
   mv projects/tasks.txt tasks_final.txt
   ```
4. 尝试把 `notes_backup.txt` 移动并覆盖已存在的 `notes.txt`：
   ```
   mv notes_backup.txt notes.txt
   ```
5. 用 `mv -i`（interactive）重复一次类似的覆盖操作，观察系统是否会要求确认：
   ```
   touch notes_backup.txt
   mv -i notes_backup.txt notes.txt
   ```

**检查理解：**

1. 为什么 Linux 没有单独的 "rename" 命令，而是用 `mv` 来完成重命名？
2. `mv` 覆盖已存在的目标文件时，默认会不会提示确认？`-i` 选项改变了什么行为？

---

## 练习四：使用通配符（wildcard）批量操作

**目标：** 掌握 `*`、`?`、`[]` 等 wildcard 模式，在 `cp`、`mv`、`rm` 中批量匹配文件。

1. 在 `lab24` 目录下创建一批测试文件：
   ```
   touch report1.txt report2.txt report3.log image1.png image2.png
   ```
2. 使用 `*` 通配符把所有 `.txt` 结尾的文件复制到 `projects/reports/2024/`：
   ```
   cp *.txt projects/reports/2024/
   ```
3. 使用 `?`（匹配单个字符）通配符，只把 `report1.txt` 和 `report2.txt`（不包括 `report3.log`）移动到 `projects/`：
   ```
   mv report?.txt projects/
   ```
4. 使用 `[]` 字符集合，只列出文件名以 `1` 或 `2` 结尾（扩展名之前）的 `image` 文件：
   ```
   ls image[12].png
   ```

**检查理解：**

1. `*` 和 `?` 这两个 wildcard 在匹配范围上有什么区别？
2. 如果目录里同时存在 `report10.txt`，`report?.txt` 能不能匹配到它？为什么？

---

## 练习五：删除文件和目录（`rm`、`rmdir`）

**目标：** 理解 `rmdir` 只能删除空目录，而 `rm -r` 可以递归删除非空目录，并认识删除操作的不可逆性。

1. 尝试用 `rmdir` 删除非空目录 `projects_copy`：
   ```
   rmdir projects_copy
   ```
2. 观察报错后，改用 `rm -r` 删除该目录及其全部内容：
   ```
   rm -r projects_copy
   ```
3. 在 `lab24` 目录下新建一个空目录 `empty_dir`，然后用 `rmdir` 删除它：
   ```
   mkdir empty_dir
   rmdir empty_dir
   ```
4. 用 `rm -i` 交互式删除单个文件，观察确认提示：
   ```
   rm -i image1.png
   ```
5. 最后用 `rm -rv` 清理掉本次练习创建的整个 `lab24` 目录（谨慎确认路径无误后再执行）：
   ```
   cd ..
   rm -rv lab24
   ```

**检查理解：**

1. `rmdir` 和 `rm -r` 分别适用于什么场景？为什么 `rmdir` 对非空目录会报错？
2. 执行 `rm` 删除的文件，是否会像放入回收站一样可以恢复？这对使用 `rm -r` 时意味着什么？

---

<details>
<summary>参考答案（点击展开）</summary>

**练习一**
1. 第 3 步报错是因为 `mkdir` 默认一次只能创建最后一级目录，如果 `projects` 和 `projects/reports` 这些父目录（parent directory）不存在，命令会失败。`-p` 选项会自动创建路径中所有缺失的父目录，并且如果目标目录已存在也不会报错。
2. 如果目标文件已存在，`touch` 不会修改也不会覆盖文件内容，只会更新该文件的访问时间和修改时间戳（timestamp）。

**练习二**
1. `cp` 默认只能复制普通文件，不能复制目录，因为复制目录涉及递归遍历其内部所有子目录和文件，必须显式加上 `-r`（或 `-R`）选项来启用这种递归行为。
2. `-r` 让 `cp` 递归复制目录及其全部内容；`-v` 让命令在执行过程中打印出每一个被处理的文件路径，便于观察进度。两者可以合并写成 `-rv`，效果与分别使用 `-r -v` 相同。

**练习三**
1. 在 Linux 中，重命名本质上就是把一个文件从旧路径"移动"到新路径（路径中的文件名部分发生变化），这与移动文件到不同目录在文件系统层面是同一种操作，因此 `mv` 命令同时承担了移动和重命名两种用途，没有必要单独设计一个 rename 命令。
2. 默认情况下 `mv` 会直接覆盖同名的目标文件，不会给出任何确认提示。加上 `-i` 选项后，命令会在即将覆盖已存在文件时询问用户是否确认（例如 `overwrite 'notes.txt'?`），需要输入 `y` 才会继续。

**练习四**
1. `*` 可以匹配任意数量（包括零个）的字符；`?` 只能匹配任意一个字符。因此 `*` 的匹配范围更广，`?` 更精确、常用于文件名长度已知的场景。
2. 不能。`report?.txt` 中的 `?` 只代表一个字符，`report10.txt` 在 `report` 和 `.txt` 之间有两个字符（`1` 和 `0`），所以不会被 `report?.txt` 匹配到；如果要匹配它需要使用 `report??.txt` 或 `report*.txt`。

**练习五**
1. `rmdir` 只能删除完全为空的目录，一旦目录内还有文件或子目录就会报错，这是一种安全设计，防止用户在不知情的情况下删除还含有数据的目录；如果确实需要删除非空目录及其全部内容，则要使用 `rm -r` 进行递归删除。
2. 标准的 `rm`（包括 `rm -r`）不会把文件放入类似图形界面"回收站"的临时存储区，而是直接从文件系统中移除，通常无法通过常规方式恢复。这意味着使用 `rm -r` 删除目录时必须格外谨慎，执行前应确认路径正确，必要时可先用 `rm -ri` 或先用 `ls` 核实目标内容。

</details>