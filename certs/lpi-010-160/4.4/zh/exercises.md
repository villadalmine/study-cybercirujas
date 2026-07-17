# LPI Linux Essentials（010-160，v1.6）主题 4.4：Your Computer on the Network — 引导式练习

参考资料（仅作背景参考，内容为原创编写）：
- https://learning.lpi.org/en/learning-materials/010-160/4/4.4/

---

## 练习 1：查看你的网络接口和 IP 配置

1. 打开终端，运行以下命令查看当前主机上所有的网络接口（network interface）：
   ```
   ip a
   ```
2. 在输出中找到你的主用有线或无线接口（通常不是 `lo`），记录它的名字（例如 `eth0`、`enp0s3`、`wlan0`）。
3. 在该接口的输出中找到 `inet` 后面的地址，这就是它的 IPv4 address，格式类似 `192.168.1.10/24`。
4. 斜杠后面的数字（如 `/24`）叫作 CIDR prefix，它等价于一个 subnet mask（例如 `/24` 对应 `255.255.255.0`）。用下面的命令确认路由信息和默认网关（default gateway）：
   ```
   ip route
   ```
5. 找到以 `default via` 开头的那一行，`via` 后面的地址就是你的 gateway，也就是数据包离开本地网络（LAN）前往外部网络（WAN）时经过的第一跳。

**检查理解：**
- `/24` 这个 prefix 对应的 subnet mask 是什么？它能容纳多少台主机（不考虑 network address 和 broadcast address）？
- 如果 `ip route` 的输出中没有 `default via` 这一行，会对访问互联网产生什么影响？

---

## 练习 2：区分公网地址与私网地址

1. 再次运行 `ip a`，记下你在练习 1 中找到的 IPv4 address。
2. 判断这个地址是否属于以下私网（private network，RFC 1918）范围之一：
   - `10.0.0.0` – `10.255.255.255`
   - `172.16.0.0` – `172.31.255.255`
   - `192.168.0.0` – `192.168.255.255`
3. 如果地址落在上述范围内，说明你的主机使用的是 private IP address，需要通过 NAT（Network Address Translation）才能与互联网上的主机通信。
4. 运行下面的命令，查看你的主机在互联网上对外呈现的 public IP address（需要联网）：
   ```
   curl ifconfig.me
   ```
5. 比较步骤 1 的地址和步骤 4 的地址是否相同。

**检查理解：**
- 如果两个地址不同，是谁（哪个设备）在做地址转换？
- 为什么家庭路由器背后可以有多台设备同时共享同一个 public IP address？

---

## 练习 3：主机名解析（hostname resolution）

1. 查看当前主机的 hostname：
   ```
   hostname
   ```
2. 查看本地静态解析表：
   ```
   cat /etc/hosts
   ```
   注意其中通常至少有一行把 `127.0.0.1` 映射到 `localhost`。
3. 查看系统当前使用的 DNS server 配置（不同发行版路径可能不同，先尝试）：
   ```
   cat /etc/resolv.conf
   ```
4. 使用 DNS 主动解析一个域名，观察它对应的 IP address：
   ```
   host www.lpi.org
   ```
   如果系统没有 `host` 命令，可以改用：
   ```
   getent hosts www.lpi.org
   ```
5. 在 `/etc/hosts` 中临时添加一行（仅用于测试，练习后可删除），把某个不存在的域名指向 `127.0.0.1`，例如：
   ```
   127.0.0.1   miprueba.local
   ```
   然后运行 `ping -c 2 miprueba.local`，观察它是否直接解析到 `127.0.0.1`，而不经过 DNS。

**检查理解：**
- Linux 在解析主机名时，`/etc/hosts` 和 DNS 的查询顺序通常是怎样的？
- 为什么在企业内网中，管理员有时会用 `/etc/hosts` 而不是 DNS 来做内部测试？

---

## 练习 4：测试网络连通性

1. 使用 `ping` 测试到网关的连通性（把地址换成你在练习 1 中记录的 gateway）：
   ```
   ping -c 4 192.168.1.1
   ```
2. 观察输出中的 `time=` 字段，这是 round-trip time（往返时延），单位是毫秒。
3. 测试到一个外部公共服务器的连通性：
   ```
   ping -c 4 8.8.8.8
   ```
4. 使用 `traceroute`（如果没有安装，可以用 `tracepath`）查看数据包从本机到目标之间经过的每一跳（hop）：
   ```
   traceroute 8.8.8.8
   ```
5. 对比只用 IP address 的 `ping 8.8.8.8` 和用域名的 `ping www.lpi.org`：如果域名版本失败但 IP 版本成功，说明问题出在哪一层？

**检查理解：**
- `ping` 无法到达某个地址，可能的原因有哪些（至少列举两种，例如目标主机关闭 ICMP、网络中断、防火墙拦截）？
- `traceroute` 展示的每一跳分别代表什么？

---

## 练习 5：识别常见端口与 client/server 交互

1. 查看系统中定义的常见服务与其对应端口（port）：
   ```
   grep -E '^(ssh|http|https|ftp|smtp|dns) ' /etc/services
   ```
2. 观察输出中每个服务名对应的端口号和协议（TCP 或 UDP），例如 `ssh 22/tcp`、`http 80/tcp`。
3. 使用 `curl` 模拟一次简单的 HTTP client 请求，观察 client/server 交互：
   ```
   curl -I https://www.lpi.org
   ```
   `-I` 只请求响应头（header），可以看到 server 返回的状态码。
4. 查看本机当前正在监听（listening）哪些端口，即哪些服务在本机上扮演 server 角色：
   ```
   ss -tulpn
   ```
5. 在输出中找出协议列（`tcp` 或 `udp`）以及本地地址列（`Local Address:Port`），确认端口号与练习中看到的常见服务是否对应。

**检查理解：**
- 端口 22、80、443 分别通常对应哪个服务？
- 在 client/server 模型中，发起连接请求的一方叫什么？被动等待并响应请求的一方叫什么？

---

<details>
<summary>参考答案（点击展开）</summary>

**练习 1**
- `/24` 对应的 subnet mask 是 `255.255.255.0`。这个网段共有 2^8=256 个地址，去掉 network address 和 broadcast address 后，可用主机地址为 254 个。
- 如果没有 default gateway，本机仍然可以与同一 subnet 内的其他主机通信，但无法访问 subnet 之外（包括互联网）的主机，因为不知道把不属于本网段的数据包发往哪里。

**练习 2**
- 是路由器（通常是家庭或办公网络出口的 router/网关设备）在做 NAT，把内网多个 private address 转换为一个 public IP address 对外通信。
- 因为 NAT 通过记录每条连接的源端口号，把不同设备的流量在同一个 public IP 下区分开，返回的流量再根据端口映射转发回正确的内网设备。

**练习 3**
- 通常先查 `/etc/hosts`（或由 `nsswitch.conf` 配置的顺序决定），如果没有匹配项，再向 `/etc/resolv.conf` 中配置的 DNS server 发起查询。
- 因为内部测试环境的域名往往还没有在正式 DNS 中注册，或者需要临时把域名指向某个测试用的 IP（例如本机或内部服务器），使用 `/etc/hosts` 可以跳过公共 DNS，快速验证。

**练习 4**
- 可能的原因包括：目标主机或中间设备的防火墙丢弃了 ICMP 报文、目标主机本身关闭、网络链路中断、路由配置错误等。
- `traceroute` 的每一跳代表数据包从源到目的地过程中经过的一个 router（三层转发设备），可以看到每一跳的地址和到达该跳的往返时延。

**练习 5**
- 端口 22 对应 SSH（远程登录），端口 80 对应 HTTP，端口 443 对应 HTTPS（加密的 HTTP）。
- 主动发起连接请求的一方叫 client；被动监听端口、等待并响应请求的一方叫 server。

</details>