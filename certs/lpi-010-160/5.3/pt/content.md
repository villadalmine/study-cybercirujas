# 5.3 Managing File Permissions and Ownership

**Peso no exame:** 2
**Exame:** LPI Linux Essentials 010-160 (versão 1.6)

---

## Por que isso importa

Linux é um sistema multiusuário: várias contas (humanas ou de serviços do sistema) convivem na mesma máquina e podem, em princípio, acessar os mesmos arquivos. Para que isso não seja um caos, todo arquivo e todo diretório carrega duas informações de segurança: um **owner** (o usuário dono) e um **group** (o grupo dono), além de um conjunto de **permissions** que dizem o que o owner, o group e todos os demais (**others**) podem fazer com aquele arquivo. O Tema 5.3 cobre como ler essa informação com `ls -l`, como interpretá-la e como alterá-la com `chmod`, `chown` e `chgrp`.

---

## Lendo permissões com `ls -l`

```console
$ ls -l
-rw-r--r-- 1 ana  staff  2048 jul  9 14:10 relatorio.txt
drwxr-x--- 2 ana  staff  4096 jul  9 13:55 projetos
-rwxr-xr-x 1 root root  16384 jul  8 09:20 backup.sh
lrwxrwxrwx 1 ana  staff     7 jul  9 14:12 atual -> projetos
```

A primeira coluna tem 10 caracteres. Tomando `-rwxr-xr--` como exemplo:

| Posição | Valor | Significado |
|---|---|---|
| 1 | `-` | Tipo do arquivo |
| 2–4 | `rwx` | Permissões do **user** (owner) |
| 5–7 | `r-x` | Permissões do **group** |
| 8–10 | `r--` | Permissões de **others** |

**Tipos de arquivo mais comuns na primeira posição:**

| Caractere | Tipo |
|---|---|
| `-` | Arquivo regular |
| `d` | Diretório |
| `l` | Symbolic link |
| `b` | Block device |
| `c` | Character device |
| `s` | Socket |
| `p` | Named pipe (FIFO) |

Depois da string de permissões vêm, em ordem: o número de hard links, o **owner**, o **group**, o tamanho em bytes, a data de modificação e o nome. Para ver o dono e os grupos da sua própria sessão:

```console
$ id
uid=1000(ana) gid=1000(ana) groups=1000(ana),10(wheel),972(docker)
```

### O que `r`, `w` e `x` significam

O mesmo trio de letras tem sentidos diferentes conforme o alvo seja um arquivo ou um diretório — ponto clássico de pegadinha no exame:

| Permissão | Em um arquivo | Em um diretório |
|---|---|---|
| `r` (read) | Ler o conteúdo do arquivo | Listar os nomes dentro do diretório (`ls`) |
| `w` (write) | Modificar o conteúdo | Criar, renomear ou apagar arquivos dentro dele |
| `x` (execute) | Executar como programa/script | Entrar no diretório (`cd`) e acessar o que está dentro |

Dois detalhes que caem com frequência:

- **Apagar um arquivo depende da permissão `w` sobre o diretório que o contém**, não sobre o arquivo em si — remover um nome é uma alteração no diretório.
- Um diretório com `r` mas sem `x` permite listar os nomes mas não entrar neles; com `x` mas sem `r`, dá para acessar arquivos cujo nome já se conhece, mas não listar o diretório. Na prática, diretórios quase sempre têm `r` e `x` juntos.

### Qual conjunto vale para mim?

O kernel verifica as três categorias **na ordem** e aplica a primeira que combinar: se você é o owner, só o trio de user importa; senão, se você pertence ao group do arquivo, vale o trio de group; caso contrário, vale others. O usuário **root** ignora essa verificação por completo.

---

## Notação octal (numérica)

Cada trio pode ser reduzido a um único dígito somando os valores dos bits ativos:

| Permissão | Valor |
|---|---|
| `r` | 4 |
| `w` | 2 |
| `x` | 1 |

Assim, `rwx` = 4+2+1 = **7**, `rw-` = 4+2 = **6**, `r-x` = 4+1 = **5**, `r--` = **4**, `---` = **0**. Um modo completo usa três dígitos, na ordem user–group–others:

| Modo | Simbólico | Uso típico |
|---|---|---|
| `755` | `rwxr-xr-x` | Diretórios, scripts, executáveis |
| `644` | `rw-r--r--` | Arquivos comuns (documentos, configs) |
| `700` | `rwx------` | Diretórios privados (ex.: `~/.ssh`) |
| `600` | `rw-------` | Arquivos privados (chaves, credenciais) |
| `777` | `rwxrwxrwx` | Todo mundo pode tudo — quase sempre um erro |

Vale treinar a conversão nos dois sentidos: `-rwxr-x---` equivale a `750`, e `664` corresponde a `rw-rw-r--`.

---

## Alterando permissões: `chmod`

`chmod` (change mode) aceita notação octal ou simbólica. Só o owner do arquivo (ou root) pode alterar suas permissões.

### Modo octal

Define os nove bits de uma vez:

```console
$ chmod 640 relatorio.txt
$ ls -l relatorio.txt
-rw-r----- 1 ana staff 2048 jul  9 14:20 relatorio.txt
```

### Modo simbólico

Ajusta bits específicos sem mexer no resto. A sintaxe é *quem* + *operador* + *o quê*:

- **Quem:** `u` (user/owner), `g` (group), `o` (others), `a` (all — os três)
- **Operador:** `+` adiciona, `-` remove, `=` define exatamente
- **O quê:** `r`, `w`, `x`

```console
$ chmod u+x backup.sh          # torna executável para o owner
$ chmod go-w compartilhado.txt # remove write de group e others
$ chmod a=r notas.md           # todos ficam só com leitura: r--r--r--
$ chmod u=rwx,g=rx,o= privado/ # equivalente a chmod 750 privado/
```

### Aplicando recursivamente

A opção `-R` propaga a mudança para um diretório e tudo dentro dele:

```console
$ chmod -R go-rwx ~/privado
```

Cuidado com modos octais recursivos: `chmod -R 644 pasta/` removeria o bit `x` também dos diretórios, tornando-os inacessíveis (sem `x` não dá para entrar neles). A notação simbólica com `X` maiúsculo — que só adiciona execute a diretórios e a arquivos que já tenham algum bit de execução — evita esse problema: `chmod -R u=rwX,go=rX docs/`.

---

## Alterando ownership: `chown` e `chgrp`

Todo arquivo pertence a um usuário e a um grupo. Um arquivo recém-criado pertence a quem o criou e, normalmente, ao grupo primário desse usuário.

### `chown` (change owner)

Altera o owner, o group, ou ambos de uma vez. **Trocar o owner exige privilégios de root**:

```console
$ sudo chown bruna relatorio.txt              # troca só o owner
$ sudo chown bruna:devs relatorio.txt         # troca owner e group juntos
$ sudo chown :devs relatorio.txt              # troca só o group
$ sudo chown -R bruna:bruna /home/bruna       # recursivo, ex.: após restaurar um backup
$ ls -l relatorio.txt
-rw-r----- 1 bruna devs 2048 jul  9 14:30 relatorio.txt
```

(O separador também pode ser um ponto: `bruna.devs`.)

### `chgrp` (change group)

Altera apenas o group dono do arquivo. Um usuário comum pode usar `chgrp` sem root, desde que seja owner do arquivo **e** pertença ao grupo de destino:

```console
$ groups
ana staff devs
$ chgrp devs relatorio.txt
```

`chgrp` também aceita `-R` para mudanças recursivas. `chown :grupo arquivo` e `chgrp grupo arquivo` fazem a mesma coisa.

---

## Permissões especiais: setuid, setgid, sticky bit

Além dos nove bits básicos existem três bits especiais, exibidos nas posições de execute do `ls -l` e representados por um quarto dígito octal, à esquerda dos outros três (setuid = 4, setgid = 2, sticky = 1).

| Bit | Aparece como | Em arquivos | Em diretórios |
|---|---|---|---|
| **setuid** (`4xxx`) | `s` no slot de execute do user | O programa roda com os privilégios do **owner** do arquivo, não de quem o executou | Sem efeito |
| **setgid** (`2xxx`) | `s` no slot de execute do group | O programa roda com os privilégios do **group** do arquivo | Arquivos novos criados dentro herdam o group do diretório — ótimo para pastas compartilhadas de equipe |
| **sticky bit** (`1xxx`) | `t` no slot de execute de others | Sem efeito relevante no Linux atual | Só o owner do arquivo (ou root) pode apagar ou renomear arquivos dentro, mesmo que o diretório seja gravável por todos |

Exemplos clássicos, verificáveis em qualquer sistema:

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 59976 jun 30 2026 /usr/bin/passwd

$ ls -ld /tmp
drwxrwxrwt 20 root root 4096 jul  9 08:00 /tmp
```

`passwd` tem o bit setuid porque precisa gravar em `/etc/shadow`, arquivo que usuários comuns não podem escrever diretamente — rodando com privilégios de root, o programa consegue atualizar a senha em nome do usuário. `/tmp` é gravável por todos, mas o sticky bit impede que um usuário apague arquivos temporários de outro.

Configurando esses bits:

```console
$ chmod u+s programa        # setuid            (ou chmod 4755 programa)
$ chmod g+s pasta_equipe/    # setgid em diretório (ou chmod 2775 pasta_equipe/)
$ chmod +t area_publica/     # sticky bit         (ou chmod 1777 area_publica/)
```

Um `s`/`t` minúsculo indica que o bit de execute correspondente também está ativo; um `S`/`T` maiúsculo avisa que o bit especial está ativo mas o execute, não.

---

## Permissões padrão: `umask`

Arquivos novos nunca nascem com permissões arbitrárias: o **umask** da shell define quais bits são *removidos* dos valores-padrão (`666` para arquivos, `777` para diretórios). Com o umask comum de `022`:

```console
$ umask
0022
$ touch novo_arquivo && mkdir nova_pasta
$ ls -ld novo_arquivo nova_pasta
-rw-r--r-- 1 ana staff    0 jul  9 15:00 novo_arquivo
drwxr-xr-x 2 ana staff 4096 jul  9 15:00 nova_pasta
```

Arquivos saem com `666 − 022 = 644` e diretórios com `777 − 022 = 755`. Um umask mais restritivo, como `077`, resulta em `600`/`700`, mantendo tudo privado ao owner. Rodar `umask` seguido de um valor altera a máscara apenas para a sessão de shell atual.

---

## Arquivos ocultos

Um arquivo cujo nome começa com ponto (`.`) fica **oculto**: o `ls` não o exibe por padrão. Não é uma questão de permissão, e sim de convenção, mas costuma aparecer junto com o tema de visibilidade de arquivos:

```console
$ ls -a ~
.  ..  .bashrc  .profile  documentos  projetos
```

---

## Resumo de comandos

| Tarefa | Comando |
|---|---|
| Ver permissões e ownership | `ls -l arquivo` / `ls -ld diretorio` |
| Ver usuário e grupos da sessão | `id` / `groups` |
| Definir permissões exatas (octal) | `chmod 640 arquivo` |
| Ajustar bits específicos (simbólico) | `chmod g+w,o-r arquivo` |
| Trocar owner (exige root) | `sudo chown usuario arquivo` |
| Trocar owner e group juntos | `sudo chown usuario:grupo arquivo` |
| Trocar só o group | `chgrp grupo arquivo` |
| Aplicar recursivamente | acrescentar `-R` a `chmod`, `chown` ou `chgrp` |
| Ver/definir a máscara padrão | `umask` / `umask 077` |

**Pontos-chave para o exame:**

- Decodificar strings de `ls -l` de cabeça: tipo + três trios (user, group, others).
- Converter entre notação simbólica e octal nos dois sentidos (`rwxr-x--x` ↔ `751`).
- Saber que `r`, `w`, `x` significam coisas diferentes em arquivos e em diretórios.
- `chmod` muda permissões; `chown` muda o owner (e opcionalmente o group, exige root para o owner); `chgrp` muda só o group.
- Reconhecer setuid (`s`, 4), setgid (`s`, 2) e sticky bit (`t`, 1), com os exemplos canônicos `/usr/bin/passwd` e `/tmp`.
- `umask` subtrai bits de `666`/`777` para gerar as permissões padrão de arquivos e diretórios novos.

---

## Referências

- LPI Learning Materials — Tema 5.3, Managing File Permissions and Ownership: https://learning.lpi.org/en/learning-materials/010-160/5/5.3/
- Objetivos do exame LPI Linux Essentials 010-160 (versão 1.6): https://www.lpi.org/our-certifications/exam-objectives/linux-essentials-exam-010-objectives/
- GNU Coreutils manual — `chmod`: https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- GNU Coreutils manual — `chown`: https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- GNU Coreutils manual — `chgrp`: https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html
- GNU Coreutils manual — `ls`: https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html
- Linux man-pages — `chmod(1)`: https://man7.org/linux/man-pages/man1/chmod.1.html
- Linux man-pages — `chown(1)`: https://man7.org/linux/man-pages/man1/chown.1.html
- Bash Reference Manual — builtin `umask`: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
