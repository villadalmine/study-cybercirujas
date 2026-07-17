# 2.3 ディレクトリの操作とファイルの一覧表示 (Using Directories and Listing Files)

## 概要

Linux のファイルシステムは、ルート (`/`) を頂点とする単一のツリー構造で構成されています。Windows のようにドライブレターごとに別々のツリーが存在するわけではなく、すべてのファイルとディレクトリはこの1本の木構造のどこかに位置します。この章では、このツリーの中を移動し、内容を確認するための基本的なコマンド (`pwd`、`cd`、`ls`) を扱います。

## ファイルシステムの構造とホームディレクトリ

Linux のディレクトリ構成は **FHS (Filesystem Hierarchy Standard)** という規約にある程度従っています。頂点は `/` (root directory) で、その下に `/etc`、`/home`、`/var` などの標準的なディレクトリがぶら下がります。

各ユーザーには **home directory** が割り当てられており、通常は `/home/ユーザー名` です（root ユーザーの場合は `/root`）。ログイン直後のシェルは、この home directory から始まります。home directory はシェル上で `~` (チルダ) という記号で表すことができます。

```
$ echo $HOME
/home/alice
```

## 現在地を確認する: `pwd`

`pwd` (print working directory) は、現在シェルがいるディレクトリの絶対パスを表示します。

```
$ pwd
/home/alice/projects
```

## 絶対パスと相対パス

パスの指定方法には2種類あります。

- **絶対パス (absolute path)**: 必ず `/` から始まり、root からの完全な経路を示す。現在地に関係なく常に同じ場所を指す。
  例: `/home/alice/projects/report.txt`
- **相対パス (relative path)**: `/` から始まらず、現在いるディレクトリを起点とした経路を示す。
  例: `projects/report.txt`（今 `/home/alice` にいる場合）

特殊な相対パス表記として、以下の2つがあります。

- `.` : 現在のディレクトリ自身
- `..` : 1つ上の親ディレクトリ

```
$ pwd
/home/alice/projects
$ cd ..
$ pwd
/home/alice
```

## ディレクトリを移動する: `cd`

`cd` (change directory) はカレントディレクトリを変更します。

```
$ cd /var/log        # 絶対パスで移動
$ cd reports          # 相対パスで移動（カレントディレクトリ内の reports へ）
$ cd ..                # 1つ上の親ディレクトリへ
$ cd ~                 # 自分の home directory へ
$ cd                   # 引数なしでも home directory へ移動する
$ cd -                 # 直前にいたディレクトリへ戻る
```

`cd -` は特に便利で、2つのディレクトリを行き来しながら作業するときに役立ちます。実行すると移動先のパスが標準出力に表示されます。

```
$ cd /etc
$ cd /home/alice
$ cd -
/etc
```

## ファイルを一覧表示する: `ls`

`ls` (list) はディレクトリの内容を表示する最も基本的なコマンドです。

```
$ ls
Desktop  Documents  Downloads  projects  report.txt
```

### よく使うオプション

| オプション | 意味 |
|---|---|
| `-a` | ドットファイル（隠しファイル）を含むすべてのエントリを表示 |
| `-A` | `-a` と同様だが `.` と `..` は除外する |
| `-l` | 長形式 (long format) で詳細情報を表示 |
| `-F` | ファイル種別を示す記号を付加する |
| `-h` | `-l` と併用してサイズを人間が読みやすい単位（K, M, G）で表示 |
| `-R` | サブディレクトリの中身も再帰的に表示 |
| `-d` | ディレクトリ自体の情報を表示し、中身は展開しない |

### 長形式 `ls -l`

```
$ ls -l
total 24
drwxr-xr-x 2 alice alice 4096 Jul  8 10:12 Desktop
drwxr-xr-x 2 alice alice 4096 Jul  8 10:12 Documents
-rw-r--r-- 1 alice alice  512 Jul 10 09:15 report.txt
```

各列の意味は次の通りです。

1. `drwxr-xr-x` — ファイル種別 (`d` はディレクトリ、`-` は通常ファイル) と permission
2. `2` — hard link の数
3. `alice` — 所有者 (owner)
4. `alice` — 所有グループ (group)
5. `4096` — サイズ（バイト単位。`-h` を付けると `4.0K` のように表示される）
6. `Jul  8 10:12` — 最終更新日時
7. `Desktop` — 名前

### 隠しファイルを表示する `ls -a`

Linux では、ファイル名が `.` (ドット) で始まるものは **hidden file**（隠しファイル、通称 dotfile）として扱われ、通常の `ls` では表示されません。設定ファイル（例: `.bashrc`、`.gitconfig`）によく使われる慣習です。

```
$ ls -a
.  ..  .bashrc  .config  Desktop  Documents  report.txt
```

ここに表示される `.` と `..` も、実際には各ディレクトリ内部に存在するエントリで、それぞれ「自分自身」と「親ディレクトリ」を指しています。

### ファイル種別を示す `ls -F`

```
$ ls -F
Desktop/  Documents/  report.txt  run.sh*
```

末尾の記号によって種別がわかります。

- `/` : ディレクトリ
- `*` : 実行権限のあるファイル
- `@` : シンボリックリンク
- 記号なし : 通常のファイル

### オプションの組み合わせ

オプションは組み合わせて指定できます。

```
$ ls -la
$ ls -lh
$ ls -lah
```

`ls -la` は「隠しファイルも含めて長形式で表示する」という、実務で最も頻繁に使われる組み合わせの一つです。

## 演習の流れ（まとめ例）

```
$ pwd
/home/alice
$ cd projects
$ pwd
/home/alice/projects
$ ls -la
total 16
drwxr-xr-x 3 alice alice 4096 Jul 10 09:00 .
drwxr-xr-x 8 alice alice 4096 Jul  8 10:12 ..
-rw-r--r-- 1 alice alice  120 Jul 10 08:50 .env
-rw-r--r-- 1 alice alice  512 Jul 10 09:15 report.txt
$ cd ..
$ pwd
/home/alice
```

## まとめ

- Linux のファイルシステムは `/` を頂点とする単一のツリー構造。
- 各ユーザーは home directory を持ち、`~` で参照できる。
- パスには absolute path（`/` から始まる）と relative path（現在地からの相対）がある。
- `.` は自分自身、`..` は親ディレクトリを指す。
- `pwd` は現在地、`cd` はディレクトリ移動、`ls` は内容表示に使う。
- `ls -a`、`ls -l`、`ls -F` などのオプションで表示内容を調整できる。

## 参考文献

- LPI Learning Materials, "2.3 Using Directories and Listing Files": https://learning.lpi.org/en/learning-materials/010-160/2/2.3/
- GNU Coreutils Manual, "ls invocation": https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- The Linux Documentation Project, "Filesystem Hierarchy Standard": https://tldp.org/LDP/Linux-Filesystem-Hierarchy/html/