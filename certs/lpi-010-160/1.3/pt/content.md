# 1.3 Open Source Software and Licensing

**Peso no exame:** 1 · **Exame:** 010-160 (Linux Essentials, versão 1.6)

## Visão geral

O Linux e a maior parte do seu ecossistema existem graças a modelos de licenciamento que garantem acesso ao código-fonte. Para o exame, você precisa entender a diferença entre *Free Software* e *Open Source Software*, conhecer as organizações **FSF** (Free Software Foundation) e **OSI** (Open Source Initiative), distinguir licenças *copyleft* de licenças *permissive* e reconhecer as licenças mais comuns: **GPL**, **BSD**, **MIT**, **Apache** e **Creative Commons**. Também é esperado que você conheça os modelos de negócio possíveis com software livre.

## Free Software vs. Open Source

Os dois termos descrevem, na prática, quase o mesmo conjunto de software, mas com filosofias diferentes:

- **Free Software** — termo promovido pela **FSF**, fundada por Richard Stallman em 1985. O foco é ético: a liberdade do usuário. "Free" refere-se a liberdade (*free as in freedom*), não a preço (*free as in free beer*). Um software é *free* se garante as **quatro liberdades**:
  - **Liberdade 0:** executar o programa para qualquer propósito;
  - **Liberdade 1:** estudar como o programa funciona e adaptá-lo (exige acesso ao *source code*);
  - **Liberdade 2:** redistribuir cópias;
  - **Liberdade 3:** distribuir versões modificadas.

- **Open Source** — termo promovido pela **OSI**, fundada em 1998 por Eric S. Raymond e Bruce Perens. O foco é pragmático: o modelo de desenvolvimento aberto produz software melhor. A OSI mantém a **Open Source Definition** (10 critérios) e aprova licenças que a cumprem.

- **FOSS / FLOSS** — siglas neutras que englobam os dois movimentos: *Free and Open Source Software* e *Free/Libre and Open Source Software*. "Libre" evita a ambiguidade da palavra inglesa "free".

O oposto é o **proprietary software** (ou *closed source*): o usuário recebe apenas o binário, sem direito de estudar, modificar ou redistribuir.

## Tipos de licença

### Copyleft (proteção forte)

Licenças **copyleft** exigem que trabalhos derivados sejam distribuídos **sob a mesma licença**. A liberdade se propaga: quem modifica e distribui é obrigado a manter o código aberto.

- **GPL (GNU General Public License)** — a licença copyleft mais conhecida. O kernel Linux usa **GPLv2**; muitos projetos GNU usam **GPLv3** (que adiciona cláusulas sobre patentes e *tivoization*). Importante: GPLv2 e GPLv3 são licenças distintas e nem sempre compatíveis entre si.
- **AGPL (GNU Affero GPL)** — estende o copyleft a software acessado pela rede (por exemplo, um serviço web): mesmo sem distribuir binários, quem oferece o serviço deve disponibilizar o código.
- **LGPL (GNU Lesser GPL)** — copyleft "fraco", usado em bibliotecas: permite que programas proprietários façam *link* com a biblioteca sem se tornarem GPL.

### Permissive (proteção mínima)

Licenças **permissive** impõem poucas condições — normalmente só manter o aviso de *copyright*. Trabalhos derivados **podem** ser fechados e incorporados em produtos proprietários.

- **MIT License** — curtíssima; exige apenas preservar o aviso de copyright e a licença.
- **BSD Licenses** (2-clause e 3-clause) — semelhantes à MIT; a versão de 3 cláusulas proíbe usar o nome do projeto para promover derivados.
- **Apache License 2.0** — permissiva, mas mais detalhada: inclui concessão explícita de patentes e exige documentar modificações.

### Creative Commons (conteúdo, não código)

As licenças **Creative Commons (CC)** aplicam-se a obras criativas (documentação, imagens, música, cursos), não a software. São montadas combinando módulos:

| Módulo | Sigla | Significado |
|---|---|---|
| Attribution | **BY** | exige creditar o autor (presente em quase todas) |
| ShareAlike | **SA** | derivados sob a mesma licença (equivalente ao copyleft) |
| NonCommercial | **NC** | proíbe uso comercial |
| NoDerivatives | **ND** | proíbe distribuir versões modificadas |

Exemplos: **CC BY-SA** (usada pela Wikipedia), **CC BY-NC-ND** (a mais restritiva). Existe ainda a **CC0**, que dedica a obra ao domínio público. Atenção para o exame: licenças com **NC** ou **ND** **não** são consideradas livres/open segundo as definições da FSF e da OSI.

## Verificando licenças no sistema

Em distribuições baseadas em RPM (Fedora, RHEL), o campo `License` faz parte dos metadados do pacote:

```bash
$ rpm -qi bash | grep License
License     : GPL-3.0-or-later

$ dnf info coreutils | grep License
License      : GPL-3.0-or-later AND GPL-2.0-or-later AND ...
```

Os textos completos ficam em `/usr/share/licenses/`:

```bash
$ ls /usr/share/licenses/bash/
COPYING
```

Em distribuições Debian/Ubuntu, cada pacote traz um arquivo `copyright`:

```bash
$ head -n 5 /usr/share/doc/bash/copyright
This is Debian GNU/Linux's prepackaged version of the FSF's GNU Bash,
the Bourne Again SHell.
...
```

Em projetos de código-fonte, procure arquivos como `LICENSE`, `COPYING` ou o campo `license` nos metadados (`package.json`, `pyproject.toml` etc.):

```bash
$ ls ~/src/linux/COPYING ~/src/linux/LICENSES/
```

## Modelos de negócio com open source

O código ser aberto não impede a atividade comercial. Modelos cobrados no exame:

- **Suporte e serviços profissionais** — vender consultoria, treinamento e suporte (ex.: Red Hat, SUSE);
- **Subscriptions** — acesso a atualizações certificadas e SLAs;
- **Dual licensing** — o mesmo código sob GPL (grátis) ou sob licença comercial para quem não quer as obrigações do copyleft (ex.: MySQL historicamente);
- **Open core** — núcleo aberto com extensões proprietárias pagas;
- **SaaS / hosting** — oferecer o software como serviço gerenciado;
- **Doações e patrocínio** — fundações (Linux Foundation, Apache Software Foundation) financiadas por empresas.

## Pontos-chave para o exame

- "Free" em *Free Software* = **liberdade**, não gratuidade.
- **FSF** → Free Software, quatro liberdades, família **GPL**. **OSI** → Open Source Definition, aprova licenças.
- **Copyleft** (GPL): derivados devem manter a mesma licença. **Permissive** (MIT, BSD, Apache): derivados podem ser fechados.
- Kernel Linux = **GPLv2**; GPLv2 ≠ GPLv3.
- **Creative Commons** é para conteúdo criativo; módulos **NC** e **ND** tornam a licença não-livre.
- Open source é compatível com negócios: suporte, subscriptions, dual licensing, open core.

## Referências

- LPI Learning Materials — Lesson 1.3, Open Source Software and Licensing: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- LPI — Linux Essentials Objectives (010-160 v1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Project — What is Free Software?: https://www.gnu.org/philosophy/free-sw.html
- GNU Project — Licenses (GPL, LGPL, AGPL): https://www.gnu.org/licenses/
- Open Source Initiative — The Open Source Definition: https://opensource.org/osd
- Open Source Initiative — Approved Licenses: https://opensource.org/licenses
- Creative Commons — About the Licenses: https://creativecommons.org/licenses/