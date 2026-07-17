# Exercícios Guiados — Tema 4.2: Understanding Computer Hardware

> Estes exercícios acompanham o estudo do tema 4.2 do exame LPI Linux Essentials (010-160, versão 1.6). Você vai precisar de um terminal em qualquer distribuição Linux. Nenhum comando abaixo altera o sistema: todos são apenas de leitura.
>
> Fonte de referência: [LPI Learning Materials — 4.2 Understanding Computer Hardware](https://learning.lpi.org/en/learning-materials/010-160/4/4.2/)

---

## Exercício 1 — Identificando o processador (CPU)

O **CPU** (Central Processing Unit) é o componente que executa as instruções dos programas. No Linux, o kernel expõe informações sobre ele através do pseudo-filesystem `/proc` e de utilitários como `lscpu`.

1. Abra um terminal e execute:

   ```bash
   lscpu
   ```

   Observe as linhas `Architecture`, `CPU(s)`, `Model name` e, se existirem, `Thread(s) per core` e `Core(s) per socket`.

2. Agora consulte a fonte "crua" dessas informações:

   ```bash
   cat /proc/cpuinfo | less
   ```

   Navegue com as setas e saia com `q`. Repare que cada processador lógico aparece como um bloco separado começando com `processor : N`.

3. Conte quantos processadores lógicos o kernel enxerga:

   ```bash
   grep -c '^processor' /proc/cpuinfo
   ```

**Perguntas:**

- **1.1** — Qual é a diferença entre um *core* físico e um processador lógico (*thread*)? Por que o número mostrado no passo 3 pode ser o dobro do número de *cores*?
- **1.2** — A linha `Architecture` mostrou algo como `x86_64` ou `aarch64`. O que essa informação diz sobre os programas que podem rodar nessa máquina?
- **1.3** — `/proc/cpuinfo` é um arquivo gravado no disco? Justifique.

---

## Exercício 2 — Memória RAM e swap

A **RAM** (Random Access Memory) é a memória volátil de trabalho: rápida, mas perde o conteúdo ao desligar. O **swap** é um espaço em disco usado como extensão da RAM quando ela se esgota.

1. Veja o resumo de memória em formato legível:

   ```bash
   free -h
   ```

   Identifique as colunas `total`, `used`, `free` e `available`, e as linhas `Mem:` e `Swap:`.

2. Consulte a fonte detalhada dessas informações:

   ```bash
   head -n 5 /proc/meminfo
   ```

3. Verifique quais dispositivos ou arquivos estão sendo usados como swap:

   ```bash
   cat /proc/swaps
   ```

**Perguntas:**

- **2.1** — Por que o valor de `free` costuma ser bem menor que o de `available`? O que o kernel está fazendo com essa memória "ocupada"?
- **2.2** — O que acontece com o desempenho do sistema quando ele passa a usar swap intensamente, e por quê?
- **2.3** — Se você desligar o computador, o que acontece com os dados que estavam na RAM? E com os dados no disco?

---

## Exercício 3 — Discos, partições e tipos de armazenamento

O armazenamento persistente pode ser um **HDD** (Hard Disk Drive, com pratos magnéticos que giram) ou um **SSD** (Solid State Drive, com memória flash, sem partes móveis). Os discos são divididos em **partitions**, e cada partição recebe um **filesystem**.

1. Liste os dispositivos de bloco do sistema:

   ```bash
   lsblk
   ```

   Observe a hierarquia: um disco (por exemplo `sda` ou `nvme0n1`) com partições dentro (`sda1`, `nvme0n1p1`...). A coluna `MOUNTPOINT`/`MOUNTPOINTS` mostra onde cada partição está montada.

2. Verifique se cada disco é rotacional (HDD) ou não (SSD):

   ```bash
   lsblk -d -o NAME,SIZE,ROTA,TYPE
   ```

   Na coluna `ROTA`, o valor `1` indica disco rotacional e `0` indica estado sólido.

3. Veja o espaço em uso nos filesystems montados:

   ```bash
   df -h
   ```

**Perguntas:**

- **3.1** — No seu sistema, qual dispositivo contém a partição montada em `/` (raiz)? Ele é HDD ou SSD segundo a coluna `ROTA`?
- **3.2** — Cite duas vantagens de um SSD sobre um HDD e uma situação em que o HDD ainda pode ser preferível.
- **3.3** — Qual é a diferença entre um disco (`sda`) e uma partição (`sda1`)? É possível ter um filesystem diferente em cada partição do mesmo disco?

---

## Exercício 4 — Dispositivos PCI e USB (periféricos)

Placas de vídeo, controladoras de rede e de armazenamento normalmente ficam no barramento **PCI/PCIe**; teclados, mouses, webcams e pendrives usam o barramento **USB**.

1. Liste os dispositivos PCI:

   ```bash
   lspci
   ```

   Procure entradas contendo `VGA` ou `Display` (vídeo), `Ethernet` ou `Network` (rede) e `SATA`/`NVMe` (armazenamento).

2. Liste os dispositivos USB:

   ```bash
   lsusb
   ```

3. Se você tiver um pendrive ou mouse USB à mão, conecte-o e rode `lsusb` de novo, comparando as duas saídas. Depois veja como o kernel registrou o evento:

   ```bash
   sudo dmesg | tail -n 20
   ```

   (Se `sudo` não estiver disponível, apenas compare as saídas de `lsusb`.)

**Perguntas:**

- **4.1** — Que tipo de informação aparece em cada linha de `lsusb` (por exemplo `Bus 001 Device 003: ID 8087:0025 ...`)?
- **4.2** — Um adaptador Wi-Fi pode aparecer tanto em `lspci` quanto em `lsusb`. Do que isso depende?
- **4.3** — Para que serve o comando `dmesg` no contexto de hardware?

---

## Exercício 5 — Drivers e módulos do kernel

Um **driver** é o software que ensina o kernel a conversar com um dispositivo. No Linux, muitos drivers são carregados dinamicamente como **kernel modules**.

1. Liste os módulos carregados no momento:

   ```bash
   lsmod | head -n 15
   ```

2. Escolha um módulo da lista (por exemplo, um cujo nome lembre rede ou som) e consulte seus detalhes:

   ```bash
   modinfo nome_do_modulo
   ```

   Observe os campos `description`, `filename` e `depends`.

3. Veja como `/sys` expõe os dispositivos e seus drivers. Por exemplo, para dispositivos de bloco:

   ```bash
   ls /sys/block/
   ```

**Perguntas:**

- **5.1** — Qual é a vantagem de carregar drivers como módulos, em vez de compilar tudo dentro do kernel?
- **5.2** — Segundo a saída de `modinfo`, onde os arquivos de módulo ficam armazenados no disco (caminho aproximado)?
- **5.3** — Qual é a diferença de propósito entre `/proc` e `/sys`?

---

## Exercício 6 — Juntando tudo: inventário rápido da máquina

1. Monte um mini-inventário do seu sistema executando, em sequência:

   ```bash
   lscpu | grep 'Model name'
   free -h | grep Mem
   lsblk -d -o NAME,SIZE,ROTA
   lspci | grep -i -E 'vga|3d|display'
   ```

2. Anote em um papel (ou arquivo de texto) quatro linhas: modelo de CPU, total de RAM, discos com tipo (HDD/SSD) e placa de vídeo. Esse é o tipo de levantamento que um técnico faz antes de decidir um upgrade.

**Perguntas:**

- **6.1** — Se essa máquina estivesse lenta ao abrir muitos programas ao mesmo tempo, e `free -h` mostrasse swap em uso constante, qual componente seria o candidato natural a upgrade?
- **6.2** — Cite mais dois componentes de hardware que fazem parte de um computador mas que não apareceram diretamente nos comandos acima.

---

<details>
<summary><strong>Respostas</strong></summary>

### Exercício 1

- **1.1** — Um *core* físico é uma unidade de processamento completa dentro do chip. Com tecnologias como **SMT** (Simultaneous Multithreading, chamada de Hyper-Threading pela Intel), cada core físico pode executar dois fluxos de instruções, aparecendo para o kernel como dois processadores lógicos. Por isso `grep -c '^processor'` pode retornar o dobro do número de cores.
- **1.2** — Indica o conjunto de instruções (ISA) do processador. Um binário compilado para `x86_64` não roda nativamente em `aarch64` (ARM 64 bits) e vice-versa; os pacotes de software precisam corresponder à arquitetura da máquina.
- **1.3** — Não. `/proc` é um pseudo-filesystem gerado em tempo real pelo kernel, na memória. Os "arquivos" são apenas uma interface de leitura para o estado atual do sistema; nada disso ocupa espaço em disco.

### Exercício 2

- **2.1** — O kernel usa a RAM ociosa como *cache* de disco (buffers/cache) para acelerar leituras futuras. Essa memória conta como "usada", mas pode ser liberada imediatamente se um programa precisar dela — por isso `available` (memória realmente disponível para novos processos) é maior que `free`.
- **2.2** — O sistema fica muito mais lento, porque o disco (mesmo um SSD) é ordens de magnitude mais lento que a RAM. Mover páginas de memória entre RAM e swap constantemente (*thrashing*) degrada o desempenho de todo o sistema.
- **2.3** — A RAM é volátil: todo o conteúdo se perde ao cortar a energia. O disco (HDD ou SSD) é armazenamento persistente: os dados permanecem após o desligamento.

### Exercício 3

- **3.1** — Depende da máquina: procure na saída de `lsblk` a partição com `MOUNTPOINT` igual a `/` e suba na hierarquia até o disco pai; a coluna `ROTA` desse disco indica `0` (SSD) ou `1` (HDD).
- **3.2** — Vantagens do SSD: acesso muito mais rápido (sem latência mecânica), silêncio, menor consumo e maior resistência a impactos, por não ter partes móveis. O HDD ainda pode ser preferível quando se precisa de muita capacidade por um custo baixo, como em backups e armazenamento em massa.
- **3.3** — O disco é o dispositivo físico inteiro; a partição é uma subdivisão lógica dele, definida na tabela de partições (MBR ou GPT). Sim: cada partição pode ter um filesystem diferente (por exemplo, `sda1` com ext4 e `sda2` com swap ou FAT32).

### Exercício 4

- **4.1** — O barramento (`Bus`) e a posição do dispositivo nele (`Device`), seguidos do `ID` no formato `vendor:product` (identificadores do fabricante e do modelo) e de uma descrição textual do dispositivo.
- **4.2** — Da forma como o adaptador está conectado fisicamente: uma placa Wi-Fi interna ligada ao barramento PCIe aparece em `lspci`; um adaptador Wi-Fi espetado numa porta USB aparece em `lsusb`.
- **4.3** — `dmesg` mostra o *ring buffer* de mensagens do kernel. É onde aparecem os registros de detecção de hardware — por exemplo, quando um pendrive é conectado, o kernel loga a detecção do dispositivo e o nome atribuído (como `sdb`).

### Exercício 5

- **5.1** — Modularidade: o kernel carrega apenas os drivers dos dispositivos realmente presentes, economizando memória, e pode carregar/descarregar suporte a hardware sem recompilar nem reiniciar (na maioria dos casos). Também permite que fabricantes distribuam drivers separadamente.
- **5.2** — Em `/lib/modules/$(uname -r)/` (ou `/usr/lib/modules/...` em algumas distribuições), organizados por versão do kernel — é o que o campo `filename` do `modinfo` mostra.
- **5.3** — `/proc` expõe principalmente informações sobre processos e estado geral do kernel (`cpuinfo`, `meminfo`, `swaps`). `/sys` (sysfs) expõe a árvore de dispositivos, barramentos e drivers de forma estruturada, e é a interface moderna para consultar e ajustar parâmetros de hardware.

### Exercício 6

- **6.1** — A RAM. Swap em uso constante indica que a memória física é insuficiente para a carga de trabalho; adicionar RAM reduz a dependência do swap e melhora o desempenho geral.
- **6.2** — Exemplos válidos: **motherboard** (placa-mãe, que interconecta todos os componentes), **power supply / PSU** (fonte de alimentação), placa de som, gabinete com sistema de refrigeração (*cooler*/ventoinhas), monitor, teclado e mouse como periféricos de entrada/saída.

</details>

---

**Fontes consultadas:**

- LPI Learning Materials, tema 4.2 — <https://learning.lpi.org/en/learning-materials/010-160/4/4.2/>