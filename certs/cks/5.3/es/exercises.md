# CKS 5.3 — Minimize external access to the network

> Peso en el examen: 2.5%
> Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Este tema cubre cómo reducir la superficie de ataque expuesta por el cluster hacia el exterior: puertos de los componentes del control plane, `Services` innecesariamente públicos, tráfico de egress no controlado (incluyendo el metadata endpoint del cloud provider) y reglas de `NetworkPolicy` que limitan qué puede hablar con qué.

---

## Ejercicio 1: Mapear la superficie de exposición externa del cluster

Antes de restringir nada, hay que saber qué está expuesto hoy.

1. Listá todos los `Services` del cluster y fijate cuáles son `NodePort` o `LoadBalancer` (los tipos que exponen tráfico fuera del cluster):

   ```bash
   kubectl get svc -A -o wide
   ```

2. Filtrá solo los que exponen puertos hacia afuera:

   ```bash
   kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name) \(.spec.type)"'
   ```

3. En un nodo (control plane o worker), revisá qué procesos están escuchando en interfaces no-loopback:

   ```bash
   ss -tlnp
   ```

4. Compará lo que ves contra la tabla de puertos críticos de Kubernetes:

   | Puerto | Componente |
   |---|---|
   | 6443 | kube-apiserver |
   | 2379-2380 | etcd |
   | 10250 | kubelet API |
   | 10257 | kube-controller-manager |
   | 10259 | kube-scheduler |
   | 10256 | kube-proxy healthz |

5. Anotá cuáles de esos puertos están bindeados a `0.0.0.0` (todas las interfaces) en lugar de a la interfaz interna del cluster.

**Preguntas de verificación:**

- ¿Por qué un `Service` de tipo `NodePort` es, por definición, una forma de acceso externo aunque no tenga un `Ingress` ni `LoadBalancer` asociado?
- Si `etcd` escucha en `0.0.0.0:2379` en vez de en la IP interna del nodo, ¿qué riesgo concreto introduce eso?

---

## Ejercicio 2: Default-deny con NetworkPolicy

Por defecto, en Kubernetes todo el tráfico entre Pods está permitido salvo que exista un CNI que soporte `NetworkPolicy` (Calico, Cilium, etc.) y se definan reglas.

1. Creá un namespace de prueba y dos Pods:

   ```bash
   kubectl create ns netpol-lab
   kubectl run backend --image=nginx -n netpol-lab --labels="app=backend"
   kubectl run attacker --image=busybox -n netpol-lab -- sleep 3600
   ```

2. Verificá que, sin políticas, el Pod `attacker` puede llegar al `backend`:

   ```bash
   kubectl exec -n netpol-lab attacker -- wget -qO- --timeout=2 backend
   ```

3. Aplicá una `NetworkPolicy` de default-deny (ingress **y** egress) para todo el namespace:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: netpol-lab
   spec:
     podSelector: {}
     policyTypes:
     - Ingress
     - Egress
   ```

4. Repetí el `wget` del paso 2 y confirmá que ahora falla por timeout.

**Preguntas de verificación:**

- ¿Qué significa un `podSelector: {}` vacío en el `spec` de una `NetworkPolicy`?
- ¿Por qué hace falta declarar `Egress` explícitamente además de `Ingress` para bloquear también el tráfico saliente del Pod?

---

## Ejercicio 3: Permitir tráfico selectivo entre microservicios

Una vez con default-deny, se habilita solo lo necesario (least privilege a nivel de red).

1. Etiquetá el Pod `attacker` como `app=frontend`:

   ```bash
   kubectl label pod attacker -n netpol-lab app=frontend --overwrite
   ```

2. Creá una `NetworkPolicy` que permita ingress al `backend` únicamente desde Pods con `app=frontend`, sobre el puerto 80:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: netpol-lab
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
         port: 80
   ```

3. Probá de nuevo el acceso desde `attacker` (ahora `frontend`) al `backend`:

   ```bash
   kubectl exec -n netpol-lab attacker -- wget -qO- --timeout=2 backend
   ```

4. Creá un tercer Pod sin la etiqueta `app=frontend` y confirmá que a **ese** sí le sigue bloqueado el acceso.

**Preguntas de verificación:**

- Si esta `NetworkPolicy` no incluyera ninguna regla de `Egress`, ¿el `backend` seguiría sin poder iniciar conexiones salientes? ¿Por qué?
- ¿Qué pasa si el CNI instalado en el cluster no implementa el enforcement de `NetworkPolicy` (por ejemplo, Flannel sin Calico)?

---

## Ejercicio 4: Bloquear el acceso al metadata endpoint del cloud provider

El metadata endpoint (`169.254.169.254` en AWS/GCP/Azure) suele exponer credenciales del nodo. Un Pod comprometido que puede alcanzarlo es una vía clásica de escalación (relacionado con CVE-2020-8554 y ataques SSRF).

1. Desde un Pod sin restricciones de egress, intentá alcanzar el metadata endpoint:

   ```bash
   kubectl run metatest --image=curlimages/curl -n netpol-lab -it --rm -- curl -s -m 2 http://169.254.169.254/latest/meta-data/
   ```

2. Creá una `NetworkPolicy` de egress que bloquee ese `/32` pero permita el resto del tráfico saliente:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: block-cloud-metadata
     namespace: netpol-lab
   spec:
     podSelector: {}
     policyTypes:
     - Egress
     egress:
     - to:
       - ipBlock:
           cidr: 0.0.0.0/0
           except:
           - 169.254.169.254/32
   ```

3. Repetí el `curl` del paso 1 y confirmá que ahora falla.

4. Verificá que un `curl` a un destino externo distinto (por ejemplo `1.1.1.1`) sigue funcionando.

**Preguntas de verificación:**

- ¿Por qué se usa `ipBlock` con `except` en lugar de un `podSelector`/`namespaceSelector` para este caso?
- Además de la `NetworkPolicy`, ¿qué mecanismo a nivel de cloud provider (IMDS) existe para mitigar este mismo riesgo sin depender del CNI?

---

## Ejercicio 5: Restringir a nivel de firewall el acceso a los componentes del control plane

Las `NetworkPolicy` operan a nivel de Pod; los puertos del control plane (`kube-apiserver`, `etcd`, `kubelet`) están en la red del **nodo**, fuera del alcance del CNI, y deben protegerse con firewall/`iptables`/security groups.

1. En el nodo control-plane, revisá el `--bind-address` con el que corre `kube-apiserver`:

   ```bash
   ps -ef | grep kube-apiserver | grep -o -- '--bind-address=[^ ]*'
   ```

2. Revisá si `etcd` está bindeado solo a la IP interna del cluster (no a `0.0.0.0`):

   ```bash
   ss -tlnp | grep 2379
   ```

3. Agregá una regla de firewall que restrinja el puerto de `etcd` (2379-2380) solo a las IPs de los nodos del control plane, denegando el resto:

   ```bash
   sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.0.0.0/24" port port="2379-2380" protocol="tcp" accept'
   sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" port port="2379-2380" protocol="tcp" reject'
   sudo firewall-cmd --reload
   ```

4. Hacé lo mismo para el puerto `10250` (kubelet API), permitiéndolo únicamente desde los nodos del control plane.

5. Confirmá desde una máquina fuera del rango permitido que la conexión a esos puertos es rechazada (`telnet <ip> 2379` o `nc -zv <ip> 2379`).

**Preguntas de verificación:**

- ¿Por qué el orden de las reglas (`accept` para el rango confiable antes que el `reject` general) es importante en `firewalld`/`iptables`?
- Si el `kubelet` expone su API sin autenticación (`--anonymous-auth=true` y sin `--authorization-mode=Webhook`), ¿qué mitiga realmente la regla de firewall del paso 4, y qué NO mitiga?

---

## Ejercicio 6: Minimizar la exposición vía Service/Ingress

1. Identificá un `Service` de tipo `NodePort` que no necesite ser accedido directamente desde fuera del cluster (por ejemplo, un servicio interno que solo debería consumir un `Ingress`):

   ```bash
   kubectl get svc -n <namespace> <service> -o yaml
   ```

2. Convertilo a `ClusterIP` y exponelo únicamente vía `Ingress`:

   ```bash
   kubectl patch svc <service> -n <namespace> -p '{"spec": {"type": "ClusterIP"}}'
   ```

3. Restringí el `Ingress` a un rango de IPs de origen conocido usando una anotación del controller (ejemplo con NGINX Ingress):

   ```yaml
   metadata:
     annotations:
       nginx.ingress.kubernetes.io/whitelist-source-range: "203.0.113.0/24"
   ```

4. Verificá que el acceso desde una IP fuera de ese rango es rechazado (HTTP 403) y que desde dentro del rango funciona.

**Preguntas de verificación:**

- ¿Por qué convertir un `Service` de `NodePort` a `ClusterIP` + `Ingress` reduce la superficie de ataque aunque el `Ingress` termine siendo público de todos modos?
- ¿Qué diferencia hay entre restringir el acceso con `whitelist-source-range` en el `Ingress` y hacerlo con una `NetworkPolicy` de `Ingress` sobre el Pod del backend?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**

- Un `NodePort` abre el puerto en **todas** las interfaces de **todos** los nodos del cluster (rango por defecto 30000-32767), sin pasar por ningún controlador de Ingress ni capa de autenticación/autorización adicional. Cualquiera que pueda alcanzar la IP de un nodo por esa red puede llegar al Pod detrás del `Service`, independientemente de si existe o no un `Ingress` "oficial".
- Si `etcd` escucha en `0.0.0.0:2379`, cualquier host que tenga ruta de red hacia ese puerto (no solo los nodos del control plane) puede intentar conectarse. `etcd` almacena todo el estado del cluster, incluyendo Secrets (que si no están cifrados en reposo, quedan en texto plano); un acceso no autenticado o mal protegido equivale a acceso total al cluster.

**Ejercicio 2**

- `podSelector: {}` sin `matchLabels` selecciona **todos** los Pods del namespace donde se aplica la política. Combinado con `policyTypes: [Ingress, Egress]` y sin reglas `ingress`/`egress` definidas, el resultado es "denegar todo el tráfico entrante y saliente" para todos los Pods de ese namespace.
- Los `policyTypes` determinan qué direcciones de tráfico controla la política. Si solo se declara `Ingress`, el egress de los Pods queda sin restricciones (comportamiento por defecto = permitir todo), porque Kubernetes no asume egress-deny implícito al bloquear ingress.

**Ejercicio 3**

- Sí. Esta `NetworkPolicy` solo tiene `policyTypes: [Ingress]`, por lo que no toca el egress del `backend` — pero en este lab el egress ya está bloqueado por la política `default-deny-all` del Ejercicio 2, que sigue vigente (las `NetworkPolicy` son aditivas: se aplican todas las que matchean el Pod). Sin esa política previa, el egress del `backend` sería libre.
- Si el CNI no implementa `NetworkPolicy` (como Flannel puro), el objeto se crea y queda almacenado en `etcd` sin error, pero **no tiene ningún efecto real**: todo el tráfico sigue permitido. Es un fallo silencioso que hay que verificar activamente (probando conectividad), no asumir por la sola existencia del YAML.

**Ejercicio 4**

- `ipBlock` con `except` es necesario porque el metadata endpoint no es un Pod ni tiene un Service de Kubernetes asociado — es una IP externa a la red de Pods (link-local, `169.254.0.0/16`), fuera del dominio que cubren `podSelector`/`namespaceSelector`. Solo `ipBlock` permite expresar reglas sobre rangos de IP arbitrarios.
- La mayoría de los cloud providers ofrecen configuración de IMDS a nivel de instancia/nodo (por ejemplo, IMDSv2 con hop-limit en AWS, que reduce el TTL de los paquetes salientes de contenedores para que no lleguen al metadata service, o deshabilitar el metadata service para roles que no lo necesitan). Es una defensa en profundidad complementaria: si la `NetworkPolicy` falla o el CNI no la aplica, la mitigación a nivel de infraestructura sigue vigente.

**Ejercicio 5**

- En `firewalld`/`iptables`, las reglas se evalúan en orden y la primera que matchea decide el destino del paquete (accept/reject). Si la regla `reject` genérica se agregara antes que la `accept` del rango confiable, todo el tráfico —incluido el de los nodos legítimos del control plane— sería rechazado antes de llegar a evaluarse la regla de excepción.
- La regla de firewall limita **quién puede establecer la conexión de red** hacia el puerto 10250 (defensa perimetral). No mitiga que, una vez que una conexión desde una IP permitida logra establecerse, el kubelet acepte peticiones sin autenticar porque `--anonymous-auth=true` sigue habilitado. Son controles en capas distintas: red vs. autenticación/autorización de la API del kubelet, y hay que corregir ambos.

**Ejercicio 6**

- Aunque el `Ingress` siga siendo el punto de entrada público, pasar a `ClusterIP` elimina la exposición **directa e incontrolada** vía la IP de cada nodo en el rango 30000-32767, que no pasa por las reglas de un `IngressClass` (TLS, rate limiting, `whitelist-source-range`, WAF, etc.). Con `ClusterIP` + `Ingress`, todo el tráfico externo queda forzado a pasar por un único punto donde sí se pueden aplicar controles centralizados.
- `whitelist-source-range` en el `Ingress` filtra por IP de origen en el borde del cluster (capa de entrada HTTP/L7, antes de llegar a cualquier Pod). Una `NetworkPolicy` de `Ingress` sobre el backend filtra por identidad de Pod/namespace **dentro** del cluster (capa L3/L4 entre Pods) y no entiende IPs de clientes externos, porque para el backend, el tráfico que llega ya tiene como origen el Pod del Ingress controller, no la IP real del cliente. Son controles complementarios en capas distintas, no intercambiables.

</details>