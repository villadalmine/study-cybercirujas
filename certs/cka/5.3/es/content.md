# 5.3 Service types: ClusterIP, NodePort, LoadBalancer y Endpoints

**Peso en el examen: 3.33**

## Por qué existen los Services

Los Pods son efímeros: cuando un Pod muere y es reemplazado (por un Deployment, un ReplicaSet, etc.), recibe una IP nueva. Si otras aplicaciones dependieran de esa IP directamente, cada reinicio rompería la comunicación. Un `Service` resuelve esto dando una identidad de red **estable** (una ClusterIP virtual y un nombre DNS) a un conjunto de Pods, seleccionados mediante `labels` (`selector`).

El componente que hace que el tráfico dirigido a esa IP virtual llegue efectivamente a los Pods correctos es **kube-proxy**, corriendo en cada Node.

## ClusterIP (default)

Expone el Service en una IP interna del clúster, alcanzable solo desde dentro del clúster (otros Pods, otros Nodes). Es el tipo por defecto si no se especifica `type`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80        # puerto del Service
      targetPort: 8080 # puerto del container
      protocol: TCP
```

```bash
kubectl apply -f web-svc.yaml
kubectl get svc web-svc
```

```
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.44.211   <none>        80/TCP    5s
```

Cualquier Pod del clúster puede alcanzarlo por IP (`10.96.44.211:80`) o por DNS (`web-svc.default.svc.cluster.local`, resuelto por CoreDNS).

Forma rápida de crear uno equivalente con imperativo:

```bash
kubectl expose deployment web --port=80 --target-port=8080 --name=web-svc
```

## NodePort

Además de la ClusterIP, abre un puerto fijo (por defecto en el rango `30000-32767`) en **todos los Nodes** del clúster. El tráfico a `<NodeIP>:<nodePort>` se redirige al Service, sin importar en qué Node corra realmente el Pod destino.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080   # opcional; si se omite, se asigna uno automático
```

```bash
kubectl get svc web-nodeport
```

```
NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-nodeport   NodePort   10.96.90.12    <none>        80:30080/TCP   10s
```

```bash
curl http://<cualquier-node-ip>:30080
```

Un `NodePort` implica automáticamente una ClusterIP (el NodePort se construye sobre ella). Es útil para pruebas o entornos sin balanceador externo.

## LoadBalancer

Extiende `NodePort` pidiéndole al proveedor de nube (o a un controlador como MetalLB en on-prem) que aprovisione un balanceador de carga externo con IP pública, que reenvía tráfico hacia los NodePorts del clúster.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-lb
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

```bash
kubectl get svc web-lb
```

```
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)        AGE
web-lb   LoadBalancer   10.96.5.201   203.0.113.10    80:31445/TCP   2m
```

Mientras `EXTERNAL-IP` esté en `<pending>`, significa que no hay ningún controlador en el clúster capaz de aprovisionar el balanceador (típico en clústeres bare-metal sin MetalLB u otro `LoadBalancer` controller instalado). En ese estado, el Service sigue siendo alcanzable como `NodePort`.

## Endpoints y EndpointSlices

Un Service con `selector` genera automáticamente un objeto `Endpoints` (y, en clústeres modernos, uno o más `EndpointSlice`) con las IPs y puertos de los Pods que matchean las labels y están **Ready**.

```bash
kubectl get endpoints web-svc
```

```
NAME      ENDPOINTS                         AGE
web-svc   10.244.1.5:8080,10.244.2.7:8080   3m
```

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-svc
kubectl describe endpointslice web-svc-xk2lp
```

Si `ENDPOINTS` aparece `<none>`, la causa casi siempre es una de estas:

- El `selector` del Service no matchea las `labels` de ningún Pod.
- Los Pods existen pero no pasan sus **readiness probes** (un Pod no-Ready se excluye de Endpoints).
- Se apunta a un `targetPort` que no coincide con el puerto real que escucha el container.

```bash
kubectl get pods --show-labels
kubectl describe svc web-svc   # muestra Selector y Endpoints juntos
```

También se puede crear un Service **sin** `selector`, y gestionar manualmente el objeto `Endpoints` (o `EndpointSlice`) — útil para apuntar a un servicio externo al clúster con una identidad interna estable:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db
spec:
  ports:
    - port: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: external-db   # debe coincidir con el nombre del Service
subsets:
  - addresses:
      - ip: 192.168.1.50
    ports:
      - port: 5432
```

## Multi-port Services

Un mismo Service puede exponer varios puertos; en ese caso cada puerto necesita `name`:

```yaml
spec:
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9090
      targetPort: 9090
```

## externalTrafficPolicy y Session Affinity

- `externalTrafficPolicy: Cluster` (default): el tráfico externo puede llegar a cualquier Node y ser reenviado a un Pod en otro Node (posible extra hop, pero balanceo parejo).
- `externalTrafficPolicy: Local`: el tráfico solo se enruta a Pods del mismo Node que recibió la conexión; preserva la IP origen del cliente, pero si ese Node no tiene un Pod local, la conexión se dropea.

```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
```

- `sessionAffinity: ClientIP`: fuerza que las requests de un mismo cliente vayan siempre al mismo Pod (por defecto es `None`, round-robin vía reglas de iptables/IPVS).

```yaml
spec:
  sessionAffinity: ClientIP
```

## kube-proxy: cómo se implementa el enrutamiento

`kube-proxy` observa el API server y traduce Services/Endpoints en reglas de red locales en cada Node. Dos modos comunes:

- **iptables** (histórico default): reglas `DNAT` que seleccionan un Pod al azar por Service.
- **IPVS**: usa el balanceador de kernel `IPVS`, más eficiente con muchos Services, soporta más algoritmos de balanceo (round-robin, least connection, etc.).

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```

```
mode: "ipvs"
```

## Comandos de diagnóstico clave

```bash
kubectl get svc -A
kubectl describe svc <nombre>
kubectl get endpoints <nombre>
kubectl get endpointslices
kubectl run tmp --rm -it --image=busybox -- wget -qO- http://<svc-name>:<port>
kubectl get pods -o wide --selector=app=web
```

## Referencias

- Kubernetes docs — Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes docs — Connecting Applications with Services: https://kubernetes.io/docs/tutorials/services/connect-applications-service/
- Kubernetes docs — EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Kubernetes docs — Service Traffic Policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Kubernetes docs — kube-proxy: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
