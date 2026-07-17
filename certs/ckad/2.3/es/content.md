# 2.3 Use the Helm package manager to deploy existing packages

**Examen:** CKAD (versión 1.35) · **Peso:** 5

---

## 1. Qué problema resuelve Helm

Desplegar una aplicación real casi nunca es un solo manifiesto. Algo tan común como un servidor web con base de datos puede implicar un `Deployment`, un `Service`, un `ConfigMap`, un `Secret`, un `PersistentVolumeClaim` y un `Ingress` — todos coordinados, con nombres consistentes y valores que cambian según el entorno (dev, staging, producción). Mantener esto a mano con `kubectl apply -f` sobre YAML estático se vuelve frágil apenas hay que parametrizar algo (una imagen, una cantidad de réplicas, un dominio).

**Helm** es el gestor de paquetes de Kubernetes: empaqueta ese conjunto de manifiestos en una unidad versionada e instalable (un **chart**), permite parametrizarla con valores, e instala/actualiza/revierte el conjunto completo como una sola operación atómica desde el punto de vista del historial de releases.

Este tema del curriculum (peso 5) evalúa específicamente **consumir charts ya existentes** — instalar, configurar con `values`, actualizar y revertir aplicaciones empaquetadas por terceros (Bitnami, la comunidad, un chart interno del equipo) — no autoría de charts desde cero.

---

## 2. Conceptos clave

| Concepto | Qué es |
|---|---|
| **Chart** | El paquete: una carpeta (o `.tgz`) con plantillas de manifiestos, metadata (`Chart.yaml`) y valores por defecto (`values.yaml`). Es el "instalable", análogo a un paquete `.deb`/`.rpm`. |
| **Release** | Una **instancia instalada** de un chart en un cluster, con un nombre propio. El mismo chart se puede instalar varias veces con nombres de release distintos (por ejemplo `nginx-prod` y `nginx-staging`), cada una con su propia configuración y su propio historial de revisiones. |
| **Repository** | Un índice HTTP (`index.yaml` + archivos `.tgz`) donde se publican charts, análogo a un repo APT/YUM. `bitnami`, `ingress-nginx` o un repo interno son ejemplos típicos. |
| **Values** | La configuración que parametriza un chart. Cada chart trae un `values.yaml` con defaults; el usuario los sobreescribe parcialmente al instalar/actualizar. |
| **Revision** | Cada `install`/`upgrade`/`rollback` de un release genera una nueva revisión numerada, lo que permite ver historial y volver atrás. |

---

## 3. Arquitectura: Helm 3 no tiene Tiller

Si ves material sobre **Helm 2**, ignoralo para el examen: Helm 2 tenía un componente server-side llamado **Tiller** corriendo dentro del cluster, con permisos amplios — un problema de seguridad recurrente. **Helm 3** (la única versión relevante hoy y en el CKAD) eliminó Tiller por completo:

- Helm es **solo un cliente** (el binario `helm`) que habla directamente con la API de Kubernetes, usando las mismas credenciales/kubeconfig que `kubectl`.
- El estado de cada release (qué se instaló, con qué valores, en qué revisión) se guarda como **Secrets** (por defecto) en el namespace donde vive el release — no hay una base de datos externa ni un componente adicional que mantener.

```bash
$ kubectl get secrets -n default | grep helm
sh.helm.release.v1.mi-app.v1   helm.sh/release.v1   1      2m
sh.helm.release.v1.mi-app.v2   helm.sh/release.v1   1      30s
```

Cada `sh.helm.release.v1.<release>.v<N>` es el manifiesto renderizado y los valores usados en esa revisión — de ahí sale el historial que usa `helm rollback`.

---

## 4. Instalación del cliente

```bash
$ curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
$ helm version
version.BuildInfo{Version:"v3.15.0", GitCommit:"...", GoVersion:"go1.22.3"}
```

No hace falta instalar nada en el cluster: si `kubectl` ya funciona contra el cluster (mismo `~/.kube/config`), `helm` también.

---

## 5. Repositorios: agregar, actualizar, buscar

Un cluster recién instalado no conoce ningún repositorio por defecto — hay que agregarlos explícitamente:

```bash
$ helm repo add bitnami https://charts.bitnami.com/bitnami
"bitnami" has been added to your repositories

$ helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
"ingress-nginx" has been added to your repositories

$ helm repo list
NAME            URL
bitnami         https://charts.bitnami.com/bitnami
ingress-nginx   https://kubernetes.github.io/ingress-nginx
```

Los índices se cachean localmente; hay que refrescarlos para ver charts/versiones nuevas:

```bash
$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "bitnami" chart repository
...Successfully got an update from the "ingress-nginx" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Buscar un chart por nombre o palabra clave, ya sea en los repos agregados o en el Artifact Hub público:

```bash
$ helm search repo wordpress
NAME                    CHART VERSION   APP VERSION   DESCRIPTION
bitnami/wordpress       23.0.5          6.5.3         WordPress is the world's most popular blogging...

$ helm search hub redis --max-col-width=40
URL                                       CHART VERSION   APP VERSION   DESCRIPTION
https://artifacthub.io/packages/helm/...  19.5.4          7.2.5         Redis(R) is an open source, advanced key-valu...
```

---

## 6. Inspeccionar un chart antes de instalar

Antes de instalar "a ciegas" conviene ver qué valores acepta el chart y qué manifiestos va a crear:

```bash
# Ver los values.yaml por defecto del chart (sin instalar nada)
$ helm show values bitnami/nginx | head -20
image:
  registry: docker.io
  repository: bitnami/nginx
  tag: 1.25.4-debian-12-r0
service:
  type: LoadBalancer
  ports:
    http: 80
replicaCount: 1
...

# Ver metadata del chart: versión, mantenedores, dependencias
$ helm show chart bitnami/nginx
apiVersion: v2
name: nginx
version: 15.14.0
appVersion: 1.25.4
description: NGINX Open Source is a web server...

# Renderizar los manifiestos finales SIN instalar (equivalente a un "dry render" local)
$ helm template mi-nginx bitnami/nginx --set service.type=ClusterIP > manifiestos.yaml

# Descargar el chart como .tgz para inspeccionarlo o modificarlo localmente
$ helm pull bitnami/nginx --untar
$ ls nginx/
Chart.yaml  values.yaml  templates/  charts/
```

`helm template` es especialmente útil en el examen: permite ver exactamente qué YAML va a aplicar `helm install` **sin tocar el cluster**, algo que `kubectl` no ofrece para charts.

---

## 7. Instalar un chart

```bash
$ helm install mi-nginx bitnami/nginx
NAME: mi-nginx
LAST DEPLOYED: Tue Jul  8 10:14:22 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
NOTES:
** Please be patient while the chart is being deployed **
...
```

Convención: `helm install <nombre-del-release> <chart>`. El chart puede referenciarse de varias formas:

```bash
$ helm install mi-nginx bitnami/nginx                    # desde un repo agregado
$ helm install mi-nginx ./nginx                           # desde una carpeta local
$ helm install mi-nginx ./nginx-15.14.0.tgz                # desde un .tgz local
$ helm install mi-nginx oci://registry-1.docker.io/bitnamicharts/nginx  # desde un OCI registry
```

### 7.1 Sobreescribir valores

Dos formas de personalizar, combinables:

```bash
# --set: para overrides puntuales, sintaxis "clave=valor" (con puntos para anidar)
$ helm install mi-nginx bitnami/nginx \
    --set replicaCount=3 \
    --set service.type=ClusterIP

# --values (o -f): un archivo YAML propio que se mergea sobre los defaults del chart
$ cat mis-valores.yaml
replicaCount: 3
service:
  type: ClusterIP
resources:
  requests:
    cpu: 100m
    memory: 128Mi

$ helm install mi-nginx bitnami/nginx -f mis-valores.yaml
```

Si se combinan ambos, `--set` tiene **precedencia más alta** y gana sobre lo que venga de `-f` o de los defaults del chart. Con múltiples `-f`, el último archivo listado gana sobre los anteriores.

### 7.2 Namespace y creación automática

```bash
$ helm install mi-nginx bitnami/nginx --namespace produccion --create-namespace
```

Sin `--create-namespace`, `helm install` falla si el namespace no existe — a diferencia de algunos flujos con `kubectl apply` donde el error puede ser menos evidente.

### 7.3 Validar antes de aplicar (dry-run)

```bash
$ helm install mi-nginx bitnami/nginx --dry-run --debug
```

Renderiza y valida contra el schema de la API sin crear objetos reales — útil para detectar errores de sintaxis en `values` antes de instalar de verdad.

---

## 8. Ver el estado de los releases instalados

```bash
$ helm list
NAME        NAMESPACE   REVISION   UPDATED                   STATUS     CHART           APP VERSION
mi-nginx    default     1          2026-07-08 10:14:22 UTC   deployed   nginx-15.14.0   1.25.4

$ helm list --all-namespaces          # equivalente a -A
$ helm list --uninstalled             # incluye releases fallidos/desinstalados (si aplica)
```

```bash
$ helm status mi-nginx
NAME: mi-nginx
LAST DEPLOYED: Tue Jul  8 10:14:22 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
```

```bash
# Ver los valores efectivamente usados (defaults + overrides) en el release instalado
$ helm get values mi-nginx
USER-SUPPLIED VALUES:
replicaCount: 3
service:
  type: ClusterIP

$ helm get values mi-nginx --all   # incluye también los defaults del chart, no solo lo que el usuario pisó

# Ver el manifiesto YAML completo que Helm efectivamente aplicó
$ helm get manifest mi-nginx | head -20

# Ver las NOTES.txt post-instalación (instrucciones del mantenedor del chart)
$ helm get notes mi-nginx
```

Los objetos creados siguen siendo Pods/Deployments/Services normales — `kubectl get all -l app.kubernetes.io/instance=mi-nginx` los muestra igual que a cualquier otro recurso.

---

## 9. Actualizar un release: `helm upgrade`

Cuando cambia la versión del chart, o simplemente se quieren ajustar valores, se usa `upgrade` — **nunca** se reinstala desde cero:

```bash
$ helm upgrade mi-nginx bitnami/nginx --set replicaCount=5
Release "mi-nginx" has been upgraded. Happy Helming!
NAME: mi-nginx
REVISION: 2
```

Puntos clave para el examen:

- `upgrade` reutiliza el release existente; cada ejecución exitosa suma una revisión (`REVISION: 2`, `3`, ...).
- Los `values` **no son acumulativos entre upgrades**: si en la revisión 1 se seteó `replicaCount=3` con `--set` y en el `upgrade` no se vuelve a pasar ese flag ni un `-f` que lo incluya, Helm usa el **default del chart**, no lo que estaba en la revisión anterior. Para preservar los valores existentes y solo tocar algunos, se usa `--reuse-values` (mergea con lo ya guardado) o, más prolijo, mantener siempre el mismo archivo `-f valores.yaml` versionado en git y actualizarlo ahí.

```bash
# Mantener todos los valores previos y solo agregar/cambiar algunos puntuales
$ helm upgrade mi-nginx bitnami/nginx --reuse-values --set image.tag=1.26.0
```

- `--install`: hace que `upgrade` funcione como "instalar si no existe, actualizar si existe" en un solo comando — muy usado en pipelines de CI/CD para que el mismo comando sea idempotente:

```bash
$ helm upgrade --install mi-nginx bitnami/nginx -f valores.yaml
```

- `--atomic`: si el upgrade falla (por ejemplo, un Pod nuevo no llega a `Ready`), revierte automáticamente a la revisión anterior en vez de dejar el release en un estado intermedio roto.

```bash
$ helm upgrade mi-nginx bitnami/nginx --set image.tag=version-inexistente --atomic --timeout 2m
Error: UPGRADE FAILED: ... timed out waiting for the condition
# Helm ya revirtió automáticamente a la revisión anterior funcional
```

---

## 10. Historial y rollback

```bash
$ helm history mi-nginx
REVISION   UPDATED                     STATUS       CHART           APP VERSION   DESCRIPTION
1          Tue Jul  8 10:14:22 2026    superseded   nginx-15.14.0   1.25.4        Install complete
2          Tue Jul  8 10:20:05 2026    superseded   nginx-15.14.0   1.25.4        Upgrade complete
3          Tue Jul  8 10:25:40 2026    deployed     nginx-15.14.0   1.25.4        Upgrade complete
```

Volver a una revisión anterior — Helm no "deshace" el cambio, sino que **crea una nueva revisión** cuyo contenido es igual al de la revisión objetivo:

```bash
$ helm rollback mi-nginx 2
Rollback was a success! Happy Helming!

$ helm history mi-nginx
REVISION   UPDATED                     STATUS       DESCRIPTION
1          ...                        superseded   Install complete
2          ...                        superseded   Upgrade complete
3          ...                        superseded   Upgrade complete
4          ...                        deployed     Rollback to 2
```

Sin número de revisión, `helm rollback mi-nginx` vuelve a la revisión anterior a la actual (equivalente a `kubectl rollout undo` sin `--to-revision`).

---

## 11. Desinstalar

```bash
$ helm uninstall mi-nginx
release "mi-nginx" uninstalled
```

Por defecto **borra el historial de revisiones junto con los recursos**. Si se quiere conservar el historial para poder hacer `helm install` de nuevo apuntando a una revisión vieja (poco común, pero existe la opción):

```bash
$ helm uninstall mi-nginx --keep-history
```

Un detalle que suele confundir en el examen: `helm uninstall` **no borra el namespace** aunque se haya usado `--create-namespace` en el install — los namespaces se gestionan por separado con `kubectl delete namespace`.

---

## 12. Qué hay dentro de un chart (para entender qué se instala)

Aunque el foco del tema es *consumir* charts, reconocer la estructura ayuda a leer/depurar uno ya existente:

```
nginx/
├── Chart.yaml          # metadata: name, version, appVersion, dependencies
├── values.yaml          # valores por defecto
├── charts/              # sub-charts (dependencias empaquetadas)
├── templates/           # manifiestos con sintaxis Go template
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl      # funciones/snippets reutilizables (nombres, labels)
│   └── NOTES.txt         # texto mostrado post-install/upgrade
└── .helmignore
```

Dentro de `templates/`, las plantillas referencian valores con `{{ .Values.algo }}` y metadata del chart con `{{ .Chart.Name }}` / `{{ .Release.Name }}`. `helm template` (visto arriba) es la forma de ver el resultado ya resuelto sin necesidad de leer Go templates a mano.

---

## 13. Buenas prácticas y errores comunes en el examen

- **Nunca reinstalar para "actualizar"**: `helm install` sobre un nombre de release que ya existe falla (`cannot re-use a name that is still in use`); lo correcto es siempre `helm upgrade` (o `upgrade --install` si no se sabe si ya existe).
- **`helm repo update` antes de instalar/buscar** si se acaba de agregar un repo o se espera una versión nueva — el índice local puede estar desactualizado.
- **Revisar `values` con `helm show values` antes de instalar** — instalar un chart de terceros sin mirar sus defaults (tipo de Service, tamaño de PVC, requests/limits) es la causa más común de sorpresas.
- **`--dry-run --debug` o `helm template`** para validar cambios de `values` antes de aplicarlos contra el cluster real — especialmente valioso bajo presión de tiempo en el examen, donde un error tipográfico en YAML de `values` puede consumir minutos si se descubre recién con `helm upgrade` fallando.
- **Los recursos creados por Helm llevan labels estándar** (`app.kubernetes.io/managed-by=Helm`, `app.kubernetes.io/instance=<release>`) — útiles para filtrarlos con `kubectl get all -l app.kubernetes.io/instance=<release>` cuando hace falta depurar con `kubectl` directamente.
- **No confundir `revision` de Helm con `replicas` de un Deployment** — son conceptos completamente distintos (historial de releases vs. cantidad de Pods).
- **El namespace no se borra solo**: `helm uninstall` limpia el release, pero no el namespace ni PVCs que el chart haya dejado con policy `Retain` (muchos charts de bases de datos, deliberadamente, no borran datos al desinstalar).

---

## 14. Comandos útiles (cheatsheet)

```bash
# Repos
helm repo add <nombre> <url>
helm repo update
helm search repo <término>
helm search hub <término>

# Inspección previa
helm show values <chart>
helm show chart <chart>
helm template <release> <chart> [-f values.yaml] [--set clave=valor]
helm pull <chart> --untar

# Ciclo de vida de un release
helm install <release> <chart> [-f values.yaml] [--set k=v] [-n <namespace>] [--create-namespace]
helm upgrade <release> <chart> [-f values.yaml] [--reuse-values] [--atomic]
helm upgrade --install <release> <chart> -f values.yaml
helm rollback <release> [<revision>]
helm uninstall <release> [--keep-history]

# Estado
helm list [-A]
helm status <release>
helm history <release>
helm get values <release> [--all]
helm get manifest <release>
helm get notes <release>
```

---

## 15. Resumen para el examen

- Helm 3 es **solo cliente** — sin Tiller. El estado de cada release se guarda como Secrets en el cluster.
- **Chart** = paquete instalable; **Release** = instancia instalada con nombre propio; una misma release acumula **revisiones** en cada install/upgrade/rollback.
- Antes de instalar, inspeccionar con `helm show values`, `helm show chart` y `helm template` (esto último renderiza el YAML final sin tocar el cluster).
- Instalar con `helm install <release> <chart>`, parametrizando con `--set clave=valor` (mayor precedencia) y/o `-f archivo.yaml`.
- Para cambios posteriores siempre `helm upgrade` — nunca reinstalar. `--install` lo hace idempotente; `--atomic` revierte solo si el upgrade falla; `--reuse-values` evita perder overrides previos si no se repasan todos los `--set`/`-f`.
- `helm rollback <release> [<revision>]` no deshace: crea una **nueva revisión** con el contenido de la revisión objetivo. `helm history` lista todas las revisiones.
- `helm uninstall` borra el release y sus recursos (y por defecto el historial), pero **no** el namespace ni necesariamente los datos persistentes.
- `helm list`, `helm status`, `helm get values/manifest/notes` son las herramientas de inspección de un release ya instalado.

---

## Referencias

- Helm — Documentación oficial: https://helm.sh/docs/
- Helm — Quickstart Guide: https://helm.sh/docs/intro/quickstart/
- Helm — Using Helm (conceptos: Chart, Repository, Release): https://helm.sh/docs/intro/using_helm/
- Helm — Chart Template Guide: https://helm.sh/docs/chart_template_guide/
- Helm CLI — helm install: https://helm.sh/docs/helm/helm_install/
- Helm CLI — helm upgrade: https://helm.sh/docs/helm/helm_upgrade/
- Helm CLI — helm rollback: https://helm.sh/docs/helm/helm_rollback/
- Artifact Hub (buscador de charts públicos): https://artifacthub.io/
- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf