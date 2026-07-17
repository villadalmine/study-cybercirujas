# KCNA · Tema 3.4 — Networking

> Fuente de referencia: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)
> Peso en el examen: 4

Prerrequisito: un cluster Kubernetes local funcionando (`kind` o `minikube`) y `kubectl` configurado contra él. Todos los comandos se ejecutan desde la terminal.

---

## Ejercicio 1 — El modelo de networking de Kubernetes (pod-to-pod)

Kubernetes exige que todo Pod pueda comunicarse con cualquier otro Pod del cluster sin NAT, usando su propia IP. Vamos a comprobarlo directamente.

1. Creá dos Pods simples:
   ```bash
   kubectl run pod-a --image=nginx --restart=Never
   kubectl run pod-b --image=busybox --restart=Never -- sleep 3600
   ```
2. Esperá a que ambos estén `Running`:
   ```bash
   kubectl get pods -o wide
   ```
3. Anotá la IP de `pod-a` (columna `IP`).
4. Desde `pod-b`, hacé un request HTTP directo a la IP de `pod-a`:
   ```bash
   kubectl exec pod-b -- wget -qO- <IP-de-pod-a>
   ```
5. Deberías ver el HTML de bienvenida de nginx, confirmando conectividad directa entre Pods sin pasar por ningún Service.

**Preguntas de repaso:**
- ¿Por qué esto funciona sin que hayamos configurado ninguna regla de NAT manualmente?
- ¿Qué componente del cluster es responsable de asignarle una IP a cada Pod?

---

## Ejercicio 2 — Service tipo `ClusterIP` y DNS interno (CoreDNS)

Las IPs de Pod son efímeras (cambian si el Pod se recrea). Un `Service` da una identidad estable; CoreDNS le da un nombre resoluble.

1. Creá un Deployment con 2 réplicas:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   ```
2. Expónelo como Service `ClusterIP`:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80
   ```
3. Verificá el Service y su ClusterIP asignada:
   ```bash
   kubectl get svc web
   ```
4. Desde `pod-b` (creado en el ejercicio anterior), resolvé el nombre DNS del Service:
   ```bash
   kubectl exec pod-b -- nslookup web.default.svc.cluster.local
   ```
5. Hacé un request usando el nombre corto (dentro del mismo namespace no hace falta el FQDN completo):
   ```bash
   kubectl exec pod-b -- wget -qO- web
   ```

**Preguntas de repaso:**
- Si eliminás uno de los dos Pods del Deployment y Kubernetes lo recrea con una IP nueva, ¿el Service deja de funcionar? ¿Por qué?
- ¿Qué patrón de nombre DNS usa CoreDNS para un Service (`<service>.<namespace>.svc.cluster.local`)?

---

## Ejercicio 3 — `NodePort` vs `LoadBalancer`

1. Cambiá el `type` del Service `web` a `NodePort`:
   ```bash
   kubectl patch svc web -p '{"spec":{"type":"NodePort"}}'
   ```
2. Consultá el puerto asignado en el nodo:
   ```bash
   kubectl get svc web
   ```
   (buscá el segundo número en la columna `PORT(S)`, formato `80:3XXXX/TCP`)
3. Obtené la IP de un nodo del cluster:
   ```bash
   kubectl get nodes -o wide
   ```
4. Accedé al Service usando `<IP-del-nodo>:<NodePort>` (con `minikube`, podés usar `minikube service web --url` en su lugar).
5. Cambiá el `type` a `LoadBalancer`:
   ```bash
   kubectl patch svc web -p '{"spec":{"type":"LoadBalancer"}}'
   kubectl get svc web
   ```
   Notá que `EXTERNAL-IP` queda en `<pending>` si el cluster no tiene un cloud controller que provisione un balanceador real.

**Preguntas de repaso:**
- ¿Qué relación jerárquica hay entre `ClusterIP`, `NodePort` y `LoadBalancer` (cada uno incluye al anterior)?
- ¿Por qué `EXTERNAL-IP` queda pendiente en un cluster local como `kind` o `minikube` sin addons adicionales?

---

## Ejercicio 4 — Ingress

Un Ingress permite exponer múltiples Services HTTP/HTTPS bajo una sola IP, enrutando por hostname o path. Requiere un Ingress Controller corriendo (por ejemplo, nginx).

1. Instalá el Ingress Controller de nginx (ejemplo con `minikube`):
   ```bash
   minikube addons enable ingress
   ```
2. Confirmá que el controller esté corriendo:
   ```bash
   kubectl get pods -n ingress-nginx
   ```
3. Creá un recurso Ingress que enrute `web.local` hacia el Service `web`:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
   spec:
     ingressClassName: nginx
     rules:
     - host: web.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: web
               port:
                 number: 80
   EOF
   ```
4. Agregá `web.local` apuntando a la IP del Ingress Controller en tu `/etc/hosts` local.
5. Probá el acceso:
   ```bash
   curl http://web.local
   ```

**Preguntas de repaso:**
- ¿Qué diferencia hay entre el recurso `Ingress` y el `Ingress Controller`?
- ¿Por qué un Ingress opera en capa 7 (HTTP/HTTPS) y no reemplaza a un Service de capa 4?

---

## Ejercicio 5 — NetworkPolicy

Por defecto, en Kubernetes todo Pod puede hablar con todo Pod. Una `NetworkPolicy` restringe ese tráfico (requiere un CNI plugin que la soporte, como Calico).

1. Verificá que podés llegar al Service `web` desde `pod-b` (debería funcionar, como en el ejercicio 2):
   ```bash
   kubectl exec pod-b -- wget -qO- --timeout=2 web
   ```
2. Aplicá una policy de "default deny" para el ingress de los Pods con label `app=web`:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-all-web
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
   EOF
   ```
3. Reintentá el mismo `wget` desde `pod-b`: ahora debería fallar por timeout.
4. Agregá una policy que permita explícitamente el tráfico solo desde Pods con label `access=allowed`:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-from-labeled
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             access: allowed
   EOF
   ```
5. Etiquetá `pod-b` y probá de nuevo:
   ```bash
   kubectl label pod pod-b access=allowed
   kubectl exec pod-b -- wget -qO- --timeout=2 web
   ```

**Preguntas de repaso:**
- Si ningún CNI plugin del cluster implementa `NetworkPolicy` (por ejemplo, el `bridge` CNI básico), ¿qué pasa al aplicar el YAML del paso 2?
- ¿Por qué el modelo de NetworkPolicy es "additive" (las reglas de distintas policies que aplican al mismo Pod se suman) en vez de evaluarse en orden?

---

## Ejercicio 6 — Identificar el CNI plugin del cluster

El Container Network Interface (CNI) es la especificación que implementan plugins (Calico, Cilium, Flannel, etc.) para asignar IPs y conectar Pods a la red.

1. Listá los Pods del namespace `kube-system` y buscá el componente de red:
   ```bash
   kubectl get pods -n kube-system
   ```
2. Identificá cuál corresponde al CNI plugin (por nombre: `kindnet`, `calico-node`, `weave-net`, `cilium`, etc.).
3. Inspeccioná su configuración en el nodo (si tenés acceso SSH/exec al nodo):
   ```bash
   kubectl exec -n kube-system <pod-del-cni> -- ls /etc/cni/net.d/
   ```

**Preguntas de repaso:**
- ¿Es el CNI plugin el mismo componente que implementa `kube-proxy`, o son responsabilidades distintas?
- ¿Por qué Kubernetes delega el networking a plugins en vez de tener una implementación única embebida?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- Funciona porque el modelo de red de Kubernetes exige (como requisito de diseño, no como feature de un plugin específico) que todos los Pods compartan un espacio de IPs plano, ruteable sin NAT entre ellos. Esta garantía la implementa el CNI plugin instalado en el cluster, no `kube-proxy`.
- El componente responsable es el **CNI plugin** (invocado por el kubelet al crear el Pod), que le asigna IP y conecta su interfaz de red al resto del cluster.

**Ejercicio 2**
- No deja de funcionar: el Service mantiene una IP virtual estable (`ClusterIP`) y un `Endpoints`/`EndpointSlice` que se actualiza automáticamente con las IPs vigentes de los Pods que matchean su selector. El cliente siempre resuelve al Service, nunca directamente a la IP del Pod.
- El patrón es `<service>.<namespace>.svc.cluster.local`. Dentro del mismo namespace alcanza con `<service>` gracias al `search domain` configurado en `/etc/resolv.conf` de cada Pod.

**Ejercicio 3**
- Es jerárquico: `NodePort` incluye automáticamente un `ClusterIP` (sigue existiendo, accesible internamente) y además abre un puerto fijo en cada nodo del cluster. `LoadBalancer` incluye a su vez un `NodePort` y le pide al cloud provider que provisione un balanceador externo que apunte a esos puertos de nodo.
- Queda `<pending>` porque provisionar el balanceador real requiere un **cloud controller manager** integrado con un proveedor (AWS, GCP, Azure, etc.) o un addon tipo MetalLB; un cluster local sin esa integración no tiene quién satisfaga el request.

**Ejercicio 4**
- El recurso `Ingress` es solo un objeto de configuración declarativa (reglas de ruteo). El **Ingress Controller** es el software (por ejemplo, nginx, Traefik, HAProxy) que efectivamente lee esos recursos y programa un proxy/load balancer para cumplirlos. Sin un controller corriendo, un Ingress no hace nada.
- Opera en capa 7 porque rutea según información HTTP (host header, path), algo que un Service (capa 4, basado en IP:puerto) no puede interpretar. Por eso Ingress se usa para consolidar múltiples servicios HTTP detrás de una sola IP/dominio en vez de crear un `LoadBalancer` por Service.

**Ejercicio 5**
- Con un CNI plugin que no implementa `NetworkPolicy` (el `apiserver` la acepta y la guarda igual, porque es solo un objeto de la API), el YAML se aplica sin error, pero **no tiene ningún efecto real**: el tráfico sigue fluyendo sin restricciones porque nadie hace cumplir la regla a nivel de red.
- Es additive porque el modelo está pensado para que múltiples equipos/policies puedan coexistir de forma segura: cada policy solo puede *permitir* tráfico adicional, nunca *quitar* un permiso otorgado por otra policy. Esto evita que una policy mal escrita bloquee accidentalmente algo que otra policy autorizó.

**Ejercicio 6**
- Son responsabilidades distintas. El **CNI plugin** asigna IPs a los Pods y provee conectividad L3 entre ellos (y opcionalmente aplica NetworkPolicies). **`kube-proxy`** es un componente separado que implementa el enrutamiento de tráfico hacia los Services (vía reglas de `iptables`, `IPVS`, o eBPF), traduciendo la IP virtual del Service a la IP real de un Pod backend.
- Porque distintos entornos (on-prem, cada cloud provider, distintos requisitos de performance o seguridad) necesitan implementaciones de red muy diferentes. Definir CNI como una especificación desacoplada permite que Kubernetes sea agnóstico de la infraestructura de red subyacente y que el ecosistema (Calico, Cilium, Flannel, etc.) compita e innove libremente sobre esa interfaz común.

</details>