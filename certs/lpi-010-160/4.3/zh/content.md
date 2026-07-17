# 4.3 Where Data is Stored

## 概述（Overview）

Linux 系统并不是把所有文件随意堆放在一起，而是遵循一套名为 **Filesystem Hierarchy Standard (FHS)** 的规范来组织目录结构。理解 FHS 可以让你在任何 Linux 发行版上迅速找到配置文件（configuration files）、日志文件（log files）、用户数据（user data）以及运行中进程（running processes）的相关信息，而不需要死记每个发行版的差异。

本节重点关注三类"数据存放位置"：

1. **静态配置数据**：主要存放在 `/etc`
2. **动态运行时数据**：主要存放在 `/proc` 和 `/var`
3. **第三方 / 附加软件数据**：主要存放在 `/opt`

## Filesystem Hierarchy Standard (FHS)

FHS 由 Linux Foundation 维护，定义了根目录（root directory，`/`）下各子目录应当承担的角色。它保证了不同发行版（Ubuntu、Debian、Fedora、Rocky 等）之间的目录布局具有一致性，这样脚本、软件包和系统管理员的操作习惯才能跨发行版复用。

可以用 `man hier` 在本地查看 FHS 的概览（部分发行版需要安装 `man-pages` 包）：

```console
$ man hier
```

与本主题最相关的顶级目录：

| 目录 | 用途 |
|---|---|
| `/etc` | 系统级配置文件（system-wide configuration），纯文本，不含二进制程序 |
| `/var` | 经常变化的数据（variable data）：日志、邮件队列、缓存、数据库文件等 |
| `/proc` | 虚拟文件系统（virtual/pseudo filesystem），反映内核（kernel）和进程（process）的实时状态 |
| `/opt` | 可选的第三方软件包（optional add-on application software packages） |
| `/tmp` | 临时文件，系统重启后通常会被清空 |
| `/home` | 普通用户的主目录（home directories） |
| `/root` | 超级用户 root 的主目录（注意不是 `/home/root`） |

## /etc：系统配置的核心

`/etc` 是 "et cetera" 的缩写，存放几乎所有系统级配置文件。这些文件都是**纯文本**（plain text），可以用任意文本编辑器查看和修改。

考试中最重要的两个文件：

### /etc/passwd

保存本地用户账户信息，每行代表一个用户，字段以冒号 `:` 分隔：

```console
$ cat /etc/passwd | head -3
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000:Alice Smith,,,:/home/alice:/bin/bash
```

字段依次为：`username`（用户名）:`password placeholder`（占位符，实际密码不在此文件）:`UID`:`GID`:`GECOS`（用户全名等描述信息）:`home directory`:`login shell`。

真正的密码哈希（password hash）保存在 `/etc/shadow` 中，只有 root 能读取，这是出于安全考虑：

```console
$ sudo cat /etc/shadow | head -1
root:$6$abcd1234$hash...:19500:0:99999:7:::
```

### /etc/group

保存组（group）信息，格式与 `/etc/passwd` 类似：

```console
$ cat /etc/group | grep sudo
sudo:x:27:alice
```

字段为：`group name`:`password placeholder`:`GID`:`member list`（附加成员列表，以逗号分隔）。

其他常见的 `/etc` 内容示例：

```console
$ ls /etc/hostname /etc/hosts /etc/fstab /etc/resolv.conf
/etc/fstab  /etc/hostname  /etc/hosts  /etc/resolv.conf
```

- `/etc/hostname`：主机名
- `/etc/hosts`：静态主机名解析表
- `/etc/fstab`：开机自动挂载的文件系统列表（filesystem table）

## /var：会变化的数据

`/var` 存放程序运行过程中不断写入、增长的数据，与 `/etc` 中"很少改变"的配置文件形成对比。

最常用的子目录是 `/var/log`，几乎所有系统服务的日志都写在这里：

```console
$ ls /var/log
auth.log  boot.log  dpkg.log  kern.log  syslog  Xorg.0.log

$ sudo tail -5 /var/log/syslog
Jul 12 10:03:11 host systemd[1]: Started Daily apt download activities.
Jul 12 10:05:02 host CRON[2231]: (root) CMD (test -x /usr/sbin/anacron ...)
```

其他重要子目录：

| 目录 | 内容 |
|---|---|
| `/var/log` | 系统与应用日志 |
| `/var/spool` | 等待处理的队列数据，如打印任务、邮件队列（mail queue） |
| `/var/cache` | 应用程序缓存数据，如 `apt`/`dnf` 的软件包缓存 |
| `/var/tmp` | 与 `/tmp` 类似，但重启后**不会**被清空，用于需要跨重启保留的临时文件 |

## /proc：内核与进程的窗口

`/proc` 是一个**虚拟文件系统（virtual filesystem）**——它不占用磁盘空间，其中的"文件"是内核在你读取时动态生成的，用来反映内核（kernel）状态和当前运行进程（running processes）的实时信息。

查看 CPU 信息：

```console
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz
```

查看内存信息：

```console
$ cat /proc/meminfo | head -3
MemTotal:       16332180 kB
MemFree:         2103456 kB
MemAvailable:    9876543 kB
```

每个进程在 `/proc` 下都有一个以其 **PID（Process ID）** 命名的子目录，包含该进程的详细信息，例如：

```console
$ echo $$
4821
$ ls /proc/4821
cmdline  cwd  environ  exe  fd  maps  status  ...

$ cat /proc/4821/status | head -2
Name:   bash
State:  S (sleeping)
```

由于 `/proc` 不是真实磁盘数据，`ls -l` 看到的文件大小通常为 0，`df`/`du` 也不会将其计入磁盘占用。

## /opt：附加软件包

`/opt`（optional）用于存放不通过发行版官方包管理器安装的第三方商业软件或独立软件包，通常每个软件占用一个独立子目录：

```console
$ ls /opt
google  spotify  vmware
```

这与 `/usr` 下由包管理器统一维护的软件形成对比——`/opt` 中的软件通常自包含（self-contained），不依赖系统共享库的严格版本匹配。

## /tmp 与 /home、/root

- `/tmp`：任何用户都可写入的临时目录，系统重启（reboot）或按发行版策略定期清理时内容会被删除。
- `/home/<username>`：普通用户的个人数据和用户级配置文件（如 `~/.bashrc`）所在位置。
- `/root`：root 用户专属主目录，出于历史和安全原因单独位于根目录下，而不在 `/home` 内。

```console
$ echo $HOME
/home/alice

$ sudo -i
# echo $HOME
/root
```

## 小结

| 目录 | 数据类型 | 是否常变化 |
|---|---|---|
| `/etc` | 系统配置文件 | 很少变化 |
| `/var/log`, `/var/spool` | 日志、队列等运行数据 | 经常变化 |
| `/proc` | 内核/进程实时状态（虚拟文件系统） | 实时动态 |
| `/opt` | 第三方附加软件 | 安装时变化 |
| `/tmp`, `/var/tmp` | 临时文件 | 频繁变化，重启后行为不同 |
| `/home`, `/root` | 用户个人数据 | 按用户使用变化 |

## 参考文献（References）

- LPI Learning Materials — 010-160 4.3 Where Data is Stored: https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Filesystem Hierarchy Standard (FHS) 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html
- Linux man-pages project — `hier(7)`: https://man7.org/linux/man-pages/man7/hier.7.html
- Linux man-pages project — `passwd(5)`: https://man7.org/linux/man-pages/man5/passwd.5.html
- Linux man-pages project — `proc(5)`: https://man7.org/linux/man-pages/man5/proc.5.html