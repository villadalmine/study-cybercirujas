# 5.8 JSON Patches — Ejercicios guiados

> **Dominio 5 — Writing Policies · Objetivo 5.8 (≈2.91% del examen KCA)**
> Syllabus de referencia: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

JSON Patch (RFC 6902) es el mecanismo de mutación *quirúrgico* de Kyverno: una lista ordenada y atómica de operaciones direccionadas mediante JSON Pointer (RFC 6901). Es la herramienta a la que recurrís cuando strategic merge no puede expresar el cambio — borrar un campo, agregar un elemento a una lista, mover un valor, o condicionar toda la mutación a un valor que ya está en el objeto.

Estos ejercicios se hacen en orden. Todo se ejecuta contra un clúster real y después se vuelve a verificar offline con la CLI de Kyverno, porque ese es exactamente el ciclo que usás en producción y en el examen.

**Convenciones usadas más abajo**

- Las salidas de los comandos se muestran tal como aparecen habitualmente. Las cadenas que produce la librería embebida `evanphx/json-patch` (usada tanto por el API server como por Kyverno) y el renderizador de la CLI `kyverno` varían levemente entre releases — anotá lo que imprime *tu* versión en lugar de memorizar una cadena.
- `$` antecede a un comando de shell. Todo lo demás dentro de un bloque de salida es salida.

---

## Ejercicio 0 — Entorno de laboratorio

### Pasos

1. Creá un clúster descartable:

```bash
$ kind create cluster --name kca-58 --image kindest/node:v1.31.0
$ kubectl cluster-info --context kind-kca-58
```

2. Instalá Kyverno:

```bash
$ helm repo add kyverno https://kyverno.github.io/kyverno/
$ helm repo update
$ helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
```

3. Confirmá que el control plane levantó. Desde Kyverno 1.10 el controlador está dividido en cuatro deployments:

```bash
$ kubectl -n kyverno get deploy
```

```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           78s
kyverno-background-controller   1/1     1            1           78s
kyverno-cleanup-controller      1/1     1            1           78s
kyverno-reports-controller      1/1     1            1           78s
```

4. Mirá el webhook que Kyverno registró para mutación:

```bash
$ kubectl get mutatingwebhookconfigurations
```

```
NAME                                 WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg   1          80s
kyverno-resource-mutating-webhook-cfg 1          80s
kyverno-verify-mutating-webhook-cfg   1          80s
```

5. Instalá la CLI de Kyverno (la vas a necesitar a partir del Ejercicio 9):

```bash
$ kubectl krew install kyverno      # or download the release tarball from GitHub
$ kubectl kyverno version
```

6. Creá el namespace de trabajo:

```bash
$ kubectl create ns json-lab
```

### Preguntas

- **Q0.1** — ¿Cuál de los cuatro deployments de Kyverno reescribe efectivamente un `Pod` entrante en tiempo de admisión, y cuál es responsable de las policies `mutateExisting`?
- **Q0.2** — `kyverno-resource-mutating-webhook-cfg` se registra inicialmente con un conjunto de reglas vacío en una instalación nueva y se puebla una vez que existen policies. ¿Por qué Kyverno gestiona dinámicamente las reglas de su propio webhook en lugar de distribuir un webhook estático de tipo "match everything"?
- **Q0.3** — En el pipeline de request del API server, ¿un mutating admission webhook ve el objeto *antes* o *después* de que se aplique el defaulting de la API? ¿Por qué importa la respuesta para una operación `test` de JSON Patch?

---

## Ejercicio 1 — RFC 6902 sin Kyverno

Antes de escribir una sola policy, manejá la misma maquinaria a mano con `kubectl patch --type='json'`. Es la forma más rápida de construir intuición sobre las seis operaciones, y saca a Kyverno de la ecuación mientras aprendés.

### Pasos

1. Creá un workload sobre el cual operar:

```bash
$ kubectl -n json-lab create deployment web --image=nginx:1.27 --replicas=2
deployment.apps/web created
```

2. `replace` — la ubicación de destino **ya debe existir**:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/spec/replicas","value":3}]'
deployment.apps/web patched
```

3. `add` sobre un miembro de objeto que ya existe. Leé con atención el RFC 6902 §4.1 antes de predecir el resultado:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/replicas","value":4}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web -o jsonpath='{.spec.replicas}'; echo
4
```

4. `add` sobre un miembro que no existe — esto lo *crea*, siempre que el padre exista:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
deployment.apps/web patched
```

5. Ahora intentá hacer `remove` de un path que no está en el documento:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
```

```
Error from server: jsonpatch remove operation does not apply: doc is missing path: "/spec/template/spec/nodeSelector": missing value
```

6. Manejo de arrays. Primero creá el array padre, después agregá al final con el token de fin de array `-`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[]},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"LOG_LEVEL","value":"info"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"TIER","value":"frontend"}}
]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL TIER
```

7. Insertá *antes* de un elemento existente usando un índice numérico en lugar de `-`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/0","value":{"name":"REGION","value":"eu-west"}}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
REGION LOG_LEVEL TIER
```

8. `test` protege todo el patch. Ejecutá primero el caso que tiene éxito:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"test","path":"/spec/replicas","value":4},
  {"op":"replace","path":"/spec/replicas","value":6}
]'
deployment.apps/web patched
```

9. Ahora el caso que falla — notá que el `replace` de la misma lista *no* se aplica:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"test","path":"/spec/replicas","value":99},
  {"op":"replace","path":"/spec/replicas","value":1}
]'
```

```
Error from server: testing value /spec/replicas failed: test failed
```

```bash
$ kubectl -n json-lab get deploy web -o jsonpath='{.spec.replicas}'; echo
6
```

10. `copy` y `move`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' -p='[
  {"op":"copy","from":"/metadata/labels/app","path":"/spec/template/metadata/labels/component"},
  {"op":"move","from":"/spec/template/spec/containers/0/env/0","path":"/spec/template/spec/containers/0/env/-"}
]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL TIER REGION
```

### Preguntas

- **Q1.1** — En el paso 3, `add` se aplicó a `/spec/replicas`, que ya tenía un valor. ¿Qué dice el RFC 6902 que pasa, y cuál es la consecuencia práctica cuando hacés `add` de un objeto vacío a `/metadata/labels` en un recurso que ya lleva labels?
- **Q1.2** — El paso 5 falló. Nombrá dos formas distintas de hacer segura una policy de tipo "borrá este campo si está presente" en Kyverno.
- **Q1.3** — ¿Cuál es la diferencia entre `path: /…/env/-` y `path: /…/env/0`? ¿Qué operaciones aceptan el token `-` y cuáles lo rechazan?
- **Q1.4** — El paso 9 demuestra una propiedad de los patches RFC 6902. Enunciá esa propiedad en una oración y explicá por qué hace de `test` el único condicional *intrínseco* de la especificación.
- **Q1.5** — `move` y `copy` toman ambos un puntero `from`. ¿Qué es lo único que `move` debe validar adicionalmente y `copy` no?

---

## Ejercicio 2 — Escapado de JSON Pointer (RFC 6901)

Las claves de Kubernetes están llenas de `/` — cada label y annotation con prefijo de dominio tiene una. Esta es, con diferencia, la razón más común por la que un JSON patch de Kyverno escrito a mano apunta silenciosamente a la ubicación equivocada.

### Pasos

1. Poné una annotation con prefijo de dominio en el deployment:

```bash
$ kubectl -n json-lab annotate deployment web kca.example.com/owner=platform
deployment.apps/web annotated
```

2. Intentá parchearla con la clave literal — observá la falla:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/kca.example.com/owner","value":"sre"}]'
```

```
Error from server: jsonpatch replace operation does not apply: doc is missing path: "/metadata/annotations/kca.example.com/owner": missing value
```

3. Escapá la `/` de la clave como `~1`:

```bash
$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/kca.example.com~1owner","value":"sre"}]'
deployment.apps/web patched

$ kubectl -n json-lab get deploy web \
  -o jsonpath='{.metadata.annotations.kca\.example\.com/owner}'; echo
sre
```

4. Ahora una clave que contiene una tilde literal. Agregala y después direccionala:

```bash
$ kubectl -n json-lab annotate deployment web 'weird~key=value1'
deployment.apps/web annotated

$ kubectl -n json-lab patch deployment web --type='json' \
  -p='[{"op":"replace","path":"/metadata/annotations/weird~0key","value":"value2"}]'
deployment.apps/web patched
```

5. Razoná el caso patológico — una clave llamada literalmente `a~1b`. Su token de JSON Pointer es `a~01b`. Decodificalo a mano: aplicá primero `~1 → /`, después `~0 → ~`, y confirmá que obtenés de vuelta `a~1b` y no `a/b`.

### Preguntas

- **Q2.1** — Escribí el path de JSON Pointer que apunta al label `app.kubernetes.io/managed-by` en un Pod.
- **Q2.2** — El RFC 6901 obliga a un orden de decodificación para los dos escapes. ¿Cuál se aplica primero, y qué se rompe si lo invertís?
- **Q2.3** — El paso 2 no levantó un error de sintaxis; levantó un error de *path faltante*. Explicá por qué una `/` sin escapar produce un puntero semánticamente válido pero incorrecto, y por qué eso hace que esta clase de bug sea tan fácil de mandar a producción.

---

## Ejercicio 3 — Tu primera regla `patchesJson6902` de Kyverno

### Pasos

1. Escribí la policy. Notá que `patchesJson6902` es un campo de tipo **string** que contiene una secuencia YAML (o JSON) de operaciones — de ahí el escalar de bloque `|-`:

```yaml
# 01-add-team-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/team"
            value: platform
```

2. Aplicala y confirmá que Kyverno la aceptó:

```bash
$ kubectl apply -f 01-add-team-label.yaml
clusterpolicy.kyverno.io/add-team-label created

$ kubectl get clusterpolicy add-team-label
NAME             ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-team-label   true        true         True    6s    Ready
```

3. Creá un Pod que **ya tenga labels** (`kubectl run` siempre setea `run=<name>`):

```bash
$ kubectl -n json-lab run labeled --image=nginx:1.27
pod/labeled created

$ kubectl -n json-lab get pod labeled -o jsonpath='{.metadata.labels}'; echo
{"run":"labeled","team":"platform"}
```

4. Inspeccioná la miga de pan que Kyverno deja en cada objeto mutado:

```bash
$ kubectl -n json-lab get pod labeled \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo
add-team-label.add-team-label.kyverno.io: added /metadata/labels/team
```

5. Ahora creá un Pod **sin ningún label**:

```yaml
# 02-unlabeled-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: unlabeled
  namespace: json-lab
spec:
  containers:
    - name: app
      image: nginx:1.27
```

```bash
$ kubectl apply -f 02-unlabeled-pod.yaml
```

6. Registrá exactamente qué pasó — este es el punto del ejercicio:

```bash
$ kubectl -n json-lab get pod unlabeled -o jsonpath='{.metadata.labels}'; echo
$ kubectl -n json-lab get events --field-selector involvedObject.name=unlabeled
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 | grep -i patch
```

7. Anotá tres hechos: (a) ¿se creó el Pod?, (b) ¿lleva `team=platform`?, (c) ¿Kyverno registró un error?

### Preguntas

- **Q3.1** — ¿Por qué `patchesJson6902` debe ser un escalar de bloque (`|-`) en lugar de una lista YAML nativa bajo la clave `mutate`?
- **Q3.2** — Según lo que observaste en los pasos 5–7, ¿está garantizado que `add` cree el objeto padre faltante `/metadata/labels`? ¿Qué exige el RFC 6902 §4.1, y por qué un build determinado de Kyverno puede comportarse de forma más permisiva que el RFC?
- **Q3.3** — Reescribí esta regla para que funcione en *cualquier* Pod, con o sin labels, sin posibilidad de destruir labels preexistentes. ¿Cuál es el mecanismo de mutación correcto acá?
- **Q3.4** — ¿Para qué sirve la annotation `policies.kyverno.io/last-applied-patches`, y por qué es lo primero que hay que revisar cuando un estudiante reporta "mi mutación no corrió"?

---

## Ejercicio 4 — La trampa del padre destructivo

Un "arreglo" muy común para el Ejercicio 3 es crear primero el padre. Demostrate a vos mismo por qué ese arreglo es peor que el bug.

### Pasos

1. Reemplazá la policy por la forma ingenua de dos operaciones:

```yaml
# 03-add-team-label-naive.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels"
            value: {}
          - op: add
            path: "/metadata/labels/team"
            value: platform
```

```bash
$ kubectl apply -f 03-add-team-label-naive.yaml
clusterpolicy.kyverno.io/add-team-label configured
```

2. Creá un Pod que lleve labels que te importan:

```bash
$ kubectl -n json-lab run important --image=nginx:1.27 \
  --labels='app=checkout,tier=frontend,owner=payments'
pod/important created
```

3. Inspeccioná el resultado:

```bash
$ kubectl -n json-lab get pod important -o jsonpath='{.metadata.labels}'; echo
{"team":"platform"}
```

4. Los selectores del Pod, las NetworkPolicies y los endpoints de Service quedaron rotos. Limpiá y restaurá una policy segura:

```bash
$ kubectl -n json-lab delete pod important --now
$ kubectl delete clusterpolicy add-team-label
```

5. Escribí la versión correcta usando strategic merge, que fusiona mapas en lugar de reemplazarlos:

```yaml
# 04-add-team-label-safe.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
    - name: add-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              team: platform
```

```bash
$ kubectl apply -f 04-add-team-label-safe.yaml
$ kubectl -n json-lab run important --image=nginx:1.27 \
  --labels='app=checkout,tier=frontend,owner=payments'
$ kubectl -n json-lab get pod important -o jsonpath='{.metadata.labels}'; echo
{"app":"checkout","owner":"payments","team":"platform","tier":"frontend"}
```

6. Si estás *obligado* a usar JSON Patch (por ejemplo, el campo es una lista y necesitás control posicional), acotá la rama destructiva con una precondition:

```yaml
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels || '' }}"
            operator: Equals
            value: ""
```

### Preguntas

- **Q4.1** — ¿Exactamente qué regla del RFC 6902 hizo que el paso 3 destruyera tres labels?
- **Q4.2** — El RFC 6902 puro no tiene una operación de "crear solo si está ausente". Dado que `test` compara un valor en un puntero, ¿se puede usar `test` para afirmar que `/metadata/labels` está *ausente*? Justificá tu respuesta.
- **Q4.3** — Enunciá la regla de decisión que vas a usar por el resto de tu carrera: ¿cuándo elegís `patchStrategicMerge` y cuándo `patchesJson6902`?
- **Q4.4** — En el paso 6, ¿por qué es necesario el fallback `|| ''`, y qué le pasa a la regla si una variable de un patch de Kyverno no se resuelve?

---

## Ejercicio 5 — Arrays, UPDATE y el bug de idempotencia

Este es el ejercicio de mayor valor del objetivo. `add …/-` de JSON Patch *no* es idempotente, y el admission webhook de Kyverno se dispara tanto en CREATE como en UPDATE.

### Pasos

1. Desplegá un workload cuyo contenedor ya tenga una lista `env`:

```yaml
# 05-api-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: json-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27
          env:
            - name: LOG_LEVEL
              value: info
```

```bash
$ kubectl apply -f 05-api-deployment.yaml
deployment.apps/api created
```

2. Escribí una policy que agrega al final:

```yaml
# 06-append-env.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/template/spec/containers/0/env/-"
            value:
              name: CLUSTER_TIER
              value: gold
```

```bash
$ kubectl apply -f 06-append-env.yaml
clusterpolicy.kyverno.io/append-cluster-tier created
```

3. Volvé a crear el deployment para que la regla se dispare en CREATE:

```bash
$ kubectl delete -f 05-api-deployment.yaml
$ kubectl apply -f 05-api-deployment.yaml

$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

4. Dispará un UPDATE ordinario — cualquier cosa, como un controlador de GitOps reaplicando una annotation:

```bash
$ kubectl -n json-lab annotate deploy api bump=1 --overwrite
deployment.apps/api annotated

$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER CLUSTER_TIER
```

5. Hacelo tres veces más y mirá cómo la lista crece sin límite:

```bash
$ for i in 2 3 4; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER CLUSTER_TIER
```

6. **Arreglo A — restringir las operaciones de admisión** (Kyverno 1.11+, `match.any[].resources.operations`):

```yaml
# 07-append-env-create-only.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
              operations:
                - CREATE
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/spec/template/spec/containers/0/env/-"
            value:
              name: CLUSTER_TIER
              value: gold
```

```bash
$ kubectl apply -f 07-append-env-create-only.yaml
$ kubectl delete -f 05-api-deployment.yaml && kubectl apply -f 05-api-deployment.yaml
$ for i in 1 2 3; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

7. **Arreglo B — una precondition sobre el verbo de admisión**, equivalente en efecto y usable en versiones más viejas:

```yaml
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: CREATE
```

8. **Arreglo C — la opción estructuralmente idempotente.** `env` lleva `patchMergeKey: name` en la API de Kubernetes, así que strategic merge deduplica por nombre:

```yaml
# 08-append-env-smp.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: append-cluster-tier
spec:
  rules:
    - name: append-env
      match:
        any:
          - resources:
              kinds:
                - Deployment
              namespaces:
                - json-lab
      mutate:
        patchStrategicMerge:
          spec:
            template:
              spec:
                containers:
                  - (name): "*"
                    env:
                      - name: CLUSTER_TIER
                        value: gold
```

```bash
$ kubectl apply -f 08-append-env-smp.yaml
$ kubectl delete -f 05-api-deployment.yaml && kubectl apply -f 05-api-deployment.yaml
$ for i in 1 2 3; do kubectl -n json-lab annotate deploy api bump=$i --overwrite >/dev/null; done
$ kubectl -n json-lab get deploy api \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
LOG_LEVEL CLUSTER_TIER
```

### Preguntas

- **Q5.1** — Explicá, en términos del ciclo de vida del admission webhook, por qué apareció el duplicado en el paso 4 aunque nada del template del Pod cambió.
- **Q5.2** — El API server acepta nombres de `env` duplicados. ¿Qué componente resuelve el conflicto en tiempo de ejecución, y por qué "igual funciona" es una conclusión peligrosa?
- **Q5.3** — El Arreglo A y el Arreglo B producen el mismo resultado para esta policy. Nombrá una situación en la que acotar vía `match.any[].resources.operations` sea materialmente mejor que una precondition, y una en la que la precondition sea la única opción.
- **Q5.4** — El Arreglo C es idempotente *para este campo*. ¿Por qué esa es una propiedad de `env` en particular y no de toda lista del `PodSpec`? ¿Cómo determinás, para un campo arbitrario, si strategic merge va a fusionar o reemplazar?
- **Q5.5** — La policy hardcodea el índice de contenedor `0`. Describí el modo de falla en un Pod con un sidecar, y enunciá la construcción correcta de Kyverno para arreglarlo.

---

## Ejercicio 6 — `test` como condicional dentro del patch

`test` le permite al patch decidir por sí mismo si aplicarse, usando solo datos que ya están en el objeto. Como una operación fallida aborta todo el patch, la guarda es atómica.

### Pasos

1. Escribí una policy que baje `imagePullPolicy` **solo si** actualmente es `Always`:

```yaml
# 09-test-guard.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: relax-image-pull-policy
spec:
  rules:
    - name: only-if-always
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: test
            path: "/spec/containers/0/imagePullPolicy"
            value: Always
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: IfNotPresent
```

```bash
$ kubectl apply -f 09-test-guard.yaml
$ kubectl delete clusterpolicy append-cluster-tier
```

2. Creá un Pod cuyo tag de imagen sea `latest` — el API server le pone `imagePullPolicy` en `Always` por defecto:

```bash
$ kubectl -n json-lab run pinned-latest --image=nginx:latest
pod/pinned-latest created

$ kubectl -n json-lab get pod pinned-latest \
  -o jsonpath='{.spec.containers[0].imagePullPolicy}'; echo
IfNotPresent
```

3. Creá un Pod con un tag explícito, que por defecto queda en `IfNotPresent` — ahora el `test` falla:

```bash
$ kubectl -n json-lab run pinned-1-27 --image=nginx:1.27
pod/pinned-1-27 created

$ kubectl -n json-lab get pod pinned-1-27 \
  -o jsonpath='{.spec.containers[0].imagePullPolicy}'; echo
IfNotPresent
```

4. Verificá que el *segundo* Pod nunca fue parcheado, en lugar de haber sido parcheado al mismo valor:

```bash
$ kubectl -n json-lab get pod pinned-1-27 \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo

$ kubectl -n json-lab get pod pinned-latest \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo
only-if-always.relax-image-pull-policy.kyverno.io: replaced /spec/containers/0/imagePullPolicy
```

5. Demostrá la afirmación de atomicidad. Agregá una segunda operación, incondicional, *después* de la guarda y confirmá que también queda suprimida cuando el `test` falla:

```yaml
        patchesJson6902: |-
          - op: test
            path: "/spec/containers/0/imagePullPolicy"
            value: Always
          - op: replace
            path: "/spec/containers/0/imagePullPolicy"
            value: IfNotPresent
          - op: add
            path: "/metadata/annotations/kca.example.com~1relaxed"
            value: "true"
```

```bash
$ kubectl apply -f 09-test-guard.yaml
$ kubectl -n json-lab run tagged2 --image=nginx:1.27
$ kubectl -n json-lab get pod tagged2 \
  -o jsonpath='{.metadata.annotations}'; echo
```

### Preguntas

- **Q6.1** — En el paso 2, tu manifiesto nunca mencionó `imagePullPolicy` y sin embargo la operación `test` encontró `Always`. ¿Qué etapa del pipeline del API server lo puso ahí, y qué lección general enseña esto sobre escribir JSON Pointers contra objetos de Kubernetes?
- **Q6.2** — `test` compara por valor. ¿Qué dice el RFC 6902 sobre comparar objetos y arrays — es `{"a":1,"b":2}` igual a `{"b":2,"a":1}`, y es `[1,2]` igual a `[2,1]`?
- **Q6.3** — En el paso 5, la operación de la annotation no tiene relación con la guarda y sin embargo no se aplicó. Reformulá la regla de atomicidad, y describí cómo dividirías esta policy en dos reglas si quisieras que la annotation se aplicara incondicionalmente.
- **Q6.4** — ¿Cuándo preferirías una `precondition` de Kyverno por sobre un `test` de RFC 6902, y viceversa? Dá una capacidad que cada uno tiene y al otro le falta.

---

## Ejercicio 7 — Variables y JMESPath dentro de un JSON Patch

### Pasos

1. Kyverno sustituye las variables `{{ … }}` **antes** de que la cadena del patch se parsee como JSON Patch. Escribí una policy que estampe la procedencia en un Pod:

```yaml
# 10-provenance.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: stamp-provenance
spec:
  rules:
    - name: stamp
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: add
            path: "/metadata/annotations/kca.example.com~1created-by"
            value: "{{ request.userInfo.username }}"
          - op: add
            path: "/metadata/annotations/kca.example.com~1namespace"
            value: "{{ request.namespace }}"
          - op: add
            path: "/metadata/annotations/kca.example.com~1app-upper"
            value: "{{ to_upper(request.object.metadata.labels.app || 'UNSET') }}"
```

2. El patch escribe dentro de `/metadata/annotations/…`, así que el Pod destino ya debe tener ese mapa. Creá uno que lo tenga:

```yaml
# 11-annotated-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: stamped
  namespace: json-lab
  labels:
    app: checkout
  annotations:
    kca.example.com/seed: "present"
spec:
  containers:
    - name: app
      image: nginx:1.27
```

```bash
$ kubectl apply -f 10-provenance.yaml
$ kubectl delete clusterpolicy relax-image-pull-policy
$ kubectl apply -f 11-annotated-pod.yaml
pod/stamped created

$ kubectl -n json-lab get pod stamped -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
```

```
{"kca.example.com/app-upper":"CHECKOUT"
"kca.example.com/created-by":"kubernetes-admin"
"kca.example.com/namespace":"json-lab"
"kca.example.com/seed":"present"
...}
```

3. Ahora sacá el fallback `|| 'UNSET'` de la tercera operación, reaplicá, y creá un Pod **sin** el label `app`. Registrá si la regla da error, se saltea, o se aplica parcialmente.

4. Restaurá el fallback.

### Preguntas

- **Q7.1** — La sustitución de variables ocurre antes de que el patch se parsee. ¿Qué implica eso si una variable resuelve a una cadena que contiene una `/` y la interpolás dentro de un `path`?
- **Q7.2** — En el paso 3, ¿qué hizo Kyverno cuando la variable no tenía valor? ¿Por qué `|| 'default'` se considera higiene obligatoria en policies de producción?
- **Q7.3** — `{{ request.userInfo.username }}` está disponible en admisión. ¿Está disponible para una regla `mutateExisting` que corre en el background controller? Explicá.
- **Q7.4** — ¿Por qué cada path de annotation de esta policy necesitó `~1`, y qué habría pasado si hubieras escrito `kca.example.com/created-by` sin escapar?

---

## Ejercicio 8 — `foreach` + `patchesJson6902`: eliminar índices hardcodeados

### Pasos

1. Desplegá un Pod multi-contenedor:

```yaml
# 12-multi-container.yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi
  namespace: json-lab
spec:
  containers:
    - name: app
      image: nginx:latest
    - name: sidecar
      image: busybox:latest
      command: ["sleep", "3600"]
    - name: exporter
      image: prom/node-exporter:latest
```

2. Escribí una mutación con `foreach`. Dentro del loop, `{{elementIndex}}` es la posición de base cero y `{{element}}` es el ítem en sí:

```yaml
# 13-foreach-pullpolicy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: set-image-pull-policy
spec:
  rules:
    - name: set-ifnotpresent
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            patchesJson6902: |-
              - op: add
                path: "/spec/containers/{{elementIndex}}/imagePullPolicy"
                value: IfNotPresent
```

```bash
$ kubectl delete clusterpolicy stamp-provenance
$ kubectl apply -f 13-foreach-pullpolicy.yaml
$ kubectl apply -f 12-multi-container.yaml
pod/multi created

$ kubectl -n json-lab get pod multi \
  -o jsonpath='{range .spec.containers[*]}{.name}{"="}{.imagePullPolicy}{"\n"}{end}'
app=IfNotPresent
sidecar=IfNotPresent
exporter=IfNotPresent
```

3. Confirmá que `add` sobre un path escalar es seguro sin importar si el campo estaba presente — crea o reemplaza, nunca falla por un hermano faltante.

4. Agregá un filtro de `foreach` para que solo se toquen las imágenes de un registry específico:

```yaml
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: NotEquals
                  value: "busybox:*"
            patchesJson6902: |-
              - op: add
                path: "/spec/containers/{{elementIndex}}/imagePullPolicy"
                value: IfNotPresent
```

```bash
$ kubectl apply -f 13-foreach-pullpolicy.yaml
$ kubectl -n json-lab delete pod multi --now && kubectl apply -f 12-multi-container.yaml
$ kubectl -n json-lab get pod multi \
  -o jsonpath='{range .spec.containers[*]}{.name}{"="}{.imagePullPolicy}{"\n"}{end}'
app=IfNotPresent
sidecar=Always
exporter=IfNotPresent
```

### Preguntas

- **Q8.1** — Compará `/spec/containers/{{elementIndex}}/imagePullPolicy` con `/spec/containers/0/imagePullPolicy`. ¿Qué clase de bug elimina el primero, y qué te cuesta en legibilidad?
- **Q8.2** — Dentro de un `foreach` que agrega al final con `/-`, el array crece a medida que corre el loop. ¿Por qué esto puede hacer que `{{elementIndex}}` sea poco confiable, y qué estilo de mutación evita el problema por completo?
- **Q8.3** — ¿Esta policy también cubriría `initContainers` y `ephemeralContainers`? ¿Qué cambio se requiere?
- **Q8.4** — ¿Cuál es la diferencia entre un bloque `preconditions` a nivel de regla y el bloque `preconditions` anidado dentro de una entrada de `foreach`?

---

## Ejercicio 9 — Iterar offline con la CLI de Kyverno

Nunca depures un JSON patch recreando Pods en un clúster. La CLI te da un ciclo determinista y revisable, y es directamente examinable bajo el Dominio 3.

### Pasos

1. Poné la policy y un recurso candidato lado a lado:

```bash
$ mkdir -p ~/kca58/tests && cd ~/kca58/tests
$ cp ../13-foreach-pullpolicy.yaml policy.yaml
$ cp ../12-multi-container.yaml resource.yaml
```

2. Aplicá la policy al recurso sin tocar el clúster:

```bash
$ kubectl kyverno apply policy.yaml --resource resource.yaml
```

```
Applying 1 policy rule(s) to 1 resource(s)...

mutate policy set-image-pull-policy applied to json-lab/Pod/multi:

apiVersion: v1
kind: Pod
metadata:
  name: multi
  namespace: json-lab
spec:
  containers:
  - image: nginx:latest
    imagePullPolicy: IfNotPresent
    name: app
...
---

pass: 1, fail: 0, warn: 0, error: 0, skip: 0
```

3. Congelá la salida esperada como archivo golden y convertí todo esto en un test de regresión:

```bash
$ kubectl kyverno apply policy.yaml --resource resource.yaml > /tmp/out.yaml
# extract the mutated Pod into patched.yaml, then:
```

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: json-patch-tests
policies:
  - policy.yaml
resources:
  - resource.yaml
results:
  - policy: set-image-pull-policy
    rule: set-ifnotpresent
    kind: Pod
    resources:
      - multi
    patchedResources: patched.yaml
    result: pass
```

4. Corrélo:

```bash
$ kubectl kyverno test .
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 1 resource ...
  Checking results ...

│───│───────────────────────│──────────────────│──────────────────│────────│
│ ID│ POLICY                │ RULE             │ RESOURCE         │ RESULT │
│───│───────────────────────│──────────────────│──────────────────│────────│
│ 1 │ set-image-pull-policy │ set-ifnotpresent │ v1/Pod/multi     │ Pass   │
│───│───────────────────────│──────────────────│──────────────────│────────│

Test Summary: 1 tests passed and 0 tests failed
```

5. Rompé la policy a propósito — cambiá `IfNotPresent` por `Never` en `policy.yaml` — y volvé a correr `kubectl kyverno test .` para ver un `Fail` con un diff.

6. Restaurá la policy y confirmá que el test vuelve a pasar.

> **Nota de versión.** El manifiesto Test con `apiVersion: cli.kyverno.io/v1alpha1` y el campo `patchedResources` son la forma moderna (Kyverno 1.11+). Las CLIs más viejas usaban un manifiesto sin versionar y un `patchedResource` en singular. Corré `kubectl kyverno test --help` en tu build en lugar de confiar en un esquema memorizado.

### Preguntas

- **Q9.1** — ¿Por qué `patchedResources` en un `Test` atrapa toda una clase de bugs de JSON patch que una aserción `result: pass` por sí sola no puede?
- **Q9.2** — `kyverno apply` corre el motor de policies sin un API server. Nombrá dos cosas que por lo tanto *no* puede evaluar, y cómo se las proveés.
- **Q9.3** — En un pipeline de CI que actúa como compuerta de un repositorio de policies, ¿dónde se ubica `kyverno test` respecto de `kyverno apply`, y cuál corresponde a un hook de pre-commit?

---

## Ejercicio 10 — JSON Patches contra recursos existentes

`mutateExisting` corre en el background controller, no en admisión. Todo lo que sabés de JSON Patch sigue aplicando — pero los modos de falla tienen forma de RBAC.

### Pasos

1. Creá ConfigMaps que ya lleven un mapa de labels:

```bash
$ kubectl -n json-lab create configmap app-config --from-literal=key=value
$ kubectl -n json-lab label configmap app-config app=checkout
$ kubectl -n json-lab create configmap other-config --from-literal=key=value
$ kubectl -n json-lab label configmap other-config app=search
```

2. Otorgale al background controller permiso para actualizar ConfigMaps. Kyverno agrega ClusterRoles por label — confirmá primero el selector en tu instalación:

```bash
$ kubectl get clusterrole kyverno:background-controller -o jsonpath='{.aggregationRule}' | jq
```

```yaml
# 14-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:mutate-configmaps
  labels:
    app.kubernetes.io/part-of: kyverno
    app.kubernetes.io/instance: kyverno
    app.kubernetes.io/component: background-controller
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
```

```bash
$ kubectl apply -f 14-rbac.yaml
```

3. Escribí la policy `mutateExisting`. `match` selecciona el **disparador**; `targets` selecciona qué se parchea:

```yaml
# 15-mutate-existing.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: label-existing-configmaps
spec:
  mutateExistingOnPolicyUpdate: true
  rules:
    - name: add-managed-label
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              namespaces:
                - json-lab
      mutate:
        targets:
          - apiVersion: v1
            kind: ConfigMap
            namespace: json-lab
        patchesJson6902: |-
          - op: add
            path: "/metadata/labels/managed-by"
            value: kyverno
```

```bash
$ kubectl apply -f 15-mutate-existing.yaml
clusterpolicy.kyverno.io/label-existing-configmaps created
```

4. Esperá unos segundos y verificá:

```bash
$ kubectl -n json-lab get cm --show-labels
NAME           DATA   AGE   LABELS
app-config     1      2m    app=checkout,managed-by=kyverno
other-config   1      2m    app=search,managed-by=kyverno
```

5. Ahora quitá el RBAC y repetí con un ConfigMap nuevo para ver la falla característica:

```bash
$ kubectl delete -f 14-rbac.yaml
$ kubectl -n json-lab create configmap third-config --from-literal=k=v
$ kubectl -n json-lab label configmap third-config app=cart
$ kubectl -n kyverno logs deploy/kyverno-background-controller --tail=30 | grep -i forbidden
```

6. Volvé a aplicar el RBAC, después limpiá.

### Preguntas

- **Q10.1** — ¿Cuál es la diferencia semántica entre `match` y `mutate.targets` en una regla `mutateExisting`, y qué pasa si omitís `targets` por completo?
- **Q10.2** — `mutateExistingOnPolicyUpdate: true` cambia cuándo corre la regla. Describí ambos caminos de disparo, y explicá por qué dejarlo en `false` es el default más seguro en un clúster grande.
- **Q10.3** — Las mutaciones en admisión no necesitan RBAC adicional; `mutateExisting` sí. ¿Por qué?
- **Q10.4** — El path `/metadata/labels/managed-by` asume que el mapa de labels existe — como pasaba acá, porque etiquetaste cada ConfigMap primero. ¿Cuál es la reescritura segura para producción?

---

## Ejercicio 11 — Diagnosticar un patch que no se aplicó

### Pasos

1. Desplegá una policy con un puntero deliberadamente incorrecto (`container` en vez de `containers`):

```yaml
# 16-broken.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-pointer
spec:
  rules:
    - name: bad-path
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - json-lab
      mutate:
        patchesJson6902: |-
          - op: replace
            path: "/spec/container/0/imagePullPolicy"
            value: IfNotPresent
```

```bash
$ kubectl apply -f 16-broken.yaml
$ kubectl -n json-lab run diag --image=nginx:1.27
```

2. Recorré la escalera de diagnóstico, de lo más barato a lo más caro:

```bash
# 1. Did the object change at all?
$ kubectl -n json-lab get pod diag \
  -o jsonpath='{.metadata.annotations.policies\.kyverno\.io/last-applied-patches}'; echo

# 2. Did the policy even match? Check events on the policy and the resource.
$ kubectl -n json-lab get events --sort-by=.lastTimestamp | tail -20
$ kubectl describe clusterpolicy broken-pointer

# 3. What did the engine actually do?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i -e patch -e broken-pointer

# 4. Reproduce offline, deterministically.
$ kubectl kyverno apply 16-broken.yaml --resource <(kubectl -n json-lab get pod diag -o yaml)
```

3. Arreglá el puntero, reaplicá, recreá el Pod, y confirmá que ahora aparece `last-applied-patches`.

4. Limpiá todo el laboratorio:

```bash
$ kubectl delete clusterpolicy --all
$ kubectl delete ns json-lab
$ kind delete cluster --name kca-58
```

### Preguntas

- **Q11.1** — Ordená estas cuatro señales según qué tan temprano deberían aparecer en tu diagnóstico, y decí qué descarta o confirma cada una: el objeto mutado, `last-applied-patches`, los logs del controlador, `kyverno apply`.
- **Q11.2** — Los PolicyReports de Kyverno son la fuente canónica para los resultados de validate y verifyImages. ¿Por qué son una mala señal primaria para una regla de mutate, y cuál *es* la verdad de campo para la mutación?
- **Q11.3** — Una regla que nunca hizo match y una regla que hizo match pero cuyo patch falló se ven parecidas desde afuera. ¿Qué único comando las distingue más rápido?

---

## Referencia rápida

**Las seis operaciones del RFC 6902**

| op | Miembros requeridos | ¿El destino debe existir? | Notas |
|---|---|---|---|
| `add` | `path`, `value` | el padre debe existir | sobre un miembro de objeto existente, **reemplaza**; sobre un índice de array, **inserta antes**; `-` agrega al final |
| `remove` | `path` | sí | da error si falta; en un array, corre los elementos siguientes hacia abajo |
| `replace` | `path`, `value` | sí | equivalente a `remove` + `add`, pero atómico y más estricto |
| `move` | `from`, `path` | `from` debe existir | `path` no debe ser una ubicación dentro de `from` |
| `copy` | `from`, `path` | `from` debe existir | copia profunda del valor |
| `test` | `path`, `value` | sí | la falla aborta el patch **entero** |

**Escapes de JSON Pointer (RFC 6901)** — decodificá `~1` → `/` primero, después `~0` → `~`.

| Clave literal | Token de puntero |
|---|---|
| `app.kubernetes.io/name` | `app.kubernetes.io~1name` |
| `weird~key` | `weird~0key` |
| `a~1b` | `a~01b` |

**Trampas de examen, condensadas**

1. `patchesJson6902` es un **string** — siempre `|-`.
2. Una `/` sin escapar en una clave de label o annotation apunta silenciosamente al path equivocado.
3. `add` sobre un mapa existente lo **reemplaza** — `add /metadata/labels {}` destruye los labels.
4. `add …/-` no es idempotente; el webhook también se dispara en UPDATE.
5. Un `test` fallido (o cualquier op fallida) descarta toda la lista del patch.
6. Los índices de contenedor hardcodeados se rompen con sidecars — usá `foreach` + `{{elementIndex}}`.
7. Los patches operan sobre el objeto **con defaults aplicados**, no sobre tu YAML.
8. `mutateExisting` necesita RBAC explícito para el background controller.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1** — El deployment del **admission controller** hospeda el endpoint del mutating webhook y reescribe recursos en vuelo durante `CREATE`/`UPDATE`. El **background controller** ejecuta las reglas `mutateExisting` (y las reglas `generate`) contra objetos ya almacenados en etcd; actúa como un cliente ordinario de la API, y por eso necesita su propio RBAC. El reports controller construye los PolicyReports; el cleanup controller ejecuta el borrado de `CleanupPolicy`/TTL.

**A0.2** — Un webhook estático de tipo catch-all pondría a Kyverno en el camino de request de *cada* llamada a la API, incluido el tráfico central del control plane, convirtiendo una caída de Kyverno en una caída del clúster y agregando latencia a operaciones que a ninguna policy le importan. Al derivar las `rules` del webhook de las policies instaladas, Kyverno intercepta solo las combinaciones de group/version/kind/operation que al menos una regla efectivamente matchea. Esto también explica por qué un Kyverno recién instalado sin policies es prácticamente inerte, y por qué al aplicar tu primera policy de Pod hay una breve demora de reconciliación antes de que tenga efecto.

**A0.3** — **Después** del defaulting. El API server decodifica el cuerpo del request, lo convierte a la versión interna y aplica los defaults de la API, y *después* corre la cadena de mutating admission. En consecuencia, el objeto que direcciona tu JSON Pointer ya contiene campos poblados por el servidor como `imagePullPolicy`, `restartPolicy`, `dnsPolicy`, `terminationMessagePath` y `serviceAccountName`. Esto es lo que hace funcionar el Ejercicio 6: un `test` sobre `/spec/containers/0/imagePullPolicy` encuentra un valor aunque el YAML enviado nunca seteó ninguno. El corolario es que deberías escribir punteros contra la salida de `kubectl get -o yaml`, no contra el manifiesto que escribiste.

### Ejercicio 1

**A1.1** — RFC 6902 §4.1: *"If the target location specifies an object member that does exist, that member's value is replaced."* `add` es por lo tanto un upsert, no un insert, para miembros de objeto. La consecuencia práctica es grave: `{"op":"add","path":"/metadata/labels","value":{}}` reemplaza el mapa entero de labels con un objeto vacío, borrando silenciosamente todos los labels existentes. El Ejercicio 4 demuestra esto destruyendo `app`, `tier` y `owner`.

**A1.2** — (a) Proteger la regla con una `precondition` de Kyverno que chequee que el campo está presente, de modo que el patch solo corra cuando `remove` pueda tener éxito. (b) Usar `patchStrategicMerge` con la directiva `null` (`nodeSelector: null` bajo strategic merge borra la clave y es un no-op cuando está ausente). Una tercera opción es poner un `test` antes del `remove` — pero `test` solo puede afirmar un *valor conocido*, así que sirve para "borralo si es igual a X", no para "borralo si está presente".

**A1.3** — `-` es el token de fin de array: `add` en `…/env/-` agrega un elemento nuevo al final. Un índice numérico `0` inserta el elemento nuevo *antes* del elemento 0 actual, corriendo el resto. `-` solo tiene sentido para `add` (y como `path` de un `move`/`copy` que apunta a un array). `remove`, `replace` y `test` requieren un índice concreto existente; usar `-` con ellos es un error, porque no hay ningún elemento en la posición de fin de array.

**A1.4** — **Un patch RFC 6902 es atómico: si cualquier operación falla, no se aplica ninguna de las operaciones y el documento queda sin cambios.** Como el documento es todo-o-nada, `test` se vuelve un condicional — ponerlo primero hace que el éxito de cada operación siguiente dependa del valor testeado. Es el único condicional de la especificación precisamente porque no hay construcción de bifurcación; la semántica de aborto provee la rama.

**A1.5** — `move` debe validar que `path` **no** sea una ubicación dentro de `from` (RFC 6902 §4.4). Mover un nodo dentro de su propio subárbol es indefinido — estarías reubicando un valor dentro del mismo objeto que removiste. `copy` no tiene esa restricción, ya que la fuente permanece en su lugar.

### Ejercicio 2

**A2.1** — `/metadata/labels/app.kubernetes.io~1managed-by`. Solo se escapa la `/` que está dentro de la *clave*; los caracteres `/` que separan tokens del puntero son estructurales y quedan literales.

**A2.2** — `~1` → `/` se decodifica **primero**, después `~0` → `~`. Invertir el orden rompe cualquier clave que contenga la secuencia literal `~1`: la clave `a~1b` se codifica `a~01b`; decodificar `~0` primero da `a~1b` y después la regla `~1` lo convertiría en `a/b` — una clave distinta e incorrecta. El orden obligatorio es inequívoco en ambas direcciones.

**A2.3** — `/metadata/annotations/kca.example.com/owner` es un puntero perfectamente bien formado; simplemente direcciona una ubicación *diferente* — el miembro `owner` dentro de un objeto llamado `kca.example.com` dentro de `annotations`. Nada en la sintaxis es inválido, así que ningún parser se queja. Solo te enterás al momento de aplicar, y solo si la operación resulta ser una que requiere que el path exista. Un `add` con el mismo path sin escapar *tendría éxito*, creando un objeto anidado `{"kca.example.com": {"owner": "sre"}}` — que ni siquiera es un mapa de annotations válido. Ese caso de éxito silencioso es la razón por la que este bug llega a producción.

### Ejercicio 3

**A3.1** — Porque el esquema del CRD de Kyverno declara `patchesJson6902` como un `string`, no como un array de objetos. El escalar de bloque le entrega a Kyverno el texto crudo, que Kyverno parsea como documento JSON Patch después de la sustitución de variables. Escribirlo como una lista YAML nativa falla la validación del CRD. El tratamiento en dos etapas es también lo que permite interpolar variables `{{ }}` en el texto antes de que se parsee.

**A3.2** — El RFC 6902 §4.1 exige que el *padre* de la ubicación destino exista; `add` crea únicamente el miembro final. **No** crea objetos intermedios. Sin embargo, la librería `evanphx/json-patch` que usa Kyverno ofrece una opción `EnsurePathExistsOnAdd` que crea automáticamente los paths intermedios faltantes, y si Kyverno la habilita o no ha variado entre releases. Por eso exactamente el paso 7 te pidió registrar el comportamiento observado en lugar de decírtelo. **La regla portable: nunca dependas de eso.** O apuntás a un padre que sabés que existe, o usás `patchStrategicMerge`.

**A3.3** — Usá `patchStrategicMerge`, que fusiona mapas en lugar de reemplazarlos y crea los padres faltantes de forma natural:

```yaml
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              team: platform
```

Esto es idempotente, no destructivo y legible. JSON Patch es la herramienta equivocada para agregar una clave a un mapa.

**A3.4** — Kyverno estampa `policies.kyverno.io/last-applied-patches` en cada recurso que muta, registrando `<rule>.<policy>.kyverno.io: <action> <path>` por cada operación aplicada. Es la señal más barata posible: su presencia prueba que la regla matcheó *y* que el patch se aplicó; su ausencia significa que la regla no matcheó, fue salteada por una precondition o un `test`, o dio error — y ahí pasás a los events y a los logs del controlador para distinguirlos. (Se puede deshabilitar por configuración de Kyverno, así que verificá que esté habilitado en tu instalación antes de tratar su ausencia como prueba.)

### Ejercicio 4

**A4.1** — La regla del RFC 6902 §4.1 de reemplazo sobre miembro existente. `{"op":"add","path":"/metadata/labels","value":{}}` encontró `/metadata/labels` presente y reemplazó todo su valor por `{}`. La segunda operación entonces agregó `team: platform` a ese mapa ahora vacío, dejando exactamente un label.

**A4.2** — **No.** `test` requiere que la ubicación destino exista; si `/metadata/labels` está ausente, el `test` mismo falla y aborta el patch — que es el mismo resultado que una aserción fallida, así que no podés distinguir "ausente" de "presente pero distinto". El RFC 6902 no provee ningún predicado de "existe" o "no existe". Esta es una carencia expresiva genuina de la especificación, y es la razón por la que Kyverno superpone `preconditions` (JMESPath, evaluadas fuera del patch) encima.

**A4.3** — **Usá `patchStrategicMerge` por defecto.** Entiende el esquema de Kubernetes, fusiona mapas, respeta `patchMergeKey` en listas, es idempotente, y soporta las anclas condicionales de Kyverno. **Recurrí a `patchesJson6902` solo cuando strategic merge no puede expresar el cambio**: borrar un campo que el esquema no te deja anular con null, operaciones posicionales sobre listas (insertar en un índice, reordenar, agregar al final de una lista atómica), `move`/`copy`, o mutación condicionada por valor mediante `test`.

**A4.4** — Kyverno resuelve `{{ … }}` antes de parsear el patch. Si `request.object.metadata.labels` está ausente, la expresión no resuelve a nada y la regla **da error** en lugar de evaluar a una condición falsa — una variable sin resolver es una falla de regla, no un valor vacío. `|| ''` provee un fallback de JMESPath para que la expresión siempre dé un valor comparable, permitiendo que la precondition se evalúe limpiamente a `true`.

### Ejercicio 5

**A5.1** — Kyverno registra un mutating webhook para `CREATE` y `UPDATE` por defecto. `kubectl annotate` emite un `PATCH`/`UPDATE` sobre el Deployment; el API server manda el *objeto entero ya modificado* nuevamente por la cadena de mutación. Kyverno reevalúa la regla contra ese objeto, que ya contiene `CLUSTER_TIER` del CREATE, y `add …/env/-` obedientemente agrega una segunda copia. La regla no tiene memoria y la operación no tiene noción de "ya está ahí" — cada admission review agrega una vez más.

**A5.2** — El kubelet construye el entorno del contenedor iterando la lista en orden, así que un duplicado posterior sobrescribe a uno anterior — en efecto, gana el último. "Igual funciona" es peligroso por tres razones: la lista crece sin límite a lo largo de las actualizaciones y eventualmente va a chocar contra el límite de tamaño de objeto de etcd (~1,5 MiB) y empezar a fallar las escrituras; la semántica es un detalle de implementación del kubelet, no un contrato de la API; y hace que el objeto sea irrevisable, enmascarando una deriva genuina entre lo que dice el manifiesto y lo que corre. El mismo bug aplicado a `tolerations`, `volumes` o `imagePullSecrets` produce un recurso que ya no hace round-trip a través de GitOps.

**A5.3** — `match.any[].resources.operations` (Kyverno 1.11+) es materialmente mejor cuando querés angostar el *webhook mismo*: Kyverno deriva las reglas del `MutatingWebhookConfiguration` del bloque de match, así que restringir a `CREATE` significa que el API server nunca llama a Kyverno para updates — menos latencia, menos radio de impacto, menos partes móviles. Una precondition es la única opción cuando la condición no se puede expresar como un campo de match: por ejemplo condicionar sobre `{{ request.userInfo.groups }}`, sobre un valor dentro del objeto, o sobre una consulta a un ConfigMap o al API server mediante un `context`. Las preconditions corren dentro del motor, así que el webhook igual se dispara.

**A5.4** — `EnvVar` en la API de Kubernetes lleva `patchStrategy:"merge"` con `patchMergeKey:"name"`, así que strategic merge trata la lista como un conjunto con clave y fusiona las entradas por `name`. Las listas sin estrategia de merge declarada son **atómicas**: strategic merge reemplaza la lista entera. Para determinar esto en un campo arbitrario, inspeccioná los struct tags del tipo de la API en `k8s.io/api` (`patchStrategy` / `patchMergeKey`), o leé el esquema publicado — `kubectl explain --recursive` y el documento OpenAPI exponen `x-kubernetes-patch-strategy` y `x-kubernetes-patch-merge-key`. Nunca asumas; `containers`, `env`, `volumeMounts` e `imagePullSecrets` fusionan, muchas otras listas no.

**A5.5** — Con un sidecar, el índice `0` es el contenedor que casualmente esté listado primero — determinado por el orden en que se escribió el manifiesto, que no es un contrato. La policy pondría `CLUSTER_TIER` en el contenedor de aplicación de un Deployment y en el shipper de logs del siguiente, y haría silenciosamente lo incorrecto para siempre. La construcción correcta es `mutate.foreach` sobre `request.object.spec.containers`, usando `{{elementIndex}}` en el puntero (Ejercicio 8) — o `patchStrategicMerge` con el ancla `(name): "*"`, que aplica a cada contenedor por esquema.

### Ejercicio 6

**A6.1** — El defaulting de la API, que corre durante la decodificación/conversión *antes* de la cadena de mutating admission. `nginx:latest` hace que `imagePullPolicy` quede por defecto en `Always`; cualquier otro tag o un digest lo dejan por defecto en `IfNotPresent`. La lección general: **escribí los JSON Pointers contra el objeto tal como el API server se lo presenta al webhook, no contra tu YAML fuente.** Confirmá siempre la forma real con `kubectl get <obj> -o yaml`, o volcando el AdmissionReview, antes de asumir que un path existe.

**A6.2** — El RFC 6902 §4.6 define la igualdad de valores estructuralmente, no textualmente. Los objetos son iguales si tienen el mismo conjunto de miembros y el valor de cada miembro es igual — **el orden de los miembros es irrelevante**, así que `{"a":1,"b":2}` es igual a `{"b":2,"a":1}`. Los arrays son iguales solo si tienen la misma cantidad de elementos *y* cada elemento es igual al elemento en la misma posición — **el orden importa**, así que `[1,2]` **no** es igual a `[2,1]`. Esta asimetría es la razón por la que un `test` contra una lista es frágil en Kubernetes, donde el API server puede reordenar o completar por defecto las entradas de una lista.

**A6.3** — Atomicidad: un JSON Patch se aplica como una unidad; si cualquier operación falla, el documento queda enteramente sin cambios. La guarda `test` por lo tanto protege cada operación de la lista, esté relacionada o no. Para aplicar la annotation incondicionalmente, dividí en dos reglas dentro de la misma policy — una regla que contenga solo el `test` + `replace` protegidos, y una segunda que contenga solo el `add` de la annotation. Kyverno evalúa las reglas de forma independiente, así que una falla en una no suprime a la otra.

**A6.4** — Preferí una **`precondition`** cuando la condición involucra datos fuera del documento parcheado (`request.operation`, `request.userInfo`, una consulta de `context` contra un ConfigMap o el API server, un registry de imágenes), cuando necesitás composición booleana (`any`/`all`), cuando necesitás una expresión JMESPath en vez de una comparación de valores, o cuando querés que la regla se *saltee* limpiamente en lugar de dar error. Preferí **`test`** cuando la condición es una igualdad simple contra un valor que ya está dentro del objeto *y* querés la garantía de que una sorpresa a mitad del patch aborte todo atómicamente — `test` se evalúa contra el documento en el momento en que corre el patch, cerrando la brecha entre "chequeado" y "aplicado" que una precondition técnicamente deja abierta.

### Ejercicio 7

**A7.1** — El valor de la variable se inserta en el texto del patch antes del parseo, así que una `/` en el valor se convierte en un **separador estructural de puntero**, no en un carácter literal. Interpolar `{{ request.object.metadata.labels.app }}` dentro de un `path` cuando el valor del label es `team/checkout` produce `/metadata/annotations/team/checkout` — una ubicación completamente distinta. Esto es un riesgo de inyección de policy además de un bug: nunca interpoles valores no confiables dentro de un `path`. Interpolá dentro de `value`; mantené `path` estático, o restringilo a valores que controlás como `{{elementIndex}}`.

**A7.2** — La regla **da error**. En Kyverno una variable sin resolver es una falla dura, no una cadena vacía implícita, y el resultado de la regla pasa a ser `error` en lugar de `skip`. `|| 'default'` es higiene obligatoria porque la diferencia entre "campo ausente" y "campo vacío" no es visible en el texto de la policy, y una policy que da error en un subconjunto de workloads es peor que una que se comporta de forma predecible — con `failurePolicy: Fail` en el webhook, un error de mutación puede impedir que se admitan workloads legítimos.

**A7.3** — **No.** `request.userInfo`, `request.operation` y el resto del contexto `request` vienen del AdmissionReview, que solo existe en tiempo de admisión. Una regla `mutateExisting` corre después, en el background controller, contra un objeto leído del API server — no hay AdmissionReview ni usuario solicitante. En una regla `mutateExisting` el objeto que se muta se direcciona vía `target` (y el objeto disparador vía `request.object`, cuando un disparador la activó); diseñá en consecuencia.

**A7.4** — Cada clave estaba prefijada con dominio (`kca.example.com/created-by`), y el RFC 6901 exige que la `/` dentro de una clave se escape como `~1`. Sin escapar, `add` habría tenido éxito pero creado un objeto anidado `{"kca.example.com": {"created-by": "..."}}` bajo `annotations` — que el API server rechazaría, ya que los valores de annotations deben ser strings, produciendo un error de validación confuso y lejano de la causa real.

### Ejercicio 8

**A8.1** — Elimina la dependencia de posición: la regla se aplica a cada contenedor sin importar cuántos haya ni el orden en que el autor los escribió, así que agregar un sidecar no puede redirigir silenciosamente la mutación al contenedor equivocado. El costo es legibilidad y facilidad de depuración — el puntero ya no es un literal que puedas pegar en `kubectl get -o jsonpath`, y razonar sobre qué iteración produjo qué patch requiere leer también la expresión de `list` del `foreach`. También significa que una lista vacía produce cero operaciones, así que una expresión `list:` mal tipeada falla en silencio en vez de ruidosamente.

**A8.2** — Cuando el loop agrega al final con `/-`, cada iteración alarga el array, así que `{{elementIndex}}` — calculado a partir de la lista *original* — ya no se corresponde con la posición en el documento que se está parcheando. Los índices derivan, y las operaciones que asumían el elemento *n* terminan direccionando el elemento *n+k*. Evitalo no combinando nunca la iteración con `foreach` con operaciones que hacen crecer el mismo array: usá `add` sobre un sub-path escalar (como en este ejercicio), o pasate a `patchStrategicMerge` con el ancla `(name): "*"`, que conoce el esquema y no depende de índices.

**A8.3** — No. `list: "request.object.spec.containers"` itera solo los contenedores principales, y el prefijo de puntero `/spec/containers/` solo los direcciona a ellos. Agregá una segunda entrada de `foreach` con `list: "request.object.spec.initContainers"` y prefijo de path `/spec/initContainers/`, y una tercera para `ephemeralContainers` si están en alcance. Notá que `initContainers` puede estar completamente ausente — protegelo con un fallback (`request.object.spec.initContainers || \`[]\``) para que el loop degrade a cero iteraciones en lugar de dar error.

**A8.4** — Un bloque `preconditions` a nivel de regla decide si corre la **regla entera**, y se evalúa una sola vez contra el admission request. Un bloque `preconditions` anidado dentro de una entrada de `foreach` se evalúa **por elemento**, con `{{element}}` y `{{elementIndex}}` en alcance, y decide si se aplica el patch de ese elemento. El paso 4 usa la forma anidada para que `busybox` se saltee mientras los otros dos contenedores sí se mutan — una precondition a nivel de regla solo podría haber salteado a los tres.

### Ejercicio 9

**A9.1** — `result: pass` solo afirma que la regla se ejecutó con éxito; no dice nada sobre *qué* produjo el patch. Un puntero mal tipeado que aterriza en el campo equivocado, un `value` con el tipo incorrecto, un índice de array corrido en uno, o un error de escapado `~1` pueden todos dar `pass` mientras producen un objeto incorrecto. `patchedResources` compara la salida real del motor contra un manifiesto golden, convirtiendo la mutación en un test de regresión a nivel de bytes. Para JSON Patch en particular — donde todo el riesgo está en *dónde* aterriza el cambio — esta es la aserción que importa.

**A9.2** — Sin API server no puede evaluar (a) entradas de `context` que hacen consultas a la API o a ConfigMaps, y (b) valores derivados del AdmissionReview como `request.userInfo`, `request.operation` y `request.roles`. Ambos se proveen a través de un **values file** (`--values-file` / la sección `variables` de un manifiesto `Test`), que te permite fijar valores de variables y simular distintos usuarios, operaciones y labels de namespace. Tampoco puede ver otros objetos del clúster, así que los targets de `mutateExisting` deben proveerse como recursos.

**A9.3** — `kyverno apply` es el comando *exploratorio* — rápido, imprime el objeto mutado, ideal en un hook de pre-commit o mientras iterás sobre un puntero. `kyverno test` es el comando *asertivo* — compara contra `patchedResources` golden y sale con código distinto de cero ante una discrepancia, así que corresponde a CI como compuerta de merge. Un repositorio sano usa `apply` mientras escribe y `test` para prevenir regresiones; solo `test` tiene un contrato de exit code significativo sobre el cual poner una compuerta.

### Ejercicio 10

**A10.1** — `match` define el **disparador**: el recurso cuya admisión (o la actualización de la policy misma) hace que la regla se dispare. `mutate.targets` define **qué se parchea realmente** — recursos buscados en el clúster, potencialmente de un kind distinto y en un namespace distinto al del disparador. Si omitís `targets`, la regla deja de ser una regla `mutateExisting`: se convierte en una mutación de admisión ordinaria que parchea el recurso matcheado en vuelo.

**A10.2** — Con `mutateExistingOnPolicyUpdate: true`, la regla se dispara tanto (a) cuando la policy se crea o actualiza — barriendo todos los targets existentes — como (b) cada vez que se admite un recurso disparador que matchea. Con `false` (el default), solo aplica el camino del disparador; los recursos existentes quedan intactos hasta que algo dispare la regla. `false` es más seguro en un clúster grande porque un solo `kubectl apply` de la policy emitiría de otro modo un update contra cada objeto que matchea a la vez, potencialmente miles de escrituras a la API, reiniciando masivamente workloads si el patch toca un template de Pod, y haciéndolo antes de que hayas observado el efecto del patch siquiera en un objeto.

**A10.3** — En admisión Kyverno nunca toca el API server: recibe un AdmissionReview, devuelve un JSON Patch en la respuesta, y el **API server** lo aplica bajo la autoridad del *solicitante original*. Kyverno no escribe nada, así que no hace falta RBAC. `mutateExisting` es lo opuesto — el background controller lee y hace `update` de objetos como sí mismo, un cliente autenticado ordinario, y Kubernetes lo autoriza como a cualquier otro. De ahí el ClusterRole agregado del paso 2 y los errores `forbidden` del paso 5.

**A10.4** — Usar `patchStrategicMerge` (`metadata: {labels: {managed-by: kyverno}}`), que crea el mapa si está ausente y fusiona dentro de él si está presente. Si se requiere JSON Patch por otras razones, protegé la regla con una precondition sobre `{{ target.metadata.labels || '' }}` y provisto una regla separada para el caso de mapa ausente — pero para agregar un solo label, strategic merge es sin ambigüedades la herramienta correcta.

### Ejercicio 11

**A11.1** — (1) **`last-applied-patches`** — lo más barato, la lectura de un solo campo; presente significa que matcheó *y* se aplicó, así que ya está. (2) **El objeto mutado en sí** — confirma que el patch aterrizó donde pretendías, atrapando el caso "aplicado pero en el path equivocado" que la annotation por sí sola no revela. (3) **Los logs del controlador** — distinguen "no matcheó" de "matcheó pero el patch dio error", y dan el texto de error subyacente de `evanphx` (`doc is missing path`, `test failed`). (4) **`kyverno apply`** — el más caro pero el más concluyente: una reproducción offline determinista sobre la que podés iterar en segundos sin perturbar el clúster, y el artefacto que adjuntás a un reporte de bug.

**A11.2** — Los PolicyReports registran pass/fail/skip/error por regla, y se generan principalmente para resultados de `validate` y `verifyImages`, donde el resultado *es* un veredicto. El resultado de una mutación no es un veredicto — es un objeto transformado. Una regla de mutate puede reportar `pass` habiendo escrito en un path que no pretendías. La verdad de campo para la mutación es el objeto almacenado (`kubectl get -o yaml`), corroborado por `last-applied-patches` y, para verificación offline, por `patchedResources` en un `kyverno test`.

**A11.3** — `kubectl kyverno apply <policy> --resource <the object as stored>`. Vuelve a correr el motor offline e imprime el resultado por regla explícitamente — una regla que no matchea reporta `skip`, mientras que una regla que matchea con un puntero malo reporta `error` junto con el mensaje de falla del JSON Patch. Un comando, sin estado de clúster, respuesta inequívoca. (Dentro del clúster, `kubectl describe clusterpolicy <name>` más el log del admission controller dan la misma distinción, pero con más ruido.)

</details>

---

## Fuentes

- CNCF KCA curriculum — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- RFC 6902, *JavaScript Object Notation (JSON) Patch* — <https://datatracker.ietf.org/doc/html/rfc6902>
- RFC 6901, *JavaScript Object Notation (JSON) Pointer* — <https://datatracker.ietf.org/doc/html/rfc6901>
- Documentación de Kyverno, reglas de mutación y `patchesJson6902` — <https://kyverno.io/docs/writing-policies/mutate/>
- Documentación de Kyverno, preconditions — <https://kyverno.io/docs/writing-policies/preconditions/>
- Documentación de la CLI de Kyverno — <https://kyverno.io/docs/kyverno-cli/>
- Código fuente y notas de release de Kyverno — <https://github.com/kyverno/kyverno>
- `evanphx/json-patch`, la implementación de RFC 6902 usada tanto por el API server de Kubernetes como por Kyverno — <https://github.com/evanphx/json-patch>
- Documentación de Kubernetes, *Update API Objects in Place Using kubectl patch* — <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/>
- Documentación de Kubernetes, *Dynamic Admission Control* — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>