# 4.1 — Discover and use resources that extend Kubernetes (CRD, Operators)

## Por qué existe este tema

Kubernetes trae de fábrica un conjunto de recursos conocidos: `Pod`, `Deployment`, `Service`, `ConfigMap`, etc. Pero la plataforma está diseñada para ser **extensible**: cualquier persona puede definir tipos de recursos nuevos mediante **CustomResourceDefinitions (CRDs)** y automatizar su comportamiento con **controllers** — el patrón conocido como **Operator**.

En el examen CKAD no vas a escribir un Operator, pero sí se espera que sepas:

1. **Descubrir** qué recursos personalizados existen en un cluster (`kubectl api-resources`, `kubectl get crd`).
2. **Inspeccionar** su esquema (`kubectl explain`).
3. **Crear y manipular** instancias de esos recursos (custom resources) como si fueran recursos nativos.
4. Entender **qué es un Operator** y cómo se relaciona con los CRDs.

---

## 1. Custom Resources y CustomResourceDefinitions

### Conceptos

- Un **custom resource (CR)** es una extensión de la API de Kubernetes: un objeto de un tipo que no viene incluido por defecto (por ejemplo `Certificate`, `PrometheusRule`, `Backup`).
- Una **CustomResourceDefinition (CRD)** es el recurso *nativo* con el que le declarás a la API server ese tipo nuevo: su nombre, su grupo de API, sus versiones y su esquema de validación.

La relación es análoga a clase e instancia: la CRD define el tipo; los custom resources son las instancias.

```
CRD (define el tipo)          Custom Resources (instancias)
─────────────────────         ─────────────────────────────
crontabs.stable.example.com → CronTab "mi-crontab"
                              CronTab "backup-nocturno"
```

Una vez creada la CRD, la API server expone endpoints REST para ese tipo y `kubectl` lo trata como cualquier otro recurso: `get`, `describe`, `create`, `apply`, `delete`, `edit`, etc.

### Anatomía de una CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # El nombre DEBE ser <plural>.<group>
  name: crontabs.stable.example.com
spec:
  group: stable.example.com
  scope: Namespaced          # o Cluster
  names:
    plural: crontabs
    singular: crontab
    kind: CronTab
    shortNames:
      - ct
  versions:
    - name: v1
      served: true           # esta versión se sirve por la API
      storage: true          # esta versión se persiste en etcd
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cronSpec:
                  type: string
                image:
                  type: string
                replicas:
                  type: integer
```

Puntos que conviene memorizar para el examen:

| Campo | Qué controla |
|---|---|
| `metadata.name` | Debe ser exactamente `<plural>.<group>` |
| `spec.scope` | `Namespaced` (vive en un namespace) o `Cluster` (global, como un `Node`) |
| `spec.names.kind` | El `kind` que usás en los manifests de los CR |
| `spec.names.shortNames` | Alias para `kubectl` (como `svc` para `Service`) |
| `versions[].served` | Si la versión se puede consultar por la API |
| `versions[].storage` | Exactamente **una** versión debe tener `storage: true` |
| `openAPIV3Schema` | Validación estructural: la API server rechaza CRs que no cumplan el esquema |

### Crear la CRD y un custom resource

```bash
kubectl apply -f crontab-crd.yaml
```

```
customresourcedefinition.apiextensions.k8s.io/crontabs.stable.example.com created
```

Ahora podés crear instancias. Notá que el `apiVersion` del CR combina el `group` y la `version` de la CRD:

```yaml
apiVersion: stable.example.com/v1
kind: CronTab
metadata:
  name: mi-crontab
spec:
  cronSpec: "*/5 * * * *"
  image: busybox:1.36
  replicas: 2
```

```bash
kubectl apply -f mi-crontab.yaml
kubectl get crontabs
```

```
NAME         AGE
mi-crontab   10s
```

Y funcionan los alias y las operaciones habituales:

```bash
kubectl get ct                    # shortName
kubectl describe crontab mi-crontab
kubectl delete crontab mi-crontab
```

> **Importante:** una CRD sola es *solo datos*. Crear un `CronTab` no ejecuta nada: los objetos quedan guardados en etcd esperando que algún controller los lea y actúe. Ahí entran los Operators.

---

## 2. Descubrir recursos en un cluster (la habilidad clave del examen)

En el examen te pueden dar un cluster con CRDs ya instaladas y pedirte que crees una instancia. El flujo de descubrimiento es siempre el mismo:

### Paso 1 — ¿Qué recursos existen?

```bash
kubectl api-resources
```

```
NAME          SHORTNAMES   APIVERSION                     NAMESPACED   KIND
pods          po           v1                             true         Pod
deployments   deploy       apps/v1                        true         Deployment
crontabs      ct           stable.example.com/v1          true         CronTab
...
```

Filtros útiles:

```bash
kubectl api-resources --namespaced=true          # solo recursos con namespace
kubectl api-resources --api-group=stable.example.com
kubectl api-versions                             # lista los grupos/versiones servidos
```

### Paso 2 — ¿Qué CRDs hay instaladas?

Las CRDs son recursos de nivel cluster, se listan directamente:

```bash
kubectl get crd
```

```
NAME                          CREATED AT
crontabs.stable.example.com   2026-07-14T10:02:11Z
```

Y para ver el detalle completo (grupo, versiones, esquema):

```bash
kubectl describe crd crontabs.stable.example.com
kubectl get crd crontabs.stable.example.com -o yaml
```

### Paso 3 — ¿Qué campos acepta el recurso?

`kubectl explain` funciona con custom resources igual que con los nativos, siempre que la CRD tenga esquema (en `apiextensions.k8s.io/v1` es obligatorio):

```bash
kubectl explain crontab.spec
```

```
GROUP:      stable.example.com
KIND:       CronTab
VERSION:    v1

FIELD: spec <Object>

FIELDS:
  cronSpec      <string>
  image         <string>
  replicas      <integer>
```

Con `--recursive` ves el árbol completo de campos de una sola vez:

```bash
kubectl explain crontab --recursive
```

Este trío — `api-resources`, `get crd`, `explain` — resuelve casi cualquier pregunta de este tema sin necesidad de abrir la documentación.

---

## 3. Operators

### El patrón

Un **Operator** es la combinación de:

1. **CRDs** que modelan la aplicación o el dominio (ej.: `PostgresCluster`, `Certificate`).
2. Un **custom controller** (un Pod corriendo en el cluster, normalmente desplegado como `Deployment`) que observa esos recursos y ejecuta un **reconciliation loop**: compara el estado deseado (lo que declaraste en el `spec`) con el estado real y actúa para converger.

Es el mismo patrón que usan los controllers nativos (el Deployment controller crea ReplicaSets; el ReplicaSet controller crea Pods), aplicado a conocimiento operacional específico de una aplicación: instalar, hacer backups, actualizar versiones, rotar certificados, failover, etc.

```
Usuario                    Operator (controller)          Cluster
───────                    ─────────────────────          ───────
kubectl apply CR  ──────▶  watch: detecta el CR
                           reconcile: estado deseado
                           vs. estado real          ────▶ crea Pods, Secrets,
                                                          Services, etc.
                           actualiza .status del CR
```

### Ejemplo concreto: cert-manager

**cert-manager** es un Operator muy usado que gestiona certificados TLS. Instala CRDs como `Certificate`, `Issuer` y `ClusterIssuer`:

```bash
kubectl get crd | grep cert-manager
```

```
certificates.cert-manager.io           2026-07-14T09:15:02Z
certificaterequests.cert-manager.io    2026-07-14T09:15:02Z
clusterissuers.cert-manager.io         2026-07-14T09:15:03Z
issuers.cert-manager.io                2026-07-14T09:15:03Z
...
```

El usuario declara *qué* quiere:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: apps
spec:
  secretName: web-tls-secret
  dnsNames:
    - web.example.com
  issuerRef:
    name: mi-issuer
    kind: Issuer
```

Y el controller de cert-manager se encarga del *cómo*: solicita el certificado, lo renueva antes de que expire y lo guarda en el `Secret` indicado. Vos solo consultás el estado:

```bash
kubectl get certificate -n apps
```

```
NAME      READY   SECRET           AGE
web-tls   True    web-tls-secret   2m
```

### Cómo reconocer un Operator instalado

En el examen, si sospechás que hay un Operator en juego:

```bash
kubectl get crd                                  # ¿qué tipos agregó?
kubectl get pods -A | grep -i operator           # ¿dónde corre el controller?
kubectl get deploy -A                            # suele estar como Deployment
```

### El campo `status` y las subresources

Los CRs bien diseñados separan:

- `spec` — lo que el usuario desea (lo escribís vos).
- `status` — lo que el controller observa/reporta (lo escribe el Operator, si la CRD habilita la subresource `status`).

Por eso, para diagnosticar un CR que "no hace nada", el primer paso es:

```bash
kubectl describe <tipo> <nombre>     # mirar Status y Events
kubectl get <tipo> <nombre> -o yaml  # mirar .status y .metadata
```

Si `.status` está vacío y no hay eventos, casi seguro el controller no está corriendo o no está mirando ese namespace.

---

## 4. Chuleta rápida para el examen

```bash
# Descubrimiento
kubectl api-resources                          # todos los tipos, con shortnames y group
kubectl api-resources --api-group=<grupo>
kubectl get crd                                # CRDs instaladas
kubectl explain <tipo> --recursive             # esquema de campos

# Uso de un custom resource (igual que un recurso nativo)
kubectl get <plural|shortname> [-n ns]
kubectl describe <tipo> <nombre>
kubectl apply -f cr.yaml
kubectl edit <tipo> <nombre>
kubectl delete <tipo> <nombre>

# Datos que salen de la CRD para escribir un CR
#   apiVersion: <spec.group>/<versions[].name>
#   kind:       <spec.names.kind>
```

Errores típicos a evitar:

- Usar un `apiVersion` que no combina bien `group` y `version` de la CRD (revisalo con `kubectl get crd <nombre> -o yaml`).
- Crear un CR `Namespaced` sin `-n` en el namespace equivocado.
- Esperar que la CRD "haga algo" por sí sola: sin controller/Operator, un CR es solo un documento almacenado.
- Olvidar que `kubectl explain` también funciona con custom resources — es la forma más rápida de ver qué campos acepta el `spec`.

---

## Referencias

- Custom Resources (conceptos): https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend the Kubernetes API with CustomResourceDefinitions (tutorial oficial): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Operator pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Versions in CustomResourceDefinitions: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Referencia de `kubectl api-resources`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#api-resources
- Referencia de `kubectl explain`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#explain
- cert-manager (ejemplo de Operator): https://cert-manager.io/docs/
- Curriculum oficial CKAD v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf