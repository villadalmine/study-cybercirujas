# LPI Linux Essentials (010-160) — Topic 5.4: Special Directories and Files

*出典（参考のみ、引用は行わない）: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/*

---

## 演習1: FHS（Filesystem Hierarchy Standard）の主要ディレクトリを調べる

1. ターミナルを開き、ルートディレクトリの直下にある項目を一覧表示する。
   ```
   ls -l /
   ```
2. `/etc` ディレクトリの中身を確認する。ここにはシステム全体の設定ファイル（configuration files）が置かれている。
   ```
   ls /etc | head -n 20
   ```
3. `/var` ディレクトリを確認する。ログファイル（`/var/log`）やスプールファイルなど、実行中に内容が変化するデータ（variable data）が保存される。
   ```
   ls /var
   ls /var/log | head -n 10
   ```
4. `/tmp` ディレクトリを確認する。ここは一時ファイル（temporary files）用で、再起動時にクリアされることがある。
   ```
   ls -ld /tmp
   ```
5. `/home` と `/opt` を確認する。`/home` は一般ユーザーの個人ディレクトリ（home directories）、`/opt` はディストリビューションパッケージ管理外の追加ソフトウェア（optional add-on software）用である。
   ```
   ls /home
   ls /opt
   ```

**確認問題**
- `/etc` と `/var` の役割の違いを、それぞれに保存されるデータの性質（静的か動的か）の観点から説明してください。
- あるアプリケーションを手動でパッケージマネージャーを使わずにインストールした場合、FHS の慣習に従うとどのディレクトリに配置するのが適切ですか。

---

## 演習2: `/dev` にある special files（デバイスファイル）を調べる

1. `/dev` ディレクトリの内容を詳細表示する。
   ```
   ls -l /dev | head -n 20
   ```
2. 出力の先頭のパーミッション欄に注目する。通常のファイルは `-`、ディレクトリは `d` で始まるが、デバイスファイルは `b`（block device）または `c`（character device）で始まる行がある。該当する行を探す。
   ```
   ls -l /dev | grep -E '^[bc]'
   ```
3. ブロックデバイス（block device）の例として、ディスクデバイスを確認する。
   ```
   ls -l /dev/sda 2>/dev/null || ls -l /dev/vda 2>/dev/null || ls -l /dev/nvme0n1 2>/dev/null
   ```
4. キャラクターデバイス（character device）の例として、端末デバイスとヌルデバイスを確認する。
   ```
   ls -l /dev/tty
   ls -l /dev/null
   ```
5. `file` コマンドで `/dev/null` の種類を確認する。
   ```
   file /dev/null
   ```

**確認問題**
- block device と character device の基本的な違いは何ですか（データの読み書きの単位という観点で）。
- `ls -l` の出力で block device の行にはどの数値情報が、通常のファイルサイズの代わりに表示されますか。

---

## 演習3: `/proc` 仮想ファイルシステム（virtual filesystem）を調べる

1. `/proc` の中身を一覧表示する。数字だけの名前のディレクトリが並んでいるはずである。
   ```
   ls /proc | head -n 20
   ```
2. これらの数字のディレクトリが何を表しているか確認するために、現在実行中のシェルの PID（process ID）を調べる。
   ```
   echo $$
   ls /proc/$$
   ```
3. CPU 情報を表示する仮想ファイルを読む。
   ```
   cat /proc/cpuinfo
   ```
4. メモリ使用状況を表示する仮想ファイルを読む。
   ```
   cat /proc/meminfo
   ```
5. これらのファイルのサイズを `ls -l` で確認する。
   ```
   ls -l /proc/cpuinfo
   ```

**確認問題**
- `/proc` 以下のファイルは実際のディスク上に存在するデータではありません。それでは何のデータをリアルタイムに反映していますか。
- `ls -l /proc/cpuinfo` で表示されるファイルサイズが `0` になっていることがあります。これは何を意味しますか。

---

## 演習4: ハードリンク（hard link）を作成して検証する

1. 作業用ディレクトリを作成して移動する。
   ```
   mkdir ~/links-lab && cd ~/links-lab
   ```
2. オリジナルファイルを作成する。
   ```
   echo "original content" > original.txt
   ```
3. `original.txt` の inode 番号を確認する。
   ```
   ls -i original.txt
   ```
4. ハードリンクを作成する。
   ```
   ln original.txt hardlink.txt
   ```
5. 両方のファイルの inode 番号とリンクカウント（link count）を確認する。
   ```
   ls -li original.txt hardlink.txt
   ```
6. `hardlink.txt` の内容を変更し、`original.txt` にも反映されることを確認する。
   ```
   echo "modified via hardlink" >> hardlink.txt
   cat original.txt
   ```
7. `original.txt` を削除し、`hardlink.txt` がまだ内容を保持していることを確認する。
   ```
   rm original.txt
   cat hardlink.txt
   ls -li hardlink.txt
   ```

**確認問題**
- 手順5で表示された2つの inode 番号は一致しますか。それはなぜですか。
- 手順7で `original.txt` を削除した後も `hardlink.txt` の内容が失われなかった理由を、inode とリンクカウントの関係から説明してください。

---

## 演習5: シンボリックリンク（symbolic link）を作成して検証する

1. 引き続き `~/links-lab` にいることを確認する。新しいオリジナルファイルを作成する。
   ```
   cd ~/links-lab
   echo "symlink target content" > target.txt
   ```
2. シンボリックリンクを作成する。
   ```
   ln -s target.txt symlink.txt
   ```
3. `ls -l` でシンボリックリンクの表示を確認する。パーミッション欄が `l` で始まり、リンク先（target）への矢印が表示されるはずである。
   ```
   ls -l symlink.txt
   ```
4. `ls -i` で `target.txt` と `symlink.txt` の inode 番号を比較する。
   ```
   ls -i target.txt symlink.txt
   ```
5. `symlink.txt` 経由で内容を読む。
   ```
   cat symlink.txt
   ```
6. `target.txt` を削除し、`symlink.txt` にアクセスするとどうなるか確認する（broken link の状態）。
   ```
   rm target.txt
   cat symlink.txt
   ls -l symlink.txt
   ```

**確認問題**
- 演習4の inode 番号（ハードリンク）と本演習の inode 番号（シンボリックリンク）を比較すると、それぞれどのような結果になりましたか。
- 手順6でリンク先を削除した後、`symlink.txt` はディスク上に存在し続けますか。それは何と呼ばれる状態ですか。

---

## 演習6: ハードリンクとシンボリックリンクの制約を比較する

1. 新しいディレクトリを作成し、そこに対してハードリンクを作成しようとする。
   ```
   cd ~/links-lab
   mkdir subdir
   ln subdir subdir-hardlink 2>&1
   ```
2. 同じディレクトリに対してシンボリックリンクを作成する。
   ```
   ln -s subdir subdir-symlink
   ls -l subdir-symlink
   ```
3. `/tmp` にファイルを作り、異なるファイルシステム（例えば `/tmp` が別パーティションや tmpfs の場合）をまたいでハードリンクを作成しようとする。
   ```
   echo "cross fs test" > /tmp/crossfs.txt
   ln /tmp/crossfs.txt ~/links-lab/crossfs-hardlink.txt 2>&1
   ```
4. 同じ操作をシンボリックリンクで試す。
   ```
   ln -s /tmp/crossfs.txt ~/links-lab/crossfs-symlink.txt
   ls -l crossfs-symlink.txt
   cat crossfs-symlink.txt
   ```

**確認問題**
- 手順1でディレクトリに対するハードリンク作成が拒否された（または特別な扱いになった）理由は何ですか。
- 手順3と手順4の結果を比較し、異なるファイルシステム間でのリンク作成についてハードリンクとシンボリックリンクにどのような違いがあるか説明してください。

---

<details>
<summary>解答（クリックして展開）</summary>

**演習1**
- `/etc` は基本的に変更頻度の低い静的な設定ファイル（configuration files）を保持する。一方 `/var` はログ、メール、スプール、キャッシュなど、システム稼働中に内容が増減・変化する可変データ（variable data）を保持する。
- パッケージマネージャーを使わずに手動でインストールした追加ソフトウェアは、FHS の慣習では `/opt` に配置するのが適切である。

**演習2**
- block device はディスクのようにランダムアクセス可能な固定サイズのブロック単位でデータを読み書きするデバイスである。character device はキーボードや端末、`/dev/null` のように、データをストリーム（バイト単位の連続した流れ）として読み書きするデバイスである。
- block device の行にはファイルサイズの代わりに、メジャー番号（major number）とマイナー番号（minor number）が表示される。これらはデバイスドライバとデバイスの識別に使われる。

**演習3**
- `/proc` はカーネル（kernel）が管理する実行中のプロセスやシステムの状態をリアルタイムに反映する仮想ファイルシステムである。ディスク上には実体を持たず、読み取り時にカーネルがその場で内容を生成する。
- サイズが `0` と表示されるのは、これらのファイルが通常のファイルのように固定サイズのデータを持つのではなく、アクセスされた瞬間にカーネルが動的に内容を生成するためである。

**演習4**
- 一致する。`ln`（オプションなし）はハードリンクを作成し、新しい名前は元のファイルと同じ inode を指すためである。両者は同一のデータ実体への別名（別のディレクトリエントリ）にすぎない。
- ハードリンクはファイル名ではなく inode（実データとメタデータ）を直接指しており、各 inode はリンクカウント（そのinodeを指しているディレクトリエントリの数）を保持している。`rm original.txt` はディレクトリエントリを1つ削除してリンクカウントを減らすだけで、リンクカウントが0になるまでデータ本体は解放されない。`hardlink.txt` が存在する限りリンクカウントは1以上なので、データは保持される。

**演習5**
- ハードリンクでは元ファイルとリンクの inode 番号が一致したのに対し、シンボリックリンクでは `target.txt` と `symlink.txt` は異なる inode 番号を持つ。シンボリックリンクはデータ本体を指す別のポインタではなく、パス文字列（リンク先のパス名）を内容として持つ独立したファイルだからである。
- `symlink.txt` 自体はディスク上に存在し続けるが、指し示す先のファイルが存在しないため、アクセスすると「そのようなファイルやディレクトリはありません」といったエラーになる。この状態は broken link（dangling link）と呼ばれる。

**演習6**
- ディレクトリに対するハードリンクは、ファイルシステムの循環参照（loop）を防ぐため、一般ユーザーには許可されていない（多くのシステムでは `.` や `..` 以外は root でも制限される）。このためエラーになるか、操作が拒否される。
- ハードリンクは同一の inode を直接参照する仕組み上、同じファイルシステム（同じパーティション）内でしか作成できない。異なるファイルシステム間ではエラーになる。一方シンボリックリンクは単にパス文字列を保持するだけなので、ファイルシステムをまたいでも問題なく作成・利用できる。

</details>