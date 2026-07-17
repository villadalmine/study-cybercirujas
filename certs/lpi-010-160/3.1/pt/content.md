# 3.1 Archiving Files on the Command Line

**Peso no exame:** 2 · **Exame:** 010-160 (Linux Essentials, versão 1.6)

## Visão geral

Fazer backup, transferir um projeto inteiro ou economizar espaço em disco são tarefas do dia a dia que passam por dois conceitos distintos: **archiving** (juntar vários arquivos em um só) e **compression** (reduzir o tamanho de um arquivo). Este tema cobre as ferramentas de linha de comando para as duas coisas — `tar`, `gzip`/`gunzip`, `bzip2`/`bunzip2`, `xz`/`unxz` e `zip`/`unzip` — e como elas costumam ser combinadas.

## Archiving x compression

- **Archiving** (*arquivamento*) reúne múltiplos arquivos e diretórios em um único arquivo, preservando nomes, estrutura de diretórios, permissões e timestamps. A ferramenta clássica é o `tar`, cujo nome vem de *tape archive* — originalmente pensado para gravar backups em fita magnética.
- **Compression** (*compressão*) reduz o tamanho de **um** arquivo aplicando um algoritmo. As ferramentas mais comuns em Linux são `gzip` (algoritmo DEFLATE), `bzip2` (Burrows–Wheeler) e `xz` (LZMA2).

No Linux, o fluxo tradicional é: primeiro o `tar` empacota os arquivos em um `.tar`, depois um compressor reduz esse `.tar`. É por isso que aparecem extensões duplas como `.tar.gz` (também escrito `.tgz`), `.tar.bz2` ou `.tar.xz`. Já o formato `zip`, popular no mundo Windows, faz as duas coisas em uma única etapa.

| Ferramenta | Extensão | Taxa de compressão | Velocidade |
|---|---|---|---|
| `gzip` | `.gz` | Boa | Rápida |
| `bzip2` | `.bz2` | Melhor | Mais lenta |
| `xz` | `.xz` | Ótima | A mais lenta |
| `zip` | `.zip` | Boa | Rápida |

Regra prática para o exame: quanto melhor a compressão, mais lento costuma ser o processo — `xz` comprime mais, mas demora mais; `gzip` é o mais rápido, mas comprime menos.

## O comando tar

Sintaxe geral:

```
tar [opções] [arquivo-de-archive] [arquivos ou diretórios...]
```

O `tar` precisa de exatamente um **modo principal**:

- `-c` — **create**: cria um novo archive
- `-t` — **test/list**: lista o conteúdo de um archive sem extraí-lo
- `-x` — **extract**: extrai os arquivos de um archive

Opções combinadas com frequência:

- `-f ARQUIVO` — indica o arquivo de archive a ser usado (quase sempre necessária; deve vir por último, logo antes do nome do arquivo)
- `-v` — modo *verbose*, mostra cada arquivo processado
- `-z` — filtra através do **gzip**
- `-j` — filtra através do **bzip2**
- `-J` — filtra através do **xz**
- `-C DIRETÓRIO` — muda para `DIRETÓRIO` antes de extrair

> Mnemônico para as letras de compressão: `-z` = g**z**ip, `-j` = **b**zip2 (a exceção que foge do padrão), `-J` = **x**z (maiúscula, o mais forte).

### Criando um archive

```bash
$ tar -cvf backup.tar Documentos/
Documentos/
Documentos/notas.txt
Documentos/relatorio.odt
Documentos/projetos/
Documentos/projetos/plano.md
```

Criar e comprimir em um único passo:

```bash
$ tar -czvf backup.tar.gz Documentos/    # gzip
$ tar -cjvf backup.tar.bz2 Documentos/   # bzip2
$ tar -cJvf backup.tar.xz Documentos/    # xz
```

Comparando o resultado:

```bash
$ ls -lh backup.tar*
-rw-r--r-- 1 carol carol  10M jul 11 10:15 backup.tar
-rw-r--r-- 1 carol carol 3.2M jul 11 10:16 backup.tar.gz
-rw-r--r-- 1 carol carol 2.9M jul 11 10:16 backup.tar.bz2
-rw-r--r-- 1 carol carol 2.6M jul 11 10:17 backup.tar.xz
```

### Listando o conteúdo

Boa prática: sempre inspecionar um archive antes de extraí-lo.

```bash
$ tar -tf backup.tar.gz
Documentos/
Documentos/notas.txt
Documentos/relatorio.odt
Documentos/projetos/
Documentos/projetos/plano.md
```

Com `-v` aparecem permissões, dono, tamanho e data (parecido com `ls -l`):

```bash
$ tar -tvf backup.tar.gz
drwxr-xr-x carol/carol       0 2026-07-11 10:12 Documentos/
-rw-r--r-- carol/carol    1420 2026-07-11 10:12 Documentos/notas.txt
```

### Extraindo

```bash
$ tar -xvf backup.tar.gz
Documentos/
Documentos/notas.txt
...
```

O `tar` do GNU (o padrão em toda distribuição Linux) detecta automaticamente o tipo de compressão ao extrair, então `-z`/`-j`/`-J` são opcionais nesse momento — mas é bom saber qual delas corresponde a cada formato. Variações úteis:

```bash
# Extrair em outro diretório
$ tar -xf backup.tar.gz -C /tmp/restore

# Extrair um único arquivo do archive
$ tar -xf backup.tar.gz Documentos/notas.txt
```

Curiosidade histórica que aparece em documentação antiga: o `tar` aceita as opções com ou sem o traço inicial (`tar xvf backup.tar` funciona igual a `tar -xvf backup.tar`).

## Ferramentas de compressão individual: gzip, bzip2, xz

Diferente do `tar`, essas três ferramentas comprimem **um arquivo por vez** e, por padrão, **substituem** o original pela versão comprimida:

```bash
$ ls -lh log.txt
-rw-r--r-- 1 carol carol 5.0M jul 11 10:20 log.txt
$ gzip log.txt
$ ls -lh log.txt.gz
-rw-r--r-- 1 carol carol 980K jul 11 10:20 log.txt.gz
```

Note que `log.txt` desapareceu — só resta `log.txt.gz`.

Para descomprimir, qualquer uma destas formas funciona:

```bash
$ gunzip log.txt.gz      # equivalente a: gzip -d log.txt.gz
$ bunzip2 log.txt.bz2    # equivalente a: bzip2 -d log.txt.bz2
$ unxz log.txt.xz        # equivalente a: xz -d log.txt.xz
```

Opções compartilhadas pelas três ferramentas:

- `-k` — **keep**, mantém o arquivo original em vez de apagá-lo
- `-d` — descomprime
- `-1` … `-9` — nível de compressão (`-1` rápido e maior, `-9` lento e menor; o padrão costuma ser `-6`)

É possível ler o conteúdo de um arquivo texto comprimido **sem** descomprimi-lo em disco, usando `zcat`, `bzcat` ou `xzcat`:

```bash
$ zcat log.txt.gz | head -n 2
Jul 11 09:00:01 host CRON[1234]: session opened
Jul 11 09:05:01 host CRON[1250]: session opened
```

## zip e unzip

O `zip` arquiva **e** comprime em um único passo, e seu formato é totalmente compatível com Windows e macOS — a escolha natural quando se troca arquivos com quem não usa Linux.

Criar um archive (`-r` para incluir o conteúdo de diretórios recursivamente):

```bash
$ zip -r backup.zip Documentos/
  adding: Documentos/ (stored 0%)
  adding: Documentos/notas.txt (deflated 62%)
  adding: Documentos/relatorio.odt (deflated 8%)
```

Listar o conteúdo sem extrair:

```bash
$ unzip -l backup.zip
Archive:  backup.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
        0  2026-07-11 10:12   Documentos/
     1420  2026-07-11 10:12   Documentos/notas.txt
```

Extrair (opcionalmente em outro diretório com `-d`):

```bash
$ unzip backup.zip
$ unzip backup.zip -d /tmp/restore
```

Duas diferenças importantes em relação ao `tar` + `gzip`: o `zip` **mantém** os arquivos originais depois de criar o archive (não precisa de `-k`), e cada arquivo dentro do `.zip` é comprimido **individualmente** — em um `.tar.gz`, é o archive inteiro que passa pelo compressor como um único fluxo de dados.

## Referência rápida

| Tarefa | Comando |
|---|---|
| Criar archive tar | `tar -cvf arch.tar dir/` |
| Criar tar + gzip | `tar -czvf arch.tar.gz dir/` |
| Criar tar + bzip2 | `tar -cjvf arch.tar.bz2 dir/` |
| Criar tar + xz | `tar -cJvf arch.tar.xz dir/` |
| Listar conteúdo do tar | `tar -tvf arch.tar.gz` |
| Extrair tar | `tar -xvf arch.tar.gz` |
| Extrair em outro diretório | `tar -xf arch.tar.gz -C /caminho` |
| Comprimir / descomprimir arquivo | `gzip arquivo` / `gunzip arquivo.gz` |
| Criar zip | `zip -r arch.zip dir/` |
| Listar / extrair zip | `unzip -l arch.zip` / `unzip arch.zip` |

## Pontos-chave para o exame

- **Archiving** junta arquivos preservando estrutura (`tar`); **compression** reduz o tamanho de um arquivo (`gzip`, `bzip2`, `xz`). São operações independentes, mas costumam ser combinadas.
- Letra de compressão do `tar`: `-z` → gzip, `-j` → bzip2, `-J` → xz.
- Ranking típico de taxa de compressão: `xz` > `bzip2` > `gzip`/`zip`; a velocidade segue a ordem inversa.
- `gzip`, `bzip2` e `xz` **substituem** o arquivo original por padrão; use `-k` para mantê-lo.
- Sempre listar (`tar -tf` / `unzip -l`) antes de extrair, para conferir o conteúdo do archive.
- `zip` precisa de `-r` para incluir o conteúdo de diretórios, e — diferente de `gzip` — mantém os arquivos originais.

## Referências

- LPI Learning Materials — Tema 3.1, Archiving Files on the Command Line: https://learning.lpi.org/en/learning-materials/010-160/3/3.1/
- LPI — Linux Essentials Exam Objectives (010-160 v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU tar Manual: https://www.gnu.org/software/tar/manual/
- GNU gzip Manual: https://www.gnu.org/software/gzip/manual/gzip.html
- bzip2 — documentação oficial: https://sourceware.org/bzip2/docs.html
- XZ Utils: https://tukaani.org/xz/
- Info-ZIP (`zip` / `unzip`): https://infozip.sourceforge.net/