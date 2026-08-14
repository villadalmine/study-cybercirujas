# 5.4 Reglas de mutación — Ejercicios guiados

> **Dominio 5 — Escritura de políticas · Tema 5.4 · Peso en el examen 2.91%**
> Currículum KCA: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

Estos ejercicios están pensados para ser *ejecutados*, no leídos. Cada bloque termina con preguntas de verificación; todas las respuestas están plegadas al final. Varios pasos producen deliberadamente un **resultado incorrecto o sorprendente** — ese es justamente el objetivo. La mutación es el tipo de regla de Kyverno donde la brecha entre "el YAML se ve bien" y "el clúster hizo lo que yo quería" es más amplia, y el examen evalúa exactamente esa brecha.

**Tiempo estimado:** 90–120 minutos.

---

## Prerrequisitos del laboratorio

| Requisito | Verificación |
|---|---|
| Un clúster en el que puedas instalar CRDs de alcance de clúster (kind/k3d/minikube sirven) | `kubectl auth can-i create customresourcedefinitions` → `yes` |
| Kyverno 1.11 o posterior, instalado a nivel de clúster | `kubectl -n kyverno get deploy` |
| La CLI de Kyverno (`kyverno`, también usable como `kubectl kyverno`) | `kyverno version` |
| `jq` para leer los resultados de admisión | `jq --version` |

Instala Kyverno si no lo tienes:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace
```

> El examen está fijado a una versión menor concreta de Kyverno, indicada en la página del examen. Nombres de campo como `mutateExistingOnPolicyUpdate` y el esquema de test de la CLI han cambiado entre versiones. Donde el comportamiento depende de la versión, los ejercicios lo advierten — **verifica contra la versión que tienes delante en lugar de fiarte de la memoria.**

---

## Ejercicio 0 — Mapea la ruta de mutación antes de escribir una política

**Objetivo:** saber qué componente realiza una mutación, y en qué punto de la cadena de admisión ocurre, antes de depurar nada.

1. Lista el plano de control de Kyverno:

   ```bash
   kubectl -n kyverno get deploy
   ```

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           3m
   kyverno-background-controller   1/1     1            1           3m
   kyverno-cleanup-controller      1/1     1            1           3m
   kyverno-reports-controller      1/1     1            1           3m
   ```

2. Lista las configuraciones de webhook de mutación que pertenecen a Kyverno, y anota el número de webhooks de cada una:

   ```bash
   kubectl get mutatingwebhookconfigurations \
     -o custom-columns='NAME:.metadata.name,WEBHOOKS:.webhooks[*].name'
   ```

   ```
   NAME                                    WEBHOOKS
   kyverno-policy-mutating-webhook-cfg     mutate-policy.kyverno.svc
   kyverno-resource-mutating-webhook-cfg   <none>
   kyverno-verify-mutating-webhook-cfg     monitor-webhooks.kyverno.svc
   ```

3. Observa las reglas registradas en el webhook de recursos — el que mutará *tus* cargas de trabajo:

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{.webhooks[*].rules}' | jq .
   ```

4. Crea el namespace del laboratorio:

   ```bash
   kubectl create namespace mutation-lab
   ```

5. Lee la lista de exclusiones que Kyverno trae de fábrica, y observa qué namespaces quedan filtrados:

   ```bash
   kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n'
   ```

**Comprueba tu comprensión**

- **Q1.** En el paso 2, `kyverno-resource-mutating-webhook-cfg` existe pero no tiene webhooks (o no tiene reglas). ¿Por qué está vacío en una instalación recién hecha, y qué lo cambiará?
- **Q2.** Kubernetes ejecuta los webhooks de admisión de mutación, luego la validación de esquema del objeto, y luego los webhooks de admisión de validación. ¿Cuál de los cuatro Deployments de Kyverno atiende cada una de las dos fases de webhook, y cuál *no* está en la ruta de admisión en absoluto?
- **Q3.** Un colega informa: "Kyverno ignora mi política para los pods en `kube-system`". ¿Qué clave de configuración del paso 5 explica esto, y cuál es el formato de cada entrada?
- **Q4.** Si todos los Pods de `kyverno-admission-controller` están caídos, ¿qué ocurre con un `kubectl apply` de un Pod que coincide con una política de mutación? ¿Qué campo de la política lo decide?

---

## Ejercicio 1 — `patchStrategicMerge`, variables y la trampa del modo background

**Objetivo:** escribir la mutación más simple posible, y chocar con el primer muro de validación que Kyverno te pone delante.

1. Escribe `01-owner.yaml`. Nota que `background` se deja en su valor por defecto:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-owner-metadata
     annotations:
       policies.kyverno.io/title: Add owner metadata
       policies.kyverno.io/category: Governance
       policies.kyverno.io/subject: Pod
   spec:
     rules:
       - name: add-team-and-creator
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - mutation-lab
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 team: platform
               annotations:
                 owner.example.com/created-by: "{{ request.userInfo.username }}"
   ```

2. Aplícala y lee el rechazo con atención:

   ```bash
   kubectl apply -f 01-owner.yaml
   ```

   ```
   Error from server: error when creating "01-owner.yaml": admission webhook
   "validate-policy.kyverno.svc" denied the request: spec.rules[0].mutate.patchStrategicMerge:
   rule "add-team-and-creator" should not have variables that are not allowed in background mode:
   variable {{request.userInfo.username}} is not allowed in background mode
   ```

   *(La redacción varía según la versión; el fondo no.)*

3. Añade `background: false` justo debajo de `spec:`, encima de `rules:`, y vuelve a aplicar:

   ```yaml
   spec:
     background: false
     rules:
   ```

   ```bash
   kubectl apply -f 01-owner.yaml
   ```

   ```
   clusterpolicy.kyverno.io/add-owner-metadata created
   ```

4. Confirma que la política está admitida y lista:

   ```bash
   kubectl get clusterpolicy add-owner-metadata
   ```

   ```
   NAME                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
   add-owner-metadata   true        false        Audit             True    5s
   ```

5. Vuelve a ejecutar el paso 3 del Ejercicio 0 y compara las reglas del webhook con lo que anotaste entonces.

6. Crea un Pod que no establezca ni la etiqueta ni la anotación:

   ```bash
   kubectl -n mutation-lab run web --image=nginx:1.27 --restart=Never
   ```

7. Inspecciona qué aterrizó realmente en etcd:

   ```bash
   kubectl -n mutation-lab get pod web \
     -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}' | jq -s .
   ```

   ```json
   [
     { "run": "web", "team": "platform" },
     { "owner.example.com/created-by": "kubernetes-admin" }
   ]
   ```

8. Confirma que tu manifiesto local nunca fue tocado, y que la mutación queda registrada como un evento:

   ```bash
   kubectl -n mutation-lab get events --field-selector reason=PolicyApplied
   ```

**Comprueba tu comprensión**

- **Q5.** ¿Por qué Kyverno rechaza una política que usa `{{ request.userInfo.username }}` a menos que tenga `background: false`? ¿Qué habilita realmente `background: true`?
- **Q6.** El nombre de usuario se escribió en una **anotación**, no en una etiqueta. Da el fallo concreto que ocurre si lo mueves a `metadata.labels` y un controlador de Deployment crea el Pod.
- **Q7.** El paso 5 muestra que las reglas del webhook cambiaron. ¿Qué está haciendo Kyverno, y cuál es la consecuencia operativa de aplicar la primerísima política de mutación para un nuevo tipo de recurso?
- **Q8.** El Pod en el clúster tiene una etiqueta que tu `kubectl run` nunca pidió. Nombra dos formas en que esto aparece como problema en un pipeline de GitOps, y una forma de evitarlo.
- **Q9.** `patchStrategicMerge` creó `metadata.annotations`, que no existía en el Pod entrante. ¿Es ese un comportamiento garantizado para todos los tipos de parche que Kyverno soporta? (Probarás la respuesta en el Ejercicio 3.)

---

## Ejercicio 2 — Anclas: `+()`, `()`, y por qué "añadir si no está presente" a veces nunca se dispara

**Objetivo:** distinguir empíricamente el ancla *condicional* del ancla de *añadir-si-no-está-presente*, y descubrir que el establecimiento de valores por defecto del servidor de API se ejecuta **antes** que tu webhook.

1. Escribe `02-anchors.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: anchor-semantics
   spec:
     rules:
       - name: default-tier-label-if-absent
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             metadata:
               labels:
                 +(tier): backend

       - name: default-pull-policy-if-absent
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             spec:
               containers:
                 - (name): "*"
                   +(imagePullPolicy): Never

       - name: force-always-for-latest
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             spec:
               containers:
                 - (image): "*:latest"
                   imagePullPolicy: Always
   ```

   `Never` se elige deliberadamente: es un valor que el servidor de API de Kubernetes nunca elegiría por su cuenta, así que su presencia o ausencia es una señal limpia.

2. Aplícala:

   ```bash
   kubectl apply -f 02-anchors.yaml
   ```

3. Crea tres Pods con estados de partida distintos:

   ```bash
   kubectl -n mutation-lab run a-plain    --image=nginx:1.27 --restart=Never
   kubectl -n mutation-lab run b-labelled --image=nginx:1.27 --restart=Never --labels=tier=frontend
   kubectl -n mutation-lab run c-latest   --image=nginx:latest --restart=Never
   ```

4. Compara los tres de una sola vez:

   ```bash
   kubectl -n mutation-lab get pod a-plain b-labelled c-latest \
     -o custom-columns='POD:.metadata.name,TIER:.metadata.labels.tier,IMAGE:.spec.containers[0].image,PULL:.spec.containers[0].imagePullPolicy'
   ```

   ```
   POD          TIER       IMAGE          PULL
   a-plain      backend    nginx:1.27     IfNotPresent
   b-labelled   frontend   nginx:1.27     IfNotPresent
   c-latest     backend    nginx:latest   Always
   ```

5. Demuestra que la tercera regla hizo algo más que coincidir con el valor por defecto. Establece temporalmente una política explícita no predeterminada sobre una imagen sin etiqueta:

   ```bash
   kubectl -n mutation-lab run d-untagged --image=nginx --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"d-untagged","image":"nginx","imagePullPolicy":"IfNotPresent"}]}}'
   kubectl -n mutation-lab get pod d-untagged -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
   ```

   ```
   IfNotPresent
   ```

6. Consulta el informe de política para ver qué reglas cree Kyverno que aplicó:

   ```bash
   kubectl -n mutation-lab get policyreport -o wide 2>/dev/null | head
   kubectl -n mutation-lab get events --field-selector reason=PolicyApplied \
     -o custom-columns='OBJ:.involvedObject.name,MSG:.message' | head
   ```

**Comprueba tu comprensión**

- **Q10.** La regla `default-tier-label-if-absent` funcionó: `a-plain` obtuvo `tier=backend`, `b-labelled` conservó `frontend`. Enuncia la regla de `+()` en una frase.
- **Q11.** La regla `default-pull-policy-if-absent` estableció `Never` en **nada**, y sin embargo Kyverno no reporta ningún error. ¿Por qué `+(imagePullPolicy)` nunca se disparó? (Esta es la respuesta más importante de este ejercicio.)
- **Q12.** En `(name): "*"`, ¿qué está haciendo el ancla, y qué significaría el parche si escribieras `name: "*"` sin paréntesis?
- **Q13.** `d-untagged` usa la imagen `nginx` sin etiqueta. Kubernetes trata una imagen sin etiqueta como `:latest`, y sin embargo la regla `force-always-for-latest` no coincidió con ella. ¿Por qué, y cómo escribirías la coincidencia para que cubra ambas formas?
- **Q14.** La regla 2 establece `imagePullPolicy` y la regla 3 lo sobrescribe para `:latest`. ¿Está garantizado el orden entre esas dos reglas? ¿Y el orden entre dos ClusterPolicies *separadas* que tocan el mismo campo?
- **Q15.** Nombra las anclas que son válidas **solo** en reglas `validate`, y la que se evalúa contra el recurso entero en lugar de contra el nodo en el que está situada.

---

## Ejercicio 3 — `patchesJson6902`: precisión, y la regla de que el padre debe existir

**Objetivo:** aprender cuándo RFC 6902 es la única herramienta correcta, y por qué falla donde el strategic merge tiene éxito en silencio.

1. Primero, demuestra por qué el strategic merge es la herramienta equivocada aquí. Escribe `03-toleration-smp.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: batch-toleration-smp
   spec:
     rules:
       - name: add-batch-toleration
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         mutate:
           patchStrategicMerge:
             spec:
               tolerations:
                 - key: workload
                   operator: Equal
                   value: batch
                   effect: NoSchedule
   ```

2. Aplícala y crea un Pod que **ya** lleva una toleration no relacionada:

   ```bash
   kubectl apply -f 03-toleration-smp.yaml
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: batch-one
     namespace: mutation-lab
     labels:
       workload-type: batch
   spec:
     tolerations:
       - key: node.example.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: worker
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

3. Cuenta las tolerations que sobrevivieron:

   ```bash
   kubectl -n mutation-lab get pod batch-one -o jsonpath='{.spec.tolerations}' | jq 'length, .[].key'
   ```

   ```
   1
   "workload"
   ```

   La toleration de GPU desapareció.

4. Borra esa política y el Pod, y reconstruye la regla con JSON Patch. Escribe `03-toleration-6902.yaml` — nota que hacen falta **dos reglas**:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: batch-toleration
   spec:
     rules:
       - name: create-toleration-list
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         preconditions:
           all:
             - key: "{{ request.object.spec | keys(@) | contains(@, 'tolerations') }}"
               operator: Equals
               value: false
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/spec/tolerations"
               value:
                 - key: workload
                   operator: Equal
                   value: batch
                   effect: NoSchedule

       - name: append-to-existing-list
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
                 selector:
                   matchLabels:
                     workload-type: batch
         preconditions:
           all:
             - key: "{{ request.object.spec | keys(@) | contains(@, 'tolerations') }}"
               operator: Equals
               value: true
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/spec/tolerations/-"
               value:
                 key: workload
                 operator: Equal
                 value: batch
                 effect: NoSchedule
   ```

5. Aplica y vuelve a probar ambos estados de partida:

   ```bash
   kubectl delete clusterpolicy batch-toleration-smp --ignore-not-found
   kubectl -n mutation-lab delete pod batch-one --ignore-not-found
   kubectl apply -f 03-toleration-6902.yaml

   kubectl -n mutation-lab run batch-plain --image=busybox:1.36 --restart=Never \
     --labels=workload-type=batch -- sleep 3600

   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: batch-gpu
     namespace: mutation-lab
     labels:
       workload-type: batch
   spec:
     tolerations:
       - key: node.example.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: worker
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

6. Verifica:

   ```bash
   for p in batch-plain batch-gpu; do
     echo "== $p"
     kubectl -n mutation-lab get pod $p -o jsonpath='{.spec.tolerations[*].key}{"\n"}'
   done
   ```

   ```
   == batch-plain
   workload
   == batch-gpu
   node.example.com/gpu workload
   ```

7. Ahora rómpelo a propósito. Añade una tercera regla a la misma política que elimine una ruta que puede no existir:

   ```yaml
       - name: strip-debug-annotation
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchesJson6902: |-
             - op: remove
               path: "/metadata/annotations/debug.example.com~1enabled"
   ```

   Aplícala, crea un Pod **sin** esa anotación, y lee los eventos y el log del controlador:

   ```bash
   kubectl -n mutation-lab run no-anno --image=busybox:1.36 --restart=Never -- sleep 3600
   kubectl -n mutation-lab get events --field-selector reason=PolicyError -o wide | tail -5
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i -E 'remove|patch'
   ```

**Comprueba tu comprensión**

- **Q16.** En el paso 3, el strategic merge **reemplazó** la lista de tolerations en lugar de fusionarse con ella. ¿Qué propiedad del campo `tolerations` en el PodSpec de Kubernetes causa eso, y cómo lo habrías predicho a partir de `kubectl explain`?
- **Q17.** ¿Por qué el paso 4 necesita dos reglas con precondiciones espejo en lugar de un único `op: add` a `/spec/tolerations/-`?
- **Q18.** ¿Qué significa `~1` en `/metadata/annotations/debug.example.com~1enabled`, y qué significa `~0`? ¿Qué se rompe si omites el escape?
- **Q19.** En el paso 7, ¿qué le ocurrió al Pod — fue creado, rechazado, o creado sin mutar? Explica la interacción con el `failurePolicy` de la regla, y escribe la precondición que hace seguro el `remove`.
- **Q20.** El `add` de RFC 6902 sobre una clave de objeto que ya existe se comporta como `replace`. Describe el incidente en producción que esto provoca si el valor es una **lista** en vez de un escalar.
- **Q21.** Un JSON Patch añade una toleration con `/-`. La política coincide con `CREATE` **y** `UPDATE`. ¿Cómo se ve la plantilla de pod del Deployment tras diez ciclos de `kubectl edit`, y qué principio general se está violando?

---

## Ejercicio 4 — `foreach`: mutación por elemento con `element` y `elementIndex`

**Objetivo:** reescribir todas las imágenes de contenedor de un Pod, omitiendo las ya reescritas, y construir claves de anotación por contenedor.

1. Escribe `04-mirror.yaml`. El orden de las reglas importa — la regla 1 garantiza el objeto padre que necesita el JSON Pointer de la regla 2:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: mirror-registry
   spec:
     rules:
       - name: ensure-annotations-exist
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 +(mirror.example.com/policy): mirror-registry

       - name: rewrite-container-images
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.containers"
               preconditions:
                 all:
                   - key: "{{ starts_with(element.image, 'mirror.example.com/') }}"
                     operator: Equals
                     value: false
               patchStrategicMerge:
                 spec:
                   containers:
                     - name: "{{ element.name }}"
                       image: "mirror.example.com/{{ element.image }}"

       - name: record-rewritten-containers
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.containers"
               patchesJson6902: |-
                 - op: add
                   path: "/metadata/annotations/mirror.example.com~1{{ element.name }}"
                   value: "index-{{ elementIndex }}"
   ```

2. Aplícala y crea un Pod multicontenedor donde una imagen ya está replicada en el mirror:

   ```bash
   kubectl apply -f 04-mirror.yaml
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: multi
     namespace: mutation-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
       - name: sidecar
         image: mirror.example.com/fluent/fluent-bit:3.0
       - name: helper
         image: busybox:1.36
         command: ["sleep", "3600"]
   EOF
   ```

3. Lee el resultado:

   ```bash
   kubectl -n mutation-lab get pod multi \
     -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
   echo '---'
   kubectl -n mutation-lab get pod multi -o jsonpath='{.metadata.annotations}' | jq .
   ```

   ```
   app	mirror.example.com/nginx:1.27
   sidecar	mirror.example.com/fluent/fluent-bit:3.0
   helper	mirror.example.com/busybox:1.36
   ---
   {
     "mirror.example.com/app": "index-0",
     "mirror.example.com/helper": "index-2",
     "mirror.example.com/policy": "mirror-registry",
     "mirror.example.com/sidecar": "index-1"
   }
   ```

4. Comprueba el estado en ejecución del Pod:

   ```bash
   kubectl -n mutation-lab get pod multi
   ```

   ```
   NAME    READY   STATUS             RESTARTS   AGE
   multi   0/3     ErrImagePull       0          15s
   ```

5. Ahora prueba la lista que suele estar ausente. Crea un Pod **con** un initContainer y otro **sin** él, tras añadir una cuarta regla:

   ```yaml
       - name: rewrite-init-images
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         mutate:
           foreach:
             - list: "request.object.spec.initContainers"
               patchStrategicMerge:
                 spec:
                   initContainers:
                     - name: "{{ element.name }}"
                       image: "mirror.example.com/{{ element.image }}"
   ```

   ```bash
   kubectl apply -f 04-mirror.yaml
   kubectl -n mutation-lab run plain-again --image=nginx:1.27 --restart=Never
   kubectl -n mutation-lab get events --field-selector reason=PolicyError -o wide | tail -3
   ```

**Comprueba tu comprensión**

- **Q22.** El contenedor `sidecar` quedó intacto. ¿Qué construcción hizo eso, y por qué *no* es alcanzable con un ancla condicional de `patchStrategicMerge` sobre `image` en este caso?
- **Q23.** La regla 3 usa `/metadata/annotations/...` como JSON Pointer. ¿Qué le ocurriría a un Pod **sin** anotaciones si se borrara la regla 1? Nombra las dos formas de arreglarlo.
- **Q24.** El Pod está en `ErrImagePull`. ¿Falló la mutación? ¿Qué te dice esto sobre el alcance de lo que una regla de mutación puede y no puede verificar?
- **Q25.** En el paso 5, `request.object.spec.initContainers` está ausente en `plain-again`. ¿Qué hizo Kyverno, y cómo haces que el comportamiento sea explícito en vez de accidental?
- **Q26.** `foreach` admite un campo `order` (`Ascending` / `Descending`). Da una mutación concreta donde `Descending` sea obligatorio para que sea correcta.
- **Q27.** Reescribe la regla 2 para que elimine cualquier prefijo de registro existente en lugar de anteponerse a él (por ejemplo `quay.io/jetstack/cert-manager-controller:v1.14` → `mirror.example.com/jetstack/cert-manager-controller:v1.14`). ¿Qué función JMESPath de Kyverno necesitas?

---

## Ejercicio 5 — Mutar recursos **existentes**: `targets`, el background controller y RBAC

**Objetivo:** mutar objetos que ya existen, descubrir que no hace nada en silencio hasta que concedes RBAC, y arreglarlo.

1. Crea el disparador y el objetivo:

   ```bash
   kubectl -n mutation-lab create configmap app-config --from-literal=level=info
   kubectl -n mutation-lab create deployment web --image=nginx:1.27
   kubectl -n mutation-lab rollout status deploy/web
   ```

2. Escribe `05-mutate-existing.yaml`. El bloque `match` selecciona el **disparador**; `targets` selecciona lo que realmente se modifica:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: roll-deployment-on-config-change
   spec:
     mutateExistingOnPolicyUpdate: false
     rules:
       - name: stamp-config-revision
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
                 namespaces:
                   - mutation-lab
                 names:
                   - app-config
         mutate:
           targets:
             - apiVersion: apps/v1
               kind: Deployment
               name: web
               namespace: "{{ request.object.metadata.namespace }}"
           patchStrategicMerge:
             spec:
               template:
                 metadata:
                   annotations:
                     config.example.com/revision: "{{ request.object.metadata.resourceVersion }}"
   ```

3. Aplícala, y luego dispárala actualizando el ConfigMap:

   ```bash
   kubectl apply -f 05-mutate-existing.yaml
   kubectl -n mutation-lab create configmap app-config --from-literal=level=debug \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. Espera unos segundos y comprueba el objetivo. **No ha cambiado:**

   ```bash
   kubectl -n mutation-lab get deploy web \
     -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
   ```

   ```
   
   ```

5. Averigua por qué. Tres sitios donde mirar, en este orden:

   ```bash
   kubectl get updaterequests -A
   kubectl -n kyverno logs deploy/kyverno-background-controller --tail=50 | grep -i -E 'forbidden|denied|mutate'
   kubectl auth can-i update deployments \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n mutation-lab
   ```

   ```
   no
   ```

6. Concede el permiso de la forma en que Kyverno lo espera — un ClusterRole **agregado**, no una edición de los roles propios de Kyverno:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:mutate-deployments
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
     - apiGroups: ["apps"]
       resources: ["deployments"]
       verbs: ["get", "list", "watch", "update", "patch"]
   ```

   ```bash
   kubectl apply -f 05-rbac.yaml
   kubectl auth can-i update deployments \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n mutation-lab
   ```

   ```
   yes
   ```

7. Dispara de nuevo y verifica el despliegue:

   ```bash
   kubectl -n mutation-lab create configmap app-config --from-literal=level=warn \
     --dry-run=client -o yaml | kubectl apply -f -
   sleep 5
   kubectl -n mutation-lab get deploy web \
     -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
   kubectl -n mutation-lab rollout history deploy/web
   ```

   ```
   {"config.example.com/revision":"41283"}
   REVISION  CHANGE-CAUSE
   1         <none>
   2         <none>
   ```

8. Dispara una actualización *sin efecto* y confirma que no se despliega nada:

   ```bash
   kubectl -n mutation-lab annotate configmap app-config touched=1 --overwrite
   sleep 5
   kubectl -n mutation-lab rollout history deploy/web | tail -3
   ```

**Comprueba tu comprensión**

- **Q28.** ¿Qué componente de Kyverno ejecutó esta mutación, y por qué *no* es el admission controller? ¿Qué implica eso para `failurePolicy` y para la latencia entre disparador y efecto?
- **Q29.** El paso 5 mostró `can-i update deployments` → `no`, y sin embargo la actualización del ConfigMap tuvo éxito sin ninguna advertencia. Explica el modo de fallo y por qué es peligroso en producción.
- **Q30.** ¿Por qué el ClusterRole lleva la etiqueta `rbac.kyverno.io/aggregate-to-background-controller` en lugar de añadirse directamente al ClusterRole que Kyverno trae de fábrica?
- **Q31.** `spec.mutateExistingOnPolicyUpdate` está en `false` aquí. ¿Qué cambia si lo pones en `true`, y cuál es el radio de impacto la primera vez que la política se aplica a un clúster con 4 000 Deployments?
- **Q32.** En el paso 8 la anotación fue modificada pero no apareció ningún despliegue nuevo — ¿o sí? Predice el resultado y explícalo en términos de `resourceVersion`, y luego reconcilia tu predicción con lo que realmente observaste.
- **Q33.** Dentro de una regla de mutación de existentes, `{{ request.object.* }}` y `{{ target.* }}` se refieren a objetos distintos. ¿Cuál es cuál, y escribe el parche que copia el `metadata.labels.env` del ConfigMap disparador al Deployment objetivo solo cuando el objetivo aún no tiene esa etiqueta.
- **Q34.** ¿Puede una regla de mutación de existentes usar `{{ request.userInfo.username }}`? Justifica tu respuesta usando el Ejercicio 1.

---

## Ejercicio 6 — Auto-gen: qué ocurre con las reglas de mutación que coinciden con Pod en los controladores

**Objetivo:** ver las reglas que Kyverno escribe por ti, y entender dónde aterriza la mutación.

1. Inspecciona las reglas generadas para la política del Ejercicio 1:

   ```bash
   kubectl get clusterpolicy add-owner-metadata -o jsonpath='{.status.autogen.rules[*].name}{"\n"}'
   ```

   ```
   autogen-add-team-and-creator autogen-cronjob-add-team-and-creator
   ```

2. Observa cómo fue reescrita la ruta del parche:

   ```bash
   kubectl get clusterpolicy add-owner-metadata -o yaml \
     | sed -n '/autogen/,$p' | head -40
   ```

3. Crea un Deployment e inspecciona **ambos** niveles:

   ```bash
   kubectl -n mutation-lab create deployment auto --image=nginx:1.27
   sleep 3
   echo "== Deployment pod template labels"
   kubectl -n mutation-lab get deploy auto -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
   echo "== Pod labels"
   kubectl -n mutation-lab get pods -l app=auto -o jsonpath='{.items[0].metadata.labels}{"\n"}'
   ```

4. Desactiva autogen y repite:

   ```bash
   kubectl annotate clusterpolicy add-owner-metadata \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl -n mutation-lab create deployment auto2 --image=nginx:1.27
   sleep 3
   kubectl -n mutation-lab get deploy auto2 -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
   kubectl -n mutation-lab get pods -l app=auto2 -o jsonpath='{.items[0].metadata.labels}{"\n"}'
   ```

5. Restaura autogen:

   ```bash
   kubectl annotate clusterpolicy add-owner-metadata \
     pod-policies.kyverno.io/autogen-controllers- 
   ```

**Comprueba tu comprensión**

- **Q35.** Con autogen **desactivado**, el Pod aún recibió `team=platform` pero la plantilla de pod del Deployment no. Explica por qué, y describe el síntoma en Argo CD / Flux que esto crea.
- **Q36.** ¿Bajo qué ruta envuelve autogen un `patchStrategicMerge` a nivel de Pod para un `Deployment`? ¿Y para un `CronJob`?
- **Q37.** Da una mutación que sea **incorrecta** de autogenerar — una en la que aplicarla a nivel de controlador cambie el significado — y cómo la restringirías.
- **Q38.** La política del Ejercicio 1 tiene `background: false`. ¿Se le aplica autogen igualmente? ¿Qué comportamientos de Kyverno desactiva realmente `background: false`?

---

## Ejercicio 7 — Verificar mutaciones sin clúster: `kyverno apply` y `kyverno test`

**Objetivo:** poner las mutaciones bajo CI, que es como se mantienen en plataformas reales.

1. Crea un fixture de recurso `resources/pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
     namespace: mutation-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ```

2. Ejecuta la política del Ejercicio 2 contra él, sin conexión:

   ```bash
   kyverno apply 02-anchors.yaml --resource resources/pod.yaml
   ```

   ```
   Applying 3 policy rule(s) to 1 resource(s)...

   mutate policy anchor-semantics applied to mutation-lab/Pod/web:
   apiVersion: v1
   kind: Pod
   metadata:
     labels:
       tier: backend
     name: web
     namespace: mutation-lab
   spec:
     containers:
     - image: nginx:1.27
       imagePullPolicy: Never
       name: app
   ---

   pass: 1, fail: 0, warn: 0, error: 0, skip: 2
   ```

3. Compara esa salida con lo que produjo el clúster en el Ejercicio 2, paso 4, y explica la diferencia.

4. Escribe el artefacto esperado `resources/pod-patched.yaml` a partir de la salida de la CLI, y luego un manifiesto de test `kyverno-test.yaml`:

   ```yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: anchor-semantics-test
   policies:
     - 02-anchors.yaml
   resources:
     - resources/pod.yaml
   results:
     - policy: anchor-semantics
       rule: default-tier-label-if-absent
       resources:
         - mutation-lab/web
       kind: Pod
       result: pass
       patchedResources: resources/pod-patched.yaml
   ```

5. Ejecútalo:

   ```bash
   kyverno test .
   ```

   ```
   Loading test  ( ./kyverno-test.yaml ) ...
     Loading values/variables ...
     Loading policies ...
     Loading resources ...
     Applying 3 policy rule(s) to 1 resource(s) ...
     Checking results ...

   │ ID │ POLICY            │ RULE                          │ RESOURCE             │ RESULT │
   │ 1  │ anchor-semantics  │ default-tier-label-if-absent  │ Pod/mutation-lab/web │ Pass   │

   Test Summary: 1 tests passed and 0 tests failed
   ```

6. Rompe el fixture — cambia `tier: backend` por `tier: frontend` en `pod-patched.yaml` — y vuelve a ejecutar para ver el diff que imprime la CLI.

**Comprueba tu comprensión**

- **Q39.** La CLI produjo `imagePullPolicy: Never`; el clúster real produjo `IfNotPresent`. ¿Cuál es la "correcta", y qué te enseña la discrepancia sobre lo que `kyverno apply` *no* simula?
- **Q40.** ¿Por qué `patchedResources` es el campo más valioso de un test de mutación, comparado con simplemente afirmar `result: pass`?
- **Q41.** Tu política usa `{{ request.userInfo.username }}`. ¿Cómo haces que `kyverno test` sea determinista para ella?
- **Q42.** ¿Qué código de salida devuelve `kyverno test` en caso de fallo, y cuál es la barrera mínima de CI que construirías a partir de los Ejercicios 2–4?

---

## Ejercicio 8 — Diagnosticar una mutación que nunca se dispara

**Objetivo:** un orden de triaje repetible. Trabaja de arriba abajo; cada paso elimina una clase de causa.

1. Reproduce un fallo. Crea un Pod en un namespace excluido:

   ```bash
   kubectl -n kube-system run probe --image=nginx:1.27 --restart=Never
   kubectl -n kube-system get pod probe -o jsonpath='{.metadata.labels}{"\n"}'
   kubectl -n kube-system delete pod probe
   ```

2. **¿Está la política admitida y lista?**

   ```bash
   kubectl get cpol -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MSG:.status.conditions[?(@.type=="Ready")].message'
   ```

3. **¿Está el webhook registrado para ese tipo?**

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{.webhooks[*].rules}' | jq '.[].resources'
   ```

4. **¿Está el recurso filtrado?**

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | grep -i -E 'kube-system|kyverno'
   ```

5. **¿Coincidió la regla pero se omitió?** Las precondiciones y las anclas producen `skip`, no `fail`:

   ```bash
   kubectl -n mutation-lab get events \
     --field-selector 'reason=PolicySkipped' -o custom-columns='OBJ:.involvedObject.name,MSG:.message'
   ```

6. **¿Dio error la regla?**

   ```bash
   kubectl -n mutation-lab get events --field-selector 'reason=PolicyError' -o wide
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i -E 'error|failed'
   ```

7. **Repítelo sin conexión** con el objeto exacto del clúster:

   ```bash
   kubectl -n mutation-lab get pod multi -o yaml > /tmp/live.yaml
   kyverno apply 04-mirror.yaml --resource /tmp/live.yaml
   ```

**Comprueba tu comprensión**

- **Q43.** Ordena estas cuatro causas de la más barata a la más cara de descartar: exclusión por `resourceFilters`; `failurePolicy: Ignore` tragándose un error del webhook; una precondición JMESPath que evalúa a falso; un webhook no registrado para ese tipo.
- **Q44.** En el paso 7, meter un objeto **vivo** de vuelta en `kyverno apply` puede producir un resultado distinto al de la admisión. Da dos razones.
- **Q45.** Una regla de mutación funciona con `kubectl apply` pero no con objetos creados por un controlador. Enumera tres explicaciones distintas y el comando que distingue cada una.
- **Q46.** `failurePolicy: Fail` en una regla de mutación hace que los errores sean ruidosos. ¿Por qué es peligroso para una regla que coincide con `Pod` en todo el clúster, y cuál es la mitigación estándar?

---

## Ejercicio 9 — Orden: la mutación alimenta a la validación

**Objetivo:** confirmar el límite entre fases que hace de "mutar para corregir, validar para exigir" un patrón de plataforma viable.

1. Añade una política de validación que exija la etiqueta que inyecta el Ejercicio 1:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: check-team
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [mutation-lab]
         validate:
           message: "Pods must carry a 'team' label."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   *(En Kyverno 1.10 y anteriores el campo es `spec.validationFailureAction`; las versiones más nuevas lo sitúan bajo `spec.rules[].validate.failureAction` — comprueba `kubectl explain clusterpolicy.spec`.)*

2. Aplícala y crea un Pod **sin** etiqueta `team`:

   ```bash
   kubectl apply -f 09-validate.yaml
   kubectl -n mutation-lab run ordering-a --image=nginx:1.27 --restart=Never
   ```

   ```
   pod/ordering-a created
   ```

3. Ahora estrecha la política de *mutación* para que ya no coincida con este Pod, y reintenta:

   ```bash
   kubectl patch clusterpolicy add-owner-metadata --type=json \
     -p='[{"op":"add","path":"/spec/rules/0/match/any/0/resources/selector","value":{"matchLabels":{"mutate":"yes"}}}]'
   kubectl -n mutation-lab run ordering-b --image=nginx:1.27 --restart=Never
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/mutation-lab/ordering-b was blocked due to the following policies

   require-team-label:
     check-team: 'validation error: Pods must carry a ''team'' label. rule check-team
       failed at path /metadata/labels/team/'
   ```

4. Revierte:

   ```bash
   kubectl patch clusterpolicy add-owner-metadata --type=json \
     -p='[{"op":"remove","path":"/spec/rules/0/match/any/0/resources/selector"}]'
   ```

**Comprueba tu comprensión**

- **Q47.** `ordering-a` fue creado aunque el usuario nunca proporcionó una etiqueta `team`. ¿Qué dos configuraciones de webhook estuvieron implicadas, y en qué orden las llamó el servidor de API?
- **Q48.** ¿Cambiaría el resultado si la regla de mutación y la de validación vivieran en la **misma** ClusterPolicy? ¿Y si vivieran en dos políticas cuyos nombres ordenan al revés?
- **Q49.** Un equipo de plataforma quiere "ponerle un valor por defecto si falta, rechazarlo si está mal". Esboza el diseño de dos reglas e indica qué regla **no** debe usar `+()`.
- **Q50.** Las mutaciones de Kyverno son invisibles para quien escribió el manifiesto original. Nombra los dos mecanismos que hacen auditable una mutación aplicada a posteriori.

---

## Limpieza

```bash
kubectl delete clusterpolicy add-owner-metadata anchor-semantics batch-toleration \
  mirror-registry roll-deployment-on-config-change require-team-label --ignore-not-found
kubectl delete clusterrole kyverno:mutate-deployments --ignore-not-found
kubectl delete namespace mutation-lab
kubectl get updaterequests -A
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A1.** Kyverno configura sus webhooks de recursos **dinámicamente** a partir del conjunto de políticas instaladas (`autoUpdateWebhooks`, activado por defecto). Sin ninguna política de mutación presente, no hay nada que interceptar, así que el webhook de mutación de recursos no lleva reglas — Kyverno evita deliberadamente situarse en la ruta de admisión para tráfico con el que no tiene trabajo. Aplicar la primera política de mutación para un tipo hace que Kyverno añada una regla para ese tipo, normalmente en pocos segundos. El `kyverno-policy-mutating-webhook-cfg` estático es distinto: siempre intercepta los propios objetos `ClusterPolicy`/`Policy` (es lo que aplica valores por defecto y valida tus políticas, y lo que rechazó la política del Ejercicio 1).

**A2.** El **admission controller** atiende tanto el webhook de mutación como el de validación de recursos. El **background controller** realiza el trabajo de mutación de existentes y de generación de forma asíncrona y no está en la ruta de admisión. El **reports controller** construye los objetos `PolicyReport`/`ClusterPolicyReport`; el **cleanup controller** atiende `CleanupPolicy`. Solo el admission controller puede bloquear o alterar una petición en vuelo.

**A3.** `resourceFilters` en el ConfigMap `kyverno` del namespace `kyverno`. Cada entrada es `[kind,namespace,name]`, se admiten comodines, y las entradas van concatenadas: `[Event,*,*][*,kube-system,*][*,kyverno,*]…`. Todo lo que coincida queda excluido de **todo** el procesamiento antes de que se evalúe cualquier política — así que no hay evento, ni informe, ni línea de log. El conjunto por defecto excluye `kube-system`, `kube-public`, `kube-node-lease`, el propio namespace de Kyverno y tipos de alta rotación como `Event`, `Node`, `Lease`, `TokenReview`. Esta es la causa más común de "mi política es ignorada" y es invisible desde el lado de la política.

**A4.** Depende de `spec.rules[].failurePolicy` (por defecto `Fail`). Con `Fail`, el servidor de API no puede alcanzar el webhook y **rechaza la petición** — una caída de Kyverno se convierte en una caída de creación de cargas de trabajo en todo el clúster. Con `Ignore`, la petición continúa sin mutar, lo cual está disponible pero silenciosamente sin aplicar. Por eso las instalaciones de producción ejecutan el admission controller con ≥3 réplicas, un PodDisruptionBudget y `kube-system` excluido.

### Ejercicio 1

**A5.** `background: true` (el valor por defecto) permite a Kyverno evaluar la política durante los **escaneos en segundo plano** periódicos de recursos existentes, donde no hay ningún AdmissionRequest. `request.userInfo`, `request.operation`, `request.roles` y compañía existen solo en un contexto de admisión, así que una política que los referencia no puede evaluarse en modo background. El propio webhook de validación de políticas de Kyverno rechaza esa combinación en el momento de aplicarla, en lugar de dejar que falle en silencio durante el escaneo. Poner `background: false` desactiva los escaneos en segundo plano y los informes de política para esa política — entonces solo se aplica en admisión.

**A6.** Los **valores** de etiqueta de Kubernetes están restringidos a alfanuméricos, `-`, `_`, `.`, con un máximo de 63 caracteres. Un nombre de usuario de ServiceAccount es `system:serviceaccount:<ns>:<name>` — los dos puntos son ilegales. Un Pod creado por un controlador de ReplicaSet sería mutado hasta convertirse en un objeto inválido y rechazado por la validación de la API *después* de la fase de mutación, así que el Deployment deja de producir Pods con un mensaje que apunta a la etiqueta, no a Kyverno. Los valores de **anotación** no tienen esa restricción de caracteres, y por eso los datos de identidad/procedencia pertenecen ahí.

**A7.** Kyverno reescribió `kyverno-resource-mutating-webhook-cfg` para interceptar Pods. Operativamente: la primera política de mutación para un tipo pone a Kyverno en la ruta crítica de **cada** creación/actualización de ese tipo en todo el clúster, sujeto al `failurePolicy` y a las exclusiones de namespace. Por tanto, añadir una política de alcance estrecho no es un cambio de alcance estrecho — acótala más con `namespaceSelector`/`objectSelector` en la política para que Kyverno también acote el webhook.

**A8.** (1) Un controlador de GitOps compara el manifiesto deseado con el objeto vivo y reporta desviación permanente / `OutOfSync`; (2) un bucle agresivo de auto-reparación puede pelearse con el webhook, reaplicando y siendo re-mutado en un bucle caliente. Cómo evitarlo: mutar también el objeto **controlador** (autogen, Ejercicio 6) para que la especificación almacenada coincida, o configurar la herramienta de GitOps para que ignore los campos mutados (`ignoreDifferences` de Argo CD, `spec.patches`/exclusiones de detección de desviación de Flux). El principio general: muta tan arriba en la cadena de propiedad como puedas.

**A9.** No. `patchStrategicMerge` crea los mapas padre que faltan a medida que fusiona. `patchesJson6902` sigue RFC 6902 estrictamente: `add` exige que el contenedor padre exista, y `remove`/`replace` exigen que el propio objetivo exista. Esa asimetría es el Ejercicio 3.

### Ejercicio 2

**A10.** `+(key): value` establece `key` a `value` **solo si `key` está ausente**; si está presente, el valor existente se deja intacto y el resto del parche continúa. Es "ponerle un valor por defecto", no "imponerlo".

**A11.** Porque el servidor de API de Kubernetes aplica los **valores por defecto durante la decodificación, antes de que se ejecuten los webhooks de admisión**. `SetDefaults_Container` rellena `imagePullPolicy` con `Always` para imágenes `:latest`/sin etiqueta y con `IfNotPresent` en el resto de casos. Para cuando el webhook de Kyverno ve el objeto, el campo ya está poblado, así que `+()` correctamente lo encuentra presente y no hace nada. La lección general: un webhook de mutación nunca puede distinguir "el usuario omitió esto" de "el servidor de API le puso el valor por defecto", así que `+()` solo tiene sentido en campos para los que la API **no tiene valor por defecto** — etiquetas, anotaciones, campos de recursos personalizados, `nodeSelector`, `tolerations`, subcampos de `securityContext` que sean genuinamente anulables. Confirma siempre las anclas empíricamente con un valor centinela que el servidor de API nunca elegiría, exactamente como hizo este ejercicio con `Never`.

**A12.** `(name): "*"` es un **ancla condicional**: "para cada elemento de la lista, si `name` coincide con el patrón `*`, aplica las claves hermanas de este mapa a ese elemento; si no, omite el elemento". Es un selector, no datos — nunca se escribe en el objeto. Sin paréntesis, `name: "*"` son datos: el strategic merge intentaría hacer coincidir/crear un contenedor literalmente llamado `*`, produciendo un contenedor adicional espurio.

**A13.** El ancla condicional coincide con la **cadena literal** de `spec.containers[].image`, y `nginx` no termina en `:latest`. La equivalencia *semántica* de `nginx` y `nginx:latest` en Kubernetes la aplica el kubelet / la lógica de valores por defecto, no la coincidencia de cadenas. Para cubrir ambos casos, o bien usa dos reglas (`"*:latest"` y un `foreach` con la precondición `contains(element.image, ':') == false`), o pásate a `foreach` + JMESPath para poder expresar "sin etiqueta O etiqueta == latest" en una sola precondición. Nota que `*:latest` también coincide correctamente con `myrepo/latest-thing:latest`, pero *no* coincidiría con una referencia fijada por digest — que es el comportamiento deseado, ya que los digests son inmutables.

**A14.** Dentro de una misma política, las reglas se ejecutan **en el orden en que están declaradas**, y una regla posterior ve el objeto tal y como lo mutaron las reglas anteriores — ese orden está garantizado y es exactamente en lo que se apoyan las reglas 2 y 3. Entre políticas **separadas**, no te fíes del orden: varias políticas se aplican en una sola invocación del webhook, pero la secuencia es un detalle de implementación y puede cambiar entre versiones. Diseña las mutaciones entre políticas para que sean conmutativas e idempotentes, o consolida las mutaciones conflictivas del mismo campo en una única política donde controles el orden explícitamente.

**A15.** Anclas exclusivas de validate: **igualdad** `=()` (si la clave existe, su valor debe coincidir), **existencia** `^()` (al menos un elemento del array debe coincidir) y **negación** `X()` (la clave no debe existir). El **ancla global** `<()` se evalúa contra el recurso en su conjunto en lugar de contra el nodo en el que está escrita: si su condición no se satisface, la regla entera se omite. La condicional `()` y la de añadir-si-no-está-presente `+()` son las dos que importan para la mutación, y `+()` es exclusiva de mutate.

### Ejercicio 3

**A16.** `tolerations` es una **lista atómica** en el PodSpec — no lleva `patchMergeKey`, así que el strategic merge no tiene forma de identificar "el mismo" elemento y reemplaza la lista entera. Puedes verlo en `kubectl explain pod.spec.tolerations` / el esquema OpenAPI (`x-kubernetes-list-type: atomic`, y la ausencia de `x-kubernetes-patch-merge-key`). Compáralo con `spec.containers`, que tiene `patchMergeKey: name` y por tanto se fusiona por contenedor — que es por lo que cada parche de contenedor en estos ejercicios especifica `name`. **Regla práctica: antes de escribir un parche de strategic merge contra una lista, comprueba si esa lista tiene una clave de fusión. Si no la tiene, strategic merge significa "reemplazar".**

**A17.** El `add` de RFC 6902 con el token `-` añade al final de un array **existente**. Si `/spec/tolerations` está ausente, el padre de la ruta no existe y el parche es inválido — la regla da error en lugar de crear la lista. La forma de dos reglas con precondiciones espejo es el modismo estándar de Kyverno: una regla crea la lista, la otra añade a ella, y las precondiciones garantizan que se ejecute exactamente una de las dos.

**A18.** JSON Pointer (RFC 6901) usa `/` como separador de segmentos, así que un `/` literal dentro de una clave se escapa como `~1`, y un `~` literal como `~0` (decodifica `~1` primero, luego `~0`). Si omites el escape, `debug.example.com/enabled` se interpreta como dos segmentos — `debug.example.com` y luego `enabled` — que no existen, así que la operación falla o, peor, apunta silenciosamente al nodo equivocado. Toda clave de anotación y etiqueta con un prefijo de dominio necesita esto.

**A19.** El Pod **se crea**, y la regla reporta un error en lugar de una mutación: `remove` sobre una ruta inexistente es inválido según RFC 6902, así que Kyverno no puede producir un parche. Con `failurePolicy: Fail` esta clase de error aparece como una petición rechazada en las versiones que lo propagan; con `Ignore` queda tragado y solo lo ves en el evento `PolicyError` y en el log del controlador. En cualquier caso, la corrección adecuada no es apoyarse en el modo de fallo, sino proteger la operación:

```yaml
preconditions:
  all:
    - key: "{{ request.object.metadata.annotations || '{}' | keys(@) | contains(@, 'debug.example.com/enabled') }}"
      operator: Equals
      value: true
```

Confirma el comportamiento exacto en tu versión de Kyverno — esta es precisamente la clase de semántica de borde que ha cambiado entre versiones, y por eso la respuesta es la precondición, no el manejo del error.

**A20.** `add` sobre una clave existente la sobrescribe por completo. Si el valor es una lista — `tolerations`, `imagePullSecrets`, `env`, `volumes` — el parche destruye entradas que el propietario de la carga de trabajo estableció deliberadamente, y lo hace en silencio, en la admisión, sin mostrar ningún diff al usuario. Ese es exactamente el incidente reproducido en el paso 3: una toleration de GPU desapareció, el Pod se volvió no planificable en los nodos con taint para los que fue escrito, y nada en el propio manifiesto del Pod explica por qué.

**A21.** Diez tolerations idénticas de más, una por actualización. `add … /-` **no es idempotente**, y las reglas de mutación se ejecutan tanto en `UPDATE` como en `CREATE` por defecto. El principio: *una mutación debe converger a un punto fijo*. Imponlo bien restringiendo la regla con `match.any[].resources.operations: [CREATE]` — recordando que eso deja las actualizaciones sin control — o, mejor, haciendo el parche autocomprobable con una precondición de que el elemento deseado no está ya presente. El strategic merge sobre una lista con clave de fusión es idempotente por naturaleza; el append de JSON Patch nunca lo es.

### Ejercicio 4

**A22.** Las **`preconditions`** de la entrada `foreach`, evaluadas por elemento contra `{{ element }}`. Un ancla condicional de `patchStrategicMerge` solo puede expresar "coincide con este glob"; aquí el requisito es la **negación** de una prueba de prefijo, más la reutilización del propio valor del elemento para construir el nuevo. Las precondiciones te dan el lenguaje de expresiones JMESPath completo por elemento, y `{{ element.image }}` te da el valor antiguo para transformarlo — ninguna de las dos cosas está disponible para un ancla desnuda.

**A23.** Sin la regla 1, `/metadata/annotations` no existe en un Pod que no tenga ninguna, así que `op: add` a `/metadata/annotations/<key>` falla con un error de padre inexistente. Soluciones: (a) mantener una regla previa de `patchStrategicMerge` que cree el mapa — el strategic merge crea los padres que faltan, que es por lo que la regla 1 va primero; o (b) expresar todo con `patchStrategicMerge` interpolando `"{{ element.name }}"` dentro de la clave de anotación. El orden de las reglas dentro de una política es lo que hace fiable la opción (a).

**A24.** La mutación tuvo éxito por completo — el servidor de API aceptó una especificación de Pod sintácticamente válida. `ErrImagePull` ocurre después, en el kubelet, porque `mirror.example.com` no existe. Una regla de mutación cambia el estado deseado; no verifica, ni puede verificar, que el estado resultante sea *ejecutable*. Las políticas de reescritura de registro deben por tanto ir emparejadas con un entorno donde el mirror realmente resuelva, y desplegarse detrás de un selector de namespace — una política de reescritura mal hecha aplicada a todo el clúster rompe todas las descargas de imagen del clúster a la vez, incluida la del propio Kyverno si alguna vez reinicia.

**A25.** `request.object.spec.initContainers` resuelve a null, el `foreach` itera sobre nada, y la regla es un no-op — sin error, sin evento. Apoyarse en eso es frágil: hazlo explícito con `list: "request.object.spec.initContainers || []"`, o añade una precondición a nivel de regla que afirme que la clave existe (`keys(@) | contains(@, 'initContainers')`). Explícito es mejor porque una *errata* en la expresión de la lista también resuelve silenciosamente a null — un `foreach` sin protección no puede distinguir "vacío" de "ruta equivocada".

**A26.** Cualquier mutación que **elimine** elementos de una lista por índice, p. ej. `patchesJson6902` con `op: remove, path: /spec/containers/{{ elementIndex }}` para quitar sidecars. Eliminar en orden ascendente desplaza cada índice posterior una posición hacia abajo, así que la segunda eliminación golpea al elemento equivocado. `order: Descending` elimina desde la cola primero, manteniendo estables los índices de los elementos aún no procesados.

**A27.** Usa `regex_replace_all_literal` para reemplazar el componente de registro:

```yaml
image: "{{ regex_replace_all_literal('^[^/]+\\.[^/]+/', '{{ element.image }}', 'mirror.example.com/') }}"
```

La variante literal no expande grupos de captura en el reemplazo, que es lo que quieres aquí. La expresión regular exige un punto en el primer segmento para que los nombres cortos de Docker Hub (`nginx:1.27`, `library/nginx`) no se confundan con registros — trátalos con una segunda regla o una precondición, ya que necesitan que se les *añada* un prefijo en vez de reemplazarlo. Verifica la expresión con `kyverno jp query` antes de ponerla en producción.

### Ejercicio 5

**A28.** El **background controller**. La mutación de existentes no es una operación de admisión: se observa el disparador, se crea un `UpdateRequest`, y el controlador lo reconcilia emitiendo un `UPDATE` contra el objetivo a través del servidor de API con su propia ServiceAccount. Consecuencias: `failurePolicy` es irrelevante (no hay ninguna petición en vuelo que pueda fallar), el efecto es **eventualmente** consistente con un retraso de segundos o más, y los fallos solo aparecen como eventos, en el estado del `UpdateRequest` y en los logs del controlador. También significa que la regla necesita `background` habilitado y no puede usar variables exclusivas de admisión.

**A29.** El disparador tuvo éxito porque el disparador no es la cosa que se muta — la escritura del ConfigMap nunca estuvo en duda. La actualización del objetivo falló después, en un controlador distinto, con `403 Forbidden`. El peligro es que se trata de un **fallo silencioso de política**: desde la perspectiva del usuario, todo funcionó; el control de seguridad u operativo que la política codifica simplemente no ocurrió. Toda política de mutación de existentes debe ir acompañada de una alerta sobre la tasa de error del background controller o sobre objetos `UpdateRequest` atascados en estado fallido.

**A30.** Porque los ClusterRoles que Kyverno trae de fábrica los gestiona su chart de Helm / manifiesto de instalación y se sobrescriben en las actualizaciones — cualquier edición directa se pierde en el siguiente `helm upgrade`. Los roles de Kyverno son roles **agregados**; añadir un ClusterRole etiquetado con `rbac.kyverno.io/aggregate-to-background-controller: "true"` injerta tus reglas a través del controlador de agregación y sobrevive a las actualizaciones. Existen etiquetas hermanas para los controladores de admisión, informes y limpieza. Este es también el lugar correcto para aplicar mínimo privilegio: concede `update`/`patch` exactamente sobre los tipos a los que apuntan tus políticas, nunca `*`.

**A31.** Con `mutateExistingOnPolicyUpdate: true`, la regla también se dispara siempre que la **propia política** se crea o actualiza, así que Kyverno rellena retroactivamente todos los objetivos coincidentes en lugar de esperar a un disparador. Sobre 4 000 Deployments eso significa 4 000 llamadas `UPDATE` encoladas a través del background controller — carga en el servidor de API, una avalancha en el log de auditoría y, dado que este parche en concreto toca `spec.template`, **4 000 reinicios rodantes simultáneos**. Despliega estas políticas primero con el flag en `false`, verifica con un disparador, y solo entonces decide si el relleno retroactivo es seguro; si lo es, escalónalo por namespace.

**A32.** La anotación `touched=1` cambia el `resourceVersion` del ConfigMap, así que la regla se dispara y escribe un valor de revisión *nuevo* en la plantilla de pod — lo cual **sí** dispara un despliegue. Ese es el modo de fallo de usar `resourceVersion` como clave de revisión: cambia con cada escritura al ConfigMap, incluidas las escrituras que no alteran los datos que tu carga de trabajo consume. La clave apta para producción es un hash **solo de los datos**:

```yaml
config.example.com/revision: "{{ request.object.data | to_string(@) | sha256(@) }}"
```

Ahora una edición solo de metadatos produce el mismo hash, el parche es un no-op y no ocurre ningún despliegue. Si tu observación difirió de tu predicción, esa diferencia es la lección — las reglas de mutación de existentes que tocan `spec.template` son disparadores de despliegue, y su idempotencia debe diseñarse, no asumirse.

**A33.** `{{ request.object.* }}` es el **disparador** (el ConfigMap que cambió); `{{ target.* }}` es el **objeto que se está mutando** (el Deployment). Copia condicionalmente con un ancla de añadir-si-no-está-presente:

```yaml
patchStrategicMerge:
  metadata:
    labels:
      +(env): "{{ request.object.metadata.labels.env }}"
```

`+()` hace que la regla converja: una vez que el objetivo tiene una etiqueta `env`, los disparadores posteriores son no-ops.

**A34.** No. La mutación de existentes se ejecuta en el background controller, que requiere `background: true`, y `background: true` prohíbe `request.userInfo` — la misma validación que rechazó la política en el Ejercicio 1, paso 2. No hay ninguna petición de admisión detrás de una mutación en segundo plano, así que no hay ningún usuario al que atribuirla; el actor en el log de auditoría es la propia ServiceAccount de Kyverno.

### Ejercicio 6

**A35.** Autogen solo reescribe la política; la regla original a nivel de Pod permanece siempre, y se dispara cuando el controlador de ReplicaSet envía el Pod. Así que el Pod se muta en cualquier caso — pero con autogen desactivado, el `spec.template` almacenado del Deployment nunca gana la etiqueta. El síntoma en GitOps es el *inverso* del de Q8: con autogen **activado**, el Deployment vivo difiere de Git y la herramienta reporta desviación; con autogen **desactivado**, el Deployment coincide con Git pero los Pods en ejecución llevan campos que ningún manifiesto declara, así que `kubectl get deploy -o yaml` no te da forma de explicar cómo son los Pods. Elige deliberadamente, y si eliges autogen, excluye las rutas mutadas en tu herramienta de GitOps.

**A36.** Para `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController` y `Job`, el parche a nivel de Pod se envuelve bajo `spec.template` (así que `metadata.labels` se convierte en `spec.template.metadata.labels`). Para `CronJob` se envuelve bajo `spec.jobTemplate.spec.template`. Puedes leer el resultado generado literalmente en `status.autogen.rules`, que es la respuesta autoritativa para tu versión — nunca lo adivines.

**A37.** Cualquier cosa cuyo significado sea posicional en vez de declarativo — por ejemplo una regla que inyecta un valor efímero, por Pod, como un token de arranque, una pista de planificación derivada de `request.object.metadata.name`, o una anotación que debe diferir por réplica. Escrito en `spec.template`, cada réplica recibe el valor idéntico y cada cambio de plantilla dispara un despliegue. Restríngelo con la anotación `pod-policies.kyverno.io/autogen-controllers: none` (solo Pod) o con un subconjunto como `Deployment,StatefulSet`.

**A38.** Sí, autogen es independiente de `background` — es un paso de reescritura de política, no un escaneo. `background: false` desactiva el escaneo periódico en segundo plano de recursos existentes y los informes de política resultantes para esa política; **no** afecta a la evaluación en tiempo de admisión, ni a autogen, ni al registro del webhook.

### Ejercicio 7

**A39.** Ambos son "correctos" para lo que miden. `kyverno apply` evalúa políticas contra el YAML que le entregas, **sin ningún servidor de API en el circuito**: sin valores por defecto, sin cadena de admisión, sin otros webhooks, sin contexto de clúster vivo. El `IfNotPresent` del clúster vino del establecimiento de valores por defecto del servidor de API (A11), que la CLI no simula. Consecuencias que interiorizar: la CLI no puede decirte si un ancla `+()` se disparará realmente sobre un campo con valor por defecto, no puede resolver entradas de `context` que consultan la API en vivo a menos que le proporciones valores, y no puede mostrar la interacción con otros webhooks de mutación. Es un test unitario de política, no un test de integración.

**A40.** `result: pass` solo afirma que la regla *se ejecutó*; una mutación que produjo el valor equivocado igualmente pasa. `patchedResources` afirma el **objeto resultante exacto**, así que detecta un ancla cambiada, una expresión JMESPath rota, un JSON Pointer con error de una unidad, o una regresión introducida al reordenar reglas. Para las reglas de mutación es la aserción que realmente tiene dientes.

**A41.** Proporciona un fichero de valores (`--values values.yaml` / la clave `variables:` en el manifiesto Test) que fije `request.userInfo`, `request.operation` y cualquier consulta de `context` a valores fijos, y súbelo al repositorio junto a los fixtures. Sin él la variable queda sin resolver y el resultado del test depende del comportamiento de respaldo de la CLI en lugar de tu política.

**A42.** Distinto de cero en caso de fallo — que es lo que lo hace utilizable como barrera. La barrera mínima de CI: ejecutar `kyverno test ./policies/...` en cada PR que toque una política, con un par de fixtures (`resource.yaml` + `patched.yaml`) por cada rama de cada regla — incluyendo los casos *negativos* (`result: skip` cuando una precondición excluye el recurso). Añade `kyverno apply --resource` contra un directorio de objetos reales exportados del clúster como prueba de humo antes de promover una política desde staging.

### Ejercicio 8

**A43.** Del más barato al más caro: (1) **webhook no registrado para el tipo** — un `kubectl get mutatingwebhookconfiguration`, inequívoco; (2) **exclusión por `resourceFilters`** — una lectura de ConfigMap, inequívoco; (3) **precondición falsa** — visible como un evento `PolicySkipped` o reproducible sin conexión con `kyverno apply` sobre el objeto vivo; (4) **`failurePolicy: Ignore` tragándose un error** — el más caro, porque por construcción deja la menor evidencia en la ruta de la petición; necesitas los logs del controlador, correlacionados por marca de tiempo, y posiblemente `--dumpPayload`.

**A44.** (1) El objeto vivo ha pasado por los valores por defecto, otros webhooks de mutación y la propia estrategia del servidor de API, así que no es el objeto que Kyverno vio en la admisión — en particular, puede que ya contenga la mutación, haciendo que una regla idempotente parezca un no-op. (2) La CLI no tiene ningún `AdmissionRequest`, así que `request.operation`, `request.userInfo` y cualquier llamada a la API de `context` resuelven de forma distinta o no resuelven en absoluto. Exporta el objeto, elimina `status`, `metadata.managedFields`, `metadata.uid`, `metadata.resourceVersion` y `metadata.creationTimestamp`, y proporciona las variables explícitamente antes de sacar conclusiones.

**A45.** (1) **El namespace del controlador está excluido** por `resourceFilters` — revisa el ConfigMap. (2) **La regla solo coincide con `Pod` y estás inspeccionando el objeto controlador**; el Pod *sí* está mutado — revisa `kubectl get pod -o yaml`, no el Deployment. (3) **El bloque match usa `objectSelector` sobre etiquetas que el controlador no propaga**, o una restricción `operations: [CREATE]` mientras la ruta del controlador realiza una actualización — revisa `kubectl get cpol <name> -o yaml` y `status.autogen.rules`. Una cuarta a tener en cuenta: la ServiceAccount del controlador está en un bloque `exclude`.

**A46.** Porque una regla de mutación de `Pod` a nivel de clúster con `failurePolicy: Fail` significa que cada indisponibilidad de Kyverno — actualización, drenaje de nodo, OOM, rotación de certificados — se convierte en una incapacidad de todo el clúster para planificar Pods nuevos, incluidos los Pods que restaurarían al propio Kyverno. Mitigaciones, aplicadas conjuntamente: ejecutar ≥3 réplicas del admission controller con antiafinidad y un PDB; mantener `kube-system` y el propio namespace de Kyverno en `resourceFilters`; acotar el webhook con `namespaceSelector` para que los namespaces críticos nunca sean interceptados; e introducir reglas nuevas con `failurePolicy: Ignore` más monitorización basada en informes antes de endurecerlas.

### Ejercicio 9

**A47.** `kyverno-resource-mutating-webhook-cfg` se ejecutó primero, en la fase de **admisión de mutación**, añadiendo `team=platform`. El servidor de API realizó entonces la validación de esquema, y luego llamó a `kyverno-resource-validating-webhook-cfg` en la fase de **admisión de validación**, que vio el objeto ya mutado y lo dejó pasar. Ese orden lo garantiza Kubernetes, no Kyverno, y es lo que hace de "mutar para remediar, validar para exigir" un patrón sólido.

**A48.** Misma política: sin cambios — el límite entre fases lo impone el servidor de API a través de todos los webhooks, así que la regla de mutación sigue ejecutándose en la fase anterior independientemente de que estén juntas. Dos políticas con nombres distintos: tampoco hay cambio, por la misma razón. El orden entre políticas solo es una preocupación entre dos reglas de **mutación** que compiten por el mismo campo (A14), nunca entre una de mutación y una de validación.

**A49.** Dos reglas: una regla de mutación que use `+(key): <default>` para que rellene el campo solo cuando esté ausente y nunca anule una elección deliberada, seguida de una regla de validación con `pattern`/`deny` que rechace cualquier valor fuera del conjunto permitido. La regla de **validación** no debe usar `+()` — el ancla es exclusiva de mutate, y la semántica que quieres ahí es "el valor debe ser uno de estos", no "ponle un valor por defecto". Publica la regla de validación en `Audit` primero, lee los informes de política, y luego cambia a `Enforce`.

**A50.** (1) **Eventos** — Kyverno emite `PolicyApplied` sobre el recurso (y `PolicySkipped`/`PolicyError` en las alternativas), que es el registro por petición; habilita `generateSuccessEvents` si también los quieres para mutaciones exitosas. (2) El **log de auditoría de Kubernetes**, donde la subetapa `patch` registra la respuesta del webhook y la atribuye a `kyverno-svc`, y el `metadata.managedFields` del objeto resultante muestra la mutación bajo el gestor de campos de Kyverno en lugar del del usuario. Los informes de política cubren resultados de validación, no mutaciones, así que no son sustituto de ninguno de los dos.

</details>

---

## Fuentes

- Kyverno — Reglas de mutación (patchStrategicMerge, patchesJson6902, foreach, mutate existing, targets): <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno — Anclas y coincidencia de patrones: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — JMESPath y las funciones personalizadas de Kyverno: <https://kyverno.io/docs/writing-policies/jmespath/>
- Kyverno — Precondiciones: <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno — Reglas auto-generadas para controladores de Pod: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — Instalación y personalización (`resourceFilters`, RBAC agregado, configuración de webhooks): <https://kyverno.io/docs/installation/customization/>
- Kyverno — CLI (`apply`, `test`, `jp`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Biblioteca de políticas (ejemplos de producción de reescritura de registro, inyección de sidecars, mutación de existentes): <https://kyverno.io/policies/>
- Kubernetes — Control de admisión dinámico y orden de los webhooks: <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Kubernetes — Actualizar objetos de la API in situ con `kubectl patch` (strategic merge patch, claves de fusión): <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/>
- Kubernetes — Imágenes de contenedor y valores por defecto de `imagePullPolicy`: <https://kubernetes.io/docs/concepts/containers/images/>
- Kubernetes — Etiquetas y selectores (sintaxis y restricciones de valores): <https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/>
- IETF RFC 6902 — JavaScript Object Notation (JSON) Patch: <https://datatracker.ietf.org/doc/html/rfc6902>
- IETF RFC 6901 — JavaScript Object Notation (JSON) Pointer (escape `~0` / `~1`): <https://datatracker.ietf.org/doc/html/rfc6901>
- CNCF — Currículum KCA: <https://github.com/cncf/curriculum>