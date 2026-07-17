# 5.2 Creating Users and Groups

## 概要

Linux はマルチユーザー OS であり、すべてのプロセスとファイルは特定の user と group に紐づいています。system administrator の基本業務の一つが、user account と group account の作成・変更・削除です。この章では `useradd`、`usermod`、`userdel`、`groupadd`、`groupmod`、`groupdel`、`passwd` といった主要なコマンドと、それらが操作する設定ファイル（`/etc/passwd`、`/etc/shadow`、`/etc/group`、`/etc/gshadow`）を扱います。

試験での重み(weight)は 2 と比較的軽めですが、実務では最も頻繁に使うコマンド群なので、オプションと出力形式を正確に押さえておくことが重要です。

---

## user account を管理するファイル

### `/etc/passwd`

すべての user account の基本情報を保持するファイルです。各行が 1 user を表し、コロン `:` で 7 つのフィールドに分かれています。

```bash
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1001:1001:Alice Smith:/home/alice:/bin/bash
```

フィールドの意味（左から順）:

| 順番 | フィールド名        | 説明                                      |
|------|---------------------|-------------------------------------------|
| 1    | username             | login 名                                  |
| 2    | password placeholder | 通常 `x`。実際の password hash は `/etc/shadow` にある |
| 3    | UID                  | user ID（数値）                           |
| 4    | GID                  | primary group ID（数値）                  |
| 5    | GECOS                | comment field（本名など任意情報）         |
| 6    | home directory       | login 後の初期 directory                  |
| 7    | login shell          | login 時に起動される shell                |

`/etc/passwd` は誰でも読み取り可能（world-readable）ですが、password hash 自体はここには含まれません。かつては password hash が直接このファイルに保存されていましたが、セキュリティ上の理由から `/etc/shadow` に分離されました（shadow password 方式）。

### `/etc/shadow`

password hash と有効期限に関する情報を保持し、root 以外は読み取れません（パーミッションは通常 `640` または `600`）。

```bash
$ sudo cat /etc/shadow
alice:$6$abcd1234$hash....:19500:0:99999:7:::
```

フィールド（コロン区切り、9 個）:

1. username
2. 暗号化された password hash（`$6$` は SHA-512 を意味する）
3. 最終変更日（1970-01-01 からの日数）
4. 変更可能になるまでの最小日数
5. 変更が必須になるまでの最大日数
6. 変更を促す警告日数
7. 無効化までの猶予日数
8. account が無効化される日（絶対値）
9. 予約フィールド

### `/etc/group`

group 情報を保持します。

```bash
$ cat /etc/group
root:x:0:
sudo:x:27:alice
developers:x:1002:alice,bob
```

フィールド:

1. group name
2. password placeholder（`x`。通常は使われない）
3. GID
4. member list（secondary member として所属する user のカンマ区切りリスト。primary group として所属する user はここには現れない）

### `/etc/gshadow`

group の password 情報や group administrator を保持する、`/etc/group` に対応する shadow file です。root のみ読み取り可能で、通常の運用ではほとんど直接編集しません。

---

## user account の作成: `useradd`

```bash
$ sudo useradd -m -s /bin/bash -c "Alice Smith" -G sudo,developers alice
```

主なオプション:

| オプション | 意味                                          |
|------------|-----------------------------------------------|
| `-m`       | home directory を作成する（`/etc/skel` の内容をコピー） |
| `-d`       | home directory の path を指定                 |
| `-s`       | login shell を指定                            |
| `-c`       | GECOS（comment field）を指定                  |
| `-u`       | UID を指定                                    |
| `-g`       | primary group を指定（名前または GID）        |
| `-G`       | secondary group を指定（複数はカンマ区切り）  |
| `-e`       | account の有効期限（`YYYY-MM-DD`）            |

distribution によっては `useradd` にデフォルトで `-m` が有効になっていない場合があるため（Debian 系は無効、RHEL 系は有効）、home directory が必要な場合は明示的に `-m` を指定するのが安全です。

作成後の確認:

```bash
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),27(sudo),1002(developers)
```

`useradd` はデフォルトで user と同名の primary group（UPG: User Private Group）を新規作成する distribution が多いです（Debian/Ubuntu の標準動作）。

---

## user account の変更: `usermod`

既存 account の属性を変更するコマンドです。

```bash
# secondary group を追加（既存の所属を維持したまま追加する場合は -a が必須）
$ sudo usermod -aG developers bob

# login shell を変更
$ sudo usermod -s /bin/zsh alice

# home directory を変更し、中身も移動
$ sudo usermod -d /home/alice_new -m alice

# account を一時的にロック（passwd の先頭に ! を付与）
$ sudo usermod -L alice

# ロック解除
$ sudo usermod -U alice
```

`-G` のみを指定して `-a` を付け忘れると、既存の secondary group がすべて上書き（削除）されてしまう点は頻出の注意点です。

---

## user account の削除: `userdel`

```bash
# account のみ削除（home directory は残る）
$ sudo userdel alice

# home directory と mail spool も削除
$ sudo userdel -r alice
```

---

## password の管理: `passwd`

```bash
# 自分自身の password を変更
$ passwd

# root が他 user の password を設定
$ sudo passwd alice

# account を lock/unlock
$ sudo passwd -l alice
$ sudo passwd -u alice

# password の有効期限をすぐに切らせ、次回 login 時に変更を強制
$ sudo passwd -e alice

# 現在の password 状態を確認
$ sudo passwd -S alice
alice L 07/16/2026 0 99999 7 -1
```

`passwd -S` の出力の 2 文字目は状態を表します：`P`（usable password）、`L`（locked）、`NP`（no password）。

---

## group account の管理

### `groupadd`

```bash
$ sudo groupadd developers
$ sudo groupadd -g 2000 qa       # GID を明示的に指定
```

### `groupmod`

```bash
$ sudo groupmod -n devops developers   # group name を変更
$ sudo groupmod -g 2100 devops         # GID を変更
```

### `groupdel`

```bash
$ sudo groupdel devops
```

注意点として、削除しようとする group が何らかの user の **primary group** になっている場合、`groupdel` は失敗します。事前に対象 user の primary group を変更する必要があります。

---

## user と group の関係を確認する

```bash
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),27(sudo)

$ groups alice
alice : alice sudo

$ getent passwd alice
alice:x:1001:1001:Alice Smith:/home/alice:/bin/bash
```

`getent` は NSS(Name Service Switch) 経由で情報を取得するため、local file だけでなく LDAP 等のバックエンドを使う環境でも正しい情報を返します。

---

## 実践例: 新規プロジェクト向け user/group のセットアップ

```bash
# 1. project 用の group を作成
$ sudo groupadd project-x

# 2. 新規 user を作成し、home directory を作り、secondary group に project-x を追加
$ sudo useradd -m -s /bin/bash -G project-x carol

# 3. password を設定
$ sudo passwd carol
New password:
Retype new password:
passwd: password updated successfully

# 4. 設定の確認
$ id carol
uid=1002(carol) gid=1002(carol) groups=1002(carol),2001(project-x)
```

---

## Referencias

- LPI Learning Materials — 5.2 Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- `useradd(8)` man page: https://man7.org/linux/man-pages/man8/useradd.8.html
- `usermod(8)` man page: https://man7.org/linux/man-pages/man8/usermod.8.html
- `userdel(8)` man page: https://man7.org/linux/man-pages/man8/userdel.8.html
- `groupadd(8)` man page: https://man7.org/linux/man-pages/man8/groupadd.8.html
- `passwd(1)` man page: https://man7.org/linux/man-pages/man1/passwd.1.html
- `passwd(5)` file format: https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` file format: https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` file format: https://man7.org/linux/man-pages/man5/group.5.html