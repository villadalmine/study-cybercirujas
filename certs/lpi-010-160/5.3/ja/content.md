# 5.3 Managing File Permissions and Ownership

## 概要

Linuxのファイルシステムでは、すべてのファイルとディレクトリに **owner（所有者）**、**group（所有グループ）**、そして三種類の権限（**read**, **write**, **execute**）が設定されています。これらはマルチユーザー環境でセキュリティを担保する基本メカニズムであり、LPI Linux Essentials（010-160 v1.6）の中でも実務的に重要なトピックです。

## パーミッションの三つのカテゴリ

各ファイル・ディレクトリには、権限を適用する対象として三つのカテゴリがあります。

| カテゴリ | 意味 |
|---|---|
| `user` (`u`) | ファイルの owner |
| `group` (`g`) | ファイルに紐づく group のメンバー |
| `other` (`o`) | それ以外の全ユーザー |
| `all` (`a`) | 上記すべて（`u`+`g`+`o`） |

## パーミッションの三つの権限

| 権限 | 記号 | ファイルへの意味 | ディレクトリへの意味 |
|---|---|---|---|
| read | `r` | ファイル内容を読める | `ls` でディレクトリの中身を一覧できる |
| write | `w` | ファイル内容を変更・削除できる | ディレクトリ内でファイルの作成・削除・rename ができる |
| execute | `x` | プログラムとして実行できる | `cd` でディレクトリに入れる（=通過できる） |

ディレクトリの `execute` は「一覧表示」ではなく「そのディレクトリを経由してアクセスできるか」を意味する点に注意してください。`r` だけあって `x` がないディレクトリは、中のファイル名は見えても、その中のファイル自体にはアクセスできません。

## `ls -l` によるパーミッションの確認

```bash
$ ls -l /etc/passwd
-rw-r--r-- 1 root root 2210  6月 12 09:15 /etc/passwd
```

先頭10文字が意味を持ちます。

```
- rw- r-- r--
| |   |   |
| |   |   +-- other: read
| |   +------ group: read
| +---------- user: read, write
+------------ ファイルタイプ (- はファイル, d はディレクトリ, l はシンボリックリンク)
```

ディレクトリの例：

```bash
$ ls -ld /home/carol
drwxr-x--- 2 carol carol 4096  6月 10 18:02 /home/carol
```

- `d` : ディレクトリ
- `rwx` : owner (carol) は読み書き実行すべて可能
- `r-x` : group はディレクトリの一覧表示と `cd` は可能だが、ファイル作成・削除は不可
- `---` : other は一切アクセス不可

## 数値（octal）表記

`r`, `w`, `x` はそれぞれ2進数のビットとして扱われ、8進数1桁で表現できます。

| 権限 | 値 |
|---|---|
| `r` | 4 |
| `w` | 2 |
| `x` | 1 |

これを user / group / other ごとに合計し、3桁の数字にします。

```
rwxr-xr-- → 7 5 4 → 754
```

代表的な組み合わせ：

| 数値 | 記号 | 用途の例 |
|---|---|---|
| `755` | `rwxr-xr-x` | 実行可能スクリプト、公開ディレクトリ |
| `644` | `rw-r--r--` | 一般的な設定ファイル |
| `600` | `rw-------` | 秘密鍵など owner のみアクセス |
| `700` | `rwx------` | 個人用ディレクトリ |

## `chmod` — パーミッションの変更

`chmod` (change mode) には **数値モード** と **シンボリックモード** の2種類の指定方法があります。

### 数値モードの例

```bash
$ chmod 644 report.txt
$ ls -l report.txt
-rw-r--r-- 1 alice alice 1024  6月 12 10:00 report.txt
```

### シンボリックモードの例

シンボリックモードは `[ugoa][+-=][rwx]` の形式で、既存の権限に対する**相対的な変更**が可能です（数値モードは常に絶対指定）。

```bash
$ chmod u+x script.sh        # owner に execute を追加
$ chmod go-w file.txt        # group と other から write を削除
$ chmod a=r public.txt       # 全員を read のみに設定
$ chmod g=u secret.cfg       # group の権限を user と同じにする
```

再帰的にディレクトリ以下すべてへ適用する場合は `-R` を使います。

```bash
$ chmod -R 750 /srv/webapp
```

## 所有者・所有グループの変更

### `chown` — owner（と group）の変更

```bash
$ chown bob file.txt              # owner を bob に変更
$ chown bob:developers file.txt   # owner を bob、group を developers に変更
$ chown :developers file.txt      # group のみ変更（chgrp と同等）
$ chown -R bob:developers /srv/app   # 再帰的に変更
```

`chown` の実行には通常 **root権限（superuser）** が必要です。一般ユーザーは自分が owner のファイルであっても、他人に所有権を譲渡することはできません。

### `chgrp` — group のみの変更

```bash
$ chgrp developers file.txt
$ ls -l file.txt
-rw-r--r-- 1 bob developers 1024  6月 12 10:05 file.txt
```

`chgrp` は、変更先の group に自分が所属していれば一般ユーザーでも実行できます（`root` は無条件に可能）。

## `umask` — デフォルト権限の制御

新規作成されるファイル・ディレクトリの権限は、システムの最大デフォルト値から `umask` の値を差し引く形で決まります。

- ファイルの最大デフォルト: `666` (`rw-rw-rw-`、通常 `x` は自動付与されない)
- ディレクトリの最大デフォルト: `777` (`rwxrwxrwx`)

```bash
$ umask
0022
$ touch newfile.txt
$ ls -l newfile.txt
-rw-r--r-- 1 alice alice 0  6月 12 10:10 newfile.txt   # 666 - 022 = 644

$ mkdir newdir
$ ls -ld newdir
drwxr-xr-x 2 alice alice 4096  6月 12 10:10 newdir       # 777 - 022 = 755
```

`umask` はセッション内でのみ有効な設定で、シェルの起動スクリプト（`~/.bashrc` や `/etc/profile` など）で恒久的に設定するのが一般的です。

```bash
$ umask 077        # 以降、自分以外は一切アクセスできないファイルを作成
```

## 補足：特殊なパーミッションビット

`ls -l` の execute 位置に `s` や `t` が現れることがあります。Linux Essentials レベルでは深入りは不要ですが、意味だけ押さえておくと安全です。

```bash
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208  ...  /usr/bin/passwd
```

- **SUID** (`s`, user位置): 実行時に owner の権限で動作する（例: `passwd` が root権限で `/etc/shadow` を書き換える）
- **SGID** (`s`, group位置): ディレクトリに設定されると、その中で作成されたファイルは親ディレクトリと同じ group を継承する
- **Sticky bit** (`t`, other位置): 共有ディレクトリ（例: `/tmp`）で、自分が owner のファイルしか削除できないよう制限する

```bash
$ ls -ld /tmp
drwxrwxrwt 10 root root 4096  6月 12 08:00 /tmp
```

## よくあるコマンドまとめ

| コマンド | 用途 |
|---|---|
| `ls -l` / `ls -ld` | ファイル・ディレクトリの権限を確認 |
| `chmod [数値 \| シンボリック] ファイル` | 権限を変更 |
| `chown user:group ファイル` | owner / group を変更 |
| `chgrp group ファイル` | group のみ変更 |
| `umask` | 新規作成物のデフォルト権限を確認・設定 |

## Referencias

- LPI Learning Materials — 010-160, Topic 5.3: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- LPI Linux Essentials Exam Objectives (010-160): https://www.lpi.org/our-certifications/exam-010-objectives