# Ejercicios Pr\u00e1cticos: 2.4 Essential System Services

Estos ejercicios se centran en el mantenimiento preventivo y el diagn\u00f3stico de los tres pilares de los servicios de sistema: Sincronizaci\u00f3n de Tiempo, Logs y Rotaci\u00f3n.

## Ejercicio 1: Interrogaci\u00f3n del Estado de Sincronizaci\u00f3n (Chrony)

La p\u00e9rdida de sincronizaci\u00f3n de tiempo (Clock Drift) es letal para las bases de datos distribuidas. Necesitamos monitorear esto constantemente.

### Pasos

1. Abre tu terminal y verifica el estado resumido del reloj a nivel del kernel con `timedatectl`:
   ```bash
   timedatectl status
   ```
2. Ahora, pide a `chrony` que muestre las estad\u00edsticas de precisi\u00f3n de seguimiento actuales:
   ```bash
   chronyc tracking
   ```
3. Finalmente, inspecciona con qu\u00e9 fuentes (sources) se est\u00e1 comunicando el demonio, su latencia y si alguna est\u00e1 marcada como "offline" o "unreachable":
   ```bash
   chronyc sources -v
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** En la salida de `chronyc tracking`, observar\u00e1s un valor llamado "Stratum". Si tu servidor marca "Stratum: 3", \u00bfqu\u00e9 significa esto en la jerarqu\u00eda del protocolo NTP?

---

## Ejercicio 2: B\u00fasquedas Avanzadas y Gesti\u00f3n del Journald

Un SRE moderno no lee archivos de log en `/var/log` usando `grep`, sino que interroga directamente al binario de `journald` de manera estructurada.

### Pasos

1. Busca en el *Journal* todos los logs generados exclusivamente durante el proceso de arranque (boot) m\u00e1s reciente del sistema operativo:
   ```bash
   journalctl -b 0
   ```
2. Encuentra todos los logs con prioridad de "Error" (prioridad 3) o peor (Cr\u00edticos, Alertas, Emergencias) que hayan ocurrido en el sistema desde ayer:
   ```bash
   journalctl -p err..emerg --since "yesterday"
   ```
3. Verifica el l\u00edmite configurado de almacenamiento del Journald para asegurarte de que no se comer\u00e1 todo tu disco:
   ```bash
   grep -i SystemMaxUse /etc/systemd/journald.conf
   ```
   *(Si la salida est\u00e1 comentada o vac\u00eda, usa los l\u00edmites por defecto que son usualmente el 10% del disco).*

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** A diferencia de los cl\u00e1sicos archivos `/var/log/syslog` o `/var/log/messages`, el sistema `journald` guarda los registros en un formato binario en `/var/log/journal/`. Nombra al menos dos ventajas arquitect\u00f3nicas que proporciona este formato binario estructurado frente al texto plano.

---

## Ejercicio 3: Configuraci\u00f3n Segura de Logrotate

Tienes una aplicaci\u00f3n heredada escribiendo continuamente a `/var/log/legacy-app.log`. Vas a simular c\u00f3mo un SRE configura una rotaci\u00f3n para evitar que el disco se llene.

### Pasos

1. Revisa (sin modificar) una configuraci\u00f3n global t\u00edpica de rotaci\u00f3n (generalmente en `/etc/logrotate.conf` o dentro de `/etc/logrotate.d/`):
   ```bash
   cat /etc/logrotate.conf
   ```
2. Observa la directiva `delaycompress` si existe en alguna de las pol\u00edticas. \u00bfAlguna vez has visto archivos nombrados `archivo.log.1` (sin comprimir) y `archivo.log.2.gz` (comprimido)?

3. Ejecuta un "Dry-Run" (simulaci\u00f3n, sin alterar nada) de logrotate para ver exactamente qu\u00e9 har\u00eda el demonio si se ejecutara en este instante:
   ```bash
   sudo logrotate -d /etc/logrotate.conf
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** \u00bfPor qu\u00e9 la directiva `delaycompress` es frecuentemente considerada una "Best Practice" al rotar archivos de log que pertenecen a demonios o aplicaciones grandes, en lugar de comprimirlos inmediatamente al rotar?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** El "Stratum" mide la distancia (en saltos de red) hasta el reloj de referencia at\u00f3mico original (Stratum 0). Un servidor Stratum 1 est\u00e1 directamente conectado a un reloj de hardware (GPS/At\u00f3mico). Un servidor Stratum 2 sincroniza su tiempo consultando a un Stratum 1 a trav\u00e9s de la red. Por lo tanto, si tu servidor es Stratum 3, significa que est\u00e1 sincronizando su tiempo contra un servidor Stratum 2.

**Respuesta 2.1:**
1. **Indexaci\u00f3n de Metadatos:** Al ser estructurado, permite b\u00fasquedas extremadamente r\u00e1pidas y complejas (ej. filtrar instant\u00e1neamente por unidad de systemd `-u nginx.service`, por PID `_PID=123`, o por rango de tiempo), cosa que ser\u00eda O(N) buscando con `grep` en texto plano.
2. **Inmutabilidad y Seguridad:** El formato binario permite utilizar caracter\u00edsticas criptogr\u00e1ficas (Forward Secure Sealing) donde los logs se firman y sellan. Si un atacante compromete el nodo hoy, no puede borrar ni alterar los logs de ayer sin invalidar el sello criptogr\u00e1fico.
3. **Control Espacial Autom\u00e1tico:** Al ser manejado por un demonio con control sobre sus archivos binarios, Journald auto-rota y auto-borra logs viejos (vacuuming) en tiempo real para no exceder los l\u00edmites de disco configurados (ej. `SystemMaxUse`).

**Respuesta 3.1:** La compresi\u00f3n requiere CPU e I/O, pero el problema real es que muchos demonios (como bases de datos o servidores web como Nginx/Apache) no liberan el *File Descriptor* (el candado l\u00f3gico) del archivo de log instant\u00e1neamente al momento en que `logrotate` renombra el archivo. Si lo comprimes inmediatamente (`gzip`), la aplicaci\u00f3n que segu\u00eda intentando vaciar sus \u00faltimos buffers de escritura en disco hacia el archivo renombrado va a fallar (ya que ahora es un binario .gz o se interrumpe la estructura). `delaycompress` pospone la compresi\u00f3n del archivo rotado hasta el siguiente ciclo (ej. al d\u00eda siguiente), dando tiempo m\u00e1s que suficiente a la aplicaci\u00f3n para recargar (`reload` / `kill -HUP`) y abrir un descriptor hacia el nuevo archivo vac\u00edo, dejando el viejo quieto y seguro para comprimir despu\u00e9s.

</details>