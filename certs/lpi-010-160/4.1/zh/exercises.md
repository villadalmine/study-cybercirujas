# 4.1 Choosing an Operating System — 引导练习 (Guided Exercises)

> 参考来源: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/

---

## 练习 1：识别当前系统的发行版信息 (Identify Distribution Info)

### 步骤

1. 打开一个 terminal。
2. 运行命令 `cat /etc/os-release`，观察输出中的 `NAME`、`ID`、`ID_LIKE`、`VERSION_ID`、`PRETTY_NAME` 等字段。
3. 如果系统装有 `lsb_release` 工具，运行 `lsb_release -a`，把 `Distributor ID`、`Release`、`Codename` 与上一步的结果对照。
4. 运行 `uname -a`，记录 kernel 的 release 版本号（如 `6.x.x`）以及机器的 architecture（如 `x86_64`、`aarch64`）。
5. 对比第 2 步和第 4 步的输出，思考它们分别描述的是系统的哪一层。

### 检查理解

- `/etc/os-release` 中的 `ID_LIKE` 字段有什么作用？它如何帮助你判断一个 distribution 属于哪个"家族"（例如 `ID_LIKE=debian`）？
- `uname -a` 显示的信息和 `/etc/os-release` 显示的信息在本质上有什么区别？（提示：一个描述的是 kernel，另一个描述的是谁在 kernel 之上构建了这套系统。）

---

## 练习 2：判断发行版所属家族与包管理器 (Distribution Family & Package Manager)

### 步骤

1. 根据练习 1 得到的发行版名称，先自行判断它属于 Debian 家族（如 Debian、Ubuntu）、Red Hat 家族（如 Fedora、CentOS、RHEL）、还是其他家族（如 Arch Linux、openSUSE）。
2. 依次检测系统上是否存在以下命令：`which apt`、`which dnf`、`which pacman`、`which zypper`。
3. 把检测到的包管理器（package manager）与你在第 1 步的推断相互印证。
4. 访问该 distribution 的官方网站，查阅它的 release model：是 fixed release（固定版本号、周期性发布）还是 rolling release（持续滚动更新）。
5. 记录该 distribution 上游（upstream）依赖的是哪个"母"发行版，还是完全独立开发。

### 检查理解

- 为什么同一个 Linux kernel 之上会衍生出如此多不同的 distribution？它们各自解决了什么不同的需求（例如桌面易用性、服务器稳定性、极简定制）？
- Rolling release 与 fixed release 在软件更新频率、稳定性、以及系统维护成本上分别有什么取舍（trade-off）？

---

## 练习 3：对比 FOSS 许可证 (Comparing FOSS Licenses)

### 步骤

1. 在终端运行 `apt-cache show bash 2>/dev/null | grep -i licen`（Debian 系）或 `rpm -qi bash | grep -i licen`（Red Hat 系），查看 `bash` 这个软件包标注的许可证信息。
2. 如果上一步没有直接结果，改为查看 `/usr/share/doc/bash/copyright`（或对应发行版下的类似路径），阅读其中提到的许可证名称。
3. 在浏览器中打开该许可证的官方全文（例如 GPL-3.0 对应 https://www.gnu.org/licenses/gpl-3.0.html），通读其序言（preamble）部分。
4. 找到 BSD 许可证或 MIT 许可证的官方全文，将其核心条款与 GPL 逐条对比，重点关注"衍生作品是否必须以相同许可证开源发布"这一条。
5. 用自己的话写一句话总结二者最本质的区别。

### 检查理解

- Free Software Foundation（FSF）所定义的"四大自由"（freedom 0 到 freedom 3）分别是什么？
- GPL 这种 copyleft license 与 BSD/MIT 这种 permissive license，在对待 derivative works（衍生作品）时的核心差异是什么？
- "Free software" 中的 "free" 指的是价格上的免费，还是使用/修改/再分发上的自由？请用一个具体例子说明为什么这两者不能划等号。

---

## 练习 4：区分 FOSS、Freeware 与 Proprietary Software (Business Models)

### 步骤

1. 选择一款你熟悉的软件（例如 VLC、Firefox、7-Zip 中任意一款），上网查询它使用的许可证类型。
2. 判断该软件属于：(a) FOSS（源码公开，且遵循 OSI 或 FSF 认可的许可证）；(b) freeware（免费获取，但不开放源码）；还是 (c) proprietary software（闭源商业软件）。
3. 打开 Open Source Initiative 官网（https://opensource.org/），找到其 "The Open Source Definition"，挑选其中 3 条标准，逐条判断你在第 1 步选择的软件是否满足。
4. 写一段两三句话的总结，说明为什么"免费获取（gratis）"不等于"开源（open source）"。

### 检查理解

- 请各举一个例子：一个"免费但不开源"的软件、以及一个"开源但依靠付费技术支持盈利"的商业模式。
- Open Source Initiative（OSI）与 Free Software Foundation（FSF）这两个组织在推广各自理念时，侧重点分别是什么（自由/伦理 vs. 实用主义/开发效率）？

---

## 练习 5：探索 Linux 在不同场景下的应用 (Where Linux Is Used)

### 步骤

1. 打开 TOP500 超级计算机榜单网站（https://www.top500.org/），查看当前榜单中运行 Linux 的机器所占的比例。
2. 在一台 Android 手机的"关于手机"或"关于设备"菜单中查找"内核版本"（kernel version）信息，确认 Android 底层同样基于 Linux kernel 构建。
3. 列举至少三种你日常生活中可能接触到、但底层运行 Linux 的 embedded devices（嵌入式设备），例如家用路由器、智能电视、车载信息娱乐系统。
4. 总结 Linux 在 server、cloud computing、supercomputer、embedded systems、mobile devices（通过 Android）这五个场景中分别扮演的角色，以及它在每个场景中相对 Windows/macOS 的主要优势。

### 检查理解

- 为什么 Linux 在超级计算机领域几乎占据绝对主导地位？这与它的 open source 特性和可定制性有什么关系？
- Android 与传统桌面 distribution（如 Ubuntu）相比，在 kernel 层面有什么共同点？在用户空间（userspace）和应用生态（application ecosystem）上又有哪些明显不同？

---

<details>
<summary>点击查看参考答案</summary>

### 练习 1 参考答案

- `ID_LIKE` 字段说明当前发行版是从哪个"上游"发行版派生而来。例如 Ubuntu 的 `/etc/os-release` 中包含 `ID_LIKE=debian`，说明它虽然自己的 `ID` 是 `ubuntu`，但底层软件包体系与 Debian 兼容（同样使用 `.deb` 包和 `apt`）。这个字段对写通用脚本、判断该用哪种 package manager 特别有用。
- `uname -a` 只描述内核（kernel）本身的信息：内核名称、hostname、内核 release 号、内核编译版本、硬件 architecture、操作系统名（通常是 `GNU/Linux`）。它不会告诉你"发行版"是什么，因为同一个 kernel 版本可以被 Ubuntu、Fedora、Arch 等完全不同的 distribution 使用。`/etc/os-release` 描述的则是"发行版"这一层——即在 kernel 之上，由谁打包、维护了这一整套系统。

### 练习 2 参考答案

- 之所以会有这么多 distribution，是因为它们虽然共享同一个 open source kernel，但在"用户空间要打包哪些软件、用什么包管理工具、面向什么用户群体、发布节奏如何"这些问题上做出了不同选择。例如 Ubuntu 面向桌面易用性和企业支持，Debian 强调稳定性和纯粹的自由软件原则，Fedora 作为 Red Hat 的上游侧重于展示前沿技术，Arch Linux 追求极简和用户完全掌控。
- Rolling release（如 Arch Linux）持续推送最新软件版本，用户始终使用最新特性，但也更容易遇到未充分测试的 bug，需要用户更频繁地关注更新日志。Fixed release（如 Debian Stable、Ubuntu LTS）在固定周期内冻结软件版本、只推送安全更新，稳定性更高、更适合生产环境，但用户要等到下一个大版本才能用上新特性。

### 练习 3 参考答案

- FSF 的四大自由：
  - **Freedom 0**：无论何种目的，都可以按自己的意愿运行该程序。
  - **Freedom 1**：可以研究该程序如何工作，并按需修改它（前提是能获取源代码）。
  - **Freedom 2**：可以自由再分发副本，帮助他人。
  - **Freedom 3**：可以分发你修改后的版本，让整个社区受益。
- GPL 是一种 copyleft license：如果你基于 GPL 代码开发并对外分发衍生作品，你也必须以 GPL（或兼容许可证）开放该衍生作品的源代码——这种"传染性"条款正是为了保证自由软件的自由性能持续传递下去。BSD/MIT 是一种 permissive license：几乎不限制衍生作品的使用方式，允许他人基于该代码开发闭源商业软件而无需公开自己的修改。
- "Free" 在这里指的是自由（liberty），而不是价格（price）。FSF 常用 "free as in freedom, not free as in beer" 来澄清这一点。例如，一款软件可以是收费的，但只要它满足四大自由（用户付费购买后仍可自由修改、再分发），它依然是 free software；反之，一款免费下载但不公开源码、禁止修改再分发的软件（即 freeware）则完全不属于 free software。

### 练习 4 参考答案

- "免费但不开源"的例子：例如某些厂商提供的免费版驱动程序或工具软件，用户可以零成本下载使用，但拿不到源代码，也无权修改或再分发——这类软件属于 freeware，而非 FOSS。
  "开源但靠付费技术支持盈利"的例子：许多企业级 open source 项目（如某些 Linux distribution 的企业版）本身源码完全公开、可自由获取，但厂商通过提供认证支持、SLA 保障、定制开发等服务收费。
- OSI 更偏"实用主义"（pragmatic）视角，强调开放源码本身带来的开发效率、协作透明、安全可审计等工程收益；FSF 则更偏"伦理"（ethical）视角，强调用户对软件应享有的自由权利，把是否尊重这四大自由作为评判软件的道德标准，而不仅仅是工程上的便利。

### 练习 5 参考答案

- Linux 在超级计算机领域占主导地位，很大程度上得益于其开源特性：研究机构和厂商可以根据自身硬件架构和计算需求自由裁剪、优化 kernel 和系统组件，无需受制于单一厂商的授权或商业策略，这种可定制性与免授权费在大规模部署（成千上万个计算节点）时优势尤为明显。
- Android 与传统桌面 distribution 一样，都以 Linux kernel 作为底层核心，因此在进程调度、内存管理、设备驱动模型等方面共享同一套机制。但在 kernel 之上，Android 使用了完全不同的用户空间：它不采用传统的 GNU 工具链和 glibc，而是使用 Bionic C library，图形界面基于 Android 自己的 framework 而非常见的 Linux desktop environment（如 GNOME、KDE），应用生态也是围绕 Java/Kotlin 与 Android SDK 构建，而非传统 Linux 的原生二进制应用体系。

</details>