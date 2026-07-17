# 4.5 Use Helm and Kustomize to install cluster components

## Por qué importan estas herramientas

Kubernetes gestiona objetos declarativos en YAML, pero mantener manifiestos a mano se vuelve inmanejable cuando:

- Un componente (ingress controller, CNI, metrics-server, cert-manager) tiene decenas de objetos relacionados (Deployment, Service, RBAC, CRDs, ConfigMaps).
- Necesitás la misma aplicación desplegada en múltiples entornos (dev/staging/prod) con pequeñas variaciones.
- Querés versionar, actualizar y hacer rollback de un conjunto de recursos como una unidad.

**Helm** resuelve esto con un modelo de *packaging* (charts, templating, releases).
**Kustomize** resuelve esto con un modelo de *composición* (bases + overlays, sin templating), integrado nativamente en `kubectl`.

El examen CKA espera que sepas instalar componentes del clúster (por ejemplo, un ingress controller o metrics-server) usando ambas herramientas.

---

## Helm

### Conceptos clave

| Término | Significado |
|---|---|
| **Chart** | Paquete de Helm: conjunto de plantillas YAML + metadata (`Chart.yaml`) + valores por defecto (`values.yaml`). |
| **Release** | Una instancia de un chart instalada en el clúster, con un nombre propio. Un mismo chart puede instalarse varias veces con distintos nombres/namespaces. |
| **Repository** | Ubicación HTTP(S) (o OCI registry) donde se publican charts empaquetados (`.tgz`) e `index.yaml`. |
| **Values** | Parámetros que sobreescriben los defaults del chart (`values.yaml`, `--set`, `-f`). |
| **Revision** | Cada `install`/`upgrade` genera una nueva revisión de la release, lo que permite `rollback`. |

Helm 3 no tiene Tiller (a diferencia de Helm 2): el cliente habla directamente con la API de Kubernetes y guarda el estado de las releases como **Secrets** en el namespace de destino.

### Instalación del cliente

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
# version.BuildInfo{Version:"v3.15.0", ...}
```

En el examen, `helm` normalmente ya está instalado; verificá con `helm version` antes de asumir que falta.

### Estructura de un chart

```
mychart/
├── Chart.yaml          # metadata: name, version, appVersion
├── values.yaml          # valores por defecto
├── charts/               # sub-charts (dependencias)
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl     # funciones/plantillas reutilizables
│   └── NOTES.txt        # mensaje post-install
└── .helmignore
```

Los templates usan la sintaxis de Go templates:

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-{{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

### Flujo típico: instalar un componente del clúster

Ejemplo: instalar el ingress-nginx controller.

```bash
# 1. Agregar el repositorio
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# 2. Buscar el chart y ver sus valores por defecto
helm search repo ingress-nginx
# NAME                       CHART VERSION   APP VERSION
# ingress-nginx/ingress-nginx 4.11.2         1.11.2

helm show values ingress-nginx/ingress-nginx > values.yaml
```

```bash
# 3. Instalar, creando el namespace si no existe
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort

# NAME: ingress-nginx
# LAST DEPLOYED: Tue Jul 14 10:02:11 2026
# NAMESPACE: ingress-nginx
# STATUS: deployed
# REVISION: 1
```

```bash
# 4. Verificar
helm list -n ingress-nginx
# NAME            NAMESPACE       REVISION  STATUS    CHART                     APP VERSION
# ingress-nginx   ingress-nginx   1         deployed  ingress-nginx-4.11.2      1.11.2

helm status ingress-nginx -n ingress-nginx
kubectl get all -n ingress-nginx
```

### Personalizar valores

Tres formas, en orden de precedencia (la última gana):

```bash
# a) archivo de valores propio
helm install myrelease repo/chart -f custom-values.yaml

# b) --set inline (para overrides puntuales)
helm install myrelease repo/chart --set replicaCount=3,image.tag=1.2.3

# c) combinando ambos (--set sobreescribe lo de -f)
helm install myrelease repo/chart -f custom-values.yaml --set replicaCount=5
```

Ver qué manifiestos generaría Helm **sin aplicarlos** (equivalente a un dry-run de templating):

```bash
helm template myrelease repo/chart -f custom-values.yaml
helm install myrelease repo/chart --dry-run --debug
```

### Actualizar, revisar historial y hacer rollback

```bash
# Actualizar valores o versión del chart
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --set controller.replicaCount=2

# Ver historial de revisiones
helm history ingress-nginx -n ingress-nginx
# REVISION  UPDATED                   STATUS      CHART                  APP VERSION  DESCRIPTION
# 1         Tue Jul 14 10:02:11 2026  superseded  ingress-nginx-4.11.2   1.11.2       Install complete
# 2         Tue Jul 14 10:15:40 2026  deployed    ingress-nginx-4.11.2   1.11.2       Upgrade complete

# Volver a una revisión anterior
helm rollback ingress-nginx 1 -n ingress-nginx
```

`upgrade --install` es útil en pipelines idempotentes: instala si no existe, actualiza si existe.

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

### Desinstalar

```bash
helm uninstall ingress-nginx -n ingress-nginx
```

Por defecto Helm 3 **no** borra los CRDs instalados por el chart (para evitar pérdida de datos accidental); si hace falta, se borran manualmente con `kubectl delete crd`.

### Comandos de diagnóstico útiles para el examen

```bash
helm list -A                    # todas las releases en todos los namespaces
helm get values ingress-nginx -n ingress-nginx    # valores efectivos usados
helm get manifest ingress-nginx -n ingress-nginx  # YAML final aplicado
helm lint ./mychart              # validar sintaxis/buenas prácticas del chart
```

---

## Kustomize

### Conceptos clave

Kustomize **no usa templating**; parte de manifiestos YAML "puros" (`base`) y los transforma declarativamente mediante **overlays** y **patches**, definidos en un archivo `kustomization.yaml`.

Está integrado en `kubectl` desde la v1.14:

```bash
kubectl apply -k <directorio>
kubectl kustomize <directorio>     # solo renderiza, sin aplicar
```

También existe el binario standalone `kustomize` con más funciones (plugins, `kustomize edit`), pero para el examen `kubectl -k` suele alcanzar.

### Estructura base + overlays

```
app/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── replica-patch.yaml
    └── prod/
        ├── kustomization.yaml
        └── replica-patch.yaml
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
namePrefix: prod-
commonLabels:
  env: prod
resources:
  - ../../base
patches:
  - path: replica-patch.yaml
    target:
      kind: Deployment
      name: myapp
images:
  - name: myapp
    newTag: v1.4.0
```

```yaml
# overlays/prod/replica-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 5
```

```bash
# Ver el YAML resultante sin aplicar
kubectl kustomize overlays/prod/

# Aplicar directamente
kubectl apply -k overlays/prod/
```

### Transformadores comunes

| Campo en `kustomization.yaml` | Efecto |
|---|---|
| `namePrefix` / `nameSuffix` | Antepone/agrega sufijo a `metadata.name` de todos los recursos. |
| `namespace` | Fuerza el namespace en todos los recursos. |
| `commonLabels` | Agrega labels a `metadata.labels` y a los selectors relacionados. |
| `commonAnnotations` | Agrega annotations a todos los recursos. |
| `images` | Reemplaza `image:`/tag de contenedores sin tocar el YAML original. |
| `configMapGenerator` / `secretGenerator` | Genera ConfigMaps/Secrets con hash de contenido en el nombre (fuerza rollout al cambiar datos). |
| `replicas` | Ajusta el número de réplicas de un Deployment/StatefulSet por nombre. |

Ejemplo de generador con hash automático:

```yaml
# kustomization.yaml
configMapGenerator:
  - name: app-config
    literals:
      - LOG_LEVEL=debug
      - FEATURE_X=enabled
```

```bash
kubectl kustomize .
# ...
# metadata:
#   name: app-config-8gcm2ttbdg
```

Al cambiar `LOG_LEVEL`, el hash del nombre cambia, lo que provoca que los Pods que referencian ese ConfigMap se reprogramen (si usan `envFrom`/`volumeMounts` acoplados al generador).

### Tipos de patches

**Strategic Merge Patch** (declarativo, se fusiona por campo):

```yaml
patches:
  - path: patch-replicas.yaml
```

**JSON 6902 Patch** (operaciones explícitas add/replace/remove, útil para arrays o cambios puntuales):

```yaml
patches:
  - target:
      kind: Deployment
      name: myapp
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: {name: NEW_VAR, value: "1"}
```

### Componentes reutilizables entre overlays

Cuando varios overlays necesitan el mismo "trozo" opcional de configuración (por ejemplo, habilitar TLS), se usa `Component`:

```yaml
# components/tls/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - path: tls-patch.yaml
```

```yaml
# overlays/prod/kustomization.yaml
components:
  - ../../components/tls
```

---

## Instalar componentes del clúster: comparación práctica

| Escenario | Herramienta recomendada |
|---|---|
| Instalar un componente de terceros publicado como chart (ingress-nginx, metrics-server, cert-manager, CSI drivers) | **Helm** — versión, values documentados, upgrade/rollback con historial. |
| Adaptar manifiestos propios a varios entornos sin lógica condicional compleja | **Kustomize** — nativo en `kubectl`, sin dependencias extra. |
| Combinar ambos: bajar un chart y aplicar overlays propios | `helm template chart/ > rendered.yaml`, usarlo como `resource` en un `kustomization.yaml`, o usar `helmCharts:` dentro de kustomize. |

Ejemplo de integración Helm dentro de Kustomize (requiere el binario `kustomize`, no siempre disponible en `kubectl -k`):

```yaml
# kustomization.yaml
helmCharts:
  - name: ingress-nginx
    repo: https://kubernetes.github.io/ingress-nginx
    version: 4.11.2
    releaseName: ingress-nginx
    namespace: ingress-nginx
    valuesFile: values.yaml
```

```bash
kustomize build --enable-helm .
```

---

## Puntos frecuentes en el examen

- `kubectl apply -k <dir>` requiere que `<dir>` contenga un `kustomization.yaml` (no se pasa un archivo YAML suelto).
- `helm install` falla si la release ya existe con ese nombre en el namespace; usar `helm upgrade --install` para idempotencia.
- El estado de las releases de Helm se guarda como Secrets tipo `helm.sh/release.v1` en el namespace de la release: `kubectl get secrets -n <ns> | grep sh.helm.release`.
- `kubectl kustomize` y `kustomize build` **no aplican** nada al clúster, solo renderizan — útil para revisar antes de aplicar (equivalente a `--dry-run=client -o yaml` pero para composición completa).
- Los nombres generados por `configMapGenerator`/`secretGenerator` cambian con el contenido; no hardcodees ese nombre en otros manifiestos fuera del kustomization (Kustomize actualiza las referencias automáticamente dentro del mismo build).
- Practicá construir un overlay rápido de memoria: `kustomization.yaml` con `resources:`, `namePrefix:`, y un `patchesStrategicMerge`/`patches:` mínimo.

---

## Referencias

- Helm — Documentación oficial: https://helm.sh/docs/
- Helm — Chart template guide: https://helm.sh/docs/chart_template_guide/getting_started/
- Helm — Comandos CLI: https://helm.sh/docs/helm/helm/
- Kustomize — Documentación oficial: https://kubectl.docs.kubernetes.io/references/kustomize/
- Kubernetes — Declarative Management with Kustomize: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kustomize — Repositorio y ejemplos: https://github.com/kubernetes-sigs/kustomize
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
