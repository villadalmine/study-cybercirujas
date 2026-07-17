# 5.2 创建用户与组 (Creating Users and Groups) —— 引导式练习

> 参考来源：[LPI Learning Materials 010-160 §5.2](https://learning.lpi.org/en/learning-materials/010-160/5/5.2/)
> 本文为原创讲解，命令与操作步骤请在测试环境（虚拟机或容器）中实际执行，避免在生产系统上练习。所有需要提权的命令请使用 `sudo` 执行。

---

## 练习 1：查看当前用户身份 (identity)

Linux 是多用户 (multiuser) 操作系统，每个用户拥有唯一的 UID (User ID)，并至少属于一个组 (GID, Group ID)。

**步骤：**

1. 打开终端，运行以下命令查看当前登录用户名：
   ```bash
   whoami
   ```
2. 运行以下命令查看当前用户的完整身份信息，包括 UID、主组 (primary group) 和附加组 (supplementary groups)：
   ```bash
   id
   ```
3. 只查看某个特定用户（例如 `root`）的身份信息：
   ```bash
   id root
   ```
4. 只输出当前用户所属的所有组名：
   ```bash
   id -Gn
   ```

**思考题：**

1. `id` 命令输出中的 `uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo)` 说明了什么？其中哪个是 primary group，哪个是 supplementary group？
2. `whoami` 和 `id -un` 的输出有什么关系？

---

## 练习 2：查看谁在系统中 (who, w, last)

**步骤：**

1. 查看当前所有已登录到系统的用户：
   ```bash
   who
   ```
2. 查看更详细的信息，包括每个用户当前正在运行的进程和系统负载 (load average)：
   ```bash
   w
   ```
3. 查看用户的历史登录记录（读取 `/var/log/wtmp`）：
   ```bash
   last
   ```
4. 只查看某个用户（例如 `root`）的登录历史：
   ```bash
   last root
   ```
5. 查看最近一次系统重启的记录：
   ```bash
   last reboot
   ```

**思考题：**

1. `who` 和 `w` 命令的主要区别是什么？在什么场景下你会优先使用 `w`？
2. 如果 `last` 命令报错找不到文件，最可能是哪个日志文件缺失或被清空？

---

## 练习 3：创建新用户 (useradd)

**步骤：**

1. 使用 `useradd` 创建一个名为 `student1` 的新用户，并让系统自动创建同名的 home 目录：
   ```bash
   sudo useradd -m student1
   ```
2. 查看新用户是否已经写入 `/etc/passwd`：
   ```bash
   grep student1 /etc/passwd
   ```
3. 查看新用户的 home 目录是否已创建：
   ```bash
   ls -ld /home/student1
   ```
4. 创建用户时，同时指定 login shell 为 `/bin/bash`，并写一句注释 (comment/GECOS 字段)：
   ```bash
   sudo useradd -m -s /bin/bash -c "Student Account 1" student2
   ```
5. 查看 `student2` 在 `/etc/passwd` 中对应的完整字段：
   ```bash
   grep student2 /etc/passwd
   ```

**思考题：**

1. `/etc/passwd` 中一行记录一共有几个用冒号 (`:`) 分隔的字段？分别代表什么？
2. 如果创建用户时不加 `-m` 参数，会发生什么？
3. `useradd` 默认使用的 skeleton 目录（新 home 目录内容的模板）通常位于哪里？

---

## 练习 4：设置与修改密码 (passwd)

新创建的用户默认没有可用密码，账户处于锁定 (locked) 状态，必须设置密码后才能登录。

**步骤：**

1. 为 `student1` 设置密码：
   ```bash
   sudo passwd student1
   ```
   按提示输入两次密码。
2. 查看 `/etc/shadow` 中 `student1` 对应行，确认密码字段已从 `!` 或 `*` 变为加密字符串：
   ```bash
   sudo grep student1 /etc/shadow
   ```
3. 以自己当前用户身份修改自己的密码（无需 `sudo`）：
   ```bash
   passwd
   ```
4. 锁定 `student2` 账户，使其暂时无法用密码登录：
   ```bash
   sudo passwd -l student2
   ```
5. 解锁该账户：
   ```bash
   sudo passwd -u student2
   ```

**思考题：**

1. 为什么真正的密码哈希 (hash) 存放在 `/etc/shadow` 而不是 `/etc/passwd` 中？
2. `passwd -l` 在底层是通过什么方式实现"锁定"的（观察加密字段前多出的字符）？

---

## 练习 5：修改用户属性 (usermod)

**步骤：**

1. 将 `student1` 的登录 shell 修改为 `/bin/bash`：
   ```bash
   sudo usermod -s /bin/bash student1
   ```
2. 修改 `student1` 的账户备注信息：
   ```bash
   sudo usermod -c "Updated comment" student1
   ```
3. 修改 `student1` 的用户名为 `student1a`（不改动 UID 和 home 目录路径）：
   ```bash
   sudo usermod -l student1a student1
   ```
4. 将 home 目录同步重命名，并把旧目录内容迁移过去：
   ```bash
   sudo usermod -d /home/student1a -m student1a
   ```
5. 确认修改结果：
   ```bash
   grep student1a /etc/passwd
   ```

**思考题：**

1. `usermod -l`（修改登录名）和 `usermod -d -m`（修改并迁移 home 目录）为什么要分开两个命令执行？
2. 修改一个正在登录使用的用户账户（在线用户）有什么潜在风险？

---

## 练习 6：创建与管理组 (groupadd, groupmod, groupdel)

**步骤：**

1. 创建一个新组 `devteam`：
   ```bash
   sudo groupadd devteam
   ```
2. 查看该组是否写入 `/etc/group`：
   ```bash
   grep devteam /etc/group
   ```
3. 创建用户时直接指定其 primary group 为 `devteam`：
   ```bash
   sudo useradd -m -g devteam student3
   ```
4. 将组名 `devteam` 重命名为 `developers`：
   ```bash
   sudo groupmod -n developers devteam
   ```
5. 删除一个不再使用的空组（先创建一个用于练习）：
   ```bash
   sudo groupadd tempgroup
   sudo groupdel tempgroup
   ```

**思考题：**

1. 如果尝试 `groupdel` 一个仍是某用户 primary group 的组，会发生什么？
2. `/etc/group` 中一行记录的字段结构是什么？和 `/etc/passwd` 有何不同？

---

## 练习 7：把用户加入附加组 (supplementary groups)

**步骤：**

1. 查看 `student3` 当前所属的所有组：
   ```bash
   id student3
   ```
2. 将 `student3` 加入 `developers` 组作为附加组，同时保留其原有的附加组（关键：使用 `-aG` 而不是 `-G`）：
   ```bash
   sudo usermod -aG developers student3
   ```
3. 再次确认加入结果：
   ```bash
   id student3
   ```
4. 也可以使用 `gpasswd` 将用户加入组：
   ```bash
   sudo gpasswd -a student3 developers
   ```
5. 将用户从某个附加组中移除：
   ```bash
   sudo gpasswd -d student3 developers
   ```

**思考题：**

1. 如果误用 `sudo usermod -G developers student3`（不带 `-a`）会造成什么后果？
2. 为什么修改附加组后，已经登录的 shell 会话中 `id` 命令的输出不会立即更新？该用户需要做什么才能看到新的组权限生效？

---

## 练习 8：设置密码有效期策略 (chage)

**步骤：**

1. 查看 `student1` 当前的密码有效期信息：
   ```bash
   sudo chage -l student1
   ```
2. 设置该账户密码最长有效天数为 90 天：
   ```bash
   sudo chage -M 90 student1
   ```
3. 设置密码修改后至少间隔 7 天才能再次修改：
   ```bash
   sudo chage -m 7 student1
   ```
4. 设置密码过期前 14 天开始提醒用户：
   ```bash
   sudo chage -W 14 student1
   ```
5. 强制该用户下次登录时必须立即修改密码：
   ```bash
   sudo chage -d 0 student1
   ```
6. 再次查看策略是否生效：
   ```bash
   sudo chage -l student1
   ```

**思考题：**

1. `chage -M`、`chage -m`、`chage -W` 分别对应 `/etc/shadow` 中的哪些字段（按字段顺序思考）？
2. `chage -d 0` 的原理是什么，为什么能强制用户下次登录改密码？

---

## 练习 9：使用 su 和 sudo 切换身份

**步骤：**

1. 使用 `su` 切换为 `student1` 用户（需要输入 `student1` 的密码）：
   ```bash
   su - student1
   ```
2. 确认当前身份已切换：
   ```bash
   whoami
   id
   ```
3. 退出回到原用户：
   ```bash
   exit
   ```
4. 以 `sudo` 临时执行一条需要 root 权限的命令（使用你自己的密码，而非 root 密码）：
   ```bash
   sudo cat /etc/shadow
   ```
5. 查看当前用户是否具备 `sudo` 权限，以及被授权执行哪些命令：
   ```bash
   sudo -l
   ```

**思考题：**

1. `su student1` 和 `su - student1` 的区别是什么？为什么后者更常用于"完整切换身份"的场景？
2. `su` 需要目标账户的密码，而 `sudo` 需要的是谁的密码？这体现了两种命令怎样不同的权限模型？

---

## 练习 10：删除用户与组 (userdel, cleanup)

**步骤：**

1. 删除 `student2` 用户，但保留其 home 目录：
   ```bash
   sudo userdel student2
   ```
2. 确认 home 目录仍然存在：
   ```bash
   ls -ld /home/student2
   ```
3. 删除 `student3` 用户，并同时删除其 home 目录和邮件池 (mail spool)：
   ```bash
   sudo userdel -r student3
   ```
4. 确认该用户已从 `/etc/passwd` 和 `/etc/shadow` 中移除：
   ```bash
   grep student3 /etc/passwd /etc/shadow
   ```
5. 清理本次练习创建的组：
   ```bash
   sudo groupdel developers
   ```

**思考题：**

1. `userdel`（不加参数）和 `userdel -r` 的核心区别是什么？在生产环境中你会更倾向于哪一种，为什么？
2. 如果某个已删除用户的 UID 后来被系统重新分配给了新用户，而旧文件的所有者信息还残留在磁盘上（显示为数字 UID 而非用户名），这会带来什么安全隐患？

---

<details>
<summary><strong>参考答案（点击展开）</strong></summary>

**练习 1**
1. `uid=1000(alice)` 是该用户的 UID 和 primary group 之外的身份编号；`gid=1000(alice)` 是其 primary group（通常与用户名同名、UID 相同，这是许多发行版采用的 "user private group" 方案）；`groups=1000(alice),27(sudo)` 列出的是该用户所属的**全部**组，其中排在最前的第一个是 primary group，其余（如 `sudo`）是 supplementary group。
2. `whoami` 只输出用户名字符串，等价于 `id -un` 的结果；两者应始终一致，因为都是读取当前进程的有效用户身份 (effective UID)。

**练习 2**
1. `who` 只列出已登录用户、终端和登录时间；`w` 在此基础上还显示系统负载 (load average) 和每个用户当前正在运行的命令，信息更丰富，适合排查"谁在占用系统资源"。
2. 最可能是 `/var/log/wtmp` 文件缺失、权限不对，或被 `logrotate` 清空/轮转。

**练习 3**
1. 共 7 个字段：`login name : password占位符 : UID : GID : GECOS/comment : home目录 : login shell`。
2. 不加 `-m` 时不会自动创建 home 目录，用户首次登录时可能找不到家目录，某些环境变量和默认配置文件也不会被复制。
3. 通常位于 `/etc/skel/`。

**练习 4**
1. 因为 `/etc/passwd` 必须对所有用户可读（很多命令行工具依赖它做 UID→用户名 的转换），如果密码哈希也存在其中，就容易被离线破解；而 `/etc/shadow` 只有 root 可读，提升了安全性。
2. `passwd -l` 会在加密字段前插入一个 `!`（或 `!!`），使存储的哈希与任何输入都无法匹配，从而阻止密码登录，但不会删除原哈希，解锁后即可恢复。

**练习 5**
1. 因为二者操作的对象不同：`-l` 只改的是 `/etc/passwd` 里的登录名字段，而 `-d -m` 涉及实际移动磁盘上的目录内容并更新路径，是更"重"的文件系统操作，分开执行更安全、更容易排查错误。
2. 如果目标用户当前有登录 session 或正在运行进程，修改用户名/UID/home 路径可能导致该用户会话中的路径引用失效、文件权限混乱，甚至造成数据丢失，建议先确认该用户已退出登录再操作。

**练习 6**
1. 会被拒绝并报错（类似 "cannot remove the primary group of user"），必须先修改或删除依赖该组作为 primary group 的用户，才能删除该组。
2. `/etc/group` 每行字段为：`组名 : 密码占位符（通常为空或x） : GID : 成员用户列表（逗号分隔）`；相比 `/etc/passwd` 少了 home 目录和 shell 字段，多的是"成员列表"这一项。

**练习 7**
1. 会用 `developers` **覆盖**该用户原有的全部附加组，导致该用户原本所在的其他组（例如 `sudo`）被意外移除，是常见且危险的误操作。
2. 因为组成员信息 (`groups`) 在登录 shell 启动时被读入并缓存在该 session 的进程凭据中，之后修改 `/etc/group` 不会实时刷新已存在的 session；该用户需要重新登录（或用 `newgrp` /启动新 shell）才能让新的组权限生效。

**练习 8**
1. `-M`（最长有效天数）对应 `/etc/shadow` 第 5 字段；`-m`（最短间隔天数）对应第 4 字段；`-W`（过期前提醒天数）对应第 6 字段。
2. `-d 0` 把"上次修改密码的日期"字段设为 1970-01-01（Unix epoch，值为 0），系统据此判断密码早已超过最长有效期，从而在下次登录时强制要求用户修改密码。

**练习 9**
1. `su student1` 只切换用户身份，但保留原用户的 shell 环境变量（如 `PATH`、当前工作目录）；`su - student1`（等价于 `su -l student1`）会模拟一次完整登录，加载目标用户的登录环境（如新的 `HOME`、`PATH`、执行其 `.bash_profile`），更接近"以该用户身份登录"的真实效果。
2. `su` 需要输入**目标账户**的密码；`sudo` 默认需要输入**当前操作者自己**的密码（由 `/etc/sudoers` 授权哪些命令可执行）。这体现了 `su` 是"身份切换"模型，而 `sudo` 是"按策略临时提权"模型，权限粒度和审计能力（如日志记录执行者）远高于 `su`。

**练习 10**
1. `userdel` 只删除账户本身（`/etc/passwd`、`/etc/shadow`、`/etc/group` 中的相关记录），保留 home 目录及邮件池；`userdel -r` 会连同 home 目录和 mail spool 一并删除。生产环境中通常先不加 `-r`，保留数据一段时间以便审计或恢复，确认无需保留后再手动清理。
2. 会出现"UID 重用" (UID reuse) 问题：旧用户留下的文件仍以数字 UID 标记所有者，一旦该 UID 分配给新用户，新用户会自动"继承"对这些旧文件的访问权限，可能导致敏感数据泄露或权限混乱，因此删除用户前建议先审计并清理其名下的所有文件。

</details>