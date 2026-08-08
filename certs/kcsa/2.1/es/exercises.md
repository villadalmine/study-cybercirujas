# Módulo de Certificación KCSA: Tema 2.1 – Arquitectura de Seguridad y Fortalecimiento del API Server

**Dominio:** Arquitectura de Seguridad del Cluster / Fortalecimiento del Control Plane  
**Certificación Objetivo:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Tema:** 2.1 API Server Security  
**Peso:** 2.0  
**Fuentes de Referencia:**
- [CNCF KCSA Curriculum v1.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Official Documentation - kube-apiserver Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Kubernetes Official Documentation - Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes Official Documentation - Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Kubernetes Official Documentation - Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

## 1. Visión General de la Arquitectura y Pipeline de Procesamiento de Solicitudes

El `kube-apiserver` actúa como la puerta de enlace principal del control plane para todas las interacciones del cluster. Cada solicitud (proveniente de administradores humanos, ServiceAccounts, kubelets de los nodos o controladores externos) pasa por un pipeline de procesamiento secuencial estricto y multietapa antes de mutar o leer el estado de `etcd`.

```
                    +-------------------------------------------------------+
                    |                 kube-apiserver Pipeline               |
                    +-------------------------------------------------------+
  Incoming Request  |                                                       |
  (TLS / Port 6443) |---> [ 1. Transport Security (mTLS / TLS 1.3) ]         |
                    |                   |                                   |
                    |                   v                                   |
                    |         [ 2. Authentication (AuthN) ]                 |
                    |                   | (User / Groups / ServiceAccount)  |
                    |                   v                                   |
                    |         [ 3. Authorization (AuthZ) ]                  |
                    |                   | (RBAC / Node / Webhook)           |
                    |                   v                                   |
                    |     [ 4. Admission Control (Mutating) ]               |
                    |                   |                                   |
                    |                   v                                   |
                    |     [ 5. Schema Validation & Object Verification ]    |
                    |                   |                                   |
                    |                   v                                   |
                    |     [ 6. Admission Control (Validating) ]             |
                    |                   |                                   |
                    +-------------------|-----------------------------------+
                                        v
                            [ etcd Persistence Storage ]
```

### Vectores de Seguridad Clave y Mecánica
1. **Authentication (AuthN):** Valida la identidad a través de certificados de cliente X.509, OIDC, Webhook Tokens o JWTs de ServiceAccount. Las solicitudes anónimas (`system:unauthenticated`) deben ser restringidas.
2. **Authorization (AuthZ):** Evalúa si la identidad autenticada puede realizar `verbs` (ej. `get`, `create`, `delete`) en los `resources`. Los modos se ejecutan en el orden declarado (`--authorization-mode=Node,RBAC`).
3. **Admission Control:** Intercepta solicitudes después de AuthZ pero antes de la persistencia en etcd. Los webhooks de tipo Mutating aplican parches a la carga útil (payloads); los webhooks de tipo Validating hacen cumplir invariantes de seguridad (ej. Pod Security Standards).
4. **Audit Logging:** Captura transiciones de estado a través de cuatro etapas granulares: `RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`.

---

## 2. Ejercicios Guiados Prácticos

---

### Ejercicio 1: Fortalecimiento del Control Plane y Optimización de Cipher Suites de TLS

#### Escenario
Como SRE Senior, tenés la tarea de fortalecer un nodo del control plane. Debés deshabilitar el acceso no autenticado, restringir la negociación TLS a cifrados modernos y fuertes, y hacer cumplir mTLS (TLS mutual) para las comunicaciones con etcd.

#### Paso 1.1: Auditar la configuración existente del pod estático del API Server
Ubicá y visualizá el manifiesto del pod estático para `kube-apiserver` en tu nodo del control plane.

```bash
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Salida Esperada (Extracto):**
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.1.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --secure-port=6443
    image: registry.k8s.io/kube-apiserver:v1.30.0
```

#### Paso 1.2: Aplicar Flags de Fortalecimiento para Producción
Modificá `/etc/kubernetes/manifests/kube-apiserver.yaml` para hacer cumplir los siguientes parámetros de seguridad:
- Deshabilitar la autenticación anónima: `--anonymous-auth=false`
- Establecer la versión mínima de TLS a 1.3: `--tls-min-version=VersionTLS13`
- Restringir los cipher suites para alternativas en TLS 1.2 (fallbacks): `--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`

```bash
sudo yq eval -i '.spec.containers[0].command += [
  "--anonymous-auth=false",
  "--tls-min-version=VersionTLS13",
  "--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
]' /etc/kubernetes/manifests/kube-apiserver.yaml
```

#### Paso 1.3: Verificar el Reinicio de kube-apiserver y el Handshake del Puerto
Monitoreá el reemplazo del pod del API Server por parte del `kubelet` local:

```bash
sudo crictl ps --name kube-apiserver
```

**Salida Esperada:**
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS      POD ID
f3a82910c2d3b       a6a4a87262111       12 seconds ago      Running             kube-apiserver      0             12a4b899c011e
```

Verificá la negociación TLS utilizando `openssl`:

```bash
openssl s_client -connect 127.0.0.1:6443 -tls1_2 < /dev/null
```

**Salida Esperada (Extracto):**
```text
CONNECTED(00000003)
140683050116416:error:1409442E:SSL routines:ssl3_read_bytes:tlsv1 alert protocol version:../ssl/record/rec_layer_s3.c:1544:SSL alert number 70
---
no peer certificate available
```

#### Paso 1.4: Verificar el Comportamiento de Solicitudes Anónimas
Intentá realizar una solicitud no autenticada al API Server:

```bash
curl -k -X GET https://127.0.0.1:6443/api/v1/namespaces
```

**Salida Esperada:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

---

#### Preguntas de Verificación (Ejercicio 1)

1. ¿Qué vulnerabilidad de seguridad se introduce cuando `--anonymous-auth=true` se combina con un binding RBAC excesivamente permisivo para `system:unauthenticated` o `system:authenticated`?
2. ¿Por qué establecer `--tls-min-version=VersionTLS13` hace que el flag `--tls-cipher-suites` no tenga efecto para los handshakes de TLS 1.3?

---

### Ejercicio 2: Implementación de Audit Logging Empresarial y Detección de Amenazas

#### Escenario
El cumplimiento normativo requiere registrar todas las modificaciones de secrets al nivel de `RequestResponse`, metadatos para todas las operaciones de pods, e ignorar solicitudes del sistema de lectura de bajo riesgo (health checks) para reducir la sobrecarga de I/O.

#### Paso 2.1: Construir el Manifiesto de Audit Policy
Creá un archivo de Audit Policy de Kubernetes sintácticamente válido en `/etc/kubernetes/audit-policy.yaml`:

```yaml
cat <<'EOF' | sudo tee /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # 1. Omit noisy system health check endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/metrics"

  # 2. Ignore system controller leases
  - level: None
    resources:
      - group: ""
        resources: ["endpoints", "services/status"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # 3. Log Secret and ConfigMap modifications at RequestResponse level for forensic analysis
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
    verbs: ["create", "update", "patch", "delete"]

  # 4. Log Pod modifications at Request level
  - level: Request
    resources:
      - group: ""
        resources: ["pods"]
    verbs: ["create", "update", "patch", "delete"]

  # 5. Catch-all rule for metadata level for all other requests
  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF
```

#### Paso 2.2: Configurar los Flags de Auditoría de `kube-apiserver` y los Volume Mounts de Host Path
Actualizá `/etc/kubernetes/manifests/kube-apiserver.yaml` para incluir los flags de auditoría y montar los directorios del host.

Agregá los flags a `spec.containers[0].command`:
- `--audit-log-path=/var/log/kubernetes/audit.log`
- `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`
- `--audit-log-maxage=30`
- `--audit-log-maxbackup=10`
- `--audit-log-maxsize=100`

Agregá los Volume Mounts a `spec.containers[0].volumeMounts`:
```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: audit-log
      readOnly: false
```

Agregá los Volumes a `spec.volumes`:
```yaml
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
```

Aplicá estas ediciones directamente en `/etc/kubernetes/manifests/kube-apiserver.yaml`.

#### Paso 2.3: Generar Eventos de Auditoría de Prueba
Creá un namespace de prueba y un Secret para activar las reglas de auditoría configuradas:

```bash
kubectl create namespace audit-test
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=SuperSecretPass123! \
  -n audit-test
```

#### Paso 2.4: Inspeccionar los Logs de Auditoría JSON para Evidencia Forense
Consultá `/var/log/kubernetes/audit.log` para extraer el evento `RequestResponse` del Secret creado:

```bash
sudo tail -n 100 /var/log/kubernetes/audit.log | jq 'select(.objectRef.resource=="secrets" and .verb=="create")'
```

**Salida Esperada (Extracto):**
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-test/secrets?fieldManager=kubectl-create",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": [
      "system:masters",
      "system:authenticated"
    ]
  },
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-test",
    "name": "db-credentials",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 201
  },
  "responseObject": {
    "kind": "Secret",
    "apiVersion": "v1",
    "metadata": {
      "name": "db-credentials",
      "namespace": "audit-test"
    },
    "data": {
      "password": "U3VwZXJTZWNyZXRQYXNzMTIzIQ==",
      "username": "YWRtaW4="
    },
    "type": "Opaque"
  }
}
```

---

#### Preguntas de Verificación (Ejercicio 2)

1. ¿Qué riesgos de seguridad se introducen al registrar recursos sensibles (tales como `secrets`) en el nivel de auditoría `RequestResponse`?
2. Si un evento de auditoría especifica `"stage": "ResponseComplete"`, ¿qué implica esto respecto a si la operación tuvo éxito o falló en `etcd`?

---

### Ejercicio 3: Depuración de Pipelines de Autenticación y Autorización del API Server

#### Escenario
Una ServiceAccount de una carga de trabajo en el namespace `production` no puede leer ConfigMaps. Debés rastrear la etapa de Autorización usando `kubectl auth can-i` e inspeccionar los atributos de identidad del certificado de cliente.

#### Paso 3.1: Crear la ServiceAccount de Prueba y Artefactos RBAC
Desplegá una ServiceAccount restringida, un Role y un RoleBinding:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-scanner
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: ServiceAccount
  name: app-scanner
  namespace: default
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

#### Paso 3.2: Ejecutar Verificaciones Previas de Autorización (`kubectl auth can-i`)
Evaluá los permisos desde la perspectiva de la ServiceAccount `app-scanner`:

```bash
# Test 1: Check pod reading capability
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=default
```
**Salida Esperada:** `yes`

```bash
# Test 2: Check secrets reading capability
kubectl auth can-i get secrets \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=default
```
**Salida Esperada:** `no`

```bash
# Test 3: Check pod reading in another namespace
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=kube-system
```
**Salida Esperada:** `no`

#### Paso 3.3: Inspeccionar Atributos Subject del Certificado X.509
Extraé e inspeccioná el certificado de cliente de administración utilizado para autenticarse contra el API Server:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout | grep -E "(Subject:|Issuer:)"
```

**Salida Esperada:**
```text
        Issuer: CN = kubernetes
        Subject: O = system:masters, CN = kube-apiserver-kubelet-client
```

---

#### Preguntas de Verificación (Ejercicio 3)

1. ¿Cómo mapea `kube-apiserver` los atributos del certificado X.509 (`Subject: O = ..., CN = ...`) al contexto de autenticación de Kubernetes?
2. Si `--authorization-mode=Node,RBAC` está configurado en `kube-apiserver`, ¿qué sucede si una solicitud es autorizada por el autorizador `Node` pero rechazada por `RBAC`?

---

### Ejercicio 4: Fortalecimiento del Admission Control Dinámico con Validating Webhooks

#### Escenario
Debés configurar un `ValidatingWebhookConfiguration` para hacer cumplir los estándares de seguridad de contenedores a nivel de cluster. Si el servicio externo del admission webhook no se puede contactar, el API Server debe fallar de forma cerrada (`FailurePolicy: Fail`) para evitar despliegues de cargas de trabajo no validadas.

#### Paso 4.1: Desplegar un Manifiesto de Configuración de Admission Webhook
Aplicá el siguiente manifiesto completo que define un `ValidatingWebhookConfiguration`:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: strict-sec-validation
webhooks:
  - name: validate.security.internal.domain
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: sec-webhook-svc
        namespace: security-system
        path: "/validate-pods"
        port: 443
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVT0daMVlXUnZaRzFzWVhSMFlTNWhjR2x6WlhKMGFXOXVNVDR3REFZRFZRUUQKRXdZd01EQWVGdzB5TkRBek1URXhNREExTVRCYUZ3MHpOREF6TVRBeE1EQTFNVEJhTUJNeExEQUJCZ05WQkFNTQpFN3d3TURDQ0FTSXdEUVlKS29aSXZjTkFRRUJCUUFEZ2dFUEFEQ0NBUW9DZ2dFQkFNNW9xM2g5SnE3UQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    failurePolicy: Fail
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "security-system"]
EOF
```

#### Paso 4.2: Verificar el Comportamiento de Bloqueo de Admisión
Intentá crear un pod en el namespace `default` mientras el servicio backend del webhook subyacente `sec-webhook-svc` está deshabilitado intencionalmente (offline):

```bash
kubectl run test-pod --image=nginx:alpine -n default
```

**Salida Esperada:**
```text
Error from server (InternalError): Internal error occurred: failed calling webhook "validate.security.internal.domain": failed to call webhook: Post "https://sec-webhook-svc.security-system.svc:443/validate-pods?timeout=5s": service "sec-webhook-svc" not found
```

#### Paso 4.3: Limpiar el Webhook para Restaurar la Operación del Cluster

```bash
kubectl delete validatingwebhookconfiguration strict-sec-validation
```

---

#### Preguntas de Verificación (Ejercicio 4)

1. ¿Cuál es la diferencia operativa entre `failurePolicy: Fail` y `failurePolicy: Ignore` en un `ValidatingWebhookConfiguration`?
2. ¿Por qué es una práctica recomendada de seguridad crítica excluir `kube-system` mediante `namespaceSelector` al configurar admission webhooks de validación estrictos?

---

## 3. Enlaces de Referencia Oficiales

- [Kubernetes API Server CLI Options](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Kubernetes Audit Logging Reference](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes Authenticators Documentation](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Dynamic Admission Control Mechanics](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

<details>
<summary><strong>Respuestas y Explicaciones Técnicas Exhaustivas</strong></summary>

### Respuestas del Ejercicio 1

1. **Mecánica de la Vulnerabilidad:**  
   Cuando `--anonymous-auth=true` está habilitado, las solicitudes HTTP no autenticadas no se rechazan en la etapa AuthN. En su lugar, se les asigna la identidad `system:anonymous` y se ubican en el grupo `system:unauthenticated`. Si un administrador crea un `ClusterRoleBinding` que otorga privilegios (ej. `get, list pods` o comodín `*`) a `system:unauthenticated` o `system:authenticated`, cualquier atacante de red no autenticado con acceso al puerto 6443 puede ejecutar llamadas a la API y comprometer el control plane o los datos del cluster.

2. **Mecánica del Protocolo TLS 1.3:**  
   En TLS 1.3 (RFC 8446), la negociación de cipher suites se desacopló de los mecanismos de intercambio de claves de certificado. A diferencia de TLS 1.2, los cipher suites en TLS 1.3 solo definen algoritmos de cifrado simétrico (ej. `TLS_AES_256_GCM_SHA384` o `TLS_CHACHA20_POLY1305_SHA256`). Las librerías estándar `crypto/tls` de Go (que impulsan control planes basados en Go como `kube-apiserver`) gestionan los cipher suites de TLS 1.3 automáticamente. El flag `--tls-cipher-suites` en `kube-apiserver` controla estrictamente los algoritmos de cifrado para TLS 1.2.

---

### Respuestas del Ejercicio 2

1. **Riesgos de Seguridad del Registro `RequestResponse` para Secrets:**  
   Configurar `level: RequestResponse` para `secrets` fuerza al API Server a capturar la carga útil completa sin procesar de la solicitud y el cuerpo de la respuesta de la API en los archivos de log de auditoría almacenados en el disco del host. En Kubernetes, los valores de datos de un Secret son cadenas codificadas en base64 (no cifradas en reposo dentro de las cargas útiles estándar de la API). Los archivos de logs de auditoría almacenados en texto plano en el sistema de archivos host del nodo del control plane (`/var/log/kubernetes/audit.log`) exponen credenciales en texto plano, tokens de API y claves privadas a cualquier proceso u operador del host con acceso de lectura a dicho directorio de logs. El patrón de cumplimiento recomendado es `level: Metadata` para recursos sensibles como Secrets.

2. **Mecánica de Ejecución de Etapas:**  
   Un evento de log de auditoría que lleve `"stage": "ResponseComplete"` indica que la solicitud a la API completó su pipeline de procesamiento completo —incluyendo validación, transformación de esquema y commit exitoso en `etcd` (para solicitudes mutantes)— y que el API Server generó y completó la escritura de la respuesta HTTP de vuelta a la conexión del cliente. El campo `responseStatus.code` (ej. `200`, `201`, `403`, `500`) dentro de ese evento `ResponseComplete` proporciona prueba definitiva del resultado.

---

### Respuestas del Ejercicio 3

1. **Mecánica del Mapeo de Atributos X.509:**  
   Cuando `kube-apiserver` procesa un certificado de cliente validado contra `--client-ca-file`, su módulo de autenticación `x509` analiza el nombre distinguido (DN) del certificado:
   - El **Common Name (`CN`)** se extrae como el **User** autenticado (`req.User = CN`).
   - Todos los campos de **Organization (`O`)** se extraen como los **Groups** del usuario (`req.Groups = [O_1, O_2, ...]`).  
   En el ejemplo del ejercicio (`O = system:masters, CN = kube-apiserver-kubelet-client`), el API Server interpreta la identidad del cliente como el usuario `kube-apiserver-kubelet-client` perteneciente al grupo `system:masters`. Dado que `system:masters` está hardcodeado en el código fuente de Kubernetes para omitir la evaluación de RBAC, esta identidad recibe acceso administrativo irrestricto.

2. **Flujo de Evaluación del Motor de Autorización:**  
   `kube-apiserver` evalúa los modos de autorización de forma secuencial según lo configurado en `--authorization-mode` (ej. `Node,RBAC`).
   - Si **cualquier** autorizador otorga acceso explícitamente (`DecisionAllow`), la evaluación se detiene de inmediato y la solicitud procede al Admission Control.
   - Si un autorizador no coincide o declina (`DecisionNoOpinion`), el API Server pasa la solicitud al siguiente autorizador en línea.
   - Si todos los autorizadores terminan sin otorgar permiso, la solicitud es denegada (`403 Forbidden`).  
   Por lo tanto, si `Node` autoriza la solicitud, se aprueba inmediatamente; el rechazo posterior o la falta de permiso en `RBAC` nunca se evalúan.

---

### Respuestas del Ejercicio 4

1. **Diferencias Operativas de FailurePolicy:**  
   - **`failurePolicy: Fail` (Fail Closed / Fallo Cerrado):** Si el servicio externo del admission webhook experimenta un tiempo de espera de red (timeout), fallo de DNS, error interno de servidor 5xx o un endpoint inalcanzable, el API Server aborta la operación y rechaza la solicitud de API. Esto garantiza una aplicación estricta de la seguridad a expensas de la disponibilidad operativa potencial del cluster si el backend del webhook se cae.
   - **`failurePolicy: Ignore` (Fail Open / Fallo Abierto):** Si el servicio de admission webhook es inalcanzable o arroja un error, el API Server omite la validación y permite que la solicitud proceda a `etcd`. Esto prioriza la disponibilidad de las cargas de trabajo por sobre la aplicación de políticas de seguridad.

2. **Mejor Práctica de Exclusión de Namespaces del Sistema:**  
   Si un webhook de validación configurado con `failurePolicy: Fail` intercepta solicitudes en todos los namespaces (incluido `kube-system`), cualquier falla del servicio del webhook crea un bloqueo por dependencia circular (dead-lock):
   - Los componentes del control plane o pods del sistema base (tales como plugins de DNS, controladores CNI, o el mismo pod del webhook si se está reiniciando) no pueden crearse ni actualizarse debido a que la validación del webhook falla de forma cerrada.
   - Los operadores no pueden desplegar una solución ni reiniciar los pods del sistema porque el API Server rechaza todas las solicitudes de creación de Pods nuevas.  
   Excluir los namespaces de infraestructura (tales como `kube-system`) a través de `namespaceSelector` garantiza que los componentes principales del sistema sigan siendo administrables durante una interrupción de emergencia.

</details>