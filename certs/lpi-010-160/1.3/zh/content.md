# 1.3 开源软件与许可证 (Open Source Software and Licensing)

## 1. 什么是 Open Source

"Open Source"(开源)指软件的源代码 (source code) 公开可获取,任何人都可以查看、修改和重新分发。这与仅提供可执行文件 (binary) 的 proprietary software (专有软件/闭源软件) 形成对比。

开源不仅仅是"能看到代码",而是一整套围绕协作开发、透明度和许可 (licensing) 的哲学与实践方式。理解这一部分内容,需要区分两个历史上并行但侧重点不同的运动:**Free Software** 运动和 **Open Source** 运动。

## 2. Free Software 与 Open Source 的区别

### 2.1 Free Software Foundation (FSF)

Free Software 运动由 Richard Stallman 于 1983 年发起,并成立了 **Free Software Foundation (FSF)**。这里的 "free" 强调的是自由 (freedom),而不是价格,常用一句话概括:

> "Free as in speech, not free as in beer."(自由如同言论自由,而非免费啤酒。)

也就是说,软件可以收费销售,但用户必须拥有对软件的控制权。FSF 定义了软件成为 "free software" 必须满足的 **四项基本自由 (Four Essential Freedoms)**,编号从 0 开始:

| 自由编号 | 内容 |
|---|---|
| Freedom 0 | 无论用于何种目的,都有运行该程序的自由 |
| Freedom 1 | 研究程序如何运作,并按需修改它的自由(前提是可以获取 source code) |
| Freedom 2 | 自由分发副本,以帮助他人 |
| Freedom 3 | 自由分发你修改后的版本,让整个社区受益 |

FSF 主导的项目包括 GNU 项目 (GNU is Not Unix),它与 Linux kernel 结合形成了通常所说的 GNU/Linux 系统。

### 2.2 Open Source Initiative (OSI)

1998 年,一部分人认为 "free" 一词在商业环境中容易造成误解(常被理解成免费),于是成立了 **Open Source Initiative (OSI)**,推广 "open source" 这一更偏重实用主义、便于企业采纳的术语。

OSI 维护着 **Open Source Definition (OSD)**,任何许可证若想被认定为 "OSI approved",必须满足包括以下在内的十项标准:

- Free Redistribution(可自由再分发,不得收取版税)
- Source Code 必须随程序提供或可轻易获取
- Derived Works(允许修改并以相同许可证再分发衍生作品)
- 不得歧视个人、群体或使用领域 (No Discrimination Against Persons or Groups / Fields of Endeavor)
- License Must Not Be Specific to a Product(许可证权利不能仅限于某个特定产品分发)

FSF 与 OSI 的核心自由/标准高度重叠,实践中绝大多数被 FSF 认定为 free 的许可证也被 OSI 认定为 open source(反之亦然),但两者在**价值观表述**上有分歧:FSF 强调伦理与用户自由,OSI 强调开发方法论与实际效益。因此常见术语 **FOSS (Free and Open Source Software)** 或 **FLOSS (Free/Libre and Open Source Software)** 被用来同时涵盖两派,避免站队。

## 3. 主要开源许可证类型

License(许可证)决定了他人可以如何使用、修改、分发你的代码。大致可分为两大类:

### 3.1 Copyleft 许可证(如 GPL)

**Copyleft** 是对 "copyright" 一词的双关,核心思想是:你可以自由使用、修改、分发代码,但衍生作品 (derivative work) 必须以**相同的许可证**发布,从而保证自由性会持续传递下去,不会被闭源化。

最具代表性的是 **GNU General Public License (GPL)**,目前常用版本是 GPLv2 与 GPLv3:

- Linux kernel 使用 **GPLv2**
- 很多 GNU 工具(如 bash、coreutils)使用 **GPLv3**

还有一种 "weak copyleft" 变体 **LGPL (GNU Lesser General Public License)**,常用于程序库 (library),允许闭源软件动态链接 (link) 该库而不必开源整个应用。

### 3.2 Permissive(宽松式)许可证

**Permissive license** 对衍生作品几乎没有限制,允许他人将代码用于闭源产品,只需保留原作者的 copyright notice。常见例子:

- **BSD License**(如 2-clause / 3-clause BSD)
- **MIT License**
- **Apache License 2.0**(额外包含专利授权条款 patent grant)

例如 FreeBSD 内核使用 BSD license,允许厂商(包括商业公司)基于它构建闭源产品而无需公开修改后的源码。

### 3.3 Creative Commons

**Creative Commons (CC)** 许可证并非专为软件设计,而主要用于文档、图片、音乐等创作内容 (content licensing)。常见组合标记:

- **BY**(署名,Attribution)
- **SA**(相同方式共享,ShareAlike,类似 copyleft 概念)
- **NC**(非商业性使用,NonCommercial)
- **ND**(禁止演绎,NoDerivatives)

例如 CC BY-SA 4.0 常用于 Wikipedia 内容;CC0 则等同于将作品放入 public domain(公有领域),放弃几乎所有权利。

需要注意:CC 许可证中带 NC 或 ND 条款的版本 **不被 OSI 视为 open source**,因为违反了 "no discrimination" 和 "derived works" 等标准,因此几乎不会用于软件本身。

## 4. 在系统中查看软件许可证信息

在实际使用 Linux 时,可以通过多种方式查询已安装软件包的许可证信息。

Debian/Ubuntu 系统下,每个软件包的版权/许可证信息通常保存在 `/usr/share/doc/<package>/copyright`:

```console
$ cat /usr/share/doc/vim-common/copyright | head -15
This package was debianized by ...
...
License: GPL-2+ or Vim
```

常见的通用协议全文集中存放于 `/usr/share/common-licenses/`:

```console
$ ls /usr/share/common-licenses/
Apache-2.0  BSD  GFDL-1.3  GPL-2  GPL-3  LGPL-2.1  LGPL-3  MPL-2.0 ...
```

RPM-based 系统(如 Fedora、CentOS)可以直接用 `rpm` 查询 License 字段:

```console
$ rpm -qi httpd | grep -i license
License     : ASL 2.0
```

对于以源码形式分发的项目(如从 GitHub 克隆的仓库),许可证通常在项目根目录下的 `LICENSE` 或 `COPYING` 文件中:

```console
$ ls
LICENSE  README.md  src/

$ head -3 LICENSE
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007
```

## 5. 开源社区的角色

一个成熟的开源项目通常围绕清晰的贡献流程和角色分工运作,常见角色包括:

- **User(用户)**:仅使用软件,可能提交 bug report。
- **Contributor(贡献者)**:提交 patch/pull request,可能是代码、文档或翻译。
- **Maintainer(维护者)**:审核并合并贡献,负责发布 (release) 版本。
- **Project lead / BDFL**:对项目方向拥有最终决策权(如 Linux kernel 的 Linus Torvalds)。

社区协作通常依托 mailing list、issue tracker(如 GitHub Issues)、Code of Conduct(行为准则)等机制维持秩序与透明度。

## 6. 开源软件的商业模式

开源不等于"免费",许多公司围绕开源软件构建了可持续的商业模式,例如:

- **Support & services(支持与服务)**:如 Red Hat 通过为 RHEL 提供付费技术支持和认证盈利,而 RHEL 的源码本身遵循开源许可证。
- **Open-core**:核心功能开源,高级/企业功能作为闭源插件收费。
- **Dual licensing(双重授权)**:同一代码同时以 copyleft 许可证(如 GPL)和商业许可证提供,企业若不愿公开自身代码可购买商业授权(如早期 MySQL 的模式)。
- **Donations / Sponsorship**:通过基金会(如 Linux Foundation、Apache Software Foundation)接受企业和个人捐赠。

## Referencias

- LPI Learning Materials — Topic 1.3: Open Source Software and Licensing: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- Free Software Foundation — The Free Software Definition: https://www.gnu.org/philosophy/free-sw.html
- Open Source Initiative — The Open Source Definition: https://opensource.org/osd
- GNU General Public License: https://www.gnu.org/licenses/gpl-3.0.html
- Creative Commons — About the Licenses: https://creativecommons.org/licenses/