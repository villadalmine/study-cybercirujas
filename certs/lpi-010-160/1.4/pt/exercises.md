# Exercícios — 1.4 ICT Skills and Working in Linux

Fonte de referência: https://learning.lpi.org/en/learning-materials/010-160/1/1.4/

## Exercício 1 — Identificando seu desktop environment e abrindo um terminal

1. Observe a tela inicial do seu sistema Linux e identifique o desktop environment em uso (GNOME, KDE Plasma, Xfce etc.) observando o menu de aplicativos e a barra de tarefas.
2. Abra o terminal emulator através do menu de aplicativos (procure por "Terminal", "Console" ou o nome específico, como "GNOME Terminal", "Konsole" ou "xterm").
3. No terminal, execute `echo $XDG_CURRENT_DESKTOP` para confirmar via linha de comando qual desktop environment está ativo.
4. Execute `echo $SHELL` para verificar qual shell está configurado como padrão para o seu usuário.

**Perguntas**
- Qual é a diferença entre um desktop environment e um terminal emulator?
- Por que a variável `$SHELL` mostra o shell configurado, e não necessariamente o shell em execução naquele momento?

## Exercício 2 — Gerenciamento básico de arquivos: GUI vs command line

1. Usando o file manager gráfico (Nautilus, Dolphin, Thunar etc.), crie uma nova pasta chamada `ict-skills` dentro da sua pasta pessoal (Home).
2. Dentro dela, crie um novo arquivo de texto vazio chamado `notas.txt` usando o próprio file manager.
3. Abra o terminal e navegue até essa pasta com `cd ~/ict-skills`.
4. Liste o conteúdo com `ls -l` e confirme que o arquivo criado pela GUI aparece na saída do comando.
5. Renomeie o arquivo para `anotacoes.txt` usando o terminal com `mv notas.txt anotacoes.txt`.
6. Volte ao file manager gráfico e atualize a visualização da pasta para confirmar que o nome mudou.

**Perguntas**
- O que esse exercício demonstra sobre a relação entre operações feitas em uma GUI e no command line?
- Qual comando poderia ter sido usado no passo 2 para criar o arquivo diretamente pelo terminal, sem usar a GUI?

## Exercício 3 — Buscando ajuda sem sair do terminal

1. Execute `man ls` para abrir a página de manual do comando `ls`.
2. Navegue pela página com as setas ou `Page Down`/`Page Up`, e pressione `q` para sair.
3. Execute `ls --help` e compare a saída com a do comando `man ls`.
4. Execute `apropos "list directory"` (ou `man -k "list directory"`) para buscar comandos relacionados por palavra-chave.
5. Execute `whatis ls` para obter uma descrição de uma linha sobre o comando.

**Perguntas**
- Qual a diferença prática entre usar `comando --help` e `man comando`?
- Em que situação o comando `apropos` é mais útil do que já saber o nome exato do comando que você precisa?

## Exercício 4 — Identificando seu usuário e privilégios básicos de segurança

1. Execute `whoami` para confirmar o nome do usuário atualmente logado.
2. Execute `id` para ver o user ID (UID), group ID (GID) e os grupos aos quais seu usuário pertence.
3. Execute `sudo -l` (pode ser solicitada sua senha) para listar quais comandos seu usuário tem permissão de executar como superusuário.
4. Compare o UID do seu usuário com o UID do usuário `root` executando `id root`.

**Perguntas**
- Por que é considerada uma boa prática de segurança usar `sudo` em vez de fazer login diretamente como `root`?
- O que o UID 0 representa em um sistema Linux?

## Exercício 5 — Conceitos básicos de conectividade

1. Execute `ip addr show` (ou `ip a`) para listar as interfaces de rede do seu sistema e seus endereços IP.
2. Identifique qual interface corresponde à conexão local (loopback, `lo`) e qual corresponde à sua conexão de rede real (Ethernet ou Wi-Fi).
3. Execute `ping -c 4 lpi.org` para testar a conectividade com um host externo através da internet (WAN).
4. Observe se sua interface de rede está conectada a uma LAN (rede local, como sua casa ou escritório) ou diretamente à internet via WAN.

**Perguntas**
- Qual é a diferença entre LAN e WAN?
- Por que a interface `lo` (loopback) sempre aparece mesmo sem uma conexão de rede física ativa?

<details>
<summary>Respostas</summary>

**Exercício 1**
- Um desktop environment é o conjunto completo de componentes gráficos (janelas, ícones, menus, painéis) que formam a interface visual do sistema operacional; um terminal emulator é apenas uma aplicação dentro desse ambiente que dá acesso a uma shell de linha de comando.
- Porque `$SHELL` é definida no momento do login e reflete o shell padrão configurado para o usuário (geralmente em `/etc/passwd`), não necessariamente o shell em execução no processo atual — para isso, `echo $0` ou `ps -p $$` seriam mais precisos.

**Exercício 2**
- Demonstra que a GUI e o command line operam sobre o mesmo sistema de arquivos subjacente: mudanças feitas em uma interface são imediatamente visíveis na outra, pois ambas manipulam os mesmos arquivos reais no disco.
- O comando `touch notas.txt` poderia ter sido usado para criar o arquivo vazio diretamente pelo terminal.

**Exercício 3**
- `comando --help` normalmente mostra um resumo rápido das opções (flags) do comando, enquanto `man comando` abre uma documentação completa, com explicações detalhadas, exemplos e seções como "SEE ALSO".
- `apropos` é mais útil quando você sabe o que quer fazer, mas não lembra ou não sabe o nome exato do comando — ele busca por palavras-chave nas descrições curtas de todos os comandos documentados no sistema.

**Exercício 4**
- Porque usar `sudo` mantém um registro (log) de quais comandos foram executados com privilégios elevados e por qual usuário, além de limitar o tempo em que esses privilégios ficam ativos — reduzindo o risco de erros acidentais ou uso indevido, em comparação a permanecer logado como `root` o tempo todo.
- UID 0 é o identificador reservado para o superusuário (`root`), que tem acesso irrestrito a todos os recursos do sistema.

**Exercício 5**
- LAN (Local Area Network) é uma rede restrita a uma área física limitada, como uma casa, escritório ou prédio; WAN (Wide Area Network) conecta redes distantes entre si, sendo a internet o maior exemplo de WAN.
- Porque `lo` é uma interface de rede virtual, implementada em software pelo próprio kernel do Linux, usada para comunicação interna do sistema consigo mesmo — não depende de hardware físico de rede.

</details>