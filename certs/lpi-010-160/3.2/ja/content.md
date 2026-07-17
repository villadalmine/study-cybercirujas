# 3.2 Searching and Extracting Data from Files

## この章で学ぶこと

Linux のコマンドラインでは、ファイルの中身を検索したり、必要な部分だけを抜き出したり、複数のコマンドを組み合わせてデータを加工したりする操作が日常的に発生します。ここでは、standard streams（標準入出力）の概念、pipe（`|`）と redirection（`>`, `>>`, `<`, `2>`）、そして `grep`、`cut`、`sort`、`uniq`、`wc`、`head`、`tail`、`tee`、`tr` といった代表的なテキスト処理コマンドを扱います。

## Standard Streams と Redirection

Linux の各プロセスには、デフォルトで3つの standard stream（標準ストリーム）が結び付けられています。

| Stream | 番号（file descriptor） | 役割 |
|---|---|---|
| stdin | 0 | プロセスへの入力 |
| stdout | 1 | 通常の出力 |
| stderr | 2 | エラー出力 |

これらは redirection operator を使ってファイルにつなぎ替えることができます。

```bash
$ echo "hello" > out.txt      # stdout をファイルに書き込む（上書き）
$ echo "world" >> out.txt     # stdout をファイルに追記
$ cat out.txt
hello
world

$ ls /nonexistent 2> error.log   # stderr だけをファイルに保存
$ cat error.log
ls: cannot access '/nonexistent': No such file or directory

$ sort < out.txt               # stdin としてファイルを読み込む
hello
world
```

`2>&1` は「stderr を stdout と同じ行き先にまとめる」という意味で、両方を1つのファイルにまとめたいときに使います。

```bash
$ command > all.log 2>&1
```

## Pipe (`|`)

Pipe は、あるコマンドの stdout を別のコマンドの stdin に直接つなぐ仕組みです。中間ファイルを作らずにコマンドを連結できるのが利点です。

```bash
$ ps aux | grep sshd
root       842  0.0  0.1  12144  6800 ?        Ss   09:01   0:00 /usr/sbin/sshd -D
```

`ps aux` の出力が `grep sshd` の入力になり、`sshd` を含む行だけが表示されます。pipe は何個でも連結できます。

```bash
$ cat /etc/passwd | cut -d: -f1 | sort | head -n 5
adm
bin
daemon
games
gdm
```

## `grep` と正規表現（regular expression）

`grep`（Global Regular Expression Print）は、パターンにマッチする行を検索するための最も基本的なツールです。

```bash
$ grep "root" /etc/passwd
root:x:0:0:root:/root:/bin/bash
```

主なオプション：

| オプション | 意味 |
|---|---|
| `-i` | 大文字小文字を無視（case-insensitive） |
| `-v` | マッチしない行を表示（invert match） |
| `-n` | 行番号を表示 |
| `-c` | マッチした行数のみ表示 |
| `-r` / `-R` | ディレクトリを再帰的に検索 |
| `-l` | マッチしたファイル名のみ表示 |
| `-E` | extended regular expression を使う（`egrep` と同等） |
| `-F` | 正規表現ではなく固定文字列として検索（`fgrep` と同等） |

正規表現の基本メタ文字：

| 記号 | 意味 |
|---|---|
| `.` | 任意の1文字 |
| `*` | 直前の文字の0回以上の繰り返し |
| `^` | 行頭 |
| `$` | 行末 |
| `[abc]` | a, b, c のいずれか1文字 |
| `[^abc]` | a, b, c 以外の1文字 |

例：

```bash
$ grep "^root" /etc/passwd          # root で始まる行
root:x:0:0:root:/root:/bin/bash

$ grep -v "^#" /etc/ssh/sshd_config # コメント行(#)を除外
$ grep -c "bash$" /etc/passwd       # bash で終わる行の数
3
$ grep -Ei "error|warn" /var/log/syslog   # ERROR か WARN（大文字小文字無視）
```

`basic regular expression (BRE)` と `extended regular expression (ERE)` の違いにも注意が必要です。BRE では `+` や `|` を使うには `\+`, `\|` のようにエスケープが必要ですが、ERE（`grep -E`）ではそのまま使えます。

## `cut`：列（フィールド）の抽出

`cut` は、行の中から指定した列だけを抜き出すコマンドです。

```bash
$ cut -d: -f1,3 /etc/passwd | head -n 3
root:0
daemon:1
bin:2
```

- `-d` : 区切り文字（delimiter）を指定
- `-f` : 抜き出すフィールド番号
- `-c` : 文字位置（column）で抜き出す

```bash
$ echo "linux-essentials" | cut -c1-5
linux
```

## `sort`：並べ替え

```bash
$ sort out.txt
hello
world

$ sort -n numbers.txt    # 数値として並べ替え
$ sort -r out.txt        # 逆順（reverse）
$ sort -k2 data.txt      # 2番目のフィールドをキーに並べ替え
$ sort -u names.txt      # 並べ替えつつ重複行を削除（unique）
```

## `uniq`：重複行の処理

`uniq` は「連続する」重複行だけを対象にするため、通常は事前に `sort` してから使います。

```bash
$ cat colors.txt
red
red
blue
red

$ sort colors.txt | uniq
blue
red

$ sort colors.txt | uniq -c
      1 blue
      3 red
```

- `-c` : 出現回数を表示
- `-d` : 重複している行だけ表示
- `-u` : 重複していない行だけ表示

## `wc`：行数・単語数・文字数のカウント

```bash
$ wc /etc/passwd
  47   64 2374 /etc/passwd
```

出力は「行数 単語数 バイト数 ファイル名」の順です。

- `-l` : 行数のみ
- `-w` : 単語数のみ
- `-c` : バイト数のみ

```bash
$ wc -l /etc/passwd
47 /etc/passwd

$ ls | wc -l    # カレントディレクトリのファイル/ディレクトリ数
```

## `head` と `tail`：先頭・末尾の表示

```bash
$ head -n 3 /etc/passwd     # 先頭3行
$ tail -n 5 /var/log/syslog # 末尾5行
$ tail -f /var/log/syslog   # ファイルの追記をリアルタイムで追跡（follow）
```

`tail -f` はログファイルの監視によく使われ、`Ctrl+C` で終了します。

## `tee`：出力を分岐させる

`tee` は、stdin から受け取った内容をファイルに保存しつつ、そのまま stdout にも流します（Tの字のように分岐するイメージ）。

```bash
$ ps aux | tee processes.log | grep sshd
```

上の例では、`ps aux` の全出力が `processes.log` に保存されると同時に、`grep sshd` にも渡されます。

## `tr`：文字の変換・削除

```bash
$ echo "Hello World" | tr 'a-z' 'A-Z'
HELLO WORLD

$ echo "a,b,c" | tr ',' '\n'
a
b
c

$ echo "hello   world" | tr -s ' '   # 連続する空白を1つに圧縮（squeeze）
hello world
```

## コマンドを組み合わせた実践例

```bash
$ cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn
     30 /bin/false
     10 /bin/bash
      3 /usr/sbin/nologin
```

この例では、`/etc/passwd` からログインシェルの列を抽出し、種類ごとにカウントして、使用頻度の多い順に表示しています。`cut` → `sort` → `uniq -c` → `sort -rn` という pipe の連鎖が、Linux のテキスト処理の基本パターンです。

## Referencias

- LPI Learning Materials — 010-160, Topic 3.2: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- GNU Grep Manual: https://www.gnu.org/software/grep/manual/grep.html
- GNU Coreutils Manual (cut, sort, uniq, wc, head, tail, tr, tee): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Bash Reference Manual — Redirections: https://www.gnu.org/software/bash/manual/bash.html#Redirections
- Bash Reference Manual — Pipelines: https://www.gnu.org/software/bash/manual/bash.html#Pipelines