# 2.2 Using the Command Line to Get Help

## 概要

Linuxのコマンドラインには、コマンドの使い方を調べるための複数の仕組みが用意されています。実際の現場では、コマンドのオプションをすべて記憶することは不可能に近く、必要なときに素早く正しい情報源を参照できる能力そのものが実務スキルです。この節では、`man`、`--help`、`info`、`whatis`/`apropos`、そして`/usr/share/doc`以下のドキュメントという、代表的な5つのヘルプ手段を扱います。

---

## 1. `--help` オプション

多くのコマンドは `--help`(または `-h`)オプションを実装しており、標準出力(stdout)へ簡潔な使用方法(usage)とオプション一覧を表示します。man pageより短く、ワンライナーで確認したいときに便利です。

```console
$ cp --help
Usage: cp [OPTION]... [-T] SOURCE DEST
  or:  cp [OPTION]... SOURCE... DIRECTORY
  or:  cp [OPTION]... -t DIRECTORY SOURCE...
Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.

Mandatory arguments to long options are mandatory for short options too.
  -a, --archive                same as -dR --preserve=all
  -f, --force                   if an existing destination file cannot be
                                 opened, remove it and try again
  -i, --interactive             prompt before overwrite
  ...
```

- GNUコマンド(coreutils由来のもの)はほぼ必ず `--help` を持ちます。
- 一部の古いUnix系コマンドや一部のシェルビルトインは `--help` を持たず、代わりに `man` を使う必要があります。
- 出力が長い場合はページャに渡すと読みやすくなります。

```console
$ ls --help | less
```

---

## 2. `man` コマンドとmanページ

`man`(manual)は最も体系的なヘルプシステムです。manページは通常 `/usr/share/man/` 以下にセクションごとに格納されています。

```console
$ man ls
```

### manページのセクション構成

manページには標準化されたセクション番号があり、同じ名前でも意味が異なる場合に区別できます。

| セクション | 内容 |
|---|---|
| 1 | ユーザーコマンド(実行可能プログラム) |
| 2 | システムコール(カーネル関数) |
| 3 | ライブラリ関数(Cライブラリ) |
| 4 | スペシャルファイル(`/dev`以下など) |
| 5 | ファイルフォーマットと設定ファイル(例: `/etc/passwd`) |
| 6 | ゲーム |
| 7 | その他(慣習、プロトコルなど) |
| 8 | システム管理コマンド(root向け) |

同じキーワードが複数セクションに存在する例として `passwd` があります。

```console
$ man passwd
```

これはデフォルトでセクション1(コマンドとしての`passwd`)を表示します。セクション5(ファイルフォーマットとしての`/etc/passwd`)を明示的に見たい場合は、セクション番号を指定します。

```console
$ man 5 passwd
```

### manページの内部構成

typicalなmanページは以下のセクションで構成されています。

- **NAME** — コマンド名と一行の簡単な説明
- **SYNOPSIS** — コマンドの構文(角括弧`[ ]`はオプション引数を意味する)
- **DESCRIPTION** — 詳細な説明
- **OPTIONS** — 各オプションの説明
- **EXAMPLES** — 使用例(存在する場合)
- **FILES** — 関連する設定ファイル
- **SEE ALSO** — 関連コマンドへの参照
- **AUTHOR** / **BUGS** — 作者情報や既知の不具合

### manページ内での検索

`man`はデフォルトで `less` をページャとして使用するため、`less`の検索機能がそのまま使えます。

```console
/pattern      # 前方検索
n             # 次の一致箇所へ
N             # 前の一致箇所へ
q             # manページを終了
```

### `man -k`(`apropos`と同等)

キーワードでmanページ自体を検索したい場合は `man -k` を使います。

```console
$ man -k partition
fdisk (8)            - manipulate disk partition table
gparted (8)          - GNOME partition editor
parted (8)           - a partition manipulation program
```

これは内部的に `apropos` と同じデータベース(`mandb`が生成するインデックス)を検索します。

---

## 3. `whatis` と `apropos`

### `whatis`

コマンド名が分かっているとき、その一行要約(manページのNAMEセクション相当)だけを素早く確認できます。

```console
$ whatis grep
grep (1)             - print lines that match patterns
```

### `apropos`

`man -k` と同じ動作をするコマンドで、キーワードに関連するmanページを検索します。

```console
$ apropos "list directory"
ls (1)               - list directory contents
```

`whatis`と`apropos`はいずれも`mandb`データベースに依存しているため、新しくインストールしたパッケージのmanページがヒットしない場合は次のコマンドでデータベースを更新します。

```console
$ sudo mandb
```

---

## 4. `info` コマンド

GNUプロジェクトの一部のコマンド(特に`coreutils`、`bash`、`gcc`など)は、manページより詳細なドキュメントを **info** 形式(GNU Texinfo)で提供しています。infoドキュメントはハイパーリンク形式のノード(node)で構成され、階層的に移動できます。

```console
$ info coreutils
```

### infoの基本操作

| キー | 動作 |
|---|---|
| `Space` / `b` | 次/前のページへスクロール |
| `n` | 次のノード(next) |
| `p` | 前のノード(previous) |
| `u` | 上位ノードへ(up) |
| `Enter`(リンク上) | リンク先のノードへ移動 |
| `l` | 直前に見ていたノードへ戻る(last) |
| `q` | 終了 |

特定コマンドのinfoページへ直接アクセスすることもできます。

```console
$ info ls
```

manとinfoの使い分けとしては、manは簡潔なリファレンス、infoはチュートリアル的で詳細な説明という傾向がありますが、両方が存在しない、あるいは内容がほぼ同じコマンドも多くあります。

---

## 5. `/usr/share/doc` 以下のドキュメント

パッケージ管理システム(`apt`、`dnf`など)でインストールされたソフトウェアは、しばしば `/usr/share/doc/<package-name>/` にREADME、changelog、設定例などの追加ドキュメントを配置します。

```console
$ ls /usr/share/doc/bash/
CHANGES.gz  README  README.Debian  changelog.Debian.gz  examples/
```

```console
$ zcat /usr/share/doc/bash/CHANGES.gz | less
```

`.gz`で圧縮されているファイルが多いため、`zcat`、`zless`、`zgrep`などの圧縮ファイル対応コマンドを使うと展開せずに中身を確認できます。

```console
$ zless /usr/share/doc/apt/README.gz
```

---

## 6. コマンドの用途を素早く整理する実践例

以下は、初めて触るコマンド(例: `tar`)について調査する典型的な流れです。

```console
$ whatis tar
tar (1)              - an archiving utility

$ tar --help | head -20

$ man tar
```

manページの中で圧縮オプションだけを知りたい場合は、`less`の検索機能を使います。

```console
/gzip
```

---

## まとめ

| 手段 | 用途 |
|---|---|
| `command --help` | 素早くオプション一覧を確認 |
| `man command` | 網羅的なリファレンス |
| `man -k` / `apropos` | キーワードから関連コマンドを探す |
| `whatis` | コマンド名から一行要約を得る |
| `info command` | GNUコマンドの詳細なチュートリアル的説明 |
| `/usr/share/doc/` | パッケージ固有のREADMEや設定例 |

---

## Referencias

- LPI Learning Materials, Topic 2.2: Using the Command Line to Get Help — https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- GNU `man-db` project — https://www.nongnu.org/man-db/
- GNU Texinfo manual (`info` documentation system) — https://www.gnu.org/software/texinfo/
- GNU Coreutils manual — https://www.gnu.org/software/coreutils/manual/