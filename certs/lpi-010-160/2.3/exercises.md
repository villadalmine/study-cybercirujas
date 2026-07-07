# Tema 2.3 — Using Directories and Listing Files
## Ejercicios guiados (LPI Linux Essentials 010-160, v1.6)

**Requisitos previos:** una terminal en cualquier distribución Linux (física, máquina virtual o WSL). Todos los ejercicios usan solo tu *home directory*, así que no necesitás permisos de `root`.

---

## Ejercicio 1 — ¿Dónde estoy? El *working directory* y el *home directory*

1. Abrí una terminal y ejecutá:
   ```bash
   pwd
   ```
   Anotá la salida. Debería ser algo como `/home/tu_usuario`.
2. Mostrá el contenido de la variable de entorno que guarda tu *home directory*:
   ```bash
   echo $HOME
   ```
3. Compará ambas salidas. Ahora movete al directorio raíz y verificá tu nueva ubicación:
   ```bash
   cd /
   pwd
   ```
4. Volvé a tu *home* de tres maneras distintas, verificando con `pwd` después de cada una:
   ```bash
   cd /home/tu_usuario
   pwd
   cd /
   cd ~
   pwd
   cd /
   cd
   pwd
   ```

**Preguntas de verificación:**

- **1.a)** ¿Qué significa la sigla del comando `pwd` y qué muestra exactamente?
- **1.b)** ¿Qué diferencia hay entre ejecutar `cd ~` y ejecutar `cd` sin argumentos?
- **1.c)** ¿Por qué la salida de `pwd` recién abierta la terminal coincide con `$HOME`?

---

## Ejercicio 2 — Rutas absolutas y relativas

1. Desde tu *home*, creá una pequeña estructura de práctica:
   ```bash
   cd
   mkdir -p practica/docs/informes
   mkdir -p practica/fotos
   ```
2. Entrá al directorio más profundo usando una **ruta relativa**:
   ```bash
   cd practica/docs/informes
   pwd
   ```
3. Ahora volvé al *home* y entrá al mismo lugar con una **ruta absoluta** (reemplazá `tu_usuario`):
   ```bash
   cd
   cd /home/tu_usuario/practica/docs/informes
   pwd
   ```
4. Estando en `informes`, subí un nivel y verificá:
   ```bash
   cd ..
   pwd
   ```
5. Desde `docs`, movete a `fotos` en un solo comando usando `..`:
   ```bash
   cd ../../fotos
   pwd
   ```
6. Probá qué hace el directorio especial `.` (punto simple):
   ```bash
   cd .
   pwd
   ```
7. Volvé al directorio anterior en el que estuviste:
   ```bash
   cd -
   pwd
   ```

**Preguntas de verificación:**

- **2.a)** ¿Cómo distinguís a simple vista una ruta absoluta de una relativa?
- **2.b)** En el paso 5, ¿por qué hicieron falta dos `..` para llegar de `docs` a `fotos`? Describí el recorrido.
- **2.c)** ¿Qué representan `.` y `..` dentro de cualquier directorio?
- **2.d)** ¿Qué hace `cd -` y en qué se diferencia de `cd ..`?

---

## Ejercicio 3 — Listando archivos con `ls` y sus opciones

1. Creá algunos archivos de prueba dentro de `practica`:
   ```bash
   cd ~/practica
   touch notas.txt datos.csv script.sh
   touch docs/informes/enero.txt docs/informes/febrero.txt
   ```
2. Listá el contenido del directorio actual:
   ```bash
   ls
   ```
3. Ahora pedí el **formato largo**:
   ```bash
   ls -l
   ```
   Observá la primera columna de cada línea: fijate qué líneas empiezan con `d` y cuáles con `-`.
4. Listá un directorio **sin entrar en él**, usando una ruta como argumento:
   ```bash
   ls docs/informes
   ls -l /etc
   ```
5. Probá el formato largo con tamaños **legibles para humanos**:
   ```bash
   ls -lh /var/log
   ```
   Compará la columna de tamaño con la salida de `ls -l /var/log`.
6. Listá **recursivamente** toda tu estructura de práctica:
   ```bash
   ls -R ~/practica
   ```

**Preguntas de verificación:**

- **3.a)** En la salida de `ls -l`, ¿qué indica el primer carácter de cada línea? Dá el significado de `-` y de `d`.
- **3.b)** ¿Qué hace la opción `-h` y por qué siempre se combina con `-l`?
- **3.c)** ¿Qué opción de `ls` usarías para ver el contenido de un directorio y de todos sus subdirectorios en un solo comando?
- **3.d)** ¿Es necesario estar "parado" dentro de un directorio para listarlo? Justificá con un ejemplo del ejercicio.

---

## Ejercicio 4 — Archivos ocultos (*hidden files*)

1. Creá un archivo oculto y un directorio oculto dentro de `practica`:
   ```bash
   cd ~/practica
   touch .config_secreta
   mkdir .cache_local
   ```
2. Listá el directorio de forma normal:
   ```bash
   ls
   ```
   Verificá que **no** aparecen los elementos recién creados.
3. Ahora listá incluyendo los ocultos:
   ```bash
   ls -a
   ```
   Además de tus archivos ocultos, fijate qué dos entradas aparecen siempre al principio.
4. Probá la variante que excluye esas dos entradas especiales:
   ```bash
   ls -A
   ```
5. Combiná opciones para ver los ocultos en formato largo:
   ```bash
   ls -la ~
   ```
   Observá cuántos archivos y directorios ocultos tiene tu *home* real: ahí guardan su configuración muchas aplicaciones.

**Preguntas de verificación:**

- **4.a)** ¿Qué convención hace que un archivo o directorio sea "oculto" en Linux? ¿Hace falta algún atributo o permiso especial?
- **4.b)** ¿Qué diferencia hay entre `ls -a` y `ls -A`?
- **4.c)** ¿Qué son las entradas `.` y `..` que muestra `ls -a`?
- **4.d)** ¿Para qué se usan típicamente los archivos ocultos en el *home directory* de un usuario?

---

## Ejercicio 5 — Integrador: navegación y exploración

1. Sin usar `cd`, listá en formato largo, con tamaños legibles y archivos ocultos incluidos, el contenido de `~/practica`:
   ```bash
   ls -lhA ~/practica
   ```
2. Desde cualquier ubicación, entrá directo a `informes` usando `~`:
   ```bash
   cd ~/practica/docs/informes
   ```
3. Desde ahí, listá el contenido de `fotos` con una **ruta relativa** (un solo comando, sin moverte).
4. Verificá que seguís en `informes` con `pwd`.
5. Cuando termines, podés borrar la estructura de práctica:
   ```bash
   cd
   rm -r ~/practica
   ```

**Preguntas de verificación:**

- **5.a)** Escribí el comando exacto que resuelve el paso 3.
- **5.b)** El comando `ls -lhA ~/practica`, ¿funciona igual desde cualquier directorio? ¿Por qué?
- **5.c)** Pregunta estilo examen: estás en `/home/carla/docs` y ejecutás `cd ../../..`. ¿En qué directorio quedás?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** `pwd` significa *print working directory*. Muestra la ruta absoluta del directorio en el que se encuentra actualmente el shell (el *current working directory*).
- **1.b)** Ninguna en la práctica: ambos te llevan a tu *home directory*. `~` es una abreviatura que el shell expande al valor de `$HOME`, y `cd` sin argumentos también usa `$HOME` como destino por defecto.
- **1.c)** Porque al iniciar sesión (o abrir una terminal), el shell arranca con el *home directory* del usuario como *working directory* inicial, y ese valor está definido en la variable `HOME`.

### Ejercicio 2

- **2.a)** La ruta absoluta empieza siempre con `/` (parte del directorio raíz), por ejemplo `/home/tu_usuario/practica`. La relativa no empieza con `/` y se interpreta a partir del directorio actual, por ejemplo `practica/docs`.
- **2.b)** Estando en `~/practica/docs`, el primer `..` sube a `~/practica` y el segundo `..` sube a `~` (el *home*)... pero como la ruta era `../../fotos`, en realidad el recorrido correcto es: estabas en `docs` **después de haber subido a él en el paso 4**, entonces `..` → `practica`, `..` → `home`, y desde ahí no existiría `fotos`. La clave: en el paso 5 estabas parado en `~/practica/docs`, así que `..` → `~/practica`, y ahí la ruta pide otro `..` → `~`; para que funcione tal como está escrita, `fotos` debe alcanzarse desde el nivel correcto. Si lo ejecutaste desde `~/practica/docs`, el comando correcto sería `cd ../fotos` (un solo nivel arriba, porque `fotos` es hermano de `docs`). Con `../../fotos` funcionaría solo si estuvieras en `~/practica/docs/informes`. **Moraleja de examen:** cada `..` sube exactamente un nivel; contá los niveles entre tu posición actual y el destino antes de escribir la ruta.
- **2.c)** `.` es una referencia al directorio actual; `..` es una referencia al directorio padre (el que está un nivel arriba). Ambas existen dentro de todos los directorios del sistema.
- **2.d)** `cd -` vuelve al directorio en el que estabas **antes** del último `cd` (usa la variable `$OLDPWD`), sin importar dónde esté en el árbol. `cd ..` en cambio sube al directorio padre del actual. Son cosas distintas: uno es "volver atrás en el historial", el otro es "subir un nivel".

### Ejercicio 3

- **3.a)** El primer carácter indica el tipo de entrada: `-` es un archivo regular (*regular file*) y `d` es un directorio. (Otros posibles: `l` para *symbolic link*, entre otros.)
- **3.b)** `-h` (*human-readable*) muestra los tamaños con unidades como K, M o G en lugar de bytes crudos. Se combina con `-l` porque la columna de tamaño solo aparece en el formato largo; `ls -h` solo, sin `-l`, no muestra ningún tamaño.
- **3.c)** `ls -R` (mayúscula), que lista recursivamente el directorio y todos sus subdirectorios.
- **3.d)** No. `ls` acepta rutas como argumento: en el ejercicio listamos `docs/informes` (ruta relativa) y `/etc` (ruta absoluta) sin cambiar el *working directory*.

### Ejercicio 4

- **4.a)** Solo la convención del nombre: todo archivo o directorio cuyo nombre empieza con un punto (`.`) se considera oculto. No requiere permisos ni atributos especiales; es simplemente que `ls` y los *file managers* no los muestran por defecto.
- **4.b)** `ls -a` muestra **todas** las entradas, incluidas las especiales `.` y `..`. `ls -A` (*almost all*) muestra los archivos ocultos pero **omite** `.` y `..`.
- **4.c)** Son las referencias al propio directorio (`.`) y a su directorio padre (`..`). Aparecen en todo directorio del sistema y por eso `ls -a` siempre las lista primero.
- **4.d)** Para guardar configuración personal de programas y del shell: por ejemplo `~/.bashrc`, `~/.config/`, `~/.ssh/`. Se ocultan para no "ensuciar" el listado habitual del *home*, no por seguridad.

### Ejercicio 5

- **5.a)** `ls ../../fotos` — desde `~/practica/docs/informes`, el primer `..` sube a `docs`, el segundo a `practica`, y desde ahí se lista `fotos`.
- **5.b)** Sí, funciona igual desde cualquier lugar, porque `~` se expande a la ruta absoluta del *home* (`/home/tu_usuario`), de modo que el argumento resultante es una ruta absoluta que no depende del *working directory*.
- **5.c)** En `/` (el directorio raíz). Desde `/home/carla/docs`: primer `..` → `/home/carla`, segundo `..` → `/home`, tercer `..` → `/`. Nota de examen: el raíz es su propio padre, así que cualquier `..` adicional te deja igualmente en `/`.

</details>

---

**Fuente de referencia:** LPI Learning Materials, Linux Essentials — Lesson 2.3 *Using Directories and Listing Files*: https://learning.lpi.org/en/learning-materials/010-160/2/2.3/