# CKA 2.5 — Troubleshoot Services and Networking

**Certificación:** CKA (Certified Kubernetes Administrator), examen v1.35
**Tema del currículum:** 2.5 Troubleshoot services and networking (peso: 6)
**Fuente de referencia:** [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Estos ejercicios asumen un cluster funcional (kubeadm, kind o similar) con al menos dos nodos y un plugin CNI instalado (Calico, Cilium, etc.). Ejecutá los comandos en orden; cada bloque termina con preguntas para chequear que entendiste el porqué, no solo el comando.

---

## Ejercicio 1 — Service sin Endpoints (selector mismatch)

Uno de los fallos más comunes en el examen: un `Service` existe, tiene `ClusterIP`, pero el tráfico nunca llega a ningún Pod.

1. Creá un Deployment de prueba:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   kubectl label pods -l app=web tier=frontend --overwrite
   ```
2. Creá un Service con un selector que **no coincide a propósito**:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 --name=web-svc \
     --overrides='{"spec":{"selector":{"tier":"backend"}}}'
   ```
3. Verificá el estado del Service:
   ```bash
   kubectl get svc web-svc
   kubectl describe svc web-svc
   ```
4. Inspeccioná los Endpoints/EndpointSlices asociados:
   ```bash
   kubectl get endpoints web-svc
   kubectl get endpointslices -l kubernetes.io/service-name=web-svc
   ```
5. Compará el selector del Service contra las labels reales de los Pods:
   ```bash
   kubectl get pods --show-labels -l app=web
   kubectl get svc web-svc -o jsonpath='{.spec.selector}{"\n"}'
   ```
6. Corregí el selector para que coincida:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'
   ```
7. Confirmá que ahora el Service tiene Endpoints:
   ```bash
   kubectl get endpoints web-svc
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Qué campo de `kubectl describe svc` te indica inmediatamente que algo está mal, incluso antes de mirar los Endpoints?
2. ¿Por qué un Service sin Endpoints no genera ningún error visible en `kubectl get svc` (el `ClusterIP` sigue asignado)?
3. ¿Qué diferencia hay entre el objeto `Endpoints` (legacy) y `EndpointSlice`, y cuál deberías preferir para diagnosticar en clusters grandes?

</blockquote>

---

## Ejercicio 2 — Pod healthy pero excluido de los Endpoints (readiness)

Un selector correcto no garantiza que el Pod reciba tráfico: si falla el `readinessProbe`, el Pod se excluye de los Endpoints aunque esté `Running`.

1. Editá uno de los Pods del deployment `web` para agregar una readiness probe que siempre falla:
   ```bash
   kubectl get pods -l app=web -o name
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/no-existe","port":80},"periodSeconds":5}}]}}}}'
   ```
2. Esperá a que rueden los nuevos Pods y observá su estado:
   ```bash
   kubectl rollout status deployment/web
   kubectl get pods -l app=web -o wide
   ```
3. Notá la columna `READY` (por ejemplo `0/1`) y revisá los eventos:
   ```bash
   kubectl describe pod -l app=web | grep -A5 Events
   ```
4. Verificá que el Service ya no tiene esos Pods como Endpoints:
   ```bash
   kubectl get endpoints web-svc
   ```
5. Corregí la probe apuntando a un path válido:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/","port":80},"periodSeconds":5}}]}}}}'
   ```
6. Confirmá la recuperación:
   ```bash
   kubectl rollout status deployment/web
   kubectl get endpoints web-svc
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Por qué un Pod `Running` puede seguir sin recibir tráfico del Service?
2. ¿Qué diferencia práctica hay entre `livenessProbe` y `readinessProbe` en el contexto de troubleshooting de Services?
3. ¿Dónde queda registrado el fallo repetido de una readiness probe si querés confirmarlo sin esperar al próximo ciclo de `describe`?

</blockquote>

---

## Ejercicio 3 — Diagnóstico de kube-proxy (modo iptables)

Cuando el Service tiene Endpoints correctos pero el tráfico igual no llega, el problema puede estar en kube-proxy.

1. Identificá el modo de kube-proxy en uso:
   ```bash
   kubectl -n kube-system get configmap kube-proxy -o yaml | grep mode
   ```
2. Verificá que el DaemonSet de kube-proxy está corriendo en todos los nodos:
   ```bash
   kubectl -n kube-system get ds kube-proxy -o wide
   kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
   ```
3. Revisá los logs de un Pod de kube-proxy en el nodo donde corre uno de los Pods de `web`:
   ```bash
   kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=50
   ```
4. Entrá (o usá `kubectl debug`) al nodo y listá las reglas iptables generadas para el Service:
   ```bash
   kubectl get svc web-svc -o jsonpath='{.spec.clusterIP}{"\n"}'
   sudo iptables -t nat -L KUBE-SERVICES -n | grep <CLUSTER-IP>
   ```
5. Si no aparecen reglas para ese ClusterIP, forzá un reinicio del Pod de kube-proxy en ese nodo:
   ```bash
   kubectl -n kube-system delete pod <kube-proxy-pod-en-ese-nodo>
   ```
6. Volvé a verificar las reglas y probá conectividad desde otro Pod:
   ```bash
   kubectl run tmp-curl --rm -it --image=busybox --restart=Never -- \
     wget -qO- http://web-svc.default.svc.cluster.local
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Qué cadena de iptables deberías buscar primero para confirmar que kube-proxy programó reglas para un Service en particular?
2. Si el cluster usa modo `ipvs` en vez de `iptables`, ¿qué comando reemplaza a `iptables -t nat -L` para inspeccionar las reglas?
3. ¿Por qué reiniciar el Pod de kube-proxy puede "arreglar" temporalmente el problema, y qué indica eso sobre la causa raíz?

</blockquote>

---

## Ejercicio 4 — Fallos de resolución DNS (CoreDNS)

1. Verificá que CoreDNS está corriendo:
   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-dns
   kubectl -n kube-system get svc kube-dns
   ```
2. Lanzá un Pod de diagnóstico con herramientas de red:
   ```bash
   kubectl run dnsutils --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
     --restart=Never -- /bin/sh
   ```
3. Dentro del Pod, probá resolver el Service creado en el Ejercicio 1:
   ```bash
   nslookup web-svc.default.svc.cluster.local
   cat /etc/resolv.conf
   ```
4. Si la resolución falla, salí y revisá los logs de CoreDNS:
   ```bash
   kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
   ```
5. Revisá el ConfigMap de CoreDNS por errores de sintaxis en el `Corefile`:
   ```bash
   kubectl -n kube-system get configmap coredns -o yaml
   ```
6. Verificá que la policy de DNS del Pod de prueba sea la esperada:
   ```bash
   kubectl get pod dnsutils -o jsonpath='{.spec.dnsPolicy}{"\n"}'
   ```
7. Si CoreDNS tiene un `Corefile` corrupto, restaurá la configuración por defecto y reiniciá el Deployment:
   ```bash
   kubectl -n kube-system rollout restart deployment coredns
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Qué formato exacto de FQDN interno se espera al resolver un Service (`<svc>.<namespace>.svc.cluster.local`)?
2. ¿Qué valores del `/etc/resolv.conf` de un Pod (`nameserver`, `search`, `options ndots`) explican por qué a veces una resolución corta funciona y una larga no, o viceversa?
3. ¿Qué diferencia hay entre un problema de DNS a nivel de Pod (dnsPolicy mal configurada) y uno a nivel de cluster (CoreDNS caído o mal configurado)?

</blockquote>

---

## Ejercicio 5 — NetworkPolicy bloqueando tráfico

1. Creá un namespace aislado y dos Deployments (cliente y servidor):
   ```bash
   kubectl create namespace netpol-test
   kubectl -n netpol-test create deployment server --image=nginx
   kubectl -n netpol-test expose deployment server --port=80
   kubectl -n netpol-test run client --image=busybox --restart=Never -- sleep 3600
   ```
2. Confirmá que hay conectividad inicial:
   ```bash
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```
3. Aplicá una NetworkPolicy que deniega todo el ingreso al `server`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-all-ingress
     namespace: netpol-test
   spec:
     podSelector:
       matchLabels:
         app: server
     policyTypes:
       - Ingress
   ```
   ```bash
   kubectl apply -f deny-all-ingress.yaml
   ```
4. Repetí la prueba de conectividad y observá el timeout:
   ```bash
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```
5. Listá las NetworkPolicies del namespace para confirmar cuál está aplicando la restricción:
   ```bash
   kubectl -n netpol-test get networkpolicy
   kubectl -n netpol-test describe networkpolicy deny-all-ingress
   ```
6. Corregí la policy permitiendo tráfico solo desde Pods con label `role=client`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-client-ingress
     namespace: netpol-test
   spec:
     podSelector:
       matchLabels:
         app: server
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 role: client
   ```
7. Etiquetá el Pod cliente y volvé a probar:
   ```bash
   kubectl -n netpol-test label pod client role=client
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Por qué una NetworkPolicy que solo especifica `Ingress` en `policyTypes` no afecta el tráfico saliente (`Egress`) del Pod seleccionado?
2. Si el CNI instalado no soporta `NetworkPolicy` (por ejemplo Flannel puro), ¿qué comportamiento verías al aplicar el YAML de este ejercicio?
3. ¿Qué diferencia hay entre "no hay ninguna NetworkPolicy" y "hay una NetworkPolicy que selecciona el Pod pero con una lista `from` vacía"?

</blockquote>

---

## Ejercicio 6 — Ingress que no enruta correctamente

1. Verificá que el Ingress Controller está desplegado y corriendo (ejemplo con ingress-nginx):
   ```bash
   kubectl -n ingress-nginx get pods
   kubectl -n ingress-nginx get svc
   ```
2. Creá un Ingress apuntando a un Service con un nombre de puerto **incorrecto a propósito**:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
     namespace: default
   spec:
     ingressClassName: nginx
     rules:
       - host: web.example.local
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: web-svc
                   port:
                     number: 8080
   ```
   ```bash
   kubectl apply -f web-ingress.yaml
   ```
3. Revisá el estado del recurso Ingress:
   ```bash
   kubectl get ingress web-ingress
   kubectl describe ingress web-ingress
   ```
4. Buscá en la sección de eventos o en los logs del controller el motivo del fallo:
   ```bash
   kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=50
   ```
5. Confirmá el puerto real expuesto por el Service:
   ```bash
   kubectl get svc web-svc -o jsonpath='{.spec.ports[0].port}{"\n"}'
   ```
6. Corregí el Ingress con el puerto correcto (80) y reaplicá:
   ```bash
   kubectl patch ingress web-ingress --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'
   ```
7. Probá el acceso end-to-end (agregando el host al `/etc/hosts` local o usando `curl --resolve`):
   ```bash
   curl --resolve web.example.local:80:$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}') \
     http://web.example.local/
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Qué diferencia hay entre un problema de Ingress (routing L7) y un problema de Service (routing L4) al momento de diagnosticar, y por cuál conviene empezar?
2. ¿Qué rol cumple el campo `ingressClassName` y qué pasa si no coincide con ningún IngressClass instalado en el cluster?
3. ¿Por qué revisar los logs del Ingress Controller es más informativo que solo mirar `kubectl describe ingress` cuando el backend responde con errores 502/503?

</blockquote>

---

## Ejercicio 7 — Conectividad Pod-a-Pod entre nodos (CNI)

1. Identificá en qué nodos corren los Pods del deployment `web`:
   ```bash
   kubectl get pods -l app=web -o wide
   ```
2. Tomá las IPs de Pod (no de Service) y probá conectividad directa desde un Pod en otro nodo:
   ```bash
   kubectl run tmp-ping --rm -it --image=busybox --restart=Never --overrides='{"spec":{"nodeName":"<nodo-B>"}}' -- \
     wget -qO- --timeout=3 http://<POD-IP-en-nodo-A>
   ```
3. Si falla, verificá el estado de los Pods del CNI (por ejemplo Calico) en ambos nodos:
   ```bash
   kubectl -n kube-system get pods -o wide | grep -Ei 'calico|cilium|flannel'
   ```
4. Revisá logs del agente CNI en el nodo problemático:
   ```bash
   kubectl -n kube-system logs <pod-cni-en-nodo-problemático> --tail=50
   ```
5. Verificá las rutas y la interfaz del CNI a nivel de nodo:
   ```bash
   ip route show
   ip addr show
   ```
6. Confirmá que el nodo no tiene un `NetworkUnavailable` taint pendiente:
   ```bash
   kubectl describe node <nodo-B> | grep -A3 Taints
   kubectl describe node <nodo-B> | grep -i networkunavailable
   ```
7. Si el problema era el CNI caído, reiniciá su DaemonSet y repetí el test:
   ```bash
   kubectl -n kube-system rollout restart daemonset <nombre-daemonset-cni>
   ```

<blockquote>

**Preguntas de verificación:**
1. ¿Por qué probar con la IP del Pod directamente (en vez de la del Service) ayuda a aislar si el problema está en kube-proxy o en el CNI?
2. ¿Qué significa la condición `NetworkUnavailable` en un nodo y qué componente es responsable de limpiarla una vez que el CNI está operativo?
3. ¿Qué diferencia de alcance hay entre un problema de CNI a nivel de un solo nodo (agente caído) y uno a nivel de cluster (mala configuración del pool de IPs)?

</blockquote>

---

<details>
<summary><strong>Ver respuestas</strong></summary>

### Ejercicio 1
1. `kubectl describe svc` muestra el campo `Endpoints: <none>` cuando ningún Pod coincide con el selector — esa es la primera señal.
2. El `ClusterIP` se asigna al crear el objeto `Service` en el API server, independientemente de si existen Pods que lo respalden; el enrutamiento efectivo depende de un paso posterior y separado (selector → Endpoints → reglas de kube-proxy).
3. `Endpoints` es un único objeto por Service con una lista plana de todas las IPs (no escala bien en clusters grandes); `EndpointSlice` divide esa lista en múltiples objetos de hasta 100 entradas cada uno y es la API recomendada desde 1.19+, usada internamente por kube-proxy.

### Ejercicio 2
1. La readiness probe determina si el Pod se incluye en los Endpoints del Service; un Pod puede estar `Running` (el proceso vive) pero fallar su readiness (la app no responde correctamente), quedando excluido del balanceo.
2. `livenessProbe` decide si el kubelet reinicia el contenedor; `readinessProbe` decide si el Pod recibe tráfico del Service — un fallo de liveness reinicia el Pod, un fallo de readiness solo lo saca temporalmente del pool de Endpoints sin reiniciarlo.
3. En los `Events` del `kubectl describe pod`, donde aparecen mensajes tipo `Readiness probe failed` con el código de estado HTTP recibido.

### Ejercicio 3
1. La cadena `KUBE-SERVICES` en la tabla `nat`, que es el punto de entrada donde kube-proxy programa el salto hacia las reglas específicas de cada Service (`KUBE-SVC-*` / `KUBE-SEP-*`).
2. `ipvsadm -Ln` (o `ipvsadm -L -n`), que lista los virtual servers y real servers gestionados por IPVS en lugar de reglas iptables.
3. Reiniciar el Pod de kube-proxy fuerza una resincronización completa de las reglas contra el estado actual de Services/Endpoints; si eso "arregla" el problema, indica que kube-proxy no estaba procesando correctamente los eventos de watch (por ejemplo, se quedó desincronizado o crasheó silenciosamente), no que el problema esté resuelto de forma permanente si la causa (por ejemplo recursos insuficientes o un bug) persiste.

### Ejercicio 4
1. `<nombre-service>.<namespace>.svc.cluster.local` (por ejemplo `web-svc.default.svc.cluster.local`).
2. `ndots:5` (valor por defecto) hace que cualquier nombre con menos de 5 puntos se intente primero con los sufijos de `search` antes que como FQDN absoluto; esto explica por qué un nombre corto como `web-svc` puede tardar más o fallar en ciertos escenarios (por ejemplo, resolviendo primero contra dominios externos con muchos intentos) mientras que el FQDN completo con punto final resuelve directo.
3. Un problema a nivel de Pod (dnsPolicy incorrecta, por ejemplo `None` sin `dnsConfig`, o un `/etc/resolv.conf` sobrescrito) afecta solo a ese Pod; un problema a nivel de cluster (CoreDNS caído, Corefile corrupto, Service `kube-dns` sin Endpoints) afecta a todos los Pods que dependen de la resolución interna.

### Ejercicio 5
1. Porque `Ingress` y `Egress` son tipos de regla independientes: si `policyTypes` solo lista `Ingress`, el Egress del Pod queda gobernado por el comportamiento por defecto (permitir todo), salvo que otra policy lo restrinja explícitamente.
2. El recurso `NetworkPolicy` se crearía sin error en el API server (es solo un objeto de la API `networking.k8s.io`), pero no tendría ningún efecto real sobre el tráfico, ya que el CNI es el que debe implementar el enforcement; sin soporte, el comportamiento observado seguiría siendo "todo permitido".
3. Sin ninguna NetworkPolicy, todo el tráfico está permitido por defecto. Con una NetworkPolicy que selecciona el Pod pero con `ingress: []` (o sin bloque `ingress` bajo `policyTypes: [Ingress]`), el efecto es denegar todo el ingreso, porque la ausencia de reglas `from` que permitan tráfico se interpreta como "ningún origen permitido".

### Ejercicio 6
1. El Ingress opera en la capa de aplicación (HTTP/HTTPS, routing por host/path) y depende de que el Service subyacente (capa de transporte) ya funcione correctamente; conviene primero confirmar con `kubectl exec`/`curl` que el Service resuelve y responde directamente, y recién después diagnosticar el Ingress, para no confundir un problema L4 con uno L7.
2. `ingressClassName` le dice al controller correcto cuál Ingress debe procesar (permite tener varios controllers en el mismo cluster); si no coincide con ningún `IngressClass` instalado, ningún controller toma ese recurso y el Ingress queda sin implementar (sin IP/dirección asignada, sin logs de error asociados en el controller equivocado).
3. Los logs del controller muestran el intento real de conexión hacia el backend (el Service/Pod), incluyendo el código de error devuelto por upstream; `kubectl describe ingress` solo muestra el estado del recurso y sus reglas, no la interacción en tiempo real con el backend.

### Ejercicio 7
1. Si la conexión a la IP del Pod falla, el problema está por debajo del nivel de Service (CNI, ruteo entre nodos, firewall del host); si la IP del Pod funciona pero el ClusterIP del Service no, el problema está aislado a kube-proxy o a las reglas de NAT.
2. Indica que el kubelet de ese nodo aún no confirmó que la red de Pods está lista (el plugin CNI no reportó éxito); el propio kubelet retira esa condición del nodo una vez que el plugin CNI se inicializa correctamente y responde al chequeo de red.
3. Un fallo a nivel de un solo nodo (agente CNI caído o crasheado en ese nodo) solo afecta la conectividad hacia/desde los Pods de ese nodo específico; un fallo de configuración a nivel de cluster (por ejemplo, solapamiento de rangos de IP entre nodos o un IPPool mal definido) puede afectar la conectividad de forma más amplia e impredecible entre múltiples nodos simultáneamente.

</details>
