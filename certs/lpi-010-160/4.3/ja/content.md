# 4.3 Where Data is Stored

## この章の位置づけ

Linux システムでは「すべてがファイルである」という思想のもと、設定・ログ・実行ファイル・デバイス情報までもがファイルシステム上のパスとして表現されます。この章では、データがどこに、どのような規則で配置されているか、そしてストレージデバイスがどのようにファイルシステムへ接続（mount）されるかを扱います。試験の重み（3）に見合う範囲として、FHS（Filesystem Hierarchy Standard）の主要ディレクトリ、ドキュメントの探し方、mount の基本操作を押さえます。

## 1. Filesystem Hierarchy Standard (FHS)

Linux のディストリビューションは、ディレクトリ構成をバラバラに決めているわけではなく、**FHS (Filesystem Hierarchy Standard)** という共通規格に沿って `/`（root）以下を構成しています。これにより、どのディストリビューションでも「設定ファイルは `/etc` にある」「一時ファイルは `/tmp` にある」といった予測が可能になります。

```bash
$ ls -1 /
bin -> usr/bin
boot
dev
etc
home
lib -> usr/lib
media
mnt
opt
proc
root
run
sbin -> usr/sbin
srv
sys
tmp
usr
var
```

現代の多くのディストリビューション（Fedora, Debian 系など）では `/bin`, `/sbin`, `/lib` は `/usr/bin`, `/usr/sbin`, `/usr/lib` へのシンボリックリンクになっており（**usr-merge**）、実行ファイルは実質的に `/usr` 以下に集約されています。

## 2. 主要ディレクトリの役割

| ディレクトリ | 用途 |
|---|---|
| `/etc` | システム全体の設定ファイル（例: `/etc/fstab`, `/etc/passwd`） |
| `/var` | 頻繁に変化するデータ（ログ、キャッシュ、メールキュー、パッケージDB） |
| `/home` | 一般ユーザーのホームディレクトリ（例: `/home/alice`） |
| `/root` | root ユーザー専用のホームディレクトリ（`/home` の外にある点に注意） |
| `/boot` | カーネル (`vmlinuz`)、initramfs、bootloader の設定 |
| `/usr` | ユーザー向けプログラムと共有データ（`bin`, `lib`, `share/doc` など） |
| `/opt` | サードパーティ製アプリケーションを独立して配置する場所 |
| `/tmp` | 再起動で消えても構わない一時ファイル |
| `/dev` | デバイスファイル（例: `/dev/sda`, `/dev/null`, `/dev/tty0`） |
| `/proc` | カーネルとプロセス情報を公開する仮想ファイルシステム |
| `/sys` | カーネルオブジェクト・デバイス情報を公開する仮想ファイルシステム |
| `/media`, `/mnt` | リムーバブルメディアや一時的な mount 先の慣習的な場所 |

### `/var` の具体例

```bash
$ ls /var
cache  lib  local  log  mail  opt  spool  tmp

$ ls /var/log | head -5
audit
boot.log
cron
dnf.log
messages
```

### `/proc` と `/sys` — 実ファイルではない情報源

`/proc` はディスク上に実在するファイルではなく、カーネルがメモリ上の情報をファイルのように見せている **pseudo-filesystem** です。

```bash
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz

$ cat /proc/meminfo | head -3
MemTotal:       16218404 kB
MemFree:         2103212 kB
MemAvailable:    9871232 kB

$ cat /proc/version
Linux version 6.10.0 (...) gcc (GCC) 13.2.1 ...
```

`/sys` はデバイスやカーネルモジュールの階層をエクスポートします。

```bash
$ cat /sys/class/net/eth0/address
52:54:00:12:34:56
```

## 3. ドキュメントの場所

### man ページ

各コマンドの詳細は **man page** で確認します。man はセクション番号（1: コマンド, 5: ファイル形式, 8: 管理コマンド、など）で分類されています。

```bash
$ man 5 fstab
$ man -k mount        # キーワード検索 (apropos と同義)
```

### `/usr/share/doc`

パッケージがインストールされると、README や changelog などの追加ドキュメントが `/usr/share/doc/<package>/` に配置されます。

```bash
$ ls /usr/share/doc/bash/
AUTHORS  CHANGES  COMPAT  NEWS  README  RBASH
```

### `--help` と `info`

軽い確認には `--help`、GNU 系コマンドの詳細な解説には `info` も使われます。

```bash
$ cp --help | head -3
Usage: cp [OPTION]... [-T] SOURCE DEST
  or:  cp [OPTION]... SOURCE... DIRECTORY
  or:  cp [OPTION]... -t DIRECTORY SOURCE...
```

## 4. Mounting と Mount Point

Linux では、ディスクパーティションや USB メモリ、CD-ROM などのストレージは、単一のディレクトリツリー上の**特定のディレクトリ（mount point）に接続（mount）**されて初めてアクセスできるようになります（Windows のように独立したドライブレターは持ちません）。

### 現在の mount 状況を確認する

```bash
$ mount | column -t
/dev/sda2 on / type ext4 (rw,relatime)
/dev/sda1 on /boot type ext4 (rw,relatime)
tmpfs     on /tmp type tmpfs (rw,nosuid,nodev)
```

### `df` でディスク使用量を確認する

```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        50G   18G   30G  38% /
/dev/sda1       1014M  180M  765M  20% /boot
tmpfs           7.9G     0  7.9G   0% /dev/shm
```

`du` はディレクトリ単位の使用量を調べる際に使います。

```bash
$ du -sh /var/log
128M    /var/log
```

### USB メモリを手動で mount する

```bash
$ lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sda      8:0    0   50G  0 disk
├─sda1   8:1    0    1G  0 part /boot
└─sda2   8:2    0   49G  0 part /
sdb      8:16   1   16G  0 disk
└─sdb1   8:17   1   16G  0 part

$ sudo mount /dev/sdb1 /mnt
$ ls /mnt
photos  notes.txt

$ sudo umount /mnt
```

### `/etc/fstab` — 起動時に自動マウントする設定

`/etc/fstab` には、システム起動時に自動的に mount すべきファイルシステムが記述されています。各行は「デバイス、mount point、type、options、dump、pass」の6フィールドです。

```bash
$ cat /etc/fstab
# <device>                                <mountpoint> <type> <options>        <dump> <pass>
UUID=1a2b3c4d-...                         /            ext4   defaults         0      1
UUID=5e6f7a8b-...                         /boot        ext4   defaults         0      2
tmpfs                                     /tmp         tmpfs  defaults,noatime 0      0
```

デバイス名（`/dev/sda1` など）はディスクの接続順によって変わりうるため、実運用では変化しない **UUID** で指定するのが一般的です。UUID は `blkid` で確認できます。

```bash
$ sudo blkid /dev/sda1
/dev/sda1: UUID="1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d" TYPE="ext4"
```

## まとめ

- ディレクトリ構成は **FHS** に沿って標準化されており、`/etc`（設定）、`/var`（可変データ）、`/home`（ユーザーデータ）、`/tmp`（一時ファイル）など役割ごとに分離されている。
- `/proc` と `/sys` はディスク上のファイルではなく、カーネル情報をファイルのように見せる仮想ファイルシステムである。
- ドキュメントは `man`、`info`、`--help`、`/usr/share/doc` の複数の場所に分散している。
- ストレージデバイスは mount point に mount して初めて使用可能になり、`mount`/`umount`/`df`/`du`/`lsblk`/`blkid` で状態を調査・操作でき、恒久的な設定は `/etc/fstab` に記述する。

## Referencias

- LPI Learning Materials, "4.3 Where Data is Stored": https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Filesystem Hierarchy Standard 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html
- `fstab(5)` man page: https://man7.org/linux/man-pages/man5/fstab.5.html
- `mount(8)` man page: https://man7.org/linux/man-pages/man8/mount.8.html
- Linux kernel documentation, `/proc` filesystem: https://www.kernel.org/doc/html/latest/filesystems/proc.html
- `df(1)` man page: https://man7.org/linux/man-pages/man1/df.1.html
- `du(1)` man page: https://man7.org/linux/man-pages/man1/du.1.html