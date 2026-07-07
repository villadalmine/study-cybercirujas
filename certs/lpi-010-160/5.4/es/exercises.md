# Ejercicios guiados — Tema 5.4: Special Directories and Files

**Certificación:** LPI Linux Essentials (010-160, v1.6) · **Peso:** 1
**Referencia:** [learning.lpi.org — 5.4 Special Directories and Files](https://learning.lpi.org/en/learning-materials/010-160/5/5.4/)

> Realizá estos ejercicios como usuario normal (no root) en una terminal. Solo necesitás una instalación de Linux estándar. Ningún paso daña el sistema.

---

## Ejercicio 1 — Directorios temporales: `/tmp`, `/var/tmp` y `/run`

1. Listá los permisos de los directorios temporales del sistema:
   ```bash
   ls -ld /tmp /var/tmp /run
   ```
2. Observá la salida de `/tmp`. Debería verse similar a:
   ```
   drwxrwxrwt 15 root root 4096 jul  7 10:32 /tmp
   ```
   Fijate en el último carácter del bloque de permisos: la letra `t`.
3. Creá un archivo temporal propio:
   ```bash
   touch /tmp/prueba-$USER.txt
   ls -l /tmp/prueba-$USER.txt
   ```
4. Verificá quién es el dueño del archivo que acabás de crear con `ls -l`.

**Preguntas:**

- **1.a** ¿Qué significa la `t` al final de los permisos de `/tmp` y cómo se llama ese permiso especial?
- **1.b** Si otro usuario del sistema también puede escribir en `/tmp` (permisos `rwx` para *others*), ¿puede borrar el archivo que vos creaste en el paso 3? ¿Por qué?
- **1.c** ¿Cuál es la diferencia práctica entre `/tmp` y `/var/tmp` respecto a la persistencia de los datos tras un reinicio?

---

## Ejercicio 2 — El *sticky bit* en la práctica

1. Creá un directorio de trabajo compartido de prueba en tu *home*:
   ```bash
   mkdir ~/compartido
   chmod 1777 ~/compartido
   ls -ld ~/compartido
   ```
2. Compará con un directorio sin el bit especial:
   ```bash
   mkdir ~/normal
   chmod 777 ~/normal
   ls -ld ~/normal
   ```
3. Observá la diferencia en el último carácter: `t` en uno, `x` en el otro.
4. Quitá el *sticky bit* usando notación simbólica y volvé a mirar:
   ```bash
   chmod -t ~/compartido
   ls -ld ~/compartido
   ```
5. Limpiá:
   ```bash
   rmdir ~/compartido ~/normal
   ```

**Preguntas:**

- **2.a** En `chmod 1777`, ¿qué representa el `1` inicial?
- **2.b** Con el *sticky bit* activo en un directorio con permisos `777`, ¿quiénes pueden borrar o renombrar un archivo dentro de ese directorio?
- **2.c** Si en la salida de `ls -ld` vieras una `T` mayúscula en lugar de `t` minúscula, ¿qué indicaría?

---

## Ejercicio 3 — Symbolic links (enlaces simbólicos)

1. Creá un archivo de datos y un *symbolic link* que apunte a él:
   ```bash
   cd ~
   echo "contenido original" > datos.txt
   ln -s datos.txt enlace-simbolico.txt
   ls -l datos.txt enlace-simbolico.txt
   ```
2. Observá en la salida: el enlace empieza con `l` en los permisos y muestra `enlace-simbolico.txt -> datos.txt`.
3. Leé el archivo a través del enlace y modificalo:
   ```bash
   cat enlace-simbolico.txt
   echo "línea agregada por el enlace" >> enlace-simbolico.txt
   cat datos.txt
   ```
4. Ahora borrá el archivo original y tratá de leer el enlace:
   ```bash
   rm datos.txt
   cat enlace-simbolico.txt
   ls -l enlace-simbolico.txt
   ```
5. Buscá un ejemplo real de *symbolic link* en el sistema:
   ```bash
   ls -l /usr/bin | grep '^l' | head -5
   ```
6. Limpiá:
   ```bash
   rm enlace-simbolico.txt
   ```

**Preguntas:**

- **3.a** En el paso 3, escribiste a través del enlace. ¿Dónde quedó guardada realmente la línea nueva?
- **3.b** ¿Qué pasó en el paso 4 al ejecutar `cat` sobre el enlace? ¿Cómo se llama un enlace en ese estado?
- **3.c** ¿Puede un *symbolic link* apuntar a un directorio? ¿Y a un archivo en otro *filesystem* (por ejemplo, otra partición)?

---

## Ejercicio 4 — Hard links (enlaces duros)

1. Creá un archivo y un *hard link* hacia él (mismo comando `ln`, pero **sin** `-s`):
   ```bash
   cd ~
   echo "datos importantes" > original.txt
   ln original.txt duro.txt
   ls -li original.txt duro.txt
   ```
2. Fijate en dos cosas de la salida de `ls -li`:
   - El primer número de cada línea (el *inode number*): es **el mismo** en ambos archivos.
   - El número que aparece después de los permisos (contador de enlaces): ahora vale `2`.
3. Modificá el contenido a través de cualquiera de los dos nombres:
   ```bash
   echo "segunda línea" >> duro.txt
   cat original.txt
   ```
4. Borrá el archivo "original" y comprobá que los datos siguen accesibles:
   ```bash
   rm original.txt
   cat duro.txt
   ls -li duro.txt
   ```
5. Intentá crear un *hard link* a un directorio y observá el error:
   ```bash
   ln ~/ enlace-a-home
   ```
6. Limpiá:
   ```bash
   rm duro.txt
   ```

**Preguntas:**

- **4.a** ¿Por qué después de `rm original.txt` el contenido sigue existiendo, a diferencia de lo que pasó con el *symbolic link* en el Ejercicio 3?
- **4.b** ¿Qué es un *inode* y qué relación tiene con los *hard links*?
- **4.c** Mencioná dos limitaciones de los *hard links* que los *symbolic links* no tienen.
- **4.d** En el paso 4, ¿qué valor mostró el contador de enlaces después de borrar `original.txt`?

---

## Ejercicio 5 — Reconocer archivos y directorios especiales en el sistema

1. Recorré la raíz del sistema y clasificá lo que ves:
   ```bash
   ls -l /
   ```
2. Buscá enlaces simbólicos directamente en `/` (en muchas distros modernas, `/bin`, `/sbin` y `/lib` son enlaces a sus equivalentes bajo `/usr`):
   ```bash
   ls -l / | grep '^l'
   ```
3. Encontrá todos los directorios con *sticky bit* bajo `/var` (puede requerir `sudo` para ver todo; sin él, ignorá los errores de permisos):
   ```bash
   find /var -maxdepth 2 -type d -perm -1000 2>/dev/null
   ```
4. Verificá cuántos *hard links* tiene un directorio cualquiera:
   ```bash
   ls -ld /etc
   ```
   El número después de los permisos es el contador de enlaces del directorio.

**Preguntas:**

- **5.a** ¿Por qué distribuciones modernas hacen que `/bin` sea un *symbolic link* a `/usr/bin`?
- **5.b** ¿Qué opción de `find` usamos para localizar directorios con *sticky bit* y qué significa el valor `1000`?
- **5.c** Un directorio recién creado y vacío muestra un contador de enlaces de `2` (no `1`). ¿A qué se debe?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a** La `t` indica el **sticky bit** (también llamado *restricted deletion flag*). En un directorio, restringe quién puede borrar o renombrar los archivos que contiene.
- **1.b** No. Aunque `/tmp` tiene permisos de escritura para todos, el *sticky bit* hace que solo el **dueño del archivo**, el **dueño del directorio** o **root** puedan borrarlo o renombrarlo. Sin el *sticky bit*, cualquiera con permiso de escritura sobre el directorio podría borrar archivos ajenos.
- **1.c** `/tmp` se limpia con frecuencia y su contenido normalmente **no sobrevive a un reinicio** (en muchas distros es un *tmpfs* en memoria). `/var/tmp` está pensado para archivos temporales que deben **persistir entre reinicios** y se conserva por más tiempo. `/run` guarda datos volátiles de tiempo de ejecución (PIDs, *sockets*) y se recrea vacío en cada arranque.

### Ejercicio 2

- **2.a** El `1` es el dígito octal de los **permisos especiales**: `1` = *sticky bit*, `2` = *setgid*, `4` = *setuid*. `1777` significa *sticky bit* + `rwxrwxrwx`.
- **2.b** Solo el dueño del archivo, el dueño del directorio y root. Todos pueden **crear** archivos (por el permiso de escritura), pero no borrar los de otros.
- **2.c** Una `T` mayúscula indica que el *sticky bit* está activo pero **falta el permiso de ejecución** (`x`) para *others* en esa posición. La minúscula `t` significa *sticky bit* + `x` juntos.

### Ejercicio 3

- **3.a** En `datos.txt`, el archivo original. El *symbolic link* no contiene datos propios: es solo un puntero (una ruta) hacia otro nombre de archivo; toda operación de lectura/escritura se redirige al destino.
- **3.b** `cat` falló con un error tipo *"No such file or directory"*, porque el destino ya no existe. El enlace quedó como **dangling link** (enlace roto o huérfano): sigue existiendo como entrada de directorio, pero apunta a nada. `ls -l` lo sigue mostrando (muchas terminales lo colorean en rojo).
- **3.c** Sí a ambas: un *symbolic link* puede apuntar a directorios y puede cruzar límites de *filesystem* (particiones, discos, montajes de red). Estas son dos ventajas clave sobre los *hard links*.

### Ejercicio 4

- **4.a** Porque un *hard link* no "apunta" al otro nombre: **ambos nombres son entradas equivalentes al mismo inode**, con igual jerarquía. `rm original.txt` solo elimina un nombre y decrementa el contador de enlaces; los datos se liberan recién cuando el contador llega a `0` (y ningún proceso tiene el archivo abierto).
- **4.b** Un *inode* es la estructura del *filesystem* que guarda los metadatos de un archivo (permisos, dueño, tamaño, ubicación de los bloques de datos) — todo excepto el nombre. Los nombres viven en los directorios y son *hard links* hacia el inode. Todo archivo tiene al menos un *hard link*; `ln` simplemente crea nombres adicionales para el mismo inode.
- **4.c** (1) No pueden cruzar *filesystems*, porque los números de inode solo tienen sentido dentro de un mismo *filesystem*. (2) No pueden apuntar a directorios (por eso el paso 5 dio error `hard link not allowed for directory`), para evitar bucles en el árbol de directorios.
- **4.d** `1`: quedaba un solo nombre (`duro.txt`) apuntando al inode.

### Ejercicio 5

- **5.a** Es parte de la unificación conocida como **/usr merge**: históricamente `/bin` y `/usr/bin` estaban separados, pero hoy esa división ya no aporta valor, así que los binarios viven en `/usr/bin` y `/bin` se mantiene como *symbolic link* por compatibilidad con rutas antiguas (por ejemplo `/bin/sh`).
- **5.b** La opción `-perm -1000`. El `1000` octal es el bit del *sticky bit* (el mismo `1` inicial de `chmod 1777`); el guion delante significa "que tenga al menos ese bit activo", sin importar el resto de los permisos. Deberías haber encontrado al menos `/var/tmp`.
- **5.c** Porque tiene dos nombres que apuntan a su inode: la entrada en su directorio padre y su propia entrada `.` (el "sí mismo"). Cada subdirectorio que se crea adentro suma uno más, por su entrada `..` que apunta de vuelta al padre.

</details>