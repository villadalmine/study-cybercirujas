# 5.1 Understand connectivity between Pods

## El modelo de red de Kubernetes

Kubernetes define un modelo de red muy simple en su contrato, pero con implicancias profundas en cómo se implementa. Los requisitos fundamentales (el "Kubernetes networking model") son:

- **Todos los Pods pueden comunicarse con todos los demás Pods sin usar NAT**, sin importar en qué nodo estén corriendo.
- **Todos los nodos pueden comunicarse con todos los Pods sin NAT** (y viceversa).
- **La IP que un Pod ve de sí mismo es la misma IP que ven los demás** al hablarle (no hay traducción de direcciones dentro del cluster).

Esto significa que, a diferencia de Docker "clásico" (donde cada host tiene su propia red NAT-eada), en Kubernetes existe una **red plana (flat network)** a nivel de cluster: cada Pod recibe una IP única y enrutable dentro del cluster, y esa IP es válida para comunicarse con cualquier otro Pod, esté donde esté.

Kubernetes **no implementa esta red por sí mismo**: delega la tarea en plugins que cumplen la especificación **CNI (Container Network Interface)**.

## CNI (Container Network Interface)

CNI es una especificación (y un conjunto de librerías) que define cómo un runtime de contenedores (a través del kubelet) invoca a un plugin de red para:

1. Crear una interfaz de red dentro del namespace de red del Pod.
2. Asignarle una IP (vía IPAM — IP Address Management).
3. Configurar las rutas necesarias para que esa IP sea alcanzable en el cluster.

Plugins CNI comunes que pueden aparecer en el examen o en clusters reales:

- **Calico** (routing con BGP, o modo overlay con VXLAN/IPIP)
- **Flannel** (overlay simple, VXLAN por defecto)
- **Cilium** (basado en eBPF, alto rendimiento y políticas L3-L7)
- **Weave Net**

El plugin se configura típicamente en `/etc/cni/net.d/` en cada nodo, y su binario vive en `/opt/cni/bin/`.

```bash
# En un nodo, ver la configuración CNI activa
cat /etc/cni/net.d/10-calico.conflist

# Ver los binarios de plugins CNI disponibles
ls /opt/cni/bin/
```

## Conectividad dentro del mismo nodo

Cuando dos Pods están en el mismo nodo, la comunicación ocurre así:

1. Cada Pod tiene su propio **network namespace**, con una interfaz `eth0` propia.
2. Esa interfaz es un extremo de un **veth pair** (virtual ethernet pair); el otro extremo vive en el namespace de red del **host**.
3. El extremo del host se conecta a un **bridge** (por ejemplo `cni0` o `docker0`, según el plugin).
4. El tráfico entre dos Pods del mismo nodo simplemente atraviesa ese bridge, como si fueran dos máquinas en el mismo switch L2.

```bash
# Desde el nodo, ver las interfaces veth y el bridge
ip addr show cni0

# Ver qué veth corresponde a qué Pod
crictl inspect <container-id> | grep -A5 network
```

## Conectividad entre nodos

Cuando los Pods están en nodos distintos, el plugin CNI necesita que el tráfico llegue de la IP del Pod origen (en el nodo A) hasta la IP del Pod destino (en el nodo B), atravesando la red física entre nodos. Hay dos estrategias típicas:

- **Overlay network** (ej. Flannel VXLAN, Calico en modo IPIP/VXLAN): el tráfico entre Pods se encapsula dentro de paquetes UDP/IP entre las IPs de los nodos. Cada nodo tiene un daemon que desencapsula el paquete y lo entrega al Pod correcto. Funciona sin depender del router físico, pero agrega overhead de encapsulación.
- **Routing nativo** (ej. Calico en modo BGP): cada nodo anuncia las subredes de Pods que aloja mediante BGP, y los routers (o los propios nodos actuando como routers) enrutan el tráfico directamente, sin encapsular. Es más eficiente pero requiere que la red subyacente lo soporte.

En ambos casos, Kubernetes le asigna a cada nodo un **rango de IPs de Pods (PodCIDR)** que no se solapa con el de otros nodos:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.podCIDR}{"\n"}{end}'
# node-1: 10.244.0.0/24
# node-2: 10.244.1.0/24
```

## Verificar conectividad entre Pods (ejemplos prácticos)

Un escenario típico de examen: crear dos Pods y confirmar que se pueden alcanzar por IP.

```bash
kubectl run pod-a --image=nicolaka/netshoot --command -- sleep 3600
kubectl run pod-b --image=nginx

kubectl get pods -o wide
# NAME     READY   STATUS    IP            NODE
# pod-a    1/1     Running   10.244.1.5    node-1
# pod-b    1/1     Running   10.244.2.8    node-2
```

Probar conectividad directa por IP (sin pasar por Service ni DNS):

```bash
kubectl exec -it pod-a -- curl -s 10.244.2.8:80 | head -1
# <!DOCTYPE html>

kubectl exec -it pod-a -- ping -c 2 10.244.2.8
```

Inspeccionar la ruta que toma el tráfico dentro del Pod:

```bash
kubectl exec -it pod-a -- ip route
# default via 10.244.1.1 dev eth0
# 10.244.1.0/24 dev eth0 proto kernel scope link
```

## DNS y descubrimiento entre Pods

Aunque la resolución de nombres corresponde más al tema de Services, vale la pena notar que **CoreDNS** también resuelve registros A para Pods individuales (si el Pod pertenece a un Service headless, o vía el nombre generado automáticamente con guiones):

```bash
# Formato: <ip-con-guiones>.<namespace>.pod.cluster.local
kubectl exec -it pod-a -- nslookup 10-244-2-8.default.pod.cluster.local
```

Esto confirma que la conectividad IP-a-IP entre Pods es la base sobre la que se construyen Services, DNS e Ingress.

## Troubleshooting habitual

Checklist cuando dos Pods no se pueden comunicar:

```bash
# 1. Confirmar que ambos Pods están Running y con IP asignada
kubectl get pods -o wide

# 2. Revisar el estado del plugin CNI en los nodos involucrados
kubectl -n kube-system get pods -o wide | grep -E 'calico|flannel|cilium'

# 3. Ver logs del pod de red en el nodo problemático
kubectl -n kube-system logs <calico-node-xxxx>

# 4. Confirmar que el kubelet reportó bien el PodCIDR del nodo
kubectl describe node <node-name> | grep PodCIDR

# 5. Revisar si hay una NetworkPolicy bloqueando el tráfico (tema aparte, pero es la primera sospecha)
kubectl get networkpolicy -A

# 6. Verificar conectividad L3 entre los propios nodos (no solo los Pods)
ssh node-1 -- ping -c2 <ip-node-2>
```

Errores comunes en el examen: interfaces `cni0`/`flannel.1` caídas tras un reinicio del nodo, PodCIDR mal configurado en el controller-manager (`--cluster-cidr`), o un plugin CNI no instalado (Pods quedan en `ContainerCreating` indefinidamente por falta de red).

## Referencias

- Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- The Kubernetes Network Model — https://kubernetes.io/docs/concepts/services-networking/#the-kubernetes-network-model
- Container Network Interface (CNI) spec — https://github.com/containernetworking/cni
- Debug Services (incluye troubleshooting de conectividad) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- CKA Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf