# 3.4 Networking

## El modelo de red de Kubernetes

Kubernetes exige que cualquier implementación de red cumpla tres reglas fundamentales (el "Kubernetes networking model"):

1. Todos los Pods pueden comunicarse con todos los demás Pods sin necesidad de NAT, sin importar en qué Node estén.
2. Todos los Nodes pueden comunicarse con todos los Pods sin NAT.
3. La IP que un Pod ve de sí mismo es la misma IP que ven los demás.

Esto crea una red "flat" (plana): cada Pod recibe su propia IP única dentro del clúster (a diferencia de Docker standalone, donde los containers de un mismo host comparten namespace de red vía NAT). Dentro de un Pod, todos los containers comparten el mismo network namespace (misma IP, mismo espacio de puertos) gracias al **pause container** (o "infra container"), que es el primero en crearse y el que sostiene el namespace de red para el resto.

Kubernetes en sí **no implementa** esta red: delega la tarea en un plugin de **CNI (Container Network Interface)**.

## CNI (Container Network Interface)

CNI es una especificación (de la CNCF) que define cómo un runtime de containers debe invocar plugins de red para asignar IPs y conectar containers a la red. El kubelet invoca al plugin CNI configurado cada vez que se crea o destruye un Pod.

Plugins de CNI comunes:

- **Calico**: routing L3, soporta NetworkPolicy avanzadas, BGP.
- **Flannel**: simple, overlay con VXLAN, foco en conectividad básica (no implementa NetworkPolicy).
- **Cilium**: basado en **eBPF**, alto rendimiento, observabilidad y NetworkPolicy a nivel L3-L7.
- **Weave Net**: overlay con encriptación opcional.

Verificar el CNI instalado en un clúster:

```
$ kubectl get pods -n kube-system | grep -E 'calico|flannel|cilium|weave'
calico-node-4x2vp                         1/1     Running   0          10d
calico-kube-controllers-6f9c...           1/1     Running   0          10d
```

La configuración del plugin suele vivir en `/etc/cni/net.d/` en cada Node.

## Comunicación Pod-a-Pod y Service Discovery

Como las IPs de Pod son efímeras (cambian al recrearse el Pod), no se usan directamente para comunicación estable entre componentes. Para eso existe el objeto **Service**.

Un Service es una abstracción que define un conjunto lógico de Pods (vía `selector` con labels) y una política de acceso, exponiendo una IP virtual estable (**ClusterIP**) que enruta tráfico hacia los Pods "backend".

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

```
$ kubectl get svc web-svc
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.45.210   <none>        80/TCP    2m

$ kubectl get endpoints web-svc
NAME      ENDPOINTS                       AGE
web-svc   10.244.1.5:8080,10.244.2.7:8080   2m
```

El objeto **Endpoints** (o **EndpointSlice** en versiones recientes, más escalable) mantiene la lista actualizada de IPs de Pod que matchean el selector.

### Tipos de Service

| Tipo | Uso |
|---|---|
| **ClusterIP** (default) | IP interna, solo accesible dentro del clúster. |
| **NodePort** | Expone un puerto (30000-32767) en cada Node, redirigiendo al Service. |
| **LoadBalancer** | Provisiona un load balancer externo (vía cloud provider) que apunta al Service. |
| **ExternalName** | Mapea el Service a un nombre DNS externo (registro CNAME), sin proxy de tráfico. |

Ejemplo de NodePort:

```
$ kubectl get svc web-svc
NAME      TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-svc   NodePort   10.96.45.210   <none>        80:30080/TCP   1m
```

Cualquier Node del clúster expone ahora el puerto `30080` hacia el Service.

También existen los **Headless Services** (`clusterIP: None`), que no asignan IP virtual: la resolución DNS devuelve directamente las IPs de los Pods backend. Se usan mucho con StatefulSets, donde cada Pod necesita identidad de red propia.

## kube-proxy

**kube-proxy** corre como DaemonSet en cada Node y es el componente responsable de implementar la IP virtual del Service, programando reglas para redirigir el tráfico destinado al ClusterIP hacia alguno de los Pods backend (balanceo básico round-robin/random).

Modos de operación:

- **iptables** (default histórico): usa reglas de `iptables` en el kernel de Linux para hacer DNAT del ClusterIP hacia una IP de Pod.
- **IPVS** (IP Virtual Server): usa el subsistema de balanceo de carga del kernel, más eficiente en clústeres con miles de Services (evita el costo O(n) de recorrer reglas de iptables).
- **userspace** (modo legacy, en desuso).

```
$ iptables -t nat -L KUBE-SERVICES -n | grep web-svc
KUBE-SVC-XYZ123  tcp  --  0.0.0.0/0   10.96.45.210   /* default/web-svc */ tcp dpt:80
```

## DNS en Kubernetes

**CoreDNS** es el servidor DNS estándar del clúster (corre como Deployment en `kube-system`) y provee resolución de nombres para Services y Pods.

Cada Service obtiene un nombre DNS con el formato:

```
<service-name>.<namespace>.svc.cluster.local
```

```
$ kubectl run tmp --rm -it --image=busybox -- sh
/ # nslookup web-svc.default.svc.cluster.local
Server:    10.96.0.10
Name:      web-svc.default.svc.cluster.local
Address:   10.96.45.210
```

El resolver de cada Pod se configura automáticamente vía `/etc/resolv.conf`, apuntando al ClusterIP de CoreDNS (típicamente `10.96.0.10` o similar, expuesto por el Service `kube-dns`).

## Ingress e Ingress Controller

Un **Service** de tipo LoadBalancer aprovisiona un balanceador por Service (costoso en cloud). Para exponer múltiples servicios HTTP/HTTPS bajo una sola IP externa, con routing por host/path, se usa **Ingress**.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-svc
                port:
                  number: 80
```

El objeto Ingress es solo una **especificación de reglas**; requiere un **Ingress Controller** (NGINX Ingress Controller, Traefik, HAProxy, Contour, etc.) corriendo en el clúster que efectivamente implemente el routing (Kubernetes no trae uno por defecto).

```
$ kubectl get ingress web-ingress
NAME           CLASS   HOSTS             ADDRESS         PORTS   AGE
web-ingress    nginx   app.example.com   203.0.113.10    80      5m
```

> Nota: la API moderna sucesora de Ingress es la **Gateway API** (`gateway.networking.k8s.io`), que separa roles (infraestructura vs. rutas de aplicación) y soporta más protocolos además de HTTP.

## NetworkPolicy

Por defecto, el tráfico entre Pods es completamente permitido ("allow all"). **NetworkPolicy** permite restringir el tráfico ingress/egress a nivel de Pod, funcionando como un firewall declarativo (requiere que el CNI lo soporte: Calico, Cilium, Weave sí; Flannel puro no).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-only
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

Esta policy solo permite tráfico entrante hacia Pods con label `app: backend` en el puerto 8080, y únicamente desde Pods con label `app: frontend`. Cualquier otro origen queda bloqueado.

## Service Mesh (mención conceptual)

Un **Service Mesh** (ej. **Istio**, **Linkerd**) agrega una capa de red de aplicación entre los Pods, típicamente inyectando un **sidecar proxy** (ej. Envoy) en cada Pod para manejar mTLS, retries, circuit breaking, observabilidad (métricas/tracing) y traffic shifting (canary, blue-green), sin cambiar el código de la aplicación. KCNA no exige configurarlo, solo reconocer el concepto y su propósito dentro de la arquitectura cloud native.

## Referencias

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs, *Cluster Networking*: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes docs, *Service*: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes docs, *Ingress*: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes docs, *Ingress Controllers*: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes docs, *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs, *DNS for Services and Pods*: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- CNI project: https://github.com/containernetworking/cni
- Kubernetes docs, *Gateway API*: https://gateway-api.sigs.k8s.io/
- Istio docs: https://istio.io/latest/docs/concepts/what-is-istio/