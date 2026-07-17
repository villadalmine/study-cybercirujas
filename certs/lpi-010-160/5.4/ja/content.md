# Topic 5.4: Special Directories and Files

## 概要

Linux のセキュリティモデルは、通常の read / write / execute パーミッションだけでは表現できない挙動を扱うために、いくつかの **special permissions**（特殊パーミッション）と、ファイルシステム上でファイルを共有・参照するための **links**（リンク）の仕組みを持っています。この節では、`SUID`・`SGID`・`sticky bit` という3つの特殊パーミッション、`hard link` と `symbolic link` の違い、そして `/etc/passwd`・`/etc/shadow`・`/etc/group` といったユーザー管理に関わる重要なシステムファイルの構造を扱います。

## Links: hard link と symbolic link

Linux では1つの実データ（inode）に対して複数の名前（ディレクトリエントリ）を割り当てることができます。これを **hard link** と呼びます。一方で、他のファイルへの「参照」だけを保持する特殊なファイルを **symbolic link**（symlink）と呼びます。

### inode の確認

```bash
$ ls -li /etc/hostname
131074 -rw-r--r-- 1 root root 12 Jul 10 09:00 /etc/hostname
```

`ls -li` の先頭列が **inode number** です。同じ inode number を持つファイルは実体が同じであることを意味します。

### hard link の作成

```bash
$ ln /etc/hostname /tmp/hostname-hardlink
$ ls -li /etc/hostname /tmp/hostname-hardlink
131074 -rw-r--r-- 2 root root 12 Jul 10 09:00 /etc/hostname
131074 -rw-r--r-- 2 root root 12 Jul 10 09:00 /tmp/hostname-hardlink
```

- 両者は同じ inode number（`131074`）を共有しており、リンクカウント（`ls -l` 出力の3列目、ここでは `2`）が増加します。
- 片方を編集すればもう片方にも変更が反映されます。片方を削除しても inode 自体はリンクカウントが 0 になるまで残るため、もう片方は影響を受けません。
- hard link は**同一ファイルシステム内**でのみ作成でき、ディレクトリに対しては（通常）作成できません。

### symbolic link の作成

```bash
$ ln -s /etc/hostname /tmp/hostname-symlink
$ ls -li /etc/hostname /tmp/hostname-symlink
131074 -rw-r--r-- 1 root root 12 Jul 10 09:00 /etc/hostname
131099 lrwxrwxrwx 1 root root 13 Jul 10 09:05 /tmp/hostname-symlink -> /etc/hostname
```

- symlink は独自の inode（`131099`）を持ち、パーミッション欄の先頭が `l` になります。
- 指し示す先（target）のパスをデータとして保持しているだけなので、異なるファイルシステムやマウントポイントをまたいで作成できます。
- ターゲットが削除されると symlink は無効な状態（**broken link** / **dangling link**）になり、`ls -l` では赤色で表示されることがあります。

### hard link と symbolic link の比較

| 特徴 | hard link | symbolic link |
|---|---|---|
| inode | ターゲットと共有 | 独自 |
| ファイルシステムをまたぐ | 不可 | 可能 |
| ディレクトリへのリンク | 通常不可 | 可能 |
| ターゲット削除後の状態 | 影響なし | broken link |
| 作成コマンド | `ln target linkname` | `ln -s target linkname` |

## 特殊パーミッション（SUID / SGID / Sticky Bit）

通常の `rwx` に加え、実行時の挙動やディレクトリの共有方法を制御する3種類の特殊ビットがあります。

### SUID（Set User ID）

実行可能ファイルに設定すると、実行時のプロセスの実効ユーザー（effective UID）が、実行したユーザーではなく**ファイルの所有者**になります。パスワード変更のように、一般ユーザーが一時的に root 権限を必要とする処理で使われます。

```bash
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar  1 2024 /usr/bin/passwd
```

所有者の実行ビットが `s` になっている点に注目してください。設定方法は次の通りです。

```bash
$ chmod u+s program
$ chmod 4755 program   # 先頭の "4" が SUID
```

### SGID（Set Group ID）

- **ファイル**に設定すると、実行時の実効グループがファイルの所有グループになります。
- **ディレクトリ**に設定すると、そのディレクトリ内に新規作成されたファイル／サブディレクトリが、作成者の所属グループではなく**親ディレクトリの所有グループ**を自動的に継承します。共同作業用ディレクトリでよく使われます。

```bash
$ mkdir /srv/shared
$ chgrp devteam /srv/shared
$ chmod g+s /srv/shared
$ ls -ld /srv/shared
drwxr-sr-x 2 root devteam 4096 Jul 10 10:00 /srv/shared
```

グループの実行ビットが `s` になっています。数値表記では `chmod 2775 /srv/shared` のように先頭が `2` になります。

### Sticky Bit

主にディレクトリに設定され、そのディレクトリ内のファイルを**所有者・root・ディレクトリ所有者以外は削除・rename できない**ようにします。`/tmp` のように全ユーザーが書き込めるが、他人のファイルを消されては困るディレクトリで使われます。

```bash
$ ls -ld /tmp
drwxrwxrwt 13 root root 4096 Jul 10 10:00 /tmp
```

他者の実行ビットが `t`（既に実行権がある場合）または `T`（実行権がない場合）になります。設定方法：

```bash
$ chmod +t /srv/dropbox
$ chmod 1777 /srv/dropbox   # 先頭の "1" が sticky bit
```

### `ls -l` 出力における特殊ビットのまとめ

| 表示位置 | 意味 | 実行権あり | 実行権なし |
|---|---|---|---|
| 所有者の x 位置 | SUID | `s` | `S` |
| グループの x 位置 | SGID | `s` | `S` |
| その他の x 位置 | Sticky bit | `t` | `T` |

`chmod` の4桁の数値表記では、先頭の桁が特殊ビットを表します：`4`=SUID、`2`=SGID、`1`=sticky bit（例：`chmod 6755` は SUID + SGID）。

### find による特殊パーミッションの検索

セキュリティ監査でよく使うコマンドです。

```bash
$ find / -perm -4000 -type f 2>/dev/null
/usr/bin/passwd
/usr/bin/sudo
/usr/bin/su
```

## 重要なシステムファイル

### `/etc/passwd`

全ユーザーアカウントの情報を保持します。誰でも read 可能ですが、write は root のみです。

```bash
$ grep alice /etc/passwd
alice:x:1001:1001:Alice Smith,,,:/home/alice:/bin/bash
```

コロン区切りのフィールドは順に：`username` : `password placeholder（"x"）` : `UID` : `GID` : `GECOS（コメント）` : `home directory` : `login shell` です。

### `/etc/shadow`

実際のパスワードハッシュとパスワードの有効期限情報を保持します。read も write も root のみに許可される、より機密性の高いファイルです。

```bash
$ sudo grep alice /etc/shadow
alice:$6$abcd...:19700:0:99999:7:::
```

フィールドは `username` : `hashed password` : `最終変更日（1970-01-01からの日数）` : `最小変更間隔` : `最大有効日数` : `警告日数` : `猶予期間` : `無効化日` : `予約` です。

### `/etc/group`

グループとそのメンバーを定義します。

```bash
$ grep devteam /etc/group
devteam:x:1010:alice,bob
```

フィールドは `group name` : `password placeholder` : `GID` : `member list（カンマ区切り）` です。

## 重要な特殊ディレクトリ

| ディレクトリ | 用途 |
|---|---|
| `/tmp` | 全ユーザーが書き込み可能な一時ファイル置き場。sticky bit が設定されており、再起動で消去されることが多い |
| `/var/tmp` | `/tmp` と同様だが、再起動をまたいで保持されることが多い一時領域 |
| `/var/log` | システムおよびアプリケーションのログファイル |
| `/etc` | システム全体の設定ファイル |
| `/dev` | デバイスファイル（device files） |

## 参考例：確認コマンドまとめ

```bash
$ stat /etc/shadow
$ ls -l /etc/passwd /etc/shadow /etc/group
$ find /usr/bin -perm -2000 -type f   # SGID が設定された実行ファイルを検索
$ ls -ld /tmp                         # sticky bit の確認
```

## Referencias

- LPI Learning Materials — 5.4 Special Directories and Files: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- LPI Linux Essentials Exam Objectives (010-160), v1.6: https://www.lpi.org/our-certifications/exam-160-objectives
- GNU Coreutils Manual — `ln`, `chmod`: https://www.gnu.org/software/coreutils/manual/html_node/index.html
- Linux man-pages — `passwd(5)`, `shadow(5)`, `group(5)`: https://man7.org/linux/man-pages/