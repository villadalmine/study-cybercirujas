# 2.2 Using the Command Line to Get Help

## Introdução

O Linux é um sistema autodocumentado: praticamente todo comando, arquivo de configuração e chamada de sistema tem documentação instalada localmente, sem depender de internet. Para o exame Linux Essentials, é essencial saber usar as ferramentas de ajuda embutidas: `man`, `info`, a opção `--help` e os arquivos em `/usr/share/doc`. Saber onde procurar ajuda rapidamente é uma competência tão importante quanto conhecer os comandos em si.

## O comando `man`

O `man` (manual) exibe as *man pages*, a documentação de referência tradicional do Unix/Linux. É a primeira ferramenta a tentar quando se precisa entender um comando.

```bash
man ls
```

Isso abre a man page do comando `ls` em um *pager* (geralmente `less`), mostrando sinopse, descrição, opções e, às vezes, exemplos e arquivos relacionados.

### Navegação dentro do `man` (via `less`)

Como o `man` usa `less` como pager por padrão, as teclas de navegação são as mesmas:

| Tecla | Ação |
|---|---|
| `Espaço` ou `Page Down` | Avança uma página |
| `b` ou `Page Up` | Volta uma página |
| `/palavra` | Busca "palavra" para frente |
| `?palavra` | Busca "palavra" para trás |
| `n` | Repete a busca no mesmo sentido |
| `N` | Repete a busca no sentido contrário |
| `q` | Sai do `man` |

### Seções do manual

As man pages são organizadas em seções numeradas. O mesmo nome pode existir em mais de uma seção — por exemplo, `passwd` é tanto um comando (seção 1) quanto um arquivo de configuração (seção 5).

| Seção | Conteúdo |
|---|---|
| 1 | Comandos de usuário (executáveis) |
| 2 | Chamadas de sistema (system calls) |
| 3 | Funções de bibliotecas C |
| 4 | Arquivos especiais (geralmente em `/dev`) |
| 5 | Formatos de arquivo e convenções (ex.: `/etc/passwd`) |
| 6 | Jogos |
| 7 | Miscelânea (convenções, protocolos) |
| 8 | Comandos de administração do sistema (root) |
| 9 | Rotinas do kernel (não padrão, específico de algumas distros) |

Para escolher a seção explicitamente:

```bash
man 5 passwd
```

Isso mostra a documentação do **formato** do arquivo `/etc/passwd`, diferente de:

```bash
man 1 passwd
```

que documenta o **comando** `passwd` usado para trocar senhas.

### Buscando por palavra-chave: `apropos` e `man -k`

Quando não se sabe o nome exato do comando, é possível buscar por palavras-chave na descrição curta de todas as man pages instaladas:

```bash
apropos partition
```

Saída típica:

```
fdisk (8)            - manipulate disk partition table
gparted (8)           - Create, reorganize, and delete partitions
parted (8)            - a partition manipulation program
```

`man -k` é equivalente a `apropos`:

```bash
man -k partition
```

Essas buscas dependem de um banco de dados de índices (`mandb`), geralmente atualizado automaticamente pelo gerenciador de pacotes ou via `sudo mandb`.

### Descrição curta: `whatis` e `man -f`

Quando já se sabe o nome do comando mas quer só uma descrição de uma linha:

```bash
whatis ls
```

Saída:

```
ls (1)               - list directory contents
```

`man -f ls` produz o mesmo resultado.

## O comando `info`

O sistema `info` do projeto GNU oferece documentação em formato hipertexto, organizada em nós (*nodes*) navegáveis, e costuma ser mais detalhado que as man pages para ferramentas GNU (como `coreutils`, `bash`, `tar`).

```bash
info coreutils
```

### Navegação no `info`

| Tecla | Ação |
|---|---|
| `n` | Próximo nó (next) |
| `p` | Nó anterior (previous) |
| `u` | Sobe um nível (up) |
| `l` | Volta ao último nó visitado (last) |
| `Enter` sobre um link | Segue o link (menu item) |
| `q` | Sai do `info` |

Para ir direto a um comando específico dentro do `info`:

```bash
info ls
```

## A opção `--help`

A maioria dos comandos GNU/Linux aceita a flag `--help` (ou, em alguns comandos mais antigos, apenas `-h`), que imprime um resumo rápido de uso e opções diretamente no terminal, sem abrir um pager:

```bash
ls --help
```

Saída (resumida):

```
Usage: ls [OPTION]... [FILE]...
List information about the FILEs (the current directory by default).

  -a, --all                  do not ignore entries starting with .
  -l                         use a long listing format
  ...
```

`--help` é ideal para consultas rápidas de sintaxe, enquanto `man` é mais completo para entender o comportamento em profundidade.

## Documentação em `/usr/share/doc`

Pacotes instalados frequentemente trazem documentação adicional (READMEs, changelogs, exemplos de configuração, licenças) em subdiretórios de `/usr/share/doc/`, nomeados conforme o pacote:

```bash
ls /usr/share/doc/bash/
```

Saída típica:

```
bash.html   bashref.html   CHANGES.gz   COMPAT   FAQ   INSTALL   README
```

Esses arquivos costumam estar comprimidos (`.gz`) e podem ser lidos com `zcat`, `zless` ou `gunzip -c`:

```bash
zless /usr/share/doc/bash/CHANGES.gz
```

## Escolhendo a ferramenta certa

| Preciso de... | Uso |
|---|---|
| Sintaxe rápida de opções | `comando --help` |
| Referência completa de um comando | `man comando` |
| Documentação de um arquivo de config | `man 5 arquivo` |
| Não sei o nome do comando | `apropos palavra-chave` |
| Descrição de uma linha | `whatis comando` |
| Documentação detalhada de ferramentas GNU | `info comando` |
| Notas de versão, exemplos, licença | `/usr/share/doc/<pacote>/` |

## Referências

- LPI Learning Materials — Topic 2.2: Using the Command Line to Get Help: https://learning.lpi.org/en/learning-materials/010-160/2/2.2/
- man-pages(7) — Linux manual page: https://man7.org/linux/man-pages/man7/man-pages.7.html
- GNU Info manual: https://www.gnu.org/software/texinfo/manual/info/info.html
- GNU Coreutils manual: https://www.gnu.org/software/coreutils/manual/