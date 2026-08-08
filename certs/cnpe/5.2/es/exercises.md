# Ejercicios guiados — Tema 5.2: Implementing Workflows for Self-Service Provisioning Using Platform APIs

> **Escenario.** Sos platform engineer en ACME. Los equipos de producto piden constantemente "un entorno aislado para probar" y hoy eso implica un ticket, una espera de dos días y un ops manual. Vas a construir el *golden path* que convierte ese pedido en una **API declarativa** (`kind: DevEnvironment`) que el desarrollador consume solo, orquestada por un **workflow** que valida, provisiona y reporta el resultado — sin que ops toque nada.
>
> Vas a montar la pila completa de self-service: **Crossplane** como plano de control (la *Platform API*), **provider-kubernetes** como reconciliador, **Argo Workflows** como orquestador del pedido, un **Backstage Software Template** como puerta de entrada humana y **Kyverno** como guardrail de admisión.

**Prerrequisitos**

- Un cluster de práctica descartable (`kind`, `k3d` o `minikube`), `kubectl`, `helm` y el CLI `crossplane` (`curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh`).
- ~4 GB de RAM libres. Todo se resuelve **in-cluster**, sin credenciales de nube: componemos objetos nativos de Kubernetes, que es el caso real de un *internal developer platform* de entornos sandbox.
- Versiones de referencia: Crossplane v1.17, `provider-kubernetes` v0.14.0, `function-patch-and-transform` v0.7.0, Argo Workflows v3.5, Kyverno v1.12. Ajustá los tags si usás otras.

```bash
kind create cluster --name cnpe-52
kubectl cluster-info --context kind-cnpe-52
```

---

## Bloque 1 — Bootstrap del plano de control

El "platform API" del que habla el syllabus no es un servicio REST que escribas a mano: es la **Kubernetes API extendida con CRDs** más un controlador que reconcilia el estado deseado. Crossplane provee ese motor.

**Pasos**

1. Instalá Crossplane con Helm:

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace --wait
   ```

2. Verificá que los pods del core están arriba:

   ```bash
   kubectl get pods -n crossplane-system
   ```
   Salida esperada (aproximada):
   ```
   NAME                                       READY   STATUS    RESTARTS   AGE
   crossplane-7d8b6c8f7d-abcde                1/1     Running   0          40s
   crossplane-rbac-manager-6c8f7d9b8c-fghij   1/1     Running   0          40s
   ```

3. Instalá el provider que va a materializar los recursos y la function que compone:

   ```yaml
   # providers.yaml
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-kubernetes
   spec:
     package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.0
   ---
   apiVersion: pkg.crossplane.io/v1beta1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
   ```
   ```bash
   kubectl apply -f providers.yaml
   kubectl wait provider.pkg/provider-kubernetes --for=condition=Healthy --timeout=180s
   kubectl wait function.pkg/function-patch-and-transform --for=condition=Healthy --timeout=180s
   ```

4. `provider-kubernetes` corre con su propia `ServiceAccount` y, por defecto, no tiene permiso para crear nada. Concedele RBAC y creale un `ProviderConfig` que use esa identidad inyectada:

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name \
        | grep provider-kubernetes | sed 's|serviceaccount/||')
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole cluster-admin \
     --serviceaccount "crossplane-system:${SA}"
   ```
   ```yaml
   # providerconfig.yaml
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   ```
   ```bash
   kubectl apply -f providerconfig.yaml
   ```

**Verificación de comprensión — Bloque 1**

1. ¿Por qué decimos que "la Platform API *es* la Kubernetes API"? ¿Qué aporta Crossplane que la API base no trae?
2. En el paso 4 le dimos `cluster-admin` al provider. ¿Por qué el provider necesita permisos que el desarrollador que consume la API **no** necesita? ¿Qué principio de plataforma se apoya en esa asimetría?
3. `credentials.source: InjectedIdentity` — ¿de dónde saca la identidad el provider y por qué es preferible a montar un `kubeconfig` en un Secret para un target in-cluster?

---

## Bloque 2 — Definir la Platform API (el contrato)

El `CompositeResourceDefinition` (XRD) es donde diseñás la **superficie pública** de tu servicio: qué campos ve el desarrollador, cuáles son obligatorios, qué defaults aplica la plataforma. Es API design, no plomería.

**Pasos**

1. Definí el XRD. Fijate que expone **dos** tipos: el `XDevEnvironment` (cluster-scoped, para la plataforma) y el `DevEnvironment` (namespaced *claim*, para el desarrollador):

   ```yaml
   # xrd.yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xdevenvironments.platform.acme.io
   spec:
     group: platform.acme.io
     names:
       kind: XDevEnvironment
       plural: xdevenvironments
     claimNames:
       kind: DevEnvironment
       plural: devenvironments
     defaultCompositionRef:
       name: devenv-kubernetes
     versions:
       - name: v1alpha1
         served: true
         referenceable: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   parameters:
                     type: object
                     properties:
                       team:
                         type: string
                         description: "Owning team; drives naming and quota."
                       cpuLimit:
                         type: string
                         default: "4"
                       memoryLimit:
                         type: string
                         default: "8Gi"
                     required:
                       - team
                 required:
                   - parameters
               status:
                 type: object
                 properties:
                   namespace:
                     type: string
                     description: "Provisioned namespace name."
   ```
   ```bash
   kubectl apply -f xrd.yaml
   kubectl get xrd xdevenvironments.platform.acme.io
   ```
   Salida esperada:
   ```
   NAME                                 ESTABLISHED   OFFERED   AGE
   xdevenvironments.platform.acme.io    True          True      6s
   ```

2. Comprobá que Crossplane generó los CRDs reales a partir de tu contrato:

   ```bash
   kubectl get crd | grep platform.acme.io
   ```
   Salida esperada:
   ```
   devenvironments.platform.acme.io     2026-08-07T...
   xdevenvironments.platform.acme.io    2026-08-07T...
   ```

3. Inspeccioná el schema publicado — es el que verá cualquier cliente (kubectl, Backstage, Argo):

   ```bash
   kubectl explain devenvironment.spec.parameters
   ```

**Verificación de comprensión — Bloque 2**

1. `ESTABLISHED=True` y `OFFERED=True`: ¿qué afirma cada columna por separado y qué falla si `OFFERED` quedara en `False`?
2. Diferenciá **Composite Resource (XR)** de **Claim**. ¿Por qué el claim es *namespaced* y el XR es *cluster-scoped*, y qué habilita eso para el multi-tenancy self-service?
3. Pusimos `default: "4"` en `cpuLimit` y `required: [team]`. Explicá cómo estas dos decisiones de schema son en sí mismas un mecanismo de *golden path*: ¿qué carga cognitiva le sacás al desarrollador?
4. El campo `status.namespace` no lo escribe el desarrollador. ¿Quién lo escribe y en qué momento del ciclo de reconciliación?

---

## Bloque 3 — Componer la infraestructura

La `Composition` es la **implementación** detrás del contrato: traduce un `XDevEnvironment` en recursos concretos. Usamos el modo **Pipeline** con `function-patch-and-transform` (el modo `Resources` inline está deprecado desde v1.17).

**Pasos**

1. Escribí la Composition. Provisiona un `Namespace` y un `ResourceQuota`, parametrizados desde el claim:

   ```yaml
   # composition.yaml
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: devenv-kubernetes
   spec:
     compositeTypeRef:
       apiVersion: platform.acme.io/v1alpha1
       kind: XDevEnvironment
     mode: Pipeline
     pipeline:
       - step: patch-and-transform
         functionRef:
           name: function-patch-and-transform
         input:
           apiVersion: pt.fn.crossplane.io/v1beta1
           kind: Resources
           resources:
             - name: namespace
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha1
                 kind: Object
                 spec:
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: Namespace
                       metadata:
                         name: # patched below
                   providerConfigRef:
                     name: default
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.name
                   transforms:
                     - type: string
                       string:
                         type: Format
                         fmt: "env-%s"
                 - type: ToCompositeFieldPath
                   fromFieldPath: spec.forProvider.manifest.metadata.name
                   toFieldPath: status.namespace
             - name: resource-quota
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha1
                 kind: Object
                 spec:
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: ResourceQuota
                       metadata:
                         name: team-quota
                       spec:
                         hard:
                           limits.cpu: "4"
                           limits.memory: "8Gi"
                   providerConfigRef:
                     name: default
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.namespace
                   transforms:
                     - type: string
                       string:
                         type: Format
                         fmt: "env-%s"
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.cpuLimit
                   toFieldPath: spec.forProvider.manifest.spec.hard[limits.cpu]
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.memoryLimit
                   toFieldPath: spec.forProvider.manifest.spec.hard[limits.memory]
   ```
   ```bash
   kubectl apply -f composition.yaml
   ```

2. Validá que la Composition referencia un tipo que existe y una function healthy:

   ```bash
   kubectl get composition devenv-kubernetes -o \
     jsonpath='{.spec.compositeTypeRef.kind}{"\n"}'
   ```
   Salida esperada:
   ```
   XDevEnvironment
   ```

**Verificación de comprensión — Bloque 3**

1. `FromCompositeFieldPath` vs `ToCompositeFieldPath`: en el recurso `namespace` usamos los dos. Explicá el flujo de datos de cada uno y por qué el segundo es el que "cierra el lazo" hacia el status del claim.
2. El transform `Format` con `fmt: "env-%s"` convierte `team=payments` en `env-payments`. ¿Por qué imponer el prefijo en la Composition y no dejar que el desarrollador elija el nombre del namespace? Nombrá al menos dos riesgos que eso mitiga.
3. Un `Object` de provider-kubernetes es un *managed resource* que envuelve un manifiesto arbitrario. ¿Qué diferencia hay, en términos de *drift* y reconciliación continua, entre que Crossplane "aplique" ese ResourceQuota vía un `Object` y que vos lo apliques una vez con `kubectl apply`?
4. Si mañana quisieras que el mismo contrato `DevEnvironment` provisione en AWS en vez de in-cluster, ¿qué archivo cambiás y cuál **no** tocás? ¿Cómo se llama esa propiedad de diseño?

---

## Bloque 4 — Consumo self-service y trazado

Ahora te ponés el sombrero de desarrollador: pedís un entorno con un solo YAML, sin saber nada de Crossplane ni de RBAC.

**Pasos**

1. Creá el namespace del equipo (donde vive el claim) y aplicá el claim:

   ```bash
   kubectl create namespace team-payments
   ```
   ```yaml
   # claim.yaml
   apiVersion: platform.acme.io/v1alpha1
   kind: DevEnvironment
   metadata:
     name: payments
     namespace: team-payments
   spec:
     parameters:
       team: payments
       cpuLimit: "8"
       memoryLimit: "16Gi"
   ```
   ```bash
   kubectl apply -f claim.yaml
   ```

2. Observá cómo la plataforma reconcilia. El claim pasa a `SYNCED=True` y luego `READY=True`:

   ```bash
   kubectl get devenvironment -n team-payments -w
   ```
   Salida esperada (tras ~10 s):
   ```
   NAME       SYNCED   READY   CONNECTION-SECRET   AGE
   payments   True     False                       3s
   payments   True     True                        11s
   ```

3. Trazá la cadena completa claim → XR → managed resources con el CLI de Crossplane:

   ```bash
   crossplane beta trace devenvironment/payments -n team-payments
   ```
   Salida esperada:
   ```
   NAME                                 SYNCED   READY   STATUS
   DevEnvironment/payments (team-...)   True     True    Available
   └─ XDevEnvironment/payments-8n2xk    True     True    Available
      ├─ Object/payments-8n2xk-nsq4z    True     True    Available
      └─ Object/payments-8n2xk-qm7bd    True     True    Available
   ```

4. Comprobá el resultado material y el status devuelto al desarrollador:

   ```bash
   kubectl get ns env-payments
   kubectl get resourcequota -n env-payments team-quota \
     -o jsonpath='{.spec.hard}{"\n"}'
   kubectl get devenvironment payments -n team-payments \
     -o jsonpath='{.status.namespace}{"\n"}'
   ```
   Salida esperada:
   ```
   NAME           STATUS   AGE
   env-payments   Active   14s
   {"limits.cpu":"8","limits.memory":"16Gi"}
   env-payments
   ```

**Verificación de comprensión — Bloque 4**

1. El desarrollador aplicó un objeto *namespaced* llamado `payments`, pero `beta trace` muestra un `XDevEnvironment/payments-8n2xk` cluster-scoped. ¿Quién creó ese XR, de dónde sale el sufijo `-8n2xk` y qué relación de ownership los une?
2. En el paso 2, `READY` pasó por `False` antes de `True`, pero `SYNCED` estuvo en `True` casi enseguida. Distinguí ambas condiciones: ¿qué afirma "Synced" y qué afirma "Ready", y por qué el orden importa para un workflow que espera el resultado?
3. Si el desarrollador hace `kubectl delete devenvironment payments -n team-payments`, ¿qué le pasa al namespace `env-payments` y al ResourceQuota? ¿Qué mecanismo de Kubernetes garantiza ese *garbage collection* en cascada?

---

## Bloque 5 — El workflow de orquestación y la puerta de entrada

La API declarativa ya es self-service, pero un pedido real casi nunca es "aplicá un CR y listo": suele encadenar *validar → abrir un PR en el repo de GitOps → aplicar → esperar readiness → notificar*. Eso es el **workflow**. Lo modelamos con **Argo Workflows** y le ponemos una **puerta de entrada humana** con un Software Template de Backstage.

**Pasos**

1. Instalá Argo Workflows:

   ```bash
   kubectl create namespace argo
   kubectl apply -n argo -f \
     https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/quick-start-minimal.yaml
   kubectl -n argo wait deploy/workflow-controller --for=condition=Available --timeout=180s
   ```

2. Dale al `default` ServiceAccount de Argo permiso para gestionar claims (mínimo necesario, no cluster-admin):

   ```yaml
   # argo-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: argo-devenv-provisioner
   rules:
     - apiGroups: ["platform.acme.io"]
       resources: ["devenvironments"]
       verbs: ["create", "get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: argo-devenv-provisioner
   roleObjects: []
   subjects:
     - kind: ServiceAccount
       name: default
       namespace: argo
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: argo-devenv-provisioner
   ```
   > Corregí el bloque `roleObjects: []` — no existe ese campo; se incluyó a propósito como error tipográfico. La `ClusterRoleBinding` correcta lleva solo `subjects` y `roleRef`. (Ver pregunta 4.)

3. Definí el `WorkflowTemplate` reutilizable — el paso 1 crea el claim, el paso 2 espera readiness:

   ```yaml
   # provision-workflow.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: WorkflowTemplate
   metadata:
     name: provision-devenv
     namespace: argo
   spec:
     entrypoint: main
     arguments:
       parameters:
         - name: team
         - name: cpu
           value: "4"
         - name: memory
           value: "8Gi"
     templates:
       - name: main
         inputs:
           parameters:
             - {name: team}
             - {name: cpu}
             - {name: memory}
         steps:
           - - name: submit-claim
               template: submit
           - - name: wait-ready
               template: wait
       - name: submit
         inputs:
           parameters: [{name: team}, {name: cpu}, {name: memory}]
         resource:
           action: create
           manifest: |
             apiVersion: platform.acme.io/v1alpha1
             kind: DevEnvironment
             metadata:
               name: "{{inputs.parameters.team}}"
               namespace: team-payments
             spec:
               parameters:
                 team: "{{inputs.parameters.team}}"
                 cpuLimit: "{{inputs.parameters.cpu}}"
                 memoryLimit: "{{inputs.parameters.memory}}"
       - name: wait
         inputs:
           parameters: [{name: team}]
         script:
           image: bitnami/kubectl:1.30
           command: [bash]
           source: |
             kubectl -n team-payments wait \
               devenvironment/{{inputs.parameters.team}} \
               --for=condition=Ready --timeout=300s
   ```
   ```bash
   kubectl apply -f argo-rbac.yaml    # tras corregir el paso 2
   kubectl apply -f provision-workflow.yaml
   ```

4. Disparalo como lo haría el orquestador (parametrizado, sin YAML a mano):

   ```bash
   kubectl delete devenvironment payments -n team-payments --ignore-not-found
   argo submit -n argo --from workflowtemplate/provision-devenv \
     -p team=analytics -p cpu=2 -p memory=4Gi --watch
   ```
   Salida esperada (cola):
   ```
   STEP                        TEMPLATE  PODNAME                    DURATION  MESSAGE
    ✔ provision-devenv-xxxxx   main
    ├─✔ submit-claim           submit    provision-devenv-xxxxx-1   4s
    └─✔ wait-ready             wait      provision-devenv-xxxxx-2   12s
   ```

5. La **puerta de entrada humana**: el desarrollador no corre `argo submit`, llena un formulario en Backstage. Este `Template` describe ese front door (leelo, no hace falta instalar Backstage para el ejercicio):

   ```yaml
   # backstage-template.yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: dev-environment
     title: Request a Dev Environment
     description: Provision an isolated, quota-capped sandbox for your team.
   spec:
     owner: platform-team
     type: resource
     parameters:
       - title: Environment
         required: [team]
         properties:
           team:
             type: string
             title: Team name
           cpu:
             type: string
             title: CPU limit
             default: "4"
             enum: ["2", "4", "8"]
     steps:
       - id: provision
         name: Trigger provisioning workflow
         action: http:backstage:request
         input:
           method: POST
           path: >-
             proxy/argo/api/v1/workflows/argo/submit
           body:
             resourceKind: WorkflowTemplate
             resourceName: provision-devenv
             submitOptions:
               parameters:
                 - "team=${{ parameters.team }}"
                 - "cpu=${{ parameters.cpu }}"
     output:
       links:
         - title: Argo Workflow run
           url: ${{ steps.provision.output.body.metadata.name }}
   ```

**Verificación de comprensión — Bloque 5**

1. Tanto el claim del Bloque 4 como el `submit` del Bloque 5 terminan creando el mismo `DevEnvironment`. Si la API declarativa ya es self-service, ¿qué agrega el workflow de Argo por encima? Dá dos responsabilidades que el CR por sí solo no cubre.
2. El paso `wait` usa `kubectl wait --for=condition=Ready`. ¿Por qué es más robusto que poner un `successCondition` con un índice de array (`status.conditions.1.status`) sobre el recurso?
3. En el Backstage Template, el desarrollador ve un `enum: ["2","4","8"]` para CPU pero nunca ve la Composition ni el RBAC del provider. Relacioná esto con la separación **interfaz vs. implementación** y con el concepto de "reducir carga cognitiva" del platform engineering.
4. **Bug plantado:** el manifiesto de RBAC del paso 2 trae un campo inventado. Identificalo, explicá por qué `kubectl apply` lo rechazaría y escribí la `ClusterRoleBinding` correcta.

---

## Bloque 6 — Guardrails de admisión y diagnóstico

Self-service sin límites es un incidente esperando ocurrir: alguien pide `cpuLimit: "10000"` y drena el cluster. Los **guardrails** viven en el *admission* — se evalúan **antes** de que el claim llegue al reconciliador. Cerramos con un ejercicio de diagnóstico.

**Pasos**

1. Instalá Kyverno y una `ClusterPolicy` que rechace claims fuera de política:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
   ```
   ```yaml
   # guardrail.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: devenv-guardrails
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
       - name: cap-cpu-and-require-team
         match:
           any:
             - resources:
                 kinds:
                   - platform.acme.io/v1alpha1/DevEnvironment
         validate:
           message: "cpuLimit must be a number <= 16 and team is required."
           deny:
             conditions:
               any:
                 - key: "{{ to_number(request.object.spec.parameters.cpuLimit) }}"
                   operator: GreaterThan
                   value: 16
   ```
   ```bash
   kubectl apply -f guardrail.yaml
   ```

2. Probá que el guardrail bloquea un pedido abusivo:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.acme.io/v1alpha1
   kind: DevEnvironment
   metadata:
     name: greedy
     namespace: team-payments
   spec:
     parameters:
       team: payments
       cpuLimit: "64"
   EOF
   ```
   Salida esperada:
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource DevEnvironment/team-payments/greedy was blocked due to the following policies:
   devenv-guardrails:
     cap-cpu-and-require-team: 'cpuLimit must be a number <= 16 and team is required.'
   ```

3. **Diagnóstico dirigido.** Rompé la plataforma como pasa en producción: borrá el RBAC del provider y creá un claim nuevo.

   ```bash
   kubectl delete clusterrolebinding provider-kubernetes-admin
   kubectl apply -f claim.yaml   # el 'payments' del Bloque 4
   ```

4. Observá el síntoma — el claim queda `SYNCED=True` pero `READY=False` para siempre:

   ```bash
   kubectl get devenvironment payments -n team-payments
   crossplane beta trace devenvironment/payments -n team-payments
   ```
   Salida esperada:
   ```
   NAME                                 SYNCED   READY   STATUS
   DevEnvironment/payments (team-...)   True     False   Creating
   └─ XDevEnvironment/payments-8n2xk    True     False   Creating
      ├─ Object/payments-8n2xk-nsq4z    False    False   ApplyFailure: ... is forbidden:
      │                                                  User "system:serviceaccount:crossplane-
      │                                                  system:provider-kubernetes-..." cannot
      │                                                  create resource "namespaces"
      └─ Object/payments-8n2xk-qm7bd    False    False   ApplyFailure: ... forbidden
   ```

5. Confirmá la causa raíz en el managed resource y en los logs del provider, después reparalo:

   ```bash
   kubectl describe object payments-8n2xk-nsq4z | sed -n '/Conditions/,$p'
   kubectl -n crossplane-system logs -l pkg.crossplane.io/provider=provider-kubernetes --tail=5
   # reparar:
   SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed 's|.*/||')
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole cluster-admin --serviceaccount "crossplane-system:${SA}"
   kubectl get devenvironment payments -n team-payments -w   # vuelve a READY=True solo
   ```

**Verificación de comprensión — Bloque 6**

1. El guardrail es una *validating admission policy*: se evalúa en el `kube-apiserver` antes de persistir. ¿Por qué es estructuralmente mejor rechazar ahí que dejar que la Composition falle al reconciliar? Pensalo en términos de *feedback loop* para el desarrollador.
2. En el paso 4, `SYNCED=True` pero `READY=False`. Traducí ese par de condiciones a lenguaje llano: ¿qué logró la plataforma y qué no? ¿Por qué este par es *exactamente* el que un workflow debe distinguir para no reportar "listo" un entorno que nunca se creó?
3. La política usa `to_number(...)` sobre `cpuLimit`, que en el schema es un `string`. ¿Qué pasa si alguien manda `cpuLimit: "abc"`? Proponé cómo endurecerías el **schema del XRD** (Bloque 2) para que este caso ni siquiera llegue a Kyverno.
4. Ordená la escalera de verificación que usaste para diagnosticar (`get` → `trace` → `describe` → `logs`). ¿Qué afirma cada peldaño que el anterior no, y por qué `beta trace` es el que más rápido te lleva al recurso culpable en una cadena de composición?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

1. **La Kubernetes API es extensible por diseño**: vía CRDs cualquiera registra tipos nuevos y el apiserver los sirve con las mismas garantías (validación de schema, RBAC, watch, audit, versionado) que los tipos nativos. Eso ya te da una *API declarativa* gratis. Lo que la API base **no** trae es un *controlador* que reconcilie esos tipos hacia infraestructura real: Crossplane aporta el motor de reconciliación (providers), el mecanismo de composición (XRD + Composition) y el modelo claim/XR para exponer abstracciones. En resumen: la API base te da la *superficie*; Crossplane te da el *comportamiento* detrás de ella.
2. El provider actúa como un **agente de sistema** que materializa lo que muchos equipos piden: crea namespaces, quotas, y en un caso real buckets, bases de datos o VPCs. Esos son privilegios elevados que jamás querés delegar al desarrollador. La asimetría es el principio de **privilege separation / least privilege por rol**: el desarrollador solo puede `create` un `DevEnvironment` en *su* namespace (poco privilegio, alcance acotado); el provider ejerce los privilegios amplios *en nombre de* la plataforma, encapsulados y auditables. Es el corazón del self-service seguro: el poder vive en la Composition, no en las manos del consumidor.
3. `InjectedIdentity` usa la **ServiceAccount del propio pod del provider**, montada por Kubernetes como un token proyectado (`/var/run/secrets/kubernetes.io/serviceaccount`). Es preferible a un `kubeconfig` en un Secret porque: (a) no hay credencial de larga vida que rotar o filtrar —el token es de vida corta y auto-renovado por el kubelet; (b) el acceso queda gobernado por RBAC nativo (el `ClusterRoleBinding`), no por un archivo opaco; (c) para un target in-cluster no hay endpoint externo ni CA que gestionar. Menos superficie de ataque, cero secretos que custodiar.

### Bloque 2

1. **`ESTABLISHED=True`** afirma que Crossplane generó y registró el CRD del *Composite Resource* (`XDevEnvironment`) y que el apiserver ya lo sirve. **`OFFERED=True`** afirma que además generó el CRD del *claim* namespaced (`DevEnvironment`), que es lo que consume el desarrollador. Si `OFFERED` quedara en `False` (típicamente porque omitiste `claimNames`), el XR existiría pero **no habría claim**: los desarrolladores no tendrían una API namespaced que aplicar y el self-service se rompe, aunque la plataforma internamente funcione.
2. El **XR** (`XDevEnvironment`) es el objeto que la plataforma reconcilia; es **cluster-scoped** porque agrupa recursos que pueden cruzar namespaces (o vivir fuera de cualquiera) y su ciclo de vida lo gobierna Crossplane. El **claim** (`DevEnvironment`) es la cara namespaced: vive en el namespace del equipo, hereda su RBAC y su quota, y es *lo único* que el desarrollador ve y posee. Esa separación habilita **multi-tenancy**: cada equipo aplica claims en su propio namespace con permisos acotados, mientras la plataforma consolida todos los XR en el plano de control sin que un tenant vea o toque los recursos de otro.
3. El `default` elimina una **decisión** que el desarrollador no tiene por qué tomar (¿cuánta CPU es "razonable"?): la plataforma provee un valor sano y él solo lo cambia si de verdad lo necesita. El `required: [team]` elimina la posibilidad de un pedido **inválido o ambiguo** (un entorno sin dueño). Juntos codifican el *golden path*: el camino por defecto es correcto, seguro y corto; desviarse es posible pero explícito. La API *enseña* cómo usarse.
4. Lo escribe el **motor de composición de Crossplane**, ejecutando el patch `ToCompositeFieldPath` de la Composition (Bloque 3), **después** de que el `Object` del namespace se reconcilió y el nombre real quedó fijado. Es decir, `status.namespace` se rellena en el camino de vuelta del ciclo de reconciliación (managed resource → XR → claim), no cuando el desarrollador aplica el claim.

### Bloque 3

1. **`FromCompositeFieldPath`** lee un campo del XR (por ej. `spec.parameters.team`) y lo **escribe hacia abajo** en el recurso compuesto (el manifiesto del `Object`): es el flujo *entrada del usuario → infraestructura*. **`ToCompositeFieldPath`** hace lo inverso: lee un campo del recurso compuesto ya materializado y lo **propaga hacia arriba** al `status` del XR (y de ahí al claim). El segundo "cierra el lazo" porque devuelve al desarrollador un dato que **solo se conoce después** de provisionar (el nombre efectivo del namespace) — sin él, el status quedaría mudo y el workflow no tendría de dónde leer el resultado.
2. Forzar el prefijo en la Composition mitiga: (a) **colisiones de nombres** entre equipos y con namespaces de sistema (`kube-system`, `default`); (b) **escapes de tenancy** —un desarrollador no puede nombrar su namespace `kube-node-lease` o el de otro equipo para pisarlo; (c) **naming inconsistente** que rompe dashboards, network policies y billing por convención. La plataforma es dueña del namespace de nombres; el desarrollador aporta solo la parte variable (`team`).
3. Con `kubectl apply` una sola vez, el ResourceQuota queda **sin dueño activo**: si alguien lo edita o lo borra, nadie lo restaura — hay *drift* silencioso. Envuelto en un `Object`, Crossplane lo **reconcilia continuamente** hacia el estado declarado en la Composition: detecta y revierte cambios manuales (self-healing), y si borrás el `Object` limpia el recurso. Pasás de "aplicar y olvidar" a "estado deseado garantizado en el tiempo".
4. Cambiás **solo la `Composition`** (y agregás el provider de AWS + su `ProviderConfig`); **no tocás el XRD ni el claim** — el contrato que ve el desarrollador es idéntico. Esa propiedad es la **separación interfaz/implementación** (o *encapsulación*): la abstracción `DevEnvironment` es estable aunque su realización cambie de backend. Incluso podés tener varias Compositions para el mismo XRD y elegir con `compositionSelector`/`compositionRef` (patrón de *golden path* con múltiples implementaciones).

### Bloque 4

1. Lo creó el **controlador de claims de Crossplane**: cuando aplicaste el `DevEnvironment` namespaced, Crossplane instanció automáticamente un `XDevEnvironment` cluster-scoped como su *backing resource*. El sufijo `-8n2xk` es un **hash aleatorio** que Crossplane añade (patrón `generateName`) para garantizar unicidad del XR a nivel cluster. La relación es de **ownership**: el claim referencia al XR vía `spec.resourceRef` y el XR referencia de vuelta al claim vía `spec.claimRef`; borrar el claim propaga la eliminación al XR.
2. **`Synced`** afirma que Crossplane pudo **traducir** el estado deseado y comunicarlo al reconciliador sin errores (la Composition corrió, los managed resources fueron *submitted*). **`Ready`** afirma que la infraestructura subyacente **existe y está operativa** (el namespace está `Active`, la quota aplicada). El orden importa porque un workflow que dispara "entorno listo" leyendo solo `Synced` reportaría éxito cuando todavía nada se materializó; **`Ready=True` es la única señal segura** de que el recurso es usable.
3. El namespace `env-payments` y su ResourceQuota **se eliminan en cascada**. El mecanismo es **owner references + garbage collection**: al borrar el claim se borra el XR; los `Object` tienen al XR como owner y se borran; y provider-kubernetes, al borrar sus `Object`, elimina los recursos reales que envolvían. Todo el árbol se colecta automáticamente sin intervención manual — otra ventaja de modelar el entorno como una API declarativa con ownership explícito.

### Bloque 5

1. El CR declarativo garantiza el **estado deseado** de la infraestructura, pero un pedido de producción tiene **pasos que no son estado**: por ejemplo (a) **abrir un Pull Request** en el repo de GitOps y esperar aprobación (compliance/auditoría), (b) **esperar readiness y notificar** por Slack/webhook, (c) sembrar datos, registrar el entorno en un catálogo, encadenar aprobaciones. Eso es lógica **imperativa/temporal** (secuencia, espera, ramas, reintentos) que el modelo declarativo no expresa: el workflow orquesta *el proceso alrededor* de la API, no reemplaza la API.
2. Un índice de array (`status.conditions.1`) asume una **posición fija** de la condición `Ready` dentro del array, y ese orden **no está garantizado** por la API — Crossplane puede reordenar o insertar condiciones, y tu wait apuntaría a `Synced` u otra por accidente. `kubectl wait --for=condition=Ready` selecciona la condición **por tipo**, no por posición: es semánticamente correcto y resiliente a cambios de orden. Regla general: nunca indexes condiciones por número.
3. Es la aplicación directa de **interfaz vs. implementación**. La *interfaz* (formulario Backstage) expone solo las decisiones que le competen al desarrollador —nombre del equipo, un `enum` acotado de CPU— con validación en el punto de entrada. La *implementación* (Composition, RBAC del provider, providers de nube) queda **encapsulada** y gobernada por la plataforma. Al presentar un menú cerrado en vez de un YAML abierto se **reduce la carga cognitiva**: el desarrollador no aprende Crossplane ni RBAC, solo elige entre opciones válidas — y no puede pedir algo fuera de política.
4. El campo inventado es **`roleObjects: []`** en la `ClusterRoleBinding`. `kubectl apply` lo rechaza porque el schema del CRD/tipo `ClusterRoleBinding` valida los campos y `roleObjects` no existe (error tipo `unknown field "roleObjects"` / `strict decoding error`). La versión correcta:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: argo-devenv-provisioner
   subjects:
     - kind: ServiceAccount
       name: default
       namespace: argo
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: argo-devenv-provisioner
   ```
   Una `RoleBinding`/`ClusterRoleBinding` lleva **solo** `subjects` (quién) y `roleRef` (qué rol) — nada más.

### Bloque 6

1. Rechazar en *admission* falla **antes de persistir** el objeto: el desarrollador recibe el error **sincrónico**, en el `kubectl apply`, con un mensaje accionable ("cpuLimit debe ser ≤ 16"). Si en cambio dejaras pasar el claim y la Composition fallara al reconciliar, el error sería **asíncrono**: el objeto queda creado pero `Ready=False`, el desarrollador tiene que ir a mirar condiciones/eventos, y el estado inválido ensucia el cluster. El *feedback loop* corto (rechazo inmediato con causa clara) es lo que hace usable un self-service; el diferido genera tickets.
2. `SYNCED=True` = "la plataforma **entendió y despachó** tu pedido: la Composition corrió y creó los managed resources". `READY=False` = "pero la infraestructura **no llegó a existir/operar**" (acá, porque el provider no tenía permiso para crear el namespace). En llano: *"te escuché, pero no pude hacerlo"*. Un workflow debe distinguirlos porque **`Synced` no implica éxito**: si reporta "listo" con solo `Synced`, entrega al desarrollador un entorno fantasma. Solo `Ready=True` autoriza a cerrar el pedido como exitoso.
3. `to_number("abc")` en JMESPath devuelve `null`; la comparación `null > 16` es `false`, así que la política **no lo bloquea** y el claim pasa — luego rompe recién al construir el ResourceQuota (fallo asíncrono, justo lo que querías evitar). El arreglo correcto es **endurecer el schema del XRD** para que un valor no numérico ni siquiera sea aceptado por el apiserver. Con OpenAPI podés restringir el string con un patrón, o mejor, cambiar el tipo a entero:
   ```yaml
   cpuLimit:
     type: integer
     minimum: 1
     maximum: 16
     default: 4
   ```
   Así la validación de tipo/rango vive en la **capa más temprana posible** (el propio contrato de la API), Kyverno queda para políticas cross-cutting, y "abc" o "64" se rechazan en el mismo `apply`. Principio: validá lo más cerca del origen que puedas.
4. La escalera:
   - **`kubectl get`** — *qué* pasa: el claim está `SYNCED=True / READY=False`. Detecta el síntoma, no la causa.
   - **`crossplane beta trace`** — *dónde*: recorre el árbol claim → XR → managed resources y muestra el nivel exacto donde `SYNCED` cae a `False` (los `Object` con `ApplyFailure`). Te lleva al **recurso culpable** sin describir uno por uno — es el peldaño de mayor rendimiento en cadenas de composición largas.
   - **`kubectl describe object …`** — *por qué*: las `Conditions`/`Events` del managed resource dan el mensaje completo (`is forbidden: ... cannot create resource "namespaces"`).
   - **`kubectl logs` del provider** — *confirmación de causa raíz*: los logs del reconciliador muestran el error RBAC crudo del apiserver, cerrando el diagnóstico.
   Cada peldaño **estrecha el alcance**: de "algo falla" a "este managed resource falla" a "por este permiso". `beta trace` es el pivote porque materializa la topología de composición —invisible en un `get` plano— y te ahorra inspeccionar recursos sanos.

</details>

---

**Fuentes**

- CNCF, *Cloud Native Platform Engineering (CNPE) Curriculum* — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes, *Custom Resources / API extension* — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Crossplane, *Composite Resource Definitions, Compositions & Claims* — https://docs.crossplane.io/latest/concepts/composite-resource-definitions/ y https://docs.crossplane.io/latest/concepts/compositions/
- Crossplane Contrib, *provider-kubernetes* — https://marketplace.upbound.io/providers/crossplane-contrib/provider-kubernetes
- Argo Workflows, *WorkflowTemplates & the `resource` template* — https://argo-workflows.readthedocs.io/en/latest/workflow-templates/ y https://argo-workflows.readthedocs.io/en/latest/walk-through/kubernetes-resources/
- Backstage, *Software Templates (Scaffolder)* — https://backstage.io/docs/features/software-templates/
- Kyverno, *Validate rules & policy types* — https://kyverno.io/docs/writing-policies/validate/