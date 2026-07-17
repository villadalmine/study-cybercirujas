# 主题 1.1 引导练习：Linux Evolution and Popular Operating Systems

> 本练习需要一台可以打开终端 (terminal) 的 Linux 系统。任何主流发行版 (distribution) 都可以：Ubuntu、Fedora、Debian、openSUSE 等。如果你还没有 Linux 环境，可以使用虚拟机 (virtual machine) 或者在线终端。

---

## 练习 1：分清 kernel 和 distribution

Linux 严格来说只是一个内核 (kernel)。我们日常安装的"Linux 系统"其实是发行版 (distribution)：kernel + GNU 工具 + 软件包管理器 (package manager) + 其他软件的组合。这个练习帮你在自己的机器上把两者区分开。

1. 打开终端，查看操作系统的内核名称：

   ```bash
   uname -s
   ```

2. 查看内核的版本号：

   ```bash
   uname -r
   ```

3. 一次性查看全部内核信息（包括硬件架构）：

   ```bash
   uname -a
   ```

4. 现在查看你的发行版信息：

   ```bash
   cat /etc/os-release
   ```

5. 对比第 2 步和第 4 步的输出：`uname -r` 显示的版本号和 `/etc/os-release` 里 `VERSION_ID` 的版本号是两回事。

**问题：**

- **1a.** `uname -s` 输出的名字是什么？它指的是 kernel 还是 distribution？
- **1b.** `/etc/os-release` 中的 `NAME` 和 `PRETTY_NAME` 字段告诉你什么信息？
- **1c.** 为什么同一个内核版本（例如 6.x）可以出现在完全不同的发行版上？

---

## 练习 2：追溯 Linux 的历史与版本演进

Linux kernel 由 Linus Torvalds 于 1991 年发布第一个版本，并采用 GPL (GNU General Public License) 授权。这个练习让你查看历史线索。

1. 查看内核编译时留下的信息，注意其中提到的编译器和构建者：

   ```bash
   cat /proc/version
   ```

2. 在浏览器中访问 Linux kernel 的官方网站 [https://www.kernel.org](https://www.kernel.org)，找到当前标记为 **stable** 和 **longterm** 的版本。

3. 把网站上的最新 stable 版本号和你机器上 `uname -r` 的输出做对比，看看你的内核落后了多少。

4. 在 `/proc/version` 的输出里找一找 "GCC" 或 "gcc" 字样——这是 GNU 项目提供的编译器。

**问题：**

- **2a.** Linux kernel 是哪一年首次公开发布的？由谁发布？
- **2b.** GNU 项目在"Linux 系统"中扮演什么角色？为什么有人主张称之为 "GNU/Linux"？
- **2c.** GPL 授权对 Linux 的普及起了什么作用？（提示：思考"任何人都可以查看、修改、再分发源代码"意味着什么。）
- **2d.** kernel.org 上的 **longterm** (LTS, Long Term Support) 内核和 **stable** 内核有什么区别？

---

## 练习 3：识别发行版家族（通过 package manager）

考试中最常考的一点：主流发行版可以按软件包管理器分成几大家族。这个练习教你用命令快速判断一台陌生机器属于哪个家族。

1. 依次运行以下命令，看哪一个存在（存在的会输出路径，不存在的会报错或无输出）：

   ```bash
   which apt   2>/dev/null && echo "Debian 家族"
   which dnf   2>/dev/null && echo "Red Hat 家族"
   which zypper 2>/dev/null && echo "SUSE 家族"
   which pacman 2>/dev/null && echo "Arch 家族"
   ```

2. 根据上一步的结果，查看底层包格式工具是否匹配：

   ```bash
   which dpkg 2>/dev/null   # Debian 家族的底层工具，包格式 .deb
   which rpm  2>/dev/null   # Red Hat / SUSE 家族的底层工具，包格式 .rpm
   ```

3. 再看一眼 `/etc/os-release` 中的 `ID_LIKE` 字段（如果有）：

   ```bash
   grep ID_LIKE /etc/os-release
   ```

   这个字段直接声明了你的发行版"派生自"哪个家族。

**问题：**

- **3a.** Ubuntu 派生自哪个发行版？它们共用什么包格式？
- **3b.** Fedora、Red Hat Enterprise Linux (RHEL)、CentOS Stream、Rocky Linux 之间是什么关系？
- **3c.** 一家企业需要付费商业支持和长生命周期，应该在 RHEL 和 Fedora 之间选哪个？为什么？
- **3d.** openSUSE 使用什么包管理器？它属于 .deb 还是 .rpm 阵营？

---

## 练习 4：嵌入式 Linux 与 Android

Linux 不只运行在服务器和桌面上——它也是 Android 的内核，并驱动着路由器、智能电视和 Raspberry Pi 这类单板计算机 (single-board computer)。

1. 如果你有一部 Android 手机：打开 **设置 → 关于手机**，找到 "内核版本" (Kernel version) 一项，记下它显示的数字。

2. 把手机上的内核版本和你 Linux 电脑上 `uname -r` 的输出放在一起对比——注意它们遵循同样的版本编号规则。

3. 在浏览器中访问 [https://www.raspberrypi.com](https://www.raspberrypi.com)，找到官方系统 Raspberry Pi OS，看看它基于哪个发行版（提示：在下载页或文档中能找到 "Debian" 字样）。

**问题：**

- **4a.** Android 使用 Linux kernel，但我们一般不把它算作"Linux distribution"，为什么？（提示：想想 GNU 工具链和 glibc。）
- **4b.** Raspberry Pi OS 基于哪个发行版家族？
- **4c.** 举出至少三类日常设备，它们很可能内部运行着嵌入式 Linux (embedded Linux)。

---

## 练习 5：生命周期 (lifecycle) 与发布模式

选择操作系统时，"能被支持多久"和"多久更新一次"是关键决策因素。

1. 查看你的发行版版本及代号：

   ```bash
   cat /etc/os-release | grep -E "VERSION=|VERSION_CODENAME"
   ```

2. 在浏览器中查询你所用发行版的支持结束日期 (EOL, End of Life)：
   - Ubuntu 用户访问 [https://ubuntu.com/about/release-cycle](https://ubuntu.com/about/release-cycle)
   - Debian 用户访问 [https://wiki.debian.org/LTS](https://wiki.debian.org/LTS)
   - Fedora 用户访问 [https://docs.fedoraproject.org/en-US/releases/](https://docs.fedoraproject.org/en-US/releases/)

3. 记下你的系统还剩多长时间的安全更新支持。

4. 思考对比：Arch Linux 采用滚动发布 (rolling release)——没有版本号，持续更新；而 Ubuntu LTS 采用固定发布 (fixed release)——每两年一个长期支持版。

**问题：**

- **5a.** Ubuntu 的 LTS 版本多久发布一次？桌面/服务器的标准支持期是多长？
- **5b.** rolling release 和 fixed release 各自的优缺点是什么？
- **5c.** 一台生产服务器 (production server) 更适合哪种发布模式？为什么？

---

## 练习 6：Linux 之外的世界

Essentials 考试也要求你了解 Linux 与其他操作系统的关系。

1. 在浏览器中访问 [https://www.freebsd.org](https://www.freebsd.org)，浏览首页对 FreeBSD 的介绍——注意它是 Unix 的直系后代，而 Linux 不是。

2. 如果你的电脑是 macOS：打开终端运行 `uname -s`，输出会是 `Darwin` 而不是 `Linux`。

3. 如果你使用 Windows 10/11：可以在 PowerShell 中运行 `wsl --list --online` 查看 WSL (Windows Subsystem for Linux) 可安装的发行版列表——微软如今也在 Windows 里内置了运行 Linux 的能力。

**问题：**

- **6a.** macOS 的内核家族和 Linux 是什么关系？它们都受了谁的影响？
- **6b.** "Linux 是 Unix" 这句话对吗？准确的说法应该是什么？
- **6c.** BSD 系列（FreeBSD、OpenBSD、NetBSD）和 Linux 在授权 (license) 上最大的区别是什么？

---

## 参考答案

<details>
<summary>点击展开全部答案</summary>

### 练习 1

- **1a.** 输出是 `Linux`——这是 **kernel** 的名字，不是发行版的名字。发行版名字要看 `/etc/os-release`。
- **1b.** `NAME` 是发行版名称（如 `Fedora Linux`、`Ubuntu`），`PRETTY_NAME` 是带版本号的完整可读名称（如 `Ubuntu 24.04.1 LTS`）。它们描述的是 **distribution**，即 kernel 之上的整套软件组合。
- **1c.** 因为 kernel 和 distribution 是独立发布的两层：所有发行版都从 kernel.org 获取同一份内核源码（可能加自己的补丁），然后各自搭配不同的软件包、默认配置和发布节奏。所以 Debian 和 Fedora 可以用几乎相同的内核版本，但用户体验完全不同。

### 练习 2

- **2a.** 1991 年，由芬兰学生 **Linus Torvalds** 发布，最初只是他的个人项目。
- **2b.** GNU 项目（1983 年由 Richard Stallman 发起）提供了操作系统所需的大量用户空间 (userspace) 工具：shell (bash)、编译器 (GCC)、核心命令 (coreutils) 等。Linux kernel 补上了 GNU 项目当时缺失的内核部分，两者结合才构成完整系统——这就是 "GNU/Linux" 称呼的由来。
- **2c.** GPL 保证任何人都可以自由使用、研究、修改和再分发源代码，但修改后再分发时必须同样开放源码（copyleft）。这吸引了全球开发者共同改进内核，也让任何公司都能基于它构建产品，是 Linux 快速演进和广泛采用的核心原因。
- **2d.** **stable** 是当前最新的稳定版本，维护期较短；**longterm (LTS)** 是被选中做长期维护的版本，会持续数年获得 bug 修复和安全补丁，适合不想频繁升级内核的场景（服务器、嵌入式设备）。

### 练习 3

- **3a.** Ubuntu 派生自 **Debian**，两者都使用 **.deb** 包格式，高层工具是 `apt`，底层工具是 `dpkg`。
- **3b.** 都属于 Red Hat 家族：**Fedora** 是社区发行版，充当新技术的试验田；**RHEL** (Red Hat Enterprise Linux) 是基于 Fedora 成果的付费商业企业版；**CentOS Stream** 是 RHEL 的上游滚动预览版；**Rocky Linux**（以及 AlmaLinux）是与 RHEL 二进制兼容的免费重构版，接替了原 CentOS 的定位。
- **3c.** 选 **RHEL**。它提供付费商业支持、认证的硬件/软件生态，以及长达约 10 年的生命周期；Fedora 更新快但每个版本只支持约 13 个月，没有商业支持，适合开发者和爱好者而不是保守的企业生产环境。
- **3d.** openSUSE 使用 **zypper**（底层同样是 rpm），属于 **.rpm** 阵营。

### 练习 4

- **4a.** Android 只复用了 Linux **kernel**（还带有大量定制），其用户空间完全不同：不用 GNU coreutils，不用 glibc（用的是 Bionic），应用运行在 Android 自己的运行时上，也没有传统的包管理器和 shell 环境。因为"发行版"指的是 kernel + GNU/传统用户空间的组合，所以 Android 通常不被算作 Linux distribution。
- **4b.** Raspberry Pi OS 基于 **Debian** 家族（使用 apt 和 .deb 包）。
- **4c.** 例如：家用路由器 (router)、智能电视 (smart TV)、网络存储设备 (NAS)、车载信息娱乐系统、智能音箱、打印机等——任选三类即可。

### 练习 5

- **5a.** Ubuntu **LTS** 每 **2 年**（偶数年 4 月，如 22.04、24.04）发布一次，标准支持期为 **5 年**（可通过付费的 Ubuntu Pro 延长）。中间的非 LTS 版本每 6 个月一版，仅支持 9 个月。
- **5b.** **rolling release**（如 Arch）：始终拥有最新软件，无需大版本升级，但更新频繁、偶尔破坏兼容性，需要用户持续维护。**fixed release**（如 Ubuntu LTS、Debian、RHEL）：版本内软件稳定、只收安全修复，行为可预测，但软件版本会逐渐变旧。
- **5c.** 生产服务器适合 **fixed release**（最好是 LTS/企业版）。生产环境最看重可预测性和稳定性：管理员需要确定今天能跑的东西明天升级后还能跑，并在整个生命周期内只接收安全补丁而不是功能变更。

### 练习 6

- **6a.** macOS 的内核 (XNU/Darwin) 源自 **BSD Unix** 血统，是经过认证的 UNIX 系统；Linux 则是从零编写的独立内核。两者都深受最初的 AT&T **Unix**（1969 年，贝尔实验室）设计思想影响，因此命令行体验非常相似。
- **6b.** 不对。准确说法是：Linux 是 **"类 Unix" (Unix-like)** 系统——它遵循 Unix 的设计理念和大部分接口标准 (POSIX)，但不包含任何原始 Unix 代码，也未做 UNIX 商标认证。
- **6c.** BSD 系列使用宽松的 **BSD license**：允许把代码闭源后用于商业产品而不必公开修改；Linux kernel 使用 **GPL** (copyleft)：再分发修改版时必须同样开放源码。这是两大开源阵营在哲学上的核心分歧。

</details>

---

## 参考资料

- LPI Learning Materials, Topic 1.1 – Linux Evolution and Popular Operating Systems: [https://learning.lpi.org/en/learning-materials/010-160/1/1.1/](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)
- The Linux Kernel Archives: [https://www.kernel.org](https://www.kernel.org)
- Ubuntu Release Cycle: [https://ubuntu.com/about/release-cycle](https://ubuntu.com/about/release-cycle)
- Raspberry Pi OS: [https://www.raspberrypi.com/software/](https://www.raspberrypi.com/software/)
- The FreeBSD Project: [https://www.freebsd.org](https://www.freebsd.org)