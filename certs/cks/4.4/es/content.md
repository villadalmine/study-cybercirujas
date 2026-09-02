# CKS 4.4 — Realizar análisis estático de cargas de trabajo de usuario e imágenes de contenedor

**Certificación:** Certified Kubernetes Security Specialist (CKS) — versión de examen 1.34
**Dominio:** Supply Chain Security (20%) · **Peso del tema:** 5
**Perfil:** Principal Platform Architect / Senior SRE

> **Cómo leer las transcripciones de terminal de este documento.** Fueron producidas con `kubesec v2.14.x`, `kube-linter v0.7.x`, `trivy v0.6x.x`, `hadolint v2.12.x` y `conftest v0.5x.x` contra Kubernetes v1.34. Los identificadores de reglas, los totales de puntos y la redacción cambian entre versiones de estas herramientas. **Confiá siempre en la salida del binario que tenés delante por encima de cualquier tabla impresa acá** — cada herramienta de este documento autodocumenta su conjunto de reglas (`kubesec scan` imprime `reason` y `points` en línea; `kube-linter checks list` imprime el catálogo completo). El examen se ejecuta contra un clúster específico y binarios específicos; la habilidad que se evalúa es *leer la salida propia de la herramienta y remediar*, no memorizar valores de puntos.

---

## 1. El problema arquitectónico: por qué existe el análisis estático

### 1.1 El modo de fallo contra el que se defiende

Un `PodSpec` de Kubernetes es un **formulario de solicitud de privilegios**. Es un documento declarativo en el que un desarrollador, sin derechos de cluster-admin, le pide al kubelet que ejecute un proceso con una relación particular con el kernel del host. Todo lo que importa para un escape de contenedor es expresable en ese YAML:

| Campo | Qué hace realmente el kernel |
|---|---|
| `securityContext.privileged: true` | El contenedor se ejecuta con **todas** las capabilities, un perfil de AppArmor/SELinux sin confinar, `/proc` y `/sys` sin enmascarar y acceso completo a dispositivos vía el cgroup de devices. Efectivamente `root` en el nodo. |
| `securityContext.capabilities.add: ["SYS_ADMIN"]` | `CAP_SYS_ADMIN` permite `mount(2)`, `setns(2)`, `pivot_root(2)`, escrituras en cgroups — la capability más abusada para escapes. |
| `hostPID: true` | El contenedor comparte el namespace de PID 1 con el nodo. `/proc/<pid>/root/` da el sistema de archivos de **todos los demás contenedores del nodo**, y `nsenter -t 1 -m -u -i -n -p` es una shell en el host. |
| `hostNetwork: true` | Elude toda `NetworkPolicy` (la aplicación por el CNI tiene alcance de namespace), expone el loopback del nodo — el puerto de solo lectura del kubelet, los metadatos del cloud vía link-local, el puerto de cliente de `etcd` en los nodos del plano de control. |
| `hostIPC: true` | IPC SysV / memoria compartida POSIX compartidas con los procesos del host. |
| `volumes[].hostPath: /var/run/docker.sock` (o `/run/containerd/containerd.sock`) | Acceso directo a la API del runtime de contenedores — lanza trivialmente un contenedor privilegiado con `/` montado por bind. |
| `allowPrivilegeEscalation: true` (el valor **por defecto** cuando no se define) | El bit `no_new_privs` **no** se establece → los binarios setuid y las file capabilities dentro de la imagen pueden elevar privilegios más allá del conjunto inicial del contenedor. |

Ninguno de estos es exótico. Son ediciones de una línea en un Deployment, se renderizan perfectamente en `helm template`, pasan `kubectl apply --dry-run=client`, y serán aceptados por un clúster sin endurecer sin una sola advertencia.

### 1.2 Dónde tiene que estar el control

Hay exactamente cuatro lugares donde se puede atrapar un `PodSpec` peligroso, y tienen propiedades muy distintas:

```
   Developer          Git / CI                  API server                 Node
   ─────────          ────────                  ──────────                 ────
   IDE plugin   →   static analysis      →   admission control     →   runtime detection
   pre-commit       (kubesec, kube-linter,    (PSA, ValidatingAdmission   (Falco, Tetragon,
                     kube-score, conftest,     Policy, Kyverno,            eBPF, audit logs)
                     trivy config, Checkov)    Gatekeeper)

   cost to fix:  $           $$                    $$$                      $$$$$
   coverage:     what is in the repo               what reaches the API     what actually ran
   bypassable:   trivially (skip CI)               no (if failurePolicy=Fail) no
   feedback:     seconds, in the PR                minutes, at deploy        after the incident
```

**El análisis estático es la capa barata, rápida y de gran volumen — y es consultiva por construcción.** Cualquiera con `kubectl` y RBAC puede hacer `kubectl apply -f` de un manifiesto que nunca pasó por tu pipeline. Ese es el punto arquitectónico más importante de este tema:

> El análisis estático te compra **latencia de feedback para el desarrollador y amplitud**. **No** te compra aplicación efectiva. La aplicación es el control de admisión. Una plataforma de producción ejecuta ambos, y las verificaciones de CI deben ser un *subconjunto* de lo que aplica el control de admisión — de lo contrario el pipeline queda en verde y el deploy falla a las 02:00.

El corolario que los equipos de plataforma hacen mal: **no dejes que ambos se separen.** Si `kube-linter` en CI exige `readOnlyRootFilesystem` pero la `ValidatingAdmissionPolicy` del clúster no, le enseñaste a los desarrolladores que el linter es ruido. Si el control de admisión exige algo que CI no verifica, cada rollout es una moneda al aire. El conjunto de políticas es un artefacto, expresado dos veces, y las dos expresiones se prueban contra el mismo corpus de manifiestos.

### 1.3 Lo que el análisis estático estructuralmente no puede ver

Esta es la limitación relevante para SRE y una trampa favorita de entrevistas/exámenes:

1. **Admisión mutante.** El manifiesto en Git no es el manifiesto que se ejecuta. Los inyectores de sidecars (Istio, Linkerd), los mutadores estilo `PodPreset`, las reglas `mutate` de Kyverno y los webhooks de defaulting agregan contenedores *después* de que tu escáner ya aprobó el archivo. Un sidecar inyectado que corre como UID 0 con `NET_ADMIN` nunca aparece en el repositorio.
2. **Defaulting del API server.** `allowPrivilegeEscalation` sin definir no es `false`. `readOnlyRootFilesystem` sin definir no es `true`. Las herramientas estáticas que solo verifican campos *explícitos* y el clúster que los *establece por defecto* no coinciden.
3. **Estado referenciado.** Un manifiesto con `serviceAccountName: builder` se ve bien. Si `builder` está vinculado a `cluster-admin` vive en un `ClusterRoleBinding` en otro repositorio. Escanear el directorio completo ayuda; entre repositorios no existe.
4. **Comportamiento en runtime.** Un `PodSpec` perfectamente endurecido que ejecuta una imagen comprometida sigue estando comprometido. El escaneo de *vulnerabilidades* de imágenes es un control hermano (CKS "scan images for known vulnerabilities" / Trivy); el *análisis estático de imágenes* acá significa la **configuración y la receta de build** de la imagen: `USER`, puertos expuestos, `ENTRYPOINT`, secretos embebidos, higiene de capas.
5. **Plantillas.** `kube-linter` no puede analizar el `{{ .Values.securityContext }}` de un chart de Helm. Hay que renderizarlo primero, con *los valores usados en producción*. Escanear los valores por defecto de `values.yaml` mientras producción usa `values-prod.yaml` es una falsa sensación de seguridad.

La mitigación para (1) y (2) es una técnica que la mayoría de los equipos nunca adopta, y vale la pena integrarla en tu pipeline (Sección 8.4): **escaneá la salida del dry-run del lado del servidor, no el archivo fuente.**

---

## 2. Panorama de herramientas y compromisos

### 2.1 Categorías

| Categoría | Entrada | Herramientas representativas | Qué responde |
|---|---|---|---|
| Análisis de manifiestos de carga de trabajo | YAML de `Pod`/`Deployment`/`DaemonSet` | **kubesec**, **KubeLinter**, kube-score, Polaris | "¿Esta carga de trabajo pide más privilegios de los que necesita?" |
| Malas configuraciones genéricas de IaC | YAML de K8s, Helm, Terraform, CloudFormation, Dockerfile | **Checkov**, **Trivy `config`**, Terrascan, Snyk IaC | "¿Esta infraestructura viola un catálogo amplio de reglas?" |
| Policy-as-code (personalizado) | Cualquier documento estructurado | **conftest/OPA (Rego)**, Kyverno CLI, `cel` vía VAP | "¿Esto viola *nuestras* reglas específicas de la organización?" |
| Linting de Dockerfile | `Dockerfile` | **hadolint** | "¿La receta de build es sólida y reproducible?" |
| Análisis de configuración de imagen | Imagen OCI (config + capas, sin base de datos de CVE) | **dockle**, `trivy image --image-config-scanners` | "¿El artefacto construido corre como root, transporta secretos, expone SSH?" |

### 2.2 kubesec vs KubeLinter — las dos nombradas en el temario

| Dimensión | **kubesec** | **KubeLinter** |
|---|---|---|
| Origen / mantenedor | ControlPlane | StackRox → Red Hat (open source) |
| Modelo | **Puntuación**: cada regla coincidente suma o resta puntos; un manifiesto obtiene un único entero | **Motor de reglas**: cada verificación pasa o falla de forma independiente; produce una lista de violaciones |
| Semántica del veredicto | `score >= threshold` → pasa. Matizado, comparable en el tiempo | Cualquier violación → exit 1. Binario, sin ambigüedad |
| Alcance | Solo seguridad, solo tipos de carga de trabajo (`Pod`, `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController`, `Job`, `CronJob`) | Seguridad **y** fiabilidad/corrección (`Service` colgante, selectores desacoplados, probes faltantes, APIs obsoletas), en muchos tipos incluyendo RBAC, `Ingress`, `NetworkPolicy` |
| Extensibilidad | **Ninguna.** Las reglas están compiladas en el binario | **De primera clase.** Los `customChecks` en YAML instancian *plantillas* integradas con parámetros; las verificaciones se pueden incluir/excluir/acotar |
| Supresión por objeto | No | Sí — anotación `ignore-check.kube-linter.io/<check>: "reason"` en el objeto |
| Formatos de salida | `json` (por defecto), `template` de Go | `plain`, `json`, `sarif` |
| Modos de despliegue | CLI, imagen Docker, **servidor HTTP** (`kubesec http 8080`), webhook de admisión (`kubesec-webhook`) | CLI, imagen Docker, GitHub Action |
| Rol típico en CI | Compuerta de puntuación + priorización legible ("¿qué es lo peor que hay acá?") | Compuerta dura ("esto no puede mergearse") |
| Puntos ciegos | Ignora por completo los tipos que no son cargas de trabajo; el conjunto de reglas va por detrás de la API (ver 3.4); sin verificaciones de probes/fiabilidad | El conjunto de verificaciones por defecto es pequeño; `--add-all-built-in` cambia el comportamiento drásticamente (ver 4.3) |

**Recomendación arquitectónica.** Son complementarias, no competidoras. Ejecutá **KubeLinter como la compuerta bloqueante** (determinista, extensible, suprimible con una anotación auditada) y **kubesec como la capa de reporte/priorización** (una puntuación que podés graficar por servicio en un dashboard y usar para ordenar el backlog de remediación). Ambas son lo bastante rápidas como para correr en cada push.

### 2.3 Comparación más amplia

| Herramienta | Reglas | Política personalizada | Velocidad | Multiformato | Mejor para |
|---|---|---|---|---|---|
| kubesec | ~20, solo seguridad | ✗ | Muy rápida (ms) | ✗ | Puntuación, triaje rápido, trabajo de examen |
| KubeLinter | ~60 verificaciones integradas / ~30 plantillas | ✓ (plantillas + parámetros) | Muy rápida | ✗ (solo YAML de K8s) | Compuerta de merge |
| kube-score | ~30, seguridad + fiabilidad | ✗ (anotaciones opcionales para omitir) | Rápida | ✗ | Revisión previa al despliegue, legible para humanos |
| Polaris | ~30, severidades configurables | ✓ (JSON Schema / verificaciones personalizadas) | Rápida | ✗ | Dashboard + auditoría de todo el clúster de cargas de trabajo *en ejecución* |
| Trivy `config` | Muchas (construidas sobre Rego, IDs de AVD) | ✓ (Rego) | Rápida | ✓ Terraform, CFN, Helm, Dockerfile, K8s | Un solo binario para toda la cadena de suministro |
| Checkov | Muchísimas (1000+) | ✓ (Python + YAML) | Más lenta (Python) | ✓ | Mapeo de cumplimiento (CIS, NIST, PCI) |
| conftest / OPA | Cero integradas | ✓ Rego, ilimitadas | Rápida | ✓ cualquier formato parseable | Invariantes específicas de la organización |
| hadolint | ~100 `DL*` + ShellCheck | ✓ (lista de ignorados, registries de confianza) | Muy rápida | Solo Dockerfile | Higiene de la receta de build |
| dockle | Subconjunto del CIS Docker Benchmark | ✗ | Rápida | Solo imagen | Compuerta de configuración de imagen posterior al build |

> **Datree** aparece en material de estudio antiguo de CKS. El servicio alojado se discontinuó en 2023 tras la adquisición de Datree; no construyas un pipeline sobre él. Su nicho (policy-as-code con un catálogo de reglas gestionado) está cubierto por KubeLinter + conftest o por Kyverno CLI.

---

## 3. kubesec en profundidad

### 3.1 Mecánica

kubesec parsea el documento YAML/JSON, recorre el `PodSpec` (desenvolviendo `.spec.template.spec` para los tipos controlador) y evalúa una lista fija de reglas. Cada regla es un selector más un valor en puntos. La puntuación final es la **suma de los puntos de cada regla que coincidió**. Las reglas que *no* coincidieron pero habrían sumado puntos se reportan bajo `advise` — esa lista es tu TODO de remediación, ordenado por valor.

Tres grupos en la salida:

- **`critical`** — reglas coincidentes con grandes puntos negativos. Son peligros activos presentes en el manifiesto.
- **`passed`** — reglas coincidentes con puntos positivos. Endurecimiento que ya hiciste.
- **`advise`** — reglas positivas no coincidentes. Endurecimiento que todavía no hiciste.

### 3.2 Catálogo de reglas (abreviado; la lista autorizada es `kubesec.io/rules` y la salida de tu binario)

| Selector | Motivo | Puntos |
|---|---|---|
| `containers[] .securityContext .privileged == true` | Los contenedores privilegiados pueden permitir un acceso al host casi completamente irrestricto | **−30** |
| `containers[] .securityContext .capabilities .add == "SYS_ADMIN"` | `CAP_SYS_ADMIN` es la capability más privilegiada y siempre debería evitarse | **−30** |
| `.spec .hostPID` | Compartir el namespace de PID del host permite ver los procesos del host | **−30** |
| `.spec .hostIPC` | Compartir el namespace de IPC del host permite que los procesos del contenedor se comuniquen con los procesos del host | **−30** |
| `.spec .hostNetwork` | Compartir el namespace de red del host permite que los procesos del pod se comuniquen con procesos vinculados al adaptador de loopback del host | **−9** |
| `.spec .volumes[] .hostPath .path == "/var/run/docker.sock"` | Montar el socket de docker filtra información sobre otros contenedores y puede permitir un escape del contenedor | **−9** |
| `containers[] .securityContext .runAsNonRoot == true` | Forzar que la imagen en ejecución corra como un usuario no root para asegurar el mínimo privilegio | **+1** |
| `containers[] .securityContext .runAsUser > 10000` | Ejecutar como un usuario con UID alto para evitar conflictos con la tabla de usuarios del host | **+1** |
| `containers[] .securityContext .readOnlyRootFilesystem == true` | Un sistema de archivos raíz inmutable puede evitar que se agreguen binarios maliciosos al `PATH` y aumenta el costo del ataque | **+1** |
| `containers[] .securityContext .capabilities .drop` | Reducir las capabilities del kernel disponibles para un contenedor limita su superficie de ataque | **+1** |
| `containers[] .securityContext .capabilities .drop \| index("ALL")` | Descartar todas las capabilities y agregar solo las requeridas para reducir la superficie de ataque de syscalls | **+1** |
| `containers[] .resources .limits .cpu` | Aplicar límites de CPU previene DoS por agotamiento de recursos | **+1** |
| `containers[] .resources .limits .memory` | Aplicar límites de memoria previene DoS por agotamiento de recursos | **+1** |
| `containers[] .resources .requests .cpu` | Aplicar requests de CPU ayuda a un balance justo de recursos en el clúster | **+1** |
| `containers[] .resources .requests .memory` | Aplicar requests de memoria ayuda a un balance justo de recursos en el clúster | **+1** |
| `.spec .serviceAccountName` | Las service accounts restringen el acceso a la API de Kubernetes y deberían configurarse con mínimo privilegio | **+1** |
| `.metadata .annotations ."container.seccomp.security.alpha.kubernetes.io/pod"` | Los perfiles de seccomp establecen el mínimo privilegio y protegen contra amenazas desconocidas | **+1** |
| `.metadata .annotations ."container.apparmor.security.beta.kubernetes.io/<container>"` | Políticas de AppArmor bien definidas pueden brindar mayor protección frente a amenazas desconocidas | **+3** |

### 3.3 Superficie de CLI

```
$ kubesec scan --help
Scan a Kubernetes resource file or directory

Usage:
  kubesec scan <file> [flags]

Flags:
      --absolute-scoring   Use absolute scoring, instead of relative to the maximum achievable score
      --debug              Log debug output
      --exit-code int      Set the exit code to use on scanning failure (default 2)
      --format string      Set output format (json|template) (default "json")
  -h, --help               help for scan
      --template string    Set output template, it will be used when --format is set to template
      --threshold int      Set the score threshold to fail the scan
```

```
$ kubesec version
2.14.2

$ kubesec http 8080 &
[1] 41522
{"severity":"info","timestamp":"2026-08-04T09:11:02Z","message":"Starting kubesec HTTP server on port 8080"}

$ curl -sSX POST --data-binary @bad-deployment.yaml http://localhost:8080/scan | jq '.[0].score'
-99
```

Forma en contenedor — el patrón a usar cuando el nodo del examen no tiene el binario `kubesec` pero sí tiene un runtime y acceso a la red, y el patrón para CI hermético:

```
$ docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < bad-deployment.yaml
```

### 3.4 La trampa del retraso de la herramienta (insight de producción de alto valor)

Las reglas de seccomp y AppArmor de kubesec coinciden con **anotaciones**:

- `seccomp.security.alpha.kubernetes.io/pod` — la anotación *alpha*, eliminada de Kubernetes en v1.25.
- `container.apparmor.security.beta.kubernetes.io/<name>` — la anotación *beta*, obsoleta desde v1.30, cuando `securityContext.appArmorProfile` pasó a beta (GA en v1.31).

Un manifiesto escrito correctamente para Kubernetes 1.34 —

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
  appArmorProfile:
    type: RuntimeDefault
```

— puede puntuar **más bajo** en kubesec que un manifiesto que lleva anotaciones obsoletas que el API server ya no respeta. Este es el ejemplo canónico de por qué una puntuación es una *heurística*, no un veredicto de cumplimiento.

**Cómo manejarlo en producción:**

1. **No** agregues anotaciones muertas para inflar la puntuación. Estarías enviando una mentira.
2. Establecé el umbral de CI a partir de una línea base medida de tu propio manifiesto de referencia endurecido, no de un número absoluto copiado de un blog.
3. Cubrí la brecha con una herramienta que lea los campos modernos — una verificación personalizada de `kube-linter`, una regla de conftest o (lo mejor) la `ValidatingAdmissionPolicy` de la Sección 7.2.
4. Recalibrá la línea base del umbral cuando actualices kubesec.

---

## 4. KubeLinter en profundidad

### 4.1 Mecánica

KubeLinter tiene tres conceptos:

- **Plantilla (template)** — una implementación parametrizada de una clase de verificación (`required-label`, `privileged`, `resources`, `env-var`, `host-mounts`, `verify-container-capabilities`, `read-only-root-fs`, `latest-tag`, `anti-affinity`, `dangling-service`, …). Listalas con `kube-linter templates list`.
- **Verificación (check)** — una plantilla instanciada con parámetros concretos, un nombre, una descripción, un texto de remediación y un **alcance** (a qué tipos de objeto se aplica). Las verificaciones integradas son instanciaciones ya provistas; los `customChecks` son tuyos.
- **Conjunto por defecto** — el subconjunto de verificaciones integradas habilitadas cuando no pasás configuración. **Es mucho más pequeño que el catálogo completo.**

### 4.2 Superficie de CLI

```
$ kube-linter version
0.7.6

$ kube-linter lint --help
Lint Kubernetes YAML files and Helm charts

Usage:
  kube-linter lint [PATH...] [flags]

Flags:
      --config string        Path to config file
      --do-not-verify-tls    If set, don't verify TLS certificates
      --fail-if-no-objects-found   Fail if no valid objects are found
      --fail-on-invalid-resource   Fail if an invalid resource is found
      --format string        Output format (plain|json|sarif) (default "plain")
  -h, --help                 help for lint
      --include-checks strings   List of checks to include
      --exclude-checks strings   List of checks to exclude
      --add-all-built-in     Add all built-in checks
      --do-not-auto-add-defaults   Do not auto-add default checks
```

```
$ kube-linter checks list | head -40
Name: access-to-create-pods
Description: Indicates when a subject (Group/User/ServiceAccount) has create access to Pods.
Remediation: Where possible, remove create access to pods.
Template: access-to-resources
Parameters: ...
Enabled by default: false

Name: dangling-service
Description: Indicates when services do not have any associated deployments.
Remediation: Confirm that your service's selector correctly matches the labels on one of your deployments.
Template: dangling-service
Enabled by default: true

Name: drop-net-raw-capability
Description: Indicates when containers do not drop NET_RAW capability
Remediation: NET_RAW makes it so that an application within the container is able to craft raw packets, use raw sockets, and bind to any address. Remove this capability in the containers under containers security contexts.
Template: verify-container-capabilities
Enabled by default: true
...
```

> **Hábito de examen:** `kube-linter checks list | grep -A5 '^Name: <something>'` es más rápido que cualquier búsqueda en la documentación, y `kube-linter checks list` incluye el texto exacto de remediación que necesitás.

### 4.3 La trampa del conjunto por defecto

```
$ kube-linter lint bad-deployment.yaml | tail -1
Error: found 9 lint errors

$ kube-linter lint --add-all-built-in bad-deployment.yaml | tail -1
Error: found 21 lint errors
```

Doce hallazgos reales adicionales — `host-network`, `host-pid`, `latest-tag`, `unsafe-proc-mount`, `privileged-ports`, `no-liveness-probe`, `no-readiness-probe` y otros — son invisibles en la ejecución por defecto. **Nunca envíes un pipeline que dependa del conjunto por defecto implícito.** Comprometé un `.kube-linter.yaml` explícito (Sección 6.1) para que las reglas habilitadas sean revisables, comparables y versionadas junto con los manifiestos que gobiernan.

### 4.4 Supresión, hecha de forma responsable

```yaml
metadata:
  annotations:
    ignore-check.kube-linter.io/no-read-only-root-fs: >-
      The embedded SQLite WAL requires writes to /var/lib/app; the path is a
      dedicated PVC and the rest of the filesystem is covered by a
      ValidatingAdmissionPolicy. Ticket PLAT-4471, review 2027-02-01.
```

El valor de la anotación es texto libre, y ese es el punto: **hacé que la justificación y su vencimiento formen parte del manifiesto**, para que aparezcan en la revisión de código y en auditorías con `grep -r ignore-check`. Una supresión sin ticket y sin fecha es un hallazgo en sí misma — agregá ese grep a la revisión mensual de tu plataforma.

---

## 5. Ejemplo trabajado: de −99 a endurecido

### 5.1 El manifiesto tal como lo recibió el equipo de aplicación

`manifests/bad-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      hostNetwork: true
      hostPID: true
      containers:
        - name: app
          image: registry.internal/payments:latest
          ports:
            - containerPort: 8080
          env:
            - name: DB_PASSWORD
              value: "s3cr3t-plaintext"
          securityContext:
            privileged: true
            capabilities:
              add:
                - SYS_ADMIN
                - NET_RAW
```

### 5.2 Veredicto de kubesec

```
$ kubesec scan manifests/bad-deployment.yaml
[
  {
    "object": "Deployment/payments.payments",
    "valid": true,
    "fileName": "manifests/bad-deployment.yaml",
    "message": "Failed with a score of -99 points",
    "score": -99,
    "scoring": {
      "critical": [
        {
          "id": "Privileged",
          "selector": "containers[] .securityContext .privileged == true",
          "reason": "Privileged containers can allow almost completely unrestricted host access",
          "points": -30
        },
        {
          "id": "CapSysAdmin",
          "selector": "containers[] .securityContext .capabilities .add == SYS_ADMIN",
          "reason": "CAP_SYS_ADMIN is the most privileged capability and should always be avoided",
          "points": -30
        },
        {
          "id": "HostPID",
          "selector": ".spec .hostPID == true",
          "reason": "Sharing the host's PID namespace allows visibility on host processes, potentially leaking information such as environment variables and configuration",
          "points": -30
        },
        {
          "id": "HostNetwork",
          "selector": ".spec .hostNetwork == true",
          "reason": "Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter",
          "points": -9
        }
      ],
      "passed": [],
      "advise": [
        {
          "id": "ApparmorAny",
          "selector": ".metadata .annotations .\"container.apparmor.security.beta.kubernetes.io/app\"",
          "reason": "Well defined AppArmor policies may provide greater protection from unknown threats. WARNING: NOT PRODUCTION READY",
          "points": 3
        },
        {
          "id": "ServiceAccountName",
          "selector": ".spec .serviceAccountName",
          "reason": "Service accounts restrict Kubernetes API access and should be configured with least privilege",
          "points": 1
        },
        {
          "id": "SeccompAny",
          "selector": ".metadata .annotations .\"container.seccomp.security.alpha.kubernetes.io/pod\"",
          "reason": "Seccomp profiles set minimum privilege and secure against unknown threats",
          "points": 1
        },
        {
          "id": "LimitsCPU",
          "selector": "containers[] .resources .limits .cpu",
          "reason": "Enforcing CPU limits prevents DOS via resource exhaustion",
          "points": 1
        },
        {
          "id": "LimitsMemory",
          "selector": "containers[] .resources .limits .memory",
          "reason": "Enforcing memory limits prevents DOS via resource exhaustion",
          "points": 1
        },
        {
          "id": "RequestsCPU",
          "selector": "containers[] .resources .requests .cpu",
          "reason": "Enforcing CPU requests aids a fair balancing of resources across the cluster",
          "points": 1
        },
        {
          "id": "RequestsMemory",
          "selector": "containers[] .resources .requests .memory",
          "reason": "Enforcing memory requests aids a fair balancing of resources across the cluster",
          "points": 1
        },
        {
          "id": "CapDropAny",
          "selector": "containers[] .securityContext .capabilities .drop",
          "reason": "Reducing kernel capabilities available to a container limits its attack surface",
          "points": 1
        },
        {
          "id": "CapDropAll",
          "selector": "containers[] .securityContext .capabilities .drop | index(\"ALL\")",
          "reason": "Drop all capabilities and add only those required to reduce syscall attack surface",
          "points": 1
        },
        {
          "id": "ReadOnlyRootFilesystem",
          "selector": "containers[] .securityContext .readOnlyRootFilesystem == true",
          "reason": "An immutable root filesystem can prevent malicious binaries being added to PATH and increase attack cost",
          "points": 1
        },
        {
          "id": "RunAsNonRoot",
          "selector": "containers[] .securityContext .runAsNonRoot == true",
          "reason": "Force the running image to run as a non-root user to ensure least privilege",
          "points": 1
        },
        {
          "id": "RunAsUser",
          "selector": "containers[] .securityContext .runAsUser -gt 10000",
          "reason": "Run as a high-UID user to avoid conflicts with the host's user table",
          "points": 1
        }
      ]
    }
  }
]

$ echo $?
2
```

Aritmética de la puntuación: `-30 (Privileged) − 30 (CapSysAdmin) − 30 (HostPID) − 9 (HostNetwork) = -99`. El código de salida `2` es el código de fallo por defecto de kubesec, gobernado por `--threshold` (por defecto `0`).

El one-liner de triaje que todo SRE debería tener en el historial de su shell:

```
$ kubesec scan manifests/bad-deployment.yaml \
    | jq -r '.[] | "\(.object)  score=\(.score)", (.scoring.critical[]? | "  CRIT \(.points)\t\(.reason)")'
Deployment/payments.payments  score=-99
  CRIT -30	Privileged containers can allow almost completely unrestricted host access
  CRIT -30	CAP_SYS_ADMIN is the most privileged capability and should always be avoided
  CRIT -30	Sharing the host's PID namespace allows visibility on host processes, potentially leaking information such as environment variables and configuration
  CRIT -9	Sharing the host's network namespace permits processes in the pod to communicate with processes bound to the host's loopback adapter
```

### 5.3 Veredicto de KubeLinter sobre el mismo archivo

```
$ kube-linter lint --add-all-built-in manifests/bad-deployment.yaml
manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" is not set to runAsNonRoot (check: run-as-non-root, remediation: Set runAsUser to a non-zero number and runAsNonRoot to true in your pod or container securityContext. Refer to https://kubernetes.io/docs/tasks/configure-pod-container/security-context/ for details.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not have a read-only root file system (check: no-read-only-root-fs, remediation: Set readOnlyRootFilesystem to true in the container securityContext.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" is privileged (check: privileged-container, remediation: Do not run your container as privileged unless it is required.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has privilege escalation enabled (check: privilege-escalation-container, remediation: Set allowPrivilegeEscalation to false in the container securityContext.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not drop NET_RAW capability (check: drop-net-raw-capability, remediation: Remove NET_RAW from the capabilities the container adds, and drop it explicitly.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has cpu request 0 (check: unset-cpu-requirements, remediation: Set your container's CPU requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has cpu limit 0 (check: unset-cpu-requirements, remediation: Set your container's CPU requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has memory request 0 (check: unset-memory-requirements, remediation: Set your container's memory requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has memory limit 0 (check: unset-memory-requirements, remediation: Set your container's memory requests and limits depending on its requirements.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" has environment variable DB_PASSWORD which may contain a secret (check: env-var-secret, remediation: Do not use raw secrets in environment variables. Instead, either mount the secret as a file or use a secretKeyRef.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" uses the latest tag (check: latest-tag, remediation: Use a container image with a specific tag other than latest.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) object has hostNetwork set to true (check: host-network, remediation: Do not use the host network namespace.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) object has hostPID set to true (check: host-pid, remediation: Do not use the host PID namespace.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not specify a liveness probe (check: no-liveness-probe, remediation: Specify a liveness probe in your container.)

manifests/bad-deployment.yaml: (object: payments/payments apps/v1, Kind=Deployment) container "app" does not specify a readiness probe (check: no-readiness-probe, remediation: Specify a readiness probe in your container.)

Error: found 15 lint errors

$ echo $?
1
```

Fijate en los hallazgos que kubesec **no puede** producir: el secreto en texto plano en `env`, la etiqueta `:latest`, las probes faltantes, `allowPrivilegeEscalation` sin definir. Y los hallazgos que kubesec produjo y kube-linter no ponderó: ninguno acá — pero el *ranking* de kubesec (−30 vs −9) te dijo cuál arreglar primero. Ese es el argumento de complementariedad en una sola pantalla.

### 5.4 El manifiesto remediado

`manifests/payments.yaml` — completo y desplegable:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    security.cks.local/enforce: "true"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-db
  namespace: payments
type: Opaque
stringData:
  password: "REPLACE_VIA_EXTERNAL_SECRETS_OPERATOR"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
    app.kubernetes.io/name: payments
    app.kubernetes.io/component: api
    owner: platform-payments
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: payments
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: payments
        app.kubernetes.io/name: payments
        owner: platform-payments
    spec:
      serviceAccountName: payments
      automountServiceAccountToken: false
      hostNetwork: false
      hostPID: false
      hostIPC: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        appArmorProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: payments
      containers:
        - name: app
          image: registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: payments-db
                  key: password
            - name: TMPDIR
              value: /tmp
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            privileged: false
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: payments
  labels:
    app: payments
spec:
  type: ClusterIP
  selector:
    app: payments
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payments-default-deny
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

`readOnlyRootFilesystem: true` es el campo que rompe aplicaciones en la práctica. Los dos montajes `emptyDir` más `TMPDIR` son el remedio estándar: darle al proceso exactamente los caminos escribibles que necesita, con tamaño limitado, y nada más. `medium: Memory` en `/tmp` también significa que nada de lo escrito ahí llega jamás al disco del nodo.

### 5.5 Verificación después de la remediación

```
$ kubesec scan manifests/payments.yaml | jq -r '.[] | "\(.object)\t\(.score)\t\(.message)"'
Deployment/payments.payments	10	Passed with a score of 10 points
```

```
$ kubesec scan manifests/payments.yaml | jq -r '.[0].scoring.passed[] | "  +\(.points)\t\(.id)"'
  +1	ServiceAccountName
  +1	LimitsCPU
  +1	LimitsMemory
  +1	RequestsCPU
  +1	RequestsMemory
  +1	CapDropAny
  +1	CapDropAll
  +1	ReadOnlyRootFilesystem
  +1	RunAsNonRoot
  +1	RunAsUser
```

```
$ kubesec scan manifests/payments.yaml | jq -r '.[0].scoring.advise[] | "  ?\(.points)\t\(.id)"'
  ?3	ApparmorAny
  ?1	SeccompAny
```

**Leé esa lista de `advise` con criterio.** El manifiesto *sí* define `appArmorProfile: RuntimeDefault` y `seccompProfile: RuntimeDefault` — los campos GA. kubesec está pidiendo las anotaciones obsoletas. Este es el retraso de la Sección 3.4, en la vida real. La respuesta correcta es dejar el manifiesto como está, fijar el umbral de CI en `10` (tu línea base endurecida medida) y cubrir seccomp/AppArmor con la política de admisión de la Sección 7.2. Si tu build de `kubesec` sí reconoce `securityContext.seccompProfile`, vas a ver `11` y `SeccompAny` bajo `passed` — recalibrá la línea base en consecuencia.

```
$ kube-linter lint --config .kube-linter.yaml manifests/payments.yaml
KubeLinter 0.7.6

No lint errors found!

$ echo $?
0
```

```
$ kubesec scan --threshold 10 manifests/payments.yaml >/dev/null; echo "exit=$?"
exit=0

$ kubesec scan --threshold 11 manifests/payments.yaml >/dev/null; echo "exit=$?"
exit=2
```

---

## 6. Configuración e integración con el pipeline

### 6.1 `.kube-linter.yaml` — el artefacto de política revisable

```yaml
# .kube-linter.yaml
# The complete lint policy for this repository. Changes require platform-security review.
checks:
  # Start from the full built-in catalogue rather than the (much smaller) default set,
  # then subtract deliberately. This makes every exemption explicit and diffable.
  addAllBuiltIn: true
  doNotAutoAddDefaults: false

  exclude:
    # Batch workloads are single-replica by design; anti-affinity is meaningless.
    - "no-anti-affinity"
    # We pin by digest, which the latest-tag check already covers via required-image-digest below.
    - "unset-cpu-requirements"

  include:
    - "privileged-container"
    - "privilege-escalation-container"
    - "run-as-non-root"
    - "no-read-only-root-fs"
    - "drop-net-raw-capability"
    - "unset-memory-requirements"
    - "env-var-secret"
    - "latest-tag"
    - "host-network"
    - "host-pid"
    - "host-ipc"
    - "writable-host-mount"
    - "sensitive-host-mounts"
    - "unsafe-proc-mount"
    - "unsafe-sysctls"
    - "ssh-port"
    - "dangling-service"
    - "mismatching-selector"
    - "no-extensions-v1beta"
    - "deprecated-service-account-field"
    - "non-existent-service-account"
    - "wildcard-in-rules"
    - "cluster-admin-role-binding"
    - "no-liveness-probe"
    - "no-readiness-probe"
    # Custom checks declared below must also be listed here to be active.
    - "required-label-owner"
    - "no-default-service-account"
    - "require-seccomp-runtime-default"

customChecks:
  - name: required-label-owner
    description: "Every workload must carry an 'owner' label so paging routes to a real team."
    remediation: "Add the label 'owner: <team-slug>' to metadata.labels and to the pod template."
    scope:
      objectKinds:
        - DeploymentLike
    template: required-label
    params:
      key: owner

  - name: no-default-service-account
    description: "Workloads must not run under the namespace 'default' ServiceAccount."
    remediation: "Create a dedicated ServiceAccount with least-privilege RBAC and set spec.serviceAccountName."
    scope:
      objectKinds:
        - DeploymentLike
    template: service-account
    params:
      serviceAccount: "^(|default)$"

  - name: require-seccomp-runtime-default
    description: "Pods must set an explicit seccomp profile of RuntimeDefault or Localhost."
    remediation: "Set spec.securityContext.seccompProfile.type to RuntimeDefault."
    scope:
      objectKinds:
        - DeploymentLike
    template: forbidden-annotation
    params:
      key: "seccomp.security.alpha.kubernetes.io/pod"
```

> La tercera verificación personalizada ilustra una limitación real: el catálogo de plantillas de KubeLinter no expone (a partir de 0.7.x) una plantilla para el campo `seccompProfile`, así que la regla expresable más cercana es *prohibir la anotación obsoleta*. Cuando no existe una plantilla para la invariante que necesitás, **no la falsifiques** — expresá la regla en conftest/Rego (Sección 6.2) o en una `ValidatingAdmissionPolicy` (Sección 7.2) y dejá un comentario indicando dónde vive la aplicación real. Una verificación mal nombrada que no hace lo que su nombre afirma es peor que ninguna verificación.

Verificá que la configuración realmente se esté leyendo:

```
$ kube-linter lint --config .kube-linter.yaml --format json manifests/ | jq '.Checks | length'
28
```

### 6.2 conftest / Rego — la vía de escape para invariantes específicas de la organización

`policy/workload.rego`:

```rego
package main

# --- helpers ---------------------------------------------------------------

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}

pod_spec[spec] {
  workload_kinds[input.kind]
  spec := input.spec.template.spec
}

pod_spec[spec] {
  input.kind == "Pod"
  spec := input.spec
}

pod_spec[spec] {
  input.kind == "CronJob"
  spec := input.spec.jobTemplate.spec.template.spec
}

all_containers[c] {
  spec := pod_spec[_]
  c := spec.containers[_]
}

all_containers[c] {
  spec := pod_spec[_]
  c := spec.initContainers[_]
}

# --- rules -----------------------------------------------------------------

deny[msg] {
  c := all_containers[_]
  c.securityContext.privileged
  msg := sprintf("container %q: privileged is true", [c.name])
}

deny[msg] {
  c := all_containers[_]
  not c.securityContext.allowPrivilegeEscalation == false
  msg := sprintf("container %q: allowPrivilegeEscalation must be explicitly false", [c.name])
}

deny[msg] {
  c := all_containers[_]
  not c.securityContext.readOnlyRootFilesystem == true
  msg := sprintf("container %q: readOnlyRootFilesystem must be true", [c.name])
}

deny[msg] {
  c := all_containers[_]
  drops := {d | d := c.securityContext.capabilities.drop[_]}
  not drops["ALL"]
  msg := sprintf("container %q: capabilities.drop must contain ALL", [c.name])
}

# Images must be pinned by digest, and must come from an approved registry.
approved_registries := {"registry.internal/", "ghcr.io/our-org/"}

deny[msg] {
  c := all_containers[_]
  not contains(c.image, "@sha256:")
  msg := sprintf("container %q: image %q is not pinned by digest", [c.name, c.image])
}

deny[msg] {
  c := all_containers[_]
  not any_prefix(c.image, approved_registries)
  msg := sprintf("container %q: image %q is not from an approved registry", [c.name, c.image])
}

any_prefix(s, prefixes) {
  prefixes[p]
  startswith(s, p)
}

# Seccomp: the modern field, which kubesec and kube-linter do not evaluate.
deny[msg] {
  spec := pod_spec[_]
  not spec.securityContext.seccompProfile.type
  msg := "pod securityContext.seccompProfile.type must be set (RuntimeDefault or Localhost)"
}

deny[msg] {
  spec := pod_spec[_]
  t := spec.securityContext.seccompProfile.type
  t == "Unconfined"
  msg := "pod securityContext.seccompProfile.type must not be Unconfined"
}

# Host namespaces.
deny[msg] {
  spec := pod_spec[_]
  spec.hostNetwork
  msg := "hostNetwork must not be true"
}

deny[msg] {
  spec := pod_spec[_]
  spec.hostPID
  msg := "hostPID must not be true"
}

deny[msg] {
  spec := pod_spec[_]
  spec.hostIPC
  msg := "hostIPC must not be true"
}

# Sensitive host mounts.
sensitive_paths := {
  "/", "/etc", "/var/run/docker.sock", "/run/containerd/containerd.sock",
  "/var/lib/kubelet", "/proc", "/sys", "/var/log", "/root", "/home",
}

deny[msg] {
  spec := pod_spec[_]
  v := spec.volumes[_]
  p := v.hostPath.path
  sensitive_paths[p]
  msg := sprintf("volume %q mounts sensitive host path %q", [v.name, p])
}

# Warnings do not fail the build but are printed.
warn[msg] {
  c := all_containers[_]
  not c.livenessProbe
  msg := sprintf("container %q: no livenessProbe defined", [c.name])
}
```

```
$ conftest test --policy policy/ manifests/bad-deployment.yaml
FAIL - manifests/bad-deployment.yaml - main - container "app": privileged is true
FAIL - manifests/bad-deployment.yaml - main - container "app": allowPrivilegeEscalation must be explicitly false
FAIL - manifests/bad-deployment.yaml - main - container "app": readOnlyRootFilesystem must be true
FAIL - manifests/bad-deployment.yaml - main - container "app": capabilities.drop must contain ALL
FAIL - manifests/bad-deployment.yaml - main - container "app": image "registry.internal/payments:latest" is not pinned by digest
FAIL - manifests/bad-deployment.yaml - main - pod securityContext.seccompProfile.type must be set (RuntimeDefault or Localhost)
FAIL - manifests/bad-deployment.yaml - main - hostNetwork must not be true
FAIL - manifests/bad-deployment.yaml - main - hostPID must not be true
WARN - manifests/bad-deployment.yaml - main - container "app": no livenessProbe defined

9 tests, 0 passed, 1 warning, 8 failures, 0 exceptions

$ echo $?
1

$ conftest test --policy policy/ manifests/payments.yaml
5 tests, 5 passed, 0 warnings, 0 failures, 0 exceptions

$ echo $?
0
```

### 6.3 Análisis estático de Dockerfile e imagen

El manifiesto de la carga de trabajo es solo la mitad del artefacto. La imagen trae sus propios valores por defecto, y `USER root` en la imagen más un `PodSpec` que omite `runAsNonRoot` produce un contenedor root que todos los linters de manifiestos pueden haber aprobado.

`Dockerfile` — antes:

```dockerfile
FROM golang
RUN apt-get update && apt-get install -y curl openssh-server
ADD https://internal.example.com/config.tar.gz /app/
COPY . /app
WORKDIR /app
RUN go build -o payments ./cmd/payments
EXPOSE 22 8080
ENV DB_PASSWORD=s3cr3t-plaintext
CMD ./payments
```

```
$ hadolint Dockerfile
Dockerfile:1 DL3006 warning: Always tag the version of an image explicitly
Dockerfile:2 DL3008 warning: Pin versions in apt-get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
Dockerfile:2 DL3009 info: Delete the apt-get lists after installing something
Dockerfile:2 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
Dockerfile:3 DL3020 error: Use COPY instead of ADD for files and folders
Dockerfile:9 DL3002 warning: Last USER should not be root
Dockerfile:10 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments

$ echo $?
1
```

`Dockerfile` — después (multi-stage, no root, distroless, fijado):

```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.24.5-bookworm@sha256:1c0d5f9a7e3b2c4d6e8f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5 AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/payments ./cmd/payments

# ---------------------------------------------------------------------------

FROM gcr.io/distroless/static-debian12:nonroot@sha256:9be3f9b4b2b0a6d7c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2

LABEL org.opencontainers.image.source="https://git.internal/platform/payments" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Platform Engineering"

COPY --from=build --chown=65532:65532 /out/payments /usr/local/bin/payments

USER 65532:65532
WORKDIR /
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/payments"]
```

```
$ hadolint Dockerfile
$ echo $?
0
```

Análisis estático de la **imagen construida** (configuración, no CVEs):

```
$ dockle registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
PASS	- CIS-DI-0001: Create a user for the container
PASS	- CIS-DI-0005: Enable Content trust for Docker
PASS	- CIS-DI-0006: Add HEALTHCHECK instruction to the container image
PASS	- CIS-DI-0008: Confirm safety of setuid/setgid files
PASS	- CIS-DI-0010: Do not store credential in environment variables/files
PASS	- DKL-DI-0005: Clear apt-get caches
PASS	- DKL-LI-0003: Only put necessary files

$ echo $?
0
```

```
$ trivy image --scanners misconfig,secret \
    --image-config-scanners misconfig,secret \
    registry.internal/payments@sha256:8c1f9b4d2a7e6c0b5f3a9d8e7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b
2026-08-04T09:41:07Z	INFO	Misconfiguration scanning is enabled
2026-08-04T09:41:07Z	INFO	Secret scanning is enabled
2026-08-04T09:41:09Z	INFO	Detected config files	num=1

registry.internal/payments (dockerfile)
=======================================
Tests: 28 (SUCCESSES: 28, FAILURES: 0)
Failures: 0 (HIGH: 0, CRITICAL: 0)
```

El escáner de malas configuraciones de Trivy sobre el directorio de manifiestos, como segunda opinión frente a kube-linter:

```
$ trivy config --severity HIGH,CRITICAL --exit-code 1 manifests/
2026-08-04T09:43:15Z	INFO	Misconfiguration scanning is enabled
2026-08-04T09:43:16Z	INFO	Detected config files	num=2

manifests/bad-deployment.yaml (kubernetes)
==========================================
Tests: 42 (SUCCESSES: 28, FAILURES: 14)
Failures: 14 (HIGH: 11, CRITICAL: 3)

CRITICAL: Container 'app' of Deployment 'payments' should not set 'securityContext.privileged' to true
════════════════════════════════════════════════════════════════════════════════
Privileged containers share namespaces with the host system and do not offer any
security. They should be used exclusively for system containers that require high
privileges.

See https://avd.aquasec.com/misconfig/ksv017
────────────────────────────────────────────────────────────────────────────────
 manifests/bad-deployment.yaml:21-24
────────────────────────────────────────────────────────────────────────────────
  21 ┌           securityContext:
  22 │             privileged: true
  23 │             capabilities:
  24 └               add:
────────────────────────────────────────────────────────────────────────────────

CRITICAL: Deployment 'payments' should not set 'spec.template.spec.hostPID' to true
════════════════════════════════════════════════════════════════════════════════
See https://avd.aquasec.com/misconfig/ksv010
...

manifests/payments.yaml (kubernetes)
====================================
Tests: 46 (SUCCESSES: 46, FAILURES: 0)
Failures: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
1
```

### 6.4 El pipeline

`Makefile`:

```makefile
SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -euo pipefail -c
MANIFESTS      ?= manifests
POLICY         ?= policy
KUBESEC_MIN    ?= 10
IMAGE          ?= registry.internal/payments

.PHONY: lint lint-manifests lint-score lint-policy lint-docker verify-gate

lint: lint-manifests lint-score lint-policy lint-docker

lint-manifests:
	kube-linter lint --config .kube-linter.yaml --format plain $(MANIFESTS)

## kubesec is per-document; iterate so one bad file cannot be masked by a good one.
lint-score:
	@fail=0; \
	for f in $$(find $(MANIFESTS) -name '*.yaml' -o -name '*.yml'); do \
	  out=$$(kubesec scan --threshold $(KUBESEC_MIN) "$$f" || true); \
	  echo "$$out" | jq -r --arg f "$$f" \
	    '.[] | select(.valid) | "\($$f)\t\(.object)\tscore=\(.score)"'; \
	  bad=$$(echo "$$out" | jq --argjson t $(KUBESEC_MIN) \
	    '[.[] | select(.valid) | select(.score < $$t)] | length'); \
	  if [[ "$$bad" != "0" ]]; then \
	    echo "  FAIL: $$f has $$bad object(s) below threshold $(KUBESEC_MIN)" >&2; \
	    echo "$$out" | jq -r '.[] | .scoring.critical[]? | "    CRIT \(.points)\t\(.reason)"' >&2; \
	    fail=1; \
	  fi; \
	done; \
	exit $$fail

lint-policy:
	conftest test --policy $(POLICY) --all-namespaces $(MANIFESTS)

lint-docker:
	hadolint Dockerfile
	trivy config --severity HIGH,CRITICAL --exit-code 1 $(MANIFESTS) Dockerfile

## Negative test: the gate must actually fail on a known-bad manifest.
verify-gate:
	@echo "==> verifying the gate rejects testdata/known-bad.yaml"
	@if kube-linter lint --config .kube-linter.yaml testdata/known-bad.yaml >/dev/null 2>&1; then \
	  echo "GATE BROKEN: known-bad.yaml passed kube-linter" >&2; exit 1; \
	fi
	@if conftest test --policy $(POLICY) testdata/known-bad.yaml >/dev/null 2>&1; then \
	  echo "GATE BROKEN: known-bad.yaml passed conftest" >&2; exit 1; \
	fi
	@echo "==> gate verified"
```

> El objetivo `verify-gate` no es decoración opcional. Un linter con una ruta de configuración mal escrita, o un `.kube-linter.yaml` cuya lista `include` referencia en silencio un nombre de verificación que ya no existe, va a imprimir alegremente "No lint errors found!" para siempre. **Toda compuerta de política necesita una prueba negativa comprometida que demuestre que sigue mordiendo.** Esta es la forma más común en que los pipelines de análisis estático se pudren.

`.github/workflows/static-analysis.yml`:

```yaml
name: static-analysis

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read
  security-events: write   # required to upload SARIF

jobs:
  manifests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: KubeLinter (blocking)
        uses: stackrox/kube-linter-action@v1
        with:
          directory: manifests
          config: .kube-linter.yaml
          format: sarif
          output-file: kube-linter.sarif

      - name: Upload KubeLinter SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: kube-linter.sarif
          category: kube-linter

      - name: kubesec score gate
        run: |
          set -euo pipefail
          docker pull kubesec/kubesec:v2
          fail=0
          while IFS= read -r -d '' f; do
            out=$(docker run --rm -i kubesec/kubesec:v2 scan /dev/stdin < "$f" || true)
            echo "::group::kubesec $f"
            echo "$out" | jq -r '.[] | "\(.object)  score=\(.score)  \(.message)"'
            echo "$out" | jq -r '.[] | .scoring.critical[]? | "  CRITICAL \(.points): \(.reason)"'
            echo "::endgroup::"
            low=$(echo "$out" | jq '[.[] | select(.valid) | select(.score < 10)] | length')
            [ "$low" = "0" ] || { echo "::error file=$f::kubesec score below threshold 10"; fail=1; }
          done < <(find manifests -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
          exit $fail

      - name: conftest policies
        run: |
          curl -sSL -o conftest.tgz \
            https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_x86_64.tar.gz
          tar xzf conftest.tgz conftest
          ./conftest test --policy policy/ --all-namespaces manifests/

      - name: Gate self-test
        run: make verify-gate

  images:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          failure-threshold: warning

      - name: Trivy config scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: config
          scan-ref: .
          severity: HIGH,CRITICAL
          exit-code: '1'
```

Equivalente en `.gitlab-ci.yml`:

```yaml
stages:
  - static-analysis

variables:
  KUBESEC_MIN: "10"

.static: &static
  stage: static-analysis
  interruptible: true
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

kube-linter:
  <<: *static
  image:
    name: stackrox/kube-linter:v0.7.6
    entrypoint: [""]
  script:
    - kube-linter lint --config .kube-linter.yaml --format sarif manifests/ > kube-linter.sarif
  artifacts:
    when: always
    paths: [kube-linter.sarif]

kubesec:
  <<: *static
  image:
    name: kubesec/kubesec:v2
    entrypoint: [""]
  before_script:
    - apk add --no-cache jq findutils bash
  script:
    - |
      set -euo pipefail
      fail=0
      for f in $(find manifests -type f -name '*.yaml'); do
        out=$(kubesec scan "$f" || true)
        echo "$out" | jq -r --arg f "$f" '.[] | "\($f) \(.object) score=\(.score)"'
        low=$(echo "$out" | jq --argjson t "$KUBESEC_MIN" '[.[] | select(.valid) | select(.score < $t)] | length')
        [ "$low" = "0" ] || { echo "$f below threshold"; fail=1; }
      done
      exit $fail

conftest:
  <<: *static
  image:
    name: openpolicyagent/conftest:v0.56.0
    entrypoint: [""]
  script:
    - conftest test --policy policy/ --all-namespaces manifests/
```

`.pre-commit-config.yaml` — desplazá el feedback todo lo posible hacia la izquierda:

```yaml
repos:
  - repo: https://github.com/stackrox/kube-linter
    rev: v0.7.6
    hooks:
      - id: kube-linter
        args: ["--config", ".kube-linter.yaml"]
        files: ^manifests/.*\.ya?ml$

  - repo: https://github.com/hadolint/hadolint
    rev: v2.12.0
    hooks:
      - id: hadolint-docker

  - repo: local
    hooks:
      - id: kubesec
        name: kubesec score gate
        language: system
        files: ^manifests/.*\.ya?ml$
        entry: >-
          bash -c 'for f in "$@"; do kubesec scan --threshold 10 "$f" >/dev/null || { echo "kubesec: $f below threshold"; kubesec scan "$f" | jq -r ".[] | .scoring.critical[]? | \"  \(.points) \(.reason)\""; exit 1; }; done' --
```

---

## 7. Cerrando el círculo: de consultivo a aplicado

### 7.1 Un servicio kubesec compartido para la plataforma

Ejecutar `kubesec http` como un servicio del clúster permite que los runners de CI, los plugins de IDE y las herramientas internas compartan una única versión fijada — lo que significa un único lugar donde recalibrar umbrales tras una actualización.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform-security
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubesec
  namespace: platform-security
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubesec
  namespace: platform-security
  labels:
    app: kubesec
spec:
  replicas: 2
  selector:
    matchLabels:
      app: kubesec
  template:
    metadata:
      labels:
        app: kubesec
    spec:
      serviceAccountName: kubesec
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kubesec
          image: kubesec/kubesec:v2.14.2
          args: ["http", "8080"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: kubesec
  namespace: platform-security
spec:
  type: ClusterIP
  selector:
    app: kubesec
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kubesec
  namespace: platform-security
spec:
  podSelector:
    matchLabels:
      app: kubesec
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ci
      ports:
        - protocol: TCP
          port: 8080
  egress: []
```

```
$ kubectl -n platform-security port-forward svc/kubesec 8080:80 >/dev/null 2>&1 &
$ curl -sSX POST --data-binary @manifests/payments.yaml http://localhost:8080/scan \
    | jq -r '.[] | "\(.object)\t\(.score)"'
Deployment/payments.payments	10
```

### 7.2 `ValidatingAdmissionPolicy` — las mismas reglas, aplicadas, sin controlador extra

La política de admisión basada en CEL es GA desde Kubernetes v1.30 y es la forma de menor costo operativo de volver vinculantes las verificaciones consultivas de CI. Sin webhook, sin rotación de certificados, sin dependencia de disponibilidad.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: workload-hardening.cks.local
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - apiGroups:   ["batch"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["jobs", "cronjobs"]
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: podSpec
      expression: >-
        has(object.spec.template)
          ? (has(object.spec.template.spec) ? object.spec.template.spec : object.spec)
          : (has(object.spec.jobTemplate)
              ? object.spec.jobTemplate.spec.template.spec
              : object.spec)
    - name: containers
      expression: >-
        (has(variables.podSpec.containers) ? variables.podSpec.containers : []) +
        (has(variables.podSpec.initContainers) ? variables.podSpec.initContainers : [])
  validations:
    - expression: >-
        !variables.containers.exists(c,
          has(c.securityContext) && has(c.securityContext.privileged) && c.securityContext.privileged)
      message: "privileged containers are not permitted"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation)
          && c.securityContext.allowPrivilegeEscalation == false)
      message: "every container must set securityContext.allowPrivilegeEscalation: false"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.capabilities)
          && has(c.securityContext.capabilities.drop)
          && c.securityContext.capabilities.drop.exists(d, d == 'ALL'))
      message: "every container must drop ALL capabilities"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem)
          && c.securityContext.readOnlyRootFilesystem == true)
      message: "every container must set readOnlyRootFilesystem: true"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostNetwork) || variables.podSpec.hostNetwork == false"
      message: "hostNetwork is not permitted"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostPID) || variables.podSpec.hostPID == false"
      message: "hostPID is not permitted"
      reason: Forbidden

    - expression: "!has(variables.podSpec.hostIPC) || variables.podSpec.hostIPC == false"
      message: "hostIPC is not permitted"
      reason: Forbidden

    - expression: >-
        has(variables.podSpec.securityContext)
        && has(variables.podSpec.securityContext.seccompProfile)
        && variables.podSpec.securityContext.seccompProfile.type in ['RuntimeDefault', 'Localhost']
      message: "pod securityContext.seccompProfile.type must be RuntimeDefault or Localhost"
      reason: Forbidden

    - expression: >-
        variables.containers.all(c,
          has(c.resources) && has(c.resources.limits)
          && has(c.resources.limits.memory) && has(c.resources.limits.cpu))
      message: "every container must declare resources.limits.cpu and resources.limits.memory"
      reason: Forbidden

    - expression: "variables.containers.all(c, c.image.contains('@sha256:'))"
      message: "container images must be pinned by digest (@sha256:...)"
      reason: Forbidden

    - expression: >-
        !has(variables.podSpec.volumes) ||
        variables.podSpec.volumes.all(v,
          !has(v.hostPath) ||
          !(v.hostPath.path in ['/', '/etc', '/proc', '/sys', '/var/run/docker.sock',
                                '/run/containerd/containerd.sock', '/var/lib/kubelet']))
      message: "mounting sensitive host paths is not permitted"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: workload-hardening-binding
spec:
  policyName: workload-hardening.cks.local
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchLabels:
        security.cks.local/enforce: "true"
```

Demostrando que la capa de aplicación coincide con la capa de CI:

```
$ kubectl apply -f manifests/bad-deployment.yaml
The deployments "payments" is invalid: ValidatingAdmissionPolicy 'workload-hardening.cks.local'
with binding 'workload-hardening-binding' denied request: privileged containers are not permitted

$ kubectl apply -f manifests/payments.yaml
namespace/payments created
serviceaccount/payments created
secret/payments-db created
deployment.apps/payments created
service/payments created
networkpolicy.networking.k8s.io/payments-default-deny created
```

> **Desplegá primero con `validationActions: ["Audit"]`.** Denegar desde el primer día contra un clúster existente va a romper todas las cargas de trabajo gestionadas por controladores que no sabías que existían. El modo de auditoría escribe anotaciones `validation.policy.admission.k8s.io/validation_failure` en el log de auditoría de la API; recolectalas durante una semana, arreglá la flota, y recién ahí cambiá a `Deny`.

### 7.3 La alternativa Kyverno

Si ya usás Kyverno (para verificación de firmas de imágenes de CKS 4.3, algo que CEL no puede hacer), expresá las mismas reglas ahí en lugar de dividir la política entre dos motores:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: workload-hardening
  annotations:
    policies.kyverno.io/title: Workload hardening
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: disallow-privileged-and-host-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: >-
          Privileged containers and host namespaces are not permitted.
        pattern:
          spec:
            =(hostNetwork): "false"
            =(hostPID): "false"
            =(hostIPC): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
                  allowPrivilegeEscalation: "false"
                  readOnlyRootFilesystem: "true"
                  capabilities:
                    drop:
                      - ALL

    - name: require-seccomp-runtime-default
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: "seccompProfile.type must be RuntimeDefault or Localhost."
        pattern:
          spec:
            securityContext:
              seccompProfile:
                type: "RuntimeDefault | Localhost"

    - name: require-digest-pinned-images
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaceSelector:
                matchLabels:
                  security.cks.local/enforce: "true"
      validate:
        message: "Images must be pinned by digest."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ contains(element.image, '@sha256:') }}"
                    operator: Equals
                    value: false
```

La misma política corre **en CI** con la CLI de Kyverno, que es la forma más limpia de garantizar que CI y el control de admisión nunca diverjan — un archivo de política, dos contextos de ejecución:

```
$ kyverno apply policies/ --resource manifests/bad-deployment.yaml

Applying 3 policy rule(s) to 1 resource(s)...

policy workload-hardening -> resource payments/Deployment/payments failed:
1. disallow-privileged-and-host-namespaces: validation error: Privileged containers
   and host namespaces are not permitted. rule disallow-privileged-and-host-namespaces
   failed at path /spec/template/spec/hostNetwork/

pass: 0, fail: 3, warn: 0, error: 0, skip: 0

$ echo $?
1
```

---

## 8. Verificación y diagnóstico de fallos

### 8.1 Referencia de códigos de salida

| Herramienta | 0 | 1 | 2 | 3+ |
|---|---|---|---|---|
| `kubesec scan` | puntuación ≥ umbral | error de uso/parseo | el escaneo falló (puntuación < umbral) — configurable con `--exit-code` | — |
| `kube-linter lint` | sin violaciones | violaciones encontradas, o configuración inválida | — | — |
| `conftest test` | sin `deny` | uno o más `deny` | — | — |
| `trivy config` | siempre 0 salvo que se defina `--exit-code` | con `--exit-code 1`: hallazgos en o por encima de `--severity` | — | — |
| `hadolint` | limpio en el umbral | hallazgos en o por encima de `--failure-threshold` | — | — |
| `dockle` | limpio | — | hallazgos `FATAL` (`-exit-code` configurable) | — |
| `kube-score score` | limpio | — | hallazgos críticos (`--exit-one-on-warning` promueve las advertencias) | — |

**El bug de pipeline que previene esta tabla:** `trivy config` sale con **0 por defecto incluso con hallazgos CRITICAL**. Una etapa que solo ejecuta `trivy config manifests/` queda en verde para siempre. Pasá siempre `--exit-code 1`.

### 8.2 Síntoma → causa → solución

| Síntoma | Causa raíz | Solución |
|---|---|---|
| `kubesec` devuelve `"valid": false` y un mensaje sobre un tipo no soportado | El documento es un `Service`/`ConfigMap`/`Ingress`/CRD. kubesec solo entiende tipos de carga de trabajo | Filtrá las entradas: `yq 'select(.kind == "Deployment" or .kind == "Pod" ...)'`, o ignorá las entradas `valid: false` en tu compuerta `jq` — `select(.valid)` |
| `kubesec` puntúa solo el *primer* documento de un archivo multi-documento | Builds antiguos; o el archivo empieza con un documento que no es carga de trabajo | Dividí con `yq -s` / `csplit`, o escaneá cada objeto por separado. Verificá con `jq 'length'` — debe igualar la cantidad de documentos de carga de trabajo |
| `kubesec scan` sobre un `kind: List` no devuelve nada útil | El envoltorio `List` no es un tipo de carga de trabajo | `kubectl apply --dry-run=client -o yaml -f list.yaml \| yq '.items[]' \| ...`, o dividí primero |
| `kube-linter` imprime `No lint errors found!` sobre un archivo obviamente malo | El conjunto de verificaciones por defecto es diminuto y la verificación relevante no está en él | `--add-all-built-in`, o comprometé un `.kube-linter.yaml` explícito y verificá con `--format json \| jq '.Checks \| length'` |
| `kube-linter` ignora silenciosamente tu `.kube-linter.yaml` | **No** se autodescubre en todas las versiones/rutas | Pasá `--config .kube-linter.yaml` explícitamente. Demostralo: agregá temporalmente una verificación que sepas que se va a disparar |
| `kube-linter` reporta `non-existent-service-account` para una SA que claramente existe | El objeto `ServiceAccount` está en un archivo/directorio distinto del escaneado | Escaneá el directorio completo, no un solo archivo. El análisis estático no tiene acceso al clúster |
| Un chart de Helm no produce ningún hallazgo | Las plantillas se escanearon literalmente; `{{ }}` no es YAML | `helm template myrel ./chart -f values-prod.yaml \| kube-linter lint -` |
| Un overlay de Kustomize no produce ningún hallazgo | Se escaneó la base, sin aplicar los parches del overlay | `kustomize build overlays/prod \| kube-linter lint -` |
| CI pasa, el deploy es rechazado por el control de admisión | Las reglas estáticas son un *superconjunto* desalineado con las reglas de admisión, o un webhook mutante inyectó un sidecar no conforme | Escaneá la salida del **dry-run del lado del servidor** (8.4). Alineá ambos conjuntos de reglas y fijalos en un solo repositorio |
| La puntuación bajó tras actualizar la herramienta sin cambiar el manifiesto | El conjunto de reglas o los valores de puntos cambiaron entre versiones | Fijá las versiones de las herramientas por digest en CI. Recalibrá los umbrales deliberadamente, en un commit dedicado |
| `readOnlyRootFilesystem: true` provoca `CrashLoopBackOff` | El proceso escribe en algún lugar que no montaste | `kubectl logs`, y luego `kubectl debug -it <pod> --image=busybox --target=app -- sh` y observá si hay `EROFS`. Agregá un `emptyDir` con tamaño para exactamente esa ruta |
| `runAsNonRoot: true` produce `CreateContainerConfigError` | El `USER` de la imagen es root o el UID numérico no se puede resolver | `docker inspect --format '{{.Config.User}}' <image>`; definí `USER 65532:65532` en el Dockerfile *y* `runAsUser` en el manifiesto |
| `conftest` reporta `0 tests, 0 passed` | Ruta `--policy` incorrecta, o el paquete no es `main` y no se dio `--namespace` | `conftest test --policy policy/ --namespace main ...`; revisá `conftest parse manifests/x.yaml` primero |

### 8.3 Reproducir un fallo localmente, exactamente como lo ve CI

```
$ docker run --rm -v "$PWD":/work -w /work stackrox/kube-linter:v0.7.6 \
    lint --config .kube-linter.yaml manifests/
```

Fijar por digest elimina por completo la clase de deriva de política "funciona en mi máquina":

```
$ docker run --rm -v "$PWD":/work -w /work \
    stackrox/kube-linter@sha256:2b7d6c1e4f8a90b3c5d7e9f1a2b4c6d8e0f1a3b5c7d9e1f3a5b7c9d1e3f5a7b9 \
    lint --config .kube-linter.yaml manifests/
```

### 8.4 La técnica que cierra el punto ciego de las mutaciones

El análisis estático del archivo en Git se pierde todo lo que agrega un mutador de admisión. Escaneá lo que el API server *realmente persistiría*:

```
$ kubectl create --dry-run=server -o yaml -f manifests/payments.yaml > /tmp/rendered.yaml
$ yq 'select(.kind == "Deployment")' /tmp/rendered.yaml | kubesec scan /dev/stdin \
    | jq -r '.[] | "\(.object)\tscore=\(.score)"'
Deployment/payments.payments	10
```

`--dry-run=server` ejecuta la cadena completa de admisión — defaulting, webhooks mutantes, inyección de sidecars — sin persistir. La diferencia entre la puntuación del archivo fuente y la del dry-run es *exactamente* el privilegio que los mutadores de tu propia plataforma están agregando a espaldas de tus desarrolladores. Seguí ese delta; debería ser cero, y cuando no lo sea, encontraste un inyector que necesita endurecerse.

La misma idea aplicada a la flota en ejecución — una auditoría programada de lo que está *realmente desplegado*, que atrapa todo lo que eludió CI:

```
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    for d in $(kubectl -n "$ns" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      score=$(kubectl -n "$ns" get deploy "$d" -o yaml \
        | kubesec scan /dev/stdin | jq -r '.[0].score')
      printf '%-24s %-32s %s\n' "$ns" "$d" "$score"
    done
  done | sort -k3 -n | head -10
kube-system              node-local-dns                   -99
kube-system              kube-proxy                       -69
observability            node-exporter                    -39
ingress-nginx            ingress-nginx-controller          -8
default                  legacy-batch-runner                0
payments                 payments                          10
```

Los DaemonSets de infraestructura al tope de esa lista son, en su mayoría, *legítimamente* privilegiados — `kube-proxy` necesita `hostNetwork`, `node-exporter` necesita montajes del host. Esa es la lección final de las herramientas de puntuación: **una puntuación baja es una pregunta, no un veredicto.** Tu trabajo es producir una respuesta documentada para cada una y asegurarte de que `legacy-batch-runner` en `default`, que nadie puede explicar, se elimine.

### 8.5 Una lista de verificación para la compuerta misma

1. `make verify-gate` — un manifiesto conocido como malo es rechazado por todas las herramientas de la cadena.
2. `echo $?` después de cada herramienta, en CI, con `set -o pipefail`. Una herramienta canalizada hacia `tee` o `jq` reporta el estado del *último* comando; `pipefail` no es opcional.
3. `kube-linter lint --format json ... | jq '.Checks | length'` — la cantidad de verificaciones activas se afirma, de modo que una regresión de configuración sea ruidosa.
4. Versiones de herramientas fijadas por digest, actualizadas en commits dedicados que además recalibran los umbrales.
5. `grep -rn "ignore-check.kube-linter.io" manifests/` revisado mensualmente; las supresiones sin ticket ni fecha se eliminan.
6. El conjunto de reglas de CI y el de admisión se comparan mediante una prueba que ejecuta ambos contra el mismo corpus y afirma veredictos idénticos.

---

## 9. Flujo de trabajo orientado al examen

Bajo presión de tiempo, el bucle confiable es:

```
$ kubesec scan /path/to/pod.yaml | jq -r '.[0] | .score, (.scoring.critical[] | "\(.points) \(.reason)")'
```

Arreglá primero el ítem más negativo, volvé a escanear, repetí. Después:

```
$ kube-linter lint /path/to/pod.yaml
```

y aplicá el texto de `remediation:` textualmente — te dice el campo exacto que hay que definir.

Memoria muscular a nivel de campo para las correcciones que aparecen una y otra vez:

```yaml
spec:
  serviceAccountName: <dedicated-sa>
  automountServiceAccountToken: false
  hostNetwork: false
  hostPID: false
  hostIPC: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: repo/name@sha256:<digest>
      resources:
        requests: {cpu: "100m", memory: "128Mi"}
        limits:   {cpu: "500m", memory: "256Mi"}
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
```

Cosas que le cuestan tiempo a los candidatos y vale la pena ensayar:

- `kubesec` rechaza los tipos que no son cargas de trabajo — no pierdas minutos con un `Service`.
- El conjunto de verificaciones por defecto de `kube-linter` es pequeño; si falta una violación que esperabas, agregá `--add-all-built-in`.
- Ambas herramientas leen de stdin (`/dev/stdin` para kubesec, `-` para kube-linter), así que `helm template … | kube-linter lint -` funciona sin archivos temporales.
- `kubectl explain pod.spec.securityContext --recursive` está disponible en el examen y es más rápido que el sitio de documentación para recordar el nombre de un campo.
- Después de remediar, demostralo: volvé a ejecutar la herramienta y mostrá una salida limpia, y si la tarea dice "deploy", hacé `kubectl apply` y confirmá que el pod llega a `Running`. Un manifiesto endurecido que no arranca no es un aprobado.

---

## 10. Referencias

**Temario y certificación**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Repositorio de temarios de CNCF — https://github.com/cncf/curriculum
- Página del examen CKS (Linux Foundation) — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Kubernetes upstream**
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Linux capabilities in Kubernetes — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container
- Kubernetes Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/
- Dry-run — https://kubernetes.io/docs/reference/using-api/api-concepts/#dry-run
- Deprecated API migration guide — https://kubernetes.io/docs/reference/using-api/deprecation-guide/

**kubesec**
- Sitio del proyecto y catálogo de reglas — https://kubesec.io/
- Repositorio de código fuente — https://github.com/controlplaneio/kubesec
- Webhook de admisión de kubesec — https://github.com/controlplaneio/kubesec-webhook

**KubeLinter**
- Documentación — https://docs.kubelinter.io/
- Repositorio de código fuente — https://github.com/stackrox/kube-linter
- Referencia de verificaciones integradas — https://docs.kubelinter.io/#/generated/checks
- Referencia de plantillas — https://docs.kubelinter.io/#/generated/templates
- Configuración de KubeLinter — https://docs.kubelinter.io/#/configuring-kubelinter
- GitHub Action — https://github.com/stackrox/kube-linter-action

**Otras herramientas de análisis estático**
- kube-score — https://github.com/zegl/kube-score
- Polaris (Fairwinds) — https://polaris.docs.fairwinds.com/
- Trivy (escaneo de malas configuraciones) — https://trivy.dev/latest/docs/scanner/misconfiguration/
- Escaneo de Kubernetes con Trivy — https://trivy.dev/latest/docs/target/kubernetes/
- Aqua Vulnerability Database (IDs de malas configuraciones KSV) — https://avd.aquasec.com/misconfig/kubernetes/
- Checkov — https://www.checkov.io/
- hadolint — https://github.com/hadolint/hadolint
- dockle — https://github.com/goodwithtech/dockle
- conftest — https://www.conftest.dev/
- Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/policy-language/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno — https://kyverno.io/docs/
- Kyverno CLI (`kyverno apply` en CI) — https://kyverno.io/docs/kyverno-cli/

**Endurecimiento de build e imágenes**
- Buenas prácticas de build de Docker — https://docs.docker.com/build/building/best-practices/
- Imágenes base distroless — https://github.com/GoogleContainerTools/distroless
- CIS Docker Benchmark — https://www.cisecurity.org/benchmark/docker
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- Especificación SARIF (formato de integración con CI) — https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html
- Code scanning de GitHub con SARIF — https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github