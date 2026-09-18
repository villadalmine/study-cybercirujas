# 701.3 Source Code Management — Exercícios Guiados

**Exame:** LPI DevOps Tools Engineer, 701-100, versão 2.0.0
**Peso do tópico:** 10
**Referência do objetivo:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estes exercícios são práticos. Cada passo foi feito para ser executado em um shell real; a saída esperada é mostrada para que você consiga distinguir "funcionou" de "pareceu que funcionou". Os hashes de objeto na sua máquina **serão diferentes** dos impressos aqui — um hash de commit inclui o autor, o committer e ambos os timestamps, de modo que duas pessoas nunca produzem o mesmo ID de commit a partir do mesmo arquivo. Os hashes de blob, porém, dependem apenas do conteúdo e *vão* coincidir exatamente.

**Ambiente necessário**

- Um host Linux com `git` ≥ 2.34 (`gpg.format=ssh` e `git switch`/`git restore` como comandos estáveis) e OpenSSH ≥ 8.2.
- Nenhum exercício precisa de acesso à rede. O Exercício 7 constrói seu próprio "servidor" como um repositório bare no sistema de arquivos local; o Exercício 9 explica o único comando que alcançaria um forge real e como ler sua saída.

---

## Exercício 0 — Construir um sandbox isolado

Você está prestes a alterar a configuração global do Git de propósito. Não faça isso na sua conta real. O Git 2.32+ respeita `GIT_CONFIG_GLOBAL`, o que permite redirecionar o `~/.gitconfig` para um arquivo descartável durante toda a sessão.

### Passos

1. Crie o sandbox e fixe uma configuração global isolada:

```bash
mkdir -p /tmp/lpi-701.3 && cd /tmp/lpi-701.3
export GIT_CONFIG_GLOBAL=/tmp/lpi-701.3/gitconfig
export GIT_CONFIG_SYSTEM=/dev/null
touch "$GIT_CONFIG_GLOBAL"
git --version
```

```
git version 2.47.1
```

2. Defina a identidade e os padrões que todo repositório de produção deveria ter:

```bash
git config --global user.name  "Ada Lovelace"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
git config --global core.editor "vi"
git config --global pull.ff only
git config --global merge.conflictstyle zdiff3
git config --global rerere.enabled true
```

3. Inspecione de onde cada ajuste realmente vem:

```bash
git config --list --show-origin --show-scope | head -n 12
```

```
global	file:/tmp/lpi-701.3/gitconfig	user.name=Ada Lovelace
global	file:/tmp/lpi-701.3/gitconfig	user.email=ada@example.com
global	file:/tmp/lpi-701.3/gitconfig	init.defaultbranch=main
global	file:/tmp/lpi-701.3/gitconfig	core.editor=vi
global	file:/tmp/lpi-701.3/gitconfig	pull.ff=only
global	file:/tmp/lpi-701.3/gitconfig	merge.conflictstyle=zdiff3
global	file:/tmp/lpi-701.3/gitconfig	rerere.enabled=true
```

4. Olhe o arquivo que o Git acabou de escrever:

```bash
cat "$GIT_CONFIG_GLOBAL"
```

```ini
[user]
	name = Ada Lovelace
	email = ada@example.com
[init]
	defaultBranch = main
[core]
	editor = vi
[pull]
	ff = only
[merge]
	conflictstyle = zdiff3
[rerere]
	enabled = true
```

### Perguntas de verificação

- **Q0.1** O Git lê configuração de quatro escopos. Nomeie-os na ordem em que são aplicados e diga qual vence quando a mesma chave está definida em vários.
- **Q0.2** `init.defaultbranch` é impresso em minúsculas mesmo você tendo digitado `init.defaultBranch`. Que parte de uma chave de configuração diferencia maiúsculas de minúsculas e qual não diferencia?
- **Q0.3** Qual falha o `pull.ff = only` transforma de um evento silencioso em um evento barulhento?
- **Q0.4** Um repositório precisa receber commits sob uma identidade de trabalho enquanto a identidade global da máquina é pessoal. Qual comando único define isso e qual arquivo ele escreve?

---

## Exercício 1 — O banco de dados de objetos: o que um repositório *é*

O Git é um armazenamento de objetos endereçado por conteúdo com uma UI de controle de versão por cima. Tudo neste exercício usa comandos de plumbing, porque a porcelain esconde exatamente a parte que o exame cobra.

### Passos

1. Crie o repositório e olhe o esqueleto que o Git monta:

```bash
cd /tmp/lpi-701.3
git init app
cd app
find .git -maxdepth 1 | sort
```

```
.git
.git/HEAD
.git/config
.git/description
.git/hooks
.git/info
.git/objects
.git/refs
```

2. Leia o `HEAD` antes de existir qualquer commit:

```bash
cat .git/HEAD
ls .git/refs/heads
git status --short --branch
```

```
ref: refs/heads/main
## No commits yet on main
```

Note que `.git/refs/heads` está **vazio**. `HEAD` aponta para um branch que ainda não existe — é isso que significa "unborn branch" (branch não nascido).

3. Faça o hash de um conteúdo sem tocar no repositório e depois com ele:

```bash
echo "hello world" | git hash-object --stdin
echo "hello world" | git hash-object --stdin -w
git count-objects -v
```

```
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
count: 1
size: 4
in-pack: 0
packs: 0
size-pack: 0
prune-packable: 0
garbage: 0
size-garbage: 0
```

Esse hash é idêntico em todas as máquinas do planeta. Ele é `sha1("blob 12\0hello world\n")`.

4. Encontre o objeto loose no disco e leia-o de volta:

```bash
find .git/objects -type f
git cat-file -t 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -s 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -p 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
```

```
.git/objects/3b/18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
blob
12
hello world
```

5. Construa um commit de verdade e percorra o grafo para baixo a partir dele:

```bash
mkdir -p src
echo "hello world" > src/greet.txt
git add src/greet.txt
git commit -m "feat: add greeting"
git cat-file -p HEAD
```

```
tree 9f6b2c1a4e0d5f3b8a7c6e2d1f0a9b8c7d6e5f4a
author Ada Lovelace <ada@example.com> 1789700000 +0000
committer Ada Lovelace <ada@example.com> 1789700000 +0000

feat: add greeting
```

6. Desça pelas trees até o blob que você criou no passo 3:

```bash
git cat-file -p HEAD^{tree}
git cat-file -p HEAD:src
git cat-file -p HEAD:src/greet.txt
```

```
040000 tree 2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f	src
100644 blob 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7	greet.txt
hello world
```

7. Confirme o que um branch realmente é e conte os objetos que o commit produziu:

```bash
cat .git/refs/heads/main
git rev-parse HEAD
git count-objects -v | head -n 2
```

```
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
count: 4
size: 16
```

### Perguntas de verificação

- **Q1.1** Nomeie os quatro tipos de objeto do Git e diga, para cada um, o que ele armazena.
- **Q1.2** No passo 6 o blob `3b18e5…` aparece com o nome `greet.txt`, mas no passo 3 você o criou a partir do stdin sem nome de arquivo nenhum, e o hash é o mesmo. Onde fica armazenado o nome do arquivo, e qual a consequência prática disso para um repositório que contém o mesmo arquivo de 10 MB em cinco caminhos diferentes?
- **Q1.3** Depois de um commit de um arquivo, `count: 4`. Que quatro objetos são esses?
- **Q1.4** `.git/refs/heads/main` contém 40 caracteres hexadecimais e nada mais. Explique em uma frase por que "criar um branch no Git é barato" é uma afirmação sobre esse arquivo.
- **Q1.5** `git cat-file -p HEAD` imprime um commit que não contém linha `parent`. O que isso diz sobre esse commit, e quantas linhas `parent` teria um merge commit de dois branches?
- **Q1.6** Qual é a diferença entre `git hash-object --stdin` e `git hash-object --stdin -w`, e por que o exame se importa com isso?

---

## Exercício 2 — As três árvores: working tree, index e HEAD

Quase toda mensagem confusa do Git é uma afirmação sobre a *diferença entre duas dessas três*. Este exercício torna cada diferença visível.

### Passos

1. Modifique o arquivo rastreado e adicione um não rastreado:

```bash
cd /tmp/lpi-701.3/app
printf 'hello world\ngoodbye world\n' > src/greet.txt
echo "*.log" > notes.tmp
git status --short --branch
```

```
## main
 M src/greet.txt
?? notes.tmp
```

Leia as duas colunas do status: a coluna da **esquerda** é `HEAD → index`; a da **direita** é `index → working tree`. Um espaço seguido de `M` significa "staged: nada, unstaged: modificado".

2. Faça o stage e veja as colunas trocarem:

```bash
git add src/greet.txt
git status --short
```

```
M  src/greet.txt
?? notes.tmp
```

3. Modifique de novo *depois* do stage — agora as três árvores discordam:

```bash
echo "third line" >> src/greet.txt
git status --short
```

```
MM src/greet.txt
?? notes.tmp
```

4. Peça cada diff explicitamente:

```bash
git diff --stat            # index  -> working tree
git diff --cached --stat   # HEAD   -> index
git diff HEAD --stat       # HEAD   -> working tree
```

```
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 2 ++
 1 file changed, 2 insertions(+)
```

5. Olhe o index como estrutura de dados, não como conceito:

```bash
git ls-files --stage
```

```
100644 5f1c9a0b3d2e4f6a8b7c9d0e1f2a3b4c5d6e7f80 0	src/greet.txt
```

O número de stage `0` significa "sem conflito". Você verá os stages 1, 2 e 3 no Exercício 4.

6. Faça stage seletivo com controle por hunk — o hábito que mantém um commit revisável:

```bash
git reset                      # unstage everything, keep the working tree
git add --patch src/greet.txt
```

O Git mostra um hunk por vez e pergunta:

```
Stage this hunk [y,n,q,a,d,s,e,?]?
```

Responda `s` para dividir o hunk quando ele contém mudanças não relacionadas, `y` para fazer stage, `n` para pular, `q` para parar.

7. Escreva regras de ignore de verdade, incluindo uma negação, e prove qual regra casou:

```bash
cat > .gitignore <<'EOF'
# build artefacts
*.log
*.tmp
/dist/
!important.tmp
EOF
touch important.tmp debug.log
mkdir dist && touch dist/app.bin
git status --short --ignored
git check-ignore -v debug.log important.tmp dist/app.bin
```

```
 M src/greet.txt
?? .gitignore
?? important.tmp
!! debug.log
!! dist/
.gitignore:2:*.log	debug.log
.gitignore:5:!important.tmp	important.tmp
.gitignore:4:/dist/	dist/app.bin
```

8. Prove o limite do `.gitignore` — ele só governa arquivos **não rastreados**:

```bash
git add -f notes.tmp && git commit -q -m "chore: add notes.tmp by mistake"
echo "still tracked" >> notes.tmp
git status --short
```

```
 M notes.tmp
```

9. Pare de rastreá-lo sem apagá-lo e depois mova um arquivo rastreado:

```bash
git rm --cached notes.tmp
git status --short
git mv src/greet.txt src/greeting.txt
git status --short
```

```
D  notes.tmp
?? notes.tmp
D  notes.tmp
R  src/greet.txt -> src/greeting.txt
```

Compare com `git rm notes.tmp`, que teria removido o arquivo do disco também.

10. Faça commit do estado e limpe o sandbox:

```bash
git add -A
git commit -q -m "chore: add ignore rules, untrack notes.tmp, rename greeting"
git clean -nd
```

```
Would remove dist/
```

`-n` é uma simulação. `git clean -fd` apaga; `git clean -fdx` apaga também arquivos ignorados, e é o comando que remove um `.env` que nunca foi commitado.

### Perguntas de verificação

- **Q2.1** `MM src/greet.txt` — descreva o conteúdo do arquivo em cada uma das três árvores naquele momento.
- **Q2.2** Você rodou `git add file`, depois editou o arquivo de novo e então rodou `git commit -m "..."` sem `-a`. Qual versão entra no commit?
- **Q2.3** Um colega adicionou `secrets.env` ao `.gitignore` mas o `git status` continua reportando-o como modificado a cada alteração. Diagnostique, e dê o comando exato que resolve isso mantendo a cópia local do arquivo.
- **Q2.4** `git check-ignore -v` imprimiu `.gitignore:5:!important.tmp`. Enuncie a regra de ordenação que faz uma negação funcionar, e explique por que `!dist/app.bin` **não** reincluiria esse arquivo dada a regra `/dist/`.
- **Q2.5** O que a `/` inicial em `/dist/` muda em comparação a escrever `dist/`?
- **Q2.6** O Git não tem um tipo de objeto "rename", e mesmo assim o `git status` imprimiu `R src/greet.txt -> src/greeting.txt`. Como o Git sabe?
- **Q2.7** Qual comando descarta mudanças *staged mas não commitadas* sem tocar na working tree, e qual descarta mudanças da working tree sem tocar no index? Dê tanto a forma com `git restore` quanto a antiga com `git reset` / `git checkout`.

---

## Exercício 3 — Ler o histórico como um operador

Num incidente você não lê o histórico, você o consulta.

### Passos

1. Construa um histórico que valha a pena consultar:

```bash
cd /tmp/lpi-701.3/app
for i in 1 2 3; do
  echo "line $i" >> src/greeting.txt
  git commit -q -am "feat: add line $i"
done
echo 'TIMEOUT = 30' > src/config.py
git add src/config.py && git commit -q -m "feat: introduce TIMEOUT"
sed -i 's/TIMEOUT = 30/TIMEOUT = 5/' src/config.py
git commit -q -am "perf: lower TIMEOUT to 5"
```

2. A única invocação de log que vale memorizar:

```bash
git log --oneline --graph --decorate --all
```

```
* 1d4e7a9 (HEAD -> main) perf: lower TIMEOUT to 5
* 0c3b6f8 feat: introduce TIMEOUT
* 9b2a5e7 feat: add line 3
* 8a1f4d6 feat: add line 2
* 7f0e3c5 feat: add line 1
* 6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
* 5d8c1a3 chore: add notes.tmp by mistake
* 7a1f0c9 feat: add greeting
```

3. Formatação customizada, que é o que você joga dentro de um relatório:

```bash
git log --pretty=format:'%h %ad %an %s' --date=short -n 3
```

```
1d4e7a9 2026-09-18 Ada Lovelace perf: lower TIMEOUT to 5
0c3b6f8 2026-09-18 Ada Lovelace feat: introduce TIMEOUT
9b2a5e7 2026-09-18 Ada Lovelace feat: add line 3
```

4. A picareta (pickaxe) — "qual commit mudou o número de ocorrências desta string?":

```bash
git log --oneline -S 'TIMEOUT = 30'
git log --oneline -G 'TIMEOUT'
```

```
0c3b6f8 feat: introduce TIMEOUT
1d4e7a9 perf: lower TIMEOUT to 5
0c3b6f8 feat: introduce TIMEOUT
```

5. Siga um arquivo através do seu rename e atribua uma única linha:

```bash
git log --oneline --follow -- src/greeting.txt
git blame -L 1,2 -- src/greeting.txt
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
7f0e3c5 feat: add line 1
6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
7a1f0c9 feat: add greeting
7a1f0c9 (Ada Lovelace 2026-09-18 00:00:00 +0000 1) hello world
6e9d2b4 (Ada Lovelace 2026-09-18 00:00:00 +0000 2) goodbye world
```

6. Ranges e sintaxe de revisão — a parte que é lida errado no exame:

```bash
git log --oneline 7f0e3c5..9b2a5e7      # exclusive of the left side
git rev-parse --short HEAD~2 HEAD^ 'HEAD@{1}'
git diff --stat HEAD~3 HEAD
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
9b2a5e7
0c3b6f8
0c3b6f8
 src/config.py   | 1 +
 src/greeting.txt | 1 +
 2 files changed, 2 insertions(+)
```

7. Autoria e volume, para uma nota de release:

```bash
git shortlog -sn --no-merges
git log --oneline --since='1 day ago' --author='Ada' | wc -l
```

```
     8	Ada Lovelace
8
```

### Perguntas de verificação

- **Q3.1** Explique a diferença entre `git log A..B` e `git log A...B`, e entre `git diff A..B` e `git diff A...B`.
- **Q3.2** Qual é a diferença entre `HEAD^`, `HEAD~`, `HEAD^2` e `HEAD~2`? Para que tipo de commit `HEAD^2` sequer resolve?
- **Q3.3** `-S 'TIMEOUT = 30'` retornou um commit; `-G 'TIMEOUT'` retornou dois. Explique com precisão o que cada opção casa.
- **Q3.4** Por que `git log -- src/greeting.txt` para em `6e9d2b4` enquanto `git log --follow -- src/greeting.txt` continua além dele?
- **Q3.5** `HEAD@{1}` e `HEAD~1` resolveram para commits diferentes aqui, e em geral. Que duas coisas distintas eles nomeiam, e qual delas consegue alcançar um commit que não está em branch algum?
- **Q3.6** Você sabe que um teste passa em `7f0e3c5` e falha em `HEAD`. Escreva a sequência de três comandos que faz o Git encontrar o primeiro commit ruim automaticamente com um script `./run-test.sh`.

---

## Exercício 4 — Branches, merges e resolução de conflitos

### Passos

1. Crie um branch e veja que "criar um branch" é uma escrita de 41 bytes:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/tls
cat .git/HEAD
cat .git/refs/heads/feature/tls
git branch -vv
```

```
ref: refs/heads/feature/tls
1d4e7a9...
  main          1d4e7a9 perf: lower TIMEOUT to 5
* feature/tls   1d4e7a9 perf: lower TIMEOUT to 5
```

2. Faça commit no branch e depois faça merge de volta com a política padrão:

```bash
echo 'TLS_MIN_VERSION = "1.2"' >> src/config.py
git commit -q -am "feat(tls): require TLS 1.2"
git switch main
git merge feature/tls
```

```
Updating 1d4e7a9..4b7c2e1
Fast-forward
 src/config.py | 1 +
 1 file changed, 1 insertion(+)
```

Nenhum merge commit foi criado: `main` não tinha se movido, então o Git apenas avançou o ponteiro.

3. Refaça com a política que a maioria dos fluxos de release realmente quer:

```bash
git reset --hard 1d4e7a9
git merge --no-ff feature/tls -m "Merge branch 'feature/tls'"
git log --oneline --graph -n 4
git cat-file -p HEAD | head -n 3
```

```
*   e2f5a80 (HEAD -> main) Merge branch 'feature/tls'
|\
| * 4b7c2e1 (feature/tls) feat(tls): require TLS 1.2
|/
* 1d4e7a9 perf: lower TIMEOUT to 5
tree 3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b
parent 1d4e7a9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e
parent 4b7c2e1d0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c
```

Duas linhas `parent`. Essa é a definição inteira de um merge commit.

4. Agora fabrique um conflito genuíno:

```bash
git switch -c fix/timeout main
sed -i 's/TIMEOUT = 5/TIMEOUT = 15/' src/config.py
git commit -q -am "fix: raise TIMEOUT to 15 for slow upstreams"

git switch main
sed -i 's/TIMEOUT = 5/TIMEOUT = 2/' src/config.py
git commit -q -am "perf: cut TIMEOUT to 2"

git merge fix/timeout
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

5. Inspecione o conflito como dado, não como texto:

```bash
git status --short
git diff --name-only --diff-filter=U
git ls-files --stage src/config.py
```

```
UU src/config.py
src/config.py
100644 8c1d0a9b7e6f5d4c3b2a1908f7e6d5c4b3a29180 1	src/config.py
100644 6b0c9f8a7d6e5c4b3a29180f7e6d5c4b3a291807 2	src/config.py
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 3	src/config.py
```

O stage 1 é a base do merge, o stage 2 é **ours** (`main`) e o stage 3 é **theirs** (`fix/timeout`).

6. Leia os marcadores de conflito — com `merge.conflictstyle=zdiff3` do Exercício 0 a base também é exibida:

```bash
cat src/config.py
```

```
<<<<<<< HEAD
TIMEOUT = 2
||||||| 1d4e7a9
TIMEOUT = 5
=======
TIMEOUT = 15
>>>>>>> fix/timeout
TLS_MIN_VERSION = "1.2"
```

7. Resolva deliberadamente e depois conclua o merge:

```bash
git show :1:src/config.py     # base
git show :2:src/config.py     # ours
git show :3:src/config.py     # theirs
sed -i '1,6c\TIMEOUT = 15' src/config.py
git add src/config.py
git ls-files --stage src/config.py
git commit --no-edit
```

```
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 0	src/config.py
[main 5c8d1e2] Merge branch 'fix/timeout'
```

Uma vez feito o stage, os três stages em conflito colapsam de volta para o stage `0`. É isso que "`git add` marca um conflito como resolvido" significa mecanicamente.

8. Pratique a saída de emergência e os atalhos em massa:

```bash
git switch -c conflict/demo 1d4e7a9
sed -i 's/TIMEOUT = 5/TIMEOUT = 99/' src/config.py
git commit -q -am "chore: demo conflict"
git switch main
git merge conflict/demo
git checkout --ours -- src/config.py   # keep main's version wholesale
git merge --abort
git status --short
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

(`git status --short` não imprime nada: `--abort` restaurou o estado anterior ao merge, incluindo a working tree.)

9. Limpe branches já mesclados como faz um release engineer:

```bash
git branch --merged main
git branch -d feature/tls fix/timeout
git branch -D conflict/demo
```

```
  feature/tls
  fix/timeout
* main
Deleted branch feature/tls (was 4b7c2e1).
Deleted branch fix/timeout (was 3e9f7b2).
Deleted branch conflict/demo (was 2a8e6c4).
```

### Perguntas de verificação

- **Q4.1** Por que o passo 2 fez fast-forward enquanto o passo 3 pôde ser forçado a criar um merge commit? Enuncie a condição precisa sob a qual o Git faz fast-forward.
- **Q4.2** Um time exige que toda feature chegue como um merge identificável em `main`. Qual opção de merge impõe isso, e quais duas chaves de configuração a tornam padrão para um repositório?
- **Q4.3** Num index em conflito, o que os stages 1, 2 e 3 guardam? Durante um `git merge`, qual branch é "ours"? Durante um `git rebase`, qual branch é "ours" — e por que isso é o oposto do que a maioria das pessoas espera?
- **Q4.4** `git checkout --ours -- file` e `git merge -X ours` soam parecidos e não são. Explique a diferença e quando cada um está correto.
- **Q4.5** Você resolveu um conflito editando o arquivo mas esqueceu de rodar `git add`. O que o `git commit` faz, e o que exatamente o `git add` muda no index?
- **Q4.6** `git branch -d` recusou apagar um branch; `git branch -D` apagou. O que o `-d` verifica, e depois de um `-D` num branch com trabalho não mesclado, o trabalho sumiu? Como você o recuperaria?
- **Q4.7** Você habilitou `rerere.enabled=true` no Exercício 0. O que isso faz, e por que importa num branch de vida longa que sofre rebase diariamente?

---

## Exercício 5 — Rebase, cherry-pick e reescrita segura do histórico

### Passos

1. Monte um branch que ficou para trás:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/metrics
echo 'METRICS_PORT = 9090' >> src/config.py
git commit -q -am "feat(metrics): expose port 9090"
echo 'METRICS_PATH = "/metrics"' >> src/config.py
git commit -q -am "feat(metrics): set scrape path"

git switch main
echo 'LOG_LEVEL = "info"' >> src/logging.py
git add src/logging.py && git commit -q -m "feat(log): add log level"
git log --oneline --graph --all -n 5
```

```
* 7d2c9f1 (HEAD -> main) feat(log): add log level
| * 9e4a1b8 (feature/metrics) feat(metrics): set scrape path
| * 6c1f8d3 feat(metrics): expose port 9090
|/
* 5c8d1e2 Merge branch 'fix/timeout'
```

2. Faça o rebase e registre os hashes antes e depois:

```bash
git switch feature/metrics
git log --oneline -n 2
git rebase main
git log --oneline -n 3
cat .git/ORIG_HEAD
```

```
9e4a1b8 feat(metrics): set scrape path
6c1f8d3 feat(metrics): expose port 9090
Successfully rebased and updated refs/heads/feature/metrics.
b3f7a02 (HEAD -> feature/metrics) feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
7d2c9f1 (main) feat(log): add log level
9e4a1b8...
```

As mensagens de commit e os diffs são idênticos; **os hashes mudaram**. O rebase não move commits, ele os reproduz como novos objetos.

3. Rebase interativo com autosquash — o fluxo para "a revisão pediu um ajuste no commit 2 de 5":

```bash
echo 'METRICS_PORT = 9091' >> src/config.py
git commit -q --fixup a91c5e4
git log --oneline -n 3
GIT_SEQUENCE_EDITOR=cat git rebase -i --autosquash main
```

```
d0e8b41 (HEAD -> feature/metrics) fixup! feat(metrics): expose port 9090
b3f7a02 feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
pick a91c5e4 feat(metrics): expose port 9090
fixup d0e8b41 fixup! feat(metrics): expose port 9090
pick b3f7a02 feat(metrics): set scrape path
```

`GIT_SEQUENCE_EDITOR=cat` imprime a lista de tarefas em vez de abrir um editor, e então o rebase prossegue com esse plano. Rode de novo sem isso para editar interativamente; os verbos são `pick`, `reword`, `edit`, `squash`, `fixup`, `drop`, `exec`.

4. Transplante um intervalo para uma base diferente com `--onto`:

```bash
git switch -c feature/dash feature/metrics
echo 'DASH_URL = "http://localhost:3000"' >> src/config.py
git commit -q -am "feat(dash): add dashboard URL"
git rebase --onto main feature/metrics feature/dash
git log --oneline --graph --all -n 4
```

```
* 4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
* 7d2c9f1 (main) feat(log): add log level
* 5c8d1e2 Merge branch 'fix/timeout'
```

Leia assim: *pegue os commits em `feature/metrics..feature/dash` e reproduza-os sobre `main`.*

5. Faça cherry-pick de uma única correção para um branch de release, com rastreabilidade:

```bash
git switch -c release/1.0 5c8d1e2
git cherry-pick -x 7d2c9f1
git log -n 1 --format='%H%n%n%B'
```

```
[release/1.0 8b5d3a6] feat(log): add log level
c1e0a7f4b3d2856907e1f2a3b4c5d6e7f8091a2b

feat(log): add log level

(cherry picked from commit 7d2c9f1e0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d)
```

6. Quebre o histórico de propósito e recupere-o com o reflog:

```bash
git switch feature/dash
git reset --hard HEAD~1
git log --oneline -n 1
git reflog -n 4
git reset --hard 'HEAD@{1}'
git log --oneline -n 1
```

```
7d2c9f1 feat(log): add log level
7d2c9f1 HEAD@{0}: reset: moving to HEAD~1
4f6b0d7 HEAD@{1}: rebase (finish): returning to refs/heads/feature/dash
4f6b0d7 HEAD@{2}: rebase (pick): feat(dash): add dashboard URL
7d2c9f1 HEAD@{3}: checkout: moving from feature/metrics to feature/dash
4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
```

7. Veja do que o reflog está te protegendo:

```bash
git fsck --unreachable --no-reflogs | head -n 3
```

```
unreachable commit 9e4a1b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f21
unreachable commit 6c1f8d3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e
unreachable commit d0e8b41f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b
```

Esses são os commits anteriores ao rebase. Eles sobrevivem até o `git gc` podá-los — por padrão 90 dias para objetos alcançáveis pelo reflog, 2 semanas para os inalcançáveis (`gc.reflogExpire`, `gc.pruneExpire`).

### Perguntas de verificação

- **Q5.1** Enuncie a regra de ouro do rebase e descreva concretamente o que acontece com um colega que já tinha feito fetch de `feature/metrics` antes de você fazer o rebase.
- **Q5.2** Merge e rebase ambos integram `main` em um branch de feature. Dê um argumento para cada um que seja sobre *operação*, não sobre estética — por exemplo bisect, revert e ler `git log --graph` seis meses depois.
- **Q5.3** Numa lista de tarefas de rebase interativo, qual é a diferença entre `squash` e `fixup`? E entre `reword` e `edit`?
- **Q5.4** `git commit --fixup <sha>` mais `git rebase -i --autosquash` substituíram um reordenamento manual. O que o `--fixup` de fato escreve na mensagem de commit, e qual chave de configuração torna o `--autosquash` padrão?
- **Q5.5** Decomponha `git rebase --onto main feature/metrics feature/dash` em seus três argumentos e diga, em palavras, quais commits são reproduzidos e onde eles aterrissam.
- **Q5.6** Por que o `-x` num cherry-pick importa para um branch de release, e por que `cherry-pick` é a ferramenta errada para trazer 40 commits de `main` para `release/1.0`?
- **Q5.7** `git reflog` recuperou um commit que o `git log` não conseguia mostrar. Explique por quê, e nomeie as duas condições sob as quais o reflog *não* vai te salvar.

---

## Exercício 6 — Desfazer: reset, restore, revert, stash

### Passos

1. Construa o estado de referência:

```bash
cd /tmp/lpi-701.3/app
git switch main
echo 'DEBUG = True' >> src/config.py
git commit -q -am "chore: enable DEBUG (mistake)"
git log --oneline -n 2
```

```
c7a2e91 (HEAD -> main) chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

2. Compare os três resets, um de cada vez, voltando atrás entre eles:

```bash
git reset --soft HEAD~1   && git status --short && git reset --hard c7a2e91 -q
git reset --mixed HEAD~1  && git status --short && git reset --hard c7a2e91 -q
git reset --hard HEAD~1   && git status --short
```

```
M  src/config.py
 M src/config.py
```

O terceiro não imprime nada: `--hard` descartou a mudança inteiramente. Preencha esta tabela com o que você acabou de observar:

| Modo | HEAD | Index | Working tree |
|---|---|---|---|
| `--soft` | move | inalterado | inalterado |
| `--mixed` (padrão) | move | reset para HEAD | inalterado |
| `--hard` | move | reset para HEAD | **reset para HEAD** |

3. Restaure o commit e desfaça-o da forma que você tem permissão de fazer num branch compartilhado:

```bash
git reset --hard c7a2e91 -q
git revert --no-edit HEAD
git log --oneline -n 3
git diff HEAD~2 HEAD
```

```
f3b8c40 (HEAD -> main) Revert "chore: enable DEBUG (mistake)"
c7a2e91 chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

`git diff HEAD~2 HEAD` não imprime nada — a árvore é idêntica, e ambos os commits permanecem no histórico.

4. Reverta um *merge*, o que exige um número de parent:

```bash
git revert -m 1 5c8d1e2 --no-edit
git log --oneline -n 1
```

```
a0d5f27 (HEAD -> main) Revert "Merge branch 'fix/timeout'"
```

Sem `-m`, o Git recusa: `error: commit 5c8d1e2 is a merge but no -m option was given.`

5. `git restore` — o substituto moderno e inequívoco do sobrecarregado `checkout`:

```bash
echo 'OOPS = 1' >> src/config.py
git add src/config.py
echo 'OOPS = 2' >> src/config.py
git restore --staged src/config.py   # index  <- HEAD ; working tree untouched
git status --short
git restore src/config.py            # working <- index
git status --short
```

```
 M src/config.py
```

(O segundo `git status --short` não imprime nada.)

6. Faça stash, incluindo arquivos não rastreados, e inspecione antes de aplicar:

```bash
echo 'WIP = True' >> src/config.py
echo 'scratch' > scratch.txt
git stash push -u -m "wip: config experiment"
git status --short
git stash list
git stash show -p 'stash@{0}' | head -n 8
```

```
stash@{0}: On main: wip: config experiment
diff --git a/src/config.py b/src/config.py
index 4a9b8e7..7c3d1f0 100644
--- a/src/config.py
+++ b/src/config.py
@@ -4,3 +4,4 @@ TLS_MIN_VERSION = "1.2"
 METRICS_PATH = "/metrics"
+WIP = True
```

(O `git status --short` entre eles não imprime nada — a working tree está limpa.)

7. Apply versus pop, e a natureza real do stash:

```bash
git stash apply 'stash@{0}'
git stash list
git status --short
git stash drop 'stash@{0}'
git cat-file -p 'stash@{0}' 2>&1 | head -n 1
```

```
stash@{0}: On main: wip: config experiment
 M src/config.py
?? scratch.txt
Dropped stash@{0} (b6e1d84...)
fatal: ambiguous argument 'stash@{0}': unknown revision
```

8. Limpe e confirme:

```bash
git checkout -- src/config.py && rm -f scratch.txt
git status --short --branch
```

```
## main
```

### Perguntas de verificação

- **Q6.1** Você commitou em `main` e já fez push. Explique por que `git reset --hard HEAD~1` seguido de um force-push é a resposta errada, e o que o `git revert` faz em vez disso.
- **Q6.2** Você commitou num branch local há 30 segundos e não fez push. Qual modo de reset permite manter as mudanças staged para recommitar imediatamente com uma mensagem melhor — e qual comando único teria sido ainda mais simples?
- **Q6.3** `git reset --hard` descartou trabalho não commitado no passo 2. Isso é recuperável pelo reflog? Justifique sua resposta em termos do que o reflog registra.
- **Q6.4** Por que reverter um merge commit exige `-m 1`, e a que se refere esse número? Qual é a consequência bem conhecida de reverter um merge e depois tentar remesclar o mesmo branch?
- **Q6.5** Dê o equivalente com `git restore` de `git reset HEAD -- file` e de `git checkout -- file`, e diga por que os comandos novos são considerados mais seguros.
- **Q6.6** `git stash push` sem `-u` deixa arquivos não rastreados na working tree. Nomeie a falha que isso causa quando você depois faz `git switch` para outro branch e roda um build.
- **Q6.7** Depois de `git stash drop`, `git cat-file -p 'stash@{0}'` falha. Que tipo de objeto era a entrada do stash, e onde a ref ficava armazenada?

---

## Exercício 7 — Remotes, refspecs e tags

Você vai construir um "servidor" localmente. Um repositório bare é exatamente o que um forge armazena — sem working tree, apenas o banco de objetos e as refs.

### Passos

1. Crie o repositório bare e clone-o:

```bash
cd /tmp/lpi-701.3
git init --bare origin.git
ls origin.git
git clone origin.git work
cd work
```

```
HEAD  config  description  hooks  info  objects  refs
Cloning into 'work'...
warning: You appear to have cloned an empty repository.
```

2. Empurre o trabalho do repositório `app` para dentro dele e inspecione a fiação:

```bash
cd /tmp/lpi-701.3/work
git remote add app /tmp/lpi-701.3/app
git fetch app
git switch -c main app/main
git push -u origin main
git remote -v
git branch -vv
```

```
 * [new branch]      main       -> app/main
branch 'main' set up to track 'origin/main'.
app	/tmp/lpi-701.3/app (fetch)
app	/tmp/lpi-701.3/app (push)
origin	/tmp/lpi-701.3/origin.git (fetch)
origin	/tmp/lpi-701.3/origin.git (push)
* main 3f2a1b9 [origin/main] Revert "Merge branch 'fix/timeout'"
```

3. Leia a refspec que o Git escreveu para você:

```bash
git config --get-regexp '^remote\.origin\.'
git config --get branch.main.merge
ls .git/refs/remotes/origin
cat .git/packed-refs 2>/dev/null | head -n 3
```

```
remote.origin.url /tmp/lpi-701.3/origin.git
remote.origin.fetch +refs/heads/*:refs/remotes/origin/*
refs/heads/main
main
```

`+refs/heads/*:refs/remotes/origin/*` se lê: *busque todo branch do remote para dentro do meu namespace `refs/remotes/origin/`, e permita atualizações non-fast-forward ali (`+`).*

4. Pergunte ao remote o que ele sabe, sem tocar nas suas refs:

```bash
git ls-remote origin
git remote show origin
```

```
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	HEAD
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	refs/heads/main
* remote origin
  Fetch URL: /tmp/lpi-701.3/origin.git
  Push  URL: /tmp/lpi-701.3/origin.git
  HEAD branch: main
  Remote branch:
    main tracked
  Local branch configured for 'git pull':
    main merges with remote main
  Local ref configured for 'git push':
    main pushes to main (up to date)
```

5. Simule um segundo desenvolvedor, para que o remote se mova sob os seus pés:

```bash
cd /tmp/lpi-701.3
git clone -q origin.git other
cd other
echo 'FEATURE_FLAG = "on"' >> src/config.py
git commit -q -am "feat: add feature flag"
git push -q origin main
```

6. De volta ao `work`, veja a diferença entre **fetch** e **pull**:

```bash
cd /tmp/lpi-701.3/work
git fetch origin
git status --short --branch
git log --oneline HEAD..@{u}
git rev-list --left-right --count HEAD...@{u}
```

```
 * branch            main       -> FETCH_HEAD
   3f2a1b9..8e7d6c5  main       -> origin/main
## main...origin/main [behind 1]
8e7d6c5 feat: add feature flag
0	1
```

O `fetch` atualizou `origin/main` e não mudou **nada** na sua working tree. `0 1` significa: 0 commits só seus, 1 commit só do remote.

7. Integre, com ambas as políticas:

```bash
git merge --ff-only origin/main
git log --oneline -n 1
```

```
Updating 3f2a1b9..8e7d6c5
Fast-forward
8e7d6c5 (HEAD -> main, origin/main) feat: add feature flag
```

`git pull` é exatamente `git fetch` mais esse segundo passo. Com `pull.ff=only` do Exercício 0, uma divergência faz parar em vez de produzir silenciosamente um merge commit; `git pull --rebase` reproduz seus commits locais por cima, em vez disso.

8. Produza uma rejeição non-fast-forward de verdade:

```bash
cd /tmp/lpi-701.3/other
echo 'REGION = "eu-west-1"' >> src/config.py
git commit -q -am "feat: pin region"
git push -q origin main

cd /tmp/lpi-701.3/work
echo 'REGION = "us-east-1"' >> src/config.py
git commit -q -am "feat: pin region differently"
git push origin main
```

```
To /tmp/lpi-701.3/origin.git
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
hint: Updates were rejected because the remote contains work that you do
hint: not have locally. This is usually caused by another repository pushing
hint: to the same ref.
```

9. Resolva corretamente — faça rebase do seu commit por cima e depois push:

```bash
git pull --rebase origin main
# resolve the conflict in src/config.py, keeping one REGION line
git add src/config.py && git rebase --continue
git push origin main
```

10. Veja por que `--force-with-lease` existe:

```bash
git commit -q --amend -m "feat: pin region (amended)"
git push --force-with-lease origin main
```

```
 + 9a1b2c3...d4e5f60 main -> main (forced update)
```

`--force-with-lease` recusa o push se `origin/main` não estiver no valor que você buscou pela última vez — isto é, se alguém tiver feito push nesse meio-tempo. `--force` sobrescreve o trabalho dessa pessoa sem perguntar. Num branch compartilhado, prefira nenhum dos dois.

11. Tags — os dois tipos não são intercambiáveis:

```bash
git tag v0.9.0
git tag -a v1.0.0 -m "Release 1.0.0: TLS 1.2 minimum, metrics endpoint"
git cat-file -t v0.9.0
git cat-file -t v1.0.0
git cat-file -p v1.0.0
```

```
commit
tag
object d4e5f60a1b2c3d4e5f60718293a4b5c6d7e8f901
type commit
tag v1.0.0
tagger Ada Lovelace <ada@example.com> 1789700000 +0000

Release 1.0.0: TLS 1.2 minimum, metrics endpoint
```

A tag lightweight *é* o hash do commit. A tag anotada é um **quarto tipo de objeto**, carregando tagger, data, mensagem e, opcionalmente, uma assinatura.

12. Publique tags — elas não são enviadas por padrão:

```bash
git push origin main
git ls-remote --tags origin
git push --follow-tags origin main
git ls-remote --tags origin
git describe --tags
```

```
d4e5f60...	refs/tags/v1.0.0
d4e5f60...	refs/tags/v1.0.0^{}
v1.0.0
```

`--follow-tags` enviou apenas a tag **anotada** alcançável a partir do que você empurrou; `v0.9.0` ficou local. A linha `^{}` é a ref descascada (peeled): o commit para o qual o objeto de tag aponta.

13. Rio abaixo, essa tag é o gatilho de release. Um pipeline a consome assim:

```yaml
stages:
  - test
  - release

test:
  stage: test
  script:
    - make test

release:
  stage: release
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+$/'
  script:
    - 'echo "publishing $CI_COMMIT_TAG"'
    - make publish
```

14. Pode referências a branches que não existem mais upstream:

```bash
cd /tmp/lpi-701.3/other
git push origin --delete main 2>/dev/null || true
cd /tmp/lpi-701.3/work
git fetch --prune origin
git branch -r
```

### Perguntas de verificação

- **Q7.1** Explique a refspec `+refs/heads/*:refs/remotes/origin/*` termo a termo: o `+`, o lado esquerdo, o lado direito.
- **Q7.2** O que exatamente o `git fetch` muda, e o que ele deliberadamente não muda? Dê um cenário de produção em que buscar primeiro e integrar depois é a diferença entre uma indisponibilidade e um não-evento.
- **Q7.3** `origin/main`, `refs/remotes/origin/main` e `@{u}` — qual é a relação entre esses três nomes? Você pode commitar em `origin/main`?
- **Q7.4** O push do passo 8 foi rejeitado com `(fetch first)`. Enuncie a invariante que o servidor está impondo e liste as três formas de prosseguir, da mais segura à mais destrutiva.
- **Q7.5** O que o `--force-with-lease` compara, e em que situação ele ainda permite uma sobrescrita que custa os commits de alguém?
- **Q7.6** Cite três comportamentos concretos que diferem entre uma tag lightweight e uma tag anotada (dica: tipo de objeto, `git describe`, assinatura, `--follow-tags`).
- **Q7.7** Um colega enviou `v1.0.0`, depois a moveu para outro commit e forçou o push da tag. Seu clone continua resolvendo `v1.0.0` para o commit antigo depois de `git fetch`. Por quê, e qual opção faz a atualização acontecer?
- **Q7.8** Um repositório bare não tem working tree. Por que isso é um requisito para um alvo de push, e não uma otimização?

---

## Exercício 8 — Submódulos

Um submódulo é um ponteiro de um repositório para *um commit específico* de outro. Tudo o que é confuso sobre submódulos decorre dessa única frase.

### Passos

1. Construa um repositório de dependência e adicione-o como submódulo:

```bash
cd /tmp/lpi-701.3
git init -q --bare libgreet.git
git clone -q libgreet.git libgreet && cd libgreet
echo 'def greet(): return "hi"' > greet.py
git add greet.py && git commit -q -m "feat: initial greet"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule add ../libgreet.git vendor/libgreet
git status --short
```

```
Cloning into '/tmp/lpi-701.3/work/vendor/libgreet'...
A  .gitmodules
A  vendor/libgreet
```

2. Leia o que foi registrado — este é o cerne do tópico inteiro:

```bash
cat .gitmodules
git ls-files --stage vendor/libgreet
git commit -q -m "chore: vendor libgreet as a submodule"
git cat-file -p HEAD^{tree} | grep libgreet
```

```ini
[submodule "vendor/libgreet"]
	path = vendor/libgreet
	url = ../libgreet.git
```

```
160000 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b 0	vendor/libgreet
160000 commit 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b	vendor/libgreet
```

O modo `160000` é um **gitlink**: uma entrada de tree cujo alvo é um commit em outro repositório. O superprojeto não armazena arquivo algum de `libgreet`.

3. Confirme que o submódulo tem seu próprio `.git` — e que ele não é um diretório:

```bash
cat vendor/libgreet/.git
git -C vendor/libgreet status --short --branch
```

```
gitdir: ../../.git/modules/vendor/libgreet
## HEAD (no branch)
```

O checkout do submódulo está com **HEAD destacado** (detached HEAD), porque o superprojeto fixa um commit, não um branch.

4. Prove que um clone simples não traz o conteúdo:

```bash
cd /tmp/lpi-701.3
git clone -q work fresh
ls fresh/vendor/libgreet
git -C fresh submodule status
```

```
-6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet
```

O diretório está vazio e o `-` inicial significa "não inicializado". Este é o incidente mais comum com submódulos: um build que funciona localmente e falha no CI com "file not found".

5. As duas formas de acertar:

```bash
git -C fresh submodule update --init --recursive
git -C fresh submodule status
rm -rf fresh
git clone -q --recurse-submodules work fresh2
git -C fresh2 submodule status
```

```
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
```

6. Avance a dependência e atualize o ponteiro deliberadamente:

```bash
cd /tmp/lpi-701.3/libgreet
echo 'def farewell(): return "bye"' >> greet.py
git commit -q -am "feat: add farewell"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule update --remote vendor/libgreet
git status --short
git diff --submodule=log
```

```
 M vendor/libgreet
Submodule vendor/libgreet 6a2b0c9..b7c3d1e:
  > feat: add farewell
```

7. Faça commit do *movimento do ponteiro*, que é um commit no superprojeto:

```bash
git add vendor/libgreet
git commit -q -m "chore(deps): bump libgreet to b7c3d1e"
git show --stat HEAD
```

```
 vendor/libgreet | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
```

Uma linha mudou: o gitlink.

8. Remova um submódulo por completo — são três lugares, e as pessoas sempre esquecem um:

```bash
git submodule deinit -f vendor/libgreet
git rm -f vendor/libgreet
rm -rf .git/modules/vendor/libgreet
git commit -q -m "chore(deps): drop libgreet"
cat .gitmodules 2>/dev/null; echo "exit=$?"
```

```
exit=0
```

O `git rm` removeu a entrada do `.gitmodules` e o gitlink; o `deinit` limpou o `.git/config`; o `rm -rf` limpou o clone interno.

### Perguntas de verificação

- **Q8.1** O que o modo de arquivo `160000` significa numa tree, e o que fica armazenado no superprojeto para o conteúdo dos arquivos do submódulo?
- **Q8.2** Por que um checkout de submódulo normalmente fica em detached HEAD? O que dá errado se um desenvolvedor commita dentro do submódulo enquanto está destacado e não percebe?
- **Q8.3** O `.gitmodules` é commitado, mas a URL do submódulo também aparece no `.git/config`. Qual das duas o `git submodule update` usa, e qual comando copia uma para a outra?
- **Q8.4** O CI faz checkout do seu repositório e o build falha com um arquivo vendorizado ausente. Dê os dois comandos que resolvem e diga qual você colocaria no pipeline e por quê.
- **Q8.5** `git submodule update` e `git submodule update --remote` fazem coisas opostas. Descreva cada um com precisão.
- **Q8.6** Depois de subir a versão do submódulo, `git show --stat` reporta uma linha alterada. Explique a um revisor o que é essa linha e como ele deveria revisar a mudança.
- **Q8.7** Cite os três lugares que precisam ser limpos para remover um submódulo, e o sintoma de esquecer `.git/modules/<path>`.

---

## Exercício 9 — Gerenciamento de chaves SSH

O objetivo 701.3 inclui conhecimento de gerenciamento de chaves SSH, porque todo push para um forge real passa por isso.

### Passos

1. Crie um par de chaves moderno com um comentário que identifique a máquina:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "ada@laptop-2026-09" -f ~/.ssh/id_ed25519_demo
ls -l ~/.ssh/id_ed25519_demo*
```

```
Generating public/private ed25519 key pair.
Enter passphrase for "/home/ada/.ssh/id_ed25519_demo" (empty for no passphrase):
Your identification has been saved in /home/ada/.ssh/id_ed25519_demo
Your public key has been saved in /home/ada/.ssh/id_ed25519_demo.pub
-rw------- 1 ada ada  464 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo
-rw-r--r-- 1 ada ada  100 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo.pub
```

Use uma passphrase. As permissões `600` na chave privada e `700` em `~/.ssh` são impostas pelo OpenSSH, não são meras recomendações.

2. Inspecione as duas metades:

```bash
cat ~/.ssh/id_ed25519_demo.pub
ssh-keygen -lf ~/.ssh/id_ed25519_demo.pub
head -n 1 ~/.ssh/id_ed25519_demo
```

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4qK0v0h7f2Zt9xQ6r3sN1mJpL8cW5yT2dX0aB3eF4g ada@laptop-2026-09
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
-----BEGIN OPENSSH PRIVATE KEY-----
```

Somente a linha do `.pub` é enviada ao forge. A fingerprint é o que você compara por um segundo canal.

3. Inicie um agent e carregue a chave para digitar a passphrase uma única vez:

```bash
eval "$(ssh-agent -s)"
ssh-add -t 8h ~/.ssh/id_ed25519_demo
ssh-add -l
```

```
Agent pid 48213
Enter passphrase for /home/ada/.ssh/id_ed25519_demo:
Identity added: /home/ada/.ssh/id_ed25519_demo (ada@laptop-2026-09)
Lifetime set to 28800 seconds
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
```

O `eval` importa: `ssh-agent -s` apenas *imprime* os exports de `SSH_AUTH_SOCK` e `SSH_AGENT_PID`; sem `eval` o seu shell nunca fica sabendo deles.

4. Vincule a chave a um host explicitamente, para que uma máquina com várias contas continue previsível:

```bash
cat >> ~/.ssh/config <<'EOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_demo
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
chmod 600 ~/.ssh/config
```

`IdentitiesOnly yes` impede o SSH de oferecer todas as chaves do agent em sequência — a causa de `Too many authentication failures` em hosts com `MaxAuthTries 6`.

5. Teste a autenticação (este é o único comando que usa rede; pule-o se estiver offline):

```bash
ssh -T git@github.com
```

```
Hi ada! You've successfully authenticated, but GitHub does not provide shell access.
```

O status de saída é `1` e isso é sucesso para esse host. Se falhar, `ssh -vT git@github.com` mostra qual chave foi oferecida e por que foi recusada.

6. Entenda o lado da confiança relativo à chave do host:

```bash
ssh-keygen -F github.com
ssh-keygen -lf ~/.ssh/known_hosts | head -n 2
```

Compare a fingerprint impressa com a que o provedor publica no próprio site de documentação **antes** de aceitá-la pela primeira vez. `ssh-keygen -R github.com` remove uma entrada obsoleta após uma rotação documentada da chave de host — e somente então.

7. Troque um repositório de HTTPS para SSH:

```bash
cd /tmp/lpi-701.3/work
git remote set-url origin git@github.com:ada/app.git
git remote -v
git remote set-url origin /tmp/lpi-701.3/origin.git   # restore the sandbox
```

8. Use a mesma chave para assinar commits — sem GPG, Git ≥ 2.34:

```bash
cd /tmp/lpi-701.3/work
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519_demo.pub
git config commit.gpgsign true
printf '%s %s\n' "ada@example.com" "$(cat ~/.ssh/id_ed25519_demo.pub)" > ~/.ssh/allowed_signers
git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
echo 'SIGNED = True' >> src/config.py
git commit -q -am "chore: signed commit"
git log --show-signature -n 1 --format='%H %G? %GS'
```

```
e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4 G ada@example.com
```

`%G?` retorna `G` (boa), `B` (ruim), `U` (boa, não confiável) ou `N` (nenhuma).

### Perguntas de verificação

- **Q9.1** Qual dos dois arquivos que o `ssh-keygen` produziu vai para o servidor, e qual a consequência de enviar o errado?
- **Q9.2** Por que o `ssh-agent -s` precisa de `eval`? O que quebra se você rodá-lo sem?
- **Q9.3** Que problema uma passphrase resolve que as permissões de arquivo não resolvem, e que problema o `ssh-add -t 8h` resolve que a passphrase sozinha não resolve?
- **Q9.4** Explique `IdentitiesOnly yes`. Descreva a falha que ele evita num laptop com seis chaves carregadas no agent.
- **Q9.5** `ssh -T git@github.com` teve sucesso mas saiu com `1`. Por que isso não é um bug, e o que isso implica para um script de shell que o executa com `set -e`?
- **Q9.6** Distinga a *chave de host* da *chave de usuário*: qual delas vive em `known_hosts`, contra qual ataque cada uma defende, e o que significa um aviso repentino de `REMOTE HOST IDENTIFICATION HAS CHANGED`?
- **Q9.7** O encaminhamento de agent (`ssh -A`) é conveniente e é geralmente desencorajado para bastions de produção. Enuncie a ameaça e nomeie a alternativa mais segura embutida no OpenSSH.
- **Q9.8** No passo 8, um commit foi assinado sem GPG. Quais três chaves de configuração fizeram isso funcionar, e o que o `git log --show-signature` reporta se `allowedSignersFile` não estiver definido?

---

## Exercício 10 — Capstone: impor a política no servidor

Disciplina do lado do cliente é uma sugestão. O repositório bare é onde uma regra vira regra.

### Passos

1. Instale um hook `pre-receive` que recusa atualizações non-fast-forward em `main`:

```bash
cd /tmp/lpi-701.3/origin.git
cat > hooks/pre-receive <<'EOF'
#!/bin/sh
# Reject force-pushes and deletions on protected branches.
protected="refs/heads/main"
zero="0000000000000000000000000000000000000000"

while read -r oldrev newrev refname; do
    [ "$refname" = "$protected" ] || continue

    if [ "$newrev" = "$zero" ]; then
        echo "policy: refusing to delete $refname" >&2
        exit 1
    fi

    if [ "$oldrev" != "$zero" ] && \
       [ "$(git merge-base "$oldrev" "$newrev")" != "$oldrev" ]; then
        echo "policy: non-fast-forward push to $refname rejected" >&2
        exit 1
    fi
done
exit 0
EOF
chmod +x hooks/pre-receive
```

2. Tente violá-lo:

```bash
cd /tmp/lpi-701.3/work
git commit -q --amend -m "chore: signed commit (amended again)"
git push --force-with-lease origin main
```

```
remote: policy: non-fast-forward push to refs/heads/main rejected
To /tmp/lpi-701.3/origin.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
```

O `--force-with-lease` passou na própria verificação — seu `origin/main` estava atualizado — e mesmo assim o servidor recusou. É esse o ponto.

3. Tente apagar o branch:

```bash
git push origin --delete main
```

```
remote: policy: refusing to delete refs/heads/main
 ! [remote rejected] main (pre-receive hook declined)
```

4. Adicione uma proteção do lado do cliente, e note onde os hooks ficam quando precisam ser compartilhados:

```bash
cd /tmp/lpi-701.3/work
mkdir -p .githooks
cat > .githooks/pre-commit <<'EOF'
#!/bin/sh
# Block obvious secrets from entering the index.
if git diff --cached -U0 | grep -nE '^\+.*(AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY)'; then
    echo "pre-commit: possible credential in staged changes" >&2
    exit 1
fi
EOF
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
echo 'AWS_KEY = "AKIAIOSFODNN7EXAMPLE"' >> src/config.py
git commit -am "chore: add key"
```

```
1:+AWS_KEY = "AKIAIOSFODNN7EXAMPLE"
pre-commit: possible credential in staged changes
```

5. Limpe:

```bash
git restore --staged src/config.py && git restore src/config.py
git config --unset core.hooksPath
```

### Perguntas de verificação

- **Q10.1** Por que o `.git/hooks/pre-commit` não pode ser distribuído commitando-o, e qual chave de configuração resolve isso? Qual é o limite duro de um hook do lado do cliente como controle de segurança?
- **Q10.2** `pre-receive` roda uma vez; `update` roda uma vez por ref. Qual você usaria para uma política que precisa aceitar algumas refs de um push e rejeitar outras, e o que o "push atômico" muda nisso?
- **Q10.3** No hook, o que prova o fato de `git merge-base "$oldrev" "$newrev"` retornar exatamente `$oldrev`?
- **Q10.4** O que um `newrev` todo de zeros sinaliza, e o que um `oldrev` todo de zeros sinaliza?
- **Q10.5** O hook `pre-commit` bloqueou o commit — mas a chave já tinha sido posta no stage e o desenvolvedor pode burlar o hook. Nomeie a flag que o burla, e diga o que precisa acontecer se uma credencial chegar a um commit já enviado (nota: `git revert` **não** é suficiente — explique por quê).

---

<details>
<summary><strong>Respostas</strong> — abra somente depois de tentar todas as perguntas</summary>

### Exercício 0

**A0.1** Na ordem de aplicação: **system** (`/etc/gitconfig`, `--system`), **global** (`~/.gitconfig` ou `$XDG_CONFIG_HOME/git/config`, `--global`), **local** (`.git/config`, `--local`) e **worktree** (`.git/config.worktree`, `--worktree`, apenas com `extensions.worktreeConfig`). O **mais específico vence** — local sobrepõe global, que sobrepõe system. O `-c key=value` na linha de comando vence todos.

**A0.2** A **seção** e a **chave** não diferenciam maiúsculas de minúsculas (o Git as normaliza para minúsculas ao imprimir); o nome da **subseção** — a parte entre aspas, por exemplo `remote "Origin"` ou `submodule "vendor/libgreet"` — e o **valor** diferenciam.

**A0.3** Uma **divergência**. Sem isso, `git pull` num branch que tem commits locais e remotos cria silenciosamente um merge commit ("Merge branch 'main' of …"). Com `pull.ff=only`, o pull falha e você precisa escolher conscientemente: `--rebase` ou um merge explícito.

**A0.4** `git config --local user.email "ada@corp.example"` executado dentro do repositório; ele escreve `.git/config`. (`git config --global user.useConfigOnly true` mais identidades por repositório faz o Git se recusar a adivinhar uma identidade, que é a versão de nível de produção.)

### Exercício 1

**A1.1**
- **blob** — conteúdo de arquivo, sem nome e sem permissões.
- **tree** — uma listagem de diretório: modo, tipo, hash e nome de cada entrada.
- **commit** — um hash de tree, zero ou mais parents, autor, committer, mensagem.
- **tag** (anotada) — o hash de um objeto alvo, seu tipo, um nome de tag, tagger e mensagem, opcionalmente uma assinatura.

**A1.2** O nome do arquivo vive na **tree**, não no blob. A identidade do blob é `sha1("blob <bytesize>\0<content>")`. Consequência: o mesmo arquivo de 10 MB em cinco caminhos é armazenado **uma vez** no banco de objetos; cinco entradas de tree apontam para um blob. O Git deduplica conteúdo globalmente e de graça.

**A1.3** Um blob (o conteúdo de `greet.txt`), duas trees (o diretório `src` e a tree raiz) e um commit. Blob + tree + tree + commit = 4.

**A1.4** Um branch é um arquivo contendo um único ID de objeto de 40 caracteres. Criar um escreve 41 bytes e não copia nada; apagar um remove 41 bytes. O custo de ramificar independe do tamanho do repositório ou do comprimento do histórico.

**A1.5** Nenhuma linha `parent` significa que é o **commit raiz** — o primeiro commit do histórico. Um merge de dois branches tem **duas** linhas `parent` (um merge polvo de N branches tem N).

**A1.6** Sem `-w` o Git apenas calcula e imprime o hash — uma função pura, nada é escrito. Com `-w` ele também grava o objeto em `.git/objects`. Isso importa porque demonstra que o endereçamento por conteúdo é determinístico e independente do repositório: o hash é uma propriedade dos bytes, não do commit que você eventualmente faz.

### Exercício 2

**A2.1** HEAD: `hello world\n`. Index: `hello world\ngoodbye world\n` (staged no passo 2). Working tree: `hello world\ngoodbye world\nthird line\n`. Coluna esquerda `M` = HEAD difere do index; coluna direita `M` = index difere da working tree.

**A2.2** A versão que estava no index no momento do `git add` — a **primeira** edição. O `git commit` constrói uma tree a partir do index, nunca da working tree. `git commit -a` teria feito stage das mudanças rastreadas antes e capturado as duas.

**A2.3** O `.gitignore` é consultado apenas para caminhos **não rastreados**. `secrets.env` já está rastreado, então a regra de ignore é inerte. Correção: `git rm --cached secrets.env && git commit -m "chore: untrack secrets.env"`. O arquivo permanece no disco e passa a ser ignorado dali em diante. (Ele continua no histórico — veja A10.5.)

**A2.4** O **último padrão que casa decide**. Uma negação só funciona se algum padrão anterior casou com o arquivo e nenhum padrão posterior o exclui de novo. `!dist/app.bin` falha diante de `/dist/` porque o Git nem desce dentro de um **diretório** excluído, de modo que o arquivo nunca é testado. Para reincluir, você precisa primeiro desfazer a exclusão do diretório: `/dist/` → `/dist/*` mais `!/dist/app.bin`, ou `!/dist/` e então `/dist/*`.

**A2.5** Uma `/` inicial ancora o padrão ao diretório que contém o `.gitignore`. `/dist/` casa apenas com um `dist` no nível superior; `dist/` casa com `dist` em **qualquer** profundidade, inclusive `src/vendor/dist`.

**A2.6** O Git calcula renames no momento da leitura por **similaridade de conteúdo**, comparando os blobs removidos e adicionados (limiar padrão 50%, `-M<n>` para ajustar, `--find-renames`). Nada sobre o rename fica armazenado no commit — um rename é uma remoção mais uma adição na tree.

**A2.7** Só staged: `git restore --staged <file>` (antigo: `git reset HEAD -- <file>`). Só working tree: `git restore <file>` (antigo: `git checkout -- <file>`). Ambos: `git restore --staged --worktree <file>`.

### Exercício 3

**A3.1** Para o `git log`: `A..B` = commits alcançáveis a partir de B mas não de A (o conjunto "o que há de novo em B"); `A...B` = a **diferença simétrica**, commits alcançáveis a partir de um ou do outro mas não de ambos (adicione `--left-right` para rotulá-los). Para o `git diff` os significados são quase invertidos: `A..B` (e o simples `A B`) compara as duas trees das pontas; `A...B` compara **B contra a base de merge** de A e B — que é o que um pull request mostra.

**A3.2** `^` e `~` são a mesma coisa quando há um único parent. `^N` seleciona o **N-ésimo parent** de um merge commit; `~N` sobe **N gerações** pela linha do primeiro parent. Logo `HEAD~2` = `HEAD^^`, e `HEAD^2` é o segundo parent — só resolve para um **merge commit**.

**A3.3** `-S<string>` casa commits em que o **número de ocorrências** da string mudou (adicionadas ou removidas) — encontra onde um símbolo foi introduzido ou apagado. `-G<regex>` casa commits cujo **texto do diff** contém uma linha que corresponde ao regex — incluindo uma linha que apenas foi movida ou reindentada. Daí os dois resultados para `-G 'TIMEOUT'`: tanto a introdução quanto a mudança de valor tocaram numa linha que o contém.

**A3.4** Sem `--follow`, o Git filtra o histórico pelo caminho tal como ele existe agora, e o histórico daquele caminho exato começa no commit do rename. `--follow` reinicia a limitação por caminho no rename ao detectar o blob similar do outro lado, continuando sob o nome antigo.

**A3.5** `HEAD~1` é uma referência de **grafo**: o primeiro parent do commit atual, calculado a partir dos objetos de commit, idêntica em todo clone. `HEAD@{1}` é uma referência de **reflog**: onde o `HEAD` apontava um movimento atrás, local ao seu repositório e ausente de um clone novo. Só a forma do reflog pode nomear um commit que nenhum branch ou tag alcança — e é por isso que ela é a ferramenta de recuperação.

**A3.6**
```
git bisect start HEAD 7f0e3c5
git bisect run ./run-test.sh
git bisect reset
```
(`HEAD` é o sabidamente ruim, `7f0e3c5` o sabidamente bom. O `run` espera saída 0 = bom, 1–124 = ruim, 125 = pular.)

### Exercício 4

**A4.1** O Git faz fast-forward quando o commit alvo é um **descendente** do atual — isto é, `git merge-base --is-ancestor HEAD <target>` vale, de modo que o commit atual já é um ancestral e não há conteúdo novo a combinar. No passo 2, `main` não tinha avançado desde o ponto de ramificação. No passo 3, `--no-ff` sobrepõe a otimização e força um merge commit mesmo assim.

**A4.2** `git merge --no-ff`. Padrões: `git config merge.ff false` (nunca fazer fast-forward num merge) e `git config pull.ff only` no lado consumidor; `git config branch.main.mergeOptions --no-ff` limita ao escopo de um branch. Num forge, o equivalente é a estratégia "merge commit" com fast-forward desabilitado.

**A4.3** Stage 1 = a **base do merge** (ancestral comum), stage 2 = **ours**, stage 3 = **theirs**. Durante o `git merge`, "ours" é o branch em que você está. Durante o `git rebase`, "ours" é o **upstream** sobre o qual você está reproduzindo e "theirs" é **o seu próprio commit sendo reproduzido** — porque o rebase faz checkout do upstream e aplica seus commits por cima, de modo que, do ponto de vista do Git, o seu trabalho é o lado que chega.

**A4.4** `git checkout --ours -- file` opera **durante um conflito, sobre um arquivo**: pega o stage 2 por inteiro para aquele caminho, descartando as mudanças do outro lado nele. `git merge -X ours` é uma **opção de estratégia** de merge aplicada ao merge inteiro: resolve cada hunk conflitante em favor do branch atual, ainda mesclando as mudanças não conflitantes do outro lado. (Nenhum dos dois é `git merge -s ours`, que produz um merge commit cuja tree é idêntica à sua, descartando inteiramente o conteúdo do outro branch — usado para marcar um branch como mesclado.)

**A4.5** O `git commit` aborta: `error: Committing is not possible because you have unmerged files.` O `git add` substitui os três stages em conflito (1/2/3) daquele caminho por uma única entrada de **stage 0** contendo o seu conteúdo resolvido — esse colapso *é* o registro da resolução.

**A4.6** O `-d` recusa a menos que o branch esteja totalmente mesclado no seu upstream ou no HEAD atual, de modo que nenhum trabalho se perca. O `-D` pula a verificação. O trabalho **não** sumiu: os commits estão inalcançáveis mas ainda no banco de objetos, recuperáveis via `git reflog` ou `git fsck --lost-found` até a coleta de lixo podá-los (padrão: 30 dias para objetos inalcançáveis que entram num pack, 2 semanas para os loose).

**A4.7** `rerere` = *reuse recorded resolution* (reutilizar resolução registrada). O Git registra os hunks em conflito e como você os resolveu, e reaplica a resolução automaticamente na próxima vez em que o conflito idêntico aparecer. Num branch de vida longa rebaseado diariamente sobre um `main` em movimento, o mesmo conflito se repete todo dia; o rerere o transforma num custo único.

### Exercício 5

**A5.1** **Nunca faça rebase de commits sobre os quais outros basearam trabalho** — na prática, nunca faça rebase de um branch que já foi enviado e que outra pessoa possa ter buscado. Um colega que buscou o antigo `feature/metrics` agora tem os commits `6c1f8d3`/`9e4a1b8` enquanto o remote tem `a91c5e4`/`b3f7a02`, com conteúdo idêntico e identidades diferentes. O próximo `git pull` dele mescla as duas linhagens e cada commit aparece duas vezes.

**A5.2** *Merge:* preserva o grafo real de integração, de modo que `git log --first-parent main` se lê como uma linha por feature, reverter uma feature é um único `git revert -m 1`, e nenhum commit jamais muda de identidade — um commit já testado continua testado. *Rebase:* produz um histórico linear, de modo que o `git bisect` divide ao meio uma sequência limpa sem merge commits cujos builds nunca foram executados naquela combinação exata, a ordem do `git log` corresponde à causalidade, e cada commit em revisão é um estado completo e construível de forma independente.

**A5.3** `squash` mantém a mensagem do commit e abre um editor para combiná-la com a do anterior; `fixup` descarta a mensagem do commit inteiramente e mantém apenas a do anterior. `reword` muda apenas a mensagem, sem parar o rebase para você mexer em arquivos; `edit` pausa o rebase com o commit aplicado, para você emendar o conteúdo, dividi-lo ou rodar comandos, e então `git rebase --continue`.

**A5.4** Ele escreve uma mensagem exatamente igual a `fixup! <assunto do commit alvo>`. `git config rebase.autosquash true` torna `--autosquash` o padrão para rebases interativos (o Git também respeita `--autosquash` para os prefixos `squash!` e `amend!` produzidos por `--squash`/`--fixup=amend:`).

**A5.5** `--onto main` = a **nova base**. `feature/metrics` = o **upstream**, ou seja, o limite inferior exclusivo. `feature/dash` = o **branch** a mover. Conjunto reproduzido: `feature/metrics..feature/dash`, exatamente o único commit `feat(dash): add dashboard URL`. Ele aterrissa sobre `main`, e `feature/dash` é reapontado para lá. Sem `--onto`, os commits de metrics teriam vindo junto.

**A5.6** O `-x` acrescenta `(cherry picked from commit <sha>)` à mensagem, de modo que um commit de branch de release é rastreável até sua origem em `main` — essencial ao auditar o que foi entregue num hotfix. Para 40 commits, o cherry-pick produz 40 novos commits com novos hashes e nenhuma relação registrada: o Git não consegue saber que `release/1.0` contém o trabalho de `main`, então merges futuros vão conflitar repetidamente. Use merge (ou faça rebase do branch de release) em vez disso.

**A5.7** O `git log` percorre o grafo de commits a partir das refs; o commit antigo não era alcançável por ref alguma após o `reset --hard`, então é invisível para o `log`. O reflog é um diário por repositório de cada valor que cada ref (e o `HEAD`) sustentou, independente de alcançabilidade. Ele **não** vai te salvar quando: (a) o trabalho nunca foi commitado — o reflog registra movimentos de refs, não estados da working tree; e (b) a entrada expirou e foi coletada pelo garbage collector, ou você está num **clone novo** / num repositório bare onde o seu reflog não existe (repositórios bare têm `core.logAllRefUpdates` desligado por padrão).

### Exercício 6

**A6.1** `reset --hard` + force-push reescreve o branch publicado: todo mundo que puxou o topo antigo agora tem um histórico divergente, pipelines de CI atrelados àqueles hashes quebram, e quem tiver feito push nesse meio-tempo tem o trabalho sobrescrito. O `git revert` cria um **novo** commit cujo diff é o inverso do ruim. O histórico só cresce, o push é um fast-forward, e o registro do que aconteceu — o erro e sua correção — permanece auditável.

**A6.2** `git reset --soft HEAD~1` deixa as mudanças staged, prontas para um `git commit` com uma nova mensagem. Mais simples ainda: `git commit --amend -m "better message"`.

**A6.3** **Não, não pelo reflog.** O reflog registra para onde as refs apontavam, então pode restaurar qualquer estado **commitado**. Conteúdo não commitado da working tree e do index nunca foi um objeto alcançável a partir de uma ref. (Uma exceção estreita: conteúdo que passou por `git add` vira um blob, então `git fsck --lost-found` às vezes consegue recuperar conteúdo que foi staged e depois descartado — mas não os nomes dos arquivos.)

**A6.4** Um merge commit tem dois parents, então "o inverso deste commit" é ambíguo — o Git precisa saber qual linha de parent representa a "mainline". `-m 1` seleciona o primeiro parent (em `main`, o branch no qual você mesclou), de modo que o revert desfaz tudo que veio do outro lado. Consequência: o revert faz a base do merge parecer já integrada, de modo que remesclar o mesmo branch depois traz **nada** — a feature silenciosamente continua ausente. A correção é reverter o revert (ou fazer rebase do branch sobre o novo topo) antes de remesclar.

**A6.5** `git reset HEAD -- file` → `git restore --staged file`. `git checkout -- file` → `git restore file`. Mais seguros porque os verbos são disjuntos: `git switch` muda de branch, `git restore` muda conteúdo de arquivos, enquanto o `git checkout` fazia as duas coisas e o significado dependia de o argumento ser por acaso um nome de branch ou um caminho — uma fonte real de perda de dados com um nome ambíguo.

**A6.6** Arquivos não rastreados permanecem na working tree através de um `git switch`, então contaminam o build do outro branch: um arquivo gerado obsoleto, um módulo remanescente ou uma configuração que o branch não espera é apanhado pelo sistema de build e produz um resultado que não corresponde a nenhum dos branches. `git stash push -u` (ou `-a` para incluir arquivos ignorados) coloca-os no stash também.

**A6.7** Uma entrada de stash é um **objeto de commit** — na verdade um merge commit com dois ou três parents (HEAD, um commit contendo o estado do index e, com `-u`, um terceiro contendo os arquivos não rastreados). A ref era `refs/stash`, com as entradas anteriores mantidas no **reflog** dessa ref — e é por isso que a numeração é `stash@{0}`, `stash@{1}` e assim por diante.

### Exercício 7

**A7.1** `+` = permite atualizações **non-fast-forward** no destino (necessário porque um branch upstream pode legitimamente sofrer force-push, e sua ref de remote-tracking precisa acompanhar). Lado esquerdo `refs/heads/*` = o padrão de **origem**, todo branch do remote. Lado direito `refs/remotes/origin/*` = o **destino** no seu namespace local de refs. O `*` dos dois lados liga posicionalmente: `refs/heads/main` → `refs/remotes/origin/main`.

**A7.2** `git fetch` baixa objetos novos e atualiza refs de remote-tracking (`refs/remotes/origin/*`), `FETCH_HEAD` e tags conforme a política. Ele **não** toca nos seus branches, no seu index, na sua working tree nem no `HEAD`. Cenário: no meio de um incidente você quer saber o que mudou upstream antes de decidir qualquer coisa. `git fetch && git log --oneline HEAD..@{u}` responde isso com risco zero; um `git pull` reflexo teria iniciado um merge ou um rebase sobre uma árvore suja no meio do incidente.

**A7.3** `origin/main` é a forma curta; `refs/remotes/origin/main` é a ref completa para a qual ela resolve; `@{u}` (`@{upstream}`) resolve para qualquer ref configurada como upstream do branch atual (`branch.main.remote` + `branch.main.merge`) — normalmente, mas não necessariamente, `origin/main`. Você **não pode** commitar em `origin/main`: fazer checkout dela destaca o HEAD, porque ela é um cache local do estado do remote, atualizado apenas por fetch/push.

**A7.4** A invariante: uma atualização de ref no servidor precisa ser um **fast-forward** — o valor antigo deve ser ancestral do novo — de modo que nenhum commit que era alcançável se torne inalcançável. Opções, da mais segura em diante: (1) `git pull --rebase` (ou fetch + rebase) e então push — seu trabalho é preservado e o resultado é um fast-forward; (2) fetch + merge e então push — mesma garantia, um merge commit extra; (3) `git push --force-with-lease` — reescreve o branch remoto, permitido apenas se ninguém empurrou desde o seu último fetch; (4) `git push --force` — sobrescrita incondicional, com potencial perda de dados.

**A7.5** Ele compara a ref de remote-tracking que você tem (`refs/remotes/origin/main`) com o valor atual real da ref no servidor, e recusa se diferirem. Ele ainda permite uma sobrescrita se **você** rodou `git fetch` depois do push dessa pessoa sem olhar — o fetch renovou silenciosamente o seu "lease". `--force-with-lease=main:<expected-sha>` com um hash explícito fecha esse buraco. Ele também não protege nada contra um push que aconteça entre a sua verificação e a atualização do servidor se o remote não tiver atomicidade de transação de refs.

**A7.6** (1) **Tipo de objeto**: lightweight é uma ref apontando direto para um commit; anotada cria um objeto de tag real com tagger, data, mensagem e assinatura opcional. (2) `git describe` considera apenas tags anotadas por padrão (`--tags` inclui as lightweight). (3) Somente tags anotadas (ou assinadas com `-s`) podem ser **assinadas por GPG/SSH** e verificadas com `git tag -v`. (4) `git push --follow-tags` envia apenas tags anotadas. (5) `git cat-file -t` retorna `commit` vs `tag`.

**A7.7** O Git deliberadamente **não** atualiza uma ref de tag existente no fetch — tags devem ser imutáveis, e mover uma silenciosamente sob o usuário mudaria a que uma release se refere. Force a atualização com `git fetch --tags --force` ou `git fetch origin 'refs/tags/*:refs/tags/*' --force`. O processo correto é não mover tags publicadas: corte a `v1.0.1` em vez disso.

**A7.8** Um push atualiza refs e, num repositório não bare, deixaria o branch do `HEAD` apontando para um commit enquanto a working tree e o index ainda refletem o antigo — o repositório reportaria o diff inteiro como remoções/modificações não commitadas, e quem estivesse trabalhando ali seria sabotado silenciosamente. O Git portanto recusa por padrão (`receive.denyCurrentBranch=refuse`). Um repositório bare não tem working tree nem branch em checkout, então não há nada a dessincronizar.

### Exercício 8

**A8.1** O modo `160000` é um **gitlink**: uma entrada de tree do tipo `commit`, nomeando um objeto de commit que vive num repositório *diferente*. O superprojeto armazena **nada** do conteúdo dos arquivos do submódulo — nenhum blob, nenhuma tree — apenas aquele ID de commit de 40 caracteres mais a entrada no `.gitmodules` dizendo ao Git de onde cloná-lo.

**A8.2** Porque o superprojeto fixa um **commit**, não um branch; fazer checkout de um branch permitiria que o submódulo derivasse silenciosamente. Se um desenvolvedor commita enquanto está destacado e depois roda `git submodule update` (ou troca de branch no superprojeto), o HEAD se move para o commit fixado e o commit dele se torna inalcançável no submódulo — recuperável apenas pelo reflog do submódulo, e invisível para todo mundo porque nunca foi enviado.

**A8.3** `git submodule update` usa o **`.git/config`** (`submodule.<name>.url`), que é preenchido a partir do `.gitmodules` por `git submodule init` (ou `update --init`). `git submodule sync` recopia a URL do `.gitmodules` para o `.git/config` — o comando de que você precisa depois que a URL upstream muda.

**A8.4** `git submodule update --init --recursive` após o checkout, ou `git clone --recurse-submodules` já de início. Num pipeline, prefira o passo explícito `submodule update --init --recursive` (ou o `GIT_SUBMODULE_STRATEGY: recursive` / `submodules: recursive` da plataforma), porque o checkout normalmente é feito pelo runner de CI e você não controla as flags de clone dele — e o passo explícito também conserta um workspace incremental em que o clone já existe.

**A8.5** `git submodule update` faz checkout do submódulo **no commit que o superprojeto registra** — ele impõe a fixação, e é o que você roda depois de um pull. `git submodule update --remote` busca o branch configurado do submódulo (`submodule.<name>.branch` no `.gitmodules`, padrão `HEAD`/`main`) e move o checkout de trabalho para o commit **mais recente** dele, deixando o gitlink do superprojeto modificado para você revisar e commitar — é um *bump* de dependência, não uma sincronização.

**A8.6** A linha alterada é o **gitlink**: os IDs de commit antigo e novo da dependência. Revisar "uma linha alterada" é sem sentido por si só; o revisor precisa inspecionar o intervalo de commits entre eles, com `git diff --submodule=log` (linhas de assunto) ou `git diff --submodule=diff` (diff completo), e deveria ter `git config diff.submodule log` definido para que isso seja o padrão.

**A8.7** (1) O checkout na working tree, a entrada no `.gitmodules` e o gitlink — removidos por `git rm <path>`; (2) `submodule.<name>.*` no `.git/config` — removido por `git submodule deinit`; (3) o clone interno em `.git/modules/<path>` — precisa ser removido manualmente. Esquecer (3) faz com que um `git submodule add` posterior no mesmo caminho falhe com `A git directory for '<path>' is found locally with remote(s): …`, e o repositório antigo seja silenciosamente reutilizado.

### Exercício 9

**A9.1** A chave **pública** (`.pub`) vai para o servidor. Enviar a chave privada expõe o segredo por completo: qualquer um que a tenha se autentica como você, e ela precisa ser considerada comprometida — revogue-a em todo lugar e gere um novo par. (A chave privada também é inútil como linha de `authorized_keys`; a falha é uma recusa silenciosa de autenticação somada a uma credencial vazada.)

**A9.2** `ssh-agent -s` inicia o agent e **imprime** comandos de shell (`SSH_AUTH_SOCK=…; export SSH_AUTH_SOCK; SSH_AGENT_PID=…; export SSH_AGENT_PID;`) no stdout. Sem `eval`, essas linhas apenas são exibidas; seu shell nunca define as variáveis, então `ssh-add` e `ssh` não encontram o socket do agent — `Could not open a connection to your authentication agent` — enquanto um processo de agent órfão continua rodando.

**A9.3** A passphrase criptografa a chave privada **em repouso**, de modo que um backup roubado, um snapshot ou o furto do laptop não rendem uma credencial utilizável — as permissões de arquivo protegem apenas contra outros usuários de um sistema em execução. `ssh-add -t 8h` limita a janela **em memória**: passado o tempo de vida, o agent descarta a chave, de modo que uma máquina deixada desbloqueada ou um atacante com acesso ao socket do agent perde a credencial ao final do expediente, e não no próximo reboot.

**A9.4** Com `IdentitiesOnly yes`, o SSH oferece **apenas** as chaves nomeadas por `IdentityFile`/`CertificateFile` para aquele host, em vez de todas as identidades que o agent guarda mais os nomes de arquivo padrão. Sem isso, um laptop com seis chaves no agent as oferece uma a uma; um servidor com `MaxAuthTries 6` fecha a conexão com `Too many authentication failures` antes que a chave correta seja sequer tentada — e num forge com múltiplas contas você se autentica com a conta errada.

**A9.5** O comando forçado do host imprime a saudação e sai com status diferente de zero porque nenhuma sessão de shell é concedida — `-T` desabilita a alocação de PTY e não há nada a executar. O que a mensagem reporta é a *autenticação* bem-sucedida. Sob `set -e`, o script aborta numa verificação bem-sucedida, então teste a mensagem em vez disso: `ssh -T git@github.com 2>&1 | grep -q 'successfully authenticated'` (ou proteja com `|| true` e inspecione a saída).

**A9.6** A **chave de host** identifica o *servidor* e é fixada em `~/.ssh/known_hosts`; ela defende contra um **man-in-the-middle** — sem ela você entregaria suas credenciais a qualquer coisa que atenda na porta 22. A **chave de usuário** identifica *você* e vive em `~/.ssh/id_*` (privada) e no `authorized_keys` do servidor (pública); ela defende contra a personificação de você. `REMOTE HOST IDENTIFICATION HAS CHANGED` significa que a chave de host apresentada difere da fixada: ou uma rotação legítima e anunciada, ou um servidor reconstruído — ou uma interceptação ativa. Verifique fora de banda contra a fingerprint publicada pelo provedor antes de rodar `ssh-keygen -R`.

**A9.7** Com `ssh -A`, o host remoto pode usar o socket do seu agent enquanto você estiver conectado: **root, ou qualquer um que consiga ler o socket encaminhado no bastion, pode se autenticar como você em qualquer host que suas chaves abram** — sem jamais obter a chave. Alternativa mais segura: `ProxyJump` (`ssh -J bastion target`, ou `ProxyJump bastion` no `~/.ssh/config`), que tunela a conexão através do bastion enquanto a autenticação acontece fim a fim a partir da sua estação de trabalho; o bastion nunca vê o seu agent. (Se o encaminhamento for inevitável, restrinja-o com `ssh-add -c` para confirmação a cada uso.)

**A9.8** `gpg.format = ssh`, `user.signingkey = <caminho do .pub>` e `commit.gpgsign = true` (mais `gpg.ssh.allowedSignersFile` para verificação). Sem `allowedSignersFile`, a assinatura está presente e é criptograficamente válida, mas o Git não tem uma lista mapeando chaves a identidades, então `git log --show-signature` reporta `No principal matched.` e `%G?` retorna `U` — assinatura boa, signatário desconhecido — em vez de `G`.

### Exercício 10

**A10.1** `.git/hooks/` **não** faz parte do conteúdo do repositório — nunca é commitado, clonado ou enviado, por projeto: um repositório que pudesse entregar código executável que roda no clone seria um vetor de execução remota de código. `git config core.hooksPath <dir>` aponta o Git para um diretório commitado, de modo que os hooks viajam com o repositório, mas **todo desenvolvedor ainda precisa optar por isso** definindo essa configuração (ou rodando um script de bootstrap). O limite duro: qualquer hook do lado do cliente é consultivo — pode ser burlado com `--no-verify`, removido, ou simplesmente não configurado. Só hooks do lado do servidor (ou as regras de branch protegido do forge) impõem alguma coisa.

**A10.2** `update` — ele roda uma vez por ref com os valores antigo e novo daquela ref e pode rejeitar exatamente uma enquanto as outras passam. `pre-receive` vê o push inteiro e só pode aceitar ou rejeitar tudo. Um **push atômico** (`git push --atomic`, ou um servidor configurado com `receive.atomic`) muda isso: todas as atualizações de ref têm sucesso ou todas falham juntas, então uma rejeição de `update` por ref aborta o push inteiro de qualquer forma.

**A10.3** Que `$oldrev` é um **ancestral** de `$newrev` — a base de merge dos dois é o próprio topo antigo — que é precisamente a definição de um **fast-forward**. Se a base de merge for qualquer outra coisa, o novo topo não contém o antigo e commits se tornariam inalcançáveis. (`git merge-base --is-ancestor "$oldrev" "$newrev"` expressa o mesmo teste diretamente via status de saída.)

**A10.4** Um `newrev` todo de zeros significa que a ref está sendo **apagada**. Um `oldrev` todo de zeros significa que a ref está sendo **criada** e não existia antes — que é por isso que o hook pula o teste de fast-forward nesse caso.

**A10.5** `--no-verify` (`git commit --no-verify`, `git push --no-verify`) burla hooks do lado do cliente. Se uma credencial chega a um commit enviado, `git revert` **não** é suficiente: o revert adiciona um novo commit, e o segredo permanece no commit antigo, no banco de objetos, em todo clone, e na UI web e na API do forge — muitas vezes permanentemente, já que forges mantêm objetos inalcançáveis. A resposta correta é, nesta ordem: **rotacionar/revogar a credencial imediatamente** (este é o único passo que de fato mitiga), depois expurgá-la do histórico (`git filter-repo`, ou o processo próprio de reescrita de histórico/suporte do forge) e fazer force-push, depois fazer todo mundo reclonar, e pedir ao forge que rode a coleta de lixo e purgue as visualizações em cache.

</details>

---

## Fontes

- LPI, *DevOps Tools Engineer — Exam 701 Objectives (version 2.0.0)*, objetivo 701.3 Source Code Management: <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Documentação do projeto Git — `git-config`, `git-hash-object`, `git-cat-file`, `git-add`, `git-reset`, `git-restore`, `git-merge`, `git-rebase`, `git-cherry-pick`, `git-revert`, `git-stash`, `git-remote`, `git-push`, `git-fetch`, `git-tag`, `git-submodule`, `gitignore`, `gitrevisions`, `githooks`: <https://git-scm.com/docs>
- Livro do projeto Git, *Pro Git*, capítulos 7 (Git Tools) e 10 (Git Internals): <https://git-scm.com/book/en/v2>
- Semântica do `--force-with-lease` do Git, documentação do `git push`: <https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegt>
- Páginas de manual do projeto OpenSSH — `ssh-keygen(1)`, `ssh-agent(1)`, `ssh-add(1)`, `ssh_config(5)`: <https://man.openbsd.org/ssh-keygen.1>, <https://man.openbsd.org/ssh-agent.1>, <https://man.openbsd.org/ssh-add.1>, <https://man.openbsd.org/ssh_config.5>
- Assinatura de commits com SSH no Git (`gpg.format=ssh`, `gpg.ssh.allowedSignersFile`), documentação do `git-config`: <https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgformat>