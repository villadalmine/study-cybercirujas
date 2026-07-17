# Exercícios – Tópico 5.4: Special Directories and Files

**Certificação:** LPI Linux Essentials (010-160, versão 1.6)
**Peso no exame:** 1

## Exercício 1 — O sticky bit em `/tmp` e `/var/tmp`

1. Abra um terminal e liste as permissões do diretório `/tmp`:
   ```
   ls -ld /tmp
   ```
2. Observe a última letra do bloco de permissões (algo como `drwxrwxrwt`). Repare no `t` no lugar do `x` na posição de "outros" (*others*).
3. Repita o comando para `/var/tmp`:
   ```
   ls -ld /var/tmp
   ```
4. Como um usuário comum (não `root`), crie um arquivo de teste dentro de `/tmp`:
   ```
   touch /tmp/meu_teste.txt
   ```
5. Confirme o dono do arquivo recém-criado:
   ```
   ls -l /tmp/meu_teste.txt
   ```
6. Peça a outro usuário do sistema (ou use `sudo -u outro_usuario`) para tentar apagar `meu_teste.txt` sem ser o dono nem `root`:
   ```
   sudo -u outro_usuario rm /tmp/meu_teste.txt
   ```
7. Observe a mensagem de erro retornada.

**Perguntas:**
- O que o `t` no final das permissões de `/tmp` representa, e por que esse bit é essencial em um diretório compartilhado por todos os usuários do sistema?
- Por que a operação do passo 6 falhou, mesmo `/tmp` tendo permissão de escrita (`w`) para "outros"?

## Exercício 2 — Set User ID (SUID) e Set Group ID (SGID)

1. Liste as permissões do binário `passwd`, que precisa gravar em `/etc/shadow`:
   ```
   ls -l /usr/bin/passwd
   ```
2. Observe o `s` no lugar do `x` na posição do dono (*owner*).
3. Verifique quem é o dono do arquivo:
   ```
   ls -l /usr/bin/passwd | awk '{print $3}'
   ```
4. Crie um arquivo próprio e aplique o SUID bit usando notação simbólica:
   ```
   touch script_teste.sh
   chmod u+s script_teste.sh
   ls -l script_teste.sh
   ```
5. Aplique o SUID usando notação octal (o SUID corresponde ao dígito `4` que precede as permissões numéricas), por exemplo `4755`:
   ```
   chmod 4755 script_teste.sh
   ls -l script_teste.sh
   ```
6. Remova o SUID e aplique o SGID (dígito `2`) no mesmo arquivo:
   ```
   chmod 2755 script_teste.sh
   ls -l script_teste.sh
   ```

**Perguntas:**
- Qual é a diferença prática entre o SUID bit e o SGID bit quando aplicados a um arquivo executável?
- Ao rodar `passwd` com o SUID ativo, com qual identidade (UID efetivo) o processo é executado?
- Qual seria o dígito octal para aplicar SUID + SGID + sticky bit ao mesmo tempo, mantendo `rwxr-xr-x` como permissões base?

## Exercício 3 — SGID em diretórios

1. Crie um diretório de teste compartilhado:
   ```
   mkdir /tmp/projeto_equipe
   ```
2. Aplique o SGID nesse diretório:
   ```
   chmod g+s /tmp/projeto_equipe
   ls -ld /tmp/projeto_equipe
   ```
3. Dentro do diretório, crie um arquivo novo:
   ```
   touch /tmp/projeto_equipe/arquivo1.txt
   ls -l /tmp/projeto_equipe/arquivo1.txt
   ```
4. Compare o grupo (*group*) do arquivo criado com o grupo primário do usuário atual (`id`) e com o grupo do diretório pai.

**Perguntas:**
- Qual grupo foi atribuído a `arquivo1.txt`: o grupo primário do usuário que o criou, ou o grupo do diretório `/tmp/projeto_equipe`? Por quê?
- Em que situação do dia a dia (times, projetos compartilhados) o SGID em diretórios é útil?

## Exercício 4 — Hard links e symbolic links

1. Crie um arquivo original:
   ```
   echo "conteúdo original" > original.txt
   ```
2. Verifique o número de inode e o link count do arquivo:
   ```
   ls -li original.txt
   ```
3. Crie um hard link para esse arquivo:
   ```
   ln original.txt link_duro.txt
   ls -li original.txt link_duro.txt
   ```
4. Crie um symbolic link (*soft link*) para o mesmo arquivo:
   ```
   ln -s original.txt link_simbolico.txt
   ls -li original.txt link_simbolico.txt
   ```
5. Apague o arquivo original:
   ```
   rm original.txt
   ```
6. Verifique o conteúdo dos dois links restantes:
   ```
   cat link_duro.txt
   cat link_simbolico.txt
   ```

**Perguntas:**
- Depois do passo 5, por que `link_duro.txt` ainda mostra o conteúdo original, enquanto `link_simbolico.txt` resulta em erro (*broken link*)?
- O que aconteceu com o link count (segunda coluna de `ls -l`) do inode compartilhado entre `original.txt` e `link_duro.txt` antes de o original ser apagado?
- Um hard link pode apontar para um arquivo em outra partição/filesystem? E um symbolic link?

## Exercício 5 — Localizando arquivos com permissões especiais

1. Localize todos os arquivos com o SUID bit ativo no sistema (pode levar alguns segundos):
   ```
   find / -perm -4000 -type f 2>/dev/null
   ```
2. Localize arquivos com o SGID bit ativo:
   ```
   find / -perm -2000 -type f 2>/dev/null
   ```
3. Localize diretórios com o sticky bit ativo:
   ```
   find / -perm -1000 -type d 2>/dev/null
   ```

**Perguntas:**
- Por que redirecionamos o `stderr` para `/dev/null` (`2>/dev/null`) nesses comandos `find`?
- Cite dois riscos de segurança associados a um binário com SUID pertencente ao `root`.

## Respostas

<details>
<summary>Clique para ver as respostas</summary>

**Exercício 1**
- O `t` é o **sticky bit**. Em um diretório com permissão de escrita para todos (como `/tmp`), ele impede que um usuário apague ou renomeie arquivos de outro usuário, mesmo tendo permissão de escrita no diretório. Somente o dono do arquivo, o dono do diretório ou `root` podem removê-lo.
- A operação falhou porque, apesar do bit `w` do diretório permitir criar/remover entradas em geral, o sticky bit restringe a remoção/renomeação de um arquivo específico apenas ao seu dono (ou a `root`).

**Exercício 2**
- SUID faz um executável rodar com a identidade (UID efetivo) do **dono do arquivo**, independentemente de quem o executa. SGID faz o processo (ou, em diretórios, os novos arquivos criados dentro deles) herdar o **grupo (GID)** do dono/diretório, em vez do grupo de quem executa.
- O processo roda com o UID efetivo de `root` (dono de `/usr/bin/passwd`), o que permite gravar em `/etc/shadow` mesmo sendo iniciado por um usuário comum.
- O dígito octal seria `7755`: `4` (SUID) + `2` (SGID) + `1` (sticky) = `7`, seguido das permissões `rwxr-xr-x`.

**Exercício 3**
- O grupo atribuído é o do **diretório pai** (`projeto_equipe`), não o grupo primário do usuário, porque o SGID em um diretório faz com que todo novo arquivo/subdiretório criado dentro dele herde o grupo do diretório.
- É útil quando vários usuários de um mesmo grupo (ex.: um time de desenvolvimento) precisam compartilhar arquivos em um diretório comum sem precisar rodar `chgrp` manualmente a cada novo arquivo.

**Exercício 4**
- `link_duro.txt` continua funcionando porque um **hard link** aponta diretamente para o mesmo **inode** que armazena os dados; o arquivo só é de fato removido do disco quando o link count do inode chega a zero. `link_simbolico.txt` quebra porque um **symbolic link** é apenas um arquivo separado que guarda o *caminho* (path) para `original.txt`; quando esse caminho deixa de existir, o link fica "pendurado" (*dangling/broken*).
- O link count subiu de `1` para `2` após a criação do hard link, pois ambos os nomes (`original.txt` e `link_duro.txt`) referenciam o mesmo inode.
- Um hard link **não pode** cruzar filesystems/partições diferentes, pois inodes só têm significado dentro do mesmo filesystem. Um symbolic link **pode** apontar para qualquer caminho, inclusive em outro filesystem, outro disco, ou até um caminho inexistente.

**Exercício 5**
- Para descartar mensagens de erro do tipo "Permission denied", que aparecem ao tentar acessar diretórios que o usuário atual não tem permissão de leitura, mantendo a saída limpa apenas com resultados válidos.
- Dois riscos: (1) se o binário tiver uma falha (buffer overflow, injeção de comando etc.), um usuário comum pode explorá-la para obter privilégios de `root`; (2) um binário SUID mal configurado ou desnecessário aumenta a superfície de ataque do sistema, permitindo escalonamento de privilégios mesmo sem uma falha "clássica" (ex.: scripts SUID chamando outros comandos sem caminho absoluto).

</details>

## Fontes
- LPI Learning Materials, "5.4 Special Directories and Files": https://learning.lpi.org/en/learning-materials/010-160/5/5.4/