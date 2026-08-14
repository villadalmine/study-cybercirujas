# KCA 5.3 — Background Scans: Ejercicios guiados

> **Alcance.** Estos ejercicios ejercitan la mecánica del subsistema de *background scanning* de Kyverno: qué controlador lo ejecuta, qué produce, qué se niega a evaluar, cómo se planifica y se acota, y de qué forma falla silenciosamente en producción. Cada paso es ejecutable contra un cluster descartable.
>
> **Versión de referencia.** Escrito contra **Kyverno 1.13.x (chart de Helm 3.3.x)** sobre Kubernetes 1.29+. Donde un campo o CRD cambió entre releases, el paso lo indica y te pide que *descubras* la versión servida en lugar de confiar en el texto. Verificá tu propio build antes de culpar a un comando:
>
> ```bash
> kubectl -n kyverno get deploy kyverno-reports-controller \
>   -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
> ```
>
> **Convención de salida.** Los bloques marcados con `# (abridged)` están recortados para facilitar la lectura; los nombres de los reports son UIDs de recursos y nunca van a coincidir literalmente con los tuyos. Nunca fijes un nombre de report en el código.

---

## Entorno de laboratorio

```bash
kind create cluster --name kca-53

helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version '>=3.3.0 <3.4.0' \
  --set features.backgroundScan.backgroundScanInterval=2m \
  --wait
```

Un intervalo de 2 minutos es un ajuste de laboratorio. El valor por defecto en producción es `1h`; el Ejercicio 7 explica por qué acortarlo no es gratis.

Si tu repositorio de charts no incluye la 3.3.x, quitá `--version` y registrá lo que se resuelva:

```bash
helm -n kyverno list
```

```
NAME     NAMESPACE  REVISION  STATUS    CHART           APP VERSION
kyverno  kyverno    1         deployed  kyverno-3.3.4   v1.13.2
```

---

## Ejercicio 1 — Mapear el plano de reporting antes de tocar una policy

El background scanning **no** lo realiza el webhook de admisión, y **no** lo realiza el controlador cuyo nombre contiene la palabra "background". Demostrátelo a vos mismo antes que nada.

1. Listá los deployments de Kyverno:

   ```bash
   kubectl -n kyverno get deploy
   ```

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           95s
   kyverno-background-controller   1/1     1            1           95s
   kyverno-cleanup-controller      1/1     1            1           95s
   kyverno-reports-controller      1/1     1            1           95s
   ```

2. Volcá los flags del reports controller:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | tr -d '[]"'
   ```

   ```
   --caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca
   --tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair
   --backgroundScan=true
   --admissionReports=true
   --aggregateReports=true
   --policyReports=true
   --backgroundScanWorkers=2
   --backgroundScanInterval=2m
   --skipResourceFilters=true
   --enableConfigMapCaching=true
   --loggingFormat=text
   --v=2
   ```

3. Hacé lo mismo con `kyverno-background-controller` y compará — notá que `--backgroundScanInterval` **no** aparece ahí.

4. Enumerá todas las APIs de reporting que sirve el cluster:

   ```bash
   kubectl api-resources --api-group=wgpolicyk8s.io
   kubectl api-resources --api-group=reports.kyverno.io
   ```

   ```
   NAME                   SHORTNAMES   APIVERSION                NAMESPACED   KIND
   clusterpolicyreports   cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
   policyreports          polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport

   NAME                      SHORTNAMES   APIVERSION              NAMESPACED   KIND
   clusterephemeralreports   cephr        reports.kyverno.io/v1   false        ClusterEphemeralReport
   ephemeralreports          ephr         reports.kyverno.io/v1   true         EphemeralReport
   ```

   > En Kyverno 1.12 y anteriores el segundo grupo no existe; en su lugar vas a encontrar `admissionreports`, `clusteradmissionreports`, `backgroundscanreports` y `clusterbackgroundscanreports` en el grupo `kyverno.io`. Ejecutá el comando, no lo asumas.

5. Confirmá que el grupo de CRDs de reporting no es una invención propia de Kyverno:

   ```bash
   kubectl get crd policyreports.wgpolicyk8s.io \
     -o jsonpath='{.spec.group}{"\n"}{.metadata.annotations}{"\n"}'
   ```

**Preguntas**

- **Q1.** ¿Qué deployment ejecuta el background scan periódico, y qué hace en realidad `kyverno-background-controller` en su lugar?
- **Q2.** `PolicyReport` vive en el grupo `wgpolicyk8s.io`, no en `kyverno.io`. ¿Cuál es la consecuencia práctica de eso para un equipo de plataforma que corre más de un motor de policies?
- **Q3.** Solo a partir del volcado de flags: si ponés `--backgroundScan=false`, ¿deja de funcionar la validación en tiempo de admisión?

---

## Ejercicio 2 — Producir tu primer background scan y diseccionar un report

El sentido del background scanning son los recursos que ya existían cuando la policy no existía.

1. Creá primero cargas de trabajo **no conformes**:

   ```bash
   kubectl create ns billing
   kubectl -n billing run legacy-api --image=nginx:1.27
   kubectl -n billing create deployment legacy-web --image=nginx:1.27
   ```

2. Confirmá que la superficie de reporting está vacía — sin policies, sin reports:

   ```bash
   kubectl get polr,cpolr -A
   ```

   ```
   No resources found
   ```

3. Aplicá una policy de tipo **Audit**:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
     annotations:
       policies.kyverno.io/title: Require team label
       policies.kyverno.io/category: Governance
       policies.kyverno.io/severity: medium
   spec:
     background: true
     admission: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           failureAction: Audit
           message: "The label `team` is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"
   EOF
   ```

   > **Nota de versión.** `validate.failureAction` es el campo a nivel de regla de 1.13+. En 1.12 y anteriores usá `spec.validationFailureAction: Audit` a nivel de policy. Nunca definas ambos — entran en conflicto.

4. Observá cómo aparecen los reports. **No** esperes dos minutos:

   ```bash
   kubectl get polr -A
   ```

   ```
   # (abridged)
   NAMESPACE     NAME                                   KIND         NAME                          PASS  FAIL  WARN  ERROR  SKIP  AGE
   billing       0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11   Pod          legacy-api                    0     1     0     0      0     6s
   billing       6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   Deployment   legacy-web                    0     1     0     0      0     6s
   billing       b3c9a1d7-77aa-4b91-9e21-2f6d7c1a0b34   ReplicaSet   legacy-web-7c9f8b6d5c         0     1     0     0      0     6s
   billing       c81e2a90-1d44-4c0e-8b2a-5f7e9c0d3a12   Pod          legacy-web-7c9f8b6d5c-2xk9n   0     1     0     0      0     6s
   kube-system   1a2b3c4d-...                           Pod          coredns-76f75df574-abcde      0     1     0     0      0     6s
   ...
   ```

5. Leé un report completo:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.name=="legacy-api")' 
   ```

   ```yaml
   # (abridged, rendered as YAML for readability)
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: PolicyReport
   metadata:
     name: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
     namespace: billing
     labels:
       app.kubernetes.io/managed-by: kyverno
     ownerReferences:
       - apiVersion: v1
         kind: Pod
         name: legacy-api
         uid: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
   scope:
     apiVersion: v1
     kind: Pod
     name: legacy-api
     namespace: billing
     uid: 0f7c2f61-6c8a-4a55-9f0d-1b0f0d3a5c11
   results:
     - source: kyverno
       policy: require-team-label
       rule: check-team-label
       result: fail
       scored: true
       category: Governance
       severity: medium
       message: >-
         validation error: The label `team` is required on every Pod.
         rule check-team-label failed at path /metadata/labels/team/
       timestamp:
         seconds: 1770000000
         nanos: 0
   summary:
     pass: 0
     fail: 1
     warn: 0
     error: 0
     skip: 0
   ```

6. Compará los nombres de las reglas entre los distintos scopes:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name)\t\(.results[].rule)"' | sort
   ```

   ```
   Deployment/legacy-web              autogen-check-team-label
   Pod/legacy-api                     check-team-label
   Pod/legacy-web-7c9f8b6d5c-2xk9n    check-team-label
   ReplicaSet/legacy-web-7c9f8b6d5c   autogen-check-team-label
   ```

7. Borrá el Pod suelto y volvé a listar los reports:

   ```bash
   kubectl -n billing delete pod legacy-api
   kubectl -n billing get polr
   ```

**Preguntas**

- **Q4.** El intervalo de scan es de 2 minutos, y sin embargo los reports aparecieron a los segundos del `kubectl apply`. ¿Qué disparó la evaluación, y para qué sirve realmente el intervalo?
- **Q5.** El report de `legacy-api` desapareció en el momento en que se borró el Pod, y ningún controlador ejecutó una pasada de limpieza. ¿Qué campo único de los metadatos del report explica eso, y por qué es una decisión de diseño deliberada a escala de cluster?
- **Q6.** ¿Por qué el report del Deployment cita `autogen-check-team-label` mientras que el del Pod cita `check-team-label`? Vos escribiste una sola regla.
- **Q7.** `kube-system` figura en los `resourceFilters` por defecto de Kyverno, lo que lo excluye del procesamiento de admisión. ¿Por qué igualmente hay resultados `fail` para Pods de `kube-system`? (Nombrá el flag exacto.)
- **Q8.** El nombre del report es un UID, no una cadena legible por humanos. Escribí el comando `kubectl` que le darías a un SRE para responder "¿el Pod `X` del namespace `Y` viola algo?" sin conocer el nombre del report.

---

## Ejercicio 3 — Los dos interruptores: `background` y `admission`

1. Deshabilitá el procesamiento en background en la policy existente y observá:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"background":false}}'
   sleep 5
   kubectl get polr -A
   ```

   ```
   No resources found
   ```

2. Demostrá que la aplicación en admisión sigue intacta — creá un Pod que viole la regla e inspeccioná su resultado de *admisión*:

   ```bash
   kubectl -n billing run probe-a --image=nginx:1.27
   kubectl -n billing get polr -o json | jq -r '.items[] | "\(.scope.name): \(.results[].rule)=\(.results[].result)"'
   ```

   ```
   probe-a: check-team-label=fail
   ```

3. Volvé a habilitar el procesamiento en background y confirmá que los recursos históricos reaparecen:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"background":true}}'
   sleep 10
   kubectl get polr -A | wc -l
   ```

4. Ahora accioná el otro interruptor — una policy **solo de scan**, sin huella en el webhook:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"admission":false}}'
   kubectl get validatingwebhookconfigurations | grep kyverno
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules}{"\n"}{end}'
   ```

5. Creá otro Pod que viole la regla y notá que es admitido sin evaluación del webhook, pero igual aparece en los reports después de la reconciliación:

   ```bash
   kubectl -n billing run probe-b --image=nginx:1.27
   sleep 10
   kubectl -n billing get polr -o json | jq -r '.items[] | select(.scope.name=="probe-b") | .results[].result'
   ```

6. Restaurá la policy:

   ```bash
   kubectl patch cpol require-team-label --type merge -p '{"spec":{"admission":true}}'
   ```

**Preguntas**

- **Q9.** Enunciá con precisión qué hace y qué no hace `spec.background: false`.
- **Q10.** `admission: false, background: true` es la configuración que usa un equipo de plataforma al incorporar una policy a un cluster en producción. ¿Por qué es más seguro que desplegar la misma regla con `failureAction: Audit` y `admission: true`?
- **Q11.** Con `admission: false`, la regla de Pod desapareció del ValidatingWebhookConfiguration. ¿Qué propiedad operativa de Kyverno demuestra eso, y por qué importa para la latencia del API server?
- **Q12.** Un recurso creado mientras el admission controller estaba caído (webhook con `failurePolicy: Ignore`) se cuela en el cluster sin cumplir la policy. ¿Qué mecanismo lo termina exponiendo, y cuál es la demora en el peor caso?

---

## Ejercicio 4 — Reglas que *no pueden* evaluarse en background

El background scanning no tiene `AdmissionReview`. No hay usuario, ni operación, ni service account. Kyverno rechaza ese tipo de policy en el momento de crearla, en lugar de sub-reportar en silencio.

1. Intentá crear una policy que dependa de la identidad del solicitante dejando el procesamiento en background activado:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-configmap-authors
   spec:
     background: true
     rules:
       - name: deny-non-platform-authors
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         validate:
           failureAction: Enforce
           message: "{{ request.userInfo.username }} is not allowed to create ConfigMaps here."
           deny:
             conditions:
               all:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyNotIn
                   value:
                     - "platform-admins"
   EOF
   ```

   ```
   # (abridged; exact wording varies by release)
   Error from server: error when creating "STDIN": admission webhook "validate-policy.kyverno.svc"
   denied the request: spec.rules[0]: variable {{ request.userInfo.groups }} is not allowed in
   background mode. Set spec.background=false to disable background mode for this policy rule.
   ```

2. Aplicá la corrección documentada y confirmá que se acepta:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-configmap-authors
   spec:
     background: false
     rules:
       - name: deny-non-platform-authors
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         validate:
           failureAction: Enforce
           message: "{{ request.userInfo.username }} is not allowed to create ConfigMaps here."
           deny:
             conditions:
               all:
                 - key: "{{ request.userInfo.groups }}"
                   operator: AnyNotIn
                   value:
                     - "platform-admins"
   EOF
   ```

3. Verificá que esta policy nunca creó ningún scope de report para ConfigMaps:

   ```bash
   kubectl get polr -A -o json | jq -r '[.items[].results[] | select(.policy=="restrict-configmap-authors")] | length'
   ```

   ```
   0
   ```

4. Ahora confirmá el caso *opuesto* — `request.object` **sí** está disponible en modo background. Reescribí la misma intención usando únicamente el contenido del recurso y observá que Kyverno acepta `background: true`:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-owner-annotation
   spec:
     background: true
     rules:
       - name: check-owner
         match:
           any:
             - resources:
                 kinds:
                   - ConfigMap
         preconditions:
           all:
             - key: "{{ request.object.metadata.namespace }}"
               operator: Equals
               value: billing
         validate:
           failureAction: Audit
           message: "ConfigMaps in billing must carry annotation owner."
           pattern:
             metadata:
               annotations:
                 owner: "?*"
   EOF

   kubectl -n billing create configmap rates --from-literal=eur=1.0
   sleep 10
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.kind=="ConfigMap") | "\(.scope.name): \(.results[].policy)=\(.results[].result)"'
   ```

**Preguntas**

- **Q13.** Enumerá las familias de variables que vuelven a una regla inelegible para el background scanning, y explicá la razón de una línea que todas comparten.
- **Q14.** Kyverno rechaza la policy en el momento del `kubectl apply` en vez de aceptarla y saltearla durante los scans. Argumentá por qué esa es la decisión de ingeniería correcta para un motor de policies.
- **Q15.** Un equipo de seguridad exige que *cada* ConfigMap del cluster sea auditado en busca de una anotación `owner`, y *además* que solo los `platform-admins` puedan crearlos. ¿Cuántas ClusterPolicies hacen falta, y por qué?
- **Q16.** Tu policy necesita `request.operation`. ¿Es usable en modo background? ¿Qué tiene que asumir el scan sobre un objeto que ya existe?

---

## Ejercicio 5 — Enforce, Audit y `skip` en los reports

Un error conceptual habitual es creer que las policies `Enforce` no producen nada en los reports. Refutalo.

1. Cambiá la policy de labels a `Enforce` dejando el background activado:

   ```bash
   kubectl patch cpol require-team-label --type json \
     -p '[{"op":"replace","path":"/spec/rules/0/validate/failureAction","value":"Enforce"}]'
   ```

   *(En 1.12 y anteriores: `kubectl patch cpol require-team-label --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'`.)*

2. Confirmá que los nuevos Pods que violan la regla ahora quedan bloqueados:

   ```bash
   kubectl -n billing run probe-c --image=nginx:1.27
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   policy Pod/billing/probe-c for resource violation:

   require-team-label:
     check-team-label: 'validation error: The label `team` is required on every Pod. ...'
   ```

3. Ahora fijate qué pasó con los infractores *preexistentes*:

   ```bash
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name): \(.results[].result)"' | sort | uniq -c
   ```

4. Otorgá una excepción y observá cómo la clase de resultado cambia de `fail` a `skip`. Primero asegurate de que las excepciones estén habilitadas:

   ```bash
   helm show values kyverno/kyverno | grep -A6 'policyExceptions'
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.policyExceptions.enabled=true --wait
   kubectl api-resources | grep -i policyexception
   ```

   ```
   policyexceptions   polex   kyverno.io/v2   true   PolicyException
   ```

5. Aplicá la excepción (usá la versión de API que haya reportado tu cluster):

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v2
   kind: PolicyException
   metadata:
     name: legacy-web-exemption
     namespace: billing
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
           - autogen-check-team-label
     match:
       any:
         - resources:
             namespaces:
               - billing
             names:
               - "legacy-web*"
   EOF

   sleep 10
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | "\(.scope.kind)/\(.scope.name): \(.results[].result)"' | sort
   ```

**Preguntas**

- **Q17.** Una policy `Enforce` bloquea las violaciones *nuevas*. ¿Qué hace con los 400 Deployments no conformes que ya existen, y cuál es el único artefacto que los evidencia?
- **Q18.** ¿Por qué la excepción tuvo que nombrar `autogen-check-team-label` además de `check-team-label`?
- **Q19.** En el resumen del PolicyReport, ¿cuál es la diferencia semántica entre `skip`, `warn` y `error`? ¿Cuál de los tres indica una policy rota en lugar de un recurso no conforme?
- **Q20.** Un dashboard de cumplimiento cuenta los resultados `fail` para calcular un puntaje. ¿Qué le hace a ese número un `skip` que pasa inadvertido, y cómo detectarías el abuso de excepciones?

---

## Ejercicio 6 — Reports intermedios y agregación

`PolicyReport` es la *salida*. Se ensambla a partir de objetos intermedios de vida corta; entenderlos es lo que te permite depurar un scan que "no produce nada".

1. Observá la capa efímera en una terminal:

   ```bash
   kubectl get ephr -A -w
   ```

   *(Kyverno ≤1.12: `kubectl get backgroundscanreports,admissionreports -A -w`.)*

2. En una segunda terminal, forzá una reevaluación completa tocando la policy:

   ```bash
   kubectl annotate cpol require-team-label kca.local/rescan="$(date +%s)" --overwrite
   ```

3. Observá cómo se crean objetos y se consumen en segundos:

   ```
   # (abridged)
   NAMESPACE   NAME                                   AGE
   billing     6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   0s
   billing     c81e2a90-1d44-4c0e-8b2a-5f7e9c0d3a12   0s
   billing     6a1b0f2e-0d2e-4a11-b7e2-9a1d2c3e4f55   2s   # deleted after aggregation
   ```

4. Inspeccioná uno antes de que desaparezca, y observá las labels que llevan el hash de la policy:

   ```bash
   kubectl -n billing get ephr -o json \
     | jq -r '.items[0].metadata.labels' 
   ```

5. Revisá el interruptor de agregación y el flag de fragmentación:

   ```bash
   kubectl -n kyverno get deploy kyverno-reports-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'aggregate|chunk|reports'
   ```

**Preguntas**

- **Q21.** Describí el flujo de datos desde "cambió una policy" hasta "se actualizó el PolicyReport", nombrando cada objeto intermedio.
- **Q22.** Los reports intermedios llevan en sus labels un hash del conjunto de policies. ¿Qué optimización habilita eso, y qué pasa con esa optimización cuando editás una policy cada pocos minutos en un loop de CI?
- **Q23.** Si ves `ephemeralreports` acumulándose en un namespace y nunca siendo eliminados, ¿qué controlador investigás, y cuáles son las dos causas más probables?

---

## Ejercicio 7 — Lo que cuesta el scan: intervalo, workers y resource filters

1. Leé la lista de exclusiones actual que usa la admisión:

   ```bash
   kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}' | tr ']' ']\n' | head -20
   ```

   ```
   # (abridged)
   [Event,*,*]
   [*/*,kube-system,*]
   [*/*,kube-public,*]
   [*/*,kube-node-lease,*]
   [Node,*,*]
   [APIService,*,*]
   [TokenReview,*,*]
   ...
   ```

2. Confirmá la contradicción que observaste en el Ejercicio 2 — `kube-system` está filtrado y sin embargo se reporta:

   ```bash
   kubectl -n kube-system get polr --no-headers | wc -l
   ```

3. Hacé que el background scan respete los filtros. Descubrí primero el nombre del valor, después seteálo:

   ```bash
   helm show values kyverno/kyverno | grep -A8 'backgroundScan:'
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.backgroundScan.skipResourceFilters=false --wait
   ```

   Sin Helm, parcheá el flag directamente (gana la última aparición, y el cambio se revierte con el próximo `helm upgrade`):

   ```bash
   kubectl -n kyverno patch deploy kyverno-reports-controller --type json \
     -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skipResourceFilters=false"}]'
   ```

4. Volvé a chequear después del rollout:

   ```bash
   kubectl -n kyverno rollout status deploy/kyverno-reports-controller
   sleep 20
   kubectl -n kube-system get polr --no-headers | wc -l
   kubectl -n billing get polr --no-headers | wc -l
   ```

5. Excluí un namespace propio y mirá cómo se vacían sus reports:

   ```bash
   FILTERS=$(kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}')
   kubectl -n kyverno patch cm kyverno --type merge \
     -p "{\"data\":{\"resourceFilters\":\"${FILTERS}[Pod,billing,*]\"}}"
   sleep 30
   kubectl -n billing get polr -o json | jq -r '[.items[] | select(.scope.kind=="Pod")] | length'
   ```

6. Dimensioná la carga de trabajo. Contá lo que un scan completo tiene que evaluar en este cluster:

   ```bash
   kubectl get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A --no-headers | wc -l
   ```

7. Restaurá los valores por defecto antes de continuar:

   ```bash
   kubectl -n kyverno patch cm kyverno --type merge -p "{\"data\":{\"resourceFilters\":\"${FILTERS}\"}}"
   helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
     --set features.backgroundScan.skipResourceFilters=true --wait
   ```

**Preguntas**

- **Q24.** Explicá `--skipResourceFilters=true` en una oración, y por qué el valor por defecto es `true` aun cuando produce resultados para namespaces que el admission controller ignora.
- **Q25.** Un cluster tiene 60.000 Pods alcanzados por 40 policies. Ponés `--backgroundScanInterval=1m` para "tener dashboards más frescos". Enumerá las tres presiones de recursos que eso genera y dónde va a aparecer la primera falla.
- **Q26.** `--backgroundScanWorkers` vale `2` por defecto. Subirlo acorta un ciclo de scan — ¿cuál es la restricción que te impide subirlo a 64?
- **Q27.** Editar el ConfigMap `kyverno` cambió el comportamiento sin reiniciar el pod. ¿Qué flag del volcado del Ejercicio 1 te dice que el ConfigMap se observa en lugar de leerse una sola vez, y cuál sería el riesgo si no fuera así?
- **Q28.** Tu organización no debe tener ningún objeto de reporting para un namespace regulado, ni siquiera un resultado `pass`. ¿Cuál de los dos mecanismos de este ejercicio lo logra, y cuál no?

---

## Ejercicio 8 — La falla silenciosa: RBAC y custom resources

Kyverno 1.10+ trae RBAC de mínimo privilegio. No puede escanear un CRD al que nunca se le dio acceso, y el scan no falla ruidosamente.

1. Creá un CRD y dos instancias, una conforme y otra no:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: widgets.example.io
   spec:
     group: example.io
     scope: Namespaced
     names:
       kind: Widget
       listKind: WidgetList
       plural: widgets
       singular: widget
     versions:
       - name: v1
         served: true
         storage: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   size:
                     type: string
   EOF

   kubectl -n billing apply -f - <<'EOF'
   apiVersion: example.io/v1
   kind: Widget
   metadata:
     name: good-widget
   spec:
     size: large
   ---
   apiVersion: example.io/v1
   kind: Widget
   metadata:
     name: bad-widget
   spec: {}
   EOF
   ```

2. Aplicá una policy que los alcance:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-widget-size
   spec:
     background: true
     rules:
       - name: check-size
         match:
           any:
             - resources:
                 kinds:
                   - example.io/v1/Widget
         validate:
           failureAction: Audit
           message: "Widgets must declare spec.size."
           pattern:
             spec:
               size: "?*"
   EOF
   ```

3. Esperá más de un intervalo y buscá resultados — no hay ninguno:

   ```bash
   sleep 130
   kubectl get polr -A -o json | jq -r '[.items[].results[] | select(.policy=="require-widget-size")] | length'
   ```

   ```
   0
   ```

4. Diagnosticá a partir de los logs del controlador y preguntándole directamente al API server:

   ```bash
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=50 | grep -i -E 'widget|forbidden|permission'
   kubectl auth can-i list widgets.example.io \
     --as=system:serviceaccount:kyverno:kyverno-reports-controller
   ```

   ```
   no
   ```

5. Otorgá el acceso mediante la label de agregación — nunca editando los ClusterRoles propios de Kyverno:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:reports-controller:widgets
     labels:
       rbac.kyverno.io/aggregate-to-reports-controller: "true"
   rules:
     - apiGroups: ["example.io"]
       resources: ["widgets"]
       verbs: ["get", "list", "watch"]
   EOF

   kubectl auth can-i list widgets.example.io \
     --as=system:serviceaccount:kyverno:kyverno-reports-controller
   ```

6. Confirmá que ahora los resultados se materializan:

   ```bash
   kubectl annotate cpol require-widget-size kca.local/rescan="$(date +%s)" --overwrite
   sleep 20
   kubectl -n billing get polr -o json \
     | jq -r '.items[] | select(.scope.kind=="Widget") | "\(.scope.name): \(.results[].result)"'
   ```

   ```
   bad-widget: fail
   good-widget: pass
   ```

**Preguntas**

- **Q29.** ¿Por qué esta falla produjo *cero* resultados en lugar de un resultado `error` en un report? ¿Qué supuesto del reporting rompe eso para un auditor?
- **Q30.** Otorgaste el permiso con un ClusterRole nuevo que lleva `rbac.kyverno.io/aggregate-to-reports-controller: "true"` en vez de editar `kyverno:reports-controller`. Dá dos razones concretas.
- **Q31.** El mismo CRD también está alcanzado por una policy `Enforce` en admisión. ¿La falta de RBAC rompe también la validación en tiempo de admisión? Explicá la diferencia en cómo llega el objeto a Kyverno en cada camino.
- **Q32.** Escribí la verificación de una línea que pondrías en un pipeline de CI de plataforma para atrapar esta clase de bug para cada kind referenciado por cualquier ClusterPolicy.

---

## Ejercicio 9 — Observabilidad y una verificación cruzada offline

1. Recolectá las métricas del reports controller:

   ```bash
   kubectl -n kyverno port-forward deploy/kyverno-reports-controller 8000:8000 >/dev/null 2>&1 &
   sleep 2
   curl -s localhost:8000/metrics | grep -i 'kyverno_policy_results_total' | grep -i background | head
   ```

   ```
   # (abridged; label casing varies by release — grep case-insensitively)
   kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_type="cluster",policy_validation_mode="audit",resource_kind="Pod",resource_namespace="billing",rule_execution_cause="background_scan",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 3
   ```

2. Compará las dos causas de ejecución lado a lado:

   ```bash
   curl -s localhost:8000/metrics | grep -o 'rule_execution_cause="[^"]*"' | sort | uniq -c
   curl -s localhost:8000/metrics | grep -i 'kyverno_policy_execution_duration_seconds_sum' | head -3
   ```

3. Subí temporalmente la verbosidad de los logs y leé un ciclo de scan:

   ```bash
   kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=100 | grep -iE 'background|resync|scan'
   ```

4. Verificá de forma cruzada la respuesta del propio cluster con la CLI de Kyverno, que evalúa las mismas reglas fuera del cluster:

   ```bash
   kyverno version
   kubectl get cpol require-team-label -o yaml > /tmp/require-team-label.yaml
   kyverno apply /tmp/require-team-label.yaml --cluster --namespace billing --policy-report
   ```

   ```
   # (abridged)
   apiVersion: wgpolicyk8s.io/v1alpha2
   kind: ClusterPolicyReport
   metadata:
     name: clusterpolicyreport
   results:
     - policy: require-team-label
       rule: autogen-check-team-label
       result: fail
       resources:
         - apiVersion: apps/v1
           kind: Deployment
           name: legacy-web
           namespace: billing
   summary:
     pass: 0
     fail: 2
     skip: 0
     warn: 0
     error: 0
   ```

5. Matá el port-forward:

   ```bash
   kill %1
   ```

**Preguntas**

- **Q33.** ¿Qué label de métrica te permite construir un panel de dashboard que muestre *solo* la deriva encontrada por los scans, excluyendo todo lo atrapado en tiempo de admisión?
- **Q34.** `kyverno apply --cluster --policy-report` produjo un report parecido al del cluster. Nombrá dos cosas que no puede reproducir, y una situación en la que igualmente la CLI es la herramienta correcta.
- **Q35.** Alertás sobre el incremento de `kyverno_policy_results_total{rule_result="fail"}`. Un equipo borra 300 Pods no conformes, el contador se aplana y los PolicyReports se vacían. ¿Por qué un contador es la señal equivocada acá, y qué debería decir la alerta en su lugar?

---

## Limpieza

```bash
kubectl delete cpol require-team-label require-widget-size restrict-configmap-authors require-owner-annotation --ignore-not-found
kubectl -n billing delete polex legacy-web-exemption --ignore-not-found
kubectl delete crd widgets.example.io --ignore-not-found
kubectl delete clusterrole kyverno:reports-controller:widgets --ignore-not-found
kubectl delete ns billing --ignore-not-found
kubectl get polr,cpolr -A
kind delete cluster --name kca-53
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** `kyverno-reports-controller` realiza el background scanning: reevalúa de forma periódica y también dirigida por eventos los recursos existentes contra las policies, y escribe `PolicyReport`/`ClusterPolicyReport`. `kyverno-background-controller` no tiene relación con el escaneo — procesa reglas `generate` y reglas `mutate` que apuntan a recursos existentes (mutate-existing), es decir, *cambia* el estado del cluster de forma asincrónica. La colisión de nombres es la confusión más común de este dominio: los reports nunca mutan nada, y el background controller nunca escribe un policy report.

**Q2.** `wgpolicyk8s.io` es la API común de reporting del Policy WG de Kubernetes, no un tipo propietario de Kyverno. Cualquier consumidor — la UI de Policy Reporter, un pipeline de Grafana, un exporter de OPA/Gatekeeper, un job de cumplimiento — lee un solo esquema, y el campo `results[].source` (`kyverno`) distingue a los productores. Un dashboard escrito contra `PolicyReport` sigue funcionando si se agrega un segundo motor o si se reemplaza a Kyverno.

**Q3.** No. `--backgroundScan` solo gobierna el escaneo periódico de recursos existentes por parte del reports controller. La validación en tiempo de admisión la realiza `kyverno-admission-controller` a través del webhook y es totalmente independiente. Podés tener enforcement sin reporting, o reporting sin enforcement.

**Q4.** El reports controller observa policies y recursos mediante informers. Cualquier creación/actualización/borrado de policy, y cualquier cambio en un recurso alcanzado, dispara la reevaluación inmediata del scope afectado. `--backgroundScanInterval` es un *resync completo*: reevalúa todo incluso cuando nada cambió en etcd. Eso importa porque el veredicto de una regla puede depender de entradas externas al cluster — firmas y attestations de imágenes (`verifyImages`), `apiCall` y contexto de servicios externos, estado del registry — y porque es la red de seguridad para los eventos perdidos mientras el controlador estaba caído o sobrecargado.

**Q5.** `metadata.ownerReferences` apunta al recurso escaneado con su UID. El report lo recolecta como basura el propio Kubernetes cuando se borra el owner — no corre código de Kyverno, ningún loop de reconciliación tiene fugas. A escala de cluster, esto es lo que mantiene la cantidad de reports acotada por la cantidad de recursos en lugar de crecer monótonamente, y hace estructuralmente imposible que quede un report obsoleto de objetos borrados.

**Q6.** Auto-gen. Cuando una policy alcanza a `Pod`, Kyverno sintetiza automáticamente reglas equivalentes contra los controladores de Pods (`Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob` y, acá, `ReplicaSet`), con el prefijo `autogen-` (`autogen-cronjob-` para CronJob), reescribiendo el path hacia `spec.template`. El background scan evalúa también esas reglas generadas, así que una sola regla escrita produce resultados en cada nivel de la cadena de propiedad. Consecuencia: los conteos de violaciones quedan inflados respecto de las cargas de trabajo distintas — deduplicá por owner de nivel superior antes de reportar una cifra de cumplimiento. El comportamiento de auto-gen se controla con la anotación `pod-policies.kyverno.io/autogen-controllers`.

**Q7.** `--skipResourceFilters=true` (el valor por defecto). `resourceFilters` en el ConfigMap `kyverno` excluye recursos del procesamiento de *admisión*; el background scan ignora deliberadamente esa lista de exclusión para que la visibilidad no se reduzca en silencio por una perilla de ajuste de rendimiento. El Ejercicio 7 lo invierte.

**Q8.** Seleccioná por scope en lugar de por nombre:
```bash
kubectl -n Y get polr -o json | jq -r '.items[] | select(.scope.name=="X") | .results[] | "\(.policy)/\(.rule)=\(.result)"'
```
Los nombres de los reports son el UID del recurso objetivo y deben tratarse como opacos.

**Q9.** Excluye a la policy del background scanning: no hay resultados para recursos existentes, y los resultados existentes aportados por esa policy se eliminan de los reports. **No** deshabilita la policy — la evaluación en tiempo de admisión (bloqueo o auditoría en admisión) continúa sin cambios. Es obligatorio para cualquier regla que use datos exclusivos del AdmissionReview, y también es una palanca de rendimiento legítima para reglas costosas sobre conjuntos de recursos enormes.

**Q10.** `admission: false, background: true` saca la regla del webhook por completo, así que un bug en la policy no puede agregar latencia a una petición de la API ni hacerla fallar — incluso durante una caída de Kyverno. `Audit` con `admission: true` sigue enrutando cada petición coincidente a través del webhook: la policy no puede bloquear, pero una regla lenta o un webhook con `failurePolicy: Fail` igual puede degradar o romper el camino de la API. La incorporación solo-scan te da el inventario de violaciones con radio de impacto cero sobre el camino de la petición.

**Q11.** Kyverno gestiona sus configuraciones de webhook de forma dinámica, derivando las `rules` (recursos, operaciones, scope) del conjunto de policies instaladas. Menos kinds alcanzados significa menos peticiones de la API interceptadas, así que el API server no paga un round-trip de red por objetos que a ninguna policy le importan. Un cluster con solo policies `admission: false` tiene un webhook de recursos efectivamente vacío.

**Q12.** El background scanning. El peor caso es un `--backgroundScanInterval` completo (por defecto `1h`) después de que el controlador vuelva a estar sano — a menos que el recurso se modifique después o cambie una policy, cualquiera de las dos cosas dispara una reevaluación inmediata. Esto es exactamente por qué una `failurePolicy` de `Ignore` es tolerable en producción: el webhook es de mejor esfuerzo, el scan es el respaldo.

**Q13.** Todo lo que provenga del `AdmissionReview` y no del objeto almacenado: `request.userInfo.*` (username, groups, uid), `request.roles`, `request.clusterRoles`, `serviceAccountName`, `serviceAccountNamespace` y el `request.oldObject`, que tiene forma de petición. Razón compartida: un background scan lee objetos desde el API server / la caché del informer; no hay solicitante, no hay petición y no hay versión previa del objeto contra la cual comparar. `request.object` *sí* está poblado — con el recurso tal como existe actualmente.

**Q14.** El valor de un motor de policies es que su report sea completo. Si Kyverno aceptara la policy y la salteara en silencio durante los scans, el `PolicyReport` resultante no mostraría violaciones para una regla que nunca se evaluó — indistinguible del cumplimiento total. Fallar en admisión convierte una brecha silenciosa de cobertura en un error de autoría ruidoso, en el momento en que la persona puede arreglarlo, y obliga al autor a explicitar el compromiso con `background: false`.

**Q15.** Dos. La verificación de identidad necesita `request.userInfo`, lo que fuerza `background: false`; la auditoría de la anotación tiene que correr en background para cubrir los ConfigMaps preexistentes. No pueden convivir en una sola policy porque `background` es un interruptor a nivel de policy (no de regla) — ponerlo en false para satisfacer la primera regla le quitaría la cobertura de background a la segunda.

**Q16.** `request.operation` es un campo del AdmissionReview y no tiene sentido durante un scan; las reglas que se bifurcan según ese campo pertenecen a policies con `background: false`. Conceptualmente, un background scan solo puede preguntar "¿este objeto, tal como existe ahora, es conforme?" — no tiene noción de CREATE vs UPDATE vs DELETE, ni un `oldObject` contra el cual hacer diff, así que cualquier regla basada en transiciones (verificaciones de inmutabilidad, "este campo no puede cambiar") es, por construcción, exclusiva de admisión.

**Q17.** Nada — `Enforce` se evalúa en admisión y solo afecta a las peticiones que llegan después de que la policy existe. Los 400 Deployments existentes siguen corriendo sin cambios. Sus resultados `fail` en objetos `PolicyReport`, producidos por el background scan, son la única evidencia de que violan la policy; la remediación es un acto aparte (reglas mutate-existing, o un cambio humano/GitOps). Esta es la razón por la que existe el background scanning.

**Q18.** Porque los resultados del Deployment y del ReplicaSet los producen reglas autogeneradas, cuyos nombres difieren del de la regla escrita. Una `PolicyException` matchea por `policyName` + `ruleNames`, así que eximir solo `check-team-label` limpiaría el resultado del Pod dejando fallando el `autogen-check-team-label` del Deployment. (Algunas releases aceptan un comodín como `autogen-*`; verificá contra tu versión en lugar de asumirlo.)

**Q19.** `skip` — la regla no se aplicó a este recurso (una `PolicyException` coincidente, o preconditions/`exclude` que no matchearon): el cumplimiento no fue evaluado. `warn` — la regla falló pero es non-scored/de severidad de auditoría, así que no cuenta en contra del puntaje. `error` — Kyverno no pudo evaluar la regla: falló la sustitución de variables, un `apiCall`/contexto externo dio timeout, una expresión JMESPath era inválida. Solo `error` indica una policy rota en lugar de un recurso no conforme, y es la clase que debe despertar a alguien.

**Q20.** Un `skip` mejora el puntaje en silencio: el recurso desaparece de `fail` sin volverse conforme. Detectalo graficando la tendencia de los conteos de `skip` junto a los de `fail`, e inventariando los objetos `PolicyException` (`kubectl get polex -A`) con un proceso de vencimiento/revisión — las excepciones son la forma ordinaria en que una métrica de cumplimiento se falsea sin ruido.

**Q21.** Cambio de policy → se dispara el informer de policies del reports controller → enumera los recursos coincidentes (informers de metadata) y evalúa cada uno → se escriben objetos intermedios por recurso (`EphemeralReport`/`ClusterEphemeralReport` en 1.13+, `BackgroundScanReport`/`AdmissionReport` y sus variantes de cluster antes) → el controlador de agregación fusiona los resultados de origen admisión y de origen scan de cada recurso en el `PolicyReport`/`ClusterPolicyReport` final, propiedad de ese recurso → el objeto intermedio se elimina. La separación existe para que los productores (webhook, escáner) puedan escribir de forma independiente y barata mientras un único consumidor es dueño del objeto final.

**Q22.** El hash identifica el conjunto exacto de policies contra el que un recurso fue evaluado por última vez. Si el hash no cambió, el recurso no necesita reevaluación, que es lo que hace barato un resync sobre 60.000 objetos. Editar policies en un loop apretado invalida el hash de cada recurso alcanzado en cada edición, forzando una reevaluación completa cada vez — un job de CI que reaplica todas las ClusterPolicies cada pocos minutos puede mantener al reports controller permanentemente saturado aunque semánticamente no haya cambiado nada.

**Q23.** El reports controller (la agregación es su trabajo). Lo más probable: (a) está en crash-loop, fue OOMKilled o está trabado — revisá `kubectl -n kyverno get pods` y su límite de memoria; (b) la agregación está deshabilitada o mal configurada (`--aggregateReports=false`, `--policyReports=false`), o le sacaron el RBAC para crear/actualizar `policyreports`. Una tercera causa lejana: el API server está rechazando reports demasiado grandes, en cuyo caso `--reportsChunkSize` y el log lo van a decir.

**Q24.** Le indica al escáner de background que ignore la lista de exclusión `resourceFilters`. El valor por defecto es `true` para que una perilla agregada para proteger el camino caliente de *admisión* (saltear `Event`, `Node`, `kube-system`, etc. para recortar tráfico del webhook) no ciegue en silencio tu *reporting de cumplimiento* — visibilidad y enforcement se ajustan de forma independiente, y un namespace filtrado suele ser uno que igual querés auditar.

**Q25.** (1) Presión de lectura sobre el API server / etcd — un resync completo lista y reevalúa cada objeto alcanzado cada minuto; (2) CPU del reports controller, ya que 40 policies × 60.000 recursos son 2,4 M de evaluaciones de reglas por ciclo, que no van a terminar en 60 s con 2 workers, así que los ciclos se solapan y la cola de trabajo crece sin límite; (3) amplificación de escritura — cada resultado que cambia reescribe un `PolicyReport` a través del API server, y el throughput de escritura de etcd más el fan-out de watches hacia cada consumidor de reports se vuelve el cuello de botella. La primera falla visible normalmente es el reports controller siendo OOMKilled (mantiene la caché del informer y los reports en vuelo), seguida por alertas de SLO de latencia del API server.

**Q26.** Cada worker mantiene en memoria recursos decodificados y contexto de evaluación, y todos los workers compiten por el mismo presupuesto de lectura/escritura del API server. Subir la cantidad de workers eleva la huella de memoria del reports controller de forma aproximadamente lineal y empuja la tasa de peticiones contra el API server; pasado cierto punto cambiás un ciclo de scan más corto por OOMKills y throttling del API server que lo vuelven a alargar. Escalá los workers junto con el límite de memoria, y preferí un intervalo más largo antes que más workers cuando el cluster es grande.

**Q27.** `--enableConfigMapCaching=true` — Kyverno observa y cachea el ConfigMap en lugar de leerlo una sola vez al arrancar, así que las ediciones surten efecto en segundos. Sin un watch necesitarías un rollout de cada controlador para cambiar los filtros, lo que durante un incidente (por ejemplo, excluir un kind desbocado para aliviar carga) es exactamente el peor momento para reiniciar el motor de policies.

**Q28.** `resourceFilters` **combinado con** `--skipResourceFilters=false` lo logra: el escáner entonces respeta la exclusión y no escribe ningún objeto de report para ese namespace. `resourceFilters` por sí solo no — con el `skipResourceFilters=true` por defecto seguís obteniendo un conjunto completo de reports para el namespace "excluido". Notá el compromiso: apagar el flag también significa que las violaciones genuinas ahí se vuelven invisibles.

**Q29.** El scan no pudo listar el kind en absoluto, así que ningún recurso entró jamás al loop de evaluación — no había nada a lo que adjuntarle un resultado `error`. Un resultado `error` requiere un recurso sobre el cual reportar; la falta de permiso de *list* elimina el conjunto de recursos mismo. El supuesto roto es el del auditor: "no hay resultados fallidos" se leyó como "es conforme", cuando en realidad significaba "nunca se miró". La ausencia de resultados no es evidencia de cumplimiento — verificá siempre de forma cruzada que los scopes esperados existan (`kubectl get polr -A -o json | jq -r '.items[].scope.kind' | sort | uniq -c`).

**Q30.** (1) Los ClusterRoles propios de Kyverno los gestiona el chart de Helm, así que las ediciones directas se revierten en el próximo `helm upgrade` — el arreglo se evaporaría en el peor momento posible. (2) La agregación es el punto de extensión documentado: `rbac.kyverno.io/aggregate-to-reports-controller: "true"` (y `...-to-background-controller`, `...-to-admission-controller`) compone tu permiso dentro del rol incorporado vía la agregación de ClusterRoles de Kubernetes, mantiene el permiso agregado auditable como un objeto separado y revisable, y lo acota a exactamente un controlador en lugar de ensanchar a todos.

**Q31.** No — la admisión sigue funcionando. En admisión, el API server *empuja* el objeto hacia Kyverno dentro del AdmissionReview; Kyverno no necesita permiso de lectura sobre el kind para evaluarlo. El background scan tiene que *traer* los objetos por sí mismo con la ServiceAccount del reports controller, y por eso necesita `get`/`list`/`watch`. Esta asimetría es la razón por la que una policy puede aplicar correctamente el enforcement sobre Widgets nuevos sin reportar nada sobre los existentes.

**Q32.** Extraé cada kind alcanzado de las policies y afirmá que el reports controller puede listarlo:
```bash
kubectl get cpol -o json | jq -r '.items[].spec.rules[].match.any[].resources.kinds[]' | sort -u | \
  while read -r k; do echo -n "$k: "; kubectl auth can-i list "${k,,}s" \
    --as=system:serviceaccount:kyverno:kyverno-reports-controller; done
```
(Ajustá la derivación del plural con `kubectl api-resources` para kinds irregulares; el punto es la aserción, no la manipulación de cadenas.)

**Q33.** `rule_execution_cause` — filtrá por el valor de background scan (`background_scan`; el uso de mayúsculas ha variado entre releases, así que hacé grep sin distinguir mayúsculas antes de fijar un matcher de PromQL) y excluí el valor de petición de admisión. `policy_background_mode` te dice si la policy es *elegible* para el escaneo, que es una pregunta distinta y un segundo panel útil: expone las policies excluidas de los scans por `background: false`.

**Q34.** La CLI no puede reproducir (a) el ciclo de vida del report — owner references, garbage collection, agregación de resultados de admisión más de scan en un objeto por recurso; ni (b) el contexto del lado del cluster que solo tiene el controlador, como el RBAC de su ServiceAccount, el manejo de `PolicyException` y los `resourceFilters` provenientes del ConfigMap — por lo que su veredicto puede diferir del del cluster. Igualmente es la herramienta correcta en CI: evalúa una policy contra manifiestos o contra un cluster en vivo *antes* de que la policy sea admitida, atrapando regresiones sin instalar nada.

**Q35.** `kyverno_policy_results_total` es un contador monótonamente creciente de *evaluaciones* de reglas, no un gauge de violaciones actuales — borrar los Pods infractores hace que deje de incrementarse, pero nunca lo decrementa, y sigue subiendo en cada reescaneo de recursos que continúan fallando. Alertá en cambio sobre el estado actual derivado de los reports, por ejemplo el campo `fail` sumado de los resúmenes de `PolicyReport`/`ClusterPolicyReport` (exportado por Policy Reporter o un exporter chico), que cae a cero cuando las violaciones se remedian de verdad. Usá el contador para tasa de cambio y para alertar sobre resultados `error`, nunca para un nivel de cumplimiento.

</details>

---

## Referencias

- Currículum KCA (CNCF): <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Kyverno — Background Processing: <https://kyverno.io/docs/writing-policies/background/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Kyverno — Instalación / personalización (flags del contenedor, agregación de RBAC): <https://kyverno.io/docs/installation/customization/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno — Monitoreo y métricas: <https://kyverno.io/docs/monitoring/>
- Valores del chart de Helm de Kyverno (`features.backgroundScan.*`): <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml>
- Policy WG de Kubernetes — API PolicyReport: <https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report>
- Código fuente de Kyverno: <https://github.com/kyverno/kyverno>