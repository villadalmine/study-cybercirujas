# Exercícios Guiados — Tópico 1.1: Linux Evolution and Popular Operating Systems

**Certificação:** LPI Linux Essentials (010-160, versão 1.6) · **Peso:** 2
**Fonte de referência:** [LPI Learning Materials 1.1](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/)

Estes exercícios assumem que você tem acesso a um terminal Linux (pode ser uma máquina virtual, WSL, um container ou um Raspberry Pi). Nenhum passo exige privilégios de `root`.

---

## Exercício 1 — Identificando o kernel do seu sistema

O Linux, estritamente falando, é apenas o **kernel**: o núcleo do sistema operacional criado por Linus Torvalds em 1991. Tudo o mais que você usa (shell, utilitários, interface gráfica) vem de outros projetos, principalmente do projeto **GNU**.

**Passos:**

1. Abra um terminal.
2. Execute o comando que mostra o nome do kernel:
   ```bash
   uname
   ```
3. Agora peça todas as informações disponíveis:
   ```bash
   uname -a
   ```
4. Extraia apenas a versão do kernel:
   ```bash
   uname -r
   ```
5. Anote o número da versão (por exemplo, `6.8.0-45-generic`). Os dois primeiros números (`6.8`) identificam a **release** principal do kernel.

**Perguntas de verificação:**

**1.1.** Qual é a diferença entre "Linux" (o kernel) e uma "Linux distribution"?

**1.2.** No output de `uname -r`, o que provavelmente significa o sufixo depois do número da versão (por exemplo, `-generic`, `-arch1` ou `-fc44`)?

**1.3.** Em que ano Linus Torvalds anunciou o kernel Linux, e qual era o objetivo inicial do projeto?

---

## Exercício 2 — Descobrindo qual distribution você está usando

Uma **distribution** (ou "distro") combina o kernel Linux com software do projeto GNU, um sistema de empacotamento e ferramentas próprias. Cada distro tem público e filosofia diferentes.

**Passos:**

1. Veja o arquivo padrão de identificação da distro:
   ```bash
   cat /etc/os-release
   ```
2. Observe os campos `NAME`, `VERSION` e `ID_LIKE`. O campo `ID_LIKE` revela de qual família a distro deriva.
3. Se disponível, tente também:
   ```bash
   lsb_release -a
   ```
   (Em algumas distros esse comando não vem instalado — isso já é uma pista sobre como as distros diferem entre si.)
4. Verifique qual gerenciador de pacotes existe no sistema, testando quais destes comandos respondem:
   ```bash
   which apt dpkg dnf rpm zypper pacman 2>/dev/null
   ```

**Perguntas de verificação:**

**2.1.** Se `which` encontrou `apt` e `dpkg`, a qual família de distributions o seu sistema pertence? E se encontrou `dnf` e `rpm`?

**2.2.** Associe cada distro à sua família ou característica principal: **Debian**, **Ubuntu**, **Fedora**, **openSUSE**, **CentOS Stream / Rocky Linux**.

**2.3.** Por que uma empresa poderia escolher uma distro **enterprise** com suporte de longo prazo (como Red Hat Enterprise Linux ou SUSE Linux Enterprise Server) em vez de uma distro comunitária com releases frequentes?

---

## Exercício 3 — Ciclo de vida e releases

Escolher um sistema operacional também significa escolher um **ciclo de suporte**. Distros do tipo **LTS** (Long Term Support) priorizam estabilidade; distros **rolling release** entregam sempre o software mais novo.

**Passos:**

1. Releia o campo `VERSION` do seu `/etc/os-release`. Se aparecer a sigla `LTS` (comum no Ubuntu), seu sistema é uma release de suporte longo.
2. Verifique há quanto tempo o kernel do sistema foi compilado:
   ```bash
   uname -v
   ```
3. Compare a versão do seu kernel (`uname -r`) com a versão estável mais recente publicada em https://www.kernel.org. É comum que sejam bem diferentes.

**Perguntas de verificação:**

**3.1.** Por que a versão do kernel da sua distro costuma ser mais antiga que a última versão publicada em kernel.org?

**3.2.** O que é uma distro **rolling release**? Cite um exemplo e uma situação em que ela seria uma má escolha.

**3.3.** O que significa dizer que o Ubuntu LTS tem 5 anos de suporte? Que tipo de atualização o sistema continua recebendo durante esse período?

---

## Exercício 4 — Linux além do desktop e do servidor

O tópico 1.1 pede que você reconheça onde o Linux aparece: servidores, cloud, dispositivos **embedded**, smartphones (**Android**) e placas como o **Raspberry Pi**.

**Passos:**

1. Se você tem um smartphone Android à mão: abra **Configurações → Sobre o telefone → Versão do Android** e procure a opção que mostra a **kernel version**. Compare o formato com o output do seu `uname -r`.
2. No terminal Linux, veja em qual arquitetura de hardware o sistema roda:
   ```bash
   uname -m
   ```
   Em um PC comum o resultado será `x86_64`; em um Raspberry Pi, algo como `aarch64` ou `armv7l`.
3. Reflita (sem executar nada): roteadores Wi-Fi, smart TVs e sistemas de infotainment de carros frequentemente rodam Linux embedded — o mesmo kernel, compilado para outra arquitetura.

**Perguntas de verificação:**

**4.1.** O Android usa o kernel Linux. Por que, mesmo assim, ele normalmente **não** é considerado uma "Linux distribution" tradicional?

**4.2.** O que o resultado de `uname -m` diz sobre o sistema, e por que isso importa ao escolher software para um Raspberry Pi?

**4.3.** Cite três contextos, além de desktops, em que o Linux é amplamente usado.

---

## Exercício 5 — Linux e os outros sistemas operacionais

Para o exame, você precisa situar o Linux entre as alternativas: **Windows**, **macOS**, os **BSDs** e o **Unix** original.

**Passos:**

1. Execute:
   ```bash
   echo $SHELL
   ```
   e anote qual shell você usa (provavelmente `bash`, do projeto GNU).
2. Pesquise (no navegador) o que é o **POSIX** standard e note que Linux, macOS e os BSDs seguem, em graus diferentes, essa herança do Unix.
3. Liste três programas do seu sistema e veja de onde vêm:
   ```bash
   ls --version | head -n 2
   ```
   Observe a menção a **GNU coreutils** — por isso muita gente chama o sistema completo de "GNU/Linux".

**Perguntas de verificação:**

**5.1.** Qual é a relação histórica entre o Unix e o Linux? O Linux contém código do Unix original?

**5.2.** O macOS também tem herança Unix. Qual é a diferença fundamental de **licenciamento** entre o macOS e o Linux?

**5.3.** Por que o nome "GNU/Linux" é considerado por muitos mais preciso que apenas "Linux" para descrever o sistema completo?

---

<details>
<summary><strong>Respostas</strong></summary>

### Exercício 1

**1.1.** "Linux" é apenas o **kernel** — o componente que gerencia hardware, memória e processos. Uma **distribution** é o pacote completo: kernel + utilitários GNU + gerenciador de pacotes + software adicional + configurações, montado por um projeto ou empresa (Debian, Fedora, Ubuntu etc.).

**1.2.** O sufixo identifica a **build da distro**: cada distribution compila o kernel com seus próprios patches e configurações. `-generic` indica o kernel padrão do Ubuntu, `-fc44` uma build do Fedora, `-arch1` do Arch Linux.

**1.3.** Em **1991**. Torvalds, então estudante na Finlândia, começou o kernel como um projeto pessoal/hobby inspirado no Minix, e o abriu para colaboração pela Internet. Combinado com as ferramentas do projeto GNU (iniciado por Richard Stallman em 1983), formou um sistema operacional completo e livre.

### Exercício 2

**2.1.** `apt` e `dpkg` indicam a família **Debian** (Debian, Ubuntu, Linux Mint, Raspberry Pi OS). `dnf` e `rpm` indicam a família **Red Hat** (Fedora, RHEL, CentOS Stream, Rocky Linux). `zypper` indicaria openSUSE; `pacman`, Arch Linux.

**2.2.**
- **Debian** — distro comunitária, base de muitas outras; foco em estabilidade e software livre.
- **Ubuntu** — derivada do Debian, mantida pela Canonical; foco em facilidade de uso, com releases LTS.
- **Fedora** — comunitária, patrocinada pela Red Hat; adota tecnologias novas cedo e serve de base para o RHEL.
- **openSUSE** — comunitária, relacionada ao SUSE Linux Enterprise; conhecida pela ferramenta YaST.
- **CentOS Stream / Rocky Linux** — relacionadas ao Red Hat Enterprise Linux: CentOS Stream é a base de desenvolvimento do RHEL; Rocky Linux é uma reconstrução compatível, gratuita.

**2.3.** Distros enterprise oferecem **suporte comercial**, ciclos de vida longos (10+ anos), atualizações de segurança garantidas e certificações de hardware/software — fatores críticos para servidores em produção, onde estabilidade e previsibilidade valem mais do que ter as versões mais recentes.

### Exercício 3

**3.1.** A distro "congela" uma versão do kernel na release e depois aplica apenas correções (**backports** de segurança e bugfixes), para garantir estabilidade. O kernel.org, por sua vez, publica o desenvolvimento contínuo do projeto upstream.

**3.2.** Uma **rolling release** não tem versões fechadas: os pacotes são atualizados continuamente para as versões mais novas. Exemplos: Arch Linux, openSUSE Tumbleweed. É uma má escolha para servidores de produção ou ambientes que exigem estabilidade e mudanças previsíveis, pois atualizações frequentes podem introduzir incompatibilidades.

**3.3.** Significa que, por 5 anos a partir do lançamento, a Canonical publica **security updates** e correções de bugs para aquela release — sem mudar as versões principais dos programas. O sistema fica mais seguro com o tempo, mas não mais "novo".

### Exercício 4

**4.1.** Porque o Android substitui quase todo o **userland** tradicional: não usa GNU coreutils, glibc padrão nem os gerenciadores de pacotes das distros; os apps rodam sobre o Android Runtime (linguagens Java/Kotlin) e a distribuição de software é feita por app stores. Só o kernel (modificado pelo Google) é compartilhado com o Linux tradicional.

**4.2.** `uname -m` mostra a **arquitetura de CPU** (`x86_64` = PC 64 bits; `aarch64`/`armv7l` = ARM). Importa porque binários compilados para uma arquitetura não rodam em outra: no Raspberry Pi você precisa de pacotes compilados para ARM, motivo pelo qual existe o Raspberry Pi OS.

**4.3.** Quaisquer três entre: **servidores** (web, banco de dados, DNS), **cloud computing** (a maioria das instâncias em provedores como AWS/Azure/GCP roda Linux), **supercomputadores** (praticamente 100% do TOP500), **dispositivos embedded** (roteadores, smart TVs, automóveis), **smartphones** (Android) e placas como o **Raspberry Pi**.

### Exercício 5

**5.1.** O Unix (Bell Labs, década de 1970) definiu os conceitos e a arquitetura que o Linux segue. Porém o Linux foi escrito **do zero**: é um sistema "Unix-like", compatível em comportamento (padrão POSIX), mas **não contém código do Unix original** — o que permitiu licenciá-lo livremente.

**5.2.** O macOS é **proprietário**: a Apple controla o código e ele só roda (legalmente) em hardware Apple. O Linux é distribuído sob a **GNU GPL**, uma licença de software livre que garante a qualquer pessoa o direito de usar, estudar, modificar e redistribuir o código.

**5.3.** Porque o kernel Linux sozinho não forma um sistema usável: o shell (`bash`), os utilitários básicos (`ls`, `cp`, `grep` — os **GNU coreutils**) e o compilador (`gcc`) vêm do projeto **GNU**, anterior ao próprio kernel. "GNU/Linux" reconhece as duas partes essenciais do sistema.

</details>

---

*Material original elaborado com base nos objetivos do exame. Referência consultada: [learning.lpi.org — 010-160, Lesson 1.1](https://learning.lpi.org/en/learning-materials/010-160/1/1.1/).*