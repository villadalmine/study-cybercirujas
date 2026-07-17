# 5.2 Creating Users and Groups

## Introdução

No Linux, cada processo e cada arquivo pertence a um *user* e a um *group*. Antes de qualquer pessoa poder fazer login no sistema, é preciso que exista uma *user account* para ela — e, geralmente, também um *group* associado. Este tópico cobre os comandos que um administrador usa para criar, modificar e remover contas de usuário e grupos, além dos arquivos do sistema onde essas informações ficam armazenadas.

## Os arquivos que armazenam users e groups

Antes de usar os comandos, vale entender onde a informação é guardada:

- **`/etc/passwd`** — uma linha por *user*, com sete campos separados por `:`:
  ```
  jsilva:x:1001:1001:Joana Silva:/home/jsilva:/bin/bash
  ```
  `username:password-placeholder:UID:GID:comentário (GECOS):home directory:login shell`

  O campo de senha aqui é sempre `x`, indicando que a senha real está em `/etc/shadow`.

- **`/etc/shadow`** — guarda o *hash* da senha e informações de expiração, legível apenas por `root`:
  ```
  jsilva:$6$abcxyz...:19500:0:99999:7:::
  ```

- **`/etc/group`** — uma linha por *group*:
  ```
  devteam:x:1050:jsilva,mmarques
  ```
  `group-name:password-placeholder:GID:lista de membros suplementares`

- **`/etc/gshadow`** — versão "shadow" do arquivo de groups (senhas de group e administradores).

- **`/etc/skel/`** — diretório modelo cujo conteúdo é copiado para o `home directory` de todo novo user criado com `useradd -m`. É aqui que se colocam arquivos padrão como `.bashrc` ou `.profile` que todo novo usuário deve receber.

## UID e GID

Todo user tem um **UID** (*User ID*) e todo group tem um **GID** (*Group ID*), ambos números inteiros:

- `UID 0` é sempre o `root`.
- Em distribuições baseadas em Red Hat, UIDs de 1 a 999 costumam ser reservados para *system accounts* (serviços), e os usuários "normais" começam em 1000.
- Em distribuições baseadas em Debian, o corte tradicional é 1 a 999 para sistema, 1000+ para usuários normais (o valor exato vem de `/etc/login.defs`, variáveis `UID_MIN` e `UID_MAX`).
- O **primary group** de um user (definido no 4º campo de `/etc/passwd`) é o group usado por padrão para novos arquivos que ele criar. Além dele, um user pode pertencer a vários **supplementary groups** (listados em `/etc/group`).

## Criando groups: `groupadd`

```
# groupadd devteam
```

Isso cria o group `devteam` com o próximo GID disponível. Para especificar um GID:

```
# groupadd -g 2000 devteam
```

## Criando users: `useradd`

Comando básico (comportamento varia bastante entre distribuições — em Debian/Ubuntu, `useradd` sem opções costuma **não** criar `home directory` nem definir shell):

```
# useradd -m -d /home/jsilva -s /bin/bash -c "Joana Silva" -g devteam -G sudo jsilva
```

Principais opções:

| Opção | Significado |
|---|---|
| `-m` | cria o `home directory`, copiando o conteúdo de `/etc/skel` |
| `-d <dir>` | define o `home directory` (padrão: `/home/<username>`) |
| `-s <shell>` | define o *login shell* (ex.: `/bin/bash`, `/usr/sbin/nologin`) |
| `-c "<texto>"` | comentário (campo GECOS, normalmente o nome completo) |
| `-g <group>` | define o *primary group* |
| `-G <g1,g2>` | define *supplementary groups*, separados por vírgula |
| `-u <uid>` | define o UID manualmente |
| `-r` ou `-s` (system) | cria uma *system account* (UID abaixo do limite normal, sem `home` por padrão) |

Depois de criar o user, é preciso definir a senha:

```
# passwd jsilva
Nova senha:
Redigite a nova senha:
passwd: senha atualizada com sucesso
```

Em sistemas Debian/Ubuntu existe também o comando `adduser`, um *wrapper* interativo em Perl sobre `useradd` que já pergunta nome completo, senha etc. e cria o `home` automaticamente — é mais amigável, mas não existe (ou tem outro comportamento) em distribuições baseadas em Red Hat.

## Modificando users: `usermod`

```
# usermod -aG devteam mmarques
```

Adiciona `mmarques` ao group `devteam` **sem removê-lo** dos demais supplementary groups. A opção `-a` (*append*) é essencial aqui: usar `-G` sozinho **substitui** a lista inteira de supplementary groups.

Outros usos comuns:

```
# usermod -s /usr/sbin/nologin jsilva     # troca o login shell
# usermod -l novonome nomeantigo          # renomeia o login
# usermod -L jsilva                        # bloqueia (lock) a conta
# usermod -U jsilva                        # desbloqueia (unlock) a conta
```

`usermod -L` funciona colocando um `!` na frente do hash em `/etc/shadow`, impedindo o login por senha (mas não bloqueia, por exemplo, login por chave SSH).

## Removendo users: `userdel`

```
# userdel jsilva          # remove o user, mantém o home directory
# userdel -r jsilva        # remove o user E o home directory + mail spool
```

## Modificando e removendo groups

```
# groupmod -n devs devteam     # renomeia o group
# groupdel devs                 # remove o group (falha se ainda for primary group de algum user)
```

## Gerenciando membros de groups: `gpasswd`

```
# gpasswd -a jsilva devteam     # adiciona jsilva ao group devteam
# gpasswd -d jsilva devteam     # remove jsilva do group devteam
```

## Consultando informações

```
$ id jsilva
uid=1001(jsilva) gid=1050(devteam) groups=1050(devteam),27(sudo)

$ groups jsilva
jsilva : devteam sudo

$ whoami
jsilva
```

`id` mostra UID, GID do *primary group* e todos os *supplementary groups* de uma vez — é o comando mais rápido para conferir a que groups um user pertence.

## Expiração de senha: `chage`

```
# chage -l jsilva
Última alteração de senha                       : jul 10, 2026
A senha expira                                   : nunca
...

# chage -M 90 jsilva      # senha expira a cada 90 dias
# chage -E 2026-12-31 jsilva   # conta expira em data fixa
```

## Alterando dados pessoais: `chfn` e `chsh`

```
$ chfn jsilva     # altera o campo GECOS (nome completo, telefone etc.)
$ chsh -s /bin/zsh jsilva   # altera o login shell (equivalente a usermod -s)
```

## Boas práticas / pontos de atenção comuns em prova

- Sempre confira se um novo user precisa ou não de `home directory` (`-m`) e de shell interativo — uma *system account* de serviço geralmente usa `-s /usr/sbin/nologin` e não deve ter shell de login.
- `usermod -G` sem `-a` **apaga** os supplementary groups anteriores — erro clássico.
- `userdel` sem `-r` deixa o `home directory` órfão no disco.
- `groupdel` falha se o group ainda é o *primary group* de algum user existente; é preciso trocar o primary group desses users antes.
- As alterações feitas por esses comandos afetam diretamente `/etc/passwd`, `/etc/shadow`, `/etc/group` e `/etc/gshadow` — em teoria, editá-los manualmente com um editor de texto também funciona, mas o comando recomendado para isso é `vipw` (para `passwd`/`shadow`) ou `vigr` (para `group`/`gshadow`), pois eles aplicam *file locking* e evitam corromper o arquivo.

## Referências

- LPI Learning Materials — 010-160, Topic 5.2 "Creating Users and Groups": https://learning.lpi.org/en/learning-materials/010-160/5/5.2/
- man page de `useradd`: https://man7.org/linux/man-pages/man8/useradd.8.html
- man page de `usermod`: https://man7.org/linux/man-pages/man8/usermod.8.html
- man page de `userdel`: https://man7.org/linux/man-pages/man8/userdel.8.html
- man page de `groupadd`: https://man7.org/linux/man-pages/man8/groupadd.8.html
- man page de `passwd` (formato do arquivo): https://man7.org/linux/man-pages/man5/passwd.5.html
- man page de `shadow` (formato do arquivo): https://man7.org/linux/man-pages/man5/shadow.5.html
- man page de `chage`: https://man7.org/linux/man-pages/man1/chage.1.html