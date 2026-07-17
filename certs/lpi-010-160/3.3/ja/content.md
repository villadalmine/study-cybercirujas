# 3.3 Turning Commands into a Script

## 概要

Linux の運用では、同じコマンドを何度も繰り返し実行する場面が頻繁にあります。そのたびに手入力するのは非効率であり、typo（入力ミス）のリスクも高まります。これを解決するのが **shell script** です。複数の command を1つのテキストファイルにまとめ、それを1回の実行で順番に処理させることができます。

この項目は試験での比重が **4**（中程度）であり、`bash` scripting の基礎——script の作成・実行方法、variable、argument、exit status、簡単な制御構文——を理解しておく必要があります。

## 1. シェルスクリプトとは何か

shell script とは、shell（一般的には `bash`）が1行ずつ解釈・実行する command の並びを記述したテキストファイルです。プログラミング言語のようにコンパイルする必要はなく、shell が interpreter として動作し、上から順に各 command を実行します。

例えば、以下のように毎回手動で実行している一連の command があるとします。

```bash
$ mkdir -p ~/backup
$ cp -r ~/documents ~/backup/
$ tar -czf ~/backup-$(date +%F).tar.gz ~/backup
$ echo "Backup completed"
```

これを1つのファイルにまとめれば、1回の呼び出しで同じ処理を再現できます。

## 2. シェバン行（shebang）

script ファイルの1行目には、通常 **shebang**（`#!` で始まる行）を記述します。これは、このファイルをどの interpreter で実行すべきかを OS に伝える仕組みです。

```bash
#!/bin/bash
```

この行は「`/bin/bash` を使ってこのファイルを実行しなさい」という指示です。`#!/bin/sh` のように別の shell を指定することもできます。shebang がない場合、`bash script.sh` のように明示的に interpreter を指定して実行する必要があります。

## 3. スクリプトの作成と実行権限

script ファイルは通常 `.sh` 拡張子を付けて作成しますが、これは慣習であり必須ではありません（Linux では拡張子は実行可否に影響しません）。

```bash
$ vi backup.sh
```

内容を保存した後、実行するには2つの方法があります。

**方法1: 実行権限を付与して直接実行する**

```bash
$ chmod +x backup.sh
$ ls -l backup.sh
-rwxr-xr-x 1 user user 142 Jul 16 10:00 backup.sh
$ ./backup.sh
```

`chmod +x` によって execute permission（`x` フラグ）が付与され、`./backup.sh` のように path を指定して実行できるようになります（`.` は現在の directory を意味し、`PATH` 上にないファイルを実行するために必要です）。

**方法2: interpreter に直接渡す**

```bash
$ bash backup.sh
```

この方法では file 自体に実行権限がなくても動作します。shebang の指定も無視され、常に `bash` で解釈されます。

## 4. スクリプトの基本構造とコメント

script 内では `#` から行末までが comment として扱われ、実行時には無視されます（先頭の shebang 行は特別扱いされる点に注意）。

```bash
#!/bin/bash
# このスクリプトはバックアップを作成する

echo "Starting backup..."
mkdir -p ~/backup
cp -r ~/documents ~/backup/
echo "Backup completed"
```

実行結果:

```bash
$ ./backup.sh
Starting backup...
Backup completed
```

comment は「何をしているか」ではなく「なぜそうしているか」を書くために使うのが望ましい習慣です。

## 5. 変数とコマンドライン引数

### ユーザー定義変数

script 内では variable を自由に定義できます。代入時に `=` の前後に space を入れてはいけません。

```bash
#!/bin/bash
NAME="World"
echo "Hello, $NAME"
```

```bash
$ ./hello.sh
Hello, World
```

### コマンドライン引数

script 実行時に渡された argument は、特殊な positional parameter で参照できます。

| 変数 | 意味 |
|---|---|
| `$0` | script 自身の名前 |
| `$1`, `$2`, … | 1番目、2番目…の argument |
| `$#` | argument の個数 |
| `$@` | すべての argument（個別の word として） |

```bash
#!/bin/bash
echo "Script name: $0"
echo "First argument: $1"
echo "Number of arguments: $#"
echo "All arguments: $@"
```

```bash
$ ./args.sh apple banana
Script name: ./args.sh
First argument: apple
Number of arguments: 2
All arguments: apple banana
```

## 6. 終了ステータス（exit status）

すべての command は終了時に **exit status**（0〜255の整数）を返します。慣習として `0` は成功、それ以外は何らかのエラーを意味します。直前に実行した command の exit status は特殊変数 `$?` で参照できます。

```bash
$ ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
$ echo $?
2
```

script 内で明示的に exit status を返したい場合は `exit` command を使います。

```bash
#!/bin/bash
if [ -d ~/backup ]; then
    echo "Directory exists"
    exit 0
else
    echo "Directory not found"
    exit 1
fi
```

## 7. 基本的な制御構造

複数 command を単に順番に並べるだけでなく、条件分岐や繰り返しを使うことで、より柔軟な script を作成できます。

### 条件分岐（if）

```bash
#!/bin/bash
if [ -f "$1" ]; then
    echo "$1 is a regular file"
else
    echo "$1 does not exist or is not a file"
fi
```

```bash
$ ./checkfile.sh /etc/passwd
/etc/passwd is a regular file
```

### 繰り返し（for）

```bash
#!/bin/bash
for FILE in *.txt; do
    echo "Processing $FILE"
done
```

```bash
$ ./loop.sh
Processing notes.txt
Processing report.txt
```

## 8. コマンド履歴とスクリプト作成の関係

shell の `history` command は、過去に実行した command の記録を表示します。これは script を作成する際の出発点として有用です。

```bash
$ history
  501  mkdir -p ~/backup
  502  cp -r ~/documents ~/backup/
  503  tar -czf backup.tar.gz ~/backup
```

過去に実行した command を確認し、それらをそのまま `.sh` ファイルにコピーして shebang を追加すれば、繰り返し作業の script 化が容易になります。また `history` の出力は `~/.bash_history` に保存されており、`fc` command で編集・再実行することも可能です。

## 9. 実践例：まとめ

以上の要素を組み合わせた、実用的な script の例です。

```bash
#!/bin/bash
# 引数で指定したディレクトリ内のファイル数を数える

if [ $# -eq 0 ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

TARGET_DIR="$1"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: $TARGET_DIR is not a directory"
    exit 1
fi

COUNT=$(ls "$TARGET_DIR" | wc -l)
echo "Number of items in $TARGET_DIR: $COUNT"
exit 0
```

```bash
$ chmod +x countfiles.sh
$ ./countfiles.sh /etc
Number of items in /etc: 218
$ echo $?
0
```

## Referencias

- LPI Learning Materials — Topic 3.3 Turning Commands into a Script: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- LPI Linux Essentials Exam Objectives (010-160, v1.6): https://www.lpi.org/our-certifications/exam-160-objectives
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- Bash man page (`man bash`): https://man7.org/linux/man-pages/man1/bash.1.html