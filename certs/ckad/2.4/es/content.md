# 2.4 Understand API deprecations

## ¿Qué es una API deprecation?

En Kubernetes, cada recurso (`Deployment`, `CronJob`, `Ingress`, etc.) se expone a través de una combinación de **API group**, **version** y **kind**, lo que en un manifiesto se ve como el campo `apiVersion`:

```yaml
apiVersion: apps/v1
kind: Deployment
```

Una **API deprecation** ocurre cuando el proyecto Kubernetes anuncia que una versión concreta de un recurso (por ejemplo `batch/v1beta1` para `CronJob`) va a dejar de estar disponible en el futuro, reemplazada por otra versión más estable (por ejemplo `batch/v1`). Deprecar no es lo mismo que remover: la deprecation es el aviso; la remoción es cuando esa versión efectivamente deja de responder en el `kube-apiserver`.

Para quien administra o despliega workloads, entender este proceso es crítico porque **un manifiesto que usa una `apiVersion` removida falla directamente al aplicarse** (`error: resource mapping not found`), típicamente después de un upgrade de cluster.

## Niveles de estabilidad de una API

Cada versión de API tiene un nivel de madurez, visible en su propio nombre:

| Nivel | Ejemplo de version | Garantías |
|---|---|---|
| **Alpha** | `v1alpha1` | Puede tener bugs, puede desactivarse por default, **puede cambiar o eliminarse en cualquier momento sin aviso previo**. No usar en producción. |
| **Beta** | `v1beta1` | Código bien probado, habilitado por default, soporte de al menos 9 meses o 3 releases (lo que sea mayor) desde que se anuncia su deprecation. El schema puede tener cambios menores incompatibles entre versiones beta. |
| **Stable / GA** | `v1` | Aparece en release notes mayores, soporte garantizado de al menos 12 meses o 3 releases (lo que sea mayor) tras el anuncio de deprecation. |

Kubernetes hace releases de versión minor aproximadamente cada 4 meses, por lo que "3 releases" equivale más o menos a un año, coincidiendo con las cifras anteriores.

## La política de deprecation (reglas concretas)

Las reglas oficiales del proyecto (documentadas en la *Kubernetes Deprecation Policy*) son:

1. **Las APIs con un nivel de madurez dado no se remueven directamente**: primero deben pasar por un período de deprecation.
2. **GA/stable**: soporte mínimo de **12 meses o 3 releases** después del anuncio, lo que sea más largo.
3. **Beta**: soporte mínimo de **9 meses o 3 releases**.
4. **Alpha**: sin garantía de soporte, puede desaparecer en cualquier release.
5. Cuando una API se reemplaza por una versión más nueva, **debe existir una ruta de migración documentada** (una nueva `apiVersion` con un schema equivalente o convertible).
6. La deprecation se comunica en las **release notes** y mediante **warnings en tiempo de ejecución** (ver sección siguiente).

Esto es lo que hace posible planificar upgrades: antes de saltar de versión de cluster, siempre hay que revisar qué APIs beta/GA que usás quedan fuera de soporte en la versión destino.

## Cómo Kubernetes te avisa: deprecation warnings

Desde Kubernetes 1.19, el `kube-apiserver` envía un **header HTTP de warning** cuando se usa una `apiVersion` deprecada, y `kubectl` lo muestra en la terminal. Ejemplo real al aplicar un `CronJob` con una versión vieja:

```console
$ kubectl apply -f cronjob-old.yaml
Warning: batch/v1beta1 CronJob is deprecated in v1.21+, unavailable in v1.25+; use batch/v1 CronJob
cronjob.batch/backup-job created
```

El objeto se crea igual (mientras la versión siga existiendo), pero el warning es la señal de que hay que migrar el manifiesto. Esto también aplica a `kubectl create`, `kubectl replace` y a cualquier cliente que hable con la API (Helm, controllers, etc.).

## Tabla de deprecations/remociones históricas relevantes

Estos son ejemplos clásicos que ilustran el patrón "beta → GA" y sirven para entender el mecanismo (para la versión exacta de Kubernetes que rinde el examen, siempre confirmar contra la *deprecation guide* oficial, ya que el detalle de versiones cambia con el tiempo):

| Recurso | Version deprecada | Version reemplazo | Removida en |
|---|---|---|---|
| `Deployment`, `DaemonSet`, `ReplicaSet` | `extensions/v1beta1`, `apps/v1beta1`, `apps/v1beta2` | `apps/v1` | v1.16 |
| `NetworkPolicy` | `extensions/v1beta1` | `networking.k8s.io/v1` | v1.16 |
| `Ingress` | `extensions/v1beta1`, `networking.k8s.io/v1beta1` | `networking.k8s.io/v1` | v1.22 |
| `CronJob` | `batch/v1beta1` | `batch/v1` | v1.25 |
| `PodDisruptionBudget` | `policy/v1beta1` | `policy/v1` | v1.25 |
| `PodSecurityPolicy` | `policy/v1beta1` | *(sin reemplazo directo; migrar a Pod Security Admission)* | v1.25 |
| `HorizontalPodAutoscaler` | `autoscaling/v2beta2` | `autoscaling/v2` | v1.26 |

El patrón a memorizar no es la tabla en sí, sino el mecanismo: **beta → GA**, con un período de convivencia donde ambas versiones responden y `kubectl` avisa.

## Cómo detectar el uso de APIs deprecadas en un cluster

**1. Inspeccionar qué API groups/versions expone el `kube-apiserver` actual:**

```console
$ kubectl api-versions | grep batch
batch/v1
```

Si `batch/v1beta1` no aparece en la salida, significa que ya fue removida en ese cluster.

**2. Ver todos los recursos disponibles y su versión preferida:**

```console
$ kubectl api-resources -o wide | grep -i cronjob
cronjobs   cj   batch/v1   true   CronJob   ...
```

**3. Revisar el schema de una versión específica con `kubectl explain`:**

```console
$ kubectl explain cronjob --api-version=batch/v1
```

**4. Herramientas dedicadas a auditar manifiestos/clusters antes de un upgrade** (mencionadas en el ecosistema CNCF, útiles para revisar Helm releases, manifests en Git o el estado vivo del cluster):

```console
$ pluto detect-all-in-cluster
NAME              KIND      VERSION          REPLACEMENT   REMOVED   DEPRECATED
backup-job        CronJob   batch/v1beta1    batch/v1      true      true
```

```console
$ kubent
>>> Deprecated APIs removed in 1.25 <<<
------------------------------------------------------------------------------------
KIND       NAMESPACE   NAME       API_VERSION
CronJob    default     backup-job batch/v1beta1
```

Estas herramientas no son parte de `kubectl` (no vienen instaladas por default), pero es útil saber que existen para el contexto de "cómo se gestiona esto en la práctica".

## Migrar un manifiesto a la nueva `apiVersion`

Casi siempre el cambio es solo actualizar el campo `apiVersion` (los campos del `spec` rara vez cambian entre beta y GA):

```yaml
# Antes
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: busybox
          restartPolicy: OnFailure
```

```yaml
# Después
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: busybox
          restartPolicy: OnFailure
```

Si intentás aplicar la versión vieja en un cluster donde ya fue removida, el error es explícito:

```console
$ kubectl apply -f cronjob-old.yaml
error: resource mapping not found for name: "backup-job" namespace: "" from "cronjob-old.yaml": no matches for kind "CronJob" in version "batch/v1beta1"
ensure CRDs are installed first
```

## Comandos clave para el día del examen

```bash
kubectl api-versions                       # lista todos los group/version disponibles en el cluster
kubectl api-resources                      # lista recursos, su kind y su versión preferida
kubectl explain <recurso> --api-version=<v> # ver el schema de una versión concreta
kubectl apply -f archivo.yaml               # aplicar y observar si aparece un Warning de deprecation
kubectl get <recurso>.<version>.<group>     # forzar la consulta contra una versión de API específica
```

En el examen, si un manifiesto provisto usa una `apiVersion` deprecada o inexistente en la versión del cluster, la tarea suele ser corregir ese campo apoyándose en `kubectl api-resources`/`kubectl explain` para encontrar la versión correcta.

## Referencias

- Kubernetes Deprecation Policy: https://kubernetes.io/docs/reference/using-api/deprecation-policy/
- Deprecated API Migration Guide: https://kubernetes.io/docs/reference/using-api/deprecation-guide/
- API versioning conceptual overview: https://kubernetes.io/docs/reference/using-api/#api-versioning
- CKAD Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Pluto (detección de APIs deprecadas): https://pluto.docs.fairwinds.com/
- kube-no-trouble (kubent): https://github.com/doitintl/kube-no-trouble