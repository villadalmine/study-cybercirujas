# 1.4 ICT Skills and Working in Linux

**試験:** LPI Linux Essentials 010-160 (version 1.6) · **配点:** 2

## この項目で学ぶこと

この項目は、Linux 環境で安全かつ生産的に作業するための基礎的な ICT スキルを扱います。試験で問われるのは主に次の4分野です。

- **Desktop skills** — グラフィカルな desktop environment とオープンソースの代表的アプリケーションの利用。
- **Getting to the command line** — terminal・console・shell という3つの用語の違いと、それぞれへの到達方法。
- **Industry uses of Linux** — cloud computing や virtualization を含む、実社会での Linux の使われ方。
- **Privacy and security** の実践知識 — ブラウザの設定、cookie、パスワード、暗号化ツール。

---

## 1. Desktop Skills

Linux では desktop environment（デスクトップ環境）は OS に固定されたものではなく、差し替え可能なコンポーネントです。同じディストリビューションでも複数の desktop environment を選択・切り替えられます。代表的なものを挙げます。

| Desktop environment | 特徴 |
|---|---|
| **GNOME** | Fedora、Ubuntu、RHEL の既定。シンプルなワークフローを志向 |
| **KDE Plasma** | 高いカスタマイズ性。Kubuntu、openSUSE の既定 |
| **Xfce / LXDE / LXQt** | 軽量。古いハードウェアでも動作しやすい |
| **Cinnamon / MATE** | 伝統的なデスクトップレイアウト。Linux Mint の既定 |

どの desktop environment を使っても、身につけるべき基本操作は共通しています。アプリケーションの起動、window とワークスペースの管理、file manager（例: GNOME Files/Nautilus、Dolphin）でのファイル操作、そして **display manager**（GDM や SDDM のようなグラフィカルなログイン画面）を通じたログインです。

### 代表的なオープンソースアプリケーション

日常的な文書作成やプレゼンテーションのために、次のアプリケーションは名前と用途を覚えておく必要があります。

- **LibreOffice** — Writer（文書）、Calc（表計算）、Impress（プレゼンテーション）、Base（データベース）、Draw（図形）からなる総合オフィススイート。標準形式は OpenDocument Format（`.odt`、`.ods`、`.odp`）で、Microsoft Office 形式の読み書きにも対応。
- **Mozilla Firefox** / **Chromium** — Web ブラウザ。
- **Mozilla Thunderbird** — メールクライアント。
- **GIMP** — ラスター画像編集（Photoshop の代替）。**Inkscape** はベクター画像編集用。
- **VLC** — メディアプレイヤー。

これらを使えば、プロプライエタリなソフトウェアに頼らずに文書・スライド・画像を作成できます。

## 2. Getting to the Command Line

Linux の柔軟性の中心にあるのはコマンドラインです。試験では次の3つの用語を明確に区別できることが求められます。

- **Shell** — 入力したコマンドを解釈して実行するプログラム。多くのディストリビューションの既定は **Bash**（`/bin/bash`）。
- **Terminal（terminal emulator）** — desktop environment の中で shell にアクセスするためのグラフィカルなアプリケーション。例: GNOME Terminal、Konsole、xterm。
- **Console（virtual console）** — GUI を介さず、システムが直接提供するフルスクリーンのテキストセッション。多くの Linux ディストリビューションでは `Ctrl` + `Alt` + `F1`〜`F6` で複数の virtual console に切り替えられます（グラフィカルなセッション自体もこのうちの1つ、ディストリビューションによっては F1 や F7 を占有しています）。

shell の **prompt**（プロンプト）は、一般ユーザーでは `$`、root ユーザーでは `#` で終わります。

```
user@mainbox:~$ whoami
user
user@mainbox:~$ echo $SHELL
/bin/bash
```

### SSH によるリモートアクセス

システム管理者が管理対象のサーバーの前に物理的に座ることは稀です。リモートからコマンドラインにアクセスするための標準的なツールが **OpenSSH**（Secure Shell）で、セッション全体を暗号化します。

```
$ ssh user@server.example.com
user@server.example.com's password:
Last login: Mon Jul  6 09:12:44 2026 from 192.168.1.10
user@server:~$
```

SSH は、パスワードを平文で送信していた Telnet のような古く安全性の低いプロトコルを置き換えました。

## 3. Industry Uses of Linux, Cloud Computing and Virtualization

Linux は目に見えない場所も含め、産業のあらゆる領域で使われています。

- **サーバー** — Web サーバー、DNS サーバー、データベースサーバーの多くは Linux 上で稼働しています。
- **Cloud computing** — パブリッククラウドのインフラは Linux が中心です。AWS、Google Cloud、Azure のような provider は膨大な数の Linux マシンを運用しており、顧客が起動する仮想マシンインスタンスの大半も Linux です。
- **Virtualization** — 1台の物理マシン上で複数の **virtual machine（VM）** を **hypervisor** が動かす技術。Linux 自体にカーネル組み込みの hypervisor である **KVM**（Kernel-based Virtual Machine）が含まれています。他に Xen、VirtualBox も代表例です。
- **Containers** — VM よりも軽量な仮想化の代替手段。**Docker** のようなコンテナ技術や **Kubernetes** によるオーケストレーションは、Linux カーネルの機能（namespaces、cgroups）の上に成り立っています。
- **組み込み機器・モバイル** — Android は Linux kernel をベースにしています。ルーター、スマート TV、IoT デバイスの多くも Linux で動作します。
- **スーパーコンピューター** — TOP500 に名を連ねるスーパーコンピューターのほぼすべてが Linux を使用しています。

試験で押さえるべき要点は次の2つです。cloud computing とは、provider のデータセンターで稼働するコンピューティングリソース（サーバー、ストレージ、各種サービス）を借りて利用する形態であり、virtualization はそれを効率化する技術です。1台の物理マシンを複数の独立したシステムで共有できるようにします。

## 4. Privacy and Security Basics

### ブラウザのプライバシー

Web を閲覧すると、サイトは **cookie**（クッキー）と呼ばれる小さなデータを保存します。これはセッション維持や設定の記憶に使われる一方、サイトをまたいだ行動追跡（**third-party cookie**）にも使われます。次の操作を理解しておく必要があります。

- ブラウザの設定から cookie と閲覧履歴を確認・削除する。
- third-party cookie をブロックする。
- **private browsing（プライベートブラウジング / incognito mode）** を使う。ウィンドウを閉じると履歴と cookie は破棄されますが、Web サイトやネットワークの提供者に対して匿名になるわけではない点に注意。
- **HTTPS**（アドレスバーの鍵アイコン）を認識する。**TLS** によって通信が暗号化されていることを示します。データを送信するサイトでは HTTPS を優先します。
- 検索エンジンや Web コンテンツの保存（ブックマーク、ページの保存）を適切に使う。

### パスワード

パスワード管理は試験でも問われる実践的なスキルです。

- 記号の複雑さよりも **長さ** を重視した長いパスワードや **passphrase** を使う。
- 同じパスワードを複数のサービスで使い回さない。
- **password manager**（例: KeePassXC）でユニークなパスワードを生成・保管する。
- Linux でパスワードを変更するには `passwd` コマンドを使う。

```
$ passwd
Changing password for user.
Current password:
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
```

- 利用可能な場合は **two-factor authentication（2FA）** を有効にする。

### 暗号化

名前と用途を説明できるようにしておくべき暗号化ツールは2つです。

- **GnuPG（GPG）** — 公開鍵暗号方式を使ってファイルやメールを暗号化・署名するツール。パスフレーズによる対称鍵暗号化の例:

```
$ gpg -c secret-notes.txt
$ ls
secret-notes.txt  secret-notes.txt.gpg
```

- **OpenSSH** — リモートログインだけでなく、`scp` や `sftp` によるファイル転送も暗号化します。

暗号化は **転送中のデータ（data in transit）**（TLS/HTTPS、SSH）と **保管中のデータ（data at rest）**（GPG で暗号化したファイル、LUKS による disk encryption）の両方を保護します。

---

## Quick Review

- **Shell** はコマンドを解釈するプログラム、**terminal emulator** は GUI 上で shell を動かすアプリケーション、**virtual console**（`Ctrl`+`Alt`+`F1`〜`F6`）は GUI の外にあるテキストセッション。
- prompt が `$` なら一般ユーザー、`#` なら root。
- **LibreOffice** = オフィススイート、**GIMP** = 画像編集、**Firefox/Thunderbird** = ブラウジング・メール。
- Linux は **サーバー、クラウド、コンテナ、組み込み機器、スーパーコンピューター** で圧倒的なシェアを持ち、**KVM** は Linux kernel 組み込みの hypervisor。
- private browsing はローカルの履歴のみを消去する。**HTTPS** はサイトとの通信を暗号化する。
- 強力かつユニークなパスワードと **password manager** を使い、`passwd` でパスワードを変更し、**GPG/SSH** で暗号化する。

## Referencias

- LPI Learning Materials, Topic 1.4 — ICT Skills and Working in Linux: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- LPI Linux Essentials Exam 010-160 Objectives: https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Manual: https://www.gnu.org/software/bash/manual/
- OpenSSH Documentation: https://www.openssh.com/manual.html
- GnuPG Documentation: https://gnupg.org/documentation/
- LibreOffice Documentation: https://documentation.libreoffice.org/en/english-documentation/
- KVM (Kernel-based Virtual Machine): https://linux-kvm.org/page/Main_Page
- Mozilla Firefox Privacy Settings: https://support.mozilla.org/en-US/kb/enhanced-tracking-protection-firefox-desktop
