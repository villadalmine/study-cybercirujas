# Tema 4.3 — Comprender y usar Alertmanager: Ejercicios guiados

> **Alcance.** Estos ejercicios te llevan desde un proceso Alertmanager pelado hasta un pipeline de alertas completo: Prometheus evaluando reglas, empujando alertas por la red, y Alertmanager deduplicando, agrupando, enrutando, inhibiendo, silenciando y notificando. Cada paso es ejecutable y cada salida es la que deberías ver realmente. La división del trabajo es la idea más evaluada de este dominio — **Prometheus decide *cuándo* se dispara una alerta; Alertmanager decide *quién* se entera y *con qué frecuencia***.
>
> **Fuentes de referencia**
> - Alertmanager overview — https://prometheus.io/docs/alerting/latest/alertmanager/
> - Alertmanager configuration — https://prometheus.io/docs/alerting/latest/configuration/
> - Alerting rules (lado Prometheus) — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
> - `alertmanager_config` en `prometheus.yml` — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
> - Alertmanager clients / webhook payload — https://prometheus.io/docs/alerting/latest/clients/ y https://prometheus.io/docs/alerting/latest/configuration/#webhook_config
> - `amtool` y clustering HA — https://github.com/prometheus/alertmanager

---

## Entorno de laboratorio

Necesitás dos binarios en el `PATH`: `prometheus` (v2.53 LTS o v3.x) y `alertmanager` + `amtool` (v0.27.0 o más nuevo, distribuidos juntos en el mismo tarball). Trabajá desde un directorio vacío:

```bash
mkdir -p ~/pca-4.3 && cd ~/pca-4.3
alertmanager --version
amtool --version
prometheus --version
```

Esperado (las versiones pueden diferir):

```
alertmanager, version 0.27.0 (branch: HEAD, revision: 0aa3c2aad14cff039931923ab16b26b7481783b5)
amtool, version 0.27.0 ...
prometheus, version 2.53.2 ...
```

---

## Ejercicio 1 — Iniciar Alertmanager y leer su estado en runtime

1. Escribí una config mínima de Alertmanager `alertmanager.yml`:

   ```yaml
   route:
     receiver: 'null'
     group_by: ['alertname']
     group_wait: 30s
     group_interval: 5m
     repeat_interval: 4h

   receivers:
     - name: 'null'
   ```

2. **Validá la config antes de iniciar el proceso** — un parseo en dry-run que además compila cualquier template:

   ```bash
   amtool check-config alertmanager.yml
   ```

   Esperado:

   ```
   Checking 'alertmanager.yml'  SUCCESS
   Found:
    - global config
    - route
    - 0 inhibit rules
    - 1 receivers
    - 0 templates
   ```

3. Lanzalo (dejalo corriendo en esta terminal):

   ```bash
   alertmanager --config.file=alertmanager.yml
   ```

   Deberías ver `Listening address=[::]:9093` y `msg="Loading configuration file"`.

4. En una **segunda** terminal, apuntá `amtool` a la instancia en ejecución y leé el estado de cluster/build a través de la API v2:

   ```bash
   export ALERTMANAGER_URL=http://localhost:9093
   amtool config show --alertmanager.url=$ALERTMANAGER_URL
   curl -s http://localhost:9093/api/v2/status | python3 -m json.tool | head -n 25
   ```

   La salida de `curl` incluye `cluster`, `versionInfo` y el bloque `config` en vivo.

**Verificación**

- **Q1.1** ¿A qué puertos TCP se enlaza un Alertmanager por defecto, y para qué sirve cada uno?
- **Q1.2** `amtool check-config` pasó pero *nunca contactaste al servidor*. ¿Qué probó exactamente, y qué **no** probó?
- **Q1.3** El receiver se llama literalmente `'null'` y no tiene `*_configs`. ¿Qué le pasa a una alerta enrutada acá, y por qué es una configuración legítima?

---

## Ejercicio 2 — Hacer que Prometheus dispare una alerta y la empuje a Alertmanager

1. Creá un archivo de reglas de alerta `rules/alerts.yml`:

   ```yaml
   groups:
     - name: demo.rules
       rules:
         - alert: AlwaysFiring
           expr: vector(1) > 0
           for: 30s
           labels:
             severity: warning
             team: platform
           annotations:
             summary: "Synthetic alert used to exercise the pipeline"
             description: "This alert is up {{ $value }} and always fires."
   ```

2. Creá `prometheus.yml` que a la vez **cargue las reglas** y **sepa dónde vive Alertmanager**:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   rule_files:
     - "rules/*.yml"

   alerting:
     alertmanagers:
       - static_configs:
           - targets:
               - localhost:9093

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']
   ```

3. Validá el archivo de reglas, y luego iniciá Prometheus en una tercera terminal:

   ```bash
   promtool check rules rules/alerts.yml
   prometheus --config.file=prometheus.yml
   ```

   Salida esperada de `promtool`:

   ```
   Checking rules/alerts.yml
     SUCCESS: 1 rules found
   ```

4. Observá cómo la alerta sube por la máquina de estados. Inmediatamente después del arranque está **pending** (el temporizador `for: 30s` está corriendo); tras ~30 s pasa a **firing**:

   ```bash
   # synthetic ALERTS series generated by Prometheus itself
   curl -s 'http://localhost:9090/api/v1/query?query=ALERTS' \
     | python3 -c 'import sys,json; [print(r["metric"]["alertstate"], r["metric"]) for r in json.load(sys.stdin)["data"]["result"]]'
   ```

   Primera corrida (dentro de los 30 s): `pending {...}`. Después de que transcurre el `for`: `firing {...}`.

5. Confirmá que la alerta efectivamente cruzó la red hacia Alertmanager:

   ```bash
   amtool alert query
   ```

   Esperado:

   ```
   Alertname     Starts At                Summary
   AlwaysFiring  2026-08-09 12:00:31 UTC  Synthetic alert used to exercise the pipeline
   ```

**Verificación**

- **Q2.1** Nombrá los tres estados por los que pasa una alerta de Prometheus, y decí con precisión cuál de ellos hace que Prometheus envíe algo a Alertmanager.
- **Q2.2** ¿Cuál es el rol de la cláusula `for`? Si la quitaras, ¿cómo cambiaría el paso 4?
- **Q2.3** El bloque `alerting:` vive en `prometheus.yml`, pero `route:`/`receivers:` viven en `alertmanager.yml`. Trazá la línea de responsabilidad: qué componente evalúa `expr`, y qué componente decide el canal de destino.
- **Q2.4** Prometheus reenvía la alerta en firing a Alertmanager en cada ciclo de evaluación. ¿Por qué el operador no recibe spam una vez cada 15 s?

---

## Ejercicio 3 — Agrupamiento y las perillas de tiempo

1. Agregá una segunda regla correlacionada para que el agrupamiento tenga algo que colapsar. Anexá a `rules/alerts.yml`:

   ```yaml
         - alert: AlwaysFiringToo
           expr: vector(1) > 0
           for: 30s
           labels:
             severity: warning
             team: platform
           annotations:
             summary: "Second synthetic alert in the same group"
   ```

2. Cambiá el `route` de Alertmanager para que ambas alertas caigan en un solo grupo y para que los tiempos sean lo bastante cortos como para observarlos. Editá `alertmanager.yml`:

   ```yaml
   route:
     receiver: 'webhook'
     group_by: ['team']          # both alerts share team=platform → ONE group
     group_wait: 10s             # buffer before the FIRST notification of a new group
     group_interval: 30s         # wait before a notification about CHANGES to an existing group
     repeat_interval: 2m         # re-send an unchanged, still-firing group after this

   receivers:
     - name: 'webhook'
       webhook_configs:
         - url: 'http://127.0.0.1:5001/'
   ```

3. Iniciá un receiver descartable para que puedas *ver* las notificaciones agrupadas con sus timestamps:

   ```bash
   # terminal 4 — prints every JSON payload Alertmanager POSTs, with a timestamp
   python3 -m http.server 5001 &   # NO — use the line below instead:
   ```

   Usá este one-liner en su lugar (el servidor de la stdlib no puede devolver los bodies):

   ```bash
   python3 - <<'PY'
   from http.server import BaseHTTPRequestHandler, HTTPServer
   import json, datetime
   class H(BaseHTTPRequestHandler):
       def do_POST(self):
           n = int(self.headers.get('Content-Length', 0))
           body = json.loads(self.rfile.read(n) or b'{}')
           ts = datetime.datetime.now().strftime('%H:%M:%S')
           names = [a['labels']['alertname'] for a in body.get('alerts', [])]
           print(f"[{ts}] status={body.get('status')} groupKey={body.get('groupKey')} alerts={names}")
           self.send_response(200); self.end_headers()
       def log_message(self, *a): pass
   HTTPServer(('127.0.0.1', 5001), H).serve_forever()
   PY
   ```

4. Recargá Alertmanager (SIGHUP, no hace falta reiniciar) y forzá a ambas reglas a volver a firing reiniciando Prometheus si hace falta:

   ```bash
   curl -s -X POST http://localhost:9093/-/reload
   ```

5. Observá la terminal 4. Deberías ver **un** payload que contiene **ambas** alertas, llegando ~10 s después de que se activaron (eso es `group_wait`), y luego una repetición ~2 min más tarde (`repeat_interval`):

   ```
   [12:10:41] status=firing groupKey={}:{team="platform"} alerts=['AlwaysFiring', 'AlwaysFiringToo']
   [12:12:41] status=firing groupKey={}:{team="platform"} alerts=['AlwaysFiring', 'AlwaysFiringToo']
   ```

**Verificación**

- **Q3.1** Definí `group_wait`, `group_interval` y `repeat_interval` en una oración cada uno. ¿Cuál gobernó el retraso de ~10 s antes de la primera notificación? ¿Cuál gobernó la repetición de ~2 min?
- **Q3.2** Ambas alertas llegaron en un **único** POST. ¿Qué línea de config causó eso, y a qué la pondrías si quisieras *una notificación por alertname* en su lugar?
- **Q3.3** Una tercera alerta con `team=platform` empieza a dispararse 5 s después de que se envió la primera notificación. Con los tiempos de arriba, ¿aproximadamente cuánto pasa hasta que se le avisa al operador, y qué perilla lo decide?
- **Q3.4** ¿Cuál es la diferencia entre `group_by: []` (lista vacía) y `group_by: ['...']` con labels reales? ¿Cuándo es la lista vacía la elección correcta?

---

## Ejercicio 4 — El árbol de enrutamiento, los matchers y `amtool config routes test`

1. Reemplazá el bloque `route` por un árbol real: un receiver por defecto, una rama de severidad crítica que además continúa, y una rama por equipo. Editá `alertmanager.yml`:

   ```yaml
   route:
     receiver: 'default'
     group_by: ['alertname']
     routes:
       - matchers:
           - severity="critical"
         receiver: 'pager'
         continue: true            # keep evaluating siblings after a match
       - matchers:
           - team="database"
         receiver: 'db-team'
       - matchers:
           - team=~"platform|infra"
         receiver: 'platform-team'

   receivers:
     - name: 'default'
       webhook_configs: [{ url: 'http://127.0.0.1:5001/' }]
     - name: 'pager'
       webhook_configs: [{ url: 'http://127.0.0.1:5001/pager' }]
     - name: 'db-team'
       webhook_configs: [{ url: 'http://127.0.0.1:5001/db' }]
     - name: 'platform-team'
       webhook_configs: [{ url: 'http://127.0.0.1:5001/platform' }]
   ```

2. Validá, y luego **renderizá el árbol** tal como lo entiende Alertmanager:

   ```bash
   amtool check-config alertmanager.yml
   amtool config routes show --config.file=alertmanager.yml
   ```

   `routes show` imprime un árbol indentado de matchers → receivers.

3. **Probá el enrutamiento sin enviar nada** — alimentá un conjunto de labels sintético y mirá qué receiver(s) gana(n):

   ```bash
   amtool config routes test --config.file=alertmanager.yml severity=critical team=database
   ```

   Esperado (dos receivers, porque `pager` tiene `continue: true`):

   ```
   pager
   db-team
   ```

4. Probá un conjunto de labels que solo matchee la rama del regex:

   ```bash
   amtool config routes test --config.file=alertmanager.yml team=infra
   ```

   Esperado:

   ```
   platform-team
   ```

5. Agregá una aserción dura que puedas poner en CI — que falle el pipeline si el enrutamiento cambia alguna vez:

   ```bash
   amtool config routes test --config.file=alertmanager.yml \
     --verify.receivers=pager severity=critical team=database
   echo "exit=$?"
   ```

   `exit=0` significa que el receiver esperado estuvo entre los matches; un exit distinto de cero significa que el enrutamiento tuvo una regresión.

**Verificación**

- **Q4.1** El enrutamiento es un **recorrido del árbol en profundidad (depth-first)**. ¿Qué cambia `continue: true` en ese recorrido, y por qué la alerta crítica llegó a dos receivers en el paso 3?
- **Q4.2** Una ruta matchea una alerta pero los labels de la alerta no matchean ninguna de sus rutas *hijas*. ¿Qué receiver la maneja — el del padre, o ninguno?
- **Q4.3** Escribí el matcher que selecciona alertas donde `severity` sea cualquier cosa **excepto** `info`. Después escribí uno que matchee `region` contra el regex `us-(east|west)-\d`.
- **Q4.4** ¿Por qué se considera `amtool config routes test` más seguro que recargar la config en vivo y observar las notificaciones al validar un cambio de enrutamiento?

---

## Ejercicio 5 — Silences e inhibición (las dos formas de suprimir)

### Parte A — Silences (impulsadas por el operador, temporales, matcheadas por label)

1. Con `AlwaysFiring` todavía en firing, creá un silence de dos horas que la matchee:

   ```bash
   amtool silence add alertname=AlwaysFiring severity=warning \
     --duration=2h --author="$USER" --comment="Planned maintenance window"
   ```

   La salida es el UUID del silence:

   ```
   6ab7f6c1-6d3d-4b8a-9c0e-2e0d0b5a1f22
   ```

2. Confirmá que la alerta ahora está **suprimida**, e inspeccioná el silence:

   ```bash
   amtool silence query
   amtool alert query --alertmanager.url=$ALERTMANAGER_URL
   ```

   `amtool silence query` muestra los matchers, la expiración y el autor. La alerta sigue *activa* en Alertmanager pero su estado pasa a `suppressed`, así que no se envía ninguna notificación.

3. Terminá el silence antes de tiempo:

   ```bash
   amtool silence expire 6ab7f6c1-6d3d-4b8a-9c0e-2e0d0b5a1f22
   ```

   Las notificaciones se reanudan en la siguiente evaluación.

### Parte B — Inhibición (impulsada por reglas, una alerta silencia a otra)

4. Agregá un bloque `inhibit_rules` a `alertmanager.yml` para que una `critical` silencie a una `warning` **para la misma identidad de alerta**:

   ```yaml
   inhibit_rules:
     - source_matchers:
         - severity="critical"
       target_matchers:
         - severity="warning"
       equal: ['alertname', 'cluster']
   ```

5. Recargá, y luego inyectá una critical y una warning que comparten `alertname` y `cluster` directamente en Alertmanager con `amtool` (esquivando Prometheus para controlar los labels con exactitud):

   ```bash
   curl -s -X POST http://localhost:9093/-/reload
   amtool alert add alertname=DiskFull cluster=prod severity=critical --annotation=summary="disk full"
   amtool alert add alertname=DiskFull cluster=prod severity=warning  --annotation=summary="disk high"
   amtool alert query
   ```

   Ambas aparecen en `alert query`, pero la **warning está suprimida por inhibición** — revisá su estado:

   ```bash
   curl -s http://localhost:9093/api/v2/alerts | \
     python3 -c 'import sys,json; [print(a["labels"]["severity"], a["status"]["state"], a["status"]["inhibitedBy"]) for a in json.load(sys.stdin)]'
   ```

   Esperado:

   ```
   critical active []
   warning suppressed ['<fingerprint-of-critical>']
   ```

**Verificación**

- **Q5.1** Enunciá la diferencia fundamental entre un **silence** y una **inhibición** — quién crea cada uno, cuánto dura cada uno, y qué lo dispara.
- **Q5.2** En la regla de inhibición, ¿cuál es el propósito del campo `equal:`? ¿Qué bug aparece si lo omitís manteniendo los mismos matchers de source/target?
- **Q5.3** Una alerta silenciada y una alerta inhibida aparecen ambas en `amtool alert query`. Entonces, ¿cómo distinguís, para una alerta dada, *por qué* no está notificando?
- **Q5.4** Creaste el silence con un matcher sobre `severity=warning`. Si el label `severity` de la alerta cambiara a `critical` mientras el silence está activo, ¿seguiría silenciada? Explicá.

---

## Ejercicio 6 — Receiver con templates y clustering de alta disponibilidad

1. Agregá un archivo de template reutilizable `templates/notifications.tmpl`:

   ```
   {{ define "slack.custom.text" }}{{ range .Alerts }}*{{ .Labels.alertname }}* ({{ .Labels.severity }})
   {{ .Annotations.summary }}
   {{ end }}{{ end }}
   ```

2. Referencialo y usalo en un receiver en `alertmanager.yml`:

   ```yaml
   templates:
     - 'templates/*.tmpl'

   receivers:
     - name: 'default'
       slack_configs:
         - api_url: 'https://hooks.slack.com/services/T000/B000/XXXX'
           channel: '#alerts'
           send_resolved: true
           title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
           text: '{{ template "slack.custom.text" . }}'
   ```

3. Validá que el template compila (por esto es que `check-config` reporta la cantidad de templates):

   ```bash
   amtool check-config alertmanager.yml
   ```

   El bloque `Found:` ahora muestra `1 templates`.

4. Entendé la HA. Alertmanager está pensado para correr como un **cluster de ≥2 peers que hacen gossip por el puerto 9094** para que un flujo de alertas duplicado (de Prometheis en HA) igualmente se notifique **una sola vez**. Iniciá un cluster local de dos nodos:

   ```bash
   # node 1
   alertmanager --config.file=alertmanager.yml \
     --cluster.listen-address=127.0.0.1:9094 \
     --web.listen-address=127.0.0.1:9093 \
     --storage.path=/tmp/am1 &

   # node 2 joins node 1
   alertmanager --config.file=alertmanager.yml \
     --cluster.listen-address=127.0.0.1:9095 \
     --cluster.peer=127.0.0.1:9094 \
     --web.listen-address=127.0.0.1:9096 \
     --storage.path=/tmp/am2 &
   ```

5. Confirmá que la malla se formó:

   ```bash
   curl -s http://127.0.0.1:9093/api/v2/status | python3 -c 'import sys,json; s=json.load(sys.stdin)["cluster"]; print("status:", s["status"], "peers:", len(s["peers"]))'
   ```

   Esperado:

   ```
   status: ready peers: 2
   ```

   Configurá **cada** Prometheus para que envíe a **todos** los peers (no a un load balancer):

   ```yaml
   alerting:
     alertmanagers:
       - static_configs:
           - targets: ['127.0.0.1:9093', '127.0.0.1:9096']
   ```

**Verificación**

- **Q6.1** ¿Por qué cada Prometheus debe estar configurado con **todos** los peers de Alertmanager, en lugar de un único VIP/load balancer por delante de ellos?
- **Q6.2** Si ambos peers reciben la misma alerta en firing, ¿qué mecanismo evita que el operador reciba dos pages idénticos? Nombrá el concepto y el puerto que usan los peers para coordinarse.
- **Q6.3** Al clustering de Alertmanager se lo describe como "AP" (de CAP). ¿Qué hace un cluster **particionado** — descarta notificaciones, o arriesga enviar duplicados — y por qué es ese el default más seguro para el alerting?
- **Q6.4** Está seteado `send_resolved: true`. ¿Qué notificación extra recibe ahora el operador, y qué campo de nivel superior en el payload del webhook/Slack la distingue (`firing` vs …)?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

**Q1.1** `9093/tcp` sirve la UI web y la API HTTP (`/api/v2/...`). `9094` (TCP **y** UDP) es el puerto de gossip del cluster, usado por el protocolo memberlist de HashiCorp para la sincronización de estado entre peers. Solo `9093` importa para una instalación de un solo nodo.

**Q1.2** Probó que el archivo es **YAML sintácticamente válido, estructuralmente una config de Alertmanager legal, y que todos los templates referenciados compilan**. **No** probó que el servidor en ejecución haya cargado este archivo, que los receivers puedan efectivamente alcanzar Slack/SMTP/webhooks, ni que el enrutamiento haga lo que pretendés para conjuntos de labels reales. Es un lint estático, no una verificación en vivo.

**Q1.3** La alerta se matchea, se agrupa y se procesa normalmente, y luego se entrega a un receiver que **no tiene integraciones de notificación**, así que no se envía nada — es un "trago"/agujero negro deliberado. Usos legítimos: un catch-all por defecto para que las alertas no den error mientras armás el enrutamiento, o una rama explícita para alertas que a sabiendas querés descartar.

**Q2.1** `inactive → pending → firing`. Prometheus envía a Alertmanager **solo las alertas en estado `firing`** (y también envía notificaciones de resolución cuando una alerta en firing se despeja). Las alertas `pending` — las que todavía están dentro de su ventana `for` — nunca se envían.

**Q2.2** `for` exige que `expr` sea continuamente verdadero durante esa duración antes de que la alerta transicione de `pending` a `firing`; hace de-bounce contra flapping/picos transitorios. Quitalo y la alerta pasa directo a `firing` en la primera evaluación verdadera — en el paso 4 verías `firing` de inmediato, sin fase `pending`.

**Q2.3** Prometheus evalúa `expr` en cada `evaluation_interval`, es dueño del temporizador `for`, y genera la alerta con sus labels/annotations — decide **cuándo**. Alertmanager recibe la alerta en firing y, vía su `route`/`receivers`, decide **quién** es notificado y **cómo** — el canal de destino. La línea: evaluación de reglas y lógica de firing = Prometheus; agrupamiento, enrutamiento, silencing, inhibición, notificación = Alertmanager.

**Q2.4** Alertmanager **deduplica**. Prometheus reenvía la misma alerta en cada ciclo como keep-alive, pero Alertmanager indexa las alertas por su fingerprint de labels y solo notifica según sus propios temporizadores (`group_wait`, `group_interval`, `repeat_interval`) — los envíos idénticos repetidos colapsan en una sola alerta rastreada.

**Q3.1**
- `group_wait`: cuánto se hace buffer de un grupo **recién creado** antes de la *primera* notificación, para que las alertas co-ocurrentes se agrupen (default 30s). ← gobernó el retraso de ~10 s.
- `group_interval`: cuánto se espera antes de enviar una notificación sobre **cambios** (alertas nuevas/resueltas) a un grupo que *ya* notificó (default 5m).
- `repeat_interval`: cuánto antes de **reenviar** una notificación de un grupo sin cambios y todavía en firing (default 4h). ← gobernó la repetición de ~2 min.

**Q3.2** `group_by: ['team']` — ambas alertas comparten `team=platform`, así que colapsan en un grupo y un POST. Para una notificación por alertname, seteá `group_by: ['alertname']` (o agregá `alertname` de modo que las dos alertas ya no compartan todos sus labels de agrupamiento).

**Q3.3** Aproximadamente `group_interval` (~30 s) después de que empieza, porque el grupo ya existe y ya notificó — agregar una alerta es un *cambio*, que está gobernado por `group_interval`, no por `group_wait`.

**Q3.4** Con labels reales, Alertmanager crea un grupo por cada combinación distinta de esos valores de label. `group_by: []` pone **cada** alerta que fluye por esa ruta en un **único** grupo (agrega todo en un solo flujo de notificaciones). La lista vacía es correcta cuando querés un único digest y nunca querés que las alertas se separen — p. ej. un catch-all de bajo volumen. (Nota: `group_by: ['...']` no puede mezclarse con el wildcard especial `'...'` salvo mediante la forma literal `['...']`, que agrupa por *todos* los labels.)

**Q4.1** El árbol se recorre en profundidad (depth-first); por defecto, una vez que una ruta matchea, su subárbol maneja la alerta y las **rutas hermanas no se evalúan**. `continue: true` anula eso: después de que esta ruta matchea, la evaluación **continúa hacia las rutas hermanas**, así que una alerta puede entregarse a varios receivers. La alerta crítica matcheó `pager` (que tenía `continue: true`) y luego también matcheó la hermana `team="database"` → dos receivers.

**Q4.2** El receiver de la **ruta padre** la maneja. Una ruta matcheada siempre recae en su propio `receiver` si ninguno de sus hijos matchea — el enrutamiento nunca "cae en el vacío" una vez que un padre ha matcheado.

**Q4.3** No-info: `severity!="info"`. Regex: `region=~"us-(east|west)-\d"`. (Operadores: `=` igual, `!=` no-igual, `=~` regex-match, `!~` regex-no-match; los regex están completamente anclados.)

**Q4.4** `amtool config routes test` es una **simulación pura y offline** contra el archivo de config — no envía notificaciones, no muta estado, y no necesita un servidor en ejecución, así que es seguro correrlo en CI y no puede paginar a nadie. Recargar la config en vivo y observar notificaciones reales arriesga alertar al on-call durante una prueba y solo ejercita los conjuntos de labels que casualmente estén en firing.

**Q5.1** Un **silence** lo crea un operador (UI/`amtool`/API), es temporal (tiene una expiración explícita), y matchea alertas por **label matchers** — dice "silenciá cualquier cosa que matchee estos labels durante N horas." Una **inhibición** se define declarativamente en la config (`inhibit_rules`), dura tanto como la alerta **source** esté en firing, y se dispara por la *presencia de otra alerta* — "mientras una critical esté en firing, silenciá las warnings relacionadas."

**Q5.2** `equal:` lista los labels que deben ser **idénticos** entre source y target para que la inhibición aplique — acota la supresión a la *misma* entidad. Omitilo y **cualquier** alerta critical en cualquier lado inhibiría a **toda** warning que matchee el target matcher, a lo ancho del cluster — silenciarías warnings no relacionadas en el momento en que se dispara una sola critical no relacionada.

**Q5.3** Consultá el estado de la alerta vía la API (`/api/v2/alerts`) o la UI: el `status.state` es `suppressed` en ambos casos, pero el payload distingue la causa — `status.silencedBy` lista los IDs de silence, y `status.inhibitedBy` lista los fingerprints de las alertas source que inhiben. Un `silencedBy` no vacío = silence; un `inhibitedBy` no vacío = inhibición.

**Q5.4** No — los silences matchean sobre los **valores de label actuales**. Si `severity` cambió de `warning` a `critical`, la alerta ya no satisface el matcher `severity=warning`, el silence deja de aplicar, y las notificaciones se reanudan (asumiendo que nada más la suprima). El matcheo se re-evalúa contra los labels vivos de la alerta, no queda congelado al momento de crear el silence.

**Q6.1** Porque los peers de Alertmanager **no se hacen de proxy de alertas entre sí** — cada Prometheus debe entregar cada alerta en firing a **cada** peer de forma independiente. Los peers luego hacen gossip del estado de *notificación* para deduplicar. Un único VIP enviaría cada alerta a un solo peer; si ese peer muriera perderías alertas, y el peer sobreviviente nunca se enteraría de ellas. Enviar a todos los peers es como el sistema tolera la falla de un peer sin lagunas.

**Q6.2** Deduplicación vía el **cluster de gossip**: los peers comparten qué notificaciones ya se enviaron (usando memberlist sobre el puerto de cluster, `9094` por defecto), y un peer designado envía tras un breve retraso según su posición mientras los demás se contienen, de modo que las alertas idénticas de Prometheis en HA producen un solo page.

**Q6.3** Es **AP**: bajo una partición de red los peers siguen operando de forma independiente y preferirán **enviar notificaciones duplicadas** antes que descartarlas. Para el alerting ese es el modo de falla más seguro — un page duplicado es molesto, un page *perdido* durante un incidente es peligroso — así que Alertmanager favorece la disponibilidad por sobre la consistencia estricta del estado de dedup.

**Q6.4** Con `send_resolved: true`, cuando una alerta en firing se despeja, Prometheus envía una notificación **resolved** y Alertmanager la reenvía, así que el operador recibe un "todo despejado." El campo `status` de nivel superior del payload es `resolved` (versus `firing`), y cada objeto de alerta además lleva un `endsAt` en el pasado; los templates típicamente ramifican sobre `.Status`/`{{ .Status | toUpper }}` para renderizarla distinto.

</details>