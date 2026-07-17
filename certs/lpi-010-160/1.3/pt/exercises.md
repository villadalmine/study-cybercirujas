# Exercícios Guiados — Tópico 1.3: Open Source Software and Licensing

**Certificação:** LPI Linux Essentials (010-160, versão 1.6) · **Peso:** 1
**Fonte de referência:** [LPI Learning Materials, Lesson 1.3](https://learning.lpi.org/en/learning-materials/010-160/1/1.3/)

> **Requisitos:** um terminal em qualquer distribuição Linux (serve uma máquina virtual, WSL ou container). Alguns passos trazem variantes para sistemas baseados em Debian/Ubuntu e para sistemas baseados em RPM (Fedora, Rocky, openSUSE). Nenhum passo exige `root`.

---

## Exercício 1 — Encontrando os textos das licenças no seu próprio sistema

As distribuições instalam cópias locais das licenças mais comuns. Você vai localizá-las e ver quantas licenças diferentes convivem em um mesmo sistema.

**Passos:**

1. Liste o diretório de licenças. Em Debian/Ubuntu:
   ```bash
   ls /usr/share/common-licenses/
   ```
   Em Fedora/Rocky e derivados:
   ```bash
   ls /usr/share/licenses/ | head -20
   ```
2. Conte quantas versões da **GPL** estão disponíveis:
   ```bash
   ls /usr/share/common-licenses/ | grep -i gpl        # Debian/Ubuntu
   ls /usr/share/licenses/ | grep -i gpl               # RPM
   ```
3. Leia o cabeçalho da GPLv3 (ajuste o caminho conforme a sua distro):
   ```bash
   head -15 /usr/share/common-licenses/GPL-3
   ```
4. Meça o tamanho da GPLv3 em linhas — guarde esse número, você vai usá-lo no Exercício 2:
   ```bash
   wc -l /usr/share/common-licenses/GPL-3
   ```

**Perguntas de verificação:**

**1.1.** Por que a distribuição guarda cópias locais das licenças em vez de apenas apontar para um site na Internet?

**1.2.** No passo 2 aparecem GPL-2 e GPL-3 como arquivos separados. Um programa pode continuar usando a GPLv2 mesmo existindo a versão 3? O que significa a cláusula "or later" (como em `GPL-2.0-or-later`)?

---

## Exercício 2 — Copyleft no texto real da licença

A ideia central da GPL é o **copyleft**: quem redistribui o software (modificado ou não) deve fazê-lo sob a mesma licença e oferecer o **source code**. Você vai verificar isso no texto da própria licença.

**Passos:**

1. Procure onde a GPLv3 exige a entrega do código-fonte:
   ```bash
   grep -n "Corresponding Source" /usr/share/common-licenses/GPL-3 | head -5
   ```
2. Procure a passagem que proíbe adicionar restrições extras:
   ```bash
   grep -n "further restrictions" /usr/share/common-licenses/GPL-3
   ```
3. Agora compare com uma licença **permissiva**. Baixe o texto da licença MIT e conte as linhas:
   ```bash
   curl -s https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt | wc -l
   ```
   (Sem acesso à rede? Basta saber que o texto completo da MIT ocupa cerca de 20 linhas.)
4. Compare esse número com o resultado do passo 4 do Exercício 1: a diferença de tamanho reflete a diferença de obrigações.

**Perguntas de verificação:**

**2.1.** Defina **copyleft** com as suas palavras. Que obrigação ele impõe a quem redistribui um programa GPL modificado?

**2.2.** Uma empresa pega código sob licença **MIT**, modifica e vende como produto fechado, sem publicar as mudanças. Isso é legal? E se o código fosse **GPLv3**?

**2.3.** Classifique cada licença como **copyleft forte** ou **permissiva**: GPL, MIT, BSD, Apache 2.0.

---

## Exercício 3 — Descobrindo a licença dos packages instalados

Cada package do sistema declara sua licença nos metadados. Você vai consultá-los com o gerenciador de pacotes.

**Passos:**

1. Consulte a licença do `bash`. Em sistemas RPM:
   ```bash
   rpm -qi bash | grep -i license
   ```
   Em Debian/Ubuntu não existe campo `License` nos metadados; consulta-se o arquivo copyright:
   ```bash
   head -30 /usr/share/doc/bash/copyright
   ```
2. Muitos programas GNU mostram a licença junto com a versão:
   ```bash
   bash --version
   ```
   Leia a saída completa: repare na menção à GPL e nas frases sobre ausência de garantia ("NO WARRANTY").
3. Repita com outro programa:
   ```bash
   gcc --version 2>/dev/null || python3 --version
   ```
4. (Somente RPM) Liste as licenças de vários packages de uma vez:
   ```bash
   rpm -qa --qf '%{NAME}: %{LICENSE}\n' | sort | head -20
   ```

**Perguntas de verificação:**

**3.1.** A saída de `bash --version` diz que ele é "free software" e distribuído "without warranty". Free software significa que é proibido cobrar por ele?

**3.2.** No passo 4 você vê licenças diferentes (GPLv2, GPLv3+, MIT, BSD, Apache…) convivendo no mesmo sistema. Quem verifica se uma licença qualifica como "open source"? Nomeie a organização e o documento que ela usa como critério.

---

## Exercício 4 — As quatro liberdades do Free Software

A **Free Software Foundation (FSF)**, fundada por Richard Stallman, define o free software por meio de quatro liberdades, numeradas de 0 a 3.

**Passos:**

1. Consulte a definição oficial (no navegador ou com `curl`):
   ```bash
   curl -s https://www.gnu.org/philosophy/free-sw.html | grep -o 'freedom [0-3]' | sort -u
   ```
   URL de referência: https://www.gnu.org/philosophy/free-sw.html
2. Anote as quatro liberdades com as suas palavras em um arquivo:
   ```bash
   nano ~/quatro-liberdades.txt
   ```
   Escreva uma linha por liberdade (0, 1, 2 e 3) e salve.
3. Confira o arquivo:
   ```bash
   cat ~/quatro-liberdades.txt
   ```

**Perguntas de verificação:**

**4.1.** Quais são as quatro liberdades? (Numere de 0 a 3.)

**4.2.** Qual das liberdades é impossível de exercer se o fornecedor não entrega o **source code**?

**4.3.** "Free software" e "open source" descrevem, na prática, quase o mesmo conjunto de programas, mas os termos vêm de organizações distintas com ênfases distintas. Explique a diferença de enfoque entre a **FSF** e a **OSI (Open Source Initiative)**.

**4.4.** Um programa **freeware** pode ser baixado de graça, mas não publica seu código. Ele é free software? Por quê?

---

## Exercício 5 — Modelos de negócio com open source

Software livre não significa que ninguém ganha dinheiro com ele. Você vai identificar o modelo de negócio por trás da sua própria distribuição.

**Passos:**

1. Identifique a sua distribuição:
   ```bash
   cat /etc/os-release
   ```
2. Observe os campos `NAME`, `HOME_URL` e, se existir, `SUPPORT_URL`. Visite o `HOME_URL` e procure o que a organização oferece em troca de dinheiro (suporte, subscriptions, hardware, cloud, treinamento, certificação).
3. Estude um caso concreto: a Red Hat publica o código dos seus produtos, mas vende **subscriptions** de suporte para o **Red Hat Enterprise Linux (RHEL)**, enquanto projetos comunitários como Fedora ou Debian se financiam de outras formas. Anote duas diferenças que encontrar.
4. Pense em um exemplo de **dual licensing**: o mesmo produto oferecido sob GPL para a comunidade e sob licença comercial para empresas que não querem as obrigações do copyleft (casos clássicos: MySQL/MariaDB, Qt).

**Perguntas de verificação:**

**5.1.** Cite pelo menos três modelos de negócio viáveis em torno do open source.

**5.2.** Se qualquer pessoa pode obter o código do RHEL e recompilá-lo (como fazem Rocky Linux e AlmaLinux), o que o cliente da Red Hat está comprando de verdade?

**5.3.** Por que o modelo **SaaS** (software as a service) permite usar software GPL sem publicar as modificações, e qual licença foi criada para fechar essa brecha?

---

## Exercício 6 — Creative Commons: licenças para conteúdo, não para código

As licenças **Creative Commons (CC)** são usadas para obras criativas e documentação, não para software. Você vai decodificar seus módulos.

**Passos:**

1. Abra https://creativecommons.org/licenses/ e localize os quatro módulos combináveis: **BY**, **SA**, **NC**, **ND**.
2. Procure conteúdo CC no seu sistema — muita documentação é publicada sob CC:
   ```bash
   grep -ril "creative commons" /usr/share/doc/ 2>/dev/null | head -5
   ```
3. Escreva em um arquivo o que a licença **CC BY-NC-ND** permite e proíbe, e compare com a **CC BY-SA**:
   ```bash
   nano ~/cc-comparacao.txt
   ```
4. Dado útil para o exame: os próprios materiais de aprendizagem da LPI são publicados sob **CC BY-NC-ND 4.0**. Confira no rodapé de https://learning.lpi.org/en/learning-materials/010-160/1/1.3/

**Perguntas de verificação:**

**6.1.** O que significa cada módulo: BY, SA, NC, ND?

**6.2.** Qual módulo das CC é o análogo do copyleft da GPL?

**6.3.** A variante **CC0** não é, estritamente, uma licença. O que ela faz?

**6.4.** Por que uma licença CC com o módulo **ND** não qualificaria como open source se fosse aplicada a software?

---

<details>
<summary><strong>✅ Respostas</strong></summary>

### Exercício 1

**1.1.** Por conformidade legal e autonomia: a licença faz parte das condições de distribuição do software, então precisa acompanhar os binários instalados — disponível offline e sem depender de um site externo continuar existindo ou manter o mesmo texto. Além disso, centenas de packages podem apontar para uma única cópia local em vez de duplicar o texto.

**1.2.** Sim. Cada versão da GPL é uma licença independente; um projeto pode permanecer na GPLv2 para sempre (o kernel Linux é o exemplo clássico: GPLv2 *only*). A cláusula "or later" (`GPL-2.0-or-later`) significa que quem recebe o software pode cumprir aquela versão **ou qualquer versão posterior** publicada pela FSF, o que facilita a compatibilidade futura entre projetos.

### Exercício 2

**2.1.** **Copyleft** é o mecanismo pelo qual a licença exige que toda redistribuição da obra — modificada ou não — seja feita **sob a mesma licença**, preservando as liberdades para os próximos receptores. Quem redistribui um programa GPL modificado deve oferecer o source code completo correspondente e não pode adicionar restrições extras.

**2.2.** Com MIT é totalmente legal: as licenças permissivas exigem, essencialmente, apenas manter o aviso de copyright e a isenção de garantia; derivados fechados (proprietary) são permitidos. Com GPLv3, não: ao **distribuir** o produto derivado, a empresa seria obrigada a licenciá-lo sob GPLv3 e entregar o código-fonte; vendê-lo fechado violaria a licença.

**2.3.** GPL → **copyleft forte**. MIT, BSD e Apache 2.0 → **permissivas** (a Apache 2.0 acrescenta uma concessão explícita de patentes, mas continua permissiva). Menção útil: a **LGPL** é um copyleft fraco, pensado para bibliotecas.

### Exercício 3

**3.1.** Não. "Free" refere-se a **liberdade**, não a preço ("free as in freedom, not as in free beer"). É perfeitamente legal vender free software ou cobrar pela distribuição; o que não se pode é impedir que o receptor use, estude, modifique e redistribua o programa.

**3.2.** A **Open Source Initiative (OSI)**, que aprova licenças comparando-as com a **Open Source Definition (OSD)** — um documento com 10 critérios (distribuição livre, código-fonte disponível, permissão de derivados, não discriminar pessoas nem campos de uso etc.). Referência: https://opensource.org/osd

### Exercício 4

**4.1.**
- **Liberdade 0:** executar o programa como quiser, para qualquer propósito.
- **Liberdade 1:** estudar como o programa funciona e modificá-lo (exige acesso ao source code).
- **Liberdade 2:** redistribuir cópias para ajudar outras pessoas.
- **Liberdade 3:** distribuir cópias das suas versões modificadas (também exige o source code).

**4.2.** As liberdades **1 e 3**: sem o código-fonte não dá para estudar, modificar nem redistribuir versões modificadas de forma prática. Se o exame pedir uma só, a resposta canônica é a **liberdade 1**.

**4.3.** A **FSF** (Stallman, 1985) trata o tema como uma questão **ética e social**: a liberdade do usuário é um fim em si mesma. A **OSI** (1998) enfatiza as vantagens **práticas e de desenvolvimento**: qualidade, transparência, colaboração, atratividade para empresas. O conjunto de software que ambas qualificam é quase idêntico — por isso se usa o termo guarda-chuva **FOSS/FLOSS** (Free/Libre and Open Source Software).

**4.4.** Não. Freeware é grátis em preço, mas **proprietary** em licença: não dá acesso ao código nem concede as liberdades 1–3. Grátis ≠ livre.

### Exercício 5

**5.1.** Entre outros: venda de **suporte e subscriptions** (Red Hat, SUSE, Canonical); **dual licensing** (Qt, MySQL); **open core** (versão base livre + recursos enterprise fechados); **SaaS/hosting** do software livre (GitLab.com, WordPress.com); **treinamento e certificação**; **doações e fundações** (Debian, Apache Software Foundation); venda de **hardware** que integra software livre.

**5.2.** Não compra o código: compra a **subscription** — suporte com SLA, atualizações e patches de segurança certificados, garantias legais/indenização, certificações de hardware e software de terceiros e acesso à engenharia do fabricante. O valor está no serviço e na confiança, não nos bits.

**5.3.** Porque a GPL clássica impõe obrigações ao **distribuir** o software, e oferecê-lo como serviço pela rede não constitui distribuição: o binário nunca sai do servidor do provedor (a chamada brecha "ASP/SaaS loophole"). Para fechá-la foi criada a **AGPL (GNU Affero GPL)**, que estende o copyleft à interação pela rede: quem oferece um serviço com software AGPL modificado deve disponibilizar o código-fonte aos usuários remotos.

### Exercício 6

**6.1.**
- **BY (Attribution):** é obrigatório dar crédito ao autor original. Presente em todas as licenças CC, exceto CC0.
- **SA (ShareAlike):** obras derivadas devem ser compartilhadas sob a mesma licença.
- **NC (NonCommercial):** proíbe usos comerciais.
- **ND (NoDerivatives):** proíbe distribuir obras modificadas/derivadas.

**6.2.** **SA (ShareAlike)**: assim como o copyleft, obriga os derivados a herdarem a mesma licença.

**6.3.** A **CC0** é uma **dedicação ao domínio público** (public domain dedication): o autor renuncia a todos os direitos na medida em que a lei permitir, sem exigir sequer atribuição. Como não impõe condições, não funciona como uma licença condicional.

**6.4.** Porque proibir obras derivadas contradiz tanto a liberdade 3 da FSF quanto o critério da Open Source Definition que exige permitir modificações e trabalhos derivados. Pela mesma razão, o módulo **NC** também seria incompatível (a OSD proíbe discriminar campos de atividade, incluindo o comercial).

</details>

---

*Material original elaborado com fins de estudo. Referências consultadas: [LPI Learning Materials 010-160, Lesson 1.3](https://learning.lpi.org/en/learning-materials/010-160/1/1.3/) · [GNU — Free Software Definition](https://www.gnu.org/philosophy/free-sw.html) · [Open Source Definition (OSI)](https://opensource.org/osd) · [Creative Commons Licenses](https://creativecommons.org/licenses/).*