# Guía de estudio KCSA de CNCF: Tema 2.2 – Seguridad del Controller Manager

## 1. Arquitectura técnica profunda y mecánicas de seguridad

El `kube-controller-manager` es un binario del control plane principal que aloja los bucles de control internos (controllers) incluidos con Kubernetes. Cada controller monitorea continuamente el estado del cluster a través del `kube-apiserver` y realiza o solicita cambios para reconciliar el estado actual con el estado deseado.

```
+-----------------------------------------------------------------------------------+
|                            kube-controller-manager                                |
|                                                                                   |
|  +-------------------------+  +-------------------------+  +-------------------+  |
|  | node-lifecycle-controller|  | job-controller          |  | serviceaccount-   |  |
|  |                         |  |                         |  | token-controller  |  |
|  +------------+------------+  +------------+------------+  +---------+---------+  |
|               |                            |                         |            |
|               +----------------------------+-------------------------+            |
|                                            |                                      |
|                 [ In-Process Client / SharedInformerFactory ]                    |
+--------------------------------------------+--------------------------------------+
                                             |  (HTTPS 6443 / Mutual TLS)
                                             v
+-----------------------------------------------------------------------------------+
|                                 kube-apiserver                                    |
|                                                                                   |
|  +--------------------+    +---------------------------+    +------------------+  |
|  | Authentication     | -> | Authorization (RBAC)      | -> | Admission Control|  |
|  +--------------------+    +---------------------------+    +------------------+  |
+-----------------------------------------------------------------------------------+
```

### Vectores de seguridad principales y flags

1. **Principio de menor privilegio (`--use-service-account-credentials`)**:
   - **Modo por defecto/inseguro (`false`)**: Todos los bucles internos comparten una única credencial de cliente con altos privilegios (el certificado de cliente de `kube-controller-manager`), el cual otorga privilegios cercanos a `cluster-admin` sobre todos los recursos.
   - **Modo endurecido (`true`)**: El controller manager crea credenciales de `ServiceAccount` individuales por bucle de control (p. ej., `system:serviceaccount:kube-system:node-controller`, `system:serviceaccount:kube-system:job-controller`). Los permisos RBAC se evalúan estrictamente para cada bucle específico, limitando el radio de impacto (blast radius) si un proceso o token de un controller individual resulta comprometido.

2. **Gestión de claves criptográficas para ServiceAccounts**:
   - `--service-account-private-key-file`: Especifica la clave privada RSA o ECDSA utilizada por el `TokenController` para firmar los JWT tokens de las ServiceAccount.
   - `--root-ca-file`: Especifica el bundle Root CA inyectado en las monturas de volumen del secret de ServiceAccount en los Pods (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) para permitir que las cargas de trabajo in-cluster verifiquen el certificado TLS del API server.

3. **Seguridad en la capa de transporte y endurecimiento de métricas**:
   - `--secure-port=10257` (puerto seguro por defecto): Cifra el tráfico HTTP entrante para las probes de salud (`/healthz`) y las métricas de Prometheus (`/metrics`).
   - `--bind-address=127.0.0.1` o IP interna del control-plane: Restringe las interfaces de escucha de red.
   - `--authorization-always-allow-paths=/healthz,/metrics`: Controla el acceso a endpoints no autenticados. Configurar las flags de autenticación/autorización (`--authentication-kubeconfig` y `--authorization-kubeconfig`) garantiza que los endpoints de métricas requieran un RBAC válido (`system:kube-scheduler` o ServiceAccounts de recolectores de métricas).

4. **Mitigación de desalojo y ciclo de vida de nodos (`--pod-eviction-timeout`, `--node-eviction-rate`)**:
   - Configura límites de tasa (rate limits) para los taints de nodos y los eviction de pods durante particiones de red para prevenir una denegación de servicio (DoS) en cascada en el cluster.

---

## 2. Referencias oficiales y documentación
- [Referencia de Kubernetes: `kube-controller-manager`](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Arquitectura de Kubernetes: Componentes del control plane](https://kubernetes.io/docs/concepts/architecture/controller/)
- [Seguridad del Token Controller de ServiceAccount](https://kubernetes.io/docs/concepts/security/service-accounts-admin/)
- [Plan de estudios del examen CNCF KCSA](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Ejercicios prácticos guiados de laboratorio

### Ejercicio 1: Auditoría y endurecimiento de las flags de seguridad de `kube-controller-manager`

En este ejercicio, auditarás un manifiesto de static pod de `kube-controller-manager` existente, identificarás configuraciones inseguras y aplicarás flags de endurecimiento para producción.

#### Paso 1.1: Inspeccionar la configuración del static pod del controller-manager en ejecución
Ejecutá el siguiente comando para obtener la configuración actual de las flags de `kube-controller-manager` en un nodo del control plane.

```bash
kubectl get pod -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' | jq .
```

**Salida esperada:**
```json
[
  "kube-controller-manager",
  "--allocate-node-cidrs=true",
  "--authentication-kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--authorization-kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--bind-address=127.0.0.1",
  "--client-ca-file=/etc/kubernetes/pki/ca.crt",
  "--cluster-cidr=10.244.0.0/16",
  "--cluster-name=kubernetes",
  "--cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt",
  "--cluster-signing-key-file=/etc/kubernetes/pki/ca.key",
  "--controllers=*,bootstrapsigner,tokentrainer",
  "--kubeconfig=/etc/kubernetes/controller-manager.conf",
  "--leader-elect=true",
  "--requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt",
  "--root-ca-file=/etc/kubernetes/pki/ca.crt",
  "--service-account-private-key-file=/etc/kubernetes/pki/sa.key",
  "--use-service-account-credentials=true"
]
```

#### Paso 1.2: Validar el aislamiento del binding de RBAC para controllers individuales
Verificá que `--use-service-account-credentials=true` haya creado bindings de identidad de ServiceAccount distintos en `kube-system`.

```bash
kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.subjects[]?.name | strings | startswith("pvc-protection-controller")) | .metadata.name'
```

**Salida esperada:**
```
system:controller:pvc-protection-controller
```

Inspeccioná los permisos asociados con el `pvc-protection-controller`:

```bash
kubectl get clusterrole system:controller:pvc-protection-controller -o yaml
```

**Salida esperada:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:controller:pvc-protection-controller
rules:
- apiGroups:
  - ""
  resources:
  - persistentvolumeclaims
  verbs:
  - get
  - list
  - watch
  - update
```

---

#### Pregunta de verificación 1.1
¿Cuál es el riesgo de seguridad de ejecutar `kube-controller-manager` con `--use-service-account-credentials=false` en un entorno de cluster multi-tenant o endurecido?

---

### Ejercicio 2: Simulación del compromiso de token de un controller e implementación del menor privilegio

En este ejercicio, analizarás cómo el RBAC de la service account de un controller individual previene el escalado horizontal de privilegios cuando se aísla el contexto del controller.

#### Paso 2.1: Verificar el acceso a la API usando `kubectl auth can-i` para una ServiceAccount de un controller específico
Simulá a un atacante que obtuvo acceso al token de `system:serviceaccount:kube-system:job-controller`. Comprobá si esta identidad puede leer secrets del cluster.

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:kube-system:job-controller -n default
```

**Salida esperada:**
```
no
```

Ahora verificá qué acciones la ServiceAccount `job-controller` *sí* tiene permitido realizar sobre Pods:

```bash
kubectl auth can-i create pods --as=system:serviceaccount:kube-system:job-controller -n default
```

**Salida esperada:**
```
yes
```

#### Paso 2.2: Crear una ServiceAccount de controller personalizada y un manifiesto RBAC
A continuación se presenta un manifiesto de producción sintácticamente válido que define una configuración RBAC de menor privilegio para un proceso personalizado de operator o controller ejecutándose dentro del cluster. Aplicá este manifiesto para configurar el acceso restringido del controller.

Creá el archivo de manifiesto `custom-controller-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: custom-deployment-reconciler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: custom-deployment-reconciler-role
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: custom-deployment-reconciler-binding
subjects:
- kind: ServiceAccount
  name: custom-deployment-reconciler
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: custom-deployment-reconciler-role
  apiGroup: rbac.authorization.k8s.io
```

Aplicá el manifiesto:

```bash
kubectl apply -f custom-controller-rbac.yaml
```

**Salida esperada:**
```
serviceaccount/custom-deployment-reconciler created
clusterrole.rbac.authorization.k8s.io/custom-deployment-reconciler-role created
clusterrolebinding.rbac.authorization.kubernetes.io/custom-deployment-reconciler-binding created
```

#### Paso 2.3: Probar los límites de permisos del controller personalizado
Ejecutá consultas de autorización para verificar la aplicación de los límites:

```bash
kubectl auth can-i delete deployments --as=system:serviceaccount:kube-system:custom-deployment-reconciler -n default
```

**Salida esperada:**
```
no
```

---

#### Pregunta de verificación 2.1
Si un controller requiere permisos de `watch` en `secrets` para reconciliar certificados TLS, pero nunca debería crear ni modificar secrets, ¿qué entradas de `verbs` y `resources` de RBAC deben configurarse en su `ClusterRole`? ¿Qué campo adicional puede limitar el acceso a instancias de Secret específicas?

---

### Ejercicio 3: Métricas del Controller Manager y diagnóstico de seguridad HTTPS

En este ejercicio, diagnosticarás y asegurarás el endpoint de métricas de `kube-controller-manager` utilizando mutual TLS y autorización RBAC.

#### Paso 3.1: Intentar acceso no autorizado al endpoint HTTPS del Controller Manager
Por defecto, los clusters seguros de producción fuerzan la autenticación en el puerto `10257`. Probá obtener métricas sin un certificado de cliente o bearer token válido:

```bash
curl -k -s -o /dev/null -w "%{http_code}\n" https://127.0.0.1:10257/metrics
```

**Salida esperada:**
```
401
```

#### Paso 3.2: Consultar métricas con credenciales administrativas del kubeconfig
Utilizá las credenciales del kubeconfig del sistema para `kube-controller-manager` para autenticarte correctamente contra el endpoint de métricas:

```bash
curl --cacert /etc/kubernetes/pki/ca.crt \
     --cert /etc/kubernetes/pki/front-proxy-client.crt \
     --key /etc/kubernetes/pki/front-proxy-client.key \
     -s https://127.0.0.1:10257/metrics | head -n 15
```

**Salida esperada:**
```
# HELP go_gc_duration_seconds A summary of the pause duration of garbage collection cycles.
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} 0.0001023
go_gc_duration_seconds{quantile="0.25"} 0.0001451
go_gc_duration_seconds{quantile="0.5"} 0.0001892
go_gc_duration_seconds{quantile="0.75"} 0.0002511
go_gc_duration_seconds{quantile="1"} 0.0008912
# HELP go_goroutines Number of goroutines that currently exist.
# TYPE go_goroutines gauge
go_goroutines 142
```

#### Paso 3.3: Inspeccionar métricas activas del controller para monitoreo de seguridad
Verificá la profundidad de la cola (queue depth) y los errores de reconciliación para controllers específicos (p. ej., el controller `serviceaccount-token`) para detectar inanición de recursos (resource starvation) o abuso de service accounts:

```bash
curl -k --cert /etc/kubernetes/pki/front-proxy-client.crt \
        --key /etc/kubernetes/pki/front-proxy-client.key \
        -s https://127.0.0.1:10257/metrics | grep "workqueue_adds_total" | head -n 5
```

**Salida esperada:**
```
workqueue_adds_total{name="action_deployment"} 12
workqueue_adds_total{name="certificate"} 4
workqueue_adds_total{name="endpoint"} 158
workqueue_adds_total{name="garbage_collector"} 89
workqueue_adds_total{name="serviceaccount"} 34
```

---

#### Pregunta de verificación 3.1
¿Qué dos flags en `kube-controller-manager` aplican verificaciones de autorización RBAC y autenticación en su endpoint HTTPS de métricas (`:10257`), previniendo el descubrimiento de métricas sin autenticar?

---

## 4. Soluciones y explicaciones técnicas

<details>
<summary>Click to expand Answers and Deep Explanations</summary>

### Respuesta a la pregunta 1.1

**Respuesta:**
Cuando `--use-service-account-credentials=false` (o no está presente), todos los bucles de control dentro de `kube-controller-manager` se ejecutan utilizando el certificado de cliente/kubeconfig suministrado a través de `--kubeconfig`. Esta credencial típicamente pertenece a `system:kube-controller-manager`, el cual posee amplios permisos administrativos a nivel de todo el cluster.

**Implicación de seguridad y mecánica:**
1. **Falta de aislamiento**: Si una falla, bug o exploit de canal lateral en un solo bucle de controller (p. ej., `pv-protection-controller` o una dependencia de terceros) permite la construcción arbitraria de peticiones a la API, el exploit hereda privilegios completos de superusuario/admin sobre el cluster en lugar de estar limitado a recursos PVC.
2. **Falla de auditoría**: Los logs de auditoría del `kube-apiserver` atribuirán todas las llamadas a la API de todos los controllers a `system:kube-controller-manager`, haciendo imposible el análisis forense granular y la detección de anomalías.
3. **Buena práctica**: Habilitar `--use-service-account-credentials=true` fuerza a cada bucle a autenticarse como `system:serviceaccount:kube-system:<controller-name>`, adhiriéndose al principio de menor privilegio.

---

### Respuesta a la pregunta 2.1

**Respuesta:**
Para permitir la lectura en modo solo lectura (`watch`) de secrets sin habilitar su modificación o creación:
- **Verbs**: `["get", "list", "watch"]`
- **Resources**: `["secrets"]`
- **Restricción de nombres de recursos**: Para restringir el acceso strictly a instancias de secret específicas, utilizá el array `resourceNames`.

**Fragmento de ejemplo de ClusterRole de RBAC:**
```yaml
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["tls-ingress-cert", "custom-api-token"]
  verbs: ["get", "list", "watch"]
```

**Explicación técnica:**
El uso de `resourceNames` previene que el controller enumere u obtenga otros secrets (como tokens de ServiceAccount o contraseñas de bases de datos) en el namespace, mitigando efectivamente el movimiento lateral en caso de que el controller resulte comprometido.

---

### Respuesta a la pregunta 3.1

**Respuesta:**
Las dos flags obligatorias son:
1. `--authentication-kubeconfig=/path/to/kubeconfig`
2. `--authorization-kubeconfig=/path/to/kubeconfig`

**Explicación técnica:**
- Sin `--authentication-kubeconfig`, el servidor HTTPS en el puerto `10257` no puede verificar los certificados de cliente o Bearer tokens contra la Token Review API del API server.
- Sin `--authorization-kubeconfig`, el servidor no delega las decisiones de autorización al API server vía `SubjectAccessReview`. Configurar ambas flags garantiza que quienes intenten acceder a `/metrics` deban presentar una identidad vinculada a un `ClusterRole` con permisos de `get` sobre las URLs no pertenecientes a recursos (non-resource URLs) `/metrics`.

</details>