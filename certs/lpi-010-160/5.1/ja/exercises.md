# LPI Linux Essentials (010-160 v1.6) — Topic 5.1: Basic Security and Identifying User Types 演習

> 参考: [LPI Learning Materials — 010-160 / 5.1](https://learning.lpi.org/en/learning-materials/010-160/5/5.1/)（本コンテンツは同ページの構成を参考にしていますが、文章はすべてオリジナルです）

---

## 演習1: `/etc/passwd` を読んでユーザーの種類を見分ける

1. ターミナルを開き、次のコマンドで `/etc/passwd` の先頭20行を表示します。

   ```bash
   head -n 20 /etc/passwd
   ```

2. `root` のエントリを見つけて、コロン区切りの各フィールドを確認します。

   ```
   root:x:0:0:root:/root:/bin/bash
   ```

   フィールドの並びは `username:password:UID:GID:GECOS:home_directory:shell` です。

3. `UID` が 1〜999 程度の行（多くのディストリビューションでは system user 用のレンジ）を1つ探します。`daemon`、`bin`、`sys` のような名前が典型例です。

4. 自分の通常ユーザーのエントリを探し、`UID` が 1000 以降（distro によって異なる）になっていることを確認します。

   ```bash
   grep "^$(whoami):" /etc/passwd
   ```

**確認問題**
- `/etc/passwd` のパスワードフィールドが `x` になっているのはなぜですか。
- `root`（superuser）、system user、regular user はそれぞれ何によって区別されますか。
- system user の shell がしばしば `/usr/sbin/nologin` に設定されているのはなぜですか。

---

## 演習2: shadow passwords の仕組みを確認する

1. root 権限で `/etc/shadow` の先頭5行を表示します。

   ```bash
   sudo head -n 5 /etc/shadow
   ```

2. 同じユーザー名で `/etc/passwd` と `/etc/shadow` を見比べ、パスワードハッシュがどちらのファイルに格納されているか確認します。

3. `/etc/shadow` の1行のフィールド構造を確認します。

   ```
   username:password_hash:last_change:min:max:warn:inactive:expire:reserved
   ```

4. `/etc/shadow` のパーミッションと所有者を確認します。

   ```bash
   ls -l /etc/shadow
   ```

**確認問題**
- パスワードハッシュを `/etc/passwd` ではなく `/etc/shadow` に分離して保存する目的は何ですか。
- `ls -l /etc/shadow` で見えるパーミッション（例: `640`）と所有グループが、この設計にどう寄与していますか。
- ハッシュ文字列の先頭にある `$6$` のような識別子は何を表していますか。

---

## 演習3: `/etc/group` とグループメンバーシップ

1. `/etc/group` の先頭を表示します。

   ```bash
   head -n 15 /etc/group
   ```

2. 現在のユーザーの UID・GID・所属グループ一覧を確認します。

   ```bash
   id
   ```

3. 所属しているグループ名だけを一覧表示します。

   ```bash
   groups
   ```

4. `/etc/passwd` に記載された自分の GID が、`/etc/group` のどのグループに対応するか確認します。

**確認問題**
- `/etc/passwd` に記録される primary group と、`id`/`groups` で見える supplementary group の違いは何ですか。
- `wheel` や `sudo` といったグループは、どのような security の目的で使われますか。

---

## 演習4: `su` と `sudo` の権限モデルを比較する

1. `su` で root に切り替え（root のパスワードが必要）、すぐに終了します。

   ```bash
   su -
   whoami
   exit
   ```

2. `sudo` で同じコマンドを実行します（自分のパスワードが必要）。

   ```bash
   sudo whoami
   ```

3. 自分に許可されている sudo コマンドの一覧を確認します。

   ```bash
   sudo -l
   ```

**確認問題**
- `su` はどのアカウントのパスワードを要求し、`sudo` はどのアカウントのパスワードを要求しますか。
- audit（監査）の観点から、`sudo` が `su` より安全とされる理由は何ですか。

---

## 演習5: `chage` によるパスワードエージングの管理

1. 自分自身のパスワードエージング情報を表示します。

   ```bash
   sudo chage -l "$(whoami)"
   ```

2. テスト用に、パスワードの最大有効日数を90日に設定します。

   ```bash
   sudo chage -M 90 "$(whoami)"
   ```

3. 変更が反映されたか再確認します。

   ```bash
   sudo chage -l "$(whoami)"
   ```

**確認問題**
- パスワードの有効期限（password expiration）を設定する security 上の目的は何ですか。
- `chage -l` の出力に含まれる項目のうち、`/etc/shadow` のどのフィールドと対応していますか。

---

## 演習6: Principle of Least Privilege に基づく system account の作成

1. ログイン不可の service account を作成します。

   ```bash
   sudo useradd -r -s /usr/sbin/nologin svc_backup
   ```

2. 作成されたエントリを確認します。

   ```bash
   grep svc_backup /etc/passwd
   ```

3. パスワードをロックして、対話的ログインを二重に防止します。

   ```bash
   sudo passwd -l svc_backup
   ```

4. 演習が終わったら後片付けとしてアカウントを削除します。

   ```bash
   sudo userdel svc_backup
   ```

**確認問題**
- service account に `/usr/sbin/nologin` を割り当てる理由は何ですか。
- パスワードが不要なはずの system account に対して、あえて `passwd -l` でロックをかけるのはなぜですか。

---

<details>
<summary>解答（クリックして展開）</summary>

**演習1**
- `x` は、実際のパスワードハッシュが `/etc/passwd` には保存されておらず、`/etc/shadow` に格納されていることを示すプレースホルダーです。
- `root` は UID `0` によって区別され、常に最上位の権限（superuser）を持ちます。system user は多くの distro で UID が 1〜999（または 1〜99）の範囲にあり、デーモンやサービス用に予約されています。regular user は distro のデフォルト設定（多くは 1000 以降）から始まる UID を持ちます。
- system user はサービスを実行するためだけのアカウントであり、対話的なログインを想定していません。`/usr/sbin/nologin` を設定することで、そのアカウントで誰かがログインシェルを得ることを防ぎ、attack surface を減らします。

**演習2**
- `/etc/passwd` はすべてのユーザーが読み取り可能なファイルです。ハッシュをそこに置くと、誰でもハッシュを取得してオフラインの brute-force 攻撃に利用できてしまいます。`/etc/shadow` に分離することで、読み取り権限を root（および shadow グループ）に限定できます。
- `640` パーミッションと `root:shadow` の所有により、一般ユーザーはファイルを読むことすらできず、ハッシュの漏洩リスクを下げます。
- `$6$` は使用されているハッシュアルゴリズムを示す識別子で、`$6$` は SHA-512 を意味します（`$1$` は MD5、`$5$` は SHA-256 など）。

**演習3**
- primary group は `/etc/passwd` の GID フィールドで指定される、そのユーザーが作成するファイルなどに既定で適用されるグループです。supplementary group は `/etc/group` の各グループ行にユーザー名が列挙されることで所属する、追加の権限を与えるグループです。
- `wheel`（RHEL系）や `sudo`（Debian系）は、そのグループに所属するユーザーだけが `sudo` で管理者権限のコマンドを実行できるようにするための仕組みで、権限管理を個々のユーザーではなくグループ単位で行うことができます。

**演習4**
- `su` は切り替え先のアカウント（多くの場合 root）のパスワードを要求します。`sudo` は実行者自身のパスワードを要求します。
- `sudo` はコマンド単位でログ（通常 `/var/log/auth.log` や `journalctl`）に記録されるため、誰が・いつ・どのコマンドを実行したかを追跡できます。また `sudoers` で許可するコマンドを細かく制限できるため、principle of least privilege を実現しやすくなります。

**演習5**
- パスワードの有効期限を設定することで、パスワードが漏洩・推測された場合でも、その有効性を一定期間に限定でき、定期的な変更を強制することで security risk を下げられます。
- `chage -l` の出力は `/etc/shadow` の各フィールド（last change、min、max、warn、inactive、expire）にそれぞれ対応しています。

**演習6**
- service account は人間ではなくプログラムが利用するためのアカウントであり、対話的なログインは不要かつ危険（侵害された場合にシェルアクセスを与えてしまう）なので、`/usr/sbin/nologin` によってログインシェルの起動を拒否します。
- `useradd -r` で作成した直後のアカウントはパスワードが未設定（ロックされた状態）であることが多いですが、明示的に `passwd -l` でロックすることで、万が一パスワードが設定・推測されても、通常の認証経路でのログインを確実に防止できます。

</details>