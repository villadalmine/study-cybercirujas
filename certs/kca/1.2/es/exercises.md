# Tema 1.2: YAML Manifests — Ejercicios guiados

> **Objetivo.** Terminar estos ejercicios sabiendo *escribir, generar, validar y depurar* manifiestos de Kubernetes con confianza. No memorizás YAML: aprendés a que el propio `kubectl` te dicte la estructura, a leer los errores que el API server devuelve, y a entender por qué un objeto que "parece bien" se rechaza o no engancha con otro.
>
> **Prerrequisitos.** Un cluster accesible (`kind`, `minikube` o uno real) y `kubectl` configurado. Verificá con `kubectl version` y `kubectl get nodes`. Trabajá en un namespace descartable para no ensuciar `default`:
>
> ```bash
> kubectl create namespace kca-1-2
> kubectl config set-context --current --namespace=kca-1-2
> ```
>
> Al terminar, limpiás todo con `kubectl delete namespace kca-1-2`.

---

## Ejercicio 1 — La anatomía de un manifiesto: los cuatro campos raíz

Todo objeto de Kubernetes, sin excepción, se serializa con la misma estructura de nivel superior: `apiVersion`, `kind`, `metadata` y (casi siempre) `spec`. El campo `status` existe pero lo escribe el cluster, no vos. En vez de memorizar campos, vas a hacer que el servidor te los describa.

1. Preguntale al cluster qué recursos conoce y en qué `apiVersion` viven:

   ```bash
   kubectl api-resources -o wide | head -n 12
   ```

   Salida esperada (recortada):

   ```
   NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND         VERBS
   pods          po           v1           true         Pod          create,delete,get,list,patch,update,watch
   services      svc          v1           true         Service      ...
   configmaps    cm           v1           true         ConfigMap    ...
   deployments   deploy       apps/v1      true         Deployment   ...
   ```

   Fijate que la columna `APIVERSION` es exactamente lo que va en el campo `apiVersion` del manifiesto: `v1` para `Pod` y `Service`, pero `apps/v1` para `Deployment`.

2. Pedile al servidor la estructura interna de un `Pod`, campo por campo:

   ```bash
   kubectl explain pod
   kubectl explain pod.spec --recursive | head -n 25
   kubectl explain pod.spec.containers.resources
   ```

   `kubectl explain` lee el OpenAPI schema del propio API server, así que **describe exactamente la versión de tu cluster** — no una doc genérica que puede estar desfasada.

3. Escribí a mano el manifiesto mínimo válido de un `Pod` en `pod-min.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
   spec:
     containers:
       - name: nginx
         image: nginx:1.27-alpine
   ```

4. Aplicalo y volvé a leerlo tal como quedó guardado en `etcd`:

   ```bash
   kubectl apply -f pod-min.yaml
   kubectl get pod web -o yaml | head -n 20
   ```

   Vas a ver muchísimos campos que vos no escribiste (`status`, `spec.restartPolicy: Always`, `spec.terminationGracePeriodSeconds: 30`, `metadata.uid`, `metadata.creationTimestamp`…). Los completó el cluster con defaults y con estado en tiempo de ejecución.

> **Preguntas de comprensión**
>
> 1. ¿Cuáles son los cuatro campos raíz de un objeto de Kubernetes y cuál de ellos **no** deberías escribir vos en un manifiesto? ¿Por qué?
> 2. Un compañero escribe `apiVersion: apps/v1` en un `Pod` y el `apply` falla. ¿Qué comando de este ejercicio le habría dicho el valor correcto antes de intentarlo?
> 3. ¿De dónde saca `kubectl explain` la información: de una base de datos externa, de la documentación de kubernetes.io, o del propio cluster? ¿Qué consecuencia práctica tiene esa respuesta?

---

## Ejercicio 2 — Sintaxis YAML: indentación, tipos escalares y las trampas clásicas

YAML es sensible a la indentación y **prohíbe los tabuladores**. Además infiere tipos de dato, y esa inferencia es la causa de bugs sutiles. Vas a provocarlos a propósito para reconocerlos.

1. Creá `types.yaml` con valores que YAML va a interpretar de forma inesperada:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: gotchas
   data:
     puerto: 8080          # esto NO es válido: data solo admite strings
     habilitado: true
     version: 1.10
     pais: NO
   ```

2. Aplicalo y leé el error:

   ```bash
   kubectl apply -f types.yaml
   ```

   Salida esperada:

   ```
   Error from server (BadRequest): error when creating "types.yaml":
   ConfigMap in version "v1" cannot be handled as a ConfigMap:
   json: cannot unmarshal number into Go struct field ConfigMap.data of type string
   ```

   El campo `data` de un `ConfigMap` solo admite **strings**. `8080` se interpretó como número, `true` como booleano, `1.10` como float (y perdería el cero final), y `NO` como el booleano `false` según YAML 1.1.

3. Arreglalo forzando que todo sea string con comillas, y reaplicá:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: gotchas
   data:
     puerto: "8080"
     habilitado: "true"
     version: "1.10"
     pais: "NO"
   ```

   ```bash
   kubectl apply -f types.yaml
   kubectl get configmap gotchas -o jsonpath='{.data.version}{"\n"}'
   ```

   Ahora `version` conserva `1.10` intacto y `pais` es `"NO"`, no `false`.

4. Comprobá que un tabulador rompe el parseo. Creá un archivo donde la indentación de `image` use un TAB en vez de espacios (en muchos editores, un `\t` real):

   ```bash
   printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: tabbed\nspec:\n  containers:\n\t- name: c\n' > tabbed.yaml
   kubectl apply -f tabbed.yaml
   ```

   Salida esperada (mensaje de parser YAML, no del API server):

   ```
   error converting YAML to JSON: yaml: line 7: found character that cannot start any token
   ```

5. Distinguí las tres formas de escribir una lista y un mapa. Estas dos son **equivalentes** (flow vs block style):

   ```yaml
   # block style (recomendado en manifiestos)
   command:
     - sh
     - -c
     - echo hola

   # flow style (una línea)
   command: ["sh", "-c", "echo hola"]
   ```

> **Preguntas de comprensión**
>
> 1. ¿Por qué `puerto: 8080` sin comillas falla dentro de `data:` de un `ConfigMap`, pero `containerPort: 8080` sin comillas en un `Pod` es perfectamente válido?
> 2. Nombrá tres valores que YAML 1.1 convierte a booleano si no los entrecomillás. ¿Qué desastre operacional puede causar `pais: NO` en un `ConfigMap` de configuración regional?
> 3. Un `apply` falla con `found character that cannot start any token`. ¿Es un error de Kubernetes o del parser YAML? ¿Cuál es la causa casi segura?

---

## Ejercicio 3 — Generar manifiestos con `--dry-run=client -o yaml` (el atajo del examen)

Escribir manifiestos a mano es lento y propenso a errores. La técnica de producción es dejar que `kubectl` genere el esqueleto y vos lo editás. Es imprescindible para trabajar rápido.

1. Generá el manifiesto de un `Pod` sin crearlo:

   ```bash
   kubectl run web --image=nginx:1.27-alpine --dry-run=client -o yaml
   ```

   `--dry-run=client` significa "armá el objeto pero no lo mandes al API server". `-o yaml` lo imprime.

2. Guardalo como base editable:

   ```bash
   kubectl run web --image=nginx:1.27-alpine \
     --port=80 --dry-run=client -o yaml > pod-gen.yaml
   ```

3. Generá un `Deployment` con 3 réplicas y un `Service` que lo exponga, sin tocar el cluster todavía:

   ```bash
   kubectl create deployment api --image=hashicorp/http-echo:1.0 \
     --replicas=3 --dry-run=client -o yaml > deploy-gen.yaml

   kubectl create service clusterip api --tcp=80:5678 \
     --dry-run=client -o yaml > svc-gen.yaml
   ```

4. Inspeccioná el `Deployment` generado y localizá el bloque que **acopla** el Deployment a sus Pods:

   ```bash
   grep -nA4 'selector:' deploy-gen.yaml
   grep -nA3 'template:' deploy-gen.yaml
   ```

   Vas a ver que `spec.selector.matchLabels` y `spec.template.metadata.labels` comparten `app: api`. Ese emparejamiento no es decorativo — lo estudiás en el Ejercicio 5.

5. Comprendé la diferencia entre `--dry-run=client` y `--dry-run=server`:

   ```bash
   # client: nunca contacta al API server; no valida contra admission controllers
   kubectl apply -f deploy-gen.yaml --dry-run=client

   # server: el API server procesa y VALIDA el objeto, pero no lo persiste en etcd
   kubectl apply -f deploy-gen.yaml --dry-run=server
   ```

> **Preguntas de comprensión**
>
> 1. ¿Qué hace exactamente `--dry-run=client -o yaml` y por qué es la forma más rápida de empezar un manifiesto en vez de escribirlo desde cero?
> 2. Un manifiesto pasa `--dry-run=client` pero es rechazado con `--dry-run=server`. ¿Qué tipo de problema detecta la validación *server-side* que la *client-side* no puede ver?
> 3. ¿Qué diferencia hay entre `kubectl run` y `kubectl create deployment` en cuanto al `kind` que generan?

---

## Ejercicio 4 — Multi-document YAML y `kubectl apply -f`

Un solo archivo puede contener varios objetos separados por `---`. Es la forma canónica de versionar una aplicación completa en un único manifiesto.

1. Creá `app.yaml` con dos objetos en un solo archivo:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: echo
     labels:
       app: echo
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: echo
     template:
       metadata:
         labels:
           app: echo
       spec:
         containers:
           - name: echo
             image: hashicorp/http-echo:1.0
             args: ["-text=hola kca", "-listen=:5678"]
             ports:
               - containerPort: 5678
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: echo
   spec:
     selector:
       app: echo
     ports:
       - port: 80
         targetPort: 5678
   ```

2. Aplicá el archivo completo de una sola vez:

   ```bash
   kubectl apply -f app.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/echo created
   service/echo created
   ```

   Un solo comando creó dos objetos, en el orden en que aparecen.

3. Verificá que el `Service` efectivamente enganchó Pods (tiene endpoints):

   ```bash
   kubectl get endpoints echo
   ```

   Salida esperada (dos IP:puerto, una por réplica):

   ```
   NAME   ENDPOINTS                       AGE
   echo   10.244.0.7:5678,10.244.0.8:5678 15s
   ```

4. Probá la idempotencia de `apply`. Cambiá `replicas: 2` a `replicas: 3` en `app.yaml` y reaplicá:

   ```bash
   kubectl apply -f app.yaml
   ```

   Salida esperada:

   ```
   deployment.apps/echo configured
   service/echo unchanged
   ```

   `apply` es declarativo: reconcilia el estado deseado. El `Deployment` cambió (`configured`), el `Service` no (`unchanged`). Aplicarlo diez veces más sin editar no rompe nada.

> **Preguntas de comprensión**
>
> 1. ¿Qué separador usa YAML para poner varios objetos en un mismo archivo, y por qué es útil frente a tener un archivo por objeto?
> 2. `kubectl apply` sobre un objeto que ya existe imprime `configured` o `unchanged`. ¿Qué significa cada uno y qué propiedad de `apply` demuestran?
> 3. Aplicaste el `Deployment` y el `Service`, pero `kubectl get endpoints echo` sale vacío (`<none>`). ¿Qué campo del `Service` y qué campo de los Pods hay que revisar?

---

## Ejercicio 5 — Labels, selectors y el acoplamiento Deployment ↔ Pod ↔ Service

Los `labels` son pares clave-valor arbitrarios; los `selectors` son consultas sobre esos labels. Todo el "cableado" interno de Kubernetes — qué Pods gobierna un Deployment, a qué Pods enruta un Service — se hace por labels, no por nombres. Este es el concepto que más se malinterpreta.

1. Mirá los labels que ya tienen tus Pods del `Deployment echo`:

   ```bash
   kubectl get pods --show-labels
   ```

   Salida esperada (recortada):

   ```
   NAME                    READY   STATUS    LABELS
   echo-5c8...-abcde       1/1     Running   app=echo,pod-template-hash=5c8...
   echo-5c8...-fghij       1/1     Running   app=echo,pod-template-hash=5c8...
   ```

2. Filtrá Pods por label, igual que hace un Service internamente:

   ```bash
   kubectl get pods -l app=echo
   kubectl get pods -l 'app in (echo,web)'
   ```

3. Provocá el error más común: un `matchLabels` que **no coincide** con el `template.labels`. Creá `broken-selector.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: mismatch
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: frontend        # el selector busca app=frontend
     template:
       metadata:
         labels:
           app: backend        # pero el Pod lleva app=backend
       spec:
         containers:
           - name: c
             image: nginx:1.27-alpine
   ```

   ```bash
   kubectl apply -f broken-selector.yaml
   ```

   Salida esperada:

   ```
   The Deployment "mismatch" is invalid: spec.template.metadata.labels:
   Invalid value: map[string]string{"app":"backend"}:
   `selector` does not match template `labels`
   ```

   El API server rechaza el objeto **antes** de crearlo: un `Deployment` cuyo selector no matchea su propio template no podría gobernar nunca a los Pods que crea.

4. Entendé la relación en cadena. Corregí `broken-selector.yaml` para que ambos digan `app: frontend`, aplicalo, y exponelo:

   ```bash
   kubectl apply -f broken-selector.yaml
   kubectl expose deployment mismatch --name=front-svc --port=80
   kubectl get endpoints front-svc
   ```

   El `Service` encuentra los Pods **por el label `app: frontend`**, no por pertenecer al Deployment. Si cambiaras el label de un Pod suelto, el Service dejaría de enrutarle tráfico aunque el Deployment lo siga contando.

> **Preguntas de comprensión**
>
> 1. Explicá con tus palabras la cadena de acoplamiento: ¿cómo sabe un `Deployment` qué Pods son suyos, y cómo sabe un `Service` a qué Pods enrutar? ¿Qué mecanismo comparten?
> 2. ¿Por qué el API server rechaza de plano un `Deployment` cuyo `spec.selector.matchLabels` difiere de `spec.template.metadata.labels`?
> 3. Un `Service` tiene `selector: {app: echo}` pero `kubectl get endpoints` sale vacío aunque hay Pods `Running`. Los Pods tienen label `application: echo`. ¿Cuál es el bug y cómo lo confirmás con `kubectl get pods -l`?

---

## Ejercicio 6 — ConfigMaps, Secrets y su inyección en un Pod

La configuración se separa del código en `ConfigMap` (texto plano) y `Secret` (datos sensibles, codificados en base64). Este ejercicio cubre cómo se escriben y cómo se inyectan.

1. Creá un `ConfigMap` y un `Secret` de forma declarativa. Notá los dos campos de un `Secret`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
   data:
     LOG_LEVEL: "info"
     GREETING: "hola produccion"
   ---
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-secret
   type: Opaque
   stringData:
     DB_PASSWORD: "s3cr3t-en-claro"   # stringData: lo escribís en claro, el cluster lo codifica
   ```

   ```bash
   kubectl apply -f config.yaml
   ```

   > `stringData` te deja escribir el valor en texto plano y Kubernetes lo codifica a base64 al persistirlo. El campo alternativo `data` exige que vos ya provеás el base64 (`echo -n valor | base64`). **base64 no es cifrado** — es solo codificación; cualquiera con acceso de lectura al Secret ve el valor.

2. Verificá cómo quedó guardado el `Secret`:

   ```bash
   kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}'; echo
   ```

   Salida esperada (el valor codificado):

   ```
   czNjcjN0LWVuLWNsYXJv
   ```

   Decodificalo para comprobar que es tu contraseña:

   ```bash
   kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
   ```

3. Inyectalos en un Pod como variables de entorno. Creá `consumer.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer
   spec:
     restartPolicy: Never
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "echo \"$GREETING / nivel=$LOG_LEVEL / pass=$DB_PASSWORD\"; sleep 3600"]
         env:
           - name: GREETING
             valueFrom:
               configMapKeyRef:
                 name: app-config
                 key: GREETING
           - name: LOG_LEVEL
             valueFrom:
               configMapKeyRef:
                 name: app-config
                 key: LOG_LEVEL
           - name: DB_PASSWORD
             valueFrom:
               secretKeyRef:
                 name: app-secret
                 key: DB_PASSWORD
   ```

   ```bash
   kubectl apply -f consumer.yaml
   kubectl logs consumer
   ```

   Salida esperada:

   ```
   hola produccion / nivel=info / pass=s3cr3t-en-claro
   ```

4. Alternativa: montar el `ConfigMap` como archivos en un volumen (útil para archivos de configuración enteros):

   ```yaml
   # dentro de spec del Pod
   volumes:
     - name: cfg
       configMap:
         name: app-config
   # dentro del container
   volumeMounts:
     - name: cfg
       mountPath: /etc/app
   ```

   Cada clave del `ConfigMap` aparece como un archivo (`/etc/app/LOG_LEVEL`, `/etc/app/GREETING`).

> **Preguntas de comprensión**
>
> 1. ¿Qué diferencia hay entre los campos `data` y `stringData` de un `Secret`? ¿Cuál te evita correr `base64` a mano?
> 2. Un compañero dice "los Secrets están seguros porque están cifrados en base64". ¿Por qué es una afirmación peligrosamente incorrecta?
> 3. ¿Cuáles son las dos formas de inyectar un `ConfigMap` en un contenedor, y en qué caso conviene cada una (variable de entorno vs volumen)?

---

## Ejercicio 7 — Validación, `diff` y depuración de manifiestos rotos

En producción no aplicás a ciegas: validás contra el servidor y comparás con el estado vivo antes de tocar nada. Y sabés leer los errores.

1. Validá un manifiesto contra el API server **sin persistirlo**:

   ```bash
   kubectl apply -f app.yaml --dry-run=server
   ```

   Esto ejecuta admission controllers y defaulting reales; atrapa errores que `--dry-run=client` no ve.

2. Compará tu manifiesto con lo que hay vivo en el cluster antes de aplicar. Editá `app.yaml` (por ejemplo cambiá el `-text` del `http-echo` a `hola v2`) y corré:

   ```bash
   kubectl diff -f app.yaml
   ```

   Salida esperada (formato diff, solo las líneas que cambiarían):

   ```diff
         - -text=hola kca
         + -text=hola v2
   ```

   `kubectl diff` es tu "preview" antes del `apply`: muestra exactamente qué campos cambiarían.

3. Reconocé el error de **campo desconocido** (typo en un nombre de campo). Creá `typo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: typo
   spec:
     containers:
       - name: c
         image: nginx:1.27-alpine
         ports:
           - containerPorts: 80      # está mal: es containerPort (singular)
   ```

   ```bash
   kubectl apply -f typo.yaml
   ```

   Salida esperada:

   ```
   error: error validating "typo.yaml": error validating data:
   ValidationError(Pod.spec.containers[0].ports[0]): unknown field "containerPorts"
   in io.k8s.api.core.v1.ContainerPort; if you choose to ignore these errors,
   turn validation off with --validate=false
   ```

   El validador de esquema del cliente atrapó el campo inexistente. La pista está en el path: `Pod.spec.containers[0].ports[0]`.

4. Reconocé el error de **indentación semántica** (YAML válido, jerarquía incorrecta). Creá `misplaced.yaml`, donde `image` quedó al nivel de la lista de containers en vez de dentro del container:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: misplaced
   spec:
     containers:
       - name: c
     image: nginx:1.27-alpine     # indentado como campo de spec, no del container
   ```

   ```bash
   kubectl apply -f misplaced.yaml
   ```

   Salida esperada:

   ```
   error: error validating "misplaced.yaml": error validating data:
   [ValidationError(Pod.spec): unknown field "image",
   ValidationError(Pod.spec.containers[0]): missing required field "image"]
   ```

   El YAML parseó perfecto — el problema es que `image` está en el nivel equivocado del árbol. El validador te lo dice con dos errores complementarios: sobra un `image` en `spec` y falta uno en `containers[0]`.

5. Confirmá tu último recurso cuando un campo generado no debe reaplicarse: podés desactivar la validación de esquema con `--validate=false`, pero **es una mala señal** — casi siempre significa que hay un typo real. Usalo solo para diagnosticar, nunca como fix.

> **Preguntas de comprensión**
>
> 1. ¿Qué valida `kubectl apply --dry-run=server` que `--dry-run=client` no puede validar? Da un ejemplo concreto de error que solo aparecería server-side.
> 2. Un `apply` falla con `unknown field "containerPorts"`. ¿En qué parte del mensaje de error está la pista para localizar el typo, y cuál es la corrección?
> 3. El manifiesto del paso 4 es YAML *sintácticamente válido* pero Kubernetes lo rechaza con "unknown field image" **y** "missing required field image" a la vez. ¿Cómo puede faltar y sobrar el mismo campo? ¿Qué herramienta usarías antes de aplicar para no llegar a este error?

---

## Limpieza

```bash
kubectl delete namespace kca-1-2
kubectl config set-context --current --namespace=default
```

---

## Respuestas

<details>
<summary>Mostrar respuestas de todos los ejercicios</summary>

### Ejercicio 1

1. Los cuatro campos raíz son **`apiVersion`**, **`kind`**, **`metadata`** y **`spec`**. El que no escribís vos es **`status`**: lo escribe y actualiza el control plane para reflejar el estado observado del objeto (por ejemplo, la fase del Pod o las réplicas disponibles). Escribirlo a mano no tiene efecto — el cluster lo sobreescribe en su ciclo de reconciliación.
2. **`kubectl api-resources`** (columna `APIVERSION`) le habría mostrado que un `Pod` es `v1`, no `apps/v1`. `apps/v1` corresponde a `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`. También servía `kubectl explain pod` en la primera línea (`VERSION: v1`).
3. Del **propio cluster**: `kubectl explain` consulta el OpenAPI schema publicado por el API server al que estás conectado. La consecuencia práctica es que describe *exactamente* la versión de Kubernetes que corrés — no una doc genérica que podría estar adelantada o atrasada respecto de tu cluster, evitando que estudies campos que tu versión no tiene o que ya fueron removidos.

### Ejercicio 2

1. Porque el campo `data` de un `ConfigMap` está tipado como `map[string]string` en el schema: **todos sus valores deben ser strings**. `8080` sin comillas lo parsea YAML como entero y el unmarshalling a string falla. En cambio `containerPort` está tipado como entero (`int32`) en el schema del `Pod`, así que ahí el número sin comillas es exactamente lo que se espera. La regla no es de YAML, es del schema del campo destino.
2. Tres ejemplos: **`true`/`false`**, **`yes`/`no`**, **`on`/`off`** (y `NO`/`Yes` en mayúsculas, por YAML 1.1). `pais: NO` sin comillas se convierte en el booleano `false`; si ese ConfigMap alimenta la configuración de país/idioma, "Noruega" (`NO`) se transforma silenciosamente en `false` — un bug que no lanza error, solo produce comportamiento incorrecto. Por eso se entrecomilla todo valor de `data`.
3. Es un error del **parser YAML**, no de Kubernetes (el objeto nunca llega a validarse contra el schema). La causa casi segura es un **tabulador** en la indentación: YAML prohíbe tabs para indentar, solo admite espacios.

### Ejercicio 3

1. Construye el objeto completo (aplicando defaults del cliente) pero **no lo envía al API server** (`--dry-run=client`) y lo imprime como YAML (`-o yaml`). Es más rápido que escribir desde cero porque `kubectl` ya conoce la estructura, los nombres exactos de los campos y el `apiVersion` correcto — vos solo redirigís a un archivo y editás lo que falta.
2. La validación **server-side** ejecuta admission controllers, defaulting y validaciones del propio API server. Detecta cosas invisibles al cliente: un `namespace` que no existe, una `ResourceQuota` o `LimitRange` que el objeto viola, un admission webhook que lo rechaza, o un valor inválido para tu versión concreta del cluster. La validación client-side solo revisa el esquema estructural local.
3. `kubectl run` genera un **`Pod`** (un solo objeto). `kubectl create deployment` genera un **`Deployment`** (`apps/v1`), que a su vez gestiona un ReplicaSet y los Pods.

### Ejercicio 4

1. El separador **`---`** (tres guiones). Es útil porque agrupa toda una aplicación (Deployment + Service + ConfigMap…) en un único archivo versionable, se aplica con un solo `kubectl apply -f`, y mantiene juntos objetos que se despliegan y evolucionan como una unidad.
2. **`configured`** = el objeto ya existía y el `apply` reconcilió al menos un campo con el estado deseado del manifiesto. **`unchanged`** = el estado vivo ya coincidía con el manifiesto, no hubo nada que cambiar. Ambos demuestran que `apply` es **declarativo e idempotente**: describís el estado final deseado y aplicarlo repetidas veces sin editar no produce cambios ni errores.
3. Hay que revisar el **`spec.selector` del Service** y los **`labels` de los Pods** (`spec.template.metadata.labels` del Deployment): si el selector del Service no matchea exactamente los labels de los Pods, el Service no arma endpoints y sale `<none>`. Se confirma con `kubectl get pods --show-labels` y `kubectl get pods -l <selector-del-service>`.

### Ejercicio 5

1. Un `Deployment` sabe qué Pods son suyos por su **`spec.selector.matchLabels`**, que consulta los labels puestos en `spec.template.metadata.labels`. Un `Service` enruta a los Pods cuyos labels matchean su **`spec.selector`**. El mecanismo compartido son los **labels**: nada se referencia por nombre, todo por coincidencia de labels. Por eso un Pod puede ser gobernado por un Deployment y enrutado por un Service simultáneamente, siempre que sus labels satisfagan ambos selectors.
2. Porque un `Deployment` cuyo selector no matchea el template de sus propios Pods **no podría adoptar nunca a los Pods que crea** — quedaría en un estado incoherente e imposible de reconciliar. El API server lo rechaza en tiempo de validación (`selector does not match template labels`) para prevenir ese objeto imposible antes de persistirlo.
3. El bug es un **desajuste de clave de label**: el Service busca `app=echo` pero los Pods tienen `application=echo` (clave distinta). Se confirma con `kubectl get pods -l app=echo` (no devuelve nada) frente a `kubectl get pods -l application=echo` (sí devuelve los Pods). La corrección es alinear la clave en ambos lados.

### Ejercicio 6

1. **`data`** espera valores ya codificados en **base64** (los codificás vos a mano). **`stringData`** los acepta en **texto plano** y el cluster los codifica a base64 al guardarlos; es un campo de solo escritura que te evita correr `base64`. Al leer el Secret siempre ves el resultado bajo `.data` en base64.
2. Porque **base64 es codificación, no cifrado**: es reversible por cualquiera sin ninguna clave (`base64 -d`). Cualquier persona con permiso de lectura sobre el Secret, o con acceso a etcd si no está cifrado en reposo, obtiene el valor original de inmediato. La protección real viene de RBAC, cifrado de etcd at-rest y gestores de secretos externos — no del base64.
3. **Variables de entorno** (`env.valueFrom.configMapKeyRef`) y **volumen montado** (`volumes.configMap` + `volumeMounts`). Las variables de entorno convienen para pocos valores discretos que la app lee del entorno; el volumen conviene cuando el ConfigMap contiene archivos de configuración enteros (cada clave se vuelve un archivo) o cuando querés que los cambios se reflejen sin recrear el Pod (los montajes de volumen se actualizan, las env vars no).

### Ejercicio 7

1. `--dry-run=server` valida a través del **API server real**: ejecuta admission controllers, webhooks, defaulting y comprobaciones dependientes del estado del cluster. Ejemplo concreto que solo aparece server-side: aplicar a un `namespace` inexistente, violar una `ResourceQuota`, o ser rechazado por un `ValidatingAdmissionWebhook`. `--dry-run=client` solo valida el esquema estructural localmente y no ve nada de eso.
2. La pista está en el **path del objeto** que precede al campo: `ValidationError(Pod.spec.containers[0].ports[0]): unknown field "containerPorts"`. Indica exactamente dónde está el campo inexistente. La corrección es `containerPort` (singular).
3. Porque el campo **está en el nivel equivocado del árbol**: `image` quedó indentado como hijo de `spec` (donde `image` no existe → "unknown field") en vez de dentro de `containers[0]` (donde `image` es obligatorio → "missing required field"). Un mismo campo mal ubicado dispara ambos errores a la vez. Antes de aplicar lo detectás con **`kubectl apply --dry-run=client`** (o `--dry-run=server`), que corre la validación de esquema sin crear el objeto; y `kubectl explain pod.spec.containers` confirma dónde va cada campo.

</details>

---

**Fuentes**
- CNCF — *KCA (Kubernetes and Cloud Native Associate) Curriculum*: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Kubernetes — *Objects In Kubernetes* (apiVersion, kind, metadata, spec, status): https://kubernetes.io/docs/concepts/overview/working-with-objects/kubernetes-objects/
- Kubernetes — *Labels and Selectors*: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes — *Managing Resources / `kubectl apply`*: https://kubernetes.io/docs/concepts/cluster-administration/manage-deployment/
- Kubernetes — *ConfigMaps*: https://kubernetes.io/docs/concepts/configuration/configmap/ y *Secrets*: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — *Server-Side Dry Run*: https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run