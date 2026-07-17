# Exercícios Guiados — Tópico 5.1: Basic Security and Identifying User Types

**Certificação:** LPI Linux Essentials (exam 010-160, v1.6)
**Fonte de referência:** https://learning.lpi.org/en/learning-materials/010-160/5/5.1/

---

## Exercício 1 — Identificando tipos de user no sistema

O Linux distingue três categorias de accounts: o **superuser** (`root`, UID 0), os **system users** (usados por serviços e daemons) e os **regular users** (contas de pessoas). Essa distinção fica registrada no arquivo `/etc/passwd`.

1. Abra um terminal e visualize o conteúdo do arquivo de contas:
   ```
   cat /etc/passwd
   ```
2. Observe a estrutura de cada linha, separada por `:` — são sete campos: `username:password:UID:GID:comment:home directory:shell`.
3. Filtre apenas a linha do `root`:
   ```
   grep '^root:' /etc/passwd
   ```
4. Liste os usernames com UID menor que 1000 (tipicamente system users em distros como Debian/Ubuntu):
   ```
   awk -F: '$3 < 1000 {print $1, $3}' /etc/passwd
   ```
5. Agora liste os usernames com UID igual ou maior que 1000 (regular users):
   ```
   awk -F: '$3 >= 1000 {print $1, $3}' /etc/passwd
   ```

**Perguntas de verificação:**
- Qual é o UID do `root` e por que ele é tratado de forma especial pelo kernel?
- Por que serviços como `www-data` ou `sshd` têm uma conta própria em vez de rodar como `root`?

---

## Exercício 2 — Password aging e o arquivo shadow

As senhas (hashes) não ficam em `/etc/passwd` (que é legível por qualquer user); ficam em `/etc/shadow`, protegido e legível apenas por `root`.

1. Tente ler o arquivo shadow como regular user:
   ```
   cat /etc/shadow
   ```
   Você deve receber `Permission denied`.
2. Agora leia o mesmo arquivo com privilégio elevado:
   ```
   sudo cat /etc/shadow
   ```
3. Localize a linha correspondente ao seu username e identifique os campos separados por `:`: username, password hash, data da última troca, mínimo de dias, máximo de dias, período de aviso, período de inatividade, data de expiração.
4. Consulte a política de aging da sua própria conta com um comando dedicado:
   ```
   sudo chage -l $(whoami)
   ```

**Perguntas de verificação:**
- Por que separar as senhas em `/etc/shadow` em vez de mantê-las em `/etc/passwd` é uma prática de security melhor?
- O que significa um campo de password começando com `!` ou `*` em `/etc/shadow`?

---

## Exercício 3 — `su` versus `sudo`

Existem duas formas principais de obter privilégios administrativos: trocar completamente de identidade (`su`) ou executar um comando pontual com privilégio elevado (`sudo`).

1. Verifique qual user você é atualmente:
   ```
   whoami
   ```
2. Tente se tornar `root` diretamente:
   ```
   su -
   ```
   Digite a senha de `root` (se disponível no seu ambiente de prática) e depois saia com `exit`.
3. Em vez de trocar de identidade, execute um único comando como `root` usando `sudo`:
   ```
   sudo whoami
   ```
4. Verifique os privilégios de `sudo` da sua conta:
   ```
   sudo -l
   ```
5. Consulte, sem editar, o arquivo que define quem pode usar `sudo` e com quais permissões:
   ```
   sudo cat /etc/sudoers
   ```

**Perguntas de verificação:**
- Qual a diferença prática entre `su -` e `sudo <comando>` em termos de sessão e de rastreabilidade (logging)?
- Por que a documentação da LPI recomenda editar `/etc/sudoers` apenas com o comando `visudo`, e nunca com um editor de texto comum?

---

## Exercício 4 — Identificando membership em groups

Cada user pertence a um primary group e pode pertencer a vários secondary groups, o que também é parte do modelo de security do Linux.

1. Veja o UID, GID e todos os groups do seu user atual:
   ```
   id
   ```
2. Liste apenas os nomes dos groups aos quais você pertence:
   ```
   groups
   ```
3. Verifique os groups de outro user do sistema (por exemplo, `root`):
   ```
   id root
   ```
4. Procure no arquivo `/etc/group` pela linha do group `sudo` (ou `wheel`, dependendo da distro) para ver quem tem permissão administrativa via membership:
   ```
   grep -E '^(sudo|wheel):' /etc/group
   ```

**Perguntas de verificação:**
- Qual é a diferença entre primary group e secondary group?
- Como o membership em um group como `sudo` ou `wheel` concede privilégios administrativos sem que o user precise saber a senha de `root`?

---

## Exercício 5 — Boas práticas de security ao criar contas

Um dos pontos centrais do objetivo 5.1 é aplicar o princípio de **least privilege**: nunca conceder mais acesso do que o necessário.

1. Crie uma nova conta de regular user (requer privilégio administrativo):
   ```
   sudo useradd -m estudante
   ```
2. Defina uma senha para essa conta:
   ```
   sudo passwd estudante
   ```
3. Force a troca de senha no próximo login, uma prática comum de security:
   ```
   sudo chage -d 0 estudante
   ```
4. Bloqueie a conta temporariamente sem apagá-la:
   ```
   sudo usermod -L estudante
   ```
5. Verifique o efeito do bloqueio consultando o campo de password em `/etc/shadow`:
   ```
   sudo grep '^estudante:' /etc/shadow
   ```
6. Desbloqueie a conta novamente:
   ```
   sudo usermod -U estudante
   ```

**Perguntas de verificação:**
- Qual é a diferença entre bloquear uma conta (`usermod -L`) e removê-la (`userdel`)?
- Por que forçar a troca de senha no primeiro login é considerado boa prática ao criar contas para outras pessoas?

---

## Exercício 6 — Riscos comuns e mitigação

O objetivo 5.1 também cobra o reconhecimento de riscos básicos de security, como login direto como `root` e uso de protocolos inseguros.

1. Verifique se o login direto como `root` via SSH está habilitado, procurando a diretiva correspondente:
   ```
   sudo grep -i '^PermitRootLogin' /etc/ssh/sshd_config
   ```
2. Verifique se existe algum serviço de acesso remoto inseguro (como `telnet`) instalado:
   ```
   which telnet
   ```
3. Liste os serviços de rede ativos no momento para avaliar a superfície de ataque:
   ```
   ss -tulnp
   ```

**Perguntas de verificação:**
- Por que desabilitar `PermitRootLogin` no SSH e usar `sudo` a partir de uma conta regular é considerado mais seguro?
- Por que protocolos como `telnet` ou `ftp` são considerados riscos de security em comparação com `ssh` ou `sftp`?

---

<details>
<summary><strong>Respostas</strong></summary>

**Exercício 1**
- O `root` tem sempre UID 0. É o único UID que o kernel trata como tendo acesso irrestrito ao sistema, ignorando as verificações normais de permissão.
- Rodar serviços com contas dedicadas (system accounts) limita o dano em caso de comprometimento: se o serviço for explorado, o invasor herda apenas os privilégios daquela conta específica, não os de `root`.

**Exercício 2**
- Manter `/etc/passwd` legível por todos é necessário porque muitos programas precisam consultar informações como username, UID e shell; mas se as senhas ficassem ali, qualquer user poderia copiar os hashes e tentar quebrá-los offline. Separá-las em `/etc/shadow`, legível só por `root`, reduz essa exposição.
- Um `!` ou `*` no campo de password indica que a conta está bloqueada/desabilitada para login por senha (não tem hash válido correspondente).

**Exercício 3**
- `su -` abre uma nova sessão de shell completa como o user alvo (com o environment dele), exigindo a senha desse user. `sudo <comando>` executa apenas um comando pontual com privilégio elevado, usando a senha do próprio user que o invoca, e cada uso fica registrado em log (geralmente em `/var/log/auth.log` ou `/var/log/secure`), o que dá melhor rastreabilidade (accountability).
- `visudo` valida a sintaxe do arquivo antes de salvar e bloqueia edições concorrentes. Editar `/etc/sudoers` diretamente com um editor comum pode introduzir um erro de sintaxe que impede qualquer user, inclusive `root`, de usar `sudo` até o arquivo ser corrigido via outro método de acesso.

**Exercício 4**
- O primary group é o group padrão atribuído a um user (definido no campo GID de `/etc/passwd`), usado por exemplo na criação de novos arquivos. Secondary groups são adicionais, listados em `/etc/group`, e concedem acesso extra sem alterar o group padrão do user.
- Adicionar um user ao group `sudo`/`wheel` concede a ele permissão para usar o comando `sudo` (conforme configurado em `/etc/sudoers`), autenticando com a própria senha do user, sem que ele precise conhecer a senha de `root`.

**Exercício 5**
- `usermod -L` apenas bloqueia a autenticação por senha (insere um caractere inválido no hash em `/etc/shadow`), mantendo a conta, seus arquivos e seu histórico intactos e reversíveis. `userdel` remove a conta permanentemente (e, com `-r`, também o home directory).
- Forçar a troca de senha no primeiro login evita que a senha temporária definida pelo administrador continue em uso indefinidamente, reduzindo o risco de ela ser compartilhada ou reutilizada.

**Exercício 6**
- Desabilitar `PermitRootLogin` obriga qualquer acesso administrativo remoto a passar primeiro por uma conta regular autenticada e depois por `sudo`, criando uma camada extra de autenticação e um log de auditoria de quem executou ações como `root`.
- Protocolos como `telnet` e `ftp` transmitem credenciais e dados em texto plano pela rede, permitindo que sejam capturados por qualquer um que consiga interceptar o tráfego. `ssh` e `sftp` criptografam a comunicação, protegendo credenciais e dados em trânsito.

</details>