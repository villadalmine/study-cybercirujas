# Tema 5.9 — Reglas de Autogeneración (Autogen)

**Ejercicios guiados — Kyverno Certified Associate (KCA), Dominio 5**

> Autogen es el mecanismo por el cual Kyverno toma una regla que escribiste para `Pod` y deriva silenciosamente reglas equivalentes para los controladores de workload que *producen* Pods. Es la única funcionalidad que decide si una violación de política aparece en `kubectl apply -f deployment.yaml` (bien) o tres niveles más abajo, en un bucle de eventos de ReplicaSet que nadie está mirando (mal). Estos ejercicios hacen visible esa derivación, y después te la ponen bajo control.
>
> Toda la salida de CLI que sigue es **representativa**: los nombres, los hashes y la lista exacta de controladores varían según la versión de Kyverno. Donde una diferencia de versión importa, el ejercicio te pide leer el valor de *tu* clúster en vez de confiar en la página.

---

## Bloque 0 — Preparación del laboratorio

**Objetivo:** un clúster con Kyverno instalado en modo control de admisión, más la CLI `kyverno`.

1. Creá un clúster descartable.

   ```bash
   kind create cluster --name autogen-lab
   kubectl config use-context kind-autogen-lab
   ```

2. Instalá Kyverno (Helm, admission controller + background controller + reports controller).

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --wait
   ```

3. Registrá la versión exacta que estás ejecutando. Cada afirmación de este tema es sensible a la versión.

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   ghcr.io/kyverno/kyverno:v1.13.4
   ```

4. Instalá la CLI y confirmá que coincide con la versión menor del clúster.

   ```bash
   kyverno version
   ```

   ```
   Version: 1.13.4
   Time: 2025-01-28T10:14:22Z
   Git commit ID: 0e9a2f1
   ```

5. Creá el namespace de trabajo.

   ```bash
   kubectl create namespace autogen-lab
   ```

6. Confirmá la superficie de API que Kyverno registró *antes* de que agregues cualquier política. Vas a comparar contra esto más adelante.

   ```bash
   kubectl get validatingwebhookconfiguration | grep kyverno
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules}{"\n"}{end}'
   ```

   En una instalación nueva y sin políticas, el webhook de recursos no tiene **ninguna regla** — Kyverno construye la superficie de match dinámicamente a partir de las políticas que instalás.

**Preguntas — Bloque 0**

- **Q0.1** El webhook de recursos de Kyverno arranca con una lista de reglas vacía. ¿Qué propiedad operativa te da eso que un `ValidatingWebhookConfiguration` definido estáticamente (el clásico atrapa-todo `*` de OPA Gatekeeper) no te da?
- **Q0.2** ¿Por qué importa la versión de la CLI específicamente en un tema sobre autogen? Nombrá el artefacto concreto que sería distinto.

---

## Bloque 1 — Hacer visible el autogen

**Objetivo:** demostrar que Kyverno guarda las reglas derivadas separadas de las reglas que vos escribiste.

1. Escribí una política de validación con alcance de Pod. Fijate que `kinds` contiene **solamente** `Pod`.

   ```yaml
   # 01-require-nonroot.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-run-as-nonroot
   spec:
     validationFailureAction: Enforce   # Kyverno >= 1.13: prefer per-rule validate.failureAction
     background: true
     rules:
       - name: check-runasnonroot
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: >-
             Every container must set securityContext.runAsNonRoot=true.
           pattern:
             spec:
               containers:
                 - securityContext:
                     runAsNonRoot: true
   ```

2. Aplicala y esperá a que quede lista.

   ```bash
   kubectl apply -f 01-require-nonroot.yaml
   kubectl get cpol require-run-as-nonroot
   ```

   ```
   NAME                     ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
   require-run-as-nonroot   true        true         Enforce           True    4s
   ```

3. Confirmá que la spec que escribiste está **sin modificar** — Kyverno no reescribió lo que vos escribiste.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.spec.rules[*].name}{"\n"}'
   ```

   ```
   check-runasnonroot
   ```

4. Ahora leé las reglas derivadas desde `status`.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}' \
     | tr ' ' '\n'
   ```

   ```
   autogen-check-runasnonroot
   autogen-cronjob-check-runasnonroot
   ```

5. Leé la anotación que Kyverno le agregó a la política.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.metadata.annotations}{"\n"}' | jq .
   ```

   ```json
   {
     "pod-policies.kyverno.io/autogen-controllers": "DaemonSet,Deployment,Job,StatefulSet,ReplicaSet,ReplicationController,CronJob"
   }
   ```

6. Leé los *kinds* que hace match cada regla derivada, en tu clúster.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0].match.any[0].resources.kinds}{"\n"}'
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[1].match.any[0].resources.kinds}{"\n"}'
   ```

**Preguntas — Bloque 1**

- **Q1.1** Escribiste una regla. Kyverno derivó **dos**, no seis o siete — una por cada controlador de pods. ¿Qué propiedad estructural de la API de Kubernetes agrupa a los controladores en exactamente dos categorías?
- **Q1.2** Las reglas derivadas viven bajo `.status`, no bajo `.spec`. Enunciá dos consecuencias operativas concretas de esa decisión de diseño — una para GitOps, otra para la autoría de políticas.
- **Q1.3** Anotá la lista exacta de kinds que produjo tu clúster en el paso 6. ¿Incluye `ReplicaSet` y `ReplicationController`? ¿Por qué una release de Kyverno sacaría deliberadamente esos dos del conjunto por defecto?
- **Q1.4** Tu regla se llama `check-runasnonroot` (18 caracteres). Kyverno impone un límite de 63 caracteres a los nombres de regla. ¿Cuál es el largo máximo práctico para un nombre de regla escrito por un autor en una política que va a pasar por autogen, y por qué?

---

## Bloque 2 — Leer la reescritura de rutas

**Objetivo:** entender *qué* transforma realmente el autogen. No es "copiar la regla y cambiar el kind" — es una reubicación de ruta JSON de todo el cuerpo de la regla.

1. Volcá la primera regla derivada completa.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0]}' | yq -P
   ```

   ```yaml
   name: autogen-check-runasnonroot
   match:
     any:
       - resources:
           kinds:
             - DaemonSet
             - Deployment
             - Job
             - StatefulSet
             - ReplicaSet
             - ReplicationController
           namespaces:
             - autogen-lab
   validate:
     message: Every container must set securityContext.runAsNonRoot=true.
     pattern:
       spec:
         template:
           spec:
             containers:
               - securityContext:
                   runAsNonRoot: true
   ```

2. Volcá la regla de CronJob.

   ```bash
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[1]}' | yq -P
   ```

   ```yaml
   name: autogen-cronjob-check-runasnonroot
   match:
     any:
       - resources:
           kinds:
             - CronJob
           namespaces:
             - autogen-lab
   validate:
     message: Every container must set securityContext.runAsNonRoot=true.
     pattern:
       spec:
         jobTemplate:
           spec:
             template:
               spec:
                 containers:
                   - securityContext:
                       runAsNonRoot: true
   ```

3. Compará mentalmente los dos bloques `pattern`, y después confirmá el prefijo que insertó cada uno:

   ```bash
   diff \
     <(kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[0].validate.pattern}' | yq -P) \
     <(kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[1].validate.pattern}' | yq -P)
   ```

4. Prestá atención a lo que **no** fue reescrito: el `message`, el selector de `namespaces`, y la semántica del alcance del `match` de la regla.

**Preguntas — Bloque 2**

- **Q2.1** Enunciá el prefijo de ruta exacto que inserta el autogen para (a) la regla de controlador estándar y (b) la regla de CronJob.
- **Q2.2** La cadena `message` se copia textualmente. Un estudiante escribe `message: "Pod must set runAsNonRoot"`. ¿Qué va a ver un platform engineer cuando su Deployment sea rechazado, y por qué ese mensaje ahora es activamente engañoso? Reescribilo correctamente.
- **Q2.3** El cuerpo de una regla contiene la variable `{{ request.object.spec.containers[0].image }}`. ¿Qué tiene que hacer el autogen con esa expresión en la regla de Deployment derivada para que la política siga siendo correcta?
- **Q2.4** `namespaces: [autogen-lab]` se copió sin cambios a las dos reglas derivadas. Explicá por qué copiarlo sin cambios es correcto acá, y nombrá un campo de `match` donde una copia textual ingenua *sí* estaría mal.

---

## Bloque 3 — Demostrar dónde ocurre la aplicación

**Objetivo:** observar la diferencia entre un clúster con autogen y uno sin él, en el punto de la experiencia del usuario.

1. Creá un Deployment que viole la política.

   ```yaml
   # 02-bad-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: autogen-lab
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
           - name: nginx
             image: nginx:1.27-alpine
             ports:
               - containerPort: 8080
   ```

   ```bash
   kubectl apply -f 02-bad-deploy.yaml
   ```

   ```
   Error from server: error when creating "02-bad-deploy.yaml": admission webhook
   "validate.kyverno.svc-fail" denied the request:

   resource Deployment/autogen-lab/web was blocked due to the following policies

   require-run-as-nonroot:
     autogen-check-runasnonroot: 'validation error: Every container must set
       securityContext.runAsNonRoot=true. rule autogen-check-runasnonroot failed at
       path /spec/template/spec/containers/0/securityContext/'
   ```

2. Leé el nombre de la regla en el mensaje de rechazo. Fijate que es el nombre **derivado**, y fijate en la ruta del fallo.

3. Ahora desactivá el autogen para esta política y repetí, para ver el contrafáctico.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen}{"\n"}'
   ```

   ```
   {}
   ```

4. Aplicá de nuevo el mismo Deployment.

   ```bash
   kubectl apply -f 02-bad-deploy.yaml
   kubectl -n autogen-lab get deploy,rs,pod
   ```

   ```
   deployment.apps/web created

   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   0/1     0            0           12s

   NAME                             DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-6d4c8f7b9    1         0         0       12s
   ```

5. Encontrá dónde apareció realmente el fallo.

   ```bash
   kubectl -n autogen-lab describe rs web-6d4c8f7b9 | tail -n 8
   ```

   ```
   Events:
     Type     Reason        Age                From                   Message
     ----     ------        ----               ----                   -------
     Warning  FailedCreate  8s (x4 over 12s)   replicaset-controller  Error creating: admission
       webhook "validate.kyverno.svc-fail" denied the request: resource Pod/autogen-lab/web-6d4c8f7b9-xk2vp
       was blocked due to the following policies

       require-run-as-nonroot:
         check-runasnonroot: 'validation error: Every container must set
           securityContext.runAsNonRoot=true.'
   ```

6. Limpiá y restaurá el autogen.

   ```bash
   kubectl -n autogen-lab delete deploy web
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers- --overwrite
   ```

**Preguntas — Bloque 3**

- **Q3.1** En el paso 4, `kubectl apply` devolvió código de salida 0 e imprimió `deployment.apps/web created`. ¿Se está aplicando la política? Justificá con precisión.
- **Q3.2** El controlador de ReplicaSet reintentó (`x4 over 12s`). Describí qué te cuesta ese bucle a lo largo de horas en un clúster con decenas de Deployments así, en términos de carga sobre el API server y backoff del controller-manager.
- **Q3.3** ¿Cuál de los dos comportamientos es más seguro desde el punto de vista de *seguridad*, y cuál desde el punto de vista de *operabilidad*? ¿Son la misma respuesta?
- **Q3.4** Un pipeline de CI corre `kubectl apply --dry-run=server -f deployment.yaml` como control de calidad. Explicá qué detecta ese control con el autogen activado, y qué detecta con el autogen desactivado.

---

## Bloque 4 — Controlar el conjunto de controladores

**Objetivo:** acotar el autogen deliberadamente, y ver el efecto de segundo orden sobre el webhook de admisión.

1. Restringí la política a dos controladores.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=Deployment,StatefulSet --overwrite
   ```

2. Volvé a leer las reglas derivadas.

   ```bash
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.status.autogen.rules[0].match.any[0].resources.kinds}'; echo
   ```

   ```
   autogen-check-runasnonroot
   ["Deployment","StatefulSet"]
   ```

3. Observá que la regla de CronJob desapareció.

4. Inspeccioná la superficie de match del webhook ahora que existen políticas.

   ```bash
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\n"}{range .rules[*]}  {.apiGroups}{" "}{.resources}{"\n"}{end}{end}'
   ```

   ```
   validate.kyverno.svc-fail
     ["apps"] ["deployments","statefulsets"]
     [""] ["pods"]
   ```

5. Aplicá un CronJob que viole la política y confirmá que ahora es aceptado a nivel de CronJob.

   ```yaml
   # 03-bad-cronjob.yaml
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: report
     namespace: autogen-lab
   spec:
     schedule: "*/5 * * * *"
     jobTemplate:
       spec:
         template:
           spec:
             restartPolicy: OnFailure
             containers:
               - name: report
                 image: busybox:1.36
                 command: ["sh", "-c", "echo run"]
   ```

   ```bash
   kubectl apply -f 03-bad-cronjob.yaml
   ```

   ```
   cronjob.batch/report created
   ```

6. Restaurá el valor por defecto y verificá que vuelve la regla de CronJob.

   ```bash
   kubectl delete -f 03-bad-cronjob.yaml
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers- --overwrite
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen.rules[*].name}'; echo
   ```

**Preguntas — Bloque 4**

- **Q4.1** En el paso 4 el webhook intercepta `deployments` y `statefulsets` pero no `jobs` ni `cronjobs`. Trazá la cadena causal desde la anotación hasta esa lista de reglas del webhook. ¿Qué opción de configuración de Kyverno hace que esto sea dinámico?
- **Q4.2** Manejás un clúster donde Argo CD crea miles de Jobs por hora. Argumentá a favor y en contra de sacar `Job` del conjunto de controladores de autogen para una política de alto tráfico. ¿Qué perdés?
- **Q4.3** El CronJob del paso 5 fue aceptado. ¿Van a correr sus Pods cinco minutos después? ¿Dónde exactamente aparecería el rechazo?
- **Q4.4** Poner la anotación en `none` y ponerla en cadena vacía no son la misma cosa para un parser de YAML. ¿Qué escribirías realmente en Git para desactivar el autogen, y cómo verificarías en CI que sigue desactivado?

---

## Bloque 5 — La trampa de los metadatos

**Objetivo:** el bug de autogen de mayor frecuencia en suites de políticas en producción.

1. Escribí una política que exige una etiqueta, contra Pods.

   ```yaml
   # 04-require-team-label.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: check-team-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: "The label 'team' is required."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 04-require-team-label.yaml
   ```

2. Predecí el pattern derivado antes de mirarlo. Escribí tu predicción, y después verificá.

   ```bash
   kubectl get cpol require-team-label \
     -o jsonpath='{.status.autogen.rules[0].validate.pattern}' | yq -P
   ```

   ```yaml
   spec:
     template:
       metadata:
         labels:
           team: "?*"
   ```

3. Aplicá un Deployment que lleva la etiqueta en el **objeto Deployment** pero no en el pod template.

   ```yaml
   # 05-label-on-wrong-object.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: api
     namespace: autogen-lab
     labels:
       team: platform
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
             image: nginx:1.27-alpine
             securityContext:
               runAsNonRoot: true
   ```

   ```bash
   kubectl apply -f 05-label-on-wrong-object.yaml
   ```

   ```
   Error from server: error when creating "05-label-on-wrong-object.yaml": admission webhook
   "validate.kyverno.svc-fail" denied the request:

   resource Deployment/autogen-lab/api was blocked due to the following policies

   require-team-label:
     autogen-check-team-label: 'validation error: The label ''team'' is required.
       rule autogen-check-team-label failed at path /spec/template/metadata/labels/team/'
   ```

4. Arreglalo moviendo la etiqueta a `spec.template.metadata.labels` y volvé a aplicar.

5. Ahora escribí la política que el equipo de plataforma realmente quería — etiquetas en **ambos**, el controlador y el Pod — como dos reglas separadas.

   ```yaml
   # 06-require-team-label-both.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-team-label-both
     annotations:
       pod-policies.kyverno.io/autogen-controllers: none
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: pod-template-label
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         validate:
           message: "Pods must carry the label 'team'."
           pattern:
             metadata:
               labels:
                 team: "?*"
       - name: controller-object-label
         match:
           any:
             - resources:
                 kinds:
                   - Deployment
                   - StatefulSet
                   - DaemonSet
                 namespaces:
                   - autogen-lab
         validate:
           message: "Workload controllers must carry the label 'team' on the object itself."
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

**Preguntas — Bloque 5**

- **Q5.1** El autogen reescribió `metadata.labels` a `spec.template.metadata.labels`. Argumentá por qué esa es la transformación *correcta* aunque sorprenda a los autores.
- **Q5.2** En `06-require-team-label-both.yaml` la anotación está en `none`. ¿Qué saldría mal si se dejara en el valor por defecto mientras la regla 2 existe tal como está escrita? Sé específico sobre qué objeto se chequea dos veces y contra qué ruta.
- **Q5.3** La regla 2 hace match con controladores explícitamente. ¿Qué le hace eso a la decisión de autogen de Kyverno para *esa regla*, independientemente de la anotación?
- **Q5.4** Una política valida `metadata.ownerReferences` en Pods. Razoná si la regla de Deployment autogenerada puede ser equivalente. ¿Qué te dice esto sobre qué campos de Pod son seguros de autogenerar?

---

## Bloque 6 — Tipos de regla: qué se autogenera y qué no

**Objetivo:** construir la tabla mental. El autogen no es universal entre tipos de regla.

1. Creá una política de mutación usando `patchStrategicMerge`.

   ```yaml
   # 07-mutate-safe-to-evict.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-safe-to-evict
   spec:
     rules:
       - name: annotate-workload
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         mutate:
           patchStrategicMerge:
             metadata:
               annotations:
                 +(cluster-autoscaler.kubernetes.io/safe-to-evict): "true"
   ```

   ```bash
   kubectl apply -f 07-mutate-safe-to-evict.yaml
   kubectl get cpol add-safe-to-evict -o jsonpath='{.status.autogen.rules[*].name}'; echo
   ```

2. Aplicá un Deployment que cumpla e inspeccioná dónde aterrizó la mutación.

   ```yaml
   # 08-good-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: cache
     namespace: autogen-lab
     labels:
       team: platform
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: cache
     template:
       metadata:
         labels:
           app: cache
           team: platform
       spec:
         containers:
           - name: redis
             image: redis:7-alpine
             securityContext:
               runAsNonRoot: true
   ```

   ```bash
   kubectl apply -f 08-good-deploy.yaml
   kubectl -n autogen-lab get deploy cache \
     -o jsonpath='{.spec.template.metadata.annotations}'; echo
   kubectl -n autogen-lab get deploy cache \
     -o jsonpath='{.metadata.annotations}'; echo
   ```

   ```
   {"cluster-autoscaler.kubernetes.io/safe-to-evict":"true"}
   {"deployment.kubernetes.io/revision":"1", ...}
   ```

3. Ahora creá una regla `generate` y verificá su estado de autogen.

   ```yaml
   # 09-generate-netpol.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: default-deny-netpol
   spec:
     rules:
       - name: create-default-deny
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
   kubectl apply -f 09-generate-netpol.yaml
   kubectl get cpol default-deny-netpol -o jsonpath='{.status.autogen}'; echo
   ```

4. Creá una regla de mutación que use `patchesJson6902` en su lugar, y compará.

   ```yaml
   # 10-mutate-json6902.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: json-patch-demo
   spec:
     rules:
       - name: patch-container
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                 namespaces:
                   - autogen-lab
         mutate:
           patchesJson6902: |-
             - op: add
               path: "/metadata/annotations/patched-by"
               value: "kyverno"
   ```

   ```bash
   kubectl apply -f 10-mutate-json6902.yaml
   kubectl get cpol json-patch-demo -o jsonpath='{.status.autogen}'; echo
   ```

5. Registrá tus hallazgos en una tabla:

   | Construcción de regla | ¿Produjo autogen? | Evidencia (comando + salida) |
   |---|---|---|
   | `validate.pattern` | | |
   | `validate.deny` | | |
   | `validate.podSecurity` | | |
   | `mutate.patchStrategicMerge` | | |
   | `mutate.patchesJson6902` | | |
   | `verifyImages` | | |
   | `generate` | | |

   Completá las filas vacías escribiendo una política mínima por construcción y leyendo `.status.autogen`.

**Preguntas — Bloque 6**

- **Q6.1** En el paso 2 la anotación aterrizó en `spec.template.metadata.annotations`, no en las `metadata.annotations` propias del Deployment. ¿Por qué ese es el *único* lugar útil para ella, dado lo que hace `cluster-autoscaler.kubernetes.io/safe-to-evict`?
- **Q6.2** Compará mutar a nivel de Deployment contra mutar solamente el Pod en la admisión del Pod. ¿Cuál causa drift de GitOps, y cuál es visible en `kubectl get deploy -o yaml`? ¿Cuál querés, y cuándo querés la otra?
- **Q6.3** Las reglas `generate` no producen entradas de autogen. Explicá por qué la transformación no está meramente sin implementar, sino que es *semánticamente indefinida* para `generate`.
- **Q6.4** A partir del paso 4, enunciá la regla para los parches JSON y explicá la razón mecánica (pensá en lo que significa un puntero JSON como `/spec/containers/0/image` una vez que el objeto es un Deployment).
- **Q6.5** Tu clúster corre el conjunto de políticas `pod-security-standards` de la biblioteca de políticas de Kyverno, aplicado solo a Pods. Explicá en una oración por qué los Deployments igualmente quedan bloqueados.

---

## Bloque 7 — Cuando Kyverno se niega a autogenerar

**Objetivo:** reconocer las condiciones que suprimen el autogen silenciosamente.

1. Escribí una regla cuyo `match` nombra tanto un Pod como un controlador.

   ```yaml
   # 11-mixed-match.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: mixed-match
   spec:
     validationFailureAction: Audit
     rules:
       - name: check-mixed
         match:
           any:
             - resources:
                 kinds:
                   - Pod
                   - Deployment
                 namespaces:
                   - autogen-lab
         validate:
           message: "demo"
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 11-mixed-match.yaml
   kubectl get cpol mixed-match -o jsonpath='{.status.autogen}'; echo
   ```

2. Escribí una regla que no haga match con ningún Pod.

   ```yaml
   # 12-service-only.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: service-only
   spec:
     validationFailureAction: Audit
     rules:
       - name: check-service
         match:
           any:
             - resources:
                 kinds:
                   - Service
         validate:
           message: "demo"
           pattern:
             metadata:
               labels:
                 team: "?*"
   ```

   ```bash
   kubectl apply -f 12-service-only.yaml
   kubectl get cpol service-only -o jsonpath='{.status.autogen}'; echo
   ```

3. Escribí una política de dos reglas donde solo una tenga alcance de Pod, y contá las reglas derivadas.

   ```bash
   kubectl get cpol <your-policy> \
     -o jsonpath='{range .status.autogen.rules[*]}{.name}{"\n"}{end}'
   ```

4. Para cada uno de los tres casos, registrá: ¿corrió el autogen y —lo crítico— te *avisó* Kyverno?

**Preguntas — Bloque 7**

- **Q7.1** En el paso 1, `mixed-match` no produjo reglas derivadas. Razoná por qué suprimir el autogen acá es el comportamiento por defecto correcto y no un bug. ¿Qué le pasaría a un Deployment si Kyverno hubiera autogenerado igual?
- **Q7.2** El caso 1 es peligroso en una revisión: la política *parece* cubrir Deployments, y de hecho lo hace — pero con el pattern con forma de Pod aplicado al objeto Deployment. ¿Contra qué ruta se chequean las `metadata.labels` de un Deployment en `mixed-match`? ¿Es eso lo que el autor quería decir?
- **Q7.3** Ninguno de estos casos produjo un evento de advertencia ni una política en estado no-listo. Diseñá un chequeo de CI —un comando más una aserción— que detecte "esta política debería haber autogenerado y no lo hizo".
- **Q7.4** Una regla hace match con `Pod` pero con un `exclude` que nombra `Deployment`. Predecí el resultado del autogen y después verificalo en tu clúster.

---

## Bloque 8 — Autogen a través de la CLI de Kyverno

**Objetivo:** probar reglas derivadas offline, en CI, sin clúster. Acá es donde el *nombre* de la regla más importa.

1. Guardá una política y un recurso en disco.

   ```bash
   mkdir -p cli-lab && cd cli-lab
   cp ../01-require-nonroot.yaml policy.yaml
   cp ../02-bad-deploy.yaml resource.yaml
   ```

2. Ejecutá `kyverno apply` contra el Deployment.

   ```bash
   kyverno apply policy.yaml --resource resource.yaml
   ```

   ```
   Loading policies ...
   Loading resources ...
   Applying 1 policy rule(s) to 1 resource(s)...

   policy require-run-as-nonroot -> resource autogen-lab/Deployment/web failed:
   1. autogen-check-runasnonroot: validation error: Every container must set
      securityContext.runAsNonRoot=true. rule autogen-check-runasnonroot failed at path
      /spec/template/spec/containers/0/securityContext/

   pass: 0, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. Fijate en el nombre de la regla en la salida de la CLI. Ahora escribí un manifiesto `Test` — usando deliberadamente primero el nombre de regla **escrito por el autor**, para que veas el modo de fallo.

   ```yaml
   # kyverno-test.yaml
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: autogen-check
   policies:
     - policy.yaml
   resources:
     - resource.yaml
   results:
     - policy: require-run-as-nonroot
       rule: check-runasnonroot        # <-- deliberately wrong for a Deployment
       kind: Deployment
       resources:
         - web
       result: fail
   ```

   ```bash
   kyverno test .
   ```

   ```
   Loading test  ( kyverno-test.yaml ) ...
     Loading values/variables ...
     Loading policies ...
     Loading resources ...
     Applying 1 policy to 1 resource ...
     Checking results ...

   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│
   │ ID │ POLICY                │ RULE             │ RESOURCE                │ RESULT │ REASON │
   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│
   │ 1  │ require-run-as-nonroot│ check-runasnonroot│ apps/v1/Deployment/web │ Fail   │ Not found │
   │────│───────────────────────│──────────────────│─────────────────────────│────────│────────│

   Test Summary: 0 tests passed and 1 tests failed
   ```

4. Corregí el nombre de la regla a `autogen-check-runasnonroot` y volvé a ejecutar hasta que quede en verde.

   ```bash
   kyverno test .
   ```

   ```
   Test Summary: 1 tests passed and 0 tests failed
   ```

5. Agregá un segundo recurso —un CronJob— y un segundo resultado esperado, y lográ que ambos pasen.

   ```yaml
   results:
     - policy: require-run-as-nonroot
       rule: autogen-check-runasnonroot
       kind: Deployment
       resources: [web]
       result: fail
     - policy: require-run-as-nonroot
       rule: autogen-cronjob-check-runasnonroot
       kind: CronJob
       resources: [report]
       result: fail
   ```

**Preguntas — Bloque 8**

- **Q8.1** La CLI `kyverno` no tiene conexión al clúster en el paso 2. ¿De dónde salió la regla derivada? ¿Qué te dice esto sobre si el autogen es una transformación del lado del controlador o del lado de la biblioteca?
- **Q8.2** ¿Por qué `kyverno test` exige el nombre de la regla derivada en vez de aceptar el escrito por el autor? Planteá la respuesta en términos de qué identifica una fila de un policy report.
- **Q8.3** Actualizás Kyverno de 1.12 a 1.14 y tu suite de `kyverno test` se pone en rojo con `Not found` en varias filas, sin ningún cambio de política en Git. Dá la causa más probable y el primer comando que ejecutarías.
- **Q8.4** Escribí el agregado de dos líneas a un job de CI que habría detectado el problema de `mixed-match` del Bloque 7 antes del merge, usando solamente la CLI.

---

## Bloque 9 — Ejercicio de diagnóstico

**Objetivo:** diagnosticar a partir de síntomas, bajo presión de tiempo, tal como lo presentan el examen y un incidente real.

**Síntoma.** Un platform engineer reporta: *"Apliqué mi Deployment, kubectl dijo `created`, pero la app nunca levanta y no hay Pods. El equipo de políticas dice que la política está en `Enforce`."*

1. Reproducí el estado.

   ```bash
   kubectl annotate cpol require-run-as-nonroot \
     pod-policies.kyverno.io/autogen-controllers=none --overwrite
   kubectl apply -f 02-bad-deploy.yaml
   ```

2. Recorré la escalera. Ejecutá cada comando y registrá qué descarta o confirma.

   ```bash
   # a. Is the workload object healthy?
   kubectl -n autogen-lab get deploy web -o wide

   # b. Does a ReplicaSet exist, and is it creating?
   kubectl -n autogen-lab get rs -l app=web

   # c. What is the controller telling you?
   kubectl -n autogen-lab describe rs -l app=web | sed -n '/Events/,$p'

   # d. Which policies are in play, and in what mode?
   kubectl get cpol

   # e. Did the policy derive controller rules?
   kubectl get cpol require-run-as-nonroot -o jsonpath='{.status.autogen}'; echo

   # f. Why not?
   kubectl get cpol require-run-as-nonroot \
     -o jsonpath='{.metadata.annotations}'; echo

   # g. What is the webhook actually intercepting?
   kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{range .rules[*]}{.resources}{"\n"}{end}{end}'

   # h. What does Kyverno itself say?
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50 | grep -i autogen
   ```

3. Aplicá el arreglo y demostralo con un apply que falla y después pasa.

4. Escribí un enunciado de postmortem de dos oraciones: causa raíz y la salvaguarda que previene la recurrencia.

**Preguntas — Bloque 9**

- **Q9.1** ¿Qué comando único de la escalera —de (a) a (h)— es el camino más rápido del síntoma a la causa raíz? Justificá.
- **Q9.2** El comando (d) muestra `VALIDATE ACTION: Enforce` y `READY: True`. Explicá cómo una política puede estar simultáneamente lista, aplicando, y no aplicando sobre el objeto que el usuario envió.
- **Q9.3** El webhook en (g) lista `pods` pero no `deployments`. Enunciá el invariante que conecta la anotación, `.status.autogen` y las reglas del webhook — como una sola oración que podrías poner en un runbook.
- **Q9.4** Proponé una regla de lint para el repositorio de políticas, expresable como un solo pipeline de `kubectl`/`jq` o un solo caso de `kyverno test`, que haga fallar CI cada vez que una política Enforce que hace match con Pod tenga el autogen desactivado sin una excepción documentada.

---

## Bloque 10 — Avanzado: autogen bajo los tipos de política CEL (Kyverno ≥ 1.14)

**Objetivo:** reconocer que el autogen existe en los CRDs más nuevos `ValidatingPolicy` / `ImageValidatingPolicy`, con una superficie distinta y *declarativa*. Saltate este bloque si `kubectl api-resources | grep validatingpolic` no devuelve nada.

1. Verificá si tu clúster sirve el CRD, e inspeccioná el esquema en vez de confiar en cualquier documento.

   ```bash
   kubectl api-resources | grep -i validatingpolic
   kubectl explain validatingpolicies.spec.autogen
   kubectl explain validatingpolicies.status.autogen
   ```

2. Escribí una política CEL con una configuración de autogen explícita.

   ```yaml
   # 13-vpol-nonroot.yaml
   apiVersion: policies.kyverno.io/v1alpha1
   kind: ValidatingPolicy
   metadata:
     name: vpol-require-nonroot
   spec:
     validationActions:
       - Deny
     autogen:
       podControllers:
         controllers:
           - deployments
           - statefulsets
     matchConstraints:
       resourceRules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["pods"]
     validations:
       - expression: >-
           object.spec.containers.all(c,
             has(c.securityContext) &&
             has(c.securityContext.runAsNonRoot) &&
             c.securityContext.runAsNonRoot == true)
         message: "Every container must set securityContext.runAsNonRoot=true."
   ```

   ```bash
   kubectl apply -f 13-vpol-nonroot.yaml
   kubectl get validatingpolicy vpol-require-nonroot -o yaml | yq '.status.autogen'
   ```

3. Compará el artefacto generado contra el `status.autogen.rules` del Bloque 1. Fijate en las diferencias de forma, en la expresión CEL que fue reescrita, y en cómo se declara la lista de controladores.

4. Prestá atención a qué superficie es **declarativa en `spec`** y cuál es **impulsada por anotaciones en `metadata`**.

**Preguntas — Bloque 10**

- **Q10.1** En la política CEL, `object.spec.containers` tiene que convertirse en otra cosa en el chequeo de Deployment derivado. Escribí la expresión que esperás, y después compará con lo que tu clúster realmente produjo.
- **Q10.2** La lista de controladores pasó de una anotación en `metadata` a un campo tipado bajo `spec.autogen.podControllers`. Nombrá dos ventajas concretas del campo tipado para un equipo de plataforma que gestiona cientos de políticas.
- **Q10.3** Los nombres de controlador en la nueva API son plurales en minúscula (`deployments`) en vez de Kinds (`Deployment`). ¿Qué te dice esa elección de nomenclatura sobre en qué capa se expresa ahora el match?
- **Q10.4** Estás migrando una `ClusterPolicy` con `pod-policies.kyverno.io/autogen-controllers: none` a una `ValidatingPolicy`. ¿Cuál es la configuración equivalente, y cómo verificarías la equivalencia en vez de asumirla?

---

## Limpieza

```bash
kubectl delete cpol require-run-as-nonroot require-team-label require-team-label-both \
  add-safe-to-evict default-deny-netpol json-patch-demo mixed-match service-only \
  --ignore-not-found
kubectl delete validatingpolicy vpol-require-nonroot --ignore-not-found
kubectl delete namespace autogen-lab
kind delete cluster --name autogen-lab
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

**Q0.1** Kyverno calcula las `rules` del webhook a partir del conjunto de políticas instaladas (configuración dinámica del webhook, activada por defecto). El costo del control de admisión es por lo tanto proporcional a lo que realmente gobernás: un objeto de la API sin política que le haga match nunca sale del API server para hacer un viaje de ida y vuelta al webhook. Un webhook estático con alcance `*` enruta cada mutación de cada recurso a través del motor de políticas, lo que convierte al controlador de políticas en una dependencia dura de todo el plano de control y en un punto único de latencia y de fallo. La contrapartida es que tu superficie de webhook cambia cada vez que cambia una política — que es exactamente lo que el Bloque 4 explota y lo que el Bloque 9 diagnostica.

**Q0.2** La transformación de autogen está implementada en la biblioteca del motor de Kyverno, que se compila dentro de *ambos*, el controlador y la CLI. Si la CLI es de una versión menor distinta a la del clúster, los nombres de las reglas derivadas, el conjunto de controladores derivado o la reescritura de rutas pueden diferir — así que `kyverno test` puede dar verde contra reglas que el clúster nunca generaría. El artefacto concreto que difiere es la regla derivada (su nombre y su `match.resources.kinds`), y por lo tanto cada entrada `results[].rule` en tus manifiestos `Test`.

### Bloque 1

**Q1.1** Todo controlador de workload en Kubernetes embebe un `PodTemplateSpec`, pero a una de dos profundidades. `Deployment`, `StatefulSet`, `DaemonSet`, `Job`, `ReplicaSet` y `ReplicationController` lo exponen todos en `spec.template`. `CronJob` es la excepción: embebe un `JobTemplateSpec` en `spec.jobTemplate`, que a su vez contiene el `PodTemplateSpec` en `spec.jobTemplate.spec.template`. Por lo tanto el autogen necesita exactamente dos prefijos de ruta, así que emite exactamente dos reglas — una cuyo `match` lista todos los controladores de `spec.template`, y otra dedicada a `CronJob`, distinguida por el prefijo `autogen-cronjob-`.

**Q1.2** *GitOps:* `.status` es un subrecurso propiedad del servidor. Como Kyverno escribe las reglas derivadas ahí en vez de mutar `.spec`, el objeto en el clúster sigue coincidiendo con el objeto en Git — sin drift, sin pelea de reconciliación con Argo CD o Flux, sin ruido en `kubectl diff`. (Esto no siempre fue así: releases más viejas de Kyverno inyectaban las reglas derivadas directamente en `spec.rules`, lo que producía exactamente esa pelea.) *Autoría de políticas:* `.spec` sigue siendo la única fuente de la intención escrita, así que una revisión de código muestra solamente lo que escribió una persona. Las reglas derivadas son un detalle de implementación que podés inspeccionar pero nunca necesitás mantener — y nunca necesitás mantener sincronizado cuando editás el original.

**Q1.3** Lo que sea que haya impreso tu clúster es la respuesta autoritativa para tu versión; tanto `["DaemonSet","Deployment","Job","StatefulSet","ReplicaSet","ReplicationController"]` como una lista más corta sin los dos últimos son plausibles según la release. La razón para sacar `ReplicaSet` y `ReplicationController` del conjunto por defecto: son objetos intermedios creados por el controlador de Deployment, no por usuarios. Validarlos agrega un segundo chequeo de admisión redundante en cada rollout de Deployment (uno sobre el Deployment, uno sobre cada nuevo ReplicaSet), infla la superficie del webhook con recursos de alta rotación y —lo peor— un rechazo en la capa de ReplicaSet produce exactamente el modo de fallo invisible del Bloque 3, ya que ningún humano envió ese objeto. Gobernar el Deployment alcanza, porque el pod template del ReplicaSet se copia de él.

**Q1.4** 63 menos el largo del prefijo más largo. `autogen-cronjob-` tiene 16 caracteres, así que un nombre de regla escrito por el autor debe tener **47 caracteres o menos** para sobrevivir la derivación de CronJob. Un nombre de regla de 50 caracteres va a validar bien por sí solo y después va a fallar —o va a ser omitido silenciosamente— cuando el autogen intente derivar la variante de CronJob. Mantené los nombres de regla cortos y semánticos; esta es una causa real de "la política funciona para Deployments pero no para CronJobs".

### Bloque 2

**Q2.1** (a) `spec.template` — el cuerpo de la regla se reubica bajo `spec.template`, así que un `spec.containers` de nivel Pod se convierte en `spec.template.spec.containers` y un `metadata.labels` de nivel Pod se convierte en `spec.template.metadata.labels`. (b) `spec.jobTemplate.spec.template` — así que esos mismos dos se convierten en `spec.jobTemplate.spec.template.spec.containers` y `spec.jobTemplate.spec.template.metadata.labels`.

**Q2.2** El ingeniero ve `Pod must set runAsNonRoot` mientras intenta crear un **Deployment**, y la ruta del fallo apunta a `/spec/template/spec/containers/0/securityContext/`. El mensaje nombra un objeto que esa persona no envió, así que la reacción natural es "no estoy creando un Pod, esta política se está disparando mal" — y el lugar real del arreglo (el pod template dentro del Deployment) nunca se enuncia. Escribí mensajes que nombren el *campo*, no el *kind*: `message: "Every container must set securityContext.runAsNonRoot=true."` — verdadero ya sea que el objeto sea un Pod, un Deployment o un CronJob. Como regla: nunca nombres un Kind en el mensaje de una regla que va a pasar por autogen.

**Q2.3** Tiene que reescribir la expresión JMESPath/variable de la misma manera en que reescribe el pattern, a `{{ request.object.spec.template.spec.containers[0].image }}` (y a `{{ request.object.spec.jobTemplate.spec.template.spec.containers[0].image }}` en la variante de CronJob). El autogen es una transformación de *todo el cuerpo de la regla* — pattern, condiciones `deny`, precondiciones y referencias a variables — no solo del pattern. Si una referencia a variable queda sin reescribir, resuelve contra la forma equivocada del objeto y evalúa a null, lo que típicamente hace que la regla pase silenciosamente en vez de fallar. Por eso las copias hechas a mano del estilo "escribo yo mismo la regla de Deployment" son más frágiles que el autogen: los humanos se olvidan de las variables.

**Q2.4** `namespaces` es un selector de `match` contra el namespace del *objeto enviado*, y un Deployment vive en el mismo namespace que los Pods que produce — así que el alcance se preserva textualmente. Un campo donde copiar textualmente estaría mal es cualquiera que seleccione por la identidad o la forma propia del objeto en vez de por su ubicación: `match.resources.names` (un Deployment llamado `web` produce Pods llamados `web-<rs>-<pod>`, así que un filtro de nombre a nivel de Pod no se traslada), y `match.resources.selector` sobre etiquetas (las etiquetas propias del Deployment no son las etiquetas del pod template — ver Bloque 5). Los selectores y los filtros de nombre son los lugares donde hay que sospechar; namespace y operations se trasladan sin problemas.

### Bloque 3

**Q3.1** Sí, se está aplicando — pero solo en la frontera de admisión del Pod, que ningún usuario cruza directamente. El objeto Deployment en sí no viola ninguna regla que Kyverno esté vigilando, así que el API server lo admite. La violación se atrapa después, cuando el controlador de ReplicaSet (un componente del sistema, usando su propia service account) envía un Pod. La aplicación es real; lo que se perdió es la *retroalimentación*. Un código de salida 0 de `kubectl apply` no es evidencia de cumplimiento en un clúster sin autogen.

**Q3.2** El controlador de ReplicaSet reintenta la creación del Pod con backoff exponencial, pero nunca se rinde ante un `FailedCreate` de admisión — la cantidad de réplicas deseada queda insatisfecha para siempre. Cada intento es un camino de escritura completo del API server más un viaje de ida y vuelta al webhook de Kyverno más una escritura de evento. Decenas de Deployments así producen una carga de fondo permanente de solicitudes `CREATE pods` rechazadas y rotación de eventos, todo invisible sobre el objeto Deployment en sí. El backoff limita la tasa pero nunca la termina; estás pagando para que una decisión de política se relitigue indefinidamente. Peor: los eventos vencen en etcd (TTL por defecto 1 h), así que un Deployment que estuvo trabado un día muestra un `describe rs` con la sección Events vacía — la única evidencia de la causa raíz expiró.

**Q3.3** Son la misma respuesta acá, lo cual es inusual y vale la pena señalarlo: el autogen activado es mejor en ambos ejes. En términos de seguridad los dos son equivalentes en la frontera de aplicación (ningún Pod no conforme corre en ninguno de los dos casos), pero el autogen activado es estrictamente mejor para la *legibilidad de la política* — el rechazo es atribuible a una acción humana, que es lo que necesita un rastro de auditoría. En términos de operabilidad el autogen activado es dramáticamente mejor: falla rápido, en el envío, con la ruta ofensora en el error. La contrapartida genuina está en otro lado — el autogen activado significa una superficie de webhook más grande y latencia de admisión sobre más kinds de recursos (Bloque 4), y significa que una caída de Kyverno con `failurePolicy: Fail` bloquea las escrituras de Deployment, no solo las de Pod.

**Q3.4** Con el autogen **activado**, el dry run del lado del servidor envía el Deployment por la cadena de admisión, choca con la regla derivada, y el control falla — el pipeline atrapa la violación antes del merge. Con el autogen **desactivado**, el dry run envía solamente el Deployment, que pasa, y el control queda en verde; la violación aparece en producción como un Deployment que nunca escala. Un dry run del lado del servidor solo puede probar el objeto que enviás, así que su cobertura es exactamente el conjunto de kinds que tus políticas interceptan. Este es el argumento práctico más fuerte a favor del autogen: es lo que hace que el testeo de admisión "shift-left" sea significativo para workloads.

### Bloque 4

**Q4.1** La anotación restringe para qué kinds de controlador el autogen deriva reglas. El controlador de políticas de Kyverno re-deriva `.status.autogen.rules` a partir de `.spec.rules` más la anotación. Un reconciliador aparte calcula después la unión de las restricciones de match de cada política instalada —escritas *y* derivadas— y escribe esa unión en las `rules` del `ValidatingWebhookConfiguration`. Como la regla de CronJob ya no existe, `cronjobs` ya no está en la unión, así que el API server deja de reenviarle a Kyverno las solicitudes de admisión de CronJob por completo. La opción que hace que esto sea dinámico es `autoUpdateWebhooks` (valor de Helm / flag del controlador, habilitado por defecto); desactivalo y tenés que mantener las reglas del webhook a mano, momento en el cual acotar la anotación deja de acotar el webhook.

**Q4.2** *A favor de sacar `Job`:* cada creación de Job cuesta actualmente un viaje de ida y vuelta al webhook en el camino crítico de la sincronización de Argo CD, agregando latencia a miles de objetos por hora y acoplando la creación de Jobs a la disponibilidad de Kyverno — con `failurePolicy: Fail`, un reinicio de Kyverno frena todo el pipeline de Jobs. Sacar `Job` de la anotación elimina esa clase de tráfico entera del camino de admisión. *En contra:* perdés la retroalimentación rápida sobre los Jobs — un Job no conforme se admite y después falla al crear el Pod, de la manera invisible del Bloque 3, lo que para un Job significa que nunca corre y la sincronización reporta éxito. También perdés el control de dry-run en CI para Jobs. Lo que *no* perdés es la aplicación: la regla de Pod sigue bloqueando el Pod. La decisión es "dónde quiero que aparezca el error", no "quiero que haya error". En la práctica: mantené `Job` si los Jobs son artefactos escritos por personas en Git; sacalo si son un fan-out generado por máquina.

**Q4.3** No. Cinco minutos después el controlador de CronJob crea un Job, el controlador de Job crea un Pod, y el Pod es rechazado por la regla de Pod, que sigue activa. El rechazo aparece como un evento de advertencia `FailedCreate` sobre el objeto **Job** (`kubectl -n autogen-lab describe job report-<timestamp>`), y el Job registra intentos fallidos de creación de pods. Sobre el CronJob en sí no aparece nada más allá de `LAST SCHEDULE`, y después de que expire el TTL del evento no queda ningún rastro — una tarea programada que dejó de producir salida silenciosamente.

**Q4.4** Escribí `pod-policies.kyverno.io/autogen-controllers: "none"` — entre comillas, como cadena explícita. El `none` sin comillas está bien en YAML 1.2, pero el entrecomillado elimina cualquier ambigüedad con las convenciones de `~`/null y sobrevive al templating por Helm, donde una palabra suelta sin comillas puede ser coercionada. Una cadena vacía *no* es equivalente: no es el centinela que Kyverno busca, y el comportamiento ante un valor no reconocido depende de la versión — no te apoyes en eso. Aserción de CI: `kubectl get cpol <name> -o jsonpath='{.status.autogen}'` debe devolver `{}` o vacío; afirmá sobre `.status`, no sobre la anotación, porque el status es lo que el motor realmente derivó. Afirmar sobre la anotación solo prueba lo que pediste, no lo que pasó.

### Bloque 5

**Q5.1** Porque el *sujeto* de la regla es el Pod, y las etiquetas del Pod se declaran en el pod template del controlador. Las `metadata.labels` propias de un Deployment describen al Deployment; los Pods que crea heredan sus etiquetas de `spec.template.metadata.labels` y de ningún otro lado. Si el autogen mapeara las `metadata.labels` del Pod a las `metadata.labels` del Deployment, la regla derivada haría cumplir una propiedad que no tiene efecto sobre ningún Pod — la política pasaría mientras cada Pod del clúster sigue sin etiquetar. La transformación preserva la *semántica* de la regla escrita (qué Pods cumplen), que es el único invariante correcto; la sorpresa es un síntoma de que los autores piensan en objetos en vez de en el Pod que el objeto produce.

**Q5.2** Con el autogen en su valor por defecto, la regla 1 (con alcance de Pod) derivaría `autogen-pod-template-label`, haciendo match con Deployment/StatefulSet/DaemonSet y chequeando `spec.template.metadata.labels.team`. La regla 2 chequea explícitamente las `metadata.labels.team` de ese mismo Deployment. El Deployment queda ahora evaluado **dos veces por la misma política** contra dos rutas distintas — lo cual es discutiblemente lo que el autor quería, pero se logra por accidente y es frágil: la cobertura de la regla derivada sigue silenciosamente al valor por defecto de la anotación, así que una actualización de Kyverno que cambie el conjunto de controladores por defecto cambia el radio de impacto de la regla 1 sin ningún cambio en Git. Poner `none` hace que los alcances de ambas reglas sean explícitos y revisables. (Notá la tensión de diseño: con `none`, la regla 1 ya no atrapa un Deployment cuyo pod template no tiene la etiqueta hasta la admisión del Pod. Si querés ambos chequeos con falla rápida, dejá el autogen activado y sacá el solapamiento de la regla 2, o hacé la regla 2 explícita y aceptá la duplicación a sabiendas.)

**Q5.3** El autogen queda suprimido para esa regla sin importar la anotación, porque la regla ya hace match con controladores de pods directamente. Kyverno no va a derivar reglas de controlador a partir de una regla que nombra controladores — derivar produciría una regla que hace match con los mismos kinds que la original, con una ruta distinta, que es la trampa de doble evaluación en una forma que nadie pidió. Esta es la misma supresión que observás en el Bloque 7. La anotación es entonces un cinturón además de tiradores acá: documenta la intención para quien lee y protege a la regla 1, mientras que la regla 2 se autosuprime.

**Q5.4** No puede ser equivalente, y la regla derivada sería activamente incorrecta. `metadata.ownerReferences` en un Pod lo establece el controlador de ReplicaSet *después* de la admisión del Deployment; el `spec.template.metadata` del Deployment no tiene el campo `ownerReferences` poblado en ningún momento, así que el chequeo derivado evalúa contra una ruta que siempre está ausente. El principio general: **el autogen solo es sólido para campos que el pod template del controlador realmente lleva** — `spec.*` y las `metadata.labels` / `metadata.annotations` del template. Los campos poblados por el API server o por controladores en el momento de creación del Pod (`ownerReferences`, `metadata.name`, `metadata.uid`, `status.*`, `spec.nodeName` por defecto, tokens de service account inyectados) no tienen equivalente en el template. Una política sobre esos campos debe ser solo-Pod, con `autogen-controllers: none` puesto explícitamente y un comentario explicando por qué — de lo contrario, alguien que lea después "arregla" la anotación faltante e introduce una regla que nunca puede hacer match.

### Bloque 6

**Q6.1** `cluster-autoscaler.kubernetes.io/safe-to-evict` la lee el cluster autoscaler desde el objeto **Pod** al decidir si un nodo puede drenarse y eliminarse. Una anotación sobre el objeto Deployment nunca es consultada por el autoscaler y no tendría ningún efecto. La única manera de que la anotación llegue al Pod es que esté presente en el pod template, que es precisamente donde la puso el autogen — y como está en el template, cada Pod futuro creado por ese Deployment la hereda, incluidos los Pods creados después de un rollout o de un fallo de nodo. Mutar solamente el Pod en la admisión del Pod también funcionaría, pero tendría que ocurrir en cada creación de Pod para siempre, y no dejaría registro sobre el Deployment.

**Q6.2** Mutar el **Deployment** (el camino del autogen) escribe el cambio en la spec persistida del Deployment, así que `kubectl get deploy -o yaml` lo muestra — y eso es exactamente el drift de GitOps: Argo CD o Flux compara el estado vivo contra Git, ve una anotación que Git no tiene, marca la app como `OutOfSync`, y puede revertirla, disparando un bucle de mutación/reversión. Mutar solamente el **Pod** deja el Deployment idéntico byte a byte a Git, así que no hay drift, pero el cambio es invisible en la spec del Deployment y se reaplica en cada creación de Pod. Cuál querés depende del reconciliador: para workloads gestionados por GitOps, preferí la mutación a nivel de Pod (`autogen-controllers: none` en la política de mutación) más una entrada `ignoreDifferences` de Argo CD si tenés que mutar el controlador; para workloads gestionados imperativamente o aplicados por personas, la mutación a nivel de controlador es mejor porque el cambio es duradero, auditable y visible para cualquiera que lea el objeto. El modo de fallo a evitar es la mutación a nivel de controlador *más* un reconciliador GitOps estricto sin regla de exclusión.

**Q6.3** Una regla `validate` o `mutate` hace una afirmación sobre el objeto bajo admisión, así que reubicarla a una ruta anidada preserva el significado. Una regla `generate` crea un objeto *distinto y no relacionado* como efecto secundario de un disparador. No hay ruta que reubicar, y la pregunta "¿cuál es el equivalente a nivel de Deployment de 'cuando aparece un Pod, creá una NetworkPolicy'?" no tiene una respuesta única — ¿la NetworkPolicy debería crearse una vez por Deployment o una vez por Pod? ¿Cuál es la owner reference? ¿Qué pasa al escalar hacia arriba? La transformación no tiene una definición que preserve el significado, así que el autogen correctamente se abstiene. Si querés una regla generate disparada por controladores, escribila explícitamente con el controlador en `match`.

**Q6.4** Los parches JSON (`patchesJson6902`) **no** se autogeneran; `.status.autogen` está ausente para `json-patch-demo`. La razón mecánica es que los parches RFC 6902 direccionan el objeto mediante punteros JSON opacos — `/spec/containers/0/image` es una cadena, no una ruta de campo estructurada que Kyverno pueda reescribir de forma confiable. Prefijarlo a `/spec/template/spec/containers/0/image` sería una edición ingenua de cadena que se rompe con cualquier puntero que no empiece en una raíz reubicable (`/metadata/name`, segmentos escapados `~1`, marcadores de agregado `-` sobre arrays cuya longitud difiere entre el contexto del Pod y el del template, u operaciones `test`/`move`/`copy` que referencian dos rutas). En vez de adivinar, Kyverno se abstiene. Consecuencia práctica: **usá `patchStrategicMerge` (o `mutate.patchesJson6902` solo con `autogen-controllers: none` y una regla de controlador explícita) siempre que necesites que la mutación se aplique a workloads.** Una regla `patchesJson6902` que hace match con Pods es una regla solo-Pod, silenciosamente.

**Q6.5** Porque esas políticas hacen match con `Pod`, y el autogen de Kyverno deriva automáticamente las reglas `spec.template.spec` equivalentes para Deployments, StatefulSets, DaemonSets, Jobs y CronJobs — la biblioteca provee una regla con alcance de Pod por control y se apoya en el autogen para toda la superficie de workloads. Por eso el conjunto de políticas PSS de Kyverno son unas pocas decenas de reglas en vez de unos cientos, y por eso desactivar el autogen globalmente lo reduciría calladamente a un conjunto de controles solo de admisión de Pods.

### Bloque 7

**Q7.1** Porque el autor ya declaró cómo deben tratarse los Deployments. Si Kyverno autogenerara igual, un Deployment enviado sería evaluado dos veces por el mismo linaje de nombre de regla: una por la regla escrita contra `metadata.labels` (las etiquetas propias del Deployment) y otra por la regla derivada contra `spec.template.metadata.labels`. El Deployment tendría que satisfacer ambas, lo que es más estricto que cualquier cosa que el autor escribió e imposible de inferir leyendo la política. La supresión hace que la intención explícita le gane a la inferencia — el valor por defecto correcto para un motor de políticas, donde una estrictez sorpresiva es tan peligrosa como una laxitud sorpresiva.

**Q7.2** Las `metadata.labels` propias del Deployment. El pattern `metadata.labels.team: "?*"` se aplica textualmente a cualquier objeto que haga match, y `Deployment` hace match, así que Kyverno chequea las etiquetas de nivel superior del objeto Deployment. Casi con certeza no es lo que el autor quería decir: escribieron `Pod, Deployment` con la intención de "cubrir tanto a los Pods como a los Deployments que los crean", y obtuvieron "los Pods deben estar etiquetados y, por separado, los objetos Deployment deben estar etiquetados" — mientras que los Pods creados por un Deployment etiquetado con un template sin etiquetar pasan por esta política intactos en la capa del Deployment y solo son atrapados en la admisión del Pod. El idiom `kinds: [Pod, Deployment]` es un olor confiable en revisión: significa que el autor no sabía que existía el autogen.

**Q7.3**
```bash
kubectl get cpol -o json | jq -e '
  [ .items[]
    | select(any(.spec.rules[]?; (.match.any[]?.resources.kinds[]? // empty) == "Pod"))
    | select((.status.autogen.rules // []) | length == 0)
    | .metadata.name
  ] | if length == 0 then true
      else ("policies match Pod but derived no autogen rules: " + (.|tostring) | halt_error(1)) end'
```
La aserción es: *cualquier política con una regla que haga match con Pod debe tener un `.status.autogen.rules` no vacío*. Permití excepciones documentadas salteando las políticas que lleven una anotación explícita `pod-policies.kyverno.io/autogen-controllers: "none"` **más** una anotación `policy.example.com/autogen-exempt-reason` — la cadena con el motivo es lo que hace que la excepción sea revisable en vez de un sello de goma. Ejecutalo contra un apply con `--dry-run=server` del directorio de políticas en CI, para que bloquee el merge en vez de reportar después del despliegue.

**Q7.4** El autogen igual corre. `exclude` acota a qué objetos se aplica una regla; no cambia el hecho de que el `match` de la regla apunta a `Pod`, que es la condición disparadora de la derivación. El bloque `exclude` se copia a las reglas derivadas junto con todo lo demás — así que terminás con una regla derivada que hace match con `Deployment` en `match` y excluye `Deployment` en `exclude`, lo que no hace match con nada. La regla está efectivamente muerta para Deployments mientras se ve activa en `.status`. Verificalo con `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[0]}' | yq -P` y leyendo el bloque `exclude`. Excluir un kind de controlador no es la forma de acotar el autogen — la anotación sí lo es.

### Bloque 8

**Q8.1** De la biblioteca del motor de Kyverno, que la CLI enlaza directamente. El autogen es una transformación **del lado de la biblioteca**, aplicada cada vez que una política se carga y se prepara para evaluación, no una mutación del lado del controlador sobre el estado almacenado — el controlador simplemente persiste el resultado en `.status` para observabilidad. Esto es lo que hace posible el testeo offline de reglas derivadas, y también es por qué el desfasaje de versión entre CLI y clúster (Q0.2) produce resultados divergentes: dos copias de la misma transformación a versiones distintas.

**Q8.2** Una entrada de policy report —y cada fila `results[]` de un `Test`— está indexada por la terna (política, regla, recurso). La regla que realmente evaluó un Deployment es `autogen-check-runasnonroot`; ese es el nombre que aparece en el `PolicyReport`, en el mensaje de rechazo de admisión y en la salida de `kyverno apply`. Afirmar sobre `check-runasnonroot` para un Deployment es afirmar sobre una fila que no existe, de ahí `Not found`. El nombre de la regla es la identidad de la regla evaluada, no de la escrita — y la regla derivada es una regla genuinamente distinta, con un match distinto y una ruta distinta.

**Q8.3** La causa más probable es un cambio en los valores por defecto de los controladores del autogen o en el nombrado/forma de las reglas derivadas entre versiones — por ejemplo, `ReplicaSet` y `ReplicationController` sacados del conjunto por defecto, de modo que una fila de `Test` que afirma un resultado sobre un recurso ReplicaSet ya no encuentra regla coincidente. Primer comando: `kyverno apply policy.yaml --resource resource.yaml` y leer los nombres de regla en la salida; equivalentemente `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'` en el clúster actualizado. Comparalo contra los valores de `rule:` en tus manifiestos `Test`. Arreglalo actualizando las expectativas del test y —si el cambio de cobertura no era intencional— fijando el conjunto de controladores explícitamente en la anotación en vez de depender del valor por defecto, que es lo que dejó que una actualización cambiara el radio de impacto de tu política en silencio.

**Q8.4**
```bash
kyverno apply policies/ --resource testdata/deployment.yaml --policy-report -o report.yaml
grep -q 'rule: autogen-check-mixed' report.yaml || { echo "no autogen rule fired on Deployment"; exit 1; }
```
Más robustamente, codificalo como un caso `Test` que afirme un resultado `fail` sobre un recurso Deployment para el nombre de la regla derivada — si el autogen fue suprimido, la fila no va a existir y `kyverno test` reporta `Not found`, haciendo fallar el build. El patrón general: **por cada política con alcance de Pod, mantené un fixture con forma de controlador en `testdata/` y un resultado esperado que nombre la regla derivada.** Ese único fixture es lo que convierte una supresión silenciosa del autogen en un build en rojo.

### Bloque 9

**Q9.1** El comando **(e)** — `kubectl get cpol <name> -o jsonpath='{.status.autogen}'` devolviendo `{}`. Va directo al invariante que explica el síntoma: la política existe y aplica, pero no derivó reglas de controlador, por lo tanto nada interceptó el Deployment. (c) es el primer instinto más natural y sí revela el Pod rechazado, pero te dice *que* el Pod fue bloqueado, no *por qué el Deployment no lo fue* — todavía tenés que razonar hacia atrás hasta el autogen. (f) después te da la causa de (e) en un comando más. En un incidente, ejecutá (c) y (e) juntos: (c) confirma que la política es la culpable, (e) explica la retroalimentación faltante.

**Q9.2** `READY: True` significa que la política compiló, que su webhook está configurado y que sus reglas están cargadas — una afirmación sobre la salud propia de la política, no sobre su cobertura. `Enforce` significa *cuando una regla hace match, denegá*. Ninguno de los dos dice nada sobre *qué kinds* hacen match. Con el autogen suprimido la política hace match solo con `Pod`, así que un Deployment enviado no hace match con nada y es admitido; el Pod que el controlador de ReplicaSet envía después sí hace match y es denegado, en modo Enforce, correctamente. La política está plenamente sana y plenamente aplicando — sobre un recurso que el usuario nunca toca. `READY` y `VALIDATE ACTION` no son indicadores de cobertura; `.status.autogen` y las reglas del webhook sí lo son.

**Q9.3** *Si la regla de una política hace match con `Pod` y `.status.autogen.rules` está vacío, Kyverno intercepta solamente `pods` — así que los objetos de workload se admiten sin chequear y la violación va a aparecer como un evento `FailedCreate` sobre el ReplicaSet o el Job, no en `kubectl apply`.* La cadena va anotación → `.status.autogen.rules` → `rules` del webhook, cada eslabón derivado del anterior, así que leer cualquier eslabón te dice el estado del siguiente. En un runbook, acompañalo con el comando de verificación: `kubectl get cpol <name> -o jsonpath='{.status.autogen.rules[*].name}'`.

**Q9.4** Usá el pipeline de `jq` de la Q7.3, ajustado a políticas Enforce y a la excepción documentada:

```bash
kubectl get cpol -o json | jq -e '
  [ .items[]
    | select(.spec.validationFailureAction == "Enforce"
             or any(.spec.rules[]?.validate?; .failureAction == "Enforce"))
    | select(any(.spec.rules[]?; (.match.any[]?.resources.kinds[]? // empty) == "Pod"))
    | select((.status.autogen.rules // []) | length == 0)
    | select((.metadata.annotations["policy.example.com/autogen-exempt-reason"] // "") == "")
    | .metadata.name
  ] | if length == 0 then true
      else ("Enforce policies match Pod, derived no autogen rules, and have no exemption reason: "
             + (.|tostring) | halt_error(1)) end'
```

Ejecutalo contra un apply con dry-run del lado del servidor del directorio de políticas para que bloquee el PR. La anotación de excepción es deliberadamente un *motivo* de texto libre, no un booleano: un booleano se pone en `true` sin pensar, una cadena con el motivo hay que escribirla y revisarla.

### Bloque 10

**Q10.1** `object.spec.template.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)` — la misma reubicación a `spec.template` que en la API v1, aplicada al accesor raíz de la expresión CEL en vez de a un pattern YAML. Compará contra `kubectl get vpol vpol-require-nonroot -o yaml | yq '.status.autogen'`; la expresión generada es la verdad de campo para tu versión, y leerla es el objetivo del ejercicio. Notá que el autogen de CEL tiene que reescribir el accesor dentro de una expresión arbitraria, lo que es una transformación más difícil que reubicar un árbol de patterns — inspeccioná qué hace con `oldObject`, con `variables`, y con cualquier `matchConditions` que agregues.

**Q10.2** (1) **Validación de esquema y descubribilidad.** Un campo tipado bajo `spec` es validado por el API server contra el esquema OpenAPI del CRD: un typo como `deployment` (singular) o `Deployments` se rechaza en el momento del apply. Una anotación es una cadena opaca — un typo se acepta silenciosamente y produce el modo de fallo del Bloque 7, donde la política parece configurada y no cubre nada. (2) **Herramientas y revisión.** `kubectl explain` lo documenta, el autocompletado por esquema del IDE lo ofrece, las políticas de admisión y las reglas de conftest pueden afirmar sobre él estructuralmente, y un `kubectl diff` muestra un cambio semántico de campo en vez de una edición de cadena en una anotación. Una tercera: las anotaciones son un espacio de nombres compartido que controladores, herramientas de GitOps y políticas de mutación reescriben rutinariamente, así que un control codificado en una anotación corre riesgo de ser pisado por algo que no tiene idea de que es crítico.

**Q10.3** Señala que el match se expresa en la capa de **recurso de la API** en vez de en la capa de Kind — los plurales en minúscula son los nombres de recurso REST que aparecen en las reglas de `ValidatingWebhookConfiguration`, en las listas `resources:` de RBAC y en el documento de descubrimiento de la API. Los nuevos tipos de política CEL se alinean con el `ValidatingAdmissionPolicy` de Kubernetes upstream, cuyo `matchConstraints.resourceRules` también usa `apiGroups`/`apiVersions`/`resources` en forma de recurso. Así que el match derivado se enchufa directamente a la misma estructura que el API server usa para la admisión, sin un paso de traducción de Kind a recurso en el medio — un lugar menos donde puede haber discrepancia.

**Q10.4** El equivalente es **omitir el bloque `spec.autogen` por completo**, o ponerlo en la lista vacía de controladores que el esquema define como "sin autogeneración" — consultá `kubectl explain validatingpolicies.spec.autogen.podControllers` para tu versión en vez de asumir, ya que la distinción entre vacío y ausente es exactamente el tipo de cosa que difiere. No asumas la equivalencia: verificala (1) confirmando que `.status.autogen` está vacío en la nueva política, (2) ejecutando `kyverno apply` contra los mismos fixtures de controlador usados para la política vieja y chequeando que ninguna regla se dispare sobre el controlador y que la regla de Pod siga disparándose sobre el Pod, y (3) comparando las `rules` del webhook antes y después de la migración — `kubectl get validatingwebhookconfiguration -o jsonpath=...` — ya que la lista de recursos es el efecto final observable de toda la cadena. Migrar de tipo de política es un cambio de motor, no solo de sintaxis; afirmá sobre el efecto final, no sobre la configuración que se supone que lo produce.

</details>

---

## Fuentes

- KCA Curriculum, CNCF — <https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf>
- Documentación de Kyverno, "Auto-Gen Rules for Pod Controllers" — <https://kyverno.io/docs/writing-policies/autogen/> (usá el selector de versión para que coincida con tu clúster; la página se movió bajo las secciones de tipos de política en la reorganización de la documentación de 1.14)
- Documentación de Kyverno, reglas de mutación y anclas — <https://kyverno.io/docs/writing-policies/mutate/>
- Kyverno CLI, referencia del comando `test` — <https://kyverno.io/docs/kyverno-cli/usage/test/>
- Kyverno CLI, referencia del comando `apply` — <https://kyverno.io/docs/kyverno-cli/usage/apply/>
- Código fuente y notas de release de Kyverno — <https://github.com/kyverno/kyverno>
- Referencia de la API de Kubernetes, `PodTemplateSpec` en controladores de workload — <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/>
- Documentación de Kubernetes, Dynamic Admission Control — <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>