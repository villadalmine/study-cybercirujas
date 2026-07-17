# LPI Linux Essentials (010-160) — Tópico 2.3: Using Directories and Listing Files

Peso no exame: 2

Fonte de referência: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/

## Exercício 1 — Onde estou? (`pwd` e a estrutura de diretórios)

1. Abra um terminal Linux.
2. Digite `pwd` e pressione Enter.
3. Observe a saída: é o **absolute path** do seu diretório atual, começando pela **root directory** (`/`).
4. Digite `ls` e Enter para listar o conteúdo do diretório atual.
5. Digite `echo $HOME` e observe que o resultado corresponde ao seu **home directory** (geralmente `/home/seu_usuario`, ou `/root` para o superusuário).

**Perguntas de verificação:**
- Qual comando mostra o absolute path do diretório atual?
- O que representa o caractere `/` sozinho, no início de um path?

## Exercício 2 — Navegando com `cd`

1. A partir do seu home directory, digite `cd /` e Enter.
2. Digite `pwd` para confirmar que você está na root directory.
3. Digite `cd /etc` e depois `pwd`.
4. Digite `cd ..` e depois `pwd`. Observe que `..` sobe um nível na hierarquia.
5. Digite `cd .` e depois `pwd`. Observe que `.` representa o próprio diretório atual (nada muda).
6. Digite `cd ~` (ou apenas `cd` sem argumentos) e depois `pwd`. Você volta ao home directory.
7. Digite `cd /etc` novamente e, em seguida, `cd -`. Observe que `cd -` retorna ao diretório anterior.

**Perguntas de verificação:**
- Qual a diferença entre `cd ..` e `cd .`?
- O que faz `cd -`?
- Se você está em `/etc` e digita `cd network`, isso é um relative path ou absolute path? Por quê?

## Exercício 3 — Listando arquivos com opções de `ls`

1. Vá para o seu home directory: `cd ~`.
2. Digite `ls` e observe a lista simples de arquivos e diretórios (hidden files não aparecem).
3. Digite `ls -a`. Observe que agora aparecem também os **hidden files** (nomes começando com `.`), incluindo `.` e `..`.
4. Digite `ls -l`. Observe o **long listing format**: permissões, número de links, owner, group, tamanho e data de modificação.
5. Digite `ls -lh`. Compare o campo de tamanho com o do passo anterior — a opção `-h` (**human-readable**) exibe tamanhos em KB, MB, GB.
6. Digite `ls -d */`. Observe que apenas diretórios são listados (a opção `-d` lista a entrada do próprio diretório em vez de seu conteúdo, útil combinada com glob patterns).
7. Digite `ls -R /etc/cron.d` (ou outro diretório pequeno). Observe que `-R` (**recursive**) lista também o conteúdo de subdiretórios.

**Perguntas de verificação:**
- Qual opção de `ls` exibe hidden files?
- Para que serve a opção `-l` de `ls`?
- Qual opção faz `ls` percorrer subdiretórios recursivamente?

## Exercício 4 — Criando e removendo diretórios

1. No seu home directory, digite `mkdir teste_lpi` e Enter.
2. Digite `ls` para confirmar que o diretório `teste_lpi` foi criado.
3. Digite `mkdir projeto/docs/rascunhos` e observe o erro (a criação falha porque os diretórios pai `projeto` e `projeto/docs` ainda não existem).
4. Digite `mkdir -p projeto/docs/rascunhos` e Enter. A opção `-p` (**parents**) cria toda a hierarquia de diretórios pais necessária, sem erro.
5. Digite `ls -R projeto` para conferir a árvore criada.
6. Digite `rmdir teste_lpi` para remover o diretório vazio criado no passo 1.
7. Tente `rmdir projeto`. Observe o erro: `rmdir` só remove diretórios vazios, e `projeto` contém `docs`.

**Perguntas de verificação:**
- O que acontece se você rodar `mkdir` para um path cujo diretório pai não existe, sem usar `-p`?
- Por que `rmdir projeto` falhou no passo 7?
- Qual comando (fora do escopo deste tópico) seria necessário para remover `projeto` com todo o seu conteúdo?

## Exercício 5 — Hidden files e o diretório home

1. Digite `cd ~` e depois `ls -a`.
2. Identifique pelo menos um hidden file (por exemplo, `.bashrc` ou `.bash_history`).
3. Digite `ls -la ~` e observe as duas primeiras entradas: `.` e `..`.
4. Digite `head -5 .bashrc` (ou outro dotfile presente) para ver que hidden files são arquivos comuns, apenas não exibidos por padrão.
5. Crie um hidden directory de teste: `mkdir .config_teste` e depois `ls` — ele não aparece — seguido de `ls -a`, onde ele aparece.

**Perguntas de verificação:**
- O que torna um arquivo ou diretório "hidden" no Linux?
- O que significam as entradas `.` e `..` dentro da listagem de qualquer diretório?

---

<details>
<summary>Respostas</summary>

**Exercício 1**
- `pwd` (print working directory) mostra o absolute path do diretório atual.
- `/` sozinho representa a root directory, o topo da hierarquia de diretórios do Linux — todos os demais diretórios e arquivos ficam abaixo dela.

**Exercício 2**
- `cd ..` sobe um nível na hierarquia (vai para o diretório pai); `cd .` mantém você no mesmo diretório, pois `.` referencia o diretório atual.
- `cd -` volta para o diretório em que você estava antes do último `cd`, alternando entre os dois últimos diretórios visitados.
- É um relative path, porque não começa com `/`. O shell interpreta `network` a partir do diretório atual (resultando em `/etc/network`), e não a partir da root directory.

**Exercício 3**
- `ls -a` (all) exibe hidden files.
- `-l` exibe o long listing format, com permissões, owner, group, tamanho e data de modificação.
- `-R` (recursive) lista também o conteúdo de subdiretórios.

**Exercício 4**
- `mkdir` falha com um erro do tipo "No such file or directory", pois por padrão ele não cria diretórios pai ausentes.
- `rmdir` só remove diretórios vazios; `projeto` continha o subdiretório `docs`, então não estava vazio.
- Seria necessário `rm -r` (fora do escopo deste tópico, mas útil saber) para remover um diretório e todo o seu conteúdo recursivamente.

**Exercício 5**
- No Linux, um arquivo ou diretório é considerado hidden quando seu nome começa com um ponto (`.`). Ele não aparece em uma listagem `ls` comum, apenas com `-a` (ou `-A`).
- `.` representa o próprio diretório atual, e `..` representa o diretório pai — ambos existem em todo diretório do sistema de arquivos.

</details>