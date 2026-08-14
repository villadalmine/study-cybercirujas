# Tema 6.2 — PolicyExceptions

## Ejercicios guiados

> **Alcance.** Estos ejercicios cubren el recurso `PolicyException` en Kyverno: habilitar la funcionalidad, escribir excepciones, acotar su alcance, eximir controles individuales de los Pod Security Standards, gobernar las excepciones mediante políticas, probarlas en CI con la Kyverno CLI y diagnosticar los casos en que una excepción no hace nada de forma silenciosa.
>
> **Disciplina.** Cada paso que afirma un hecho dependiente de la versión está escrito como un comando que ejecutás, no como una afirmación en la que confiás. La superficie de excepciones de Kyverno cambió entre 1.9 → 1.11 → 1.13, así que *verificar en tu cluster* es parte del ejercicio, no una advertencia legal.

---

## Requisitos previos del laboratorio

| Componente | Versión usada aquí | Notas |
|---|---|---|
| Kubernetes | 1.29+ | `kind` alcanza; no hace falta proveedor cloud |
| Kyverno | 1.11+ (se recomienda 1.13+) | instalado con el chart de Helm `kyverno/kyverno` 3.x |
| `kubectl` | acorde al cluster | |
| Kyverno CLI | mismo minor que el cluster | se usa en el Ejercicio 7 |

Necesitás cluster-admin sobre un cluster descartable. No ejecutes el Ejercicio 6 contra un cluster compartido: instala una política en modo `Enforce` sobre el propio kind `PolicyException`.

---

## Ejercicio 1 — Crear el cluster y comprobar si la funcionalidad está activa

Las PolicyExceptions están detrás de un flag del controlador. En algunas versiones viene desactivado por defecto; en otras, activado. Nunca lo asumas: leé el Deployment en ejecución.

1. Creá el cluster y los namespaces que vas a usar:

```bash
kind create cluster --name kca-62

kubectl create namespace legacy-monitoring
kubectl create namespace team-a
kubectl create namespace kyverno-exceptions
```

2. Inspeccioná los values del chart *antes* de instalar, para conocer los nombres exactos de las claves que expone tu versión del chart:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm show values kyverno/kyverno | grep -A 8 'policyExceptions'
```

Salida representativa:

```yaml
  policyExceptions:
    # -- Enables the feature
    enabled: false
    # -- Restrict PolicyExceptions to a single namespace
    namespace: ''
```

3. Instalá Kyverno con la funcionalidad explícitamente habilitada y **sin restricción por ahora** (la vas a restringir en el Ejercicio 5):

```bash
helm install kyverno kyverno/kyverno \
  -n kyverno --create-namespace \
  --set features.policyExceptions.enabled=true

kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

4. Comprobá que el flag llegó al contenedor. Esta es la verificación más útil cuando una excepción "no funciona":

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n' | grep -i exception
```

```
"--enablePolicyException=true"
```

5. Confirmá que el CRD está servido, y anotá la versión de la API y el nombre corto:

```bash
kubectl api-resources | grep -i policyexception
```

```
policyexceptions   polex   kyverno.io/v2   true   PolicyException
```

6. Leé el esquema desde el cluster en lugar de hacerlo de memoria:

```bash
kubectl explain policyexception.spec
kubectl explain policyexception.spec.exceptions
```

### Comprobá tu comprensión

- **Q1.** El flag `enablePolicyException` se pasa a más de un controlador de Kyverno. ¿Qué controladores lo necesitan, y qué se rompe si lo configurás solo en el admission controller?
- **Q2.** `kubectl api-resources` muestra `NAMESPACED = true` para `PolicyException`. ¿Por qué un kind namespaced es una decisión de diseño deliberada para un mecanismo de excepciones, dado que `ClusterPolicy` es cluster-scoped?
- **Q3.** Ejecutás `kubectl get polex -A` y obtenés `No resources found`, pero un compañero insiste en que aplicó una. Nombrá dos causas distintas que produzcan exactamente esa salida.

---

## Ejercicio 2 — Instalar una política enforcing y observar el bloqueo

Necesitás algo *de lo cual* eximir. Construí primero la línea base y confirmá que efectivamente deniega.

1. Escribí la política:

```yaml
# disallow-host-path.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
  annotations:
    policies.kyverno.io/title: Disallow hostPath
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      HostPath volumes let a Pod read and write the node filesystem, which
      collapses the container boundary. This rule forbids them cluster-wide;
      exemptions are granted only through a PolicyException.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: host-path
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: >-
          HostPath volumes are forbidden. The field spec.volumes[*].hostPath
          must be unset.
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
```

> **Nota sobre versiones.** Kyverno 1.13 deprecia el `validationFailureAction` a nivel de spec en favor del `spec.rules[].validate.failureAction` por regla. Verificá cuál sirve tu cluster antes de copiar esto a producción:
> ```bash
> kubectl explain clusterpolicy.spec.rules.validate.failureAction
> ```

2. Aplicala y confirmá que está lista:

```bash
kubectl apply -f disallow-host-path.yaml
kubectl get clusterpolicy disallow-host-path
```

```
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    8s    Ready
```

3. Listá las reglas que Kyverno compiló realmente, incluidas las que no escribiste:

```bash
kubectl get clusterpolicy disallow-host-path -o jsonpath='{.status.autogen.rules[*].name}' ; echo
```

```
autogen-host-path autogen-cronjob-host-path
```

4. Intentá crear un Pod que la viole:

```yaml
# node-exporter.yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-exporter
  namespace: legacy-monitoring
  labels:
    app: node-exporter
spec:
  containers:
    - name: node-exporter
      image: quay.io/prometheus/node-exporter:v1.8.2
      args: ["--path.rootfs=/host"]
      volumeMounts:
        - name: rootfs
          mountPath: /host
          readOnly: true
  volumes:
    - name: rootfs
      hostPath:
        path: /
        type: Directory
```

```bash
kubectl apply -f node-exporter.yaml
```

```
Error from server: error when creating "node-exporter.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/legacy-monitoring/node-exporter was blocked due to the following policies

disallow-host-path:
  host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. rule host-path failed at path
    /spec/volumes/0/hostPath/'
```

5. Registrá el nombre exacto de la regla que aparece en el mensaje de denegación — `host-path`. Lo vas a necesitar textual.

### Comprobá tu comprensión

- **Q4.** La política solo matchea `kind: Pod`, y sin embargo `status.autogen.rules` lista dos reglas extra. ¿Qué las genera, y qué problema crea eso para la excepción que estás por escribir?
- **Q5.** El webhook del error se llama `validate.kyverno.svc-fail`. ¿Qué te dice el sufijo `-fail` sobre el `failurePolicy` del webhook, y qué le pasaría a la creación de Pods en todo el cluster si el admission controller de Kyverno quedara inalcanzable?
- **Q6.** ¿Por qué este ejercicio insiste en que copies el nombre de la regla desde el *mensaje de denegación* y no desde el YAML que escribiste?

---

## Ejercicio 3 — Escribir tu primera PolicyException

1. Escribí una excepción acotada lo más estrechamente posible: una política, una regla, un namespace, un patrón de nombre:

```yaml
# polex-node-exporter.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-node-exporter-hostpath
  namespace: kyverno-exceptions
  annotations:
    exceptions.corp.io/owner: platform-observability
    exceptions.corp.io/ticket: PLAT-4471
    exceptions.corp.io/justification: >-
      node-exporter must read /proc, /sys and the root filesystem from the node.
      Compensating control: the mount is readOnly and the DaemonSet runs with a
      dedicated ServiceAccount with no API permissions.
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - legacy-monitoring
          names:
            - node-exporter*
```

> Si tu cluster sirve `kyverno.io/v2beta1` en lugar de `kyverno.io/v2`, cambiá el `apiVersion` según corresponda — el `spec` mostrado acá es idéntico en ambos.

2. Aplicala y volvé a intentar el Pod:

```bash
kubectl apply -f polex-node-exporter.yaml
kubectl apply -f node-exporter.yaml
```

```
policyexception.kyverno.io/exempt-node-exporter-hostpath created
pod/node-exporter created
```

3. Verificá el *radio de impacto*: la excepción no debe haber abierto un agujero para nada más. Creá un segundo Pod violatorio en el mismo namespace con otro nombre:

```bash
kubectl run rogue --image=busybox -n legacy-monitoring --restart=Never --dry-run=client -o yaml \
  | kubectl patch --local -f - -o yaml --type=json \
    -p='[{"op":"add","path":"/spec/volumes","value":[{"name":"h","hostPath":{"path":"/etc"}}]},
         {"op":"add","path":"/spec/containers/0/volumeMounts","value":[{"name":"h","mountPath":"/mnt"}]}]' \
  | kubectl apply -f -
```

Esperado: sigue denegado. Si no lo está, tu selector `names` está mal.

4. Ahora observá cómo se *registra* la excepción, no solo cómo se comporta. Kyverno reporta un recurso eximido como `skip`, nunca como `pass`:

```bash
kubectl get policyreport -n legacy-monitoring -o wide
```

```
NAME                                   KIND   NAME            PASS  FAIL  WARN  ERROR  SKIP  AGE
b3f1e0a2-7c4e-4a41-9f0d-8a2c5e1d9b77   Pod    node-exporter   0     0     0     0      1     22s
```

5. Leé el mensaje que Kyverno adjunta al resultado omitido:

```bash
kubectl get policyreport -n legacy-monitoring -o jsonpath='{.items[0].results[0]}' | python3 -m json.tool
```

```json
{
    "policy": "disallow-host-path",
    "rule": "host-path",
    "result": "skip",
    "message": "rule skipped due to policy exception kyverno-exceptions/exempt-node-exporter-hostpath",
    "source": "kyverno",
    "scored": true
}
```

*(El texto exacto del mensaje varía según la versión; los invariantes son el `result: skip` y la referencia a la excepción.)*

### Comprobá tu comprensión

- **Q7.** La excepción vive en el namespace `kyverno-exceptions` pero exime a un Pod en `legacy-monitoring`. ¿Qué namespace determina si la excepción aplica: el propio de la excepción, o el de `spec.match`?
- **Q8.** ¿Por qué `skip` es una señal de auditoría materialmente distinta de `pass`? Describí qué pierde un tablero de cumplimiento si colapsa las dos.
- **Q9.** Escribiste `ruleNames: [host-path]`. Predecí qué pasa si el equipo cambia `node-exporter` de un Pod suelto a un DaemonSet, y enunciá la corrección exacta.
- **Q10.** ¿Cuál es el argumento de seguridad para poner la justificación en una annotation en lugar de en un comentario YAML?

---

## Ejercicio 4 — Reglas autogen, comodines y controladores de Pods

Esta es, de lejos, la razón más común por la que una excepción de apariencia correcta falla.

1. Convertí la carga de trabajo en un DaemonSet:

```yaml
# node-exporter-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: legacy-monitoring
spec:
  selector:
    matchLabels: { app: node-exporter }
  template:
    metadata:
      labels: { app: node-exporter }
    spec:
      containers:
        - name: node-exporter
          image: quay.io/prometheus/node-exporter:v1.8.2
          volumeMounts:
            - { name: rootfs, mountPath: /host, readOnly: true }
      volumes:
        - name: rootfs
          hostPath: { path: /, type: Directory }
```

```bash
kubectl apply -f node-exporter-ds.yaml
```

Denegación esperada:

```
Error from server: error when creating "node-exporter-ds.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource DaemonSet/legacy-monitoring/node-exporter was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. ...'
```

2. Notá que la regla que falla ahora es `autogen-host-path`, que no está en tu excepción. Parcheá la excepción para cubrir tanto los kinds de recurso como los nombres de reglas generados:

```yaml
# polex-node-exporter.yaml  (revised)
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-node-exporter-hostpath
  namespace: kyverno-exceptions
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames:
        - host-path
        - autogen-host-path
  match:
    any:
      - resources:
          kinds:
            - Pod
            - DaemonSet
          namespaces:
            - legacy-monitoring
          names:
            - node-exporter*
```

```bash
kubectl apply -f polex-node-exporter.yaml
kubectl apply -f node-exporter-ds.yaml
kubectl -n legacy-monitoring rollout status ds/node-exporter
```

3. Considerá la forma con comodín. `ruleNames` acepta `*`:

```yaml
      ruleNames:
        - "*"
```

Aplicala, confirmá que funciona y después **volvé a la lista explícita**:

```bash
kubectl apply -f polex-node-exporter.yaml   # explicit list version
```

4. Agregá una protección basada en datos, para que la excepción aplique solo a cargas de trabajo que llevan la etiqueta correcta, y no meramente el nombre correcto. `spec.conditions` usa los mismos operadores que las precondiciones de las reglas:

```yaml
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames: [host-path, autogen-host-path]
  match:
    any:
      - resources:
          kinds: [Pod, DaemonSet]
          namespaces: [legacy-monitoring]
  conditions:
    all:
      - key: "{{ request.object.metadata.labels.app || '' }}"
        operator: Equals
        value: node-exporter
```

> `spec.conditions` se agregó en Kyverno 1.12. Confirmalo con `kubectl explain policyexception.spec.conditions`; si devuelve un error, quedate con `match.names`.

### Comprobá tu comprensión

- **Q11.** Explicá con precisión por qué `ruleNames: ["*"]` se desaconseja en una excepción de producción, dado que la excepción ya está fijada a un único `policyName`.
- **Q12.** Tu excepción matchea `kinds: [Pod, DaemonSet]`. El controlador del DaemonSet crea un Pod en cada nodo. ¿Cuál de las dos admission requests evalúa la regla `autogen-host-path`, y cuál evalúa `host-path`?
- **Q13.** `spec.conditions` lee `request.object`. ¿Qué implica eso respecto de si tal excepción puede ser honrada durante un background scan?

---

## Ejercicio 5 — Acotar el alcance: `exceptionNamespace` y la vía de escalada de RBAC

Una API de PolicyException sin restricciones es una primitiva de escalada de privilegios: cualquiera que pueda crear una `PolicyException` en *cualquier* namespace puede eximir recursos en *todos* los namespaces.

1. Demostrá el problema. Otorgale a un equipo de bajos privilegios la capacidad de gestionar excepciones en su propio namespace:

```yaml
# team-a-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: exception-author
  namespace: team-a
rules:
  - apiGroups: ["kyverno.io"]
    resources: ["policyexceptions"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: exception-author
  namespace: team-a
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: exception-author
```

```bash
kubectl apply -f team-a-rbac.yaml
```

2. Desde `team-a`, escribí una excepción cuyo `match` apunte a un namespace que `team-a` no posee:

```yaml
# escalation.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: totally-normal-exception
  namespace: team-a
spec:
  exceptions:
    - policyName: disallow-host-path
      ruleNames: ["*"]
  match:
    any:
      - resources:
          kinds: ["*"]
          namespaces: ["*"]
```

```bash
kubectl --as=system:serviceaccount:team-a:default apply -f escalation.yaml
```

3. Observá que la creación tiene éxito y que la política cluster-wide queda ahora efectivamente desactivada. Confirmalo con el Pod rogue del Ejercicio 3 — ahora debería ser admitido. Después borrá la excepción de inmediato:

```bash
kubectl -n team-a delete polex totally-normal-exception
```

4. Cerrá el agujero. Restringí a Kyverno para que honre excepciones de exactamente un namespace:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno \
  --reuse-values \
  --set features.policyExceptions.enabled=true \
  --set features.policyExceptions.namespace=kyverno-exceptions

kubectl -n kyverno rollout status deploy/kyverno-admission-controller

kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception
```

```
"--enablePolicyException=true"
"--exceptionNamespace=kyverno-exceptions"
```

5. Volvé a ejecutar el intento de escalada. El objeto se sigue *creando*, pero ya no se *honra*:

```bash
kubectl --as=system:serviceaccount:team-a:default apply -f escalation.yaml
kubectl apply -f node-exporter.yaml   # exception in kyverno-exceptions still works
# rogue Pod from Exercise 3 → still denied
kubectl -n team-a delete polex totally-normal-exception
```

6. Ahora eliminá por completo la superficie de API a los tenants, dejando solo el namespace central:

```bash
kubectl -n team-a delete rolebinding exception-author
kubectl -n team-a delete role exception-author
```

### Comprobá tu comprensión

- **Q14.** En el paso 5 el objeto de escalada igual fue admitido por el API server. Explicá la diferencia entre *crear* una PolicyException y que sea *efectiva*, y por qué `--exceptionNamespace` no produce un error de admisión.
- **Q15.** Con `--exceptionNamespace=kyverno-exceptions` configurado, describí el RBAC mínimo que le otorgarías a un equipo de plataforma para que pueda aprobar excepciones sin ganar la capacidad de editar los objetos `ClusterPolicy` subyacentes.
- **Q16.** Un colega propone saltear `--exceptionNamespace` y, en cambio, confiar en un controlador de GitOps como único escritor de excepciones. Dá una ventaja y un riesgo residual de ese enfoque.

---

## Ejercicio 6 — Eximir un único control de los Pod Security Standards

Cuando la regla subyacente es `validate.podSecurity`, una excepción de todo o nada es demasiado burda: renunciaría a todos los controles del perfil. El bloque `spec.podSecurity` exime un control, para una imagen, para un campo, para un valor.

1. Instalá una política PSS Baseline:

```yaml
# psa-baseline.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-baseline
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: baseline
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        podSecurity:
          level: baseline
          version: latest
```

```bash
kubectl apply -f psa-baseline.yaml
```

2. Creá un Pod que viole exactamente un control de Baseline (`Capabilities`):

```yaml
# legacy-agent.yaml
apiVersion: v1
kind: Pod
metadata:
  name: legacy-agent
  namespace: legacy-monitoring
spec:
  containers:
    - name: agent
      image: docker.io/library/nginx:1.27
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
```

```bash
kubectl apply -f legacy-agent.yaml
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/legacy-monitoring/legacy-agent was blocked due to the following policies

psa-baseline:
  baseline: 'Validation rule ''baseline'' failed. It violates PodSecurity
    "baseline:latest": ({Allowed:false ForbiddenReason:non-default capabilities
    ForbiddenDetail:container "agent" must not include "NET_ADMIN" in
    securityContext.capabilities.add ...})'
```

3. Escribí una excepción quirúrgica. Fijate que nombra el *control*, la *imagen*, el *campo restringido* y el *valor permitido*:

```yaml
# polex-psa-capabilities.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: exempt-legacy-agent-net-admin
  namespace: kyverno-exceptions
  annotations:
    exceptions.corp.io/owner: platform-networking
    exceptions.corp.io/ticket: PLAT-4488
spec:
  exceptions:
    - policyName: psa-baseline
      ruleNames:
        - baseline
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - legacy-monitoring
          names:
            - legacy-agent
  podSecurity:
    - controlName: Capabilities
      images:
        - "docker.io/library/nginx*"
      restrictedField: spec.containers[*].securityContext.capabilities.add
      values:
        - NET_ADMIN
```

```bash
kubectl apply -f polex-psa-capabilities.yaml
kubectl apply -f legacy-agent.yaml
```

```
pod/legacy-monitoring/legacy-agent created
```

4. Demostrá que la exención es genuinamente estrecha. Agregá una segunda capability que la excepción no lista:

```bash
kubectl delete pod legacy-agent -n legacy-monitoring
# edit legacy-agent.yaml: add: ["NET_ADMIN", "SYS_ADMIN"]
kubectl apply -f legacy-agent.yaml
```

Esperado: denegado, citando solo `SYS_ADMIN`. Después demostrá que los *demás* controles de Baseline siguen vivos:

```bash
kubectl run hostpid --image=nginx -n legacy-monitoring \
  --overrides='{"spec":{"hostPID":true}}' --restart=Never
```

Esperado: denegado por el control `Host Namespaces`.

5. Agregá ciclo de vida. Una excepción sin fecha de fin se convierte en política permanente. Etiquetala para limpieza por TTL:

```bash
kubectl -n kyverno-exceptions label polex exempt-legacy-agent-net-admin \
  cleanup.kyverno.io/ttl=720h
```

Confirmá que el controlador de cleanup está corriendo y que la etiqueta de TTL tiene la forma que tu versión acepta:

```bash
kubectl -n kyverno get deploy | grep cleanup
kubectl -n kyverno-exceptions get polex --show-labels
```

### Comprobá tu comprensión

- **Q17.** Compará dos maneras de desbloquear `legacy-agent`: (a) la excepción con `spec.podSecurity` de arriba, y (b) una excepción sin bloque `podSecurity` que simplemente lista `ruleNames: [baseline]`. ¿A qué renuncia exactamente (b)?
- **Q18.** El campo `images` usa el comodín `docker.io/library/nginx*`. ¿Qué clase de bypass permite ese comodín, y cómo lo ajustarías?
- **Q19.** ¿Por qué una excepción sin mecanismo de vencimiento degrada un programa de políticas con el tiempo, incluso cuando cada excepción individual estaba justificada al concederse?

---

## Ejercicio 7 — Shift left: probar excepciones con la Kyverno CLI

Las excepciones pertenecen al mismo pull request que la carga de trabajo que las necesita, y deben probarse antes de llegar a un cluster.

1. Descubrí el nombre del flag que usa tu versión de la CLI — ha diferido entre releases:

```bash
kyverno version
kyverno apply --help | grep -i exception
```

2. Reuní los archivos y evaluá la política contra el recurso *sin* la excepción:

```bash
kyverno apply disallow-host-path.yaml --resource node-exporter.yaml
```

```
Applying 1 policy rule(s) to 1 resource(s)...

policy disallow-host-path -> resource legacy-monitoring/Pod/node-exporter failed:
1. host-path: validation error: HostPath volumes are forbidden. ...

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

3. Ahora incluí la excepción, usando el nombre de flag que encontraste en el paso 1:

```bash
kyverno apply disallow-host-path.yaml \
  --resource node-exporter.yaml \
  --exception polex-node-exporter.yaml
```

```
pass: 0, fail: 0, warn: 0, error: 0, skip: 1
```

4. Convertí eso en una aserción declarativa, ejecutable en CI:

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: hostpath-exception-test
policies:
  - disallow-host-path.yaml
resources:
  - node-exporter.yaml
  - rogue.yaml
exceptions:
  - polex-node-exporter.yaml
results:
  - policy: disallow-host-path
    rule: host-path
    resource: node-exporter
    kind: Pod
    result: skip
  - policy: disallow-host-path
    rule: host-path
    resource: rogue
    kind: Pod
    result: fail
```

```bash
kyverno test .
```

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Loading exceptions ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│ ID │ POLICY             │ RULE      │ RESOURCE                          │ RESULT │
│ 1  │ disallow-host-path │ host-path │ Pod/legacy-monitoring/node-exporter│ Pass   │
│ 2  │ disallow-host-path │ host-path │ Pod/legacy-monitoring/rogue        │ Pass   │

Test Summary: 2 tests passed and 0 tests failed
```

5. Prestá atención a la segunda aserción. Una suite de pruebas que solo demuestra que la excepción *funciona* es media prueba; la fila con `result: fail` demuestra que no se excedió.

### Comprobá tu comprensión

- **Q20.** En la salida de `kyverno test`, la fila 2 dice `RESULT: Pass` mientras que la expectativa declarada era `result: fail`. Explicá los dos significados distintos de "pass" que están en juego acá.
- **Q21.** Tu CI ejecuta `kyverno test` en cada PR. Un desarrollador envía una excepción con `ruleNames: ["*"]` y `namespaces: ["*"]`, más una prueba que asevera `result: skip`. La suite queda en verde. ¿Qué clase de defecto es estructuralmente incapaz de detectar `kyverno test`, y qué ejercicio de este documento lo aborda?

---

## Ejercicio 8 — Gobernar las excepciones mismas, y diagnosticar el silencio

Una excepción es un recurso de Kubernetes, así que está sujeta a políticas como cualquier otro. Cerrá el círculo validando las excepciones con Kyverno.

1. Escribí una meta-política. Exige metadatos de procedencia y prohíbe apuntar a namespaces con comodín:

```yaml
# govern-policy-exceptions.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: govern-policy-exceptions
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-provenance
      match:
        any:
          - resources:
              kinds:
                - kyverno.io/v2/PolicyException
      validate:
        message: >-
          Every PolicyException must declare an owner, a ticket and a TTL.
        pattern:
          metadata:
            labels:
              cleanup.kyverno.io/ttl: "?*"
            annotations:
              exceptions.corp.io/owner: "?*"
              exceptions.corp.io/ticket: "?*"

    - name: forbid-wildcard-namespaces
      match:
        any:
          - resources:
              kinds:
                - kyverno.io/v2/PolicyException
      validate:
        message: >-
          A PolicyException must not target all namespaces. List them explicitly.
        deny:
          conditions:
            any:
              - key: "*"
                operator: AnyIn
                value: "{{ request.object.spec.match.any[].resources.namespaces[] || `[]` }}"
```

```bash
kubectl apply -f govern-policy-exceptions.yaml
```

2. Probala contra el manifiesto de escalada del Ejercicio 5:

```bash
kubectl apply -f escalation.yaml
```

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource PolicyException/team-a/totally-normal-exception was blocked due to the following policies

govern-policy-exceptions:
  require-provenance: 'validation error: Every PolicyException must declare an
    owner, a ticket and a TTL. rule require-provenance failed at path
    /metadata/labels/'
```

3. **Trampa crítica.** Kyverno incluye una lista `resourceFilters` en su ConfigMap que excluye ciertos namespaces y kinds de *toda* evaluación de políticas — el namespace de Kyverno entre ellos. Inspeccionala y confirmá que tu namespace de excepciones no está en la lista:

```bash
kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' \
  | tr ']' ']\n' | grep -iE 'kyverno|kube-system'
```

Si hubieras llamado `kyverno` al namespace central en lugar de `kyverno-exceptions`, esta meta-política nunca se dispararía.

4. Construí la lista de verificación de diagnóstico. Cuando una excepción "no hace nada", recorré estos pasos en orden:

```bash
# 1. Is the feature on, and is the namespace restriction what you think?
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception

# 2. Does the exception exist where Kyverno is looking?
kubectl get polex -A

# 3. Does policyName match exactly? (typos here fail silently)
kubectl get clusterpolicy -o name
kubectl get polex -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.exceptions[*].policyName}{"\n"}{end}'

# 4. Does ruleNames include the autogen variants?
kubectl get clusterpolicy disallow-host-path -o jsonpath='{.status.autogen.rules[*].name}'; echo

# 5. What did the controller actually decide?
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 | grep -i exception

# 6. What does the report say — skip, or fail?
kubectl get polr -A -o wide
```

5. Disparά un background scan fresco para confirmar que los reportes convergen, y después leé el resultado para todo el cluster:

```bash
kubectl get clusterpolicyreport,policyreport -A -o wide
```

### Comprobá tu comprensión

- **Q22.** En la meta-política se configura `background: false`. ¿Por qué eso no es meramente una optimización sino un requisito de corrección para la regla `forbid-wildcard-namespaces`?
- **Q23.** Ordená los seis comandos de diagnóstico del paso 4 según la frecuencia con que esperarías que cada uno sea la causa raíz real, y justificá tu primera opción.
- **Q24.** Una PolicyException referencia `policyName: disallow-hostpath` (sin guion antes de `path`) mientras que la política es `disallow-host-path`. Describí el síntoma observable, y explicá por qué Kyverno no rechaza la excepción en tiempo de admisión.
- **Q25.** Pregunta de diseño: tu organización quiere que las excepciones sean autoexpirables, revisables y auditables. Bosquejá los tres controles que combinarías, nombrando el mecanismo concreto de cada uno.

---

## Limpieza

```bash
kubectl delete -f govern-policy-exceptions.yaml --ignore-not-found
kubectl delete polex --all -A
kubectl delete clusterpolicy --all
kind delete cluster --name kca-62
```

---

## Fuentes

- Documentación de Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Índice de la documentación de Kyverno: <https://kyverno.io/docs/>
- Instalación de Kyverno y personalización de flags del contenedor: <https://kyverno.io/docs/installation/customization/>
- Kyverno CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Policy Reports de Kyverno: <https://kyverno.io/docs/policy-reports/>
- Cleanup de Kyverno / borrado basado en TTL: <https://kyverno.io/docs/writing-policies/cleanup/>
- Código fuente y notas de release de Kyverno: <https://github.com/kyverno/kyverno>
- Pod Security Standards de Kubernetes: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Referencia de RBAC de Kubernetes: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- Referencia de admission webhooks de Kubernetes (`failurePolicy`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Currícula KCA: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** El flag debe configurarse tanto en el **admission controller** (que evalúa las excepciones en tiempo de request) como en el **background/reports controller** (que las evalúa durante los escaneos periódicos y al producir los PolicyReports). Si solo lo tiene el admission controller, las cargas de trabajo se admiten correctamente pero los background scans siguen emitiendo `fail` para los recursos eximidos: tus tableros muestran violaciones para Pods que el cluster permite deliberadamente. El value de Helm lo configura en todos los controladores relevantes; un Deployment parcheado a mano habitualmente no.

**Q2.** El namespacing te da un asidero para RBAC. Un kind de excepción cluster-scoped solo sería gobernable con ClusterRole, una concesión de todo o nada. Como es namespaced, podés (a) delegar la autoría de excepciones por equipo con Role/RoleBinding, o (b) centralizarla en un namespace y restringir Kyverno a ese namespace con `--exceptionNamespace`. Notá que la asimetría es intencional: la *política* es cluster-wide porque es una garantía cluster-wide; la *excepción* es namespaced porque es una dispensa acotada, delegada y revocable.

**Q3.** (1) La funcionalidad está deshabilitada, así que el CRD nunca se instaló — `kubectl get polex` en realidad daría error en lugar de imprimir `No resources found`, así que, con más precisión: el CRD existe pero el compañero aplicó en otro cluster/contexto. (2) El compañero aplicó un manifiesto `v2alpha1`/`v2beta1` que fue rechazado, o lo aplicó y una política de TTL/cleanup ya lo borró. Una tercera causa real: lo aplicaron en un namespace excluido por los `resourceFilters` de Kyverno, o su contexto de `kubectl` apunta a otro cluster. El comando mostrado lleva `-A`, así que un error de namespace por sí solo no lo explicaría.

**Q4.** La funcionalidad de **auto-gen** de Kyverno. Cuando una regla matchea `Pod`, Kyverno sintetiza reglas equivalentes contra los controladores de Pods (`Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `CronJob`), nombrándolas `autogen-<rule>` y `autogen-cronjob-<rule>`. La consecuencia para las excepciones: una excepción que solo lista `host-path` cubre Pods sueltos pero **no** el camino del controlador — la propia admission request del DaemonSet es evaluada por `autogen-host-path`, que no está eximida, así que la carga de trabajo sigue bloqueada.

**Q5.** El sufijo `-fail` identifica al webhook configurado con `failurePolicy: Fail`. Si el admission controller de Kyverno queda inalcanzable, el API server trata el error de la llamada al webhook como una denegación, de modo que las creaciones y actualizaciones de recursos matcheados se rechazan en todo el cluster. Este es el valor por defecto correcto para un control de seguridad (fail closed), pero convierte la disponibilidad de Kyverno en una dependencia dura para la admisión de cargas de trabajo — razón por la cual las instalaciones de producción corren múltiples réplicas con un PodDisruptionBudget, y por la cual `kyverno` y `kube-system` están en `resourceFilters`, para que Kyverno no pueda bloquearse a sí mismo.

**Q6.** Porque el nombre de la regla que falla no siempre es el nombre de la regla que escribiste. Auto-gen lo reescribe (`autogen-host-path`), y el matcheo de `ruleNames` es de cadena exacta más comodín: una discrepancia **no produce ningún error**, solo una excepción que nunca se dispara. El mensaje de denegación es la verdad de campo sobre lo que Kyverno evaluó.

**Q7.** `spec.match` determina la aplicabilidad. El namespace propio de la excepción **no** necesita coincidir con el namespace del objetivo, y por defecto una excepción en cualquier namespace puede apuntar a cualquier namespace. El namespace propio de la excepción importa exactamente para dos cosas: RBAC (quién puede crearla) y `--exceptionNamespace` (si Kyverno la honra siquiera).

**Q8.** `pass` significa que la regla se ejecutó y el recurso la satisfizo. `skip` significa que la regla no se ejecutó: se renunció a la garantía. Colapsarlas destruye la capacidad de responder "¿cuántas dispensas de hostPath están vivas, y quién las posee?". Un tablero que reporta 100% pass mientras 40 recursos son omitidos está reportando teatro de cumplimiento. `skip` es la métrica que debería tener un dueño, un ticket y un burn-down.

**Q9.** La admission request del DaemonSet es evaluada por la regla autogenerada `autogen-host-path`, que la excepción no lista, así que el DaemonSet es denegado. Corrección: agregar **tanto** `autogen-host-path` a `ruleNames` **como** `DaemonSet` a `match.any[].resources.kinds`. Ambas son necesarias: la lista de nombres de reglas y la lista de kinds son filtros independientes.

**Q10.** Las annotations son parte del objeto de la API, así que son consultables (`kubectl get polex -A -o custom-columns=...`), se preservan a través de la sincronización de GitOps y de `kubectl get -o yaml`, son visibles para las políticas de admisión (el Ejercicio 8 exige su presencia) y son exportables a un sistema de auditoría. Un comentario YAML existe solo en el archivo fuente y el API server lo descarta: el cluster no tiene registro de por qué existe la dispensa.

**Q11.** Fijar `policyName` limita la excepción a una política hoy, pero las políticas suman reglas. `ruleNames: ["*"]` extiende silenciosamente la dispensa a toda regla que se agregue a esa política en el futuro — incluidas reglas escritas después de que la excepción fue revisada y aprobada. Convierte una decisión revisada y acotada en una abierta. La lista explícita fuerza una nueva revisión cuando el alcance cambia.

**Q12.** `autogen-host-path` evalúa la admission request del **DaemonSet** (el objeto controlador, cuyo `spec.template.spec` lleva los volúmenes). `host-path` evalúa las admission requests de los **Pods** creados por el controlador del DaemonSet. Ambos caminos deben eximirse, que es por lo que la excepción lista ambos kinds y ambos nombres de regla — y también es por eso que Kyverno genera las reglas autogen: bloquear solo el Pod produciría un DaemonSet atascado en un bucle permanente de fallos de creación, sin señal clara.

**Q13.** Los background scans no tienen `AdmissionRequest`. Las variables bajo `request.*` — incluidas `request.object`, `request.operation` y `request.userInfo` — no están disponibles, así que una condición que las referencie no puede evaluarse durante un escaneo. En la práctica: la excepción puede aplicar en admisión pero no durante el background scanning, produciendo `fail` en los reportes para un recurso que fue admitido legítimamente. Preferí selectores de `match` (namespaces, names, label selectors) por sobre `conditions` cuando la política tiene `background: true`.

**Q14.** Crear una PolicyException es una escritura ordinaria de API, gobernada por RBAC y por cualquier política de admisión sobre ese kind. Ser *efectiva* es una decisión en runtime de Kyverno: al momento de evaluar, Kyverno lee las excepciones únicamente del namespace nombrado por `--exceptionNamespace`. El flag es un filtro del lado del controlador, no un webhook, así que no hay nada que produzca un error de admisión: el objeto se almacena y simplemente se ignora. Este es un peligro operativo real: la excepción parece aplicada, `kubectl get polex` la muestra, y no hace nada. Combiná el flag con la meta-política del Ejercicio 8 (o con una restricción de RBAC) para que el caso ignorado no pueda crearse en primer lugar.

**Q15.** Otorgá un `Role` en `kyverno-exceptions` con `apiGroups: ["kyverno.io"]`, `resources: ["policyexceptions"]`, verbos `get,list,watch,create,update,patch,delete`, ligado al grupo del equipo de plataforma. **No** otorgues ningún ClusterRole sobre `clusterpolicies` ni `policies` — esos quedan con un grupo separado de dueños de políticas, idealmente con escritura solo vía GitOps. La separación importa: los autores de excepciones pueden dispensar un control para una carga de trabajo específica pero no pueden debilitar ni borrar el control en sí, de modo que el rastro de auditoría de "cuál es la regla" queda independiente de "a quién se le perdonó".

**Q16.** *Ventaja:* cada excepción lleva un commit revisado, una identidad de autor y un diff — procedencia que la API del cluster no puede darte, más un rollback trivial. *Riesgo residual:* es un control de proceso, no técnico. Cualquier principal con acceso de escritura directo a la API (un admin de break-glass, un ServiceAccount de controlador comprometido, un `kubectl apply` durante un incidente) evita Git por completo, y la deriva es invisible salvo que el controlador de GitOps esté configurado para podar y autorreparar. Defensa en profundidad: GitOps como único camino *previsto*, más `--exceptionNamespace` y RBAC para que el camino imprevisto también quede cerrado.

**Q17.** (a) dispensa exactamente un control (`Capabilities`), para un patrón de imagen, para un campo, para un valor — `NET_ADMIN`. Todo otro control de Baseline, y toda otra capability, siguen aplicándose. (b) dispensa la **regla `baseline` entera** para los recursos matcheados: hostPID, hostNetwork, contenedores privilegiados, volúmenes hostPath, sysctls inseguros — el perfil completo. (b) es la diferencia entre una dispensa y un agujero.

**Q18.** El `*` final matchea cualquier tag *y* cualquier ruta de repositorio más larga que comparta el prefijo — `docker.io/library/nginx-evil`, `docker.io/library/nginxproxy:latest`, y todo tag futuro de nginx, incluidos los que todavía no se construyeron. Ajustalo fijando la referencia completa, idealmente por digest: `docker.io/library/nginx@sha256:...`, o como mínimo un tag exacto `docker.io/library/nginx:1.27`. Combinalo con una política de verificación de imágenes para que el digest esté atestiguado; si no, el tag es mutable y el pin es cosmético.

**Q19.** Las excepciones se acumulan monótonamente porque el costo de conceder una se paga de inmediato y el costo de mantenerla no lo paga nadie. La carga de trabajo que necesitaba la dispensa se borra, se refactoriza o se arregla, pero la excepción la sobrevive, matcheando todavía por comodín. En un año el conjunto de excepciones se vuelve una política en la sombra que nadie revisó como un todo. Las etiquetas de TTL, las referencias obligatorias a tickets y un reporte periódico de los resultados `skip` vivos convierten el default de "permanente salvo que alguien lo note" en "vence salvo que alguien lo renueve".

**Q20.** Son capas distintas. La columna `RESULT` reporta si se cumplió la **aserción del test**, no si la política permitió el recurso. La fila 2 asevera `result: fail` (el Pod rogue debe ser bloqueado); la CLI observó un fallo de política, la aserción coincidió, así que el *test* pasa. Confundir ambas lleva a "arreglar" una suite verde que está aseverando correctamente una denegación.

**Q21.** `kyverno test` verifica el comportamiento contra los recursos que elegiste incluir; no puede verificar el **alcance** — no tiene noción de los recursos que *no* listaste, así que una excepción demasiado amplia que también dispensa otros diez namespaces produce una corrida verde idéntica. Esa es una propiedad de gobernanza, no de comportamiento, y la detecta la meta-política del Ejercicio 8 (`forbid-wildcard-namespaces`, `require-provenance`) aplicada en admisión, más la restricción `--exceptionNamespace` del Ejercicio 5. La lección general: las pruebas unitarias demuestran que la excepción hace lo que quisiste; la política de admisión demuestra que hace *solo* eso.

**Q22.** `forbid-wildcard-namespaces` lee `{{ request.object.spec.match... }}`. Durante un background scan no hay `AdmissionRequest`, así que `request.object` es indefinido y la regla o bien daría error o bien evaluaría contra un valor vacío y produciría entradas de reporte sin sentido. Configurar `background: false` declara la regla como exclusiva de admisión, lo cual es a la vez preciso y previene un flujo de resultados `error` en el ClusterPolicyReport.

**Q23.** Frecuencia esperada, de mayor a menor: (4) faltan los nombres de regla `autogen-*` — el más común por amplio margen, porque parece correcto y falla en silencio; (3) error de tipeo en `policyName` — la misma clase de fallo silencioso; (1) el flag de la funcionalidad ausente en el background controller, que produce la división "funciona en admisión, falla en los reportes"; (2) la excepción en el namespace equivocado una vez que `--exceptionNamespace` está configurado; (6) reportes desactualizados confundidos con una excepción rota; (5) los logs, adonde vas una vez descartados los primeros cuatro. La primera opción es (4) porque el auto-gen es invisible en el manifiesto que escribiste — nada en tu YAML insinúa que `autogen-host-path` existe.

**Q24.** Síntoma: la excepción se crea con éxito, aparece en `kubectl get polex`, y la carga de trabajo sigue denegada — sin error, advertencia ni evento que apunte a la excepción. Kyverno no la rechaza porque `policyName` es una referencia de cadena libre, no una referencia a objeto validada por el API server; la política que nombra puede legítimamente no existir todavía (orden de GitOps, política aplicada después de la excepción). Rechazar nombres no resueltos rompería el apply independiente del orden. Mitigación: aseverá el emparejamiento en CI con `kyverno test` (Ejercicio 7), o agregá una regla de meta-política que use un context lookup para confirmar que la ClusterPolicy referenciada existe.

**Q25.** Tres controles complementarios:
1. **Autoexpirable** — una etiqueta `cleanup.kyverno.io/ttl` en cada PolicyException, exigida como obligatoria por la meta-política del Ejercicio 8, con el controlador de cleanup de Kyverno borrando las vencidas. La renovación requiere un nuevo commit, así que el silencio revoca en lugar de extender.
2. **Revisable** — las excepciones viven en Git junto al manifiesto de la carga de trabajo, `--exceptionNamespace` más RBAC hacen de GitOps el único camino de escritura, y `kyverno test` en CI asevera tanto el `skip` buscado como al menos un `fail` vecino para acotar el alcance.
3. **Auditable** — annotations obligatorias de `owner`/`ticket` exigidas en admisión, más un reporte programado sobre los resultados de `PolicyReport` filtrados a `result: skip`, unidos a esas annotations. Ese reporte — y no la cantidad de objetos de excepción vivos — es el número que lee la revisión de seguridad, porque mide garantías dispensadas sobre recursos reales en lugar de YAML que puede no matchear nada.

</details>