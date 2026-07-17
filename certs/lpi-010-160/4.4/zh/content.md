# 4.4 Your Computer on the Network

## 1. 网络基础概念

要让一台 Linux 主机能够在网络中通信，你需要理解几个核心概念：**IP address**、**subnet mask**、**default gateway**、**hostname** 和 **DNS**。这些配置项共同决定了主机如何被识别、如何路由数据包、以及如何将域名解析为地址。

### 1.1 IP address（IPv4）

IPv4 地址是一个 32-bit 的数字，通常写成四组十进制数（每组 0-255），用点分隔，例如 `192.168.1.10`。地址分为两部分：

- **network part**：标识主机所在的网络
- **host part**：标识网络内的具体主机

划分方式由 **subnet mask**（如 `255.255.255.0`）或 **CIDR notation**（如 `/24`）决定。例如 `192.168.1.10/24` 表示前 24 位是网络部分，后 8 位是主机部分，该网络最多可容纳 254 台主机（去掉网络地址和广播地址）。

常见的私有地址段（private address ranges，RFC 1918）：

| 范围 | CIDR |
|---|---|
| 10.0.0.0 – 10.255.255.255 | 10.0.0.0/8 |
| 172.16.0.0 – 172.31.255.255 | 172.16.0.0/12 |
| 192.168.0.0 – 192.168.255.255 | 192.168.0.0/16 |

**特殊地址**：
- `127.0.0.1`：loopback 地址，指向本机自己（`localhost`）
- `0.0.0.0`：表示"任意地址"，常用于监听所有网络接口

### 1.2 IPv6 简介

IPv6 地址是 128-bit，用冒号分隔的十六进制数表示，例如 `2001:0db8:85a3:0000:0000:8a2e:0370:7334`，可省略前导零并用 `::` 压缩连续的零段：`2001:db8:85a3::8a2e:370:7334`。IPv6 的 loopback 地址是 `::1`。

### 1.3 MAC address

每个网络接口（network interface）都有一个 **MAC address**（Media Access Control address），是烧录在网卡硬件中的 48-bit 唯一标识，格式如 `08:00:27:4e:3a:1c`。MAC 地址工作在 OSI 模型的 **Data Link layer (Layer 2)**，而 IP 地址工作在 **Network layer (Layer 3)**。

### 1.4 Default gateway

**Default gateway** 是主机在需要将数据包发往本地网络之外时使用的路由器地址。如果目标地址不在本机所属的子网内，数据包就会被发送到 default gateway 进行转发。

## 2. 查看和配置网络接口

### 2.1 `ip` 命令（推荐，现代 Linux 发行版标准工具）

查看所有网络接口及其 IP 地址：

```bash
$ ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:4e:3a:1c brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 brd 192.168.1.255 scope global dynamic eth0
       valid_lft 86000sec preferred_lft 86000sec
```

也可以简写为 `ip a`。查看路由表（routing table）：

```bash
$ ip route show
default via 192.168.1.1 dev eth0 proto dhcp metric 100
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10
```

第一行显示 default gateway 是 `192.168.1.1`。

临时给接口分配地址（重启后失效）：

```bash
$ sudo ip addr add 192.168.1.20/24 dev eth0
$ sudo ip link set eth0 up
```

### 2.2 `ifconfig`（传统工具，来自 net-tools，部分发行版已不默认安装）

```bash
$ ifconfig eth0
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.10  netmask 255.255.255.0  broadcast 192.168.1.255
        ether 08:00:27:4e:3a:1c  txqueuelen 1000  (Ethernet)
```

考试中可能同时考察 `ip` 和 `ifconfig` 两种写法的对应关系，建议两者都熟悉。

### 2.3 `hostname` 命令

查看或设置主机名：

```bash
$ hostname
myserver

$ hostname -I
192.168.1.10

$ sudo hostnamectl set-hostname newserver
```

主机名的持久配置文件通常是 `/etc/hostname`，本机名到 IP 的静态映射保存在 `/etc/hosts`：

```
127.0.0.1   localhost
192.168.1.10 myserver.example.com myserver
```

## 3. DHCP vs 静态配置

- **DHCP (Dynamic Host Configuration Protocol)**：网络中的 DHCP server 自动为主机分配 IP address、subnet mask、default gateway 和 DNS server，是最常见的家庭/办公网络配置方式。
- **静态配置 (static configuration)**：管理员手动指定固定的 IP 参数，常用于服务器、打印机等需要固定地址的设备。

在使用 NetworkManager 的系统上，可以用 `nmcli` 查看和管理连接：

```bash
$ nmcli device status
DEVICE  TYPE      STATE      CONNECTION
eth0    ethernet  connected  Wired connection 1

$ nmcli connection show "Wired connection 1"
```

## 4. DNS 域名解析

**DNS (Domain Name System)** 负责将人类可读的域名（如 `example.com`）解析为 IP 地址。

### 4.1 相关配置文件

- `/etc/resolv.conf`：指定 DNS server 地址

```
nameserver 8.8.8.8
nameserver 1.1.1.1
```

- `/etc/nsswitch.conf`：定义名字解析的查询顺序（先查 `/etc/hosts` 还是先查 DNS）

```
hosts: files dns
```

### 4.2 常用查询工具

`host` 命令：

```bash
$ host example.com
example.com has address 93.184.216.34
```

`dig` 命令（更详细，是 DNS 排错的首选工具）：

```bash
$ dig example.com

;; ANSWER SECTION:
example.com.        86400   IN      A       93.184.216.34
```

`nslookup`（较老，但仍常被考察）：

```bash
$ nslookup example.com
Server:         8.8.8.8
Address:        8.8.8.8#53

Name:   example.com
Address: 93.184.216.34
```

## 5. 网络连通性测试与排错工具

### 5.1 `ping`：测试主机是否可达

```bash
$ ping -c 4 example.com
PING example.com (93.184.216.34) 56(84) bytes of data.
64 bytes from 93.184.216.34: icmp_seq=1 ttl=56 time=12.3 ms
64 bytes from 93.184.216.34: icmp_seq=2 ttl=56 time=11.9 ms
...
--- example.com ping statistics ---
4 packets transmitted, 4 received, 0% packet loss
```

`-c 4` 限制只发送 4 个包（否则默认会一直发送直到 `Ctrl+C`）。

### 5.2 `traceroute` / `tracepath`：显示数据包经过的路径

```bash
$ traceroute example.com
 1  192.168.1.1 (192.168.1.1)  1.123 ms
 2  10.0.0.1 (10.0.0.1)  5.456 ms
 3  93.184.216.34 (93.184.216.34)  12.789 ms
```

每一跳（hop）代表一台路由器，用来定位网络延迟或中断发生的位置。

### 5.3 `netstat` / `ss`：查看网络连接和监听端口

`ss` 是 `netstat` 的现代替代品：

```bash
$ ss -tuln
Netid  State      Local Address:Port    Peer Address:Port
tcp    LISTEN     0.0.0.0:22            0.0.0.0:*
tcp    LISTEN     127.0.0.1:3306        0.0.0.0:*
```

- `-t`：TCP
- `-u`：UDP
- `-l`：只显示 listening 状态的 socket
- `-n`：不解析主机名/服务名（显示数字）

### 5.4 `curl` / `wget`：测试 HTTP(S) 服务

```bash
$ curl -I https://example.com
HTTP/2 200
content-type: text/html; charset=UTF-8
```

`-I` 只获取响应头（HEAD 请求），常用于快速确认服务是否在线。

## 6. 常见端口与协议对应关系（考试常考）

| 端口 | 协议/服务 |
|---|---|
| 22 | SSH |
| 21 | FTP |
| 23 | Telnet |
| 25 | SMTP |
| 53 | DNS |
| 67/68 | DHCP |
| 80 | HTTP |
| 443 | HTTPS |
| 3306 | MySQL |

端口与服务名的映射也可以在 `/etc/services` 文件中查到：

```bash
$ grep -w 80 /etc/services
http            80/tcp
```

## 7. 小结

| 任务 | 命令 |
|---|---|
| 查看/配置 IP 地址 | `ip addr`, `ifconfig` |
| 查看路由 | `ip route` |
| 查看/设置主机名 | `hostname`, `hostnamectl` |
| DNS 查询 | `host`, `dig`, `nslookup` |
| 测试连通性 | `ping`, `traceroute` |
| 查看端口/连接 | `ss`, `netstat` |
| 测试 HTTP 服务 | `curl`, `wget` |

## 参考文献 (References)

- LPI Learning Materials — Topic 4.4: Your Computer on the Network: https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- LPI Linux Essentials Exam Objectives (010-160, v1.6): https://www.lpi.org/our-certifications/linux-essentials-objectives
- `ip(8)` man page: https://man7.org/linux/man-pages/man8/ip.8.html
- `dig(1)` man page: https://man7.org/linux/man-pages/man1/dig.1.html
- `ss(8)` man page: https://man7.org/linux/man-pages/man8/ss.8.html
- RFC 1918 — Address Allocation for Private Internets: https://datatracker.ietf.org/doc/html/rfc1918