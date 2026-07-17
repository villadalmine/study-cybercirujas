# 4.1 Choosing an Operating System — 演習

> 参考: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
> （このセクションはこの参考ページを下敷きにしていますが、文章はすべてオリジナルで書き下ろしています。実際の試験問題や資料からの引用はありません。）

---

## 演習1: 自分の Linux system がどの distribution か特定する

現在使っている machine の Operating System (OS) 情報を、複数の角度から確認します。distribution ごとに情報の出し方が微妙に違うため、確実な方法を複数知っておくことが重要です。

1. ターミナルを開きます。
2. `uname -a` を実行し、kernel 名・hostname・kernel version・architecture (`x86_64` など) を確認します。
3. `cat /etc/os-release` を実行し、`NAME`、`VERSION`、`ID`、`PRETTY_NAME` の各行を確認します。
4. `hostnamectl` を実行し（systemd 系 distribution の場合）、`Operating System` と `Kernel` の行を確認します。
5. インストールされている package manager の種類を確認します。`which apt` `which dnf` `which pacman` のいずれかを実行し、どれが存在するか確認します。

**理解度チェック**

- `uname -a` の出力から distribution 名（例: Ubuntu、Fedora）が直接わかりますか？わからない場合、その理由は何ですか？
- `/etc/os-release` の `ID` フィールドと `PRETTY_NAME` フィールドは、それぞれどのような目的で使われますか？
- あなたの system の package manager が `apt` だった場合、その system はどの distribution family（Debian 系 / Red Hat 系 / Arch 系）に属すると推測できますか？

<details>
<summary>解答</summary>

- わかりません。`uname -a` は kernel に関する情報（kernel name、version、architecture など）を表示するものであり、kernel は複数の distribution で共有されるため、distribution 名は含まれません。distribution 名を知りたい場合は `/etc/os-release` や `hostnamectl` を使う必要があります。
- `ID` フィールドは script などプログラムから機械的に distribution を判定するための短い識別子（例: `ubuntu`、`fedora`）です。`PRETTY_NAME` は人間が読むための完全な表示名（例: `Ubuntu 24.04.2 LTS`）です。
- `apt` が存在する場合、Debian 系（Debian、Ubuntu、Linux Mint など）である可能性が高いです。Red Hat 系は `dnf`/`yum`、Arch 系は `pacman` を使用します。

</details>

---

## 演習2: license の種類を見分ける

同じ Linux system 上に、license の性質が異なる software が混在していることを確認します。open source software と proprietary software（商用ソフトウェア）の違いを、実際の package から観察します。

1. すでに install 済みの package の一覧を表示します。`apt list --installed`（Debian 系）または `dnf list installed`（Red Hat 系）を実行します。
2. その中から任意の package（例: `bash`）を一つ選び、詳細情報を表示します。`apt show bash` または `dnf info bash` を実行します。
3. 出力に含まれる license 情報（`apt show` では別途 `/usr/share/doc/<package>/copyright` を確認、`dnf info` では `License` フィールド）を確認します。
4. GNU GPL、MIT、BSD といった license 名が出てきたら、それぞれが open source license であることを覚えておきます。
5. 比較として、proprietary software の例（例: NVIDIA の proprietary driver package、または業務で使う商用アプリ）が system 上にあるか確認します。`apt show nvidia-driver-XXX` のように試すか、なければ「もし入れるとしたら」を想定して考えます。

**理解度チェック**

- open source software と free software（Free Software Foundation の定義での "free"）は同じ意味ですか？違いを一言で説明してください。
- GPL license の software を改変して再配布する場合、どのような義務が発生しますか？
- proprietary software を選ぶメリットとして、open source software に対してどのような点が挙げられますか？

<details>
<summary>解答</summary>

- 完全に同じではありません。"free" は「無料 (free of charge)」ではなく「自由 (freedom)」を指します。open source は主に開発プロセスやライセンスの技術的条件（source code の公開・改変・再配布の自由）に焦点を当てた考え方であり、free software は利用者の自由（4つの freedom）という哲学的・倫理的側面を強調します。実務上は多くの license（GPL など）が両方の定義を満たします。
- 改変後の source code を公開し、同じ GPL license の下で再配布する義務（copyleft）が発生します。これにより GPL software から派生した software も open source であり続けます。
- vendor による正式な support、責任の所在が明確、business 向けの SLA（サービス品質保証）、特定 hardware への最適化などが挙げられます。一方で source code が非公開なため検証や改変ができない、cost がかかる、といった trade-off があります。

</details>

---

## 演習3: 用途に応じて Operating System を選定する

同じ "Linux" でも、目的（desktop 用途、server 用途、embedded 機器、virtualization 環境）によって適した distribution や構成が異なります。手元の system の specification を確認しながら、用途に応じた選定基準を考えます。

1. `lscpu` を実行し、CPU の architecture（`x86_64` / `aarch64` など）と core 数を確認します。
2. `free -h` を実行し、利用可能な memory 容量を確認します。
3. `df -h /` を実行し、root filesystem の空き容量を確認します。
4. 以下の3つの用途について、演習1〜3で得た情報を踏まえてどの種類の OS 構成が適切か考えます。
   - (a) GUI（デスクトップ環境）を必要とする一般利用者向けの desktop
   - (b) 常時稼働し外部からアクセスされる web server
   - (c) memory・storage が極めて限られた embedded device（例: IoT センサー）
5. それぞれの用途に対して、`Ubuntu Desktop` / `Ubuntu Server` / `Debian`（minimal install）/ `Alpine Linux` のうちどれが妥当か、理由とともに書き出します。

**理解度チェック**

- server 用途では GUI（graphical user interface）を install しないことが一般的です。それはなぜですか？
- embedded device 向けに Alpine Linux のような軽量 distribution が好まれる理由を、memory と storage の観点から説明してください。
- 同じ hardware で複数の OS を同時に動かしたい場合、選択肢となる技術は何ですか？

<details>
<summary>解答</summary>

- GUI は CPU・memory・storage を追加で消費し、攻撃対象領域（attack surface）も広げます。server は多くの場合 SSH や remote 管理ツールで操作すれば十分であり、resource を service 自体に割り当てた方が効率的だからです。
- Alpine Linux は musl libc と BusyBox を採用し、base image のサイズが数 MB 程度と非常に小さいため、memory・storage 容量が限られた device でも動作します。不要な package や daemon を含まないことで、footprint（占有領域）を最小限に抑えられます。
- virtualization（VMware、KVM、VirtualBox など）や container 技術（Docker など）を使うことで、1つの物理 hardware 上に複数の OS 環境を同時に動作させることができます。

</details>