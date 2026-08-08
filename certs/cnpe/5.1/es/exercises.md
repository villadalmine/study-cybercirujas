# Ejercicios Guiados — Tema 5.1: Diseño y Creación de Custom Resource Definitions (CRDs) para Platform Services

> **Objetivo del tema.** Como Platform Engineer no escribís un CRD para "extender Kubernetes" en abstracto: estás **diseñando el contrato de API** que tus usuarios internos (developers, otros equipos) van a consumir de forma declarativa. Un CRD bien diseñado es una interfaz estable, autovalidada y autodocumentada; uno mal diseñado filtra detalles de implementación, rompe compatibilidad en cada release y empuja la validación al runtime del controller (o peor, a producción).
>
> Estos ejercicios construyen, de forma incremental, la API de un servicio de plataforma real: `DatabaseClaim` — un recurso self-service con el que un developer pide una base de datos sin conocer la infraestructura subyacente (patrón *claim* estilo Crossplane).

**Prerrequisitos**
- Cluster con acceso `cluster-admin` (kind, minikube o real). Versión ≥ 1.29 para CEL (`x-kubernetes-validations`) estable.
- `kubectl` configurado.
- Comprobá la versión del API server: `kubectl version` — CEL cost limits y ratcheting dependen de la minor version.

Fuentes de referencia:
- CRDs: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Structural schemas: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- Versioning y conversion: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- CEL validation rules: https://kubernetes.io/docs/reference/using-api/cel/ y https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules

---

## Ejercicio 1 — Anatomía del contrato: un CRD mínimo pero correcto

Vas a definir la primera versión (`v1alpha1`) del recurso, con un **structural schema** desde el arranque. Nunca crees un CRD sin schema: un CRD sin `openAPIV3Schema` acepta cualquier YAML y convierte tu API en un basurero no tipado.

1. Creá el archivo `databaseclaim-crd.yaml`:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # OBLIGATORIO: <plural>.<group>
  name: databaseclaims.platform.example.com
spec:
  group: platform.example.com
  scope: Namespaced          # el developer lo pide en SU namespace
  names:
    plural: databaseclaims
    singular: databaseclaim
    kind: DatabaseClaim       # el kind que va en el YAML del usuario
    listKind: DatabaseClaimList
    shortNames: [dbc]
    categories: [platform, all]
  versions:
    - name: v1alpha1
      served: true            # el API server responde en esta versión
      storage: true           # esta versión se persiste en etcd
      schema:
        openAPIV3Schema:
          type: object
          required: [spec]
          properties:
            spec:
              type: object
              required: [engine, sizeGB]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                version:
                  type: string
                  default: "16"
                sizeGB:
                  type: integer
                  minimum: 10
                  maximum: 1000
              # rechaza claves que el schema no declara
              additionalProperties: false
            status:
              type: object
              properties:
                phase:
                  type: string
                x-kubernetes-preserve-unknown-fields: false
```

2. Aplicalo y esperá a que se establezca:

```bash
kubectl apply -f databaseclaim-crd.yaml
kubectl wait --for=condition=Established crd/databaseclaims.platform.example.com --timeout=30s
```

Salida esperada:

```
customresourcedefinition.apiextensions.k8s.io/databaseclaims.platform.example.com created
customresourcedefinition.apiextensions.k8s.io/databaseclaims.platform.example.com condition met
```

3. Verificá que el schema quedó publicado y que la discovery API lo expone:

```bash
kubectl explain databaseclaim.spec
kubectl api-resources --api-group=platform.example.com
```

Salida esperada (recortada):

```
GROUP:      platform.example.com
KIND:       DatabaseClaim
VERSION:    v1alpha1

FIELD: spec <Object>
...
   engine       <string> -required-
   sizeGB       <integer> -required-
   version      <string>
```

```
NAME             SHORTNAMES   APIVERSION                        NAMESPACED   KIND
databaseclaims   dbc          platform.example.com/v1alpha1     true         DatabaseClaim
```

4. Creá una instancia válida y una inválida:

```bash
# válida
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: orders-db }
spec: { engine: postgres, sizeGB: 20 }
EOF

# inválida: engine no permitido + campo desconocido + sizeGB fuera de rango
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: bad-db }
spec: { engine: oracle, sizeGB: 5, replicas: 3 }
EOF
```

Salida esperada del segundo apply (el API server rechaza en admission, antes de tocar etcd):

```
The DatabaseClaim "bad-db" is invalid:
* spec.engine: Unsupported value: "oracle": supported values: "postgres", "mysql"
* spec.sizeGB: Invalid value: 5: spec.sizeGB in body should be greater than or equal to 10
* spec.replicas: Forbidden: property not defined in the schema
```

**Preguntas de comprensión**

1.1. El `metadata.name` del CRD debe ser exactamente `databaseclaims.platform.example.com`. ¿Qué dos campos del `spec` determinan ese valor y qué pasa si no coinciden?

1.2. ¿Cuál es la diferencia práctica entre `served: true` y `storage: true`? ¿Cuántas versiones pueden tener `storage: true` simultáneamente y por qué?

1.3. El objeto `bad-db` fue rechazado sin crearse. ¿En qué etapa del request pipeline del API server ocurrió la validación del schema, y por qué es relevante que sea *antes* de la persistencia en etcd?

1.4. ¿Por qué `additionalProperties: false` es una decisión de diseño y no solo "higiene"? Pensalo desde la evolución futura del API.

---

## Ejercicio 2 — Structural schema, defaulting y por qué `preserve-unknown-fields` es peligroso

Un **structural schema** es la precondición para que features como defaulting, pruning, `kubectl explain` completo, server-side apply y CEL funcionen. Vamos a demostrar el pruning y el defaulting, y a ver el agujero que abre `x-kubernetes-preserve-unknown-fields`.

1. El campo `version` tiene `default: "16"`. Creá un claim sin especificarlo y leé el objeto persistido:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: analytics-db }
spec: { engine: postgres, sizeGB: 50 }
EOF

kubectl get databaseclaim analytics-db -o jsonpath='{.spec.version}{"\n"}'
```

Salida esperada:

```
16
```

El API server **inyectó** el default en el objeto almacenado. El default se aplica en lectura/escritura para objetos ya persistidos que no lo tenían.

2. Demostrá el **pruning**. Un campo no declarado se descarta silenciosamente al persistir (no genera error como en el Ejercicio 1 porque ahí `additionalProperties:false` lo hizo *fallar*; el pruning ocurre en nodos que *no* tienen esa restricción o cuando el campo viene por otras vías). Agregá temporalmente un mapa abierto y observá la diferencia. Editá el CRD para añadir bajo `spec`:

```yaml
                labels:
                  type: object
                  additionalProperties:
                    type: string
```

Aplicá y creá:

```bash
kubectl apply -f databaseclaim-crd.yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: tagged-db }
spec:
  engine: mysql
  sizeGB: 30
  labels: { team: payments, tier: gold }
EOF
kubectl get databaseclaim tagged-db -o jsonpath='{.spec.labels}{"\n"}'
```

Salida esperada:

```
{"team":"payments","tier":"gold"}
```

3. Ahora el anti-patrón. Reemplazá ese bloque `labels` por un nodo que preserva lo desconocido:

```yaml
                labels:
                  type: object
                  x-kubernetes-preserve-unknown-fields: true
```

```bash
kubectl apply -f databaseclaim-crd.yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: leaky-db }
spec:
  engine: postgres
  sizeGB: 30
  labels: { team: payments, __internal_secret_flag: true, nested: { a: 1 } }
EOF
kubectl get databaseclaim leaky-db -o jsonpath='{.spec.labels}{"\n"}'
```

Salida esperada — **todo** se persiste sin validar:

```
{"__internal_secret_flag":true,"nested":{"a":1},"team":"payments"}
```

**Preguntas de comprensión**

2.1. Enumerá tres reglas que hacen que un schema sea "structural" (no hace falta la lista exacta, sí el concepto: qué obliga sobre `type` y sobre `allOf/anyOf/oneOf/not`).

2.2. En el paso 1, `analytics-db` se guardó con `version: "16"` aunque el usuario no lo escribió. ¿Dónde se aplica el defaulting — en el controller o en el API server — y qué implica eso para objetos creados *antes* de que existiera el default?

2.3. ¿Por qué `x-kubernetes-preserve-unknown-fields: true` deshabilita el pruning en ese subárbol y qué riesgo concreto de diseño introduce en una API de plataforma multi-tenant?

2.4. El pruning y `additionalProperties: false` producen resultados distintos ante un campo extra: uno descarta, el otro rechaza. ¿Cuál elegirías para el `spec` de un servicio de plataforma y por qué?

---

## Ejercicio 3 — Validación de negocio con CEL (`x-kubernetes-validations`)

OpenAPI cubre tipos y rangos, pero no reglas que cruzan campos ("si `engine=mysql`, `version` debe ser 8.x") ni inmutabilidad. Eso es CEL, evaluado en el API server durante admission — sin escribir un webhook.

1. Agregá reglas a nivel de `spec` (validación cruzada) y a nivel de campo (inmutabilidad con `oldSelf`). Editá el `openAPIV3Schema.properties.spec` para que incluya:

```yaml
            spec:
              type: object
              required: [engine, sizeGB]
              x-kubernetes-validations:
                # regla que cruza dos campos del spec
                - rule: "self.engine != 'mysql' || self.version.startsWith('8')"
                  message: "mysql solo se soporta en versiones 8.x"
                # límite de storage según engine
                - rule: "self.engine != 'postgres' || self.sizeGB <= 500"
                  message: "postgres está limitado a 500GB en este tier"
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql]
                  # inmutable: no se puede cambiar el motor de una DB existente
                  x-kubernetes-validations:
                    - rule: "self == oldSelf"
                      message: "engine es inmutable una vez creado el claim"
                version:
                  type: string
                  default: "16"
                sizeGB:
                  type: integer
                  minimum: 10
                  maximum: 1000
                  x-kubernetes-validations:
                    # solo permitir crecer, nunca encoger (evita pérdida de datos)
                    - rule: "self >= oldSelf"
                      message: "sizeGB solo puede aumentar, no reducirse"
              additionalProperties: false
```

2. Aplicá y probá la validación cruzada:

```bash
kubectl apply -f databaseclaim-crd.yaml

# viola la regla mysql/version
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: mysql-old }
spec: { engine: mysql, version: "5.7", sizeGB: 20 }
EOF
```

Salida esperada:

```
The DatabaseClaim "mysql-old" is invalid: spec: Invalid value: "object": mysql solo se soporta en versiones 8.x
```

3. Probá las **transition rules** (reglas que comparan con el valor anterior, `oldSelf`). Solo se evalúan en updates, no en create:

```bash
# crear válido
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: prod-db }
spec: { engine: postgres, version: "16", sizeGB: 100 }
EOF

# intentar cambiar el engine -> rechazado por inmutabilidad
kubectl patch databaseclaim prod-db --type=merge -p '{"spec":{"engine":"mysql","version":"8.0"}}'

# intentar encoger el storage -> rechazado
kubectl patch databaseclaim prod-db --type=merge -p '{"spec":{"sizeGB":50}}'

# crecer el storage -> permitido
kubectl patch databaseclaim prod-db --type=merge -p '{"spec":{"sizeGB":200}}'
```

Salida esperada (las tres, en orden):

```
The DatabaseClaim "prod-db" is invalid: spec.engine: Invalid value: "string": engine es inmutable una vez creado el claim
The DatabaseClaim "prod-db" is invalid: spec.sizeGB: Invalid value: "integer": sizeGB solo puede aumentar, no reducirse
databaseclaim.platform.example.com/prod-db patched
```

**Preguntas de comprensión**

3.1. ¿Por qué la regla `self == oldSelf` no dispara ningún error cuando se *crea* el objeto por primera vez? ¿Qué es `oldSelf` en un create?

3.2. La regla de inmutabilidad de `engine` está a nivel de campo, pero la regla `mysql`↔`version` está a nivel de `spec`. ¿Por qué esa última no puede escribirse a nivel del campo `engine`?

3.3. CEL se evalúa en el API server durante admission. Menciona una ventaja y una limitación de esto frente a un ValidatingAdmissionWebhook para la misma regla. (Pista: dependencias externas, cost limits.)

3.4. Diseño: implementaste "solo crecer" para `sizeGB`. ¿Qué clase entera de bugs de operación de plataforma previene esta única línea de CEL, y por qué es mejor tenerla en el contrato que en la lógica del controller?

---

## Ejercicio 4 — Subresources `/status` y `/scale`: separar deseo de realidad

En una API declarativa, el usuario escribe `spec` (lo deseado) y el controller escribe `status` (lo observado). Habilitar el subresource `/status` **prohíbe** que el usuario modifique `status` en el endpoint principal y hace que `metadata.generation` solo avance con cambios de `spec` — la base del patrón `observedGeneration`.

1. Enriquecé el `status` con condiciones estándar y habilitá los subresources. Bajo la versión `v1alpha1`, agregá al mismo nivel que `schema:`:

```yaml
      subresources:
        status: {}
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
          labelSelectorPath: .status.selector
```

Y ampliá el schema del `status` (y agregá `spec.replicas`):

```yaml
                replicas:
                  type: integer
                  default: 1
                  minimum: 1
                  maximum: 5
```

```yaml
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Pending, Provisioning, Ready, Failed]
                observedGeneration:
                  type: integer
                replicas:
                  type: integer
                selector:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    required: [type, status]
                    properties:
                      type: { type: string }
                      status: { type: string, enum: ["True", "False", "Unknown"] }
                      reason: { type: string }
                      message: { type: string }
                      lastTransitionTime: { type: string, format: date-time }
```

2. Aplicá y demostrá que el usuario **no puede** escribir `status` por el endpoint normal:

```bash
kubectl apply -f databaseclaim-crd.yaml
kubectl apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: DatabaseClaim
metadata: { name: sub-db }
spec: { engine: postgres, sizeGB: 20 }
status: { phase: Ready }
EOF

kubectl get databaseclaim sub-db -o jsonpath='{.status.phase}{"\n"}'
```

Salida esperada — el `status: Ready` del YAML fue **ignorado** (queda vacío):

```

```

3. Escribí `status` como lo haría el controller, vía el subresource, y observá `generation`:

```bash
# solo el subresource /status acepta esta escritura
kubectl patch databaseclaim sub-db --subresource=status --type=merge \
  -p '{"status":{"phase":"Ready","observedGeneration":1}}'

kubectl get databaseclaim sub-db -o jsonpath='gen={.metadata.generation} obsGen={.status.observedGeneration} phase={.status.phase}{"\n"}'

# cambiar el spec incrementa generation; el status queda "atrasado"
kubectl patch databaseclaim sub-db --type=merge -p '{"spec":{"sizeGB":40}}'
kubectl get databaseclaim sub-db -o jsonpath='gen={.metadata.generation} obsGen={.status.observedGeneration}{"\n"}'
```

Salida esperada:

```
gen=1 obsGen=1 phase=Ready
gen=2 obsGen=1
```

4. Probá el subresource `/scale` — ahora `kubectl scale` funciona sobre tu CRD como si fuera un Deployment:

```bash
kubectl scale databaseclaim sub-db --replicas=3
kubectl get databaseclaim sub-db -o jsonpath='{.spec.replicas}{"\n"}'
```

Salida esperada:

```
databaseclaim.platform.example.com/sub-db scaled
3
```

**Preguntas de comprensión**

4.1. En el paso 2, escribiste `status: {phase: Ready}` en el YAML y `kubectl` no dio error, pero el valor no se guardó. ¿Por qué el subresource `/status` produce ese comportamiento en vez de un rechazo?

4.2. Tras el paso 3, `generation=2` pero `observedGeneration=1`. Explica en una frase qué le está diciendo esto al controller y cómo lo usa para saber si tiene trabajo pendiente.

4.3. El subresource `/scale` requiere tres paths. ¿Qué habilita `labelSelectorPath` que va más allá de `kubectl scale` — pensá en el HorizontalPodAutoscaler?

4.4. Diseño: ¿por qué es correcto que un update *solo* de `spec` (no de `status`) sea lo único que incrementa `metadata.generation`? ¿Qué pasaría con los reconcile loops si cada escritura de `status` también lo incrementara?

---

## Ejercicio 5 — Ergonomía del operador: printer columns, shortNames y categories

Un contrato de plataforma no termina en la validación: `kubectl get` debe ser útil sin `-o yaml`. Las `additionalPrinterColumns` son parte del diseño de la interfaz.

1. Agregá columnas a la versión `v1alpha1` (al mismo nivel que `schema` y `subresources`):

```yaml
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Size
          type: integer
          jsonPath: .spec.sizeGB
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
        # columna extendida: solo aparece con -o wide
        - name: Version
          type: string
          priority: 1
          jsonPath: .spec.version
```

2. Aplicá y observá la salida tabular:

```bash
kubectl apply -f databaseclaim-crd.yaml
kubectl get databaseclaims
kubectl get dbc -o wide          # usando el shortName y viendo la columna priority:1
kubectl get platform             # usando la category
```

Salida esperada (aproximada):

```
NAME       ENGINE     SIZE   PHASE   AGE
prod-db    postgres   200            15m
sub-db     postgres   40     Ready   9m
...
```

```
NAME       ENGINE     SIZE   PHASE   AGE   VERSION
sub-db     postgres   40     Ready   9m    16
...
```

`kubectl get platform` lista **todos** los recursos de la categoría `platform` (tu CRD y cualquier otro que la comparta), útil para dashboards de plataforma.

**Preguntas de comprensión**

5.1. ¿Qué hace el atributo `priority: 1` en una printer column y cuándo aparece esa columna?

5.2. Si un CRD tiene múltiples `versions` servidas con distintos `additionalPrinterColumns`, ¿cuáles se usan al hacer `kubectl get`? (Pista: `served` vs. la versión de la request.)

5.3. `categories: [platform, all]`. ¿Qué implica incluir `all` y por qué podrías **no** querer que un CRD de infraestructura aparezca en `kubectl get all`?

---

## Ejercicio 6 — Múltiples versiones y conversión: evolucionar sin romper

Ninguna API nace perfecta. El diseño maduro planifica la evolución: introducir `v1beta1`, promover el storage, y convertir objetos entre versiones. Empezamos con conversión `None` (schemas compatibles) y discutimos cuándo hace falta un webhook.

1. Agregá una segunda versión `v1beta1` que renombra conceptualmente pero mantiene compatibilidad estructural. En este ejercicio mantendremos ambos schemas compatibles y usaremos `strategy: None`. Añadí a `spec.versions` (junto a `v1alpha1`) y ajustá los flags:

```yaml
  conversion:
    strategy: None
  versions:
    - name: v1alpha1
      served: true
      storage: false          # ya no es la versión de almacenamiento
      # ... (schema, subresources, printerColumns como antes)
    - name: v1beta1
      served: true
      storage: true           # v1beta1 pasa a ser la versión almacenada
      schema:
        openAPIV3Schema:
          # mismo schema estructural que v1alpha1 (compatible)
          type: object
          # ... (idéntico)
      subresources:
        status: {}
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
          labelSelectorPath: .status.selector
```

2. Aplicá y observá que un objeto creado en `v1alpha1` se puede leer en `v1beta1`:

```bash
kubectl apply -f databaseclaim-crd.yaml

# leer el mismo objeto en ambas versiones servidas
kubectl get databaseclaims.v1alpha1.platform.example.com sub-db -o jsonpath='{.apiVersion}{"\n"}'
kubectl get databaseclaims.v1beta1.platform.example.com sub-db -o jsonpath='{.apiVersion}{"\n"}'
```

Salida esperada:

```
platform.example.com/v1alpha1
platform.example.com/v1beta1
```

3. Verificá cuál es la versión de almacenamiento real y cómo migrar objetos viejos. `status.storedVersions` del CRD registra en qué versiones hay objetos persistidos:

```bash
kubectl get crd databaseclaims.platform.example.com -o jsonpath='{.status.storedVersions}{"\n"}'
```

Salida esperada (los objetos viejos siguen marcados como almacenados en `v1alpha1` hasta reescribirlos):

```
["v1alpha1","v1beta1"]
```

Para poder eventualmente **retirar** `v1alpha1`, hay que reescribir todos los objetos a la storage version (por ejemplo con `kubectl get ... -o yaml | kubectl replace -f -`, o el StorageVersionMigrator) y recién ahí depurar `storedVersions`.

**Preguntas de comprensión**

6.1. `strategy: None` no hace ninguna transformación de datos: solo cambia el `apiVersion` del objeto servido. ¿Qué condición **deben** cumplir los schemas de todas las versiones servidas para que `None` sea seguro?

6.2. Cambiaste `storage: true` de `v1alpha1` a `v1beta1`. Un objeto viejo creado bajo `v1alpha1` sigue apareciendo en `status.storedVersions`. ¿Por qué no basta con cambiar el flag para poder borrar `v1alpha1`, y qué paso operativo falta?

6.3. Supongamos que `v1beta1` **renombra** `sizeGB` a `storage.sizeGB` (cambio no estructuralmente compatible). ¿Por qué `strategy: None` ya no sirve y qué componente hay que desplegar en su lugar?

6.4. Diseño de ciclo de vida: ordená correctamente estas acciones para deprecar `v1alpha1` sin downtime — (a) `served: false` en v1alpha1, (b) promover storage a v1beta1, (c) migrar objetos existentes a v1beta1, (d) eliminar v1alpha1 del CRD y de `storedVersions`.

---

## Ejercicio 7 — Diagnóstico: cuando el CRD no se comporta

Como platform engineer vas a debuggear CRDs ajenos y propios. Estos son los fallos más comunes.

1. **CRD que no se establece.** Introducí a propósito un schema no-structural (un `type` faltante) y observá la condición:

```bash
kubectl get crd databaseclaims.platform.example.com \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

Salida esperada de un CRD sano:

```
NamesAccepted=True NoConflicts: no conflicts found
Established=True InitialNamesAccepted: the initial names have been accepted
```

Si el schema es inválido verás `NonStructuralSchema=True` con el detalle del campo culpable.

2. **"No coincide ninguna versión servida".** Si intentás usar una `apiVersion` con `served: false` obtenés un error de discovery, no de validación:

```bash
kubectl get databaseclaims.v1alpha1.platform.example.com 2>&1 | head -1
```

3. **Inspeccionar el schema efectivo tal como lo publica el API server** (no el YAML fuente, sino lo que realmente sirve, útil cuando defaulting o conversión están en juego):

```bash
kubectl get --raw /apis/platform.example.com/v1beta1 | python3 -m json.tool
kubectl explain databaseclaim.spec.sizeGB --api-version=platform.example.com/v1beta1
```

**Preguntas de comprensión**

7.1. ¿Qué dos condiciones del `status` de un CRD tenés que ver en `True` para saber que el recurso está usable, y cuál falla ante un schema no-structural?

7.2. Un usuario reporta "mi campo desaparece al aplicar". Sin ver su YAML, ¿cuáles son las dos causas de diseño más probables en el CRD, y con qué comando confirmás cada una?

7.3. ¿Por qué `kubectl explain` es una herramienta de *contrato* y no solo de conveniencia? ¿Qué feature del CRD debe estar presente para que muestre descripciones de campo?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.1.** El nombre debe ser `<spec.names.plural>.<spec.group>` → `databaseclaims` + `.` + `platform.example.com`. Si no coincide, el API server rechaza el CRD con un error de validación (`metadata.name: Invalid value... must be spec.names.plural+"."+spec.group`); el objeto nunca se crea. Es una restricción sintáctica del propio recurso CRD.

**1.2.** `served: true` significa que el API server **responde** requests en esa versión (aparece en discovery, se puede `get/create/apply`). `storage: true` significa que los objetos se **persisten en etcd** codificados en esa versión. Puede haber muchas versiones `served`, pero **exactamente una** con `storage: true` en un momento dado — etcd guarda una sola representación canónica; las demás versiones servidas se convierten desde/hacia ella al leer/escribir.

**1.3.** Ocurrió en la fase de **admission/validation** del request pipeline (schema validation es parte del admission del API server para custom resources), *después* de authN/authZ y *antes* de la escritura a etcd. Es relevante porque garantiza que etcd nunca contiene objetos inválidos: la invariante de datos se mantiene a nivel de storage, no depende de que el controller "limpie" después, y ningún consumidor puede leer basura.

**1.4.** `additionalProperties: false` cierra el objeto: cualquier campo no declarado se rechaza. Como decisión de evolución, protege el *espacio de nombres* de tus campos: si mañana agregás `spec.replicas`, ningún usuario pudo haber estado poniendo `replicas` con otra semántica, y no rompés a nadie. Sin él, los usuarios inventan campos (que el pruning descarta silenciosamente), creando la ilusión de que "funcionan" y generando incompatibilidades el día que vos reclamás ese nombre.

### Ejercicio 2

**2.1.** (cualquiera tres) — (a) especifica un `type` no vacío para la raíz, para cada campo de un objeto (bajo `properties`/`additionalProperties`) y para los items de un array (bajo `items`), salvo nodos `x-kubernetes-int-or-string` o `x-kubernetes-preserve-unknown-fields`; (b) para cada campo/item mencionado dentro de `allOf/anyOf/oneOf/not`, ese campo también está especificado *fuera* de esos junctors; (c) no coloca `type`, `default`, `additionalProperties`, `nullable` dentro de `allOf/anyOf/oneOf/not`; (d) si aparece `metadata`, solo puede restringir `metadata.name`/`metadata.generateName`.

**2.2.** El defaulting lo aplica el **API server**, no el controller, durante el manejo del request (y también al leer objetos previamente almacenados sin ese campo). Implicancia: objetos creados antes de que existiera el default **no se reescriben** en etcd automáticamente, pero se sirven *con* el default aplicado al leerlos; el valor se materializa en la próxima escritura del objeto. Un default no muta retroactivamente el storage por sí solo.

**2.3.** `x-kubernetes-preserve-unknown-fields: true` le dice al API server "no hagas pruning en este subárbol": conserva cualquier clave, sin tipo ni validación. El riesgo en una plataforma multi-tenant: los usuarios pueden inyectar estructura arbitraria (payloads gigantes, claves que colisionan con futura semántica, datos que ningún check valida), y perdés la capacidad de razonar sobre el shape de tus propios objetos — se vuelve un blob no tipado dentro de una API supuestamente tipada.

**2.4.** Para el `spec` de un servicio de plataforma: `additionalProperties: false` (rechazar). Un rechazo explícito le da **feedback inmediato** al developer ("ese campo no existe") en vez de descartar silenciosamente su intención y dejar que descubra en producción que su config nunca tuvo efecto. El pruning silencioso es una de las peores experiencias de API porque falla sin señal.

### Ejercicio 3

**3.1.** En un create, `oldSelf` **no existe** (no hay valor anterior), por lo que las *transition rules* (reglas que referencian `oldSelf`) **no se evalúan** — solo corren en updates donde hay un estado previo con el que comparar. Por eso `self == oldSelf` nunca bloquea la creación inicial, solo prohíbe *cambios* posteriores.

**3.2.** Una regla a nivel del campo `engine` solo recibe en `self` el valor de `engine` (un string); no tiene acceso a `version`. La regla `mysql`↔`version` cruza dos campos, así que su `self` debe ser el objeto que **contiene ambos** — el `spec`. El scope de `self` en CEL es el nodo del schema donde se declara la regla.

**3.3.** Ventaja: CEL corre **in-process** en el API server — sin desplegar/mantener/escalar/asegurar un webhook, sin latencia de red ni punto de fallo extra (un webhook caído puede bloquear todo el API group). Limitación: CEL no puede consultar **estado externo** (otros objetos, sistemas externos, la hora real de forma arbitraria) y está sujeto a **cost limits** (presupuesto de complejidad por regla y por request); reglas caras o que necesitan contexto externo requieren un webhook.

**3.4.** Previene toda la clase de **shrink/data-loss por reconfiguración**: un usuario (o un GitOps mal mergeado) bajando `sizeGB` y disparando un redimensionamiento destructivo de almacenamiento. Tenerlo en el **contrato** (CEL) lo hace imposible atómicamente en admission, para *todos* los clientes, incluso si el controller tiene un bug o alguien edita etcd por otra vía; en la lógica del controller, la protección solo existe cuando el controller corre y no tiene bugs.

### Ejercicio 4

**4.1.** Al habilitar el subresource `/status`, el endpoint principal (`create`/`update`/`apply` del recurso) **descarta el `status`** entrante en lugar de rechazarlo: `status` solo es escribible por el endpoint `/status`. Es un comportamiento por diseño (no un error) para que aplicar un manifiesto completo — que un usuario podría copiar con `status` incluido — no falle, pero tampoco permita que el usuario falsifique el estado observado.

**4.2.** `observedGeneration (1) < generation (2)` significa: "el `spec` cambió y el controller todavía no reconcilió la última versión". El controller compara ambos; si `observedGeneration < metadata.generation`, sabe que tiene trabajo pendiente, reconcilia, y al terminar escribe `observedGeneration = generation` en el status.

**4.3.** `labelSelectorPath` expone un **label selector** en el subresource `/scale`, que es exactamente lo que el **HorizontalPodAutoscaler** necesita para descubrir qué pods pertenecen al recurso y leer sus métricas. Con los tres paths, un HPA puede escalar tu CRD como si fuera un Deployment/StatefulSet — sin `labelSelectorPath`, `kubectl scale` funciona pero el HPA no puede operar sobre él.

**4.4.** Porque `metadata.generation` está pensada como "número de versión del **deseo** del usuario". Solo los cambios de `spec` representan una nueva intención a reconciliar; `status` es la *respuesta* del sistema, no una nueva petición. Si cada escritura de `status` incrementara `generation`, el controller escribir status subiría `generation`, lo que se vería como "hay nuevo trabajo", disparando otra reconciliación y otra escritura de status — un **loop infinito de reconciliación**. Separarlos rompe ese ciclo.

### Ejercicio 5

**5.1.** `priority: 1` marca la columna como **extendida**: no aparece en `kubectl get` normal, solo con `kubectl get -o wide`. Las columnas con `priority: 0` (o sin `priority`, que es el default) son las estándar. Sirve para datos útiles pero secundarios que no querés en la vista compacta.

**5.2.** Se usan las printer columns **de la versión que resuelve la request**. Con `kubectl get databaseclaims` sin sufijo de versión, `kubectl` usa la versión preferida que anuncia discovery (típicamente la de mayor madurez/storage servida); con `kubectl get databaseclaims.v1alpha1...` usa las columnas de `v1alpha1`. Cada versión servida define sus propias columnas.

**5.3.** Incluir `all` hace que el recurso aparezca en `kubectl get all`. Podrías **no** querer eso para CRDs de infraestructura pesados o numerosos: `kubectl get all` es un comando que la gente usa para ver "sus cargas de trabajo" (pods, deployments, services); llenarlo de recursos de plataforma lo vuelve ruidoso y puede disparar listados costosos. `all` es para recursos que un usuario razonablemente espera ver como "sus aplicaciones".

### Ejercicio 6

**6.1.** Todas las versiones servidas deben ser **estructural y semánticamente compatibles**: el mismo objeto debe poder representarse en cualquiera de ellas sin pérdida ni transformación de datos (mismos campos, mismos tipos, misma semántica). Con `None`, el API server solo reetiqueta el `apiVersion` y sirve los mismos datos; si un campo existe en una versión y no en otra, o cambia de significado, `None` corrompe o pierde información.

**6.2.** `status.storedVersions` lista **todas las versiones en las que existen objetos persistidos en etcd**, no la versión de storage actual. Cambiar `storage: true` a `v1beta1` solo afecta a **escrituras nuevas**; los objetos viejos siguen codificados en `v1alpha1` en etcd, así que `v1alpha1` permanece en `storedVersions`. Falta **reescribir** cada objeto existente (p. ej. `get -o yaml | replace`, o un StorageVersionMigration) para que se recodifiquen en `v1beta1`, y recién entonces depurar `storedVersions`. No se puede quitar una versión que todavía figura en `storedVersions`.

**6.3.** Con un renombre (`sizeGB` → `storage.sizeGB`) las versiones ya **no son estructuralmente compatibles**: el mismo objeto tiene shapes distintos, y `None` no puede transformar datos. Hay que usar `conversion.strategy: Webhook` y desplegar un **conversion webhook** que traduzca objetos entre `v1alpha1` y `v1beta1` en ambas direcciones cuando el API server los sirve o migra.

**6.4.** Orden sin downtime: **(b)** promover storage a v1beta1 → **(c)** migrar/reescribir los objetos existentes a v1beta1 (para vaciar `v1alpha1` de `storedVersions`) → **(a)** `served: false` en v1alpha1 (deja de responderse, pero antes hay que estar seguro de que ningún cliente la usa) → **(d)** eliminar v1alpha1 del CRD y depurar `storedVersions`. La clave: nunca quitar la versión servida antes de migrar los datos y confirmar que no hay consumidores.

*(Nota: en la práctica se suele intercalar un período de deprecación anunciada de `v1alpha1` antes del paso (a), para dar tiempo a los clientes a migrar.)*

### Ejercicio 7

**7.1.** `NamesAccepted=True` (no hay conflicto de nombres/plural/kind con otros recursos) y `Established=True` (el CRD está registrado y usable). Ante un schema no-structural aparece además `NonStructuralSchema=True` con el mensaje del campo culpable; mientras persista, el CRD puede quedar no `Established` o con features deshabilitadas (defaulting, CEL, pruning).

**7.2.** Las dos causas de diseño más probables: (a) **pruning** — el campo no está declarado en el schema y no hay `additionalProperties`/`preserve-unknown-fields`, así que el API server lo descarta; se confirma con `kubectl explain <recurso>.<ruta>` (si el campo no figura, no está en el schema). (b) **subresource /status** — el usuario escribe bajo `status` un recurso que tiene el subresource habilitado, y el endpoint principal lo descarta; se confirma viendo `spec.versions[].subresources.status` en el CRD (`kubectl get crd ... -o yaml`).

**7.3.** `kubectl explain` renderiza el **schema publicado por el API server** — es la documentación *ejecutable* del contrato, siempre sincronizada con lo que realmente se valida (a diferencia de un README que puede quedar desactualizado). Para que muestre descripciones de campo, el `openAPIV3Schema` debe incluir atributos `description:` en los nodos; son parte del diseño de la API tanto como los tipos.

</details>