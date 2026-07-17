# 4.2 Understanding Computer Hardware

## 概要

Linux Essentials 010-160 の Topic 4.2 では、PC やサーバーを構成する物理的な**ハードウェアコンポーネント**の基礎知識と、Linux システム上でそれらの情報を調べるための基本的なコマンドを扱います。試験での重み(weight)は 2 であり、細かい電子工学的な知識よりも、「どのハードウェアがどう見えるか」「どのコマンドで何を確認できるか」という実践的な理解が問われます。

具体的には以下を理解することが目標です。

- CPU、メモリ、ストレージ、バス、周辺機器といった基本的なハードウェア構成
- `lscpu`、`lspci`、`lsusb`、`lsblk`、`dmidecode` などでハードウェア情報を取得する方法
- デバイスドライバ(kernel module)と `udev` による動的なデバイス管理
- 仮想デバイス(virtual filesystem、virtual memory、virtual network device)の概念
- BIOS/UEFI といったシステムファームウェアの基礎
- マルチブート(dual boot)環境で発生しやすい問題

## コンピュータハードウェアの基本構成要素

### CPU (Central Processing Unit)

CPU はプログラムの命令を実行する中心的な処理装置です。近年の CPU は 1 つの物理チップに複数の**コア(core)**を持ち、さらに**ハイパースレッディング(hyper-threading)**によって 1 コアが複数の論理 CPU(logical CPU)として見えることがあります。

```console
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
Byte Order:               Little Endian
CPU(s):                   8
  On-line CPU(s) list:    0-7
Vendor ID:                GenuineIntel
  Model name:              Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
    CPU family:            6
    Thread(s) per core:    2
    Core(s) per socket:    4
    Socket(s):             1
```

`/proc/cpuinfo` を読むことでも同様の情報が得られます。

```console
$ grep -c ^processor /proc/cpuinfo
8
$ grep "model name" /proc/cpuinfo | head -1
model name : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

### メモリ (RAM)

RAM(Random Access Memory)は実行中のプログラムやデータを一時的に保持する主記憶装置です。物理メモリが不足すると、ディスク上の**swap 領域**が仮想メモリとして利用されます(後述)。

```console
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4.2Gi       6.1Gi       412Mi        5.3Gi        10Gi
Swap:          2.0Gi          0B       2.0Gi
```

`/proc/meminfo` はより詳細な内訳を提供します。

```console
$ head -5 /proc/meminfo
MemTotal:       16305408 kB
MemFree:         6396920 kB
MemAvailable:   10485760 kB
Buffers:          212480 kB
Cached:          4820392 kB
```

### ストレージデバイス

ハードディスク(HDD)、ソリッドステートドライブ(SSD)、NVMe デバイスなどの記憶装置です。`lsblk` はブロックデバイスとそのパーティション構成をツリー表示します。

```console
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda           8:0    0 238.5G  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
├─sda2        8:2    0     1G  0 part /boot
└─sda3        8:3    0   237G  0 part /
nvme0n1     259:0    0 465.8G  0 disk
└─nvme0n1p1 259:1    0 465.8G  0 part /home
```

ディスクの空き容量は `df` で確認します。

```console
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda3       233G   42G  180G  19% /
```

### バスと拡張スロット

**バス(bus)**は CPU・メモリ・周辺機器の間でデータをやり取りする経路です。現代の PC では主に **PCI Express(PCIe)** がグラフィックカードやネットワークカード、NVMe SSD の接続に使われ、外部デバイスの接続には **USB** バスが広く使われます。PCI 接続のデバイス一覧は `lspci` で確認できます。

```console
$ lspci
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620
00:14.0 USB controller: Intel Corporation Sunrise Point-LP USB 3.0 xHCI Controller
02:00.0 Non-Volatile memory controller: Samsung Electronics NVMe SSD Controller
03:00.0 Network controller: Intel Corporation Wireless-AC 9260
```

`-v` オプションを付けるとより詳細な情報(使用中のカーネルモジュールなど)が表示されます。

```console
$ lspci -v -s 02:00.0
02:00.0 Non-Volatile memory controller: Samsung Electronics NVMe SSD Controller
        Subsystem: Samsung Electronics NVMe SSD Controller
        Kernel driver in use: nvme
        Kernel modules: nvme
```

### 周辺機器とポート

キーボード、マウス、プリンタ、外部ストレージなどは主に **USB(Universal Serial Bus)** で接続されます。USB デバイスの一覧は `lsusb` で確認します。

```console
$ lsusb
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 001 Device 002: ID 8087:0025 Intel Corp. Bluetooth
Bus 002 Device 004: ID 0781:5583 SanDisk Corp. Ultra Fit
```

## ハードウェア情報を取得するための総合コマンド

### dmidecode

`dmidecode` は **DMI(Desktop Management Interface)/ SMBIOS** のテーブルを読み取り、マザーボード、BIOS バージョン、メモリスロットの構成など、ファームウェアが保持するハードウェア情報を表示します。root 権限が必要です。

```console
$ sudo dmidecode -t system
System Information
        Manufacturer: Dell Inc.
        Product Name: XPS 13 9370
        Serial Number: ABCD1234

$ sudo dmidecode -t memory | grep -A3 "Memory Device"
Memory Device
        Size: 8 GB
        Type: LPDDR3
        Speed: 2133 MT/s
```

### /proc と /sys 仮想ファイルシステム

`/proc` と `/sys` は実際のディスク上には存在しない**仮想ファイルシステム(virtual filesystem)**で、カーネルが保持するハードウェアやプロセスの情報をファイルの形でエクスポートします。

| パス | 内容 |
|---|---|
| `/proc/cpuinfo` | CPU の詳細情報 |
| `/proc/meminfo` | メモリ使用状況 |
| `/proc/partitions` | 認識されているパーティション一覧 |
| `/proc/interrupts` | 割り込み(IRQ)の使用状況 |
| `/sys/class/net/` | ネットワークインターフェースの情報 |
| `/sys/block/` | ブロックデバイスの情報 |

```console
$ ls /sys/class/net/
enp0s31f6  lo  wlp2s0
```

### dmesg

`dmesg` はカーネルのリングバッファに記録されたメッセージを表示します。起動時にデバイスが認識される様子や、USB デバイスを挿した際の検出ログを確認するのに便利です。

```console
$ dmesg | grep -i usb | tail -3
[12345.678901] usb 2-1: new high-speed USB device number 4 using xhci_hcd
[12345.789012] usb-storage 2-1:1.0: USB Mass Storage device detected
[12345.812345] sd 4:0:0:0: [sdb] Attached SCSI removable disk
```

## デバイスドライバとカーネルモジュール

ハードウェアを OS が利用できるようにするソフトウェアが **device driver** です。Linux ではドライバの多くが **kernel module** として実装されており、必要に応じて動的にロード/アンロードできます。

```console
$ lsmod | head -5
Module                  Size  Used by
nvidia_uvm            995328  0
snd_hda_codec_hdmi     69632  1
btusb                  61440  0
```

```console
$ sudo modprobe -r btusb   # モジュールをアンロード
$ sudo modprobe btusb      # モジュールをロード(依存関係も自動解決)
```

`insmod` / `rmmod` は依存関係を自動解決しない低レベルなコマンドで、通常は依存関係を解決してくれる `modprobe` を使うのが推奨されます。

### udev による動的デバイス管理

`udev` は、USB メモリの抜き差しなどデバイスの接続・切断(**hot-plug**)をカーネルから通知(uevent)されると、`/dev` 以下に適切なデバイスノードを動的に作成・削除する仕組みです。ルールは `/etc/udev/rules.d/` や `/usr/lib/udev/rules.d/` に配置され、`udevadm` コマンドで情報確認やルールの再読み込みができます。

```console
$ udevadm info --query=all --name=/dev/sdb
P: /devices/pci0000:00/.../block/sdb
N: sdb
E: ID_VENDOR=SanDisk
E: ID_MODEL=Ultra_Fit
```

## 仮想デバイス (Virtual Devices)

物理ハードウェアを模倣する、あるいはソフトウェアのみで実装されたデバイスも Linux では多く存在します。

- **仮想ファイルシステム**: `/proc`、`/sys`、`tmpfs` はディスクではなくメモリ上に存在します。
- **仮想メモリ**: 物理 RAM が不足すると、ディスク上の**swap パーティション/swap ファイル**を使って仮想的にメモリ容量を拡張します。
- **仮想ネットワークデバイス**: `lo`(ループバック)、`docker0`、`veth`、`tun`/`tap` などはネットワークカードを介さずカーネル内部で完結する仮想インターフェースです。

```console
$ ip link show lo
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
$ swapon --show
NAME      TYPE       SIZE USED PRIO
/swap.img file       2G     0B   -2
```

## システムファームウェア: BIOS と UEFI

**BIOS(Basic Input/Output System)**は従来型のファームウェアで、電源投入時にハードウェアを初期化しブートローダーを起動します。近年の PC の多くは、より高機能で GPT パーティションテーブルからの起動やセキュアブートに対応した **UEFI(Unified Extensible Firmware Interface)** を採用しています。

システムが UEFI モードで起動しているかどうかは、次のディレクトリの有無で確認できます。

```console
$ ls /sys/firmware/efi
config_table  efivars  fw_platform_size  mokvar  runtime  systab
```

このディレクトリが存在しなければ、レガシー BIOS モードで起動していることを意味します。

## マルチブート環境における注意点

複数の OS を 1 台のコンピュータにインストールする(**dual boot**)場合、以下の点に注意が必要です。

- **パーティションテーブルの形式**: レガシー BIOS では **MBR(Master Boot Record)**、UEFI では **GPT(GUID Partition Table)** が一般的に使われます。異なる形式を混在させるとブートに失敗することがあります。
- **ブートローダー**: Linux では **GRUB(GRand Unified Bootloader)** が標準的に使われ、他 OS のエントリを検出してブートメニューに追加できます(`os-prober` の利用など)。
- **ファイルシステムの互換性**: Windows は NTFS/exFAT、Linux は ext4/XFS/Btrfs などを使うのが一般的です。Linux は NTFS を読み書きできますが、Windows は標準では ext4 を認識できません。
- **時刻(hardware clock)のずれ**: Windows はハードウェアクロックをローカルタイムとして扱う一方、Linux は UTC として扱うのがデフォルトです。これが原因で OS を切り替えるたびに時刻がずれることがあります。

```console
$ sudo update-grub          # Debian/Ubuntu 系: GRUB の設定を再生成
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL/Fedora 系
```

## まとめ

Topic 4.2 では、CPU・メモリ・ストレージ・バス・周辺機器といった物理ハードウェアの基礎に加え、`lscpu`・`lspci`・`lsusb`・`lsblk`・`dmidecode`・`/proc`・`/sys` といったコマンドやインターフェースでハードウェア情報を調べる方法を学びました。さらに、kernel module と udev による動的なデバイス管理、仮想デバイスの概念、BIOS/UEFI の違い、そしてマルチブート環境特有の注意点を押さえることが、実務でもトラブルシューティングの基礎になります。

## Referencias

- LPI Learning Materials — 4.2 Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- Linux Kernel Documentation — Filesystems (/proc): https://www.kernel.org/doc/html/latest/filesystems/proc.html
- Linux Kernel Documentation — sysfs: https://www.kernel.org/doc/html/latest/filesystems/sysfs.html
- freedesktop.org — udev documentation: https://www.freedesktop.org/software/systemd/man/latest/udev.html
- GNU GRUB Manual: https://www.gnu.org/software/grub/manual/grub/grub.html
- man7.org — lscpu(1): https://man7.org/linux/man-pages/man1/lscpu.1.html
- man7.org — lspci(8): https://man7.org/linux/man-pages/man8/lspci.8.html
- man7.org — dmidecode(8): https://man7.org/linux/man-pages/man8/dmidecode.8.html