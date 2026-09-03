# 703.3 Gestión de Paquetes en Kubernetes — Ejercicios Guiados

**LPI DevOps Tools Engineer · Examen 701-100 · Versión 2.0.0 · Peso 3.33**

> Objetivos oficiales: <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estos ejercicios son prácticos. Tecleás cada comando, leés cada salida, y después de cada bloque respondés las preguntas de verificación antes de seguir. Las respuestas están plegadas al final — resistí la tentación de abrirlas antes de tiempo; la idea es predecir el comportamiento y después confirmarlo.

Todo corre contra un clúster local descartable. Nada de esto necesita una cuenta en la nube, y nada cuesta dinero.

---

## Lab 0 — Entorno

### Pasos

1. Creá un clúster desechable y confirmá que el plano de control responde:

```bash
$ kind create cluster --name lpi703 --image kindest/node:v1.32.0
Creating cluster "lpi703" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-lpi703"

$ kubectl get nodes
NAME                    STATUS   ROLES           AGE   VERSION
lpi703-control-plane    Ready    control-plane   41s   v1.32.0
```

2. Confirmá la versión del cliente Helm. Todo lo de abajo funciona en Helm **3.14 o posterior**; los flags que necesitan un mínimo específico están marcados en línea.

```bash
$ helm version
version.BuildInfo{Version:"v3.17.1", GitCommit:"980d8ac1939e39138101364400756af2bdee1da5", GitTreeState:"clean", GoVersion:"go1.23.6"}
```

3. Creá un directorio de trabajo y un namespace para los labs:

```bash
$ mkdir -p ~/lpi703 && cd ~/lpi703
$ kubectl create namespace pkg
namespace/pkg created
```

4. Notá que Helm 3 **no tiene componente del lado del clúster**. Probalo:

```bash
$ kubectl get pods -A | grep -i tiller
$ echo $?
1
```

### Preguntas de verificación

- **Q1.** Helm 2 requería `tiller`, un Deployment corriendo en `kube-system` con RBAC amplio. Helm 3 lo eliminó. ¿De dónde viene ahora la *autorización* para `helm install`, y qué consecuencia práctica de seguridad tiene eso en un clúster multi-tenant?
- **Q2.** `helm version` reporta solamente una versión de cliente. ¿Qué determina si un chart que instalás va a funcionar realmente sobre la superficie de API de este clúster, y qué dos mecanismos le permiten al autor de un chart expresar ese requisito?

---

## Ejercicio 1 — Anatomía de un chart: qué es realmente un "paquete"

### Pasos

1. Andamiá un chart e inspeccioná la estructura:

```bash
$ helm create web
Creating web

$ find web -type f | sort
web/.helmignore
web/Chart.yaml
web/charts/.gitkeep          # empty in a fresh scaffold
web/templates/NOTES.txt
web/templates/_helpers.tpl
web/templates/deployment.yaml
web/templates/hpa.yaml
web/templates/ingress.yaml
web/templates/service.yaml
web/templates/serviceaccount.yaml
web/templates/tests/test-connection.yaml
web/values.yaml
```

2. Leé los metadatos del chart:

```bash
$ cat web/Chart.yaml
apiVersion: v2
name: web
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
appVersion: "1.16.0"
```

3. Editá `web/Chart.yaml` para que los dos campos de versión cuenten historias distintas, y agregá una restricción de Kubernetes:

```yaml
apiVersion: v2
name: web
description: Production reference web tier for LPI 703.3
type: application
version: 0.2.0          # the chart's own SemVer — bumped on every chart change
appVersion: "1.27.2"    # the version of the software being deployed
kubeVersion: ">=1.28.0-0"
maintainers:
  - name: platform-team
    email: platform@example.com
```

4. Pedile a Helm que te muestre lo que vería un consumidor sin instalar nada:

```bash
$ helm show chart ./web
apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
kubeVersion: '>=1.28.0-0'
...

$ helm show values ./web | head -20
replicaCount: 1

image:
  repository: nginx
  pullPolicy: IfNotPresent
  # Overrides the image tag whose default is the chart appVersion.
  tag: ""
...
```

5. Creá un chart que deliberadamente no se puede instalar y observá la falla:

```bash
$ helm create common && sed -i 's/^type: application/type: library/' common/Chart.yaml
$ rm common/templates/*.yaml common/templates/NOTES.txt
$ helm install c ./common -n pkg
Error: INSTALLATION FAILED: library charts are not installable
```

### Preguntas de verificación

- **Q3.** Un colega sube `appVersion` de `1.27.2` a `1.27.3` y publica el chart en el repositorio sin tocar `version`. Los consumidores que corren `helm repo update && helm upgrade` no ven ningún cambio. ¿Por qué? ¿Cuál campo es la versión del *paquete* en términos de SemVer?
- **Q4.** `apiVersion: v2` en `Chart.yaml` no es la versión de API de Kubernetes. ¿Qué selecciona, y qué usaba el chart equivalente con `apiVersion: v1` en lugar del bloque `dependencies:`?
- **Q5.** ¿Para qué sirve un chart `type: library`, dado que no se puede instalar? Nombrá el mecanismo que usa un chart consumidor para extraer plantillas de él.
- **Q6.** El `values.yaml` del andamio trae `image.tag: ""`. Mirá el Deployment renderizado en el próximo ejercicio y explicá qué valor termina en la referencia de imagen — y por qué un default vacío es más seguro que fijar `latest`.

---

## Ejercicio 2 — Renderizá antes de instalar: `template`, `lint`, `--dry-run`

### Pasos

1. Renderizá el chart enteramente del lado del cliente y leé el resultado:

```bash
$ helm template web ./web --namespace pkg | head -30
---
# Source: web/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  labels:
    helm.sh/chart: web-0.2.0
    app.kubernetes.io/name: web
    app.kubernetes.io/instance: web
    app.kubernetes.io/version: "1.27.2"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: web/templates/service.yaml
apiVersion: v1
kind: Service
...
```

2. Restringí la salida a una sola plantilla — indispensable en charts que renderizan 40 objetos:

```bash
$ helm template web ./web --show-only templates/deployment.yaml \
    --set replicaCount=3 --set image.tag=1.27.2-alpine | grep -E 'replicas|image:'
  replicas: 3
          image: "nginx:1.27.2-alpine"
```

3. Pasale el linter:

```bash
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

4. Rompé una plantilla a propósito y volvé a pasar el linter:

```bash
$ sed -i 's/{{- if .Values.autoscaling.enabled }}/{{- if .Values.autoscaling.enabld }}/' web/templates/hpa.yaml
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

5. Esa es la trampa. Restaurá el archivo y en cambio rompé la *forma del YAML*:

```bash
$ sed -i 's/{{- if .Values.autoscaling.enabld }}/{{- if .Values.autoscaling.enabled }}/' web/templates/hpa.yaml
$ cat >> web/templates/service.yaml <<'EOF'
  badIndent: true
EOF
$ helm lint ./web
==> Linting ./web
[INFO] Chart.yaml: icon is recommended
[ERROR] templates/: error validating "": error validating data: ValidationError(Service): unknown field "badIndent" in io.k8s.api.core.v1.Service

Error: 1 chart(s) linted, 1 chart(s) failed
```

6. Deshacé eso, y después compará los tres modos de "no lo instales de verdad":

```bash
$ sed -i '/badIndent/d' web/templates/service.yaml

# (a) pure client-side render, no cluster contact at all
$ helm template web ./web >/dev/null && echo "no API server needed"
no API server needed

# (b) client dry-run: contacts the cluster for capabilities + name collision
$ helm install web ./web -n pkg --dry-run | head -6
NAME: web
LAST DEPLOYED: Thu Sep  3 10:14:22 2026
NAMESPACE: pkg
STATUS: pending-install
REVISION: 1
NOTES:

# (c) server dry-run: the API server validates and admission runs (Helm 3.13+)
$ helm install web ./web -n pkg --dry-run=server >/dev/null && echo "server accepted the objects"
server accepted the objects
```

7. Mostrá cómo se ve un objeto renderizado-pero-inválido cuando solo el servidor puede detectarlo:

```bash
$ helm template web ./web --set resources.limits.memory=128 | grep -A3 resources:
$ helm install web ./web -n pkg --dry-run=server --set 'resources.limits.memory=128'
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest: error validating "": error validating data: ValidationError(Deployment.spec.template.spec.containers[0].resources.limits.memory): invalid type for io.k8s.apimachinery.pkg.api.resource.Quantity: got "integer", expected "string"
```

### Preguntas de verificación

- **Q7.** El paso 4 muestra a `helm lint` reportando éxito sobre un chart con una referencia a un valor mal escrita (`.Values.autoscaling.enabld`). Explicá con precisión por qué el linter es ciego a eso, y nombrá la opción de plantillas de Go que convertiría ese silencio en un error.
- **Q8.** Ordená `helm template`, `helm install --dry-run` y `helm install --dry-run=server` según cuánto pueden probar sobre un chart. Para cada uno, nombrá una clase de defecto que detecta y que el más débil no.
- **Q9.** Dentro de `helm template`, ¿a qué evalúan `.Capabilities.APIVersions` y `.Release.IsUpgrade`, y qué modo de falla en CI genera eso para un chart que renderiza un `PodDisruptionBudget` solo cuando `.Capabilities.APIVersions.Has "policy/v1"`?
- **Q10.** Tenés un chart con 60 plantillas y solo necesitás mirar el CronJob. Dá el flag exacto, y explicá qué pasa si el archivo que nombrás no renderiza nada.

---

## Ejercicio 3 — Ciclo de vida del release y dónde guarda Helm su estado

### Pasos

1. Instalá de verdad, esperando a que esté listo:

```bash
$ helm install web ./web -n pkg --create-namespace --wait --timeout 2m
NAME: web
LAST DEPLOYED: Thu Sep  3 10:19:41 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 1
NOTES:
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace pkg -l "app.kubernetes.io/name=web,app.kubernetes.io/instance=web" -o jsonpath="{.items[0].metadata.name}")
  ...

$ helm list -n pkg
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        1         2026-09-03 10:19:41.118203 -03:00 -03   deployed  web-0.2.0  1.27.2
```

2. Encontrá el estado del release. No es un archivo en tu laptop:

```bash
$ kubectl get secret -n pkg -l owner=helm
NAME                        TYPE                 DATA   AGE
sh.helm.release.v1.web.v1   helm.sh/release.v1   1      38s

$ kubectl get secret -n pkg sh.helm.release.v1.web.v1 -o jsonpath='{.metadata.labels}' | tr ',' '\n'
{"modifiedAt":"1788440381"
"name":"web"
"owner":"helm"
"status":"deployed"
"version":"1"}
```

3. Decodificalo. La carga útil es base64 → gzip → JSON, envuelta en el propio base64 del Secret:

```bash
$ kubectl get secret -n pkg sh.helm.release.v1.web.v1 -o jsonpath='{.data.release}' \
  | base64 -d | base64 -d | gunzip | jq '{name, version, info: .info.status, chart: .chart.metadata.version, config}'
{
  "name": "web",
  "version": 1,
  "info": "deployed",
  "chart": "0.2.0",
  "config": null
}
```

4. Actualizá dos veces, para tener historial con el que trabajar:

```bash
$ helm upgrade web ./web -n pkg --set replicaCount=3 --wait
Release "web" has been upgraded. Happy Helming!
NAME: web
LAST DEPLOYED: Thu Sep  3 10:22:03 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 2

$ helm upgrade web ./web -n pkg --set replicaCount=3 --set image.tag=1.29.9-does-not-exist \
    --wait --timeout 45s
Error: UPGRADE FAILED: context deadline exceeded

$ helm history web -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 10:19:41 2026  superseded  web-0.2.0  1.27.2       Install complete
2         Thu Sep  3 10:22:03 2026  deployed    web-0.2.0  1.27.2       Upgrade complete
3         Thu Sep  3 10:23:30 2026  failed      web-0.2.0  1.27.2       Upgrade "web" failed: context deadline exceeded
```

5. Mirá el destrozo que dejó el upgrade fallido:

```bash
$ kubectl get pods -n pkg
NAME                   READY   STATUS             RESTARTS   AGE
web-6d4bcbb7c5-2zqkl   1/1     Running            0          3m
web-6d4bcbb7c5-9wgtn   1/1     Running            0          3m
web-6d4bcbb7c5-hz4rv   1/1     Running            0          3m
web-7f9c98d4b8-tp7xk   0/1     ImagePullBackOff   0          70s
```

6. Hacé rollback y confirmá que el puntero del release avanza, nunca retrocede:

```bash
$ helm rollback web 2 -n pkg --wait
Rollback was a success! Happy Helming!

$ helm history web -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 10:19:41 2026  superseded  web-0.2.0  1.27.2       Install complete
2         Thu Sep  3 10:22:03 2026  superseded  web-0.2.0  1.27.2       Upgrade complete
3         Thu Sep  3 10:23:30 2026  failed      web-0.2.0  1.27.2       Upgrade "web" failed: context deadline exceeded
4         Thu Sep  3 10:25:12 2026  deployed    web-0.2.0  1.27.2       Rollback to 2
```

7. Repetí el upgrade malo como debería hacerlo un pipeline:

```bash
$ helm upgrade web ./web -n pkg --set image.tag=1.29.9-does-not-exist \
    --atomic --wait --timeout 45s
Error: UPGRADE FAILED: context deadline exceeded
Error: release web failed, and has been rolled back due to atomic being set

$ helm list -n pkg
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        6         2026-09-03 10:27:05.442901 -03:00 -03   deployed  web-0.2.0  1.27.2

$ kubectl get pods -n pkg --no-headers | wc -l
3
```

8. Inspeccioná lo que Helm cree que le pertenece:

```bash
$ helm get manifest web -n pkg | grep -c '^kind:'
4
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
replicaCount: 3
$ helm get metadata web -n pkg          # Helm 3.13+
NAME: web
CHART: web
VERSION: 0.2.0
APP_VERSION: 1.27.2
NAMESPACE: pkg
REVISION: 6
STATUS: deployed
DEPLOYED_AT: 2026-09-03T10:27:05-03:00
```

### Preguntas de verificación

- **Q11.** El estado del release vive en Secrets en el namespace del release. Dá dos consecuencias operativas: una para un usuario que tiene `get secrets` en ese namespace, y otra sobre qué pasa con `helm list` si alguien corre `kubectl delete secret -l owner=helm -n pkg` mientras las cargas de trabajo siguen corriendo.
- **Q12.** Después del rollback del paso 6, el historial muestra la revisión 4 como `deployed` y la revisión 2 como `superseded`. ¿Por qué Helm crea una revisión *nueva* en lugar de reactivar la revisión 2, y qué te da eso que una restauración en el lugar no te daría?
- **Q13.** En el paso 4, el upgrade fallido dejó tres Pods viejos sanos y un Pod nuevo roto, y el estado del release fue `failed` — pero nada se deshizo. Contrastá eso con el paso 7. Nombrá el flag, decí exactamente qué implica respecto de `--wait`, y dá una razón por la que un equipo igual podría *no* quererlo en cada upgrade.
- **Q14.** `helm get manifest` y `kubectl get -o yaml` pueden discrepar. Nombrá dos causas distintas de esa divergencia, y decí cuál comando consulta la propia lógica de upgrade de Helm.
- **Q15.** Poné `HELM_DRIVER=configmap` y volvé a correr `helm list -n pkg`. Predecí la salida antes de correrlo, y después explicá la única razón de producción por la que alguien elegiría deliberadamente el driver `secret` sobre `configmap` — y la razón por la que ninguno de los dos alcanza para releases muy grandes.

---

## Ejercicio 4 — Values: precedencia, tipos y validación por esquema

### Pasos

1. Construí una configuración en capas exactamente como lo hace un pipeline real — defaults del chart, después un archivo de entorno, después un override por release, y después un flag:

```bash
$ cat > prod.yaml <<'EOF'
replicaCount: 4
image:
  tag: "1.27.2"
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
EOF

$ cat > canary.yaml <<'EOF'
replicaCount: 1
podAnnotations:
  release-channel: canary
EOF

$ helm upgrade web ./web -n pkg -f prod.yaml -f canary.yaml --set replicaCount=2 --wait
Release "web" has been upgraded. Happy Helming!
```

2. Preguntale a Helm qué valor ganó realmente, y de dónde vino el resto:

```bash
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
image:
  tag: 1.27.2
podAnnotations:
  release-channel: canary
replicaCount: 2
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

$ helm get values web -n pkg --all | grep -A2 serviceAccount
serviceAccount:
  annotations: {}
  automount: true
```

3. Demostrá la trampa de tipos en `--set`:

```bash
$ helm template web ./web --set image.tag=1.27 --show-only templates/deployment.yaml | grep image:
          image: "nginx:1.27"

$ helm template web ./web --set podAnnotations.build=00123 --show-only templates/deployment.yaml | grep -A2 annotations
      annotations:
        build: "123"

$ helm template web ./web --set-string podAnnotations.build=00123 --show-only templates/deployment.yaml | grep -A2 annotations
      annotations:
        build: "00123"
```

4. Demostrá la trampa del *merge* — los mapas se fusionan, las listas se reemplazan:

```bash
$ cat > lists.yaml <<'EOF'
tolerations:
  - key: workload
    operator: Equal
    value: web
    effect: NoSchedule
  - key: zone
    operator: Exists
    effect: NoSchedule
EOF

$ helm template web ./web -f lists.yaml --set 'tolerations[0].key=only-this' \
    --show-only templates/deployment.yaml | grep -A6 tolerations:
      tolerations:
        - effect: NoSchedule
          key: only-this
          operator: Equal
          value: web
        - effect: NoSchedule
          key: zone
          operator: Exists
```

5. Ahora agregá un contrato, para que los valores malos fallen antes de que algo llegue al API server:

```bash
$ cat > web/values.schema.json <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["replicaCount", "image"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 1, "maximum": 10 },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string", "minLength": 1 },
        "tag": { "type": "string" },
        "pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] }
      }
    }
  }
}
EOF

$ helm template web ./web --set replicaCount=40
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- replicaCount: Must be less than or equal to 10

$ helm template web ./web --set image.pullPolicy=ifnotpresent
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- image.pullPolicy: image.pullPolicy must be one of the following: "Always", "IfNotPresent", "Never"

$ helm template web ./web --set image.tag=1.27 >/dev/null
Error: values don't meet the specifications of the schema(s) in the following chart(s):
web:
- image.tag: Invalid type. Expected: string, given: number
```

6. Arreglá la última y confirmá que el esquema ahora pasa:

```bash
$ helm template web ./web --set-string image.tag=1.27 >/dev/null && echo OK
OK
```

7. Examiná cómo tratan los upgrades a los valores provistos previamente:

```bash
$ helm upgrade web ./web -n pkg --set replicaCount=2 --wait >/dev/null
$ helm get values web -n pkg
USER-SUPPLIED VALUES:
replicaCount: 2

$ helm upgrade web ./web -n pkg -f prod.yaml --wait >/dev/null
$ helm upgrade web ./web -n pkg --set podAnnotations.owner=sre --reuse-values --wait >/dev/null
$ helm get values web -n pkg | head -8
USER-SUPPLIED VALUES:
image:
  tag: 1.27.2
podAnnotations:
  owner: sre
replicaCount: 4
```

### Preguntas de verificación

- **Q16.** Escribí el orden completo de precedencia para: el `values.yaml` del chart, un chart padre sobreescribiendo un subchart, `-f a.yaml`, `-f b.yaml`, `--set`, `--set-string`. ¿Cuál de estos *reemplaza* silenciosamente en lugar de fusionar?
- **Q17.** En el paso 3, `--set podAnnotations.build=00123` produjo `"123"`. Explicá las dos conversiones separadas que ocurren — una en el parser de `--set` de Helm y otra cuando el valor se emite al YAML — y nombrá los dos flags que evitan cada una.
- **Q18.** En el paso 4, `--set 'tolerations[0].key=only-this'` no borró la segunda toleration pero sí mutó la primera. Reconciliá eso con "las listas se reemplazan, los mapas se fusionan", y decí qué haría `--set tolerations=null`.
- **Q19.** `values.schema.json` rechazó `replicaCount=40` durante `helm template`, sin ningún clúster involucrado. Listá cada subcomando de Helm que aplica el esquema, y explicá por qué la validación por esquema es estrictamente más fuerte que "el API server lo va a rechazar igual".
- **Q20.** Un pipeline usa `--reuse-values` en cada upgrade. Seis meses después nadie puede explicar por qué un valor eliminado sigue activo. Describí la falla, y nombrá los dos flags (uno clásico, uno agregado en Helm 3.14) que dan un comportamiento determinístico en su lugar.

---

## Ejercicio 5 — Mecánica de plantillas que vas a depurar de verdad

### Pasos

1. Leé las plantillas nombradas del andamio:

```bash
$ sed -n '1,40p' web/templates/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "web.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}
```

2. Agregá un ConfigMap que ejercite los modismos que se rompen en producción — `toYaml`/`nindent`, `required`, `tpl` y `default`:

```bash
$ cat > web/templates/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "web.fullname" . }}-config
  labels:
    {{- include "web.labels" . | nindent 4 }}
data:
  ENVIRONMENT: {{ required "config.environment is mandatory" .Values.config.environment | quote }}
  LOG_LEVEL: {{ .Values.config.logLevel | default "info" | quote }}
  BACKEND_URL: {{ tpl .Values.config.backendUrl . | quote }}
  extra.yaml: |
    {{- toYaml .Values.config.extra | nindent 4 }}
EOF

$ cat >> web/values.yaml <<'EOF'

config:
  environment: ""
  logLevel: ""
  backendUrl: "http://{{ .Release.Name }}-api.{{ .Release.Namespace }}.svc.cluster.local:8080"
  extra:
    timeouts:
      read: 30s
      write: 30s
EOF
```

3. Disparó la guarda, y después satisfacela:

```bash
$ helm template web ./web --show-only templates/configmap.yaml
Error: execution error at (web/templates/configmap.yaml:8:23): config.environment is mandatory

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/configmap.yaml
---
# Source: web/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
  labels:
    helm.sh/chart: web-0.2.0
    app.kubernetes.io/name: web
    app.kubernetes.io/instance: web
    app.kubernetes.io/version: "1.27.2"
    app.kubernetes.io/managed-by: Helm
data:
  ENVIRONMENT: "prod"
  LOG_LEVEL: "info"
  BACKEND_URL: "http://web-api.pkg.svc.cluster.local:8080"
  extra.yaml: |
    timeouts:
      read: 30s
      write: 30s
```

4. Rompé la indentación deliberadamente — el bug de Helm más común de todos:

```bash
$ sed -i 's/toYaml .Values.config.extra | nindent 4/toYaml .Values.config.extra | indent 4/' web/templates/configmap.yaml
$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/configmap.yaml | tail -5
  extra.yaml: |
        timeouts:
      read: 30s
      write: 30s
```

5. Restauralo, y después conectá el ConfigMap al Deployment para que los cambios de configuración realmente reinicien los Pods:

```bash
$ sed -i 's/toYaml .Values.config.extra | indent 4/toYaml .Values.config.extra | nindent 4/' web/templates/configmap.yaml
$ sed -i 's|^      annotations:|      annotations:\n        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . \| sha256sum }}|' web/templates/deployment.yaml

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/deployment.yaml | grep checksum
        checksum/config: 4bd0a2b8b3f2eea8d1f5f0a1b1d5a10d0c2c1b1e2f5a9f8f4a6c2d8e7b3f1a0c

$ helm template web ./web -n pkg --set config.environment=prod --set config.logLevel=debug \
    --show-only templates/deployment.yaml | grep checksum
        checksum/config: 9a2f7d1c4e8b0a3f6c5d2e1b8f7a4c9d0e3b6a1f2c5d8e7b4a9f0c3d6e1b8a2f
```

6. Explorá el renderizado consciente del clúster con `lookup` — el patrón para no regenerar secrets en cada upgrade:

```bash
$ cat > web/templates/secret.yaml <<'EOF'
{{- $name := printf "%s-db" (include "web.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- $pw := "" -}}
{{- if $existing -}}
{{- $pw = index $existing.data "password" | b64dec -}}
{{- else -}}
{{- $pw = randAlphaNum 24 -}}
{{- end }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
type: Opaque
data:
  password: {{ $pw | b64enc | quote }}
EOF

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get secret -n pkg web-db -o jsonpath='{.data.password}' | base64 -d; echo
Xr7kQm2ZpL9vT4bNc8sHwJ1e

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get secret -n pkg web-db -o jsonpath='{.data.password}' | base64 -d; echo
Xr7kQm2ZpL9vT4bNc8sHwJ1e

$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/secret.yaml | grep password
  password: "d0FyMmtMOXBUN3ZOYzhzSHdKMWU="
```

7. Inspeccioná los objetos incorporados disponibles para toda plantilla:

```bash
$ cat > /tmp/builtins.tpl <<'EOF'
{{- printf "release=%s ns=%s isInstall=%v isUpgrade=%v revision=%d" .Release.Name .Release.Namespace .Release.IsInstall .Release.IsUpgrade (int .Release.Revision) }}
{{ printf "kube=%s major=%s minor=%s" .Capabilities.KubeVersion.Version .Capabilities.KubeVersion.Major .Capabilities.KubeVersion.Minor }}
{{ printf "hasAutoscalingV2=%v" (.Capabilities.APIVersions.Has "autoscaling/v2") }}
EOF
$ cp /tmp/builtins.tpl web/templates/zz-debug.yaml
$ helm template web ./web -n pkg --set config.environment=prod --show-only templates/zz-debug.yaml
---
# Source: web/templates/zz-debug.yaml
release=web ns=pkg isInstall=true isUpgrade=false revision=1
kube=v1.32.0 major=1 minor=32
hasAutoscalingV2=true
$ rm web/templates/zz-debug.yaml
```

### Preguntas de verificación

- **Q21.** `include "web.labels" . | nindent 4` aparece por todos lados en el andamio, pero la documentación de Helm también define `template`. Dá la única capacidad que `include` tiene y `template` no, y explicá por qué esa diferencia hace inutilizable a `template` en la línea de arriba.
- **Q22.** El paso 4 produjo YAML donde la primera línea quedó indentada 8 espacios y el resto 4. Explicá la diferencia mecánica entre `indent` y `nindent` que causa exactamente esa forma.
- **Q23.** La anotación `checksum/config` cambió cuando cambió `logLevel`. ¿Qué comportamiento concreto de Kubernetes dispara eso, y qué pasa *sin* la anotación cuando cambiás un ConfigMap montado como volumen versus consumido vía `envFrom`?
- **Q24.** En el paso 6, `helm template` imprimió una contraseña *distinta* de la almacenada en el clúster. Explicá por qué, y describí el accidente de producción que esto causa si un job de CI renderiza manifiestos con `helm template` y los aplica con `kubectl apply`.
- **Q25.** `required` se dispara en tiempo de renderizado; `values.schema.json` se dispara antes del renderizado. Un valor debe ser un string no vacío que cumpla `^[a-z0-9-]+$`. ¿Qué mecanismo elegís, y por qué `required` solo es insuficiente acá?

---

## Ejercicio 6 — Dependencias, condiciones, alias y globals

### Pasos

1. Construí un pequeño chart paraguas sobre dos subcharts locales:

```bash
$ helm create cache >/dev/null
$ mkdir platform && cd platform
$ cat > Chart.yaml <<'EOF'
apiVersion: v2
name: platform
description: Umbrella chart for the LPI 703.3 lab
type: application
version: 1.0.0
appVersion: "2026.09"
dependencies:
  - name: web
    version: "0.2.0"
    repository: "file://../web"
  - name: cache
    version: "0.1.0"
    repository: "file://../cache"
    alias: sessioncache
    condition: sessioncache.enabled
    tags:
      - stateful
EOF
$ mkdir -p templates && cat > values.yaml <<'EOF'
global:
  imageRegistry: registry.example.com
  environment: prod

web:
  replicaCount: 3
  config:
    environment: prod

sessioncache:
  enabled: false
  replicaCount: 1
EOF
```

2. Resolvé las dependencias y leé lo que escribió Helm:

```bash
$ helm dependency update .
Saving 2 charts
Deleting outdated charts

$ ls charts/
cache-0.1.0.tgz  web-0.2.0.tgz

$ cat Chart.lock
dependencies:
- name: web
  repository: file://../web
  version: 0.2.0
- name: cache
  repository: file://../cache
  version: 0.1.0
digest: sha256:4d61b0e3c7a1e4c9f1a7d2b8e5c0f3a6d9b2e8c1f4a7d0b3e6c9f2a5d8b1e4c7
generated: "2026-09-03T10:41:19.884215-03:00"
```

3. Confirmá que la condición funciona, y confirmá la trampa del alias:

```bash
$ helm template plat . -n pkg | grep -c 'kind: Deployment'
1

$ helm template plat . -n pkg --set sessioncache.enabled=true | grep -c 'kind: Deployment'
2

# The trap: the ORIGINAL chart name no longer controls anything
$ helm template plat . -n pkg --set cache.enabled=true | grep -c 'kind: Deployment'
1
```

4. Mostrá que el propio nombre de un subchart sigue gobernando los nombres de sus recursos salvo que se lo sobreescriba:

```bash
$ helm template plat . -n pkg --set sessioncache.enabled=true | grep -E '^  name: plat'
  name: plat-web
  name: plat-cache
```

5. Probá la propagación de valores globales, y probá que los valores ordinarios *no* se propagan:

```bash
$ cat > ../web/templates/zz-globals.yaml <<'EOF'
{{- printf "web sees registry=%v environment=%v topLevel=%v" .Values.global.imageRegistry .Values.global.environment (.Values.someTopLevel | default "<nil>") }}
EOF
$ helm dependency update . >/dev/null
$ helm template plat . -n pkg --set someTopLevel=xyz --show-only charts/web/templates/zz-globals.yaml
---
# Source: platform/charts/web/templates/zz-globals.yaml
web sees registry=registry.example.com environment=prod topLevel=<nil>
```

6. Reproducí una build desde el archivo de lock, como debe hacerlo CI:

```bash
$ rm -rf charts/
$ helm dependency build .
Saving 2 charts
Deleting outdated charts

$ helm dependency list .
NAME    VERSION  REPOSITORY          STATUS
web     0.2.0    file://../web       unpacked
cache   0.1.0    file://../cache     unpacked
```

7. Rompé la reproducibilidad a propósito y mirá cómo `build` se niega:

```bash
$ sed -i 's/version: "0.2.0"/version: "0.3.0"/' Chart.yaml
$ helm dependency build .
Error: the lock file (Chart.lock) is out of sync with the dependencies file (Chart.yaml). Please update the dependencies
$ sed -i 's/version: "0.3.0"/version: "0.2.0"/' Chart.yaml && helm dependency build . >/dev/null
$ rm ../web/templates/zz-globals.yaml && helm dependency update . >/dev/null && cd ..
```

### Preguntas de verificación

- **Q26.** `helm dependency update` y `helm dependency build` ambos pueblan `charts/`. Decí exactamente cuál lee `Chart.lock`, cuál lo escribe, y cuál corresponde en un pipeline de CI — con la razón.
- **Q27.** Con `alias: sessioncache`, `--set cache.enabled=true` no hizo nada. Explicá la regla, y escribí la línea `condition:` que necesitarías si el mismo chart también estuviera incluido una segunda vez bajo el alias `pagecache`.
- **Q28.** Un subchart lee `.Values.image.repository`. Desde el chart paraguas, dá las dos formas distintas de fijarlo — una a través de la clave del subchart y otra a través de `global` — y decí cuál tuvo que haber soportado explícitamente el autor del subchart.
- **Q29.** `charts/` ahora contiene archivos `.tgz` commiteados. Argumentá los dos lados: qué ganás commiteándolos (vendoring), y qué ganás commiteando solo `Chart.lock`. ¿Cuál es obligatorio para una build air-gapped?
- **Q30.** Un subchart trae una CRD en `crds/`. El chart paraguas se actualiza con un subchart más nuevo cuya CRD ganó un campo. Predecí qué hace Helm, y decí el procedimiento operativo que realmente hace falta.

---

## Ejercicio 7 — Repositorios: package, index, HTTP, OCI y provenance

### Pasos

1. Empaquetá el chart e inspeccioná el artefacto:

```bash
$ cd ~/lpi703
$ helm package web
Successfully packaged chart and saved it to: /home/user/lpi703/web-0.2.0.tgz

$ tar tzf web-0.2.0.tgz | head
web/Chart.yaml
web/values.yaml
web/values.schema.json
web/templates/NOTES.txt
web/templates/_helpers.tpl
web/templates/configmap.yaml
web/templates/deployment.yaml
...
```

2. Confirmá que `.helmignore` está haciendo su trabajo:

```bash
$ echo "secret-notes.txt" >> web/.helmignore
$ echo "do not ship me" > web/secret-notes.txt
$ helm package web >/dev/null && tar tzf web-0.2.0.tgz | grep -c secret-notes
0
```

3. Construí un repositorio de charts HTTP clásico — un `index.yaml` más tarballs, nada más:

```bash
$ mkdir -p repo && mv web-0.2.0.tgz repo/
$ helm package cache -d repo/ >/dev/null
$ helm repo index repo/ --url http://127.0.0.1:8879
$ head -25 repo/index.yaml
apiVersion: v1
entries:
  cache:
  - apiVersion: v2
    appVersion: 1.16.0
    created: "2026-09-03T10:52:44.109827-03:00"
    description: A Helm chart for Kubernetes
    digest: 2f1e7c9d4b8a0e3f6c5d2b1a8f7e4c9d0b3a6f1e2c5d8b7a4e9f0c3d6b1a8e2f
    name: cache
    type: application
    urls:
    - http://127.0.0.1:8879/cache-0.1.0.tgz
    version: 0.1.0
  web:
  - apiVersion: v2
    appVersion: 1.27.2
    created: "2026-09-03T10:52:44.110412-03:00"
    ...
generated: "2026-09-03T10:52:44.108991-03:00"
```

4. Servilo y consumilo como lo haría un cliente:

```bash
$ (cd repo && python3 -m http.server 8879 >/tmp/repo.log 2>&1 &)
$ helm repo add lpilab http://127.0.0.1:8879
"lpilab" has been added to your repositories

$ helm repo update lpilab
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "lpilab" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm search repo lpilab
NAME          CHART VERSION  APP VERSION  DESCRIPTION
lpilab/cache  0.1.0          1.16.0       A Helm chart for Kubernetes
lpilab/web    0.2.0          1.27.2       Production reference web tier for LPI 703.3

$ helm install fromrepo lpilab/web -n pkg --set config.environment=prod --wait >/dev/null
$ helm list -n pkg --filter fromrepo
NAME      NAMESPACE  REVISION  STATUS    CHART      APP VERSION
fromrepo  pkg        1         deployed  web-0.2.0  1.27.2
```

5. Publicá una segunda versión y observá que los clientes no la ven hasta que refrescan:

```bash
$ sed -i 's/^version: 0.2.0/version: 0.3.0/' web/Chart.yaml
$ helm package web -d repo/ >/dev/null
$ helm repo index repo/ --url http://127.0.0.1:8879 --merge repo/index.yaml

$ helm search repo lpilab/web --versions
NAME        CHART VERSION  APP VERSION  DESCRIPTION
lpilab/web  0.2.0          1.27.2       Production reference web tier for LPI 703.3

$ helm repo update lpilab >/dev/null && helm search repo lpilab/web --versions
NAME        CHART VERSION  APP VERSION  DESCRIPTION
lpilab/web  0.3.0          1.27.2       Production reference web tier for LPI 703.3
lpilab/web  0.2.0          1.27.2       Production reference web tier for LPI 703.3
```

6. Descargá sin instalar — la jugada de auditoría antes de confiar en un chart de terceros:

```bash
$ helm pull lpilab/web --version 0.3.0 --untar --untardir /tmp/audit
$ diff -r /tmp/audit/web web >/dev/null && echo "identical"
identical
```

7. Ahora hacé lo mismo con un registro OCI, que es donde viven los charts en 2026:

```bash
$ docker run -d --name lpireg -p 5000:5000 registry:2 >/dev/null
$ helm push repo/web-0.3.0.tgz oci://localhost:5000/charts
Pushed: localhost:5000/charts/web:0.3.0
Digest: sha256:8c1f0a5d2e7b4c9a6f3d0b8e5c2a1f7d4b9e6c3a0f8d5b2e7c4a1f9d6b3e0c8a

$ helm show chart oci://localhost:5000/charts/web --version 0.3.0 | head -4
apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
kubeVersion: '>=1.28.0-0'

$ helm install oci-web oci://localhost:5000/charts/web --version 0.3.0 \
    -n pkg --set config.environment=prod --wait >/dev/null
$ helm list -n pkg --filter oci-web
NAME     NAMESPACE  REVISION  STATUS    CHART      APP VERSION
oci-web  pkg        1         deployed  web-0.3.0  1.27.2
```

8. Firmá un chart y verificalo. Ojo con la trampa del formato de GnuPG:

```bash
$ gpg --quick-generate-key "LPI Lab <lab@example.com>" default default never
$ gpg --export-secret-keys > ~/.gnupg/secring.gpg     # Helm needs the legacy keyring format

$ helm package web --sign --key 'LPI Lab' --keyring ~/.gnupg/secring.gpg -d repo/
Successfully packaged chart and saved it to: /home/user/lpi703/repo/web-0.3.0.tgz

$ cat repo/web-0.3.0.tgz.prov | head -12
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

apiVersion: v2
appVersion: 1.27.2
description: Production reference web tier for LPI 703.3
...
files:
  web-0.3.0.tgz: sha256:5f2c1a8d...
-----BEGIN PGP SIGNATURE-----
...

$ gpg --export > ~/.gnupg/pubring.gpg
$ helm verify repo/web-0.3.0.tgz --keyring ~/.gnupg/pubring.gpg
Signed by: LPI Lab <lab@example.com>
Using Key With Fingerprint: 9C1A0F4B8D2E7A6C3F5B0D9E8C2A1F7D4B6E3C09
Chart Hash Verified: sha256:5f2c1a8d...

$ printf '\0' >> repo/web-0.3.0.tgz
$ helm verify repo/web-0.3.0.tgz --keyring ~/.gnupg/pubring.gpg
Error: sha256 hash of web-0.3.0.tgz does not match the value in the provenance file
```

### Preguntas de verificación

- **Q31.** Un repositorio de charts es "solamente un servidor HTTP". Listá el conjunto mínimo de cosas que debe servir, y explicá por qué `helm repo add` de un repositorio con 400 charts es instantáneo mientras que `helm install` de uno de ellos hace una segunda petición.
- **Q32.** En el paso 5, `helm search repo` mostró la versión vieja hasta que corrió `helm repo update`. ¿Dónde vive ese dato viejo en disco, y cuál es la diferencia relevante para el examen entre `helm search repo` y `helm search hub`?
- **Q33.** Compará un repositorio HTTP clásico con un registro OCI en tres ejes: cómo se descubren las versiones, cómo funciona la autenticación, y qué puede hacer `helm search repo` para cada uno. ¿Cuál es la consecuencia práctica del tercero?
- **Q34.** La verificación de provenance falló después de agregar un byte. Explicá qué contiene el archivo `.prov`, por qué `--verify` en `helm install` protege contra un *mirror* comprometido pero no contra un *autor de chart* comprometido, y dónde debe estar la clave pública para que CI pueda chequearlo.
- **Q35.** Tenés que garantizar que una build producida hoy pueda reproducirse byte a byte dentro de dos años, con el repositorio upstream offline. Dá los artefactos concretos que archivás y los comandos exactos que corre un ingeniero futuro.

---

## Ejercicio 8 — Hooks, CRDs y tests de chart

### Pasos

1. Agregá un Job de migración pre-upgrade y un notificador post-install:

```bash
$ cat > web/templates/migrate-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "web.fullname" . }}-migrate
  labels:
    {{- include "web.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  template:
    metadata:
      name: {{ include "web.fullname" . }}-migrate
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["sh", "-c", "echo 'applying schema {{ .Chart.AppVersion }}'; sleep 5; echo done"]
EOF

$ cat > web/templates/prewarm-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "web.fullname" . }}-prewarm
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: prewarm
          image: busybox:1.36
          command: ["sh", "-c", "echo warming {{ include \"web.fullname\" . }}"]
EOF
```

2. Instalá un release nuevo y observá el orden:

```bash
$ helm install hooked ./web -n pkg --set config.environment=prod --wait --timeout 3m
NAME: hooked
LAST DEPLOYED: Thu Sep  3 11:05:12 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 1

$ kubectl get events -n pkg --sort-by=.lastTimestamp | grep -E 'hooked-(migrate|prewarm)|hooked-[0-9a-f]{9,}' | head
0s   Normal   SuccessfulCreate   job/hooked-migrate     Created pod: hooked-migrate-x7k2p
0s   Normal   Completed          job/hooked-migrate     Job completed
0s   Normal   ScalingReplicaSet  deployment/hooked      Scaled up replica set hooked-6d4bcbb7c5 to 1
0s   Normal   SuccessfulCreate   job/hooked-prewarm     Created pod: hooked-prewarm-m9d4t
```

3. Confirmá que los hooks no forman parte del manifiesto del release:

```bash
$ helm get manifest hooked -n pkg | grep -c 'kind: Job'
0
$ helm get hooks hooked -n pkg | grep -E '^kind:|helm.sh/hook:'
    "helm.sh/hook": pre-install,pre-upgrade
kind: Job
    "helm.sh/hook": post-install,post-upgrade
kind: Job
    "helm.sh/hook": test
kind: Pod
```

4. Hacé fallar un hook y observá qué hace Helm con el release:

```bash
$ sed -i 's|echo .applying schema.*done|exit 1|' web/templates/migrate-job.yaml
$ helm upgrade hooked ./web -n pkg --set config.environment=prod --wait --timeout 90s
Error: UPGRADE FAILED: pre-upgrade hooks failed: 1 error occurred:
	* job hooked-migrate failed: BackoffLimitExceeded

$ helm history hooked -n pkg
REVISION  UPDATED                   STATUS      CHART      APP VERSION  DESCRIPTION
1         Thu Sep  3 11:05:12 2026  deployed    web-0.3.0  1.27.2       Install complete
2         Thu Sep  3 11:09:44 2026  failed      web-0.3.0  1.27.2       pre-upgrade hooks failed: ...

$ kubectl get job -n pkg hooked-migrate
NAME             STATUS     COMPLETIONS   DURATION   AGE
hooked-migrate   Failed     0/1           68s        68s
```

5. Restaurá el hook, y después corré los tests del chart:

```bash
$ sed -i 's|exit 1|echo "applying schema {{ .Chart.AppVersion }}"; sleep 5; echo done|' web/templates/migrate-job.yaml
$ helm upgrade hooked ./web -n pkg --set config.environment=prod --wait >/dev/null

$ cat web/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "web.fullname" . }}-test-connection"
  labels:
    {{- include "web.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['{{ include "web.fullname" . }}:{{ .Values.service.port }}']
  restartPolicy: Never

$ helm test hooked -n pkg --logs
NAME: hooked
LAST DEPLOYED: Thu Sep  3 11:12:30 2026
NAMESPACE: pkg
STATUS: deployed
REVISION: 3
TEST SUITE:     hooked-test-connection
Last Started:   Thu Sep  3 11:13:02 2026
Last Completed: Thu Sep  3 11:13:09 2026
Phase:          Succeeded

POD LOGS: hooked-test-connection
Connecting to hooked:80 (10.96.184.22:80)
saving to 'index.html'
index.html           100% |********************************|   615  0:00:00 ETA
```

6. Agregá una CRD como Helm espera, y observá la asimetría:

```bash
$ mkdir -p web/crds && cat > web/crds/widget.yaml <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.lab.lpi.org
spec:
  group: lab.lpi.org
  names:
    kind: Widget
    listKind: WidgetList
    plural: widgets
    singular: widget
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size: { type: string }
EOF

$ helm install crdtest ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get crd widgets.lab.lpi.org
NAME                  CREATED AT
widgets.lab.lpi.org   2026-09-03T14:16:02Z

$ helm get manifest crdtest -n pkg | grep -c CustomResourceDefinition
0

$ sed -i 's/size: { type: string }/size: { type: string }\n                color: { type: string }/' web/crds/widget.yaml
$ helm upgrade crdtest ./web -n pkg --set config.environment=prod --wait >/dev/null
$ kubectl get crd widgets.lab.lpi.org -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties}'; echo
{"size":{"type":"string"}}

$ helm uninstall crdtest -n pkg >/dev/null
$ kubectl get crd widgets.lab.lpi.org --no-headers
widgets.lab.lpi.org   2026-09-03T14:16:02Z
```

### Preguntas de verificación

- **Q36.** Listá los eventos de hook que Helm dispara alrededor de un upgrade, en orden, y ubicá `--wait` correctamente respecto de ellos. ¿Qué hooks corren si `helm upgrade` falla durante la aplicación de recursos?
- **Q37.** `helm get manifest` mostró cero Jobs pero `helm get hooks` mostró dos. Explicá la consecuencia de propiedad: qué le pasa a un recurso de hook con `hook-succeeded` en `helm uninstall`, y qué le pasa a uno sin ningún `hook-delete-policy`.
- **Q38.** `helm.sh/hook-weight: "-5"` está entre comillas. ¿Qué se rompe si escribís `-5` sin comillas, y cuál es el orden de desempate para dos hooks con el mismo peso?
- **Q39.** El paso 6 mostró una CRD instalada en la primera instalación, *no* actualizada en el upgrade, y *no* eliminada en el uninstall. Dá la razón de diseño de los tres comportamientos, y describí las dos estrategias de autoría de charts que usan los equipos para sortear la brecha del upgrade — con el riesgo de cada una.
- **Q40.** `helm test` tuvo éxito acá, pero un Pod de test que se cuelga va a bloquear un pipeline. Nombrá el flag que lo acota, y explicá por qué los tests de chart son hooks y no plantillas ordinarias.

---

## Ejercicio 9 — Diagnóstico en producción

### Pasos

1. Generá drift a mano, y después dejá que Helm lo corrija:

```bash
$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl scale deployment web -n pkg --replicas=0
deployment.apps/web scaled
$ kubectl get deploy web -n pkg
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/0     0            0           54m

$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl get deploy web -n pkg
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/3     3            3           55m
```

2. Agregá a mano un campo que el chart no gestiona, y mirá cómo sobrevive:

```bash
$ kubectl annotate deployment web -n pkg observed-by=sre-oncall
deployment.apps/web annotated
$ helm upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=3 --wait >/dev/null
$ kubectl get deploy web -n pkg -o jsonpath='{.metadata.annotations.observed-by}'; echo
sre-oncall
```

3. Previsualizá un upgrade como un diff en lugar de un muro de YAML:

```bash
$ helm plugin install https://github.com/databus23/helm-diff
Installed plugin: diff

$ helm diff upgrade web ./web -n pkg --set config.environment=prod --set replicaCount=5
pkg, web, Deployment (apps) has changed:
  ...
  spec:
-   replicas: 3
+   replicas: 5
    selector:
  ...
```

4. Fabricá un release trabado — el incidente que todo operador de Helm termina conociendo:

```bash
$ helm upgrade web ./web -n pkg --set config.environment=prod \
    --set image.tag=1.29.9-does-not-exist --wait --timeout 10m &
$ sleep 12 && kill %1
$ helm list -n pkg --filter '^web$'
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS           CHART      APP VERSION
web   pkg        9         2026-09-03 11:31:02.771 -03:00 -03      pending-upgrade  web-0.3.0  1.27.2

$ helm upgrade web ./web -n pkg --set config.environment=prod --wait
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

5. Resolvelo — primero de la forma soportada, y después la salida de emergencia:

```bash
$ helm rollback web -n pkg --wait
Rollback was a success! Happy Helming!

# If rollback is also refused, the release pointer must be moved by hand:
$ kubectl get secret -n pkg -l owner=helm,name=web --sort-by=.metadata.name -o name | tail -3
secret/sh.helm.release.v1.web.v8
secret/sh.helm.release.v1.web.v9
secret/sh.helm.release.v1.web.v10
$ kubectl delete secret -n pkg sh.helm.release.v1.web.v9      # the pending revision only
$ helm list -n pkg --filter '^web$'
NAME  NAMESPACE  REVISION  UPDATED                                 STATUS    CHART      APP VERSION
web   pkg        10        2026-09-03 11:33:47.220 -03:00 -03      deployed  web-0.3.0  1.27.2
```

6. Entendé `--force` antes de que alguien te lo pase como solución:

```bash
$ kubectl get pods -n pkg -l app.kubernetes.io/instance=web -o name | wc -l
3
$ helm upgrade web ./web -n pkg --set config.environment=prod --force --wait
Release "web" has been upgraded. Happy Helming!
$ kubectl get svc web -n pkg -o jsonpath='{.spec.clusterIP}'; echo
10.96.184.22
```

7. Podá el historial huérfano y confirmá la semántica del uninstall:

```bash
$ helm history web -n pkg | wc -l
11
$ helm upgrade web ./web -n pkg --set config.environment=prod --history-max 5 --wait >/dev/null
$ helm history web -n pkg | wc -l
6

$ helm uninstall fromrepo -n pkg --keep-history
release "fromrepo" uninstalled
$ helm list -n pkg --uninstalled
NAME      NAMESPACE  REVISION  UPDATED                              STATUS      CHART      APP VERSION
fromrepo  pkg        1         2026-09-03 10:55:11.02 -03:00 -03    uninstalled web-0.2.0  1.27.2
$ helm rollback fromrepo 1 -n pkg --wait
Rollback was a success! Happy Helming!
```

### Preguntas de verificación

- **Q41.** El paso 1 restableció `replicas` de 0 de vuelta a 3; el paso 2 dejó en paz una anotación agregada a mano. Nombrá la estrategia de parcheo que usa Helm 3, decí las tres entradas que consume, y derivá ambos resultados a partir de ella.
- **Q42.** Dado el comportamiento del paso 1, explicá el peligro concreto en producción de un chart que fija `spec.replicas` de forma dura mientras un HPA gestiona el mismo Deployment — y dá la construcción exacta del chart que usa el andamio para evitarlo.
- **Q43.** Un release está trabado en `pending-upgrade` y `helm rollback` se niega. Explicá qué *significa* ese estado en el backend de almacenamiento, por qué funciona borrar el Secret de release más nuevo, y el riesgo específico de pérdida de datos de borrar el equivocado.
- **Q44.** `--force` le "arregló" un upgrade trabado a un colega. Explicá qué le hace realmente a los recursos que Kubernetes considera inmutables, y nombrá dos tipos de objeto donde causa una caída visible.
- **Q45.** `--history-max 5` recortó el historial a cinco revisiones. Decí el valor por defecto, el costo de almacenamiento de un historial sin límite en un clúster con 300 releases, y qué perdés cuando la ventana recorta una revisión a la que después querías volver.
- **Q46.** Contrastá `helm uninstall` con y sin `--keep-history` en tres puntos: visibilidad en `helm list`, si el nombre puede reutilizarse inmediatamente, y si `helm rollback` es posible.

---

## Ejercicio 10 — Kustomize: la alternativa sin plantillas

### Pasos

1. Construí una base sin ningún templating:

```bash
$ mkdir -p kust/base && cd kust/base
$ cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27.0
          ports:
            - containerPort: 80
          envFrom:
            - configMapRef:
                name: api-config
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
EOF
$ cat > service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
EOF
$ cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: lpi703
    includeSelectors: false
configMapGenerator:
  - name: api-config
    literals:
      - LOG_LEVEL=info
EOF
```

2. Agregá un overlay de producción que cambie la base sin editarla:

```bash
$ cd .. && mkdir -p overlays/prod && cd overlays/prod
$ cat > resources-patch.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  template:
    spec:
      containers:
        - name: api
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
EOF
$ cat > kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: pkg
namePrefix: prod-
resources:
  - ../../base
replicas:
  - name: api
    count: 4
images:
  - name: nginx
    newTag: 1.27.2
configMapGenerator:
  - name: api-config
    behavior: merge
    literals:
      - LOG_LEVEL=warn
patches:
  - path: resources-patch.yaml
    target:
      kind: Deployment
      name: api
EOF
```

3. Renderizá y leé el resultado con atención:

```bash
$ kubectl kustomize . | grep -E '^(kind|  name|    name)|replicas:|image:|LOG_LEVEL'
kind: ConfigMap
  name: prod-api-config-9h2f4k8m6t
  LOG_LEVEL: warn
kind: Service
  name: prod-api
kind: Deployment
  name: prod-api
  replicas: 4
          image: nginx:1.27.2

$ kubectl kustomize . | grep -A2 'configMapRef'
            - configMapRef:
                name: prod-api-config-9h2f4k8m6t
```

4. Aplicalo y cambiá un literal:

```bash
$ kubectl apply -k . >/dev/null
$ kubectl get deploy -n pkg prod-api
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
prod-api   4/4     4            4           28s

$ sed -i 's/LOG_LEVEL=warn/LOG_LEVEL=debug/' kustomization.yaml
$ kubectl apply -k . 
configmap/prod-api-config-3d7b1e5c0a created
deployment.apps/prod-api configured
service/prod-api unchanged

$ kubectl rollout status deploy/prod-api -n pkg
deployment "prod-api" successfully rolled out
$ kubectl get cm -n pkg | grep prod-api-config
prod-api-config-3d7b1e5c0a   1      12s
prod-api-config-9h2f4k8m6t   1      2m
```

5. Combiná las dos herramientas — Helm renderiza, Kustomize post-procesa:

```bash
$ cd ~/lpi703
$ cat > kustomize-render.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /tmp/pr/all.yaml
cd /tmp/pr && kubectl kustomize .
EOF
$ chmod +x kustomize-render.sh
$ mkdir -p /tmp/pr && cat > /tmp/pr/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - all.yaml
patches:
  - patch: |-
      - op: add
        path: /metadata/annotations/policy.example.com~1reviewed
        value: "true"
    target:
      kind: Deployment
EOF

$ helm template postrender ./web -n pkg --set config.environment=prod \
    --post-renderer ./kustomize-render.sh | grep -B1 'policy.example.com'
  annotations:
    policy.example.com/reviewed: "true"
```

6. Fijate en las versiones en juego — una causa clásica de tickets de soporte:

```bash
$ kubectl version --client -o yaml | grep -A1 kustomizeVersion
kustomizeVersion: v5.4.2

$ kustomize version
v5.5.0
```

### Preguntas de verificación

- **Q47.** El ConfigMap generado se llamó `prod-api-config-9h2f4k8m6t`, y cambiar un literal produjo un nombre nuevo más un rollout del Deployment. Nombrá el mecanismo, y explicá qué debe hacer un chart de Helm común para lograr el mismo efecto (lo construiste en el Ejercicio 5).
- **Q48.** El paso 4 dejó el ConfigMap viejo en el clúster. Decí por qué `kubectl apply -k` no lo elimina, y nombrá el flag que sí lo hace — junto con la razón por la que es peligroso.
- **Q49.** Decí la diferencia fundamental de diseño entre Helm y Kustomize respecto de *cuándo* se resuelve la configuración, y derivá de ahí dos cosas que Kustomize estructuralmente no puede hacer y una clase de bug que estructuralmente no puede tener.
- **Q50.** Kustomize no tiene objeto release. Dado eso, respondé: cómo sabés qué recursos del clúster vinieron de `overlays/prod`, cómo hacés rollback, y qué reemplaza a `helm history`.
- **Q51.** `kubectl kustomize` reportó v5.4.2 mientras que el `kustomize` standalone reportó v5.5.0. Describí el modo de falla que esto produce en un equipo, y dá la regla que pondrías en el README del proyecto.
- **Q52.** El post-renderer del paso 5 mutó la salida de Helm antes de que llegara al clúster. Explicá por qué esto es más seguro que forkear un chart upstream, y nombrá la única cosa que *no* te deja cambiar.

---

## Limpieza

```bash
$ helm uninstall web hooked fromrepo oci-web -n pkg 2>/dev/null
$ kubectl delete -k ~/lpi703/kust/overlays/prod
$ kubectl delete crd widgets.lab.lpi.org
$ docker rm -f lpireg
$ kind delete cluster --name lpi703
$ pkill -f "http.server 8879"
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Lab 0

**A1.** Helm 3 es un cliente puro. Construye los manifiestos localmente y habla con el API server usando **las credenciales de tu kubeconfig**, así que `helm install` solo puede hacer lo que tu RBAC ya permite. Consecuencia: ya no hay una única identidad privilegiada dentro del clúster que todos los usuarios toman prestada. En Helm 2, un usuario acotado a un namespace podía alcanzar poder de nivel cluster-admin a través del ServiceAccount de Tiller; en Helm 3, un tenant restringido al namespace `pkg` no puede instalar un chart que cree un ClusterRole — la petición la rechaza el API server, no Helm. Los Secrets del release también viven en el namespace del release, así que el aislamiento de tenants sigue el RBAC normal de namespaces. Ver <https://helm.sh/docs/faq/changes_since_helm2/>.

**A2.** La compatibilidad la determinan los grupos/versiones de API que sirve el *clúster destino* frente a lo que emiten las plantillas del chart. Dos mecanismos lo expresan: (a) `kubeVersion` en `Chart.yaml`, un rango SemVer que Helm hace cumplir antes de instalar (`Error: chart requires kubeVersion: >=1.28.0-0 which is incompatible with Kubernetes v1.27.4`); y (b) `.Capabilities.APIVersions.Has "<group>/<version>"` dentro de las plantillas, que le permite a un mismo chart renderizar objetos distintos según el clúster. También es relevante la política de version skew de Helm/Kubernetes: <https://helm.sh/docs/topics/version_skew/>.

### Ejercicio 1

**A3.** `version` es el SemVer del paquete-chart y es el *único* campo que comparan el índice del repositorio y el resolvedor. `appVersion` es metadato de forma libre que describe el software empaquetado; no es una versión de paquete y no participa de la resolución de dependencias ni de la selección de versión de `helm search`. Subir solo `appVersion` republica las mismas coordenadas, así que `helm repo update` no ve un chart más nuevo y `helm upgrade` es un no-op. Regla: cualquier cambio dentro del directorio del chart — plantillas, values, defaults, `appVersion` — requiere subir `version`. Ver <https://helm.sh/docs/topics/charts/#the-chartyaml-file>.

**A4.** `apiVersion` en `Chart.yaml` selecciona el **formato del chart**: `v1` es el formato de Helm 2, `v2` es el de Helm 3. `v2` agrega el campo `type`, mueve las dependencias a `Chart.yaml`, y agrega `dependencies[].condition/tags/import-values`. Un chart `v1` declaraba sus dependencias en un `requirements.yaml` aparte (con los overrides en `requirements.lock`). Helm 3 todavía instala charts `v1`, que es la razón por la que ocasionalmente te cruzás con `requirements.yaml` en repositorios viejos.

**A5.** Un library chart es un **paquete de solo plantillas**: exporta plantillas nombradas con `define` para que otros charts las hagan `include`, y no trae plantillas renderizables propias (los archivos deben llevar el prefijo `_`, por ejemplo `_pod.tpl`). Existe para eliminar el copiar-y-pegar en una flota de charts — un solo lugar define el esqueleto estándar del Deployment, el security context y el conjunto de labels. Los consumidores lo agregan bajo `dependencies:` como cualquier otro chart y llaman `{{ include "common.deployment" . }}`. Helm se niega a instalarlo porque produciría cero objetos de Kubernetes. Ver <https://helm.sh/docs/topics/library_charts/>.

**A6.** El deployment del andamio renderiza `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"`, así que el default vacío cae hasta `appVersion` — acá `1.27.2`. Eso es más seguro que `latest` por dos razones: la versión desplegada queda fijada y registrada en el release, así que `helm history`/`helm get metadata` te dicen qué está corriendo realmente; y `latest` combinado con `imagePullPolicy: Always` hace que los reinicios de Pod cambien silenciosamente el software en ejecución, lo cual es irreproducible y destruye la semántica de rollback — `helm rollback` restauraría el mismo tag flotante.

### Ejercicio 2

**A7.** El `text/template` de Go resuelve una clave de mapa faltante al valor cero en lugar de dar un error. `.Values.autoscaling.enabld` es una clave inexistente en un mapa, así que evalúa a `<no value>`/nil, que `if` trata como falso. Nada da error; el HPA simplemente nunca se renderiza, y `helm lint` — que hace lint sobre lo que se *produjo* — ve YAML válido y reporta éxito. La opción que cambia esto es la opción `missingkey=error` de Go, que Helm expone de forma tal que **`helm template --debug` no la habilita**; la ruta soportada es `helm lint --strict` (convierte las advertencias en fallas) combinada con `values.schema.json` para acotar la superficie de valores, y renderizar con un `--set` de un conjunto de valores conocido-bueno en CI. El arreglo estructural es el esquema: una clave desconocida puede rechazarse con `"additionalProperties": false`.

**A8.** De más débil a más fuerte:
1. `helm template` — puramente del lado del cliente. Detecta errores de sintaxis de plantillas Go, fallas de `required`, violaciones del esquema, y YAML que no va a parsear. Nunca contacta al API server, así que funciona en un runner de CI air-gapped.
2. `--dry-run` (cliente) — todo lo anterior, más la colisión del nombre del release contra el backend de almacenamiento, `.Capabilities` reales tomadas del discovery del clúster vivo, y un `.Release.IsUpgrade` correcto.
3. `--dry-run=server` (3.13+) — todo lo anterior, más la validación de esquema del API server (campos desconocidos, tipos equivocados como el entero `memory: 128`), los admission webhooks, y el rechazo por políticas de OPA/Kyverno; `lookup` también resuelve. Detecta el "renderiza bien, pero el clúster lo rechaza".

**A9.** En `helm template`, `.Capabilities.APIVersions` se puebla desde una **lista por defecto incorporada** compilada dentro del cliente Helm (no desde tu clúster) salvo que pases `--api-versions`, y `.Release.IsUpgrade` es siempre `false` mientras que `.Release.IsInstall` es siempre `true`. Modo de falla: un chart condicionado a `policy/v1` renderiza el PDB en CI porque la lista por defecto de Helm lo contiene, pero el destino de despliegue es un clúster más viejo o recortado que solo sirve `policy/v1beta1` — CI está en verde, `helm install` falla al aplicar. A la inversa, un chart condicionado a un grupo provisto por una CRD (por ejemplo `monitoring.coreos.com/v1` para ServiceMonitor) no renderiza *nada* en CI, así que el test de golden file pierde cobertura en silencio. Arreglo: pasar `--api-versions` explícitamente en CI, o usar `--dry-run=server`.

**A10.** `helm template <rel> <chart> --show-only templates/cronjob.yaml` (repetible; la ruta es relativa a la raíz del chart, y `-s` es la forma corta). Si la plantilla nombrada no renderiza nada — el archivo entero está dentro de un `if` falso — Helm sale con código distinto de cero y `Error: could not find template templates/cronjob.yaml in chart`. Ese error es genuinamente útil: distingue "escribí mal la ruta" de "la feature está deshabilitada", pero implica que `--show-only` en un script de CI necesita manejo con `|| true` si el objeto es condicional.

### Ejercicio 3

**A11.** (a) Los Secrets de release contienen el manifiesto renderizado completo, que incluye cada `kind: Secret` que creó el chart. Un usuario con `get secrets` en el namespace puede leer `sh.helm.release.v1.*`, decodificarlo, y recuperar secretos de la aplicación aun si el RBAC sobre los objetos Secret individuales fuera más estricto — así que "leer Secrets en este namespace" equivale efectivamente a "leer todo lo que Helm haya desplegado acá", y la retención de historial extiende eso hacia atrás en el tiempo. (b) Borrar los Secrets del release borra el *único* registro de Helm. `helm list` no muestra nada, `helm history` desaparece, y `helm upgrade` falla con `Error: ... release: not found`. Las cargas de trabajo siguen corriendo intactas — Kubernetes no tiene idea de que Helm existió — dejando recursos huérfanos que hay que adoptar reinstalando con los mismos nombres o limpiar por label (`app.kubernetes.io/managed-by=Helm`).

**A12.** El almacenamiento de Helm es **append-only**; la revisión "actual" de un release es el registro no-superseded con el número más alto. Un rollback re-aplica el manifiesto de la revisión 2 pero lo escribe como revisión 4 con `DESCRIPTION: Rollback to 2`. Eso te da un rastro de auditoría inmutable — podés ver que hubo un rollback, cuándo, y desde qué — y hace que el propio rollback sea reversible: podés hacer `helm rollback web 3` para volver al estado del que te alejaste. Una restauración en el lugar reescribiría el historial y dejaría sin respuesta la pregunta "¿por qué producción está corriendo la imagen vieja?".

**A13.** El flag es `--atomic`. **Implica `--wait`** — Helm bloquea hasta que todos los recursos reporten estar listos (o expire `--timeout`) y, ante cualquier falla, ejecuta automáticamente un rollback a la revisión desplegada anterior, dejando el release en `deployed` en lugar de `failed`. Razones por las que un equipo puede no quererlo en todos lados: (1) convierte una falla parcial en un rollback completo, lo que para un release grande significa el doble de movimiento y puede ser más lento y más disruptivo que arreglar hacia adelante; (2) la semántica de `--wait` es incorrecta para charts cuyos Pods legítimamente nunca llegan a Ready sin una acción externa (un chart basado en Jobs, o un StatefulSet esperando aprovisionamiento manual de PVC), así que `--atomic` haría rollback de una instalación perfectamente buena al vencer el timeout; (3) esconde el estado intermedio roto que quizás necesitás para diagnosticar.

**A14.** Causas de divergencia: (1) **admission mutante** — inyectores de sidecars (Istio, Linkerd), webhooks de defaulting, y los propios defaults del API server agregan campos que el manifiesto nunca tuvo; (2) **cambios fuera de banda** — `kubectl edit`, un HPA escribiendo `spec.replicas`, un operator reconciliando el objeto, u otro controlador agregando anotaciones. La lógica de upgrade de Helm consulta **las tres**: el manifiesto *viejo* almacenado, el manifiesto *nuevo* renderizado, y el objeto *vivo*, que es precisamente el merge a tres vías. `helm get manifest` muestra solo lo que Helm renderizó — es intención, no realidad.

**A15.** `HELM_DRIVER=configmap helm list -n pkg` imprime una **lista vacía**: el driver determina dónde busca Helm, y nunca se escribió nada en ConfigMaps, así que los releases son invisibles. Razón para preferir `secret` (el default desde Helm 3): las cargas útiles de los releases suelen contener manifiestos de Secret, y los Secrets son el tipo de objeto cubierto por el cifrado en reposo (`EncryptionConfiguration`) y por un RBAC por defecto más estricto — los ConfigMaps no están cifrados en reposo y son mucho más ampliamente legibles. Ninguno alcanza para releases muy grandes porque ambos objetos están limitados a aproximadamente **1 MiB** en etcd; un chart que renderiza cientos de objetos (o que embebe CRDs grandes) lo excede y falla al guardar, que es la razón por la que Helm soporta el driver `sql` (PostgreSQL) para instalaciones de gran escala. Ver <https://helm.sh/docs/topics/advanced/#storage-backends>.

### Ejercicio 4

**A16.** De menor a mayor precedencia:
1. El `values.yaml` propio del subchart
2. El `values.yaml` del chart padre (el bloque `subchartname:` del padre sobreescribe los defaults del subchart)
3. `-f a.yaml`
4. `-f b.yaml` (el `-f` posterior gana sobre el anterior)
5. `--set`
6. `--set-string` / `--set-json` / `--set-file` — mismo nivel que `--set`; entre ellos, gana el último de la línea de comandos.

La fusión es un deep merge para **mapas**. **Las listas se reemplazan enteras**, no se concatenan — esa es la que reemplaza silenciosamente. `null` también es especial: fijar una clave a `null` la elimina del resultado fusionado en lugar de dejarla en nil.

**A17.** Dos conversiones independientes. (1) El parser `strvals` de Helm tipa el lado derecho: un token pelado que parsea como número se convierte en un **int64**, así que `00123` se vuelve el entero `123` y los ceros a la izquierda desaparecen antes de que corra ninguna plantilla. (2) Cuando ese valor se emite al YAML en un contexto que exige un string (los valores de anotación deben ser strings), Helm entrecomilla el entero, y por eso ves `"123"`. Evitá (1) con `--set-string podAnnotations.build=00123`, que fuerza el valor a un string de Go, o `--set-json 'podAnnotations={"build":"00123"}'` para control total del tipo. La misma trampa muerde con `--set image.tag=1.27` (float `1.27`, y `1.10` se volvería `1.1`) y `--set nodeSelector.rack=01` — siempre `--set-string` para identificadores que parecen numéricos.

**A18.** Ambas afirmaciones son ciertas a niveles distintos. `--set 'tolerations[0].key=only-this'` **no** provee una lista nueva; la sintaxis de índice navega *dentro* de la lista fusionada existente y fija una hoja, así que la fusión ocurre elemento por elemento y el elemento 1 queda intacto. La regla "las listas se reemplazan" aplica cuando un **archivo** de values o un `--set` de lista entera provee la lista en sí: `-f lists.yaml` después de otro archivo con `tolerations` descarta enteramente la lista anterior. `--set tolerations=null` fija la clave a null, lo que la elimina de los values fusionados — el `{{- with .Values.tolerations }}` de la plantilla entonces no renderiza nada, descartando todas las tolerations.

**A19.** El esquema lo hacen cumplir `helm install`, `helm upgrade`, `helm rollback`, `helm template` y `helm lint` — incluyendo los values de subcharts, donde el esquema propio de cada chart valida su propio subárbol. Es estrictamente más fuerte que la validación del lado del servidor porque: (a) corre **antes** del renderizado, así que un valor malo falla en milisegundos localmente con un mensaje que nombra la ruta del valor, en lugar de después de un apply parcial; (b) valida *semántica que el API server no puede conocer* — `replicaCount` entre 1 y 10, un enum de entornos permitidos, un campo requerido sin un default sensato; (c) atrapa valores que renderizan manifiestos **válidos pero equivocados**, que el API server aceptaría contento; y (d) con `"additionalProperties": false` atrapa claves con typos, exactamente la clase de bug que `helm lint` no vio en el Ejercicio 2. Ver <https://helm.sh/docs/topics/charts/#schema-files>.

**A20.** `--reuse-values` fusiona los nuevos `--set`/`-f` encima de los valores almacenados en el release *anterior*, así que cada upgrade acumula estado que no existe en ningún lado de Git. Quitar un valor del archivo de values de tu pipeline no tiene efecto — el valor viejo resucita desde el registro del release para siempre, y la única forma de verlo es `helm get values`. Las alternativas determinísticas: **`--reset-values`**, que descarta los valores almacenados y usa los defaults del chart más exactamente lo que provee esta invocación; y **`--reset-then-reuse-values`** (Helm 3.14+), que resetea a los defaults del chart, después re-aplica los valores *provistos por el usuario* previos, y después los de esta invocación — útil cuando los defaults del chart cambiaron pero querés conservar los overrides del operador. La mejor práctica no es ninguno de los dos flags: pasá el conjunto completo de valores en cada upgrade, desde el control de versiones.

### Ejercicio 5

**A21.** `include` devuelve la plantilla renderizada **como un string**, así que su salida puede canalizarse a otras funciones. `template` es una sentencia que escribe directo al flujo de salida y no devuelve nada. Como `nindent 4` es una función que debe recibir un string como argumento, `{{ template "web.labels" . | nindent 4 }}` es un error de parseo/semántico — no hay ningún valor que canalizar. Cada lugar donde la salida de una plantilla nombrada necesita indentarse, entrecomillarse, hashearse (`sha256sum`) o capturarse en una variable, debe ser `include`. Ver <https://helm.sh/docs/howto/charts_tips_and_tricks/>.

**A22.** `indent N` antepone N espacios a **cada línea, incluida la primera**. `nindent N` emite **primero una nueva línea** y después indenta cada línea con N espacios. En `extra.yaml: |` la llamada a la plantilla está en su propia línea después de `{{-`, que come la nueva línea precedente; `nindent 4` devuelve esa nueva línea, así que la línea 1 aterriza en la columna 4 como el resto. Con `indent 4`, la nueva línea comida nunca se restaura, así que la primera línea se anexa a la indentación de 4 espacios que ya estaba en la línea fuente — 4 + 4 = 8 — mientras que las líneas siguientes reciben solo los 4 de la función. Regla práctica: después de un `{{-` en su propia línea, usá `nindent`; en línea después de texto existente, usá `indent`.

**A23.** La anotación vive en la **plantilla del Pod** (`spec.template.metadata.annotations`), así que cambiarla cambia el hash de la plantilla del Pod, lo que hace que el controlador de Deployment cree un ReplicaSet nuevo y ejecute un rolling update. Sin ella: un ConfigMap **montado como volumen** es actualizado en el lugar por el kubelet (eventualmente — hasta el período de sincronización más el TTL de caché, típicamente ~1 minuto), así que el archivo cambia debajo de un proceso en ejecución que no se va a enterar salvo que vigile el archivo; un ConfigMap consumido vía **`envFrom`/`env.valueFrom`** se inyecta solo al arrancar el contenedor y **nunca** se actualiza — el Pod conserva los valores viejos hasta que se lo recree por alguna razón no relacionada, que es el incidente clásico del "cambié la configuración hace una hora y no pasó nada".

**A24.** `lookup` hace una lectura viva de la API, y durante `helm template` (y el `--dry-run` del lado del cliente) no hay conexión con la API, así que devuelve un **mapa vacío**. La rama `if $existing` es falsa, corre `randAlphaNum 24`, y se imprime una contraseña completamente nueva. El accidente: un job de CI que renderiza con `helm template` y aplica con `kubectl apply -f` regenera la contraseña de la base de datos **en cada corrida del pipeline**, sobrescribiendo el Secret que funcionaba mientras los Pods en ejecución todavía tienen la vieja en su entorno — la aplicación empieza a fallar la autenticación en el próximo reinicio de Pod, horas más tarde, sin conexión obvia con el deploy. Mitigaciones: usar `helm upgrade` (que tiene acceso al clúster) en lugar de renderizar-y-aplicar; o abandonar por completo el patrón de generar-en-plantilla a favor de un gestor de secretos externo (External Secrets Operator, Vault) o un Job hook `pre-install` que cree el Secret exactamente una vez.

**A25.** Usá **`values.schema.json`**, con `{"type":"string","minLength":1,"pattern":"^[a-z0-9-]+$"}`. `required` solo prueba que el valor no está vacío en el momento en que esa única línea de plantilla renderiza: no puede expresar un patrón, se dispara únicamente si esa plantilla efectivamente se alcanza (un valor usado solo dentro de un `if` deshabilitado nunca se chequea), produce un error que nombra un archivo y una línea en lugar de una ruta de valor, y corre después de que el renderizado ya arrancó, así que el orden de las fallas no es determinístico entre plantillas. El esquema valida todo el árbol de values por adelantado, antes de cualquier renderizado, y lo chequean tanto `helm lint` como `helm template`. Usá ambos si querés: el esquema como contrato, `required` como guarda de último recurso.

### Ejercicio 6

**A26.** `helm dependency update` **lee `Chart.yaml`, re-resuelve los rangos de versión contra los repositorios, descarga los tarballs a `charts/`, y (sobre)escribe `Chart.lock`.** `helm dependency build` **lee `Chart.lock` y descarga exactamente las versiones fijadas**, negándose a correr si el lock está desincronizado con `Chart.yaml`. CI debe usar **`build`**: es reproducible — una dependencia declarada como `version: "^2.1.0"` va a traer silenciosamente 2.9.0 seis meses después bajo `update`, cambiando lo que se despacha sin ningún commit en tu repositorio. `update` es una acción humana deliberada y revisada que produce un diff de `Chart.lock`.

**A27.** `condition` es una **ruta dentro de los values del padre de nivel superior**, y el alias determina la clave bajo la cual viven los values de una dependencia. Con `alias: sessioncache`, los values del subchart están en `.Values.sessioncache`, así que la condición debe ser `sessioncache.enabled` — `cache.enabled` apunta a una clave que nadie lee. Para una segunda inclusión bajo `pagecache`, esa entrada necesita su propia `condition: pagecache.enabled` (cada entrada de dependencia lleva su propia condición), y ambas entradas nombran el mismo `name: cache` con alias distintos. Notá que `condition` acepta una lista separada por comas y **gana la primera ruta que resuelve a un booleano**, que es como los charts soportan a la vez un toggle nuevo y uno heredado: `condition: sessioncache.enabled,cache.enabled`.

**A28.** (1) A través de la clave del subchart: `--set web.image.repository=registry.example.com/web`, o el bloque equivalente en el `values.yaml` del padre. Esto siempre funciona — el bloque `<subchartname>:` del padre se fusiona sobre los defaults propios del subchart, y es el mecanismo sobre el que está construido el patrón paraguas. (2) A través de `global`: `--set global.imageRegistry=registry.example.com`, que se inyecta en **todos** los charts del árbol como `.Values.global.*`. Esto solo tiene efecto si el **autor del subchart escribió una plantilla que lo lee** (por ejemplo `{{ .Values.global.imageRegistry | default .Values.image.registry }}`); `global` es un mecanismo de propagación, no un override mágico. Los charts que lo soportan lo documentan explícitamente.

**A29.** Vendorizar los archivos `.tgz`: la build tiene **cero dependencia de red**, los bytes exactos están en tu VCS y son auditables en la revisión de código, y que un repositorio upstream desaparezca o que un mantenedor reemplace por la fuerza una versión no puede romperte ni cambiarte nada en silencio. Costo: binarios grandes en Git, diffs ruidosos, y drift fácil entre `Chart.yaml` y lo que efectivamente está vendorizado. Commitear solo `Chart.lock`: diffs chicos y legibles, y el digest igual fija exactamente lo que se resolvió — pero necesitás acceso de red a un repositorio vivo al momento de la build, y estás confiando en que el repositorio todavía sirva esos bytes. **Las builds air-gapped requieren los tarballs vendorizados** (o un repositorio/registro OCI interno espejado y poblado de antemano). Agregá `charts/*.tgz` a `.gitignore` solo si tenés ese espejo.

**A30.** Helm instala los archivos de `crds/` **solo en la primera instalación**, y nunca los actualiza ni los borra: en el upgrade el archivo nuevo de la CRD se ignora por completo, así que el campo agregado sigue sin estar disponible y cualquier CR que lo use es rechazado; en el uninstall la CRD y todos sus recursos personalizados quedan en su lugar. Esto es deliberado — borrar una CRD tiene efecto cascada sobre **todos los recursos personalizados del clúster**, incluidos los que pertenecen a otros releases, así que Helm se niega a tomar esa decisión. El procedimiento requerido es fuera de banda y explícito: `kubectl apply --server-side -f charts/<sub>/crds/` (o `kubectl replace -f`) **antes** de correr `helm upgrade`, idealmente como un paso pre-upgrade documentado en el runbook del release. Ver <https://helm.sh/docs/chart_best_practices/custom_resource_definitions/>.

### Ejercicio 7

**A31.** Un repositorio de charts debe servir exactamente dos cosas sobre HTTP(S): un **`index.yaml`** en la raíz del repositorio, y los **tarballs de los charts** en las URLs listadas en ese índice (pueden vivir en cualquier lado — S3, una CDN, otro host — porque cada entrada lleva `urls` absolutas). `helm repo add`/`update` descarga solamente `index.yaml`, que es la razón por la que es instantáneo sin importar la cantidad de charts y por la que `helm search repo` es una operación puramente local contra el índice cacheado. `helm install lpilab/web` después resuelve la versión en el índice cacheado a una entrada de `urls` y hace una **segunda** petición por el tarball en sí. Sin API del lado del servidor, sin base de datos, sin comportamiento dinámico — GitHub Pages o un bucket es una implementación completa. Ver <https://helm.sh/docs/topics/chart_repository/>.

**A32.** Los índices cacheados viven bajo `$HELM_REPOSITORY_CACHE`, por defecto `~/.cache/helm/repository/<name>-index.yaml`, con la lista de repositorios en `~/.config/helm/repositories.yaml`. `helm search repo` busca **solo en esas cachés locales** — es offline e instantáneo, y queda viejo hasta que corras `helm repo update`. `helm search hub` consulta la API de **Artifact Hub** por red a través de todos los repositorios públicos que *no* agregaste, devuelve una URL en lugar de una referencia `repo/chart` instalable, y por lo tanto te obliga a hacer `helm repo add` del repositorio descubierto antes de poder instalar desde él.

**A33.** (a) **Descubrimiento de versiones**: los repos HTTP enumeran cada versión en `index.yaml`, así que el cliente puede listarlas offline; OCI no tiene archivo de índice — las versiones son **tags** del registro, descubiertas por chart a través de la API de listado de tags del registro. (b) **Autenticación**: los repos HTTP usan basic auth o certificados de cliente configurados por repo en `repositories.yaml` (`--username/--password`); OCI usa el flujo de tokens estándar del registro vía `helm registry login`, que reutiliza las mismas credenciales e infraestructura que tus imágenes de contenedor (y `~/.docker/config.json`). (c) **`helm search repo` funciona solo para repositorios HTTP** — no hay nada que agregar ni cachear para OCI. La consecuencia: con OCI tenés que conocer de antemano la referencia completa del chart (`oci://host/path/name --version X`), así que el descubrimiento se muda de Helm a la UI del registro o a un catálogo como Artifact Hub, y los scripts que hacían `helm search repo | grep` hay que reescribirlos. Ver <https://helm.sh/docs/topics/registries/>.

**A34.** El archivo `.prov` es un **mensaje PGP firmado en claro** que contiene los metadatos de `Chart.yaml` del chart más un bloque `files:` con el SHA-256 del tarball; `helm verify` (o `helm install --verify`) chequea la firma contra tu keyring *y* recalcula el hash del tarball. Protege contra un mirror comprometido o un MITM porque esas partes no pueden producir una firma válida para bytes alterados. **No** protege contra un autor comprometido: si el atacante tiene la clave de firma, un chart malicioso queda firmado correctamente y verifica perfecto — provenance prueba *origen e integridad*, no *seguridad*. Para CI, la clave **pública** del firmante debe estar en un keyring que el runner pueda leer, pasado con `--keyring`; el error estándar es exportar el keyring *secreto* en su lugar, y el segundo error estándar es la incapacidad de Helm de leer el almacén `.kbx` de GnuPG 2.1+, que es la razón por la que el ejercicio corre primero `gpg --export`/`--export-secret-keys` hacia archivos `.gpg` heredados. Ver <https://helm.sh/docs/topics/provenance/>.

**A35.** Archivá: (1) el tarball exacto del chart `web-0.3.0.tgz` y su `.prov`; (2) todos los tarballs de dependencias — es decir, un chart empaquetado con `charts/` poblado, o los `charts/*.tgz` vendorizados más `Chart.lock`; (3) los archivos de values completos que se usaron, desde el control de versiones en el commit del release; (4) las **imágenes de contenedor** que el chart referencia, por digest, espejadas en tu propio registro (un chart es inútil si `nginx:1.27.2` fue re-etiquetada o borrada); y (5) la versión del cliente Helm utilizada. Reproducción futura: `helm verify web-0.3.0.tgz --keyring pub.gpg`, después `helm template web ./web-0.3.0.tgz -f values-prod.yaml` para comparar contra el manifiesto renderizado archivado, después `helm upgrade --install web ./web-0.3.0.tgz -f values-prod.yaml`. Fijá las imágenes por digest `@sha256:` en los values, no por tag — esa es la única parte de todo esto que es genuinamente inmutable.

### Ejercicio 8

**A36.** Para `helm upgrade`: `pre-upgrade` → (aplicar recursos) → `post-upgrade`. `--wait` se aplica **entre** la aplicación de recursos y `post-upgrade`: Helm espera a que los recursos del release estén listos antes de disparar los post hooks, y también espera a que el recurso propio de cada hook complete antes de avanzar al siguiente peso de hook. Conjunto completo de eventos: `pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-delete`, `post-delete`, `pre-rollback`, `post-rollback`, `test`. Si el upgrade falla durante la aplicación de recursos, `pre-upgrade` ya corrió y `post-upgrade` **no** corre — que es exactamente por qué una migración `pre-upgrade` debe ser idempotente y retrocompatible: el código nuevo puede no llegar nunca, y el código viejo sigue corriendo contra el esquema migrado.

**A37.** Los recursos de hook **no forman parte del manifiesto del release**, así que Helm no los considera contenido propiedad del release: se crean, se vigilan, y después se manejan puramente según `helm.sh/hook-delete-policy`. Con `hook-succeeded`, el Job se borra apenas completa, así que `helm uninstall` no encuentra nada que eliminar. Sin **ninguna** política de borrado, el default es `before-hook-creation` — el recurso queda en el clúster después de que el release completa y se borra solamente la próxima vez que corre el mismo hook. Ese remanente **no lo borra `helm uninstall`**, que es la fuente estándar de Jobs huérfanos y sus Pods acumulándose en un namespace mucho después de que el release desapareció. Si querés que un hook se limpie en ambos caminos, poné `hook-succeeded,hook-failed` (o `before-hook-creation,hook-succeeded`, conservando las fallas para depurar). Ver <https://helm.sh/docs/topics/charts_hooks/>.

**A38.** Los valores de anotación de Kubernetes deben ser strings. `-5` sin comillas renderiza como un entero YAML y el API server rechaza el objeto: `cannot unmarshal number into Go struct field ObjectMeta.metadata.annotations of type string`. Helm ordena los hooks por peso **ascendente** (los negativos primero) y los ejecuta en ese orden, esperando a que cada uno complete antes de arrancar el siguiente peso. Los empates se desempatan determinísticamente por **kind de recurso** (la lista de orden de instalación de Helm — Namespace, ResourceQuota, ... , ConfigMap, Secret, ... , Job, ...) y después por **nombre**, alfabéticamente. Nunca dependas del desempate; asigná pesos distintos cuando el orden importa.

**A39.** (1) **Instalada en la primera instalación** para que un chart que trae un operator funcione de entrada — la CRD debe existir antes de que se pueda aplicar cualquier CR de `templates/`, y `crds/` se aplica primero, en una pasada aparte, dándole tiempo al API server a registrarla. (2) **No actualizada en el upgrade** porque una actualización de CRD puede ser destructiva: angostar un esquema, quitar una versión servida, o cambiar la versión de almacenamiento puede volver ilegibles los recursos personalizados existentes en *todo el clúster*, incluidos CRs pertenecientes a otros releases. (3) **No borrada en el uninstall** porque borrar una CRD recolecta como basura cada CR de ese tipo a nivel de todo el clúster — una pérdida de datos irreversible y entre tenants disparada por quitar un release. Alternativas: **(a)** poner la CRD en `templates/` en su lugar, habitualmente detrás de `--set crds.install=true` y `helm.sh/resource-policy: keep`; ganás los upgrades y perdés el orden garantizado de Helm previo a `templates`, y arriesgás que dos releases se peleen por el mismo objeto de alcance de clúster. **(b)** Despachar un **Job hook `pre-upgrade`** que aplique las CRDs con `kubectl apply --server-side`; conseguís orden y upgrades pero el Job necesita RBAC de alcance de clúster, que es en sí mismo una superficie de escalación de privilegios. Muchos charts de producción eligen (c): un chart `<name>-crds` separado con su propio ciclo de vida de release.

**A40.** `helm test <rel> --timeout 5m` lo acota (por defecto 5 minutos); combinalo con `--logs` para que un timeout igual muestre la salida del Pod. Los tests de chart son hooks (`helm.sh/hook: test`) y no plantillas ordinarias porque deben quedar **excluidos del manifiesto del release** — un Pod de test no es parte de la aplicación desplegada y no debe ser creado por `helm install`, no debe ser reconciliado, y no debe aparecer en `helm get manifest` ni bloquear `helm upgrade`. Ser un hook le permite a `helm test` crearlos a demanda, esperar la fase del Pod, reportar Succeeded/Failed, y limpiar según `hook-delete-policy`. Ver <https://helm.sh/docs/topics/chart_tests/>.

### Ejercicio 9

**A41.** Helm 3 usa un **strategic merge patch a tres vías**, calculado a partir de: (1) el **manifiesto viejo** almacenado en el Secret del release, (2) el **manifiesto nuevo** recién renderizado, y (3) el **objeto vivo** leído del API server. `spec.replicas` era 3 en el manifiesto viejo y 3 en el nuevo, pero 0 en vivo — el campo lo gestiona el chart y el valor vivo diverge del valor declarado, así que el parche lo devuelve a 3. La anotación agregada a mano aparece **solo** en el objeto vivo; está ausente tanto del manifiesto viejo como del nuevo, así que Helm no tiene instrucción para quitarla y el parche la deja en paz. La regla general: Helm revierte el drift en los campos que declara, e ignora los campos que nunca declaró. (El merge a dos vías de Helm 2 comparaba solo el manifiesto viejo y el nuevo, así que no corregía las replicas.) Ver <https://helm.sh/docs/faq/changes_since_helm2/#improved-upgrade-strategy-3-way-strategic-merge-patches>.

**A42.** Si el chart siempre renderiza `spec.replicas: 3` mientras un HPA escaló el Deployment a 40 bajo carga, el próximo `helm upgrade` — incluso uno que no cambia nada más — parchea las replicas de vuelta a 3 y tira instantáneamente el 92% de la capacidad, en pleno tráfico. El HPA va a volver a escalar hacia arriba, pero solo a su propio ritmo, así que obtenés una ventana de caída real. El andamio lo evita **omitiendo el campo por completo** cuando el autoscaling está activo:
```yaml
{{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
{{- end }}
```
Un campo no declarado no es drift, así que el merge a tres vías deja intacto el valor del HPA. (El server-side apply con un field manager separado es la respuesta más nueva y general al mismo problema.)

**A43.** `pending-upgrade` significa que Helm escribió un registro de release nuevo marcado como "en progreso" y después **murió antes de terminar** — matado, partición de red, timeout de CI. En la siguiente invocación Helm ve un estado no terminal y se niega con `another operation is in progress`, porque no puede distinguir tu corrida interrumpida de una concurrente que todavía está trabajando; `helm rollback` se niega por la misma razón. Borrar el Secret de release más nuevo elimina el registro en progreso, así que la revisión `deployed` anterior pasa a ser la más alta y la vista de Helm vuelve a ser consistente. El riesgo de borrar el Secret equivocado: si borrás la última revisión **`deployed`** en lugar de la pendiente, destruís el registro de lo que efectivamente está corriendo — el próximo upgrade de Helm calcula su parche a tres vías desde un manifiesto más viejo y va a borrar contento recursos que agregó la revisión (ahora olvidada). Confirmá siempre con `kubectl get secret -l owner=helm,name=<rel> -L version,status` antes de borrar, y borrá exactamente la `pending-*`. Verificá primero que ningún otro proceso esté genuinamente a mitad de un upgrade.

**A44.** `--force` hace que Helm use semántica de **`replace`** (un PUT completo del objeto / borrar-y-recrear) en lugar de un parche. Sobre campos inmutables "funciona" destruyendo y recreando el objeto en lugar de fallar. Dos casos de caída visible: (1) **Service** — un recreate elimina el objeto, así que su `spec.clusterIP` y los Endpoints/NodePort asociados se reasignan; todo cliente que cachea esa IP, más cualquier DNS externo o regla de firewall fijada a ese NodePort, se rompe. (2) **Deployment/StatefulSet con un `spec.selector` cambiado** (inmutable) — Helm borra el controlador, lo que con la cascada por defecto se lleva todos sus Pods, así que la carga de trabajo baja a cero replicas y se reconstruye desde cero; para un StatefulSet esto además implica un reinicio ordenado, uno por uno, de los miembros con estado. `--force` no es un arreglo para un release trabado — es una forma de convertir "Helm se negó" en "Helm borró producción".

**A45.** El default es `--history-max 10` (0 significa ilimitado). Con 300 releases e historial sin límite, cada revisión es un Secret que contiene el manifiesto comprimido completo — unos cientos de KB cada uno para un chart no trivial — así que etcd crece hasta los gigabytes, `kubectl get secrets -A` se vuelve lento, y las cachés de watch del API server y los backups crecen con él; la falla práctica es que etcd exceda su `--quota-backend-bytes` y quede en solo lectura a nivel de todo el clúster. Lo que perdés cuando la ventana recorta: `helm rollback <rel> <n>` para un `n` recortado devuelve `Error: release: not found` — ya no podés volver a ese estado con Helm, y tenés que reconstruirlo reinstalando la versión del chart y los values correspondientes desde Git. Ese es el argumento real para mantener la versión del chart + los values en control de versiones: la retención de historial es una caché, no un backup.

**A46.** (1) **Visibilidad en `helm list`**: un uninstall común elimina el release por completo — no aparece en ningún lado; con `--keep-history` aparece bajo `helm list --uninstalled` (o `--all`) con estado `uninstalled`. (2) **Reutilización del nombre**: después de un uninstall común el nombre queda libre inmediatamente; con `--keep-history` el nombre sigue tomado, y `helm install <same-name>` falla con `cannot re-use a name that is still in use` — tenés que hacer `helm uninstall` de nuevo (sin el flag) primero. (3) **Rollback**: imposible después de un uninstall común (no hay registros); posible con `--keep-history` — `helm rollback <rel> <rev>` recrea los recursos desde el manifiesto conservado, que es la única forma soportada de deshacer un uninstall accidental.

### Ejercicio 10

**A47.** El mecanismo es el **configMapGenerator** de Kustomize (y `secretGenerator`), que anexa un **hash del contenido** al nombre del objeto y reescribe cada referencia a él — `configMapRef`, `volumes[].configMap`, `env.valueFrom.configMapKeyRef` — a lo largo de todo el conjunto renderizado. Cambiar un literal cambia el hash, que cambia el nombre, que cambia la plantilla del Pod, que fuerza un rolling update; y es atómico, porque el ConfigMap nuevo existe antes de que los Pods nuevos lo referencien. Un chart de Helm común logra el mismo efecto con la anotación **`checksum/config`** en la plantilla del Pod construida en el Ejercicio 5: `{{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`. La diferencia es que Helm muta el ConfigMap en el lugar (así que un rollback del Deployment no hace rollback del ConfigMap), mientras que Kustomize crea un objeto inmutable nuevo por cada versión del contenido.

**A48.** `kubectl apply -k` aplica el conjunto renderizado; no tiene memoria de lo que contenía un render anterior, así que un objeto que desaparece de la salida simplemente no vuelve a mencionarse nunca y se queda en el clúster. El flag es **`--prune`** (con `-l <selector>` o, mejor, `--prune-allowlist`/`--applyset`), que borra los recursos que coinciden con el selector y no están en el apply actual. Es peligroso porque el pruning está guiado por un **selector de labels, no por propiedad**: un selector demasiado amplio borra objetos creados por otros overlays, por otras herramientas, o a mano, y un render temporalmente incompleto (una entrada `resources:` con un typo) poda objetos sanos de producción. Esta es la mayor ventaja estructural que Helm tiene sobre Kustomize crudo: el registro del release hace que la eliminación sea explícita y acotada.

**A49.** Helm resuelve la configuración en **tiempo de renderizado**, ejecutando un programa de plantillas Go Turing-completo sobre un árbol de values. Kustomize la resuelve en **tiempo de overlay**, fusionando y parcheando estructuralmente YAML completo y ya válido. Consecuencias — dos cosas que Kustomize estructuralmente no puede hacer: (1) **emitir condicionalmente un recurso entero según un flag** (`if .Values.ingress.enabled`) — un overlay puede parchear o excluir un recurso editando `resources:`, pero no hay generación guiada por booleanos; (2) **computar valores** — sin bucles sobre una lista para generar N objetos, sin funciones de string, sin `randAlphaNum`, sin `lookup`. Una clase de bug que no puede tener: **renderizar YAML inválido**. Cada entrada y cada salida es YAML parseable en cada paso, así que los bugs de indentación, los bugs de recorte de espacios en blanco, y los de "el mapa se volvió un string" — toda la familia `nindent`/`toYaml` del Ejercicio 5 — no existen. Kustomize tampoco puede despachar un *artefacto empaquetado, versionado y descubrible* como lo hace un repositorio de charts, que es la otra mitad de "gestión de paquetes".

**A50.** (a) **Procedencia**: solo mediante labels que vos mismo pusiste — `labels:`/`commonLabels` en el overlay, más convenciones de `namePrefix`. Nada es automático; `app.kubernetes.io/managed-by` no tiene equivalente. (b) **Rollback**: `git revert` del commit del overlay y volver a correr `kubectl apply -k` — el estado vive en el control de versiones, no en el clúster. Esto es estrictamente basado en Git, que es la razón por la que Kustomize se empareja naturalmente con un controlador GitOps (Argo CD, Flux) que almacena el historial de sincronización y provee una UI de rollback. (c) `helm history` queda reemplazado por el **log de Git** del directorio del overlay, más `kubectl rollout history` para las revisiones por carga de trabajo. El intercambio es explícito: Helm mantiene estado operativo en el clúster; Kustomize lo mantiene todo en Git y no tiene nada que pueda quedar trabado en `pending-upgrade`.

**A51.** `kubectl` **vendoriza** una versión específica de Kustomize, y va atrás del binario standalone — muchas veces por varios releases. Modo de falla: un desarrollador escribe una kustomization usando un campo o un transformer presente solo en v5.5.0, la verifica con `kustomize build`, la commitea, y el runner de CI (u otro desarrollador, o el controlador GitOps del clúster) usa `kubectl apply -k` con la versión embebida más vieja, que o bien da error por un campo desconocido o — peor — lo **ignora silenciosamente**, produciendo un manifiesto que parece válido pero está mal. Regla del README: *"Renderizá y aplicá siempre con el binario `kustomize` standalone fijado en `.tool-versions`: `kustomize build overlays/prod | kubectl apply -f -`. Nunca uses `kubectl apply -k`."* Fijá la misma versión en CI y en el controlador GitOps.

**A52.** Un **post-renderer** es un ejecutable que recibe el manifiesto renderizado de Helm por stdin y devuelve el manifiesto modificado por stdout; Helm entonces aplica *eso* y lo almacena en el registro del release. Es más seguro que forkear un chart upstream porque seguís rastreando upstream: hacer `helm upgrade` a una versión nueva del chart no cuesta nada, no hay conflicto de merge, y tu modificación es un parche chico y revisable que expresa exactamente tu delta — el uso clásico siendo inyectar una anotación, un sidecar o un nodeSelector que el chart no parametriza. Lo que **no** te deja cambiar: cualquier cosa que Helm resuelve *antes* de renderizar — la validación de `values.schema.json` del chart, las fallas de `required`, el *agendamiento* de hooks (Helm extrae los hooks del manifiesto y no forman parte de lo que los cambios del post-renderer afectan sobre el release aplicado de la misma manera), y las CRDs en `crds/`, que evitan por completo el pipeline de plantillas. Si el chart se niega a renderizar tus values, ningún post-renderer puede ayudar. Ver <https://helm.sh/docs/topics/advanced/#post-rendering>.

</details>

---

## Fuentes

- LPI Exam 701 Objectives, version 2.0 — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Helm — Charts — <https://helm.sh/docs/topics/charts/>
- Helm — Chart Template Guide — <https://helm.sh/docs/chart_template_guide/>
- Helm — Chart Repository Guide — <https://helm.sh/docs/topics/chart_repository/>
- Helm — OCI Registries — <https://helm.sh/docs/topics/registries/>
- Helm — Chart Hooks — <https://helm.sh/docs/topics/charts_hooks/>
- Helm — Chart Tests — <https://helm.sh/docs/topics/chart_tests/>
- Helm — Library Charts — <https://helm.sh/docs/topics/library_charts/>
- Helm — Provenance and Integrity — <https://helm.sh/docs/topics/provenance/>
- Helm — Advanced Topics (storage backends, post-rendering) — <https://helm.sh/docs/topics/advanced/>
- Helm — Changes Since Helm 2 (three-way merge, no Tiller) — <https://helm.sh/docs/faq/changes_since_helm2/>
- Helm — Custom Resource Definitions best practice — <https://helm.sh/docs/chart_best_practices/custom_resource_definitions/>
- Helm — Version Support Policy — <https://helm.sh/docs/topics/version_skew/>
- Kubernetes — Declarative Management using Kustomize — <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
- Kustomize — Kustomization file reference — <https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/>