# LPI Linux Essentials (010-160 v1.6) — Topic 1.1: Linux Evolution and Popular Operating Systems

**試験での配点:** 2

このトピックでは、Linux の起源、GNU project と kernel の関係、主要な distribution の系統、Free Software と Open Source の違い、そして cloud computing・embedded systems における Linux の役割を扱います。以下の演習は、実際に terminal でコマンドを実行しながら概念を確認する形式です。

---

## 演習 1: 自分の distribution を特定する

### 手順

1. terminal を開きます。
2. 以下のコマンドを実行し、現在の distribution の情報を表示します。

   ```bash
   cat /etc/os-release
   ```

3. 出力の中から `NAME`、`ID`、`ID_LIKE`、`VERSION` の各項目を確認します。
4. 続けて kernel のバージョンと architecture を確認します。

   ```bash
   uname -a
   ```

5. `/etc/os-release` の `ID_LIKE` に値がある場合、それはあなたの distribution が別の distribution 系統から派生していることを示します（例: Ubuntu は `ID_LIKE=debian`）。

### 理解度チェック

- Q1. `ID_LIKE` フィールドが存在する場合、それは何を意味しますか。
- Q2. `uname -a` と `cat /etc/os-release` は、それぞれ何についての情報を示していますか（2つの違いを説明してください）。

---

## 演習 2: package manager から distribution の系統を判別する

### 手順

1. 主要な package manager コマンドのうち、どれが自分の system に存在するかを確認します。

   ```bash
   for cmd in apt dpkg dnf yum rpm zypper pacman; do
     command -v "$cmd" >/dev/null 2>&1 && echo "$cmd: found"
   done
   ```

2. 見つかった package manager のバージョンを確認します（例: `apt --version` や `rpm --version` など、found と表示されたコマンドに対応するものを実行）。
3. 以下の対応関係をメモします。
   - `apt` / `dpkg` → Debian 系統（Debian, Ubuntu, Linux Mint など）
   - `dnf` / `yum` / `rpm` → Red Hat 系統（Fedora, RHEL, CentOS, Rocky Linux など）
   - `zypper` → SUSE 系統（openSUSE, SLES）
   - `pacman` → Arch Linux 系統

### 理解度チェック

- Q3. あなたの system にはどの package manager が存在しましたか。それは演習1で確認した `ID_LIKE` の結果と一致していますか。
- Q4. なぜ同じ Linux kernel を使っていても、distribution ごとに異なる package manager が存在するのだと考えられますか。

---

## 演習 3: GNU project と Free Software のライセンスを確認する

### 手順

1. bash のバージョン情報を全文表示します。

   ```bash
   bash --version
   ```

2. 出力の中に `Free Software Foundation` という文字列と、「free software; you are free to change and redistribute it」という趣旨の文、および「There is NO WARRANTY」という文があることを確認します。
3. man page のフッター部分も確認します。

   ```bash
   man bash | tail -n 5
   ```

4. これらの文言は、bash が GPL (GNU General Public License) のもとで配布されていることを示しています。GPL は Free Software Foundation (FSF) が推進する license の代表例です。

### 理解度チェック

- Q5. `bash --version` の出力に含まれる「NO WARRANTY」という文言は、何を意味していますか。
- Q6. Free Software Foundation (FSF) が定義する Free Software と、Open Source Initiative (OSI) が定義する Open Source は、しばしば同じソフトウェアを指しますが、両者が重視する観点は異なります。それぞれが強調する点の違いを一つずつ挙げてください。

---

## 演習 4: cloud computing 環境と Linux の関係を確認する

### 手順

1. 自分の system が仮想化環境（VM）や container 上で動作しているかを確認します（systemd が入っている場合）。

   ```bash
   systemd-detect-virt
   ```

   `none` と表示された場合は物理machine（bare metal）、それ以外（例: `kvm`、`docker`、`lxc` など）は仮想化環境上で動作していることを示します。
2. systemd が無い環境では、代わりに以下を確認します。

   ```bash
   cat /proc/cpuinfo | grep -i hypervisor
   ```

3. 結果をもとに、次の3つの cloud computing サービスモデルのうち、自分の system がどれに近い使われ方をしているか考えます。
   - IaaS (Infrastructure as a Service)
   - PaaS (Platform as a Service)
   - SaaS (Software as a Service)

### 理解度チェック

- Q7. `systemd-detect-virt` が `none` 以外の値を返した場合、それは何を意味しますか。
- Q8. Linux が cloud computing の分野（特に IaaS や container 技術）で広く採用されている理由を、license の観点から一つ説明してください。

---

## 演習 5: 単一の kernel が embedded systems から server まで対応することを確認する

### 手順

1. 自分の machine の CPU architecture を確認します。

   ```bash
   uname -m
   ```

2. CPU のコア数と搭載メモリを確認します。

   ```bash
   nproc
   free -h
   ```

3. 出力された architecture（例: `x86_64`、`aarch64` など）をメモします。`aarch64` や `armv7l` は、Raspberry Pi のような embedded device や、Android smartphone で広く使われている architecture です。
4. 同じ Linux kernel の source code が、`aarch64` 上の小型 embedded device（数百 MB の RAM）から、`x86_64` の大規模 cloud server（数百 GB の RAM）まで対応していることを、手順1〜2の結果と結びつけて考えます。

### 理解度チェック

- Q9. Android は Linux kernel を採用していますが、一般的な desktop distribution（例: Ubuntu）とは userspace の構成が異なります。この違いは何ですか。
- Q10. 同一の kernel design が embedded systems から cloud server まで対応できる理由を、Linux の設計思想（modularity）の観点から説明してください。

---

## 参考文献

- LPI Learning Materials, Topic 1.1 Linux Evolution and Popular Operating Systems: https://learning.lpi.org/en/learning-materials/010-160/1/1.1/
- GNU Project (GNU General Public License の原文): https://www.gnu.org/licenses/gpl-3.0.html
- Free Software Foundation, "What is Free Software?": https://www.fsf.org/about/what-is-free-software
- Open Source Initiative, "The Open Source Definition": https://opensource.org/osd
- The Linux Kernel Archives: https://www.kernel.org/

---

<details>
<summary>解答例（クリックして展開）</summary>

**Q1.** `ID_LIKE` は、その distribution がどの distribution 系統をベースにしているかを示します。例えば Ubuntu の `ID_LIKE=debian` は、Ubuntu が Debian をベースに作られていることを表します。

**Q2.** `cat /etc/os-release` は distribution（OS の配布パッケージ、userspace 全体）についての情報を示すのに対し、`uname -a` は Linux kernel 自体のバージョンや architecture、hostname などの情報を示します。distribution は同じでも kernel のバージョンは更新によって変わることがあります。

**Q3.** 環境によって異なります（例: Ubuntu なら `apt`/`dpkg` が見つかり、`ID_LIKE=debian` と一致するはずです）。

**Q4.** 各 distribution 系統が独自に package format（`.deb`、`.rpm` など）と依存関係解決の仕組みを歴史的に発展させてきたためです。共通の kernel を使っていても、userspace のソフトウェア管理方式は distribution の設計思想によって異なります。

**Q5.** ソフトウェアの動作について、開発元や配布者が一切の保証をしないことを意味します。これは GPL に含まれる標準的な免責条項で、Free Software であっても品質保証を伴わないことを明示しています。

**Q6.** FSF が定義する Free Software は、利用者の「自由（実行・研究・改変・再配布の自由）」という倫理的・哲学的観点を重視します。一方 OSI が定義する Open Source は、source code の公開や再配布の自由といった実務上の基準（The Open Source Definition の10項目）を重視し、より実用的・ビジネス寄りの観点で語られることが多いです。

**Q7.** その system が仮想化環境（VM）または container 上で動作していることを意味します。`kvm` や `vmware` などは VM、`docker` や `lxc` などは container 技術を示します。

**Q8.** Linux は GPL などの Free Software license のもとで配布されており、利用者は license 料を支払うことなく自由に導入・改変・大規模展開ができます。この低コストと自由度の高さが、cloud provider が大量の server に Linux を採用する大きな理由の一つです。

**Q9.** Android は Linux kernel を採用していますが、GNU の userspace tools（bash、glibc など）は使用せず、独自の userspace（Bionic libc、ART runtime など）を採用しています。そのため Android は「GNU/Linux」ではなく、Linux kernel ベースの独立した platform として扱われます。

**Q10.** Linux kernel は monolithic かつ modular に設計されており、driver やサブシステムを module として組み込み・除外できます。この modularity により、必要な機能だけを含めた小さな kernel を embedded device 向けに構成することも、多数の CPU やメモリを扱う server 向けに構成することも、同じ source tree から実現できます。

</details>