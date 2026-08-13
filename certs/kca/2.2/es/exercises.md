# Tema 2.2 — Kyverno Custom Resource Definitions (CRDs)

> **Dominio 2 · Peso en el examen: 3.0 · Nivel: producción**
>
> Kyverno es un motor de políticas que se ejecuta *enteramente como un conjunto de Kubernetes Custom Resources*. No hay DSL, ni lenguaje de sidecar, ni lenguaje de políticas externo que aprender: cada policy, cada exception, cada resultado y cada elemento de trabajo interno es un objeto de Kubernetes servido por el API server a través de un CRD que Kyverno instala. Dominar la superficie de CRDs — qué kinds existen, su scope, sus API groups/versions, y cómo se relacionan entre sí — es la columna vertebral de todo lo demás en el examen.
>
> **Prerequisitos:** un cluster funcional (se recomienda `kind`, `k3d`, o minikube ≥ 3 nodos), `kubectl ≥ 1.27`, y Helm 3. Todos los manifiestos de abajo son sintácticamente completos e idempotentes — reaplicarlos es seguro.

---

## Ejercicio 0 — Instalar Kyverno y exponer su superficie de CRDs

Kyverno distribuye sus CRDs como parte del Helm chart. Instalar el chart es la única forma en que el API server aprende sobre `ClusterPolicy`, `PolicyReport`, etc.

**Pasos**

1. Agregá el repositorio e instalá en su propio namespace:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --set admissionController.replicas=1 \
     --wait
   ```

2. Confirmá que cada Deployment de controlador esté Ready (Kyverno 1.10+ se divide en cuatro controladores):

   ```bash
   kubectl -n kyverno get deploy
   ```

   Esperado:

   ```
   NAME                                 READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller         1/1     1            1           95s
   kyverno-background-controller        1/1     1            1           95s
   kyverno-cleanup-controller           1/1     1            1           95s
   kyverno-reports-controller           1/1     1            1           95s
   ```

3. Listá cada CRD que Kyverno registró:

   ```bash
   kubectl get crd | grep -E 'kyverno\.io|wgpolicyk8s\.io'
   ```

   Esperado (abreviado):

   ```
   admissionreports.reports.kyverno.io                2026-08-13T09:14:22Z
   backgroundscanreports.reports.kyverno.io           2026-08-13T09:14:22Z
   cleanuppolicies.kyverno.io                         2026-08-13T09:14:21Z
   clusteradmissionreports.reports.kyverno.io         2026-08-13T09:14:22Z
   clusterbackgroundscanreports.reports.kyverno.io    2026-08-13T09:14:22Z
   clustercleanuppolicies.kyverno.io                  2026-08-13T09:14:21Z
   clusterpolicies.kyverno.io                         2026-08-13T09:14:21Z
   clusterpolicyreports.wgpolicyk8s.io                2026-08-13T09:14:22Z
   globalcontextentries.kyverno.io                    2026-08-13T09:14:21Z
   policies.kyverno.io                                2026-08-13T09:14:21Z
   policyexceptions.kyverno.io                        2026-08-13T09:14:21Z
   policyreports.wgpolicyk8s.io                       2026-08-13T09:14:22Z
   updaterequests.kyverno.io                          2026-08-13T09:14:21Z
   ```

**Comprensión**

- **Q1.** Dos de los CRDs de arriba **no** viven en el API group `kyverno.io`. ¿Cuáles dos, y a qué group pertenecen? ¿Por qué pensás que Kyverno adoptó un group externo para ellos en lugar de `kyverno.io`?
- **Q2.** ¿Cuál de los cuatro Deployments de controlador esperarías que sea el consumidor *autor* de los CRDs `reports.kyverno.io`, y cuál produce los reports `wgpolicyk8s.io`?

---

## Ejercicio 1 — Enumerar scope, short names, y API versions

Los CRDs tienen tres propiedades que el examen evalúa repetidamente: **scope** (Namespaced vs Cluster), **short name**, y **served/storage versions**.

**Pasos**

1. Imprimí la tabla de recursos legible por máquina para ambos groups:

   ```bash
   kubectl api-resources --api-group=kyverno.io
   kubectl api-resources --api-group=reports.kyverno.io
   kubectl api-resources --api-group=wgpolicyk8s.io
   ```

   Salida esperada combinada:

   ```
   NAME                           SHORTNAMES   APIVERSION                NAMESPACED   KIND
   cleanuppolicies                cleanpol     kyverno.io/v2beta1        true         CleanupPolicy
   clustercleanuppolicies         ccleanpol    kyverno.io/v2beta1        false        ClusterCleanupPolicy
   clusterpolicies                cpol         kyverno.io/v1             false        ClusterPolicy
   globalcontextentries           gctxentry    kyverno.io/v2alpha1       false        GlobalContextEntry
   policies                       pol          kyverno.io/v1             true         Policy
   policyexceptions               polex        kyverno.io/v2beta1        true         PolicyException
   updaterequests                 ur           kyverno.io/v2             true         UpdateRequest
   admissionreports               admr         reports.kyverno.io/v1     true         AdmissionReport
   backgroundscanreports          bgscanr      reports.kyverno.io/v1     true         BackgroundScanReport
   clusteradmissionreports        cadmr        reports.kyverno.io/v1     false        ClusterAdmissionReport
   clusterbackgroundscanreports   cbgscanr     reports.kyverno.io/v1     false        ClusterBackgroundScanReport
   clusterpolicyreports           cpolr        wgpolicyk8s.io/v1alpha2   false        ClusterPolicyReport
   policyreports                  polr         wgpolicyk8s.io/v1alpha2   true         PolicyReport
   ```

2. Mirá qué API versions sirve el CRD *policy*, y cuál es la versión de **storage**:

   ```bash
   kubectl api-versions | grep kyverno
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{range .spec.versions[*]}{.name}{"  served="}{.served}{"  storage="}{.storage}{"\n"}{end}'
   ```

   Esperado:

   ```
   kyverno.io/v1
   kyverno.io/v2
   kyverno.io/v2beta1
   ```
   ```
   v1        served=true   storage=false
   v2beta1   served=true   storage=false
   v2        served=true   storage=true
   ```

3. Confirmá el scope directamente desde el CRD (no solo `api-resources`):

   ```bash
   kubectl get crd policies.kyverno.io        -o jsonpath='{.spec.scope}{"\n"}'
   kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.scope}{"\n"}'
   ```

   Esperado:

   ```
   Namespaced
   Cluster
   ```

**Comprensión**

- **Q3.** Un `Policy` y un `ClusterPolicy` tienen schemas de `spec` *idénticos byte por byte*. ¿Cuál único campo del CRD es lo único que difiere, y qué garantía práctica le da elegir `Policy` en lugar de `ClusterPolicy` a un tenant de namespace?
- **Q4.** Escribiste un manifiesto con `apiVersion: kyverno.io/v1`. El CRD reporta `v2` como la versión de storage. Cuando hacés `kubectl get cpol <name> -o yaml`, ¿qué `apiVersion` vuelve, y por qué tu request original `v1` sigue siendo válido?
- **Q5.** Dá el short name correcto para `ClusterPolicy`, `PolicyReport`, `PolicyException`, y `UpdateRequest`.

---

## Ejercicio 2 — `ClusterPolicy` vs `Policy`: schema, scope, y alcance

Ahora instanciá los dos CRDs de policy y observá cómo el scope restringe lo que cada uno puede matchear.

**Pasos**

1. Inspeccioná el schema de nivel superior del CRD de policy sin salir de la terminal:

   ```bash
   kubectl explain clusterpolicy.spec --recursive=false
   ```

   Esperado (abreviado):

   ```
   FIELDS:
     admission                 <boolean>
     background                <boolean>
     failurePolicy             <string>
     rules                     <[]Object>
     validationFailureAction   <string>
     ...
   ```

2. Creá una policy de validación **cluster-scoped** que requiere un label `team` en cada Pod:

   ```yaml
   # require-labels-cpol.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce   # Audit | Enforce (PascalCase since 1.10)
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "The label 'team' is required on every Pod."
           pattern:
             metadata:
               labels:
                 team: "?*"          # ?* = at least one character
   ```

   ```bash
   kubectl apply -f require-labels-cpol.yaml
   ```

3. Creá una policy **namespaced** que solo gobierne el namespace `payments`:

   ```yaml
   # require-cost-center-pol.yaml
   apiVersion: kyverno.io/v1
   kind: Policy
   metadata:
     name: require-cost-center
     namespace: payments
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: check-cost-center
         match:
           any:
             - resources:
                 kinds:
                   - Pod
         validate:
           message: "Pods in payments must carry a cost-center label."
           pattern:
             metadata:
               labels:
                 cost-center: "?*"
   ```

   ```bash
   kubectl create namespace payments
   kubectl apply -f require-cost-center-pol.yaml
   ```

4. Intentá violar la cluster policy y mirá cómo admission la rechaza:

   ```bash
   kubectl run nginx --image=nginx --namespace=default
   ```

   Esperado:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/default/nginx was blocked due to the following policies

   require-team-label:
     check-team-label: 'validation error: The label ''team'' is required on every Pod.
       rule check-team-label failed at path /metadata/labels/team/'
   ```

5. Confirmá que la Policy namespaced no puede alcanzar fuera de su namespace:

   ```bash
   kubectl get pol -A
   ```

   Esperado:

   ```
   NAMESPACE   NAME                  BACKGROUND   VALIDATE ACTION   READY   AGE
   payments    require-cost-center   true         Audit             True    30s
   ```

**Comprensión**

- **Q6.** En el paso 2 la policy es `Enforce`; en el paso 3 es `Audit`. Cuando un recurso viola cada una, ¿cuál es la diferencia en el comportamiento observable al momento de `kubectl apply`?
- **Q7.** Se crea un Pod en `default`. ¿`require-cost-center` (una `Policy` en `payments`) lo evalúa? Justificá desde el scope del CRD, no desde el bloque `match`.
- **Q8.** El campo `spec.background` es `true`. ¿Qué activa ese flag, y qué CRD group es la *salida* de esa actividad de background?

---

## Ejercicio 3 — Los CRDs de resultado: PolicyReport, ClusterPolicyReport, y los reports intermedios

Kyverno nunca muta tu objeto de policy para almacenar resultados. Cada resultado de evaluación aterriza en un CRD de **report**. Hay dos *capas*: los CRDs internos `reports.kyverno.io` (resultados crudos por recurso, un detalle de implementación) y los CRDs agregados, de cara al usuario, `wgpolicyk8s.io`.

**Pasos**

1. Creá un Pod que *pasa* la cluster policy pero *falla* la audit policy namespaced:

   ```bash
   kubectl -n payments run app --image=nginx \
     --labels=team=core          # satisfies require-team-label, but no cost-center
   ```

2. Leé el report namespaced agregado:

   ```bash
   kubectl -n payments get policyreport
   kubectl -n payments get polr -o wide
   ```

   Esperado:

   ```
   NAME                          KIND   NAME   PASS   FAIL   WARN   ERROR   SKIP   AGE
   <hash>                        Pod    app    1      1      0      0      0      20s
   ```

3. Profundizá en una única entrada de resultado:

   ```bash
   kubectl -n payments get polr -o jsonpath='{.items[0].results[?(@.result=="fail")].message}{"\n"}'
   ```

   Esperado:

   ```
   Pods in payments must carry a cost-center label.
   ```

4. Mirá el agregado cluster-scoped para recursos cluster-scoped:

   ```bash
   kubectl get clusterpolicyreport
   kubectl get cpolr
   ```

5. Revelá los CRDs *intermedios* que el reports-controller consume y agrega:

   ```bash
   kubectl -n payments get admissionreports,backgroundscanreports
   kubectl get clusteradmissionreports,clusterbackgroundscanreports
   ```

   Esperado (namespaced):

   ```
   NAME                                        GVR         REF    AGGREGATE   READY
   admissionreport.reports.kyverno.io/<uid>    v1/pods     app                true
   NAME                                             KIND   SUBJECT   PASS   FAIL   AGE
   backgroundscanreport.reports.kyverno.io/<uid>    Pod    app       1      1      20s
   ```

**Comprensión**

- **Q9.** Un estudiante afirma "los resultados se almacenan dentro del `status` del ClusterPolicy". Corregilo: nombrá los dos *groups* de CRD que realmente contienen los resultados e indicá cuál deberías consultar para una API estable y documentada.
- **Q10.** ¿Cuál es la diferencia en el *disparador* entre un `AdmissionReport` y un `BackgroundScanReport`? Atá cada uno a un evento específico.
- **Q11.** Borraste el Pod `app`. ¿Qué le pasa a su entrada en el `PolicyReport`, y qué mecanismo (pista: un campo de metadata en el report) mantiene el report sincronizado con los recursos vivos?

---

## Ejercicio 4 — `PolicyException`: opt-outs con scope como objetos de primera clase

En lugar de editar una policy para tallar una exception, Kyverno modela la exception misma como un CRD (`PolicyException`, `polex`). Esto mantiene la policy inmutable y la exception auditable.

**Pasos**

1. Confirmá que las exceptions estén habilitadas (por defecto en los charts actuales; releases más viejos requerían flags):

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i exception
   ```

   Esperado (puede estar vacío en la configuración por defecto, o):

   ```
   "--enablePolicyException=true"
   ```

2. Creá un namespace que deba estar exento de la regla del team-label:

   ```bash
   kubectl create namespace sandbox
   ```

3. Declará la exception. Notá que apunta a la policy **y** al nombre de regla específico, incluyendo las variantes auto-generadas de pod-controller:

   ```yaml
   # sandbox-exception.yaml
   apiVersion: kyverno.io/v2beta1
   kind: PolicyException
   metadata:
     name: exempt-sandbox-team-label
     namespace: sandbox
   spec:
     exceptions:
       - policyName: require-team-label
         ruleNames:
           - check-team-label
           - autogen-check-team-label      # Deployments/ReplicaSets/etc.
     match:
       any:
         - resources:
             kinds:
               - Pod
             namespaces:
               - sandbox
   ```

   ```bash
   kubectl apply -f sandbox-exception.yaml
   ```

4. Probá que la acción previamente bloqueada ahora tiene éxito *solo* en `sandbox`:

   ```bash
   kubectl -n sandbox run nginx --image=nginx      # no team label — succeeds
   kubectl -n default run nginx --image=nginx      # still blocked
   ```

   Esperado:

   ```
   pod/nginx created
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: ...
   ```

**Comprensión**

- **Q12.** ¿Por qué la `PolicyException` debe listar `autogen-check-team-label` además de `check-team-label`? ¿Qué feature de Kyverno genera ese segundo nombre de regla?
- **Q13.** Una `PolicyException` es un CRD Namespaced. ¿Cuál es la significancia de seguridad de ese scope en un cluster multi-tenant, y cómo evitaría un equipo de plataforma que los tenants escriban sus propias exceptions?
- **Q14.** Después de aplicar la exception, ¿el Pod exento aparece como `pass`, `fail`, o `skip` en el `PolicyReport`? ¿Cuál es la semántica prevista de ese valor de resultado?

---

## Ejercicio 5 — `UpdateRequest`: el motor asíncrono detrás de `generate` y `mutateExisting`

Cuando una regla *genera* un recurso o muta recursos existentes, admission no puede hacer el trabajo de forma síncrona (puede abarcar muchos objetos). En su lugar, Kyverno encola un `UpdateRequest` (`ur`) interno que el **background-controller** reconcilia.

**Pasos**

1. Otorgá al background controller permiso para crear el kind objetivo (los targets de generate a menudo necesitan RBAC explícito vía un ClusterRole agregado):

   ```yaml
   # bg-networkpolicy-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:generate-networkpolicies
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
     - apiGroups: ["networking.k8s.io"]
       resources: ["networkpolicies"]
       verbs: ["create", "update", "delete", "get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f bg-networkpolicy-rbac.yaml
   ```

2. Aplicá una policy `generate` que aprovisiona una NetworkPolicy default-deny en cada namespace y la mantiene sincronizada:

   ```yaml
   # generate-default-deny.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-deny
   spec:
     rules:
       - name: default-deny
         match:
           any:
             - resources:
                 kinds:
                   - Namespace
         generate:
           apiVersion: networking.k8s.io/v1
           kind: NetworkPolicy
           name: default-deny
           namespace: "{{request.object.metadata.name}}"
           synchronize: true
           data:
             spec:
               podSelector: {}
               policyTypes:
                 - Ingress
                 - Egress
   ```

   ```bash
   kubectl apply -f generate-default-deny.yaml
   kubectl create namespace tenant-a
   ```

3. Observá el `UpdateRequest` creado para llevar a cabo la generación, luego el objeto generado:

   ```bash
   kubectl -n kyverno get updaterequests
   kubectl -n tenant-a get networkpolicy default-deny
   ```

   Esperado:

   ```
   NAME       POLICY             RULETYPE   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS
   ur-abc12   add-default-deny   generate   Namespace      tenant-a                           Completed
   ```
   ```
   NAME           POD-SELECTOR   AGE
   default-deny   <none>         6s
   ```

4. Probá `synchronize: true` — borrá el recurso generado y mirá cómo Kyverno lo recrea vía un nuevo `UpdateRequest`:

   ```bash
   kubectl -n tenant-a delete networkpolicy default-deny
   sleep 5
   kubectl -n tenant-a get networkpolicy default-deny   # back again
   ```

**Comprensión**

- **Q15.** ¿Por qué `generate` usa un CRD `UpdateRequest` en lugar de hacer el trabajo dentro de la respuesta del admission webhook? Dá la razón arquitectónica.
- **Q16.** El `UpdateRequest` vive en el namespace **kyverno**, no en el namespace objetivo. ¿Qué te dice eso sobre qué controlador lo posee y reconcilia?
- **Q17.** Con `synchronize: true`, ¿qué dos clases distintas de drift reconcilia el background controller, y qué cambiaría `synchronize: false`?

---

## Ejercicio 6 — `CleanupPolicy` / `ClusterCleanupPolicy`: TTL como un CRD programado

Las cleanup policies borran recursos en un schedule de cron cuando las condiciones matchean — implementado por el **cleanup-controller** y modelado como su propio par de CRDs.

**Pasos**

1. Otorgá al cleanup controller derechos de borrado sobre el kind objetivo (rol agregado, reflejando el Ejercicio 5):

   ```yaml
   # cleanup-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:cleanup-completed-jobs
     labels:
       rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   rules:
     - apiGroups: ["batch"]
       resources: ["jobs"]
       verbs: ["get", "list", "watch", "delete"]
   ```

   ```bash
   kubectl apply -f cleanup-rbac.yaml
   ```

2. Creá una `ClusterCleanupPolicy` que elimina los Jobs completados cada 5 minutos:

   ```yaml
   # cleanup-completed-jobs.yaml
   apiVersion: kyverno.io/v2beta1
   kind: ClusterCleanupPolicy
   metadata:
     name: cleanup-completed-jobs
   spec:
     match:
       any:
         - resources:
             kinds:
               - Job
     conditions:
       all:
         - key: "{{ target.status.succeeded || `0` }}"
           operator: GreaterThanOrEquals
           value: 1
     schedule: "*/5 * * * *"
   ```

   ```bash
   kubectl apply -f cleanup-completed-jobs.yaml
   ```

3. Validá e inspeccioná:

   ```bash
   kubectl get ccleanpol
   kubectl describe ccleanpol cleanup-completed-jobs | sed -n '/Events/,$p'
   ```

   Esperado:

   ```
   NAME                     SCHEDULE      AGE
   cleanup-completed-jobs   */5 * * * *   12s
   ```

**Comprensión**

- **Q18.** Una `CleanupPolicy` no tiene bloque `rules:`, a diferencia de `ClusterPolicy`. ¿Qué dos campos reemplazan la maquinaria de validate/mutate/generate, y qué aporta cada uno?
- **Q19.** En la condición, la variable es `target.*`, no `request.object.*`. ¿Por qué es `target` el contexto correcto para una cleanup policy?
- **Q20.** El cleanup controller es un Deployment *separado* con un label de RBAC agregado *separado*. ¿Qué falla verías si olvidaras el ClusterRole en el paso 1, y dónde se manifestaría?

---

## Ejercicio 7 — Inspeccionar el contrato del CRD en sí (versions, conversion, printer columns)

El examen espera que leas un CRD como un objeto de Kubernetes, no solo que apliques CRs.

**Pasos**

1. Volcá las served/storage versions y la estrategia de conversion del CRD de policy:

   ```bash
   kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.spec.conversion.strategy}{"\n"}'
   ```

   Esperado:

   ```
   Webhook
   ```

2. Mirá las additional printer columns que hacen que `kubectl get cpol` sea legible para humanos:

   ```bash
   kubectl get crd clusterpolicies.kyverno.io \
     -o jsonpath='{range .spec.versions[?(@.storage==true)].additionalPrinterColumns[*]}{.name}{"\t"}{.jsonPath}{"\n"}{end}'
   ```

   Esperado (abreviado):

   ```
   Admission    .spec.admission
   Background   .spec.background
   Ready        .status.conditions[?(@.type=="Ready")].status
   Age          .metadata.creationTimestamp
   ```

3. Leé la documentación de un campo directamente desde el schema de OpenAPI incorporado en el CRD:

   ```bash
   kubectl explain clusterpolicy.spec.validationFailureAction
   ```

   Esperado:

   ```
   FIELD: validationFailureAction <string>
   DESCRIPTION:
       ValidationFailureAction defines if a validation policy rule violation
       should block the admission review request (Enforce) or allow (Audit) the
       admission review request and report an error in a policy report...
   ```

4. Verificá que un manifiesto escrito contra una served version *más vieja* se convierte de forma transparente a storage:

   ```bash
   kubectl get cpol require-team-label -o jsonpath='{.apiVersion}{"\n"}'
   ```

   Esperado:

   ```
   kyverno.io/v2
   ```

**Comprensión**

- **Q21.** El `conversion.strategy` del CRD es `Webhook`. ¿Qué significa eso para un cluster que tiene objetos `ClusterPolicy` almacenados en `v1` cuando el operador sube la versión de storage a `v2`? ¿Qué componente realiza la traducción?
- **Q22.** `kubectl explain` devolvió documentación real de campos. ¿Dónde vive físicamente ese texto, y por qué funciona incluso offline contra el API server?

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

**Q1.** `policyreports` y `clusterpolicyreports` pertenecen al group **`wgpolicyk8s.io/v1alpha2`** — la API **Policy WG (Working Group) Policy Report** de Kubernetes, un estándar *vendor-neutral*. Kyverno lo adoptó deliberadamente para que cualquier consumidor (Policy Reporter UI, Falco, kube-bench, Trivy, etc.) pueda leer un formato de report único y común sin importar qué motor lo produjo. Los CRDs del group `kyverno.io` son específicos de Kyverno; el schema del report intencionalmente no lo es.

**Q2.** El **reports-controller** autora/reconcilia los CRDs internos `reports.kyverno.io` (AdmissionReport, BackgroundScanReport y sus variantes de cluster) y los *agrega* en los `PolicyReport`/`ClusterPolicyReport` de cara al usuario del group **`wgpolicyk8s.io`**. Así que el reports-controller tanto consume los CRDs intermedios como produce los del estándar wg.

**Q3.** El único campo que difiere es el **`spec.scope`** del CRD (`Namespaced` para `Policy`, `Cluster` para `ClusterPolicy`). Elegir `Policy` garantiza que el objeto — y por lo tanto su autoridad de enforcement — quede confinado a su propio namespace: un tenant de namespace con RBAC solo en su namespace puede crear/leer/borrar sus objetos `Policy` pero no puede autorar reglas a nivel de cluster.

**Q4.** `kubectl get` devuelve **`kyverno.io/v2`** — la versión de *storage* — porque el API server persiste cada objeto en la versión de storage y lo sirve de vuelta convertido. Tu request `v1` es válido porque `v1` sigue siendo una versión **served**; el API server convierte tu envío `v1` a `v2` para storage (vía el conversion webhook) y de vuelta a la versión que pidas al leer.

**Q5.** `ClusterPolicy → cpol`; `PolicyReport → polr`; `PolicyException → polex`; `UpdateRequest → ur`.

**Q6.** `Enforce` hace que el admission webhook **rechace** el request — `kubectl apply` falla con un error `denied the request`, y el objeto nunca se crea. `Audit` **permite** que el objeto se cree y en cambio registra un resultado `fail` en un `PolicyReport`; el usuario ve éxito al momento de aplicar.

**Q7.** No. `require-cost-center` es una **`Policy`** (CRD Namespaced) en `payments`; una policy namespaced solo puede evaluar recursos en su *propio* namespace. Un Pod en `default` está fuera de scope sin importar lo que diga el bloque `match` — el scope se aplica por el límite del CRD/motor antes de siquiera considerar `match`.

**Q8.** `background: true` habilita el **background scanning**: Kyverno re-evalúa periódicamente los recursos *ya existentes* contra la policy (no solo al momento de admission), de modo que las policies agregadas después de que los recursos existen igual obtienen resultados. Su salida es la capa de report — los objetos internos `BackgroundScanReport` de `reports.kyverno.io`, agregados en los `PolicyReport`/`ClusterPolicyReport` de `wgpolicyk8s.io`.

**Q9.** Los resultados **no** están en el `status` de la policy. Viven en (a) el group interno **`reports.kyverno.io`** (AdmissionReport/BackgroundScanReport, un detalle de implementación) y (b) el group agregado y estandarizado **`wgpolicyk8s.io`** (PolicyReport/ClusterPolicyReport). Consultá el `polr`/`cpolr` de **`wgpolicyk8s.io`** para una API estable y documentada.

**Q10.** Un **AdmissionReport** es producido por un *evento de admission* — un request real de create/update que pasa a través del webhook. Un **BackgroundScanReport** es producido por el *background scan* — una re-evaluación periódica de recursos existentes sin ningún request de usuario involucrado.

**Q11.** La entrada es **eliminada**: los reports se mantienen sincronizados con los recursos vivos. Cada report lleva **`ownerReferences`** que apuntan al recurso subyacente (e identificadores de recurso por resultado); cuando el Pod se borra, Kubernetes hace garbage-collect/reconcilia la entrada de report poseída para que los resultados obsoletos no persistan.

**Q12.** Kyverno **auto-genera** variantes de regla para los controladores de Pod (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet…) prefijando el nombre de regla original con `autogen-` (y `autogen-cronjob-` para CronJobs). Una única regla que matchea Pods por lo tanto también corre contra el template de Pod dentro de los controladores, así que una exception debe nombrar esas reglas generadas también, o el camino del controlador sigue con enforcement.

**Q13.** Como `PolicyException` es Namespaced, quien pueda hacer `create` de ella en un namespace puede debilitar la policy **para ese namespace** — un vector de escalada de privilegios en multi-tenancy. Un equipo de plataforma evita las exceptions escritas por tenants mediante (a) RBAC que niegue a los tenants `create` sobre `policyexceptions`, y/o (b) restringiendo las exceptions a un namespace controlado vía el flag del controlador (por ej. `--exceptionNamespace=<trusted-ns>`) para que solo se honren las exceptions en ese namespace.

**Q14.** El recurso exento se reporta como **`skip`**. `skip` significa que la regla *matcheó la selección pero no fue evaluada intencionalmente* (aquí, porque aplicó una `PolicyException`) — distinto de `pass` (evaluada y satisfecha) y `fail` (evaluada y violada).

**Q15.** La generación puede expandirse a través de muchos recursos/namespaces y debe **reintentarse y reconciliarse a lo largo del tiempo**; el admission webhook debe retornar dentro de su timeout y solo gobierna el único request en curso. Modelar el trabajo como un CRD `UpdateRequest` lo entrega a un controlador asíncrono, level-triggered (el background-controller) que puede reintentar, rastrear el status, y mantener los targets sincronizados — nada de lo cual encaja en una respuesta síncrona de webhook.

**Q16.** Te dice que el **background-controller** (que corre en el namespace kyverno) posee y reconcilia los `UpdateRequest`s. Son elementos de trabajo internos de ese controlador, no objetos de cara al tenant, así que viven centralizados en el namespace de instalación en lugar de dispersos por los namespaces objetivo.

**Q17.** Con `synchronize: true` el controlador reconcilia (1) el **borrado/mutación del target generado** (borrá la NetworkPolicy → se recrea; editala → se revierte a los datos de la policy) y (2) el **drift por cambios en la policy fuente** (editá el `generate.data` → todas las copias generadas se actualizan). `synchronize: false` hace que la generación sea **fire-and-forget**: el target se crea una vez y de ahí en adelante nunca se re-sincroniza ni se restaura.

**Q18.** `CleanupPolicy` reemplaza `rules:` con **`schedule:`** (una expresión de cron que define *cuándo* evalúa el controlador) y **`conditions:`** (un predicado JMESPath/CEL sobre el recurso candidato que define *cuáles* objetos matcheados se borran). Junto con `match:`, seleccionan los targets y temporizan el borrado.

**Q19.** Una cleanup policy actúa sobre recursos **existentes** que está examinando para borrado, no sobre un request de admission entrante — no hay `request.object`. `target` es el contexto que Kyverno vincula a cada recurso candidato bajo evaluación, así que las condiciones deben leer desde `target.*` (por ej. `target.status.succeeded`).

**Q20.** El borrado **fallaría con un error forbidden/RBAC**: el ServiceAccount del cleanup-controller carece de `delete` sobre el kind objetivo. Se manifiesta en los **logs del pod del cleanup-controller** y típicamente como **Warning Events** en el objeto `ClusterCleanupPolicy` (visible vía `kubectl describe ccleanpol`). El controlador tiene su propio label de agregación (`rbac.kyverno.io/aggregate-to-cleanup-controller`) distinto del background controller.

**Q21.** Los objetos almacenados en `v1` se **leen tal cual y se convierten bajo demanda** por el **conversion webhook** (el propio servicio de Kyverno, dado que `strategy: Webhook`). Subir la versión de storage a `v2` no reescribe los objetos existentes de inmediato; cada uno se convierte a `v2` la próxima vez que se escribe (o vía una migración de storage-version). El conversion webhook traduce entre served versions en ambas direcciones, así que los clientes en `v1` siguen funcionando.

**Q22.** La documentación vive en el **schema OpenAPI v3** del CRD (`spec.versions[].schema.openAPIV3Validation`), embebido en el objeto CRD almacenado en el cluster. `kubectl explain` lo lee desde el **endpoint de discovery/OpenAPI del API server**, que se sirve desde ese schema in-cluster — no se necesita acceso a internet, solo alcanzabilidad al API server.

</details>

---

### Fuentes (oficiales)

- Kyverno — Introducción y arquitectura: <https://kyverno.io/docs/introduction/>
- Kyverno — Instalación (Helm, controladores): <https://kyverno.io/docs/installation/>
- Kyverno — Escritura de policies · Validate: <https://kyverno.io/docs/writing-policies/validate/>
- Kyverno — Escritura de policies · Generate (UpdateRequest, synchronize): <https://kyverno.io/docs/writing-policies/generate/>
- Kyverno — Policy Exceptions: <https://kyverno.io/docs/writing-policies/exceptions/>
- Kyverno — Cleanup Policies: <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — Policy Reports (`wgpolicyk8s.io`): <https://kyverno.io/docs/policy-reports/>
- Kubernetes Policy WG — Policy Report API: <https://github.com/kubernetes-sigs/wg-policy-prototypes>
- Kubernetes — CustomResourceDefinition versioning & conversion: <https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/>
- CNCF Kyverno Certified Associate (KCA) currículum: <https://github.com/cncf/curriculum>