# 4.1 选择操作系统（Choosing an Operating System）

## 什么是 Operating System

Operating System（操作系统，简称 OS）是管理计算机硬件资源（CPU、内存、存储、网络设备等）并为应用程序提供统一运行环境的系统软件。用户和应用程序不需要直接操作硬件，而是通过 OS 提供的接口（system call）来使用资源。一个典型的 OS 通常包含三层：

- **Kernel（内核）**：直接管理硬件，负责进程调度（process scheduling）、内存管理（memory management）、设备驱动（device driver）等核心功能。
- **System libraries / utilities**：为上层程序提供标准化接口，例如 GNU 的 `glibc`。
- **Applications**：用户实际使用的程序，如浏览器、编辑器、shell 等。

## Kernel 与 Distribution 的区别

很多初学者容易把 "Linux" 和 "操作系统" 混淆，但严格来说 **Linux 本身只是 kernel**，由 Linus Torvalds 于 1991 年发起。仅有 kernel 是无法直接使用的，必须搭配大量的系统工具（很多来自 GNU 项目，如 `bash`、`coreutils`、`gcc`）以及应用软件，打包成一个完整可安装、可使用的系统，这个打包结果就叫 **distribution（发行版，简称 distro）**。因此更准确的说法是 **GNU/Linux**：GNU 提供用户空间工具链，Linux 提供 kernel。

常见的 distribution 分类：

| 类别 | 代表 distro | 包管理格式 |
|---|---|---|
| Debian 系 | Debian, Ubuntu, Linux Mint | `.deb`（`dpkg` / `apt`） |
| Red Hat 系 | Fedora, RHEL, CentOS Stream | `.rpm`（`rpm` / `dnf`） |
| 独立设计 | Arch Linux | `pacman` |
| 源码编译型 | Gentoo | Portage（从源码编译） |
| 不可变/容器化 | Fedora CoreOS, openSUSE MicroOS | 镜像/事务式更新 |

不同 distro 在包管理工具、默认软件、发布周期（release cycle）、目标用户（桌面 / 服务器 / 嵌入式）上各不相同，但内核都是同一个 Linux kernel（版本可能不同）。

## 查看当前系统信息（示例）

在实际选择或识别一个 Linux 系统时，常用以下命令：

查看 kernel 版本：

```console
$ uname -a
Linux debian12 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01) x86_64 GNU/Linux
```

查看具体的 distribution 信息：

```console
$ cat /etc/os-release
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
ID=debian
```

也可以用 `lsb_release`（如果已安装 `lsb-release` 包）：

```console
$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.4 LTS
Release:        22.04
Codename:       jammy
```

## Free/Open Source Software（FOSS）与专有软件

Linux distribution 大多遵循 **open source** 理念，源码公开、可自由查看、修改、再发布，常见许可证如 GPL（GNU General Public License）、MIT、Apache License。这与 Windows、macOS 等 **proprietary（专有）** 操作系统形成对比——后者源码不公开，使用受许可协议限制。开源模式带来的实际优势包括：透明的安全审计、社区驱动的快速修复、以及厂商锁定（vendor lock-in）风险较低。

## 选择 distribution 时的考量因素

- **用途**：桌面办公（如 Ubuntu、Fedora Workstation）、服务器（如 Debian、RHEL）、嵌入式设备（如 OpenWrt、Yocto 构建的定制系统）。
- **稳定性 vs 新特性**：Debian stable 更新慢但极稳定；Fedora、Arch 更新快、软件版本新，适合追新场景。
- **支持周期**：企业环境常选择 **LTS（Long Term Support）** 版本，例如 Ubuntu 22.04 LTS 提供 5 年安全更新。
- **包管理生态**：需要的软件是否在该 distro 的仓库（repository）中容易获取。
- **社区与文档**：社区规模直接影响遇到问题时能否快速找到解决方案。

## 嵌入式与其他场景中的 Linux

Linux kernel 因体积可裁剪、授权免费、驱动生态丰富，被广泛用于非传统 PC 场景，如路由器（OpenWrt）、Android 手机（基于 Linux kernel）、物联网设备等。这类场景通常使用高度定制的最小化系统，而非完整桌面 distro。

---

## 参考资料 / References

- LPI Linux Essentials 官方学习资料 4.1: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- Linux kernel 官方网站: https://www.kernel.org/
- GNU 项目: https://www.gnu.org/
- Debian 官方文档: https://www.debian.org/doc/
- DistroWatch（发行版对比）: https://distrowatch.com/