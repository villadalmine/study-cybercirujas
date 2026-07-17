# 4.7 – Understand CRDs, install and configure operators

## Introducción

Kubernetes expone su funcionalidad nativa (Pods, Deployments, Services, etc.) a través de la API declarativa. Los **Custom Resource Definitions (CRDs)** permiten extender esa API con tipos de recursos propios, sin necesidad de modificar el código fuente del API server. Los **operators** son el patrón que combina un CRD con un **controller** que implementa lógica de reconciliación específica de dominio, automatizando tareas operacionales que normalmente requerirían intervención humana (deploy, backup, upgrade, failover, etc.).

Este tema es transversal: aparece en cualquier cluster productivo moderno, ya que la mayoría de los componentes de infraestructura (CNI, CSI, service mesh, monitoring, bases de datos) se instalan y gestionan mediante operators.

## Custom Resource Definitions (CRDs)

### ¿Qué es un Custom Resource?

Un **Custom Resource (CR)** es una instancia de un tipo de objeto que no es parte del set estándar de Kubernetes (Pod, Service, etc.), pero que se comporta como cualquier otro objeto nativo: se crea, lee, actualiza y elimina vía `kubectl` o la API, se versiona, soporta `kubectl get/describe/edit`, y puede tener `status` y `spec`.

El **CustomResourceDefinition** es el recurso que le enseña al API server cómo es ese nuevo tipo: su nombre, grupo de API, versiones, schema de validación (OpenAPI v3) y scope (`Namespaced` o `Cluster`).

### Anatomía de un CRD

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.storage.example.com   # <plural>.<group>
spec:
  group: storage.example.com
  names:
    kind: Backup
    plural: backups
    singular: backup
    shortNames:
      - bkp
  scope: Namespaced
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
              properties:
                schedule:
                  type: string
                retentionDays:
                  type: integer
                  minimum: 1
              required: ["schedule"]
            status:
              type: object
              properties:
                lastBackupTime:
                  type: string
      subresources:
        status: {}
```

Puntos clave del schema:

- `group` + `plural` forman el nombre único del CRD (`<plural>.<group>`).
- Puede haber múltiples `versions` simultáneas (ej. `v1alpha1`, `v1beta1`, `v1`); exactamente una debe tener `storage: true` (la versión en la que etcd persiste los datos).
- `served: true` indica que esa versión está expuesta en la API; se pueden servir varias versiones a la vez con conversión automática o webhooks de conversión.
- `subresources.status: {}` habilita el subrecurso `/status`, separando el ciclo de escritura del `spec` (usuario) del `status` (controller), igual que en los recursos nativos.
- El `openAPIV3Schema` es obligatorio en `apiextensions.k8s.io/v1` y permite validación estructural en el API server (rechaza objetos inválidos antes de persistirlos).

### Crear y usar un CRD

```bash
kubectl apply -f backup-crd.yaml
kubectl get crd backups.storage.example.com
```

Salida esperada:

```
NAME                          CREATED AT
backups.storage.example.com   2026-07-16T10:15:00Z
```

Una vez que el CRD existe, se puede crear un Custom Resource:

```yaml
apiVersion: storage.example.com/v1
kind: Backup
metadata:
  name: nightly-backup
spec:
  schedule: "0 2 * * *"
  retentionDays: 7
```

```bash
kubectl apply -f nightly-backup.yaml
kubectl get backups
kubectl get bkp   # usando el shortName
```

Salida:

```
NAME              AGE
nightly-backup    5s
```

Sin un **controller** que observe este recurso, `Backup` es solo un dato almacenado en etcd: no ejecuta ninguna acción por sí solo. El CRD define la forma; el controller define el comportamiento.

### Comandos útiles de diagnóstico

```bash
kubectl explain backup.spec          # usa el schema OpenAPI para documentar el CR
kubectl api-resources | grep backups # confirma que el tipo está registrado
kubectl get crd backups.storage.example.com -o yaml   # ver el schema completo
kubectl delete crd backups.storage.example.com        # elimina el tipo y TODAS sus instancias
```

> **Importante:** eliminar un CRD elimina en cascada todos los Custom Resources de ese tipo en todos los namespaces. Es una operación destructiva que se debe tratar con el mismo cuidado que borrar un namespace completo.

## El patrón Operator

### Concepto

Un **operator** = CRD(s) + **controller** que implementa el **control loop** (reconciliation loop):

```
observar estado actual → comparar con estado deseado (spec) → actuar → actualizar status → repetir
```

Este es el mismo patrón que usan los controllers nativos de Kubernetes (ej. el Deployment controller reconciliando ReplicaSets), pero aplicado a lógica de dominio específica: un `PostgresOperator` sabe cómo hacer failover de una base de datos, algo que el kube-controller-manager desconoce por completo.

El operator típicamente corre como un Deployment dentro del propio cluster, usando **RBAC** para tener permisos sobre su CRD y los recursos nativos que necesita crear (Pods, PVCs, Services, Secrets, etc.).

### Custom Resources vs. ConfigMaps

Un error común es preguntarse "¿por qué no usar un ConfigMap?". La diferencia central:

| | ConfigMap | Custom Resource |
|---|---|---|
| Validación de schema | No | Sí (OpenAPI v3) |
| Subresource `/status` | No | Sí |
| Versionado de API | No | Sí |
| `kubectl get/describe` tipado | No | Sí |
| Watch eficiente por tipo | Genérico | Específico |

## Instalar operators

### Opción 1: manifiestos YAML directos

Muchos operators se distribuyen como un bundle de YAMLs (CRDs + RBAC + Deployment del controller):

```bash
kubectl apply -f https://example.com/operator/crds.yaml
kubectl apply -f https://example.com/operator/operator.yaml
```

### Opción 2: Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

Helm suele instalar los CRDs (carpeta `crds/`) y luego el Deployment del controller y sus RBAC roles vía templates.

### Opción 3: Operator Lifecycle Manager (OLM)

**OLM** es un proyecto del ecosistema Operator Framework que gestiona instalación, actualización y dependencias entre operators de forma declarativa, similar a un gestor de paquetes:

```bash
# instalar OLM en el cluster
curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/latest/download/install.sh | bash -s v0.28.0

# instalar un operator desde OperatorHub vía Subscription
kubectl create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: prometheus
  namespace: operators
spec:
  channel: beta
  name: prometheus
  source: operatorhubio-catalog
  sourceNamespace: olm
EOF
```

OLM introduce sus propios CRDs: `ClusterServiceVersion` (CSV, describe el operator), `Subscription` (declara qué canal/versión se quiere seguir) y `CatalogSource` (fuente de operators disponibles).

## Verificar y depurar un operator instalado

```bash
# ver el Deployment del controller
kubectl get deployment -n <namespace-del-operator>

# logs del controller para ver el reconciliation loop en acción
kubectl logs -n <namespace-del-operator> deploy/<operator-name> -f

# verificar los CRDs que instaló
kubectl get crd | grep <dominio-del-operator>

# revisar el status de un Custom Resource para ver si el controller lo procesó
kubectl get <custom-resource> <name> -o yaml
kubectl describe <custom-resource> <name>
```

Ejemplo típico de `status` poblado por un controller (patrón `conditions`, igual que en recursos nativos):

```yaml
status:
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2026-07-16T10:20:00Z"
      reason: ReconcileSuccess
  observedGeneration: 3
```

`observedGeneration` comparado con `metadata.generation` del objeto permite saber si el controller ya procesó el último cambio del `spec` o si todavía está desactualizado (`generation` > `observedGeneration` significa reconciliación pendiente).

### Problemas comunes

- **CRD no encontrado / `no matches for kind`**: el CRD no se aplicó antes que el CR, o hay un typo en `apiVersion`/`kind`.
- **CR "atascado" sin cambios en `status`**: el controller no está corriendo, no tiene RBAC suficiente, o crasheó — revisar `kubectl get pods -n <ns-operador>` y sus logs.
- **`finalizers` bloqueando el delete**: muchos operators agregan `metadata.finalizers` para limpiar recursos externos antes de borrar el CR; si el controller está caído, el objeto queda en estado `Terminating` indefinidamente.

```bash
kubectl get backup nightly-backup -o jsonpath='{.metadata.finalizers}'
```

## Referencias

- Custom Resources — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend the Kubernetes API with CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Operator pattern — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- CustomResourceDefinition (API reference) — https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.35/#customresourcedefinition-v1-apiextensions-k8s-io
- Versions in CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Operator Framework / OLM — https://olm.operatorframework.io/
- OperatorHub — https://operatorhub.io/
- CNCF CKA Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf