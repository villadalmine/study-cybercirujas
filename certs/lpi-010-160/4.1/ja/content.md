# 4.1 Choosing an Operating System

## オペレーティングシステム（OS）とは

**Operating System (OS)** とは、コンピュータのハードウェアとユーザー（またはアプリケーション）の間を仲介するソフトウェアの層です。主な役割は次の通りです。

- **Process management**: 実行中のプログラム（プロセス）に CPU 時間を割り当てる
- **Memory management**: RAM の割り当てと保護
- **Device management**: ディスク、ネットワークカード、キーボードなどのハードウェアへのアクセスを制御する
- **File system management**: データをファイルやディレクトリという形で永続化する
- **User interface**: CLI（コマンドライン）や GUI（グラフィカルインターフェース）を通じて操作を可能にする

OS の中心部分は **kernel**（カーネル）と呼ばれ、ハードウェアと直接やり取りする最も低レベルなコードです。Linux の場合、"Linux" という言葉は本来カーネルそのものを指しますが、一般には kernel に GNU ツール群（bash, coreutils など）やその他のソフトウェアを組み合わせた **distribution（ディストリビューション）** 全体を指して「Linux」と呼ぶことが多いです。これを厳密に **GNU/Linux** と呼ぶこともあります。

## 主要な OS のカテゴリ

試験対策として、代表的な OS ファミリーとその特徴を押さえておく必要があります。

| OS | 特徴 |
|---|---|
| **Linux** | オープンソース、カーネルは Linus Torvalds が開発開始（1991年）。多数のディストリビューションが存在 |
| **BSD** (FreeBSD, OpenBSD, NetBSD) | Unix 系の別系統。ライセンスが Linux（GPL）と異なり、BSD license を採用 |
| **Unix** (AIX, Solaris, HP-UX) | 商用の proprietary Unix。大規模サーバー向けに使われることが多い |
| **Windows** | Microsoft の proprietary OS。デスクトップ市場で高いシェア |
| **macOS** | Apple の proprietary OS。実は BSD/Unix をベースにしている |
| **Android** | Google が開発。Linux kernel をベースにしたモバイル向け OS |
| **iOS** | Apple のモバイル向け OS。macOS 同様 Unix 系の系譜 |
| **ChromeOS** | Google の Linux kernel ベースの軽量デスクトップ OS |

ポイントは、**Linux kernel は Linux ディストリビューションだけでなく Android や ChromeOS にも使われている**という点です。逆に macOS や iOS は Linux kernel ではなく独自の XNU kernel（Darwin をベース）を使っています。

## Linux ディストリビューションのファミリー

Linux Essentials では、代表的なディストリビューションとその「系統（family）」を区別できることが求められます。

- **Debian 系**: Debian, Ubuntu, Linux Mint など。パッケージ管理は `dpkg` / `apt`
- **Red Hat 系**: Red Hat Enterprise Linux (RHEL), Fedora, CentOS, Rocky Linux, AlmaLinux。パッケージ管理は `rpm` / `dnf`（旧 `yum`）
- **SUSE 系**: openSUSE, SUSE Linux Enterprise。パッケージ管理は `rpm` / `zypper`
- **Arch 系**: Arch Linux, Manjaro。パッケージ管理は `pacman`
- **独立系 / その他**: Slackware（最古参のディストリビューションの一つ）、Gentoo（ソースからビルドする独自の Portage システム）

ディストリビューションの選択基準としては、用途（デスクトップ / サーバー / 組み込み）、パッケージ管理方式、リリースサイクル（rolling release か fixed release か）、商用サポートの有無などが挙げられます。

## 汎用 OS と組み込み・専用 OS

- **General-purpose OS**: デスクトップやサーバーなど幅広い用途を想定した OS（Ubuntu Desktop, Windows など）
- **Embedded / special-purpose OS**: 特定のハードウェアや用途に特化した OS。例えば、ルーターに搭載される OpenWrt、ネットワーク機器の Cisco IOS、家電に組み込まれる Linux ベースのファームウェアなど

同じ Linux kernel でも、デスクトップ向けの Ubuntu と組み込み機器向けの Yocto Project ベースのシステムでは、含まれるパッケージやリソース消費が大きく異なります。

## コマンドラインで OS 情報を確認する

実際にシステムにログインした際、どの OS・カーネル・ディストリビューションが動いているかを確認するコマンドを知っておくことは実務上も重要です。

**カーネルとアーキテクチャの確認 (`uname`)**

```console
$ uname -a
Linux myhost 6.8.0-45-generic #45-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
```

- `Linux` : kernel 名
- `6.8.0-45-generic` : kernel バージョン
- `x86_64` : CPU アーキテクチャ

**ディストリビューション情報の確認 (`/etc/os-release`)**

```console
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04 LTS"
```

`ID_LIKE=debian` からも分かるように、Ubuntu は Debian 系ディストリビューションであることがここで確認できます。

**`lsb_release` コマンド（LSB: Linux Standard Base 対応環境の場合）**

```console
$ lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 24.04 LTS
Release:        24.04
Codename:       noble
```

**systemd 環境でのホスト情報 (`hostnamectl`)**

```console
$ hostnamectl
 Static hostname: myhost
       Icon name: computer-vm
         Chassis: vm
      Machine ID: 8f3a1c...
   Operating System: Ubuntu 24.04 LTS
             Kernel: Linux 6.8.0-45-generic
       Architecture: x86-64
```

これらのコマンドは、サポート対象の OS を判断したり、パッケージの互換性を確認したりする際に頻繁に使われます。

## OS 選択の際の考慮点

実際にどの OS を選ぶかは、次のような観点で判断されます。

1. **ハードウェア対応**: 対象のドライバやファームウェアがサポートされているか
2. **ライセンスとコスト**: proprietary（有償・ソースコード非公開）か Open Source（無償・ソースコード公開）か
3. **用途**: デスクトップ利用、サーバー利用、組み込み利用のいずれか
4. **コミュニティとサポート**: 商用サポート契約が必要か、コミュニティベースで十分か
5. **リリースサイクル**: 安定性重視の LTS (Long Term Support) 版か、最新機能を追う rolling release か

## Referencias

- LPI Learning Materials — 4.1 Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- The Linux Kernel Archives: https://www.kernel.org/
- Debian Project: https://www.debian.org/
- Fedora Project: https://fedoraproject.org/
- Arch Linux: https://archlinux.org/
- freedesktop.org — os-release specification: https://www.freedesktop.org/software/systemd/man/latest/os-release.html