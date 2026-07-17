# LPI Linux Essentials (010-160, v1.6) — 主题 3.1: Archiving Files on the Command Line

> 参考来源：https://learning.lpi.org/en/learning-materials/010-160/3/3.1/ （本练习为原创改写，仅作参考，未直接复制原文）

本主题考查你在 command line 上使用 `tar`、`cpio`、`dd` 以及 `gzip`/`bzip2`/`xz` 等压缩工具进行 archiving 和 compression 的能力。请在一个可以随意创建/删除文件的目录（例如 `~/lpi-lab`）中完成以下练习。

---

## 练习 1：准备实验环境并创建你的第一个 tar archive

1. 创建一个专用的实验目录，并进入其中：
   ```bash
   mkdir -p ~/lpi-lab/project
   cd ~/lpi-lab/project
   ```
2. 在 `project` 目录中创建几个示例文件：
   ```bash
   echo "hello linux" > notes.txt
   echo "config data" > settings.conf
   mkdir docs
   echo "readme content" > docs/readme.md
   ```
3. 回到上一级目录，把整个 `project` 目录打包成一个 tar archive：
   ```bash
   cd ~/lpi-lab
   tar -cvf project.tar project/
   ```
4. 用 `ls -l` 查看生成的 `project.tar` 文件大小，并与 `du -sh project/` 得到的原目录大小做对比。

**问题：**
- 命令 `tar -cvf project.tar project/` 中，`c`、`v`、`f` 三个选项分别代表什么作用？
- 为什么打包后的 `project.tar` 文件大小通常会略大于原目录中所有文件大小之和？

---

## 练习 2：查看 archive 内容而不解压

1. 使用 `tar` 的 table-of-contents 模式查看 `project.tar` 里包含哪些文件，但不要真正解压：
   ```bash
   tar -tvf project.tar
   ```
2. 只列出 archive 中 `docs/` 目录下的内容：
   ```bash
   tar -tvf project.tar project/docs
   ```
3. 观察输出中每一行显示的 permissions、owner/group、文件大小和路径信息。

**问题：**
- `tar` 命令中的 `t` 选项（table of contents）与 `x`（extract）选项的区别是什么？
- 如果 archive 文件非常大（几个 GB），只查看内容而不解压有什么实际意义？

---

## 练习 3：解压 archive 到指定目录

1. 创建一个用于解压的目标目录：
   ```bash
   mkdir -p ~/lpi-lab/restore
   ```
2. 使用 `-C` 选项把 `project.tar` 解压到该目录，而不是当前目录：
   ```bash
   tar -xvf project.tar -C ~/lpi-lab/restore
   ```
3. 验证解压结果：
   ```bash
   diff -r ~/lpi-lab/project ~/lpi-lab/restore/project
   ```
4. 只从 archive 中提取单个文件 `project/notes.txt`：
   ```bash
   cd ~/lpi-lab
   tar -xvf project.tar project/notes.txt
   ```

**问题：**
- `tar` 的 `-C` 选项的作用是什么？如果不使用它，`tar -xvf` 默认会把文件解压到哪里？
- 步骤 3 中 `diff -r` 命令没有任何输出，说明了什么？

---

## 练习 4：结合压缩工具打包（gzip、bzip2、xz）

1. 分别使用三种压缩算法打包同一个目录，并比较结果：
   ```bash
   cd ~/lpi-lab
   tar -czvf project.tar.gz  project/
   tar -cjvf project.tar.bz2 project/
   tar -cJvf project.tar.xz  project/
   ```
2. 比较三个文件的大小：
   ```bash
   ls -lh project.tar project.tar.gz project.tar.bz2 project.tar.xz
   ```
3. 分别解压其中一个（例如 `.tar.gz`）来验证内容完整：
   ```bash
   mkdir -p ~/lpi-lab/restore-gz
   tar -xzvf project.tar.gz -C ~/lpi-lab/restore-gz
   ```

**问题：**
- 选项 `z`、`j`、`J` 分别让 `tar` 调用哪个压缩程序（`gzip`、`bzip2`、`xz`）？
- 在压缩率（文件更小）和压缩速度之间，`gzip`、`bzip2`、`xz` 大致的取舍关系是什么？

---

## 练习 5：单独使用 gzip / bzip2 / xz（不通过 tar）

1. 单独压缩一个普通文件（不打包成 archive）：
   ```bash
   cd ~/lpi-lab/project
   gzip -k notes.txt
   ls -l notes.txt notes.txt.gz
   ```
2. 解压刚才生成的 `.gz` 文件，保留原文件（`-k` = keep）：
   ```bash
   gzip -dk notes.txt.gz
   ```
3. 用 `bzip2` 和 `xz` 对同一个文件做同样的操作，并观察扩展名的变化：
   ```bash
   bzip2 -k settings.conf
   xz -k docs/readme.md
   ls -l settings.conf* docs/readme.md*
   ```

**问题：**
- `gzip`、`bzip2`、`xz` 压缩单个文件后，原文件默认会发生什么变化？`-k` 选项的作用是什么？
- 为什么 `gzip`/`bzip2`/`xz` 通常需要先用 `tar` 把多个文件合并成一个 archive，然后再压缩，而不是直接压缩整个目录？

---

## 练习 6：使用 cpio 打包文件

1. 生成一个文件名列表，作为 `cpio` 的输入：
   ```bash
   cd ~/lpi-lab
   find project -type f > filelist.txt
   cat filelist.txt
   ```
2. 使用 `cpio` 的 copy-out 模式，把列表中的文件打包为 `project.cpio`：
   ```bash
   cpio -ov < filelist.txt > project.cpio
   ```
3. 查看 `cpio` archive 中的内容（copy-out 模式加 `-t`）：
   ```bash
   cpio -tv < project.cpio
   ```
4. 把 `project.cpio` 解压（copy-in 模式）到一个新目录：
   ```bash
   mkdir -p ~/lpi-lab/restore-cpio
   cd ~/lpi-lab/restore-cpio
   cpio -idv < ~/lpi-lab/project.cpio
   ```

**问题：**
- `cpio` 与 `tar` 最大的使用方式区别是什么（`cpio` 的输入从哪里来）？
- copy-out 模式（`-o`）和 copy-in 模式（`-i`）分别对应打包还是解包？

---

## 练习 7：使用 dd 复制与备份原始数据

1. 创建一个固定大小的测试文件，模拟一个"设备"或磁盘镜像：
   ```bash
   cd ~/lpi-lab
   dd if=/dev/zero of=disk-image.img bs=1M count=10
   ```
2. 观察 `dd` 执行完毕后打印的统计信息（记录数、传输字节数、耗时）。
3. 用 `dd` 把这个镜像文件完整复制一份：
   ```bash
   dd if=disk-image.img of=disk-image-copy.img bs=1M
   ```
4. 用 `cmp` 验证两个文件内容完全一致：
   ```bash
   cmp disk-image.img disk-image-copy.img && echo "内容相同"
   ```

**问题：**
- `dd` 命令中 `if=`、`of=`、`bs=`、`count=` 分别代表什么参数？
- `dd` 与 `tar`/`cpio` 相比，在处理对象上有什么本质区别（按文件复制 vs. 按字节/块复制）？为什么这让 `dd` 也能用来备份整个磁盘分区？

---

## 练习 8：清理实验环境

1. 确认所有练习产生的文件都在 `~/lpi-lab` 下：
   ```bash
   ls -la ~/lpi-lab
   ```
2. 删除整个实验目录：
   ```bash
   rm -rf ~/lpi-lab
   ```

**问题：**
- 在删除 `~/lpi-lab` 之前，为什么先用 `ls -la` 确认目录内容是一个好习惯？

---

<details>
<summary>点击展开参考答案</summary>

**练习 1**
- `c` = create（创建新 archive）；`v` = verbose（打印处理过程中的每个文件名）；`f` = file（后面跟 archive 的文件名，几乎总是需要指定，否则 `tar` 会尝试写入默认的 tape 设备）。
- 因为 tar 格式除了文件内容外，还会为每个文件记录 header 信息（文件名、permissions、owner、时间戳等），并按 512 字节的 block 对齐填充，所以打包后的文件通常比原始数据总和略大。

**练习 2**
- `t` 只读取 archive 的 header 信息并列出其中的文件列表，不会把文件内容写到磁盘上；`x` 则会真正把文件内容释放（提取）到文件系统中。
- 对于几个 GB 的大 archive，先用 `t` 查看内容可以确认里面是否有需要的文件、避免因为解压位置或磁盘空间问题造成的浪费，也可以避免误覆盖当前目录中的同名文件。

**练习 3**
- `-C` 指定解压时先切换（change directory）到某个目录，再执行解压操作；如果不使用 `-C`，`tar -xvf` 默认会把内容解压到当前工作目录。
- 没有任何输出说明两个目录内容完全相同（`diff -r` 在没有发现差异时不产生输出），证明打包和解压过程没有丢失或损坏数据。

**练习 4**
- `z` 调用 `gzip`；`j` 调用 `bzip2`；`J` 调用 `xz`。
- 大致规律：`gzip` 压缩/解压速度最快，但压缩率相对较低；`bzip2` 压缩率比 `gzip` 高，但速度更慢；`xz` 通常能获得最高的压缩率（文件最小），但压缩过程消耗的时间和内存也最多。

**练习 5**
- 默认情况下，`gzip`/`bzip2`/`xz` 压缩后会删除原文件，只留下带压缩后缀（`.gz`/`.bz2`/`.xz`）的新文件；`-k`（keep）选项会保留原文件，同时生成压缩后的文件。
- 因为 `gzip`/`bzip2`/`xz` 本身只能压缩单个文件（不具备把多个文件/目录结构合并成一个文件的能力），所以通常的做法是先用 `tar` 把整个目录结构合并（archive）成一个文件，再对这一个文件整体做压缩，这样既保留了目录结构，又只需要压缩一次。

**练习 6**
- `tar` 通常直接对目录名或文件名参数进行操作；`cpio` 默认不接受目录名作为参数，而是从标准输入（stdin）读取一个文件名列表（常与 `find` 配合使用），然后决定要打包哪些文件。
- copy-out 模式（`-o`）用于把文件打包成 archive（对应"输出"到 archive）；copy-in 模式（`-i`）用于从 archive 中把文件解包还原到文件系统（对应从 archive 读"进"文件系统）。

**练习 7**
- `if=` 指定 input file（输入源）；`of=` 指定 output file（输出目标）；`bs=` 指定每次读写的 block size（块大小）；`count=` 指定要复制多少个这样的 block。
- `tar`/`cpio` 是按文件为单位工作的：它们理解文件系统结构（文件名、目录、permissions 等），所以只能复制"文件"这个抽象层面的东西；`dd` 是按原始字节/块为单位工作的，它不关心内容是不是文件系统，只是原样地从一个位置读取字节流写到另一个位置。正因为这种"不关心内容含义、只管字节"的特性，`dd` 才能用来对整个磁盘分区（甚至是没有文件系统或还未挂载的设备）做逐字节的镜像备份。

**练习 8**
- 删除操作（尤其是 `rm -rf`）是不可逆的；先用 `ls -la` 确认目录里都是自己练习产生的、可以安全删除的内容，是避免误删重要文件的基本习惯。

</details>