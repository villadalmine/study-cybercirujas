# LPI Linux Essentials (010-160 v1.6) — Topic 4.4: Your Computer on the Network

## 実習ガイド

以下の実習は、Linux マシンがネットワーク上でどのように識別され、通信するかを体験的に理解するためのものです。実行環境はターミナルのある任意の Linux ディストリビューション（root 権限が不要なコマンドが中心ですが、一部は `sudo` が必要な場合があります）。

参考: LPI Learning Materials — https://learning.lpi.org/en/learning-materials/010-160/4/4.4/

---

### Exercise 1 — Network Interface の確認

1. ターミナルを開き、次のコマンドでシステム上の network interface 一覧を表示します。

   ```
   ip addr show
   ```

   （古いディストリビューションでは `ifconfig -a` でも代用できます）

2. 出力の中から `lo` という名前の interface を探します。これは loopback interface です。IPv4 アドレスが `127.0.0.1`、subnet mask が `/8`（つまり `255.0.0.0`）になっていることを確認してください。

3. 有線または無線の実際の interface（`eth0`, `enp0s3`, `wlan0` など環境により名前は異なります）を探し、その `inet` 行に書かれている IPv4 アドレスと `/xx` の prefix length（subnet mask）をメモします。

4. 同じ interface の行にある `link/ether` の後ろの値（例: `08:00:27:aa:bb:cc`）が MAC address です。これをメモしてください。

**確認問題**
- `127.0.0.1` はどのような用途のために予約されているアドレスですか。
- MAC address と IP address の違いを1文で説明してください。

---

### Exercise 2 — IP Address・Subnet Mask・Default Gateway の確認

1. 次のコマンドで routing table を表示します。

   ```
   ip route show
   ```

2. `default via <IPアドレス> dev <interface名>` という行を探します。この `<IPアドレス>` が default gateway（多くの場合、家庭用ルーターのアドレス）です。

3. Exercise 1 でメモした自分のアドレスと prefix length（例: `192.168.1.20/24`）から、この network の network address と broadcast address を計算してください（`/24` の場合、最初の3オクテットが同じであれば同一ネットワークです）。

4. 計算した内容を、次のコマンドの出力と照らし合わせて検証します（`ipcalc` がインストールされている場合）。

   ```
   ipcalc 192.168.1.20/24
   ```

   （自分の実際のアドレスに置き換えてください）

**確認問題**
- Default gateway の役割を、自分のマシンが別の subnet 上のホストと通信するときの流れとともに説明してください。
- `/24` の subnet mask は10進表記で何になりますか。またそのネットワークに割り当て可能なホスト数はいくつですか（network address と broadcast address を除く）。

---

### Exercise 3 — DHCP と Static Configuration の違いを確認する

1. 自分の interface の IP アドレスが DHCP client によって自動取得されたものか、static に設定されたものかを確認します。NetworkManager を使っている場合:

   ```
   nmcli device show <interface名>
   ```

   出力中の `IP4.ADDRESS` の割り当て方法（`DHCP4` セクションの有無）を確認してください。

2. DHCP lease の有効期限や DHCP server のアドレスを確認します（環境によりコマンドは異なります）。

   ```
   nmcli device show <interface名> | grep DHCP
   ```

3. もし static な IP 設定に変更する場合、どのファイルまたはツールを使うか（例: `nmcli`, `netplan`, `/etc/network/interfaces`）を、自分のディストリビューションについて調べてノートに記録してください（実際に変更する必要はありません）。

**確認問題**
- DHCP を使う利点と、Static configuration を使うべき場面（例: サーバー機）をそれぞれ1つ挙げてください。

---

### Exercise 4 — DNS Resolution の確認

1. `/etc/resolv.conf` の内容を確認します。

   ```
   cat /etc/resolv.conf
   ```

   `nameserver` として指定されている IP アドレス（DNS server）を確認してください。

2. `/etc/hosts` の内容を確認します。

   ```
   cat /etc/hosts
   ```

   `127.0.0.1 localhost` という行があることを確認してください。この仕組みにより、DNS server に問い合わせる前にローカルなホスト名解決ができます。

3. `host` コマンドで hostname から IP address への解決（forward lookup）を実行します。

   ```
   host www.lpi.org
   ```

4. `dig` コマンドでより詳細な DNS の問い合わせ結果を確認します。

   ```
   dig www.lpi.org
   ```

   `ANSWER SECTION` に表示される IP アドレスと、`host` コマンドの結果が一致することを確認してください。

**確認問題**
- `/etc/hosts` と DNS server（外部の nameserver）のどちらが名前解決で先に参照されるか、その仕組みを制御するファイルの名前とともに答えてください。
- `dig` の出力にある `ANSWER SECTION` は何を意味しますか。

---

### Exercise 5 — 疎通確認（ping と traceroute）

1. デフォルトゲートウェイに対して ping を実行します（Exercise 2 でメモしたアドレスを使用）。

   ```
   ping -c 4 <default gatewayのIPアドレス>
   ```

   応答時間（`time=` の値）と packet loss の割合を確認してください。

2. 外部ホストに対して ping を実行します。

   ```
   ping -c 4 www.lpi.org
   ```

   このとき ping はまず DNS resolution を行ってから ICMP packet を送信していることに注意してください。

3. `traceroute`（または `tracepath`）で、パケットが目的地に到達するまでに経由する router（hop）を確認します。

   ```
   traceroute www.lpi.org
   ```

   各行が1つの hop を表し、そこまでの往復時間（RTT）が表示されることを確認してください。

**確認問題**
- `ping` が使用するプロトコルは何ですか。
- `traceroute` の出力で、ある hop の応答時間が `* * *` と表示された場合、何が起きている可能性がありますか。

---

### Exercise 6 — Port・Service・Protocol の確認

1. 現在 listen している TCP/UDP port を確認します。

   ```
   ss -tuln
   ```

   （古い環境では `netstat -tuln`）

   `-t` は TCP、`-u` は UDP、`-l` は listening 状態のみ、`-n` は名前解決せず番号で表示、を意味します。

2. `/etc/services` ファイルを開き、well-known port の一覧を確認します。

   ```
   grep -w '22/tcp\|80/tcp\|443/tcp\|53/udp' /etc/services
   ```

   SSH (22), HTTP (80), HTTPS (443), DNS (53) がそれぞれ何番のポートに対応しているか確認してください。

3. 自分のマシンで SSH server（`sshd`）が動作している場合、それが `ss -tuln` の出力の中で port 22 として listen していることを確認してください。動作していない場合は、その port が出力に現れないことを確認してください。

**確認問題**
- TCP と UDP の主な違いを1つ挙げてください（例: 信頼性、コネクションの有無）。
- HTTP のデフォルト port 番号と、HTTPS のデフォルト port 番号をそれぞれ答えてください。
- DNS の問い合わせで主に使われる protocol（TCP か UDP か）とその理由を簡潔に述べてください。

---

<details>
<summary>解答例（クリックして展開）</summary>

**Exercise 1**
- `127.0.0.1` は loopback address であり、自分自身のマシン内で通信するために予約されている（ネットワークの外には出ない）。
- MAC address は network interface card（NIC）に割り当てられた物理的・固定的な識別子（Data Link layer）であり、IP address は論理的にネットワーク上の位置を示す、設定や DHCP によって変わりうるアドレス（Network layer）である。

**Exercise 2**
- Default gateway は、自マシンが属する subnet の外にあるホスト宛のパケットを転送してもらうための router のアドレス。宛先が同一 subnet になければ、パケットはまず default gateway に送られ、そこから先の経路へ転送される。
- `/24` は 10進表記で `255.255.255.0`。ホスト部が8ビットのため `2^8 - 2 = 254` 台のホストを割り当て可能（network address と broadcast address を除く）。

**Exercise 3**
- DHCP の利点: IP アドレスやDNS情報などを自動で取得でき、管理の手間が減り、アドレスの重複も防げる。
- Static configuration が適する場面: server機のように、常に同じ IP アドレスで到達可能である必要がある場合（DNS レコードや firewall ルールが特定の IP に依存するため）。

**Exercise 4**
- 名前解決の順序は通常 `/etc/nsswitch.conf` の `hosts:` 行で制御され、一般的には `/etc/hosts`（files）が DNS（dns）より先に参照される。
- `ANSWER SECTION` は、問い合わせた hostname に対する DNS server からの実際の回答（該当する IP アドレスなどの resource record）を示す。

**Exercise 5**
- `ping` は ICMP（Internet Control Message Protocol）の echo request/echo reply を使用する。
- `* * *` は、その hop の router が ICMP に応答しない（または応答をフィルタしている）ことを示している可能性がある。必ずしも経路上の障害を意味するわけではない。

**Exercise 6**
- TCP は接続指向（connection-oriented）でパケットの到達を保証する信頼性のあるプロトコルであるのに対し、UDP はコネクションレスで到達保証を行わない、軽量なプロトコルである。
- HTTP のデフォルト port は `80`、HTTPS のデフォルト port は `443`。
- DNS の問い合わせは主に UDP（port 53）を使用する。UDP はオーバーヘッドが小さく、通常1回のクエリと1回の応答で完結する軽量なやり取りに適しているため。ただし応答サイズが大きい場合（zone transfer など）は TCP が使われる。

</details>