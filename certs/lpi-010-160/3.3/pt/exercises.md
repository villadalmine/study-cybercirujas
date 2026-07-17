# Exercícios: Turning Commands into a Script

**Certificação:** LPI Linux Essentials (010-160, v1.6) — Tópico 3.3
**Peso no exame:** 4
**Fonte de referência:** [learning.lpi.org — 3.3 Turning Commands into a Script](https://learning.lpi.org/en/learning-materials/010-160/3/3.3/)

---

## Exercício 1 — Do `history` para um script

1. Abra o terminal e rode alguns comandos simples, por exemplo:
   ```bash
   date
   whoami
   echo "Fim da execução"
   ```
2. Veja o `history` desses comandos:
   ```bash
   history | tail -n 5
   ```
3. Crie um arquivo chamado `meuscript.sh` com um text editor (`nano`, `vim` ou o de sua preferência) e copie os três comandos anteriores para dentro dele, um por linha.
4. Salve o arquivo e confira o conteúdo:
   ```bash
   cat meuscript.sh
   ```

**Perguntas:**
- Um arquivo de texto contendo apenas comandos, sem nenhuma linha especial no início, já é reconhecido automaticamente como um shell script executável pelo sistema?
- Qual comando usado no passo 2 permite reaproveitar comandos já digitados, evitando redigitá-los manualmente ao montar um script?

---

## Exercício 2 — Shebang e permissão de execução

1. Edite `meuscript.sh` e adicione como **primeira linha** do arquivo:
   ```bash
   #!/bin/bash
   ```
2. Tente executar o script diretamente:
   ```bash
   ./meuscript.sh
   ```
3. Observe a mensagem de erro (algo como `Permission denied`).
4. Verifique as permissões atuais do arquivo:
   ```bash
   ls -l meuscript.sh
   ```
5. Conceda permissão de execução ao dono do arquivo:
   ```bash
   chmod u+x meuscript.sh
   ```
6. Execute novamente:
   ```bash
   ./meuscript.sh
   ```

**Perguntas:**
- Qual é a função da linha `#!/bin/bash` (shebang) no início de um script?
- Por que o script não executou no passo 2, mesmo já contendo comandos válidos?
- Qual seria uma forma alternativa de executar `meuscript.sh` sem usar `chmod`, invocando o interpretador diretamente?

---

## Exercício 3 — Usando variáveis dentro do script

1. Edite `meuscript.sh` e substitua o conteúdo por:
   ```bash
   #!/bin/bash
   NOME="Linux Essentials"
   echo "Estudando para a certificação $NOME"
   echo "Data atual: $(date +%F)"
   ```
2. Execute o script:
   ```bash
   ./meuscript.sh
   ```
3. Modifique a variável `NOME` para outro valor e execute novamente, confirmando que a saída muda de acordo.

**Perguntas:**
- Por que `$NOME` é interpretado dentro das aspas duplas em `echo`, mas não seria interpretado se estivesse entre aspas simples (`'$NOME'`)?
- O que a sintaxe `$(comando)` faz dentro de um script?

---

## Exercício 4 — Positional parameters (argumentos do script)

1. Edite `meuscript.sh` com o seguinte conteúdo:
   ```bash
   #!/bin/bash
   echo "Nome do script: $0"
   echo "Primeiro argumento: $1"
   echo "Segundo argumento: $2"
   echo "Quantidade de argumentos: $#"
   echo "Todos os argumentos: $@"
   ```
2. Execute o script passando dois argumentos:
   ```bash
   ./meuscript.sh alpha beta
   ```
3. Execute novamente sem nenhum argumento:
   ```bash
   ./meuscript.sh
   ```

**Perguntas:**
- O que acontece com `$2` quando o script é chamado sem um segundo argumento?
- Qual a diferença entre `$0` e `$1`?
- Se você quisesse saber quantos argumentos foram passados ao script, qual variável usaria?

---

## Exercício 5 — Exit status (`$?`)

1. Edite `meuscript.sh` com este conteúdo:
   ```bash
   #!/bin/bash
   ls /diretorio/que/nao/existe
   echo "Exit status do comando anterior: $?"
   ```
2. Execute o script:
   ```bash
   ./meuscript.sh
   ```
3. Agora rode diretamente no terminal, fora do script:
   ```bash
   echo "Teste"
   echo $?
   ```

**Perguntas:**
- O que representa o valor retornado por `$?`?
- Qual é o exit status esperado quando um comando é executado com sucesso?
- Por que é importante consultar `$?` logo depois do comando que se quer verificar, e não depois de outro comando no meio do caminho?

---

## Exercício 6 — Executando o script de diferentes formas

1. Com o `meuscript.sh` do Exercício 3 ainda salvo, tente rodá-lo das seguintes formas e compare os resultados:
   ```bash
   bash meuscript.sh
   sh meuscript.sh
   ./meuscript.sh
   meuscript.sh
   ```
2. Verifique se o diretório atual (`.`) está incluído na variável `PATH`:
   ```bash
   echo $PATH
   ```

**Perguntas:**
- Por que o comando `meuscript.sh` (sem `./` na frente) normalmente falha com `command not found`, mesmo o script tendo permissão de execução?
- Ao rodar com `bash meuscript.sh`, a linha do shebang (`#!/bin/bash`) ainda é necessária? Por quê?

---

<details>
<summary>Ver respostas</summary>

**Exercício 1**
- Não. Um arquivo de texto com comandos não é automaticamente um script executável; ele precisa de permissão de execução (e, na prática, de um shebang) para ser tratado como um programa pelo shell.
- O comando `history`, que lista os comandos digitados anteriormente e permite copiá-los/reaproveitá-los ao montar um script.

**Exercício 2**
- O shebang indica ao kernel qual interpretador deve ser usado para executar o restante do arquivo — nesse caso, `/bin/bash`.
- Porque o arquivo ainda não tinha permissão de execução (`x`) atribuída; um arquivo de texto comum não pode ser executado como `./arquivo`, mesmo contendo comandos válidos.
- Executando `bash meuscript.sh` (ou `sh meuscript.sh`), passando o arquivo como argumento para o interpretador — nesse caso a permissão de execução não é necessária, só permissão de leitura.

**Exercício 3**
- Aspas duplas (`"..."`) permitem a expansão de variáveis dentro delas; aspas simples (`'...'`) tratam o conteúdo como texto literal, sem expandir `$NOME`.
- `$(comando)` é a *command substitution*: executa o comando e substitui a expressão pela saída (stdout) desse comando.

**Exercício 4**
- `$2` fica vazio (string vazia), pois não existe segundo argumento passado.
- `$0` é o nome do próprio script (como foi chamado); `$1` é o primeiro argumento passado a ele.
- A variável `$#`, que contém a quantidade de argumentos recebidos.

**Exercício 5**
- O exit status (código de saída) do último comando executado: `0` indica sucesso, qualquer valor diferente de `0` indica algum tipo de erro ou falha.
- `0`.
- Porque `$?` é sobrescrita a cada novo comando executado; se outro comando rodar entre o comando de interesse e a consulta a `$?`, o valor original é perdido.

**Exercício 6**
- Porque o diretório atual (`.`) geralmente não está incluído na variável `PATH` por padrão (por segurança), então o shell não encontra `meuscript.sh` a menos que o caminho seja explicitado com `./`.
- Sim, ela ainda pode estar presente, mas é ignorada nesse modo de execução: ao chamar `bash meuscript.sh`, é o `bash` informado explicitamente na linha de comando que interpreta o arquivo, não o shebang.

</details>