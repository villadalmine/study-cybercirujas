# 4.4 Your Computer on the Network

## この項目について

ネットワークに接続されたコンピュータが通信するためには、IP アドレス、サブネットマスク、デフォルトゲートウェイ、DNS といった基本設定が必要です。この項目では、Linux のクライアントマシンにおけるネットワーク設定の確認方法、静的 (static) 設定と動的 (DHCP) 設定の違い、そして基本的なトラブルシューティングツールの使い方を学びます。

## IP アドレスとサブネットマスク

IPv4 アドレスは 32 ビットの数値で、`192.168.1.10` のようにドット区切りの 10 進数 (dotted decimal notation) で表記されます。サブネットマスク (subnet mask) は、そのアドレスのうちどこまでがネットワーク部でどこからがホスト部かを示します。

たとえば `192.168.1.10/24` は、サブネットマスク `255.255.255.0` を意味し、`192.168.1.0`〜`192.168.1.255` が同じネットワークセグメントに属することを表します。この CIDR 表記 (`/24`) は prefix length と呼ばれます。

IPv6 アドレスは 128 ビットで、`2001:0db8:0000:0000:0000:ff00:0042:8329` のようにコロン区切りの 16 進数で表記されます。先頭のゼロ省略や `::`(連続するゼロブロックの省略、1 アドレスにつき1回のみ使用可)により短縮できます:

```
2001:db8::ff00:42:8329
```

IPv4 のプライベートアドレス範囲(RFC 1918)は以下の通りです。

| クラス範囲 | CIDR |
|---|---|
| 10.0.0.0 – 10.255.255.255 | 10.0.0.0/8 |
| 172.16.0.0 – 172.31.255.255 | 172.16.0.0/12 |
| 192.168.0.0 – 192.168.255.255 | 192.168.0.0/16 |

## デフォルトゲートウェイとルーティング

デフォルトゲートウェイ (default gateway) は、宛先が同一ネットワーク内にない場合にパケットを転送するルーター(通常はホームルーターやコアスイッチ)の IP アドレスです。ルーティングテーブル (routing table) にはどの宛先ネットワークにどのインターフェース/ゲートウェイ経由で到達するかが記録されています。

```
$ ip route show
default via 192.168.1.1 dev eth0 proto dhcp metric 100
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10 metric 100
```

上記の出力では、`192.168.1.0/24` 宛のパケットは直接 `eth0` から送信され、それ以外の宛先はすべて `192.168.1.1`(デフォルトゲートウェイ)経由で転送されることが分かります。

## ポート番号の基礎

TCP/IP 通信では、IP アドレスに加えてポート番号 (port number) がサービスを識別します。よく使われるウェルノウンポート (well-known ports, 0–1023) の例:

| ポート | サービス |
|---|---|
| 22 | SSH |
| 53 | DNS |
| 80 | HTTP |
| 443 | HTTPS |
| 67/68 | DHCP |

## 静的設定 (Static) と動的設定 (DHCP)

- **static**: 管理者が IP アドレス・サブネットマスク・ゲートウェイ・DNS サーバーを手動で固定設定する方式。サーバーなど、常に同じアドレスであってほしい機器に向いています。
- **DHCP (Dynamic Host Configuration Protocol)**: DHCP サーバーがネットワーク上のクライアントに自動で IP アドレスなどを割り当てる方式。一般的なデスクトップやノート PC で広く使われています。

現在のネットワークインターフェース設定は `ip` コマンド(`ip addr`, 旧来の `ifconfig` に相当)で確認します。

```
$ ip addr show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 08:00:27:4a:3b:1c brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 brd 192.168.1.255 scope global dynamic eth0
       valid_lft 84532sec preferred_lft 84532sec
    inet6 fe80::a00:27ff:fe4a:3b1c/64 scope link
       valid_lft forever preferred_lft forever
```

`dynamic` という表記から、このアドレスが DHCP により割り当てられたことが分かります。GUI 環境ではデスクトップの Network Manager(GNOME の「設定 > ネットワーク」など)から、有線/無線それぞれの接続方式(自動 (DHCP) / 手動 (static))やアドレスを設定できます。CLI からは `nmcli` で同様の操作が可能です。

```
$ nmcli device status
DEVICE  TYPE      STATE      CONNECTION
eth0    ethernet  connected  Wired connection 1
```

## DNS 設定

DNS (Domain Name System) は、ホスト名(例: `www.lpi.org`)を IP アドレスに変換します。クライアント側で使用する DNS サーバーは `/etc/resolv.conf` に記述されます。

```
$ cat /etc/resolv.conf
nameserver 192.168.1.1
nameserver 8.8.8.8
search example.com
```

- `nameserver`: 問い合わせ先の DNS サーバーの IP アドレス(複数指定可能で、上から順に試行)
- `search`: ホスト名の一部だけを指定した場合に補完されるドメイン

多くのディストリビューションでは、この内容は DHCP クライアントや `systemd-resolved` によって自動生成されるため、直接編集しない方がよい場合があります。

ローカルでの名前解決には `/etc/hosts` も使われ、DNS 問い合わせより先に参照されます(参照順序は `/etc/nsswitch.conf` の `hosts:` 行で制御)。

```
$ cat /etc/hosts
127.0.0.1   localhost
192.168.1.20 fileserver.local fileserver
```

## トラブルシューティングツール

### ping — 疎通確認

```
$ ping -c 3 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=12.3 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=115 time=11.9 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=115 time=12.1 ms

--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
```

`-c` で送信回数を指定しないと、Linux では Ctrl+C まで無限に送信し続けます。

### traceroute — 経路の確認

```
$ traceroute example.com
 1  192.168.1.1  1.021 ms  0.987 ms  0.955 ms
 2  10.0.0.1     8.213 ms  8.109 ms  8.077 ms
 3  203.0.113.1  15.442 ms  15.301 ms  15.209 ms
```

宛先までパケットが通過する各ルーター(ホップ)の応答時間を表示し、どこで経路が途切れているかの切り分けに使います。

### dig / host — DNS 問い合わせ

```
$ dig www.lpi.org +short
203.0.113.45
```

### ss / netstat — ソケット・接続状態の確認

```
$ ss -tunlp
Netid State  Local Address:Port  Peer Address:Port  Process
tcp   LISTEN 0.0.0.0:22          0.0.0.0:*           users:(("sshd",pid=812,fd=3))
tcp   LISTEN 127.0.0.1:631       0.0.0.0:*           users:(("cupsd",pid=903,fd=6))
```

`netstat` は多くのディストリビューションで非推奨(deprecated)となり、後継の `ss` コマンドへの移行が進んでいます。

## まとめ

| 確認したいこと | コマンド |
|---|---|
| IP アドレス・インターフェース状態 | `ip addr` |
| ルーティングテーブル | `ip route` |
| 疎通確認 | `ping` |
| 経路確認 | `traceroute` |
| DNS 名前解決 | `dig`, `host` |
| 開いているポート・接続 | `ss` |
| DNS サーバー設定 | `/etc/resolv.conf` |
| 静的ホスト名解決 | `/etc/hosts` |

## Referencias

- LPI Learning Materials — Topic 4.4: Your Computer on the Network: https://learning.lpi.org/en/learning-materials/010-160/4/4.4/
- Linux `ip` command manual (iproute2): https://man7.org/linux/man-pages/man8/ip.8.html
- `resolv.conf` manual: https://man7.org/linux/man-pages/man5/resolv.conf.5.html
- RFC 1918 — Address Allocation for Private Internets: https://www.rfc-editor.org/rfc/rfc1918
- `ss` command manual: https://man7.org/linux/man-pages/man8/ss.8.html