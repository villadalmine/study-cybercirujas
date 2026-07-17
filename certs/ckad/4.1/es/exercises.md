# Ejercicios guiados — 4.1 Discover and use resources that extend Kubernetes (CRD, Operators)

> **Requisitos:** un cluster de práctica (minikube, kind o similar) y `kubectl` configurado. Todos los ejercicios se hacen con permisos de administrador del cluster. Al final hay una sección de limpieza.

---

## Ejercicio 1 — Descubrir qué recursos expone la API

Antes de extender Kubernetes, hay que saber qué recursos ya existen y cómo explorarlos. Estas son las herramientas de descubrimiento que vas a usar todo el tiempo en el examen.

1. Listá todos los tipos de recursos que conoce tu cluster:

   ```bash
   kubectl api-resources
   ```

   Observá las columnas: `NAME` (plural), `SHORTNAMES`, `APIVERSION`, `NAMESPACED` y `KIND`.

2. Filtrá solo los recursos que **no** viven dentro de un namespace:

   ```bash
   kubectl api-resources --namespaced=false
   ```

3. Listá los recursos de un API group específico:

   ```bash
   kubectl api-resources --api-group=apps
   ```

4. Ahora mirá las **versiones** de API disponibles (group/version), que es otra cosa distinta:

   ```bash
   kubectl api-versions
   ```

5. Explorá el schema de un recurso con `kubectl explain`, bajando por sus campos:

   ```bash
   kubectl explain deployments
   kubectl explain deployments.spec.strategy
   kubectl explain deployments.spec.template.spec.containers --recursive | head -30
   ```

**Pregunta 1.** ¿Qué diferencia hay entre lo que muestra `kubectl api-resources` y lo que muestra `kubectl api-versions`?

**Pregunta 2.** En la salida de `api-resources`, ¿para qué sirve la columna `SHORTNAMES`? Dá un ejemplo que ya uses sin darte cuenta.

**Pregunta 3.** Nombrá dos recursos con `NAMESPACED=false` y explicá por qué tiene sentido que sean cluster-scoped.

---

## Ejercicio 2 — Inspeccionar las CustomResourceDefinitions del cluster

Una **CustomResourceDefinition (CRD)** es un recurso de Kubernetes que define un *nuevo tipo* de recurso. Es la forma estándar de extender la API sin recompilar nada.

1. Listá las CRDs instaladas (en un cluster nuevo puede no haber ninguna; en uno real vas a ver varias):

   ```bash
   kubectl get crd
   ```

2. Fijate a qué API group pertenecen las CRDs *en sí mismas*:

   ```bash
   kubectl api-resources | grep customresourcedefinitions
   ```

3. Si tu cluster tiene alguna CRD (por ejemplo de un ingress controller o de una herramienta de CNI), inspeccionala:

   ```bash
   kubectl describe crd <nombre>
   ```

   Buscá en la salida: `Group`, `Scope`, `Names` (kind, plural, singular, shortNames) y `Versions`.

**Pregunta 4.** El nombre de toda CRD sigue un formato fijo. ¿Cuál es y por qué?

**Pregunta 5.** ¿A qué API group y versión pertenece el recurso `CustomResourceDefinition`?

---

## Ejercicio 3 — Crear tu propia CRD

Vas a definir un nuevo tipo llamado `Backup`, con validación de schema y columnas propias en `kubectl get`.

1. Creá el archivo `backup-crd.yaml`:

   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     # Obligatorio: <plural>.<group>
     name: backups.training.example.com
   spec:
     group: training.example.com
     scope: Namespaced
     names:
       kind: Backup
       plural: backups
       singular: backup
       shortNames:
         - bk
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
                 required: ["source"]
                 properties:
                   source:
                     type: string
                   schedule:
                     type: string
                   retentionDays:
                     type: integer
                     minimum: 1
         additionalPrinterColumns:
           - name: Source
             type: string
             jsonPath: .spec.source
           - name: Schedule
             type: string
             jsonPath: .spec.schedule
           - name: Age
             type: date
             jsonPath: .metadata.creationTimestamp
   ```

2. Aplicala y verificá que el nuevo tipo existe:

   ```bash
   kubectl apply -f backup-crd.yaml
   kubectl get crd backups.training.example.com
   ```

3. Confirmá que el descubrimiento de la API ya lo ve:

   ```bash
   kubectl api-resources --api-group=training.example.com
   ```

4. Pedile el schema al API server, igual que con un recurso nativo:

   ```bash
   kubectl explain backup
   kubectl explain backup.spec
   ```

5. Listá los backups (todavía no creaste ninguno):

   ```bash
   kubectl get backups
   ```

**Pregunta 6.** En `spec.versions[]`, ¿qué significan los campos `served` y `storage`? ¿Cuántas versiones pueden tener `storage: true` a la vez?

**Pregunta 7.** El paso 5 no da error a pesar de que no existe ningún `Backup`. ¿Qué te dice eso sobre lo que hizo el API server al aplicar la CRD?

**Pregunta 8.** ¿Por qué `kubectl explain backup.spec` funciona y muestra los campos `source`, `schedule` y `retentionDays`?

---

## Ejercicio 4 — Crear y manipular custom resources

Con la CRD instalada, los objetos `Backup` se manejan con los mismos verbos de siempre: `apply`, `get`, `describe`, `patch`, `delete`.

1. Creá el archivo `mi-backup.yaml`:

   ```yaml
   apiVersion: training.example.com/v1
   kind: Backup
   metadata:
     name: backup-db
   spec:
     source: /data/postgres
     schedule: "0 3 * * *"
     retentionDays: 7
   ```

2. Aplicalo y listalo usando el shortname y las printer columns que definiste:

   ```bash
   kubectl apply -f mi-backup.yaml
   kubectl get bk
   ```

   Deberías ver las columnas `SOURCE`, `SCHEDULE` y `AGE`.

3. Probá que la **validación del schema** funciona. Intentá aplicar un backup inválido:

   ```bash
   kubectl apply -f - <<EOF
   apiVersion: training.example.com/v1
   kind: Backup
   metadata:
     name: backup-roto
   spec:
     source: /data/mysql
     retentionDays: 0
   EOF
   ```

   Leé el mensaje de error completo.

4. Modificá el recurso existente con `patch`:

   ```bash
   kubectl patch backup backup-db --type=merge -p '{"spec":{"retentionDays":30}}'
   kubectl get backup backup-db -o jsonpath='{.spec.retentionDays}{"\n"}'
   ```

5. Mirá el objeto completo tal como quedó almacenado:

   ```bash
   kubectl get backup backup-db -o yaml
   ```

**Pregunta 9.** ¿Por qué falló el paso 3? ¿Qué componente rechazó el objeto y en qué momento?

**Pregunta 10.** Si ahora ejecutaras `kubectl delete crd backups.training.example.com`, ¿qué pasaría con el objeto `backup-db`? (No lo hagas todavía.)

**Pregunta 11.** El `Backup` quedó creado, pero ningún backup real va a ocurrir en el cluster. ¿Por qué?

---

## Ejercicio 5 — El patrón Operator

La pregunta 11 apunta al corazón del tema: una CRD solo agrega *datos* a la API. Para que esos datos produzcan *acciones* hace falta un **controller** que los observe. Un **Operator** = CRDs + un controller que ejecuta un *reconciliation loop*: observa el estado deseado (el custom resource) y trabaja para que el estado real coincida.

1. Observá que tu `Backup` no tiene `status` y nunca lo va a tener:

   ```bash
   kubectl get backup backup-db -o yaml | grep -A5 "^status:" || echo "sin status"
   ```

   En un recurso gestionado por un operator (como los que crea cert-manager o un database operator), el controller escribiría ahí el estado observado.

2. Aprendé a **reconocer un operator instalado** en un cluster ajeno — habilidad típica de examen. Un operator casi siempre se ve como: (a) una o más CRDs, y (b) un Deployment corriendo el controller. Simulá la búsqueda:

   ```bash
   # (a) ¿qué tipos custom hay y de qué grupos?
   kubectl get crd -o custom-columns=NAME:.metadata.name,GROUP:.spec.group

   # (b) ¿qué deployments parecen controllers/operators?
   kubectl get deployments -A | grep -Ei 'operator|controller' || true
   ```

3. Comparación mental con un recurso nativo: `Deployment` también es "estado deseado + controller". Verificá que su controller vive dentro del control plane:

   ```bash
   kubectl get pods -n kube-system | grep controller-manager
   ```

   La diferencia con un operator es *dónde* corre el controller y *quién* lo escribió, no el patrón.

**Pregunta 12.** Definí con tus palabras qué es un operator y qué le agrega a una CRD sola.

**Pregunta 13.** ¿Qué es el *reconciliation loop* (también llamado *control loop*)?

**Pregunta 14.** En el examen te dan un cluster y te piden "crear un recurso del tipo que gestiona el operator X ya instalado". Escribí la secuencia de comandos que usarías para descubrir el kind, su API version y sus campos, sin acceso a documentación externa (salvo kubernetes.io).

---

## Limpieza

```bash
kubectl delete backup backup-db
kubectl delete crd backups.training.example.com
rm -f backup-crd.yaml mi-backup.yaml
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**Respuesta 1.** `kubectl api-resources` lista los **tipos de recursos** (kinds) disponibles con sus atributos (plural, shortnames, si son namespaced). `kubectl api-versions` lista los pares **group/version** servidos por el API server (por ejemplo `apps/v1`, `training.example.com/v1`). Uno responde "¿qué objetos puedo crear?"; el otro, "¿qué versiones de API existen?".

**Respuesta 2.** Los shortnames son alias cortos aceptados por `kubectl`. Ejemplos que usás a diario: `po` (pods), `svc` (services), `deploy` (deployments). Las CRDs pueden definir los suyos, como el `bk` del ejercicio 3.

**Respuesta 3.** Ejemplos: `nodes` (un nodo es infraestructura física/virtual del cluster, no pertenece a ningún namespace), `persistentvolumes` (el almacenamiento se provisiona a nivel cluster y luego se reclama desde namespaces vía PVC), `namespaces` (no puede vivir dentro de sí mismo) y la propia `customresourcedefinitions` (define tipos para todo el cluster).

**Respuesta 4.** El formato obligatorio es `<plural>.<group>`, por ejemplo `backups.training.example.com`. Garantiza unicidad global: dos organizaciones pueden definir un kind `Backup` sin colisionar, porque el group (un dominio DNS que controlan) los distingue.

**Respuesta 5.** Al group `apiextensions.k8s.io`, versión `v1`. Es decir: las CRDs se crean usando un recurso que a su vez es parte de la API — Kubernetes se extiende con sus propios mecanismos.

**Respuesta 6.** `served: true` significa que esa versión se puede leer y escribir vía la API. `storage: true` marca la versión en la que los objetos se **persisten en etcd**. Exactamente **una** versión puede tener `storage: true`; puede haber varias `served` a la vez (útil durante migraciones de versión).

**Respuesta 7.** Que al aplicar la CRD, el API server registró un **endpoint REST nuevo** (`/apis/training.example.com/v1/namespaces/*/backups`) de forma dinámica, sin reiniciar nada. `kubectl get backups` consulta ese endpoint y recibe una lista vacía válida — el tipo existe aunque no haya instancias.

**Respuesta 8.** Porque la CRD incluye un `openAPIV3Schema` en `spec.versions[].schema`. El API server publica ese schema en su documento OpenAPI, y `kubectl explain` lo consume igual que hace con los tipos nativos. Sin schema estructural (obligatorio en `apiextensions.k8s.io/v1`), `explain` no tendría nada que mostrar.

**Respuesta 9.** Falló dos veces en una: `retentionDays: 0` viola el `minimum: 1` del schema. Quien rechaza es el **API server** durante la **validación de admisión**, es decir *antes* de persistir el objeto en etcd. Por eso la validación por schema es la primera línea de defensa: los objetos inválidos nunca llegan a existir. (Notá que `source` sí estaba presente; si lo quitaras, también fallaría por el `required: ["source"]`.)

**Respuesta 10.** Se borraría también `backup-db` y cualquier otro `Backup` existente. Eliminar una CRD elimina **en cascada todos los custom resources de ese tipo** en todos los namespaces, además del endpoint de la API. Por eso borrar CRDs en producción es una operación peligrosa.

**Respuesta 11.** Porque una CRD solo define un **tipo de dato** en la API: el objeto `Backup` es una entrada declarativa en etcd y nada más. No hay ningún **controller** observando (`watch`) esos objetos para ejecutar la lógica de backup. Sin controller, el estado deseado nunca se convierte en acción.

**Respuesta 12.** Un operator es la combinación de **custom resources (vía CRDs) + un controller propio** que codifica conocimiento operacional de una aplicación: instalarla, actualizarla, hacer backups, recuperarla de fallos. La CRD aporta el "sustantivo" (el nuevo tipo declarativo); el operator aporta el "verbo": un proceso (normalmente un Deployment dentro del cluster) que observa esos objetos y actúa para materializarlos, escribiendo el progreso en `status`.

**Respuesta 13.** Es el ciclo continuo *observar → comparar → actuar*: el controller observa el estado real del sistema, lo compara con el estado deseado declarado en `spec`, y ejecuta las acciones necesarias para acercar el real al deseado. Es el mismo patrón de los controllers nativos (el deployment controller creando ReplicaSets); los operators lo aplican a dominios específicos.

**Respuesta 14.** Una secuencia razonable:

```bash
# 1. Ver qué tipos custom existen y ubicar el del operator
kubectl get crd
kubectl api-resources | grep <grupo-o-palabra-clave>

# 2. Obtener kind, group/version y shortnames exactos
kubectl describe crd <plural>.<group>

# 3. Explorar los campos del spec para escribir el YAML
kubectl explain <kind> --recursive | less
kubectl explain <kind>.spec

# 4. (Atajo) Si ya existe una instancia, usarla de plantilla
kubectl get <kind> -A
kubectl get <kind> <nombre> -n <ns> -o yaml
```

Con `apiVersion` (= `<group>/<version>`), `kind` y los campos de `spec` ya podés redactar y aplicar el manifiesto.

</details>

---

## Fuentes

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Custom Resources: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — Extend the Kubernetes API with CustomResourceDefinitions: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — Operator pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Kubernetes — kubectl api-resources / explain: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_api-resources/ y https://kubernetes.io/docs/reference/kubectl/generated/kubectl_explain/