# CoreDNS en Kubernetes

## ¿Qué es CoreDNS?

CoreDNS es el servidor DNS que Kubernetes usa por defecto (desde la v1.13, reemplazando a `kube-dns`) para proveer *service discovery* dentro del clúster. Es un proyecto de la CNCF, escrito en Go, cuya arquitectura se basa en una cadena de **plugins**: cada request DNS pasa por una serie de middlewares configurables que resuelven, cachean, reescriben o reenvían la consulta.

En un clúster estándar, CoreDNS corre como un `Deployment` en el namespace `kube-system`, expuesto internamente mediante un `Service` de tipo `ClusterIP` llamado `kube-dns` (el nombre se mantiene por compatibilidad histórica, aunque el binario sea CoreDNS).

```bash
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get svc kube-dns
```

Salida típica:

```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           10d

NAME       TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10    <none>        53/UDP,53/TCP,9153/TCP   10d
```

Todos los Pods del clúster reciben, vía `kubelet`, la IP de este Service como `nameserver` en su `/etc/resolv.conf` (comportamiento controlado por el campo `dnsPolicy` del Pod, ver más abajo).

## Arquitectura y funcionamiento

- CoreDNS se despliega típicamente con 2 réplicas (para HA), gestionadas por un `Deployment` con anti-affinity para distribuirlas entre nodos.
- Su configuración vive en un `ConfigMap` llamado `coredns` en `kube-system`, montado como archivo `Corefile` dentro del Pod.
- Usa el plugin `kubernetes` para consultar la API server (vía *watch*) y resolver dinámicamente los registros de Services y Pods, sin depender de `etcd` directamente ni de un backend externo.

```bash
kubectl -n kube-system get configmap coredns -o yaml
```

## El Corefile

El `Corefile` define zonas y la cadena de plugins que se aplica a cada una. Ejemplo por defecto (kubeadm):

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

Plugins clave para el examen:

| Plugin | Función |
|---|---|
| `kubernetes` | Resuelve DNS para Services y Pods consultando la API de Kubernetes |
| `forward` | Reenvía queries que no son del dominio del clúster (ej. internet) al DNS del nodo (`/etc/resolv.conf`) o a servidores upstream explícitos |
| `cache` | Cachea respuestas por el TTL indicado (en segundos) para reducir carga sobre la API |
| `loop` | Detecta loops de forwarding y aborta el proceso si encuentra uno (evita bucles infinitos) |
| `reload` | Permite recargar el `Corefile` automáticamente sin reiniciar el Pod cuando cambia el `ConfigMap` |
| `loadbalance` | Round-robin de registros A/AAAA para repartir carga entre múltiples IPs |
| `errors` / `health` / `ready` | Logging de errores y endpoints de *liveness*/*readiness* para el propio CoreDNS |

Editar el comportamiento de DNS del clúster (por ejemplo, agregar un *stub domain* o cambiar el upstream) se hace editando este ConfigMap:

```bash
kubectl -n kube-system edit configmap coredns
```

Gracias al plugin `reload`, los cambios se aplican solos en unos segundos (no hace falta reiniciar los Pods de CoreDNS), aunque en la práctica muchos operadores igual fuerzan un rollout:

```bash
kubectl -n kube-system rollout restart deployment coredns
```

## Convención de nombres DNS

CoreDNS genera registros automáticamente según el estado del clúster:

**Services**

```
<service-name>.<namespace>.svc.cluster.local
```

- `ClusterIP` Service → registro **A/AAAA** apuntando a la ClusterIP.
- Service **headless** (`clusterIP: None`) → registro **A/AAAA** por cada Pod backend (útil para StatefulSets).
- Service `ExternalName` → registro **CNAME** apuntando al valor de `externalName`.
- Cada puerto nombrado del Service genera además un registro **SRV**:
  `_<port-name>._<protocol>.<service>.<namespace>.svc.cluster.local`

**Pods**

```
<pod-ip-con-guiones>.<namespace>.pod.cluster.local
```

Ejemplo: la IP `10.244.1.5` en el namespace `default` resuelve como `10-244-1-5.default.pod.cluster.local`.

`cluster.local` es el *cluster domain* por defecto, configurable al bootstrapear el clúster (kubeadm: `--service-dns-domain`).

### Ejemplo práctico

```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80
kubectl run test --image=busybox:1.28 --rm -it --restart=Never -- \
  nslookup nginx.default.svc.cluster.local
```

Salida esperada:

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      nginx.default.svc.cluster.local
Address 1: 10.96.5.23 nginx.default.svc.cluster.local
```

Dentro del mismo namespace basta con el nombre corto (`nginx`); entre namespaces distintos se necesita al menos `nginx.default`, gracias a los *search domains*.

## `/etc/resolv.conf` dentro de un Pod

```bash
kubectl exec test -- cat /etc/resolv.conf
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` indica que cualquier nombre con menos de 5 puntos se prueba primero contra cada dominio de `search` antes de considerarse un FQDN absoluto — esto explica por qué resolver nombres externos (ej. `google.com`) desde un Pod genera varias consultas internas antes del `forward` exitoso, y es un punto común de latencia/DNS *throttling* en clústeres grandes.

## `dnsPolicy` y `dnsConfig` del Pod

El campo `spec.dnsPolicy` controla qué `resolv.conf` recibe el Pod:

- `ClusterFirst` (default): usa CoreDNS para el dominio del clúster y reenvía el resto al upstream configurado en CoreDNS.
- `Default`: hereda el `resolv.conf` del nodo donde corre el Pod (**no** usa CoreDNS).
- `ClusterFirstWithHostNet`: igual a `ClusterFirst` pero para Pods con `hostNetwork: true` (que de otro modo caerían en `Default`).
- `None`: ignora cualquier resolución automática; requiere `dnsConfig` explícito.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-dns
spec:
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 1.1.1.1
    searches:
      - custom.svc.cluster.local
    options:
      - name: ndots
        value: "2"
  containers:
    - name: app
      image: busybox:1.28
      command: ["sleep", "3600"]
```

## Troubleshooting de CoreDNS

Checklist típico de examen ante fallas de resolución DNS:

```bash
# 1. ¿Están los Pods de CoreDNS corriendo?
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide

# 2. Logs (buscar errores de forwarding, SERVFAIL, loops)
kubectl -n kube-system logs -l k8s-app=kube-dns

# 3. ¿El Service kube-dns tiene endpoints?
kubectl -n kube-system get endpoints kube-dns

# 4. Test de resolución desde un Pod efímero
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
  --rm -it --restart=Never -- /agnhost dnsutils
# o con busybox clásico:
kubectl run -it --rm dns-test --image=busybox:1.28 --restart=Never -- \
  nslookup kubernetes.default

# 5. Revisar la config activa
kubectl -n kube-system get configmap coredns -o yaml

# 6. Revisar CoreDNS "desde adentro" (métricas Prometheus en :9153)
kubectl -n kube-system port-forward deploy/coredns 9153:9153
```

Causas comunes de falla:

- CoreDNS `CrashLoopBackOff` por un `Corefile` mal editado (YAML/plugin inválido) → revisar `kubectl -n kube-system describe pod` y logs.
- Endpoints vacíos en el Service `kube-dns` → problema del CNI (los Pods de CoreDNS no llegan a `Ready` porque no hay red de Pod funcionando).
- `NetworkPolicy` bloqueando tráfico al puerto 53 desde otros namespaces.
- Loop de DNS (`forward . /etc/resolv.conf` en un nodo cuyo `resolv.conf` apunta de vuelta al propio CoreDNS) → el plugin `loop` lo detecta y el Pod entra en `CrashLoopBackOff` con el error `Loop (127.0.0.1:...) detected for zone "."`.
- `ndots` alto sumado a resolución de nombres externos frecuente → latencia/timeout en apps que hacen muchísimas queries salientes.

## NodeLocal DNSCache

Para reducir la carga sobre CoreDNS y la latencia de DNS en clústeres grandes, Kubernetes soporta **NodeLocal DNSCache**: un `DaemonSet` que corre un caché DNS en cada nodo (vía `link-local` IP, típicamente `169.254.20.10`), interceptando las queries antes de que lleguen al CoreDNS central. No reemplaza a CoreDNS, sino que actúa como caché local por nodo.

```bash
kubectl -n kube-system get pods -l k8s-app=node-local-dns
```

## Referencias

- DNS for Services and Pods — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Customizing DNS Service (CoreDNS) — https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Debugging DNS Resolution — https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- CoreDNS project docs — https://coredns.io/manual/toc/
- CoreDNS plugins reference — https://coredns.io/plugins/
- NodeLocal DNSCache — https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Pod's DNS Policy (`dnsPolicy`/`dnsConfig`) — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pod-s-dns-policy
- CKA Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf