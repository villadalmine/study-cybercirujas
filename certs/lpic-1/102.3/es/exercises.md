# 102.3 — Gestionar bibliotecas compartidas: ejercicios guiados

**LPIC-1 / Examen 101-500, Tema 102.3 — peso 1.56**
Cobertura del objetivo: identificar bibliotecas compartidas, comprender la ruta de búsqueda de bibliotecas del sistema, cargar bibliotecas compartidas, `ldd`, `ldconfig`, `/etc/ld.so.conf`, `LD_LIBRARY_PATH`.

---

## Entorno de laboratorio

Estos ejercicios están escritos para **Debian 12 / Ubuntu 24.04 en x86_64** (rutas multiarch). Donde RHEL/Fedora/openSUSE difieren, la diferencia se señala explícitamente — saber *cuáles* rutas son convención de la distribución y cuáles están compiladas dentro de `ld.so` es en sí mismo una distinción de nivel de examen.

Preparar la máquina:

```bash
sudo apt-get install -y build-essential binutils file    # Debian/Ubuntu
# sudo dnf install -y gcc binutils file glibc-devel      # RHEL/Fedora
mkdir -p ~/lab-102.3 && cd ~/lab-102.3
```

> **Seguridad.** Los ejercicios 7 y 8 modifican `/etc/ld.so.conf.d/` y rompen un enlace deliberadamente. Ejecutalos en una VM descartable, en un contenedor (`docker run -it --rm debian:12 bash`), o asumí que vas a tener que ejecutar la reversión documentada. **Nunca** experimentes con `LD_PRELOAD`, `/etc/ld.so.preload`, ni con un `libc.so.6` movido de lugar en una máquina que no podés reinstalar.

---

## Bloque 1 — Estático vs. dinámico: qué se enlaza realmente

Todo el tema existe por una sola decisión de diseño: un binario puede llevar el código de la biblioteca dentro de sí mismo (estático) o pedirle al kernel que lo cargue en tiempo de ejecución (dinámico). Todo lo demás — la caché, la ruta de búsqueda, `ldconfig` — es infraestructura para el segundo caso.

### Pasos

1. Identificar el tipo de enlazado de un binario normal del sistema:

   ```bash
   file /bin/ls
   ```

   Salida esperada:

   ```
   /bin/ls: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
   interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=..., for GNU/Linux 3.2.0, stripped
   ```

2. Ahora compilá el mismo programa trivial dos veces, una de cada forma:

   ```bash
   cd ~/lab-102.3
   printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > hi.c
   gcc hi.c -o hi-dynamic
   gcc -static hi.c -o hi-static
   ```

3. Compararlos:

   ```bash
   ls -l hi-dynamic hi-static
   file hi-dynamic hi-static
   ```

   Salida esperada (los tamaños varían según la versión de glibc):

   ```
   -rwxr-xr-x 1 user user   16040 Aug 25 10:12 hi-dynamic
   -rwxr-xr-x 1 user user  916312 Aug 25 10:12 hi-static

   hi-dynamic: ELF 64-bit LSB pie executable, x86-64, ..., dynamically linked,
               interpreter /lib64/ld-linux-x86-64.so.2, ...
   hi-static:  ELF 64-bit LSB executable, x86-64, ..., statically linked, ...
   ```

4. Preguntarle al enlazador dinámico qué necesita cada uno:

   ```bash
   ldd hi-dynamic
   ldd hi-static
   ```

   Salida esperada:

   ```
   	linux-vdso.so.1 (0x00007ffd4b1fe000)
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0e2a000000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f0e2a2b1000)

   	not a dynamic executable
   ```

5. Inspeccionar la cabecera de programa ELF que nombra al propio cargador:

   ```bash
   readelf -l hi-dynamic | grep -A1 INTERP
   ```

   Salida esperada:

   ```
     INTERP         0x0000000000000318 0x0000000000000318 0x0000000000000318
                    0x000000000000001c 0x000000000000001c  R      0x1
       [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
   ```

### Verificá tu comprensión

- **Q1.1** — `hi-static` es ~57× más grande que `hi-dynamic`. ¿De dónde salieron los ~900 KB extra, y por qué el dinámico igual puede ejecutarse?
- **Q1.2** — `ldd hi-static` imprime `not a dynamic executable`. ¿Es eso un error?
- **Q1.3** — ¿Qué es `linux-vdso.so.1`, y por qué falla `ls -l` sobre esa ruta?
- **Q1.4** — `/lib64/ld-linux-x86-64.so.2` aparece en la salida de `ldd` *sin* una flecha `=>`. ¿Qué te dice eso sobre cómo fue encontrado?
- **Q1.5** — Nombrá una ventaja operativa del enlazado estático y una del dinámico, en términos de producción (no "más chico/más grande").

---

## Bloque 2 — Leer la sección dinámica directamente

`ldd` es cómodo y, sobre binarios no confiables, inseguro: en glibc puede ejecutar el binario a través del cargador para resolver dependencias. `readelf` y `objdump` solamente *leen* el archivo. Construí el hábito ahora.

### Pasos

1. Listar las dependencias declaradas de `/bin/ls` sin ejecutar nada:

   ```bash
   readelf -d /bin/ls | grep NEEDED
   ```

   Salida esperada (Debian 12):

   ```
    0x0000000000000001 (NEEDED)             Shared library: [libselinux.so.1]
    0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
   ```

2. Hacer lo mismo con `objdump`:

   ```bash
   objdump -p /bin/ls | grep -E 'NEEDED|SONAME|RPATH|RUNPATH'
   ```

3. Ahora mirá una *biblioteca* y encontrá su SONAME:

   ```bash
   objdump -p /lib/x86_64-linux-gnu/libc.so.6 | grep SONAME
   ```

   Salida esperada:

   ```
     SONAME               libc.so.6
   ```

4. Comparar la vista recursiva contra la vista declarada:

   ```bash
   readelf -d /bin/ls | grep -c NEEDED     # direct dependencies only
   ldd /bin/ls | wc -l                     # transitive closure + vdso + loader
   ```

   Salida esperada:

   ```
   2
   5
   ```

5. Verificar si hay símbolos sin resolver (un modo de falla que `ldd` por sí solo oculta):

   ```bash
   ldd -r /bin/ls
   ```

   Un binario limpio imprime la misma lista sin líneas `undefined symbol:`.

6. Listar los símbolos que una biblioteca *exporta*:

   ```bash
   nm -D --defined-only /lib/x86_64-linux-gnu/libc.so.6 | grep -w ' T printf'
   ```

   Salida esperada:

   ```
   0000000000060c50 T printf@@GLIBC_2.2.5
   ```

### Verificá tu comprensión

- **Q2.1** — `readelf -d /bin/ls` muestra 2 entradas `NEEDED` pero `ldd` muestra 5 líneas. Justificá cada línea extra.
- **Q2.2** — ¿Por qué ejecutar `ldd ./suspicious-binary` sobre un archivo que descargaste es un problema de seguridad, y qué ejecutás en su lugar?
- **Q2.3** — ¿Cuál es la diferencia entre el *SONAME* de una biblioteca y su *nombre de archivo en disco*? ¿Cuál de los dos registra el enlazador en el ejecutable?
- **Q2.4** — `printf@@GLIBC_2.2.5` — ¿para qué son el `@@` y la etiqueta de versión?
- **Q2.5** — Un binario muestra `RUNPATH  $ORIGIN/../lib`. ¿A qué se expande `$ORIGIN`, y por qué los proveedores distribuyen software así?

---

## Bloque 3 — La caché: `ldconfig -p` y `/etc/ld.so.cache`

Recorrer cada directorio de la ruta de búsqueda en cada `exec()` sería inaceptablemente lento. glibc precalcula una tabla hash de `SONAME → ruta` en `/etc/ld.so.cache`. `ldconfig` la construye; el cargador la lee.

### Pasos

1. Mirar la cabecera de la caché y su tamaño:

   ```bash
   ldconfig -p | head -5
   ls -lh /etc/ld.so.cache
   file /etc/ld.so.cache
   ```

   Salida esperada:

   ```
   1187 libs found in cache `/etc/ld.so.cache'
   	libzstd.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libzstd.so.1
   	libz.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libz.so.1
   	libuuid.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libuuid.so.1
   	libudev.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libudev.so.1

   -rw-r--r-- 1 root root 79K Aug 20 09:31 /etc/ld.so.cache
   /etc/ld.so.cache: data
   ```

2. Consultar la caché por una biblioteca específica — este es el uso cotidiano de `ldconfig -p`:

   ```bash
   ldconfig -p | grep -w libssl.so.3
   ```

   Salida esperada:

   ```
   	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3
   ```

3. Leer la configuración que alimenta la caché:

   ```bash
   cat /etc/ld.so.conf
   ls /etc/ld.so.conf.d/
   cat /etc/ld.so.conf.d/*.conf
   ```

   Salida esperada (Debian 12):

   ```
   include /etc/ld.so.conf.d/*.conf

   libc.conf  x86_64-linux-gnu.conf

   # libc default configuration
   /usr/local/lib
   # Multiarch support
   /usr/local/lib/x86_64-linux-gnu
   /lib/x86_64-linux-gnu
   /usr/lib/x86_64-linux-gnu
   ```

   En RHEL 9 vas a ver en cambio `include ld.so.conf.d/*.conf` y archivos como `kernel-*.conf`, con `/lib64` y `/usr/lib64` **ausentes** — porque están compilados dentro de `ld.so` como directorios confiables.

4. Observar a `ldconfig` haciendo su trabajo, directorio por directorio, **sin** escribir nada:

   ```bash
   sudo ldconfig -v -N -X 2>/dev/null | head -12
   ```

   Salida esperada:

   ```
   /usr/local/lib:
   /lib/x86_64-linux-gnu:
   	libnss_files.so.2 -> libnss_files.so.2
   	libpcre2-8.so.0 -> libpcre2-8.so.0.11.2
   	libselinux.so.1 -> libselinux.so.1
   ...
   ```

5. Confirmar que una ejecución simple de `ldconfig` es idempotente:

   ```bash
   sudo cp /etc/ld.so.cache /tmp/cache.before
   sudo ldconfig
   cmp /tmp/cache.before /etc/ld.so.cache && echo "identical"
   ```

### Verificá tu comprensión

- **Q3.1** — `file /etc/ld.so.cache` dice `data`. ¿Por qué no es un archivo de texto, y qué pasa si lo editás con `vim`?
- **Q3.2** — En el paso 4, ¿qué suprime cada uno de `-N` y `-X`? ¿Por qué `-N -X` es la forma segura de previsualizar?
- **Q3.3** — En la salida de `ldconfig -v`, la línea `libpcre2-8.so.0 -> libpcre2-8.so.0.11.2` describe una acción. ¿Cuál de los tres nombres de biblioteca está a la izquierda, cuál a la derecha, y quién creó el enlace simbólico?
- **Q3.4** — `/lib64` no aparece en `/etc/ld.so.conf.d/*.conf` en RHEL. ¿Por qué se encuentran igual las bibliotecas que están ahí?
- **Q3.5** — Instalaste un paquete a mano en `/opt/acme/lib`. ¿Cuál es la forma *correcta* y persistente de hacer visibles sus bibliotecas en todo el sistema, en dos comandos?

---

## Bloque 4 — Construir una biblioteca compartida y conocer sus tres nombres

Toda biblioteca compartida tiene tres nombres, y confundirlos es la fuente más común de "compiló pero no arranca".

| Nombre | Ejemplo | Quién lo usa | Quién lo crea |
|---|---|---|---|
| **Nombre real** | `libgreet.so.1.0.0` | nadie directamente | el compilador/`make install` |
| **SONAME** | `libgreet.so.1` | el cargador en *tiempo de ejecución* | `ldconfig` (enlace simbólico) |
| **Nombre de enlazador** | `libgreet.so` | `gcc -lgreet` en tiempo de *compilación* | el paquete `-dev`/`-devel` |

### Pasos

1. Escribir el código fuente de la biblioteca:

   ```bash
   cd ~/lab-102.3
   cat > greet.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who)
   {
           printf("hello, %s (libgreet v1)\n", who);
   }
   EOF
   ```

2. Compilar código independiente de posición y enlazarlo como objeto compartido, **declarando el SONAME explícitamente**:

   ```bash
   gcc -fPIC -Wall -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.1 -o libgreet.so.1.0.0 greet.o
   ```

3. Verificar que el SONAME quedó grabado en el archivo:

   ```bash
   objdump -p libgreet.so.1.0.0 | grep SONAME
   file libgreet.so.1.0.0
   ```

   Salida esperada:

   ```
     SONAME               libgreet.so.1

   libgreet.so.1.0.0: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV),
   dynamically linked, BuildID[sha1]=..., not stripped
   ```

4. Dejar que `ldconfig` cree por vos el enlace simbólico del SONAME, solo en este directorio:

   ```bash
   ldconfig -n .
   ls -l libgreet*
   ```

   Salida esperada:

   ```
   lrwxrwxrwx 1 user user    17 Aug 25 10:40 libgreet.so.1 -> libgreet.so.1.0.0
   -rwxr-xr-x 1 user user 15920 Aug 25 10:39 libgreet.so.1.0.0
   ```

5. Agregar el nombre de enlazador a mano (esto es lo que distribuye un paquete `-dev`):

   ```bash
   ln -sf libgreet.so.1 libgreet.so
   ```

6. Escribir y enlazar un consumidor:

   ```bash
   cat > main.c <<'EOF'
   void greet(const char *who);

   int main(void)
   {
           greet("LPIC-1");
           return 0;
   }
   EOF
   gcc main.c -L. -lgreet -o hello
   ```

7. Confirmar qué registró el *ejecutable*, y después intentar ejecutarlo:

   ```bash
   readelf -d hello | grep NEEDED
   ./hello
   ```

   Salida esperada:

   ```
    0x0000000000000001 (NEEDED)             Shared library: [libgreet.so.1]
    0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]

   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

8. Diagnosticarlo como lo harías en producción:

   ```bash
   ldd ./hello
   ```

   Salida esperada:

   ```
   	linux-vdso.so.1 (0x00007ffc9f7f6000)
   	libgreet.so.1 => not found
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f4b1c000000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f4b1c2a4000)
   ```

### Verificá tu comprensión

- **Q4.1** — Enlazaste con `-lgreet`, que resolvió `libgreet.so` (el nombre de enlazador), y sin embargo `readelf -d hello` registra `libgreet.so.1`. Explicá el mecanismo que convirtió uno en el otro.
- **Q4.2** — ¿Por qué `-fPIC` es obligatorio para la biblioteca pero no para `main.c`?
- **Q4.3** — El archivo de la biblioteca está en el *directorio actual* y ejecutaste `./hello` desde ese mismo directorio. ¿Por qué sigue siendo `not found`?
- **Q4.4** — ¿Qué hizo exactamente `ldconfig -n .`, y en qué se diferencia `-n` de un `ldconfig` a secas?
- **Q4.5** — Si hubieras omitido `-Wl,-soname,libgreet.so.1`, ¿qué habría mostrado `readelf -d hello | grep NEEDED`, y por qué eso es un bug latente de producción?

---

## Bloque 5 — `LD_LIBRARY_PATH` y el orden de búsqueda real

### Pasos

1. Hacer funcionar el binario anterior con una variable de entorno:

   ```bash
   cd ~/lab-102.3
   LD_LIBRARY_PATH=$PWD ./hello
   ```

   Salida esperada:

   ```
   hello, LPIC-1 (libgreet v1)
   ```

2. Confirmar que es por proceso, no persistente:

   ```bash
   ./hello
   ```

   Salida esperada:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

3. Exportarla y observar que `ldd` también la obedece:

   ```bash
   export LD_LIBRARY_PATH=$PWD
   ldd ./hello | grep greet
   ```

   Salida esperada:

   ```
   	libgreet.so.1 => /home/user/lab-102.3/libgreet.so.1 (0x00007f3a5c9f0000)
   ```

4. Rastrear la búsqueda real con `LD_DEBUG` — esta es la herramienta que termina las discusiones sobre el orden de búsqueda:

   ```bash
   LD_DEBUG=libs ./hello 2>&1 | head -20
   ```

   Salida esperada (abreviada):

   ```
        4711:	find library=libgreet.so.1 [0]; searching
        4711:	 search path=/home/user/lab-102.3		(LD_LIBRARY_PATH)
        4711:	  trying file=/home/user/lab-102.3/libgreet.so.1
        4711:
        4711:	find library=libc.so.6 [0]; searching
        4711:	 search path=/home/user/lab-102.3		(LD_LIBRARY_PATH)
        4711:	  trying file=/home/user/lab-102.3/libc.so.6
        4711:	 search cache=/etc/ld.so.cache
        4711:	  trying file=/lib/x86_64-linux-gnu/libc.so.6
   ```

5. Ver el menú completo de canales de depuración:

   ```bash
   LD_DEBUG=help ./hello
   ```

6. Demostrar que `LD_LIBRARY_PATH` se descarta para binarios privilegiados:

   ```bash
   ls -l /usr/bin/passwd            # note the 's' in the mode
   LD_DEBUG=libs /usr/bin/passwd --help 2>&1 | head -3
   ```

   Salida esperada:

   ```
   -rwsr-xr-x 1 root root 68208 Mar 23  2023 /usr/bin/passwd
   ```

   …y **ningún** rastro de `LD_DEBUG` en absoluto: el cargador ignora estas variables para los binarios set-user-ID.

7. Limpiar antes del siguiente bloque:

   ```bash
   unset LD_LIBRARY_PATH
   ```

### El orden autoritativo

Para cada SONAME `NEEDED`, el `ld.so` de glibc busca, en este orden:

1. `DT_RPATH` en el objeto — **solo si** `DT_RUNPATH` está ausente (obsoleto).
2. `LD_LIBRARY_PATH` — ignorado por completo para binarios set-user-ID / set-group-ID / portadores de capacidades.
3. `DT_RUNPATH` en el objeto.
4. `/etc/ld.so.cache` — a menos que el objeto haya sido enlazado con `-z nodeflib`.
5. Los directorios predeterminados confiables: `/lib`, `/usr/lib` (más `/lib64`, `/usr/lib64` en 64 bits).

### Verificá tu comprensión

- **Q5.1** — Ordená estos según el orden de búsqueda e indicá la única relación condicional entre dos de ellos: `LD_LIBRARY_PATH`, `DT_RUNPATH`, `/etc/ld.so.cache`, `DT_RPATH`, `/lib`.
- **Q5.2** — En el rastro del paso 4, ¿por qué el cargador prueba `/home/user/lab-102.3/libc.so.6` y falla, antes de encontrar el `libc.so.6` real?
- **Q5.3** — ¿Por qué el cargador ignora `LD_LIBRARY_PATH` para `/usr/bin/passwd`? Describí el ataque que eso previene.
- **Q5.4** — Un colega arregla un error de biblioteca faltante agregando `export LD_LIBRARY_PATH=/opt/app/lib` a `/etc/profile`. Dá tres razones concretas por las que esa es la solución equivocada, e indicá la correcta.
- **Q5.5** — `LD_LIBRARY_PATH` está configurada como `/a:/b` y `/etc/ld.so.cache` mapea `libfoo.so.1` a `/usr/lib/libfoo.so.1`. También existe una copia en `/b`. ¿Cuál se carga?

---

## Bloque 6 — Instalar la biblioteca correctamente, y la ruptura de ABI

### Pasos

1. Instalar la biblioteca donde corresponde a un paquete compilado localmente, según el FHS:

   ```bash
   cd ~/lab-102.3
   sudo install -m 0755 libgreet.so.1.0.0 /usr/local/lib/
   sudo ldconfig
   ```

2. Verificar que `ldconfig` creó el enlace simbólico del SONAME y cacheó la entrada:

   ```bash
   ls -l /usr/local/lib/libgreet*
   ldconfig -p | grep greet
   ```

   Salida esperada:

   ```
   lrwxrwxrwx 1 root root    17 Aug 25 11:02 /usr/local/lib/libgreet.so.1 -> libgreet.so.1.0.0
   -rwxr-xr-x 1 root root 15920 Aug 25 11:02 /usr/local/lib/libgreet.so.1.0.0

   	libgreet.so.1 (libc6,x86-64) => /usr/local/lib/libgreet.so.1
   ```

   > Si no aparece nada, tu distribución no incluye `/usr/local/lib` en la ruta de búsqueda. Agregalo: `echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf && sudo ldconfig`.

3. Ejecutar el binario sin trucos de entorno:

   ```bash
   ./hello
   ldd ./hello | grep greet
   ```

   Salida esperada:

   ```
   hello, LPIC-1 (libgreet v1)
   	libgreet.so.1 => /usr/local/lib/libgreet.so.1 (0x00007f1b2c9f0000)
   ```

4. Publicar una actualización **compatible** — mismo SONAME, nuevo nombre real:

   ```bash
   sed -i 's/libgreet v1/libgreet v1.1/' greet.c
   gcc -fPIC -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.1 -o libgreet.so.1.1.0 greet.o
   sudo install -m 0755 libgreet.so.1.1.0 /usr/local/lib/
   sudo ldconfig
   ls -l /usr/local/lib/libgreet.so.1
   ./hello
   ```

   Salida esperada:

   ```
   lrwxrwxrwx 1 root root 17 Aug 25 11:08 /usr/local/lib/libgreet.so.1 -> libgreet.so.1.1.0
   hello, LPIC-1 (libgreet v1.1)
   ```

   El binario **no** fue recompilado. Ese es el sentido del SONAME.

5. Ahora publicar una actualización **incompatible** — cambia la firma de la función, así que el SONAME debe cambiar:

   ```bash
   cat > greet.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who, int times)
   {
           for (int i = 0; i < times; i++)
                   printf("hello, %s (libgreet v2)\n", who);
   }
   EOF
   gcc -fPIC -c greet.c -o greet.o
   gcc -shared -Wl,-soname,libgreet.so.2 -o libgreet.so.2.0.0 greet.o
   sudo install -m 0755 libgreet.so.2.0.0 /usr/local/lib/
   sudo ldconfig
   ls -l /usr/local/lib/libgreet*
   ./hello
   ```

   Salida esperada:

   ```
   lrwxrwxrwx 1 root root    17 ... /usr/local/lib/libgreet.so.1 -> libgreet.so.1.1.0
   lrwxrwxrwx 1 root root    17 ... /usr/local/lib/libgreet.so.2 -> libgreet.so.2.0.0
   -rwxr-xr-x 1 root root 15920 ... /usr/local/lib/libgreet.so.1.0.0
   -rwxr-xr-x 1 root root 15928 ... /usr/local/lib/libgreet.so.1.1.0
   -rwxr-xr-x 1 root root 16040 ... /usr/local/lib/libgreet.so.2.0.0

   hello, LPIC-1 (libgreet v1.1)
   ```

6. Confirmar que ambas versiones mayores coexisten en la caché:

   ```bash
   ldconfig -p | grep greet
   ```

   Salida esperada:

   ```
   	libgreet.so.2 (libc6,x86-64) => /usr/local/lib/libgreet.so.2
   	libgreet.so.1 (libc6,x86-64) => /usr/local/lib/libgreet.so.1
   ```

### Verificá tu comprensión

- **Q6.1** — En el paso 4, `./hello` adoptó el nuevo comportamiento sin ser reenlazado. Rastreá la cadena exacta de nombres que lo hizo posible.
- **Q6.2** — En el paso 5 el binario viejo sigue imprimiendo `v1.1`. ¿Es eso un bug o el resultado diseñado? ¿Qué habría pasado si el desarrollador hubiera reutilizado el SONAME `libgreet.so.1` para el código v2?
- **Q6.3** — `ldconfig` creó `libgreet.so.1` y `libgreet.so.2` pero nunca `libgreet.so`. ¿Por qué se niega a hacerlo, y qué se rompe como consecuencia?
- **Q6.4** — Tenés `libgreet.so.1.0.0` y `libgreet.so.1.1.0` en el mismo directorio, ambos con SONAME `libgreet.so.1`. ¿A cuál apunta el enlace simbólico que crea `ldconfig`, y según qué regla?
- **Q6.5** — Llevá esto a un paquete real: `libssl.so.3` vs `libssl.so.1.1`. ¿Por qué una distribución podría distribuir ambos simultáneamente, y qué significa eso para el nombrado de paquetes de `dpkg`/`rpm`?

---

## Bloque 7 — Diagnosticar fallas: los cuatro errores canónicos

### Pasos

1. **Error A — biblioteca faltante.** Ocultá la cadena v1 y ejecutá el binario viejo:

   ```bash
   sudo mv /usr/local/lib/libgreet.so.1.1.0 /root/
   sudo ldconfig
   ./hello
   ldd ./hello | grep greet
   ```

   Salida esperada:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   	libgreet.so.1 => not found
   ```

2. **Error B — caché desactualizada.** Restaurá el archivo pero *no* reconstruyas la caché:

   ```bash
   sudo mv /root/libgreet.so.1.1.0 /usr/local/lib/
   ./hello
   ```

   Salida esperada — sigue fallando, porque el enlace simbólico del SONAME y la entrada de la caché ya no están:

   ```
   ./hello: error while loading shared libraries: libgreet.so.1: cannot open shared
   object file: No such file or directory
   ```

   Y después:

   ```bash
   sudo ldconfig
   ./hello
   ```

   ```
   hello, LPIC-1 (libgreet v1.1)
   ```

3. **Error C — arquitectura equivocada.** Preguntale a la caché qué sabe sobre la etiqueta de ABI:

   ```bash
   ldconfig -p | grep -c 'libc6,x86-64'
   ldconfig -p | grep -c 'libc6)'      # 32-bit entries, if any
   ```

   Una biblioteca de 32 bits en una ruta de búsqueda de 64 bits produce:

   ```
   ./app: error while loading shared libraries: libfoo.so.1: wrong ELF class: ELFCLASS32
   ```

4. **Error D — símbolo indefinido.** Forzá el desajuste que `ldd` por sí solo no muestra:

   ```bash
   cd ~/lab-102.3
   gcc main.c -L/usr/local/lib -l:libgreet.so.2 -o hello2
   readelf -d hello2 | grep NEEDED
   ./hello2
   ```

   La biblioteca v2 exporta `greet(const char *, int)`; `main.c` la llama con un solo argumento. C no tiene name mangling, así que enlaza y ejecuta — con un segundo argumento basura. Ahora hagamos la falla explícita:

   ```bash
   printf 'void nosuchfunc(void);\nint main(void){nosuchfunc();return 0;}\n' > bad.c
   gcc bad.c -L/usr/local/lib -l:libgreet.so.2 -o bad 2>&1 | tail -2
   ```

   Salida esperada:

   ```
   /usr/bin/ld: /tmp/ccXXXX.o: in function `main':
   bad.c:(.text+0xa): undefined reference to `nosuchfunc'
   ```

   En tiempo de *ejecución*, el equivalente (desde un plugin con enlazado perezoso) se ve así:

   ```
   symbol lookup error: ./plugin.so: undefined symbol: nosuchfunc
   ```

   `ldd -r` es lo que lo detecta antes de que lo publiques.

5. Forzar el enlazado anticipado para hacer aflorar todo símbolo faltante al arranque en lugar de en la primera llamada:

   ```bash
   LD_BIND_NOW=1 ./hello
   ```

### Verificá tu comprensión

- **Q7.1** — En el paso 2 el archivo estaba de vuelta en disco, en el directorio correcto, y sin embargo el programa seguía fallando. Nombrá las dos cosas que faltaban y el único comando que recreó ambas.
- **Q7.2** — Distinguí estos dos mensajes con precisión: `error while loading shared libraries: ... cannot open shared object file` vs. `symbol lookup error: ... undefined symbol`. ¿En qué etapa ocurre cada uno?
- **Q7.3** — ¿Qué significa `wrong ELF class: ELFCLASS32`, y cuál es la solución?
- **Q7.4** — ¿Qué codifica la etiqueta `(libc6,x86-64)` en la salida de `ldconfig -p`, y por qué la caché la necesita?
- **Q7.5** — ¿Por qué `LD_BIND_NOW=1` convierte un fallo latente a la hora 3 en un fallo al arranque, y cuándo es ese el comportamiento que querés?

---

## Bloque 8 — Interposición: `LD_PRELOAD` y `/etc/ld.so.preload`

`LD_PRELOAD` carga objetos *antes* que cualquier otra dependencia, de modo que sus símbolos ganan. Es una herramienta legítima de depuración, una solución alternativa legítima de empaquetado, y una técnica clásica de rootkit — todo con el mismo mecanismo.

### Pasos

1. Escribir una biblioteca interpositora que reemplace `greet`:

   ```bash
   cd ~/lab-102.3
   cat > fake.c <<'EOF'
   #include <stdio.h>

   void greet(const char *who)
   {
           printf("INTERPOSED: %s\n", who);
   }
   EOF
   gcc -fPIC -shared -o libfake.so fake.c
   ```

2. Ejecutar el binario original con la precarga:

   ```bash
   ./hello
   LD_PRELOAD=$PWD/libfake.so ./hello
   ```

   Salida esperada:

   ```
   hello, LPIC-1 (libgreet v1.1)
   INTERPOSED: LPIC-1
   ```

3. Confirmar el orden de carga:

   ```bash
   LD_PRELOAD=$PWD/libfake.so ldd ./hello
   ```

   Salida esperada:

   ```
   	linux-vdso.so.1 (0x00007ffe4b3f9000)
   	/home/user/lab-102.3/libfake.so (0x00007f8c2d1f0000)
   	libgreet.so.1 => /usr/local/lib/libgreet.so.1 (0x00007f8c2d1e0000)
   	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8c2ce00000)
   	/lib64/ld-linux-x86-64.so.2 (0x00007f8c2d201000)
   ```

4. Inspeccionar — **no crear** — el equivalente a nivel de todo el sistema:

   ```bash
   ls -l /etc/ld.so.preload 2>&1
   ```

   Salida esperada en un sistema sano:

   ```
   ls: cannot access '/etc/ld.so.preload': No such file or directory
   ```

5. Verificar que la protección para setuid también se aplica acá:

   ```bash
   LD_PRELOAD=$PWD/libfake.so /usr/bin/passwd --help >/dev/null; echo "exit=$?"
   ```

   La precarga se descarta silenciosamente; `passwd` se ejecuta normalmente.

### Verificá tu comprensión

- **Q8.1** — En el paso 3, `libfake.so` aparece *arriba* de `libgreet.so.1` y sin flecha `=>`. Explicá ambos detalles.
- **Q8.2** — ¿Por qué la existencia de `/etc/ld.so.preload` en un host de producción es un hallazgo de seguridad P1, y cuál es el paso de triaje estándar?
- **Q8.3** — `LD_PRELOAD` se ignora para binarios setuid, pero una biblioteca listada en `/etc/ld.so.preload` **no** (con restricciones). ¿Cuál es el razonamiento de seguridad detrás de esa asimetría?
- **Q8.4** — Nombrá un uso de producción enteramente legítimo de `LD_PRELOAD`.
- **Q8.5** — Tu `greet` interpositora nunca llama a la real. ¿Cómo escribirías un *wrapper* que registre y después delegue? Nombrá la función de glibc necesaria.

---

## Bloque 9 — Recuperación y la realidad entre distribuciones

### Pasos

1. Reconstruir la caché en un archivo alternativo, dejando intacta la que está en uso:

   ```bash
   sudo ldconfig -C /tmp/test.cache
   ls -lh /tmp/test.cache
   ldconfig -p -C /tmp/test.cache | head -2
   ```

2. Operar sobre el sistema de archivos raíz de un chroot o contenedor desde el host — la maniobra de rescate estándar:

   ```bash
   sudo ldconfig -r /mnt/broken-system
   ```

   Esto trata a `/mnt/broken-system` como `/`, leyendo su `/etc/ld.so.conf` y escribiendo su `/etc/ld.so.cache`.

3. Confirmar la versión de glibc de dos formas independientes:

   ```bash
   ldd --version | head -1
   getconf GNU_LIBC_VERSION
   /lib/x86_64-linux-gnu/libc.so.6
   ```

   Salida esperada:

   ```
   ldd (Debian GLIBC 2.36-9+deb12u7) 2.36
   glibc 2.36
   GNU C Library (Debian GLIBC 2.36-9+deb12u7) stable release version 2.36.
   ...
   ```

   > `libc.so.6` es uno de los raros objetos compartidos que además es directamente ejecutable.

4. Ubicar un shell *enlazado estáticamente* ahora, antes de necesitarlo:

   ```bash
   file /bin/busybox 2>/dev/null || echo "busybox not installed"
   file /usr/bin/sash 2>/dev/null || echo "sash not installed"
   ```

   Si no existe ninguno, instalá `busybox-static`. Una máquina cuyo enlace simbólico `libc.so.6` esté roto no puede ejecutar `ls`, `mv`, `ln`, ni `ldconfig` — todos ellos están enlazados dinámicamente.

5. Observar el caso no-glibc:

   ```bash
   docker run --rm alpine:3.20 sh -c 'ldconfig -p 2>&1 | head -2; ls /etc/ld-musl-x86_64.path; cat /etc/ld-musl-x86_64.path'
   ```

   Alpine usa **musl**, que no tiene `/etc/ld.so.cache` ni `/etc/ld.so.conf.d/`; la ruta de búsqueda es el único archivo `/etc/ld-musl-<arch>.path`.

### Verificá tu comprensión

- **Q9.1** — `ldconfig -r /mnt/broken-system` vs. `chroot /mnt/broken-system ldconfig`. ¿Qué puede hacer el primero que el segundo no?
- **Q9.2** — Un administrador ejecuta `mv /lib/x86_64-linux-gnu/libc.so.6 /tmp/` por SSH. La sesión sobrevive, pero todo comando nuevo falla. ¿Por qué el shell *existente* sigue funcionando, y cómo se recupera?
- **Q9.3** — ¿Por qué un shell enlazado estáticamente es la herramienta de rescate obligatoria ante una rotura de bibliotecas, y dónde encaja el initramfs?
- **Q9.4** — Estás depurando una imagen de contenedor construida `FROM alpine`. Tus notas dicen "ejecutar `ldconfig -p`". ¿Por qué falla ese consejo, y qué lo reemplaza?
- **Q9.5** — ¿Qué opción de `ldconfig` usarías para reconstruir la caché en una ubicación no predeterminada, para pruebas, sin tocar `/etc/ld.so.cache`?

---

## Referencia de comandos

| Comando | Propósito |
|---|---|
| `ldd <file>` | Imprime las dependencias de objetos compartidos (transitivas). Puede ejecutar el objetivo — archivos no confiables: usá `readelf`/`objdump`. |
| `ldd -r <file>` | También resuelve reubicaciones de datos y funciones; reporta símbolos indefinidos. |
| `ldd -v <file>` | Detallado: información de símbolos de versión. |
| `ldd --version` | Versión de glibc. |
| `ldconfig` | Reconstruye `/etc/ld.so.cache` y refresca los enlaces simbólicos de SONAME. Ejecutalo después de instalar cualquier biblioteca. |
| `ldconfig -p` | Imprime el contenido actual de la caché. **Consulta, nunca reconstruye.** |
| `ldconfig -v` | Detallado: muestra cada directorio y cada enlace simbólico creado. |
| `ldconfig -n <dir>` | Procesa solo `<dir>`; **no** reconstruye la caché, **no** recorre los directorios confiables. |
| `ldconfig -N` | No reconstruir la caché (solo enlaces simbólicos). |
| `ldconfig -X` | No actualizar los enlaces simbólicos (solo caché). |
| `ldconfig -f <conf>` | Usa `<conf>` en lugar de `/etc/ld.so.conf`. |
| `ldconfig -C <cache>` | Escribe en `<cache>` en lugar de `/etc/ld.so.cache`. |
| `ldconfig -r <root>` | Hace chroot a `<root>` primero — operación offline/de rescate. |
| `readelf -d <file>` | Sección dinámica: `NEEDED`, `SONAME`, `RPATH`, `RUNPATH`. Nunca ejecuta. |
| `objdump -p <file>` | La misma información, con otro formato. |
| `nm -D <lib>` | Tabla de símbolos dinámicos de un objeto compartido. |
| `file <file>` | `dynamically linked` vs `statically linked`; clase ELF y arquitectura. |

| Ruta / variable | Rol |
|---|---|
| `/etc/ld.so.conf` | Configuración de ruta de búsqueda de nivel superior; casi siempre solo una línea `include`. |
| `/etc/ld.so.conf.d/*.conf` | Un directorio por línea; donde los paquetes y los administradores agregan rutas. |
| `/etc/ld.so.cache` | Índice binario `SONAME → ruta`, generado por `ldconfig`. Nunca editarlo. |
| `/etc/ld.so.preload` | Lista de precarga para todo el sistema. Ausente por omisión; su presencia es una señal de alarma. |
| `LD_LIBRARY_PATH` | Directorios de búsqueda extra, separados por dos puntos. Por proceso, solo para depuración, ignorada para setuid. |
| `LD_PRELOAD` | Objetos cargados primero; sus símbolos tienen precedencia. |
| `LD_DEBUG=libs\|symbols\|bindings\|all` | Rastrea el comportamiento del cargador hacia stderr. |
| `LD_DEBUG_OUTPUT=<prefix>` | Envía ese rastro a `<prefix>.<pid>` en lugar de a stderr. |
| `LD_BIND_NOW=1` | Resuelve todos los símbolos al arranque en lugar de perezosamente. |
| `/lib`, `/usr/lib`, `/lib64`, `/usr/lib64` | Valores predeterminados confiables compilados dentro de `ld.so`. |
| `/usr/local/lib` | Ubicación FHS para bibliotecas compiladas localmente. |

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**A1.1** — El binario estático contiene una copia de cada rutina de libc que referencia (`puts`, más toda la maquinaria de arranque, locale y malloc arrastrada transitivamente) copiada desde `/usr/lib/x86_64-linux-gnu/libc.a` en tiempo de enlazado. El binario dinámico contiene solo *referencias*: la entrada `NEEDED` `libc.so.6` más los stubs de PLT/GOT. Se ejecuta porque el kernel, al ver la cabecera de programa `INTERP`, carga primero `/lib64/ld-linux-x86-64.so.2`; ese cargador mapea `libc.so.6` en el espacio de direcciones del proceso y arregla los stubs antes de transferir el control a `main`.

**A1.2** — No. Es la respuesta correcta y esperada para un binario estático: no hay dependencias en tiempo de ejecución que listar, así que no hay nada que `ldd` pueda reportar. `ldd` devuelve un estado de salida distinto de cero, pero el binario está sano.

**A1.3** — El **objeto compartido dinámico virtual** (virtual dynamic shared object). Es inyectado en cada proceso por el kernel, no leído del disco, así que no tiene archivo. Exporta implementaciones rápidas en espacio de usuario de unas pocas llamadas al sistema (`gettimeofday`, `clock_gettime`, `getcpu`) que evitan una transición a modo kernel. `ls -l` falla porque la ruta no existe en ningún sistema de archivos.

**A1.4** — Un `=>` significa "este SONAME fue resuelto a esa ruta mediante búsqueda". La ruta del propio cargador no se busca — está codificada como ruta absoluta en la cabecera de programa `INTERP` del ejecutable, así que `ldd` la imprime textualmente con solo su dirección de carga.

**A1.5** — Estático: sin dependencia en tiempo de ejecución de las versiones de bibliotecas del host, así que el binario es autocontenido e inmune al desfasaje de bibliotecas del tipo "funciona en mi máquina" — la razón por la que los binarios de Go y las herramientas de rescate se construyen así. Dinámico: un arreglo de seguridad en `libc` o `libssl` se aplica una vez, a un solo archivo, y todo proceso que se reinicie lo adopta — con enlazado estático hay que recompilar y redesplegar cada consumidor. El dinámico también permite que muchos procesos compartan una única copia de solo lectura de las páginas de texto de la biblioteca en la RAM física.

### Bloque 2

**A2.1** — Dos entradas `NEEDED` → 2 líneas (`libselinux.so.1`, `libc.so.6`). Más `linux-vdso.so.1` (inyectada por el kernel, no es una dependencia real). Más `/lib64/ld-linux-x86-64.so.2` (el propio intérprete). Más `libpcre2-8.so.0` — una dependencia *transitiva*, arrastrada por `libselinux.so.1`, no por `ls`. Total 5. `readelf` muestra las dependencias directas; `ldd` muestra la clausura completa.

**A2.2** — El `ldd` de glibc resuelve dependencias invocando al cargador dinámico sobre el objetivo, y en algunos caminos de código ejecuta el propio binario con variables de entorno especiales. Un archivo ELF manipulado puede por lo tanto ejecutar código arbitrario como vos, simplemente porque lo inspeccionaste. Usá `readelf -d` u `objdump -p`, que solo parsean el archivo.

**A2.3** — El SONAME es la cadena de identidad registrada *dentro* del `.so` (`DT_SONAME`) y normalmente es `lib<name>.so.<major>`. El nombre de archivo en disco es en general la versión completa, `lib<name>.so.<major>.<minor>.<patch>`. En tiempo de enlazado `ld` copia el **SONAME** de la dependencia — no su nombre de archivo — en la entrada `DT_NEEDED` del ejecutable. Esa indirección es lo que permite actualizar la versión menor de la biblioteca sin reenlazar nada.

**A2.4** — `@@` marca la versión *predeterminada* de un símbolo cuando existen múltiples definiciones versionadas (`@` marca una no predeterminada, de compatibilidad). `GLIBC_2.2.5` es el nodo de versión del símbolo. Esto es el versionado de símbolos de glibc: una única `libc.so.6` puede exportar varias implementaciones ABI-incompatibles del mismo nombre de función, de modo que los binarios compilados contra glibc viejo siguen funcionando mientras los binarios nuevos obtienen el comportamiento nuevo — sin necesidad de subir el SONAME.

**A2.5** — `$ORIGIN` es expandido por el cargador al directorio que contiene el objeto que se está cargando. Los proveedores lo usan para distribuir árboles relocalizables (`/opt/vendor/bin/app` encontrando `/opt/vendor/lib/`) que funcionan sin importar el prefijo de instalación y sin contaminar la ruta de búsqueda del sistema ni requerir `LD_LIBRARY_PATH`.

### Bloque 3

**A3.1** — Es una tabla hash binaria, diseñada para que el cargador la haga `mmap()` y la consulte en tiempo constante; parsear texto en cada `exec()` sería demasiado lento. Editarla con un editor corrompe la estructura; el cargador entonces fallará al encontrar bibliotecas en todo el sistema. La solución siempre es `ldconfig`, que la regenera desde `/etc/ld.so.conf*` y los directorios confiables.

**A3.2** — `-N` suprime la reconstrucción de la caché; `-X` suprime la actualización de los enlaces simbólicos. Juntas dejan a `ldconfig` sin nada que escribir, así que recorre los directorios configurados e informa lo que *haría* — una simulación genuina.

**A3.3** — A la izquierda está el **SONAME** (`libpcre2-8.so.0`), a la derecha el **nombre real** en disco (`libpcre2-8.so.0.11.2`). `ldconfig` creó ese enlace simbólico: lee `DT_SONAME` de cada `.so` que encuentra y enlaza el SONAME al archivo. El **nombre de enlazador** (`libpcre2-8.so`, sin versión) está ausente — viene del paquete `-dev`, no de `ldconfig`.

**A3.4** — Porque `/lib`, `/usr/lib`, `/lib64` y `/usr/lib64` son *directorios predeterminados confiables* compilados dentro de `ld.so` y siempre procesados por `ldconfig`. Listarlos en `ld.so.conf` sería redundante. Debian lista `/lib/x86_64-linux-gnu` explícitamente solo porque las rutas multiarch **no** están entre los valores predeterminados compilados.

**A3.5** —
```bash
echo /opt/acme/lib | sudo tee /etc/ld.so.conf.d/acme.conf
sudo ldconfig
```
Verificá con `ldconfig -p | grep acme`. Agregar un archivo bajo `/etc/ld.so.conf.d/` es preferible a editar `/etc/ld.so.conf` porque las actualizaciones de paquetes pueden reemplazar este último.

### Bloque 4

**A4.1** — `gcc -L. -lgreet` hizo que `ld` abriera `./libgreet.so`, que es una cadena de enlaces simbólicos hacia `libgreet.so.1.0.0`. `ld` leyó el campo `DT_SONAME` de ese archivo — `libgreet.so.1` — y escribió **esa cadena**, no la ruta ni el nombre de archivo, en el `DT_NEEDED` de `hello`. El nombre en tiempo de compilación y el nombre en tiempo de ejecución son deliberadamente distintos.

**A4.2** — El código de una biblioteca compartida se mapea en una dirección arbitraria que difiere por proceso, así que toda referencia interna debe ser relativa al contador de programa en lugar de absoluta; `-fPIC` le indica al compilador que genere ese código y que enrute el acceso a datos externos a través de la GOT. `main.c` se compila para un ejecutable — en las cadenas de herramientas modernas suele ser PIE por omisión de todas formas, pero no está sujeto a ser mapeado en una base impredecible por un *tercero*, así que la bandera no es obligatoria de tu parte.

**A4.3** — El directorio de trabajo actual no está en el orden de búsqueda del cargador. `.` no es `DT_RPATH`, no está en `LD_LIBRARY_PATH`, no está en `/etc/ld.so.cache`, y no es un valor predeterminado confiable. Esto es deliberado: si se buscara en `.`, dejar caer un `libc.so.6` malicioso en un directorio compartido secuestraría todo programa ejecutado desde ahí.

**A4.4** — `-n` restringe `ldconfig` exactamente a los directorios nombrados en la línea de comandos y, crucialmente, **no** reconstruye `/etc/ld.so.cache` ni procesa los directorios predeterminados confiables. Solo creó el enlace simbólico del SONAME `libgreet.so.1 → libgreet.so.1.0.0`. Un `ldconfig` a secas lee `/etc/ld.so.conf*` más los directorios confiables, crea enlaces simbólicos en todos ellos, y reescribe la caché.

**A4.5** — Sin `DT_SONAME`, `ld` recurre a registrar la *ruta que se le dio* — acá `libgreet.so`. `hello` dependería entonces del nombre de enlazador sin versión. Ese nombre pertenece al paquete de desarrollo y se reapunta en cada nueva versión mayor, así que el día en que `libgreet.so` empiece a apuntar al ABI v2, tu binario sin recompilar cargará silenciosamente código incompatible y se caerá o corromperá memoria. El SONAME existe precisamente para hacer eso imposible.

### Bloque 5

**A5.1** — `DT_RPATH` → `LD_LIBRARY_PATH` → `DT_RUNPATH` → `/etc/ld.so.cache` → valores predeterminados confiables (`/lib`, `/usr/lib`, `/lib64`, `/usr/lib64`). La condicional: **`DT_RPATH` se honra únicamente cuando `DT_RUNPATH` está ausente.** Si el objeto tiene `DT_RUNPATH`, `DT_RPATH` se ignora por completo — que es lo que hace que `RUNPATH` sea sobreescribible por `LD_LIBRARY_PATH` y `RPATH` no.

**A5.2** — El cargador aplica la misma búsqueda ordenada a *cada* nombre `NEEDED`. `LD_LIBRARY_PATH` va delante de la caché, así que el directorio del laboratorio se prueba primero también para `libc.so.6`. La línea `trying file=` que no encuentra nada es un fallo, y el cargador cae hacia `search cache=/etc/ld.so.cache`. Este es además el argumento de costo en contra de un `LD_LIBRARY_PATH` largo: cada entrada es un `stat()` fallido por cada biblioteca de cada proceso.

**A5.3** — `passwd` es set-user-ID root. Si `LD_LIBRARY_PATH` se honrara, cualquier usuario sin privilegios podría apuntarla a un directorio que contenga un `libc.so.6` (o `libcrypt.so.1`) hostil cuyo constructor ejecute `execve("/bin/sh")` — root instantáneo. glibc por lo tanto purga `LD_LIBRARY_PATH`, `LD_PRELOAD` (para rutas sin privilegios), `LD_AUDIT` y compañía cada vez que el proceso corre con privilegios elevados (`AT_SECURE` está activo en el vector auxiliar).

**A5.4** — (1) Se aplica globalmente a cada proceso de la máquina, así que puede tapar una biblioteca del sistema para software no relacionado — un `libssl.so.3` en `/opt/app/lib` va a ser cargado por cualquier cosa que inicie un shell de login. (2) Cuesta una búsqueda fallida por entrada, por biblioteca, por proceso. (3) Es frágil e invisible: no se aplica a los servicios iniciados por systemd (que no lee `/etc/profile`), así que la aplicación funciona interactivamente y falla como unidad — la peor firma de falla posible. La solución correcta es `/etc/ld.so.conf.d/app.conf` + `ldconfig`, o compilar la aplicación con `-Wl,-rpath,'$ORIGIN/../lib'` para que la dependencia quede registrada en el binario.

**A5.5** — `/b/libfoo.so.1`. `LD_LIBRARY_PATH` se busca antes que `/etc/ld.so.cache`, y dentro de `LD_LIBRARY_PATH` las entradas se prueban de izquierda a derecha — `/a` primero (fallo), después `/b` (acierto). La caché nunca se consulta.

### Bloque 6

**A6.1** — El `DT_NEEDED` de `hello` dice `libgreet.so.1`. La caché mapea ese SONAME a `/usr/local/lib/libgreet.so.1`. Esa ruta es un enlace simbólico, y `ldconfig` lo reapuntó de `libgreet.so.1.0.0` a `libgreet.so.1.1.0` porque el archivo nuevo también declara `DT_SONAME libgreet.so.1`. Cuatro nombres, una indirección cada uno: NEEDED → entrada de caché → enlace simbólico → archivo real.

**A6.2** — Resultado diseñado. `hello` pide el SONAME `libgreet.so.1`, y la cadena v1 sigue instalada y sigue siendo correcta para él. Si el desarrollador hubiera reutilizado el SONAME `libgreet.so.1` para el código v2, `ldconfig` habría reapuntado `libgreet.so.1` al archivo v2, y `hello` llamaría a una función de dos argumentos con un solo argumento en la pila — comportamiento indefinido, típicamente un contador de bucle basura o un segfault, sin ningún mensaje de error del cargador.

**A6.3** — `ldconfig` deriva sus enlaces simbólicos de `DT_SONAME`, y ninguna biblioteca declara un SONAME sin versión. El nombre de enlazador es un artefacto de *tiempo de compilación* sin significado en tiempo de ejecución, así que queda fuera del alcance de `ldconfig` por diseño — lo crea el paquete `-dev`/`-devel` (o `make install`). Sin él, `gcc -lgreet` falla con `cannot find -lgreet`; el tiempo de ejecución no se ve afectado.

**A6.4** — `libgreet.so.1.1.0`. Cuando varios archivos reclaman el mismo SONAME, `ldconfig` elige el que considera más nuevo comparando los sufijos de versión numéricamente, campo por campo — `1.1.0` le gana a `1.0.0`. No es la fecha de modificación ni el orden alfabético (alfabéticamente, `1.1.0` < `1.0.0` es falso, pero `1.10.0` vs `1.9.0` es exactamente donde un ordenamiento de cadenas daría la respuesta equivocada y la regla numérica te salva).

**A6.5** — OpenSSL 3.0 rompió el ABI con 1.1.x, así que el SONAME cambió de `libssl.so.1.1` a `libssl.so.3`. Como los SONAME difieren, los dos archivos no colisionan y ambos pueden estar instalados a la vez, permitiendo que los binarios viejos sigan funcionando durante una migración. Las distribuciones codifican esto en el nombre del paquete — Debian distribuye `libssl1.1` y `libssl3` como paquetes binarios separados y coinstalables, con un único `libssl-dev` que provee el nombre de enlazador (mutuamente excluyente). Esa convención de nombrado — el nombre del paquete lleva la versión mayor del SONAME — existe precisamente para que `dpkg`/`rpm` puedan expresar "estos dos no entran en conflicto".

### Bloque 7

**A7.1** — Faltaban: (1) el enlace simbólico del SONAME `/usr/local/lib/libgreet.so.1`, eliminado por la ejecución de `ldconfig` del paso 1 cuando su destino desapareció; (2) la entrada de caché que mapeaba `libgreet.so.1` a esa ruta. `sudo ldconfig` recreó ambas en una sola pasada. Esta es la causa real más común de "definitivamente instalé la biblioteca y sigue diciendo que no la encuentra".

**A7.2** — `cannot open shared object file` lo emite el **cargador dinámico antes de que se ejecute `main()`**: un objeto `NEEDED` completo no pudo localizarse en ninguna parte de la ruta de búsqueda. `undefined symbol` significa que el objeto *sí* fue encontrado y mapeado, pero un símbolo específico que referencia no existe en ningún objeto cargado — un desajuste de versión/ABI, no un archivo faltante. Con enlazado perezoso puede aflorar arbitrariamente tarde, en el momento de la primera llamada.

**A7.3** — El cargador encontró un archivo con el SONAME correcto pero la clase ELF equivocada: un objeto de 32 bits (`ELFCLASS32`) donde un proceso de 64 bits necesita `ELFCLASS64`. Normalmente una biblioteca de 32 bits fue a parar a una ruta de 64 bits, o `LD_LIBRARY_PATH` apunta a un árbol de 32 bits. Solución: instalar el paquete de la arquitectura correcta (`:i386` / `.i686` para consumidores genuinamente de 32 bits) y mantener los árboles separados — `/usr/lib32` vs `/usr/lib64`, o `i386-linux-gnu` vs `x86_64-linux-gnu` en Debian.

**A7.4** — El ABI y el tipo de máquina de esa entrada: `libc6` significa el ABI de glibc 2.x, `x86-64` la máquina. La caché contiene entradas de *todas* las arquitecturas instaladas a la vez, así que el cargador debe poder saltear las entradas que no puede usar — de lo contrario una `libfoo.so.1` de 32 bits satisfaría la búsqueda de un proceso de 64 bits y fallaría al mapearla.

**A7.5** — Por omisión glibc enlaza los símbolos de función de forma perezosa: la primera llamada a cada función pasa por la PLT y dispara la resolución en ese momento. Un símbolo que falta en un camino de código poco usado permanece por lo tanto invisible hasta que ese camino se ejecuta — posiblemente en producción, a las 03:00. `LD_BIND_NOW=1` (o enlazar con `-Wl,-z,now`) resuelve todo al arranque, convirtiendo eso en una falla de arranque inmediata y evidente. Lo querés para todo aquello donde una caída a mitad de una petición sea peor que una caída en el despliegue — y es un prerrequisito de endurecimiento para RELRO completo, ya que permite que la GOT quede de solo lectura después de la reubicación.

### Bloque 8

**A8.1** — Los objetos precargados se colocan al frente del alcance global de búsqueda de símbolos, por delante de todas las dependencias `NEEDED`, que es por lo que pueden interponerse. `ldd` los imprime en ese orden de alcance. No hay `=>` porque proporcionaste una ruta absoluta — el cargador no tuvo nada que buscar, exactamente igual que con la línea `INTERP`.

**A8.2** — `/etc/ld.so.preload` inyecta una biblioteca en *todo* proceso enlazado dinámicamente del sistema, incluidos los procesos iniciados por root. Es el mecanismo canónico de persistencia de un rootkit de espacio de usuario: el objeto precargado engancha `readdir`, `open` y `getdents` para ocultar archivos y procesos de `ls`, `ps` y `find`. Triaje: leé el archivo con una herramienta **enlazada estáticamente** (`busybox cat /etc/ld.so.preload`) para que el rootkit no pueda filtrar lo que ves, capturá el `.so` nombrado para análisis forense, y tratá al host como comprometido — no lo "limpies" en el lugar.

**A8.3** — `LD_PRELOAD` viene del *entorno del invocador sin privilegios*, así que honrarla en un binario setuid le entrega al atacante ejecución de código en un proceso privilegiado. `/etc/ld.so.preload` es un archivo propiedad de root — solo root puede escribirlo — así que su contenido ya es confiable al mismo nivel que los propios binarios. (glibc igualmente restringe qué bibliotecas puede precargar desde ahí un proceso en modo seguro: deben estar en los directorios confiables y, históricamente, ser setuid.) La asimetría es simplemente sobre quién controla la entrada.

**A8.4** — Cualquiera de: `libeatmydata` (anular `fsync` para acelerar suites de tests); `fakeroot` (interceptar `chown`/`stat` para que un usuario sin privilegios pueda construir paquetes); `libfaketime` (probar el comportamiento ante cambios de fecha); `jemalloc`/`tcmalloc` (cambiar el asignador de memoria sin recompilar); trazado de llamadas al estilo `ltrace`; inyectar un `gethostbyname` fijo en un arnés de pruebas; forzar un símbolo corregido de `libstdc++` dentro de un binario de un proveedor que no podés recompilar.

**A8.5** — Usá `dlsym(RTLD_NEXT, "greet")` (con `#define _GNU_SOURCE` y `-ldl` en glibc antiguo) para obtener la *siguiente* definición de `greet` en el alcance de búsqueda — es decir, la real — y después llamala tras registrar:

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

void greet(const char *who)
{
        static void (*real)(const char *);
        if (!real)
                real = dlsym(RTLD_NEXT, "greet");
        fprintf(stderr, "[trace] greet(\"%s\")\n", who);
        real(who);
}
```

`RTLD_NEXT` es lo que marca la diferencia entre un wrapper y un reemplazo.

### Bloque 9

**A9.1** — `ldconfig -r` hace el `chroot()` por sí mismo usando el binario `ldconfig` **del host** y las bibliotecas del host. `chroot /mnt/... ldconfig` requiere que el `/usr/sbin/ldconfig` del destino **y** cada biblioteca de la que ese binario dependa estén intactos dentro del chroot — que es precisamente lo que está roto en el escenario donde lo necesitás. `-r` también funciona cuando el destino es una distribución diferente o un sistema raíz parcialmente desempaquetado.

**A9.2** — El shell que ya está corriendo tiene `libc.so.6` mapeada en su espacio de direcciones; en Linux un inodo sigue vivo mientras esté mapeado o abierto, y `mv` dentro del mismo sistema de archivos solo cambia una entrada de directorio — el mapeo no se ve afectado. Todo `execve()` *nuevo* necesita abrir la ruta por nombre, y esa ruta ya no está. Recuperación: usar comandos internos del shell (`echo`, `cd`) y un binario enlazado estáticamente, por ejemplo `busybox mv /tmp/libc.so.6 /lib/x86_64-linux-gnu/`. Si no existe ninguna herramienta estática, reiniciar hacia el initramfs o un medio de rescate y reparar desde ahí. Esta es además la razón por la que `ldconfig` en Debian instala bibliotecas con `install`/renombrado atómico en lugar de borrar-y-copiar.

**A9.3** — Todo comando corriente — `ls`, `cp`, `mv`, `ln`, `ldconfig`, incluso `/bin/sh` — está enlazado dinámicamente contra `libc.so.6`. Si ese archivo falta, fue movido, o su enlace simbólico de SONAME está roto, ninguno de ellos puede arrancar, así que no podés usar el sistema para reparar el sistema. Un shell enlazado estáticamente (`busybox-static`, `sash`) lleva su propia libc y se ejecuta igual. El initramfs es la misma idea una capa más abajo: un raíz autocontenido con su propio `/lib` y un `busybox` estático o completamente provisto, que es por lo que arrancar a un prompt de rescate de initramfs funciona incluso cuando las bibliotecas del raíz real están destruidas.

**A9.4** — Alpine usa **musl**, no glibc. El cargador dinámico de musl (`/lib/ld-musl-x86_64.so.1`) no tiene archivo de caché en absoluto; no hay nada que `ldconfig` pueda construir, y el `ldconfig` de Alpine es un stub mínimo. La ruta de búsqueda es el archivo de texto plano `/etc/ld-musl-x86_64.path`, un directorio por línea, leído directamente en tiempo de carga. Reemplazá `ldconfig -p` por `cat /etc/ld-musl-x86_64.path`, y reemplazá `ldd` por `ldd` (el propio de musl, que es el cargador invocado como `ld-musl-x86_64.so.1 --list <file>`) o, mejor, `readelf -d`. Notá además que un binario compilado con glibc no va a ejecutarse en Alpine en absoluto — ruta de cargador distinta en `INTERP`, produciendo `no such file or directory` sobre un archivo que evidentemente existe.

**A9.5** — `ldconfig -C <file>`, por ejemplo `sudo ldconfig -C /tmp/test.cache`. Combinalo con `ldconfig -p -C /tmp/test.cache` para leerla de vuelta, y con `-f <conf>` si además querés probar un archivo de configuración alternativo sin tocar `/etc/ld.so.conf`.

</details>

---

## Fuentes

- LPI — *Exam 101-500 Objectives*, Tema 102.3 "Manage shared libraries": <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `ld.so(8)` — enlazador/cargador dinámico, orden de búsqueda y variables de entorno: <https://man7.org/linux/man-pages/man8/ld.so.8.html>
- `ldconfig(8)` — configurar los enlaces en tiempo de ejecución del enlazador dinámico: <https://man7.org/linux/man-pages/man8/ldconfig.8.html>
- `ldd(1)` — imprimir dependencias de objetos compartidos, incluida la nota de seguridad sobre la ejecución: <https://man7.org/linux/man-pages/man1/ldd.1.html>
- `dlopen(3)` / `dlsym(3)` — `RTLD_NEXT` y carga en tiempo de ejecución: <https://man7.org/linux/man-pages/man3/dlsym.3.html>
- Manual de la GNU C Library — *Dynamic Linker*: <https://www.gnu.org/software/libc/manual/html_node/Dynamic-Linker.html>
- Filesystem Hierarchy Standard 3.0, §3.8 `/lib`, §4.5 `/usr/lib`, §4.9 `/usr/local`: <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- Manual de GNU Libtool — *Library interface versions* (SONAME y política de versionado): <https://www.gnu.org/software/libtool/manual/html_node/Versioning.html>
- musl libc — enlazado dinámico y `/etc/ld-musl-$ARCH.path`: <https://wiki.musl-libc.org/functional-differences-from-glibc.html>