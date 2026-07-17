# Tópico 2.4: Creating, Moving and Deleting Files

## Introdução

Depois de aprender a navegar entre diretórios e listar arquivos (tópico 2.3), o próximo passo é saber criar, copiar, mover e remover arquivos e diretórios usando a linha de comando. Este é um conjunto de operações que qualquer usuário Linux realiza dezenas de vezes por dia, e é fundamental entender bem cada comando antes de usá-lo — especialmente os que apagam dados, já que no shell não existe "lixeira" por padrão.

## Criando arquivos

### `touch`

O comando `touch` cria um arquivo vazio se ele não existir, ou apenas atualiza o *timestamp* de modificação (`mtime`) se ele já existir.

```bash
$ touch relatorio.txt
$ ls -l relatorio.txt
-rw-r--r-- 1 aluno aluno 0 jul 13 10:00 relatorio.txt
```

Rodar `touch` de novo no mesmo arquivo não muda o conteúdo, só a data:

```bash
$ touch relatorio.txt
$ stat relatorio.txt | grep Modify
Modify: 2026-07-13 10:05:12.000000000 -0300
```

`touch` também aceita múltiplos nomes de uma vez:

```bash
$ touch a.txt b.txt c.txt
```

### Criando arquivos com redirecionamento

Além de `touch`, é comum criar arquivos redirecionando a saída de um comando com `>` (sobrescreve) ou `>>` (anexa ao final):

```bash
$ echo "primeira linha" > notas.txt
$ echo "segunda linha" >> notas.txt
$ cat notas.txt
primeira linha
segunda linha
```

## Criando diretórios

### `mkdir`

```bash
$ mkdir projetos
$ ls -ld projetos
drwxr-xr-x 2 aluno aluno 4096 jul 13 10:10 projetos
```

Para criar uma estrutura de diretórios aninhados de uma vez, use a opção `-p` (*parents*). Sem ela, `mkdir` falha se o diretório pai não existir:

```bash
$ mkdir projetos/2026/relatorios
mkdir: cannot create directory 'projetos/2026/relatorios': No such file or directory

$ mkdir -p projetos/2026/relatorios
$ ls -R projetos
projetos:
2026

projetos/2026:
relatorios
```

A opção `-v` (*verbose*) mostra cada diretório criado, útil combinada com `-p`:

```bash
$ mkdir -pv teste/a/b/c
mkdir: created directory 'teste'
mkdir: created directory 'teste/a'
mkdir: created directory 'teste/a/b'
mkdir: created directory 'teste/a/b/c'
```

## Copiando arquivos e diretórios

### `cp`

```bash
$ cp relatorio.txt relatorio_backup.txt
$ ls
relatorio.txt  relatorio_backup.txt
```

Copiar um arquivo para dentro de um diretório existente mantém o nome original:

```bash
$ cp relatorio.txt projetos/
```

Principais opções de `cp`:

| Opção | Efeito |
|---|---|
| `-r` (ou `-R`) | copia diretórios recursivamente (obrigatória para diretórios) |
| `-i` | pede confirmação antes de sobrescrever um arquivo existente |
| `-v` | modo *verbose*, mostra o que está sendo copiado |
| `-a` | modo *archive*: preserva permissões, dono e timestamps, e é recursivo |
| `-u` | copia apenas se a origem for mais nova que o destino, ou se o destino não existir |

Copiando um diretório inteiro:

```bash
$ cp -r projetos projetos_copia
$ ls
projetos  projetos_copia  relatorio.txt  relatorio_backup.txt

$ cp projetos projetos_copia2
cp: -r not specified; omitting directory 'projetos'
```

O exemplo acima mostra o erro clássico: tentar copiar um diretório sem `-r`.

Usando `-i` para evitar sobrescrever um arquivo por engano:

```bash
$ cp -i relatorio_backup.txt relatorio.txt
cp: overwrite 'relatorio.txt'? n
```

## Movendo e renomeando arquivos

### `mv`

No Linux, mover e renomear são a mesma operação: `mv` altera a entrada do arquivo no diretório (e move o inode se for para outro sistema de arquivos), sem precisar copiar o conteúdo.

Renomear um arquivo:

```bash
$ mv relatorio.txt relatorio_final.txt
```

Mover um arquivo para outro diretório (mantendo o nome):

```bash
$ mv relatorio_final.txt projetos/
```

Mover e renomear ao mesmo tempo:

```bash
$ mv projetos/relatorio_final.txt projetos/relatorio_2026.txt
```

Assim como `cp`, `mv` aceita `-i` (confirma antes de sobrescrever) e `-v` (modo verboso):

```bash
$ mv -iv a.txt b.txt
mv: overwrite 'b.txt'? y
'a.txt' -> 'b.txt'
```

Mover múltiplos arquivos para um diretório:

```bash
$ mv arquivo1.txt arquivo2.txt arquivo3.txt projetos/
```

## Removendo arquivos e diretórios

### `rm`

`rm` remove arquivos. **Não existe lixeira**: por padrão, o arquivo removido não pode ser recuperado facilmente.

```bash
$ rm relatorio_backup.txt
```

Removendo vários arquivos, inclusive com wildcards:

```bash
$ rm *.tmp
```

Principais opções de `rm`:

| Opção | Efeito |
|---|---|
| `-i` | pede confirmação para cada arquivo |
| `-f` | força a remoção, ignora arquivos inexistentes e não pede confirmação |
| `-r` (ou `-R`) | remove diretórios e seu conteúdo recursivamente |
| `-v` | modo *verbose* |

Removendo um diretório com conteúdo:

```bash
$ rm projetos_copia
rm: cannot remove 'projetos_copia': Is a directory

$ rm -r projetos_copia
```

A combinação `rm -rf` é poderosa e perigosa: remove recursivamente sem pedir confirmação. É a base do clássico alerta de segurança sobre nunca rodar `rm -rf /` ou `rm -rf *` sem ter certeza absoluta do diretório atual (`pwd`).

```bash
$ pwd
/home/aluno/teste
$ rm -rf *
```

### `rmdir`

`rmdir` remove **apenas diretórios vazios**. É uma forma mais segura de remover diretórios quando não se quer risco de apagar conteúdo por engano:

```bash
$ rmdir projetos/2026/relatorios
$ rmdir projetos
rmdir: failed to remove 'projetos': Directory not empty
```

## Wildcards ao criar, mover e remover

Os curingas (`*`, `?`, `[...]`) vistos no tópico 2.3 são muito usados aqui para operar em lote:

```bash
$ touch arquivo1.log arquivo2.log arquivo3.txt
$ cp *.log backup/
$ mv *.txt arquivados/
$ rm arquivo?.log
```

## Boas práticas

- Antes de um `rm -r` ou `mv` em massa, rode o mesmo padrão com `ls` primeiro para conferir quais arquivos serão afetados.
- Use `-i` em `cp`, `mv` e `rm` enquanto ainda estiver aprendendo, para evitar sobrescrever ou apagar algo por engano.
- Lembre que `mv` e `rm` não têm "desfazer" (`undo`) built-in — algumas distribuições oferecem `trash-cli` como alternativa mais segura ao `rm` para uso interativo, mas isso não é parte do padrão POSIX nem do exame.

## Referências

- LPI Learning Materials — Topic 2.4: Creating, Moving and Deleting Files: https://learning.lpi.org/en/learning-materials/010-160/2/2.4/
- GNU Coreutils Manual — `cp`: https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
- GNU Coreutils Manual — `mv`: https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html
- GNU Coreutils Manual — `rm`: https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html
- GNU Coreutils Manual — `mkdir`: https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html
- GNU Coreutils Manual — `touch`: https://www.gnu.org/software/coreutils/manual/html_node/touch-invocation.html