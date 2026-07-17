# 2.3 Using Directories and Listing Files — 引导练习

> 参考资料：https://learning.lpi.org/en/learning-materials/010-160/2/2.3/

## 练习 1：确认你在文件系统中的位置

1. 打开终端（terminal），输入以下命令并回车：
   ```
   pwd
   ```
2. 观察输出。这就是你当前的 **working directory**（工作目录），也就是 shell 此刻"站立"的位置。
3. 输入：
   ```
   echo $HOME
   ```
   对比这个输出和上一步 `pwd` 的输出是否相同。
4. 输入：
   ```
   echo ~
   ```
   观察 `~`（tilde）符号被 shell 替换成了什么。

**思考题：**
1. `pwd` 命令的全称是什么？它输出的路径属于 absolute path（绝对路径）还是 relative path（相对路径）？
2. `~` 符号代表什么？如果当前登录用户是 `student`，`~` 通常会被展开成哪个目录？

---

## 练习 2：使用 absolute path 和 relative path 导航

1. 从任意位置，使用 absolute path 切换到根目录（root directory）：
   ```
   cd /
   pwd
   ```
2. 再使用 absolute path 切换到 `/home` 目录：
   ```
   cd /home
   pwd
   ```
3. 回到你的 home directory，分别用三种不同方式尝试（每次先用 `cd /` 或 `cd /home` 复位，再执行）：
   ```
   cd ~
   cd
   cd $HOME
   ```
4. 现在用 relative path 的方式回到根目录的上一层试试看：
   ```
   cd /home
   cd ..
   pwd
   ```
5. 输入以下命令，观察 `.`（当前目录）的作用：
   ```
   cd .
   pwd
   ```

**思考题：**
1. Absolute path 和 relative path 的核心区别是什么？分别举出练习中出现的一个例子。
2. `..` 和 `.` 各自代表什么？如果你在 `/home/student` 目录下执行 `cd ../..`，最终会到达哪个目录？

---

## 练习 3：cd 的特殊跳转方式

1. 先确认当前位置：
   ```
   pwd
   ```
2. 切换到 `/etc` 目录：
   ```
   cd /etc
   pwd
   ```
3. 再切换到 `/var`：
   ```
   cd /var
   pwd
   ```
4. 现在执行：
   ```
   cd -
   pwd
   ```
5. 再执行一次 `cd -`，观察 `pwd` 的输出变化。

**思考题：**
1. `cd -` 命令的作用是什么？它和 `cd ..` 有什么本质区别？
2. 如果你连续执行两次 `cd -`，最终会回到哪里？为什么？

---

## 练习 4：用 ls 列出目录内容

1. 切换回 home directory，并列出其中的文件和目录：
   ```
   cd ~
   ls
   ```
2. 使用 long listing format 查看详细信息：
   ```
   ls -l
   ```
3. 观察输出的每一列，尝试识别：文件类型与权限（permissions）、所有者（owner）、文件大小（size）、修改时间（modification time）、文件名。
4. 使用 `-F` 选项，为不同类型的条目添加分类符号：
   ```
   ls -F
   ```
5. 观察目录名后面是否出现了 `/`，可执行文件后面是否出现了 `*`。

**思考题：**
1. `ls -l` 输出中，一行最左边的第一个字符（例如 `d` 或 `-`）代表什么信息？
2. `ls -F` 在目录名后附加的符号是什么？这个选项对区分文件和目录有什么帮助？

---

## 练习 5：隐藏文件与递归列表

1. 在 home directory 下列出所有文件，包括 hidden files（隐藏文件）：
   ```
   cd ~
   ls -a
   ```
2. 观察是否出现了以 `.` 开头的条目，例如 `.bashrc`、`.` 和 `..`。
3. 创建一个测试目录结构，方便下一步练习（虽然 `mkdir` 属于其他主题，这里仅用于生成练习素材）：
   ```
   mkdir -p testdir/subdir1 testdir/subdir2
   ```
4. 递归列出 `testdir` 及其所有子目录内容：
   ```
   ls -R testdir
   ```
5. 结合选项，同时查看隐藏文件和长格式信息：
   ```
   ls -la testdir
   ```

**思考题：**
1. 为什么 `ls`（不加参数）默认不会显示以 `.` 开头的文件？这类文件通常用来存放什么内容？
2. `ls -a` 的输出中一定会包含 `.` 和 `..` 这两个条目，它们分别代表什么？
3. `ls -R` 中的 `-R` 与 `-r` 含义相同吗？`-R` 具体做了什么？

---

<details>
<summary>点击查看参考答案</summary>

**练习 1**
1. `pwd` 是 "print working directory" 的缩写，输出的路径是 **absolute path**（因为它总是从根目录 `/` 开始完整描述位置）。
2. `~` 代表当前用户的 home directory。对于用户 `student`，通常会展开为 `/home/student`。

**练习 2**
1. Absolute path 从文件系统的根目录 `/` 开始描述完整路径（例如 `/home/student`），无论当前处于什么目录都指向同一个位置；relative path 是相对于当前 working directory 描述的路径（例如 `..`、`subdir1`），其含义取决于你出发时所在的位置。
2. `.` 代表当前目录本身；`..` 代表当前目录的上一级目录（parent directory）。在 `/home/student` 下执行 `cd ../..` 会先到 `/home`，再到 `/`，最终到达根目录 `/`。

**练习 3**
1. `cd -` 会切换到你**上一次**所在的目录（即切换前的 working directory），并把该路径打印出来；`cd ..` 则是切换到当前目录的**上一级目录**，两者依据完全不同（前者基于历史记录，后者基于目录树层级）。
2. 连续执行两次 `cd -` 会在两个目录之间来回切换：第一次回到切换前的目录，第二次又切回之前的目录，因此会回到最初执行第一次 `cd -` 之前所在的目录。

**练习 4**
1. 第一个字符表示文件类型：`d` 表示这是一个 directory（目录），`-` 表示这是一个普通文件（regular file），`l` 表示 symbolic link 等。
2. `ls -F` 会在目录名后加 `/`，在可执行文件后加 `*`，在符号链接后加 `@` 等。这让用户不需要执行 `ls -l` 也能快速从名称上区分条目类型。

**练习 5**
1. 因为以 `.` 开头的文件被系统约定为 hidden files，通常用来存放程序或 shell 的配置信息（configuration），默认隐藏可以让普通的目录列表更简洁，不被大量配置文件干扰。
2. `.` 代表当前目录自身，`..` 代表当前目录的 parent directory；它们是每个目录中都天然存在的两个特殊条目。
3. 不相同。`-R` 表示 recursive（递归），会连同所有子目录的内容一起列出；`-r` 表示 reverse（反转排序顺序），与递归无关。

</details>