# Tópico 4.3 – Where Data is Stored (LPI Linux Essentials, exame 010-160, v1.6)

> Fonte de referência: https://learning.lpi.org/en/learning-materials/010-160/4/4.3/

## Exercício 1 – Explorando a Filesystem Hierarchy Standard (FHS)

1. Abra um terminal e liste os diretórios da raiz do sistema:
   ```bash
   ls -l /
   ```
2. Consulte a página de manual que descreve o padrão de organização dos diretórios:
   ```bash
   man hier
   ```
3. Dentro do `man hier`, procure as entradas referentes a `/etc`, `/var`, `/home` e `/proc` (use `/etc` e pressione Enter para buscar).
4. Saia do manual pressionando `q`.

**Perguntas de verificação**
- O que é a FHS e por que distribuições Linux diferentes conseguem manter uma estrutura de diretórios previsível?
- Qual comando usado acima permite consultar a documentação oficial sobre a hierarquia de diretórios sem sair do terminal?

---

## Exercício 2 – Conteúdo de `/etc`, `/var` e `/home`

1. Liste os arquivos de configuração do sistema:
   ```bash
   ls /etc | head -20
   ```
2. Verifique o conteúdo típico de logs e dados variáveis:
   ```bash
   ls /var/log
   ```
3. Liste os diretórios pessoais dos usuários:
   ```bash
   ls /home
   ```
4. Compare o tamanho ocupado por cada um desses diretórios:
   ```bash
   du -sh /etc /var /home 2>/dev/null
   ```

**Perguntas de verificação**
- Que tipo de arquivo você esperaria encontrar em `/etc` e por que eles normalmente não mudam de tamanho com o uso diário do sistema?
- Por que `/var` tende a crescer continuamente enquanto o sistema está em uso?

---

## Exercício 3 – `/proc` como filesystem virtual

1. Veja as informações do processador lidas diretamente do kernel:
   ```bash
   cat /proc/cpuinfo
   ```
2. Veja as informações de memória:
   ```bash
   cat /proc/meminfo
   ```
3. Verifique o tamanho reportado para o diretório `/proc`:
   ```bash
   du -sh /proc 2>/dev/null
   ```
4. Repita o passo 3 depois de abrir e fechar um programa qualquer (por exemplo, `sleep 100 &` seguido de `ls /proc`) e observe que aparece uma nova entrada numérica correspondente ao PID do processo.

**Perguntas de verificação**
- Por que os arquivos dentro de `/proc` não ocupam espaço real em disco, mesmo que `cat` consiga exibir seu conteúdo?
- O que representam os diretórios numerados dentro de `/proc`?

---

## Exercício 4 – Identificando block devices

1. Liste todos os block devices reconhecidos pelo kernel:
   ```bash
   lsblk
   ```
2. Veja detalhes sobre partições, tamanhos e tipos de filesystem:
   ```bash
   sudo blkid
   ```
3. Liste a tabela de partições de um disco específico (ajuste `/dev/sda` conforme seu sistema):
   ```bash
   sudo fdisk -l /dev/sda
   ```

**Perguntas de verificação**
- Qual a diferença entre um block device como `/dev/sda` e uma partição como `/dev/sda1`?
- Qual comando mostra o UUID e o tipo de filesystem de cada partição?

---

## Exercício 5 – Mount e unmount manuais

1. Conecte um pendrive USB e identifique o dispositivo correspondente:
   ```bash
   lsblk
   ```
2. Crie um ponto de montagem (mount point) dedicado:
   ```bash
   sudo mkdir -p /mnt/usb
   ```
3. Monte o dispositivo manualmente (substitua `sdb1` pelo nome real):
   ```bash
   sudo mount /dev/sdb1 /mnt/usb
   ```
4. Confirme que a montagem foi bem-sucedida:
   ```bash
   df -h /mnt/usb
   ```
5. Desmonte o dispositivo com segurança antes de remover o pendrive:
   ```bash
   sudo umount /mnt/usb
   ```

**Perguntas de verificação**
- Por que é necessário desmontar (`umount`) um dispositivo antes de removê-lo fisicamente?
- O que aconteceria se você tentasse montar um dispositivo em um mount point que já está sendo usado por outro filesystem?

---

## Exercício 6 – Montagem persistente com `/etc/fstab`

1. Descubra o UUID da partição que você deseja montar automaticamente:
   ```bash
   sudo blkid /dev/sdb1
   ```
2. Abra o arquivo de configuração de montagens do sistema:
   ```bash
   sudo nano /etc/fstab
   ```
3. Adicione uma linha (sem executar, apenas como exercício de leitura) no formato:
   ```
   UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /mnt/usb  ext4  defaults  0  2
   ```
4. Sem reiniciar o sistema, teste se a entrada está sintaticamente correta:
   ```bash
   sudo mount -a
   ```

**Perguntas de verificação**
- Por que usar o UUID em vez do nome do dispositivo (`/dev/sdb1`) é considerado mais confiável em `/etc/fstab`?
- Para que serve o comando `mount -a` depois de editar o `/etc/fstab`?

---

## Exercício 7 – Uso de espaço em disco

1. Veja o espaço total, usado e disponível em todos os filesystems montados:
   ```bash
   df -h
   ```
2. Veja quanto espaço um diretório específico está ocupando:
   ```bash
   du -sh /home/*
   ```
3. Combine os dois comandos para identificar se algum filesystem está perto da capacidade máxima:
   ```bash
   df -h | grep -v tmpfs
   ```

**Perguntas de verificação**
- Qual a diferença entre o que `df` reporta e o que `du` reporta?
- Por que filesystems do tipo `tmpfs` costumam ser ignorados ao analisar uso real de disco?

---

<details>
<summary><strong>Respostas</strong></summary>

**Exercício 1**
- A FHS (Filesystem Hierarchy Standard) define nomes e propósitos padronizados para os diretórios principais do sistema, permitindo que qualquer distribuição Linux mantenha uma estrutura previsível — o que facilita para administradores e programas saberem onde encontrar configurações, binários e dados.
- `man hier` exibe a documentação oficial da hierarquia de diretórios do sistema.

**Exercício 2**
- `/etc` contém arquivos de configuração do sistema e de aplicativos, geralmente arquivos de texto editados manualmente; eles não crescem com o uso porque não armazenam dados gerados durante a execução do sistema.
- `/var` cresce continuamente porque armazena dados variáveis, como logs, filas de e-mail, caches e bancos de dados que mudam constantemente enquanto o sistema roda.

**Exercício 3**
- `/proc` é um filesystem virtual gerado dinamicamente pelo kernel em memória; seus arquivos não existem em disco, apenas representam informações do kernel e dos processos em tempo real.
- Cada diretório numerado em `/proc` corresponde ao PID (Process ID) de um processo em execução, contendo informações sobre esse processo específico.

**Exercício 4**
- `/dev/sda` representa o disco inteiro (block device), enquanto `/dev/sda1` representa uma partição específica dentro desse disco.
- `blkid` mostra o UUID e o tipo de filesystem (por exemplo, ext4, xfs, vfat) de cada partição.

**Exercício 5**
- É preciso desmontar antes de remover fisicamente porque o sistema operacional pode manter dados em buffer (cache de escrita) que ainda não foram gravados no dispositivo; remover sem desmontar pode causar perda ou corrupção de dados.
- O sistema recusaria a montagem, retornando erro, pois um mount point só pode ter um filesystem montado por vez.

**Exercício 6**
- O UUID é único e não muda, enquanto o nome do dispositivo (`/dev/sdb1`) pode variar dependendo da ordem em que os discos são detectados no boot, especialmente com dispositivos USB.
- `mount -a` monta todos os filesystems listados em `/etc/fstab` que ainda não estão montados, permitindo testar a configuração sem reiniciar o sistema.

**Exercício 7**
- `df` mostra o uso de espaço por filesystem montado (visão do dispositivo/partição); `du` mostra o uso de espaço por arquivos e diretórios específicos (visão do conteúdo).
- Filesystems `tmpfs` residem na memória RAM, não em disco persistente, então seu "uso" não reflete consumo real de armazenamento físico.

</details>