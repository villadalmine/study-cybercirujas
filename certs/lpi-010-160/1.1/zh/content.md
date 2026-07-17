# 1.1 Linux 的演进与流行操作系统（Linux Evolution and Popular Operating Systems）

**考试权重：** 2

## 学习目标

- 了解 Linux 的起源与发展历程
- 理解 **kernel**、**GNU** 工具与 **distribution**（发行版）之间的关系
- 认识主流发行版家族及其典型代表
- 了解 Linux 在服务器、云计算、嵌入式设备与移动端（Android）中的应用

---

## 1. Linux 的起源与演进

### 1.1 从 Unix 到 Linux

Linux 的历史与 **Unix** 密不可分。Unix 诞生于 1969 年的贝尔实验室（Bell Labs），由 Ken Thompson 和 Dennis Ritchie 等人开发。Unix 确立了许多至今仍在使用的设计理念：多用户（multi-user）、多任务（multitasking）、"一切皆文件"（everything is a file）以及由小工具组合完成复杂任务的哲学。

由于 Unix 是商业软件，1983 年 Richard Stallman 发起了 **GNU Project**（GNU's Not Unix），目标是创建一个完全自由（free software）的类 Unix 操作系统。GNU 项目开发了大量核心工具，例如：

- **GCC**（GNU Compiler Collection）—— 编译器
- **Bash**（Bourne Again Shell）—— 命令行 shell
- **coreutils** —— `ls`、`cp`、`mv` 等基础命令

但 GNU 项目一直缺少一个可用的内核（kernel）。

### 1.2 Linus Torvalds 与 Linux kernel

1991 年，芬兰赫尔辛基大学的学生 **Linus Torvalds** 发布了他编写的内核，即 **Linux kernel**。他在新闻组中著名地写道，这"只是一个爱好，不会像 GNU 那样庞大和专业"。

Linux kernel 采用 **GPL**（GNU General Public License）授权发布，允许任何人自由使用、修改和再发布源代码。GNU 工具与 Linux kernel 的结合，构成了一个完整可用的操作系统——因此有人称之为 **GNU/Linux**。

关键时间线：

| 年份 | 事件 |
|------|------|
| 1969 | Unix 在 Bell Labs 诞生 |
| 1983 | Richard Stallman 发起 GNU Project |
| 1991 | Linus Torvalds 发布 Linux kernel 0.01 |
| 1992 | Linux kernel 采用 GPL 许可证 |
| 1993 | Debian 与 Slackware 发行版出现 |
| 2008 | 基于 Linux kernel 的 Android 1.0 发布 |

> **考点提示：** 要区分清楚——**Linux 严格来说只是 kernel**；日常所说的"Linux 操作系统"实际上是 kernel + GNU 工具 + 其他软件的集合，即发行版（distribution）。

---

## 2. 什么是发行版（Distribution）

**Distribution**（常缩写为 **distro**）是将 Linux kernel、GNU 工具、包管理器（package manager）、桌面环境（desktop environment）以及应用软件打包在一起、可直接安装使用的完整操作系统。

不同发行版的主要差异在于：

- **包管理系统：** 如 `.deb`（Debian 系）与 `.rpm`（Red Hat/SUSE 系）
- **发布模式：** 固定版本（fixed release，如 Ubuntu 24.04）或滚动更新（rolling release，如 Arch Linux）
- **支持周期：** 是否提供 **LTS**（Long Term Support，长期支持）版本
- **目标用户：** 企业服务器、桌面用户、开发者或嵌入式设备

### 2.1 主要发行版家族

**Debian 家族（使用 `.deb` 包与 APT 包管理器）**

- **Debian**：完全由社区驱动，以稳定性著称
- **Ubuntu**：由 Canonical 公司维护，基于 Debian，桌面与云端都很流行，每两年发布一个 LTS 版本
- **Linux Mint**：基于 Ubuntu，面向桌面新手
- **Raspberry Pi OS**：为 Raspberry Pi 单板计算机优化的 Debian 衍生版

**Red Hat 家族（使用 `.rpm` 包与 DNF/YUM 包管理器）**

- **RHEL**（Red Hat Enterprise Linux）：商业企业级发行版，提供付费支持
- **Fedora**：由 Red Hat 赞助的社区版，新技术的"试验田"
- **CentOS Stream**：位于 Fedora 与 RHEL 之间的滚动预览版
- **Rocky Linux / AlmaLinux**：与 RHEL 二进制兼容的免费替代品

**SUSE 家族（使用 `.rpm` 包与 Zypper 包管理器）**

- **SLES**（SUSE Linux Enterprise Server）：商业企业级发行版
- **openSUSE**：社区版，提供 Leap（固定版本）与 Tumbleweed（滚动更新）

**独立发行版**

- **Arch Linux**：滚动更新、高度可定制，面向进阶用户
- **Gentoo**：软件从源代码（source code）编译安装
- **Alpine Linux**：极为精简，广泛用于容器（container）镜像

### 2.2 查看当前系统的发行版信息

`/etc/os-release` 文件记录了发行版信息：

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.1 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.1 LTS"
VERSION_ID="24.04"
```

`uname` 命令显示 kernel 版本信息：

```bash
$ uname -r
6.8.0-45-generic

$ uname -a
Linux server01 6.8.0-45-generic #45-Ubuntu SMP x86_64 GNU/Linux
```

许多发行版还提供 `lsb_release` 命令：

```bash
$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.1 LTS
Release:        24.04
Codename:       noble
```

---

## 3. Linux 的应用场景

### 3.1 服务器与云计算

Linux 是服务器领域的绝对主流：绝大多数网站服务器、数据库服务器和超级计算机（TOP500 榜单上 100% 的超级计算机）都运行 Linux。主要云平台（AWS、Google Cloud、Microsoft Azure）上的虚拟机大多数也是 Linux 实例。容器技术（**Docker**、**Kubernetes**）同样构建在 Linux kernel 的特性之上。

### 3.2 嵌入式系统（Embedded Systems）

Linux 可裁剪、免授权费的特点使其成为嵌入式设备的首选，例如：

- 路由器与网络设备（如 **OpenWrt** 固件）
- 智能电视、机顶盒
- 车载娱乐系统
- **Raspberry Pi** 等单板计算机（single-board computer），广泛用于教育与物联网（IoT）项目

### 3.3 移动设备：Android

**Android** 是全球市场份额最大的移动操作系统，其底层使用 **Linux kernel**，但用户空间（userspace）与传统发行版差异很大：它不使用 GNU 工具集，应用运行在 **ART**（Android Runtime）之上。由 Google 主导开发，核心部分以 **AOSP**（Android Open Source Project）的形式开源。

### 3.4 桌面

Linux 桌面份额相对较小，但持续增长。常见桌面环境包括 **GNOME**、**KDE Plasma**、**Xfce** 等。同一发行版通常可以自由更换桌面环境。

---

## 4. 与其他操作系统的对比

| 操作系统 | 类型 | 说明 |
|----------|------|------|
| **Linux** | 开源，类 Unix | kernel 采用 GPL 许可证，发行版众多 |
| **Windows** | 闭源商业软件 | 桌面市场主流；Windows Server 用于企业环境 |
| **macOS** | 闭源商业软件 | 基于 **Darwin**（含 BSD 组件），经 **UNIX 03** 认证的真正 Unix 系统 |
| **BSD 家族** | 开源，Unix 直系后裔 | 包括 **FreeBSD**、**OpenBSD**、**NetBSD**；使用宽松的 BSD License，而非 GPL |

> **考点提示：** macOS 与 BSD 是 Unix 的直接后裔；Linux 是"类 Unix"（Unix-like）系统——从零编写、并非源自 Unix 源代码。BSD License 与 GPL 的核心区别：GPL 要求衍生作品同样开源（copyleft），BSD License 则允许闭源使用。

---

## 5. 版本与支持周期

选择发行版时需要理解两种发布模式：

- **Fixed release（固定版本）：** 定期发布带版本号的快照，如 Ubuntu 24.04、Debian 12。企业环境偏好此模式，尤其是 **LTS** 版本（Ubuntu LTS 提供 5 年支持，RHEL 提供 10 年支持）。
- **Rolling release（滚动更新）：** 没有大版本概念，软件包持续更新到最新，如 Arch Linux、openSUSE Tumbleweed。适合希望始终使用最新软件的用户。

Linux kernel 本身也有版本体系，可在 [kernel.org](https://www.kernel.org) 查看当前的稳定版（stable）与长期支持版（longterm/LTS）。

---

## 小结

- Linux 诞生于 1991 年，由 Linus Torvalds 编写 kernel，与 GNU 工具结合构成完整操作系统
- **Distribution = Linux kernel + GNU 工具 + 包管理器 + 应用软件**
- 三大主要家族：**Debian 系**（Debian、Ubuntu、Mint）、**Red Hat 系**（RHEL、Fedora、Rocky）、**SUSE 系**（SLES、openSUSE）
- Linux 主导服务器、云、超级计算机与嵌入式领域；**Android** 基于 Linux kernel
- 使用 `cat /etc/os-release`、`uname -r`、`lsb_release -a` 查看系统信息

---

## 参考资料（References）

- LPI 官方学习材料 — Topic 1.1: [https://learning.lpi.org/en/learning-materials/010-160/1/1.1/](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)
- Linux kernel 官方网站: [https://www.kernel.org](https://www.kernel.org)
- GNU Project: [https://www.gnu.org/gnu/gnu.html](https://www.gnu.org/gnu/gnu.html)
- Debian: [https://www.debian.org](https://www.debian.org) · Ubuntu: [https://ubuntu.com](https://ubuntu.com)
- Fedora: [https://fedoraproject.org](https://fedoraproject.org) · openSUSE: [https://www.opensuse.org](https://www.opensuse.org)
- Android Open Source Project (AOSP): [https://source.android.com](https://source.android.com)