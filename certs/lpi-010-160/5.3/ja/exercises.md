# Topic 5.3: Managing File Permissions and Ownership — ガイド付き演習

**対象認定:** LPI Linux Essentials (試験 010-160, version 1.6)
**参考文献:** https://learning.lpi.org/en/learning-materials/010-160/5/5.3/ （内容は独自に構成しており、原文の逐語的な引用は行っていません）

以下の演習は、実際にターミナルでコマンドを実行しながら permission と ownership の概念を体得することを目的としています。各ブロックの後にある質問に、次のブロックへ進む前に自分の言葉で答えてみてください。

---

## Exercise 1: `ls -l` で permission 文字列を読む

1. 作業用ディレクトリを作成し、移動します。
   ```bash
   mkdir ~/perm-lab && cd ~/perm-lab
   ```
2. 空のファイルを作成します。
   ```bash
   touch file1.txt
   ```
3. 詳細情報を表示します。
   ```bash
   ls -l file1.txt
   ```
4. 出力は次のような形式になります。
   ```
   -rw-r--r-- 1 student student 0  7月 12 10:00 file1.txt
   ```
   先頭の10文字（`-rw-r--r--`）を、以下のように分解して読みます。
   - 1文字目: file type（`-` = 通常ファイル、`d` = directory）
   - 2〜4文字目: owner (user) の permission
   - 5〜7文字目: group の permission
   - 8〜10文字目: other (world) の permission

   その後に続く `student student` は、それぞれ owner と group を表します。

**確認問題**
- **Q1.** `-rwxr-x---` という permission 文字列を持つファイルがあるとき、group に属するユーザーはこのファイルに対して何ができますか？
- **Q2.** `ls -l` の出力の1文字目が `d` である場合、何を意味しますか？

---

## Exercise 2: symbolic mode で `chmod` を使う

1. `file1.txt` の owner に execute 権限を追加します。
   ```bash
   chmod u+x file1.txt
   ```
2. 結果を確認します。
   ```bash
   ls -l file1.txt
   ```
3. group から write 権限を取り除きます（もともと持っていないので変化を観察するだけでも構いません）。
   ```bash
   chmod g-w file1.txt
   ```
4. other の permission を read のみに固定します。
   ```bash
   chmod o=r file1.txt
   ```
5. 最終的な permission を確認します。
   ```bash
   ls -l file1.txt
   ```

**確認問題**
- **Q3.** symbolic mode における `u`、`g`、`o`、`a` はそれぞれ何を指しますか？
- **Q4.** `+`、`-`、`=` の3つの演算子の違いは何ですか？

---

## Exercise 3: numeric (octal) mode で `chmod` を使う

1. `file1.txt` の permission を owner: read/write/execute、group: read/execute、other: 権限なし、に設定します。
   ```bash
   chmod 750 file1.txt
   ```
2. 確認します。
   ```bash
   ls -l file1.txt
   ```
3. 別のファイルを作成し、一般的な「テキストファイル」用の permission に設定します。
   ```bash
   touch file2.txt
   chmod 644 file2.txt
   ls -l file2.txt
   ```

**確認問題**
- **Q5.** `r=4`、`w=2`、`x=1` という値の割り当てに基づくと、owner に read と write のみ、group と other に read のみを与える octal 値はいくつですか？
- **Q6.** `chmod 750` を実行した結果、other には何の権限も残っていません。これを symbolic mode の1行のコマンドで表すとどうなりますか？

---

## Exercise 4: directory の execute permission の意味

1. サブディレクトリとその中にファイルを作成します。
   ```bash
   mkdir subdir
   touch subdir/inside.txt
   ```
2. directory から execute 権限を外します。
   ```bash
   chmod u-x subdir
   ```
3. そのディレクトリに移動しようとします。
   ```bash
   cd subdir
   ```
   permission denied のエラーが出ることを確認します。
4. execute 権限を戻します。
   ```bash
   cd ~/perm-lab
   chmod u+x subdir
   cd subdir && ls -l && cd ..
   ```

**確認問題**
- **Q7.** ファイルに対する execute permission とディレクトリに対する execute permission では、意味がどう異なりますか？
- **Q8.** directory の read 権限はあるが execute 権限がない場合、`ls` はどのように動作すると予想しますか？

---

## Exercise 5: `chown` と `chgrp` で ownership を変更する

> 以下は管理者権限（`sudo`）が必要な操作です。学習用の仮想環境やサンドボックスで実行してください。

1. 現在の owner と group を確認します。
   ```bash
   ls -l file1.txt
   ```
2. 新しい group を作成します（すでに複数の group が存在する環境なら省略可）。
   ```bash
   sudo groupadd labgroup
   ```
3. ファイルの group を変更します。
   ```bash
   sudo chgrp labgroup file1.txt
   ```
4. ファイルの owner を変更します（対象ユーザーが存在する場合）。
   ```bash
   sudo chown otheruser file1.txt
   ```
5. owner と group を同時に変更します。
   ```bash
   sudo chown otheruser:labgroup file1.txt
   ```
6. 結果を確認します。
   ```bash
   ls -l file1.txt
   ```

**確認問題**
- **Q9.** 一般ユーザーが自分の所有していないファイルの owner を、`sudo` なしで変更できますか？その理由は？
- **Q10.** `chown user:group file` と `chown user file && chgrp group file` の違いは何ですか？

---

## Exercise 6: SetUID・SetGID・sticky bit の観察

1. `passwd` コマンドの permission を確認します。
   ```bash
   ls -l /usr/bin/passwd
   ```
   owner の execute の位置に `s` が表示されていることを確認します（SetUID bit）。
2. `/tmp` ディレクトリの permission を確認します。
   ```bash
   ls -ld /tmp
   ```
   other の execute の位置に `t` が表示されていることを確認します（sticky bit）。
3. 自分の演習用ファイルに SetGID を試しに設定してみます。
   ```bash
   chmod g+s subdir
   ls -ld subdir
   ```

**確認問題**
- **Q11.** SetUID bit が設定された実行ファイルを一般ユーザーが実行すると、どのユーザー権限でプロセスが動作しますか？
- **Q12.** `/tmp` のような共有ディレクトリに sticky bit が設定されている目的は何ですか？

---

<details>
<summary>解答例（クリックして展開）</summary>

**Q1.** group のユーザーは read と execute が可能です（このファイルがスクリプトやプログラムであれば実行でき、内容を読むこともできます）。ただし write（書き込み・変更）はできません。

**Q2.** そのエントリが通常のファイルではなく directory であることを意味します。

**Q3.** `u` は owner (user)、`g` は group、`o` は other（それ以外の全ユーザー）、`a` はすべて（`u`+`g`+`o`）を指します。

**Q4.** `+` は指定した権限を既存の設定に追加し、`-` は指定した権限を取り除きます。`=` は既存の設定を無視し、指定した権限だけをそのカテゴリに設定（上書き）します。

**Q5.** owner: read+write = 4+2 = 6、group: read = 4、other: read = 4 なので、`chmod 644` になります。

**Q6.** `chmod o= file1.txt`（もしくは `chmod o-rwx file1.txt`）で other の全権限を削除できます。

**Q7.** ファイルの execute permission は、そのファイルをプログラム／スクリプトとして実行できるかどうかを制御します。一方 directory の execute permission は、そのディレクトリの中に「入って（traverse）」ファイルやサブディレクトリにアクセスできるかどうかを制御します。execute がないと、ディレクトリ名や存在自体は分かっても中身のファイルの詳細情報にアクセスできません。

**Q8.** read はあるが execute がない場合、`ls` でファイル名の一覧は表示できますが、各ファイルの詳細情報（パーミッションやサイズなど、`ls -l` で必要な stat 情報）を取得できずエラーになったり、サブディレクトリに `cd` で入れなかったりします。

**Q9.** 通常はできません。ファイルの owner を変更する操作（`chown`）は、システムのセキュリティ上、root（もしくは `sudo` 権限を持つユーザー）にのみ許可されています。これは、一般ユーザーが自分のファイルを他人に「押し付けて」ディスク使用量制限（quota）などを回避することを防ぐためです。

**Q10.** 実行結果としては同じで、owner と group の両方が変更されます。`chown user:group file` は1コマンドで両方を同時に変更できるのに対し、2つに分けた場合はコマンドが2回実行されるだけで、最終的な状態に違いはありません。

**Q11.** 実行したユーザー自身の権限ではなく、そのファイルの owner の権限でプロセスが動作します（例: `passwd` は root が owner なので、一般ユーザーが実行しても root 権限で `/etc/shadow` を書き換えられます）。

**Q12.** sticky bit が設定された directory では、そのディレクトリに write 権限を持つユーザーであっても、自分が owner ではないファイルを削除・rename できなくなります。`/tmp` のように複数ユーザーが共有し、誰でも書き込めるディレクトリで、他人のファイルを誤って（または悪意を持って）削除されるのを防ぐために使われます。

</details>