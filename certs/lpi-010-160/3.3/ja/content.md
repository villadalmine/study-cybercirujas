# 3.3 Turning Commands into a Script

**Exam weight: 4** — 010-160試験の中でも比較的配点の高いトピックです。shebang、実行権限、変数、引数、exit code、条件分岐、ループについて幅広く出題されます。

---

## 1. なぜscriptを書くのか

シェルのプロンプトで一つずつ入力しているコマンドは、そのままテキストファイルに保存して何度でも再生できます。これが**shell script**です。一連のコマンドを上から下へ順番に実行するだけの、単なるプレーンテキストファイルにすぎません。

scriptを書く理由は次の通りです。

- **自動化** — バックアップ、クリーンアップ、レポート生成など、繰り返し行う作業を手放しで実行できる。
- **手順の文書化** — 「どうやるか」を陳腐化しがちなwikiページではなく、実行可能なコードとして残せる。
- **ミスの削減** — 人間が手作業で毎回タイプするより、機械が同じ手順を同じように実行するほうが確実。
- **スケジュール実行** — `cron`などと組み合わせて、無人で処理を走らせられる。

同じ3つのコマンドを2回タイプしたら、それはすでにscriptにすべきサインです。

---

## 2. Scriptの基本構造

### 2.1 Shebang（`#!`）

scriptの1行目には**shebang**（*hashbang*とも呼ばれる）を置くのが基本です。`#!`に続けて、そのscriptを実行するinterpreterの絶対パスを書きます。

```bash
#!/bin/bash
```

scriptをprogramとして実行すると、kernelはまずこの1行目を読み取り、指定されたinterpreterを起動して、scriptファイル自体をその入力として渡します。interpreterはbashに限りません。

| Shebang | Interpreter |
|---|---|
| `#!/bin/bash` | Bash（Bourne Again Shell）— Linuxでの標準的な選択肢 |
| `#!/bin/sh` | システムのPOSIXシェル（`bash`や`dash`へのリンクであることが多い） |
| `#!/usr/bin/env python3` | `PATH`から探したPython 3 |
| `#!/usr/bin/perl` | Perl |

**shebangは必ずファイルの最初の行**でなければなりません。空行やスペースをその前に置いてはいけません。1行目以外に書いても、それは単なるcommentとして無視されます。

### 2.2 Comment

shebang以外の場所では、`#`から行末までが**comment**として扱われ、シェルはその部分を実行時に無視します。「何をしているか」ではなく「なぜそうしているか」を書くのが良いcommentです。

```bash
#!/bin/bash
# backup-home.sh - ホームディレクトリをアーカイブする
# Author: carol, Last updated: 2026-07-07

tar -czf /tmp/home-backup.tar.gz "$HOME"   # -z はgzip圧縮
```

### 2.3 最初のscriptを書く

エディタは何でも構いませんが、試験では次の2つの定番エディタを知っておく必要があります。

- **`nano`** — 初心者向け。画面下部に主要な操作が常に表示される（`Ctrl+O`で保存、`Ctrl+X`で終了）。
- **`vi` / `vim`** — ほぼすべてのUnix系システムに存在するmodal editor（`i`で挿入モード、`Esc`の後`:wq`で保存して終了）。

```console
$ nano hello.sh
```

内容：

```bash
#!/bin/bash
# 最初のscript
echo "Hello, world!"
```

---

## 3. Scriptを実行可能にする

作成直後のファイルには実行権限がないため、直接実行しようとすると失敗します。

```console
$ ./hello.sh
bash: ./hello.sh: Permission denied
```

実行する方法は主に2通りあります。

**方法1 — interpreterに明示的に渡す**（実行権限は不要。shebangは無視される）

```console
$ bash hello.sh
Hello, world!
```

**方法2 — `chmod`で実行権限を付与する**（標準的なやり方）

```console
$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 carol carol 52 Jul  7 10:15 hello.sh
$ ./hello.sh
Hello, world!
```

### なぜ`./`が必要か

セキュリティ上の理由から、カレントディレクトリ（`.`）は通常`PATH`（シェルがコマンドを探索するディレクトリの一覧）に含まれていません。`./hello.sh`と書くことで、シェルに探索させずに明示的なパスとしてscriptを指定します。名前だけで実行したい場合は、`PATH`に含まれるディレクトリ（例：`/usr/local/bin`や`~/bin`）にscriptを置きます。

```console
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/home/carol/bin
$ cp hello.sh ~/bin/hello
$ hello
Hello, world!
```

**Tip:** 既存のコマンド名（例：`test`。これはbuilt-inでありbinaryでもある）とscriptの名前が衝突しないよう、事前に`which`や`type`で確認する習慣をつけましょう。

---

## 4. 出力を作る：`echo`と`printf`

`echo`は与えられた引数を表示し、最後に改行を出力します。

```console
$ echo "The current directory is: $PWD"
The current directory is: /home/carol
```

よく使うオプション：

- `echo -n` — 末尾の改行を出さない。
- `echo -e` — `\n`（改行）や`\t`（タブ）などのエスケープシーケンスを解釈する。

```console
$ echo -e "Name:\tCarol\nShell:\t$SHELL"
Name:	Carol
Shell:	/bin/bash
```

`printf`はより細かい書式指定ができます（`printf "%s is %d years old\n" "Alice" 30`）が、このレベルのscriptingでは`echo`だけで十分なケースがほとんどです。

---

## 5. 変数（Variables）

### 5.1 代入と参照

`NAME=value`の形で代入します。**`=`の前後にスペースを入れてはいけません。** 値を参照するときは`$NAME`と書きます。

```bash
#!/bin/bash
username="carol"
greeting="Welcome back"
echo "$greeting, $username!"
```

```console
$ ./welcome.sh
Welcome back, carol!
```

覚えておくべきルール：

- 変数名は文字・数字・アンダースコアを使えますが、**数字で始めることはできません**。
- `VAR = value`（スペースあり）はエラーになります — シェルは`VAR`をコマンド名だと解釈してしまいます。
- 変数展開は`"$var"`のように二重引用符で囲む習慣をつけましょう。値にスペースが含まれていてもscriptが壊れません。

### 5.2 コマンドの出力を変数に取り込む

**command substitution**を使うと、あるコマンドの出力を変数に格納できます。`$(...)`という構文を使います。

```bash
#!/bin/bash
today=$(date +%F)
kernel=$(uname -r)
echo "Report generated on $today (kernel $kernel)"
```

```console
$ ./report.sh
Report generated on 2026-07-07 (kernel 6.9.4-200.fc40.x86_64)
```

古い記法として`` `date` ``のようなbacktickによるcommand substitutionもありますが、可読性が低くnestしにくいため、`$(...)`のほうが推奨されます。

### 5.3 Shell変数とEnvironment変数

scriptの中で作った変数は、そのscript（またはシェル）の中だけで有効です。`export VAR`とすることで**environment variable**（環境変数）となり、そこから起動される子プロセスにも引き継がれます。あらかじめ定義済みの代表的な環境変数には`$HOME`、`$USER`、`$PATH`、`$PWD`、`$SHELL`があります。

---

## 6. 引数：Scriptを再利用可能にする

scriptはscript名の後ろに書かれた値を**positional parameter**（位置パラメータ）として受け取ります。

| 変数 | 意味 |
|---|---|
| `$0` | script自身の名前 |
| `$1`、`$2`、… `$9` | 1番目、2番目、… 9番目の引数 |
| `$#` | 引数の個数 |
| `$@` | すべての引数（それぞれ独立した単語として） |
| `$*` | すべての引数（1つの単語として連結） |

```bash
#!/bin/bash
# args.sh - positional parameterのデモ
echo "Script name:     $0"
echo "First argument:  $1"
echo "Second argument: $2"
echo "Argument count:  $#"
echo "All arguments:   $@"
```

```console
$ ./args.sh apple banana cherry
Script name:     ./args.sh
First argument:  apple
Second argument: banana
Argument count:  3
All arguments:   apple banana cherry
```

実用的な例：

```bash
#!/bin/bash
# mkbackup.sh - 引数で渡されたファイルに日付を付けてコピーする
cp "$1" "$1.$(date +%F).bak"
echo "Backup of $1 created."
```

```console
$ ./mkbackup.sh notes.txt
Backup of notes.txt created.
$ ls notes*
notes.txt  notes.txt.2026-07-07.bak
```

---

## 7. Exit Code：成功したかどうかを知る

すべてのコマンドは終了時に**exit status**（*return code*とも呼ばれる）を返します。0から255までの整数です。

- **`0`は成功**を意味します。
- **`0以外はすべて失敗**を意味します（具体的な値の意味はコマンドごとに異なります）。

特殊変数`$?`には、**直前に実行された**コマンドのexit statusが格納されます。

```console
$ ls /etc/hostname
/etc/hostname
$ echo $?
0
$ ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
$ echo $?
2
```

注意点として、`$?`は新しいコマンドを実行するたびに上書きされます（値を表示するための`echo`自体もコマンドです）。後で使いたい場合は、値を別の変数に保存しておく必要があります。

script内では、`exit N`によってscriptを即座に終了し、exit status `N`を返せます。引数なしの`exit`（またはscriptの末尾に到達した場合）は、最後に実行されたコマンドのstatusをそのまま返します。

```bash
#!/bin/bash
if [ ! -f "$1" ]; then
    echo "Error: file $1 not found" >&2
    exit 1        # 呼び出し元に失敗を伝える
fi
echo "Processing $1..."
exit 0
```

exit codeがあるからこそ、`&&`（直前が成功したときだけ次を実行）や`||`（直前が失敗したときだけ次を実行）によるコマンドの連結が機能します。

```console
$ ./deploy.sh && echo "Deployed" || echo "Deploy FAILED"
```

---

## 8. 条件分岐：`if`と`test`

### 8.1 基本構造

```bash
if command; then
    # commandがexit status 0で終了した場合に実行される
elif other_command; then
    # 最初の条件が失敗し、こちらが成功した場合に実行される
else
    # 上記すべてが失敗した場合に実行される
fi
```

`if`の条件には*任意のコマンド*を置けます。そのコマンドのexit statusによって分岐が決まります。もっとも多用されるのは`test`コマンドで、通常は角括弧形式`[ ... ]`で書きます（角括弧の内側の前後にスペースを入れるのは必須です）。

### 8.2 よく使うtest

| Test | 真になる条件 |
|---|---|
| `[ -f FILE ]` | FILEが存在し、通常のファイルである |
| `[ -d DIR ]` | DIRが存在し、ディレクトリである |
| `[ -r FILE ]` / `[ -w FILE ]` / `[ -x FILE ]` | FILEが読み取り可能／書き込み可能／実行可能である |
| `[ -z "$s" ]` / `[ -n "$s" ]` | 文字列が空である／空でない |
| `[ "$a" = "$b" ]` / `[ "$a" != "$b" ]` | 文字列が等しい／等しくない |
| `[ "$x" -eq "$y" ]` | 整数が等しい（他に`-ne`、`-lt`、`-le`、`-gt`、`-ge`） |
| `[ ! EXPR ]` | EXPRが偽である（否定） |

### 8.3 例

```bash
#!/bin/bash
# checkfile.sh - 引数で渡されたファイルの種類を報告する

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <filename>" >&2
    exit 1
fi

if [ -d "$1" ]; then
    echo "$1 is a directory."
elif [ -f "$1" ]; then
    echo "$1 is a regular file, $(wc -l < "$1") lines long."
else
    echo "$1 does not exist."
    exit 2
fi
```

```console
$ ./checkfile.sh /etc
/etc is a directory.
$ ./checkfile.sh /etc/hostname
/etc/hostname is a regular file, 1 lines long.
$ ./checkfile.sh /nope; echo "exit status: $?"
/nope does not exist.
exit status: 2
```

---

## 9. ループ：`for`

`for`ループは、リストの各要素に対して、ひとまとまりのコマンド群を1回ずつ実行します。

```bash
for variable in list; do
    commands
done
```

**単語を反復する：**

```bash
#!/bin/bash
for fruit in apple banana cherry; do
    echo "I like $fruit"
done
```

```
I like apple
I like banana
I like cherry
```

**ファイルを反復する（glob展開）：**

```bash
#!/bin/bash
for f in *.log; do
    echo "Compressing $f"
    gzip "$f"
done
```

**scriptの引数を反復する：**

```bash
#!/bin/bash
for arg in "$@"; do
    echo "Argument: $arg"
done
```

**数値の範囲を反復する**（`seq`またはbrace expansionを使用）：

```console
$ for i in $(seq 1 3); do echo "Run $i"; done
Run 1
Run 2
Run 3
```

Bashには`while`ループ（`while [ condition ]; do ... done`）もあり、条件が真である間だけ処理を繰り返します。1行ずつ入力を読み込むといった用途に便利ですが、このレベルの試験範囲で重視されるのは`for`です。

---

## 10. 総合例

これまでの要素をすべて盛り込んだscriptです。

```bash
#!/bin/bash
# dirsummary.sh - 1つ以上のディレクトリの中身を要約する
# Usage: ./dirsummary.sh DIR [DIR...]

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 DIR [DIR...]" >&2
    exit 1
fi

report="/tmp/dirsummary-$(date +%F).txt"
echo "Directory summary - $(date)" > "$report"

for dir in "$@"; do
    if [ -d "$dir" ]; then
        count=$(ls -A "$dir" | wc -l)
        echo "$dir: $count entries" >> "$report"
    else
        echo "$dir: not a directory (skipped)" >> "$report"
    fi
done

echo "Report written to $report"
cat "$report"
exit 0
```

```console
$ chmod +x dirsummary.sh
$ ./dirsummary.sh /etc /home /nope
Report written to /tmp/dirsummary-2026-07-07.txt
Directory summary - Mon Jul  7 10:42:11 UTC 2026
/etc: 168 entries
/home: 1 entries
/nope: not a directory (skipped)
$ echo $?
0
```

---

## 11. 試験対策としての要点

- **Shebang**（`#!/bin/bash`）はscriptの1行目に置き、使用するinterpreterを指定する。
- shebang以外の場所では`#`が**comment**を開始する。
- scriptを実行可能にするには**`chmod +x`**を使う。カレントディレクトリは`PATH`に含まれないため、`./script.sh`のように明示的なパスで実行する。
- **変数**：`name=value`（`=`の前後にスペースなし）で代入し、`$name`で参照する。command substitution `$(command)`で出力を取り込む。
- **Positional parameter**：`$1`〜`$9`（引数）、`$0`（script名）、`$#`（引数の個数）、`$@`（すべての引数）。
- **Exit status**：`0`は成功、0以外は失敗。直前のコマンドのstatusは`$?`に入る。`exit N`で自分でも設定できる。
- **`if`/`test`**：`[ -f file ]`、`[ -d dir ]`のようなファイルtest、文字列比較（`=`、`!=`）、整数比較（`-eq`、`-lt`など）を使い分ける。`fi`で閉じる。
- **`for var in list; do ... done`**は、単語・glob・`"$@"`のいずれに対しても反復できる。
- scriptを書くための標準的なエディタとして**`nano`**と**`vi`**を知っておく。

---

## Referencias

- LPI Learning Materials — Topic 3.3 *Turning Commands into a Script*: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- LPI Linux Essentials Exam 010-160 Objectives (v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- Bash Reference Manual — Shell Scripts: https://www.gnu.org/software/bash/manual/html_node/Shell-Scripts.html
- Bash Reference Manual — Conditional Constructs: https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html
- Bash Reference Manual — Looping Constructs: https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html
- GNU Coreutils Manual — `test`: https://www.gnu.org/software/coreutils/manual/html_node/test-invocation.html
- GNU Coreutils Manual — `echo`: https://www.gnu.org/software/coreutils/manual/html_node/echo-invocation.html
- GNU nano Documentation: https://www.nano-editor.org/docs.php
- Vim Documentation: https://www.vim.org/docs.php
