# Tema 5.4: Kustomize

## ¿Qué es Kustomize?

**Kustomize** es una herramienta de gestión de configuración nativa de Kubernetes que permite personalizar manifiestos YAML sin usar templates ni variables. Está integrada directamente en `kubectl` desde la versión 1.14 (`kubectl apply -k`), y también existe como binario standalone (`kustomize build`).

La idea central es **declarativa y sin plantillas**: en lugar de parametrizar YAML con placeholders (como hace Helm), Kustomize parte de manifiestos base "puros" (`base`) y aplica **transformaciones** (patches, prefijos, labels, etc.) para generar variantes (`overlays`) por entorno (dev, staging, prod).

Todo gira en torno a un archivo llamado **`kustomization.yaml`**, que declara qué recursos incluir y qué transformaciones aplicar.

## Estructura básica de `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

commonLabels:
  app: mi-app

namePrefix: prod-
```

Con esta estructura mínima:

```bash
$ kubectl kustomize .
```

genera el YAML final combinando `deployment.yaml` + `service.yaml`, agregando el label `app: mi-app` a todos los recursos y anteponiendo `prod-` a sus nombres.

Para aplicarlo directamente al cluster:

```bash
$ kubectl apply -k .
deployment.apps/prod-mi-app created
service/prod-mi-app created
```

`-k` le indica a `kubectl` que el path apunta a un directorio con `kustomization.yaml`, no a un manifiesto individual.

## Patrón base + overlays

El patrón más usado (y el que suele evaluarse en el examen) es organizar el repo así:

```
app/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        ├── kustomization.yaml
        └── replica-patch.yaml
```

**`base/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

**`overlays/prod/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: production
resources:
  - ../../base
patches:
  - path: replica-patch.yaml
```

**`overlays/prod/replica-patch.yaml`**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mi-app
spec:
  replicas: 5
```

Cada overlay referencia la `base` como recurso (`resources: [../../base]`) y le aplica sus propios ajustes. Esto evita duplicar YAML entre entornos.

```bash
$ kubectl apply -k overlays/prod
namespace/production unchanged
deployment.apps/mi-app created
service/mi-app created
```

## Transformadores comunes

| Campo | Efecto |
|---|---|
| `namePrefix` / `nameSuffix` | Agrega prefijo/sufijo a `metadata.name` de todos los recursos |
| `namespace` | Fuerza el namespace en todos los recursos |
| `commonLabels` | Agrega labels a `metadata.labels` y a los selectores relacionados |
| `commonAnnotations` | Agrega annotations a todos los recursos |
| `images` | Reemplaza la imagen (y/o tag) de contenedores sin tocar el YAML original |
| `replicas` | Ajusta `spec.replicas` de un Deployment/StatefulSet por nombre |
| `configMapGenerator` / `secretGenerator` | Genera ConfigMaps/Secrets con hash en el nombre a partir de literales o archivos |

Ejemplo de `images` (muy común para promover una imagen entre entornos sin editar el Deployment):

```yaml
images:
  - name: nginx
    newName: mi-registry/nginx
    newTag: "1.27.0"
```

Ejemplo de `replicas` (forma moderna, reemplaza al patch de replicas):

```yaml
replicas:
  - name: mi-app
    count: 3
```

## Generadores: ConfigMap y Secret

Kustomize puede **generar** ConfigMaps y Secrets a partir de literales o archivos, calculando automáticamente un **hash** que se agrega al nombre. Esto garantiza que, si cambia el contenido, cambia el nombre, y por lo tanto el Deployment que lo referencia se reinicia (rolling update automático al detectar el nuevo nombre).

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=debug
      - MAX_CONNECTIONS=100

secretGenerator:
  - name: app-secret
    literals:
      - DB_PASSWORD=s3cr3t
```

```bash
$ kubectl kustomize .
apiVersion: v1
data:
  LOG_LEVEL: debug
  MAX_CONNECTIONS: "100"
kind: ConfigMap
metadata:
  name: app-config-8t2gc4bd2k
---
apiVersion: v1
data:
  DB_PASSWORD: czNjcjN0
kind: Secret
metadata:
  name: app-secret-fh9k274bmg
type: Opaque
```

Si un Deployment referencia `app-config` en un `envFrom` o `volumes.configMap.name`, Kustomize actualiza automáticamente esa referencia al nombre con hash (`app-config-8t2gc4bd2k`).

## Patches: Strategic Merge vs JSON 6902

Kustomize soporta dos estilos de patch:

**1. Strategic Merge Patch** (más común, mismo formato que el recurso original, solo con los campos a cambiar):

```yaml
patches:
  - path: patch.yaml
```

```yaml
# patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mi-app
spec:
  template:
    spec:
      containers:
        - name: app
          resources:
            limits:
              memory: "512Mi"
```

**2. JSON 6902 Patch** (operaciones tipo `add`/`replace`/`remove` sobre paths JSON, útil para cambios muy puntuales o cuando no se puede usar merge):

```yaml
patches:
  - target:
      kind: Deployment
      name: mi-app
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
```

También existe la forma inline sin archivo separado, usando `patches` con `target` y bloque `patch` embebido, como en el ejemplo anterior.

## Verificar antes de aplicar

Es buena práctica renderizar el YAML resultante antes de aplicarlo, para revisar exactamente qué se va a crear:

```bash
$ kubectl kustomize overlays/dev > /tmp/render.yaml
$ less /tmp/render.yaml
```

o equivalentemente:

```bash
$ kustomize build overlays/dev
```

Para aplicar (equivalente a `kubectl apply -f <(kubectl kustomize ...)`):

```bash
$ kubectl apply -k overlays/dev
```

Y para eliminar los recursos generados por un overlay:

```bash
$ kubectl delete -k overlays/dev
```

## Kustomize vs Helm (para contexto en el examen)

- **Kustomize**: sin templates, YAML válido en todo momento, basado en overlays/patches, nativo en `kubectl`, no requiere instalar nada extra.
- **Helm**: usa templates con placeholders (`{{ .Values.x }}`), packaging con versionado (charts), más apto para distribuir aplicaciones reutilizables por terceros.

El CKAD se enfoca en Kustomize porque es la herramienta integrada de forma nativa en `kubectl`.

## Referencias

- Documentación oficial de Kustomize en Kubernetes: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kustomize project docs: https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
- Repositorio y guía completa de Kustomize: https://github.com/kubernetes-sigs/kustomize
- Referencia de campos de `kustomization.yaml`: https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/
- `kubectl` reference (`apply -k`, `kustomize`): https://kubernetes.io/docs/reference/kubectl/generated/kubectl_kustomize/