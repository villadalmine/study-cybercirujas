# 102.3 — Gestionar bibliotecas compartidas

> **Examen:** LPIC-1 / 102-500 · **Objetivo:** 102.3 · **Peso:** 1.56
> **Conocimientos clave:** identificar bibliotecas compartidas · identificar ubicaciones típicas de las bibliotecas del sistema · cargar bibliotecas compartidas
> **Archivos, términos y utilidades listados en el examen:** `ldd`, `ldconfig`, `/etc/ld.so.conf`, `LD_LIBRARY_PATH`

Este es un objetivo de bajo peso que acarrea una cantidad desproporcionada de dolor en producción. Casi todo incidente del tipo "el binario funciona en la máquina de build y muere en el pod", todo "parcheamos OpenSSL pero el escáner de CVE nos sigue marcando", y todo nodo GPU que deja de aceptar trabajo es, por debajo, un problema de resolución de bibliotecas compartidas. Tratá los cuatro ítems del examen como la superficie, y al cargador en tiempo de ejecución como el tema real.

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 Qué se gana con el enlazado dinámico, y qué cuesta

Un programa necesita código que no escribió: `printf`, `SSL_read`, `getaddrinfo`. Hay tres maneras de meterlo en el proceso.

1. **Enlazado estático** — copiar el código máquina dentro del ejecutable en tiempo de compilación.
2. **Enlazado dinámico** — registrar una *dependencia* en el ejecutable y dejar que un componente en tiempo de ejecución (`ld.so`, el *cargador dinámico* / *intérprete*) mapee la biblioteca en el momento de `execve()`.
3. **Carga en tiempo de ejecución** — el propio programa llama a `dlopen()` sobre una ruta que decide en ejecución (plugins, códecs, drivers).

El enlazado dinámico es el comportamiento por defecto en toda distribución Linux principal por cuatro propiedades que importan a escala de flota:

| Propiedad | Por qué importa en producción |
|---|---|
| **Un único punto de parcheo** | Un solo `libcrypto.so.3` en disco. Se parchea una vez y todo proceso que lo mapee *después de reiniciar* queda corregido. El enlazado estático implica recompilar y redesplegar cada consumidor. |
| **Compartición de memoria física** | El segmento de texto de solo lectura de un objeto compartido está respaldado por la page cache y se mapea con `MAP_PRIVATE` en cada proceso. 400 contenedores que usan glibc comparten *un solo* conjunto de páginas físicas para su `.text`. |
| **Desacoplamiento de ABI** | El contrato `SONAME` permite que una biblioteca publique correcciones (`1.2.3` → `1.2.4`) sin tocar a los consumidores. |
| **Enlace tardío del detalle de plataforma** | La misma imagen de contenedor puede enlazarse con un `libcuda.so.1` específico del host inyectado en el momento de crear el contenedor. Imposible con enlazado estático. |

El costo es que **el contrato de dependencias se resuelve en tiempo de ejecución, en el host destino, bajo el entorno del destino** — es decir, exactamente donde se tiene el menor control y la peor observabilidad. Un binario enlazado estáticamente que arranca en tu laptop arranca en todos lados. Uno enlazado dinámicamente es una promesa que tiene que honrar `ld.so` en una máquina en la que quizá nunca inicies sesión.

### 1.2 Los cuatro incidentes que este objetivo realmente previene

**Incidente A — el parche que no fue.** Aparece un CVE en `libssl3`. Se corre la actualización de paquetes, el RPM/DEB reemplaza el archivo en disco, el escáner reescanea el sistema de archivos e informa "limpio". Pero todo proceso de larga vida (`nginx`, `postgres`, la JVM) sigue teniendo mapeado el **inodo eliminado**: el kernel mantiene vivo el archivo viejo mientras un mapeo lo referencie. La flota sigue siendo vulnerable y todos los artefactos dicen que no. La detección es una cuestión de bibliotecas compartidas (`lsof +L1`, `needs-restarting -r`), no de paquetes.

**Incidente B — el despliegue con `GLIBC_2.38 not found`.** CI compila sobre `ubuntu:24.04` (glibc 2.39), la imagen de runtime es `debian:12` (glibc 2.36). La compilación tiene éxito, los tests unitarios pasan en la imagen de build, y el pod entra en `CrashLoopBackOff` con un error de una línea antes de que se ejecute una sola sentencia de log. La causa raíz es el **versionado de símbolos**: glibc garantiza compatibilidad hacia atrás, nunca hacia adelante.

**Incidente C — la biblioteca de terceros que ensombreció a la del sistema.** Un operador agrega `LD_LIBRARY_PATH=/opt/vendor/lib` a una unidad de systemd para satisfacer a un agente propietario. Ese directorio también contiene una `libstdc++.so.6` antiquísima. Cada proceso hijo que la unidad lanza ahora la hereda, y herramientas sin relación empiezan a fallar con errores de `undefined symbol`. `LD_LIBRARY_PATH` se hereda a través de `fork`/`exec` — no es una propiedad del binario, es una propiedad del *árbol de procesos*.

**Incidente D — los nodos GPU dejan de funcionar tras actualizar el driver.** El runtime de contenedores inyecta las bibliotecas del driver del host dentro del contenedor y ejecuta `ldconfig` allí. Si la imagen no tiene `ldconfig`, no tiene `/etc` escribible, o tiene un sistema de archivos raíz de solo lectura, `libcuda.so.1` está presente en disco pero no es resoluble, y todo pod CUDA falla con `cannot open shared object file`.

Los cuatro son la misma pregunta: **en el instante en que el proceso arranca, ¿qué archivo en disco satisface cada entrada `NEEDED`, y es ese el archivo que creés que es?**

---

## 2. Mecánica: qué ocurre entre `execve()` y `main()`

### 2.1 El kernel delega en el intérprete

Cuando se hace `execve()` sobre un archivo ELF, el kernel parsea las cabeceras de programa. Si encuentra una cabecera `PT_INTERP`, el kernel mapea **ese** archivo — el cargador dinámico — y le transfiere el control a él, no a tu `_start`.

```bash
$ readelf -l /usr/bin/curl | head -20

Elf file type is DYN (Position-Independent Executable file)
Entry point 0xa0c0
There are 13 program headers, starting at offset 64

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  PHDR           0x0000000000000040 0x0000000000000040 0x0000000000000040
                 0x00000000000002d8 0x00000000000002d8  R      0x8
  INTERP         0x0000000000000318 0x0000000000000318 0x0000000000000318
                 0x000000000000001c 0x000000000000001c  R      0x1
      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
  LOAD           0x0000000000000000 0x0000000000000000 0x0000000000000000
                 0x0000000000003000 0x0000000000003000  R      0x1000
```

Esa única línea — `Requesting program interpreter` — es toda la delegación. Si esa ruta no existe en el mount namespace, el kernel devuelve `ENOENT` y la shell imprime el célebremente engañoso:

```bash
$ ./app
bash: ./app: No such file or directory
$ ls -l ./app
-rwxr-xr-x 1 root root 16224 Aug 25 09:12 ./app
```

El archivo está justo ahí. Lo que falta es el *intérprete*. Este es el fallo canónico del "binario glibc en una imagen Alpine/scratch".

### 2.2 La sección `.dynamic` es el contrato de dependencias

Todo lo que el cargador necesita está en el segmento `PT_DYNAMIC`:

```bash
$ readelf -d /usr/bin/curl

Dynamic section at offset 0x1a2c8 contains 30 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libcurl.so.4]
 0x0000000000000001 (NEEDED)             Shared library: [libz.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]
 0x000000000000000c (INIT)               0x9000
 0x000000000000000d (FINI)               0x15a54
 0x0000000000000019 (INIT_ARRAY)         0x19c88
 0x000000000000001b (INIT_ARRAYSZ)       8 (bytes)
 0x0000000000000004 (HASH)               0x3a0
 0x000000006ffffef5 (GNU_HASH)           0x3d8
 0x0000000000000005 (STRTAB)             0x1178
 0x0000000000000006 (SYMTAB)             0x458
 0x000000000000000a (STRSZ)              1163 (bytes)
 0x0000000000000015 (DEBUG)              0x0
 0x0000000000000003 (PLTGOT)             0x1a4b8
 0x0000000000000002 (PLTRELSZ)           1032 (bytes)
 0x0000000000000014 (PLTREL)             RELA
 0x0000000000000017 (JMPREL)             0x2058
 0x000000006ffffffe (VERNEED)            0x1fd8
 0x000000006fffffff (VERNEEDNUM)         3
 0x000000006ffffff0 (VERSYM)             0x1ea4
 0x000000006ffffff9 (RELACOUNT)          3
 0x0000000000000000 (NULL)               0x0
```

Las etiquetas que deciden el comportamiento en tiempo de ejecución:

| Etiqueta | Significado |
|---|---|
| `NEEDED` | Una dependencia, registrada **por SONAME, no por ruta**. Por eso `libcurl.so.4` y no `/usr/lib/x86_64-linux-gnu/libcurl.so.4.8.0`. |
| `SONAME` | El nombre con el que *este* objeto se anuncia a sí mismo. Presente en bibliotecas, ausente en la mayoría de los ejecutables. |
| `RPATH` (legado) | Ruta de búsqueda embebida, consultada **antes** de `LD_LIBRARY_PATH`, y **heredada** por la búsqueda de dependencias transitivas. |
| `RUNPATH` (moderna) | Ruta de búsqueda embebida, consultada **después** de `LD_LIBRARY_PATH`, y que se aplica **solo a las dependencias directas de ese objeto**. |
| `VERNEED` / `VERSYM` | Requisitos de versión de símbolos — el origen de `version 'GLIBC_2.38' not found`. |
| `FLAGS_1: NOW` | Enlazar todo de forma anticipada al arrancar (ver §2.6). |

### 2.3 El esquema de tres nombres, y quién crea cada symlink

Una biblioteca compartida correctamente empaquetada existe bajo tres nombres:

```
libgreet.so.1.2.3   real file        "real name"       — the actual ELF object
libgreet.so.1       symlink          "soname"          — the runtime ABI contract
libgreet.so         symlink          "linker name"     — what `gcc -lgreet` resolves at build time
```

| Nombre | Creado por | Consumido por | Vive en |
|---|---|---|---|
| `libgreet.so.1.2.3` | `make install` / el paquete | nada directamente | paquete de runtime |
| `libgreet.so.1` | **`ldconfig`**, a partir del `SONAME` embebido | `ld.so` en tiempo de ejecución | paquete de runtime |
| `libgreet.so` | el empaquetador / `make install` — **nunca `ldconfig`** | `ld` (el enlazador GNU) en tiempo de compilación | paquete `-dev` / `-devel` |

El malentendido más común y cercano al examen es que `ldconfig` crea todos los symlinks. No lo hace. Crea **solo el enlace del SONAME**, y deriva el nombre de la cabecera ELF, no del nombre de archivo:

```bash
$ objdump -p /usr/local/lib/libgreet.so.1.2.3 | grep SONAME
  SONAME               libgreet.so.1
```

Por eso `ldconfig` puede estar *bien* mientras el nombre de archivo está *mal*, y por eso renombrar un archivo `.so` nunca cambia lo que el cargador busca.

### 2.4 El orden de búsqueda autoritativo

Para cada nombre `NEEDED` que **no contiene una barra**, el `ld.so` de glibc busca, en este orden exacto, y se detiene en la primera coincidencia:

| # | Fuente | Notas |
|---|---|---|
| 1 | `DT_RPATH` del objeto que carga, luego el de sus cargadores, de forma transitiva | **Se ignora por completo si ese objeto también tiene `DT_RUNPATH`.** |
| 2 | `LD_LIBRARY_PATH` | Separado por dos puntos. **Se ignora en modo de ejecución segura** (setuid/setgid/capabilities de archivo). |
| 3 | `DT_RUNPATH` del objeto que declara la dependencia | Solo dependencias directas — *no* se hereda a las transitivas. |
| 4 | `/etc/ld.so.cache` | El índice construido por `ldconfig`. Se omite con `-z nodefaultlib` o `--inhibit-cache`. |
| 5 | Directorios de confianza por defecto | `/lib`, `/usr/lib`, más `/lib64`, `/usr/lib64` en 64 bits. Se omiten con `-z nodefaultlib`. |

Si el nombre `NEEDED` *sí* contiene una barra, se usa literalmente como ruta (relativa al CWD si es relativa) y nada de lo anterior aplica.

Dentro de `RPATH`/`RUNPATH`/`LD_LIBRARY_PATH` se realizan dos expansiones:

- `$ORIGIN` — el directorio del objeto que se está cargando. La forma correcta de construir bundles de aplicación relocalizables.
- `$LIB` y `$PLATFORM` — se expanden a `lib`/`lib64` y a, por ejemplo, `x86_64`.

`$ORIGIN` se ignora en modo de ejecución segura para binarios setuid.

Por último, glibc ≥ 2.33 soporta subdirectorios **`glibc-hwcaps`** para despacho por microarquitectura: una biblioteca ubicada en `/usr/lib64/glibc-hwcaps/x86-64-v3/libfoo.so.1` se prefiere sobre `/usr/lib64/libfoo.so.1` en una CPU que soporta el nivel `x86-64-v3`. El mecanismo mucho más antiguo de "hwcaps legado" (`tls/`, `sse2/`, …) quedó obsoleto en 2.33 y fue **eliminado en glibc 2.37** — si heredás un sistema de build que instala en esos directorios, esas bibliotecas ahora son silenciosamente invisibles.

### 2.5 `/etc/ld.so.cache` — el índice, no la fuente de verdad

Recorrer cada directorio en cada arranque de proceso sería intolerable, así que `ldconfig` precalcula un índice binario.

```bash
$ file /etc/ld.so.cache
/etc/ld.so.cache: Linux-x86-64 ld.so cache 1.1, 64-bit, 1213 entries

$ ldconfig -p | head -6
1213 libs found in cache `/etc/ld.so.cache'
	libzstd.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libzstd.so.1
	libz.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libz.so.1
	libxml2.so.2 (libc6,x86-64) => /lib/x86_64-linux-gnu/libxml2.so.2
	libuuid.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libuuid.so.1
	libudev.so.1 (libc6,x86-64) => /lib/x86_64-linux-gnu/libudev.so.1
```

Leé las columnas: **SONAME**, **(flags de ABI, arquitectura)**, **ruta resuelta**. La etiqueta de arquitectura es la razón por la que una `libz.so.1` de 32 bits y otra de 64 bits pueden coexistir en una misma caché sin ambigüedad.

La caché es estado derivado. Sus entradas son:

```bash
$ cat /etc/ld.so.conf
include /etc/ld.so.conf.d/*.conf

$ ls /etc/ld.so.conf.d/
fakeroot-x86_64-linux-gnu.conf  libc.conf  x86_64-linux-gnu.conf  zz_i386-biarch.conf

$ cat /etc/ld.so.conf.d/x86_64-linux-gnu.conf
# Multiarch support
/usr/local/lib/x86_64-linux-gnu
/lib/x86_64-linux-gnu
/usr/lib/x86_64-linux-gnu
```

**`ldconfig` siempre escanea los directorios de confianza `/lib` y `/usr/lib` (y las variantes `lib64`) aunque no estén listados en ningún archivo de configuración.** Todo lo demás debe declararse.

Toda la regla operativa se reduce a: **editar `/etc/ld.so.conf.d/*.conf` no cambia nada hasta que se ejecuta `ldconfig`.** El archivo es la entrada; la caché es lo que el cargador lee.

### 2.6 Relocalización, enlace perezoso y endurecimiento

Las llamadas a funciones dentro de objetos compartidos pasan por la **PLT** (Procedure Linkage Table), cuyas entradas se respaldan en la **GOT** (Global Offset Table). Por defecto glibc enlaza de forma perezosa: la primera llamada a `SSL_read` salta al cargador, que resuelve el símbolo y parchea la GOT.

| Modo | Cómo | Costo de arranque | Momento del fallo | Seguridad |
|---|---|---|---|---|
| Perezoso (por defecto) | `DT_BIND_NOW` ausente | El más bajo | Un `undefined symbol` puede aparecer **horas después**, en una ruta de código poco transitada | La GOT queda escribible durante toda la vida del proceso |
| Anticipado | Variable de entorno `LD_BIND_NOW=1`, o enlazar con `-Wl,-z,now` | El más alto — cada símbolo se resuelve en el exec | **Todos** los símbolos faltantes salen a la luz al arrancar | Habilita Full RELRO: la GOT queda `mprotect`eada como solo lectura |

Para servicios en producción, **enlazá con `-Wl,-z,now -Wl,-z,relro`**. Convertís una clase de incidentes de las 3 de la mañana en una clase de fallos en tiempo de despliegue, y cerrás la primitiva de explotación de "sobrescribir una entrada de la GOT". Verificación:

```bash
$ readelf -d ./app | grep -E 'BIND_NOW|FLAGS'
 0x000000000000001e (FLAGS)              BIND_NOW
 0x000000006ffffffb (FLAGS_1)            Flags: NOW PIE

$ readelf -lW ./app | grep GNU_RELRO
  GNU_RELRO      0x00d000 0x000000000000d000 0x000000000000d000 0x000390 0x000390 R   0x1
```

### 2.7 Versionado de símbolos — por qué `libc.so.6` es la versión 6 desde 1997

glibc no incrementa su SONAME cuando agrega APIs nuevas. En cambio, cada símbolo exportado lleva un *nodo de versión*:

```bash
$ objdump -T /lib/x86_64-linux-gnu/libc.so.6 | grep -w 'memcpy\|clock_gettime'
0000000000098670 g    DF .text	000000000000000e  GLIBC_2.14  memcpy
000000000010c9f0 g    DF .text	0000000000000068  GLIBC_2.17  clock_gettime
00000000000d5c10 g    DF .text	0000000000000010 (GLIBC_2.2.5) memcpy
```

Un binario compilado contra glibc 2.39 registra entradas `VERNEED` que exigen, por ejemplo, `GLIBC_2.38`. Una `libc.so.6` más vieja sencillamente no define ese nodo, y el cargador se niega a arrancar el proceso. La compatibilidad hacia atrás está garantizada (`memcpy@GLIBC_2.2.5` sigue ahí para binarios de hace 20 años); la compatibilidad hacia adelante no lo está, y no puede estarlo.

Inspeccionar qué exige un binario:

```bash
$ readelf -V ./app | sed -n '/Version needs/,/^$/p'
Version needs section '.gnu.version_r' contains 2 entries:
 Addr: 0x0000000000000618  Offset: 0x000618  Link: 6 (.dynstr)
  000000: Version: 1  File: libc.so.6  Cnt: 3
  0x0010:   Name: GLIBC_2.38  Flags: none  Version: 4
  0x0020:   Name: GLIBC_2.14  Flags: none  Version: 3
  0x0030:   Name: GLIBC_2.2.5  Flags: none  Version: 2

$ objdump -p ./app | grep -A5 'required from libc'
  required from libc.so.6:
    0x09691974 0x00 04 GLIBC_2.38
    0x0d696914 0x00 03 GLIBC_2.14
    0x09691a75 0x00 02 GLIBC_2.2.5
```

El nodo de versión más alto de esa lista es tu **glibc mínima en tiempo de ejecución**. Extraelo en CI:

```bash
$ objdump -p ./app | awk '/GLIBC_/ {print $NF}' | sort -V | tail -1
GLIBC_2.38
```

### 2.8 `dlopen()` — el tercer modelo de enlazado

Los plugins evitan por completo las entradas `NEEDED`. `ldd` no los mostrará, la compuerta de dependencias de CI no los verá, y el fallo ocurre la primera vez que un usuario habilita la funcionalidad.

```c
void *h = dlopen("libfancycodec.so.2", RTLD_NOW | RTLD_LOCAL);
if (!h) { fprintf(stderr, "plugin load failed: %s\n", dlerror()); }
```

Operativamente: `dlopen()` sin barra pasa por el **mismo orden de búsqueda de cinco pasos**, así que `ld.so.conf.d` + `ldconfig` lo resuelve. Desde glibc 2.34, `libdl` está fusionada dentro de `libc` — `-ldl` es un stub sin efecto y `libdl.so.2` existe solo por compatibilidad. Auditá las dependencias de plugins con `strace`, nunca con `ldd`:

```bash
$ strace -f -e trace=openat -o /tmp/plug.log ./app --enable-fancy
$ grep -E 'lib.*\.so' /tmp/plug.log | grep -v ENOENT
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/usr/local/lib/libfancycodec.so.2", O_RDONLY|O_CLOEXEC) = 4
```

---

## 3. Comparativas técnicas y compromisos

### 3.1 Modelo de enlazado

| Dimensión | Estático (`-static`) | Dinámico (por defecto) | `dlopen()` |
|---|---|---|---|
| Parcheo de CVE | Recompilar + redesplegar cada consumidor | Reemplazar un archivo, reiniciar consumidores | Reemplazar un archivo, reiniciar o recargar |
| Latencia de arranque | La más rápida (sin cargador) | +1–15 ms típico; peor con muchos `NEEDED` | Diferida al primer uso |
| RSS con N procesos | N × tamaño de la biblioteca | ~1 × segmento de texto (compartido vía page cache) | ~1 × segmento de texto |
| Tamaño de imagen (contenedor) | Binario grande, imagen base vacía | Binario chico, imagen base con bibliotecas | Chico, pero hay que enviar los plugins |
| `getaddrinfo`/NSS | **Roto** — el NSS de glibc hace `dlopen` de los módulos igual | Funciona | Funciona |
| Detección de fallos en tiempo de despliegue | Total (el build falla o funciona) | Parcial (`NEEDED` verificable; versiones verificables) | **Ninguna** sin `strace`/tests |
| Exposición de licencias | El enlazado estático LGPL impone obligaciones de reenlazado | LGPL se satisface con enlazado dinámico | Igual que dinámico |
| Mejor encaje | Sidecars con imagen `scratch`, herramientas de initramfs, CLIs en Go/Rust | Todo sobre una distribución de propósito general | Códecs, drivers de BD, backends de GPU |

**Regla práctica:** glibc estática es una trampa — `getaddrinfo`, `getpwnam` y `gethostbyname` siguen necesitando `libnss_*.so` en tiempo de ejecución, y obtenés una advertencia en tiempo de compilación y un fallo silencioso de resolución en producción. Si querés un binario estático, usá musl o un lenguaje con su propio resolver.

### 3.2 Las cinco formas de apuntar el cargador a un directorio

| Mecanismo | Alcance | Persistencia | ¿Se honra para setuid? | Precedencia | Veredicto |
|---|---|---|---|---|---|
| `/etc/ld.so.conf.d/*.conf` + `ldconfig` | Todo el sistema, todos los procesos | Permanente, sobrevive al reinicio | Sí (vía la caché) | 4.º | **La respuesta correcta para bibliotecas instaladas por el sistema.** Propiedad de un paquete. |
| `DT_RUNPATH` (`-Wl,-rpath,'$ORIGIN/../lib'` ) | Este binario y sus dependencias directas | Horneada en el ELF | `$ORIGIN` se ignora | 3.º | **La respuesta correcta para bundles de aplicación autocontenidos.** Sin entorno, sin estado global. |
| `DT_RPATH` (`-Wl,--disable-new-dtags,-rpath,…`) | Este binario **y transitivamente** | Horneada en el ELF | `$ORIGIN` se ignora | 1.º | Legado. Anula a `LD_LIBRARY_PATH`, así que no se puede depurar rodeándolo. Evitar. |
| `LD_LIBRARY_PATH` | El proceso **y todos sus descendientes** | Hasta que la shell/unidad termine | **No** (se elimina) | 2.º | Solo para depuración y ejecuciones puntuales. Nunca en un archivo de unidad persistente. |
| Copiar la biblioteca a `/usr/lib` | Todo el sistema | Permanente | Sí | 5.º | Solo si un paquete es dueño del archivo. Los archivos copiados a mano rompen la siguiente actualización. |

El modo de fallo que se repite una y otra vez: **`LD_LIBRARY_PATH` puesto en `/etc/environment` o en un drop-in de systemd.** Lo hereda cada hijo, reordena silenciosamente la resolución para programas *sin relación*, y deja de funcionar en el instante en que un binario es setuid — produciendo "funciona como root, falla como el usuario del servicio", lo que manda a la gente por una vía de diagnóstico completamente equivocada.

### 3.3 `RPATH` vs `RUNPATH` en detalle

| | `DT_RPATH` | `DT_RUNPATH` |
|---|---|---|
| Flag del enlazador | `-Wl,--disable-new-dtags,-rpath,DIR` | `-Wl,--enable-new-dtags,-rpath,DIR` (por defecto en binutils moderno) |
| Posición en el orden de búsqueda | Antes de `LD_LIBRARY_PATH` | Después de `LD_LIBRARY_PATH` |
| Aplica a dependencias transitivas | **Sí** | **No** — cada objeto necesita el suyo |
| Anulable en tiempo de ejecución | No | Sí, con `LD_LIBRARY_PATH` |
| Estado | Obsoleto | Vigente |
| Coexistencia | Si están ambos, `RPATH` se **ignora** | — |

La regla de "sin herencia transitiva" de `RUNPATH` es la que sorprende a la gente: si `app` tiene `RUNPATH=$ORIGIN/../lib` y encuentra `libA.so.1` ahí, pero `libA.so.1` necesita `libB.so.1` en el mismo directorio, **`libB` no será encontrada** a menos que la propia `libA` lleve un `RUNPATH`. Arreglalo en tiempo de compilación para cada objeto del bundle, o volvé a `ld.so.conf.d`.

### 3.4 glibc vs musl — maquinaria completamente distinta

| | glibc | musl (Alpine) |
|---|---|---|
| Ruta del cargador | `/lib64/ld-linux-x86-64.so.2` | `/lib/ld-musl-x86_64.so.1` |
| Caché | `/etc/ld.so.cache`, construida por `ldconfig` | **Sin caché por defecto** |
| Configuración de rutas de búsqueda | `/etc/ld.so.conf` + `ld.so.conf.d` | `/etc/ld-musl-x86_64.path` (un directorio por línea) |
| `ldd` | Script envoltorio que define `LD_TRACE_LOADED_OBJECTS=1` | Symlink al cargador; `ldd` = `ld-musl-x86_64.so.1 --list` |
| `ldconfig` | Implementación completa | Provisto por `musl-utils`; limitado, sin semántica real de caché |
| Versionado de símbolos | Sí (nodos `GLIBC_2.x`) | **No** — espacio de nombres de símbolos plano |
| `LD_LIBRARY_PATH` | Soportado | Soportado |
| Consecuencia | Binario glibc en Alpine → `No such file or directory` | Binario musl en un host glibc → normalmente necesita el paquete `musl` |

`gcompat` en Alpine disimula el tema de la ruta del cargador, pero no implementa las versiones de símbolos de glibc; tratalo como un rodeo, no como una plataforma.

### 3.5 Herramientas de inspección — y cuáles son seguras con binarios no confiables

| Herramienta | Qué muestra | ¿Ejecuta el cargador? | ¿Segura con archivos no confiables? |
|---|---|---|---|
| `ldd BIN` | Resolución **recursiva** completa con rutas finales | **Sí** — ejecuta el cargador contra el objeto | **No.** Históricamente, con un binario manipulado con un `RUNPATH`/intérprete hostil, `ldd` podía ejecutar código. |
| `objdump -p BIN` | `NEEDED`, `SONAME`, `RPATH`, `RUNPATH`, versiones requeridas | No | Sí |
| `readelf -d BIN` | Lo mismo, la tabla `.dynamic` en crudo | No | Sí |
| `/lib64/ld-linux-x86-64.so.2 --list BIN` | Lo mismo que `ldd` | Sí | No |
| `lddtree BIN` (`pax-utils`) | Árbol recursivo, calculado estáticamente | No | Sí |
| `scanelf -n BIN` (`pax-utils`) | Lista de `NEEDED`, rápida, escaneable en masa | No | Sí |
| `nm -D --defined-only LIB` | Símbolos que la biblioteca **exporta** | No | Sí |
| `nm -D --undefined-only BIN` | Símbolos que el binario **necesita** | No | Sí |

Regla para respuesta a incidentes y para cualquier job de CI que toque artefactos que no compilaste vos: **`readelf -d` / `objdump -p`, nunca `ldd`.**

### 3.6 Opciones de `ldconfig` que importan

| Opción | Efecto | Cuándo la necesitás |
|---|---|---|
| *(ninguna)* | Reescanear todos los directorios configurados + de confianza, refrescar symlinks, reescribir la caché | Después de instalar una biblioteca |
| `-p`, `--print-cache` | Volcar la caché actual; **solo lee, no necesita root** | Verificación, diagnóstico |
| `-v`, `--verbose` | Imprimir cada directorio escaneado y cada enlace creado | Probar que un directorio efectivamente se está escaneando |
| `-n DIR…` | Procesar **solo** esos directorios, sin actualizar la caché, sin escanear los de confianza | Creación de symlinks en tiempo de build sobre un árbol de staging |
| `-N` | No reconstruir la caché (solo enlaces) | Poco frecuente |
| `-X` | No actualizar los enlaces (solo la caché) | Poco frecuente |
| `-r ROOT` | Hacer `chroot()` a ROOT primero | Construcción de imágenes, entornos de rescate, `debootstrap` |
| `-C CACHE` | Escribir un archivo de caché alternativo | Construir imágenes sin tocar el host |
| `-f CONF` | Usar un archivo de configuración alternativo en lugar de `/etc/ld.so.conf` | Builds con raíz cruzada |
| `--ignore-aux-cache` | Ignorar `/var/cache/ldconfig/aux-cache` | Cuando `ldconfig` inexplicablemente se saltea un archivo que cambió |

---

## 4. Infraestructura y manifiestos (completos, sin abreviar)

El siguiente conjunto construye una biblioteca correctamente versionada, la instala como corresponde, la expone a través de `ld.so.conf.d`, endurece el servicio consumidor y lleva todo el conjunto a Kubernetes. Cada archivo está completo y es sintácticamente válido.

### 4.1 La biblioteca en sí — `SONAME` correcto y versionado de símbolos

`src/greet.h`

```c
#ifndef GREET_H
#define GREET_H

#ifdef __cplusplus
extern "C" {
#endif

/* ABI GREET_1.0 */
const char *greet_message(void);

/* ABI GREET_1.1 — added, does not break GREET_1.0 consumers */
int greet_message_r(char *buf, unsigned long buflen);

#ifdef __cplusplus
}
#endif

#endif /* GREET_H */
```

`src/greet.c`

```c
#include <stdio.h>
#include <string.h>
#include "greet.h"

static const char *MSG = "hello from libgreet";

const char *greet_message(void)
{
    return MSG;
}

int greet_message_r(char *buf, unsigned long buflen)
{
    if (buf == NULL || buflen == 0)
        return -1;
    if (strlen(MSG) + 1 > buflen)
        return -1;
    memcpy(buf, MSG, strlen(MSG) + 1);
    return 0;
}
```

`src/libgreet.map` — el script de versiones. Todo lo que no esté listado es `local`, es decir, no se exporta. Esto es lo de mayor apalancamiento que se puede hacer por la estabilidad del ABI: impide que los helpers internos se conviertan en un contrato público accidental.

```
GREET_1.0 {
    global:
        greet_message;
    local:
        *;
};

GREET_1.1 {
    global:
        greet_message_r;
} GREET_1.0;
```

`Makefile`

```make
# Build a production-shaped shared library:
#   real name : libgreet.so.$(VERSION)
#   soname    : libgreet.so.$(ABI)
#   linkername: libgreet.so
ABI       := 1
VERSION   := 1.2.3
LIBNAME   := libgreet
REALNAME  := $(LIBNAME).so.$(VERSION)
SONAME    := $(LIBNAME).so.$(ABI)
LINKERNAME:= $(LIBNAME).so

PREFIX    ?= /usr/local
LIBDIR    ?= $(PREFIX)/lib
INCDIR    ?= $(PREFIX)/include
DESTDIR   ?=

CC        ?= gcc
CFLAGS    ?= -O2 -g -Wall -Wextra -Werror -fPIC -fvisibility=hidden
LDFLAGS   ?= -Wl,-z,relro -Wl,-z,now -Wl,--as-needed
LDFLAGS   += -Wl,-soname,$(SONAME)
LDFLAGS   += -Wl,--version-script=src/libgreet.map

OBJS      := src/greet.o

.PHONY: all clean install check-abi app

all: $(REALNAME) app

$(REALNAME): $(OBJS)
	$(CC) -shared $(CFLAGS) $(LDFLAGS) -o $@ $^
	ln -sf $(REALNAME) $(SONAME)
	ln -sf $(SONAME)   $(LINKERNAME)

# Consumer, built with an explicit RUNPATH so the bundle is relocatable.
app: src/main.c $(REALNAME)
	$(CC) $(CFLAGS) -o $@ $< -L. -lgreet \
	      -Wl,--enable-new-dtags -Wl,-rpath,'$$ORIGIN/../lib' \
	      -Wl,-z,relro -Wl,-z,now

install: all
	install -d $(DESTDIR)$(LIBDIR) $(DESTDIR)$(INCDIR)
	install -m 0644 $(REALNAME) $(DESTDIR)$(LIBDIR)/$(REALNAME)
	# ldconfig -n creates ONLY the soname link, from the ELF SONAME.
	ldconfig -n $(DESTDIR)$(LIBDIR)
	# The linker name is the packager's job, not ldconfig's.
	ln -sf $(REALNAME) $(DESTDIR)$(LIBDIR)/$(LINKERNAME)
	install -m 0644 src/greet.h $(DESTDIR)$(INCDIR)/greet.h

# Fails the build if the exported ABI changed incompatibly.
check-abi: $(REALNAME)
	abidiff --no-added-syms baseline/$(SONAME).abi $(REALNAME) || \
	  { echo "ABI BREAK: bump SONAME to $(LIBNAME).so.$$(( $(ABI) + 1 ))"; exit 1; }

clean:
	rm -f $(OBJS) $(REALNAME) $(SONAME) $(LINKERNAME) app
```

`src/main.c`

```c
#include <stdio.h>
#include "greet.h"

int main(void)
{
    char buf[64];
    printf("%s\n", greet_message());
    if (greet_message_r(buf, sizeof buf) == 0)
        printf("reentrant: %s\n", buf);
    return 0;
}
```

### 4.2 `/etc/ld.so.conf` y un fragmento propiedad del paquete

`/etc/ld.so.conf` — dejalo exactamente así. **No** agregues directorios acá; las actualizaciones de la distribución reemplazan el archivo.

```
include /etc/ld.so.conf.d/*.conf
```

`/etc/ld.so.conf.d/greet.conf` — este es el archivo del que tu paquete es dueño.

```
# libgreet runtime libraries.
# Owned by: greet-runtime package. Do not edit by hand.
# Any change here requires `ldconfig` to take effect.
/opt/greet/lib
```

Verificá que haya surtido efecto — nunca lo des por sentado:

```bash
$ sudo ldconfig
$ ldconfig -p | grep greet
	libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1
```

### 4.3 Unidad de systemd — sin `LD_LIBRARY_PATH`, resolución probada al arrancar

`/etc/systemd/system/greet-api.service`

```ini
[Unit]
Description=Greet API
Documentation=https://example.internal/greet
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=greet
Group=greet
WorkingDirectory=/opt/greet
ExecStart=/opt/greet/bin/greet-api --listen 0.0.0.0:8080

# Fail fast and loudly on a missing symbol instead of hours later on a cold path.
Environment=LD_BIND_NOW=1

# Prove every NEEDED entry resolves BEFORE we claim the service started.
# `ld.so --list` exits non-zero when anything is unresolved.
ExecStartPre=/lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api

Restart=on-failure
RestartSec=5s

# Hardening. Note: NoNewPrivileges + a setuid binary would strip LD_LIBRARY_PATH,
# which is one more reason this unit does not use it.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/greet
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

### 4.4 `Dockerfile` multi-etapa — una imagen distroless cuyas dependencias están probadas, no supuestas

`Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7

##############################################################################
# Stage 1 — build. Pinned to the SAME glibc generation as the runtime stage.
##############################################################################
FROM debian:12-slim AS build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        pkg-config \
        libssl-dev \
        pax-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile ./
COPY src/ ./src/

RUN make all VERSION=1.2.3 ABI=1
RUN make install DESTDIR=/staging PREFIX=/opt/greet
RUN install -D -m 0755 app /staging/opt/greet/bin/greet-api

##############################################################################
# Stage 2 — dependency closure. Compute exactly which shared objects are
# needed, statically (no ldd on the artifact), and copy only those.
##############################################################################
FROM build AS deps

# lddtree resolves the full recursive closure without executing the binary.
RUN set -eux; \
    mkdir -p /rootfs; \
    lddtree --copy-to-tree /rootfs /staging/opt/greet/bin/greet-api; \
    cp -a /staging/opt/greet /rootfs/opt/greet; \
    # The dynamic loader itself is not a NEEDED entry; copy it explicitly.
    install -D /lib64/ld-linux-x86-64.so.2 /rootfs/lib64/ld-linux-x86-64.so.2; \
    # NSS modules are dlopen()ed and therefore invisible to any NEEDED scan.
    for m in /lib/x86_64-linux-gnu/libnss_files.so.2 \
             /lib/x86_64-linux-gnu/libnss_dns.so.2; do \
        install -D "$m" "/rootfs${m}"; \
    done; \
    install -D /staging/opt/greet/lib/libgreet.so.1.2.3 /rootfs/opt/greet/lib/libgreet.so.1.2.3; \
    ln -sf libgreet.so.1.2.3 /rootfs/opt/greet/lib/libgreet.so.1

# Bake the cache at build time: the runtime image has no ldconfig and a
# read-only root filesystem, so this is the only chance to build it.
RUN set -eux; \
    mkdir -p /rootfs/etc/ld.so.conf.d /rootfs/var/cache/ldconfig; \
    printf '%s\n' 'include /etc/ld.so.conf.d/*.conf' > /rootfs/etc/ld.so.conf; \
    printf '%s\n' '/opt/greet/lib' > /rootfs/etc/ld.so.conf.d/greet.conf; \
    printf '%s\n' '/lib/x86_64-linux-gnu' '/usr/lib/x86_64-linux-gnu' \
        > /rootfs/etc/ld.so.conf.d/x86_64-linux-gnu.conf; \
    ldconfig -r /rootfs -v | tail -20

# Hard gate: refuse to produce an image whose dependencies do not resolve
# inside the assembled rootfs.
RUN set -eux; \
    chroot /rootfs /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api \
      | tee /tmp/closure.txt; \
    ! grep -q 'not found' /tmp/closure.txt

##############################################################################
# Stage 3 — runtime. No shell, no package manager, no ldconfig.
##############################################################################
FROM gcr.io/distroless/base-debian12:nonroot AS runtime

COPY --from=deps /rootfs/ /

USER nonroot:nonroot
WORKDIR /opt/greet

ENV LD_BIND_NOW=1
EXPOSE 8080

ENTRYPOINT ["/opt/greet/bin/greet-api"]
CMD ["--listen", "0.0.0.0:8080"]
```

### 4.5 Kubernetes — bibliotecas de terceros vía `initContainer`, con sistema de archivos raíz de solo lectura

Este es el patrón para el caso que no se puede evitar: una biblioteca de terceros que debe inyectarse en tiempo de ejecución y no puede hornearse en la imagen (licenciamiento, versión de driver por clúster, blobs de proveedor en entornos aislados).

`k8s/greet-api.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: greet
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: greet-ldconfig
  namespace: greet
  labels:
    app.kubernetes.io/name: greet-api
    app.kubernetes.io/component: runtime-linkage
data:
  # Mounted into the init container, which runs ldconfig against the
  # emptyDir so the main container gets a prebuilt cache on a read-only
  # root filesystem.
  ld.so.conf: |
    include /etc/ld.so.conf.d/*.conf
  greet.conf: |
    # Vendored runtime libraries, injected by the init container.
    /opt/vendor/lib
  x86_64-linux-gnu.conf: |
    /lib/x86_64-linux-gnu
    /usr/lib/x86_64-linux-gnu
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: greet-api
  namespace: greet
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: greet-api
  namespace: greet
  labels:
    app.kubernetes.io/name: greet-api
    app.kubernetes.io/version: "1.2.3"
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: greet-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: greet-api
        app.kubernetes.io/version: "1.2.3"
      annotations:
        # Force a rollout when the linkage config changes; a stale ld.so.cache
        # in a running pod is invisible until the next restart.
        checksum/ldconfig: "REPLACED-BY-CI-WITH-SHA256-OF-CONFIGMAP"
    spec:
      serviceAccountName: greet-api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        # 1. Copy the vendor blobs out of their delivery image into an
        #    emptyDir shared with the app container.
        - name: vendor-libs
          image: registry.example.internal/vendor/libfancy:4.7.1
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "==> copying vendor libraries"
              cp -av /dist/lib/. /opt/vendor/lib/
              echo "==> creating SONAME symlinks from ELF headers"
              # ldconfig -n: process ONLY this directory, do not touch a cache,
              # do not scan the trusted directories.
              ldconfig -n -v /opt/vendor/lib
              ls -l /opt/vendor/lib
          volumeMounts:
            - name: vendor-lib
              mountPath: /opt/vendor/lib
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { cpu: "200m", memory: "128Mi" }

        # 2. Build an ld.so.cache that covers both the image's own libraries
        #    and the vendored ones, and write it to a writable emptyDir. The
        #    app container mounts that single file over /etc/ld.so.cache.
        - name: build-ldcache
          image: registry.example.internal/greet/api:1.2.3-toolchain
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "==> assembling loader configuration"
              mkdir -p /work/etc/ld.so.conf.d /work/var/cache/ldconfig
              cp /config/ld.so.conf            /work/etc/ld.so.conf
              cp /config/greet.conf            /work/etc/ld.so.conf.d/greet.conf
              cp /config/x86_64-linux-gnu.conf /work/etc/ld.so.conf.d/x86_64-linux-gnu.conf

              echo "==> ldconfig against the assembled root"
              ldconfig -f /work/etc/ld.so.conf \
                       -C /work/etc/ld.so.cache \
                       -v /opt/vendor/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu

              echo "==> cache contents relevant to this app"
              ldconfig -C /work/etc/ld.so.cache -p | grep -E 'fancy|greet|ssl|crypto' || true

              echo "==> preflight: every NEEDED entry must resolve"
              LD_LIBRARY_PATH= \
              /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api > /tmp/closure.txt
              cat /tmp/closure.txt
              if grep -q 'not found' /tmp/closure.txt; then
                echo "FATAL: unresolved shared libraries; refusing to start" >&2
                exit 1
              fi
              cp /work/etc/ld.so.cache /ldcache/ld.so.cache
              echo "==> ok"
          env:
            # The toolchain image resolves against the vendored dir explicitly
            # for the preflight; the app container uses the baked cache instead.
            - name: LD_LIBRARY_PATH
              value: /opt/vendor/lib
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
            - name: vendor-lib
              mountPath: /opt/vendor/lib
              readOnly: true
            - name: workdir
              mountPath: /work
            - name: ldcache
              mountPath: /ldcache
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }

      containers:
        - name: greet-api
          image: registry.example.internal/greet/api:1.2.3
          imagePullPolicy: IfNotPresent
          args: ["--listen", "0.0.0.0:8080"]
          env:
            # Resolve every symbol at exec time: a missing symbol becomes a
            # CrashLoopBackOff during rollout, not a 500 at 03:00.
            - name: LD_BIND_NOW
              value: "1"
            # Deliberately NOT setting LD_LIBRARY_PATH: the baked ld.so.cache
            # covers /opt/vendor/lib, and an env var would leak into every
            # child process this container ever spawns.
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          volumeMounts:
            - name: vendor-lib
              mountPath: /opt/vendor/lib
              readOnly: true
            # Single-file mount: replaces the image's cache without needing a
            # writable /etc.
            - name: ldcache
              mountPath: /etc/ld.so.cache
              subPath: ld.so.cache
              readOnly: true
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "250m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }

      volumes:
        - name: config
          configMap:
            name: greet-ldconfig
            defaultMode: 0444
        - name: vendor-lib
          emptyDir:
            medium: Memory
            sizeLimit: 256Mi
        - name: ldcache
          emptyDir:
            sizeLimit: 8Mi
        - name: workdir
          emptyDir:
            sizeLimit: 32Mi
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: greet-api
  namespace: greet
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: greet-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

Por qué esta forma y no `LD_LIBRARY_PATH` en el contenedor:

| Enfoque | Rootfs de solo lectura | Se filtra a procesos hijos | Funciona con `dlopen` | Sobrevive a la reconstrucción de la imagen |
|---|---|---|---|---|
| `env: LD_LIBRARY_PATH` | Sí | **Sí** | Sí | Sí |
| `initContainer` + caché horneada + montaje `subPath` | Sí | **No** | Sí | Sí |
| `ldconfig` en el entrypoint | **No** — necesita `/etc` escribible | No | Sí | Sí |
| Hornear las bibliotecas en la imagen | Sí | No | Sí | Requiere reconstruir por cada versión del proveedor |

### 4.6 Ansible — instalación declarativa de bibliotecas para flotas de VMs

`roles/shared-libs/tasks/main.yml`

```yaml
---
- name: Ensure the vendor library directory exists
  ansible.builtin.file:
    path: "{{ greet_vendor_libdir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Install versioned shared objects
  ansible.builtin.copy:
    src: "files/{{ item }}"
    dest: "{{ greet_vendor_libdir }}/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ greet_vendor_libs }}"
  notify: run ldconfig

- name: Declare the directory to the dynamic loader
  ansible.builtin.copy:
    dest: /etc/ld.so.conf.d/greet.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible (role: shared-libs). Do not edit.
      # A change here is inert until ldconfig runs.
      {{ greet_vendor_libdir }}
  notify: run ldconfig

- name: Flush handlers so verification runs against a fresh cache
  ansible.builtin.meta: flush_handlers

- name: Verify each SONAME resolves through the cache
  ansible.builtin.command:
    argv: ["ldconfig", "-p"]
  register: greet_ldcache
  changed_when: false

- name: Fail if a required SONAME is absent from the cache
  ansible.builtin.assert:
    that:
      - greet_ldcache.stdout is search(item)
    fail_msg: >-
      {{ item }} is not in /etc/ld.so.cache. Check that the file carries the
      expected SONAME (objdump -p) and that {{ greet_vendor_libdir }} is listed
      in /etc/ld.so.conf.d/.
    success_msg: "{{ item }} resolves through the loader cache."
  loop: "{{ greet_required_sonames }}"

- name: Verify the application binary has no unresolved dependencies
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      {{ greet_loader }} --list {{ greet_binary }} | grep -c 'not found' || true
    executable: /bin/bash
  register: greet_unresolved
  changed_when: false
  failed_when: greet_unresolved.stdout | trim | int > 0

- name: Report processes still mapping deleted library files
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      lsof +L1 2>/dev/null | awk '$0 ~ /\.so/ {print $1, $2, $NF}' | sort -u
    executable: /bin/bash
  register: greet_stale_maps
  changed_when: false
  failed_when: false

- name: Warn about processes that must be restarted to pick up patched libraries
  ansible.builtin.debug:
    msg: >-
      Processes still mapping deleted shared objects (restart required):
      {{ greet_stale_maps.stdout_lines }}
  when: greet_stale_maps.stdout_lines | length > 0
```

`roles/shared-libs/handlers/main.yml`

```yaml
---
- name: run ldconfig
  ansible.builtin.command:
    argv: ["ldconfig"]
  changed_when: true
```

`roles/shared-libs/defaults/main.yml`

```yaml
---
greet_vendor_libdir: /opt/greet/lib
greet_loader: /lib64/ld-linux-x86-64.so.2
greet_binary: /opt/greet/bin/greet-api
greet_vendor_libs:
  - libgreet.so.1.2.3
  - libfancycodec.so.2.4.0
greet_required_sonames:
  - libgreet.so.1
  - libfancycodec.so.2
```

### 4.7 Compuerta de CI — el script que convierte fallos de ejecución en fallos de compilación

`scripts/check-so-deps.sh`

```bash
#!/usr/bin/env bash
#
# Static shared-library gate. Runs against an ELF artifact WITHOUT executing
# it (no ldd), so it is safe on third-party binaries and in cross-builds.
#
#   check-so-deps.sh <binary> [max_glibc_version]
#
# Exit codes: 0 ok · 1 unresolved dependency · 2 glibc too new · 3 usage
set -euo pipefail

BIN=${1:?usage: check-so-deps.sh <binary> [max_glibc_version]}
MAX_GLIBC=${2:-2.36}

[[ -f $BIN ]] || { echo "no such file: $BIN" >&2; exit 3; }

echo "== artifact =================================================="
file "$BIN"

echo
echo "== interpreter ==============================================="
INTERP=$(readelf -lW "$BIN" | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p')
if [[ -z $INTERP ]]; then
    echo "statically linked (no PT_INTERP)"
else
    echo "$INTERP"
    [[ -e $INTERP ]] || { echo "FATAL: interpreter missing on this host" >&2; exit 1; }
fi

echo
echo "== declared dependencies (NEEDED) ============================"
mapfile -t NEEDED < <(objdump -p "$BIN" | awk '/NEEDED/ {print $2}')
printf '  %s\n' "${NEEDED[@]:-<none>}"

echo
echo "== embedded search paths ====================================="
objdump -p "$BIN" | awk '/RPATH|RUNPATH/ {print "  " $1 " = " $2}' || echo "  <none>"
if objdump -p "$BIN" | grep -q 'RPATH'; then
    echo "  WARNING: DT_RPATH is deprecated and cannot be overridden at runtime."
fi

echo
echo "== resolution ================================================"
rc=0
for so in "${NEEDED[@]:-}"; do
    [[ -n $so ]] || continue
    path=$(ldconfig -p | awk -v s="$so" '$1 == s {print $NF; exit}')
    if [[ -n $path && -e $path ]]; then
        printf '  %-28s -> %s\n' "$so" "$path"
    else
        printf '  %-28s -> NOT FOUND IN CACHE\n' "$so"
        rc=1
    fi
done

echo
echo "== minimum glibc required ===================================="
REQ=$(objdump -p "$BIN" | awk '/GLIBC_[0-9]/ {print $NF}' | tr -d '()' | sort -V | tail -1)
REQ=${REQ#GLIBC_}
if [[ -n $REQ ]]; then
    echo "  requires GLIBC_$REQ   (policy ceiling: $MAX_GLIBC)"
    if [[ $(printf '%s\n%s\n' "$REQ" "$MAX_GLIBC" | sort -V | tail -1) != "$MAX_GLIBC" ]]; then
        echo "  FATAL: artifact demands a newer glibc than the runtime image ships." >&2
        exit 2
    fi
else
    echo "  no versioned glibc symbols"
fi

echo
echo "== undefined symbols (informational) ========================="
nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print "  " $NF}' | head -20 || true

echo
if (( rc == 0 )); then echo "RESULT: ok"; else echo "RESULT: unresolved dependencies" >&2; fi
exit "$rc"
```

Ejecutalo:

```bash
$ ./scripts/check-so-deps.sh /opt/greet/bin/greet-api 2.36
== artifact ==================================================
/opt/greet/bin/greet-api: ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, BuildID[sha1]=3f2a...c91, for GNU/Linux 3.2.0, not stripped

== interpreter ===============================================
/lib64/ld-linux-x86-64.so.2

== declared dependencies (NEEDED) ============================
  libgreet.so.1
  libssl.so.3
  libcrypto.so.3
  libc.so.6

== embedded search paths =====================================
  RUNPATH = [$ORIGIN/../lib]

== resolution ================================================
  libgreet.so.1                -> /opt/greet/lib/libgreet.so.1
  libssl.so.3                  -> /lib/x86_64-linux-gnu/libssl.so.3
  libcrypto.so.3               -> /lib/x86_64-linux-gnu/libcrypto.so.3
  libc.so.6                    -> /lib/x86_64-linux-gnu/libc.so.6

== minimum glibc required ====================================
  requires GLIBC_2.34   (policy ceiling: 2.36)

== undefined symbols (informational) =========================
  SSL_read
  SSL_write
  greet_message
  __libc_start_main
  printf

RESULT: ok
```

---

## 5. Sesión de referencia de CLI — verificación y diagnóstico

### 5.1 Identificar una biblioteca compartida y su identidad

```bash
$ file /usr/lib/x86_64-linux-gnu/libssl.so.3
/usr/lib/x86_64-linux-gnu/libssl.so.3: ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked, BuildID[sha1]=8c2e1d94a1f0b7c3e5d2a9f0c1b8e7d6a5f4c3b2, stripped

$ objdump -p /usr/lib/x86_64-linux-gnu/libssl.so.3 | grep -E 'SONAME|NEEDED'
  NEEDED               libcrypto.so.3
  NEEDED               libc.so.6
  SONAME               libssl.so.3

$ ls -l /usr/lib/x86_64-linux-gnu/libssl.so*
lrwxrwxrwx 1 root root      15 Jun  4 11:02 /usr/lib/x86_64-linux-gnu/libssl.so -> libssl.so.3
-rw-r--r-- 1 root root  668992 Jun  4 11:02 /usr/lib/x86_64-linux-gnu/libssl.so.3
```

Qué paquete es su dueño — confirmalo siempre antes de tocar una biblioteca del sistema:

```bash
# Debian/Ubuntu
$ dpkg -S /usr/lib/x86_64-linux-gnu/libssl.so.3
libssl3:amd64: /usr/lib/x86_64-linux-gnu/libssl.so.3

# RHEL/Fedora/SUSE
$ rpm -qf /usr/lib64/libssl.so.3
openssl-libs-3.2.2-6.el9.x86_64
```

### 5.2 `ldd` — resolución recursiva completa

```bash
$ ldd /usr/bin/curl
	linux-vdso.so.1 (0x00007ffd4f5f8000)
	libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4 (0x00007f2a3c1e0000)
	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f2a3c1c4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2a3bc00000)
	libnghttp2.so.14 => /lib/x86_64-linux-gnu/libnghttp2.so.14 (0x00007f2a3c197000)
	libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3 (0x00007f2a3c0f3000)
	libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3 (0x00007f2a3b800000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f2a3c227000)
```

Tres formas de línea, tres significados:

| Línea | Significado |
|---|---|
| `linux-vdso.so.1 (0x…)` | El **vDSO** — un objeto virtual provisto por el kernel, no un archivo. No tiene ruta y nunca la tendrá. No es un problema. |
| `libc.so.6 => /lib/… (0x…)` | Resuelta. La ruta es el archivo que el cargador va a mapear. |
| `/lib64/ld-linux-x86-64.so.2 (0x…)` | El intérprete en sí, listado sin `=>`. |
| `libfoo.so.1 => not found` | **El fallo que estás buscando.** |

Entradas no dinámicas:

```bash
$ ldd /bin/sh
	linux-vdso.so.1 (0x00007ffc2f7f4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8b2ec00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f8b2ee3f000)

$ ldd /usr/bin/busybox-static
	not a dynamic executable

$ ldd ./go-binary
	statically linked

$ ldd /etc/passwd
	not a dynamic executable
```

El equivalente seguro, que no ejecuta nada — notá la forma de salida *idéntica*:

```bash
$ /lib64/ld-linux-x86-64.so.2 --list /usr/bin/curl | head -4
	linux-vdso.so.1 (0x00007ffd94dfd000)
	libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4 (0x00007f11c81e0000)
	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f11c81c4000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f11c7c00000)
```

Esto sigue ejecutando el cargador. La opción genuinamente estática:

```bash
$ lddtree /usr/bin/curl
curl => /usr/bin/curl (interpreter => /lib64/ld-linux-x86-64.so.2)
    libcurl.so.4 => /lib/x86_64-linux-gnu/libcurl.so.4
        libnghttp2.so.14 => /lib/x86_64-linux-gnu/libnghttp2.so.14
        libssl.so.3 => /lib/x86_64-linux-gnu/libssl.so.3
        libcrypto.so.3 => /lib/x86_64-linux-gnu/libcrypto.so.3
    libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1
    libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
```

### 5.3 `ldconfig` — inspeccionar, reconstruir, probar

```bash
# Read the cache. No root needed.
$ ldconfig -p | wc -l
1214

$ ldconfig -p | grep -w libssl.so.3
	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3

# Install a new library and watch the cache stay stale.
$ sudo install -m 0644 libgreet.so.1.2.3 /opt/greet/lib/
$ ldconfig -p | grep greet
$ echo $?
1

# Declare the directory...
$ echo /opt/greet/lib | sudo tee /etc/ld.so.conf.d/greet.conf
/opt/greet/lib

# ...still stale. The config file is not consulted at process start.
$ ldconfig -p | grep greet
$ echo $?
1

# Rebuild. This is the step people forget.
$ sudo ldconfig

$ ldconfig -p | grep greet
	libgreet.so.1 (libc6,x86-64) => /opt/greet/lib/libgreet.so.1

# ldconfig created the SONAME symlink from the ELF header:
$ ls -l /opt/greet/lib/
total 24
lrwxrwxrwx 1 root root    17 Aug 25 09:41 libgreet.so.1 -> libgreet.so.1.2.3
-rw-r--r-- 1 root root 16408 Aug 25 09:40 libgreet.so.1.2.3
```

El modo verboso es la manera de probar que un directorio se está escaneando siquiera:

```bash
$ sudo ldconfig -v 2>/dev/null | grep -A3 '^/opt/greet/lib'
/opt/greet/lib:
	libgreet.so.1 -> libgreet.so.1.2.3 (changed)

$ sudo ldconfig -v 2>/dev/null | grep '^/' | head
/usr/local/lib:
/lib/x86_64-linux-gnu:
/usr/lib/x86_64-linux-gnu:
/opt/greet/lib:
/lib32:
/usr/lib32:
/lib:
/usr/lib:
```

Si un directorio que configuraste no aparece en esa lista, el archivo `.conf` no se está leyendo — verificá que el nombre de archivo termine en `.conf` y que `/etc/ld.so.conf` todavía tenga su línea `include`.

Modo no invasivo para árboles de compilación (sin escritura de caché, sin escaneo de directorios de confianza):

```bash
$ ldconfig -n -v /staging/usr/local/lib
/staging/usr/local/lib:
	libgreet.so.1 -> libgreet.so.1.2.3
```

Modo chroot para construcción de imágenes:

```bash
$ sudo ldconfig -r /rootfs -v | tail -5
/rootfs/usr/lib/x86_64-linux-gnu:
	libcrypto.so.3 -> libcrypto.so.3
	libssl.so.3 -> libssl.so.3
/rootfs/opt/greet/lib:
	libgreet.so.1 -> libgreet.so.1.2.3
```

### 5.4 `LD_LIBRARY_PATH` — la herramienta de depuración, no el mecanismo de despliegue

```bash
$ ./app
./app: error while loading shared libraries: libgreet.so.1: cannot open shared object file: No such file or directory

# Prove the hypothesis in one command, without touching system state:
$ LD_LIBRARY_PATH=/opt/greet/lib ./app
hello from libgreet
reentrant: hello from libgreet
```

Confirmado. Ahora hacelo permanente de la forma correcta (`ld.so.conf.d` + `ldconfig`), y demostremos por qué la variable de entorno no es ese mecanismo:

```bash
# It leaks to every descendant:
$ export LD_LIBRARY_PATH=/opt/greet/lib
$ bash -c 'echo "child sees: $LD_LIBRARY_PATH"'
child sees: /opt/greet/lib

# It is stripped for setuid binaries (secure-execution mode):
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar 23 12:04 /usr/bin/passwd

$ LD_LIBRARY_PATH=/tmp/evil LD_DEBUG=libs /usr/bin/passwd --help 2>&1 | grep -c '/tmp/evil'
0

# An empty element means "current directory" — a classic privilege-escalation vector:
$ echo "$LD_LIBRARY_PATH"
/opt/greet/lib:
#                ^ trailing colon == "." — never do this
$ unset LD_LIBRARY_PATH
```

### 5.5 `LD_DEBUG` — la traza del propio cargador

Este es el diagnóstico de mayor valor de todo el objetivo y no figura en ninguna lista de objetivos del examen. Imprime exactamente qué rutas intentó el cargador y en qué orden.

```bash
$ LD_DEBUG=help ./app
Valid options for the LD_DEBUG environment variable are:

  libs        display library search paths
  reloc       display relocation processing
  files       display progress for input file
  symbols     display symbol table processing
  bindings    display information about symbol binding
  versions    display version dependencies
  scopes      display scope information
  all         all previous options combined
  statistics  display relocation statistics
  unused      determine unused DSOs
  help        display this help message and exit

To direct the debugging output into a file instead of standard output
a filename can be specified using the LD_DEBUG_OUTPUT environment variable.
```

Trazar la resolución de un binario que falla:

```bash
$ LD_DEBUG=libs ./app 2>&1 | head -30
    294817:	find library=libgreet.so.1 [0]; searching
    294817:	 search path=/opt/greet/bin/../lib		(RUNPATH from file ./app)
    294817:	  trying file=/opt/greet/bin/../lib/libgreet.so.1
    294817:	 search cache=/etc/ld.so.cache
    294817:	 search path=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib		(system search path)
    294817:	  trying file=/lib/x86_64-linux-gnu/libgreet.so.1
    294817:	  trying file=/usr/lib/x86_64-linux-gnu/libgreet.so.1
    294817:	  trying file=/lib/libgreet.so.1
    294817:	  trying file=/usr/lib/libgreet.so.1
    294817:
    294817:	find library=libc.so.6 [0]; searching
    294817:	 search path=/opt/greet/bin/../lib		(RUNPATH from file ./app)
    294817:	  trying file=/opt/greet/bin/../lib/libc.so.6
    294817:	 search cache=/etc/ld.so.cache
    294817:	  trying file=/lib/x86_64-linux-gnu/libc.so.6
    294817:
./app: error while loading shared libraries: libgreet.so.1: cannot open shared object file: No such file or directory
```

Leé esa traza como una lista de verificación: `RUNPATH` intentado y fallido → caché consultada y fallida → cuatro directorios por defecto intentados y fallidos. Esa es una respuesta completa e inequívoca a "dónde buscó".

Encontrar bibliotecas contra las que enlazás pero nunca llamás — reducción real del tamaño de imagen y de la superficie de ataque:

```bash
$ LD_DEBUG=unused ./app 2>&1 | grep unused
    294903:	/lib/x86_64-linux-gnu/libm.so.6: unused direct dependency
```

Se corrige recompilando con `-Wl,--as-needed` (ya presente en el `Makefile` de arriba).

Medición del costo de arranque:

```bash
$ LD_DEBUG=statistics ./app 2>&1 | grep -E 'total startup|relocation'
    294941:	  total startup time in dynamic loader: 1421953 cycles
    294941:		    time needed for relocation: 892401 cycles (62.7%)
    294941:		   number of relocations: 1874
    294941:		number of relative relocations: 3921
    294941:	       time needed to load objects: 421077 cycles (29.6%)
```

### 5.6 `strace` — la verdad de fondo

Cuando `LD_DEBUG` no está disponible (el modo de ejecución segura lo elimina), `strace` igual muestra cada sondeo:

```bash
$ strace -e trace=openat,stat ./app 2>&1 | grep -E 'greet|ld.so'
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/opt/greet/bin/../lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/usr/lib/x86_64-linux-gnu/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/usr/lib/libgreet.so.1", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
```

### 5.7 Qué mapeó realmente un proceso vivo

`ldd` dice qué *se cargaría*. `/proc/<pid>/maps` dice qué *se cargó*.

```bash
$ pgrep -x nginx
2181
2182

$ awk '/\.so/ {print $6}' /proc/2181/maps | sort -u
/usr/lib/x86_64-linux-gnu/libcrypt.so.1
/usr/lib/x86_64-linux-gnu/libc.so.6
/usr/lib/x86_64-linux-gnu/libcrypto.so.3
/usr/lib/x86_64-linux-gnu/libpcre2-8.so.0
/usr/lib/x86_64-linux-gnu/libssl.so.3
/usr/lib/x86_64-linux-gnu/libz.so.1
/usr/lib64/ld-linux-x86-64.so.2
```

La comprobación de **mapeos eliminados** — este es el Incidente A de §1.2:

```bash
$ sudo apt-get install -y --only-upgrade libssl3
...
Setting up libssl3:amd64 (3.0.15-1~deb12u1) ...

$ grep -c 'deleted' /proc/2181/maps
2

$ grep 'deleted' /proc/2181/maps
7f3c2a400000-7f3c2a460000 r--p 00000000 fd:01 1180337  /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (deleted)
7f3c2a460000-7f3c2a9c8000 r-xp 00060000 fd:01 1180337  /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (deleted)

# Fleet-wide, in one command:
$ sudo lsof +L1 2>/dev/null | awk '/\.so/ {print $1, $2, $NF}' | sort -u
nginx     2181 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
nginx     2182 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
postgres  1044 /usr/lib/x86_64-linux-gnu/libcrypto.so.3

# Distribution helpers:
$ sudo needs-restarting -r ; echo "exit=$?"          # RHEL family (dnf-utils)
Core libraries or services have been updated since boot-up:
  * openssl-libs
Reboot is required to ensure that your system benefits from these updates.
exit=1

$ sudo checkrestart                                   # Debian (debian-goodies)
Found 3 processes using old versions of upgraded files
(1 distinct program)
(1 distinct packages)

These are the packages:
nginx
```

**El parche no está aplicado hasta que el proceso se reinicia.** Cualquier informe de cumplimiento que se detenga en la versión del paquete está equivocado.

### 5.8 Reparar el enlazado de un ELF sin recompilar

`patchelf` es la salida de emergencia para binarios de proveedores que no podés recompilar:

```bash
$ patchelf --print-rpath ./vendor-agent
/build/tmp/lib

$ patchelf --print-needed ./vendor-agent
libfancy.so.2
libc.so.6

$ patchelf --print-interpreter ./vendor-agent
/lib64/ld-linux-x86-64.so.2

# Repoint at a relocatable location.
$ cp ./vendor-agent ./vendor-agent.bak
$ patchelf --set-rpath '$ORIGIN/../lib' ./vendor-agent

$ patchelf --print-rpath ./vendor-agent
$ORIGIN/../lib

$ readelf -d ./vendor-agent | grep -E 'RPATH|RUNPATH'
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib]

$ ./vendor-agent --version
vendor-agent 4.7.1
```

Guardá la copia de respaldo. `patchelf` reescribe las cabeceras de programa y, en disposiciones poco habituales, puede producir un binario que ya no carga. Verificá con `--list` antes de enviarlo.

---

## 6. Guía de diagnóstico de fallos

### 6.1 Síntoma → causa → comando → solución

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| `error while loading shared libraries: libX.so.N: cannot open shared object file` | El SONAME no resuelve en ninguno de los cinco pasos de búsqueda | `LD_DEBUG=libs ./app` | Instalar la biblioteca; agregar su directorio a `ld.so.conf.d` y ejecutar `ldconfig` |
| `bash: ./app: No such file or directory` sobre un archivo existente y ejecutable | Falta `PT_INTERP` en este mount namespace (binario glibc en Alpine/`scratch`) | `readelf -l ./app \| grep interpreter` | Igualar la libc de las imágenes de build y de runtime; o enviar el cargador |
| `libX.so.6: version 'GLIBC_2.38' not found` | Compilado contra una glibc más nueva que la que provee el runtime | `objdump -p ./app \| grep GLIBC_ \| sort -V \| tail -1` | Compilar en la distro de la imagen de runtime; fijar la imagen base de CI a la imagen base de runtime |
| `symbol lookup error: ./app: undefined symbol: foo` | Biblioteca actualizada/degradada en el lugar sin incrementar el SONAME, o una biblioteca equivocada ensombreciendo a la correcta | `nm -D --defined-only /path/libX.so.N \| grep foo` | Restaurar la versión que corresponde; eliminar la ruta que ensombrece; usar `LD_BIND_NOW=1` para que esto salga a la luz al arrancar |
| `wrong ELF class: ELFCLASS32` | Se encontró primero una biblioteca de 32 bits para un proceso de 64 bits | `file libX.so.N`; `ldconfig -p \| grep libX` | Corregir el orden de directorios; instalar el paquete multiarch correcto |
| Funciona con tu usuario, falla con el usuario del servicio | `LD_LIBRARY_PATH` en el perfil de tu shell; o setuid la elimina | `sudo -u svc env \| grep LD_` | Migrar a `ld.so.conf.d` + `ldconfig` |
| Funciona interactivamente, falla desde cron/systemd | Lo mismo — la variable de entorno no existe en un entorno sin login | `systemctl show -p Environment greet-api` | Lo mismo |
| `ldconfig -p` muestra la biblioteca pero la aplicación igual no la encuentra | Entrada de arquitectura equivocada, o la aplicación tiene `DT_RPATH` que anula todo, o `-z nodefaultlib` | `ldconfig -p \| grep libX` (revisá la etiqueta de arquitectura); `objdump -p ./app \| grep RPATH` | Eliminar el `RPATH` con parche; instalar la arquitectura correcta |
| `cannot restore segment prot after reloc: Permission denied` | Relocalizaciones de texto en una biblioteca no-PIC bajo SELinux | `readelf -d libX.so \| grep TEXTREL`; `ausearch -m avc -ts recent` | Recompilar con `-fPIC` (lo correcto); o `chcon -t textrel_shlib_t libX.so` (rodeo) |
| `failed to map segment from shared object` | Opción de montaje `noexec` en el directorio que contiene la biblioteca | `findmnt -T /opt/greet/lib -o TARGET,OPTIONS` | Remontar sin `noexec`, o reubicar la biblioteca |
| El escáner de CVE sigue marcando un host parcheado | Los procesos siguen mapeando el inodo eliminado | `lsof +L1 \| grep '\.so'` | Reiniciar los procesos que lo mapean |
| Una biblioteca aparece/desaparece según el modelo de CPU | Despacho por subdirectorio `glibc-hwcaps` (glibc ≥ 2.33) | `ld.so --help \| grep -A10 'Subdirectories'` | Instalar en el directorio base, o en cada nivel `glibc-hwcaps/` relevante |
| Una biblioteca instalada en `tls/`, `sse2/`, `x86_64/` se ignora en una distro nueva | Los hwcaps legados fueron **eliminados en glibc 2.37** | `ldd --version`; `ldconfig -p \| grep libX` | Mover el archivo al directorio de bibliotecas normal |

### 6.2 Caso de estudio — `cannot open shared object file`, resuelto de punta a punta

```bash
$ /opt/greet/bin/greet-api --listen :8080
/opt/greet/bin/greet-api: error while loading shared libraries: libfancycodec.so.2: cannot open shared object file: No such file or directory
```

**Paso 1 — ¿qué exige realmente el binario?** No lo ejecutes de nuevo.

```bash
$ objdump -p /opt/greet/bin/greet-api | grep -E 'NEEDED|RPATH|RUNPATH'
  NEEDED               libgreet.so.1
  NEEDED               libfancycodec.so.2
  NEEDED               libc.so.6
  RUNPATH              $ORIGIN/../lib
```

**Paso 2 — ¿la caché lo conoce?**

```bash
$ ldconfig -p | grep -i fancy
$ echo $?
1
```

No. O el archivo no está, o su directorio no está configurado, o su `SONAME` no es el que el binario quiere.

**Paso 3 — ¿el archivo existe en alguna parte?**

```bash
$ sudo find / -xdev -name 'libfancycodec.so*' -printf '%p\t%l\n' 2>/dev/null
/opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2.4.0	
```

Existe. El symlink del `SONAME` no.

**Paso 4 — ¿con qué nombre se anuncia el archivo?**

```bash
$ objdump -p /opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2.4.0 | grep SONAME
  SONAME               libfancycodec.so.2
```

Coincide. Así que las únicas piezas faltantes son el symlink y la configuración.

**Paso 5 — confirmar la hipótesis sin cambiar el estado del sistema.**

```bash
$ ln -s libfancycodec.so.2.4.0 /tmp/probe/libfancycodec.so.2
$ LD_LIBRARY_PATH=/tmp/probe:/opt/vendor/fancy-4.7.1/lib \
    /opt/greet/bin/greet-api --version
greet-api 1.2.3 (libfancycodec 4.7.1)
```

Confirmado.

**Paso 6 — aplicar la solución duradera.**

```bash
$ printf '%s\n' '# libfancycodec runtime, owned by greet-runtime' \
                '/opt/vendor/fancy-4.7.1/lib' \
    | sudo tee /etc/ld.so.conf.d/fancycodec.conf
# libfancycodec runtime, owned by greet-runtime
/opt/vendor/fancy-4.7.1/lib

$ sudo ldconfig

$ ls -l /opt/vendor/fancy-4.7.1/lib/
total 1892
lrwxrwxrwx 1 root root      23 Aug 25 10:12 libfancycodec.so.2 -> libfancycodec.so.2.4.0
-rw-r--r-- 1 root root 1936784 Jul 30 08:41 libfancycodec.so.2.4.0
```

`ldconfig` creó el symlink a partir del `SONAME` del ELF. No hizo falta ningún `ln` manual.

**Paso 7 — verificar y luego reiniciar el servicio.**

```bash
$ ldconfig -p | grep -i fancy
	libfancycodec.so.2 (libc6,x86-64) => /opt/vendor/fancy-4.7.1/lib/libfancycodec.so.2

$ /lib64/ld-linux-x86-64.so.2 --list /opt/greet/bin/greet-api | grep -c 'not found'
0

$ sudo systemctl restart greet-api
$ systemctl is-active greet-api
active
```

### 6.3 Caso de estudio — la biblioteca ensombrecida

Síntoma: el servicio arranca y luego muere en el primer handshake TLS con `undefined symbol: SSL_CTX_set_ciphersuites`.

```bash
$ LD_DEBUG=libs /opt/greet/bin/greet-api 2>&1 | grep -A2 'find library=libssl'
    301244:	find library=libssl.so.3 [0]; searching
    301244:	 search path=/opt/legacy/lib		(LD_LIBRARY_PATH)
    301244:	  trying file=/opt/legacy/lib/libssl.so.3
```

`LD_LIBRARY_PATH` le ganó a la caché. ¿Qué archivo obtuvo?

```bash
$ ldconfig -p | grep -w libssl.so.3
	libssl.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libssl.so.3

$ nm -D --defined-only /opt/legacy/lib/libssl.so.3 | grep -c SSL_CTX_set_ciphersuites
0
$ nm -D --defined-only /lib/x86_64-linux-gnu/libssl.so.3 | grep -c SSL_CTX_set_ciphersuites
1
```

Confirmado: `/opt/legacy/lib` contiene una compilación más vieja de OpenSSL 3 con el mismo SONAME. Buscá quién definió la variable:

```bash
$ systemctl show -p Environment greet-api
Environment=LD_LIBRARY_PATH=/opt/legacy/lib LD_BIND_NOW=1

$ sudo tr '\0' '\n' < /proc/$(pgrep -x greet-api)/environ | grep '^LD_'
LD_LIBRARY_PATH=/opt/legacy/lib
LD_BIND_NOW=1
```

Solución: eliminar la línea `Environment=LD_LIBRARY_PATH=` de la unidad y darle al *único* binario que necesita la compilación legada su propio `RUNPATH` vía `patchelf`, de modo que la anulación quede acotada a ese ELF en lugar de a todo el árbol de procesos.

```bash
$ sudo systemctl edit --full greet-api      # delete the LD_LIBRARY_PATH assignment
$ sudo systemctl daemon-reload
$ sudo systemctl restart greet-api
$ sudo tr '\0' '\n' < /proc/$(pgrep -x greet-api)/environ | grep -c LD_LIBRARY_PATH
0
```

### 6.4 Comprobaciones de seguridad que corresponden a tu línea base

```bash
# /etc/ld.so.preload is loaded into EVERY process. It is not an environment
# variable, so it survives env scrubbing — the classic userland-rootkit hook.
$ ls -l /etc/ld.so.preload 2>/dev/null || echo "absent (expected on a clean host)"
absent (expected on a clean host)

# World-writable directories in the loader's search path = arbitrary code
# execution as every user who runs a dynamically linked program.
$ ldconfig -v 2>/dev/null | sed -n 's/^\(\/[^:]*\):$/\1/p' \
    | xargs -r stat -c '%A %U %n' 2>/dev/null | grep -E '^d.......w'

# World-writable shared objects.
$ find /lib /usr/lib /usr/local/lib /opt -xdev -name '*.so*' -perm -o+w -ls 2>/dev/null

# Libraries not owned by any package.
$ for f in $(find /usr/lib/x86_64-linux-gnu -maxdepth 1 -name '*.so.*' -type f); do
>   dpkg -S "$f" >/dev/null 2>&1 || echo "UNOWNED: $f"
> done
UNOWNED: /usr/lib/x86_64-linux-gnu/libfancycodec.so.2.4.0

# Text relocations (indicate non-PIC code; blocked under SELinux, and a sign
# of a library built without -fPIC).
$ for f in /usr/local/lib/*.so*; do
>   readelf -d "$f" 2>/dev/null | grep -q TEXTREL && echo "TEXTREL: $f"
> done
```

---

## 7. Radar de examen — qué evalúa realmente 102.3

- **`/etc/ld.so.conf` contiene `include /etc/ld.so.conf.d/*.conf`.** Agregá directorios como fragmentos ahí, no editando el archivo principal.
- **Editar la configuración no hace nada hasta que se ejecuta `ldconfig`.** Esta es la cadena causal más evaluada de todo el objetivo.
- **`ldconfig -p` imprime la caché; `ldconfig` a secas la reconstruye** (y necesita root).
- **`ldconfig` crea el symlink del SONAME, a partir de la cabecera ELF — no el symlink de desarrollo `.so`, y no a partir del nombre de archivo.**
- **`ldd` muestra las dependencias resueltas de forma recursiva**; `=> not found` es el marcador de fallo; que `linux-vdso.so.1` no tenga ruta es normal.
- **`LD_LIBRARY_PATH` es una variable de entorno separada por dos puntos, consultada antes de la caché y después de `RPATH`**, heredada por los hijos, ignorada para binarios setuid.
- **Ubicaciones típicas:** `/lib`, `/lib64`, `/usr/lib`, `/usr/lib64`, `/usr/local/lib`, y en multiarch de la familia Debian `/lib/x86_64-linux-gnu`, `/usr/lib/x86_64-linux-gnu`.
- **Nomenclatura:** `libNAME.so.MAJOR.MINOR.PATCH` (nombre real) → `libNAME.so.MAJOR` (soname) → `libNAME.so` (nombre para el enlazador).
- **El archivo de caché es `/etc/ld.so.cache`** — binario, nunca se edita a mano, siempre se regenera.

Distractores a rechazar de entrada: "ejecutá `ldd` para reconstruir la caché" (no — `ldconfig`), "editá `/etc/ld.so.cache` con un editor de texto" (no — es binario), "`ldconfig` crea `libfoo.so`" (no — solo `libfoo.so.N`), "`LD_LIBRARY_PATH` se lee desde `/etc/ld.so.conf`" (no — son mecanismos sin relación).

---

## 8. Práctica

### 8.1 Ejercicios

1. Usando únicamente `readelf`/`objdump`, listá todas las dependencias directas de `/usr/sbin/sshd` y sus rutas de búsqueda embebidas, sin ejecutar el binario. ¿Cuál es su versión mínima de glibc?
2. Un colega instaló `libmagic.so.1.0.0` en `/opt/tools/lib` e informa que "`ldconfig` no creó el symlink". Dá los dos comandos que determinan si el problema es el `SONAME` o la configuración.
3. Explicá, en los términos del propio cargador, por qué un binario con `DT_RPATH=/opt/old/lib` no puede redirigirse con `LD_LIBRARY_PATH`, y dá el comando que lo arregla en el lugar.
4. Tu escáner de imágenes informa que `libcrypto3` está parcheada, pero el equipo de seguridad insiste en que el host es vulnerable. Ambos tienen razón. Producí el comando que lo demuestra y la remediación.
5. Un pod con `readOnlyRootFilesystem: true` necesita que se le inyecte una biblioteca de proveedor en tiempo de ejecución. Explicá por qué `ldconfig` en el entrypoint falla y dá dos alternativas que funcionan con sus compromisos.
6. `libfoo.so.2` está presente en `/usr/local/lib`, `ldconfig -p` la lista, pero un binario de 64 bits igual informa que no la encuentra. Nombrá tres causas distintas y el comando que distingue cada una.

### 8.2 Laboratorio — construir, romper y arreglar un despliegue con bibliotecas compartidas

**Preparación.** Usando el `Makefile` y las fuentes de §4.1:

```bash
$ make all VERSION=1.2.3 ABI=1
$ sudo make install PREFIX=/opt/greet
$ ls -l /opt/greet/lib/
```

**Tarea 1 — observar el fallo.** Ejecutá `/opt/greet/bin/app` (copiá `./app` ahí primero) desde un directorio donde `$ORIGIN/../lib` no resuelva. Capturá la traza completa de `LD_DEBUG=libs` y anotá cada uno de los cinco pasos de búsqueda.

**Tarea 2 — arreglarlo de tres formas y ordenarlas.** Hacé que el binario funcione usando (a) `LD_LIBRARY_PATH`, (b) `/etc/ld.so.conf.d/` + `ldconfig`, (c) `patchelf --set-rpath`. Para cada una, registrá: ¿sobrevive a un reinicio?, ¿afecta a otros procesos?, ¿sobrevive a un `chmod u+s` sobre el binario?

**Tarea 3 — romper el ABI.** Editá `src/libgreet.map` para quitar `greet_message` de `GREET_1.0`, recompilá, reinstalá **sin** incrementar el SONAME y ejecutá el binario `app` existente. Capturá el error exacto. Después definí `LD_BIND_NOW=1` y observá cómo cambia el momento del fallo.

**Tarea 4 — simular el incidente de parchear y olvidar.** Arrancá `app` en un bucle en segundo plano. Reinstalá `libgreet.so.1.2.3` con contenido distinto. Demostrá con `/proc/<pid>/maps` y `lsof +L1` que el proceso en ejecución sigue mapeando el inodo viejo. Reinicialo y demostrá que el mapeo cambió.

**Tarea 5 — contenerizarlo.** Construí el `Dockerfile` de §4.4. Después rompelo a propósito: cambiá la etapa de build a `ubuntu:24.04` dejando la etapa de runtime en `debian:12`. Capturá el fallo y luego mostrá cuál de las tres compuertas de CI en `check-so-deps.sh` lo detecta y por qué las otras dos no.

**Tarea 6 — la trampa de multiarch.** Instalá una `libz1:i386` de 32 bits en un host de 64 bits. Mostrá con `ldconfig -p` cómo la caché distingue las dos entradas, y construí un caso donde un binario de 64 bits falle con `wrong ELF class`.

---

## 9. Referencias

**LPI — objetivos oficiales del examen**
- LPIC-1 Exam 101 objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives (v5.0), objetivo 102.3: https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Documentación de referencia de glibc y del cargador dinámico**
- `ld.so(8)` — enlazador/cargador dinámico, orden de búsqueda, variables de entorno, modo de ejecución segura: https://man7.org/linux/man-pages/man8/ld.so.8.html
- `ldconfig(8)` — gestión de la caché y de los symlinks, todas las opciones: https://man7.org/linux/man-pages/man8/ldconfig.8.html
- `ldd(1)` — incluida la advertencia de seguridad sobre ejecutar el objeto: https://man7.org/linux/man-pages/man1/ldd.1.html
- `dlopen(3)` — carga en tiempo de ejecución, flags `RTLD_*`: https://man7.org/linux/man-pages/man3/dlopen.3.html
- `elf(5)` — estructuras ELF, `PT_INTERP`, etiquetas dinámicas: https://man7.org/linux/man-pages/man5/elf.5.html
- El manual de la GNU C Library — Dynamic Linker: https://www.gnu.org/software/libc/manual/html_node/Dynamic-Linker.html
- Subdirectorios `glibc-hwcaps` de glibc y la eliminación de los hwcaps legados: https://sourceware.org/glibc/wiki/Release/2.33 y https://sourceware.org/glibc/wiki/Release/2.37
- Política de ABI y versionado de símbolos de glibc: https://sourceware.org/glibc/wiki/Development

**Binutils y herramientas de inspección**
- Documentación de GNU `ld` — `-rpath`, `-rpath-link`, `--enable-new-dtags`, `LD_RUN_PATH`: https://sourceware.org/binutils/docs/ld/Options.html
- `readelf(1)`: https://sourceware.org/binutils/docs/binutils/readelf.html
- `objdump(1)`: https://sourceware.org/binutils/docs/binutils/objdump.html
- `nm(1)`: https://sourceware.org/binutils/docs/binutils/nm.html
- `patchelf` — modificar el intérprete ELF, el RPATH y las entradas NEEDED: https://github.com/NixOS/patchelf
- `pax-utils` (`lddtree`, `scanelf`): https://wiki.gentoo.org/wiki/Hardened/PaX_Utilities
- `libabigail` / `abidiff` — detección de cambios de ABI: https://sourceware.org/libabigail/manual/abidiff.html

**Estándares y guías de empaquetado**
- Filesystem Hierarchy Standard 3.0 — `/lib`, `/usr/lib`, `/usr/local/lib`: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Especificación Multiarch de Debian (`/usr/lib/<triplet>`): https://wiki.debian.org/Multiarch/Implementation
- Debian Policy — bibliotecas compartidas, SONAME y `ldconfig` en los scripts del mantenedor: https://www.debian.org/doc/debian-policy/ch-sharedlibs.html
- Fedora Packaging Guidelines — bibliotecas compartidas: https://docs.fedoraproject.org/en-US/packaging-guidelines/
- Ulrich Drepper, *How To Write Shared Libraries*: https://www.akkadia.org/drepper/dsohowto.pdf
- Especificación ELF (System V ABI, gABI): https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html

**musl y contenedores**
- musl libc — enlazado dinámico y `/etc/ld-musl-$ARCH.path`: https://wiki.musl-libc.org/functional-differences-from-glibc.html
- Alpine Linux — ejecutar software glibc: https://wiki.alpinelinux.org/wiki/Running_glibc_programs
- Kubernetes — contexto de seguridad del Pod y `readOnlyRootFilesystem`: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — init containers: https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- NVIDIA Container Toolkit — inyección de bibliotecas del driver en contenedores: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html

**systemd**
- `systemd.exec(5)` — `Environment=`, `ExecStartPre=`, `NoNewPrivileges=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html