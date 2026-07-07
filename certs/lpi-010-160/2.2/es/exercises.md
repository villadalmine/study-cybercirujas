# Ejercicios guiados — Tema 2.2: Using the Command Line to Get Help

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2
**Referencia:** [learning.lpi.org — 2.2 Using the Command Line to Get Help](https://learning.lpi.org/en/learning-materials/010-160/2/2.2/)

Necesitás una terminal en cualquier distribución Linux. Ejecutá cada paso y respondé las preguntas antes de mirar las soluciones.

---

## Ejercicio 1 — La opción `--help`

La forma más rápida de obtener ayuda es pedírsela al propio comando.

1. Ejecutá:
   ```bash
   ls --help
   ```
2. Como la salida es larga, paginala:
   ```bash
   ls --help | less
   ```
   Salí de `less` con la tecla `q`.
3. Probá la versión corta que ofrecen algunos comandos:
   ```bash
   cp --help | head -n 5
   ```

**Preguntas:**

- **1.a)** ¿Qué ventaja tiene `--help` frente a otros métodos de ayuda?
- **1.b)** ¿Por qué conviene combinar `--help` con `less` o `head`?

---

## Ejercicio 2 — Las *man pages*

El manual del sistema (`man`) es la fuente de documentación clásica de Linux.

1. Abrí la página de manual de `ls`:
   ```bash
   man ls
   ```
2. Dentro de `man` (que usa `less` como *pager*), practicá la navegación:
   - `Espacio` o `AvPág`: avanzar una pantalla
   - `b` o `RePág`: retroceder una pantalla
   - `/size`: buscar la palabra "size" hacia adelante
   - `n`: siguiente coincidencia, `N`: coincidencia anterior
   - `g`: ir al inicio, `G`: ir al final
   - `q`: salir
3. Identificá en la página las secciones típicas: **NAME**, **SYNOPSIS**, **DESCRIPTION**, **OPTIONS**, **SEE ALSO**.
4. Mirá el encabezado de la página: dice `LS(1)`. Ese `1` es la **sección** del manual.

**Preguntas:**

- **2.a)** ¿Qué información encontrás en la sección **SYNOPSIS** de una *man page*?
- **2.b)** ¿Qué tecla usás para buscar texto dentro de una *man page* y cuál para saltar a la siguiente coincidencia?
- **2.c)** ¿Qué significa el número entre paréntesis en `LS(1)`?

---

## Ejercicio 3 — Secciones del manual

El manual está dividido en secciones numeradas; una misma palabra puede existir en varias.

1. Ejecutá:
   ```bash
   man passwd
   ```
   Fijate en el encabezado: `PASSWD(1)`. Salí con `q`.
2. Ahora pedí explícitamente la sección 5:
   ```bash
   man 5 passwd
   ```
   El encabezado ahora dice `PASSWD(5)` y el contenido es distinto: describe el **archivo** `/etc/passwd`, no el comando.
3. Listá todas las páginas disponibles con ese nombre:
   ```bash
   man -f passwd
   ```

Las secciones más importantes para el examen:

| Sección | Contenido |
|---------|-----------|
| 1 | Comandos de usuario |
| 2 | System calls |
| 3 | Funciones de bibliotecas (C) |
| 4 | Archivos especiales y drivers (`/dev`) |
| 5 | Formatos de archivos de configuración |
| 6 | Juegos |
| 7 | Convenciones, misceláneas |
| 8 | Comandos de administración del sistema |

**Preguntas:**

- **3.a)** ¿Qué comando ejecutarías para leer la documentación del archivo de configuración `/etc/fstab`? ¿En qué sección esperás encontrarla?
- **3.b)** Si `man passwd` te muestra la sección 1 pero vos querés el formato del archivo, ¿qué comando exacto usás?
- **3.c)** ¿En qué sección del manual buscarías la documentación de un comando de administración como `mount` (en su rol administrativo)?

---

## Ejercicio 4 — Buscar por palabra clave: `apropos` y `whatis`

¿Y si no sabés cómo se llama el comando? Para eso están las búsquedas por palabra clave.

1. Buscá comandos relacionados con directorios:
   ```bash
   apropos directory
   ```
2. Obtené lo mismo con la opción equivalente de `man`:
   ```bash
   man -k directory
   ```
3. Pedí solo la descripción corta de un comando conocido:
   ```bash
   whatis ls
   man -f ls
   ```
4. Si `apropos` devuelve `nothing appropriate`, la base de datos del manual puede estar desactualizada. Se regenera (como root) con:
   ```bash
   sudo mandb
   ```
   *(Solo ejecutalo si tenés permisos; en la mayoría de los sistemas ya está actualizada.)*

**Preguntas:**

- **4.a)** ¿Cuál es la diferencia entre `apropos` y `whatis`?
- **4.b)** ¿A qué opciones de `man` equivalen `apropos` y `whatis` respectivamente?
- **4.c)** ¿Dónde buscan estos comandos: en el contenido completo de las páginas o en otra parte?

---

## Ejercicio 5 — Las *info pages*

El proyecto GNU documenta muchas de sus herramientas en formato `info`, más extenso y con hipervínculos.

1. Abrí la documentación info de `ls`:
   ```bash
   info ls
   ```
2. Practicá la navegación básica:
   - `Espacio`: avanzar
   - `n`: nodo siguiente (*next*), `p`: nodo anterior (*previous*), `u`: subir un nivel (*up*)
   - `Enter` sobre una línea que empieza con `*`: seguir el enlace
   - `l`: volver atrás (*last*)
   - `q`: salir
3. Abrí el índice general de info:
   ```bash
   info
   ```
   Movete con las flechas y entrá a algún nodo con `Enter`. Salí con `q`.

**Preguntas:**

- **5.a)** Mencioná dos diferencias entre las *info pages* y las *man pages*.
- **5.b)** Dentro de `info`, ¿qué teclas te llevan al nodo siguiente, al anterior y un nivel arriba?

---

## Ejercicio 6 — Documentación en `/usr/share/doc`

Muchos paquetes instalan documentación adicional (README, changelogs, ejemplos) en el sistema de archivos.

1. Listá el contenido del directorio:
   ```bash
   ls /usr/share/doc | less
   ```
2. Entrá al directorio de algún paquete que tengas instalado, por ejemplo:
   ```bash
   ls /usr/share/doc/bash
   ```
   *(Si no existe, elegí otro paquete de la lista del paso 1.)*
3. Leé algún archivo de texto que encuentres, por ejemplo:
   ```bash
   less /usr/share/doc/bash/README
   ```
   *(Los nombres varían según la distribución; algunos archivos están comprimidos como `.gz` y podés verlos con `zless`.)*

**Preguntas:**

- **6.a)** ¿Qué tipo de contenido esperás encontrar en `/usr/share/doc/<paquete>` que normalmente no está en la *man page*?
- **6.b)** ¿Cómo están organizados los archivos dentro de `/usr/share/doc`?

---

## Ejercicio 7 — Localizar archivos y programas: `locate`, `find`, `which`, `whereis`, `type`

Parte de "obtener ayuda" es poder encontrar dónde está un comando o un archivo.

1. Averiguá qué ejecutable se usa cuando escribís `ls`:
   ```bash
   which ls
   ```
2. Obtené el binario, el código fuente (si existe) y las *man pages* de un comando:
   ```bash
   whereis ls
   ```
3. Consultá cómo interpreta la shell un nombre (binario, alias, builtin o función):
   ```bash
   type ls
   type cd
   type type
   ```
4. Buscá archivos por nombre con la base de datos de `locate`:
   ```bash
   locate fstab
   ```
   Si el comando no existe o la base está vacía, instalá el paquete (`mlocate` o `plocate`) y actualizá la base con:
   ```bash
   sudo updatedb
   ```
5. Buscá en tiempo real con `find` (sin base de datos):
   ```bash
   find /etc -name fstab 2>/dev/null
   find ~ -name "*.txt"
   ```

**Preguntas:**

- **7.a)** ¿Cuál es la diferencia clave entre `locate` y `find` en cuanto a *cómo* buscan?
- **7.b)** Creaste un archivo hace un minuto y `locate` no lo encuentra. ¿Por qué, y cómo lo solucionás?
- **7.c)** ¿Qué muestra `whereis` que `which` no muestra?
- **7.d)** `which cd` puede no devolver nada útil, pero `type cd` sí explica qué es. ¿Por qué?

---

## Ejercicio 8 — Integrador

Resolvé este mini-desafío usando solo lo aprendido:

1. No recordás el nombre del comando para cambiar contraseñas. Buscalo por palabra clave con `apropos password`.
2. Una vez identificado (`passwd`), leé su descripción corta con `whatis passwd`.
3. Abrí su *man page* y buscá dentro de ella la palabra "expire" con `/expire`.
4. Averiguá dónde está el binario con `which passwd` y `whereis passwd`.
5. Leé la documentación del **archivo** `/etc/passwd` con la sección correcta del manual.

**Pregunta:**

- **8.a)** Escribí la secuencia completa de comandos que usaste en los pasos 1 a 5.

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

**1.a)** Es inmediata y está incluida en el propio programa: no depende de que haya páginas de manual instaladas, y suele ser un resumen rápido de sintaxis y opciones, ideal como primer recurso.

**1.b)** Porque la salida de `--help` suele ocupar más de una pantalla; `less` permite navegarla y buscar dentro de ella, y `head` muestra solo las primeras líneas (normalmente el *usage*).

**2.a)** El **SYNOPSIS** muestra la sintaxis de invocación del comando: el nombre, las opciones (entre corchetes `[]` cuando son opcionales) y los argumentos que acepta.

**2.b)** `/texto` busca hacia adelante; `n` salta a la siguiente coincidencia (`N` a la anterior).

**2.c)** Indica la **sección del manual** a la que pertenece la página: `LS(1)` significa que `ls` está documentado en la sección 1, la de comandos de usuario.

**3.a)** `man 5 fstab` — los formatos de archivos de configuración están en la **sección 5**. (En este caso `man fstab` también funciona porque solo existe en esa sección, pero pedirla explícitamente es lo correcto.)

**3.b)** `man 5 passwd` — el número de sección va **antes** del nombre de la página.

**3.c)** En la **sección 8** (comandos de administración del sistema). Por ejemplo, `man 8 mount`.

**4.a)** `apropos` busca una **palabra clave** en los nombres y descripciones cortas de todas las *man pages* y devuelve todas las coincidencias (útil cuando no sabés el nombre del comando). `whatis` busca una **coincidencia exacta de nombre** y devuelve solo la descripción corta de esa página.

**4.b)** `apropos` equivale a `man -k`; `whatis` equivale a `man -f`.

**4.c)** No leen las páginas completas: consultan una **base de datos** de nombres y descripciones cortas que se genera con `mandb`. Por eso, si la base está desactualizada, pueden no encontrar nada.

**5.a)** Cualquiera de estas: (1) las *info pages* están organizadas en **nodos enlazados** (hipervínculos) mientras que las *man pages* son un documento lineal; (2) las *info pages* suelen ser más **extensas y tipo tutorial**, mientras que las *man pages* son de referencia concisa; (3) `info` es el formato preferido del proyecto **GNU**.

**5.b)** `n` = nodo siguiente, `p` = nodo anterior, `u` = subir un nivel.

**6.a)** Documentación extra provista por el paquete: archivos README, changelogs, notas de licencia, ejemplos de configuración, FAQs y a veces manuales completos en HTML o PDF.

**6.b)** En **subdirectorios por paquete**: cada paquete instalado tiene su propio directorio, por ejemplo `/usr/share/doc/bash/`.

**7.a)** `locate` busca en una **base de datos precalculada** (rapidísimo, pero puede estar desactualizada); `find` recorre el **sistema de archivos en tiempo real** (más lento, pero siempre refleja el estado actual y permite criterios avanzados: tamaño, fecha, permisos, etc.).

**7.b)** Porque la base de datos de `locate` se actualiza periódicamente (típicamente una vez al día vía cron) y el archivo nuevo todavía no está indexado. Se soluciona ejecutando `sudo updatedb` para regenerar la base.

**7.c)** `which` muestra solo la **ruta del ejecutable** que se usaría según el `PATH`. `whereis` además muestra la ubicación del **código fuente** (si está) y de las **man pages** asociadas.

**7.d)** Porque `cd` no es un archivo ejecutable en el disco sino un **shell builtin** (comando interno de la shell). `which` busca ejecutables en el `PATH`, así que no lo encuentra; `type` es un builtin de la shell que conoce aliases, funciones y builtins, y por eso responde `cd is a shell builtin`.

**8.a)** Una secuencia válida:

```bash
apropos password        # 1. buscar comandos relacionados con contraseñas
whatis passwd           # 2. descripción corta
man passwd              # 3. abrir la man page; adentro: /expire y n para navegar
which passwd            # 4a. ruta del ejecutable
whereis passwd          # 4b. binario + man pages
man 5 passwd            # 5. formato del archivo /etc/passwd (sección 5)
```

</details>