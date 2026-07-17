# 4.2 Understanding Computer Hardware

## Visão geral

Um sistema Linux roda sobre componentes físicos que o kernel precisa reconhecer e gerenciar: processador, memória, armazenamento, placa-mãe, fonte de alimentação e periféricos. Este tema apresenta esses componentes e as ferramentas de linha de comando que o Linux oferece para inspecioná-los — habilidade essencial para diagnosticar problemas, planejar upgrades e entender mensagens do sistema.

---

## Componentes principais do hardware

### Motherboard (placa-mãe)

A **motherboard** é a placa de circuito que interconecta todos os componentes. Nela ficam:

- O **socket** do processador (CPU).
- Os slots de memória **RAM** (normalmente **DIMM**).
- Os barramentos de expansão, hoje dominados pelo **PCI Express (PCIe)**.
- Controladoras de armazenamento (**SATA**, **NVMe** via M.2) e portas externas (**USB**, rede, vídeo).
- O **firmware** (**BIOS** legado ou **UEFI**, o padrão moderno), que inicializa o hardware e entrega o controle ao *bootloader* do sistema operacional.

O firmware é o primeiro software executado ao ligar a máquina. Sistemas **UEFI** trazem recursos como **Secure Boot** e suporte a discos com tabela de partição **GPT**, enquanto o **BIOS** clássico usa **MBR**.

### CPU (processador)

A **CPU** (*Central Processing Unit*) executa as instruções dos programas. Conceitos importantes:

- **Arquitetura**: define o conjunto de instruções. As mais comuns são **x86_64** (também chamada **amd64**, usada em desktops e servidores) e **ARM/aarch64** (celulares, Raspberry Pi, servidores modernos).
- **Cores**: um processador moderno tem vários núcleos, cada um capaz de executar tarefas em paralelo.
- **Threads**: com tecnologias como *simultaneous multithreading* (SMT/Hyper-Threading), cada core pode apresentar dois threads lógicos ao sistema.
- **32 bits vs 64 bits**: sistemas de 64 bits endereçam muito mais memória; um kernel de 64 bits executa binários de 32 bits, mas não o contrário.

No Linux, as informações da CPU ficam expostas no arquivo virtual `/proc/cpuinfo`:

```bash
$ cat /proc/cpuinfo | head -n 10
processor       : 0
vendor_id       : GenuineIntel
cpu family      : 6
model           : 142
model name      : Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz
stepping        : 10
microcode       : 0xf4
cpu MHz         : 1800.000
cache size      : 6144 KB
physical id     : 0
```

Cada core lógico aparece como um bloco `processor` separado. O comando `lscpu` resume tudo de forma mais legível:

```bash
$ lscpu
Architecture:            x86_64
CPU op-mode(s):          32-bit, 64-bit
CPU(s):                  8
Thread(s) per core:      2
Core(s) per socket:      4
Model name:              Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz
```

### Memória RAM

A **RAM** (*Random Access Memory*) é a memória de trabalho: rápida, mas **volátil** — o conteúdo se perde ao desligar. Os módulos físicos são pentes **DIMM** (ou **SO-DIMM** em notebooks) das gerações **DDR3**, **DDR4**, **DDR5**.

O comando `free` mostra o uso atual (a opção `-h`, *human-readable*, formata em MiB/GiB):

```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4,2Gi       6,1Gi       512Mi       5,0Gi        10Gi
Swap:          2,0Gi          0B       2,0Gi
```

Pontos que costumam cair em prova:

- **buff/cache**: memória usada pelo kernel para cache de disco; é liberada automaticamente quando os programas precisam. Por isso a coluna **available** é o indicador real de memória disponível, não **free**.
- **Swap**: área em disco usada como extensão da RAM quando ela se esgota. Pode ser uma **swap partition** ou um **swap file**. É muito mais lenta que a RAM.

Os mesmos dados brutos estão em `/proc/meminfo`:

```bash
$ head -n 3 /proc/meminfo
MemTotal:       16284856 kB
MemFree:         6399124 kB
MemAvailable:   10905232 kB
```

### Armazenamento (storage)

Os dispositivos de armazenamento são **persistentes** (mantêm os dados sem energia). Tipos principais:

| Tipo | Característica |
|------|----------------|
| **HDD** (*Hard Disk Drive*) | Pratos magnéticos giratórios; barato por GB, mais lento e sensível a impactos |
| **SSD** (*Solid State Drive*) | Memória flash, sem partes móveis; muito mais rápido que HDD |
| **NVMe** | SSD conectado direto ao barramento **PCIe** (formato **M.2**); latência mínima e altíssima velocidade |
| Mídia óptica (**CD/DVD/Blu-ray**) | Leitura via laser; hoje usada quase só para instalação ou arquivamento |
| **USB flash drive / SD card** | Flash removível, comum para instalação e transferência |

No Linux, cada dispositivo aparece como um arquivo em `/dev`:

- `/dev/sda`, `/dev/sdb`, ... — discos **SATA/SCSI/USB** (a letra identifica o disco).
- `/dev/sda1`, `/dev/sda2`, ... — as **partitions** dentro do disco.
- `/dev/nvme0n1` — primeiro SSD **NVMe**; suas partições são `/dev/nvme0n1p1`, `p2`, etc.
- `/dev/sr0` — unidade óptica.

O comando `lsblk` lista os *block devices* e suas partições em árvore:

```bash
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda           8:0    0 931,5G  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
├─sda2        8:2    0   900G  0 part /
└─sda3        8:3    0    31G  0 part [SWAP]
nvme0n1     259:0    0 465,8G  0 disk
└─nvme0n1p1 259:1    0 465,8G  0 part /home
```

A lista de partições reconhecidas pelo kernel também está em `/proc/partitions`.

**Particionamento**: um disco é dividido em **partitions**, cada uma formatada com um **filesystem** (ext4, XFS, Btrfs...). O esquema de particionamento pode ser **MBR** (legado, máximo de 4 partições primárias e discos até 2 TiB) ou **GPT** (moderno, usado com UEFI, sem essas limitações).

### Fonte de alimentação (power supply)

A **PSU** (*Power Supply Unit*) converte a corrente alternada da tomada em corrente contínua nas tensões que os componentes exigem (12 V, 5 V, 3,3 V). A potência (em watts) deve ser dimensionada para o conjunto — GPUs dedicadas são geralmente o maior consumidor. Em notebooks e dispositivos móveis, a bateria cumpre esse papel; o Linux expõe seu estado em `/sys/class/power_supply/`.

### Periféricos

**Peripherals** são dispositivos conectados externamente: teclado, mouse, impressora, webcam, monitores. A interface dominante é o **USB**. O comando `lsusb` lista os dispositivos USB detectados:

```bash
$ lsusb
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 001 Device 004: ID 04f2:b604 Chicony Electronics Co., Ltd Integrated Camera
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
```

Já os dispositivos internos conectados ao barramento **PCI/PCIe** (placa de vídeo, placa de rede, controladoras) são listados com `lspci`:

```bash
$ lspci
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620
00:14.0 USB controller: Intel Corporation Sunrise Point-LP USB 3.0 xHCI Controller
02:00.0 Network controller: Intel Corporation Wireless 8265 / 8275
```

Ambos aceitam `-v` (*verbose*) para detalhes adicionais, como o **driver** em uso.

---

## Drivers e como o kernel enxerga o hardware

Um **driver** é o código que ensina o kernel a conversar com um dispositivo específico. No Linux, a maioria dos drivers vem como **kernel modules**, carregados sob demanda:

```bash
$ lsmod | head -n 4
Module                  Size  Used by
iwlmvm                389120  0
btusb                  65536  0
uvcvideo              114688  0
```

O kernel expõe seu conhecimento do hardware por meio de dois *pseudo-filesystems* montados em memória (não ocupam disco):

- **`/proc`** — informações de processos e do sistema: `/proc/cpuinfo`, `/proc/meminfo`, `/proc/partitions`.
- **`/sys`** — visão estruturada dos dispositivos e drivers: por exemplo, `/sys/class/net/` lista as interfaces de rede.

As mensagens do kernel ao detectar hardware (útil ao conectar um pendrive, por exemplo) são vistas com `dmesg` (requer privilégios em muitas distribuições):

```bash
$ sudo dmesg | tail -n 3
[9042.312] usb 1-2: new high-speed USB device number 7 using xhci_hcd
[9042.470] usb-storage 1-2:1.0: USB Mass Storage device detected
[9043.501]  sdb: sdb1
```

---

## Resumo dos comandos

| Comando / arquivo | O que mostra |
|-------------------|--------------|
| `lscpu`, `/proc/cpuinfo` | Modelo, arquitetura, cores e threads da CPU |
| `free -h`, `/proc/meminfo` | Uso de RAM e swap |
| `lsblk`, `/proc/partitions` | Discos, partições e pontos de montagem |
| `lspci` | Dispositivos no barramento PCI/PCIe |
| `lsusb` | Dispositivos USB conectados |
| `lsmod` | Kernel modules (drivers) carregados |
| `dmesg` | Mensagens do kernel, incluindo detecção de hardware |

---

## Referências

- LPI Learning Materials — Objetivo 4.2, Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- LPI Linux Essentials — objetivos do exame 010-160 v1.6: https://www.lpi.org/our-certifications/exam-160-objectives/
- Documentação do kernel Linux — `/proc` filesystem: https://docs.kernel.org/filesystems/proc.html
- Documentação do kernel Linux — sysfs: https://docs.kernel.org/filesystems/sysfs.html
- man pages: `man lscpu`, `man lsblk`, `man free`, `man lspci`, `man lsusb`, `man dmesg`