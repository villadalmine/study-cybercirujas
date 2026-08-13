# Políticas y Reglas de Kyverno — Ejercicios Guiados

> **Certificación:** Kyverno Certified Associate (KCA) · **Tema 1.1** (peso en el examen 4.51%)
> **Referencia:** [Currículum KCA de la CNCF](https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf) · [Documentación de Kyverno — Policies & Rules](https://kyverno.io/docs/policy-types/) · [Resumen de Writing Policies](https://kyverno.io/docs/writing-policies/)
>
> **Lo que vas a internalizar:** la anatomía de un objeto de política de Kyverno, la diferencia entre `Policy` y `ClusterPolicy`, los cuatro tipos de regla (`validate`, `mutate`, `generate`, `verifyImages`), cómo `match`/`exclude` seleccionan recursos, cómo `validationFailureAction` cambia el comportamiento de admission, los anclas de patrón, y cómo los resultados aparecen en objetos `PolicyReport`.

## Prerrequisitos

- Un clúster de Kubernetes descartable que puedas romper. `kind create cluster --name kca` es ideal.
- `kubectl` v1.27+ en tu `PATH`, con el contexto apuntando a ese clúster.
- Internet de salida para descargar el manifiesto de release de Kyverno y las imágenes de contenedor.
- ~2 GB de RAM libre; Kyverno corre un admission controller más un controlador de background/reports.

Todo lo de abajo es casi-idempotente: reaplicar una política la actualiza en el lugar, y borrar los namespaces al final devuelve el clúster a un estado limpio.

---

## Ejercicio 1 — Instalar Kyverno y leer los CRDs

**Objetivo:** poner el motor en funcionamiento y entender qué *es* "una política" a nivel de API.

1. Instalá el control plane de Kyverno (fijando una versión — nunca `latest` en trabajo tipo examen):

   ```bash
   kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
   ```

2. Esperá a que los controladores estén listos:

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   kubectl -n kyverno get pods
   ```

   Esperado (los nombres llevan un sufijo hash):

   ```
   NAME                                             READY   STATUS    RESTARTS   AGE
   kyverno-admission-controller-6f8d9c7b5-4xk2n     1/1     Running   0          58s
   kyverno-background-controller-7c9f6d4b8-tq7m9    1/1     Running   0          58s
   kyverno-cleanup-controller-59b7c6d9f-l8w4z       1/1     Running   0          58s
   kyverno-reports-controller-6d8b7f5c4-r2n6p       1/1     Running   0          58s
   ```

3. Descubrí los Custom Resource Definitions que instaló Kyverno:

   ```bash
   kubectl api-resources --api-group=kyverno.io
   ```

   Esperado (abreviado):

   ```
   NAME              SHORTNAMES   APIVERSION      NAMESPACED   KIND
   clusterpolicies   cpol         kyverno.io/v1   false        ClusterPolicy
   policies          pol          kyverno.io/v1   true         Policy
   ```

4. Inspeccioná los dos tipos de política y fijate en la columna `NAMESPACED` de arriba.

> **Verificá tu comprensión**
> 1. Un `ClusterPolicy` y un `Policy` comparten el mismo esquema. ¿Qué única propiedad difiere entre ellos, y qué consecuencia práctica tiene eso para qué recursos puede gobernar cada uno?
> 2. Kyverno se despliega como varios deployments separados (admission, background, reports, cleanup). ¿Por qué es el controlador de *admission* el que debe estar sano para que las políticas `Enforce` realmente bloqueen un `kubectl apply`?

---

## Ejercicio 2 — Tu primera regla `validate` (Audit → Enforce)

**Objetivo:** escribir una política de validación, ver la diferencia entre `Audit` y `Enforce`, y leer el resultado en un `PolicyReport`.

1. Creá una política que requiera que cada Pod lleve una etiqueta `team`. Empezá en **Audit** para que nada se bloquee:

   ```yaml
   # require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "The label 'team' is required on all Pods."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label.yaml
   ```

2. Creá un Pod que no cumpla. Como la acción es `Audit`, es **admitido**:

   ```bash
   kubectl run nginx --image=nginx:1.27
   ```

   ```
   pod/nginx created
   ```

3. Leé el reporte generado automáticamente para ese Pod:

   ```bash
   kubectl get policyreport -o wide
   ```

   Esperado:

   ```
   NAME                                   KIND   NAME    PASS   FAIL   WARN   ERROR   SKIP   AGE
   e4f...   ...
   ```

   Después profundizá en el resultado que falla:

   ```bash
   kubectl describe policyreport | grep -A6 "require-team-label"
   ```

   ```
   Result:   fail
   Rule:     check-team-label
   Message:  validation error: The label 'team' is required on all Pods.
             rule check-team-label failed at path /metadata/labels/team/
   ```

4. Pasá la política a **Enforce** y reaplicala:

   ```bash
   kubectl patch clusterpolicy require-team-label \
     --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
   ```

5. Probá de nuevo el Pod que no cumple — ahora es **rechazado en tiempo de admission**:

   ```bash
   kubectl run nginx2 --image=nginx:1.27
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/nginx2 was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label ''team'' is required on all
       Pods. rule check-team-label failed at path /metadata/labels/team/'
   ```

6. Comprobá que el camino que cumple funciona:

   ```bash
   kubectl run nginx3 --image=nginx:1.27 --labels team=payments
   ```

   ```
   pod/nginx3 created
   ```

> **Verificá tu comprensión**
> 1. Bajo `Audit`, el Pod del paso 2 fue creado *y* apareció un reporte que falla. ¿Cuál de los cuatro controladores de Kyverno produjo ese reporte, y por qué es relevante `background: true` para él?
> 2. En el `validate.pattern`, ¿qué significa el valor `"?*"`, y en qué se diferencia de `"*"`?
> 3. Las versiones más nuevas de Kyverno deprecan `spec.validationFailureAction` a favor de un campo por regla. ¿Cuál es la ruta de ese campo, y por qué es útil la granularidad por regla en una única política con múltiples reglas?

---

## Ejercicio 3 — Alcance con `match` y `exclude` usando `any` / `all`

**Objetivo:** controlar *a qué* recursos se aplica una regla, y entender la diferencia lógica entre `any` y `all`.

1. Creá dos namespaces contra los cuales acotar:

   ```bash
   kubectl create ns prod
   kubectl create ns sandbox
   ```

2. Aplicá una política que exija la etiqueta `team` **solo** para Pods en el namespace `prod`, y que **excluya** cualquier cosa creada por las service accounts internas `system:`:

   ```yaml
   # require-team-label-prod.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label-prod
   spec:
     validationFailureAction: Enforce
     rules:
       - name: check-team-label-in-prod
         match:
           all:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - prod
         exclude:
           any:
             - clusterRoles:
                 - system:node
         validate:
           message: "Pods in 'prod' must carry a 'team' label."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label-prod.yaml
   ```

3. Confirmá que la regla está acotada: un Pod pelado en `sandbox` se permite, el mismo Pod en `prod` se bloquea:

   ```bash
   kubectl -n sandbox run web --image=nginx:1.27      # allowed
   kubectl -n prod    run web --image=nginx:1.27      # blocked
   ```

   ```
   pod/web created
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/prod/web was blocked due to the following policies
   require-team-label-prod:
     check-team-label-in-prod: 'validation error: Pods in ''prod'' must carry a
       ''team'' label. ...'
   ```

4. Compará la semántica: editá el bloque `match` temporalmente para que liste **dos** entradas bajo `any` (`Pod` *o* `Deployment`) versus **dos** entradas bajo `all`. Aplicá, y observá cómo se comporta cada uno frente a un Pod.

> **Verificá tu comprensión**
> 1. Dentro de `match`, ¿cuál es la relación booleana *entre las entradas de la lista* bajo `any` versus bajo `all`? (No los filtros dentro de una entrada — las entradas en sí.)
> 2. El bloque `exclude` de arriba filtra por `clusterRoles`. Además de `kinds`, `names`, `namespaces` y `selector`, nombrá dos filtros basados en identidad (`subjects`, `roles`/`clusterRoles`) por los que `match`/`exclude` pueden discriminar y explicá cuándo el matching basado en identidad es la *única* opción correcta.
> 3. Esta política hace match por `kinds: [Pod]`, y sin embargo la función de autogen de Kyverno igual va a proteger Deployments. ¿Qué está haciendo autogen, y qué agregarías a la política para ver las reglas auto-generadas de Deployment/DaemonSet/CronJob?

---

## Ejercicio 4 — Una regla `mutate` (`patchStrategicMerge` + anclas)

**Objetivo:** modificar recursos en tiempo de admission y aprender las anclas de mutación.

1. Aplicá una política que agregue una etiqueta `team=unassigned` por defecto **solo si el Pod no tiene ya una**:

   ```yaml
   # add-default-team.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-team
   spec:
     rules:
       - name: add-team-if-missing
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(team): unassigned
   ```

   ```bash
   kubectl apply -f add-default-team.yaml
   ```

2. Creá un Pod **sin** etiqueta `team` e inspeccioná el resultado:

   ```bash
   kubectl run cache --image=redis:7
   kubectl get pod cache -o jsonpath='{.metadata.labels}' ; echo
   ```

   ```
   {"run":"cache","team":"unassigned"}
   ```

3. Creá un Pod que **ya** tenga la etiqueta y confirmá que queda intacto (el ancla `+()` no sobrescribe):

   ```bash
   kubectl run api --image=redis:7 --labels team=payments
   kubectl get pod api -o jsonpath='{.metadata.labels}' ; echo
   ```

   ```
   {"run":"api","team":"payments"}
   ```

> **Verificá tu comprensión**
> 1. ¿Qué garantiza el ancla `+()` (add-if-absent) que una clave `team: unassigned` pelada no garantizaría?
> 2. La mutación y la validación corren en un orden definido para la misma solicitud de admission. ¿Kyverno *muta* antes o después de *validar*, y por qué ese orden permite que una regla mutate "arregle" un recurso para que pase una regla validate posterior?
> 3. Además de `patchStrategicMerge`, nombrá el otro método de mutación que soporta Kyverno para ediciones quirúrgicas basadas en posición, y una situación en la que lo elegirías en su lugar.

---

## Ejercicio 5 — Una regla `generate` con `synchronize`

**Objetivo:** hacer que Kyverno cree y mantenga sincronizado un recurso downstream cuando aparece un recurso disparador.

1. Creá un `ConfigMap` de origen en `default` que se clonará en cada namespace nuevo:

   ```bash
   kubectl -n default create configmap org-defaults \
     --from-literal=cost-center=platform
   ```

2. Aplicá una política que lo clone en cualquier namespace recién creado y lo mantenga sincronizado:

   ```yaml
   # sync-org-defaults.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: sync-org-defaults
   spec:
     rules:
       - name: clone-org-defaults
         match:
           any:
             - resources:
                 kinds:
                   - Namespace
         generate:
           apiVersion: v1
           kind: ConfigMap
           name: org-defaults
           namespace: "{{request.object.metadata.name}}"
           synchronize: true
           clone:
             namespace: default
             name: org-defaults
   ```

   ```bash
   kubectl apply -f sync-org-defaults.yaml
   ```

3. Creá un namespace nuevo y confirmá que el ConfigMap se materializó:

   ```bash
   kubectl create ns team-alpha
   kubectl -n team-alpha get configmap org-defaults
   ```

   ```
   NAME           DATA   AGE
   org-defaults   1      3s
   ```

4. Probá la sincronización: editá el **origen** y mirá cómo el clon se reconcilia:

   ```bash
   kubectl -n default patch configmap org-defaults \
     --type merge -p '{"data":{"cost-center":"shared-infra"}}'
   sleep 3
   kubectl -n team-alpha get configmap org-defaults -o jsonpath='{.data.cost-center}' ; echo
   ```

   ```
   shared-infra
   ```

> **Verificá tu comprensión**
> 1. ¿Qué controlador de Kyverno reconcilia los recursos generados, y qué agrega `synchronize: true` comparado con un generate de una sola vez?
> 2. El campo `namespace` usa `{{request.object.metadata.name}}`. ¿Cómo se llama esta expresión, y en qué punto del manejo de la solicitud se resuelve?
> 3. ¿Cuál es la diferencia entre la forma `clone:` usada acá y la forma `data:` de una regla generate?

---

## Ejercicio 6 — Anclas, precondiciones y `deny`

**Objetivo:** ir más allá de simples chequeos de presencia hacia lógica condicional — la parte de la escritura de reglas que el examen sondea con más dureza.

1. Aplicá una política que use un **ancla condicional** `()`: *si* la `image` de un contenedor usa el tag `:latest`, *entonces* su `imagePullPolicy` debe ser `Always`:

   ```yaml
   # latest-needs-always.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: latest-needs-always
   spec:
     validationFailureAction: Enforce
     rules:
       - name: latest-tag-pull-policy
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "Containers on ':latest' must set imagePullPolicy: Always."
           pattern:
             spec:
               containers:
                 - (image): "*:latest"
                   imagePullPolicy: Always
   ```

   ```bash
   kubectl apply -f latest-needs-always.yaml
   kubectl run bad --image=nginx:latest --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx:latest","imagePullPolicy":"IfNotPresent"}]}}'
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/default/bad was blocked due to the following policies
   latest-needs-always:
     latest-tag-pull-policy: 'validation error: Containers on '':latest'' must set
       imagePullPolicy: Always. ...'
   ```

2. Aplicá una política que use **`preconditions`** + un bloque **`deny`**: rechazá Pods que corran como UID 0, pero *solo* evaluá la regla para Pods cuyo nombre empiece con `svc-`:

   ```yaml
   # no-root-for-svc.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: no-root-for-svc
   spec:
     validationFailureAction: Enforce
     rules:
       - name: block-uid-0
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         preconditions:
           all:
             - key: "{{ request.object.metadata.name }}"
               operator: AnyIn
               value: "svc-*"
         validate:
           message: "Service Pods (svc-*) must not run as UID 0."
           deny:
             conditions:
               any:
                 - key: "{{ request.object.spec.securityContext.runAsUser || `0` }}"
                   operator: Equals
                   value: 0
   ```

   ```bash
   kubectl apply -f no-root-for-svc.yaml
   kubectl run svc-billing --image=nginx:1.27   # blocked (defaults to UID 0)
   kubectl run tmp-debug   --image=nginx:1.27   # allowed (precondition not met)
   ```

> **Verificá tu comprensión**
> 1. En el paso 1, la clave `(image)` es un *ancla condicional*. Describí la evaluación "if/then" que dispara, y qué le pasa al chequeo cuando el valor de `image` **no** coincide con `*:latest`.
> 2. Un `validate.pattern` y un `validate.deny` expresan la polaridad *opuesta*. Cuando escribís un bloque `deny`, ¿una condición que coincide significa que el recurso *pasa* o *falla*? Contrastalo con `pattern`.
> 3. En el paso 2, ¿por qué es esencial el fallback JMESPath `|| \`0\``? ¿Qué se rompería si un Pod simplemente omitiera `spec.securityContext.runAsUser` y hubieras escrito solo `{{ request.object.spec.securityContext.runAsUser }}`?
> 4. ¿Cuál es la diferencia funcional entre poner un filtro en `preconditions` versus expresar la misma condición dentro de `match`?

---

## Ejercicio 7 — Verificar con la CLI de Kyverno (sin mutar el clúster)

**Objetivo:** probar políticas contra manifiestos candidatos de forma offline — cómo iterás con seguridad y cómo CI valida políticas.

1. Instalá la CLI y guardá un manifiesto + política localmente:

   ```bash
   # brew install kyverno   (or download from the release page)
   kyverno version
   ```

2. Corré una política contra un archivo de recurso sin tocar el clúster:

   ```bash
   kyverno apply require-team-label.yaml --resource my-pod.yaml
   ```

   ```
   Applying 1 policy rule(s) to 1 resource(s)...

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. (Opcional) Explorá el tester de políticas incorporado con un `values.yaml` y `--policy-report`.

> **Verificá tu comprensión**
> 1. `kyverno apply` nunca contacta al admission webhook. ¿Qué clase de comportamiento de política **no** puede por lo tanto reproducir por completo, y por qué importa eso específicamente para las reglas `generate`?
> 2. ¿Por qué la validación offline con la CLI es una mejor barrera para los pull requests que depender del modo `Enforce` en un clúster en vivo?

---

## Limpieza

```bash
kubectl delete clusterpolicy \
  require-team-label require-team-label-prod add-default-team \
  sync-org-defaults latest-needs-always no-root-for-svc --ignore-not-found
kubectl delete ns prod sandbox team-alpha --ignore-not-found
kubectl delete pod nginx nginx3 cache api web --ignore-not-found
# Full teardown:  kind delete cluster --name kca
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
1. Solo difiere el **alcance (scope)**. `ClusterPolicy` es de alcance de clúster (sin `metadata.namespace`) y puede hacer match con recursos en **cualquier** namespace además de recursos de alcance de clúster (Namespaces, ClusterRoles, PersistentVolumes, CRDs). `Policy` es namespaced y sus reglas se aplican **solo** a recursos en el mismo namespace que el objeto `Policy`. El esquema (`spec.rules`, tipos de regla, `match`/`exclude`) es por lo demás idéntico.
2. El bloqueo de `Enforce` ocurre sincrónicamente durante la fase de admission del API server: el API server llama al `ValidatingWebhookConfiguration` de Kyverno, y el **admission controller** devuelve allow/deny. Si ese controlador está caído, el webhook o falla abierto o la solicitud da error (según `failurePolicy`), así que no ocurre bloqueo real. Los controladores de background y reports solo producen resultados `PolicyReport` *a posteriori* y nunca están en el camino de admission.

### Ejercicio 2
1. El **reports controller** (con ayuda del scanner de background) genera los objetos `PolicyReport`/`ClusterPolicyReport`. `background: true` habilita la reevaluación periódica de recursos *ya existentes* contra la política fuera del camino de admission — ese escaneo es lo que produce un resultado que falla para un Pod que fue admitido bajo `Audit`. Sin el escaneo de background, solo los recursos recién admitidos generarían resultados.
2. `"?*"` requiere **al menos un carácter** — `?` = exactamente un carácter, `*` = cero o más — así que significa "la etiqueta `team` debe existir **y** ser no vacía". Un `"*"` pelado hace match con cero o más caracteres y por lo tanto también hace match con un string vacío, así que una etiqueta presente pero vacía igual pasaría.
3. El campo por regla es `spec.rules[].validate.failureAction` (valores `Enforce`/`Audit`). La granularidad por regla permite que una política haga `Enforce` de una regla crítica mientras mantiene una regla más nueva o más ruidosa en `Audit` durante el despliegue, en lugar de forzar a cada regla de la política a compartir una sola acción. (Relacionado: `validate.failureActionOverrides` puede variar la acción por namespace.)

### Ejercicio 3
1. Las entradas bajo **`any`** están OR-eadas (el recurso hace match si satisface *cualquier* entrada individual); las entradas bajo **`all`** están AND-eadas (debe satisfacer *cada* entrada). Dentro de una única entrada, los filtros individuales (kinds + namespaces + selector …) siempre están AND-eados entre sí.
2. Los filtros de identidad incluyen **`subjects`** (usuarios/grupos/service accounts), **`roles`** (roles RBAC namespaced) y **`clusterRoles`**. Son la única opción correcta cuando la regla debe reaccionar a *quién* está haciendo la solicitud en lugar de a *qué* es el recurso — p. ej., "bloqueá esta acción a menos que el solicitante tenga un ClusterRole específico", que ningún campo de recurso puede expresar.
3. **Autogen** sintetiza automáticamente reglas equivalentes que apuntan a los tipos de controlador de Pods (`Deployment`, `DaemonSet`, `StatefulSet`, `ReplicaSet`, `Job`, `CronJob`) para que una regla a nivel de Pod también proteja los Pods que esos controladores *van a crear*. Podés verlas con `kubectl get cpol require-team-label-prod -o yaml` y leyendo el valor de `metadata.annotations["pod-policies.kyverno.io/autogen-controllers"]` más las reglas renderizadas, o controlarlo mediante esa anotación (p. ej. ponerla en `none` para deshabilitar autogen).

### Ejercicio 4
1. `+(team): unassigned` **solo agrega la clave si está ausente** y nunca sobrescribe un valor existente. Un `team: unassigned` pelado bajo `patchStrategicMerge` *fijaría/sobrescribiría* la etiqueta a `unassigned` incluso para Pods que ya declararon un team real.
2. Kyverno **muta antes de validar** para la misma solicitud. Ese orden significa que una regla mutate puede inyectar o corregir campos (agregar una etiqueta por defecto, fijar un `securityContext`) para que una regla validate posterior — en la misma política o en otra — vea el objeto ya corregido y pase.
3. **`patchesJson6902`** (RFC 6902 JSON Patch): usalo para operaciones precisas basadas en posición/índice — p. ej. insertar un elemento en un índice de array específico, `remove` sobre una ruta, o ediciones protegidas con `test` — donde la semántica de strategic-merge no puede expresar el cambio.

### Ejercicio 5
1. El **background controller** reconcilia los recursos generados. `synchronize: true` hace la relación *continua*: los cambios al origen (o el borrado/deriva del clon) se reconcilian continuamente, y borrar el disparador elimina el recurso generado. Un generate de una sola vez (`synchronize: false`) crea el objeto downstream una vez y no lo vuelve a tocar.
2. Es una **sustitución de variable / JMESPath** (`{{ ... }}`) que referencia el contexto de la solicitud de admission. Se resuelve en tiempo de ejecución de la regla, cuando Kyverno procesa la solicitud de admission disparadora, antes de que se finalice el spec del recurso generado.
3. **`clone:`** copia un objeto de origen existente (desde un namespace nombrado) y puede mantenerlo sincronizado con ese origen vivo; **`data:`** define el contenido del recurso generado **inline** en la política misma, así que no hay ningún objeto de origen externo que rastrear.

### Ejercicio 6
1. El ancla condicional `(image): "*:latest"` significa: **si** la condición hermana coincide (la imagen del contenedor termina en `:latest`), **entonces** el resto de esa entrada del mapa (`imagePullPolicy: Always`) también debe cumplirse. Si `image` **no** coincide con `*:latest`, la condición del ancla es falsa, todo el bloque se **omite** para ese contenedor, y pasa sin chequear `imagePullPolicy`.
2. `deny` está **invertido** respecto de `pattern`. Con `deny`, si las `conditions` evalúan a **true**, el recurso es **denegado/falla**; si es false, pasa. Con `pattern`, el recurso debe **coincidir** con el patrón para pasar — una discordancia es la falla. Así que `pattern` describe la forma *permitida*, `deny` describe la condición *prohibida*.
3. El fallback `|| \`0\`` provee un valor por defecto cuando `runAsUser` no está definido. Sin él, `{{ request.object.spec.securityContext.runAsUser }}` evalúa a `null`/undefined para un Pod que omite el campo, así que `operator: Equals value: 0` **no** coincidiría — y un Pod que hereda root por *defecto* (sin `runAsUser` explícito) se colaría por el chequeo que estaba pensado para atraparlo.
4. Las `preconditions` se evalúan **después** de que el recurso ya coincidió con el alcance de `match`/`exclude` y pueden usar JMESPath/variables completos sobre el contexto de la solicitud (valores, operadores como `AnyIn`, comparaciones). `match` es el selector grueso de recursos (kinds/namespaces/selectors/identidad). Usá `match` para elegir la población de recursos; usá `preconditions` para lógica por solicitud más rica que `match` no puede expresar. Una precondición que no se cumple **omite** la regla en lugar de hacerla fallar.

### Ejercicio 7
1. `kyverno apply` no puede reproducir por completo los **efectos secundarios en tiempo de admission y la reconciliación de controladores** — muy notablemente `generate` (que es ejecutado por el background controller contra un clúster vivo) y cualquier cosa que dependa del estado vivo del clúster (`context` con `apiCall`, verificación de imágenes contra un registry). Evalúa la lógica de la política contra los manifiestos dados pero no corre el loop de generación/sincronización.
2. La validación offline con la CLI es **determinística, rápida y no destructiva**: corre en CI contra manifiestos candidatos sin acceso al clúster, atrapando violaciones *antes* del merge. Depender del `Enforce` en vivo significa que el manifiesto malo ya llegó a un clúster (y bloquea un deploy real), y no puede correr sobre un pull request que todavía no se aplicó.

</details>