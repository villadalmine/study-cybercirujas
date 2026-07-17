# 1.3 Open Source Software and Licensing

## Free Software と Open Source の考え方

Linux エコシステムを理解するうえで最初に押さえるべきは、「なぜソースコードが公開されているのか」という思想的背景です。この分野には歴史的に二つの立場があります。

### Free Software（FSF の立場）

Free Software Foundation（FSF）は、ソフトウェアが利用者に保証すべき「four freedoms（4つの自由）」を定義しています。

| 自由 | 内容 |
|---|---|
| Freedom 0 | どんな目的でも、プログラムを実行する自由 |
| Freedom 1 | プログラムがどう動くか研究し、必要に応じて改変する自由（source code へのアクセスが前提） |
| Freedom 2 | コピーを再配布して他者を助ける自由 |
| Freedom 3 | 改変したバージョンを配布し、コミュニティ全体に貢献する自由 |

ここでの "free" は「無料」ではなく「自由」を意味します。FSF はよく "free as in freedom, not as in free beer" という言い回しでこれを説明します。有料で販売されている Free Software も存在します（自由が保たれていれば no-cost である必要はない）。

### Open Source（OSI の立場）

Open Source Initiative（OSI）は思想よりも実務・開発手法としての利点（品質、セキュリティ、協業のしやすさ）を強調します。OSI は "Open Source Definition (OSD)" という10項目の基準を定めており、ライセンスがこの基準を満たすかどうかで "Open Source" を名乗れるかが決まります。主な要件には以下が含まれます。

- Free Redistribution（自由な再配布ができること）
- Source Code の入手が可能であること
- Derived Works（派生物）の作成・配布を許可すること
- 特定の個人・グループ・利用分野を差別しないこと（No Discrimination）
- ライセンスが特定の製品に限定されないこと

### FOSS / FLOSS という呼び方

実務上、Free Software と Open Source Software はライセンスとして重なる部分が非常に大きいため、両方を包含する中立的な呼称として **FOSS**（Free and Open Source Software）や **FLOSS**（Free/Libre and Open Source Software）が使われます。試験でもこの用語の違い（思想の違いであってライセンス条項の違いではないことが多い）が問われます。

## Proprietary Software / Freeware / Shareware との違い

| 種別 | Source Code | 再配布 | 改変 | 料金 |
|---|---|---|---|---|
| Free Software / Open Source | 公開 | 自由 | 自由 | 無料または有料 |
| Freeware | 非公開が多い | 制限あり | 不可 | 無料 |
| Shareware | 非公開 | 期間限定で配布可 | 不可 | 試用後に購入 |
| Proprietary Software | 非公開 | 不可 | 不可 | 通常有料 |

Freeware は「無料で使える」だけであり、source code の公開や改変の自由は保証されません。ここを混同しないことが Linux Essentials では重要です。

## 主要なライセンスの分類

### Copyleft ライセンス（GPL 系）

**GNU General Public License（GPL）** は copyleft の代表例です。copyleft とは「派生物も同じ自由（four freedoms）を保証したライセンスで配布しなければならない」という考え方です。GPL でライセンスされたコードを組み込んだソフトウェアを配布する場合、その配布物全体も GPL 互換のライセンスで、source code とともに公開する義務があります。

- **GPLv2**：Linux kernel が採用しているライセンス。
- **GPLv3**：特許報復条項（patent retaliation）や tivoization 対策を追加した後継版。
- **LGPL (Lesser GPL)**：ライブラリ向け。LGPL なライブラリをリンクするだけなら、リンクする側のアプリケーションまで GPL 化する義務はない（ライブラリ自体の改変には copyleft が適用される）。

### Permissive ライセンス（BSD / MIT / Apache 系）

Permissive ライセンスは、派生物を proprietary（非公開）にしても構わないという緩やかな条件を持ちます。

- **MIT License**：著作権表示とライセンス文の保持のみを条件とする、最もシンプルなライセンスの一つ。
- **BSD License（2-Clause / 3-Clause）**：MIT に近いが、3-Clause 版には「作者名を宣伝目的で無断使用しない」条項が追加される。
- **Apache License 2.0**：MIT/BSD に加え、明示的な patent grant（特許許諾）条項を含む。企業が関与するプロジェクトで好まれる。

### Creative Commons（ソフトウェア以外向け）

**Creative Commons（CC）** ライセンスはソフトウェアではなく、ドキュメント・画像・音楽などのコンテンツ向けに設計されています。組み合わせ可能な条件記号で表現されます。

- `BY`（表示）：作者のクレジット表示が必要
- `SA`（継承）：派生物も同じライセンスで公開
- `NC`（非営利）：商用利用不可
- `ND`（改変禁止）：派生物の作成不可

例：`CC BY-SA 4.0` は Wikipedia が採用しているライセンスで、「表示＋継承」を条件に自由な利用・改変・再配布を許可します。

## コミュニティと Foundation

多くの大規模 Open Source プロジェクトは、法人格を持つ非営利団体（foundation）を通じて運営されています。

- **Free Software Foundation (FSF)**：GNU プロジェクトを支援、GPL/LGPL/AGPL を策定・管理。
- **Open Source Initiative (OSI)**：ライセンスの OSD 準拠審査、承認済みライセンス一覧の管理。
- **The Linux Foundation**：Linux kernel の開発支援のほか、Kubernetes（CNCF）などを含む多数のプロジェクトをホスト。

これらの組織は、trademark（商標）管理、法的防御、資金調達、リリース調整といった役割を担い、個人の contributor だけでは難しい継続性をプロジェクトに与えます。

## ライセンス情報を確認するコマンド例

Linux ディストリビューション上でインストール済みパッケージのライセンスを確認する方法はパッケージ形式によって異なります。

### RPM 系（Fedora/RHEL/CentOS）

RPM のパッケージメタデータには `License` タグが含まれています。

```console
$ rpm -qi coreutils | grep -i license
License     : GPLv3+
```

### DEB 系（Debian/Ubuntu）

Debian Policy により、すべてのパッケージが `/usr/share/doc/<package>/copyright` に copyright/license 情報を含める必要があります。

```console
$ dpkg -L bash | grep copyright
/usr/share/doc/bash/copyright

$ head -n 15 /usr/share/doc/bash/copyright
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: bash
Source: https://ftp.gnu.org/gnu/bash/

Files: *
Copyright: 1989-2022 Free Software Foundation, Inc.
License: GPL-3+
```

### ソースコード内のライセンスヘッダー

GPL でライセンスされたソースファイルの冒頭には、しばしば次のような notice が記載されています（例示のための要約）。

```c
/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License.
 */
```

このような notice の有無と内容が、そのファイルに適用されるライセンスを判断する一次情報になります。

## 試験で問われやすいポイント

- "Free" は「無料」ではなく「自由」を指す（gratis ではなく libre）。
- Free Software と Open Source は思想の出発点が異なるだけで、実務上は多くのライセンスが両方の定義を満たす（FOSS/FLOSS）。
- Copyleft（GPL）と Permissive（MIT/BSD/Apache）の違いは「派生物にも同じ条件を課すかどうか」。
- Creative Commons はソフトウェアライセンスではなく、コンテンツ向けライセンス。
- FSF・OSI・Linux Foundation それぞれの役割の違い。

## Referencias

- LPI Learning Materials — Topic 1.3: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- The Free Software Definition (FSF): https://www.gnu.org/philosophy/free-sw.en.html
- GNU General Public License v3.0: https://www.gnu.org/licenses/gpl-3.0.en.html
- GNU Lesser General Public License: https://www.gnu.org/licenses/lgpl-3.0.en.html
- The Open Source Definition (OSI): https://opensource.org/osd
- OSI Approved Licenses: https://opensource.org/licenses
- MIT License text: https://opensource.org/license/mit
- BSD 3-Clause License text: https://opensource.org/license/bsd-3-clause
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- Creative Commons Licenses: https://creativecommons.org/licenses/
- Debian Machine-Readable Copyright Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
- The Linux Foundation: https://www.linuxfoundation.org/