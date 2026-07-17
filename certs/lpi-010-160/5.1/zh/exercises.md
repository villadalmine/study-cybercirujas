# LPI Linux Essentials（010-160,v1.6）主题 5.1：Basic Security and Identifying User Types 引导练习

> 参考来源：https://learning.lpi.org/en/learning-materials/010-160/5/5.1/ （内容为原创编写，仅以此链接作为知识点参考，未直接摘抄原文）

---

## 练习一：认识 `/etc/passwd` 与账户结构

1. 打开终端，执行以下命令查看系统账户文件：
   ```bash
   cat /etc/passwd
   ```
2. 观察输出的每一行，字段之间用冒号 `:` 分隔。找到 `root` 所在的那一行，记录它的第三个字段（UID）。
3. 再执行：
   ```bash
   awk -F: '{print $1, $3}' /etc/passwd | sort -n -k2 | head -20
   ```
   观察 UID 从小到大排列的账户列表。

**理解检查：**
- `/etc/passwd` 文件中一共有几个字段？第 3 个和第 4 个字段分别代表什么？
- `root` 账户的 UID 是多少？这个值在 Linux 系统中有什么特殊含义？
- 你在输出中看到的 `bin`、`daemon`、`sys` 这类账户属于哪一类用户（system user 还是 regular user）？

---

## 练习二：区分 system users 与 regular users

1. 执行以下命令，只列出 UID 小于 1000 的账户（多数发行版将 1000 以下视为 system users）：
   ```bash
   awk -F: '$3 < 1000 {print $1, $3}' /etc/passwd
   ```
2. 再列出 UID 大于等于 1000 的账户：
   ```bash
   awk -F: '$3 >= 1000 {print $1, $3}' /etc/passwd
   ```
3. 比较两组输出的账户名称，思考它们分别用于什么目的。

**理解检查：**
- 为什么系统需要像 `bin`、`sshd`、`nobody` 这样的 system users？它们能否用于交互式登录？
- Regular user（普通用户）与 system user 在权限设计上的核心区别是什么？

---

## 练习三：查看 `/etc/shadow` 中的密码信息

1. 使用 `sudo` 权限查看密码文件（普通用户默认无法直接读取）：
   ```bash
   sudo cat /etc/shadow
   ```
2. 找到自己账户所在的那一行，注意第二个字段（密码哈希，或 `!`、`*` 等特殊符号）。
3. 执行以下命令，只显示密码字段是否被锁定的账户：
   ```bash
   sudo awk -F: '$2 ~ /^!|^\*/ {print $1}' /etc/shadow
   ```

**理解检查：**
- 为什么 `/etc/shadow` 的读取权限比 `/etc/passwd` 更严格？这体现了什么安全设计原则？
- 如果某账户密码字段是 `!` 或 `*`，说明该账户处于什么状态？
- `/etc/shadow` 中除了密码哈希，还包含哪些与密码有效期（password aging）相关的字段？

---

## 练习四：查看 `/etc/group` 并理解 root 的特殊权限

1. 执行：
   ```bash
   cat /etc/group | grep -E 'root|wheel|sudo'
   ```
2. 查看自己所属的组：
   ```bash
   id
   groups
   ```
3. 尝试执行一个需要 root 权限的命令，先不加 `sudo`，观察报错：
   ```bash
   cat /etc/shadow
   ```
   再加上 `sudo` 重新执行，对比结果。

**理解检查：**
- `id` 命令输出中的 `uid`、`gid`、`groups` 分别说明什么？
- root 账户为什么被称为 "super user"？它对系统文件和进程有怎样的权限？
- 直接以 root 身份日常操作系统会带来哪些安全风险？为什么推荐使用 `sudo` 而不是长期切换到 root？

---

## 练习五：使用命令识别当前登录与认证情况

1. 查看当前登录的用户身份：
   ```bash
   whoami
   ```
2. 查看当前所有已登录用户及其终端：
   ```bash
   who
   w
   ```
3. 查看最近的登录历史：
   ```bash
   last -n 10
   ```

**理解检查：**
- `who` 与 `w` 命令的输出有什么区别？`w` 多显示了哪些信息？
- `last` 命令的数据来源是哪个日志文件？它对安全审计（audit）有什么作用？
- 如果 `last` 显示了一个你不认识的登录记录，你应该怀疑什么安全问题？

---

## 练习六：本地系统安全意识——单用户模式与磁盘加密

1. 查看当前系统是否启用了磁盘加密（以 LUKS 为例）：
   ```bash
   lsblk -f
   ```
   观察是否有 `crypto_LUKS` 类型的分区。
2. 查看系统引导加载程序配置（如 GRUB），了解是否设置了进入单用户模式（single user mode / rescue mode）的密码保护：
   ```bash
   sudo grep -i password /boot/grub2/grub.cfg 2>/dev/null || sudo grep -i password /boot/grub/grub.cfg 2>/dev/null
   ```

**理解检查：**
- 为什么未加密的磁盘在物理丢失或被盗时是严重的安全隐患？
- 单用户模式（single user mode）默认通常以什么权限启动？如果不设密码保护会带来什么风险？

---

## 练习七：远程与网络安全意识——SSH、防火墙与加密

1. 查看 SSH 服务是否在运行，以及其配置文件中是否禁止了 root 直接远程登录：
   ```bash
   sudo systemctl status sshd
   sudo grep -i permitrootlogin /etc/ssh/sshd_config
   ```
2. 查看本机防火墙（firewall）的状态：
   ```bash
   sudo firewall-cmd --state 2>/dev/null || sudo ufw status 2>/dev/null || sudo iptables -L
   ```
3. 使用 GnuPG 生成一对测试密钥，体验文件加密的基本流程：
   ```bash
   gpg --full-generate-key
   gpg --list-keys
   echo "test message" | gpg --encrypt --armor -r "your-key-id"
   ```

**理解检查：**
- SSH 相比传统的 `telnet` 在安全性上做了哪些改进（提示：加密传输、认证方式）？
- `PermitRootLogin no` 这项配置的安全目的是什么？
- 防火墙（firewall）在网络安全中扮演什么角色？它与 SSH、VPN、SSL/TLS 分别处于安全防护的哪个层面？
- GnuPG（GPG）常用于哪两类安全目的（提示：加密与数字签名）？

---

<details>
<summary>点击查看参考答案</summary>

**练习一**
- `/etc/passwd` 共有 7 个字段：username、password placeholder(`x`)、UID、GID、GECOS（描述信息）、home directory、login shell。第 3 个字段是 UID（用户唯一标识符），第 4 个字段是 GID（该用户所属的主组）。
- root 的 UID 固定为 `0`。UID 0 在 Linux 内核中被特殊对待：拥有该 UID 的账户绕过绝大多数权限检查，等同于 "super user"，无论账户名是不是叫 `root`。
- `bin`、`daemon`、`sys` 属于 system users（系统账户），用于运行系统服务和拥有系统文件，而不是给真人登录使用。

**练习二**
- system users 是为服务、守护进程（daemon）、系统文件所有权而创建的账户，目的是遵循最小权限原则（least privilege）：让服务以专属的低权限身份运行，而不是以 root 身份运行，从而缩小被攻破后的影响范围。它们的 shell 通常被设为 `/sbin/nologin` 或 `/bin/false`，不能交互式登录。
- Regular user 是供真实人类使用的账户，拥有 home directory、可交互登录、UID 通常从 1000（或某些发行版从 500）开始；system user 则服务于后台进程，权限范围被严格限制在其运行所需的最小范围内。

**练习三**
- `/etc/passwd` 需要对所有用户可读（很多命令需要用它把 UID 转换成用户名），但密码哈希若也放在里面，任何用户都能拿去做离线暴力破解。因此密码哈希被移到只有 root 可读的 `/etc/shadow`，体现了"权限分离"和"最小暴露面"的安全设计原则。
- `!` 或 `*` 表示该账户的密码被锁定/禁用，无法通过密码方式登录（常见于 system users 或被管理员临时禁用的账户）。
- `/etc/shadow` 还包含：上次修改密码的日期、密码最短/最长有效天数、密码过期前的警告天数、密码过期后的宽限天数、账户失效日期等 password aging 相关字段。

**练习四**
- `uid` 显示当前用户的 UID 及用户名，`gid` 显示主组的 GID 及组名，`groups`（或 `id` 输出末尾的 `groups=`）列出该用户所属的所有附加组。
- root 被称为 super user，因为它的 UID 为 0，内核默认不对其执行常规的文件权限、进程权限检查，可以读写任意文件、终止任意进程、绑定任意端口等。
- 长期以 root 身份操作的风险：任何误操作（如误删文件）或被利用的漏洞都会以最高权限执行，破坏面没有任何限制；而 `sudo` 允许按需、按命令临时提权，并保留操作日志，便于审计（audit）和追责，同时降低误操作或恶意程序获得完全控制的概率。

**练习五**
- `who` 只显示已登录用户、终端、登录时间；`w` 在此基础上还显示每个用户当前运行的进程、登录来源、空闲时间及系统负载（load average）。
- `last` 的数据来源是 `/var/log/wtmp`（二进制登录历史日志）。它对安全审计的作用是可以追溯谁在何时、从哪个来源登录过系统，帮助发现异常或未授权的访问。
- 如果看到不认识的登录记录，应怀疑账户可能已被盗用（compromised），需要立即检查密码是否泄露、修改密码、审查该账户近期的操作记录。

**练习六**
- 未加密磁盘一旦丢失或被盗，攻击者只需将硬盘挂载到另一台机器即可直接读取全部文件，绕过操作系统的登录认证；磁盘加密（如 LUKS）能确保即使物理介质落入他人之手，数据在没有解密密钥的情况下也无法被读取。
- 单用户模式（single user mode / rescue mode）默认通常以 root 权限启动且跳过正常登录认证，主要用于系统修复；如果没有为进入该模式设置密码保护，任何能物理接触或控制引导过程的人都能绕过所有账户密码直接获得 root 权限。

**练习七**
- SSH 对所有传输内容（包括认证凭据和会话数据）进行加密，并支持基于密钥对（key pair）的认证方式，避免了 telnet 以明文形式传输用户名和密码、任何人在同一网络上都能嗅探（sniff）到凭据的问题。
- `PermitRootLogin no` 禁止直接以 root 身份通过 SSH 远程登录，迫使攻击者即使拿到 root 密码也无法直接远程登录，必须先以普通账户登录再通过 `su` 或 `sudo` 提权，这样既增加了一层防护，也让权限提升的过程可以被日志记录、审计。
- 防火墙（firewall）负责在网络层/传输层控制进出流量，决定哪些端口、协议、IP 可以与本机通信，属于边界防护；SSH 提供加密的远程管理通道，VPN 在不受信任的网络（如公共 Wi-Fi）上建立加密隧道以保护整体网络流量，SSL/TLS 则为应用层（如 HTTP、邮件等）协议提供端到端加密，四者分别作用在防护体系的不同层面，通常需要组合使用。
- GnuPG（GPG）常用于：① 文件/消息加密（encryption），确保只有持有私钥的人能解密内容；② 数字签名（digital signature），用于验证数据的完整性和来源真实性（防篡改、防伪造）。

</details>