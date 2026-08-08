# Dominio KCSA 1.3: Controles y Frameworks

## 1. Motivación Arquitectónica y Problemática en Producción

En entornos empresariales de Kubernetes en producción, la seguridad no se puede gestionar como una lista de verificación ad-hoc o un protocolo de parcheo reactivo. A medida que los entornos cloud-native se escalan a través de clusters multi-tenant, diversos microservicios y pipelines de entrega continua, las organizaciones se enfrentan a desafíos críticos de gestión de la seguridad:

1. **Drift y Aplicación Inconsistente**: Sin guardrails automatizados, los equipos de desarrollo despliegan workloads con configuraciones de seguridad variables, que van desde la ejecución como root (`runAsUser: 0`) y sistemas de archivos root de escritura hasta comunicaciones de red no restringidas (`0.0.0.0/0`).
2. **Mapeo Regulatorio y de Cumplimiento**: Los frameworks de cumplimiento empresarial estándar (tales como PCI-DSS, SOC 2, HIPAA e ISO 27001) no hablan "Kubernetes" de forma nativa. Los equipos de ingeniería de seguridad deben mapear controles regulatorios de alto nivel (p. ej., Mínimo Privilegio, Encriptación de Datos en Tránsito, Registro de Auditoría) a primitivas de runtime de contenedores de bajo nivel.
3. **Brechas de Vulnerabilidad del Modelo de Seguridad de las 4Cs**: Los fallos de seguridad en las capas superiores no se pueden mitigar mediante controles en las capas inferiores, y viceversa. Asegurar la **Cloud** (infraestructura IaaS) no compensa un **Código** débil o **Contenedores** mal configurados.

```
            +-------------------------------------------------------+
            |                        CODE                           |
            |   (Static Analysis, Secret Scanning, Dependencies)    |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                      CONTAINER                        |
            |     (Image Signing, Vulnerability Scanning, SBOM)     |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                       CLUSTER                         |
            |   (RBAC, NetworkPolicies, Pod Security, Audit Logs)   |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                        CLOUD                          |
            |   (IAM, Node Hardening, VPC Segmentation, Encryption)  |
            +-------------------------------------------------------+
```

Para resolver estos desafíos arquitectónicos, la Seguridad Cloud Native se basa en **Frameworks de Seguridad** estructurados y **Controles de Seguridad** accionables:
* **Frameworks** (p. ej., NIST SP 800-190, CIS Benchmarks, Guía de Hardening de NSA/CISA, CNCF TAG-Security Lifecycle Model, MITRE ATT&CK para Kubernetes) proporcionan la estructura de gobernanza, las taxonomías de amenazas y los objetivos de control.
* **Controles** (p. ej., Pod Security Admission, Network Policies, políticas de OPA Gatekeeper/Kyverno, perfiles de Seccomp, restricciones de RBAC) aplican el límite operativo dentro del control plane y el data plane del cluster.

---

## 2. Matriz de Comparación Técnica y Trade-Offs

Al seleccionar controles de seguridad y frameworks de gobernanza para clusters de Kubernetes en producción, los arquitectos de plataformas deben balancear la eficacia de la seguridad, la sobrecarga operativa, el impacto en el rendimiento y la complejidad de implementación.

| Control / Framework | Enfoque Principal y Objetivo | Mecanismo Arquitectónico | Sobrecarga Operativa | Fricción para Desarrolladores | Trade-Off Principal en Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Pod Security Admission (PSA)** | Aplicación integrada de seguridad para workloads del cluster (Privileged, Baseline, Restricted). | Admission Controller integrado en el `kube-apiserver`. Evalúa las plantillas de Pods frente a las etiquetas de PSS. | Baja (Característica nativa, cero dependencias externas). | Media (Los perfiles estrictos rompen imágenes heredadas que ejecutan como root). | Rápido y ligero, pero carece de lógica de reglas personalizadas de grano fino (todo o nada por etiqueta de namespace). |
| **OPA Gatekeeper** | Aplicación declarativa de políticas mediante lógica Rego personalizada. | Webhook Controller de Validación/Mutación que utiliza el motor de Open Policy Agent. | Alta (Requiere gestionar CRDs de OPA, pods de Gatekeeper, experiencia en la DSL de Rego). | Media a Alta (Curva de aprendizaje compleja para la sintaxis de Rego). | Validación personalizada extremadamente expresiva, pero con mayor sobrecarga de latencia y huella de memoria en el control plane. |
| **Kyverno** | Gestión de políticas nativa de Kubernetes utilizando CRDs de YAML. | Webhook Controller de Validación/Mutación/Generación que opera de forma nativa en los recursos de K8s. | Media (Requiere gestionar el estado del controlador y los CRDs de Kyverno). | Baja (Utiliza la estructura declarativa YAML familiar de K8s). | Alta ergonomía para desarrolladores en YAML nativo, pero menos expresivo que Rego (Turing-completo) para coincidencias de contexto multirrecurso. |
| **CIS Kubernetes Benchmark** | Recomendaciones base de hardening para nodos y Control Plane. | Scripts de auditoría que verifican permisos de archivos, flags en el API server, etcd, kubelet (`kube-bench`). | Baja (Se ejecuta como un CronJob estándar o utilidad del host). | Ninguna (Herramienta de evaluación operativa no bloqueante). | Evaluación de configuración exhaustiva, pero solo de auditoría (requiere herramientas secundarias para aplicar remediaciones). |
| **NIST SP 800-190** | Estándares de arquitectura de seguridad para contenedores de aplicaciones. | Framework de gobernanza que categoriza riesgos a lo largo de Imagen, Registry, Orquestador, Contenedor y Host. | Alta (Alineación estratégica de cumplimiento entre equipos organizacionales). | Baja (Nivel de framework, no genera fricción directa en CLI). | Cubre la seguridad del ciclo de vida de extremo a extremo, pero es abstracto: requiere traducción a manifiestos de K8s concretos y gates de CI/CD. |

---

## 3. Manifiestos de Producción y Configuraciones de Infraestructura

### 3.1. PodSecurityConfiguration a Nivel de Cluster (configuración del `kube-apiserver`)

El siguiente manifiesto define un archivo `PodSecurityConfiguration` completo y sintácticamente válido que se pasa al `kube-apiserver` a través de `--admission-control-config-file`. Aplica el perfil `restricted` por defecto en todos los namespaces mientras establece los modos de advertencia (warn) y auditoría (audit).

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "restricted"
  enforce-version: "latest"
  warn: "restricted"
  warn-version: "latest"
  audit: "restricted"
  audit-version: "latest"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces:
    - kube-system
    - cert-manager
    - ingress-nginx
```

### 3.2. Namespace de Producción con Pod Security Standards Aplicados mediante Etiquetas

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-service-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
```

### 3.3. Manifiesto de Workload Totalmente Conforme con el Perfil Restricted

Este Deployment se adhiere estrictamente al **Perfil Restricted de PSS**, las **recomendaciones de CIS Benchmark** y los **Estándares de Hardening de NSA/CISA**.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: payment-service-prod
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: payment-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: processor
          image: internal-registry.enterprise.io/finance/payment-processor:v2.4.1
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          volumeMounts:
            - mountPath: /tmp
              name: tmp-volume
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

### 3.4. Política de Kyverno: Aplicar la Prohibición de Escalada de Privilegios y Requerir Sistema de Archivos Root de Solo Lectura

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-hardened-container-security
  annotations:
    policies.kyverno.io/title: Enforce Hardened Container Security Context
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Enforces that allowPrivilegeEscalation is set to false and readOnlyRootFilesystem
      is set to true for all container instances in user workload namespaces.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-privilege-escalation-and-readonly-root
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - "payment-service-prod"
                - "order-service-prod"
      validate:
        message: "Containers must disable privilege escalation and mandate a read-only root filesystem."
        pattern:
          spec:
            containers:
              - securityContext:
                  allowPrivilegeEscalation: false
                  readOnlyRootFilesystem: true
```

---

## 4. Comandos CLI Reales y Verificación de Salidas de Terminal

### 4.1. Auditoría de Hardening del Cluster mediante `kube-bench` (CIS Kubernetes Benchmark)

Ejecute `kube-bench` apuntando a un Nodo Master/Control Plane para verificar el cumplimiento del framework CIS Kubernetes Benchmark.

```bash
$ kube-bench run --targets master --check 1.2.1,1.2.2,1.2.5
```

**Salida de Terminal Esperada:**

```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server Configuration
[FAIL] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set (Automated)
[PASS] 1.2.5 Ensure that the --kubelet-client-certificate and --kubelet-client-key arguments are set (Automated)

== Summary master ==
2 checks PASS
1 checks FAIL
0 checks WARN
0 checks INFO

== Remediations master ==
1.2.1 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the below parameter.
--anonymous-auth=false
```

### 4.2. Prueba de Rechazo de Pod Security Admission (PSA) en un Pod No Conforme

Intente aplicar un pod no conforme (ejecutándose como root y sin `seccompProfile`) en el namespace etiquetado `payment-service-prod`.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-pod
  namespace: payment-service-prod
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Salida de Terminal Esperada:**

```text
Error from server (Forbidden): error when creating "STDIN": pods "non-compliant-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 4.3. Verificación de la Ejecución de Políticas de Kyverno y Violaciones

Verifique el estado de aplicación de la política del cluster directamente usando `kubectl`.

```bash
$ kubectl get clusterpolicy enforce-hardened-container-security -o wide
```

**Salida de Terminal Esperada:**

```text
NAME                                     ADMISSION   BACKGROUND   READY   AGE   MESSAGE
enforce-hardened-container-security      true        true         True    18h   Ready
```

Inspeccione los reportes de políticas de Kyverno en todo el cluster:

```bash
$ kubectl get policyreports -n payment-service-prod
```

**Salida de Terminal Esperada:**

```text
NAME                                PASS   FAIL   WARN   ERROR   AGE
cpol-enforce-hardened-container-security   3      0      0      0       4h22m
```

---

## 5. Guía de Verificación, Solución de Problemas y Diagnóstico

### 5.1. Diagrama de Flujo de Diagnóstico: Rechazo de Seguridad de Workload

```
               [ Workload Deployment Submitted ]
                                |
                                v
               +---------------------------------+
               |  Is Namespace Exempt in PSA?   |
               +----------------+----------------+
                                |
                      +---------+---------+
                      |                   |
                     YES                  NO
                      |                   |
                      v                   v
            [ Bypass PSA Checks ]   [ Evaluate PSS Profile ]
                                          |
                                 +--------+--------+
                                 |                 |
                               PASS              FAIL
                                 |                 |
                                 v                 v
                    [ Kyverno/OPA Webhook ]  [ Blocked by kube-apiserver ]
                                 |            (403 Forbidden Error)
                       +---------+---------+
                       |                   |
                     PASS              VIOLATION
                       |                   |
                       v                   v
              [ Pod Scheduled ]     [ Rejected by Policy Engine ]
```

### 5.2. Problemas Comunes en Producción y Análisis de Causa Raíz

#### Problema 1: `CrashLoopBackOff` después de configurar `readOnlyRootFilesystem: true`
* **Causa Raíz**: El framework de la aplicación intenta escribir el estado de ejecución, logs o archivos temporales (p. ej., `/tmp`, `/var/cache`, `/var/log`) directamente en el sistema de archivos root del contenedor.
* **Comando de Diagnóstico**:
  ```bash
  $ kubectl logs -n payment-service-prod deployment/payment-processor --previous
  ```
  *Salida*: `Error: open /tmp/app.lock: read-only file system`
* **Resolución**: Montar un volumen efímero (`emptyDir`) específicamente en los directorios que requieren escritura (p. ej., `/tmp`).

#### Problema 2: Timeout del Admission Webhook (`500 Internal Server Error` en la Creación del Pod)
* **Causa Raíz**: Los webhooks de los Policy Engines personalizados (OPA Gatekeeper o Kyverno) están mal configurados con `failurePolicy: Fail` mientras que los pods del controlador de políticas están fallando, inalcanzables o desprovistos de recursos.
* **Comandos de Diagnóstico**:
  ```bash
  $ kubectl get validatingservicepolicies,validatingwebhookconfigurations -A
  $ kubectl get pods -n kyverno
  $ kubectl top pod -n kyverno
  ```
* **Resolución**: Verificar la comunicación de red entre el control plane y los admission controllers. Asegurar que los deployments de los controladores de políticas tengan réplicas redundantes y reservas adecuadas de recursos de CPU/memoria.

---

## 6. Referencias

* **CNCF TAG Security Whitepaper**: [https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper-v2.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper-v2.md)
* **Documentación de Pod Security Standards de Kubernetes**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Documentación de Pod Security Admission de Kubernetes**: [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **NIST SP 800-190 (Guía de Seguridad de Contenedores de Aplicación)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **CIS Kubernetes Benchmarks**: [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)
* **Guía de Hardening de Kubernetes de NSA/CISA**: [https://www.nsa.gov/Cybersecurity/Cybersecurity-Technical-Reports/](https://www.nsa.gov/Cybersecurity/Cybersecurity-Technical-Reports/)
* **MITRE ATT&CK para Kubernetes**: [https://attack.mitre.org/matrices/enterprise/kubernetes/](https://attack.mitre.org/matrices/enterprise/kubernetes/)