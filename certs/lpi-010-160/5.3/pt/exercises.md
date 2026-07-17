# Exercícios Guiados — Tema 5.3: Managing File Permissions and Ownership

**Certificação:** LPI Linux Essentials (010-160, versão 1.6) · **Peso no exame:** 2

Estes exercícios são práticos. Abra um terminal em qualquer sistema Linux (uma máquina virtual ou container serve). Tudo acontece dentro de um diretório descartável no seu home, então nada aqui compromete o sistema; alguns passos usam `sudo` para demonstrar mudanças de ownership. Depois de cada bloco, responda às perguntas antes de conferir as respostas no final.

> Referência: LPI Learning Materials, Tema 5.3 — https://learning.lpi.org/en/learning-materials/010-160/5/5.3/

---

## Exercício 1 — Lendo a string de permissões

Toda listagem de arquivo começa com uma string de 10 caracteres que codifica o tipo do arquivo e três conjuntos de permissões. Aprenda a lê-la antes de alterar qualquer coisa.

1. Crie um playground e alguns objetos para inspecionar:
   ```bash
   mkdir ~/perms-lab && cd ~/perms-lab
   touch relatorio.txt
   mkdir arquivados
   echo "segredo" > .nota-oculta
   ```
2. Liste o diretório em formato longo:
   ```bash
   ls -l
   ```
   Leia cada linha como: `tipo + permissões`, contador de hard links, **owner**, **group**, tamanho, timestamp, nome.
3. O arquivo oculto não apareceu. Liste de novo incluindo entradas ocultas:
   ```bash
   ls -la
   ```
4. Compare o primeiro caractere da linha de `relatorio.txt` com o primeiro caractere da linha de `arquivados`. Depois olhe um device file e um symbolic link para contraste:
   ```bash
   ls -l /dev/null /etc/localtime
   ```

**Perguntas**

- **1a.** Na string `-rw-r--r--`, o que indica o primeiríssimo caractere, e o que significaria `d` ou `l` nessa posição?
- **1b.** Os nove caracteres restantes formam três grupos de três. Quais são as três *classes* de usuários que eles descrevem, em ordem?
- **1c.** O que torna um arquivo "oculto" no Linux, e qual opção do `ls` revela arquivos ocultos?
- **1d.** Na saída de `ls -l` para `relatorio.txt`, quais duas colunas indicam o owner e o group dono?

---

## Exercício 2 — O que r, w e x significam em arquivos

As mesmas três letras têm significados precisos em arquivos regulares: ler o conteúdo, alterar o conteúdo, executar como programa.

1. Ainda dentro de `~/perms-lab`, crie um script pequeno:
   ```bash
   echo -e '#!/bin/bash\necho "Funcionou!"' > ola.sh
   ls -l ola.sh
   ```
2. Tente executá-lo — isso deve falhar:
   ```bash
   ./ola.sh
   ```
3. Conceda permissão de execute ao owner usando **modo simbólico**, e execute de novo:
   ```bash
   chmod u+x ola.sh
   ls -l ola.sh
   ./ola.sh
   ```
4. Agora remova sua própria permissão de leitura e veja o que quebra:
   ```bash
   chmod u-r ola.sh
   cat ola.sh
   ./ola.sh
   ```
5. Restaure o acesso de leitura:
   ```bash
   chmod u+r ola.sh
   ```

**Perguntas**

- **2a.** Por que `./ola.sh` falhou no passo 2, mesmo você tendo acabado de criar o arquivo?
- **2b.** Em `chmod u+x`, o que representam o `u`, o `+` e o `x`? O que faria `chmod go-w arquivo`?
- **2c.** Depois do passo 4 o script tinha execute mas não tinha read para você — e executá-lo continuou falhando. Por que um shell script precisa de `r` *e* `x` para rodar?

---

## Exercício 3 — O que r, w e x significam em diretórios

Em diretórios as mesmas letras significam outra coisa: `r` lista nomes, `w` cria/apaga entradas, `x` permite entrar no diretório e alcançar o que está dentro.

1. Monte uma árvore pequena:
   ```bash
   cd ~/perms-lab
   mkdir cofre
   echo "conteudo" > cofre/dados.txt
   ```
2. Remova o *execute* do diretório e tente trabalhar com ele:
   ```bash
   chmod u-x cofre
   ls cofre
   cat cofre/dados.txt
   cd cofre
   ```
   Observe exatamente quais comandos falham.
3. Restaure o execute, depois remova o *read* no lugar dele:
   ```bash
   chmod u+x cofre
   chmod u-r cofre
   ls cofre
   cat cofre/dados.txt
   ```
4. Restaure o read, depois remova o *write* e tente criar e apagar arquivos dentro:
   ```bash
   chmod u+r cofre
   chmod u-w cofre
   touch cofre/novo.txt
   rm cofre/dados.txt
   ```
5. Limpe as permissões:
   ```bash
   chmod u+w cofre
   ```

**Perguntas**

- **3a.** Com `r` mas sem `x` num diretório (situação invertida do passo 2, testada no passo 3), `ls cofre` funciona parcialmente mas `cat cofre/dados.txt` falha. Explique o que cada um de `r` e `x` permite num diretório.
- **3b.** No passo 4 você não conseguiu apagar `cofre/dados.txt` mesmo *sendo o owner desse arquivo e ele sendo gravável*. Qual permissão, em qual objeto, controla apagar um arquivo?
- **3c.** Um diretório que outros podem atravessar mas não listar é uma configuração comum em sistemas compartilhados. Qual combinação de permissões no diretório obtém "pode atravessar, não pode listar"?

---

## Exercício 4 — Modo octal (numérico)

Cada trio de permissões pode ser escrito como um único dígito: `r = 4`, `w = 2`, `x = 1`, somados. Três dígitos descrevem owner, group e others de uma vez.

1. Crie um arquivo e defina alguns modos clássicos, conferindo o resultado a cada passo:
   ```bash
   cd ~/perms-lab
   touch numeros.txt
   chmod 644 numeros.txt && ls -l numeros.txt
   chmod 600 numeros.txt && ls -l numeros.txt
   chmod 755 numeros.txt && ls -l numeros.txt
   chmod 777 numeros.txt && ls -l numeros.txt
   ```
2. Converta no sentido contrário — defina um modo simbolicamente e preveja o número antes de conferir:
   ```bash
   chmod u=rwx,g=rx,o= numeros.txt
   ls -l numeros.txt
   stat -c "%a %n" numeros.txt
   ```
3. Aplique um modo recursivamente numa árvore inteira:
   ```bash
   mkdir -p projeto/src
   touch projeto/src/main.c
   chmod -R 750 projeto
   ls -lR projeto
   ```

**Perguntas**

- **4a.** Decodifique `644`, `755` e `600` em strings de permissão (estilo `rwxrwxrwx`). Qual dos três é o padrão típico para um arquivo de texto novo, e qual para um diretório ou programa?
- **4b.** Que número octal corresponde a `rw-rw-r--`? E a `r-xr-x---`?
- **4c.** Por que `chmod 777` quase sempre é uma má ideia, mesmo quando "faz o erro sumir"?
- **4d.** O que faz a opção `-R` do `chmod`, e por que é preciso cuidado ao aplicar `755` recursivamente numa árvore que mistura diretórios com arquivos de dados comuns?

---

## Exercício 5 — Modo simbólico em profundidade

O modo simbólico se destaca quando você quer ajustar uma classe sem recalcular o número inteiro.

1. Redefina um arquivo para um estado conhecido:
   ```bash
   cd ~/perms-lab
   touch memo.txt
   chmod 644 memo.txt
   ```
2. Pratique alterações pontuais, conferindo com `ls -l memo.txt` depois de cada uma:
   ```bash
   chmod g+w memo.txt        # adiciona write para o group
   chmod o-r memo.txt        # remove read de others
   chmod a+x memo.txt        # adiciona execute para todo mundo
   chmod u=rw,go= memo.txt   # define permissões exatas, zerando o resto
   ```
3. Combine várias alterações num único comando:
   ```bash
   chmod u+x,g+r,o-rwx memo.txt
   ls -l memo.txt
   ```

**Perguntas**

- **5a.** Quais são as quatro letras de *classe* aceitas pelo `chmod` simbólico, e a quais classes cada uma se aplica?
- **5b.** Explique a diferença entre os operadores `+`, `-` e `=`. Qual deles é "seguro" no sentido de só mexer nos bits que você nomeia?
- **5c.** Depois de `chmod u=rw,go= memo.txt`, qual é o modo octal do arquivo?

---

## Exercício 6 — Alterando ownership: chown e chgrp

Todo arquivo tem exatamente um owner e um group dono. Usuários comuns só podem ceder o group para grupos aos quais pertencem; trocar o *owner* é reservado a `root`.

1. Veja sua própria identidade e memberships de grupo:
   ```bash
   id
   ```
2. Crie um arquivo e tente doá-lo como usuário comum — isso deve falhar:
   ```bash
   cd ~/perms-lab
   touch transferencia.txt
   chown root transferencia.txt
   ```
3. Faça o mesmo com privilégios administrativos, e inspecione:
   ```bash
   sudo chown root transferencia.txt
   ls -l transferencia.txt
   ```
4. Troque owner *e* group num único comando, depois só o group:
   ```bash
   sudo chown root:root transferencia.txt
   sudo chgrp $USER transferencia.txt
   ls -l transferencia.txt
   ```
5. Crie um group compartilhado, adicione um arquivo a ele, e passe uma árvore inteira recursivamente:
   ```bash
   sudo groupadd equipe-projeto
   mkdir compartilhado
   touch compartilhado/plano.txt
   sudo chown -R :equipe-projeto compartilhado
   ls -l compartilhado
   ```

**Perguntas**

- **6a.** Por que trocar o owner com `chown` é restrito a `root`? Pense no que um usuário poderia fazer com disk quotas ou com a responsabilização por arquivos maliciosos.
- **6b.** Qual é a diferença entre `chown ana arquivo`, `chown ana:staff arquivo` e `chown :staff arquivo`? Qual dos três o `chgrp` consegue replicar?
- **6c.** Depois do passo 3, você ainda consegue editar `transferencia.txt`? Confira com `ls -l` e explique qual trio de permissões passa a valer para você.

---

## Exercício 7 — Permissões especiais: setuid, setgid e sticky bit

Três bits extras aparecem na mesma string: `s` no trio do owner (setuid), `s` no trio do group (setgid), e `t` no trio de others (sticky).

1. Encontre um programa setuid clássico e inspecione-o:
   ```bash
   ls -l /usr/bin/passwd
   ```
   Observe o `s` onde você esperaria o `x` do owner.
2. Olhe o diretório temporário gravável por todos:
   ```bash
   ls -ld /tmp
   ```
   Observe o `t` no final da string de permissões.
3. Crie um diretório de colaboração com setgid e observe a herança de group:
   ```bash
   cd ~/perms-lab
   mkdir dir-equipe
   sudo chgrp equipe-projeto dir-equipe
   chmod g+s dir-equipe
   ls -ld dir-equipe
   touch dir-equipe/novo-arquivo.txt
   ls -l dir-equipe/novo-arquivo.txt
   ```
4. Em octal, os bits especiais são um quarto dígito na frente: setuid = 4, setgid = 2, sticky = 1. Reproduza o modo de `/tmp` num diretório de teste:
   ```bash
   mkdir area-descarte
   chmod 1777 area-descarte
   ls -ld area-descarte
   ```

**Perguntas**

- **7a.** `passwd` precisa editar `/etc/shadow`, que só `root` pode escrever — mas qualquer usuário consegue trocar sua própria senha. Como o bit setuid torna isso possível?
- **7b.** O que o sticky bit em `/tmp` impede, dado que `/tmp` é gravável por todos?
- **7c.** No passo 3, qual group é dono de `dir-equipe/novo-arquivo.txt`, e por que isso é útil num diretório compartilhado por uma equipe?
- **7d.** Decodifique o modo `1777` do passo 4, dígito por dígito.

---

## Limpeza

Remova tudo o que os exercícios criaram:

```bash
cd ~
sudo rm -rf ~/perms-lab
sudo groupdel equipe-projeto
```

---

<details>
<summary><strong>Respostas</strong></summary>

### Exercício 1

- **1a.** O primeiro caractere é o **tipo do arquivo**: `-` significa arquivo regular, `d` um diretório, e `l` um symbolic link. (Existem outros valores, como `c` e `b` para character e block devices.)
- **1b.** Em ordem: o **owner** (usuário dono) do arquivo, o **group** dono, e **others** (todos os demais). Cada classe tem seu próprio trio `rwx`.
- **1c.** Um arquivo fica oculto simplesmente porque seu nome começa com ponto (`.`). Não existe um atributo "oculto" separado. `ls -a` (ou `-la` combinado com formato longo) revela dot files.
- **1d.** A terceira coluna é o owner e a quarta coluna é o group dono (logo depois do contador de links, antes do tamanho).

### Exercício 2

- **2a.** Criar um arquivo não o torna executável. Arquivos novos costumam nascer só com permissões de leitura/escrita (ex.: `rw-r--r--`), então a shell recusa executá-lo com "Permission denied" até o bit `x` ser definido.
- **2b.** `u` seleciona a classe **user/owner**, `+` significa **adicionar** a permissão, e `x` é **execute**. `chmod go-w arquivo` remove (`-`) a permissão de write (`w`) tanto do group (`g`) quanto de others (`o`).
- **2c.** Para rodar um shell script, o kernel verifica o bit `x`, mas depois o interpretador (`/bin/bash`) precisa *abrir e ler* o texto do script — o que exige `r`. Binários compilados podem rodar só com `x`, mas scripts interpretados precisam de `r` e `x` juntos.

### Exercício 3

- **3a.** Num diretório, `r` permite **listar os nomes** das entradas, enquanto `x` permite **atravessá-lo** — alcançar os inodes internos, necessário para abrir arquivos, dar `cd`, ou até ler metadados de arquivos. Com `r` mas sem `x`, o `ls` pode mostrar nomes (muitas vezes com erros nos detalhes), mas nenhum arquivo interno pode de fato ser aberto.
- **3b.** Apagar um arquivo significa **remover uma entrada do diretório**, então isso é controlado pela **permissão de write no diretório** que contém o arquivo — não pelas permissões do arquivo em si. Sem `w` em `cofre`, nem `touch` (criar) nem `rm` (apagar) dentro dele funcionam.
- **3c.** Execute sem read: `--x` (ex.: `chmod o=x dir`, ou modos como `711` num diretório home). Usuários conseguem atravessá-lo para alcançar um caminho conhecido dentro, mas `ls` no diretório falha.

### Exercício 4

- **4a.** `644` = `rw-r--r--`, `755` = `rwxr-xr-x`, `600` = `rw-------`. `644` é o padrão típico para um arquivo de texto novo; `755` é típico para diretórios e programas executáveis; `600` cabe a arquivos privados (chaves, spools de e-mail).
- **4b.** `rw-rw-r--` = `664`. `r-xr-x---` = `550`.
- **4c.** `777` dá a todo usuário do sistema acesso total de leitura, escrita e execução. Qualquer um pode modificar ou substituir o arquivo (ou, num diretório, apagar qualquer coisa dentro). Isso "resolve" o sintoma removendo toda a proteção, o que é uma falha de segurança; o conserto correto é conceder à classe específica a permissão específica que falta.
- **4d.** `-R` aplica o modo ao diretório **e a tudo abaixo dele, recursivamente**. Aplicar `755` recursivamente de forma cega torna todo arquivo de dados executável, o que é errado (dados não deveriam carregar `x`); por outro lado, aplicar `644` recursivamente removeria o `x` dos diretórios, quebrando a travessia. Diretórios e arquivos costumam precisar de modos diferentes.

### Exercício 5

- **5a.** `u` = user/owner, `g` = group, `o` = others, `a` = os três de uma vez (equivalente a `ugo`).
- **5b.** `+` **adiciona** as permissões nomeadas ao que já está definido; `-` as **remove**; `=` **define exatamente** as permissões nomeadas, zerando as demais daquela classe. `+` e `-` são os operadores incrementais "seguros" — só tocam nos bits que você nomeia, enquanto `=` sobrescreve o trio inteiro.
- **5c.** `u=rw` dá ao owner `rw-` (6); `go=` zera group e others para `---` (0 e 0). O modo octal é `600`.

### Exercício 6

- **6a.** Se usuários pudessem doar arquivos, poderiam driblar **disk quotas** (cobrar seus arquivos grandes na conta de outra pessoa) ou **transferir a culpa** — plantando um arquivo malicioso ou comprometedor em nome de outro usuário. Ownership faz parte do modelo de responsabilização do sistema, por isso só `root` pode reatribuí-lo.
- **6b.** `chown ana arquivo` troca só o **owner**. `chown ana:staff arquivo` troca **owner e group** de uma vez. `chown :staff arquivo` troca só o **group** — exatamente o que `chgrp staff arquivo` faz; esse é o único dos três que o `chgrp` consegue replicar.
- **6c.** Sim para leitura, não para escrita (com o modo típico `644`). Depois que `root` passa a ser o dono, você deixa de ser o owner; se o group também for `root`, você se enquadra só no trio de **others**, `r--`. Dá para dar `cat` mas um editor não consegue salvar alterações. (Você ainda consegue *apagar* o arquivo, porque o diretório que o contém é seu e gravável — ver 3b.)

### Exercício 7

- **7a.** O bit setuid faz o programa rodar **com a identidade efetiva do owner do arquivo**, em vez da identidade de quem o executou. `passwd` pertence a `root` e tem setuid, então, enquanto roda, tem o poder de `root` e consegue atualizar `/etc/shadow` — mas o próprio programa restringe *o que* fará (só trocar a sua própria senha, depois de verificar a senha atual).
- **7b.** Num diretório gravável por todos, a permissão de write normalmente deixaria *qualquer um* apagar ou renomear arquivos *de outra pessoa* (apagar é uma operação de write no diretório, conforme 3b). O sticky bit (`t`) restringe apagar/renomear naquele diretório ao **owner do arquivo**, ao owner do diretório, e a `root` — assim usuários que compartilham `/tmp` não conseguem remover os temporários uns dos outros.
- **7c.** `equipe-projeto` é dono de `novo-arquivo.txt`. Num diretório com setgid, arquivos novos **herdam o group do diretório** em vez do group primário de quem os criou. Num diretório compartilhado isso significa que todo arquivo automaticamente pertence ao group da equipe, então todos os membros conseguem acessá-lo conforme as permissões de group, sem que ninguém precise rodar `chgrp` manualmente.
- **7d.** O `1` inicial é o **sticky bit**; cada `7` é `rwx` (4+2+1) para owner, group e others respectivamente. Resultado: `rwxrwxrwt` — todo mundo pode criar arquivos, mas só owners podem apagar os seus próprios.

</details>
