# Guía de Estudio KCSA — Dominio 6.1: Frameworks de Cumplimiento

## 1. Motivación Arquitectónica y Problemática en Producción

En entornos empresariales de producción —especialmente dentro de infraestructuras de FinTech, Salud (Healthcare), Comercio Electrónico (E-Commerce) y Sector Público— los clusters de Kubernetes representan un límite de seguridad crítico. Las arquitecturas nativas de la nube introducen paradigmas operativos clave que rompen los flujos de trabajo de cumplimiento tradicionales y estáticos:
* **Dinámica de Cargas de Trabajo Efímeras (Ephemeral Workload Dynamics):** Los Pods se crean, mutan y terminan en cuestión de segundos o minutos. Las auditorías manuales puntuales (por ejemplo, pruebas de penetración anuales o revisiones estáticas en hojas de cálculo) no logran capturar la desviación de la postura (posture drift) en tiempo de ejecución (runtime).
* **Plano de Control Compartido y Riesgo de Multitenencia (Multi-Tenancy Risk):** Los microservicios propiedad de diferentes equipos de ingeniería comparten las API del plano de control (`kube-apiserver`), nodos de cómputo, runtimes de contenedores e interfaces de red superpuesta (network overlay). Una sola mala configuración en un namespace puede comprometer el host subyacente o los inquilinos (tenants) adyacentes.
* **Complejidad de la API Declarativa:** Kubernetes expone más de 50 recursos de API. Garantizar que cada carga de trabajo cumpla con los frameworks regulatorios requiere mapear políticas abstractas legibles por humanos a restricciones deterministas a nivel de API.

### El Problema Arquitectónico: Traducir Frameworks a Primitivas de Kubernetes
Los frameworks de cumplimiento como **PCI-DSS 4.0**, **NIST SP 800-53 / 800-190**, **SOC 2 Type II** y **CIS Kubernetes Benchmarks** exigen controles a lo largo de múltiples capas operativas:

```
+-----------------------------------------------------------------------+
|                         COMPLIANCE FRAMEWORKS                         |
|             (PCI-DSS 4.0, NIST SP 800-53, SOC 2, CIS Benchmarks)      |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 KUBERNETES CONTROL PLANE ARCHITECTURE                 |
+-----------------------------------------------------------------------+
|  [ API Server ] ----> [ Admission Controllers ] ----> [ Audit Log ]   |
|         |                      |                                      |
|         v                      v                                      |
|   (RBAC & OIDC)    (ValidatingAdmissionPolicy)                        |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 WORKLOAD & INFRASTRUCTURE ENFORCEMENT                 |
+-----------------------------------------------------------------------+
|  [ NetworkPolicies ]       [ Pod Security Standards ]   [ Node Security ]  |
|  (Microsegmentation)       (Non-root, ReadOnly FS)      (etcd, Kubelet)    |
+-----------------------------------------------------------------------+
```

Sin una aplicación automatizada y continua (continuous automated enforcement), los sistemas experimentan **Compliance Drift** (desviación de cumplimiento): los desarrolladores envían manifiestos no conformes (por ejemplo, contenedores privilegiados, permisos RBAC con comodines, rutas de Ingress no cifradas) que aprueban la revisión por pares inicial, pero violan los estándares de seguridad base una vez desplegados en producción.

---

## 2. Comparaciones Técnicas y Tablas de Compromisos (Trade-offs)

La siguiente matriz compara los cuatro estándares principales de cumplimiento que se encuentran en entornos de Kubernetes nativos de la nube:

| Característica / Métrica | CIS Kubernetes Benchmark | NIST SP 800-190 / SP 800-53 | PCI-DSS v4.0 (Req 1, 2, 7, 10) | SOC 2 Type II |
| :--- | :--- | :--- | :--- | :--- |
| **Alcance Principal** | Componentes del plano de control, Kubelet, configuración del host, etcd, RBAC. | Ciclo de vida de seguridad de contenedores de aplicaciones, gestión de riesgos, control de acceso. | Microsegmentación del Entorno de Datos de Tarjetahabientes (CDE), pista de auditoría (audit trail), criptografía. | Eficacia de controles operativos durante un período de observación (Trust Services). |
| **Primitivas de Kubernetes Utilizadas** | Permisos de archivos del host (`/etc/kubernetes`), flags de Kubelet, flags del API Server. | `PodSecurityAdmission`, `securityContext`, `seccompProfile`, `capabilities`. | `NetworkPolicy`, cifrado de `Secret` en reposo, API Audit Logs, RBAC `RoleBinding`. | API Audit Logging, inmutabilidad de estado en GitOps, aplicación automatizada de políticas. |
| **Capa de Aplicación (Enforcement Layer)** | Escaneo estático del host (`kube-bench`), gestión de configuración de nodos. | Control de admisión (`ValidatingAdmissionPolicy`, OPA/Kyverno), Container Runtime. | Filtro de red CNI (eBPF / iptables), control de admisión de API, Service Mesh. | Pipelines de logs (Fluentbit/Loki/Splunk), pipelines de CI/CD, integraciones SIEM. |
| **Frecuencia de Auditoría** | Continua / Escaneos cron diarios programados. | En línea por solicitud de API (bloqueo de admisión en tiempo real). | Monitoreo continuo en runtime y pruebas trimestrales de penetración / postura. | Recolección continua de evidencia histórica (típicamente una ventana de 3 a 12 meses). |
| **Compromisos e Impacto Operativo** | Bajo costo de runtime; requiere acceso al host para ejecutar scripts de verificación de configuración. | Evita que se generen cargas de trabajo no conformes; puede bloquear despliegues si está mal configurado. | Alta complejidad de red; las reglas estructuradas incorrectamente causan interrupciones del servicio. | Requiere un gran volumen de almacenamiento de logs; sobrecosto (overhead) de mantenimiento en el pipeline de datos de logs. |

---

## 3. Manifiestos e Infraestructura Sintácticamente Válidos y Completos

### Manifiesto 1: NetworkPolicy de Nivel de Producción para PCI-DSS v4.0 (Requisitos 1.2 y 1.3 Microsegmentación)
Este manifiesto aplica un aislamiento estricto por defecto (default-deny) para un servicio de Procesamiento de Pagos en un Entorno de Datos de Tarjetahabientes (CDE). Permite explícitamente el Ingress únicamente desde un API Gateway autorizado en el puerto HTTPS `8443` y limita el Egress exclusivamente a la base de datos de transacciones en el puerto TCP `5432` más el DNS interno del cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pci-dss-cde-microsegmentation
  namespace: payment-cde
  labels:
    app.kubernetes.io/name: payment-processor
    compliance.framework/pci-dss: "v4.0"
    compliance.requirement: "1.2-1.3"
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      tier: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              environment: production
              zone: dmz
          podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - protocol: TCP
          port: 8443
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              environment: production
              zone: secure-data
          podSelector:
            matchLabels:
              app: transaction-db
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

---

### Manifiesto 2: ValidatingAdmissionPolicy Nativa de Kubernetes para NIST SP 800-190 y CIS 5.2.6
Aplica reglas de endurecimiento (hardening) en el runtime de contenedores de forma dinámica en la capa del API server sin webhooks externos. Bloquea la creación de Pods si los contenedores se ejecutan como root, tienen un sistema de archivos raíz escribible o habilitan la escalación de privilegios.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: nist-sp800-190-container-hardening
  labels:
    compliance.framework/nist-sp800-190: "4.1"
    compliance.framework/cis-benchmark: "5.2.6"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"
      message: "NIST SP 800-190 Violation: All containers must explicitly set securityContext.runAsNonRoot to true."
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem == true)"
      message: "NIST SP 800-190 Violation: All containers must set securityContext.readOnlyRootFilesystem to true."
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)"
      message: "CIS Benchmark 5.2.6 Violation: Container privilege escalation must be explicitly disabled (allowPrivilegeEscalation: false)."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: nist-sp800-190-container-hardening-binding
spec:
  policyName: nist-sp800-190-container-hardening
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: compliance-enforcement
          operator: In
          values: ["strict", "enabled"]
```

---

### Manifiesto 3: CronJob Automatizado de CIS Kubernetes Benchmark con Kube-Bench
Despliega un trabajo programado (CronJob) ejecutando `kube-bench` para realizar auditorías automatizadas de cumplimiento del plano de control y de los nodos, reportando los hallazgos en formato JSON.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-cis-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    compliance.framework/cis-k8s: "v1.8"
spec:
  schedule: "0 2 * * *"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: kube-bench
        spec:
          hostPID: true
          restartPolicy: OnFailure
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node-role.kubernetes.io/master
              operator: Exists
              effect: NoSchedule
          containers:
            - name: kube-bench
              image: docker.io/aquasec/kube-bench:v0.7.3
              command: ["kube-bench", "run", "--targets", "master,node", "--json"]
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
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal ($)

### Comando 1: Validación de la Aplicación de Pod Security Admission (PSA)
Consulta la configuración operativa de los namespaces para verificar el etiquetado de cumplimiento bajo los estándares de Kubernetes Pod Security Admission.

```bash
$ kubectl get namespaces --show-labels -l pod-security.kubernetes.io/enforce
```
```text
NAME           STATUS   AGE   LABELS
payment-cde    Active   12d   app.kubernetes.io/part-of=core-banking,compliance-enforcement=strict,environment=production,pod-security.kubernetes.io/enforce-version=latest,pod-security.kubernetes.io/enforce=restricted,zone=secure-data
secure-system  Active   45d   compliance-enforcement=enabled,pod-security.kubernetes.io/enforce-version=v1.30,pod-security.kubernetes.io/enforce=restricted
```

---

### Comando 2: Pruebas de Aplicación de ValidatingAdmissionPolicy contra Pods No Conformes
Intenta aplicar un manifiesto de Pod no conforme para verificar el rechazo de la política de admisión en tiempo real.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: payment-cde
spec:
  containers:
  - name: nginx
    image: nginx:1.25.3
EOF
```
```text
Error from server (Forbidden): error when creating "STDIN": pods "non-compliant-workload" is forbidden: validating admission policy "nist-sp800-190-container-hardening" with binding "nist-sp800-190-container-hardening-binding" denied the request:
- NIST SP 800-190 Violation: All containers must explicitly set securityContext.runAsNonRoot to true.
- NIST SP 800-190 Violation: All containers must set securityContext.readOnlyRootFilesystem to true.
- CIS Benchmark 5.2.6 Violation: Container privilege escalation must be explicitly disabled (allowPrivilegeEscalation: false).
```

---

### Comando 3: Ejecución de `kube-bench` Directamente en un Nodo Master/Control Plane
Ejecuta auditorías de CIS Benchmark a nivel de host para evaluar los permisos de archivos y los flags de los componentes.

```bash
$ kube-bench run --targets master --check 1.1.1,1.1.2,1.2.1
```
```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root (Automated)
[INFO] 1.2 API Server
[FAIL] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)

== Summary master ==
2 checks PASS
1 checks FAIL
0 checks WARN
0 checks INFO

== Remediations master ==
1.2.1 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --anonymous-auth parameter to false.
```

---

### Comando 4: Inspección de Logs de Auditoría del API Server para Verificación de Pista de Auditoría (Audit Trail) SOC 2 / PCI-DSS
Extrae registros de auditoría de acceso filtrados para operaciones en recursos sensibles (accesos a Secrets y modificaciones de RBAC).

```bash
$ tail -n 100 /var/log/kubernetes/audit/audit.log | jq 'select(.objectRef.resource=="secrets" and .verb=="get") | {time: .stageTimestamp, user: .user.username, namespace: .objectRef.namespace, secret: .objectRef.name, decision: .annotations["authorization.k8s.io/decision"]}'
```
```json
{
  "time": "2026-08-07T20:15:32.410912Z",
  "user": "system:serviceaccount:payment-cde:payment-processor-sa",
  "namespace": "payment-cde",
  "secret": "db-credentials",
  "decision": "allow"
}
{
  "time": "2026-08-07T20:18:04.891001Z",
  "user": "developer-user@company.internal",
  "namespace": "payment-cde",
  "secret": "stripe-api-key",
  "decision": "deny"
}
```

---

## 5. Guía de Verificación y Diagnóstico / Solución de Problemas (Troubleshooting)

```
                      WORKLOAD DEPLOYMENT FAILURE
                                   |
                                   v
             +-------------------------------------------+
             |   Check `kubectl describe pod` Output     |
             +-------------------------------------------+
                                   |
        +--------------------------+--------------------------+
        |                                                     |
        v                                                     v
[ Admission Policy Blocked ]                      [ Network Policy Drop ]
        |                                                     |
        v                                                     v
Check Policy Specs & Labels                       Check CNI Flow Logs / Traces
  - `kubectl get policybindings`                    - `cilium monitor --type drop`
  - Inspect `validations[].expression`             - Inspect ingress/egress labels
  - Validate Namespace matchLabels                  - Verify DNS resolution egress (53)
```

### Problema 1: La Política de Admisión Bloquea Cargas de Trabajo Legítimas (Fallo de `ValidatingAdmissionPolicy`)
* **Síntoma:** Los despliegues de cargas de trabajo fallan con `Error from server (Forbidden)` haciendo referencia a una regla de política de cumplimiento.
* **Análisis de Causa Raíz:**
  1. Inspecciona las políticas activas que coinciden con el namespace:
     ```bash
     $ kubectl get validatingadmissionpolicybindings -o wide
     ```
  2. Verifica las etiquetas (labels) del namespace para asegurarte de que la carga de trabajo no haya coincidido accidentalmente con un selector demasiado amplio:
     ```bash
     $ kubectl get ns <namespace-name> --show-labels
     ```
  3. Valida la expresión de la política contra el manifiesto del Pod objetivo:
     Asegúrate de que campos como `securityContext` estén declarados a nivel de contenedor si así lo requiere la expresión CEL:
     ```yaml
     securityContext:
       runAsNonRoot: true
       readOnlyRootFilesystem: true
       allowPrivilegeEscalation: false
       capabilities:
         drop: ["ALL"]
     ```

### Problema 2: NetworkPolicy Bloquea la Comunicación Interna entre Servicios
* **Síntoma:** Pods atascados en `CrashLoopBackOff` o devolviendo errores HTTP 504 Gateway Timeout al conectarse a servicios internos.
* **Análisis de Causa Raíz:**
  1. Verifica las políticas de red activas aplicadas al Pod:
     ```bash
     $ kubectl get networkpolicies -n <namespace> -o wide
     ```
  2. Confirma la alineación de etiquetas (labels) entre el `spec.template.metadata.labels` del Pod objetivo y el `podSelector` / `ingress.from.podSelector` de la NetworkPolicy.
  3. Verifica el Egress de DNS: Un error común al implementar el aislamiento por defecto (default-deny) en `policyTypes: [Egress]` es omitir una regla de salida explícita para CoreDNS en el puerto UDP 53. Si el DNS falla, las conexiones a los endpoints del servicio fallan antes del enrutamiento.

### Problema 3: Los Escaneos de Host de `kube-bench` Fallan en las Reglas de Permisos (CIS 1.1.1 - 1.1.12)
* **Síntoma:** Los escaneos reportan `FAIL` para `/etc/kubernetes/manifests` o los directorios de datos de `etcd`.
* **Pasos de Remediación:**
  1. Conéctate por SSH al nodo afectado y verifica los permisos exactos:
     ```bash
     $ stat -c "%a %U %G %n" /etc/kubernetes/manifests/kube-apiserver.yaml
     ```
  2. Corrige los bits de modo y el propietario (ownership) para cumplir con los estándares base de CIS:
     ```bash
     $ sudo chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
     $ sudo chown root:root /etc/kubernetes/manifests/kube-apiserver.yaml
     ```

---

## 6. Referencias

* **Repositorio Oficial de GitHub del Currículo KCSA de la CNCF:**
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **CIS Kubernetes Benchmark:**
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)
* **Guía de Seguridad para Contenedores de Aplicaciones NIST SP 800-190:**
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **PCI Security Standards Council (PCI-DSS v4.0):**
  [https://www.pcisecuritystandards.org/document_library/](https://www.pcisecuritystandards.org/document_library/)
* **Documentación Oficial de Kubernetes - Network Policies:**
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* **Documentación Oficial de Kubernetes - Validating Admission Policy:**
  [https://kubernetes.io/docs/concepts/security/validating-admission-policy/](https://kubernetes.io/docs/concepts/security/validating-admission-policy/)
* **Documentación de kube-bench de Aqua Security:**
  [https://github.com/aquasecurity/kube-bench](https://github.com/aquasecurity/kube-bench)