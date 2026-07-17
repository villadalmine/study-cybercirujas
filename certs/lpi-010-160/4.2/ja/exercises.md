# Topic 4.2: Understanding Computer Hardware — ガイド付き演習

**対象認定**: LPI Linux Essentials (010-160, v1.6)
**トピック重み**: 2
**参考資料**: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/

この演習では、Linuxシステム上で実際にコマンドを実行しながら、CPU・RAM・storage・PCIデバイス・USBデバイスなどの computer hardware をどのように確認し、どのように Linux kernel がそれらを認識するかを学びます。ターミナル(shell)が使える Linux 環境で進めてください。root権限が必要なコマンドには `sudo` を使用してください。

---

## 演習1: CPUの情報を確認する

1. ターミナルを開き、以下のコマンドを実行して CPU の概要情報を表示します。

   ```bash
   lscpu
   ```

2. 出力の中から、以下の項目を確認してください。
   - `Architecture`(例: x86_64, aarch64)
   - `CPU(s)`(論理コア数)
   - `Model name`
   - `CPU MHz` または `CPU max MHz`

3. より詳細な raw 情報を、kernel が公開している pseudo file から確認します。

   ```bash
   cat /proc/cpuinfo
   ```

4. `/proc/cpuinfo` の出力を `grep` で絞り込み、物理コア数(`physical id`)や論理プロセッサ数(`processor`)を数えてみます。

   ```bash
   grep -c ^processor /proc/cpuinfo
   ```

**理解度チェック**
- `lscpu` と `cat /proc/cpuinfo` はどちらも CPU 情報を表示しますが、情報の出どころ(データソース)に違いはありますか?
- `/proc` ディレクトリはディスク上の実ファイルではありません。これは何と呼ばれる filesystem ですか?

---

## 演習2: メモリ(RAM)の使用状況を確認する

1. システムに搭載されている RAM の総量と使用状況を、人間が読みやすい単位で表示します。

   ```bash
   free -h
   ```

2. 出力の `total`、`used`、`free`、`available` の各列が何を意味するか確認してください。特に `available` は `free` と異なり、キャッシュを解放すれば実際に使用可能なメモリ量を示す点に注目します。

3. kernel が管理するメモリ情報を、より詳細な raw 形式で確認します。

   ```bash
   cat /proc/meminfo | head -n 5
   ```

4. swap 領域(swap space)のサイズも確認します。

   ```bash
   swapon --show
   ```

**理解度チェック**
- `free -h` の出力で `buff/cache` に分類されているメモリは、アプリケーションがメモリを要求した際に即座に解放されますか?
- swap space はどのような種類の hardware(またはファイル)上に作成されますか?

---

## 演習3: storageデバイス(ディスク)を確認する

1. システムに接続されているブロックデバイス(block device)、つまりディスクやパーティションの一覧を階層構造で表示します。

   ```bash
   lsblk
   ```

2. 出力の `NAME`、`SIZE`、`TYPE`(disk/part/rom など)、`MOUNTPOINT` の各列を確認してください。

3. 各パーティションの使用済み容量と空き容量を表示します。

   ```bash
   df -h
   ```

4. ディスクが SATA/PATA/USB のどの接続方式(interface)で認識されているかを確認するため、以下も実行してみます。

   ```bash
   lsblk -o NAME,TRAN,SIZE,MODEL
   ```

   `TRAN` 列には `sata`、`usb`、`nvme` などが表示されます。

**理解度チェック**
- `lsblk` の `TYPE` が `rom` と表示されるデバイスは、一般的にどのような hardware ですか?
- `df -h` と `lsblk` はどちらもストレージ関連の情報を出すコマンドですが、それぞれ何を基準に情報を表示していますか(filesystem 単位か、device 単位か)?

---

## 演習4: PCI / PCIeデバイスを確認する

1. マザーボード上の PCI/PCIe バスに接続されているデバイス(グラフィックカード、ネットワークカードなど)を一覧表示します。

   ```bash
   lspci
   ```

2. 出力の各行にある bus番号(例: `00:02.0`)、デバイスクラス(`VGA compatible controller` など)、ベンダー名・製品名を確認します。

3. より詳細な情報(kernel driver が使用されているか含む)を確認します。

   ```bash
   lspci -k
   ```

   `Kernel driver in use:` の行に注目し、そのデバイスがどの driver によって制御されているかを確認してください。

**理解度チェック**
- `lspci -k` で表示される `Kernel driver in use` は何を意味しますか? もし driver が表示されない場合、そのデバイスはどうなっている可能性がありますか?
- PCIe は PCI と比べてどのような特徴を持つ接続規格ですか(bus 共有 vs. point-to-point など、一般論として)?

---

## 演習5: USBデバイスと hotplug / coldplug の違いを確認する

1. 現在接続されている USB デバイスの一覧を表示します。

   ```bash
   lsusb
   ```

2. 何か USB デバイス(USBメモリ、マウスなど)を今から接続してください。接続する前に、次のコマンドを別のターミナルで実行しておき、kernel が新しいデバイスを検出する様子をリアルタイムで観察します。

   ```bash
   sudo dmesg -w
   ```

3. USB デバイスを接続した瞬間、`dmesg -w` の出力に新しい行が追加されることを確認してください(例: `usb 1-2: new high-speed USB device number ... `)。これが **hotplug**(システム稼働中に接続してもすぐ認識されるデバイス)の実例です。

4. `Ctrl+C` で `dmesg -w` を終了し、再度 `lsusb` を実行して、新しいデバイスが一覧に追加されたことを確認します。

**理解度チェック**
- hotplug デバイスと coldplug デバイスの違いは何ですか? CPU やマザーボード上の RAM モジュールはどちらに分類されますか?
- なぜ USB デバイスは典型的な hotplug デバイスの例とされるのですか?

---

## 演習6: システム全体のハードウェア概要を確認する

1. カーネルバージョンとシステムアーキテクチャを一括表示します。

   ```bash
   uname -a
   ```

2. システム起動時に kernel が検出した全ハードウェアメッセージのログを確認します(演習5でも使用しましたが、ここでは起動時のログ全体を見ます)。

   ```bash
   dmesg | less
   ```

3. `dmesg` の出力を `grep` でフィルタし、特定の hardware に関するメッセージだけを抜き出してみます(例: memory 関連)。

   ```bash
   dmesg | grep -i memory
   ```

**理解度チェック**
- `dmesg` の出力はシステムを再起動すると、通常どうなりますか(永続化されるか、消えるか)?
- `uname -a` はどのような情報を提供し、これはどのようなときに役立ちますか(例: driver の互換性確認など)?

---

<details>
<summary>解答例(クリックして展開)</summary>

**演習1**
- `lscpu` は kernel および `/proc/cpuinfo` などから情報を整形して表示するコマンドで、人間が読みやすい要約形式です。`cat /proc/cpuinfo` はより低レベルで、論理プロセッサごとの生(raw)データを表示します。データソース自体は共通していますが、`lscpu` は集約・整形されたビューを提供します。
- `/proc` は **procfs** と呼ばれる仮想ファイルシステム(virtual filesystem)で、ディスク上に実体を持たず、kernel が実行時の情報をファイルの形で公開しています。

**演習2**
- いいえ。`buff/cache` に分類されたメモリは、performance向上のために kernel が保持しているキャッシュであり、アプリケーションが追加のメモリを必要とした場合には即座に解放されて再利用されます。そのため `free` 列だけでなく `available` 列を見るべきです。
- swap space は、通常ディスク上の専用パーティション(swap partition)、または swap file として作成されます。物理的な RAM ではなく storage devices 上に確保される点がポイントです。

**演習3**
- `TYPE` が `rom` のデバイスは、一般的に CD/DVD などの光学ドライブ(optical drive)です。
- `lsblk` はブロックデバイス(disk、partitionなどの device 単位)の構造を階層的に表示するのに対し、`df -h` はマウントされている filesystem 単位で使用容量・空き容量を表示します。両者は視点(deviceかfilesystemか)が異なります。

**演習4**
- `Kernel driver in use` は、そのPCIデバイスを現在制御している kernel module(driver)の名前を示します。driver が表示されない場合、そのデバイス用の driver が読み込まれていない、または適切な driver がシステムにインストールされていない可能性があります。
- PCIe は PCI と異なり、共有バス方式ではなく point-to-point のシリアル接続(serial, lane構成)を採用しており、一般的に PCI よりも高い転送速度(higher bandwidth)を実現します。

**演習5**
- hotplug デバイスはシステム稼働中(実行中)に接続・切断してもOSがすぐに認識できるデバイスです。coldplug デバイスはシステム起動時にのみ認識され、稼働中の抜き差しに対応していないデバイスです。CPUやRAMモジュールは一般的に coldplug デバイスに分類されます(稼働中に交換することを前提としていないため)。
- USB規格自体が電気的・ソフトウェア的に稼働中の抜き差しをサポートするよう設計されており、kernel の udev サブシステムがデバイスの接続・切断イベントを即座に検出して driver を自動的に読み込む仕組みになっているためです。

**演習6**
- 通常、`dmesg` の内容はメモリ上の kernel ring buffer に保持されているだけなので、再起動すると内容は消えます(永続的なログとして残したい場合は `journalctl -k` などpersistentな仕組みを別途利用します)。
- `uname -a` はカーネル名、hostname、kernel release/versionバージョン、machine architecture(例: x86_64)などを表示します。これは、特定の driver やソフトウェアがそのシステムのカーネルバージョンやアーキテクチャと互換性があるかを確認する際に役立ちます。

</details>