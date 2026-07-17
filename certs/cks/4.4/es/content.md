# 4.4 Static Analysis de Workloads y Container Images (Kubesec, KubeLinter)

## Por qué importa

El *static analysis* es una técnica de **shift-left security**: analiza manifiestos YAML de Kubernetes, Helm charts y Dockerfiles/imágenes **antes** de que lleguen a un cluster en ejecución, sin necesidad de desplegar nada. Detecta misconfigurations comunes (containers privilegiados, falta de `resource limits`, capabilities innecesarias, uso de `:latest`, montaje del socket de Docker, etc.) en el pipeline de CI/CD, donde corregirlas es barato, en lugar de en producción, donde es caro y riesgoso.

Este tema se enfoca en dos herramientas mencionadas explícitamente en el curriculum:

- **Kubesec**: analiza manifiestos de Kubernetes (Pods, Deployments, etc.) y devuelve un **score** de riesgo.
- **KubeLinter**: hace *lint* de manifiestos de Kubernetes y Helm charts contra un set de reglas de seguridad y best practices, devolviendo errores/warnings por regla (sin scoring numérico).

También se cubre brevemente el análisis estático de **container images** (Dockerfiles), ya que el tema del curriculum incluye explícitamente "container images" además de "workloads".

> Diferencia clave con el tema de "vulnerability scanning" (4.5): el static analysis de este tema evalúa **configuración** (misconfigurations, hardening), no CVEs conocidos en paquetes del sistema operativo o dependencias. Esa es la función de Trivy/Grype, que se ve en otro tema.

---

## Kubesec

### Qué hace

Kubesec analiza un manifiesto de Kubernetes y asigna **puntos** a cada práctica de seguridad presente o ausente, según reglas fijas. El resultado final es un score numérico: mientras más alto, más "seguro" es el manifiesto según esas reglas.

- Reglas **Critical**: puntúan muy negativo (ej. `securityContext.privileged == true`).
- Reglas **Advise**: suman o restan puntos según buenas prácticas (ej. `runAsNonRoot`, `capabilities.drop: ["ALL"]`, `readOnlyRootFilesystem`, `resources.limits.cpu/memory` definidos, no montar `hostPath`, no usar `hostNetwork`/`hostPID`/`hostIPC`).

### Formas de uso

```bash
# Binario standalone
kubesec scan pod.yaml

# Como imagen de container (sin instalar nada)
docker run -i kubesec/kubesec:v2 scan /dev/stdin < pod.yaml

# Como admission webhook (bloquea manifiestos por debajo de un score mínimo)
```

### Ejemplo

Manifiesto de prueba:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo
spec:
  containers:
  - name: demo
    image: nginx:1.25
    securityContext:
      privileged: true
```

```bash
kubesec scan pod.yaml
```

Salida (resumida):

```json
[
  {
    "object": "Pod/demo.default",
    "valid": true,
    "message": "Failed with a score of -30 points",
    "score": -30,
    "scoring": {
      "critical": [
        {
          "selector": "containers[] .securityContext .privileged == true",
          "reason": "Privileged containers can allow almost completely unrestricted host access",
          "points": -30
        }
      ],
      "advise": [
        {
          "selector": "containers[].securityContext.runAsNonRoot == true",
          "reason": "Force the running image to run as a non-root user",
          "points": 1
        },
        {
          "selector": "containers[].resources.limits.cpu",
          "reason": "Enforcing CPU limits prevents DOS via resource exhaustion",
          "points": 1
        }
      ]
    }
  }
]
```

Ese manifiesto **falla** por tener `privileged: true`. Corrigiendo la configuración (quitar `privileged`, agregar `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, `resources.limits`) el score sube y pasa a positivo.

### Integración en CI/CD

Kubesec se usa típicamente como *gate* en el pipeline: se falla el build si el score es menor a un umbral.

```bash
SCORE=$(kubesec scan pod.yaml | jq '.[0].score')
if [ "$SCORE" -lt 0 ]; then
  echo "Manifest inseguro (score $SCORE), abortando pipeline"
  exit 1
fi
```

---

## KubeLinter

### Qué hace

KubeLinter (proyecto de StackRox/Red Hat, ahora bajo CNCF) hace *lint* de manifiestos de Kubernetes YAML **y** Helm charts, aplicando checks predefinidos agrupados por categoría (security, configuration, DoS-vector, etc.). A diferencia de Kubesec, no da un score: reporta cada violación con el nombre del check y una remediación sugerida.

### Instalación y uso básico

```bash
# Binario standalone (o vía go install / brew / container image)
kube-linter lint deployment.yaml

# Contra un directorio completo o un Helm chart
kube-linter lint ./manifests/
kube-linter lint ./my-helm-chart/
```

### Ejemplo

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
```

```bash
kube-linter lint deployment.yaml
```

Salida (resumida):

```text
deployment.yaml: (object: <no namespace>/nginx-deployment apps/v1, Kind=Deployment) container "nginx" does not specify a read-only root file system (check: "no-read-only-root-fs", remediation: Set readOnlyRootFilesystem to true...)
deployment.yaml: (object: <no namespace>/nginx-deployment apps/v1, Kind=Deployment) container "nginx" has no resource requests/limits (check: "unset-cpu-requirements", remediation: Set CPU requests/limits...)
deployment.yaml: (object: <no namespace>/nginx-deployment apps/v1, Kind=Deployment) image tag "latest" used (check: "latest-tag", remediation: Use a specific container image tag...)

Error: found 3 lint errors
```

### Listar y explorar checks

```bash
kube-linter checks list
kube-linter templates list
```

### Configuración personalizada

Se puede incluir/excluir checks (o crear checks propios a partir de templates) con un archivo de config:

```yaml
# .kube-linter.yaml
checks:
  exclude:
    - "unset-cpu-requirements"
  include:
    - "no-read-only-root-fs"
    - "privileged-container"
    - "run-as-non-root"
    - "host-network"
    - "host-pid"
    - "docker-sock"
```

```bash
kube-linter lint --config .kube-linter.yaml deployment.yaml
```

Esto es útil en pipelines donde algunas reglas no aplican al contexto del equipo, sin desactivar el linting completo.

---

## Static analysis de container images (Dockerfiles)

El curriculum menciona explícitamente "container images", no solo workloads. El equivalente de static analysis para imágenes/Dockerfiles (distinto de escanear CVEs) es:

- **hadolint**: lint del Dockerfile en sí (mejores prácticas: no usar `latest`, evitar `ADD` cuando alcanza `COPY`, combinar `RUN` para reducir capas, no correr como root explícitamente, etc.).

```bash
hadolint Dockerfile
```

```text
Dockerfile:1 DL3006 warning: Always tag the version of an image explicitly
Dockerfile:5 DL3002 error: Last USER should not be root
Dockerfile:7 DL3009 info: Delete the apt-get lists after installing something
```

- **Dockle**: inspecciona la **imagen ya construida** contra el CIS Docker Benchmark y best practices (no vulnerabilidades de paquetes, sino configuración: usuario root por defecto, permisos de archivos, metadata faltante).

```bash
dockle myapp:1.0
```

```text
WARN    - CIS-DI-0001: Create a user for the container
        * Last user should not be root
INFO    - CIS-DI-0005: Enable Content trust for Docker
        * export DOCKER_CONTENT_TRUST=1
```

Ambas se ejecutan en la etapa de build del pipeline, antes del push al registry.

---

## Otras herramientas del mismo espacio (contexto, no foco del tema)

El curriculum usa "e.g." — pueden aparecer variantes conceptualmente equivalentes:

- **kube-score**: similar a Kubesec, lint de manifiestos con explicaciones detalladas por regla.
- **Polaris**: lint + dashboard de configuración de workloads.
- **Checkov / Conftest (OPA)**: policy-as-code genérico, aplicable a manifiestos K8s, Terraform, Dockerfiles, etc., usando Rego u otros lenguajes de policy.

Conceptualmente todas resuelven el mismo problema: comparar YAML/config contra un set de reglas de seguridad **sin ejecutar nada**.

---

## Tips para el examen

- Practicá correr `kubesec scan` y `kube-linter lint` contra manifiestos con fallas típicas (`privileged: true`, sin `resources`, `image: x:latest`, `hostPath`, `hostNetwork: true`) para reconocer rápido qué check dispara cada una.
- Con `kube-linter`, memorizá cómo filtrar output con `--config` para no perder tiempo leyendo warnings irrelevantes al escenario del examen.
- El examen puede pedir "corregir" el manifiesto hasta que la herramienta no reporte errores/score negativo — practicá el ciclo *lint → editar → re-lint* con `vim`/`kubectl` rápido.
- Si la tool no está preinstalada en el entorno del examen, revisá si hay que descargar el binario (verificá conectividad permitida a los dominios oficiales del vendor, según las reglas del examen).

---

## Referencias

- Kubesec — sitio oficial y reglas de scoring: https://kubesec.io/
- Kubesec — repositorio: https://github.com/controlplaneio/kubesec
- KubeLinter — documentación oficial: https://docs.kubelinter.io/
- KubeLinter — repositorio y lista de checks: https://github.com/stackrox/kube-linter
- hadolint — repositorio: https://github.com/hadolint/hadolint
- Dockle — repositorio: https://github.com/goodwithtech/dockle
- kube-score: https://kube-score.com/
- Open Policy Agent / Conftest: https://www.openpolicyagent.org/docs/latest/ | https://www.conftest.dev/
- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf