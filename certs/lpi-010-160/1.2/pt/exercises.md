# Exercícios Guiados — Tópico 1.2: Major Open Source Applications

**Certificação:** LPI Linux Essentials (010-160, versão 1.6) · **Peso:** 2
**Fonte de referência:** [LPI Learning Materials 1.2](https://learning.lpi.org/en/learning-materials/010-160/1/1.2/)

Estes exercícios assumem acesso a um terminal Linux (máquina virtual, WSL, container ou Raspberry Pi). Os passos que instalam ou removem software usam o modo de **simulação** do package manager, então nenhum passo altera o sistema nem exige privilégios de `root` — exceto onde indicado como opcional.

---

## Exercício 1 — Reconhecendo as desktop applications instaladas

O ecossistema open source cobre praticamente todas as categorias de software de desktop: suíte de escritório (**LibreOffice** — [libreoffice.org](https://www.libreoffice.org)), navegador (**Firefox** — [mozilla.org](https://www.mozilla.org/firefox/)), edição de imagem (**GIMP** — [gimp.org](https://www.gimp.org)), gráficos vetoriais (**Inkscape**), multimídia (**VLC** — [videolan.org](https://www.videolan.org)) e modelagem 3D (**Blender**).

**Passos:**

1. Descubra quais dessas aplicações já existem no seu sistema:
   ```bash
   which firefox libreoffice gimp inkscape vlc blender 2>/dev/null
   ```
2. Para cada uma encontrada, consulte a versão (exemplo com o Firefox):
   ```bash
   firefox --version
   ```
3. O LibreOffice é uma **suíte**: um único projeto com vários módulos. Liste os binários relacionados:
   ```bash
   ls /usr/bin/ | grep -i libre
   ```
4. Anote quais categorias de aplicação (office, browser, imagem, multimídia) estão cobertas na sua instalação e quais não estão.

**Perguntas de verificação:**

**1.1.** Qual aplicação open source você usaria para: (a) editar uma planilha, (b) retocar uma fotografia, (c) assistir a um vídeo, (d) criar um logotipo vetorial?

**1.2.** O LibreOffice Writer produz arquivos no formato **ODF** (Open Document Format). Por que um formato de arquivo aberto e padronizado é importante, independentemente do programa usado?

**1.3.** GIMP e Inkscape editam "imagens", mas não são intercambiáveis. Qual é a diferença fundamental entre os dois tipos de gráficos com que trabalham?

---

## Exercício 2 — Identificando a família de package management do sistema

Quase todo software em Linux chega através de **packages** baixados de **repositories** mantidos pela distribution. Existem duas grandes famílias: a de Debian (`.deb`, ferramentas `dpkg` e `apt`) e a de Red Hat (`.rpm`, ferramentas `rpm` e `dnf`/`yum`).

**Passos:**

1. Descubra quais ferramentas de empacotamento existem no seu sistema:
   ```bash
   which dpkg apt apt-get rpm dnf yum zypper 2>/dev/null
   ```
2. Confirme a família olhando a identificação da distro:
   ```bash
   grep -E '^(ID|ID_LIKE)=' /etc/os-release
   ```
3. Conte quantos packages estão instalados. Use o comando da sua família:
   ```bash
   dpkg -l | wc -l        # família Debian
   rpm -qa | wc -l        # família Red Hat
   ```
4. Descubra qual package instalou um arquivo que você usa todos os dias, o shell `bash`:
   ```bash
   dpkg -S /bin/bash      # família Debian
   rpm -qf /bin/bash      # família Red Hat
   ```

**Perguntas de verificação:**

**2.1.** Qual é a relação entre `dpkg` e `apt` (ou entre `rpm` e `dnf`)? Por que existem duas ferramentas na mesma família?

**2.2.** Um colega baixou um arquivo `pacote.rpm` e tenta instalá-lo no Ubuntu. Por que isso não funciona diretamente?

**2.3.** O que é um **repository** e qual vantagem ele oferece em relação a baixar instaladores de sites, como se faz tradicionalmente no Windows?

---

## Exercício 3 — Pesquisando e "instalando" software a partir dos repositories

Antes de instalar qualquer coisa, o package manager permite pesquisar e inspecionar packages. A instalação em si exige `root`, mas o modo de simulação mostra exatamente o que aconteceria.

**Passos:**

1. Atualize sua visão do catálogo e pesquise pelo editor de imagens GIMP:
   ```bash
   apt search gimp 2>/dev/null | head -20      # família Debian
   dnf search gimp | head -20                  # família Red Hat
   ```
2. Consulte os detalhes do package (descrição, versão, tamanho):
   ```bash
   apt show gimp        # família Debian
   dnf info gimp        # família Red Hat
   ```
3. Simule a instalação **sem** alterar nada. Observe a lista de dependências que seriam instaladas junto:
   ```bash
   apt-get -s install gimp             # família Debian (-s = simulate)
   dnf install --assumeno gimp         # família Red Hat (responde "não" sozinho)
   ```
4. *(Opcional, exige `sudo`)* Se quiser instalar de verdade, execute o mesmo comando sem `-s`/`--assumeno` e com `sudo`. Depois remova com `sudo apt-get remove gimp` ou `sudo dnf remove gimp`.

**Perguntas de verificação:**

**3.1.** Na simulação do passo 3, o package manager listou vários outros packages além do `gimp`. O que são **dependencies** e por que o package manager as resolve automaticamente?

**3.2.** Qual campo do output de `apt show` / `dnf info` permite verificar a licença ou a página oficial do projeto antes de instalar?

**3.3.** Por que instalar software apenas exige `root`, mas pesquisar (`search`, `show`/`info`) não?

---

## Exercício 4 — Conhecendo as server applications

Grande parte da internet roda sobre server applications open source: os web servers **Apache HTTP Server** ([httpd.apache.org](https://httpd.apache.org)) e **NGINX** ([nginx.org](https://nginx.org)), os bancos de dados **MariaDB** ([mariadb.org](https://mariadb.org)) e **PostgreSQL** ([postgresql.org](https://www.postgresql.org)), o compartilhamento de arquivos **Samba** ([samba.org](https://www.samba.org)) e o mail server **Postfix**.

**Passos:**

1. Consulte nos repositories os packages desses servidores (note que o nome pode variar entre distros):
   ```bash
   apt show apache2 nginx mariadb-server samba 2>/dev/null | grep -E '^(Package|Description):'   # Debian
   dnf info httpd nginx mariadb-server samba 2>/dev/null | grep -E '^(Name|Summary)'             # Red Hat
   ```
2. Verifique se algum servidor já está rodando na sua máquina, listando os programas que escutam conexões de rede:
   ```bash
   ss -tln
   ```
3. Observe a coluna `Local Address:Port`. As portas 80/443 indicariam um web server; 3306, MariaDB/MySQL; 5432, PostgreSQL; 139/445, Samba.
4. Compare com um servidor real: consulte quais cabeçalhos um site público envia (o campo `Server:` às vezes revela o software):
   ```bash
   curl -sI https://www.lpi.org | head -10
   ```

**Perguntas de verificação:**

**4.1.** Associe cada aplicação à sua função: Apache HTTP Server, MariaDB, Samba, Postfix.

**4.2.** MariaDB nasceu como um **fork** do MySQL. O que é um fork e por que licenças open source tornam isso possível?

**4.3.** Qual a diferença de propósito entre Samba e NFS, sendo que ambos compartilham arquivos em rede?

---

## Exercício 5 — Development languages disponíveis no sistema

Linux é também uma plataforma de desenvolvimento. O exame espera que você reconheça as linguagens mais comuns do ecossistema: **shell script (Bash)**, **Python** ([python.org](https://www.python.org)), **C**, **Perl**, **PHP** e **JavaScript**.

**Passos:**

1. Verifique quais interpretadores e compiladores existem no sistema:
   ```bash
   bash --version | head -1
   python3 --version
   perl -v 2>/dev/null | head -2
   gcc --version 2>/dev/null | head -1
   ```
2. Execute um programa de uma linha em Python, direto do terminal:
   ```bash
   python3 -c 'print("LPI Essentials: " + str(20 * 8) + " questões? Não: 40!")'
   ```
3. Crie e execute um shell script mínimo:
   ```bash
   echo -e '#!/bin/bash\necho "Rodando em: $(uname -sr)"' > ~/ola.sh
   chmod +x ~/ola.sh
   ~/ola.sh
   ```
4. Abra o script e identifique a primeira linha:
   ```bash
   cat ~/ola.sh
   ```
5. Limpe o ambiente:
   ```bash
   rm ~/ola.sh
   ```

**Perguntas de verificação:**

**5.1.** Como se chama a primeira linha `#!/bin/bash` de um script e qual é a sua função?

**5.2.** C é uma linguagem **compilada** e Python é **interpretada**. Explique a diferença prática entre as duas abordagens.

**5.3.** Qual dessas linguagens é a mais provável para: (a) automatizar uma sequência de comandos do sistema, (b) o código-fonte do próprio kernel Linux, (c) a lógica de uma página web executada no browser?

---

## Exercício 6 — Escolhendo a ferramenta certa (revisão integradora)

Este exercício não usa o terminal: é um cenário de decisão, o formato mais comum das questões do exame para este tópico.

**Passos:**

1. Leia cada cenário abaixo e escolha **uma** aplicação open source adequada, sem consultar os exercícios anteriores.
   - **Cenário A:** uma escola precisa abrir e editar documentos de texto e planilhas sem pagar licenças.
   - **Cenário B:** uma empresa quer hospedar seu site institucional em um servidor Linux próprio.
   - **Cenário C:** um estúdio precisa cortar e converter arquivos de áudio.
   - **Cenário D:** uma aplicação web precisa armazenar dados de clientes de forma estruturada e consultável.
   - **Cenário E:** um escritório com máquinas Windows precisa acessar pastas compartilhadas hospedadas em um servidor Linux.
   - **Cenário F:** um administrador quer automatizar um backup que roda todas as noites encadeando comandos do sistema.
2. Depois de responder, confira suas escolhas na seção de respostas e verifique com `apt search` / `dnf search` que cada aplicação escolhida realmente existe nos repositories da sua distro.

**Perguntas de verificação:**

**6.1.** Quais foram suas escolhas para os cenários A–F?

**6.2.** Para o Cenário B, há pelo menos duas respostas corretas consagradas. Quais são, e o que isso diz sobre o ecossistema open source?

---

<details>
<summary><strong>Respostas</strong></summary>

### Exercício 1

**1.1.** (a) **LibreOffice Calc** (planilhas); (b) **GIMP** (edição de imagens raster/fotografias); (c) **VLC** (reprodutor multimídia que suporta praticamente qualquer formato); (d) **Inkscape** (gráficos vetoriais).

**1.2.** Um formato aberto e padronizado (o ODF é um padrão ISO/IEC 26300) garante que o documento possa ser lido por qualquer software, hoje e no futuro, sem depender de um único fornecedor. Isso evita o **vendor lock-in**: seus dados não ficam presos ao programa que os criou.

**1.3.** O GIMP trabalha com gráficos **raster** (bitmap): uma grade de pixels, ideal para fotografias, que perde qualidade ao ser ampliada. O Inkscape trabalha com gráficos **vector**: formas descritas matematicamente (formato SVG), que escalam para qualquer tamanho sem perda — ideal para logotipos e ícones.

### Exercício 2

**2.1.** `dpkg` e `rpm` são as ferramentas de **baixo nível**: instalam um arquivo de package local, mas não sabem buscar nada nem resolver dependências. `apt` e `dnf` são as ferramentas de **alto nível**: consultam os repositories, baixam os packages, resolvem dependencies automaticamente e, por baixo, usam `dpkg`/`rpm` para a instalação em si.

**2.2.** Ubuntu pertence à família Debian e usa packages `.deb` gerenciados por `dpkg`/`apt`. Um arquivo `.rpm` está no formato da família Red Hat: estrutura interna, metadados e banco de dados de packages são incompatíveis. Seria preciso encontrar o `.deb` equivalente (ou o mesmo software nos repositories do Ubuntu).

**2.3.** Um repository é um catálogo centralizado de packages mantido e assinado pela distribution. Vantagens: fonte única e confiável (packages verificados criptograficamente), resolução automática de dependencies e atualização de **todo** o software instalado com um único comando — em vez de visitar dezenas de sites e baixar instaladores de origem duvidosa.

### Exercício 3

**3.1.** **Dependencies** são outros packages (bibliotecas, recursos, ferramentas) de que um programa precisa para funcionar. Em vez de cada programa embutir tudo, o software é dividido em packages reutilizáveis; o package manager calcula a árvore completa de dependências e instala o que faltar, garantindo que nada fique quebrado.

**3.2.** No `apt show`, os campos `Homepage:` e (nos metadados do package) a licença documentada; no `dnf info`, os campos `License` e `URL`. Eles permitem conferir o projeto oficial e os termos de uso antes de instalar.

**3.3.** Instalar software altera diretórios do sistema (`/usr/bin`, `/usr/lib`, etc.) e o banco de dados de packages, que pertencem ao sistema como um todo — por isso exige `root`. Pesquisar apenas **lê** metadados públicos do catálogo, o que qualquer usuário pode fazer com segurança.

### Exercício 4

**4.1.** **Apache HTTP Server** → servir páginas e aplicações web (protocolo HTTP/HTTPS). **MariaDB** → banco de dados relacional (armazenar e consultar dados com SQL). **Samba** → compartilhar arquivos e impressoras em redes com máquinas Windows (protocolo SMB/CIFS). **Postfix** → servidor de e-mail (MTA, envio e roteamento de mensagens via SMTP).

**4.2.** Um **fork** é a criação de um projeto novo e independente a partir do código-fonte de um projeto existente. Licenças open source (como a GPL, sob a qual o MySQL é distribuído) garantem o direito de estudar, modificar e redistribuir o código — foi assim que a comunidade criou o MariaDB quando o rumo do MySQL, após sua aquisição pela Oracle, gerou desconfiança. O fork é uma proteção fundamental do modelo open source.

**4.3.** Ambos compartilham arquivos, mas para públicos diferentes: **Samba** implementa o protocolo SMB/CIFS, nativo do mundo Windows — ideal para redes mistas Linux/Windows. **NFS** (Network File System) é o protocolo tradicional de compartilhamento entre sistemas Unix/Linux, comum em servidores e clusters.

### Exercício 5

**5.1.** É o **shebang** (ou *hashbang*). Ele indica ao sistema qual interpretador deve executar o arquivo — aqui, `/bin/bash`. Sem ele, o sistema não saberia se o script é Bash, Python, Perl, etc.

**5.2.** Em uma linguagem **compilada** (C), o código-fonte é traduzido de antemão, por um compiler como o `gcc`, para código de máquina — o resultado executa muito rápido, mas precisa ser recompilado para cada arquitetura. Em uma linguagem **interpretada** (Python), um interpreter lê e executa o código diretamente a cada execução — desenvolvimento mais ágil e portátil, ao custo de desempenho menor.

**5.3.** (a) **Shell script (Bash)** — feito exatamente para encadear comandos do sistema; (b) **C** — o kernel Linux é escrito quase todo em C; (c) **JavaScript** — a linguagem executada pelos browsers.

### Exercício 6

**6.1.** Respostas esperadas: **A:** LibreOffice. **B:** Apache HTTP Server ou NGINX. **C:** Audacity (edição de áudio; para conversão em lote também vale FFmpeg). **D:** MariaDB ou PostgreSQL. **E:** Samba. **F:** um shell script (Bash), possivelmente agendado com `cron`.

**6.2.** **Apache HTTP Server** e **NGINX** — ambos são web servers open source amplamente usados em produção. Isso ilustra uma característica central do ecossistema: para quase toda necessidade existem **múltiplas** soluções open source maduras competindo, e a escolha depende de requisitos (desempenho, configuração, familiaridade), não de um fornecedor único.

</details>