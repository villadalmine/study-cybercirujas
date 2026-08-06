# 1.3 GNU and Unix Commands

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En arquitecturas distribuidas modernas, un Site Reliability Engineer (SRE) o Platform Architect se enfrenta constantemente a la necesidad de procesar terabytes de telemetr\u00eda (logs, m\u00e9tricas) y transformar formatos de datos estructurados en tiempo real. Aunque disponemos de stacks complejos de observabilidad (Elastic, Splunk, Loki), a menudo la primera l\u00ednea de defensa durante un incidente cr\u00edtico o un "Sev-1" ocurre directamente en la terminal de un nodo degradado, donde estas plataformas centralizadas pueden estar indisponibles o saturadas.

El problema arquitect\u00f3nico es el procesamiento de *data streams* (flujos de datos). Las herramientas GNU/Unix no son simples utilidades aisladas; forman un pipeline de procesamiento funcional puro basado en el est\u00e1ndar POSIX. Su dise\u00f1o, donde la salida est\u00e1ndar (`stdout`) de un comando alimenta la entrada est\u00e1ndar (`stdin`) del siguiente mediante *pipes* (`|`), permite ensamblar soluciones de parseo complejas (filtrado con `grep`, transformaci\u00f3n con `sed`/`awk`, ordenamiento con `sort`, y agregaci\u00f3n con `uniq`) con un overhead m\u00ednimo en memoria, algo cr\u00edtico cuando se analizan archivos de log masivos en servidores de producci\u00f3n que ya est\u00e1n bajo estr\u00e9s (Out of Memory risks).

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Procesamiento de Texto: grep vs sed vs awk

| Herramienta | Caso de Uso Principal | Complejidad / Curva de Aprendizaje | Rendimiento (I/O & CPU) |
| :--- | :--- | :--- | :--- |
| **`grep` (y `egrep`)** | Filtrado est\u00e1tico. Encontrar l\u00edneas que hacen *match* con un patr\u00f3n o Regex. | Baja. Sintaxis declarativa pura. | Muy r\u00e1pido. Optimizado para bypass de buffers usando algoritmos como Boyer-Moore. |
| **`sed` (Stream Editor)** | Sustituci\u00f3n y manipulaci\u00f3n de streams al vuelo (find & replace, borrado condicional). | Media. Lenguaje imperativo, altamente cr\u00edptico (ej. *hold spaces*). | R\u00e1pido. Procesa l\u00ednea por l\u00ednea sin cargar el archivo completo en memoria. |
| **`awk`** | Procesamiento de datos tabulares (columnas), aritm\u00e9tica b\u00e1sica, reportes y estados entre l\u00edneas. | Alta. Es un lenguaje de programaci\u00f3n Turing completo impulsado por eventos. | Moderado. Mayor overhead que `grep` pero infinitamente m\u00e1s r\u00e1pido que scripts Python para tareas ETL simples. |

### Redirecci\u00f3n y Flujos: Pipes (`|`) vs. Archivos Temporales

| Arquitectura de Datos | Pipes / FIFOs (`|`, `mkfifo`) | Archivos Temporales (`> /tmp/dump.txt`) |
| :--- | :--- | :--- |
| **I/O Overhead** | Nulo. Ocurre estrictamente en memoria (kernel buffers). | Alto. Depende del ancho de banda y latencia del block device (Disk I/O). |
| **Paralelismo** | Ejecuci\u00f3n as\u00edncrona concurrente de los procesos involucrados. | Secuencial estricta. |
| **Riesgo en Producci\u00f3n** | Menor riesgo de agotar espacio en disco (filesystem filling). | Riesgo de llenar `/` o `/tmp`, causando ca\u00eddas en cadena de otros servicios locales. |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

En entornos Cloud, utilizamos comandos GNU frecuentemente dentro de scripts de inicializaci\u00f3n o *sidecars* de contenedores para ajustar configuraciones din\u00e1micamente antes del inicio del proceso principal (entrypoint).

### Configuraci\u00f3n: Script de Entrypoint en Kubernetes (`entrypoint.sh`)

Este script demuestra el uso avanzado de `sed`, variables de entorno (`env`) y comandos b\u00e1sicos para inyectar configuraci\u00f3n en runtime, previniendo que los contenedores arranquen con variables vac\u00edas.

```bash
#!/usr/bin/env bash
set -eo pipefail # Fail fast y propagar errores a trav\u00e9s de pipes

# 1. Validaci\u00f3n condicional y sustituci\u00f3n (Variable Expansion de shell)
export APP_ENV="${APP_ENV:-production}"
export DB_PORT="${DB_PORT:-5432}"

if [ -z "${DB_HOST}" ]; then
  echo "[FATAL] La variable DB_HOST no est\u00e1 definida. Abortando inicio." >&2
  exit 1
fi

# 2. Reemplazo in-place con sed en el archivo de configuraci\u00f3n est\u00e1tico
# Usamos delimitadores alternativos '#' en sed para evitar escapar las barras '/' de las URLs
sed -i -e "s#{{DB_HOST}}#${DB_HOST}#g" \
       -e "s#{{DB_PORT}}#${DB_PORT}#g" /etc/myapp/config.yaml

# 3. Validaci\u00f3n del payload modificado usando grep
if grep -q "{{DB_" /etc/myapp/config.yaml; then
   echo "[ERROR] Fall\u00f3 el reemplazo. A\u00fan existen placeholders sin resolver." >&2
   exit 1
fi

# 4. Sustituci\u00f3n del proceso actual (PID 1) usando exec
exec /usr/local/bin/myapp-binary --config /etc/myapp/config.yaml
```

## 4. Comandos CLI y Salidas de Terminal Reales

### An\u00e1lisis Forense con awk y sort

En un escenario de ataque de denegaci\u00f3n de servicio (DDoS) o un pico an\u00f3malo de tr\u00e1fico, un SRE debe parsear un `access.log` crudo instant\u00e1neamente.

```bash
# Extraer las 5 IPs que han generado m\u00e1s tr\u00e1fico (asumiendo que la IP est\u00e1 en la columna 1)
# $ awk '{print $1}' : Imprime la primera columna.
# $ sort : Ordena alfab\u00e9ticamente (requerido antes de uniq).
# $ uniq -c : Cuenta ocurrencias consecutivas.
# $ sort -nr : Ordena num\u00e9ricamente en orden reverso (descendente).
# $ head -n 5 : Devuelve el Top 5.

$ awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -nr | head -n 5
  45210 192.168.1.104
  12045 10.0.0.5
    804 172.16.0.2
    150 192.168.1.200
     12 127.0.0.1
```

### Manipulaci\u00f3n Avanzada con sed y Expresiones Regulares Extendidas (egrep)

```bash
# Buscar errores cr\u00edticos ("FATAL" o "ERROR" seguido de un c\u00f3digo num\u00e9rico) en m\u00faltiples archivos
$ egrep -Hn "(FATAL|ERROR).*code:[0-9]{3}" /var/log/app/*.log
/var/log/app/backend.log:45:[ERROR] connection timeout code:504
/var/log/app/worker.log:102:[FATAL] database lock error code:101

# Eliminar comentarios y l\u00edneas vac\u00edas de un archivo de configuraci\u00f3n para leerlo limpio
# -e '/^#/d' elimina l\u00edneas que empiezan con #. -e '/^$/d' elimina l\u00edneas vac\u00edas.
$ sed -e '/^#/d' -e '/^$/d' /etc/ssh/sshd_config | head -n 4
Include /etc/ssh/sshd_config.d/*.conf
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
```

### Transformaci\u00f3n de Archivos (tr y cut)

```bash
# Transformar un string delimitado por comas (CSV) extrayendo campos espec\u00edficos (cut)
# Y luego pasar todo a min\u00fasculas (tr)
$ echo "USER_ID,NAME,EMAIL,ROLE" > data.csv
$ echo "1001,John Doe,J.DOE@COMPANY.COM,ADMIN" >> data.csv

# Extraer el campo 3 (EMAIL), omitiendo el header, y pasar a lower-case
$ tail -n +2 data.csv | cut -d',' -f3 | tr '[:upper:]' '[:lower:]'
j.doe@company.com
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Broken Pipes (`SIGPIPE`)**:
   En pipelines largos (`cat huge.log | grep "error" | head -n 1`), cuando el \u00faltimo comando (`head`) finaliza tras leer su primera l\u00ednea, cierra su *stdin*. El comando previo (`grep`) intenta escribir en el pipe cerrado, recibiendo una se\u00f1al `SIGPIPE` del kernel. En terminales interactivos se ignora, pero en scripts bash estrictos (`set -eo pipefail`) esto puede hacer que el script falle inesperadamente con c\u00f3digo de salida `141`.
   *Resoluci\u00f3n:* Manejar el error expl\u00edcitamente o evitar `set -o pipefail` en secciones de c\u00f3digo que intencionalmente truncan pipelines de lectura infinita.

2. **Inconsistencias por el Entorno (`Locale` issues)**:
   Comandos como `sort`, `sed`, y `grep` son extremadamente sensibles a la variable de entorno `LANG` o `LC_ALL`. Un archivo ordenado en un locale puede no coincidir en otro.
   *Diagn\u00f3stico:* Ejecuta `locale`.
   *Resoluci\u00f3n:* Para asegurar un ordenamiento binario estricto (y un boost de performance gigante en *regex*), antepone `LC_ALL=C` al comando:
   `$ LC_ALL=C sort file.txt > sorted.txt`

3. **Limitaciones de Argumentos (Argument list too long)**:
   Expandir miles de archivos con `rm /var/log/*.log` puede exceder el l\u00edmite de argumentos del kernel `ARG_MAX`.
   *Resoluci\u00f3n:* Utilizar la redirecci\u00f3n de entrada de comandos xargs combinada con un iterador find:
   `$ find /var/log -name "*.log" -print0 | xargs -0 rm`

## 6. Referencias

* LPIC-1 Objetivos (Topic 103): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* GNU Coreutils Manual: [https://www.gnu.org/software/coreutils/manual/coreutils.html](https://www.gnu.org/software/coreutils/manual/coreutils.html)
* AWK User's Guide (GNU Awk): [https://www.gnu.org/software/gawk/manual/gawk.html](https://www.gnu.org/software/gawk/manual/gawk.html)
* Sed - An Introduction and Tutorial: [https://www.gnu.org/software/sed/manual/sed.html](https://www.gnu.org/software/sed/manual/sed.html)