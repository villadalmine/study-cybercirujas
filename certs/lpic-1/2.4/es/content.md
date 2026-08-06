# 2.4 Essential System Services

## 1. Motivaci\u00f3n y Problema Arquitect\u00f3nico de Producci\u00f3n

En sistemas distribuidos y arquitecturas de microservicios, los *Essential System Services* (Tiempo, Logging, Correo y colas de impresi\u00f3n) son la columna vertebral de la observabilidad y el cumplimiento (compliance). 

**Tiempo (Time Synchronization):** El problema arquitect\u00f3nico m\u00e1s grave en cl\u00fasteres (como Kubernetes o bases de datos como Cassandra/Spanner) es el *Clock Drift*. Si dos nodos difieren en su reloj por m\u00e1s de unos milisegundos, los algoritmos de consenso (Raft, Paxos) fallan, las transacciones TLS expiran prematuramente y los logs pierden su causalidad (un evento de respuesta parece ocurrir antes que la petici\u00f3n).
**Logging (Centralizaci\u00f3n):** Localmente, escribir logs a disco sin una pol\u00edtica estricta de rotaci\u00f3n llenar\u00e1 el *filesystem*, provocando ca\u00eddas (Out of Disk). A nivel macro, los logs aislados en cada nodo son in\u00fatiles; deben ser recolectados por `journald` o `rsyslog` y enviados a un backend central (ELK, Loki).
**MTA (Mail Transfer Agent):** Aunque las aplicaciones modernas env\u00edan correos v\u00eda APIs de terceros (SendGrid, SES), el propio kernel y demonios locales (cron, mdadm, sudo) siguen asumiendo la existencia de un MTA local (como Postfix) para alertar al usuario `root` sobre fallos de hardware o brechas de seguridad.

## 2. Comparativas T\u00e9cnicas y Trade-offs

### Mantenimiento del Tiempo: NTPd vs. Chrony vs. systemd-timesyncd

| Servicio | Arquitectura y Algoritmo | Caso de Uso SRE |
| :--- | :--- | :--- |
| **NTPd (Classic)** | Preciso pero lento para converger. Dise\u00f1ado para conexiones permanentes. | Sistemas *legacy* e infraestructuras *on-premise* est\u00e1ticas. |
| **Chrony** | Algoritmos agresivos que convergen en segundos. Tolera desconexiones. | **Est\u00e1ndar en la nube (AWS/GCP)**. Ideal para VMs ef\u00edmeras que necesitan sincronizarse al bootear. |
| **systemd-timesyncd** | Cliente SNTP muy ligero. Solo sincroniza tiempo (no puede servir tiempo a otros). | Contenedores y nodos *Edge* que no act\u00faan como servidores de tiempo, por su m\u00ednima huella. |

### Logging de Sistema: Syslogd vs. Rsyslog vs. Journald

| Sistema de Logs | Formato de Almacenamiento | Capacidades de B\u00fasqueda y Rotaci\u00f3n |
| :--- | :--- | :--- |
| **Syslog Cl\u00e1sico** | Texto plano (ej. `/var/log/messages`). | Lenta (grep). Requiere `logrotate` externo para no saturar disco. |
| **Rsyslog** | Texto plano, pero permite filtrado avanzado y TCP/UDP remote logging. | B\u00fasqueda por texto. Excelente para enviar logs legacy a un SIEM central. |
| **Journald** | Binario estructurado e indexado por metadatos (PID, Unit, UID). | B\u00fasquedas instant\u00e1neas (`journalctl`). Auto-rotaci\u00f3n nativa (cuotas de disco internas). |

## 3. Manifiestos, Configuraci\u00f3n e Infraestructura

### Configuraci\u00f3n del Tiempo: `chrony.conf` para Nodos de Producci\u00f3n

En plataformas Cloud, los nodos no deber\u00edan consultar servidores p\u00fablicos de internet (pool.ntp.org) por motivos de latencia y seguridad (ataques de amplificaci\u00f3n DDoS). En su lugar, consultan al servidor de hipervisor interno.

```text
# /etc/chrony/chrony.conf
# Usar el servidor NTP de enlace local (link-local) provisto por AWS/GCP
server 169.254.169.123 prefer iburst

# 'iburst' manda una r\u00e1faga de 8 paquetes en el arranque para una convergencia inicial < 2s

# Archivo de seguimiento de la desviaci\u00f3n (drift) del reloj f\u00edsico local
driftfile /var/lib/chrony/chrony.drift

# Si el reloj est\u00e1 desfasado m\u00e1s de 1 segundo en los primeros 3 updates (boot),
# hacer un 'step' (salto duro) en vez de un 'slew' (ajuste suave).
makestep 1.0 3

# Deshabilitar NTP como servidor para evitar ser usado en ataques de amplificaci\u00f3n NTP.
port 0

# Logs (solo para debugging avanzado SRE)
logdir /var/log/chrony
# log measurements statistics tracking
```

### Configuraci\u00f3n de Rotaci\u00f3n de Logs: `logrotate.conf`

Cuando aplicaciones legacy escriben directo a `/var/log/app.log`, los SREs implementan pol\u00edticas de retenci\u00f3n con `logrotate`.

```text
# /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14               # Retener solo 14 d\u00edas de logs
    compress                # Comprimir logs antiguos (.gz) para ahorrar espacio
    delaycompress           # No comprimir el log del d\u00eda de ayer inmediatamente
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        # Despu\u00e9s de rotar, obligar a Nginx a reabrir los descriptores de archivo
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
```

## 4. Comandos CLI y Salidas de Terminal Reales

### Gesti\u00f3n y Diagn\u00f3stico de NTP (Chrony)

```bash
# Validar contra qu\u00e9 servidores de tiempo est\u00e1 sincronizando nuestro nodo
$ chronyc sources -v
  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Source state '*' = current best, '+' = combined, '-' = not combined.
| /
^? 169.254.169.123               2   10     3   -    -20ms[  -20ms] +/-   15ms

# Ver m\u00e9tricas detalladas del reloj local y su desviaci\u00f3n actual
$ chronyc tracking
Reference ID    : A9FEA97B (169.254.169.123)
Stratum         : 3
Ref time (UTC)  : Wed Oct 25 10:00:00 2023
System time     : 0.000000004 seconds fast of NTP time
Last offset     : -0.000015243 seconds
RMS offset      : 0.000030112 seconds
```

### Journald y Extracci\u00f3n Estructurada de Logs

```bash
# Ver cu\u00e1nto espacio en disco est\u00e1 consumiendo el diario binario de systemd
$ journalctl --disk-usage
Archived and active journals take up 4.0G in the file system.

# Forzar una rotaci\u00f3n inmediata y reducir el tama\u00f1o hist\u00f3rico a 500MB
$ sudo journalctl --vacuum-size=500M
Vacuuming done, freed 3.5G of archived journals from /var/log/journal.

# SRE: Buscar logs generados *solo* por un binario espec\u00edfico desde ayer
$ journalctl /usr/sbin/sshd --since yesterday

# SRE: Extraer logs en formato JSON para mandarlos a un parser automatizado (jq)
$ journalctl -u kubelet.service -n 2 -o json-pretty
```

### Colas de Correo (MTA Postfix/Sendmail local)

```bash
# Ver la cola local de correos (Mails encolados que el demonio no pudo entregar)
$ mailq
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
A1B2C3D4E5      1024 Wed Oct 25 10:00:00  root@server.local
(Connection refused)
                                         admin@company.com
-- 1 Kbytes in 1 Request.

# Forzar la limpieza/borrado de toda la cola de correos trabados (peligroso, asume p\u00e9rdida de alertas)
$ sudo postsuper -d ALL
postsuper: Deleted: 1 message
```

## 5. Gu\u00eda de Verificaci\u00f3n y Diagn\u00f3stico de Fallas

1. **Base de Datos Crashea (Clock Skew / Drift excesivo)**:
   Si los logs del cluster de base de datos reportan "Clock drift detected, refusing to form quorum", es porque la m\u00e1quina local se desincroniz\u00f3.
   *Diagn\u00f3stico:* Corre `chronyc tracking`. Si el *Last offset* o el *System time* es > 500ms, hay un problema grave.
   *Resoluci\u00f3n:* Si est\u00e1s en una VM que fue pausada y reanudada, el reloj dio un salto gigante. `chrony` por defecto trata de arreglar esto muy lentamente (*slew*). Para forzar un ajuste duro inmediato: `sudo chronyc makestep`.

2. **Partici\u00f3n Ra\u00edz al 100% por falta de Rotaci\u00f3n (Syslog/App logs)**:
   Un desarrollador cre\u00f3 una app que escupe cientos de Gigas de logs a `/var/log/miapp.log` y olvid\u00f3 a\u00f1adir una regla de `logrotate`. El servidor ya no permite escribir nada ("No space left on device").
   *Diagn\u00f3stico:* `du -sh /var/log/* | sort -rh | head -n 5`.
   *Resoluci\u00f3n inmediata:* NO elimines el archivo con `rm`, ya que el proceso de la app a\u00fan lo tiene abierto y el espacio del inodo no se liberar\u00e1. Utiliza el truncamiento en caliente: `> /var/log/miapp.log` o `truncate -s 0 /var/log/miapp.log`. Luego crea la regla en `/etc/logrotate.d/` para prevenir la recurrencia.

3. **Correos de Cron inundando `/var/spool/mail/root`**:
   Un script de cron se ejecuta cada minuto y hace un simple `echo "OK"`. Como Cron manda por defecto cualquier salida est\u00e1ndar (STDOUT/STDERR) por email al propietario, est\u00e1 generando un correo por minuto.
   *Resoluci\u00f3n:* Edita el crontab para redirigir la salida a un archivo o a la nada: `* * * * * /opt/script.sh > /dev/null 2>&1`, o a\u00f1ade al principio del archivo crontab la variable `MAILTO=""`.

## 6. Referencias

* LPIC-1 Objetivos (Topic 108): [https://www.lpi.org/our-certifications/exam-101-objectives](https://www.lpi.org/our-certifications/exam-101-objectives)
* Chrony Documentation: [https://chrony.tuxfamily.org/documentation.html](https://chrony.tuxfamily.org/documentation.html)
* Systemd Journalctl Manual: [https://www.freedesktop.org/software/systemd/man/journalctl.html](https://www.freedesktop.org/software/systemd/man/journalctl.html)
* Logrotate Manual (man page): [https://linux.die.net/man/8/logrotate](https://linux.die.net/man/8/logrotate)