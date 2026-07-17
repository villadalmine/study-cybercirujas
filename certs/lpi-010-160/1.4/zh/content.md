# 1.4 ICT Skills and Working in Linux

## 引言

本主题考察候选人在 Linux 环境中完成基础 ICT（Information and Communication Technology）任务的能力，包括理解计算机硬件的基本组成、掌握 command line 的基本语法与求助方式、了解 cloud computing 与 virtualization 的基本概念，以及在使用计算机和互联网时应遵循的安全最佳实践（best practices）。这是 Linux Essentials 考试中偏"通识"的一个主题，考查的不是某个具体命令的高级用法,而是从业者应具备的基本素养。

---

## 一、计算机硬件基础知识

理解硬件与软件的区别，是使用任何操作系统的前提。

- **CPU（Central Processing Unit）**：负责执行指令、进行运算，常被称为计算机的"大脑"。
- **RAM（Random Access Memory）**：易失性（volatile）内存，用于临时存放正在运行的程序和数据，断电后数据丢失。RAM 越大，系统可同时处理的任务/数据量通常越多。
- **storage device（存储设备）**：非易失性（non-volatile）设备，如 HDD（Hard Disk Drive）、SSD（Solid State Drive）、USB flash drive，用于长期保存数据，断电后数据不会丢失。
- **motherboard（主板）**：连接 CPU、RAM、storage 与其他外设的电路板。
- **peripheral devices（外围设备）**：如 keyboard、mouse、monitor、printer，通过 USB、HDMI 等接口与主机连接。

理解 RAM 与 storage 的区别，是理解"为什么关机会丢失未保存的数据，但硬盘里的文件不会消失"的关键，也是后续学习 Linux 文件系统与进程管理的基础。

在 Linux 中可以用命令快速查看部分硬件信息，例如：

```
$ free -h
              total        used        free      shared  buff/cache   available
Mem:          7.5Gi       2.1Gi       3.0Gi       211Mi       2.4Gi       5.0Gi
Swap:         2.0Gi          0B       2.0Gi

$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        50G   18G   30G  38% /
```

`free -h` 显示的是 RAM（内存）使用情况，`df -h` 显示的是 storage（磁盘）的使用情况——两者是不同的资源，考试中容易混淆考查。

---

## 二、Command Line 基本语法

Linux 的 command line（也称 shell 或 CLI, Command Line Interface）遵循一个通用的语法结构：

```
command [options] [arguments]
```

- **command**：要执行的程序或内建命令名称。
- **options**（也叫 flags/switches）：修改命令行为，通常以 `-`（short option）或 `--`（long option）开头。
- **arguments**：命令作用的对象，例如文件名、目录名。

示例：

```
$ ls -l /home
```

这里 `ls` 是 command，`-l` 是 option（以长格式列出），`/home` 是 argument（要列出的目录）。

多个 short options 通常可以合并书写：

```
$ ls -la
```

等价于 `ls -l -a`。

命令的执行结果由**环境变量** `PATH` 决定命令在哪些目录中被查找：

```
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

如果输入的命令不在 `$PATH` 列出的任何目录中，shell 会报错：

```
$ foobar
bash: foobar: command not found
```

---

## 三、命令行求助资源

Linux 提供了多种方式在不离开 command line 的情况下获取帮助，这是本主题的核心考点之一。

### 1. `--help`

大多数命令支持 `--help` 选项，快速输出用法摘要：

```
$ mkdir --help
Usage: mkdir [OPTION]... DIRECTORY...
Create the DIRECTORY(ies), if they do not already exist.

  -m, --mode=MODE  set file mode (as in chmod), not a=rwx - umask
  -p, --parents    no error if existing, make parent directories as needed
      --help     display this help and exit
```

### 2. `man`（manual page）

`man` 命令查看命令的完整手册页，内容比 `--help` 更详细，通常还包含 examples 和 related commands（SEE ALSO）章节：

```
$ man ls
LS(1)                     User Commands                    LS(1)

NAME
       ls - list directory contents
SYNOPSIS
       ls [OPTION]... [FILE]...
...
```

manual page 分为多个 section（章节），例如 section 1 是用户命令，section 5 是文件格式，section 8 是系统管理命令。当同一名称存在于多个 section 时，可以指定 section 号：

```
$ man 5 passwd
```

查看 `/etc/passwd` 文件格式，而不是 `passwd` 命令本身。

### 3. `whatis` 与 `apropos`

- `whatis`：只显示命令的一行简短描述。
- `apropos`：按关键字搜索所有 manual page 的描述，用于"我不知道命令叫什么名字"的场景。

```
$ whatis passwd
passwd (1)           - change user password

$ apropos "change password"
passwd (1)           - change user password
chpasswd (8)         - update passwords in batch mode
```

### 4. `info`

`info` 提供比 `man` 更结构化、可导航的文档系统（尤其对 GNU 工具），适合查阅较长的参考手册：

```
$ info coreutils
```

---

## 四、文件管理：GUI 与 command line

Linux 桌面环境通常提供 file manager（如 GNOME Files、Dolphin）用图形界面浏览文件，而 command line 则通过 `ls`、`cp`、`mv`、`rm` 等命令完成相同的任务。两者操作的是同一份文件系统，只是交互方式不同——这也是为什么 Linux Essentials 强调候选人应同时熟悉 GUI 概念与 CLI 操作，而不是只会其中一种。

---

## 五、Cloud 与 Virtualization 基本概念

- **virtualization（虚拟化）**：在一台物理主机上通过 hypervisor 运行多个相互隔离的 virtual machine（VM），每个 VM 可以运行独立的操作系统。
- **container（容器）**：比 VM 更轻量的隔离技术（如 Docker），容器共享宿主机内核，但拥有独立的进程、文件系统视图。
- **cloud computing**：按需通过网络获取计算资源（服务器、存储、网络）的模式，常见服务模型有：
  - **IaaS**（Infrastructure as a Service）：提供虚拟机、存储、网络等基础设施；
  - **PaaS**（Platform as a Service）：提供开发和部署应用的平台；
  - **SaaS**（Software as a Service）：直接提供可用的软件应用（如网页邮箱）。

理解这些概念有助于认识到，如今大量 Linux 系统运行在 VM 或 container 中，而不仅仅是物理机器上。

---

## 六、应用软件类型

- **desktop application**：安装并运行在本地计算机上的软件，例如 LibreOffice、GIMP。
- **server application**：运行在服务器上、通常通过网络对外提供服务的软件，例如 Apache HTTP Server、MySQL。
- **mobile application**：运行在智能手机/平板等移动设备上的软件。
- **web application**：通过浏览器访问、逻辑运行在服务器端的软件，例如网页版邮箱、在线文档编辑器。

常见办公与通信类应用还包括：word processor（文字处理，如 LibreOffice Writer）、spreadsheet（电子表格，如 LibreOffice Calc）、web browser（浏览器，如 Firefox）、email client（邮件客户端，如 Thunderbird）。

---

## 七、ICT 安全最佳实践

这是本主题另一个重点考查方向：候选人应了解基本的信息安全意识，而非具体的加密算法实现。

### 1. 密码安全（password security）

- 使用足够长且包含大小写字母、数字、符号的强密码，避免使用生日、姓名等易猜测信息。
- 不同账户使用不同密码，避免"一处泄露、处处遭殃"。
- 定期更换密码，尤其是怀疑账户可能已泄露时。
- 使用 `passwd` 命令在 Linux 中修改自己账户的密码：

```
$ passwd
Changing password for user alice.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

### 2. 加密（encryption）

- **静态数据加密（data at rest）**：对硬盘或文件本身加密，防止设备丢失后数据被读取。
- **传输中加密（data in transit）**：如使用 HTTPS 而非 HTTP 访问网站，使用 SSH 而非 telnet 远程登录，防止网络传输过程中数据被窃听。

### 3. 恶意软件与防护

- **malware（恶意软件）**：包括 virus（病毒）、worm（蠕虫）、trojan（木马）、ransomware（勒索软件）等，可能窃取数据或破坏系统。
- **firewall（防火墙）**：过滤网络流量，阻止未授权的连接，是网络安全的基本防线之一。

### 4. 日常良好习惯（ICT good practice）

- 离开设备时锁屏（lock the screen），避免他人未经授权使用你已登录的账户。
- 不随意点击不明来源的链接或附件，警惕 phishing（网络钓鱼）。
- 对敏感数据做好 backup（备份），防止硬件故障或勒索软件导致数据永久丢失。
- 及时安装系统与软件更新（updates/patches），修补已知安全漏洞。

---

## 小结

Topic 1.4 覆盖的内容看似分散，但核心是一条主线：**作为一名合格的 ICT 从业者/Linux 使用者，既要能通过 command line 高效地自助查找帮助信息（`man`、`--help`、`whatis`、`apropos`、`info`），也要具备基本的硬件、云计算与安全常识**，从而在实际工作和考试中都能做出正确判断。

---

## Referencias

- LPI Learning Materials — 010-160, Topic 1.4: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- `man(1)` manual page (man7.org): https://man7.org/linux/man-pages/man1/man.1.html
- GNU Coreutils Manual: https://www.gnu.org/software/coreutils/manual/html_node/index.html