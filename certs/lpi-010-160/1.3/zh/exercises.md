# LPI Linux Essentials (010-160 v1.6) — 1.3 Open Source Software and Licensing

**考试权重：1**
**参考资料：** [https://learning.lpi.org/en/learning-materials/010-160/1/1.3/](https://learning.lpi.org/en/learning-materials/010-160/1/1.3/)

本节练习围绕 open source licensing（开源许可）在真实 Linux 系统中的落地方式展开：从已安装软件包的 license 元数据，到内核模块（kernel module）的 GPL 合规机制，再到 copyleft 与 permissive license 的文本差异。所有命令均可在常见发行版（Debian/Ubuntu 系与 Fedora/RHEL 系均已标注差异）上直接执行。

---

## 练习一：查看已安装软件包的 License 元数据

1. 在 Debian/Ubuntu 系统上，运行以下命令，定位 `bash` 软件包附带的版权说明文件：
   ```
   dpkg -L bash | grep copyright
   ```
2. 查看该文件的前 30 行：
   ```
   cat /usr/share/doc/bash/copyright | head -30
   ```
3. 在输出中找到 `License:` 字段，记录 `bash` 使用的许可证名称。
4. 若你使用的是 Fedora/RHEL/CentOS 系统，改用以下命令直接查询同样的信息：
   ```
   rpm -q --queryformat '%{LICENSE}\n' bash
   ```

**✍️ 思考题**
1. 为什么每个 Debian 软件包都必须附带一个 `copyright` 文件？这与 open source license 要求"保留版权声明"的条款有什么关系？
2. `rpm -q --queryformat '%{LICENSE}\n'` 返回的是一句简短的许可证标识，而 Debian 的 `copyright` 文件通常是完整文本，这两种方式各自的优缺点是什么？

---

## 练习二：用 `modinfo` 验证内核模块的 License 字段

Linux kernel 本身以 GPL v2 发布，非 GPL 兼容的内核模块加载后会使内核进入 "tainted"（污染）状态，这是 copyleft 许可证在系统层面的一个真实体现。

1. 查看当前已加载的内核模块：
   ```
   lsmod | head -5
   ```
2. 任选一个模块（例如 `ext4`），查看它声明的许可证：
   ```
   modinfo ext4 | grep -i license
   ```
3. 观察输出的 `license` 字段（通常为 `GPL`）。这是模块源代码中 `MODULE_LICENSE()` 宏声明的值。
4. 检查当前内核的污染状态：
   ```
   cat /proc/sys/kernel/tainted
   ```
   输出 `0` 表示未加载任何非 GPL 兼容的模块。

**✍️ 思考题**
1. 如果一个内核模块的 `MODULE_LICENSE` 声明为 `"Proprietary"`，会对内核的 `tainted` 状态产生什么影响？为什么内核开发者要设计这个机制？
2. `modinfo` 显示的 license 字段是一个字符串（如 `GPL`、`Dual BSD/GPL`），它是否具有法律约束力？谁才是真正决定该模块许可条款的权威来源？

---

## 练习三：对比 Copyleft 与 Permissive License 的结构差异

1. 在 Debian/Ubuntu 系统上，列出系统内置的标准许可证文本：
   ```
   ls /usr/share/common-licenses/
   ```
2. 查看 GPL-3 许可证的开头部分：
   ```
   cat /usr/share/common-licenses/GPL-3 | head -40
   ```
3. 查看 BSD 许可证全文（篇幅短很多）：
   ```
   cat /usr/share/common-licenses/BSD
   ```
4. 用 `grep` 搜索 BSD 许可证中关于再分发（redistribution）的条款：
   ```
   grep -A2 -i "redistribution" /usr/share/common-licenses/BSD
   ```

**✍️ 思考题**
1. 根据你阅读到的条款，GPL 与 BSD 最核心的区别是什么——具体来说，衍生作品（derivative work）在再分发时是否必须使用相同的许可证？
2. 一家公司如果想把某段开源代码集成进自己的闭源商业产品中并且不公开自己新增的代码，选择 BSD 许可证的代码和选择 GPL 许可证的代码，结果会有什么不同？

---

## 练习四：比较不同许可证对 Patent（专利）条款的处理

1. 统计三种许可证文本中 "patent" 一词出现的次数：
   ```
   grep -c -i patent /usr/share/common-licenses/GPL-2 /usr/share/common-licenses/GPL-3 /usr/share/common-licenses/Apache-2.0
   ```
2. 查看 Apache-2.0 中关于专利授权的具体条款：
   ```
   grep -A3 -i "patent" /usr/share/common-licenses/Apache-2.0
   ```
3. 对比 GPL-2 和 GPL-3 中出现 "patent" 的上下文，观察两者措辞详略的差异。

**✍️ 思考题**
1. 为什么 Apache License 2.0 会包含一段明确的 "Grant of Patent License"（专利授权）条款，而这在 GPL-2 中几乎找不到对应内容？
2. GPL-3 相比 GPL-2 在专利方面新增了哪类保护机制？这类条款是为了应对什么现实风险（提示：贡献者或发行商利用专利起诉最终用户）？

---

## 练习五：在系统文档中寻找 Creative Commons 许可证

Creative Commons（CC）许可证通常不用于软件源代码本身，而是用于文档、字体、图标主题等创作性内容。

1. 在系统中搜索所有引用了 "Creative Commons" 的软件包版权文件：
   ```
   grep -rl "Creative Commons" /usr/share/doc/*/copyright 2>/dev/null | head -5
   ```
2. 任选一个匹配结果，用 `cat` 查看它引用的具体 CC 许可证版本（例如 `CC-BY-SA-4.0` 或 `CC0-1.0`）。
3. 记录该软件包属于哪一类内容（字体、图标、文档等）。

**✍️ 思考题**
1. 为什么字体、图标主题这类"创作性内容"倾向于使用 Creative Commons 许可证，而不是 GPL 或 BSD 这类为程序代码设计的许可证？
2. `CC0` 与 `CC-BY-SA` 的核心区别是什么？如果你希望自己发布的内容被自由使用但必须署名，应该选择哪一种？

---

## 练习六：分类练习 — FOSS、Freeware、Shareware 的判断标准

1. 阅读下表中列出的五款软件（或按你熟悉的软件自行替换）：

   | 软件 | 是否公开源代码 | 是否收费 | 是否允许修改并再分发 |
   |---|---|---|---|
   | Linux kernel | 是 | 否 | 是 |
   | Mozilla Firefox | 是 | 否 | 是（需遵循 MPL 2.0） |
   | Adobe Acrobat Reader | 否 | 否（基础版） | 否 |
   | 某款试用期 30 天的压缩软件 | 否 | 试用期后收费 | 否 |
   | Wikipedia 正文内容 | 是（文本） | 否 | 是（需署名并保留 CC BY-SA） |

2. 针对每一行，判断它属于 Open Source（FOSS）、Freeware 还是 Shareware，并写下判断依据。
3. 对比 "免费（no cost）" 与 "自由（freedom，即 FSF 所说的四大自由）" 这两个概念，说明为什么二者不能混为一谈。

**✍️ 思考题**
1. Freeware 与 Open Source Software 最本质的区别是什么？（提示：能否获取并修改源代码，而不是是否收费）
2. FSF（Free Software Foundation）和 OSI（Open Source Initiative）分别强调"自由软件（free software）"和"开源软件（open source software）"这两个术语，二者在软件许可的实际条款要求上是否存在根本冲突？

---

<details>
<summary>点击展开查看参考答案</summary>

**练习一**
1. Debian Policy 要求每个软件包必须包含 `copyright` 文件，是因为绝大多数开源许可证（包括 GPL、BSD、MIT 等）都要求在再分发时保留原始的版权声明（copyright notice）和许可条款全文；这是许可证生效的前提条件之一，缺失该文件会导致再分发行为不合规。
2. `rpm --queryformat` 方式查询速度快、便于脚本化批量检查，但只给出许可证的简短标识（如 `GPLv2+`），不包含完整法律文本；Debian 的 `copyright` 文件信息更完整、可追溯到具体文件级别的版权归属，但不便于自动化批量处理。两者互补，前者适合快速筛查，后者适合合规审计。

**练习二**
1. 加载 `MODULE_LICENSE("Proprietary")` 的模块会使 `/proc/sys/kernel/tainted` 的对应比特位被置位（非 0），内核会在日志和崩溃报告（oops/panic）中标注 "tainted" 状态。这样设计是为了让内核开发者在排查 bug 时能立刻识别问题是否可能源于非开源、未经审查的闭源代码，从而决定是否值得花时间调试。
2. 该字段没有独立的法律约束力，它只是模块作者在源代码中自我声明的字符串，系统本身不会验证其真实性。真正具有法律效力的许可条款来自该模块对应的实际源代码仓库和随附的许可证文件（如 `COPYING`），`modinfo` 的输出只是一个供内核和开发者参考的元数据标记。

**练习三**
1. 核心区别在于是否具有 copyleft（著佐权）效力：GPL 要求任何基于 GPL 代码修改或衍生的作品，在对外分发时也必须以 GPL 许可证发布并公开源代码；BSD 是 permissive license（宽松许可证），只要求保留版权声明和免责声明，允许衍生作品以任意许可证（包括闭源商业许可证）再分发。
2. 使用 BSD 许可代码的公司可以自由地将其整合进闭源产品，无需公开自己新增的代码；而使用 GPL 许可代码则必须以相同的 GPL 条款公开整个衍生作品的源代码，因此大多数希望保持代码闭源的商业公司会避免直接链接或修改 GPL 代码，转而选择 permissive license 的替代实现。

**练习四**
1. Apache License 2.0 制定时间较晚（2004 年），专门针对企业级贡献者可能持有软件相关专利的现实情况，加入了明确的 "Grant of Patent License" 条款：贡献者向使用者明确授予专利许可，并规定如果使用者对贡献者发起专利诉讼，将自动丧失该专利授权（专利报复条款）。GPL-2 制定于 1991 年，当时软件专利问题尚不突出，因此条款中只在第 7 条以间接方式提及专利可能带来的分发限制，没有专门的授权条款。
2. GPL-3（2007 年发布）相比 GPL-2 新增了显式的 "Patents" 条款（对应 Apache 式的专利授权与报复机制），目的是应对随着软件专利诉讼增多而出现的风险：贡献者或发行商可能一边分发 GPL 代码，一边利用自己持有的相关专利起诉下游用户或其他实现者（即所谓 "Tivoization" 和专利伏击问题的延伸）。

**练习五**
1. 字体、图标主题这类内容本质上是"创作性作品（creative work）"而非"可执行的程序逻辑"，GPL、BSD 这类许可证的条款（如源代码公开、衍生代码许可证延续）是围绕程序源代码的编译、修改和链接设计的，并不适用于描述图像、字形这类静态创作内容的使用和署名规则，而 Creative Commons 正是专门为这类创作内容设计的许可证体系。
2. `CC0` 相当于将作品放弃版权、进入 public domain（公共领域），使用者无需署名即可自由使用；`CC-BY-SA`（署名-相同方式共享）要求使用者必须署名原作者，并且如果对作品进行修改再分发，必须使用相同的许可证。如果希望内容被自由使用但要求署名，应选择 `CC-BY` 或 `CC-BY-SA`（后者额外要求衍生作品保持相同许可证）。

**练习六**
1. 本质区别在于源代码是否公开可获取、可修改、可再分发，而不是价格。Freeware 通常免费提供给用户使用，但不公开源代码，用户无权查看、修改或再分发程序；Open Source Software 则必须满足 OSI 认可的开源定义（源代码可获取、允许修改、允许再分发衍生作品），是否收费与"是否开源"是两个独立维度。
2. 二者在具体许可证条款的实际要求上高度重合（事实上绝大多数 OSI 认可的开源许可证同时也被 FSF 认定为自由软件许可证，例如 GPL、BSD、MIT），并不存在根本性的条款冲突；真正的分歧在于两个组织强调的价值出发点不同——FSF 从"用户自由（自由使用、学习、修改、分享）"这一伦理立场出发，OSI 则更强调"开放协作带来的实际开发效率与质量优势"这一实用主义立场。

</details>