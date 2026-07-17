# LPI Linux Essentials (010-160 v1.6) — Topic 5.2: Creating Users and Groups — 実習問題

参考文献: https://learning.lpi.org/en/learning-materials/010-160/5/5.2/

以下の演習は仮想マシンまたはコンテナ上で、`root` または `sudo` 権限を持つユーザーとして実行してください。実際のシステムに影響を与えないよう、テスト環境で行うことを推奨します。

---

## 演習 1: user の作成と `/etc/passwd` の理解

1. `sudo useradd -m alice` を実行して、home directory 付きの新しい user `alice` を作成する。
2. `tail -n 1 /etc/passwd` を実行し、`alice` のエントリを確認する。出力は `username:x:UID:GID:comment:home:shell` の形式になっている。
3. `ls -ld /home/alice` を実行し、home directory が作成されたことを確認する。
4. `cat /etc/default/useradd` を実行し、`useradd` がデフォルトで使う shell や skeleton directory (`/etc/skel`) の設定を確認する。

**理解度確認:**
- `useradd` に `-m` オプションを付けなかった場合、何が起こりますか。
- `/etc/passwd` の各フィールドのうち、実際のパスワードのハッシュ値はどこに保存されていますか。

---

## 演習 2: パスワードの設定と `/etc/shadow`

1. `sudo passwd alice` を実行し、`alice` のパスワードを設定する。
2. `sudo tail -n 1 /etc/shadow` を実行し、パスワードハッシュが記録されたエントリを確認する（root 権限が必要な理由も意識する）。
3. `sudo chage -l alice` を実行し、パスワードの有効期限に関する情報（最終変更日、有効期限など）を確認する。
4. `sudo passwd -S alice` を実行し、アカウントのパスワードステータス（`P`=有効、`L`=ロック、`NP`=未設定など）を確認する。

**理解度確認:**
- なぜ `/etc/passwd` は誰でも読み取れるのに、`/etc/shadow` は root しか読み取れないのですか。
- `passwd -l alice` と `passwd -u alice` はそれぞれ何をするコマンドですか。

---

## 演習 3: `id` と `groups` で user 情報を確認する

1. `id alice` を実行し、UID・primary group の GID・secondary group の一覧を確認する。
2. `groups alice` を実行し、`alice` が所属するすべての group 名を確認する。
3. `id` （引数なし）を実行し、自分自身の情報と比較する。

**理解度確認:**
- `useradd -m alice` を実行した直後、`alice` の primary group はデフォルトで何になっていますか（多くの distribution でのデフォルトの挙動を説明してください）。

---

## 演習 4: group の作成と `/etc/group`

1. `sudo groupadd developers` を実行し、新しい group `developers` を作成する。
2. `tail -n 1 /etc/group` を実行し、`group_name:x:GID:member_list` の形式でエントリを確認する。
3. `getent group developers` を実行し、`/etc/group` を直接読むのと同じ情報が取得できることを確認する。

**理解度確認:**
- `groupadd` で GID を明示的に指定したい場合、どのオプションを使いますか。
- `getent group developers` の出力が `/etc/group` の内容と一致するのはなぜですか（`getent` の役割を説明してください）。

---

## 演習 5: 既存の user を secondary group に追加する

1. `sudo usermod -aG developers alice` を実行し、`alice` を `developers` group の secondary member として追加する。
2. `groups alice` を再度実行し、`developers` が追加されたことを確認する。
3. `getent group developers` を再度実行し、member list に `alice` が追加されたことを確認する。

**理解度確認:**
- `usermod -aG developers alice` の代わりに `usermod -G developers alice`（`-a` なし）を実行すると何が起こりますか。この違いはなぜ重要ですか。

---

## 演習 6: user の属性を変更する

1. `sudo usermod -c "Alice Example" alice` を実行し、`/etc/passwd` の comment field（GECOS）を変更する。
2. `sudo usermod -s /bin/bash alice` を実行し、login shell を変更する。
3. `tail -n 1 /etc/passwd` で変更が反映されたことを確認する。
4. `sudo usermod -L alice` を実行してアカウントをロックし、`sudo passwd -S alice` で状態を確認する。その後 `sudo usermod -U alice` でロックを解除する。

**理解度確認:**
- `usermod -L` と `passwd -l` の効果はほぼ同じですが、それぞれどのファイルのどのフィールドを操作していますか。

---

## 演習 7: group の名前・属性を変更する

1. `sudo groupmod -n devteam developers` を実行し、group 名を `developers` から `devteam` に変更する。
2. `getent group devteam` を実行し、名前が変更され、member list（`alice`）が保持されていることを確認する。

**理解度確認:**
- group の GID は変更せずに名前だけを変更した場合、その group を primary group として持つ user たちの `/etc/passwd` エントリは更新が必要ですか。理由も説明してください。

---

## 演習 8: user と group の削除

1. `sudo userdel alice` を実行し、home directory を残したまま `alice` を削除する。
2. `ls -ld /home/alice` を実行し、home directory がまだ存在することを確認する。
3. もう一人 `sudo useradd -m bob` を作成した後、`sudo userdel -r bob` を実行し、home directory ごと削除されることを確認する。
4. `sudo groupdel devteam` を実行し、group を削除する。
5. `getent group devteam` を実行し、group が存在しなくなったことを確認する。

**理解度確認:**
- `userdel` （オプションなし）と `userdel -r` の違いは何ですか。
- まだ user の primary group になっている group を `groupdel` で削除しようとするとどうなりますか。

---

<details>
<summary>解答</summary>

**演習 1**
- `-m` を付けないと home directory は作成されず、`alice` は home directory を持たない状態になる（`/etc/passwd` の home field は指定されるが、実際のディレクトリは存在しない）。
- 実際のパスワードハッシュは `/etc/passwd` ではなく `/etc/shadow` に保存されている。`/etc/passwd` のパスワードフィールドは慣例的に `x` となっており、shadow password が使われていることを示す。

**演習 2**
- `/etc/passwd` はログイン時のシェルやユーザー名解決など、多くのプログラムが読み取る必要があるため world-readable になっている。一方 `/etc/shadow` はパスワードハッシュを含むため、オフライン攻撃（辞書攻撃・brute force）を防ぐ目的で root のみが読み取れるように制限されている。
- `passwd -l alice` はパスワードハッシュの先頭に `!` を付けてアカウントをロックし、ログインできないようにする。`passwd -u alice` はそのロックを解除する。

**演習 3**
- デフォルトでは、`useradd -m alice` を実行すると多くの distribution（Debian/Ubuntu 系や、`USERGROUPS_ENAB yes` が設定された RHEL 系など）は user 名と同じ名前の新しい private group（`alice`）を作成し、それを primary group とする（User Private Group scheme）。

**演習 4**
- `groupadd -g GID group_name` のように `-g` オプションで GID を明示的に指定する。
- `getent group developers` は Name Service Switch (NSS) 経由で group 情報を取得するコマンドで、通常のローカル環境では `/etc/group` を参照するため同じ結果になる。ただし LDAP などの外部ディレクトリサービスが設定されている場合でも同じコマンドで統一的に情報を取得できる点が `cat /etc/group` との違い。

**演習 5**
- `-a`（append）を付けずに `-G` を実行すると、指定した group リストで secondary group が「置き換え」られてしまい、それまで所属していた他の secondary group から外れてしまう。`-aG` は既存の secondary group を保持したまま追加するため、通常はこちらを使うべき。

**演習 6**
- `usermod -L` は `/etc/shadow` のパスワードハッシュの先頭に `!` を付加してロックする。`passwd -l` も同様に `/etc/shadow` のパスワードフィールドを操作しており、実質的に同じ仕組みで動作する。

**演習 7**
- 更新は不要。`/etc/passwd` の GID field は group 名ではなく数値の GID を保持しているため、group 名が変わっても GID が同じであれば紐付けは維持される。

**演習 8**
- `userdel` はアカウント情報（`/etc/passwd`・`/etc/shadow`・`/etc/group` の該当エントリ）のみを削除し、home directory は残す。`userdel -r` は home directory と mail spool も含めて削除する。
- ある group がいずれかの user の primary group として `/etc/passwd` に参照されている場合、`groupdel` は削除を拒否し、エラーメッセージ（例: "cannot remove the primary group of user..."）を表示する。先にその user の primary group を変更してから削除する必要がある。

</details>