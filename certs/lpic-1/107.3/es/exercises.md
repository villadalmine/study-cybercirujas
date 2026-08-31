# 107.3 — Localización e internacionalización

## Ejercicios guiados

**Objetivo del examen:** LPIC-1, examen 102-500, objetivo 107.3 — *Localización e internacionalización*.

### Requisitos previos del laboratorio

- Un sistema Linux donde tengas `sudo`. Se recomienda encarecidamente una VM o un contenedor descartable: varios pasos modifican el estado de locale y de zona horaria de todo el sistema.
- Paquetes: `glibc` (siempre presente), `coreutils`, `bsdmainutils`/`util-linux` (para `hexdump`), `tzdata` y —en sistemas con systemd— `systemd` (para `timedatectl` / `localectl`).
- Tomá una instantánea del estado original antes de empezar; lo vas a restaurar al final:

```bash
$ mkdir -p ~/107.3-lab && cd ~/107.3-lab
$ locale > locale.before
$ readlink -f /etc/localtime > tz.before
$ cat tz.before
/usr/share/zoneinfo/Europe/Madrid
```

> A lo largo del documento, `$` marca un comando ejecutado como tu usuario normal y `#` marca un comando ejecutado como root. Las salidas son representativas — las cadenas exactas varían según la distribución, la versión de glibc y el conjunto de locales instalados en tu máquina. Cuando un valor es genuinamente específico de la máquina, se señala.

---

## Ejercicio 1 — Leer el estado actual del locale

**Meta:** distinguir las *categorías* de un locale y aprender a saber cuál de ellas se estableció explícitamente y cuál se heredó.

1. Imprimí la configuración de locale efectiva:

```bash
$ locale
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="en_US.UTF-8"
LC_NUMERIC="en_US.UTF-8"
LC_TIME="en_US.UTF-8"
LC_COLLATE="en_US.UTF-8"
LC_MONETARY="en_US.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="en_US.UTF-8"
LC_NAME="en_US.UTF-8"
LC_ADDRESS="en_US.UTF-8"
LC_TELEPHONE="en_US.UTF-8"
LC_MEASUREMENT="en_US.UTF-8"
LC_IDENTIFICATION="en_US.UTF-8"
LC_ALL=
```

2. Fijate con atención en que cada valor `LC_*` de arriba está **entre comillas dobles**. Ahora establecé una categoría explícitamente y mirá de nuevo:

```bash
$ export LC_TIME=C
$ locale | grep -E 'LANG=|LC_TIME|LC_CTYPE|LC_ALL'
LANG=en_US.UTF-8
LC_CTYPE="en_US.UTF-8"
LC_TIME=C
LC_ALL=
```

3. Inspeccioná el *contenido* de una categoría con `-k` (keyword) en lugar de solo su nombre:

```bash
$ locale -k LC_NUMERIC
decimal_point="."
thousands_sep=","
grouping=3;3
numeric-decimal-point-wc=46
numeric-thousands-sep-wc=44
numeric-codeset="UTF-8"

$ LC_ALL=de_DE.UTF-8 locale -k LC_NUMERIC | head -3
decimal_point=","
thousands_sep="."
grouping=3;3
```

4. Consultá una sola clave en lugar de una categoría entera — esta es la forma apta para scripts:

```bash
$ locale decimal_point
.
$ LC_ALL=de_DE.UTF-8 locale abday
So;Mo;Di;Mi;Do;Fr;Sa
$ locale charmap
UTF-8
```

5. Deshacé el paso 2 antes de continuar:

```bash
$ unset LC_TIME
```

**Preguntas**

- **Q1.1** — En la salida de `locale`, ¿cuál es la diferencia de significado entre `LC_TIME="en_US.UTF-8"` y `LC_TIME=en_US.UTF-8`?
- **Q1.2** — Descomponé `en_US.UTF-8` en sus partes y nombrá cada una. ¿Qué agregaría `ca_ES.UTF-8@valencia`?
- **Q1.3** — ¿Qué categoría gobierna cada uno de los siguientes casos: el orden alfabético que usa `sort`; el símbolo de moneda que imprime una aplicación; si `tr '[:upper:]' '[:lower:]'` sabe que `É` se pasa a minúscula como `é`; el idioma de los mensajes de error de `ls`?
- **Q1.4** — `locale charmap` devolvió `UTF-8`. ¿Qué única categoría determinó esa respuesta?

---

## Ejercicio 2 — Precedencia: `LC_ALL` > `LC_*` > `LANG`, y dónde encaja `LANGUAGE`

**Meta:** interiorizar la cadena de sobrescritura de tres niveles y el rol especial —solo para mensajes— de `LANGUAGE`.

1. Establecé una línea base conocida y observá el formato de fecha:

```bash
$ export LANG=en_US.UTF-8
$ unset LC_ALL LANGUAGE
$ date
Thu Aug 27 02:15:44 PM CEST 2026
```

2. Sobrescribí **una** categoría. `LANG` sigue proveyendo todas las demás:

```bash
$ LC_TIME=de_DE.UTF-8 date
Do 27 Aug 2026 14:15:51 CEST
```

3. Ahora sobrescribí **todo** con `LC_ALL` y confirmá que le gana al `LC_TIME` más específico:

```bash
$ LC_ALL=C LC_TIME=de_DE.UTF-8 date
Thu Aug 27 14:16:02 CEST 2026
```

4. Mirá cómo `LC_ALL` aplana el informe completo:

```bash
$ LC_ALL=C locale | head -4
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="C"
LC_NUMERIC="C"
```

5. Explorá `LANGUAGE`, que es una extensión de GNU gettext y **no** una categoría POSIX. Toma una *lista* de idiomas de reserva separados por dos puntos, y solo afecta a los mensajes traducidos:

```bash
$ LANGUAGE=de:fr:en LC_ALL=en_US.UTF-8 ls /nonexistent
ls: Zugriff auf '/nonexistent' nicht möglich: Datei oder Verzeichnis nicht gefunden

$ LANGUAGE=de:fr:en LC_ALL=en_US.UTF-8 date
Thu Aug 27 02:16:30 PM CEST 2026
```

6. Ahora demostrá la regla con la que la gente tropieza en los scripts — `LANGUAGE` se ignora por completo cuando el locale de mensajes es `C` o `POSIX`:

```bash
$ LANGUAGE=de LC_ALL=C ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory
```

**Preguntas**

- **Q2.1** — Enunciá el orden de precedencia para una sola categoría como `LC_TIME`, del más fuerte al más débil.
- **Q2.2** — En el paso 5, los *mensajes* pasaron a alemán pero el *formato de fecha* siguió siendo estadounidense. Explicá con precisión por qué.
- **Q2.3** — ¿Por qué establecer `LC_ALL` de forma permanente en `/etc/environment` o `~/.bashrc` se considera mala práctica, mientras que usarlo como prefijo puntual (`LC_ALL=C somecommand`) se considera buena práctica?
- **Q2.4** — Un script necesita mensajes en francés si están disponibles, si no en español, si no en inglés. ¿Qué variable expresa eso, y con qué valor?

---

## Ejercicio 3 — Observar qué cambia realmente un locale

**Meta:** ver la colación, el formato numérico y el formato de hora cambiar bajo tus manos, de modo que los errores dependientes del locale se vuelvan reconocibles.

1. Colación — la diferencia más trascendente entre `C` y cualquier locale de lengua natural:

```bash
$ printf 'apple\nBanana\ncherry\nApricot\n' > words.txt

$ LC_ALL=C sort words.txt
Apricot
Banana
apple
cherry

$ LC_ALL=en_US.UTF-8 sort words.txt
apple
Apricot
Banana
cherry
```

2. Formato numérico — agrupación de miles y separador decimal:

```bash
$ LC_ALL=C          printf "%'d\n" 1234567
1234567
$ LC_ALL=en_US.UTF-8 printf "%'d\n" 1234567
1,234,567
$ LC_ALL=de_DE.UTF-8 printf "%'d\n" 1234567
1.234.567

$ LC_ALL=en_US.UTF-8 printf "%.2f\n" 3.5
3.50
$ LC_ALL=de_DE.UTF-8 printf "%.2f\n" 3.5
3,50
```

3. Formato de hora — incluido el nombre abreviado de mes del que dependen tantos analizadores de logs:

```bash
$ LC_ALL=C           date +'%A %d %B %Y — %x %X'
Thursday 27 August 2026 — 08/27/26 14:17:20
$ LC_ALL=es_ES.UTF-8 date +'%A %d %B %Y — %x %X'
jueves 27 agosto 2026 — 27/08/26 14:17:22
$ LC_ALL=C date +%b ; LC_ALL=es_ES.UTF-8 date +%b
Aug
ago
```

4. Clasificación de caracteres (`LC_CTYPE`) — si el sistema sabe siquiera que una secuencia de bytes es una letra:

```bash
$ printf 'ÁÉÍÓÚ\n' | LC_ALL=en_US.UTF-8 tr '[:upper:]' '[:lower:]'
áéíóú
$ printf 'ÁÉÍÓÚ\n' | LC_ALL=C tr '[:upper:]' '[:lower:]'
ÁÉÍÓÚ
```

5. Medí el impacto práctico sobre un script que analiza salida:

```bash
$ LC_ALL=es_ES.UTF-8 ls -l /etc/hosts
-rw-r--r-- 1 root root 219 ago  3 11:04 /etc/hosts
$ LC_ALL=C ls -l /etc/hosts
-rw-r--r-- 1 root root 219 Aug  3 11:04 /etc/hosts
```

**Preguntas**

- **Q3.1** — En el paso 1, `C` colocó `Apricot` antes que `apple`, pero `en_US.UTF-8` colocó `apple` antes que `Apricot`. ¿Qué regla de ordenamiento aplica cada locale?
- **Q3.2** — Un trabajo de cron canaliza `ls -l` hacia `awk` y busca coincidencias con `"Aug"`. Funciona en tu portátil y falla en el de un colega. Dá la causa y la corrección de una línea.
- **Q3.3** — Una exportación CSV producida bajo `de_DE.UTF-8` contiene el valor `1.234,56`. Dos problemas van a golpear al importador aguas abajo. Nombrá ambos y nombrá las dos categorías responsables.
- **Q3.4** — ¿Por qué `LC_ALL=C` hace que `tr '[:upper:]' '[:lower:]'` deje de funcionar con caracteres acentuados? ¿Es un error de `tr`?

---

## Ejercicio 4 — Qué locales existen y cómo crear uno

**Meta:** distinguir las definiciones de locale *soportadas* de los locales *generados/instalados*, y generar uno en las dos grandes familias de distribuciones.

1. Listá los locales disponibles actualmente en el sistema y contalos:

```bash
$ locale -a
C
C.utf8
POSIX
en_US.utf8
$ locale -a | wc -l
4
```

2. Fijate en la grafía. glibc informa la forma *normalizada*. Confirmá que ambas grafías se aceptan:

```bash
$ LC_ALL=en_US.UTF-8 date +%b
Aug
$ LC_ALL=en_US.utf8 date +%b
Aug
```

3. Probá un locale que está *definido* pero no *generado*, y leé el error con precisión:

```bash
$ LC_ALL=fr_FR.UTF-8 date
bash: warning: setlocale: LC_ALL: cannot change locale (fr_FR.UTF-8): No such file or directory
Thu Aug 27 02:18:03 PM CEST 2026
```

4. Mirá los ingredientes crudos a partir de los cuales se construyen los locales:

```bash
$ ls /usr/share/i18n/locales | head -5
aa_DJ
aa_ER
aa_ET
af_ZA
agr_PE
$ ls /usr/share/i18n/charmaps | head -5
ANSI_X3.110-1983.gz
ANSI_X3.4-1968.gz
ARMSCII-8.gz
ASCII.gz
BIG5.gz
$ grep -c '' /usr/share/i18n/SUPPORTED
496
```

5. Generá el locale. **Camino Debian/Ubuntu** — descomentá la línea en `/etc/locale.gen` y ejecutá el generador:

```bash
# sed -i 's/^# *\(fr_FR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
# grep '^fr_FR' /etc/locale.gen
fr_FR.UTF-8 UTF-8
# locale-gen
Generating locales (this might take a while)...
  en_US.UTF-8... done
  fr_FR.UTF-8... done
Generation complete.
```

6. **Camino directo / RHEL-Fedora** — construí un único locale con `localedef`, o instalá el paquete de idioma:

```bash
# localedef -i fr_FR -f UTF-8 fr_FR.UTF-8
# localedef --list-archive | head -3
en_US.utf8
fr_FR.utf8

# dnf install -y glibc-langpack-fr        # Fedora/RHEL equivalent
```

7. Verificá y luego establecé el valor predeterminado de todo el sistema. Los **sistemas systemd** escriben `/etc/locale.conf`:

```bash
$ locale -a | grep fr
fr_FR.utf8

$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us

# localectl set-locale LANG=fr_FR.UTF-8
$ cat /etc/locale.conf
LANG=fr_FR.UTF-8
```

8. **Debian** mantiene además `/etc/default/locale`, gestionado por `update-locale`:

```bash
# update-locale LANG=fr_FR.UTF-8
# cat /etc/default/locale
LANG=fr_FR.UTF-8
```

9. Restaurá tu valor predeterminado original antes de continuar:

```bash
# localectl set-locale LANG=en_US.UTF-8
```

**Preguntas**

- **Q4.1** — `/usr/share/i18n/locales/fr_FR` existe en un sistema recién instalado y sin embargo `LC_ALL=fr_FR.UTF-8 date` falla. Explicá la distinción que está haciendo el sistema.
- **Q4.2** — ¿Cuáles son los dos argumentos que toman `localedef -i` y `-f`, y qué aporta cada uno al locale terminado?
- **Q4.3** — `/etc/locale.gen` contiene `fr_FR.UTF-8 UTF-8`. ¿Por qué aparece el charmap dos veces en esa línea, y son lo mismo las dos apariciones?
- **Q4.4** — ¿Cuál es la diferencia de alcance entre `/etc/locale.conf` y `~/.bashrc` para establecer `LANG`? ¿Cuál afecta a una sesión de inicio gráfica y a una unidad de servicio de `systemd`?
- **Q4.5** — `C.UTF-8` aparece en `locale -a`. ¿En qué se diferencia tanto de `C` como de `en_US.UTF-8`, y por qué es un buen valor predeterminado para contenedores?

---

## Ejercicio 5 — Codificaciones de caracteres: ASCII, ISO-8859, Unicode, UTF-8

**Meta:** ver, a nivel de bytes, que "el mismo texto" ocupa bytes distintos en codificaciones distintas, y que la codificación no se almacena en el archivo.

1. Creá un archivo UTF-8 e inspeccioná sus bytes:

```bash
$ printf 'ma\xc3\xb1ana\n' > utf8.txt
$ cat utf8.txt
mañana
$ file utf8.txt
utf8.txt: Unicode text, UTF-8 text
$ hexdump -C utf8.txt
00000000  6d 61 c3 b1 61 6e 61 0a                           |ma..ana.|
00000008
```

2. Contrastá el recuento de *bytes* con el de *caracteres*. Esto solo funciona si `LC_CTYPE` es un locale UTF-8:

```bash
$ LC_ALL=en_US.UTF-8 wc -c -m utf8.txt
 8  7 utf8.txt
$ LC_ALL=C wc -c -m utf8.txt
 8  8 utf8.txt
```

3. Convertí a ISO-8859-1 (Latin-1) y compará:

```bash
$ iconv -f UTF-8 -t ISO-8859-1 utf8.txt > latin1.txt
$ hexdump -C latin1.txt
00000000  6d 61 f1 61 6e 61 0a                              |ma.ana.|
00000007
$ file latin1.txt
latin1.txt: ISO-8859 text
$ wc -c latin1.txt
7 latin1.txt
```

4. Ahora mostrá el archivo Latin-1 en una terminal UTF-8 — esto es *mojibake*, reproducido deliberadamente:

```bash
$ cat latin1.txt
ma?ana
```

5. Probá que el archivo en sí no lleva etiqueta de codificación — la tenés que aportar vos:

```bash
$ iconv -f ISO-8859-1 -t UTF-8 latin1.txt
mañana
$ iconv -f ISO-8859-5 -t UTF-8 latin1.txt
maёana
```

6. Mirá un carácter que Latin-1 no puede contener en absoluto:

```bash
$ printf '10 \xe2\x82\xac\n' > euro.txt
$ cat euro.txt
10 €
$ hexdump -C euro.txt
00000000  31 30 20 e2 82 ac 0a                              |10 ....|
00000007

$ iconv -f UTF-8 -t ISO-8859-1 euro.txt > /dev/null
iconv: cannot convert
$ echo $?
1

$ iconv -f UTF-8 -t ISO-8859-15 euro.txt | hexdump -C
00000000  31 30 20 a4 0a                                    |10 ..|
00000005
```

> La redacción exacta del diagnóstico difiere entre versiones de glibc e implementaciones de libc (`illegal input sequence at position N` también es habitual). Lo que es portable es el **estado de salida distinto de cero** — eso es lo que un script debe comprobar.

7. Recorré las codificaciones que conoce tu `iconv`:

```bash
$ iconv -l | wc -l
1173
$ iconv -l | grep -i '^UTF'
UTF-7//
UTF-8//
UTF-16//
UTF-16BE//
UTF-16LE//
UTF-32//
$ locale -m | grep -iE '^(ASCII|ISO-8859-1|UTF-8)$'
ANSI_X3.4-1968
ISO-8859-1
UTF-8
```

**Preguntas**

- **Q5.1** — `mañana` tiene 6 caracteres. ¿Por qué `utf8.txt` ocupa 8 bytes y `latin1.txt` 7 bytes (ambos incluyendo el salto de línea)?
- **Q5.2** — En el paso 2, `wc -m` devolvió 8 bajo `LC_ALL=C` y 7 bajo `en_US.UTF-8`, para el archivo idéntico. Explicalo.
- **Q5.3** — Los bytes `6d 61` son idénticos en ambos archivos. ¿Qué propiedad de UTF-8 garantiza esto para cada carácter ASCII, y por qué importó tanto esa propiedad para su adopción?
- **Q5.4** — El paso 5 decodificó los mismos 7 bytes como `mañana` y como `maёana` sin que ninguno de los dos comandos informara un error. ¿Qué te dice esto sobre la fiabilidad de `file` para detectar codificaciones?
- **Q5.5** — El paso 6 tuvo éxito con ISO-8859-15 y falló con ISO-8859-1. ¿Cuál es la única diferencia práctica entre esos dos juegos de caracteres que esto demuestra?
- **Q5.6** — Distinguí, en una oración cada uno: *Unicode*, *punto de código*, *UTF-8*, *UTF-16*.

---

## Ejercicio 6 — Conversión con pérdida: `//TRANSLIT`, `//IGNORE` y `-c`

**Meta:** aprender las tres formas en que se le puede indicar a `iconv` que continúe más allá de un carácter no convertible, y qué cuesta cada una.

1. Establecé el fallo de referencia:

```bash
$ printf 'caf\xc3\xa9 10 \xe2\x82\xac\n' > mixed.txt
$ cat mixed.txt
café 10 €
$ iconv -f UTF-8 -t ASCII mixed.txt
iconv: cannot convert
$ echo $?
1
```

2. Pedí transliteración — un reemplazo de mejor esfuerzo en el juego de caracteres destino:

```bash
$ LC_ALL=en_US.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT mixed.txt
cafe 10 EUR
$ echo $?
0
```

3. Ejecutá el *mismo* comando con el locale eliminado y compará el resultado con atención:

```bash
$ LC_ALL=C iconv -f UTF-8 -t ASCII//TRANSLIT mixed.txt
caf? 10 EUR
```

4. Pedí que los caracteres problemáticos se descarten en su lugar:

```bash
$ iconv -f UTF-8 -t ASCII//IGNORE mixed.txt
caf 10 
iconv: cannot convert
$ echo $?
1

$ iconv -c -f UTF-8 -t ASCII mixed.txt
caf 10 
$ echo $?
1
```

5. Confirmá lo que realmente te costó "descartar":

```bash
$ iconv -c -f UTF-8 -t ASCII mixed.txt | hexdump -C
00000000  63 61 66 20 31 30 20 0a                           |caf 10 .|
00000008
```

6. Un flujo de reparación realista — normalizá un directorio de archivos heredados in situ, de forma segura:

```bash
$ for f in *.txt; do
>   if iconv -f ISO-8859-1 -t UTF-8 "$f" -o "$f.new"; then
>     mv -- "$f.new" "$f"
>   else
>     echo "FAILED: $f" >&2; rm -f -- "$f.new"
>   fi
> done
```

**Preguntas**

- **Q6.1** — Los pasos 2 y 3 ejecutaron un comando `iconv` idéntico y produjeron salidas distintas. ¿Qué variable de entorno causó la diferencia, y por qué la transliteración depende de ella?
- **Q6.2** — `//TRANSLIT` convirtió `é` en `e` y `€` en `EUR`. ¿Es reversible esta conversión? ¿Qué implica eso respecto de usarla sobre datos que pensás conservar?
- **Q6.3** — Tanto `//IGNORE` como `-c` descartaron caracteres. ¿Cuál es la diferencia observable entre ambos, y cuál es más peligroso dentro de un script de shell?
- **Q6.4** — En el paso 6, ¿por qué se escribe la salida en `"$f.new"` y se mueve solo en caso de éxito, en lugar de redirigir directamente sobre `"$f"`?
- **Q6.5** — ¿Qué único destino de conversión habría evitado todo el problema, y por qué no siempre está disponible?

---

## Ejercicio 7 — La base de datos de zonas horarias y `/etc/localtime`

**Meta:** mapear la maquinaria de zonas horarias en disco y cambiar la zona horaria del sistema tanto por el método moderno como por el clásico.

1. Explorá la base de datos IANA de zonas horarias tal como se distribuye:

```bash
$ ls /usr/share/zoneinfo/ | head -12
Africa
America
Antarctica
Arctic
Asia
Atlantic
Australia
Etc
Europe
Indian
Pacific
UTC
$ ls /usr/share/zoneinfo/America/Argentina/
Buenos_Aires  Catamarca  ComodRivadavia  Cordoba  Jujuy  La_Rioja  Mendoza
Rio_Gallegos  Salta  San_Juan  San_Luis  Tucuman  Ushuaia
$ file /usr/share/zoneinfo/Europe/Madrid
/usr/share/zoneinfo/Europe/Madrid: timezone data, version 2, 5 gmt time flags, \
5 std time flags, no leap seconds, 15 transition times, 5 abbreviation chars
```

2. Identificá la zona horaria del sistema a través de los dos archivos que la definen:

```bash
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug  3 11:02 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
$ cat /etc/timezone            # Debian family only
Europe/Madrid
$ date +'%Z %z'
CEST +0200
```

3. Leé el estado completo de reloj/zona horaria en un sistema systemd:

```bash
$ timedatectl
               Local time: Thu 2026-08-27 14:20:11 CEST
           Universal time: Thu 2026-08-27 12:20:11 UTC
                 RTC time: Thu 2026-08-27 12:20:11
                Time zone: Europe/Madrid (CEST, +0200)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

4. Encontrá el nombre de una zona horaria y luego cambiá la zona horaria del sistema por el método moderno:

```bash
$ timedatectl list-timezones | grep -i tokyo
Asia/Tokyo

# timedatectl set-timezone Asia/Tokyo
$ date
Thu Aug 27 09:20:33 PM JST 2026
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 30 Aug 27 21:20 /etc/localtime -> ../usr/share/zoneinfo/Asia/Tokyo
```

5. Hacé lo mismo por la vía clásica, sin systemd:

```bash
# ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
# echo 'Europe/Madrid' > /etc/timezone        # Debian family
$ date +'%Z %z'
CEST +0200
```

6. Usá el asistente interactivo — y observá que no cambia nada:

```bash
$ tzselect
Please identify a location so that time zone rules can be set correctly.
Please select a continent, ocean, "coord", "TZ" or "time":
 1) Africa
 ...
#? 8
...
You can make this change permanent for yourself by appending the line
	TZ='Asia/Tokyo'; export TZ
to the file '.profile' in your home directory; then log out and log in again.

Here is that TZ value again, this time on standard output so that you
can use the /usr/bin/tzselect command in shell scripts:
Asia/Tokyo

$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 14:21 /etc/localtime -> /usr/share/zoneinfo/Europe/Madrid
```

**Preguntas**

- **Q7.1** — ¿Qué es exactamente `/etc/localtime`, en términos de tipo de archivo y contenido? ¿Por qué se prefiere un enlace simbólico a una copia?
- **Q7.2** — `/etc/timezone` y `/etc/localtime` nombran ambos la zona horaria. ¿Cuál es el formato de cada uno, y cuál consulta realmente la biblioteca de C cuando un programa llama a `localtime()`?
- **Q7.3** — Después del paso 4, `date` imprimió `JST` aunque nada del reloj de hardware cambió. ¿Qué sí cambió?
- **Q7.4** — `tzselect` terminó e imprimió `Asia/Tokyo`, pero la zona horaria del sistema siguió en `Europe/Madrid`. Entonces, ¿para qué sirve `tzselect`?
- **Q7.5** — ¿Por qué las zonas horarias se llaman `America/Argentina/Buenos_Aires` (un lugar) y no `ART` o `UTC-3` (un desplazamiento)?

---

## Ejercicio 8 — La variable `TZ` y las zonas horarias por proceso

**Meta:** sobrescribir la zona horaria para un solo proceso sin tocar el sistema, y dominar la convención de signos POSIX de `TZ`.

1. Sobrescribí por comando, por usuario, y confirmá que no se filtra:

```bash
$ date
Thu Aug 27 02:22:05 PM CEST 2026
$ TZ='Asia/Tokyo' date
Thu Aug 27 09:22:05 PM JST 2026
$ TZ='UTC' date
Thu Aug 27 12:22:05 PM UTC 2026
$ date
Thu Aug 27 02:22:06 PM CEST 2026
```

2. Mostrá que el *instante* nunca cambió — solo su representación:

```bash
$ TZ='Asia/Tokyo' date +%s ; TZ='UTC' date +%s ; date +%s
1787833330
1787833330
1787833330
```

3. Compará varias oficinas en un mismo instante — el uso operativo clásico:

```bash
$ NOW=$(date +%s)
$ for z in UTC Europe/Madrid America/New_York Asia/Tokyo Australia/Sydney; do
>   printf '%-22s %s\n' "$z" "$(TZ=$z date -d "@$NOW" +'%F %T %Z')"
> done
UTC                    2026-08-27 12:22:10 UTC
Europe/Madrid          2026-08-27 14:22:10 CEST
America/New_York       2026-08-27 08:22:10 EDT
Asia/Tokyo             2026-08-27 21:22:10 JST
Australia/Sydney       2026-08-27 22:22:10 AEST
```

4. Ahora la forma de cadena POSIX de `TZ`, que codifica las reglas en línea en lugar de nombrar una zona. **Leé los desplazamientos con atención:**

```bash
$ TZ='UTC' date +'%H:%M %Z'
12:22 UTC
$ TZ='XXX-3' date +'%H:%M %Z'
15:22 XXX
$ TZ='XXX3' date +'%H:%M %Z'
09:22 XXX
```

5. Una cadena POSIX completa con una regla de horario de verano — nombre/desplazamiento estándar, nombre de DST y luego las fechas de transición:

```bash
$ TZ='EST5EDT,M3.2.0,M11.1.0' date +'%F %T %Z %z'
2026-08-27 08:22:15 EDT -0400
```

6. Fijate en la forma con dos puntos, que le indica a glibc que trate el valor como una ruta:

```bash
$ TZ=':/usr/share/zoneinfo/Asia/Kolkata' date +'%H:%M %Z'
17:52 IST
```

7. Persistí una zona horaria para un solo usuario, sin root:

```bash
$ echo "export TZ='Asia/Tokyo'" >> ~/.profile
```

8. Inspeccioná las reglas de transición que guarda la base de datos y localizá los cambios de horario de verano de este año:

```bash
$ zdump -v Europe/Madrid | grep 2026
Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET isdst=0 gmtoff=3600

$ zdump Asia/Kolkata
Asia/Kolkata  Thu Aug 27 17:52:20 2026 IST
```

9. Eliminá la línea que agregaste en el paso 7 antes de continuar.

**Preguntas**

- **Q8.1** — En el paso 2, tres representaciones de reloj de pared distintas produjeron un número idéntico. ¿Qué cuenta ese número, y por qué es independiente de la zona horaria?
- **Q8.2** — `TZ='XXX-3'` produjo un reloj *adelantado* respecto de UTC y `TZ='XXX3'` produjo uno *atrasado*. Enunciá la regla de signos POSIX que lo explica, y decí por qué es la opuesta al `+02:00` que ves en una marca de tiempo ISO 8601.
- **Q8.3** — Decodificá `EST5EDT,M3.2.0,M11.1.0` campo por campo.
- **Q8.4** — El 2026-10-25 el reloj local en Madrid marca `02:30`. Usando la salida de `zdump`, explicá por qué eso no es información suficiente para identificar un instante. ¿Qué ocurre en cambio a las 02:30 del 2026-03-29?
- **Q8.5** — Dá dos situaciones en las que establecer `TZ` para un solo proceso es la respuesta correcta y cambiar `/etc/localtime` sería incorrecto.

---

## Ejercicio 9 — Reloj de hardware, UTC y diagnóstico de un sistema mixto

**Meta:** conectar el RTC con el reloj del sistema y entender la decisión `UTC` frente a `LOCAL` registrada en `/etc/adjtime`.

1. Leé el reloj de hardware y compará con el reloj del sistema:

```bash
# hwclock --show
2026-08-27 14:23:40.512345+02:00
$ date
Thu Aug 27 02:23:41 PM CEST 2026
```

2. Inspeccioná cómo se le indicó al sistema que interprete el RTC:

```bash
$ cat /etc/adjtime
0.000000 1756290000 0.000000
0
UTC
$ timedatectl | grep 'RTC in local TZ'
          RTC in local TZ: no
```

3. Observá el mismo hecho desde la otra dirección:

```bash
$ timedatectl | grep -E 'RTC time|Universal time'
           Universal time: Thu 2026-08-27 12:23:45 UTC
                 RTC time: Thu 2026-08-27 12:23:45
```

4. Simulá el escenario de arranque dual y deshacelo de inmediato:

```bash
# timedatectl set-local-rtc 1
Warning: The system is configured to read the RTC time in the local time zone.
         This mode cannot be fully supported. It will create various problems
         with time zone changes and daylight saving time adjustments. ...
$ tail -1 /etc/adjtime
LOCAL

# timedatectl set-local-rtc 0
$ tail -1 /etc/adjtime
UTC
```

5. Sincronización manual en ambas direcciones, para sistemas sin `timedatectl`:

```bash
# hwclock --hctosys        # hardware clock  ->  system clock
# hwclock --systohc        # system clock    ->  hardware clock
```

**Preguntas**

- **Q9.1** — ¿Cuáles son los dos relojes distintos en juego acá, y cuál sobrevive a un corte de energía?
- **Q9.2** — La última línea de `/etc/adjtime` es `UTC`. ¿Qué se rompe si esa línea dice `LOCAL` y la máquina está en Madrid?
- **Q9.3** — ¿Por qué almacenar el RTC en UTC hace que las transiciones de horario de verano sean un no-evento, mientras que almacenarlo en hora local no?
- **Q9.4** — Distinguí `hwclock --hctosys` de `hwclock --systohc` y dá una situación para cada uno.

---

## Ejercicio 10 — Diagnosticar fallos de locale a través de SSH

**Meta:** reconocer y corregir la queja de locale más común en producción — la advertencia que aparece solo después de iniciar sesión en un host remoto.

1. Reproducí el síntoma. En el *cliente*, establecé un locale que el *servidor* no tiene generado:

```bash
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'perl -e "print qq(ok\n)"'
perl: warning: Setting locale failed.
perl: warning: Please check that your locale settings:
	LANGUAGE = (unset),
	LC_ALL = "fr_FR.UTF-8",
	LANG = "en_US.UTF-8"
    are supported and installed on your system.
perl: warning: Falling back to the standard locale ("C").
ok
```

2. Encontrá el mecanismo que transportó la variable. En el **cliente**:

```bash
$ grep -rn 'SendEnv' /etc/ssh/ssh_config /etc/ssh/ssh_config.d/ 2>/dev/null
/etc/ssh/ssh_config:52:    SendEnv LANG LC_*
```

3. Y en el **servidor**:

```bash
$ grep -rn 'AcceptEnv' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null
/etc/ssh/sshd_config:117:AcceptEnv LANG LC_*
```

4. Confirmá qué llega realmente al otro extremo:

```bash
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'locale 2>/dev/null | grep -E "LANG=|LC_ALL"'
LANG=en_US.UTF-8
LC_ALL=fr_FR.UTF-8
$ ssh user@server 'locale -a | grep -c fr_FR'
0
```

5. Aplicá la corrección correcta — generá el locale **en el servidor**:

```bash
server# sed -i 's/^# *\(fr_FR.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen
server# locale -a | grep fr_FR
fr_FR.utf8
$ LC_ALL=fr_FR.UTF-8 ssh user@server 'date'
jeu. 27 août 2026 14:25:02 CEST
```

6. Aplicá la corrección alternativa cuando no podés modificar el servidor — impedí que el cliente reenvíe:

```bash
$ ssh -o SendEnv=  user@server 'date'
Thu Aug 27 02:25:10 PM CEST 2026
```

7. Por último, blindá un script contra todos los locales de la Tierra:

```bash
$ cat > /tmp/report.sh <<'EOF'
#!/bin/bash
export LC_ALL=C.UTF-8            # stable parsing, still UTF-8 aware
ls -l --time-style=long-iso /etc/hosts | awk '{print $6, $7, $9}'
EOF
$ chmod +x /tmp/report.sh
$ LANG=es_ES.UTF-8 /tmp/report.sh
2026-08-03 11:04 /etc/hosts
```

8. Restaurá tu máquina de laboratorio:

```bash
$ diff <(locale) locale.before
# ln -sf "$(cat ~/107.3-lab/tz.before)" /etc/localtime
```

**Preguntas**

- **Q10.1** — Nada en el servidor estaba mal configurado, y nada en el cliente estaba mal configurado. ¿Dónde vive realmente la falla?
- **Q10.2** — ¿Qué dos directivas, en qué dos archivos, forman el par que transporta las variables de locale sobre SSH?
- **Q10.3** — Ordená las tres correcciones posibles (generar el locale en el servidor / quitar `SendEnv` en el cliente / quitar `AcceptEnv` en el servidor) por radio de impacto, y decí cuál elegirías en una flota de 300 servidores.
- **Q10.4** — El paso 7 establece `LC_ALL=C.UTF-8` en lugar de `LC_ALL=C`. ¿Qué gana el script, y qué conserva?
- **Q10.5** — En el paso 7 se agregó `--time-style=long-iso`. ¿Qué categoría neutraliza eso, y por qué hacerlo es más robusto que confiar solo en `LC_ALL`?

---

## Referencias

- LPI, *Exam 101 Objectives* (LPIC-1 v5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI, *Exam 102 Objectives* (LPIC-1 v5.0), objetivo 107.3 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- GNU C Library Manual, *Locales and Internationalization* — <https://www.gnu.org/software/libc/manual/html_node/Locales.html>
- GNU C Library Manual, *Specifying the Time Zone with `TZ`* — <https://www.gnu.org/software/libc/manual/html_node/TZ-Variable.html>
- GNU gettext Manual, *The `LANGUAGE` variable* — <https://www.gnu.org/software/gettext/manual/html_node/The-LANGUAGE-variable.html>
- Páginas de manual de Linux: `locale(1)`, `locale(5)`, `locale(7)`, `localedef(1)`, `iconv(1)`, `tzselect(8)`, `zdump(8)`, `hwclock(8)` — <https://man7.org/linux/man-pages/>
- IANA, *Time Zone Database* y *Theory and pragmatics of the tz code and data* — <https://www.iana.org/time-zones> y <https://data.iana.org/time-zones/theory.html>
- Proyecto systemd, `timedatectl(1)`, `localectl(1)`, `locale.conf(5)` — <https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html>
- The Unicode Consortium, *The Unicode Standard* — <https://www.unicode.org/versions/latest/>
- IETF RFC 3629, *UTF-8, a transformation format of ISO 10646* — <https://www.rfc-editor.org/rfc/rfc3629>
- Debian Reference, *Localization* — <https://www.debian.org/doc/manuals/debian-reference/ch08.en.html>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** — Las comillas indican la *procedencia*, no el valor. `locale` imprime una categoría **entre comillas** cuando su valor es heredado — de `LC_ALL` si está establecido, si no de `LANG`, si no del valor `POSIX` incorporado por defecto. Imprime el valor **sin comillas** cuando la variable de entorno propia de esa categoría (`LC_TIME` acá) está establecida explícitamente. Así que `LC_TIME="en_US.UTF-8"` significa "nadie estableció `LC_TIME`; sigue a `LANG`", mientras que `LC_TIME=en_US.UTF-8` significa "`LC_TIME` está establecida en este entorno". `LANG` y `LC_ALL` en sí siempre se imprimen en crudo.

**A1.2** — `en` es el código ISO 639 de **idioma**; `US` es el código ISO 3166 de **territorio/país**; `UTF-8` después del punto es el **codeset** (codificación de caracteres). Un `@valencia` final es el **modificador** opcional, que selecciona una variante del mismo par idioma/territorio — acá la variante ortográfica valenciana del catalán en España. La forma general es `language[_TERRITORY][.codeset][@modifier]`.

**A1.3** —
- orden alfabético usado por `sort` → `LC_COLLATE`
- símbolo de moneda → `LC_MONETARY`
- saber que `É` ↔ `é` → `LC_CTYPE`
- idioma de los mensajes de error → `LC_MESSAGES`

**A1.4** — `LC_CTYPE`. El codeset vigente es una propiedad de la categoría de clasificación de caracteres, y por eso `LC_CTYPE` es la única categoría que debés mantener en UTF-8 incluso cuando forzás todo lo demás a `C`.

### Ejercicio 2

**A2.1** — `LC_ALL` (sobrescribe todo) → la variable específica `LC_TIME` → `LANG` (el valor de reserva para toda categoría no establecida) → el valor `POSIX`/`C` incorporado por defecto si no hay ninguno establecido.

**A2.2** — `LANGUAGE` es una extensión de GNU gettext, no una categoría de locale POSIX. Influye **solo** en la selección de los catálogos de mensajes traducidos — lo mismo que gobierna `LC_MESSAGES`. El orden de los campos de fecha, los nombres de los meses y los separadores provienen de `LC_TIME`, que `LANGUAGE` no toca. `LC_ALL=en_US.UTF-8` estableció `LC_TIME` en el formato estadounidense, y `LANGUAGE=de:fr:en` redirigió únicamente la búsqueda de mensajes.

**A2.3** — Porque `LC_ALL` es una sobrescritura incondicional: una vez exportada, ningún usuario, script o aplicación puede ajustar una sola categoría — establecer `LC_TIME` o `LANG` deja de tener efecto en silencio, lo que hace que el mal comportamiento resultante sea muy difícil de diagnosticar. El valor predeterminado persistente corresponde a `LANG` (más variables `LC_*` específicas donde haga falta). Como prefijo puntual, `LC_ALL=C cmd` es exactamente lo correcto: garantiza un entorno determinista para ese único proceso y desaparece después.

**A2.4** — `LANGUAGE`, establecida con una lista de prioridad separada por dos puntos: `export LANGUAGE=fr:es:en`. Nótese que esto requiere que `LC_MESSAGES` (o `LANG`) sea algo distinto de `C`/`POSIX`, o `LANGUAGE` se ignora por completo.

### Ejercicio 3

**A3.1** — El locale `C` colaciona por **valor de byte crudo**, así que toda letra ASCII mayúscula (0x41–0x5A) se ordena antes que toda minúscula (0x61–0x7A): `Apricot`, `Banana`, luego `apple`, `cherry`. `en_US.UTF-8` colaciona según las **reglas lingüísticas** del locale (las tablas ISO 14651 de glibc): las letras se comparan primero alfabéticamente, y el caso se usa solo como criterio de desempate de menor prioridad, de modo que `apple` < `Apricot` (`app` < `apr`) < `Banana` < `cherry`.

**A3.2** — El `LC_TIME` (o `LANG`) del colega no es inglés, así que `ls` imprime una abreviatura de mes localizada (`ago`, `août`, `авг`) que nunca coincide con `"Aug"`. Corrección: forzar un locale estable para ese comando — `LC_ALL=C ls -l ...` — o, mejor, dejar de analizar `ls` y usar `ls -l --time-style=long-iso` / `stat -c '%y'`, que emiten una fecha numérica independiente del locale.

**A3.3** — (1) El separador decimal es una coma, así que un importador que espera `1234.56` lo va a leer mal o lo va a rechazar. (2) El separador de miles es un punto, y en un archivo delimitado por comas un número agrupado también puede romper el recuento de campos si el entrecomillado es imperfecto. Ambos vienen de `LC_NUMERIC` (y de `LC_MONETARY` específicamente para los valores con formato de moneda).

**A3.4** — `tr` le pregunta a la biblioteca de C qué caracteres pertenecen a las clases `upper` y `lower` y cómo se corresponden, y ese mapeo vive en `LC_CTYPE`. El juego de caracteres del locale `C` es solo ASCII, así que `Á` no es miembro de `[:upper:]` allí y no tiene correspondencia de caso — `tr` correctamente lo deja pasar sin tocarlo. No es un error: `tr` está implementando fielmente el locale que se le dio. (Una segunda consecuencia: bajo `LC_ALL=C`, `tr` además opera sobre bytes individuales, así que las secuencias multibyte de UTF-8 ni siquiera se ven como caracteres.)

### Ejercicio 4

**A4.1** — `/usr/share/i18n/locales/fr_FR` es la **definición fuente** — una especificación legible por humanos de las reglas del locale. No es utilizable en tiempo de ejecución. Debe **compilarse** contra un charmap hacia la forma binaria que carga la biblioteca de C (en `/usr/lib/locale/`, o dentro del `locale-archive`). `locale -a` lista los locales compilados/instalados; el árbol de fuentes lista lo que *podría* construirse. `locale-gen` y `localedef` tienden el puente entre ambos.

**A4.2** — `-i` nombra la **definición de locale de entrada** (un archivo bajo `/usr/share/i18n/locales`, p. ej. `fr_FR`) que aporta las reglas de idioma/territorio: colación, nombres de meses, formatos de números y de moneda. `-f` nombra el **charmap** (de `/usr/share/i18n/charmaps`, p. ej. `UTF-8`) que aporta la codificación de caracteres. Juntos producen el locale compilado, nombrado convencionalmente `fr_FR.UTF-8`.

**A4.3** — Son dos campos distintos. El primer token, `fr_FR.UTF-8`, es el **nombre** que tendrá el locale terminado (lo que los usuarios ponen en `LANG`); el segundo, `UTF-8`, es el **charmap** contra el cual compilarlo — es decir, `localedef -f UTF-8`. Suelen coincidir, pero no es obligatorio: `en_US ISO-8859-1` es una línea válida que produce un locale llamado simplemente `en_US`.

**A4.4** — `~/.bashrc` se aplica solo a las shells `bash` interactivas sin inicio de sesión de un usuario; no afecta a una sesión gráfica iniciada por un gestor de pantalla, a un servicio de `systemd`, a un trabajo de `cron` ni a programas lanzados desde un menú de escritorio. `/etc/locale.conf` (leído por systemd y aplicado al entorno de todo el sistema, incluidas las unidades de servicio y la sesión gráfica) es el lugar correcto para un valor predeterminado de todo el sistema; en Debian, `/etc/default/locale` cumple el mismo rol vía `pam_env` de PAM. Para un valor predeterminado por usuario que además cubra los inicios de sesión gráficos, `~/.profile` o `~/.config/environment.d/*.conf` es más apropiado que `~/.bashrc`.

**A4.5** — `C.UTF-8` conserva el comportamiento determinista y culturalmente neutro del locale `C` — colación por orden de bytes, `.` como punto decimal, mensajes en inglés sin traducir, salida de estilo ISO — pero establece el codeset en UTF-8, de modo que `LC_CTYPE` reconoce correctamente los caracteres multibyte. `C` es solo ASCII; `en_US.UTF-8` es UTF-8 pero impone convenciones estadounidenses y requiere que el locale haya sido generado. Para contenedores `C.UTF-8` es ideal: viene incorporado en glibc (sin paso de `locale-gen`, sin tamaño extra de imagen), produce una salida estable y analizable por máquina, y no destroza los datos no ASCII.

### Ejercicio 5

**A5.1** — UTF-8 es de ancho variable: `m`, `a`, `n`, `a` ocupan 1 byte cada una, pero `ñ` (U+00F1) necesita 2 bytes (`c3 b1`). Así que 5 letras ASCII + 1 letra de dos bytes + salto de línea = 8 bytes. ISO-8859-1 es una codificación de un solo byte de ancho fijo en la que `ñ` es un byte (`f1`), lo que da 6 + salto de línea = 7 bytes.

**A5.2** — `wc -m` cuenta **caracteres**, y qué constituye un carácter lo decide `LC_CTYPE`. Bajo `en_US.UTF-8` la biblioteca decodifica `c3 b1` como un carácter → 7. Bajo `C` el codeset es ASCII de un solo byte, así que cada byte es un carácter → 8, igual que `wc -c`. El archivo nunca cambió; cambió la interpretación.

**A5.3** — UTF-8 codifica cada punto de código U+0000–U+007F como un único byte con el valor idéntico, y garantiza que ningún byte de una secuencia multibyte cae nunca en ese rango (los bytes de continuación y de inicio tienen todos el bit alto activado). En consecuencia, cualquier archivo puramente ASCII ya es UTF-8 válido, byte por byte, y las herramientas basadas en ASCII que buscan `/`, `\0`, `\n` o `:` siguen funcionando sin modificaciones sobre datos UTF-8. Esa retrocompatibilidad —ausente en UTF-16— es la razón por la que UTF-8 pudo adoptarse de forma incremental en Unix en lugar de exigir un cambio de golpe.

**A5.4** — La codificación **no se almacena en el archivo**; un archivo de texto son solo bytes, y la codificación es metadato que el lector debe aportar por fuera. `file` solo *adivina*, a partir de heurísticas sobre qué patrones de bytes son plausibles. El byte `f1` es legal en ISO-8859-1 (`ñ`), en ISO-8859-5 (`ё`), en ISO-8859-2 (`ń`) y en decenas de otros juegos de caracteres de un solo byte, y nada en el archivo los distingue. `file` es una pista útil, nunca una autoridad. (UTF-8 es la excepción parcial: su estructura multibyte se autovalida, así que `file` puede distinguir "UTF-8 válido" de "no UTF-8" con alta confianza — pero incluso entonces no puede decirte *cuál* juego de un solo byte usa un archivo que no es UTF-8.)

**A5.5** — ISO-8859-15 (Latin-9) es una revisión de ISO-8859-1 (Latin-1) que reemplaza ocho caracteres poco usados —el más notable, el signo genérico de moneda `¤` en 0xA4— por caracteres que Europa Occidental necesitó después de 1999: el signo del euro `€` (ahora en 0xA4), más `Š š Ž ž Œ œ Ÿ`. Latin-1 es anterior al euro y sencillamente no tiene punto de código para él, así que la conversión no puede tener éxito. Esta es la lección general: un juego de caracteres heredado de un solo byte tiene solo 256 ranuras, y la conversión hacia uno falla siempre que la fuente use un carácter fuera de ese repertorio.

**A5.6** —
- **Unicode** — el estándar que asigna un número único y un conjunto de propiedades a cada carácter de cada sistema de escritura; es un *juego de caracteres*, no un formato de archivo.
- **Punto de código** — uno de esos números, escrito `U+00F1`; es una identidad abstracta, independiente de cualquier representación en bytes.
- **UTF-8** — una *codificación* de ancho variable de los puntos de código Unicode en 1–4 bytes, compatible con ASCII, independiente del orden de bytes; el estándar de facto en Linux y en la web.
- **UTF-16** — una codificación de ancho variable en 1 o 2 unidades de dieciséis bits (pares suplentes por encima de U+FFFF); no compatible con ASCII, requiere una convención de orden de bytes (BE/LE, de ahí la BOM); usada internamente por Windows y la JVM.

### Ejercicio 6

**A6.1** — `LC_ALL` (específicamente `LC_CTYPE`). La transliteración de glibc consulta las **tablas de transliteración del locale**, que viven en la definición del locale. El locale `C` prácticamente no tiene ninguna, así que glibc recurre al carácter de reemplazo por defecto `?` para `é`. Un locale UTF-8 completo aporta la regla `é → e`. (`€ → EUR` pasó en ambos casos porque ese mapeo está en la tabla de transliteración por defecto incorporada en glibc y no en una específica del locale.) Consecuencia práctica: `//TRANSLIT` no es determinista entre entornos a menos que fijes el locale.

**A6.2** — No. `cafe` y `EUR` no pueden reasignarse a `café` y `€` — la información se perdió, y la transformación ni siquiera es inyectiva (`e`, `é`, `è`, `ê` se convierten todas en `e`). Por lo tanto `//TRANSLIT` es aceptable para producir un artefacto *derivado*, solo para visualización o solo para índice (un slug ASCII, un nombre de archivo, una alimentación para un sistema heredado), pero nunca debe usarse sobre datos que pensás conservar como registro de verdad.

**A6.3** — Ambos descartan los caracteres no convertibles, así que ambos pierden datos. La diferencia observable en glibc es el **diagnóstico**: `//IGNORE` igual informa el fallo por stderr y el comando igual sale con estado distinto de cero, mientras que `-c` suprime el mensaje. `-c` es el más peligroso en un script, porque una conversión parcial silenciosa se ve exactamente igual que una exitosa en stdout — y no habría que confiar en ninguna de las dos formas sin comprobar `$?` y comparar los recuentos de caracteres. (El comportamiento del estado de salida ha variado entre versiones de glibc; verificá siempre en tu sistema destino en lugar de suponerlo.)

**A6.4** — Dos razones. Primero, `iconv -f ... "$f" > "$f"` trunca `$f` a longitud cero *antes* de que `iconv` lo abra para lectura, destruyendo la entrada — la clásica trampa de la redirección de shell. Segundo, incluso con una lectura correcta, escribir in situ significa que un fallo de conversión a mitad de flujo deja un archivo a medio convertir sin un original al que volver. Convertir hacia un archivo temporal y hacer `mv` solo en caso de éxito hace la operación atómica e idempotente: una ejecución fallida deja la fuente intacta y puede reintentarse con seguridad. (`iconv -o` evita la primera trampa pero no la segunda.)

**A6.5** — Convertir **a UTF-8** en lugar de a ASCII o a un juego heredado de un solo byte. UTF-8 puede representar todos los puntos de código Unicode, así que ningún carácter es jamás no convertible y no hace falta ninguna alternativa con pérdida. No siempre está disponible porque el *consumidor* puede estar fijo: una alimentación hacia un mainframe heredado, una interfaz EBCDIC de ancho fijo, un dispositivo antiguo que solo acepta ASCII, o un campo de protocolo definido como de un solo byte. Cuando no podés cambiar al consumidor, `//TRANSLIT` bajo un locale fijado es la opción menos mala — y la pérdida debería registrarse en el log.

### Ejercicio 7

**A7.1** — `/etc/localtime` es (o apunta a) un **archivo binario TZif** — datos de zona horaria compilados que listan las transiciones de desplazamiento UTC históricas y futuras, los indicadores de horario de verano y las abreviaturas de zona para una ubicación. La biblioteca de C lo lee cada vez que un programa convierte entre UTC y hora local. Se prefiere un enlace simbólico hacia `/usr/share/zoneinfo/` porque así la zona sigue siendo correcta automáticamente cuando se actualiza el paquete `tzdata` (los gobiernos cambian las reglas de horario de verano varias veces al año); una copia congela en silencio reglas obsoletas. Además hace que la zona actual se autodocumente: `ls -l /etc/localtime` la nombra, mientras que una copia no te dice nada.

**A7.2** — `/etc/timezone` es un archivo de **texto plano** de una línea que contiene el nombre de la zona (`Europe/Madrid`); es una convención de la familia Debian y es metadato puramente informativo para las herramientas de empaquetado. `/etc/localtime` son los **datos binarios TZif**, y es el que glibc lee realmente para `localtime()`. Si discrepan, el *comportamiento* sigue a `/etc/localtime` mientras que las *herramientas que informan la zona* pueden seguir a `/etc/timezone` — que es exactamente como una máquina termina informando una zona y usando otra. Mantenelos sincronizados; `timedatectl set-timezone` y `dpkg-reconfigure tzdata` lo hacen por vos.

**A7.3** — Solo el mapeo usado para representar un instante como texto de reloj de pared. El reloj del sistema siguió contando los mismos segundos desde la época Unix, y el RTC no se tocó. Cambiar el enlace simbólico cambió qué archivo TZif carga glibc, y por lo tanto qué desplazamiento UTC y qué abreviatura se aplican al mostrar.

**A7.4** — `tzselect` es una **ayuda de descubrimiento de solo lectura**. Te guía por continente → país → región e imprime el nombre de zona IANA correcto, sin cambiar nada deliberadamente, así que es seguro ejecutarlo como usuario sin privilegios. Después aplicás ese nombre vos mismo — `timedatectl set-timezone "$(tzselect)"`, o escribiendo el enlace simbólico. Su bloque final de "esta vez por salida estándar" existe precisamente para que pueda usarse en scripts.

**A7.5** — Porque el desplazamiento no es una propiedad estable de un lugar. `Europe/Madrid` es UTC+1 en invierno y UTC+2 en verano, y tanto las reglas de horario de verano como el desplazamiento base cambiaron repetidamente durante el último siglo — solo Argentina tiene una docena de historias de zona distintas, y por eso `America/Argentina/` tiene trece entradas. Un identificador *basado en el lugar* permite que el paquete tzdata codifique la historia completa de transiciones, de modo que las marcas de tiempo del pasado se representen correctamente y las futuras se actualicen automáticamente cuando una legislatura cambie las reglas. Un nombre basado en el desplazamiento quedaría congelado y sería incorrecto la mitad del año. Las abreviaturas como `IST` o `CST` son todavía peores: son ambiguas entre países y son solo de salida, nunca entrada válida.

### Ejercicio 8

**A8.1** — `date +%s` imprime el **tiempo Unix**: segundos transcurridos desde el 1970-01-01 00:00:00 UTC. Identifica un *instante*, y los instantes son absolutos — el mismo momento en toda la Tierra. Las zonas horarias solo afectan cómo se representa ese instante como año/mes/día/hora. Por eso todo log, marca de tiempo de base de datos e intercambio entre sistemas debería llevar UTC o tiempo Unix, y convertirse a local solo en la capa de presentación.

**A8.2** — En una cadena `TZ` POSIX, el desplazamiento es **el valor que hay que sumar a la hora local para obtener UTC** — la orientación opuesta al `±hh:mm` de ISO 8601, que es el valor que se suma a UTC para obtener la hora local. Así que `XXX-3` significa "local − (−3) = UTC", es decir, local es UTC+3 (adelantado); `XXX3` significa que local es UTC−3 (atrasado). Esta inversión de signo es la trampa clásica de `TZ`; el hábito seguro es usar nombres de zona IANA (`TZ='Europe/Madrid'`) y reservar las cadenas POSIX para el caso raro en que no aplique ningún nombre de zona.

**A8.3** —
- `EST` — abreviatura de la hora estándar.
- `5` — la hora estándar es UTC−5 (sumar 5 a la local para obtener UTC).
- `EDT` — abreviatura de la hora de verano. No la sigue ningún número, así que el desplazamiento se toma por defecto como el estándar menos una hora, es decir UTC−4.
- `M3.2.0` — el horario de verano empieza en el mes 3 (marzo), semana 2, día 0 (domingo) → el segundo domingo de marzo. Hora por defecto 02:00 local.
- `M11.1.0` — el horario de verano termina el primer domingo de noviembre, por defecto a las 02:00 locales.

**A8.4** — `zdump` muestra que a las 01:00 UTC del 2026-10-25 Madrid retrocede de CEST (+0200) a CET (+0100). El reloj de pared, por lo tanto, recorre 02:00→02:59 dos veces: una a las 00:00–00:59 UTC como CEST, otra a las 01:00–01:59 UTC como CET. La hora local `02:30` en esa fecha es **ambigua** — nombra dos instantes distintos separados por una hora, y solo el desplazamiento o el indicador `isdst` los desambigua. La transición de marzo es la imagen especular: a las 01:00 UTC el reloj salta de 02:00 a 03:00, así que las horas locales de 02:00 a 02:59 del 2026-03-29 **no existen**; un programa al que se le pida analizar `02:30` allí debe rechazarla o normalizarla (`date` de GNU la normaliza). Ambos casos son la razón por la que las marcas de tiempo almacenadas deberían ser UTC y por la que "hora local + fecha" nunca es una clave primaria válida.

**A8.5** — Cualquiera de estas:
- Generar un informe o una factura que debe representarse en la zona horaria de un cliente o de una sucursal, mientras el servidor en sí permanece en UTC.
- Reproducir un error que solo se manifiesta en una zona en particular (frontera de horario de verano, desplazamiento de media hora como `Asia/Kolkata`, una zona que cruzó la línea de cambio de fecha).
- Ejecutar un trabajo por lotes cuyo calendario está definido en una zona horaria comercial sobre un host configurado en UTC.
- Comparar marcas de tiempo de logs de un sistema remoto que informa hora local.

En todos estos casos la zona horaria del *sistema* debe seguir siendo aquella de la que dependen las operaciones y el registro de logs; cambiar `/etc/localtime` reescribiría en silencio la representación de todos los demás servicios de la máquina, incluidos el journal del sistema y la interpretación de los horarios por parte de cron.

### Ejercicio 9

**A9.1** — El **reloj de hardware** (RTC / reloj CMOS), un contador respaldado por batería en la placa madre que sigue funcionando con la máquina apagada; y el **reloj del sistema**, mantenido por el kernel en memoria, inicializado desde el RTC en el arranque y disciplinado luego por NTP. Solo el RTC sobrevive a un corte de energía.

**A9.2** — El valor almacenado en el RTC pasa entonces a interpretarse como hora de reloj de pared de Madrid en lugar de UTC, y el kernel aplica el desplazamiento de zona horaria en el arranque para derivar UTC. Rotura concreta: si esa suposición es incorrecta, el reloj del sistema queda desfasado por el desplazamiento actual (1–2 horas), lo que se propaga en fallos de validación de certificados TLS, rechazo de tickets Kerberos, `make` reconstruyendo todo o nada, y marcas de tiempo de log que no se correlacionan entre hosts. Incluso cuando el ajuste *coincide* con la realidad, las transiciones de horario de verano se vuelven un problema activo — ver A9.3.

**A9.3** — UTC no tiene horario de verano; avanza monotónicamente. Un RTC en UTC, por lo tanto, no necesita ajuste cuando cambian los relojes — solo cambia el mapeo de visualización. Un RTC en hora local debe reescribirse físicamente en cada transición, y eso crea dos modos de fallo que el sistema no puede resolver por sí solo: durante el solapamiento de otoño el valor almacenado es **ambiguo** (la misma hora local ocurre dos veces, así que una máquina arrancada en esa ventana no puede saber cuál es), y una máquina apagada a lo largo de una transición no tiene ocasión alguna de hacer el ajuste. Por eso `timedatectl set-local-rtc 1` imprime una advertencia explícita de que el modo "cannot be fully supported"; la única justificación real es un arranque dual con una instalación de Windows antigua que asume hora local.

**A9.4** — `hwclock --hctosys` copia **hardware → sistema**: usalo en el arranque en una máquina sin red/NTP, o después de reemplazar la batería del RTC y ajustar el RTC desde el firmware. `hwclock --systohc` copia **sistema → hardware**: usalo después de corregir el reloj del sistema (manualmente o vía NTP) para que el valor bueno sobreviva al siguiente ciclo de encendido — tradicionalmente se ejecuta al apagar. Los sistemas que ejecutan `systemd-timesyncd` o `chronyd` normalmente gestionan `--systohc` automáticamente.

### Ejercicio 10

**A10.1** — En la **combinación**, no en ninguno de los dos extremos. El cliente declara legítimamente su locale; el servidor legítimamente no tiene generados todos los locales de la Tierra. El par `SendEnv`/`AcceptEnv` de SSH los une, y el desajuste aflora solo en el servidor, al iniciar el proceso, cuando `setlocale()` falla y la biblioteca recurre a `C`. Nada está roto aisladamente — que es exactamente por qué el reporte suele ser "solo pasa cuando entro por SSH".

**A10.2** — `SendEnv LANG LC_*` en el `/etc/ssh/ssh_config` (o `~/.ssh/config`) del **cliente**, y `AcceptEnv LANG LC_*` en el `/etc/ssh/sshd_config` del **servidor**. Ambos son necesarios: el cliente debe ofrecer las variables y el servidor debe aceptarlas.

**A10.3** — De menor a mayor radio de impacto:
1. **Generar el locale en el servidor** — afecta solo a ese host, corrige el problema como corresponde para todos los usuarios y deja el locale de cada uno funcionando como se pretendía. Correcto en principio.
2. **Quitar `SendEnv` en el cliente** — afecta solo a ese cliente, pero rompe el locale del cliente en *todos* los servidores a los que se conecte, incluidos aquellos donde funcionaba.
3. **Quitar `AcceptEnv` en el servidor** — afecta a todos los usuarios de ese servidor, degradándolos a todos en silencio al locale predeterminado del servidor.

En 300 servidores, no hagas nada de esto a mano. Estandarizá el conjunto de locales de la flota mediante gestión de configuración (Ansible/Puppet/construcción de imagen) — generando `en_US.UTF-8` más `C.UTF-8` en todas partes, o, en una flota basada en contenedores, estandarizando en `C.UTF-8`, que no necesita generación en absoluto. La corrección por host es la correcta; hacerla 300 veces a mano no lo es.

**A10.4** — **Gana** determinismo: colación por orden de bytes, `.` como separador decimal, mensajes en inglés sin traducir y formato independiente del locale, de modo que las posiciones de campo de `awk` y cualquier coincidencia de cadenas se comportan de forma idéntica en toda máquina donde aterrice el script. **Conserva** el manejo de caracteres UTF-8, así que los nombres de archivo, las líneas de log y los datos de usuario que contengan caracteres no ASCII se siguen procesando como caracteres en lugar de quedar destrozados en bytes individuales — lo que un `LC_ALL=C` a secas sacrificaría.

**A10.5** — Neutraliza `LC_TIME`. Confiar solo en `LC_ALL` es más frágil porque depende de que el entorno sobreviva intacto hasta el proceso hijo — un wrapper, un `sudo` con `env_reset`, un `Environment=` de una unidad de `systemd`, un `LC_*` reenviado por SSH o el entorno mínimo de un trabajo de `cron` pueden cada uno sobrescribirlo o descartarlo. `--time-style=long-iso` le pide directamente a `ls` un formato inequívoco `YYYY-MM-DD HH:MM`, así que la salida es correcta sin importar qué locale llegue realmente al proceso. Cinturón y tiradores: establecé el locale *y* pedí formatos explícitos, y donde sea posible evitá analizar salida orientada a humanos por completo (`stat -c`, `find -printf`, `date -u +%s`).

</details>