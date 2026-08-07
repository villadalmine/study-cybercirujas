# LPI-702 (Exam 702-100, Version 1.0)
## Tema 713.6: Administrar la impresión y los trabajos de impresión
**Peso:** 1.67  
**Referencia oficial:** [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

### Contexto técnico profundo y visión general arquitectónica

La arquitectura de impresión BSD se basa ya sea en el tradicional Line Printer Daemon (`lpd(8)`) que opera sobre el protocolo Berkeley LPR ([RFC 1179](https://datatracker.ietf.org/doc/html/rfc1179)) o en infraestructuras modernas de spooling de impresión como CUPS (Common UNIX Printing System) que utilizan IPP (Internet Printing Protocol).

#### 1. La arquitectura y mecánica del LPD BSD tradicional

```
                      +-------------------+
                      |      user         |
                      +---------+---------+
                                |
                                v
                      +-------------------+
                      |  lpr(1) utility   |
                      +---------+---------+
                                |
               Reads /etc/printcap & creates spool files
                                |
                                v
               +----------------------------------+
               | Spool Dir: /var/spool/output/lp  |
               |  - Data file:    dfA001hostname  |
               |  - Control file: cfA001hostname  |
               |  - Lock file:    lock            |
               +----------------+-----------------+
                                |
                                v
                      +-------------------+
                      |      lpd(8)       |
                      +---------+---------+
                                |
                Executes Input/Output Filters
                                |
                                v
            +---------------------------------------+
            |  if (input filter) / of (out filter) |
            |    Translates text/PostScript to RAW   |
            +-------------------+-------------------+
                                |
             +------------------+------------------+
             |                                     |
      Local Device                          Remote LPD Server
  (e.g., /dev/lpt0, /dev/ulpt0)              (RFC 1179 Port 515)
```

1. **Envío de trabajos de cliente (`lpr(1)`):**
   Cuando un usuario ejecuta `lpr -P printer_name file.ps`, `lpr` lee `/etc/printcap` para resolver las rutas del directorio de spool (`sd`) y las definiciones de destino remoto (`rm`/`rp`). Escribe dos archivos de spool temporales en el directorio de spool de destino:
   - **Archivo de datos (`dfA<jobid><hostname>`):** Contiene la carga útil de impresión RAW (PostScript, texto plano, PCL, etc.).
   - **Archivo de control (`cfA<jobid><hostname>`):** Contiene instrucciones de metadatos como el propietario del trabajo (`P`), el nombre del trabajo (`J`), la clasificación (`C`), la especificación de formato (`f` para texto plano, `l` para binario/raw, `p` para texto formateado) y la referencia al archivo de datos de destino (`U`/`N`).

2. **Procesamiento del demonio (`lpd(8)`):**
   `lpd` detecta nuevos archivos `cf*` a través de `kqueue(2)` o escaneos periódicos del spool. Abre un archivo de bloqueo (`lock`) en el directorio de spool para evitar que subprocesos (threads) de trabajo concurrentes procesen la misma cola.
   - Para salida física local: `lpd` canaliza (pipes) la carga útil a través del filtro de entrada (`if`) o filtro de salida (`of`) definido en `/etc/printcap` para manejar el enmarcado de página, la conversión de salto de línea (`LF` a `CR+LF`) o la rasterización.
   - Para impresión remota: `lpd` establece una conexión TCP al puerto **515** en el servidor de impresión de destino, iniciando el saludo (handshake) RFC 1179.

3. **Control de colas (`lpc(8)`):**
   `lpc` modifica los flags de estado de la cola escribiendo archivos de control de estado (`status`) dentro del directorio de spool o comunicándose con `lpd` a través de sockets de dominio UNIX (`/var/run/printer`).
   - `disable`: Bloquea `lpr` para que no coloque nuevos archivos `cf*`/`df*` en el spool.
   - `stop`: Detiene `lpd` para que no desentrampe (dequeue) ni envíe trabajos existentes al filtro/dispositivo.
   - `enable` / `start`: Reactiva el spooling y el procesamiento respectivamente.

---

#### 2. Análisis profundo: esquema de capacidades de `/etc/printcap`

El archivo `/etc/printcap` utiliza una sintaxis de capacidades separadas por dos puntos (`cap=value` o flags booleanos `:flag:`).

| Capacidad | Tipo | Descripción técnica e impacto en producción |
| :--- | :--- | :--- |
| `lp` | String | Nodo de dispositivo de caracteres para conexión física directa (por ejemplo, `/dev/lpt0`, `/dev/unlpt0`). Si se establece vacío (`lp=`), la cola se designa como remota o vinculada a la red. |
| `sd` | Path | Ruta del directorio de spool (por ejemplo, `/var/spool/output/lp1`). Debe existir con permisos `0770` y propiedad `daemon:daemon` o `root:daemon`. |
| `rm` | String | Nombre de dominio o dirección IP del host remoto para impresión en red RFC 1179. |
| `rp` | String | Nombre de la cola/impresora remota en el servidor de impresión RFC 1179 de destino. |
| `if` | Path | Ruta absoluta al ejecutable del **Input Filter** (filtro de entrada). Filtra la entrada una vez por trabajo de impresión. Recibe la entrada estándar desde `df*` y envía el flujo transformado a `lp`. |
| `of` | Path | Ruta absoluta al ejecutable del **Output Filter** (filtro de salida). Se utiliza para la generación de banners y el manejo multiplexado de trabajos. Se ejecuta de forma persistente a través de los límites de banner/datos. |
| `lf` | Path | Archivo de registro (log) para mensajes de error del demonio asociados con la cola (por ejemplo, `/var/log/lpd-errs`). |
| `af` | Path | Ruta del archivo de log de contabilidad (accounting) para realizar el seguimiento del conteo de páginas de los usuarios. |
| `mx` | Numeric | Tamaño máximo del archivo de trabajo en bloques de 512 bytes. Establezca `mx#0` para permitir tamaños de trabajo ilimitados en producción. |
| `sh` | Flag | Suppress Header (suprimir encabezado). Desactiva la impresión de páginas de portada/banner por defecto (`:sh:`). |
| `rg` | String | Restricted Group (grupo restringido). Restringe el uso de `lpr` para esta cola a los usuarios del grupo del sistema especificado. |

---

### Ejercicios prácticos guiados

#### Ejercicio 1: Configuración avanzada de `/etc/printcap`, filtrado personalizado e inicialización del demonio

##### Objetivo
Construir una entrada de `/etc/printcap` de grado de producción y sintácticamente válida que cuente con un filtro de entrada (`if`) para la traducción de texto plano a PostScript, configurar permisos de directorio estrictos e inicializar `lpd(8)`.

##### Pasos de ejecución

1. Crear el directorio de spool y los archivos de log con permisos de sistema estrictos para la ejecución del demonio:
```bash
sudo mkdir -p /var/spool/output/acct_print
sudo touch /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
sudo chown -R daemon:daemon /var/spool/output/acct_print
sudo chmod 0770 /var/spool/output/acct_print
sudo chown daemon:daemon /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
sudo chmod 0640 /var/log/lpd-acct_print.log /var/log/lpd-acct_audit.log
```

2. Crear un filtro de entrada de shell personalizado `/usr/local/libexec/ps_filter.sh` para desinfectar el texto y anteponer una línea de banner con marca de tiempo:
```bash
sudo mkdir -p /usr/local/libexec
cat << 'EOF' | sudo tee /usr/local/libexec/ps_filter.sh > /dev/null
#!/bin/bin/sh
# Input filter: Read stdin, append audit info, send to device/output stream
LOGGER="/usr/bin/logger -t lpd_filter"
$LOGGER "Processing job submission..."
# Accounting log entry: append user timestamp
echo "$(date '+%Y-%m-%d %H:%M:%S') - Printed job" >> /var/log/lpd-acct_audit.log
# Pass standard input directly to standard output
cat
exit 0
EOF
sudo chmod 0755 /usr/local/libexec/ps_filter.sh
```

3. Configurar `/etc/printcap` definiendo tanto una cola primaria como una cola alias:
```bash
cat << 'EOF' | sudo tee -a /etc/printcap > /dev/null
# Production Accounting Printer Configuration
acct_print|ap|Accounting HP LaserJet:\
	:lp=/dev/null:\
	:sd=/var/spool/output/acct_print:\
	:lf=/var/log/lpd-acct_print.log:\
	:af=/var/log/lpd-acct_audit.log:\
	:if=/usr/local/libexec/ps_filter.sh:\
	:mx#0:\
	:sh:
EOF
```

4. Verificar la sintaxis de `/etc/printcap` y comprobar la disponibilidad del demonio usando `lpc`:
```bash
sudo lpc status acct_print
```

**Salida esperada:**
```
acct_print:
	queuing is enabled
	printing is enabled
	no entries in spool area
	daemon present
```

5. Habilitar `lpd` en `/etc/rc.conf` y reiniciar el servicio:
```bash
sudo sysrc lpd_enable="YES"
sudo service lpd restart
```

**Salida esperada:**
```
lpd_enable: NO -> YES
Stopping lpd.
Starting lpd.
```

---

##### Preguntas de verificación - Bloque 1

**Pregunta 1.1:** En una entrada de `/etc/printcap`, ¿cuál es la diferencia operativa entre configurar `:mx#0:` en comparación con omitir la capacidad `mx` por completo?  
**Pregunta 1.2:** Si los permisos de `/var/spool/output/acct_print` se establecen en `0777` (escritura para todos), ¿qué vulnerabilidad de seguridad y anomalía operativa pueden ocurrir dentro del subsistema de spooling `lpd` de BSD?

---

#### Ejercicio 2: Análisis de spool a bajo nivel, ciclo de vida de archivos y gestión de colas a través de `lpc`

##### Objetivo
Simular la encolación de trabajos de impresión, pausar el procesamiento usando `lpc`, disecar los archivos de control (`cf*`) y datos (`df*`), analizar el mecanismo de bloqueo del spool y gestionar trabajos utilizando `lpq` y `lprm`.

##### Pasos de ejecución

1. Detener el procesamiento de la cola de impresión (desencolado) manteniendo habilitado el envío de trabajos (encolado):
```bash
sudo lpc stop acct_print
```

**Salida esperada:**
```
acct_print:
	printing disabled
```

2. Enviar un trabajo de impresión a la cola detenida utilizando `lpr(1)` con flags de metadatos personalizados (`-J` para el nombre del trabajo, `-C` para la clasificación):
```bash
echo "CONFIDENTIAL FINANCIAL REPORT - Q3" | lpr -Pacct_print -J "q3_report.txt" -C "FINANCE"
```

3. Listar el contenido del directorio de spool para observar los archivos `cf*`, `df*` y de estado de bloqueo generados:
```bash
sudo ls -l /var/spool/output/acct_print
```

**Salida esperada:**
```
total 8
-rw-r-----  1 daemon  daemon   122 Aug  6 20:50 cfA001hostname
-rw-r-----  1 daemon  daemon    35 Aug  6 20:50 dfA001hostname
-rw-r--r--  1 daemon  daemon    33 Aug  6 20:50 status
```

4. Inspeccionar el contenido RAW del archivo de control (`cfA*`):
```bash
sudo cat /var/spool/output/acct_print/cfA*
```

**Salida esperada:**
```
Hhostname
Pusername
Jq3_report.txt
CFINANCE
Lusername
fdfA001hostname
UdfA001hostname
Nq3_report.txt
```

5. Consultar el estado de la cola de impresión activa utilizando `lpq(1)`:
```bash
lpq -Pacct_print
```

**Salida esperada:**
```
Rank   Owner      Job  Files                                 Total Size
1st    username   1    q3_report.txt                         35 bytes
```

6. Cancelar el trabajo de impresión encolado utilizando `lprm(1)` especificando el ID del trabajo:
```bash
lprm -Pacct_print 1
```

**Salida esperada:**
```
dfA001hostname dequeued
cfA001hostname dequeued
```

7. Volver a habilitar el procesamiento de la cola de impresión:
```bash
sudo lpc start acct_print
```

**Salida esperada:**
```
acct_print:
	printing enabled
	daemon started
```

---

##### Preguntas de verificación - Bloque 2

**Pregunta 2.1:** ¿Qué representan las líneas de control `H`, `P`, `J`, `C` y `f` dentro de un archivo de control BSD LPD (`cfA*`)?  
**Pregunta 2.2:** Si un administrador ejecuta `lpc disable acct_print`, ¿cuál es el comportamiento exacto del sistema cuando un usuario que no es root ejecuta `lpr -Pacct_print test.txt`?

---

#### Ejercicio 3: Impresión en red (RFC 1179 / IPP), integración con CUPS y diagnóstico

##### Objetivo
Configurar una cola de impresora de red remota utilizando la sintaxis de RFC 1179, inspeccionar las comunicaciones de red mediante `tcpdump` y realizar la administración del spool multiplataforma utilizando `lpadmin` y `lpstat`.

##### Pasos de ejecución

1. Agregar una configuración de impresora de red remota a `/etc/printcap` apuntando a un servidor de impresión empresarial o puerta de enlace jetdirect (`rm` = remote machine, `rp` = remote printer):
```bash
cat << 'EOF' | sudo tee -a /etc/printcap > /dev/null

# Remote RFC 1179 Network Printer Queue
net_laser|Remote Network HP LaserJet:\
	:lp=:\
	:rm=192.168.100.50:\
	:rp=raw:\
	:sd=/var/spool/output/net_laser:\
	:lf=/var/log/lpd-errs:\
	:mx#0:\
	:sh:
EOF
```

2. Crear el directorio de spool remoto y asignar los permisos correctos:
```bash
sudo mkdir -p /var/spool/output/net_laser
sudo chown daemon:daemon /var/spool/output/net_laser
sudo chmod 0770 /var/spool/output/net_laser
```

3. Simular la administración de CUPS utilizando comandos estándar IPP/CUPS (`lpadmin`, `lpstat`). Comprobar los destinos IPP existentes:
```bash
lpstat -p -d
```

**Salida esperada:**
```
no system default destination
system host printer status: idle
```

4. Configurar una cola IPP de CUPS mediante programación utilizando `lpadmin`:
```bash
sudo lpadmin -p Enterprise_Color -E -v ipp://192.168.100.55/ipp/print -m raw
sudo lpadmin -d Enterprise_Color
```

5. Verificar el destino por defecto y el estado de la cola con `lpstat`:
```bash
lpstat -s
```

**Salida esperada:**
```
system default destination: Enterprise_Color
device for Enterprise_Color: ipp://192.168.100.55/ipp/print
```

6. Realizar una captura de diagnóstico de red en vivo en LPD (puerto 515) o IPP (puerto 631) usando `tcpdump`:
```bash
sudo tcpdump -ni lo0 port 515 or port 631 -c 5
```

---

##### Preguntas de verificación - Bloque 3

**Pregunta 3.1:** ¿Cuál es la diferencia principal entre cómo el `lpd(8)` heredado procesa los trabajos de impresión remotos a través de `:rm:`/`:rp:` en comparación con cómo CUPS enruta los trabajos a través de especificaciones URI de IPP (`ipp://`)?  
**Pregunta 3.2:** Si `lpq` informa `warning: net_laser: connection refused` al enviar un trabajo a una impresora remota configurada con `:rm=192.168.100.50:`, ¿qué pasos y comandos de diagnóstico se deben ejecutar para aislar la causa raíz?

---

<details>
<summary>Respuestas y explicaciones detalladas</summary>

### Respuestas y explicaciones detalladas

#### Respuestas del Bloque 1

**Respuesta 1.1:**
- **`:mx#0:`**: Establece el límite de tamaño máximo de archivo de impresión en **ilimitado** (0 bloques). Esto es obligatorio para gráficos de producción, archivos CAD o grandes flujos de PDF.
- **Omitting `mx`**: Por defecto, establece un límite máximo de tamaño de archivo de **1000 bloques** (aprox. 500 KB). Cualquier trabajo de impresión enviado a través de `lpr` que supere este umbral será truncado o rechazado con un error de spool `file too large`.

**Respuesta 1.2:**
- **Riesgos de seguridad e integridad:** Establecer los permisos del directorio de spool en `0777` permite que usuarios locales no privilegiados inspeccionen, modifiquen o eliminen archivos `df*` y `cf*` propiedad de otros usuarios, violando la confidencialidad.
- **Anomalías operativas:** `lpd(8)` aplica comprobaciones de sanidad internas sobre la propiedad y los permisos del directorio de spool. Si se puede escribir en él públicamente (world-writable) o si es propiedad de un usuario no privilegiado, `lpd` puede negarse a procesar trabajos en esa cola, registrando errores de `unsecure spool directory` en el archivo de registro definido en `:lf:`. Los directorios de spool deben cumplir estrictamente con la propiedad `0770` o `0750` (`daemon:daemon` o `root:daemon`).

---

#### Respuestas del Bloque 2

**Respuesta 2.1:**
Los campos del archivo de control en `cfA*` dictan los parámetros de ejecución para `lpd`:
- `H`: **Nombre del host** de la máquina cliente que envía el trabajo.
- `P`: **ID de persona/usuario** de quien envía el trabajo (utilizado para contabilidad y validación de propiedad).
- `J`: Cadena con el **nombre del trabajo** que se muestra en `lpq` y en las páginas de banner.
- `C`: Cadena de **clase / clasificación** impresa en las hojas de portada/banner (por ejemplo, `FINANCE`, `TOP SECRET`).
- `f`: **Especificación del formato de archivo** que indica que el archivo de datos de destino (`dfA*`) es un archivo de texto plano que se procesará a través del filtro de entrada estándar (`if`).

**Respuesta 2.2:**
- `lpc disable acct_print` establece explícitamente el **flag de encolado** como deshabilitado en el archivo `status` de la cola.
- Cuando un usuario ejecuta `lpr -Pacct_print test.txt`, `lpr` intenta copiar archivos en `/var/spool/output/acct_print`. Al leer el archivo de estado, `lpr` falla inmediatamente e imprime un error en `stderr`: `lpr: acct_print: queuing is disabled`. No se crean archivos `cf*` ni `df*`.

---

#### Respuestas del Bloque 3

**Respuesta 3.1:**
- **`lpd` heredado (`rm`/`rp`):** Actúa como un spooler de paso a través (pass-through). Transfiere archivos de control/datos raw o prefiltrados a través del puerto TCP 515 utilizando el protocolo de flujo RFC 1179. Carece de consulta dinámica de capacidades, retroalimentación de estado bidireccional (por ejemplo, niveles precisos de tinta o atascamientos de papel) y cifrado nativo.
- **CUPS / IPP (`ipp://`):** Utiliza un protocolo basado en HTTP/1.1 (puerto 631). IPP admite consultas complejas de atributos de trabajo, autenticación (TLS/Kerberos), canalizaciones (pipelines) de renderizado de controladores PPD (PostScript Printer Description) en el lado del cliente o del servidor, y generación de informes de estado enriquecidos (conteo de páginas, estados de error detallados).

**Respuesta 3.2:**
Para diagnosticar `connection refused` en la impresión en red RFC 1179:
1. **Verificar la alcanzabilidad de transporte y puertos abiertos:** Ejecutar `nc -zv 192.168.100.50 515` o `telnet 192.168.100.50 515` para determinar si el demonio de destino está escuchando y aceptando conexiones TCP en el puerto 515.
2. **Inspeccionar las políticas de firewall / filtro de paquetes:** Ejecutar `sudo pfctl -sr` (PF en FreeBSD/OpenBSD) o comprobar los grupos de seguridad de red externos para asegurarse de que el tráfico de salida TCP del puerto 515 esté permitido.
3. **Rastrear las rutas de red:** Ejecutar `traceroute 192.168.100.50` para descartar bucles de enrutamiento o fallos en la puerta de enlace.
4. **Comprobar los registros de spool locales:** Inspeccionar `/var/log/lpd-errs` (o la ruta específica de `:lf:`) en busca de errores de vinculación de socket (socket binding) o de privilegio (por ejemplo, `lpd` fallando al vincularse a un puerto de origen con número bajo `< 1024` según lo requieren las implementaciones estrictas de RFC 1179).

</details>