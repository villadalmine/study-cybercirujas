# Tema 6.1 — Policy Reports · Ejercicios guiados

> **Contexto de examen (KCA, dominio 6, peso 3.33 %).** Los Policy Reports son la manera en que Kyverno indica *cómo se ve el clúster ahora mismo* respecto de las políticas — como objetos Kubernetes de primera clase, no como líneas de log. El examen espera que se localice un reporte, se lo lea, se explique de dónde salió cada campo y se diagnostique por qué falta un reporte que se esperaba.

---

## Entorno de laboratorio

Estos ejercicios asumen un clúster descartable. Todo queda dentro de un namespace o se elimina en la sección de limpieza.

```bash
kind create cluster --name kca-reports --image kindest/node:v1.31.0

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm search repo kyverno/kyverno --versions | head -5

# Pick a recent 1.x line; record what you actually installed.
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7 \
  --wait
```

Registrar la versión antes que nada — dos cambios de esquema descritos más abajo dependen de ella:

```bash
kubectl -n kyverno get deploy -o custom-columns=NAME:.metadata.name,IMAGE:'.spec.template.spec.containers[*].image'
```

```text
NAME                          IMAGE
kyverno-admission-controller  reg.kyverno.io/kyverno/kyverno:v1.13.4
kyverno-background-controller reg.kyverno.io/kyverno/kyverno:v1.13.4
kyverno-cleanup-controller    reg.kyverno.io/kyverno/cleanup-controller:v1.13.4
kyverno-reports-controller    reg.kyverno.io/kyverno/reports-controller:v1.13.4
```

Dos detalles que dependen de la versión, señalados aquí una sola vez para que los ejercicios se mantengan legibles:

| Aspecto | ≤ 1.12 | 1.13 + |
|---|---|---|
| Audit frente a Enforce | `spec.validationFailureAction: Audit` | `spec.rules[].validate.failureAction: Audit` |
| Grupo de API de los reportes | `wgpolicyk8s.io/v1alpha2` (`PolicyReport`, `ClusterPolicyReport`) | igual, más las versiones recientes que migran a la API OpenReports (`openreports.io`), cuya disposición de campos es deliberadamente idéntica |

Cada vez que un ejercicio muestre un campo que el clúster rechace, ejecutar el `kubectl explain` correspondiente y usar lo que registre *su* API server. Ese hábito vale más que memorizar el esquema de una versión concreta.

---

## Ejercicio 1 — Mapear la superficie de la API de reportes antes de producir un solo resultado

1. Listar todos los kinds del grupo wg-policy:

   ```bash
   kubectl api-resources --api-group=wgpolicyk8s.io
   ```

   ```text
   NAME                   SHORTNAMES   APIVERSION                    NAMESPACED   KIND
   clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2       false        ClusterPolicyReport
   policyreports          polr         wgpolicyk8s.io/v1alpha2       true         PolicyReport
   ```

2. Comprobar si la versión instalada también registra el sucesor OpenReports y los kinds de reporte internos de Kyverno:

   ```bash
   kubectl api-resources | grep -Ei 'openreports|reports\.kyverno\.io'
   ```

   ```text
   clusterephemeralreports   cephr    reports.kyverno.io/v1   false   ClusterEphemeralReport
   ephemeralreports          ephr     reports.kyverno.io/v1   true    EphemeralReport
   ```

3. Leer el esquema de los resultados directamente desde el API server — esta es la forma segura, de cara al examen, de recordar los nombres de los campos:

   ```bash
   kubectl explain polr.summary
   kubectl explain polr.results --recursive | head -30
   ```

4. Identificar qué controlador es dueño de cada kind:

   ```bash
   kubectl -n kyverno get deploy
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
   ```

**Comprobación de comprensión**

- **Q1.1** — `PolicyReport` está dentro de un namespace y `ClusterPolicyReport` no. ¿Cuál contiene el resultado de un `ClusterRole` que incumple, y cuál el de un `Pod` que incumple?
- **Q1.2** — ¿Para qué sirve un `EphemeralReport` (`ephr`) y por qué nunca hay que construir tooling ni alertas sobre él?
- **Q1.3** — Hay cuatro deployments de Kyverno en ejecución. ¿Cuál escribe los objetos `PolicyReport` y cuál bloquea una petición en tiempo de admission?

---

## Ejercicio 2 — Producir el primer resultado `fail` en modo Audit

1. Crear el namespace del laboratorio:

   ```bash
   kubectl create namespace reports-lab
   ```

2. Escribir la política. Nótese que las anotaciones de metadata no son decoración: aterrizan literalmente en el reporte.

   ```yaml
   # require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
     annotations:
       policies.kyverno.io/title: Require team label
       policies.kyverno.io/category: Governance
       policies.kyverno.io/severity: medium
       policies.kyverno.io/description: >-
         Every Pod must carry a `team` label so that cost and on-call ownership
         can be attributed without consulting a spreadsheet.
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
                   - reports-lab
         validate:
           failureAction: Audit      # <=1.12: remove this and set spec.validationFailureAction: Audit
           message: "The label `team` is required."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f require-team-label.yaml
   kubectl get cpol require-team-label
   ```

   ```text
   NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
   require-team-label   true        true         True    5s    Ready
   ```

3. Crear una carga de trabajo que incumpla:

   ```bash
   kubectl -n reports-lab create deployment web --image=nginx:1.27
   kubectl -n reports-lab wait --for=condition=Available deploy/web --timeout=60s
   ```

4. Observar qué apareció:

   ```bash
   kubectl -n reports-lab get polr
   ```

   ```text
   NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
   3f2a6c1e-9d4b-4a77-8f0e-2c5b1a7e91d0   Deployment   web        0      1      0      0       0      12s
   9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11   Pod          web-6f...  0      1      0      0       0      10s
   ```

   (Las columnas de impresión varían entre versiones del CRD; lo que importa son los conteos.)

5. Demostrar de dónde sale el *nombre* del reporte:

   ```bash
   kubectl -n reports-lab get pod -l app=web -o jsonpath='{.items[0].metadata.uid}{"\n"}'
   kubectl -n reports-lab get polr -o name
   ```

6. Contar cuántos reportes existen — el Deployment también creó un ReplicaSet:

   ```bash
   kubectl -n reports-lab get deploy,rs,pod --no-headers | wc -l
   kubectl -n reports-lab get polr --no-headers | wc -l
   ```

**Comprobación de comprensión**

- **Q2.1** — El bloque `match` de la política solo nombra `Pod` y, sin embargo, existe un reporte para el `Deployment`. ¿Qué produjo ese segundo resultado y cómo se llamará el campo `rule` de ese resultado?
- **Q2.2** — Existen tres objetos de carga de trabajo (Deployment, ReplicaSet, Pod) pero solo dos reportes. ¿Por qué no se reporta sobre el ReplicaSet?
- **Q2.3** — ¿Qué relación hay entre el `metadata.name` de un reporte y el recurso que describe, y qué consecuencia práctica tiene ese esquema de nombres cuando se quiere buscar «el reporte del pod X»?
- **Q2.4** — Kyverno pasó de un reporte por namespace (≤1.9) a un reporte por recurso (1.10+). Nombrar el problema de escalado que motivó el cambio.

---

## Ejercicio 3 — Anatomía de un resultado: cada campo y de dónde salió

1. Volcar completo el reporte del Pod:

   ```bash
   POLR=$(kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.scope.kind}{"\n"}{end}' | awk '$2=="Pod"{print $1}')
   kubectl -n reports-lab get polr "$POLR" -o yaml
   ```

   ```yaml
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: PolicyReport
   metadata:
     name: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
     namespace: reports-lab
     labels:
       app.kubernetes.io/managed-by: kyverno
     ownerReferences:
       - apiVersion: v1
         kind: Pod
         name: web-6f8c9d7b5c-hq2xn
         uid: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
   scope:
     apiVersion: v1
     kind: Pod
     name: web-6f8c9d7b5c-hq2xn
     namespace: reports-lab
     uid: 9b7c4d02-1e88-4c3a-b5aa-6d0f3e2c8a11
   summary:
     pass: 0
     fail: 1
     warn: 0
     error: 0
     skip: 0
   results:
     - source: kyverno
       policy: require-team-label
       rule: check-team-label
       category: Governance
       severity: medium
       result: fail
       scored: true
       message: >-
         validation error: The label `team` is required.
         rule check-team-label failed at path /metadata/labels/team/
       timestamp:
         seconds: 1786982400
         nanos: 0
   ```

2. Correlacionar tres campos con su origen:

   ```bash
   kubectl get cpol require-team-label -o jsonpath='{.metadata.annotations}' | tr ',' '\n'
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.results[0].category}{" / "}{.results[0].severity}{"\n"}'
   ```

3. Inspeccionar las labels y cualquier mapa `properties` que escriba la versión instalada — así se distingue un resultado producido en admission de uno producido por un background scan:

   ```bash
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.metadata.labels}' | tr ',' '\n'
   kubectl -n reports-lab get polr "$POLR" -o jsonpath='{.results[0].properties}{"\n"}'
   ```

4. Convertir el hallazgo en no puntuado y observar cómo el veredicto cambia de clase:

   ```bash
   kubectl annotate cpol require-team-label policies.kyverno.io/scored="false" --overwrite
   kubectl -n reports-lab delete pod -l app=web
   sleep 20
   kubectl -n reports-lab get polr
   ```

   ```text
   NAME                                   KIND         NAME       PASS   FAIL   WARN   ERROR   SKIP   AGE
   3f2a6c1e-9d4b-4a77-8f0e-2c5b1a7e91d0   Deployment   web        0      0      1      0       0      3m
   c1d5e7f9-2a3b-4c5d-8e9f-0a1b2c3d4e5f   Pod          web-9x...  0      0      1      0       0      18s
   ```

5. Revertirlo:

   ```bash
   kubectl annotate cpol require-team-label policies.kyverno.io/scored- 
   ```

**Comprobación de comprensión**

- **Q3.1** — Asociar cada uno de `category`, `severity`, `policy`, `rule`, `scope` y `source` con el lugar del que Kyverno lo obtuvo.
- **Q3.2** — Dar el significado preciso de los cinco valores de resultado: `pass`, `fail`, `warn`, `error`, `skip`. ¿Cuál indica un problema con la *política* y no con el recurso?
- **Q3.3** — ¿Qué cambió `policies.kyverno.io/scored: "false"` y cuándo convendría publicar deliberadamente una política sin puntuar?
- **Q3.4** — El reporte lleva una entrada `ownerReferences` que apunta al Pod. Nombrar dos comportamientos que se obtienen gratis gracias a ello.
- **Q3.5** — `summary` duplica información que ya es derivable de `results`. ¿Por qué el CRD lo incluye igualmente?

---

## Ejercicio 4 — Audit frente a Enforce: lo que Enforce *no* pone en un reporte

1. Cambiar la regla a Enforce:

   ```bash
   kubectl patch cpol require-team-label --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
   # <=1.12: kubectl patch cpol require-team-label --type=merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
   ```

2. Intentar crear un Pod nuevo que incumpla:

   ```bash
   kubectl -n reports-lab run blocked --image=nginx:1.27
   ```

   ```text
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/reports-lab/blocked was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label `team` is required.
       rule check-team-label failed at path /metadata/labels/team/'
   ```

3. Contar los reportes otra vez y comprobar si el Pod rechazado produjo alguno:

   ```bash
   kubectl -n reports-lab get polr
   kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.scope.name}{"\n"}{end}' | grep blocked
   ```

4. Ahora crear un Pod que cumpla y observar un resultado `pass`:

   ```bash
   kubectl -n reports-lab run allowed --image=nginx:1.27 --labels=team=platform
   sleep 15
   kubectl -n reports-lab get polr -o custom-columns=\
   SCOPE:.scope.name,PASS:.summary.pass,FAIL:.summary.fail
   ```

5. Devolver la regla a Audit para los ejercicios restantes:

   ```bash
   kubectl patch cpol require-team-label --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Audit"}]'
   ```

**Comprobación de comprensión**

- **Q4.1** — ¿Por qué no hay ninguna entrada de reporte para el Pod llamado `blocked`?
- **Q4.2** — Un equipo de plataforma dice: «ejecutamos todo en Enforce, así que nuestros reportes nunca tienen fallos — cumplimos». Dar las dos razones por las que esa conclusión no es sólida.
- **Q4.3** — Se está desplegando una política restrictiva nueva en un clúster en producción. Describir la secuencia de despliegue guiada por reportes y la consulta exacta que se ejecutaría para decidir que es seguro pasar a Enforce.

---

## Ejercicio 5 — Background scans: reportes de recursos que ya existen

1. Eliminar la política y recrear *primero* la carga de trabajo, para que los recursos sean anteriores a la política:

   ```bash
   kubectl delete cpol require-team-label
   kubectl -n reports-lab get polr
   kubectl -n reports-lab run legacy-a --image=nginx:1.27
   kubectl -n reports-lab run legacy-b --image=nginx:1.27
   ```

2. Acortar el intervalo del background scan para que el laboratorio no tarde una hora:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i background

   kubectl -n kyverno patch deploy kyverno-reports-controller --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--backgroundScanInterval=1m"}]'

   kubectl -n kyverno rollout status deploy/kyverno-reports-controller
   ```

3. Volver a aplicar la política y observar cómo aparecen los reportes sin que se admita nada:

   ```bash
   kubectl apply -f require-team-label.yaml
   kubectl -n reports-lab get polr -w
   ```

4. Ahora demostrar que una política con `background: false` no reporta nada sobre los recursos preexistentes:

   ```yaml
   # no-background.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: block-cluster-admin-creators
   spec:
     background: false
     rules:
       - name: check-creator
         match:
           any:
             - resources:
                 kinds: [Pod]
                 namespaces: [reports-lab]
         validate:
           failureAction: Audit
           message: "Pods must not be created by system:masters."
           deny:
             conditions:
               any:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyIn
                   value: ["system:masters"]
   ```

   ```bash
   kubectl apply -f no-background.yaml
   sleep 90
   kubectl -n reports-lab get polr -o jsonpath='{range .items[*]}{.scope.name}{": "}{range .results[*]}{.policy}{" "}{end}{"\n"}{end}'
   ```

**Comprobación de comprensión**

- **Q5.1** — En el paso 3 no se creó ni actualizó nada y, sin embargo, aparecieron fallos. ¿Qué controlador los produjo y mediante qué mecanismo?
- **Q5.2** — ¿Por qué `background: false` es obligatorio para la política del paso 4? ¿Qué no está disponible, estructuralmente, durante un background scan?
- **Q5.3** — Un clúster de producción tiene 40 000 Pods y el intervalo por defecto de 1 h. Describir el compromiso en ambas direcciones si se establece `--backgroundScanInterval=5m`.
- **Q5.4** — El `kubectl patch` del paso 2 funciona hoy. ¿Qué operación rutinaria lo revierte silenciosamente y dónde debería vivir esa opción en su lugar?

---

## Ejercicio 6 — Consultar reportes a escala de flota

1. Inventario de fallos en todo el clúster:

   ```bash
   kubectl get polr -A -o jsonpath=\
   '{range .items[*]}{range .results[?(@.result=="fail")]}{..policy}{"\t"}{end}{end}' 2>/dev/null

   kubectl get polr -A -o json | jq -r '
     .items[]
     | .metadata.namespace as $ns
     | .scope as $s
     | .results[]
     | select(.result=="fail")
     | [$ns, $s.kind, $s.name, .policy, .rule, .severity] | @tsv' | sort | column -t
   ```

   ```text
   reports-lab  Deployment  web       require-team-label  autogen-check-team-label  medium
   reports-lab  Pod         legacy-a  require-team-label  check-team-label          medium
   reports-lab  Pod         legacy-b  require-team-label  check-team-label          medium
   ```

2. Ordenar las políticas por número de recursos que fallan — el número que un equipo de plataforma reporta realmente hacia arriba:

   ```bash
   kubectl get polr -A -o json | jq -r '
     [.items[].results[] | select(.result=="fail") | .policy]
     | group_by(.) | map({policy: .[0], failures: length})
     | sort_by(-.failures) | .[] | "\(.failures)\t\(.policy)"'
   ```

3. El lado con alcance de clúster:

   ```bash
   kubectl get cpolr
   kubectl get cpolr -o custom-columns=NAME:.metadata.name,KIND:.scope.kind,FAIL:.summary.fail
   ```

4. Total de objetos que está almacenando la capa de reportes:

   ```bash
   kubectl get polr -A --no-headers | wc -l
   kubectl get cpolr --no-headers | wc -l
   ```

5. Opcional — instalar la capa de agregación/UI y ver los mismos datos como un dashboard:

   ```bash
   helm repo add policy-reporter https://kyverno.github.io/policy-reporter
   helm install policy-reporter policy-reporter/policy-reporter \
     -n policy-reporter --create-namespace --set ui.enabled=true --wait
   kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
   ```

**Comprobación de comprensión**

- **Q6.1** — ¿Por qué hay que leer `scope` (u `ownerReferences`) en lugar de `metadata.name` para responder «¿qué recursos están fallando?»?
- **Q6.2** — Un reporte por recurso significa que un clúster de 40 000 Pods puede contener más de 40 000 objetos de reporte. Nombrar dos consecuencias para el plano de control y una propiedad de diseño del modelo por recurso que mantiene pequeño cada objeto.
- **Q6.3** — El reporte de un `Pod` muestra `fail` para `check-team-label` y el reporte del `Deployment` muestra `fail` para `autogen-check-team-label`. Si se cuentan los resultados `fail` en bruto para producir un porcentaje de cumplimiento, ¿qué sale mal?
- **Q6.4** — ¿Qué aporta Policy Reporter que un `kubectl get polr` en crudo no puede dar?

---

## Ejercicio 7 — Ciclo de vida: los reportes son estado actual, no historial

1. Eliminar un Pod que incumple y observar cómo desaparece su reporte:

   ```bash
   kubectl -n reports-lab get polr --no-headers | wc -l
   kubectl -n reports-lab delete pod legacy-a
   sleep 5
   kubectl -n reports-lab get polr --no-headers | wc -l
   ```

2. Eliminar la política y observar cómo se retiran los resultados:

   ```bash
   kubectl delete cpol require-team-label
   sleep 20
   kubectl -n reports-lab get polr
   ```

3. Preguntarle al clúster qué queda del incumplimiento:

   ```bash
   kubectl -n reports-lab get events --field-selector reason=PolicyViolation
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20
   ```

4. Volver a aplicar la política para que los ejercicios posteriores tengan datos:

   ```bash
   kubectl apply -f require-team-label.yaml
   ```

**Comprobación de comprensión**

- **Q7.1** — ¿Quién eliminó el reporte en el paso 1: Kyverno o el plano de control de Kubernetes? Explicar el mecanismo con precisión.
- **Q7.2** — Después del paso 2, un recurso que incumplió la política durante tres días no deja rastro en la API de reportes. ¿Por qué, y qué habría que desplegar si se necesita poder responder «¿este namespace estuvo alguna vez fuera de cumplimiento en el Q3?»?
- **Q7.3** — Un auditor pide demostrar el cumplimiento en una fecha pasada usando `kubectl get polr`. ¿Cuál es la respuesta?

---

## Ejercicio 8 — Reportes sin clúster: la CLI de Kyverno en CI

1. Instalar la CLI (o usar la imagen de contenedor) y comprobar la versión:

   ```bash
   kyverno version
   ```

2. Escribir un archivo de recurso contra el cual probar:

   ```yaml
   # candidate.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: candidate
     namespace: reports-lab
   spec:
     containers:
       - name: app
         image: nginx:1.27
   ```

3. Producir un reporte sin conexión:

   ```bash
   kyverno apply require-team-label.yaml --resource candidate.yaml --policy-report
   echo "exit=$?"
   ```

   ```text
   Applying 1 policy rule(s) to 1 resource(s)...

   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: merged
   results:
   - message: 'validation error: The label `team` is required. rule check-team-label
       failed at path /metadata/labels/team/'
     policy: require-team-label
     resources:
     - apiVersion: v1
       kind: Pod
       name: candidate
       namespace: reports-lab
     result: fail
     rule: check-team-label
     scored: true
     source: kyverno
   summary:
     error: 0
     fail: 1
     pass: 0
     skip: 0
     warn: 0
   exit=1
   ```

4. Inspeccionar los controles de código de salida que se conectarían a un pipeline:

   ```bash
   kyverno apply --help | grep -iE 'exit|warn|report|cluster'
   ```

5. Contrastar con la ruta dentro del clúster:

   ```bash
   kubectl -n reports-lab get polr -o name | head -1
   ```

**Comprobación de comprensión**

- **Q8.1** — La CLI emitió un `ClusterPolicyReport` para un `Pod` con namespace, con el recurso dentro de `results[].resources` en lugar de un `scope` de nivel superior. ¿Por qué la forma sin conexión difiere de la forma dentro del clúster?
- **Q8.2** — No se escribió nada en el clúster. ¿Qué dos propiedades de CI hace eso posibles?
- **Q8.3** — CI está en verde y el reporte dentro del clúster muestra fallos para el mismo manifiesto. Dar tres razones por las que esto puede ocurrir legítimamente.

---

## Ejercicio 9 — Diagnosticar «el reporte que esperaba no está»

1. Crear un Pod que incumple en un namespace excluido y observar que no pasa nada:

   ```bash
   kubectl -n kube-system run sneaky --image=nginx:1.27
   sleep 90
   kubectl -n kube-system get polr
   ```

   ```text
   No resources found in kube-system namespace.
   ```

2. Averiguar por qué:

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head
   ```

   ```text
   [Event,*,*]
   [*,kube-system,*]
   [*,kube-public,*]
   [*,kube-node-lease,*]
   [*,kyverno,*]
   ...
   ```

3. Recorrer el resto de la lista de comprobación sobre un namespace que *sí* debería reportarse:

   ```bash
   # a. Is the reports controller alive and not being OOM-killed?
   kubectl -n kyverno get pods -l app.kubernetes.io/component=reports-controller
   kubectl -n kyverno describe pod -l app.kubernetes.io/component=reports-controller | grep -iE 'restart|oom|last state' 

   # b. Is reporting enabled for this rule type at all?
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'enableReporting|backgroundScan'

   # c. Is the policy background-eligible and Ready?
   kubectl get cpol -o custom-columns=NAME:.metadata.name,BACKGROUND:.spec.background,READY:.status.conditions[0].status

   # d. Is intermediate state being produced but never aggregated?
   kubectl get ephr -A
   kubectl get cephr

   # e. What does the controller itself say?
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50
   ```

4. Confirmar que la exclusión es la causa probando el mismo Pod en un namespace no excluido:

   ```bash
   kubectl -n reports-lab run sneaky --image=nginx:1.27
   sleep 20
   kubectl -n reports-lab get polr -o custom-columns=SCOPE:.scope.name,FAIL:.summary.fail | grep sneaky
   ```

**Comprobación de comprensión**

- **Q9.1** — ¿Por qué `resourceFilters` provoca un punto ciego *silencioso* en lugar de un error, y por qué es el valor por defecto más peligroso para alguien que trata «0 fallos» como «cumple»?
- **Q9.2** — `kubectl get ephr -A` muestra decenas de objetos `EphemeralReport` pero `kubectl get polr -A` está vacío. ¿Cuál es el diagnóstico y qué componente hay que inspeccionar?
- **Q9.3** — Ordenar esta lista de comprobación de lo más barato a lo más caro de verificar cuando falta un reporte: la opción `background` de la política, `resourceFilters`, la salud del reports controller, el bloque `match` de la regla, las opciones `--enableReporting`.
- **Q9.4** — Se crea una `PolicyException` que coincide con un Pod que incumple. ¿Qué valor de resultado aparece en el reporte y por qué es mejor que el resultado simplemente desaparezca?

---

## Limpieza

```bash
kubectl delete ns reports-lab
kubectl -n kube-system delete pod sneaky --ignore-not-found
kubectl delete cpol require-team-label block-cluster-admin-creators --ignore-not-found
helm uninstall policy-reporter -n policy-reporter 2>/dev/null; kubectl delete ns policy-reporter --ignore-not-found
kind delete cluster --name kca-reports
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** — Un `ClusterRole` que incumple (un recurso con alcance de clúster) se reporta en un `ClusterPolicyReport`; un `Pod` que incumple (con namespace) se reporta en un `PolicyReport` dentro del namespace de ese Pod. El alcance del reporte sigue al alcance del *sujeto*, no al de la política — una `ClusterPolicy` que coincide con Pods sigue produciendo objetos `PolicyReport` dentro del namespace.

**A1.2** — `EphemeralReport` / `ClusterEphemeralReport` (`reports.kyverno.io`) son los objetos *intermedios internos* de Kyverno. El admission controller y el background controller escriben allí los resultados en bruto de cada evaluación; el reports controller los consume, los agrega por recurso, escribe el `PolicyReport` y elimina el objeto efímero. Son de vida corta, inestables en su forma y específicos de cada versión — un detalle de implementación. El tooling y las alertas pertenecen a `PolicyReport`/`ClusterPolicyReport`, que es el contrato estable y común entre proveedores. El único uso legítimo es la resolución de problemas (Ejercicio 9).

**A1.3** — `kyverno-reports-controller` escribe `PolicyReport`/`ClusterPolicyReport`. `kyverno-admission-controller` sirve los webhooks y es el único que puede bloquear una petición. Los otros dos: `kyverno-background-controller` se encarga del background scan más las reglas generate/mutate-existing, y `kyverno-cleanup-controller` se encarga del borrado por TTL de `CleanupPolicy`. Separarlos (1.10+) significa que la carga de generación de reportes no puede dejar sin recursos la ruta de admission.

### Ejercicio 2

**A2.1** — La **autogeneración (autogen)** de Kyverno: una regla que coincide con `Pod` se expande automáticamente en reglas equivalentes dirigidas a los controladores de pods, aplicadas al `spec.template` del controlador. La regla generada se nombra con el prefijo `autogen-` — aquí `autogen-check-team-label` — y para los CronJobs `autogen-cronjob-check-team-label`. Por eso una única regla escrita produce resultados tanto en el objeto de carga de trabajo como en el Pod.

**A2.2** — `ReplicaSet` no está en el conjunto de controladores de autogen por defecto de Kyverno (`Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob`). Reportar sobre él triplicaría el conteo del mismo incumplimiento, ya que el template del ReplicaSet es una copia del del Deployment. El conjunto es configurable por política mediante la anotación `pod-policies.kyverno.io/autogen-controllers`.

**A2.3** — En Kyverno 1.10+ el `metadata.name` del reporte agregado es el **UID del recurso reportado**, y `scope` / `ownerReferences` apuntan de vuelta a él. Consecuencia: no se puede construir el nombre del reporte a partir del *nombre* de un recurso — primero hay que leer el UID del recurso (`kubectl get pod X -o jsonpath='{.metadata.uid}'`) o consultar por `scope`. Cualquier script que haga `kubectl get polr <pod-name>` está roto por diseño.

**A2.4** — El modelo por namespace concentraba todos los resultados de un namespace en un solo objeto. En un namespace grande, ese objeto crece hacia el límite de etcd de ~1.5 MiB por objeto y se convierte en un punto caliente de escritura: cada evento de admission en el namespace reescribe el mismo objeto, provocando conflictos, reintentos y rotación de objetos grandes. Un reporte por recurso mantiene cada objeto pequeño, hace las escrituras independientes y permite que Kubernetes los recolecte individualmente.

### Ejercicio 3

**A3.1** —
- `category` ← la anotación `policies.kyverno.io/category` de la política.
- `severity` ← la anotación `policies.kyverno.io/severity` de la política.
- `policy` ← el nombre del objeto `ClusterPolicy`/`Policy`.
- `rule` ← el `spec.rules[].name` que produjo el veredicto (con el prefijo `autogen-` cuando es generada).
- `scope` ← la identidad del recurso evaluado (apiVersion, kind, name, namespace, uid).
- `source` ← el motor que lo produjo, `kyverno`. El campo existe porque el CRD es neutral respecto del proveedor: Falco, Trivy, kube-bench y otros escriben en los mismos kinds, y `source` es como se los distingue en una sola consulta.

**A3.2** —
- `pass` — la regla se evaluó y el recurso la satisfizo.
- `fail` — se evaluó y el recurso la incumplió. En Audit esto se registra; en Enforce esto es lo que bloquea la admission.
- `warn` — un incumplimiento que deliberadamente no se computa contra el cumplimiento, producido por una política sin puntuar (`policies.kyverno.io/scored: "false"`).
- `error` — la regla no pudo evaluarse: sustitución de variables incorrecta, una llamada a la API inalcanzable en `context`, un JMESPath malformado. **Esto es culpa de la política, no del recurso**, y es el valor que más gente olvida alertar — un `error` significa que el control silenciosamente no se está ejecutando.
- `skip` — la regla no aplicaba a este recurso: las precondiciones fueron falsas, o una `PolicyException` coincidente lo eximió.

**A3.3** — Reclasificó el `fail` en un `warn`, moviendo el conteo de `summary.fail` a `summary.warn`. Conviene publicar una política sin puntuar cuando codifica un consejo y no un requisito — una recomendación nueva durante un período de rodaje, o una buena práctica que se quiere visible en los dashboards sin que degrade una puntuación de cumplimiento ni dispare una alerta de `summary.fail > 0`.

**A3.4** — (1) **Garbage collection**: cuando el Pod se elimina, Kubernetes borra en cascada el reporte automáticamente — Kyverno no tiene que reconciliar los borrados. (2) **Trazabilidad/adopción**: la owner reference da un enlace inequívoco y libre de colisiones de nombres hacia la instancia exacta del objeto (por UID), de modo que un reporte nunca puede atribuirse erróneamente a un recurso recreado que simplemente reutiliza el nombre.

**A3.5** — Porque hace posibles consultas baratas. `summary` se expone a través de `additionalPrinterColumns`, así que `kubectl get polr -A` muestra los conteos de pass/fail sin que el API server o el cliente tengan que analizar cada resultado. Agregadores, alertas y dashboards pueden observar los contadores sin deserializar todo el array `results` — lo que, en una flota grande, es la diferencia entre una consulta usable y una inusable.

### Ejercicio 4

**A4.1** — Enforce rechaza la petición en admission, así que el Pod **nunca existe** en etcd. Los policy reports describen recursos que existen: no hay UID con el que nombrar el reporte, ni objeto que lo posea, ni scope al que apuntar. Una petición bloqueada deja un error del admission webhook al cliente, una entrada en el log de Kyverno y (opcionalmente) un Event — no un reporte.

**A4.2** — (1) Enforce solo protege los recursos *nuevos y actualizados* de ahí en adelante; los recursos admitidos antes de que existiera la política siguen incumpliendo y solo un background scan los saca a la luz — y aparecerán como `fail`, no como nada. (2) La ausencia de `fail` puede significar que la regla nunca se ejecutó: un resultado `error`, un namespace excluido vía `resourceFilters`, un failurePolicy del webhook puesto en Ignore durante una caída, o una `PolicyException` produciendo `skip`. «Sin fallos» y «el control funciona» son afirmaciones distintas; solo revisar los conteos de `error`/`skip` y la cobertura permite distinguirlas.

**A4.3** — Desplegar en Audit con `background: true`. Dejar que el background scan complete y luego consultar el radio de impacto real:

```bash
kubectl get polr -A -o json | jq -r '
  .items[] | .metadata.namespace as $ns | .scope as $s | .results[]
  | select(.policy=="require-team-label" and .result=="fail")
  | [$ns,$s.kind,$s.name] | @tsv'
```

Llevar esa lista a cero (remediar, o conceder `PolicyException`s explícitas), confirmar que el conteo de `error` también es cero — una regla con error no está aprobando, no se está ejecutando — y entonces cambiar `failureAction` a `Enforce`.

### Ejercicio 5

**A5.1** — `kyverno-reports-controller`, mediante el **background scan**: periódicamente lista los recursos existentes que coinciden con cada política con `background: true`, los reevalúa a través del mismo motor de políticas usado en admission y escribe los resultados. No interviene ninguna petición de admission, que es exactamente por lo que puede reportar sobre recursos anteriores a la política.

**A5.2** — La regla referencia `request.userInfo.groups`. `userInfo` (y todo lo demás del `AdmissionRequest`: el usuario que solicita, los grupos, la operación, la marca de dry-run, el objeto antiguo) existe **solo durante una admission review**. Un background scan tiene un objeto almacenado y nada más — no hay solicitante al que atribuirlo. Por eso Kyverno se niega a marcar tales políticas como aptas para background; hay que poner `background: false`, y el precio es que los recursos preexistentes nunca son escaneados por esa regla.

**A5.3** — Intervalo más corto: los incumplimientos introducidos por fuera del canal habitual (un recurso mutado por un controlador, una política recién cambiada, un namespace cuyo webhook fue esquivado) salen a la luz en 5 minutos en lugar de hasta una hora — mejor MTTD. Costo: cada ciclo hace un LIST de los recursos coincidentes en todo el clúster y los reevalúa, así que con 40 000 Pods se multiplica por 12 la carga de listado sobre el API server, la CPU/memoria del reports controller y la rotación de escrituras de objetos de reporte. En un clúster grande la respuesta práctica es mantener un intervalo largo, escalar `--backgroundScanWorkers` y confiar en los resultados de tiempo de admission para la inmediatez.

**A5.4** — `helm upgrade` (y cualquier reconciliación GitOps de la release de Kyverno) reescribe el Deployment y descarta el argumento añadido. La opción pertenece a los valores de Helm del reports controller — el mecanismo de extra-args del chart para ese componente — de modo que quede versionada junto con el resto de la instalación. Confirmar el nombre del valor para su chart con `helm show values kyverno/kyverno | grep -A15 reportsController`.

### Ejercicio 6

**A6.1** — `metadata.name` es el UID del recurso, que no significa nada para una persona y es inestable entre recreaciones. `scope` (`kind`, `name`, `namespace`, `apiVersion`, `uid`) es la identidad del sujeto, usable tanto por personas como por máquinas. `ownerReferences` lleva el mismo enlace. Toda consulta de reportes que valga la pena escribir hace el join sobre `scope`.

**A6.2** — Consecuencias: (1) el conteo de objetos en etcd y el tráfico total de watch/list del apiserver crecen con el tamaño del clúster — los informers de los reportes se vuelven un costo de memoria real en el reports controller y en cualquier agregador que los observe; (2) `kubectl get polr -A` devuelve decenas de miles de elementos, así que las consultas ad hoc deben filtrarse del lado del servidor o agregarse en lugar de canalizarse por `jq` en un portátil. La propiedad que salva: cada reporte cubre exactamente un recurso, así que su array `results` está acotado por el número de reglas coincidentes — los objetos se mantienen muy por debajo del límite de tamaño por objeto de etcd y las escrituras de recursos distintos nunca compiten entre sí.

**A6.3** — Se cuenta dos veces el mismo incumplimiento. El resultado `autogen-` del Deployment y el resultado del Pod describen un único defecto subyacente — una label faltante en un único pod template. Un conteo ingenuo de `fail` se infla según el número de kinds de controlador expandidos por autogen involucrados, y el factor de inflación varía por tipo de carga de trabajo (un CronJob añade otra capa). Los porcentajes de cumplimiento deben computarse sobre *scopes distintos* — y normalmente sobre un nivel elegido (objetos de carga de trabajo, o Pods, no ambos).

**A6.4** — Agregación, historial y entrega: observa los CRDs de reportes en todo el clúster, mantiene un almacén consultable con tendencias en el tiempo (que los CRDs por sí mismos no pueden expresar) y envía los resultados a destinos externos — Slack, Teams, Elasticsearch, Loki, S3, webhooks — además de métricas de Prometheus y una UI. En otras palabras, convierte el estado puntual del clúster en notificaciones e historial.

### Ejercicio 7

**A7.1** — El **garbage collector de Kubernetes**, no Kyverno. El reporte lleva una `ownerReference` al Pod; cuando el Pod se elimina, el GC elimina los dependientes cuyo dueño ya no existe. Kyverno nunca tiene que vigilar los borrados para limpiar los reportes — que es también por lo que la limpieza de reportes sigue funcionando incluso si el reports controller está caído.

**A7.2** — El reports controller de Kyverno reconcilia los reportes contra el conjunto actual de políticas: cuando la política desaparece, sus resultados se eliminan de cada reporte, y un reporte que queda sin resultados se borra. Los reportes son una **vista materializada del estado actual**, no un registro de eventos. Para responder preguntas históricas hay que enviar los resultados a algún lugar durable: Policy Reporter con un destino persistente (Elasticsearch, S3, un SIEM), o extraer/exportar los datos de forma programada. Los Events de Kubernetes no son un sustituto — expiran (TTL de 1 h por defecto).

**A7.3** — No se puede responder desde `kubectl get polr`. La API de reportes solo describe el *ahora*: lo que las políticas actuales dicen sobre los recursos que existen actualmente. La evidencia histórica de cumplimiento requiere un sistema de retención externo que ya estuviera recolectando en el momento en cuestión; la prueba retroactiva es imposible.

### Ejercicio 8

**A8.1** — Sin conexión no hay API server, así que nada tiene UID y nada está en un namespace en el sentido del clúster: la CLI no puede nombrar un reporte según un UID, ni poseerlo, ni colocarlo en un namespace. Por eso emite un único `ClusterPolicyReport` fusionado (llamado `merged` en las versiones recientes) que lista cada recurso evaluado dentro de `results[].resources` — la forma antigua, previa a 1.10, que es la única expresable sin un clúster. Las dos formas llevan la misma información; solo difiere el mecanismo de identidad.

**A8.2** — (1) **Shift-left**: los fallos de política se detectan en un pull request, antes del merge, sin ningún clúster al que conectarse y sin credenciales en CI. (2) **Determinismo y aislamiento**: la ejecución no tiene efectos secundarios sobre ningún entorno, así que puede ejecutarse en cada commit, en paralelo, para muchas ramas, y su código de salida puede condicionar el merge (revisar `kyverno apply --help` para las opciones de código de salida y advertencias).

**A8.3** — (1) **Autogen**: CI evaluó el manifiesto del Deployment; el clúster además evalúa el Pod generado, y las reglas de mutación o los valores por defecto pueden hacer que el Pod real difiera. (2) **Mutación y cadena de admission**: otras reglas mutate de Kyverno, inyectores de sidecars o webhooks de defaulting cambian el objeto entre el archivo en disco y el objeto en etcd. (3) **Diferencias de contexto**: las políticas que usan contexto del clúster (`apiCall`, búsquedas en ConfigMap, `namespaceSelector`, búsquedas en el registro de imágenes para `verifyImages`) se evalúan de forma distinta — o dan error — sin conexión frente a dentro del clúster. También, simple deriva: el clúster puede estar ejecutando un conjunto o versión de políticas distinto del que probó el CI del repositorio.

### Ejercicio 9

**A9.1** — `resourceFilters`, en el ConfigMap `kyverno`, es una lista de *exclusión* aplicada antes de la evaluación, y por defecto excluye `kube-system`, `kube-public`, `kube-node-lease` y el propio namespace de Kyverno (entre otros) para evitar un bloqueo mutuo del plano de control. Los recursos excluidos nunca se evalúan, así que no hay nada que reportar — ni error, ni advertencia, ni `skip`: el recurso es sencillamente invisible para el motor. Es peligroso precisamente porque el modo de fallo es indistinguible del éxito en todos los dashboards: «0 fallos» sobre un alcance que nunca se escaneó se lee exactamente igual que «0 fallos» sobre un alcance que sí se escaneó. Toda afirmación de cumplimiento debe declarar su cobertura, no solo sus conteos.

**A9.2** — Los productores (los controladores de admission y de background) están funcionando — la evaluación ocurre y se escriben resultados intermedios — pero la **etapa de agregación está rota**: `kyverno-reports-controller` está en crash-loop, muerto por OOM, limitado, sin RBAC para escribir `policyreports`, o atascado. Hay que inspeccionar ese Deployment: `kubectl -n kyverno describe pod -l app.kubernetes.io/component=reports-controller` para ver reinicios/OOM, y luego sus logs en busca de errores de RBAC o de conflicto. La acumulación de objetos `EphemeralReport` es en sí misma el síntoma, ya que un controlador sano los consume y los elimina.

**A9.3** — De lo más barato a lo más caro:
1. El bloque `match` de la regla — leer la política que ya se tiene, sin llamadas al clúster.
2. La opción `background` de la política y su estado Ready — un `kubectl get cpol`.
3. `resourceFilters` — un `kubectl get cm`.
4. Las opciones del reports controller (`--enableReporting`, `--backgroundScanInterval`) — un `kubectl get deploy`.
5. La salud del reports controller — describe + logs y posiblemente correlacionar el estado de `ephr` a lo largo del tiempo.
En la práctica, revisar `match` y `resourceFilters` primero resuelve la gran mayoría de los casos de «no hay reporte».

**A9.4** — El resultado pasa a ser **`skip`**, e incrementa `summary.skip`. Eso es sustancialmente mejor que la desaparición del resultado: una exención permanece *visible y auditable*. Se puede consultar qué recursos están exentos de qué regla, revisar si la excepción sigue justificada y alertar sobre el crecimiento de las excepciones — mientras que un resultado desvanecido es indistinguible de un control que dejó de ejecutarse silenciosamente. (Las excepciones deben habilitarse en el momento de la instalación; revisar `helm show values kyverno/kyverno | grep -i -A5 policyExceptions` para el nombre del valor y la restricción de namespace de su chart.)

</details>

---

## Fuentes

- KCA curriculum — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- Kyverno documentation — https://kyverno.io/docs/
- Kyverno policy reports documentation — https://kyverno.io/docs/policy-reports/
- Kyverno CLI (`kyverno apply`) — https://kyverno.io/docs/kyverno-cli/
- PolicyReport CRD specification (Kubernetes Policy WG) — https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
- OpenReports API (successor of the wg-policy report CRDs) — https://github.com/openreports
- Policy Reporter — https://github.com/kyverno/policy-reporter
- Kubernetes owner references and garbage collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/