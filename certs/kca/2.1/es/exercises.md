# Instalación y Configuración basadas en Helm — Ejercicios Guiados

> **Topic 2.1 · KCA · Peso en el examen: 3.0**
> Estos labs asumen un cluster de Kubernetes en funcionamiento (`kubectl` configurado contra un contexto que puedas modificar libremente — `kind`, `minikube`, o un namespace descartable en un cluster compartido) y Helm **v3.x**. Helm v3 es solo cliente: no hay Tiller, y el estado de los releases vive en objetos `Secret` de Kubernetes en el namespace del release.
> Todos los comandos son reales. Donde un flag `-o` o un pin de versión cambiaría la salida, se indica. Ajustá las versiones de los charts a lo que tus repositorios sirvan realmente — fijar `--version` es el hábito de producción y es obligatorio para la reproducibilidad.

---

## Ejercicio 1 — Instalar Helm y conectar un repositorio

**Objetivo:** conseguir un cliente funcionando, entender dónde vive su configuración, y agregar/consultar un repositorio de charts.

1. Instalá el cliente (se muestra el método por script; un gestor de paquetes o un binario fijado a una versión son igualmente válidos en producción):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   ```

2. Confirmá la versión y que se comunica con tu cluster:

   ```bash
   helm version --short
   # v3.15.2+g...
   kubectl config current-context
   ```

3. Inspeccioná dónde guarda Helm su propio estado. Estas son rutas XDG, no objetos de Kubernetes:

   ```bash
   helm env | grep -E 'HELM_(REPOSITORY|CACHE|DATA|CONFIG)'
   # HELM_CACHE_HOME="/home/user/.cache/helm"
   # HELM_CONFIG_HOME="/home/user/.config/helm"
   # HELM_DATA_HOME="/home/user/.local/share/helm"
   # HELM_REPOSITORY_CONFIG="/home/user/.config/helm/repositories.yaml"
   ```

4. Agregá un repositorio y refrescá el índice local:

   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm repo update
   ```

5. Buscá en el índice del repositorio y luego en el hub público de Helm (Artifact Hub):

   ```bash
   helm search repo bitnami/nginx --versions | head
   helm search hub wordpress --max-col-width=60 | head
   ```

**Verificá tu comprensión:**
- **1a.** Helm v3 eliminó un componente del lado del servidor que Helm v2 requería. ¿Cómo se llamaba, y dónde vive ahora el estado de los releases?
- **1b.** `helm search repo` y `helm search hub` consultan dos fuentes de datos diferentes. ¿Cuál funciona offline, y por qué?
- **1c.** Después de `helm repo add`, un compañero de equipo publica una nueva versión de un chart pero tu `helm search repo` no la muestra. ¿Qué único comando lo soluciona, y qué descarga realmente?

---

## Ejercicio 2 — Instalar un release e inspeccionarlo

**Objetivo:** crear un release, entender el modelo release/namespace/revisión, y leer el estado en vivo sin `kubectl`.

1. Creá un namespace dedicado e instalá un chart en él. Fijá la versión del chart y nombrá el release explícitamente:

   ```bash
   kubectl create namespace demo
   helm install web bitnami/nginx --version 18.1.0 --namespace demo
   ```

   Cola esperada de la salida:

   ```
   NAME: web
   LAST DEPLOYED: ...
   NAMESPACE: demo
   STATUS: deployed
   REVISION: 1
   ```

2. Listá los releases — primero en el namespace, luego en todos los namespaces:

   ```bash
   helm list --namespace demo
   helm list --all-namespaces
   ```

3. Leé el release sin tocar `kubectl`:

   ```bash
   helm status web --namespace demo
   helm get values web --namespace demo          # user-supplied values (empty here)
   helm get values web --namespace demo --all    # user + computed defaults
   helm get manifest web --namespace demo | head -40
   ```

4. Comprobá dónde almacena Helm su estado. Es un `Secret` de Kubernetes, base64 de gzip de JSON:

   ```bash
   kubectl get secret --namespace demo -l owner=helm
   # NAME                          TYPE                 DATA
   # sh.helm.release.v1.web.v1     helm.sh/release.v1   1
   ```

**Verificá tu comprensión:**
- **2a.** El nombre de un release debe ser único dentro de un ámbito. ¿Cuál es ese ámbito — el cluster, o el namespace? ¿Qué te permite hacer esto que Helm v2 no podía?
- **2b.** ¿Cuál es la diferencia entre `helm get values web` y `helm get values web --all`? ¿Cuál commitearías a Git como tu "fuente de verdad" para un release?
- **2c.** Borrás a mano el Secret `sh.helm.release.v1.web.v1` pero dejás el Deployment corriendo. ¿Qué se rompe de `helm upgrade`/`helm rollback` después, y por qué?

---

## Ejercicio 3 — Configurar un release con values

**Objetivo:** sobrescribir los defaults del chart de tres formas (`--set`, `--set-string`, `-f`), y entender la precedencia.

1. Inspeccioná la superficie configurable del chart antes de sobrescribir nada:

   ```bash
   helm show values bitnami/nginx --version 18.1.0 | grep -A3 -E '^(replicaCount|service):'
   ```

2. Instalá un *segundo* release en un nuevo namespace usando un archivo de values. Escribilo primero:

   ```bash
   cat > /tmp/web-values.yaml <<'EOF'
   replicaCount: 3
   service:
     type: ClusterIP
   commonLabels:
     team: platform
   EOF

   kubectl create namespace staging
   helm install web bitnami/nginx --version 18.1.0 \
     --namespace staging \
     -f /tmp/web-values.yaml
   ```

3. Sobrescribí un único value por encima del archivo en el momento de la instalación. Los flags `--set` posteriores ganan sobre los archivos `-f`:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging \
     -f /tmp/web-values.yaml \
     --set replicaCount=5
   ```

4. Observá la trampa de la coerción de tipos. `--set` interpreta `true`, `123`, `null` como escalares tipados; `--set-string` fuerza un string:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 --namespace staging \
     --reuse-values --set-string podAnnotations.build=00123 --dry-run=server \
     | grep -A2 annotations
   # build: "00123"   <-- leading zero preserved; --set would have made it 123
   ```

5. Confirmá qué tuvo efecto realmente:

   ```bash
   helm get values web --namespace staging
   # replicaCount: 5
   # service:
   #   type: ClusterIP
   ```

**Verificá tu comprensión:**
- **3a.** Pasás `-f base.yaml -f override.yaml --set image.tag=1.2` en un solo comando. Enunciá el orden de precedencia de menor a mayor.
- **3b.** ¿Cuál es la diferencia entre `--reuse-values` y `--reset-values` en un upgrade? ¿Cuál es el *default* cuando pasás `--set` pero ningún `-f`, y por qué sorprende a la gente?
- **3c.** ¿Por qué recurrirías a `--set-string` para fijar una versión como `1.10`? ¿Qué sale mal con `--set` a secas?

---

## Ejercicio 4 — Upgrade, rollback, y leer el historial

**Objetivo:** tratar un release como un objeto versionado y reversible.

1. Mirá el historial del release hasta ahora:

   ```bash
   helm history web --namespace staging
   # REVISION  STATUS      CHART        APP VERSION  DESCRIPTION
   # 1         superseded  nginx-18.1.0 ...          Install complete
   # 2         superseded  nginx-18.1.0 ...          Upgrade complete
   # 3         deployed    nginx-18.1.0 ...          Upgrade complete
   ```

2. Realizá un upgrade que cambie un image tag, y esperá a que quede listo. `--atomic` hace rollback automático ante un fallo; `--timeout` acota la espera:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging --reuse-values \
     --set image.tag=1.27.0-debian-12-r0 \
     --atomic --timeout 3m
   ```

3. Provocá un upgrade deliberadamente roto para ver cómo `--atomic` te protege. Apuntá a un tag que nunca hará pull:

   ```bash
   helm upgrade web bitnami/nginx --version 18.1.0 \
     --namespace staging --reuse-values \
     --set image.tag=this-tag-does-not-exist \
     --atomic --timeout 90s
   # Error: UPGRADE FAILED: ... ; the release was rolled back
   ```

4. Hacé un rollback manual a una revisión conocida como buena y confirmá que el historial registra el rollback como una *nueva* revisión:

   ```bash
   helm rollback web 4 --namespace staging --wait
   helm history web --namespace staging | tail -3
   ```

**Verificá tu comprensión:**
- **4a.** ¿Un `helm rollback` a la revisión 4 reutiliza el número de revisión 4, o crea uno nuevo? ¿Qué te dice eso sobre cómo Helm modela el historial?
- **4b.** `--atomic` implica otro flag. ¿Cuál, y cuál es el comportamiento ante un fallo de un upgrade *sin* `--atomic`?
- **4c.** Helm mantiene por default un número acotado de revisiones históricas. ¿Aproximadamente cuántas, y qué flag en `helm upgrade` lo controla? ¿Por qué un historial ilimitado perjudica en un release con mucha actividad?

---

## Ejercicio 5 — Escribir tu propio chart

**Objetivo:** scaffoldear un chart, entender su anatomía, templatearlo offline, y hacerle lint.

1. Scaffoldeá y leé el árbol:

   ```bash
   helm create mychart
   find mychart -maxdepth 2 -type f | sort
   # mychart/Chart.yaml
   # mychart/values.yaml
   # mychart/.helmignore
   # mychart/templates/deployment.yaml
   # mychart/templates/service.yaml
   # mychart/templates/_helpers.tpl
   # mychart/templates/NOTES.txt
   # ...
   ```

2. Inspeccioná los dos campos de metadata que *no* son lo mismo:

   ```bash
   grep -E '^(version|appVersion):' mychart/Chart.yaml
   # version: 0.1.0       # the chart's own SemVer
   # appVersion: "1.16.0" # the app being deployed — a label, not used for ordering
   ```

3. Renderizá el chart a manifests planos **sin un cluster** y buscá una sustitución de value:

   ```bash
   helm template demo ./mychart --set replicaCount=2 | grep -E 'replicas:|kind:'
   ```

4. Rompé el chart a propósito, luego dejá que `lint` lo detecte. Introducí una indentación inválida en `values.yaml`, corré lint, luego revertí:

   ```bash
   helm lint ./mychart
   # ==> Linting ./mychart
   # 1 chart(s) linted, 0 chart(s) failed
   ```

5. Empaquetá el chart en un artefacto versionado y distribuible:

   ```bash
   helm package ./mychart
   # Successfully packaged chart and saved it to: mychart-0.1.0.tgz
   ```

**Verificá tu comprensión:**
- **5a.** `Chart.yaml` tiene tanto `version` como `appVersion`. Explicá el significado distinto de cada uno y cuál usa Helm realmente para ordenar los upgrades.
- **5b.** `helm template` y `helm install --dry-run` ambos renderizan manifests. Nombrá una cosa que `--dry-run=server` hace que `helm template` no puede.
- **5c.** ¿Qué contiene `_helpers.tpl`, y por qué su nombre de archivo lleva un prefijo de guion bajo? (Pista: pensá en qué trata Helm como un manifest renderizado vs. un partial.)

---

## Ejercicio 6 — Dependencias y subcharts

**Objetivo:** componer un chart a partir de otros y entender la propagación de values y las condiciones.

1. Declará una dependencia en `Chart.yaml`. Agregá un subchart de base de datos, condicionado por un `condition`:

   ```yaml
   # append to mychart/Chart.yaml
   dependencies:
     - name: postgresql
       version: "15.5.38"
       repository: https://charts.bitnami.com/bitnami
       condition: postgresql.enabled
   ```

2. Resolvé y bloqueá la dependencia. Esto escribe `Chart.lock` y baja el tarball a `charts/`:

   ```bash
   helm dependency update ./mychart
   ls mychart/charts
   # postgresql-15.5.38.tgz
   cat mychart/Chart.lock
   ```

3. Habilitá y configurá el subchart desde el `values.yaml` del padre. Los values de un subchart anidan bajo su nombre:

   ```yaml
   # mychart/values.yaml
   postgresql:
     enabled: true
     auth:
       database: appdb
   ```

4. Renderizá y confirmá que los objetos del subchart aparecen (o desaparecen cuando está deshabilitado):

   ```bash
   helm template demo ./mychart | grep -c 'kind: StatefulSet'   # 1 (postgresql)
   helm template demo ./mychart --set postgresql.enabled=false | grep -c 'kind: StatefulSet'  # 0
   ```

**Verificá tu comprensión:**
- **6a.** Para fijar `auth.database` en el subchart `postgresql` desde el chart padre, ¿bajo qué clave de nivel superior debe vivir el value? Escribí la ruta YAML exacta.
- **6b.** ¿Cuál es el propósito de `Chart.lock`, y por qué debería commitearse al control de versiones? ¿Qué comando lo regenera?
- **6c.** `condition` vs `tags` en una entrada de dependencia — ¿qué controla cada uno, y cuál gana si ambos están fijados?

---

## Ejercicio 7 — Templating, dry-run, y debuggear un render defectuoso

**Objetivo:** debuggear la lógica de templates como lo harías bajo la presión de tiempo del examen — offline, rápido, con los objetos built-in.

1. Agregá un template que use los objetos built-in `Release` y `Values`. Creá `mychart/templates/configmap.yaml`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: {{ include "mychart.fullname" . }}-info
   data:
     release:   {{ .Release.Name | quote }}
     namespace: {{ .Release.Namespace | quote }}
     replicas:  {{ .Values.replicaCount | default 1 | quote }}
   ```

2. Renderizá solo ese comportamiento y leé los values que entraron:

   ```bash
   helm template demo ./mychart --show-only templates/configmap.yaml \
     --namespace prod --set replicaCount=4
   ```

   Esperado:

   ```yaml
   data:
     release: "demo"
     namespace: "prod"
     replicas: "4"
   ```

3. Introducí un error de template (referenciar una clave faltante con `required`) y leé el diagnóstico de Helm:

   ```bash
   helm template demo ./mychart \
     --set-string image.repository= \
     --set 'image.tag=null' 2>&1 | tail -5
   ```

4. Usá `--debug` con un dry-run del servidor para ver el manifest completamente computado más los values que Helm fusionó:

   ```bash
   helm install demo ./mychart --namespace demo --dry-run=server --debug 2>&1 | head -30
   ```

**Verificá tu comprensión:**
- **7a.** Nombrá tres objetos built-in disponibles dentro de un template y un dato que cada uno expone. ¿Cuál *no* se conoce en el momento de `helm template` pero *sí* se conoce en el momento de `--dry-run=server`?
- **7b.** ¿Qué hace la función `required "msg" .Values.x` que un `{{ .Values.x }}` a secas no hace? ¿Cuándo preferirías `default`?
- **7c.** `--show-only templates/configmap.yaml` acota el render. ¿Por qué es el bucle de debugging más rápido para un único manifest roto, y por qué *no* necesita un cluster?

---

## Ejercicio 8 — Distribuir un chart vía un registry OCI

**Objetivo:** publicar y consumir un chart de la forma moderna — sin `index.yaml`, solo un registry OCI.

1. Iniciá sesión en un registry compatible con OCI (cualquiera sirve; un `zot`/`registry:2` local está bien para el lab):

   ```bash
   helm registry login registry.example.com --username "$USER"
   ```

2. Pusheá el chart empaquetado del Ejercicio 5. Notá el esquema `oci://` y que el *nombre* del chart está implícito, no es parte de la URL:

   ```bash
   helm push mychart-0.1.0.tgz oci://registry.example.com/charts
   # Pushed: registry.example.com/charts/mychart:0.1.0
   # Digest: sha256:...
   ```

3. Instalá directamente desde el registry — no existe un paso `helm repo add` para OCI:

   ```bash
   helm install demo oci://registry.example.com/charts/mychart \
     --version 0.1.0 --namespace demo
   ```

4. Inspeccioná la metadata del chart remoto sin instalar:

   ```bash
   helm show chart oci://registry.example.com/charts/mychart --version 0.1.0
   ```

**Verificá tu comprensión:**
- **8a.** Los repos de charts HTTP tradicionales dependen de un archivo que los registries OCI no usan. Nombrá ese archivo y explicá qué reemplaza su rol en OCI.
- **8b.** Para un chart `oci://`, `helm repo add` no es ni necesario ni válido. ¿Cuál es el equivalente OCI de "agregar" una fuente antes de poder hacer pull desde un registry privado?
- **8c.** En la referencia `oci://registry.example.com/charts/mychart`, ¿qué parte es el nombre del chart y cuál es la ruta de "repository/namespace"? ¿De dónde sale la *versión* del chart?

---

## Limpieza

```bash
helm uninstall web --namespace demo
helm uninstall web --namespace staging
helm uninstall demo --namespace demo
kubectl delete namespace demo staging
```

`helm uninstall` borra los objetos de Kubernetes del release y su Secret de historial. Agregá `--keep-history` para retener el registro de modo que un `helm rollback` de un release desinstalado siga siendo posible.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1a.** El componente eliminado era **Tiller**, el servidor in-cluster de Helm v2. Helm v3 es un cliente puro; el estado del release se almacena como objetos `Secret` de Kubernetes (tipo `helm.sh/release.v1`) en el namespace propio del release — base64 de gzip del JSON del release. Esto eliminó los privilegios cluster-wide de Tiller e hizo que Helm honre el RBAC normal.
- **1b.** `helm search repo` funciona **offline** — consulta los archivos `index.yaml` cacheados localmente que descargaron `helm repo add`/`update`, almacenados bajo `HELM_CACHE_HOME`. `helm search hub` consulta **Artifact Hub por la red** y necesita conectividad.
- **1c.** `helm repo update`. Re-descarga el `index.yaml` de cada repositorio configurado al cache local; **no** descarga ningún archivo de charts — solo el índice de charts y versiones disponibles.

### Ejercicio 2
- **2a.** El ámbito de unicidad es el **namespace**. Dos releases llamados `web` pueden coexistir en namespaces diferentes. Los nombres de Helm v2 eran **globales al cluster**, así que este scoping por namespace es nuevo en v3 y es lo que te permite instalar el mismo chart bajo el mismo nombre de release en `demo` y `staging`.
- **2b.** `helm get values web` muestra solo las sobrescrituras **provistas por el usuario** (lo que pasaste con `-f`/`--set`); `--all` fusiona esas por encima de los defaults computados del chart, mostrando el conjunto de values **efectivo completo**. Commiteá el conjunto **provisto por el usuario** (idealmente el propio archivo `-f`) como fuente de verdad — la salida de `--all` incluye defaults que cambian con la versión del chart y derivarían.
- **2c.** El historial y el estado actual de Helm viven en ese Secret. Borrarlo hace que Helm crea que el release no existe: `helm upgrade` se negará (o intentará una instalación nueva y colisionará con los objetos existentes), y `helm rollback` no tiene revisiones a las cuales volver. El Deployment en vivo queda ahora **huérfano** desde el punto de vista de Helm.

### Ejercicio 3
- **3a.** De menor → mayor: **defaults de `values.yaml` del chart → merges de subchart/padre → cada archivo `-f` en el orden dado (los archivos posteriores ganan) → flags `--set`/`--set-string`/`--set-file`**. Así que `--set image.tag=1.2` le gana a ambos archivos, y `override.yaml` le gana a `base.yaml`.
- **3b.** `--reuse-values` arrastra los values de la revisión anterior y superpone los nuevos `--set`/`-f` encima; `--reset-values` descarta las sobrescrituras previas y parte de los defaults del chart más lo que pases ahora. La sorpresa: cuando pasás **solo `--set` y ningún `-f`**, Helm históricamente tiende por default a reutilizar los values previos para esa ruta, así que la gente espera una pizarra limpia y obtiene un merge. Sé explícito con `--reuse-values`/`--reset-values` para evitar la ambigüedad.
- **3c.** Coerción de tipos de YAML/Go. `--set image.tag=1.10` a secas puede ser parseado como el **número** `1.1` (el cero final se descarta) o retipeado de otra forma; `--set-string` fuerza el string literal `"1.10"`. El mismo razonamiento protege valores con ceros de relleno como `00123`.

### Ejercicio 4
- **4a.** Crea una **nueva revisión** (aquí la revisión 5) cuyo contenido es igual al de la revisión 4. El historial es **append-only** — Helm nunca reescribe ni reutiliza un número de revisión pasado; un rollback es simplemente otro cambio registrado.
- **4b.** `--atomic` implica **`--wait`**. Sin `--atomic`, un upgrade fallido deja el release en estado **`failed`** con cambios parcialmente aplicados y **no** hace rollback automático — tenés que hacer el rollback manualmente.
- **4c.** El historial retenido por default es de **10** revisiones (`--history-max` en `helm upgrade`, env `HELM_MAX_HISTORY`). Un historial ilimitado significa un Secret grande por revisión acumulándose en el namespace, inflando etcd y ralentizando cada operación de Helm sobre ese release.

### Ejercicio 5
- **5a.** `version` es el **SemVer propio del chart** y es el campo que Helm usa para ordenar y seleccionar versiones de chart (`--version`, resolución de dependencias, ordenamiento de upgrades). `appVersion` es una etiqueta de formato libre que describe la **aplicación** enviada dentro (por ej. la versión de nginx) y no tiene efecto en el ordenamiento.
- **5b.** `--dry-run=server` envía los manifests renderizados al API server para **validación/admission** (chequeos de schema, defaulting, admission webhooks) y puede resolver datos **conocidos por el cluster**; `helm template` renderiza puramente del lado del cliente y no sabe nada del cluster de destino, así que no puede validar contra él.
- **5c.** `_helpers.tpl` contiene **partials de templates nombrados** (`define`/`template`/`include`) — snippets reutilizables como bloques de labels y el helper `fullname`. El prefijo de guion bajo le dice a Helm que el archivo **no** es un manifest instalable: los archivos que empiezan con `_` (y `NOTES.txt`) quedan excluidos del conjunto de objetos aplicados al cluster.

### Ejercicio 6
- **6a.** Bajo el nombre del subchart como clave de nivel superior en los values del padre:
  ```yaml
  postgresql:
    auth:
      database: appdb
  ```
- **6b.** `Chart.lock` fija las **versiones y digests resueltos exactos** de cada dependencia, de modo que `helm dependency build` reproduce el contenido idéntico de `charts/` en cualquier lado. Commiteálo para builds reproducibles. `helm dependency update` lo regenera (re-resolviendo contra los repositorios); `helm dependency build` instala estrictamente lo que el lock ya nombra.
- **6c.** `condition` es una **ruta a un value booleano** (por ej. `postgresql.enabled`) que enciende/apaga una única dependencia. `tags` agrupan varias dependencias bajo switches nombrados que se conmutan juntos. Si ambos están presentes, un **`condition` fijado explícitamente gana** sobre los tags para esa dependencia.

### Ejercicio 7
- **7a.** Ejemplos: `.Release` (`.Name`, `.Namespace`, `.Revision`, `.IsUpgrade`/`.IsInstall`), `.Chart` (`.Name`, `.Version`, `.AppVersion`), `.Values` (values fusionados usuario+default), `.Capabilities` (`.KubeVersion`, grupos de API disponibles), `.Files` (archivos no-template en el chart). **`.Capabilities`** (la versión real del cluster y su conjunto de APIs) es desconocido para `helm template` a menos que lo falsees con `--api-versions`/`--kube-version`, pero se puebla de verdad con `--dry-run=server`.
- **7b.** `required "msg" .Values.x` **falla el render con tu mensaje** si `x` está vacío/ausente, convirtiendo una mala configuración silenciosa en un error duro y explicativo. Preferí `default` cuando un value faltante tiene un **fallback seguro** y el deployment debería proceder igual.
- **7c.** `--show-only` renderiza el **chart entero** (así que las referencias cruzadas y los helpers siguen resolviéndose) pero imprime **solo el archivo nombrado**, dando un bucle ajustado de editar-renderizar-leer para un manifest. Corre enteramente del lado del cliente — no se contacta ningún API server — así que funciona sin cluster y sin credenciales.

### Ejercicio 8
- **8a.** Los repos HTTP dependen de **`index.yaml`**, un catálogo de cada chart/versión en ese repo. Los registries OCI **no tienen índice**; el descubrimiento usa la propia API de tags/manifests del registry (cada chart es un artefacto OCI direccionado por `name:tag` y digest de contenido), así que no hay nada que re-descargar periódicamente.
- **8b.** `helm registry login <registry>` (y `helm registry logout`). La autenticación es por registry vía el login OCI, reutilizando credenciales estilo Docker — no hay paso de `repo add`/`index.yaml` para fuentes `oci://`.
- **8c.** En `oci://registry.example.com/charts/mychart`: `registry.example.com/charts` es el **host del registry + ruta de repository/namespace**, `mychart` es el **nombre del chart**, y la **versión no está en la URL** — viene de `--version` (o del tag del artefacto), por ej. `--version 0.1.0` resolviendo al artefacto `mychart:0.1.0`.

</details>

---

**Sources (official):**
- Helm documentation — Using Helm: https://helm.sh/docs/intro/using_helm/
- Helm — Charts guide (structure, dependencies, `Chart.yaml`): https://helm.sh/docs/topics/charts/
- Helm — Values files and precedence: https://helm.sh/docs/chart_template_guide/values_files/
- Helm — Built-in Objects: https://helm.sh/docs/chart_template_guide/builtin_objects/
- Helm — OCI-based registries: https://helm.sh/docs/topics/registries/
- Helm CLI reference (`helm install`, `upgrade`, `rollback`, `history`, `template`, `dependency`): https://helm.sh/docs/helm/
- KCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf