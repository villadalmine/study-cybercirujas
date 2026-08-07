# Ejercicios guiados — Tema 4.2: APIs for Self-Service Platforms (Custom Resource Definitions)

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) · versión 2025-04-01
> **Peso en el examen:** 3.0
>
> **Objetivo de la práctica:** construir, paso a paso, la superficie de API que un equipo de plataforma expone a sus usuarios internos. Vas a extender el Kubernetes API server con una `CustomResourceDefinition` (CRD), endurecerla con validación estructural y CEL, dotarla de ergonomía de self-service (subresources, printer columns, categories) y versionarla con una estrategia de conversión — que es exactamente el patrón que sostiene un Internal Developer Platform (IDP) construido sobre el control plane de Kubernetes.
>
> **Prerrequisitos:** un cluster de práctica donde tengas permisos de `cluster-admin` (kind, minikube, k3d o similar), `kubectl` v1.29+ y acceso a `curl`/`jq`. Los ejemplos asumen Kubernetes ≥ 1.29, donde las CEL validation rules (`x-kubernetes-validations`) ya son GA.
>
> **Advertencia de entorno:** creá un namespace descartable y borrá los recursos al final. Una CRD es un objeto **cluster-scoped**: afecta a todo el cluster y a la discovery de todos los usuarios.

```bash
kubectl create namespace platform-lab
kubectl config set-context --current --namespace=platform-lab
```

---

## Ejercicio 1 — Ubicar los puntos de extensión del API server

Antes de escribir una sola CRD conviene ver *dónde* encaja en la arquitectura del API server. Kubernetes tiene dos mecanismos de extensión de la capa de API: **CRDs** (declarativas, servidas por el propio `kube-apiserver` a través del `apiextensions-apiserver` embebido) y el **aggregation layer** (un `APIService` que delega a tu propio servidor de API). Este ejercicio los distingue.

1. Listá los API groups y versiones que el cluster sirve hoy:

   ```bash
   kubectl api-versions | sort | head -n 20
   ```

   Salida esperada (abreviada):

   ```
   admissionregistration.k8s.io/v1
   apiextensions.k8s.io/v1
   apiregistration.k8s.io/v1
   apps/v1
   authentication.k8s.io/v1
   authorization.k8s.io/v1
   ...
   v1
   ```

2. Fijate que `apiextensions.k8s.io/v1` es el grupo que sirve el recurso `CustomResourceDefinition`, y `apiregistration.k8s.io/v1` es el del aggregation layer (`APIService`). Confirmalo:

   ```bash
   kubectl api-resources --api-group=apiextensions.k8s.io
   kubectl api-resources --api-group=apiregistration.k8s.io
   ```

   Salida esperada:

   ```
   NAME                        SHORTNAMES   APIVERSION                NAMESPACED   KIND
   customresourcedefinitions   crd,crds     apiextensions.k8s.io/v1   false        CustomResourceDefinition

   NAME          SHORTNAMES   APIVERSION                 NAMESPACED   KIND
   apiservices   apisvc       apiregistration.k8s.io/v1  false        APIService
   ```

3. Inspeccioná los `APIService` registrados y notá cuáles están respaldados por un aggregated API server (columna con un `Service`) y cuáles son *locales* (servidos por el propio apiserver):

   ```bash
   kubectl get apiservices | grep -Ev "Local" | head
   ```

   En un cluster con `metrics-server` verás algo como:

   ```
   NAME                     SERVICE                      AVAILABLE   AGE
   v1beta1.metrics.k8s.io   kube-system/metrics-server   True        7d
   ```

**Preguntas de comprensión (bloque 1)**

- 1a. ¿Por qué una CRD **no** necesita un `APIService` propio para que su recurso aparezca en `kubectl api-resources`, mientras que un aggregated API server sí?
- 1b. Como platform engineer, tenés que ofrecer un recurso `Database` de self-service. ¿En qué situación elegirías el aggregation layer en lugar de una CRD? Nombrá al menos dos capacidades que el aggregation layer da y la CRD no.
- 1c. ¿Qué implica que `CustomResourceDefinition` sea `NAMESPACED = false`?

---

## Ejercicio 2 — Definir una CRD estructural mínima y crear una instancia

Vamos a exponer un recurso `Database` en el group `platform.example.com`. Este es el "contrato" que tus usuarios internos van a consumir; el controller que lo reconcilie queda fuera de este tema (Tema 4.x sobre operators), pero la **API** ya es útil por sí sola como registro declarativo.

1. Guardá esta definición en `database-crd-v1.yaml`. Es una CRD **estructural** (`apiextensions.k8s.io/v1` obliga a schema estructural):

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: databases.platform.example.com   # DEBE ser <plural>.<group>
   spec:
     group: platform.example.com
     scope: Namespaced
     names:
       plural: databases
       singular: database
       kind: Database
       listKind: DatabaseList
     versions:
       - name: v1alpha1
         served: true
         storage: true
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 properties:
                   engine:
                     type: string
                   version:
                     type: string
                   sizeGi:
                     type: integer
                 required:
                   - engine
                   - version
   ```

2. Aplicá la CRD y esperá a que el establishment controller la marque como `Established`:

   ```bash
   kubectl apply -f database-crd-v1.yaml
   kubectl wait --for=condition=Established crd/databases.platform.example.com --timeout=60s
   ```

   Salida esperada:

   ```
   customresourcedefinition.apiextensions.k8s.io/databases.platform.example.com created
   customresourcedefinition.apiextensions.k8s.io/databases.platform.example.com condition met
   ```

3. Verificá que el nuevo recurso ya aparece en discovery — el apiserver actualizó su OpenAPI y la tabla de recursos:

   ```bash
   kubectl api-resources --api-group=platform.example.com
   ```

   ```
   NAME        SHORTNAMES   APIVERSION                          NAMESPACED   KIND
   databases                platform.example.com/v1alpha1       true         Database
   ```

4. Creá una instancia (Custom Resource, CR) del nuevo tipo en `db-instance.yaml`:

   ```yaml
   apiVersion: platform.example.com/v1alpha1
   kind: Database
   metadata:
     name: orders-db
   spec:
     engine: postgres
     version: "16"
     sizeGi: 20
   ```

   ```bash
   kubectl apply -f db-instance.yaml
   kubectl get databases
   ```

   ```
   NAME        AGE
   orders-db   4s
   ```

5. Probá el límite del schema mínimo: pedí un campo que no declaraste.

   ```bash
   kubectl get database orders-db -o jsonpath='{.spec.replicas}'; echo
   ```

   Devuelve vacío (no existe). Ahora intentá *escribir* un campo no declarado:

   ```bash
   kubectl patch database orders-db --type=merge -p '{"spec":{"replicas":3}}'
   ```

   Con `x-kubernetes-preserve-unknown-fields` en su valor por defecto (`false`) en un schema estructural, el apiserver **poda** (prune) los campos desconocidos: el patch se acepta pero `spec.replicas` se descarta silenciosamente. Comprobalo:

   ```bash
   kubectl get database orders-db -o jsonpath='{.spec.replicas}'; echo   # sigue vacío
   ```

**Preguntas de comprensión (bloque 2)**

- 2a. ¿Por qué `metadata.name` de la CRD debe ser exactamente `databases.platform.example.com` y no un nombre arbitrario?
- 2b. ¿Qué significa que exactamente una versión tenga `storage: true`, y qué pasaría si marcaras dos con `storage: true`?
- 2c. En el paso 5, el campo `spec.replicas` desapareció sin error. Explicá el mecanismo de *pruning* y por qué es una decisión de diseño deseable para una API de self-service (pista: pensá en el schema estructural y en `x-kubernetes-preserve-unknown-fields`).
- 2d. La instancia usa `version: "16"` entre comillas. ¿Qué habría pasado con `version: 16` sin comillas, dado que el schema declara `version` como `string`?

---

## Ejercicio 3 — Validación declarativa: OpenAPI v3 + reglas CEL

Un contrato de self-service sin validación traslada al controller (y a los tickets de soporte) todos los errores. Movemos la validación al borde: el apiserver rechaza lo inválido **antes** de persistirlo. Combinamos restricciones OpenAPI v3 (`enum`, `pattern`, `minimum`) con **CEL** (`x-kubernetes-validations`) para invariantes que OpenAPI no puede expresar.

1. Reemplazá el schema de la versión por esta variante endurecida (editá `database-crd-v1.yaml`, sección `schema.openAPIV3Schema`, y reaplicá):

   ```yaml
           schema:
             openAPIV3Schema:
               type: object
               required: ["spec"]
               properties:
                 spec:
                   type: object
                   required: ["engine", "version"]
                   properties:
                     engine:
                       type: string
                       enum: ["postgres", "mysql", "mariadb"]
                     version:
                       type: string
                       pattern: '^[0-9]+(\.[0-9]+)?$'
                     sizeGi:
                       type: integer
                       minimum: 1
                       maximum: 1024
                       default: 10
                     highAvailability:
                       type: boolean
                       default: false
                     replicas:
                       type: integer
                       minimum: 1
                       maximum: 5
                   x-kubernetes-validations:
                     - rule: "!has(self.highAvailability) || !self.highAvailability || (has(self.replicas) && self.replicas >= 3)"
                       message: "highAvailability=true requiere replicas >= 3"
                     - rule: "self.engine != 'mysql' || self.version != '5.7'"
                       message: "MySQL 5.7 está EOL y no se permite en esta plataforma"
   ```

   ```bash
   kubectl apply -f database-crd-v1.yaml
   ```

2. Probá que las restricciones OpenAPI rechazan valores inválidos. Cada comando debe **fallar**:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: Database
   metadata: { name: bad-engine }
   spec: { engine: mongodb, version: "7" }
   EOF
   ```

   Salida esperada:

   ```
   The Database "bad-engine" is invalid: spec.engine: Unsupported value: "mongodb": supported values: "postgres", "mysql", "mariadb"
   ```

3. Probá que CEL rechaza una combinación *semánticamente* inválida que OpenAPI no podría atrapar (dependencia entre campos):

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: Database
   metadata: { name: bad-ha }
   spec: { engine: postgres, version: "16", highAvailability: true, replicas: 1 }
   EOF
   ```

   Salida esperada:

   ```
   The Database "bad-ha" is invalid: spec: Invalid value: "object": highAvailability=true requiere replicas >= 3
   ```

4. Confirmá que los **defaults** se materializan. Creá una instancia mínima y leé los campos que no pusiste:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: platform.example.com/v1alpha1
   kind: Database
   metadata: { name: analytics-db }
   spec: { engine: mariadb, version: "11" }
   EOF
   kubectl get database analytics-db -o jsonpath='{.spec.sizeGi}{" "}{.spec.highAvailability}'; echo
   ```

   Salida esperada:

   ```
   10 false
   ```

**Preguntas de comprensión (bloque 3)**

- 3a. Diferenciá qué clase de validación va en OpenAPI v3 (`enum`, `pattern`, `minimum`) y cuál requiere CEL. ¿Por qué la regla "highAvailability implica replicas ≥ 3" no se puede expresar en OpenAPI v3 puro?
- 3b. En el paso 4, `sizeGi` resultó `10` aunque el usuario no lo puso. ¿En qué momento del request pipeline se aplican los `default`, y por qué eso implica que un default **cambia** el objeto persistido (a diferencia de un valor asumido por el controller)?
- 3c. ¿Qué ventaja operativa tiene la validación CEL frente a un ValidatingAdmissionWebhook para la misma regla? Nombrá al menos dos (pensá en disponibilidad, latencia y operación).
- 3d. La regla `pattern: '^[0-9]+(\.[0-9]+)?$'` acepta `"16"` y `"5.7"`. ¿Cómo bloqueaste específicamente `mysql 5.7` sin prohibir `postgres 5.7`? ¿Qué te dice esto sobre el orden lógico entre validación de *forma* y validación de *política*?

---

## Ejercicio 4 — Ergonomía de self-service: subresources, printer columns, categories y shortNames

Una API de plataforma se usa a diario desde `kubectl`. Este ejercicio la hace *ergonómica* y, sobre todo, activa el **status subresource** — el que separa el "estado deseado" (`spec`, del usuario) del "estado observado" (`status`, del controller), habilitando además `/scale`.

1. Añadí a la versión `v1alpha1` (bajo el mismo entry en `versions[]`) los bloques `subresources`, `additionalPrinterColumns`, y a `spec.names` los `shortNames` y `categories`. El fragmento a integrar:

   ```yaml
       names:
         plural: databases
         singular: database
         kind: Database
         listKind: DatabaseList
         shortNames: ["db", "dbs"]
         categories: ["platform", "all"]
   ```

   ```yaml
       versions:
         - name: v1alpha1
           served: true
           storage: true
           subresources:
             status: {}
             scale:
               specReplicasPath: .spec.replicas
               statusReplicasPath: .status.readyReplicas
               labelSelectorPath: .status.selector
           additionalPrinterColumns:
             - name: Engine
               type: string
               jsonPath: .spec.engine
             - name: Version
               type: string
               jsonPath: .spec.version
             - name: Phase
               type: string
               jsonPath: .status.phase
             - name: Age
               type: date
               jsonPath: .metadata.creationTimestamp
           schema:
             openAPIV3Schema:
               type: object
               # ... (mismo spec del Ejercicio 3) ...
               properties:
                 spec: { ... }
                 status:
                   type: object
                   properties:
                     phase:
                       type: string
                     readyReplicas:
                       type: integer
                     selector:
                       type: string
   ```

   > **Importante:** para que `/scale` funcione, `spec.replicas` y los paths de status deben existir en el schema. Reaplicá la CRD completa con estos añadidos.

2. Verificá los shortNames, categories y las columnas:

   ```bash
   kubectl get db                       # usa el shortName
   kubectl get all --namespace platform-lab | grep -i database   # aparece por la category "all"
   kubectl get category platform 2>/dev/null; kubectl get databases -o wide
   ```

   Salida esperada de `kubectl get databases`:

   ```
   NAME           ENGINE     VERSION   PHASE   AGE
   orders-db      postgres   16                12m
   analytics-db   mariadb    11                3m
   ```

   (La columna `PHASE` está vacía porque ningún controller escribió `status` todavía.)

3. Demostrá que el **status subresource** desacopla spec de status. Primero, intentá escribir `status` con un `apply` normal — se ignora:

   ```bash
   kubectl patch database orders-db --type=merge -p '{"status":{"phase":"Provisioning"}}'
   kubectl get database orders-db -o jsonpath='{.status.phase}'; echo   # vacío: /status es un endpoint aparte
   ```

   Ahora escribilo por el endpoint correcto (`--subresource=status`), simulando lo que haría el controller:

   ```bash
   kubectl patch database orders-db --subresource=status --type=merge \
     -p '{"status":{"phase":"Ready","readyReplicas":3}}'
   kubectl get db orders-db -o wide
   ```

   ```
   NAME        ENGINE     VERSION   PHASE   AGE
   orders-db   postgres   16        Ready   14m
   ```

4. Usá el scale subresource — el mismo verbo `kubectl scale` que `Deployment`, ahora sobre tu recurso custom:

   ```bash
   kubectl patch database orders-db --type=merge -p '{"spec":{"replicas":3}}'
   kubectl scale database orders-db --replicas=4
   kubectl get database orders-db -o jsonpath='{.spec.replicas}'; echo   # 4
   ```

**Preguntas de comprensión (bloque 4)**

- 4a. ¿Por qué habilitar el `status` subresource es importante para el patrón operator/controller? ¿Qué garantía sobre RBAC y sobre el `metadata.generation` obtenés al separarlo del `spec`?
- 4b. Un usuario con RBAC de `update` sobre `databases` (pero no sobre `databases/status`) hace `kubectl apply` de un manifiesto que incluye un bloque `status`. ¿Qué le pasa a ese `status`? ¿Por qué esto protege al controller?
- 4c. ¿Qué hace posible el `scale` subresource más allá de `kubectl scale`? (Pensá en HorizontalPodAutoscaler apuntando a un `scaleTargetRef` custom.)
- 4d. Añadiste la category `all`. ¿Qué efecto — potencialmente indeseado — tiene eso sobre `kubectl get all`, y por qué un equipo de plataforma podría preferir una category propia como `platform` en su lugar?

---

## Ejercicio 5 — Versionado de la API y estrategia de conversión

Una plataforma evoluciona: `v1alpha1` → `v1beta1` → `v1`. El apiserver almacena **una sola** versión (la `storage`) y debe convertir al vuelo hacia/desde las demás. Este ejercicio agrega `v1beta1`, muestra la conversión trivial `None` y explica cuándo se necesita un `Webhook`.

1. Agregá una segunda versión sirviendo el mismo shape (conversión `None` sólo es válida si las versiones son *estructuralmente compatibles* — mismos campos). Añadí bajo `spec` el bloque `conversion` y un segundo entry en `versions[]`:

   ```yaml
     conversion:
       strategy: None
     versions:
       - name: v1alpha1
         served: true
         storage: false        # ya no es la de almacenamiento
         # ... schema, subresources, printerColumns idénticos ...
       - name: v1beta1
         served: true
         storage: true         # nueva versión de almacenamiento
         # ... mismo schema/subresources/printerColumns ...
   ```

   ```bash
   kubectl apply -f database-crd-v1.yaml
   kubectl wait --for=condition=Established crd/databases.platform.example.com --timeout=60s
   ```

2. Leé el **mismo** objeto por dos versiones distintas — el apiserver lo convierte transparentemente:

   ```bash
   kubectl get database.v1alpha1.platform.example.com orders-db -o jsonpath='{.apiVersion}'; echo
   kubectl get database.v1beta1.platform.example.com orders-db -o jsonpath='{.apiVersion}'; echo
   ```

   ```
   platform.example.com/v1alpha1
   platform.example.com/v1beta1
   ```

3. Inspeccioná qué versiones *existen* en etcd. El campo `status.storedVersions` de la CRD registra toda versión que alguna vez fue de almacenamiento — clave para poder retirar una versión sin romper objetos viejos:

   ```bash
   kubectl get crd databases.platform.example.com -o jsonpath='{.status.storedVersions}'; echo
   ```

   ```
   ["v1alpha1","v1beta1"]
   ```

4. Simulá la migración de storage antes de retirar `v1alpha1`. Para que `storedVersions` deje de incluir `v1alpha1`, todos los objetos deben reescribirse en la nueva storage version (`kubectl` no tiene comando nativo; en producción se usa el `storage-version-migrator` o un `kubectl get ... | kubectl apply`):

   ```bash
   # reescribe cada Database en la storage version actual (v1beta1)
   kubectl get databases -o json | kubectl apply -f -
   ```

   Luego editarías la CRD para poner `served: false` en `v1alpha1` y, sólo cuando `status.storedVersions` ya no lo liste, quitarlo de `versions[]`.

**Preguntas de comprensión (bloque 5)**

- 5a. Explicá la diferencia entre `served` y `storage` en una versión de CRD. ¿Puede una versión tener `served: false, storage: true`? ¿Y `served: true, storage: false`?
- 5b. ¿Por qué la estrategia `conversion.strategy: None` sólo es aceptable cuando los schemas de las versiones son compatibles, y qué límite exacto impone `None`? (Pista: ¿qué hace `None` con `apiVersion` y con los campos?)
- 5c. Vas a renombrar `sizeGi` (integer, GiB) a `sizeBytes` (integer, bytes) entre `v1beta1` y `v1`. ¿Por qué `None` ya no alcanza y necesitás un conversion webhook? Describí qué recibe y qué devuelve ese webhook (`ConversionReview`).
- 5d. ¿Qué rol juega `status.storedVersions` en la retirada segura de una versión, y por qué es peligroso quitar una versión de `versions[]` mientras aún figura ahí?

---

## Ejercicio 6 — Gobernanza del self-service: RBAC por recurso y limpieza

La razón de ser de una CRD en platform engineering es **delegar** de forma segura. Este ejercicio cierra el círculo: das a un equipo acceso *sólo* a su recurso, sin tocar el resto del cluster, y limpiás.

1. Creá un `Role` que otorgue self-service sobre `databases` en el namespace, sin acceso al `status` subresource (ese lo maneja el controller):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: database-self-service
     namespace: platform-lab
   rules:
     - apiGroups: ["platform.example.com"]
       resources: ["databases"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     # nótese: NO se incluye "databases/status" ni "databases/scale"
   ```

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata: { name: database-self-service, namespace: platform-lab }
   rules:
     - apiGroups: ["platform.example.com"]
       resources: ["databases"]
       verbs: ["get","list","watch","create","update","patch","delete"]
   EOF
   ```

2. Verificá con `kubectl auth can-i`, impersonando a un service account ficticio, que puede gestionar databases pero no escribir su status:

   ```bash
   kubectl auth can-i create databases.platform.example.com \
     --as=system:serviceaccount:platform-lab:app-team -n platform-lab
   kubectl auth can-i update databases.platform.example.com/status \
     --as=system:serviceaccount:platform-lab:app-team -n platform-lab
   ```

   Salida esperada:

   ```
   yes
   no
   ```

3. Limpieza. Borrar la CRD **borra en cascada todas sus instancias** — es una operación cluster-wide, hacela con conciencia:

   ```bash
   kubectl delete crd databases.platform.example.com
   kubectl delete namespace platform-lab
   ```

   Salida esperada:

   ```
   customresourcedefinition.apiextensions.k8s.io "databases.platform.example.com" deleted
   namespace "platform-lab" deleted
   ```

**Preguntas de comprensión (bloque 6)**

- 6a. Al borrar la CRD desaparecieron todas las `Database`. Explicá el mecanismo (pensá en el `CustomResourceCleanupController` y en los finalizers) y por qué esto es distinto de borrar un `APIService` del aggregation layer.
- 6b. En el RBAC del paso 1 diste `databases` pero no `databases/status`. ¿Cómo se traduce ese `/status` en la sintaxis de RBAC y por qué un equipo de plataforma separa esos dos verbos entre el usuario y el controller?
- 6c. ¿Por qué `kubectl auth can-i` es una herramienta central para un platform engineer que expone APIs de self-service, en comparación con probar los permisos "a mano" creando objetos?

---

## Respuestas

<details>
<summary><strong>Mostrar / ocultar las respuestas</strong></summary>

### Bloque 1

- **1a.** Las CRDs son servidas por el `apiextensions-apiserver` **embebido** dentro de `kube-apiserver`: cuando aplicás una CRD, el propio apiserver crea el handler REST, actualiza su documento OpenAPI y publica el recurso en discovery. No hay un proceso externo, así que no hace falta un `APIService` para "enrutar" el tráfico. Un aggregated API server, en cambio, es un binario que corre **fuera** del apiserver; el objeto `APIService` es justamente el registro que le dice al apiserver "para el group/version `X`, delegá (proxy) las peticiones a este `Service`".
- **1b.** El aggregation layer conviene cuando necesitás lógica que el modelo declarativo de CRD no soporta: (1) **storage no-etcd** o cómputo al vuelo (p. ej. `metrics.k8s.io` calcula datos, no los persiste); (2) **operaciones/subresources custom** con verbos arbitrarios (imposible con CRDs, limitadas a `status` y `scale`); (3) **validación/side-effects imperativos** en la propia ruta de servido; (4) control fino sobre protocolo, campos calculados o vistas distintas del mismo dato. La contracara: operarlo es mucho más costoso (alta disponibilidad, certificados, versionado propio). Para el 95% de las APIs de plataforma, una CRD alcanza.
- **1c.** Que `CustomResourceDefinition` es un objeto **cluster-scoped**: no vive dentro de un namespace, existe una sola vez para todo el cluster y su discovery afecta a todos los usuarios. (Distinto de las *instancias* `Database`, que definimos `Namespaced`.)

### Bloque 2

- **2a.** El apiserver deriva la ruta REST del recurso de la CRD y **exige** que `metadata.name` sea exactamente `<spec.names.plural>.<spec.group>`. Es una invariante de integridad: garantiza un único nombre canónico por (plural, group) y evita colisiones. Un nombre distinto es rechazado en la validación de la propia CRD.
- **2b.** `storage: true` marca la versión en la que los objetos se **serializan y persisten en etcd**. Debe haber **exactamente una**. Si marcaras dos, la CRD es rechazada por el apiserver (`must have exactly one version marked as storage version`), porque un objeto no puede persistirse en dos formatos a la vez.
- **2c.** En un schema estructural con `x-kubernetes-preserve-unknown-fields` en su valor por defecto (`false`), el apiserver hace **pruning**: cualquier campo que el request traiga y que el schema no declare se **elimina** antes de persistir. Por eso `spec.replicas` desapareció sin error. Es deseable en self-service porque hace el contrato **explícito y cerrado**: el objeto guardado sólo contiene lo que la API define, no basura ni typos silenciosos que un controller podría malinterpretar, y evita que campos "colados" se conviertan en dependencias de facto.
- **2d.** El schema declara `version` como `string`. Sin comillas, `16` es un integer en YAML; el apiserver lo rechazaría con un error de tipo (`spec.version: Invalid value: "integer": spec.version in body must be of type string`). Las comillas fuerzan el tipo string, que es lo que el schema espera.

### Bloque 3

- **3a.** OpenAPI v3 valida **un campo a la vez** contra restricciones estáticas: `enum` (conjunto cerrado), `pattern` (regex), `minimum`/`maximum`, `required`, tipos. No puede expresar relaciones **entre** campos. "highAvailability implica replicas ≥ 3" es una restricción *cross-field* (el valor válido de un campo depende de otro), y eso sólo lo captura **CEL** en `x-kubernetes-validations`, que evalúa una expresión sobre todo el objeto (`self`).
- **3b.** Los `default` se aplican en el apiserver durante la fase de **defaulting**, justo después de decodificar el objeto y **antes** de validarlo y persistirlo. Por eso `sizeGi: 10` quedó **escrito en etcd**: el objeto persistido *contiene* el default, no es un valor que el controller asume en runtime. Consecuencia práctica: `kubectl get -o yaml` muestra el `10`, y cambiar el default de la CRD **no** reescribe objetos ya existentes.
- **3c.** Ventajas de CEL frente a un ValidatingAdmissionWebhook: (1) **sin dependencia externa** — no hay un pod/Service que pueda caerse y bloquear (o, mal configurado, dejar pasar) las escrituras; la regla vive en la propia CRD; (2) **latencia** — la evaluación es in-process, sin round-trip de red; (3) **operación** — nada que desplegar, certificar (TLS), versionar ni monitorear; la regla se versiona junto al schema; (4) menor superficie de fallo (`failurePolicy`, timeouts, webhooks colgados). El webhook sólo sigue siendo necesario para validaciones que requieren I/O externo o estado que CEL no puede ver.
- **3d.** El `pattern` valida **forma** (que `version` sea un número tipo `16` o `5.7`), sin saber nada de política. La prohibición de `mysql 5.7` es una regla **de política** que combina dos campos, y la expresaste en CEL: `self.engine != 'mysql' || self.version != '5.7'`. Como sólo se dispara cuando `engine == mysql`, `postgres 5.7` pasa. La lección: la validación de *forma* (OpenAPI) y la de *política* (CEL) son capas distintas y ortogonales; primero se comprueba que el dato tenga la forma correcta, después que la combinación sea aceptable.

### Bloque 4

- **4a.** El `status` subresource crea un **endpoint REST separado** (`/status`) para el estado observado. Beneficios: (1) **RBAC independiente** — podés dar a los usuarios permiso de escribir `spec` sin dejarlos tocar `status`, y al controller lo inverso; (2) **`metadata.generation`** sólo se incrementa cuando cambia `spec`, no `status`, de modo que el controller puede comparar `metadata.generation` con `status.observedGeneration` para saber si ya reconcilió el último cambio deseado, sin bucles de auto-reconciliación (escribir status **no** dispara un nuevo evento de spec).
- **4b.** Ese bloque `status` se **ignora** silenciosamente: con el status subresource activo, las escrituras al endpoint principal descartan el campo `status`. Sólo un `PUT/PATCH` a `.../status` (con RBAC sobre `databases/status`) lo modifica. Esto protege al controller de que un usuario pise su estado observado por accidente o malicia.
- **4c.** El `scale` subresource expone un endpoint `/scale` con la forma estándar `autoscaling/v1 Scale`. Eso permite que `kubectl scale` funcione, y —más importante— que un **HorizontalPodAutoscaler** apunte su `scaleTargetRef` a tu recurso `Database`: el HPA lee/escribe réplicas a través de ese endpoint genérico sin saber nada de tu tipo. Habilita autoscaling de recursos custom.
- **4d.** La category `all` hace que tus `Database` aparezcan en `kubectl get all`, que muchos usuarios usan como "mostrame todo lo importante". Meter recursos de plataforma ahí puede **saturar** esa salida y confundir (los usuarios esperan sólo cargas de trabajo core). Por eso conviene una category propia como `platform`, que agrupa los recursos del IDP bajo `kubectl get platform` sin contaminar `all`.

### Bloque 5

- **5a.** `served` controla si esa versión se **expone por la API** (los clientes pueden leer/escribir con ese `apiVersion`); `storage` controla en qué versión se **persiste** en etcd. Debe haber exactamente una `storage: true`. `served: false, storage: true` es **inválido/peligroso** y el apiserver lo rechaza si nadie puede escribir la versión de almacenamiento — la storage version debe ser served o al menos alcanzable; en la práctica la storage version siempre se sirve. `served: true, storage: false` es **totalmente válido y común**: sirve una versión adicional que se convierte al vuelo desde/hacia la storage version.
- **5b.** `None` no transforma datos: al convertir sólo **cambia el campo `apiVersion`** y deja el resto de los campos **idénticos**. Por eso sólo es correcto cuando las versiones son estructuralmente compatibles (mismos nombres/semántica de campos). Su límite exacto: no puede renombrar, mover, fusionar ni recalcular campos. Si `v1alpha1.foo` y `v1beta1.foo` significan lo mismo, `None` sirve; si difieren, corrompe datos.
- **5c.** Renombrar `sizeGi` (GiB) a `sizeBytes` (bytes) implica **renombrar y recalcular** (`sizeBytes = sizeGi * 2^30`). `None` no puede hacer eso — dejaría ambos objetos inconsistentes. Necesitás `conversion.strategy: Webhook`: el apiserver, cada vez que debe convertir entre versiones, envía un `ConversionReview` (que contiene la lista de objetos en la versión de origen y el `desiredAPIVersion`) a tu webhook por HTTPS; el webhook devuelve un `ConversionReview` con los mismos objetos **transformados** a la versión destino (y `result.status: Success`). El apiserver hace esto de forma transparente en lecturas, escrituras y migraciones de storage.
- **5b/5d — storedVersions.** `status.storedVersions` lista **toda** versión que alguna vez fue storage version y por tanto puede existir todavía en etcd con ese formato. Para retirar una versión con seguridad: (1) marcala `served: false`; (2) **reescribí todos los objetos** en la nueva storage version (storage-version-migrator o `get | apply`); (3) recién cuando la vieja versión ya no figura en `storedVersions`, quitala de `versions[]`. Quitarla antes es peligroso: quedarían objetos persistidos en un formato que el apiserver ya no sabe decodificar → errores de lectura y objetos "atrapados".

### Bloque 6

- **6a.** Al borrar la CRD, el `CustomResourceCleanupController` del apiserver borra en cascada **todas las instancias** de ese tipo (respetando sus finalizers: si un objeto tiene un finalizer, se marca con `deletionTimestamp` y espera a que el controller responsable lo limpie antes de desaparecer). La discovery del recurso también se retira. Es distinto de borrar un `APIService` del aggregation layer: ahí sólo **desregistrás la ruta** hacia el aggregated server; los datos viven en el storage de *ese* servidor externo y no se tocan.
- **6b.** El status subresource se expresa en RBAC como el "subresource" `databases/status` (sintaxis `resources: ["databases/status"]`). Separar `databases` de `databases/status` permite el reparto correcto de responsabilidades: el **usuario** obtiene verbos sobre `databases` (edita el `spec`, el estado deseado) y el **controller** obtiene verbos sobre `databases/status` (escribe el estado observado). Así ninguno pisa el dominio del otro y se refleja en permisos el contrato spec-vs-status.
- **6c.** `kubectl auth can-i` consulta directamente el **SubjectAccessReview** del apiserver: responde qué permite el RBAC **sin ejecutar** la acción ni crear/mutar objetos. Para un platform engineer que expone self-service es la forma correcta de auditar los permisos delegados (incluso con `--as` para impersonar a un usuario/SA), de forma repetible, segura y sin efectos secundarios — algo imposible si "probás a mano" creando recursos reales.

</details>

---

### Fuentes oficiales

- CNCF — *CNPA Curriculum* (dominio 4, APIs for Self-Service Platforms): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes — *Extend the Kubernetes API with CustomResourceDefinitions*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — *Versions in CustomResourceDefinitions* (served/storage, conversion webhooks, storedVersions): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Kubernetes — *Validation rules (CEL) — `x-kubernetes-validations`*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Kubernetes — *Structural schemas & pruning*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- Kubernetes — *Custom resource definitions: status & scale subresources*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#status-subresource
- Kubernetes — *Configure the Aggregation Layer / APIService*: https://kubernetes.io/docs/tasks/extend-kubernetes/configure-aggregation-layer/
- Kubernetes — *Using RBAC Authorization* (subresources en reglas): https://kubernetes.io/docs/reference/access-authn-authz/rbac/