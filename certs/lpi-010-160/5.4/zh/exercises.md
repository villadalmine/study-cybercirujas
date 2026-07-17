# LPI Linux Essentials (010-160, v1.6) — 主题 5.4：Special Directories and Files

> 参考来源：https://learning.lpi.org/en/learning-materials/010-160/5/5.4/

## 练习 1：探索标准系统目录

1. 打开终端，依次查看以下目录的权限和所有者：
   ```
   ls -ld /etc /var /tmp /proc /dev
   ```
2. 查看 `/etc` 下的几个常见配置文件：
   ```
   ls /etc | head -20
   cat /etc/hostname
   cat /etc/os-release
   ```
3. 查看 `/var` 下用于存放可变数据（日志、缓存、邮件队列等）的子目录：
   ```
   ls /var
   sudo ls /var/log | head -10
   ```
4. 查看 `/proc`，这是一个虚拟文件系统（virtual filesystem），并不占用磁盘空间，而是内核在内存中动态生成的：
   ```
   cat /proc/cpuinfo | head -5
   cat /proc/meminfo | head -5
   ls /proc | grep -E '^[0-9]+$' | head -5
   ```
5. 查看 `/dev`，注意其中的 device files：
   ```
   ls -l /dev | head -20
   ```

**理解检查：**
- `/etc`、`/var`、`/tmp`、`/proc`、`/dev` 这五个目录各自的主要用途是什么？
- 为什么 `/proc` 目录下的文件大小通常显示为 0 字节，而且 `ls -l /proc` 中很多条目是纯数字？
- `/proc` 中以数字命名的目录代表什么？

---

## 练习 2：/tmp 目录与 sticky bit

1. 查看 `/tmp` 的权限位：
   ```
   ls -ld /tmp
   ```
   观察输出末尾（其他用户权限位）是否出现字母 `t`。
2. 以当前用户身份在 `/tmp` 创建一个文件：
   ```
   touch /tmp/myfile_$USER.txt
   ls -l /tmp/myfile_$USER.txt
   ```
3. 自己创建一个测试目录并模拟同样的效果：
   ```
   mkdir ~/shared_test
   chmod 1777 ~/shared_test
   ls -ld ~/shared_test
   ```
4. 观察第 3 步中 `chmod 1777` 里的数字 `1` 与 `ls -ld` 输出末尾字符之间的对应关系。

**理解检查：**
- `/tmp` 权限末尾的 `t`（或 `T`）代表什么机制？它解决了什么问题？
- 在一个所有用户都拥有 write 权限的共享目录中，如果没有 sticky bit，会发生什么安全问题？
- `chmod 1777` 中的第一位数字 `1` 对应哪一种特殊权限？

---

## 练习 3：Hard Links 与 Symbolic Links

1. 创建测试目录并进入：
   ```
   mkdir ~/links_test && cd ~/links_test
   ```
2. 创建一个原始文件：
   ```
   echo "hello world" > original.txt
   ```
3. 创建一个 hard link 和一个 symbolic link（也称 soft link）：
   ```
   ln original.txt hardlink.txt
   ln -s original.txt symlink.txt
   ```
4. 使用 `-i` 选项查看每个文件的 inode number：
   ```
   ls -li
   ```
5. 查看三个文件的内容，确认它们目前一致：
   ```
   cat original.txt hardlink.txt symlink.txt
   ```
6. 删除原始文件，再次尝试查看另外两个文件：
   ```
   rm original.txt
   cat hardlink.txt
   cat symlink.txt
   ```
7. 用 `ls -l` 观察 `symlink.txt` 现在的状态（通常会以红色 broken link 形式显示，且指向不存在的目标）：
   ```
   ls -l
   ```

**理解检查：**
- 第 4 步中，`hardlink.txt` 和 `original.txt` 的 inode number 是否相同？`symlink.txt` 呢？
- 为什么删除 `original.txt` 之后，`hardlink.txt` 仍然能正常读取内容，而 `symlink.txt` 却失效了？
- `ls -l` 输出第一列的第一个字符，对于 symbolic link 会显示成什么？
- Hard link 有什么限制是 symbolic link 没有的（提示：跨文件系统、指向目录）？

---

## 练习 4：SUID 与 SGID 特殊权限

1. 查看一个系统自带的、设置了 SUID 位的可执行文件：
   ```
   ls -l /usr/bin/passwd
   ```
   注意所有者（owner）执行权限位上出现的字母 `s`，而不是通常的 `x`。
2. 在整个系统中查找所有设置了 SUID 位的普通文件：
   ```
   find / -perm -4000 -type f 2>/dev/null
   ```
3. 查找所有设置了 SGID 位的普通文件：
   ```
   find / -perm -2000 -type f 2>/dev/null
   ```
4. 在自己的测试目录中创建一个文件，并手动设置 SUID：
   ```
   cd ~/links_test
   touch testperm.sh
   chmod u+s testperm.sh
   ls -l testperm.sh
   ```
5. 再给这个文件加上 SGID：
   ```
   chmod g+s testperm.sh
   ls -l testperm.sh
   ```
6. 去掉该文件的 execute 权限，观察 `ls -l` 中 `s` 字母的变化：
   ```
   chmod u-x,g-x testperm.sh
   ls -l testperm.sh
   ```

**理解检查：**
- SUID 位设置在一个可执行文件上，会对该程序的运行方式产生什么影响？为什么 `/usr/bin/passwd` 需要这个位？
- SGID 位设置在一个目录上（而不是文件上）时，作用是什么？
- 第 6 步中，`ls -l` 输出里 `s` 变成了大写 `S`，这代表什么含义？

---

## 练习 5：用数字方式组合特殊权限

1. 回到测试目录，创建一个新文件：
   ```
   cd ~/links_test
   touch combo.sh
   ```
2. 用八进制（numeric）方式同时设置 SUID、owner 的 rwx，以及 group、other 的 r-x：
   ```
   chmod 4755 combo.sh
   ls -l combo.sh
   ```
3. 改为同时设置 SGID：
   ```
   chmod 2755 combo.sh
   ls -l combo.sh
   ```
4. 改为同时设置 sticky bit：
   ```
   chmod 1755 combo.sh
   ls -l combo.sh
   ```
5. 尝试同时设置 SUID + SGID + sticky bit：
   ```
   chmod 7755 combo.sh
   ls -l combo.sh
   ```

**理解检查：**
- 在四位数的 `chmod` 数字权限（如 `4755`）中，最前面这一位数字代表什么类别的权限，取值范围是多少？
- `chmod 7755` 分别对应哪三种特殊权限同时生效？
- 如果只写 `chmod 755 combo.sh`（三位数字），会对已经设置好的 SUID/SGID/sticky bit 产生什么影响？

<details>
<summary>参考答案（点击展开）</summary>

**练习 1**
- `/etc`：系统级配置文件（configuration files）；`/var`：经常变化的数据，如日志（logs）、缓存（cache）、邮件队列等；`/tmp`：临时文件，重启后通常会被清空；`/proc`：虚拟文件系统，提供内核和进程运行时信息；`/dev`：设备文件（device files），代表硬件设备或虚拟设备。
- 因为 `/proc` 中的内容不是存储在磁盘上的真实文件，而是内核在被访问时实时生成的数据视图，所以文件大小对磁盘占用没有意义，通常显示为 0。
- 每一个以数字命名的目录对应系统中一个正在运行的进程（process），数字就是该进程的 PID。

**练习 2**
- 这是 sticky bit。设置了 sticky bit 的目录中，即使某用户对目录本身拥有 write 权限，也只能删除或重命名自己拥有（owner）的文件，不能删除其他用户的文件。
- 没有 sticky bit 时，任何对该目录有 write 权限的用户都可以删除或覆盖其他用户在该目录下创建的文件，这在像 `/tmp` 这样的多用户共享临时目录中是一个严重的安全隐患。
- 数字 `1` 对应 sticky bit（其他两个特殊位分别是 SUID=4、SGID=2）。

**练习 3**
- `hardlink.txt` 与 `original.txt` 的 inode number 相同，因为 hard link 本质上是同一个 inode 的另一个目录项（directory entry），指向磁盘上同一份数据。`symlink.txt` 的 inode number 不同，它是一个独立的、内容为路径字符串的小文件。
- 因为 hard link 直接引用底层的 inode/数据块，只要还有至少一个 hard link（含原始文件名）存在，数据就不会被删除；而 symbolic link 只是保存了指向原路径名的一个引用，原文件被删除后，这个路径就不存在了，链接随之失效（broken link）。
- 对于 symbolic link，`ls -l` 第一列第一个字符会显示为 `l`（普通文件为 `-`，目录为 `d`）。
- Hard link 不能跨文件系统（filesystem）创建，也不能指向目录（directory）；symbolic link 则两者都可以做到。

**练习 4**
- 设置了 SUID 的可执行文件，在运行时会以该文件所有者（owner）的权限执行，而不是以实际运行它的用户的权限执行。`/usr/bin/passwd` 需要临时以 root 权限运行，才能修改本来只有 root 才能写入的 `/etc/shadow` 文件。
- 设置在目录上的 SGID 会让该目录下新创建的文件和子目录自动继承该目录的 group 所有权，而不是继承创建者当前的 primary group，常用于团队共享目录。
- 大写的 `S` 表示该文件设置了 SUID（或 SGID），但对应的 execute 权限位并未开启；小写的 `s` 则表示 SUID/SGID 和 execute 权限同时存在。大写通常提示这是一个不太常见、可能配置有误的组合。

**练习 5**
- 最前面的第四位数字代表特殊权限（special permissions）：SUID、SGID、sticky bit，取值范围是 0–7，是这三者对应值（4、2、1）的组合和。
- `chmod 7755` 中的 `7` = 4（SUID）+ 2（SGID）+ 1（sticky bit），三个特殊权限同时生效。
- 只写三位数字（如 `755`）会把第四位（特殊权限）重置为 `0`，也就是清除掉之前设置的所有 SUID/SGID/sticky bit。

</details>