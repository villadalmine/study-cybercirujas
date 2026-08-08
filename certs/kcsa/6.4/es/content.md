# Material de Estudio para la Certificación KCSA — Tema 6.4: Automatización y Herramientas

---

## 1. Problema Arquitectónico de Producción y Motivación

### El Problema de Escala y Velocidad en la Seguridad Cloud-Native
En entornos cloud-native modernos que ejecutan cientos de microservicios a través de múltiples clusters de Kubernetes, el control de seguridad manual falla. Las pipelines de Integración Continua y Despliegue Continuo (CI/CD) envían actualizaciones continuamente. Las revisiones de código dirigidas por humanos, el triaje manual de vulnerabilidades y las auditorías de seguridad periódicas generan severos cuellos de botella operativos e introducen errores humanos.

Sin herramientas de seguridad automatizadas, los sistemas de producción sufren de:
1. **Configuration Drift**: Los clusters divergen gradualmente de las líneas base (baselines) de seguridad debido a comandos `kubectl apply` ad-hoc, hotfixes de emergencia o cambios operativos no rastreados.
2. **Supply Chain Vulnerabilities**: Imágenes de contenedor no firmadas ni verificadas que contienen Common Vulnerabilities and Exposures (CVEs) conocidas llegan a los registries y nodos de producción.
3. **Delayed Threat Detection**: Actividades maliciosas de post-explotación (tales como reverse shells, container escapes o privilege escalations) pasan desapercibidas porque el análisis de logs ocurre de forma retroactiva en lugar de tiempo real a nivel de kernel de Linux.
4. **Compliance Fatigue**: La recolección manual de evidencia para marcos regulatorios (PCI-DSS, SOC 2, ISO 27001, NIST SP 800-190) requiere cientos de horas de ingeniería por ciclo de auditoría.

```
 +----------------------------------------------------------------------------------------------------+
 |                                   SHIFT-LEFT TO RUNTIME PIPELINE                                   |
 +----------------------------------------------------------------------------------------------------+
 |                                                                                                    |
 |   [ Developer Commit ] ---> [ CI Pipeline: Static Analysis & Image Sign ]                          |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Registry Push ]   ---> [ Vulnerability & SBOM Attestation Scan ]                               |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Kubectl Apply ]   ---> [ K8s API Server: Admission Control (OPA/Kyverno) ]                     |
 |                                    |                                                               |
 |                                    v                                                               |
 |   [ Container Run ]   ---> [ Runtime Observability: eBPF Kernel Probe (Falco) ]                   |
 |                                                                                                    |
 +----------------------------------------------------------------------------------------------------+
```

### Paradigma de Automatización Shift-Left vs. Shift-Right
La automatización de seguridad debe abarcar todo el ciclo de vida de una workload:

*   **Shift-Left (Automatización Pre-Deployment)**: Integra controles de seguridad en repositorios de código y pipelines de CI. Las herramientas realizan pruebas estáticas de seguridad de aplicaciones (SAST), escaneo de infrastructure-as-code (IaC), escaneo de vulnerabilidades en imágenes de contenedor, generación de Software Bill of Materials (SBOM) y firma criptográfica de imágenes (Cosign/Sigstore).
*   **In-Flight (Automatización de Admission Control)**: Intercepta solicitudes al API server de Kubernetes antes de la persistencia de objetos en `etcd`. Los Dynamic Admission Webhooks (Validating y Mutating) rechazan workloads no conformes o inyectan automáticamente security contexts obligatorios.
*   **Shift-Right (Automatización de Runtime & Auditoría Continua)**: Monitorea procesos activos, modificaciones del file system, sockets de red y system calls dentro de contenedores activos utilizando eBPF o módulos de kernel. Simultáneamente, los auditores automatizados comparan continuamente el estado del cluster con las comparativas de referencia (benchmarks) de CIS (Center for Internet Security).

### Trade-Offs Operativos y Fricción Arquitectónica
La integración de herramientas de seguridad automatizadas introduce trade-offs específicos de ingeniería:

1. **Disponibilidad de Webhook vs. Disponibilidad de Cluster**: Si un Validating Admission Webhook configurado con `failurePolicy: Fail` se vuelve inalcanzable o sufre de alta latencia, el Control Plane de Kubernetes rechaza todas las solicitudes de creación y actualización de recursos, convirtiendo un fallo de la herramienta de seguridad en una caída del servicio (outage).
2. **Latencia de Escaneo vs. Velocidad de Deployment**: Los escaneos profundos de vulnerabilidades por capas y la verificación de atestaciones en CI/CD agregan latencia a la ejecución de la pipeline. Las organizaciones deben ajustar la profundidad del escaneo e implementar mecanismos agresivos de capas de almacenamiento en caché.
3. **Overhead de Kernel de eBPF vs. Visibilidad de Detección**: El rastreo profundo de syscalls en el kernel captura datos forenses detallados pero consume CPU y memoria del host. Los ring buffers mal configurados pueden descartar eventos durante una carga elevada del sistema.

---

## 2. Comparativas Técnicas y Tablas de Trade-offs

### 2.1 Motores de Policy-as-Code: Kyverno vs. OPA Gatekeeper vs. ValidatingAdmissionPolicies

| Característica / Criterio | Kyverno | OPA Gatekeeper | ValidatingAdmissionPolicies Nativas (K8s 1.30+) |
| :--- | :--- | :--- | :--- |
| **DSL / Lenguaje** | YAML nativo de Kubernetes | Rego (variante de Datalog) | CEL (Common Expression Language) |
| **Arquitectura de Ejecución** | Controller & Webhook dentro del cluster (In-cluster) | Controller & Motor OPA dentro del cluster (In-cluster) | Proceso nativo de API Server (Sin Webhook externo) |
| **Soporte de Mutación** | Nativo (superposiciones de YAML, JSON Patches) | Limitado (vía Gatekeeper Mutation Manager) | No soportado (Solo validación) |
| **Soporte de Generación** | Nativo (Genera valores predeterminados, network policies) | No soportado | No soportado |
| **Verificación de Imágenes** | Integración nativa con Sigstore/Cosign | Requiere helper externo / Rego personalizado | Requiere integración externa |
| **Curva de Aprendizaje** | Baja (Sintaxis nativa de Kubernetes) | Alta (Requiere aprender Rego) | Baja/Media (Expresiones CEL estándar) |
| **Impacto en Latencia** | Ida y vuelta por red del Webhook (~15-50ms) | Ida y vuelta por red del Webhook (~20-60ms) | Ejecución dentro del proceso (<1-3ms) |
| **Riesgo de Fail-Closed** | Alto (Dependencia de webhook externo) | Alto (Dependencia de webhook externo) | Bajo (Se ejecuta directamente dentro de `kube-apiserver`) |

### 2.2 Escáneres de Seguridad: Trivy vs. Kubescape vs. Kube-bench

| Métrica / Dimensión | Trivy (Aqua Security) | Kubescape (ARMO) | Kube-bench (Aqua Security) |
| :--- | :--- | :--- | :--- |
| **Dominio Principal** | Escaneo de Vulnerabilidades, Licencias, IaC y SBOM | Malas configuraciones y Cumplimiento (Compliance) de Kubernetes | Pruebas de CIS Kubernetes Benchmark |
| **Alcance Objetivo** | Imágenes, Filesystems, Repositorios Git, Clusters K8s | Clusters, Manifiestos, Helm Charts, Nodos Worker | Configuraciones del Sistema Operativo/Kubelet en Control Plane y Nodos Worker |
| **Modo de Ejecución** | CLI, Operator, Plugin de CI/CD | CLI, Operator, Plugin de CI/CD | CLI Independiente, Container Job, DaemonSet |
| **Mapeo de Frameworks** | CVE, NSA-CISA, MITRE ATT&CK | NSA-CISA, MITRE, CIS, SOC 2, PCI-DSS | Estrictamente CIS Benchmarks |
| **Salida de Remediación** | Versión de solución por paquete | Diffs de código directos y sugerencias de remediación | Comandos CLI específicos y ediciones de archivos |
| **Overhead de Recursos** | Bajo (Binario estático único, base de datos efímera) | Medio (Almacenamiento in-cluster, escaneos de cluster) | Extremadamente Bajo (Ejecución efímera de shell/go) |

### 2.3 Motores de Detección de Amenazas en Runtime: Falco vs. KubeArmor vs. Tracee

| Dimensión | Falco (Sysdig / CNCF) | KubeArmor (Accuknox / CNCF) | Tracee (Aqua Security) |
| :--- | :--- | :--- | :--- |
| **Tecnología Principal** | Captura de syscalls vía eBPF / Módulo de Kernel Heredado (Legacy) | eBPF + Linux Security Modules (AppArmor, SELinux) | Rastreo de syscalls y funciones de kernel vía eBPF |
| **Modo de Aplicación (Enforcement)** | Detección y Alertamiento (Requiere Falcosidekick/Response Engine para acción) | Prevención y Bloqueo en línea (Inline) vía LSM | Detección y Transmisión (Streaming) de Eventos |
| **Motor de Reglas** | Reglas basadas en YAML que coinciden con llamadas al sistema (syscalls) | Políticas de seguridad basadas en YAML | Firmas basadas en Go / basadas en Rego |
| **Contexto de Metadatos de K8s**| Rico (Enriquece syscalls brutas con Pod, Namespace, Container ID) | Rico (Interfaz nativa de Custom Resource Definition de K8s) | Rico (Enriquecimiento de Container ID y Process Namespace) |
| **Requisito de Versión de Kernel** | >= 4.14 (Kernel Module) o >= 5.8 (eBPF Moderno) | >= 4.17 (Se requieren LSM Hooks para el bloqueo) | >= 4.18 (eBPF CO-RE habilitado) |

---

## 3. Manifiestos de Producción Completos y Sintácticamente Válidos

### Manifiesto 1: CronJob de Auditoría Automatizada de CIS Benchmark (`kube-bench`)
Este manifiesto configura una auditoría programada de las configuraciones de seguridad del control plane y los nodos utilizando `kube-bench`. Monta directorios críticos del host en modo de solo lectura para evaluar permisos de archivos, propiedad y flags de procesos según los estándares de CIS.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-node-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: security-audit
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: kube-bench
        spec:
          hostPID: true
          serviceAccountName: default
          restartPolicy: Never
          containers:
          - name: kube-bench
            image: aquasec/kube-bench:v0.7.3
            command: ["kube-bench", "node", "--json"]
            securityContext:
              privileged: false
              readOnlyRootFilesystem: true
              allowPrivilegeEscalation: false
              capabilities:
                drop:
                - ALL
            volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/bin
              readOnly: true
          volumes:
          - name: var-lib-kubelet
            hostPath:
              path: /var/lib/kubelet
          - name: etc-systemd
            hostPath:
              path: /etc/systemd
          - name: etc-kubernetes
            hostPath:
              path: /etc/kubernetes
          - name: usr-bin
            hostPath:
              path: /usr/bin
```

### Manifiesto 2: Política de Kyverno para Verificación de Firma de Imagen y Restricción de Root
Esta `ClusterPolicy` de Kyverno de nivel de producción fuerza la verificación de imágenes vía Cosign (utilizando una clave pública) y bloquea workloads configuradas para ejecutarse como root o con capacidades de escalación de privilegios.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signature-and-non-root
  annotations:
    policies.kyverno.io/title: Enforce Cosign Signature and Non-Root Execution
    policies.kyverno.io/category: Pod Security Standards & Supply Chain
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      Verifies that container images are cryptographically signed by the corporate PKI
      using Cosign, and enforces non-root execution constraints on all workloads.
spec:
  validationFailureAction: Enforce
  background: true
  webhookTimeoutSeconds: 15
  rules:
  - name: verify-image-signature
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - imageReferences:
      - "ghcr.io/corporate-org/*"
      key: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p+qL8hQZp6Yd2kZ4+L7M+N9HkY1
        rV6U3W4Z8qK9tL2xN5M6P8Q1R7S4T9U2V5W8X1Y4Z7A0B3C6D9E2F5==
        -----END PUBLIC KEY-----
  - name: enforce-non-root-user
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Pods must run as non-root user, disallow privilege escalation, and drop ALL capabilities."
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
          containers:
          - name: "*"
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop:
                - ALL
```

### Manifiesto 3: ConstraintTemplate y Constraint de OPA Gatekeeper para File System Root de Solo Lectura
Este manifiesto define un `ConstraintTemplate` de OPA Gatekeeper en Rego que comprueba si todos los contenedores en un Pod aplican un file system root de solo lectura, seguido por la `Constraint` instanciada.

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sreadonlyrootfilesystem
  annotations:
    metadata.gatekeeper.sh/title: Read-Only Root Filesystem
    description: >-
      Requires container root filesystems to be read-only.
spec:
  crd:
    spec:
      names:
        kind: K8sReadOnlyRootFilesystem
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sreadonlyrootfilesystem

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not is_readonly(container)
          msg := sprintf("Container '%v' must set securityContext.readOnlyRootFilesystem to true", [container.name])
        }

        is_readonly(container) {
          container.securityContext.readOnlyRootFilesystem == true
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sReadOnlyRootFilesystem
metadata:
  name: enforce-readonly-root-fs
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
    excludedNamespaces:
      - "kube-system"
```

### Manifiesto 4: Regla Personalizada de Falco de Producción para Detección de Amenazas en Runtime
Esta configuración define una regla personalizada de Falco diseñada para activar una alerta si un proceso de shell (tal como `bash` o `sh`) es engendrado (spawned) dentro de un pod en ejecución dentro de namespaces sensibles, o si un binario intenta alterar binarios de ejecución del sistema.

```yaml
- rule: Terminal Shell Spawned in Sensitive Pod
  desc: Detects terminal shell execution inside production pods which may indicate unauthorized interactive access or post-exploitation activity.
  condition: >
    container.id != "" and
    evt.type = execve and
    evt.dir = < and
    proc.name in (bash, sh, zsh, ksh, ash) and
    k8s.ns.name in (production, payment-processing, core-infrastructure) and
    not user.name in (monitoring-agent)
  output: >
    CRITICAL: Interactive shell spawned in production container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container=%container.name image=%container.image.repository:%container.image.tag 
    cmdline=%proc.cmdline parent=%proc.pname pid=%proc.pid)
  priority: CRITICAL
  tags: [k8s, runtime, execution, pci-dss, mitre_execution]
```

---

## 4. Comandos CLI Reales y Salidas Actuales de Terminal ($)

### 4.1 Auditando Nodos con `kube-bench`
Ejecute `kube-bench` directamente en un nodo worker objetivo para evaluar el cumplimiento con los benchmarks de CIS.

```bash
$ kube-bench node --benchmark cis-1.8 --check 4.1.1,4.1.2 --json | jq .
```
```json
{
  "Controls": [
    {
      "id": "4",
      "text": "Worker Node Security Configuration",
      "tests": [
        {
          "section": "4.1",
          "desc": "Worker Node Configuration Files",
          "results": [
            {
              "test_number": "4.1.1",
              "test_desc": "Ensure that the kubelet service file permissions are set to 600 or more restrictive",
              "status": "PASS",
              "actual_value": "permissions are 600",
              "expected_result": "permissions are 600 or more restrictive"
            },
            {
              "test_number": "4.1.2",
              "test_desc": "Ensure that the kubelet service file ownership is set to root:root",
              "status": "FAIL",
              "actual_value": "ownership is 1000:1000",
              "expected_result": "ownership is root:root",
              "remediation": "Run 'chown root:root /etc/systemd/system/kubelet.service.d/10-kubeadm.conf' to fix ownership."
            }
          ]
        }
      ]
    }
  ],
  "Totals": {
    "total_pass": 1,
    "total_fail": 1,
    "total_warn": 0,
    "total_info": 0
  }
}
```

### 4.2 Escaneo de Vulnerabilidades de Imagen y Atestación con `trivy`
Escanee una imagen remota en un registry en busca de vulnerabilidades de seguridad críticas, ignorando los CVEs sin solucionar para enfocar el esfuerzo accionable de ingeniería.

```bash
$ trivy image --severity CRITICAL,HIGH --ignore-unfixed --format table ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
2026-08-07T14:22:01.102Z	INFO	Vulnerability database is up to date
2026-08-07T14:22:02.441Z	INFO	Detected OS: alpine 3.18.2
2026-08-07T14:22:02.442Z	INFO	Detecting Alpine vulnerabilities...

ghcr.io/corporate-org/payment-service:v2.1.0 (alpine 3.18.2)
=============================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬────────────────────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ InstalledVer │     FixedVer      │                         Title                          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1     │ 3.1.1-r3          │ openssl: excessive time checking DH keys               │
│ openssl      │ CVE-2023-5363  │ CRITICAL │ 3.1.1-r1     │ 3.1.1-r3          │ openssl: incorrect key length checking in ciphers      │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴────────────────────────────────────────────────────────┘
```

### 4.3 Firma y Verificación de Imágenes de Contenedor con `cosign`
Genere un par de claves (keypair), firme un artefacto de imagen y verifique su firma criptográfica.

```bash
$ cosign generate-key-pair
```
```text
Enter password for private key: 
Confirm password for private key: 
Private key written to cosign.key
Public key written to cosign.pub
```

```bash
$ cosign sign --key cosign.key ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
Enter password for private key: 
Pushing signature to: ghcr.io/corporate-org/payment-service:sha256-a1b2c3d4e5f6...sig
```

```bash
$ cosign verify --key cosign.pub ghcr.io/corporate-org/payment-service:v2.1.0
```
```text
Verification for ghcr.io/corporate-org/payment-service:v2.1.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"ghcr.io/corporate-org/payment-service"},"image":{"docker-manifest-digest":"sha256:8f4c2e617a99b2e7d3f10111213141516171819202122232425262728293031a"},"type":"cosign container image signature"},"optional":null}]
```

### 4.4 Pruebas de Aplicación (Enforcement) del Admission Webhook
Intente desplegar un manifiesto de contenedor no conforme para verificar que Kyverno bloquee la solicitud en el momento de admisión.

```bash
$ kubectl apply -f insecure-pod.yaml
```
```text
Error from server (Forbidden): error when creating "insecure-pod.yaml": admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request:

resource Pod/production/insecure-nginx was blocked due to the following policies:

enforce-signature-and-non-root:
  verify-image-signature:
    failed to verify signature for ghcr.io/untrusted/nginx:latest: no matching signatures found
  enforce-non-root-user:
    autogen-enforce-non-root-user: 'validation error: Pods must run as non-root user, disallow privilege escalation, and drop ALL capabilities. Rule autogen-enforce-non-root-user failed at path /spec/template/spec/securityContext/runAsNonRoot/'
```

---

## 5. Guía de Verificación y Diagnóstico de Fallos

```
 +----------------------------------------------------------------------------------------------------+
 |                                ADMISSION WEBHOOK DIAGNOSTIC WORKFLOW                               |
 +----------------------------------------------------------------------------------------------------+
 |                                                                                                    |
 |  [ Pod Creation Fails ]                                                                            |
 |          |                                                                                         |
 |          v                                                                                         |
 |  Is kube-apiserver throwing API server timeout (504)?                                              |
 |          |-- YES --> Check Webhook Pod status, TLS secret expiration, and Cluster Network CNI.     |
 |          |                                                                                         |
 |          +-- NO  --> Is failure caused by Policy violation?                                        |
 |                       |-- YES --> Inspect policy rule definitions & pod SecurityContext.           |
 |                       |-- NO  --> Check webhook failurePolicy (Fail vs Ignore).                     |
 |                                                                                                    |
 +----------------------------------------------------------------------------------------------------+
```

### Procedimiento de Diagnóstico 1: Solución de Problemas de Bucles de Fallo en Admission Webhooks
Cuando `kube-apiserver` no puede alcanzar un admission webhook (por ejemplo, Kyverno o Gatekeeper), las solicitudes a la API se bloquean o agotan el tiempo de espera (time out).

1.  **Inspeccionar las Configuraciones de Webhook**:
    ```bash
    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o wide
    ```
2.  **Verificar los Endpoints del Servicio de Webhook**:
    Compruebe si los endpoints respaldados por el servicio del admission controller están activos y saludables:
    ```bash
    kubectl get endpoints -n kyverno kyverno-svc
    ```
3.  **Validar la Expiración del Certificado TLS del Webhook**:
    Los admission webhooks requieren certificados TLS válidos confiados por el CA bundle del `kube-apiserver`. Compruebe la validez del certificado:
    ```bash
    kubectl get secret -n kyverno kyverno-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
    ```
4.  **Ejecutar el Procedimiento de Emergencia Break-Glass**:
    Si el control plane queda bloqueado debido a un webhook roto configurado con `failurePolicy: Fail`, aplique un parche temporal a la configuración del webhook cambiándolo a `Ignore`:
    ```bash
    kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
      --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
    ```

### Procedimiento de Diagnóstico 2: Depuración de Pérdidas de Eventos de eBPF y Problemas de Rendimiento en Falco
Si la detección de amenazas en runtime pierde eventos o falla (crashes) durante picos de tráfico, inspeccione el estado de salud del buffer de eventos del kernel.

1.  **Revisar los Logs de los Pods de Falco en busca de Pérdidas de Buffer**:
    ```bash
    kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -E "drop|buffer|overload"
    ```
    *Salida de Advertencia Esperada*:
    `14:35:12.102341000: Warning: eBPF ring buffer full. Dropped 4512 events.`

2.  **Ajustar las Capacidades del Ring Buffer de eBPF**:
    Edite la configuración de Falco (`falco.yaml`) para incrementar el tamaño del buffer de eBPF:
    ```yaml
    sysctls:
      ebpf:
        buf_size_preset: 4 # Increases buffer memory allocation (1=small, 4=max)
    ```

3.  **Verificar el Estado del Driver del Kernel**:
    Confirme si Falco está funcionando mediante eBPF moderno, eBPF heredado (legacy) o módulo del kernel:
    ```bash
    kubectl exec -ti -n falco daemonset/falco -- falco-driver-loader status
    ```
    *Salida Esperada*:
    `[*] eBPF probe is loaded and active in the kernel.`

### Procedimiento de Diagnóstico 3: Resolución de Fallos en la Verificación de Firma de Imágenes
Cuando las imágenes válidas son rechazadas por los admission controllers de Kyverno o Cosign:

1.  **Inspeccionar el Digest del Manifiesto de la Imagen Bruta**:
    Las firmas se mapean a digests de imagen exactos, no a tags mutables. Verifique el digest de la imagen:
    ```bash
    crane digest ghcr.io/corporate-org/payment-service:v2.1.0
    ```
2.  **Obtener Firmas Manualmente**:
    Determine si el artefacto de firma existe en el registry OCI:
    ```bash
    cosign tree ghcr.io/corporate-org/payment-service:v2.1.0
    ```
3.  **Verificar Incoincidencia de Claves (Key Mismatch) en Cosign**:
    Verifique que la clave pública configurada dentro de la `ClusterPolicy` de Kyverno coincida con la clave utilizada durante la ejecución de `cosign sign` en CI:
    ```bash
    cosign verify --key /tmp/cluster-public-key.pub ghcr.io/corporate-org/payment-service:v2.1.0
    ```

---

## 6. Referencias

*   **Currículum Oficial de CNCF KCSA**:  
    [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

*   **Documentación de Control de Admisión Dinámico de Kubernetes**:  
    [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

*   **Politica de Admisión de Validación de Kubernetes (CEL)**:  
    [https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)

*   **Documentación y Políticas de Seguridad de Kyverno**:  
    [https://kyverno.io/docs/](https://kyverno.io/docs/)

*   **Documentación de OPA Gatekeeper**:  
    [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)

*   **Documentación de Trivy de Aqua Security**:  
    [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)

*   **Documentación de Cosign de Sigstore**:  
    [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)

*   **Documentación de Seguridad en Runtime de Falco**:  
    [https://falco.org/docs/](https://falco.org/docs/)

*   **CIS Kubernetes Benchmarks**:  
    [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)