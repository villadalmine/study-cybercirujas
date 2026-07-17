# 2.4 Creating, Moving and Deleting Files — 実習

このセクションでは、Linux のコマンドラインでファイルやディレクトリを作成・コピー・移動・削除する基本操作を学びます。使用するコマンドは `mkdir`、`touch`、`cp`、`mv`、`rm`、`rmdir`、そしてワイルドカード（globbing）です。各演習は端末（terminal）上で実際に手を動かして進めてください。

参考資料: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/

---

## 演習 1: ディレクトリの作成 (mkdir)

1. ホームディレクトリ（home directory）に移動します。

   ```bash
   cd ~
   ```

2. `practice` という名前のディレクトリを作成します。

   ```bash
   mkdir practice
   ```

3. `practice` ディレクトリの中に、さらに `docs` と `images` という 2 つのサブディレクトリを一度に作成します。

   ```bash
   mkdir practice/docs practice/images
   ```

4. 存在しない中間ディレクトリも含めて、一度に階層構造を作成してみます。

   ```bash
   mkdir -p practice/projects/2024/reports
   ```

5. `ls -R practice` を実行し、作成した階層構造を確認します。

**確認問題 1-1**: 手順 4 で `-p` オプションを付けなかった場合、`projects` や `2024` ディレクトリが存在しないとどうなりますか。

**確認問題 1-2**: `mkdir` で一度に複数のディレクトリを作成するには、どのように引数を渡しますか。

---

## 演習 2: ファイルの作成とタイムスタンプ (touch)

1. `practice/docs` ディレクトリに移動します。

   ```bash
   cd ~/practice/docs
   ```

2. 中身が空のファイル `notes.txt` を作成します。

   ```bash
   touch notes.txt
   ```

3. `ls -l notes.txt` でファイルのサイズと更新日時（modification time）を確認します。

4. 数秒待ってから、もう一度同じファイルに対して `touch` を実行します。

   ```bash
   touch notes.txt
   ```

5. 再度 `ls -l notes.txt` を実行し、タイムスタンプがどう変化したか比較します。

6. 存在しないファイル名を複数指定して、一度に空ファイルをまとめて作成します。

   ```bash
   touch draft1.txt draft2.txt draft3.txt
   ```

**確認問題 2-1**: 既に存在するファイルに対して `touch` を実行すると、ファイルの中身はどうなりますか。

**確認問題 2-2**: `touch` コマンドの主な 2 つの用途は何ですか。

---

## 演習 3: ファイルのコピー (cp)

1. `notes.txt` を同じディレクトリ内に `notes_backup.txt` としてコピーします。

   ```bash
   cp notes.txt notes_backup.txt
   ```

2. `notes.txt` を親ディレクトリの `practice` にコピーします。

   ```bash
   cp notes.txt ../
   ```

3. `docs` ディレクトリ全体を `docs_copy` という名前で `practice` の直下にコピーしようとします（ディレクトリを指定せずに実行）。

   ```bash
   cp ~/practice/docs ~/practice/docs_copy
   ```

   → エラーメッセージが表示されるはずです。

4. 正しくディレクトリごとコピーするために `-r`（再帰的、recursive）オプションを付けて再実行します。

   ```bash
   cp -r ~/practice/docs ~/practice/docs_copy
   ```

5. `ls ~/practice` を実行し、`docs_copy` が作成されたことを確認します。

**確認問題 3-1**: 手順 3 でエラーが発生した理由は何ですか。

**確認問題 3-2**: ディレクトリをその中身ごとコピーするには、`cp` にどのオプションを付ける必要がありますか。

---

## 演習 4: ファイル・ディレクトリの移動とリネーム (mv)

1. `practice/draft1.txt` を `practice/images` ディレクトリに移動します。

   ```bash
   mv ~/practice/draft1.txt ~/practice/images/
   ```

2. `ls ~/practice/images` で移動できたことを確認します。

3. `practice/draft2.txt` の名前を `final.txt` に変更します（同じディレクトリ内で `mv` を使う）。

   ```bash
   mv ~/practice/draft2.txt ~/practice/final.txt
   ```

4. `practice/docs_copy` ディレクトリの名前を `practice/archive` に変更します。

   ```bash
   mv ~/practice/docs_copy ~/practice/archive
   ```

5. `ls ~/practice` を実行し、リネームの結果を確認します。

**確認問題 4-1**: Linux には「rename」という専用コマンドがないのに、なぜ `mv` でファイルの名前を変更できるのですか。

**確認問題 4-2**: `mv` と `cp` の根本的な違いは何ですか。

---

## 演習 5: ファイルとディレクトリの削除 (rm, rmdir)

1. `practice/draft3.txt` を削除します。

   ```bash
   rm ~/practice/draft3.txt
   ```

2. 削除前に確認プロンプトを表示させるため、`-i`（interactive）オプションを付けて `notes_backup.txt` を削除してみます。

   ```bash
   rm -i ~/practice/docs/notes_backup.txt
   ```

3. 中身が空の `practice/projects` ディレクトリ以下にある空の `reports` ディレクトリを、`rmdir` で削除します。

   ```bash
   rmdir ~/practice/projects/2024/reports
   ```

4. 中身が空でない `practice/archive` ディレクトリに対して `rmdir` を実行してみます。

   ```bash
   rmdir ~/practice/archive
   ```

   → エラーメッセージが表示されるはずです。

5. `-r`（再帰的）オプションを付けた `rm` で `practice/archive` を中身ごと削除します。

   ```bash
   rm -r ~/practice/archive
   ```

**確認問題 5-1**: `rmdir` が手順 4 で失敗した理由は何ですか。また、中身のあるディレクトリを削除するにはどうすればよいですか。

**確認問題 5-2**: `rm -i` オプションを使う利点は何ですか。誤って重要なファイルを削除しないためにどう役立ちますか。

---

## 演習 6: ワイルドカードによる一括操作 (globbing)

1. `practice` ディレクトリに移動し、テスト用のファイルを複数作成します。

   ```bash
   cd ~/practice
   touch file1.log file2.log file3.log report.txt
   ```

2. アスタリスク（`*`）を使い、`.log` で終わるファイルだけを一覧表示します。

   ```bash
   ls *.log
   ```

3. `?` を使い、`file` の後に 1 文字だけが続く `.log` ファイルを一覧表示します。

   ```bash
   ls file?.log
   ```

4. 角括弧（`[]`）を使い、`file1.log` と `file2.log` だけを指定して表示します。

   ```bash
   ls file[12].log
   ```

5. `*.log` に一致するすべてのファイルを一度に削除します。

   ```bash
   rm *.log
   ```

6. `ls` を実行し、`.log` ファイルがすべて削除され、`report.txt` だけが残っていることを確認します。

**確認問題 6-1**: `*` と `?` はワイルドカードとしてそれぞれ何文字にマッチしますか。

**確認問題 6-2**: `rm *.log` のようにワイルドカードで一括削除する際、実行前に安全確認として何をすべきですか。

---

<details>
<summary>解答を表示</summary>

**1-1**: `mkdir -p` を使わずに存在しない中間ディレクトリ（`projects` や `2024`）を指定すると、`mkdir` はエラー（例: "No such file or directory"）を出して失敗します。`-p` オプションは必要な親ディレクトリを自動的に作成し、既にディレクトリが存在してもエラーにしません。

**1-2**: `mkdir` の後にディレクトリ名をスペースで区切って複数指定します（例: `mkdir dir1 dir2 dir3`）。

**2-1**: 既存ファイルに `touch` を実行しても中身は変更されません。変更されるのはファイルの更新日時（modification timestamp）とアクセス日時（access timestamp）だけです。

**2-2**: (1) 中身が空の新規ファイルを作成すること、(2) 既存ファイルのタイムスタンプを現在時刻に更新すること。

**3-1**: `cp` はデフォルトではディレクトリを再帰的にコピーしません。ディレクトリを指定して `-r`（または `-R`）オプションを付けずに実行すると、"omitting directory" のようなエラーになります。

**3-2**: `-r`（recursive、再帰的）オプションが必要です（`cp -r`）。

**4-1**: `mv` はファイルの「移動」と「名前変更」を同じ操作として扱います。ファイルを同じディレクトリ内で別名の宛先に「移動」することは、事実上リネームと同じ意味になるため、専用の rename コマンドは不要です。

**4-2**: `cp` は元のファイルを残したまま複製（コピー）を作成しますが、`mv` は元のファイルを新しい場所・名前に移し、元の場所には残しません（実体は 1 つのまま位置や名前だけが変わります）。

**5-1**: `rmdir` は空のディレクトリしか削除できないため、中身がある `practice/archive` に対しては失敗します。中身ごと削除するには `rm -r`（再帰的削除）を使う必要があります。

**5-2**: `rm -i` は削除の実行前に 1 件ずつ確認プロンプトを表示するため、意図しないファイルを誤って削除してしまうリスクを減らせます。特にワイルドカードや複数ファイルを対象にした削除で有効です。

**6-1**: `*` は 0 文字以上の任意の文字列にマッチします。`?` はちょうど 1 文字にマッチします。

**6-2**: `rm` を実行する前に、同じパターンで `ls` を実行し、どのファイルが対象になるかを事前に確認することが推奨されます（例: `ls *.log` を先に実行してから `rm *.log` を実行する）。

</details>