# 701.3 — Gerenciamento de Código-Fonte

**LPI DevOps Tools Engineer — Exame 701-100, v2.0.0 · Tópico 701: Engenharia de Software · Peso: 10**

---

## 1. O problema arquitetural: o repositório é o sistema de registro

Todo outro estágio de uma plataforma de entrega é uma *derivação* do controle de fontes. A imagem do contêiner é uma função de um commit. O manifesto Kubernetes aplicado em produção é uma função de um commit. O SBOM, a atestação de proveniência, a resposta de auditoria para "quem aprovou esta mudança e quando" — todas funções de um commit. Se a camada de SCM for fraca, nada a jusante pode ser mais forte do que ela, porque você não pode assinar, reproduzir ou reverter aquilo que não consegue endereçar.

É por isso que o Gerenciamento de Código-Fonte carrega um peso desproporcional para um SRE. As falhas não são "perdi meu trabalho"; são arquiteturais:

| Classe de falha | Sintoma concreto em produção | Causa raiz na camada de SCM |
|---|---|---|
| **Build irreproduzível** | A imagem com a tag `v2.4.1` não pode ser reconstruída byte a byte; a tag foi movida | Tags mutáveis, sem tags anotadas/assinadas, sem `git describe` no build |
| **Mudança não atribuível** | A revisão do incidente não consegue determinar quem escreveu uma linha de configuração | Commits não assinados, contas de serviço compartilhadas, histórico reescrito em um branch compartilhado |
| **Exposição de segredo** | Um `kubeconfig` vazado permanece alcançável no histórico por anos após "apagar o arquivo" | Git é append-only por design; deleção é um novo commit, não um apagamento |
| **Colapso de integração** | Doze branches de vida longa, o merge leva dias, conflitos semânticos passam pelo CI | Modelo de branching incompatível com o tamanho do time e a cadência de deploy |
| **Precipício no tempo de clone** | Um monorepo de 40 GB faz cada job de CI gastar 6 minutos em `git clone` | Histórico completo + blobs completos buscados quando só uma árvore é necessária |
| **Desvio do estado desejado** | O cluster roda algo que nenhum commit descreve | GitOps não imposto; `kubectl apply` a partir de laptops |

A mecânica abaixo existe para tornar cada uma dessas linhas impossível por construção, não por disciplina.

---

## 2. O modelo de objetos: o que o Git realmente armazena

Git é um banco de dados de objetos endereçável por conteúdo com um índice em formato de sistema de arquivos por cima. Entender os quatro tipos de objeto é a diferença entre usar o Git e diagnosticá-lo.

| Objeto | Contém | Endereçado por | Mutável? |
|---|---|---|---|
| **blob** | Bytes brutos do arquivo. Sem nome, sem modo, sem histórico | Hash de `blob <len>\0<content>` | Não |
| **tree** | Lista de entradas `(mode, type, hash, name)` — um diretório | Hash de suas entradas serializadas | Não |
| **commit** | Um hash de tree, zero ou mais pais, author, committer, mensagem, `gpgsig` opcional | Hash do cabeçalho do commit + mensagem | Não |
| **tag** (anotada) | Ponteiro para um objeto + tagger + mensagem + assinatura opcional | Hash do objeto de tag | Não |

Todo o resto — branches, `HEAD`, refs de rastreamento remoto, o stash, notas — é uma *referência*: um arquivo de 41 bytes (ou uma linha em `packed-refs`) contendo um hash. Branches são baratos porque um branch é um nome de arquivo contendo um hash.

### 2.1 Provando isso em um repositório ativo

```
$ git init --initial-branch=main /tmp/objmodel
Initialized empty Git repository in /tmp/objmodel/.git/

$ cd /tmp/objmodel
$ printf 'apiVersion: v1\n' > note.txt
$ git add note.txt
$ git commit -q -m 'chore: seed the object database'
$ git cat-file -p HEAD
tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
author Ada Lovelace <ada@example.org> 1758153600 +0000
committer Ada Lovelace <ada@example.org> 1758153600 +0000

chore: seed the object database
```

Desça um nível, do commit para a tree e para o blob:

```
$ git cat-file -p HEAD^{tree}
100644 blob 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f    note.txt

$ git cat-file -p 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
apiVersion: v1

$ git cat-file -t 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
blob
```

O hash não é atribuído, ele é *calculado*. Reproduza-o sem a ajuda do Git:

```
$ printf 'blob 15\0apiVersion: v1\n' | sha1sum
3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f  -
```

**Consequência arquitetural:** conteúdo idêntico armazenado em mil diretórios é um único blob. Renomeações não são armazenadas — o Git registra duas trees e *infere* a renomeação no momento da leitura com uma heurística de similaridade (`git log --follow`, `diff.renames`). É por isso que `git mv` é um wrapper de conveniência sobre `rm` + `add`, e não uma operação distinta.

### 2.2 As três áreas, e o índice como um arquivo real

```
$ git ls-files --stage
100644 3f4e2b1a9c0d5e6f7a8b9c0d1e2f3a4b5c6d7e8f 0    note.txt
```

O número de stage `0` significa "sem conflito". Durante um conflito de merge o mesmo caminho aparece três vezes, com os stages `1` (ancestral comum / base), `2` (ours), `3` (theirs):

```
$ git ls-files --stage -- deploy/values.yaml
100644 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 1    deploy/values.yaml
100644 b2c3d4e5f60718293a4b5c6d7e8f90123456789a 2    deploy/values.yaml
100644 c3d4e5f60718293a4b5c6d7e8f90123456789abc 3    deploy/values.yaml
```

Esta é a definição mecânica de um conflito: o índice contém três versões de um caminho e se recusa a produzir uma tree. `git checkout --ours`/`--theirs` seleciona o stage 2 ou 3; `git add` colapsa para o stage 0 e o merge pode ser concluído.

| Área | Localização física | Populada por | Descartada por |
|---|---|---|---|
| Working tree | Arquivos em disco | `git checkout` / `git switch` / `git restore` | `git restore <path>` |
| Índice (staging area) | `.git/index`, binário | `git add`, `git rm`, `git mv` | `git restore --staged <path>` |
| Banco de objetos + refs | `.git/objects`, `.git/refs` | `git commit`, `git fetch` | `git gc` após tornar-se inalcançável |

### 2.3 Refs, HEAD e o reflog

```
$ cat .git/HEAD
ref: refs/heads/main

$ git symbolic-ref HEAD
refs/heads/main

$ git rev-parse HEAD
9c1f0a4d7b2e3a5c8d1f6b0e4a7c9d2f5b8e1a03

$ git for-each-ref --format='%(refname) %(objecttype) %(objectname:short)'
refs/heads/main commit 9c1f0a4
refs/remotes/origin/main commit 9c1f0a4
refs/tags/v2.4.1 tag 7d3b9e1
```

Um **HEAD destacado** (detached HEAD) é simplesmente `.git/HEAD` contendo um hash bruto em vez de `ref: refs/heads/...`. Commits feitos ali não são alcançáveis a partir de nada além do reflog, e o `git gc` acabará por deletá-los. Este é todo o mistério.

O reflog é o diário local, por ref, de cada valor que uma ref já teve — é o que torna quase toda operação destrutiva do Git recuperável *localmente*, e ele **nunca é enviado com push**:

```
$ git reflog show main --date=iso
9c1f0a4 main@{2026-09-17 11:04:22 +0000}: commit: feat: add readiness probe
1a2b3c4 main@{2026-09-17 10:51:07 +0000}: reset: moving to HEAD~2
5d6e7f8 main@{2026-09-17 10:12:44 +0000}: rebase (finish): refs/heads/main onto 8899aab
```

Expiração padrão: 90 dias para entradas alcançáveis (`gc.reflogExpire`), 30 dias para as inalcançáveis (`gc.reflogExpireUnreachable`).

### 2.4 SHA-1, SHA-256 e integridade

O uso de SHA-1 pelo Git foi endurecido com detecção de colisão (`sha1dc`) desde a versão 2.13 — uma colisão forjada no estilo SHAttered aborta a operação em vez de corromper silenciosamente o banco de dados. Um formato de objeto SHA-256 existe e é utilizável, mas **não há interoperabilidade entre um repositório SHA-1 e um SHA-256**; você não pode fazer push entre eles.

```
$ git init --object-format=sha256 /tmp/sha256repo
Initialized empty Git repository in /tmp/sha256repo/.git/

$ git -C /tmp/sha256repo rev-parse --show-object-format
sha256
```

Trate repositórios SHA-256 como um experimento voltado ao futuro; não migre um repositório de plataforma compartilhado para ele hoje. Em vez disso, imponha verificações de integridade na transferência, que estão desativadas por padrão por questões de desempenho:

```
$ git config --global transfer.fsckObjects true
$ git config --global fetch.fsckObjects true
$ git config --system receive.fsckObjects true
```

---

## 3. Mecânica de integração: merge, rebase e o que cada um destrói

### 3.1 Fast-forward vs three-way

Um **fast-forward** não é um merge: se `HEAD` é um ancestral do alvo, o Git move a ref. Nenhum objeto novo é criado, nenhum conflito é possível, e a existência do branch desaparece do grafo.

Um **merge three-way** calcula a base do merge (`git merge-base A B`), faz o diff base→ours e base→theirs, e os combina. Desde o Git 2.34 a estratégia padrão é **`ort`** ("Ostensibly Recursive's Twin"), uma reescrita do `recursive` que é dramaticamente mais rápida em árvores grandes e lida melhor com detecção de renomeação e históricos entrecruzados (múltiplas bases de merge).

```
$ git merge-base --all main feature/probe
8899aabbccddeeff00112233445566778899aabb

$ git merge --no-ff feature/probe
Auto-merging deploy/values.yaml
CONFLICT (content): Merge conflict in deploy/values.yaml
Automatic merge failed; fix conflicts and then commit the result.

$ git status --short
UU deploy/values.yaml
M  deploy/deployment.yaml
```

Configure um estilo de conflito que mostre a *base*, para que você possa ver o que cada lado mudou em vez de adivinhar:

```
$ git config --global merge.conflictStyle zdiff3
```

Com `zdiff3` os marcadores carregam uma seção de base:

```
<<<<<<< HEAD
  replicas: 6
||||||| 8899aab
  replicas: 3
=======
  replicas: 4
>>>>>>> feature/probe
```

Agora a decisão é informada: o nosso lado escalou de 3→6, o deles escalou de 3→4. Com o estilo `merge` padrão você veria apenas 6 vs 4 e não saberia qual lado se moveu.

### 3.2 Rebase: reproduzindo patches, criando novos objetos

`git rebase` pega os commits exclusivos do seu branch, calcula seus patches, e os reaplica sobre uma nova base. **Todo commit rebaseado é um novo objeto com um novo hash** — a tree pode ser idêntica, o pai não é. É por isso que rebasear um branch que outros já puxaram é uma falha de serviço em miniatura.

```
$ git rebase --onto origin/main HEAD~3 feature/probe
Successfully rebased and updated refs/heads/feature/probe.

$ git range-diff origin/main HEAD@{1} HEAD
1:  4f5a6b7 = 1:  a1b2c3d feat: add readiness probe
2:  6c7d8e9 ! 2:  b2c3d4e feat: expose /healthz
    @@ internal/server/health.go
     -   w.WriteHeader(http.StatusOK)
     +   w.WriteHeader(http.StatusNoContent)
3:  8e9f0a1 = 3:  c3d4e5f test: cover the probe path
```

`git range-diff` é a ferramenta de revisão correta após um force-push: ele faz o diff de duas *séries* de commits e mostra exatamente quais patches mudaram, o que é invisível para um diff comum.

### 3.3 Tabela de compromissos: estratégias de integração

| Estratégia | Formato do grafo | Fidelidade do histórico | Bissetabilidade | Granularidade do revert | Segura em branch compartilhado | Melhor para |
|---|---|---|---|---|---|---|
| `merge --ff-only` | Linear | Exata | Excelente | Por commit | Sim | `main` protegida em fluxo trunk-based |
| `merge --no-ff` | Bolhas de merge | Exata + registra o ponto de integração | Boa (`--first-parent`) | Feature inteira (reverta o merge com `-m 1`) | Sim | Branches de release, ambientes com auditoria intensa |
| `rebase` e depois ff | Linear | Reescrito (datas, hashes, possivelmente semântica) | Excelente | Por commit | **Não** | Branches de feature privados antes da revisão |
| `merge --squash` | Linear, um commit por feature | Com perdas — passos intermediários se vão | Grosseira mas muito limpa | Feature inteira | Sim | Repos de alta rotatividade com commits WIP ruidosos |
| `cherry-pick` | Patches duplicados | Duplica conteúdo sob novos hashes | Confusa (mesma mudança, dois hashes) | Por pick | Sim | Backport de um hotfix para um branch de release |

Duas regras operacionais que decorrem diretamente da mecânica:

1. **Rebase reescreve o histórico; nunca rebaseie uma ref que outras pessoas buscam.** Se for necessário, use `--force-with-lease --force-if-includes` para que você não possa sobrescrever silenciosamente um commit que nunca viu:

```
$ git push --force-with-lease --force-if-includes origin feature/probe
To ssh://git@git.example.org/platform/api.git
 + 6c7d8e9...b2c3d4e feature/probe -> feature/probe (forced update)
```

O `--force` simples sobrescreve incondicionalmente. `--force-with-lease` recusa se a ref remota se moveu desde o seu último fetch. `--force-if-includes` (Git 2.30+) fecha a brecha restante em que um `git fetch` em segundo plano atualizou sua ref de rastreamento remoto sem que você a tivesse integrado.

2. **Ensine o Git a reutilizar resoluções de conflito** em rebases repetidos de branches de vida longa:

```
$ git config --global rerere.enabled true
$ git config --global rerere.autoUpdate true
```

O `rerere` registra o trecho do conflito e sua resolução em `.git/rr-cache/`; na próxima vez que o conflito idêntico aparecer ele é resolvido automaticamente. É uma grande economia de tempo em branches de release — e um perigo se a primeira resolução estava errada, já que ela será reproduzida silenciosamente. `git rerere forget <path>` limpa uma entrada.

---

## 4. Modelos de branching: escolhendo uma topologia, não uma preferência

| Modelo | Branches de vida longa | Frequência de merge | Mecanismo de release | Isolamento de feature | Custo de um hotfix | Serve para |
|---|---|---|---|---|---|---|
| **Trunk-based** | Apenas `main` | Várias vezes/dia, branches < 24 h | Tag em `main` + promover artefato | Feature flags | Trivial — commit em `main`, promover | CD, times de alta confiança, repos de plataforma |
| **GitHub Flow** | Apenas `main` | Por PR | Deploy no merge | Vida do branch de horas a dias | Igual a qualquer mudança | SaaS, versão única em produção |
| **GitLab Flow** | `main` + branches de ambiente (`staging`, `production`) | Apenas merges a jusante | Merge `main`→`staging`→`production` | Branch + portão de ambiente | Cherry-pick para `production` | Portões de promoção regulados |
| **Git Flow** | `main`, `develop`, `release/*`, `hotfix/*` | Semanas | Estabilização em `release/*` e depois tag | Forte, de vida longa | `hotfix/*` dedicado + merge duplo | Software entregue/on-prem, muitas versões suportadas |
| **Release train** | `main` + `release-X.Y` | Contínua para `main`, cherry-pick de volta | Cortar um branch por calendário | Política de backport | Cherry-pick por release suportada | Projetos no estilo Kubernetes |

**A variável decisiva não é o gosto do time, é quantas versões você precisa suportar em produção simultaneamente.** Uma versão → trunk-based. Muitas → você precisa de branches de release, e precisa aceitar o imposto do backport.

### 4.1 Conflitos semânticos e filas de merge

A falha que os modelos de branching raramente abordam: dois PRs passam no CI contra a `main`, não conflitam em nenhum arquivo, e quebram a `main` quando ambos entram — um renomeou uma função, o outro adicionou um chamador. Um merge textual não consegue enxergar isso.

A correção mecânica é uma **fila de merge** (merge queue): serialize os candidatos, construa cada um contra o resultado *especulado* dos que estão à frente, e só faça fast-forward na `main` quando estiver verde.

```yaml
name: ci
on:
  pull_request:
    branches:
      - main
  merge_group:
    types:
      - checks_requested
permissions:
  contents: read
concurrency:
  group: "ci-${{ github.ref }}"
  cancel-in-progress: true
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout with full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Verify commit messages against Conventional Commits
        run: |
          base="${{ github.event.pull_request.base.sha }}"
          head="${{ github.event.pull_request.head.sha }}"
          if [ -z "$base" ]; then
            base="$(git rev-parse HEAD~1)"
            head="$(git rev-parse HEAD)"
          fi
          git log --format=%s "${base}..${head}" | while read -r subject; do
            echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+' \
              || { echo "non-conforming subject: $subject" >&2; exit 1; }
          done
      - name: Fail on merge conflict markers
        run: |
          if git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . ':!docs/**'; then
            echo "conflict markers committed" >&2
            exit 1
          fi
      - name: Unit tests
        run: make test
```

Note as duas escolhas de endurecimento: `persist-credentials: false` mantém o token do job fora do `.git/config`, onde qualquer passo do build poderia lê-lo, e `fetch-depth: 0` é requisitado explicitamente porque passos dependentes do histórico (`git describe`, lint de commits, intervalos de `git log`) se comportam mal silenciosamente sob o clone raso padrão.

---

## 5. Topologia de repositório: monorepo vs polyrepo, e as ferramentas de escala

| Dimensão | Monorepo | Polyrepo |
|---|---|---|
| Mudança atômica entre serviços | Um commit, uma revisão | N PRs, merge coordenado, janela de corrida |
| Desvio de versão de dependências | Estruturalmente impossível (uma versão de tudo) | Estado normal; requer um registry e pinagem |
| Custo de clone/CI | Cresce com a organização inteira; precisa de partial clone + sparse checkout | Naturalmente limitado |
| Controle de acesso | Baseado em caminho, requer suporte da forge (CODEOWNERS, regras de path do GitLab) | Em nível de repositório, simples e grosseiro |
| Raio de explosão de uma `main` ruim | Todo mundo | Um time |
| Investimento em ferramental necessário | Alto (grafo de build, detecção de alvos afetados) | Baixo |
| Refatoração através de fronteiras | Barata | Cara (ciclos de depreciação) |

Um monorepo é uma aposta de que você investirá em ferramental de build; um polyrepo é uma aposta de que você investirá em coordenação de releases. Ambas as apostas são pagáveis — um monorepo sem financiamento é a falha comum.

### 5.1 Tornando um repositório grande barato de clonar

Três alavancas independentes, combináveis:

```
$ git clone --filter=blob:none --no-checkout ssh://git@git.example.org/platform/mono.git
Cloning into 'mono'...
remote: Enumerating objects: 918442, done.
remote: Total 918442 (delta 0), reused 0 (delta 0), pack-reused 918442
Receiving objects: 100% (918442/918442), 214.66 MiB | 31.22 MiB/s, done.
Resolving deltas: 100% (611930/611930), done.

$ cd mono
$ git sparse-checkout set --cone services/billing platform/lib
$ git checkout main
Updating files: 100% (1894/1894), done.
Your branch is up to date with 'origin/main'.

$ du -sh .git
248M    .git
```

| Técnica | Flag | O que é omitido | Custo quando você precisa dos dados | Segura para CI? |
|---|---|---|---|---|
| Clone raso | `--depth=1` | Todo histórico além de N commits | `git fetch --unshallow` (rebusca completa) | Só para jobs que nunca leem histórico |
| Partial clone sem blobs | `--filter=blob:none` | Conteúdo dos arquivos; trees e commits mantidos | Fetch preguiçoso por blob sob demanda | Sim — melhor padrão para CI |
| Partial clone sem trees | `--filter=tree:0` | Trees e blobs | Fetch preguiçoso, caro para `git log -- path` | Só para builds de uma única vez |
| Sparse checkout | `sparse-checkout set --cone` | Arquivos da working tree fora do cone | Estender o cone | Sim |
| Branch único | `--single-branch` | Refs de outros branches | `git remote set-branches` + fetch | Sim |

O servidor precisa aderir ao partial clone, ou o filtro é ignorado silenciosamente:

```
$ git config --system uploadpack.allowFilter true
$ git config --system uploadpack.allowAnySHA1InWant true
```

Acelere a travessia do grafo (`git log`, merge-base, `git describe`) com o commit-graph e o multi-pack index, e deixe o Git mantê-los em uma agenda:

```
$ git commit-graph write --reachable --changed-paths
$ git multi-pack-index write
$ git maintenance start
$ systemctl --user list-timers git-maintenance@*
NEXT                        LEFT     LAST                        PASSED   UNIT                            ACTIVATES
Thu 2026-09-18 15:00:00 UTC 41min    Thu 2026-09-18 14:00:00 UTC 18min    git-maintenance@hourly.timer    git-maintenance@hourly.service
Fri 2026-09-19 00:00:00 UTC 9h       Thu 2026-09-18 00:00:00 UTC 14h      git-maintenance@daily.timer     git-maintenance@daily.service
```

### 5.2 Compondo repositórios: submodules, subtrees, registry de pacotes

| Abordagem | Onde o código vive | Clone do consumidor | Pinagem | Contribuição upstream | Falha típica |
|---|---|---|---|---|---|
| **Submodule** | Repo separado; o pai armazena um gitlink (uma entrada de tree com modo `160000`) | `--recurse-submodules` obrigatório | Commit exato, sempre | Natural — commit no submodule | HEAD destacado dentro do submodule; `--recurse` esquecido; commit pinado inalcançável |
| **Subtree** | Vendorizado na tree do pai | Clone simples funciona | Pelo commit de importação | `git subtree push`, desajeitado | Poluição do histórico; contribuidores que não sabem que é vendorizado |
| **Registry de pacotes** | Artefato, não código-fonte | Clone simples | Faixa de versão ou lock file | Ciclo de release | Desvio de versão; superfície de supply-chain |
| **Diretório vendor** | Arquivos copiados, sem link upstream | Clone simples | Manual | Nenhuma | Divergência silenciosa das correções upstream |

Submodules na prática — o ciclo de vida completo, incluindo as partes que as pessoas pulam:

```
$ git submodule add -b release-1.29 ssh://git@git.example.org/platform/charts.git vendor/charts
Cloning into '/home/ada/mono/vendor/charts'...
done.

$ cat .gitmodules
[submodule "vendor/charts"]
	path = vendor/charts
	url = ssh://git@git.example.org/platform/charts.git
	branch = release-1.29

$ git ls-files --stage vendor/charts
160000 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 0	vendor/charts

$ git commit -q -m 'build: pin platform charts to release-1.29'
```

O modo `160000` é o gitlink: o commit pai armazena *um hash de commit de outro repositório*, nada mais. Consequências: os objetos do submodule não estão no banco de objetos do pai, e se aquele commit for removido por force-push upstream, todo commit pai que o referencia se torna impossível de clonar.

```
$ git config --global submodule.recurse true
$ git clone --recurse-submodules ssh://git@git.example.org/platform/mono.git
$ git submodule update --init --recursive --depth 1
$ git submodule status
 4d2f8a1b6c9e0f3a5b7d2e4f6a8c0b1d3e5f7a92 vendor/charts (release-1.29-7-g4d2f8a1)
```

Um `-` à esquerda em `git submodule status` significa não inicializado; `+` significa que o commit em checkout difere daquele que o pai pina — a causa isolada mais comum de "funciona na minha máquina" em repos com submodules.

Subtree, para comparação — nenhum passo de clone extra para os consumidores, ao custo de um histórico mais gordo:

```
$ git subtree add --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
git fetch ssh://git@git.example.org/platform/charts.git release-1.29
Added dir 'vendor/charts'

$ git subtree pull --prefix=vendor/charts ssh://git@git.example.org/platform/charts.git release-1.29 --squash
```

---

## 6. Integridade e proveniência: assinatura, proteção, propriedade

O campo `author` de um commit não assinado é uma string de texto livre. `git commit --author="Linus Torvalds <torvalds@linux-foundation.org>"` não é um ataque, é uma flag documentada. A atribuição, portanto, exige criptografia.

### 6.1 Assinatura de commits baseada em SSH (Git 2.34+)

Mais simples de operar do que GPG em escala de plataforma, porque o material de chave e o mecanismo de distribuição já existem:

```
$ git config --global gpg.format ssh
$ git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
$ git config --global commit.gpgsign true
$ git config --global tag.gpgsign true
$ git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers

$ cat ~/.config/git/allowed_signers
ada@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff
grace@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2Ww3Ee4Rr5Tt6Yy7Uu8Ii9Oo0Pp1Aa2Ss3Dd4Ff5Gg

$ git commit -q -m 'feat: enforce mTLS between gateway and billing'
$ git log --show-signature -1
commit e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
Author: Ada Lovelace <ada@example.org>
Date:   Thu Sep 18 14:12:03 2026 +0000

    feat: enforce mTLS between gateway and billing

$ git verify-commit HEAD && echo VERIFIED
Good "git" signature for ada@example.org with ED25519 key SHA256:9Yk3...q1Zc
VERIFIED
```

### 6.2 Tags: o único ponteiro de release correto

| Tipo de tag | Objeto criado | Pode ser assinada | Carrega data/tagger | Padrão do `git describe` | Uso |
|---|---|---|---|---|---|
| Leve (lightweight) | Nenhum — uma ref para um commit | Não | Não | Precisa de `--tags` | Marcadores locais |
| Anotada | Sim — um objeto de tag | Sim | Sim | Sim | **Toda release** |

```
$ git tag -s -a v2.4.1 -m 'release: v2.4.1 — gateway mTLS'
$ git cat-file -p v2.4.1
object e7a91c5d0b3f8a2e6c4d9b1f7a3e5c8d0b2f4a69
type commit
tag v2.4.1
tagger Ada Lovelace <ada@example.org> 1758204723 +0000

release: v2.4.1 — gateway mTLS
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAg...
-----END SSH SIGNATURE-----

$ git describe --tags --always --dirty
v2.4.1-0-ge7a91c5

$ git push origin v2.4.1
```

Tags são mutáveis por force-push a menos que a forge o proíba. Proteja-as no lado do servidor; uma tag de release movida invalida todo artefato construído a partir dela.

### 6.3 Propriedade e política de revisão como código

`CODEOWNERS` (GitHub, GitLab, Gitea — coloque em `.github/`, `.gitlab/` ou na raiz do repo):

```
# Fallback owner for everything not matched below.
*                               @platform/maintainers

# Kubernetes desired state requires both platform and the owning service team.
/deploy/**                      @platform/sre @platform/maintainers
/deploy/prod/**                 @platform/sre @security/appsec

# Anything that touches identity or crypto needs AppSec.
/internal/auth/**               @security/appsec
/internal/crypto/**             @security/appsec

# CI definitions are a privilege-escalation surface: treat them as code.
/.github/workflows/**           @platform/sre @security/appsec
/.gitlab-ci.yml                 @platform/sre @security/appsec
```

Combine isso com proteção de branch que imponha, no mínimo: revisão obrigatória dos code owners, status checks obrigatórios, histórico linear ou merge commits obrigatórios (escolha um e seja consistente), commits assinados, e nada de force-push / nada de deleção em `main` e `release/*`.

### 6.4 Arquivos de higiene do repositório

`.gitignore` — ignore artefatos *gerados*; nunca conte com ele para proteger segredos (não faz nada por arquivos já rastreados):

```
# Build output
/bin/
/dist/
*.o
*.test

# Local environment — never commit
.env
.env.*
!.env.example
*.kubeconfig
*.pem
*.key

# Editor and OS noise
.idea/
.vscode/
.DS_Store
```

`.gitattributes` — normalize finais de linha, marque binários, e acabe com diffs ruidosos. Este arquivo é a correção para a rotatividade de CRLF que faz o PR de todo contribuidor Windows tocar 4 000 linhas:

```
* text=auto eol=lf
*.sh text eol=lf
*.bat text eol=crlf
*.png binary
*.qcow2 filter=lfs diff=lfs merge=lfs -text
go.sum merge=union
package-lock.json -diff linguist-generated=true
secrets.enc.yaml diff=sops
```

---

## 7. Aplicação de políticas: hooks dos dois lados do fio

| Hook | Lado | Roda quando | Pode bloquear? | Uso realista |
|---|---|---|---|---|
| `pre-commit` | Cliente | Antes do editor da mensagem de commit | Sim | Formatar, lint, varredura de segredos |
| `prepare-commit-msg` | Cliente | Antes de o editor abrir | Não (edita o template) | Injetar o ID do ticket a partir do nome do branch |
| `commit-msg` | Cliente | Depois de a mensagem ser escrita | Sim | Checagem de Conventional Commits |
| `pre-push` | Cliente | Antes de os objetos serem enviados | Sim | Bloquear pushes para refs protegidas, rodar testes rápidos |
| `pre-receive` | **Servidor** | Uma vez por push, antes de qualquer atualização de ref | Sim — rejeita atomicamente o push inteiro | O único lugar onde a política é de fato imposta |
| `update` | **Servidor** | Uma vez por ref | Sim — rejeita aquela ref | Regras por branch |
| `post-receive` | **Servidor** | Depois de as refs serem atualizadas | Não | Disparar CI, notificar, espelhar |

**Hooks de cliente são conselho; hooks de servidor são política.** Qualquer um pode passar `--no-verify`. Projete de acordo: hooks de cliente para feedback rápido, hooks de servidor (ou regras de push da forge) para imposição.

Distribua hooks de cliente com um diretório rastreado em vez de `.git/hooks`, que nunca é clonado:

```
$ git config --local core.hooksPath .githooks
$ install -m 0755 /dev/stdin .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
protected='^refs/heads/(main|release/.*)$'
while read -r _local_ref local_sha remote_ref _remote_sha; do
  if [[ "$remote_ref" =~ $protected && "$local_sha" != "0000000000000000000000000000000000000000" ]]; then
    echo "pre-push: direct push to ${remote_ref} is not allowed; open a merge request" >&2
    exit 1
  fi
done
exit 0
EOF
```

Um hook `pre-receive` que impõe assinaturas, formato de mensagem e tamanho de arquivo — a contraparte do lado do servidor:

```bash
#!/usr/bin/env bash
# .git/hooks/pre-receive on the bare repository
set -euo pipefail

ZERO='0000000000000000000000000000000000000000'
MAX_BLOB_BYTES=$((5 * 1024 * 1024))
status=0

while read -r oldrev newrev refname; do
  [ "$newrev" = "$ZERO" ] && continue            # branch deletion

  if [ "$oldrev" = "$ZERO" ]; then
    range="$newrev"
    revs=$(git rev-list "$newrev" --not --all)
  else
    range="${oldrev}..${newrev}"
    revs=$(git rev-list "$range")
  fi

  for rev in $revs; do
    subject=$(git log -1 --format=%s "$rev")
    if ! echo "$subject" | grep -Eq '^(feat|fix|docs|chore|refactor|test|perf|build|ci)(\([a-z0-9-]+\))?!?: .+'; then
      echo "reject ${rev:0:8}: subject does not follow Conventional Commits: $subject" >&2
      status=1
    fi

    if [ "$refname" = "refs/heads/main" ] && ! git verify-commit "$rev" >/dev/null 2>&1; then
      echo "reject ${rev:0:8}: unsigned commit on protected ref $refname" >&2
      status=1
    fi
  done

  while read -r objsize objpath; do
    if [ "$objsize" -gt "$MAX_BLOB_BYTES" ]; then
      echo "reject: $objpath is ${objsize} bytes; use Git LFS for files over ${MAX_BLOB_BYTES}" >&2
      status=1
    fi
  done < <(git rev-list --objects "$range" --not --all \
            | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
            | awk '$1 == "blob" { print $3, $4 }')
done

exit "$status"
```

O push rejeitado se parece com isto para o desenvolvedor — note que **nenhuma ref se moveu**, porque `pre-receive` é atômico para o push inteiro:

```
$ git push origin main
Enumerating objects: 9, done.
Counting objects: 100% (9/9), done.
Writing objects: 100% (5/5), 612 bytes | 612.00 KiB/s, done.
remote: reject 4a9f1c2e: subject does not follow Conventional Commits: wip
remote: reject: assets/demo.mp4 is 41943040 bytes; use Git LFS for files over 5242880
To ssh://git@git.example.org/platform/api.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to 'ssh://git@git.example.org/platform/api.git'
```

### 7.1 O framework `pre-commit`, totalmente configurado

`.pre-commit-config.yaml` na raiz do repositório, instalado com `pre-commit install --install-hooks -t pre-commit -t commit-msg`:

```yaml
minimum_pre_commit_version: "3.5.0"
default_install_hook_types:
  - pre-commit
  - commit-msg
  - pre-push
fail_fast: false
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-added-large-files
        args:
          - "--maxkb=5120"
      - id: check-yaml
        args:
          - "--allow-multiple-documents"
      - id: check-json
      - id: detect-private-key
      - id: no-commit-to-branch
        args:
          - "--branch=main"
          - "--pattern=^release/"
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args:
          - "--strict"
          - "-d"
          - "{extends: default, rules: {line-length: {max: 160}}}"
  - repo: https://github.com/compilerla/conventional-pre-commit
    rev: v3.4.0
    hooks:
      - id: conventional-pre-commit
        stages:
          - commit-msg
        args:
          - feat
          - fix
          - docs
          - chore
          - refactor
          - test
          - perf
          - build
          - ci
```

```
$ pre-commit run --all-files
trim trailing whitespace.................................................Passed
fix end of files.........................................................Passed
check for merge conflicts................................................Passed
check for added large files..............................................Passed
check yaml...............................................................Passed
check json...............................................................Passed
detect private key.......................................................Failed
- hook id: detect-private-key
- exit code: 1

deploy/prod/tls.yaml:12: BEGIN RSA PRIVATE KEY

yamllint.................................................................Passed
Conventional Commit......................................................Passed
```

---

## 8. O repositório como estado desejado: a ligação com GitOps

Em uma plataforma GitOps a camada de SCM deixa de ser "onde os desenvolvedores guardam código" e se torna a entrada do control plane. Duas propriedades passam a sustentar a carga: **a revisão precisa ser imutável e endereçável** (pine em uma tag ou digest, nunca em um branch móvel, para produção) e **o acesso de leitura do reconciliador precisa ser de menor privilégio** (uma deploy key com escopo somente leitura, não um token pessoal).

`Application` do Argo CD, pinado a uma tag assinada, com sync automatizado e correção de desvio:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: billing-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: ssh://git@git.example.org/platform/deploy.git
    targetRevision: v2.4.1
    path: overlays/prod/billing
  destination:
    server: https://kubernetes.default.svc
    namespace: billing
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  revisionHistoryLimit: 20
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

O `AppProject` que restringe quais repositórios o Argo CD sequer irá ler — sem ele, um único `Application` comprometido pode apontar o cluster para qualquer repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: "Platform-owned workloads, deployed only from the deploy repository"
  sourceRepos:
    - ssh://git@git.example.org/platform/deploy.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: billing
    - server: https://kubernetes.default.svc
      namespace: gateway
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  signatureKeys:
    - keyID: 4AEE18F83AFDEB23
  roles:
    - name: read-only
      description: "Read-only access for on-call engineers"
      policies:
        - "p, proj:platform:read-only, applications, get, platform/*, allow"
```

`signatureKeys` é a parte que amarra a seção 6 à seção 8: o Argo CD se recusará a sincronizar uma revisão cujo commit não esteja assinado por uma chave listada. A assinatura do Git se torna uma decisão de controle de admissão.

O equivalente com Flux — a fonte `GitRepository`, separada da reconciliação:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-deploy
  namespace: flux-system
spec:
  interval: 1m
  url: ssh://git@git.example.org/platform/deploy.git
  ref:
    tag: v2.4.1
  secretRef:
    name: platform-deploy-key
  verify:
    mode: HEAD
    secretRef:
      name: platform-signing-keys
  ignore: |
    /*
    !/overlays
    !/base
```

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: billing-prod
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-deploy
  path: ./overlays/prod/billing
  targetNamespace: billing
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: billing-api
      namespace: billing
```

A deploy key somente leitura, montada como um `Secret` — note o `stringData` com material de placeholder; a chave real é injetada por SOPS ou por um operador de segredos externo, nunca commitada:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-deploy-key
  namespace: flux-system
type: Opaque
stringData:
  identity: "<ed25519 private key injected by the secrets operator>"
  identity.pub: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7Qm2v3Xk9Lp0Rr5Ty8Uu1Ii2Oo3Pp4Aa5Ss6Dd7Ff flux@example.org"
  known_hosts: "git.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKeyMaterialGoesHere0123456789"
```

### 8.1 Servidor Git auto-hospedado como infraestrutura de plataforma

Uma instância Gitea completa e implantável — o ponto é que o próprio serviço de SCM é declarado, versionado e reconciliado como qualquer outra carga de trabalho. Um documento por manifesto.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: scm
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitea-config
  namespace: scm
data:
  app.ini: |
    APP_NAME = Example Platform SCM
    RUN_MODE = prod

    [server]
    PROTOCOL = http
    DOMAIN = git.example.org
    ROOT_URL = https://git.example.org/
    HTTP_PORT = 3000
    SSH_DOMAIN = git.example.org
    SSH_PORT = 22
    START_SSH_SERVER = true
    SSH_LISTEN_PORT = 2222
    LFS_START_SERVER = true

    [repository]
    DEFAULT_BRANCH = main
    DEFAULT_PUSH_CREATE_PRIVATE = true

    [repository.signing]
    INITIAL_COMMIT = never
    CRUD_ACTIONS = pubkey, twofa
    MERGES = pubkey, twofa

    [security]
    INSTALL_LOCK = true
    DISABLE_GIT_HOOKS = false

    [service]
    DISABLE_REGISTRATION = true
    REQUIRE_SIGNIN_VIEW = true

    [metrics]
    ENABLED = true

    [log]
    LEVEL = info
```

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitea
  namespace: scm
spec:
  serviceName: gitea
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gitea
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gitea
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: /metrics
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gitea
          image: gitea/gitea:1.22.3-rootless
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3000
            - name: ssh
              containerPort: 2222
          env:
            - name: GITEA_APP_INI
              value: /etc/gitea/conf/app.ini
            - name: GITEA__database__DB_TYPE
              value: postgres
            - name: GITEA__database__HOST
              value: "postgres.scm.svc.cluster.local:5432"
            - name: GITEA__database__NAME
              value: gitea
            - name: GITEA__database__USER
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: username
            - name: GITEA__database__PASSWD
              valueFrom:
                secretKeyRef:
                  name: gitea-db
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/gitea
            - name: config
              mountPath: /etc/gitea/conf
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: "2"
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /api/healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 60
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config
          configMap:
            name: gitea-config
        - name: tmp
          emptyDir:
            sizeLimit: 2Gi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 200Gi
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: scm
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: gitea
  ports:
    - name: http
      port: 3000
      targetPort: http
    - name: ssh
      port: 22
      targetPort: ssh
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea
  namespace: scm
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "1024m"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - git.example.org
      secretName: gitea-tls
  rules:
    - host: git.example.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitea
                port:
                  name: http
```

`proxy-body-size` não é cosmético: o limite padrão de 1 MiB no corpo da requisição no NGINX Ingress rejeita qualquer push maior que isso com um opaco `HTTP 413`, que chega ao desenvolvedor como `RPC failed; HTTP 413`.

Alertas sobre o serviço de SCM, incluindo o sinal de crescimento de armazenamento que prediz o incidente do "alguém commitou uma imagem de VM":

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: scm-platform
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: scm.rules
      rules:
        - alert: GitServerDown
          expr: up{job="gitea"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Git server unreachable — all pipelines and GitOps reconciliation are blocked"
        - alert: GitRepositoryStorageGrowth
          expr: |
            (
              max by (instance) (gitea_repositories_size_bytes)
              -
              max by (instance) (gitea_repositories_size_bytes offset 7d)
            )
            /
            max by (instance) (gitea_repositories_size_bytes offset 7d)
            > 0.5
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Repository storage grew more than 50 percent in seven days; check for large binaries committed outside LFS"
        - alert: GitVolumeNearlyFull
          expr: |
            kubelet_volume_stats_available_bytes{namespace="scm"}
            /
            kubelet_volume_stats_capacity_bytes{namespace="scm"}
            < 0.15
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "SCM persistent volume below 15 percent free"
```

---

## 9. Binários grandes: Git LFS

O Git armazena cada versão de cada arquivo para sempre. Um binário de 200 MB alterado semanalmente adiciona ~10 GB de packfile por ano que todo clone precisa baixar. O LFS substitui o blob por um pequeno ponteiro de texto e move os bytes para um armazenamento separado.

```
$ git lfs install
Updated Git hooks.
Git LFS initialized.

$ git lfs track "*.qcow2" "*.tar.zst"
Tracking "*.qcow2"
Tracking "*.tar.zst"

$ cat .gitattributes
*.qcow2 filter=lfs diff=lfs merge=lfs -text
*.tar.zst filter=lfs diff=lfs merge=lfs -text

$ git add .gitattributes images/base.qcow2
$ git commit -q -m 'build: track VM images with LFS'
$ git show HEAD:images/base.qcow2
version https://git-lfs.github.com/spec/v1
oid sha256:6f1e3c9a8b2d4f7e0a1c5b9d3e6f8a2c4b7d0e3f6a9c2b5d8e1f4a7c0b3d6e9f
size 2147483648

$ git lfs ls-files
6f1e3c9a8b * images/base.qcow2
```

| Consideração | Comportamento |
|---|---|
| Clone sem o LFS instalado | Você obtém arquivos de ponteiro, não conteúdo — builds falham com "not a valid image" |
| CI | Precisa de `lfs: true` no checkout, ou de `git lfs pull` explícito |
| Suporte do servidor | A forge precisa implementar a API do LFS; um repo bare por SSH sozinho não basta |
| Migração de histórico existente | `git lfs migrate import --include="*.qcow2" --everything` — **reescreve o histórico**, mesmo raio de explosão que uma execução de filter-repo |
| Deleção | Remover o ponteiro não recupera armazenamento no servidor; objetos LFS são coletados como lixo separadamente |

---

## 10. Segredos commitados no histórico: detecção, remoção cirúrgica, rotação

**Primeiro princípio: um segredo enviado por push para um repositório compartilhado está comprometido. Rotacione-o. A remoção do histórico é limpeza, não remediação** — clones, forks, caches de CI e o próprio armazenamento de objetos pendentes da forge podem retê-lo.

Detectar:

```
$ gitleaks detect --source . --redact --report-format json --report-path /tmp/leaks.json
    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

10:41AM INF 1483 commits scanned.
10:41AM INF scanned ~48.2 MB (2.19s)
10:41AM WRN leaks found: 2

$ git log --all --oneline -S 'AKIA' -- .
4a9f1c2 chore: local testing setup
b7e3d80 feat: initial terraform for the artifact bucket
```

`git log -S<string>` é a *picareta* (pickaxe): ele encontra commits onde o número de ocorrências da string mudou — isto é, onde ela foi introduzida ou removida. `git log -G<regex>` casa com o próprio texto do diff. Ambos são as ferramentas corretas para "quando esta linha apareceu", e ambos são muito mais baratos que varrer checkouts.

Remover, usando `git-filter-repo` (o substituto mantido para o obsoleto `git filter-branch`):

```
$ git clone --mirror ssh://git@git.example.org/platform/api.git api-mirror.git
$ cd api-mirror.git
$ git filter-repo --invert-paths --path .env.production --path terraform/secrets.auto.tfvars
Parsed 1483 commits
New history written in 4.12 seconds; now repacking/cleaning...
Repacking your repo and cleaning out old unneeded objects
Completely finished after 9.87 seconds.

$ git filter-repo --replace-text <(printf 'AKIAIOSFODNN7EXAMPLE==>***REMOVED***\n')
Parsed 1483 commits
New history written in 3.64 seconds; now repacking/cleaning...
Completely finished after 8.91 seconds.

$ git count-objects -vH
count: 0
size: 0 bytes
in-pack: 21488
packs: 1
size-pack: 38.11 MiB
prune-packable: 0
garbage: 0
size-garbage: 0 bytes
```

As consequências, que precisam ser comunicadas antes de você executar isso:

1. **Todo hash de commit após o commit reescrito mais antigo muda.** Tags, referências de PR, registros de deployment e saídas de `git describe` que nomeavam hashes antigos agora apontam para o nada.
2. Todo clone precisa ser recriado. Um desenvolvedor que fizer pull e merge vai *reintroduzir* o histórico antigo.
3. O `git-filter-repo` remove deliberadamente o remote `origin` após a reescrita, para que você não possa fazer push por acidente.
4. A forge ainda mantém objetos inalcançáveis até rodar seu próprio GC — abra um chamado de suporte/administração para purgá-los.

```
$ git remote add origin ssh://git@git.example.org/platform/api.git
$ git push --force --mirror origin
```

Depois rotacione: revogue a chave AWS, reemita o token, resele o arquivo SOPS, e registre o incidente.

---

## 11. Verificação e diagnóstico de falhas

### 11.1 Saúde do banco de objetos

```
$ git fsck --full --strict --unreachable --dangling
Checking object directories: 100% (256/256), done.
Checking objects: 100% (21488/21488), done.
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40
dangling blob 7c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b3c69

$ git count-objects -vH
count: 1842
size: 12.44 MiB
in-pack: 21488
packs: 3
size-pack: 214.66 MiB
prune-packable: 118
garbage: 0
size-garbage: 0 bytes

$ git gc --prune=now
Enumerating objects: 23330, done.
Counting objects: 100% (23330/23330), done.
Delta compression using up to 8 threads
Compressing objects: 100% (6104/6104), done.
Writing objects: 100% (23330/23330), done.
Total 23330 (delta 15918), reused 21488 (delta 14700), pack-reused 0
```

"Dangling" é normal após um rebase, reset ou amend — é histórico não referenciado aguardando o GC, e é exatamente aquilo que você recupera. "Corrupt" não é normal; veja a tabela abaixo.

### 11.2 Encontrando o commit que quebrou a produção

`git bisect` é uma busca binária sobre o histórico. `git bisect run` a automatiza com um script cujo código de saída decide: `0` = bom, `1..124` = ruim, `125` = pular (não testável), `>127` = abortar.

```
$ git bisect start
$ git bisect bad v2.4.1
$ git bisect good v2.3.0
Bisecting: 61 revisions left to test after this (roughly 6 steps)
[8f3c1a90b2d4e6f8a0c2e4f6a8c0e2f4a6c8e0f2] refactor: split the gateway config loader

$ git bisect run ./hack/repro-regression.sh
running './hack/repro-regression.sh'
Bisecting: 30 revisions left to test after this (roughly 5 steps)
...
d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64 is the first bad commit
commit d41c8e7b3a5f9c2e6b0d4f8a1c5e9b3d7f0a2c64
Author: Grace Hopper <grace@example.org>
Date:   Mon Sep 14 09:22:41 2026 +0000

    fix: normalise upstream timeout units

 internal/gateway/config.go | 6 +++---
 1 file changed, 3 insertions(+), 3 deletions(-)
bisect found first bad commit

$ git bisect reset
Previous HEAD position was d41c8e7 fix: normalise upstream timeout units
Switched to branch 'main'
```

Investigação complementar:

```
$ git blame -L 88,96 --show-email -w -C internal/gateway/config.go
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 88)     timeout := cfg.UpstreamTimeout * time.Second
d41c8e7b (<grace@example.org> 2026-09-14 09:22:41 +0000 89)     if timeout <= 0 {

$ git log --first-parent --oneline --decorate main..origin/main
$ git log --format='%h %ad %an %s' --date=short --since='7 days ago' -- deploy/prod/
```

`-w` ignora mudanças de espaço em branco e `-C` segue código movido entre arquivos — sem eles, o `blame` frequentemente credita um commit de reformatação em vez do autor da lógica.

### 11.3 Recuperação de operações destrutivas

```
$ git reset --hard HEAD~5
HEAD is now at 1a2b3c4 chore: bump base image

$ git reflog
1a2b3c4 HEAD@{0}: reset: moving to HEAD~5
9c1f0a4 HEAD@{1}: commit: feat: add readiness probe
...

$ git reset --hard HEAD@{1}
HEAD is now at 9c1f0a4 feat: add readiness probe
```

Se a entrada do reflog sumiu mas o GC não rodou, o commit ainda é um objeto pendente (dangling):

```
$ git fsck --lost-found
dangling commit 3f1a9b7c0d2e5f8a1b4c7d0e3f6a9c2b5d8e1f40

$ git show --stat 3f1a9b7
$ git branch recovered/probe 3f1a9b7
```

### 11.4 Tabela de diagnóstico: sintoma → mecanismo → resolução

| Mensagem / sintoma | O que está realmente acontecendo | Resolução |
|---|---|---|
| `fatal: refusing to merge unrelated histories` | Os dois branches não compartilham base de merge (dois `git init` independentes) | `git merge --allow-unrelated-histories` — e verifique se é isso que você quer, e não um remote adicionado por engano |
| `! [rejected] main -> main (non-fast-forward)` | O remoto tem commits que você não tem | `git fetch && git rebase origin/main` (ou merge); nunca `--force` em uma ref compartilhada |
| `! [remote rejected] (pre-receive hook declined)` | A política do servidor recusou o push, atomicamente | Leia as linhas `remote:`; corrija localmente e refaça o push |
| `You are in 'detached HEAD' state` | `.git/HEAD` contém um hash, não uma symref | `git switch -c <branch>` para manter o trabalho, ou `git switch -` para descartar a posição |
| `fatal: Not possible to fast-forward, aborting.` | `pull.ff=only` e os históricos divergiram | `git pull --rebase` ou `git pull --no-rebase` explicitamente |
| `error: object file .git/objects/ab/cdef… is empty` | Objeto solto corrompido, geralmente um desligamento sujo ou disco cheio | Apague o arquivo vazio, `git fsck`, e então busque o objeto de outro clone: `git fetch <peer-clone> --tags` |
| `fatal: remote error: upload-pack: not our ref <sha>` | Um submodule ou pin de CI referencia um commit que foi removido por force-push | Restaure o commit upstream, ou repine o submodule a um commit alcançável |
| `shallow update not allowed` | Fazendo push de um clone `--depth` para um repo completo | `git fetch --unshallow` antes do push |
| Todo arquivo aparece como modificado após o checkout | Incompatibilidade de normalização CRLF/LF | Adicione `* text=auto eol=lf` ao `.gitattributes`, depois `git add --renormalize .` |
| Um arquivo aparece duas vezes com caixa diferente | Sistema de arquivos insensível à caixa (macOS/Windows) colapsou dois caminhos | `git config core.ignorecase true` localmente; corrija removendo um dos caminhos em um host sensível à caixa |
| Arquivos LFS são pequenos blobs de texto | Filtro LFS não instalado naquele ambiente | `git lfs install && git lfs pull`; no CI defina `lfs: true` no checkout |
| `RPC failed; curl 92 HTTP/2 stream … / HTTP 413` | Limite de tamanho de corpo do proxy ou ingress em um push grande | Aumente o `proxy-body-size`, ou faça push por SSH; `git config http.postBuffer 524288000` como paliativo |
| O clone leva minutos em cada job de CI | Histórico completo + blobs buscados | `--filter=blob:none` + sparse checkout; `--depth=1` somente se nenhum histórico for lido |
| O diretório `.git` cresce sem limite | Objetos soltos nunca empacotados, ou binários grandes no histórico | `git maintenance start`; audite com `git rev-list --objects --all \| git cat-file --batch-check` e mova binários para o LFS |
| Commits aparecem fora de ordem em `git log` | `--date-order` vs data de autoria; ou desvio de relógio do committer | Use `git log --date-order` / `--topo-order`; corrija o NTP no host problemático |
| Um conflito resolvido reaparece resolvido *erradamente* | O `rerere` reproduziu uma resolução ruim em cache | `git rerere forget <path>`, resolva de novo |

### 11.5 Uma rotina de verificação que vale a pena automatizar

```
$ git fsck --full --strict
$ git count-objects -vH
$ git verify-commit HEAD
$ git verify-tag "$(git describe --tags --abbrev=0)"
$ git log --oneline --no-merges origin/main..HEAD
$ git diff --stat origin/main...HEAD
$ git grep -nE '^(<{7}|={7}|>{7})( |$)' -- . || echo 'no conflict markers'
$ git ls-files -z | xargs -0 -n1 -I{} sh -c 'test $(git cat-file -s :{} 2>/dev/null || echo 0) -lt 5242880 || echo "large: {}"'
```

Três pontos (`origin/main...HEAD`) em `git diff` significa "mudanças em HEAD desde a base do merge" — o diff que um revisor vê. Dois pontos significa "diferença entre os dois extremos", o que inclui mudanças feitas na `origin/main` invertidas. Escolher o errado é a origem de diffs de PR que parecem reverter o trabalho de outras pessoas.

---

## 12. Referência de comandos, agrupada por mecanismo

| Preocupação | Comandos |
|---|---|
| Criar / obter | `git init [--bare] [--initial-branch=main] [--object-format=sha256]`, `git clone [--depth] [--filter] [--recurse-submodules] [--single-branch]` |
| Inspecionar estado | `git status [--short] [--branch]`, `git diff [--staged] [--stat] [A...B]`, `git show`, `git log [--oneline] [--graph] [--first-parent] [-S] [-G] [--follow]`, `git blame [-L] [-w] [-C]` |
| Preparar e registrar | `git add [-p] [--renormalize]`, `git rm [--cached]`, `git mv`, `git commit [-s] [-S] [--amend] [--fixup]`, `git restore [--staged]` |
| Branch e posição | `git branch [-a] [-m] [--merged]`, `git switch [-c] [--detach]`, `git checkout`, `git worktree add`, `git tag [-a] [-s] [-d]` |
| Integrar | `git merge [--no-ff] [--ff-only] [--squash] [-s ort]`, `git rebase [-i] [--onto] [--autosquash]`, `git cherry-pick [-x]`, `git revert [-m 1]`, `git range-diff` |
| Trocar | `git remote [-v] [add] [set-url]`, `git fetch [--prune] [--unshallow]`, `git pull [--rebase] [--ff-only]`, `git push [--tags] [--force-with-lease] [--force-if-includes] [--mirror]` |
| Desfazer | `git reset [--soft|--mixed|--hard]`, `git restore`, `git revert`, `git reflog`, `git stash [push -u] [list] [pop] [drop]` |
| Composição | `git submodule [add] [update --init --recursive] [status] [sync]`, `git subtree [add] [pull] [push]`, `git lfs [install] [track] [ls-files] [migrate]` |
| Investigação | `git bisect [start] [good] [bad] [run] [reset]`, `git fsck [--lost-found]`, `git rev-list --objects --all`, `git cat-file [-t|-s|-p|--batch-check]`, `git hash-object`, `git ls-tree`, `git ls-files --stage`, `git verify-pack -v` |
| Manutenção | `git gc [--prune=now]`, `git repack -adb`, `git commit-graph write --reachable`, `git multi-pack-index write`, `git maintenance [start|run]`, `git count-objects -vH` |
| Proveniência | `git commit -S`, `git tag -s`, `git verify-commit`, `git verify-tag`, `git log --show-signature`, `git notes` |

---

## Referencias

- LPI — DevOps Tools Engineer, Exam 701 Objectives (v2.0): https://www.lpi.org/our-certifications/exam-701-objectives/
- Git — Reference manual (all commands): https://git-scm.com/docs
- Git — Pro Git book, "Git Internals": https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain
- Git — `git-merge` and merge strategies (`ort`, `octopus`, `ours`): https://git-scm.com/docs/git-merge
- Git — `git-rebase`: https://git-scm.com/docs/git-rebase
- Git — `git-rerere`: https://git-scm.com/docs/git-rerere
- Git — `git-bisect`: https://git-scm.com/docs/git-bisect
- Git — `git-submodule`: https://git-scm.com/docs/git-submodule
- Git — `gitattributes(5)`: https://git-scm.com/docs/gitattributes
- Git — `gitignore(5)`: https://git-scm.com/docs/gitignore
- Git — `githooks(5)`: https://git-scm.com/docs/githooks
- Git — `git-maintenance`: https://git-scm.com/docs/git-maintenance
- Git — `git-config` (`transfer.fsckObjects`, `uploadpack.allowFilter`, `gpg.ssh.allowedSignersFile`): https://git-scm.com/docs/git-config
- Git — Partial clone design documentation: https://git-scm.com/docs/partial-clone
- Git — `git-sparse-checkout`: https://git-scm.com/docs/git-sparse-checkout
- Git — Hash function transition (SHA-256): https://git-scm.com/docs/hash-function-transition
- Git — `git-filter-branch` deprecation notice and alternatives: https://git-scm.com/docs/git-filter-branch
- git-filter-repo — upstream repository and user manual: https://github.com/newren/git-filter-repo
- Git LFS — specification and documentation: https://github.com/git-lfs/git-lfs/tree/main/docs
- GitHub Docs — About protected branches: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- GitHub Docs — About code owners: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
- GitHub Docs — Merge queue: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitLab Docs — GitLab Flow: https://docs.gitlab.com/ee/topics/gitlab_flow.html
- GitLab Docs — Protected branches: https://docs.gitlab.com/ee/user/project/protected_branches.html
- Conventional Commits 1.0.0: https://www.conventionalcommits.org/en/v1.0.0/
- pre-commit — framework documentation: https://pre-commit.com/
- Gitleaks — documentation: https://github.com/gitleaks/gitleaks
- Argo CD — Application specification and GnuPG signature verification: https://argo-cd.readthedocs.io/en/stable/user-guide/gpg-verification/
- Argo CD — Projects: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Flux — GitRepository API: https://fluxcd.io/flux/components/source/gitrepositories/
- Flux — Kustomization API: https://fluxcd.io/flux/components/kustomize/kustomizations/
- OpenGitOps — Principles v1.0.0: https://opengitops.dev/
- Gitea — Configuration cheat sheet: https://docs.gitea.com/administration/config-cheat-sheet
- Sigstore — Gitsign, keyless Git commit signing: https://docs.sigstore.dev/cosign/signing/gitsign/