# CKA 1.35 — Tema 2.5: Troubleshoot Services and Networking

## Introducción

El troubleshooting de networking es uno de los temas con más peso práctico del examen CKA porque requiere combinar conocimiento de varias capas: el modelo de red de Kubernetes, `kube-proxy`, CoreDNS, el CNI plugin, y las reglas de `iptables`/IPVS que terminan materializando todo esto en el kernel de Linux. No hay "un" comando que resuelva un problema de red; hay un método de descarte por capas.

El modelo de red de Kubernetes exige:
- Todo Pod puede comunicarse con todo Pod sin NAT (implementado por el CNI).
- Todo Node puede comunicarse con todo Pod sin NAT.
- La IP que un Pod ve de sí mismo es la misma que otros ven de él.

Cuando algo de esto se rompe, hay que verificar en orden: **Pod → Service → Endpoints → kube-proxy → CNI → DNS → NetworkPolicy → Ingress**.

---

## 1. Metodología general de troubleshooting

Un flujo típico para "no puedo llegar al backend":

1. ¿El Pod está `Running` y `Ready`? (`kubectl get pods -o wide`)
2. ¿El Pod escucha en el puerto esperado? (`kubectl exec -- ss -tlnp` o `netstat -tlnp`)
3. ¿El Service tiene Endpoints? (`kubectl get endpoints <svc>`)
4. ¿Los `selector` del Service coinciden con los `labels` del Pod?
5. ¿kube-proxy generó las reglas correctas? (`iptables-save` / `ipvsadm -Ln`)
6. ¿Hay una NetworkPolicy bloqueando el tráfico?
7. ¿DNS resuelve el nombre del Service? (`nslookup`, `dig` desde un Pod de debug)
8. ¿El CNI plugin está sano en todos los nodos? (`kubectl get pods -n kube-system`, revisar CIDR de Pods)

Pod de debug recomendado (con herramientas de red incluidas, no siempre disponibles en imágenes `scratch`/`distroless`):

```bash
kubectl run tmp-shell --rm -it --image=nicolaka/netshoot -- sh
```

O con `kubectl debug` para inspeccionar un Pod existente sin reiniciarlo:

```bash
kubectl debug -it pod/mypod --image=nicolaka/netshoot --target=mypod -- sh
```

---

## 2. Troubleshooting de Services

### 2.1 Verificar Endpoints

El síntoma más común de un Service roto es `selector` mal configurado o Pods no `Ready` (los Pods `NotReady` no entran en Endpoints).

```bash
kubectl get svc web
```
```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.45.12    <none>        80/TCP    5m
```

```bash
kubectl get endpoints web
```
```
NAME   ENDPOINTS   AGE
web    <none>      5m
```

`<none>` en ENDPOINTS es la señal clave: el Service no tiene backends. Causas típicas:

- El `selector` del Service no matchea las `labels` de los Pods:
```bash
kubectl get svc web -o jsonpath='{.spec.selector}'
```
```
{"app":"web"}
```
```bash
kubectl get pods --show-labels
```
```
NAME        READY   STATUS    LABELS
web-6d9f8   1/1     Running   app=webapp
```
Aquí el selector busca `app=web` pero el Pod tiene `app=webapp` → mismatch.

- Los Pods existen pero no pasan el `readinessProbe` (solo Pods `Ready` entran en Endpoints, salvo que se use `publishNotReadyAddresses: true`):
```bash
kubectl describe pod web-6d9f8 | grep -A5 Readiness
```
```
Readiness probe failed: Get "http://10.244.1.5:8080/healthz": connection refused
```

- El `targetPort` no coincide con el puerto real de escucha del contenedor:
```bash
kubectl get svc web -o jsonpath='{.spec.ports[0].targetPort}'
```
Comparar contra lo que el proceso realmente escucha dentro del Pod (`ss -tlnp`).

### 2.2 EndpointSlices (API moderna)

Desde 1.21+ los Endpoints se implementan mediante `EndpointSlices` (habilitado por defecto). Es útil inspeccionarlos directamente cuando hay dudas sobre el estado de "ready":

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpointslices web-x7k2p -o yaml
```
```yaml
endpoints:
- addresses: ["10.244.1.5"]
  conditions:
    ready: true
    serving: true
    terminating: false
```

### 2.3 Tipos de Service y fallas comunes

| Tipo | Falla típica | Diagnóstico |
|---|---|---|
| ClusterIP | Selector mal configurado, sin Endpoints | `kubectl get endpoints` |
| NodePort | Firewall del nodo bloquea el rango 30000-32767 | `iptables -L`, `curl <nodeIP>:<nodePort>` |
| LoadBalancer | `EXTERNAL-IP` queda en `<pending>` porque no hay cloud-controller-manager | `kubectl describe svc` (eventos) |
| ExternalName | No resuelve porque depende de CoreDNS pero apunta mal el CNAME | `nslookup` desde dentro del cluster |
| Headless (`clusterIP: None`) | Cliente espera una sola IP y recibe múltiples registros A | Revisar `dig` — es comportamiento esperado, no bug |

Ejemplo de `LoadBalancer` pendiente en un cluster bare-metal (sin MetalLB u otro proveedor):

```bash
kubectl get svc frontend
```
```
NAME       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
frontend   LoadBalancer   10.96.88.20   <pending>     80:31840/TCP   2m
```

Esto es esperado sin un controlador de LB; para exponerlo en el interín se puede probar por NodePort (`31840` en este caso).

### 2.4 Verificar conectividad directa al Pod (bypass del Service)

Para aislar si el problema está en el Service o en el Pod:

```bash
kubectl get pod web-6d9f8 -o jsonpath='{.status.podIP}'
# 10.244.1.5
kubectl run tmp --rm -it --image=busybox -- wget -qO- http://10.244.1.5:8080
```

Si esto funciona pero el Service no, el problema está en selectors/Endpoints/kube-proxy, no en la aplicación.

---

## 3. kube-proxy

`kube-proxy` traduce Services/Endpoints en reglas de datapath. Corre como DaemonSet en `kube-system`.

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
kubectl logs -n kube-system kube-proxy-abcde
```

### 3.1 Modo iptables (default histórico)

Verificar que existan las reglas para el Service (ClusterIP `10.96.45.12:80`):

```bash
iptables-save | grep 10.96.45.12
```
```
-A KUBE-SERVICES -d 10.96.45.12/32 -p tcp -m tcp --dport 80 -j KUBE-SVC-XPGD46QRK7WJZT7O
-A KUBE-SVC-XPGD46QRK7WJZT7O -j KUBE-SEP-57KPRZ3JQVENLNBR
-A KUBE-SEP-57KPRZ3JQVENLNBR -p tcp -m tcp -j DNAT --to-destination 10.244.1.5:8080
```

Si esta cadena no existe, kube-proxy no procesó el Service (revisar sus logs, o que el `nodePort`/CIDR configurado matchee).

### 3.2 Modo IPVS

```bash
ipvsadm -Ln
```
```
TCP  10.96.45.12:80 rr
  -> 10.244.1.5:8080              Masq    1      0          0
```

Confirmar el modo activo:

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```
```
mode: "ipvs"
```

### 3.3 Fallas comunes de kube-proxy

- ConfigMap `kube-proxy` desactualizado tras cambiar el `--cluster-cidr`: reiniciar el DaemonSet.
- `kube-proxy` no corre en un nodo → ese nodo no puede resolver Services vía ClusterIP (los Pods en ese nodo fallan al hacer `curl` al Service).
- Conflictos de `hostNetwork` o firewalls locales (`firewalld`, `ufw`) que interceptan las cadenas `KUBE-*` — típico en RHEL/CentOS con firewalld activo sin excepciones.

---

## 4. Troubleshooting de DNS (CoreDNS)

### 4.1 Verificar el Pod y Service de CoreDNS

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
```
```
NAME       TYPE        CLUSTER-IP   PORT(S)
kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

### 4.2 Probar resolución desde un Pod

```bash
kubectl run dnsutils --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.39 -- /bin/sh
nslookup web.default.svc.cluster.local
```
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web.default.svc.cluster.local
Address:   10.96.45.12
```

Si falla:
```
;; connection timed out; no servers could be reached
```

Causas típicas:
- `/etc/resolv.conf` del Pod mal configurado (revisar `dnsPolicy` del Pod).
```bash
kubectl exec dnsutils -- cat /etc/resolv.conf
```
```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```
- CoreDNS caído o con `CrashLoopBackOff` — revisar logs:
```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```
- NetworkPolicy que bloquea el puerto 53 hacia `kube-system`.
- Loop de resolución detectado por el plugin `loop` de CoreDNS (típico cuando `/etc/resolv.conf` del nodo apunta a `127.0.0.1` vía `systemd-resolved` sin el forwarder correcto):
```
[FATAL] plugin/loop: Loop (127.0.0.1:53 -> 127.0.0.1:53) detected for zone ".", see https://coredns.io/plugins/loop#troubleshooting
```
Solución: ajustar `resolvConf` del kubelet o el ConfigMap `coredns` para no reenviar a `/etc/resolv.conf` del host cuando este apunta a un stub loopback.

### 4.3 Revisar Corefile

```bash
kubectl get configmap coredns -n kube-system -o yaml
```
```yaml
Corefile: |
  .:53 {
      errors
      health
      ready
      kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
      }
      forward . /etc/resolv.conf
      cache 30
      loop
      reload
  }
```

Un error común en el examen: alguien edita el `Corefile` a mano y olvida que hace falta reiniciar CoreDNS (no aplica solo) o que el `ConfigMap` se monta como volumen y no como env var:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

### 4.4 `ndots:5` y latencia de resolución externa

Por defecto los Pods tienen `ndots:5`, lo que provoca que toda consulta con menos de 5 puntos (ej. `api.github.com`) primero pruebe contra los `search domains` internos antes de ir a upstream, generando lookups extra. No es un "bug" sino un costo de performance a tener en cuenta; se puede mitigar con `dnsConfig` por Pod:

```yaml
dnsConfig:
  options:
    - name: ndots
      value: "2"
```

---

## 5. Troubleshooting del CNI

### 5.1 Verificar que el CNI plugin esté corriendo

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|flannel|cilium|weave'
```

Un Pod que queda en `ContainerCreating` indefinidamente con evento de red suele indicar fallo del CNI:

```bash
kubectl describe pod web-6d9f8
```
```
Warning  FailedCreatePodSandBox  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "abc123": plugin type="calico" failed (add): error getting ClusterInformation: Get "https://10.96.0.1:443/apis/...": dial tcp 10.96.0.1:443: i/o timeout
```

Esto indica que el propio CNI no puede hablar con el apiserver — revisar si el Service `kubernetes` en `default` tiene Endpoints correctos, o si el problema es de conectividad Node→apiserver.

### 5.2 Verificar el archivo de configuración CNI en el nodo

```bash
ls /etc/cni/net.d/
cat /etc/cni/net.d/10-calico.conflist
```

Un directorio vacío o con múltiples archivos en conflicto ("multiple CNI configs") hace que el kubelet no sepa qué plugin usar.

### 5.3 Verificar el CIDR de Pods

```bash
kubectl cluster-info dump | grep -m1 cluster-cidr
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

Si el `podCIDR` del nodo no está asignado (`""`), el CNI no puede levantar interfaces para nuevos Pods — típico cuando el controller-manager arrancó sin `--allocate-node-cidrs=true` o sin `--cluster-cidr` coincidente con el manifest del CNI.

### 5.4 Verificar la interfaz de red del Pod

```bash
kubectl exec web-6d9f8 -- ip addr
```
```
3: eth0@if15: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
    inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0
```

Un MTU incorrecto (ej. overlay con VXLAN usando 1500 en vez de 1450) provoca fragmentación silenciosa y timeouts intermitentes en payloads grandes, mientras que `ping` con paquetes chicos funciona — síntoma clásico de "funciona con curl pero falla con requests grandes".

### 5.5 Comunicación cross-node rota

Si Pods en el mismo nodo se comunican pero Pods en nodos distintos no:

```bash
# Desde el nodo, verificar rutas hacia el CIDR de otros nodos
ip route | grep 10.244
```
```
10.244.0.0/24 via 192.168.1.10 dev eth0
10.244.2.0/24 via 192.168.1.12 dev eth0
```

Si faltan rutas, o el firewall del host bloquea el protocolo de encapsulación (VXLAN UDP 8472, o IP-in-IP protocolo 4 para Calico), la comunicación cross-node se rompe aunque intra-node funcione perfecto.

---

## 6. Troubleshooting de NetworkPolicy

Requiere que el CNI soporte NetworkPolicy (Flannel puro no lo soporta sin Canal/Calico).

```bash
kubectl get networkpolicy -A
kubectl describe networkpolicy deny-all -n prod
```

Ejemplo de policy que bloquea todo el tráfico de entrada salvo desde un namespace específico:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
  namespace: backend
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
    ports:
    - protocol: TCP
      port: 8080
```

Fallas típicas:
- Olvidar que **una vez que existe una policy con `podSelector` que matchea un Pod, todo lo no explícitamente permitido queda denegado** (default-deny implícito por selector, no hace falta una regla "deny-all" explícita).
- El namespace de origen no tiene el label esperado (`kubernetes.io/metadata.name` se autopone desde 1.21+, pero namespaces creados antes de actualizar el cluster pueden no tenerlo):
```bash
kubectl get ns frontend --show-labels
```
- Confundir `Ingress`/`Egress` en `policyTypes`: si solo se declara `Ingress` pero hay reglas de `egress`, estas se ignoran.
- Testear con `kubectl exec` para confirmar bloqueo real:
```bash
kubectl exec -n frontend testpod -- curl -m2 http://api.backend.svc.cluster.local:8080
```
```
curl: (28) Connection timed out after 2000 milliseconds
```

---

## 7. Troubleshooting de Ingress

```bash
kubectl get ingress -A
kubectl describe ingress web-ingress
```

Fallas comunes:
- El `ingressClassName` no coincide con ningún IngressClass instalado:
```bash
kubectl get ingressclass
```
```
NAME    CONTROLLER
nginx   k8s.io/ingress-nginx
```
Si el Ingress dice `ingressClassName: nginx-internal` y no existe esa clase, el controlador ignora el recurso silenciosamente (sin error visible salvo en logs del controller).

- El backend Service referenciado no existe o el puerto está mal:
```bash
kubectl describe ingress web-ingress
```
```
Warning  BadConfig  ingress-nginx-controller  Service "web" not found
```

- Revisar logs del Ingress Controller directamente cuando el problema es 502/504:
```bash
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | tail -50
```

---

## 8. Comandos de diagnóstico de red a nivel de sistema

Útiles dentro de un Pod de debug (`netshoot`) o accediendo al nodo con `kubectl debug node/<node> -it --image=busybox`:

```bash
ss -tlnp                 # puertos en escucha
curl -v telnet://<ip>:<port>
nc -zv <ip> <port>        # test de conectividad TCP
tcpdump -i eth0 port 8080 -w /tmp/cap.pcap
traceroute <ip>
mtr <ip>
```

Ejemplo real de diagnóstico con `nc`:

```bash
nc -zv 10.244.1.5 8080
```
```
10.244.1.5 (10.244.1.5:8080) open
```

vs.

```
nc: connect to 10.244.1.5 port 8080 (tcp) failed: Connection refused
```

`Connection refused` = el proceso no escucha en ese puerto (problema de la app o `targetPort` mal mapeado). `Connection timed out` = el paquete ni siquiera llega (problema de CNI, NetworkPolicy o firewall).

---

## 9. Resumen de árbol de decisión

```
¿kubectl get endpoints <svc> = <none>?
 ├── Sí → revisar selector/labels y readinessProbe
 └── No → ¿curl directo al Pod IP funciona?
          ├── No → problema de CNI/red del Pod (revisar CNI pods, rutas, MTU)
          └── Sí → ¿curl al ClusterIP funciona desde el mismo nodo?
                   ├── No → revisar kube-proxy (iptables/ipvsadm)
                   └── Sí → ¿falla solo por nombre DNS?
                            ├── Sí → troubleshooting CoreDNS
                            └── No → revisar NetworkPolicy / Ingress
```

---

## Referencias

- CNCF, *CKA Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Kubernetes Docs, *Debug Services*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes Docs, *Debugging DNS Resolution*: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Kubernetes Docs, *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Docs, *Service*: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Docs, *Ingress*: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes Docs, *kube-proxy Reference*: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Kubernetes Docs, *Debug Running Pods (`kubectl debug`)*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- CoreDNS, *Troubleshooting Loop Plugin*: https://coredns.io/plugins/loop/#troubleshooting
- Kubernetes Docs, *Cluster Networking*: https://kubernetes.io/docs/concepts/cluster-administration/networking/
