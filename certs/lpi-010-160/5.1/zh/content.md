# 5.1 Basic Security and Identifying User Types

## 概述

Linux 系统的安全性建立在两个基本支柱之上：**防止未经授权的访问**（本地和网络层面）以及**正确管理用户权限**。作为 Linux Essentials 考生，你不需要掌握深入的安全加固技术，但需要理解基本的安全威胁、常见的防护手段（如加密通信、firewall），以及 Linux 系统中不同类型的用户账户及其权限差异。

## 常见的安全威胁

Linux 虽然因其权限模型和开源审计而被认为相对安全，但同样面临真实的安全风险：

- **Malware（恶意软件）**：包括病毒（virus）、蠕虫（worm）、木马（trojan horse）和勒索软件（ransomware）。虽然 Linux 上的恶意软件数量远少于 Windows，但并非不存在，尤其是针对服务器和 IoT 设备的恶意软件（例如僵尸网络 botnet）近年来持续增长。
- **未经授权的本地访问**：如果攻击者能物理接触机器，或者获得一个普通用户账户，就可能尝试提权（privilege escalation）来获取 root 权限。
- **网络攻击**：包括暴力破解（brute-force attack）、中间人攻击（man-in-the-middle attack）、端口扫描（port scanning）等，目标通常是开放的网络服务。

## 安全最佳实践

一些基础但非常有效的安全习惯：

1. **及时更新系统**：使用发行版的包管理器（如 `apt`、`dnf`）定期安装安全补丁。
2. **最小权限原则（principle of least privilege）**：日常操作使用普通用户账户，仅在必要时通过 `sudo` 提升权限，而不是直接以 root 身份登录。
3. **关闭不必要的服务**：减少系统对外暴露的攻击面（attack surface）。
4. **使用强密码策略**，并结合密钥认证（key-based authentication）代替纯密码登录（尤其是 SSH）。
5. **审查日志**：如 `/var/log/auth.log` 或 `/var/log/secure`，用于发现异常登录尝试。

### 密码策略要点

一个好的密码策略通常包括：

- 足够的长度和复杂度（大小写字母、数字、特殊符号混合）。
- 避免使用字典单词或个人信息（生日、姓名）。
- 定期更换密码，且不重复使用旧密码。
- **绝不使用默认密码**：许多安全事件源于设备或服务保留了出厂默认密码（如路由器、IoT 设备）。

## 加密与安全通信

明文协议（plaintext protocol）在网络上传输时容易被窃听（sniffing），因此应优先使用加密版本：

| 明文协议（不安全） | 加密替代方案 |
|---|---|
| Telnet | **SSH**（Secure Shell） |
| FTP | **SFTP** / FTPS |
| HTTP | **HTTPS**（HTTP over TLS/SSL） |

### SSH 示例

SSH 是 Linux 系统管理中最常用的加密远程登录工具，默认监听 TCP 端口 22。

```bash
# 使用密码登录远程主机
$ ssh alice@192.168.1.10
alice@192.168.1.10's password:
Last login: Sun Jul 12 09:15:22 2026 from 192.168.1.5

# 使用密钥登录（更安全，避免暴力破解）
$ ssh -i ~/.ssh/id_ed25519 alice@192.168.1.10
```

**VPN（Virtual Private Network）** 则用于在不受信任的网络（如公共 Wi-Fi）上建立加密隧道（tunnel），保护整体网络流量的机密性（confidentiality），而不仅仅是单个应用协议。

## 防火墙基础

**Firewall（防火墙）** 是一种根据预定义规则过滤进出网络流量的机制，可以基于软件（如 Linux 内核的 `netfilter`/`iptables`、`firewalld`）或硬件实现。它的基本作用是：

- 阻止未经授权的入站连接（inbound connection）。
- 限制哪些服务/端口可以对外暴露。
- 记录（log）可疑的连接尝试以便审计。

```bash
# 查看当前 iptables 规则（示例输出）
$ sudo iptables -L
Chain INPUT (policy DROP)
target     prot opt source               destination
ACCEPT     tcp  --  anywhere             anywhere             tcp dpt:ssh
ACCEPT     tcp  --  anywhere             anywhere             tcp dpt:https
```

## Linux 用户类型（User Types）

Linux 是多用户系统（multi-user system），每个账户在 `/etc/passwd` 中都有对应的一行记录。系统会根据 **UID（User ID）** 区分不同类型的账户：

| 用户类型 | 典型 UID 范围 | 说明 |
|---|---|---|
| **root / superuser** | 0 | 拥有系统最高权限，可以绕过几乎所有权限检查 |
| **系统/服务账户（system account）** | 1–999（发行版而异） | 由系统或软件包创建，用于运行特定服务（如 `www-data`、`mysql`），通常不允许交互式登录 |
| **普通/标准用户（regular user）** | 1000 及以上 | 供真实人类用户日常使用，权限受限，需通过 `sudo` 才能执行管理操作 |

### 查看 /etc/passwd

```bash
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
alice:x:1000:1000:Alice Smith,,,:/home/alice:/bin/bash
```

每行字段依次为：用户名、密码占位符（`x` 表示真实密码存放在 `/etc/shadow`）、UID、GID（主组 ID）、GECOS 备注、家目录、登录 shell。可以看到，`daemon` 和 `www-data` 这类系统账户的 shell 通常设为 `/usr/sbin/nologin`，明确阻止交互式登录，这是一种降低攻击面的安全设计。

### 常用识别命令

```bash
# 查看当前用户的 UID/GID 及所属组
$ id
uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo)

# 查看当前登录用户名
$ whoami
alice

# 查看谁正登录在系统上
$ who
alice    tty1         2026-07-12 08:00

# 查看登录用户及其正在做什么
$ w
 09:20:01 up  1:20,  1 user,  load average: 0.00, 0.01, 0.05
USER     TTY      LOGIN@   IDLE   JCPU   PCPU WHAT
alice    tty1     08:00    1:20m  0.02s  0.02s -bash

# 查看历史登录记录
$ last
alice    tty1                          Sun Jul 12 08:00   still logged in
```

### root 权限的获取方式

出于安全考虑，日常操作不建议直接以 root 身份登录，而是使用以下两种机制临时获取管理权限：

```bash
# su：切换为 root 用户（需要 root 密码）
$ su -
Password:
# 提示符从 $ 变为 #，表示已切换为 root
#

# sudo：以 root 权限执行单条命令（需要当前用户自己的密码，且需在 sudoers 中授权）
$ sudo apt update
[sudo] password for alice:
```

`sudo` 相比直接使用 root 账户的优势在于：每次操作都会被记录在日志中（可审计性），且权限可以被精细地限制在特定命令上，符合最小权限原则。

## 小结

- Linux 面临的安全威胁包括 malware、未授权访问和各类网络攻击，需要通过更新、最小权限、强密码等基础措施防范。
- 应优先使用加密协议（SSH、HTTPS、VPN）代替明文协议传输敏感数据。
- Firewall 用于过滤网络流量，是网络安全的第一道防线。
- Linux 用户账户分为 root（UID 0）、系统账户（低 UID，通常不可登录）和普通用户（高 UID），可通过 `id`、`who`、`w`、`last` 等命令查看。
- `su` 和 `sudo` 是获取管理权限的两种主要方式，`sudo` 更符合安全最佳实践。

## 参考资料

- LPI Learning Materials — Topic 5.1: Basic Security and Identifying User Types: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- LPI Linux Essentials Exam Objectives (010-160), version 1.6: https://www.lpi.org/our-certifications/exam-160-objectives
- man pages: `man ssh`, `man sudo`, `man su`, `man passwd`, `man iptables`