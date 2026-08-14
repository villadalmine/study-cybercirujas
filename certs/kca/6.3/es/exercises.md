# 6.3 — Métricas de Kyverno · Ejercicios guiados

> **Peso en el examen:** 3.33 % (dominio 6, *Monitoring, Reporting and Troubleshooting*).
> **Temario de referencia:** [KCA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf)
> **Documentación principal:** [kyverno.io/docs/monitoring/](https://kyverno.io/docs/monitoring/)

**Qué vas a poder hacer cuando termines**

1. Localizar cada endpoint de métricas que expone Kyverno y explicar por qué hay más de uno.
2. Leer la exposición cruda de OpenTelemetry/Prometheus y decodificar el conjunto de labels de cada familia de métricas.
3. Correlacionar `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_policy_execution_duration_seconds` y `kyverno_policy_results_total` para atribuir la latencia.
4. Controlar la cardinalidad de las métricas mediante el ConfigMap `kyverno-metrics` antes de que te tire abajo Prometheus.
5. Conectar Kyverno con Prometheus Operator usando un `ServiceMonitor`, escribir PromQL con sentido y alertar sobre los modos de falla que ocurren de verdad.
6. Cambiar el pipeline de pull (Prometheus) a push (collector OTLP/gRPC).

**Prerrequisitos del laboratorio**

| Componente | Versión usada en las salidas de abajo | Notas |
|---|---|---|
| Kubernetes | 1.31 (kind) | sirve cualquiera 1.27+ |
| Kyverno | 1.13.x (chart de Helm `3.3.x`) | arquitectura multi-controller — obligatoria para este tema |
| `kubectl` | el mismo minor | |
| Helm | 3.14+ | |
| `kube-prometheus-stack` | 65.x | solo hace falta a partir del Ejercicio 7 |
| `curl`, `jq`, `grep` | cualquiera | |

---

## Ejercicio 0 — Montar el laboratorio

### Pasos

1. Creá el clúster y los namespaces de tenant que vas a usar como valores de label de las métricas:

```bash
kind create cluster --name kca-metrics
kubectl create namespace team-a
kubectl create namespace team-b
```

2. Instalá Kyverno con los cuatro controllers y sus Services de métricas:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7 \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1
```

3. Confirmá que los cuatro Deployments estén listos:

```bash
kubectl -n kyverno get deploy
```

Salida esperada:

```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           93s
kyverno-background-controller   1/1     1            1           93s
kyverno-cleanup-controller      1/1     1            1           93s
kyverno-reports-controller      1/1     1            1           93s
```

> **Nota de producción.** `admissionController.replicas=1` es un ajuste de *laboratorio*. En producción se corren 3 réplicas, y esa decisión tiene una consecuencia directa sobre las métricas que vas a ejercitar en el Ejercicio 9: cada counter es **por pod**.

---

## Ejercicio 1 — Mapear la superficie de métricas

### Pasos

1. Listá los Services del namespace `kyverno` y separá los Services del webhook de los Services de métricas:

```bash
kubectl -n kyverno get svc
```

Salida esperada:

```
NAME                                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
kyverno-background-controller-metrics   ClusterIP   10.96.146.211   <none>        8000/TCP   4m12s
kyverno-cleanup-controller              ClusterIP   10.96.63.84     <none>        443/TCP    4m12s
kyverno-cleanup-controller-metrics      ClusterIP   10.96.15.7      <none>        8000/TCP   4m12s
kyverno-reports-controller-metrics      ClusterIP   10.96.209.32    <none>        8000/TCP   4m12s
kyverno-svc                             ClusterIP   10.96.111.20    <none>        443/TCP    4m12s
kyverno-svc-metrics                     ClusterIP   10.96.24.155    <none>        8000/TCP   4m12s
```

2. Inspeccioná el selector y el target port del Service de métricas del admission controller:

```bash
kubectl -n kyverno get svc kyverno-svc-metrics -o yaml | grep -A8 -E '^spec:'
```

Esperado (abreviado):

```yaml
spec:
  ports:
  - name: metrics-port
    port: 8000
    protocol: TCP
    targetPort: metrics-port
  selector:
    app.kubernetes.io/component: admission-controller
    app.kubernetes.io/instance: kyverno
    app.kubernetes.io/part-of: kyverno
  type: ClusterIP
```

3. Leé los flags efectivos del admission controller — esta es la fuente autoritativa de cómo están configuradas las métricas, no los values del chart que *creés* haber puesto:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

Esperado (abreviado):

```
["--caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca"
 "--tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair"
 "--servicePort=443"
 "--webhookServerPort=9443"
 "--resyncPeriod=15m"
 "--disableMetrics=false"
 "--otelConfig=prometheus"
 "--metricsPort=8000"
 "--admissionReports=true"
 "--autoUpdateWebhooks=true"
 "--enableConfigMapCaching=true"
 "--v=2"]
```

4. Confirmá que el puerto del contenedor tenga nombre y esté expuesto:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{"\t"}{.containerPort}{"\n"}{end}'
```

Salida esperada:

```
https	9443
metrics-port	8000
```

### Preguntas de comprensión — bloque 1

- **Q1.1** — ¿Por qué Kyverno 1.11+ expone cuatro endpoints `/metrics` separados en lugar de uno, y qué se rompe operativamente si tu configuración de scrape apunta únicamente a `kyverno-svc-metrics`?
- **Q1.2** — `kyverno-svc` escucha en 443 y `kyverno-svc-metrics` en 8000. ¿Qué se sirve en cada uno, y por qué el puerto de métricas **nunca** debe fusionarse con el puerto del webhook?
- **Q1.3** — De la lista de flags, ¿cuáles dos flags determinan juntos si Prometheus puede hacer scrape de Kyverno siquiera, y cuál es el valor por defecto de cada uno?
- **Q1.4** — El `selector` del Service incluye `app.kubernetes.io/component: admission-controller`. ¿Qué observarías en Prometheus si ese label se quitara del selector y los otros dos quedaran?

---

## Ejercicio 2 — Leer la exposición cruda

### Pasos

1. Abrí un port-forward al endpoint de métricas del admission controller (dejalo corriendo en una segunda terminal):

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000
```

2. Contá cuántas familias de métricas distintas de Kyverno existen en un clúster recién instalado:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^# TYPE kyverno_' | sort
```

Salida esperada (abreviada, el orden y el conjunto varían según la versión):

```
# TYPE kyverno_admission_requests_total counter
# TYPE kyverno_admission_review_duration_seconds histogram
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_http_requests_duration_seconds histogram
# TYPE kyverno_http_requests_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge
```

3. Mirá qué más hay en el endpoint además de `kyverno_*`:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^# TYPE ' | grep -v kyverno_ | head -12
```

Salida esperada (abreviada):

```
# TYPE go_gc_duration_seconds summary
# TYPE go_goroutines gauge
# TYPE go_memstats_alloc_bytes gauge
# TYPE go_threads gauge
# TYPE process_cpu_seconds_total counter
# TYPE process_resident_memory_bytes gauge
# TYPE promhttp_metric_handler_errors_total counter
# TYPE target_info gauge
```

4. Imprimí una línea de muestra completa y decodificala a mano:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_client_queries_total' | head -1
```

Salida esperada:

```
kyverno_client_queries_total{client_type="dynamic",operation="List",otel_scope_name="kyverno",otel_scope_version="",resource_kind="ClusterPolicy",resource_namespace=""} 6
```

5. Extraé las *claves* de los labels de una familia de forma programática — la técnica que deberías usar en lugar de memorizar listas de labels que cambian entre versiones minor:

```bash
curl -s http://127.0.0.1:8000/metrics \
  | grep -m1 '^kyverno_policy_rule_info_total{' \
  | sed 's/.*{//; s/}.*//' | tr ',' '\n' | cut -d= -f1
```

Salida esperada:

```
otel_scope_name
otel_scope_version
policy_background_mode
policy_名... 
```

Salida esperada corregida:

```
otel_scope_name
otel_scope_version
policy_background_mode
policy_name
policy_namespace
policy_type
policy_validation_mode
rule_name
rule_type
status_ready
```

6. Inspeccioná `target_info`, el resource descriptor de OpenTelemetry:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^target_info'
```

Salida esperada:

```
target_info{service_name="kyverno",service_version="v1.13.4",telemetry_sdk_language="go",telemetry_sdk_name="opentelemetry",telemetry_sdk_version="1.32.0"} 1
```

### Preguntas de comprensión — bloque 2

- **Q2.1** — ¿De dónde vienen los labels `otel_scope_name` y `otel_scope_version`? No están documentados en la referencia de métricas de Kyverno — ¿qué te dice su presencia sobre cómo produce Kyverno las métricas internamente?
- **Q2.2** — Un colega escribe `sum(kyverno_policy_results_total) by (rule_result)` y obtiene un número que de vez en cuando *baja*. La métrica es un counter. Explicá la baja y dá la consulta correcta.
- **Q2.3** — `kyverno_policy_rule_info_total` está tipada como `gauge` pero su nombre termina en `_total`. ¿Por qué es un olor de nomenclatura, y qué representa realmente el *valor* del gauge (a diferencia de lo que sugiere el nombre)?
- **Q2.4** — Necesitás el p95 de `kyverno_admission_review_duration_seconds`. ¿Qué tres sufijos de series temporales expone un histogram de Prometheus, y cuál de ellos consume `histogram_quantile()`?

---

## Ejercicio 3 — Generar tráfico de admission y atribuir la latencia

### Pasos

1. Aplicá una policy de validate en modo **Enforce** acotada a `team-a`. Fijate en el campo `failureAction` por regla de Kyverno 1.13+ (el `spec.validationFailureAction` a nivel de spec está deprecado pero se sigue respetando):

```yaml
# require-team-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/severity: medium
spec:
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - team-a
      validate:
        failureAction: Enforce
        message: "The label `team` is required on every Pod in team-a."
        pattern:
          metadata:
            labels:
              team: "?*"
```

2. Aplicá una policy en modo **Audit** y una policy de **mutate**, para que las métricas lleven más de un `rule_type` y `policy_validation_mode`:

```yaml
# audit-and-mutate.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Audit
        message: "An explicit image tag is required."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-resources
spec:
  background: false
  rules:
    - name: add-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - team-b
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(cpu): "50m"
                    +(memory): "64Mi"
```

```bash
kubectl apply -f require-team-label.yaml -f audit-and-mutate.yaml
kubectl get clusterpolicy
```

Salida esperada:

```
NAME                    ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-default-resources   true        false        True    8s    Ready
disallow-latest-tag     true        true         True    8s    Ready
require-team-label      true        true         True    8s    Ready
```

3. Generá una petición **denegada**:

```bash
kubectl -n team-a run web --image=nginx:1.27
```

Salida esperada:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/team-a/web was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: The label `team` is required on every Pod
    in team-a. rule check-team-label failed at path /metadata/labels/team/'
```

4. Generá una petición **aceptada** y una petición **mutada**:

```bash
kubectl -n team-a run web --image=nginx:1.27 --labels=team=payments
kubectl -n team-b run cache --image=redis:7.4
kubectl -n team-b get pod cache -o jsonpath='{.spec.containers[0].resources}'; echo
```

Salida esperada:

```
pod/web created
pod/cache created
{"requests":{"cpu":"50m","memory":"64Mi"}}
```

5. Leé el counter de resultados:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_results_total' | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Salida esperada (abreviada, labels reordenados para facilitar la lectura):

```
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="require-image-tag",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="false",policy_name="add-default-resources",policy_namespace="-",policy_type="cluster",policy_validation_mode="-",resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="add-requests",rule_result="pass",rule_type="mutate"} 1
```

6. Leé el counter de peticiones y los dos histograms de latencia:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_admission_requests_total'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_admission_review_duration_seconds_sum'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_execution_duration_seconds_sum'
```

Salida esperada (abreviada):

```
kyverno_admission_requests_total{...,resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create"} 2
kyverno_admission_requests_total{...,resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create"} 1

kyverno_admission_review_duration_seconds_sum{...,resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create"} 0.041672
kyverno_admission_review_duration_seconds_sum{...,resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create"} 0.019344

kyverno_policy_execution_duration_seconds_sum{...,policy_name="require-team-label",rule_name="check-team-label",rule_result="fail",rule_type="validate",...} 0.000186
kyverno_policy_execution_duration_seconds_sum{...,policy_name="disallow-latest-tag",rule_name="require-image-tag",rule_result="pass",rule_type="validate",...} 0.000094
```

### Preguntas de comprensión — bloque 3

- **Q3.1** — `kyverno_admission_requests_total` para `team-a` vale `2` pero `kyverno_policy_results_total` tiene más de 2 muestras para `team-a`. ¿Cuál es la relación de cardinalidad entre una admission request y un policy result, y cuál de los dos es el denominador correcto para un SLI de "% de peticiones bloqueadas"?
- **Q3.2** — La suma de `kyverno_policy_execution_duration_seconds_sum` sobre todas las reglas para el create de `team-a` es ~0,3 ms, mientras que `kyverno_admission_review_duration_seconds_sum` para el mismo conjunto de labels es ~42 ms. ¿A dónde se fueron los otros ~41,7 ms? Nombrá tres contribuyentes concretos.
- **Q3.3** — En la muestra de resultado de la regla de mutate, `policy_validation_mode="-"`. ¿Por qué es un guion y no `Audit` ni `Enforce`?
- **Q3.4** — `rule_execution_cause="admission_request"`. ¿Cuál es el otro valor que puede tomar este label, y qué controller lo emite?
- **Q3.5** — Tu webhook de Kyverno tiene `timeoutSeconds: 10` y `failurePolicy: Fail`. Escribí el PromQL que te dice cuán cerca estás de ese precipicio, y explicá por qué la serie `_count` por sí sola no alcanza.

---

## Ejercicio 4 — Inventario de reglas y ciclo de vida de las policies

### Pasos

1. Leé el gauge de inventario de reglas:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_rule_info_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Salida esperada (abreviada):

```
kyverno_policy_rule_info_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",rule_name="check-team-label",rule_type="validate",status_ready="true"} 1
kyverno_policy_rule_info_total{policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",rule_name="require-image-tag",rule_type="validate",status_ready="true"} 1
kyverno_policy_rule_info_total{policy_background_mode="false",policy_name="add-default-resources",policy_namespace="-",policy_type="cluster",policy_validation_mode="-",rule_name="add-requests",rule_type="mutate",status_ready="true"} 1
```

2. Observá el counter de ciclo de vida. Registrá la línea base y después creá, actualizá y borrá una `Policy` namespaced:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_changes_total'
```

```yaml
# throwaway-policy.yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: throwaway
  namespace: team-b
spec:
  background: false
  rules:
    - name: noop-check
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
      validate:
        failureAction: Audit
        message: "placeholder"
        pattern:
          metadata:
            name: "?*"
```

```bash
kubectl apply -f throwaway-policy.yaml
kubectl -n team-b annotate policy throwaway note=v2 --overwrite
kubectl -n team-b delete policy throwaway
sleep 5
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_changes_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Salida esperada:

```
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="created",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="updated",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="deleted",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
```

3. Rompé una policy a propósito y observá `status_ready`. Referenciá una API inexistente en una llamada de context:

```yaml
# broken-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-context
spec:
  background: true
  rules:
    - name: lookup-missing
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        - name: missing
          apiCall:
            urlPath: "/apis/does.not.exist/v1/widgets"
            jmesPath: "items | length(@)"
      validate:
        failureAction: Audit
        message: "context lookup demo"
        deny:
          conditions:
            all:
              - key: "{{ missing }}"
                operator: GreaterThan
                value: 0
```

```bash
kubectl apply -f broken-policy.yaml
kubectl get clusterpolicy broken-context
```

### Preguntas de comprensión — bloque 4

- **Q4.1** — `kyverno_policy_rule_info_total` sigue mostrando `1` para una regla después de borrar la policy, hasta el siguiente intervalo de refresco. ¿Qué clave de configuración gobierna eso, y qué problema está resolviendo?
- **Q4.2** — `policy_namespace="-"` para las ClusterPolicies y un namespace real para las Policies. ¿Por qué Kyverno emite un guion literal en vez de una cadena vacía, y qué problema práctico de PromQL evita eso?
- **Q4.3** — Escribí la expresión de alerta que se dispara cuando *cualquier* regla de Kyverno está cargada pero no lista, y explicá por qué `kyverno_policy_rule_info_total{status_ready="false"} == 1` es más seguro que `== 0`.

---

## Ejercicio 5 — Background scans, cleanup controller y presión sobre el API server

### Pasos

1. Hacé scrape del controller de **background** — otro endpoint, otra mezcla de métricas:

```bash
kubectl -n kyverno port-forward svc/kyverno-background-controller-metrics 8001:8000 &
curl -s http://127.0.0.1:8001/metrics | grep '^# TYPE kyverno_' | sort
```

Salida esperada:

```
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge
```

2. Dispará un background scan tocando una policy, y después buscá resultados cuya causa *no* sea una admission request:

```bash
kubectl annotate clusterpolicy require-team-label rescan="$(date +%s)" --overwrite
sleep 20
curl -s http://127.0.0.1:8001/metrics \
  | grep '^kyverno_policy_results_total' \
  | grep 'rule_execution_cause="background_scan"' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Salida esperada (abreviada):

```
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="",rule_execution_cause="background_scan",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
```

3. Mirá las métricas de la work-queue del controller — la señal de salud para los controllers de background y de reports:

```bash
curl -s http://127.0.0.1:8001/metrics | grep -E '^kyverno_controller_(reconcile|requeue|drop)_total' | head -8
```

Salida esperada (abreviada):

```
kyverno_controller_reconcile_total{controller_name="background-scan-controller",otel_scope_name="kyverno",otel_scope_version=""} 14
kyverno_controller_reconcile_total{controller_name="update-request-controller",otel_scope_name="kyverno",otel_scope_version=""} 3
kyverno_controller_requeue_total{controller_name="background-scan-controller",num_requeues="1",otel_scope_name="kyverno",otel_scope_version=""} 2
kyverno_controller_drop_total{controller_name="background-scan-controller",otel_scope_name="kyverno",otel_scope_version=""} 0
```

4. Medí la carga que Kyverno le pone al API server:

```bash
curl -s http://127.0.0.1:8001/metrics | grep '^kyverno_client_queries_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g' | head -6
```

Salida esperada (abreviada):

```
kyverno_client_queries_total{client_type="dynamic",operation="List",resource_kind="Pod",resource_namespace=""} 11
kyverno_client_queries_total{client_type="kubeclient",operation="Get",resource_kind="ConfigMap",resource_namespace="kyverno"} 4
kyverno_client_queries_total{client_type="kyverno",operation="Watch",resource_kind="ClusterPolicy",resource_namespace=""} 1
kyverno_client_queries_total{client_type="metadata",operation="List",resource_kind="Deployment",resource_namespace=""} 2
```

5. Ejercitá el controller de **cleanup**. Primero otorgale permisos de borrado vía agregación de RBAC, y después creá una cleanup policy:

```yaml
# cleanup-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-pods
  labels:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "delete"]
---
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-marked-pods
spec:
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - team-b
          selector:
            matchLabels:
              ephemeral: "true"
  schedule: "*/1 * * * *"
```

```bash
kubectl apply -f cleanup-rbac.yaml
kubectl -n team-b run scratch --image=busybox:1.36 --labels=ephemeral=true --command -- sleep 3600
sleep 90

kubectl -n kyverno port-forward svc/kyverno-cleanup-controller-metrics 8002:8000 &
curl -s http://127.0.0.1:8002/metrics | grep '^kyverno_cleanup_controller_deletedobjects_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Salida esperada:

```
kyverno_cleanup_controller_deletedobjects_total{policy_name="cleanup-marked-pods",policy_namespace="",policy_type="ClusterCleanupPolicy",resource_group="",resource_kind="Pod",resource_namespace="team-b",resource_version="v1"} 1
```

### Preguntas de comprensión — bloque 5

- **Q5.1** — En el resultado del background scan, `resource_request_operation` es la cadena vacía. ¿Por qué, y qué implica eso para una consulta de PromQL que filtra por `resource_request_operation="create"`?
- **Q5.2** — `kyverno_admission_requests_total` y `kyverno_admission_review_duration_seconds` no aparecen en el endpoint del background controller. Dá la razón arquitectónica, y nombrá la métrica que *sí* aparece en los cuatro controllers.
- **Q5.3** — Ves `rate(kyverno_controller_drop_total{controller_name="reports-controller"}[5m]) > 0`. ¿Qué significa un "drop" en una work queue de controller-runtime, y cuál es el síntoma visible para el usuario aguas abajo?
- **Q5.4** — `kyverno_client_queries_total{client_type="metadata"}` crece mucho más rápido que los otros client types en un clúster grande. ¿Para qué usa Kyverno el metadata client, y por qué eso es una *buena* noticia para la carga del API server y no una mala?

---

## Ejercicio 6 — Control de cardinalidad con el ConfigMap `kyverno-metrics`

> Este es el ejercicio que más importa en producción. Un clúster de 5 000 namespaces con la configuración por defecto va a agregarle millones de series activas a Prometheus.

### Pasos

1. Estimá tu cardinalidad actual antes de cambiar nada:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_' \
  | sed 's/{.*//' | sort | uniq -c | sort -rn | head
```

Salida esperada:

```
187
     84 kyverno_policy_execution_duration_seconds_bucket
     28 kyverno_admission_review_duration_seconds_bucket
     14 kyverno_client_queries_total
      8 kyverno_policy_results_total
      6 kyverno_policy_execution_duration_seconds_sum
      6 kyverno_policy_execution_duration_seconds_count
      ...
```

2. Inspeccioná la configuración que viene de fábrica:

```bash
kubectl -n kyverno get cm kyverno-metrics -o yaml
```

Salida esperada (abreviada):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
data:
  bucketBoundaries: 0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10,15,20,25,30
  metricsExposure: ""
  metricsRefreshInterval: 0
  namespaces: |
    {"exclude":[],"include":[]}
```

3. Confirmá las claves de Helm que renderizan este ConfigMap en *tu* versión del chart — nunca confíes en un path de clave recordado de memoria:

```bash
helm show values kyverno/kyverno --version 3.3.7 | grep -n -A 30 '^metricsConfig:'
```

4. Aplicá una configuración con forma de producción: descartá los namespaces más ruidosos, quitá `resource_namespace` de las familias de mayor cardinalidad, ajustá los buckets del histogram y desactivá una métrica que no usás:

```yaml
# kyverno-metrics-tuned.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
data:
  namespaces: |
    {
      "include": [],
      "exclude": ["kube-system", "kube-public", "kube-node-lease", "kyverno"]
    }
  metricsRefreshInterval: 6h
  bucketBoundaries: "0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10"
  metricsExposure: |
    {
      "kyverno_admission_requests_total": {
        "disabledLabelDimensions": ["resource_namespace"]
      },
      "kyverno_policy_results_total": {
        "disabledLabelDimensions": ["resource_namespace", "resource_kind"]
      },
      "kyverno_policy_execution_duration_seconds": {
        "disabledLabelDimensions": ["resource_namespace", "resource_request_operation"],
        "bucketBoundaries": [0.005, 0.01, 0.05, 0.1, 0.5, 1]
      },
      "kyverno_client_queries_total": {
        "enabled": false
      }
    }
```

```bash
kubectl apply -f kyverno-metrics-tuned.yaml
kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

5. Reabrí el port-forward (el pod fue reemplazado), regenerá tráfico y compará la cardinalidad:

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
kubectl -n team-a run web2 --image=nginx:1.27 --labels=team=payments
kubectl -n kube-system run probe --image=busybox:1.36 --command -- sleep 60

curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_'
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_client_queries_total'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_results_total' | head -2
```

Salida esperada:

```
64
0
kyverno_policy_results_total{otel_scope_name="kyverno",otel_scope_version="",policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="require-image-tag",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{otel_scope_name="kyverno",otel_scope_version="",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
```

6. Verificá que la exclusión de namespaces haya surtido efecto — el Pod de `kube-system` fue admitido pero no produjo ninguna serie:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c 'kube-system'
```

Salida esperada:

```
0
```

7. Confirmá que `kyverno_policy_rule_info_total` **no** haya sido afectada por la exclusión de namespaces:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_policy_rule_info_total'
```

Salida esperada:

```
4
```

### Preguntas de comprensión — bloque 6

- **Q6.1** — `metricsRefreshInterval: 0` es el valor por defecto de fábrica. ¿Qué significa `0` acá, y cuál es el comportamiento exacto que comprás al ponerlo en `6h`? ¿Qué *perdés*?
- **Q6.2** — Después de la exclusión, el Pod de `kube-system` igual fue admitido e igual fue evaluado por `disallow-latest-tag`. Explicá con precisión qué filtra la lista `namespaces.exclude` y qué **no** filtra. ¿Por qué es un punto ciego de monitoreo que tenés que documentar?
- **Q6.3** — En el paso 5, dos muestras de `kyverno_policy_results_total` tienen conjuntos de labels *distintos*: una tiene `resource_kind` y la otra no. Dado el ConfigMap que aplicaste, ¿es consistente? ¿Qué te dice sobre cómo se aplica `disabledLabelDimensions`?
- **Q6.4** — Recortaste `bucketBoundaries` de 15 límites a 11. Para una sola familia de histogram con 40 combinaciones distintas de labels, ¿cuántas series temporales eliminaste, y cuál es la fórmula? (Acordate del bucket `+Inf` implícito más `_sum` y `_count`.)
- **Q6.5** — Poner `"enabled": false` en `kyverno_client_queries_total` ahorra series pero te cuesta algo durante un incidente. Nombrá la clase específica de incidente que ya no vas a poder diagnosticar, y la señal alternativa que usarías en su lugar.

---

## Ejercicio 7 — Prometheus Operator, PromQL y alertas

### Pasos

1. Instalá `kube-prometheus-stack`, desactivando el selector por defecto para que levante ServiceMonitors que él no creó:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait
```

2. Habilitá los ServiceMonitors de Kyverno y los dashboards de Grafana que vienen incluidos:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set admissionController.serviceMonitor.enabled=true \
  --set backgroundController.serviceMonitor.enabled=true \
  --set cleanupController.serviceMonitor.enabled=true \
  --set reportsController.serviceMonitor.enabled=true \
  --set grafana.enabled=true \
  --set grafana.namespace=monitoring

kubectl -n kyverno get servicemonitor
```

Salida esperada:

```
NAME                            AGE
kyverno-background-controller   12s
kyverno-cleanup-controller      12s
kyverno-reports-controller      12s
kyverno-admission-controller    12s
```

3. Inspeccioná un ServiceMonitor para ver cómo se enlaza al Service de métricas:

```bash
kubectl -n kyverno get servicemonitor kyverno-admission-controller -o yaml | grep -A 14 '^spec:'
```

Salida esperada (abreviada):

```yaml
spec:
  endpoints:
  - interval: 30s
    path: /metrics
    port: metrics-port
    scrapeTimeout: 25s
  namespaceSelector:
    matchNames:
    - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/instance: kyverno
      app.kubernetes.io/part-of: kyverno
```

4. Confirmá que los targets estén UP:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("kyverno")) | "\(.labels.job)\t\(.health)\t\(.scrapeUrl)"'
```

Salida esperada:

```
kyverno-admission-controller	up	http://10.244.0.14:8000/metrics
kyverno-background-controller	up	http://10.244.0.15:8000/metrics
kyverno-cleanup-controller	up	http://10.244.0.16:8000/metrics
kyverno-reports-controller	up	http://10.244.0.17:8000/metrics
```

5. Ejecutá el conjunto de consultas de producción. Corré cada una a través de la API HTTP para poder scriptearlo:

```bash
q() { curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric)\t\(.value[1])"'; }

# a) Enforce-mode block rate per policy/rule
q 'sum by (policy_name, rule_name) (rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[5m]))'

# b) p99 admission review latency per resource kind
q 'histogram_quantile(0.99, sum by (le, resource_kind) (rate(kyverno_admission_review_duration_seconds_bucket[5m])))'

# c) Fraction of admission time NOT spent in the policy engine
q '1 - ( sum(rate(kyverno_policy_execution_duration_seconds_sum[5m])) / sum(rate(kyverno_admission_review_duration_seconds_sum[5m])) )'

# d) Slowest rules by mean execution time
q 'topk(5, sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_sum[5m])) / sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_count[5m])))'

# e) Rules loaded but not ready
q 'max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"})'

# f) Kyverno's own series count — watch your cardinality budget
q 'count({__name__=~"kyverno_.+"})'
```

6. Desplegá las reglas de alerta:

```yaml
# kyverno-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-slo
  namespace: monitoring
  labels:
    release: monitoring
spec:
  groups:
    - name: kyverno.availability
      rules:
        - alert: KyvernoMetricsAbsent
          expr: absent(kyverno_policy_rule_info_total)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno is exporting no metrics — the admission path is unobserved"

        - alert: KyvernoRuleNotReady
          expr: max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"}) == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Rule {{ $labels.rule_name }} of policy {{ $labels.policy_name }} is not ready"

    - name: kyverno.latency
      rules:
        - alert: KyvernoAdmissionLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, resource_kind) (
                rate(kyverno_admission_review_duration_seconds_bucket[5m])
              )
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 Kyverno admission latency for {{ $labels.resource_kind }} is above 1s"
            description: "Webhook timeoutSeconds is 10s with failurePolicy=Fail; at this rate a latency spike becomes a cluster-wide write outage."

    - name: kyverno.saturation
      rules:
        - alert: KyvernoControllerDroppingWork
          expr: sum by (controller_name) (rate(kyverno_controller_drop_total[10m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Controller {{ $labels.controller_name }} is dropping queue items — reports will be stale"

        - alert: KyvernoBlockRateSpike
          expr: |
            sum(rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[10m]))
              > 5 * sum(rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[1h] offset 1h))
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Enforce-mode denials are 5x the previous hour — a policy rollout may be breaking deployments"
```

```bash
kubectl apply -f kyverno-alerts.yaml
curl -s http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[] | select(.name|startswith("kyverno.")) | .name'
```

Salida esperada:

```
kyverno.availability
kyverno.latency
kyverno.saturation
```

### Preguntas de comprensión — bloque 7

- **Q7.1** — `serviceMonitorSelectorNilUsesHelmValues=false` se fijó en el momento de la instalación. ¿Qué sale mal exactamente si te lo olvidás, y cómo lo diagnosticarías — qué mostraría `kubectl get servicemonitor`, y qué mostraría la página de targets de Prometheus?
- **Q7.2** — El `PrometheusRule` lleva `labels: {release: monitoring}`. ¿Por qué? ¿Cuál es la perilla equivalente que se ajusta en el CR de Prometheus para que eso sea innecesario?
- **Q7.3** — La consulta (c) calcula `1 - (policy_execution_sum / admission_review_sum)`. Dá dos razones por las que esta relación puede superar 1,0 o volverse negativa, y cómo protegerías la expresión.
- **Q7.4** — La alerta `KyvernoAdmissionLatencyHigh` usa `sum by (le, ...)` dentro de `histogram_quantile`. ¿Qué pasa si omitís `le` en la cláusula `by`, y qué pasa si aplicás `histogram_quantile` antes que el `rate`?
- **Q7.5** — El `interval` de scrape es 30 s y el `scrapeTimeout` es 25 s. Después ponés `metricsRefreshInterval: 20s` en el ConfigMap de métricas "para tener datos más frescos". Describí la falla que eso produce en los resultados de `increase()` y `rate()`.

---

## Ejercicio 8 — Modo push: exportar a un OpenTelemetry Collector

### Pasos

1. Desplegá un collector mínimo que acepte OTLP/gRPC y reexponga un endpoint de Prometheus:

```yaml
# otel-collector.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      batch:
        timeout: 10s
    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
      debug:
        verbosity: basic
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [prometheus, debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: prom
              containerPort: 8889
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: prom
      port: 8889
      targetPort: prom
```

```bash
kubectl apply -f otel-collector.yaml
kubectl -n observability rollout status deploy/otel-collector
```

2. Pasá el admission controller de pull a push. Leé primero los flags actuales, y después parcheá:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'otel|metricsPort'
```

```bash
kubectl -n kyverno patch deploy kyverno-admission-controller --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--otelConfig=grpc"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--otelCollector=otel-collector.observability.svc.cluster.local"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--transportCreds="}
]'
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

> En la línea de comandos de Kyverno ganan los flags posteriores, así que agregar `--otelConfig=grpc` al final anula el `--otelConfig=prometheus` renderizado por el chart. Para un cambio duradero, fijá el value equivalente del chart en lugar de parchear.

3. Generá tráfico y confirmá que las métricas llegan al collector y no a Kyverno:

```bash
kubectl -n team-a run web3 --image=nginx:1.27 --labels=team=payments
sleep 20

kubectl -n observability port-forward svc/otel-collector 8889:8889 &
curl -s http://127.0.0.1:8889/metrics | grep '^kyverno_admission_requests_total'
```

Salida esperada:

```
kyverno_admission_requests_total{exported_job="kyverno",instance="",job="kyverno",resource_kind="Pod",resource_request_operation="create"} 1
```

4. Confirmá que el endpoint de Kyverno ahora está mudo:

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
curl -s -m 5 http://127.0.0.1:8000/metrics | grep -c '^kyverno_' || echo "no kyverno metrics served"
```

Salida esperada:

```
no kyverno metrics served
```

5. Volvé al modo pull para el resto del laboratorio:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

### Preguntas de comprensión — bloque 8

- **Q8.1** — `--otelConfig` acepta `prometheus` o `grpc`. Más allá de "pull vs push", dá dos propiedades operativas que cambian cuando pasás a `grpc` — una que mejora y una que empeora.
- **Q8.2** — `--transportCreds=` está puesto en la cadena vacía. ¿Qué configura eso, cuál es el valor correcto para producción, y cuál es el riesgo de dejarlo vacío en un clúster compartido?
- **Q8.3** — En la salida del collector apareció el label `exported_job="kyverno"` junto a `job="kyverno"`. ¿Qué produjo el prefijo `exported_`, y por qué importa para los dashboards escritos contra scrapes en modo pull?

---

## Ejercicio 9 — Práctica de troubleshooting

Recorré cada síntoma. No mires las respuestas hasta haber escrito tu propia escalera de hipótesis.

### Pasos

1. **Síntoma A.** Prometheus no muestra ninguna serie `kyverno_*`. Recorré la escalera de diagnóstico en orden y anotá qué prueba cada escalón:

```bash
# 1. Is metrics generation on at all?
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'disableMetrics|otelConfig|metricsPort'

# 2. Does the pod serve the endpoint?
kubectl -n kyverno exec deploy/kyverno-reports-controller -- true 2>/dev/null || \
kubectl -n kyverno run curl-probe --rm -it --restart=Never --image=curlimages/curl:8.11.0 -- \
  -s -o /dev/null -w '%{http_code}\n' http://kyverno-svc-metrics.kyverno.svc:8000/metrics

# 3. Does the Service select any endpoints?
kubectl -n kyverno get endpointslice -l kubernetes.io/service-name=kyverno-svc-metrics

# 4. Does a ServiceMonitor exist and does Prometheus own it?
kubectl -n kyverno get servicemonitor kyverno-admission-controller -o yaml | grep -A6 selector

# 5. Is the target registered?
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=dropped' \
  | jq -r '.data.droppedTargets[]?.discoveredLabels["__meta_kubernetes_service_name"]' | sort -u
```

2. **Síntoma B.** Reproducí la trampa de los counters con múltiples réplicas:

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=3
kubectl -n kyverno rollout status deploy/kyverno-admission-controller

for i in $(seq 1 20); do kubectl -n team-a run t$i --image=nginx:1.27 --labels=team=payments >/dev/null; done

q 'sum(increase(kyverno_admission_requests_total{resource_kind="Pod"}[10m]))'
q 'sum without (instance, pod) (increase(kyverno_admission_requests_total{resource_kind="Pod"}[10m]))'
```

3. **Síntoma C.** Reproducí un incidente de cardinalidad y medilo:

```bash
for n in $(seq 1 40); do kubectl create namespace tenant-$n >/dev/null; done
for n in $(seq 1 40); do kubectl -n tenant-$n run p --image=nginx:1.27 >/dev/null; done
sleep 30

q 'count({__name__=~"kyverno_.+"})'
q 'topk(5, count by (__name__) ({__name__=~"kyverno_.+"}))'
```

4. **Síntoma D.** Un panel de dashboard titulado "Policies blocking deployments" usa:

```promql
sum by (policy_name) (kyverno_policy_results_total{rule_result="fail"})
```

El panel muestra 4 policies. El equipo de plataforma insiste en que solo 1 policy está en modo Enforce. Reconciliá las dos afirmaciones sin cambiar las policies.

### Preguntas de comprensión — bloque 9

- **Q9.1** — En el Síntoma A, el escalón 3 (`endpointslice`) devuelve un EndpointSlice con `addresses: []`. ¿Cuáles dos escalones por encima quedan ahora probadamente *irrelevantes*, y cuál es la causa raíz más probable?
- **Q9.2** — En el Síntoma B, ambas consultas devuelven el mismo número en este laboratorio. Construí el escenario en el que difieren, e indicá cuál de las dos es siempre correcta.
- **Q9.3** — En el Síntoma C, agregar 40 namespaces multiplicó la cantidad de series. ¿Qué familias de métricas crecieron, cuáles no, y qué único cambio en el ConfigMap habría acotado el crecimiento sin perder visibilidad por policy?
- **Q9.4** — En el Síntoma D, explicá la discrepancia en una oración, y después escribí el PromQL corregido para el panel — incluyendo el arreglo del problema de counter-reset que la consulta original también tiene.

---

## Respuestas

<details>
<summary><strong>Clic para revelar las respuestas a todas las preguntas de comprensión</strong></summary>

### Bloque 1 — Mapear la superficie de métricas

**A1.1** — Desde 1.11 Kyverno está dividido en cuatro Deployments escalables de manera independiente: el admission controller (camino de las peticiones del webhook), el background controller (background scans y procesamiento de `UpdateRequest` para generate/mutate-existing), el reports controller (agregación de PolicyReport) y el cleanup controller (borrados por cron de `CleanupPolicy`). Cada uno es un proceso separado con su propio meter provider de OpenTelemetry, así que cada uno tiene su propio `/metrics`. Si solo hacés scrape de `kyverno-svc-metrics` obtenés el camino de admission y nada más: perdés todos los resultados con `rule_execution_cause="background_scan"`, todo `kyverno_cleanup_controller_deletedobjects_total`, y la salud de las work-queues (`kyverno_controller_drop_total`, `_requeue_total`) de los tres controllers que no son de admission — exactamente las métricas que necesitás cuando los reports quedan viejos o las reglas de generate dejan de dispararse. El camino de admission sigue en verde mientras el resto de Kyverno se degrada en silencio.

**A1.2** — `kyverno-svc:443` es el destino del `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration`: TLS mutuo, invocado por el kube-apiserver, respaldado por el puerto de contenedor 9443. `kyverno-svc-metrics:8000` es la exposición Prometheus en texto plano, respaldada por el puerto de contenedor 8000 (`metrics-port`). Deben permanecer separados porque el puerto del webhook es alcanzable por el API server y termina una sesión TLS cuyo CA bundle administra Kyverno; exponer un handler `/metrics` sin autenticación en ese mismo listener filtraría nombres de policies, nombres de namespaces y kinds de recursos — una divulgación de la topología del clúster — a cualquier cosa que pueda alcanzar el webhook, y además pondría trabajo no crítico en el listener de admission, que sí es crítico para la latencia. Puertos separados también te permiten aplicar una NetworkPolicy que admita al API server en 9443 y solo a Prometheus en 8000.

**A1.3** — `--disableMetrics` (por defecto `false`, es decir métricas *encendidas*) y `--otelConfig` (por defecto `prometheus`, es decir servir un endpoint de pull). Ambos deben mantener sus valores por defecto para que un scrape tenga éxito: `--disableMetrics=true` detiene por completo el registro de métricas, y `--otelConfig=grpc` sigue registrando pero empuja a un collector y deja de servir `/metrics`. `--metricsPort` (por defecto `8000`) determina *dónde*, pero no puede rescatar a ninguno de los otros dos.

**A1.4** — El selector del Service pasaría entonces a matchear todos los pods de Kyverno que lleven `app.kubernetes.io/instance: kyverno` y `app.kubernetes.io/part-of: kyverno` — los cuatro controllers. El EndpointSlice del Service listaría cuatro IPs de pod en el puerto 8000, y Prometheus (haciendo scrape vía el Service en una configuración de endpoints `static`/`kubernetes_sd` común) atribuiría las métricas de *los cuatro controllers* al job `kyverno-admission-controller`. Síntomas: `kyverno_cleanup_controller_deletedobjects_total` apareciendo bajo el job de admission, y counters que parecen saltar de manera errática porque distintos pods con distintos labels `instance` exportan valores diferentes para la misma familia. Notá que un `ServiceMonitor` de Prometheus Operator hace scrape de cada endpoint por separado con su propio label `pod`/`instance`, así que las series siguen siendo distinguibles — pero todo dashboard que filtre por `job` ahora está equivocado.

---

### Bloque 2 — Leer la exposición cruda

**A2.1** — Kyverno no usa directamente la librería cliente de Prometheus; se instrumenta con el **SDK de OpenTelemetry para Go** y renderiza el texto de Prometheus a través del exporter `prometheus` de OTel. Ese exporter estampa cada serie con el *scope* de instrumentación que creó el instrumento — `otel_scope_name` (acá `kyverno`) y `otel_scope_version` — más un gauge `target_info` que lleva los atributos de resource de OTel. Las consecuencias prácticas: (a) estos labels no están en la documentación de Kyverno porque no son de Kyverno, (b) agregan un par de labels constante a cada serie, así que `sum without (...)` y los joins con `group_left` tienen que tenerlos en cuenta, y (c) los mismos instrumentos pueden exportarse por OTLP/gRPC sin ningún cambio de código — que es justamente lo que explota el Ejercicio 8.

**A2.2** — Dos causas, ambas reales. Primero, **resets de counter**: el valor es por proceso, y cuando el pod del admission controller reinicia (rollout, OOM, drenaje de nodo) sus counters vuelven a cero. Segundo, **rotación de series**: cuando una policy o un namespace deja de producir tráfico, sus series eventualmente dejan de exportarse (favorecido por `metricsRefreshInterval`), y un `sum()` pelado de una serie que desaparece la saca del total. La consulta correcta nunca lee el valor crudo de un counter:

```promql
sum by (rule_result) (increase(kyverno_policy_results_total[1h]))
```

`rate()`/`increase()` son conscientes de los resets — detectan la caída a un valor más bajo y la tratan como un reinicio en vez de un delta negativo.

**A2.3** — Las convenciones de nomenclatura de Prometheus reservan el sufijo `_total` para los counters ([prometheus.io/docs/practices/naming/](https://prometheus.io/docs/practices/naming/)); un gauge con sufijo `_total` viola eso y va a confundir a cualquiera (y a cualquier linter o dashboard autogenerado) que infiera el tipo a partir del nombre. El valor **no** es un conteo acumulado — es `1` mientras la regla descrita por el conjunto de labels esté actualmente cargada en el engine, es decir, un gauge de estilo *info* cuya carga útil completa es su conjunto de labels. Por eso lo consultás con `== 1`, `count()`, o como destino de un join `group_left` — nunca con `rate()` ni `increase()`.

**A2.4** — Un histogram de Prometheus expone `<name>_bucket{le="..."}` (conteos acumulativos por límite superior, incluido `le="+Inf"`), `<name>_sum` (total de todos los valores observados) y `<name>_count` (cantidad de observaciones, igual al bucket `+Inf`). `histogram_quantile()` consume las series **`_bucket`**, y requiere que el label `le` se preserve a través de cualquier agregación:

```promql
histogram_quantile(0.95, sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m])))
```

---

### Bloque 3 — Atribuir la latencia

**A3.1** — Una admission request se abre en *N* evaluaciones de regla, donde *N* es la cantidad de reglas de todas las policies cuyo `match`/`exclude` selecciona ese recurso. `kyverno_admission_requests_total` cuenta **peticiones AdmissionReview** (una por cada escritura de API que llega al webhook); `kyverno_policy_results_total` cuenta **resultados de regla** (uno por cada regla evaluada). Para team-a, 2 peticiones × (1 regla de team-label + 1 regla de latest-tag) = 4 resultados, así que los dos números difieren legítimamente.

Para un SLI de "% de peticiones bloqueadas" el denominador correcto es `kyverno_admission_requests_total`, porque esa es la unidad que experimenta el usuario (un `kubectl apply` que falló). Usar `kyverno_policy_results_total` como denominador te da "% de evaluaciones de regla que fallaron", que es una métrica de calidad de policies, no de disponibilidad — y se mueve cada vez que agregás una policy no relacionada, porque el denominador crece mientras las fallas visibles para el usuario se mantienen constantes.

**A3.2** — La evaluación de reglas del engine es de menos de un milisegundo; la duración de la review es de punta a punta dentro de Kyverno. La brecha es todo lo que rodea a la evaluación:

1. **Deserialización y selección de policies** — desempaquetar el AdmissionReview, construir el `PolicyContext`, resolver qué policies matchean, y aplicar la caché de recursos / la carga diferida.
2. **Resolución de datos externos** — entradas de `context`: búsquedas de `configMap`, peticiones `apiCall` de vuelta al API server, `globalReference`, y para reglas `verifyImages` un viaje de red al registry OCI y a Rekor/Fulcio. Estos son el contribuyente dominante en clústeres reales y *no* se contabilizan de la misma manera en el histogram de ejecución por regla.
3. **Generación de reports y serialización de la respuesta** — construir el objeto AdmissionReport, generar el JSON patch para las reglas de mutate, calcular la respuesta, más el GC de Go y la latencia del scheduler dentro de un pod con recursos limitados.

Además, en un pod frío la primera petición paga el costo de sincronizar los informers y de compilar JMESPath/CEL. Operativamente: cuando la relación de la consulta (c) del Ejercicio 7 es alta, mirá `kyverno_client_queries_total` y las reglas `verifyImages` antes de culpar al engine.

**A3.3** — `policy_validation_mode` describe la failure action de **validate** (`Audit` o `Enforce`). Una regla de mutate no tiene failure action — o parchea o no; no puede "auditar" una mutación. Kyverno emite `-` como centinela explícito de *no aplica*. Lo mismo vale para las reglas de generate y cleanup.

**A3.4** — El otro valor es `background_scan`, emitido por el **background controller** cuando reevalúa recursos existentes de forma programada o después de un cambio de policy (solo para policies con `background: true`). Distinguir ambos es esencial: los resultados con causa de admission miden el comportamiento de bloqueo en vivo de tu webhook, mientras que los resultados de background scan miden el cumplimiento de tu *flota existente* y van a mostrar violaciones de recursos que fueron admitidos antes de que la policy existiera. Mezclarlos en un mismo panel hace que un despliegue de policy parezca una inundación de denegaciones nuevas cuando en realidad no se bloqueó nada.

**A3.5** —

```promql
histogram_quantile(0.99,
  sum by (le, resource_kind) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
) / 10
```

…alertando cuando esto supera ~0,3 (30 % del presupuesto de timeout). La serie `_count` por sí sola solo te dice *cuántas* reviews hubo, no cuánto duró ninguna de ellas; y la media derivada de `_sum / _count` esconde la cola — el p99 es lo que hace saltar un timeout de 10 segundos. Lo que está en juego con `failurePolicy: Fail` es que un timeout no es "policy salteada", es **la escritura de API es rechazada**: una regresión de latencia en Kyverno se convierte en una incapacidad de todo el clúster para crear recursos. Complementá el cuantil con una consulta directa de presupuesto sobre los límites de bucket:

```promql
1 - (
  sum(rate(kyverno_admission_review_duration_seconds_bucket{le="5"}[5m]))
  / sum(rate(kyverno_admission_review_duration_seconds_count[5m]))
)
```

— la fracción de reviews más lentas que 5 s, es decir, a mitad de camino del precipicio.

---

### Bloque 4 — Inventario de reglas y ciclo de vida

**A4.1** — `metricsRefreshInterval` en el ConfigMap `kyverno-metrics`. Las series de gauges y counters se mantienen en el registry del exporter durante toda la vida del proceso; sin un reset, cada policy y cada namespace de recurso que alguna vez produjo una muestra queda exportado para siempre, así que el endpoint crece monótonamente y Prometheus sigue ingiriendo series de objetos que ya no existen. `metricsRefreshInterval` desarma y vuelve a registrar periódicamente el meter provider, descartando las series que ya no se están escribiendo. Es un control de sangrado de cardinalidad, no un control de frescura.

**A4.2** — Un valor de label vacío en Prometheus es indistinguible de *que el label esté ausente*: `{policy_namespace=""}` matchea series que nunca tuvieron el label, y `sum by (policy_namespace)` colapsa "cluster-scoped" junto con cualquier serie donde el label fue descartado por `disabledLabelDimensions`. Usar el `-` literal convierte el alcance de clúster en un valor explícito y matcheable: `kyverno_policy_rule_info_total{policy_namespace="-"}` selecciona exactamente las ClusterPolicies, y `!="-"` selecciona exactamente las Policies namespaced. Sin eso no podés escribir ninguna de las dos consultas de manera confiable.

**A4.3** —

```promql
max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"}) == 1
```

`status_ready` es un **label**, no el valor. El valor del gauge es `1` para "esta regla está actualmente cargada"; una regla no lista es por lo tanto `kyverno_policy_rule_info_total{status_ready="false"} = 1`. Escribir `== 0` no matchearía nada en el caso normal y solo llegaría a dispararse ante un valor transitorio del que no deberías depender. El `max by (...)` colapsa a múltiples réplicas del admission controller que reportan la misma regla, así que un deployment de 3 réplicas produce una instancia de alerta en vez de tres. En la práctica, una regla no lista significa que Kyverno parseó la policy pero no pudo activarla (una llamada `context` a la API mal formada, un CRD faltante, un hueco de RBAC para un destino de generate/mutate-existing) — la policy existe, aparece en `kubectl get cpol`, y no está haciendo cumplir nada.

---

### Bloque 5 — Background, cleanup y presión sobre la API

**A5.1** — Los background scans no están impulsados por un AdmissionReview, así que no hay operación `CREATE`/`UPDATE`/`DELETE` para reportar; Kyverno emite la cadena vacía. En consecuencia, una consulta filtrada por `resource_request_operation="create"` **excluye silenciosamente todos los resultados de background**, que es lo opuesto a lo que pretende la mayoría cuando arma un dashboard de cumplimiento. O filtrás explícitamente por la causa (`rule_execution_cause="admission_request"`) — más claro y autodocumentado — o sacás el filtro de operación y agregás con `sum without (resource_request_operation)`.

**A5.2** — Solo el admission controller corre el servidor de webhook, así que solo él recibe alguna vez un AdmissionReview; los controllers de background, reports y cleanup reconcilian a través de informers y de la API, nunca a través del camino del webhook. Esas dos familias de métricas, por lo tanto, no pueden existir en otro lado. Las familias presentes en **los cuatro** son el conjunto de work-queue de controller-runtime — `kyverno_controller_reconcile_total`, `kyverno_controller_requeue_total`, `kyverno_controller_drop_total` — más `kyverno_client_queries_total`; todo controller tiene colas y todo controller le habla al API server. (Notá que `kyverno_client_queries_total` desaparece si la desactivaste en el Ejercicio 6.)

**A5.3** — En una work queue con rate limiting de controller-runtime, un ítem que falla se reencola con backoff hasta una cantidad máxima de intentos (`num_requeues` en la métrica de requeue); cuando se alcanza ese techo el ítem es **descartado** — olvidado, nunca reintentado, sin ningún error expuesto al usuario. Para el reports controller el síntoma visible para el usuario son **PolicyReports viejos o faltantes**: `kubectl get polr` muestra resultados que no reflejan el estado actual del clúster, los dashboards de cumplimiento sub-reportan violaciones, y nada en los logs de Kyverno parece una caída. Este es el modo de falla de Kyverno menos monitoreado de todos; `rate(kyverno_controller_drop_total[10m]) > 0` sostenido siempre es un incidente real.

**A5.4** — El **metadata client** (`k8s.io/client-go/metadata`) pide objetos con `Accept: application/json;as=PartialObjectMetadata`, así que el API server devuelve solo `TypeMeta` + `ObjectMeta` — nombre, namespace, labels, annotations, ownerRefs — y nunca el spec ni el status. Kyverno lo usa donde solo necesita identidad y labels: pertenencia de reports, recolección de basura de reports, y matcheo de recursos por selector. Conteos altos de `client_type="metadata"` son buenas noticias porque cada una de esas consultas transfiere una fracción de los bytes que transferiría un objeto completo, y mantiene los objetos grandes afuera de las cachés de informers de Kyverno — la diferencia entre unos cientos de MB y varios GB de RSS en un clúster con muchos Secrets o ConfigMaps. La señal preocupante es un `client_type="dynamic"` alto con `operation="List"`, que significa llamadas de list de objetos completos contra el API server.

---

### Bloque 6 — Control de cardinalidad

**A6.1** — `0` desactiva el refresco periódico: el meter provider nunca se desarma, así que toda serie alguna vez emitida se exporta durante toda la vida del proceso. Poner `6h` hace que Kyverno resetee y vuelva a registrar sus instrumentos cada seis horas, descartando series de policies, namespaces y kinds de recursos que ya no producen datos — ese es el control del sangrado de cardinalidad.

Lo que perdés: **todos los counters reinician desde cero en cada refresco**. `increase()` y `rate()` manejan esto correctamente porque son conscientes de los resets, pero cualquier dashboard o consulta que lea un valor crudo de counter ("total de denegaciones desde la instalación") pierde sentido, y un `increase()` sobre una ventana *más larga que* el intervalo de refresco pierde precisión en el borde. Regla: poné `metricsRefreshInterval` cómodamente más largo que tu rango de consulta más largo, y nunca leas valores crudos de counters.

**A6.2** — `namespaces.exclude` filtra la **emisión de métricas**, con clave en el namespace *del recurso* (`resource_namespace`). No filtra la evaluación de policies, ni la admission, ni el reporting: el Pod de `kube-system` igual fue enviado al webhook, igual fue evaluado por cada regla que matcheaba, e igual produjo un PolicyReport. Lo único que cambió es que no se registró ninguna serie temporal para él.

Este es un punto ciego que tenés que documentar explícitamente, porque el invariante "podemos ver todo lo que hace Kyverno" ahora es falso para esos namespaces. Concretamente: una policy en modo Enforce que empiece a bloquear cargas de trabajo de `kube-system` — rompiendo pods de CNI, CSI o DNS — va a producir **cero** señal en Prometheus y **cero** alertas disparadas, mientras el clúster se degrada. El patrón correcto es excluir namespaces de las *métricas* solo donde también los excluís de las *policies* (vía los `resourceFilters` de Kyverno en el ConfigMap principal `kyverno`), para que las dos exclusiones se mantengan sincronizadas. Si un namespace está policeado, tiene que estar medido.

**A6.3** — Sí, es consistente. `disabledLabelDimensions` se configura **por familia de métricas**, no globalmente. La configuración aplicada quita `resource_namespace` *y* `resource_kind` de `kyverno_policy_results_total`… pero la segunda muestra sigue mostrando `resource_kind="Pod"`.

Esa inconsistencia es el punto de la pregunta: si la observás en tu propio laboratorio, significa que el pod que sirve esa muestra **no** había tomado el ConfigMap nuevo — estás mirando una serie registrada por el proceso previo al reinicio (o por una segunda réplica que no fue reiniciada), y el exporter todavía la retiene. Se resuelve en el siguiente `metricsRefreshInterval` o con un rollout completo de todas las réplicas. La lección: después de cambiar `metricsExposure`, verificá en **cada** pod (`kubectl get pods -l app.kubernetes.io/component=admission-controller`) y confirmá que el label viejo esté ausente de *todas* las muestras, no solo de la primera que devuelve `grep`. No asumas hot reload; rotá el Deployment.

**A6.4** — Un histogram con *B* límites configurados exporta `B + 1` series de bucket (los límites más `+Inf`), más `_sum` y `_count` — o sea `B + 3` series por combinación de labels.

- Antes: `(15 + 3) × 40 = 720` series
- Después: `(11 + 3) × 40 = 560` series
- Eliminadas: **160 series**

La fórmula general es `Δseries = (B_antes − B_después) × L`, donde *L* es la cantidad de combinaciones distintas de labels. Notá cómo el multiplicador juega en tu contra: recortar cuatro límites ahorró 160 series acá, pero en un clúster donde *L* es 5 000 (muchos namespaces × muchos kinds) esos mismos cuatro límites cuestan 20 000 series. Reducir *L* vía `disabledLabelDimensions` es casi siempre el cambio de mayor palanca.

**A6.5** — Perdés la capacidad de diagnosticar **presión sobre el API server inducida por Kyverno**: el incidente donde la latencia del API server y sus colas de priority-and-fairness se degradan y necesitás demostrar si Kyverno es causa o víctima. `kyverno_client_queries_total` desglosada por `client_type` y `operation` es la evidencia directa — por ejemplo, un `context.apiCall` en una policy caliente emitiendo un `List` por cada admission request, o una tormenta de resync de informers después de un rollout.

Alternativas, en orden decreciente de utilidad: las propias métricas del API server `apiserver_request_total{user_agent=~"kyverno.*"}` y `apiserver_flowcontrol_*` (autoritativas, y fuera del control de Kyverno, así que sobreviven a que Kyverno esté caído); los audit logs filtrados por las service accounts de Kyverno; y, como proxy débil, la brecha entre `kyverno_admission_review_duration_seconds` y `kyverno_policy_execution_duration_seconds` de la pregunta A3.2, que crece cuando las búsquedas de context son el cuello de botella. Dado que la métrica del API server existe, desactivar `kyverno_client_queries_total` es un trade defendible en un clúster muy grande — pero solo si confirmaste que el lado del API server está siendo scrapeado.

---

### Bloque 7 — Prometheus, PromQL, alertas

**A7.1** — `kube-prometheus-stack` deja por defecto el `serviceMonitorSelector` del CR de Prometheus en `{matchLabels: {release: <nombre-del-release-de-helm>}}`, así que solo adopta ServiceMonitors que lleven ese label. El chart de Kyverno no lo agrega. Olvidarte del flag significa que los cuatro ServiceMonitors de Kyverno se crean y están sanos pero **nunca son adoptados**.

Diagnóstico: `kubectl -n kyverno get servicemonitor` muestra los cuatro objetos (o sea, el recurso existe — este escalón no prueba nada), mientras que la página de **Targets** de Prometheus no muestra ningún job `kyverno-*` — no "down", *ausente*. Confirmalo leyendo qué selecciona Prometheus realmente:

```bash
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorNamespaceSelector}'
```

y revisando la configuración de scrape generada (`kubectl -n monitoring get secret prometheus-<name> -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep kyverno`). Dos arreglos: poner `serviceMonitorSelectorNilUsesHelmValues=false` (adoptar todo), o etiquetar los ServiceMonitors de Kyverno con `release: monitoring` vía `--set admissionController.serviceMonitor.additionalLabels.release=monitoring`. El segundo es la mejor opción para producción — mantiene el selector con sentido.

**A7.2** — Mismo mecanismo, campo distinto: el `ruleSelector` del CR de Prometheus también queda por defecto en `{matchLabels: {release: <release>}}`, así que un `PrometheusRule` sin ese label es ignorado — en silencio, sin ningún error en `kubectl apply`. Agregar `labels: {release: monitoring}` lo hace adoptable. La perilla equivalente del lado del CR es `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false` (usada en el momento de la instalación en el paso 1), que anula el selector para que todos los objetos `PrometheusRule` en los namespaces vigilados sean adoptados. Verificá también que `ruleNamespaceSelector` cubra el namespace donde desplegaste.

**A7.3** — Dos razones por las que puede salirse de rango:

1. **Denominadores distintos.** `kyverno_policy_execution_duration_seconds` también se emite para ejecuciones de background scan, mientras que `kyverno_admission_review_duration_seconds` solo existe para admission requests. Durante un background scan el numerador incluye trabajo que el denominador nunca vio, así que la relación puede superar 1 y la expresión se vuelve negativa. Restringí el numerador: `{rule_execution_cause="admission_request"}`.
2. **División por cero / sin tráfico.** Sin admission requests en la ventana, el `rate()` del denominador es 0 o la serie está ausente, dando `+Inf` o un resultado vacío.

Versión protegida:

```promql
clamp_min(
  clamp_max(
    1 - (
      sum(rate(kyverno_policy_execution_duration_seconds_sum{rule_execution_cause="admission_request"}[5m]))
      /
      clamp_min(sum(rate(kyverno_admission_review_duration_seconds_sum[5m])), 0.0001)
    ), 1),
  0)
```

Una tercera razón, más sutil: con múltiples réplicas las dos familias se suman sobre el mismo conjunto de pods, así que un pod que reinició a mitad de la ventana aporta un reset a una familia y no a la otra. Mantené la ventana corta en relación con la frecuencia de reinicios.

**A7.4** — Omitir `le` en la cláusula `by` suma las series de bucket *a través de* los límites superiores, destruyendo la estructura acumulativa que codifica el histogram. `histogram_quantile()` entonces devuelve `NaN` o un valor sin sentido — y, críticamente, no da error, así que el panel muestra un número que parece plausible y simplemente está mal. `le` siempre tiene que sobrevivir a la agregación.

Aplicar `histogram_quantile()` antes de `rate()` está mal de otra manera: las series `_bucket` crudas son counters monótonamente crecientes sobre toda la vida del proceso, así que el cuantil que calculás es el cuantil histórico desde el arranque del pod, fuertemente pesado por el historial e incapaz de mostrar una regresión actual — y se rompe por completo ante un reset de counter. El invariante es: **`rate()` primero (por `le`), agregar después (conservando `le`), `histogram_quantile()` al final.**

**A7.5** — Un `metricsRefreshInterval` más corto que — o cercano a — el intervalo de scrape significa que los counters se resetean *entre* scrapes, a veces más de una vez. Prometheus detecta un reset de counter al ver un valor más bajo que la muestra anterior y compensa sumando el valor previo al reset; esa lógica solo es correcta cuando observa al menos una muestra a cada lado del reset. Con un reset de 20 s y un scrape de 30 s, Prometheus ve con frecuencia un reset que no puede acotar, y los incrementos que ocurrieron enteramente dentro de una ventana de reset se pierden para siempre.

Síntomas: `rate()` e `increase()` **sub-reportan** sistemáticamente, con un gráfico dentado y con picos; los totales no reconcilian con la realidad; y las alertas sobre tasa de denegaciones nunca se disparan porque la tasa siempre está cerca de cero. La regla es `metricsRefreshInterval >> scrape_interval` — horas, no segundos. El valor por defecto de `0` (nunca) y los valores recomendados de `6h`–`24h` existen exactamente por esta razón; el ajuste es un control de cardinalidad, y tratarlo como un control de frescura corrompe todas las consultas derivadas de counters que tengas.

---

### Bloque 8 — Modo push OTLP

**A8.1** — Mejora: **no se requiere ningún camino de red entrante.** En modo push Kyverno inicia una conexión gRPC saliente hacia el collector, así que ya no necesitás que Prometheus alcance el puerto 8000 en cada pod de Kyverno. Eso elimina excepciones de NetworkPolicy y de firewall, funciona a través de fronteras de clúster y de VPC, y hace seguros a los pods de vida corta — las métricas registradas justo antes de que un pod termine se exportan en vez de perderse entre scrapes. También habilita el pipeline de processors del collector (batching, filtrado, reescritura de atributos, tail sampling, fan-out a múltiples backends) sin tocar Kyverno.

Empeora: **perdés la liveness basada en scrape y las garantías de entrega.** Con pull, un target de Prometheus que pasa a `down` es en sí mismo una señal de que Kyverno es inalcanzable, y las alertas `up == 0` te salen gratis. Con push, un pod de Kyverno que deja de exportar es indistinguible de un pod de Kyverno que no tiene nada para reportar — `absent()` es tu único detector y es lento y grueso. Además agregás una dependencia dura del collector: si está caído, saturado o mal configurado, las métricas se descartan en vuelo (las fallas de exportación OTLP aparecen solo en los logs de Kyverno), y ahora tenés un segundo componente que planificar en capacidad, actualizar y monitorear.

**A8.2** — `--transportCreds` es la ruta a un archivo de certificado de CA usado para establecer **TLS en la conexión OTLP/gRPC hacia el collector**. La cadena vacía selecciona una conexión gRPC **insegura** (texto plano). Lo correcto para producción es montar un CA bundle dentro del pod de Kyverno y pasar su ruta, con el collector configurado para TLS en su receiver OTLP.

El riesgo de dejarlo vacío en un clúster compartido: el flujo OTLP transporta nombres de policies, nombres de reglas, nombres de namespaces y kinds de recursos en texto claro por la red de pods — un mapa de tu postura de seguridad y de la topología del clúster, útil para que un atacante encuentre qué namespaces están sin policear. Tampoco hay autenticación del servidor, así que cualquier carga de trabajo que pueda ganar el nombre del Service (o interceptar el tráfico) puede absorber silenciosamente la telemetría de Kyverno, y nada en Kyverno va a reportar una anomalía.

**A8.3** — Prometheus renombra un label de una muestra ingerida cuando colisionaría con un label que el propio Prometheus adjunta durante el scrape. Acá el exporter `prometheus` del collector reexpuso una serie que ya llevaba `job="kyverno"` (proveniente de los atributos de resource de OTel / `target_info`), y cuando Prometheus hizo scrape del collector aplicó su propio label `job` para el target del collector — así que el original se preservó como `exported_job`. Lo mismo pasa con `instance`.

Por qué importa: **cada dashboard y alerta escrita contra scrapes en modo pull se rompe por el conjunto de labels, no por el nombre de la métrica.** Las consultas que agrupan por `job` ahora agrupan por el collector, no por Kyverno; las consultas que filtran `job="kyverno-admission-controller"` no devuelven nada; y el label `instance` — que en modo pull identificaba al pod de Kyverno — ahora identifica al collector, colapsando la visibilidad por réplica. Arreglos, en orden de preferencia: poner `honor_labels: true` en el scrape de Prometheus hacia el collector (mantiene los valores exportados bajo sus nombres originales), o normalizar en el pipeline del collector con un processor `transform`/`attributes` antes del exporter. Verificá el conjunto de labels después de cualquier migración pull→push; que los nombres de las métricas sobrevivan no es evidencia de que las consultas hayan sobrevivido.

---

### Bloque 9 — Troubleshooting

**A9.1** — Un EndpointSlice que existe pero no tiene direcciones prueba que el objeto Service y su selector están bien y que la configuración del lado de Prometheus todavía no entra en juego, así que **el escalón 4 (selector del ServiceMonitor) y el escalón 5 (descubrimiento de targets) son irrelevantes** — Prometheus no puede hacer scrape de un endpoint que no existe, sin importar cómo esté etiquetado el ServiceMonitor. El escalón 1 (flags) también queda aguas abajo de esto: la configuración del proceso no puede importar si no hay ningún pod respaldando al Service.

Causa raíz más probable: **ningún pod ready matchea el selector del Service.** O bien los pods no están `Ready` (readiness probe fallando, `CrashLoopBackOff`, image pull, scheduling pendiente), o bien los labels del pod ya no matchean el selector — lo que pasa después de un upgrade de chart que renombra un label de componente, o cuando alguien edita el Service. Revisá en ese orden:

```bash
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide
kubectl -n kyverno describe svc kyverno-svc-metrics | grep -i endpoints
```

Un EndpointSlice vacío con pods `Running` sanos significa un **desajuste de labels**; uno vacío sin pods listados significa un problema de **scheduling o de crash**.

**A9.2** — Difieren apenas el counter de un pod individual se **resetea** — un rollout, un OOM kill, un desalojo, o el disparo de `metricsRefreshInterval`.

- `sum(increase(...))` aplica `increase()` **primero por serie** (el counter de cada pod se corrige por reset de forma aislada) y después suma los incrementos corregidos. Correcto.
- `sum without (instance, pod) (increase(...))` también calcula `increase()` por serie antes de sumar — acá `sum without` solo controla qué labels sobreviven, así que en esta forma es equivalente.

La forma genuinamente incorrecta — de la que trata esta trampa — es agregar **antes** de la función de rate:

```promql
increase(sum(kyverno_admission_requests_total{resource_kind="Pod"})[10m:])   # WRONG
```

Sumar primero a través de los pods produce una serie compuesta que baja cada vez que *cualquier* pod individual reinicia, mientras los demás siguen subiendo. `increase()` ve una caída menor que un reset completo y o bien la malinterpreta o descarta el intervalo, así que sub-contás aproximadamente el total acumulado del pod que reinició. **Siempre `rate()`/`increase()` por serie, y después `sum()`.** Es el mismo invariante de orden que en A7.4.

**A9.3** — Crecieron: todas las familias que llevan `resource_namespace` — `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds` (×(B+3) por namespace, la peor infractora porque es un histogram), `kyverno_policy_results_total`, `kyverno_policy_execution_duration_seconds` y `kyverno_client_queries_total`. Los histograms dominan: 40 namespaces × 18 series cada uno son 720 series nuevas de una sola familia.

No crecieron: `kyverno_policy_rule_info_total` y `kyverno_policy_changes_total` — ambas tienen clave en `policy_namespace` (el namespace de la *policy*, `-` para las ClusterPolicies), no en el namespace del recurso. Tampoco crecieron las métricas de cola de los controllers, que tienen clave solo en `controller_name`.

El único cambio que lo acota es `disabledLabelDimensions: ["resource_namespace"]` sobre las familias infractoras en `metricsExposure`. Quita la dimensión no acotada — la cantidad de namespaces crece con los tenants, para siempre — mientras conserva `policy_name`, `rule_name`, `rule_result` y `rule_type`, así que la visibilidad por policy queda totalmente intacta. `namespaces.exclude` *no* habría servido acá: no podés enumerar los namespaces de tenant por adelantado, y excluirlos crearía el punto ciego de A6.2 exactamente en los namespaces que más necesitás vigilar.

**A9.4** — En una oración: el panel cuenta **todos** los resultados de regla fallidos, incluidos los de policies en modo `Audit`, que detectan y reportan violaciones sin bloquear nada, así que tres de las cuatro policies "bloqueantes" simplemente están observando.

PromQL corregido, arreglando tanto el filtro de modo como el problema de counter-reset del original:

```promql
sum by (policy_name) (
  increase(
    kyverno_policy_results_total{
      policy_validation_mode="Enforce",
      rule_result="fail",
      rule_execution_cause="admission_request"
    }[1h]
  )
)
```

Tres arreglos, todos necesarios: `policy_validation_mode="Enforce"` restringe a las policies que efectivamente rechazan la petición; `increase(...[1h])` reemplaza el valor crudo del counter para que los reinicios de pods y los resets de `metricsRefreshInterval` no corrompan el número (A2.2); y `rule_execution_cause="admission_request"` excluye las violaciones de background scan, que son hallazgos sobre recursos preexistentes, no despliegues que fueron bloqueados (A3.4). Sin el tercer filtro el panel pega un pico cada vez que alguien edita una policy y dispara un rescan — la falsa alarma clásica que entrena a los equipos a ignorar el dashboard.

Salvedad que vale la pena aclarar en el propio panel: una regla en modo Enforce que falla no *siempre* bloquea, porque `failureActionOverrides` puede degradar namespaces específicos a Audit. Si usás overrides, el label refleja el modo declarado de la regla y tenés que reconciliar contra `kyverno_admission_requests_total` para confirmar que la petición fue efectivamente rechazada.

</details>

---

## Fuentes

- Kyverno — Referencia de monitoring y métricas: <https://kyverno.io/docs/monitoring/>
- Kyverno — Instalación y configuración (flags de los controllers, configuración de métricas): <https://kyverno.io/docs/installation/customization/>
- Values del chart de Helm de Kyverno (`metricsConfig`, `serviceMonitor`, `grafana`): <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml>
- Kyverno — Cleanup policies: <https://kyverno.io/docs/policy-types/cleanup-policy/>
- Prometheus — Convenciones de nomenclatura de métricas y labels: <https://prometheus.io/docs/practices/naming/>
- Prometheus — Histograms, cuantiles e `histogram_quantile`: <https://prometheus.io/docs/practices/histograms/>
- Prometheus Operator — API de `ServiceMonitor` y `PrometheusRule`: <https://prometheus-operator.dev/docs/api-reference/api/>
- OpenTelemetry Collector — configuración y receivers: <https://opentelemetry.io/docs/collector/configuration/>
- CNCF — Temario de KCA: <https://github.com/cncf/curriculum>