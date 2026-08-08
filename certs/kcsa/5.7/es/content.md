# Guía de estudio KCSA — Tema 5.7: Admission Control

**Examen de certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Cluster Hardening / Admission Control  
**Peso del tema:** 2.29%  

---

## 1. Problema arquitectónico de producción y motivación

En un cluster de Kubernetes de grado de producción, el Control de Acceso Basado en Roles (RBAC) es necesario pero insuficiente para aplicar la gobernanza de seguridad del cluster. RBAC responde *quién* puede realizar una operación en un recurso (por ejemplo, "¿Puede el usuario `alice` hacer `CREATE` de un `Pod` en el namespace `prod`?"), pero no puede evaluar el **estado semántico o la carga útil de configuración** (payload) de la propia solicitud (por ejemplo, "¿Está `alice` intentando ejecutar un Pod como `root`, montando el directorio `/etc` del host u omitiendo las solicitudes de CPU/memoria?").

Los Admission Controllers actúan como el límite final de defensa en profundidad dentro de `kube-apiserver` antes de que los objetos se validen contra el esquema OpenAPI y se persistan en `etcd`.

```
                    kube-apiserver Request Lifecycle
                    
  +----------------+      +---------------+      +----------------------------+
  |  HTTP Request  | ---> | Authentication| ---> |       Authorization        |
  |  (JSON/YAML)   |      |  (Token/X509) |      | (RBAC / Node / Webhook)    |
  +----------------+      +---------------+      +----------------------------+
                                                                |
                                                                v
  +----------------+      +---------------+      +----------------------------+
  | Schema Check & | <--- |   Mutating    | <--- |   Mutating Webhook Phase   |
  | Serialization  |      | Admission (In)|      | (Dynamic Webhooks)         |
  +----------------+      +---------------+      +----------------------------+
          |
          v
  +----------------+      +---------------+      +----------------------------+
  |  Validating    | ---> |  Validating   | ---> |  ValidatingAdmissionPolicy |
  | Admission (In) |      | Webhook Phase |      |    (In-Tree CEL Engine)    |
  +----------------+      +---------------+      +----------------------------+
                                                                |
                                                                v
                                                 +----------------------------+
                                                 |        etcd Store          |
                                                 |      (Persistence)         |
                                                 +----------------------------+
```

### Peligros arquitectónicos de producción

1. **Bloqueos mutuos (Deadlocks) circulares durante el Bootstrap:** Si un Admission Webhook dinámico depende de componentes del cluster (tales como CoreDNS o plugins de CNI) y su `namespaceSelector` no excluye explícitamente los namespaces del sistema (`kube-system`), reiniciar los nodos del cluster causará que `kube-apiserver` bloquee la creación de pods para CoreDNS/CNI esperando al webhook, mientras que el contenedor del webhook no podrá ejecutarse porque CoreDNS/CNI está caído.
2. **Latencias y fallos en cascada de la API:** Los webhooks operan sobre llamadas de red HTTPS síncronas. Si un admission webhook tarda 10 segundos en responder o agota el tiempo de espera (timeout), cada solicitud de la API coincidente se bloquea. Bajo un alto rendimiento (throughput), las goroutines de trabajo de `kube-apiserver` agotan los límites de max-in-flight, derribando las operaciones de todo el cluster.
3. **Bypass a través de la re-invocación mutante:** Los mutating webhooks pueden modificar campos de objetos. Si el Webhook A muta un objeto, puede eludir las garantías de seguridad esperadas por el Webhook B a menos que `reinvocationPolicy: IF_NEEDED` esté configurado y cuidadosamente auditado.
4. **Admission Webhooks no autenticados / MitM:** Si el API server no valida la autoridad de certificación TLS del webhook (`caBundle`) o si el endpoint del webhook está expuesto a la red de pods sin mTLS/autenticación, un atacante en la red puede secuestrar las llamadas de admisión y aprobar solicitudes maliciosas.

---

## 2. Comparativas arquitectónicas técnicas y compensaciones (Trade-offs)

### Matriz 1: Comparativa arquitectónica de mecanismos de admisión

| Dimensión | PodSecurity integrado (PSA) | Dynamic Admission Webhooks (OPA/Kyverno) | ValidatingAdmissionPolicy (In-Tree CEL) |
| :--- | :--- | :--- | :--- |
| **Contexto de ejecución** | Compilado dentro de `kube-apiserver` | Servicio HTTPS externo (Fuera de proceso) | Intérprete CEL embebido dentro de `kube-apiserver` |
| **Sobrecarga de red (Network Overhead)** | 0 ms | 5 ms – 500+ ms (RTT de red + Handshake TLS) | 0 ms (Ejecución en memoria) |
| **Riesgo de disponibilidad** | Cero (vinculado a la disponibilidad del API Server) | Alto (Particiones de red, caída de pod, fallo de DNS) | Cero (Evaluado en el runtime del apiserver) |
| **Reglas personalizadas** | Ninguna (Pod Security Standards predefinidos: Privileged, Baseline, Restricted) | Ilimitadas (Turing-completo, lógica HTTP personalizada, Rego/YAML) | Alta (Declarative Common Expression Language) |
| **Capacidad de mutación**| No | Sí (`MutatingAdmissionWebhook`) | No (Solo validación y auditoría a partir de la v1.30) |
| **Búsqueda de estado externo**| No | Sí (Puede consultar APIs externas, bases de datos, etcd) | No (Estrictamente funciones puras sobre el objeto/parámetros de la solicitud) |

### Matriz 2: Compensaciones (Trade-offs) de seguridad vs. disponibilidad de `failurePolicy`

| Modo | Postura de seguridad | Resiliencia / Disponibilidad del cluster | Caso de uso en producción |
| :--- | :--- | :--- | :--- |
| `failurePolicy: Fail` | **Fail-Closed (Seguro)**. Bloquea la solicitud si el webhook es inalcanzable, agota el tiempo de espera (timeout) o devuelve un error 5xx. | **Riesgo de interrupción (Outage)**. Un fallo en el servicio de webhook detiene las tuberías (pipelines) de despliegue y las modificaciones de recursos en todos los ámbitos coincidentes. | Obligatorio para webhooks de seguridad/cumplimiento en producción (ej., verificación de firma de imágenes, bloqueo de ejecución como root). |
| `failurePolicy: Ignore` | **Fail-Open (Inseguro)**. Permite que la solicitud continúe si el webhook da error o agota el tiempo de espera. | **Alta disponibilidad**. El API Server continúa funcionando incluso si los pods del webhook están completamente caídos. | Webhooks no críticos (ej., etiquetado de telemetría, registro de auditoría sin aplicación estricta). |

---

## 3. Manifiestos completos de grado de producción

### 3.1 Production `ValidatingWebhookConfiguration` with mTLS and System Exclusion

Este manifiesto configura un webhook de validación dinámico que impone etiquetas estrictas. Excluye los namespaces del sistema para prevenir bloqueos mutuos (deadlocks) en el bootstrap y aplica un tiempo de espera (timeout) estricto de 3 segundos con `failurePolicy: Fail`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: enterprise-security-guardrail
  labels:
    app.kubernetes.io/name: security-guardrail
    app.kubernetes.io/part-of: platform-governance
spec:
  webhooks:
  - name: validate-security-controls.enterprise.io
    rules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods", "services"]
      scope:       "Namespaced"
    clientConfig:
      service:
        name: security-webhook-svc
        namespace: security-system
        path: "/validate-pod-spec"
        port: 443
      # Base64 encoded PEM certificate authority that signed the webhook server certificate
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVTnZXd1l0SmZ1Znd6TEpYVDRNZEh2Zk5ZUWpFd0RRWUpLb1pJaHZjTkFRRUwKQlFBd1NURUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd0hoY05Nak13TnpBMU1qQXdNQjRYRFRNNE16QXhNVEl3Ck1qQXdNQjB3U1RFTE1Ba0dBMTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd2dnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3CmdnRUZBQUtDQVFFQXJ6M0JBNzFsZzBVS1E1U0MvYWRaMVYxM0R5cVVqNWJrbk5xTHQ3Yzc0TGp5N3dNQmt4eDEKNm45VXZ3dHFBTHI3c0s0YjNmNGc3QU8yWUpvL09vOWM3a2FldDhpT21RUlZ2Smt2eW0ybUtvdTdpSUtSRnFkQQp3N2Zic1dEelQ0SmlCQUFBPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    admissionReviewVersions:
    - "v1"
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
    matchPolicy: Equivalent
    namespaceSelector:
      matchExpressions:
      - key: security.enterprise.io/enforce
        operator: In
        values: ["true"]
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values:
        - kube-system
        - kube-public
        - kube-node-lease
        - security-system
    objectSelector:
      matchExpressions:
      - key: app.kubernetes.io/managed-by
        operator: NotIn
        values: ["helm"]
```

### 3.2 Production `MutatingWebhookConfiguration` with `reinvocationPolicy`

Este webhook inyecta sidecars de seguridad o contextos de seguridad por defecto en las cargas de trabajo (workloads) entrantes. Especifica `reinvocationPolicy: IF_NEEDED` para garantizar que los cambios realizados por otros mutating webhooks aguas abajo (downstream) sean reevaluados.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: enterprise-security-mutator
spec:
  webhooks:
  - name: mutate-security-context.enterprise.io
    rules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE"]
      resources:   ["pods"]
      scope:       "Namespaced"
    clientConfig:
      service:
        name: security-mutator-svc
        namespace: security-system
        path: "/mutate-pods"
        port: 443
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVTnZXd1l0SmZ1Znd6TEpYVDRNZEh2Zk5ZUWpFd0RRWUpLb1pJaHZjTkFRRUwKQlFBd1NURUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd0hoY05Nak13TnpBMU1qQXdNQjRYRFRNNE16QXhNVEl3Ck1qQXdNQjB3U1RFTE1Ba0dBMTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd2dnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3CmdnRUZBQUtDQVFFQXJ6M0JBNzFsZzBVS1E1U0MvYWRaMVYxM0R5cVVqNWJrbk5xTHQ3Yzc0TGp5N3dNQmt4eDEKNm45VXZ3dHFBTHI3c0s0YjNmNGc3QU8yWUpvL09vOWM3a2FldDhpT21RUlZ2Smt2eW0ybUtvdTdpSUtSRnFkQQp3N2Zic1dEelQ0SmlCQUFBPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    admissionReviewVersions: ["v1"]
    sideEffects: NoneOnDryRun
    timeoutSeconds: 5
    failurePolicy: Fail
    reinvocationPolicy: IF_NEEDED
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "security-system"]
```

### 3.3 Zero-Trust In-Tree Policy: `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` (CEL)

El control de admisión nativo de Kubernetes que utiliza Common Expression Language (CEL) se ejecuta directamente dentro de `kube-apiserver`. La siguiente política impone dos reglas en los Pods:
1. `readOnlyRootFilesystem` debe configurarse en `true`.
2. Las etiquetas de imagen (tags) no deben usar `latest`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: enforce-pod-hardening
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem == true)"
      message: "Security Hardening Breach: Every container must set securityContext.readOnlyRootFilesystem to true."
      reason: Invalid
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest') && c.image.contains(':'))"
      message: "Supply Chain Risk: Containers are forbidden from using floating ':latest' tags or untagged images."
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: enforce-pod-hardening-binding
spec:
  policyName: enforce-pod-hardening
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-public"]
```

### 3.4 Cluster-Wide `AdmissionConfiguration` for PodSecurity Admission (PSA)

Este archivo estático del plano de control (control plane) configura los valores predeterminados de admisión de `PodSecurity` en todo el cluster. Aplica reglas `baseline` por defecto, audita reglas `restricted` y exime a la infraestructura del sistema.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1
    kind: PodSecurityConfiguration
    defaults:
      enforce: "baseline"
      enforce-version: "latest"
      audit: "restricted"
      audit-version: "latest"
      warn: "restricted"
      warn-version: "latest"
    exemptions:
      usernames: []
      runtimeClassNames: []
      namespaces:
      - kube-system
      - kube-public
      - kube-node-lease
```

---

## 4. Comandos de CLI operacionales y salidas esperadas de la terminal

### Paso 4.1: Generación de certificados de servidor TLS para un Admission Webhook

Los admission webhooks **deben** servirse a través de HTTPS con certificados TLS válidos en los que confíe `kube-apiserver`.

```bash
$ openssl req -new -newkey rsa:4096 -nodes \
    -keyout webhook-server.key \
    -out webhook-server.csr \
    -subj "/CN=security-webhook-svc.security-system.svc"

$ cat <<EOF > san.ext
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = security-webhook-svc
DNS.2 = security-webhook-svc.security-system
DNS.3 = security-webhook-svc.security-system.svc
DNS.4 = security-webhook-svc.security-system.svc.cluster.local
EOF

$ openssl x509 -req -in webhook-server.csr \
    -CA /etc/kubernetes/pki/ca.crt \
    -CAkey /etc/kubernetes/pki/ca.key \
    -CAcreateserial \
    -out webhook-server.crt \
    -days 365 \
    -extfile san.ext
```

**Salida esperada de la terminal:**
```text
Signature ok
subject=CN = security-webhook-svc.security-system.svc
Getting CA Private Key
```

### Paso 4.2: Inspección de Admission Webhooks activos y sus configuraciones

```bash
$ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o wide
```

**Salida esperada de la terminal:**
```text
NAME                                                                 WEBHOOKS   AGE
validatingwebhookconfiguration.admissionregistration.k8s.io/enterprise-security-guardrail   1          4d2h

NAME                                                                 WEBHOOKS   AGE
mutatingwebhookconfiguration.admissionregistration.k8s.io/enterprise-security-mutator     1          4d2h
```

### Paso 4.3: Prueba de aplicación de políticas mediante Server Dry-Run

Validar si una carga de trabajo (workload) que no cumple las normas activa la denegación en la admisión sin persistir los cambios:

```bash
$ kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload-test
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Salida esperada de la terminal:**
```text
Error from server (Forbidden): error when creating "STDIN": pods "insecure-workload-test" is forbidden: validaterule deny request: 
[ValidatingAdmissionPolicy: enforce-pod-hardening] Supply Chain Risk: Containers are forbidden from using floating ':latest' tags or untagged images.
[ValidatingAdmissionPolicy: enforce-pod-hardening] Security Hardening Breach: Every container must set securityContext.readOnlyRootFilesystem to true.
```

### Paso 4.4: Auditoría de métricas de latencia de webhooks del API Server

Para determinar si los webhooks están degradando el rendimiento de `kube-apiserver`, consulte el endpoint de métricas de Prometheus del API server:

```bash
$ kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_bucket
```

**Salida esperada de la terminal:**
```text
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.05"} 1420
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.1"} 1485
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.5"} 1501
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="+Inf"} 1501
```

---

## 5. Guía de verificación, hardening y resolución de problemas (Troubleshooting)

### 5.1 Modos de fallo comunes y flujos de trabajo de diagnóstico

#### Escenario A: Timeout del webhook causando `InternalError` (HTTP 500)
**Síntoma:** `kubectl apply` devuelve `Internal error occurred: failed calling webhook... context deadline exceeded`.

```
           Admission Timeout Troubleshooting Flow
           
  +-------------------------------------------------------+
  | Symptom: context deadline exceeded (Webhook Timeout)  |
  +-------------------------------------------------------+
                              |
                              v
       +---------------------------------------------+
       | Check Webhook Pod & Endpoint Status         |
       | $ kubectl get pods,ep -n <webhook-ns>       |
       +---------------------------------------------+
                              |
              +---------------+---------------+
              |                               |
       [Endpoints Ready]             [No Endpoints / Pending]
              |                               |
              v                               v
  +-----------------------+       +-----------------------+
  | Check NetworkPolicy / |       | Inspect Pod Logs &    |
  | Firewall / Egress     |       | Deployment Events     |
  | Rules (Port 443/8443) |       | $ kubectl logs -n ... |
  +-----------------------+       +-----------------------+
```

1. **Verificar la disponibilidad del endpoint del webhook:**
   ```bash
   $ kubectl get endpoints security-webhook-svc -n security-system
   ```
2. **Inspeccionar los registros de error (logs) del API Server:**
   ```bash
   $ journalctl -u kube-apiserver -g "failed calling webhook" --no-pager | tail -n 20
   ```
   *Buscar `x509: certificate signed by unknown authority` (descoincidencia en `caBundle`) o `i/o timeout` (NetworkPolicy bloqueando el tráfico de master a worker en los puertos 443/8443).*

#### Escenario B: Bloqueo mutuo (Deadlock) del plano de control durante el reinicio de nodos
**Síntoma:** Los nodos del cluster se reinician, `kube-apiserver` está activo, pero ningún pod en el cluster puede iniciar. CoreDNS está atascado en `Pending`.  
**Causa raíz:** El Admission Webhook tiene `failurePolicy: Fail` y no excluye `kube-system`. Cuando el API server llama al webhook, CoreDNS está caído, la resolución DNS falla, la llamada al webhook falla, bloqueando el inicio del pod de CoreDNS (bloqueo circular).  
**Remediación de emergencia:**
Eliminar o parchear temporalmente la `ValidatingWebhookConfiguration` bloqueante directamente:

```bash
$ kubectl delete validatingwebhookconfiguration enterprise-security-guardrail
```

---

## 6. Referencias

* **Documentación de Kubernetes — Dynamic Admission Control:**  
  [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
* **Documentación de Kubernetes — Validating Admission Policy (CEL):**  
  [https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
* **Documentación de Kubernetes — Pod Security Admission (PSA):**  
  [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **Plan de estudios del examen CNCF KCSA:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)