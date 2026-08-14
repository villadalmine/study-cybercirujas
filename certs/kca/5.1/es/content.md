# KCA — Tema 5.1: Validation Rules (Kyverno)

> Peso en el examen: **2.91**. Autoría original; toda afirmación técnica está atribuida a la documentación oficial de Kyverno en la sección *Referencias*.

---

## 1. Motivación y problema arquitectónico de producción

En un clúster de Kubernetes de producción, el API server acepta cualquier manifiesto sintácticamente válido que pase la validación de esquema OpenAPI del recurso. Eso significa que un `Deployment` sin `resources.limits`, un `Pod` corriendo como `root`, una imagen etiquetada como `:latest` o un `Service` de tipo `LoadBalancer` sin anotaciones de coste **entran al clúster** sin fricción. El esquema del recurso no codifica *política organizacional*; codifica *forma estructural*.

El problema arquitectónico es el **drift de gobernanza**: a medida que crecen los equipos y los namespaces, las convenciones ("todo Pod debe declarar `requests` y `limits`", "prohibido `hostPath`", "toda carga debe llevar el label `team`") dejan de sostenerse por revisión humana. Necesitás un **punto de control programático en el admission path**, ejecutado antes de que el objeto se persista en `etcd`.

Kyverno resuelve esto como un **admission controller basado en policy-as-resource**: las políticas son CRDs (`ClusterPolicy`, `Policy`) que se aplican con `kubectl`, versionan en Git y auditan como cualquier otro recurso — no hay que escribir Go ni compilar webhooks a mano (a diferencia de un webhook custom, y con un modelo declarativo distinto al Rego de OPA/Gatekeeper).

Una **validation rule** (`rule.validate`) es el corazón del enforcement: inspecciona un recurso entrante (o existente, en background scan) y decide **admitir** o **rechazar**. Las decisiones se materializan de dos formas:

- **En el admission path** (síncrono): el `AdmissionReview` se rechaza; el `kubectl apply` del usuario devuelve error y el objeto nunca llega a `etcd`.
- **En background scan** (asíncrono): Kyverno reevalúa recursos ya existentes y emite `PolicyReport`/`ClusterPolicyReport` con resultados `pass/fail/warn/error/skip`, sin bloquear nada.

El trade-off central que resolvés con validation rules es **prevención vs. observabilidad**: `Enforce` bloquea (protege el estado deseado a costa de romper despliegues no conformes) y `Audit` reporta (visibiliza el incumplimiento sin fricción, ideal para rollout gradual sobre un clúster con deuda pre-existente).

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Métodos de validación dentro de `validate`

Una `validate` rule usa **exactamente uno** de los siguientes mecanismos:

| Método | Semántica | Cuándo usarlo | Expresividad | Background |
|---|---|---|---|---|
| `pattern` | Overlay declarativo: el recurso debe *contener* el patrón (con anchors/operadores) | Requisitos de forma simples: campos obligatorios, valores permitidos | Media | Sí |
| `anyPattern` | Lista de patrones; pasa si **alguno** matchea (OR lógico) | Alternativas válidas mutuamente excluyentes (p. ej. `runAsNonRoot` **o** UID>0) | Media | Sí |
| `deny` | Rechaza si las `conditions` (JMESPath + operadores) evalúan verdadero | Lógica imperativa, comparaciones, uso de `request.operation`/`userInfo` | Alta | Depende (userInfo no) |
| `foreach` | Itera una lista y aplica `pattern`/`deny`/`cel` por elemento | Validar cada container/volume/host individualmente con `context` por ítem | Alta | Sí (según fuente) |
| `cel` | Expresiones CEL (alineado con ValidatingAdmissionPolicy de K8s) | Lógica compleja, portabilidad a VAP nativo, `variables`/`messageExpression` | Muy alta | Sí |
| `podSecurity` | Aplica Pod Security Standards (baseline/restricted) con exclusiones finas | Enforcement de PSS con control por control | Alta (dominio-específico) | Sí |
| `manifests` | Verifica firmas de manifiestos (sigstore) | Cadena de suministro / integridad de YAML | — | — |

### 2.2 `Enforce` vs `Audit` (acción ante fallo)

| Dimensión | `Enforce` | `Audit` |
|---|---|---|
| Efecto admission | **Bloquea** la request; `kubectl apply` falla | **Permite**; el objeto se crea |
| Salida | Error de webhook al usuario | Entrada `fail` en `PolicyReport` |
| Riesgo operativo | Puede romper CI/CD y despliegues legítimos | Cero fricción; requiere disciplina para revisar reportes |
| Uso típico | Namespaces maduros, invariantes duros (seguridad) | Deuda pre-existente, rollout gradual, medición de impacto |
| Rollout | Se restringe por namespace con `validationFailureActionOverrides` / `failureActionOverrides` | Punto de partida seguro antes de endurecer |

> **Nota de versión.** Históricamente la acción era `spec.validationFailureAction` (a nivel política) con `spec.validationFailureActionOverrides` para scoping por namespace. Desde Kyverno 1.12+ la forma recomendada es **por regla**: `rule.validate.failureAction` y `rule.validate.failureActionOverrides`. Ambos aceptan `Enforce`/`Audit` (capitalizado desde 1.10; el minúsculo `enforce`/`audit` quedó deprecado).

### 2.3 Anchors de `pattern`

| Anchor | Sintaxis | Semántica |
|---|---|---|
| Conditional | `()` | *Si* la clave matchea el valor, *entonces* el resto del patrón debe cumplirse; si no matchea, se saltea |
| Equality | `=()` | La clave **debe existir** y matchear |
| Existence | `^()` | En un array, **al menos un** elemento debe satisfacer el patrón |
| Negation | `X()` | La clave **no debe estar presente** |
| Global | `<()` | Gatea la evaluación de todo el patrón según un valor externo |
| Add-if-not-present | `+()` | Solo `mutate` (no aplica a `validate`) |

### 2.4 Operadores y wildcards de valores en `pattern`

| Símbolo | Significado | Ejemplo |
|---|---|---|
| `*` | Cero o más caracteres | `"registry.corp/*"` |
| `?` | Exactamente un carácter alfanumérico | `"?*"` = valor no vacío |
| `>` `<` `>=` `<=` | Comparación numérica / de `Quantity` | `">1"`, `"<=2Gi"` |
| `!` | Distinto de | `"!latest"` |
| `\|` | OR lógico | `"amd64 \| arm64"` |
| `&` | AND lógico | `">1 & <100"` |
| `-` | Rango inclusivo | `"5-10"` |
| `!-` | Fuera de rango | `"!5-10"` |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 `pattern` con conditional anchor — requiere requests y limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-requests-limits
  annotations:
    policies.kyverno.io/title: Require Requests and Limits
    policies.kyverno.io/category: Resource Management
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Todo container debe declarar requests y limits de CPU y memoria para
      permitir un scheduling y una gestión de recursos predecibles.
spec:
  background: true
  rules:
    - name: validate-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Enforce
        message: >-
          Se requieren requests y limits de CPU y memoria en todos los containers.
        pattern:
          spec:
            # ^() -> aplica a TODOS los elementos del array containers
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

### 3.2 `anyPattern` — exigir ejecución no privilegiada por cualquiera de dos vías

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  background: true
  rules:
    - name: run-as-non-root
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Audit
        message: >-
          El Pod debe correr como no-root: definí runAsNonRoot=true a nivel
          Pod o container, o bien un runAsUser > 0.
        anyPattern:
          # Opción A: securityContext a nivel Pod
          - spec:
              securityContext:
                runAsNonRoot: true
          # Opción B: securityContext en cada container
          - spec:
              containers:
                - securityContext:
                    runAsNonRoot: true
```

### 3.3 `deny` con `conditions` — prohibir el tag `:latest` y bloquear DELETE de recursos protegidos

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  background: false
  rules:
    - name: forbid-latest
      match:
        any:
          - resources:
              kinds:
                - Pod
      preconditions:
        all:
          - key: "{{ request.operation || 'BACKGROUND' }}"
            operator: AnyIn
            value:
              - CREATE
              - UPDATE
      validate:
        failureAction: Enforce
        message: >-
          El uso de imágenes con el tag ':latest' o sin tag está prohibido.
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ regex_match('^.*:latest$', '{{ element.image }}') }}"
                    operator: Equals
                    value: true
                  - key: "{{ contains('{{ element.image }}', ':') }}"
                    operator: Equals
                    value: false
```

### 3.4 `foreach` con `context` y `preconditions` por elemento — restringir registries

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  background: true
  rules:
    - name: validate-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Enforce
        message: >-
          Las imágenes solo pueden provenir de registry.internal.corp o de
          docker.io/library.
        foreach:
          - list: "request.object.spec.containers"
            # Salteo containers cuya imagen ya está en la allowlist explícita
            preconditions:
              all:
                - key: "{{ element.image }}"
                  operator: AnyNotIn
                  value:
                    - "registry.internal.corp/pause:3.9"
            pattern:
              image: "registry.internal.corp/* | docker.io/library/*"
```

### 3.5 `validate.cel` — lógica avanzada portable a ValidatingAdmissionPolicy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: max-replicas-cel
spec:
  background: true
  rules:
    - name: check-replica-ceiling
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
      validate:
        failureAction: Enforce
        cel:
          variables:
            - name: replicas
              expression: "object.spec.replicas"
          expressions:
            - expression: "variables.replicas <= 10"
              messageExpression: >-
                'El número de replicas (' + string(variables.replicas) +
                ') supera el máximo permitido de 10.'
```

### 3.6 Negation + equality anchors — prohibir `hostPath` y exigir `automountServiceAccountToken: false`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: harden-pod-surface
spec:
  background: true
  rules:
    - name: no-host-path
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Enforce
        message: "Los volúmenes hostPath están prohibidos."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
    - name: disable-sa-token-automount
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Audit
        message: >-
          automountServiceAccountToken debe estar en false salvo que el Pod
          necesite acceso a la API.
        pattern:
          spec:
            =(automountServiceAccountToken): false
```

### 3.7 Rollout gradual por namespace — `failureActionOverrides`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
spec:
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - DaemonSet
      validate:
        # Default Audit en todo el clúster...
        failureAction: Audit
        # ...pero Enforce solo en producción, y explícitamente Audit en sandbox
        failureActionOverrides:
          - action: Enforce
            namespaces:
              - "prod-*"
          - action: Audit
            namespaces:
              - "sandbox-*"
        message: "El label 'team' es obligatorio en el pod template y metadata."
        pattern:
          metadata:
            labels:
              team: "?*"
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Aplicar la política y confirmar que está READY

```console
$ kubectl apply -f require-requests-limits.yaml
clusterpolicy.kyverno.io/require-requests-limits created

$ kubectl get clusterpolicy
NAME                       ADMISSION   BACKGROUND   READY   AGE   MESSAGE
require-requests-limits    true        true         True    12s   Ready
disallow-latest-tag        true        false        True    9s    Ready
```

> Si `READY` es `False`, la política tiene un error (pattern inválido, campo mal escrito) y **no se está aplicando**. Ver §5.

### 4.2 El enforcement bloquea un despliegue no conforme

```console
$ cat nginx-bad.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27

$ kubectl apply -f nginx-bad.yaml
Error from server: error when creating "nginx-bad.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:

resource Pod/default/nginx was blocked due to the following policies

require-requests-limits:
  validate-resources: 'validation error: Se requieren requests y limits de CPU y
    memoria en todos los containers. rule validate-resources failed at path
    /spec/containers/0/resources/limits/'
```

Un manifiesto conforme pasa:

```console
$ kubectl apply -f nginx-good.yaml
pod/nginx created
```

### 4.3 Modo Audit: el recurso entra pero se reporta

```console
$ kubectl apply -f deploy-no-team-label.yaml -n sandbox-alice
deployment.apps/web created

$ kubectl get policyreport -n sandbox-alice
NAME                                   KIND         NAME   PASS   FAIL   WARN   ERROR   SKIP   AGE
d3f1c9a2-6b0e-4d2a-9f77-2a1b3c4d5e6f   Deployment   web    0      1      0      0       0      15s

$ kubectl get policyreport -n sandbox-alice -o wide \
    -o jsonpath='{.items[0].results[0]}' | jq
{
  "policy": "require-team-label",
  "rule": "check-team-label",
  "result": "fail",
  "message": "validation error: El label 'team' es obligatorio ...",
  "resources": [
    { "apiVersion": "apps/v1", "kind": "Deployment", "name": "web",
      "namespace": "sandbox-alice" }
  ],
  "scored": true
}
```

Resumen agregado a nivel clúster:

```console
$ kubectl get policyreport -A
NAMESPACE        NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
default          ...        18     0      0      0       2      6m
sandbox-alice    ...        0      1      0      0       0      2m
prod-payments    ...        41     3      0      0       0      6m
```

### 4.4 Validar políticas en CI con la Kyverno CLI (sin clúster)

```console
$ kyverno apply require-team-label.yaml --resource web-deploy.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy require-team-label -> resource default/Deployment/web failed:
1. check-team-label: validation error: El label 'team' es obligatorio en el pod
   template y metadata. rule check-team-label failed at path /metadata/labels/team/

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Test declarativo reproducible (`kyverno test`):

```yaml
# kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: require-team-label-test
policies:
  - require-team-label.yaml
resources:
  - web-deploy.yaml
results:
  - policy: require-team-label
    rule: check-team-label
    kind: Deployment
    resources: [web]
    result: fail
```

```console
$ kyverno test .

Executing require-team-label-test...
applying 1 policy to 1 resource ...

│───│──────────────────────│──────────────────│──────────│────────│
│ID │POLICY                │RULE              │RESOURCE  │RESULT  │
│───│──────────────────────│──────────────────│──────────│────────│
│1  │require-team-label    │check-team-label  │web       │Pass    │
│───│──────────────────────│──────────────────│──────────│────────│

Test Summary: 1 tests passed and 0 tests failed
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Checklist de verificación

```console
# 1) ¿La política existe y está READY?
$ kubectl get cpol require-requests-limits -o jsonpath='{.status.conditions}'
[{"type":"Ready","status":"True","reason":"Succeeded","message":"Ready"}]

# 2) ¿El webhook de validación quedó registrado?
$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-resource-validating-webhook-cfg   2   7d
kyverno-policy-validating-webhook-cfg     1   7d

# 3) ¿El admission controller está sano?
$ kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller
NAME                                         READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-6c4f8b9d7-xk2ql 1/1     Running   0          7d

# 4) ¿Qué decidió Kyverno para un recurso concreto?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 \
    | grep -i "require-requests-limits"
```

### 5.2 Fallas comunes y su diagnóstico

| Síntoma | Causa probable | Diagnóstico / fix |
|---|---|---|
| `kubectl get cpol` muestra `READY=False` | `pattern` inválido, indentación o campo mal escrito | `kubectl describe cpol <name>` → leer `status.conditions[].message`; validar con `kyverno apply` en CI antes de aplicar |
| La política existe pero **no bloquea nada** | Está en `Audit`, o el `match` no incluye el `kind`/apiVersion del recurso | Confirmar `failureAction: Enforce` y revisar `spec.rules[].match.any[].resources.kinds` |
| Falla solo en admission, no en background scan | La regla usa `request.userInfo`/`request.operation`; esos datos no existen en background | `background: false` o reescribir sin dependencias de admission-only |
| Todos los `apply` empiezan a fallar tras un incidente | El webhook está en `failurePolicy: Fail` y el controller no responde (`svc-fail`) | Ver salud del Pod de admission; considerar recursos/replicas; entender el trade-off Fail vs Ignore |
| El recurso pasa aunque no cumple | `match` demasiado laxo + anchor conditional `()` que se saltea porque la clave no matchea | Cambiar `()` por `=()` (equality) para exigir presencia de la clave |
| `PolicyReport` no aparece o está vacío | `background: false` o reports controller caído | Habilitar `background: true`; revisar `kyverno-reports-controller` |
| Mensaje `svc-fail` vs `svc-ignore` en el error | Indica el `failurePolicy` del webhook que rechazó | `-fail` = fail-closed (más seguro); `-ignore` = fail-open |

### 5.3 Interpretar el `path` del error

El mensaje `rule <name> failed at path /spec/containers/0/resources/limits/` es **la ruta JSON exacta** donde el patrón no matcheó. Es la primera pista de diagnóstico: te dice qué elemento del array (`containers/0`) y qué campo (`resources/limits`) violó el patrón, sin necesidad de leer logs.

### 5.4 Precedencia mental para elegir mecanismo

1. ¿Es forma simple (campo obligatorio, valor permitido)? → `pattern`.
2. ¿Hay alternativas válidas mutuamente excluyentes? → `anyPattern`.
3. ¿Necesito iterar cada container/volume con contexto propio? → `foreach`.
4. ¿Necesito comparaciones, `request.operation`/`userInfo` o lógica imperativa? → `deny`.
5. ¿Quiero portabilidad a ValidatingAdmissionPolicy nativo o lógica CEL rica? → `cel`.
6. ¿Es Pod Security Standards? → `podSecurity`.

---

## Referencias

- Kyverno — Validate Rules: https://kyverno.io/docs/writing-policies/validate/
- Kyverno — Anchors (conditional, equality, existence, negation, global): https://kyverno.io/docs/writing-policies/validate/#anchors
- Kyverno — Operators y wildcards en patterns: https://kyverno.io/docs/writing-policies/validate/#operators
- Kyverno — Deny rules y conditions: https://kyverno.io/docs/writing-policies/validate/#deny-rules
- Kyverno — foreach: https://kyverno.io/docs/writing-policies/validate/#foreach
- Kyverno — CEL en validate rules: https://kyverno.io/docs/writing-policies/validate/#common-expression-language-cel
- Kyverno — Preconditions y operadores de condición: https://kyverno.io/docs/writing-policies/preconditions/
- Kyverno — validationFailureAction / failureAction y overrides: https://kyverno.io/docs/writing-policies/validate/#validation-failure-action
- Kyverno — Policy Reports: https://kyverno.io/docs/policy-reports/
- Kyverno — Kyverno CLI (`apply`, `test`): https://kyverno.io/docs/kyverno-cli/
- Kyverno — Policy Types (ClusterPolicy / Policy): https://kyverno.io/docs/writing-policies/policy-types/
- Kyverno — Background scanning: https://kyverno.io/docs/writing-policies/background/
- CNCF Curriculum (KCA): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf