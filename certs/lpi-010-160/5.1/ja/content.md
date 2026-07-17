# 5.1 Basic Security and Identifying User Types

## この項目について（Weight: 2）

Linux システムにおける security の基本は、「誰が」システムにアクセスできるか、そして「その人が何をできるか」を正しく制御することです。この項目では、Linux における user の種類（root、system user、regular user）と、それらを管理・切り替えるための基本的なコマンドおよび設定ファイルについて学びます。

---

## 1. root user（スーパーユーザー）

Linux には常に `root` という特別な user が存在します。`root` は UID（User ID）が `0` で、ファイルパーミッションやアクセス制御を無視してシステム上のあらゆる操作を実行できる、いわゆる superuser です。

- パッケージのインストール、システムファイルの変更、他 user のパスワードリセットなど、通常の user には許可されない操作が可能。
- 強力すぎるため、日常的な作業を `root` で直接行うことは推奨されません（誤操作やセキュリティリスクが大きい）。
- 実務では `sudo` を使って必要な時だけ一時的に権限を得るのが一般的な運用です。

これは **principle of least privilege**（最小権限の原則）と呼ばれる考え方で、「必要な権限だけを、必要な時だけ与える」ことでリスクを減らします。

---

## 2. User の種類

Linux 上の user は大きく3種類に分けられます。

| 種類 | 説明 | UID の目安 |
|---|---|---|
| root | すべての権限を持つ管理者 | 0 |
| system user | サービスやデーモンが使うための非対話的な account（例: `www-data`, `mysql`, `daemon`） | 1〜999 程度（distribution による） |
| regular user（normal user） | 人間が日常的にログインして使う account | 1000 以上（Debian/Ubuntu 系）または 500 以上（一部の RHEL 系） |

system user は人間が直接ログインする必要がないため、多くの場合 login shell が `/usr/sbin/nologin` や `/bin/false` に設定されており、対話的ログインができないようになっています。これにより、サービスが乗っ取られても攻撃者がその account で shell を得ることを防いでいます。

---

## 3. `/etc/passwd` の構造

user の基本情報は `/etc/passwd` に保存されています。誰でも読み取れるファイルです（パスワードのハッシュ自体はここには入っていません）。

```
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
alice:x:1000:1000:Alice Smith,,,:/home/alice:/bin/bash
```

各行は `:` で区切られた7つの field から成ります。

1. **username**: ログイン名
2. **password**: 通常は `x`。実際のハッシュは `/etc/shadow` に格納されている
3. **UID**: user ID（数値）
4. **GID**: primary group ID
5. **GECOS**: 氏名などのコメント情報
6. **home directory**: 例 `/home/alice`
7. **shell**: ログイン時に起動される shell（例 `/bin/bash`、無効化する場合は `/usr/sbin/nologin`）

---

## 4. `/etc/shadow` の構造

パスワードのハッシュや有効期限などの機密情報は `/etc/shadow` に格納され、root のみが読み取れます。

```
$ sudo cat /etc/shadow
alice:$6$rounds=656000$abcdefgh$hashhashhash...:19500:0:99999:7:::
```

field は次の通りです（`:` 区切り）。

1. username
2. password hash（暗号化されたパスワード。`!` や `*` はログイン不可を意味する）
3. 最終変更日（1970年1月1日からの日数）
4. 変更可能になるまでの最小日数
5. 変更が必須になるまでの最大日数
6. 期限切れ前の警告日数
7. 無効化までの猶予日数
8. account の失効日
9. 予約 field

---

## 5. `/etc/group` の構造

group の情報は `/etc/group` に保存されています。

```
$ cat /etc/group
sudo:x:27:alice
developers:x:1001:alice,bob
```

field は `group_name:password:GID:member_list` です。ここでの member_list はその group を **secondary group**（補助グループ）として持つ user の一覧です。primary group は `/etc/passwd` の GID field で決まります。

---

## 6. User 情報を確認するコマンド

### `id` — 自分または他 user の UID/GID を確認

```
$ id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo),1001(developers)
```

### `who` / `w` — 現在ログイン中の user を確認

```
$ who
alice    tty2         2026-07-10 09:15 (:0)

$ w
 09:20:01 up 2:05, 1 user, load average: 0.15, 0.10, 0.05
USER   TTY   FROM   LOGIN@   IDLE   JCPU   PCPU WHAT
alice  tty2  :0     09:15    2:05   0.30s  0.10s -bash
```

`w` は `who` の情報に加えて、各 session が何をしているか（`WHAT` 列）や load average も表示します。

---

## 7. `su` — user を切り替える

`su`（switch user）は別の user になりすます（あるいはその shell を得る）ためのコマンドです。

```
$ su - root
Password:
root@host:~#
```

- `su username` だけだと現在の環境変数を引き継ぎますが、`su - username`（ハイフン付き）は **login shell** として起動し、対象 user のホームディレクトリや環境変数を完全に読み込みます。
- 引数なしの `su` は `root` への切り替えを意味します。
- `root` 以外の一般 user から他の一般 user へ切り替える場合、原則としてその対象 user のパスワードが必要です（`root` から切り替える場合はパスワード不要）。

---

## 8. `sudo` — 権限を借りてコマンドを実行する

`sudo`（superuser do）は、許可された user が **自分自身のパスワード** を使って、一時的に他の user（通常は root）の権限でコマンドを実行できる仕組みです。

```
$ sudo apt update
[sudo] password for alice:
```

- 誰が `sudo` を使えるか、どのコマンドを実行できるかは `/etc/sudoers` で制御されます。編集には構文チェック付きの `visudo` コマンドを使うのが安全です。
- Debian/Ubuntu 系では `sudo` group、RHEL 系では `wheel` group に user を追加することで `sudo` 権限を与えるのが一般的です。
- `su` との違い: `su` は対象 account（多くの場合 root）のパスワードが必要で、いったん切り替わるとその後の操作がログに残りにくいのに対し、`sudo` は自分のパスワードで済み、実行したコマンドが `/var/log/auth.log`（Debian系）や `/var/log/secure`（RHEL系）に記録されるため監査（audit）がしやすいという利点があります。

---

## 9. `passwd` — パスワードの変更

```
$ passwd
Changing password for alice.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

root は他の user のパスワードも変更できます。

```
$ sudo passwd bob
New password:
Retype new password:
passwd: password updated successfully
```

---

## まとめ

- `root` は UID 0 を持つ superuser。日常作業は避け、`sudo` 経由で必要な時だけ権限を使うのが best practice。
- user は `root` / `system user` / `regular user` に大別され、system user は多くの場合ログイン不可に設定されている。
- account 情報は `/etc/passwd`（誰でも読める）と `/etc/shadow`（root のみ）に分かれて保存される。
- group 情報は `/etc/group` に保存され、`id` コマンドで自分の所属 group を確認できる。
- `su` は user を切り替える、`sudo` は自分の権限を一時的に昇格させてコマンドを実行する、という役割の違いを理解しておくこと。

---

## Referencias

- LPI Learning Materials — Topic 5.1 Basic Security and Identifying User Types: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- passwd(5) man page: https://man7.org/linux/man-pages/man5/passwd.5.html
- shadow(5) man page: https://man7.org/linux/man-pages/man5/shadow.5.html
- group(5) man page: https://man7.org/linux/man-pages/man5/group.5.html
- su(1) man page: https://man7.org/linux/man-pages/man1/su.1.html
- sudo(8) man page: https://man7.org/linux/man-pages/man8/sudo.8.html
- passwd(1) man page: https://man7.org/linux/man-pages/man1/passwd.1.html