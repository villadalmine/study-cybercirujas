# Tema 3.3: Turning Commands into a Script

## Introdução

Um **shell script** é um arquivo de texto que contém uma sequência de comandos do shell, escritos na ordem em que seriam digitados interativamente no terminal. Transformar comandos avulsos em um script traz automação, repetibilidade e a possibilidade de compartilhar tarefas complexas como um único arquivo executável. Este é um dos objetivos centrais do exame Linux Essentials: entender como criar, tornar executável e rodar um script simples, além de conhecer variáveis, argumentos posicionais e loops básicos.

## Criando um script

Um script é criado com qualquer editor de texto (`vi`, `nano`, `gedit`, etc.). Por convenção, usa-se a extensão `.sh`, embora o Linux não exija extensão alguma para que um arquivo seja executável — quem determina isso é a permissão de execução, não o nome.

```bash
$ nano hello.sh
```

Conteúdo:

```bash
#!/bin/bash
# Script simples de saudação
echo "Hello, $USER!"
echo "Today is $(date +%A)"
```

### A linha shebang (`#!`)

A primeira linha, chamada **shebang** (ou *hashbang*), indica ao kernel qual interpretador deve executar o script. Ela precisa ser exatamente a primeira linha do arquivo, sem espaços antes do `#!`.

```bash
#!/bin/bash
```

Isso diz ao sistema: "execute este arquivo usando `/bin/bash`". Outras variações comuns:

```bash
#!/bin/sh
#!/usr/bin/env bash
#!/usr/bin/python3
```

A forma `#!/usr/bin/env bash` é mais portátil, pois usa o comando `env` para localizar o `bash` no `$PATH` do usuário, em vez de assumir um caminho fixo como `/bin/bash`.

Se o shebang for omitido, o script ainda pode rodar, mas será interpretado pelo shell que o chamou (por exemplo, ao executar `bash hello.sh`), o que pode gerar comportamento inconsistente entre sistemas.

### Comentários

Qualquer linha (ou parte de linha) iniciada com `#` é ignorada pelo interpretador, exceto na primeira posição do arquivo, onde forma o shebang.

```bash
# Isto é um comentário de linha inteira
echo "olá"   # Isto é um comentário ao final da linha
```

## Tornando o script executável

Por padrão, um arquivo recém-criado não tem permissão de execução:

```bash
$ ls -l hello.sh
-rw-r--r-- 1 aluno aluno 78 jul 13 10:00 hello.sh
```

É preciso adicionar a permissão `x` (execute) com `chmod`:

```bash
$ chmod +x hello.sh
$ ls -l hello.sh
-rwxr-xr-x 1 aluno aluno 78 jul 13 10:00 hello.sh
```

Também é possível usar notação octal (`chmod 755 hello.sh`), mas `chmod +x` é a forma mais comum para scripts pessoais.

## Executando o script

Existem várias formas de rodar um script, cada uma com implicações diferentes:

### 1. Caminho explícito (`./`)

```bash
$ ./hello.sh
Hello, aluno!
Today is Monday
```

O `./` é necessário porque, por padrão, o diretório atual (`.`) normalmente **não** faz parte do `$PATH` — medida de segurança para evitar execução acidental de scripts maliciosos colocados no diretório de trabalho. Sem o `./`, o shell procuraria `hello.sh` apenas nos diretórios listados em `$PATH` e retornaria erro:

```bash
$ hello.sh
bash: hello.sh: command not found
```

Este método exige que o arquivo tenha permissão de execução (`chmod +x`).

### 2. Chamando o interpretador diretamente

```bash
$ bash hello.sh
Hello, aluno!
Today is Monday
```

Aqui, o shebang é ignorado — quem interpreta o arquivo é o `bash` explicitamente invocado. Este método **não** exige permissão de execução, pois `bash` apenas lê o arquivo como argumento, como faria com qualquer texto.

### 3. Usando `source` (ou `.`)

```bash
$ source hello.sh
$ . hello.sh
```

Diferente dos métodos anteriores, `source` executa o script no **shell atual**, sem criar um novo processo (subshell). Isso significa que variáveis e mudanças de diretório (`cd`) definidas no script continuam disponíveis depois que o script termina — muito usado para carregar variáveis de ambiente, como em `source ~/.bashrc`.

### 4. Colocando o script no `$PATH`

Se o script for movido para um diretório listado em `$PATH` (por exemplo, `~/bin` ou `/usr/local/bin`), ele pode ser chamado apenas pelo nome, de qualquer lugar:

```bash
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/home/aluno/bin
$ mv hello.sh ~/bin/hello
$ chmod +x ~/bin/hello
$ hello
Hello, aluno!
```

## Variáveis em scripts

Variáveis armazenam valores para uso posterior. Não há espaços ao redor do `=` na atribuição.

```bash
#!/bin/bash
nome="Ana"
echo "Olá, $nome"
echo "Olá, ${nome}!"
```

Saída:

```
Olá, Ana
Olá, Ana!
```

O uso de chaves (`${nome}`) é recomendado quando o nome da variável pode ser confundido com o texto ao redor, como em `${nome}s` (evita que o shell tente expandir uma variável chamada `nomes`).

### Variáveis locais x variáveis de ambiente

Por padrão, uma variável criada em um script é **local** ao shell que o executa — não fica visível para processos filhos (subprocessos) chamados a partir dele. Para torná-la disponível a esses subprocessos, usa-se `export`:

```bash
#!/bin/bash
export SAUDACAO="Bom dia"
bash outro_script.sh   # outro_script.sh pode acessar $SAUDACAO
```

### Command substitution

O resultado de um comando pode ser capturado dentro de uma variável ou usado diretamente com `$(comando)` (forma moderna) ou crase `` `comando` `` (forma antiga):

```bash
#!/bin/bash
data_atual=$(date +%Y-%m-%d)
echo "Backup feito em $data_atual"
```

## Argumentos posicionais

Um script pode receber argumentos na linha de comando, acessados através de variáveis especiais:

| Variável | Significado |
|---|---|
| `$0` | Nome do script |
| `$1`, `$2`, ... | Primeiro, segundo, ... argumento |
| `${10}` | Décimo argumento (chaves obrigatórias a partir de dois dígitos) |
| `$#` | Quantidade de argumentos |
| `$@` | Todos os argumentos, cada um como palavra separada |
| `$*` | Todos os argumentos como uma única string |
| `$?` | Código de saída (*exit status*) do último comando |
| `$$` | PID do processo atual |

Exemplo:

```bash
#!/bin/bash
# saudacao.sh
echo "Script: $0"
echo "Primeiro argumento: $1"
echo "Total de argumentos: $#"
echo "Todos os argumentos: $@"
```

Execução:

```bash
$ ./saudacao.sh Maria João Pedro
Script: ./saudacao.sh
Primeiro argumento: Maria
Total de argumentos: 3
Todos os argumentos: Maria João Pedro
```

### Diferença entre `$@` e `$*`

Quando usados com aspas duplas, dentro de um loop `for`, `"$@"` preserva cada argumento como um item separado (importante quando algum argumento contém espaços), enquanto `"$*"` os junta em uma única string:

```bash
#!/bin/bash
for arg in "$@"; do
  echo "-> $arg"
done
```

```bash
$ ./teste.sh "primeiro arg" segundo
-> primeiro arg
-> segundo
```

Se o script usasse `"$*"` em vez de `"$@"`, a saída seria uma única linha: `-> primeiro arg segundo`.

## Código de saída (exit status)

Todo comando, ao terminar, retorna um código numérico indicando sucesso (`0`) ou falha (diferente de `0`). Esse valor fica disponível em `$?` logo após a execução:

```bash
$ ls /tmp
$ echo $?
0
$ ls /diretorio-inexistente
ls: cannot access '/diretorio-inexistente': No such file or directory
$ echo $?
2
```

Um script pode definir seu próprio código de saída com o comando `exit`:

```bash
#!/bin/bash
if [ -f /etc/hostname ]; then
  echo "Arquivo encontrado"
  exit 0
else
  echo "Arquivo não encontrado"
  exit 1
fi
```

## Loops básicos: `for`

O comando `for` permite repetir um bloco de comandos para cada item de uma lista — útil para processar arquivos, argumentos ou saídas de outros comandos.

```bash
#!/bin/bash
for arquivo in *.txt; do
  echo "Processando $arquivo"
  wc -l "$arquivo"
done
```

Também é comum iterar sobre uma sequência numérica:

```bash
#!/bin/bash
for i in 1 2 3 4 5; do
  echo "Contagem: $i"
done
```

Ou usando `seq`:

```bash
#!/bin/bash
for i in $(seq 1 5); do
  echo "Contagem: $i"
done
```

## Combinando redirecionamento e filtros em um script

Um dos usos mais práticos de scripts é encadear comandos já conhecidos (redirecionamento, pipes, filtros de texto) em uma única rotina reutilizável:

```bash
#!/bin/bash
# relatorio.sh - gera um relatório de usuários logados
echo "Relatório gerado em: $(date)" > relatorio.txt
echo "----------------------------" >> relatorio.txt
who | sort >> relatorio.txt
echo "Total de usuários: $(who | wc -l)" >> relatorio.txt
```

```bash
$ ./relatorio.sh
$ cat relatorio.txt
Relatório gerado em: Mon Jul 13 10:15:22 -03 2026
----------------------------
aluno    tty1         2026-07-13 09:00
aluno    pts/0        2026-07-13 09:30
Total de usuários: 2
```

## Depurando um script

Para acompanhar a execução comando a comando, útil ao investigar erros, usa-se a opção `-x` do bash:

```bash
$ bash -x hello.sh
+ echo 'Hello, aluno!'
Hello, aluno!
+ date +%A
+ echo Today is Monday
Today is Monday
```

Também é possível ativar isso dentro do próprio script, entre trechos específicos:

```bash
#!/bin/bash
set -x   # ativa modo de depuração
comando_suspeito
set +x   # desativa modo de depuração
```

Outra prática comum é usar `set -e`, que faz o script parar imediatamente caso qualquer comando retorne um código de saída diferente de zero, evitando que erros passem despercebidos.

## Boas práticas

- Sempre inicie o script com uma linha shebang.
- Use nomes de variáveis descritivos e coloque-os entre aspas duplas (`"$variavel"`) para evitar problemas com espaços ou caracteres especiais (*word splitting*).
- Comente o propósito do script e de trechos não óbvios.
- Teste o código de saída dos comandos críticos antes de prosseguir.
- Verifique a sintaxe sem executar, com `bash -n script.sh`.

## Referências

- LPI Learning Materials — 010-160, Topic 3.3, Turning Commands into a Script: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- man bash: https://man7.org/linux/man-pages/man1/bash.1.html
- man chmod: https://man7.org/linux/man-pages/man1/chmod.1.html