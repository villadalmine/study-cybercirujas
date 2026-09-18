# 701.3 Gestión de código fuente — Ejercicios guiados

**Examen:** LPI DevOps Tools Engineer, 701-100, versión 2.0.0
**Peso del tema:** 10
**Referencia del objetivo:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estos ejercicios son prácticos. Cada paso está pensado para ejecutarse en una shell real; se muestra la salida esperada para que puedas distinguir "funcionó" de "parecía que funcionaba". Los hashes de objeto en tu máquina **van a diferir** de los que se imprimen acá — un hash de commit incluye el autor, el committer y ambas marcas de tiempo, así que no hay dos personas que produzcan el mismo ID de commit a partir del mismo archivo. Los hashes de blob, en cambio, dependen solo del contenido y *sí* van a coincidir exactamente.

**Entorno necesario**

- Un host Linux con `git` ≥ 2.34 (`gpg.format=ssh` y `git switch`/`git restore` como comandos estables) y OpenSSH ≥ 8.2.
- No hace falta acceso a la red para ningún ejercicio. El ejercicio 7 construye su propio "servidor" como repositorio bare en el sistema de archivos local; el ejercicio 9 explica el único comando que llegaría a una forge real y cómo leer su salida.

---

## Ejercicio 0 — Construir un sandbox aislado

Estás por cambiar la configuración global de Git a propósito. No hagas eso con tu cuenta real. Git 2.32+ respeta `GIT_CONFIG_GLOBAL`, que permite redirigir `~/.gitconfig` a un archivo descartable durante toda la sesión.

### Pasos

1. Creá el sandbox y fijá una configuración global aislada:

```bash
mkdir -p /tmp/lpi-701.3 && cd /tmp/lpi-701.3
export GIT_CONFIG_GLOBAL=/tmp/lpi-701.3/gitconfig
export GIT_CONFIG_SYSTEM=/dev/null
touch "$GIT_CONFIG_GLOBAL"
git --version
```

```
git version 2.47.1
```

2. Definí la identidad y los valores por defecto que todo repositorio de producción debería tener:

```bash
git config --global user.name  "Ada Lovelace"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
git config --global core.editor "vi"
git config --global pull.ff only
git config --global merge.conflictstyle zdiff3
git config --global rerere.enabled true
```

3. Inspeccioná de dónde viene realmente cada ajuste:

```bash
git config --list --show-origin --show-scope | head -n 12
```

```
global	file:/tmp/lpi-701.3/gitconfig	user.name=Ada Lovelace
global	file:/tmp/lpi-701.3/gitconfig	user.email=ada@example.com
global	file:/tmp/lpi-701.3/gitconfig	init.defaultbranch=main
global	file:/tmp/lpi-701.3/gitconfig	core.editor=vi
global	file:/tmp/lpi-701.3/gitconfig	pull.ff=only
global	file:/tmp/lpi-701.3/gitconfig	merge.conflictstyle=zdiff3
global	file:/tmp/lpi-701.3/gitconfig	rerere.enabled=true
```

4. Mirá el archivo que Git acaba de escribir:

```bash
cat "$GIT_CONFIG_GLOBAL"
```

```ini
[user]
	name = Ada Lovelace
	email = ada@example.com
[init]
	defaultBranch = main
[core]
	editor = vi
[pull]
	ff = only
[merge]
	conflictstyle = zdiff3
[rerere]
	enabled = true
```

### Preguntas de verificación

- **Q0.1** Git lee la configuración desde cuatro ámbitos. Nombralos en el orden en que se aplican, y decí cuál gana cuando la misma clave está definida en varios.
- **Q0.2** `init.defaultbranch` se imprime en minúsculas aunque escribiste `init.defaultBranch`. ¿Qué parte de una clave de configuración distingue mayúsculas y minúsculas y qué parte no?
- **Q0.3** ¿Qué falla convierte `pull.ff = only` de un evento silencioso en uno ruidoso?
- **Q0.4** Un repositorio debe commitearse bajo una identidad laboral mientras que la identidad global de la máquina es personal. ¿Qué único comando define eso, y qué archivo escribe?

---

## Ejercicio 1 — La base de datos de objetos: qué *es* un repositorio

Git es un almacén de objetos direccionado por contenido con una interfaz de control de versiones encima. Todo en este ejercicio usa comandos de plumbing, porque el porcelain oculta justamente la parte que el examen pregunta.

### Pasos

1. Creá el repositorio y mirá el esqueleto que Git deja:

```bash
cd /tmp/lpi-701.3
git init app
cd app
find .git -maxdepth 1 | sort
```

```
.git
.git/HEAD
.git/config
.git/description
.git/hooks
.git/info
.git/objects
.git/refs
```

2. Leé `HEAD` antes de que exista commit alguno:

```bash
cat .git/HEAD
ls .git/refs/heads
git status --short --branch
```

```
ref: refs/heads/main
## No commits yet on main
```

Fijate que `.git/refs/heads` está **vacío**. `HEAD` apunta a una rama que todavía no existe — eso es lo que significa "unborn branch".

3. Calculá el hash de un contenido sin tocar el repositorio, y después tocándolo:

```bash
echo "hello world" | git hash-object --stdin
echo "hello world" | git hash-object --stdin -w
git count-objects -v
```

```
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
count: 1
size: 4
in-pack: 0
packs: 0
size-pack: 0
prune-packable: 0
garbage: 0
size-garbage: 0
```

Este hash es idéntico en todas las máquinas del planeta. Es `sha1("blob 12\0hello world\n")`.

4. Encontrá el objeto suelto en disco y volvé a leerlo:

```bash
find .git/objects -type f
git cat-file -t 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -s 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
git cat-file -p 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
```

```
.git/objects/3b/18e512dba79e4c8300dd08aea6d4d9e3d8f6b7
blob
12
hello world
```

5. Construí un commit real y recorré el grafo hacia abajo desde él:

```bash
mkdir -p src
echo "hello world" > src/greet.txt
git add src/greet.txt
git commit -m "feat: add greeting"
git cat-file -p HEAD
```

```
tree 9f6b2c1a4e0d5f3b8a7c6e2d1f0a9b8c7d6e5f4a
author Ada Lovelace <ada@example.com> 1789700000 +0000
committer Ada Lovelace <ada@example.com> 1789700000 +0000

feat: add greeting
```

6. Descendé por los árboles hasta el blob que creaste en el paso 3:

```bash
git cat-file -p HEAD^{tree}
git cat-file -p HEAD:src
git cat-file -p HEAD:src/greet.txt
```

```
040000 tree 2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f	src
100644 blob 3b18e512dba79e4c8300dd08aea6d4d9e3d8f6b7	greet.txt
hello world
```

7. Confirmá qué es realmente una rama, y contá los objetos que produjo el commit:

```bash
cat .git/refs/heads/main
git rev-parse HEAD
git count-objects -v | head -n 2
```

```
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
7a1f0c9d2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f70
count: 4
size: 16
```

### Preguntas de verificación

- **Q1.1** Nombrá los cuatro tipos de objeto de Git e indicá, para cada uno, qué almacena.
- **Q1.2** En el paso 6 el blob `3b18e5…` aparece con el nombre `greet.txt`, pero en el paso 3 lo creaste desde stdin sin ningún nombre de archivo, y el hash es el mismo. ¿Dónde se guarda el nombre del archivo, y qué consecuencia práctica tiene eso para un repositorio que contiene el mismo archivo de 10 MB bajo cinco rutas distintas?
- **Q1.3** Después de un commit de un archivo, `count: 4`. ¿Cuáles son esos cuatro objetos?
- **Q1.4** `.git/refs/heads/main` contiene 40 caracteres hexadecimales y nada más. Explicá en una oración por qué "crear una rama en Git es barato" es una afirmación sobre este archivo.
- **Q1.5** `git cat-file -p HEAD` imprime un commit que no contiene ninguna línea `parent`. ¿Qué te dice eso sobre este commit, y cuántas líneas `parent` tendría un commit de merge de dos ramas?
- **Q1.6** ¿Cuál es la diferencia entre `git hash-object --stdin` y `git hash-object --stdin -w`, y por qué le importa al examen?

---

## Ejercicio 2 — Los tres árboles: working tree, index, HEAD

Casi todo mensaje confuso de Git es una afirmación sobre la *diferencia entre dos de estos tres*. Este ejercicio hace visible cada diferencia.

### Pasos

1. Modificá el archivo trackeado y agregá uno sin trackear:

```bash
cd /tmp/lpi-701.3/app
printf 'hello world\ngoodbye world\n' > src/greet.txt
echo "*.log" > notes.tmp
git status --short --branch
```

```
## main
 M src/greet.txt
?? notes.tmp
```

Leé las dos columnas de status: la columna **izquierda** es `HEAD → index`, la columna **derecha** es `index → working tree`. El espacio seguido de `M` significa "staged: nada, sin stagear: modificado".

2. Stageá el archivo y mirá cómo se intercambian las columnas:

```bash
git add src/greet.txt
git status --short
```

```
M  src/greet.txt
?? notes.tmp
```

3. Modificalo otra vez *después* de stagearlo — ahora los tres árboles discrepan:

```bash
echo "third line" >> src/greet.txt
git status --short
```

```
MM src/greet.txt
?? notes.tmp
```

4. Pedí cada diff explícitamente:

```bash
git diff --stat            # index  -> working tree
git diff --cached --stat   # HEAD   -> index
git diff HEAD --stat       # HEAD   -> working tree
```

```
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 1 +
 1 file changed, 1 insertion(+)
 src/greet.txt | 2 ++
 1 file changed, 2 insertions(+)
```

5. Mirá el index como estructura de datos, no como concepto:

```bash
git ls-files --stage
```

```
100644 5f1c9a0b3d2e4f6a8b7c9d0e1f2a3b4c5d6e7f80 0	src/greet.txt
```

El número de stage `0` significa "sin conflicto". Vas a ver los stages 1, 2 y 3 en el ejercicio 4.

6. Stageá selectivamente con control a nivel de hunk — el hábito que mantiene revisable a un commit:

```bash
git reset                      # unstage everything, keep the working tree
git add --patch src/greet.txt
```

Git muestra un hunk por vez y pregunta:

```
Stage this hunk [y,n,q,a,d,s,e,?]?
```

Respondé `s` para dividir el hunk cuando contiene cambios no relacionados, `y` para stagear, `n` para saltear, `q` para parar.

7. Escribí reglas de ignorado reales, incluida una negación, y demostrá qué regla coincidió:

```bash
cat > .gitignore <<'EOF'
# build artefacts
*.log
*.tmp
/dist/
!important.tmp
EOF
touch important.tmp debug.log
mkdir dist && touch dist/app.bin
git status --short --ignored
git check-ignore -v debug.log important.tmp dist/app.bin
```

```
 M src/greet.txt
?? .gitignore
?? important.tmp
!! debug.log
!! dist/
.gitignore:2:*.log	debug.log
.gitignore:5:!important.tmp	important.tmp
.gitignore:4:/dist/	dist/app.bin
```

8. Demostrá el límite de `.gitignore` — solo gobierna archivos **sin trackear**:

```bash
git add -f notes.tmp && git commit -q -m "chore: add notes.tmp by mistake"
echo "still tracked" >> notes.tmp
git status --short
```

```
 M notes.tmp
```

9. Dejá de trackearlo sin borrarlo, y después mové un archivo trackeado:

```bash
git rm --cached notes.tmp
git status --short
git mv src/greet.txt src/greeting.txt
git status --short
```

```
D  notes.tmp
?? notes.tmp
D  notes.tmp
R  src/greet.txt -> src/greeting.txt
```

Compará con `git rm notes.tmp`, que además habría eliminado el archivo del disco.

10. Commiteá el estado y limpiá el sandbox:

```bash
git add -A
git commit -q -m "chore: add ignore rules, untrack notes.tmp, rename greeting"
git clean -nd
```

```
Would remove dist/
```

`-n` es una simulación. `git clean -fd` borra; `git clean -fdx` borra también los archivos ignorados, y es el comando que elimina un `.env` que nunca se commiteó.

### Preguntas de verificación

- **Q2.1** `MM src/greet.txt` — describí el contenido del archivo en cada uno de los tres árboles en ese momento.
- **Q2.2** Ejecutaste `git add file`, después editaste el archivo otra vez, y después ejecutaste `git commit -m "..."` sin `-a`. ¿Qué versión queda en el commit?
- **Q2.3** Un colega agregó `secrets.env` a `.gitignore` pero `git status` lo sigue reportando como modificado ante cada cambio. Diagnosticalo, y dá el comando exacto que lo arregla conservando su copia local del archivo.
- **Q2.4** `git check-ignore -v` imprimió `.gitignore:5:!important.tmp`. Enunciá la regla de orden que hace funcionar una negación, y explicá por qué `!dist/app.bin` **no** volvería a incluir ese archivo dada la regla `/dist/`.
- **Q2.5** ¿Qué cambia la `/` inicial en `/dist/` respecto de escribir `dist/`?
- **Q2.6** Git no tiene un tipo de objeto "rename", y sin embargo `git status` imprimió `R src/greet.txt -> src/greeting.txt`. ¿Cómo lo sabe Git?
- **Q2.7** ¿Qué comando descarta cambios *stageados pero no commiteados* sin tocar el working tree, y cuál descarta cambios del working tree sin tocar el index? Dá tanto la forma con `git restore` como la forma antigua con `git reset` / `git checkout`.

---

## Ejercicio 3 — Leer el historial como un operador

En un incidente no leés el historial: lo consultás.

### Pasos

1. Construí un historial que valga la pena consultar:

```bash
cd /tmp/lpi-701.3/app
for i in 1 2 3; do
  echo "line $i" >> src/greeting.txt
  git commit -q -am "feat: add line $i"
done
echo 'TIMEOUT = 30' > src/config.py
git add src/config.py && git commit -q -m "feat: introduce TIMEOUT"
sed -i 's/TIMEOUT = 30/TIMEOUT = 5/' src/config.py
git commit -q -am "perf: lower TIMEOUT to 5"
```

2. La única invocación de log que vale la pena memorizar:

```bash
git log --oneline --graph --decorate --all
```

```
* 1d4e7a9 (HEAD -> main) perf: lower TIMEOUT to 5
* 0c3b6f8 feat: introduce TIMEOUT
* 9b2a5e7 feat: add line 3
* 8a1f4d6 feat: add line 2
* 7f0e3c5 feat: add line 1
* 6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
* 5d8c1a3 chore: add notes.tmp by mistake
* 7a1f0c9 feat: add greeting
```

3. Formato personalizado, que es lo que canalizás hacia un reporte:

```bash
git log --pretty=format:'%h %ad %an %s' --date=short -n 3
```

```
1d4e7a9 2026-09-18 Ada Lovelace perf: lower TIMEOUT to 5
0c3b6f8 2026-09-18 Ada Lovelace feat: introduce TIMEOUT
9b2a5e7 2026-09-18 Ada Lovelace feat: add line 3
```

4. El pickaxe — "¿qué commit cambió la cantidad de apariciones de esta cadena?":

```bash
git log --oneline -S 'TIMEOUT = 30'
git log --oneline -G 'TIMEOUT'
```

```
0c3b6f8 feat: introduce TIMEOUT
1d4e7a9 perf: lower TIMEOUT to 5
0c3b6f8 feat: introduce TIMEOUT
```

5. Seguí un archivo a través de su renombre, y atribuí una línea individual:

```bash
git log --oneline --follow -- src/greeting.txt
git blame -L 1,2 -- src/greeting.txt
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
7f0e3c5 feat: add line 1
6e9d2b4 chore: add ignore rules, untrack notes.tmp, rename greeting
7a1f0c9 feat: add greeting
7a1f0c9 (Ada Lovelace 2026-09-18 00:00:00 +0000 1) hello world
6e9d2b4 (Ada Lovelace 2026-09-18 00:00:00 +0000 2) goodbye world
```

6. Rangos y sintaxis de revisiones — la parte que se lee mal en el examen:

```bash
git log --oneline 7f0e3c5..9b2a5e7      # exclusive of the left side
git rev-parse --short HEAD~2 HEAD^ 'HEAD@{1}'
git diff --stat HEAD~3 HEAD
```

```
9b2a5e7 feat: add line 3
8a1f4d6 feat: add line 2
9b2a5e7
0c3b6f8
0c3b6f8
 src/config.py   | 1 +
 src/greeting.txt | 1 +
 2 files changed, 2 insertions(+)
```

7. Atribución y volumen, para una nota de versión:

```bash
git shortlog -sn --no-merges
git log --oneline --since='1 day ago' --author='Ada' | wc -l
```

```
     8	Ada Lovelace
8
```

### Preguntas de verificación

- **Q3.1** Explicá la diferencia entre `git log A..B` y `git log A...B`, y entre `git diff A..B` y `git diff A...B`.
- **Q3.2** ¿Cuál es la diferencia entre `HEAD^`, `HEAD~`, `HEAD^2` y `HEAD~2`? ¿Para qué tipo de commit resuelve siquiera `HEAD^2`?
- **Q3.3** `-S 'TIMEOUT = 30'` devolvió un commit; `-G 'TIMEOUT'` devolvió dos. Explicá con precisión qué coincide cada opción.
- **Q3.4** ¿Por qué `git log -- src/greeting.txt` se detiene en `6e9d2b4` mientras que `git log --follow -- src/greeting.txt` continúa más allá?
- **Q3.5** `HEAD@{1}` y `HEAD~1` resolvieron acá a commits distintos en general. ¿Qué dos cosas distintas nombran, y cuál puede alcanzar un commit que no está en ninguna rama?
- **Q3.6** Sabés que un test pasa en `7f0e3c5` y falla en `HEAD`. Escribí la secuencia de tres comandos que hace que Git encuentre automáticamente el primer commit malo con un script `./run-test.sh`.

---

## Ejercicio 4 — Ramas, merges y resolución de conflictos

### Pasos

1. Creá una rama y comprobá que "crear una rama" es una escritura de 41 bytes:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/tls
cat .git/HEAD
cat .git/refs/heads/feature/tls
git branch -vv
```

```
ref: refs/heads/feature/tls
1d4e7a9...
  main          1d4e7a9 perf: lower TIMEOUT to 5
* feature/tls   1d4e7a9 perf: lower TIMEOUT to 5
```

2. Commiteá en la rama, y después mergeá de vuelta con la política por defecto:

```bash
echo 'TLS_MIN_VERSION = "1.2"' >> src/config.py
git commit -q -am "feat(tls): require TLS 1.2"
git switch main
git merge feature/tls
```

```
Updating 1d4e7a9..4b7c2e1
Fast-forward
 src/config.py | 1 +
 1 file changed, 1 insertion(+)
```

No se creó ningún commit de merge: `main` no se había movido, así que Git simplemente avanzó el puntero.

3. Rehacelo con la política que la mayoría de los flujos de release realmente quiere:

```bash
git reset --hard 1d4e7a9
git merge --no-ff feature/tls -m "Merge branch 'feature/tls'"
git log --oneline --graph -n 4
git cat-file -p HEAD | head -n 3
```

```
*   e2f5a80 (HEAD -> main) Merge branch 'feature/tls'
|\
| * 4b7c2e1 (feature/tls) feat(tls): require TLS 1.2
|/
* 1d4e7a9 perf: lower TIMEOUT to 5
tree 3a6b9c2d5e8f1a4b7c0d3e6f9a2b5c8d1e4f7a0b
parent 1d4e7a9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a4f3e
parent 4b7c2e1d0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c
```

Dos líneas `parent`. Esa es la definición completa de un commit de merge.

4. Ahora fabricá un conflicto genuino:

```bash
git switch -c fix/timeout main
sed -i 's/TIMEOUT = 5/TIMEOUT = 15/' src/config.py
git commit -q -am "fix: raise TIMEOUT to 15 for slow upstreams"

git switch main
sed -i 's/TIMEOUT = 5/TIMEOUT = 2/' src/config.py
git commit -q -am "perf: cut TIMEOUT to 2"

git merge fix/timeout
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

5. Inspeccioná el conflicto como dato, no como texto:

```bash
git status --short
git diff --name-only --diff-filter=U
git ls-files --stage src/config.py
```

```
UU src/config.py
src/config.py
100644 8c1d0a9b7e6f5d4c3b2a1908f7e6d5c4b3a29180 1	src/config.py
100644 6b0c9f8a7d6e5c4b3a29180f7e6d5c4b3a291807 2	src/config.py
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 3	src/config.py
```

El stage 1 es el merge base, el stage 2 es **ours** (`main`), y el stage 3 es **theirs** (`fix/timeout`).

6. Leé los marcadores de conflicto — con `merge.conflictstyle=zdiff3` del ejercicio 0 también se muestra la base:

```bash
cat src/config.py
```

```
<<<<<<< HEAD
TIMEOUT = 2
||||||| 1d4e7a9
TIMEOUT = 5
=======
TIMEOUT = 15
>>>>>>> fix/timeout
TLS_MIN_VERSION = "1.2"
```

7. Resolvé deliberadamente, y después terminá el merge:

```bash
git show :1:src/config.py     # base
git show :2:src/config.py     # ours
git show :3:src/config.py     # theirs
sed -i '1,6c\TIMEOUT = 15' src/config.py
git add src/config.py
git ls-files --stage src/config.py
git commit --no-edit
```

```
100644 4a9b8e7c6d5f4a3b2019f8e7d6c5b4a39281706f 0	src/config.py
[main 5c8d1e2] Merge branch 'fix/timeout'
```

Una vez stageado, los tres stages en conflicto colapsan de nuevo al stage `0`. Eso es, mecánicamente, lo que significa "`git add` marca un conflicto como resuelto".

8. Practicá la salida de emergencia y los atajos masivos:

```bash
git switch -c conflict/demo 1d4e7a9
sed -i 's/TIMEOUT = 5/TIMEOUT = 99/' src/config.py
git commit -q -am "chore: demo conflict"
git switch main
git merge conflict/demo
git checkout --ours -- src/config.py   # keep main's version wholesale
git merge --abort
git status --short
```

```
Auto-merging src/config.py
CONFLICT (content): Merge conflict in src/config.py
Automatic merge failed; fix conflicts and then commit the result.
```

(`git status --short` no imprime nada: `--abort` restauró el estado previo al merge, incluido el working tree.)

9. Limpiá las ramas mergeadas como lo hace un release engineer:

```bash
git branch --merged main
git branch -d feature/tls fix/timeout
git branch -D conflict/demo
```

```
  feature/tls
  fix/timeout
* main
Deleted branch feature/tls (was 4b7c2e1).
Deleted branch fix/timeout (was 3e9f7b2).
Deleted branch conflict/demo (was 2a8e6c4).
```

### Preguntas de verificación

- **Q4.1** ¿Por qué el paso 2 hizo fast-forward mientras que al paso 3 se lo pudo forzar a crear un commit de merge? Enunciá la condición precisa bajo la cual Git hace fast-forward.
- **Q4.2** Un equipo exige que cada feature llegue como un merge identificable en `main`. ¿Qué opción de merge lo impone, y qué dos claves de configuración lo vuelven el comportamiento por defecto de un repositorio?
- **Q4.3** En un index en conflicto, ¿qué contienen los stages 1, 2 y 3? Durante un `git merge`, ¿qué rama es "ours"? Durante un `git rebase`, ¿qué rama es "ours" — y por qué eso es lo opuesto a lo que la mayoría espera?
- **Q4.4** `git checkout --ours -- file` y `git merge -X ours` suenan parecido y no lo son. Explicá la diferencia y cuándo es correcto cada uno.
- **Q4.5** Resolviste un conflicto editando el archivo pero te olvidaste de ejecutar `git add`. ¿Qué hace `git commit`, y qué cambia exactamente `git add` en el index?
- **Q4.6** `git branch -d` se negó a borrar una rama; `git branch -D` la borró. ¿Qué verifica `-d`, y después de un `-D` sobre una rama con trabajo no mergeado, ¿el trabajo se perdió? ¿Cómo lo recuperarías?
- **Q4.7** Activaste `rerere.enabled=true` en el ejercicio 0. ¿Qué hace, y por qué importa en una rama de larga vida que se rebasea a diario?

---

## Ejercicio 5 — Rebase, cherry-pick y reescribir el historial de forma segura

### Pasos

1. Preparó una rama que quedó atrasada:

```bash
cd /tmp/lpi-701.3/app
git switch -c feature/metrics
echo 'METRICS_PORT = 9090' >> src/config.py
git commit -q -am "feat(metrics): expose port 9090"
echo 'METRICS_PATH = "/metrics"' >> src/config.py
git commit -q -am "feat(metrics): set scrape path"

git switch main
echo 'LOG_LEVEL = "info"' >> src/logging.py
git add src/logging.py && git commit -q -m "feat(log): add log level"
git log --oneline --graph --all -n 5
```

```
* 7d2c9f1 (HEAD -> main) feat(log): add log level
| * 9e4a1b8 (feature/metrics) feat(metrics): set scrape path
| * 6c1f8d3 feat(metrics): expose port 9090
|/
* 5c8d1e2 Merge branch 'fix/timeout'
```

2. Rebaseá, y registrá los hashes antes y después:

```bash
git switch feature/metrics
git log --oneline -n 2
git rebase main
git log --oneline -n 3
cat .git/ORIG_HEAD
```

```
9e4a1b8 feat(metrics): set scrape path
6c1f8d3 feat(metrics): expose port 9090
Successfully rebased and updated refs/heads/feature/metrics.
b3f7a02 (HEAD -> feature/metrics) feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
7d2c9f1 (main) feat(log): add log level
9e4a1b8...
```

Los mensajes de commit y los diffs son idénticos; **los hashes cambiaron**. Rebase no mueve commits: los reproduce como objetos nuevos.

3. Rebase interactivo con autosquash — el flujo para "la revisión pidió un arreglo en el commit 2 de 5":

```bash
echo 'METRICS_PORT = 9091' >> src/config.py
git commit -q --fixup a91c5e4
git log --oneline -n 3
GIT_SEQUENCE_EDITOR=cat git rebase -i --autosquash main
```

```
d0e8b41 (HEAD -> feature/metrics) fixup! feat(metrics): expose port 9090
b3f7a02 feat(metrics): set scrape path
a91c5e4 feat(metrics): expose port 9090
pick a91c5e4 feat(metrics): expose port 9090
fixup d0e8b41 fixup! feat(metrics): expose port 9090
pick b3f7a02 feat(metrics): set scrape path
```

`GIT_SEQUENCE_EDITOR=cat` imprime la lista de tareas en vez de abrir un editor, y luego el rebase procede con ese plan. Volvé a ejecutarlo sin eso para editar interactivamente; los verbos son `pick`, `reword`, `edit`, `squash`, `fixup`, `drop`, `exec`.

4. Trasplantá un rango sobre una base distinta con `--onto`:

```bash
git switch -c feature/dash feature/metrics
echo 'DASH_URL = "http://localhost:3000"' >> src/config.py
git commit -q -am "feat(dash): add dashboard URL"
git rebase --onto main feature/metrics feature/dash
git log --oneline --graph --all -n 4
```

```
* 4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
* 7d2c9f1 (main) feat(log): add log level
* 5c8d1e2 Merge branch 'fix/timeout'
```

Leelo como: *tomá los commits en `feature/metrics..feature/dash` y reproducilos sobre `main`.*

5. Hacé cherry-pick de un arreglo puntual sobre una rama de release, con trazabilidad:

```bash
git switch -c release/1.0 5c8d1e2
git cherry-pick -x 7d2c9f1
git log -n 1 --format='%H%n%n%B'
```

```
[release/1.0 8b5d3a6] feat(log): add log level
c1e0a7f4b3d2856907e1f2a3b4c5d6e7f8091a2b

feat(log): add log level

(cherry picked from commit 7d2c9f1e0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d)
```

6. Rompé el historial a propósito y recuperalo con el reflog:

```bash
git switch feature/dash
git reset --hard HEAD~1
git log --oneline -n 1
git reflog -n 4
git reset --hard 'HEAD@{1}'
git log --oneline -n 1
```

```
7d2c9f1 feat(log): add log level
7d2c9f1 HEAD@{0}: reset: moving to HEAD~1
4f6b0d7 HEAD@{1}: rebase (finish): returning to refs/heads/feature/dash
4f6b0d7 HEAD@{2}: rebase (pick): feat(dash): add dashboard URL
7d2c9f1 HEAD@{3}: checkout: moving from feature/metrics to feature/dash
4f6b0d7 (HEAD -> feature/dash) feat(dash): add dashboard URL
```

7. Mirá de qué te está protegiendo el reflog:

```bash
git fsck --unreachable --no-reflogs | head -n 3
```

```
unreachable commit 9e4a1b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f21
unreachable commit 6c1f8d3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e
unreachable commit d0e8b41f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b
```

Esos son los commits previos al rebase. Sobreviven hasta que `git gc` los poda — por defecto 90 días para los objetos alcanzables desde el reflog, 2 semanas para los inalcanzables (`gc.reflogExpire`, `gc.pruneExpire`).

### Preguntas de verificación

- **Q5.1** Enunciá la regla de oro del rebase, y describí concretamente qué le pasa a un colega que ya había hecho fetch de `feature/metrics` antes de que la rebasearas.
- **Q5.2** Merge y rebase integran ambos `main` en una rama de feature. Dá un argumento a favor de cada uno que sea sobre *operaciones*, no sobre estética — por ejemplo bisectar, revertir, y leer `git log --graph` seis meses después.
- **Q5.3** En la lista de tareas de un rebase interactivo, ¿cuál es la diferencia entre `squash` y `fixup`? ¿Y entre `reword` y `edit`?
- **Q5.4** `git commit --fixup <sha>` más `git rebase -i --autosquash` reemplazó un reordenamiento manual. ¿Qué escribe realmente `--fixup` en el mensaje de commit, y qué clave de configuración vuelve `--autosquash` el comportamiento por defecto?
- **Q5.5** Descomponé `git rebase --onto main feature/metrics feature/dash` en sus tres argumentos y decí, en palabras, qué commits se reproducen y dónde aterrizan.
- **Q5.6** ¿Por qué importa `-x` en un cherry-pick para una rama de release, y por qué `cherry-pick` es la herramienta equivocada para llevar 40 commits de `main` a `release/1.0`?
- **Q5.7** `git reflog` recuperó un commit que `git log` no podía mostrar. Explicá por qué, y nombrá las dos condiciones bajo las cuales el reflog *no* te va a salvar.

---

## Ejercicio 6 — Deshacer: reset, restore, revert, stash

### Pasos

1. Construí el estado de referencia:

```bash
cd /tmp/lpi-701.3/app
git switch main
echo 'DEBUG = True' >> src/config.py
git commit -q -am "chore: enable DEBUG (mistake)"
git log --oneline -n 2
```

```
c7a2e91 (HEAD -> main) chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

2. Compará los tres resets, uno por vez, volviendo atrás entre medio:

```bash
git reset --soft HEAD~1   && git status --short && git reset --hard c7a2e91 -q
git reset --mixed HEAD~1  && git status --short && git reset --hard c7a2e91 -q
git reset --hard HEAD~1   && git status --short
```

```
M  src/config.py
 M src/config.py
```

El tercero no imprime nada: `--hard` descartó el cambio por completo. Completá esta tabla con lo que acabás de observar:

| Modo | HEAD | Index | Working tree |
|---|---|---|---|
| `--soft` | se mueve | sin cambios | sin cambios |
| `--mixed` (por defecto) | se mueve | reseteado a HEAD | sin cambios |
| `--hard` | se mueve | reseteado a HEAD | **reseteado a HEAD** |

3. Restaurá el commit y deshacelo de la forma que tenés permitida en una rama compartida:

```bash
git reset --hard c7a2e91 -q
git revert --no-edit HEAD
git log --oneline -n 3
git diff HEAD~2 HEAD
```

```
f3b8c40 (HEAD -> main) Revert "chore: enable DEBUG (mistake)"
c7a2e91 chore: enable DEBUG (mistake)
7d2c9f1 feat(log): add log level
```

`git diff HEAD~2 HEAD` no imprime nada — el árbol es idéntico, y ambos commits siguen en el historial.

4. Revertí un *merge*, que necesita un número de parent:

```bash
git revert -m 1 5c8d1e2 --no-edit
git log --oneline -n 1
```

```
a0d5f27 (HEAD -> main) Revert "Merge branch 'fix/timeout'"
```

Sin `-m`, Git se niega: `error: commit 5c8d1e2 is a merge but no -m option was given.`

5. `git restore` — el reemplazo moderno y sin ambigüedades del sobrecargado `checkout`:

```bash
echo 'OOPS = 1' >> src/config.py
git add src/config.py
echo 'OOPS = 2' >> src/config.py
git restore --staged src/config.py   # index  <- HEAD ; working tree untouched
git status --short
git restore src/config.py            # working <- index
git status --short
```

```
 M src/config.py
```

(El segundo `git status --short` no imprime nada.)

6. Stasheá, incluyendo archivos sin trackear, e inspeccioná antes de aplicar:

```bash
echo 'WIP = True' >> src/config.py
echo 'scratch' > scratch.txt
git stash push -u -m "wip: config experiment"
git status --short
git stash list
git stash show -p 'stash@{0}' | head -n 8
```

```
stash@{0}: On main: wip: config experiment
diff --git a/src/config.py b/src/config.py
index 4a9b8e7..7c3d1f0 100644
--- a/src/config.py
+++ b/src/config.py
@@ -4,3 +4,4 @@ TLS_MIN_VERSION = "1.2"
 METRICS_PATH = "/metrics"
+WIP = True
```

(El `git status --short` intermedio no imprime nada — el working tree está limpio.)

7. Apply contra pop, y la verdadera naturaleza del stash:

```bash
git stash apply 'stash@{0}'
git stash list
git status --short
git stash drop 'stash@{0}'
git cat-file -p 'stash@{0}' 2>&1 | head -n 1
```

```
stash@{0}: On main: wip: config experiment
 M src/config.py
?? scratch.txt
Dropped stash@{0} (b6e1d84...)
fatal: ambiguous argument 'stash@{0}': unknown revision
```

8. Limpiá y confirmá:

```bash
git checkout -- src/config.py && rm -f scratch.txt
git status --short --branch
```

```
## main
```

### Preguntas de verificación

- **Q6.1** Commiteaste en `main` y ya pusheaste. Explicá por qué `git reset --hard HEAD~1` seguido de un force-push es la respuesta equivocada, y qué hace `git revert` en su lugar.
- **Q6.2** Commiteaste en una rama local hace 30 segundos y no pusheaste. ¿Qué modo de reset te permite conservar los cambios stageados para poder recommitear enseguida con un mensaje mejor — y qué único comando habría sido aún más simple?
- **Q6.3** `git reset --hard` descartó trabajo sin commitear en el paso 2. ¿Es eso recuperable desde el reflog? Justificá tu respuesta en términos de qué registra el reflog.
- **Q6.4** ¿Por qué revertir un commit de merge requiere `-m 1`, y a qué se refiere el número? ¿Cuál es la consecuencia conocida de revertir un merge y después intentar volver a mergear la misma rama?
- **Q6.5** Dá el equivalente con `git restore` de `git reset HEAD -- file` y de `git checkout -- file`, y decí por qué los comandos nuevos se consideran más seguros.
- **Q6.6** `git stash push` sin `-u` deja los archivos sin trackear en el working tree. Nombrá la falla que eso causa cuando después hacés `git switch` a otra rama y corrés un build.
- **Q6.7** Después de `git stash drop`, `git cat-file -p 'stash@{0}'` falla. ¿Qué tipo de objeto era la entrada del stash, y dónde estaba guardada la ref?

---

## Ejercicio 7 — Remotes, refspecs y tags

Vas a construir un "servidor" localmente. Un repositorio bare es exactamente lo que guarda una forge — sin working tree, solo la base de datos de objetos y las refs.

### Pasos

1. Creá el repositorio bare y clonalo:

```bash
cd /tmp/lpi-701.3
git init --bare origin.git
ls origin.git
git clone origin.git work
cd work
```

```
HEAD  config  description  hooks  info  objects  refs
Cloning into 'work'...
warning: You appear to have cloned an empty repository.
```

2. Pusheá el trabajo del repositorio `app` hacia él, y después inspeccioná el cableado:

```bash
cd /tmp/lpi-701.3/work
git remote add app /tmp/lpi-701.3/app
git fetch app
git switch -c main app/main
git push -u origin main
git remote -v
git branch -vv
```

```
 * [new branch]      main       -> app/main
branch 'main' set up to track 'origin/main'.
app	/tmp/lpi-701.3/app (fetch)
app	/tmp/lpi-701.3/app (push)
origin	/tmp/lpi-701.3/origin.git (fetch)
origin	/tmp/lpi-701.3/origin.git (push)
* main 3f2a1b9 [origin/main] Revert "Merge branch 'fix/timeout'"
```

3. Leé el refspec que Git escribió por vos:

```bash
git config --get-regexp '^remote\.origin\.'
git config --get branch.main.merge
ls .git/refs/remotes/origin
cat .git/packed-refs 2>/dev/null | head -n 3
```

```
remote.origin.url /tmp/lpi-701.3/origin.git
remote.origin.fetch +refs/heads/*:refs/remotes/origin/*
refs/heads/main
main
```

`+refs/heads/*:refs/remotes/origin/*` se lee: *traé todas las ramas del remote a mi espacio de nombres `refs/remotes/origin/`, y permití ahí actualizaciones que no sean fast-forward (`+`).*

4. Preguntale al remote qué sabe, sin tocar tus refs:

```bash
git ls-remote origin
git remote show origin
```

```
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	HEAD
3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a	refs/heads/main
* remote origin
  Fetch URL: /tmp/lpi-701.3/origin.git
  Push  URL: /tmp/lpi-701.3/origin.git
  HEAD branch: main
  Remote branch:
    main tracked
  Local branch configured for 'git pull':
    main merges with remote main
  Local ref configured for 'git push':
    main pushes to main (up to date)
```

5. Simulá un segundo desarrollador, para que el remote se mueva debajo tuyo:

```bash
cd /tmp/lpi-701.3
git clone -q origin.git other
cd other
echo 'FEATURE_FLAG = "on"' >> src/config.py
git commit -q -am "feat: add feature flag"
git push -q origin main
```

6. De vuelta en `work`, mirá la diferencia entre **fetch** y **pull**:

```bash
cd /tmp/lpi-701.3/work
git fetch origin
git status --short --branch
git log --oneline HEAD..@{u}
git rev-list --left-right --count HEAD...@{u}
```

```
 * branch            main       -> FETCH_HEAD
   3f2a1b9..8e7d6c5  main       -> origin/main
## main...origin/main [behind 1]
8e7d6c5 feat: add feature flag
0	1
```

`fetch` actualizó `origin/main` y no cambió **nada** en tu working tree. `0 1` significa: 0 commits que solo tenés vos, 1 commit que solo tiene el remote.

7. Integrá, con ambas políticas:

```bash
git merge --ff-only origin/main
git log --oneline -n 1
```

```
Updating 3f2a1b9..8e7d6c5
Fast-forward
8e7d6c5 (HEAD -> main, origin/main) feat: add feature flag
```

`git pull` es exactamente `git fetch` más este segundo paso. Con `pull.ff=only` del ejercicio 0, una divergencia detiene el proceso en lugar de producir silenciosamente un commit de merge; `git pull --rebase` reproduce tus commits locales encima en su lugar.

8. Producí un rechazo real por no ser fast-forward:

```bash
cd /tmp/lpi-701.3/other
echo 'REGION = "eu-west-1"' >> src/config.py
git commit -q -am "feat: pin region"
git push -q origin main

cd /tmp/lpi-701.3/work
echo 'REGION = "us-east-1"' >> src/config.py
git commit -q -am "feat: pin region differently"
git push origin main
```

```
To /tmp/lpi-701.3/origin.git
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
hint: Updates were rejected because the remote contains work that you do
hint: not have locally. This is usually caused by another repository pushing
hint: to the same ref.
```

9. Resolvelo correctamente — rebaseá tu commit encima, y después pusheá:

```bash
git pull --rebase origin main
# resolve the conflict in src/config.py, keeping one REGION line
git add src/config.py && git rebase --continue
git push origin main
```

10. Mirá por qué existe `--force-with-lease`:

```bash
git commit -q --amend -m "feat: pin region (amended)"
git push --force-with-lease origin main
```

```
 + 9a1b2c3...d4e5f60 main -> main (forced update)
```

`--force-with-lease` rechaza el push si `origin/main` no está en el valor que trajiste la última vez — es decir, si alguien pusheó mientras tanto. `--force` sobrescribe el trabajo ajeno sin preguntar. En una rama compartida, mejor ninguno de los dos.

11. Tags — las dos clases no son intercambiables:

```bash
git tag v0.9.0
git tag -a v1.0.0 -m "Release 1.0.0: TLS 1.2 minimum, metrics endpoint"
git cat-file -t v0.9.0
git cat-file -t v1.0.0
git cat-file -p v1.0.0
```

```
commit
tag
object d4e5f60a1b2c3d4e5f60718293a4b5c6d7e8f901
type commit
tag v1.0.0
tagger Ada Lovelace <ada@example.com> 1789700000 +0000

Release 1.0.0: TLS 1.2 minimum, metrics endpoint
```

El tag liviano *es* el hash del commit. El tag anotado es un **cuarto tipo de objeto** que lleva tagger, fecha, mensaje y, opcionalmente, una firma.

12. Publicá los tags — no se pushean por defecto:

```bash
git push origin main
git ls-remote --tags origin
git push --follow-tags origin main
git ls-remote --tags origin
git describe --tags
```

```
d4e5f60...	refs/tags/v1.0.0
d4e5f60...	refs/tags/v1.0.0^{}
v1.0.0
```

`--follow-tags` pusheó solo el tag **anotado** alcanzable desde lo que pusheaste; `v0.9.0` quedó local. La línea con `^{}` es la ref pelada: el commit al que apunta el objeto tag.

13. Aguas abajo, ese tag es el disparador de la release. Un pipeline lo consume así:

```yaml
stages:
  - test
  - release

test:
  stage: test
  script:
    - make test

release:
  stage: release
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+$/'
  script:
    - 'echo "publishing $CI_COMMIT_TAG"'
    - make publish
```

14. Podá las referencias a ramas que ya no existen upstream:

```bash
cd /tmp/lpi-701.3/other
git push origin --delete main 2>/dev/null || true
cd /tmp/lpi-701.3/work
git fetch --prune origin
git branch -r
```

### Preguntas de verificación

- **Q7.1** Explicá el refspec `+refs/heads/*:refs/remotes/origin/*` término por término: el `+`, el lado izquierdo, el lado derecho.
- **Q7.2** ¿Qué cambia exactamente `git fetch`, y qué decide deliberadamente no cambiar? Dá un escenario de producción donde traer primero e integrar después es la diferencia entre una caída y un no-evento.
- **Q7.3** `origin/main`, `refs/remotes/origin/main` y `@{u}` — ¿cuál es la relación entre estos tres nombres? ¿Podés commitear sobre `origin/main`?
- **Q7.4** El push del paso 8 fue rechazado con `(fetch first)`. Enunciá el invariante que el servidor está imponiendo, y listá las tres formas de continuar, ordenadas de la más segura a la más destructiva.
- **Q7.5** ¿Qué compara `--force-with-lease`, y en qué situación permite igualmente una sobrescritura que le cuesta a alguien sus commits?
- **Q7.6** Nombrá tres comportamientos concretos que difieren entre un tag liviano y un tag anotado (pista: tipo de objeto, `git describe`, firma, `--follow-tags`).
- **Q7.7** Un colega pusheó `v1.0.0`, después lo movió a otro commit y lo force-pusheó. Tu clon sigue resolviendo `v1.0.0` al commit viejo después de `git fetch`. ¿Por qué, y qué opción hace que la actualización ocurra?
- **Q7.8** Un repositorio bare no tiene working tree. ¿Por qué eso es un requisito para un destino de push y no una optimización?

---

## Ejercicio 8 — Submódulos

Un submódulo es un puntero de un repositorio a *un commit específico* de otro. Todo lo confuso de los submódulos se desprende de esa única oración.

### Pasos

1. Construí un repositorio de dependencia y agregalo como submódulo:

```bash
cd /tmp/lpi-701.3
git init -q --bare libgreet.git
git clone -q libgreet.git libgreet && cd libgreet
echo 'def greet(): return "hi"' > greet.py
git add greet.py && git commit -q -m "feat: initial greet"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule add ../libgreet.git vendor/libgreet
git status --short
```

```
Cloning into '/tmp/lpi-701.3/work/vendor/libgreet'...
A  .gitmodules
A  vendor/libgreet
```

2. Leé qué se registró — este es el punto central de todo el tema:

```bash
cat .gitmodules
git ls-files --stage vendor/libgreet
git commit -q -m "chore: vendor libgreet as a submodule"
git cat-file -p HEAD^{tree} | grep libgreet
```

```ini
[submodule "vendor/libgreet"]
	path = vendor/libgreet
	url = ../libgreet.git
```

```
160000 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b 0	vendor/libgreet
160000 commit 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b	vendor/libgreet
```

El modo `160000` es un **gitlink**: una entrada de árbol cuyo destino es un commit en otro repositorio. El superproyecto no almacena ningún archivo de `libgreet`.

3. Confirmá que el submódulo tiene su propio `.git` — y que no es un directorio:

```bash
cat vendor/libgreet/.git
git -C vendor/libgreet status --short --branch
```

```
gitdir: ../../.git/modules/vendor/libgreet
## HEAD (no branch)
```

El checkout del submódulo está en **detached HEAD**, porque el superproyecto fija un commit, no una rama.

4. Demostrá que un clon común no obtiene el contenido:

```bash
cd /tmp/lpi-701.3
git clone -q work fresh
ls fresh/vendor/libgreet
git -C fresh submodule status
```

```
-6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet
```

El directorio está vacío y el `-` inicial significa "no inicializado". Este es el incidente de submódulos más común: un build que funciona en local y falla en CI con "file not found".

5. Las dos maneras de hacerlo bien:

```bash
git -C fresh submodule update --init --recursive
git -C fresh submodule status
rm -rf fresh
git clone -q --recurse-submodules work fresh2
git -C fresh2 submodule status
```

```
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
 6a2b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b vendor/libgreet (heads/main)
```

6. Avanzá la dependencia y actualizá el puntero deliberadamente:

```bash
cd /tmp/lpi-701.3/libgreet
echo 'def farewell(): return "bye"' >> greet.py
git commit -q -am "feat: add farewell"
git push -q origin main

cd /tmp/lpi-701.3/work
git submodule update --remote vendor/libgreet
git status --short
git diff --submodule=log
```

```
 M vendor/libgreet
Submodule vendor/libgreet 6a2b0c9..b7c3d1e:
  > feat: add farewell
```

7. Commiteá el *movimiento del puntero*, que es un commit en el superproyecto:

```bash
git add vendor/libgreet
git commit -q -m "chore(deps): bump libgreet to b7c3d1e"
git show --stat HEAD
```

```
 vendor/libgreet | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)
```

Cambió una línea: el gitlink.

8. Eliminá un submódulo por completo — tres lugares, y siempre se olvidan de uno:

```bash
git submodule deinit -f vendor/libgreet
git rm -f vendor/libgreet
rm -rf .git/modules/vendor/libgreet
git commit -q -m "chore(deps): drop libgreet"
cat .gitmodules 2>/dev/null; echo "exit=$?"
```

```
exit=0
```

`git rm` eliminó la entrada de `.gitmodules` y el gitlink; `deinit` limpió `.git/config`; el `rm -rf` limpió el clon interno.

### Preguntas de verificación

- **Q8.1** ¿Qué significa el modo de archivo `160000` en un árbol, y qué se almacena en el superproyecto respecto del contenido de los archivos del submódulo?
- **Q8.2** ¿Por qué el checkout de un submódulo está normalmente en detached HEAD? ¿Qué sale mal si un desarrollador commitea dentro del submódulo estando detached y no se da cuenta?
- **Q8.3** `.gitmodules` está commiteado, pero la URL del submódulo también aparece en `.git/config`. ¿Cuál usa `git submodule update`, y qué comando copia una en la otra?
- **Q8.4** CI hace checkout de tu repositorio y el build falla por un archivo vendorizado ausente. Dá los dos comandos que lo arreglan, y decí cuál pondrías en el pipeline y por qué.
- **Q8.5** `git submodule update` y `git submodule update --remote` hacen cosas opuestas. Describí cada una con precisión.
- **Q8.6** Después de actualizar el submódulo, `git show --stat` reporta una línea cambiada. Explicale a quien revisa qué es esa línea y cómo debería revisar el cambio.
- **Q8.7** Nombrá las tres ubicaciones que hay que limpiar para eliminar un submódulo, y el síntoma de olvidarse de `.git/modules/<path>`.

---

## Ejercicio 9 — Gestión de claves SSH

El objetivo 701.3 incluye conocimiento de gestión de claves SSH, porque todo push a una forge real pasa por ahí.

### Pasos

1. Creá un par de claves moderno con un comentario que identifique la máquina:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "ada@laptop-2026-09" -f ~/.ssh/id_ed25519_demo
ls -l ~/.ssh/id_ed25519_demo*
```

```
Generating public/private ed25519 key pair.
Enter passphrase for "/home/ada/.ssh/id_ed25519_demo" (empty for no passphrase):
Your identification has been saved in /home/ada/.ssh/id_ed25519_demo
Your public key has been saved in /home/ada/.ssh/id_ed25519_demo.pub
-rw------- 1 ada ada  464 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo
-rw-r--r-- 1 ada ada  100 Sep 18 10:02 /home/ada/.ssh/id_ed25519_demo.pub
```

Usá una passphrase. Los permisos `600` sobre la clave privada y `700` sobre `~/.ssh` los impone OpenSSH, no son una recomendación.

2. Inspeccioná ambas mitades:

```bash
cat ~/.ssh/id_ed25519_demo.pub
ssh-keygen -lf ~/.ssh/id_ed25519_demo.pub
head -n 1 ~/.ssh/id_ed25519_demo
```

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4qK0v0h7f2Zt9xQ6r3sN1mJpL8cW5yT2dX0aB3eF4g ada@laptop-2026-09
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
-----BEGIN OPENSSH PRIVATE KEY-----
```

Solo la línea `.pub` se sube a la forge. La huella digital es lo que comparás por un segundo canal.

3. Arrancá un agente y cargá la clave para tipear la passphrase una sola vez:

```bash
eval "$(ssh-agent -s)"
ssh-add -t 8h ~/.ssh/id_ed25519_demo
ssh-add -l
```

```
Agent pid 48213
Enter passphrase for /home/ada/.ssh/id_ed25519_demo:
Identity added: /home/ada/.ssh/id_ed25519_demo (ada@laptop-2026-09)
Lifetime set to 28800 seconds
256 SHA256:9xL2k8Qv7rT0mN4pZ1sD6bY3cW5eR8uI0aF2hJ7gK9M ada@laptop-2026-09 (ED25519)
```

`eval` importa: `ssh-agent -s` solo *imprime* los export de `SSH_AUTH_SOCK` y `SSH_AGENT_PID`; sin `eval` tu shell nunca se entera de ellos.

4. Atá la clave a un host explícitamente, para que una máquina con múltiples cuentas siga siendo predecible:

```bash
cat >> ~/.ssh/config <<'EOF'

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_demo
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
chmod 600 ~/.ssh/config
```

`IdentitiesOnly yes` impide que SSH ofrezca una por una todas las claves del agente — la causa de `Too many authentication failures` en hosts con `MaxAuthTries 6`.

5. Probá la autenticación (este es el único comando con red; salteralo si estás offline):

```bash
ssh -T git@github.com
```

```
Hi ada! You've successfully authenticated, but GitHub does not provide shell access.
```

El estado de salida es `1` y eso es éxito para este host. Si falla, `ssh -vT git@github.com` muestra qué clave se ofreció y por qué fue rechazada.

6. Entendé el lado de la confianza correspondiente a la clave de host:

```bash
ssh-keygen -F github.com
ssh-keygen -lf ~/.ssh/known_hosts | head -n 2
```

Compará la huella impresa con la que el proveedor publica en su propio sitio de documentación **antes** de aceptarla la primera vez. `ssh-keygen -R github.com` elimina una entrada obsoleta después de una rotación documentada de la clave de host — y solo entonces.

7. Cambiá un repositorio de HTTPS a SSH:

```bash
cd /tmp/lpi-701.3/work
git remote set-url origin git@github.com:ada/app.git
git remote -v
git remote set-url origin /tmp/lpi-701.3/origin.git   # restore the sandbox
```

8. Usá la misma clave para firmar commits — sin GPG, Git ≥ 2.34:

```bash
cd /tmp/lpi-701.3/work
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519_demo.pub
git config commit.gpgsign true
printf '%s %s\n' "ada@example.com" "$(cat ~/.ssh/id_ed25519_demo.pub)" > ~/.ssh/allowed_signers
git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
echo 'SIGNED = True' >> src/config.py
git commit -q -am "chore: signed commit"
git log --show-signature -n 1 --format='%H %G? %GS'
```

```
e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4 G ada@example.com
```

`%G?` devuelve `G` (buena), `B` (mala), `U` (buena, no confiable) o `N` (ninguna).

### Preguntas de verificación

- **Q9.1** ¿Cuál de los dos archivos que produjo `ssh-keygen` va al servidor, y cuál es la consecuencia de subir el equivocado?
- **Q9.2** ¿Por qué `ssh-agent -s` necesita `eval`? ¿Qué se rompe si lo ejecutás sin eso?
- **Q9.3** ¿Qué problema resuelve una passphrase que los permisos de archivo no resuelven, y qué problema resuelve `ssh-add -t 8h` que la passphrase sola no resuelve?
- **Q9.4** Explicá `IdentitiesOnly yes`. Describí la falla que previene en una laptop con seis claves cargadas en el agente.
- **Q9.5** `ssh -T git@github.com` tuvo éxito pero salió con `1`. ¿Por qué no es un bug, y qué implica para un script de shell que lo ejecuta con `set -e`?
- **Q9.6** Distinguí la *clave de host* de la *clave de usuario*: cuál vive en `known_hosts`, contra qué ataque defiende cada una, y qué significa una advertencia repentina de `REMOTE HOST IDENTIFICATION HAS CHANGED`.
- **Q9.7** El reenvío del agente (`ssh -A`) es cómodo y en general se desaconseja para bastiones de producción. Enunciá la amenaza, y nombrá la alternativa más segura incorporada en OpenSSH.
- **Q9.8** En el paso 8 se firmó un commit sin GPG. ¿Qué tres claves de configuración lo hicieron posible, y qué reporta `git log --show-signature` si `allowedSignersFile` no está definido?

---

## Ejercicio 10 — Cierre integrador: imponer la política en el servidor

La disciplina del lado del cliente es una sugerencia. El repositorio bare es donde una regla se vuelve una regla.

### Pasos

1. Instalá un hook `pre-receive` que rechace actualizaciones que no sean fast-forward sobre `main`:

```bash
cd /tmp/lpi-701.3/origin.git
cat > hooks/pre-receive <<'EOF'
#!/bin/sh
# Reject force-pushes and deletions on protected branches.
protected="refs/heads/main"
zero="0000000000000000000000000000000000000000"

while read -r oldrev newrev refname; do
    [ "$refname" = "$protected" ] || continue

    if [ "$newrev" = "$zero" ]; then
        echo "policy: refusing to delete $refname" >&2
        exit 1
    fi

    if [ "$oldrev" != "$zero" ] && \
       [ "$(git merge-base "$oldrev" "$newrev")" != "$oldrev" ]; then
        echo "policy: non-fast-forward push to $refname rejected" >&2
        exit 1
    fi
done
exit 0
EOF
chmod +x hooks/pre-receive
```

2. Intentá violarla:

```bash
cd /tmp/lpi-701.3/work
git commit -q --amend -m "chore: signed commit (amended again)"
git push --force-with-lease origin main
```

```
remote: policy: non-fast-forward push to refs/heads/main rejected
To /tmp/lpi-701.3/origin.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to '/tmp/lpi-701.3/origin.git'
```

`--force-with-lease` pasó su propia verificación — tu `origin/main` estaba al día — y el servidor igual se negó. De eso se trata.

3. Intentá borrar la rama:

```bash
git push origin --delete main
```

```
remote: policy: refusing to delete refs/heads/main
 ! [remote rejected] main (pre-receive hook declined)
```

4. Agregá una barrera del lado del cliente, y observá dónde viven los hooks cuando deben compartirse:

```bash
cd /tmp/lpi-701.3/work
mkdir -p .githooks
cat > .githooks/pre-commit <<'EOF'
#!/bin/sh
# Block obvious secrets from entering the index.
if git diff --cached -U0 | grep -nE '^\+.*(AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY)'; then
    echo "pre-commit: possible credential in staged changes" >&2
    exit 1
fi
EOF
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
echo 'AWS_KEY = "AKIAIOSFODNN7EXAMPLE"' >> src/config.py
git commit -am "chore: add key"
```

```
1:+AWS_KEY = "AKIAIOSFODNN7EXAMPLE"
pre-commit: possible credential in staged changes
```

5. Limpiá:

```bash
git restore --staged src/config.py && git restore src/config.py
git config --unset core.hooksPath
```

### Preguntas de verificación

- **Q10.1** ¿Por qué `.git/hooks/pre-commit` no puede distribuirse commiteándolo, y qué clave de configuración lo resuelve? ¿Cuál es el límite duro de un hook del lado del cliente como control de seguridad?
- **Q10.2** `pre-receive` corre una vez; `update` corre una vez por ref. ¿Cuál usarías para una política que debe aceptar algunas refs de un push y rechazar otras, y qué cambia al respecto un "atomic push"?
- **Q10.3** En el hook, ¿qué prueba que `git merge-base "$oldrev" "$newrev"` devuelva exactamente `$oldrev`?
- **Q10.4** ¿Qué señala un `newrev` de puros ceros, y qué señala un `oldrev` de puros ceros?
- **Q10.5** El hook `pre-commit` bloqueó el commit — pero la clave ya estaba stageada y el desarrollador puede saltearse el hook. Nombrá el flag que lo evita, y enunciá qué debe pasar si una credencial llega a un commit pusheado (nota: `git revert` **no** alcanza — explicá por qué).

---

<details>
<summary><strong>Respuestas</strong> — abrir solo después de intentar todas las preguntas</summary>

### Ejercicio 0

**A0.1** En orden de aplicación: **system** (`/etc/gitconfig`, `--system`), **global** (`~/.gitconfig` o `$XDG_CONFIG_HOME/git/config`, `--global`), **local** (`.git/config`, `--local`) y **worktree** (`.git/config.worktree`, `--worktree`, solo con `extensions.worktreeConfig`). Gana **el más específico** — local pisa a global, que pisa a system. El `-c key=value` de la línea de comandos le gana a todos.

**A0.2** La **sección** y la **clave** no distinguen mayúsculas de minúsculas (Git las normaliza a minúsculas al imprimir); el nombre de la **subsección** — la parte entre comillas, por ejemplo `remote "Origin"` o `submodule "vendor/libgreet"` — y el **valor** sí las distinguen.

**A0.3** Una **divergencia**. Sin eso, `git pull` sobre una rama que tiene commits locales y remotos crea silenciosamente un commit de merge ("Merge branch 'main' of …"). Con `pull.ff=only`, el pull falla y hay que elegir conscientemente: `--rebase` o un merge explícito.

**A0.4** `git config --local user.email "ada@corp.example"` ejecutado dentro del repositorio; escribe `.git/config`. (`git config --global user.useConfigOnly true` más identidades por repositorio hace que Git se niegue directamente a adivinar una identidad, que es la versión de grado productivo.)

### Ejercicio 1

**A1.1**
- **blob** — el contenido de un archivo, sin nombre y sin permisos.
- **tree** — un listado de directorio: modo, tipo, hash y nombre para cada entrada.
- **commit** — un hash de árbol, cero o más padres, autor, committer y mensaje.
- **tag** (anotado) — el hash del objeto destino, su tipo, un nombre de tag, tagger y mensaje, y opcionalmente una firma.

**A1.2** El nombre del archivo vive en el **árbol**, no en el blob. La identidad del blob es `sha1("blob <bytesize>\0<content>")`. Consecuencia: el mismo archivo de 10 MB en cinco rutas se almacena **una sola vez** en la base de datos de objetos; cinco entradas de árbol apuntan a un blob. Git deduplica el contenido globalmente y gratis.

**A1.3** Un blob (el contenido de `greet.txt`), dos árboles (el directorio `src` y el árbol raíz) y un commit. blob + tree + tree + commit = 4.

**A1.4** Una rama es un archivo que contiene un ID de objeto de 40 caracteres. Crear una escribe 41 bytes y no copia nada; borrar una elimina 41 bytes. El costo de ramificar es independiente del tamaño del repositorio o del largo del historial.

**A1.5** Que no haya línea `parent` significa que es el **commit raíz** — el primero del historial. Un merge de dos ramas tiene **dos** líneas `parent` (un merge octopus de N ramas tiene N).

**A1.6** Sin `-w`, Git solo calcula e imprime el hash — una función pura, no se escribe nada. Con `-w` además escribe el objeto en `.git/objects`. Importa porque demuestra que el direccionamiento por contenido es determinista e independiente del repositorio: el hash es una propiedad de los bytes, no del commit que eventualmente hagas.

### Ejercicio 2

**A2.1** HEAD: `hello world\n`. Index: `hello world\ngoodbye world\n` (stageado en el paso 2). Working tree: `hello world\ngoodbye world\nthird line\n`. La `M` de la columna izquierda = HEAD difiere del index; la `M` de la columna derecha = el index difiere del working tree.

**A2.2** La versión que estaba en el index al momento del `git add` — la **primera** edición. `git commit` construye un árbol a partir del index, nunca del working tree. `git commit -a` habría stageado primero los cambios en archivos trackeados y capturado ambas.

**A2.3** `.gitignore` se consulta solo para rutas **sin trackear**. `secrets.env` ya está trackeado, así que la regla de ignorado es inerte. Arreglo: `git rm --cached secrets.env && git commit -m "chore: untrack secrets.env"`. El archivo queda en disco y de ahí en más se ignora. (Sigue estando en el historial — ver A10.5.)

**A2.4** **Decide el último patrón que coincide**. Una negación solo funciona si algún patrón anterior coincidió con el archivo y ningún patrón posterior lo vuelve a excluir. `!dist/app.bin` falla frente a `/dist/` porque Git directamente no desciende a un **directorio** excluido, así que el archivo nunca se evalúa. Para volver a incluirlo hay que des-excluir primero el directorio: `/dist/` → `/dist/*` más `!/dist/app.bin`, o `!/dist/` y después `/dist/*`.

**A2.5** Una `/` inicial ancla el patrón al directorio que contiene el `.gitignore`. `/dist/` coincide solo con un `dist` de nivel superior; `dist/` coincide con `dist` a **cualquier** profundidad, incluido `src/vendor/dist`.

**A2.6** Git calcula los renombres al momento de leer, por **similitud de contenido**, comparando los blobs eliminados y agregados (umbral por defecto del 50%, `-M<n>` para ajustarlo, `--find-renames`). En el commit no se almacena nada sobre el renombre — un renombre es un borrado más un agregado en el árbol.

**A2.7** Solo lo stageado: `git restore --staged <file>` (antiguo: `git reset HEAD -- <file>`). Solo el working tree: `git restore <file>` (antiguo: `git checkout -- <file>`). Ambos: `git restore --staged --worktree <file>`.

### Ejercicio 3

**A3.1** Para `git log`: `A..B` = commits alcanzables desde B pero no desde A (el conjunto "qué hay de nuevo en B"); `A...B` = la **diferencia simétrica**, los commits alcanzables desde uno u otro pero no desde ambos (agregá `--left-right` para etiquetarlos). Para `git diff` los significados están casi invertidos: `A..B` (y el simple `A B`) compara los dos árboles extremos; `A...B` compara **B contra el merge base** de A y B — que es lo que muestra un pull request.

**A3.2** `^` y `~` son lo mismo cuando hay un solo padre. `^N` selecciona el **N-ésimo padre** de un commit de merge; `~N` sube **N generaciones** por la línea del primer padre. Así, `HEAD~2` = `HEAD^^`, y `HEAD^2` es el segundo padre — solo resuelve para un **commit de merge**.

**A3.3** `-S<string>` coincide con los commits donde cambió la **cantidad de apariciones** de la cadena (agregadas o eliminadas) — encuentra dónde se introdujo o se borró un símbolo. `-G<regex>` coincide con los commits cuyo **texto del diff** contiene una línea que hace match con la regex — incluida una línea que apenas se movió o se reindentó. De ahí los dos resultados de `-G 'TIMEOUT'`: tanto la introducción como el cambio de valor tocaron una línea que la contiene.

**A3.4** Sin `--follow`, Git filtra el historial por la ruta tal como existe ahora, y el historial de esa ruta exacta empieza en el commit del renombre. `--follow` reinicia el filtrado por ruta en el renombre detectando el blob similar del otro lado, y continúa bajo el nombre viejo.

**A3.5** `HEAD~1` es una referencia de **grafo**: el primer padre del commit actual, calculado desde los objetos commit, idéntica en todos los clones. `HEAD@{1}` es una referencia de **reflog**: dónde apuntaba `HEAD` un movimiento atrás, local a tu repositorio y ausente en un clon nuevo. Solo la forma del reflog puede nombrar un commit al que no llega ninguna rama ni tag — por eso es la herramienta de recuperación.

**A3.6**
```
git bisect start HEAD 7f0e3c5
git bisect run ./run-test.sh
git bisect reset
```
(`HEAD` es el malo conocido, `7f0e3c5` el bueno conocido. `run` espera salida 0 = bueno, 1–124 = malo, 125 = saltear.)

### Ejercicio 4

**A4.1** Git hace fast-forward cuando el commit destino es **descendiente** del actual — es decir, se cumple `git merge-base --is-ancestor HEAD <target>`, así que el commit actual ya es un ancestro y no hay contenido nuevo que combinar. En el paso 2, `main` no había avanzado desde el punto de ramificación. En el paso 3, `--no-ff` anula la optimización y fuerza igual un commit de merge.

**A4.2** `git merge --no-ff`. Por defecto: `git config merge.ff false` (nunca hacer fast-forward en un merge) y `git config pull.ff only` del lado consumidor; `git config branch.main.mergeOptions --no-ff` lo acota a una rama. En una forge, el equivalente es la estrategia de "merge commit" con el fast-forward deshabilitado.

**A4.3** Stage 1 = el **merge base** (ancestro común), stage 2 = **ours**, stage 3 = **theirs**. Durante `git merge`, "ours" es la rama en la que estás. Durante `git rebase`, "ours" es el **upstream** sobre el que estás reproduciendo y "theirs" es **tu propio commit que se está reproduciendo** — porque el rebase hace checkout del upstream y aplica tus commits encima, de modo que, desde el punto de vista de Git, tu trabajo es el lado entrante.

**A4.4** `git checkout --ours -- file` opera **durante un conflicto sobre un archivo**: toma el stage 2 completo para esa ruta, descartando los cambios del otro lado sobre ella. `git merge -X ours` es una **opción de estrategia** de merge aplicada a todo el merge: resuelve cada hunk en conflicto a favor de la rama actual, pero sigue mergeando los cambios no conflictivos del otro lado. (Ninguno de los dos es `git merge -s ours`, que produce un commit de merge cuyo árbol es idéntico al tuyo, descartando por completo el contenido de la otra rama — se usa para marcar una rama como mergeada.)

**A4.5** `git commit` aborta: `error: Committing is not possible because you have unmerged files.` `git add` reemplaza los tres stages en conflicto (1/2/3) de esa ruta por una sola entrada en **stage 0** con tu contenido resuelto — ese colapso *es* el registro de la resolución.

**A4.6** `-d` se niega salvo que la rama esté completamente mergeada en su upstream o en el HEAD actual, de modo que no se pierda trabajo. `-D` saltea la verificación. El trabajo **no** se perdió: los commits quedan inalcanzables pero siguen en la base de datos de objetos, recuperables vía `git reflog` o `git fsck --lost-found` hasta que el recolector de basura los pode (por defecto: 30 días para objetos inalcanzables que entran en un pack, 2 semanas para los sueltos).

**A4.7** `rerere` = *reuse recorded resolution*. Git registra los hunks en conflicto y cómo los resolviste, y reproduce la resolución automáticamente la próxima vez que aparece el conflicto idéntico. En una rama de larga vida rebaseada a diario sobre un `main` en movimiento, el mismo conflicto se repite todos los días; rerere lo convierte en un costo único.

### Ejercicio 5

**A5.1** **Nunca rebasees commits sobre los que otros basaron trabajo** — en la práctica, nunca rebasees una rama que fue pusheada y que alguien más pueda haber traído. Un colega que trajo el viejo `feature/metrics` ahora tiene los commits `6c1f8d3`/`9e4a1b8` mientras que el remote tiene `a91c5e4`/`b3f7a02`, con contenido idéntico e identidades distintas. Su próximo `git pull` mergea ambos linajes y cada commit aparece dos veces.

**A5.2** *Merge:* preserva el grafo real de integración, así que `git log --first-parent main` se lee como una línea por feature, revertir una feature es un solo `git revert -m 1`, y ningún commit cambia nunca de identidad — un commit ya testeado sigue testeado. *Rebase:* produce un historial lineal, así que `git bisect` divide a la mitad una secuencia limpia sin commits de merge cuyos builds nunca se corrieron en esa combinación exacta, el orden de `git log` coincide con la causalidad, y cada commit en revisión es un estado completo y compilable de forma independiente.

**A5.3** `squash` conserva el mensaje del commit y abre un editor para combinarlo con el anterior; `fixup` descarta por completo el mensaje del commit y conserva solo el del anterior. `reword` cambia únicamente el mensaje, sin detener el rebase para dejarte tocar archivos; `edit` pausa el rebase con el commit ya aplicado, para que puedas enmendar el contenido, dividirlo o ejecutar comandos, y luego `git rebase --continue`.

**A5.4** Escribe un mensaje que es exactamente `fixup! <asunto del commit destino>`. `git config rebase.autosquash true` hace que `--autosquash` sea el comportamiento por defecto de los rebases interactivos (Git también respeta `--autosquash` para los prefijos `squash!` y `amend!` producidos por `--squash`/`--fixup=amend:`).

**A5.5** `--onto main` = la **nueva base**. `feature/metrics` = el **upstream**, es decir la cota inferior exclusiva. `feature/dash` = la **rama** a mover. Conjunto reproducido: `feature/metrics..feature/dash`, exactamente el único commit `feat(dash): add dashboard URL`. Aterriza sobre `main`, y `feature/dash` se reapunta ahí. Sin `--onto`, los commits de metrics habrían venido también.

**A5.6** `-x` agrega `(cherry picked from commit <sha>)` al mensaje, de modo que un commit en la rama de release es trazable hasta su origen en `main` — esencial al auditar qué se envió en un hotfix. Para 40 commits, el cherry-pick produce 40 commits nuevos con hashes nuevos y sin relación registrada: Git no puede saber que `release/1.0` contiene el trabajo de `main`, así que los merges futuros van a entrar en conflicto una y otra vez. Usá merge (o rebaseá la rama de release) en su lugar.

**A5.7** `git log` recorre el grafo de commits desde las refs; el commit viejo no era alcanzable desde ninguna ref después del `reset --hard`, así que es invisible para `log`. El reflog es un diario por repositorio de cada valor que tuvo cada ref (y `HEAD`), independiente de la alcanzabilidad. **No** te va a salvar cuando: (a) el trabajo nunca se commiteó — el reflog registra movimientos de refs, no estados del working tree; y (b) la entrada expiró y fue recolectada, o estás en un **clon nuevo** / un repositorio bare donde tu reflog no existe (los repos bare tienen `core.logAllRefUpdates` desactivado por defecto).

### Ejercicio 6

**A6.1** `reset --hard` + force-push reescribe la rama publicada: todos los que trajeron el tip viejo ahora tienen un historial divergente, los pipelines de CI atados a esos hashes se rompen, y a cualquiera que haya pusheado en el medio se le sobrescribe el trabajo. `git revert` crea un commit **nuevo** cuyo diff es el inverso del malo. El historial solo crece, el push es un fast-forward, y el registro de lo que pasó — el error y su corrección — queda auditable.

**A6.2** `git reset --soft HEAD~1` deja los cambios stageados, listos para un `git commit` con un mensaje nuevo. Todavía más simple: `git commit --amend -m "better message"`.

**A6.3** **No, no desde el reflog.** El reflog registra dónde apuntaban las refs, así que puede restaurar cualquier estado **commiteado**. El contenido no commiteado del working tree y del index nunca fue un objeto alcanzable desde una ref. (Excepción acotada: el contenido al que se le hizo `git add` se convierte en un blob, así que `git fsck --lost-found` a veces puede recuperar contenido stageado y luego descartado — pero no los nombres de archivo.)

**A6.4** Un commit de merge tiene dos padres, así que "el inverso de este commit" es ambiguo — Git necesita saber qué línea de padre representa la "mainline". `-m 1` selecciona el primer padre (en `main`, la rama en la que **mergeaste**), de modo que el revert deshace todo lo que vino del otro lado. Consecuencia: el revert hace que el merge base parezca ya integrado, así que volver a mergear la misma rama más adelante no trae **nada** — la feature queda silenciosamente ausente. El arreglo es revertir el revert (o rebasear la rama sobre el nuevo tip) antes de volver a mergear.

**A6.5** `git reset HEAD -- file` → `git restore --staged file`. `git checkout -- file` → `git restore file`. Más seguros porque los verbos son disjuntos: `git switch` cambia de rama, `git restore` cambia el contenido de archivos, mientras que `git checkout` hacía las dos cosas y el significado dependía de si el argumento resultaba ser un nombre de rama o una ruta — una fuente real de pérdida de datos con un nombre ambiguo.

**A6.6** Los archivos sin trackear permanecen en el working tree al hacer `git switch`, así que contaminan el build de la otra rama: un archivo generado obsoleto, un módulo sobrante o una configuración que la rama no espera terminan tomados por el sistema de build y producen un resultado que no corresponde a ninguna de las dos ramas. `git stash push -u` (o `-a` para incluir los ignorados) los pone también en el stash.

**A6.7** Una entrada de stash es un **objeto commit** — de hecho un commit de merge con dos o tres padres (HEAD, un commit con el estado del index y, con `-u`, un tercero con los archivos sin trackear). La ref era `refs/stash`, y las entradas anteriores se guardan en el **reflog** de esa ref — por eso la numeración es `stash@{0}`, `stash@{1}`, etcétera.

### Ejercicio 7

**A7.1** `+` = permitir actualizaciones **no fast-forward** en el destino (necesario porque una rama upstream puede ser force-pusheada legítimamente, y tu ref de seguimiento remoto debe acompañarla). Lado izquierdo `refs/heads/*` = el patrón **origen**, todas las ramas del remote. Lado derecho `refs/remotes/origin/*` = el **destino** en tu espacio de nombres local de refs. El `*` de ambos lados se liga posicionalmente: `refs/heads/main` → `refs/remotes/origin/main`.

**A7.2** `git fetch` descarga objetos nuevos y actualiza las refs de seguimiento remoto (`refs/remotes/origin/*`), `FETCH_HEAD` y los tags según la política. **No** toca tus ramas, tu index, tu working tree ni `HEAD`. Escenario: en medio de un incidente querés saber qué cambió upstream antes de decidir nada. `git fetch && git log --oneline HEAD..@{u}` responde eso con riesgo cero; un `git pull` reflejo habría iniciado un merge o un rebase sobre un árbol sucio en plena contingencia.

**A7.3** `origin/main` es la forma corta; `refs/remotes/origin/main` es la ref completa a la que resuelve; `@{u}` (`@{upstream}`) resuelve a la ref configurada como upstream de la rama actual (`branch.main.remote` + `branch.main.merge`) — habitualmente, pero no necesariamente, `origin/main`. **No podés** commitear sobre `origin/main`: hacerle checkout detacha HEAD, porque es una caché local del estado del remote, actualizada solo por fetch/push.

**A7.4** El invariante: una actualización de ref en el servidor debe ser un **fast-forward** — el valor viejo debe ser ancestro del nuevo — para que ningún commit que era alcanzable pase a ser inalcanzable. Opciones, de la más segura a la menos: (1) `git pull --rebase` (o fetch + rebase) y después push — tu trabajo se preserva y el resultado es un fast-forward; (2) fetch + merge y después push — misma garantía, un commit de merge extra; (3) `git push --force-with-lease` — reescribe la rama remota, permitido solo si nadie pusheó desde tu último fetch; (4) `git push --force` — sobrescritura incondicional, con posible pérdida de datos.

**A7.5** Compara la ref de seguimiento remoto que tenés (`refs/remotes/origin/main`) con el valor actual real de la ref en el servidor, y rechaza si difieren. Igual permite una sobrescritura si **vos** ejecutaste `git fetch` después del push ajeno sin mirar — el fetch refrescó silenciosamente tu lease. `--force-with-lease=main:<expected-sha>` con un hash explícito cierra ese agujero. Tampoco protege nada contra un push que ocurra entre tu verificación y la actualización del servidor si el remote carece de atomicidad en las transacciones de refs.

**A7.6** (1) **Tipo de objeto**: el liviano es una ref que apunta directo a un commit; el anotado crea un objeto tag real con tagger, fecha, mensaje y firma opcional. (2) `git describe` considera solo tags anotados por defecto (`--tags` incluye los livianos). (3) Solo los tags anotados (o firmados con `-s`) pueden **firmarse con GPG/SSH** y verificarse con `git tag -v`. (4) `git push --follow-tags` pushea solo tags anotados. (5) `git cat-file -t` devuelve `commit` contra `tag`.

**A7.7** Git deliberadamente **no** actualiza una ref de tag existente al hacer fetch — los tags están pensados para ser inmutables, y mover uno en silencio bajo los pies del usuario cambiaría a qué se refiere una release. Forzá la actualización con `git fetch --tags --force` o `git fetch origin 'refs/tags/*:refs/tags/*' --force`. El proceso correcto es no mover tags publicados: sacá `v1.0.1` en su lugar.

**A7.8** Un push actualiza refs y, en un repositorio no bare, dejaría la rama de `HEAD` apuntando a un commit mientras el working tree y el index siguen reflejando el anterior — el repositorio reportaría todo el diff como borrados/modificaciones sin commitear, y quien estuviera trabajando ahí sería saboteado en silencio. Por eso Git se niega por defecto (`receive.denyCurrentBranch=refuse`). Un repositorio bare no tiene working tree ni rama chequeada, así que no hay nada que desincronizar.

### Ejercicio 8

**A8.1** El modo `160000` es un **gitlink**: una entrada de árbol de tipo `commit` que nombra un objeto commit que vive en un repositorio *distinto*. El superproyecto no almacena **nada** del contenido de los archivos del submódulo — ni blobs ni árboles — solo ese ID de commit de 40 caracteres más la entrada de `.gitmodules` que le dice a Git desde dónde clonarlo.

**A8.2** Porque el superproyecto fija un **commit**, no una rama; hacer checkout de una rama dejaría que el submódulo derive en silencio. Si un desarrollador commitea estando detached y después ejecuta `git submodule update` (o cambia de rama en el superproyecto), HEAD se mueve al commit fijado y su commit queda inalcanzable en el submódulo — recuperable solo a través del reflog del submódulo, e invisible para todos los demás porque nunca se pusheó.

**A8.3** `git submodule update` usa **`.git/config`** (`submodule.<name>.url`), que se completa desde `.gitmodules` con `git submodule init` (o `update --init`). `git submodule sync` vuelve a copiar la URL de `.gitmodules` a `.git/config` — el comando que necesitás después de que cambia la URL upstream.

**A8.4** `git submodule update --init --recursive` después del checkout, o `git clone --recurse-submodules` de entrada. En un pipeline, preferí el paso explícito `submodule update --init --recursive` (o el `GIT_SUBMODULE_STRATEGY: recursive` / `submodules: recursive` de la plataforma), porque el checkout normalmente lo hace el runner de CI y no controlás sus flags de clonado — y además el paso explícito arregla un workspace incremental donde el clon ya existe.

**A8.5** `git submodule update` hace checkout del submódulo en **el commit que registra el superproyecto** — impone el pin, y es lo que ejecutás después de un pull. `git submodule update --remote` trae la rama configurada del submódulo (`submodule.<name>.branch` en `.gitmodules`, por defecto `HEAD`/`main`) y mueve el checkout a su commit **más reciente**, dejando modificado el gitlink del superproyecto para que lo revises y lo commitees — es un *bump* de dependencia, no una sincronización.

**A8.6** La línea cambiada es el **gitlink**: los IDs de commit viejo y nuevo de la dependencia. Revisar "una línea cambiada" no significa nada por sí solo; quien revisa debe inspeccionar el rango de commits entre ambos, con `git diff --submodule=log` (líneas de asunto) o `git diff --submodule=diff` (diff completo), y debería tener `git config diff.submodule log` para que ese sea el comportamiento por defecto.

**A8.7** (1) El checkout en el working tree, la entrada de `.gitmodules` y el gitlink — los elimina `git rm <path>`; (2) `submodule.<name>.*` en `.git/config` — lo elimina `git submodule deinit`; (3) el clon interno en `.git/modules/<path>` — hay que eliminarlo a mano. Olvidarse de (3) hace que un `git submodule add` posterior en la misma ruta falle con `A git directory for '<path>' is found locally with remote(s): …`, y que el repositorio viejo se reutilice silenciosamente.

### Ejercicio 9

**A9.1** La clave **pública** (`.pub`) va al servidor. Subir la clave privada revela el secreto por completo: cualquiera que la tenga se autentica como vos, y debe considerarse comprometida — hay que revocarla en todos lados y generar un par nuevo. (La clave privada además es inútil como línea de `authorized_keys`; la falla es un rechazo de autenticación silencioso más una credencial filtrada.)

**A9.2** `ssh-agent -s` arranca el agente e **imprime** comandos de shell (`SSH_AUTH_SOCK=…; export SSH_AUTH_SOCK; SSH_AGENT_PID=…; export SSH_AGENT_PID;`) en stdout. Sin `eval`, esas líneas solo se muestran; tu shell nunca define las variables, así que `ssh-add` y `ssh` no encuentran el socket del agente — `Could not open a connection to your authentication agent` — mientras queda corriendo un proceso de agente huérfano.

**A9.3** La passphrase cifra la clave privada **en reposo**, de modo que un backup robado, un snapshot o el robo de la laptop no entregan una credencial usable — los permisos de archivo protegen solo contra otros usuarios de un sistema en ejecución. `ssh-add -t 8h` acota la ventana **en memoria**: al vencer el tiempo de vida el agente descarta la clave, así que una máquina dejada desbloqueada o un atacante con acceso al socket del agente pierde la credencial al final de la jornada laboral y no en el próximo reinicio.

**A9.4** Con `IdentitiesOnly yes`, SSH ofrece **solo** las claves indicadas por `IdentityFile`/`CertificateFile` para ese host, en lugar de todas las identidades que tenga el agente más los nombres de archivo por defecto. Sin eso, una laptop con seis claves en el agente las ofrece de a una; un servidor con `MaxAuthTries 6` cierra la conexión con `Too many authentication failures` antes de que se pruebe la clave correcta — y en una forge con múltiples cuentas te autenticás con la cuenta equivocada.

**A9.5** El comando forzado del host imprime el saludo y sale con código distinto de cero porque no se otorga sesión de shell — `-T` desactiva la asignación de PTY y no hay nada que ejecutar. Lo que el mensaje reporta es la *autenticación* exitosa. Bajo `set -e`, el script aborta ante una verificación exitosa, así que probá el mensaje en su lugar: `ssh -T git@github.com 2>&1 | grep -q 'successfully authenticated'` (o protegelo con `|| true` e inspeccioná la salida).

**A9.6** La **clave de host** identifica al *servidor* y queda fijada en `~/.ssh/known_hosts`; defiende contra un **man-in-the-middle** — sin ella entregarías tus credenciales a lo que sea que responda en el puerto 22. La **clave de usuario** te identifica *a vos* y vive en `~/.ssh/id_*` (privada) y en el `authorized_keys` del servidor (pública); defiende contra la suplantación de tu identidad. `REMOTE HOST IDENTIFICATION HAS CHANGED` significa que la clave de host presentada difiere de la fijada: o una rotación legítima y anunciada, o un servidor reconstruido — o una intercepción activa. Verificá fuera de banda contra la huella publicada por el proveedor antes de ejecutar `ssh-keygen -R`.

**A9.7** Con `ssh -A`, el host remoto puede usar el socket de tu agente mientras dure la conexión: **root, o cualquiera que pueda leer el socket reenviado en el bastión, puede autenticarse como vos ante cualquier host que abran tus claves** — sin obtener nunca la clave. Alternativa más segura: `ProxyJump` (`ssh -J bastion target`, o `ProxyJump bastion` en `~/.ssh/config`), que tuneliza la conexión a través del bastión mientras la autenticación ocurre de extremo a extremo desde tu estación de trabajo; el bastión nunca ve tu agente. (Si el reenvío es inevitable, acotalo con `ssh-add -c` para pedir confirmación por uso.)

**A9.8** `gpg.format = ssh`, `user.signingkey = <ruta al .pub>` y `commit.gpgsign = true` (más `gpg.ssh.allowedSignersFile` para la verificación). Sin `allowedSignersFile`, la firma está presente y es criptográficamente válida pero Git no tiene una lista que mapee claves a identidades, así que `git log --show-signature` reporta `No principal matched.` y `%G?` devuelve `U` — firma buena, firmante desconocido — en lugar de `G`.

### Ejercicio 10

**A10.1** `.git/hooks/` **no** es parte del contenido del repositorio — nunca se commitea, clona ni pushea, por diseño: un repositorio capaz de distribuir código ejecutable que corre al clonarlo sería un vector de ejecución remota de código. `git config core.hooksPath <dir>` apunta Git a un directorio commiteado, de modo que los hooks viajan con el repo, pero **cada desarrollador debe optar explícitamente** definiendo esa configuración (o corriendo un script de bootstrap). El límite duro: cualquier hook del lado del cliente es orientativo — se puede saltear con `--no-verify`, eliminar, o simplemente no configurar. Solo los hooks del lado del servidor (o las reglas de rama protegida de la forge) imponen algo.

**A10.2** `update` — corre una vez por ref, con el valor viejo y el nuevo de esa ref, y puede rechazar exactamente una mientras las demás tienen éxito. `pre-receive` ve el push entero y solo puede aceptarlo o rechazarlo todo. Un **atomic push** (`git push --atomic`, o un servidor configurado con `receive.atomic`) cambia esto: todas las actualizaciones de refs tienen éxito o fallan juntas, así que el rechazo de un `update` por ref aborta igualmente el push completo.

**A10.3** Que `$oldrev` es **ancestro** de `$newrev` — el merge base de ambos es el propio tip viejo — que es precisamente la definición de un **fast-forward**. Si el merge base es cualquier otra cosa, el tip nuevo no contiene al viejo y habría commits que quedarían inalcanzables. (`git merge-base --is-ancestor "$oldrev" "$newrev"` expresa la misma prueba directamente mediante el estado de salida.)

**A10.4** Un `newrev` de puros ceros significa que la ref está siendo **eliminada**. Un `oldrev` de puros ceros significa que la ref está siendo **creada** y no existía antes — por eso el hook saltea la prueba de fast-forward en ese caso.

**A10.5** `--no-verify` (`git commit --no-verify`, `git push --no-verify`) saltea los hooks del lado del cliente. Si una credencial llega a un commit pusheado, `git revert` **no** alcanza: el revert agrega un commit nuevo, y el secreto sigue en el commit viejo, en la base de datos de objetos, en cada clon, y en la interfaz web y la API de la forge — a menudo de forma permanente, ya que las forges conservan objetos inalcanzables. La respuesta correcta es, en orden: **rotar/revocar la credencial de inmediato** (es el único paso que realmente mitiga), después purgarla del historial (`git filter-repo`, o el proceso de reescritura de historial/soporte de la propia forge) y force-pushear, después hacer que cada clon se vuelva a clonar, y pedirle a la forge que haga garbage collection y purgue las vistas cacheadas.

</details>

---

## Fuentes

- LPI, *DevOps Tools Engineer — Exam 701 Objectives (version 2.0.0)*, objetivo 701.3 Source Code Management: <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Documentación del proyecto Git — `git-config`, `git-hash-object`, `git-cat-file`, `git-add`, `git-reset`, `git-restore`, `git-merge`, `git-rebase`, `git-cherry-pick`, `git-revert`, `git-stash`, `git-remote`, `git-push`, `git-fetch`, `git-tag`, `git-submodule`, `gitignore`, `gitrevisions`, `githooks`: <https://git-scm.com/docs>
- Libro del proyecto Git, *Pro Git*, capítulos 7 (Git Tools) y 10 (Git Internals): <https://git-scm.com/book/en/v2>
- Semántica de `--force-with-lease` en Git, documentación de `git push`: <https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegt>
- Páginas de manual del proyecto OpenSSH — `ssh-keygen(1)`, `ssh-agent(1)`, `ssh-add(1)`, `ssh_config(5)`: <https://man.openbsd.org/ssh-keygen.1>, <https://man.openbsd.org/ssh-agent.1>, <https://man.openbsd.org/ssh-add.1>, <https://man.openbsd.org/ssh_config.5>
- Firma de commits con SSH en Git (`gpg.format=ssh`, `gpg.ssh.allowedSignersFile`), documentación de `git-config`: <https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgformat>