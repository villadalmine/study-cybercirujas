# Ejercicios guiados — Tema 2.3: Use the Helm package manager to deploy existing packages

**Certificación:** CKAD (examen CKAD, versión 1.35) · **Peso:** 5
**Fuente de referencia:** [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

> Necesitás un cluster de Kubernetes accesible con `kubectl` (minikube, kind, k3s o similar) y el binario `helm` (v3) instalado. Los ejercicios usan el chart público `bitnami/nginx` y requieren salida a internet para descargarlo del repositorio de Bitnami. Todo se instala en un namespace dedicado `ckad-2-3` para no interferir con otros ejercicios.

---

## Ejercicio 1 — Instalar el cliente Helm y agregar un repositorio

Helm 3 es solo un binario cliente: no hay nada que instalar en el cluster.

1. Confirmá que tenés Helm 3 (no Helm 2, que traía Tiller):

   ```bash
   helm version
   ```

   ```
   version.BuildInfo{Version:"v3.15.0", GitCommit:"...", GitTreeState:"clean", GoVersion:"go1.22.3"}
   ```

2. Un cluster recién configurado no conoce ningún repositorio por defecto. Agregá el de Bitnami:

   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   ```

   ```
   "bitnami" has been added to your repositories
   ```

3. Refrescá el índice local (necesario para ver versiones nuevas de charts):

   ```bash
   helm repo update
   ```

4. Listá los repos agregados y buscá el chart de `nginx` dentro de ese repo:

   ```bash
   helm repo list
   helm search repo bitnami/nginx
   ```

**Preguntas de verificación**

- **1.a)** `helm version` no muestra ningún componente corriendo en el cluster. ¿Por qué Helm 3 no necesita instalar nada server-side, a diferencia de Helm 2?
- **1.b)** Si te olvidás de correr `helm repo update` después de agregar el repo, ¿qué consecuencia concreta puede tener al buscar o instalar un chart?
- **1.c)** ¿Qué diferencia hay entre `helm repo add` y lo que hace `helm install`? Es decir, ¿agregar un repo instala algo en el cluster?

---

## Ejercicio 2 — Inspeccionar un chart antes de instalar

Instalar "a ciegas" un chart de terceros es la forma más común de llevarse una sorpresa (tipo de `Service`, tamaño de recursos, etc.). Antes de instalar, revisá qué trae.

1. Mirá la metadata del chart (versión del chart, versión de la app, mantenedores):

   ```bash
   helm show chart bitnami/nginx
   ```

2. Mirá los valores por defecto que trae el chart:

   ```bash
   helm show values bitnami/nginx | head -30
   ```

3. Renderizá los manifiestos finales **sin instalar nada**, simulando ya el override que vas a usar más adelante (`service.type=ClusterIP`):

   ```bash
   helm template mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --set service.type=ClusterIP \
       --set replicaCount=2 > manifiestos-renderizados.yaml

   grep -E "^kind:|replicas:|type: ClusterIP" manifiestos-renderizados.yaml
   ```

4. Confirmá que no se creó nada en el cluster todavía:

   ```bash
   kubectl get all -n ckad-2-3
   ```

   ```
   Error from server (NotFound): namespaces "ckad-2-3" not found
   ```

**Preguntas de verificación**

- **2.a)** `helm template` y `helm install --dry-run` son parecidos. ¿Qué gana `helm template` frente a leer los `templates/*.yaml` del chart directamente en un editor?
- **2.b)** El namespace `ckad-2-3` ni siquiera existe todavía, pero `helm template --namespace ckad-2-3` no dio error. ¿Por qué? ¿Renderizar un manifiesto requiere que el namespace exista?
- **2.c)** Si no hubieras pasado `--set replicaCount=2`, ¿de dónde hubiera salido el valor de `replicas` en el Deployment renderizado?

---

## Ejercicio 3 — Instalar el chart con valores personalizados

Ahora instalá el chart de verdad, combinando un archivo de `values` con overrides puntuales.

1. Creá el archivo de valores:

   ```bash
   cat > mis-valores.yaml <<'EOF'
   replicaCount: 2
   service:
     type: ClusterIP
   resources:
     requests:
       cpu: 100m
       memory: 128Mi
     limits:
       cpu: 200m
       memory: 256Mi
   EOF
   ```

2. Instalá el release, creando el namespace en el mismo comando:

   ```bash
   helm install mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --create-namespace \
       -f mis-valores.yaml \
       --set image.tag=1.25.4-debian-12-r0
   ```

   ```
   NAME: mi-nginx
   LAST DEPLOYED: Tue Jul 11 10:14:22 2026
   NAMESPACE: ckad-2-3
   STATUS: deployed
   REVISION: 1
   ```

3. Verificá el release y los objetos que Helm creó:

   ```bash
   helm list -n ckad-2-3
   helm status mi-nginx -n ckad-2-3
   kubectl get all -n ckad-2-3 -l app.kubernetes.io/instance=mi-nginx
   ```

4. Confirmá que el `Service` quedó con el tipo pedido y no con el default del chart:

   ```bash
   kubectl get svc -n ckad-2-3 -l app.kubernetes.io/instance=mi-nginx
   ```

**Preguntas de verificación**

- **3.a)** En el comando de instalación se combinaron `-f mis-valores.yaml` (que no define `image.tag`) con `--set image.tag=1.25.4-debian-12-r0`. Si `mis-valores.yaml` también hubiera definido `image.tag` con otro valor, ¿cuál gana?
- **3.b)** ¿Qué hubiera pasado si corrías el mismo `helm install` sin `--create-namespace` y el namespace `ckad-2-3` no existiera?
- **3.c)** El label `app.kubernetes.io/instance=mi-nginx` no lo escribiste vos en ningún YAML. ¿De dónde sale y para qué sirve al usar `kubectl` directamente sobre recursos gestionados por Helm?

---

## Ejercicio 4 — Ver el estado y los valores efectivos de un release

Un release instalado se puede auditar completamente sin volver a mirar el chart original.

1. Mirá solo los valores que vos sobreescribiste:

   ```bash
   helm get values mi-nginx -n ckad-2-3
   ```

   ```
   USER-SUPPLIED VALUES:
   image:
     tag: 1.25.4-debian-12-r0
   replicaCount: 2
   resources:
     limits:
       cpu: 200m
       memory: 256Mi
     requests:
       cpu: 100m
       memory: 128Mi
   service:
     type: ClusterIP
   ```

2. Ahora mirá el set completo, incluyendo los defaults del chart que no tocaste:

   ```bash
   helm get values mi-nginx -n ckad-2-3 --all | head -20
   ```

3. Mirá el manifiesto YAML final que Helm efectivamente aplicó contra la API:

   ```bash
   helm get manifest mi-nginx -n ckad-2-3 | grep -A2 "kind: Deployment"
   ```

4. Confirmá dónde vive el estado del release — no hay base de datos externa, es un `Secret` en el mismo namespace:

   ```bash
   kubectl get secrets -n ckad-2-3 | grep helm.sh/release
   ```

   ```
   sh.helm.release.v1.mi-nginx.v1   helm.sh/release.v1   1      5m
   ```

**Preguntas de verificación**

- **4.a)** ¿Por qué `helm get values` (sin `--all`) no muestra `replicaCount` heredado del chart si vos no lo hubieras seteado, pero sí lo muestra en este ejercicio?
- **4.b)** El `Secret` `sh.helm.release.v1.mi-nginx.v1` — ¿qué pasa con este objeto la próxima vez que hagas un `helm upgrade` exitoso? ¿Se modifica o se crea uno nuevo?
- **4.c)** Si alguien borrara a mano el `Secret` `sh.helm.release.v1.mi-nginx.v1` con `kubectl delete`, sin tocar el Deployment ni el Service, ¿qué comando de Helm dejaría de funcionar correctamente sobre ese release?

---

## Ejercicio 5 — `helm upgrade` y el trap de los valores no acumulativos

Este es uno de los errores más comunes en el examen: asumir que los valores de una instalación anterior "quedan pegados" en el próximo upgrade.

1. Actualizá el release cambiando solo `replicaCount`, **sin** volver a pasar `-f mis-valores.yaml`:

   ```bash
   helm upgrade mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --set replicaCount=3
   ```

   ```
   Release "mi-nginx" has been upgraded. Happy Helming!
   REVISION: 2
   ```

2. Revisá qué tipo de `Service` quedó ahora:

   ```bash
   kubectl get svc -n ckad-2-3 -l app.kubernetes.io/instance=mi-nginx
   ```

3. Confirmalo mirando los valores efectivos del release:

   ```bash
   helm get values mi-nginx -n ckad-2-3
   ```

4. Corregilo usando `--reuse-values`, que mergea con lo que ya estaba guardado en la revisión anterior en vez de partir de los defaults del chart:

   ```bash
   helm upgrade mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --reuse-values \
       --set replicaCount=3
   ```

5. Verificá el historial de revisiones acumuladas hasta acá:

   ```bash
   helm history mi-nginx -n ckad-2-3
   ```

**Preguntas de verificación**

- **5.a)** En el paso 2, ¿el `Service` volvió a `LoadBalancer` (el default del chart) o se quedó en `ClusterIP`? Explicá por qué, en términos de qué `values` usa Helm en cada `upgrade`.
- **5.b)** ¿Qué diferencia hay entre `--reuse-values` y simplemente volver a pasar `-f mis-valores.yaml` en cada `upgrade`? ¿Cuál preferirías en un pipeline de CI/CD versionado en git y por qué?
- **5.c)** Después del paso 4, ¿cuántas revisiones tiene el release en `helm history`? ¿El paso 1 (el upgrade "roto") cuenta como una revisión aparte o se pisa?

---

## Ejercicio 6 — `upgrade --install` idempotente y `--atomic` ante un fallo

En pipelines de CI/CD casi nunca se sabe de antemano si un release ya existe. `--install` resuelve eso; `--atomic` protege contra un upgrade que rompe el release.

1. Corré el mismo comando dos veces seguidas — la primera actualiza, la segunda no debería fallar aunque el release ya exista:

   ```bash
   helm upgrade --install mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --reuse-values \
       --set replicaCount=3

   helm upgrade --install mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --reuse-values \
       --set replicaCount=3
   ```

2. Ahora provocá un upgrade que va a fallar: un tag de imagen inexistente, con `--atomic` y un timeout corto:

   ```bash
   helm upgrade mi-nginx bitnami/nginx \
       --namespace ckad-2-3 \
       --reuse-values \
       --set image.tag=version-que-no-existe \
       --atomic \
       --timeout 90s
   ```

   ```
   Error: UPGRADE FAILED: release mi-nginx failed, and has been rolled back due to atomic being set: ...timed out waiting for the condition
   ```

3. Confirmá que el release quedó en un estado sano (no en un limbo con Pods rotos):

   ```bash
   helm status mi-nginx -n ckad-2-3
   kubectl get pods -n ckad-2-3 -l app.kubernetes.io/instance=mi-nginx
   ```

4. Mirá el historial completo — el intento fallido también deja rastro:

   ```bash
   helm history mi-nginx -n ckad-2-3
   ```

**Preguntas de verificación**

- **6.a)** En el paso 1, ¿qué hubiera pasado con el segundo comando si en vez de `helm upgrade --install` hubieras corrido `helm install` a secas?
- **6.b)** Si el paso 2 se hubiera corrido **sin** `--atomic`, ¿en qué estado hubiera quedado el release y qué tendrías que hacer manualmente para recuperarlo?
- **6.c)** En `helm history` del paso 4, ¿aparece una revisión con `STATUS: failed`, o el rollback automático de `--atomic` hace que no quede ningún rastro del intento roto?

---

## Ejercicio 7 — Historial, rollback y desinstalación

Cerrá el ciclo completo del release: volver a una revisión anterior y después desinstalar.

1. Repasá el historial completo de revisiones y anotá el número de la primera (`REVISION: 1`, la instalación original con `service.type: ClusterIP` y `replicaCount: 2`):

   ```bash
   helm history mi-nginx -n ckad-2-3
   ```

2. Hacé rollback a esa revisión:

   ```bash
   helm rollback mi-nginx 1 -n ckad-2-3
   ```

   ```
   Rollback was a success! Happy Helming!
   ```

3. Confirmá que el `replicaCount` volvió a 2 y que se generó una revisión **nueva**, no que "se borró" el historial hasta ahí:

   ```bash
   kubectl get deploy -n ckad-2-3 -l app.kubernetes.io/instance=mi-nginx
   helm history mi-nginx -n ckad-2-3
   ```

4. Desinstalá el release conservando el historial de revisiones:

   ```bash
   helm uninstall mi-nginx -n ckad-2-3 --keep-history
   ```

5. Confirmá qué quedó y qué no:

   ```bash
   kubectl get all -n ckad-2-3
   helm history mi-nginx -n ckad-2-3
   kubectl get namespace ckad-2-3
   ```

6. Limpiá el namespace de prueba:

   ```bash
   kubectl delete namespace ckad-2-3
   ```

**Preguntas de verificación**

- **7.a)** Después del `helm rollback mi-nginx 1`, ¿qué número de revisión tiene el release en `helm history`? ¿Por qué no vuelve a mostrar `REVISION: 1` como la revisión activa?
- **7.b)** En el paso 5, `kubectl get all -n ckad-2-3` no debería mostrar nada, pero `helm history mi-nginx -n ckad-2-3` sí sigue respondiendo. ¿Por qué esa asimetría, dado que usaste `--keep-history`?
- **7.c)** El namespace `ckad-2-3` sigue existiendo después de `helm uninstall`, aunque se creó con `--create-namespace` en el `helm install` original. ¿Qué comando lo borra?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** Helm 3 eliminó **Tiller**, el componente server-side que tenía Helm 2 corriendo dentro del cluster con permisos amplios (un problema de seguridad recurrente). Desde Helm 3, el binario `helm` habla directamente con la API de Kubernetes usando el mismo `kubeconfig`/credenciales que `kubectl`, así que no hay nada adicional que desplegar ni mantener en el cluster.
- **1.b)** El índice local de charts y versiones queda desactualizado: `helm search repo` puede no mostrar una versión nueva del chart, o `helm install`/`helm show values` pueden traer una versión vieja del chart en vez de la última disponible en el repositorio remoto.
- **1.c)** `helm repo add` solo registra la URL de un índice HTTP en la configuración local del cliente Helm (algo enteramente del lado del usuario, no toca el cluster). `helm install` es el que efectivamente crea objetos en el cluster (Deployments, Services, etc.) a partir de un chart de ese repo. Agregar un repo no instala ni descarga nada por sí mismo.

### Ejercicio 2

- **2.a)** `helm template` resuelve la sintaxis de Go templates (`{{ .Values.algo }}`, condicionales, loops, sub-charts) y produce el YAML final literal, exactamente como quedaría en el cluster. Leer los archivos de `templates/*.yaml` a mano obliga a mentalmente "ejecutar" esas plantillas — con charts complejos (Bitnami, por ejemplo) es prácticamente inviable predecir el resultado sin renderizarlo.
- **2.b)** `helm template` es una operación 100% local: no hace ninguna llamada a la API de Kubernetes para validar que el namespace exista (a diferencia de `helm install`, que sí necesita crear objetos ahí). El valor de `--namespace` solo se usa para completar el campo `metadata.namespace` en el YAML renderizado.
- **2.c)** Del `values.yaml` por defecto que trae el chart `bitnami/nginx` (visto en el paso 2 con `helm show values`), típicamente `replicaCount: 1`.

### Ejercicio 3

- **3.a)** Gana `--set`. Helm aplica los overrides en un orden de precedencia donde `--set` (y `--set-string`, `--set-json`, etc.) tiene **prioridad más alta** que cualquier archivo pasado con `-f`/`--values`, sin importar el orden en que se escriban en la línea de comandos.
- **3.b)** El comando hubiera fallado directamente, con un error indicando que el namespace `ckad-2-3` no existe. A diferencia de algunos flujos con `kubectl apply` donde un namespace faltante puede generar errores menos evidentes recurso por recurso, `helm install` sin `--create-namespace` no crea el namespace implícitamente.
- **3.c)** Es un label estándar que Helm agrega automáticamente a todos los objetos que crea (junto con `app.kubernetes.io/managed-by: Helm` y otros). Sirve para poder filtrar con `kubectl` todos los recursos que pertenecen a un release específico sin depender de que el chart haya definido labels propios consistentes.

### Ejercicio 4

- **4.a)** `helm get values` sin `--all` muestra únicamente las claves que el usuario sobreescribió explícitamente (`USER-SUPPLIED VALUES`) — en este ejercicio `replicaCount: 2` aparece porque fue pasado explícitamente en `mis-valores.yaml` durante la instalación, no porque sea el default del chart.
- **4.b)** Se crea un `Secret` **nuevo**, versionado (`sh.helm.release.v1.mi-nginx.v2`), sin modificar el de la revisión anterior. Esto es lo que le permite a Helm mantener un historial completo de revisiones y hacer `rollback` a cualquiera de ellas.
- **4.c)** `helm history mi-nginx` perdería esa revisión del historial (o, si se borra el único Secret existente, Helm ya no reconocería el release como instalado vía su mecanismo normal), y comandos como `helm rollback` a esa revisión específica dejarían de funcionar, aunque el Deployment y el Service sigan corriendo con total normalidad en el cluster.

### Ejercicio 5

- **5.a)** Volvió a `LoadBalancer`, el default del chart. Los `values` **no son acumulativos entre upgrades**: cada `helm upgrade` parte de los defaults del chart y aplica únicamente los `--set`/`-f` que se pasan en *ese* comando puntual. Como el segundo comando solo trae `--set replicaCount=3` y no repite `-f mis-valores.yaml`, el override de `service.type: ClusterIP` de la revisión anterior se pierde.
- **5.b)** `--reuse-values` toma los valores **ya guardados** en la revisión actual del release y los mergea con los nuevos `--set`/`-f` del comando (los nuevos tienen prioridad si hay conflicto), sin necesidad de tener el archivo de valores completo a mano en ese momento. Volver a pasar `-f mis-valores.yaml` en cada `upgrade` es más explícito y auditable en un pipeline de CI/CD, porque el archivo versionado en git es la única fuente de verdad y no depende de qué se haya seteado manualmente en un `upgrade` anterior — es la opción preferible cuando el archivo de valores vive en el repositorio.
- **5.c)** Tres revisiones: `REVISION: 1` (install original), `REVISION: 2` (el upgrade "roto" del paso 1 — sí cuenta como revisión propia, aunque haya perdido el override de `service.type`), y `REVISION: 3` (el upgrade corregido del paso 4 con `--reuse-values`). Helm nunca "pisa" una revisión existente; cada `upgrade` exitoso siempre suma una nueva.

### Ejercicio 6

- **6.a)** `helm install mi-nginx ...` hubiera fallado con un error del tipo `cannot re-use a name that is still in use`, porque `install` asume que el nombre de release no existe todavía. `upgrade --install` es justamente lo que resuelve ese problema: actúa como upgrade si el release ya existe, o como install si no existe — haciendo el comando idempotente, ideal para correrlo repetidamente en un pipeline.
- **6.b)** Sin `--atomic`, el release hubiera quedado en estado `failed` (o con Pods nuevos atascados sin llegar a `Ready`, mientras los Pods viejos de la revisión anterior podrían seguir corriendo en paralelo según cómo esté configurada la estrategia de rollout). Para recuperarlo manualmente habría que correr `helm rollback mi-nginx` a la última revisión sana, o investigar y corregir el problema (en este caso, el tag de imagen inexistente) y reintentar el `upgrade`.
- **6.c)** Sí aparece una revisión con el intento — el rollback automático de `--atomic` **crea una revisión nueva** con el contenido de la última revisión sana (el mismo mecanismo que un `helm rollback` manual), en vez de simplemente descartar el intento sin dejar rastro. El historial completo queda visible: la revisión intermedia rota y la revisión de recuperación posterior.

### Ejercicio 7

- **7.a)** El release queda en una revisión nueva (por ejemplo `REVISION: 4`, siguiendo la numeración de este ejercicio), con `DESCRIPTION: Rollback to 1`. Helm nunca "retrocede" el contador de revisiones ni reactiva la `REVISION: 1` original — un rollback es conceptualmente un `upgrade` cuyo contenido copia el de la revisión objetivo, así que siempre suma una revisión nueva al historial.
- **7.b)** `kubectl get all` consulta directamente los objetos vivos del cluster (Deployment, Service, Pods), que sí fueron eliminados por `helm uninstall`. `helm history` no lee esos objetos: lee los `Secrets` `sh.helm.release.v1.mi-nginx.v*` que registran el historial de revisiones, y esos se conservan deliberadamente porque se pasó `--keep-history` — son registros independientes de los recursos aplicados.
- **7.c)** Ninguno de los comandos de `helm` lo hace — `helm uninstall` gestiona exclusivamente el release (y opcionalmente su historial), nunca el namespace en el que vive. Hay que borrarlo explícitamente con `kubectl delete namespace ckad-2-3`.

</details>

---

**Fuentes consultadas:**
- CKAD Curriculum v1.35 (CNCF): [https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)
- Helm — Documentación oficial: [https://helm.sh/docs/](https://helm.sh/docs/)
- Helm CLI — helm upgrade: [https://helm.sh/docs/helm/helm_upgrade/](https://helm.sh/docs/helm/helm_upgrade/)
- Helm CLI — helm rollback: [https://helm.sh/docs/helm/helm_rollback/](https://helm.sh/docs/helm/helm_rollback/)
- Bitnami nginx chart: [https://github.com/bitnami/charts/tree/main/bitnami/nginx](https://github.com/bitnami/charts/tree/main/bitnami/nginx)