# Guía de Estudio CNCF KCSA: Dominio 2.6 – KubeProxy

**Certificación:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Kubernetes Cluster Component Security (Peso: 22%)  
**Subtema:** 2.6 KubeProxy (Peso del tema: 2.0%)  

---

## 1. Motivación Arquitectónica de Producción y Problemática

### Rol Arquitectónico
`kube-proxy` es el daemon proxy de red que se ejecuta en cada nodo de un cluster de Kubernetes. Refleja los objetos `Service` y `Endpoint` / `EndpointSlice` de Kubernetes definidos en el API server manipulando los mecanismos de enrutamiento y filtrado de paquetes del kernel de Linux a nivel de host (tales como `iptables`, `IPVS` o `nftables`). Su función principal es implementar redes Virtual IP (VIP) y balanceo de carga de Capa 4 para tráfico interno del cluster (`ClusterIP`) y externo (`NodePort`, `LoadBalancer`).

```
                   +-----------------------------------------------+
                   |                  Control Plane                |
                   |               kube-apiserver                  |
                   +-----------------------+-----------------------+
                                           | Watch (Services/EndpointSlices)
                                           v
+---------------------------------------------------------------------------------+
| Worker Node                                                                     |
|  +-------------------+        Modifies        +------------------------------+  |
|  |    kube-proxy     | ---------------------> | Host Linux Kernel Networking |  |
|  |   (DaemonSet)     |                        | (iptables / IPVS / nftables) |  |
|  +-------------------+                        +--------------+---------------+  |
|                                                              |                  |
|  Inbound Traffic ---> [ NodePort / ClusterIP ] --------------+                  |
|                                                              |                  |
|                                            +-----------------+-----------------+  |
|                                            | DNAT / Load Balancing             |  |
|                                            v                                   v  |
|                                    +---------------+                   +---------------+  |
|                                    | Pod A (Local) |                   | Pod B (Remote)|  |
|                                    +---------------+                   +---------------+  |
+---------------------------------------------------------------------------------+
```

### Problemas Operativos y de Seguridad en Producción

1. **Acceso Privilegiado al Host y Superficie de Ataque Ampliada:**
   Para mutar las tablas netfilter del kernel del host, conjuntos IPVS o sockets crudos, `kube-proxy` típicamente requiere privilegios elevados en el host (`privileged: true` o las Linux capabilities `CAP_NET_ADMIN` y `CAP_NET_RAW`) junto con acceso al namespace de red del host (`hostNetwork: true`). Si un atacante compromete un pod de `kube-proxy` o explota un endpoint de métricas/salud no autenticado, hereda derechos de manipulación de red de bajo nivel en el nodo host, lo que permite la intercepción de tráfico, suplantación (spoofing) de ARP/IP y ataques de hombre en el medio (man-in-the-middle, MitM).

2. **Complejidad de Escalamiento de Reglas $O(N)$ (modo iptables):**
   En modo `iptables`, cada Service y Endpoint se evalúa secuencialmente. Un cluster con 10,000 Services y 50,000 Endpoints crea cientos de miles de reglas de iptables secuenciales. La evaluación secuencial de reglas incurre en un alto consumo de CPU por paquete e induce bloqueos de escritura en el kernel (contención de bloqueo de `iptables-restore`), lo que resulta en picos de latencia en el procesamiento de paquetes y retrasos prolongados de sincronización durante eventos de escalamiento rápido.

3. **Ofuscación de IP de Origen y Evasión de Políticas de Seguridad:**
   Por defecto, `kube-proxy` realiza Source Network Address Translation (SNAT) en el tráfico de Service entre nodos para garantizar que los paquetes de retorno atraviesen el nodo de origen (gestionando el enrutamiento asimétrico). Esto reemplaza la IP de origen real del cliente por la dirección IP interna del nodo. Mecanismos de seguridad como NetworkPolicies, Web Application Firewalls (WAFs), Intrusion Detection Systems (IDS) y mecanismos de registro de auditoría pierden visibilidad de la identidad real del cliente, haciendo que las listas de control de acceso (ACLs) basadas en IP sean ineficaces a menos que se aplique explícitamente `externalTrafficPolicy: Local`.

4. **Vinculación de Interfaces Sin Restricciones (Riesgo de NodePort):**
   Por defecto, `kube-proxy` configura reglas de NodePort en todas las interfaces de red de un nodo (`0.0.0.0`). En nodos con múltiples interfaces (multi-homed) o entornos donde los nodos poseen interfaces de red tanto públicas (expuestas a internet) como privadas de administración, los Services internos de tipo `NodePort` quedan expuestos inadvertidamente en interfaces públicas a menos que se restrinjan mediante el flag de configuración `nodePortAddresses`.

---

## 2. Comparativas Técnicas y Tablas de Compromisos (Trade-offs)

### Arquitectura de los Modos de Proxy

*   **Modo iptables:** Se apoya en los hooks de `netfilter` de Linux (`PREROUTING`, `POSTROUTING`, `KUBE-SERVICES`, `KUBE-NODEPORTS`). Las actualizaciones de reglas usan llamadas secuenciales a `iptables-restore`. La selección de paquetes utiliza la distribución de probabilidad aleatoria del módulo `statistic` ($1/N$).
*   **Modo IPVS:** Construido sobre el framework Netfilter utilizando tablas hash de IP Virtual Server (IPVS) (complejidad $O(1)$). Utiliza estructuras de datos `ipset` para almacenar direcciones IP y puertos, reduciendo significativamente la profundidad de las cadenas de netfilter.
*   **Modo nftables:** Reemplaza el `iptables` heredado utilizando el bytecode moderno de `nftables` en el kernel. Ofrece un mejor escalamiento que `iptables` manteniendo tablas de estado explícitas sin la contención de bloqueos heredada.
*   **eBPF (Integrado en CNI, ej. Cilium):** Reemplaza completamente a `kube-proxy` compilando programas eBPF tipo C directamente en los hooks del kernel de capa de socket y eXtensible Data Path (XDP). Omite por completo el stack de netfilter para un enrutamiento directo $O(1)$.

### Matriz de Comparación Exhaustiva

| Característica / Métrica | Modo `iptables` | Modo `IPVS` | Modo `nftables` | `eBPF` (Reemplazo de kube-proxy) |
| :--- | :--- | :--- | :--- | :--- |
| **Subsistema del Kernel** | Netfilter (`iptables`) | IPVS & `ipset` | Netfilter (`nftables`) | eBPF (tc, socket ops, XDP) |
| **Complejidad Algorítmica** | $O(N)$ (Procesamiento secuencial de cadenas) | $O(1)$ (Búsqueda en tabla hash) | $O(\log N)$ / $O(1)$ (Búsquedas en conjuntos) | $O(1)$ (Búsqueda en mapa eBPF) |
| **Rendimiento de Sincronización de Reglas** | Lento a escala ($>5k$ Services); reemplazo atómico de cadena | Rápido ($>100k$ Endpoints); actualización dinámica | Rápido; transacción atómica de bytecode | Casi instantáneo; actualizaciones de mapa sin bloqueos |
| **Algoritmos de Balanceo de Carga** | Probabilidad aleatoria (módulo `statistic`) | Round-Robin, Least-Conn, Source/Dest Hash, Weighted | Random ponderado, Conjuntos | Round-Robin, Maglev, Least-Conn, Random |
| **Requerimiento de Privilegios en el Host** | `CAP_NET_ADMIN`, `CAP_NET_RAW` | `CAP_NET_ADMIN`, `CAP_NET_RAW` + módulos del kernel IPVS | `CAP_NET_ADMIN` | `CAP_BPF`, `CAP_NET_ADMIN`, `CAP_SYS_ADMIN` |
| **Preservación de IP de Origen** | Requiere `externalTrafficPolicy: Local` | Requiere `externalTrafficPolicy: Local` | Requiere `externalTrafficPolicy: Local` | Soporte nativo para Direct Server Return (DSR) |
| **Dependencia de Conntrack** | Alta (Fuerte dependencia de `nf_conntrack`) | Alta (Utiliza `ip_vs` y `nf_conntrack`) | Moderada | Baja / Opcional (Omite `conntrack`) |

---

## 3. Manifestos de Infraestructura y YAML Listos para Producción

### 3.1 ConfigMap de `KubeProxyConfiguration` Asegurado (Hardened)

Este manifesto aplica endurecimiento de seguridad (hardening): vinculando explícitamente métricas a IPs locales/internas, restringiendo interfaces de NodePort, configurando el modo IPVS con ARP estricto para compatibilidad con CNI (ej. MetalLB/Cilium) y ajustando los límites de `conntrack` de Linux para prevenir condiciones de Denegación de Servicio (DoS).

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy-production-config
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-proxy
    app.kubernetes.io/part-of: kube-system
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "ipvs"
    bindAddress: "0.0.0.0"
    healthzBindAddress: "127.0.0.1:10256"
    metricsBindAddress: "127.0.0.1:10249"
    enableProfiling: false
    showHiddenMetricsForVersion: ""
    clientConnection:
      acceptContentTypes: ""
      burst: 100
      contentType: "application/vnd.kubernetes.protobuf"
      qps: 50
    iptables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 2s
      syncPeriod: 30s
      localhostNodePorts: true
    ipvs:
      minSyncPeriod: 2s
      syncPeriod: 30s
      scheduler: "rr"
      strictARP: true
      tcpTimeout: 0s
      tcpFinTimeout: 0s
      udpTimeout: 0s
      excludeCIDRs: []
    nodePortAddresses:
      - "10.240.0.0/16"
    conntrack:
      maxPerCore: 32768
      min: 131072
      tcpEstablishedTimeout: 86400s
      tcpCloseWaitTimeout: 1h
```

### 3.2 Manifesto de DaemonSet de `kube-proxy` Seguro

Este manifesto adopta las mejores prácticas de seguridad: eliminando capabilities innecesarias, ejecutándose con un `readOnlyRootFilesystem`, aplicando un entorno no-root cuando es posible (con capabilities de red de Linux requeridas explícitas), configurando contextos de seguridad y asignando solicitudes (requests) y límites estrictos de recursos.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    k8s-app: kube-proxy
    app.kubernetes.io/name: kube-proxy
    app.kubernetes.io/component: network
spec:
  selector:
    matchLabels:
      k8s-app: kube-proxy
  template:
    metadata:
      labels:
        k8s-app: kube-proxy
    spec:
      hostNetwork: true
      priorityClassName: system-node-critical
      serviceAccountName: kube-proxy
      terminationGracePeriodSeconds: 30
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
          effect: NoSchedule
        - operator: Exists
          effect: NoExecute
      securityContext:
        runAsNonRoot: false
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kube-proxy
          image: registry.k8s.io/kube-proxy:v1.30.2
          command:
            - /usr/local/bin/kube-proxy
            - --config=/var/lib/kube-proxy/config.conf
            - --v=2
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - NET_ADMIN
                - NET_RAW
                - SYS_MODULE
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: kube-proxy-config
              mountPath: /var/lib/kube-proxy
            - name: xtables-lock
              mountPath: /run/xtables.lock
              readOnly: false
            - name: sys-fs
              mountPath: /sys
              readOnly: true
            - name: modules
              mountPath: /lib/modules
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 10256
              host: 127.0.0.1
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 10256
              host: 127.0.0.1
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
      volumes:
        - name: kube-proxy-config
          configMap:
            name: kube-proxy-production-config
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
        - name: sys-fs
          hostPath:
            path: /sys
            type: Directory
        - name: modules
          hostPath:
            path: /lib/modules
            type: Directory
```

### 3.3 Manifesto de Service de Producción Zero-Trust con Preservación de IP de Origen

Este Service aprovecha `externalTrafficPolicy: Local` para preservar las IPs de origen del cliente para auditoría de ingress y utiliza `internalTrafficPolicy: Local` para mantener el tráfico intra-nodo de forma local, eliminando saltos de red adicionales.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-gateway-secure
  namespace: production
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/component: api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  internalTrafficPolicy: Local
  allocateLoadBalancerNodePorts: true
  selector:
    app.kubernetes.io/name: payment-gateway
  ports:
    - name: https
      port: 443
      targetPort: 8443
      nodePort: 32443
      protocol: TCP
```

---

## 4. Comandos CLI Reales y Salidas de Terminal

### 4.1 Verificación del Estado de Despliegue y Salud de kube-proxy

```bash
$ kubectl get daemonset kube-proxy -n kube-system -o wide
```
**Salida Esperada:**
```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE   CONTAINERS   IMAGES                                  SELECTOR
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   42d   kube-proxy   registry.k8s.io/kube-proxy:v1.30.2   k8s-app=kube-proxy
```

```bash
$ kubectl exec -n kube-system ds/kube-proxy -- curl -s http://127.0.0.1:10256/healthz
```
**Salida Esperada:**
```
{"lastUpdated": "2026-08-07 19:30:00.123456789 +0000 UTC m=+1234.567890123", "currentTime": "2026-08-07 19:30:05.123456789 +0000 UTC m=+1239.567890123"}
```

### 4.2 Inspección de Reglas en Modo `iptables` en un Nodo del Cluster

```bash
$ sudo iptables -t nat -L KUBE-SERVICES -n -v | head -n 15
```
**Salida Esperada:**
```
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination         
    0     0 KUBE-SVC-NPXIX4V234123  tcp  --  *      *       0.0.0.0/0            10.96.0.10           /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
  142  8520 KUBE-SVC-T425234123412  tcp  --  *      *       0.0.0.0/0            10.96.14.22          /* production/payment-gateway-secure:https cluster IP */ tcp dpt:443
 1204 72240 KUBE-NODEPORTS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; terminating search */ ADDRTYPE match dst-type LOCAL
```

```bash
$ sudo iptables -t nat -L KUBE-SVC-T425234123412 -n -v
```
**Salida Esperada:**
```
Chain KUBE-SVC-T425234123412 (1 references)
 pkts bytes target     prot opt in     out     source               destination         
   71  4260 KUBE-SEP-AAAA11112222  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */ statistic mode random probability 0.50000000000
   71  4260 KUBE-SEP-BBBB33334444  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */
```

### 4.3 Inspección de Tablas de Servidores Virtuales `IPVS` e IP Sets

```bash
$ sudo ipvsadm -ln -t 10.96.14.22:443
```
**Salida Esperada:**
```
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.14.22:443 rr
  -> 10.244.1.45:8443             Masq    1      0          0         
  -> 10.244.2.89:8443             Masq    1      0          0         
```

```bash
$ sudo ipset list KUBE-CLUSTER-IP | head -n 12
```
**Salida Esperada:**
```
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 5
Header: family inet hashsize 1024 maxelem 65536 timeout 0 dynamic
Size in memory: 528 bytes
References: 2
Members:
10.96.0.1,tcp:443
10.96.0.10,udp:53
10.96.0.10,tcp:53
10.96.14.22,tcp:443
```

---

## 5. Guía de Verificación y Resolución de Problemas (Troubleshooting)

### Diagrama de Flujo de Decisión Diagnóstica

```
                          [ Issue: Service Unreachable or High Latency ]
                                                |
                                                v
                                  [ Check kube-proxy Pod Logs ]
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
             (Kernel Netfilter Error)                               (API Error)
                      |                                                   |
                      v                                                   v
        [ Inspect conntrack & iptables ]                       [ Check RBAC & APIServer ]
                      |                                                   |
         +------------+------------+                             +--------+--------+
         |                         |                             |                 |
  (Table Full)             (Lock Contention)              (Token Expired)    (Watch Timeout)
         |                         |                             |                 |
         v                         v                             v                 v
[Increase sysctl      [Tune minSyncPeriod &        [Verify SA secret &    [Inspect APIServer
  conntrack_max]       switch mode to IPVS]         ClusterRoleBinding]    etcd health]
```

### Problema 1: Agotamiento de la Tabla de Seguimiento de Conexiones (`nf_conntrack: table full`)

*   **Síntoma:** Tiempos de espera (timeouts) de conexión intermitentes, paquetes TCP SYN descartados, la salida de `dmesg` muestra `nf_conntrack: table full, dropping packet`.
*   **Causa Raíz:** El tráfico de red excede los límites asignados de seguimiento de conexiones del kernel de Linux definidos por `net.netfilter.nf_conntrack_max`.

**Comandos de Diagnóstico:**
```bash
$ sudo sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
```
*Salida:*
```
net.netfilter.nf_conntrack_count = 262144
net.netfilter.nf_conntrack_max = 262144
```

**Estrategia de Resolución:**
Actualizar la configuración de `conntrack` en el ConfigMap de `KubeProxyConfiguration` (o directamente a través de `sysctl` en el host):
```bash
$ sudo sysctl -w net.netfilter.nf_conntrack_max=524288
```

---

### Problema 2: Pérdida de IP de Origen y Fallos Asimétricos en Health Checks (`externalTrafficPolicy: Local`)

*   **Síntoma:** Los target groups de LoadBalancer de ingress reportan nodos worker como `Unhealthy`, o los Pods de backend reciben tráfico con las IPs de los nodos en lugar de las IPs de los clientes.
*   **Causa Raíz:** Cuando se configura `externalTrafficPolicy: Local`, `kube-proxy` descarta el tráfico enrutado a nodos que **no ejecutan una instancia local del Pod de destino**. Si el Cloud Load Balancer enruta tráfico a un nodo sin Pods de endpoint locales, se producen caídas de conexión.

**Comandos de Diagnóstico:**
```bash
$ kubectl get endpointslice -l kubernetes.io/service-name=payment-gateway-secure
```
*Salida:*
```
NAME                           ADDRESSTYPE   PORTS   ENDPOINTS                  AGE
payment-gateway-secure-7x9zk   IPv4          8443    10.244.1.45,10.244.1.46   12m
```

```bash
$ kubectl get service payment-gateway-secure -n production -o jsonpath='{.spec.externalTrafficPolicy}'
```
*Salida:*
```
Local
```

**Estrategia de Resolución:**
Asegurar que los balanceadores de carga externos utilicen el puerto de nodo de health check expuesto dinámicamente por `kube-proxy` para Services con `externalTrafficPolicy: Local`.
```bash
$ kubectl get service payment-gateway-secure -n production -o jsonpath='{.spec.healthCheckNodePort}'
```
*Salida:*
```
31892
```
Configurar los balanceadores de carga externos para realizar sondeos (polling) HTTP `GET /healthz` en el puerto `31892` a través de todas las IPs de los nodos. Los nodos que devuelvan `200 OK` poseen endpoints de pods locales; los nodos que devuelvan `503 Service Unavailable` no tienen endpoints locales y serán eliminados de la rotación del balanceador de carga.

---

### Problema 3: Exposición Inadvertida mediante Vinculación a `0.0.0.0` en NodePort

*   **Síntoma:** Los escáneres de seguridad activan alertas indicando que los servicios internos del cluster son accesibles a través de la interfaz WAN pública del nodo sobre `NodePort`.
*   **Causa Raíz:** `kube-proxy` crea por defecto reglas para todas las direcciones IP del host local.

**Comandos de Diagnóstico:**
```bash
$ sudo iptables -t nat -L KUBE-NODEPORTS -n -v
```
*Salida:*
```
Chain KUBE-NODEPORTS (1 references)
 pkts bytes target     prot opt in     out     source               destination         
   15   900 KUBE-SVC-T425234123412  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */ tcp dpt:32443
```

**Estrategia de Resolución:**
Restringir `kube-proxy` para vincular NodePorts estrictamente a la interfaz de red de administración interna del nodo modificando `nodePortAddresses` en `KubeProxyConfiguration`:
```yaml
nodePortAddresses:
  - "10.240.0.0/16"
```
Volver a aplicar el ConfigMap y realizar un reinicio progresivo (rolling restart) del DaemonSet de `kube-proxy`:
```bash
$ kubectl rollout restart daemonset/kube-proxy -n kube-system
```

---

### Problema 4: Contención de Bloqueo de `iptables-restore` Bajo Alto Tráfico/Cambio (High Churn)

*   **Síntoma:** La utilización de CPU del pod de `kube-proxy` se dispara al 100% y los logs muestran advertencias repetidas de `waiting for lock /run/xtables.lock` o timeouts de sincronización.
*   **Causa Raíz:** Los eventos rápidos de creación/eliminación de pods (ej. despliegues con autoscaling) invocan llamadas concurrentes a `iptables` que compiten por el `xtables.lock` del sistema.

**Comandos de Diagnóstico:**
```bash
$ kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=100 | grep -i "lock"
```
*Salida:*
```
E0807 19:35:12.890123       1 server.go:842] "Error syncing iptables rules" err="exit status 4: Another app is currently holding the xtables lock; waiting (1s)..."
```

**Estrategia de Resolución:**
1. Incrementar `minSyncPeriod` en `KubeProxyConfiguration` de `0s` a `2s` para agrupar (batch) las actualizaciones de reglas de red.
2. Migrar del modo `iptables` al modo `IPVS` o a redes CNI basadas en eBPF (como Cilium).

---

## 6. Referencias

*   **Documentación Oficial de Kubernetes – Virtual IPs and Service Proxies:**  
    https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies
*   **Referencia Oficial de Kubernetes – KubeProxyConfiguration (v1alpha1):**  
    https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
*   **Repositorio Oficial del Curriculum KCSA de la CNCF:**  
    https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
*   **Redes de Kubernetes – Preservación de IP de Origen:**  
    https://kubernetes.io/docs/tutorials/services/source-ip/
*   **Documentación de Linux Kernel Netfilter & IPVS:**  
    https://www.kernel.org/doc/Documentation/networking/ipvs-sysctl.txt