# Exercícios Guiados — Tópico 2.2: Using the Command Line to Get Help

**Certificação:** LPI Linux Essentials (010-160, versão 1.6)
**Peso no exame:** 2

> Fonte de referência: [LPI Learning Materials — 010-160, seção 2.2](https://learning.lpi.org/en/learning-materials/010-160/2/2.2/)

---

## Exercício 1 — Usando `man` pela primeira vez

O comando `man` (manual) é a principal ferramenta de consulta embutida no Linux. Ele abre a página de manual de um comando usando o paginador `less` por baixo dos panos.

**Passos:**

1. Abra um terminal.
2. Execute:
   ```
   man ls
   ```
3. Observe as seções no topo da página: `NAME`, `SYNOPSIS`, `DESCRIPTION`, `OPTIONS` (às vezes chamada de `EXIT STATUS`, `AUTHOR` etc., dependendo do comando).
4. Use as teclas de navegação do `less` dentro do `man`:
   - `Espaço` ou `Page Down` → avança uma página
   - `b` ou `Page Up` → volta uma página
   - `/palavra` + `Enter` → busca "palavra" para frente
   - `n` → repete a última busca
   - `q` → sai do `man`
5. Dentro de `man ls`, digite `/--recursive` e pressione `Enter` para localizar a explicação da opção `-R`.
6. Pressione `q` para sair.

**Perguntas:**

1. Qual programa o `man` usa internamente para exibir e paginar o conteúdo?
2. Depois de fazer uma busca com `/`, qual tecla repete a busca para o próximo resultado?

---

## Exercício 2 — Seções do manual (`man sections`)

As páginas de manual são organizadas em seções numeradas. É comum existir mais de uma entrada com o mesmo nome em seções diferentes — por exemplo, `passwd` é tanto um comando (seção 1) quanto um arquivo de configuração (seção 5).

**Passos:**

1. Execute:
   ```
   man passwd
   ```
   Note que, por padrão, o `man` abre a primeira seção que encontrar (geralmente a 1, o comando).
2. Agora peça explicitamente a seção 5 (formato de arquivos):
   ```
   man 5 passwd
   ```
3. Compare o conteúdo: a seção 1 descreve como *trocar* uma senha; a seção 5 descreve o *formato* do arquivo `/etc/passwd`.
4. Liste todas as seções disponíveis para um mesmo nome com:
   ```
   man -a passwd
   ```
   Pressione `q` para avançar de uma seção para a próxima.
5. Consulte rapidamente o índice de seções e seus significados com:
   ```
   man man
   ```
   e procure a lista numerada (1: comandos de usuário, 5: formatos de arquivo, 8: comandos de administração, etc.).

**Perguntas:**

1. Por que `passwd` aparece em mais de uma seção do manual?
2. Qual comando exibe *todas* as ocorrências de uma página de manual em todas as seções, uma após a outra?

---

## Exercício 3 — Ajuda rápida com `--help`

Muitos comandos aceitam a opção `--help` (ou, em alguns casos, `-h`), que imprime um resumo de uso direto no terminal, sem abrir um paginador. É mais rápido que o `man`, mas geralmente menos detalhado.

**Passos:**

1. Execute:
   ```
   ls --help
   ```
2. Compare a saída com o que você viu em `man ls` no Exercício 1 — repare que `--help` lista as opções de forma mais compacta, sem exemplos longos.
3. Teste em outro comando:
   ```
   cp --help
   ```
4. Combine `--help` com `grep` para localizar rapidamente uma opção específica:
   ```
   ls --help | grep -i recursive
   ```

**Perguntas:**

1. Qual a principal diferença prática entre a saída de `comando --help` e a de `man comando`?
2. Por que faz sentido usar `grep` junto com `--help` quando a lista de opções é longa?

---

## Exercício 4 — Encontrando o comando certo com `whatis` e `apropos`

Nem sempre sabemos o nome exato do comando que precisamos. `whatis` mostra a descrição de uma palavra-chave que já é exatamente o nome de uma página de manual; `apropos` faz uma busca mais ampla, por palavras dentro das descrições.

**Passos:**

1. Execute:
   ```
   whatis ls
   ```
   Isso mostra a linha-resumo (a seção `NAME`) da página de manual de `ls`.
2. Agora tente uma palavra que não é exatamente um comando:
   ```
   whatis partition
   ```
   Provavelmente não haverá resultado, porque `whatis` exige correspondência exata do nome.
3. Use `apropos` para uma busca mais ampla:
   ```
   apropos partition
   ```
   Isso retorna vários comandos relacionados a particionamento de disco (como `fdisk`, `parted`, `mkfs`, dependendo da distribuição).
4. Compare com a forma equivalente usando `man`:
   ```
   man -k partition
   ```
   (a opção `-k`, de *keyword*, faz o `man` se comportar como o `apropos`)
5. E o equivalente de `whatis` via `man`:
   ```
   man -f ls
   ```

**Perguntas:**

1. Qual comando (`whatis` ou `apropos`) você usaria para descobrir *qual* comando lida com "criptografia de disco", sem saber o nome exato?
2. Quais duas opções do próprio `man` reproduzem o comportamento de `whatis` e `apropos`?

---

## Exercício 5 — Explorando o comando `info`

O sistema `info` é outra fonte de documentação, tradicionalmente usada pelos utilitários GNU. Ele organiza o conteúdo em "nós" (nodes) navegáveis, formando uma estrutura em hipertexto — diferente do texto corrido do `man`.

**Passos:**

1. Execute:
   ```
   info ls
   ```
2. Navegue pela estrutura usando as teclas:
   - `Espaço` → avança
   - `u` → sobe (up) um nível na hierarquia
   - `n` → vai ao próximo nó (next)
   - `p` → vai ao nó anterior (previous)
   - `q` → sai
3. Repare que, ao final da página inicial, existe uma lista de "menu" com subtópicos navegáveis — isso não existe no `man`.
4. Saia com `q`.

**Perguntas:**

1. Qual é a principal diferença estrutural entre a documentação do `info` e a do `man`?
2. Cite duas teclas usadas para navegar entre nós dentro do `info` que não têm equivalente direto no `man`.

---

## Exercício 6 — Documentação em `/usr/share/doc`

Além de `man` e `info`, os pacotes instalados costumam incluir arquivos de documentação extra (como `README`, `CHANGELOG`, exemplos de configuração) dentro de `/usr/share/doc`.

**Passos:**

1. Liste os diretórios de documentação disponíveis:
   ```
   ls /usr/share/doc
   ```
2. Escolha um pacote que você sabe estar instalado (por exemplo, `bash`) e liste seu conteúdo:
   ```
   ls /usr/share/doc/bash
   ```
3. Muitos arquivos vêm compactados com `.gz`. Para ler um arquivo compactado sem descompactá-lo manualmente, use:
   ```
   zless /usr/share/doc/bash/changelog.Debian.gz
   ```
   (o nome exato do arquivo varia conforme a distribuição)
4. Se o arquivo não estiver compactado, um simples `less arquivo` ou `cat arquivo` resolve.

**Perguntas:**

1. Que tipo de informação você normalmente encontra em `/usr/share/doc` que não está nem no `man` nem no `info`?
2. Qual comando permite ler um arquivo de texto compactado com `.gz` sem precisar descompactá-lo primeiro?

---

<details>
<summary><strong>Respostas</strong></summary>

**Exercício 1**
1. O `man` usa o paginador `less` (definido pela variável de ambiente `PAGER`, geralmente `less` por padrão) para exibir o conteúdo.
2. A tecla `n` repete a última busca, avançando para a próxima ocorrência.

**Exercício 2**
1. Porque o nome `passwd` corresponde tanto a um **comando** (seção 1, usado para trocar senha) quanto a um **arquivo de configuração** (seção 5, o formato de `/etc/passwd`). O `man` organiza o conteúdo por seções para evitar essa ambiguidade.
2. O comando `man -a passwd` mostra todas as páginas de manual chamadas `passwd`, em todas as seções, uma após a outra.

**Exercício 3**
1. `--help` imprime um resumo curto direto no terminal (sem paginador), listando principalmente as opções disponíveis. `man` abre uma página completa, paginada, com descrições mais longas, exemplos e seções como `AUTHOR` ou `SEE ALSO`.
2. Porque comandos com muitas opções (como `ls` ou `find`) geram uma saída longa em `--help`, e `grep` permite filtrar rapidamente apenas a linha da opção que interessa.

**Exercício 4**
1. `apropos`, pois ele busca por palavras-chave dentro das descrições de todas as páginas de manual, não exige o nome exato do comando.
2. `man -f` equivale a `whatis`, e `man -k` equivale a `apropos`.

**Exercício 5**
1. O `info` organiza a documentação em uma estrutura de hipertexto com "nós" (nodes) navegáveis e menus, enquanto o `man` apresenta um texto único e linear por página.
2. `u` (sobe um nível na hierarquia) e `n` / `p` (avança ou volta entre nós) — teclas de navegação estrutural que não existem no `man`.

**Exercício 6**
1. Arquivos como `README`, `CHANGELOG`, notas de licença, exemplos de configuração e informações específicas da distribuição sobre o pacote — conteúdo mais detalhado ou específico do empacotamento, que não faz parte da documentação "oficial" do projeto (`man`/`info`).
2. O comando `zless` (ou alternativamente `zcat arquivo.gz | less`) permite ler o conteúdo de um arquivo `.gz` sem descompactá-lo manualmente.

</details>