# Tema 5.2 — Preconditions

**Certificación:** Kyverno Certified Associate (KCA) · **Dominio 5** · **Peso: 2.91%**

> Las `preconditions` son el segundo filtro del pipeline de evaluación de una regla Kyverno. `match`/`exclude` filtran por **identidad del recurso** (GVK, nombre, namespace, selectors, sujeto de la petición); las `preconditions` filtran por **valor de datos arbitrarios** resueltos vía JMESPath: campos del objeto, del `oldObject`, del `AdmissionReview`, de un `context` (ConfigMap, APICall, imageRegistry) o del `element` dentro de un `foreach`.
>
> El orden de evaluación documentado es: `match`/`exclude` → `context` → `preconditions` → cuerpo de la regla (`validate` / `mutate` / `generate` / `verifyImages`).
> Fuente: <https://kyverno.io/docs/writing-policies/preconditions/>

Estos ejercicios se ejecutan sobre un cluster real (admission path) **y** en modo offline con la Kyverno CLI, porque hay comportamientos de preconditions que sólo se observan en uno de los dos entornos.

---

## Bloque 0 — Preparación del laboratorio

**Paso 1.** Creá el cluster de trabajo.

```bash
kind create cluster --name kca-5-2 --image kindest/node:v1.31.0
kubectl cluster-info --context kind-kca-5-2
```

Salida esperada (extracto):

```
Kubernetes control plane is running at https://127.0.0.1:6443
CoreDNS is running at https://127.0.0.1:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

**Paso 2.** Instalá Kyverno con Helm y fijá la versión del chart para que el laboratorio sea reproducible.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.2.6 \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --wait --timeout 5m
```

**Paso 3.** Verificá **qué versión de Kyverno** quedó instalada, no la del chart. La sintaxis de `preconditions` cambió entre versiones y necesitás saber en cuál estás parado.

```bash
kubectl -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

Salida esperada (aproximada):

```
kyverno-admission-controller     reg.kyverno.io/kyverno/kyverno:v1.12.6
kyverno-background-controller    reg.kyverno.io/kyverno/background-controller:v1.12.6
kyverno-cleanup-controller       reg.kyverno.io/kyverno/cleanup-controller:v1.12.6
kyverno-reports-controller       reg.kyverno.io/kyverno/reports-controller:v1.12.6
```

**Paso 4.** Instalá la CLI con la **misma minor** que el cluster. Un `kyverno apply` de una CLI 1.11 contra políticas escritas para 1.12 produce falsos negativos silenciosos.

```bash
KV=v1.12.6
curl -sSL -o kyverno-cli.tar.gz \
  "https://github.com/kyverno/kyverno/releases/download/${KV}/kyverno-cli_${KV}_linux_x86_64.tar.gz"
tar -xzf kyverno-cli.tar.gz kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno
kyverno version
```

Salida esperada:

```
Version: 1.12.6
Time: 2024-...
Git commit ID: ...
```

**Paso 5.** Creá el namespace de trabajo y un directorio para los manifiestos.

```bash
kubectl create namespace lab-preconditions
mkdir -p ~/kca-5-2 && cd ~/kca-5-2
```

### Preguntas de verificación — Bloque 0

- **Q0.1** ¿Por qué `match` no puede expresar la condición «el Pod tiene la label `app.kubernetes.io/component` con el valor `database`», siendo que `match` sí soporta `selector`?  Pensá en el caso «el valor de la label A es igual al valor de la anotación B».
- **Q0.2** Si el orden es `match` → `context` → `preconditions`, ¿qué le pasa al coste de admisión de una regla cuyo `context` hace un `APICall` y cuya `precondition` descarta el 99% de las peticiones?
- **Q0.3** ¿Qué componente de Kyverno evalúa las preconditions durante un background scan, y cuál durante un `kubectl apply`?

---

## Bloque 1 — Anatomía de una precondition y el bloque `all`

**Paso 6.** Escribí la primera política. Nótese que la `precondition` accede a una label con puntos en el nombre, lo que obliga a usar comillas dobles en JMESPath.

```bash
cat > 01-backup-label.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-backup-schedule-on-db
  annotations:
    policies.kyverno.io/title: Require backup schedule on database Pods
    policies.kyverno.io/category: Data Protection
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: db-pods-need-backup-schedule
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - lab-preconditions
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/component\" || '' }}"
            operator: Equals
            value: database
      validate:
        message: >-
          Los Pods con app.kubernetes.io/component=database deben declarar la
          anotacion backup.example.com/schedule (formato cron).
        pattern:
          metadata:
            annotations:
              backup.example.com/schedule: "?*"
EOF

kubectl apply -f 01-backup-label.yaml
```

Salida esperada:

```
clusterpolicy.kyverno.io/require-backup-schedule-on-db created
```

> **Nota de versión.** Desde Kyverno 1.13 `spec.validationFailureAction` está deprecado en favor de `spec.rules[*].validate.failureAction`. El campo a nivel `spec` sigue funcionando con un warning. Verificá con `kubectl apply -f 01-backup-label.yaml` si tu versión emite `Warning: ...deprecated...`.

**Paso 7.** Probá los tres caminos: recurso que **no dispara** la regla, recurso que la dispara y **falla**, recurso que la dispara y **pasa**.

```bash
# (a) No es database -> las preconditions no se cumplen -> la regla se salta
kubectl -n lab-preconditions run frontend \
  --image=nginx:1.27 \
  --labels="app.kubernetes.io/component=frontend"

# (b) Es database y no tiene la anotacion -> bloqueado
kubectl -n lab-preconditions run db-bad \
  --image=postgres:16 \
  --labels="app.kubernetes.io/component=database"

# (c) Es database y tiene la anotacion -> admitido
kubectl -n lab-preconditions run db-good \
  --image=postgres:16 \
  --labels="app.kubernetes.io/component=database" \
  --annotations="backup.example.com/schedule=0 3 * * *"
```

Salidas esperadas:

```
pod/frontend created

Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/lab-preconditions/db-bad was blocked due to the following policies

require-backup-schedule-on-db:
  db-pods-need-backup-schedule: 'validation error: Los Pods con app.kubernetes.io/component=database
    deben declarar la anotacion backup.example.com/schedule (formato cron). rule
    db-pods-need-backup-schedule failed at path /metadata/annotations/'

pod/db-good created
```

**Paso 8.** Observá cómo se reporta el caso (a). Un recurso descartado por preconditions **no aparece como `pass`**.

```bash
kubectl -n lab-preconditions get policyreport -o wide
```

Salida esperada (aproximada):

```
NAME                                   KIND   NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
...
```

> Con `background: false` esta política no genera entradas de background scan; los reports que veas provienen del admission path.

### Preguntas de verificación — Bloque 1

- **Q1.1** En el caso (a), ¿el resultado conceptual de la regla es `pass`, `skip` o `fail`? ¿Por qué esa distinción importa para un dashboard de compliance?
- **Q1.2** El `key` es `"{{ request.object.metadata.labels.\"app.kubernetes.io/component\" || '' }}"`. ¿Qué hace exactamente el operador `||` de JMESPath y por qué no es lo mismo que un `default()` de Go templates?
- **Q1.3** ¿Podrías haber logrado el mismo filtro con `match.any[].resources.selector.matchLabels`? ¿Qué perdés y qué ganás en cada opción?
- **Q1.4** El patrón `"?*"` en `validate.pattern` — ¿qué significa y por qué no alcanza con poner `"*"`?

---

## Bloque 2 — `all` vs `any`, y la forma legacy

**Paso 9.** Reemplazá el bloque de preconditions por una disyunción: la regla aplica si el componente es `database` **o** si la label `data-classification` es `pii`.

```bash
cat > 02-any-block.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-backup-schedule-on-db
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: db-pods-need-backup-schedule
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        any:
          - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/component\" || '' }}"
            operator: Equals
            value: database
          - key: "{{ request.object.metadata.labels.\"data-classification\" || '' }}"
            operator: Equals
            value: pii
      validate:
        message: >-
          Pods de base de datos o con datos PII deben declarar
          backup.example.com/schedule.
        pattern:
          metadata:
            annotations:
              backup.example.com/schedule: "?*"
EOF

kubectl apply -f 02-any-block.yaml
kubectl -n lab-preconditions run pii-app --image=nginx:1.27 --labels="data-classification=pii"
```

Salida esperada: el Pod `pii-app` es rechazado aunque no sea `database`.

**Paso 10.** Combiná ambos bloques. Cuando aparecen `any` **y** `all` en el mismo `preconditions`, el resultado es la conjunción de ambos: `(any) AND (all)`.

```bash
cat > 03-any-and-all.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: backup-schedule-prod-only
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: prod-sensitive-workloads
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        any:
          - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/component\" || '' }}"
            operator: Equals
            value: database
          - key: "{{ request.object.metadata.labels.\"data-classification\" || '' }}"
            operator: Equals
            value: pii
        all:
          - key: "{{ request.object.metadata.labels.\"env\" || '' }}"
            operator: Equals
            value: prod
      validate:
        message: "Workloads productivos sensibles requieren backup.example.com/schedule."
        pattern:
          metadata:
            annotations:
              backup.example.com/schedule: "?*"
EOF

kubectl apply -f 03-any-and-all.yaml
```

**Paso 11.** Probá la sintaxis estricta de `v2beta1`, donde `any`/`all` es obligatorio y la lista plana ya no se acepta.

```bash
cat > 04-legacy-list.yaml <<'EOF'
apiVersion: kyverno.io/v2beta1
kind: ClusterPolicy
metadata:
  name: legacy-precondition-form
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: flat-list
      match:
        any:
          - resources:
              kinds: [Pod]
      preconditions:
        - key: "{{ request.object.metadata.labels.env || '' }}"
          operator: Equals
          value: prod
      validate:
        message: "test"
        pattern:
          metadata:
            annotations:
              owner: "?*"
EOF

kubectl apply -f 04-legacy-list.yaml
```

Salida esperada: un error de deserialización del API server, porque en `v2beta1` el campo `preconditions` está tipado como objeto `{any, all}` y no como lista.

```
Error from server (BadRequest): error when creating "04-legacy-list.yaml":
ClusterPolicy in version "v2beta1" cannot be handled as a ClusterPolicy:
json: cannot unmarshal array into Go struct field Rule.spec.rules.preconditions of type v2beta1.AnyAllConditions
```

**Paso 12.** Cambiá `apiVersion` a `kyverno.io/v1` en el mismo archivo y reaplicá.

```bash
sed -i 's|kyverno.io/v2beta1|kyverno.io/v1|' 04-legacy-list.yaml
kubectl apply -f 04-legacy-list.yaml
kubectl get cpol legacy-precondition-form -o jsonpath='{.spec.rules[0].preconditions}' | jq .
```

### Preguntas de verificación — Bloque 2

- **Q2.1** ¿La lista plana de condiciones se comporta como `any` o como `all`?
- **Q2.2** Si escribís `preconditions.any` con tres condiciones y ninguna se cumple, ¿la regla falla o se salta?
- **Q2.3** En `kyverno.io/v1` la lista plana sigue aceptándose. ¿Qué argumento operativo hay para migrar igual a la forma `any`/`all` explícita?
- **Q2.4** ¿Cuál es la diferencia práctica entre poner una condición en `preconditions.all` versus agregar otra entrada a `match.all`?

---

## Bloque 3 — El fallo duro: variables que no resuelven

Este es el incidente de producción más común con preconditions.

**Paso 13.** Escribí la misma política **sin** el fallback `|| ''`, en modo `Enforce`.

```bash
cat > 05-no-fallback.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: fragile-precondition
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: needs-owner-annotation
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier }}"
            operator: Equals
            value: critical
      validate:
        message: "Los Pods tier=critical necesitan la anotacion owner."
        pattern:
          metadata:
            annotations:
              owner: "?*"
EOF

kubectl apply -f 05-no-fallback.yaml
```

**Paso 14.** Creá un Pod **sin** la label `tier`. Este es el recurso que, intuitivamente, «no le importa» a la política.

```bash
kubectl -n lab-preconditions run canary --image=nginx:1.27
```

Salida esperada (aproximada — el texto exacto varía por versión):

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/lab-preconditions/canary was blocked due to the following policies

fragile-precondition:
  needs-owner-annotation: 'failed to evaluate preconditions: failed to substitute
    variables in preconditions: failed to resolve request.object.metadata.labels.tier
    at path /'
```

**Paso 15.** Confirmá el radio de impacto: la política tenía la intención de tocar sólo `tier=critical`, pero **bloqueó todo el namespace**.

```bash
kubectl -n lab-preconditions run any-pod --image=busybox:1.36 --command -- sleep 3600
```

**Paso 16.** Inspeccioná los logs del admission controller para ver el error de resolución.

```bash
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 | grep -i "precondition\|substitut"
```

**Paso 17.** Aplicá las dos mitigaciones y comparalas.

```bash
# Mitigacion A: fallback JMESPath (recomendada)
cat > 06-fallback.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: fragile-precondition
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: needs-owner-annotation
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.tier || '' }}"
            operator: Equals
            value: critical
      validate:
        message: "Los Pods tier=critical necesitan la anotacion owner."
        pattern:
          metadata:
            annotations:
              owner: "?*"
EOF

kubectl apply -f 06-fallback.yaml
kubectl -n lab-preconditions run canary --image=nginx:1.27
```

Salida esperada:

```
clusterpolicy.kyverno.io/fragile-precondition configured
pod/canary created
```

```bash
# Mitigacion B: mover el filtro a match (evita la resolucion por completo)
cat > 07-match-selector.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: robust-by-match
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: needs-owner-annotation
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
              selector:
                matchLabels:
                  tier: critical
      validate:
        message: "Los Pods tier=critical necesitan la anotacion owner."
        pattern:
          metadata:
            annotations:
              owner: "?*"
EOF

kubectl apply -f 07-match-selector.yaml
```

**Paso 18.** Estudiá el tercer eje de control: `failurePolicy`. Cambiala a `Ignore` en una copia de la política frágil y observá que un error de precondition deja de bloquear.

```bash
kubectl patch cpol fragile-precondition --type=merge -p '{"spec":{"failurePolicy":"Ignore"}}'
kubectl get cpol fragile-precondition -o jsonpath='{.spec.failurePolicy}{"\n"}'
```

### Preguntas de verificación — Bloque 3

- **Q3.1** ¿Por qué un error de **resolución de variable** produce un rechazo y no un `skip`, si la intención del autor era filtrar?
- **Q3.2** ¿Qué diferencia hay entre `|| ''` y `|| 'none'` en un `key`, cuando el operador es `NotEquals`?
- **Q3.3** `failurePolicy: Ignore` evita el bloqueo. ¿Por qué es una mitigación peligrosa como solución permanente?
- **Q3.4** La Mitigación B (mover a `match.selector`) es más robusta. ¿En qué escenario **no** podés usarla y estás obligado a la precondition?
- **Q3.5** Si la misma política tuviera `validationFailureAction: Audit`, ¿el Pod `canary` se hubiera creado? ¿Y qué habrías visto en el PolicyReport?

---

## Bloque 4 — Catálogo de operadores

Kyverno soporta en `preconditions` y en `deny.conditions` los siguientes operadores:
`Equals`, `NotEquals`, `AnyIn`, `AllIn`, `AnyNotIn`, `AllNotIn`, `GreaterThan`, `GreaterThanOrEquals`, `LessThan`, `LessThanOrEquals`, `DurationGreaterThan`, `DurationGreaterThanOrEquals`, `DurationLessThan`, `DurationLessThanOrEquals`.
Fuente: <https://kyverno.io/docs/writing-policies/preconditions/>

**Paso 19.** Construí una política que ejercite los operadores de conjunto sobre una lista. `AnyIn` es verdadero si **al menos un** elemento del `key` está en `value`; `AllIn` exige que **todos** lo estén.

```bash
cat > 08-set-operators.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-set-operators
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: warn-on-mixed-registries
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          # al menos una imagen viene de un registro externo
          - key: "{{ request.object.spec.containers[].image }}"
            operator: AnyNotIn
            value:
              - "registry.internal.example.com/*"
          # pero no TODAS son externas (workload mixto: el caso interesante)
          - key: "{{ request.object.spec.containers[].image }}"
            operator: AnyIn
            value:
              - "registry.internal.example.com/*"
      validate:
        message: >-
          Workload mixto: convive al menos una imagen interna con una externa.
          Declara la anotacion supply-chain.example.com/exception.
        pattern:
          metadata:
            annotations:
              supply-chain.example.com/exception: "?*"
EOF

kubectl apply -f 08-set-operators.yaml
```

**Paso 20.** Verificá empíricamente si los wildcards funcionan en tu versión, en lugar de asumirlo. Usá la CLI, que es determinística y rápida.

```bash
cat > wildcard-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mixed-registry
  namespace: lab-preconditions
spec:
  containers:
    - name: app
      image: registry.internal.example.com/team/app:1.0
    - name: sidecar
      image: docker.io/envoyproxy/envoy:v1.31.0
EOF

kyverno apply 08-set-operators.yaml --resource wildcard-pod.yaml
```

Salida esperada (aproximada):

```
Applying 1 policy rule(s) to 1 resource(s)...

policy registry-set-operators -> resource lab-preconditions/Pod/mixed-registry failed:
1. warn-on-mixed-registries: validation error: Workload mixto: ... rule warn-on-mixed-registries failed at path /metadata/annotations/

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Si obtenés `skip: 1`, la evaluación de wildcards no se comportó como esperabas: revisá el resultado del paso siguiente antes de seguir.

**Paso 21.** Aislá cada condición. Dividí la política en dos reglas de una sola condición y volvé a correr `kyverno apply` para saber **cuál** de las dos falló. Esta es la técnica de bisección estándar para depurar preconditions compuestas.

```bash
cat > 09-bisect.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: bisect-operators
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: only-anynotin
      match: {any: [{resources: {kinds: [Pod]}}]}
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[].image }}"
            operator: AnyNotIn
            value: ["registry.internal.example.com/*"]
      validate:
        message: "AnyNotIn evaluo TRUE"
        deny: {}
    - name: only-anyin
      match: {any: [{resources: {kinds: [Pod]}}]}
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[].image }}"
            operator: AnyIn
            value: ["registry.internal.example.com/*"]
      validate:
        message: "AnyIn evaluo TRUE"
        deny: {}
EOF

kyverno apply 09-bisect.yaml --resource wildcard-pod.yaml
```

Cada regla que aparezca como `fail` es una regla cuya precondition evaluó `true` (porque `deny: {}` deniega incondicionalmente). Las que aparezcan como `skip` evaluaron `false`.

**Paso 22.** Operadores numéricos y de cantidad. Kyverno interpreta las Kubernetes *quantities* (`1Gi`, `500m`) en los operadores `GreaterThan`/`LessThan`.

```bash
cat > 10-quantities.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: large-memory-workloads
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: big-memory-needs-node-selector
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.object.spec.containers[0].resources.limits.memory || '0' }}"
            operator: GreaterThan
            value: 4Gi
      validate:
        message: "Pods con limite de memoria > 4Gi deben fijar nodeSelector."
        pattern:
          spec:
            nodeSelector:
              node-class: "?*"
EOF

kyverno apply 10-quantities.yaml --resource - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: hungry, namespace: lab-preconditions}
spec:
  containers:
    - name: app
      image: nginx:1.27
      resources:
        limits: {memory: 8Gi}
EOF
```

**Paso 23.** Operadores de duración. Se usan sobre strings tipo `1h`, `30m`, `72h` — típicamente contra un valor derivado de una anotación de TTL.

```bash
cat > 11-duration.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: short-lived-namespaces
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: long-ttl-needs-approval
      match:
        any:
          - resources:
              kinds: [Namespace]
      preconditions:
        all:
          - key: "{{ request.object.metadata.annotations.\"lifecycle.example.com/ttl\" || '0h' }}"
            operator: DurationGreaterThan
            value: 72h
      validate:
        message: "Un TTL mayor a 72h requiere la anotacion lifecycle.example.com/approved-by."
        pattern:
          metadata:
            annotations:
              lifecycle.example.com/approved-by: "?*"
EOF

kubectl apply -f 11-duration.yaml
```

### Preguntas de verificación — Bloque 4

- **Q4.1** Un Pod tiene `containers[].image = ["a", "b"]`. Con `value: ["a", "c"]`: ¿qué devuelve `AnyIn`? ¿Y `AllIn`? ¿Y `AnyNotIn`? ¿Y `AllNotIn`?
- **Q4.2** ¿Por qué `AnyNotIn` **no** es la negación de `AnyIn`? Escribí el par de valores que lo demuestra.
- **Q4.3** En el Paso 21, el truco es `validate.deny: {}`. Explicá por qué una regla con `deny` vacío convierte el resultado de la regla en un indicador directo de la precondition.
- **Q4.4** En el Paso 22, ¿qué pasaría si el fallback fuera `|| 0` (número) en vez de `|| '0'` (string), comparando contra `4Gi`?
- **Q4.5** ¿`DurationGreaterThan` acepta el valor `3d`? ¿Qué formato de duración espera Kyverno?

---

## Bloque 5 — `preconditions` vs `deny.conditions`

Ambos usan la **misma estructura sintáctica** (`{any, all}` de `{key, operator, value}`) pero significan cosas opuestas:

| | Significado si evalúa `true` | Significado si evalúa `false` |
|---|---|---|
| `preconditions` | la regla **se ejecuta** | la regla **se salta** (resultado `skip`) |
| `validate.deny.conditions` | la petición **se rechaza** | la petición **se admite** |

**Paso 24.** Escribí una política que use ambos, para el requisito: «en el namespace de laboratorio, los Deployments etiquetados `env=prod` no pueden tener menos de 2 réplicas».

```bash
cat > 12-precondition-vs-deny.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: prod-min-replicas
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: prod-deployments-need-ha
      match:
        any:
          - resources:
              kinds: [Deployment]
              namespaces: [lab-preconditions]
      # CUANDO se evalua la regla
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.env || '' }}"
            operator: Equals
            value: prod
      validate:
        message: "Un Deployment env=prod requiere al menos 2 replicas."
        # CUANDO se rechaza
        deny:
          conditions:
            all:
              - key: "{{ request.object.spec.replicas || `1` }}"
                operator: LessThan
                value: 2
EOF

kubectl apply -f 12-precondition-vs-deny.yaml
```

**Paso 25.** Probá la matriz completa de cuatro casos.

```bash
kubectl -n lab-preconditions create deployment dev-1  --image=nginx:1.27 --replicas=1
kubectl -n lab-preconditions create deployment prod-1 --image=nginx:1.27 --replicas=1 \
  --dry-run=client -o yaml | kubectl label -f - --local -o yaml env=prod | kubectl apply -f -
kubectl -n lab-preconditions create deployment prod-3 --image=nginx:1.27 --replicas=3 \
  --dry-run=client -o yaml | kubectl label -f - --local -o yaml env=prod | kubectl apply -f -
```

Salida esperada: `dev-1` y `prod-3` se crean; `prod-1` es rechazado.

```
deployment.apps/dev-1 created

Error from server: error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request:

resource Deployment/lab-preconditions/prod-1 was blocked due to the following policies

prod-min-replicas:
  prod-deployments-need-ha: Un Deployment env=prod requiere al menos 2 replicas.

deployment.apps/prod-3 created
```

**Paso 26.** Reescribí la misma política usando **una sola** capa (todo en `deny.conditions`) y compará la legibilidad y el reporting.

```bash
cat > 13-deny-only.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: prod-min-replicas-flat
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: prod-deployments-need-ha
      match:
        any:
          - resources:
              kinds: [Deployment]
              namespaces: [lab-preconditions]
      validate:
        message: "Un Deployment env=prod requiere al menos 2 replicas."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.labels.env || '' }}"
                operator: Equals
                value: prod
              - key: "{{ request.object.spec.replicas || `1` }}"
                operator: LessThan
                value: 2
EOF

kyverno apply 13-deny-only.yaml 12-precondition-vs-deny.yaml \
  --resource - --policy-report <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: dev-1, namespace: lab-preconditions, labels: {env: dev}}
spec:
  replicas: 1
  selector: {matchLabels: {app: dev-1}}
  template:
    metadata: {labels: {app: dev-1}}
    spec:
      containers: [{name: nginx, image: "nginx:1.27"}]
EOF
```

Observá el PolicyReport generado: una política reporta `skip` para `dev-1`, la otra reporta `pass`.

### Preguntas de verificación — Bloque 5

- **Q5.1** Para `dev-1` (env=dev, 1 réplica), ¿qué resultado da `prod-min-replicas` y qué resultado da `prod-min-replicas-flat`? ¿Cuál de los dos describe mejor la realidad?
- **Q5.2** ¿Por qué en `{{ request.object.spec.replicas || `1` }}` el fallback va entre backticks y no entre comillas simples?
- **Q5.3** Si tuvieras 40 reglas que aplican sólo a `env=prod`, ¿qué ventaja operativa concreta tiene el patrón de dos capas sobre el patrón plano?
- **Q5.4** ¿En qué tipos de regla (`validate`, `mutate`, `generate`, `verifyImages`) existe `deny.conditions`? ¿Y `preconditions`?

---

## Bloque 6 — Preconditions dentro de `foreach`: la variable `element`

**Paso 27.** Una precondition a nivel de regla decide si la regla corre. Una precondition dentro de `foreach` decide, **por cada elemento**, si ese elemento se procesa. La variable disponible es `{{ element }}` (y `{{ elementIndex }}`).

```bash
cat > 14-foreach-mutate.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: harden-external-containers
spec:
  background: false
  rules:
    - name: drop-privesc-on-external-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: AllNotIn
                  value:
                    - "registry.internal.example.com/*"
            patchStrategicMerge:
              spec:
                containers:
                  - name: "{{ element.name }}"
                    securityContext:
                      allowPrivilegeEscalation: false
                      capabilities:
                        drop: ["ALL"]
EOF

kubectl apply -f 14-foreach-mutate.yaml
```

> Nótese que en `foreach.list` la expresión JMESPath va **sin** las llaves `{{ }}`; dentro de `preconditions` y del patch, **con** llaves.

**Paso 28.** Aplicá un Pod mixto y verificá que sólo el container externo fue mutado.

```bash
kubectl -n lab-preconditions apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mixed-hardening
spec:
  containers:
    - name: app
      image: registry.internal.example.com/team/app:1.0
    - name: sidecar
      image: docker.io/envoyproxy/envoy:v1.31.0
EOF

kubectl -n lab-preconditions get pod mixed-hardening \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.securityContext.allowPrivilegeEscalation}{"\n"}{end}'
```

Salida esperada:

```
app	<no value>
sidecar	false
```

**Paso 29.** Repetí el ejercicio con `validate.foreach`, donde el `skip` por elemento es más visible.

```bash
cat > 15-foreach-validate.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: external-images-need-digest
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: pin-external-images-by-digest
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      validate:
        message: "Las imagenes externas deben estar fijadas por digest (@sha256:...)."
        foreach:
          - list: "request.object.spec.containers"
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: AllNotIn
                  value:
                    - "registry.internal.example.com/*"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: AllNotIn
                    value:
                      - "*@sha256:*"
EOF

kubectl apply -f 15-foreach-validate.yaml
kubectl -n lab-preconditions run tagged --image=docker.io/library/redis:7
```

Salida esperada: rechazo, porque `redis:7` es externa y no está fijada por digest.

**Paso 30.** Confirmá que una imagen interna sin digest **sí** pasa (la precondition del `foreach` la saltea).

```bash
kubectl -n lab-preconditions run internal-tagged \
  --image=registry.internal.example.com/team/tool:2.1 \
  --dry-run=server -o name
```

### Preguntas de verificación — Bloque 6

- **Q6.1** ¿Qué diferencia hay entre poner la precondition a nivel de regla y ponerla dentro del `foreach`, en el caso de un Pod con 3 containers de los cuales 1 es externo?
- **Q6.2** ¿Por qué `list:` no lleva `{{ }}` y `key:` sí?
- **Q6.3** En el Paso 29 se usan **dos** bloques de condiciones con el mismo operador `AllNotIn`. Explicá qué hace cada uno.
- **Q6.4** ¿Qué otras variables además de `element` están disponibles dentro de un `foreach`, y para qué sirve `elementIndex` en un `patchesJson6902`?

---

## Bloque 7 — `request.operation`, `request.userInfo` y el veto al background mode

**Paso 31.** Escribí una política que sólo aplique en `UPDATE` — un patrón muy común para permitir la creación pero controlar la mutación posterior.

```bash
cat > 16-operation.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: immutable-owner-annotation
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: owner-cannot-change
      match:
        any:
          - resources:
              kinds: [ConfigMap]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: UPDATE
          - key: "{{ request.oldObject.metadata.annotations.owner || '' }}"
            operator: NotEquals
            value: ""
      validate:
        message: "La anotacion owner es inmutable una vez fijada."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.annotations.owner || '' }}"
                operator: NotEquals
                value: "{{ request.oldObject.metadata.annotations.owner }}"
EOF

kubectl apply -f 16-operation.yaml

kubectl -n lab-preconditions create configmap app-config \
  --from-literal=k=v
kubectl -n lab-preconditions annotate configmap app-config owner=team-platform
kubectl -n lab-preconditions annotate configmap app-config owner=team-other --overwrite
```

Salida esperada: los dos primeros comandos funcionan (CREATE, y el UPDATE que **fija** owner por primera vez, donde `oldObject.metadata.annotations.owner` está vacío y la precondition descarta la regla); el tercero es rechazado.

```
configmap/app-config created
configmap/app-config annotated

Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource ConfigMap/lab-preconditions/app-config was blocked due to the following policies

immutable-owner-annotation:
  owner-cannot-change: La anotacion owner es inmutable una vez fijada.
```

**Paso 32.** Agregá una excepción por identidad usando `request.userInfo`, y dejá `background: true` a propósito.

```bash
cat > 17-userinfo-background.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: owner-exception-for-platform-sa
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: owner-cannot-change-unless-platform
      match:
        any:
          - resources:
              kinds: [ConfigMap]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: UPDATE
          - key: "{{ request.userInfo.username }}"
            operator: AnyNotIn
            value:
              - "system:serviceaccount:lab-preconditions:platform-operator"
      validate:
        message: "Solo platform-operator puede modificar la anotacion owner."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.annotations.owner || '' }}"
                operator: NotEquals
                value: "{{ request.oldObject.metadata.annotations.owner || '' }}"
EOF

kubectl apply -f 17-userinfo-background.yaml
```

Salida esperada: **rechazo del webhook de validación de políticas de Kyverno**, no del recurso. El mensaje exacto varía por versión, pero indica que las variables de `userInfo` no son resolubles en background mode:

```
Error from server: error when creating "17-userinfo-background.yaml": admission webhook
"validate-policy.kyverno.svc" denied the request: spec.rules[0]: variable
{{request.userInfo.username}} is not allowed in background mode. Set spec.background=false
```

**Paso 33.** Corregí y confirmá.

```bash
sed -i 's/background: true/background: false/' 17-userinfo-background.yaml
kubectl apply -f 17-userinfo-background.yaml
kubectl get cpol owner-exception-for-platform-sa -o jsonpath='{.spec.background}{"\n"}'
```

**Paso 34.** Verificá el efecto colateral de `background: false` sobre el reporting.

```bash
kubectl get cpol -o custom-columns='NAME:.metadata.name,BACKGROUND:.spec.background,READY:.status.conditions[?(@.type=="Ready")].status'
kubectl -n lab-preconditions get policyreport -o yaml | grep -c "owner-exception-for-platform-sa" || echo "sin entradas de background scan"
```

### Preguntas de verificación — Bloque 7

- **Q7.1** ¿Por qué `request.userInfo` no puede resolverse en un background scan? ¿Qué le falta al reports controller que sí tiene el admission controller?
- **Q7.2** En el Paso 31, la segunda precondition (`oldObject.metadata.annotations.owner != ""`) parece redundante con el `deny`. ¿Qué caso concreto cubre?
- **Q7.3** ¿Qué otras variables comparten la restricción de background mode junto con `request.userInfo`?
- **Q7.4** Poner `background: false` apaga el escaneo periódico. ¿Qué consecuencia tiene sobre la detección de recursos que ya existían antes de instalar la política?
- **Q7.5** ¿Por qué usar `AnyNotIn` con una lista de un solo elemento en vez de `NotEquals` para el username?

---

## Bloque 8 — Autogen: las preconditions también se reescriben

**Paso 35.** Aplicá una política sobre Pods y observá qué generó Kyverno para los Pod controllers.

```bash
cat > 18-autogen.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: autogen-precondition-demo
  annotations:
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: db-needs-storage-class
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.object.metadata.labels.\"app.kubernetes.io/component\" || '' }}"
            operator: Equals
            value: database
      validate:
        message: "Los Pods de base de datos deben declarar la anotacion storage-class."
        pattern:
          metadata:
            annotations:
              storage.example.com/class: "?*"
EOF

kubectl apply -f 18-autogen.yaml
```

**Paso 36.** Extraé las reglas autogeneradas y **diffeá** las preconditions contra el original.

```bash
kubectl get cpol autogen-precondition-demo -o yaml \
  | yq '.status.autogen.rules[] | {"name": .name, "preconditions": .preconditions}'
```

Salida esperada (aproximada): dos reglas adicionales, `autogen-db-needs-storage-class` y `autogen-cronjob-db-needs-storage-class` (según los controllers habilitados), donde la ruta de la precondition fue reescrita.

```yaml
name: autogen-db-needs-storage-class
preconditions:
  all:
    - key: '{{ request.object.spec.template.metadata.labels."app.kubernetes.io/component" || '''' }}'
      operator: Equals
      value: database
```

> Si tu versión no expone `status.autogen.rules`, mirá la anotación `pod-policies.kyverno.io/autogen-controllers` y usá `kyverno apply` contra un Deployment para observar el comportamiento efectivo.

**Paso 37.** Comprobá el efecto en la práctica: un Deployment cuyas labels están en el **Pod template**, no en el Deployment.

```bash
kubectl -n lab-preconditions apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pg
  labels:
    app.kubernetes.io/component: frontend    # label del Deployment: NO es la que cuenta
spec:
  replicas: 1
  selector:
    matchLabels: {app: pg}
  template:
    metadata:
      labels:
        app: pg
        app.kubernetes.io/component: database   # esta es la que evalua la regla autogen
    spec:
      containers:
        - name: pg
          image: postgres:16
EOF

kubectl -n lab-preconditions get policyreport -o wide | grep -i autogen || true
```

**Paso 38.** Ahora provocá el bug clásico. Escribí una precondition que referencie `request.object.metadata.name` y observá a qué nombre se refiere en la regla autogenerada.

```bash
cat > 19-autogen-trap.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: autogen-name-trap
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: canary-pods-are-exempt
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [lab-preconditions]
      preconditions:
        all:
          - key: "{{ request.object.metadata.name || '' }}"
            operator: AnyNotIn
            value: ["canary-*"]
      validate:
        message: "Todo Pod no-canary requiere la anotacion owner."
        pattern:
          metadata:
            annotations:
              owner: "?*"
EOF

kubectl apply -f 19-autogen-trap.yaml
kubectl get cpol autogen-name-trap -o yaml | yq '.status.autogen.rules[].preconditions'
```

### Preguntas de verificación — Bloque 8

- **Q8.1** ¿Qué prefijo de ruta reescribe autogen dentro de las preconditions, y cuál es el objeto de destino?
- **Q8.2** En el Paso 37, el Deployment tiene `component=frontend` y su template tiene `component=database`. ¿Cuál de las dos evalúa la regla autogenerada? ¿Y la regla original, cuando el ReplicaSet crea el Pod?
- **Q8.3** En el Paso 38, ¿a qué nombre se refiere `request.object.metadata.name` en la regla autogenerada para Deployment? ¿Por qué esto rompe la exención `canary-*`?
- **Q8.4** ¿Cómo desactivás autogen para una política puntual, y en qué caso es la decisión correcta?
- **Q8.5** ¿Por qué una regla que aplica al Deployment **y** al Pod resultante puede producir un doble reporte, y cómo lo evitás?

---

## Bloque 9 — Testing offline: `skip` es un resultado de primera clase

**Paso 39.** Armá un caso de test completo. Este es el flujo que se espera dominar en el examen.

```bash
mkdir -p ~/kca-5-2/test && cd ~/kca-5-2/test

cat > policy.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-updates-by-sa
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: only-platform-may-update-prod
      match:
        any:
          - resources:
              kinds: [ConfigMap]
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: UPDATE
          - key: "{{ request.object.metadata.labels.env || '' }}"
            operator: Equals
            value: prod
      validate:
        message: "Solo el SA platform-operator puede modificar ConfigMaps de prod."
        deny:
          conditions:
            all:
              - key: "{{ request.userInfo.username || '' }}"
                operator: AnyNotIn
                value: ["system:serviceaccount:platform:platform-operator"]
EOF

cat > resources.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: prod-config
  namespace: lab-preconditions
  labels: {env: prod}
data: {k: v}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: dev-config
  namespace: lab-preconditions
  labels: {env: dev}
data: {k: v}
EOF
```

**Paso 40.** Sin un archivo de variables, `request.operation` y `request.userInfo` no existen offline. Creá el `Value` manifest.

```bash
cat > values.yaml <<'EOF'
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata:
  name: values
globalValues:
  request.operation: UPDATE
  request.userInfo.username: "system:serviceaccount:dev:builder"
EOF
```

**Paso 41.** Corré `kyverno apply` con y sin el archivo de variables, y compará.

```bash
kyverno apply policy.yaml --resource resources.yaml
echo "----- ahora con variables -----"
kyverno apply policy.yaml --resource resources.yaml --values-file values.yaml
```

Salida esperada del primer comando (aproximada): un aviso de variables no resueltas y/o resultados en `error`/`skip`. Del segundo: `prod-config` falla, `dev-config` se saltea.

```
Applying 1 policy rule(s) to 2 resource(s) with 1 variable file(s)...

policy restrict-updates-by-sa -> resource lab-preconditions/ConfigMap/prod-config failed:
1. only-platform-may-update-prod: Solo el SA platform-operator puede modificar ConfigMaps de prod.

pass: 0, fail: 1, warn: 0, error: 0, skip: 1
```

**Paso 42.** Formalizá los resultados esperados en un `Test` manifest — así se convierte en un test de regresión de CI.

```bash
cat > kyverno-test.yaml <<'EOF'
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: preconditions-regression
policies:
  - policy.yaml
resources:
  - resources.yaml
variables: values.yaml
results:
  - policy: restrict-updates-by-sa
    rule: only-platform-may-update-prod
    kind: ConfigMap
    resources: [prod-config]
    result: fail
  - policy: restrict-updates-by-sa
    rule: only-platform-may-update-prod
    kind: ConfigMap
    resources: [dev-config]
    result: skip
EOF

kyverno test .
```

Salida esperada (el formato de tabla varía por versión):

```
Loading test  ( ./kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│───│──────────────────────────│─────────────────────────────────│──────────────────────────────────────│────────│
│ ID│ POLICY                   │ RULE                            │ RESOURCE                             │ RESULT │
│───│──────────────────────────│─────────────────────────────────│──────────────────────────────────────│────────│
│ 1 │ restrict-updates-by-sa   │ only-platform-may-update-prod   │ v1/ConfigMap/lab-.../prod-config     │ Pass   │
│ 2 │ restrict-updates-by-sa   │ only-platform-may-update-prod   │ v1/ConfigMap/lab-.../dev-config      │ Pass   │
│───│──────────────────────────│─────────────────────────────────│──────────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

**Paso 43.** Rompé el test a propósito: cambiá `result: skip` por `result: pass` para `dev-config` y volvé a correr.

```bash
sed -i 's/result: skip/result: pass/' kyverno-test.yaml
kyverno test .
```

Salida esperada: el segundo caso aparece como `Fail` en la columna RESULT y el resumen dice `1 tests passed and 1 tests failed`.

```bash
sed -i '0,/result: pass$/! s/result: pass/result: skip/' kyverno-test.yaml   # revertir
```

### Preguntas de verificación — Bloque 9

- **Q9.1** ¿Por qué `dev-config` debe declararse como `skip` y no como `pass`? ¿Qué afirmación distinta hace cada uno sobre la política?
- **Q9.2** ¿Qué diferencia hay entre `globalValues` y la sección `policies[].rules[].values` en un manifest `Value`?
- **Q9.3** Si no proveés `request.operation`, ¿qué asume la CLI por defecto y por qué eso puede dar un falso `pass`?
- **Q9.4** ¿Cómo probarías offline una precondition que depende de un `context` con `apiCall`?
- **Q9.5** En la columna `RESULT` de `kyverno test`, `Pass` significa «la política pasó». ¿Verdadero o falso?

---

## Bloque 10 — Diagnóstico en producción

**Paso 44.** Subí la verbosidad del admission controller para ver la evaluación de preconditions paso a paso.

```bash
kubectl -n kyverno set env deploy/kyverno-admission-controller --list | head
kubectl -n kyverno patch deploy kyverno-admission-controller --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"-v=4"}
]'
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

**Paso 45.** Disparó una petición y seguí los logs.

```bash
kubectl -n kyverno logs deploy/kyverno-admission-controller -f --tail=0 &
kubectl -n lab-preconditions run debug-pod --image=nginx:1.27 --labels="tier=critical"
sleep 3; kill %1
```

Buscá líneas que contengan `preconditions`, `variable substitution` y `rule skipped`.

**Paso 46.** Consultá los reports agregados y filtralos por `skip`.

```bash
kubectl -n lab-preconditions get policyreport -o json \
  | jq -r '.items[].results[] | select(.result=="skip") | "\(.policy)/\(.rule)\t\(.resources[0].name)"'
```

**Paso 47.** Consultá las métricas Prometheus. `kyverno_policy_results_total` desagrega por `rule_result`, lo que te permite medir cuántas peticiones un ruleset está **salteando** — un `skip` del 100% es la firma de una precondition mal escrita.

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
sleep 2
curl -s http://localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -20
kill %1
```

Salida esperada (extracto):

```
kyverno_policy_results_total{policy_background_mode="false",policy_name="require-backup-schedule-on-db",policy_type="cluster",policy_validation_mode="enforce",resource_kind="Pod",resource_namespace="lab-preconditions",rule_name="db-pods-need-backup-schedule",rule_result="fail",rule_type="validate"} 1
kyverno_policy_results_total{...,rule_result="skip",...} 3
```

**Paso 48.** Medí la latencia que la regla agrega al admission path.

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
sleep 2
curl -s http://localhost:8000/metrics | grep 'kyverno_admission_review_duration_seconds' | head -5
kill %1
```

### Preguntas de verificación — Bloque 10

- **Q10.1** Una regla muestra `rule_result="skip"` en el 100% de las peticiones desde hace una semana. Enumerá tres causas posibles, ordenadas por probabilidad.
- **Q10.2** ¿Qué señal en las métricas distingue «la precondition filtró correctamente» de «la variable no resolvió»?
- **Q10.3** ¿Por qué `-v=4` es aceptable para un laboratorio pero problemático en un cluster de producción con miles de admission reviews por minuto?
- **Q10.4** Un equipo reporta que su política «no hace nada». Diseñá una secuencia de tres comandos que discrimine entre: (a) `match` no coincide, (b) precondition evalúa `false`, (c) la regla corre y pasa.

---

## Bloque 11 — Limpieza

**Paso 49.**

```bash
kubectl delete cpol \
  require-backup-schedule-on-db backup-schedule-prod-only legacy-precondition-form \
  fragile-precondition robust-by-match registry-set-operators bisect-operators \
  large-memory-workloads short-lived-namespaces prod-min-replicas prod-min-replicas-flat \
  harden-external-containers external-images-need-digest immutable-owner-annotation \
  owner-exception-for-platform-sa autogen-precondition-demo autogen-name-trap \
  --ignore-not-found
kubectl delete namespace lab-preconditions --wait=false
kind delete cluster --name kca-5-2
```

---

## Fuentes

- Kyverno — Preconditions: <https://kyverno.io/docs/writing-policies/preconditions/>
- Kyverno — Match/Exclude: <https://kyverno.io/docs/writing-policies/match-exclude/>
- Kyverno — Variables: <https://kyverno.io/docs/writing-policies/variables/>
- Kyverno — JMESPath: <https://kyverno.io/docs/writing-policies/jmespath/>
- Kyverno — Validate rules (`deny.conditions`, `foreach`): <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Mutate rules (`foreach`, `element`): <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno — Auto-Gen Rules for Pod Controllers: <https://kyverno.io/docs/writing-policies/autogen/>
- Kyverno — External Data Sources (`context`): <https://kyverno.io/docs/writing-policies/external-data-sources/>
- Kyverno — Kyverno CLI (`apply`, `test`, `Value`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — Monitoring & metrics: <https://kyverno.io/docs/monitoring/>
- CNCF — KCA Curriculum: <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Kubernetes — Dynamic Admission Control (`AdmissionReview`, `userInfo`, `failurePolicy`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- JMESPath — Or expressions: <https://jmespath.org/specification.html#or-expressions>

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

**Q0.1** `match.selector` es un `LabelSelector` de Kubernetes: compara una label contra un **literal constante** escrito en la política. No puede comparar dos campos del mismo objeto entre sí, ni comparar contra un valor traído de un ConfigMap o de un `apiCall`, ni contra `request.userInfo`. La condición «el valor de la label A es igual al valor de la anotación B» requiere resolver **ambos** lados en tiempo de admisión, y eso sólo lo hace una precondition:
```yaml
- key: "{{ request.object.metadata.labels.team || '' }}"
  operator: Equals
  value: "{{ request.object.metadata.annotations.\"cost-center/owner\" || '' }}"
```

**Q0.2** El `context` se resuelve **antes** que las preconditions, así que el `APICall` se ejecuta en el 100% de las peticiones que pasaron `match`, incluso en el 99% que la precondition va a descartar. Es un round trip al API server por admission review desperdiciado, sumado directamente a la latencia de admisión. La mitigación es estrechar el `match` (kinds, namespaces, `selector`, `operations`) para que la regla ni siquiera se evalúe. Algunas versiones recientes de Kyverno hacen resolución perezosa del `context` (sólo resuelven la entrada si alguna expresión la referencia), pero eso no ayuda cuando es la propia precondition la que la referencia. Verificalo en tu versión con `-v=4` y contando las peticiones al API server.

**Q0.3** En background scan las evalúa el **reports controller**; en el admission path las evalúa el **admission controller**. Es exactamente por eso que las variables del `AdmissionReview` (`request.userInfo`, `request.roles`, `request.operation`) no están disponibles en background: el reports controller lee objetos del cluster, no recibe un `AdmissionReview`.

### Bloque 1

**Q1.1** `skip`. Es la diferencia entre «este recurso fue evaluado y cumple» y «este recurso nunca fue evaluado». Un dashboard que colapse `skip` en `pass` reporta cobertura que no existe: si una precondition se rompe y de golpe todo pasa a `skip`, un dashboard mal diseñado muestra 100% verde. La métrica sana es la **proporción** `skip / (pass + fail + skip)` por regla y su estabilidad en el tiempo.

**Q1.2** `||` es el *or-expression* de JMESPath: evalúa el lado izquierdo y, si el resultado es un valor **falsy** (`null`, `false`, string vacío `""`, lista vacía `[]`, objeto vacío `{}`), devuelve el lado derecho. No es sólo un chequeo de nulidad. La consecuencia práctica: `{{ x.replicas || `1` }}` devuelve `1` tanto si `replicas` no existe **como si vale `0`** — un caso real donde el fallback miente. Para distinguir «ausente» de «cero» hay que usar la función `not_null()` o comprobar la clave explícitamente.

**Q1.3** Con `match.selector` ganás: (a) el filtro se aplica antes de resolver variables y de cargar el `context`, así que es más barato; (b) es inmune al fallo duro por variable ausente; (c) Kyverno puede usarlo para afinar el `objectSelector` del webhook, reduciendo el tráfico que llega a Kyverno. Perdés: expresividad (sólo igualdad/existencia contra literales) y la capacidad de comparar campos entre sí o contra datos externos. **Regla de diseño:** todo lo que se pueda expresar en `match` va en `match`; las preconditions son para lo que `match` no puede.

**Q1.4** `?*` significa «un carácter cualquiera (`?`) seguido de cero o más caracteres cualesquiera (`*`)», es decir: **la clave existe y su valor no está vacío**. `*` solo también matchea el string vacío, con lo cual `backup.example.com/schedule: ""` pasaría la validación — que es exactamente el bypass que queríamos evitar.

### Bloque 2

**Q2.1** Como `all`: la lista plana (forma legacy de `kyverno.io/v1`) es una conjunción implícita — todas las condiciones deben ser verdaderas.

**Q2.2** Se **salta** (`skip`). Ninguna evaluación de precondition produce un `fail`; producen `run` o `skip`. Lo único que puede convertir una precondition en un rechazo es un **error** al resolver sus variables (Bloque 3).

**Q2.3** Legibilidad e intención explícita, pero sobre todo **portabilidad de versión**: `kyverno.io/v2beta1` ya rechaza la forma plana, y las políticas escritas hoy sobreviven a la migración de API version sin edición. Además, una lista plana invita al error de leerla como `any` durante una revisión de código.

**Q2.4** `match.all` filtra por identidad y se evalúa **antes** de resolver variables y `context`; una condición allí no puede fallar por variable ausente y es más barata. `preconditions.all` filtra por valor y se evalúa después. Operativamente: `match` decide *qué recursos ve la regla*, `preconditions` decide *bajo qué estado de esos recursos actúa*.

### Bloque 3

**Q3.1** Porque Kyverno no puede saber si la variable ausente hubiera dado `true` o `false`. Ante ambigüedad, con `failurePolicy: Fail` (el default), el comportamiento seguro es rechazar: preferís bloquear un despliegue antes que dejar pasar algo que la política debía revisar. El problema es que la política **no había declarado** que le importara ese recurso — la intención del autor era filtrar, pero escribió una expresión que no tolera la ausencia.

**Q3.2** Con `NotEquals` importa mucho. `{{ ...tier || '' }} NotEquals critical` da `true` para un Pod sin la label (porque `"" != "critical"`), así que la regla **corre** sobre recursos que no tienen la label. Si la intención era «corré sólo sobre Pods que declaran un tier distinto de critical», necesitás `|| 'none'` más una segunda condición `NotEquals none`, o mejor: un bloque `all` con una condición de existencia explícita.

**Q3.3** `failurePolicy: Ignore` no arregla la precondition — hace que **cualquier** fallo del webhook (incluido Kyverno caído, un timeout, o un error de red) resulte en admisión silenciosa de la petición. Convertís una política de seguridad en *best effort*. Como respuesta de incidente para desbloquear un cluster es correcta; como estado permanente significa que no tenés la garantía que creés tener. Lo correcto es arreglar la expresión y devolver `failurePolicy: Fail`.

**Q3.4** Cuando la condición no es una label o annotation constante: comparar dos campos del objeto entre sí, comparar contra `request.oldObject` (inmutabilidad), contra `request.userInfo`, contra `request.operation`, contra datos de un ConfigMap/`apiCall`, o contra `element` dentro de un `foreach`. Nada de eso se puede expresar como `LabelSelector`.

**Q3.5** El Pod **sí** se hubiera creado — `Audit` nunca bloquea. Pero en el PolicyReport habrías visto un resultado `error` (no `fail`, no `pass`), con el mensaje de sustitución de variable fallida. Esto es exactamente por qué desplegar toda política nueva primero en `Audit` y revisar los `error` del report es el procedimiento estándar antes de pasar a `Enforce`.

### Bloque 4

**Q4.1** Con `key = ["a","b"]` y `value = ["a","c"]`:
- `AnyIn` → `true` (al menos un elemento del key está en value: `"a"`).
- `AllIn` → `false` (`"b"` no está en value).
- `AnyNotIn` → `true` (al menos un elemento del key **no** está en value: `"b"`).
- `AllNotIn` → `false` (`"a"` sí está en value).

**Q4.2** Porque ambos cuantifican sobre el mismo conjunto pero con predicados independientes, y en una lista con elementos heterogéneos **los dos pueden ser `true` a la vez** — que es justamente el caso del Paso 19. Con `key = ["a","b"]` y `value = ["a","c"]`: `AnyIn = true` **y** `AnyNotIn = true`. La negación real de `AnyIn` es `AllNotIn`, y la negación de `AllIn` es `AnyNotIn`. Confundirlas es una fuente clásica de políticas que no filtran nada.

**Q4.3** `validate.deny` con un cuerpo vacío no tiene condiciones que evaluar, así que deniega siempre que la regla se ejecute. Entonces el resultado de la regla se vuelve una lectura directa de la precondition: `fail` ⇒ la precondition dio `true`; `skip` ⇒ dio `false`; `error` ⇒ una variable no resolvió. Con una condición por regla, un solo `kyverno apply` te da la tabla de verdad completa sin tocar el cluster.

**Q4.4** Compararías el número `0` contra el string `4Gi`. Kyverno intenta parsear ambos lados como *quantity*; `0` es una quantity válida, así que probablemente funcione — pero el comportamiento con tipos mixtos es frágil y dependiente de versión. La práctica robusta es mantener **ambos lados del mismo tipo**: si el valor de comparación es una quantity string, el fallback también debe ser una quantity string (`'0'`).

**Q4.5** No: `3d` no es válido. Kyverno usa el parser de duración de Go (`time.ParseDuration`), que acepta `ns, us, ms, s, m, h` — **no** `d`, `w` ni `y`. Tres días se escriben `72h`. Un `3d` produce un error de parseo de la condición en tiempo de evaluación, con el mismo efecto de bloqueo que una variable ausente.

### Bloque 5

**Q5.1** `prod-min-replicas` (dos capas) reporta **`skip`**: la regla no aplica a un Deployment de dev. `prod-min-replicas-flat` reporta **`pass`**: la regla corrió, el `deny` no se disparó. El `skip` describe mejor la realidad — decir «`dev-1` pasó la política de mínimo de réplicas de producción» es engañoso, porque esa política nunca tuvo nada que decir sobre `dev-1`.

**Q5.2** Los backticks delimitan un **literal JSON** en JMESPath: `` `1` `` es el número entero 1. `'1'` sería el string `"1"`. Como `LessThan` compara contra el número `2`, el fallback debe ser numérico. Un `'1'` string obliga a Kyverno a hacer coerción de tipos, con resultado dependiente de versión.

**Q5.3** Consistencia y auditabilidad. Con el patrón de dos capas, el filtro «esto es producción» aparece idénticamente en las 40 reglas y se puede verificar con un `grep`/`yq` mecánico. Con el patrón plano, esa condición está **mezclada** con la lógica de negocio de cada regla, y basta que una la escriba con `AnyIn` en vez de `Equals` para que aplique en dev. Además, los reports muestran `skip` explícito, así que podés medir cuántos recursos quedaron fuera de alcance por regla — con el patrón plano eso es invisible.

**Q5.4** `deny.conditions` existe sólo en reglas `validate` (a nivel de regla y dentro de `validate.foreach`). `preconditions` existe a nivel de **regla** para los cuatro tipos (`validate`, `mutate`, `generate`, `verifyImages`) y además dentro de `mutate.foreach` y `validate.foreach`, donde opera por elemento.

### Bloque 6

**Q6.1** A nivel de regla, la precondition se evalúa **una vez** sobre el Pod entero: o la regla procesa los 3 containers, o no procesa ninguno. Dentro del `foreach`, se evalúa **una vez por container**: se procesa sólo el externo y los 2 internos se saltean individualmente. Para políticas de container-level hardening, la versión `foreach` es la única correcta.

**Q6.2** Porque son contextos sintácticos distintos. `list:` está tipado como una **expresión JMESPath** — Kyverno la evalúa directamente, sin sustitución de variables previa. `key:` y `value:` están tipados como valores arbitrarios (string, número, lista), donde `{{ }}` marca las porciones que deben sustituirse antes de comparar. Poner `{{ }}` en `list:` produce un error de evaluación.

**Q6.3** El primero (`preconditions`) selecciona **qué containers se evalúan**: sólo los que no vienen del registro interno. El segundo (`deny.conditions`) decide **cuáles de esos se rechazan**: los que no tienen un digest en la referencia. Sin la precondition, un container interno con tag mutable también sería rechazado — que puede ser deseable, pero es una política distinta.

**Q6.4** `{{ elementIndex }}` (índice base 0 del elemento actual) y `{{ element }}`. `elementIndex` es indispensable en `patchesJson6902`, donde la ruta del patch necesita el índice numérico:
```yaml
patchesJson6902: |-
  - path: /spec/containers/{{ elementIndex }}/securityContext/runAsNonRoot
    op: add
    value: true
```
Dentro de un `foreach` anidado, `element` se refiere al elemento del `foreach` más interno.

### Bloque 7

**Q7.1** Porque en un background scan **no existe un `AdmissionReview`**. El reports controller lee objetos que ya están persistidos en etcd; el objeto almacenado no conserva quién lo creó ni con qué verbo. `request.userInfo` sólo existe mientras la petición está en vuelo, en el admission path. Kyverno lo detecta en tiempo de validación de la política y rechaza la combinación `background: true` + variables de `userInfo`, en lugar de fallar silenciosamente en cada scan.

**Q7.2** El caso en que la anotación `owner` se fija **por primera vez** (pasa de ausente a presente). Ese es un `UPDATE` en el que `oldObject.metadata.annotations.owner` está vacío y `object.metadata.annotations.owner` vale `team-platform`: el `deny` (`NotEquals`) daría `true` y rechazaría. La precondition `oldObject...owner != ""` descarta la regla en ese caso, implementando «inmutable **una vez fijada**» en lugar de «imposible de fijar».

**Q7.3** `request.userInfo` (con sus subcampos `username`, `groups`, `uid`, `extra`), `request.roles`, `request.clusterRoles` y `request.operation`. Todas provienen del `AdmissionReview`. También `serviceAccountName` y `serviceAccountNamespace`, que Kyverno deriva de `request.userInfo.username`.

**Q7.4** Los recursos preexistentes **nunca son evaluados** por esa política: sólo se evalúa lo que pase por el admission path a partir de la instalación. Un Deployment que viola la política y que no se toca durante meses no aparece en ningún report. La mitigación operativa es dividir en dos políticas: una con `background: false` que hace *enforcement* usando `userInfo`, y otra con `background: true` sin variables de admisión que hace la detección continua en modo `Audit`.

**Q7.5** Porque `AnyIn`/`AnyNotIn` soportan **wildcards** en los elementos de `value`, mientras que `Equals`/`NotEquals` los soportan de forma dependiente de versión. Escribiendo `AnyNotIn` desde el principio, extender la excepción a `system:serviceaccount:platform:*` es agregar un elemento a la lista, no reescribir el operador. Además, la forma de lista documenta que la excepción es un conjunto que va a crecer.

### Bloque 8

**Q8.1** Autogen reescribe `request.object.spec` → `request.object.spec.template.spec` y `request.object.metadata` → `request.object.spec.template.metadata` dentro de toda la regla (preconditions incluidas), de modo que las expresiones apunten al **Pod template** del controller y no al controller mismo. Para CronJob la reescritura es más profunda: `spec.jobTemplate.spec.template.spec`.

**Q8.2** La regla autogenerada evalúa `spec.template.metadata.labels`, es decir `database` — y por eso el Deployment `pg` sí dispara la validación. La regla **original** se evalúa sobre el Pod que finalmente crea el ReplicaSet, cuyas labels vienen del template: también `database`. Las labels del Deployment (`frontend`) no las mira nadie. Este desalineamiento entre labels del controller y del template es una fuente recurrente de confusión al depurar.

**Q8.3** Se refiere al nombre del **Deployment** (`pg`), no al del Pod — porque `metadata.name` no está bajo `spec` ni bajo `metadata` del template en el sentido que autogen reescribe, y en la mayoría de las versiones queda apuntando al nombre del controller. Eso rompe la exención `canary-*` de dos maneras: un Deployment llamado `canary-web` queda exento aunque sus Pods se llamen `canary-web-7d9f-xxxxx`, y a nivel Pod la regla original ve nombres generados con sufijo aleatorio, que sí matchean `canary-*` sólo por accidente del prefijo. **Nunca bases una precondition en `metadata.name` en una política con autogen activo**: usá labels, que sí se propagan de forma controlada.

**Q8.4** Con la anotación `pod-policies.kyverno.io/autogen-controllers: "none"` en la política. Es la decisión correcta cuando la regla depende de campos que sólo existen en el Pod real y no en el template (por ejemplo `spec.nodeName`, `status.*`, o los containers inyectados por otro webhook de mutación que corre después del controller), o cuando ya tenés una política separada y explícita para los controllers.

**Q8.5** Porque Kyverno evalúa tanto el Deployment (vía regla autogen) como el Pod resultante (vía regla original), y ambos generan una entrada en el PolicyReport para el mismo problema lógico. Se evita restringiendo el `match` a un solo nivel: o bien `kinds: [Deployment, StatefulSet, ...]` con `autogen-controllers: "none"`, o bien `kinds: [Pod]` aceptando el doble reporte a cambio de cubrir Pods creados sin controller. La decisión depende de si querés bloquear temprano (en el `kubectl apply` del Deployment, con mejor feedback al usuario) o exhaustivamente (en el Pod, sin escapes).

### Bloque 9

**Q9.1** `pass` afirma «la regla evaluó este recurso y lo encontró conforme». `skip` afirma «la regla decidió no evaluar este recurso». Declarar `skip` en el test convierte la **precondition misma** en algo bajo test: si mañana alguien cambia `Equals: prod` por `AnyIn: [prod, dev]`, el test falla. Si hubieras declarado `pass`, ese cambio de alcance pasaría desapercibido — y ampliar silenciosamente el alcance de una política de enforcement es exactamente el tipo de regresión que este test debe atrapar.

**Q9.2** `globalValues` define variables que aplican a **toda** la ejecución del test, independientemente de la política, la regla o el recurso. La sección `policies[].rules[].values` (y `policies[].resources[].values`) permite dar valores **distintos** por regla o por recurso — indispensable cuando el mismo test necesita simular un `CREATE` para un recurso y un `UPDATE` para otro, o dos usernames distintos contra la misma política.

**Q9.3** La CLI asume `CREATE` cuando no se especifica. Con una precondition `request.operation Equals UPDATE`, todos los recursos darían `skip` — o, según la versión, la variable quedaría sin resolver y el resultado sería `error`. El falso `pass` aparece en el caso inverso: una política que bloquea en `UPDATE` y que en el test corre implícitamente como `CREATE` reporta que todo está bien, cuando en el cluster va a rechazar cada `kubectl edit`.

**Q9.4** Con un `Value` manifest que provea la variable de contexto directamente, sin ejecutar el `apiCall`:
```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata: {name: values}
policies:
  - name: mi-politica
    rules:
      - name: mi-regla
        values:
          nombreDeLaEntradaDeContext: '{"items": [{"metadata":{"name":"x"}}]}'
```
La clave debe coincidir con el `name` de la entrada de `context`. Alternativamente, `kyverno apply --cluster` evalúa contra un cluster real y resuelve los `apiCall` de verdad — útil para validación, no para CI hermético.

**Q9.5** **Falso.** En `kyverno test`, la columna `RESULT` indica si el resultado **observado coincide con el resultado esperado** declarado en el manifest `Test`. Un caso con `result: fail` esperado y que efectivamente falla muestra `Pass`. Confundir estos dos niveles es un error habitual al leer la salida: `Test Summary: 2 tests passed` significa «2 aserciones se cumplieron», no «2 recursos cumplieron las políticas».

### Bloque 10

**Q10.1** Por probabilidad decreciente:
1. **La precondition no coincide con la realidad de los datos** — un nombre de label mal escrito, un valor con mayúsculas distintas, o una ruta JMESPath incorrecta. Es la causa dominante.
2. **Autogen** — la regla está siendo evaluada sobre `spec.template.*` pero la precondition fue escrita contra la ruta del Pod, o viceversa.
3. **El `match` es más amplio que la precondition** — la regla ve recursos que nunca iba a procesar, y el `skip` es correcto pero el `match` debería estrecharse.

**Q10.2** Un filtrado correcto incrementa `kyverno_policy_results_total{rule_result="skip"}`. Una variable no resuelta incrementa `rule_result="error"` (y, con `failurePolicy: Fail` y `Enforce`, además rechaza la petición). Si ves `skip` alto y `error` en cero, la política está filtrando; si ves `error` distinto de cero, tenés una expresión rota independientemente de lo que diga el conteo de `skip`.

**Q10.3** `-v=4` emite varias líneas por admission review, incluyendo el contenido de los objetos evaluados. A escala de producción eso significa: volumen de logs que puede saturar el agente de recolección y su backend, coste de I/O y CPU en el path caliente de admisión (aumentando la latencia que estás intentando diagnosticar), y — el punto crítico — **exposición de datos sensibles**, porque los objetos volcados pueden incluir Secrets, variables de entorno con credenciales y tokens. Si hace falta en producción, se sube la verbosidad de forma acotada en el tiempo y con el destino de logs bajo control.

**Q10.4** Tres comandos que discriminan las tres hipótesis:

```bash
# (a) ¿El match coincide? Si no aparece NINGUNA linea para el recurso, el match falla.
kyverno apply politica.yaml --resource recurso.yaml --policy-report -o yaml \
  | yq '.results[] | select(.resources[0].name == "mi-recurso")'

# (b) ¿La precondition da false? Aislala con deny vacio: fail=true, skip=false.
#     (copia de la politica con validate.deny:{} y una sola condicion por regla)
kyverno apply bisect.yaml --resource recurso.yaml

# (c) ¿Corre y pasa? Los logs con -v=4 lo dicen explicitamente.
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 \
  | grep -E "rule (skipped|passed|failed)|preconditions|substitut"
```

El orden importa: (a) es gratis y descarta la mitad de los casos; (b) es la bisección del Paso 21 y no toca el cluster; (c) es el último recurso, porque exige elevar la verbosidad.

</details>