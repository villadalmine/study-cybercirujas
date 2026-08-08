# Guía de Estudio KCSA: Tema 6.4 – Automatización y Herramientas

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 6:** Cloud Native Security Ecosystem  
**Subtema 6.4:** Automatización y Herramientas  
**Ponderación del examen:** 2.5%  

---

## 1. Profundización Arquitectónica y Fundamentos Mecánicos

La automatización de la seguridad en entornos cloud-native desplaza (shift left) los controles de seguridad hacia los flujos de trabajo de los desarrolladores (pipelines de CI/CD) y automatiza el cumplimiento continuo y la protección en tiempo de ejecución (runtime) dentro de los clusters de Kubernetes en producción. El objetivo principal es reemplazar la supervisión manual de seguridad (security gatekeeping) por motores de aplicación de políticas automatizados, deterministas y escalables.

```
                   +-------------------------------------------------------------+
                   |                 SHIFT-LEFT SECURITY (CI/CD)                |
                   +-------------------------------------------------------------+
                   |  1. IaC & Manifest Linting (KubeLinter / Checkov / OPA)    |
                   |  2. Container Image & Dependency Scan (Trivy / Grype)       |
                   |  3. Supply Chain Integrity & Signing (Cosign / Syft SBOM)   |
                   +-------------------------------------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |               IN-CLUSTER ADMISSION AUTOMATION               |
                   +-------------------------------------------------------------+
                   |  4. Validating/Mutating Admission Webhooks (Kyverno / OPA)  |
                   |     - Blocks non-compliant resources before etcd write      |
                   +-------------------------------------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |            CONTINUOUS IN-CLUSTER COMPLIANCE (CD)            |
                   +-------------------------------------------------------------+
                   |  5. Security Operators (Trivy Operator / Kubescape)         |
                   |     - Generates VulnerabilityReport / ConfigAuditReport CRDs|
                   +-------------------------------------------------------------+
```

### Conceptos Arquitectónicos Clave

1. **Shift-Left vs. Aplicación en el Cluster (In-Cluster Enforcement):**
   - **Shift-Left (CI/CD):** Captura vulnerabilidades, malas configuraciones y alteraciones en la cadena de suministro antes del despliegue. Bucle de retroalimentación rápido para desarrolladores, sin sobrecarga en tiempo de ejecución (runtime).
   - **Admisión en el Cluster (Webhooks de la API de Kubernetes):** Sirve como una red de seguridad inmutable. Garantiza que incluso si la CI/CD se omite o se compromete, los manifiestos no conformes no se puedan persistir en `etcd`.
   - **Auditoría Continua basada en Operators:** Detecta CVEs recientemente divulgados (zero-days) en cargas de trabajo (workloads) ya en ejecución y señala la desviación de configuración (configuration drift).

2. **Mecánica de Admission Webhooks:**
   - El API Server invoca endpoints registrados de `MutatingWebhookConfiguration` y `ValidatingWebhookConfiguration` durante el ciclo de vida del objeto.
   - Las decisiones del Webhook ocurren **después** de la Autenticación y Autorización (RBAC), pero **antes** de que los objetos se persistan en `etcd`.
   - **Compromisos en la Política de Fallos (Failure Policy Trade-offs):** Establecer `failurePolicy: Fail` aplica una seguridad estricta, pero introduce riesgos de disponibilidad si el controlador del webhook queda fuera de línea. Establecer `failurePolicy: Ignore` prioriza la disponibilidad del cluster a costa de omitir controles de seguridad durante eventos de interrupción.

3. **Patrón Operator para la Automatización de la Seguridad:**
   - Los escáneres in-cluster se ejecutan como Operators estándar de Kubernetes, reconciliando Custom Resource Definitions (CRDs) como `VulnerabilityReport`, `ClusterImageScan` o `ConfigAuditReport`.
   - La sobrecarga de recursos y el rendimiento deben gobernarse mediante límites de `resource` y `nodeSelector` / `tolerations` dedicados para evitar afectar a las cargas de trabajo (workloads) principales.

---

## 2. Ejercicios Guiados de Producción

---

### Módulo 1: Escaneo de Vulnerabilidades Shift-Left y Gates de CI/CD Automatizados

En este módulo, automatizarás el escaneo de vulnerabilidades en imágenes de contenedores y la verificación de la Lista de Materiales del Software (SBOM, Software Bill of Materials) utilizando `trivy` en un formato de pipeline de automatización de CI/CD.

#### Paso 1: Ejecutar un Escaneo Local de Vulnerabilidades con Criterios Estrictos de Fallo

Ejecutá `trivy` contra una imagen de contenedor específica, filtrando exclusivamente vulnerabilidades `HIGH` y `CRITICAL` con correcciones conocidas. Configurá la herramienta para que devuelva un código de salida distinto de cero al fallar para bloquear los pipelines automatizados.

```bash
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --exit-code 1 \
  --format table \
  python:3.9-slim
```

**Resultado Esperado:**

```
2026-08-07T20:40:12.112Z	INFO	Vulnerability scanning is enabled
2026-08-07T20:40:12.112Z	INFO	Detected OS: debian 11.6
2026-08-07T20:40:12.120Z	INFO	Number of language-specific files: 0

python:3.9-slim (debian 11.6)
=============================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬────────────────────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ Installed    │  Fixed Version    │                         Title                          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ libssl1.1    │ CVE-2023-0286  │ CRITICAL │ 1.1.1n-0+deb11u3 │ 1.1.1n-0+deb11u4  │ OpenSSL: X.400 address type confusion in               │
│              │                │          │              │                   │ GENERAL_NAME_cmp                                       │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ zlib1g       │ CVE-2023-45853 │ HIGH     │ 1.2.11.dfsg-2│ 1.2.11.dfsg-2+deb11u1│ zlib: integer overflow in MiniZip                      │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴────────────────────────────────────────────────────────┘

Error: exit status 1
```

#### Paso 2: Generación Automatizada de SBOM y Escaneo de Atestaciones

Generá un Software Bill of Materials (SBOM) compatible con SPDX para una imagen con el fin de cumplir con los requisitos de trazabilidad de la cadena de suministro.

```bash
trivy image \
  --format spdx-json \
  --output sbom.spdx.json \
  python:3.9-slim
```

Verificá que el SBOM en formato JSON generado contenga los metadatos de identificación del paquete:

```bash
head -n 25 sbom.spdx.json
```

**Resultado Esperado:**

```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-07T20:41:00Z",
    "creators": [
      "Tool: trivy-0.50.0"
    ]
  },
  "name": "python:3.9-slim",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "http://aquasecurity.github.io/trivy/container/python:3.9-slim-12345",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-debian-libssl1.1",
      "name": "libssl1.1",
      "versionInfo": "1.1.1n-0+deb11u3",
      "downloadLocation": "NONE",
      "filesAnalyzed": false
    }
  ]
}
```

---

#### Preguntas de Comprensión del Módulo 1

1. ¿Por qué se recomienda pasar `--ignore-unfixed` al configurar gates de seguridad automatizados en pipelines de CI/CD empresariales?
2. Si un pipeline ejecuta `trivy image` con `--exit-code 1`, ¿qué mecanismo hace que el servidor de CI (por ejemplo, GitHub Actions, GitLab CI) detenga la ejecución de las tareas de despliegue posteriores?

---

### Módulo 2: Policy-as-Code y Control de Admisión Automatizado por Webhooks

En este módulo, redactarás y validarás un manifiesto **ClusterPolicy de Kyverno** de nivel de producción para automatizar la aplicación de la seguridad en el límite de admisión de la API de Kubernetes.

#### Paso 1: Desplegar una ClusterPolicy de Seguridad de Producción

Aplicá el siguiente manifiesto `ClusterPolicy` completo y sintácticamente válido para forzar sistemas de archivos de raíz de solo lectura y no permitir la escalada de privilegios en todas las cargas de trabajo (workloads) que no sean del sistema.

Creá `policy-disallow-privilege-escalation.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privilege-escalation
  annotations:
    policies.kyverno.io/title: Disallow AllowPrivilegeEscalation
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Privilege escalation allows a process to gain more privileges than its parent
      process. This policy ensures allowPrivilegeEscalation is explicitly set to false.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-privilege-escalation
    match:
      any:
      - resources:
          kinds:
          - Pod
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
  - validate:
      message: "Privilege escalation is disallowed. Set securityContext.allowPrivilegeEscalation to false."
      pattern:
        spec:
          containers:
          - securityContext:
              allowPrivilegeEscalation: false
```

Aplicá el manifiesto a tu cluster:

```bash
kubectl apply -f policy-disallow-privilege-escalation.yaml
```

**Resultado Esperado:**

```
clusterpolicy.kyverno.io/disallow-privilege-escalation created
```

#### Paso 2: Probar la Mecánica de Aplicación del API Server

Intentá desplegar un manifiesto de carga de trabajo (workload) no conforme que omita `allowPrivilegeEscalation: false` o lo establezca explícitamente en `true`.

Creá `test-noncompliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-test-pod
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    securityContext:
      allowPrivilegeEscalation: true
```

Ejecutá `kubectl apply`:

```bash
kubectl apply -f test-noncompliant-pod.yaml
```

**Resultado Esperado:**

```
Error from server (Forbidden): error when creating "test-noncompliant-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/vulnerable-test-pod was blocked due to the following policies:

disallow-privilege-escalation:
  validate-privilege-escalation: 'Privilege escalation is disallowed. Set securityContext.allowPrivilegeEscalation
    to false.'
```

#### Paso 3: Inspeccionar la Configuración y Métricas de Salud de los Admission Webhooks

Consultá los objetos `ValidatingWebhookConfiguration` activos del cluster para inspeccionar las políticas de fallo y las configuraciones de tiempo de espera (timeout):

```bash
kubectl get validatingwebhookconfigurations -o custom-columns=NAME:.metadata.name,FAIL_POLICY:.webhooks[*].failurePolicy,TIMEOUT:.webhooks[*].timeoutSeconds
```

**Resultado Esperado:**

```
NAME                                      FAIL_POLICY   TIMEOUT
kyverno-resource-validating-webhook-cfg   Fail          10
cert-manager-webhook                      Fail          30
```

---

#### Preguntas de Comprensión del Módulo 2

1. En el manifiesto `ClusterPolicy`, ¿cuál es la diferencia operativa entre configurar `validationFailureAction: Audit` frente a `validationFailureAction: Enforce`?
2. ¿Qué riesgo se introduce si una `ValidatingWebhookConfiguration` tiene `failurePolicy: Fail` y el despliegue (deployment) del controlador del webhook subyacente sufre una caída total de nodos?

---

### Módulo 3: Cumplimiento Continuo en el Cluster y Automatización de Escaneo basada en Operators

En este módulo, examinarás y diagnosticarás informes continuos e automatizados de vulnerabilidades generados por Operators dentro del cluster.

#### Paso 1: Desplegar un Manifiesto de Cumplimiento con Anotaciones de Escaneo

Creá un manifiesto de despliegue `secure-app-deployment.yaml` configurado con campos estrictos de contexto de seguridad (security context) para la evaluación continua por parte del Operator.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: default
  labels:
    app.kubernetes.io/name: secure-app
    app.kubernetes.io/component: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      containers:
      - name: web
        image: ccr.io/google-containers/pause:3.9
        securityContext:
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 10001
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
```

Aplicá el despliegue (deployment):

```bash
kubectl apply -f secure-app-deployment.yaml
```

**Resultado Esperado:**

```
deployment.apps/secure-app created
```

#### Paso 2: Consultar las Definiciones de Recursos Personalizados (CRDs) Generadas por Escáneres Automatizados

Listá las CRDs `VulnerabilityReport` y `ConfigAuditReport` gestionadas por Operators de seguridad automatizados dentro del cluster (por ejemplo, Trivy Operator / Kubescape):

```bash
kubectl get vulnerabilityreports -n default -o wide
```

**Resultado Esperado:**

```
NAME                                  REPOSITORY                      TAG    SCANNER   AGE   CRITICAL   HIGH   MEDIUM   LOW
replica-set-secure-app-67998b48bb-web ccr.io/google-containers/pause  3.9    Trivy     45s   0          0      0        0
```

Inspeccioná los metadatos detallados de hallazgos de seguridad desde la CRD:

```bash
kubectl get vulnerabilityreports replica-set-secure-app-67998b48bb-web -n default -o jsonpath='{.report.summary}' | jq .
```

**Resultado Esperado:**

```json
{
  "criticalCount": 0,
  "highCount": 0,
  "lowCount": 0,
  "mediumCount": 0,
  "unknownCount": 0
}
```

#### Paso 3: Solución de Problemas Diagnósticos en Fallos de Webhooks y Security Operators

Diagnosticá problemas de alta latencia o rechazo del API Server causados por webhooks de seguridad utilizando `kubectl logs` y `kubectl get events`.

Consultá los eventos del sistema en busca de marcadores de fallo de Webhook:

```bash
kubectl get events -n default --field-selector reason=FailedCreate
```

**Resultado Esperado:**

```
LAST SEEN   TYPE      REASON         OBJECT                   MESSAGE
12s         Warning   FailedCreate   replicaset/bad-app-54f   Error creating: admission webhook "validate.kyverno.svc-fail" denied the request: timeout calling webhook
```

Verificá las métricas de latencia de los admission webhooks a través del endpoint de métricas del API Server (si está accesible):

```bash
kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_count
```

**Resultado Esperado:**

```
apiserver_admission_webhook_admission_duration_seconds_count{name="validate.kyverno.svc-fail",operation="CREATE",type="validating"} 452
```

---

#### Preguntas de Comprensión del Módulo 3

1. ¿Por qué se prefieren las Custom Resource Definitions (CRDs) como `VulnerabilityReport` en lugar de almacenar los resultados de los escaneos en ConfigMaps o bases de datos externas para la automatización nativa de Kubernetes?
2. ¿Qué secuencia de comandos de diagnóstico debería ejecutar un SRE si las creaciones de Pods se bloquean indefinidamente en todo el cluster?

---

## 3. Referencias Oficiales y Enlaces a la Documentación

- **CNCF KCSA Curriculum Repository:** [cncf/curriculum KCSA Document](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Dynamic Admission Control:** [Kubernetes Official Documentation - Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- **Kyverno Policy Architecture:** [Kyverno Documentation - Concepts & Policies](https://kyverno.io/docs/writing-policies/)
- **Aqua Security Trivy Documentation:** [Trivy Vulnerability Scanning CLI](https://aquasecurity.github.io/trivy/latest/)
- **CNCF Financial & Security Technical Advisory Group (TAG-Security):** [CNCF Cloud Native Security Supply Chain Best Practices](https://tag-security.cncf.io/)

---

## 4. Respuestas y Explicaciones Detalladas

<details>
<summary><strong>Hacé clic para expandir las Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas del Módulo 1

1. **Por qué se utiliza `--ignore-unfixed` en pipelines empresariales:**  
   Pasar `--ignore-unfixed` suprime las alertas de fallo para aquellas vulnerabilidades que actualmente no disponen de un parche publicado por los mantenedores del SO o del paquete upstream. En pipelines de CI/CD de producción, hacer fallar una compilación por un CVE que no se puede parchear detiene la entrega de software sin ofrecer a los desarrolladores una ruta de remediación inmediata. Esto evita la fatiga en los pipelines y enfoca el esfuerzo de los desarrolladores estrictamente en actualizaciones sobre las que sí pueden actuar.

2. **Mecanismo de fallo en la ejecución de CI (`--exit-code 1`):**  
   Los sistemas operativos y entornos de shell compatibles con POSIX devuelven un código de estado de salida (0 para éxito, 1–255 para errores) cuando finaliza un proceso. Los orquestadores de CI (como GitHub Actions, GitLab CI o Jenkins) verifican el código de retorno de los comandos ejecutados en cada paso. Cuando `trivy` devuelve `1`, el runner intercepta este estado distinto de cero, marca el paso como fallido, omite las etapas posteriores del pipeline (como `cd-deploy`) y marca el pipeline de compilación como fallido.

---

### Respuestas del Módulo 2

1. **`validationFailureAction: Audit` vs `Enforce`:**  
   - **`Audit`:** El API server permite que los objetos no conformes se creen y se escriban en `etcd`. Sin embargo, los eventos de violación de políticas se registran en los logs de auditoría del API server y las entradas de estado se reportan en los CRDs de informes de políticas de Kyverno. Este modo se utiliza para probar nuevas políticas en seco (dry-run) en producción sin arriesgar la caída de las aplicaciones.  
   - **`Enforce`:** El admission controller rechaza activamente las solicitudes de creación/actualización de la API que violen la política, devolviendo un estado HTTP 403 Forbidden directamente al usuario o sistema de CI solicitante.

2. **Riesgos de `failurePolicy: Fail` durante caídas del controlador:**  
   Cuando se configura `failurePolicy: Fail`, el API Server de Kubernetes *debe* recibir una respuesta de validación HTTP 200 exitosa por parte del admission controller antes de permitir que proceda cualquier operación de la API coincidente. Si los pods del controlador del webhook sufren un crash, pierden un nodo o quedan aislados en la red, el API server bloqueará *todas* las creaciones o actualizaciones de recursos posteriores que coincidan con el patrón de configuración del webhook. Esto genera una interrupción grave del cluster donde los deployments, statefulsets y horizontal pod autoscalers no pueden instanciar nuevos pods.

---

### Respuestas del Módulo 3

1. **Por qué se prefieren los CRDs para almacenar el cumplimiento continuo:**  
   Almacenar los informes de seguridad como CRDs permite a los equipos de plataforma aprovechar el RBAC nativo de Kubernetes, los watchers de la API, los bucles de reconciliación de los controladores y las herramientas de CLI (`kubectl`). Las métricas de seguridad se convierten en objetos nativos de la API que pueden activar operators de remediación automatizados, alimentar dashboards de GitOps o consultarse a través de endpoints estándar de la API de Kubernetes sin introducir dependencias de bases de datos de terceros dentro del control plane.

2. **Flujo de trabajo de diagnóstico para creaciones de Pods bloqueadas en todo el cluster:**  
   - **Paso 1:** Ejecutar `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` para identificar todos los admission hooks activos.
   - **Paso 2:** Verificar los eventos del API server usando `kubectl get events -n default --field-selector type=Warning` para buscar errores de timeout o rechazo del webhook.
   - **Paso 3:** Inspeccionar la salud y los logs de los pods controladores del webhook de seguridad (por ejemplo, `kubectl logs -n kyverno -l app=kyverno`).
   - **Paso 4:** Si se requiere una mitigación de emergencia para restaurar la disponibilidad del cluster, establecer temporalmente `failurePolicy: Ignore` en la configuración del webhook usando `kubectl edit validatingwebhookconfiguration <webhook-name>` o eliminar temporalmente el objeto webhook problemático.

</details>