# Módulo 6.1: Compliance Frameworks en Kubernetes

## 1. Deep Dive Técnico & Arquitectura de Producción

### 1.1 Mecánica de los Compliance Frameworks Cloud-Native
El compliance en la infraestructura cloud-native es el proceso verificable de alinear las cargas de trabajo (workloads) contenedorizadas, las configuraciones del control plane, los entornos de ejecución (runtime) y los flujos de trabajo operacionales con marcos de seguridad estandarizados. A diferencia de los entornos monolíticos tradicionales, el compliance en Kubernetes no puede depender de auditorías estáticas en un punto puntual en el tiempo. Requiere automatización de compliance continuo a través de tres capas distintas:

1. **Static Control Plane & Node Configuration Compliance**: Verificación de flags y permisos de archivos del API server, etcd, controller manager, scheduler y kubelet contra benchmarks de hardening (por ejemplo, CIS Kubernetes Benchmark).
2. **Declarative Workload Admission Compliance**: Aplicación de guardrails operacionales en las cargas de trabajo antes de su persistencia en etcd utilizando motores de Policy-as-Code (por ejemplo, Kyverno, OPA Gatekeeper) alineados con guías como NSA/CISA Hardening Guidelines y NIST SP 800-190.
3. **Forensic Audit & Event Streaming Compliance**: Captura, retención y análisis de registros (logs) de peticiones del API server para establecer registros de auditoría (audit trails) no repudiables requeridos por estándares regulatorios (por ejemplo, PCI-DSS v4.0 Requirement 10, SOC 2 Type II Trust Services Criteria).

---

### 1.2 Mapeo de Controles de Compliance Frameworks a Primitivas de Kubernetes

| Regulatory / Industry Framework | Control ID & Description | Kubernetes Technical Primitive | Enforcement / Audit Engine |
| :--- | :--- | :--- | :--- |
| **CIS Kubernetes Benchmark** | **Control 1.2.19**: Ensure `--anonymous-auth=false` | Flag de CLI de `kube-apiserver` | Auditoría estática de manifiestos (`kube-bench`) |
| **CIS Kubernetes Benchmark** | **Control 4.2.1**: Ensure `--anonymous-auth=false` on Kubelet | `kubelet-config.yaml` / Kubelet Service | Auditoría estática de configuración de nodos (`kube-bench`) |
| **NSA/CISA Guidance** | **Section 1**: Pod Security (Non-root, read-only root filesystem, drop caps) | Security Context (`securityContext`) | Admission Control (`Kyverno` / `OPA Gatekeeper` / `Pod Security Admission`) |
| **NIST SP 800-190** | **Section 3.1**: Container Image Flaws & Unapproved Registries | Image Pull Secrets & Image Pattern Match | Admission Control (`Kyverno` Image Verification / ImagePolicyWebhook) |
| **PCI-DSS v4.0** | **Requirement 10.2.1**: Audit all user access to cardholder data / API objects | API Server Audit Policy (`AuditPolicy`) | Motor de Audit Logging de `kube-apiserver` a SIEM |
| **SOC 2 Type II** | **CC6.1**: Prevent unauthorized execution & access | RBAC (`ClusterRole`, `RoleBinding`), Pod Security | Motor RBAC de Kubernetes & Admission Controllers |

---

### 1.3 Arquitectura de Compliance Continuo

```
  +---------------------------------------------------------------------------------------------------+
  |                                   Continuous Compliance Architecture                              |
  +---------------------------------------------------------------------------------------------------+
  
   [ Developer / CI/CD ]
            |
            v  (kubectl apply / GitOps Push)
   +-----------------------+
   |   kube-apiserver      |
   +-----------+-----------+
               |
               +---> [ 1. Audit Policy Engine ] ---------> Write JSON Logs ---> [ SIEM / Log Collector ]
               |                                                                (PCI-DSS 10.2 / SOC 2)
               |
               +---> [ 2. Admission Controllers ]
                           |
                           +---> [ Kyverno / OPA Gatekeeper ] ---> Validate Security Context
                                                                    (NSA/CISA & NIST SP 800-190)
                                                                    Reject Non-Compliant Pods
  [ Node Infrastructure ]
               |
   +-----------+-----------+
   |  kube-bench CronJob   | ---> Audit API / Kubelet / etcd Flags against CIS Benchmarks
   +-----------------------+
```

---

## 2. Ejercicios Guiados de Producción

### Ejercicio 1: Escaneo Automatizado de Compliance de CIS Benchmark y Hardening de Nodos

En este ejercicio, desplegarás un `CronJob` de `kube-bench` automatizado para escanear continuamente las configuraciones de tus nodos de Kubernetes contra el CIS Kubernetes Benchmark, analizar los hallazgos no conformes y remediar las violaciones de flags del control plane y del kubelet.

#### Paso 1.1: Desplegar el CronJob de Escaneo de CIS Benchmark
Crea un manifiesto de `CronJob` sintácticamente válido para ejecutar `kube-bench` en el nodo máster del control plane utilizando montajes de host path para la inspección de configuración.

Ejecutá el siguiente comando para desplegar el escáner:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-control-plane
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/part-of: compliance-suite
spec:
  schedule: "0 0 * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: kube-bench
        spec:
          hostPID: true
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node-role.kubernetes.io/master
              operator: Exists
              effect: NoSchedule
          restartPolicy: OnFailure
          containers:
            - name: kube-bench
              image: aquasec/kube-bench:v0.7.3
              command: ["kube-bench", "run", "--targets", "master"]
              volumeMounts:
                - name: var-lib-etcd
                  mountPath: /var/lib/etcd
                  readOnly: true
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
                  mountPath: /usr/local/mount-from-host/bin
                  readOnly: true
          volumes:
            - name: var-lib-etcd
              hostPath:
                path: /var/lib/etcd
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
EOF
```

Salida Esperada:
```text
cronjob.batch/kube-bench-control-plane created
```

---

#### Paso 1.2: Activar el Job Manualmente y Analizar la Salida del CIS Benchmark
Activá una ejecución manual del job e inspeccioná los logs del Pod generados en busca de fallos de CIS.

```bash
kubectl create job --from=cronjob/kube-bench-control-plane kube-bench-manual-01 -n kube-system
kubectl wait --for=condition=complete job/kube-bench-manual-01 -n kube-system --timeout=60s
POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-bench --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs $POD_NAME -n kube-system | grep -E "\[FAIL\]|\[WARN\]"
```

Salida Esperada:
```text
[FAIL] 1.2.19 Ensure that the --anonymous-auth argument is set to false (FAIL)
[FAIL] 1.2.22 Ensure that the --mode argument is set to Node,RBAC (FAIL)
[WARN] 1.1.12 Ensure that the etcd data directory permissions are set to 700 or more restrictive (WARNING)
```

---

#### Paso 1.3: Remediar la Flag de Autenticación Anónima de `kube-apiserver`
Remediá el Control CIS 1.2.19 modificando el manifiesto de Pod estático para `kube-apiserver` en el nodo del control plane para deshabilitar la autenticación anónima.

Inspeccioná `/etc/kubernetes/manifests/kube-apiserver.yaml` y asegurate de que `--anonymous-auth=false` esté configurado explícitamente debajo de `.spec.containers[0].command`.

```bash
# Execute on the control-plane host:
sudo sed -i '/--anonymous-auth/d' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a \    - --anonymous-auth=false' /etc/kubernetes/manifests/kube-apiserver.yaml
```

Verificá que el Pod de `kube-apiserver` se reinicie automáticamente:

```bash
kubectl get pods -n kube-system -l component=kube-apiserver -w
```

Salida Esperada:
```text
NAME                                           READY   STATUS    RESTARTS   AGE
kube-apiserver-control-plane                   1/1     Running   0          12s
```

---

#### Paso 1.4: Reevaluar el Benchmark Post-Remediación
Volvé a ejecutar el job manual de `kube-bench` para confirmar la remediación del Control CIS 1.2.19.

```bash
kubectl create job --from=cronjob/kube-bench-control-plane kube-bench-manual-02 -n kube-system
kubectl wait --for=condition=complete job/kube-bench-manual-02 -n kube-system --timeout=60s
POD_NAME_02=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-bench --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs $POD_NAME_02 -n kube-system | grep "1.2.19"
```

Salida Esperada:
```text
[PASS] 1.2.19 Ensure that the --anonymous-auth argument is set to false
```

---

#### Preguntas de Verificación — Ejercicio 1
1. **Pregunta 1.1**: ¿Por qué configurar `--anonymous-auth=false` en `kube-apiserver` satisface el Control CIS 1.2.19 y qué potencial breaking change introduce para los probes de readiness o endpoints de métricas no autenticados?
2. **Pregunta 1.2**: En un entorno de Kubernetes administrado (por ejemplo, EKS, GKE, AKS), ¿por qué ejecutar `kube-bench` contra componentes del control plane falla o reporta archivos faltantes, y dónde se debería enfocar el escaneo de compliance en su lugar?

---

### Ejercicio 2: Aplicación Declarativa de Políticas de Compliance mediante Policy-as-Code (Mapeo de NSA/CISA & NIST SP 800-190)

En este ejercicio, desplegarás una `ClusterPolicy` de Kyverno para aplicar de manera declarativa las directrices de Pod Security Hardening de NSA/CISA y los controles de seguridad de container runtime de NIST SP 800-190 en todo tu cluster.

#### Paso 2.1: Desplegar el Motor de Políticas Kyverno (si no está presente) y Aplicar la Política de Compliance
Desplegá una `ClusterPolicy` de nivel de producción que bloquee las cargas de trabajo que no cumplan con los requisitos de NSA/CISA:
- Deshabilitar la ejecución del usuario root (`runAsNonRoot: true`).
- Exigir sistemas de archivos root de solo lectura (`readOnlyRootFilesystem: true`).
- Eliminar todas las capacidades (`drop: ["ALL"]`).
- Deshabilitar la escalada de privilegios (`allowPrivilegeEscalation: false`).
- Exigir la coincidencia de dominio de container registry aprobado por NIST SP 800-190 (`company-registry.io/*`).

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-nsa-cisa-nist-compliance
  annotations:
    policies.kyverno.io/title: NSA-CISA Pod Hardening & NIST SP 800-190 Registry Guard
    policies.kyverno.io/category: Security, Compliance
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Enforces NSA/CISA pod hardening requirements and NIST SP 800-190 unapproved registry protection.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-nsa-cisa-security-context
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "NSA/CISA Compliance Failure: Security Context must enforce runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation=false, and drop ALL capabilities."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
                  readOnlyRootFilesystem: true
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop:
                      - ALL
    - name: validate-nist-approved-registry
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "NIST SP 800-190 Compliance Failure: Image must originate from approved registry 'company-registry.io'."
        pattern:
          spec:
            containers:
              - image: "company-registry.io/*"
EOF
```

Salida Esperada:
```text
clusterpolicy.kyverno.io/enforce-nsa-cisa-nist-compliance created
```

---

#### Paso 2.2: Probar el Rechazo de Admission Control con un Manifiesto No Conforme
Intentá desplegar una carga de trabajo no conforme que viole el security context de NSA/CISA y las políticas de image registry de NIST SP 800-190.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: default
spec:
  containers:
    - name: vulnerable-app
      image: nginx:latest
      securityContext:
        runAsNonRoot: false
        allowPrivilegeEscalation: true
EOF
```

Salida Esperada:
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/non-compliant-workload was blocked due to the following policies:

enforce-nsa-cisa-nist-compliance:
  validate-nsa-cisa-security-context: 'NSA/CISA Compliance Failure: Security Context must enforce runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation=false, and drop ALL capabilities.'
  validate-nist-approved-registry: 'NIST SP 800-190 Compliance Failure: Image must originate from approved registry ''company-registry.io''.'
```

---

#### Paso 2.3: Desplegar una Carga de Trabajo Totalmente Conforme
Desplegá una carga de trabajo que satisfaga completamente los atributos de security context de NSA/CISA y las reglas de container registry de NIST SP 800-190.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fully-compliant-workload
  namespace: default
spec:
  containers:
    - name: hardened-app
      image: company-registry.io/apps/secure-api:v1.0.0
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
  volumes:
    - name: tmp-volume
      emptyDir: {}
EOF
```

Salida Esperada:
```text
pod/fully-compliant-workload created
```

---

#### Paso 2.4: Inspeccionar la Salida de la CLI de Policy Reports de Kyverno
Verificá que Kyverno genere reportes estructurados de auditoría de compliance para los recursos existentes.

```bash
kubectl get policyreport -A
```

Salida Esperada:
```text
NAMESPACE   NAME                   PASS   FAIL   WARN   ERROR   AGE
default     pol-nsa-cisa-report    1      0      0      0       45s
```

---

#### Preguntas de Verificación — Ejercicio 2
1. **Pregunta 2.1**: ¿Qué componente específico de NIST SP 800-190 (Sección 3.1) se aborda directamente al aplicar restricciones de image registry (`company-registry.io/*`), y por qué se prefiere el etiquetado por digest de imagen (`@sha256:...`) en lugar del nombre de etiqueta (`:v1.0.0`) en entornos de alto compliance?
2. **Pregunta 2.2**: Si una aplicación requiere escribir archivos de bloqueo (lock files) temporales en tiempo de ejecución, ¿cómo el montaje de un volumen `emptyDir` en `/tmp` preserva el compliance con el mandato de `readOnlyRootFilesystem: true` de NSA/CISA?

---

### Ejercicio 3: Arquitectura de Audit Logging de Kubernetes API Server para Auditorías de PCI-DSS v4.0 & SOC 2

En este ejercicio, crearás un manifiesto granular de `AuditPolicy` alineado con PCI-DSS v4.0 Requirement 10 (Logging & Auditing), configurarás flags de `kube-apiserver` y analizarás los audit logs del API server para la generación de evidencia forense.

#### Paso 3.1: Construir el Manifiesto de `AuditPolicy` Conforme a PCI-DSS & SOC 2
Crea un `audit-policy.yaml` de producción aplicando reglas estrictas de auditoría de logs:
- **Nivel RequestResponse**: Para modificaciones de RBAC (`ClusterRole`, `RoleBinding`), acceso a Secret y subrecursos de Pod `exec`/`attach`/`port-forward` (PCI-DSS 10.2.2 & 10.2.7).
- **Nivel Metadata**: Para creaciones/eliminaciones de cargas de trabajo en namespaces que no sean de sistema.
- **Nivel None**: Descartar peticiones ruidosas y de alto volumen (por ejemplo, `kube-proxy`, endpoints, leases de componentes).

```bash
cat <<'EOF' | sudo tee /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "ResponseStarted"
rules:
  # 1. Ignore high-volume read-only noise
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "configmaps"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  - level: None
    namespaces: ["kube-system"]
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # 2. Critical PCI-DSS / SOC 2 Compliance Events: RequestResponse Level
  # Audit Secret reads and modifications
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]

  # Audit RBAC permissions changes (PCI-DSS 10.2.2)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Audit Interactive Pod Access (kubectl exec/attach) (PCI-DSS 10.2.7)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Metadata Level for workload operations
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods", "services", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets"]

  # 4. Default catch-all for remaining authenticated requests
  - level: Metadata
    omitStages:
      - "ResponseStarted"
EOF
```

Salida Esperada:
```text
apiVersion: audit.k8s.io/v1
kind: Policy
...
```

---

#### Paso 3.2: Configurar `kube-apiserver` para el Streaming de Logs de Auditoría
Configurá `/etc/kubernetes/manifests/kube-apiserver.yaml` para habilitar el audit logging adjuntando las flags de auditoría y montando el archivo de política y el directorio de logs.

Agregá las siguientes flags a `kube-apiserver`:
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

Y montá los host paths para `/etc/kubernetes/audit-policy.yaml` y `/var/log/kubernetes/audit`.

```bash
# Ensure log directory exists
sudo mkdir -p /var/log/kubernetes/audit
```

Verificá la generación del archivo de audit log:

```bash
sudo tail -n 5 /var/log/kubernetes/audit/audit.log
```

Salida Esperada (JSON Log Crudo):
```json
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"RequestResponse","auditID":"c8b6b2e1-45a8-4e40-9a3d-612b7f8911ab","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/default/secrets","verb":"get","user":{"username":"kubernetes-admin","groups":["system:masters","system:authenticated"]},"sourceIPs":["192.168.1.50"],"responseStatus":{"metadata":{},"code":200},"objectRef":{"resource":"secrets","name":"db-credential","namespace":"default"}}
```

---

#### Paso 3.3: Analizar y Extraer Evidencia Forense de Compliance Usando `jq`
Los eventos de auditoría deben ser analizados para la verificación de compliance. Ejecutá consultas `jq` para extraer evidencia de lecturas de Secret (PCI-DSS 10.2.1) y eventos de acceso interactivo `kubectl exec` (PCI-DSS 10.2.7).

Consulta 1: Extraer todas las operaciones de lectura de Secret (`verb=get` o `list`):

```bash
sudo cat /var/log/kubernetes/audit/audit.log | jq -c 'select(.objectRef.resource=="secrets" and (.verb=="get" or .verb=="list")) | {timestamp: .requestReceivedTimestamp, user: .user.username, verb: .verb, secret: .objectRef.name, namespace: .objectRef.namespace, clientIP: .sourceIPs[0]}'
```

Salida Esperada:
```json
{"timestamp":"2026-08-07T20:45:12Z","user":"kubernetes-admin","verb":"get","secret":"db-credential","namespace":"default","clientIP":"192.168.1.50"}
```

Consulta 2: Detectar acceso interactivo a la shell del contenedor (`pods/exec`):

```bash
sudo cat /var/log/kubernetes/audit/audit.log | jq -c 'select(.objectRef.subresource=="exec") | {timestamp: .requestReceivedTimestamp, user: .user.username, pod: .objectRef.name, namespace: .objectRef.namespace, container: .objectRef.subresource}'
```

Salida Esperada:
```json
{"timestamp":"2026-08-07T20:48:30Z","user":"admin-user@company.com","pod":"fully-compliant-workload","namespace":"default","container":"exec"}
```

---

#### Preguntas de Verificación — Ejercicio 3
1. **Pregunta 3.1**: ¿Por qué el audit logging se configura a nivel `RequestResponse` para recursos `Secret` y subrecursos `pods/exec`, mientras que el nivel `Metadata` es suficiente para `Deployments` bajo PCI-DSS v4.0 Requirement 10?
2. **Pregunta 3.2**: En una arquitectura orientada a eventos (event-driven), ¿qué riesgo se introduce si los audit logs se almacenan localmente en el sistema de archivos del host del control plane (`/var/log/kubernetes/audit/audit.log`), y cómo se mitiga esto para el compliance de SOC 2 Type II?

---

## 3. Referencias Oficiales & Citas

- **CNCF KCSA Curriculum**: [KCSA Exam Curriculum GitHub](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Audit Logging Reference**: [Kubernetes Auditing Tasks](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- **NSA/CISA Kubernetes Hardening Guidance**: [NSA/CISA Kubernetes Hardening Technical Report (PDF)](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2.PDF)
- **NIST SP 800-190 Application Container Security Guide**: [NIST Special Publication 800-190](https://csrc.nist.gov/pubs/sp/800/190/final)
- **CIS Kubernetes Benchmarks**: [Center for Internet Security Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- **Kyverno Policy Library**: [Kyverno Production Policies](https://kyverno.io/policies/)

---

## 4. Respuestas de Verificación & Justificación Técnica

<details>
<summary><strong>Haz clic para ver las Respuestas de Verificación y Justificación Detallada</strong></summary>

### Respuestas para el Ejercicio 1

#### Respuesta 1.1
Configurar `--anonymous-auth=false` instruye al `kube-apiserver` a rechazar las peticiones no autenticadas con un código de estado `HTTP 401 Unauthorized` en lugar de evaluarlas bajo el usuario `system:unauthenticated` y el grupo `system:unauthenticated`.

- **Justificación del Control CIS**: Permitir el acceso anónimo deja cualquier puerto expuesto del API server abierto al descubrimiento no autenticado, reconocimiento y potencial explotación si los permisos de RBAC vinculan accidentalmente roles sensibles a `system:unauthenticated` o `system:authenticated`.
- **Potencial Breaking Change**: Deshabilitar la autenticación anónima rompe los probes `/healthz`, `/livez` y `/readyz` de `kube-apiserver` si los balanceadores de carga externos o agentes de monitoreo consultan estas rutas sin bearer tokens o certificados de cliente TLS. En Kubernetes moderno (v1.20+), los endpoints de health check permanecen accesibles para los clientes no autenticados bajo rutas exentas integradas específicas, pero los probes HTTP personalizados que consultan otros API endpoints sin credenciales fallarán.

#### Respuesta 1.2
En las ofertas de Kubernetes administrado (EKS, GKE, AKS), los proveedores de servicios cloud administran los nodos del control plane (API server, etcd, controller-manager, scheduler) como un servicio de caja negra bajo el Modelo de Responsabilidad Compartida.

- **Por qué fallan los escaneos de Control Plane de `kube-bench`**: `kube-bench` intenta leer archivos de manifiestos estáticos ubicados en rutas del sistema de archivos del host como `/etc/kubernetes/manifests/` o `/var/lib/etcd`. En los nodos del control plane administrado, los nodos worker no tienen acceso por SSH ni al sistema de archivos de la infraestructura subyacente del control plane.
- **Hacia dónde se desplaza el escaneo**: La auditoría de compliance en Kubernetes administrado se desplaza de las verificaciones estáticas de flags del control plane a:
  1. APIs de Configuración de Proveedores Administrados (AWS Security Hub, GCP Security Command Center, Azure Defender).
  2. Escaneos de Configuración de Nodos Worker (ejecutando `kube-bench --targets node`).
  3. Auditoría de Cargas de Trabajo mediante Policy-as-Code (Kyverno/OPA Gatekeeper) y análisis de Audit Logs del API de Kubernetes.

---

### Respuestas para el Ejercicio 2

#### Respuesta 2.1
- **Mapeo de la Sección 3.1 de NIST SP 800-190**: La Sección 3.1 ("Image Flaws") destaca el riesgo de ejecutar imágenes de contenedor no confiables, no examinadas o comprometidas que se originen en registries públicos externos (por ejemplo, repositorios públicos de Docker Hub) que puedan contener malware embebido o CVEs no parcheadas. Restringir los nombres de host de registry mediante políticas aplica la autenticidad de la fuente de la imagen.
- **Digest de Imagen vs. Etiquetas Mutables**: Las etiquetas de imagen como `:v1.0.0` o `:latest` son referencias de puntero mutables. Un actor malicioso con acceso de escritura al registry puede sobrescribir `:v1.0.0` con un binario malicioso sin alterar el manifiesto de deployment. Un digest de imagen (`@sha256:7f83...`) representa un hash criptográfico del manifiesto de imagen y del contenido de la capa. Exigir referencias fijas de digest garantiza la integridad inmutable de la imagen y previene ataques de Mutación/Manipulación de Imágenes (Image Mutation/Tampering).

#### Respuesta 2.2
Cuando `readOnlyRootFilesystem: true` está configurado en el `securityContext` de un contenedor, el container runtime monta el directorio raíz (`/`) como un sistema de archivos de solo lectura a través de overlayfs. Cualquier intento por parte del proceso contenedorizado de escribir archivos (tales como `/tmp/app.lock`, cachés de sesión o archivos pid) resulta en un error `HTTP 500` o a nivel de SO `EROFS (Read-only file system)`.

- **Preservar el Compliance mediante `emptyDir`**: Montar un volumen `emptyDir` específicamente en `/tmp` anula el montaje de solo lectura raíz en esa ruta exacta. El `emptyDir` reside en el almacenamiento temporal del nodo (o memoria RAM si se establece `medium: Memory`). El sistema de archivos raíz permanece estrictamente en solo lectura, lo que impide que los atacantes modifiquen binarios del sistema o inyecten scripts maliciosos en los sistemas de archivos de los contenedores, permitiendo al mismo tiempo el acceso de escritura de la aplicación a directorios temporales volátiles.

---

### Respuestas para el Ejercicio 3

#### Respuesta 3.1
- **`RequestResponse` para Secrets y Exec**: PCI-DSS v4.0 Requirement 10.2.1 y 10.2.7 exigen auditar todo el acceso a datos sensibles y el acceso administrativo interactivo. Configurar `level: RequestResponse` registra:
  1. El contexto completo de la petición (quién solicitó el secret o la sesión de exec, IP del cliente, marca de tiempo).
  2. El estado y el cuerpo devuelto por el API server (lo que permite a los equipos de operaciones de seguridad verificar si una obtención no autorizada de Secret tuvo éxito o falló, y qué parámetros de subrecurso se pasaron).
- **`Metadata` para Deployments**: Los objetos de carga de trabajo (`Deployments`, `StatefulSets`) contienen metadatos de configuración estructural no sensibles. Registrar eventos al nivel `Metadata` captura el usuario iniciador, la marca de tiempo, el recurso de destino y el código de estado HTTP sin generar una amplificación masiva de logs causada por la serialización de especificaciones YAML completas de recursos en los audit logs.

#### Respuesta 3.2
- **Riesgo Arquitectónico**: Almacenar audit logs exclusivamente en los discos locales de los nodos del control plane introduce tres riesgos críticos:
  1. **Manipulación de Logs / Fallo de No Repudio**: Un atacante que comprometa un host del control plane puede modificar o eliminar `/var/log/kubernetes/audit/audit.log`, destruyendo las huellas forenses de acceso no autorizado.
  2. **Agotamiento de Almacenamiento**: Los audit logs consumen alto I/O de disco y almacenamiento. La saturación del disco local causa fallos en `kube-apiserver` o presión en el disco del nodo.
  3. **Incumplimiento de SOC 2 Type II**: SOC 2 CC6.8 requiere recolección inmutable de logs, retención centralizada y monitoreo continuo.
- **Arquitectura de Mitigación**: Configurar `kube-apiserver` con flags de rotación de audit logs (`--audit-log-maxbackup`, `--audit-log-maxage`) combinado con un agente de envío de logs tipo daemon (por ejemplo, Fluentbit, Vector, Logstash) o configurar la flag `--audit-webhook-config-file` del API server para transmitir eventos de auditoría de forma síncrona sobre TLS hacia un SIEM externo conforme con WORM (write-once-read-many) o un objetivo de almacenamiento de objetos (por ejemplo, AWS CloudWatch, Datadog, Elastic, Splunk).

</details>