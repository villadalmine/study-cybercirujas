# Exercícios Guiados — Tópico 5.2: Creating Users and Groups

**Certificação:** LPI Linux Essentials (010-160, versão 1.6)
**Peso no exame:** 2
**Fonte de referência:** https://learning.lpi.org/en/learning-materials/010-160/5/5.2/

> Pré-requisito: acesso a um terminal Linux com privilégios de `root` (ou `sudo`). Todos os comandos administrativos abaixo devem ser executados com `sudo` caso você esteja logado como usuário comum.

---

## Exercício 1 — Explorando os arquivos de contas do sistema

1. Abra um terminal e visualize o conteúdo do arquivo de contas de usuários:
   ```
   cat /etc/passwd
   ```
2. Localize sua própria linha usando `grep`:
   ```
   grep "^$(whoami):" /etc/passwd
   ```
3. Observe os sete campos separados por `:` (username, password placeholder, UID, GID, GECOS, home directory, login shell).
4. Agora visualize o arquivo de grupos:
   ```
   cat /etc/group
   ```
5. Verifique a que grupos seu usuário pertence:
   ```
   id
   groups
   ```
6. Tente ler o arquivo de senhas criptografadas sem privilégios elevados:
   ```
   cat /etc/shadow
   ```
7. Repita o comando anterior com `sudo`:
   ```
   sudo cat /etc/shadow
   ```

**Perguntas:**
1. Por que o campo de senha em `/etc/passwd` normalmente contém apenas um `x`?
2. Por que o comando `cat /etc/shadow` falha sem `sudo`, enquanto `cat /etc/passwd` funciona para qualquer usuário?

---

## Exercício 2 — Criando um usuário com `useradd`

1. Crie um novo usuário chamado `estudante1`, com criação automática do home directory:
   ```
   sudo useradd -m estudante1
   ```
2. Verifique se a conta foi criada corretamente:
   ```
   grep estudante1 /etc/passwd
   ```
3. Confira se o home directory foi criado e populado a partir do `/etc/skel`:
   ```
   ls -la /home/estudante1
   ```
4. Observe que a conta está bloqueada (sem senha definida) tentando fazer login:
   ```
   sudo passwd -S estudante1
   ```
5. Crie um segundo usuário, agora especificando explicitamente o shell de login:
   ```
   sudo useradd -m -s /bin/bash estudante2
   ```
6. Compare os dois usuários criados:
   ```
   grep -E "estudante1|estudante2" /etc/passwd
   ```

**Perguntas:**
1. O que é o diretório `/etc/skel` e qual seu papel na criação de um novo usuário?
2. O que a opção `-m` faz no comando `useradd`, e o que aconteceria se ela fosse omitida?

---

## Exercício 3 — Definindo e testando a senha com `passwd`

1. Defina uma senha para `estudante1`:
   ```
   sudo passwd estudante1
   ```
2. Verifique novamente o status da conta:
   ```
   sudo passwd -S estudante1
   ```
3. Troque para o usuário recém-criado:
   ```
   su - estudante1
   ```
4. Como `estudante1`, tente trocar a própria senha:
   ```
   passwd
   ```
5. Volte para seu usuário original:
   ```
   exit
   ```
6. Como `root` (ou via `sudo`), bloqueie a conta de `estudante2` sem removê-la:
   ```
   sudo passwd -l estudante2
   ```
7. Confirme o bloqueio:
   ```
   sudo passwd -S estudante2
   ```

**Perguntas:**
1. Qual a diferença entre um usuário comum trocar a própria senha com `passwd` e o `root` trocar a senha de outro usuário com o mesmo comando?
2. O que exatamente o `passwd -l` faz no arquivo `/etc/shadow`, e por que isso não é o mesmo que remover a conta?

---

## Exercício 4 — Criando grupos e gerenciando membros

1. Crie um novo grupo chamado `devops`:
   ```
   sudo groupadd devops
   ```
2. Verifique a criação do grupo:
   ```
   grep devops /etc/group
   ```
3. Adicione `estudante1` ao grupo `devops` como grupo secundário, preservando os grupos já existentes:
   ```
   sudo usermod -aG devops estudante1
   ```
4. Confirme a associação:
   ```
   id estudante1
   ```
5. Adicione `estudante2` ao mesmo grupo usando `gpasswd` como alternativa ao `usermod`:
   ```
   sudo gpasswd -a estudante2 devops
   ```
6. Liste todos os membros do grupo `devops`:
   ```
   grep devops /etc/group
   ```

**Perguntas:**
1. Por que é fundamental usar a opção `-a` junto com `-G` no comando `usermod` ao adicionar um usuário a um novo grupo?
2. Qual a diferença entre o grupo primário e um grupo secundário de um usuário?

---

## Exercício 5 — Alterando propriedades de um usuário com `usermod`

1. Altere o shell de login de `estudante1` para `/bin/sh`:
   ```
   sudo usermod -s /bin/sh estudante1
   ```
2. Confirme a alteração:
   ```
   grep estudante1 /etc/passwd
   ```
3. Altere o comentário (campo GECOS) do usuário:
   ```
   sudo usermod -c "Estudante de Teste 1" estudante1
   ```
4. Trave a conta para expirar em uma data futura (formato `AAAA-MM-DD`):
   ```
   sudo usermod -e 2026-12-31 estudante1
   ```
5. Verifique as informações de expiração:
   ```
   sudo chage -l estudante1
   ```

**Perguntas:**
1. Qual comando usado neste exercício permite consultar a política de expiração de senha e conta de um usuário?
2. Que cuidado se deve ter ao alterar o shell de login de um usuário para algo como `/usr/sbin/nologin`?

---

## Exercício 6 — Removendo usuários e grupos

1. Tente remover o grupo `devops` enquanto ele ainda tem membros:
   ```
   sudo groupdel devops
   ```
2. Remova `estudante2` do grupo `devops` antes de apagar o grupo:
   ```
   sudo gpasswd -d estudante2 devops
   ```
3. Remova `estudante1` do grupo `devops` também:
   ```
   sudo gpasswd -d estudante1 devops
   ```
4. Agora remova o grupo `devops` com sucesso:
   ```
   sudo groupdel devops
   ```
5. Remova o usuário `estudante2`, mantendo seu home directory:
   ```
   sudo userdel estudante2
   ```
6. Verifique que o home directory de `estudante2` ainda existe:
   ```
   ls -la /home/estudante2
   ```
7. Remova o usuário `estudante1`, apagando também seu home directory:
   ```
   sudo userdel -r estudante1
   ```
8. Confirme que ambos os home directories foram tratados corretamente:
   ```
   ls /home/
   ```

**Perguntas:**
1. Por que o `groupdel` recusa remover um grupo que ainda é grupo primário de algum usuário existente?
2. Qual a diferença de comportamento entre `userdel` e `userdel -r`?

---

<details>
<summary><strong>Respostas</strong></summary>

**Exercício 1**
1. O `x` indica que a senha criptografada real está armazenada em `/etc/shadow`, e não em `/etc/passwd`. Isso existe porque `/etc/passwd` precisa ser legível por todos os usuários (comandos como `ls -l` e `id` dependem disso para resolver UID → nome), enquanto o hash da senha deve ficar protegido.
2. `/etc/passwd` tem permissão de leitura para todos (`644`), pois muitos programas do sistema precisam consultá-lo para mapear UID/GID a nomes. Já `/etc/shadow` tem permissões restritas (geralmente `640` ou `600`, pertencente a `root`/`shadow`) porque contém os hashes de senha e informações sensíveis de expiração, exigindo privilégios elevados para leitura.

**Exercício 2**
1. `/etc/skel` é um diretório modelo (template) cujo conteúdo é copiado automaticamente para o home directory de todo novo usuário criado com a opção `-m`. Ele normalmente contém arquivos de configuração padrão do shell, como `.bashrc` e `.profile`.
2. A opção `-m` instrui o `useradd` a criar o home directory do usuário (copiando o conteúdo de `/etc/skel`). Se ela for omitida, a conta é criada normalmente em `/etc/passwd`, mas nenhum diretório home é criado — o que causaria problemas ao usuário tentar fazer login (sem `.bashrc`, sem diretório para gravar arquivos, etc.), a menos que o comportamento padrão do sistema (definido em `/etc/login.defs` ou `login.defs`/distros específicas) já habilite a criação automática.

**Exercício 3**
1. Quando um usuário comum executa `passwd`, o sistema exige a senha atual antes de aceitar a nova, como medida de segurança. Quando `root` executa `passwd <usuário>`, a senha é trocada diretamente, sem exigir a senha anterior, pois `root` já tem autoridade administrativa completa sobre o sistema.
2. `passwd -l` insere um caractere (geralmente `!` ou `!!`) no início do campo de hash da senha em `/etc/shadow`, invalidando a autenticação por senha sem apagar o hash original. Isso é reversível com `passwd -u`. É diferente de remover a conta porque o usuário, seu UID, GID, home directory e demais atributos continuam intactos — apenas o login por senha é bloqueado (outros métodos, como chave SSH, podem continuar funcionando).

**Exercício 4**
1. Sem `-a`, o `usermod -G` **substitui** toda a lista de grupos secundários do usuário pela lista fornecida. Usar `-aG` (append + Groups) garante que o novo grupo seja **adicionado** à lista existente, preservando as associações anteriores. Esquecer o `-a` é um erro comum que remove o usuário de todos os outros grupos secundários.
2. O grupo primário é aquele associado ao GID listado diretamente em `/etc/passwd` e é usado, por exemplo, como dono de grupo padrão para novos arquivos criados pelo usuário. Os grupos secundários (listados em `/etc/group`) concedem permissões adicionais, mas não são o grupo "dono" padrão dos arquivos do usuário.

**Exercício 5**
1. O comando `chage -l <usuário>` exibe a política de expiração de senha e de conta (data da última troca de senha, dias mínimos/máximos entre trocas, dias de aviso e data de expiração da conta).
2. Definir o shell como `/usr/sbin/nologin` (ou `/bin/false`) impede que o usuário obtenha um shell interativo de login, o que é apropriado para contas de serviço, mas inadequado para uma conta de usuário real que precisa fazer login interativamente — o usuário seria desconectado imediatamente após autenticar.

**Exercício 6**
1. Todo usuário precisa de um grupo primário válido referenciado pelo GID em `/etc/passwd`. Se o `groupdel` apagasse um grupo que ainda é primário de algum usuário, esse usuário ficaria com uma referência de GID órfã (inválida), quebrando a resolução de grupo do sistema. Por isso o comando recusa a remoção nesse caso.
2. `userdel` remove apenas a entrada da conta em `/etc/passwd`, `/etc/shadow` e `/etc/group` (associações), mas mantém o home directory e demais arquivos do usuário intactos no disco. `userdel -r` (remove) faz o mesmo, porém também apaga o home directory e o mail spool associado ao usuário.

</details>