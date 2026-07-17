# LPI Linux Essentials (010-160) 演習教材

**トピック**: 1.2 Major Open Source Applications（配点: 2）
**参考資料**: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/

---

## 演習1: Desktop Application の調査

1. ターミナルを開き、`cat /etc/os-release` を実行して、使用しているディストリビューションが Debian 系（Ubuntu など）か、Red Hat 系（Fedora など）かを確認する。
2. Debian 系の場合は `dpkg -l | grep -i libreoffice`、Red Hat 系の場合は `rpm -qa | grep -i libreoffice` を実行し、Office Suite である LibreOffice がインストールされているか確認する。
3. `which gimp` を実行し、画像編集用の Open Source Application である GIMP（GNU Image Manipulation Program）の有無を確認する。インストールされていれば `gimp --version` でバージョンも確認する。
4. デスクトップ環境のアプリケーションメニューを開き、Graphics カテゴリに Inkscape（ベクター画像編集）や Blender（3DCG 制作）がないか探す。
5. 確認した結果を、「アプリケーション名」「用途」「対応する proprietary な商用アプリケーション」の3列でメモに書き出す（例: LibreOffice Writer → 文書作成 → Microsoft Word）。

### 理解度チェック
**Q1.** LibreOffice Writer に相当する、Windows でよく使われる proprietary な商用アプリケーションは何か。
**Q2.** GIMP は主にどのような用途に使われる Open Source Application か。

---

## 演習2: Web Browser と Email Client の調査

1. `which firefox` および `which chromium` または `which chromium-browser` を実行し、インストール済みの Web Browser を確認する。
2. `firefox --version` を実行してバージョンを確認する。
3. `which thunderbird` を実行し、Email Client である Thunderbird の有無を確認する。見つからない場合は `which evolution` も試す。
4. Firefox の Rendering Engine が Gecko、Chromium の Rendering Engine が Blink であることを、各アプリケーションの「このバージョンについて」または公式ドキュメントで確認する。
5. 自分の環境にインストールされている Browser と Email Client を1つずつ挙げ、それぞれの開発元（コミュニティ or 企業）をメモする。

### 理解度チェック
**Q1.** Firefox が採用している Rendering Engine の名称は何か。
**Q2.** Thunderbird はどのカテゴリの Open Source Application に分類されるか。

---

## 演習3: LAMP Stack を構成するソフトウェアの調査

1. `systemctl list-units --type=service | grep -Ei 'apache2|httpd|nginx'` を実行し、Web Server サービスが登録・稼働しているか確認する。
2. `which mysql` または `which mariadb` を実行し、Database Management System がインストールされているか確認する。見つからない場合は `which psql`（PostgreSQL）も試す。
3. `php -v` を実行し、Server-side Scripting Language である PHP のバージョンを確認する。見つからない場合は代わりに `python3 --version` を確認する。
4. Web Server が稼働している場合、`curl -I http://localhost` を実行してレスポンスヘッダーを確認し、`Server:` フィールドにどのソフトウェア名が表示されるか観察する。
5. LAMP という頭字語を構成する4つの要素（Linux／Apache／MySQL（または MariaDB）／PHP（または Perl、Python））を紙またはメモに書き出し、それぞれの役割を1行で説明する。

### 理解度チェック
**Q1.** LAMP という頭字語の4文字がそれぞれ何を表すか説明せよ。
**Q2.** MySQL の代替としてよく使われる Open Source な RDBMS を1つ挙げよ。

---

## 演習4: Package Management とアプリケーションの依存関係

1. Debian 系では `apt list --installed | wc -l`、Red Hat 系では `dnf list installed | wc -l` を実行し、現在インストールされているパッケージの総数を確認する。
2. `apt show firefox`（Debian 系）または `dnf info firefox`（Red Hat 系）を実行し、パッケージの説明文と依存関係（dependencies）情報を確認する。
3. `dpkg -L <パッケージ名>`（Debian 系）または `rpm -ql <パッケージ名>`（Red Hat 系）を実行し、そのパッケージによってインストールされたファイルの一覧を確認する。
4. 上記の結果から、Package Manager が単なる「インストーラー」ではなく、依存関係の解決やファイル管理まで担っていることを整理する。

### 理解度チェック
**Q1.** `dpkg` と `rpm` は、それぞれどのディストリビューション系列で使われる low-level package manager か。
**Q2.** Package Manager を使わずソフトウェアを手動でインストールする方法と比較して、Package Manager を使う利点を1つ挙げよ。

---

## 演習5: Mobile および開発言語分野の Open Source Application

1. `python3 --version`、`perl -v`、`gcc --version` をそれぞれ実行し、自分の環境にどの Programming Language の処理系がインストールされているか確認する。
2. Android OS の Kernel が Linux Kernel をベースにしていることを、Android の公式ドキュメントまたは信頼できる技術資料で確認する（コマンド実行は不要、調査のみ）。
3. `which gnumeric` を実行し、Microsoft Excel の代替としても使われる表計算ソフト Gnumeric の有無を確認する（見つからなければ LibreOffice Calc を代わりに調べる）。
4. 演習1〜5で調査した Open Source Application を、「Desktop」「Server」「Mobile」「Development」の4分野に分類した一覧表を作成し、まとめとする。

### 理解度チェック
**Q1.** Android OS はどの Kernel をベースにしているか。
**Q2.** Microsoft Excel の Open Source な代替として使われる表計算ソフトウェアを1つ挙げよ。

---

<details>
<summary>解答（クリックして表示）</summary>

**演習1**
- Q1: Microsoft Word
- Q2: 画像編集（ラスター画像の作成・加工）。写真のレタッチやデジタルペイントなどに使われる。

**演習2**
- Q1: Gecko
- Q2: Email Client（メールクライアント）

**演習3**
- Q1: L = Linux（OS）、A = Apache（Web Server）、M = MySQL または MariaDB（Database）、P = PHP（または Perl、Python。Server-side Scripting Language）
- Q2: MariaDB（他に PostgreSQL も正解）

**演習4**
- Q1: `dpkg` は Debian 系（Ubuntu を含む）、`rpm` は Red Hat 系（Fedora、CentOS、RHEL など）
- Q2: 依存関係を自動的に解決してくれる、バージョン管理やアンインストールが容易になる、セキュリティアップデートの適用が簡単になる、などのいずれか。

**演習5**
- Q1: Linux Kernel
- Q2: LibreOffice Calc（または Gnumeric）

</details>