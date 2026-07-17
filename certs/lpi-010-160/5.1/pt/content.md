# 5.1 Basic Security and Identifying User Types

## Introdução

Linux é um sistema operacional multiusuário (multi-user) desde sua concepção: vários usuários podem usar a mesma máquina, simultaneamente ou não, cada um com seu próprio espaço de trabalho, arquivos e permissões. A segurança básica do sistema começa justamente aí — em como o Linux identifica *quem* está executando cada ação e *o que* essa pessoa (ou processo) tem permissão de fazer.

Este tópico cobre os conceitos fundamentais de identidade e privilégio no Linux: os tipos de usuários que existem, como o sistema os identifica internamente, e as ferramentas básicas para alternar entre identidades de forma segura (`su`, `sudo`).

## O modelo de privilégios do Linux

Todo processo em execução no Linux roda "como" um usuário específico, e esse usuário determina a quais arquivos, dispositivos e recursos o processo pode acessar. Esse é o mecanismo central de segurança do sistema: em vez de confiar em cada programa individualmente, o kernel confia na identidade (identity) sob a qual o programa foi iniciado.

Existem três grandes categorias de usuários no Linux:

### 1. Superuser (root)

O usuário `root`, também chamado de **superuser**, é a conta administrativa do sistema. Ele tem UID (User ID) `0` e não está sujeito às restrições normais de permissão: pode ler, escrever e executar qualquer arquivo, criar e remover usuários, instalar software, configurar a rede, etc.

Justamente por esse poder, usar `root` diretamente no dia a dia é considerado uma má prática de segurança (security best practice violation). Um erro de digitação em um comando como `rm -rf` executado como root pode destruir o sistema inteiro, sem nenhuma barreira de permissão para impedir. Por isso, a convenção moderna é usar contas regulares combinadas com `sudo` para elevar privilégios apenas quando necessário — princípio conhecido como **least privilege** (privilégio mínimo).

### 2. Regular users (usuários regulares)

São as contas criadas para pessoas reais usarem o sistema — para trabalhar, navegar, programar, etc. Cada regular user tem:

- um **home directory** próprio (geralmente `/home/nome_do_usuario`);
- um UID normalmente a partir de `1000` (esse valor pode variar por distribuição — algumas usam `500` como ponto de corte);
- permissões restritas ao seu próprio espaço, salvo quando lhe é concedido acesso adicional.

### 3. System users (usuários de sistema)

São contas criadas automaticamente por serviços e daemons — não representam pessoas, mas processos do sistema. Exemplos comuns: `www-data` (servidor web), `mail`, `sshd`, `mysql`, `nobody`. Eles existem para que cada serviço rode com sua própria identidade, isolada das demais — se um serviço for comprometido, o atacante herda apenas os privilégios daquela conta de sistema, não os de todo o sistema.

System users normalmente:

- não têm senha utilizável para login interativo (o shell costuma ser `/usr/sbin/nologin` ou `/bin/false`);
- têm UID em uma faixa reservada, tipicamente abaixo de `1000` (varia por distribuição: Debian/Ubuntu usam algo como `1`–`999`, outras usam até `500`).

## Identificando usuários: `/etc/passwd`

Todo usuário local do sistema está registrado no arquivo `/etc/passwd`. Cada linha descreve uma conta, com campos separados por dois-pontos:

```
$ cat /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
ana:x:1000:1000:Ana Souza,,,:/home/ana:/bin/bash
```

Os campos, na ordem, são:

| Campo | Significado |
|---|---|
| `username` | nome de login (ex.: `ana`) |
| `password` | placeholder (`x` indica que a senha real está em `/etc/shadow`) |
| `UID` | User ID numérico |
| `GID` | Group ID do grupo primário do usuário |
| `GECOS` | campo de informação (nome completo, contato, etc.) |
| `home directory` | diretório pessoal do usuário |
| `shell` | shell padrão iniciado no login |

Note como `root` sempre tem UID `0`, `daemon` e `www-data` estão na faixa de system users, e `ana` — um regular user — começa em `1000`.

As senhas reais (criptografadas/hashed) ficam em `/etc/shadow`, legível apenas por `root`, justamente para impedir que qualquer usuário tente quebrar hashes de senha alheias.

## Comandos para identificar usuários e sessões

```
$ whoami
ana

$ id
uid=1000(ana) gid=1000(ana) groups=1000(ana),27(sudo),999(docker)

$ id www-data
uid=33(www-data) gid=33(www-data) groups=33(www-data)

$ who
ana      tty2         2026-07-12 09:14
ana      pts/0        2026-07-12 09:20 (192.168.1.20)

$ w
 09:41:02 up  2:15,  2 users,  load average: 0.12, 0.08, 0.05
USER     TTY      FROM             LOGIN@   IDLE   WHAT
ana      tty2     -                09:14    2:15   -bash
ana      pts/0    192.168.1.20     09:20    0.00s  w
```

- `whoami` mostra apenas o nome do usuário atual.
- `id` mostra UID, GID e todos os grupos (groups) aos quais o usuário pertence — útil para saber se ele tem acesso a `sudo`, `docker`, etc.
- `who` e `w` mostram quem está logado no sistema, de onde e há quanto tempo (relevante para auditoria de segurança básica).

## Alternando de identidade: `su` vs `sudo`

### `su` (switch user)

Troca completamente para outro usuário, pedindo a **senha do usuário de destino**:

```
$ su -
Password:
# whoami
root
```

O `-` (equivalente a `su -l`) simula um login completo, carregando as variáveis de ambiente do usuário de destino. Sem o `-`, o ambiente atual é mantido, o que pode causar comportamento inesperado (por exemplo, `$PATH` do usuário anterior).

### `sudo` (superuser do)

Executa **um único comando** com privilégios elevados, pedindo a **senha do próprio usuário** (não a de root), desde que ele esteja autorizado no arquivo `/etc/sudoers`:

```
$ sudo apt update
[sudo] password for ana:
...

$ sudo -l
User ana may run the following commands on this host:
    (ALL : ALL) ALL

$ sudo -u www-data whoami
www-data
```

`sudo` é considerado mais seguro que `su` por dois motivos práticos:

1. **Rastreabilidade (accountability)**: cada comando executado com `sudo` fica registrado em log (geralmente `/var/log/auth.log` ou `/var/log/secure`), associado ao usuário real que o executou — não apenas "root fez algo".
2. **Privilégio mínimo**: é possível autorizar um usuário a rodar apenas comandos específicos como root (configurado em `/etc/sudoers`, editado com `visudo`), em vez de dar acesso irrestrito à conta root inteira.

## Boas práticas básicas de segurança

- **Evitar login direto como root**: usar uma conta regular + `sudo` para tarefas administrativas.
- **Senhas fortes e únicas**: alteradas com `passwd`, seguindo políticas mínimas de complexidade.
  ```
  $ passwd
  Changing password for ana.
  Current password:
  New password:
  Retype new password:
  passwd: password updated successfully
  ```
- **Restringir acesso remoto de root**: em servidores com SSH, desabilitar login direto de root (`PermitRootLogin no` em `/etc/ssh/sshd_config`), forçando o uso de contas nomeadas + `sudo`.
- **Revisar contas de sistema**: system users não devem ter shell interativo nem senha válida, reduzindo a superfície de ataque caso sejam comprometidas.
- **Auditar sessões e logs**: usar `who`, `w`, `last` e os logs de autenticação para identificar acessos inesperados.

## Referências

- LPI Learning Materials — 5.1 Basic Security and Identifying User Types: https://learning.lpi.org/en/learning-materials/010-160/5/5.1/
- `passwd(5)` man page: https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` man page: https://man7.org/linux/man-pages/man5/shadow.5.html
- `sudo(8)` man page: https://man7.org/linux/man-pages/man8/sudo.8.html
- `su(1)` man page: https://man7.org/linux/man-pages/man1/su.1.html
- `sudoers(5)` man page: https://man7.org/linux/man-pages/man5/sudoers.5.html