# Ejercicios guiados: Helm package manager (CKAD 2.3)

**Prerequisito:** acceso a un cluster de Kubernetes vía `kubectl` con permisos para crear objetos en al menos un namespace.

---

## Bloque 1 — Instalación y verificación de Helm

1. Verificá si Helm 3 ya está instalado y qué versión corre:
   ```bash
   helm version --short
   ```
2. Si no está instalado, instalalo (Linux/macOS, vía script oficial):
   ```bash
   curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
   chmod 700 get_helm.sh
   ./get_helm.sh
   ```
3. Confirmá que Helm usa el mismo contexto que `kubectl` y puede listar releases (aunque no haya ninguno todavía) en todos los namespaces:
   ```bash
   helm list --all-namespaces
   ```
4. Creá un namespace dedicado para estos ejercicios:
   ```bash
   kubectl create namespace helm-demo
   ```

**Preguntas de comprensión:**
1. A diferencia de Helm 2, ¿Helm 3 requiere un componente server-side (Tiller) corriendo dentro del cluster?
2. ¿Con qué credenciales se autentica Helm contra el API server, y qué implica esto para RBAC?

---

## Bloque 2 — Agregar un repo y buscar charts

1. Agregá el repositorio de charts de Bitnami:
   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   ```
2. Actualizá el índice local de charts de todos los repos agregados:
   ```bash
   helm repo update
   ```
3. Listá los repos configurados:
   ```bash
   helm repo list
   ```
4. Buscá charts de nginx dentro de los repos agregados localmente:
   ```bash
   helm search repo nginx
   ```
5. Buscá el mismo chart en Artifact Hub (índice público, sin necesidad de agregar el repo primero):
   ```bash
   helm search hub nginx --max-col-width=0
   ```

**Preguntas de comprensión:**
1. ¿Qué diferencia hay entre `helm search repo` y `helm search hub`?
2. ¿Qué comando ejecutarías si sospechás que el índice local de un repo está desactualizado respecto al remoto?

---

## Bloque 3 — Instalar un chart (crear un release)

1. Inspeccioná los values por defecto del chart antes de instalarlo:
   ```bash
   helm show values bitnami/nginx | less
   ```
2. Instalá el chart como un nuevo release llamado `web` en el namespace `helm-demo`:
   ```bash
   helm install web bitnami/nginx --namespace helm-demo
   ```
3. Listá los releases activos en ese namespace:
   ```bash
   helm list --namespace helm-demo
   ```
4. Verificá que Kubernetes efectivamente creó los objetos (Deployment, Service, etc.):
   ```bash
   kubectl get all --namespace helm-demo
   ```

**Preguntas de comprensión:**
1. ¿Qué es un "release" en la terminología de Helm y en qué se diferencia de un "chart"?
2. Si corrieras `helm install web bitnami/nginx --namespace helm-demo` una segunda vez sin cambiar el nombre, ¿qué pasaría?

---

## Bloque 4 — Inspeccionar un release existente

1. Consultá el estado detallado del release:
   ```bash
   helm status web --namespace helm-demo
   ```
2. Mostrá los values efectivamente usados (default + overrides) para ese release:
   ```bash
   helm get values web --namespace helm-demo --all
   ```
3. Mostrá el manifest completo de Kubernetes que Helm renderizó y aplicó:
   ```bash
   helm get manifest web --namespace helm-demo
   ```
4. Revisá el historial de revisiones del release (por ahora debería haber una sola):
   ```bash
   helm history web --namespace helm-demo
   ```

**Preguntas de comprensión:**
1. ¿Qué diferencia hay entre `helm get values` con `--all` y sin esa flag?
2. ¿De dónde saca Helm el manifest que muestra `helm get manifest`: lo vuelve a renderizar en el momento, o lo recupera de un release guardado?

---

## Bloque 5 — Customizar values e instalar con overrides

1. Creá un archivo `custom-values.yaml` con un override simple (por ejemplo, cambiar el número de réplicas):
   ```yaml
   replicaCount: 2
   ```
2. Verificá, sin instalar nada, qué manifest generaría ese override (`--dry-run` + `--debug`) contra un release nuevo de prueba:
   ```bash
   helm install web-test bitnami/nginx --namespace helm-demo -f custom-values.yaml --dry-run --debug
   ```
3. Aplicá el mismo override como un `upgrade` sobre el release `web` que ya existe:
   ```bash
   helm upgrade web bitnami/nginx --namespace helm-demo -f custom-values.yaml
   ```
4. Alternativamente, para un cambio puntual, hacé un upgrade usando `--set` en vez de un archivo:
   ```bash
   helm upgrade web bitnami/nginx --namespace helm-demo --set replicaCount=3
   ```
5. Confirmá el cambio revisando el historial:
   ```bash
   helm history web --namespace helm-demo
   ```

**Preguntas de comprensión:**
1. Si combinás `-f custom-values.yaml` y `--set replicaCount=3` en el mismo comando, ¿cuál de los dos gana?
2. ¿Qué hace `--dry-run --debug` y por qué es útil antes de un `install` o `upgrade` real?
3. ¿Qué pasa con la numeración de `REVISION` en `helm history` después de cada `upgrade`?

---

## Bloque 6 — Rollback a una revisión anterior

1. Provocá intencionalmente un upgrade que falle o quede con una configuración no deseada, por ejemplo apuntando a una imagen inexistente:
   ```bash
   helm upgrade web bitnami/nginx --namespace helm-demo --set image.tag=no-existe-1.0
   ```
2. Verificá el estado de los pods para confirmar el problema:
   ```bash
   kubectl get pods --namespace helm-demo
   ```
3. Revisá el historial para identificar el número de revisión buena anterior:
   ```bash
   helm history web --namespace helm-demo
   ```
4. Hacé rollback a esa revisión:
   ```bash
   helm rollback web <REVISION> --namespace helm-demo
   ```
5. Confirmá que el rollback generó una nueva entrada en el historial (no borra las anteriores):
   ```bash
   helm history web --namespace helm-demo
   ```

**Preguntas de comprensión:**
1. ¿Un `helm rollback` elimina las revisiones posteriores del historial o simplemente agrega una nueva revisión que reaplica el estado anterior?
2. ¿Cómo sabrías a qué número de revisión hacer rollback si el historial tiene 6 entradas?

---

## Bloque 7 — Desinstalar un release

1. Desinstalá el release `web`:
   ```bash
   helm uninstall web --namespace helm-demo
   ```
2. Confirmá que ya no aparece en la lista de releases:
   ```bash
   helm list --namespace helm-demo
   ```
3. Verificá que Kubernetes eliminó los objetos asociados:
   ```bash
   kubectl get all --namespace helm-demo
   ```
4. Repetí el uninstall del release de prueba `web-test` si llegó a instalarse en el Bloque 5:
   ```bash
   helm uninstall web-test --namespace helm-demo
   ```

**Preguntas de comprensión:**
1. Por defecto, ¿`helm uninstall` conserva el historial de revisiones para poder hacer rollback después de desinstalado?
2. ¿Qué flag usarías con `helm uninstall` si quisieras conservar ese historial igualmente?

---

## Bloque 8 — Explorar un chart antes de instalarlo (sin tocar el cluster)

1. Descargá el chart como archivo `.tgz` local, sin instalarlo:
   ```bash
   helm pull bitnami/nginx --destination /tmp
   ```
2. Descargalo y extraelo directamente en un directorio, para inspeccionar sus archivos:
   ```bash
   helm pull bitnami/nginx --untar --destination /tmp
   ls /tmp/nginx
   ```
3. Mostrá el `Chart.yaml` (metadata) y el `README` del chart:
   ```bash
   helm show chart bitnami/nginx
   helm show readme bitnami/nginx
   ```
4. Renderizá localmente los templates del chart con tus overrides, sin contactar al cluster ni crear ningún release:
   ```bash
   helm template web bitnami/nginx --namespace helm-demo -f custom-values.yaml
   ```

**Preguntas de comprensión:**
1. ¿Qué diferencia hay entre `helm template` y `helm install --dry-run`?
2. Si necesitás auditar qué objetos de Kubernetes va a crear un chart de un tercero antes de aplicarlo en un cluster productivo, ¿qué comando de este bloque usarías primero?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Bloque 1**
1. No. Helm 3 eliminó Tiller: el cliente `helm` habla directamente con el API server usando el kubeconfig del usuario, por lo que los permisos de Helm son exactamente los permisos RBAC del usuario/service account que ejecuta el comando (no hay un componente con permisos elevados corriendo en el cluster).
2. Usa el mismo kubeconfig (contexto, cluster, usuario) que `kubectl` esté usando en ese momento — no gestiona credenciales propias.

**Bloque 2**
1. `helm search repo` busca solo en los índices de los repos que agregaste localmente con `helm repo add` (requiere `helm repo update` para estar al día). `helm search hub` consulta el índice público de Artifact Hub sin necesidad de haber agregado el repo.
2. `helm repo update`.

**Bloque 3**
1. Un chart es el paquete (plantillas + metadata + values por defecto) que describe cómo desplegar una aplicación; un release es una instancia concreta de ese chart desplegada en el cluster, identificada por un nombre y asociada a un namespace. Un mismo chart puede instalarse múltiples veces como releases distintos con nombres diferentes.
2. Fallaría con un error indicando que ya existe un release con ese nombre en ese namespace — Helm no permite dos releases con el mismo nombre en el mismo namespace.

**Bloque 4**
1. Sin `--all`, `helm get values` muestra solo los values que el usuario sobreescribió explícitamente al instalar/actualizar (user-supplied). Con `--all`, muestra el resultado combinado de esos overrides fusionados con los values por defecto del chart.
2. Lo recupera del release guardado (el manifest se guarda como parte del historial de esa revisión en el cluster, típicamente en un Secret); no se vuelve a renderizar el chart en el momento de la consulta.

**Bloque 5**
1. Gana `--set`: los flags pasados en la línea de comandos tienen precedencia sobre los valores provistos con `-f`/`--values`, y entre múltiples `-f` gana el último archivo especificado.
2. Simula el install/upgrade y muestra el manifest de Kubernetes que se generaría, sin aplicarlo realmente al cluster (`--dry-run`) e imprimiendo información adicional de depuración como los values combinados (`--debug`). Sirve para detectar errores de templating o valores incorrectos antes de tocar el cluster.
3. Se incrementa en 1 en cada `upgrade` (y también en cada `rollback`); nunca decrece ni se reutiliza.

**Bloque 6**
1. Agrega una nueva revisión al historial que reaplica el estado de la revisión objetivo; no borra ni modifica las revisiones intermedias, que quedan disponibles para futuros rollbacks.
2. Con `helm history web --namespace helm-demo`, identificando el número de `REVISION` correspondiente al estado bueno conocido (por su `DESCRIPTION`/`STATUS` y el orden cronológico).

**Bloque 7**
1. No. Por defecto `helm uninstall` borra el historial de revisiones junto con los recursos.
2. `--keep-history`.

**Bloque 8**
1. `helm template` solo renderiza los templates localmente usando el chart y los values, sin contactar al API server en absoluto (no verifica compatibilidad con el cluster ni con recursos ya existentes). `helm install --dry-run` sí se comunica con el API server (por ejemplo, para validaciones del lado del servidor) pero no persiste ningún objeto ni crea un release.
2. `helm template`, porque permite revisar el manifest generado completamente offline antes de decidir si se aplica.

</details>

---

**Fuentes de referencia:**
- CNCF, *CKAD Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Helm, *Using Helm*: https://helm.sh/docs/intro/using_helm/
- Helm, *Quickstart Guide*: https://helm.sh/docs/intro/quickstart/
- Helm, *Helm Commands Reference*: https://helm.sh/docs/helm/helm/
- Artifact Hub: https://artifacthub.io/