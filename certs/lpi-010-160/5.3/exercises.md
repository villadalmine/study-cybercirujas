# Ejercicios guiados — Tema 5.3: Managing File Permissions and Ownership

**Certificación:** LPI Linux Essentials (examen 010-160, versión 1.6) · **Peso:** 2
**Fuente de referencia:** [learning.lpi.org — Lesson 5.3](https://learning.lpi.org/en/learning-materials/010-160/5/5.3/)

> **Preparación:** trabajá en una terminal con un usuario normal (no root). Todos los ejercicios se hacen dentro de un directorio de práctica que vas a crear en el primer bloque.

---

## Bloque 1 — Leer permisos con `ls -l`

1. Creá un directorio de práctica y entrá en él:
   ```bash
   mkdir ~/permisos-lab
   cd ~/permisos-lab
   ```
2. Creá un archivo vacío y un subdirectorio:
   ```bash
   touch notas.txt
   mkdir datos
   ```
3. Listá el contenido en formato largo:
   ```bash
   ls -l
   ```
4. Observá la primera columna de cada línea. Para `notas.txt` deberías ver algo como `-rw-r--r--` y para `datos` algo como `drwxr-xr-x`.
5. Verificá quién sos y a qué grupos pertenecés:
   ```bash
   id
   ```

**Preguntas de verificación:**

**1.1** En la cadena `-rw-r--r--`, ¿qué indica el primer carácter y qué significan los tres bloques de tres caracteres que siguen?

**1.2** ¿Por qué `datos` empieza con `d` y `notas.txt` con `-`?

**1.3** Según la salida de `ls -l`, ¿qué dos columnas indican el *owner* (dueño) y el *group* del archivo?

---

## Bloque 2 — Permisos en archivos: `chmod` en modo simbólico

1. Creá un script simple:
   ```bash
   echo 'echo "Hola desde mi script"' > saludo.sh
   ls -l saludo.sh
   ```
2. Intentá ejecutarlo directamente:
   ```bash
   ./saludo.sh
   ```
   Deberías recibir un error de tipo *Permission denied*.
3. Agregale permiso de ejecución al *user* (dueño) con modo simbólico:
   ```bash
   chmod u+x saludo.sh
   ls -l saludo.sh
   ```
4. Ejecutalo de nuevo:
   ```bash
   ./saludo.sh
   ```
5. Ahora quitale la lectura a *others* y verificá:
   ```bash
   chmod o-r saludo.sh
   ls -l saludo.sh
   ```
6. Probá una asignación exacta (el signo `=` reemplaza en lugar de sumar o restar):
   ```bash
   chmod g=r saludo.sh
   ls -l saludo.sh
   ```

**Preguntas de verificación:**

**2.1** En modo simbólico, ¿qué representan las letras `u`, `g`, `o` y `a`?

**2.2** ¿Cuál es la diferencia entre `chmod g+w archivo` y `chmod g=w archivo`?

**2.3** ¿Por qué el paso 2 falló aunque el archivo tenía permiso de lectura para el dueño?

---

## Bloque 3 — `chmod` en modo octal (numérico)

1. Revisá los permisos actuales de `saludo.sh`:
   ```bash
   ls -l saludo.sh
   ```
2. Asignale permisos exactos con notación octal: dueño todo, grupo lectura+ejecución, otros nada:
   ```bash
   chmod 750 saludo.sh
   ls -l saludo.sh
   ```
   Deberías ver `-rwxr-x---`.
3. Ahora dejá el archivo legible y escribible solo por el dueño, y legible por el resto:
   ```bash
   chmod 644 saludo.sh
   ls -l saludo.sh
   ```
4. Practicá la conversión inversa: mirá esta salida y calculá mentalmente el número octal antes de seguir:
   ```
   -rw-rw-r--
   ```
5. Comprobá tu cálculo aplicándolo y comparando:
   ```bash
   chmod 664 saludo.sh
   ls -l saludo.sh
   ```

**Preguntas de verificación:**

**3.1** ¿Qué valor numérico tiene cada permiso (`r`, `w`, `x`) y cómo se combinan para formar un dígito octal?

**3.2** ¿Qué permisos otorga `chmod 600 archivo`? Escribí la cadena simbólica equivalente.

**3.3** Un compañero ejecuta `chmod 777 datos_privados.txt`. ¿Qué hizo y por qué es una mala práctica?

---

## Bloque 4 — Permisos en directorios

1. Creá un directorio con un archivo adentro:
   ```bash
   mkdir carpeta
   echo "contenido secreto" > carpeta/secreto.txt
   ```
2. Quitale el permiso de ejecución (*execute*) al directorio para tu propio usuario:
   ```bash
   chmod u-x carpeta
   ```
3. Intentá listar y luego entrar:
   ```bash
   ls carpeta
   cd carpeta
   ```
   El `ls` puede mostrar nombres (quizás con errores), pero el `cd` va a fallar.
4. Restaurá el permiso y probá lo contrario — quitá la lectura pero dejá la ejecución:
   ```bash
   chmod u+x carpeta
   chmod u-r carpeta
   ls carpeta
   cat carpeta/secreto.txt
   ```
   Ahora `ls` falla, pero `cat` sobre el archivo (cuyo nombre conocés) funciona.
5. Dejá todo normal de nuevo:
   ```bash
   chmod u+r carpeta
   ```

**Preguntas de verificación:**

**4.1** En un directorio, ¿qué permite cada permiso: `r`, `w` y `x`?

**4.2** ¿Por qué en el paso 4 pudiste leer `secreto.txt` aunque no podías listar el directorio?

**4.3** Si querés que un usuario pueda crear y borrar archivos dentro de un directorio, ¿qué dos permisos necesita sobre ese directorio?

---

## Bloque 5 — Ownership: `chown` y `chgrp`

> **Nota:** cambiar el dueño de un archivo requiere privilegios de root; cambiar el grupo solo requiere ser el dueño y pertenecer al grupo destino. Por eso acá vas a usar `sudo` en algunos pasos.

1. Verificá el dueño y grupo actuales de `notas.txt`:
   ```bash
   ls -l notas.txt
   ```
2. Mirá a qué grupos pertenecés:
   ```bash
   id
   ```
3. Si tu usuario pertenece a más de un grupo (por ejemplo `users`), cambiá el grupo del archivo sin `sudo`:
   ```bash
   chgrp users notas.txt
   ls -l notas.txt
   ```
   (Si no tenés otro grupo disponible, hacelo con `sudo chgrp`.)
4. Cambiá el dueño del archivo a root (requiere privilegios):
   ```bash
   sudo chown root notas.txt
   ls -l notas.txt
   ```
5. Intentá modificar el archivo ahora que no es tuyo:
   ```bash
   echo "una línea más" >> notas.txt
   ```
   Fijate si funciona o no según los permisos de *group* y *others*.
6. Recuperá el archivo cambiando dueño y grupo en un solo comando con la sintaxis `usuario:grupo` (reemplazá `tuusuario` por tu nombre de usuario real):
   ```bash
   sudo chown tuusuario:tuusuario notas.txt
   ls -l notas.txt
   ```

**Preguntas de verificación:**

**5.1** ¿Qué diferencia hay entre `chown`, `chgrp` y `chown usuario:grupo`?

**5.2** ¿Por qué un usuario normal no puede "regalar" sus archivos a otro usuario con `chown`?

**5.3** Después del paso 4, ¿bajo qué categoría de permisos (user, group u others) se evalúa tu acceso a `notas.txt`?

---

## Bloque 6 — Permisos especiales: setuid, setgid y sticky bit

1. Mirá un binario clásico con *setuid*:
   ```bash
   ls -l /usr/bin/passwd
   ```
   Observá la `s` en la posición de ejecución del dueño: `-rwsr-xr-x`.
2. Mirá un directorio clásico con *sticky bit*:
   ```bash
   ls -ld /tmp
   ```
   Observá la `t` al final: `drwxrwxrwt`.
3. Creá un directorio compartido de prueba y aplicale *setgid* y *sticky bit*:
   ```bash
   mkdir compartido
   chmod g+s compartido
   chmod +t compartido
   ls -ld compartido
   ```
4. Creá un archivo adentro y observá su grupo:
   ```bash
   touch compartido/prueba.txt
   ls -l compartido/
   ```
   Con *setgid* activo, los archivos nuevos heredan el grupo del directorio, no el grupo primario de quien los crea.
5. Limpieza final del laboratorio (opcional):
   ```bash
   cd ~
   rm -r ~/permisos-lab
   ```

**Preguntas de verificación:**

**6.1** ¿Qué efecto tiene el bit *setuid* en `/usr/bin/passwd` y por qué es necesario ahí?

**6.2** ¿Qué logra el *sticky bit* en un directorio como `/tmp`?

**6.3** En notación octal de cuatro dígitos, ¿qué valor representa cada permiso especial (setuid, setgid, sticky) y qué comando dejaría un directorio con permisos `rwxrwsr-x`?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**1.1** El primer carácter indica el tipo de archivo (`-` archivo regular, `d` directorio, `l` symbolic link, entre otros). Los tres bloques siguientes son los permisos de tres categorías, en este orden: *user* (dueño) → `rw-`, *group* → `r--`, *others* → `r--`. Cada bloque muestra lectura (`r`), escritura (`w`) y ejecución (`x`); un guion significa que ese permiso está ausente.

**1.2** Porque el primer carácter identifica el tipo: `datos` es un directorio (`d`) y `notas.txt` es un archivo regular (`-`). No es un permiso, es metadata del tipo de archivo.

**1.3** La tercera columna es el *owner* y la cuarta es el *group*. Por ejemplo: `-rw-r--r-- 1 carla users 0 jul 7 10:00 notas.txt` → dueño `carla`, grupo `users`.

### Bloque 2

**2.1** `u` = *user* (el dueño), `g` = *group*, `o` = *others* (el resto de los usuarios), `a` = *all* (las tres categorías a la vez, equivalente a `ugo`).

**2.2** `g+w` **agrega** escritura al grupo sin tocar los demás permisos del grupo. `g=w` **fija** los permisos del grupo exactamente en escritura: si el grupo tenía `r`, lo pierde. El `+` y el `-` modifican; el `=` reemplaza.

**2.3** Porque para ejecutar un archivo como programa hace falta el permiso de ejecución (`x`), que es independiente de la lectura. El archivo recién creado tenía `rw-` para el dueño: se podía leer y editar, pero no ejecutar.

### Bloque 3

**3.1** `r` = 4, `w` = 2, `x` = 1. Se suman por categoría: por ejemplo `rwx` = 4+2+1 = 7, `r-x` = 4+1 = 5, `r--` = 4, `rw-` = 6. El número final tiene tres dígitos: user, group, others (ej.: `750` = `rwxr-x---`).

**3.2** `chmod 600` deja `rw-------`: el dueño puede leer y escribir; grupo y otros no tienen ningún acceso. Equivalente simbólico: `chmod u=rw,go= archivo` (o `u=rw,g=,o=`). Es el permiso típico de archivos privados como claves SSH.

**3.3** Dio todos los permisos (`rwxrwxrwx`) a todo el mundo: cualquier usuario del sistema puede leer, modificar y ejecutar el archivo. Para un archivo de datos privados es exactamente lo contrario de lo que se busca; además el permiso de ejecución en un archivo de datos no tiene sentido. Lo correcto sería algo como `600` o `640`.

### Bloque 4

**4.1** En un directorio: `r` permite **listar** los nombres de las entradas (lo que hace `ls`); `w` permite **crear, renombrar y borrar** entradas dentro del directorio; `x` permite **atravesarlo** (entrar con `cd` y acceder a los archivos que contiene). Sin `x`, la `r` y la `w` sirven de poco.

**4.2** Porque la lectura del directorio solo controla el listado de nombres. Como el directorio conservaba `x`, se podía atravesar, y como ya conocías el nombre exacto del archivo (`secreto.txt`) y ese archivo era legible, `cat` funcionó. `ls` falló porque listar requiere `r` sobre el directorio.

**4.3** Necesita `w` (para crear/borrar entradas) **y** `x` (para atravesar el directorio). Un detalle que suele sorprender: borrar un archivo depende de los permisos del **directorio**, no de los permisos del archivo en sí.

### Bloque 5

**5.1** `chown` cambia el dueño (y opcionalmente el grupo); `chgrp` cambia solo el grupo. La forma `chown usuario:grupo archivo` cambia ambos en un solo comando. `chown :grupo` cambia solo el grupo (equivale a `chgrp`).

**5.2** Por seguridad, en Linux solo root puede cambiar el dueño de un archivo. Si un usuario normal pudiera "regalar" archivos, podría por ejemplo atribuir a otro usuario archivos maliciosos, o evadir cuotas de disco asignándole sus archivos a otra cuenta.

**5.3** Como el dueño pasó a ser root y tu usuario ya no es el owner, el sistema evalúa primero si estás en el grupo del archivo: si sí, aplican los permisos de *group*; si no, los de *others*. Con permisos típicos `rw-r--r--`, en ambos casos solo tendrías lectura, por eso el `>>` del paso 5 falla con *Permission denied*. La evaluación es en orden user → group → others, y se aplica la **primera** categoría que coincide.

### Bloque 6

**6.1** El *setuid* hace que el programa se ejecute con los privilegios del **dueño del binario** (root en este caso) en lugar de los del usuario que lo lanza. Es necesario en `passwd` porque cualquier usuario debe poder cambiar su propia contraseña, y eso implica escribir en `/etc/shadow`, un archivo que solo root puede modificar.

**6.2** En un directorio con permisos de escritura para todos (como `/tmp`), el *sticky bit* restringe el borrado: cada usuario solo puede eliminar o renombrar **sus propios** archivos (o los del directorio si es el dueño del directorio, y root siempre puede). Sin él, cualquiera podría borrar los archivos temporales de otros usuarios.

**6.3** setuid = 4, setgid = 2, sticky = 1, y se anteponen como cuarto dígito a la izquierda. `rwxrwsr-x` corresponde a setgid (2) + `775`, es decir: `chmod 2775 directorio` (equivalente simbólico: `chmod g+s directorio` sobre un directorio que ya tiene `775`).

</details>