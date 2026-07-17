# LPI Linux Essentials (010-160 v1.6) — トピック3.3: Turning Commands into a Script

**参考資料**: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/

この演習では、シェルの対話的なコマンドを再利用可能な script に変換する方法を、実際に手を動かしながら学びます。各ステップを自分のターミナルで実行し、続く質問に自分の言葉で答えてから `<details>` セクションを開いて確認してください。

---

## 演習1: 最初の script を作成して実行する

1. 作業用のディレクトリを作成し、移動します。

   ```bash
   mkdir ~/scripts-lab && cd ~/scripts-lab
   ```

2. テキストエディタ（`nano` など）で `hello.sh` というファイルを作成し、以下の内容を書き込みます。

   ```bash
   #!/bin/bash
   echo "Hello, Linux Essentials!"
   ```

3. ファイルを保存し、現在の権限を確認します。

   ```bash
   ls -l hello.sh
   ```

4. `bash` を明示的に呼び出して script を実行してみます。

   ```bash
   bash hello.sh
   ```

5. 次に、実行可能ビットを付与してから、直接実行してみます。

   ```bash
   chmod +x hello.sh
   ./hello.sh
   ```

**質問1**: 1行目の `#!/bin/bash` は何と呼ばれ、どのような役割を持っていますか。
**質問2**: ステップ4のように `bash hello.sh` で実行した場合と、ステップ5のように `./hello.sh` で実行した場合とで、`chmod +x` の必要性に違いはありますか。理由も説明してください。
**質問3**: `./hello.sh` を実行しようとして `Permission denied` と表示された場合、何が原因である可能性が高いですか。

---

## 演習2: variable と `echo` の展開

1. `greet.sh` という新しい script を作成します。

   ```bash
   #!/bin/bash
   NAME="Linux Essentials"
   echo "Studying for $NAME certification."
   echo 'Studying for $NAME certification.'
   ```

2. 実行権限を付与して実行します。

   ```bash
   chmod +x greet.sh
   ./greet.sh
   ```

3. 出力の2行を見比べます。1行目と2行目で `$NAME` の扱いがどう違うか観察してください。

**質問4**: ダブルクォート `"..."` とシングルクォート `'...'` で、shell variable の展開（expansion）に違いが生じるのはなぜですか。
**質問5**: variable への代入 `NAME="Linux Essentials"` で、`=` の前後にスペースを入れると何が起こりますか。実際に試して確認してください。

---

## 演習3: positional parameters（引数）を扱う

1. `args.sh` という script を作成します。

   ```bash
   #!/bin/bash
   echo "Script name: $0"
   echo "First argument: $1"
   echo "Second argument: $2"
   echo "Number of arguments: $#"
   echo "All arguments: $@"
   ```

2. 実行権限を付与し、複数の引数を与えて実行します。

   ```bash
   chmod +x args.sh
   ./args.sh apple banana cherry
   ```

3. 引数を1つも与えずに実行してみます。

   ```bash
   ./args.sh
   ```

**質問6**: `$1` と `$2` はそれぞれ何を表していますか。また `$0` は他の positional parameters と何が本質的に異なりますか。
**質問7**: ステップ3のように引数なしで実行すると、`$#` と `$@` はそれぞれどのような値になりますか。

---

## 演習4: exit code（`$?`）で成功・失敗を判定する

1. 存在しないファイルに対して `ls` を実行し、直後に `$?` を確認します。

   ```bash
   ls /no/such/file
   echo "Exit code: $?"
   ```

2. 存在するディレクトリに対して同じ操作をします。

   ```bash
   ls /etc
   echo "Exit code: $?"
   ```

3. `check.sh` という script を作成します。

   ```bash
   #!/bin/bash
   grep "root" /etc/passwd > /dev/null
   echo "grep exit code: $?"
   exit 3
   ```

4. 実行権限を付与し、実行後すぐに script 自体の exit code を確認します。

   ```bash
   chmod +x check.sh
   ./check.sh
   echo "Script's own exit code: $?"
   ```

**質問8**: exit code `0` は一般的に何を意味しますか。また `0` 以外の値はどう解釈すべきですか。
**質問9**: 演習4のステップ4で、最後の `echo "Script's own exit code: $?"` はいくつを表示しますか。なぜ `check.sh` 内部の `grep` の exit code ではないのですか。

---

## 演習5: `if-then-else` で条件分岐する

1. `check_file.sh` という script を作成します。

   ```bash
   #!/bin/bash
   FILE="$1"
   if [ -f "$FILE" ]; then
       echo "$FILE exists and is a regular file."
   else
       echo "$FILE was not found."
   fi
   ```

2. 実行権限を付与し、存在するファイルと存在しないファイルの両方でテストします。

   ```bash
   chmod +x check_file.sh
   ./check_file.sh /etc/hostname
   ./check_file.sh /tmp/not_here.txt
   ```

**質問10**: `if [ -f "$FILE" ]; then` の `-f` は何をテストしていますか。他によく使われるテスト演算子を1つ挙げてください。
**質問11**: `$FILE` をダブルクォートで囲まずに `if [ -f $FILE ]; then` と書いた場合、引数にスペースを含むファイル名を渡すとどのような問題が起こり得ますか。

---

## 演習6: `for` ループでコマンドを繰り返す

1. `loopfiles.sh` という script を作成します。

   ```bash
   #!/bin/bash
   for FILE in *.sh; do
       echo "Found script: $FILE"
   done
   ```

2. 実行権限を付与し、`~/scripts-lab` ディレクトリ内で実行します。

   ```bash
   chmod +x loopfiles.sh
   ./loopfiles.sh
   ```

3. `for` の対象を数値の範囲に変えた script `countup.sh` を作成し、実行します。

   ```bash
   #!/bin/bash
   for NUM in 1 2 3 4 5; do
       echo "Count: $NUM"
   done
   ```

**質問12**: 演習6のステップ1で `for FILE in *.sh` は何をリストとして反復していますか。
**質問13**: `for NUM in 1 2 3 4 5` の代わりに `for NUM in $(seq 1 5)` と書いても同じ結果になります。この2つの書き方の実用上の違いは何ですか（例えば範囲が1から100の場合を考えてみてください）。

---

## 演習7: script から別の script を呼び出す

1. 演習6で作成した `countup.sh` を再利用し、それを呼び出す `runner.sh` を作成します。

   ```bash
   #!/bin/bash
   echo "Starting runner.sh"
   ./countup.sh
   echo "countup.sh finished with exit code: $?"
   echo "runner.sh done"
   ```

2. `countup.sh` と `runner.sh` の両方に実行権限があることを確認してから実行します。

   ```bash
   chmod +x countup.sh runner.sh
   ./runner.sh
   ```

**質問14**: `runner.sh` の中で `countup.sh` を `./countup.sh` として呼び出すには何が前提条件になりますか（PATH やカレントディレクトリの観点から）。
**質問15**: もし `countup.sh` に実行権限がなかった場合、`runner.sh` の実行結果はどうなりますか。

---

<details>
<summary>解答を見る</summary>

**質問1**: `#!/bin/bash` は shebang（シバン）と呼ばれ、この script をどの interpreter（この場合は `/bin/bash`）で実行すべきかを OS に伝える役割を持ちます。1行目の先頭に `#!` で始まる必要があります。

**質問2**: `bash hello.sh` のように interpreter を明示して呼び出す場合、ファイルの実行ビットは不要です。`bash` コマンド自体が読み取り権限（read permission）のあるファイルをスクリプトとして解釈して実行するためです。一方 `./hello.sh` のように直接実行する場合は、shell がそのファイルを実行ファイルとして起動しようとするため、実行権限（execute permission）が必須です。

**質問3**: 主な原因は実行ビット（execute permission）が付与されていないことです。`chmod +x hello.sh` を実行し忘れている、または `ls -l` で確認したときに `x` の権限フラグが立っていない状態が考えられます。

**質問4**: ダブルクォート内では `$` による variable expansion（および command substitution）が行われますが、シングルクォート内ではすべての文字がリテラル文字列として扱われ、展開が一切行われません。そのため2行目は `$NAME` という文字がそのまま出力されます。

**質問5**: `NAME = "Linux Essentials"` のように `=` の前後にスペースを入れると、shell はこれを代入ではなく `NAME` というコマンドの実行として解釈しようとし、`NAME: command not found` のようなエラーになります。bash の変数代入では `=` の前後にスペースを入れてはいけません。

**質問6**: `$1` は script に渡された1番目の引数、`$2` は2番目の引数を表す positional parameter です。`$0` は script 自身の名前（呼び出されたときのパス）を表し、引数の一部ではないため `$#` の集計にも含まれません。

**質問7**: 引数なしで実行した場合、`$#` は `0` になり、`$@` は空文字列（何も展開されない）になります。

**質問8**: exit code `0` は一般的にコマンドや script が成功（success）したことを意味します。`0` 以外の値（通常 `1`〜`255`）は何らかのエラーや異常終了（failure）を意味し、値ごとに script 作成者が意味を定義できます。

**質問9**: 表示されるのは `3` です。理由は、`check.sh` 内部の `exit 3` によって script 全体の exit code が明示的に `3` に上書きされるためです。`$?` は直前に実行されたコマンド（この場合は `check.sh` 自体の呼び出し）の exit code を参照するので、内部の `grep` の exit code は `exit 3` によって既に上書きされています。

**質問10**: `-f` は指定したパスが存在し、かつ通常のファイル（regular file、ディレクトリやシンボリックリンクではない）であるかをテストします。他によく使われる演算子には `-d`（ディレクトリかどうか）、`-x`（実行権限があるか）、`-z`（文字列が空か）などがあります。

**質問11**: クォートせずに `$FILE` を展開すると、shell がスペースを引数の区切りとして解釈してしまい、`[ -f My File.txt ]` のように複数の単語に分割されます。その結果 `test` コマンド（`[` )が想定より多い引数を受け取り、`too many arguments` のようなエラーになります。ファイル名やパスを扱う variable は常にダブルクォートで囲むのが安全です。

**質問12**: `*.sh` はカレントディレクトリ内で拡張子が `.sh` で終わるファイル名すべてに展開される glob pattern（ワイルドカード）です。`for` ループはこの展開結果である個々のファイル名を1つずつ `$FILE` に代入して繰り返します。

**質問13**: `for NUM in 1 2 3 4 5` は事前に列挙した固定のリストを反復します。一方 `for NUM in $(seq 1 5)` は `seq` コマンドの出力を command substitution で動的に生成してから反復します。範囲が1〜100のように大きい場合、固定リストをすべて手で書くのは非現実的なので `$(seq 1 100)`（または bash の `{1..100}` のような range 展開）を使う方が実用的です。

**質問14**: `./countup.sh` という呼び出し方は、`countup.sh` が現在のカレントディレクトリ（current working directory）に存在し、かつ実行権限を持っていることを前提としています。`./` を付けているのは、通常 PATH にカレントディレクトリが含まれていないため、明示的に相対パスを指定する必要があるからです。

**質問15**: `countup.sh` に実行権限がない場合、`./countup.sh` の呼び出しは `Permission denied` エラーで失敗し、`$?` には非ゼロの exit code（多くの場合 `126`）が入ります。ただし `runner.sh` 自体はそこで停止せず、後続の `echo` 行（"countup.sh finished..." や "runner.sh done"）は実行され続けます。これは bash が既定では、コマンドの失敗があっても script 全体を自動的には停止しない（`set -e` のような設定をしない限り）ためです。

</details>