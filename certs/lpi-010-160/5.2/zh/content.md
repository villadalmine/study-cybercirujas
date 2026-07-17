# 5.2 Creating Users and Groups

## 概述

Linux 是一个多用户 (multi-user) 系统，每一个能够登录或运行进程的实体都需要一个 user account，而组织用户权限的基本单位是 group。理解用户和组的创建、修改与查询，是系统管理员日常工作中最基础的任务之一。本节介绍与用户/组账户相关的核心配置文件，以及用于创建、修改、删除用户和组的命令行工具。

## 用户账户信息：/etc/passwd

每个用户账户的基本信息保存在 `/etc/passwd` 文件中，该文件对所有用户可读。每一行代表一个用户，字段之间用冒号 `:` 分隔：

```
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1001:1001:Alice Smith:/home/alice:/bin/bash
```

7 个字段依次为：

| 字段 | 说明 |
|---|---|
| username | 登录名，如 `alice` |
| password placeholder | 通常为 `x`，表示真实密码存放在 `/etc/shadow` |
| UID | 用户 ID（数字） |
| GID | 用户的主组（primary group）ID |
| GECOS | 用户全名等描述性信息（comment field） |
| home directory | 用户的主目录，如 `/home/alice` |
| login shell | 登录时启动的 shell，如 `/bin/bash`；`/usr/sbin/nologin` 表示禁止交互式登录 |

## 密码信息：/etc/shadow

出于安全考虑，加密后的密码不直接存放在人人可读的 `/etc/passwd` 中，而是存放在只有 root 可读的 `/etc/shadow` 中：

```
# cat /etc/shadow
alice:$6$RandomSalt$HashedPasswordString...:19500:0:99999:7:::
```

字段依次为：username、加密密码（`!` 或 `*` 表示账户被锁定/无密码登录）、上次修改日期（自 1970-01-01 起的天数）、最小修改间隔、最大有效期、警告天数、宽限期、账户失效日期，以及一个保留字段。这些字段可通过 `chage` 命令查看和修改，例如 `chage -l alice`。

## 组信息：/etc/group 与 /etc/gshadow

组信息存放在 `/etc/group`：

```
$ cat /etc/group
root:x:0:
sudo:x:27:alice
alice:x:1001:
developers:x:1002:alice,bob
```

字段为：group name、密码占位符（一般不用）、GID、成员列表（该组的 secondary/supplementary 成员，用逗号分隔）。注意：一个用户的 primary group 记录在 `/etc/passwd` 的 GID 字段中，不一定出现在 `/etc/group` 的成员列表里。`/etc/gshadow` 则存放组密码等敏感信息，结构与 `/etc/shadow` 类似。

## 创建用户：useradd

`useradd` 用于创建新用户账户：

```
# useradd -m -s /bin/bash -c "Alice Smith" alice
```

常用选项：

| 选项 | 作用 |
|---|---|
| `-m` | 创建主目录（如果不存在），并从 `/etc/skel` 复制默认文件 |
| `-d <dir>` | 指定自定义主目录路径 |
| `-s <shell>` | 指定登录 shell |
| `-c "<comment>"` | 设置 GECOS 字段（通常是全名） |
| `-u <uid>` | 指定 UID |
| `-g <group>` | 指定 primary group |
| `-G <group1,group2>` | 加入若干 secondary group |
| `-r` | 创建系统账户（system account），使用较低的 UID 范围且通常不创建 home 目录 |

创建用户后，`/etc/skel` 目录中的模板文件（如 `.bashrc`、`.bash_profile`）会被复制到新用户的主目录，作为其初始环境配置。

新建用户默认处于锁定状态（无法用密码登录），必须用 `passwd` 设置密码后才能登录：

```
# passwd alice
New password:
Retype new password:
passwd: password updated successfully
```

## 修改用户：usermod

`usermod` 用于修改已存在的用户账户属性，选项与 `useradd` 大体一致：

```
# usermod -aG developers alice
# usermod -s /usr/sbin/nologin alice
# usermod -L alice          # 锁定账户（在 /etc/shadow 密码前加 !）
# usermod -U alice          # 解锁账户
```

注意：`-G` 会覆盖用户当前的所有 secondary group，因此追加新组时必须搭配 `-a`（append），即 `-aG`，否则用户会被从原有的其他组中移除。

## 删除用户：userdel

```
# userdel alice          # 只删除账户，保留主目录
# userdel -r alice        # 同时删除主目录及邮件池 (mail spool)
```

## 创建和管理组：groupadd / groupmod / groupdel

```
# groupadd developers
# groupadd -g 2000 designers
# groupmod -n devs developers      # 重命名组
# groupdel designers
```

`-g` 可指定 GID；若组内仍有成员将其设为 primary group，则无法直接删除该组。

## 查询用户与组信息

| 命令 | 用途 |
|---|---|
| `id [username]` | 显示 UID、GID 及所属的所有组 |
| `groups [username]` | 显示用户所属的组列表 |
| `whoami` | 显示当前登录用户名 |
| `getent passwd alice` | 从 name service（含 NSS 后端，如 LDAP）中查询用户信息 |
| `getent group developers` | 查询组信息 |

示例：

```
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),27(sudo),1002(developers)
```

## 系统账户与普通账户的 UID 范围

Linux 发行版通常在 `/etc/login.defs` 中定义 UID/GID 的分配区间。典型划分为：

- `0`：root
- `1–999`（不同发行版略有差异，如 Debian 系用 `1–999`，RHEL 系常用 `1–999` 或 `201–999`）：系统账户 / 服务账户（如 `daemon`、`www-data`），通常没有交互式登录 shell
- `1000` 起：普通用户账户

可以用 `useradd -r` 创建低于此界限的系统账户，这类账户一般不需要 home 目录或登录能力。

## 用户私有组 (User Private Group, UPG)

许多发行版（如 Debian、Fedora）在创建用户时默认为其创建一个与用户名同名、GID 与 UID 相同的私有组（UPG），而不是把所有用户都放进公共的 `users` 组。这样每个用户的 primary group 只有自己一个成员，umask 可以更宽松（如 `002`）而不必担心文件被其他普通用户访问，同时仍可通过 secondary group 共享文件访问权限。

## 参考

- LPI Learning Materials — Topic 5.2: Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- `useradd(8)`, `usermod(8)`, `userdel(8)` man pages
- `groupadd(8)`, `groupmod(8)`, `groupdel(8)` man pages
- `passwd(5)`, `shadow(5)`, `group(5)`, `gshadow(5)` man pages
- `login.defs(5)` man page