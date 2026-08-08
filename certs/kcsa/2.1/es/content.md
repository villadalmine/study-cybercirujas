# Material de estudio KCSA: Dominio 2.1 — Endurecimiento del API Server y Arquitectura de Seguridad

## 1. Motivación de Producción y Problema Arquitectónico

El `kube-apiserver` es el nexo central del plano de control de Kubernetes. Es el único componente que se comunica directamente con `etcd`, sirviendo como la pasarela sin estado (stateless gateway) para todas las interacciones operativas, de gestión y programáticas dentro del clúster. Cada comando `kubectl`, bucle de controlador interno, solicitud de admisión dinámica y actualización del estado del nodo Kubelet debe enrutarse a través del API server y ser evaluado por este.

```
                     +-----------------------------------------------------------------------+
                     |                          kube-apiserver                               |
                     |                                                                       |
  +---------------+  |  +------------------+  +-----------------+  +-------------------+  |   +----------+
  |  Client       |---> |  1. Authentication--> 2. Authorization--> 3. Admission Control---> | etcd     |
  | (kubectl/SDK) |  |  +------------------+  +-----------------+  +-------------------+  |   | Storage  |
  +---------------+  +-----------------------------------------------------------------------+   +----------+
```

### Modos de Falla en Producción y Vectores de Vulnerabilidad en Configuraciones por Defecto

1. **Riesgos de Acceso No Autenticado / Anónimo:**
   En clústeres no endurecidos, `--anonymous-auth=true` (el valor por defecto histórico) permite a los clientes no autenticados alcanzar el pipeline del API server. Si los permisos de RBAC vinculan inadvertidamente roles a `system:unauthenticated` o `system:authenticated`, actores maliciosos pueden enumerar grupos de API, descubrir la topología del clúster o leer metadatos sensibles a través de endpoints como `/metrics` o `/api/v1`.

2. **Exposición de Secrets en Texto Plano en el Almacenamiento (`etcd`):**
   Por defecto, `kube-apiserver` escribe el estado de los recursos (incluyendo objetos `v1/Secret`) en `etcd` en formatos JSON/protobuf sin cifrar, en bruto. Un atacante que obtenga acceso de lectura al disco del host `etcd` subyacente, snapshots de volúmenes o certificados de cliente de `etcd` puede recuperar claves privadas TLS en bruto, tokens de service account y contraseñas de bases de datos sin interactuar con la capa de autorización de la API.

3. **Exfiltración de Tokens de Service Account y Escalado de Privilegios:**
   Las implementaciones heredadas de Kubernetes montan automáticamente tokens de service account basados en Secret de larga duración en el sistema de archivos del contenedor de cada Pod en `/var/run/secrets/kubernetes.io/serviceaccount/token`. Si un Pod de aplicación se ve comprometido a través de ejecución remota de código (RCE), un atacante puede extraer este token estático e invocar el API server. Si las vinculaciones de RBAC son excesivamente permisivas (por ejemplo, otorgando cluster-admin o comodines `verbs: ["*"]`), el atacante logra el compromiso total del clúster.

4. **Bloqueos Mutuos (Deadlocks) y Denegación de Servicio (DoS) en Webhooks de Admisión Dinámica:**
   Los controladores de admisión dinámica (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`) extienden la lógica de evaluación del API server invocando endpoints HTTPS externos. Un webhook mal configurado con `failurePolicy: Fail`, un valor alto de `timeoutSeconds` y la falta de exclusiones mediante `namespaceSelector` puede bloquear namespaces críticos del sistema (`kube-system`). Si el Pod del webhook externo se bloquea o sufre latencia de red, `kube-apiserver` rechaza o se cuelga en todas las creaciones de recursos, incluyendo los Pods necesarios para recuperar el propio servicio del webhook.

5. **Agotamiento de Recursos mediante Solicitudes API No Limitadas:**
   Sin la función de API Priority and Fairness (APF) habilitada y configurada, el tráfico masivo (como bucles de controladores anómalos, actualizaciones excesivas de estado o escaneos externos de fuerza bruta) puede agotar la memoria y los hilos de trabajo (goroutines) del API server, causando la falta de respuesta del plano de control (`HTTP 503 / 429`) para controladores críticos del sistema.

---

## 2. Comparaciones Arquitectónicas Técnicas y Compromisos (Trade-offs)

### 2.1 Matriz de Estrategias de Autenticación

| Estrategia | Arquitectura Mecánica | Postura de Seguridad | Sobrecarga Operativa | Compromiso (Trade-off) en Producción |
| :--- | :--- | :--- | :--- | :--- |
| **X.509 Client Certificates** | El cliente demuestra su identidad a través de mTLS; el Common Name (CN) se mapea a User, Organization (O) a Groups. | **Alta** (Firmado criptográficamente, no falsificable). | **Alta** (Sin estándar de revocación nativo como CRL/OCSP dentro del API server; requiere rotación de CA). | Excelente para componentes estáticos del plano de control (Kubelet, Scheduler); deficiente para la gestión de identidades de usuarios debido a restricciones de revocación. |
| **OpenID Connect (OIDC)** | Bearer JWT firmado por un IdP externo (Okta, Keycloak); el API server verifica la firma mediante JWKS público. | **Muy Alta** (Tokens de corta duración, identidad centralizada y aplicación de MFA). | **Media** (Requiere integración con IdP y configuración de flags externos). | Estándar recomendado para usuarios humanos. La duración del token es controlada por el IdP; sin almacenamiento local de tokens dentro del clúster. |
| **Webhook Token Authentication** | El API server envía un objeto JSON `TokenReview` mediante POST a un endpoint HTTPS externo para validar tokens portadores (bearer tokens). | **Alta** (Validación remota dinámica). | **Alta** (Sobrecarga de red por cada solicitud de autenticación no almacenada en caché; dependencia de la disponibilidad del webhook). | Ideal para puentes de autenticación personalizados, integraciones heredadas empresariales o capas de identidad de proveedores de nube. |
| **Service Account Bound Tokens (Bound Tokens API)** | Los volúmenes proyectados generan JWTs de corta duración vinculados a la identidad del Pod, tiempo y audiencia específica. | **Muy Alta** (Limitados a una audiencia, auto-rotativos, invalidados al eliminar el Pod). | **Baja** (Manejado nativamente por el API server y Kubelet a través de la API `TokenRequest`). | Reemplaza los tokens estáticos heredados basados en Secret. Previene ataques de retransmisión de tokens (token replay) entre clústeres mediante restricción de audiencia. |

### 2.2 Matriz de Motores de Autorización

```
                      Authorization Pipeline Request Evaluation
                                          │
                                          ▼
                                ┌───────────────────┐
                                │   NodeAuthorizer  │ ──(Pass/Next)──►
                                └───────────────────┘
                                          │ (Allow)
                                          ▼
                                ┌───────────────────┐
                                │        RBAC       │ ──(Pass/Next)──►
                                └───────────────────┘
                                          │ (Allow)
                                          ▼
                                ┌───────────────────┐
                                │  Webhook (OPA/etc)│ ──(Pass/Deny)──► Result
                                └───────────────────┘
```

| Motor | Mecánica | Flexibilidad | Impacto en el Rendimiento | Mejor Caso de Uso |
| :--- | :--- | :--- | :--- | :--- |
| **Node Authorizer** | Autorizador de propósito especial que impone que los Kubelets solo puedan leer/escribir recursos relacionados con su nodo específico. | Alcance estático basado en la identidad del nodo. | Despreciable (~microsegundos). | Obligatorio para asegurar los límites de Kubelet-a-APIServer (`--authorization-mode=Node,RBAC`). |
| **RBAC (Role-Based Access Control)** | Evalúa `Roles`, `ClusterRoles`, `RoleBindings` y `ClusterRoleBindings` declarativos. | Moderada (Granular para grupos de API, recursos, verbos, nombres). | Bajo (Caché de evaluación en memoria). | Estándar por defecto para service accounts intra-clúster, cargas de trabajo y acceso de usuarios. |
| **ABAC (Attribute-Based Access Control)** | Evalúa reglas definidas en un archivo de política JSON estático en el host del API server. | Baja (Requiere reiniciar el API server para cambiar políticas). | Bajo. | Obsoleto en producción. Alta fricción operativa y riesgo de seguridad debido al mantenimiento estático. |
| **Webhook (ej. OPA / Gatekeeper)** | El API server envía un payload JSON `SubjectAccessReview` a un motor de autorización remoto. | Extremadamente Alta (Lógica consciente del contexto, filtrado por rango de IP, acceso basado en tiempo). | Medio (Latencia de ida y vuelta de red añadida a la fase de autorización). | Requisitos de cumplimiento empresarial avanzados donde el RBAC estándar no puede evaluar contexto externo. |

---

## 3. Manifiestos de Producción y Arquitectura de Configuración

### Manifiesto 1: Static Pod Manifest Endurecido de `kube-apiserver.yaml`
Ubicación: `/etc/kubernetes/manifests/kube-apiserver.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 192.168.1.10:6443
  creationTimestamp: null
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.1.10
    - --allow-privileged=false
    - --anonymous-auth=false
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction,PodSecurity,ServiceAccount
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --encryption-provider-config=/etc/kubernetes/security/encryption-config.yaml
    - --audit-policy-file=/etc/kubernetes/security/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS12
    image: registry.k8s.io/kube-apiserver:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 192.168.1.10
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-apiserver
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 192.168.1.10
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/security
      name: k8s-security
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: k8s-audit-logs
      readOnly: false
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: /etc/kubernetes/security
      type: DirectoryOrCreate
    name: k8s-security
  - hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
    name: k8s-audit-logs
```

---

### Manifiesto 2: `EncryptionConfiguration` Empresarial (Cifrado de Datos en Reposo AES-CBC)
Ubicación en el host: `/etc/kubernetes/security/encryption-config.yaml`

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIGEgc2VjcmV0IGlzIGEgc2VjcmV0IQ==
      - identity: {}
```

> **Nota de Seguridad:** El proveedor `identity: {}` debe colocarse en segundo lugar durante los ciclos de rotación de claves para que los datos no cifrados aún puedan leerse mientras que las nuevas escrituras se cifran con `key1` (`aescbc`).

---

### Manifiesto 3: Configuración de `AuditPolicy` de Seguridad de Alta Fidelidad
Ubicación en el host: `/etc/kubernetes/security/audit-policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Do not log system status checks or health probes
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/livez*"
      - "/readyz*"

  # 2. Log Secret and ConfigMap changes at Metadata level to protect payload confidentiality while auditing access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # 3. Log RBAC policy alterations at RequestResponse level (critical for auditing privilege escalations)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 4. Log pod executive access and port forwarding attempts at RequestResponse level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/portforward", "pods/attach"]

  # 5. Default catch-all for all other namespace-scoped operational modifications
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    executionData: true
```

---

### Manifiesto 4: `ValidatingWebhookConfiguration` de Nivel de Producción
Ubicación: `/tmp/validating-webhook.yaml`

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: security-policy-validation
spec:
  webhooks:
    - name: pod-security-enforcer.security.domain.internal
      rules:
        - apiGroups: [""]
          apiVersions: ["v1"]
          operations: ["CREATE", "UPDATE"]
          resources: ["pods"]
          scope: "Namespaced"
      clientConfig:
        service:
          name: webhook-validator-svc
          namespace: security-system
          path: "/validate-pods"
          port: 443
        caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
      admissionReviewVersions: ["v1"]
      sideEffects: None
      timeoutSeconds: 3
      failurePolicy: Fail
      namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: ["kube-system", "security-system"]
```

---

## 4. Comandos de Ejecución CLI y Salidas de Terminal de Producción

### Paso 4.1: Inspeccionando Detalles del Certificado de Cliente del API Server y SANs

```bash
$ openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 3 "Subject Alternative Name"
```
**Salida Esperada:**
```text
            X509v3 Subject Alternative Name: 
                DNS:k8s-control-01, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.10
    Signature Algorithm: sha256WithRSAEncryption
```

---

### Paso 4.2: Verificando la Eliminación de Autenticación Anónima Endurecida (`--anonymous-auth=false`)

```bash
$ curl -k -s -i https://127.0.0.1:6443/api/v1/namespaces
```
**Salida Esperada:**
```http
HTTP/2 401 
audit-id: 2d86a45b-76b1-4f76-8094-81fd001ec862
content-type: application/json
x-content-type-options: nosniff
content-length: 165
date: Fri, 07 Aug 2026 23:35:10 GMT

{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

---

### Paso 4.3: Validando el Cifrado de etcd en Reposo mediante Recuperación Directa de Claves

Primero, cree un secret de prueba en el namespace `default`:

```bash
$ kubectl create secret generic production-db-credentials --from-literal=password='SuperSecretPass2026!' -n default
```
**Salida Esperada:**
```text
secret/production-db-credentials created
```

Ahora, inspeccione directamente el almacenamiento de `etcd` utilizando `etcdctl` para verificar que el payload se almacena como texto cifrado (ciphertext):

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
  --endpoints=https://127.0.0.1:2379 \
  get /registry/secrets/default/production-db-credentials
```
**Salida Esperada:**
```text
/registry/secrets/default/production-db-credentials
k8s:enc:aescbc:v1:key1:[>!{`	|.+Z/~"=#!g!|,~1
	.G,%`
```
*(Observe el prefijo `k8s:enc:aescbc:v1:key1:` que confirma el cifrado exitoso mediante el proveedor `aescbc`).*

---

### Paso 4.4: Consultando Endpoints de Salud del Plano de Control del API Server

```bash
$ kubectl get --raw "/healthz?verbose"
```
**Salida Esperada:**
```text
[ping] connection succeeded
[log] response ok
[etcd] response ok
[poststarthook/start-kube-apiserver-admission-initializer] response ok
[poststarthook/generic-apiserver-start-informers] response ok
[poststarthook/priority-and-fairness-config-consumer] response ok
[poststarthook/bootstrap-controller] response ok
[poststarthook/start-cluster-authentication-info-controller] response ok
[poststarthook/start-kube-apiserver-identity-lease-controller] response ok
[poststarthook/start-kube-apiserver-identity-lease-garbage-collector] response ok
healthz check passed
```

---

### Paso 4.5: Inspeccionando las Configuraciones de Limitación de Tráfico (Throttling) de API Priority and Fairness (APF)

```bash
$ kubectl get flowschemas.flowcontrol.apiserver.k8s.io
```
**Salida Esperada:**
```text
NAME                    TIME-WINDOW   MATCHING-PRECEDENCE   DISTINGUISHER-METHOD   AGE
exempt                  0s            0                     <none>                 42d
probes                  0s            100                   <none>                 42d
system-leader-election  0s            200                   ByUser                 42d
workload-leader-election 0s           300                   ByUser                 42d
system-nodes            0s            400                   ByUser                 42d
kube-controller-manager 0s            800                   ByUser                 42d
kube-scheduler          0s            900                   ByUser                 42d
service-accounts        0s            9000                  ByNamespace            42d
global-default          0s            9900                  ByUser                 42d
catch-all               0s            10000                 ByUser                 42d
```

---

## 5. Guía de Verificación y Solución de Problemas (Runbook)

```
                         API Server Failure Troubleshooting Flow
                                           │
                                           ▼
                            Is kube-apiserver pod running?
                                   │              │
                           (No)    │              │ (Yes)
              ┌────────────────────┘              └────────────────────┐
              ▼                                                        ▼
   Check Static Pod Manifest                     Check API Server Logs & Status
   - Location: /etc/kubernetes/manifests/        - kubectl get --raw /readyz
   - View Container Logs:                        - Check Audit Logs: /var/log/kubernetes/
     crictl logs <container-id>                    audit.log
              │                                                        │
              ▼                                                        ▼
   Common Causes:                                 Common Causes:
   1. Syntax error in EncryptionConfig/           1. Admission Webhook Timeout (HTTP 500)
      AuditPolicy YAML file                       2. APF Flow Schema Throttling (HTTP 429)
   2. Certificate Expiry / Path mismatch          3. etcd Connectivity/Disk Latency
   3. Unsupported flag values
```

### Escenario 1: CrashLoopBackOff de `kube-apiserver` Después de Configurar Políticas de Cifrado o Auditoría

#### Análisis de Causa Raíz
Si un archivo subyacente referenciado por flags de línea de comandos (por ejemplo, `--encryption-provider-config` o `--audit-policy-file`) contiene sintaxis YAML inválida, claves faltantes o rutas de montaje inalcanzables dentro de la definición del static pod, `kube-apiserver` fallará en la inicialización en tiempo de ejecución y se finalizará instantáneamente.

#### Flujo de Trabajo Diagnóstico y Pasos de Resolución

1. Verifique el estado del static pod en el nodo del plano de control a través de `crictl`:

```bash
$ crictl ps -a --name kube-apiserver
```
**Salida Esperada:**
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS            POD ID
c1a2b3c4d5e6        a89f412c2a0b        20 seconds ago      Exited              kube-apiserver      3                   f9e8d7c6b5a4
```

2. Extraiga los últimos logs de error del contenedor finalizado:

```bash
$ crictl logs c1a2b3c4d5e6
```
**Salida Esperada de Snippet de Log Diagnóstico:**
```text
F0807 23:42:15.123456       1 server.go:302] error starting api server: error opening encryption provider configuration file "/etc/kubernetes/security/encryption-config.yaml": error loading configuration file: yaml: unmarshal errors: line 7: field keyss not found in type apiserver.Configuration
```

3. **Remediación:** Corrija el error de sintaxis (`keyss` -> `keys`) en `/etc/kubernetes/security/encryption-config.yaml`. El Kubelet monitorea `/etc/kubernetes/manifests` y `/etc/kubernetes/security`, y reiniciará automáticamente el static pod una vez guardado.

---

### Escenario 2: Bloqueo de Webhook de Admisión Dinámica (Deadlock de Solicitudes API)

#### Análisis de Causa Raíz
Un `ValidatingWebhookConfiguration` configurado con `failurePolicy: Fail` apunta a un endpoint de webhook que no es enrutable, se bloquea o agota el tiempo de espera. Cualquier solicitud entrante de creación de API que coincida con la regla se cuelga hasta que expira `timeoutSeconds`, y luego falla con `HTTP 500 / Internal Server Error`.

#### Flujo de Trabajo Diagnóstico y Pasos de Resolución

1. Pruebe la creación de recursos y observe el error exacto de rechazo del API server:

```bash
$ kubectl run test-pod --image=nginx:alpine -n default
```
**Salida Esperada:**
```text
Error from server (InternalError): Internal error occurred: failed calling webhook "pod-security-enforcer.security.domain.internal": failed to call webhook: Post "https://webhook-validator-svc.security-system.svc:443/validate-pods?timeout=3s": context deadline exceeded
```

2. Remediación Temporal de Emergencia:
Omita o elimine la configuración del webhook bloqueante interactuando directamente con el API server (o utilizando credenciales administrativas):

```bash
$ kubectl delete validatingwebhookconfiguration security-policy-validation --ignore-not-found
```
**Salida Esperada:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io "security-policy-validation" deleted
```

3. **Prevención Arquitectónica:**
Asegúrese siempre de que los namespaces críticos del sistema estén exentos utilizando `namespaceSelector`:

```yaml
namespaceSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: ["kube-system", "security-system"]
```

---

### Escenario 3: Investigando la Limitación de Tasa y el Estrangulamiento (Throttling) de API Priority & Fairness (`HTTP 429`)

#### Análisis de Causa Raíz
Las solicitudes de clientes que exceden los límites de concurrencia establecidos por `PriorityLevelConfiguration` y `FlowSchema` se encolan. Una vez agotada la profundidad de la cola, el API server rechaza el tráfico entrante con `HTTP 429 Too Many Requests`.

#### Flujo de Trabajo Diagnóstico y Pasos de Resolución

1. Inspeccione las métricas del API server para caídas de APF utilizando `curl` con autenticación de certificado de cliente:

```bash
$ kubectl get --raw "/metrics" | grep "apiserver_flowcontrol_rejected_requests_total"
```
**Salida de Diagnóstico Esperada:**
```text
# HELP apiserver_flowcontrol_rejected_requests_total [ALPHA] Number of requests rejected by API Priority and Fairness system
# TYPE apiserver_flowcontrol_rejected_requests_total counter
apiserver_flowcontrol_rejected_requests_total{flow_schema="service-accounts",priority_level="workload-high",reason="queue-full"} 142
```

2. Identifique el nivel de prioridad saturado y verifique sus límites de concurrencia actuales:

```bash
$ kubectl get prioritylevelconfiguration workload-high -o yaml
```

3. **Remediación:** Ajuste la configuración de concurrencia `handseat` o incremente `queueLengthLimit` en el objeto `PriorityLevelConfiguration` objetivo para dar cabida a patrones de tráfico en ráfagas de microservicios.

---

## 6. Referencias

- **CNCF KCSA Curriculum Specification:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Official Documentation — Controlling API Access:**  
  https://kubernetes.io/docs/concepts/security/controlling-access/
- **Kubernetes Official Documentation — Encrypting Confidential Data at Rest:**  
  https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- **Kubernetes Official Documentation — Auditing Architecture & Policies:**  
  https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- **Kubernetes Official Documentation — Dynamic Admission Control Webhooks:**  
  https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Kubernetes Official Documentation — API Priority and Fairness:**  
  https://kubernetes.io/docs/concepts/cluster-administration/flow-control/