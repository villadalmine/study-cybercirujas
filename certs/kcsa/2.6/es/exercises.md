# KCSA Tema 2.6: Arquitectura de Seguridad de KubeProxy & Cluster Networking

## Referencias Oficiales
* **CNCF KCSA Curriculum**: [KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Virtual IPs and Service Proxies**: [Kubernetes Service Proxies Documentation](https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies)
* **kube-proxy Component Reference**: [kube-proxy Reference Guide](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/)
* **Kubernetes Network Policies**: [Network Policies Concept](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## 1. Arquitectura Profunda y Compromisos de Seguridad en Producción

`kube-proxy` es un proxy de red que se ejecuta en cada nodo de un cluster de Kubernetes. Mantiene las reglas de red en los nodos que permiten la comunicación de red hacia los Pods desde dentro o fuera del cluster.

### 1.1 Modos de Operación y Mecánica Interna

1. **Modo iptables**:
   * **Mecanismo**: Utiliza reglas de `iptables` de Linux generadas secuencialmente a través de `iptables-restore`. `kube-proxy` observa el API server de Kubernetes en busca de cambios en los objetos `Service` y `EndpointSlice`.
   * **Rendimiento y Escala**: La evaluación de reglas es secuencial $O(N)$. Los clusters grandes con decenas de miles de Services experimentan una alta sobrecarga de CPU en los nodos durante la sincronización de reglas (`iptables-restore` bloquea el cerrojo `xtables`).
   * **Sobrecarga de Seguridad**: No realiza inspección de paquetes ni verificación de identidad. Todo el tráfico que coincide con los patrones de destino `ClusterIP` o `NodePort` se traduce mediante NAT (`DNAT`/`SNAT`).

2. **Modo IPVS**:
   * **Mecanismo**: Aprovecha el módulo del kernel Netfilter IP Virtual Server (IPVS). Construye servidores virtuales y servidores reales de IPVS mientras utiliza `ipset` para búsquedas de conjuntos de alto rendimiento.
   * **Rendimiento y Escala**: Búsqueda por hash de $O(1)$. Altamente escalable para clusters grandes ($>2,000$ Services).
   * **Requisito de Seguridad**: Requiere `strictARP: true` en la configuración de `kube-proxy` cuando se utilizan Load Balancers de Capa 2 como MetalLB para evitar conflictos de respuesta ARP en la interfaz dummy `kube-ipvs0`.

3. **Modo nftables** (Kubernetes v1.31+ vía GA/Beta):
   * **Mecanismo**: Reemplaza el `iptables` heredado con la sintaxis y gestión de estado del kernel de `nftables`, reduciendo la contención de bloqueos y optimizando las estructuras del árbol de reglas.

4. **Alternativas basadas en eBPF** (por ejemplo, enrutamiento de host Cilium eBPF):
   * Omite Netfilter/iptables por completo adjuntando programas eBPF directamente a los controladores de dispositivos de red (XDP/tc). Reemplaza o ignora completamente a `kube-proxy`.

---

### 1.2 Perímetro de Seguridad y Vectores de Ataque Comunes

| Aspecto Arquitectónico | Problema de Seguridad | Estrategia de Mitigación / Hardening |
| :--- | :--- | :--- |
| **Privilegios de Pod** | Se ejecuta con `hostNetwork: true` y privilegios `CAP_NET_ADMIN` y `CAP_NET_RAW` para mutar el estado del kernel Netfilter del host. | Aplicar Pod Security Standards estrictos (excepción `Unrestricted` para CNI/proxy críticos del sistema), restringir el acceso al token del ServiceAccount de `kube-proxy`. |
| **Métricas y Healthz Sin Autenticación** | Históricamente vinculados a `0.0.0.0:10249` (`/metrics`) y `0.0.0.0:10256` (`/healthz`). Expone métricas internas del nodo/cluster a escáneres de red no autenticados. | Vincular `metricsBindAddress` a `127.0.0.1:10249` o exigir autenticación mediante proxies RBAC/TLS. |
| **Falta de Control de Acceso** | `kube-proxy` **NO** aplica objetos `NetworkPolicy`. Simplemente enruta el tráfico. | Emparejar `kube-proxy` con un CNI compatible con NetworkPolicy (Calico, Cilium, Weave Net). |
| **Ocultamiento de IP de Origen (SNAT)** | El valor predeterminado `externalTrafficPolicy: Cluster` aplica `SNAT` al tráfico entrante de NodePort/LoadBalancer, ocultando las direcciones IP de los clientes en los logs de la aplicación y WAFs. | Establecer `externalTrafficPolicy: Local` para preservar la IP de origen del cliente (Nota de compromiso: riesgo de balanceo de carga desigual y caídas por cero endpoints en nodos sin pods). |

---

## 2. Ejercicios Guiados Prácticos

### Ejercicio 1: Auditoría y Hardening de la Exposición y Privilegios de `kube-proxy`

#### Escenario
Estás auditando un cluster de producción para garantizar que `kube-proxy` cumpla con las configuraciones de seguridad de menor privilegio y no exponga endpoints de métricas sin autenticación en las interfaces públicas de los nodos.

#### Pasos

1. **Paso 1**: Obtener el ConfigMap actual de `kube-proxy` del namespace `kube-system` e inspeccionar la estructura de su configuración.
```bash
kubectl get configmap kube-proxy -n kube-system -o yaml > kube-proxy-cm.yaml
cat kube-proxy-cm.yaml | grep -E "bindAddress|metricsBindAddress|mode|healthzBindAddress"
```
*Salida Esperada:*
```text
    bindAddress: 0.0.0.0
    healthzBindAddress: 0.0.0.0:10256
    metricsBindAddress: 0.0.0.0:10249
    mode: "iptables"
```

2. **Paso 2**: Verificar si el endpoint de métricas es accesible públicamente desde dentro de un Pod del cluster a través de las interfaces del nodo.
```bash
kubectl run network-audit-pod --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl -s -I http://kube-proxy.kube-system.svc:10249/metrics | head -n 5
```
*Salida Esperada:*
```text
HTTP/1.1 200 OK
Content-Type: text/plain; version=0.0.4; charset=utf-8
Date: Fri, 07 Aug 2026 19:37:42 GMT
```

3. **Paso 3**: Inspeccionar la especificación del DaemonSet de `kube-proxy` para auditar el uso compartido del namespace de red del host y los contextos de seguridad.
```bash
kubectl get ds kube-proxy -n kube-system -o yaml | grep -A 12 "securityContext:"
```
*Salida Esperada:*
```yaml
      securityContext:
        capabilities:
          add:
          - NET_ADMIN
        privileged: true
```

4. **Paso 4**: Aplicar un parche de ConfigMap endurecido (hardened) que restrinja `metricsBindAddress` a localhost (`127.0.0.1:10249`) y cambie el modo a `iptables` con reglas de enmascaramiento estrictas.

Guardar el siguiente manifiesto en `kube-proxy-hardened-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    app: kube-proxy
data:
  config.conf: |-
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    bindAddress: 0.0.0.0
    clientConnection:
      acceptContentTypes: ""
      burst: 10
      contentType: application/vnd.kubernetes.protobuf
      qps: 5
    clusterCIDR: 10.244.0.0/16
    healthzBindAddress: 127.0.0.1:10256
    metricsBindAddress: 127.0.0.1:10249
    mode: "iptables"
    iptables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 0s
      syncPeriod: 30s
    nftables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 0s
      syncPeriod: 30s
```

Aplicar el ConfigMap actualizado y desencadenar un reinicio progresivo (rolling restart) del DaemonSet de `kube-proxy`:
```bash
kubectl apply -f kube-proxy-hardened-cm.yaml
kubectl rollout restart daemonset/kube-proxy -n kube-system
kubectl rollout status daemonset/kube-proxy -n kube-system
```
*Salida Esperada:*
```text
configmap/kube-proxy configured
daemonset.apps/kube-proxy restarted
daemonset rolling update status master restart recorder: 1 of 1 updated instances are available...
```

5. **Paso 5**: Verificar que el acceso de pods externos a `/metrics` ahora esté bloqueado/rechazado.
```bash
kubectl run network-audit-pod-verify --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl --connect-timeout 3 http://10.96.0.1:10249/metrics
```
*Salida Esperada:*
```text
curl: (7) Failed to connect to 10.96.0.1 port 10249 after 3000 ms: Couldn't connect to server
pod "network-audit-pod-verify" deleted
```

---

#### Preguntas de Verificación - Ejercicio 1
1. **P1.1**: ¿Por qué `kube-proxy` requiere la Linux capability `CAP_NET_ADMIN` cuando se ejecuta dentro de un Pod?
2. **P1.2**: ¿Qué riesgo de seguridad se introduce cuando `metricsBindAddress` se establece en `0.0.0.0:10249` sin un grupo de seguridad de red o una política de firewall que proteja los nodos?

---

### Ejercicio 2: Preservación de IP de Origen e Inspección de Cadenas de Netfilter

#### Escenario
Un equipo de respuesta a incidentes de seguridad nota que los logs de acceso de la aplicación web muestran que todas las solicitudes externas entrantes se originan desde direcciones IP internas de los nodos del cluster (por ejemplo, `10.244.0.1` o la IP de la interfaz del nodo), enmascarando las verdaderas IP de origen del cliente. Debes diagnosticar el comportamiento de `externalTrafficPolicy` e inspeccionar las cadenas de `iptables` correspondientes generadas por `kube-proxy`.

#### Pasos

1. **Paso 1**: Crear un namespace de prueba y desplegar una aplicación web con un Service de tipo `NodePort` configurado con el valor predeterminado `externalTrafficPolicy: Cluster`.

Guardar el manifiesto como `echoserver-cluster.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: net-security-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echoserver
  namespace: net-security-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echoserver
  template:
    metadata:
      labels:
        app: echoserver
    spec:
      containers:
      - name: echoserver
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        command: ["/agnhost", "netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echoserver-nodeport
  namespace: net-security-test
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
  selector:
    app: echoserver
```

Aplicar el manifiesto:
```bash
kubectl apply -f echoserver-cluster.yaml
kubectl wait --for=condition=available deployment/echoserver -n net-security-test --timeout=60s
```

2. **Paso 2**: Ejecutar `iptables-save` dentro de un nodo o contenedor de depuración privilegiado para inspeccionar las cadenas `KUBE-NODEPORTS` y `KUBE-SERVICES` para el puerto `30080`.
```bash
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') -it --image=alpine -- sh -c "apk add --no-舆 iptables >/dev/null 2>&1; iptables-save | grep 30080"
```
*Salida Esperada:*
```text
-A KUBE-NODEPORTS -p tcp -m comment --comment "net-security-test/echoserver-nodeport:" -m tcp --dport 30080 -j KUBE-SVC-WBX7M4O4KQKZ2V3X
-A KUBE-SVC-WBX7M4O4KQKZ2V3X -m comment --comment "net-security-test/echoserver-nodeport:" -j KUBE-MARK-MASQ
```
*(Observa la regla `KUBE-MARK-MASQ`: el tráfico que ingresa en el NodePort se marca para Source NAT (SNAT), reescribiendo la IP de origen con la dirección IP del nodo).*

3. **Paso 3**: Aplicar un parche al service para usar `externalTrafficPolicy: Local`.

Guardar el siguiente archivo de parche como `patch-local.yaml`:
```yaml
spec:
  externalTrafficPolicy: Local
```

Aplicar el parche:
```bash
kubectl patch svc echoserver-nodeport -n net-security-test --patch-file patch-local.yaml
```
*Salida Esperada:*
```text
service/echoserver-nodeport patched
```

4. **Paso 4**: Volver a inspeccionar las reglas de `iptables` generadas por `kube-proxy` para `30080`.
```bash
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') -it --image=alpine -- sh -c "apk add --no-cache iptables >/dev/null 2>&1; iptables-save | grep 30080"
```
*Salida Esperada:*
```text
-A KUBE-NODEPORTS -p tcp -m comment --comment "net-security-test/echoserver-nodeport:" -m tcp --dport 30080 -j KUBE-XLB-WBX7M4O4KQKZ2V3X
-A KUBE-XLB-WBX7M4O4KQKZ2V3X -m comment --comment "net-security-test/echoserver-nodeport local retrieves" -m balancer --mode rc -j KUBE-SEP-EG6G4X3J77Y5L2RR
```
*(Observa cómo la cadena cambia de `KUBE-SVC-*` a `KUBE-XLB-*` (cadena de External Load Balancer/NodePort Local), omitiendo `KUBE-MARK-MASQ` para endpoints locales y conservando la IP real del cliente).*

5. **Paso 5**: Limpiar los recursos de prueba.
```bash
kubectl delete ns net-security-test
```

---

#### Preguntas de Verificación - Ejercicio 2
1. **P2.1**: ¿Cuál es el compromiso (trade-off) arquitectónico al cambiar `externalTrafficPolicy` de `Cluster` a `Local`?
2. **P2.2**: ¿Qué sucede con el tráfico entrante de NodePort que llega a un nodo que **no** tiene réplicas activas de Pod para ese Service cuando está configurado `externalTrafficPolicy: Local`?

---

### Ejercicio 3: Validación de Límites de Network Policy y Límites de Aislamiento de KubeProxy

#### Escenario
Un desarrollador junior asume que `kube-proxy` aplica objetos `NetworkPolicy` y que la configuración de servicios bloquea automáticamente el tráfico no autorizado entre pods de distintos namespaces. Debes demostrar empíricamente que `kube-proxy` NO aplica reglas de `NetworkPolicy` sin un plugin proveedor de CNI instalado.

#### Pasos

1. **Paso 1**: Crear dos namespaces aislados (`secure-backend` y `untrusted-frontend`).
```bash
kubectl create namespace secure-backend
kubectl create namespace untrusted-frontend
```

2. **Paso 2**: Desplegar una aplicación objetivo en `secure-backend` y definir una `NetworkPolicy` estricta orientada a denegar todo el tráfico de ingress a menos que tenga la etiqueta `role: authorized`.

Guardar el manifiesto como `backend-with-netpol.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api
  namespace: secure-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-api
  template:
    metadata:
      labels:
        app: secure-api
    spec:
      containers:
      - name: api
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        command: ["/agnhost", "netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: secure-api-svc
  namespace: secure-backend
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: secure-api
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ingress-by-default
  namespace: secure-backend
spec:
  podSelector:
    matchLabels:
      app: secure-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: authorized
```

Aplicar el manifiesto:
```bash
kubectl apply -f backend-with-netpol.yaml
kubectl wait --for=condition=available deployment/secure-api -n secure-backend --timeout=60s
```

3. **Paso 3**: Iniciar un pod cliente no autorizado en `untrusted-frontend` y probar la conexión a `secure-api-svc.secure-backend.svc.cluster.local`.
```bash
kubectl run attacker-pod -n untrusted-frontend --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl -i -s --connect-timeout 5 http://secure-api-svc.secure-backend.svc.cluster.local:8080/version
```

4. **Paso 4**: Evaluar el resultado.
* **Si el plugin CNI con soporte de NetworkPolicy (por ejemplo, Calico, Cilium) SÍ está instalado**: La conexión se agota por tiempo de espera (times out).
* **Si el plugin CNI NO soporta NetworkPolicy (por ejemplo, Flannel por defecto) y SOLO `kube-proxy` se está ejecutando**: La conexión tiene éxito (`HTTP/1.1 200 OK`).

*Salida en entorno sin aplicación de políticas:*
```text
HTTP/1.1 200 OK
Date: Fri, 07 Aug 2026 19:37:42 GMT
Content-Length: 12
Content-Type: text/plain; charset=utf-8

agnhost 2.43
pod "attacker-pod" deleted
```

5. **Paso 5**: Limpiar los recursos.
```bash
kubectl delete ns secure-backend untrusted-frontend
```

---

#### Preguntas de Verificación - Ejercicio 3
1. **P3.1**: ¿`kube-proxy` crea o manipula reglas del kernel para objetos `NetworkPolicy`? ¿Qué capa de la arquitectura de Kubernetes es responsable de aplicar las `NetworkPolicy`?
2. **P3.2**: En un entorno que utiliza Cilium en modo de enrutamiento de host eBPF con `kubeProxyReplacement: true`, ¿qué sucede con el DaemonSet estándar de `kube-proxy`?

---

## 3. Respuestas y Explicaciones Detalladas

<details>
<summary>Haz clic para expandir Respuestas y Explicaciones Detalladas</summary>

### Respuestas del Ejercicio 1

* **Respuesta a P1.1**:
  `kube-proxy` necesita manipular objetos de configuración de red a nivel de kernel en el host (como modificar tablas/cadenas de `iptables`, actualizar tablas de servidores virtuales de `ipvs` o configurar definiciones de conjuntos de `ipset`). Para hacer esto desde dentro de un contenedor utilizando el namespace de red del nodo (`hostNetwork: true`), el proceso del contenedor debe poseer la Linux capability `CAP_NET_ADMIN` (o ejecutarse como completamente privilegiado - `privileged`).

* **Respuesta a P1.2**:
  Vincular `metricsBindAddress` a `0.0.0.0:10249` expone el endpoint HTTP `/metrics` en todas las interfaces de red físicas y virtuales del nodo. Si el puerto de gestión del nodo se expone a Internet o a una VPC no confiable, actores externos no autenticados pueden escanear el puerto `10249` para extraer métricas de Prometheus. Esto filtra telemetría operativa sensible, incluyendo nombres de servicios, patrones de asignación de IP internas, estadísticas de recuento de paquetes y métricas de escala del cluster.

---

### Respuestas del Ejercicio 2

* **Respuesta a P2.1**:
  * **`externalTrafficPolicy: Cluster`**: Maximiza la disponibilidad y la distribución de carga entre todos los Pods del cluster. Si el tráfico llega al Nodo A, pero el Nodo A no tiene Pods locales para ese Service, `kube-proxy` enruta el paquete a través de la red overlay al Nodo B (causando un salto de red adicional). Para garantizar que el Nodo B pueda devolver el tráfico correctamente a través del Nodo A, `kube-proxy` realiza Source Network Address Translation (SNAT), sobrescribiendo la IP del cliente original con la dirección IP del Nodo A.
  * **`externalTrafficPolicy: Local`**: Elimina el enrutamiento entre nodos y el SNAT, preservando la dirección IP de origen original del cliente para los paquetes de ingress. Sin embargo, introduce dos compromisos (trade-offs):
    1. Posible balanceo de carga desigual si la distribución de Pods entre los nodos no es uniforme.
    2. Descarta los paquetes que llegan a nodos que tienen cero endpoints locales para ese Service (a menos que se combine con un balanceador de carga externo utilizando chequeos de estado en `healthCheckNodePort`).

* **Respuesta a P2.2**:
  Cuando `externalTrafficPolicy: Local` está activo, `kube-proxy` crea reglas de `iptables`/`ipvs` que descartan inmediatamente paquetes o rechazan conexiones que llegan al NodePort de un nodo si no se están ejecutando instancias de pod locales saludables en ese nodo específico. Los External Load Balancers (como AWS NLB o GCP ILB) dependen de `healthCheckNodePort` (rango predeterminado de puerto 30256) expuesto por `kube-proxy` para excluir dinámicamente de los grupos destino a los nodos sin endpoints locales.

---

### Respuestas del Ejercicio 3

* **Respuesta a P3.1**:
  **No.** `kube-proxy` es estrictamente un proxy de Service responsable del balanceo de carga del tráfico dirigido a IP de `ClusterIP`, `NodePort` y `ExternalName` hacia los `EndpointSlices`. Ignora por completo los recursos `NetworkPolicy`. 
  El **plugin CNI (Container Network Interface)** (por ejemplo, Calico, Cilium, Antrea, Weave Net) es el único responsable de interpretar los objetos `NetworkPolicy` y programar reglas de filtrado de paquetes a nivel de interfaz o eBPF/iptables (por ejemplo, a través de `tc`, `xt_physdev` o búsquedas en mapas eBPF) para bloquear o permitir el tráfico este-oeste de pod a pod.

* **Respuesta a P3.2**:
  Cuando un CNI como Cilium opera con `kubeProxyReplacement: true`, los programas eBPF de Cilium manejan el enrutamiento de servicios `ClusterIP`, `NodePort`, `LoadBalancer` y `externalIPs` directamente en la capa de socket (`BPF_PROG_TYPE_CGROUP_SOCK`) e interfaces del controlador de red. En esta arquitectura, el DaemonSet heredado de `kube-proxy` se vuelve redundante y se puede eliminar por completo del cluster (`kubectl delete ds kube-proxy -n kube-system`), ahorrando memoria en el nodo y eliminando por completo la contención de bloqueos de Netfilter/iptables.

</details>