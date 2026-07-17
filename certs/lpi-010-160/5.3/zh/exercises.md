# LPI Linux Essentials (010-160, v1.6) — Topic 5.3: Managing File Permissions and Ownership

> 参考来源:
> - https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
>
> 以下练习为原创内容，仅将上述资料作为主题范围参考，未直接复制其文字。请在一台 Linux 虚拟机或容器中依次执行下列命令，并在每个练习块之后回答理解性问题。

---

## 练习 1：解读 `ls -l` 输出的权限字段

1. 打开终端，进入你的 home 目录：
   ```bash
   cd ~
   ```
2. 创建一个测试目录并进入：
   ```bash
   mkdir perm_lab && cd perm_lab
   ```
3. 创建一个空文件：
   ```bash
   touch demo.txt
   ```
4. 查看该文件的详细信息：
   ```bash
   ls -l demo.txt
   ```
   你应该会看到类似这样的一行输出：
   ```
   -rw-r--r-- 1 student student 0 Jul 12 10:00 demo.txt
   ```
5. 把权限字符串 `-rw-r--r--` 拆分成 4 段来分析：
   - 第 1 个字符：文件类型（`-` 表示 regular file，`d` 表示 directory）
   - 第 2–4 个字符：owner 的权限（`rwx`）
   - 第 5–7 个字符：group 的权限
   - 第 8–10 个字符：other 的权限

**理解性问题：**
1. 在 `-rw-r--r--` 中，group 拥有哪些权限？owner 和 other 之间的权限区别是什么？
2. 如果 `ls -l` 显示的第一个字符是 `d` 而不是 `-`，这说明这一行描述的是什么类型的对象？
3. `ls -l` 输出中，`demo.txt` 前面的 `student student` 两列分别代表什么？

---

## 练习 2：用 symbolic mode 修改权限（`chmod u/g/o + - =`）

1. 确认当前权限：
   ```bash
   ls -l demo.txt
   ```
2. 给 owner 增加 execute 权限：
   ```bash
   chmod u+x demo.txt
   ```
3. 再次查看权限，确认变化：
   ```bash
   ls -l demo.txt
   ```
4. 移除 group 和 other 的 write 权限（本来就没有 write，这一步用来练习语法）并撤销 group 的 read 权限：
   ```bash
   chmod g-r demo.txt
   ```
5. 使用 `=` 直接设定 other 的权限为只有 read：
   ```bash
   chmod o=r demo.txt
   ```
6. 一次性对多个对象同时操作，给 owner 和 group 都加上 write 权限：
   ```bash
   chmod ug+w demo.txt
   ls -l demo.txt
   ```

**理解性问题：**
1. `chmod g-r demo.txt` 和 `chmod g=r demo.txt` 这两条命令的行为有什么本质区别？
2. 如果你想让所有人（owner、group、other）都拥有 read 和 execute 权限，但没有人有 write 权限，应该用哪个 symbolic mode 命令？
3. `chmod a+x demo.txt` 中的 `a` 代表什么？

---

## 练习 3：用 octal（numeric）mode 修改权限

1. 回顾 octal 权限的计算方式：`r=4`、`w=2`、`x=1`，三者相加得到一位数字，owner/group/other 各占一位。
2. 把 `demo.txt` 的权限直接设为 `rw-r--r--`：
   ```bash
   chmod 644 demo.txt
   ls -l demo.txt
   ```
3. 把权限设为 `rwxr-xr-x`（常见于可执行脚本或目录）：
   ```bash
   chmod 755 demo.txt
   ls -l demo.txt
   ```
4. 创建一个 shell 脚本并只允许 owner 读写执行，其他人完全没有权限：
   ```bash
   echo '#!/bin/bash' > run.sh
   echo 'echo hello' >> run.sh
   chmod 700 run.sh
   ls -l run.sh
   ./run.sh
   ```

**理解性问题：**
1. octal 数字 `644` 换算成 `rwx` 字符串是什么？分别对应 owner/group/other 的哪些权限？
2. 为什么要给 `run.sh` 这样一个脚本文件添加 execute 权限之后，`./run.sh` 才能直接运行？
3. octal `750` 表示的权限组合是什么？这种设置常用于什么场景？

---

## 练习 4：使用 `chown` 和 `chgrp` 修改所有权

> 说明：修改文件的 owner 通常需要 root 权限，以下步骤使用 `sudo`。若没有 sudo 权限，可以只做只读观察（`ls -l`、`id` 命令部分）。

1. 查看当前系统中存在的用户和组（了解可用的 owner/group 名称）：
   ```bash
   cat /etc/passwd | cut -d: -f1
   cat /etc/group | cut -d: -f1
   ```
2. 查看 `demo.txt` 当前的 owner 和 group：
   ```bash
   ls -l demo.txt
   ```
3. 假设系统中存在另一个用户 `alice`，将 `demo.txt` 的 owner 改为 `alice`：
   ```bash
   sudo chown alice demo.txt
   ls -l demo.txt
   ```
4. 只修改 group，把 group 改为 `sudo` 组（或系统中已存在的其他组）：
   ```bash
   sudo chgrp sudo demo.txt
   ls -l demo.txt
   ```
5. 一次性同时修改 owner 和 group，语法为 `owner:group`：
   ```bash
   sudo chown alice:alice demo.txt
   ls -l demo.txt
   ```
6. 使用 `-R` 递归地修改整个目录及其内容的 owner：
   ```bash
   sudo chown -R alice:alice ~/perm_lab
   ```

**理解性问题：**
1. `chown alice:alice demo.txt` 命令中，冒号前后的两个 `alice` 分别修改的是什么？
2. 为什么普通用户一般不能随意把自己的文件 `chown` 给别的用户？
3. `chown -R` 中的 `-R` 选项起什么作用？在什么场景下你会需要它？

---

## 练习 5：理解 `umask` 与新建文件/目录的默认权限

1. 查看当前 shell 的 umask 值：
   ```bash
   umask
   ```
2. 创建一个新文件和一个新目录，观察它们的默认权限：
   ```bash
   touch newfile.txt
   mkdir newdir
   ls -l newfile.txt
   ls -ld newdir
   ```
3. 临时修改 umask 为 `022`，再新建一个文件和目录，比较权限差异：
   ```bash
   umask 022
   touch newfile2.txt
   mkdir newdir2
   ls -l newfile2.txt
   ls -ld newdir2
   ```
4. 把 umask 改得更严格，例如 `077`，再新建一个文件观察结果：
   ```bash
   umask 077
   touch newfile3.txt
   ls -l newfile3.txt
   ```
5. 恢复默认 umask（重新打开一个终端，或手动设回 `022`）：
   ```bash
   umask 022
   ```

**理解性问题：**
1. 为什么普通文件的默认最大权限是 `666`（而不是 `777`），而目录的默认最大权限是 `777`？
2. 如果 umask 是 `022`，新建文件的最终权限是多少？请写出计算过程。
3. umask 为 `077` 时，新建的文件和目录只有谁能访问？这种设置适合什么场景？

---

## 练习 6：SUID、SGID 与 sticky bit（特殊权限）

1. 找到系统中一个已经设置了 SUID 的常见命令，观察其权限字符串：
   ```bash
   ls -l /usr/bin/passwd
   ```
   注意 owner 的 execute 位显示为 `s`（例如 `-rwsr-xr-x`），这就是 SUID。
2. 创建一个测试文件，练习用 symbolic mode 添加 SUID：
   ```bash
   touch suidtest
   chmod u+s suidtest
   ls -l suidtest
   ```
3. 用 octal mode 设置 SUID（在原来三位数字前加第 4 位，SUID=4）：
   ```bash
   chmod 4755 suidtest
   ls -l suidtest
   ```
4. 练习添加 SGID（symbolic mode 用 `g+s`，octal mode 第 4 位为 2）：
   ```bash
   mkdir sgiddir
   chmod g+s sgiddir
   ls -ld sgiddir
   chmod 2775 sgiddir
   ls -ld sgiddir
   ```
5. 观察 sticky bit 的典型例子 `/tmp` 目录：
   ```bash
   ls -ld /tmp
   ```
   other 的 execute 位显示为 `t`（例如 `drwxrwxrwt`），这就是 sticky bit。
6. 在自己的测试目录上练习设置 sticky bit：
   ```bash
   mkdir stickydir
   chmod +t stickydir
   ls -ld stickydir
   chmod 1777 stickydir
   ls -ld stickydir
   ```

**理解性问题：**
1. SUID 权限位对一个可执行文件的作用是什么？为什么 `/usr/bin/passwd` 需要设置 SUID？
2. 当一个目录设置了 SGID，在该目录下新建的文件/子目录的 group 归属会发生什么变化？
3. sticky bit 通常设置在共享目录（如 `/tmp`）上，它解决了什么权限问题？
4. octal mode `4755`、`2775`、`1777` 中，最前面的数字（4、2、1）分别代表哪种特殊权限？

---

<details>
<summary>参考答案（点击展开）</summary>

**练习 1**
1. `-rw-r--r--` 中 group 只有 read 权限（`r--`）；owner 拥有 read 和 write（`rw-`），比 group 多了 write 权限。
2. `d` 表示这一行描述的是一个 directory（目录），而不是 regular file。
3. 前一个 `student` 是文件的 owner（所有者），后一个 `student` 是文件所属的 group。

**练习 2**
1. `g-r` 是在现有权限基础上"减去" read 权限（如果 group 本来没有 write/execute，不受影响）；`g=r` 是把 group 的权限"重置"为只有 read，会清除 group 原本可能拥有的 write 或 execute 权限。
2. `chmod a=rx demo.txt`（`a` 代表 all，即 owner+group+other）。
3. `a` 代表 `all`，等价于同时对 `u`（user/owner）、`g`（group）、`o`（other）执行操作。

**练习 3**
1. `644` 换算为 `rw-r--r--`：owner = read+write，group = read only，other = read only。
2. Linux 内核只有在文件的对应权限位包含 execute（`x`）时，才允许该文件被当作程序直接执行；`chmod` 之前即使内容是合法脚本，系统也会拒绝执行。
3. `750` = `rwxr-x---`：owner 可读写执行，group 只能读和执行，other 完全没有权限。常用于团队共享但需要保密、不希望其他系统用户访问的脚本或目录。

**练习 4**
1. 冒号前的 `alice` 修改文件的 owner，冒号后的 `alice` 修改文件所属的 group。
2. 因为 `chown` 修改 owner 涉及到把文件"转让"给别的用户，属于需要更高权限才能执行的敏感操作，普通用户默认没有权限把自己的文件转让给他人（防止恶意转移文件归属规避配额或审计）。
3. `-R` 表示递归（recursive），会对目录本身以及目录下所有子目录和文件都执行同样的 owner/group 修改，而不仅仅是目录本身这一项。

**练习 5**
1. 因为在 Linux 权限模型里，普通文件默认不应该具有 execute 权限（除非明确设置），所以文件的默认最大值是 `666`（`rw-rw-rw-`）；而目录必须要有 execute 权限才能被"进入"（`cd`）和列出内容，所以目录的默认最大值是 `777`（`rwxrwxrwx`）。
2. 文件默认最大权限 `666`，umask `022` 表示要从最大权限中减去 owner=0、group=2（write）、other=2（write）对应的位，结果是 `644`（`rw-r--r--`）。
3. umask `077` 时，group 和 other 的所有权限位都被屏蔽，新建的文件/目录只有 owner 自己能访问（读写，若是目录还包括执行/进入）。这种设置适合个人隐私目录或存放敏感数据的场景。

**练习 6**
1. SUID（Set User ID）使得该可执行文件在运行时，进程的有效用户身份（effective UID）变成文件 owner 的身份，而不是执行者本身的身份。`/usr/bin/passwd` 需要修改 `/etc/shadow`（该文件普通用户不可写），所以借助 SUID 以 root 身份运行，从而允许普通用户修改自己的密码。
2. 设置了 SGID 的目录，其中新建的文件和子目录会自动继承该目录的 group，而不是继承创建者当前的主 group，从而方便团队共享文件时保持一致的 group 归属。
3. sticky bit 用于共享的、任何人都可写的目录（如 `/tmp`），它规定即使 other 用户对目录有 write 权限，也只有文件/子目录的 owner（或 root）才能删除或重命名该文件，防止用户互相删除彼此的文件。
4. `4` 代表 SUID，`2` 代表 SGID，`1` 代表 sticky bit；这一位是在标准的 owner/group/other 三位数字之前额外加上的第 4 位。

</details>