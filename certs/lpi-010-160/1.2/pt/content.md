# 1.2 Major Open Source Applications

**Peso no exame:** 2
**Certificação:** LPI Linux Essentials (010-160, versão 1.6)

---

## Visão geral

Um sistema Linux raramente é usado "vazio": o valor do sistema está nas aplicações que rodam sobre ele. Este tema apresenta as principais aplicações *open source* que você deve reconhecer no exame, agrupadas em quatro áreas:

1. Aplicações de **desktop** (escritório, navegação, multimídia)
2. Aplicações de **servidor** (web, banco de dados, compartilhamento de arquivos)
3. **Linguagens de programação** comuns no ecossistema Linux
4. **Gerenciamento de pacotes** (como o software é instalado e atualizado)

Para o exame, o importante é saber **o que cada aplicação faz** e **a qual categoria pertence** — não é preciso dominar a configuração de cada uma.

---

## 1. Aplicações de desktop

### Suítes de escritório

- **LibreOffice** — a suíte de escritório *open source* mais usada no Linux. É um *fork* do antigo OpenOffice.org e usa o formato aberto **ODF (Open Document Format)**, além de ler e gravar formatos do Microsoft Office (`.docx`, `.xlsx`, `.pptx`). Componentes que você deve reconhecer:

| Componente | Função | Equivalente proprietário |
|---|---|---|
| **Writer** | Processador de texto | Word |
| **Calc** | Planilha eletrônica | Excel |
| **Impress** | Apresentações | PowerPoint |
| **Draw** | Desenho vetorial e diagramas | Visio |
| **Base** | Banco de dados de desktop | Access |
| **Math** | Editor de fórmulas matemáticas | Equation Editor |

### Navegadores web

- **Mozilla Firefox** — navegador *open source* mantido pela Mozilla Foundation; costuma ser o navegador padrão em muitas distribuições.
- **Chromium** — a base *open source* do Google Chrome.

### E-mail

- **Mozilla Thunderbird** — cliente de e-mail *open source*, com suporte a calendário, *feeds* RSS e criptografia **OpenPGP**.

### Multimídia e gráficos

- **GIMP (GNU Image Manipulation Program)** — edição de imagens *raster* (bitmap); alternativa ao Photoshop.
- **Inkscape** — desenho vetorial (formato **SVG**); alternativa ao Illustrator.
- **Blender** — modelagem, animação e renderização **3D**.
- **ImageMagick** — manipulação de imagens **pela linha de comando**. Exemplo de conversão e redimensionamento:

  ```bash
  $ convert foto.png -resize 800x600 foto.jpg
  $ identify foto.jpg
  foto.jpg JPEG 800x600 800x600+0+0 8-bit sRGB 98.3KB 0.000u 0:00.000
  ```

- **VLC** — reprodutor multimídia que suporta praticamente qualquer formato de áudio e vídeo.
- **Audacity** — gravação e edição de **áudio**.

---

## 2. Aplicações de servidor

Servidores Linux dominam a internet, e o exame espera que você associe cada serviço ao seu papel.

### Servidores web

- **Apache HTTP Server (httpd)** — o servidor web mais tradicional; muito flexível, usa arquivos de configuração e módulos (ex.: `mod_ssl`). Suporta *virtual hosts* (vários sites no mesmo servidor).
- **NGINX** — servidor web mais recente, conhecido pelo alto desempenho; também é muito usado como *reverse proxy* e *load balancer*.

Verificando qual servidor web responde em uma máquina:

```bash
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.24.0
Content-Type: text/html
```

### Bancos de dados

- **MySQL / MariaDB** — bancos de dados relacionais (**RDBMS**) que usam SQL. O **MariaDB** é um *fork* comunitário do MySQL, criado após a aquisição deste pela Oracle. Fazem parte da clássica pilha **LAMP** (Linux, Apache, MySQL/MariaDB, PHP).
- **PostgreSQL** — RDBMS *open source* avançado, conhecido pela conformidade com padrões SQL e pela robustez.

Exemplo mínimo de uso interativo:

```bash
$ sudo mariadb
MariaDB [(none)]> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
+--------------------+
```

### Compartilhamento de arquivos

- **Samba** — implementa o protocolo **SMB/CIFS**, permitindo que um servidor Linux compartilhe arquivos e impressoras com clientes **Windows** (e até atue como controlador de domínio Active Directory).
- **NFS (Network File System)** — protocolo tradicional de compartilhamento de arquivos entre sistemas **Unix/Linux**.

Regra prática para o exame: *interoperar com Windows → Samba; entre máquinas Linux/Unix → NFS.*

### Outros serviços que podem aparecer

- **Postfix** — servidor de e-mail (**MTA**, *Mail Transfer Agent*); sucessor comum do antigo **Sendmail**.
- **Dovecot** — entrega de e-mail aos clientes via **IMAP/POP3**.
- **OpenLDAP** — serviço de diretório (autenticação centralizada) usando o protocolo **LDAP**.
- **Nextcloud / ownCloud** — plataformas de nuvem privada (arquivos, calendário, contatos) auto-hospedadas.

---

## 3. Linguagens de programação

O Linux nasceu junto com ferramentas de desenvolvimento, e várias linguagens são parte do dia a dia do sistema:

- **Shell script (Bash)** — automação de tarefas administrativas; é a linguagem "nativa" da linha de comando.
- **C** — linguagem em que o **kernel Linux** e grande parte das ferramentas GNU são escritos. Compilada com o **GCC (GNU Compiler Collection)**.
- **Python** — linguagem interpretada de propósito geral; muito usada em automação, administração de sistemas e ciência de dados.
- **Perl** — tradicional para processamento de texto e scripts administrativos.
- **PHP** — muito usada no lado servidor da web (o "P" da pilha LAMP); WordPress e MediaWiki são escritos em PHP.
- **JavaScript** — linguagem da web no lado cliente; com o **Node.js**, também roda no servidor.

Exemplo rápido — as linguagens interpretadas identificam o interpretador pelo *shebang*:

```bash
$ cat ola.py
#!/usr/bin/env python3
print("Olá, mundo!")
$ ./ola.py
Olá, mundo!
```

---

## 4. Gerenciamento de pacotes

No Linux, o software é distribuído em **pacotes**, obtidos de **repositórios** mantidos pela distribuição. O gerenciador de pacotes instala, atualiza e remove software **resolvendo dependências automaticamente**. Existem duas grandes famílias:

### Família Debian (Debian, Ubuntu, Linux Mint)

- Formato de pacote: **`.deb`**
- Ferramenta de baixo nível: **`dpkg`**
- Ferramenta de alto nível (repositórios + dependências): **APT** (`apt`, `apt-get`)

```bash
$ sudo apt update              # atualiza a lista de pacotes dos repositórios
$ sudo apt install gimp        # instala um pacote e suas dependências
$ apt search imagemagick       # procura pacotes
$ dpkg -l | grep gimp          # lista pacotes instalados
ii  gimp  2.10.36-1  amd64  GNU Image Manipulation Program
```

### Família Red Hat (RHEL, Fedora, CentOS Stream, openSUSE*)

- Formato de pacote: **`.rpm`**
- Ferramenta de baixo nível: **`rpm`**
- Ferramenta de alto nível: **`dnf`** (sucessora do `yum`); no openSUSE, **`zypper`**

```bash
$ sudo dnf install vlc         # instala um pacote e suas dependências
$ dnf search blender           # procura pacotes
$ rpm -q firefox               # consulta se um pacote está instalado
firefox-128.0-1.fc44.x86_64
```

\* O openSUSE usa pacotes `.rpm`, mas com o gerenciador `zypper`.

### Resumo para memorizar

| Família | Pacote | Baixo nível | Alto nível |
|---|---|---|---|
| Debian/Ubuntu | `.deb` | `dpkg` | `apt` / `apt-get` |
| Red Hat/Fedora | `.rpm` | `rpm` | `dnf` (antes `yum`) |
| openSUSE | `.rpm` | `rpm` | `zypper` |

Formatos mais novos e independentes de distribuição — **Flatpak**, **Snap** e **AppImage** — empacotam a aplicação junto com suas dependências e funcionam em qualquer distribuição.

---

## Pontos-chave para o exame

- Associar aplicação ↔ função: GIMP = imagens raster, Inkscape = vetorial, Blender = 3D, VLC = multimídia, Audacity = áudio.
- LibreOffice: saber o nome e o papel de cada componente (Writer, Calc, Impress, Draw, Base, Math).
- Servidores: Apache e NGINX = web; MySQL/MariaDB e PostgreSQL = banco de dados; Samba = compartilhamento com Windows (SMB); NFS = compartilhamento Unix/Linux; Postfix = e-mail.
- MariaDB é um *fork* do MySQL; LibreOffice é um *fork* do OpenOffice.org.
- Pacotes: `.deb` + `dpkg`/`apt` na família Debian; `.rpm` + `rpm`/`dnf` na família Red Hat.
- As ferramentas de alto nível (`apt`, `dnf`) usam repositórios e resolvem dependências; as de baixo nível (`dpkg`, `rpm`) operam sobre arquivos de pacote individuais.

---

## Referências

- LPI Learning Materials — Topic 1.2, Major Open Source Applications: https://learning.lpi.org/en/learning-materials/010-160/1/1.2/
- Objetivos oficiais do exame Linux Essentials (010-160): https://www.lpi.org/our-certifications/exam-010-objectives/
- LibreOffice — documentação: https://documentation.libreoffice.org/
- GIMP — documentação: https://docs.gimp.org/
- Apache HTTP Server — documentação: https://httpd.apache.org/docs/
- NGINX — documentação: https://nginx.org/en/docs/
- MariaDB — documentação: https://mariadb.com/kb/en/documentation/
- PostgreSQL — documentação: https://www.postgresql.org/docs/
- Samba — documentação: https://www.samba.org/samba/docs/
- Debian — manual do APT: https://www.debian.org/doc/manuals/debian-faq/pkgtools.en.html
- Fedora — documentação do DNF: https://docs.fedoraproject.org/en-US/quick-docs/dnf/