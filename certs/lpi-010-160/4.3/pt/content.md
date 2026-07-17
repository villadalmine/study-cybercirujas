# 4.3 Where Data is Stored

## Introdução

No Linux, quase tudo é representado como um arquivo dentro de uma única árvore de diretórios que começa na raiz (`/`). Diferente do Windows, não existem letras de unidade (`C:`, `D:`) — discos, partições, dispositivos e até informações do kernel são "montados" (mounted) em pontos específicos dessa árvore. Saber onde cada tipo de dado é armazenado é essencial tanto para administrar o sistema quanto para o exame, já que esse conhecimento é formalizado pelo **Filesystem Hierarchy Standard (FHS)**, mantido pela Linux Foundation.

## A Filesystem Hierarchy Standard (FHS)

O FHS define a função de cada diretório de primeiro nível abaixo de `/`, garantindo que qualquer distribuição Linux organize os dados de forma previsível. Isso permite que scripts, pacotes e administradores saibam, por convenção, onde procurar binários, configurações, dados variáveis ou arquivos temporários.

```bash
$ ls -l /
drwxr-xr-x   2 root root  4096 bin
drwxr-xr-x   3 root root  4096 boot
drwxr-xr-x  20 root root  4020 dev
drwxr-xr-x 150 root root 12288 etc
drwxr-xr-x   4 root root  4096 home
drwxr-xr-x   9 root root  4096 media
drwxr-xr-x   2 root root  4096 mnt
drwxr-xr-x   3 root root  4096 opt
dr-xr-xr-x 250 root root     0 proc
drwx------  10 root root  4096 root
drwxr-xr-x  30 root root   960 run
drwxr-xr-x   2 root root 12288 sbin
dr-xr-xr-x  13 root root     0 sys
drwxrwxrwt  15 root root  4096 tmp
drwxr-xr-x  10 root root  4096 usr
drwxr-xr-x  11 root root  4096 var
```

### Tabela dos principais diretórios

| Diretório | Conteúdo típico |
|---|---|
| `/bin`, `/sbin` | Binários essenciais para uso geral e administração (em distros modernas, geralmente symlinks para `/usr/bin`, `/usr/sbin`) |
| `/boot` | Kernel, initramfs e arquivos do bootloader (ex: `vmlinuz`, `initrd.img`, `grub/`) |
| `/dev` | Arquivos de dispositivo (device files), como `/dev/sda`, `/dev/null`, `/dev/tty` |
| `/etc` | Arquivos de configuração do sistema, sempre que possível em texto plano |
| `/home` | Diretórios pessoais (home directories) dos usuários comuns |
| `/media` | Ponto de montagem automático para mídias removíveis (pendrives, CDs) |
| `/mnt` | Ponto de montagem temporário, usado manualmente pelo administrador |
| `/opt` | Software de terceiros instalado fora do gerenciador de pacotes da distro |
| `/proc` | Sistema de arquivos virtual com informações do kernel e dos processos em execução |
| `/root` | Diretório pessoal do usuário `root` |
| `/tmp` | Arquivos temporários, normalmente limpos a cada reinicialização |
| `/usr` | Programas, bibliotecas e documentação compartilhados entre usuários |
| `/var` | Dados que mudam com frequência: logs, filas de e-mail, caches, bancos de dados |

## Diretórios em detalhe

### `/etc` — configuração do sistema

Contém as configurações globais que afetam todos os usuários da máquina: rede, serviços, gerenciamento de usuários, etc. Praticamente tudo aqui é texto plano, editável com qualquer editor.

```bash
$ ls /etc/passwd /etc/group /etc/hostname /etc/fstab
/etc/fstab  /etc/group  /etc/hostname  /etc/passwd
```

### `/var` — dados variáveis

Guarda dados que crescem e mudam durante a operação do sistema, como logs (`/var/log`), spool de impressão (`/var/spool`) e caches de pacotes (`/var/cache`).

```bash
$ ls /var/log | head -5
auth.log
dpkg.log
kern.log
syslog
wtmp
```

### `/home` e `~/` — dados do usuário

Cada usuário comum tem seu próprio diretório dentro de `/home`, referenciado pelo atalho `~`. É lá que ficam os "dotfiles" (arquivos ocultos, iniciados por `.`) com as configurações pessoais de cada aplicativo, em contraste com as configurações globais de `/etc`.

```bash
$ echo $HOME
/home/aluno

$ ls -a ~ | head -6
.
..
.bashrc
.config
.ssh
Documentos
```

O usuário `root`, por convenção, não usa `/home/root`, mas sim `/root`, mantido separado para que o sistema continue acessível mesmo se `/home` estiver em outra partição e não puder ser montada.

### `/usr` — programas e dados compartilhados

Guarda a maior parte dos programas instalados e seus dados de suporte (`/usr/bin`, `/usr/lib`, `/usr/share`). É considerado compartilhável entre múltiplas máquinas e, em teoria, pode ser montado como somente leitura.

### `/opt` — software opcional de terceiros

Usado por aplicativos que não seguem o empacotamento padrão da distribuição, geralmente instalando tudo em um único subdiretório próprio, por exemplo `/opt/google/chrome/`.

### `/boot` — arquivos de inicialização

Contém tudo que é necessário para o boot: a imagem do kernel, o initramfs e a configuração do bootloader (GRUB, por exemplo). Em muitos setups é uma partição separada, pequena, montada em `/boot`.

```bash
$ ls /boot
grub  initrd.img-6.1.0  vmlinuz-6.1.0
```

### `/dev` — arquivos de dispositivo

Cada dispositivo de hardware é representado como um arquivo especial. Discos aparecem como `/dev/sda`, `/dev/nvme0n1`, etc., e suas partições recebem um número (`/dev/sda1`, `/dev/sda2`).

```bash
$ ls /dev/sd*
/dev/sda  /dev/sda1  /dev/sda2
```

### `/proc` e `/sys` — sistemas de arquivos virtuais

Não armazenam dados em disco: são gerados dinamicamente pelo kernel em memória e expõem informações sobre processos e hardware. `/proc/<PID>/` existe para cada processo em execução.

```bash
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i5-10210U CPU

$ cat /proc/meminfo | head -2
MemTotal:       16336700 kB
MemFree:         2107344 kB
```

### `/tmp` — arquivos temporários

Área de escrita compartilhada por todos os usuários, geralmente esvaziada a cada boot ou por uma tarefa agendada (`systemd-tmpfiles`).

### `/media` e `/mnt` — pontos de montagem

Ambos são pontos de montagem (mount points), ou seja, diretórios vazios onde um sistema de arquivos externo é "anexado" à árvore principal. `/media` é usado por gerenciadores de desktop para montagem automática de mídias removíveis; `/mnt` é reservado para montagens manuais e temporárias feitas pelo administrador.

```bash
$ sudo mount /dev/sdb1 /mnt
$ df -h /mnt
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1        29G  1.2G   26G   5% /mnt

$ sudo umount /mnt
```

## Arquivos-chave de usuários e grupos

Diferente de senhas ou dados variáveis, as informações de contas de usuário ficam em arquivos de texto simples dentro de `/etc`.

### `/etc/passwd`

Lista todos os usuários do sistema, um por linha, com sete campos separados por `:`.

```bash
$ grep aluno /etc/passwd
aluno:x:1000:1000:Aluno LPI:/home/aluno:/bin/bash
```

Campos, na ordem: `username:senha(x):UID:GID:comentário(GECOS):home directory:shell`. O `x` no campo de senha indica que o hash real está guardado em `/etc/shadow`, arquivo legível apenas por `root`.

### `/etc/group`

Lista os grupos do sistema e seus membros adicionais.

```bash
$ grep sudo /etc/group
sudo:x:27:aluno
```

Campos: `nome_do_grupo:senha(x):GID:lista_de_membros`.

## Configurações de usuário vs. configurações globais

Um padrão recorrente no Linux é a existência de dois níveis de configuração para o mesmo programa:

- **Global (system-wide)**: em `/etc`, aplica-se a todos os usuários por padrão. Exemplo: `/etc/vim/vimrc`.
- **Por usuário (user-specific)**: em `~/`, sobrepõe a configuração global apenas para aquele usuário. Exemplo: `~/.vimrc`.

```bash
$ ls -la /etc/vim/vimrc ~/.vimrc
-rw-r--r-- 1 root  root   2837 /etc/vim/vimrc
-rw-r--r-- 1 aluno aluno  120 /home/aluno/.vimrc
```

## Referências

- LPI Learning Materials — 4.3 Where Data is Stored: https://learning.lpi.org/en/learning-materials/010-160/4/4.3/
- Filesystem Hierarchy Standard (FHS 3.0), Linux Foundation: https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html
- `man hier` (documentação local sobre a hierarquia de diretórios)
- `man 5 passwd`, `man 5 group`