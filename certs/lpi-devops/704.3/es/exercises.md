# 704.3 — Gestión y análisis de logs
## Ejercicios guiados (LPI DevOps Tools Engineer, examen 701-100)

**Antes de empezar.** Cada comando de abajo corre en una VM descartable basada en systemd (familia Debian 12 / Ubuntu 24.04 / RHEL 9) donde tenés root, más un runtime de contenedores para la mitad de agregación. Nunca corras los ejercicios 2, 4 y 5 en una máquina cuyos logs le importen a alguien: vas a rotar, vaciar y limitar por tasa journals reales a propósito.

```bash
sudo mkdir -p /var/log/drill
sudo apt-get install -y rsyslog logrotate jq   # or: sudo dnf install -y rsyslog logrotate jq
docker --version   # or podman --version
```

A lo largo de todo esto, el modelo mental que conviene tener presente es el pipeline del cual toda arquitectura de logs es una instancia:

```
emit  ->  local collector  ->  buffer/queue  ->  ship  ->  index/store  ->  query/alert
```

La mayoría de los incidentes de logging en producción no son "la aplicación no logueó". Son "un salto de esa cadena descartó en silencio, y nada alertó sobre el descarte". Los ejercicios están ordenados a lo largo de esa cadena.

---

## Ejercicio 1 — journald es un almacén estructurado, no un archivo de texto

`systemd-journald` no guarda líneas. Guarda registros: un conjunto de campos clave/valor por entrada, en un formato binario indexado. Los campos que empiezan con `_` son **campos confiables** — el kernel y journald los derivan de las credenciales del proceso emisor, y una aplicación no puede falsificarlos. Esa distinción es todo el argumento de seguridad de journald.

### Pasos

1. Confirmá que journald es el dueño del socket y emití una entrada con facility y severidad explícitas:

```bash
systemctl status systemd-journald --no-pager
logger -p local3.warning -t drill "disk latency p99 exceeded"
```

2. Leé la entrada de vuelta con todos sus campos:

```bash
journalctl -t drill -n 1 -o verbose
```

Salida esperada (los campos abreviados van a diferir según el host):

```
Thu 2026-09-17 11:42:07.913455 UTC [s=6c1f2a...;i=1a4f;b=9d3c...;m=2b8e...;t=63c1...]
    _TRANSPORT=syslog
    PRIORITY=4
    SYSLOG_FACILITY=19
    SYSLOG_IDENTIFIER=drill
    SYSLOG_TIMESTAMP=Sep 17 11:42:07
    _UID=0
    _GID=0
    _COMM=logger
    _EXE=/usr/bin/logger
    _CMDLINE=logger -p local3.warning -t drill disk latency p99 exceeded
    _CAP_EFFECTIVE=1ffffffffff
    _SELINUX_CONTEXT=unconfined_u:unconfined_r:unconfined_t:s0
    _SYSTEMD_CGROUP=/user.slice/user-1000.slice/session-3.scope
    _SYSTEMD_UNIT=session-3.scope
    _BOOT_ID=9d3c...
    _MACHINE_ID=1f08...
    _HOSTNAME=node-a
    _PID=48213
    MESSAGE=disk latency p99 exceeded
    _SOURCE_REALTIME_TIMESTAMP=1789643327913455
```

3. Inspeccioná el mismo registro como JSON, y después extraé dos campos con `jq`:

```bash
journalctl -t drill -n 1 -o json | jq -r '[.PRIORITY, .SYSLOG_FACILITY, .MESSAGE] | @tsv'
```

```
4	19	disk latency p99 exceeded
```

> **Pregunta 1.** `SYSLOG_FACILITY=19` y `PRIORITY=4`. ¿Qué byte único vería un receptor syslog clásico RFC 3164 como valor PRI de este mensaje, y cómo se calcula?
>
> **Pregunta 2.** Querés probar que la entrada realmente vino del PID 48213 ejecutando `/usr/bin/logger`, en una investigación forense. ¿En cuáles de los campos de arriba podés confiar, y cuáles podría haber puesto un proceso hostil con el valor que se le antojara?

### Pasos (continuación)

4. Explorá el índice en lugar de grepear texto. `-N` lista los *nombres* de campo presentes; `-F` lista los *valores* distintos de un campo:

```bash
journalctl -N | head -20
journalctl -F _TRANSPORT
```

```
audit
driver
journal
kernel
stdout
syslog
```

5. Ahora corré cuatro consultas que un `grep` sobre `/var/log/syslog` no puede expresar tan barato:

```bash
journalctl -u ssh.service -p 3..4 --since "-2h" --no-pager
journalctl _SYSTEMD_UNIT=cron.service _UID=0 -o short-iso
journalctl --facility=local3 --output-fields=MESSAGE,_PID -o json | tail -5
journalctl -k -b -1 -g 'oom|Out of memory'
```

> **Pregunta 3.** ¿Qué severidades seleccionó `-p 3..4`, por nombre? ¿Por qué `journalctl -p 4` por sí solo devuelve *más* entradas que `-p 3..4`?
>
> **Pregunta 4.** `journalctl -g` y `journalctl -t` acotan ambos el conjunto de resultados. Uno de los dos es una búsqueda indexada y el otro es un escaneo completo de las entradas coincidentes. ¿Cuál es cuál, y qué implica eso para una consulta sobre 40 GB de journal?
>
> **Pregunta 5.** `_TRANSPORT=stdout` aparece en la lista. ¿Qué tipo de productor de logs cae en el journal a través de ese transporte, y qué te dice eso sobre un servicio que escribe a `stdout` y es arrancado por systemd?

---

## Ejercicio 2 — Retención, presupuesto de disco y limitación por tasa

Un journal con configuración por defecto es volátil en muchas distribuciones (`Storage=auto` lo mantiene en `/run` salvo que exista `/var/log/journal`), y *sí* va a descartar mensajes ante una ráfaga. Ambos comportamientos sorprenden a la gente durante su primer postmortem.

### Pasos

1. Verificá el estado actual:

```bash
journalctl --disk-usage
ls -ld /var/log/journal 2>/dev/null || echo "volatile: journal lives in /run/log/journal"
systemd-analyze cat-config systemd/journald.conf | grep -vE '^\s*#|^$'
```

2. Hacé el journal persistente y acotalo explícitamente, usando un drop-in en lugar de editar el archivo que trae la distribución:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-drill.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
SystemKeepFree=1G
SystemMaxFileSize=128M
MaxRetentionSec=2week
MaxFileSec=1day
RateLimitIntervalSec=30s
RateLimitBurst=1000
ForwardToSyslog=yes
EOF
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

3. Disparé el limitador de tasa a propósito y mirá cómo journald lo admite:

```bash
for i in $(seq 1 5000); do logger -t drill-flood "burst line $i"; done
journalctl -t drill-flood | wc -l
journalctl _COMM=systemd-journald --since "-2min" | grep -i suppress
```

```
Sep 18 09:03:12 node-a systemd-journald[412]: Suppressed 4019 messages from /user.slice/user-1000.slice/session-3.scope
```

4. Rotá y recuperá espacio sin reiniciar el demonio:

```bash
sudo journalctl --rotate
sudo journalctl --vacuum-size=200M
sudo journalctl --vacuum-time=7d
sudo journalctl --verify | tail -3
```

> **Pregunta 6.** Tu drop-in define tanto `SystemMaxUse=2G` como `SystemKeepFree=1G`, en un sistema de archivos `/var` con 1,4 GB libres. ¿Cuánto journal va a conservar systemd realmente, y por qué?
>
> **Pregunta 7.** El limitador de tasa suprimió 4019 de 5000 mensajes. ¿A qué ámbito se aplica `RateLimitBurst` — al host, a la unidad, o a otra cosa — y cuál es la consecuencia operativa de subirlo a `RateLimitBurst=0`?
>
> **Pregunta 8.** Pusiste `ForwardToSyslog=yes` y rsyslog también está corriendo con `imuxsock` habilitado. Describí el modo de falla por duplicación que esto puede causar, y los dos ajustes de módulo que lo resuelven.
>
> **Pregunta 9.** `journalctl --verify` reportó `PASS` pero no corriste `journalctl --setup-keys`. ¿Qué se verificó exactamente, y qué garantía adicional te habría dado FSS (Forward Secure Sealing)?

---

## Ejercicio 3 — rsyslog: facilities, severidades, selectores, y validar antes de recargar

rsyslog sigue siendo el enrutador local de la máquina en la mayoría de las flotas Linux: decide qué se escribe dónde, qué se descarta y qué sale del host. Su sintaxis clásica de selectores es escueta y sus valores por defecto son "y todo lo más severo", que es la mala configuración más común del objetivo.

### Pasos

1. Escribí un archivo de reglas que demuestre los tres estilos de filtro. Notá que el archivo se evalúa en orden lexicográfico de `/etc/rsyslog.d/*.conf`, así que el prefijo numérico importa:

```bash
sudo tee /etc/rsyslog.d/30-drill.conf >/dev/null <<'EOF'
# 1. classic selector: this severity AND everything more severe
local3.warning                  /var/log/drill/local3-warn-and-above.log

# 2. exact severity only
local3.=notice                  /var/log/drill/local3-notice-only.log

# 3. everything except one severity
local3.!=debug                  /var/log/drill/local3-no-debug.log

# 4. property-based filter on the message body
:msg, contains, "p99 exceeded"  /var/log/drill/latency.log

# 5. RainerScript: structured condition + explicit stop
if ($syslogfacility-text == "local3") and ($msg contains "SECRET") then {
    action(type="omfile" file="/var/log/drill/redacted.log" template="RSYSLOG_TraditionalFileFormat")
    stop
}
EOF
```

2. **Validá antes de recargar.** Un error de sintaxis en un drop-in puede dejar a rsyslog corriendo con un conjunto de reglas parcial, o directamente sin correr:

```bash
sudo rsyslogd -N1
```

```
rsyslogd: version 8.2312.0, config validation run (level 1), master config /etc/rsyslog.conf
rsyslogd: End of config validation run. Bye.
```

Un error se ve así — notá que rsyslog te da una URL de documentación por número de error:

```
rsyslogd: error during parsing file /etc/rsyslog.d/30-drill.conf, on or before line 14: syntax error on token 'then' [v8.2312.0 try https://www.rsyslog.com/e/2207 ]
```

3. Recargá y generá un mensaje en cada severidad:

```bash
sudo systemctl reload rsyslog
for sev in debug info notice warning err crit; do
  logger -p local3.$sev -t drill "severity test: $sev"
done
wc -l /var/log/drill/local3-*.log
```

```
  3 /var/log/drill/local3-warn-and-above.log
  1 /var/log/drill/local3-notice-only.log
  5 /var/log/drill/local3-no-debug.log
  9 total
```

> **Pregunta 10.** Explicá los tres conteos de arriba línea por línea. ¿Qué mensajes cayeron en cada archivo?
>
> **Pregunta 11.** Un colega escribe `local3.warning` con la intención de "solo warnings" y después abre un ticket diciendo que el archivo está "lleno de ruido". Dale el arreglo de un solo carácter, y dale el selector que capturaría *todo* de `local3` sin importar la severidad.
>
> **Pregunta 12.** El bloque de RainerScript termina en `stop`. ¿Qué cambiaría, concretamente, si lo sacaras, dadas las reglas 1–4 que están arriba de él y el propio `/etc/rsyslog.d/50-default.conf` de la distribución que está abajo?
>
> **Pregunta 13.** El filtro 4 usa `:msg, contains, "p99 exceeded"`. ¿Por qué `$msg contains` se evalúa contra una cadena *distinta* que `$rawmsg`, y cuándo te muerde esa diferencia?

---

## Ejercicio 4 — Reenvío con una cola que sobrevive a la red

Reenviar logs es fácil. Reenviar logs *sin perderlos cuando el colector está caído durante 40 minutos* es el problema de ingeniería real, y es enteramente un problema de configuración de colas.

### Pasos

1. En el **receptor** (puede ser la misma VM en un puerto libre), aceptá syslog por TCP y archivá por host y por programa:

```bash
sudo tee /etc/rsyslog.d/10-receiver.conf >/dev/null <<'EOF'
module(load="imtcp" MaxSessions="500")
input(type="imtcp" port="10514" ruleset="remote")

template(name="RemoteFile" type="string"
         string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")

ruleset(name="remote") {
    action(type="omfile"
           dynaFile="RemoteFile"
           dynaFileCacheSize="200"
           createDirs="on"
           fileCreateMode="0640"
           dirCreateMode="0750")
    stop
}
EOF
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
ss -lntp | grep 10514
```

```
LISTEN 0  25  0.0.0.0:10514  0.0.0.0:*  users:(("rsyslogd",pid=51204,fd=7))
```

2. En el **emisor**, reenviá con una cola en memoria asistida por disco y reintento infinito:

```bash
sudo tee /etc/rsyslog.d/90-forward.conf >/dev/null <<'EOF'
action(type="omfwd"
       target="127.0.0.1" port="10514" protocol="tcp"
       template="RSYSLOG_SyslogProtocol23Format"
       action.resumeRetryCount="-1"
       action.resumeInterval="10"
       queue.type="LinkedList"
       queue.filename="fwd_drill"
       queue.spoolDirectory="/var/spool/rsyslog"
       queue.maxDiskSpace="1g"
       queue.highWatermark="8000"
       queue.lowWatermark="2000"
       queue.size="10000"
       queue.saveOnShutdown="on"
       queue.dequeueBatchSize="1000")
EOF
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
logger -p local3.err -t drill "forwarded probe"
cat /var/log/remote/$(hostname)/drill.log
```

```
<155>1 2026-09-18T09:21:44.512883+00:00 node-a drill 52310 - - forwarded probe
```

3. Ahora rompé el receptor y probá que la cola vuelca a disco en lugar de descartar:

```bash
sudo ss -K dport = :10514 2>/dev/null
sudo systemctl stop rsyslog        # on the receiver side
for i in $(seq 1 20000); do logger -p local3.info -t drill "queued $i"; done
ls -lh /var/spool/rsyslog/
```

```
-rw------- 1 root root 1.8M Sep 18 09:24 fwd_drill.00000001
-rw------- 1 root root   84 Sep 18 09:24 fwd_drill.qi
```

4. Levantá el receptor de nuevo y mirá cómo se drena el backlog:

```bash
sudo systemctl start rsyslog       # receiver
sleep 20; ls -lh /var/spool/rsyslog/; wc -l /var/log/remote/*/drill.log
```

> **Pregunta 14.** `RSYSLOG_SyslogProtocol23Format` produjo `<155>1 ...`. Decodificá `155` en facility y severidad, y nombrá el RFC que define el `1` inmediatamente después.
>
> **Pregunta 15.** Sacaste `queue.filename`. ¿Qué tipo de cola queda, y exactamente cuántos mensajes sobreviven a una caída del receptor de 40 minutos a 200 msg/s?
>
> **Pregunta 16.** Compará `protocol="udp"`, `protocol="tcp"` y `omrelp` para este reenviador en términos de qué se garantiza en el cable. TCP es orientado a conexión — ¿por qué aun así no es una garantía de entrega extremo a extremo para syslog?
>
> **Pregunta 17.** `queue.saveOnShutdown="on"` cuesta tiempo de apagado. Describí el escenario de pérdida de datos que previene, y un escenario donde hace que el reinicio de un nodo tarde un tiempo inaceptable.

---

## Ejercicio 5 — logrotate: `create` versus `copytruncate`, y la corrida en seco que te salva

### Pasos

1. Escribí una política de rotación para los logs del drill:

```bash
sudo tee /etc/logrotate.d/drill >/dev/null <<'EOF'
/var/log/drill/*.log {
    daily
    rotate 14
    dateext
    dateformat -%Y%m%d
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
    endscript
}
EOF
```

2. Corrélo en seco. `-d` implica debug **y** no hace cambios ni actualiza el archivo de estado:

```bash
sudo logrotate -d /etc/logrotate.d/drill
```

```
reading config file /etc/logrotate.d/drill
Allocating hash table for state file, size 64 entries
Handling 1 logs
rotating pattern: /var/log/drill/*.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/drill/latency.log
  Now: 2026-09-18 09:31
  Last rotated at 2026-09-18 00:00
  log does not need rotating (log has already been rotated)
```

3. Forzá una rotación y leé las acciones reales:

```bash
sudo logrotate -v -f /etc/logrotate.d/drill
ls -l /var/log/drill/
sudo grep drill /var/lib/logrotate/logrotate.status   # RHEL: /var/lib/logrotate/logrotate.status
```

```
renaming /var/log/drill/latency.log to /var/log/drill/latency.log-20260918
creating new /var/log/drill/latency.log mode = 0640 uid = 0 gid = 4
running postrotate script
```

4. Reproducí la falla clásica. Arrancá un escritor que mantenga abierto el descriptor de archivo y nunca reabra, y después rotá por debajo de él:

```bash
( while true; do echo "$(date -Is) tick" >> /var/log/drill/stubborn.log; sleep 1; done ) &
WRITER=$!
sudo logrotate -f /etc/logrotate.d/drill
ls -l /proc/$WRITER/fd | grep drill
tail -1 /var/log/drill/stubborn.log
```

```
lrwx------ 1 root root 64 Sep 18 09:34 3 -> /var/log/drill/stubborn.log-20260918 (deleted)
tail: cannot open '/var/log/drill/stubborn.log' for reading: ... (or: file stays empty)
```

5. Pasá ese único archivo a `copytruncate` y repetí:

```bash
sudo tee /etc/logrotate.d/drill-stubborn >/dev/null <<'EOF'
/var/log/drill/stubborn.log {
    daily
    rotate 7
    copytruncate
    compress
    missingok
    notifempty
}
EOF
sudo logrotate -f /etc/logrotate.d/drill-stubborn
kill $WRITER
```

6. Confirmá qué dispara realmente a logrotate en una distribución moderna:

```bash
systemctl list-timers logrotate.timer --no-pager
systemctl cat logrotate.timer | grep -A3 '\[Timer\]'
```

> **Pregunta 18.** En el paso 4 el fd 3 del escritor apunta a un archivo marcado `(deleted)`. Explicá la secuencia de llamadas al sistema que produjo ese estado, y por qué el espacio en disco *no* se recupera hasta que el escritor termina.
>
> **Pregunta 19.** `copytruncate` lo arregló. Nombrá la condición de carrera que introduce `copytruncate`, y explicá por qué existe `delaycompress` si `compress` ya está puesto.
>
> **Pregunta 20.** El script `postrotate` le manda `SIGHUP` a rsyslog y la estrofa lleva `sharedscripts`. ¿Qué pasaría sin `sharedscripts` dado que el glob `/var/log/drill/*.log` coincide con seis archivos?
>
> **Pregunta 21.** ¿Por qué journald no necesita una entrada de logrotate, y qué mecanismo cumple el rol equivalente para él?

---

## Ejercicio 6 — Logging estructurado, Loki y la trampa de la cardinalidad

Los sistemas de agregación se dividen en dos familias: **indexar todo** (Elasticsearch — cualquier campo es consultable, al costo de un índice pesado) y **indexar solo etiquetas** (Loki — un índice pequeño de etiquetas más chunks comprimidos que se escanean por fuerza bruta). Elegir mal, o etiquetar mal, es lo que hace explotar una factura de logging.

### Pasos

1. Emití logs estructurados. Un objeto JSON por línea — el archivo en su conjunto es JSON Lines, no un documento JSON:

```bash
sudo tee /usr/local/bin/drill-app >/dev/null <<'EOF'
#!/usr/bin/env bash
routes=(/api/v1/cart /api/v1/checkout /healthz)
levels=(info info info warn error)
while true; do
  r=${routes[$RANDOM % 3]}; l=${levels[$RANDOM % 5]}
  printf '{"ts":"%s","level":"%s","service":"checkout","route":"%s","status":%d,"latency_ms":%d,"trace_id":"%032x","msg":"request completed"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$l" "$r" $(( RANDOM % 2 ? 200 : 502 )) $(( RANDOM % 2000 )) $RANDOM \
    >> /var/log/drill/app.log
  sleep 0.2
done
EOF
sudo chmod +x /usr/local/bin/drill-app
sudo /usr/local/bin/drill-app &
tail -1 /var/log/drill/app.log | jq .
```

Un único registro, formateado:

```json
{"ts":"2026-09-18T09:41:02.481Z","level":"error","service":"checkout","route":"/api/v1/checkout","status":502,"latency_ms":1843,"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","msg":"request completed"}
```

2. Levantá Loki y apuntá un colector al archivo:

```bash
docker run -d --name loki -p 3100:3100 grafana/loki:3.1.1
curl -s http://localhost:3100/ready
```

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10

scrape_configs:
  - job_name: drill-app
    static_configs:
      - targets:
          - localhost
        labels:
          job: drill
          env: staging
          __path__: /var/log/drill/app.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            ts: ts
            route: route
      - labels:
          level:
      - timestamp:
          source: ts
          format: RFC3339
      - output:
          source: msg
```

> Nota sobre upstream: Grafana puso a Promtail en modo mantenimiento y dirige los despliegues nuevos a **Grafana Alloy**, cuyos componentes `loki.source.file` / `loki.process` mapean uno a uno con las etapas de arriba. El objetivo del examen todavía nombra a Promtail; verificá el estado actual en la documentación de Loki antes de diseñar una flota nueva.

3. Consultá con `logcli` (o la vista Explore de Grafana). Empezá con un selector de streams, después filtrá, después parseá:

```bash
export LOKI_ADDR=http://localhost:3100
logcli query --limit=20 --since=15m '{job="drill"}'
logcli query --limit=20 --since=15m '{job="drill"} |= "502"'
logcli query --limit=20 --since=15m '{job="drill", level="error"} | json | status >= 500'
logcli query --since=15m 'sum by (route) (rate({job="drill", level="error"} [5m]))'
logcli query --since=15m 'quantile_over_time(0.99, {job="drill"} | json | unwrap latency_ms [5m]) by (route)'
```

4. Convertí la razón en una regla de alerta. Notá que dentro del escalar de bloque cada línea — incluido el operador `/` solo — lleva la misma indentación, o el documento YAML termina antes de tiempo:

```yaml
groups:
  - name: drill-log-alerts
    rules:
      - alert: CheckoutErrorRatioHigh
        expr: |
          sum(rate({job="drill", level="error"} |= "checkout" [5m]))
          /
          sum(rate({job="drill"} [5m]))
          > 0.05
        for: 10m
        labels:
          severity: page
        annotations:
          summary: "Over 5% of checkout log lines are errors"
          runbook_url: "https://runbooks.example.com/drill/checkout-errors"
```

> **Pregunta 22.** La etapa `labels:` promueve `level` pero deliberadamente no `trace_id` ni `route`. Estimá la cantidad de streams creados si se promoviera `trace_id` a lo largo de un día a 5 req/s, y explicá qué le hace eso al índice de Loki y a la memoria del ingester.
>
> **Pregunta 23.** Ordená estas tres consultas por costo sobre 100 GB de chunks, de la más barata a la más cara, y decí por qué: `{job="drill"} | json | status>=500`, `{job="drill"} |= "502"`, `{job="drill", level="error"}`.
>
> **Pregunta 24.** Una línea falla al parsearse como JSON. ¿Qué pone `| json` en el resultado, y qué le hace a tu cómputo de `rate()` agregar `| __error__=""`?
>
> **Pregunta 25.** La etapa `timestamp` parsea `ts` del payload. Nombrá un incidente concreto que esta etapa previene, y un modo de falla nuevo que introduce cuando el reloj de una aplicación está mal.

---

## Ejercicio 7 — Elastic Stack: Filebeat envía, Logstash parsea, Elasticsearch indexa

### Pasos

1. Levantá Elasticsearch y Kibana de nodo único para el drill:

```bash
docker network create elastic
docker run -d --name es01 --net elastic -p 9200:9200 \
  -e discovery.type=single-node -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms1g -Xmx1g" docker.elastic.co/elasticsearch/elasticsearch:8.15.0
curl -s localhost:9200/_cat/health?v
```

```
epoch      timestamp cluster       status node.total node.data shards pri relo init unassign
1789645... 09:52:31  docker-cluster yellow          1         1      3   3    0    0        1
```

2. Un pipeline de Logstash para un log heredado *no* JSON — acá es donde `grok` se gana el sueldo. El DSL del pipeline no es YAML, así que no se etiqueta como tal:

```
input {
  beats { port => 5044 }
}

filter {
  if [log][file][path] =~ "legacy" {
    grok {
      match => { "message" => "%{TIMESTAMP_ISO8601:ts} \[%{LOGLEVEL:level}\] %{DATA:component} - %{NUMBER:latency_ms:int}ms - %{GREEDYDATA:detail}" }
      tag_on_failure => ["_grokparsefailure_legacy"]
    }
    date {
      match => ["ts", "ISO8601"]
      target => "@timestamp"
      timezone => "UTC"
    }
    mutate {
      lowercase => ["level"]
      remove_field => ["ts", "message"]
    }
  }
}

output {
  if "_grokparsefailure_legacy" in [tags] {
    file { path => "/var/log/logstash/unparsed-%{+YYYY.MM.dd}.log" }
  } else {
    elasticsearch {
      hosts => ["http://es01:9200"]
      data_stream => "true"
    }
  }
  stdout { codec => rubydebug }
}
```

3. **Validá el pipeline antes de reiniciar el servicio** — el equivalente de `rsyslogd -N1`:

```bash
/usr/share/logstash/bin/logstash -f /etc/logstash/conf.d/drill.conf --config.test_and_exit
```

```
[INFO ][logstash.runner] Using config.test_and_exit mode. Config Validation Result: OK. Exiting Logstash
Configuration OK
```

4. Enviá el archivo JSON del ejercicio 6 con Filebeat, parseando NDJSON en el borde para que Logstash no haga trabajo:

```yaml
filebeat.inputs:
  - type: filestream
    id: drill-app
    enabled: true
    paths:
      - /var/log/drill/app.log
    parsers:
      - ndjson:
          target: ""
          overwrite_keys: true
          add_error_key: true
    fields:
      env: staging
    fields_under_root: true

filebeat.registry.path: /var/lib/filebeat/registry

output.logstash:
  hosts:
    - "localhost:5044"
  ttl: 30s
  pipelining: 2

logging.level: info
```

5. Verificá el viaje de ida y vuelta y vigilá la etiqueta reveladora de falla de parseo:

```bash
filebeat test config -c /etc/filebeat/filebeat.yml
filebeat test output -c /etc/filebeat/filebeat.yml
curl -s 'localhost:9200/_cat/indices?v&s=index'
curl -s 'localhost:9200/logs-*/_count?q=tags:_grokparsefailure_legacy' | jq .count
```

> **Pregunta 26.** Están llegando documentos pero `@timestamp` es el momento de ingesta, no el `ts` de la aplicación. ¿Qué filtro falta o está mal configurado, y por qué un dashboard sobre "los últimos 15 minutos" se ve correcto igual hasta el primer atraso de ingesta?
>
> **Pregunta 27.** `_grokparsefailure` aparece en el 30% de los documentos. Dá los pasos de diagnóstico ordenados, y nombrá el filtro de Logstash al que te pasarías si el formato del log es de delimitador fijo y la CPU es el cuello de botella.
>
> **Pregunta 28.** Filebeat mantiene un registry en `/var/lib/filebeat/registry`. Predecí el comportamiento exacto si lo borrás con Filebeat detenido, y por separado si se cambia el `id` del input `filestream`.
>
> **Pregunta 29.** Contrastá el modelo de almacenamiento de Loki con el de Elasticsearch para este mismo stream JSON: ¿cuál te permite preguntar "mostrame cada línea con `trace_id=4bf92f...` en los últimos 30 días" sin un escaneo completo, y qué pagás por eso?

---

## Ejercicio 8 — Logs de contenedores y de Kubernetes

En un contenedor, "el archivo de log" es una convención mantenida por el runtime, no por la aplicación. La aplicación escribe a `stdout`/`stderr`; todo lo que viene después es el driver de logging del runtime.

### Pasos

1. Corré un contenedor ruidoso con el driver por defecto y encontrá el archivo que el runtime realmente está escribiendo:

```bash
docker run -d --name noisy --log-driver json-file \
  --log-opt max-size=10m --log-opt max-file=3 --log-opt compress=true \
  busybox sh -c 'i=0; while true; do i=$((i+1)); echo "{\"seq\":$i,\"msg\":\"hello\"}"; sleep 0.05; done'

docker inspect --format '{{.LogPath}}' noisy
sudo ls -lh "$(docker inspect --format '{{.LogPath}}' noisy)"*
docker logs --since 1m --timestamps noisy | tail -3
```

```
/var/lib/docker/containers/9f1a.../9f1a...-json.log
-rw-r----- 1 root root 6.2M Sep 18 10:02 /var/lib/docker/containers/9f1a.../9f1a...-json.log
```

2. Pasá un segundo contenedor al driver journald y consultalo a través del índice del journal:

```bash
docker run -d --name noisy-jd --log-driver journald --log-opt tag="{{.Name}}" \
  busybox sh -c 'while true; do echo "journald path"; sleep 1; done'
journalctl CONTAINER_NAME=noisy-jd -n 3 -o json | jq -r '.MESSAGE'
docker logs noisy-jd | tail -2
```

3. En Kubernetes, localizá la misma cadena y revisá los ajustes de rotación propios del kubelet:

```bash
kubectl run drill --image=busybox --restart=Never -- sh -c 'echo started; sleep 3600'
kubectl logs drill --timestamps
kubectl logs drill --previous 2>&1 | head -2
sudo ls -l /var/log/pods/default_drill_*/drill/
kubectl get --raw "/api/v1/nodes/$(kubectl get no -o jsonpath='{.items[0].metadata.name}')/proxy/configz" \
  | jq '.kubeletconfig | {containerLogMaxSize, containerLogMaxFiles}'
```

```
{
  "containerLogMaxSize": "10Mi",
  "containerLogMaxFiles": 5
}
```

> **Pregunta 30.** Con `--log-driver journald`, `docker logs` siguió funcionando. Con `--log-driver syslog` típicamente no. ¿Qué propiedad de un driver de logging determina si `docker logs` puede servir desde él?
>
> **Pregunta 31.** Un pod está en `CrashLoopBackOff`, corrés `kubectl logs pod`, y ves los logs del contenedor *actual*, que todavía está arrancando. ¿Qué flag muestra el que crasheó, y qué hace que esos logs desaparezcan para siempre?
>
> **Pregunta 32.** `containerLogMaxSize: 10Mi` con 5 archivos limita a un contenedor a ~50 MiB en el nodo. A 2 MiB/min de salida, ¿de cuánto es tu historial de `kubectl logs` — y cuál es la conclusión arquitectónica para la respuesta a incidentes?
>
> **Pregunta 33.** Compará un colector DaemonSet a nivel de nodo contra un colector sidecar por pod. Dá un caso donde el sidecar sea la única opción que funciona.

---

## Ejercicio 9 — Trabajo final: "los logs se cortaron"

A las 03:10 un ingeniero de guardia reporta que los logs de un servicio desaparecieron del dashboard, mientras que el servicio en sí está sirviendo tráfico normalmente. Trabajá la cadena **desde el emisor hacia afuera** — el orden importa, porque cada escalón elimina todo lo que está debajo.

### Pasos

1. ¿El proceso sigue escribiendo, siquiera?

```bash
PID=$(pgrep -f drill-app | head -1)
sudo ls -l /proc/$PID/fd | grep -E 'drill|deleted'
sudo lsof -p $PID | grep -E 'REG.*log'
stat -c '%n size=%s mtime=%y' /var/log/drill/app.log
```

2. ¿El colector local está aceptando, o descartando?

```bash
journalctl _COMM=systemd-journald --since "-30min" | grep -iE 'suppress|missed|rotat'
sudo grep -iE 'imjournal|ratelimit|impstats|action.*suspended|discard' /var/log/syslog | tail -20
ls -lh /var/spool/rsyslog/
```

3. ¿Al host se le acabó el recurso que necesita el pipeline?

```bash
df -h /var /var/log
df -i /var/log
sudo ausearch -m avc -ts recent 2>/dev/null | tail -5   # or: journalctl -t setroubleshoot -n 5
```

4. ¿El emisor quedó trabado en una posición obsoleta?

```bash
sudo cat /var/lib/promtail/positions.yaml
curl -s localhost:9080/metrics | grep -E 'promtail_(read_bytes|sent_entries|dropped)_total'
curl -s localhost:3100/loki/api/v1/labels | jq .
```

5. ¿El almacén está rechazando las escrituras?

```bash
docker logs loki 2>&1 | grep -iE 'out of order|too far behind|per-stream rate limit|429'
curl -s 'localhost:9200/_cat/indices?v&health=red'
curl -s 'localhost:9200/_cluster/allocation/explain' | jq -r '.allocate_explanation? // "no unassigned shards"'
```

> **Pregunta 34.** El paso 1 muestra el fd 3 apuntando a `/var/log/drill/app.log-20260918 (deleted)` y `app.log` tiene `size=0` con un mtime de las 00:00. Nombrá la causa raíz y los dos arreglos independientes — uno en logrotate, uno en la aplicación.
>
> **Pregunta 35.** El paso 5 muestra a Loki devolviendo `429` con `per-stream rate limit exceeded`. ¿Qué cambio en la etapa `labels:` del colector lo causó con mayor plausibilidad, y por qué agregar más ingesters de Loki no arregla este error específico?
>
> **Pregunta 36.** `df -h` muestra 40% usado pero `df -i` muestra 100% de inodos usados. Explicá cómo un pipeline de logging llega a ese estado y qué directiva única del ejercicio 5 lo previene.
>
> **Pregunta 37.** Todo lo de arriba está en verde y los logs siguen ausentes del dashboard. Nombrá los dos sospechosos restantes que ninguno de estos comandos habría atrapado.

---

<details>
<summary><b>Respuestas</b></summary>

**A1.** PRI = `facility * 8 + severity` = `19 * 8 + 4` = **156**, transmitido como `<156>`. La facility 19 es `local3`, la severidad 4 es `warning`. (En el Ejercicio 4 el valor era `155` porque ese mensaje era `local3.err`: `19 * 8 + 3 = 155`.)

**A2.** Confiá en los campos con prefijo de guion bajo: `_PID`, `_UID`, `_GID`, `_COMM`, `_EXE`, `_CMDLINE`, `_CAP_EFFECTIVE`, `_SELINUX_CONTEXT`, `_SYSTEMD_UNIT`, `_BOOT_ID`, `_MACHINE_ID`, `_HOSTNAME`. journald los deriva de las credenciales del socket emisor (`SO_PEERCRED` / `SCM_CREDENTIALS`) y del cgroup del proceso, así que el emisor no puede falsificarlos. Todo lo que no tiene guion bajo — `MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER`, `SYSLOG_FACILITY`, `SYSLOG_PID` — lo suministra el emisor y es arbitrario. Un proceso puede afirmar que es `sshd` con prioridad `emerg`; no puede reclamar el `_PID` ni el `_SYSTEMD_UNIT` de otro.

**A3.** `-p 3..4` es solo `err` y `warning`. `-p 4` a secas significa "warning *y todo lo más severo*" — es decir, severidades 0–4 — así que es un superconjunto: agrega `emerg`, `alert`, `crit` y `err`. Un único valor de `-p` es siempre un techo, nunca una coincidencia exacta; solo la forma de rango excluye el extremo más severo.

**A4.** `-t` (`SYSLOG_IDENTIFIER=`) es una coincidencia sobre un campo indexado: las tablas hash por archivo de journald y el índice de arreglos de entradas le permiten saltar a las entradas coincidentes. `-g` / `--grep` es una regex PCRE2 aplicada al campo `MESSAGE` de las entradas que sobreviven a los demás filtros — tiene que descomprimirlas y escanearlas. Sobre 40 GB, acotá siempre *primero* con coincidencias indexadas (`-u`, `-t`, `_SYSTEMD_UNIT=`, `--since`) y usá `-g` como última etapa, o pagás una descompresión completa de todo el journal.

**A5.** `_TRANSPORT=stdout` significa que la entrada llegó por la tubería que systemd conecta al stdout/stderr de un servicio (`StandardOutput=journal`, el valor por defecto). Cualquier servicio que simplemente imprime a stdout obtiene integración con el journal gratis, con un `_SYSTEMD_UNIT` confiable adjunto — que es por qué "loguear a stdout" es el comportamiento correcto para un servicio gestionado por systemd o containerizado, y por qué escribir tu propio archivo dentro de la unidad tira esos metadatos a la basura.

**A6.** journald respeta **ambos** límites y toma en todo momento el resultado más restrictivo. `SystemKeepFree=1G` significa que debe dejar 1 GB libre en `/var`; con solo 1,4 GB libres puede usar como máximo ~0,4 GB, muy por debajo de `SystemMaxUse=2G`. Además journald calcula un valor por defecto implícito del 10% de la capacidad del sistema de archivos con tope de 4 GB cuando no está definido, y `SystemMaxUse` nunca anula hacia arriba a `SystemKeepFree`.

**A7.** El límite se aplica **por servicio** — journald lo lleva por el `_SYSTEMD_UNIT`/cgroup del emisor, así que una sola unidad ruidosa no puede silenciar al resto del host. `RateLimitBurst=0` deshabilita la limitación por tasa para todas las unidades, lo que elimina la última defensa contra una tormenta de logs que llene `/var`, ahogue la E/S de disco y empuje fuera, por los límites de retención, las entradas que realmente necesitás. En producción, preferí subir el burst para la unidad específica mediante un drop-in (`LogRateLimitBurst=` en la unidad de *servicio*) antes que deshabilitarlo globalmente.

**A8.** `ForwardToSyslog=yes` hace que journald copie cada entrada al socket de syslog; `imuxsock` hace que rsyslog lea `/dev/log` directamente. Un mensaje enviado a `/dev/log` puede entonces registrarse dos veces — una desde el socket, otra desde el reenvío de journald — duplicando el tamaño del archivo y sesgando cualquier alerta basada en conteos. Resolvelo eligiendo exactamente un camino: o bien `module(load="imuxsock" SysSock.Use="off")` más `module(load="imjournal" StateFile="imjournal.state")` (el journal es la única fuente), o mantené `imuxsock` y poné `ForwardToSyslog=no` en `journald.conf`.

**A9.** Sin FSS, `--verify` chequea solo la consistencia interna: el hash/checksum de cada objeto, los arreglos de entradas y la estructura del archivo — detecta corrupción (bloques dañados, truncamiento, una escritura que se cortó). **No** detecta manipulación deliberada, porque un atacante con root puede recalcular esos hashes. `journalctl --setup-keys` establece Forward Secure Sealing: una clave de sellado que evoluciona con el tiempo, guardada en el host, y una clave de verificación guardada fuera del host. Después de eso, `--verify --verify-key=...` prueba que las entradas escritas *antes* de un compromiso no fueron alteradas, porque el atacante ya no posee las claves pasadas.

**A10.**
- `local3-warn-and-above.log` → 3 líneas: `warning`, `err`, `crit` (severidad ≤ 4).
- `local3-notice-only.log` → 1 línea: `notice` (`=` fija la severidad exacta).
- `local3-no-debug.log` → 5 líneas: todo lo emitido salvo `debug`.

**A11.** Agregá `=`: `local3.=warning`. Para capturar cada severidad de la facility, usá `local3.*` (el comodín), que es equivalente a `local3.debug` dada la semántica de "y más severo" pero declara la intención explícitamente.

**A12.** `stop` descarta el mensaje para que ninguna regla posterior lo vea. Sin él, el mensaje sigue bajando por el conjunto de reglas y también va a ser capturado por el `50-default.conf` de la distribución — cayendo típicamente en `/var/log/syslog` o `/var/log/messages`. Para una regla cuyo propósito es enrutar contenido que contiene `SECRET` hacia un archivo restringido, omitir `stop` significa que el secreto *también* se escribe en el log general legible por todo el mundo: la regla de redacción no logra nada, en silencio.

**A13.** `$rawmsg` es el mensaje exactamente como fue recibido, incluyendo el encabezado `<PRI>`, el timestamp, el hostname y el tag. `$msg` es solo la parte MSG después de que el encabezado fue parseado — y notá que normalmente conserva el espacio inicial que syslog pone después del tag. Así que `:msg, contains, "p99"` no va a coincidir con un hostname, pero un filtro escrito contra `$rawmsg` podría coincidir con el nombre de *otro host* que aparezca en el encabezado, y `:msg, isequal, "text"` falla sorprendentemente seguido por culpa de ese espacio inicial. Preferí `contains`/`regex` sobre `$msg`, o `startswith` solo cuando hayas tenido en cuenta el espacio.

**A14.** `155` = `19 * 8 + 3` → facility `local3`, severidad `err`. El `1` después del PRI es el campo VERSION del protocolo syslog, definido por el **RFC 5424** (el protocolo syslog estructurado que reemplazó al formato informativo "BSD syslog" del RFC 3164). `RSYSLOG_SyslogProtocol23Format` emite RFC 5424 con timestamps ISO 8601 que incluyen zona horaria, un formato de cable mucho mejor que el ambiguo `Sep 18 09:21:44` del RFC 3164 sin año y sin zona.

**A15.** Sin `queue.filename` la cola es puramente en memoria (`queue.type="LinkedList"` sigue igual, pero sin asistencia de disco), acotada por `queue.size="10000"`. A 200 msg/s la cola se llena en 50 segundos; todo lo posterior se descarta cuando se alcanza la marca de agua alta y entra en juego la política de descarte. A lo largo de 40 minutos conservarías 10 000 mensajes y perderías aproximadamente **470 000**. `queue.filename` + `queue.spoolDirectory` es lo que la hace *asistida por disco*: la memoria absorbe ráfagas, el disco absorbe caídas hasta `queue.maxDiskSpace`.

**A16.**
- **UDP** — dispará y olvidate. La pérdida es invisible: sin retransmisión, sin acuse de recibo, truncamiento silencioso por encima de la MTU. Aceptable solo para telemetría de bajo valor y alto volumen.
- **TCP** — el kernel garantiza entrega ordenada y retransmitida *al buffer de socket del par*. No garantiza que el rsyslog del par haya desencolado y escrito el mensaje: ante un crasheo del receptor, los mensajes que estaban en los buffers de socket y de aplicación se esfuman, y el emisor nunca se entera.
- **RELP** (`omrelp`/`imrelp`) — agrega un acuse de recibo a nivel de aplicación por lote. El emisor solo saca un mensaje de su cola una vez que el receptor confirma que se hizo responsable de él, cerrando exactamente el hueco que deja TCP.

**A17.** Al apagarse, `saveOnShutdown="on"` persiste la porción en memoria de la cola al directorio de spool, para que un reinicio planificado no pierda los mensajes que todavía no habían sido reenviados. El costo: con un backlog grande (digamos 1 GB de cola en disco más una cola de memoria llena) la escritura puede llevar minutos, y systemd eventualmente va a alcanzar `TimeoutStopSec` y hacerle `SIGKILL` a rsyslog — perdiendo los datos igual *y* demorando el reinicio. En nodos con colas grandes, subí el timeout de parada de la unidad deliberadamente o aceptá la pérdida de manera consciente.

**A18.** logrotate llamó a `rename("app.log", "app.log-20260918")` — lo que cambia la entrada de directorio, no el inodo — y después creó (`creat()`) un `app.log` nuevo (la directiva `create`). El fd 3 del escritor todavía referencia el *inodo original*, alcanzable ahora solo bajo el nombre nuevo; después de que `rotate 14` eventualmente desenlace ese nombre, el inodo tiene cero enlaces pero una cuenta de aperturas distinta de cero, así que el kernel lo mantiene vivo y sus bloques asignados hasta que se cierre el último descriptor. Por eso `df` muestra un disco lleno mientras `du` no muestra nada: el espacio pertenece a un archivo sin nombre. `lsof +L1` lista exactamente estos.

**A19.** `copytruncate` copia el contenido del archivo al nombre rotado, y después llama a `truncate(fd, 0)` sobre el inodo original. Todo lo que el escritor agregue **entre la copia y el truncamiento se pierde**, y un escritor que use `O_APPEND` con un offset cacheado puede dejar un agujero disperso de bytes NUL al comienzo del archivo nuevo. Es un recurso de último momento para procesos a los que no se puede hacer reabrir — no un valor por defecto. `delaycompress` existe porque la compresión ocurre *después* de la rotación: si el escritor todavía no reabrió (está por recibir su `SIGHUP`, o usa `copytruncate`), comprimir de inmediato el archivo recién rotado comprimiría un archivo que todavía se está escribiendo. `delaycompress` posterga la compresión un ciclo para que el archivo esté definitivamente quieto.

**A20.** Sin `sharedscripts`, el bloque `postrotate` corre **una vez por archivo coincidente** — seis llamadas a `systemctl kill -s HUP rsyslog.service` en un bucle apretado. Más allá del trabajo desperdiciado, los HUP repetidos hacen que rsyslog relea su configuración y reabra todas sus salidas una y otra vez, y cualquier rotación que todavía esté en curso puede intercalarse mal. `sharedscripts` lo colapsa a una única ejecución después de que los seis archivos fueron rotados.

**A21.** journald implementa rotación y retención internamente — `SystemMaxFileSize`, `MaxFileSec`, `SystemMaxUse`, `MaxRetentionSec` — sellando el archivo activo y empezando uno nuevo, y después vaciando los viejos. Una rotación externa corrompería el formato. Los equivalentes de cara al operador son `journalctl --rotate`, `--vacuum-size=`, `--vacuum-time=`, `--vacuum-files=`, más `SIGUSR2` al demonio para una rotación inmediata (y `SIGUSR1` para volcar `/run` dentro de `/var/log/journal`).

**A22.** Cada combinación distinta de valores de etiqueta es un **stream**. A 5 req/s un día son 432 000 pedidos, cada uno con un `trace_id` único → hasta 432 000 streams, contra un puñado para `{job, env, level}`. El índice de Loki crece con la cantidad de streams, cada stream mantiene un chunk abierto en la memoria del ingester (los chunks se vuelcan solo cuando se llenan o quedan inactivos), y las consultas tienen que fusionar cientos de miles de chunks diminutos y mal comprimidos. Esta es la caída canónica de Loki: OOM del ingester, errores de `per-stream rate limit` y `max streams per user`. Los valores de alta cardinalidad van en la **línea**, encontrados con una expresión de filtro, nunca en una etiqueta.

**A23.** De la más barata a la más cara:
1. `{job="drill", level="error"}` — búsqueda pura sobre el índice; solo se traen los chunks de los streams coincidentes.
2. `{job="drill"} |= "502"` — un filtro de línea, pero Loki lo aplica como una coincidencia rápida de subcadena sobre el contenido comprimido del chunk antes de cualquier parseo; trae todos los chunks de `job=drill` pero hace un trabajo mínimo por línea.
3. `{job="drill"} | json | status>=500` — trae los mismos chunks *y además* parsea como JSON cada línea hacia etiquetas antes de comparar. Los parsers son la etapa cara.
La regla práctica: acotá con el selector de streams, después filtros de línea (`|=`, `!=`, `|~`), y recién después parsers y filtros de etiqueta.

**A24.** La entrada se conserva pero queda etiquetada con la etiqueta interna `__error__="JSONParserErr"` (más `__error_details__`), y ninguna de las etiquetas extraídas esperadas existe. En un `rate()` o un `sum by (...)` esas entradas o bien caen en una serie aparte o desaparecen de un agrupamiento `by`, sesgando la métrica en silencio. `| __error__=""` conserva solo las líneas que parsearon limpiamente, lo que vuelve honesta a la métrica — pero entonces tenés que alertar por separado sobre la *tasa de errores de parseo*, o un cambio de formato se convierte en una pérdida de datos invisible.

**A25.** Previene el incidente del "timestamp de ingesta": cuando un colector está atrasado o se reinicia, miles de líneas emitidas a lo largo de la última hora quedan todas estampadas con el momento en que fueron enviadas, colapsando en un único pico en el dashboard y destruyendo el ordenamiento que necesitás para reconstruir una caída. El modo de falla nuevo: con un reloj de aplicación equivocado, las entradas llegan estampadas muy en el pasado o el futuro — Loki rechaza entradas fuera de orden o demasiado viejas por stream (`entry too far behind`), y una entrada estampada en el futuro se vuelve invisible en cualquier dashboard de "los últimos 15 minutos" hasta que el tiempo real la alcance.

**A26.** El filtro `date` falta o su patrón `match` no le calza al `ts` entrante, así que Elasticsearch cae de vuelta al `@timestamp` propio de Logstash (el momento de creación del evento). Los dashboards se ven bien en estado estacionario porque el retraso de ingesta es de un segundo o dos y ambos timestamps son casi idénticos; la ilusión se rompe la primera vez que se desarrolla un backlog, momento en el cual el gráfico muestra la *recuperación* en lugar del *incidente*, y todos los eventos del backlog aparecen simultáneamente. Una etiqueta `_dateparsefailure` en los documentos es la pista delatora.

**A27.** Diagnóstico en orden: (1) traé una línea cruda que falle — para eso existe `output { file }` para la rama de falla, y por eso `remove_field => ["message"]` debe correr *después* de que se decide la rama de falla; (2) probá el patrón contra esa línea exacta en el Grok Debugger de Kibana o con `logstash -e` usando un input `stdin`; (3) revisá los culpables de siempre — un campo opcional, un nombre de componente de varias palabras comido por la voracidad de `%{DATA}`, un formato de timestamp cambiado, o finales de línea CRLF; (4) anclá el patrón (`^...$`) y preferí patrones específicos (`%{NUMBER}`, `%{WORD}`) sobre `%{DATA}`/`%{GREEDYDATA}`, que causan backtracking catastrófico. Si el formato tiene delimitadores estables, pasate al filtro **`dissect`**: divide por delimitadores literales sin motor de regex y típicamente es varias veces más rápido.

**A28.** El registry guarda, por input, la identidad del archivo (dispositivo/inodo o huella) y el offset en bytes ya consumido. Borralo con Filebeat detenido y, al reiniciar, cada archivo coincidente se trata como nuevo y se relee desde el principio según los ajustes de `ignore_older`/`prospector` — una ingesta masiva de duplicados. Cambiar el `id` del input `filestream` tiene el mismo efecto para los archivos de ese input, porque las entradas del registry están indexadas por el id del input: precisamente por esto el `id` es obligatorio para `filestream` y debe tratarse como inmutable una vez desplegado.

**A29.** **Elasticsearch** puede responderla sin escaneo: `trace_id` es un término indexado, así que una búsqueda en el índice invertido salta directo a los documentos coincidentes sin importar el rango temporal. Eso se paga con tamaño de índice (a menudo mayor que los logs crudos), presión sobre el heap, gestión de mappings y el peso operativo de un clúster de búsqueda distribuido. **Loki** guarda solo etiquetas en el índice; `trace_id` vive en la línea, así que la misma pregunta se vuelve un descomprimir-y-filtrar por fuerza bruta sobre cada chunk de la ventana — barato a 30 minutos, prohibitivo a 30 días. La recompensa de Loki es un costo de almacenamiento y operación dramáticamente menor, así que la elección es: acceso aleatorio con índice pesado (Elasticsearch) contra almacenamiento barato con escaneos acotados en el tiempo (Loki).

**A30.** Si el driver soporta **lectura** de logs además de escritura. `docker logs` lo sirve la API de lectura del driver, que solo implementan `json-file`, `local` y `journald` (más `awslogs`/`gcplogs` en algunas versiones); `syslog`, `fluentd`, `gelf` y compañía son de solo escritura, así que `docker logs` devuelve `Error response from daemon: configured logging driver does not support reading`. La regla práctica: si enviás fuera del host con un driver de solo escritura, mantené también `local`/`json-file` — o usá `journald`, que te da tanto el índice local como el reenvío.

**A31.** `kubectl logs --previous` (`-p`) lee la *instancia de contenedor terminada anterior*. El kubelet guarda exactamente el log de una instancia anterior por contenedor; se borra cuando se borra el objeto pod, cuando el nodo recupera disco bajo presión de desalojo, cuando el contenedor se reinicia otra vez (la anterior a la anterior ya no está), o si el pod se reprograma a otro nodo. Esa ventana de una sola generación es el argumento para enviar los logs fuera del nodo antes de que el crash loop te pase por encima.

**A32.** ~50 MiB ÷ 2 MiB/min = **unos 25 minutos** de historial. La conclusión: `kubectl logs` es una comodidad para depurar, no una herramienta de respuesta a incidentes. Cualquier investigación que empiece más de unos minutos después del evento tiene que ser servida por un sistema de agregación con retención independiente; si todavía dependés de `kubectl logs` para los postmortems, lo que falta es el pipeline de los ejercicios 6–7, no un `containerLogMaxSize` más grande.

**A33.** Un **DaemonSet a nivel de nodo** (Alloy/Promtail/Fluent Bit leyendo `/var/log/pods/`) es el valor por defecto: un colector por nodo sin importar la cantidad de pods, sin cambios en la aplicación, enriquecimiento automático con metadatos de Kubernetes, y sobrecarga de recursos constante. Un **sidecar** cuesta un contenedor por pod y duplica el esfuerzo — pero es la única opción cuando no se puede hacer que la aplicación escriba a stdout, por ejemplo un proceso heredado que escribe varios archivos de log distintos dentro de su propio sistema de archivos (un log de acceso y uno de errores con formatos diferentes), o cuando un inquilino necesita una configuración de parseo/envío completamente distinta que un agente de nodo compartido no puede expresar. El híbrido habitual es un sidecar que simplemente hace `tail` de esos archivos hacia stdout, dejándole el envío al DaemonSet.

**A34.** Causa raíz: logrotate renombró el archivo (modo `create`) y la aplicación nunca reabrió, así que sigue agregando al inodo borrado — exactamente la reproducción del Ejercicio 4, esta vez en producción. Dos arreglos independientes: **(a)** en logrotate, agregar un `postrotate` que le señale a la aplicación que reabra (`kill -HUP`, o el mecanismo de reapertura propio de la app), o caer de vuelta a `copytruncate` para ese archivo; **(b)** en la aplicación, manejar `SIGHUP` cerrando y reabriendo su archivo de log — o, mejor, dejar de escribir archivos por completo y escribir a stdout, dejando que systemd/el runtime de contenedores sea dueño del ciclo de vida.

**A35.** Lo más plausible es que se haya promovido una etiqueta de alta cardinalidad en la etapa `labels:` — `trace_id`, `route` con parámetros de ruta, un nombre de pod, un id de usuario — así que lo que antes era un puñado de streams pasó a ser miles, y los límites por stream (`per_stream_rate_limit`, por defecto en el orden de pocos MB/s) ahora se aplican a streams que llevan cada uno una porción del tráfico. Agregar ingesters no ayuda porque el límite es **por stream**, no por ingester: el mismo stream sigue siendo propiedad de un ingester a la vez, y el arreglo correcto es sacar la etiqueta (mantener el campo en la línea) o, solo si la cardinalidad es genuinamente necesaria, subir el límite por stream a conciencia.

**A36.** Cada rotación con `dateext` crea un archivo nuevo, y cada generación comprimida otro más — multiplicá eso por un comodín que coincida con cientos de archivos de log por contenedor o por host y asignás cientos de miles de archivos pequeños, agotando los inodos mucho antes que los bytes. `rotate 14` (una cantidad acotada de rotaciones) es la directiva que lo previene: es lo único que alguna vez *borra* generaciones viejas. Una política con `dateext` y sin `rotate`/`maxage` crece sin límite. `df -i` pertenece al conjunto de alertas de todo host de logging, junto a `df -h`.

**A37.** (1) **El lado de la consulta** — el rango temporal, la zona horaria o el selector de streams del dashboard ya no coinciden con la realidad: se renombró una etiqueta, el panel filtra por `job="drill"` mientras que el colector ahora emite `job="drill-app"`, o el navegador está en una zona horaria distinta a la de los datos. Nada en el camino de ingesta mostraría esto. (2) **El nivel de log del propio emisor** — la aplicación se desplegó con `LOG_LEVEL=error` (o un feature flag apagó un camino de código), así que genuinamente no hay líneas para recolectar. Ambos se encuentran comparando contra una línea buena conocida que emitís a mano (`logger -t drill "canary $(date -Is)"`) y siguiéndola de punta a punta, que es por qué un canario sintético de log con una alerta sobre su ausencia es el único monitor que cubre toda la cadena de una sola vez.

</details>

---

## Fuentes oficiales

- LPI, *DevOps Tools Engineer exam 701 objectives* — https://www.lpi.org/our-certifications/exam-701-objectives/
- freedesktop.org, `journalctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- freedesktop.org, `journald.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- freedesktop.org, `systemd-journald.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- rsyslog, *Configuration* y *Queues* — https://www.rsyslog.com/doc/configuration/index.html · https://www.rsyslog.com/doc/concepts/queues.html
- IETF, RFC 5424, *The Syslog Protocol* — https://www.rfc-editor.org/rfc/rfc5424
- logrotate upstream — https://github.com/logrotate/logrotate
- Grafana, *Loki documentation* y *LogQL* — https://grafana.com/docs/loki/latest/ · https://grafana.com/docs/loki/latest/query/
- Grafana, *Promtail* (estado y migración a Alloy) — https://grafana.com/docs/loki/latest/send-data/promtail/
- Elastic, *Logstash* y *Filebeat* references — https://www.elastic.co/guide/en/logstash/current/index.html · https://www.elastic.co/guide/en/beats/filebeat/current/index.html
- Docker, *Configure logging drivers* — https://docs.docker.com/engine/logging/configure/
- Kubernetes, *Logging Architecture* — https://kubernetes.io/docs/concepts/cluster-administration/logging/