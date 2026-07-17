# LPI Linux Essentials (010-160 v1.6) — Topic 2.1: Command Line Basics 演習

参考文献: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/ (LPI公式学習教材、本演習は独自作成のオリジナルコンテンツです)

---

## 演習 1: シェルプロンプトとコマンドの基本構文

Linux の command line は `command [options] [arguments]` という構文で成り立っています。まずはこの基本形を体で覚えましょう。

1. terminal を開き、現在ログインしているユーザー名を表示する。
   ```
   whoami
   ```
2. 現在の作業ディレクトリ (current working directory) を表示する。
   ```
   pwd
   ```
3. システムの日時を表示する。
   ```
   date
   ```
4. `echo` コマンドで任意の文字列を画面に出力する。
   ```
   echo Hello Linux Essentials
   ```
5. 直前に実行したコマンドの終了ステータス (exit status) を確認する。
   ```
   echo $?
   ```

**確認問題**
1. `command [options] [arguments]` という構文において、`options` と `arguments` の役割の違いは何ですか。
2. `echo $?` が `0` を返した場合、直前のコマンドはどのような結果だったと判断できますか。

---

## 演習 2: options と arguments の使い分け

同じコマンドでも options を付けることで挙動が変化します。`ls` を例に確認します。

1. 現在のディレクトリの内容を一覧表示する。
   ```
   ls
   ```
2. 隠しファイル (dotfile) を含めて表示する `-a` option を付ける。
   ```
   ls -a
   ```
3. 詳細情報 (パーミッション、所有者、サイズなど) を表示する `-l` option を付ける。
   ```
   ls -l
   ```
4. `-a` と `-l` を組み合わせる (short option の連結)。
   ```
   ls -la
   ```
5. long option 形式でヘルプを表示する。
   ```
   ls --help
   ```

**確認問題**
1. `ls -la` のように short option を1文字ずつまとめて指定できるのはなぜですか。
2. short option (`-h`) と long option (`--help`) の記法上の違いを説明してください。

---

## 演習 3: 環境変数 (environment variables) の参照と設定

shell environment は environment variables によって制御されています。

1. `HOME` 変数の値を表示する。
   ```
   echo $HOME
   ```
2. `PATH` 変数の値を表示する。
   ```
   echo $PATH
   ```
3. 現在の shell に設定されている全ての variable を表示する。
   ```
   set | less
   ```
4. 現在の environment variable のみを表示する。
   ```
   env
   ```
   または
   ```
   printenv
   ```
5. 新しい shell variable を定義する (この時点では子プロセスに継承されない)。
   ```
   MYVAR=lpi_essentials
   echo $MYVAR
   ```
6. `MYVAR` を environment variable として export し、子プロセスにも継承されるようにする。
   ```
   export MYVAR
   bash -c 'echo $MYVAR'
   ```
7. 不要になった変数を削除する。
   ```
   unset MYVAR
   ```

**確認問題**
1. `MYVAR=lpi_essentials` のように定義しただけの variable と、`export` した後の variable では、子プロセスへの見え方にどのような違いがありますか。
2. `PATH` 変数にはどのような情報が格納されており、shell はそれをどのように利用しますか。

---

## 演習 4: コマンド履歴 (command history) の利用と編集

shell は実行したコマンドを記録しており、再利用できます。

1. これまでに実行したコマンドの一覧を表示する。
   ```
   history
   ```
2. 直前のコマンドをもう一度実行する。
   ```
   !!
   ```
3. `history` の出力に表示された番号 `N` を指定して、そのコマンドを再実行する (例: 番号が `12` の場合)。
   ```
   !12
   ```
4. 現在の shell セッションで保持できる履歴の最大件数を確認する。
   ```
   echo $HISTSIZE
   ```
5. 履歴が保存されるファイルのパスを確認する。
   ```
   echo $HISTFILE
   ```
6. `Ctrl` + `r` を押しながら検索したいキーワード (例: `echo`) を入力し、reverse-i-search で過去のコマンドを探す。実行したくない場合は `Ctrl` + `c` でキャンセルする。

**確認問題**
1. `!!` と `!N` はそれぞれどのような場面で使い分けると便利ですか。
2. `HISTFILE` に保存された履歴は、ログアウト後もなぜ次回のログインで参照できるのですか。

---

## 演習 5: PATH 内外のコマンド呼び出し

コマンドが `PATH` に含まれるディレクトリにあるか、どこに実際に存在するかを調べます。

1. `ls` コマンドの実体がどこにあるかを調べる。
   ```
   which ls
   ```
2. `type` コマンドで、対象が builtin なのか外部コマンドなのか alias なのかを確認する。
   ```
   type ls
   type cd
   ```
3. `command -v` を使って同様に確認する (script内での判定に適した書き方)。
   ```
   command -v ls
   ```
4. 自分の home directory に実行可能な簡単な shell script を作成する。
   ```
   echo 'echo "PATH外から実行成功"' > myscript.sh
   chmod +x myscript.sh
   ```
5. `PATH` に含まれていないディレクトリ (例えば home directory) にあるスクリプトを、相対パスを明示して実行する。
   ```
   ./myscript.sh
   ```
6. スクリプト名だけで実行しようとして、何が起こるか確認する。
   ```
   myscript.sh
   ```

**確認問題**
1. 手順 6 で `myscript.sh` とだけ入力した場合に “command not found” のようなエラーになる理由を、`PATH` の仕組みから説明してください。
2. `./` を先頭に付けて実行する必要があるのはなぜですか。

---

## 演習 6: alias と shell function の基礎

繰り返し使うコマンドを短縮するには alias や shell function が便利です。

1. 現在定義されている alias の一覧を表示する。
   ```
   alias
   ```
2. 新しい alias を定義する (`ll` を `ls -la` の短縮形にする)。
   ```
   alias ll='ls -la'
   ll
   ```
3. `type` を使って `ll` が alias であることを確認する。
   ```
   type ll
   ```
4. 不要になった alias を削除する。
   ```
   unalias ll
   ```
5. 引数を受け取る簡単な bash shell function を定義する。
   ```
   greet() {
       echo "Hello, $1!"
   }
   greet LPI
   ```
6. `type` で `greet` が function であることを確認する。
   ```
   type greet
   ```

**確認問題**
1. alias と shell function は、いずれもコマンドの短縮に使えますが、引数の扱いにおいてどのような違いがありますか。
2. alias や function は、新しい terminal を開いた際にもそのまま使えますか。使えない場合、それはなぜですか。

---

## 演習 7: quoting (引用符) の基礎

shell は特殊文字を解釈するため、意図した通りの文字列を渡すには quoting の理解が必要です。

1. variable を展開せずに、そのままの文字列として出力する (single quote)。
   ```
   echo '$HOME is my home directory'
   ```
2. variable を展開して出力する (double quote)。
   ```
   echo "$HOME is my home directory"
   ```
3. double quote の中でも展開されない文字 (`\$`) を確認する。
   ```
   echo "The price is \$5"
   ```
4. スペースを含むファイル名を扱う際の quoting を確認する。
   ```
   touch "my file.txt"
   ls -l "my file.txt"
   ```
5. 後片付けとして作成したファイルを削除する。
   ```
   rm "my file.txt"
   rm myscript.sh
   ```

**確認問題**
1. single quote (`'...'`) と double quote (`"..."`) の中で、`$` の展開に違いがあるのはなぜですか。
2. スペースを含むファイル名を quoting せずに `ls -l my file.txt` のように扱うと、shell はこれをどのように解釈しますか。

---

<details>
<summary>解答例（クリックで展開）</summary>

**演習 1**
1. `options` はコマンドの動作そのものを変更する指示 (多くは `-` や `--` で始まる)、`arguments` はコマンドが処理対象とするファイル名や値そのものです。
2. `0` は直前のコマンドが正常終了 (success) したことを意味します。`0` 以外の値はエラーや異常終了を示します。

**演習 2**
1. `-l` と `-a` のように1文字の short option は、`-la` のように1つの `-` の後にまとめて連結して指定できます。これは多くの Linux コマンドに共通する慣習です。
2. short option は `-` + 1文字 (例: `-h`)、long option は `--` + 単語 (例: `--help`) で表記します。long option の方が意味が読み取りやすい一方、short option はタイプ数が少なく済みます。

**演習 3**
1. `export` していない variable はその shell セッション内でのみ有効で、子プロセス (新たに起動する bash など) には引き継がれません。`export` した variable は environment variable となり、子プロセスにも継承されます。
2. `PATH` には、コマンド名だけを入力した際に shell がそのコマンドの実行ファイルを検索するディレクトリの一覧が `:` 区切りで格納されています。shell はコマンド実行時に `PATH` に列挙された順にディレクトリを検索します。

**演習 4**
1. `!!` は直前のコマンドを繰り返したい場合、`!N` は履歴の中の特定の番号のコマンドをピンポイントで再実行したい場合に使います。
2. `HISTFILE` (通常 `~/.bash_history`) に履歴がディスク上のファイルとして保存されるため、ログアウトしてセッションが終了してもファイルの内容は残り、次回ログイン時に再度読み込まれます。

**演習 5**
1. `myscript.sh` の存在するディレクトリ (home directory など) が `PATH` に含まれていないため、shell は `PATH` 上のディレクトリだけを検索しても実行ファイルを見つけられず、“command not found” となります。
2. `PATH` に含まれないディレクトリのファイルを実行するには、shell に明示的な場所 (相対パスまたは絶対パス) を伝える必要があるためです。`./` は「現在のディレクトリ」を意味します。

**演習 6**
1. alias は単純な文字列置換であり、引数の位置を柔軟に制御することはできません。shell function は `$1`, `$2` などの位置パラメータを使って引数を柔軟に処理できます。
2. 通常、そのまま新しい terminal では使えません。alias や function は現在の shell セッションのメモリ上にのみ存在するため、`~/.bashrc` などの設定ファイルに記述して保存しない限り、新しいセッションでは失われます。

**演習 7**
1. single quote は中身をすべてリテラル文字列として扱い、`$` による variable 展開を一切行いません。double quote は文字列内での variable 展開 (`$VAR`) やコマンド置換を許可しつつ、スペースなどによる word splitting を抑制します。
2. quoting せずに `ls -l my file.txt` と入力すると、shell はスペースを区切り文字とみなし、`my` と `file.txt` という2つの別々の argument として解釈してしまいます。

</details>