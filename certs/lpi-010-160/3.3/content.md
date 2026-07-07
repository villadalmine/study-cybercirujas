# Tema 3.3: Turning Commands into a Script

**Certificación:** LPI Linux Essentials (010-160, versión 1.6)
**Peso en el examen:** 4

---

## Introducción

Cuando trabajás en la línea de comandos, muchas veces repetís las mismas secuencias de comandos una y otra vez. Un **shell script** es simplemente un archivo de texto que contiene una serie de comandos que el shell ejecuta en orden, de arriba hacia abajo. Convertir comandos en un script te permite automatizar tareas, reducir errores y compartir soluciones con otros.

Este tema cubre los elementos esenciales para escribir scripts básicos en **Bash**: editores de texto, la línea *shebang*, comentarios, variables, argumentos, condicionales, bucles y el estado de salida (*exit status*).

---

## 1. Editores de texto

Para escribir un script necesitás un editor de **texto plano** (no un procesador de textos como LibreOffice Writer, que agrega formato). Los dos editores más comunes en la terminal son:

### nano

Editor simple e intuitivo, ideal para principiantes. Los atajos aparecen en la parte inferior de la pantalla (el símbolo `^` significa la tecla `Ctrl`):

```bash
$ nano miscript.sh
```

- `Ctrl+O` — guardar (*Write Out*)
- `Ctrl+X` — salir
- `Ctrl+K` — cortar una línea
- `Ctrl+U` — pegar

### vi / vim

Editor más potente, presente en prácticamente cualquier sistema Linux/Unix. Tiene **modos** de trabajo:

- **Modo normal** (al abrir): para navegar y ejecutar comandos del editor.
- **Modo inserción**: se entra con `i` (insertar) o `a` (agregar), y se escribe texto. Se vuelve al modo normal con `Esc`.
- **Comandos útiles** en modo normal: `:w` (guardar), `:q` (salir), `:wq` (guardar y salir), `:q!` (salir sin guardar).

Para el examen alcanza con saber que existen ambos, sus diferencias básicas y cómo guardar y salir de cada uno.

---

## 2. Anatomía de un script

### 2.1 La línea shebang (`#!`)

La primera línea de un script indica **qué intérprete** debe ejecutarlo. Se llama *shebang* (o *hashbang*):

```bash
#!/bin/bash
```

Cuando ejecutás el script, el kernel lee esta línea y lanza `/bin/bash` para interpretar el resto del archivo. Otros ejemplos:

```bash
#!/bin/sh          # shell POSIX genérico
#!/usr/bin/python3 # un script de Python
#!/usr/bin/env bash # busca bash en el PATH (más portable)
```

Si el shebang no está presente, el script se ejecuta con el shell actual, lo que puede causar comportamientos inesperados. **Siempre incluilo.**

### 2.2 Comentarios

Todo lo que sigue a un `#` (salvo en el shebang) es un **comentario**: el shell lo ignora. Los comentarios documentan qué hace el script y por qué:

```bash
#!/bin/bash
# Este script saluda al usuario
echo "Hola"  # también se puede comentar al final de una línea
```

### 2.3 Un primer script completo

Creá el archivo `hola.sh`:

```bash
#!/bin/bash
# hola.sh - mi primer script
echo "¡Hola, mundo!"
echo "Hoy es: $(date)"
```

Nota: `$(comando)` es **sustitución de comandos** (*command substitution*): ejecuta el comando y reemplaza la expresión por su salida.

---

## 3. Hacer el script ejecutable y ejecutarlo

Un archivo recién creado no tiene permiso de ejecución. Hay dos formas de correr el script:

### Opción A: pasarlo como argumento al intérprete

```bash
$ bash hola.sh
¡Hola, mundo!
Hoy es: mar 07 jul 2026 10:15:32 -03
```

### Opción B: darle permiso de ejecución con `chmod`

```bash
$ chmod +x hola.sh
$ ls -l hola.sh
-rwxr-xr-x 1 carla carla 89 jul  7 10:14 hola.sh
$ ./hola.sh
¡Hola, mundo!
Hoy es: mar 07 jul 2026 10:15:40 -03
```

**¿Por qué `./hola.sh` y no solo `hola.sh`?** Por seguridad, el directorio actual (`.`) normalmente **no está en la variable `PATH`**, que es la lista de directorios donde el shell busca los ejecutables. Con `./` le indicás la ruta explícita. Si querés ejecutar el script desde cualquier lugar solo con su nombre, podés copiarlo a un directorio del `PATH` (por ejemplo `/usr/local/bin` o `~/bin`):

```bash
$ echo $PATH
/usr/local/bin:/usr/bin:/bin:/home/carla/bin
```

---

## 4. Variables

Las variables almacenan valores para reutilizarlos. Reglas clave:

- Se asignan con `NOMBRE=valor` — **sin espacios** alrededor del `=`.
- Se leen anteponiendo `$`: `$NOMBRE` o `${NOMBRE}`.
- Los nombres pueden contener letras, números y `_`, pero no pueden empezar con un número.

```bash
#!/bin/bash
NOMBRE="Carla"
DISTRO=$(lsb_release -sd)   # sustitución de comandos
echo "Usuario: $NOMBRE"
echo "Distribución: $DISTRO"
```

```
$ ./variables.sh
Usuario: Carla
Distribución: Ubuntu 24.04 LTS
```

### Comillas: dobles vs. simples

- **Comillas dobles** (`"..."`): el shell expande las variables dentro.
- **Comillas simples** (`'...'`): todo se toma literal, sin expansión.

```bash
$ SALUDO=Hola
$ echo "$SALUDO mundo"
Hola mundo
$ echo '$SALUDO mundo'
$SALUDO mundo
```

### Leer entrada del usuario: `read`

```bash
#!/bin/bash
echo "¿Cómo te llamás?"
read NOMBRE
echo "Bienvenido, $NOMBRE"
```

```
$ ./saludo.sh
¿Cómo te llamás?
Carla
Bienvenido, Carla
```

---

## 5. Argumentos del script

Un script puede recibir **argumentos posicionales** desde la línea de comandos. Dentro del script se acceden con variables especiales:

| Variable | Significado |
|----------|-------------|
| `$0` | Nombre del script |
| `$1`, `$2`, … `$9` | Primer, segundo… noveno argumento |
| `$#` | Cantidad de argumentos recibidos |
| `$@` | Todos los argumentos |
| `$?` | Exit status del último comando ejecutado |

Ejemplo (`args.sh`):

```bash
#!/bin/bash
echo "Script: $0"
echo "Primer argumento: $1"
echo "Segundo argumento: $2"
echo "Total de argumentos: $#"
echo "Todos: $@"
```

```
$ ./args.sh manzana pera
Script: ./args.sh
Primer argumento: manzana
Segundo argumento: pera
Total de argumentos: 2
Todos: manzana pera
```

---

## 6. Exit status (estado de salida)

Todo comando en Linux termina con un **código de salida** entre 0 y 255:

- `0` = éxito.
- Cualquier otro valor = error (el significado exacto depende del programa).

El código del último comando queda en la variable `$?`:

```bash
$ ls /etc/hostname
/etc/hostname
$ echo $?
0
$ ls /noexiste
ls: cannot access '/noexiste': No such file or directory
$ echo $?
2
```

Dentro de un script, el comando `exit N` termina la ejecución devolviendo el código `N`. Si no se indica, el script devuelve el exit status del último comando ejecutado:

```bash
#!/bin/bash
if [ $# -eq 0 ]; then
    echo "Error: falta un argumento" >&2
    exit 1
fi
echo "Procesando $1"
exit 0
```

Esto es fundamental para la automatización: otros programas (y operadores como `&&` y `||`) deciden qué hacer según ese código:

```bash
$ ./backup.sh && echo "OK" || echo "Falló"
```

---

## 7. Condicionales: `if` y `test`

La estructura `if` ejecuta comandos según el exit status de una condición:

```bash
if condición; then
    comandos
elif otra_condición; then
    comandos
else
    comandos
fi
```

La condición suele evaluarse con el comando `test` o su forma equivalente entre corchetes `[ ]` (¡los espacios dentro de los corchetes son obligatorios!).

### Operadores comunes de `test`

| Expresión | Verdadera si… |
|-----------|---------------|
| `-f archivo` | el archivo existe y es regular |
| `-d ruta` | la ruta existe y es un directorio |
| `-z "$VAR"` | la cadena está vacía |
| `"$A" = "$B"` | las cadenas son iguales |
| `"$A" != "$B"` | las cadenas son distintas |
| `$X -eq $Y` | los números son iguales |
| `$X -ne $Y` | los números son distintos |
| `$X -gt $Y` / `$X -lt $Y` | mayor que / menor que |
| `$X -ge $Y` / `$X -le $Y` | mayor o igual / menor o igual |

Ejemplo (`checkfile.sh`):

```bash
#!/bin/bash
if [ -f "$1" ]; then
    echo "El archivo $1 existe"
else
    echo "El archivo $1 NO existe"
    exit 1
fi
```

```
$ ./checkfile.sh /etc/passwd
El archivo /etc/passwd existe
$ ./checkfile.sh /tmp/nada.txt
El archivo /tmp/nada.txt NO existe
$ echo $?
1
```

Ejemplo con números:

```bash
#!/bin/bash
if [ $# -lt 2 ]; then
    echo "Uso: $0 archivo1 archivo2"
    exit 1
fi
```

---

## 8. Bucles: `for` y `while`

### Bucle `for`

Itera sobre una lista de elementos:

```bash
#!/bin/bash
for FRUTA in manzana pera uva; do
    echo "Fruta: $FRUTA"
done
```

```
$ ./frutas.sh
Fruta: manzana
Fruta: pera
Fruta: uva
```

Es muy común iterar sobre archivos usando *globbing* (comodines):

```bash
#!/bin/bash
for ARCHIVO in *.txt; do
    echo "Procesando $ARCHIVO"
    wc -l "$ARCHIVO"
done
```

O sobre una secuencia numérica con `seq`:

```bash
#!/bin/bash
for N in $(seq 1 3); do
    echo "Iteración $N"
done
```

```
Iteración 1
Iteración 2
Iteración 3
```

### Bucle `while`

Repite mientras la condición sea verdadera (exit status 0):

```bash
#!/bin/bash
CONTADOR=1
while [ $CONTADOR -le 3 ]; do
    echo "Contador: $CONTADOR"
    CONTADOR=$((CONTADOR + 1))
done
```

Nota: `$(( ... ))` es **expansión aritmética**: permite hacer cuentas con enteros en Bash.

---

## 9. Ejemplo integrador

Un script que combina todos los conceptos del tema (`respaldo.sh`):

```bash
#!/bin/bash
# respaldo.sh - crea una copia .bak de cada archivo indicado
# Uso: ./respaldo.sh archivo1 [archivo2 ...]

if [ $# -eq 0 ]; then
    echo "Uso: $0 archivo [archivo ...]" >&2
    exit 1
fi

COPIADOS=0

for ARCHIVO in "$@"; do
    if [ -f "$ARCHIVO" ]; then
        cp "$ARCHIVO" "$ARCHIVO.bak"
        echo "Copiado: $ARCHIVO -> $ARCHIVO.bak"
        COPIADOS=$((COPIADOS + 1))
    else
        echo "Aviso: $ARCHIVO no existe, se omite" >&2
    fi
done

echo "Total de archivos respaldados: $COPIADOS"
exit 0
```

```
$ chmod +x respaldo.sh
$ ./respaldo.sh notas.txt inexistente.txt
Copiado: notas.txt -> notas.txt.bak
Aviso: inexistente.txt no existe, se omite
Total de archivos respaldados: 1
$ echo $?
0
```

---

## 10. Puntos clave para el examen

- Un shell script es un archivo de texto con comandos que el shell ejecuta secuencialmente.
- La primera línea `#!/bin/bash` (*shebang*) define el intérprete.
- `#` inicia un comentario; el shell ignora el resto de la línea.
- `chmod +x script.sh` da permiso de ejecución; se ejecuta con `./script.sh` porque `.` no está en el `PATH`.
- Variables: asignación sin espacios (`VAR=valor`), lectura con `$VAR`; comillas dobles expanden, simples no.
- Argumentos posicionales: `$1`, `$2`…; `$#` cuenta argumentos; `$@` los lista todos; `$0` es el nombre del script.
- `$?` contiene el exit status del último comando: `0` es éxito, distinto de cero es error; `exit N` fija el código de salida del script.
- `if` / `test` (o `[ ]`) para condicionales; `for` y `while` para bucles.
- `$(comando)` sustituye por la salida del comando; `$((expresión))` hace aritmética entera.
- Editores: `nano` (simple, atajos con Ctrl) y `vi`/`vim` (modal: `i` para insertar, `Esc`, `:wq` para guardar y salir).

---

## Referencias

- LPI Learning Materials — Topic 3.3, Turning Commands into a Script: https://learning.lpi.org/en/learning-materials/010-160/3/3.3/
- LPI Linux Essentials — Objetivos del examen 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Coreutils Manual (`test`, `chmod`, `seq`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Documentación de GNU nano: https://www.nano-editor.org/docs.php
- Documentación de Vim: https://www.vim.org/docs.php