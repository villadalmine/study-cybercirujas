# Exercícios Guiados – Tópico 2.1: Command Line Basics
**Certificação:** LPI Linux Essentials (010-160), v1.6 — Peso no exame: 3
**Fonte de referência:** https://learning.lpi.org/en/learning-materials/010-160/2/2.1/

---

## Exercício 1 — Conhecendo o shell e o prompt

1. Abra um terminal (terminal emulator) na sua distribuição Linux.
2. Observe o **prompt**. Ele geralmente mostra `usuário@hostname:diretório$`.
3. Digite `whoami` e pressione Enter. Esse comando mostra o usuário atualmente logado.
4. Digite `pwd` (print working directory) para ver o diretório atual.
5. Digite `echo Hello, Linux Essentials!` e observe a saída.

**Perguntas:**
1. Qual a diferença entre o *shell* e o *terminal emulator*?
2. O que o comando `echo` faz, de forma geral?

---

## Exercício 2 — Sintaxe da command line: command, options e arguments

1. Execute `ls` no seu diretório home.
2. Execute `ls -l`. Observe que a saída muda para o formato "long listing".
3. Execute `ls -la`. Compare com o passo anterior — repare nos arquivos ocultos (que começam com `.`).
4. Execute `ls -l /etc` passando `/etc` como **argument**.
5. Combine tudo: `ls -la /etc`.

**Perguntas:**
1. Na sintaxe geral `command [options] [arguments]`, o que é uma *option* e o que é um *argument*? Dê um exemplo com base no `ls -la /etc`.
2. É possível combinar várias *options* de uma letra só em um único traço (ex.: `-la`)? Por quê isso funciona?

---

## Exercício 3 — Command history

1. Execute alguns comandos simples, por exemplo: `pwd`, `whoami`, `echo teste`.
2. Digite `history` e observe a lista numerada dos comandos digitados anteriormente.
3. Execute `!!` (dois pontos de exclamação) para repetir o último comando.
4. Escolha um número da lista de `history` (por exemplo, `5`) e execute `!5` para repetir o comando daquela posição.
5. Pressione `Ctrl+R` e digite parte de um comando anterior (ex.: `echo`) para usar a busca reversa no *history*.

**Perguntas:**
1. Qual a utilidade prática de usar `!n` em vez de redigitar um comando inteiro?
2. Em qual arquivo o bash normalmente guarda o histórico de comandos ao encerrar a sessão?

---

## Exercício 4 — Tab completion

1. No terminal, digite `cd /et` e pressione a tecla **Tab**.
2. Observe que o shell completa automaticamente para `/etc/`.
3. Digite `ls /etc/pas` e pressione **Tab** novamente.
4. Digite apenas `who` e pressione **Tab** duas vezes seguidas (sem completar sozinho).
5. Observe a lista de comandos possíveis que começam com `who` (ex.: `whoami`, `whois`, `whoopsie`, dependendo da distribuição).

**Perguntas:**
1. O que acontece quando existe apenas uma possibilidade de *completion* versus quando existem várias?
2. Por que o *tab completion* é considerado uma boa prática para reduzir erros de digitação?

---

## Exercício 5 — Variáveis de ambiente (environment variables)

1. Execute `echo $HOME` para ver o valor da variável `HOME`.
2. Execute `echo $PATH` e observe a lista de diretórios separados por `:`.
3. Crie uma variável local: `MEUNOME="Estudante Linux"`.
4. Execute `echo $MEUNOME` para confirmar o valor.
5. Abra um novo terminal (ou uma nova sessão de shell com `bash`) e execute `echo $MEUNOME`. Observe que o valor está vazio.
6. Volte ao terminal original, execute `export MEUNOME` e repita o passo 5 (abrindo outro terminal/`bash`).
7. Execute `env` (ou `printenv`) e localize `MEUNOME` na lista.
8. Execute `unset MEUNOME` e confirme com `echo $MEUNOME` que a variável foi removida.

**Perguntas:**
1. Qual a diferença de comportamento entre uma variável **local** (shell variable) e uma variável **exportada** (environment variable) em relação a subprocessos?
2. Para que serve a variável `PATH`?

---

## Exercício 6 — Localizando comandos (which, type, whatis, man)

1. Execute `which ls` para descobrir o caminho absoluto do binário executado.
2. Execute `type ls` e compare a saída com a do passo anterior.
3. Execute `type cd`. Observe que o resultado é diferente (indica um *shell builtin*).
4. Execute `whatis ls` para ver uma descrição curta do comando.
5. Execute `man ls` e navegue pela página usando as setas ou `Espaço`/`b`. Pressione `q` para sair.
6. Dentro do `man ls`, pressione `/` e digite `recursive` para buscar esse termo na página.

**Perguntas:**
1. Por que `type cd` não retorna um caminho de arquivo como `which ls` retorna?
2. Qual comando você usaria para obter rapidamente uma descrição de uma linha sobre o que um comando faz, sem abrir a página completa do manual?

---

## Exercício 7 — Aliases

1. Execute `alias` sem argumentos para ver os *aliases* já configurados no seu shell.
2. Crie um novo alias: `alias ll='ls -la'`.
3. Execute `ll` e confirme que ele se comporta como `ls -la`.
4. Feche o terminal e abra um novo. Execute `ll` novamente.
5. Se o alias não existir mais, adicione a linha `alias ll='ls -la'` ao final do arquivo `~/.bashrc` usando um editor de texto.
6. Execute `source ~/.bashrc` e teste o comando `ll` novamente.
7. Remova o alias temporário com `unalias ll` (sem editar o `~/.bashrc`) e confirme que `ll` deixa de funcionar nessa sessão.

**Perguntas:**
1. Por que um alias criado apenas com o comando `alias` na linha de comando desaparece ao abrir um novo terminal?
2. Qual a vantagem de colocar um alias em `~/.bashrc` em vez de digitá-lo toda vez?

---

<details>
<summary><strong>Respostas</strong></summary>

**Exercício 1**
1. O *shell* é o programa interpretador de comandos (ex.: bash) que lê e executa o que você digita; o *terminal emulator* é a aplicação gráfica (janela) que fornece a interface de texto para interagir com o shell.
2. O `echo` exibe (imprime) na saída padrão o texto ou o valor passado como argumento.

**Exercício 2**
1. *Option* modifica o comportamento do comando (ex.: `-l` para formato longo, `-a` para mostrar ocultos); *argument* é o dado sobre o qual o comando atua (ex.: `/etc`, o diretório a ser listado).
2. Sim, porque *options* de uma única letra (short options) podem ser agrupadas após um único traço, como `-la` equivalendo a `-l -a`.

**Exercício 3**
1. Evita ter que redigitar comandos longos ou complexos, reduzindo erros e economizando tempo.
2. Normalmente em `~/.bash_history`.

**Exercício 4**
1. Com apenas uma possibilidade, o shell completa automaticamente o texto; com várias possibilidades, é necessário pressionar Tab duas vezes para exibir a lista de opções compatíveis.
2. Porque reduz erros de digitação em nomes de arquivos e comandos longos, além de acelerar a digitação.

**Exercício 5**
1. Uma variável local só existe na sessão de shell atual; uma variável exportada (via `export`) é herdada por processos filhos (subshells, programas executados a partir desse shell).
2. Define a lista de diretórios onde o shell procura por executáveis quando um comando é digitado sem caminho completo.

**Exercício 6**
1. Porque `cd` é um *shell builtin* (comando interno do próprio shell), não um arquivo executável separado no disco, então não há um "caminho" a mostrar.
2. `whatis`.

**Exercício 7**
1. Porque o alias definido diretamente na linha de comando existe apenas na memória daquela sessão de shell; ao abrir um novo terminal, um novo processo de shell é iniciado sem esse alias.
2. O `~/.bashrc` é lido automaticamente em cada nova sessão de shell interativa, tornando o alias permanente sem precisar redigitá-lo.

</details>