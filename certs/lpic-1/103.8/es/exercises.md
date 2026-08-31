# LPIC-1 · 103.8 Edición básica de archivos — Ejercicios guiados

**Examen:** 101-500 (LPIC-1 v5.0) · **Tema:** 103.8 Basic file editing
**Cobertura del objetivo:** navegar por un documento con `vi`; entender y usar los modos de `vi`; insertar, editar, borrar, copiar y buscar texto en `vi`; conocimiento de Emacs, nano y vim.

Todo lo que sigue está pensado para que lo tipees. Cada bloque termina con **Comprobá lo que entendiste** — respondé antes de seguir. Todas las respuestas están plegadas al final.

## Notación usada en este laboratorio

| Notación | Significado |
|---|---|
| `$ command` | se tipea en el prompt del shell |
| `<Esc>`, `<Enter>` | esas teclas |
| `Ctrl-R` | mantené Control, presioná `r` |
| `:wq<Enter>` | se tipea **dentro** del editor, en modo línea de comandos (ex) |
| `dd` | dos pulsaciones en modo normal — **no** es un comando de shell |

Las pulsaciones en `vi` distinguen mayúsculas de minúsculas y **no** se muestran en pantalla en modo normal. Si parece que no pasa nada, probablemente estés en el modo equivocado: presioná `<Esc>` dos veces y empezá de nuevo.

---

## Ejercicio 1 — Averiguá qué editor tenés realmente

`vi` es un *nombre*, no un programa. En una máquina Linux moderna casi siempre es un enlace simbólico o una compilación recortada de Vim, y las diferencias (deshacer multinivel, modo visual, teclas de flecha en modo inserción) deciden qué funciona durante el examen y en un nodo de producción.

1. Armá el directorio del laboratorio:

```bash
mkdir -p ~/lab-103.8 && cd ~/lab-103.8
```

2. Descubrí todos los editores presentes en el sistema:

```bash
command -v vi vim vim.tiny nano emacs ed 2>/dev/null
```

Salida típica en una instalación mínima de Debian/Ubuntu:

```text
/usr/bin/vi
/usr/bin/nano
/usr/bin/ed
```

3. Resolvé qué es realmente `vi`:

```bash
readlink -f "$(command -v vi)"
```

```text
/usr/bin/vim.tiny
```

En RHEL/Fedora/openSUSE normalmente vas a ver `/usr/bin/vi` (un binario real del paquete `vim-minimal`). En Alpine y dentro de muchas imágenes de contenedor es `/bin/busybox`.

4. En sistemas de la familia Debian, inspeccioná la entrada de alternatives que tomó esa decisión:

```bash
update-alternatives --display vi
```

```text
vi - auto mode
  link best version is /usr/bin/vim.tiny
  link currently points to /usr/bin/vim.tiny
  link vi is /usr/bin/vi
/usr/bin/vim.tiny - priority 15
```

5. Preguntale al binario con qué conjunto de características fue compilado:

```bash
vi --version 2>/dev/null | head -2
```

```text
VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Mar 11 2024 12:00:00)
Tiny version without GUI.
```

(La versión, las fechas y la palabra `Tiny`/`Small`/`Normal`/`Huge` varían según la distribución. Un binario clásico de `nvi` no entiende `--version` en absoluto e imprime una línea de uso en su lugar.)

6. Comprobá qué editor va a lanzar el resto del sistema en tu nombre:

```bash
echo "VISUAL=$VISUAL EDITOR=$EDITOR"
```

```text
VISUAL= EDITOR=
```

Que esté vacío es normal — y es la razón por la que `crontab -e` en un Debian recién instalado te deja en `nano`, mientras que en RHEL te deja en `vi`.

7. Creá el archivo prístino del laboratorio y una copia de referencia intacta:

```bash
cat > svc.conf <<'EOF'
# svc.conf - edge service, staging
listen 0.0.0.0:8080
workers 4
worker_connections 1024
keepalive_timeout 65
client_max_body_size 1m

upstream api {
    server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
    server 10.0.2.12:9000 max_fails=3 fail_timeout=10s;
    server 10.0.2.13:9000 backup;
}

log_level info
access_log /var/log/svc/access.log
error_log /var/log/svc/error.log
metrics_port 9100
tls_cert /etc/svc/tls/tls.crt
tls_key /etc/svc/tls/tls.key
drain_timeout 30s
EOF
cp svc.conf svc.conf.orig
wc -lc svc.conf
```

```text
 20 477 svc.conf
```

Esos dos números — **20 líneas, 477 bytes** — son tu control de integridad para todo el laboratorio. Cada vez que un ejercicio diga *restaurá el archivo*, ejecutá `cp svc.conf.orig svc.conf` y confirmá `wc -lc` de nuevo.

**Comprobá lo que entendiste**

**Q1.** ¿Por qué `readlink -f "$(command -v vi)"` es una respuesta más confiable a "¿qué editor estoy por obtener?" que `which vi`?
**Q2.** Un colega dice "usá `Ctrl-R` para rehacer". ¿En cuáles de los binarios que encontraste arriba podría fallar eso, y por qué?
**Q3.** `EDITOR` y `VISUAL` están ambos vacíos. Nombrá dos comandos cuyo comportamiento cambie igualmente si exportás uno de ellos.

---

## Ejercicio 2 — Los tres modos, y cómo demostrar en cuál estás

`vi` es modal. Cada minuto perdido frente a `vi` viene de estar en un modo que no esperabas.

1. Abrí el archivo y activá inmediatamente el indicador de modo y los números de línea:

```bash
vi svc.conf
```

Dentro del editor:

```text
:set showmode number<Enter>
```

2. Presioná `i`. Mirá la esquina inferior izquierda:

```text
-- INSERT --
```

3. Tipeá `# touched` y después presioná `<Esc>`. El indicador `-- INSERT --` desaparece — volviste al modo **normal** (también llamado *modo comando*).

4. Presioná `:` — el cursor salta a la línea inferior, que ahora muestra un único dos puntos. Este es el **modo línea de comandos** (también llamado *modo ex*, porque estos son los comandos del editor de líneas `ex` del que `vi` es un frontend visual). Presioná `<Esc>` para abandonarlo sin ejecutar nada.

5. Presioná `R`. El indicador ahora dice:

```text
-- REPLACE --
```

Tipeá `XXX` — sobrescribe caracteres en vez de empujarlos a la derecha. Presioná `<Esc>`.

6. Presioná `v` (solo Vim; no está en el `vi` original):

```text
-- VISUAL --
```

Movete con `l` unas cuantas veces para extender la selección resaltada, después presioná `<Esc>`.

7. Deshacé todo lo que acabás de hacer y confirmá que el archivo quedó intacto:

```text
:e!<Enter>
:q<Enter>
```

```bash
cmp svc.conf svc.conf.orig && echo IDENTICAL
```

```text
IDENTICAL
```

**Comprobá lo que entendiste**

**Q4.** Nombrá los tres modos que exige el objetivo e indicá la única tecla que te devuelve al modo normal desde cada uno de ellos.
**Q5.** Presionás `dd` esperando borrar una línea y en cambio aparece el texto literal `dd` en el búfer. ¿Qué pasó, y cuáles son las dos pulsaciones que lo arreglan?
**Q6.** ¿Cuál es la diferencia entre `:e!` y `u`?
**Q7.** `Ctrl-[` produce el mismo efecto que `<Esc>`. ¿Por qué importa eso en una consola remota o en un teclado con la tecla Escape lejana o ausente?

---

## Ejercicio 3 — Navegación: moverse sin teclas de flecha

Las teclas de flecha no están garantizadas. En una consola serie, en `vi` en modo compatible, o a través de un `TERM` roto, las flechas emiten secuencias de escape que te dejan en modo inserción con `A`/`B`/`C`/`D` desperdigados por el archivo. `h j k l` siempre funcionan.

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number<Enter>
```

2. Movimientos de carácter y de línea — desde la línea 1, presioná:

```text
j j j        (down to line 4)
l l l l      (right four characters)
k            (up to line 3)
h            (left one character)
```

3. Movimientos de palabra. Presioná `0` (inicio de línea), después:

| Tecla | Movimiento |
|---|---|
| `w` | hacia adelante, al inicio de la palabra siguiente |
| `b` | hacia atrás, al inicio de la palabra anterior |
| `e` | hacia adelante, al final de la palabra actual/siguiente |
| `W` `B` `E` | lo mismo, pero una "palabra" es cualquier secuencia de no-blancos (así que `10.0.2.11:9000` es **una** WORD) |

Andá a la línea 9 (`9G`), presioná `0`, después `w w w` — parás en `server`, `10`, `.`. Ahora presioná `0` y `W W` — parás en `server`, y después en el `10.0.2.11:9000` completo.

4. Movimientos anclados a la línea:

| Tecla | Movimiento |
|---|---|
| `0` | columna 1 |
| `^` | primer carácter no blanco (útil en las líneas `server` indentadas) |
| `$` | fin de línea |

En la línea 9, compará `0` y `^`: `0` aterriza en el espacio inicial, `^` aterriza en la `s` de `server`.

5. Movimientos de archivo y de línea:

```text
gg      first line          (Vim; classic vi uses 1G)
G       last line (20)
17G     line 17
:17<Enter>   same thing, ex style
```

6. Movimientos de pantalla — agrandá o achicá tu terminal para verlos funcionar:

| Tecla | Movimiento |
|---|---|
| `H` | **H**igh — línea superior de la pantalla |
| `M` | **M**iddle — medio de la pantalla |
| `L` | **L**ow — línea inferior de la pantalla |
| `Ctrl-F` / `Ctrl-B` | **F**orward / **B**ack, una pantalla completa |
| `Ctrl-D` / `Ctrl-U` | **D**own / **U**p, media pantalla |

7. Movimientos estructurales. Poné el cursor en la `{` de la línea 8 y presioná `%`:

```text
   8 upstream api {
...
  12 }
```

El cursor salta a la `}` correspondiente en la línea 12. Presioná `%` de nuevo para volver. Ahora presioná `{` y `}` para moverte por párrafo (bloques delimitados por líneas en blanco): desde la línea 9, `{` aterriza en la línea en blanco 7, `}` aterriza en la línea en blanco 13.

8. Salí sin guardar:

```text
:q<Enter>
```

**Comprobá lo que entendiste**

**Q8.** Dá dos formas de saltar a la línea 17 y una forma de saltar a la última línea de un archivo de longitud desconocida.
**Q9.** En la línea `    server 10.0.2.11:9000 backup;`, ¿cuántas veces tenés que presionar `w` para llegar a `backup`, frente a `W`? Explicá la regla.
**Q10.** Tenés que comprobar que una configuración tipo JSON de 4000 líneas tiene las llaves balanceadas alrededor de un bloque. ¿Qué única pulsación responde eso más rápido, y qué te dice si el cursor no se mueve?
**Q11.** `Ctrl-D` frente a `Ctrl-F`: ¿cuál es más seguro para leer un archivo de log que estás escaneando visualmente, y por qué?

---

## Ejercicio 4 — Entrar al modo inserción a propósito

Seis teclas distintas entran al modo inserción. Elegir la correcta te ahorra todo un paso de posicionamiento.

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Presioná `3G` (línea `workers 4`), después `$`. Ahora compará:

| Tecla | Dónde empezás a tipear |
|---|---|
| `i` | **i**nsertar *antes* del cursor |
| `a` | **a**gregar (append) *después* del cursor |
| `I` | insertar antes del **primer carácter no blanco** de la línea |
| `A` | agregar al **final de la línea** |
| `o` | **o**pen: abrir una línea nueva *debajo* e insertar |
| `O` | abrir una línea nueva *arriba* e insertar |

3. Con el cursor en la línea 3, presioná `A`, tipeá ` # tuned 2026-08-20`, presioná `<Esc>`. La línea 3 queda así:

```text
    3 workers 4 # tuned 2026-08-20
```

4. Presioná `o`, tipeá `worker_rlimit_nofile 65535`, presioná `<Esc>`. El texto nuevo es la línea 4, y todo lo de abajo se desplazó una línea.

5. Presioná `I`, tipeá `# `, presioná `<Esc>` — la línea que acabás de crear ahora está comentada.

6. Los contadores funcionan con los comandos de inserción. Presioná `G` (última línea), después:

```text
3o---<Esc>
```

Se agregan tres líneas `---` idénticas. Este es el *prefijo de contador*, y se generaliza a casi todos los comandos del modo normal.

7. Descartá todo:

```text
:q!<Enter>
```

**Comprobá lo que entendiste**

**Q12.** El cursor está en la columna 1 de una línea indentada. Necesitás agregar texto al comienzo del *código*, no al comienzo de la *indentación*. ¿Qué tecla?
**Q13.** ¿Qué hace exactamente `5O`?
**Q14.** Tipeaste `A` al final de una sesión y obtuviste un pitido y ningún `-- INSERT --`. ¿Cuál es la causa más probable?

---

## Ejercicio 5 — Borrar, cambiar, copiar y pegar: la gramática operador + movimiento

`d`, `c` e `y` son **operadores**. Un operador solo no hace nada; espera un movimiento. `operador + movimiento` es todo el lenguaje:

```
[count] operator [count] motion
```

Duplicar el operador (`dd`, `cc`, `yy`) lo aplica a la línea entera.

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number<Enter>
```

2. **Borrados de carácter.** Andá a la línea 3 (`3G`), `$`, después presioná `x` — el `4` desaparece. Presioná `u` para deshacer. Presioná `3x` sobre `workers` desde la columna 1 — `wor` desapareció. Deshacé con `u`. (`X` borra *hacia atrás*.)

3. **Borrar con un movimiento.** En la línea 9, presioná `^` y después:

| Comando | Efecto |
|---|---|
| `dw` | borra la palabra `server ` |
| `d$` o `D` | borra desde el cursor hasta el fin de línea |
| `d0` | borra desde el cursor hacia atrás hasta la columna 1 |
| `d%` | con el cursor en la `{` de la línea 8: borra todo el bloque delimitado por llaves |

Probá `dw`, mirá el resultado, presioná `u`. Después presioná `D`, mirá, presioná `u`.

4. **Borrados de línea y contadores.** Presioná `9G` y después `3dd`:

```text
3 fewer lines
```

Las líneas 9–11 (las tres líneas `server`) desaparecieron. Presioná `u`.

5. **Cambiar.** `c` es *borrar y entrar al modo inserción*. En la línea 14 (`log_level info`), presioná `$` y después `b` (inicio de `info`), después:

```text
cwdebug<Esc>
```

```text
   14 log_level debug
```

`cc` cambia la línea entera conservando la indentación; `C` cambia desde el cursor hasta el fin de línea.

6. **Copiar y pegar.** `y` copia. `p` pega **después** del cursor (o **debajo** de la línea, si el yank es por líneas); `P` pega antes/arriba.

Presioná `9G`, después `yy`, después `p`:

```text
    9     server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
   10     server 10.0.2.11:9000 max_fails=3 fail_timeout=10s;
```

Ahora convertí el duplicado en un backend nuevo: con el cursor en la línea 10, presioná `f1` … o simplemente `^`, `W`, y después `cw10.0.2.14:9000<Esc>`.

7. **El registro sin nombre es compartido.** Presioná `dd` en cualquier línea, después movete a otro lado y presioná `p` — la línea borrada reaparece ahí. **Borrar es cortar.** Así se mueve una línea: `dd` y después `p`.

8. **Repetir.** Presioná `.` para repetir el último cambio. Borrá una palabra con `dw`, movete a otra palabra, presioná `.` — borrada de nuevo. Combinado con un contador: `3.` lo repite tres veces.

9. Guardá con un nombre temporal y salí, así podés comparar después:

```text
:w /tmp/svc.edited.conf<Enter>
:q!<Enter>
```

```bash
diff svc.conf.orig /tmp/svc.edited.conf | head
```

**Comprobá lo que entendiste**

**Q15.** Escribí el único comando que borra desde el cursor hasta el final del archivo, y el que borra desde el cursor hasta el principio.
**Q16.** ¿Cuál es la diferencia entre `dw` y `cw` en cuanto al modo en el que terminás, y por qué importa eso cuando lo seguís con `.`?
**Q17.** Necesitás mover 12 líneas desde el medio de un archivo hasta el final. Dá una secuencia en modo normal y una en una sola línea de modo ex.
**Q18.** Después de `dd`, presionás `p` dos veces. ¿Cuántas copias de la línea existen, y dónde?

---

## Ejercicio 6 — Registros: recuperar algo que borraste tres borrados atrás

El registro sin nombre guarda solo el último corte. `vi` también tiene 26 registros con nombre (`a`–`z`) y 9 numerados (`"1`–`"9`) que guardan los últimos nueve borrados **por líneas**. Esta es la diferencia entre "perdí ese bloque" y "lo recuperé".

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Copiá todo el bloque `upstream` al registro con nombre `a`. Presioná `8G`, después:

```text
"a5yy
```

(`"a` selecciona el registro, `5yy` copia cinco líneas en él.)

3. Ahora hacé tres borrados de línea sin relación: `1G`, `dd`; `1G`, `dd`; `1G`, `dd`. El registro sin nombre ahora guarda solo el tercero.

4. Recuperá el *primero* de esos borrados:

```text
G
"1p
```

El borrado más reciente está en `"1`; presioná `u` y probá `"2p`, `"3p` para recorrer el historial hacia atrás.

5. Pegá tu bloque guardado, intacto pese a todos esos borrados:

```text
G
"ap
```

El bloque `upstream` de cinco líneas reaparece al final del archivo.

6. Inspeccioná los registros (Vim; no disponible en el `vi` clásico):

```text
:registers<Enter>
```

```text
Type Name Content
  l  ""   # svc.conf - edge service, staging^J
  l  "1   # svc.conf - edge service, staging^J
  l  "2   listen 0.0.0.0:8080^J
  l  "3   workers 4^J
  l  "a   upstream api {^J    server 10.0.2.11:9000 ...
```

7. Descartá: `:q!<Enter>`.

**Comprobá lo que entendiste**

**Q19.** ¿Qué se guarda en `"1` frente a `"a`, y cuál sobrevive a más borrados?
**Q20.** `"Ayy` (A mayúscula) hace algo distinto de `"ayy`. ¿Qué?
**Q21.** Borraste una *palabra* (no una línea) cuatro borrados atrás. ¿`"4p` la va a traer de vuelta? Explicá.

---

## Ejercicio 7 — Buscar texto: `/`, `?`, y editar a escala con `ex`

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

```text
:set number ignorecase hlsearch<Enter>
```

(`hlsearch` e `incsearch` son agregados de Vim; `ignorecase` también existe en `vi`, abreviado `:set ic`.)

2. **Buscar hacia adelante** con `/`:

```text
/timeout<Enter>
```

El cursor aterriza en `keepalive_timeout` (línea 5). Presioná `n` para la coincidencia siguiente (línea 9), `n` de nuevo (línea 10), `n` otra vez (línea 20, `drain_timeout`), y una vez más:

```text
search hit BOTTOM, continuing at TOP
```

Las búsquedas dan la vuelta por defecto (`:set nowrapscan` lo desactiva). `N` invierte la dirección.

3. **Buscar hacia atrás** con `?`:

```text
?server<Enter>
```

después `n` (que ahora se mueve *hacia atrás*, en la dirección de la búsqueda original) y `N` (hacia adelante).

4. Un patrón que no existe:

```text
/nosuchkey<Enter>
```

```text
E486: Pattern not found: nosuchkey
```

5. Las **expresiones regulares** son de estilo BRE. Los anclajes y las clases funcionan:

```text
/^tls_<Enter>          first line starting with tls_
/[0-9]\{4\}$<Enter>    line ending in four digits (9100)
/\<api\><Enter>        the word api, not "rapid" or "apiserver"
```

6. **Sustitución guiada por búsqueda**, el verdadero caballo de batalla. Redireccioná todo el pool de upstream:

```text
:%s/10\.0\.2\./10.0.3./g<Enter>
```

```text
3 substitutions on 3 lines
```

El rango `%` significa "todas las líneas"; `g` significa "todas las ocurrencias de la línea, no solo la primera". Agregá `c` para confirmar cada una:

```text
:%s/timeout/TIMEOUT/gc<Enter>
```

```text
replace with TIMEOUT (y/n/a/q/l/^E/^Y)?
```

Presioná `q` para abortar. Deshacé el cambio de direcciones con `u`.

7. **Comandos ex con rango.** Los rangos aceptan números de línea, `.` (línea actual), `$` (última línea), `%` (todas) y `/patrón/`:

```text
:9,11d<Enter>          delete lines 9 to 11
u
:5t$<Enter>            copy line 5 to the end of the file
:5m$<Enter>            move line 5 to the end of the file
u
u
:1,12w /tmp/head.conf<Enter>   write only lines 1-12 to another file
```

8. **`:g` — aplicar un comando a cada línea coincidente.** Este es el que escala a un log de 200 000 líneas:

```text
:g/^$/d<Enter>
```

```text
2 fewer lines
```

Todas las líneas en blanco desaparecieron. Deshacé con `u`, y después probá lo inverso:

```text
:v/^tls_/d<Enter>
```

Se borra todo lo que **no** coincide con `^tls_` (`:v` es `:g!`). Deshacé con `u`.

9. Descartá: `:q!<Enter>`.

**Comprobá lo que entendiste**

**Q22.** Dá el comando exacto para reemplazar todas las ocurrencias de `info` por `warn` en todo el archivo, pidiendo confirmación cada vez.
**Q23.** ¿Por qué hay que escribir `10.0.2.` como `10\.0\.2\.` en el lado izquierdo de `:s`, pero no en el lado derecho?
**Q24.** Después de `/error`, presionás `n` cinco veces y terminás *por encima* de donde empezaste. ¿Qué pasó, y qué ajuste lo desactiva?
**Q25.** Escribí un comando que borre del búfer todas las líneas que contienen `DEBUG`, y otro que conserve solo esas líneas.

---

## Ejercicio 8 — Deshacer, rehacer y la trampa de la compatibilidad

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Hacé tres cambios separados: `1G` `dd`; `1G` `dd`; `1G` `dd`.

3. Presioná `u`. Vim informa algo como:

```text
1 more line; before #3  4 seconds ago
```

4. Presioná `u` dos veces más. Si vuelven los tres borrados, tenés **deshacer multinivel**. Ahora presioná `Ctrl-R` tres veces — los borrados se rehacen.

5. Probá el comportamiento del `vi` clásico deliberadamente:

```text
:set compatible<Enter>
```

Borrá una línea con `dd`, presioná `u` (vuelve), presioná `u` otra vez — en modo compatible `u` **alterna**: la línea se borra de nuevo. Este es el comportamiento histórico de `vi` y es lo que obtenés en un sistema verdaderamente mínimo.

```text
:set nocompatible<Enter>
```

6. `U` (mayúscula) es un comando distinto en ambos: deshace *todos los cambios recientes en la última línea que tocaste*. Andá a la línea 5, presioná `x` cuatro veces, después presioná `U` — la línea se restaura en un solo paso.

7. Confirmá con qué ajuste arranca realmente tu editor:

```text
:set compatible?<Enter>
```

```text
nocompatible
```

8. Descartá: `:q!<Enter>`.

**Comprobá lo que entendiste**

**Q26.** Distinguí `u`, `U` y `Ctrl-R`.
**Q27.** Estás en un sistema embebido desconocido, presionás `u` dos veces, y tu segundo deshacer vuelve a aplicar el cambio. ¿Qué te dice eso sobre el editor, y cómo deberías adaptar tus hábitos de edición por el resto de la sesión?

---

## Ejercicio 9 — Escribir y salir: todas las combinaciones que nombra el objetivo

Este es el bloque que más se falla bajo la presión de tiempo del examen. Hacelo hasta que sea memoria muscular.

1. Restaurá y abrí:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

2. Hacé un cambio (`1G`, `dd`), después intentá salir sin más:

```text
:q<Enter>
```

```text
E37: No write since last change (add ! to override)
```

3. Ahora la tabla completa. Probá cada una sobre una copia fresca:

| Comando | Significado |
|---|---|
| `:w` | escribe el búfer en su archivo, seguís en el editor |
| `:w <file>` | escribe el búfer en *otro* archivo, seguís editando el original |
| `:w!` | fuerza la escritura (búfer de solo lectura, o permisos restrictivos que podés anular) |
| `:q` | salir — se niega si hay cambios sin guardar |
| `:q!` | salir y **descartar los cambios** |
| `:wq` | escribir (siempre, aunque no haya modificaciones) y salir |
| `:x` | escribir **solo si hubo modificaciones**, y salir |
| `ZZ` | igual que `:x`, desde modo normal, sin dos puntos |
| `ZQ` | igual que `:q!` (solo Vim) |
| `:wqa` / `:qa!` | se aplica a *todos* los búferes abiertos (Vim) |

4. Demostrá que `:wq` y `:x` no son idénticos:

```bash
cp svc.conf.orig svc.conf
stat -c '%y' svc.conf
vi svc.conf     # change nothing; type :wq<Enter>
stat -c '%y' svc.conf
cp svc.conf.orig svc.conf
stat -c '%y' svc.conf
vi svc.conf     # change nothing; type :x<Enter>
stat -c '%y' svc.conf
```

`:wq` actualiza la fecha de modificación aunque no haya cambios; `:x` no. En un host donde `make`, el `creates:` de Ansible, o un vigilante de configuración se disparan según la mtime, esa diferencia es una recarga espuria del servicio.

5. Manejo de solo lectura. Abrí el archivo deliberadamente en solo lectura:

```bash
vi -R svc.conf      # same as the `view` command
```

Intentá tipear `x`:

```text
W10: Warning: Changing a readonly file
```

Después:

```text
:w<Enter>
```

```text
E45: 'readonly' option is set (add ! to override)
```

```text
:w!<Enter>
```

Observá si tiene éxito. Después salí y repetí la misma prueba en un archivo que **no** sea tuyo:

```bash
sudo cp svc.conf /etc/svc-lab.conf 2>/dev/null || true
vi /etc/svc-lab.conf    # try x, then :w!, then :q!
```

```text
E212: Can't open file for writing
```

6. Limpieza: `sudo rm -f /etc/svc-lab.conf`

**Comprobá lo que entendiste**

**Q28.** Abriste `/etc/fstab` con `vi` (no con `sudo vi`), hiciste ediciones cuidadosas, y recién ahora notás `E45`. Describí dos maneras de conservar tu trabajo, y decí cuál es la correcta en un host de producción.
**Q29.** ¿Por qué `:w!` tuvo éxito en un archivo tuyo con modo `0400`, pero falló con `E212` en un archivo propiedad de root? ¿Qué permiso es realmente decisivo?
**Q30.** Necesitás conservar el original y guardar las ediciones en otro lado. Dá el comando.

---

## Ejercicio 10 — Archivos de intercambio (swap) y recuperación ante caídas

Una sesión de `vi` que muere (caída de SSH, OOM kill, corte de energía) normalmente deja un archivo swap recuperable. Saber esto es la diferencia entre rehacer 40 minutos de trabajo y presionar `R`.

1. Restaurá y abrí el archivo, hacé un cambio, y **dejá el editor corriendo**:

```bash
cp svc.conf.orig svc.conf && vi svc.conf
```

Dentro: `1G`, `O`, tipeá `# emergency change, incident INC-4471`, `<Esc>`. **No** guardes.

2. Desde una segunda terminal, mirá el directorio y el proceso:

```bash
cd ~/lab-103.8 && ls -a
```

```text
.  ..  .svc.conf.swp  svc.conf  svc.conf.orig
```

```bash
pgrep -a 'vi|vim'
```

```text
4711 vi svc.conf
```

3. Simulá la caída:

```bash
kill -9 4711        # use the PID you actually saw
```

4. De vuelta en la primera terminal, reabrí el archivo:

```bash
vi svc.conf
```

```text
E325: ATTENTION
Found a swap file by the name ".svc.conf.swp"
          owned by: alice   dated: Wed Aug 26 09:41:12 2026
         file name: ~alice/lab-103.8/svc.conf
          modified: YES
         user name: alice   host name: node01
        process ID: 4711 (still running)
While opening file "svc.conf"
             dated: Wed Aug 26 09:40:58 2026
...
Swap file ".svc.conf.swp" already exists!
[O]pen Read-Only, (E)dit anyway, (R)ecover, (D)elete it, (Q)uit, (A)bort:
```

5. Presioná `R`. Tu línea sin guardar volvió. Guardala, y después **borrá vos mismo el archivo swap** — la recuperación no lo elimina:

```text
:w<Enter>
:q<Enter>
```

```bash
ls -a; rm -f .svc.conf.swp
```

6. Recuperá de forma no interactiva (como lo harías en un host donde el archivo ya está abierto en otro lado):

```bash
vi -r svc.conf
```

7. Para tener en cuenta: el `nvi` clásico no usa un archivo swap oculto junto al documento; guarda los datos de recuperación en `/var/tmp/vi.recover/` y le manda al dueño un mensaje de "vi recovery" por correo. `busybox vi` no tiene recuperación en absoluto.

**Comprobá lo que entendiste**

**Q31.** El diálogo del swap dice `process ID: 4711 (still running)`. ¿Qué es lo que *no* tenés que elegir, y qué deberías hacer primero?
**Q32.** Después de una `R` exitosa y un `:w`, ¿por qué hay que borrar igual el archivo swap?
**Q33.** Estás editando en un sistema de archivos raíz de solo lectura y `vi` se queja de que no puede crear un archivo swap. ¿Qué ajuste te permite continuar, y qué perdés?

---

## Ejercicio 11 — Editar archivos de producción sin romperlos

Acá es donde el objetivo se encuentra con las operaciones reales. Todo lo de abajo es verificable con `stat`.

1. Armá un experimento de inodo/enlace duro:

```bash
cd ~/lab-103.8
cp svc.conf.orig target.conf
ln target.conf hardlink.conf
ln -s target.conf symlink.conf
stat -c '%n inode=%i links=%h mode=%a' target.conf hardlink.conf
```

```text
target.conf inode=1310721 links=2 mode=644
hardlink.conf inode=1310721 links=2 mode=644
```

2. Editá con la estrategia de **copia** (escribir en el lugar):

```bash
vi target.conf
```

```text
:set backupcopy=yes<Enter>
:set backupcopy?<Enter>          confirm it took
A # touched<Esc>
:wq<Enter>
```

```bash
stat -c '%n inode=%i links=%h' target.conf hardlink.conf
```

El inodo no cambió y `links=2` — el enlace duro sigue viendo tu edición.

3. Ahora la estrategia de **renombrado**:

```bash
vi target.conf
```

```text
:set backupcopy=no<Enter>
A # again<Esc>
:wq<Enter>
```

```bash
stat -c '%n inode=%i links=%h' target.conf hardlink.conf
grep -c touched hardlink.conf
```

El inodo de `target.conf` cambió, `links=1`, y `hardlink.conf` es ahora un *archivo distinto*, congelado en el contenido viejo.

4. Repetí el paso 3 contra el **enlace simbólico**:

```bash
vi symlink.conf     # :set backupcopy=no, edit, :wq
ls -l symlink.conf
```

Con `backupcopy=no`, el enlace simbólico es reemplazado por un archivo regular. Así es exactamente como la gente destruye `/etc/resolv.conf → ../run/systemd/resolve/stub-resolv.conf`, o un enlace de `/etc/alternatives`, con una edición "inofensiva".

5. Comprobá el valor por defecto que usa tu editor, y de dónde salió:

```bash
vi target.conf
```

```text
:verbose set backupcopy?<Enter>
:q<Enter>
```

6. **Nunca hagas `sudo vi` sobre un archivo de sistema si existe `sudoedit`.** Compará los dos:

```bash
sudo -e /etc/hosts        # same as: sudoedit /etc/hosts
```

`sudoedit` copia el archivo a una ruta temporal, ejecuta **tu** editor como **tu** usuario (vía `SUDO_EDITOR`, después `VISUAL`, después `EDITOR`), y copia el resultado de vuelta con la propiedad y el modo originales. `sudo vi` ejecuta todo el editor como root — y `:!bash` dentro de él es un shell de root sin registrar, que es por lo que una regla de sudoers que otorga `sudo vi` otorga root completo.

7. Los comandos del sistema que conocen al editor:

```bash
export EDITOR=vi
crontab -e        # edits a temp copy; installs and syntax-checks on exit
sudo visudo       # locks /etc/sudoers, validates before installing
sudo visudo -c    # validate only
sudo visudo -f /etc/sudoers.d/90-lab   # correct way to edit a drop-in
```

Rompé deliberadamente la sintaxis dentro de `visudo` (tipeá una palabra suelta `garbage` en su propia línea) y salí:

```text
>>> /etc/sudoers: syntax error near line 25 <<<
What now?
Options are:
  (e)dit sudoers file again
  e(x)it without saving changes to sudoers file
  (Q)uit and save changes to sudoers file (DANGER!)
```

Presioná `x`. Esta validación es toda la razón por la que existe `visudo` — un `/etc/sudoers` roto deja a todos los usuarios afuera de `sudo`.

8. Bash puede entregarle la línea de comandos actual a tu editor. Tipeá un comando largo, **no** presiones Enter, y después presioná `Ctrl-x Ctrl-e`: se abre en `$VISUAL`/`$EDITOR`; guardar y salir lo ejecuta.

9. Limpieza:

```bash
rm -f target.conf hardlink.conf symlink.conf
sudo rm -f /etc/sudoers.d/90-lab
```

**Comprobá lo que entendiste**

**Q34.** En una oración cada uno, indicá qué le hacen `backupcopy=yes` y `backupcopy=no` al inodo del archivo, y dá un escenario de producción donde la elección equivocada causa una caída del servicio.
**Q35.** Una regla de sudoers dice `alice ALL=(root) NOPASSWD: /usr/bin/vi /etc/nginx/nginx.conf`. ¿Por qué esto equivale a darle a alice root completo, y cuál es la regla correcta?
**Q36.** ¿Por qué es preferible `crontab -e` a editar `/var/spool/cron/crontabs/alice` directamente con `vi`?

---

## Ejercicio 12 — Editar YAML/JSON como realmente vas a tener que hacerlo

Dos ajustes de `vi` explican la mayoría de los manifiestos de Kubernetes destrozados.

1. Creá un manifiesto y abrilo:

```bash
cat > deploy.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: edge
          image: registry.local/edge:1.4.2
EOF
vi deploy.yaml
```

2. Hacé visibles los tabuladores y los espacios finales — YAML prohíbe los tabuladores para la indentación, y de otro modo son invisibles:

```text
:set list<Enter>
:set listchars=tab:>-,trail:·<Enter>
```

Insertá un tabulador literal en algún lado con `o<Tab>foo<Esc>` y mirá cómo aparece `>---`. Deshacelo.

3. Configurá una indentación sensata, y después probá la trampa del pegado. Con `autoindent` activo, pegá un bloque de varias líneas desde el portapapeles en la terminal:

```text
:set expandtab shiftwidth=2 tabstop=2 autoindent<Enter>
```

El bloque pegado forma una "escalera" — cada línea queda indentada por la indentación de la línea anterior *más* la suya propia. El arreglo:

```text
:set paste<Enter>
```

pegá de nuevo (limpio esta vez), y después:

```text
:set nopaste<Enter>
```

4. Quitá los espacios finales en todo el archivo y confirmá:

```text
:%s/\s\+$//e<Enter>
:wq<Enter>
```

```bash
grep -nP '\s+$' deploy.yaml || echo "no trailing whitespace"
```

```text
no trailing whitespace
```

5. Filtrá el búfer a través de un comando externo. Reabrí y probá:

```text
:r !date -u +%FT%TZ<Enter>       insert command output at the cursor
:r /etc/hostname<Enter>          insert a file at the cursor
:14,20!sort<Enter>               sort a line range in place
:%!grep -v '^#'<Enter>           replace the buffer with the filter's output
u                                 undo the filter
:!ls -l %<Enter>                 run a shell command, % = current file name
```

6. Conciencia sobre binarios:

```bash
vi -b /bin/true
```

```text
:%!xxd<Enter>        render as hex
:%!xxd -r<Enter>     convert back
:q!<Enter>
```

Nunca guardes un binario abierto sin `-b`: sin él, `vi` puede normalizar los fines de línea y agregar un salto de línea final, corrompiendo el archivo.

**Comprobá lo que entendiste**

**Q37.** ¿Qué sale mal exactamente cuando pegás YAML indentado en `vi` con `autoindent` activado, y qué dos comandos encierran el pegado?
**Q38.** `:%!sort` y `:r !sort` involucran ambos un `sort` externo. ¿Cuál es la diferencia en el efecto?
**Q39.** ¿Por qué importa `:set list` específicamente para editar YAML y `Makefile`?

---

## Ejercicio 13 — Conocimiento general: nano, Emacs y el resto de la familia

El objetivo exige *conocimiento* de las alternativas. Deberías poder abrir, guardar y salir de cada una sin ayuda.

1. **nano** — la barra de atajos en pantalla es la documentación. `^` significa Control, `M-` significa Alt/Meta.

```bash
nano -w svc.conf
```

| Teclas | Acción |
|---|---|
| `Ctrl-O` | write **O**ut (guardar) — pide el nombre del archivo, confirmá con `Enter` |
| `Ctrl-X` | salir (pregunta si guardar cuando hay modificaciones) |
| `Ctrl-W` | **W**here is — buscar |
| `Ctrl-\` | buscar y reemplazar |
| `Ctrl-K` | cortar la línea actual |
| `Ctrl-U` | uncut (pegar) |
| `Ctrl-G` | ayuda |
| `Ctrl-C` | mostrar la posición del cursor |
| `Alt-U` / `Alt-E` | deshacer / rehacer |

La opción `-w` desactiva el ajuste de línea duro. En versiones viejas de nano, el ajuste estaba **activado** por defecto y partía silenciosamente las líneas largas en los archivos de configuración — una causa genuina de archivos rotos en `/etc`. Guardá una copia como `/tmp/nano-test.conf` con `Ctrl-O`, cambiá el nombre del archivo en el prompt, y después `Ctrl-X`.

2. **Emacs** — sin modos, con acordes. `C-x` significa Control-x; `M-x` significa Alt-x.

```bash
emacs -nw svc.conf     # -nw = no window, run in the terminal
```

| Teclas | Acción |
|---|---|
| `C-x C-s` | guardar |
| `C-x C-c` | salir |
| `C-g` | cancelar el comando actual (tu `<Esc>`) |
| `C-k` | kill (cortar) hasta el fin de línea |
| `C-y` | yank (pegar) |
| `C-s` / `C-r` | búsqueda incremental hacia adelante / hacia atrás |
| `C-_` o `C-x u` | deshacer |
| `C-x C-f` | abrir otro archivo |

Si `emacs` no está instalado, ese hecho ya es relevante para el examen: `vi` es el único editor garantizado en un sistema POSIX.

3. **El resto de la familia**, en una línea cada uno:

- `vim` — Vi IMproved: deshacer multinivel, modo visual, resaltado de sintaxis, `:help`.
- `vi` — en la mayoría de las distribuciones, un enlace simbólico o una compilación mínima de `vim`; a veces `nvi` o `elvis`.
- `busybox vi` — un subconjunto diminuto que se encuentra en Alpine/initramfs/contenedores; sin archivo swap, sin `:g`.
- `ed` — el editor de líneas del que surgió `vi`; sigue siendo el único editor garantizado para funcionar sobre un enlace de 300 baudios o en un shell de rescate con el `TERM` roto.
- `sed` — el editor de *flujos* (stream): el mismo lenguaje de comandos, no interactivo.

4. Corré el tutorial incorporado una vez — son 25 minutos y es la preparación más eficiente para este objetivo:

```bash
vimtutor
```

**Comprobá lo que entendiste**

**Q40.** Dá las pulsaciones para guardar y salir en `vi`, `nano` y Emacs.
**Q41.** Entrás por SSH a un contenedor para arreglar una configuración y `vi` se comporta raro — sin historial de `u`, `:set` mayormente ignorado, sin `:g`. ¿Qué estás corriendo probablemente, y cuál es la forma más segura de hacer el cambio?
**Q42.** ¿Por qué el objetivo de LPI insiste en `vi` en vez de permitir nano en todos lados?

---

## Referencia: las teclas nombradas por el objetivo 103.8

| Tecla | Modo | Acción |
|---|---|---|
| `h` `j` `k` `l` | normal | izquierda, abajo, arriba, derecha |
| `i` `a` `o` | normal → inserción | insertar antes del cursor / agregar después del cursor / abrir línea debajo |
| `c` | normal (operador) | cambiar (borrar + insertar), necesita un movimiento: `cw`, `cc`, `C` |
| `d` | normal (operador) | borrar, necesita un movimiento: `dw`, `d$`, `dd`, `D` |
| `y` | normal (operador) | yank (copiar), necesita un movimiento: `yw`, `yy` |
| `dd` | normal | borrar la línea actual (al registro sin nombre) |
| `p` | normal | pegar después del cursor / debajo de la línea (`P` = antes/arriba) |
| `/` | normal → búsqueda | buscar hacia adelante (`n` siguiente, `N` anterior) |
| `?` | normal → búsqueda | buscar hacia atrás |
| `ZZ` | normal | escribir si hubo modificaciones, después salir |
| `:w!` | línea de comandos | forzar la escritura |
| `:q!` | línea de comandos | salir, descartando los cambios |
| `:!cmd` | línea de comandos | ejecutar un comando de shell sin salir del editor |

---

## Respuestas

<details>
<summary><b>Hacé clic para revelar las respuestas de Q1–Q42</b></summary>

**A1.** `which vi` informa el primer `vi` en `$PATH`, que casi siempre es un enlace simbólico (`/usr/bin/vi`) o un enlace de alternatives. `readlink -f` resuelve toda la cadena de enlaces simbólicos hasta el binario real, así que te dice si estás por ejecutar `vim.tiny`, un `vim` completo, `nvi` o `busybox`. Esos difieren en características que importan en medio de una edición (profundidad de deshacer, modo visual, `:g`).

**A2.** `Ctrl-R` (rehacer) es un agregado de Vim. No existe en el `vi`/`nvi` clásico, y no está disponible en `busybox vi`. Además se comporta de forma inútil en Vim cuando `compatible` está activo, porque entonces `u` alterna en vez de retroceder por un árbol de deshacer. Probá con `:set compatible?` antes de confiar en él.

**A3.** Cualquiera de: `crontab -e`, `visudo`, `sudoedit`/`sudo -e`, `git commit` (vía `core.editor`, que recae en `$EDITOR`), `systemctl edit`, el `Ctrl-x Ctrl-e` de `bash` (`edit-and-execute-command`), `less` con `v`. La mayoría consulta `VISUAL` antes que `EDITOR`; `sudoedit` revisa `SUDO_EDITOR` primero.

**A4.** *Modo normal (comando)* — el modo en el que arrancás, donde las teclas son comandos; se llega desde cualquier lado con `<Esc>`. *Modo inserción* — el texto que tipeás se inserta; se sale con `<Esc>`. *Modo línea de comandos (ex)* — se entra con `:` (también `/` y `?`), los comandos se tipean en la línea inferior; se sale con `<Esc>` o presionando `<Enter>` para ejecutar.

**A5.** Estabas en modo inserción, así que `dd` fue texto literal. Presioná `<Esc>` para volver al modo normal, después `u` para deshacer los dos caracteres insertados (o `x` dos veces). Después volvé a emitir `dd`.

**A6.** `u` deshace un cambio por vez dentro de la sesión de edición actual, conservando el historial de deshacer del búfer. `:e!` descarta **todos** los cambios sin guardar releyendo el archivo desde el disco — es un reinicio completo al último estado guardado, y no se puede deshacer.

**A7.** `Ctrl-[` envía el mismo carácter de control (0x1B, ESC) que la tecla Escape. En consolas serie, visores IPMI/KVM, algunos emuladores de terminal y teclados donde Escape está remapeada o lejos de la fila base, `Ctrl-[` es más rápido y siempre está disponible. También evita la ambigüedad con terminales que usan un tiempo de espera para distinguir un `<Esc>` suelto de una secuencia de escape.

**A8.** Línea 17: `17G` (modo normal) o `:17<Enter>` (modo ex). Última línea: `G` sin contador (o `:$<Enter>`).

**A9.** `w` trata la puntuación como separadora de palabras, así que `10.0.2.11:9000` son muchas "palabras" — tendrías que presionar `w` alrededor de una docena de veces. `W` usa WORDs delimitadas por espacios en blanco, así que dos pulsaciones (`server`, después la dirección) te dejan en `backup`. Regla: los movimientos en minúscula respetan los límites de puntuación; los de mayúscula solo respetan los blancos.

**A10.** `%` — poné el cursor en la `{` de apertura y presioná `%`. Si el cursor salta a una `}`, las llaves están balanceadas hasta ese punto y podés ver exactamente dónde termina el bloque. Si el cursor no se mueve, no hay corchete coincidente — el bloque está desbalanceado (o el cursor no estaba sobre un corchete para empezar).

**A11.** `Ctrl-D` desplaza media pantalla, así que la mitad del texto visible previamente queda en pantalla y te da continuidad visual — no podés saltearte una línea por accidente. `Ctrl-F` avanza una pantalla completa y, si parpadeás o la terminal es chica, puede pasar contenido sin llegar a leerse cómodamente.

**A12.** `I` — insertar antes del primer carácter no blanco. `i` en la columna 1 insertaría *antes de la indentación*.

**A13.** Abre **cinco** líneas vacías nuevas encima de la línea actual y te deja en modo inserción; lo que tipees se repite en cada una de las cinco líneas cuando presionás `<Esc>`.

**A14.** Ya estabas en modo inserción cuando presionaste `A`, así que se insertó como texto literal — o el búfer es de solo lectura (`vi -R` / `view` / sin permiso de escritura), en cuyo caso Vim pita y muestra `W10: Warning: Changing a readonly file`. Fijate en la línea inferior y presioná `<Esc>`.

**A15.** Hasta el final del archivo: `dG`. Hasta el principio del archivo: `dgg` (Vim) o `d1G` (funciona en todos lados).

**A16.** `dw` borra y te deja en modo **normal**; `cw` borra y te deja en modo **inserción**. Eso importa para `.` porque el comando de repetición reproduce el cambio *entero*, incluido el texto tipeado: `.` después de `cw` vuelve a tipear la palabra de reemplazo en el objetivo siguiente, que es lo que hace de `cw` + `n` + `.` el bucle de renombrado manual más rápido en `vi`.

**A17.** Modo normal: poné el cursor en la primera línea, presioná `12dd`, presioná `G`, presioná `p`. Modo ex, en un solo comando: `:.,+11m$` (o `:15,26m$` con números de línea explícitos).

**A18.** Existen tres copias: la original se cortó al registro sin nombre y se sacó del búfer, después `p` la puso de vuelta una vez y `p` otra vez puso una segunda copia debajo de la primera. El registro sigue conteniendo la línea, así que un tercer `p` haría una cuarta.

**A19.** `"1` guarda el **borrado por líneas** más reciente, y se corre por la cadena (`"1`→`"2`→…→`"9`) con cada borrado de línea nuevo, así que se destruye después de nueve borrados más. `"a` es un registro con nombre en el que escribiste explícitamente; nada lo sobrescribe salvo otra escritura explícita a `"a` (o salir del editor — los registros son estado de sesión salvo que `viminfo`/`shada` los persista).

**A20.** El `"a` en minúscula **sobrescribe** el registro `a`. El `"A` en mayúscula le **agrega** (append). Así es como juntás líneas dispersas de todo un archivo en un solo registro antes de pegarlas como bloque.

**A21.** No. Los registros numerados `"1`–`"9` solo reciben borrados **por líneas** (y borrados que abarcan más de una línea). Los borrados chicos dentro de una línea, como `dw` o `x`, van al registro de "borrado pequeño" `"-` y a `""`, y solo sobrevive el más reciente. Si vas a necesitar una palabra después, copiala explícitamente a un registro con nombre.

**A22.** `:%s/info/warn/gc<Enter>` — `%` = todas las líneas, `g` = todas las ocurrencias por línea, `c` = confirmar cada una.

**A23.** En el lado izquierdo, `.` es un metacarácter de expresión regular que coincide con *cualquier* carácter, así que un `10.0.2.` sin escapar también coincidiría con `10x0y2z`. Escaparlo como `\.` fuerza un punto literal. El lado derecho es una *cadena de reemplazo*, no un patrón — ahí `.` no tiene ningún significado especial (los caracteres que sí lo tienen son `&`, `\1`–`\9`, `~` y `\`).

**A24.** La búsqueda dio la vuelta: después de la última coincidencia del archivo continuó desde arriba, imprimiendo `search hit BOTTOM, continuing at TOP`. Se desactiva con `:set nowrapscan` (`:set nows`), que hace que la búsqueda falle con `E385: search hit BOTTOM without match` en vez de dar vueltas silenciosamente.

**A25.** Borrar las líneas coincidentes: `:g/DEBUG/d`. Conservar solo las coincidentes: `:v/DEBUG/d` (equivalentemente `:g!/DEBUG/d`).

**A26.** `u` deshace el último cambio (repetible en el modo `nocompatible` de Vim, un alternador en el `vi` clásico). `U` deshace **todos** los cambios recientes hechos en la última línea que editaste, como una sola operación — y `U` en sí se puede deshacer con `u`. `Ctrl-R` rehace lo que `u` deshizo; es una característica exclusiva de Vim.

**A27.** Se está comportando como el `vi` clásico (o Vim con `compatible` activo): `u` es un alternador de un solo nivel, no un historial. Adaptate haciendo cambios chicos y verificables y guardando seguido — para cualquier cosa más grande, guardá primero una copia de control (`:w /tmp/file.bak`) o usá `:e!` para volver al último guardado, porque no hay un historial de deshacer por el que retroceder.

**A28.** (1) `:w /tmp/fstab.new`, salir, y después `sudo cp /tmp/fstab.new /etc/fstab` — pero eso arriesga perder la propiedad/el modo/el contexto de SELinux. (2) `:w !sudo tee %` escribe el búfer a `sudo tee`, pero dispara un pedido de contraseña dentro del editor, no funciona en `vim.tiny`, y deja el búfer marcado como modificado. La práctica correcta en producción es haberlo abierto con `sudoedit /etc/fstab` desde el principio, que preserva la propiedad y el modo y nunca ejecuta el editor como root.

**A29.** Para un archivo tuyo con modo `0400`, `:w!` puede tener éxito igual porque Vim puede o bien cambiar temporalmente el modo (sos el dueño, así que `chmod` está permitido) o bien escribir un archivo nuevo en el directorio y renombrarlo — y tenés permiso de escritura sobre el *directorio*. Para un archivo propiedad de root, ninguna de las dos cosas es posible: no podés hacerle `chmod` y no podés crear archivos en `/etc`, así que la escritura falla con `E212`. El permiso decisivo es el acceso de escritura al **directorio contenedor**, más la propiedad — no los bits de modo del archivo en sí.

**A30.** `:w /path/to/newfile` — escribe el búfer con un nombre nuevo y deja el original intacto en el disco. (Tené en cuenta que seguís editando el archivo original; usá `:saveas` en Vim si querés que el búfer cambie al nombre nuevo.)

**A31.** **No** elijas `(R)ecover` ni `(E)dit anyway` — hay otro proceso vivo editando el mismo archivo, y dos escritores se van a sobrescribir mutuamente. Elegí `(O)pen Read-Only` o `(Q)uit`, encontrá la otra sesión (`pgrep -a vim`, `who`, o reconectate a la sesión de `tmux`/`screen`), y dejá que guarde y salga primero.

**A32.** El archivo swap no lo borra la recuperación en sí — Vim lo deja deliberadamente, para que una recuperación fallida o parcial se pueda reintentar. Hasta que lo saques, cada apertura posterior de ese archivo muestra el aviso `E325 ATTENTION`, lo que entrena a la gente a apretar `(E)dit anyway` por reflejo y eventualmente perder trabajo real.

**A33.** `:set noswapfile` (o arrancar con `vim -n`) te deja editar sin archivo swap. Perdés la recuperación ante caídas por completo — si la sesión muere, los cambios sin guardar se van — y perdés el aviso multiusuario de "este archivo ya se está editando". Como alternativa, apuntá el swap a otro lado con `:set directory=/tmp` o `--cmd 'set dir=/dev/shm'`.

**A34.** `backupcopy=yes` copia el original a un lado y después sobrescribe el archivo original en el lugar, así que el **inodo, los enlaces duros, la propiedad, el modo y los atributos extendidos se preservan**. `backupcopy=no` renombra el original para sacarlo del camino y escribe un archivo completamente nuevo, así que el archivo obtiene un **inodo nuevo**, los enlaces duros se rompen y los enlaces simbólicos son reemplazados por archivos regulares. Fallo de producción: editar un archivo montado por bind dentro de un contenedor (Kubernetes proyecta un inodo específico; el contenedor sigue viendo el contenido viejo), editar una configuración con enlaces duros, o editar `/etc/resolv.conf` que es un enlace simbólico hacia `/run` — el enlace se destruye y el resolver deja de actualizarse.

**A35.** Dentro de `vi` podés tipear `:!/bin/bash`, `:shell`, o `:r !cmd`. Como `sudo` ejecuta todo el editor como root, ese shell es un shell de root — la regla otorga root sin restricciones, y el escape a shell no queda registrado como un comando de sudo. Además, `vi` puede hacer `:w` a *cualquier* ruta, no solo a la nombrada en la regla. La regla correcta usa `sudoedit`, que ejecuta el editor sin privilegios: `alice ALL=(root) NOPASSWD: sudoedit /etc/nginx/nginx.conf`.

**A36.** `crontab -e` edita una copia temporal privada, invoca tu `$VISUAL`/`$EDITOR`, **analiza el resultado antes de instalarlo**, se niega a instalar un crontab sintácticamente inválido, e instala el archivo con la propiedad, el modo y la ubicación correctos mientras mantiene un bloqueo. Editar el archivo del spool directamente saltea la comprobación de sintaxis y el bloqueo, puede dejar un dueño o un modo equivocados (lo que hace que `cron` ignore el archivo), y compite con un `crontab` que se ejecute en paralelo.

**A37.** Con `autoindent` activo, `vi` no puede distinguir las pulsaciones pegadas de las tipeadas, así que agrega su propia indentación a cada línea entrante *encima de* la indentación que ya trae el texto pegado — produciendo una escalera cada vez más ancha, que en YAML cambia la estructura del documento. Encerrá el pegado con `:set paste` antes y `:set nopaste` después (en Vim moderno también podés usar bracketed paste o `"+p` desde un registro, que no se ven afectados).

**A38.** `:%!sort` **filtra** el búfer: todo el búfer se le pasa a `sort` por stdin y se *reemplaza* por su salida. `:r !sort` **lee** la salida del comando y la inserta en el cursor, dejando en su lugar el contenido existente del búfer — y acá `sort` no tendría entrada, así que se quedaría colgado esperando en stdin.

**A39.** Ambos formatos tratan los tabuladores y los espacios como semánticamente distintos, y ninguno de los dos es visible en pantalla. YAML prohíbe los caracteres de tabulación para la indentación de plano; un `Makefile` requiere un tabulador real al principio de la línea de una receta y falla con `missing separator` si son espacios. `:set list` (con `listchars`) muestra explícitamente los tabuladores, los blancos finales y el fin de línea, convirtiendo un error invisible en uno visible.

**A40.** `vi`: `<Esc>` y después `ZZ` (o `:wq<Enter>` / `:x<Enter>`). `nano`: `Ctrl-O`, `Enter` para confirmar el nombre del archivo, y después `Ctrl-X`. Emacs: `C-x C-s` y después `C-x C-c`.

**A41.** Casi con seguridad estás corriendo `busybox vi` (típico de las imágenes de Alpine y de initramfs), que implementa solo un subconjunto pequeño de `vi`. El enfoque más seguro es no editar en el lugar en absoluto: cambiá el archivo en la imagen/el manifiesto/el ConfigMap que lo produjo y volvé a desplegar. Si tenés que parchear en vivo, hacé el cambio con una herramienta no interactiva cuyo resultado puedas verificar (`sed -i`, o `cat > file <<'EOF'` escribiendo el contenido completo previsto), y sacale un diff después — los contenedores están pensados para reemplazarse, no para editarse.

**A42.** `vi` es el único editor de pantalla exigido por POSIX, así que está presente en prácticamente todos los sistemas tipo UNIX, incluidas las instalaciones mínimas, los entornos de rescate, los appliances y las imágenes de proveedores donde nano y Emacs no están instalados y no hay un gestor de paquetes al alcance. Un administrador que solo sabe usar nano queda bloqueado justo cuando más importa — durante una recuperación. Esa es también la razón por la que conocer `ed` tiene valor: funciona incluso cuando el tipo de terminal es inutilizable.

</details>

---

## Fuentes

- LPI, *Exam 101 Objectives (LPIC-1 version 5.0)*, objetivo 103.8 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- The Open Group, *POSIX.1-2017, `vi` utility* (el comportamiento que toda implementación debe proveer) — <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html>
- Documentación del proyecto Vim (`:help` tal como se publica en línea): movimientos <https://vimhelp.org/motion.txt.html>, cambio de texto <https://vimhelp.org/change.txt.html>, recuperación <https://vimhelp.org/recover.txt.html>, opciones incluidas `'backupcopy'`, `'compatible'` y `'paste'` <https://vimhelp.org/options.txt.html>
- GNU nano, *nano(1) manual page* — <https://www.nano-editor.org/dist/latest/nano.1.html>
- GNU Emacs, *Emacs Manual — Basic Editing Commands* — <https://www.gnu.org/software/emacs/manual/html_node/emacs/Basic.html>
- Proyecto Sudo, *sudoedit / sudo(8)* — <https://www.sudo.ws/docs/man/sudo.man/> — y *visudo(8)* — <https://www.sudo.ws/docs/man/visudo.man/>
- Proyecto Linux man-pages, *crontab(1)* — <https://man7.org/linux/man-pages/man1/crontab.1.html>
- Debian, *update-alternatives(1)* (cómo se resuelve `/usr/bin/vi` en sistemas de la familia Debian) — <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>