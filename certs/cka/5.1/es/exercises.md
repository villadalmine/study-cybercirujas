# CKA 5.1 — Understand connectivity between Pods

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Este set de ejercicios cubre el modelo de networking de Kubernetes desde la perspectiva de un Pod: cómo comparten el network namespace los containers de un mismo Pod, cómo se comunican Pods entre sí (incluso entre nodos distintos) sin NAT, y cómo debuggear esa conectividad con herramientas nativas de `kubectl`.

Preparación común para todos los ejercicios:

```bash
kubectl create namespace net-lab
kubectl config set-context --current --namespace=net-lab
```

---

## Ejercicio 1: El modelo de red plano (flat network) de Kubernetes

1. Creá dos Pods simples basados en una imagen con herramientas de red:

```bash
kubectl run pod-a --image=nicolaka/netshoot --command -- sleep infinity
kubectl run pod-b --image=nicolaka/netshoot --command -- sleep infinity
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b
```

2. Obtené las IPs asignadas a cada Pod:

```bash
kubectl get pods -o wide
```

3. Desde `pod-a`, hacé ping a la IP de `pod-b` usando esa IP directamente (sin Service de por medio):

```bash
POD_B_IP=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
kubectl exec pod-a -- ping -c 3 "$POD_B_IP"
```

4. Repetí el ping en sentido inverso, de `pod-b` a `pod-a`:

```bash
POD_A_IP=$(kubectl get pod pod-a -o jsonpath='{.status.podIP}')
kubectl exec pod-b -- ping -c 3 "$POD_A_IP"
```

5. Compará la IP que ves con `kubectl get pods -o wide` contra la IP que ve el propio Pod internamente:

```bash
kubectl exec pod-a -- ip addr show eth0
```

**Preguntas de comprensión:**

1. ¿Por qué el ping funciona en ambas direcciones sin haber creado ningún Service, Ingress ni regla de NAT?
2. ¿La IP que reporta `ip addr show eth0` dentro del Pod coincide con la que muestra `kubectl get pods -o wide`? ¿Qué principio del modelo de red de Kubernetes confirma esto?

---

## Ejercicio 2: Containers dentro del mismo Pod comparten el network namespace

1. Creá un Pod con dos containers: uno sirviendo HTTP y otro solo con herramientas de diagnóstico.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-multicontainer
spec:
  containers:
  - name: web
    image: nginx:1.27
    ports:
    - containerPort: 80
  - name: shell
    image: nicolaka/netshoot
    command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready pod/pod-multicontainer
```

2. Desde el container `shell`, accedé al servidor `nginx` del container `web` usando **localhost**, no la IP del Pod:

```bash
kubectl exec pod-multicontainer -c shell -- curl -s -o /dev/null -w "%{http_code}\n" http://localhost:80
```

3. Verificá que ambos containers reportan la misma interfaz de red y la misma IP:

```bash
kubectl exec pod-multicontainer -c web   -- hostname -i
kubectl exec pod-multicontainer -c shell -- hostname -i
```

4. Intentá abrir un socket de escucha en el container `shell` en el puerto 8080 y accedé a él desde `web` también por `localhost` (opcional, requiere `nc` en ambas imágenes; si `web` no lo tiene, usá `curl` desde `shell` hacia sí mismo como comprobación alternativa):

```bash
kubectl exec pod-multicontainer -c shell -- sh -c 'nc -lk -p 8080 &'
kubectl exec pod-multicontainer -c shell -- nc -zv localhost 8080
```

**Preguntas de comprensión:**

3. ¿Por qué `curl http://localhost:80` desde el container `shell` alcanza al servidor `nginx` que corre en el container `web`, si son procesos distintos en containers distintos?
4. Si `web` y `shell` necesitaran escuchar en el mismo puerto (por ejemplo, ambos en el puerto 80), ¿sería posible dentro del mismo Pod? ¿Por qué?

---

## Ejercicio 3: Conectividad Pod-to-Pod entre nodos distintos

1. Listá los nodos del cluster:

```bash
kubectl get nodes -o wide
```

2. Si hay más de un nodo worker, forzá que dos Pods se agenden en nodos distintos usando `nodeName` (o `nodeSelector`/`podAntiAffinity` si preferís no fijar el nodo de forma tan explícita):

```bash
NODE1=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
NODE2=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[1].metadata.name}')

kubectl run pod-node1 --image=nicolaka/netshoot --overrides="{\"spec\":{\"nodeName\":\"$NODE1\"}}" --command -- sleep infinity
kubectl run pod-node2 --image=nicolaka/netshoot --overrides="{\"spec\":{\"nodeName\":\"$NODE2\"}}" --command -- sleep infinity
kubectl wait --for=condition=Ready pod/pod-node1 pod/pod-node2
```

3. Confirmá en qué nodo terminó cada Pod:

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

4. Probá la conectividad cruzando nodos:

```bash
IP_NODE2=$(kubectl get pod pod-node2 -o jsonpath='{.status.podIP}')
kubectl exec pod-node1 -- ping -c 3 "$IP_NODE2"
kubectl exec pod-node1 -- traceroute -n "$IP_NODE2" 2>/dev/null || kubectl exec pod-node1 -- tracepath "$IP_NODE2"
```

5. Si el cluster tiene un solo nodo worker, documentá igual el resultado esperado: repetí el paso 4 conceptualmente y anotá que, en ese caso, ambos Pods comparten el mismo nodo y el tráfico nunca sale de la interfaz `cni0`/bridge local.

**Preguntas de comprensión:**

5. ¿Qué componente del cluster es responsable de que el tráfico entre `pod-node1` y `pod-node2` llegue a destino aunque estén en hosts físicos/VMs distintas?
6. Según el requisito fundamental del modelo de red de Kubernetes, ¿debería el resultado del ping cambiar según si los Pods están en el mismo nodo o en nodos distintos? ¿Por qué ese requisito es clave para que las aplicaciones no necesiten saber en qué nodo corre su destino?

---

## Ejercicio 4: Inspeccionar la implementación de red desde adentro del Pod

1. Desde `pod-node1`, revisá la tabla de rutas:

```bash
kubectl exec pod-node1 -- ip route
```

2. Identificá la interfaz de red y su dirección:

```bash
kubectl exec pod-node1 -- ip addr show eth0
```

3. Verificá la MTU configurada en la interfaz del Pod (relevante cuando el CNI usa overlay/encapsulación como VXLAN):

```bash
kubectl exec pod-node1 -- ip link show eth0 | grep -o 'mtu [0-9]*'
```

4. Consultá qué plugin CNI está en uso, inspeccionando el DaemonSet o los Pods del sistema en `kube-system` (el nombre varía según el CNI instalado: Calico, Cilium, Flannel, etc.):

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|flannel|weave|antrea'
```

5. Si tenés acceso a un nodo (por ejemplo con `kubectl debug node/<nombre> -it --image=nicolaka/netshoot`), revisá desde el host las interfaces `veth*` que corresponden a cada Pod:

```bash
kubectl debug node/$NODE1 -it --image=nicolaka/netshoot -- chroot /host ip -br link show
```

**Preguntas de comprensión:**

7. ¿Qué relación hay entre la interfaz `eth0` que ve el Pod y la interfaz `veth*` que se ve del lado del nodo host?
8. ¿Por qué la MTU de la interfaz del Pod puede ser distinta de la MTU física de la NIC del nodo, y en qué escenario de CNI eso importa?

---

## Ejercicio 5: Debugging de conectividad con ephemeral containers

1. Creá un Pod con una imagen mínima que **no** tenga herramientas de red (por ejemplo `busybox` recortado o una imagen distroless simulada con `nginx:alpine` sin shell de diagnóstico completo):

```bash
kubectl run pod-target --image=nginx:1.27-alpine --port=80
kubectl wait --for=condition=Ready pod/pod-target
```

2. Intentá diagnosticar conectividad directamente en ese container y notá las limitaciones (puede no tener `curl`, `ping`, etc.):

```bash
kubectl exec pod-target -- which curl ping nc 2>&1 || true
```

3. Adjuntá un **ephemeral container** de debugging al mismo Pod, que comparte su network namespace:

```bash
kubectl debug -it pod-target --image=nicolaka/netshoot --target=nginx -- bash
```

4. Dentro de esa sesión, verificá que estás en el mismo namespace de red que `pod-target` comprobando la IP y probando el puerto local del servidor `nginx`:

```bash
ip addr show eth0
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:80
```

5. Desde otro Pod (`pod-a` del Ejercicio 1, si sigue vivo) probá alcanzar `pod-target` en el puerto 80 usando su IP:

```bash
IP_TARGET=$(kubectl get pod pod-target -o jsonpath='{.status.podIP}')
kubectl exec pod-a -- curl -s -o /dev/null -w "%{http_code}\n" http://$IP_TARGET:80
```

**Preguntas de comprensión:**

9. ¿Por qué `kubectl debug --target=nginx` permite ver el tráfico y las interfaces del container `nginx` aunque el container de debugging sea una imagen completamente distinta e independiente?
10. ¿Qué diferencia hay, en términos de qué se comparte y qué no, entre agregar un ephemeral container con `--target` y crear un Pod nuevo aparte para hacer pruebas de conectividad?

---

<details>
<summary><strong>Respuestas</strong></summary>

1. Kubernetes exige que todos los Pods puedan comunicarse entre sí usando su IP de Pod sin necesidad de NAT (requisito fundamental del modelo de red "IP-per-Pod"). El CNI instalado en el cluster es responsable de programar las rutas necesarias para que esto funcione automáticamente, por eso el ping llega sin configurar nada adicional.

2. Sí, coinciden. Esto confirma que cada Pod tiene una única IP de cluster, visible tanto desde `kubectl` (plano de control) como desde adentro del propio Pod (plano de datos): no hay NAT interno entre "la IP que ve Kubernetes" y "la IP que ve la aplicación".

3. Porque todos los containers de un mismo Pod comparten el mismo network namespace de Linux (misma interfaz `eth0`, misma tabla de rutas, mismo espacio de puertos). `localhost` dentro de cualquier container del Pod apunta a esa interfaz compartida, por eso `curl localhost:80` desde `shell` llega al proceso `nginx` que escucha en `web`.

4. No, no sería posible: como comparten el mismo espacio de puertos del namespace de red, dos containers del mismo Pod no pueden bindear el mismo puerto simultáneamente (se produciría un conflicto de "address already in use"). Este es justamente el motivo por el que patrones como sidecars de proxy suelen requerir puertos distintos entre containers del mismo Pod.

5. El plugin CNI instalado en el cluster (por ejemplo Calico, Cilium, Flannel), en conjunto con `kube-proxy`/el dataplane correspondiente y el routing/overlay entre nodos que ese CNI configura. Es responsable de que el tráfico entre IPs de Pod atraviese la red física o virtual entre nodos y llegue a destino.

6. No debería cambiar: el resultado del ping tiene que ser exitoso en ambos casos, porque el requisito de "todos los Pods pueden alcanzarse entre sí sin NAT" es independiente de en qué nodo estén agendados. Esto es clave porque le permite a una aplicación (o a un Service que balancea entre Pods) tratar a todos los backends de la misma forma, sin lógica especial según ubicación, y hace que el scheduler pueda mover Pods libremente sin romper la conectividad.

7. Cada interfaz `eth0` dentro de un Pod es un extremo de un par `veth` (virtual ethernet pair): el otro extremo vive en el namespace de red del nodo host y normalmente se conecta a un bridge (por ejemplo `cni0`) o se maneja mediante rutas punto a punto, según el CNI. Es el mecanismo que conecta el namespace de red aislado del Pod con la red del nodo.

8. Cuando el CNI usa encapsulación (por ejemplo VXLAN en modo overlay), cada paquete que sale del Pod se envuelve con un header adicional para atravesar la red entre nodos. Ese overhead de encapsulación obliga a reducir la MTU efectiva dentro del Pod (por ejemplo de 1500 a 1450) para evitar fragmentación, aunque la NIC física del nodo siga configurada con la MTU estándar.

9. Porque un ephemeral container agregado con `kubectl debug --target=<container>` se une al **mismo Pod** y, según el runtime, puede compartir el network namespace (y opcionalmente el namespace de procesos) del container objetivo. Esto le da visibilidad directa sobre `localhost`, la interfaz `eth0` del Pod y, con `--target`, potencialmente sobre los procesos del container señalado.

10. Un ephemeral container con `--target` reutiliza el Pod existente: comparte su IP, su network namespace y (con `--target`) puede compartir el namespace de procesos del container objetivo, sin alterar el Pod original de forma persistente ni cambiar su IP. Crear un Pod nuevo aparte, en cambio, da una IP y un network namespace completamente distintos, por lo que cualquier prueba de conectividad hacia el Pod original tiene que hacerse "desde afuera", igual que lo haría cualquier otro cliente en el cluster.

</details>