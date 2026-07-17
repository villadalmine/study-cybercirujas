# Tópico 1.4 – ICT Skills and Working in Linux

## Introdução

Este tópico cobre habilidades gerais de **ICT** (*Information and Communication Technology*) que qualquer profissional precisa dominar antes de se aprofundar em comandos específicos do Linux: entender os componentes de hardware de um computador, saber onde os dados ficam armazenados, conectar-se a redes com e sem fio, fazer login em um sistema Linux (tanto via GUI quanto via linha de comando), usar aplicações básicas do dia a dia (browser, e-mail, editores de texto) e adotar práticas seguras de trabalho. É um tópico "de base": menos sobre comandos e mais sobre o contexto em que esses comandos serão usados.

## Hardware básico de um computador

Todo computador — seja um desktop, notebook, servidor ou Raspberry Pi rodando Linux — é composto pelas mesmas peças fundamentais:

- **CPU** (*Central Processing Unit*): executa as instruções. Medida em núcleos (*cores*) e frequência (GHz).
- **RAM** (*Random Access Memory*): memória volátil, usada para dados e programas em execução. É rápida, mas perde o conteúdo quando o equipamento é desligado.
- **Armazenamento** (*storage*): HDD (mecânico), SSD (estado sólido) ou NVMe (SSD conectado via PCIe). Não volátil — os dados permanecem após desligar.
- **Motherboard** (placa-mãe): conecta todos os componentes entre si.
- **Dispositivos de entrada/saída** (*I/O devices*): teclado, mouse, monitor, impressora, webcam.
- **Interfaces de rede**: placas Ethernet (com fio) e Wi-Fi (sem fio).

No Linux, é possível inspecionar esses componentes diretamente pela linha de comando:

```bash
$ lscpu | head -5
Architecture:            x86_64
CPU op-mode(s):          32-bit, 64-bit
Byte Order:               Little Endian
CPU(s):                   8

$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4.2Gi       6.1Gi       412Mi       5.3Gi        10Gi

$ lsblk
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda      8:0    0 476.9G  0 disk
├─sda1   8:1    0   512M  0 part /boot/efi
└─sda2   8:2    0 476.4G  0 part /
```

## Onde os dados ficam armazenados e como são usados

É importante distinguir **memória volátil** (RAM, usada enquanto o programa roda) de **armazenamento persistente** (disco, onde os dados sobrevivem a um *reboot*). No Linux, o sistema de arquivos organiza tudo em uma única árvore a partir da raiz `/`:

- `/home/usuario` — arquivos pessoais do usuário.
- `/etc` — arquivos de configuração do sistema.
- `/var` — dados variáveis, como logs (`/var/log`).
- `/tmp` — arquivos temporários, geralmente apagados a cada reboot.

Além do armazenamento local, dados também podem residir em **armazenamento em rede** (NAS, servidores de arquivos) ou na **nuvem** (*cloud storage*, como Nextcloud, Google Drive). O candidato deve entender essa distinção conceitual, mesmo sem entrar em detalhes de administração de sistemas — esse aprofundamento vem no Tópico 4 (*The Linux Operating System*).

## Conectando-se a uma rede (com fio ou sem fio)

Para acessar a internet ou uma rede local, o computador precisa de uma conexão física (Ethernet, cabo RJ-45) ou sem fio (Wi-Fi). Em distribuições Linux modernas, isso costuma ser gerenciado por um applet gráfico (NetworkManager) ou pela linha de comando:

```bash
# Ver interfaces de rede disponíveis
$ ip a
2: enp3s0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
3: wlp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...

# Listar redes Wi-Fi disponíveis
$ nmcli device wifi list

# Conectar a uma rede Wi-Fi
$ nmcli device wifi connect "MinhaRede" password "minhasenha"
```

Conceitos básicos que fazem parte deste objetivo: **SSID** (nome da rede Wi-Fi), **DHCP** (atribuição automática de endereço IP) versus **IP estático**, e a diferença entre rede **local (LAN)** e **internet (WAN)**.

## Firewalls: função básica

Um **firewall** filtra o tráfego de rede que entra e sai de um computador, permitindo ou bloqueando conexões com base em regras (porta, protocolo, origem/destino). É uma camada básica de segurança contra acessos não autorizados. No Linux, as implementações mais comuns são `iptables`/`nftables` (baixo nível) e ferramentas de gerenciamento como `ufw` (Ubuntu) ou `firewalld` (Fedora/RHEL):

```bash
# Ubuntu
$ sudo ufw status
Status: active
To                         Action      From
22/tcp                     ALLOW       Anywhere

# Fedora/RHEL
$ sudo firewall-cmd --state
running
$ sudo firewall-cmd --list-all
```

Para o exame, basta entender **o propósito** do firewall (proteger a máquina de conexões indesejadas) — não é necessário saber configurar regras complexas.

## Login no Linux: GUI e linha de comando, local e remoto

Um usuário pode acessar um sistema Linux de várias formas:

- **Login gráfico (GUI)**: via *display manager* (GDM, SDDM, LightDM), digitando usuário e senha em uma tela gráfica, escolhendo o *desktop environment* (GNOME, KDE Plasma, XFCE).
- **Login local em modo texto**: através de um **console virtual** (TTY), acessível geralmente com `Ctrl+Alt+F3` (por exemplo).
- **Login remoto**: usando **SSH** (*Secure Shell*), o método padrão para administrar servidores Linux remotamente:

```bash
$ ssh usuario@192.168.1.10
usuario@192.168.1.10's password:
Last login: Mon Jul 13 09:12:03 2026

$ whoami
usuario

$ who
usuario  tty1   2026-07-13 09:00
usuario  pts/0  2026-07-13 09:12 (192.168.1.5)
```

O comando `who` (ou `w`, que mostra também o que cada sessão está executando) permite ver quem está logado e de onde — útil para diferenciar sessões locais (`tty`) de remotas (`pts`, *pseudo-terminal*).

## Uso de aplicações básicas do dia a dia

Além da linha de comando, um usuário de Linux precisa se sentir confortável com ferramentas gráficas de uso comum:

- **Navegador web (browser)**: Firefox, Chromium. Conceitos importantes: *bookmarks*, histórico, downloads, indicadores de segurança (cadeado HTTPS), extensões/*add-ons*.
- **Gerenciador de arquivos gráfico (file manager)**: Nautilus (GNOME), Dolphin (KDE), Thunar (XFCE) — permitem navegar, copiar, mover e buscar arquivos sem usar o terminal.
- **Suíte de escritório**: LibreOffice (Writer, Calc, Impress) como alternativa livre ao Microsoft Office.
- **Cliente de e-mail**: Thunderbird ou webmail, com atenção a boas práticas (não abrir anexos suspeitos, verificar remetente).
- **Editores de texto**: desde editores gráficos simples (gedit, Kate) até editores de terminal (`nano`, `vim`), úteis para editar arquivos de configuração rapidamente:

```bash
$ nano ~/.bashrc
```

## Encontrando ajuda e documentação

Saber *onde procurar ajuda* é uma habilidade central em ICT. No Linux, as fontes mais comuns são:

```bash
# Manual completo de um comando
$ man ls

# Ajuda resumida embutida no próprio comando
$ ls --help

# Buscar comandos relacionados a uma palavra-chave
$ apropos partition
```

Além disso, documentação oficial das distribuições (Ubuntu Docs, Fedora Docs, Arch Wiki), fóruns de comunidade e a própria documentação do LPI são recursos legítimos para resolver dúvidas — sempre preferíveis a copiar comandos de fontes não confiáveis sem entender o que fazem.

## Boas práticas de segurança e de trabalho

Fazem parte deste objetivo noções básicas de segurança que qualquer profissional de TI deve internalizar:

- **Senhas fortes** e únicas por serviço; trocar senha padrão de um sistema recém-instalado com `passwd`.
- **Manter o sistema atualizado**, aplicando patches de segurança regularmente (`sudo apt update && sudo apt upgrade`, `sudo dnf upgrade`).
- **Backups regulares** dos dados importantes, seguindo a lógica de que "dado sem backup é dado que ainda não foi perdido, mas vai ser".
- **Atenção a phishing e engenharia social**: não clicar em links suspeitos, verificar remetentes de e-mail.
- **Privacidade**: entender permissões de arquivos e evitar compartilhar dados sensíveis desnecessariamente.

```bash
$ passwd
Changing password for usuario.
Current password:
New password:
Retype new password:
passwd: password updated successfully
```

## Resumo

| Habilidade | O que envolve |
|---|---|
| Hardware básico | CPU, RAM, storage, I/O devices |
| Armazenamento de dados | Volátil (RAM) vs. persistente (disco), local vs. rede/nuvem |
| Conectividade | Rede com fio (Ethernet) e sem fio (Wi-Fi), DHCP/IP |
| Firewall | Filtragem de tráfego de entrada/saída como camada de segurança |
| Login | GUI (display manager), TTY local, SSH remoto |
| Aplicações do dia a dia | Browser, file manager, suíte de escritório, e-mail, editores |
| Encontrar ajuda | `man`, `--help`, `apropos`, documentação oficial |
| Boas práticas | Senhas fortes, atualizações, backups, cuidado com phishing |

## Referências

- LPI Learning Materials — *Topic 1.4: ICT Skills and Working in Linux*: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/
- LPI — Linux Essentials (010-160) Exam Objectives: https://www.lpi.org/our-exams/010-160-details
- man7.org — `passwd(1)`: https://man7.org/linux/man-pages/man1/passwd.1.html
- ArchWiki — *firewalld*: https://wiki.archlinux.org/title/Firewalld
- ArchWiki — *NetworkManager*: https://wiki.archlinux.org/title/NetworkManager