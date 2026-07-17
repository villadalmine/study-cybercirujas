# 5.2 Creating Users and Groups

**Exam weight: 2** — Linux Essentials 010-160, version 1.6

## なぜ user と group の管理を理解する必要があるのか

Linux はマルチユーザー OS であり、1台のマシンを複数の人間、そして多数のサービス（daemon）が同時に利用します。実行中のあらゆるプロセスは必ず「ある user」として動作しており、その user は必ず1つ以上の group に所属しています。誰がどのファイルにアクセスできるか、どのコマンドを実行できるかという権限管理（Topic 5 の他のセクションで扱うパーミッション）は、すべてこの user/group の仕組みの上に成り立っています。したがって account をどう作成し、どこにどんな情報として保存されるかを理解することが、Linux 管理の出発点になります。

## account の種類

Linux の account は大きく3種類に分類されます。

| 種類 | 典型的な UID の範囲 | 用途 |
|---|---|---|
| **root**（superuser） | 0 | システム全体に対する無制限の管理権限を持つ |
| **system account** | 1〜999 | daemon やサービス用（例: `sshd`, `www-data`）。通常は対話的な login ができない |
| **regular user** | 1000以上 | home directory と login shell を持つ、人間が使う account |

- 各 user には数値の **UID**（User ID）が割り当てられており、user 名はあくまで人間向けのラベルで、kernel 内部は UID の数値だけで動作を管理しています。
- 各 group にも同様に数値の **GID**（Group ID）があります。
- user は必ず1つの **primary group** を持ち（account 作成時に決まる）、さらに任意の数の **supplementary group** に所属できます。supplementary group は追加の権限を付与するのに使われ、たとえば管理者権限を得るために `sudo` や `wheel` group に加える、といった運用がよく行われます。

regular user が始まる UID の境界値はディストリビューションによって差があります（古いシステムでは500からのこともあります）が、現在の主要ディストリビューションでは 1000 が一般的です。この値は `/etc/login.defs` の `UID_MIN` で定義されています。

## 自分が誰であるかを確認する

`id` コマンドは、現在の user の UID、primary GID、そして所属するすべての group を表示します。

```
$ id
uid=1000(carol) gid=1000(carol) groups=1000(carol),27(sudo),998(docker)
```

他の account を指定して調べることも可能です: `id emma`。

試験でよく問われる関連コマンド:

- `who` — 現在 login している user の一覧を表示する。
- `w` — `who` と似ているが、各セッションが何を実行しているか、load average なども合わせて表示する。
- `last` — `/var/log/wtmp` を読み取り、login と reboot の履歴を表示する:

```
$ last -n 3
carol    pts/0        192.168.1.20     Mon Jul  6 09:12   still logged in
emma     tty2         :0               Sun Jul  5 18:40 - 19:55  (01:15)
reboot   system boot  5.15.0-91        Sun Jul  5 18:38   still running
```

## account 情報はどこに保存されているか

### /etc/passwd

1行に1 user、コロン区切りの7つのフィールドで構成されます。名前とは裏腹に、現在このファイルには実際の password は保存されていません。

```
$ grep carol /etc/passwd
carol:x:1000:1000:Carol Jones:/home/carol:/bin/bash
```

左から順にフィールドの意味は次のとおりです。

1. **username** — `carol`
2. **password のプレースホルダー** — `x` は実際の password hash が `/etc/shadow` にあることを示す
3. **UID** — `1000`
4. **primary group の GID** — `1000`
5. **GECOS** — 自由記述のコメント欄。通常はフルネームが入る
6. **home directory** — `/home/carol`
7. **login shell** — `/bin/bash`（system account では login を禁止するために `/usr/sbin/nologin` や `/bin/false` が使われることが多い）

`/etc/passwd` は誰でも読める（world-readable）ファイルです。これはまさに password hash がこのファイルから `/etc/shadow` に分離された理由でもあります。

### /etc/shadow

password の hash と、password の有効期限に関するポリシーを保持します。root のみが読み取り可能です。

```
$ sudo grep carol /etc/shadow
carol:$6$W3q9...hashed...:20456:0:99999:7:::
```

主なフィールドは、username、password hash、最終変更日（1970-01-01 からの経過日数）、最小/最大有効日数、warning 期間などです。hash フィールドが `!` や `*` の場合、その account は password による login ができないことを意味します（ロックされているか、system account であることが多い）。

### /etc/group

1行に1 group、4つのフィールド（group 名、password のプレースホルダー、GID、member のカンマ区切りリスト）で構成されます。ここに列挙される member は supplementary membership であり、primary group は `/etc/passwd` 側に記録されている点に注意してください。

```
$ grep sudo /etc/group
sudo:x:27:carol,emma
```

これらのデータベースは `getent` コマンドでも参照できます。`getent` は LDAP など、ネットワーク経由の directory service に account 情報がある場合にも同様に機能する、より汎用的な方法です。

```
$ getent passwd carol
carol:x:1000:1000:Carol Jones:/home/carol:/bin/bash
```

## user の作成: useradd

account 管理には root 権限が必要なので、以下のコマンドはすべて `sudo` を付けて実行します。低レベルで、どのディストリビューションでも利用できる標準ツールが `useradd` です。

```
$ sudo useradd -m -c "Dave Lee" -s /bin/bash dave
```

よく使われるオプション:

- `-m` — home directory を作成する（`/etc/skel` にある skeleton files、例えばデフォルトの `.bashrc` などがコピーされる）
- `-c` — comment（GECOS フィールド。通常はフルネーム）
- `-s` — login shell
- `-d` — デフォルト以外の home directory を指定する
- `-g` — primary group を指定、`-G` — カンマ区切りで supplementary group を指定
- `-u` — 特定の UID を指定する

作成直後の account はまだ有効な password を持たないため、`passwd` コマンドで設定します。

```
$ sudo passwd dave
New password:
Retype new password:
passwd: password updated successfully
```

一般 user は引数なしで `passwd` を実行すると自分自身の password を変更できます。他人の password を変更できるのは root だけです。

作成結果を確認します。

```
$ id dave
uid=1001(dave) gid=1001(dave) groups=1001(dave)
$ ls /home
carol  dave
```

Debian 系のディストリビューションでは `adduser` という、対話形式で password などをまとめて聞いてくれる `useradd` のフレンドリーなフロントエンドも用意されています。ただし試験対策としては `useradd` が標準ツールであることを押さえておいてください。

## group の作成: groupadd

```
$ sudo groupadd developers
$ grep developers /etc/group
developers:x:1002:
```

`-g` オプションで特定の GID を指定できます。既存の user をこの group に supplementary member として追加するには `usermod -aG` を使います。

```
$ sudo usermod -aG developers dave
$ id dave
uid=1001(dave) gid=1001(dave) groups=1001(dave),1002(developers)
```

**注意:** `-a`（append）フラグの有無が重要です。`usermod -G developers dave` は Dave の supplementary group をすべて `developers` だけに**置き換えて**しまいます。既存の membership を保持したまま追加するには必ず `-aG` を使ってください。また、新しい group membership が反映されるには、一度 logout して再度 login する必要があります。

## account の変更と削除

- `usermod` — 既存 account を変更する: `-s` で shell 変更、`-d`（`-m` 併用でファイルも移動）で home directory 変更、`-L`/`-U` で account の lock/unlock。
- `userdel dave` — account を削除する。`-r` を付けると home directory と mail spool も同時に削除される。
- `groupmod` — group 名の変更（`-n`）や GID の変更（`-g`）。
- `groupdel developers` — group を削除する（その group が誰かの primary group になっていない場合に限る）。

```
$ sudo userdel -r dave
$ sudo groupdel developers
```

## Key takeaways

- root の UID は 0。system account は regular user より低い UID 範囲に置かれ、regular user は通常 UID 1000 から始まる。
- user は `/etc/passwd` に、password hash は `/etc/shadow`（root のみ読み取り可）に、group は `/etc/group` に定義される。
- `useradd -m` で home directory 付きの user を作成し、`passwd` で password を設定し、`groupadd` で group を作成し、`usermod -aG` で supplementary group への追加を行う。
- `id`、`who`、`w`、`last` は、自分自身や他の user の login 状況を確認するためのコマンドである。

## Referencias

- LPI Learning Materials, Linux Essentials 5.2 — Creating Users and Groups: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- LPI Linux Essentials exam objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- `useradd(8)` man page: https://man7.org/linux/man-pages/man8/useradd.8.html
- `groupadd(8)` man page: https://man7.org/linux/man-pages/man8/groupadd.8.html
- `usermod(8)` man page: https://man7.org/linux/man-pages/man8/usermod.8.html
- `passwd(5)` man page (format of /etc/passwd): https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` man page (format of /etc/shadow): https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` man page (format of /etc/group): https://man7.org/linux/man-pages/man5/group.5.html
