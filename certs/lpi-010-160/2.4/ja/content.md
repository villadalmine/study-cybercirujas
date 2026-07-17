# 2.4 Creating, Moving and Deleting Files

## 概要

Linux のファイルシステムを扱う上で、ファイルやディレクトリの作成・移動・コピー・削除は最も基本的な操作です。この trailing セクションでは `touch`、`mkdir`、`cp`、`mv`、`rm`、`rmdir` の各コマンドと、それらを効率的に使うための wildcard（ワイルドカード）展開、および `find` コマンドの基礎を扱います。LPI Linux Essentials (010-160) の Exam Objective 2.4 に対応する内容です。

---

## 1. ファイル・ディレクトリの作成

### 1.1 `touch` — 空ファイルの作成とタイムスタンプの更新

`touch` は本来ファイルの mtime（modification time）と atime（access time）を更新するコマンドですが、指定したファイルが存在しない場合は **サイズ 0 バイトの空ファイル** を新規作成します。

```bash
$ touch notes.txt
$ ls -l notes.txt
-rw-r--r-- 1 user user 0 Jul 12 10:00 notes.txt
```

既存ファイルに対して実行すると、内容は変更されずタイムスタンプだけが更新されます。

```bash
$ touch notes.txt
$ stat -c '%y' notes.txt
2026-07-12 10:05:12.000000000 +0000
```

複数ファイルを一度に作成することも可能です。

```bash
$ touch file1.txt file2.txt file3.txt
```

主なオプション:

| オプション | 説明 |
|---|---|
| `-t STAMP` | タイムスタンプを `[[CC]YY]MMDDhhmm[.ss]` 形式で指定 |
| `-d STRING` | 日付文字列（例: `"2026-01-01"`）を指定 |
| `-c` / `--no-create` | ファイルが存在しない場合に新規作成しない |

### 1.2 `mkdir` — ディレクトリの作成

```bash
$ mkdir projects
$ ls -ld projects
drwxr-xr-x 2 user user 4096 Jul 12 10:10 projects
```

親ディレクトリが存在しない多階層のパスを一度に作る場合は `-p`（`--parents`）を使います。

```bash
$ mkdir project/src/main
mkdir: cannot create directory 'project/src/main': No such file or directory

$ mkdir -p project/src/main
$ find project -type d
project
project/src
project/src/main
```

`-p` は既存ディレクトリがあってもエラーにならない点も便利です（冪等な実行が可能）。

作成と同時にパーミッションを指定するには `-m`（`--mode`）を使います。

```bash
$ mkdir -m 700 private_dir
$ ls -ld private_dir
drwx------ 2 user user 4096 Jul 12 10:12 private_dir
```

---

## 2. ファイル・ディレクトリのコピー — `cp`

基本構文は `cp SOURCE DESTINATION` または `cp SOURCE... DIRECTORY` です。

```bash
$ cp notes.txt notes_backup.txt
$ ls
notes.txt  notes_backup.txt
```

複数ファイルを既存のディレクトリへコピーする場合、最後の引数はディレクトリでなければなりません。

```bash
$ cp file1.txt file2.txt projects/
$ ls projects/
file1.txt  file2.txt
```

### 2.1 ディレクトリの再帰的コピー

`cp` はデフォルトではディレクトリをコピーできません。ディレクトリ全体（サブディレクトリを含む）をコピーするには `-r`（`--recursive`、`-R` も同義）が必須です。

```bash
$ cp projects reports
cp: -r not specified; omitting directory 'projects'

$ cp -r projects reports
$ find reports
reports
reports/file1.txt
reports/file2.txt
```

### 2.2 主なオプション

| オプション | 説明 |
|---|---|
| `-r`, `-R` | ディレクトリを再帰的にコピー |
| `-i` | 上書き前に確認する（interactive） |
| `-v` | コピーしたファイル名を表示（verbose） |
| `-p` | パーミッション・所有者・タイムスタンプを保持 |
| `-a` | アーカイブモード（`-dR --preserve=all` 相当。リンクや属性を全て保持） |
| `-u` | コピー先が古いか存在しない場合のみコピー（update） |

```bash
$ cp -v file1.txt file1_copy.txt
'file1.txt' -> 'file1_copy.txt'
```

バックアップ作成やシステムファイルの複製など、属性を完全に保持したい場合は `cp -a` が定番です。

```bash
$ cp -a /etc/skel /home/newuser_template
```

---

## 3. ファイル・ディレクトリの移動とリネーム — `mv`

`mv` は「移動」と「リネーム」の両方に使われます。Linux には専用の rename コマンドはなく、同一ファイルシステム内での移動はディレクトリエントリの付け替えだけなので、`cp` と違い **再帰オプションは不要** です（ディレクトリごと丸ごと移動できます）。

### 3.1 リネーム

```bash
$ mv notes.txt memo.txt
$ ls
memo.txt  notes_backup.txt
```

### 3.2 移動

```bash
$ mv memo.txt projects/
$ ls projects/
file1.txt  file2.txt  memo.txt
```

ディレクトリごと移動する場合もオプション不要です。

```bash
$ mv reports archive/reports
$ ls archive/
reports
```

### 3.3 主なオプション

| オプション | 説明 |
|---|---|
| `-i` | 上書き前に確認する |
| `-f` | 確認なしで強制上書き（`-i` と併用時は後に指定した方が優先） |
| `-v` | 実行内容を表示 |
| `-n` | 既存ファイルを上書きしない（no-clobber） |

```bash
$ mv -i file2.txt file1_copy.txt
mv: overwrite 'file1_copy.txt'? y
```

複数ファイルを 1 つのディレクトリへ移動する場合も、最後の引数がディレクトリになります。

```bash
$ mv file1.txt file2.txt project/src/
```

---

## 4. ファイル・ディレクトリの削除

### 4.1 `rm` — ファイルの削除

```bash
$ rm notes_backup.txt
$ ls
notes_backup.txt: No such file or directory
```

ディレクトリを削除するには `-r`（`--recursive`）が必要です。中身が空でなくても再帰的に削除されます。

```bash
$ rm projects
rm: cannot remove 'projects': Is a directory

$ rm -r projects
```

確認なしで強制削除するには `-f`（`--force`）を組み合わせます。`-rf` はシステムを破壊しうる危険な組み合わせなので、対象パスは必ず確認してから実行すること。

```bash
$ rm -rf old_reports/
```

主なオプション:

| オプション | 説明 |
|---|---|
| `-r`, `-R` | ディレクトリを再帰的に削除 |
| `-f` | 確認なし・存在しないファイルでもエラーを出さない |
| `-i` | 1 件ずつ確認する |
| `-v` | 削除したファイル名を表示 |

```bash
$ rm -i file1.txt
rm: remove regular file 'file1.txt'? y
```

> **注意:** Linux の `rm` にはゴミ箱機能がありません。削除は即座に確定するため、特に `rm -rf` は実行前に対象パス（相対パス／絶対パス、ワイルドカードの展開結果）を必ず確認する習慣が重要です。

### 4.2 `rmdir` — 空ディレクトリの削除

`rmdir` は **空のディレクトリのみ** を削除できるコマンドです。中身が残っている場合は失敗します。

```bash
$ mkdir empty_dir
$ rmdir empty_dir
$ ls
empty_dir: No such file or directory

$ mkdir not_empty
$ touch not_empty/file.txt
$ rmdir not_empty
rmdir: failed to remove 'not_empty': Directory not empty
```

`-p` オプションを使うと、削除後に空になった親ディレクトリも連鎖的に削除できます。

```bash
$ mkdir -p a/b/c
$ rmdir -p a/b/c
$ ls a 2>&1
ls: cannot access 'a': No such file or directory
```

`rmdir` は誤って中身のあるディレクトリを消してしまう事故を防げるため、意図的に「空であること」を確認しながら削除したい場面で有効です。

---

## 5. Wildcard（ワイルドカード）展開

シェル（bash）はコマンド実行前にワイルドカードパターンをマッチするファイル名の一覧に展開（globbing）します。これは `cp`・`mv`・`rm` を複数ファイルに一括適用する際に頻繁に使われます。

| パターン | 意味 |
|---|---|
| `*` | 0 文字以上の任意の文字列（ただし先頭の `.` は通常マッチしない） |
| `?` | 任意の 1 文字 |
| `[abc]` | `a`・`b`・`c` のいずれか 1 文字 |
| `[a-z]` | `a` から `z` までの範囲の 1 文字 |
| `[!abc]` または `[^abc]` | `a`・`b`・`c` 以外の 1 文字 |

```bash
$ ls
report1.txt  report2.txt  report10.txt  summary.log

$ cp report*.txt archive/
$ ls archive/
report1.txt  report10.txt  report2.txt

$ rm report?.txt
$ ls
report10.txt  summary.log
```

`[...]` を使った範囲指定の例:

```bash
$ ls
img01.png  img02.png  img03.png  img10.png

$ rm img0[1-3].png
$ ls
img10.png
```

拡張パターン（`extglob`）を使うと、より高度な除外指定も可能です（bash で `shopt -s extglob` が必要）。

```bash
$ shopt -s extglob
$ ls
a.txt  b.txt  c.log

$ rm !(*.log)
$ ls
c.log
```

---

## 6. `find` を使ったファイル操作

`find` は条件に合致するファイルを検索し、`-delete` や `-exec` で直接操作できます。単純な wildcard では表現できない「サイズ」「更新日時」「種類」などの条件で対象を絞り込めるのが特徴です。

### 6.1 種類（type）で絞り込む

```bash
$ find . -type f -name "*.tmp"
./cache/session.tmp
./data/upload.tmp
```

`-type d` はディレクトリ、`-type f` は通常ファイル、`-type l` はシンボリックリンクを意味します。

### 6.2 サイズで絞り込む

```bash
$ find /var/log -type f -size +10M
/var/log/syslog
/var/log/journal/system.log
```

`+10M` は 10 MB より大きいファイル、`-10M` は 10 MB 未満、`10M` はちょうど 10 MB を意味します。

### 6.3 更新日時で絞り込む

```bash
$ find /tmp -type f -mtime +7
/tmp/old_upload.dat
```

`-mtime +7` は 7 日以上前に更新されたファイルを対象とします。

### 6.4 検索結果に対する操作

見つかったファイルをそのまま削除するには `-delete`、または `-exec` でコマンドを実行します。

```bash
$ find /tmp -type f -name "*.tmp" -delete
```

```bash
$ find . -type f -name "*.bak" -exec rm {} \;
```

`{}` はマッチしたファイルパスに置き換えられ、`\;` は各ファイルごとにコマンドを 1 回実行することを示します（`+` を使うとまとめて 1 回のコマンドで処理され効率的です）。

```bash
$ find /var/tmp -type f -mtime +30 -exec mv {} /var/tmp/archive/ \;
```

> **注意:** `find ... -delete` や `-exec rm` は確認なしで即削除されるため、必ず先に `-delete` を付けずに実行して検索結果（対象ファイル一覧）を確認してから削除を行うことが推奨されます。

---

## 7. コマンドの比較まとめ

| 操作 | 単一ファイル | ディレクトリ（再帰） |
|---|---|---|
| 作成 | `touch file` | `mkdir -p dir/subdir` |
| コピー | `cp src dst` | `cp -r src dst` |
| 移動／リネーム | `mv src dst` | `mv src dst`（オプション不要） |
| 削除 | `rm file` | `rm -r dir`、空のみなら `rmdir dir` |

---

## Referencias

- LPI Learning Materials — 010-160, Topic 2.4: Creating, Moving and Deleting Files  
  https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- GNU Coreutils Manual — `touch`  
  https://www.gnu.org/software/coreutils/manual/html_node/touch-invocation.html
- GNU Coreutils Manual — `mkdir`  
  https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html
- GNU Coreutils Manual — `cp`  
  https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
- GNU Coreutils Manual — `mv`  
  https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html
- GNU Coreutils Manual — `rm`  
  https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html
- GNU Coreutils Manual — `rmdir`  
  https://www.gnu.org/software/coreutils/manual/html_node/rmdir-invocation.html
- GNU Findutils Manual — `find`  
  https://www.gnu.org/software/findutils/manual/html_node/find_html/index.html
- Bash Reference Manual — Filename Expansion (Pathname Expansion)  
  https://www.gnu.org/software/bash/manual/html_node/Filename-Expansion.html