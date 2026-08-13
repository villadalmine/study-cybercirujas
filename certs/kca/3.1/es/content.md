# 3.1 — `apply`: Gestión declarativa de objetos, Client-Side vs Server-Side Apply

> Peso en el examen: **3.0** · Dominio 3 · Enfoque: el modelo de gestión declarativa de objetos que implementa `kubectl apply`, el three-way merge que lo hace seguro, y la propiedad de campos (field ownership) de Server-Side Apply (SSA) — el mecanismo del que ahora dependen todos los controladores GitOps y admission webhooks.

---

## 1. Motivación — el problema de producción que resuelve `apply`

El estado deseado de un objeto de Kubernetes no tiene un único autor. Un `Deployment` lo escribe un humano (o un repo de Git), y luego es *mutado en vuelo* por:

- **Controllers** — el HorizontalPodAutoscaler reescribe `.spec.replicas`; el Deployment controller estampa `.spec.template.metadata.annotations` para los rollouts.
- **Admission webhooks** — un injector de service mesh agrega un container sidecar; Kyverno/Gatekeeper inyectan valores por defecto de `securityContext`.
- **Otros humanos / otras herramientas** — `kubectl scale`, `kubectl set image`, el Helm release de otro equipo, un `kubectl edit` de emergencia (break-glass).

Si gestionás objetos de forma **imperativa** (`kubectl create`, `kubectl replace -f`, `kubectl edit`), cada escritura es una *sobrescritura del objeto completo*. Reaplicar tu archivo a ciegas pisa todo lo que hicieron el HPA o el injector, y quitar un campo de tu archivo **no** lo elimina del cluster (no hay registro de lo que antes "poseías"). Esto produce dos incidentes crónicos:

1. **El aleteo de réplicas (replica flap).** Hacés `apply` de `replicas: 3`. El HPA escala a 12. Tu CI vuelve a hacer `apply` → de vuelta a 3 → el HPA escala a 12 otra vez. El Deployment oscila en cada corrida del pipeline.
2. **Config drift / campos huérfanos.** Alguien hace `kubectl edit` de una variable de entorno en prod. Tu siguiente `apply` la deja intacta porque tu archivo "no sabe" que el campo existe — el objeto vivo diverge silenciosamente de Git.

`kubectl apply` existe para convertir el manifiesto en la **fuente declarativa de verdad** mientras rastrea *qué campos poseés*, de modo que una reaplicación reconcilie solo tus campos y *elimine los campos que quitaste* sin pisar los campos que pertenecen a otros actores. Esta es la base sobre la que está construido GitOps (Argo CD, Flux) — ambos usan Server-Side Apply para que el controller, el equipo de plataforma y el equipo de la aplicación puedan co-poseer un mismo objeto sin una guerra de merges.

---

## 2. Los tres modelos de gestión de objetos (y cuándo cada uno es legítimo)

Kubernetes documenta tres técnicas mutuamente incompatibles. **Nunca las mezcles en el mismo objeto** — esa es la causa #1 de sorpresas con apply.

| Técnica | Verbos | Fuente de configuración | Seguimiento de estado | Uso correcto | Modo de fallo al mal usarla |
|---|---|---|---|---|---|
| **Comandos imperativos** | `kubectl create/run/expose/scale/set/delete` | ninguna (flags) | ninguno | puntual, dev, emergencia (break-glass), generar YAML con `--dry-run=client -o yaml` | no reproducible; sin traza de auditoría |
| **Configuración imperativa de objetos** | `kubectl create -f`, `kubectl replace -f`, `kubectl delete -f` | un `.yaml` | ninguno | cuando querés una *sobrescritura completa* y rechazar ediciones concurrentes | `replace` falla si el objeto cambió por debajo tuyo; descarta campos puestos por controllers/webhooks |
| **Configuración declarativa de objetos** | `kubectl apply -f`, `kubectl apply -k`, `kubectl diff -f` | archivos / dirs / kustomize | **sí** — anotación CSA o `managedFields` de SSA | producción, GitOps, CI/CD, objetos con múltiples escritores | mezclar con `replace`/`edit` corrompe la base del merge |

**Regla general:** un objeto tocado por `apply` debería ser tocado *solo* por `apply` durante el resto de su vida. `kubectl edit`, `kubectl scale` y `kubectl replace` escriben con *distintos field managers* y arman exactamente el conflicto que SSA está diseñado para detectar (ver §4.6).

---

## 3. Cómo funciona `apply` realmente — la mecánica del merge

`kubectl apply` calcula qué cambiar a partir de **tres entradas**, de ahí *three-way merge*:

1. **El archivo de configuración** que pasás con `-f` (tu nuevo estado deseado).
2. **El objeto vivo** actualmente en etcd.
3. **El estado aplicado por última vez (last-applied)** — lo que *vos* declaraste la última vez.

La entrada #3 es lo que hace posible la eliminación: un campo presente en *last-applied* pero ausente de tu *nuevo archivo* → **eliminarlo**. Un campo presente en vivo pero nunca en tu last-applied → **dejarlo en paz** (lo posee otro). Ese es todo el truco.

Hay dos implementaciones de #3.

### 3.1 Client-Side Apply (CSA) — el default heredado

`kubectl` guarda tu estado last-applied como un blob JSON dentro de una anotación en el objeto:

```yaml
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"apps/v1","kind":"Deployment","metadata":{...},"spec":{...}}
```

El cliente lee el objeto vivo, lee esa anotación, hace diff contra tu archivo, calcula un **strategic merge patch**, y lo aplica con PATCH. Problemas:

- La anotación **duplica el objeto completo** — un ConfigMap de 300 KB rompe el límite de 256 KB de la anotación y el apply falla.
- La lógica de merge vive en el **cliente**, así que `kubectl` y `client-go` y todos los demás SDK deben reimplementarla de forma idéntica (y no lo hacen, exactamente).
- La propiedad es gruesa — la anotación registra *lo que enviaste*, no *qué campos poseés en exclusiva*.

### 3.2 Server-Side Apply (SSA) — beta en 1.16, **GA en 1.22**, el default moderno para controllers

Con `--server-side`, el cliente envía *solo tu intención* como un objeto parcial con `Content-Type: application/apply-patch+yaml`, etiquetado con un nombre de **field manager**. El **API server** hace el merge y registra, por campo, quién lo posee, en `.metadata.managedFields`:

```yaml
metadata:
  managedFields:
  - manager: kubectl                      # who
    operation: Apply                      # Apply (declarative) vs Update (imperative)
    apiVersion: apps/v1
    time: "2026-08-13T10:15:32Z"
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:replicas: {}                    # <- this manager owns .spec.replicas
        f:template:
          f:spec:
            f:containers:
              k:{"name":"web"}:           # keyed list entry (merge key = name)
                f:image: {}               # <- owns the image of container "web"
```

Ahora el servidor puede responder *"¿quién posee `.spec.replicas`?"* con precisión. Si dos managers intentan poseer el mismo campo con **valores distintos**, el servidor devuelve un **409 conflict** en vez de sobrescribir silenciosamente.

### 3.3 Estrategias de patch y semántica de merge de listas

El merge no es una superposición JSON ingenua. Los tipos built-in llevan struct tags de Go (`patchStrategy`, `patchMergeKey`); los CRDs expresan lo mismo vía OpenAPI `x-kubernetes-list-type`.

| Estrategia | Content-Type | Comportamiento de listas | Dónde se usa |
|---|---|---|---|
| **Strategic Merge Patch** | `application/strategic-merge-patch+json` | fusiona listas por **merge key** (ej. containers por `name`, ports por `containerPort`) | tipos built-in, CSA |
| **JSON Merge Patch (RFC 7386)** | `application/merge-patch+json` | las listas son **atómicas** — se reemplazan enteras | CRDs sin pistas de schema, `kubectl patch --type merge` |
| **JSON Patch (RFC 6902)** | `application/json-patch+json` | array explícito de op/path | `kubectl patch --type json` |
| **Apply Patch** | `application/apply-patch+yaml` | comportamiento de listas según `x-kubernetes-list-type` | Server-Side Apply |

Para SSA, el CRD (o el schema built-in) declara cómo se fusiona cada lista:

| `x-kubernetes-list-type` | Semántica | ¿Múltiples dueños? | Campo de ejemplo |
|---|---|---|---|
| `atomic` | toda la lista es una unidad; un dueño reemplaza todo | no — dueño único | `.spec.template.spec.tolerations` (en algunos tipos) |
| `set` | lista de escalares, deduplicada, insensible al orden | sí — por elemento | `.spec.finalizers` |
| `map` | lista asociativa indexada por `x-kubernetes-list-map-keys` | sí — por entrada indexada | `containers` (key `name`), `ports` (key `containerPort`) |

Por esto dos managers pueden poseer cada uno un *container distinto* en el mismo Pod spec, pero si el schema marca una lista como `atomic`, solo un manager puede poseer la lista entera. **Equivocarse con `x-kubernetes-list-type` en un CRD es una de las causas principales de "SSA no para de pelear con mi controller."**

---

## 4. Manifiestos completos y sesiones reales de CLI

### 4.1 El objeto de trabajo

`web.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      containers:
      - name: web
        image: registry.example.com/web:1.8.2
        ports:
        - name: http
          containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: "500m"
            memory: 256Mi
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 5
          periodSeconds: 10
```

### 4.2 Create → configure → unchanged (el bucle idempotente)

```console
$ kubectl apply -f web.yaml
deployment.apps/web created

$ sed -i 's/web:1.8.2/web:1.9.0/' web.yaml

$ kubectl apply -f web.yaml
deployment.apps/web configured

$ kubectl apply -f web.yaml
deployment.apps/web unchanged
```

Tres verbos distintos en la salida — `created`, `configured`, `unchanged` — son tu señal principal en CI: `unchanged` significa que la reconciliación es un no-op (sin drift); `configured` después de una corrida limpia del pipeline significa que alguien editó el cluster por fuera de banda.

### 4.3 Previsualizá antes de tocar prod — `kubectl diff`

```console
$ kubectl diff -f web.yaml
diff -u -N /tmp/LIVE-3517880123/apps.v1.Deployment.shop.web /tmp/MERGED-1029384756/apps.v1.Deployment.shop.web
--- /tmp/LIVE-3517880123/apps.v1.Deployment.shop.web    2026-08-13 10:20:11.000000000 +0000
+++ /tmp/MERGED-1029384756/apps.v1.Deployment.shop.web  2026-08-13 10:20:11.000000000 +0000
@@ -34,7 +34,7 @@
       containers:
       - name: web
-        image: registry.example.com/web:1.8.2
+        image: registry.example.com/web:1.9.0
         name: web
         ports:
         - containerPort: 8080
```

`kubectl diff` ejecuta un **dry-run del lado del servidor** (merge `--server-side` en memoria), así que muestra exactamente lo que calcularía el API server, incluyendo las mutaciones de los webhooks. El código de salida `1` significa "hay un diff" — utilizable como gate de drift en CI:

```console
$ kubectl diff -f web.yaml >/dev/null 2>&1 && echo "in sync" || echo "DRIFT"
DRIFT
```

### 4.4 Dry-run: client vs server

```console
$ kubectl apply -f web.yaml --dry-run=client
deployment.apps/web configured (dry run)

$ kubectl apply -f web.yaml --dry-run=server
deployment.apps/web configured (server dry run)
```

`--dry-run=client` solo valida el YAML localmente. `--dry-run=server` pasa el objeto por **admission** (validating + mutating webhooks, quota, defaulting) sin persistir — la única previsualización confiable, porque atrapa los rechazos de OPA/Kyverno y las mutaciones del injector. Preferí siempre `server` en los chequeos previos al deploy.

### 4.5 Server-Side Apply e inspección de la propiedad

```console
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied

$ kubectl get deploy web -n shop --show-managed-fields -o yaml | yq '.metadata.managedFields[] | {"manager": .manager, "operation": .operation}'
{"manager": "kubectl", "operation": "Apply"}
```

Notá el nuevo verbo en la salida: **`serverside-applied`**. Para ver *quién posee qué*:

```console
$ kubectl get deploy web -n shop --show-managed-fields \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
kubectl         Apply
```

Fijá un nombre estable de field-manager para la automatización (las herramientas GitOps hacen esto):

```console
$ kubectl apply --server-side --field-manager=argo-cd -f web.yaml
deployment.apps/web serverside-applied
```

### 4.6 El conflicto — y cómo resolverlo (migración canónica CSA→SSA)

Supongamos que el objeto se creó primero con apply **client-side** (manager `kubectl-client-side-apply`, operación `Update`), y luego un pipeline de plataforma cambia a SSA. El campo image ahora está en disputa:

```console
$ kubectl apply --server-side -f web.yaml
error: Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using apps/v1:
  .spec.template.spec.containers[name="web"].image
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

Las tres resoluciones documentadas mapean a tres decisiones reales de producción:

| Querés… | Hacé esto | Efecto en `managedFields` |
|---|---|---|
| **Tomar el control** del campo (sos el nuevo dueño registrado) | `kubectl apply --server-side --force-conflicts -f web.yaml` | tu manager pasa a ser dueño único; el otro manager lo pierde |
| **Dejárselo al otro manager** (ej. el HPA posee replicas) | quitá el campo de tu manifiesto | nunca lo reclamás; sin conflicto |
| **Co-poseerlo** (ambos deben acordar el valor) | mantené el campo pero fijalo al *valor vivo actual* | propiedad compartida; lo heredás si el otro manager lo suelta |

Tomar la propiedad por la fuerza:

```console
$ kubectl apply --server-side --force-conflicts -f web.yaml
deployment.apps/web serverside-applied
```

### 4.7 Eliminación de campos removidos (la historia de la eliminación)

Agregá una variable de entorno, aplicá, luego quitala y aplicá de nuevo:

```console
$ kubectl apply --server-side -f web-with-env.yaml
deployment.apps/web serverside-applied

# web.yaml no longer contains the env block
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied

$ kubectl get deploy web -n shop -o jsonpath='{.spec.template.spec.containers[0].env}'
                                     # empty — the field you stopped declaring was removed
```

Como SSA rastrea que *vos* poseías `.spec.template.spec.containers[name="web"].env`, quitarlo de tu manifiesto lo elimina — pero **solo ese campo**, nunca los campos que pertenecen al injector sidecar o al HPA.

### 4.8 Pruning de objetos — eliminar objetos completos que ya no están en tu conjunto de manifiestos

`apply` solo reconcilia los objetos que se le *dan*. Borrar un archivo de manifiesto **no** elimina el objeto. Dos mecanismos cierran esta brecha:

**Heredado (deprecado, peligroso):**

```console
$ kubectl apply -f ./manifests/ --prune -l app.kubernetes.io/part-of=storefront
```

Este prune basado en labels recorre una allowlist hardcodeada de tipos y puede eliminar objetos que nunca pretendiste (objetos de alcance de cluster a lo largo de todo el cluster). Tratalo como un peligro (footgun).

**Pruning basado en ApplySet (KEP-3659, alpha/beta — condicionado por una variable de entorno):**

```console
$ export KUBECTL_APPLYSET=true
$ kubectl apply -n shop --server-side --applyset=storefront --prune -f ./manifests/
namespace/shop unchanged
deployment.apps/web serverside-applied
service/web serverside-applied
configmap/web-config pruned          # was in the set last run, absent now → deleted
```

El `--applyset` nombra un objeto *padre* (un ConfigMap/Secret, o un CRD designado) que registra el conjunto de miembros vía labels `applyset.kubernetes.io/*`, así kubectl sabe *exactamente* qué objetos pertenecen a esta aplicación y solo poda esos. Este es el sucesor seguro y acotado de `--prune -l`.

### 4.9 Kustomize y stdin

```console
$ kubectl apply -k ./overlays/prod/
configmap/web-config-6t4h2b8f9c created
deployment.apps/web configured

$ kustomize build ./overlays/prod | kubectl apply --server-side -f -
deployment.apps/web serverside-applied
```

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Diagnosticar el aleteo de réplicas (peleando con el HPA)

Síntoma: las réplicas oscilan en cada corrida del pipeline. Confirmá la propiedad:

```console
$ kubectl get deploy web -n shop --show-managed-fields -o yaml | \
    yq '.metadata.managedFields[] | select(.fieldsV1.f:spec | has("f:replicas")) | .manager'
kubectl
horizontal-pod-autoscaler
```

Dos managers reclaman `.spec.replicas`. **Solución:** quitá `replicas` del manifiesto para que el HPA sea el dueño único:

```yaml
spec:
  # replicas: 3      <-- DELETE this line; the HPA owns it
  selector:
    ...
```

```console
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied
$ kubectl get deploy web -n shop --show-managed-fields -o yaml | \
    yq '[.metadata.managedFields[] | select(.fieldsV1.f:spec | has("f:replicas"))] | length'
1
```

Ahora queda exactamente un dueño y el aleteo se detiene. (Esta es la razón canónica por la que los manifiestos de Deployment en producción bajo HPA **omiten `replicas` por completo**.)

### 5.2 Diagnosticar "mezclé apply con edit/replace"

Síntoma: `apply` informa `configured` en un pipeline limpio, o los campos que quitaste siguen reapareciendo. Buscá un field manager ajeno con `operation: Update`:

```console
$ kubectl get deploy web -n shop --show-managed-fields \
    -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" / "}{.operation}{"\n"}{end}'
kubectl                 / Apply
kubectl-edit            / Update      # <- someone ran kubectl edit
```

**Solución:** reclamá los campos con `--server-side --force-conflicts`, luego prohibí las ediciones por fuera de banda (RBAC, admission policy). Para limpiar por completo los restos de CSA tras migrar a SSA, eliminá la anotación heredada:

```console
$ kubectl apply --server-side --force-conflicts -f web.yaml
$ kubectl annotate deploy web -n shop kubectl.kubernetes.io/last-applied-configuration-
```

### 5.3 Fallo por tamaño de anotación (solo CSA)

```console
$ kubectl apply -f big-configmap.yaml
The ConfigMap "app-data" is invalid: metadata.annotations: Too long: must have at most 262144 bytes
```

**Causa raíz:** la anotación `last-applied-configuration` duplica el objeto (grande). **Solución:** usá `--server-side`, que no guarda ninguna anotación:

```console
$ kubectl apply --server-side -f big-configmap.yaml
configmap/app-data serverside-applied
```

### 5.4 Comportamiento incorrecto del merge de listas en CRDs

Síntoma: SSA sobre un custom resource reemplaza una lista entera que esperabas que se fusionara, o dos controllers no pueden co-poseer una lista indexada. Inspeccioná el schema del CRD:

```console
$ kubectl get crd widgets.example.com -o jsonpath \
    ='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.rules}' | jq
{
  "type": "array",
  "x-kubernetes-list-type": "atomic"          # <- why it replaces wholesale
}
```

**Solución:** el autor del CRD debe declarar `x-kubernetes-list-type: map` + `x-kubernetes-list-map-keys: ["name"]` para la co-propiedad por entrada. Esta es una corrección de *schema*, no de cliente.

### 5.5 Tabla de referencia de errores comunes

| Síntoma / mensaje | Causa probable | Resolución |
|---|---|---|
| `Apply failed with N conflicts` | otro field manager posee esos campos | `--force-conflicts` (tomar el control), quitar el campo (ceder), o igualar el valor (co-poseer) |
| la salida dice `configured` en una corrida limpia de CI | cambio por fuera de banda con `kubectl edit`/`scale`/consola | encontrá el manager `Update` vía `--show-managed-fields`; reclamá + asegurá RBAC |
| un campo removido persiste en el cluster | el objeto se escribió por última vez de forma imperativa (sin last-applied / sin `managedFields` para él) | un apply SSA reclama la propiedad; a partir de ahí las eliminaciones se rastrean |
| `metadata.annotations: Too long` | objeto grande bajo CSA | cambiá a `--server-side` |
| borraste un archivo YAML pero el objeto sigue existiendo | `apply` nunca poda por defecto | prune con ApplySet (`--applyset --prune`), o `kubectl delete -f` |
| SSA reemplaza una lista entera inesperadamente | la lista del CRD es `atomic` | el CRD debe usar `x-kubernetes-list-type: map` con map keys |
| `error validating data: ...unknown field` | typo / apiVersion incorrecta vs schema vivo | `kubectl apply --dry-run=server`; corregí el campo o `--validate=strict` lo detecta temprano |

### 5.6 La secuencia dorada de verificación para cualquier cambio con `apply`

```console
$ kubectl apply --dry-run=server -f web.yaml        # passes admission?
$ kubectl diff -f web.yaml                           # exactly what changes?
$ kubectl apply --server-side -f web.yaml            # apply with ownership tracking
$ kubectl rollout status deploy/web -n shop          # did it converge?
deployment "web" successfully rolled out
$ kubectl diff -f web.yaml && echo "IN SYNC"         # drift gate: exit 0 == clean
IN SYNC
```

---

## 6. Referencias

- Gestión declarativa de objetos con `kubectl apply` — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Gestión de objetos de Kubernetes (resumen de las tres técnicas) — https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/
- Configuración imperativa de objetos con archivos de configuración — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/imperative-config/
- Server-Side Apply (gestión de campos, conflictos, managedFields) — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Referencia del comando `kubectl apply` — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/
- Referencia del comando `kubectl diff` — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_diff/
- Actualizar objetos de la API in situ usando `kubectl patch` (estrategias de merge) — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/
- Conceptos de la API de Kubernetes — content types de patch/apply y dry-run — https://kubernetes.io/docs/reference/using-api/api-concepts/
- Structural schemas y list types (`x-kubernetes-list-type`) para CRDs — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- KEP-3659: pruning basado en ApplySet para `kubectl apply --prune` — https://github.com/kubernetes/enhancements/tree/master/keps/sig-cli/3659-kubectl-apply-prune
- Field manager y conflictos de gestión de objetos de `kubectl` (blog, SSA GA) — https://kubernetes.io/blog/2021/08/06/server-side-apply-ga/