# 3.2 Searching and Extracting Data from Files

## Introdução

Um dos pontos fortes do Linux é a filosofia Unix de combinar ferramentas pequenas e especializadas através de **pipes** e **redirects** para processar texto. Neste tópico vamos ver como localizar padrões dentro de arquivos com `grep` e expressões regulares (**regex**), e como extrair, reordenar e resumir dados com utilitários como `cut`, `sort`, `uniq`, `wc`, `head`, `tail`, `tr` e `tee`.

## Streams, pipes e redirects

Todo processo no Linux abre três *streams* por padrão:

| Stream | Descrição | File descriptor |
|---|---|---|
| `stdin` | entrada padrão | 0 |
| `stdout` | saída padrão | 1 |
| `stderr` | saída de erro | 2 |

Redirects permitem enviar esses streams para arquivos:

```bash
$ ls -l > listagem.txt      # redireciona stdout, sobrescreve o arquivo
$ ls -l >> listagem.txt     # redireciona stdout, faz append
$ comando 2> erros.log      # redireciona apenas stderr
$ comando > saida.log 2>&1  # stdout e stderr no mesmo arquivo
$ wc -l < arquivo.txt       # arquivo.txt vira stdin do comando
```

O **pipe** (`|`) conecta o `stdout` de um comando ao `stdin` do próximo, formando um "cano" de processamento:

```bash
$ cat access.log | grep "404" | wc -l
```

Essa combinação é a base de praticamente todos os exemplos deste tópico.

## `grep`: procurando padrões em texto

`grep` (*global regular expression print*) procura linhas que casem com um padrão e as imprime.

```bash
$ grep "root" /etc/passwd
root:x:0:0:root:/root:/bin/bash
```

Opções mais usadas no exame:

| Opção | Efeito |
|---|---|
| `-i` | ignora maiúsculas/minúsculas (*case insensitive*) |
| `-v` | inverte a busca — mostra linhas que **não** casam |
| `-c` | conta o número de linhas que casam, em vez de imprimi-las |
| `-n` | mostra o número da linha junto com o resultado |
| `-l` | mostra apenas o nome dos arquivos com correspondência |
| `-r` / `-R` | busca recursiva em diretórios |
| `-w` | casa apenas palavras inteiras |
| `-A N` / `-B N` / `-C N` | mostra N linhas depois (*after*), antes (*before*) ou ao redor (*context*) da correspondência |
| `-E` | habilita *extended regular expressions* (equivalente a `egrep`) |
| `-F` | trata o padrão como texto literal, não regex (equivalente a `fgrep`) |

Exemplos:

```bash
$ grep -i "ERROR" app.log
$ grep -v "^#" /etc/ssh/sshd_config     # ignora comentários
$ grep -c "bash" /etc/passwd
5
$ grep -n "nologin" /etc/passwd
14:sync:x:4:65534:sync:/bin:/bin/sync
26:games:x:5:60:games:/usr/games:/usr/sbin/nologin
$ grep -rl "TODO" ~/projeto/
$ grep -B2 -A2 "Fatal" servidor.log
```

## Expressões regulares (regex)

Uma **regular expression** é um padrão que descreve um conjunto de strings, diferente dos *wildcards* do shell (`*`, `?`), que são expandidos pelo próprio shell antes de o comando rodar. Regex é interpretada pelo próprio comando (`grep`, `sed`, etc.).

### Metacaracteres básicos (BRE — Basic Regular Expressions)

| Metacaractere | Significado |
|---|---|
| `.` | qualquer caractere único |
| `*` | zero ou mais repetições do caractere/grupo anterior |
| `^` | início da linha |
| `$` | fim da linha |
| `[abc]` | qualquer um dos caracteres `a`, `b` ou `c` |
| `[^abc]` | qualquer caractere **exceto** `a`, `b` ou `c` |
| `[0-9]` | qualquer dígito (intervalo) |
| `\` | escapa um metacaractere, tratando-o como literal |

Exemplos:

```bash
$ grep "^root" /etc/passwd          # linhas que começam com "root"
$ grep "bash$" /etc/passwd          # linhas que terminam com "bash"
$ grep "^$" arquivo.txt             # linhas vazias
$ grep "colo.r" texto.txt           # casa "color", "colour", "colo r", etc.
$ grep "[Ll]inux" texto.txt         # casa "Linux" ou "linux"
```

### Metacaracteres estendidos (ERE — Extended Regular Expressions)

Com `grep -E` (ou `egrep`) ficam disponíveis também:

| Metacaractere | Significado |
|---|---|
| `+` | uma ou mais repetições |
| `?` | zero ou uma ocorrência (opcional) |
| `{n,m}` | entre `n` e `m` repetições |
| `(  )` | agrupamento |
| `|` | alternância (OU) |

```bash
$ grep -E "colou?r" texto.txt         # "color" ou "colour"
$ grep -E "[0-9]{3}-[0-9]{4}"         # padrão tipo telefone: 555-1234
$ grep -E "erro|falha|fatal" log.txt  # qualquer uma das três palavras
```

> Em BRE, `+`, `?`, `{}`, `(`, `)` e `|` precisam ser escapados com `\` (ex.: `\+`) para terem significado especial. Em ERE eles já são especiais por padrão.

## `cut`: extraindo colunas

`cut` extrai partes de cada linha com base em delimitador ou posição de caractere.

```bash
$ cut -d: -f1 /etc/passwd
root
daemon
bin
...
```

| Opção | Efeito |
|---|---|
| `-d` | define o delimitador (padrão: TAB) |
| `-f` | seleciona quais campos (*fields*) extrair |
| `-c` | seleciona por posição de caractere |

```bash
$ cut -d: -f1,3 /etc/passwd     # usuário e UID
root:0
daemon:1
$ echo "abcdefgh" | cut -c2-5
bcde
```

## `sort`: ordenando linhas

```bash
$ sort nomes.txt
```

| Opção | Efeito |
|---|---|
| `-n` | ordenação numérica (não lexicográfica) |
| `-r` | ordem reversa |
| `-k N` | ordena pela coluna N |
| `-t` | define o delimitador de coluna |
| `-u` | remove duplicatas (*unique*) |
| `-f` | ignora maiúsculas/minúsculas |

```bash
$ sort -n numeros.txt
$ sort -t: -k3 -n /etc/passwd   # ordena /etc/passwd pelo UID (campo 3)
$ sort -r arquivo.txt
```

Sem `-n`, `sort` compara strings caractere a caractere, então `10` viria antes de `2`:

```bash
$ printf "10\n2\n1\n" | sort
1
10
2
$ printf "10\n2\n1\n" | sort -n
1
2
10
```

## `uniq`: removendo/contando duplicatas

`uniq` só remove linhas duplicadas **adjacentes**, por isso quase sempre é usado depois de `sort`.

```bash
$ sort acessos.txt | uniq
```

| Opção | Efeito |
|---|---|
| `-c` | conta quantas vezes cada linha se repete |
| `-d` | mostra apenas as linhas que se repetem |
| `-u` | mostra apenas as linhas que **não** se repetem |

Exemplo clássico: contar quantas vezes cada IP aparece em um log e ordenar do mais frequente ao menos frequente:

```bash
$ cut -d' ' -f1 access.log | sort | uniq -c | sort -rn
    154 192.168.1.10
     87 192.168.1.23
     12 10.0.0.5
```

## `wc`: contando linhas, palavras e caracteres

```bash
$ wc arquivo.txt
  120  845 5230 arquivo.txt
```

| Opção | Efeito |
|---|---|
| `-l` | conta linhas |
| `-w` | conta palavras |
| `-c` | conta bytes |
| `-m` | conta caracteres |

```bash
$ wc -l /etc/passwd
42 /etc/passwd
$ grep -c "^$" arquivo.txt   # alternativa: contar linhas vazias
```

## `head` e `tail`: início e fim de um arquivo

```bash
$ head -n 5 arquivo.log     # 5 primeiras linhas
$ tail -n 5 arquivo.log     # 5 últimas linhas
$ tail -f /var/log/syslog   # acompanha o arquivo em tempo real (follow)
```

`tail -f` é muito usado para monitorar logs enquanto eles crescem; a saída para com `Ctrl+C`.

## `tr`: traduzindo ou removendo caracteres

`tr` trabalha apenas com `stdin`, nunca recebe nome de arquivo como argumento direto.

```bash
$ echo "Linux Essentials" | tr 'a-z' 'A-Z'
LINUX ESSENTIALS
$ cat arquivo.csv | tr ',' ';'          # troca delimitador
$ echo "linha  com   espaços" | tr -s ' '   # -s: comprime repetições
linha com espaços
$ echo "Sem123Números456" | tr -d '0-9'     # -d: deleta caracteres
SemNúmeros
```

## `tee`: gravando em arquivo e continuando o pipe

`tee` copia o `stdin` para um arquivo **e** o repassa para `stdout`, permitindo inspecionar um resultado intermediário sem quebrar o pipe.

```bash
$ dmesg | grep -i "usb" | tee usb.log | wc -l
```

## Combinando tudo: exemplo prático

Encontrar os 5 usuários com shell `/bin/bash` cujo UID é maior que 1000, ordenados por nome:

```bash
$ grep "/bin/bash$" /etc/passwd | awk -F: '$3 > 1000' | cut -d: -f1 | sort | head -n 5
```

Contar quantas requisições HTTP retornaram erro 500 em um log de acesso:

```bash
$ grep " 500 " access.log | wc -l
```

## Referências

- LPI Learning Materials — Linux Essentials 010-160, Topic 3.2 *Searching and Extracting Data from Files*: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- `grep(1)` man page: https://man7.org/linux/man-pages/man1/grep.1.html
- `regex(7)` man page: https://man7.org/linux/man-pages/man7/regex.7.html
- `cut(1)` man page: https://man7.org/linux/man-pages/man1/cut.1.html
- `sort(1)` man page: https://man7.org/linux/man-pages/man1/sort.1.html
- `uniq(1)` man page: https://man7.org/linux/man-pages/man1/uniq.1.html
- `wc(1)` man page: https://man7.org/linux/man-pages/man1/wc.1.html
- `tr(1)` man page: https://man7.org/linux/man-pages/man1/tr.1.html
- `tee(1)` man page: https://man7.org/linux/man-pages/man1/tee.1.html