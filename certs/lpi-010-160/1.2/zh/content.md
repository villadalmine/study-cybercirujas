# 1.2 主流开源应用（Major Open Source Applications）

*考试权重：2*

## 学习目标

完成本节学习后，你应该能够：

- 说出各类场景（desktop、server、mobile、cloud）下常见的开源应用及其对应的商业替代品
- 理解 office productivity、web browser、email client、graphics 等桌面软件的开源方案
- 了解 web server、database、mail server、DNS、file sharing 等服务器端开源软件
- 了解 virtualization 与 cloud computing 领域的主流开源项目
- 知道常见的开源开发语言，以及包管理（package management）的基本概念

## 桌面应用（Desktop Applications）

开源桌面软件通常是对应商业软件的直接替代品（drop-in replacement），在功能上高度相似，但源代码公开、可自由修改分发。

| 用途 | 开源方案 | 常见商业对照 |
|---|---|---|
| Office suite | LibreOffice（Writer、Calc、Impress） | Microsoft Office |
| Web browser | Firefox、Chromium | Google Chrome、Microsoft Edge |
| Email client | Thunderbird、Evolution | Microsoft Outlook |
| 图像编辑（raster） | GIMP | Adobe Photoshop |
| 矢量绘图（vector） | Inkscape | Adobe Illustrator |
| 桌面环境（Desktop Environment） | GNOME、KDE Plasma、Xfce | Windows Shell、macOS Aqua |

在大多数发行版中，可以直接用包管理器安装这些软件，例如：

```bash
$ sudo apt install libreoffice firefox thunderbird gimp
```

在 Fedora / RHEL 系发行版上则使用 `dnf`：

```bash
$ sudo dnf install libreoffice firefox thunderbird gimp
```

## 服务器应用（Server Applications）

服务器端的开源软件是互联网基础设施的核心，几乎所有大型网站背后都能找到它们的身影。

- **Web server**：Apache HTTP Server（`httpd`）、NGINX
- **Database**：MySQL / MariaDB、PostgreSQL
- **Mail server**：Postfix、Sendmail、Dovecot（IMAP/POP3）
- **DNS server**：BIND（Berkeley Internet Name Domain）
- **File/print sharing**：Samba（与 Windows 网络互通）、CUPS（打印）
- **DHCP**：ISC DHCP、Kea

以 Apache HTTP Server 为例，安装并检查其运行状态：

```bash
$ sudo dnf install httpd
$ sudo systemctl start httpd
$ sudo systemctl status httpd
● httpd.service - The Apache HTTP Server
     Loaded: loaded (/usr/lib/systemd/system/httpd.service; enabled)
     Active: active (running) since ...
```

用 `curl` 验证服务是否响应：

```bash
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: Apache/2.4.57 (Fedora)
```

MySQL / MariaDB 客户端连接示例：

```bash
$ mysql -u root -p -e "SHOW DATABASES;"
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
+--------------------+
```

这些服务器软件常常组合使用，形成经典的 **LAMP stack**（Linux、Apache、MySQL/MariaDB、PHP/Perl/Python），是开源 Web 架构的代表性组合，也是考试中经常出现的概念。

## 虚拟化与云计算（Virtualization and Cloud Computing）

- **Hypervisor / Virtualization**：
  - KVM（Kernel-based Virtual Machine）——内建于 Linux 内核的虚拟化技术
  - Xen——独立的开源 hypervisor
  - QEMU——常与 KVM 搭配用作硬件模拟层
- **容器化（Containerization）**：
  - Docker——目前最流行的容器引擎
  - Kubernetes（K8s）——容器编排平台，用于管理大规模容器集群
- **Cloud 平台**：
  - OpenStack——开源的 Infrastructure as a Service（IaaS）平台

用 `virsh` 查看基于 KVM 的虚拟机列表：

```bash
$ virsh list --all
 Id   Name       State
--------------------------
 1    ubuntu-vm  running
```

用 Docker 运行一个容器：

```bash
$ docker run hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

## 移动操作系统（Mobile Operating Systems）

**Android** 是基于 Linux kernel 构建的移动操作系统，由 Open Handset Alliance 发起、目前主要由 Google 维护其开源核心（Android Open Source Project，AOSP）。虽然多数设备预装了闭源的 Google 服务组件（如 Google Play），但 Android 的底层（内核、部分系统库）仍然遵循开源许可证发布。

与之对应的开源应用生态还包括 **F-Droid**——一个专门收录自由/开源 Android 应用的软件仓库，是 Google Play 的开源替代品。

## 开发语言与工具（Development Languages and Tools）

Linux 平台上的应用开发大量依赖开源编程语言与工具链，常见的包括：

- **脚本语言**：Perl、Python、PHP、Ruby
- **编译型/托管语言**：Java（OpenJDK 是其开源实现）、Go
- **版本控制**：Git（配合 GitHub/GitLab/Gitea 等开源或商业托管平台）

示例：查看系统中默认安装的 Python 版本

```bash
$ python3 --version
Python 3.11.4
```

## 包管理简介（Package Management Awareness）

不同发行版使用不同的包管理系统来分发和维护开源应用，这也是 Linux 生态多样性的体现：

| 发行版系列 | 包管理工具 | 包格式 |
|---|---|---|
| Debian / Ubuntu | `apt`、`dpkg` | `.deb` |
| Fedora / RHEL / CentOS | `dnf`、`rpm` | `.rpm` |
| Arch Linux | `pacman` | `.pkg.tar.zst` |

```bash
$ apt search libreoffice
$ dnf list installed | grep firefox
```

## 常见误区

- **误区**：开源软件 = 免费但功能弱。
  实际上许多开源软件（如 LibreOffice、GIMP、Kubernetes）在各自领域是行业事实标准，被大量企业和云服务商采用。
- **误区**：Android 完全开源。
  实际上 AOSP 核心是开源的，但绝大多数商用设备还捆绑了闭源的 Google Mobile Services（GMS）。

## Referencias

- LPI Learning Materials – Topic 1.2: <https://learning.lpi.org/en/learning-materials/010-160/1/1.2/>
- LibreOffice 官方站点: <https://www.libreoffice.org/discover/libreoffice/>
- GIMP Documentation: <https://www.gimp.org/docs/>
- Mozilla Firefox: <https://www.mozilla.org/en-US/firefox/>
- Apache HTTP Server Documentation: <https://httpd.apache.org/docs/>
- NGINX Documentation: <https://nginx.org/en/docs/>
- MariaDB Knowledge Base: <https://mariadb.com/kb/en/>
- PostgreSQL Documentation: <https://www.postgresql.org/docs/>
- Samba Documentation: <https://www.samba.org/samba/docs/>
- Postfix Documentation: <https://www.postfix.org/documentation.html>
- Docker Documentation: <https://docs.docker.com/>
- KVM (Kernel-based Virtual Machine): <https://www.linux-kvm.org/page/Main_Page>
- OpenStack Documentation: <https://docs.openstack.org/>
- Android Open Source Project: <https://source.android.com/>
- F-Droid: <https://f-droid.org/>
- Python Documentation: <https://docs.python.org/3/>