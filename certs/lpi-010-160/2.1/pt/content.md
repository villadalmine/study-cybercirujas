# 2.1 Command Line Basics

## O que é a linha de comando

A linha de comando é a interface de texto através da qual o usuário interage com o sistema operacional, digitando *commands* que são interpretados e executados por um programa chamado **shell**. Em praticamente todas as distribuições Linux, o shell padrão é o **bash** (*Bourne Again SHell*), embora existam alternativas como `zsh`, `dash`, `ksh` ou `fish`.

O shell é acessado através de um **terminal** (uma janela de terminal em ambiente gráfico, ou um console virtual em modo texto). Quando o shell está pronto para receber comandos, ele exibe um **prompt**, tipicamente terminado em `$` para usuários comuns e `#` para o usuário `root`:

```
dalmine@host:~$
```

Para saber qual shell está sendo usado no momento:

```
$ echo $SHELL
/bin/bash
```

## Sintaxe de um comando

A estrutura geral de um comando no shell é:

```
comando [opções] [argumentos]
```

- **comando**: o nome do programa ou *builtin* do shell a ser executado.
- **opções** (ou *flags*): modificam o comportamento do comando. Podem ser curtas (`-l`, `-a`) ou longas (`--all`, `--human-readable`). Várias opções curtas geralmente podem ser combinadas: `-la` equivale a `-l -a`.
- **argumentos**: os dados sobre os quais o comando opera, como nomes de arquivos ou diretórios.

Exemplo:

```
$ ls -l /etc
```

Aqui, `ls` é o comando, `-l` é a opção (formato longo de listagem) e `/etc` é o argumento (o diretório a ser listado).

Os elementos de um comando são separados por **espaços em branco** (*whitespace*), e o shell é sensível a maiúsculas/minúsculas (*case sensitive*): `LS` não é o mesmo comando que `ls`.

## Obtendo ajuda sobre comandos

### `--help`

A maioria dos comandos GNU aceita a opção `--help`, que exibe um resumo rápido de uso e das opções disponíveis:

```
$ date --help
Usage: date [OPTION]... [+FORMAT]
  or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]
Display the current time in the given FORMAT...
```

### `man` (manual pages)

O comando `man` exibe as páginas de manual, mais completas e organizadas em **seções**:

```
$ man ls
```

Dentro do `man`, a navegação é feita com as setas ou `j`/`k`, `/palavra` busca texto, `n` vai para a próxima ocorrência, e `q` sai.

As seções principais do manual são:

| Seção | Conteúdo |
|-------|----------|
| 1 | Comandos executáveis (user commands) |
| 2 | Chamadas de sistema (system calls) |
| 3 | Funções de bibliotecas (library calls) |
| 4 | Arquivos especiais (dispositivos em `/dev`) |
| 5 | Formatos de arquivo e convenções |
| 6 | Jogos |
| 7 | Miscelânea (convenções, protocolos) |
| 8 | Comandos de administração do sistema |

Quando um termo existe em mais de uma seção (por exemplo, `passwd` é tanto um comando quanto um arquivo), pode-se especificar a seção:

```
$ man 5 passwd
```

Para buscar páginas de manual por palavra-chave:

```
$ man -k partition
$ apropos partition
```

### `info`

Alguns pacotes GNU (como `coreutils`) documentam seus comandos no formato **info**, um sistema de documentação em hipertexto navegável:

```
$ info coreutils
```

## Histórico de comandos

O bash mantém um **histórico** dos comandos digitados, armazenado por padrão em `~/.bash_history` e exibido com:

```
$ history
  501  ls -l
  502  cd /var/log
  503  man ls
```

Atalhos úteis relacionados ao histórico:

- **seta para cima / para baixo**: navega entre comandos anteriores/posteriores.
- **Ctrl+R**: busca reversa incremental no histórico (digite parte do comando e o bash sugere a última ocorrência).
- **`!!`**: repete o último comando executado.
- **`!n`**: executa o comando de número `n` no histórico (ex.: `!502`).
- **`!string`**: executa o comando mais recente que começa com `string`.

## Edição da linha de comando

O bash usa por padrão os atalhos de edição no estilo **Emacs** (existe também o modo `vi`, ativado com `set -o vi`):

| Atalho | Ação |
|--------|------|
| `Ctrl+A` | Move o cursor ao início da linha |
| `Ctrl+E` | Move o cursor ao final da linha |
| `Ctrl+U` | Apaga da posição do cursor até o início da linha |
| `Ctrl+K` | Apaga da posição do cursor até o final da linha |
| `Ctrl+W` | Apaga a palavra anterior ao cursor |
| `Ctrl+L` | Limpa a tela (equivale ao comando `clear`) |
| `Ctrl+C` | Interrompe o comando em execução (envia `SIGINT`) |
| `Ctrl+D` | Encerra a entrada atual / fecha o shell se a linha estiver vazia |
| `Tab` | Autocompleta comandos, caminhos e nomes de arquivos |

O **autocompletar** (`tab completion`) é uma das ferramentas mais úteis do dia a dia: ao digitar parte de um nome de comando ou arquivo e pressionar `Tab`, o bash completa automaticamente se houver apenas uma possibilidade, ou lista as opções ao pressionar `Tab` duas vezes quando há ambiguidade.

## Variáveis de ambiente

O shell mantém um conjunto de **variáveis de ambiente** (*environment variables*), pares nome=valor que influenciam o comportamento de programas e do próprio shell. Por convenção, os nomes são escritos em maiúsculas.

Para exibir o valor de uma variável, usa-se `$` antes do nome:

```
$ echo $HOME
/home/dalmine
```

Para listar todas as variáveis de ambiente exportadas:

```
$ env
```

Para listar também variáveis locais do shell (não exportadas), use o comando `set` sem argumentos.

Algumas variáveis importantes:

- **`HOME`**: diretório pessoal do usuário atual.
- **`USER`**: nome do usuário logado.
- **`SHELL`**: caminho do shell padrão do usuário.
- **`PWD`**: diretório de trabalho atual.
- **`PATH`**: lista de diretórios onde o shell procura executáveis, separados por `:`.

### A variável `PATH`

Quando um comando é digitado sem caminho explícito (por exemplo `ls`, e não `/bin/ls`), o shell procura um executável com esse nome em cada diretório listado em `PATH`, na ordem em que aparecem:

```
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Para descobrir qual executável será usado para um dado comando:

```
$ which ls
/usr/bin/ls

$ type cd
cd is a shell builtin
```

Para adicionar um novo diretório ao `PATH` (por exemplo, um diretório com scripts pessoais), sem perder o valor já existente:

```
$ export PATH=$PATH:$HOME/bin
```

### Criando e exportando variáveis

Uma variável comum, criada com `variavel=valor` (sem espaços ao redor do `=`), existe apenas no shell atual. Para que fique disponível também em processos filhos (subshells, scripts executados a partir dele), é preciso **exportá-la**:

```
$ MEUAPP=producao
$ export MEUAPP
```

ou, em uma única linha:

```
$ export MEUAPP=producao
```

Para remover uma variável do ambiente:

```
$ unset MEUAPP
```

## Aspas e escape (quoting)

Como o shell interpreta espaços, `$`, `*`, `"`, `'` e outros caracteres de forma especial, às vezes é necessário controlar essa interpretação:

- **Aspas duplas (`"..."`)**: preservam espaços literais, mas ainda permitem a **expansão de variáveis** (`$var`) e de comandos.

  ```
  $ nome="Mundo"
  $ echo "Olá, $nome!"
  Olá, Mundo!
  ```

- **Aspas simples (`'...'`)**: preservam tudo literalmente, sem nenhuma expansão.

  ```
  $ echo 'Olá, $nome!'
  Olá, $nome!
  ```

- **Barra invertida (`\`)**: escapa (neutraliza o significado especial de) um único caractere seguinte.

  ```
  $ echo Preço\ do\ produto
  Preço do produto
  ```

Isso é especialmente relevante ao lidar com nomes de arquivos ou diretórios que contêm espaços: `cd Meus Documentos` falha, pois o shell interpreta dois argumentos separados; o correto é `cd "Meus Documentos"` ou `cd Meus\ Documentos`.

## Alguns comandos básicos de exemplo

```
$ pwd
/home/dalmine

$ whoami
dalmine

$ uname -a
Linux host 6.10.0-generic #1 SMP x86_64 GNU/Linux

$ date
Sun Jul 12 14:32:07 -03 2026

$ echo "Hoje é $(date +%A)"
Hoje é domingo

$ alias ll='ls -la'
$ ll
```

O comando `alias` cria um atalho para um comando (ou combinação de comando e opções); listado sem argumentos, mostra todos os *aliases* definidos. `unalias nome` remove um *alias*.

Para sair do shell:

```
$ exit
```

## Referências

- LPI Learning Materials — Topic 2.1: Command Line Basics: https://learning.lpi.org/en/learning-materials/010-160/2/2.1/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Coreutils Manual: https://www.gnu.org/software/coreutils/manual/coreutils.html
- man(1) — Linux manual page: https://man7.org/linux/man-pages/man1/man.1.html