# Preparación para el examen KCSA: Tema 2.4 - Seguridad y hardening de Kubelet

**Dominio:** Hardening del clúster / Seguridad del nodo  
**Peso en el examen:** ~2.0  
**Audiencia objetivo:** SREs, Ingenieros de seguridad y Arquitectos de plataforma preparándose para la certificación CNCF KCSA.

---

## Documentación de referencia oficial
- [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Hardening Guide - Kubelet Authentication & Authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
- [Kubelet Configuration API (v1beta1)](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Kubernetes Node Authorization and NodeRestriction Admission Plugin](https://kubernetes.io/docs/reference/access-authn-authz/node/)

---

## Visión general técnica y arquitectura central

El **Kubelet** es el agente de nodo principal que se ejecuta en cada nodo worker en un clúster de Kubernetes. Recibe PodSpecs principalmente del `kube-apiserver` y garantiza que los contenedores descritos en esos PodSpecs estén ejecutándose y saludables.

Debido a que el Kubelet expone endpoints de servidor HTTPS (puerto TCP predeterminado `10250`) capaces de realizar acciones de alto privilegio (ejecutar comandos en contenedores, transmitir logs, obtener secrets de pods, exponer métricas de nodos), asegurar el Kubelet es un requisito fundamental de la seguridad del clúster.

```
                         [ API Requests (e.g. exec, logs, metrics) ]
                                            │
                                            ▼
                        ┌───────────────────────────────────────┐
                        │        Kubelet HTTPS Server           │
                        │             (Port 10250)              │
                        └───────────────────┬───────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │       Phase 1: Authentication           │
                       │ ───> Client X.509 Cert (/etc/.../ca.crt) │
                       │ ───> Bearer Token (TokenReview API)     │
                       │ ───> Anonymous (If enabled - DANGER!)   │
                       └────────────────────┬────────────────────┘
                                            │ (Identity Verified)
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │        Phase 2: Authorization           │
                       │ ───> Mode: Webhook                      │
                       │      Delegates to API Server            │
                       │      (SubjectAccessReview API call)     │
                       └────────────────────┬────────────────────┘
                                            │ (Allowed)
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │       CRI / Runtime Execution           │
                       │  (containerd, crictl, systemd cgroups) │
                       └─────────────────────────────────────────┘
```

### Vectores críticos de seguridad en la arquitectura de Kubelet:
1. **Autenticación (`authentication`)**: De manera predeterminada, los Kubelets sin tratar pueden permitir solicitudes anónimas (`--anonymous-auth=true`). Los Kubelets en producción deben exigir validación de certificados de cliente X.509 o autenticación por Webhook de Bearer Token.
2. **Autorización (`authorization`)**: Configurar `authorization.mode` en `AlwaysAllow` permite a cualquier cliente autenticado realizar tareas arbitrarias de gestión del nodo (incluyendo `exec` en pods de `kube-system`). La configuración en producción requiere `mode: Webhook`, el cual delega la evaluación del control de acceso al `kube-apiserver` mediante `SubjectAccessReview`.
3. **Aislamiento de nodos (Autorizador `Node` y plugin de admisión `NodeRestriction`)**: Limita los permisos de la API del Kubelet estrictamente a su nodo asignado, evitando que un credencial comprometido del Kubelet modifique otros nodos worker o acceda a secrets fuera de sus Pods programados.
4. **Puertos legados y suites de cifrado**: Deshabilitar el puerto de solo lectura (`--read-only-port=0`, puerto legado `10255`) y restringir los ciphers de TLS a suites modernas con forward secrecy.

---

## Ejercicios prácticos guiados

### Módulo 1: Hardening de la autenticación de Kubelet (Acceso anónimo y Client CA X.509)

#### Paso 1.1: Sondear el estado actual de la autenticación de Kubelet
Ejecutá una sonda TLS no autenticada contra el endpoint HTTPS del Kubelet del nodo local (puerto `10250`) en `/metrics` y `/pods`.

```bash
curl -sk -X GET https://127.0.0.1:10250/pods
```

**Salida esperada (Kubelet no asegurado / predeterminado):**
```json
{
  "kind": "PodList",
  "apiVersion": "v1",
  "metadata": {},
  "items": [
    {
      "metadata": {
        "name": "coredns-768b85b76f-2v48l",
        "namespace": "kube-system"
      }
    }
  ]
}
```

**Salida esperada (Kubelet asegurado):**
```text
Unauthorized
```

#### Paso 1.2: Auditar y crear un `KubeletConfiguration` endurecido
Creá un manifiesto de configuración de Kubelet para producción `kubelet-config.yaml` utilizando la API `kubelet.config.k8s.io/v1beta1`.

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: "0.0.0.0"
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: "/etc/kubernetes/pki/ca.crt"
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
tlsCertFile: "/var/lib/kubelet/pki/kubelet.crt"
tlsPrivateKeyFile: "/var/lib/kubelet/pki/kubelet.key"
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
cgroupDriver: systemd
protectKernelDefaults: true
```

#### Paso 1.3: Aplicar la configuración y reiniciar el servicio Kubelet
Copiá la configuración a `/var/lib/kubelet/config.yaml`, recargá la configuración de systemd y reiniciá el demonio `kubelet`.

```bash
sudo cp kubelet-config.yaml /var/lib/kubelet/config.yaml
sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager
```

**Salida esperada:**
```text
● kubelet.service - kubelet: The Kubernetes Node Agent
     Active: active (running) since Fri 2026-08-07 19:34:10 UTC; 4s ago
       Docs: https://kubernetes.io/docs/home/
   Main PID: 142091 (kubelet)
      Tasks: 34 (limit: 9472)
     Memory: 42.1M
        CPU: 410ms
     CGroup: /system.slice/kubelet.service
             └─142091 /usr/local/bin/kubelet --config=/var/lib/kubelet/config.yaml
```

#### Paso 1.4: Verificar el rechazo del acceso anónimo
Verificá que las solicitudes no autenticadas fallen con `401 Unauthorized`.

```bash
curl -sk -I -X GET https://127.0.0.1:10250/metrics
```

**Salida esperada:**
```http
HTTP/2 401 
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
date: Fri, 07 Aug 2026 19:34:15 GMT
content-length: 13
```

#### Paso 1.5: Autenticarse utilizando certificados de cliente del API Server
Realizá una consulta autenticada contra el Kubelet usando el certificado de cliente y la clave privada del API server (`apiserver-kubelet-client.crt` y `apiserver-kubelet-client.key`).

```bash
curl -sk --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
         --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
         -X GET https://127.0.0.1:10250/healthz
```

**Salida esperada:**
```text
ok
```

---

### Preguntas de comprensión del Módulo 1

**Pregunta 1.1:** ¿Qué código de respuesta HTTP devuelve el Kubelet cuando `authentication.anonymous.enabled` está configurado en `false` y se realiza una solicitud sin certificados de cliente ni un token Bearer válido?
- A) `403 Forbidden`
- B) `401 Unauthorized`
- C) `400 Bad Request`
- D) `500 Internal Server Error`

**Pregunta 1.2:** Si `authentication.webhook.enabled` está configurado en `true`, ¿cómo verifica el Kubelet un token Bearer HTTP entrante presentado en una solicitud?
- A) Valida el token contra su archivo local `/etc/kubernetes/passwd`.
- B) Envía una solicitud `TokenReview` al `kube-apiserver`.
- C) Desencripta el token utilizando su clave privada TLS local.
- D) Consulta el clúster `etcd` directamente en el puerto 2379.

---

### Módulo 2: Delegar la autorización de Kubelet al `kube-apiserver` (Modo Webhook y RBAC)

#### Paso 2.1: Comprensión arquitectónica de la autorización por Webhook
Cuando `authorization.mode: Webhook` está habilitado en `KubeletConfiguration`, el Kubelet llama al endpoint de la API `SubjectAccessReview` del API Server para determinar si un usuario/cuenta de servicio (ServiceAccount) autenticado tiene permiso para acceder a endpoints específicos del Kubelet (`/exec`, `/logs`, `/metrics`, `/stats`, `/pods`).

Los permisos se mapean directamente a subrecursos en el recurso de API `nodes`:
- `/exec` $\rightarrow$ `nodes/proxy` (Verbo: `create`, `get`)
- `/metrics` $\rightarrow$ `nodes/metrics` (Verbo: `get`)
- `/stats` $\rightarrow$ `nodes/stats` (Verbo: `get`)
- `/logs` $\rightarrow$ `nodes/log` (Verbo: `get`)

#### Paso 2.2: Implementar RBAC de grano fino para agentes de monitoreo
Creá un `ClusterRole` y un `ClusterRoleBinding` de privilegios mínimos otorgando a un ServiceAccount de monitoreo (`prometheus-k8s`) acceso *únicamente* a `/metrics` y `/stats`, excluyendo explícitamente la ejecución de comandos (`nodes/proxy`).

Guardá como `kubelet-monitoring-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-metrics-only-reader
rules:
  - apiGroups: [""]
    resources:
      - nodes/metrics
      - nodes/stats
    verbs:
      - get
      - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-kubelet-metrics-binding
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: kubelet-metrics-only-reader
  apiGroup: rbac.authorization.k8s.io
```

Aplicá el manifiesto de RBAC:

```bash
kubectl apply -f kubelet-monitoring-rbac.yaml
```

**Salida esperada:**
```text
serviceaccount/prometheus-k8s created
clusterrole.rbac.authorization.k8s.io/kubelet-metrics-only-reader created
clusterrolebinding.rbac.authorization.k8s.io/prometheus-kubelet-metrics-binding created
```

#### Paso 2.3: Probar los límites de autorización usando `kubectl auth can-i`
Verificá que el ServiceAccount `prometheus-k8s` pueda acceder a las métricas del nodo, pero no pueda ejecutar comandos dentro de entornos de contenedores.

```bash
# Check metrics access (Should be YES)
kubectl auth can-i get nodes/metrics --as=system:serviceaccount:monitoring:prometheus-k8s

# Check container exec access (Should be NO)
kubectl auth can-i create nodes/proxy --as=system:serviceaccount:monitoring:prometheus-k8s
```

**Salida esperada:**
```text
yes
no
```

#### Paso 2.4: Probar la autorización real de Webhook con token de ServiceAccount
Extraé el token Bearer para `prometheus-k8s` y consultá la API del Kubelet directamente.

```bash
# Obtain token for the ServiceAccount
TOKEN=$(kubectl create token prometheus-k8s -n monitoring --duration=1h)

# Query Kubelet metrics endpoint with Bearer Token (Should succeed 200 OK)
curl -sk -H "Authorization: Bearer ${TOKEN}" -X GET https://127.0.0.1:10250/metrics | head -n 5
```

**Salida esperada:**
```text
# HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 1.2541e-05
go_gc_duration_seconds{quantile="0.25"} 2.4510e-05
go_gc_duration_seconds{quantile="0.5"} 3.6120e-05
```

Consultá el endpoint `/exec` con el mismo token:

```bash
curl -sk -H "Authorization: Bearer ${TOKEN}" -X POST https://127.0.0.1:10250/exec/default/my-pod/my-container?command=date
```

**Salida esperada:**
```text
Forbidden (user=system:serviceaccount:monitoring:prometheus-k8s, verb=get, resource=nodes, subresource=proxy)
```

---

### Preguntas de comprensión del Módulo 2

**Pregunta 2.1:** ¿Por qué otorgar acceso a `nodes/proxy` a agentes de monitoreo o de registro (logging) de terceros se considera un riesgo grave de seguridad en entornos de Kubernetes en producción?
- A) `nodes/proxy` permite que el agente apague el sistema operativo host.
- B) `nodes/proxy` otorga privilegios completos de ejecución dentro de cualquier contenedor que se ejecute en ese nodo a través de la API exec del Kubelet.
- C) `nodes/proxy` expone las claves de cifrado de la base de datos etcd principal.
- D) `nodes/proxy` elude el cifrado de intercambio de claves TLS en el puerto TCP 10250.

**Pregunta 2.2:** Cuando el Kubelet recibe una solicitud mientras `authorization.mode: Webhook` está configurado, ¿qué objeto de la API transmite el Kubelet al `kube-apiserver` para verificar los permisos del usuario?
- A) `TokenReview`
- B) `SubjectAccessReview`
- C) `CertificateSigningRequest`
- D) `SelfSubjectRulesReview`

---

### Módulo 3: Aplicar el aislamiento del alcance del nodo (Autorizador Node y plugin de admisión NodeRestriction)

#### Paso 3.1: Mecánica de la autorización de nodos y NodeRestriction
El **Autorizador Node** es un plugin de autorización dedicado que autoriza las solicitudes realizadas por los Kubelets. Para ser reconocidos por el Autorizador Node, los certificados de cliente del Kubelet deben presentar:
- **Organización (`O`)**: `system:nodes`
- **Nombre común (`CN`)**: `system:node:<nodeName>`

El plugin de admisión **`NodeRestriction`** intercepta las solicitudes de API originadas por los Kubelets y limita su alcance de mutación:
1. Un Kubelet solo puede modificar el estado de su propio objeto `Node`.
2. Un Kubelet no puede agregar/modificar etiquetas de nodo que coincidan con `node-restriction.kubernetes.io/*`.
3. Un Kubelet solo puede modificar objetos `Pod` vinculados a su propio nodo.
4. Un Kubelet no puede crear ni eliminar su propio objeto `Node`.

```
       [ Kubelet Certificate ]
        CN: system:node:worker-01
        O:  system:nodes
               │
               ▼
       ┌──────────────────────────────────────────────────────────┐
       │                 kube-apiserver Pipeline                  │
       ├─────────────────────────┬────────────────────────────────┤
       │ 1. Node Authorizer      │ Checks if request touches pods │
       │                         │ / secrets bound to worker-01   │
       ├─────────────────────────┼────────────────────────────────┤
       │ 2. NodeRestriction      │ Blocks cross-node mutations &  │
       │    Admission Plugin     │ forbidden label updates        │
       └─────────────────────────┴────────────────────────────────┘
```

#### Paso 3.2: Inspeccionar los controladores de admisión del API Server
Verificá que `NodeRestriction` esté habilitado en el manifiesto de pod estático del `kube-apiserver` (`/etc/kubernetes/manifests/kube-apiserver.yaml`).

```bash
grep -E "--enable-admission-plugins" /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Salida esperada:**
```yaml
    - --enable-admission-plugins=NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
```

#### Paso 3.3: Inspeccionar el certificado de identidad X.509 del Kubelet
Inspeccioná el certificado X.509 utilizado por el Kubelet para autenticarse ante el `kube-apiserver`.

```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -text -noout | grep -E "Subject:"
```

**Salida esperada:**
```text
        Subject: O = system:nodes, CN = system:node:worker-01
```

#### Paso 3.4: Probar la aplicación de NodeRestriction (Simulando mutación de un Kubelet comprometido)
Simulá el intento de un Kubelet comprometido de modificar etiquetas en otro nodo (`worker-02`) o aplicar etiquetas restringidas sobre sí mismo utilizando las credenciales del certificado de cliente del Kubelet.

Creá un archivo de solicitud de parche raw `node-patch.json`:
```json
{
  "metadata": {
    "labels": {
      "node-restriction.kubernetes.io/compromised": "true"
    }
  }
}
```

Ejecutá la solicitud de parche al `kube-apiserver` utilizando las credenciales del certificado de cliente del Kubelet:

```bash
curl -sk --cert /var/lib/kubelet/pki/kubelet-client-current.pem \
         --key /var/lib/kubelet/pki/kubelet-client-current.pem \
         -X PATCH \
         -H "Content-Type: application/strategic-merge-patch+json" \
         --data @node-patch.json \
         https://127.0.0.1:6443/api/v1/nodes/worker-01
```

**Salida esperada:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "nodes \"worker-01\" is forbidden: is restricted from modifying labels with prefix node-restriction.kubernetes.io/",
  "reason": "Forbidden",
  "details": {
    "name": "worker-01",
    "kind": "nodes"
  },
  "code": 403
}
```

---

### Preguntas de comprensión del Módulo 3

**Pregunta 3.1:** ¿Qué atributos exactos de Subject X.509 se requieren en un certificado de cliente del Kubelet para que el Autorizador Node lo identifique correctamente como un agente de nodo válido?
- A) `O = system:kubelet`, `CN = node:<nodeName>`
- B) `O = system:nodes`, `CN = system:node:<nodeName>`
- C) `O = kubernetes:nodes`, `CN = kubelet:<nodeName>`
- D) `O = system:masters`, `CN = system:node-agent`

**Pregunta 3.2:** ¿Cuál de las siguientes operaciones sería **rechazada** por el controlador de admisión `NodeRestriction` si fuera ejecutada por el Kubelet `worker-01`?
- A) Actualizar el estado de un Pod programado en `worker-01`.
- B) Reportar actualizaciones de estado (por ejemplo, DiskPressure) para `worker-01`.
- C) Obtener un Secret montado por un Pod programado en `worker-01`.
- D) Modificar anotaciones o etiquetas en el nodo `worker-02`.

---

### Módulo 4: Deshabilitar puertos legados, hardening de ciphers y diagnóstico de sockets CRI

#### Paso 4.1: Auditar puertos de sistema abiertos para detectar el puerto legado de solo lectura
El puerto legado de solo lectura (`10255`) históricamente proporcionaba acceso no autenticado a pod specs, métricas y datos de salud. En entornos de producción, `readOnlyPort` debe configurarse en `0`.

Auditá los sockets de escucha abiertos en el sistema operativo host:

```bash
ss -tulpn | grep -E "10255|10250"
```

**Salida esperada (Seguro):**
```text
tcp   LISTEN 0      4096       *:10250            *:*    users:(("kubelet",pid=142091,fd=31))
```
*(Notá que el puerto TCP `10255` está ausente de la tabla de sockets de escucha).*

Si el puerto `10255` aparece, asegurate de que `readOnlyPort: 0` esté definido en `/var/lib/kubelet/config.yaml`.

#### Paso 4.2: Inspeccionar la seguridad del socket de la interfaz del runtime de contenedores (CRI)
El Kubelet se comunica localmente con el runtime del contenedor (por ejemplo, `containerd`) sobre un socket de dominio Unix (típicamente `/run/containerd/containerd.sock`). El acceso a este socket otorga control equivalente a root sobre todos los contenedores en el host.

Auditá la propiedad y los permisos del socket de dominio CRI:

```bash
ls -la /run/containerd/containerd.sock
```

**Salida esperada:**
```text
srw-rw---- 1 root root 0 Aug  7 18:00 /run/containerd/containerd.sock
```

> [!CAUTION]
> Si usuarios que no son root o contenedores sin privilegios montan `/run/containerd/containerd.sock`, pueden eludir todos los controles de seguridad de Kubernetes (PodSecurityStandards, RBAC, NetworkPolicies) y obtener un escape completo del contenedor hacia el sistema host.

#### Paso 4.3: Realizar diagnósticos a nivel de CRI con `crictl`
Usá `crictl` para interactuar directamente con el socket CRI para depuración del nodo a bajo nivel.

```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info | grep -A 10 "containerd"
```

**Salida esperada:**
```json
    "containerd": {
      "version": "1.7.13",
      "revision": "7cbf65a396706173223f9583a2d591a27e0b9040",
      "dynamicPlugins": {},
      "pendingPlugins": null
    }
```

Verificá los pods en ejecución directamente en la capa del runtime:

```bash
sudo crictl pods --limit 3
```

**Salida esperada:**
```text
POD ID              CREATED             STATE               NAME                        NAMESPACE           ATTEMPT             DEFAULT
a1b2c3d4e5f6        2 hours ago         Ready               coredns-768b85b76f-2v48l    kube-system         0                   (default)
f6e5d4c3b2a1        2 hours ago         Ready               kube-proxy-8j9xz            kube-system         0                   (default)
```

---

### Preguntas de comprensión del Módulo 4

**Pregunta 4.1:** ¿Cuál es el impacto en la seguridad de configurar `readOnlyPort: 0` en `KubeletConfiguration`?
- A) Deshabilita el cifrado HTTPS en el puerto 10250.
- B) Cierra el puerto HTTP TCP legado 10255, eliminando el acceso no autenticado a la información de los pods y métricas del nodo.
- C) Evita que el Kubelet lea `/etc/kubernetes/pki/ca.crt`.
- D) Coloca al Kubelet en modo de solo lectura, bloqueando la creación de pods en el nodo.

**Pregunta 4.2:** ¿Por qué debe restringirse el montaje de sockets de dominio Unix del host como `/run/containerd/containerd.sock` dentro de Pods no administrativos a través de Pod Security Standards (perfil `Restricted`)?
- A) Aumenta el consumo de CPU en el ciclo (loop) del Kubelet.
- B) Permite que los contenedores interactúen directamente con el motor del runtime, lo que permite la toma de control completa del host y la evasión de los controles de seguridad.
- C) Provoca tiempos de espera agotados (timeouts) en la ejecución del binario `crictl`.
- D) Fuerza al Kubelet a recurrir al driver de cgroups v1.

---

## Soluciones de ejercicios y explicaciones técnicas

<details>
<summary>Hacé clic para desplegar las respuestas y las explicaciones técnicas completas...</summary>

### Respuestas del Módulo 1

**Pregunta 1.1: Respuesta correcta: B (`401 Unauthorized`)**
- **Explicación:** Cuando `authentication.anonymous.enabled` se configura en `false`, cualquier solicitud entrante que carezca de credenciales (certificados de cliente X.509 o tokens Bearer) falla en la fase de autenticación. Kubelet devuelve HTTP `401 Unauthorized`. HTTP `403 Forbidden` ocurre durante la fase de autorización (es decir, cuando la autenticación tiene éxito pero el sujeto carece de permisos de RBAC).

**Pregunta 1.2: Respuesta correcta: B (Envía una solicitud `TokenReview` al `kube-apiserver`)**
- **Explicación:** Cuando se configura `authentication.webhook.enabled: true`, Kubelet delega la verificación del token Bearer al API server. Emite un HTTP POST que contiene un objeto `TokenReview` de `authentication.k8s.io/v1` hacia el `kube-apiserver`. El API server valida la firma/expiración del token y devuelve la identidad del usuario (`username`, `groups`, `uid`) de vuelta al Kubelet.

---

### Respuestas del Módulo 2

**Pregunta 2.1: Respuesta correcta: B (`nodes/proxy` otorga privilegios completos de ejecución dentro de cualquier contenedor que se ejecute en ese nodo)**
- **Explicación:** El subrecurso `nodes/proxy` se mapea a los endpoints del Kubelet `/exec`, `/attach`, `/portForward` y `/run`. Otorgar permiso `nodes/proxy` a una identidad le permite abrir una shell interactiva (`kubectl exec`) dentro de *cualquier* pod que se ejecute en el nodo objetivo, incluidos los pods de sistema privilegiados (`kube-system`). A los agentes de monitoreo solo se les debe otorgar `nodes/metrics` y `nodes/stats`.

**Pregunta 2.2: Respuesta correcta: B (`SubjectAccessReview`)**
- **Explicación:** En `authorization.mode: Webhook`, una vez que el Kubelet autentica al emisor, transmite una especificación `SubjectAccessReview` de `authorization.k8s.io/v1` al `kube-apiserver`. La especificación detalla la identidad del usuario, el verbo solicitado (`get`, `create`), el recurso (`nodes`) y el subrecurso (`proxy`, `metrics`). El API server evalúa las reglas de RBAC y devuelve `allowed: true` o `allowed: false`.

---

### Respuestas del Módulo 3

**Pregunta 3.1: Respuesta correcta: B (`O = system:nodes`, `CN = system:node:<nodeName>`)**
- **Explicación:** El Autorizador Node comprueba explícitamente los campos de Subject del certificado X.509. La Organización DEBE ser `system:nodes` y el Nombre Común DEBE seguir estrictamente el formato `system:node:<nodeName>`. Si estas cadenas exactas no están presentes, la solicitud no se reconoce como proveniente de un agente de nodo válido y las reglas del Autorizador Node se omiten o se rechazan.

**Pregunta 3.2: Respuesta correcta: D (Modificar anotaciones o etiquetas en el nodo `worker-02`)**
- **Explicación:** El controlador de admisión `NodeRestriction` restringe al Kubelet a operar exclusivamente sobre los recursos de su propio nodo. A `worker-01` se le prohíbe estrictamente leer/modificar objetos de nodo, pods o estados pertenecientes a `worker-02`. Además, `NodeRestriction` bloquea que el Kubelet agregue etiquetas con el prefijo `node-restriction.kubernetes.io/` incluso en su propio objeto de nodo.

---

### Respuestas del Módulo 4

**Pregunta 4.1: Respuesta correcta: B (Cierra el puerto HTTP TCP legado 10255, eliminando el acceso no autenticado...)**
- **Explicación:** Históricamente, Kubelet servía métricas y datos de salud no cifrados ni autenticados sobre el puerto TCP 10255. Configurar `readOnlyPort: 0` deshabilita este oyente por completo, forzando a todos los clientes a conectarse a través del puerto HTTPS 10250 donde se aplican los pipelines de autenticación y autorización.

**Pregunta 4.2: Respuesta correcta: B (Permite que los contenedores interactúen directamente con el motor del runtime...)**
- **Explicación:** El socket CRI (`/run/containerd/containerd.sock`) es la interfaz de gestión a bajo nivel para containerd. Cualquiera con acceso de escritura a este socket puede emitir llamadas de API para iniciar contenedores privilegiados, montar sistemas de archivos raíz del host (`/`), inspeccionar namespaces de red del host o finalizar procesos arbitrarios del host. El acceso al socket otorga efectivamente privilegios de root en el host del nodo.

</details>