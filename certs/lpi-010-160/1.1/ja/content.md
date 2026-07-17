# Linux Evolution and Popular Operating Systems

## Linux とは何か

**Linux** は、**Linus Torvalds** が1991年にフィンランドのヘルシンキ大学在学中に開発を始めた **kernel**(オペレーティングシステムの中核部分)です。当初は個人的な趣味のプロジェクトとして、Intel 386 プロセッサ向けの Unix 互換 kernel として公開されました。

重要なのは、「Linux」という言葉が厳密には **kernel** のみを指すという点です。私たちが日常的に「Linux」と呼んでいるオペレーティングシステムは、実際には Linux kernel に **GNU project** のツール群(シェル、コンパイラ、ユーティリティなど)やその他のソフトウェアを組み合わせた総体であり、これを **GNU/Linux** と呼ぶこともあります。

```
$ uname -a
Linux myhost 6.8.0-generic #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
```

`uname -a` の出力からも、kernel 名(Linux)、hostname、kernel バージョン、アーキテクチャなどが確認できます。

## 歴史的背景

### Unix の系譜

Linux のルーツは1969年に AT&T Bell Labs で **Ken Thompson** と **Dennis Ritchie** によって開発された **Unix** に遡ります。Unix は以下の設計思想を持っていました。

- 「一つのプログラムに一つの仕事をさせる」という **モジュール性**
- テキストベースの入出力と **パイプ (pipe)** による連携
- マルチユーザー・マルチタスク対応

Unix はその後、商用ライセンスの制約から複数の亜種(BSD, System V など)に分岐しました。

### GNU project と Free Software

1983年、**Richard Stallman** は **GNU project**(GNU's Not Unix の再帰的頭字語)を開始し、完全にフリーな Unix 互換システムの構築を目指しました。GNU project は **GCC**(コンパイラ)、**Bash**(シェル)、**GNU Core Utilities** など多くの基盤ソフトウェアを生み出しましたが、独自の kernel(**GNU Hurd**)の開発は難航していました。

Stallman はまた **Free Software Foundation (FSF)** を設立し、**GPL (GNU General Public License)** という copyleft ライセンスを策定しました。GPL は「派生物も同じ自由な条件で配布しなければならない」という思想に基づいています。

### Linux kernel の誕生

1991年、Linus Torvalds が Usenet に投稿した有名なメッセージ("I'm doing a (free) operating system...")をきっかけに Linux kernel の開発が始まりました。GNU project のツール群と Linux kernel が組み合わさることで、初めて完全にフリーな Unix 互換オペレーティングシステムが実用段階に到達しました。これが今日の GNU/Linux システムの基礎です。

Linux kernel はライセンスとして **GPLv2** を採用しており、この選択が Linux の急速な普及とコミュニティ主導の開発モデルを支えています。

## Open Source と Free Software の違い

両者は似ていますが、強調点が異なります。

| 観点 | Free Software (FSF) | Open Source (OSI) |
|---|---|---|
| 主導組織 | Free Software Foundation | Open Source Initiative (OSI) |
| 重視する点 | 利用者の自由(倫理的側面) | 開発手法としての実用的優位性 |
| 代表ライセンス | GPL | MIT, Apache, BSD など多様 |

どちらの陣営も **OSS (Open Source Software)** としてソースコードの公開・改変・再配布の自由を認める点では共通しています。

## ディストリビューション (Distributions)

Linux kernel 単体では OS として利用できないため、kernel・GNU tools・パッケージ管理システム・デスクトップ環境などをまとめた **ディストリビューション (distro)** という形で配布されます。

### 主要なディストリビューションファミリー

**Debian 系**
- **Debian**: コミュニティ主導、安定性重視
- **Ubuntu**: Canonical 社が開発、デスクトップ・サーバー両方で人気
- パッケージ形式: `.deb`、管理ツール: `apt`, `dpkg`

**Red Hat 系**
- **Red Hat Enterprise Linux (RHEL)**: 商用サポート付き
- **Fedora**: RHEL の実験的な上流版、コミュニティ主導
- **CentOS Stream / Rocky Linux / AlmaLinux**: RHEL 互換のコミュニティ版
- パッケージ形式: `.rpm`、管理ツール: `dnf`, `yum`, `rpm`

**その他**
- **openSUSE / SUSE Linux Enterprise**: `zypper` と `rpm` を使用
- **Arch Linux**: ローリングリリース方式、`pacman` によるパッケージ管理
- **Alpine Linux**: 軽量、コンテナ用途で人気

```
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
```

`/etc/os-release` はディストリビューションを判別するための標準的な手段であり、スクリプトなどでも広く利用されます。

### コミュニティ版と商用版

多くのディストリビューションには、無償のコミュニティ版(例: Fedora, openSUSE Leap)と、有償サポート付きの商用版(例: RHEL, SUSE Linux Enterprise Server)が存在します。企業では長期サポート(LTS)や SLA が求められる場面で商用版が選ばれる傾向があります。

## Linux が使われている領域

Linux は単一の「デスクトップ OS」という枠を超えて、非常に幅広い領域で利用されています。

- **サーバー**: Web サーバー、データベースサーバーの大部分が Linux 上で稼働
- **スーパーコンピュータ**: TOP500 のほぼ全てが Linux ベース
- **組み込みシステム (embedded systems)**: ルーター、スマート家電、車載システムなど
- **モバイル**: **Android** は Linux kernel をベースにしている
- **クラウド**: 主要なクラウドプロバイダーの基盤インフラの多くが Linux
- **デスクトップ**: シェアは小さいものの、開発者コミュニティで根強い人気

この多様性は、Linux kernel が高度にモジュール化・設定可能であることに起因します。

## Linux Foundation

**Linux Foundation** は Linux kernel の開発を支援する非営利団体で、Linus Torvalds を含む主要開発者を雇用し、カンファレンス運営や関連プロジェクト(Kubernetes, Node.js など)のホスティングも行っています。LPI の認定とは組織が異なる点に注意してください(LPI は独立した認定団体です)。

## まとめのポイント

- **Linux** = kernel の名前、**GNU/Linux** = kernel + GNU tools を含む完全なシステム
- Unix の思想を受け継ぎつつ、GPL の下で自由なソフトウェアとして開発
- ディストリビューションはパッケージ管理システム(`apt` 系 vs `rpm` 系など)で大別できる
- サーバーから組み込み機器、モバイル(Android)まで用途は極めて広範

## Referencias

- LPI Learning Materials — Topic 1.1: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- The Linux Kernel Archives: https://www.kernel.org/
- GNU Project: https://www.gnu.org/
- Free Software Foundation: https://www.fsf.org/
- Linux Foundation: https://www.linuxfoundation.org/
- Debian Project: https://www.debian.org/
- Fedora Project: https://docs.fedoraproject.org/