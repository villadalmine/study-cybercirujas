# Ejercicios Pr\u00e1cticos: 2.3 Administrative Tasks

Estos ejercicios abarcan la automatizaci\u00f3n confiable de tareas, la gesti\u00f3n segura de identidades de sistema y el manejo correcto del reloj en servidores de producci\u00f3n.

## Ejercicio 1: Migraci\u00f3n de un Cronjob a Systemd Timer

Una tarea vital de sincronizaci\u00f3n de bases de datos se encuentra definida en `/etc/crontab` como:
`0 4 * * * root /opt/sync_db.sh`

El problema es que si el servidor falla y est\u00e1 apagado a las 04:00 AM, la sincronizaci\u00f3n no ocurre hasta el d\u00eda siguiente.

### Pasos

1. *(Mental o VM)* Crea el archivo del servicio unitario en `/etc/systemd/system/db-sync.service` definiendo el ejecutable.
   ```ini
   [Unit]
   Description=Database Sync
   [Service]
   Type=oneshot
   ExecStart=/opt/sync_db.sh
   ```
2. Escribe el timer correspondiente en `/etc/systemd/system/db-sync.timer`. La clave es usar el directivo que garantiza la ejecuci\u00f3n posterior si se perdi\u00f3 la ventana programada.
   ```ini
   [Unit]
   Description=Run Database Sync Daily
   [Timer]
   OnCalendar=*-*-* 04:00:00
   Persistent=true
   [Install]
   WantedBy=timers.target
   ```
3. Finalmente, debes indicarle a Systemd que vuelva a leer la configuraci\u00f3n de disco y luego habilitar el timer:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now db-sync.timer
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** En el manifiesto del Timer, \u00bfqu\u00e9 directiva exacta soluciona el problema de los servidores que estuvieron apagados durante la hora programada (`04:00`) y c\u00f3mo se comporta al encender el servidor?

---

## Ejercicio 2: Creaci\u00f3n de Usuarios de Servicio Seguros

Acabas de instalar manualmente un binario llamado `promtail` para enviar logs. Ejecutarlo como `root` es un riesgo inaceptable.

### Pasos

1. Crea un grupo dedicado de sistema para la aplicaci\u00f3n:
   ```bash
   sudo groupadd --system promtail
   ```
2. Crea el usuario asociado. Debe ser un usuario de sistema (`--system`), no debe tener un directorio *Home* real (`--no-create-home`), su grupo principal debe ser el que acabamos de crear (`-g promtail`), y no debe poder loguearse jam\u00e1s por consola (`-s /bin/false`):
   ```bash
   sudo useradd --system --no-create-home -g promtail -s /bin/false promtail
   ```
3. Cambia el propietario del binario (y de la carpeta de configuraci\u00f3n si la tuvieras) para que le pertenezcan a este usuario:
   ```bash
   # asumiendo que promtail est\u00e1 en /usr/local/bin
   sudo chown promtail:promtail /usr/local/bin/promtail
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** Cuando usas la bandera `--system` al crear un usuario en Linux, \u00bfqu\u00e9 diferencia tiene el UID (User ID) generado en comparaci\u00f3n con un usuario normal creado sin esta bandera?

---

## Ejercicio 3: Resoluci\u00f3n de Problemas de Timezones (NTP/RTC)

Tus microservicios en Golang fallan al validar *JSON Web Tokens (JWT)* alegando que los tokens a\u00fan no son v\u00e1lidos (expiraron en el futuro/pasado). Sospechas que el reloj del host subyacente est\u00e1 desincronizado.

### Pasos

1. Utiliza la herramienta est\u00e1ndar en distribuciones modernas (Systemd) para verificar el estado de la sincronizaci\u00f3n de tiempo:
   ```bash
   timedatectl status
   ```
2. Revisa la l\u00ednea que dice `System clock synchronized:`. Si dice `no`, debes activar el cliente NTP (Network Time Protocol) nativo:
   ```bash
   sudo timedatectl set-ntp true
   ```
3. A continuaci\u00f3n, verifica que la zona horaria (Time zone) no est\u00e9 introduciendo un *offset* accidental en los logs locales forz\u00e1ndola a UTC:
   ```bash
   sudo timedatectl set-timezone UTC
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** En la salida de `timedatectl`, aparecen tres relojes: `Local time`, `Universal time` (UTC) y `RTC time` (Real Time Clock). \u00bfA qu\u00e9 componente f\u00edsico o l\u00f3gico corresponde el `RTC time` y por qu\u00e9 es una mala pr\u00e1ctica configurarlo para usar el huso horario local en un servidor Linux?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** La directiva es `Persistent=true`. Cuando se activa, Systemd guarda en el disco (en `/var/lib/systemd/timers/`) la marca de tiempo (timestamp) de la \u00faltima vez que la tarea se ejecut\u00f3 exitosamente. Al bootear el servidor, si Systemd detecta que la tarea deber\u00eda haberse ejecutado mientras la m\u00e1quina estaba apagada, la dispara inmediatamente.

**Respuesta 2.1:** Los usuarios de sistema se crean con un UID num\u00e9rico bajo, tradicionalmente reservado para aplicaciones y daemons. En distribuciones modernas (basadas en Red Hat o Debian), los UIDs de sistema van del `1` al `999`. Un usuario humano normal, por otro lado, recibe autom\u00e1ticamente un UID empezando desde el `1000` en adelante.

**Respuesta 3.1:** El `RTC time` corresponde al Reloj de Tiempo Real, un chip f\u00edsico alimentado por una bater\u00eda en la placa base (motherboard) del servidor. Guardar la hora local en el RTC (t\u00edpico de sistemas Windows) causa problemas con los cambios de horario de verano (Daylight Saving Time), ya que el kernel no sabe si el salto de hora ya fue aplicado o no al bootear. Por eso, en Linux, el est\u00e1ndar es guardar el tiempo en el RTC siempre en formato UTC, y que el Sistema Operativo calcule el `Local time` bas\u00e1ndose en la zona horaria seleccionada.

</details>