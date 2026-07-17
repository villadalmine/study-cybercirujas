# 3.2 Searching and Extracting Data from Files — 演習

**証明書**: LPI Linux Essentials (試験 010-160, version 1.6)
**Topic**: 3.2 Searching and Extracting Data from Files（配点: 3）
**参考資料**: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/

この演習では、`grep`、`sort`、`cut`、`wc`、redirection、pipe、`find`、`locate` といったコマンドを使い、テキストファイルから必要なデータを検索・抽出する方法を学びます。すべてのステップは実際に terminal で実行しながら進めてください。

---

## 演習1: 練習用ファイルの準備

1. 作業用ディレクトリを作成し、移動します。

   ```bash
   mkdir ~/lpi-practice
   cd ~/lpi-practice
   ```

2. 果物のリストを含むファイル `fruits.txt` を作成します。

   ```bash
   printf "apple\nbanana\nApricot\ncherry\navocado\nBlueberry\ngrape\n" > fruits.txt
   ```

3. ログ風のサンプルファイル `syslog-sample.txt` を作成します。

   ```bash
   printf "Jan 10 08:00:01 host systemd: Started session\nJan 10 08:02:15 host sshd: Failed password for root\nJan 10 08:05:44 host sshd: Accepted password for admin\nJan 10 09:12:03 host kernel: USB disconnected\nJan 10 09:15:00 host sshd: Failed password for guest\n" > syslog-sample.txt
   ```

4. `cat` コマンドで両方のファイルの内容を確認します。

   ```bash
   cat fruits.txt
   cat syslog-sample.txt
   ```

**確認問題（演習1）**

- Q1. `printf` の代わりに `echo` だけで複数行のファイルを1行のコマンドで作る場合、何に注意する必要がありますか？
- Q2. `cat` はファイル全体を一度に表示しますが、ファイルが非常に大きい場合に不便な点は何ですか？

---

## 演習2: `head` と `tail` でファイルの一部を見る

1. `syslog-sample.txt` の最初の3行だけを表示します。

   ```bash
   head -n 3 syslog-sample.txt
   ```

2. 最後の2行だけを表示します。

   ```bash
   tail -n 2 syslog-sample.txt
   ```

3. `tail -f` の動作を確認するため、別の terminal を開き（またはバックグラウンドで）ファイルへの追記を監視します。

   ```bash
   tail -f syslog-sample.txt &
   echo "Jan 10 09:20:00 host sshd: Accepted password for root" >> syslog-sample.txt
   ```

4. `tail -f` のプロセスを終了します。

   ```bash
   kill %1
   ```

**確認問題（演習2）**

- Q1. `head -n 3` と `head -3` の結果に違いはありますか？
- Q2. `tail -f` はどのような場面で使うと便利ですか（例: ログファイルの監視）？

---

## 演習3: `grep` による基本的な検索

1. `fruits.txt` の中から `"a"` を含む行を検索します。

   ```bash
   grep "a" fruits.txt
   ```

2. 大文字・小文字を区別せずに `"a"` を検索します。

   ```bash
   grep -i "a" fruits.txt
   ```

3. `"a"` を **含まない** 行だけを表示します。

   ```bash
   grep -v "a" fruits.txt
   ```

4. マッチした行数だけをカウントします。

   ```bash
   grep -c "a" fruits.txt
   ```

5. マッチした行の行番号も一緒に表示します。

   ```bash
   grep -n "a" fruits.txt
   ```

**確認問題（演習3）**

- Q1. `grep -i` オプションは何をしますか？
- Q2. `grep -v` と `grep -c` を組み合わせた場合、出力される内容は何ですか？

---

## 演習4: regular expression を使った検索

1. `syslog-sample.txt` から行頭（`^`）が `"Jan 10 08"` で始まる行を検索します。

   ```bash
   grep "^Jan 10 08" syslog-sample.txt
   ```

2. `"Failed"` という単語で終わらない行の中から、`"password"` という文字列の直後に任意の1文字が続くパターン（`.`）を検索します。

   ```bash
   grep "password." syslog-sample.txt
   ```

3. `"sshd"` または `"kernel"` を含む行を extended regular expression（`-E`）で検索します。

   ```bash
   grep -E "sshd|kernel" syslog-sample.txt
   ```

4. `fruits.txt` から、`[Aa]` で始まる（大文字・小文字どちらの `A` でも）行を character class を使って検索します。

   ```bash
   grep "^[Aa]" fruits.txt
   ```

5. 行末（`$`）が `"e"` で終わる行を検索します。

   ```bash
   grep "e$" fruits.txt
   ```

**確認問題（演習4）**

- Q1. regular expression における `^` と `$` はそれぞれ何を意味しますか？
- Q2. `grep -E` を使うと `|`（OR）のような拡張パターンが使えるのはなぜですか？基本の `grep` との違いは何ですか？
- Q3. `[Aa]` のような character class はどのような場合に便利ですか？

---

## 演習5: `sort`、`uniq`、`wc` でデータを整理する

1. `fruits.txt` をアルファベット順に sort します。

   ```bash
   sort fruits.txt
   ```

2. 大文字・小文字を無視して sort します。

   ```bash
   sort -f fruits.txt
   ```

3. 重複行を含むファイルを新規作成し、`uniq` で重複を除去します。

   ```bash
   printf "banana\nbanana\napple\napple\napple\ncherry\n" > dup-fruits.txt
   sort dup-fruits.txt | uniq
   ```

4. 各行の出現回数も表示します。

   ```bash
   sort dup-fruits.txt | uniq -c
   ```

5. `fruits.txt` の行数、単語数、バイト数を確認します。

   ```bash
   wc fruits.txt
   wc -l fruits.txt
   ```

**確認問題（演習5）**

- Q1. `uniq` を単独で使う前に、なぜ多くの場合 `sort` を先に実行する必要がありますか？
- Q2. `wc -l` は何を数えますか？

---

## 演習6: `cut` でフィールドを抽出する

1. コロン区切りのサンプルデータを作成します。

   ```bash
   printf "alice:1001:/home/alice:/bin/bash\nbob:1002:/home/bob:/bin/sh\ncarol:1003:/home/carol:/bin/bash\n" > users-sample.txt
   ```

2. `cut` を使い、ユーザー名（1番目のフィールド）だけを抽出します。

   ```bash
   cut -d ":" -f 1 users-sample.txt
   ```

3. ユーザー名とホームディレクトリ（1番目と3番目のフィールド）を抽出します。

   ```bash
   cut -d ":" -f 1,3 users-sample.txt
   ```

4. 各行の先頭5文字だけを character 単位で抽出します。

   ```bash
   cut -c 1-5 users-sample.txt
   ```

**確認問題（演習6）**

- Q1. `cut -d` オプションは何を指定するためのものですか？
- Q2. `cut -f 1,3` と `cut -f 1-3` の違いは何ですか？

---

## 演習7: redirection と pipe の組み合わせ

1. `grep` の検索結果をファイルに保存します（上書き）。

   ```bash
   grep "sshd" syslog-sample.txt > sshd-only.txt
   cat sshd-only.txt
   ```

2. さらに検索結果を追記します（append）。

   ```bash
   grep "kernel" syslog-sample.txt >> sshd-only.txt
   cat sshd-only.txt
   ```

3. `sshd-only.txt` を input として `wc -l` に渡します（input redirection）。

   ```bash
   wc -l < sshd-only.txt
   ```

4. 複数のコマンドを pipe（`|`）でつなぎ、`"Failed"` を含む行を抽出してから sort します。

   ```bash
   grep "Failed" syslog-sample.txt | sort
   ```

5. さらに pipe を重ね、失敗ログの件数だけを数えます。

   ```bash
   grep "Failed" syslog-sample.txt | wc -l
   ```

**確認問題（演習7）**

- Q1. `>` と `>>` の違いは何ですか？
- Q2. pipe（`|`）はコマンド間で何を受け渡しますか？standard output と standard input の観点から説明してください。

---

## 演習8: `find` と `locate` でファイルを探す

1. `~/lpi-practice` 以下から拡張子 `.txt` のファイルをすべて検索します。

   ```bash
   find ~/lpi-practice -name "*.txt"
   ```

2. ファイル名の大文字・小文字を区別せずに検索します。

   ```bash
   find ~/lpi-practice -iname "*SAMPLE*"
   ```

3. ファイルタイプを指定して、ディレクトリだけを検索します。

   ```bash
   find ~/lpi-practice -type d
   ```

4. `locate` コマンドが使えるか確認し、使える場合は database を更新してから検索します（`sudo` 権限が必要な場合があります）。

   ```bash
   which locate
   sudo updatedb
   locate fruits.txt
   ```

**確認問題（演習8）**

- Q1. `find` と `locate` の動作方法には根本的な違いがあります。それぞれどのように検索を行いますか？
- Q2. `locate` を使う前に `updatedb` を実行しないと、なぜ最新のファイルが検索結果に出ないことがありますか？

---

<details>
<summary>解答</summary>

**演習1**
- A1. `echo` はデフォルトで `\n` をエスケープシーケンスとして解釈しないため、`echo -e` を使うか、複数の `echo ... >>` を実行する必要があります。
- A2. ファイルが大きい場合、`cat` は端末画面に一度に大量の内容を出力してしまい、必要な部分を見つけにくくなります。この場合は `less` や `more`、あるいは `head`/`tail` を使う方が適切です。

**演習2**
- A1. 違いはありません。`-n` オプションの引数はスペースありでもなしでも指定できます（`head -n 3` と `head -3` は同じ結果になります）。
- A2. ログファイルなど、内容がリアルタイムで追記されていくファイルを監視し、新しい行が追加されるたびに即座に確認したい場合に便利です。

**演習3**
- A1. 検索パターンの大文字・小文字の違いを無視してマッチさせます。
- A2. `"a"` を含まない行の**数**（行数のカウント）だけが出力されます。

**演習4**
- A1. `^` は行の先頭、`$` は行の末尾を表すアンカーです。
- A2. 基本の `grep`（BRE: Basic Regular Expression）では `|` はそのままでは特殊文字として扱われず、エスケープが必要になるか動作しません。`grep -E`（ERE: Extended Regular Expression）を使うと `|`（OR）や `+`、`?` などの拡張メタ文字がエスケープなしで使えます。
- A3. 複数の候補となる1文字（例: 大文字/小文字、母音字など）のどれか1つにマッチさせたい場合に便利です。

**演習5**
- A1. `uniq` は**隣接する**重複行しか検出できないため、離れた場所にある同じ行をまとめて除去するには、事前に `sort` で同じ行を隣接させておく必要があります。
- A2. ファイル内の行数を数えます。

**演習6**
- A1. フィールドの区切り文字（delimiter）を指定します。デフォルトはタブ文字です。
- A2. `-f 1,3` は1番目と3番目のフィールドのみを個別に抽出しますが、`-f 1-3` は1番目から3番目までの連続する範囲をすべて抽出します。

**演習7**
- A1. `>` は出力先ファイルを上書きします（既存の内容は失われます）。`>>` は既存ファイルの末尾に追記します。
- A2. pipe は左側のコマンドの standard output を、右側のコマンドの standard input として直接渡します。中間ファイルを作らずにコマンドを連結できます。

**演習8**
- A1. `find` は指定したディレクトリ以下を実際にリアルタイムで走査（traverse）してファイルを探します。処理には時間がかかりますが、常に最新の状態を反映します。`locate` は事前に構築された database（インデックス）を検索するため非常に高速ですが、database が更新されていないと最新のファイルシステムの状態を反映していない可能性があります。
- A2. `locate` が参照する database は `updatedb` によって定期的に（通常は cron 経由で）更新されます。手動で `updatedb` を実行しない限り、直前に作成・削除されたファイルは database に反映されず、検索結果に現れないことがあります。

</details>