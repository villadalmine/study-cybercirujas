# Exercícios: 2.4 Creating, Moving and Deleting Files

**Certificação:** LPI Linux Essentials (010-160, versão 1.6)
**Tópico:** 2.4 Creating, Moving and Deleting Files — peso 2
**Fonte de referência:** https://learning.lpi.org/en/learning-materials/010-160/2/2.4/

Estes exercícios são práticos: abra um terminal Linux e execute os comandos na ordem indicada. Trabalhe dentro de um diretório de testes para não afetar arquivos importantes.

---

## Exercício 1 — Preparando o ambiente e criando arquivos com `touch`

1. Vá para o seu diretório home:
   ```bash
   cd ~
   ```
2. Crie um diretório de trabalho para os exercícios:
   ```bash
   mkdir lpi-exercicios
   ```
3. Entre nele:
   ```bash
   cd lpi-exercicios
   ```
4. Crie três arquivos vazios de uma vez usando `touch`:
   ```bash
   touch notas.txt relatorio.txt rascunho.txt
   ```
5. Liste o conteúdo do diretório para confirmar:
   ```bash
   ls -l
   ```

**Perguntas:**

1. O que acontece se você usar `touch` em um arquivo que já existe? Ele é apagado e recriado vazio?
2. É possível criar múltiplos arquivos com um único comando `touch`? Como?

---

## Exercício 2 — Criando estruturas de diretórios com `mkdir -p`

1. Ainda dentro de `~/lpi-exercicios`, tente criar uma estrutura aninhada sem a opção `-p`:
   ```bash
   mkdir projeto/src/backend
   ```
2. Observe a mensagem de erro retornada pelo shell.
3. Agora crie a mesma estrutura usando a opção `-p` (parents):
   ```bash
   mkdir -p projeto/src/backend
   ```
4. Confirme que os diretórios intermediários foram criados:
   ```bash
   find projeto -type d
   ```

**Perguntas:**

1. Por que o comando do passo 1 falhou?
2. O que a opção `-p` faz exatamente, e por que ela evita o erro anterior?

---

## Exercício 3 — Copiando arquivos e diretórios com `cp`

1. Copie `notas.txt` para dentro de `projeto/`:
   ```bash
   cp notas.txt projeto/
   ```
2. Copie o mesmo arquivo, mas com um novo nome, para `projeto/src/`:
   ```bash
   cp notas.txt projeto/src/notas-backup.txt
   ```
3. Tente copiar o diretório inteiro `projeto` para um novo diretório `projeto-copia` sem nenhuma opção:
   ```bash
   cp projeto projeto-copia
   ```
4. Observe o erro e repita a operação usando a opção `-r` (recursive):
   ```bash
   cp -r projeto projeto-copia
   ```
5. Verifique que a cópia é idêntica ao original:
   ```bash
   diff -r projeto projeto-copia
   ```

**Perguntas:**

1. Por que `cp` sozinho não conseguiu copiar um diretório?
2. O que o comando `diff -r` reportou, e o que isso indica sobre o resultado do `cp -r`?

---

## Exercício 4 — Movendo e renomeando com `mv`

1. Mova `relatorio.txt` para dentro de `projeto/`:
   ```bash
   mv relatorio.txt projeto/
   ```
2. Renomeie `rascunho.txt` para `rascunho-final.txt`, ainda no diretório atual:
   ```bash
   mv rascunho.txt rascunho-final.txt
   ```
3. Mova o diretório `projeto-copia` inteiro para dentro de `projeto/src/`:
   ```bash
   mv projeto-copia projeto/src/
   ```
4. Liste a árvore de diretórios resultante:
   ```bash
   find projeto -maxdepth 3
   ```

**Perguntas:**

1. Qual a diferença conceitual entre usar `mv` para renomear um arquivo e usar `mv` para movê-lo para outro diretório?
2. `mv` precisa da opção `-r` para mover diretórios inteiros, como `cp` precisa? Por quê?

---

## Exercício 5 — Removendo arquivos e diretórios com `rm` e `rmdir`

1. Crie um diretório vazio para testar `rmdir`:
   ```bash
   mkdir diretorio-vazio
   ```
2. Remova esse diretório vazio:
   ```bash
   rmdir diretorio-vazio
   ```
3. Tente remover o diretório `projeto/src/projeto-copia` (que não está vazio) usando `rmdir`:
   ```bash
   rmdir projeto/src/projeto-copia
   ```
4. Observe o erro e remova-o corretamente usando `rm -r`:
   ```bash
   rm -r projeto/src/projeto-copia
   ```
5. Remova o arquivo `rascunho-final.txt` (não é necessário `-r` para arquivos simples):
   ```bash
   rm rascunho-final.txt
   ```

**Perguntas:**

1. Por que `rmdir` recusou remover `projeto/src/projeto-copia`?
2. Que cuidado especial se deve ter ao usar `rm -r`, comparado a `rmdir`?

---

## Exercício 6 — Wildcards (globbing): `*`, `?` e `[]`

1. Dentro de `~/lpi-exercicios`, crie alguns arquivos de teste:
   ```bash
   touch relatorio1.txt relatorio2.txt relatorioA.txt notas.log config.bak
   ```
2. Liste todos os arquivos que terminam em `.txt` usando `*`:
   ```bash
   ls *.txt
   ```
3. Liste apenas os arquivos `relatorio` seguidos de exatamente um caractere antes de `.txt`, usando `?`:
   ```bash
   ls relatorio?.txt
   ```
4. Liste apenas os arquivos `relatorio1.txt` ou `relatorio2.txt` usando um conjunto de caracteres `[]`:
   ```bash
   ls relatorio[12].txt
   ```
5. Copie todos os arquivos `.txt` para o diretório `projeto/` de uma vez, usando wildcard:
   ```bash
   cp *.txt projeto/
   ```

**Perguntas:**

1. Qual a diferença entre o wildcard `*` e o wildcard `?`?
2. O comando `ls relatorio?.txt` do passo 3 lista `relatorioA.txt`? E o comando `ls relatorio[12].txt` do passo 4?

---

## Exercício 7 — Executando comandos em sequência com `;`

1. Crie um diretório e entre nele em uma única linha, usando `;` para separar os comandos:
   ```bash
   mkdir sequencia-teste; cd sequencia-teste
   ```
2. Confirme em qual diretório você está agora:
   ```bash
   pwd
   ```
3. Volte ao diretório anterior, crie um arquivo e liste o conteúdo, tudo em uma linha:
   ```bash
   cd ..; touch arquivo-sequencial.txt; ls
   ```

**Perguntas:**

1. Os comandos separados por `;` são executados em paralelo ou um após o outro?
2. Se o primeiro comando de uma sequência com `;` falhar, os comandos seguintes ainda são executados?

---

<details>
<summary>Respostas</summary>

**Exercício 1**

1. Não. Se o arquivo já existe, `touch` não apaga nem altera seu conteúdo — apenas atualiza o timestamp de última modificação (mtime) e acesso. Se o arquivo não existe, `touch` o cria vazio.
2. Sim, basta listar os nomes separados por espaço após o comando: `touch arquivo1 arquivo2 arquivo3`.

**Exercício 2**

1. Porque `mkdir`, sem opções, exige que o diretório pai (`projeto`, e depois `projeto/src`) já exista antes de criar o subdiretório final. Como `projeto` não existia, o comando falhou.
2. A opção `-p` (parents) faz com que `mkdir` crie automaticamente todos os diretórios intermediários necessários no caminho, além do diretório final, sem retornar erro caso algum deles já exista.

**Exercício 3**

1. Porque, por padrão, `cp` copia apenas arquivos individuais. Para copiar um diretório e todo o seu conteúdo (incluindo subdiretórios), é necessário indicar explicitamente que a cópia deve ser recursiva.
2. `diff -r` não reportou nenhuma diferença (saída vazia), indicando que `projeto-copia` é uma cópia exata da estrutura e do conteúdo de `projeto`.

**Exercício 4**

1. Não há diferença de comando — em ambos os casos usa-se `mv origem destino`. A diferença está apenas no destino informado: se o destino é um novo nome no mesmo diretório, o efeito é renomear; se o destino é um diretório existente, o efeito é mover o arquivo para lá (mantendo o nome, a menos que um novo nome seja especificado no destino).
2. Não. Diferente de `cp`, `mv` não precisa da opção `-r` para mover diretórios inteiros, porque `mv` não copia o conteúdo bloco a bloco — ele apenas atualiza a referência (entrada) do arquivo/diretório no sistema de arquivos, o que funciona da mesma forma para arquivos e diretórios.

**Exercício 5**

1. Porque `rmdir` só remove diretórios vazios. Como `projeto/src/projeto-copia` continha arquivos e subdiretórios, `rmdir` recusou a operação.
2. `rm -r` remove arquivos e diretórios de forma recursiva e, sem a opção `-i`, não pede confirmação — a exclusão é imediata e não há lixeira por padrão. É preciso conferir cuidadosamente o caminho antes de executar, especialmente combinado com wildcards.

**Exercício 6**

1. `*` corresponde a zero ou mais caracteres quaisquer, enquanto `?` corresponde a exatamente um caractere.
2. Não. `relatorioA.txt` tem uma letra (não um dígito) na posição do `?`/`[]`, mas isso não importa para `?`, que aceita qualquer caractere — então `ls relatorio?.txt` **lista** `relatorioA.txt` também. Já `ls relatorio[12].txt` só lista arquivos em que esse caractere seja exatamente `1` ou `2`, portanto **não** lista `relatorioA.txt`.

**Exercício 7**

1. Um após o outro, sequencialmente (execução síncrona), na ordem em que aparecem na linha.
2. Sim. O `;` apenas separa comandos para executá-los em sequência; ele não interrompe a sequência se um comando anterior falhar (diferente de `&&`, que só executa o comando seguinte se o anterior tiver sucesso).

</details>