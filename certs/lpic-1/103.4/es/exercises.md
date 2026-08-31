# 103.4 — Usar flujos, tuberías y redirecciones
## Ejercicios guiados (LPIC-1, examen 101-500, v5.0)

**Entorno asumido:** Linux con Bash 5.x, GNU coreutils, GNU findutils, `procfs` montado. Todo se ejecuta como usuario sin privilegios salvo donde se muestre `sudo` explícitamente. Ejecute cada comando en el directorio de laboratorio construido en el Ejercicio 0.

**Cómo trabajar con esto:** ejecute cada paso numerado, compare su salida real con la salida esperada que se muestra, y luego responda las preguntas antes de continuar. Las respuestas están en la sección plegable del final.

---

## Ejercicio 0 — Construir el laboratorio

```bash
mkdir -p ~/lab-103.4 && cd ~/lab-103.4
```

1. Cree ficheros de datos deterministas:

```bash
seq 1 100 > numbers.txt
printf 'alpha\nbravo\ncharlie\ndelta\n' > words.txt
printf 'bravo\ncharlie\necho\nfoxtrot\n' > words2.txt
touch 'my report.txt' "it's here.txt"
```

2. Cree un programa que escriba de forma determinista en **ambos** flujos de salida y termine con estado distinto de cero. Casi todos los ejercicios posteriores lo utilizan:

```bash
cat > noisy.sh <<'EOF'
#!/bin/bash
echo "stdout: processing $1"
echo "stderr: warning about $1" >&2
exit 3
EOF
chmod +x noisy.sh
```

3. Verifíquelo:

```bash
./noisy.sh alpha
echo "exit=$?"
```

Esperado:

```
stdout: processing alpha
stderr: warning about alpha
exit=3
```

4. Observe el idioma usado dentro del script — `echo "..." >&2`. Así es como una herramienta bien educada separa los diagnósticos de los datos.

### Preguntas

- **Q0.1** En el paso 2 el delimitador del here-document se escribe como `<<'EOF'` en lugar de `<<EOF`. ¿Qué habría salido mal con la forma sin comillas, dado que el cuerpo del script contiene `$1`?
- **Q0.2** Ambas líneas de `./noisy.sh alpha` aparecen en su terminal. ¿Qué experimento demuestra que viajaron por dos descriptores de fichero distintos?

---

## Ejercicio 1 — Los tres flujos estándar como objetos del kernel

1. Pregunte al shell qué descriptores de fichero tiene abiertos en este momento:

```bash
ls -l /proc/self/fd
```

Esperado (el nombre del dispositivo variará):

```
total 0
lrwx------ 1 user user 64 Aug 26 10:00 0 -> /dev/pts/0
lrwx------ 1 user user 64 Aug 26 10:00 1 -> /dev/pts/0
lrwx------ 1 user user 64 Aug 26 10:00 2 -> /dev/pts/0
lr-x------ 1 user user 64 Aug 26 10:00 3 -> /proc/2841/fd
```

2. Ahora cambie a qué apunta el fd 1, solo para ese comando:

```bash
ls -l /proc/self/fd > fds.txt
cat fds.txt
```

Esperado: el fd `1` ahora resuelve a `/home/user/lab-103.4/fds.txt`, mientras que `0` y `2` siguen apuntando a la terminal.

3. Confirme que los tres flujos están numerados, no nombrados:

```bash
./noisy.sh a 1> stdout.txt 2> stderr.txt
cat stdout.txt
cat stderr.txt
```

Esperado:

```
stdout: processing a
stderr: warning about a
```

4. Confirme que la redirección es por comando y no persiste:

```bash
echo "back on the terminal"
```

### Preguntas

- **Q1.1** ¿Por qué `ls -l /proc/self/fd` muestra un descriptor 3 adicional que usted nunca abrió, y por qué es `lr-x` en lugar de `lrwx`?
- **Q1.2** `1>` y `>` se comportan igual. ¿Qué número de descriptor de fichero es el *único* que puede omitirse antes de `>`, y cuál es el único que puede omitirse antes de `<`?
- **Q1.3** En el paso 2, ¿qué habría mostrado `/proc/self/fd/1` si hubiera escrito `ls -l /proc/self/fd | cat` en su lugar?

---

## Ejercicio 2 — Truncar, añadir y la red de seguridad `noclobber`

1. Observe el truncado:

```bash
echo "first"  > log.txt
echo "second" > log.txt
cat log.txt
```

Esperado: solo `second` — `>` trunca a longitud cero **antes** de que el comando se ejecute.

2. Observe el añadido:

```bash
echo "third" >> log.txt
cat log.txt
```

Esperado:

```
second
third
```

3. Demuestre que el truncado ocurre antes de la ejecución, incluso si el comando falla:

```bash
echo "important data" > keep.txt
nosuchcommand > keep.txt
wc -c keep.txt
```

Esperado:

```
bash: nosuchcommand: command not found
0 keep.txt
```

4. Active la protección y reinténtelo:

```bash
set -o noclobber      # equivalent: set -C
echo "attempt" > log.txt
```

Esperado:

```
bash: log.txt: cannot overwrite existing file
```

5. Anúlela deliberadamente para un solo comando, y luego desactive la opción:

```bash
echo "attempt" >| log.txt
cat log.txt
set +o noclobber
```

6. Añada stderr sin tocar stdout:

```bash
./noisy.sh b 2>> errors.log
./noisy.sh c 2>> errors.log
cat errors.log
```

### Preguntas

- **Q2.1** En el paso 3 el fichero se vació aunque el comando nunca llegó a ejecutarse. ¿Qué proceso realiza el truncado, y en qué punto de la secuencia de eventos?
- **Q2.2** `noclobber` bloqueó `>` en el paso 4. ¿Bloquea también `>>`? ¿Bloquea `>` cuando el destino todavía no existe? ¿Bloquea `> /dev/null`?
- **Q2.3** El script de respaldo de un colega contiene `sort < data.txt > data.txt`. Prediga el tamaño resultante de `data.txt` y explique por qué.

---

## Ejercicio 3 — Fusionar stderr en stdout: el orden lo es todo

1. Envíe ambos flujos al mismo fichero:

```bash
./noisy.sh a > both.txt 2>&1
cat both.txt
```

Esperado:

```
stdout: processing a
stderr: warning about a
```

2. Ahora intercambie el orden de las dos redirecciones:

```bash
./noisy.sh a 2>&1 > only-stdout.txt
```

Esperado en la terminal:

```
stderr: warning about a
```

Y:

```bash
cat only-stdout.txt
```

Esperado:

```
stdout: processing a
```

3. Use la forma abreviada de Bash (no POSIX):

```bash
./noisy.sh a &> shorthand.txt
./noisy.sh b &>> shorthand.txt
cat shorthand.txt
```

4. Observe cómo el búfer de stdio cambia el *entrelazado* cuando un programa en C escribe a un fichero:

```bash
ls /etc/hostname /etc/definitely-not-here > lsboth.txt 2>&1
cat lsboth.txt
```

Esperado:

```
ls: cannot access '/etc/definitely-not-here': No such file or directory
/etc/hostname
```

5. Compare con el mismo comando escribiendo a la terminal:

```bash
ls /etc/hostname /etc/definitely-not-here
echo "exit=$?"
```

Esperado: las dos líneas aparecen en el orden opuesto (el natural), y `exit=2`.

### Preguntas

- **Q3.1** Explique `2>&1 > file` en términos de duplicación de descriptores. ¿A dónde apunta el fd 2 después de procesar toda la línea, y por qué *no* es al fichero?
- **Q3.2** En el paso 4 la línea de error llegó al fichero *antes* que la línea de datos, aunque `ls` imprimió los datos primero internamente. ¿Cuál es el mecanismo?
- **Q3.3** Debe escribir un script portable para `/bin/sh`. Reescriba `cmd &>> out.log` usando solo operadores de redirección POSIX.
- **Q3.4** ¿Por qué `cmd > file 2>&1` funciona pero `cmd > file 1>&2` destruye silenciosamente sus datos?

---

## Ejercicio 4 — Descartar salida, y la diferencia entre `/dev/null` y un descriptor cerrado

1. Descarte solo stderr:

```bash
./noisy.sh a 2>/dev/null
```

Esperado: solo `stdout: processing a`.

2. Descarte solo stdout, conservando los diagnósticos:

```bash
./noisy.sh a >/dev/null
```

3. Descarte todo pero conserve el estado de salida:

```bash
./noisy.sh a >/dev/null 2>&1
echo "exit=$?"
```

Esperado: `exit=3`.

4. Ahora *cierre* el fd 2 en lugar de descartarlo:

```bash
./noisy.sh a 2>&-
echo "exit=$?"
```

5. Muestre por qué cerrar es más arriesgado que descartar:

```bash
bash -c 'exec 2>&-; echo hello > /dev/full' ; echo "exit=$?"
```

Compare con:

```bash
bash -c 'exec 2>/dev/null; echo hello > /dev/full' ; echo "exit=$?"
```

### Preguntas

- **Q4.1** ¿Qué es `/dev/null`, en términos de números de dispositivo mayor/menor y del comportamiento del driver del kernel ante `write()` y ante `read()`?
- **Q4.2** Un programa hace `write(2, buf, n)` después de que usted lo ejecutara con `2>&-`. ¿Qué `errno` obtiene, y nombre un modo de fallo realista que esto provoque en un demonio de larga duración.
- **Q4.3** `find / -name core 2>/dev/null` es un idioma muy común. ¿Qué se está ocultando exactamente, y qué problema real puede enmascarar esto durante una auditoría?

---

## Ejercicio 5 — Redirección de entrada, here-documents y here-strings

1. Contraste un argumento con la entrada redirigida:

```bash
wc -l numbers.txt
wc -l < numbers.txt
```

Esperado:

```
100 numbers.txt
100
```

2. Alimente a un comando con un bloque literal:

```bash
sort <<EOF
delta
alpha
charlie
EOF
```

Esperado:

```
alpha
charlie
delta
```

3. Compare el comportamiento de expansión del delimitador:

```bash
cat <<EOF
user=$USER
year=$(date +%Y)
EOF

cat <<'EOF'
user=$USER
year=$(date +%Y)
EOF
```

4. Use la variante que elimina tabuladores. **La indentación de abajo debe consistir en caracteres de tabulación reales** (escriba `Ctrl+V` y luego `Tab` en la terminal, o escriba el script en un editor con tabuladores):

```bash
if true; then
	cat <<-EOF
	indented but flush in output
	EOF
fi
```

5. Use un here-string:

```bash
tr 'a-z' 'A-Z' <<< "alpha bravo"
wc -c <<< "abc"
```

Esperado:

```
ALPHA BRAVO
4
```

6. Observe cómo la sustitución de comandos y los here-strings tratan los saltos de línea finales:

```bash
printf 'a\nb\nc\n' | wc -l
wc -l <<< "$(printf 'a\nb\nc\n')"
printf 'no-newline' | wc -l
```

Esperado:

```
3
3
0
```

### Preguntas

- **Q5.1** ¿Por qué `wc -l < numbers.txt` omite el nombre del fichero? ¿Qué le dice eso sobre cómo decide `wc` qué imprimir?
- **Q5.2** En el paso 4, `<<-` eliminó la indentación. ¿Elimina también los *espacios* iniciales? ¿Cuál es la consecuencia práctica para un heredoc pegado desde un documento que usa indentación de 4 espacios?
- **Q5.3** `wc -c <<< "abc"` devolvió 4, no 3. ¿De dónde salió el cuarto byte?
- **Q5.4** En el paso 6, `$(printf 'a\nb\nc\n')` pasado a `<<<` siguió produciendo 3. Dos transformaciones opuestas se cancelaron — nombre ambas.

---

## Ejercicio 6 — Tuberías, estado de salida y SIGPIPE

1. Construya una tubería de tres etapas:

```bash
grep -c . numbers.txt
sort -n numbers.txt | tail -3 | tr '\n' ' '; echo
```

Esperado:

```
100
98 99 100 
```

2. Demuestre que el estado de una tubería es el estado del **último** comando:

```bash
false | true
echo "status=$?"
```

Esperado: `status=0`.

3. Recupere el estado de cada etapa. Capture `PIPESTATUS` *inmediatamente*:

```bash
false | true | ./noisy.sh x >/dev/null 2>&1
status=("${PIPESTATUS[@]}")
echo "stages: ${status[*]}"
```

Esperado:

```
stages: 1 0 3
```

4. Demuestre que `PIPESTATUS` es volátil:

```bash
false | true
echo "last=$?"
echo "pipestatus now: ${PIPESTATUS[*]}"
```

5. Haga que los fallos se propaguen:

```bash
set -o pipefail
false | true
echo "status=$?"
set +o pipefail
```

Esperado: `status=1`.

6. Observe SIGPIPE:

```bash
yes | head -3
echo "stages: ${PIPESTATUS[*]}"
```

Esperado:

```
y
y
y
stages: 141 0
```

7. Observe el búfer por bloques en una tubería. Primero, salida a una terminal:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep tick
```

Luego lo mismo con una etapa adicional de tubería:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep tick | cat
```

Luego corríjalo:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done | grep --line-buffered tick | cat
```

### Preguntas

- **Q6.1** ¿Cuántos procesos crea `a | b | c`, y cuántas tuberías? ¿Qué extremo de cada tubería mantiene abierto cada proceso?
- **Q6.2** ¿Por qué `141` es el estado de salida de `yes` en el paso 6? Descomponga el número.
- **Q6.3** En el paso 4, ¿por qué `${PIPESTATUS[*]}` ya no mostró `1 0`?
- **Q6.4** En el paso 7, la versión intermedia no imprimió nada durante 3 segundos y luego volcó todo de golpe. ¿Qué decisión toma el stdio de glibc al arrancar, basándose en qué prueba, y cuál es el equivalente con `stdbuf` de `--line-buffered` para un programa que no tiene una opción así?
- **Q6.5** `cmd 2>&1 | grep error` filtra ambos flujos. ¿Qué filtra `cmd | grep error 2>&1`, y por qué es casi siempre un error?

---

## Ejercicio 7 — La trampa del subshell: variables perdidas en una tubería

1. Intente contar líneas con un bucle alimentado por una tubería:

```bash
count=0
printf 'a\nb\nc\n' | while read -r line; do count=$((count+1)); done
echo "count=$count"
```

Esperado:

```
count=0
```

2. Confirme que el bucle realmente se ejecutó:

```bash
printf 'a\nb\nc\n' | while read -r line; do echo "saw $line"; done
```

3. Corríjalo con sustitución de procesos (Bash):

```bash
count=0
while read -r line; do count=$((count+1)); done < <(printf 'a\nb\nc\n')
echo "count=$count"
```

Esperado: `count=3`.

4. Corríjalo con redirección de entrada simple cuando la fuente es un fichero:

```bash
count=0
while read -r line; do count=$((count+1)); done < words.txt
echo "count=$count"
```

Esperado: `count=4`.

5. Corríjalo con `lastpipe`. En un shell interactivo también debe desactivar el control de tareas:

```bash
set +m
shopt -s lastpipe
count=0
printf 'a\nb\nc\n' | while read -r line; do count=$((count+1)); done
echo "count=$count"
shopt -u lastpipe
set -m
```

Esperado: `count=3`.

### Preguntas

- **Q7.1** ¿A dónde fueron exactamente los incrementos del paso 1?
- **Q7.2** ¿Por qué `shopt -s lastpipe` requiere que el control de tareas esté desactivado?
- **Q7.3** `cmd | read -r var` nunca establece `var` en Bash, pero el equivalente sí funciona en `ksh93`. ¿Qué le dice eso sobre qué extremo de una tubería elige el shell para ejecutar en el proceso actual, y por qué un script portable nunca debe depender de ello?

---

## Ejercicio 8 — `tee`: dividir un flujo

1. Divida un flujo entre un fichero y la siguiente etapa:

```bash
seq 1 5 | tee five.txt | wc -l
cat five.txt
```

Esperado:

```
5
1
2
3
4
5
```

2. Añada en lugar de truncar, y escriba en varios ficheros a la vez:

```bash
seq 6 8 | tee -a five.txt
seq 1 3 | tee copy-a.txt copy-b.txt > /dev/null
wc -l five.txt copy-a.txt copy-b.txt
```

Esperado:

```
8 five.txt
3 copy-a.txt
3 copy-b.txt
12 total
```

3. Envíe una copia a stderr para que una persona vea los datos mientras una tubería los consume:

```bash
seq 1 3 | tee /dev/stderr | md5sum
```

4. El patrón de producción para escribir un fichero privilegiado — note que `sudo echo x > /root/file` falla, porque es el *shell* quien abre el fichero, no `echo`:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-lab.conf > /dev/null
cat /etc/sysctl.d/99-lab.conf
sudo rm /etc/sysctl.d/99-lab.conf
```

5. Reparta un flujo entre dos *comandos* distintos usando `tee` más sustitución de procesos:

```bash
seq 1 10 | tee >(grep -c . > count.txt) >(paste -sd+ - > sum-expr.txt) > /dev/null
sleep 0.2
cat count.txt sum-expr.txt
```

Esperado:

```
10
1+2+3+4+5+6+7+8+9+10
```

6. Proteja una captura larga de un `Ctrl+C` accidental sobre el lector:

```bash
seq 1 3 | tee -i protected.txt
```

### Preguntas

- **Q8.1** En el paso 1, ¿por qué es necesario `tee` en absoluto — por qué no puede escribir `seq 1 5 > five.txt | wc -l`?
- **Q8.2** En el paso 4, ¿qué proceso abre `/etc/sysctl.d/99-lab.conf`, y con las credenciales de quién? ¿Por qué falla la forma con redirección aunque el comando lleve el prefijo `sudo`?
- **Q8.3** ¿Por qué se añade `> /dev/null` en el paso 4 y en el paso 5, si el fichero ya se está escribiendo?
- **Q8.4** En el paso 5, ¿para qué está el `sleep 0.2`, y qué clase de error produce su ausencia en un script?
- **Q8.5** `cmd | tee out.log | grep ERROR` devuelve el estado de salida de qué comando? ¿Cómo obtiene en su lugar el estado de `cmd`?

---

## Ejercicio 9 — `xargs`: convertir salida en argumentos

1. Comportamiento por defecto — agrupa tantos argumentos como quepan:

```bash
printf 'alpha\nbravo\ncharlie\n' | xargs echo
```

Esperado:

```
alpha bravo charlie
```

2. Un argumento por invocación, mostrando los comandos que se construyen:

```bash
printf 'alpha\nbravo\n' | xargs -t -n1 echo "word:"
```

Esperado:

```
echo word: alpha
word: alpha
echo word: bravo
word: bravo
```

3. Coloque el argumento en un lugar distinto del final:

```bash
printf 'alpha\nbravo\n' | xargs -I{} echo "[{}] done"
```

Esperado:

```
[alpha] done
[bravo] done
```

4. Provoque el error de los espacios en blanco con los ficheros que creó en el Ejercicio 0:

```bash
find . -maxdepth 1 -name '*.txt' | xargs ls -l 2>&1 | head -5
```

Esperado: errores como

```
ls: cannot access './my': No such file or directory
ls: cannot access 'report.txt': No such file or directory
```

5. Provoque el error de las comillas:

```bash
echo "it's here" | xargs echo
```

Esperado:

```
xargs: unmatched single quote; by default quotes are special to xargs unless you use the -0 option
```

6. Corrija ambos con separación por NUL — la única forma correcta de pasar nombres de fichero:

```bash
find . -maxdepth 1 -name '*.txt' -print0 | xargs -0 ls -l
```

7. Protéjase contra un conjunto de entrada vacío:

```bash
find . -name 'nothing-matches-this' | xargs -r ls -l ; echo "exit=$?"
find . -name 'nothing-matches-this' | xargs    ls -l ; echo "exit=$?"
```

8. Observe los estados de salida distintivos de `xargs`:

```bash
printf '/etc/hostname\n/definitely/not/here\n' | xargs -n1 cat > /dev/null 2>&1
echo "exit=$?"
```

Esperado: `exit=123`.

9. Paralelice:

```bash
time (seq 1 4 | xargs -P4 -I{} sh -c 'sleep 1; echo done {}')
```

Esperado: tiempo de reloj ≈ 1 s, no 4 s.

10. Inspeccione los límites reales de su sistema:

```bash
getconf ARG_MAX
xargs --show-limits < /dev/null
```

### Preguntas

- **Q9.1** En el paso 4, `find` emitió una única línea `./my report.txt`. ¿Qué caracteres trata `xargs` como separadores de argumentos por defecto, y cuántos argumentos recibió realmente `ls`?
- **Q9.2** ¿Por qué `-print0`/`-0` es lo correcto en lugar de simplemente entrecomillar? ¿Cuál es el único byte que no puede aparecer en un nombre de fichero de Linux, y cuál es el otro único?
- **Q9.3** `-I{}` cambia más que la posición del marcador. ¿Qué otra opción fija implícitamente a `1`, y cuál es la consecuencia de rendimiento sobre 50 000 elementos?
- **Q9.4** Distinga `find . -name '*.log' -exec rm {} \;` de `-exec rm {} +` y de `-print0 | xargs -0 rm`. ¿Cuáles dos son equivalentes en cantidad de procesos?
- **Q9.5** `rm $(find /var/tmp -name '*.tmp')` puede fallar con `Argument list too long`, pero la forma con `xargs` nunca lo hace. ¿Qué hace `xargs` que la sustitución de comandos no puede hacer?
- **Q9.6** Interprete los estados de salida 123, 124, 125, 126 y 127 de `xargs`.

---

## Ejercicio 10 — Sustitución de comandos vs. sustitución de procesos

1. Capture la salida en una variable:

```bash
lines=$(wc -l < numbers.txt)
echo "lines=[$lines]"
```

Esperado: `lines=[100]`.

2. Demuestre que los saltos de línea finales se eliminan:

```bash
v=$(printf 'x\n\n\n')
printf 'len=%s\n' "${#v}"
```

Esperado: `len=1`.

3. Lea un fichero sin bifurcar un `cat`:

```bash
content=$(<words.txt)
echo "$content" | head -1
```

4. Muestre el peligro del entrecomillado:

```bash
mkdir -p sub && touch 'sub/two words.txt'
for f in $(find sub -type f); do echo "got: [$f]"; done
echo '--- correct ---'
while IFS= read -r -d '' f; do echo "got: [$f]"; done < <(find sub -type f -print0)
```

Esperado: el primer bucle imprime dos entradas rotas, el segundo imprime una entrada correcta.

5. Compare dos comandos sin ficheros temporales:

```bash
diff <(sort words.txt) <(sort words2.txt)
```

Esperado:

```
1d0
< alpha
3a3,4
> echo
> foxtrot
```

6. Vea qué *es* realmente una sustitución de procesos:

```bash
echo <(true)
ls -l <(true)
```

Esperado: una ruta como `/dev/fd/63`.

7. Use la forma del lado de la salida:

```bash
seq 1 6 > >(grep -c . > outcount.txt)
sleep 0.2
cat outcount.txt
```

Esperado: `6`.

### Preguntas

- **Q10.1** Enuncie la regla de una línea que decide entre `$(cmd)` y `<(cmd)`.
- **Q10.2** ¿Por qué debe preferirse `$(...)` sobre las comillas invertidas? Dé un ejemplo concreto de anidamiento que solo funcione con `$(...)`.
- **Q10.3** En el paso 5, `diff` recibió dos nombres de fichero. ¿Qué clase de objeto es `/dev/fd/63`, y por qué `diff <(sort a) <(sort b)` falla con una herramienta que hace búsquedas hacia atrás en su entrada?
- **Q10.4** ¿Por qué `for f in $(find ...)` es incorrecto incluso cuando lo entrecomilla como `"$(find ...)"`, y por qué `read -d ''` es la primitiva correcta?

---

## Ejercicio 11 — Descriptores de fichero persistentes y personalizados con `exec`

1. Abra un descriptor privado para escritura:

```bash
exec 3> app.log
echo "starting run" >&3
echo "step 1 complete" >&3
exec 3>&-
cat app.log
```

Esperado:

```
starting run
step 1 complete
```

2. Abra un descriptor para lectura y consúmalo incrementalmente:

```bash
exec 4< numbers.txt
read -r a <&4
read -r b <&4
echo "a=$a b=$b"
exec 4<&-
```

Esperado: `a=1 b=2`.

3. Guarde, redirija y restaure el propio stdout del shell — el patrón clásico de script:

```bash
bash -c '
  exec 3>&1                 # save the original stdout
  exec > /tmp/captured.txt  # everything now goes to the file
  echo "this line is captured"
  exec 1>&3 3>&-            # restore stdout, close the saved copy
  echo "this line is visible"
'
cat /tmp/captured.txt
```

Esperado en la terminal:

```
this line is visible
this line is captured
```

4. Redirija un script entero desde el principio — la cabecera estándar segura para cron:

```bash
cat > logged.sh <<'EOF'
#!/bin/bash
exec >> /tmp/logged.out 2>&1
echo "run at fixed marker"
ls /definitely-not-here
EOF
chmod +x logged.sh
./logged.sh
echo "exit=$?"
tail -2 /tmp/logged.out
```

5. Redirija un bloque o bucle completo sin repetirse:

```bash
{
  echo "header"
  seq 1 3
  echo "footer"
} > block.txt
cat block.txt
```

6. Redirija la *entrada* de un bucle:

```bash
while read -r w; do echo "word=$w"; done < words.txt
```

### Preguntas

- **Q11.1** ¿Cuál es la diferencia entre `exec 3> app.log` y `exec > app.log`?
- **Q11.2** En el paso 3, `exec 1>&3 3>&-` hace dos cosas en una línea. ¿Por qué es importante cerrar el fd 3 en un script de larga duración, y qué se filtra a los procesos hijos si lo olvida?
- **Q11.3** En el paso 4, ¿por qué `exec >> file 2>&1` al principio de un script resuelve el problema de «cron me manda correo que no quiero / la salida de cron desaparece» mejor que redirigir en la propia línea del crontab?
- **Q11.4** ¿Qué números de descriptor debe evitar para uso personalizado en scripts, y por qué `{fd}>file` (Bash 4.1+) es más seguro que codificar `3` a mano?

---

## Ejercicio 12 — Diagnosticar redirecciones en un proceso en marcha

1. Inicie un proceso en segundo plano con redirecciones conocidas e inspecciónelo:

```bash
sleep 300 > /tmp/sleep.out 2> /tmp/sleep.err &
pid=$!
ls -l /proc/$pid/fd
```

Esperado:

```
lrwx------ ... 0 -> /dev/pts/0
l-wx------ ... 1 -> /tmp/sleep.out
l-wx------ ... 2 -> /tmp/sleep.err
```

2. Inspeccione en su lugar un miembro de una tubería:

```bash
kill $pid
sleep 300 | cat &
pid=$!
ls -l /proc/$pid/fd
```

Esperado: fd `0 -> pipe:[123456]`.

3. Verifíquelo de forma cruzada con `lsof`:

```bash
lsof -p "$pid" 2>/dev/null | awk 'NR==1 || $4 ~ /^[0-9]/'
kill %1 2>/dev/null
```

4. Escenario — reproduzca y corrija un fallo real. Un script de despliegue contiene:

```bash
cat > deploy.sh <<'EOF'
#!/bin/bash
./noisy.sh service-a 2>&1 >> /tmp/deploy.log
./noisy.sh service-b | grep -q "stdout"
echo "grep status=$?"
EOF
chmod +x deploy.sh
./deploy.sh
```

Observe: las advertencias aparecen en la terminal en lugar de en `/tmp/deploy.log`, y el script no puede saber si `noisy.sh` en sí falló.

5. Repare ambos defectos y verifique:

```bash
cat > deploy-fixed.sh <<'EOF'
#!/bin/bash
set -o pipefail
./noisy.sh service-a >> /tmp/deploy.log 2>&1
echo "service-a status=$?"
./noisy.sh service-b 2>>/tmp/deploy.log | grep -q "stdout"
echo "pipeline status=$? stages=${PIPESTATUS[*]}"
EOF
chmod +x deploy-fixed.sh
./deploy-fixed.sh
```

Esperado:

```
service-a status=3
pipeline status=3 stages=3 0
```

### Preguntas

- **Q12.1** En el paso 1, ¿por qué el fd 1 se muestra como `l-wx` mientras que el fd 0 es `lrwx`?
- **Q12.2** Un proceso tiene `1 -> pipe:[123456]`. ¿Cómo encuentra el proceso del otro extremo de esa tubería usando solo `/proc` o `lsof`?
- **Q12.3** En el paso 4, nombre ambos defectos con precisión, uno por línea del script.
- **Q12.4** En el paso 5, `pipeline status=3` aunque `grep` tuvo éxito. ¿Qué opción produjo eso, y cuál habría sido el estado sin ella?
- **Q12.5** El fichero de log de un demonio se eliminó mientras estaba en ejecución. `du` muestra que el disco sigue lleno y `ls` no muestra ningún fichero. Usando los conceptos de este ejercicio, ¿cómo localiza el espacio y recupera los datos sin reiniciar el demonio?

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

### Ejercicio 0

**A0.1** Con un delimitador sin comillas, el here-document queda sujeto a expansión de parámetros, sustitución de comandos y expansión aritmética. `$1` se habría expandido al primer parámetro posicional del shell *actual* — casi con seguridad vacío — de modo que el script generado contendría `echo "stdout: processing "`. Entrecomillar cualquier parte del delimitador (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) desactiva toda expansión y pasa el cuerpo literalmente. Regla para scripts que generan scripts: entrecomille siempre el delimitador salvo que quiera interpolación de forma deliberada.

**A0.2** Redirija uno de ellos a otro sitio y vea qué línea sobrevive: `./noisy.sh alpha 2>/dev/null` imprime solo la línea de stdout; `./noisy.sh alpha >/dev/null` imprime solo la línea de stderr. Ambos flujos apuntan por defecto a la misma terminal, que es exactamente la razón por la que parecen idénticos hasta que los separa.

### Ejercicio 1

**A1.1** El fd 3 es el flujo de directorio que el propio `ls` abrió para leer `/proc/self/fd`. Aparece en su propio listado porque el listado se produce mientras ese descriptor está abierto. Es `lr-x` (solo lectura) porque un directorio abierto con `opendir()` se abre en modo `O_RDONLY` — no se puede hacer `write()` a un directorio. Note además que `/proc/self` se resuelve dentro del proceso `ls`, así que muestra los descriptores *de `ls`*, no los del shell.

**A1.2** `>` toma por defecto el fd **1** (stdout) y `<` toma por defecto el fd **0** (stdin). El fd 2 siempre debe escribirse explícitamente (`2>`, `2>>`, `2>&1`). Esta asimetría es la razón por la que `2>` es la redirección que más se teclea al diagnosticar problemas.

**A1.3** Habría mostrado una tubería, p. ej. `1 -> pipe:[219845]`. Una tubería es un objeto anónimo del kernel con número de inodo pero sin ruta en el sistema de ficheros.

### Ejercicio 2

**A2.1** Lo realiza el **shell**, no el comando. Bash analiza la redirección, llama a `open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666)` — que trunca de inmediato —, luego hace `dup2()` del resultado sobre el fd 1, y solo entonces ejecuta `execve()` del comando. Si `execve()` falla (comando no encontrado), el fichero ya ha sido vaciado.

**A2.2** `noclobber` afecta solo a `>` (y `>|` lo anula). **No** afecta a `>>`, y **no** bloquea `>` cuando el destino no existe — de eso se trata precisamente: previene sobrescrituras accidentales, no la creación. Tampoco bloquea `> /dev/null`: desde Bash 4.x `noclobber` exime a los ficheros especiales de carácter y a otros ficheros no regulares, algo esencial porque `>/dev/null` es omnipresente.

**A2.3** `data.txt` acaba con **0 bytes**. Ambas redirecciones se establecen antes de que `sort` se ejecute; `O_TRUNC` vacía el fichero y luego `sort` lee un fichero ya vacío. Formas correctas: `sort data.txt -o data.txt` (GNU `sort` gestiona el modo in-place explícitamente), `sponge` de moreutils, o un fichero temporal más `mv`.

### Ejercicio 3

**A3.1** Las redirecciones se procesan estrictamente de izquierda a derecha. `2>&1` significa «haz que el fd 2 sea un duplicado de *lo que sea que el fd 1 es en este momento*» — en ese instante el fd 1 sigue siendo la terminal, así que el fd 2 pasa a ser un segundo asa sobre la terminal. Después, `> file` reapunta el fd 1 al fichero. El fd 2 sigue apuntando a la terminal, porque `dup2()` copia el destino actual; no crea un alias que siga los cambios posteriores. Estado final: fd 1 → fichero, fd 2 → terminal.

**A3.2** El stdio de glibc elige un modo de búfer por flujo en el primer uso, basándose en `isatty()`. `stdout` hacia un fichero queda **completamente bufferizado** (típicamente 4 KiB), así que `ls` acumula `/etc/hostname` en memoria y lo vuelca en `exit()`. `stderr` está **sin bufferizar** por requisito del estándar C, así que el error se escribe de inmediato con un `write(2)` directo. Por eso el error llega antes al fichero. El entrelazado de flujos fusionados es un artefacto del búfer, nunca una garantía.

**A3.3** `cmd >> out.log 2>&1`. `&>` y `&>>` son extensiones de Bash/Zsh y no están en POSIX; `sh` en Debian (dash) interpreta `cmd &> file` como «ejecuta `cmd` en segundo plano y luego redirige un comando vacío a `file`» — una interpretación errónea, silenciosa y peligrosa.

**A3.4** `> file 2>&1` apunta el fd 1 al fichero y luego hace que el fd 2 sea una copia del fd 1 (el fichero). `> file 1>&2` apunta el fd 1 al fichero y acto seguido reapunta el fd 1 a lo que sea el fd 2 (la terminal) — de modo que nunca se escribe nada en `file`, pero el fichero igualmente se creó y se truncó. Sus datos desaparecieron y su salida se fue a la pantalla.

### Ejercicio 4

**A4.1** `/dev/null` es un dispositivo de carácter, mayor 1, menor 3, respaldado por el driver `null` del kernel. `write()` acepta cualquier cantidad de bytes, los descarta y devuelve el recuento completo como éxito. `read()` devuelve 0 de inmediato — es decir, es una fuente infinita de EOF, razón por la cual `cmd < /dev/null` es la forma estándar de garantizar que un trabajo por lotes nunca se bloquee esperando entrada.

**A4.2** `EBADF` (descriptor de fichero inválido). Fallo realista: un demonio que comprueba el valor de retorno del `write()` de su registro y trata el fallo como fatal terminará en la primera línea de log; peor todavía, un demonio que después llame a `open()` recibirá el fd 2 como descriptor libre más bajo, de modo que su *fichero de datos* pasa a ser el fd 2 y cada `perror()`/diagnóstico de biblioteca posterior corrompe ese fichero. Precisamente por esto `2>/dev/null` es correcto y `2>&-` no.

**A4.3** Oculta `Permission denied` de directorios que el usuario no puede recorrer, además de `No such file or directory` por carreras con enlaces simbólicos y entradas de `/proc` que desaparecen. Durante una auditoría esto enmascara el hecho de que su barrido fue **incompleto** — usted concluye «no hay ficheros core en el sistema» cuando grandes partes del árbol nunca se examinaron. Mejor: `find / -name core 2>errors.log`, y luego revisar `errors.log`.

### Ejercicio 5

**A5.1** Con un nombre de fichero como argumento, `wc` abre el fichero él mismo y conoce su nombre, así que etiqueta el recuento. Con `<`, `wc` lee el fd 0 y no tiene nombre que imprimir. Consecuencia práctica: `wc -l < f` es la forma correcta siempre que quiera capturar un número pelado en una variable, evitando el posprocesado con `awk '{print $1}'`.

**A5.2** `<<-` elimina **únicamente los caracteres de tabulación iniciales** — nunca espacios. Un heredoc indentado con espacios conservará cada espacio en la salida, lo que rompe ficheros de configuración generados, YAML y SQL construido con here-docs. Los editores configurados con «expandir tabuladores a espacios» anulan silenciosamente `<<-`; este es uno de los errores de heredoc más comunes en scripts reales.

**A5.3** El operador de here-string añade un salto de línea a la palabra que alimenta a stdin. Así que `abc` se convierte en `abc\n` — 4 bytes.

**A5.4** La sustitución de comandos `$( )` elimina **todos** los saltos de línea finales de la salida capturada (`a\nb\nc\n` → `a\nb\nc`); el here-string entonces añade exactamente **uno** (`a\nb\nc\n`). Las dos se cancelan para una entrada con un único salto final, pero no para varios: `$(printf 'a\n\n\n')` alimentado a `<<<` produce una línea, no tres.

### Ejercicio 6

**A6.1** Tres procesos y dos tuberías. Cada tubería se crea con `pipe()` antes de bifurcar; el proceso que escribe conserva el extremo de escritura como fd 1 y cierra el de lectura, el proceso que lee conserva el extremo de lectura como fd 0 y cierra el de escritura. Cerrar los extremos no usados es esencial — si el lector conservara abierta una copia del extremo de escritura, nunca vería EOF y la tubería se colgaría. Bash ejecuta los tres en un subshell por defecto, que es la causa raíz del Ejercicio 7.

**A6.2** `141 = 128 + 13`. El shell informa de un hijo terminado por señal como `128 + número de señal`, y `SIGPIPE` es la señal 13. `yes` escribió en una tubería cuyo extremo de lectura se había cerrado, el kernel entregó `SIGPIPE`, y la disposición por defecto es terminar. Este es un final normal y sano para la mitad superior de `… | head`; los scripts que usan `set -o pipefail` deben estar preparados para ver 141 y no tratarlo como un error.

**A6.3** Bash establece `PIPESTATUS` después de **cada** tubería, y un comando simple como `echo "last=$?"` es una tubería de un solo elemento. Ese `echo` tuvo éxito, así que `PIPESTATUS` se sobrescribió con `(0)`. Cópielo siempre en el comando inmediatamente siguiente: `st=("${PIPESTATUS[@]}")`.

**A6.4** El stdio de glibc llama a `isatty(1)` en el primer uso: una terminal obtiene búfer por **línea**, cualquier otra cosa (tubería, fichero) obtiene búfer **completo** con un búfer de ~4 KiB. Añadir `| cat` convirtió el stdout de `grep` en una tubería, así que nada se volcó hasta la salida. `stdbuf -oL cmd` fuerza el búfer por línea en un programa sin opción propia (funciona precargando `libstdbuf.so`, de modo que no tiene efecto sobre binarios enlazados estáticamente ni sobre programas que fijan su propio búfer explícitamente, como `dd`).

**A6.5** `cmd | grep error 2>&1` redirige el stderr **de grep** al stdout de grep — el stderr de `cmd` va directo a la terminal, sin filtrar ni registrar. Es un error porque la redirección está adosada al proceso equivocado: `2>&1` debe aparecer en el comando cuyo stderr le interesa, y debe ir *antes* del `|`.

### Ejercicio 7

**A7.1** Cada comando de una tubería se ejecuta en un **subshell** (un hijo bifurcado). El bucle `while` incrementó `count` en el espacio de direcciones de ese hijo; cuando el hijo terminó, la variable murió con él. El `count` del padre nunca se tocó. Las variables no pueden propagarse hacia arriba a través de un `fork()` — solo pueden hacerlo el estado de salida y los datos escritos.

**A7.2** Con el control de tareas activado, Bash pone la tubería completa en su propio grupo de procesos para poder suspenderla y reanudarla como una unidad; el shell en sí no puede unirse a ese grupo sin ceder el control de la terminal. `lastpipe` requiere que el último comando se ejecute en el proceso del shell *actual*, lo cual es incompatible con eso. De ahí que solo surta efecto en shells no interactivos, o después de `set +m`.

**A7.3** `ksh93` (y `zsh`) ejecutan la **última** etapa de una tubería en el shell actual; Bash la bifurca como cualquier otra etapa salvo que `lastpipe` esté activo. Por tanto, un script portable nunca debe depender de efectos secundarios de la última etapa — alimente el bucle con `< file` o `< <(cmd)`, que no implican tubería alguna.

### Ejercicio 8

**A8.1** La redirección y la tubería compiten por el mismo descriptor. En `seq 1 5 > five.txt | wc -l`, la maquinaria de la tubería apunta primero el fd 1 a la tubería y luego `> five.txt` lo sobrescribe; `wc -l` hereda una tubería en la que nadie escribe, ve EOF de inmediato e imprime `0`. `tee` es un proceso real que lee stdin una vez y hace `write()` del mismo búfer a cada fichero de salida *y* a su propio stdout — una duplicación que la redirección por sí sola no puede expresar.

**A8.2** El **shell** abre el fichero, antes incluso de que `sudo` se ejecute, y lo hace con su UID sin privilegios — de ahí `Permission denied`. En la forma con `tee`, `sudo` es el proceso que hace exec de `tee`, así que `tee` corre como root y es *él* quien abre el fichero. Regla general: `sudo` eleva el comando, nunca la sintaxis del shell que lo rodea.

**A8.3** `tee` siempre reproduce su entrada también en stdout. Sin `> /dev/null` obtiene el contenido impreso en la terminal (paso 4) o reenviado a la siguiente etapa / a la terminal (paso 5), lo que en el mejor de los casos es ruido y en el peor son datos duplicados.

**A8.4** La sustitución de procesos crea un hijo asíncrono; el shell padre **no** lo espera. `tee` puede terminar y el shell puede volver al prompt mientras `grep -c` todavía está escribiendo `count.txt`. Sin el retardo, usted lee un fichero que aún no existe o está a medio escribir — una carrera clásica que solo aparece bajo carga o en almacenamiento lento. Soluciones robustas: capturar el PID desde `$!` cuando sea posible, usar un fichero temporal más `mv` para lograr atomicidad, o reestructurar para evitar la sustitución de procesos cuando el orden importa.

**A8.5** Devuelve el estado de `grep` (el último comando). Para obtener el de `cmd`, use `set -o pipefail` (la tubería devuelve entonces el estado distinto de cero más a la derecha) o lea `${PIPESTATUS[0]}` inmediatamente después de la tubería.

### Ejercicio 9

**A9.1** Por defecto `xargs` divide por **espacios en blanco (espacios y tabuladores) y saltos de línea**, y además respeta comillas simples, comillas dobles y escapes con barra invertida. `./my report.txt` se convirtió en dos argumentos, así que `ls` recibió `./my` y `report.txt`.

**A9.2** Entrecomillar no puede ayudar, porque `find` emite nombres de fichero en crudo y `xargs` los vuelve a analizar — no hay ninguna convención de entrecomillado compartida entre ambos. NUL (`\0`) es el separador correcto porque es el terminador de cadena de C y, por tanto, el **único** byte que no puede aparecer en un nombre de fichero de Linux; el otro byte prohibido es `/`, que es el separador de rutas. Los saltos de línea, comillas, espacios y barras invertidas son todos perfectamente legales en nombres de fichero, razón por la cual cualquier tubería basada en saltos de línea es solo aproximadamente correcta.

**A9.3** `-I` fija implícitamente `-L 1` (una línea de entrada por invocación del comando) y desactiva el agrupamiento de `-n`/`-L`. Sobre 50 000 elementos eso significa 50 000 pares `fork()`+`execve()` en lugar de un puñado de invocaciones agrupadas — a menudo dos órdenes de magnitud más lento. Use `-I` solo cuando la posición del marcador realmente lo exija; en caso contrario, deje que `xargs` agrupe.

**A9.4** `-exec rm {} \;` ejecuta **un `rm` por fichero**. `-exec rm {} +` agrupa nombres de fichero hasta `ARG_MAX`, ejecutando muy pocos procesos `rm` — esto es equivalente en cantidad de procesos a `-print0 | xargs -0 rm`, y además es más seguro porque no se hace ningún análisis de separadores. Prefiera `-exec … +` cuando `find` por sí solo basta; use `xargs` cuando necesite `-P`, `-I`, o un productor distinto de `find`.

**A9.5** La sustitución de comandos construye **un único** vector de argumentos y se lo entrega a `execve()`, que impone el límite `MAX_ARG_STRLEN`/`ARG_MAX` (típicamente 2 MiB en total para argv+envp en Linux). `xargs` lee la lista de forma incremental y la divide en **múltiples** invocaciones que caben cada una por debajo del límite, de forma transparente. `xargs --show-limits` imprime el techo real calculado en su sistema.

**A9.6**
- **123** — una o más invocaciones del comando terminaron con estado 1–125.
- **124** — el comando terminó con estado 255 (tratado como «detenerse de inmediato»).
- **125** — el comando fue terminado por una señal.
- **126** — el comando se encontró pero no pudo ejecutarse (p. ej. no es ejecutable).
- **127** — el comando no pudo encontrarse.
Cualquier otra cosa es un error propio de `xargs` (1). Note que `123` *no* es el estado del comando que falló, así que los scripts no deben compararlo con 1.

### Ejercicio 10

**A10.1** Use `$(cmd)` cuando necesite la salida del comando **como texto** (un valor que asignar, comparar o interpolar). Use `<(cmd)` cuando un programa exija un **nombre de fichero** y usted quiera entregarle un flujo en lugar de crear un fichero temporal.

**A10.2** Las comillas invertidas no se anidan sin escapes, y procesan las barras invertidas de forma distinta. `$(du -sh "$(dirname "$(readlink -f "$0")")")` es directo; el equivalente con comillas invertidas requiere escapes con barra invertida que se acumulan en cada nivel y se vuelve ilegible y propenso a errores. `$(...)` es además POSIX y es lo que impone cualquier guía de estilo.

**A10.3** `/dev/fd/63` es un enlace simbólico (vía `/proc/self/fd`) al **extremo de lectura de una tubería anónima**. Las tuberías no admiten búsqueda: `lseek()` devuelve `ESPIPE`. Cualquier herramienta que haga búsquedas — `tail -c` en algunas implementaciones, `sort` con ciertas estrategias de temporales, `mediainfo`, `unzip` — fallará o se comportará mal en silencio. En sistemas sin `/dev/fd`, Bash recurre a FIFOs, que solo son «buscables» de nombre y añaden un objeto en el sistema de ficheros.

**A10.4** `$(find ...)` sin comillas sufre división en palabras según `$IFS` **y** expansión de comodines, así que `two words.txt` produce dos iteraciones y un fichero llamado literalmente `*` coincide con todo. Entrecomillarlo como `"$(find ...)"` impide la división por completo, de modo que el bucle se ejecuta **una** vez con todos los nombres de fichero concatenados en una sola cadena — igual de incorrecto. Solo un flujo delimitado por NUL es inequívoco, y `read -r -d ''` fija el delimitador a NUL (`-r` además desactiva la interpretación de barras invertidas, `IFS=` evita que se recorten los espacios iniciales y finales).

### Ejercicio 11

**A11.1** `exec 3> app.log` abre el fichero en un descriptor **nuevo y no utilizado por lo demás** y deja intactos los fds 0/1/2 — usted opta por usarlo comando a comando con `>&3`. `exec > app.log` reemplaza el **stdout propio del shell** durante el resto del script; cada comando posterior lo hereda, sin forma de recuperar la terminal salvo que haya guardado una copia antes.

**A11.2** `exec 1>&3` restaura stdout desde la copia guardada; `3>&-` cierra el descriptor ya redundante. Importa porque cada hijo creado con `fork()` hereda los descriptores abiertos: un fd 3 filtrado que apunte a un fichero mantiene vivo el inodo de ese fichero incluso tras su borrado (el espacio no se recupera), puede ser escrito accidentalmente por un hijo que espera que el fd 3 esté libre, y aparece en `lsof` como un asa misteriosa. Los demonios de larga duración que filtran descriptores acaban alcanzando `RLIMIT_NOFILE` y fallan con `EMFILE`.

**A11.3** `exec >> file 2>&1` dentro del script captura la salida de **todo lo que el script hace**, incluido cualquier cosa antes o después de comandos individuales y cualquier hijo que herede los descriptores, y funciona con independencia de cómo se invocó el script — manualmente, desde `systemd`, desde `cron`, desde otro script. Redirigir en la línea del crontab cubre solo esa invocación, es fácil de omitir cuando se edita la entrada, y la sintaxis de crontab convierte `%` en un metacarácter de salto de línea que altera silenciosamente las redirecciones que lo contengan.

**A11.4** Evite 0, 1 y 2 (los flujos estándar) y tenga cuidado con **255**, que Bash usa internamente para su propia contabilidad en algunos contextos; los descriptores por encima de `ulimit -n` no están disponibles. Codificar `3` a mano es frágil porque un llamador, una biblioteca cargada con `source` o una herramienta envolvente puede estar usándolo ya, y usted lo pisaría en silencio. `exec {logfd}>file` deja que Bash asigne un descriptor libre y guarde el número en `$logfd`; ciérrelo con `exec {logfd}>&-`.

### Ejercicio 12

**A12.1** Los bits de permiso del enlace simbólico `/proc/PID/fd/N` reflejan cómo se abrió el descriptor. El fd 1 fue abierto en modo `O_WRONLY` por el shell para `> /tmp/sleep.out`, así que aparece como solo escritura (`l-wx`). El fd 0 se heredó de la terminal, que se abre en lectura-escritura (`lrwx`).

**A12.2** El número en `pipe:[123456]` es el **inodo** de la tubería. Encuentre todos los procesos que lo tienen: `lsof 2>/dev/null | grep 123456` (la columna `FD` muestra `0r` para el lector y `1w` para el escritor), o recorra `/proc/*/fd` con `ls -l /proc/*/fd 2>/dev/null | grep 'pipe:\[123456\]'`. Esta es la forma estándar de diagnosticar una tubería colgada — un lector atascado se manifiesta como un escritor bloqueado en `pipe_write` (compruebe `/proc/PID/stack` o `/proc/PID/wchan`).

**A12.3**
- Línea 1: `2>&1 >> /tmp/deploy.log` tiene las redirecciones en el orden equivocado. El fd 2 se duplica desde la terminal *antes* de que el fd 1 se mueva al log, así que las advertencias van a la pantalla y solo se registra stdout. Correcto: `>> /tmp/deploy.log 2>&1`.
- Línea 2: `$?` después de la tubería informa del estado de `grep`, no del de `noisy.sh`. Un `noisy.sh` que falle pero aun así emita el texto coincidente se reportaría como éxito.

**A12.4** `set -o pipefail`, que hace que la tubería devuelva el estado del **comando más a la derecha que terminó con estado distinto de cero** — aquí el 3 de `noisy.sh`. Sin ella, la tubería habría devuelto el 0 de `grep`, ocultando el fallo por completo. `${PIPESTATUS[*]}` le da el desglose por etapa (`3 0`) en cualquiera de los dos casos.

**A12.5** El fichero está desenlazado del árbol de directorios pero el demonio todavía mantiene un descriptor abierto, así que el inodo — y sus bloques — no se liberan. Localícelo con `lsof +L1` (ficheros con contador de enlaces 0) o `lsof -p PID | grep deleted`; la columna `SIZE` muestra el espacio consumido. Recupere el contenido copiando a través del descriptor aún abierto: `cp /proc/PID/fd/N /var/log/recovered.log`. Para reclamar el espacio sin reiniciar, trunque por la misma ruta: `: > /proc/PID/fd/N` (`truncate -s0` sobre la ruta de `/proc` también funciona). Un reinicio también lo libera, pero solo porque cierra el descriptor — el mismo efecto, con tiempo de inactividad.

</details>

---

## Fuentes

- LPI — *Exam 101-500 Objectives*, objetivo 103.4 "Use streams, pipes and redirects": <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — *Redirections* (incluyendo `>|`, `&>`, `<<`, `<<<`, `{varname}>`): <https://www.gnu.org/software/bash/manual/bash.html#Redirections>
- GNU Bash Reference Manual — *Pipelines* y `PIPESTATUS`: <https://www.gnu.org/software/bash/manual/bash.html#Pipelines>
- GNU Bash Reference Manual — *Process Substitution* y *Command Substitution*: <https://www.gnu.org/software/bash/manual/bash.html#Process-Substitution>
- GNU Coreutils Manual — invocación de `tee`: <https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html>
- GNU Findutils Manual — opciones y estado de salida de `xargs`: <https://www.gnu.org/software/findutils/manual/html_node/find_html/xargs-options.html>
- POSIX.1-2024 (IEEE 1003.1) — Shell Command Language, *Redirection*: <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07>
- Linux man-pages — `pipe(7)`: <https://man7.org/linux/man-pages/man7/pipe.7.html>
- Linux man-pages — `proc_pid_fd(5)`: <https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html>
- Linux man-pages — `null(4)`: <https://man7.org/linux/man-pages/man4/null.4.html>