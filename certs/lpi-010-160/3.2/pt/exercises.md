# Exercícios guiados — Tópico 3.2: Searching and Extracting Data from Files

**Certificação:** LPI Linux Essentials (exame 010-160, versão 1.6)
**Peso no exame:** 3
**Fonte de referência:** https://learning.lpi.org/en/learning-materials/010-160/3/3.2/

---

## Bloco 1 — Preparando o ambiente de teste

1. Abra um terminal e crie um diretório de trabalho para os exercícios:
   ```bash
   mkdir -p ~/lpi-3.2 && cd ~/lpi-3.2
   ```
2. Gere um arquivo de texto com dados de exemplo (uma lista de "usuários" fictícia):
   ```bash
   printf "ana:staff:1001\nbruno:dev:1002\ncarla:dev:1003\ndaniel:staff:1004\nana:admin:1005\n" > users.txt
   ```
3. Confirme o conteúdo do arquivo com `cat`:
   ```bash
   cat users.txt
   ```
4. Exiba apenas as duas primeiras linhas com `head` e apenas a última linha com `tail`:
   ```bash
   head -n 2 users.txt
   tail -n 1 users.txt
   ```

**Perguntas de verificação:**
- Qual é a diferença entre usar `cat` sozinho e usar `head -n 2` no mesmo arquivo?
- Se `users.txt` tivesse 10.000 linhas, por que `tail -n 1` é mais eficiente do que `cat` seguido de leitura manual?

---

## Bloco 2 — Filtrando linhas com `grep`

1. Liste apenas as linhas que contêm `dev`:
   ```bash
   grep dev users.txt
   ```
2. Liste as linhas que **não** contêm `staff`, usando a opção de inversão:
   ```bash
   grep -v staff users.txt
   ```
3. Faça uma busca sem diferenciar maiúsculas/minúsculas por `ANA`:
   ```bash
   grep -i ana users.txt
   ```
4. Conte quantas linhas contêm `ana` (sem exibi-las), combinando `grep` com a opção de contagem:
   ```bash
   grep -c ana users.txt
   ```

**Perguntas de verificação:**
- O que a opção `-v` do `grep` inverte, exatamente?
- Por que `grep -c ana users.txt` retorna `2` mesmo havendo apenas duas ocorrências de `ana`, uma por linha, e não conta ocorrências múltiplas dentro da mesma linha?

---

## Bloco 3 — Extraindo colunas com `cut`

1. Extraia apenas o primeiro campo (nome de usuário), usando `:` como delimitador:
   ```bash
   cut -d: -f1 users.txt
   ```
2. Extraia o segundo e o terceiro campo ao mesmo tempo:
   ```bash
   cut -d: -f2,3 users.txt
   ```
3. Extraia um intervalo de campos (do campo 1 ao 2):
   ```bash
   cut -d: -f1-2 users.txt
   ```

**Perguntas de verificação:**
- O que aconteceria se você rodasse `cut -f1 users.txt` sem especificar `-d:`? (Dica: pense no delimitador padrão do `cut`.)
- Qual opção do `cut` você usaria se quisesse extrair caracteres por posição (por exemplo, os 5 primeiros caracteres de cada linha) em vez de campos delimitados?

---

## Bloco 4 — Ordenando e contando com `sort` e `wc`

1. Ordene o arquivo em ordem alfabética:
   ```bash
   sort users.txt
   ```
2. Ordene numericamente pelo terceiro campo (o ID), usando `:` como delimitador de campo:
   ```bash
   sort -t: -k3 -n users.txt
   ```
3. Remova duplicatas de nomes de usuário combinando `cut` e `sort` com a opção de unicidade:
   ```bash
   cut -d: -f1 users.txt | sort -u
   ```
4. Conte quantas linhas, palavras e caracteres tem o arquivo:
   ```bash
   wc users.txt
   ```
5. Conte apenas o número de linhas:
   ```bash
   wc -l users.txt
   ```

**Perguntas de verificação:**
- Por que é necessário usar `-t:` junto com `-k3` no comando `sort` do passo 2?
- No passo 3, qual seria o resultado se você usasse apenas `sort` (sem `-u`) depois do `cut`? E se você usasse `sort -u` sem passar antes pelo `cut`?

---

## Bloco 5 — Redirecionamento de streams (`>`, `>>`, `2>`)

1. Redirecione a saída de `sort users.txt` para um novo arquivo, sobrescrevendo-o se já existir:
   ```bash
   sort users.txt > users_sorted.txt
   ```
2. Acrescente uma nova linha ao final de `users.txt` sem apagar o conteúdo existente:
   ```bash
   echo "elisa:dev:1006" >> users.txt
   ```
3. Tente ler um arquivo que não existe e observe a mensagem de erro no terminal:
   ```bash
   cat arquivo_inexistente.txt
   ```
4. Repita o comando anterior, mas redirecione apenas o **standard error** para um arquivo, deixando a tela limpa:
   ```bash
   cat arquivo_inexistente.txt 2> erros.log
   cat erros.log
   ```

**Perguntas de verificação:**
- Qual a diferença prática entre `>` e `>>` ao redirecionar a saída de um comando?
- No passo 4, por que a mensagem de erro foi parar em `erros.log` e não na tela, se `cat arquivo_inexistente.txt` normalmente imprime o erro no terminal?

---

## Bloco 6 — Combinando comandos com pipes (`|`)

1. Combine `cat`, `grep` e `wc -l` para contar quantos usuários têm a função `dev`:
   ```bash
   cat users.txt | grep dev | wc -l
   ```
2. Encontre o usuário com o maior ID numérico, combinando `sort` e `tail`:
   ```bash
   sort -t: -k3 -n users.txt | tail -n 1
   ```
3. Liste os nomes de usuários únicos, em ordem alfabética, em uma única linha de pipe:
   ```bash
   cut -d: -f1 users.txt | sort | uniq
   ```

**Perguntas de verificação:**
- No passo 1, o comando `cat users.txt |` é estritamente necessário, ou `grep dev users.txt | wc -l` produziria o mesmo resultado? Por quê?
- O que faz o comando `uniq` no passo 3, e por que ele só funciona corretamente porque a entrada já passou por `sort` antes?

---

## Bloco 7 — Duplicando a saída com `tee`

1. Rode um pipe que filtra as linhas com `dev`, salva o resultado em um arquivo **e** ainda mostra na tela:
   ```bash
   grep dev users.txt | tee devs.txt
   ```
2. Confirme que o arquivo `devs.txt` foi criado com o conteúdo esperado:
   ```bash
   cat devs.txt
   ```
3. Use `tee -a` para acrescentar (em vez de sobrescrever) uma nova busca ao mesmo arquivo:
   ```bash
   grep staff users.txt | tee -a devs.txt
   ```

**Perguntas de verificação:**
- Por que `tee` é útil quando você já poderia simplesmente usar `>` para salvar a saída em um arquivo?
- O que a opção `-a` do `tee` faz, e com qual opção de redirecionamento (do Bloco 5) ela é equivalente em comportamento?

---

## Bloco 8 — Usando a saída de um comando como argumento com `xargs`

1. Crie alguns arquivos vazios cujos nomes vêm dos nomes de usuários únicos:
   ```bash
   cut -d: -f1 users.txt | sort -u | xargs touch
   ```
2. Confirme que os arquivos foram criados:
   ```bash
   ls
   ```
3. Remova todos os arquivos criados no passo 1 usando `xargs` com `rm`:
   ```bash
   cut -d: -f1 users.txt | sort -u | xargs rm
   ```

**Perguntas de verificação:**
- Por que `cut -d: -f1 users.txt | sort -u | touch` (sem `xargs`) não funcionaria como o comando do passo 1?
- Em que situação `xargs` é necessário, considerando que muitos comandos (como `grep` ou `cat`) já aceitam nomes de arquivo diretamente como argumento?

---

## Bloco 9 — Revisão integrada

1. Em um único comando, combine `grep`, `cut`, `sort` e `tee` para: filtrar os usuários com função `dev`, extrair apenas o nome, ordenar alfabeticamente e salvar o resultado em `revisao.txt` enquanto exibe na tela:
   ```bash
   grep dev users.txt | cut -d: -f1 | sort | tee revisao.txt
   ```
2. Verifique quantas linhas o arquivo `revisao.txt` tem:
   ```bash
   wc -l revisao.txt
   ```

**Perguntas de verificação:**
- Consegue explicar, comando por comando, o que cada etapa desse pipe faz com o standard output da etapa anterior?
- Se você quisesse redirecionar apenas os erros desse pipe completo para um arquivo de log, sem afetar o standard output, qual redirecionamento adicionaria e onde?

---

<details>
<summary><strong>Respostas</strong></summary>

**Bloco 1**
- `cat` exibe o arquivo inteiro de uma vez; `head -n 2` limita a saída às duas primeiras linhas, útil para visualizar rapidamente arquivos grandes sem carregar tudo na tela.
- `tail -n 1` lê apenas o final do arquivo (internamente pode até evitar processar o arquivo inteiro), enquanto percorrer manualmente 10.000 linhas exibidas por `cat` seria lento e pouco prático.

**Bloco 2**
- `-v` inverte a seleção: `grep -v staff` mostra todas as linhas que **não** contêm o padrão `staff`, em vez das que contêm.
- `grep -c` conta o número de linhas que contêm ao menos uma ocorrência do padrão, não o número total de ocorrências. Como `ana` aparece em duas linhas diferentes (uma vez por linha), o resultado é `2`.

**Bloco 3**
- Sem `-d:`, o `cut` usaria o delimitador padrão, que é o caractere de tabulação (`TAB`). Como `users.txt` usa `:` como separador, `cut -f1` sem `-d:` retornaria a linha inteira, já que não há tabulações no arquivo.
- Para extrair por posição de caractere (em vez de campo delimitado), usa-se a opção `-c`, por exemplo `cut -c1-5`.

**Bloco 4**
- `-t:` diz ao `sort` que o delimitador de campo é `:`; sem isso, `sort` usaria espaço em branco como delimitador padrão e não conseguiria identificar corretamente o "terceiro campo" separado por `:`.
- Sem `-u`, `sort` apenas ordenaria os nomes (incluindo a repetição de `ana`), sem removê-los. Usar `sort -u` diretamente no arquivo original (sem `cut`) ordenaria e removeria linhas duplicadas *inteiras*, mas como cada linha tem ID diferente, nenhuma linha seria considerada duplicada — por isso o `cut` antes é necessário para comparar apenas os nomes.

**Bloco 5**
- `>` sobrescreve o arquivo de destino (apaga o conteúdo anterior, se existir); `>>` acrescenta o conteúdo ao final do arquivo, preservando o que já estava lá.
- O terminal normalmente mostra tanto o standard output quanto o standard error. `2>` redireciona especificamente o descritor de arquivo 2 (standard error) para `erros.log`, então a mensagem de erro deixa de aparecer na tela e passa a ser gravada no arquivo.

**Bloco 6**
- Não é estritamente necessário: `grep dev users.txt | wc -l` produz o mesmo resultado, porque `grep` já aceita um nome de arquivo como argumento. Usar `cat arquivo | comando` sem necessidade é conhecido informalmente como "useless use of cat", já que introduz um processo extra sem necessidade.
- `uniq` remove linhas duplicadas **consecutivas** da entrada. Ele só remove corretamente todas as duplicatas porque `sort` já agrupou as linhas iguais lado a lado antes; sem a ordenação prévia, duplicatas não adjacentes não seriam eliminadas.

**Bloco 7**
- `tee` permite ver a saída no terminal **e** gravá-la em um arquivo ao mesmo tempo, o que é útil para acompanhar o progresso de um comando enquanto ainda se guarda o resultado — algo que `>` sozinho não permite, pois redireciona toda a saída exclusivamente para o arquivo.
- `-a` faz o `tee` acrescentar ao arquivo em vez de sobrescrevê-lo, comportamento equivalente ao do operador `>>` no Bloco 5.

**Bloco 8**
- `touch` não lê o standard input como lista de argumentos — ele apenas cria/atualiza os arquivos passados diretamente como argumentos na linha de comando. Um pipe (`|`) conecta a saída de um comando ao standard input do próximo, mas `touch` ignora o standard input, então nenhum arquivo seria criado a partir dos nomes recebidos pelo pipe.
- `xargs` é necessário quando o comando de destino (como `touch` ou `rm`) espera receber os valores como **argumentos da linha de comando**, e não como texto vindo pelo standard input. `xargs` converte a entrada padrão recebida do pipe em argumentos posicionais para o comando seguinte.

**Bloco 9**
- `grep dev users.txt` filtra as linhas com `dev`; o resultado passa por `cut -d: -f1`, que extrai apenas o nome de usuário de cada linha filtrada; em seguida `sort` ordena esses nomes alfabeticamente; por fim `tee revisao.txt` grava o resultado ordenado em `revisao.txt` e, simultaneamente, o exibe no terminal.
- Bastaria adicionar `2> revisao_erros.log` ao final do pipe completo (por exemplo, depois de `tee revisao.txt`), redirecionando apenas o standard error de todo o pipeline para esse arquivo, sem interferir no standard output que já está sendo exibido e salvo por `tee`.

</details>