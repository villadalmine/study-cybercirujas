# 1.1 Linux Evolution and Popular Operating Systems

**Peso no exame: 2** — Objetivo: conhecer a história do Linux, as principais *distributions* e os sistemas operacionais mais populares, entendendo onde o Linux se encaixa no ecossistema (desktop, servidor, *cloud*, dispositivos móveis e *embedded systems*).

---

## 1. Um pouco de história: do UNIX ao Linux

Para entender o Linux, é preciso voltar ao **UNIX**, criado no final dos anos 1960 na Bell Labs (AT&T) por Ken Thompson e Dennis Ritchie. O UNIX introduziu conceitos que sobrevivem até hoje: sistema multiusuário, multitarefa, tudo tratado como arquivo e uma filosofia de pequenas ferramentas que fazem uma coisa bem feita.

Nos anos 1980, **Richard Stallman** fundou o **GNU Project** (*GNU's Not Unix*) e a **Free Software Foundation (FSF)**, com o objetivo de criar um sistema operacional completamente livre. O projeto GNU produziu componentes essenciais — o compilador **GCC**, o shell **Bash**, as *coreutils* — mas faltava a peça central: o **kernel**.

Essa peça chegou em **1991**, quando **Linus Torvalds**, então estudante na Finlândia, anunciou um kernel que escreveu como hobby, inspirado no MINIX. Combinado com as ferramentas GNU, nasceu o sistema que conhecemos como **Linux** (por isso algumas pessoas preferem o nome *GNU/Linux*).

Dois fatores foram decisivos para o sucesso:

- **Licença GPL (GNU General Public License):** qualquer pessoa pode usar, estudar, modificar e redistribuir o código, desde que as modificações permaneçam sob a mesma licença (*copyleft*).
- **Desenvolvimento colaborativo pela Internet:** milhares de desenvolvedores no mundo todo contribuem com o kernel, hoje hospedado em [kernel.org](https://www.kernel.org).

> **Ponto de prova:** Linux, estritamente falando, é **apenas o kernel**. O que instalamos no computador é uma *distribution* (kernel + ferramentas GNU + software adicional + instalador + gerenciador de pacotes).

## 2. O que é uma *distribution*?

Uma **Linux distribution** (ou *distro*) empacota o kernel com tudo o que é necessário para um sistema utilizável: bibliotecas, utilitários, ambiente gráfico (*desktop environment*), *package manager* e políticas de atualização. As distros costumam se organizar em **famílias**:

| Família | Distros principais | *Package manager* | Uso típico |
|---|---|---|---|
| **Debian** | Debian, **Ubuntu**, Linux Mint, Raspberry Pi OS | `apt` / `dpkg` (pacotes `.deb`) | Desktop, servidor, educação |
| **Red Hat** | **RHEL**, Fedora, CentOS Stream, Rocky Linux, AlmaLinux | `dnf` / `rpm` (pacotes `.rpm`) | Empresas, servidores |
| **SUSE** | SUSE Linux Enterprise, openSUSE | `zypper` / `rpm` | Empresas (forte na Europa) |
| **Independentes** | Arch Linux, Gentoo, Slackware | `pacman`, `portage`, etc. | Usuários avançados |

Alguns modelos de lançamento que vale conhecer:

- ***Fixed release* / LTS (Long Term Support):** versões com data e suporte prolongado. Ex.: Ubuntu LTS (5 anos de suporte), RHEL (10 anos).
- ***Rolling release*:** atualização contínua, sem "versões". Ex.: Arch Linux, openSUSE Tumbleweed.
- **Distros comunitárias vs. empresariais:** Fedora é a base comunitária que alimenta o RHEL (comercial, com suporte pago); Rocky Linux e AlmaLinux surgiram como recompilações gratuitas compatíveis com o RHEL.

### Identificando a distro e o kernel na prática

O arquivo `/etc/os-release` identifica a distribuição:

```bash
$ cat /etc/os-release
NAME="Ubuntu"
VERSION="24.04.2 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04.2 LTS"
VERSION_ID="24.04"
```

O comando `uname` mostra informações do kernel:

```bash
$ uname -a
Linux servidor01 6.8.0-57-generic #59-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux

$ uname -r
6.8.0-57-generic
```

Repare no formato da versão do kernel (`6.8.0`): *major.minor.patch* — informação que pode aparecer no exame.

## 3. Onde o Linux está presente

O Linux domina praticamente todos os segmentos da computação, exceto o desktop tradicional:

- **Servidores e *cloud computing*:** a grande maioria dos servidores web e das instâncias em AWS, Google Cloud e Azure roda Linux. Tecnologias de **containers** como Docker e **Kubernetes** são construídas sobre recursos do kernel Linux.
- **Supercomputadores:** 100% do TOP500 (lista dos supercomputadores mais rápidos do mundo) roda Linux.
- **Android:** o sistema móvel do Google usa o **kernel Linux**, embora o restante da pilha (bibliotecas, interface) seja diferente de uma distro tradicional.
- ***Embedded systems* e IoT:** roteadores (OpenWrt), Smart TVs, carros, câmeras e o **Raspberry Pi** (com Raspberry Pi OS, baseado em Debian).
- **Desktop:** minoritário, mas presente com Ubuntu, Mint, Fedora e ambientes gráficos como **GNOME** e **KDE Plasma**. O ChromeOS, dos Chromebooks, também é baseado em Linux.

## 4. Outros sistemas operacionais populares

O exame espera que você saiba situar o Linux frente às alternativas:

### Microsoft Windows
Sistema **proprietário**, dominante no desktop corporativo e doméstico. Diferenças práticas em relação ao Linux: usa letras de unidade (`C:\`) em vez de uma árvore única de diretórios, separador de caminho `\` em vez de `/`, e ciclo de atualização controlado pela Microsoft. Curiosamente, o Windows moderno inclui o **WSL (Windows Subsystem for Linux)**, que permite rodar distros Linux dentro do Windows.

### Apple macOS
Sistema proprietário da Apple, mas com base **UNIX certificada** (derivado do BSD via Darwin). Por isso, o Terminal do macOS é bastante parecido com o do Linux — comandos como `ls`, `grep` e `ssh` funcionam de forma quase idêntica. O **iOS** compartilha essa mesma base.

### Família BSD
**FreeBSD**, **OpenBSD** e **NetBSD** são descendentes diretos do UNIX de Berkeley, com código aberto sob a **licença BSD** — mais permissiva que a GPL, pois permite reutilização em software proprietário (a Apple e a Sony, no PlayStation, fizeram exatamente isso). Diferença estrutural: nos BSDs, kernel e *userland* são desenvolvidos juntos como um sistema único, enquanto uma distro Linux monta peças de origens diversas.

### UNIX comerciais
Ainda existem em nichos: **IBM AIX**, **Oracle Solaris** e **HP-UX**, geralmente atrelados a hardware específico e em declínio frente ao Linux.

### Comparação rápida

| Sistema | Licença | Kernel | Nicho principal |
|---|---|---|---|
| Linux | GPL (open source) | Linux | Servidores, cloud, embedded, Android |
| Windows | Proprietária | NT | Desktop corporativo/doméstico |
| macOS | Proprietária (base BSD) | XNU/Darwin | Desktop criativo, desenvolvimento |
| FreeBSD | BSD (open source) | FreeBSD | Servidores, appliances de rede |

## 5. Escolhendo um sistema: ciclo de vida e suporte

Um administrador precisa considerar:

- ***Support lifecycle*:** por quanto tempo a versão recebe correções de segurança? Uma Ubuntu LTS recebe 5 anos; uma versão intermediária, apenas 9 meses.
- **Estabilidade vs. novidade:** Debian Stable e RHEL priorizam estabilidade; Fedora e Arch entregam software mais recente.
- **Custo e suporte comercial:** o software pode ser gratuito, mas empresas frequentemente pagam por suporte (Red Hat, SUSE, Canonical/Ubuntu).
- **Compatibilidade de hardware e de aplicações:** motivo pelo qual o Windows ainda domina o desktop corporativo.

---

## Pontos-chave para o exame

1. **Linus Torvalds** criou o kernel Linux em **1991**; o **GNU Project** (Richard Stallman, anos 1980) forneceu as ferramentas do sistema.
2. Linux = **kernel**; o sistema completo que você instala é uma **distribution**.
3. Famílias de distros: **Debian** (Ubuntu, Mint, Raspberry Pi OS) e **Red Hat** (Fedora, RHEL, Rocky, Alma) são as mais cobradas.
4. **Android** usa o kernel Linux; **macOS** e **iOS** têm base UNIX/BSD; os **BSDs** são open source com licença mais permissiva que a GPL.
5. Comandos úteis: `uname -a` / `uname -r` (kernel) e `cat /etc/os-release` (distro).
6. Diferencie **fixed release / LTS** de **rolling release** e entenda o conceito de *support lifecycle*.

## Referências

- LPI Learning Materials — Lesson 1.1, Linux Evolution and Popular Operating Systems: <https://learning.lpi.org/en/learning-materials/010-160/1/1.1/>
- The Linux Kernel Archives: <https://www.kernel.org>
- GNU Project / Free Software Foundation: <https://www.gnu.org>
- GNU General Public License (GPL): <https://www.gnu.org/licenses/gpl-3.0.html>
- Debian: <https://www.debian.org> · Ubuntu: <https://ubuntu.com> · Fedora: <https://fedoraproject.org>
- FreeBSD: <https://www.freebsd.org>
- Raspberry Pi OS: <https://www.raspberrypi.com/software/>