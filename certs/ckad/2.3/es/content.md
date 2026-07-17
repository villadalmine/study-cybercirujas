# 2.3 Use the Helm package manager to deploy existing packages

## ¿Qué es Helm?

Helm es el **package manager** de facto para Kubernetes. Permite empaquetar, versionar, instalar y actualizar aplicaciones completas (uno o varios objetos de la API de Kubernetes: `Deployment`, `Service`, `ConfigMap`, `Ingress`, etc.) como una sola unidad reutilizable llamada **chart**.

En vez de escribir y mantener a mano decenas de manifiestos YAML por cada aplicación, con Helm se instala un chart ya empaquetado (por ejemplo, un chart de PostgreSQL o de nginx) pasando solo los parámetros que se quieren personalizar. Helm resuelve el resto: templating, orden de aplicación de los recursos y tracking de qué se instaló.

Desde Helm 3 (la versión vigente para el examen) **no existe Tiller** (el componente server-side que tenía Helm 2 corriendo dentro del cluster). Todo el trabajo lo hace el cliente `helm`, que se conecta directamente a la API de Kubernetes usando el mismo `kubeconfig` que `kubectl`. Esto simplifica el modelo de seguridad: los permisos de Helm son los permisos del usuario que ejecuta el comando (RBAC normal de Kubernetes).

## Conceptos clave

| Término | Significado |
|---|---|
| **Chart** | Paquete de Helm: conjunto de templates YAML + metadata (`Chart.yaml`) + valores por defecto (`values.yaml`) que describe una app o componente. |
| **Release** | Una instancia instalada de un chart en un cluster, identificada por un nombre (`release name`). El mismo chart se puede instalar varias veces con nombres distintos. |
| **Repository (repo)** | Un servidor HTTP que aloja charts empaquetados e indexados (`index.yaml`). Análogo a un repositorio de paquetes APT/YUM. |
| **Values** | Parámetros de configuración que se inyectan en los templates del chart (`values.yaml` por defecto, sobreescribibles). |
| **Revision** | Cada `install`/`upgrade`/`rollback` de una release genera una nueva revisión numerada, lo que permite hacer rollback. |

Para el examen CKAD, el foco de este tema es el **uso** de Helm para desplegar paquetes *existentes* (no crear charts desde cero, eso es CKAD 2.2 - Application Deployment / templating, más asociado al tema de Kustomize y Helm charts en general). Acá lo importante es dominar el flujo: repo → search → install → upgrade → rollback → uninstall.

## Comandos esenciales

### Verificar la instalación

```bash
helm version
```

```
version.BuildInfo{Version:"v3.14.0", GitCommit:"...", GitTreeState:"clean", GoVersion:"go1.21.5"}
```

### Gestión de repositorios

Antes de poder instalar un chart público hay que agregar el repo que lo aloja e indexarlo localmente:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

```
"bitnami" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "bitnami" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Listar los repos configurados:

```bash
helm repo list
```

```
NAME      URL
bitnami   https://charts.bitnami.com/bitnami
```

Quitar un repo:

```bash
helm repo remove bitnami
```

### Buscar charts

Buscar en los repos agregados localmente (`helm search repo`) o en el Artifact Hub público (`helm search hub`):

```bash
helm search repo nginx
```

```
NAME               CHART VERSION   APP VERSION   DESCRIPTION
bitnami/nginx      15.5.1          1.25.3        NGINX Open Source is a web server...
bitnami/nginx-ingress-controller  11.1.1  1.10.0  NGINX Ingress Controller...
```

```bash
helm search hub wordpress
```

### Instalar un chart (`helm install`)

Sintaxis: `helm install <release-name> <chart> [flags]`

```bash
helm install my-nginx bitnami/nginx --namespace web --create-namespace
```

```
NAME: my-nginx
LAST DEPLOYED: Tue Jul 14 10:12:03 2026
NAMESPACE: web
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Get the application URL by running these commands:
...
```

Flags importantes para el examen:

- `--namespace <ns> --create-namespace`: instala en un namespace, creándolo si no existe.
- `--set clave=valor`: sobrescribe un valor puntual del `values.yaml` del chart sin editar archivos. Se pueden encadenar con comas: `--set replicaCount=3,service.type=NodePort`.
- `-f values-custom.yaml` (o `--values`): sobrescribe usando un archivo YAML propio (útil para muchos valores).
- `--dry-run --debug`: renderiza los manifiestos sin aplicarlos, para revisar el resultado del templating antes de instalar.
- `--version <chart-version>`: instala una versión específica del chart (no de la app).
- `--wait`: espera a que los recursos estén `Ready` antes de devolver el control.
- `--atomic`: si la instalación falla, hace rollback/uninstall automático.

Ejemplo combinando `--set` y `-f`:

```bash
helm install my-nginx bitnami/nginx \
  --namespace web --create-namespace \
  -f values-custom.yaml \
  --set service.type=ClusterIP,replicaCount=2
```

> Precedencia: los `--set` sobrescriben lo definido en `-f`, y `-f` sobrescribe el `values.yaml` por defecto del chart. Si se pasan varios `-f`, el último gana; si se pasan varios `--set` sobre la misma clave, también gana el último.

### Inspeccionar un chart antes de instalar

```bash
helm show values bitnami/nginx      # ver el values.yaml por defecto
helm show chart bitnami/nginx       # ver metadata (Chart.yaml)
helm show readme bitnami/nginx      # ver el README del chart
```

Para ver qué manifiestos genera realmente sin tocar el cluster:

```bash
helm template my-nginx bitnami/nginx --set replicaCount=2
```

Este comando (`helm template`) solo renderiza localmente, no requiere conexión al cluster ni crea una release; es la forma más rápida de auditar qué YAML va a aplicar `install`.

### Listar releases (`helm list` / `helm ls`)

```bash
helm list --namespace web
```

```
NAME       NAMESPACE   REVISION   UPDATED                    STATUS     CHART         APP VERSION
my-nginx   web         1          2026-07-14 10:12:03 -03    deployed   nginx-15.5.1  1.25.3
```

`-A` / `--all-namespaces` lista releases de todos los namespaces (equivalente a `kubectl get pods -A`).

### Ver el estado de una release

```bash
helm status my-nginx -n web
```

Muestra lo mismo que devuelve `install`/`upgrade`: estado, revisión, notas del chart.

```bash
helm get values my-nginx -n web     # values efectivos usados en la release
helm get manifest my-nginx -n web   # YAML final aplicado al cluster
helm get all my-nginx -n web        # hooks, notes, manifest, values, todo junto
```

### Actualizar una release (`helm upgrade`)

Cuando cambia una versión de app o hay que modificar valores, no se reinstala: se hace **upgrade**, que aplica un diff sobre los recursos existentes y crea una nueva revisión.

```bash
helm upgrade my-nginx bitnami/nginx --set replicaCount=3 -n web
```

```
Release "my-nginx" has been upgraded. Happy Helming!
NAME: my-nginx
LAST DEPLOYED: Tue Jul 14 10:20:11 2026
NAMESPACE: web
STATUS: deployed
REVISION: 2
```

Patrón muy usado en el examen: **instalar si no existe, actualizar si ya existe**, en un solo comando idempotente:

```bash
helm upgrade --install my-nginx bitnami/nginx -n web --create-namespace
```

### Ver el historial de revisiones

```bash
helm history my-nginx -n web
```

```
REVISION   UPDATED                    STATUS       CHART         APP VERSION   DESCRIPTION
1          Tue Jul 14 10:12:03 2026   superseded   nginx-15.5.1  1.25.3        Install complete
2          Tue Jul 14 10:20:11 2026   deployed     nginx-15.5.1  1.25.3        Upgrade complete
```

### Rollback

Volver a una revisión anterior si un `upgrade` rompió algo:

```bash
helm rollback my-nginx 1 -n web
```

```
Rollback was a success! Happy Helming!
```

Esto crea una **nueva revisión** (revisión 3) cuyo contenido es igual al de la revisión 1; el historial no se borra, solo avanza hacia adelante.

### Desinstalar una release

```bash
helm uninstall my-nginx -n web
```

```
release "my-nginx" uninstalled
```

Por defecto Helm 3 **no** deja registro de la release luego de desinstalar (a diferencia de Helm 2). Si se necesita conservar el historial para poder inspeccionarlo después, usar `--keep-history`.

## Flujo típico de un escenario de examen

1. Agregar el repo indicado: `helm repo add <name> <url>` y `helm repo update`.
2. Buscar el chart correcto: `helm search repo <keyword>`.
3. (Opcional) Revisar valores disponibles: `helm show values <repo>/<chart>`.
4. Instalar con el nombre de release y namespace pedidos, personalizando con `--set` o `-f`:
   `helm install <release> <repo>/<chart> -n <namespace> --create-namespace --set clave=valor`.
5. Verificar: `helm list -n <namespace>` y `kubectl get all -n <namespace>`.
6. Si piden cambiar un valor: `helm upgrade <release> <repo>/<chart> -n <namespace> --set clave=nuevoValor`.
7. Si piden deshacer un cambio: `helm rollback <release> <revision> -n <namespace>`.
8. Si piden limpiar: `helm uninstall <release> -n <namespace>`.

## Errores comunes a evitar

- Confundir **chart version** (versión del paquete Helm) con **app version** (versión del software empaquetado, ej. nginx 1.25.3). El flag `--version` de `helm install`/`upgrade` se refiere siempre a la chart version.
- Olvidar `helm repo update` después de `helm repo add`: sin el update, `helm search repo` puede no encontrar el chart o mostrar versiones desactualizadas.
- Usar `helm install` sobre una release que ya existe (falla con `cannot re-use a name that is still in use`) en vez de `helm upgrade` o `helm upgrade --install`.
- No indicar `-n <namespace>` y asumir el namespace `default`: Helm, igual que `kubectl`, opera sobre el namespace del contexto actual si no se especifica uno explícitamente.

## Referencias

- Helm — Documentación oficial: https://helm.sh/docs/
- Helm — Quickstart Guide: https://helm.sh/docs/intro/quickstart/
- Helm — Comandos de la CLI (`helm install`, `upgrade`, `rollback`, etc.): https://helm.sh/docs/helm/helm/
- Helm — Using Helm (conceptos de charts, releases, values): https://helm.sh/docs/intro/using_helm/
- Artifact Hub (búsqueda pública de charts): https://artifacthub.io/
- CNCF CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf