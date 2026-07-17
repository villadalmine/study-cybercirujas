# 5.2 Provide and troubleshoot access to applications via services

## Por qué existen los Services

Los Pods son efímeros: cuando un Pod muere y es reemplazado (por un Deployment, un ReplicaSet, etc.), recibe una IP nueva. Si otras aplicaciones dependieran directamente de la IP del Pod, cada reinicio rompería la conectividad. Un **Service** resuelve este problema proveyendo un endpoint estable (IP virtual + nombre DNS) que enruta el tráfico hacia el conjunto de Pods que cumplen con un `selector` de labels, sin importar cuántas veces esos Pods cambien.

## Cómo un Service selecciona sus Pods

Un Service usa `spec.selector` para encontrar Pods por sus labels. El control plane mantiene automáticamente un objeto `Endpoints` (o `EndpointSlice` en clusters modernos) con las IP:puerto de los Pods que matchean, y solo incluye Pods cuyos containers pasan el **readiness probe**. Un Pod `Running` pero `NotReady` es removido de los Endpoints, aunque siga sirviendo tráfico técnicamente.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80          # puerto expuesto por el Service
      targetPort: 8080  # puerto real donde escucha el container
  type: ClusterIP
```

Tres puertos que se confunden con frecuencia en el examen:

| Campo | Dónde vive | Qué representa |
|---|---|---|
| `port` | Service | Puerto en el que otros clientes contactan al Service |
| `targetPort` | Service → Pod | Puerto en el que escucha el container dentro del Pod |
| `nodePort` | Service (tipo NodePort) | Puerto abierto en cada Node del cluster (30000-32767) |

## Tipos de Service

- **ClusterIP** (default): IP virtual interna, solo alcanzable dentro del cluster.
- **NodePort**: además de la ClusterIP, expone un puerto fijo en cada Node (`<NodeIP>:<nodePort>`). Útil para acceso externo simple o pruebas.
- **LoadBalancer**: pide a la infraestructura cloud un balanceador externo (crea NodePort + ClusterIP internamente). Sin cloud provider, `EXTERNAL-IP` queda en `<pending>`.
- **ExternalName**: no tiene selector ni Endpoints; mapea el Service a un nombre DNS externo vía un registro `CNAME`. Sirve para referenciar servicios fuera del cluster con un nombre interno consistente.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-externo
spec:
  type: ExternalName
  externalName: db.miempresa.com
```

### Headless Service

Con `clusterIP: None` no se asigna IP virtual ni se hace load balancing vía kube-proxy. La consulta DNS del Service devuelve directamente las IPs de todos los Pods backing (un registro `A`/`AAAA` por Pod). Es el mecanismo que usan StatefulSets para dar identidad de red estable a cada réplica.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-headless
spec:
  clusterIP: None
  selector:
    app: db
  ports:
    - port: 5432
```

## Crear Services rápido con imperative commands

```bash
kubectl create deployment web --image=nginx --replicas=3

# Expone el Deployment como ClusterIP
kubectl expose deployment web --port=80 --target-port=80 --name=web

# Expone como NodePort explícito
kubectl expose deployment web --port=80 --target-port=80 --type=NodePort --name=web-np
```

```bash
kubectl get svc web
```
```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.45.201   <none>        80/TCP    5s
```

## DNS interno de servicios

CoreDNS registra automáticamente cada Service con el patrón:

```
<service-name>.<namespace>.svc.cluster.local
```

Desde cualquier Pod del mismo namespace alcanza con `web`; desde otro namespace hace falta `web.default.svc.cluster.local` (o `web.default`).

```bash
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web.default.svc.cluster.local
```
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web.default.svc.cluster.local
Address:   10.96.45.201
```

## Session affinity

Por defecto cada request se puede balancear a un Pod distinto. Para pegar un cliente al mismo Pod durante un período (útil con apps stateful sin session store externo):

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

## Troubleshooting

El flujo típico de diagnóstico va de "afuera hacia adentro": Service → Endpoints → Pods → Container.

### 1. El Service no tiene Endpoints

Es la causa más común de "no puedo llegar a mi app". Normalmente el `selector` del Service no matchea las labels reales del Pod.

```bash
kubectl get endpoints web
```
```
NAME   ENDPOINTS   AGE
web    <none>      2m
```

```bash
kubectl describe svc web
```
```
Name:              web
Selector:          app=web
...
Endpoints:         <none>
```

```bash
kubectl get pods --show-labels
```
```
NAME              READY   STATUS    RESTARTS   AGE   LABELS
web-6b9f7c-abcde  1/1     Running   0          3m    app=frontend
```

El Pod tiene `app=frontend` pero el Service busca `app=web`: mismatch. Se corrige alineando labels o selector:

```bash
kubectl label pod web-6b9f7c-abcde app=web --overwrite
```

### 2. El Pod matchea pero sigue sin aparecer en Endpoints

Revisar el readiness probe: si falla, el Pod queda fuera de Endpoints aunque `STATUS` diga `Running`.

```bash
kubectl get pods -o wide
```
```
NAME              READY   STATUS    RESTARTS   AGE
web-6b9f7c-abcde  0/1     Running   0          1m
```

`0/1` en `READY` es la señal: el container corre, pero el readiness check no pasa.

```bash
kubectl describe pod web-6b9f7c-abcde
```
```
Warning  Unhealthy  10s  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
```

### 3. `targetPort` no coincide con el puerto real del container

Endpoints puede existir pero apuntar a un puerto donde nadie escucha.

```bash
kubectl exec -it web-6b9f7c-abcde -- ss -tlnp
```
```
State   Local Address:Port
LISTEN  0.0.0.0:8080
```

Si el Service tiene `targetPort: 80` pero el container escucha en `8080`, hay que corregir el manifest del Service.

### 4. Probar conectividad desde dentro del cluster

```bash
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://web.default.svc.cluster.local
```

Si esto falla pero un `curl` directo a la IP del Pod funciona, el problema está en la capa del Service (selector, puertos, kube-proxy), no en la aplicación.

```bash
kubectl get pods -o wide | grep web
# tomar la IP y probar directo al Pod
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://10.244.1.15:8080
```

### 5. `port-forward` para aislar el problema

Salteando el Service por completo, para confirmar que el Pod responde:

```bash
kubectl port-forward pod/web-6b9f7c-abcde 8080:8080
curl localhost:8080
```

Si el `port-forward` directo al Pod funciona pero el Service no, el problema es 100% del lado del Service/Endpoints, no de la app.

### 6. NetworkPolicy bloqueando tráfico

Si Endpoints está poblado, los puertos coinciden y el `port-forward` directo funciona, pero el acceso vía Service sigue fallando entre namespaces, revisar si existe una `NetworkPolicy` restringiendo el tráfico de ingreso:

```bash
kubectl get networkpolicy -A
```

### 7. `EXTERNAL-IP` en `<pending>` (LoadBalancer)

Es esperable en clusters sin cloud provider (kind, minikube sin `minikube tunnel`, clusters on-prem sin MetalLB). No es un bug del manifest.

```bash
kubectl get svc web-lb
```
```
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-lb   LoadBalancer   10.96.88.12    <pending>     80:31900/TCP   1m
```

En ese caso, igual se puede acceder vía el `nodePort` autogenerado (`31900` en el ejemplo) contra la IP de cualquier Node.

## Checklist rápido para el examen

1. `kubectl get svc <name>` — ¿existe, tipo correcto, puertos correctos?
2. `kubectl get endpoints <name>` — ¿hay al menos una IP:puerto listada?
3. Si no hay Endpoints → comparar `kubectl describe svc` (Selector) contra `kubectl get pods --show-labels`.
4. Si hay Endpoints pero falla → verificar `targetPort` contra el puerto real del container (`kubectl exec ... ss -tlnp` o revisar el `Dockerfile`/manifest).
5. Verificar readiness probes (`READY` columna, `kubectl describe pod`).
6. Probar con un Pod temporal (`kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh`) usando `wget`/`nslookup` para aislar DNS vs conectividad vs aplicación.

## Referencias

- Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Connecting Applications with Services: https://kubernetes.io/docs/tutorials/services/connect-applications-service/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf