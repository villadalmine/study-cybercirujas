# Cleanup Policies — Ejercicios guiados

> **Certificación:** Kyverno Certified Associate (KCA) · **Tema de dominio 5.10 — Cleanup Policies** (peso en el examen 2.91)
>
> Kyverno te da dos mecanismos independientes para *eliminar* recursos existentes según un schedule o tras un tiempo de vida — algo que las reglas `validate`/`mutate`/`generate` no pueden hacer porque solo actúan en el momento de admisión:
>
> 1. **CRDs de cleanup policy** — `CleanupPolicy` (namespaced) y `ClusterCleanupPolicy` (cluster‑scoped). Llevan un `schedule` de cron, un selector `match`/`exclude` y `conditions` opcionales. El **cleanup‑controller** las evalúa como un escaneo en segundo plano y elimina cada recurso que coincida.
> 2. **La label `cleanup.kyverno.io/ttl`** — asignala a *cualquier* recurso y el mismo controller elimina ese único objeto una vez que su TTL vence. No requiere ningún objeto de policy.
>
> Ambos caminos son aplicados por el mismo componente y están controlados por el mismo RBAC. Estos ejercicios van construyendo desde una única policy namespaced hasta conditions, alcance de cluster, el modelo de RBAC, labels de TTL y resolución de problemas.
>
> **Fuente de verdad para cada comando de abajo:** documentación de Kyverno — *Cleanup* (<https://kyverno.io/docs/writing-policies/cleanup/>) y el currículo de KCA (<https://github.com/cncf/curriculum>).

---

## Prerrequisitos y preparación del entorno

Necesitás un cluster descartable (`kind`, `minikube` o k3d) y `kubectl`. **No ejecutes esto en un cluster compartido o de producción** — las cleanup policies eliminan objetos reales.

**Pasos**

1. Creá un cluster descartable:

   ```bash
   kind create cluster --name kca-cleanup
   ```

2. Instalá Kyverno con Helm (el cleanup‑controller viene como componente estándar en el chart por defecto desde v1.10):

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   ```

3. Confirmá que los cuatro controllers están corriendo — el que te importa es **`kyverno-cleanup-controller`**:

   ```bash
   kubectl -n kyverno get deploy
   ```

   Esperado (abreviado):

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           2m
   kyverno-background-controller   1/1     1            1           2m
   kyverno-cleanup-controller      1/1     1            1           2m
   kyverno-reports-controller      1/1     1            1           2m
   ```

4. Confirmá qué API group/version sirve tu instalación para los CRDs de cleanup (esto cambió entre releases — `v2alpha1 → v2beta1`, y 1.13+ puede servir `kyverno.io/v2`):

   ```bash
   kubectl api-resources | grep -i cleanup
   ```

   Salida de ejemplo:

   ```
   cleanuppolicies          kyverno.io/v2beta1   true    CleanupPolicy
   clustercleanuppolicies   kyverno.io/v2beta1   false   ClusterCleanupPolicy
   ```

5. Creá el namespace de trabajo que usan todos los ejercicios:

   ```bash
   kubectl create namespace cleanup-demo
   ```

**Verificá tu comprensión**

- Q0.1 — ¿Cuál de los cuatro controllers de Kyverno realiza en realidad las eliminaciones, y por qué eso importa para el RBAC?
- Q0.2 — Mirá la columna `NAMESPACED` en el paso 4. ¿Qué te dice sobre la diferencia entre `CleanupPolicy` y `ClusterCleanupPolicy`, y cuál de las dos podría alguna vez eliminar un `PersistentVolume`?
- Q0.3 — ¿Por qué una cleanup policy puede eliminar un Pod que ya fue admitido en el cluster, cuando una policy `validate` no puede?

---

## Ejercicio 1 — Tu primera `CleanupPolicy` (namespaced, match por label + schedule)

**Objetivo:** eliminar Pods que llevan una label específica, según un schedule de cron, acotado a un namespace.

**Pasos**

1. Creá tres Pods básicos; dos están marcados como descartables:

   ```bash
   kubectl -n cleanup-demo run keep-me   --image=nginx
   kubectl -n cleanup-demo run scratch-a --image=nginx -l canremove=true
   kubectl -n cleanup-demo run scratch-b --image=nginx -l canremove=true
   ```

2. Escribí la policy. Notá que el selector de recursos reutiliza la misma gramática de `match` que ya conocés de las policies `validate`, y el campo requerido `schedule` es cron estándar de 5 campos:

   ```yaml
   # cleanup-scratch-pods.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-scratch-pods
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Pod
           selector:
             matchLabels:
               canremove: "true"
     schedule: "*/1 * * * *"   # every minute (1 minute is the finest cron granularity)
   ```

3. Aplicala e inspeccionala:

   ```bash
   kubectl apply -f cleanup-scratch-pods.yaml
   kubectl -n cleanup-demo get cleanuppolicy
   ```

   Esperado:

   ```
   NAME                   SCHEDULE      AGE
   cleanup-scratch-pods   */1 * * * *   5s
   ```

4. Esperá al próximo límite de minuto y volvé a listar los Pods:

   ```bash
   sleep 65
   kubectl -n cleanup-demo get pods
   ```

   Esperado — solo sobrevive el Pod sin label:

   ```
   NAME      READY   STATUS    RESTARTS   AGE
   keep-me   1/1     Running   0          2m
   ```

5. Confirmá que el controller registró la acción como un event en el objeto de policy:

   ```bash
   kubectl -n cleanup-demo describe cleanuppolicy cleanup-scratch-pods
   ```

   Esperado (final, el texto exacto varía según la versión):

   ```
   Events:
     Type    Reason          Age   From                        Message
     ----    ------          ----  ----                        -------
     Normal  PolicyApplied   30s   kyverno-cleanup-controller  successfully cleaned up target resources
   ```

**Verificá tu comprensión**

- Q1.1 — El campo `schedule` es obligatorio. ¿Cuál es el intervalo más pequeño que podés expresar, y qué implica eso para lo "instantáneamente" que una cleanup policy reacciona ante un recurso que empieza a coincidir?
- Q1.2 — Esta policy vive en `cleanup-demo`. Si existiera un Pod idéntico con `canremove=true` en `default`, ¿se eliminaría? ¿Por qué sí o por qué no?
- Q1.3 — Editaste `keep-me` para agregarle `canremove=true`. ¿Tenés que volver a aplicar la policy para que sea barrido en la próxima ejecución?
- Q1.4 — Una policy `validate` usa `request.object` en sus reglas. ¿Cuál es la variable análoga que usa una cleanup policy para referenciar el recurso que se está evaluando? (Anticipo del Ejercicio 2.)

---

## Ejercicio 2 — `conditions` y la variable `target`

**Objetivo:** eliminar solo los recursos que satisfacen un predicado basado en datos, usando JMESPath sobre el recurso candidato expuesto como **`target`**.

**Pasos**

1. Creá dos Deployments con distinta cantidad de réplicas:

   ```bash
   kubectl -n cleanup-demo create deployment web-small --image=nginx --replicas=1
   kubectl -n cleanup-demo create deployment web-big   --image=nginx --replicas=3
   ```

2. Escribí una policy que coincida con *todos* los Deployments pero solo elimine los escalados por debajo de 2 réplicas. El recurso candidato se referencia como `{{ target.* }}`:

   ```yaml
   # cleanup-underscaled.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-underscaled
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Deployment
     conditions:
       all:
       - key: "{{ target.spec.replicas }}"
         operator: LessThan
         value: 2
     schedule: "*/1 * * * *"
   ```

3. Aplicá, esperá un ciclo y observá el resultado:

   ```bash
   kubectl apply -f cleanup-underscaled.yaml
   sleep 65
   kubectl -n cleanup-demo get deploy
   ```

   Esperado — `web-big` (3 réplicas) permanece, `web-small` (1 réplica) desaparece:

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   web-big   3/3     3            3           2m
   ```

4. **Predicado avanzado — recursos "sueltos".** Las conditions son JMESPath completo, así que podés basarte en estructura que no es un escalar. Esta condition elimina solo los Pods *sin* `ownerReferences` (es decir, no gestionados por un ReplicaSet/Job/StatefulSet):

   ```yaml
   conditions:
     all:
     - key: "{{ target.metadata.ownerReferences[] || `[]` | length(@) }}"
       operator: Equals
       value: 0
   ```

   El guard `|| `[]`` provee un array vacío cuando el campo está ausente, y los backticks `` `0` ``/`` `[]` `` son la forma en que el JMESPath de Kyverno escribe JSON literal.

**Verificá tu comprensión**

- Q2.1 — ¿A qué objeto se resuelve exactamente `target` durante la evaluación, y en qué se diferencia de `request.object`?
- Q2.2 — Escribiste `conditions.all`. ¿Qué cambia si usás `conditions.any` con dos conditions? Dá una regla de una línea para cuándo elegir cada una.
- Q2.3 — En el paso 4, ¿por qué es necesario el fallback `|| `[]`` en lugar de simplemente escribir `{{ target.metadata.ownerReferences | length(@) }}`?
- Q2.4 — `match` selecciona Deployments y `conditions` filtra por réplicas. ¿Por qué suele ser más barato/claro acotar primero con `match` en lugar de mover el filtro de kind a una condition?

---

## Ejercicio 3 — Cleanup con alcance de cluster (`ClusterCleanupPolicy`)

**Objetivo:** entender cuándo solo sirve una policy con alcance de cluster, y acotarla de forma segura para que no barra todo el cluster.

**Pasos**

1. Creá un Job que corre hasta completarse:

   ```bash
   kubectl -n cleanup-demo create job pi --image=perl:5.34 -- perl -Mbignum=bpi -wle 'print bpi(20)'
   kubectl -n cleanup-demo wait --for=condition=complete job/pi --timeout=120s
   ```

2. Escribí una **`ClusterCleanupPolicy`** que elimine los Jobs *completados* — pero restringila al namespace de demo con el selector `namespaces` para que no pueda tocar `kube-system` ni nada más:

   ```yaml
   # cleanup-completed-jobs.yaml
   apiVersion: kyverno.io/v2beta1
   kind: ClusterCleanupPolicy
   metadata:
     name: cleanup-completed-jobs
   spec:
     match:
       any:
       - resources:
           kinds:
             - Job
           namespaces:
             - cleanup-demo      # <-- safety scope; without it this is cluster-wide
     conditions:
       all:
       - key: "{{ target.status.succeeded || `0` }}"
         operator: GreaterThanOrEquals
         value: 1
     schedule: "*/1 * * * *"
   ```

3. Aplicá y observá:

   ```bash
   kubectl apply -f cleanup-completed-jobs.yaml
   kubectl get clustercleanuppolicy
   sleep 65
   kubectl -n cleanup-demo get jobs
   ```

   Esperado — el Job completado se elimina:

   ```
   No resources found in cleanup-demo namespace.
   ```

**Verificá tu comprensión**

- Q3.1 — Dá dos kinds de recurso que una `CleanupPolicy` (namespaced) *nunca* puede eliminar, obligándote a usar `ClusterCleanupPolicy`.
- Q3.2 — El manifest no tiene `metadata.namespace`. ¿Cuál es el radio de impacto de una `ClusterCleanupPolicy` cuyo `match` omite el selector `namespaces`, y por qué es el error más peligroso de este tema?
- Q3.3 — ¿Por qué proteger la condition con `{{ target.status.succeeded || `0` }}` en lugar de `{{ target.status.succeeded }}` en un Job que todavía no terminó?

---

## Ejercicio 4 — RBAC: otorgar al cleanup‑controller permisos de delete

**Objetivo:** entender que *el ServiceAccount del controller*, no vos, elimina el recurso — así que el cleanup falla con un error `Forbidden` a menos que el role agregado de cleanup cubra ese kind. Vas a reproducir la falla y arreglarla.

**Pasos**

1. Inspeccioná la regla de agregación que usa el ClusterRole del controller. **Copiá los `matchLabels` exactos que veas** — difieren entre versiones, así que nunca los pongas hardcodeados de memoria:

   ```bash
   kubectl get clusterrole kyverno:cleanup-controller:core -o yaml
   # If that name isn't present, list candidates:
   kubectl get clusterrole | grep cleanup
   ```

   Buscás un bloque como:

   ```yaml
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         app.kubernetes.io/part-of: kyverno
         rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   ```

2. Creá un recurso de un kind que el role de cleanup por defecto **no** cubre (Ingress es un buen candidato; si tu role por defecto ya lo cubre, elegí cualquier kind ausente de las reglas agregadas):

   ```bash
   kubectl -n cleanup-demo create ingress demo \
     --rule="demo.local/*=svc:80" --class=nginx
   kubectl -n cleanup-demo label ingress demo canremove=true
   ```

3. Aplicá una policy que lo apunte:

   ```yaml
   # cleanup-ingress.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-ingress
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Ingress
           selector:
             matchLabels:
               canremove: "true"
     schedule: "*/1 * * * *"
   ```

   ```bash
   kubectl apply -f cleanup-ingress.yaml
   ```

4. Esperá un ciclo y leé el log del controller — la eliminación es **denegada**, y el Ingress sobrevive:

   ```bash
   sleep 65
   kubectl -n cleanup-demo get ingress
   kubectl -n kyverno logs deploy/kyverno-cleanup-controller | grep -i forbidden | tail -1
   ```

   Línea de log esperada (abreviada):

   ```
   "level":"error" "msg":"failed to cleanup" "policy":"cleanup-demo/cleanup-ingress"
   "error":"ingresses.networking.k8s.io \"demo\" is forbidden:
   User \"system:serviceaccount:kyverno:kyverno-cleanup-controller\" cannot delete
   resource \"ingresses\" in API group \"networking.k8s.io\""
   ```

5. Otorgá el permiso creando un ClusterRole **etiquetado para agregarse al role de cleanup** — reutilizá los `matchLabels` que copiaste en el paso 1:

   ```yaml
   # rbac-cleanup-ingress.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:cleanup-ingress
     labels:
       # MUST match the clusterRoleSelectors from step 1
       app.kubernetes.io/part-of: kyverno
       rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   rules:
   - apiGroups: ["networking.k8s.io"]
     resources: ["ingresses"]
     verbs: ["get", "list", "watch", "delete"]
   ```

   ```bash
   kubectl apply -f rbac-cleanup-ingress.yaml
   sleep 65
   kubectl -n cleanup-demo get ingress
   ```

   Esperado — el Ingress ya no está:

   ```
   No resources found in cleanup-demo namespace.
   ```

**Verificá tu comprensión**

- Q4.1 — ¿Qué identidad aparece en el mensaje `Forbidden`, y por qué *no* es tu usuario de `kubectl`?
- Q4.2 — ¿Por qué Kyverno usa un ClusterRole *agregado* (labels + `aggregationRule`) en lugar de pedirte que edites directamente el ClusterRole del controller?
- Q4.3 — Tu policy se validó y fue aceptada por el API server, pero no se eliminó nada. ¿En cuál de los peldaños de la "escalera de verificaciones" cae una falla por RBAC faltante — se detecta en la admisión de la policy o solo en tiempo de ejecución? ¿Cuál es la lección práctica de monitoreo?
- Q4.4 — ¿Qué verbs, como mínimo, debe otorgar el ClusterRole para que el cleanup funcione, y por qué `delete` por sí solo es insuficiente?

---

## Ejercicio 5 — Cleanup basado en TTL con la label `cleanup.kyverno.io/ttl`

**Objetivo:** hacer expirar un único objeto sin escribir ninguna policy, e internalizar la restricción de valor de label que dicta los formatos de TTL aceptados.

**Pasos**

1. Creá un Pod que debería vivir solo dos minutos, usando la label reservada:

   ```bash
   kubectl -n cleanup-demo run ephemeral --image=nginx -l cleanup.kyverno.io/ttl=2m
   ```

2. Confirmá que la label está presente y anotá la hora de creación (para duraciones, la cuenta regresiva arranca desde `creationTimestamp`):

   ```bash
   kubectl -n cleanup-demo get pod ephemeral \
     -o jsonpath='{.metadata.labels.cleanup\.kyverno\.io/ttl}{"\n"}'
   # -> 2m
   ```

3. Esperá más allá del TTL y confirmá la eliminación:

   ```bash
   sleep 130
   kubectl -n cleanup-demo get pod ephemeral
   # -> Error from server (NotFound): pods "ephemeral" not found
   ```

4. **Expiración absoluta.** También podés fijar una fecha absoluta. Probá primero fijar un timestamp preciso y observá cómo el API server lo rechaza:

   ```bash
   kubectl -n cleanup-demo run late --image=nginx \
     -l cleanup.kyverno.io/ttl=2026-12-31T23:59:59Z
   ```

   Esperado — el objeto es rechazado antes de que Kyverno siquiera lo vea:

   ```
   The Pod "late" is invalid: metadata.labels: Invalid value:
   "2026-12-31T23:59:59Z": a valid label must be an empty string or
   consist of alphanumeric characters, '-', '_' or '.' ...
   ```

   Ahora usá la forma de solo fecha, que *sí* es un valor de label válido:

   ```bash
   kubectl -n cleanup-demo run late --image=nginx -l cleanup.kyverno.io/ttl=2026-12-31
   ```

**Verificá tu comprensión**

- Q5.1 — ¿Qué controller aplica la label `cleanup.kyverno.io/ttl` — y el mecanismo de la label requiere que crees un objeto `CleanupPolicy`?
- Q5.2 — En el paso 4 el timestamp RFC3339 con dos puntos fue rechazado. *¿Por qué?* — ¿cuál es la restricción subyacente de Kubernetes, y qué implica sobre la granularidad absoluta más fina que podés expresar a través de la label? ¿Cómo expresarías "eliminar en 90 minutos" en su lugar?
- Q5.3 — Un recurso lleva `cleanup.kyverno.io/ttl=1h` pero su kind no está cubierto por el ClusterRole agregado de cleanup. ¿Qué pasa al expirar, y dónde verías el síntoma? (Conectalo con el Ejercicio 4.)
- Q5.4 — Nombrá una ventaja operativa de la label de TTL sobre un CRD `CleanupPolicy`, y una ventaja del CRD sobre la label.

---

## Ejercicio 6 — Observabilidad y resolución de problemas

**Objetivo:** aprender las tres señales autoritativas para "¿corrió mi cleanup, y qué hizo?" y cómo el controller programa el trabajo.

**Pasos**

1. **Events de policy** — el registro por ejecución, adjunto al objeto de policy:

   ```bash
   kubectl -n cleanup-demo get events \
     --field-selector involvedObject.kind=CleanupPolicy
   ```

2. **Logs del controller** — la verdad de fondo para éxitos *y* errores (acá es donde aparecen `Forbidden`, JMESPath incorrecto y schedules que no se pueden parsear):

   ```bash
   kubectl -n kyverno logs deploy/kyverno-cleanup-controller --tail=50
   ```

3. **Artefacto de scheduling** — según tu versión de Kyverno, el cleanup‑controller o bien corre un scheduler interno o bien materializa un `CronJob` de Kubernetes por policy en el namespace `kyverno`. Revisá ambos, y tratá los events/logs (pasos 1–2) como autoritativos sin importar cuál veas:

   ```bash
   kubectl -n kyverno get cronjob
   ```

   Salida posible (depende de la versión — el nombre se deriva de la policy y puede llevar un hash):

   ```
   NAME                   SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
   cleanup-scratch-pods   */1 * * * *   False     0        41s             5m
   ```

4. **Rompelo a propósito** para ver la validación. Aplicá una policy con un cron inválido y mirá cómo el admission webhook la rechaza *antes* de que llegue a almacenarse:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: bad-schedule
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds: ["Pod"]
     schedule: "every minute"
   EOF
   ```

   Esperado:

   ```
   Error from server: admission webhook "vcleanuppolicy.kyverno.svc" denied the request:
   spec.schedule: Invalid value: "every minute": schedule spec in the cleanupPolicy is not in proper cron format
   ```

**Verificá tu comprensión**

- Q6.1 — Tenés tres señales: events de policy, logs del controller y el artefacto de scheduling. ¿Cuál por sí sola prueba que *una eliminación realmente ocurrió*, y cuál revisarías primero cuando la respuesta es "no se eliminó nada"?
- Q6.2 — En el paso 4 el schedule incorrecto fue rechazado al momento de aplicar. Contrastá eso con la falla de RBAC en el Ejercicio 4, que fue aceptada al momento de aplicar. ¿Qué te dice eso sobre *qué* clases de fallas puede detectar Kyverno en la admisión frente a solo en la ejecución?
- Q6.3 — Existe una cleanup policy, su schedule es válido, el RBAC es correcto, pero el target sigue sin eliminarse. Dá dos causas raíz relacionadas con `conditions` y el comando exacto que usarías para confirmar cada una contra un recurso en vivo.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Preparación

- **Q0.1** — El deployment **`kyverno-cleanup-controller`** realiza todas las eliminaciones (tanto las guiadas por CRD como las guiadas por la label de TTL). Importa porque las eliminaciones se ejecutan bajo el ServiceAccount *del controller* (`system:serviceaccount:kyverno:kyverno-cleanup-controller`), no bajo la identidad de quien aplicó la policy — así que el controller mismo debe tener permisos de `delete` sobre el kind objetivo (ver Ejercicio 4).
- **Q0.2** — `NAMESPACED=true` para `CleanupPolicy` significa que solo puede seleccionar recursos namespaced y solo dentro de su propio namespace; `ClusterCleanupPolicy` (`NAMESPACED=false`) tiene alcance de cluster y además puede apuntar a recursos **cluster‑scoped**. Solo una `ClusterCleanupPolicy` podría alguna vez eliminar un `PersistentVolume`, `Namespace`, `PV`, `ClusterRole`, etc.
- **Q0.3** — `validate`/`mutate`/`generate` pasan por el webhook de *admisión* y solo ven un recurso al momento de crearlo/actualizarlo. Las cleanup policies corren en **segundo plano** según un cron, evaluando recursos que ya existen en etcd — así que pueden actuar sobre objetos mucho después de la admisión.

### Ejercicio 1

- **Q1.1** — La granularidad más fina de cron es **un minuto** (`*/1 * * * *` o `* * * * *`). Por lo tanto una cleanup policy *no* es en tiempo real: un recurso que empieza a coincidir puede vivir hasta ~1 minuto (más la latencia de procesamiento del controller) antes de que el próximo barrido programado lo elimine.
- **Q1.2** — No. Una `CleanupPolicy` namespaced solo evalúa recursos **en su propio namespace** (`cleanup-demo`). Un Pod con `canremove=true` en `default` queda intacto a menos que exista una policy ahí (o que una `ClusterCleanupPolicy` lo cubra).
- **Q1.3** — No. `match`/`conditions` se vuelven a evaluar contra el cluster en vivo en cada ejecución programada. Agregarle la label a `keep-me` significa que será barrido en el próximo tick; el objeto de policy no cambia.
- **Q1.4** — **`target`** (es decir, `{{ target.* }}`), el recurso candidato en evaluación — el análogo de `request.object` para cleanup.

### Ejercicio 2

- **Q2.1** — `target` es el **manifest completo del recurso existente** que se está considerando para eliminación (su `spec`, `status`, `metadata`, etc. en vivo, tal como está almacenado en el cluster). `request.object` solo está definido en el contexto de admisión (el objeto *que se está admitiendo*); el cleanup corre en segundo plano sin ninguna request de admisión, así que expone el recurso como `target` en su lugar — y algo clave: `target` incluye el `status` poblado, que el `request.object` del momento de admisión a menudo no tiene.
- **Q2.2** — `all` es un AND lógico (toda condition debe ser verdadera); `any` es un OR lógico (al menos una). Regla práctica: usá `all` cuando *cada* criterio debe cumplirse para justificar la eliminación (el default seguro), `any` cuando *cualquier* señal de alarma individual es suficiente.
- **Q2.3** — Cuando un Pod no tiene owner, `target.metadata.ownerReferences` está **ausente** (null), y `length(null)` da error / evalúa de forma inutilizable. `|| `[]`` sustituye por un array vacío para que `length(@)` produzca `0` de forma confiable. Normaliza "campo faltante" y "campo vacío" al mismo valor comparable.
- **Q2.4** — `match` es un selector estructural/de label barato que se aplica primero; acotar el kind ahí significa que las `conditions` (JMESPath evaluado por candidato) solo corren contra el conjunto ya reducido. Es más rápido y más legible — las `conditions` deberían expresar predicados de *datos*, no filtrado por tipo de recurso.

### Ejercicio 3

- **Q3.1** — Cualquier kind con alcance de cluster, p. ej. **`Namespace`, `PersistentVolume`, `ClusterRole`, `Node`, `StorageClass`**. Una `CleanupPolicy` namespaced no puede seleccionarlos.
- **Q3.2** — Sin una restricción `namespaces` (o de label/`namespaceSelector`), una `ClusterCleanupPolicy` coincide con el kind **en todos los namespaces del cluster**, incluido `kube-system`. Es el error más peligroso porque un `kinds: [Pod]` amplio + una condition permisiva/ausente barrería las cargas de trabajo del sistema en todo el cluster según un schedule. Siempre acotá las cluster policies de forma estricta.
- **Q3.3** — En un Job en ejecución/pendiente, `status.succeeded` no está definido (null). `{{ target.status.succeeded }}` entonces compararía null contra `1` y se comportaría de forma impredecible; `|| `0`` coacciona "todavía no exitoso" a `0`, así que el predicado `>= 1` es falso y el Job queda correctamente a salvo hasta que efectivamente se completa.

### Ejercicio 4

- **Q4.1** — `system:serviceaccount:kyverno:kyverno-cleanup-controller`. Kyverno elimina en tu nombre usando **su propio** ServiceAccount, así que tus permisos personales de `kubectl` son irrelevantes — lo que se verifica es el RBAC del controller.
- **Q4.2** — La agregación te permite *extender* los permisos del controller agregando un ClusterRole pequeño y autocontenido con las labels correctas, sin editar (y arriesgar pisar en un upgrade) los roles gestionados por Kyverno. El chart de Helm es dueño de `kyverno:cleanup-controller*`; tu role aditivo sobrevive a los upgrades del chart.
- **Q4.3** — **No** se detecta en la admisión de la policy — la policy es válida y queda almacenada. Falla solo en **tiempo de ejecución**, visible únicamente en los logs del cleanup‑controller (y como un event `PolicyError`/fallido), nunca como un error de `kubectl apply`. Lección práctica: "policy aplicada con éxito" ≠ "el cleanup funciona"; tenés que monitorear los logs/events del controller para saber que las eliminaciones efectivamente están teniendo éxito.
- **Q4.4** — Como mínimo **`get`, `list`, `watch`, `delete`**. `delete` por sí solo es insuficiente porque el controller primero debe *descubrir y leer* los recursos candidatos (list/watch/get) antes de poder eliminarlos; sin los verbs de lectura no puede enumerar qué limpiar.

### Ejercicio 5

- **Q5.1** — El **cleanup‑controller** aplica la label `cleanup.kyverno.io/ttl`. **No requiere ningún objeto `CleanupPolicy`** — etiquetar el recurso es suficiente; el controller vigila la label y programa la eliminación.
- **Q5.2** — Los **valores de label de Kubernetes solo pueden contener alfanuméricos, `-`, `_`, `.` (≤63 caracteres)** — los dos puntos son ilegales, así que un timestamp RFC3339 como `2026-12-31T23:59:59Z` es rechazado por el API server antes de que Kyverno intervenga. En consecuencia, la forma absoluta debe ser **solo fecha (`YYYY-MM-DD`)**, con granularidad de un día. Para precisión menor a un día usá en su lugar una **duración**: `cleanup.kyverno.io/ttl=90m` (o `1h30m`).
- **Q5.3** — No se elimina nada. Al expirar, el controller intenta el delete bajo su ServiceAccount, choca con un error `Forbidden` (clase idéntica a la del Ejercicio 4), y el objeto persiste. El síntoma aparece **solo en los logs del cleanup‑controller** — lo arreglarías agregando un ClusterRole agregado que otorgue `delete` (+ verbs de lectura) sobre ese kind.
- **Q5.4** — Ventaja de la label de TTL: **por objeto, cero gestión de policies** — ideal para recursos efímeros/de preview etiquetados al crearse. Ventaja del CRD: cleanup **declarativo, a nivel de flota, guiado por conditions** que aplica a *todos los recursos coincidentes actuales y futuros* de forma centralizada (p. ej. "todo Job completado más antiguo que X"), auditable como un único objeto de policy en lugar de N labels.

### Ejercicio 6

- **Q6.1** — Los **logs del controller** son la única señal que prueba que una eliminación efectivamente se ejecutó (o falló, y por qué). Los **events** de policy resumen los resultados por ejecución y son una buena primera parada; el artefacto CronJob/scheduler solo prueba que el *schedule* está registrado, no que algo se haya eliminado. Cuando "no se eliminó nada", revisá primero los logs.
- **Q6.2** — Kyverno detecta fallas **estructurales/estáticas** en la admisión mediante el validating webhook — cron mal formado, forma de policy incorrecta, etc. — y las rechaza al momento de aplicar. Las fallas **semánticas/de tiempo de ejecución** — RBAC insuficiente, una condition que no coincide con nada, un JMESPath que da error sobre datos en vivo — no pueden conocerse hasta la ejecución programada, así que solo afloran en la ejecución en los logs/events. La validación de admisión es necesaria pero no suficiente.
- **Q6.3** — Dos causas relacionadas con conditions: (1) el predicado de `conditions` es simplemente falso para el recurso — confirmalo con `kubectl get <res> -o yaml` y evaluá manualmente la ruta usada como key (p. ej. `kubectl get deploy web-small -o jsonpath='{.spec.replicas}'`); (2) el JMESPath usa como key un campo ausente/null así que la condition nunca evalúa a verdadero — confirmá que la ruta existe en el objeto en vivo con `kubectl get <res> -o jsonpath='{.status.succeeded}'` (salida vacía ⇒ necesitás un fallback `|| `0`` / `|| `[]``). Cruzá la información con los logs del controller por si hay errores de evaluación por recurso.

</details>

---

**Referencias**

- Kyverno — *Cleanup Policies*: <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — RBAC / agregación de roles para controllers: <https://kyverno.io/docs/installation/customization/>
- Código fuente de Kyverno (versiones de API de los CRD y cleanup‑controller): <https://github.com/kyverno/kyverno>
- CNCF — Currículo de Kyverno Certified Associate: <https://github.com/cncf/curriculum>