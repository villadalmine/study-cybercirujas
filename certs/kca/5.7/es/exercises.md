# KCA 5.7 — Variables y llamadas a la API en políticas

## Ejercicios guiados

> **Alcance.** El sistema de variables de Kyverno (expresiones JMESPath `{{ ... }}` sobre el AdmissionReview), el bloque `context` (`configMap`, `apiCall`, `variable`, `globalReference`, `imageRegistry`), el orden de evaluación, la semántica de fallos, y el RBAC que decide si un `apiCall` tiene éxito siquiera. Cada paso de abajo se ejecuta contra un clúster real; nada es teórico.

---

## Lab 0 — Entorno

Necesitás un clúster descartable (kind, k3d, minikube) con cluster-admin, `kubectl`, `helm` y la CLI `kyverno`.

1. Creá el clúster e instalá Kyverno:

```bash
kind create cluster --name kca-vars

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait
```

2. Registrá **exactamente** contra qué versión estás probando — las funcionalidades de variables y de contexto se movieron entre releases, y las respuestas de abajo dependen de eso:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Salida esperada (la tuya puede diferir):

```
ghcr.io/kyverno/kyverno:v1.13.2
```

3. Confirmá los cuatro controladores y sus ServiceAccounts. Solo el controlador de **admission** atiende peticiones de admisión; el controlador **background** reevalúa políticas para recursos existentes; el controlador **reports** escribe PolicyReports:

```bash
kubectl -n kyverno get deploy
kubectl -n kyverno get sa
```

```
NAME                           READY   UP-TO-DATE   AVAILABLE
kyverno-admission-controller   1/1     1            1
kyverno-background-controller  1/1     1            1
kyverno-cleanup-controller     1/1     1            1
kyverno-reports-controller     1/1     1            1
```

4. Instalá la CLI (la misma versión menor que el componente del clúster siempre que sea posible) y verificá:

```bash
kyverno version
```

5. Creá el namespace del laboratorio:

```bash
kubectl create namespace vars-lab
kubectl label namespace vars-lab cost-center=eng-platform
```

**Preguntas — Lab 0**

- **0.1** ¿Por qué importa *cuál* de los cuatro ServiceAccounts se usa cuando una política realiza un `apiCall`?
- **0.2** Una regla que lee `{{ request.userInfo.username }}` no puede ser evaluada por uno de esos controladores. ¿Cuál, y por qué?

---

## Ejercicio 1 — De dónde vienen las variables: el AdmissionReview

Las variables de Kyverno no son globales mágicas. Casi todas son rutas JMESPath dentro del objeto `AdmissionReview` que el API server le envía al webhook, más un puñado de alias de conveniencia que Kyverno deriva de él.

1. Escribí una política que deniegue todo y te imprima de vuelta el contexto de la petición. Este es el truco de depuración más útil de este tema:

```yaml
# 01-var-anatomy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: var-anatomy
  annotations:
    policies.kyverno.io/title: Print the request context
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: echo-request-context
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: >-
          op={{ request.operation }}
          kind={{ request.object.kind }}
          user={{ request.userInfo.username }}
          groups={{ request.userInfo.groups | join(',', @) }}
          sa={{ serviceAccountName || 'none' }}
          sans={{ serviceAccountNamespace || 'none' }}
          ns={{ request.namespace }}
          name={{ request.object.metadata.name || 'none' }}
          images={{ request.object.spec.containers[].image | join(',', @) }}
        deny:
          conditions:
            all:
              - key: "{{ request.operation }}"
                operator: AnyIn
                value:
                  - CREATE
                  - UPDATE
```

```bash
kubectl apply -f 01-var-anatomy.yaml
kubectl get clusterpolicy var-anatomy
```

```
NAME          ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
var-anatomy   true        false        Enforce           True    8s
```

2. Disparala como vos mismo:

```bash
kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server
```

Salida esperada (abreviada — el nombre de usuario depende de tu kubeconfig):

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/demo was blocked due to the following policies

var-anatomy:
  echo-request-context: 'op=CREATE kind=Pod user=kubernetes-admin
    groups=system:masters,system:authenticated sa=none sans=none ns=vars-lab
    name=demo images=nginx:1.27.1'
```

3. Ahora disparala como un ServiceAccount, para que se llene el alias `serviceAccountName`:

```bash
kubectl -n vars-lab create serviceaccount deployer
kubectl -n vars-lab create rolebinding deployer-edit \
  --clusterrole=edit --serviceaccount=vars-lab:deployer

kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server \
  --as=system:serviceaccount:vars-lab:deployer
```

```
...
  echo-request-context: 'op=CREATE kind=Pod
    user=system:serviceaccount:vars-lab:deployer
    groups=system:serviceaccounts,system:serviceaccounts:vars-lab,system:authenticated
    sa=deployer sans=vars-lab ns=vars-lab name=demo images=nginx:1.27.1'
```

4. Comprobá que `background: false` no es opcional acá. Cambialo a `true` y volvé a aplicar:

```bash
sed 's/background: false/background: true/' 01-var-anatomy.yaml | kubectl apply -f -
```

```
The ClusterPolicy "var-anatomy" is invalid: spec.rules[0]: Invalid value: ...:
 variables {{ request.userInfo.username }} are not allowed in background mode.
 Set spec.background=false
```

Restaurá el archivo (`kubectl apply -f 01-var-anatomy.yaml`) antes de continuar.

5. Explorá las mismas rutas sin conexión con la CLI, que evalúa JMESPath contra cualquier documento YAML/JSON:

```bash
cat > pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: demo
  namespace: vars-lab
  labels:
    tier: web
spec:
  containers:
    - name: web
      image: ghcr.io/nginxinc/nginx-unprivileged:1.27
      securityContext:
        runAsNonRoot: true
    - name: sidecar
      image: registry.k8s.io/pause:3.10
EOF

kyverno jp query -i pod.yaml 'spec.containers[].image'
kyverno jp query -i pod.yaml 'spec.containers[?securityContext.runAsNonRoot != `true`].name'
kyverno jp query -i pod.yaml 'metadata.labels."tier"'
```

```
# spec.containers[].image
[
  "ghcr.io/nginxinc/nginx-unprivileged:1.27",
  "registry.k8s.io/pause:3.10"
]
```

6. Listá las funciones no estándar que Kyverno agrega por encima de la especificación JMESPath:

```bash
kyverno jp function | grep -E 'semver_compare|regex_match|time_now_utc|parse_json|x509_decode'
kyverno jp function semver_compare
```

**Preguntas — Ejercicio 1**

- **1.1** En el paso 2 aparece `name=demo`, pero si creás un Pod desde un Deployment la misma expresión a menudo devuelve `none`. ¿Por qué, y qué campo deberías leer en su lugar?
- **1.2** `serviceAccountName` devolvió `deployer`, no `system:serviceaccount:vars-lab:deployer`. ¿De qué se deriva ese alias, y qué le pasa cuando un usuario humano envía la petición?
- **1.3** El paso 4 falló la validación de la política. Enunciá la regla en una oración, y explicá la razón de diseño que hay detrás.
- **1.4** `request.object` es `null` para una operación. ¿Cuál, y qué usás en su lugar?
- **1.5** ¿`kyverno jp query` está hablando con el clúster en el paso 5? ¿Qué implica eso sobre lo que puede y lo que no puede reproducir?

---

## Ejercicio 2 — Variables derivadas: `{{ images }}`, `foreach`, `{{ element }}`

Kyverno pre-parsea cada imagen de contenedor del recurso en una estructura `images`. Hacer esto vos mismo con división de cadenas es un bug clásico de producción.

1. Imprimí la estructura parseada para una referencia de imagen **pelada**:

```yaml
# 02-image-vars.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: image-vars
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: show-image-parts
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: >-
          registry={{ images.containers.web.registry }}
          path={{ images.containers.web.path }}
          name={{ images.containers.web.name }}
          tag={{ images.containers.web.tag || 'none' }}
          digest={{ images.containers.web.digest || 'none' }}
          reference={{ images.containers.web.reference }}
          raw-split={{ request.object.spec.containers[0].image | split(@, '/') | [0] }}
        deny: {}
```

```bash
kubectl apply -f 02-image-vars.yaml

kubectl -n vars-lab run demo --image=nginx:1.27.1 --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"web","image":"nginx:1.27.1"}]}}'
```

2. Compará con una referencia completamente calificada:

```bash
kubectl -n vars-lab run demo --dry-run=server \
  --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --overrides='{"spec":{"containers":[{"name":"web","image":"ghcr.io/nginxinc/nginx-unprivileged:1.27"}]}}'
```

Leé con atención tanto el valor de `registry=` como el de `raw-split=` — no coinciden en el primer caso.

3. Inspeccioná de dónde viene la normalización:

```bash
kubectl -n kyverno get configmap kyverno -o yaml | grep -iE 'defaultRegistry|enableDefaultRegistryMutation'
```

4. Reemplazá el nombre de contenedor fijo `web` por una iteración que funcione para cualquier Pod, incluyendo contenedores init y efímeros. `foreach` introduce dos variables más, `{{ element }}` y `{{ elementIndex }}`:

```yaml
# 03-registry-allowlist.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: only-approved-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      validate:
        message: "Container images must come from an approved registry."
        foreach:
          - list: "request.object.spec.[containers, initContainers, ephemeralContainers][]"
            deny:
              conditions:
                all:
                  - key: "{{ images.containers.\"{{ element.name }}\".registry || images.initContainers.\"{{ element.name }}\".registry }}"
                    operator: AnyNotIn
                    value:
                      - ghcr.io
                      - registry.k8s.io
```

```bash
kubectl apply -f 03-registry-allowlist.yaml
kubectl delete clusterpolicy image-vars

kubectl -n vars-lab run bad --image=nginx:1.27.1 --dry-run=server
kubectl -n vars-lab run good --image=registry.k8s.io/pause:3.10 --dry-run=server
```

Esperado:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/bad was blocked due to the following policies

registry-allowlist:
  only-approved-registries: Container images must come from an approved registry.
```

```
pod/good created (server dry run)
```

**Preguntas — Ejercicio 2**

- **2.1** Para `image: nginx:1.27.1`, ¿qué reportó `registry=` y qué reportó `raw-split=`? Explicá la diferencia y nombrá las dos claves del ConfigMap que la gobiernan.
- **2.2** Una política de lista blanca escrita como `split(image, '/') | [0]` es evadible. Dá una cadena de imagen concreta que la derrote pero que sí sea atrapada por `images.containers.<name>.registry`.
- **2.3** En el paso 4, `request.object.spec.[containers, initContainers, ephemeralContainers][]` es una lista multiselect seguida de un aplanado. ¿Qué se rompería si escribieras solo `request.object.spec.containers[]`, y qué se rompería si omitieras el `[]` final?
- **2.4** Dentro de `foreach`, `{{ element }}` está disponible pero `{{ images }}` sigue siendo el mapa del Pod completo. ¿Por qué la política de arriba tiene que anidar `{{ element.name }}` dentro de otro `{{ }}`?
- **2.5** Esta política define `background: true` mientras que el Ejercicio 1 requería `false`. ¿Qué marca la diferencia?

---

## Ejercicio 3 — Datos externos: contexto `configMap`

El bloque `context` se evalúa **por regla**, después de la selección de `match`/`exclude` y antes de las `preconditions` y del cuerpo `validate`/`mutate`.

1. Creá la fuente de datos:

```yaml
# 04-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: vars-lab
data:
  allowed: "ghcr.io,registry.k8s.io,quay.io"
  team-limits: |
    {
      "eng-platform": { "maxReplicas": 20 },
      "eng-data":     { "maxReplicas": 5  }
    }
```

```bash
kubectl apply -f 04-cm.yaml
```

2. Consumila, incluyendo el caso de JSON-dentro-de-una-clave para el que existe `parse_json`:

```yaml
# 05-cm-context.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist-cm
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: allowlist-from-configmap
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: allowlist
          configMap:
            name: registry-allowlist
            namespace: vars-lab
        - name: limits
          variable:
            jmesPath: "parse_json(allowlist.data.\"team-limits\")"
            default: {}
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      validate:
        message: >-
          Registry not allowed. Permitted: {{ allowlist.data.allowed }}.
          (eng-platform cap is {{ limits."eng-platform".maxReplicas || 'unset' }})
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ images.containers.\"{{ element.name }}\".registry }}"
                    operator: AnyNotIn
                    value: "{{ allowlist.data.allowed | split(@, ',') }}"
```

```bash
kubectl delete clusterpolicy registry-allowlist
kubectl apply -f 05-cm-context.yaml

kubectl -n vars-lab run q --image=quay.io/prometheus/busybox:latest --dry-run=server
kubectl -n vars-lab run d --image=docker.io/library/nginx:1.27.1 --dry-run=server
```

El Pod de `quay.io` es admitido; el de `docker.io` es denegado con el mensaje que lista la lista blanca actual.

3. Cambiá los datos **sin tocar la política** y observá que el comportamiento acompaña:

```bash
kubectl -n vars-lab patch configmap registry-allowlist \
  --type=merge -p '{"data":{"allowed":"ghcr.io,registry.k8s.io"}}'

sleep 5
kubectl -n vars-lab run q2 --image=quay.io/prometheus/busybox:latest --dry-run=server
```

4. Rompela deliberadamente — apuntá el contexto a un ConfigMap que no existe:

```bash
kubectl -n vars-lab delete configmap registry-allowlist
kubectl -n vars-lab run q3 --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 --dry-run=server
```

Observá si el Pod es admitido o rechazado, y después inspeccioná el controlador:

```bash
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=40 | grep -i context
```

Recreá el ConfigMap (`kubectl apply -f 04-cm.yaml`) antes de continuar.

**Preguntas — Ejercicio 3**

- **3.1** La clave es `team-limits`, y la expresión es `allowlist.data."team-limits"`. ¿Por qué son obligatorias las comillas dobles internas, y a qué evaluaría `allowlist.data.team-limits` en JMESPath?
- **3.2** El valor de un ConfigMap siempre es una cadena. ¿Qué cambia `parse_json` respecto de cómo podés indexarlo, y qué le pasa a la regla si el valor no es JSON válido y no hay `default` definido?
- **3.3** En el paso 3 cambiaste el estado del clúster y la decisión cambió en segundos sin volver a aplicar la política. ¿Qué mecanismo hace que eso funcione, y cuál es el riesgo operativo de que el comportamiento de la política viva en un ConfigMap que usuarios comunes del namespace pueden editar?
- **3.4** En el paso 4, ¿el Pod fue admitido o denegado? ¿Qué configuración a nivel de política decide ese resultado, y cómo harías para que un ConfigMap faltante falle *abierto* específicamente para esta regla?
- **3.5** ¿En qué punto del orden de evaluación corre `context` en relación con `match` y `preconditions`, y por qué importa ese orden para la carga del API server?

---

## Ejercicio 4 — `apiCall`: leer el estado vivo del clúster

`context[].apiCall.urlPath` emite un **GET** contra la API de Kubernetes usando el propio ServiceAccount de Kyverno, con las variables sustituidas dentro de la ruta.

1. Denegá Pods en namespaces que no tengan una etiqueta `cost-center` y — en la misma política — copiá esa etiqueta al Pod:

```yaml
# 06-apicall-ns.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: namespace-cost-center
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: copy-cost-center-to-pod
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: costCenter
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: >-
              metadata.labels."cost-center" || 'unassigned'
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              cost-center: "{{ costCenter }}"

    - name: require-cost-center
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      context:
        - name: costCenter
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}"
            jmesPath: >-
              metadata.labels."cost-center" || 'unassigned'
      validate:
        message: >-
          Namespace {{ request.namespace }} has no cost-center label
          (resolved: {{ costCenter }}). Ask platform-eng to label it.
        deny:
          conditions:
            all:
              - key: "{{ costCenter }}"
                operator: Equals
                value: unassigned
```

```bash
kubectl apply -f 06-apicall-ns.yaml
kubectl -n vars-lab run labeled --image=registry.k8s.io/pause:3.10
kubectl -n vars-lab get pod labeled --show-labels
```

```
NAME      READY   STATUS    RESTARTS   AGE   LABELS
labeled   1/1     Running   0          4s    cost-center=eng-platform,run=labeled
```

2. Comprobá el caso negativo:

```bash
kubectl create namespace no-cc
kubectl label namespace no-cc kubernetes.io/metadata.name- --overwrite 2>/dev/null

# widen the policy to the new namespace
kubectl patch clusterpolicy namespace-cost-center --type=json \
  -p '[{"op":"add","path":"/spec/rules/1/match/any/0/resources/namespaces/-","value":"no-cc"}]'

kubectl -n no-cc run orphan --image=registry.k8s.io/pause:3.10 --dry-run=server
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/no-cc/orphan was blocked due to the following policies

namespace-cost-center:
  require-cost-center: 'Namespace no-cc has no cost-center label (resolved:
    unassigned). Ask platform-eng to label it.'
```

3. Verificá el mismo GET a mano, tal como lo ve el API server:

```bash
kubectl get --raw "/api/v1/namespaces/vars-lab" | jq '.metadata.labels'
```

4. Ejercitá la forma de cadena de consulta en la URL, que es como evitás traer colecciones enteras:

```bash
kubectl get --raw "/api/v1/namespaces/vars-lab/pods?labelSelector=run%3Dlabeled" \
  | jq '.items | length'
```

**Preguntas — Ejercicio 4**

- **4.1** Ambas reglas declaran un `context` idéntico. ¿La llamada a la API se hace una vez o dos para un único CREATE de Pod? Explicá por qué, en términos de a qué está acotada una entrada de contexto.
- **4.2** La regla 1 muta y la regla 2 valida. ¿Cuál se evalúa primero, y ese orden está garantizado por el orden de las reglas en este archivo, por los tipos de webhook, o por ninguno de los dos?
- **4.3** `jmesPath: metadata.labels."cost-center" || 'unassigned'` está haciendo dos trabajos. ¿Cuáles son, y qué haría distinto la regla si quitaras el `|| 'unassigned'` y la etiqueta faltara?
- **4.4** En el paso 4 el selector se escribe `labelSelector=run%3Dlabeled`. ¿Por qué el `%3D`, y cuál es la consecuencia práctica de pedir `/api/v1/pods` sin selector en un clúster de 5.000 Pods?
- **4.5** ¿Qué identidad realizó el GET en el paso 1 — el usuario que corrió `kubectl`, u otra cosa? ¿Por qué importa esa distinción para una revisión de seguridad?

---

## Ejercicio 5 — `apiCall` y RBAC: el modo de fallo con el que realmente te vas a topar

1. Revisá, antes de escribir nada, si Kyverno puede leer Secrets:

```bash
kubectl auth can-i list secrets \
  --as=system:serviceaccount:kyverno:kyverno-admission-controller -n vars-lab
```

```
no
```

2. Escribí una política que necesite exactamente ese permiso — el `imagePullSecret` referenciado debe llevar una etiqueta que lo marque como seguro para montar:

```yaml
# 07-pullsecret.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: approved-pull-secrets
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: pull-secret-must-be-approved
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      preconditions:
        all:
          - key: "{{ request.object.spec.imagePullSecrets || `[]` | length(@) }}"
            operator: GreaterThan
            value: 0
      context:
        - name: approved
          apiCall:
            urlPath: "/api/v1/namespaces/{{ request.namespace }}/secrets/{{ request.object.spec.imagePullSecrets[0].name }}"
            jmesPath: >-
              metadata.labels."kyverno.io/pull-secret" || 'false'
      validate:
        message: >-
          imagePullSecret {{ request.object.spec.imagePullSecrets[0].name }} is not
          approved (label kyverno.io/pull-secret=true is missing).
        deny:
          conditions:
            all:
              - key: "{{ approved }}"
                operator: NotEquals
                value: "true"
```

```bash
kubectl apply -f 07-pullsecret.yaml

kubectl -n vars-lab create secret docker-registry regcred \
  --docker-server=ghcr.io --docker-username=bot --docker-password=notreal

kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
```

Esperado — notá que esto **no** es una violación de política, es un fallo de carga de contexto:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/puller was blocked due to the following policies

approved-pull-secrets:
  pull-secret-must-be-approved: 'failed to load context: failed to fetch data for
    APICall: secrets "regcred" is forbidden: User
    "system:serviceaccount:kyverno:kyverno-admission-controller" cannot get
    resource "secrets" in API group "" in the namespace "vars-lab"'
```

3. Otorgá el permiso de la forma soportada — un ClusterRole agregado, nunca editando los roles propios de Kyverno (los upgrades de Helm los sobrescriben):

```yaml
# 08-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:vars-lab-extra
  labels:
    rbac.kyverno.io/aggregate-to-admission-controller: "true"
    rbac.kyverno.io/aggregate-to-background-controller: "true"
    rbac.kyverno.io/aggregate-to-reports-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["subjectaccessreviews"]
    verbs: ["create"]
```

```bash
kubectl apply -f 08-rbac.yaml
sleep 10
kubectl auth can-i get secrets \
  --as=system:serviceaccount:kyverno:kyverno-admission-controller -n vars-lab
```

```
yes
```

4. Reintentá, después aprobá el Secret y reintentá de nuevo:

```bash
kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
# -> denied by the policy, with the intended message

kubectl -n vars-lab label secret regcred kyverno.io/pull-secret=true

kubectl -n vars-lab run puller --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}'
# -> pod/puller created (server dry run)
```

5. Ahora referenciá un Secret que no existe:

```bash
kubectl -n vars-lab run ghost --image=ghcr.io/nginxinc/nginx-unprivileged:1.27 \
  --dry-run=server \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"does-not-exist"}]}}'
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/ghost was blocked due to the following policies

approved-pull-secrets:
  pull-secret-must-be-approved: 'failed to load context: failed to fetch data for
    APICall: secrets "does-not-exist" not found'
```

**Preguntas — Ejercicio 5**

- **5.1** En el paso 2 la petición fue rechazada, y sin embargo las condiciones `deny` propias de la política nunca corrieron. ¿Qué configuración convirtió un error interno en un rechazo, y qué habría hecho `failurePolicy: Ignore` en su lugar?
- **5.2** ¿Por qué se prefiere el enfoque de la etiqueta de agregación frente a `kubectl edit clusterrole kyverno:admission-controller`?
- **5.3** El manifiesto del paso 3 también agrega la etiqueta para los controladores background y reports. ¿Cuándo es necesario, y cuándo es privilegio innecesario?
- **5.4** En el paso 5 el Secret faltante produjo la misma clase de fallo que un 403. Si quisieras "no existe tal Secret ⇒ denegar con un mensaje claro" en lugar de "falló la carga del contexto", ¿cómo reestructurarías la entrada de contexto?
- **5.5** Que Kyverno lea Secrets a nivel de todo el clúster es una superficie real de escalada. Describí concretamente qué podría hacer un atacante capaz de autorar una ClusterPolicy con el RBAC otorgado arriba, y un control que lo limite.

---

## Ejercicio 6 — `apiCall` con POST: delegar la autorización al API server

`apiCall` no es solo GET. Con `method: POST` más `data`, Kyverno construye un cuerpo JSON — el uso canónico es `SubjectAccessReview`, que le pregunta a la propia cadena de autorizadores del API server "¿este usuario puede hacer X?".

1. Condicioná los contenedores privilegiados a un permiso RBAC real:

```yaml
# 09-sar.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: privileged-requires-ns-admin
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: sar-gate
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - vars-lab
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[?securityContext.privileged == `true`] | length(@) }}"
            operator: GreaterThan
            value: 0
      context:
        - name: sar
          apiCall:
            urlPath: "/apis/authorization.k8s.io/v1/subjectaccessreviews"
            method: POST
            data:
              - key: kind
                value: SubjectAccessReview
              - key: apiVersion
                value: authorization.k8s.io/v1
              - key: spec
                value:
                  user: "{{ request.userInfo.username }}"
                  groups: "{{ request.userInfo.groups }}"
                  resourceAttributes:
                    verb: update
                    group: ""
                    resource: namespaces
                    name: "{{ request.namespace }}"
            jmesPath: "status"
      validate:
        message: >-
          Privileged containers require permission to update namespace
          {{ request.namespace }}. Decision for {{ request.userInfo.username }}:
          allowed={{ sar.allowed }} reason={{ sar.reason || 'n/a' }}
        deny:
          conditions:
            all:
              - key: "{{ sar.allowed }}"
                operator: Equals
                value: false
```

```bash
kubectl apply -f 09-sar.yaml
```

2. Como cluster-admin (que *sí puede* actualizar namespaces), el Pod privilegiado es permitido:

```bash
kubectl -n vars-lab run priv --image=registry.k8s.io/pause:3.10 --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"priv","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
```

```
pod/priv created (server dry run)
```

3. Como el ServiceAccount `deployer` (vinculado solo a `edit`), es rechazado:

```bash
kubectl -n vars-lab run priv --image=registry.k8s.io/pause:3.10 --dry-run=server \
  --as=system:serviceaccount:vars-lab:deployer \
  --overrides='{"spec":{"containers":[{"name":"priv","image":"registry.k8s.io/pause:3.10","securityContext":{"privileged":true}}]}}'
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/vars-lab/priv was blocked due to the following policies

privileged-requires-ns-admin:
  sar-gate: 'Privileged containers require permission to update namespace vars-lab.
    Decision for system:serviceaccount:vars-lab:deployer: allowed=false reason='
```

4. Reproducí a mano la interacción exacta con la API para que puedas ver el cuerpo que Kyverno ensambla:

```bash
cat <<'EOF' | kubectl create -f - -o jsonpath='{.status}{"\n"}'
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:vars-lab:deployer
  groups: ["system:serviceaccounts", "system:authenticated"]
  resourceAttributes:
    verb: update
    group: ""
    resource: namespaces
    name: vars-lab
EOF
```

```
{"allowed":false,"denied":false,"reason":""}
```

5. Contrastá con la alternativa declarativa que Kyverno ofrece en `match`:

```yaml
      match:
        any:
          - resources:
              kinds:
                - Pod
            clusterRoles:
              - cluster-admin
```

**Preguntas — Ejercicio 6**

- **6.1** Cada entrada de `data[]` tiene `key` y `value`. ¿Cómo se ve el cuerpo de la petición ensamblado, y por qué hay que suministrar `kind` y `apiVersion` explícitamente?
- **6.2** ¿Por qué `preconditions` está colocado *antes* del `context` en importancia acá, aunque aparezca después de él en el YAML? ¿Qué ahorra en un clúster que crea cientos de Pods por minuto?
- **6.3** `jmesPath: "status"` recorta la respuesta antes de que se almacene. Nombrá dos razones independientes para recortar una respuesta de `apiCall` en lugar de almacenar el objeto completo.
- **6.4** Compará `match.clusterRoles` con el enfoque de SubjectAccessReview. Dá un escenario donde `clusterRoles` devuelve la respuesta equivocada y SAR devuelve la correcta.
- **6.5** `status.allowed` puede ser `false` mientras `status.denied` también es `false`. ¿Qué significa esa combinación, y la política de arriba la trata correctamente?
- **6.6** Esta política debe definir `background: false`. ¿Qué te cuesta eso en términos de reporte sobre Pods que ya existen?

---

## Ejercicio 7 — `globalReference`: cachear una llamada a la API

Un `apiCall` por petición corre en **cada** petición de admisión que coincida. Para datos grandes o que cambian lento, `GlobalContextEntry` hace el fetch una vez por intervalo y comparte el resultado.

1. Descubrí la versión de la API servida en tu clúster — este recurso se movió entre alpha y beta:

```bash
kubectl api-resources | grep -i globalcontext
```

```
globalcontextentries   gctxentries   kyverno.io/v2alpha1   false   GlobalContextEntry
```

2. Creá la entrada (ajustá `apiVersion` a lo que haya reportado el paso 1):

```yaml
# 10-gctx.yaml
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: ingress-hosts
spec:
  apiCall:
    urlPath: "/apis/networking.k8s.io/v1/ingresses"
    refreshInterval: 30s
```

```bash
kubectl apply -f 10-gctx.yaml
kubectl get globalcontextentry ingress-hosts
```

```
NAME            READY   AGE
ingress-hosts   True    12s
```

3. Referenciala desde una política que prohíba nombres de host de Ingress duplicados:

```yaml
# 11-unique-host.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: unique-ingress-host
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: no-duplicate-hosts
      match:
        any:
          - resources:
              kinds:
                - Ingress
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: CREATE
      context:
        - name: existingHosts
          globalReference:
            name: ingress-hosts
            jmesPath: "items[].spec.rules[].host"
      validate:
        message: >-
          Host {{ request.object.spec.rules[0].host }} is already served by another
          Ingress. Known hosts: {{ existingHosts | join(',', @) }}
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.rules[].host }}"
                operator: AnyIn
                value: "{{ existingHosts || `[]` }}"
```

```bash
kubectl apply -f 11-unique-host.yaml

cat <<'EOF' | kubectl -n vars-lab apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: first
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
EOF
```

4. Esperá la ventana de refresco, después intentá una colisión:

```bash
sleep 35
cat <<'EOF' | kubectl -n vars-lab apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: second
spec:
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /checkout
            pathType: Prefix
            backend:
              service:
                name: checkout
                port:
                  number: 80
EOF
```

```
Error from server: error when creating "STDIN": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Ingress/vars-lab/second was blocked due to the following policies

unique-ingress-host:
  no-duplicate-hosts: 'Host shop.example.com is already served by another Ingress.
    Known hosts: shop.example.com'
```

5. Ahora creá `second` **inmediatamente** después de `first`, sin el sleep, con un par de nombres nuevos — y observá que la colisión puede colarse.

**Preguntas — Ejercicio 7**

- **7.1** Reescribí el compromiso en una oración: ¿qué te compra `refreshInterval: 30s`, y qué te cuesta en corrección?
- **7.2** El paso 5 demuestra una condición de carrera. Nombrala con precisión, y explicá por qué *ninguna* verificación de unicidad basada en webhooks de admisión es completamente sólida, ni siquiera con `refreshInterval: 0s`.
- **7.3** `GlobalContextEntry` es de alcance de clúster y guarda lo que sea que devuelva la URL. ¿Qué tenés que revisar antes de apuntar una a `/api/v1/secrets`?
- **7.4** ¿Qué controlador puebla la caché global, y el RBAC de qué ServiceAccount gobierna entonces el fetch?
- **7.5** La regla usa `{{ existingHosts || `[]` }}` como `value`. ¿De qué fallo protege eso en un clúster con cero Ingresses?

---

## Ejercicio 8 — Probar variables sin conexión, y depurarlas en vivo

Probar en vivo cada variable creando Pods es lento y no repetible. La CLI resuelve políticas contra archivos, con valores simulados para todo lo que no pueda computar.

1. Construí un recurso y un archivo de valores que inyecte las variables que la CLI no puede conocer:

```yaml
# resource.yaml
apiVersion: v1
kind: Pod
metadata:
  name: priv
  namespace: vars-lab
spec:
  containers:
    - name: priv
      image: registry.k8s.io/pause:3.10
      securityContext:
        privileged: true
```

```yaml
# values.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
spec:
  globalValues:
    request.operation: CREATE
    request.namespace: vars-lab
    request.userInfo.username: system:serviceaccount:vars-lab:deployer
  policies:
    - name: privileged-requires-ns-admin
      rules:
        - name: sar-gate
          values:
            sar.allowed: false
```

> Si tu CLI rechaza este documento, sacá el nivel `spec:` — las releases más viejas de la CLI usaban una disposición plana de `policies:` / `globalValues:` en la raíz.

2. Ejecutalo:

```bash
kyverno apply 09-sar.yaml --resource resource.yaml --values-file values.yaml --detailed-results
```

```
Applying 1 policy rule(s) to 1 resource(s)...

policy privileged-requires-ns-admin -> resource vars-lab/Pod/priv failed:
1. sar-gate: Privileged containers require permission to update namespace vars-lab...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

3. Cambiá la decisión simulada a `true` y volvé a ejecutar — el resultado debe pasar a `pass: 1`. Ese es todo el punto: la SubjectAccessReview nunca ocurrió.

4. Ejecutá la misma política contra el clúster **real** para que los contextos se resuelvan de verdad:

```bash
kyverno apply 09-sar.yaml --resource resource.yaml --cluster
```

5. Convertila en un test de regresión para CI:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: sar-gate-test
policies:
  - 09-sar.yaml
resources:
  - resource.yaml
variables: values.yaml
results:
  - policy: privileged-requires-ns-admin
    rule: sar-gate
    resource: priv
    kind: Pod
    result: fail
```

```bash
kyverno test .
```

6. Depurá un clúster en vivo cuando una variable se comporta mal. Estos tres comandos cubren casi todos los casos:

```bash
# 1. the controller's own account of the failure
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
  | grep -iE 'failed to load context|variable substitution|jmespath'

# 2. what the policy engine recorded for existing resources
kubectl -n vars-lab get policyreport -o wide

# 3. events attached to the offending resource
kubectl -n vars-lab get events --field-selector reason=PolicyViolation
```

**Preguntas — Ejercicio 8**

- **8.1** ¿Por qué la CLI no puede resolver `sar.allowed` por sí sola en el paso 2, y qué flag cambia eso?
- **8.2** `globalValues` frente a un bloque `values` por regla: ¿cuándo necesitás la forma por regla?
- **8.3** `kyverno test` te da un contrato de pasa/falla en CI. ¿Qué clase de bug *no* atrapa, por más casos que escribas?
- **8.4** Una regla no produce violaciones silenciosamente en producción pero pasa en CI. Enumerá las tres causas más probables relacionadas con variables, en el orden en que las revisarías.
- **8.5** Una regla de política con un contexto `configMap` reporta `skip` en un PolicyReport en lugar de `fail`. ¿Qué significa `skip` acá, y qué bloque lo produce habitualmente?

---

## Limpieza

```bash
kubectl delete clusterpolicy var-anatomy registry-allowlist-cm namespace-cost-center \
  approved-pull-secrets privileged-requires-ns-admin unique-ingress-host --ignore-not-found
kubectl delete globalcontextentry ingress-hosts --ignore-not-found
kubectl delete clusterrole kyverno:vars-lab-extra --ignore-not-found
kubectl delete namespace vars-lab no-cc --ignore-not-found
kind delete cluster --name kca-vars
```

---

## Fuentes de referencia

- Kyverno — Variables: https://kyverno.io/docs/writing-policies/variables/
- Kyverno — Fuentes de datos externas (`configMap`, `apiCall`, `imageRegistry`, Global Context): https://kyverno.io/docs/writing-policies/external-data-sources/
- Kyverno — JMESPath y filtros personalizados: https://kyverno.io/docs/writing-policies/jmespath/
- Kyverno — Preconditions: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — Instalación y personalización de RBAC (etiquetas de agregación de roles): https://kyverno.io/docs/installation/customization/
- Kyverno CLI (`apply`, `test`, `jp`): https://kyverno.io/docs/kyverno-cli/
- Especificación JMESPath (operadores, precedencia, literales): https://jmespath.org/specification.html
- Kubernetes — Autorización / SubjectAccessReview: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — Control de admisión dinámico (`failurePolicy`, orden de webhooks): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- CNCF — Currícula KCA: https://github.com/cncf/curriculum

---

<details>
<summary><strong>Respuestas</strong></summary>

### Lab 0

**0.1** Un `apiCall` es ejecutado por el controlador que esté evaluando la regla, usando el ServiceAccount de ese controlador — `kyverno-admission-controller` durante la admisión, `kyverno-background-controller` durante la mutación/generación en background, `kyverno-reports-controller` al producir reportes. Tienen RBAC distinto. Por lo tanto una política puede funcionar perfecto en tiempo de admisión y fallar en los escaneos de background con un 403, que es la razón por la que los permisos extra suelen otorgarse a los tres mediante etiquetas de agregación.

**0.2** El controlador de background (y el de reports). `request.userInfo`, `request.operation` y los alias `serviceAccountName`/`serviceAccountNamespace` existen solo dentro de un AdmissionReview. Un escaneo de background reevalúa un recurso que ya existe; no hay peticionario ni operación, así que esas variables no tienen valor. Kyverno rechaza semejante política en la admisión salvo que tenga `spec.background: false`.

### Ejercicio 1

**1.1** `kubectl run` define `metadata.name`. Un Pod creado por un ReplicaSet se envía con `metadata.generateName` (p. ej. `web-7c9f8d-`) y un `metadata.name` vacío — el API server asigna el nombre final *después* de la admisión. Leé `request.object.metadata.generateName` como alternativa, o hacé match sobre el recurso controlador (Deployment) en lugar del Pod. Nunca construyas lógica de política que asuma que existe un nombre de Pod en tiempo de admisión.

**1.2** `serviceAccountName` y `serviceAccountNamespace` son alias de conveniencia que Kyverno deriva parseando `request.userInfo.username` cuando tiene la forma `system:serviceaccount:<namespace>:<name>`. Para un usuario humano (`kubernetes-admin`) el parseo no aplica y las variables quedan vacías — por eso la política escribió `{{ serviceAccountName || 'none' }}`. Usarlas sin protección es una causa común de fallos de sustitución.

**1.3** Las reglas que referencian variables exclusivas del AdmissionReview (`request.userInfo.*`, `request.operation`, `serviceAccountName`, `serviceAccountNamespace`) requieren `spec.background: false`. La razón es la solidez: el escaneo en background reevalúa recursos almacenados donde no existe peticionario, así que la regla no podría evaluarse de forma consistente. Kyverno lo impone en la admisión de la política en vez de producir reportes silenciosamente erróneos.

**1.4** `DELETE`. En un borrado el API server envía el recurso que se está eliminando en `oldObject`, y `object` es null. `UPDATE` llena ambos — `oldObject` es el estado previo, que es contra lo que comparás para detectar *cambios* (p. ej. "esta etiqueta puede definirse en la creación pero nunca modificarse").

**1.5** No. `kyverno jp query` es un evaluador JMESPath puro sobre un archivo local. Reproduce la semántica de las expresiones — proyecciones, filtros, `||`, pipes, las funciones personalizadas de Kyverno — pero no sabe nada de `request.*`, `images`, ni de ninguna entrada de `context`. Usalo para depurar la *expresión*, y `kyverno apply`/un clúster real para depurar los *datos*.

### Ejercicio 2

**2.1** `registry=docker.io` mientras que `raw-split=nginx:1.27.1`. Kyverno normaliza cada referencia de imagen en `registry`/`path`/`name`/`tag`/`digest`/`reference` antes de que corra la regla, completando el registry por defecto para las referencias peladas; la división cruda de la cadena simplemente devuelve el primer segmento de ruta, que para una imagen pelada es el repositorio, no un registry. El comportamiento está gobernado por `defaultRegistry` y `enableDefaultRegistryMutation` en el ConfigMap `kyverno` del namespace `kyverno`.

**2.2** Cualquier imagen pelada de Docker Hub la derrota: `nginx:1.27.1` se divide en `nginx`, que no está en la lista blanca, así que es *atrapada* — pero `ghcr.io.evil.example.com/nginx:1` se divide en `ghcr.io.evil.example.com` (atrapada), mientras que `busybox` se divide en `busybox`. La evasión confiable va en la otra dirección: una verificación de lista blanca escrita como "¿la cadena *empieza con* `ghcr.io`?" deja pasar `ghcr.io.attacker.net/x`. El `registry` parseado es exacto e inequívoco; el manejo de referencias de imagen como cadenas no lo es. Las referencias fijadas por digest y las calificadas con puerto (`localhost:5000/x`) también rompen la división ingenua.

**2.3** `spec.containers[]` por sí solo ignora `initContainers` y `ephemeralContainers` — un contenedor init privilegiado o un contenedor efímero de depuración pasa directo por delante de la política. Omitir el `[]` final te deja con una lista *de listas* (`[[c1,c2],[i1],null]`), así que `element` sería un array y `element.name` sería null en cada iteración.

**2.4** `images` está indexado por nombre de contenedor, y la clave solo se conoce por iteración. `images.containers."{{ element.name }}".registry` es sustitución anidada: Kyverno resuelve primero el `{{ element.name }}` interno, produciendo una clave concreta, y después evalúa la expresión externa. Sin el anidado estarías buscando una clave literal llamada `element.name`.

**2.5** La regla 3 usa solo `request.object` y el derivado `images`, ambos reconstruibles por Kyverno a partir de un recurso almacenado durante un escaneo en background. Sin `userInfo` y sin `operation`, la evaluación en background es legal — y deseable, porque entonces obtenés PolicyReports para los Pods que ya existen.

### Ejercicio 3

**3.1** Los identificadores JMESPath no pueden contener `-`; sin comillas, `team-limits` se parsea como un token estilo resta y falla o devuelve null. Los identificadores entrecomillados (`."team-limits"`) son la vía de escape de la especificación para claves con guiones, puntos, barras o dígitos iniciales — lo que cubre la mayoría de las claves reales de anotaciones y ConfigMaps de Kubernetes.

**3.2** Los valores de un ConfigMap son cadenas, así que `allowlist.data."team-limits"` es una cadena larga sobre la que solo podés hacer coincidencia de patrones. `parse_json` la convierte en una estructura que podés indexar (`limits."eng-platform".maxReplicas`). Si la cadena no es JSON válido, la expresión da error, la entrada de contexto falla al cargar y — con el `failurePolicy: Fail` por defecto — la petición es rechazada. `default: {}` en la entrada `variable` convierte ese fallo duro en un objeto vacío, tras lo cual `|| 'unset'` en el mensaje mantiene legible la salida.

**3.3** Kyverno observa los ConfigMaps a través de un informer y resuelve la entrada en tiempo de petición desde la caché, así que las ediciones surten efecto en segundos sin tocar la política. El riesgo es la otra cara de la misma propiedad: el ConfigMap ahora es parte de tu control de seguridad, y cualquiera con `edit` en ese namespace puede ampliar la lista blanca sin un cambio de política y sin rastro de auditoría de política. Mantené los ConfigMaps de datos de política en un namespace donde solo puedan escribir los dueños de la plataforma, y protegé ese ConfigMap con otra política de Kyverno.

**3.4** Denegado. El `spec.failurePolicy: Fail` por defecto significa que un error interno — incluido un contexto que no puede cargarse — se manifiesta como un rechazo, así que un ConfigMap borrado se convierte en una caída de Pods a nivel de todo el namespace. Para fallar abierto en una sola regla, definí `spec.failurePolicy: Ignore` en esa política (es de alcance de política, no de regla, así que aislá la regla en su propia ClusterPolicy). La alternativa más segura es mantener `Fail` y hacer que los *datos* sean opcionales con una entrada de contexto `variable` que lleve un `default`.

**3.5** El orden es: selección de `match`/`exclude` → resolución de `context` → `preconditions` → cuerpo de la regla (`validate`/`mutate`/`generate`). El contexto se resuelve antes que las preconditions, así que una precondition no puede salvarte del costo ni del fallo de una entrada de contexto. Para saltear `apiCall`s costosos en peticiones irrelevantes tenés que estrechar el `match` (kinds, namespaces, selectores) — ese es el único filtro que corre antes.

### Ejercicio 4

**4.1** Dos veces. Una entrada de `context` está acotada a la regla que la declara; no hay compartición entre reglas dentro de una política, ni deduplicación de URLs idénticas. Dos reglas que necesitan la misma consulta significan dos GETs por petición de admisión. Si el costo importa, fusioná las reglas o mové los datos a un `GlobalContextEntry`.

**4.2** La regla de mutación corre primero, pero no por el orden en el archivo — Kubernetes corre *todos* los webhooks de mutación antes de *cualquier* webhook de validación, y Kyverno se registra por separado para cada uno. Dentro de una única invocación del webhook de Kyverno las reglas aplicables de ese tipo se procesan en orden, pero el ordenamiento mutate/validate es una propiedad de la cadena de admisión. La consecuencia práctica: las reglas de validación siempre ven el objeto completamente mutado, incluyendo mutaciones de otras políticas y de otros controladores de admisión.

**4.3** Extrae un campo del objeto Namespace (manteniendo en memoria solo lo que la regla necesita) y provee un valor de reserva para que una etiqueta faltante produzca el centinela `'unassigned'` en vez de null. Sin el reserva, `costCenter` sería null: la comparación del `deny` contra `unassigned` nunca sería verdadera, la regla de validación pasaría en silencio, y la regla de mutación intentaría definir una etiqueta con un valor null — un fallo de sustitución que, con `failurePolicy: Fail`, bloquea el Pod por una razón que parece no tener relación.

**4.4** `%3D` es la codificación porcentual de `=`; el valor va dentro de una cadena de consulta de URL, así que el separador debe escaparse o el selector queda malformado. Traer `/api/v1/pods` sin filtrar hace que el API server serialice cada Pod del clúster en **cada petición de admisión que coincida** — megabytes de JSON, por petición, compitiendo con el propio trabajo del API server. Ese patrón es la forma individual más común en que una política de Kyverno degrada un plano de control; usá siempre un `labelSelector`/`fieldSelector`, una ruta con namespace, o un `GlobalContextEntry`.

**4.5** El GET lo realizó `system:serviceaccount:kyverno:kyverno-admission-controller`, no el usuario peticionario. Esta es una superficie de diputado confundido: el autor de la política elige la URL, y la identidad de Kyverno — no la del peticionario — la autoriza. Cualquiera capaz de crear o modificar una ClusterPolicy puede leer todo lo que Kyverno puede leer y exfiltrarlo a través de un `deny.message`. Tratá el acceso de escritura a ClusterPolicy como equivalente al RBAC propio de Kyverno.

### Ejercicio 5

**5.1** `spec.failurePolicy`, que por defecto es `Fail`. Un error de carga de contexto es un error del webhook, y `Fail` le dice al API server que rechace la petición cuando el webhook no puede producir un veredicto. Con `failurePolicy: Ignore`, el API server registraría el error y admitiría el Pod — la verificación del pull-secret simplemente no existiría en silencio, lo que para un control de seguridad suele ser peor que la caída.

**5.2** Los ClusterRoles propios de Kyverno (`kyverno:admission-controller`, etc.) son objetos gestionados: un `helm upgrade` o un reaplicado de los manifiestos de instalación revierte las ediciones manuales, y tu política empieza a fallar en el momento menos conveniente. Kyverno declara esos roles como agregados, así que cualquier ClusterRole etiquetado con `rbac.kyverno.io/aggregate-to-<controller>: "true"` ve sus reglas fusionadas automáticamente y sobrevive a los upgrades. También es auditable: tus permisos extra viven en un único objeto que es tuyo.

**5.3** Necesario cuando la misma regla también se evalúa fuera de la admisión — reglas con `background: true` (controlador background) y reglas que aparecen en PolicyReports (controlador reports) hacen sus propias cargas de contexto. Innecesario cuando la regla es `background: false` y solo de admisión, como en este ejercicio: otorgar lectura de Secrets a los tres controladores amplía el radio de impacto sin ganancia funcional. Otorgá por controlador, según la necesidad.

**5.4** No pongas la consulta volátil en el camino de una entrada obligatoria. Traé la *colección* con un selector y reducila vos mismo, suministrando un valor por defecto:

```yaml
- name: secrets
  apiCall:
    urlPath: "/api/v1/namespaces/{{ request.namespace }}/secrets"
    jmesPath: "items[].metadata.name"
- name: approved
  variable:
    jmesPath: "contains(secrets, '{{ request.object.spec.imagePullSecrets[0].name }}')"
    default: false
```

Después `deny` cuando `approved == false` con un mensaje que nombre el Secret. Una entrada `variable` con `default` es el mecanismo general para convertir "no se pudo resolver" en "se resolvió a un valor conocido".

**5.5** Cualquiera que pueda crear una ClusterPolicy puede escribir una regla que haga match con cualquier recurso, agregar un contexto `apiCall` a `/api/v1/namespaces/kube-system/secrets`, y emitir el contenido en un `deny.message` o en una anotación de `mutate` — Kyverno lee con sus propias credenciales y le devuelve el resultado al peticionario. Controles: (a) tratar la escritura de `clusterpolicies` como equivalente a cluster-admin en la revisión de RBAC; (b) otorgar el ClusterRole extra de forma acotada con `resourceNames` sobre Secrets específicos en lugar de `list` sobre todos; (c) exigir que las políticas lleguen por GitOps con revisión, y bloquear las escrituras directas de ClusterPolicy.

### Ejercicio 6

**6.1** Cada entrada de `data[]` se convierte en un campo de nivel superior del cuerpo JSON, así que las tres entradas se ensamblan en `{"kind":"SubjectAccessReview","apiVersion":"authorization.k8s.io/v1","spec":{...}}`. Kyverno hace POST de un cuerpo opaco a la URL que nombraste; no infiere el tipo de recurso a partir de la ruta, así que los campos de TypeMeta deben proveerse explícitamente o el API server rechaza la petición como un objeto no reconocido.

**6.2** Porque la carga del contexto ocurre para cada petición que sobrevive al `match`, y una SubjectAccessReview por POST es un viaje de ida y vuelta al API server por el camino de escritura más una evaluación completa del autorizador. `match` no puede expresar "tiene un contenedor privilegiado", así que en un clúster con carga esta política paga ese costo en cada Pod. La mitigación es mantener el `match` tan estrecho como permita la API (kinds, namespaces, `selector`) y aceptar que `preconditions` filtra el *cuerpo*, no el *contexto*. Si el costo es inaceptable, dividí en dos políticas donde la barata anota y la cara hace match sobre la anotación.

**6.3** Primero, memoria y carga útil: la respuesta entera se mantiene por petición en vuelo, y las respuestas sin límite son un riesgo de OOM del controlador (Kyverno también limita el tamaño de las respuestas). Segundo, radio de impacto y claridad: almacenar solo `status` significa que un `deny.message` no puede filtrar accidentalmente el objeto completo, y la dependencia de datos de la regla es explícita y revisable. Una tercera razón en la práctica: recortar convierte un cambio de esquema aguas arriba en un null evidente en vez de en una estructura sutilmente distinta en el fondo de una comparación.

**6.4** `match.clusterRoles` depende de que Kyverno resuelva por sí mismo los bindings del peticionario, a partir de objetos RBAC, usando los grupos del AdmissionReview. SubjectAccessReview le pregunta al API server, que consulta la cadena **entera** de autorizadores configurada en orden — Node, RBAC, ABAC, y cualquier webhook de autorización. En un clúster gestionado donde los permisos se otorgan mediante un webhook de autorización externo (una integración con el IAM de la nube), `match.clusterRoles` no ve ningún ClusterRole coincidente y trata a un administrador de plataforma plenamente autorizado como si no tuviera privilegios; SAR devuelve `allowed: true`. SAR además maneja correctamente la impersonación y los roles agregados sin que reimplementes la resolución.

**6.5** `allowed: false, denied: false` significa *ningún autorizador permitió explícitamente la acción, y ninguno la denegó explícitamente* — el resultado por defecto de "sin opinión", que el API server trata como una denegación. `denied: true` es más fuerte: un autorizador se negó activamente, y los autorizadores posteriores no pueden anularlo. La política es correcta para su propósito, porque condiciona sobre `allowed == false`, que cubre tanto "no permitido" como "denegado explícitamente". Condicionar sobre `denied == true` sería el bug clásico: dejaría pasar a todo usuario sin permiso.

**6.6** Ninguna cobertura de PolicyReport para los Pods existentes y ninguna reevaluación en background. Si ya existe un Pod privilegiado — creado antes de la política, o por un controlador cuyo SA sí tiene derechos de actualización de namespace — esta regla nunca lo va a señalar. Emparejá la regla SAR con una segunda regla `background: true` que reporte sobre contenedores privilegiados sin la dimensión de RBAC, para conservar visibilidad sobre el parque instalado.

### Ejercicio 7

**7.1** Te compra una carga acotada y predecible sobre el API server (un LIST por intervalo sin importar el volumen de admisión, más una lectura rápida en memoria por petición) al costo de tomar decisiones contra datos con hasta 30 segundos de antigüedad.

**7.2** Una condición de carrera time-of-check-to-time-of-use (TOCTOU). Incluso con cero antigüedad no es sólida, porque dos Ingresses en colisión pueden admitirse concurrentemente: cada petición se valida contra un estado del clúster que todavía no contiene al otro, y ningún webhook ve el objeto aún no persistido del otro. El control de admisión es por petición y no tiene una vista transaccional del almacén. La unicidad genuina debe imponerse donde existe serialización — una clave única en el nombre del recurso, un controlador que reconcilia y reporta el conflicto, o la propia unicidad de nombres del API server.

**7.3** Si el controlador de background/reports está autorizado a leerlos y — más importante aún — si aceptás que cada Secret del clúster queda residente en la memoria de Kyverno de forma continua, no solo durante las peticiones que lo necesitan, y alcanzable por cualquier política escrita posteriormente vía `globalReference`. Restringí la URL al namespace y selector más pequeños que satisfagan el requisito, o directamente no uses Secrets como datos de política.

**7.4** El controlador de Kyverno responsable del mantenimiento del contexto global realiza el fetch periódico — no el camino del webhook de admisión — así que el fetch lo autoriza el ServiceAccount de ese controlador (en la disposición Helm por defecto, el del controlador background). Justamente por eso el ClusterRole del Ejercicio 5 también lleva la etiqueta `aggregate-to-background-controller`: que `kubectl get globalcontextentry` muestre `READY: False` es casi siempre un fallo de RBAC ahí, y `kubectl describe` sobre la entrada lo indica.

**7.5** Si el LIST devuelve `items: []`, la proyección `items[].spec.rules[].host` produce null en lugar de una lista vacía. Comparar contra null en un operador `AnyIn` es un fallo de sustitución/evaluación, así que el primerísimo Ingress en un clúster vacío sería rechazado con un error opaco. `|| \`[]\`` lo fuerza a una lista vacía, y `AnyIn []` es correctamente falso.

### Ejercicio 8

**8.1** `sar.allowed` viene de un POST en vivo a un API server en ejecución; sin conexión al clúster la CLI no puede hacerlo, así que el valor debe suministrarlo el archivo de valores. `--cluster` hace que la CLI resuelva los contextos contra tu contexto de kubeconfig actual — `apiCall`s reales, ConfigMaps reales, consultas reales al registry — usando *tus* credenciales en lugar del ServiceAccount de Kyverno, lo que es en sí una diferencia digna de recordar cuando los resultados divergen de los del clúster.

**8.2** Cuando el mismo nombre de variable debe tener valores distintos en reglas distintas o para políticas distintas dentro de una sola corrida de test — por ejemplo dos reglas que leen ambas una entrada de contexto llamada `data`, o probar las ramas de permitir y denegar de una variable en un mismo archivo. `globalValues` es un mapa plano aplicado en todas partes; los `values` por regla están acotados y lo sobrescriben.

**8.3** Cualquier cosa que dependa de datos que el archivo de test simula. `kyverno test` prueba que tus *expresiones y la lógica de las reglas* son correctas dadas ciertas entradas asumidas; no puede probar que las entradas asumidas coincidan con la realidad — que la clave del ConfigMap siga existiendo, que la ruta de la API siga devolviendo esa forma, que el ServiceAccount de Kyverno siga autorizado, o que el CRD aguas arriba no haya renombrado un campo. Esos fallos aparecen solo contra un clúster real, que es para lo que sirve `kyverno apply --cluster` en un entorno de staging.

**8.4** (1) El `match` es más estrecho de lo que creés — `kinds` equivocados, una lista de namespaces que omite producción, o un `selector` que ya no coincide; la regla nunca corre, así que no hay nada que reportar. (2) Una entrada de contexto que resuelve a null en producción — una clave de ConfigMap renombrada, una etiqueta ausente — dejando insatisfacible una condición `deny`, particularmente donde un `default` sustituye silenciosamente un valor benigno. (3) `background: false` en una regla que esperabas ver en los reportes, o `validationFailureAction: Audit` donde asumías `Enforce`. Revisá en ese orden: selección, después datos, después modo — es el camino de diagnóstico de lo más barato a lo más caro.

**8.5** `skip` significa que la regla hizo match con el recurso pero no fue evaluada hasta un veredicto — abrumadoramente porque las `preconditions` evaluaron a falso. Es un estado sano y esperado, no un error; `error` es el estado para un contexto que falló al cargar. Distinguirlos en los reportes importa: un muro de `skip` normalmente significa que una precondition está mal, mientras que un muro de `error` significa RBAC o una fuente de datos faltante.

</details>