# Archiving Files on the Command Line

## 概要

Linux では、複数のファイルやディレクトリをひとつのファイルにまとめる操作を **archiving**、ファイルサイズを小さくする操作を **compression** と呼びます。この2つはよく混同されますが、別の概念です。

- **Archiving**: 複数のファイル構造（ディレクトリ階層、パーミッション、タイムスタンプなど）を1つのファイルに保存すること。代表的なツールは `tar`。
- **Compression**: データの冗長性を取り除いてサイズを小さくすること。代表的なツールは `gzip`、`bzip2`、`xz`。

`tar` 自体には圧縮機能はありませんが、`gzip` や `bzip2`、`xz` と連携して「アーカイブしてから圧縮する」という一連の処理をワンコマンドで行うオプションが用意されています。この組み合わせがバックアップやソフトウェア配布の定番パターンです。

## tar コマンドの基本

`tar` は "tape archive" に由来する名前で、もともとテープ装置へのバックアップ用に作られました。基本となる3つの動作モードがあります。

| オプション | 意味 |
|---|---|
| `-c` | create（新規アーカイブを作成） |
| `-x` | extract（アーカイブから展開） |
| `-t` | list / table（アーカイブの内容一覧を表示） |

これに加えて、以下のオプションをほぼ常に併用します。

| オプション | 意味 |
|---|---|
| `-v` | verbose（処理中のファイル名を表示） |
| `-f <file>` | 対象となるアーカイブファイル名を指定 |

### アーカイブの作成

```
$ tar -cvf backup.tar docs/
docs/
docs/report.txt
docs/notes.md
```

### アーカイブの内容確認（展開せずに中身を見る）

```
$ tar -tvf backup.tar
drwxr-xr-x user/user       0 2026-07-10 10:00 docs/
-rw-r--r-- user/user    1200 2026-07-10 10:00 docs/report.txt
-rw-r--r-- user/user     340 2026-07-10 10:00 docs/notes.md
```

### アーカイブの展開

```
$ tar -xvf backup.tar
docs/
docs/report.txt
docs/notes.md
```

展開先を変えたい場合は `-C` オプションでディレクトリを指定します。

```
$ tar -xvf backup.tar -C /tmp/restore/
```

特定のファイルだけを展開したい場合は、アーカイブ名の後にパスを指定します。

```
$ tar -xvf backup.tar docs/report.txt
```

## 圧縮と組み合わせた tar

`tar` に圧縮用オプションを渡すと、アーカイブ作成と同時に圧縮まで行えます。

| オプション | 圧縮方式 | 一般的な拡張子 |
|---|---|---|
| `-z` | gzip | `.tar.gz`, `.tgz` |
| `-j` | bzip2 | `.tar.bz2` |
| `-J` | xz | `.tar.xz` |

```
$ tar -czvf backup.tar.gz docs/
$ tar -cjvf backup.tar.bz2 docs/
$ tar -cJvf backup.tar.xz docs/

$ ls -lh backup.tar*
-rw-r--r-- 1 user user  12K backup.tar
-rw-r--r-- 1 user user 4.1K backup.tar.gz
-rw-r--r-- 1 user user 3.6K backup.tar.bz2
-rw-r--r-- 1 user user 3.2K backup.tar.xz
```

一般的な傾向として、**gzip は高速だが圧縮率は低め**、**xz は圧縮率が高いが処理時間がかかる**、**bzip2 はその中間**という特性があります。展開時は `-x` に同じ圧縮オプション（`-z`/`-j`/`-J`）を付けますが、最近の GNU tar は拡張子から圧縮形式を自動判別するため、省略しても動作することが多いです。

```
$ tar -xvf backup.tar.gz
$ tar -xvf backup.tar.xz
```

## 単体の圧縮ツール: gzip / bzip2 / xz

`tar` を使わず、1つのファイルだけを圧縮したい場合はこれらのツールを直接使います。いずれも「元ファイルを圧縮ファイルに置き換える」動作がデフォルトです。

```
$ gzip report.txt
$ ls
report.txt.gz

$ gunzip report.txt.gz
$ ls
report.txt
```

元ファイルを残したい場合は `-k`（keep）オプションを使います。

```
$ gzip -k report.txt
$ ls
report.txt  report.txt.gz
```

圧縮ファイルの中身を展開せずに確認したい場合は `zcat` を使います。

```
$ zcat report.txt.gz
（ファイルの内容がそのまま表示される）
```

`bzip2`/`bunzip2`/`bzcat`、`xz`/`unxz`/`xzcat` もそれぞれ同じ考え方で使えます。

```
$ bzip2 -k report.txt   # report.txt.bz2 を作成
$ xz -k report.txt      # report.txt.xz を作成
```

## zip / unzip

`zip` 形式は Windows や macOS との互換性が高く、他のOSとファイルをやり取りする場面でよく使われます。`tar` と違い、`zip` は圧縮とアーカイブ化を同時に行うのがデフォルトの動作です。

```
$ zip -r archive.zip docs/
  adding: docs/ (stored 0%)
  adding: docs/report.txt (deflated 45%)
  adding: docs/notes.md (deflated 30%)

$ unzip -l archive.zip
Archive:  archive.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-07-10 10:00   docs/
     1200  2026-07-10 10:00   docs/report.txt
      340  2026-07-10 10:00   docs/notes.md

$ unzip archive.zip
```

`-r` はディレクトリを再帰的に含めるオプションです。

## ファイルの整合性確認: md5sum / sha256sum

アーカイブをネットワーク経由で配布・ダウンロードした際、転送中の破損や改ざんがないかを確認するために **checksum**（ハッシュ値）を使います。

```
$ sha256sum backup.tar.gz
3a7bd3e2360a3d... backup.tar.gz

$ sha256sum backup.tar.gz > backup.tar.gz.sha256

$ sha256sum -c backup.tar.gz.sha256
backup.tar.gz: OK
```

もしファイルが壊れていたり改ざんされていた場合は、以下のように表示されます。

```
$ sha256sum -c backup.tar.gz.sha256
backup.tar.gz: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```

`md5sum` も同様の用途で使われますが、MD5 はアルゴリズムとして衝突耐性が弱いため、セキュリティ用途では `sha256sum` や `sha512sum` が推奨されます。ソフトウェア配布サイトでダウンロードファイルのチェックサムが公開されているのはこのためです。

## cpio（補足）

`cpio` は `tar` と同様にアーカイブを作成するツールですが、単体では対象ファイルを指定せず、`find` などからファイル一覧を標準入力で受け取って動作するのが特徴です。

```
$ find docs/ -print | cpio -ov > backup.cpio
docs/
docs/report.txt
docs/notes.md
1 block

$ cpio -idv < backup.cpio
```

現在は `tar` の方が広く使われていますが、`find` と組み合わせた柔軟なファイル選択が必要な場面や、一部のパッケージ形式（例: RPM の内部構造）で `cpio` が使われることがあります。

## コマンド早見表

| 目的 | コマンド例 |
|---|---|
| tar でアーカイブ作成 | `tar -cvf archive.tar dir/` |
| tar + gzip で作成 | `tar -czvf archive.tar.gz dir/` |
| tar + bzip2 で作成 | `tar -cjvf archive.tar.bz2 dir/` |
| tar + xz で作成 | `tar -cJvf archive.tar.xz dir/` |
| tar の内容一覧 | `tar -tvf archive.tar` |
| tar の展開 | `tar -xvf archive.tar` |
| gzip 圧縮（元ファイル保持） | `gzip -k file` |
| gzip 展開 | `gunzip file.gz` |
| zip 作成 | `zip -r archive.zip dir/` |
| zip 展開 | `unzip archive.zip` |
| チェックサム生成 | `sha256sum file > file.sha256` |
| チェックサム検証 | `sha256sum -c file.sha256` |

## 参考資料

- LPI Learning Materials, "3.1 Archiving Files on the Command Line": https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- GNU tar Manual: https://www.gnu.org/software/tar/manual/
- GNU gzip Manual: https://www.gnu.org/software/gzip/manual/gzip.html
- man7.org, tar(1): https://man7.org/linux/man-pages/man1/tar.1.html
- man7.org, gzip(1): https://man7.org/linux/man-pages/man1/gzip.1.html
- man7.org, bzip2(1): https://man7.org/linux/man-pages/man1/bzip2.1.html
- man7.org, xz(1): https://man7.org/linux/man-pages/man1/xz.1.html
- man7.org, sha256sum(1): https://man7.org/linux/man-pages/man1/sha256sum.1.html
- man7.org, cpio(1): https://man7.org/linux/man-pages/man1/cpio.1.html