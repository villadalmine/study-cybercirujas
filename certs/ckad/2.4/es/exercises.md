# Ejercicios: 2.4 Understand API deprecations (CKAD v1.35)

## Ejercicio 1: Explorar las apiVersions vigentes en el cluster

1. Listá todas las apiVersions que expone el API server:
   ```bash
   kubectl api-versions | sort
   ```
2. Filtrá los recursos que pertenecen al grupo `batch`:
   ```bash
   kubectl api-resources --api-group=batch
   ```
3. Confirmá qué versión usa hoy el recurso `CronJob`:
   ```bash
   kubectl explain cronjob | head -5
   ```
4. Repetí el paso 3 para `poddisruptionbudget` (grupo `policy`) y para `ingress` (grupo `networking.k8s.io`).

**Preguntas**
1. `CronJob` llegó a GA en `batch/v1` en Kubernetes 1.21. ¿Qué apiVersion usaba antes, y qué comando usaste para confirmar la versión activa?
2. ¿Qué diferencia hay entre `kubectl api-versions` y `kubectl api-resources`?

---

## Ejercicio 2: Reproducir el error de una apiVersion removida

1. Creá `cronjob-viejo.yaml` con una apiVersion obsoleta:
   ```yaml
   apiVersion: batch/v1beta1
   kind: CronJob
   metadata:
     name: demo-cron
   spec:
     schedule: "*/5 * * * *"
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: hello
               image: busybox
               command: ["echo", "hola"]
             restartPolicy: OnFailure
   ```
2. Intentá aplicarlo:
   ```bash
   kubectl apply -f cronjob-viejo.yaml
   ```
3. Leé el mensaje de error devuelto por `kubectl` (algo como `no matches for kind "CronJob" in version "batch/v1beta1"`).
4. Corregí el manifiesto cambiando `apiVersion` a `batch/v1` y volvé a aplicarlo. Confirmá que el `CronJob` se creó:
   ```bash
   kubectl get cronjob demo-cron
   ```

**Preguntas**
1. ¿Por qué falla el paso 2? ¿Ese error indica que la API está "deprecated" o que ya fue "removed" del API server?
2. Según la [deprecation policy de Kubernetes](https://kubernetes.io/docs/reference/using-api/deprecation-policy/), ¿qué diferencia hay entre esos dos estados de una API?

---

## Ejercicio 3: Migrar manifiestos con `kubectl-convert`

1. Instalá el plugin `convert` vía `krew` (si no lo tenés):
   ```bash
   kubectl krew install convert
   ```
2. Creá `pdb-viejo.yaml` con una versión deprecada de `PodDisruptionBudget`:
   ```yaml
   apiVersion: policy/v1beta1
   kind: PodDisruptionBudget
   metadata:
     name: demo-pdb
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app: demo
   ```
3. Convertí el manifiesto a la versión estable actual:
   ```bash
   kubectl-convert -f pdb-viejo.yaml --output-version policy/v1
   ```
4. Compará el `apiVersion` del output contra el original.

**Preguntas**
1. ¿Qué ventaja tiene usar `kubectl-convert` en lugar de editar `apiVersion` a mano en manifiestos grandes?
2. ¿Qué es lo que `kubectl-convert` **no** garantiza, y que igual deberías validar vos mismo antes de aplicar el resultado en un cluster real?

---

## Ejercicio 4: Detectar APIs deprecadas antes de un upgrade con `kubent`

1. Instalá [kube-no-trouble (`kubent`)](https://github.com/doitintl/kube-no-trouble):
   ```bash
   sh -c "$(curl -sSL https://git.io/install-kubent)"
   ```
2. Ejecutalo contra tu cluster actual:
   ```bash
   kubent
   ```
3. Revisá el reporte: columnas `KIND`, `NAMESPACE`, `NAME`, `API_VERSION`, `REPLACE_WITH`, `SINCE`, `REPLACED_IN`, `REMOVED_IN`.
4. Elegí un recurso reportado (si hay alguno) y migralo a la apiVersion sugerida en `REPLACE_WITH`.

**Preguntas**
1. ¿Por qué es recomendable correr una herramienta como `kubent` (o [`pluto`](https://github.com/FairwindsOps/pluto)) **antes** de subir la versión minor del cluster, y no después?
2. En el reporte de `kubent`, ¿qué columna te dice si todavía tenés margen antes de que la API deje de funcionar, y cuál te dice a qué migrar?

---

## Ejercicio 5: Warnings de deprecación emitidos por el API server

1. Buscá si tu cluster todavía expone algún recurso en versión `v1beta1` o `v1beta2`:
   ```bash
   kubectl api-resources -o wide | grep -E "v1beta"
   ```
2. Si encontrás alguno, aplicá un manifiesto usando esa apiVersion y observá la salida de `kubectl` (no solo el `stdout`, sino cualquier línea que empiece con `Warning:`).
3. Si no encontrás ninguno, corré con `-v=6` un `kubectl get` sobre un recurso cualquiera y observá las cabeceras HTTP de la respuesta:
   ```bash
   kubectl get deployment -v=6
   ```

**Preguntas**
1. Desde Kubernetes 1.19, ¿mediante qué mecanismo HTTP comunica el API server que una apiVersion o un campo están deprecados, sin que eso impida que el request se procese? (ver [kubernetes.io/blog/2020/09/03/warnings](https://kubernetes.io/blog/2020/09/03/warnings/))
2. ¿Ese mecanismo aplica solo a `kubectl`, o también a cualquier cliente que use el API REST directamente?

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
1. `CronJob` usaba `batch/v1beta1` antes de graduarse a `batch/v1` en Kubernetes 1.21. Se confirma con `kubectl explain cronjob`, que muestra el campo `VERSION:` con la apiVersion activa en el API server actual.
2. `kubectl api-versions` lista los grupos/versiones de API habilitados (`grupo/versión`, p. ej. `batch/v1`). `kubectl api-resources` lista los *recursos* (kinds) disponibles, junto con su `APIVERSION`, si son namespaced y sus `SHORTNAMES`; es más útil para saber qué kind vive en qué grupo.

**Ejercicio 2**
1. Falla porque `batch/v1beta1` ya fue **removida** del API server (no solo deprecada): el servidor no tiene registrado ningún handler para ese group/version, por eso `kubectl` responde "no matches for kind ... in version ...". Si solo estuviera deprecada pero aún soportada, el `apply` habría funcionado, mostrando en cambio un `Warning:` en la salida.
2. "Deprecated" significa que la API sigue funcionando pero se anunció su reemplazo y su eventual remoción en una release futura (el cliente recibe warnings). "Removed" significa que el API server ya no registra esa versión: cualquier request contra ella falla inmediatamente, independientemente del cliente usado.

**Ejercicio 3**
1. `kubectl-convert` reescribe automáticamente la estructura completa del manifiesto (apiVersion y, si corresponde, campos que cambiaron de forma/nombre entre versiones), evitando errores manuales al migrar muchos archivos o manifiestos complejos.
2. No garantiza que el comportamiento en runtime sea idéntico (por ejemplo, defaults distintos, validaciones más estrictas en la nueva versión, o campos que cambiaron de semántica). Por eso conviene revisar el diff y probar el manifiesto convertido en un entorno no productivo antes de aplicarlo en el cluster real.

**Ejercicio 4**
1. Porque una vez que hacés el upgrade de versión minor, si esa release remueve la apiVersion que estabas usando, los manifiestos, Helm charts o controllers que dependen de ella empiezan a fallar inmediatamente al aplicarse o reconciliarse. Corriendo `kubent`/`pluto` antes del upgrade podés migrar con tiempo, sin downtime forzado.
2. `REMOVED_IN` indica la versión de Kubernetes en la que esa apiVersion deja de existir (tu margen antes de romperse); `REPLACE_WITH` indica la apiVersion estable a la que deberías migrar el manifiesto.

**Ejercicio 5**
1. El API server envía el header HTTP estándar `Warning` (RFC 7234) en la respuesta cuando el request usa una apiVersion, campo o valor deprecado. `kubectl` (y cualquier cliente que respete ese header, incluido `client-go`) lo imprime como una línea `Warning: ...` sin bloquear la operación.
2. Aplica a cualquier cliente que hable el API REST de Kubernetes, no solo a `kubectl`: el header `Warning` viaja en la respuesta HTTP misma, así que herramientas como `curl`, Helm o controllers escritos con `client-go` también pueden leerlo (aunque no todos los clientes lo muestran por defecto).

</details>