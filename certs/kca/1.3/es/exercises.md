# Topic 1.3 — Admission Controllers · Ejercicios guiados

> **Dónde encaja esto en el request path.** Cada escritura a la API de Kubernetes recorre: **Authentication → Authorization → Mutating admission → Validación del schema del objeto → Validating admission → persistir en etcd**. Los admission controllers son la *última* barrera antes de que un objeto se almacene, y la *única* barrera que puede tanto **rechazar** una request como **modificar el objeto** a su paso. Se ejecutan en dos fases: primero los mutating controllers/webhooks (pueden reescribir el objeto) y luego —tras revalidar el objeto mutado contra el schema OpenAPI— los validating controllers/webhooks (solo pueden aceptar o rechazar). Las lecturas (`GET`, `LIST`, `WATCH`) nunca pasan por admission.
>
> **Referencia:** <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>

**Prerrequisitos**

- Un clúster que administres, **v1.30 o más reciente** (`ValidatingAdmissionPolicy` es GA desde 1.30). `kind create cluster` o `minikube start` es ideal: obtenés un `kube-apiserver` real como static pod.
- `kubectl` configurado con `cluster-admin`.
- Los ejemplos asumen un clúster `kind` llamado `kind` (contenedor del control-plane `kind-control-plane`). Ajustá los nombres de nodo/contenedor según tu entorno.

---

## Exercise 1 — Mapear la cadena de admission en un clúster vivo

**Objetivo:** ver qué controllers vienen compilados y habilitados por defecto, y cómo `kubeadm` agrega otros por encima.

1. Confirmá que el API server corre como static pod y encontrá su nombre:

   ```bash
   kubectl -n kube-system get pod -l component=kube-apiserver
   ```

   ```
   NAME                                READY   STATUS    RESTARTS   AGE
   kube-apiserver-kind-control-plane   1/1     Running   0          42m
   ```

2. Leé el flag de admission con el que se arrancó el clúster:

   ```bash
   kubectl -n kube-system get pod kube-apiserver-kind-control-plane -o yaml \
     | grep -- '--enable-admission-plugins'
   ```

   ```
     - --enable-admission-plugins=NodeRestriction
   ```

3. Ese flag solo lista lo que está habilitado **además** de los defaults. Preguntale al binario mismo por el conjunto completo por defecto:

   ```bash
   docker exec kind-control-plane kube-apiserver -h 2>/dev/null \
     | grep -A4 -- '--enable-admission-plugins'
   ```

   ```
       --enable-admission-plugins strings
           admission plugins that should be enabled in addition to default
           enabled ones (CertificateApproval, CertificateSigning,
           CertificateSubjectRestriction, DefaultIngressClass,
           DefaultStorageClass, DefaultTolerationSeconds, LimitRanger,
           MutatingAdmissionWebhook, NamespaceLifecycle,
           PersistentVolumeClaimResize, PodSecurity, Priority, ResourceQuota,
           RuntimeClass, ServiceAccount, StorageObjectInUseProtection,
           TaintNodesByCondition, ValidatingAdmissionPolicy,
           ValidatingAdmissionWebhook, ...).
   ```

4. Fijate en los dos plugins de webhook de esa lista —`MutatingAdmissionWebhook` y `ValidatingAdmissionWebhook`—. Estos son los **dispatchers** del admission *dinámico*: sin ellos, los objetos `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration` serían inertes.

> **Comprobación de comprensión 1**
> 1. `--enable-admission-plugins=NodeRestriction` lista un solo plugin, y sin embargo `LimitRanger`, `PodSecurity` y `ResourceQuota` están todos activos. ¿Por qué?
> 2. La documentación del flag dice "*El orden de los plugins en este flag no importa.*" Si el orden del flag es irrelevante, ¿qué determina en realidad el orden en que se ejecutan los controllers —y por qué `MutatingAdmissionWebhook` se ejecuta siempre cerca del **final** de la fase de mutación?
> 3. ¿Por qué se molesta `kubeadm` en agregar `NodeRestriction` explícitamente si los defaults integrados ya se consideran seguros?

---

## Exercise 2 — Un mutating controller integrado vs. un validating controller integrado

**Objetivo:** ver a `LimitRanger` *reescribir* un Pod (mutación) y a `ResourceQuota` *rechazar* uno (validación), y razonar a qué fase pertenece cada uno.

1. Creá un namespace sandbox y un `LimitRange` que inyecta defaults:

   ```bash
   kubectl create namespace adm-lab
   ```

   ```yaml
   # limitrange.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: defaults
     namespace: adm-lab
   spec:
     limits:
       - type: Container
         default:            # becomes spec.containers[].resources.limits
           cpu: "500m"
           memory: "256Mi"
         defaultRequest:     # becomes spec.containers[].resources.requests
           cpu: "100m"
           memory: "128Mi"
   ```

   ```bash
   kubectl apply -f limitrange.yaml
   ```

2. Creá un Pod que no especifica **ningún** recurso:

   ```bash
   kubectl -n adm-lab run web --image=nginx:1.27 --restart=Never
   ```

3. Inspeccioná lo que realmente se almacenó —nunca escribiste estos campos:

   ```bash
   kubectl -n adm-lab get pod web \
     -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   ```

   ```
   {"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
   ```

4. Ahora agregá un tope duro con `ResourceQuota`:

   ```yaml
   # quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tight
     namespace: adm-lab
   spec:
     hard:
       requests.cpu: "150m"     # only 50m left after the running pod's 100m
       requests.memory: "256Mi"
   ```

   ```bash
   kubectl apply -f quota.yaml
   ```

5. Intentá agendar un segundo pod que superaría el presupuesto de CPU request:

   ```bash
   kubectl -n adm-lab run web2 --image=nginx:1.27 --restart=Never \
     --requests='cpu=200m'
   ```

   ```
   Error from server (Forbidden): pods "web2" is forbidden: exceeded quota: tight,
   requested: requests.cpu=200m, used: requests.cpu=100m, limited: requests.cpu=150m
   ```

> **Comprobación de comprensión 2**
> 1. `LimitRanger` y `ResourceQuota` son ambos plugins de admission únicos, y sin embargo uno *cambió* el objeto y el otro lo *bloqueó*. ¿En qué fase de admission actúa cada uno, y por qué `ResourceQuota` no puede ejecutarse **antes** de `LimitRanger`?
> 2. En el paso 5 la quota dice `used: requests.cpu=100m`. ¿De dónde salieron esos 100m, dado que el primer pod se creó **sin** ningún resource request?
> 3. Si borraras el `LimitRange` y recrearas `web`, ¿lo admitiría igual el `ResourceQuota`? Explicá la interacción.

---

## Exercise 3 — Pod Security Admission (el reemplazo integrado de PodSecurityPolicy)

**Objetivo:** hacer cumplir un Pod Security Standard en el límite del namespace usando el controller `PodSecurity`, y usar sus modos no bloqueantes para migrar de forma segura.

1. Creá un namespace y activá los tres modos de PSA en el nivel `restricted`. Fijá la **versión** para que un upgrade del clúster no pueda endurecer las reglas silenciosamente por debajo tuyo:

   ```bash
   kubectl create namespace psa-demo

   kubectl label namespace psa-demo \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31 \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

2. Intentá un Pod deliberadamente no conforme (privileged):

   ```yaml
   # privileged.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: privileged
     namespace: psa-demo
   spec:
     containers:
       - name: app
         image: nginx:1.27
         securityContext:
           privileged: true
   ```

   ```bash
   kubectl apply -f privileged.yaml
   ```

   ```
   Error from server (Forbidden): error when creating "privileged.yaml": pods "privileged" is
   forbidden: violates PodSecurity "restricted:v1.31": privileged (container "app" must not set
   securityContext.privileged=true), allowPrivilegeEscalation != false (container "app" must set
   securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app"
   must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container
   "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must
   set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

3. Corregí el Pod para que satisfaga `restricted`:

   ```yaml
   # compliant.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: compliant
     namespace: psa-demo
   spec:
     securityContext:
       runAsNonRoot: true
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginx:1.27
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   kubectl apply -f compliant.yaml    # pod/compliant created
   ```

4. Previsualizá el impacto de una política más estricta sobre workloads **existentes** *sin cambiar nada*, usando una evaluación de label en dry-run server-side:

   ```bash
   kubectl label --dry-run=server ns kube-system \
     pod-security.kubernetes.io/enforce=restricted
   ```

   ```
   Warning: existing pods in namespace "kube-system" violate the new PodSecurity enforce level
   "restricted:latest": kube-apiserver-... (host namespaces, hostPath volumes, ...)
   namespace/kube-system labeled (server dry run)
   ```

> **Comprobación de comprensión 3**
> 1. PSA rechazó el pod en tiempo de admission. ¿Cuál es la diferencia arquitectónica fundamental entre esto y hacer cumplir las mismas reglas con un `ValidatingWebhook` que corre un motor de políticas como OPA/Gatekeeper o Kyverno?
> 2. ¿Cuál es el propósito práctico de migración de correr `warn` y `audit` en `restricted` mientras `enforce` permanece en `baseline` (o sin fijar)?
> 3. ¿Por qué `enforce-version=v1.31` es un label crítico en producción, y dónde afloran realmente los mensajes de `warn`/`audit` para cada uno de los dos modos?

---

## Exercise 4 — Política in-tree con CEL: `ValidatingAdmissionPolicy`

**Objetivo:** hacer cumplir una regla personalizada **sin desplegar un servidor de webhook**, usando evaluación CEL compilada (GA desde v1.30). Vamos a limitar las réplicas de un Deployment.

1. Definí la política —*qué* comprobar:

   ```yaml
   # vap.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: "replica-limit.example.com"
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   ["apps"]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["deployments"]
     validations:
       - expression: "object.spec.replicas <= 5"
         message: "Deployment replicas must be 5 or fewer."
         reason: Invalid
   ```

2. Definí el binding —*dónde* se aplica la política. Delimitalo a los namespaces con label `team=payments`:

   ```yaml
   # vapb.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: "replica-limit-binding"
   spec:
     policyName: "replica-limit.example.com"
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           team: payments
   ```

3. Aplicá ambos y etiquetá un namespace de destino:

   ```bash
   kubectl apply -f vap.yaml -f vapb.yaml
   kubectl create namespace payments
   kubectl label namespace payments team=payments
   ```

4. Un Deployment conforme es admitido:

   ```bash
   kubectl -n payments create deployment ok --image=nginx:1.27 --replicas=3
   ```

   ```
   deployment.apps/ok created
   ```

5. Un Deployment que viola la regla es rechazado —por el API server mismo, sin salto de red:

   ```bash
   kubectl -n payments create deployment toobig --image=nginx:1.27 --replicas=8
   ```

   ```
   error: failed to create deployment: deployments.apps "toobig" is forbidden:
   ValidatingAdmissionPolicy 'replica-limit.example.com' with binding
   'replica-limit-binding' denied request: Deployment replicas must be 5 or fewer.
   ```

6. Confirmá que el alcance es realmente el label, no el clúster: el mismo Deployment sobredimensionado en `default` tiene éxito porque a ese namespace le falta `team=payments`.

   ```bash
   kubectl -n default create deployment toobig --image=nginx:1.27 --replicas=8
   ```

   ```
   deployment.apps/toobig created
   ```

> **Comprobación de comprensión 4**
> 1. Nombrá dos ventajas operativas de una `ValidatingAdmissionPolicy` sobre una `ValidatingWebhookConfiguration` equivalente, y una cosa que un webhook puede hacer y una VAP fundamentalmente no.
> 2. En la expresión CEL, ¿por qué `object.spec.replicas <= 5` es riesgoso si el campo puede omitirse, y cómo lo harías null-safe? (Pista: `object.spec.replicas` cuando no está fijado.)
> 3. La política y el binding son dos objetos separados. ¿Qué flujo de trabajo del mundo real habilita esa división entre `ValidatingAdmissionPolicy` y `ValidatingAdmissionPolicyBinding`?

---

## Exercise 5 — Admission dinámico y el trade-off de `failurePolicy`

**Objetivo:** entender el riesgo de disponibilidad de los webhooks externos haciendo que uno **falle cerrado** (fail closed), y luego **falle abierto** (fail open), *sin nunca correr un servidor de webhook*. Un webhook inalcanzable es toda la demostración.

1. Registrá un validating webhook que apunta a un service que **no existe**, delimitado por label para que no pueda tocar el resto del clúster:

   ```yaml
   # webhook.yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingWebhookConfiguration
   metadata:
     name: deny-when-down.example.com
   webhooks:
     - name: deny-when-down.example.com
       admissionReviewVersions: ["v1"]
       sideEffects: None
       failurePolicy: Fail          # fail CLOSED
       timeoutSeconds: 5
       namespaceSelector:
         matchLabels:
           webhook-demo: "true"
       clientConfig:
         service:
           name: nonexistent-webhook
           namespace: default
           path: /validate
           port: 443
       rules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE"]
           resources:   ["pods"]
           scope: "Namespaced"
   ```

   ```bash
   kubectl apply -f webhook.yaml
   kubectl create namespace webhook-demo
   kubectl label namespace webhook-demo webhook-demo=true
   ```

2. Intentá crear un Pod en el namespace delimitado. El API server intenta llamar al webhook, no puede alcanzarlo y —por `failurePolicy: Fail`— rechaza la request:

   ```bash
   kubectl -n webhook-demo run p --image=nginx:1.27 --restart=Never
   ```

   ```
   Error from server (InternalError): Internal error occurred: failed calling webhook
   "deny-when-down.example.com": failed to call webhook: Post
   "https://nonexistent-webhook.default.svc:443/validate?timeout=5s": service
   "nonexistent-webhook" not found
   ```

3. Comprobá que el radio de impacto está contenido por el `namespaceSelector` —el *mismo* Pod en `default` (sin el label `webhook-demo=true`) se crea con normalidad:

   ```bash
   kubectl -n default run p --image=nginx:1.27 --restart=Never   # pod/p created
   ```

4. Ahora cambiá la política a **fail open** y reintentá en el namespace delimitado:

   ```bash
   kubectl patch validatingwebhookconfiguration deny-when-down.example.com \
     --type='json' \
     -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

   kubectl -n webhook-demo run p --image=nginx:1.27 --restart=Never
   ```

   ```
   pod/p created
   ```

   El webhook sigue siendo inalcanzable —pero `failurePolicy: Ignore` le dice al API server que admita la request cuando la llamada falla.

5. **Limpiá todo lo de los cinco ejercicios:**

   ```bash
   kubectl delete validatingwebhookconfiguration deny-when-down.example.com
   kubectl delete validatingadmissionpolicybinding replica-limit-binding
   kubectl delete validatingadmissionpolicy replica-limit.example.com
   kubectl delete namespace adm-lab psa-demo payments webhook-demo
   kubectl -n default delete pod p toobig --ignore-not-found
   kubectl -n default delete deployment toobig --ignore-not-found
   ```

> **Comprobación de comprensión 5**
> 1. Enunciá el trade-off de seguridad en una oración: ¿qué protege `failurePolicy: Fail`, y qué pone en peligro?
> 2. ¿Por qué es peligroso escribir un webhook cuyas `rules` matchean `pods` **y** cuyo `namespaceSelector` también matchea `kube-system` con `failurePolicy: Fail`? ¿Cuál es la mitigación estándar?
> 3. Este webhook declara `sideEffects: None`. ¿Qué significa ese campo, y por qué el API server necesita conocerlo para que `kubectl ... --dry-run=server` se comporte correctamente?
> 4. Orden: si este namespace *también* tuviera un `LimitRange`, un `ResourceQuota`, enforcement de PSA **y** este webhook, ¿en qué orden se evalúan —y puede este validating webhook llegar a ver campos inyectados por `LimitRanger`?

---

## Respuestas

<details>
<summary><strong>Mostrar respuestas de todas las comprobaciones de comprensión</strong></summary>

### Exercise 1
1. **El conjunto habilitado por defecto está compilado dentro del binario `kube-apiserver` y está activo salvo que se lo deshabilite explícitamente.** `--enable-admission-plugins` agrega plugins *extra* sobre ese conjunto por defecto; no lo reemplaza. Así que `LimitRanger`, `PodSecurity`, `ResourceQuota`, etc. están activos porque están en los defaults integrados, mientras que `NodeRestriction` es el único plugin no-default por el que `kubeadm` opta. Para apagar un default usarías `--disable-admission-plugins`.
2. El orden lo fija el **orden de registro de plugins compilado en el código fuente del API server**, no el orden del flag de CLI. Dentro de cada fase los controllers corren en esa secuencia fija. `MutatingAdmissionWebhook` se ubica cerca del final de la fase de mutación deliberadamente: los mutadores integrados (defaults, inyección de token de ServiceAccount, etc.) corren primero, de modo que los webhooks externos observen un objeto que ya tiene los defaults in-tree aplicados, y puedan sobrescribirlos al final. (`ValidatingAdmissionWebhook` es igualmente el último en la fase de validación.)
3. `NodeRestriction` limita lo que las **credenciales propias del kubelet** pueden modificar —un kubelet solo puede editar su *propio* objeto Node y solo los Pods vinculados a él. *No* está en el conjunto por defecto, así que `kubeadm` lo agrega explícitamente para amortiguar una ruta de escalamiento de nodo-comprometido → clúster-completo. Se combina con el modo de autorización `Node`.

### Exercise 2
1. `LimitRanger` actúa en la fase de **mutación** (inyecta `default`/`defaultRequest` en los containers que omiten recursos). `ResourceQuota` actúa en la fase de **validación** (solo acepta o rechaza; nunca edita). `ResourceQuota` *debe* correr después de `LimitRanger` porque necesita contabilizar los resource requests **finales** —incluyendo los que `LimitRanger` acaba de inyectar. Invertirlos dejaría que un pod que termina solicitando 100m se cuele por una quota que vio 0m.
2. Los 100m vinieron de `LimitRanger`. El primer pod `web` se creó sin recursos, pero `LimitRanger` lo mutó a `requests.cpu=100m` (desde `defaultRequest`). `ResourceQuota` entonces contó ese valor inyectado —que es exactamente por qué los dos controllers deben correr en ese orden.
3. Sin el `LimitRange`, `web` se almacenaría con **ningún** CPU request. Notá que una vez que un `ResourceQuota` restringe `requests.cpu`, el quota controller *exige* que cada pod del namespace declare ese recurso —un pod sin request sería a su vez rechazado ("must specify requests.cpu"). Así que quitar el `LimitRange` no solo cambia la contabilidad; puede hacer que pods antes válidos fallen en admission, porque `LimitRanger` estaba silenciosamente proveyendo el valor obligatorio.

### Exercise 3
1. PSA es un controller **integrado, in-process**: las comprobaciones están compiladas en el API server, se activan según los labels del namespace, sin llamada de red externa y sin componente extra que mantener en alta disponibilidad. OPA/Gatekeeper y Kyverno son deployments de `ValidatingWebhook` **dinámicos**: lógica de política arbitraria, lookups cross-object y mutación —pero al costo de correr (y asegurar, y mantener al día) un servidor de webhook externo que queda en el camino crítico de cada request que matchee. PSA está fijo a los tres Pod Security Standards; los motores de webhook son de propósito general.
2. `warn` muestra un mensaje al cliente interactivo (p. ej. `kubectl`) y `audit` escribe una anotación en el audit log —**ninguno bloquea la request.** Correrlos en `restricted` mientras `enforce` permanece permisivo te permite descubrir *qué workloads existentes se romperían* antes de cambiar `enforce`, convirtiendo un cambio big-bang riesgoso en una migración observable y escalonada.
3. `enforce-version` fija el conjunto de reglas a una versión minor específica de Kubernetes. Sin él (`latest`), un upgrade del clúster puede agregar silenciosamente nuevas restricciones al perfil `restricted` y empezar a rechazar workloads que antes pasaban —un cambio que no autoraste. Fijarlo hace del drift de políticas un acto explícito y revisado. Dónde afloran: los mensajes de `warn` aparecen como líneas `Warning:` en el cliente (el usuario que crea el objeto); los mensajes de `audit` aparecen solo como anotaciones en el **audit log** del API server.

### Exercise 4
1. **Ventajas de VAP:** (a) ningún componente extra que desplegar, asegurar, rotar certificados o mantener en alta disponibilidad —la lógica corre in-process; (b) latencia mucho menor y sin riesgo de disponibilidad, así que sin el footgun de `failurePolicy`/timeout. **Lo que solo un webhook puede hacer:** correr código arbitrario, realizar I/O / lookups externos y (como webhook *mutating*) modificar el objeto —las políticas CEL son puras, sin efectos secundarios, y solo de validación (las mutating admission policies existían solo como alpha a fecha de v1.32).
2. Si `spec.replicas` se omite, `object.spec.replicas` no está fijado; evaluar `<= 5` contra un campo ausente levanta un error de runtime de CEL, y con `failurePolicy: Fail` ese error *rechaza* la request —posiblemente rechazando Deployments válidos. Hacelo null-safe, p. ej. `!has(object.spec.replicas) || object.spec.replicas <= 5` (tratar "sin fijar" —que por defecto es 1— como conforme).
3. La división separa la **definición de la política** de la **aplicación/alcance de la política**. Un equipo de plataforma autora una `ValidatingAdmissionPolicy` (la regla + CEL); muchos `ValidatingAdmissionPolicyBinding`s luego la vinculan a distintos namespaces/label-selectors, cada uno con su propio `validationActions` (`Deny`, `Warn`, `Audit`) y `params` opcionales. Eso te permite hacer dry-run de una política en modo `Warn`/`Audit` vía un binding, o aplicar una regla a distintos tenants con distintos parámetros, sin tocar la política misma.

### Exercise 5
1. `failurePolicy: Fail` **protege el invariante** que el webhook hace cumplir (nada pasa sin comprobar cuando el webhook está caído) al costo de **poner en peligro la disponibilidad** (un webhook inalcanzable detiene todas las escrituras que matcheen en todo el clúster). `Ignore` invierte el trade-off: las escrituras siguen fluyendo, pero la política se saltea silenciosamente mientras el webhook está caído.
2. Muchos componentes del control-plane y add-ons viven en `kube-system`. Un webhook fail-closed que matchee sus Pods, en el momento en que el servidor de webhook no esté disponible, bloqueará al API server de (re)crear esos Pods de sistema —una interrupción autoinfligida y autosostenida que puede impedir que el webhook mismo se recupere. Mitigaciones estándar: **excluir los namespaces del control-plane** con un `namespaceSelector` (p. ej. `NotIn` un label `control-plane` / `kubernetes.io/metadata.name`), delimitar las `rules` lo más estrechamente posible, mantener `timeoutSeconds` bajo, y reservar `failurePolicy: Fail` para comprobaciones estrechamente delimitadas y críticas para el negocio.
3. `sideEffects` declara si llamar al webhook muta algún estado **fuera** de la admission request (p. ej. escribir en un sistema externo). `None` significa que está libre de efectos secundarios. El API server lo necesita porque durante `--dry-run=server` debe garantizar que nada cambie realmente: **solo llamará** a webhooks declarados `None` (o `NoneOnDryRun`) durante un dry run, y saltea los que declaran `Some`.
4. Orden de evaluación en el namespace que matchea: **fase de mutación** —mutadores integrados incluyendo `LimitRanger` (inyectar defaults), luego `MutatingAdmissionWebhook`; luego **validación de schema**; luego **fase de validación** —validadores integrados incluyendo `PodSecurity` y `ResourceQuota`, luego `ValidatingAdmissionPolicy`, luego `ValidatingAdmissionWebhook` (este webhook) al final. Sí —porque este validating webhook corre *después* de toda la fase de mutación, ve el objeto con los `requests`/`limits` inyectados por `LimitRanger` ya presentes.

</details>

---

**Fuentes**

- Admission Controllers Reference — <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>
- Dynamic Admission Control (webhooks) — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- Validating Admission Policy (CEL) — <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>
- Pod Security Admission — <https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- Pod Security Standards — <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Resource Quotas — <https://kubernetes.io/docs/concepts/policy/resource-quotas/> · Limit Ranges — <https://kubernetes.io/docs/concepts/policy/limit-range/>