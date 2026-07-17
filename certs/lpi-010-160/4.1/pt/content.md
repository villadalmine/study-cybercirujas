# 4.1 Choosing an Operating System

## O que é Open Source

**Open Source** (código aberto) é um modelo de desenvolvimento e distribuição de software no qual o código-fonte é disponibilizado publicamente, permitindo que qualquer pessoa possa estudá-lo, modificá-lo e redistribuí-lo. Isso se opõe ao modelo **proprietário** (ou *closed source*), em que apenas o fabricante tem acesso ao código-fonte e o usuário recebe apenas o binário compilado, sob uma licença restritiva.

É importante não confundir "gratuito" com "open source". O termo em inglês *free* é ambíguo (pode significar "livre" ou "grátis"), por isso a comunidade costuma usar a expressão **"free as in freedom, not as in free beer"** — livre como em liberdade, não como em cerveja grátis. Um software pode ser:

- **Open Source e gratuito**: a maioria das distribuições Linux, LibreOffice, Firefox.
- **Open Source e pago**: algumas empresas cobram por suporte, integração ou uma versão empacotada do código aberto (ex.: Red Hat Enterprise Linux).
- **Proprietário e gratuito** (*freeware*): o código não é aberto, mas o uso não tem custo (ex.: Adobe Acrobat Reader).
- **Proprietário e pago**: modelo comercial tradicional (ex.: Microsoft Office).

Outras categorias de licenciamento relevantes para o exame:

- **Trialware/Shareware**: software proprietário distribuído gratuitamente por um período limitado ou com funcionalidades reduzidas, para avaliação antes da compra.
- **Public Domain**: software sem restrições de copyright, pode ser usado, modificado e redistribuído livremente, sem exigir atribuição.

## Copyright, patentes e marcas registradas

Três mecanismos legais distintos afetam o software:

- **Copyright (direito autoral)**: protege a expressão de uma obra (o código-fonte em si), não a ideia. É o que licenças como a GPL usam como base legal para impor suas condições.
- **Patentes**: protegem invenções e processos técnicos (algoritmos, métodos). São mais controversas no mundo open source, pois podem impedir a reimplementação livre de uma técnica mesmo que o código seja escrito do zero.
- **Trademarks (marcas registradas)**: protegem nomes e logotipos. Por isso, projetos como Firefox ou Fedora têm regras específicas sobre o uso de seu nome/logo em builds modificadas, mesmo sendo o código open source.

## Free Software Foundation e Open Source Initiative

Duas organizações formalizam e defendem os princípios do software livre/aberto:

- **Free Software Foundation (FSF)**, fundada por Richard Stallman em 1985, promove as **quatro liberdades essenciais** do *free software*: executar o programa para qualquer propósito (0), estudar e modificar o código (1), redistribuir cópias (2) e distribuir versões modificadas (3). A FSF mantém a licença **GPL**.
- **Open Source Initiative (OSI)**, fundada em 1998, mantém a **Open Source Definition** e é responsável por aprovar oficialmente licenças como *open source compliant*.

Na prática, a maioria das licenças aprovadas pela OSI também é considerada *free software* pela FSF — a diferença é mais filosófica (ênfase em liberdade do usuário vs. ênfase em benefícios práticos de desenvolvimento colaborativo) do que técnica.

## Principais licenças

| Licença | Característica principal |
|---|---|
| **GPL (GNU General Public License)** | *Copyleft*: qualquer trabalho derivado distribuído deve manter a mesma licença e disponibilizar o código-fonte. Usada pelo kernel Linux. |
| **LGPL (Lesser GPL)** | Copyleft mais fraco, permite linkar a biblioteca em software proprietário sem obrigar a abrir o código do programa que a usa. |
| **BSD License** | Permissiva: permite reutilizar o código, inclusive em produtos proprietários, com exigência mínima (manter o aviso de copyright). |
| **MIT License** | Permissiva, muito simples e curta, semelhante em espírito à BSD. |
| **Creative Commons (CC)** | Não é uma licença de software, mas de conteúdo (textos, imagens, documentação, cursos). Tem variantes como CC-BY, CC-BY-SA, CC0. |

Verificando a licença de um pacote instalado no sistema:

```
$ dpkg -s bash | grep -i licen
$ zless /usr/share/doc/bash/copyright
```

## Distribuições Linux e outros sistemas open source

Uma **distribuição Linux** combina o kernel Linux com um conjunto de ferramentas GNU, um gerenciador de pacotes e, geralmente, um ambiente gráfico. Exemplos citados no material da LPI:

- **Debian**: base de dezenas de outras distros, gerenciador `apt`/`dpkg`, ciclo de lançamento conservador.
- **Ubuntu**: derivada do Debian, focada em facilidade de uso.
- **Fedora**: patrocinada pela Red Hat, gerenciador `dnf`/`rpm`, base do RHEL.
- **openSUSE**: gerenciador `zypper`/`rpm`.
- **Arch Linux**: instalação minimalista, *rolling release*, gerenciador `pacman`.

Verificando qual distribuição está em uso:

```
$ cat /etc/os-release
NAME="Fedora Linux"
VERSION="40 (Workstation Edition)"
ID=fedora
VERSION_ID=40

$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 24.04 LTS
Release:        24.04
Codename:       noble

$ uname -a
Linux host 6.8.0-generic #1 SMP x86_64 GNU/Linux
```

Além do Linux, o exame espera conhecimento básico sobre outros sistemas open source:

- **BSD (Berkeley Software Distribution)**: família de sistemas Unix-like open source com licença permissiva, distinta do modelo de "distribuição" do Linux (o kernel e o userland do BSD são desenvolvidos em conjunto). Principais variantes:
  - **FreeBSD**: foco em desempenho e uso em servidores.
  - **OpenBSD**: foco em segurança e código auditado.
  - **NetBSD**: foco em portabilidade (roda em muitas arquiteturas diferentes).
- **Android**: sistema operacional para dispositivos móveis baseado no kernel Linux, mantido pelo **Android Open Source Project (AOSP)**. O kernel e boa parte da base são open source, mas muitos dispositivos comerciais incluem camadas proprietárias (Google Play Services, apps do fabricante).

## Aplicações open source comuns

O exame espera reconhecer alternativas open source populares a softwares proprietários equivalentes:

| Categoria | Software proprietário | Alternativa Open Source |
|---|---|---|
| Suíte de escritório | Microsoft Office | LibreOffice, OpenOffice |
| Edição de imagem | Adobe Photoshop | GIMP |
| Edição/animação 3D | Autodesk Maya | Blender |
| Navegador web | Google Chrome (proprietário em parte) | Firefox, Chromium |
| Banco de dados | Oracle DB, Microsoft SQL Server | MySQL/MariaDB, PostgreSQL |
| Servidor web | IIS | Apache HTTP Server, nginx |

## Referências

- LPI Learning Materials — 010-160 — 4.1 Choosing an Operating System: https://learning.lpi.org/en/learning-materials/010-160/4/4.1/
- Free Software Foundation — What is Free Software?: https://www.gnu.org/philosophy/free-sw.html
- Open Source Initiative — The Open Source Definition: https://opensource.org/osd
- GNU General Public License: https://www.gnu.org/licenses/gpl-3.0.html
- OSI — Licenses (BSD, MIT, etc.): https://opensource.org/licenses
- Creative Commons — About the licenses: https://creativecommons.org/about/cclicenses/
- FreeBSD Project: https://www.freebsd.org/
- OpenBSD Project: https://www.openbsd.org/
- Android Open Source Project: https://source.android.com/