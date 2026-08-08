# Guía de estudio KCSA: Sección 2.2 — Seguridad y hardening de Controller Manager

---

## 1. Motivación y problema de arquitectura en producción

### Arquitectura de bucles de control y panorama de vectores de amenaza
El Control Plane de Kubernetes se basa en el modelo de reconciliación declarativo. El demonio `kube-controller-manager` actúa como un binario monolítico que encapsula docenas de bucles de control (control loops) asíncronos y distintos (tales como `NodeController`, `ServiceAccountController`, `JobController`, `EndpointSliceController` y `GarbageCollector`). Cada controlador observa continuamente el API server para obtener el estado actual de los recursos del cluster y lleva al cluster hacia el estado deseado definido en los manifiestos.

```
+-----------------------------------------------------------------------------------------+
|                                  kube-controller-manager                                |
|                                                                                         |
|  +-------------------+  +------------------------+  +--------------------------------+  |
|  |   NodeController  |  | ServiceAccountController| | PersistentVolumeBinderController| |
|  +---------+---------+  +-----------+------------+  +---------------+----------------+  |
|            |                        |                           |                       |
|            +------------------------+---------------------------+                       |
|                                     |                                                   |
|                        Shared Informers & WorkQueues                                    |
|                                     |                                                   |
+-------------------------------------+---------------------------------------------------+
                                      |
                      gRPC / mTLS (Port 6443 / HTTPS)
                                      |
                                      v
+-----------------------------------------------------------------------------------------+
|                                   kube-apiserver                                        |
|  +---------------------+   +--------------------------+   +--------------------------+  |
|  | Authentication     |   | RBAC Authorization       |   | Admission Controllers    |  |
|  +---------------------+   +--------------------------+   +--------------------------+  |
+-----------------------------------------------------------------------------------------+
```

Desde una perspectiva de seguridad, `kube-controller-manager` representa una de las superficies de amenaza más críticas en el control plane de Kubernetes:

1. **Escalación de privilegios a través de identidad compartida**: Históricamente, todos los bucles de control internos en `kube-controller-manager` se autenticaban ante `kube-apiserver` utilizando un único certificado de cliente X.509 monolítico vinculado al usuario `system:kube-controller-manager`. Si se explotaba una vulnerabilidad en un bucle de control de baja confianza (por ejemplo, el manejo de CRD personalizados o la recolección de basura de Pods) mediante modificación arbitraria de memoria o inyección de prompts/datos en anotaciones de recursos, el atacante obtenía permisos completos equivalentes a `cluster-admin` en todos los grupos de API.
2. **Generación de Secrets y exposición de claves de firma**: El `ServiceAccountController` y el `TokenController` dentro de `kube-controller-manager` requieren acceso a la clave privada RSA/ECDSA (`--service-account-private-key-file`) utilizada para firmar tokens legacy de ServiceAccount. El compromiso del sistema de archivos del proceso permite a un atacante robar esta clave y falsificar tokens JWT válidos para cualquier ServiceAccount, otorgando persistencia a nivel de todo el cluster.
3. **Denegación de servicio (DoS) del Control Plane**: Las cargas de trabajo maliciosas o mal configuradas que crean millones de objetos de vida corta (por ejemplo, Jobs completados, endpoints colgantes) pueden desencadenar bucles de reconciliación ilimitados en `kube-controller-manager`, consumiendo CPU/memoria del nodo y privando de recursos a controladores de infraestructura críticos (por ejemplo, la expulsión por ciclo de vida del nodo).
4. **HTTP no cifrado / Endpoints de métricas no autenticados**: Ejecutar `kube-controller-manager` con el flag legacy `--port=10252` abre un puerto HTTP no autenticado que expone métricas internas de tiempo de ejecución, volcados de depuración pprof y pilas de hilos a la capa de red del nodo.

### Arquitectura de remediación de seguridad
Para cumplir con los requisitos de hardening de KCSA de CNCF y las recomendaciones de CIS Kubernetes Benchmark, `kube-controller-manager` debe configurarse con:
- **Aislamiento de RBAC de grano fino**: Habilitar `--use-service-account-credentials=true` fuerza a cada bucle de controlador interno a autenticarse ante `kube-apiserver` utilizando su propio token de ServiceAccount dedicado (ubicado en `system:serviceaccount:kube-system:pvc-protection-controller`, `node-controller`, etc.), minimizando el radio de impacto (blast radius) de la explotación de un solo controlador.
- **Autenticación y autorización delegada**: Solicitar autenticación mediante `--authentication-kubeconfig` y `--authorization-kubeconfig` obliga a que las consultas HTTPS entrantes (metrics, healthz) se verifiquen contra las reglas de RBAC de `kube-apiserver`.
- **Límites criptográficos strictly definidos**: Restringir los puertos no seguros (`--secure-port=10257`, `--bind-address=127.0.0.1`), hacer cumplir TLS 1.3 y proteger las claves privadas de firma a través de permisos de archivo de SO estrictos (`0400`).

---

## 2. Comparaciones técnicas y tablas de balance (Trade-offs)

### 2.1 Credenciales monolíticas vs. credenciales individuales de ServiceAccount

| Métrica / Dimensión | Monolítica (`--use-service-account-credentials=false`) | SA por controlador (`--use-service-account-credentials=true`) |
| :--- | :--- | :--- |
| **Identidad de autenticación** | Certificado X.509 único (`system:kube-controller-manager`) | JWTs de ServiceAccount individuales por bucle de control |
| **Radio de impacto (Blast Radius)** | **Crítico**: El compromiso de 1 controlador otorga acceso a todas las APIs | **Bajo**: El compromiso está restringido estrictamente a las reglas de RBAC de ese controlador específico |
| **Visibilidad de auditoría de RBAC** | Los logs del API Server muestran `system:kube-controller-manager` para todas las mutaciones | Los logs de auditoría especifican el origen exacto (ej. `system:serviceaccount:kube-system:job-controller`) |
| **Carga en el API Server** | Sobrecarga baja (conexión TLS única multiplexada) | Sobrecarga de verificación de token ligeramente mayor en `kube-apiserver` |
| **Complejidad de configuración** | Certificado de cliente único y simple en kubeconfig | Requiere ServiceAccounts del sistema creadas previamente y vinculaciones de RBAC |

### 2.2 Selección de líder y modos de alta disponibilidad

| Característica de arquitectura | Instancia única | Selección de líder multinodo (bloqueos por `Lease`) |
| :--- | :--- | :--- |
| **Disponibilidad / SLA** | Punto único de falla (SPOF) | Alta disponibilidad activo-pasivo |
| **Mecanismo** | Ejecución estándar del demonio | Coordinado a través del objeto `Lease` `coordination.k8s.io/v1` en `kube-system` |
| **Protección contra Split-Brain** | N/A | Asegurado mediante bloqueo optimista distribuido y verificaciones de marca de tiempo del API server |
| **Configuración de flags** | `--leader-elect=false` | `--leader-elect=true --leader-elect-resource-lock=leases` |
| **Requisito de RBAC** | Permisos básicos de lectura/escritura | Requiere `get, update, create` en `leases.coordination.k8s.io` en `kube-system` |

---

## 3. Manifiestos de producción y configuraciones de infraestructura

### 3.1 Manifiesto de Static Pod endurecido: `kube-controller-manager.yaml`
Ruta: `/etc/kubernetes/manifests/kube-controller-manager.yaml`
Este manifiesto hace cumplir los requisitos de seguridad de NIST SP 800-190, CIS Benchmark v1.8 y KCSA.

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-controller-manager
    tier: control-plane
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --cluster-name=production-cluster
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --controllers=*
    - --feature-gates=RotateKubeletServerCertificate=true
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --leader-elect-resource-lock=leases
    - --leader-elect-retry-period=2s
    - --leader-elect-lease-duration=15s
    - --leader-elect-renew-deadline=10s
    - --node-cidr-mask-size=24
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --secure-port=10257
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --terminated-pod-gc-threshold=1250
    - --tls-cert-file=/etc/kubernetes/pki/kube-controller-manager.crt
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS13
    - --tls-private-key-file=/etc/kubernetes/pki/kube-controller-manager.key
    - --use-service-account-credentials=true
    image: registry.k8s.io/kube-controller-manager:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki
      name: ca-certs-etc-pki
      readOnly: true
    - mountPath: /etc/kubernetes/controller-manager.conf
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
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
      path: /etc/pki
      type: DirectoryOrCreate
    name: ca-certs-etc-pki
  - hostPath:
      path: /etc/kubernetes/controller-manager.conf
      type: FileOrCreate
    name: kubeconfig
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
```

### 3.2 Configuración de Kubeconfig: `/etc/kubernetes/controller-manager.conf`
Este archivo de configuración establece la autenticación mTLS para que `kube-controller-manager` se comunique con `kube-apiserver`.

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://127.0.0.1:6443
  name: production-cluster
contexts:
- context:
    cluster: production-cluster
    user: system:kube-controller-manager
  name: system:kube-controller-manager@production-cluster
current-context: system:kube-controller-manager@production-cluster
users:
- name: system:kube-controller-manager
  user:
    client-certificate: /etc/kubernetes/pki/kube-controller-manager.crt
    client-key: /etc/kubernetes/pki/kube-controller-manager.key
```

### 3.3 Configuración de RBAC dedicada para autenticación por controlador
Cuando se establece `--use-service-account-credentials=true`, `kube-controller-manager` utiliza ServiceAccounts internas para cada bucle. A continuación se muestra un manifiesto de RBAC explícito que muestra cómo `system:kube-controller-manager` delega el control para el bucle del Deployment Controller.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployment-controller
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:controller:deployment-controller
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/rollback", "deployments/scale"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:controller:deployment-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:controller:deployment-controller
subjects:
- kind: ServiceAccount
  name: deployment-controller
  namespace: kube-system
```

---

## 4. Comandos de ejecución reales de CLI y salidas de terminal

### 4.1 Verificación de flags de proceso y ejecución en tiempo de ejecución non-root
Valide que el proceso se esté ejecutando en el host/contenedor sin flags inseguros de alto riesgo (`--port=0` o la ausencia de puertos HTTP legacy).

```bash
$ ps aux | grep kube-controller-manager | grep -v grep
```
```output
10001    14201  3.2  2.1 743120 178200 ?        Ssl  18:22   0:14 kube-controller-manager --allocate-node-cidrs=true --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf --bind-address=127.0.0.1 --client-ca-file=/etc/kubernetes/pki/ca.crt --cluster-cidr=10.244.0.0/16 --cluster-name=production-cluster --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt --cluster-signing-key-file=/etc/kubernetes/pki/ca.key --controllers=* --feature-gates=RotateKubeletServerCertificate=true --kubeconfig=/etc/kubernetes/controller-manager.conf --leader-elect=true --leader-elect-resource-lock=leases --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt --root-ca-file=/etc/kubernetes/pki/ca.crt --secure-port=10257 --service-account-private-key-file=/etc/kubernetes/pki/sa.key --service-cluster-ip-range=10.96.0.0/12 --terminated-pod-gc-threshold=1250 --tls-cert-file=/etc/kubernetes/pki/kube-controller-manager.crt --tls-min-version=VersionTLS13 --tls-private-key-file=/etc/kubernetes/pki/kube-controller-manager.key --use-service-account-credentials=true
```

### 4.2 Auditoría del estado de selección de líder a través de la API de `Lease`
Verifique qué instancia de `kube-controller-manager` mantiene actualmente el bloqueo distribuido.

```bash
$ kubectl get lease kube-controller-manager -n kube-system -o yaml
```
```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  creationTimestamp: "2026-08-07T12:00:00Z"
  name: kube-controller-manager
  namespace: kube-system
  resourceVersion: "48201"
spec:
  acquireTime: "2026-08-07T14:10:05.122849Z"
  holderIdentity: master-node-01_fa82910c-391a-4d6b-b4a1-09852f10214a
  leaseDurationSeconds: 15
  leaseTransitions: 1
  renewTime: "2026-08-07T19:31:30.984120Z"
```

### 4.3 Verificación del cumplimiento de RBAC de ServiceAccount por controlador
Compruebe si las cuentas de servicio individuales existen y pueden realizar sus reconciliaciones explícitas.

```bash
$ kubectl auth can-i create deployments --as=system:serviceaccount:kube-system:deployment-controller -n default
```
```output
yes
```

```bash
$ kubectl auth can-i delete secrets --as=system:serviceaccount:kube-system:deployment-controller -n default
```
```output
no
```

### 4.4 Inspección del endpoint TLS con certificados de cliente autorizados
Pruebe los endpoints seguros de healthz y metrics sobre el puerto 10257 utilizando mTLS.

```bash
$ curl -s --cacert /etc/kubernetes/pki/ca.crt \
        --cert /etc/kubernetes/pki/kube-controller-manager.crt \
        --key /etc/kubernetes/pki/kube-controller-manager.key \
        https://127.0.0.1:10257/healthz
```
```output
ok
```

---

## 5. Guía de verificación y resolución de fallas (Troubleshooting)

```
                      Troubleshooting Flowchart: kube-controller-manager
                                                |
                                    Is Process Running?
                                    /                 \
                                  YES                  NO
                                  /                     \
                      Check Health Endpoint          Check Container Logs
                   https://127.0.0.1:10257/healthz     (crictl logs / journalctl)
                            /         \                         |
                         HTTP 200    HTTP 500 / Timeout     Look for startup flags,
                            |             |               PKI permissions, or missing
                     Controller OK   Inspect Logs        sa.key path issues
                                          |
                        +-----------------+-----------------+
                        |                                   |
              RBAC Authorization Error             Leader Election Blocked
                        |                                   |
              Check --use-service-account         Check clock synchronization (NTP)
              -credentials RBAC bindings          & Lease object ownership in kube-system
```

### 5.1 Escenarios de diagnóstico y protocolos de remediación

#### Escenario A: Pods atascados en `Pending` / Tokens de ServiceAccount no aprovisionados
* **Síntoma**: La creación de Pods se congela; los secrets de tipo `kubernetes.io/service-account-token` no se pueblan, o los montajes de volumen del pod fallan con `token-request-denied`.
* **Causa raíz**: `--service-account-private-key-file` en `kube-controller-manager` falta, está mal configurado o es inaccesible debido a permisos del SO.
* **Comando de diagnóstico**:
  ```bash
  $ crictl logs $(crictl ps --name=kube-controller-manager -q) 2>&1 | grep -i "token"
  ```
* **Salida de log de muestra**:
  ```output
  E0807 19:15:02.102941 1 sa_token_controller.go:143] Cannot start ServiceAccountTokenController: open /etc/kubernetes/pki/sa.key: permission denied
  ```
* **Remediación**:
  Asegúrese de que la ruta del host `/etc/kubernetes/pki/sa.key` tenga una propiedad de archivo estricta que coincida con el usuario definido en `securityContext` (`runAsUser: 10001` o `root` según la configuración) y permisos establecidos en `0400` o `0600`.

#### Escenario B: Falla de autorización del bucle de controlador (`--use-service-account-credentials=true`)
* **Síntoma**: Los cambios de estado de Deployment en `kube-apiserver` se ignoran; los objetos `ReplicaSet` no logran reducir la escala o crear pods.
* **Causa raíz**: Los roles de cluster del sistema (cluster roles) vinculados a `system:serviceaccount:kube-system:deployment-controller` (u otro controlador) se modificaron o eliminaron.
* **Comando de diagnóstico**:
  ```bash
  $ kubectl logs -n kube-system static-pod-kube-controller-manager-master-node-01 | grep "Forbidden"
  ```
* **Salida de log de muestra**:
  ```output
  E0807 19:22:11.892014 1 replica_set.go:312] Failed to create pod for replicaset frontend-6b478848c4: pods is forbidden: User "system:serviceaccount:kube-system:deployment-controller" cannot create resource "pods" in API group "" in the namespace "default"
  ```
* **Remediación**:
  Vuelva a aplicar los manifiestos de RBAC estándar del sistema de Kubernetes o ejecute `kubeadm init phase rbac bootstrap-roles` para restaurar los permisos predeterminados.

#### Escenario C: Bloqueo mutuo (Deadlock) en la selección de líder / Split-Brain
* **Síntoma**: Múltiples nodos de control plane intentando realizar reconciliaciones simultáneamente, lo que resulta en recursos duplicados o alta rotación de objetos.
* **Causa raíz**: Desviación de reloj (NTP skew) entre los nodos del control plane que supera `--leader-elect-lease-duration` o particiones de red que bloquean las operaciones de actualización en la `Lease` de `coordination.k8s.io/v1`.
* **Comando de diagnóstico**:
  ```bash
  $ kubectl get events -n kube-system --field-selector involvedObject.name=kube-controller-manager
  ```
* **Salida de log de muestra**:
  ```output
  LAST SEEN   TYPE      REASON            OBJECT                        MESSAGE
  12s         Warning   FailedToRenew     lease/kube-controller-manager master-node-02 failed to renew lease: leaderelection lost
  2s          Normal    LeaderElection    lease/kube-controller-manager master-node-01 became leader
  ```
* **Remediación**:
  1. Verifique la desviación de reloj utilizando `chronyc tracking` en todas las instancias del control plane. La desviación debe permanecer por debajo de 500ms.
  2. Verifique la conectividad de red entre todos los nodos del control plane y los balanceadores de carga locales/remotos del API server.

---

## 6. Referencias

- [Documentación oficial de Kubernetes: Referencia de CLI de kube-controller-manager](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Documentación oficial de Kubernetes: Asegurar el Control Plane](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [Repositorio del currículo del examen CNCF KCSA](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)