# CNPE 5.1 — Diseño y creación de Custom Resource Definitions (CRDs) para Platform Services

> **Dominio:** Platform Engineering / Extensibilidad de la API de Kubernetes
> **Peso en el examen:** 6.25 %
> **Perfil:** Platform Architect / SRE Senior
> **Prerrequisitos mentales:** modelo declarativo de Kubernetes, `apiextensions.k8s.io`, OpenAPI v3, admission control, control loops.

---

## 1. Motivación: el CRD como contrato de API de tu plataforma

### 1.1 El problema arquitectónico de producción

Una Internal Developer Platform (IDP) existe para ofrecer **self-service con guardarraíles**: un desarrollador pide "una base de datos Postgres HA con backups" y no debería tener que conocer StatefulSets, PVCs, PodDisruptionBudgets, CronJobs de backup ni NetworkPolicies. El problema es *dónde vive ese contrato*.

Las plataformas inmaduras codifican ese contrato de tres formas frágiles:

1. **ConfigMaps + convenciones**: el "esquema" es un `README`. No hay validación, no hay tipado, no hay RBAC granular, no hay `kubectl get databases`. Un typo en `replicas: "3"` (string) se descubre en runtime.
2. **Módulos Terraform / Helm charts como interfaz**: obligan a un flujo *push* fuera del cluster (CI, `terraform apply`), rompen la reconciliación continua y no se integran con el modelo watch/reconcile de Kubernetes. El estado deseado no es un objeto del cluster.
3. **Un API server propio (aggregated API)**: potente pero costoso — requiere operar un binario extra, TLS, storage propio o delegación a etcd, y una superficie de mantenimiento considerable.

El **Custom Resource Definition (CRD)** resuelve exactamente este hueco: **extiende la API declarativa de Kubernetes con tus propios tipos** (`kind: Database`, `kind: TenantNamespace`, `kind: MessageQueue`) que se comportan como recursos nativos:

- Se almacenan en **etcd** vía el mismo `kube-apiserver`.
- Heredan **RBAC**, **admission webhooks**, **audit logging**, **field selectors**, **watch**, **`kubectl`**, **labels/annotations** y **owner references**.
- Definen un **contrato tipado y versionado** validado por **OpenAPI v3 structural schema** antes de tocar el datastore.

El CRD es la **cara declarativa** de la plataforma; el **controller/operator** (tema aparte) es la mecánica que reconcilia ese deseo hacia el mundo real. Diseñar bien el CRD es diseñar la API pública de tu plataforma — y como toda API pública, **el versionado y la validación no son opcionales**.

### 1.2 Qué es realmente un CRD por dentro

`apiextensions-apiserver` es un componente *embebido* dentro de `kube-apiserver`. Cuando aplicás un objeto `CustomResourceDefinition`:

1. `apiextensions-apiserver` valida el propio CRD (nombres, esquema estructural).
2. Registra dinámicamente un nuevo grupo/versión/recurso (**GVR**) en el **discovery** y en el **RESTStorage**.
3. Cada instancia (Custom Resource, CR) que creás pasa por la cadena estándar: **authentication → authorization (RBAC) → mutating admission → schema validation → validating admission → etcd**.
4. El objeto queda disponible en watch/list/get igual que un Pod.

No hay proceso extra corriendo: el CRD es *pura configuración* del apiserver. Ese es su gran atractivo operativo frente al aggregated API server.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 CRD vs. las alternativas de extensión

| Criterio | ConfigMap + convención | Helm/Terraform como interfaz | **CRD + controller** | Aggregated API Server |
|---|---|---|---|---|
| Tipado / validación de esquema | Ninguno (todo string) | Fuera del cluster | **OpenAPI v3 + CEL** en admission | Código Go arbitrario |
| Reconciliación continua | No | No (push, drift silencioso) | **Sí (watch/reconcile)** | Sí |
| Superficie operativa | Mínima | CI externo | **CRD (config) + 1 Deployment** | Binario + TLS + storage |
| Storage | etcd (opaco) | Estado externo | **etcd (tipado)** | Propio o delegado a etcd |
| RBAC granular por tipo | No | No | **Sí (por GVR/verbo)** | Sí |
| Subresources (`/status`, `/scale`) | No | No | **Sí** | Sí (a medida) |
| Lógica de admission a medida | No | No | Webhooks | **Nativa en el server** |
| Casos límite (validación cruzada compleja, campos calculados, protobuf, storage a medida) | — | — | Limitado | **Sí** |

**Regla de decisión:** empezá siempre con **CRD**. Migrá a **aggregated API server** solo si necesitás algo que el CRD no da: campos calculados/virtuales no persistidos, validación con acceso a otros recursos en el propio path del server, serialización protobuf, o control fino del storage. En >95 % de las plataformas, el CRD es suficiente.

### 2.2 Estrategias de esquema

| Enfoque | Cuándo usar | Riesgo |
|---|---|---|
| **Structural schema completo** (recomendado, obligatorio en `v1`) | Siempre, para todo campo conocido | Ninguno; es el default correcto |
| `x-kubernetes-preserve-unknown-fields: true` | Campos con forma libre genuina (ej. `podTemplate` embebido, config passthrough) | Desactiva pruning; entra basura a etcd; **acota su alcance** a un subárbol |
| `x-kubernetes-embedded-resource: true` | Embeber un objeto Kubernetes completo (con `apiVersion/kind/metadata`) | Debe combinarse con preserve-unknown o esquema completo |
| `x-kubernetes-int-or-string` | Campos tipo `intstr` (ej. puertos, `maxUnavailable`) | Validación más laxa |

### 2.3 Validación: OpenAPI v3 vs. CEL (`x-kubernetes-validations`)

| Necesidad | OpenAPI v3 (`enum`, `pattern`, `minimum`, `required`) | **CEL** (`x-kubernetes-validations`, GA en 1.25) | Validating Webhook |
|---|---|---|---|
| Rango / regex / enum de un campo | ✅ Ideal | Posible pero innecesario | Sobredimensionado |
| Reglas cruzadas (`minReplicas <= maxReplicas`) | ❌ Imposible | ✅ **`self.minReplicas <= self.maxReplicas`** | ✅ (pero requiere operar un servicio) |
| Inmutabilidad de un campo | ❌ | ✅ **`self == oldSelf`** con `transition rules` | ✅ |
| Validación contra *otros recursos* del cluster | ❌ | ❌ | ✅ Único que puede |
| Costo operativo | Cero | Cero (in-process) | Alto (TLS, disponibilidad, latencia en el path) |

**Trade-off central:** CEL cubre hoy la mayoría de la validación cruzada **sin operar un webhook**. Reservá los validating webhooks para lo que CEL no puede: decisiones que dependen del estado de *otros* objetos del cluster.

### 2.4 Estrategias de conversión de versiones

| `conversion.strategy` | Coste | Cuándo |
|---|---|---|
| `None` | Cero | Todas las versiones son *idénticas* en estructura (solo cambia el nombre) — raro en la práctica |
| `Webhook` | Operar un servicio HTTPS | Cambios reales de shape entre versiones (renombrar/mover campos) |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 CRD de producción: `Database` (multi-versión, CEL, subresources, printer columns)

Este es un CRD de plataforma realista. Expone `v1alpha1` (deprecada, no-storage) y `v1` (storage), con validación estructural, defaulting, reglas CEL de validación cruzada e inmutabilidad, subresources `/status` y `/scale`, columnas de impresión, categorías y short names.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.platform.acme.io          # DEBE ser <plural>.<group>
  labels:
    app.kubernetes.io/part-of: acme-platform
spec:
  group: platform.acme.io
  scope: Namespaced                          # o Cluster para recursos globales
  names:
    plural: databases
    singular: database
    kind: Database
    listKind: DatabaseList
    shortNames: ["db", "dbs"]
    categories: ["acme", "all"]              # 'kubectl get acme' los agrupa
  conversion:
    strategy: Webhook
    webhook:
      conversionReviewVersions: ["v1"]
      clientConfig:
        service:
          namespace: acme-platform-system
          name: database-conversion-webhook
          path: /convert
          port: 443
        # caBundle lo inyecta cert-manager (ca-injector) en runtime
  versions:
    # ---------- v1alpha1: deprecada, servida pero NO de storage ----------
    - name: v1alpha1
      served: true
      storage: false
      deprecated: true
      deprecationWarning: "platform.acme.io/v1alpha1 Database está deprecada; migrá a v1."
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                engine:
                  type: string
                size:
                  type: string
              required: ["engine"]
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
      subresources:
        status: {}
    # ---------------------- v1: versión de storage ----------------------
    - name: v1
      served: true
      storage: true                          # EXACTAMENTE una versión con storage:true
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
                  description: "Motor de base de datos."
                version:
                  type: string
                  pattern: '^[0-9]+(\.[0-9]+)?$'
                  description: "Versión mayor.menor del engine, p.ej. '16' o '16.2'."
                storageGiB:
                  type: integer
                  minimum: 1
                  maximum: 4096
                  default: 20
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 9
                  default: 1
                highAvailability:
                  type: object
                  default: {enabled: false}
                  properties:
                    enabled:
                      type: boolean
                      default: false
                    minReplicas:
                      type: integer
                      minimum: 1
                    maxReplicas:
                      type: integer
                      minimum: 1
                  x-kubernetes-validations:
                    - rule: "!has(self.minReplicas) || !has(self.maxReplicas) || self.minReplicas <= self.maxReplicas"
                      message: "minReplicas no puede superar a maxReplicas."
                backup:
                  type: object
                  properties:
                    schedule:
                      type: string
                      pattern: '^(@(daily|hourly|weekly|monthly))|(([0-9*/,-]+\s+){4}[0-9*/,-]+)$'
                    retentionDays:
                      type: integer
                      minimum: 1
                      default: 7
                # passthrough acotado: solo este subárbol acepta forma libre
                engineParameters:
                  type: object
                  x-kubernetes-preserve-unknown-fields: true
              # --- validación a nivel del objeto spec (CEL) ---
              x-kubernetes-validations:
                - rule: "self.engine != 'postgres' || int(self.version.split('.')[0]) >= 13"
                  message: "Postgres requiere versión mayor >= 13."
                - rule: "!self.highAvailability.enabled || self.replicas >= 2"
                  message: "highAvailability.enabled requiere replicas >= 2."
                - rule: "self.engine == oldSelf.engine"
                  message: "El campo 'engine' es inmutable."
                  # esta transition rule solo se evalúa en UPDATE
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: ["Pending", "Provisioning", "Ready", "Degraded", "Failed"]
                observedGeneration:
                  type: integer
                readyReplicas:
                  type: integer
                endpoint:
                  type: string
                conditions:
                  type: array
                  # list-type=map: merge por 'type', no reemplazo atómico
                  x-kubernetes-list-type: map
                  x-kubernetes-list-map-keys: ["type"]
                  items:
                    type: object
                    required: ["type", "status", "lastTransitionTime", "reason"]
                    properties:
                      type: {type: string}
                      status: {type: string, enum: ["True", "False", "Unknown"]}
                      lastTransitionTime: {type: string, format: date-time}
                      reason: {type: string}
                      message: {type: string}
      subresources:
        status: {}                            # habilita /status (spec y status se escriben por separado)
        scale:                                # habilita kubectl scale / HPA
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.readyReplicas
          labelSelectorPath: .status.labelSelector
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Version
          type: string
          jsonPath: .spec.version
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Endpoint
          type: string
          priority: 1                          # priority>0 → solo con 'kubectl get -o wide'
          jsonPath: .status.endpoint
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

### 3.2 Instancia (Custom Resource) que ese CRD acepta

```yaml
apiVersion: platform.acme.io/v1
kind: Database
metadata:
  name: orders-db
  namespace: team-checkout
spec:
  engine: postgres
  version: "16.2"
  storageGiB: 100
  replicas: 3
  highAvailability:
    enabled: true
    minReplicas: 2
    maxReplicas: 3
  backup:
    schedule: "@daily"
    retentionDays: 30
  engineParameters:
    shared_buffers: "2GB"
    max_connections: "300"
```

### 3.3 RBAC de plataforma: quién puede tocar el nuevo tipo

El CRD hereda RBAC por GVR. Este es el patrón de producción: los equipos de aplicación gestionan `databases` en su namespace; solo la plataforma toca `/status`.

```yaml
# Rol para equipos: CRUD del recurso, NUNCA del status
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: acme:database-user
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
# El controller de plataforma: además escribe el subresource /status
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: acme:database-controller
rules:
  - apiGroups: ["platform.acme.io"]
    resources: ["databases"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["platform.acme.io"]
    resources: ["databases/status"]        # subresource como recurso propio en RBAC
    verbs: ["get", "update", "patch"]
  - apiGroups: ["platform.acme.io"]
    resources: ["databases/finalizers"]
    verbs: ["update"]
```

### 3.4 Conversion webhook (esqueleto de infraestructura)

Cuando `conversion.strategy: Webhook`, necesitás el servicio que lo sirve y la inyección del `caBundle`. Con cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: database-conversion-webhook
  namespace: acme-platform-system
spec:
  secretName: database-conversion-webhook-tls
  dnsNames:
    - database-conversion-webhook.acme-platform-system.svc
    - database-conversion-webhook.acme-platform-system.svc.cluster.local
  issuerRef:
    name: platform-selfsigned
    kind: Issuer
---
apiVersion: v1
kind: Service
metadata:
  name: database-conversion-webhook
  namespace: acme-platform-system
spec:
  selector:
    app.kubernetes.io/name: database-operator
  ports:
    - port: 443
      targetPort: 9443
```

> El apiserver inyecta el warning de deprecación (`deprecationWarning`) y, con la annotation `cert-manager.io/inject-ca-from`, el `ca-injector` rellena `spec.conversion.webhook.clientConfig.caBundle` en el CRD automáticamente.

---

## 4. Comandos CLI y salidas reales

### 4.1 Aplicar y verificar el registro del CRD

```console
$ kubectl apply -f database-crd.yaml
customresourcedefinition.apiextensions.k8s.io/databases.platform.acme.io created

$ kubectl get crd databases.platform.acme.io
NAME                          CREATED AT
databases.platform.acme.io    2026-08-07T14:22:10Z

$ kubectl api-resources --api-group=platform.acme.io
NAME        SHORTNAMES   APIVERSION               NAMESPACED   KIND
databases   db,dbs       platform.acme.io/v1      true         Database

$ kubectl api-versions | grep platform.acme.io
platform.acme.io/v1
platform.acme.io/v1alpha1
```

### 4.2 El esquema es descubrible vía `kubectl explain`

```console
$ kubectl explain database.spec --recursive=false
GROUP:      platform.acme.io
KIND:       Database
VERSION:    v1

FIELD: spec <Object>

DESCRIPTION:
    <empty>
FIELDS:
  backup             <Object>
  engine             <string> -required-
  engineParameters   <Object>
  highAvailability   <Object>
  replicas           <integer>
  storageGiB         <integer>
  version            <string> -required-

$ kubectl explain database.spec.engine
GROUP:      platform.acme.io
KIND:       Database
VERSION:    v1

FIELD: engine <string>
DESCRIPTION:
    Motor de base de datos.
```

### 4.3 Crear una instancia y ver defaulting + printer columns

```console
$ kubectl apply -f orders-db.yaml
database.platform.acme.io/orders-db created

$ kubectl get databases -n team-checkout
NAME        ENGINE     VERSION   REPLICAS   PHASE         AGE
orders-db   postgres   16.2      3          Provisioning  8s

$ kubectl get db orders-db -n team-checkout -o wide
NAME        ENGINE     VERSION   REPLICAS   PHASE   ENDPOINT                              AGE
orders-db   postgres   16.2      3          Ready   orders-db.team-checkout.svc:5432      2m

$ kubectl get acme -n team-checkout        # category en acción
NAME                             ENGINE     VERSION   REPLICAS   PHASE   AGE
database.platform.acme.io/orders-db   postgres   16.2      3     Ready   2m
```

Comprobá que el default se aplicó (no pusimos `retentionDays` en `backup`… sí lo pusimos; probemos con uno mínimo):

```console
$ kubectl create -n team-checkout -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: {name: cache-meta}
spec: {engine: mysql, version: "8.0"}
EOF
database.platform.acme.io/cache-meta created

$ kubectl get db cache-meta -n team-checkout -o jsonpath='{.spec.storageGiB}{"\n"}{.spec.replicas}{"\n"}'
20
1
```

### 4.4 Validación rechazando payloads inválidos (OpenAPI y CEL)

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: {name: bad-engine, namespace: team-checkout}
spec: {engine: oracle, version: "19"}
EOF
The Database "bad-engine" is invalid: spec.engine: Unsupported value: "oracle":
  supported values: "postgres", "mysql", "mariadb"

$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: {name: old-pg, namespace: team-checkout}
spec: {engine: postgres, version: "11"}
EOF
The Database "old-pg" is invalid: spec: Invalid value: "object":
  Postgres requiere versión mayor >= 13.

$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: {name: ha-bad, namespace: team-checkout}
spec:
  engine: postgres
  version: "16"
  replicas: 1
  highAvailability: {enabled: true}
EOF
The Database "ha-bad" is invalid: spec: Invalid value: "object":
  highAvailability.enabled requiere replicas >= 2.
```

Inmutabilidad (transition rule CEL) en un `update`:

```console
$ kubectl patch db orders-db -n team-checkout --type merge -p '{"spec":{"engine":"mysql"}}'
The Database "orders-db" is invalid: spec: Invalid value: "object":
  El campo 'engine' es inmutable.
```

### 4.5 Subresources en acción: `/scale` y `/status`

```console
$ kubectl scale database orders-db -n team-checkout --replicas=5
database.platform.acme.io/orders-db scaled

$ kubectl get db orders-db -n team-checkout -o jsonpath='{.spec.replicas}{"\n"}'
5

# Un HPA puede targetear el recurso porque expone /scale:
$ kubectl autoscale database orders-db -n team-checkout --min=2 --max=9 --cpu-percent=70
horizontalpodautoscaler.autoscaling/orders-db autoscaled
```

Un usuario con `acme:database-user` (sin `databases/status`) no puede escribir status:

```console
$ kubectl patch db orders-db -n team-checkout --subresource=status \
    --type merge -p '{"status":{"phase":"Ready"}}'
Error from server (Forbidden): databases.platform.acme.io "orders-db" is forbidden:
  User "dev@acme.io" cannot patch resource "databases/status" in API group
  "platform.acme.io" in the namespace "team-checkout"
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El CRD tiene su propio `status` con conditions — leelo siempre

Un CRD no está "listo" solo por existir. El apiserver publica conditions clave:

```console
$ kubectl get crd databases.platform.acme.io -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
NamesAccepted=True (NoConflicts)
Established=True (InitialNamesAccepted)
KubernetesAPIApprovalPolicyConformant=True (ApprovalPolicyConformant)
NonStructuralSchema=False (NoViolations)
```

| Condition | Qué significa cuando **falla** | Diagnóstico |
|---|---|---|
| `NamesAccepted=False` | El `plural`/`kind`/`shortNames` **colisiona** con otro recurso ya registrado | `reason: ListKindConflict` / `PluralConflict`. Renombrá. |
| `Established=False` | El CRD se aceptó pero el recurso aún no se sirve (o nombres no aceptados) | Esperá unos segundos; si persiste, revisá `NamesAccepted`. |
| `NonStructuralSchema=True` | El esquema **no es estructural** (falta `type`, usa `anyOf` mal ubicado, `default` prohibido) | El mensaje lista cada violación; es la causa #1 de rechazo en `v1`. |
| `KubernetesAPIApprovalPolicyConformant=False` | Usaste el grupo `*.k8s.io` sin aprobación upstream | No uses grupos reservados; usá tu propio dominio. |

### 5.2 Errores de esquema estructural (la trampa más común al migrar a `v1`)

En `apiextensions.k8s.io/v1` el structural schema es **obligatorio**: cada nivel necesita `type`, no se permiten `default` bajo ciertos combinadores, y `x-kubernetes-preserve-unknown-fields` debe declararse explícitamente. Un error típico:

```console
$ kubectl apply -f broken-crd.yaml
The CustomResourceDefinition "widgets.platform.acme.io" is invalid:
  spec.versions[0].schema.openAPIV3Schema.properties[spec].properties[config]:
    Required value: must specify a type
```

**Causa:** un `object` sin `type: object` ni `x-kubernetes-preserve-unknown-fields: true`. **Fix:** declarar el tipo o marcar el subárbol como preserve-unknown.

### 5.3 Pruning: por qué "desaparecen" campos

Con structural schema, todo campo **no declarado** se poda (prune) silenciosamente antes de persistir:

```console
$ kubectl apply -f - <<'EOF'
apiVersion: platform.acme.io/v1
kind: Database
metadata: {name: typo-db, namespace: team-checkout}
spec: {engine: postgres, version: "16", replcas: 3}   # typo: 'replcas'
EOF
database.platform.acme.io/typo-db created

$ kubectl get db typo-db -n team-checkout -o jsonpath='{.spec.replicas}{"\n"}'
1
```

El campo `replcas` (typo) fue podado y `replicas` quedó en su default `1`. **Diagnóstico:** activá `--warnings` del apiserver o usá `--validate=strict` en el cliente para atrapar campos desconocidos:

```console
$ kubectl apply --validate=strict -f typo.yaml
error: error validating "typo.yaml": error validating data:
  ValidationError(Database.spec): unknown field "replcas"; if you choose to ignore
  these errors, turn validation off with --validate=false
```

### 5.4 Diagnóstico del conversion webhook

Si el webhook de conversión está caído, **toda lectura de una versión no-storage falla**:

```console
$ kubectl get databases.v1alpha1.platform.acme.io -A
Error from server: conversion webhook for platform.acme.io/v1, Kind=Database
  failed: Post "https://database-conversion-webhook.acme-platform-system.svc:443/convert?timeout=30s":
  x509: certificate signed by unknown authority
```

Checklist de diagnóstico:

```console
# 1) ¿El caBundle está inyectado?
$ kubectl get crd databases.platform.acme.io \
    -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' | wc -c
1424                                    # 0 = cert-manager no inyectó → revisar annotation

# 2) ¿El servicio tiene endpoints?
$ kubectl -n acme-platform-system get endpoints database-conversion-webhook
NAME                          ENDPOINTS            AGE
database-conversion-webhook   10.244.2.17:9443     3d

# 3) ¿El pod del operator/webhook está sano?
$ kubectl -n acme-platform-system logs deploy/database-operator -c webhook --tail=20
```

### 5.5 Verificar la migración de storage version

Al promover `v1` a storage version, los objetos viejos siguen en etcd con la versión anterior hasta ser reescritos. `status.storedVersions` te lo dice:

```console
$ kubectl get crd databases.platform.acme.io -o jsonpath='{.status.storedVersions}{"\n"}'
["v1alpha1","v1"]
```

Mientras `v1alpha1` figure en `storedVersions`, **no podés dejar de servirla** (romperías lecturas). El procedimiento seguro:

```console
# 1) Forzar reescritura de todos los objetos a la storage version actual
$ kubectl get databases -A -o name | \
    xargs -I{} kubectl patch {} --type merge -p '{}' --dry-run=none >/dev/null

# ...o con la herramienta oficial:
$ kubectl kube-storage-version-migrator ...   # StorageVersionMigration API

# 2) Recién entonces, quitar v1alpha1 de storedVersions (patch del CRD status) y
#    poner served:false en esa versión.
```

### 5.6 Cheatsheet de verificación rápida

```console
# ¿Está establecido y sin violaciones de esquema?
$ kubectl wait --for=condition=Established crd/databases.platform.acme.io --timeout=30s
customresourcedefinition.apiextensions.k8s.io/databases.platform.acme.io condition met

# ¿Qué versiones se sirven y cuál almacena?
$ kubectl get crd databases.platform.acme.io \
    -o jsonpath='{range .spec.versions[*]}{.name} served={.served} storage={.storage}{"\n"}{end}'
v1alpha1 served=true storage=false
v1 served=true storage=true

# Volcado del esquema efectivo (útil para diff en CI)
$ kubectl get crd databases.platform.acme.io -o yaml | \
    yq '.spec.versions[] | select(.name=="v1") | .schema.openAPIV3Schema'
```

---

## 6. Buenas prácticas de diseño (resumen operativo)

- **Un dominio propio como `group`** (`platform.acme.io`), nunca `*.k8s.io` reservado.
- **Empezá en `v1alpha1`**, promové a `v1beta1`/`v1` con contrato de compatibilidad; declará `deprecated` + `deprecationWarning`.
- **Structural schema completo**; acotá `x-kubernetes-preserve-unknown-fields` al mínimo subárbol necesario.
- **Validación cruzada e inmutabilidad con CEL** antes que webhooks; reservá webhooks para lo que requiere otros recursos.
- **Habilitá `/status`** y separá RBAC de `spec` (usuarios) vs. `status` (controller). Modelá `status.conditions` como `list-type: map` con clave `type`.
- **Publicá `additionalPrinterColumns`** — la UX de `kubectl get` es parte del contrato.
- **Convención de estado:** `status.observedGeneration` para saber si el controller ya reconcilió la última `spec`.
- **Versioná el CRD junto al operator** (mismo chart/OLM bundle) y probá conversión en CI con objetos de cada versión.

---

## 7. Referencias

- Extend the Kubernetes API with CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Versions in CustomResourceDefinitions (served/storage, conversion, storedVersions) — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/versioning/
- Custom Resources (concepto, CRD vs Aggregated API) — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Structural schemas y pruning — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#specifying-a-structural-schema
- Validation con CEL (`x-kubernetes-validations`) — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- Common Expression Language en Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Subresources (`/status`, `/scale`) — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#status-subresource
- `additionalPrinterColumns` — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#additional-printer-columns
- API `apiextensions.k8s.io/v1` (referencia CustomResourceDefinition) — https://kubernetes.io/docs/reference/kubernetes-api/extend-resources/custom-resource-definition-v1/
- Webhook conversion — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#webhook-conversion
- Storage version migration (StorageVersionMigration) — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/storage-version-migration/
- API conventions (conditions, observedGeneration, list-type) — https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
- CNCF Certified Cloud Native Platform Engineer (CNPE) — Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- cert-manager CA injector (inyección de `caBundle`) — https://cert-manager.io/docs/concepts/ca-injector/