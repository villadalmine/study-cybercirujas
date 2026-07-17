# LPI Linux Essentials (010-160) — 4.3 Where Data is Stored

> 参考来源: https://learning.lpi.org/en/learning-materials/010-160/4/4.3/ （内容为原创讲解，仅将此链接作为主题参考）

## 练习 1：认识 Filesystem Hierarchy Standard (FHS)

1. 打开终端，执行：
   ```bash
   ls -l /
   ```
2. 观察输出中的顶级目录（`/bin`、`/etc`、`/home`、`/var`、`/usr`、`/tmp` 等）。
3. 查看系统自带的 FHS 官方说明文档：
   ```bash
   man hier
   ```
   如果提示找不到该 man page，尝试：
   ```bash
   man 7 hier
   ```
4. 在 `hier` 手册中找到 `/etc`、`/var`、`/home` 三个目录的简短定义，并用自己的话记下来。

**理解检查：**
1. FHS 的全称是什么？它的作用是什么？
2. 为什么几乎所有主流 Linux 发行版（distribution）都遵循同一套 FHS，而不是各自随意组织目录？

---

## 练习 2：探索 `/etc`、`/home`、`/var`

1. 进入并列出系统配置目录：
   ```bash
   cd /etc
   ls
   cat /etc/os-release
   ```
2. 进入用户主目录（home directory）的父目录：
   ```bash
   cd /home
   ls -l
   ```
3. 进入 `/var` 并查看日志目录占用的磁盘空间：
   ```bash
   cd /var
   ls
   du -sh /var/log
   ```

**理解检查：**
1. `/etc` 里存放的文件通常有什么共同特征？（提示：它们是不是二进制程序？）
2. 如果一台服务器同时有多个用户账户，你预计在 `/home` 下会看到什么？
3. 为什么 `/var`（variable data）里的内容会随着系统运行不断增长，而 `/etc` 一般不会？

---

## 练习 3：`/proc` 虚拟文件系统

1. 查看 CPU 信息：
   ```bash
   cat /proc/cpuinfo
   ```
2. 查看内存信息：
   ```bash
   cat /proc/meminfo
   ```
3. 列出 `/proc` 下的部分内容，注意里面有很多纯数字命名的目录：
   ```bash
   ls /proc | head -n 20
   ```
4. 获取当前 shell 的进程号（PID），并查看它自己在 `/proc` 中对应的信息：
   ```bash
   echo $$
   cat /proc/$$/status
   ```
5. 尝试用 `ls -l` 查看 `/proc/cpuinfo` 的文件大小：
   ```bash
   ls -l /proc/cpuinfo
   ```

**理解检查：**
1. `/proc` 下那些数字命名的目录分别对应什么？
2. `/proc/cpuinfo` 的文件大小通常显示为 0 字节，这说明了 `/proc` 的什么本质（它是不是像 `/etc` 下的普通文件一样存储在磁盘上）？
3. 如果你关闭当前 shell 会话，`/proc/$$` 这个路径还会存在吗？为什么？

---

## 练习 4：`/dev` 中的设备文件（device files）

1. 列出 `/dev` 目录的详细信息：
   ```bash
   ls -l /dev | head -n 20
   ```
2. 观察每一行最前面的字符（`b`、`c`、`d`、`l` 等），找出至少一个以 `b` 开头的行和一个以 `c` 开头的行。
3. 查看一个具体的块设备（block device），例如你的主磁盘（根据实际情况可能是 `/dev/sda`、`/dev/vda` 或 `/dev/nvme0n1`）：
   ```bash
   lsblk
   ls -l /dev/sda 2>/dev/null || ls -l /dev/vda 2>/dev/null
   ```
4. 试验两个特殊的字符设备（character device）：
   ```bash
   echo "test" > /dev/null
   cat /dev/null
   head -c 16 /dev/zero | xxd
   ```

**理解检查：**
1. `ls -l` 输出第一列中的 `b` 和 `c` 分别代表什么类型的设备？两者最主要的区别是什么？
2. 为什么写入 `/dev/null` 的数据永远读不出来？这个设备在实际工作中通常用来做什么？
3. `/dev/zero` 和 `/dev/null` 的行为有什么不同？

---

## 练习 5：查看已挂载的文件系统（mounted filesystems）

1. 查看当前系统所有挂载点（mount point）：
   ```bash
   mount | column -t
   ```
2. 用更易读的方式查看磁盘使用情况：
   ```bash
   df -hT
   ```
3. 查看系统识别到的存储设备及其分区结构：
   ```bash
   lsblk -f
   ```

**理解检查：**
1. `df` 命令中 `-h` 和 `-T` 两个选项分别的作用是什么？
2. 什么是 mount point？为什么 Linux 用一个统一的目录树来表示所有存储设备，而不像某些系统那样用 `C:`、`D:` 这种盘符？

---

## 练习 6：创建并挂载一个虚拟磁盘镜像（练习 mount / umount）

> 本练习使用一个本地镜像文件（disk image），不会影响真实磁盘分区，操作安全。

1. 创建一个 50MB 的镜像文件：
   ```bash
   dd if=/dev/zero of=~/practice.img bs=1M count=50
   ```
2. 在镜像文件上创建 ext4 文件系统：
   ```bash
   mkfs.ext4 ~/practice.img
   ```
3. 创建一个空目录作为挂载点：
   ```bash
   mkdir ~/mnt_test
   ```
4. 使用 loop 设备挂载镜像：
   ```bash
   sudo mount -o loop ~/practice.img ~/mnt_test
   ```
5. 确认挂载成功：
   ```bash
   mount | grep mnt_test
   df -h ~/mnt_test
   ```
6. 在挂载点内写入一个测试文件：
   ```bash
   echo "hola desde el filesystem montado" > ~/mnt_test/test.txt
   cat ~/mnt_test/test.txt
   ```
7. 卸载（unmount）该文件系统：
   ```bash
   sudo umount ~/mnt_test
   ```
8. 卸载后再次查看该目录：
   ```bash
   ls ~/mnt_test
   ```

**理解检查：**
1. 第 8 步执行 `ls ~/mnt_test` 之后，为什么看不到 `test.txt` 了？它的数据丢失了吗？
2. 如果你重新执行第 4 步的 `mount` 命令，`test.txt` 会不会重新出现？为什么？
3. `mount -o loop` 中的 `loop` 是什么意思，它和挂载一个真实的 U 盘（USB device）有什么本质区别与相似之处？

---

## 练习 7：区分 `df` 与 `du`

1. 查看整个系统各文件系统的空间占用：
   ```bash
   df -h
   ```
2. 查看某个具体目录（例如你的 home directory）下各子目录占用的空间：
   ```bash
   du -h --max-depth=1 ~
   ```
3. 只查看总大小：
   ```bash
   du -sh ~
   ```

**理解检查：**
1. `df` 统计的是什么层面的信息，`du` 统计的又是什么层面的信息？
2. 如果 `df -h` 显示某分区几乎已满，但你用 `du -sh` 加总该分区下所有可见目录得到的数字却小得多，可能是什么原因？（提示：想想已删除但仍被进程占用的文件）

---

<details>
<summary>参考答案（点击展开）</summary>

**练习 1**
1. FHS 全称 Filesystem Hierarchy Standard，它规定了 Linux 系统中标准目录（如 `/etc`、`/bin`、`/var`）应该存放什么类型的数据，使不同发行版之间的目录结构保持一致。
2. 遵循统一标准可以让软件包、脚本和系统管理员在任何发行版上都能用同样的路径假设找到配置文件、可执行文件、日志文件等，极大提高了兼容性和可维护性。

**练习 2**
1. `/etc` 里几乎全部是纯文本的配置文件（configuration files），而不是可执行的二进制程序。
2. 每个用户账户通常对应 `/home` 下的一个子目录，例如 `/home/alice`、`/home/bob`。
3. `/var` 存放会在系统运行过程中不断变化的数据（日志、缓存、邮件队列、数据库文件等），而 `/etc` 存放的是相对静态的系统配置，只有管理员手动修改时才会变化。

**练习 3**
1. `/proc` 下以数字命名的目录对应系统中每一个正在运行的 process，目录名就是该进程的 PID。
2. 文件大小显示为 0 说明 `/proc` 不是存储在磁盘上的真实文件，而是内核（kernel）在你读取时实时生成的虚拟文件系统（virtual filesystem），用于以文件接口的方式暴露内核和进程的运行时信息。
3. 不会存在。因为 shell 进程结束后，该 PID 不再对应任何运行中的 process，内核不会再生成这个虚拟目录。

**练习 4**
1. `b` 表示 block device（以数据块为单位读写，如硬盘、分区），`c` 表示 character device（以字符流为单位读写，如终端、`/dev/null`）。两者最主要区别在于数据传输的方式和是否支持随机寻址（block device 支持随机访问，character device 通常是顺序流）。
2. `/dev/null` 会直接丢弃所有写入它的数据，从不保存，因此读不出任何内容。它常用于丢弃不需要的命令输出（如 `command > /dev/null`）。
3. `/dev/null` 丢弃所有写入数据、读取时立即返回空（EOF）；`/dev/zero` 则相反，读取时会不断提供无限的 `0x00` 字节流，常用于生成指定大小的空白文件或清零数据。

**练习 5**
1. `-h` 表示以人类可读格式显示大小（如 GB、MB），`-T` 表示额外显示每个挂载点的文件系统类型（如 ext4、xfs、tmpfs）。
2. Mount point 是把某个存储设备的文件系统"挂接"到目录树中某一个目录上的位置。Linux 用单一的目录树统一管理所有设备，是因为其设计哲学是"一切皆文件"，用户和程序不需要关心数据物理上存放在哪个设备，只需要通过统一的路径访问。

**练习 6**
1. 数据没有丢失，仍然完整保存在 `~/practice.img` 这个镜像文件内部。卸载（`umount`）之后，`~/mnt_test` 又变回一个普通的空目录，之前挂载在其上的文件系统内容自然不可见了。
2. 会重新出现。因为 `test.txt` 是写入到 `practice.img` 内部的文件系统里的，只要重新执行 `mount` 命令把这个镜像挂载回同一个挂载点，其内容就会重新显现。
3. `loop` 表示使用 loop device，把一个普通文件模拟成一块块设备（block device）来对待。挂载 U 盘时，内核直接把物理设备识别为 block device 挂载；而这里是先让内核把一个文件"伪装"成 block device，再执行同样的挂载流程——挂载之后对用户来说使用方式完全相同，区别只在于底层数据实际存放在文件里还是物理存储介质上。

**练习 7**
1. `df` 统计的是文件系统（filesystem）层面的空间占用，反映整个分区/挂载点的已用与可用空间；`du` 统计的是具体目录或文件层面的空间占用，反映某个路径下实际数据占用了多少空间。
2. 常见原因是有进程仍然打开着一个已经被删除（deleted）的文件的文件描述符（file descriptor）：该文件已经从目录树中不可见，`du` 无法统计到它，但内核尚未真正释放其占用的磁盘块，因此 `df` 依然会把这部分空间计为已使用，直到持有该文件描述符的进程结束或关闭该文件。

</details>