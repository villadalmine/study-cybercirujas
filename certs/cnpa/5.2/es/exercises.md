# Tema 5.2 — Ejercicios guiados: API-Driven Service Catalogs and Infrastructure Abstractions

> **Objetivo del tema.** En Platform Engineering, la infraestructura deja de ser un ticket y pasa a ser una **API**. Estos ejercicios te llevan por el ciclo completo: primero *abstraés* infraestructura detrás de una API de Kubernetes con **Crossplane** (XRD → Composition → Claim), después la *publicás* en un **service catalog** (Backstage: `catalog-info.yaml` + Software Templates) como un *golden path* autoservicio, y finalmente *diagnosticás* una abstracción que no reconcilia. La idea de fondo, que evaluamos en cada bloque: el **Kubernetes API server es el plano de control universal** del platform team, y el catálogo es el *front door* que lo hace descubrible y consumible sin que el desarrollador conozca los detalles del provider.

**Prerrequisitos**

- Un cluster de Kubernetes ≥ 1.28 (sirve `kind` o `minikube`) con `kubectl` apuntando a él.
- `helm` ≥ 3.12.
- El binario `crossplane` CLI ([instalación](https://docs.crossplane.io/latest/cli/)).
- Node.js ≥ 20 y `yarn` (para el Ejercicio 2).
- Permisos de `cluster-admin` en el cluster de laboratorio (vas a crear CRDs y RBAC).

Crear el cluster de laboratorio si no tenés uno:

```bash
kind create cluster --name cnpa-52
kubectl cluster-info --context kind-cnpa-52
```

---

## Ejercicio 1 — Abstraer infraestructura como API con Crossplane

Vas a construir una API propia de plataforma —`AppEnvironment`— que, con tres campos, aprovisiona un `Namespace`, un `ResourceQuota` y un `NetworkPolicy`. El desarrollador nunca escribe esos tres objetos: pide un *AppEnvironment* y el control plane los materializa.

### Bloque 1.1 — Instalar Crossplane y el provider

1. Instalá el core de Crossplane con Helm:

   ```bash
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane \
     --namespace crossplane-system --create-namespace \
     crossplane-stable/crossplane --wait
   ```

2. Verificá que el control plane esté arriba:

   ```bash
   kubectl get pods -n crossplane-system
   ```

   Salida esperada (los `Running` importan; los nombres con hash varían):

   ```
   NAME                                       READY   STATUS    RESTARTS   AGE
   crossplane-7c9d4f9c8b-2xk4p                1/1     Running   0          40s
   crossplane-rbac-manager-5f7d6c9b4d-9v2lq   1/1     Running   0          40s
   ```

3. Instalá `provider-kubernetes` (permite que Crossplane cree objetos *dentro del mismo cluster*, sin cuenta de nube):

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: pkg.crossplane.io/v1
   kind: Provider
   metadata:
     name: provider-kubernetes
   spec:
     package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1
   EOF
   ```

4. Esperá a que el provider quede `HEALTHY=True`:

   ```bash
   kubectl get providers
   ```

   ```
   NAME                  INSTALLED   HEALTHY   PACKAGE                                                          AGE
   provider-kubernetes   True        True      xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1   65s
   ```

5. El provider corre con su propia `ServiceAccount`, que por defecto **no** puede crear `Namespaces`. Dale permisos y configurá un `ProviderConfig` que use esa identidad inyectada:

   ```bash
   SA=$(kubectl -n crossplane-system get sa -o name | grep provider-kubernetes | sed 's|serviceaccount/||')
   kubectl create clusterrolebinding provider-kubernetes-admin \
     --clusterrole=cluster-admin \
     --serviceaccount="crossplane-system:${SA}"

   kubectl apply -f - <<'EOF'
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   EOF
   ```

**Preguntas de comprensión (1.1)**

1. ¿Qué diferencia hay entre un `Provider` de Crossplane y un `ProviderConfig`? ¿Por qué el `ProviderConfig` usa `source: InjectedIdentity` en este laboratorio y no un `Secret`?
2. El provider quedó `HEALTHY=True` pero, si te saltearas el paso 5, los objetos que cree quedarían en error. ¿Sobre qué identidad se ejecutan realmente las llamadas al API server y por qué es un control de seguridad relevante en una plataforma multi-tenant?

---

### Bloque 1.2 — Definir la API con un XRD

El **CompositeResourceDefinition (XRD)** es el contrato: define un tipo nuevo (`XAppEnvironment`) y su versión ofrecida a los usuarios (`AppEnvironment`, el *Claim*), con su esquema OpenAPI validado por el API server.

1. Creá el XRD:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xappenvironments.platform.acme.io
   spec:
     group: platform.acme.io
     names:
       kind: XAppEnvironment
       plural: xappenvironments
     claimNames:
       kind: AppEnvironment
       plural: appenvironments
     defaultCompositionRef:
       name: appenvironment-kubernetes
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
                         description: "Nombre del equipo; deriva el namespace team-<team>."
                       tier:
                         type: string
                         enum: ["small", "medium", "large"]
                         default: "small"
                     required:
                       - team
                 required:
                   - parameters
               status:
                 type: object
                 properties:
                   namespace:
                     type: string
   EOF
   ```

2. Confirmá que el API server ya expone los dos tipos nuevos como recursos de primera clase:

   ```bash
   kubectl api-resources | grep platform.acme.io
   ```

   ```
   appenvironments     platform.acme.io/v1alpha1   true    AppEnvironment
   xappenvironments    platform.acme.io/v1alpha1   false   XAppEnvironment
   ```

3. Observá la diferencia de *scope*: `AppEnvironment` es *namespaced* (`true`) y `XAppEnvironment` es cluster-scoped (`false`).

**Preguntas de comprensión (1.2)**

1. Un `Claim` (`AppEnvironment`) es *namespaced* y un *Composite* (`XAppEnvironment`) es cluster-scoped. ¿Por qué esa asimetría es exactamente lo que necesitás para dar autoservicio a un equipo sin darle acceso cluster-wide?
2. Definiste `tier` con `enum` y `default`, y `team` como `required`. ¿En qué momento y componente se rechaza un Claim con `tier: xlarge`, **antes** de que Crossplane intente aprovisionar algo? ¿Qué principio de "shift-left" cumple eso?

---

### Bloque 1.3 — Implementar la abstracción con una Composition

La **Composition** es el *cómo*: traduce un `XAppEnvironment` a objetos reales. Usamos el modo `Pipeline` moderno con la función `function-patch-and-transform` (el patch-and-transform inline quedó deprecado a favor de *composition functions*).

1. Instalá la función:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: pkg.crossplane.io/v1beta1
   kind: Function
   metadata:
     name: function-patch-and-transform
   spec:
     package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
   EOF

   kubectl wait function/function-patch-and-transform --for=condition=Healthy --timeout=120s
   ```

2. Creá la Composition:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: appenvironment-kubernetes
   spec:
     compositeTypeRef:
       apiVersion: platform.acme.io/v1alpha1
       kind: XAppEnvironment
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
                 apiVersion: kubernetes.crossplane.io/v1alpha2
                 kind: Object
                 spec:
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: Namespace
                       metadata:
                         name: placeholder
                   providerConfigRef:
                     name: default
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.name
                   transforms:
                     - type: string
                       string:
                         fmt: "team-%s"
                 - type: ToCompositeFieldPath
                   fromFieldPath: spec.forProvider.manifest.metadata.name
                   toFieldPath: status.namespace
             - name: quota
               base:
                 apiVersion: kubernetes.crossplane.io/v1alpha2
                 kind: Object
                 spec:
                   forProvider:
                     manifest:
                       apiVersion: v1
                       kind: ResourceQuota
                       metadata:
                         name: team-quota
                         namespace: placeholder
                       spec:
                         hard:
                           requests.cpu: "2"
                           requests.memory: 4Gi
                   providerConfigRef:
                     name: default
               patches:
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.team
                   toFieldPath: spec.forProvider.manifest.metadata.namespace
                   transforms:
                     - type: string
                       string:
                         fmt: "team-%s"
                 - type: FromCompositeFieldPath
                   fromFieldPath: spec.parameters.tier
                   toFieldPath: spec.forProvider.manifest.spec.hard['requests.cpu']
                   transforms:
                     - type: map
                       map:
                         small: "2"
                         medium: "4"
                         large: "8"
   EOF
   ```

3. Verificá que la Composition quedó registrada y referencia el tipo correcto:

   ```bash
   kubectl get composition appenvironment-kubernetes \
     -o jsonpath='{.spec.compositeTypeRef.kind}{"\n"}'
   ```

   ```
   XAppEnvironment
   ```

**Preguntas de comprensión (1.3)**

1. El patch del `namespace` usa `FromCompositeFieldPath` y también uno `ToCompositeFieldPath`. Explicá el flujo de datos de cada dirección: ¿de dónde a dónde viaja el valor y para qué sirve escribir `status.namespace` de vuelta en el Composite?
2. El `tier` mapea a `requests.cpu` con un transform de tipo `map`. ¿Qué pasaría si un usuario pidiera un `tier` válido por el `enum` del XRD pero ausente en el `map` de la Composition? ¿Por qué conviene que las claves del `enum` y del `map` estén sincronizadas, y quién es responsable de cada una?

---

### Bloque 1.4 — Consumir la API (el Claim)

Ahora te ponés en los zapatos del desarrollador: no sabés nada de `Object`, `ProviderConfig` ni `ResourceQuota`. Solo pedís un entorno.

1. Creá un namespace de equipo para el Claim y aplicá el Claim:

   ```bash
   kubectl create namespace payments-team

   kubectl apply -f - <<'EOF'
   apiVersion: platform.acme.io/v1alpha1
   kind: AppEnvironment
   metadata:
     name: payments
     namespace: payments-team
   spec:
     parameters:
       team: payments
       tier: medium
   EOF
   ```

2. Observá la reconciliación con el CLI de Crossplane:

   ```bash
   crossplane beta trace appenvironment/payments -n payments-team
   ```

   Salida esperada una vez estabilizado:

   ```
   NAME                                      SYNCED   READY   STATUS
   AppEnvironment/payments (payments-team)   True     True    Available
   └─ XAppEnvironment/payments-abc12         True     True    Available
      ├─ Object/payments-abc12-ns            True     True    Available
      └─ Object/payments-abc12-quota         True     True    Available
   ```

3. Comprobá que la infraestructura real existe:

   ```bash
   kubectl get ns team-payments
   kubectl get resourcequota -n team-payments team-quota \
     -o jsonpath='{.spec.hard.requests\.cpu}{"\n"}'
   ```

   ```
   NAME            STATUS   AGE
   team-payments   Active   30s
   4
   ```

   (`requests.cpu: 4` confirma que `tier: medium` se resolvió por el `map`.)

4. Leé el `status` que el Composite escribió de vuelta:

   ```bash
   kubectl get appenvironment payments -n payments-team \
     -o jsonpath='{.status.namespace}{"\n"}'
   ```

   ```
   team-payments
   ```

**Preguntas de comprensión (1.4)**

1. Definí con tus palabras la relación **Claim → Composite → Managed Resources** que muestra `crossplane beta trace`. ¿Cuál de esos tres objetos verá y editará el desarrollador, y cuáles son detalle de implementación del platform team?
2. Borrá el Claim con `kubectl delete appenvironment payments -n payments-team`. Sin ejecutarlo aún, predecí qué pasa con el `Namespace team-payments` y el `ResourceQuota`, y explicá qué mecanismo de Kubernetes/Crossplane garantiza ese comportamiento.

---

## Ejercicio 2 — Publicar la abstracción en un Service Catalog (Backstage)

Una API de plataforma que nadie descubre no es autoservicio. En este ejercicio exponés el `AppEnvironment` en **Backstage**: registrás el componente en el **Software Catalog** y creás una **Software Template** (*Scaffolder*) que genera el Claim — el *golden path*.

### Bloque 2.1 — Levantar Backstage y entender el modelo de entidades

1. Creá una app de Backstage (tarda unos minutos la primera vez):

   ```bash
   npx @backstage/create-app@latest --path ./platform-portal
   cd platform-portal
   yarn dev
   ```

   Abrí `http://localhost:3000`. El backend del catálogo queda en `http://localhost:7007`.

2. El catálogo es un **grafo de entidades tipadas**. Creá un archivo descriptor `catalog-info.yaml` que declare un `System`, un `Component` y la `API` que expone la plataforma:

   ```yaml
   # platform-portal/catalog/appenvironment-platform.yaml
   apiVersion: backstage.io/v1alpha1
   kind: System
   metadata:
     name: platform-provisioning
     description: Autoservicio de entornos sobre Crossplane
   spec:
     owner: platform-team
   ---
   apiVersion: backstage.io/v1alpha1
   kind: API
   metadata:
     name: appenvironment-api
     description: API de plataforma para pedir entornos de aplicación
   spec:
     type: openapi
     lifecycle: production
     owner: platform-team
     system: platform-provisioning
     definition: |
       openapi: 3.0.0
       info: { title: AppEnvironment, version: v1alpha1 }
       paths: {}
   ---
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: appenvironment-provisioner
     description: Controller que reconcilia AppEnvironment (Crossplane)
   spec:
     type: service
     lifecycle: production
     owner: platform-team
     system: platform-provisioning
     providesApis:
       - appenvironment-api
   ```

3. Registrá la ubicación del descriptor. Vía UI: **Create… → Register Existing Component** y pegá la ruta/URL del archivo. Vía API REST del catálogo:

   ```bash
   curl -s -X POST http://localhost:7007/api/catalog/locations \
     -H 'Content-Type: application/json' \
     -d '{"type":"file","target":"'"$PWD"'/catalog/appenvironment-platform.yaml"}' | jq .status
   ```

4. Consultá el catálogo **como API** (esto es la clave del tema: el catálogo *es* una API consultable):

   ```bash
   curl -s 'http://localhost:7007/api/catalog/entities/by-query?filter=kind=api,spec.owner=platform-team' \
     | jq -r '.items[].metadata.name'
   ```

   ```
   appenvironment-api
   ```

**Preguntas de comprensión (2.1)**

1. Enumerá el rol de los kinds `System`, `Component` y `API` en el modelo de Backstage y explicá cómo las relaciones (`providesApis`, `system`) convierten al catálogo en un **grafo** en vez de una lista plana.
2. En el paso 4 consultaste el catálogo por HTTP con un `filter`. ¿Por qué "API-driven service catalog" no significa solo "una UI bonita", y qué habilita que el catálogo sea consumible por otras herramientas (CI, dashboards, políticas) además del navegador?

---

### Bloque 2.2 — Crear el golden path (Software Template → Claim de Crossplane)

1. Definí una **Software Template** que le pida al usuario `team` y `tier` y genere el Claim del Ejercicio 1:

   ```yaml
   # platform-portal/catalog/template-appenvironment.yaml
   apiVersion: scaffolder.backstage.io/v1beta3
   kind: Template
   metadata:
     name: request-app-environment
     title: Solicitar un App Environment
     description: Golden path — aprovisiona un entorno vía Crossplane
     tags: [platform, crossplane, self-service]
   spec:
     owner: platform-team
     type: resource
     parameters:
       - title: Parámetros del entorno
         required: [team, tier]
         properties:
           team:
             title: Equipo
             type: string
             pattern: '^[a-z][a-z0-9-]{1,20}$'
           tier:
             title: Tier
             type: string
             enum: [small, medium, large]
             default: small
     steps:
       - id: render
         name: Renderizar el Claim
         action: fetch:template
         input:
           url: ./skeleton
           values:
             team: ${{ parameters.team }}
             tier: ${{ parameters.tier }}
       - id: pr
         name: Abrir Pull Request
         action: publish:github:pull-request
         input:
           repoUrl: github.com?owner=acme&repo=platform-claims
           branchName: appenv-${{ parameters.team }}
           title: 'feat: AppEnvironment para ${{ parameters.team }}'
           description: 'Generado por el golden path de la plataforma.'
     output:
       links:
         - title: Pull Request
           url: ${{ steps.pr.output.remoteUrl }}
   ```

2. Creá el *skeleton* que la template renderiza (el manifiesto que terminará en Git y lo aplicará tu GitOps controller — Argo CD/Flux):

   ```yaml
   # platform-portal/catalog/skeleton/appenvironment.yaml
   apiVersion: platform.acme.io/v1alpha1
   kind: AppEnvironment
   metadata:
     name: ${{ values.team }}
     namespace: ${{ values.team }}-team
   spec:
     parameters:
       team: ${{ values.team }}
       tier: ${{ values.tier }}
   ```

3. Registrá la template igual que en 2.1 (por UI o por `POST /api/catalog/locations`) apuntando a `template-appenvironment.yaml`. Aparecerá en **Create…** como tarjeta *Solicitar un App Environment*.

4. Validá localmente que la template está bien formada antes de commitear:

   ```bash
   yarn backstage-cli repo lint
   ```

**Preguntas de comprensión (2.2)**

1. La template **no** aplica el Claim con `kubectl`: abre un **Pull Request**. Explicá por qué ese diseño (Scaffolder → Git → GitOps → Crossplane) es preferible a que el portal escriba directo contra el API server, y qué garantías gana la plataforma.
2. Compará dónde se valida `tier` en este flujo: en la template (`enum`), en el XRD (`enum`), y en la Composition (`map`). ¿Es redundante? Justificá por qué la defensa en capas es deseable y qué falla cubre cada capa que las otras no.

---

## Ejercicio 3 — Diagnóstico: una abstracción que no reconcilia

En producción, la parte difícil no es crear la API sino diagnosticarla cuando un Claim queda `READY=False`. Vas a **romper** la plataforma a propósito y encontrar la causa raíz de forma metódica.

### Bloque 3.1 — Reproducir la falla

1. Aplicá un Claim que apunta (implícitamente) a un `ProviderConfig` inexistente. Primero, rompé la referencia borrando el `ProviderConfig`:

   ```bash
   kubectl delete providerconfig.kubernetes.crossplane.io default
   ```

2. Creá un Claim nuevo:

   ```bash
   kubectl create namespace billing-team
   kubectl apply -f - <<'EOF'
   apiVersion: platform.acme.io/v1alpha1
   kind: AppEnvironment
   metadata:
     name: billing
     namespace: billing-team
   spec:
     parameters:
       team: billing
       tier: small
   EOF
   ```

3. Observá el estado degradado:

   ```bash
   kubectl get appenvironment billing -n billing-team
   ```

   ```
   NAME      SYNCED   READY   CONNECTION-SECRET   AGE
   billing   True     False                       25s
   ```

**Preguntas de comprensión (3.1)**

1. `SYNCED=True` pero `READY=False`. ¿Qué afirma cada una de esas dos condiciones por separado en Crossplane, y por qué es un error común confundir "el control plane aceptó mi Composition" con "mi infraestructura está lista"?

---

### Bloque 3.2 — Descender por el árbol de recursos

1. Usá el trace para ver **dónde** se corta la cadena:

   ```bash
   crossplane beta trace appenvironment/billing -n billing-team
   ```

   ```
   NAME                                    SYNCED   READY   STATUS
   AppEnvironment/billing (billing-team)   True     False   Waiting: ...
   └─ XAppEnvironment/billing-9f3kd        True     False   Waiting: ...
      ├─ Object/billing-9f3kd-ns           False    -       ReconcileError: ... no such ProviderConfig
      └─ Object/billing-9f3kd-quota        False    -       ReconcileError: ... no such ProviderConfig
   ```

2. Confirmá la causa en los `Events` del Managed Resource:

   ```bash
   OBJ=$(kubectl get objects.kubernetes.crossplane.io \
     -l crossplane.io/claim-name=billing -o name | head -1)
   kubectl describe "$OBJ" | sed -n '/Events:/,$p'
   ```

   ```
   Events:
     Type     Reason                   Age              From                   Message
     ----     ------                   ----             ----                   -------
     Warning  CannotResolveResourceReferences  12s (x5)  managed/object   cannot get referenced ProviderConfig: providerconfigs.kubernetes.crossplane.io "default" not found
   ```

3. Reparación: recreá el `ProviderConfig` (paso 5 del Bloque 1.1) y observá la reconciliación automática:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: kubernetes.crossplane.io/v1alpha1
   kind: ProviderConfig
   metadata:
     name: default
   spec:
     credentials:
       source: InjectedIdentity
   EOF

   kubectl wait appenvironment/billing -n billing-team \
     --for=condition=Ready --timeout=120s
   ```

   ```
   appenvironment.platform.acme.io/billing condition met
   ```

**Preguntas de comprensión (3.2)**

1. Describí la **escalera de diagnóstico** que usaste: Claim → `beta trace` → Managed Resource concreto → `Events`. ¿Por qué es más eficiente que empezar leyendo logs del pod de Crossplane, y en qué caso *sí* tendrías que bajar a los logs del provider o de la función?
2. No reiniciaste nada: apenas recreaste el `ProviderConfig`, el entorno se completó. ¿Qué modelo de ejecución de Kubernetes/Crossplane explica esa auto-recuperación, y qué implica para el diseño de una plataforma resiliente frente a fallas transitorias?

---

## Fuentes oficiales

- CNCF — *Cloud Native Platform Engineering Associate (CNPA) Curriculum*: <https://github.com/cncf/curriculum> (`CNPA_Curriculum.pdf`)
- Crossplane — *Composite Resource Definitions (XRDs)*: <https://docs.crossplane.io/latest/concepts/composite-resource-definitions/>
- Crossplane — *Compositions*: <https://docs.crossplane.io/latest/concepts/compositions/>
- Crossplane — *Composition Functions*: <https://docs.crossplane.io/latest/concepts/composition-functions/>
- Crossplane — *Claims*: <https://docs.crossplane.io/latest/concepts/claims/>
- Crossplane — *Troubleshoot / `crossplane beta trace`*: <https://docs.crossplane.io/latest/cli/command-reference/#beta-trace>
- provider-kubernetes: <https://github.com/crossplane-contrib/provider-kubernetes>
- Backstage — *Software Catalog*: <https://backstage.io/docs/features/software-catalog/>
- Backstage — *Descriptor Format (entities)*: <https://backstage.io/docs/features/software-catalog/descriptor-format>
- Backstage — *Software Templates (Scaffolder)*: <https://backstage.io/docs/features/software-templates/>
- Backstage — *Catalog REST API*: <https://backstage.io/docs/features/software-catalog/software-catalog-api>

---

<details>
<summary><strong>Respuestas — verificación de comprensión</strong></summary>

### Ejercicio 1

**1.1 · 1.** El `Provider` es el *paquete* que instala el controller y los CRDs de los Managed Resources (define *qué* tipos de infraestructura sabe manejar Crossplane). El `ProviderConfig` es la *configuración de acceso* que usan esas reconciliaciones: qué credenciales/identidad y contra qué endpoint. Se separan porque un mismo Provider suele necesitar varias configuraciones (por cuenta, entorno o tenant). Usamos `source: InjectedIdentity` porque `provider-kubernetes` actúa contra *este mismo* cluster: reutiliza la `ServiceAccount` del pod del provider en vez de montar un kubeconfig en un `Secret`. En un provider de nube (AWS/GCP) sí pondrías un `Secret` con credenciales o, mejor, Workload Identity/IRSA.

**1.1 · 2.** Las llamadas al API server se ejecutan con la identidad de la `ServiceAccount` del provider (`crossplane-system:provider-kubernetes-…`), no con la del usuario que creó el Claim. Es un control de seguridad central: el desarrollador solo tiene permiso para crear un `AppEnvironment` en su namespace; el *poder* de crear `Namespaces` o `ResourceQuotas` está confinado a la SA del provider, gobernada por el platform team. Así se implementa el privilegio mínimo y se evita que el autoservicio implique dar `cluster-admin` a cada equipo.

**1.2 · 1.** El `Claim` (`AppEnvironment`, namespaced) vive en el namespace del equipo, así que RBAC namespaced alcanza para dejar que ese equipo cree/edite solo *sus* Claims. El `Composite` (`XAppEnvironment`, cluster-scoped) es el objeto "real" que orquesta recursos que muchas veces son cluster-wide (como `Namespaces`); vive fuera del alcance del equipo. Esa asimetría te da autoservicio acotado por namespace sin exponer objetos cluster-scoped ni permisos globales a los desarrolladores.

**1.2 · 2.** Lo rechaza el **API server de Kubernetes** en la fase de *schema validation* del `openAPIV3Schema` (derivado del XRD), en el momento del `kubectl apply`, antes de que ningún controller de Crossplane vea el objeto. Cumple *shift-left*: el error se detecta lo más temprano y barato posible (validación de admisión), con un mensaje claro, en vez de fallar a mitad de una reconciliación que ya empezó a crear infraestructura.

**1.3 · 1.** `FromCompositeFieldPath` lee un valor del Composite (`spec.parameters.team`) y lo *escribe* en el Managed Resource (el nombre del `Namespace`), transformándolo a `team-<team>`. `ToCompositeFieldPath` hace lo inverso: toma un valor del Managed Resource ya resuelto (`…manifest.metadata.name`) y lo escribe *de vuelta* en `status.namespace` del Composite. Sirve para exponer resultados de la reconciliación (el namespace efectivamente creado) al consumidor, que lo lee en el `status` de su Claim sin conocer los objetos internos.

**1.3 · 2.** Si el `tier` es válido para el `enum` pero no existe en el `map`, el transform `map` falla la reconciliación de ese recurso (no encuentra la clave) y el Managed Resource no se materializa como esperabas. Por eso las claves del `enum` (contrato de la API, en el XRD) y del `map` (implementación, en la Composition) deben mantenerse sincronizadas. El XRD es responsabilidad del *diseñador de la API*; la Composition, del *implementador*. Es un acoplamiento real a vigilar cuando agregás un tier nuevo: tocás ambos.

**1.4 · 1.** `Claim → Composite → Managed Resources`: el **Claim** (`AppEnvironment`) es la petición namespaced del desarrollador; crea automáticamente un **Composite** (`XAppEnvironment`) cluster-scoped que la Composition expande en **Managed Resources** (los `Object` de provider-kubernetes, que a su vez crean el `Namespace` y el `ResourceQuota`). El desarrollador solo ve y edita el Claim; el Composite y los Managed Resources son detalle de implementación del platform team.

**1.4 · 2.** Al borrar el Claim, Crossplane elimina en cascada el Composite y, con él, los Managed Resources; el `Namespace team-payments` y su `ResourceQuota` se borran. El mecanismo son las **owner references** y los **finalizers**: cada objeto hijo tiene como owner a su padre, y la garbage collection de Kubernetes (más los finalizers de Crossplane que aseguran el borrado ordenado en el provider) propaga el delete de arriba hacia abajo.

### Ejercicio 2

**2.1 · 1.** `System` agrupa recursos que colaboran para una capacidad (aquí, el aprovisionamiento). `Component` es una unidad de software con dueño y ciclo de vida (el controller/servicio). `API` es un contrato consumible que un componente *provee* o *consume*. Las relaciones `providesApis`, `system`, `owner` conectan entidades entre sí: el catálogo deja de ser una lista y se vuelve un **grafo** navegable (quién provee qué API, qué componentes forman un sistema, quién es dueño), lo que habilita impact analysis, ownership y descubrimiento.

**2.1 · 2.** Porque el catálogo expone una **API REST** (`/api/catalog/entities…`) con filtros: cualquier herramienta —un pipeline de CI, un chequeo de políticas, un dashboard de SLOs, un bot— puede consultar el estado de la plataforma programáticamente. "API-driven" significa que el catálogo es una fuente de verdad consultable e integrable, no solo un portal para humanos. Eso permite automatizar auditorías de ownership, gates de despliegue por lifecycle, etc.

**2.2 · 1.** Porque separa *intención* de *aplicación*: el Scaffolder genera un manifiesto y abre un PR; el merge queda auditado y revisable, y es el controller de GitOps (Argo CD/Flux) el que lo aplica al cluster. Ganás trazabilidad (Git como fuente de verdad), revisión/aprobación, rollback por `git revert`, y evitás darle al portal credenciales de escritura directas contra el API server de producción. El portal nunca es un actor privilegiado en runtime.

**2.2 · 2.** No es redundancia inútil, es **defensa en capas**: la template (`enum`) valida *en el punto de entrada de UX*, con feedback inmediato al usuario antes de generar nada. El XRD (`enum`) valida *en el API server* a cualquier Claim, venga del portal, de `kubectl` o de otra herramienta — cubre el caso en que alguien saltea el portal. La Composition (`map`) traduce a la implementación concreta y falla si el tier no tiene mapeo. Cada capa protege un límite distinto (UX, API, implementación); una sola no cubriría a los consumidores que no pasan por ella.

### Ejercicio 3

**3.1 · 1.** `SYNCED` afirma que Crossplane pudo *reconciliar la composición*: matcheó el Composite con una Composition válida y creó/actualizó los Managed Resources deseados. `READY` afirma que esos recursos existen y están *operativos* según el provider. Confundirlas lleva a creer que "está listo" cuando en realidad el control plane solo aceptó el plan pero el provider todavía no materializó (o falló en materializar) la infraestructura real.

**3.2 · 1.** La escalera es: mirar el **Claim** (síntoma: `READY=False`) → `crossplane beta trace` para ver **en qué nodo del árbol** se rompe la cadena → ir al **Managed Resource** concreto en error → leer sus **`Events`/`status.conditions`** para el mensaje de causa raíz. Es más eficiente que empezar por los logs del pod porque el trace y los Events te llevan directo al recurso y al motivo sin filtrar ruido. Bajás a los **logs del provider o de la función** solo cuando el mensaje del Event es genérico o insuficiente (p. ej., un panic de la función de composición, un timeout del provider, un bug), no como primer paso.

**3.2 · 2.** El modelo es el **bucle de reconciliación continuo** (controllers *level-triggered*, no *edge-triggered*): Crossplane compara sin cesar el estado deseado con el observado y reintenta con backoff. La falla por `ProviderConfig` faltante era transitoria respecto del estado deseado; al recrearlo, la siguiente iteración del loop encontró todo lo necesario y convergió sola. Implica que una plataforma bien diseñada tolera fallas transitorias sin intervención manual ni reinicios: el sistema se auto-cura hacia el estado declarado.

</details>