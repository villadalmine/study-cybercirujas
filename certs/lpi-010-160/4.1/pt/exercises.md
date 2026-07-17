# Exercícios guiados — Tópico 4.1: Choosing an Operating System

**Certificação:** LPI Linux Essentials (010-160), versão 1.6
**Peso no exame:** 1
**Referência:** https://learning.lpi.org/en/learning-materials/010-160/4/4.1/

## Exercício 1 — Identificar o kernel e a arquitetura do sistema

1. Abra um terminal.
2. Execute `uname -a` e observe a saída completa.
3. Execute separadamente `uname -s`, `uname -r` e `uname -m` para isolar nome do kernel, versão do kernel e arquitetura de hardware.
4. Compare o valor de `uname -m` (ex.: `x86_64`, `aarch64`, `armv7l`) com a arquitetura real do seu processador (consulte a documentação do fabricante ou `lscpu`, se disponível).

**Perguntas de verificação**
1. Qual é a diferença entre o "kernel" reportado por `uname -s` e o "sistema operacional" no sentido amplo (kernel + ferramentas GNU + gerenciador de pacotes + desktop environment)?
2. Por que a mesma distribuição Linux pode ser compilada para arquiteturas diferentes (x86_64, ARM, etc.), enquanto isso não costuma acontecer com sistemas operacionais proprietários de uso doméstico?

## Exercício 2 — Identificar a distribuição a partir dos arquivos de release

1. Verifique se existe o arquivo padronizado `/etc/os-release` com `cat /etc/os-release`.
2. Observe os campos `NAME`, `ID`, `VERSION_ID` e `ID_LIKE`.
3. Procure arquivos de release legados específicos de família, executando `ls /etc/*release* /etc/*version* 2>/dev/null` (ex.: `/etc/debian_version` para a família Debian, `/etc/redhat-release` para a família Red Hat).
4. Se o comando `lsb_release` estiver instalado, execute `lsb_release -a` e compare a saída com `/etc/os-release`.

**Perguntas de verificação**
1. Para que serve o campo `ID_LIKE` em `/etc/os-release`, e o que ele indica sobre a origem de uma distribuição derivada (por exemplo, Ubuntu em relação a Debian)?
2. Se `/etc/debian_version` existe mas `/etc/redhat-release` não, o que isso sugere sobre a família da distribuição instalada?

## Exercício 3 — Comparar famílias de distribuições pelo gerenciador de pacotes

1. Verifique quais gerenciadores de pacotes estão disponíveis no sistema, testando a existência dos binários: `which dpkg apt rpm dnf yum pacman zypper 2>/dev/null`.
2. Anote qual(is) comando(s) retornaram um caminho válido.
3. Associe o(s) gerenciador(es) encontrado(s) à família de distribuição correspondente:
   - `dpkg`/`apt` → família Debian (Debian, Ubuntu, Linux Mint)
   - `rpm`/`dnf`/`yum` → família Red Hat (Fedora, RHEL, CentOS, Rocky Linux)
   - `pacman` → Arch Linux e derivadas
   - `zypper` → openSUSE
4. Se tiver acesso à internet, consulte https://distrowatch.com e compare pelo menos duas distribuições de famílias diferentes quanto a: ciclo de lançamento (rolling release vs. release fixo), público-alvo (desktop, servidor, embedded) e licenciamento.

**Perguntas de verificação**
1. Por que o formato do pacote (`.deb` vs `.rpm`) não é, por si só, suficiente para definir a "distribuição" — o que mais compõe a identidade de uma distro?
2. Cite uma vantagem e uma desvantagem de um modelo de lançamento "rolling release" (ex.: Arch Linux) em comparação com um modelo de lançamento fixo com suporte de longo prazo (ex.: Ubuntu LTS).

## Exercício 4 — Reconhecer o papel do desktop environment

1. Verifique se há uma sessão gráfica ativa consultando a variável de ambiente com `echo $XDG_CURRENT_DESKTOP` (ou `echo $DESKTOP_SESSION`).
2. Se estiver em um sistema apenas de terminal (sem interface gráfica), pesquise na documentação da sua distribuição quais desktop environments ela oferece oficialmente (ex.: GNOME, KDE Plasma, Xfce).
3. Liste, sem instalar nada, pelo menos três desktop environments distintos e identifique se cada um é voltado a hardware leve (baixo consumo de recursos) ou a hardware robusto com muitos efeitos visuais.

**Perguntas de verificação**
1. Qual é a relação entre kernel, distribuição e desktop environment — eles são a mesma coisa ou camadas independentes que podem ser combinadas?
2. Por que um mesmo desktop environment (ex.: GNOME) pode estar disponível em distribuições completamente diferentes, como Fedora e Debian?

## Exercício 5 — Diferenciar software livre, open source e proprietário

1. Escolha um software que você usa no dia a dia (sistema operacional, navegador ou editor de texto).
2. Pesquise sua licença (procure por "license" ou "licença" na documentação oficial ou repositório do projeto).
3. Classifique o software em uma das categorias: software livre/open source (ex.: licenciado sob GPL, MIT, Apache), freeware proprietário (gratuito, mas de código fechado) ou software comercial proprietário.
4. Repita o processo para o próprio kernel Linux e verifique sob qual licença ele é distribuído (consulte https://www.kernel.org).

**Perguntas de verificação**
1. Qual é a diferença central entre "gratuito" (free as in beer) e "livre" (free as in freedom) no contexto de licenciamento de software?
2. Sob qual licença o kernel Linux é distribuído, e o que essa licença exige de quem redistribui versões modificadas do código?

---

<details>
<summary>Respostas</summary>

**Exercício 1**
1. `uname -s` reporta apenas o nome do kernel (por exemplo, "Linux"). O "sistema operacional" no sentido amplo inclui o kernel, mas também as bibliotecas do sistema, as ferramentas GNU (coreutils, bash, etc.), o gerenciador de pacotes e, opcionalmente, um desktop environment — tudo isso empacotado por uma distribuição.
2. O kernel Linux é open source e foi portado para dezenas de arquiteturas de hardware por uma comunidade ampla e distribuída, o que viabiliza builds para x86_64, ARM, RISC-V, etc. Sistemas operacionais proprietários de uso doméstico normalmente têm o suporte de arquitetura decidido e limitado por uma única empresa, conforme seus próprios interesses comerciais.

**Exercício 2**
1. `ID_LIKE` indica de qual distribuição "base" a distribuição atual deriva ou com qual é compatível (por exemplo, Ubuntu declara `ID_LIKE=debian`), permitindo que scripts e ferramentas tratem a distribuição derivada de forma compatível com a original.
2. Sugere que a distribuição pertence à família Debian (Debian, Ubuntu, Mint, etc.), já que `/etc/debian_version` é um arquivo legado específico dessa família, enquanto `/etc/redhat-release` é específico da família Red Hat.

**Exercício 3**
1. O formato de pacote é apenas o mecanismo de empacotamento. A identidade de uma distribuição também inclui o conjunto de pacotes padrão, as políticas de manutenção e segurança, o ciclo de lançamento, a configuração padrão do sistema e a comunidade/empresa responsável.
2. Rolling release: vantagem é ter sempre os pacotes mais recentes disponíveis; desvantagem é maior risco de instabilidade por mudanças constantes. Release fixo com LTS: vantagem é estabilidade e suporte previsível por anos; desvantagem é ter pacotes mais desatualizados até o próximo lançamento maior.

**Exercício 4**
1. São camadas independentes: o kernel gerencia hardware e recursos; a distribuição empacota o kernel junto com bibliotecas, utilitários e gerenciador de pacotes; o desktop environment é uma camada gráfica opcional que roda sobre o sistema já instalado, podendo ser trocado sem alterar a distribuição.
2. Porque desktop environments como GNOME são desenvolvidos como projetos independentes das distribuições e distribuídos como pacotes que qualquer distribuição pode empacotar e oferecer aos usuários.

**Exercício 5**
1. "Gratuito" (free as in beer) refere-se apenas ao custo zero de aquisição, independentemente de o código-fonte estar disponível ou poder ser modificado. "Livre" (free as in freedom) refere-se às liberdades de uso, estudo, modificação e redistribuição do software, geralmente com acesso ao código-fonte, conforme definido pela Free Software Foundation.
2. O kernel Linux é distribuído sob a GPLv2 (GNU General Public License versão 2). Essa licença exige que qualquer redistribuição de versões modificadas do código também disponibilize o código-fonte sob os mesmos termos (copyleft).

</details>