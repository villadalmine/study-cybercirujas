# Guía de Estudio KCSA: Tema 2.4 - Seguridad y Arquitectura de Kubelet

## 1. Motivación Arquitectónica de Producción y Planteamiento del Problema

El `kubelet` es el agente principal a nivel de nodo que se ejecuta en cada nodo worker y de control plane dentro de un cluster de Kubernetes. Actúa como el puente entre el Control Plane centralizado de Kubernetes (`kube-apiserver`) y el container runtime subyacente (a través de la Container Runtime Interface, CRI). 

Desde la perspectiva de la Arquitectura de Plataforma y SRE, el `kubelet` representa una de las superficies de ataque más críticas en un entorno de Kubernetes:
1. **Control Directo de Ejecución de Cargas de Trabajo**: El `kubelet` expone endpoints HTTP (por defecto en el puerto `10250`) que permiten la creación de pods, ejecución de comandos (`exec`), transmisión de logs (`logs`), redirección de puertos (`portforward`) y depuración de contenedores.
2. **Exposición de Credenciales y Secretos**: El `kubelet` gestiona credenciales vinculadas al nodo (como certificados de cliente y tokens) y obtiene `Secrets`, `ConfigMaps` y credenciales de volumen requeridas por los pods programados.
3. **Vector de Escalada de Privilegios**: Una autenticación o autorización mal configurada en el `kubelet` permite que atacantes en la red sin autenticar o cargas de trabajo comprometidas invoquen la API de Kubelet directamente, omitiendo los controles RBAC de `kube-apiserver` y logrando la ejecución remota de código (RCE) como `root` dentro de contenedores o en el nodo host.

```
                   [ Attacker / Compromised Pod ]
                                 |
                                 | (Direct HTTP call to :10250)
                                 v
   +-------------------------------------------------------------+
   | Node Host                                                   |
   |                                                             |
   |   [ Kubelet HTTP API Server (Port 10250) ]                  |
   |     |                                                       |
   |     +-- Authentication Check  (--anonymous-auth=false)      |
   |     |                                                       |
   |     +-- Authorization Check   (--authorization-mode=Webhook)|
   |     |                                                       |
   |     v                                                       |
   |   [ CRI Shim / Runtime (containerd / crio) ]                |
   |     |                                                       |
   |     v                                                       |
   |   [ Host Kernel & Container Namespaces ]                    |
   +-------------------------------------------------------------+
```

### Principales Amenazas de Seguridad Abordadas en el Dominio 2.4 de KCSA
- **Acceso No Autenticado a la API de Kubelet**: Configuraciones predeterminadas o inseguras que permiten el acceso anónimo al puerto `10250` o habilitan el puerto heredado de solo lectura `10255`.
- **Omitir la Autorización del API Server**: Acceso directo a `10250/exec/` permitiendo a los atacantes ejecutar comandos dentro de los pods sin generar logs de auditoría en `kube-apiserver`.
- **Suplantación de Nodos y Recolección de Secretos**: Nodos que solicitan credenciales fuera de su alcance de autorización si el plugin de admisión `NodeRestriction` y el autorizador `Node` están deshabilitados.
- **Cifrados TLS Débiles y Certificados Expirados**: Vulnerabilidad a ataques de Man-In-The-Middle (MITM) durante el tráfico del control-plane al kubelet.

---

## 2. Comparaciones Técnicas y Matriz de Compromisos (Trade-offs)

### Tabla 2.4a: Modos de Autenticación de Kubelet

| Modo de Autenticación | Configuración (`KubeletConfiguration`) | Postura de Seguridad | Impacto en el Rendimiento | Complejidad Operativa | Caso de Uso / Recomendación de Producción |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Anónimo** | `authentication.anonymous.enabled: true` | **RIESGO CRÍTICO**. Cualquiera con acceso de red al puerto 10250 puede ejecutar comandos como root en contenedores. | Sobrecarga cero (sin validación). | Baja | **NUNCA** en producción. Debe ser deshabilitado. |
| **Certificados de Cliente x509** | `authentication.x509.clientCAFile: /etc/kubernetes/pki/ca.crt` | **ALTA**. Valida los certificados TLS del cliente contra una CA de confianza. | Bajo (solo costo de CPU del handshake TLS). | Media (Requiere distribución de la CA). | **REQUERIDO**. Valida los certificados de cliente de `kube-apiserver` cuando se conecta a Kubelet. |
| **Token Bearer / Webhook** | `authentication.webhook.enabled: true` | **ALTA**. Valida los tokens bearer contra `kube-apiserver` a través de la API `TokenReview`. | Bajo-Medio (Mitigado por almacenamiento en caché TTL). | Media (Requiere conectividad con `kube-apiserver`). | **RECOMENDADO**. Se utiliza junto con x509 para la autenticación del API server basada en tokens. |

### Tabla 2.4b: Modos de Autorización de Kubelet

| Modo de Autorización | Configuración (`KubeletConfiguration`) | Mecánica de Seguridad | Perfil de Riesgo | Idoneidad en Producción |
| :--- | :--- | :--- | :--- | :--- |
| **AlwaysAllow** | `authorization.mode: AlwaysAllow` | Otorga acceso total a cualquier usuario/cliente autenticado, independientemente de las reglas de RBAC. | **ALTO**. Usuarios autenticados con bajos privilegios pueden ejecutar `exec` o `attach`. | **NO APTO** para producción. |
| **Webhook** | `authorization.mode: Webhook` | Llama a la API `SubjectAccessReview` de `kube-apiserver` para verificar si la identidad tiene permisos sobre `nodes/proxy`, `nodes/log`, `nodes/exec`, etc. | **SEGURO**. Aplica la política global de RBAC en todos los endpoints de Kubelet. | **OBLIGATORIO** para el cumplimiento del CIS Benchmark. |

### Tabla 2.4c: Compromisos (Trade-offs) de Endurecimiento de Red y Recursos de Kubelet

| Característica de Endurecimiento | Estado Inseguro / Legado | Estado Endurecido de Producción | Compromisos Operativos / Consideraciones |
| :--- | :--- | :--- | :--- |
| **Puerto de Solo Lectura** | `readOnlyPort: 10255` | `readOnlyPort: 0` | Deshabilitar el puerto 10255 previene la fuga de métricas de especificaciones de pods no autenticadas. Los agentes de monitoreo de terceros deben actualizarse para usar el puerto autenticado 10250 o el endpoint de métricas cAdvisor con tokens bearer. |
| **Proteger Ajustes por Defecto del Kernel** | `protectKernelDefaults: false` | `protectKernelDefaults: true` | Kubelet fallará al iniciar si los sysctls del kernel (por ejemplo, `vm.overcommit_memory`) no coinciden con los valores por defecto requeridos por Kubernetes. Previene fallos silenciosos en tiempo de ejecución debido a parámetros mal configurados en el SO host. |
| **Rotación TLS del Servidor** | Certificados TLS estáticos | `serverTLSBootstrap: true` | Kubelet solicita automáticamente certificados de servidor a través de la API CSR (`certificates.k8s.io`). Requiere un controlador de aprobación automatizada de CSR (por ejemplo, reglas de auto-aprobación en `kube-controller-manager`). |

---

## 3. Manifiestos de Grado de Producción y Configuraciones de Infraestructura

### 3.1 Archivo de Configuración de Kubelet Endurecido (`/var/lib/kubelet/config.yaml`)

Este manifiesto cumple con `kubelet.config.k8s.io/v1beta1` e implementa recomendaciones estrictas del CIS Kubernetes Benchmark.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
healthzPort: 10248
healthzBindAddress: 127.0.0.1
cgroupDriver: systemd
hairpinMode: hairpin-veth
protectKernelDefaults: true
serializeImagePulls: false

# Authentication Configuration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt

# Authorization Configuration
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

# TLS Hardening
tlsCertFile: /var/lib/kubelet/pki/kubelet-server.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet-server.key
tlsMinVersion: VersionTLS12
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256

# Certificate Rotation
rotateCertificates: true
serverTLSBootstrap: true

# Resource Reservation & Management
kubeReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 1Gi
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%

# Event & Logging Rate Limiting
eventRecordQPS: 5
eventBurst: 10
containerLogMaxSize: 10Mi
containerLogMaxFiles: 5
```

### 3.2 Archivo de Unidad de Servicio Systemd de Producción (`/etc/systemd/system/kubelet.service`)

```ini
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --config=/var/lib/kubelet/config.yaml \
  --container-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --kubeconfig=/etc/kubernetes/kubelet.conf \
  --node-ip=192.168.1.50 \
  --v=2
Restart=always
RestartSec=10s
StartLimitInterval=0
KillMode=process
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
```

### 3.3 RBAC del Control Plane para Acceso a la API de Kubelet

Para permitir que `kube-apiserver` (o servicios de monitoreo) obtengan métricas y ejecuten comandos a través de la API de Kubelet, se debe definir un RBAC explícito.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kubelet-api-admin
rules:
- apiGroups: [""]
  resources:
  - nodes/proxy
  - nodes/stats
  - nodes/log
  - nodes/spec
  - nodes/metrics
  verbs:
  - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-api
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
- kind: User
  name: kube-apiserver
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Comandos CLI de Terminal Real y Salidas Esperadas

### 4.1 Verificación de que el Acceso Anónimo está Bloqueado en el Puerto 10250

Intentar una solicitud HTTP no autenticada directamente al puerto de la API de Kubelet debe dar como resultado una respuesta `HTTP 401 Unauthorized`.

```bash
$ curl -k -i https://127.0.0.1:10250/metrics
```
```http
HTTP/2 401 
audit-id: 204d13fa-2384-4e2b-b9d9-952467d028cf
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
content-length: 13

Unauthorized
```

### 4.2 Verificación de que el Puerto de Solo Lectura 10255 está Completamente Deshabilitado

```bash
$ curl -i http://127.0.0.1:10255/pods
```
```text
curl: (7) Failed to connect to 127.0.0.1 port 10255 after 0 ms: Connection refused
```

### 4.3 Autenticación contra la API de Kubelet Utilizando Certificados de Cliente

Uso del certificado de cliente del API server para interactuar de forma segura con el endpoint `/runningpods/` de Kubelet:

```bash
$ curl --cacert /etc/kubernetes/pki/ca.crt \
       --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
       --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
       -s https://127.0.0.1:10250/runningpods/ | jq '.items[0].metadata'
```
```json
{
  "name": "coredns-768b85b76f-4x2lm",
  "namespace": "kube-system",
  "uid": "a1c2b3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
}
```

### 4.4 Inspección de la Configuración Activa de Kubelet en Tiempo de Ejecución

```bash
$ kubectl get --raw "/api/v1/nodes/node-01/proxy/configz" | jq '.kubeletconfig.authentication'
```
```json
{
  "anonymous": {
    "enabled": false
  },
  "webhook": {
    "cacheTTL": "2m0s",
    "enabled": true
  },
  "x509": {
    "clientCAFile": "/etc/kubernetes/pki/ca.crt"
  }
}
```

### 4.5 Prueba de Suites de Cifrado TLS Aprobadas con OpenSSL

```bash
$ openssl s_client -connect 127.0.0.1:10250 -tls1_3 2>&1 | grep "Protocol"
```
```text
Protocol  : TLSv1.3
```

---

## 5. Verificación y Guía de Diagnóstico / Resolución de Problemas (Troubleshooting)

### Diagrama de Flujo: Espectro de Fallos de Autenticación y Autorización de Kubelet

```
                [ Client Connection Request to Port 10250 ]
                                     |
                         Is TLS Handshake Valid?
                                /         \
                              NO           YES
                             /               \
              [ TLS Handshake Error ]     Is Client Authenticated?
               (Check Client CA File)        (x509 / Webhook Token)
                                             /                  \
                                           NO                    YES
                                          /                        \
                            [ 401 Unauthorized ]            Is Client Authorized?
                             (Check --anonymous-auth)       (Webhook SubjectAccessReview)
                                                            /                  \
                                                          NO                    YES
                                                         /                        \
                                          [ 403 Forbidden ]                 [ 200 OK ]
                                        (Check RBAC ClusterRole)
```

### Escenario 1: `kubectl exec` / `kubectl logs` falla con `401 Unauthorized` o `403 Forbidden`

**Síntoma**:
```bash
$ kubectl exec -it coredns-768b85b76f-4x2lm -n kube-system -- sh
Error from server (Forbidden): error execing into pod: open //node-01:10250/exec/kube-system/coredns-768b85b76f-4x2lm/coredns: 403 Forbidden
```

**Pasos de Diagnóstico**:
1. Inspeccionar los logs de `kube-apiserver` para verificar si las credenciales de autenticación de Kubelet son las estándar:
   ```bash
   $ journalctl -u kubelet | grep -E "Unable to authenticate|Forbidden"
   ```
2. Verificar que `kube-apiserver` tenga configuradas las flags requeridas para autenticarse ante el Kubelet:
   - `--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt`
   - `--kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key`
   - `--kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt`
3. Verificar el CN/OU del subject del certificado de cliente de Kubelet del API server:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout | grep -E "Subject:|Issuer:"
   ```
   *Salida Esperada*:
   ```text
   Issuer: CN = kubernetes
   Subject: O = system:masters, CN = kube-apiserver-kubelet-client
   ```
4. Si Kubelet utiliza `authorization.mode: Webhook`, asegurarse de que el grupo `system:masters` o el usuario `kube-apiserver-kubelet-client` tenga un `ClusterRoleBinding` para `system:kubelet-api-admin`.

---

### Escenario 2: Kubelet Falla al Iniciar debido a los Valores por Defecto del Kernel (`protectKernelDefaults: true`)

**Síntoma**:
`systemctl status kubelet` reporta estado `failed` con estado de salida de bucle de reinicio por fallo (crash loop).

**Extracción de Log de Diagnóstico**:
```bash
$ journalctl -u kubelet -n 20 --no-pager | grep -i "kernel"
```
*Salida*:
```text
fatal error: failed to start Kubelet: invalid configuration: vm.overcommit_memory sysctl mismatch: expected 1, got 0
```

**Remediación**:
Actualizar `/etc/sysctl.d/99-kubernetes.conf` con los ajustables de kernel requeridos y recargar:

```bash
$ cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes.conf
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

$ sudo sysctl --system
$ sudo systemctl restart kubelet
```

---

### Escenario 3: Auto-rotación de Certificados de Kubelet Pendiente de Aprobación

**Síntoma**:
El certificado del servidor Kubelet expira, lo que provoca errores de `x509: certificate expired or not yet valid` cuando `kube-apiserver` se conecta al puerto `10250`.

**Pasos de Diagnóstico**:
1. Listar las Certificate Signing Requests (CSRs) pendientes en el cluster:
   ```bash
   $ kubectl get csr | grep -i pending
   ```
   *Salida*:
   ```text
   csr-9z8x7   2m   kubernetes.io/kubelet-serving   system:node:node-01   Pending
   ```
2. Inspeccionar los detalles de la CSR pendiente:
   ```bash
   $ kubectl describe csr csr-9z8x7
   ```
3. Aprobar manualmente la CSR del servidor si la auto-aprobación no está habilitada en `kube-controller-manager`:
   ```bash
   $ kubectl certificate approve csr-9z8x7
   ```

---

## 6. Referencias

- **CNCF KCSA Exam Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Documentation - Kubelet Security Configuration**: [https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- **Kubernetes Documentation - Controlling Kubelet Authentication/Authorization**: [https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
- **Kubernetes Documentation - TLS Bootstrap and Certificate Rotation**: [https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- **CIS Kubernetes Benchmark**: [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)