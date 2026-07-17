# 5.4 Special Directories and Files

## Introdução

O Linux organiza o sistema de arquivos seguindo o **Filesystem Hierarchy Standard (FHS)**, que define o propósito de cada diretório na árvore raiz (`/`). Este tópico cobre três diretórios com funções especiais (`/tmp`, `/var`, `/dev`), as **special permissions** (SUID, SGID, sticky bit) e a diferença entre **hard links** e **symbolic links**.

## Diretórios especiais

### `/tmp`

Usado para armazenar arquivos temporários criados por programas e usuários. Qualquer usuário pode escrever nele, mas isso não significa que qualquer usuário possa apagar os arquivos de outro — isso é controlado pelo **sticky bit** (ver seção abaixo).

Muitas distribuições limpam `/tmp` automaticamente no boot ou por meio de serviços como `systemd-tmpfiles`.

```bash
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 jul 12 10:03 /tmp
```

Repare no `t` final das permissões: é o sticky bit ativo.

### `/var`

Contém dados **variáveis**, ou seja, que mudam durante a operação normal do sistema: logs, spool de impressão e e-mail, cache, bancos de dados de aplicações, etc.

```bash
$ ls /var
cache  lib  local  lock  log  mail  opt  run  spool  tmp  www
```

Subdiretórios importantes:

| Diretório | Conteúdo |
|---|---|
| `/var/log` | Logs do sistema e de serviços (ex.: `/var/log/syslog`) |
| `/var/spool` | Filas de tarefas (cron, impressão, mail) |
| `/var/cache` | Dados de cache de aplicações |
| `/var/tmp` | Arquivos temporários que devem sobreviver a um reboot (diferente de `/tmp`) |

### `/dev`

Contém **device files** (arquivos de dispositivo), que representam periféricos e recursos do kernel como se fossem arquivos comuns — seguindo o princípio Unix "everything is a file".

```bash
$ ls -l /dev/sda /dev/tty1 /dev/null
brw-rw---- 1 root disk    8,   0 jul 12 09:00 /dev/sda
crw--w---- 1 root tty     4,   1 jul 12 09:00 /dev/tty1
crw-rw-rw- 1 root root    1,   3 jul 12 09:00 /dev/null
```

O primeiro caractere da listagem indica o tipo:

- `b` — **block device**: transfere dados em blocos, com acesso randômico (ex.: discos, `/dev/sda`).
- `c` — **character device**: transfere dados byte a byte, de forma sequencial (ex.: terminais, `/dev/tty1`, `/dev/null`).

Os dois números após o grupo (ex.: `8, 0`) são o **major number** (identifica o driver) e o **minor number** (identifica a instância específica do dispositivo).

Dispositivos especiais úteis:

- `/dev/null` — descarta tudo que é escrito nele; lê como EOF imediato.
- `/dev/zero` — fornece um fluxo infinito de bytes zero.
- `/dev/random` e `/dev/urandom` — geram dados aleatórios.

Hoje o conteúdo de `/dev` é gerenciado dinamicamente pelo **udev**, que cria e remove entradas conforme dispositivos são conectados ou desconectados (hotplug).

## Special permissions

Além do `r`, `w`, `x` padrão, o Linux tem três bits especiais.

### SUID (Set User ID) — valor octal 4

Aplicado a arquivos executáveis. Quando presente, o programa roda com a identidade do **dono do arquivo**, não do usuário que o executa.

```bash
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 mar  3  2024 /usr/bin/passwd
```

O `s` no lugar do `x` do dono indica SUID ativo. Isso permite que qualquer usuário execute `passwd` com privilégios de `root`, necessário para editar `/etc/shadow`.

```bash
$ chmod u+s arquivo
$ chmod 4755 arquivo
```

### SGID (Set Group ID) — valor octal 2

- Em **arquivos executáveis**: o processo roda com o grupo do dono do arquivo.
- Em **diretórios**: todo arquivo novo criado dentro herda o grupo do diretório (em vez do grupo primário do usuário que o criou) — muito usado para diretórios compartilhados entre equipes.

```bash
$ chmod g+s /projetos/equipe
$ ls -ld /projetos/equipe
drwxrwsr-x 2 root devs 4096 jul 12 10:10 /projetos/equipe
```

```bash
$ chmod 2775 diretorio
```

### Sticky bit — valor octal 1

Aplicado a diretórios com permissão de escrita para todos (como `/tmp`). Impede que um usuário apague ou renomeie arquivos de outro usuário dentro do diretório — só o dono do arquivo (ou `root`) pode fazer isso.

```bash
$ chmod +t /compartilhado
$ chmod 1777 /compartilhado
$ ls -ld /compartilhado
drwxrwxrwt 2 root root 4096 jul 12 10:15 /compartilhado
```

> Quando o bit especial está ativo mas a permissão `x` correspondente não está, a letra aparece maiúscula (`S` ou `T`) em vez de minúscula.

## Hard links e symbolic links

Ambos são criados com o comando `ln`, mas funcionam de forma bem diferente.

### Hard links

Um hard link é uma segunda entrada de diretório apontando para o **mesmo inode** (os mesmos dados no disco). Não existe "original" e "cópia" — os dois nomes são igualmente válidos.

```bash
$ echo "conteudo" > arquivo1
$ ln arquivo1 arquivo2
$ ls -li arquivo1 arquivo2
1234567 -rw-r--r-- 2 user user 10 jul 12 10:20 arquivo1
1234567 -rw-r--r-- 2 user user 10 jul 12 10:20 arquivo2
```

Note que os dois arquivos compartilham o mesmo **inode number** (`1234567`) e o **link count** aparece como `2`. Apagar `arquivo1` não afeta `arquivo2`, pois os dados só são liberados quando o link count chega a zero.

Limitações: hard links não podem apontar para diretórios e não podem atravessar diferentes sistemas de arquivos (filesystems/partições).

### Symbolic links (symlinks)

Um symlink é um arquivo especial que contém o **caminho** para outro arquivo ou diretório — é uma referência, não uma cópia dos dados.

```bash
$ ln -s /etc/nginx/nginx.conf conf_link
$ ls -l conf_link
lrwxrwxrwx 1 user user 22 jul 12 10:22 conf_link -> /etc/nginx/nginx.conf
```

O `l` inicial na listagem identifica um symlink. Diferente do hard link, ele:

- pode apontar para diretórios;
- pode atravessar filesystems diferentes;
- fica "quebrado" (**broken link**) se o alvo for removido ou movido.

```bash
$ rm /etc/nginx/nginx.conf
$ ls -l conf_link
lrwxrwxrwx 1 user user 22 jul 12 10:22 conf_link -> /etc/nginx/nginx.conf
$ cat conf_link
cat: conf_link: No such file or directory
```

### Comparando com `stat` e `file`

```bash
$ file conf_link
conf_link: symbolic link to /etc/nginx/nginx.conf

$ stat arquivo1 | grep Inode
Device: ...  Inode: 1234567  Links: 2
```

## Referências

- LPI Learning Materials — 010-160, 5.4 Special Directories and Files: https://learning.lpi.org/en/learning-materials/010-160/5/5.4/
- Filesystem Hierarchy Standard (FHS) 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- man page — `hier(7)`: https://man7.org/linux/man-pages/man7/hier.7.html
- man page — `chmod(1)`: https://man7.org/linux/man-pages/man1/chmod.1.html
- man page — `ln(1)`: https://man7.org/linux/man-pages/man1/ln.1.html
- man page — `udev(7)`: https://man7.org/linux/man-pages/man7/udev.7.html