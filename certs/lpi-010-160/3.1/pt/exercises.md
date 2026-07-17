# Exercícios Guiados — Tópico 3.1: Archiving Files on the Command Line

**Certificação:** LPI Linux Essentials (010-160, versão 1.6) · **Peso:** 2
**Fonte de referência:** [LPI Learning Materials, Lesson 3.1](https://learning.lpi.org/en/learning-materials/010-160/3/3.1/)

> **Requisitos:** um terminal em qualquer distribuição Linux (serve uma máquina virtual, WSL ou container), com usuário normal (sem `root`). Se `zip`/`unzip` não estiverem instalados, use o gestor de pacotes da sua distro antes do Exercício 5 (`sudo apt install zip unzip` ou `sudo dnf install zip unzip`).

---

## Exercício 1 — Preparando o ambiente e criando o primeiro archive com tar

Você vai montar uma pequena estrutura de arquivos e criar seu primeiro archive **sem compressão**, para entender que `tar` sozinho apenas empacota, não reduz tamanho.

**Passos:**

1. Crie um diretório de trabalho e entre nele:
   ```bash
   mkdir ~/pratica-archiving
   cd ~/pratica-archiving
   ```
2. Monte uma estrutura com conteúdo variado:
   ```bash
   mkdir -p projeto/docs projeto/scripts
   echo "Relatório anual do projeto" > projeto/docs/relatorio.txt
   echo "Notas da reunião de julho" > projeto/docs/notas.txt
   printf '#!/bin/bash\necho "Olá, mundo"\n' > projeto/scripts/saudacao.sh
   ```
3. Gere um arquivo grande com conteúdo repetitivo (ideal para ver o efeito da compressão mais adiante):
   ```bash
   yes "Linux Essentials 010-160" | head -n 100000 > projeto/dados.txt
   ```
4. Confira o tamanho do que foi criado:
   ```bash
   du -sh projeto
   ls -lh projeto/dados.txt
   ```
5. Crie um archive **sem compressão** com todo o diretório `projeto`:
   ```bash
   tar -cvf projeto.tar projeto
   ```
6. Compare o tamanho do archive com o do diretório original:
   ```bash
   ls -lh projeto.tar
   du -sh projeto
   ```
7. Liste o conteúdo do archive **sem extraí-lo**:
   ```bash
   tar -tvf projeto.tar
   ```

**Perguntas de verificação:**

**1.1.** *Archiving* e *compression* são a mesma coisa? Qual ferramenta faz cada uma no fluxo tradicional do Linux?

**1.2.** O que significa cada uma das opções `-c`, `-v` e `-f` usadas no passo 5?

**1.3.** Por que `projeto.tar` ficou com tamanho parecido (ou até levemente maior) do que `du -sh projeto` reportou?

**1.4.** Por que é uma boa prática rodar `tar -tvf` antes de extrair um archive que alguém te enviou? O que acontece se você esquecer a opção `-f`?

---

## Exercício 2 — Comparando compressão: gzip, bzip2 e xz

O `tar` sozinho não comprime — para isso ele delega a um filtro externo. Você vai gerar a mesma estrutura em três formatos comprimidos e comparar os resultados.

**Passos:**

1. Crie três versões comprimidas do mesmo diretório, uma para cada algoritmo:
   ```bash
   tar -czvf projeto.tar.gz projeto
   tar -cjvf projeto.tar.bz2 projeto
   tar -cJvf projeto.tar.xz projeto
   ```
2. Compare os tamanhos resultantes, incluindo o `.tar` sem compressão do exercício anterior:
   ```bash
   ls -lh projeto.tar projeto.tar.gz projeto.tar.bz2 projeto.tar.xz
   ```
3. Liste o conteúdo da versão gzip para confirmar que o `tar` lê o formato comprimido diretamente:
   ```bash
   tar -tzvf projeto.tar.gz
   ```

**Perguntas de verificação:**

**2.1.** Associe cada opção do `tar` ao algoritmo que ela invoca: `-z`, `-j`, `-J`.

**2.2.** Pelos tamanhos observados no passo 2, ordene os três formatos comprimidos do maior para o menor archive resultante. Qual é o *trade-off* típico de usar `xz`?

**2.3.** Quais são as extensões convencionais para cada combinação (`tar` + gzip, `tar` + bzip2, `tar` + xz)? Essas extensões são obrigatórias para o `tar` funcionar?

---

## Exercício 3 — Extraindo archives com tar

Agora você vai restaurar o conteúdo dos archives criados, tanto por completo quanto arquivo por arquivo.

**Passos:**

1. Crie um diretório de destino e extraia a versão gzip **dentro dele**, sem usar `cd`:
   ```bash
   mkdir restaurado
   tar -xzvf projeto.tar.gz -C restaurado
   ```
2. Confira se a estrutura foi restaurada por completo:
   ```bash
   ls -R restaurado
   ```
3. Extraia agora **um único arquivo** do archive, informando o caminho interno exatamente como aparece na listagem:
   ```bash
   tar -xzvf projeto.tar.gz projeto/docs/notas.txt
   ls -l projeto/docs/notas.txt
   ```

**Perguntas de verificação:**

**3.1.** O que faz a opção `-C restaurado` no passo 1? O que teria acontecido sem ela?

**3.2.** Por que no passo 3 é preciso escrever o caminho completo `projeto/docs/notas.txt`, e não apenas `notas.txt`?

**3.3.** Quais são os três modos principais do `tar` (`-c`, `-x`, `-t`)? Eles podem ser combinados em uma mesma chamada?

---

## Exercício 4 — Compressão de arquivos individuais: gzip, bzip2, xz

Diferente do `tar`, `gzip`, `bzip2` e `xz` operam sobre **um arquivo por vez** e, por padrão, **substituem** o original. Você vai observar esse comportamento e a opção que evita perder o arquivo original.

**Passos:**

1. Copie `dados.txt` para experimentar sem afetar o original:
   ```bash
   cp projeto/dados.txt dados-copia.txt
   ```
2. Comprima com `gzip` e veja o que acontece com o arquivo de origem:
   ```bash
   gzip dados-copia.txt
   ls -lh dados-copia.*
   ```
3. Leia o conteúdo do arquivo comprimido **sem descomprimi-lo em disco**:
   ```bash
   zcat dados-copia.txt.gz | head -n 3
   ```
4. Descomprima de volta:
   ```bash
   gunzip dados-copia.txt.gz
   ls -lh dados-copia.txt
   ```
5. Desta vez, comprima com `bzip2` usando a opção que **mantém** o original:
   ```bash
   bzip2 -k dados-copia.txt
   ls -lh dados-copia.txt dados-copia.txt.bz2
   ```
6. Como o original ainda existe, comprima-o também com `xz` e depois limpe tudo:
   ```bash
   xz dados-copia.txt
   ls -lh dados-copia.*
   bunzip2 -k dados-copia.txt.bz2
   unxz dados-copia.txt.xz
   ```

**Perguntas de verificação:**

**4.1.** No passo 2, o que aconteceu com `dados-copia.txt` depois do `gzip`? O que a opção `-k`, usada no passo 5, muda nesse comportamento?

**4.2.** `gzip`, `bzip2` e `xz` comprimem arquivos individuais. O que essas ferramentas **não conseguem** fazer sozinhas, e como isso costuma ser resolvido na prática?

**4.3.** Qual comando você usaria para ver o conteúdo de um `.gz` sem descomprimi-lo em disco? Quais são os equivalentes para `.bz2` e `.xz`?

---

## Exercício 5 — O formato zip

O `zip` arquiva **e** comprime em uma única etapa, e seu formato é o mais compatível com Windows e macOS.

**Passos:**

1. Crie um arquivo zip com o diretório completo (repare que é necessária a opção `-r`):
   ```bash
   zip -r projeto.zip projeto
   ```
2. Liste o conteúdo sem extrair:
   ```bash
   unzip -l projeto.zip
   ```
3. Extraia em um diretório próprio:
   ```bash
   unzip projeto.zip -d restaurado-zip
   ls -R restaurado-zip
   ```
4. Confirme que o diretório original permanece intacto:
   ```bash
   ls projeto
   ```

**Perguntas de verificação:**

**5.1.** Para que serve a opção `-r` do `zip`? O que `projeto.zip` teria contido se ela fosse omitida?

**5.2.** Qual é a diferença conceitual entre `zip` e a combinação `tar` + `gzip` em relação ao **momento** em que cada arquivo é comprimido?

**5.3.** Em que cenário típico você escolheria `zip` em vez de `tar.gz`?

**5.4.** Qual opção do `unzip` cumpre um papel equivalente ao `-C` do `tar`?

---

## Exercício 6 — Desafio integrador

Sem consultar os exercícios anteriores, resolva este mini-cenário. Escreva cada comando antes de executá-lo.

**Passos:**

1. Crie um archive comprimido com `xz` chamado `backup-docs.tar.xz` contendo **somente** o diretório `projeto/docs`.
2. Liste o conteúdo desse archive para confirmar que só inclui o que foi pedido.
3. Extraia-o dentro de um novo diretório chamado `verificacao`.
4. Faça a limpeza final, removendo todo o diretório de prática:
   ```bash
   cd ~ && rm -r ~/pratica-archiving
   ```

**Perguntas de verificação:**

**6.1.** Qual comando você usou no passo 1?

**6.2.** No exame você recebe o arquivo `backup.tgz`. Com qual comando único você o extrai? O que significa a extensão `.tgz`?

**6.3.** As versões modernas do GNU `tar` detectam a compressão automaticamente ao extrair ou listar. Isso significa que `-J` também é dispensável ao **criar** um archive?

---

<details>
<summary><strong>✅ Respostas</strong></summary>

### Exercício 1

**1.1.** Não são a mesma coisa. **Archiving** é reunir vários arquivos e diretórios em um único arquivo, preservando nomes, estrutura e permissões — quem faz isso é o `tar`. **Compression** é reduzir o tamanho dos dados, tarefa de `gzip`, `bzip2` ou `xz`. No fluxo tradicional do Linux, o `tar` empacota primeiro e um compressor reduz o resultado depois.

**1.2.** `-c` (*create*) cria um archive novo; `-v` (*verbose*) mostra na tela cada arquivo processado; `-f` (*file*) indica que o argumento seguinte é o nome do arquivo de archive a ser usado.

**1.3.** Porque `tar` apenas **empacota**, sem comprimir. O archive contém os mesmos dados mais os metadados do próprio formato tar (cabeçalhos por arquivo, blocos de preenchimento), por isso pode ficar até um pouco maior do que o conteúdo original.

**1.4.** Porque permite inspecionar o que o archive contém — e quais caminhos ele vai criar — antes de extrair, evitando sobrescrever arquivos existentes ou espalhar centenas de arquivos no diretório atual. Sem `-f`, `tar` não interpreta `projeto.tar` como nome de arquivo e por padrão tenta usar um dispositivo de fita (o nome `tar` vem de *tape archive*), o que resulta em erro em um sistema atual.

### Exercício 2

**2.1.** `-z` → gzip; `-j` → bzip2; `-J` → xz.

**2.2.** Do maior para o menor archive comprimido: `.tar.gz` (gzip) > `.tar.bz2` (bzip2) > `.tar.xz` (xz) — ou seja, `xz` costuma produzir o menor arquivo. O *trade-off* é que `xz` é o algoritmo mais lento e o que mais consome CPU e memória para comprimir.

**2.3.** `.tar.gz` (também `.tgz`) para gzip, `.tar.bz2` para bzip2, `.tar.xz` para xz. A extensão é só uma convenção para humanos: o `tar` funciona com qualquer nome de arquivo, pois o formato é definido pelas opções usadas (ou detectado automaticamente ao ler), não pelo nome.

### Exercício 3

**3.1.** `-C restaurado` faz o `tar` mudar para o diretório `restaurado` antes de extrair. Sem ela, o conteúdo seria extraído no diretório atual, sobrescrevendo potencialmente o diretório `projeto` já existente.

**3.2.** Porque o `tar` guarda cada membro com o caminho relativo com que foi empacotado. Para extrair um membro específico é preciso nomeá-lo exatamente como aparece na saída de `tar -t`; `notas.txt` sozinho não corresponde a nenhum membro do archive.

**3.3.** `-c` cria, `-x` extrai, `-t` lista. São mutuamente exclusivos: cada chamada do `tar` usa exatamente um desses modos principais.

### Exercício 4

**4.1.** O arquivo original desapareceu, substituído por `dados-copia.txt.gz` — esse é o comportamento padrão de `gzip`, `bzip2` e `xz`. A opção `-k` (*keep*), usada no passo 5, faz a ferramenta manter o arquivo original além de criar o comprimido.

**4.2.** Elas não conseguem empacotar vários arquivos ou diretórios em um único arquivo — operam sobre um arquivo de cada vez. Na prática isso se resolve combinando com `tar`: primeiro ele junta tudo em um archive, depois o compressor reduz esse archive (daí `.tar.gz`, `.tar.bz2`, `.tar.xz`).

**4.3.** `zcat` para `.gz`, `bzcat` para `.bz2` e `xzcat` para `.xz`. As três enviam o conteúdo descomprimido para a saída padrão sem alterar o arquivo em disco.

### Exercício 5

**5.1.** `-r` (*recursive*) faz o `zip` descer pelos subdiretórios e incluir seu conteúdo. Sem ela, `projeto.zip` conteria apenas a entrada do diretório `projeto`, sem os arquivos internos.

**5.2.** O `zip` comprime **cada arquivo individualmente** antes de guardá-lo no contêiner. Já `tar` + `gzip` primeiro empacota tudo e só depois comprime o archive inteiro **como um único fluxo**. Na prática, isso permite extrair um arquivo isolado de um `.zip` sem descomprimir o resto, enquanto um `.tar.gz` costuma comprimir melhor (aproveita redundância entre arquivos), mas exige processar o fluxo completo para chegar a um membro.

**5.3.** Quando quem recebe o arquivo usa Windows ou outro ambiente onde `zip` é o formato nativo, ou quando alguma plataforma/serviço exige explicitamente esse formato — é o formato de intercâmbio multiplataforma mais universal.

**5.4.** `unzip arquivo.zip -d diretorio_destino` extrai dentro do diretório indicado, papel equivalente ao de `tar ... -C diretorio_destino`.

### Exercício 6

**6.1.** `tar -cJvf backup-docs.tar.xz projeto/docs` (o `-v` é opcional). Para o passo 2: `tar -tJvf backup-docs.tar.xz`. Para o passo 3: `mkdir verificacao && tar -xJvf backup-docs.tar.xz -C verificacao`.

**6.2.** `tar -xzvf backup.tgz`. `.tgz` é apenas a forma abreviada de `.tar.gz`: um archive tar comprimido com gzip.

**6.3.** Não necessariamente. Ao **extrair** (`-x`) ou **listar** (`-t`), o GNU `tar` moderno detecta o tipo de compressão lendo o conteúdo do arquivo, então `-J`/`-z`/`-j` tornam-se opcionais nesses casos. Ao **criar** (`-c`), porém, a autodetecção não se aplica da mesma forma: é preciso indicar o compressor explicitamente com `-z`, `-j` ou `-J` (ou usar `-a`, que deduz o algoritmo pela extensão do nome de saída).

</details>

---

*Material original elaborado com fins de estudo. Referências consultadas: [LPI Learning Materials 010-160, Lesson 3.1](https://learning.lpi.org/en/learning-materials/010-160/3/3.1/) · [GNU tar Manual](https://www.gnu.org/software/tar/manual/) · [GNU gzip Manual](https://www.gnu.org/software/gzip/manual/gzip.html) · [bzip2 — documentação oficial](https://sourceware.org/bzip2/docs.html) · [XZ Utils](https://tukaani.org/xz/) · [Info-ZIP (zip / unzip)](https://infozip.sourceforge.net/).*