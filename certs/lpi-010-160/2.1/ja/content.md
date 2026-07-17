# 2.1 Command Line Basics

## この項目について

Linux essentials 試験 (010-160) における Command Line Basics は、shell の基本操作を扱う項目です。GUI を介さずに Linux システムを操作する際の土台となる知識であり、command syntax、shell の種類、環境変数、command history、command completion、そして基本的な情報取得コマンド (`man`, `whoami`, `uname` など) を理解することが求められます。

## Shell とは何か

Shell は、ユーザーが入力した command を解釈し、kernel に処理を依頼して結果を表示する command line interpreter です。Linux のデフォルト shell として最も広く使われているのは **bash** (Bourne Again SHell) ですが、他にも `sh`, `dash`, `zsh`, `ksh` などが存在します。

現在使用している shell を確認するには、`$SHELL` という環境変数を参照します。

```
$ echo $SHELL
/bin/bash
```

ログインしている shell はユーザーごとに `/etc/passwd` の最終フィールドに記録されています。

```
$ grep student /etc/passwd
student:x:1000:1000:Student User:/home/student:/bin/bash
```

## Command の基本構文

Linux の command はおおよそ次の形式に従います。

```
command [options] [arguments]
```

- **command**: 実行するプログラムまたは shell builtin の名前
- **options**: command の挙動を変更する指定 (多くの場合 `-` または `--` で始まる)
- **arguments**: command が処理する対象 (file 名など)

例えば `ls` command の場合:

```
$ ls -l /etc
```

ここで `-l` は option (long listing format)、`/etc` は argument (対象 directory) です。

Option には短い形式 (single dash + single letter) と長い形式 (double dash + word) の2種類があり、複数の短い option はまとめて指定できます。

```
$ ls -l -a -h
$ ls -lah
```

これらは同じ意味です (`-l` long format, `-a` all files including hidden, `-h` human-readable sizes)。

## Command の探索: PATH 変数

Shell が command を実行する際、実行可能な program がどこにあるかを `PATH` という環境変数で管理されている directory list から探します。

```
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

各 directory は `:` で区切られており、shell は左から順に探索し、最初に見つかった実行可能 file を実行します。ある command が実際にどの file を実行しているかは `which` または `type` で確認できます。

```
$ which ls
/usr/bin/ls

$ type cd
cd is a shell builtin
```

`type` は builtin command (shell 自身に組み込まれている command, 例: `cd`, `echo`, `pwd`) と外部 program の違いを区別できる点で `which` より汎用的です。

Command が `PATH` 上に無い場合、絶対 path (`/home/student/myscript.sh`) や相対 path (`./myscript.sh`) を明示的に指定する必要があります。

## Quoting と Escaping

Shell は特殊文字 (`*`, `$`, `"`, `'`, `\`, スペースなど) を特別な意味として解釈します。これを制御するために quoting と escaping を使います。

- **Single quotes (`'...'`)**: 内部のすべての文字を literal (そのままの文字) として扱う。変数展開もされない。
- **Double quotes (`"..."`)**: 大部分の特殊文字を literal として扱うが、変数展開 (`$VAR`) と command substitution (`` `cmd` `` や `$(cmd)`) は行われる。
- **Backslash (`\`)**: 直後の1文字だけを literal として扱う (escape)。

```
$ name="Linux"
$ echo 'Hello, $name'
Hello, $name

$ echo "Hello, $name"
Hello, Linux

$ echo Hello,\ World
Hello, World
```

Space を含む file 名を扱う際は quoting が特に重要です。

```
$ touch "my file.txt"
$ ls -l "my file.txt"
-rw-r--r-- 1 student student 0 Jul 12 10:00 my file.txt
```

## Command History

Bash は実行した command を history として記録します。デフォルトでは `~/.bash_history` に保存され、`history` command で一覧表示できます。

```
$ history
  501  ls -l
  502  cd /etc
  503  cat passwd
  504  history
```

主な history 操作:

| 操作 | 内容 |
|---|---|
| 上下矢印キー | 過去の command を順に呼び出す |
| `Ctrl+R` | history を interactive に検索 (reverse-i-search) |
| `!!` | 直前の command を再実行 |
| `!n` | history 番号 n の command を実行 (例: `!502`) |
| `!string` | string で始まる直近の command を実行 |

```
$ !502
cd /etc
```

環境変数 `HISTSIZE` (メモリ上に保持する件数) や `HISTFILESIZE` (file に保存する件数) で history の量を制御できます。

## Tab Completion

Bash には command 名、file 名、path、変数名などを Tab キーで自動補完する機能があります。入力途中で `Tab` を1回押すと、候補が一意なら補完され、複数候補がある場合は何も起きません。もう一度 `Tab` を押すと候補一覧が表示されます。

```
$ cd /etc/net<Tab>
$ cd /etc/network/
```

Tab completion は typo を減らし、長い path の入力を効率化するため、日常的な command line 操作で非常に重要です。

## ヘルプの参照方法

Linux には command の使い方を調べる複数の手段が用意されています。

### `man` (manual pages)

最も標準的な参照方法です。Manual は複数の section に分かれています (1: user commands, 5: file formats, 8: system administration commands など)。

```
$ man ls
```

同じ名前が複数 section に存在する場合、section 番号を指定します。

```
$ man 5 passwd
```

`man` 内では `/keyword` で検索、`q` で終了します。関連する section を横断的に検索するには `man -k keyword` (または `apropos keyword`) を使います。

```
$ man -k partition
fdisk (8)            - manipulate disk partition table
```

### `--help` option

多くの command は `--help` option で簡潔な使い方summaryを表示します。

```
$ ls --help | head -5
Usage: ls [OPTION]... [FILE]...
List information about the FILEs (the current directory by default).
```

### `info`

一部の command (特に GNU project 由来のもの) は `man` より詳細な `info` document を持ちます。

```
$ info coreutils 'ls invocation'
```

## 基本的な情報取得 Command

以下は shell 環境やシステム情報を調べる代表的な command です。

```
$ whoami
student

$ hostname
lpi-lab

$ uname -a
Linux lpi-lab 6.5.0-generic #1 SMP x86_64 GNU/Linux

$ date
Sun Jul 12 10:15:32 UTC 2026

$ pwd
/home/student

$ echo $$
12345
```

- `whoami`: 現在の実効 user 名を表示
- `uname -a`: kernel 名、hostname、kernel version、architecture などを表示
- `pwd`: 現在の working directory を表示
- `echo $$`: 現在の shell process の PID (process ID) を表示

## Redirection と Pipe (基礎)

Command line 操作では、command の入出力を制御する記号もよく使われます。

```
$ echo "log entry" > output.txt      # 標準出力を file に上書き
$ echo "another entry" >> output.txt # 標準出力を file に追記
$ sort < names.txt                   # file を標準入力として渡す
$ ls -l | grep ".txt"                # 前の command の出力を次の command の入力にする
```

これらの詳細 (file descriptor、`2>` によるエラー出力の制御など) は別項目 (I/O redirection) でより深く扱われますが、command line の基本操作として概念だけは押さえておく必要があります。

## よくある間違いと注意点

- Option の前に `-` を忘れる (`ls l` は `l` という file/directory を探そうとしてしまう)
- Single quote と double quote の違いを混同し、変数展開が意図通りに行われない
- Space を含む file 名を quoting せずに扱い、複数の argument として誤認識される
- `PATH` に含まれていない directory の実行可能 file を、path 指定無しで実行しようとする (`command not found` エラー)

## Referencias

- LPI Learning Materials — Command Line Basics: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Coreutils Manual: https://www.gnu.org/software/coreutils/manual/coreutils.html
- Linux man-pages project: https://www.kernel.org/doc/man-pages/