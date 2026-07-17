# Topic 3.1: Archiving Files on the Command Line — ガイド付き演習

出典（参考のみ、引用ではなくオリジナル解説）: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/

このセクションでは `tar` を使った archive の作成・展開・確認、`gzip`・`bzip2`・`xz` による compression、そして glob pattern（wildcard）を使ったファイル選択を、実際にコマンドを実行しながら学びます。作業用ディレクトリを用意してから進めてください。

```bash
mkdir ~/lpi-3-1 && cd ~/lpi-3-1
```

---

## 演習 1: サンプルファイルの準備と tar archive の作成

1. 練習用のファイルをいくつか作成します。

   ```bash
   mkdir project
   echo "report draft" > project/report.txt
   echo "notes" > project/notes.txt
   echo "print(1)" > project/script.py
   ```

2. `project` ディレクトリ全体を 1 つの archive ファイルにまとめます。

   ```bash
   tar -cvf project.tar project/
   ```

   `-c` は create、`-v` は verbose（処理中のファイル名を表示）、`-f` は続く引数が archive のファイル名であることを指定します。

3. `ls -lh` で `project.tar` のサイズと、元の `project/` ディレクトリの合計サイズを見比べてみます。

   ```bash
   ls -lh project.tar
   du -sh project/
   ```

> **確認問題 1-1**: `tar -cvf project.tar project/` を実行したあと、`project.tar` のファイルサイズは元のディレクトリのサイズとおおよそ同じでしょうか、それとも大きく異なるでしょうか。理由も答えてください。
>
> **確認問題 1-2**: コマンド中の `f` オプションを省略すると（例: `tar -cv project/`）何が起こりますか。`f` オプションが必須である理由を説明してください。

---

## 演習 2: archive の中身を確認する（compression と archive の違い）

1. `project.tar` を展開せずに中身の一覧だけを見ます。

   ```bash
   tar -tvf project.tar
   ```

2. 同じ内容を `gzip` で compress してみます。

   ```bash
   gzip -k project.tar
   ls -lh project.tar project.tar.gz
   ```

   `-k`（keep）は元の `.tar` ファイルを削除せずに残すオプションです。

3. `project.tar` と `project.tar.gz` のサイズを比較します。

> **確認問題 2-1**: `tar` コマンド自体は archive 内のデータを compression（圧縮）しますか。archive（複数ファイルを 1 つにまとめること）と compression（データサイズを縮小すること）の違いを、この演習の結果を使って説明してください。
>
> **確認問題 2-2**: `project.tar.gz` は `project.tar` よりファイルサイズが小さくなっているはずです。なぜそうなるのか説明してください。

---

## 演習 3: tar で directly compress する（gzip / bzip2 / xz の比較）

1. まずクリーンな状態に戻します。

   ```bash
   rm -f project.tar project.tar.gz
   ```

2. `tar` に compression オプションを直接渡して 3 種類の archive を作成します。

   ```bash
   tar -czvf project.tar.gz project/    # gzip 圧縮
   tar -cjvf project.tar.bz2 project/   # bzip2 圧縮
   tar -cJvf project.tar.xz project/    # xz 圧縮
   ```

   `-z` は gzip、`-j` は bzip2、`-J` は xz を通す指定です。

3. 3 つの archive のサイズを比較します。

   ```bash
   ls -lh project.tar.gz project.tar.bz2 project.tar.xz
   ```

> **確認問題 3-1**: 一般的に compression 率（ファイルサイズの小ささ）が高い順に `gzip`、`bzip2`、`xz` を並べるとどうなりますか。またその代わりにトレードオフとなる要素は何ですか。
>
> **確認問題 3-2**: `tar -czvf` の `c`・`z`・`v`・`f` はそれぞれ何を意味しますか。

---

## 演習 4: archive を展開する（extract）

1. 展開用のディレクトリを作り、`project.tar.gz` を展開します。

   ```bash
   mkdir restore && cd restore
   tar -xzvf ../project.tar.gz
   ```

2. 展開結果を確認します。

   ```bash
   ls -R
   cd ..
   ```

3. 特定の 1 ファイルだけを archive から展開してみます。

   ```bash
   tar -xzvf project.tar.gz project/notes.txt
   ```

> **確認問題 4-1**: `tar -xzvf` を実行するとき、compression の種類（gzip か bzip2 か xz か）を `x`（extract）のオプションで明示的に指定する必要がありますか。理由も含めて答えてください。
>
> **確認問題 4-2**: `tar -xzvf project.tar.gz project/notes.txt` のように archive 名の後にパスを指定すると、どのような動作になりますか。

---

## 演習 5: glob pattern（wildcard）でファイルを選んで archive に含める

1. archive 対象を絞り込むための追加ファイルを作成します。

   ```bash
   touch project/data1.csv project/data2.csv project/image.png
   ```

2. `.csv` ファイルだけを archive します。

   ```bash
   tar -cvf csv-only.tar project/*.csv
   tar -tvf csv-only.tar
   ```

3. `?` を使って 1 文字だけ違うファイル名にマッチさせます。

   ```bash
   tar -cvf single-digit.tar project/data?.csv
   ```

4. `[]` で文字の範囲を指定して archive します。

   ```bash
   tar -cvf report-or-notes.tar project/[rn]*.txt
   ```

> **確認問題 5-1**: `*`、`?`、`[]` という 3 つの glob 記号は、それぞれ何にマッチしますか。
>
> **確認問題 5-2**: `project/[rn]*.txt` という pattern は `project/report.txt` と `project/notes.txt` のどちらにマッチしますか。理由を pattern の構造から説明してください。
>
> **確認問題 5-3**: glob pattern はシェル（shell）自身がファイル名に展開してから `tar` に渡すのか、それとも `tar` コマンド自体が pattern を解釈するのか、どちらだと考えられますか。`echo project/*.csv` を実行して確認してみてください。

---

<details>
<summary>解答を見る</summary>

**1-1**: 大きく異なりません。`tar` はデフォルトでは compression を行わず、複数のファイルを 1 つにまとめる（archive する）だけなので、`project.tar` のサイズは元の `project/` ディレクトリの合計サイズとヘッダー情報を加えた程度になります。

**1-2**: `f` オプションを省略すると `tar` は archive の出力先としてデフォルトのテープデバイス（例: `/dev/rmt0` など、歴史的に tar が磁気テープ用に作られたことに由来）を使おうとし、エラーになるか意図しない動作になります。`f` は「次の引数がファイル名である」ことを明示するために必須です。

**2-1**: `tar` 自体は compression を行いません。`tar` は archiving（複数ファイル・ディレクトリ構造を 1 つのファイルにまとめること）のみを担当し、データサイズは縮小されません。一方 `gzip` は compression（既存の 1 ファイルのデータを可逆的に縮小すること）を担当します。このため「複数ファイルを 1 つにまとめてから圧縮する」という組み合わせ（`tar` + `gzip`）がよく使われます。

**2-2**: `gzip` が `project.tar` のデータに対して圧縮アルゴリズムを適用し、冗長なデータパターンを符号化してファイルサイズを縮小するためです。

**3-1**: 一般的に圧縮率は `xz` > `bzip2` > `gzip` の順に高くなります（ファイルサイズがより小さくなります）。ただしトレードオフとして、圧縮率が高いほど圧縮・展開にかかる時間（CPU 負荷）が大きくなります。`gzip` は高速だが圧縮率は低め、`xz` は圧縮率が高いが低速、という関係です。

**3-2**: `c` は create（新規 archive を作成）、`z` は gzip で compression を通す、`v` は verbose（処理中のファイル名を表示）、`f` は続く引数を archive のファイル名として扱う、という意味です。

**4-1**: 現代の GNU `tar` は archive の内容を自動検出できるため、`x` オプションで `z`・`j`・`J` を厳密に一致させなくても展開できることが多いです（自動判別機能）。ただし試験対策としては、作成時に使った compression オプションと同じものを extract 時にも明示的に指定する習慣をつけるのが確実です。

**4-2**: archive 全体ではなく、指定したパス（`project/notes.txt`）に一致するファイルだけが展開されます。

**5-1**: `*` は 0 文字以上の任意の文字列にマッチします。`?` は任意の 1 文字にマッチします。`[]` は角括弧内に列挙した文字のいずれか 1 文字にマッチします（例: `[rn]` は `r` または `n` の 1 文字）。

**5-2**: 両方にマッチします。`[rn]` は先頭の 1 文字が `r` または `n` であることを意味し、`report.txt` は `r` で、`notes.txt` は `n` で始まるため、続く `*.txt` の部分（任意の文字列 + `.txt`）にもそれぞれ一致します。

**5-3**: シェル自身が glob pattern をファイル名のリストに展開してから `tar` に渡します（この仕組みを pathname expansion と呼びます）。`echo project/*.csv` を実行すると、`tar` を介さずに `data1.csv data2.csv` のようにシェルが展開した結果がそのまま表示されることで確認できます。

</details>