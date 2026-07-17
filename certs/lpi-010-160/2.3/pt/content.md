# Topic 2.3 — Using Directories and Listing Files

## Introdução

Navegar pela árvore de diretórios do Linux é uma habilidade central do dia a dia com a linha de comando. Este tópico cobre como descobrir onde você está no filesystem, como se mover entre diretórios, como listar seu conteúdo (incluindo arquivos ocultos) e a diferença entre caminhos (paths) absolutos e relativos.

## Onde você está: `pwd`

O comando `pwd` (**print working directory**) mostra o caminho absoluto do diretório atual:

```console
$ pwd
/home/aluno/projetos
```

Todo processo (incluindo o shell) mantém um **current working directory (cwd)**. Comandos que recebem caminhos relativos são resolvidos em relação a esse diretório.

## Home directory

Cada usuário possui um **home directory**, geralmente `/home/<usuário>` (no caso do root, `/root`). O shell expande o símbolo `~` (til) para o home directory do usuário:

```console
$ echo ~
/home/aluno

$ echo ~root
/root
```

Ao abrir um terminal, normalmente você já começa no seu home directory.

## Absolute path vs relative path

- **Absolute path**: começa com `/` (root do filesystem) e descreve a localização completa, independente do diretório atual.
  ```console
  $ cd /var/log
  ```
- **Relative path**: não começa com `/`; é resolvido a partir do diretório atual.
  ```console
  $ cd log       # equivale a ./log, relativo ao cwd
  ```

Símbolos especiais usados em paths:

| Símbolo | Significado |
|---|---|
| `.` | diretório atual |
| `..` | diretório pai |
| `~` | home directory do usuário |
| `-` | diretório anterior (usado com `cd -`) |
| `/` | root do filesystem (no início do path) ou separador de componentes |

## Navegando: `cd`

O comando `cd` (**change directory**) altera o diretório atual do shell:

```console
$ cd /etc          # vai para um path absoluto
$ cd ..             # sobe um nível
$ cd ../..          # sobe dois níveis
$ cd                # sem argumento: vai para o home directory
$ cd ~              # equivalente ao comando acima
$ cd -              # volta para o diretório anterior (e imprime o path)
/home/aluno/projetos
```

`cd` é um **shell builtin** (não um binário externo), pois precisa alterar o estado do próprio processo do shell — um programa externo não conseguiria mudar o cwd do shell que o chamou.

## Listando conteúdo: `ls`

O comando `ls` lista arquivos e diretórios.

```console
$ ls
Documents  Downloads  Pictures  notas.txt
```

### Opções mais usadas

| Opção | Efeito |
|---|---|
| `-l` | **long listing**: formato detalhado (permissões, dono, grupo, tamanho, data) |
| `-a` | mostra também arquivos ocultos (**all**), incluindo `.` e `..` |
| `-A` | como `-a`, mas omite `.` e `..` (**almost all**) |
| `-h` | tamanhos "human-readable" (K, M, G) — usado junto com `-l` |
| `-d` | lista o próprio diretório, não seu conteúdo (**directory**) |
| `-R` | lista recursivamente subdiretórios |
| `-F` | acrescenta um caractere indicando o tipo (`/` diretório, `*` executável, `@` link simbólico) |
| `-t` | ordena por data de modificação (mais recente primeiro) |
| `-r` | inverte a ordem da listagem |
| `-S` | ordena por tamanho |
| `-1` | um item por linha |
| `--color` | colore a saída por tipo de arquivo |

Exemplo com `ls -l`:

```console
$ ls -l
total 16
drwxr-xr-x 2 aluno aluno 4096 jul 10 09:15 Documents
drwxr-xr-x 2 aluno aluno 4096 jul 10 09:15 Downloads
-rw-r--r-- 1 aluno aluno  512 jul 12 08:40 notas.txt
```

Leitura de cada campo:

1. **Tipo de arquivo** (primeiro caractere): `-` arquivo comum, `d` diretório, `l` link simbólico, `c`/`b` device.
2. **Permissões** (9 caracteres seguintes): rwx para owner, group e others.
3. **Número de links** (hard links).
4. **Owner** (usuário dono) e **group**.
5. **Tamanho** em bytes (ou com `-h`, formato legível).
6. **Data/hora** da última modificação.
7. **Nome** do arquivo ou diretório.

Combinando opções:

```console
$ ls -lah
total 24K
drwxr-xr-x  4 aluno aluno 4.0K jul 12 08:40 .
drwxr-xr-x 20 aluno aluno 4.0K jul 11 22:00 ..
-rw-------  1 aluno aluno  120 jul 12 08:41 .bash_history
drwxr-xr-x  2 aluno aluno 4.0K jul 10 09:15 Documents
-rw-r--r--  1 aluno aluno  512 jul 12 08:40 notas.txt
```

## Hidden files (dotfiles)

No Linux, qualquer arquivo ou diretório cujo nome comece com `.` é considerado **oculto** e não aparece em uma listagem padrão de `ls`. São conhecidos como **dotfiles** e costumam guardar configurações de programas e do próprio usuário (ex.: `.bashrc`, `.ssh/`, `.gitconfig`).

```console
$ ls
notas.txt

$ ls -a
.  ..  .bashrc  .ssh  notas.txt
```

Os entries `.` e `..` sempre existem em todo diretório: representam o próprio diretório e seu pai, respectivamente — não são criados manualmente.

## Listagem recursiva

`ls -R` percorre subdiretórios e mostra o conteúdo de cada um:

```console
$ ls -R Documents
Documents:
notas  relatorios

Documents/relatorios:
2025.pdf  2026.pdf
```

## Criando e removendo diretórios

Embora o foco do tópico seja navegação e listagem, os comandos básicos de criação/remoção de diretórios são parte do mesmo fluxo de trabalho:

```console
$ mkdir projetos
$ mkdir -p projetos/2026/janeiro   # -p cria diretórios pais que faltarem, sem erro se já existirem
$ rmdir projetos/2026/janeiro       # remove diretório vazio
```

## Wildcards (globbing)

O shell expande caracteres curinga antes de passar os argumentos para `ls` (ou qualquer outro comando):

| Padrão | Significa |
|---|---|
| `*` | qualquer sequência de caracteres (zero ou mais) |
| `?` | exatamente um caractere qualquer |
| `[abc]` | um caractere entre os listados |
| `[0-9]` | um caractere no intervalo |

```console
$ ls *.txt
notas.txt  tarefas.txt

$ ls relatorio?.pdf
relatorio1.pdf  relatorio2.pdf
```

## Referências

- LPI Learning Materials — Topic 2.3: Using Directories and Listing Files: <https://learning.lpi.org/en/learning-materials/010-160/2/2.3/>
- GNU Coreutils Manual — `ls`, `cd`, `pwd`, `mkdir`: <https://www.gnu.org/software/coreutils/manual/html_node/index.html>
- man7.org — `ls(1)`: <https://man7.org/linux/man-pages/man1/ls.1.html>