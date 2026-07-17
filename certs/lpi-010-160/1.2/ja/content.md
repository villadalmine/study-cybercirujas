# 1.2 Major Open Source Applications

## 概要

LPI Linux Essentials (010-160) の Topic 1.2 では、Linux 環境で広く使われている代表的なオープンソースアプリケーションを、カテゴリごとに識別できることが求められます。特定のコマンドの深い操作知識よりも、「どんなアプリケーションが、どのカテゴリに属し、何のために使われるか」を把握することが中心です。**Weight は 2** であり、Topic 1.1 (Linux Community / Distributions) ほどの比重はありませんが、デスクトップ・サーバー・データベース・プログラミング言語・クラウドコンピューティングという広い範囲をカバーします。

---

## 1. デスクトップアプリケーション (Desktop Applications)

### Desktop Environments

Linux では GUI そのものは X Window System (または Wayland) が提供し、その上に **Desktop Environment (DE)** が乗ります。代表的なもの:

- **GNOME** — Fedora、Debian、Ubuntu(デフォルトから外れたが GNOME 版もある)などで採用。GTK ツールキットベース。
- **KDE Plasma** — openSUSE、Kubuntu などで採用。Qt ツールキットベース。
- **Xfce** — 軽量で、リソースが限られた環境や古いハードウェアに向く。

```bash
# 現在のセッションで動いているデスクトップ環境を確認する例
echo $XDG_CURRENT_DESKTOP
```

### Office Suite — LibreOffice

試験では **LibreOffice** について基本的な知識が明示的に問われます。LibreOffice は Apache OpenOffice から派生したオフィススイートで、以下のコンポーネントで構成されます。

| コンポーネント | 用途 | Microsoft Office 相当 |
|---|---|---|
| Writer | ワープロ | Word |
| Calc | 表計算 | Excel |
| Impress | プレゼンテーション | PowerPoint |
| Draw | ドローイング/図形作成 | Visio に近い |
| Base | データベース管理 | Access |
| Math | 数式エディタ | Equation Editor |

LibreOffice はネイティブに **ODF (OpenDocument Format)** (`.odt`, `.ods`, `.odp`) を使用しますが、`.docx` / `.xlsx` / `.pptx` など Microsoft Office 形式との互換性も持ちます。

### グラフィック関連 (Graphics)

- **GIMP** (GNU Image Manipulation Program) — ラスター画像編集。Photoshop に相当。
- **Inkscape** — ベクター画像編集。Illustrator に相当し、SVG をネイティブに扱う。
- **Blender** — 3D モデリング・アニメーション・レンダリング。

### Web ブラウザ

- **Firefox** (Mozilla)
- **Chromium** — Google Chrome のオープンソース版のベースとなるプロジェクト

```bash
# インストール済みブラウザの確認例 (Debian系)
dpkg -l | grep -E 'firefox|chromium'
```

---

## 2. サーバーアプリケーション (Server Applications)

### Web サーバー

- **Apache HTTP Server (httpd)** — モジュール式で歴史が長く、`.htaccess` によるディレクトリ単位の設定が特徴。
- **Nginx** — イベント駆動型で高並列性能に優れ、リバースプロキシ/ロードバランサとしてもよく使われる。

```bash
# サービス状態確認 (systemd 環境)
systemctl status httpd      # Apache (RHEL系のサービス名)
systemctl status nginx

# 稼働中の Web サーバーへの簡易確認
curl -I http://localhost
# HTTP/1.1 200 OK
# Server: nginx/1.24.0
```

### メールサーバー (MTA — Mail Transfer Agent)

- **Postfix** — 現在多くのディストリビューションでデフォルト採用。設定がシンプルで安全性重視。
- **Sendmail** — 歴史的に最も古い MTA の一つ。設定が複雑なことで知られる。
- **Exim** — Debian で長らくデフォルトだった MTA。

### ファイル・印刷サーバー

- **Samba** — SMB/CIFS プロトコルを実装し、Windows とのファイル/プリンタ共有を可能にする。
- **NFS (Network File System)** — Unix/Linux 系ネットワーク間でのファイル共有標準。
- **CUPS (Common Unix Printing System)** — 印刷サービスを提供。

### プロキシ・ディレクトリサービス・DNS

- **Squid** — キャッシュ機能を持つプロキシサーバー。
- **OpenLDAP** — LDAP プロトコルを実装したディレクトリサービス。集中認証などに使われる。
- **BIND (Berkeley Internet Name Domain)** — 最も広く使われる DNS サーバーソフトウェア。

```bash
# DNS サーバーが応答しているかの確認例
dig @localhost example.com
```

---

## 3. データベース (Databases)

### リレーショナルデータベース (RDBMS)

- **MySQL** / **MariaDB** — MariaDB は MySQL からの fork で、多くのディストリビューションで MySQL の代替デフォルトになっている。
- **PostgreSQL** — 高度な標準準拠と拡張性を持つ RDBMS。
- **SQLite** — サーバープロセスを必要としない組み込み型 (embedded) データベース。単一ファイルで完結する。

```bash
# MariaDB/MySQL への接続例
mysql -u root -p

MariaDB [(none)]> SHOW DATABASES;
MariaDB [(none)]> CREATE DATABASE testdb;
MariaDB [(none)]> USE testdb;
```

```sql
-- SQLite の簡易利用例
sqlite3 mydata.db
sqlite> CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
sqlite> INSERT INTO users (name) VALUES ('taro');
sqlite> SELECT * FROM users;
```

### NoSQL データベース

- **MongoDB** — ドキュメント指向 (document-oriented) データベース。JSON ライクな BSON 形式でデータを保存し、スキーマレスな設計が特徴。

---

## 4. プログラミング言語・スクリプティング (Programming Languages)

Linux Essentials では言語の詳細な文法ではなく、**どの言語がどのような用途に使われるか**を把握していることが重要です。

| 言語 | 特徴・主な用途 |
|---|---|
| **C** | システムプログラミング、Linux カーネル自体も C で書かれている |
| **Java** | 「Write Once, Run Anywhere」を掲げる、JVM 上で動作 |
| **Python** | 汎用スクリプト言語、可読性重視、自動化やデータ分析で人気 |
| **PHP** | サーバーサイド Web 開発 (WordPress など多くの CMS で採用) |
| **Perl** | テキスト処理・システム管理スクリプトに強い、歴史が長い |
| **Ruby** | Ruby on Rails フレームワークで有名な Web 開発言語 |
| **JavaScript** | ブラウザ上のクライアントサイド処理、Node.js によりサーバーサイドでも利用可 |

```bash
# インストール済みバージョンの確認例
python3 --version
# Python 3.11.6

php -v
# PHP 8.2.7 (cli)

perl -v
```

Shell スクリプト (**bash**) 自体もシステム管理の自動化に頻繁に使われるスクリプト手段として意識しておく必要があります。

---

## 5. クラウドコンピューティング (Cloud Computing)

試験ではクラウドコンピューティングの基本概念に触れます。

- **IaaS (Infrastructure as a Service)** — 仮想マシンやストレージなどインフラを提供 (例: 仮想化されたサーバー)
- **PaaS (Platform as a Service)** — アプリケーション実行環境を提供し、OS やミドルウェア管理を意識せずに開発できる
- **SaaS (Software as a Service)** — 完成されたアプリケーションをそのままサービスとして利用

**コンテナ (Containers)** はクラウド環境における軽量な仮想化技術として重要視されます。代表例は **Docker** です。

```bash
# Docker の基本操作例
docker run hello-world
docker ps -a
docker images
```

コンテナは仮想マシンと異なりホスト OS のカーネルを共有するため、起動が高速でリソース効率が良いのが特徴です。

---

## まとめ

| カテゴリ | 代表アプリケーション |
|---|---|
| Desktop Environment | GNOME, KDE Plasma, Xfce |
| Office Suite | LibreOffice (Writer, Calc, Impress, Draw, Base, Math) |
| Graphics | GIMP, Inkscape, Blender |
| Web Server | Apache HTTP Server, Nginx |
| Mail Server | Postfix, Sendmail, Exim |
| File/Print Server | Samba, NFS, CUPS |
| Proxy / Directory / DNS | Squid, OpenLDAP, BIND |
| Database | MySQL/MariaDB, PostgreSQL, SQLite, MongoDB |
| Programming Language | C, Java, Python, PHP, Perl, Ruby, JavaScript |
| Cloud / Container | IaaS/PaaS/SaaS, Docker |

---

## Referencias

- LPI Learning Materials — 1.2 Major Open Source Applications: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- LibreOffice 公式サイト: https://www.libreoffice.org/
- GIMP 公式サイト: https://www.gimp.org/
- Inkscape 公式サイト: https://inkscape.org/
- Blender 公式サイト: https://www.blender.org/
- Apache HTTP Server 公式ドキュメント: https://httpd.apache.org/docs/
- Nginx 公式ドキュメント: https://nginx.org/en/docs/
- Postfix 公式サイト: http://www.postfix.org/
- Samba 公式サイト: https://www.samba.org/
- CUPS 公式サイト: https://www.cups.org/
- Squid 公式サイト: https://www.squid-cache.org/
- OpenLDAP 公式サイト: https://www.openldap.org/
- BIND (ISC) 公式サイト: https://www.isc.org/bind/
- MariaDB 公式ドキュメント: https://mariadb.org/documentation/
- MySQL 公式ドキュメント: https://dev.mysql.com/doc/
- PostgreSQL 公式ドキュメント: https://www.postgresql.org/docs/
- SQLite 公式サイト: https://www.sqlite.org/
- MongoDB 公式ドキュメント: https://www.mongodb.com/docs/
- Docker 公式ドキュメント: https://docs.docker.com/