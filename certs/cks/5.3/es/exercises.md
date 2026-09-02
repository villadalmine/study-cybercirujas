# CKS 5.3 — Minimizar el Acceso Externo a la Red
## Ejercicios Guiados (Kubernetes v1.34)

> **Dominio:** System Hardening · **Peso en el examen:** 2.5 %
> **Objetivo:** reducir la superficie alcanzable de un nodo Kubernetes y de las cargas de trabajo que corren en él — a nivel del host (filtro de paquetes del kernel, servicios systemd, sshd), a nivel de los componentes del control plane (direcciones de bind, puertos), y a nivel de la API de Kubernetes (tipos de Service, alcance del bind de `kube-proxy`, NetworkPolicy, admission control).

### Supuestos del laboratorio

| Ítem | Valor |
|---|---|
| Cluster | `kubeadm`, Kubernetes **v1.34** |
| Control plane | `cp01` — `192.168.56.10` |
| Worker | `w01` — `192.168.56.11` |
| SO del nodo | Ubuntu 24.04 LTS, backend `nftables` |
| CNI | Calico (sirve cualquier CNI con soporte de NetworkPolicy) |
| Pod CIDR / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` |
| Acceso | `root` (o `sudo`) en ambos nodos, kubeconfig `cluster-admin` |

> **Advertencia — no ejecutes esto en un cluster que te importe sin tener un snapshot.** Varios pasos modifican el estado del filtro de paquetes y la configuración del kubelet. Cada ejercicio termina con un paso de rollback.

---

## Ejercicio 1 — Construir un inventario fehaciente de la superficie de escucha del nodo

No podés minimizar lo que no enumeraste. Las reglas de firewall escritas de memoria son la razón por la que el puerto `10255` queda abierto durante tres años.

1. En `cp01`, listá todos los sockets TCP en escucha junto con el proceso propietario:

   ```bash
   sudo ss -lntp
   ```

   Esperado (abreviado, nodo de control plane):

   ```
   State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
   LISTEN  0       4096     127.0.0.1:10248      0.0.0.0:*          users:(("kubelet",pid=921,fd=20))
   LISTEN  0       4096     127.0.0.1:10249      0.0.0.0:*          users:(("kube-proxy",pid=1755,fd=14))
   LISTEN  0       4096     127.0.0.1:2379       0.0.0.0:*          users:(("etcd",pid=1402,fd=9))
   LISTEN  0       4096  192.168.56.10:2379      0.0.0.0:*          users:(("etcd",pid=1402,fd=10))
   LISTEN  0       4096  192.168.56.10:2380      0.0.0.0:*          users:(("etcd",pid=1402,fd=8))
   LISTEN  0       4096     127.0.0.1:2381       0.0.0.0:*          users:(("etcd",pid=1402,fd=12))
   LISTEN  0       4096     127.0.0.1:10257      0.0.0.0:*          users:(("kube-controller",pid=1385,fd=3))
   LISTEN  0       4096     127.0.0.1:10259      0.0.0.0:*          users:(("kube-scheduler",pid=1361,fd=3))
   LISTEN  0       4096       0.0.0.0:10250      0.0.0.0:*          users:(("kubelet",pid=921,fd=21))
   LISTEN  0       4096       0.0.0.0:10256      0.0.0.0:*          users:(("kube-proxy",pid=1755,fd=16))
   LISTEN  0       4096             *:6443             *:*          users:(("kube-apiserver",pid=1420,fd=3))
   LISTEN  0       4096       0.0.0.0:22         0.0.0.0:*          users:(("sshd",pid=804,fd=3))
   ```

2. Hacé lo mismo para UDP, e incluí los sockets que mantienen los contenedores en el network namespace del host:

   ```bash
   sudo ss -lunp
   sudo lsof -nP -i -sTCP:LISTEN | awk '{print $1, $2, $9}' | sort -u
   ```

3. Separá lo "bindeado a loopback" de lo "bindeado al mundo". Este es el comando de triaje más útil de todo el dominio:

   ```bash
   sudo ss -lntH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\])' | sort -u
   ```

   Esperado:

   ```
   *:6443
   0.0.0.0:10250
   0.0.0.0:10256
   0.0.0.0:22
   192.168.56.10:2379
   192.168.56.10:2380
   ```

4. Confirmá el panorama desde *afuera* del nodo — un `ss` local no puede decirte qué está bloqueando ya un firewall. Desde `w01`:

   ```bash
   nmap -Pn -n -sS -p 22,2379,2380,6443,10248-10260,30000-30010 192.168.56.10
   ```

   Esperado:

   ```
   PORT      STATE    SERVICE
   22/tcp    open     ssh
   2379/tcp  open     etcd-client
   2380/tcp  open     etcd-server
   6443/tcp  open     sun-sr-https
   10250/tcp open     unknown
   10256/tcp open     unknown
   10248/tcp filtered unknown
   ```

5. Guardá un snapshot del inventario para poder hacer diff después de cada cambio:

   ```bash
   sudo ss -lntuH | awk '{print $1, $5}' | sort -u | sudo tee /root/baseline-listeners.txt
   ```

**Preguntas**

- **Q1.1** — En el paso 3 excluiste `127.0.0.1`. ¿Por qué un componente escuchando en `127.0.0.1:10257` es materialmente más seguro que uno escuchando en `0.0.0.0:10257`, dado que ambos están en el mismo host?
- **Q1.2** — `nmap` reporta `10248/tcp filtered` mientras que `ss` en el nodo lo muestra en `LISTEN`. Explicá la discrepancia, y decí qué significa `filtered` en oposición a `closed`.
- **Q1.3** — `kube-proxy` bindea `10249` a `127.0.0.1` pero `10256` a `0.0.0.0`. ¿Qué son esos dos puertos, y por qué difiere el default?
- **Q1.4** — Un pod que corre con `hostNetwork: true` abre un listener en `0.0.0.0:9000`. ¿Aparecería en `ss -lntp` en el nodo? ¿Y un pod normal que expone `containerPort: 9000`?

---

## Ejercicio 2 — Cerrar las superficies no autenticadas del kubelet

El kubelet es el objetivo de mayor valor en cualquier nodo: el puerto `10250` da `exec` dentro de cada contenedor que ejecuta.

1. Ubicá la configuración del kubelet e inspeccioná las claves relevantes para la seguridad:

   ```bash
   sudo grep -E 'readOnlyPort|anonymous|authorization|mode:|enabled:|healthzPort|port:' \
     -A1 /var/lib/kubelet/config.yaml
   ```

   Esperado en un nodo `kubeadm` bien configurado:

   ```yaml
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
   authorization:
     mode: Webhook
   ```

2. **No confíes en una clave ausente.** `readOnlyPort` toma por defecto el valor `10255` en el propio código de defaulting del kubelet cuando no está seteada. Verificá empíricamente en lugar de leer el archivo:

   ```bash
   sudo ss -lntp | grep -E ':(10250|10255|10248)\b'
   curl -s --max-time 3 http://192.168.56.10:10255/pods | head -c 200; echo
   ```

   Si `10255` está abierto vas a obtener un volcado JSON no autenticado de todos los pods del nodo — incluyendo valores de `env` inyectados desde ConfigMaps:

   ```
   {"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-cp01",...
   ```

3. Sondeá el puerto autenticado de forma anónima y confirmá que te rechaza:

   ```bash
   curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.56.10:10250/pods
   ```

   Esperado: `401`.
   `403` significaría que la *autenticación* anónima tuvo éxito y que solo la *autorización* te detuvo — una postura más débil. `200` significa que el nodo está totalmente comprometido para cualquiera que pueda alcanzarlo.

4. Endurecé explícitamente. Editá `/var/lib/kubelet/config.yaml`:

   ```yaml
   apiVersion: kubelet.config.k8s.io/v1beta1
   kind: KubeletConfiguration
   readOnlyPort: 0
   healthzBindAddress: 127.0.0.1
   healthzPort: 10248
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
       cacheTTL: 2m0s
     x509:
       clientCAFile: /etc/kubernetes/pki/ca.crt
   authorization:
     mode: Webhook
   ```

5. Aplicá y verificá:

   ```bash
   sudo systemctl restart kubelet
   sudo systemctl is-active kubelet
   sudo ss -lntp | grep -E ':(10250|10255)\b'
   kubectl get nodes
   ```

   Esperado: solo queda `10250`; el nodo permanece `Ready`.

6. Confirmá que el puerto de solo lectura desapareció desde afuera:

   ```bash
   curl -s --max-time 3 http://192.168.56.10:10255/pods || echo "refused/timeout — good"
   ```

**Preguntas**

- **Q2.1** — Con `authentication.anonymous.enabled: false` y `authorization.mode: Webhook`, describí de punta a punta qué sucede cuando el API server llama a `POST /exec/...` en el kubelet. ¿Qué dos objetos de la API consulta la ruta del webhook?
- **Q2.2** — ¿Por qué `authorization.mode: AlwaysAllow` es catastrófico incluso con la autenticación anónima deshabilitada?
- **Q2.3** — `readOnlyPort: 10255` no sirve operaciones de escritura. Dá dos piezas concretas de datos sensibles que un atacante extrae de ahí, y nombrá el endpoint de cada una.
- **Q2.4** — Después de que setees `readOnlyPort: 0`, un agente de monitoreo que scrapeaba `http://$NODE_IP:10255/metrics/cadvisor` se rompe. ¿Cuál es la ruta de reemplazo correcta, y qué identidad necesita ahora el scraper?

---

## Ejercicio 3 — Verificar las direcciones de bind de los componentes restantes del control plane

1. Inspeccioná los manifiestos de los static pods buscando los flags que deciden *quién puede alcanzar* cada componente:

   ```bash
   sudo grep -HE 'bind-address|listen-client-urls|listen-peer-urls|listen-metrics-urls|secure-port' \
     /etc/kubernetes/manifests/*.yaml
   ```

   Esperado:

   ```
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.10:2379
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-metrics-urls=http://127.0.0.1:2381
   /etc/kubernetes/manifests/etcd.yaml:    - --listen-peer-urls=https://192.168.56.10:2380
   /etc/kubernetes/manifests/kube-apiserver.yaml:    - --bind-address=0.0.0.0
   /etc/kubernetes/manifests/kube-apiserver.yaml:    - --secure-port=6443
   /etc/kubernetes/manifests/kube-controller-manager.yaml:    - --bind-address=127.0.0.1
   /etc/kubernetes/manifests/kube-scheduler.yaml:    - --bind-address=127.0.0.1
   ```

2. Comprobá que el binding a loopback realmente se sostiene, desde `w01`:

   ```bash
   curl -sk --max-time 3 https://192.168.56.10:10259/healthz || echo "unreachable — expected"
   curl -sk --max-time 3 https://192.168.56.10:2379/health   || echo "unreachable or TLS-rejected"
   ```

3. En un cluster con un solo control plane, `etcd` no tiene peers, así que `2380` no necesita estar en la LAN. Angostá también la client URL — pero entendé primero la restricción:

   ```bash
   sudo grep -E 'advertise-client-urls|initial-advertise-peer-urls' /etc/kubernetes/manifests/etcd.yaml
   ```

   ```
   - --advertise-client-urls=https://192.168.56.10:2379
   - --initial-advertise-peer-urls=https://192.168.56.10:2380
   ```

4. En lugar de cambiar la topología de `etcd` (lo que rompe el scale-out de HA más adelante), aplicá la restricción en el filtro de paquetes — se hace en el Ejercicio 4.

5. Confirmá que `etcd` rechaza clientes no autenticados incluso cuando es alcanzable:

   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://192.168.56.10:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt endpoint health
   ```

   Esperado: una falla de handshake TLS — `etcd` requiere un certificado de cliente (`--client-cert-auth=true`).

**Preguntas**

- **Q3.1** — `kube-apiserver` bindea `0.0.0.0` mientras que `kube-scheduler` bindea `127.0.0.1`. Justificá ambos defaults en términos de quiénes son los clientes legítimos de cada componente.
- **Q3.2** — ¿Por qué restringir el acceso de red a `etcd` es un control de *defensa en profundidad* y no el control primario, y cuál es el primario?
- **Q3.3** — `--listen-metrics-urls=http://127.0.0.1:2381` es HTTP plano. ¿Es un hallazgo? Justificá.
- **Q3.4** — Seteás `--bind-address=127.0.0.1` en `kube-apiserver` en un cluster de un solo nodo y el cluster sigue funcionando desde ese nodo, pero el `kubelet` en `w01` pasa a `NotReady`. Explicá la cadena de falla.

---

## Ejercicio 4 — Filtro de paquetes del host con `nftables`, sin romper `kube-proxy`

Un nodo Kubernetes *ya es* un appliance de filtrado de paquetes: `kube-proxy` y el CNI son dueños de grandes conjuntos de reglas. El hardening ingenuo (`iptables -F`, `ufw enable` con un `FORWARD DROP` por defecto) corta la red de pods.

1. Mirá lo que ya está instalado antes de agregar nada:

   ```bash
   sudo nft list ruleset | grep -E '^table' 
   sudo iptables-save | grep -c '^-A KUBE'
   ```

   Esperado:

   ```
   table ip kube-proxy
   table ip6 kube-proxy
   table inet filter
   table ip nat
   1274
   ```

2. Creá tu **propia** tabla para no editar nunca una chain que otro controlador reconcilia. `nftables` evalúa *todas* las base chains registradas en un hook, en orden de prioridad, y un veredicto `drop` en cualquiera de ellas es definitivo:

   ```bash
   sudo tee /etc/nftables.d/cks-host-guard.nft >/dev/null <<'EOF'
   table inet cks_guard
   delete table inet cks_guard

   table inet cks_guard {
     set trusted_cp {
       type ipv4_addr
       flags interval
       elements = { 192.168.56.10/32, 192.168.56.11/32 }
     }

     set admin_net {
       type ipv4_addr
       flags interval
       elements = { 192.168.56.0/24 }
     }

     chain input {
       type filter hook input priority filter - 10; policy accept;

       ct state established,related accept
       ct state invalid drop
       iif lo accept

       # Cluster-internal sources are exempt from the rules below
       ip saddr @trusted_cp accept
       iifname { "cali*", "tunl0", "vxlan.calico", "cni0", "flannel.1" } accept

       # Restrict the sensitive control-plane ports to the admin network
       tcp dport { 2379, 2380, 10250, 10256, 10257, 10259 } ip saddr != @admin_net \
         log prefix "cks-guard-drop-cp " level warn counter drop

       # SSH from the admin network only
       tcp dport 22 ip saddr != @admin_net counter drop
     }
   }
   EOF
   ```

3. Cargala y confirmá que existen los contadores:

   ```bash
   sudo nft -f /etc/nftables.d/cks-host-guard.nft
   sudo nft list table inet cks_guard
   ```

4. Hacé que sobreviva al reboot (Debian/Ubuntu):

   ```bash
   grep -q 'nftables.d' /etc/nftables.conf || \
     echo 'include "/etc/nftables.d/*.nft"' | sudo tee -a /etc/nftables.conf
   sudo systemctl enable --now nftables
   ```

5. Validá desde un origen *fuera* de la red de administración (o simulá con una IP de origen distinta), y después validá que el cluster está intacto:

   ```bash
   kubectl get nodes
   kubectl -n kube-system get pods -o wide | head
   kubectl run probe --image=nicolaka/netshoot --restart=Never --rm -it -- \
     curl -s -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc/version -k
   ```

   Esperado: nodos `Ready`, pods `Running`, la prueba devuelve `401` o `403` (alcanzabilidad probada; la authn es un asunto separado).

6. Inspeccioná los contadores de drop después de un intento de sondeo:

   ```bash
   sudo nft list table inet cks_guard | grep -A1 counter
   sudo journalctl -k -g 'cks-guard-drop-cp' -n 20
   ```

7. Rollback:

   ```bash
   sudo nft delete table inet cks_guard
   ```

**Preguntas**

- **Q4.1** — ¿Por qué `ct state established,related accept` se coloca *antes* de toda regla de drop, y qué se rompe si lo omitís mientras dropeás `10250` entrante?
- **Q4.2** — Explicá con precisión por qué `iptables -F` en un nodo worker rompe el tráfico de Services, y por qué el daño puede parecer "curarse solo" al cabo de un rato.
- **Q4.3** — Agregaste una base chain en `priority filter - 10` en tu propia tabla en lugar de anexar a `table inet filter`. Enunciá dos ventajas operativas.
- **Q4.4** — Un colega ejecuta `ufw default deny incoming && ufw enable` en un nodo. El tráfico pod-a-pod entre nodos se detiene. ¿Qué chain de `ufw`/`iptables` es la responsable, y cuál es el arreglo mínimo correcto?

---

## Ejercicio 5 — Por qué una regla `INPUT` no bloquea un NodePort (y qué sí lo hace)

Esta es la tarea de "minimizar el acceso externo" que más se falla en la práctica.

1. Creá un Service NodePort:

   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=2
   kubectl expose deployment web --type=NodePort --port=80 --name=web-np
   kubectl get svc web-np
   ```

   Esperado:

   ```
   NAME     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
   web-np   NodePort   10.107.24.11    <none>        80:31544/TCP   5s
   ```

2. Confirmá que es alcanzable desde fuera del cluster:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.11:31544/
   ```

   Esperado: `200`.

3. Intentá bloquearlo con una regla `input` obvia:

   ```bash
   sudo nft add table inet np_test
   sudo nft add chain inet np_test input '{ type filter hook input priority filter; policy accept; }'
   sudo nft add rule inet np_test input tcp dport 31544 counter drop
   curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://192.168.56.11:31544/
   sudo nft list table inet np_test
   ```

   Esperado: sigue siendo `200`, y el contador marca `packets 0 bytes 0`.

4. Explicalo con `conntrack` — el paquete recibió DNAT en `prerouting` **antes** de la decisión de ruteo, así que tomó el hook `forward`, nunca `input`:

   ```bash
   sudo conntrack -L -p tcp --dport 31544 2>/dev/null | head -3
   ```

   ```
   tcp 6 118 TIME_WAIT src=192.168.56.1 dst=192.168.56.11 sport=51022 dport=31544 \
       src=10.244.1.7 dst=192.168.56.1 sport=80 dport=51022 [ASSURED]
   ```

5. Bloqueala correctamente — filtrá **antes** de `dstnat` (prioridad `-100`):

   ```bash
   sudo nft flush table inet np_test
   sudo nft add chain inet np_test prerouting \
     '{ type filter hook prerouting priority -160; policy accept; }'
   sudo nft add rule inet np_test prerouting ip saddr != 192.168.56.0/24 \
     tcp dport 30000-32767 counter drop
   ```

6. O, equivalentemente, matcheá el puerto de destino pre-DNAT a posteriori:

   ```bash
   sudo iptables -I FORWARD 1 -m conntrack --ctorigdstport 31544 \
     ! -s 192.168.56.0/24 -j DROP
   ```

7. Verificá y limpiá:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://192.168.56.11:31544/
   sudo nft list table inet np_test
   sudo nft delete table inet np_test
   sudo iptables -D FORWARD -m conntrack --ctorigdstport 31544 ! -s 192.168.56.0/24 -j DROP
   ```

**Preguntas**

- **Q5.1** — Ordená estas prioridades de hooks de `nftables` y decí dónde ocurre el DNAT del NodePort: `raw (-300)`, `mangle (-150)`, `dstnat (-100)`, `filter (0)`, `srcnat (100)`. ¿Por qué tu regla de drop debe estar en `-160`?
- **Q5.2** — ¿Por qué `-m conntrack --ctorigdstport 31544` funciona en `FORWARD` mientras que `--dport 31544` no?
- **Q5.3** — Un Service NodePort es alcanzable en **todos** los nodos, incluidos los que no tienen ningún pod que lo respalde. ¿Qué mecanismo hace que eso funcione, y cómo lo cambia `externalTrafficPolicy: Local`?
- **Q5.4** — ¿Es `externalTrafficPolicy: Local` un control de seguridad? Respondé sí/no y justificá en una oración.

---

## Ejercicio 6 — Achicar la superficie de Services expuestos desde el lado de Kubernetes

Los firewalls de host son por nodo y derivan. Quitar la exposición a nivel de la API es duradero.

1. Auditá qué está expuesto actualmente en todo el cluster:

   ```bash
   kubectl get svc -A -o json | jq -r '
     .items[]
     | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer" or (.spec.externalIPs|length>0))
     | [.metadata.namespace, .metadata.name, .spec.type,
        ((.spec.ports//[])|map(.nodePort|tostring)|join(",")),
        ((.spec.loadBalancerSourceRanges//["ANY"])|join(",")),
        ((.spec.externalIPs//[])|join(","))]
     | @tsv' | column -t
   ```

   Esperado:

   ```
   default   web-np      NodePort      31544   ANY
   ingress   ingress-lb  LoadBalancer  32180   ANY
   ```

2. Convertí la carga de trabajo a `ClusterIP` y ponele adelante un Ingress/Gateway, lo que te da un único punto de entrada auditable en lugar de N node ports:

   ```bash
   kubectl patch svc web-np --type=merge -p '{"spec":{"type":"ClusterIP","ports":[{"port":80,"targetPort":80,"protocol":"TCP","nodePort":null}]}}'
   kubectl get svc web-np
   ```

3. Donde un `LoadBalancer` sea inevitable, fijá los rangos de origen **y** suprimí los node ports que de otro modo abriría en todos los nodos:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: ingress-lb
     namespace: ingress
   spec:
     type: LoadBalancer
     allocateLoadBalancerNodePorts: false     # no 30000-32767 listener on any node
     externalTrafficPolicy: Local             # preserve client source IP for the ranges below
     loadBalancerSourceRanges:
       - 203.0.113.0/24
       - 198.51.100.17/32
     selector:
       app.kubernetes.io/name: ingress-nginx
     ports:
       - name: https
         port: 443
         targetPort: 443
         protocol: TCP
   ```

   ```bash
   kubectl apply -f ingress-lb.yaml
   kubectl get svc -n ingress ingress-lb -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
   ```

   Esperado: salida vacía.

4. Angostá el propio rango de NodePort para que un Service perdido no pueda aterrizar en un puerto que tu firewall permite. En `cp01`:

   ```bash
   sudo sed -i 's#^\( *\)- --service-cluster-ip-range#\1- --service-node-port-range=30000-30100\n\1- --service-cluster-ip-range#' \
     /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo crictl ps --name kube-apiserver -q   # wait for the static pod to be recreated
   kubectl get --raw /livez?verbose | tail -3
   ```

5. Restringí a qué interfaz del nodo bindea `kube-proxy` los NodePorts — este es el control que la mayoría de los equipos nunca habilita:

   ```bash
   kubectl -n kube-system edit configmap kube-proxy
   ```

   ```yaml
   apiVersion: kubeproxy.config.k8s.io/v1alpha1
   kind: KubeProxyConfiguration
   mode: nftables
   nodePortAddresses:
     - 192.168.56.0/24     # or the literal ["primary"] on recent releases
   ```

   ```bash
   kubectl -n kube-system rollout restart daemonset kube-proxy
   kubectl -n kube-system rollout status daemonset kube-proxy
   ```

6. Comprobá el efecto — recreá un Service NodePort y verificá que *no* queda bindeado en una segunda interfaz del nodo.

7. Rollback: restaurá el ConfigMap y quitá `--service-node-port-range`.

**Preguntas**

- **Q6.1** — `loadBalancerSourceRanges` lo aplica el proveedor cloud / el controlador del load balancer, no `kube-proxy`. ¿Cuál es la consecuencia de seguridad en un cluster bare-metal que usa MetalLB en modo L2?
- **Q6.2** — ¿De qué te protege `allocateLoadBalancerNodePorts: false`, dado que el LoadBalancer ya restringe los orígenes?
- **Q6.3** — `spec.externalIPs` parece inofensivo. Explicá por qué se lo trata como un campo privilegiado y qué puede hacer con él un atacante con `create services` en un solo namespace.
- **Q6.4** — Setear `nodePortAddresses` no elimina los Services NodePort existentes. ¿Por qué sigue siendo valioso, y qué es lo que *no* protege?

---

## Ejercicio 7 — Impedir que la exposición se recree: `ValidatingAdmissionPolicy`

Borrar un NodePort es remediación. Hacer que los NodePorts sean irrepresentables es hardening.

1. Escribí la política (CEL, in-tree, sin webhook externo que haya que mantener disponible):

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: restrict-external-service-exposure
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups:   [""]
           apiVersions: ["v1"]
           operations:  ["CREATE", "UPDATE"]
           resources:   ["services"]
     validations:
       - expression: "object.spec.type != 'NodePort'"
         message: "NodePort Services are forbidden; use ClusterIP behind the shared Ingress."
         reason: Forbidden
       - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
         message: "spec.externalIPs is forbidden."
         reason: Forbidden
       - expression: >-
           object.spec.type != 'LoadBalancer' ||
           (has(object.spec.loadBalancerSourceRanges) &&
            size(object.spec.loadBalancerSourceRanges) > 0 &&
            object.spec.loadBalancerSourceRanges.all(r, r != '0.0.0.0/0'))
         message: "LoadBalancer Services must set a non-wildcard spec.loadBalancerSourceRanges."
         reason: Forbidden
   ```

2. Vinculala, exceptuando los namespaces que legítimamente necesitan exposición:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: restrict-external-service-exposure-binding
   spec:
     policyName: restrict-external-service-exposure
     validationActions: ["Deny", "Audit"]
     matchResources:
       namespaceSelector:
         matchExpressions:
           - key: kubernetes.io/metadata.name
             operator: NotIn
             values: ["kube-system", "ingress"]
   ```

3. Aplicá y probá:

   ```bash
   kubectl apply -f vap-services.yaml -f vap-services-binding.yaml
   kubectl expose deployment web --type=NodePort --port=80 --name=web-np2
   ```

   Esperado:

   ```
   error: failed to create service: services "web-np2" is forbidden: ValidatingAdmissionPolicy
   'restrict-external-service-exposure' with binding
   'restrict-external-service-exposure-binding' denied request:
   NodePort Services are forbidden; use ClusterIP behind the shared Ingress.
   ```

4. Confirmá que la excepción sigue funcionando:

   ```bash
   kubectl -n ingress create service nodeport tmp --tcp=80:80 --dry-run=server -o name
   ```

5. Hacé un dry-run de la política contra los objetos existentes antes de aplicarla en producción, desplegando primero con `validationActions: ["Audit"]` y leyendo el audit log de la API:

   ```bash
   sudo grep -o '"validation_policy[^,]*' /var/log/kubernetes/audit.log | sort | uniq -c | head
   ```

6. Limpieza:

   ```bash
   kubectl delete validatingadmissionpolicybinding restrict-external-service-exposure-binding
   kubectl delete validatingadmissionpolicy restrict-external-service-exposure
   ```

**Preguntas**

- **Q7.1** — `failurePolicy: Fail` en una `ValidatingAdmissionPolicy` tiene un perfil de disponibilidad muy distinto al de `failurePolicy: Fail` en una `ValidatingWebhookConfiguration`. Explicá por qué.
- **Q7.2** — El binding exceptúa `kube-system` e `ingress` por label de namespace. ¿Por qué `kubernetes.io/metadata.name` es confiable para esto, y qué tendría de malo un label propio como `exempt: "true"`?
- **Q7.3** — Tu política bloquea `CREATE` y `UPDATE` en Services. Nombrá una vía por la que un NodePort podría igualmente aparecer en el cluster.
- **Q7.4** — ¿Por qué la tercera validación rechaza explícitamente `0.0.0.0/0` en lugar de solo chequear que la lista no esté vacía?

---

## Ejercicio 8 — Cortar el egress de los pods: default-deny más un bloqueo del endpoint de metadata

Minimizar el acceso externo es bidireccional. Un pod que puede alcanzar el servicio de metadata del cloud a menudo puede acuñar credenciales cloud a nivel de nodo.

1. Creá un namespace y un pod de sondeo:

   ```bash
   kubectl create namespace payments
   kubectl -n payments run probe --image=nicolaka/netshoot --command -- sleep 3600
   kubectl -n payments wait --for=condition=Ready pod/probe --timeout=60s
   ```

2. Establecé el estado "antes":

   ```bash
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'internet=%{http_code}\n' --max-time 5 https://example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'metadata=%{http_code}\n' --max-time 3 http://169.254.169.254/latest/meta-data/
   kubectl -n payments exec probe -- nslookup kubernetes.default.svc.cluster.local
   ```

3. Aplicá una política de egress default-deny:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-egress
     namespace: payments
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
   ```

   ```bash
   kubectl apply -f default-deny-egress.yaml
   kubectl -n payments exec probe -- nslookup kubernetes.default.svc.cluster.local || echo "DNS blocked — expected"
   ```

4. Reabrí solamente lo que la carga de trabajo necesita. Prestá atención cuidadosa a la semántica de la lista `to:` de dos elementos:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: payments-egress-allowlist
     namespace: payments
   spec:
     podSelector:
       matchLabels:
         app: payments-api
     policyTypes: ["Egress"]
     egress:
       # 1) Cluster DNS only
       - to:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
             podSelector:
               matchLabels:
                 k8s-app: kube-dns
         ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
       # 2) Public internet, minus link-local and RFC1918
       - to:
           - ipBlock:
               cidr: 0.0.0.0/0
               except:
                 - 169.254.0.0/16
                 - 10.0.0.0/8
                 - 172.16.0.0/12
                 - 192.168.0.0/16
         ports:
           - protocol: TCP
             port: 443
   ```

   ```bash
   kubectl apply -f payments-egress-allowlist.yaml
   kubectl -n payments label pod probe app=payments-api --overwrite
   ```

5. Verificá la postura resultante:

   ```bash
   kubectl -n payments exec probe -- nslookup example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'https=%{http_code}\n' --max-time 5 https://example.com
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'meta=%{http_code}\n' --max-time 3 http://169.254.169.254/latest/meta-data/ || echo "metadata blocked — expected"
   kubectl -n payments exec probe -- curl -s -o /dev/null -w 'apiserver=%{http_code}\n' --max-time 3 -k https://kubernetes.default.svc/version || echo "apiserver blocked — expected"
   ```

6. Poné a prueba la honestidad del CNI respecto del tráfico node-local — muchos CNIs eximen del `ipBlock` al tráfico dirigido a la IP del propio nodo del pod:

   ```bash
   NODE_IP=$(kubectl -n payments get pod probe -o jsonpath='{.status.hostIP}')
   kubectl -n payments exec probe -- curl -sk -o /dev/null -w "kubelet=%{http_code}\n" --max-time 3 https://$NODE_IP:10250/pods
   ```

7. Limpieza:

   ```bash
   kubectl delete namespace payments
   ```

**Preguntas**

- **Q8.1** — En la regla de DNS, `namespaceSelector` y `podSelector` son dos claves de un **único** elemento de la lista. Reescribí la semántica en palabras, y decí qué cambia si ponés un `-` antes de `podSelector`.
- **Q8.2** — ¿Por qué cada entrada de `except` debe ser un subconjunto del `cidr` que la contiene? ¿Qué error devuelve el API server si no?
- **Q8.3** — En el paso 6, algunos CNIs devuelven `401` (alcanzable) en lugar de un timeout. Explicá la razón de fondo y nombrá el mecanismo (por CNI) que usarías para cerrarlo.
- **Q8.4** — La allowlist permite `TCP/443` hacia `0.0.0.0/0` menos los rangos privados. ¿Por qué una política de egress expresada en CIDRs de IP da una protección débil contra la exfiltración, y qué clase de motor de políticas lo resuelve?
- **Q8.5** — Un pod con `hostNetwork: true` en el namespace `payments` ignora `default-deny-egress`. ¿Por qué, y qué admission control impide que ese pod exista?

---

## Ejercicio 9 — SO del host: eliminar listeners que nunca necesitaste

1. Enumerá las units activadas por socket — servicios que no están corriendo pero arrancarán en la primera conexión:

   ```bash
   systemctl list-sockets --all
   systemctl list-units --type=socket --state=active
   ```

2. Enumerá los servicios habilitados y cruzalos con tu baseline de listeners:

   ```bash
   systemctl list-unit-files --state=enabled --type=service | sort
   ```

3. Deshabilitá lo que un nodo Kubernetes no necesita para nada:

   ```bash
   for u in avahi-daemon cups cups-browsed rpcbind postfix bluetooth ModemManager; do
     systemctl list-unit-files "$u.service" >/dev/null 2>&1 && \
       sudo systemctl disable --now "$u.service" "$u.socket" 2>/dev/null
   done
   sudo systemctl mask avahi-daemon.socket
   ```

4. Endurecé `sshd` y verificá con la configuración *efectiva*, no con el archivo:

   ```bash
   sudo tee /etc/ssh/sshd_config.d/99-cks.conf >/dev/null <<'EOF'
   PermitRootLogin no
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitEmptyPasswords no
   X11Forwarding no
   AllowTcpForwarding no
   MaxAuthTries 3
   ClientAliveInterval 300
   ClientAliveCountMax 2
   AllowGroups k8s-admins
   ListenAddress 192.168.56.10
   EOF
   sudo sshd -t && sudo systemctl reload ssh
   sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|allowgroups|listenaddress|maxauthtries)'
   ```

   Esperado:

   ```
   permitrootlogin no
   passwordauthentication no
   maxauthtries 3
   allowgroups k8s-admins
   listenaddress 192.168.56.10:22
   ```

5. Volvé a correr el inventario del Ejercicio 1 y hacé el diff:

   ```bash
   sudo ss -lntuH | awk '{print $1, $5}' | sort -u > /tmp/now-listeners.txt
   diff /root/baseline-listeners.txt /tmp/now-listeners.txt
   ```

**Preguntas**

- **Q9.1** — ¿Por qué `systemctl stop avahi-daemon.service` por sí solo deja el nodo expuesto, y qué agrega `mask` por sobre `disable`?
- **Q9.2** — ¿Por qué hay que validar `sshd` con `sshd -T` en lugar de leyendo `/etc/ssh/sshd_config`? Dá dos formas concretas en que el archivo te engaña.
- **Q9.3** — `AllowTcpForwarding no` — ¿qué técnica de pivoteo específica le quita esto a un atacante que obtuvo una clave SSH válida?
- **Q9.4** — `ListenAddress 192.168.56.10` bindea sshd a la interfaz de administración. En un nodo cloud con una única NIC que carga ambos roles, ¿cuál es el control equivalente?

---

## Ejercicio 10 — Verificación continua: un chequeo de deriva de exposición

1. Escribí un chequeo que falle ruidosamente cuando la superficie externa del nodo cambia:

   ```bash
   sudo tee /usr/local/bin/check-external-exposure.sh >/dev/null <<'EOF'
   #!/usr/bin/env bash
   # Fails (exit 1) if the node exposes a listener outside the approved allowlist.
   set -uo pipefail

   ALLOWED_PORTS="22 6443 10250"
   ALLOWED_CIDR="192.168.56.0/24"
   rc=0

   echo "== Externally bound listeners =="
   while read -r addr; do
     port="${addr##*:}"
     grep -qw "$port" <<<"$ALLOWED_PORTS" || { echo "UNEXPECTED listener: $addr"; rc=1; }
   done < <(ss -lntH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\])')

   echo "== Kubelet read-only port =="
   ss -lntH | grep -q ':10255' && { echo "kubelet readOnlyPort is OPEN"; rc=1; }

   echo "== Kubelet anonymous auth =="
   code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:10250/pods")
   [ "$code" = "401" ] || { echo "kubelet /pods returned $code (expected 401)"; rc=1; }

   echo "== Exposed Services =="
   if command -v kubectl >/dev/null; then
     kubectl get svc -A -o json 2>/dev/null | jq -e '
       [.items[] | select(.spec.type=="NodePort"
         or (.spec.type=="LoadBalancer" and ((.spec.loadBalancerSourceRanges//[])|length==0))
         or ((.spec.externalIPs//[])|length>0))] | length == 0' >/dev/null \
       || { echo "Unrestricted NodePort/LoadBalancer/externalIP Services present"; rc=1; }
   fi

   echo "== Guard table loaded =="
   nft list table inet cks_guard >/dev/null 2>&1 || { echo "cks_guard nftables table missing"; rc=1; }

   exit $rc
   EOF
   sudo chmod 0750 /usr/local/bin/check-external-exposure.sh
   ```

2. Ejecutalo y leé el exit status explícitamente — nunca lo pipees a través de `tee`, que enmascara la falla como exit `0`:

   ```bash
   sudo /usr/local/bin/check-external-exposure.sh
   echo "exit=$?"
   ```

3. Programalo y alertá ante fallas:

   ```bash
   sudo systemd-run --on-calendar='*:0/15' --unit=exposure-check \
     /usr/local/bin/check-external-exposure.sh
   systemctl list-timers exposure-check.timer
   ```

4. Contrastá con el CIS Kubernetes Benchmark usando `kube-bench` para el mismo dominio:

   ```bash
   kubectl run kube-bench --rm -it --restart=Never \
     --image=docker.io/aquasec/kube-bench:latest \
     --overrides='{"spec":{"hostPID":true,"nodeName":"cp01","containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:latest","command":["kube-bench","run","--targets","node"],"volumeMounts":[{"name":"varlib","mountPath":"/var/lib/kubelet","readOnly":true},{"name":"etckube","mountPath":"/etc/kubernetes","readOnly":true}]}],"volumes":[{"name":"varlib","hostPath":{"path":"/var/lib/kubelet"}},{"name":"etckube","hostPath":{"path":"/etc/kubernetes"}}]}}' \
     2>/dev/null | grep -E '^\[(FAIL|WARN)\]' | head -20
   ```

**Preguntas**

- **Q10.1** — El script exige `401` desde `https://127.0.0.1:10250/pods`. ¿Por qué `401` es la condición de aprobación y tanto `200` como `403` son fallas?
- **Q10.2** — El chequeo corre en el nodo y lee estado local. Nombrá una exposición que estructuralmente no puede detectar, y el control complementario que sí lo haría.
- **Q10.3** — ¿Por qué aparece `set -uo pipefail` sin `-e` en este script? ¿Qué rompería `-e` acá?
- **Q10.4** — Agregás esto a CI como gate. Un atacante con root en el nodo puede hacer que pase mientras deja un listener backdoor. Describí cómo, y qué clase de herramientas lo detecta en cambio.

---

<details>
<summary><b>Soluciones</b> — expandí solo después de intentar cada bloque</summary>

### Ejercicio 1

**A1.1** — Un socket bindeado a `127.0.0.1` solo es alcanzable a través de la interfaz de loopback, así que los paquetes que llegan por una NIC física con ese destino son descartados por el manejo de martian/rutas del kernel; no hay ruta por la cual un host remoto lo alcance. Convierte una superficie de ataque alcanzable por *red* en una alcanzable por *ejecución de código local*: el atacante ya debe tener un punto de apoyo en el nodo (una shell, o un pod `hostNetwork`, o un escape de contenedor). Esa es una barrera materialmente más alta, y es por eso que CIS 1.3.x / 1.4.x exigen `--bind-address=127.0.0.1` en el scheduler y el controller-manager. No sustituye a la autenticación — un pod con `hostNetwork: true` comparte el network namespace del host y puede alcanzar los listeners de loopback directamente.

**A1.2** — `ss` reporta lo que contiene la tabla de sockets del kernel; `nmap` reporta lo que sobrevivió al filtro de paquetes *en el camino*. `10248` está bindeado a `127.0.0.1`, así que un SYN desde `w01` nunca alcanza el socket. `filtered` significa que `nmap` envió sondas y no recibió ni un SYN/ACK ni un RST — el paquete fue descartado silenciosamente (un `DROP` de firewall, un rechazo de ruteo, o ningún listener en esa dirección). `closed` significa que el host respondió activamente con un TCP RST: host alcanzable, sin listener. La distinción importa para el reconocimiento: `closed` confirma que el host está vivo y que el puerto está desprotegido-pero-vacío; `filtered` le dice al atacante que algo está bloqueando deliberadamente, y además le cuesta tiempo de escaneo en silencio.

**A1.3** — `10249` es `metricsBindAddress`, que sirve `/metrics` (datos Prometheus sobre los propios syncs de `kube-proxy`, cantidad de reglas, latencia). `10256` es `healthzBindAddress`, que sirve `/healthz`. Los defaults difieren por sus consumidores: las métricas las scrapea un agente in-cluster que puede apuntarse a la IP del pod o correr como sidecar, así que loopback alcanza y protege las métricas moderadamente sensibles de topología de services/endpoints. La salud la sondean load balancers *externos* — un LB cloud haciendo health checks contra el `:10256/healthz` de cada nodo para decidir si mandarle tráfico NodePort — así que por defecto debe ser alcanzable desde fuera del nodo. En un cluster sin LB externo, seteá `healthzBindAddress: 127.0.0.1` y cerrá `10256`, como hace el Ejercicio 4 con el firewall.

**A1.4** — Sí para el pod con `hostNetwork: true`: comparte el network namespace del host, así que su socket está en la tabla de sockets del host y `ss -lntp` lo muestra (con el PID del proceso del contenedor, ya que `ss` lee `/proc/net/tcp` del namespace actual). No para un pod normal: su listener vive en su propio network namespace, y `containerPort` es metadata puramente informativa — no abre nada. Para verlo hay que entrar al namespace del pod, p. ej. `nsenter -t <pid> -n ss -lntp` o `crictl inspect` para encontrar el PID del sandbox. Esta asimetría es exactamente por lo que `hostNetwork` es una violación del nivel *baseline* de los Pod Security Standards.

### Ejercicio 2

**A2.1** — El API server presenta su certificado de cliente (`--kubelet-client-certificate`, normalmente `kube-apiserver-kubelet-client`). El autenticador `x509` del kubelet lo valida contra `authentication.x509.clientCAFile` y extrae el CN del subject como nombre de usuario (`kube-apiserver-kubelet-client`) y la O como grupos (`system:masters` en kubeadm por defecto). Como `authorization.mode: Webhook`, el kubelet entonces emite un `SubjectAccessReview` al API server preguntando si esa identidad puede realizar `create` sobre `nodes/proxy` (subrecurso `nodes/proxy`, o más precisamente el verbo mapeado a `nodes/exec`) para ese nodo. Los dos objetos son **`TokenReview`** (usado cuando el cliente presenta un bearer token en lugar de un certificado — la vía de delegación de autenticación) y **`SubjectAccessReview`** (la vía de delegación de autorización). A ambos los responde el API server, razón por la cual un kubelet con `mode: Webhook` falla cerrado si el API server es inalcanzable, sujeto a `cacheTTL`.

**A2.2** — Porque autenticación y autorización responden preguntas distintas. Con `anonymous.enabled: false`, toda solicitud debe llevar *alguna* credencial válida — pero "válida" solo significa "firmada por la CA configurada" o "un token que el API server acepta". Cada pod del cluster tiene un token de ServiceAccount montado; cualquier nodo tiene certificados en disco; cualquier certificado de cliente firmado por la CA del cluster (incluido el propio cert `system:node:*` de un kubelet, u obtenido vía un CSR) autentica exitosamente. Con `AlwaysAllow`, todas esas identidades obtienen acceso completo a la API del kubelet — `exec` a cualquier contenedor del nodo, leer todos los logs, listar todos los pods con sus variables de entorno. La autenticación prueba *quién*; solo la autorización decide *qué*. `AlwaysAllow` borra la segunda mitad.

**A2.3** — (a) `GET /pods` en `10255` devuelve el `PodList` completo del nodo, incluyendo el array `env` de cada contenedor; las variables de entorno provenientes de un ConfigMap se renderizan como valores literales, así que quedan expuestos hostnames de bases de datos, feature flags, URLs internas, y cualquier credencial que alguien haya puesto en un ConfigMap. (Los valores de `secretKeyRef` aparecen como una referencia, no como el valor — pero los *nombres* de los Secrets, la ServiceAccount, los registries de imágenes, los labels del nodo y toda la topología quedan expuestos.) (b) `GET /metrics/cadvisor` (y `/stats/summary`) en `10255` devuelve contadores de CPU, memoria, filesystem y red por contenedor, indexados por nombre de pod y namespace — un inventario completo de qué corre dónde, más un canal lateral para inferir actividad. Ambos son no autenticados; ambos le dan al atacante el mapa de objetivos antes de gastar un solo exploit.

**A2.4** — El endpoint autenticado equivalente es `https://$NODE_IP:10250/metrics/cadvisor`. El scraper ahora necesita un bearer token de una ServiceAccount vinculada a un ClusterRole que otorgue `get` sobre el recurso `nodes/metrics` (y típicamente `nodes/stats`, `nodes/proxy`), más la CA del cluster para validar el certificado de servicio del kubelet. La forma canónica es el ClusterRole `kubelet-serving`/`node-metrics` que instala Prometheus Operator, con `authorization: type: Bearer` y `tlsConfig.caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt` — notá que el certificado de servicio del kubelet debe estar efectivamente firmado por la CA del cluster (`serverTLSBootstrap: true` más aprobación del CSR), de lo contrario el scraper necesita `insecureSkipVerify: true`, lo que reintroduce una vía de MITM.

### Ejercicio 3

**A3.1** — Los clientes legítimos de `kube-apiserver` están, por diseño, fuera del nodo: cada kubelet del cluster, cada usuario de `kubectl`, cada controlador que corre como pod, y los sistemas de CI externos. Ninguno de ellos puede alcanzarlo por loopback, así que debe bindear una dirección ruteable; su defensa es TLS con autenticación obligatoria (x509/OIDC/tokens de ServiceAccount) más RBAC, no la inalcanzabilidad de red. `kube-scheduler` y `kube-controller-manager` tienen exactamente dos categorías de clientes: sus propias liveness probes (localhost) y los scrapers de métricas. Nada fuera del nodo necesita llamarlos, así que bindear loopback saca de la red por completo su `/metrics` (que filtra la topología de scheduling) y su `/healthz`, con costo funcional cero. El principio: el alcance del bind debería igualar al conjunto real de clientes, y para estos dos componentes ese conjunto es local.

**A3.2** — El control primario es TLS mutuo con `--client-cert-auth=true`: `etcd` no completa un handshake con un cliente que no presente un certificado firmado por la CA de etcd (`/etc/kubernetes/pki/etcd/ca.crt`). La restricción de red es defensa en profundidad porque no detiene el ataque que realmente importa — un atacante que obtuvo `/etc/kubernetes/pki/etcd/healthcheck-client.crt` (o `apiserver-etcd-client.*`) del filesystem del nodo, lo que otorga lectura/escritura completas de todo el estado del cluster, incluyendo cada Secret en texto plano (a menos que haya cifrado en reposo configurado). Poner un firewall en `2379` te compra protección contra el *escáner de red no autenticado* y reduce el radio de daño de una futura vulnerabilidad TLS de `etcd`; no te compra nada frente al acceso al filesystem. Por eso CKS empareja esto con `EncryptionConfiguration` y permisos de archivo `0600 root:root` en el directorio PKI.

**A3.3** — No, siempre que esté bindeado a `127.0.0.1`. El endpoint `listen-metrics-urls` en `2381` sirve solamente `/metrics` y `/health`; no tiene vía de escritura y no puede leer claves. Como está bindeado a loopback, el HTTP en texto plano solo es observable por un proceso que ya está en el nodo con capacidad de esnifar loopback (`CAP_NET_RAW` en el netns del host) — un atacante con ese nivel de privilegio ya tiene los certificados. Es HTTP deliberadamente para que las liveness probes y los scrapers node-local no necesiten certificados de cliente. *Sí* sería un hallazgo si la URL fuera `http://0.0.0.0:2381` o cualquier dirección ruteable: ahí las métricas operativas de etcd (tamaño de la DB, término raft, cambios de líder, cantidad de claves) atraviesan la red sin autenticar y sin cifrar.

**A3.4** — El `kubelet` de cada nodo se conecta al API server usando el endpoint de su `/etc/kubernetes/kubelet.conf` (`server: https://192.168.56.10:6443`). Bindear el API server a `127.0.0.1` elimina el listener `0.0.0.0:6443`, así que el kubelet de `w01` recibe connection-refused. Ya no puede hacer POST de su heartbeat `NodeStatus` (objetos `Lease` en `kube-node-lease`). Después de `--node-monitor-grace-period` (default 40 s) el node controller de `kube-controller-manager` — que sigue funcionando, porque corre en `cp01` y alcanza al API server por loopback — marca el nodo como `NotReady`, y luego empieza a desalojar pods tras `--default-not-ready-toleration-seconds` (300 s). El `kubectl` local en `cp01` sigue funcionando porque su kubeconfig también resuelve a la dirección alcanzable por loopback. Esta es la falla clásica del "el cluster se ve bien desde donde estoy parado".

### Ejercicio 4

**A4.1** — Las reglas de firewall se evalúan contra *cada* paquete en ambas direcciones del camino de retorno de un flujo. Cuando el nodo mismo inicia una conexión — `kubelet` → API server, `crictl` bajando una imagen, un pod `hostNetwork` llamando hacia afuera — las *respuestas* llegan como entrantes con puertos de origen arbitrarios y, críticamente, con el puerto del remoto como origen. Una regla de drop que matchea `tcp dport 10250` no las va a alcanzar, pero una `policy drop` o una regla más amplia sí, y la conexión se cuelga. La regla `ct state established,related accept` cortocircuita todo eso: cualquier paquete perteneciente a un flujo que conntrack ya conoce pasa antes de que corra la lógica de drop, así que solo se evalúan las conexiones entrantes genuinamente nuevas. Omitirla mientras dropeás específicamente `10250` es sobrevivible (el drop es angosto), pero en el momento en que cambiás a `policy drop` — el estado final correcto — omitirla corta la conectividad saliente del propio nodo, incluido su heartbeat al API server, y perdés el nodo.

**A4.2** — `kube-proxy` implementa los Services programando reglas de DNAT (chains `KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*` en la tabla `nat`) y el CNI programa sus propias reglas de forwarding/masquerade. `iptables -F` vacía la tabla `filter`; `iptables -t nat -F` vacía las reglas de DNAT, y en ese punto el tráfico de ClusterIP no tiene a dónde ir y cada Service se vuelve un agujero negro — los pods todavía pueden hablar IP-de-pod a IP-de-pod, pero cada conexión a `svc.cluster.local` da timeout. Parece "curarse" porque `kube-proxy` corre una resincronización completa periódica (`syncPeriod`, default 30 s, con el throttling de `minSyncPeriod`) que reescribe sus chains desde cero; el agente del CNI hace lo mismo en su propio intervalo. Así que la caída dura de segundos a un minuto y después desaparece, que es precisamente lo que la vuelve una pesadilla de diagnosticar desde un ticket. La lección: nunca vacíes chains compartidas — poné tus reglas en tu propia tabla (o en tu propia chain con un jump que vos controlás).

**A4.3** — (1) **Sin conflicto de reconciliación.** `kube-proxy` y el agente del CNI reescriben periódicamente las tablas que poseen, y el `kube-proxy` moderno en modo nftables hace un reemplazo completo de tabla; una regla que anexaste dentro de una chain que ellos manejan se borra silenciosamente en el próximo resync. Tu propia tabla nunca es tocada por ellos. (2) **Ciclo de vida atómico, revisable y reversible.** `nft -f file` aplica el archivo entero como una sola transacción — o cargan todas las reglas o ninguna, así que no hay ventana con una política a medio aplicar — y `nft delete table inet cks_guard` es un rollback completo de un solo comando que no puede llevarse por delante accidentalmente una regla de `kube-proxy`. Una ventaja secundaria: `nft list table inet cks_guard` te da un artefacto de auditoría limpio que contiene solo tu política, en lugar de tener que extraerla con grep de entre 1.200 reglas `KUBE-*`.

**A4.4** — El perfil por defecto de `ufw` pone la policy de `filter FORWARD` en `DROP` (e inserta las chains `ufw-before-forward`/`ufw-reject-forward`). El tráfico pod-a-pod entre nodos es *forwardeado* por el nodo — los paquetes entran por la NIC física (o por la interfaz de túnel VXLAN/IPIP) y salen por una interfaz `cali*`/`veth` hacia el pod — así que atraviesa `FORWARD`, no `INPUT`, y es descartado. Las reglas `ufw allow` solo tocan `INPUT`, que es por lo que "permití el puerto y sigue sin andar" es el reporte habitual. Arreglo mínimo correcto: poner `DEFAULT_FORWARD_POLICY="ACCEPT"` en `/etc/default/ufw` y recargar (`ufw reload`), y después, si querés filtrado en forward, agregar permisos explícitos para los CIDRs de pod y service y para la interfaz de túnel del CNI (reglas `ufw route allow`), p. ej. `ufw allow in on cali+`, `ufw allow in on vxlan.calico`, `ufw route allow from 10.244.0.0/16 to 10.244.0.0/16`. En un nodo Kubernetes la respuesta honesta suele ser: no uses `ufw` — es una abstracción sobre una tabla que Kubernetes co-posee.

### Ejercicio 5

**A5.1** — Orden de recorrido para un paquete entrante: `raw (-300)` → `mangle prerouting (-150)` → `dstnat (-100)` → *decisión de ruteo* → `filter forward (0)` o `filter input (0)` → ... → `srcnat (100)`. El DNAT del NodePort ocurre en el hook `dstnat`, en prioridad `-100`: el destino se reescribe de `192.168.56.11:31544` al endpoint `10.244.1.7:80`. Después de esa reescritura el kernel toma su decisión de ruteo sobre el *nuevo* destino, que no es una dirección local, así que el paquete se manda a `forward` — `input` nunca se consulta. Tu regla de drop debe estar en una prioridad numéricamente **menor** que `-100` (más temprana), de ahí `-160`, para que vea el puerto de destino original `31544` antes de que sea reescrito. `-160` además queda después de `mangle (-150)`; cualquier prioridad en `(-300, -100)` funciona, y elegir una que no choque con las convenciones de `mangle` o `raw` mantiene el ruleset legible.

**A5.2** — Después del DNAT, las cabeceras L3/L4 del paquete llevan el destino *traducido* (`10.244.1.7:80`), así que un match liso de `--dport 31544` en `FORWARD` no matchea nada. Conntrack, sin embargo, registra la tupla **original** de la conexión junto con la tupla de respuesta — que es exactamente lo que viste en la salida de `conntrack -L`, donde `dport=31544` aparece en la dirección original y `sport=80` en la respuesta. `-m conntrack --ctorigdstport 31544` matchea contra esa tupla original almacenada en lugar de contra las cabeceras actuales, así que identifica correctamente "este flujo entró como una conexión NodePort" aunque el paquete que tenés delante ya no lo parezca. La misma técnica con `--ctorigdst` es como se escriben reglas del tipo "bloqueá el tráfico que originalmente apuntaba a esta IP externa" en un nodo que hace NAT.

**A5.3** — `kube-proxy` en *todos* los nodos programa una regla para el node port que hace DNAT hacia el conjunto completo de endpoints listos a nivel de cluster, sin importar dónde viven esos endpoints. Si el endpoint seleccionado está en otro nodo, el paquete recibe SNAT (masquerade) hacia la IP del nodo receptor y se forwardea allá — un salto extra, y el pod backend ve la IP del nodo intermedio como el cliente. Con `externalTrafficPolicy: Local`, `kube-proxy` programa el node port solo con los endpoints *locales a ese nodo*: los nodos sin pod que respalde el Service o bien descartan el tráfico o bien fallan su health check de `:10256`, de modo que el LB externo deja de mandarles tráfico, y como no hace falta un segundo salto no hay SNAT, así que el pod ve la IP real del cliente. La contrapartida es una distribución de carga despareja (el tráfico se reparte por nodo, no por pod) y una dependencia dura del health checking del LB.

**A5.4** — **No.** Cambia *qué* nodos responden y preserva la IP de origen del cliente; no autentica, ni filtra, ni restringe quién puede conectarse — cualquier cliente que pueda alcanzar un nodo que casualmente aloje un pod de respaldo sigue teniendo acceso completo al Service. Su valor de seguridad es indirecto y secundario: como ahora la IP real del cliente llega al pod, las allowlists a nivel de aplicación, los rate limits y los logs de auditoría pasan a ser significativos en lugar de registrar la IP del nodo. No lo presentes como un control de acceso en una respuesta de examen ni en una revisión de diseño.

### Ejercicio 6

**A6.1** — `loadBalancerSourceRanges` es un *pedido* al controlador de load balancer del proveedor, del que se espera que lo traduzca en reglas de security group del cloud (AWS NLB/ALB, reglas de firewall de GCP, NSG de Azure). MetalLB en modo L2 no hace nada de eso: simplemente responde ARP por la VIP desde un nodo electo y deja que `kube-proxy` se ocupe del resto, así que el campo se ignora silenciosamente — el objeto Service muestra los rangos, la auditoría pasa, y la VIP es alcanzable desde todo el segmento L2. Este es el peor tipo de control: uno que *parece* configurado. En bare metal tenés que aplicar los rangos vos mismo, en el filtro de paquetes del nodo (un drop en `prerouting` que matchee la VIP, como en el Ejercicio 5), en la ACL del router/switch upstream, o poniendo delante de la VIP un Ingress/Gateway que haga su propio filtrado de origen. Verificá siempre la aplicación empíricamente desde un origen no permitido, en lugar de confiar en la presencia del campo.

**A6.2** — Contra la vía de bypass. Un Service `type: LoadBalancer` por defecto *también* asigna un node port y lo programa en todos los nodos, porque así es como la mayoría de los LBs cloud alcanzan los backends. El LB aplica `loadBalancerSourceRanges`, pero el node port no — cualquiera que pueda alcanzar la IP de cualquier nodo en `30000-32767` pasa de largo del load balancer y de su filtrado de origen, de su WAF, de su terminación TLS y de sus logs de acceso. `allocateLoadBalancerNodePorts: false` elimina esa puerta lateral; es seguro cuando la implementación del LB apunta directamente a IPs de pod (AWS NLB/ALB en modo target `ip`, LB-IPAM de Cilium, la mayoría de las implementaciones integradas con el CNI) y va a romper la conectividad cuando el LB apunta a node ports, así que verificá antes de desplegarlo.

**A6.3** — `spec.externalIPs` le indica a `kube-proxy` en **todos los nodos** que intercepte el tráfico destinado a direcciones IP arbitrarias que vos nombrás y lo haga DNAT hacia los endpoints de tu Service — sin ninguna validación de que seas dueño de esa dirección o de que tengas permitido reclamarla. Un atacante con `create services` en un solo namespace puede poner `externalIPs: ["10.96.0.10"]` (la ClusterIP del DNS del cluster) o la IP del API server, o la dirección de un servicio interno de otro namespace, y secuestrar ese tráfico a nivel de todo el cluster, rompiendo por completo el aislamiento entre namespaces: un solo secuestro de DNS ya les permite redirigir la resolución de nombres de todas las cargas de trabajo. Por eso existe el admission plugin upstream `DenyServiceExternalIPs` (se habilita con `--enable-admission-plugins=DenyServiceExternalIPs`), por eso la guía hermana de los Pod Security Standards lo marca, y por eso la política del Ejercicio 7 rechaza de plano un `externalIPs` no vacío.

**A6.4** — Impide que `kube-proxy` bindee node ports en interfaces fuera de los CIDRs listados, así que un Service creado en un nodo multi-homed (NIC de administración + NIC pública, o una NIC en una VLAN de DMZ) deja de publicarse silenciosamente en la dirección expuesta a internet. Su valor es que es un control de *alcance por defecto* aplicado por el data plane a cada Service, presente y futuro, sin configuración por Service — un NodePort creado mañana queda automáticamente confinado. Lo que **no** protege: (a) nada alcanzable en el propio CIDR aprobado — es un control de alcance de bind, no de autenticación ni por origen; (b) los pods con `hostPort` y `hostNetwork`, que evitan `kube-proxy` por completo y bindean lo que el contenedor pida; (c) las VIPs de `LoadBalancer` manejadas por una implementación integrada con el CNI que no rutea a través de `kube-proxy`; (d) las entradas de conntrack existentes, razón por la cual reiniciar `kube-proxy` no derriba inmediatamente los flujos establecidos.

### Ejercicio 7

**A7.1** — Una `ValidatingWebhookConfiguration` con `failurePolicy: Fail` hace que el API server dependa de un endpoint HTTPS externo — normalmente un Deployment *dentro del mismo cluster que está controlando*. Si ese Deployment está caído (un rollout malo, un nodo drenado, un certificado vencido, un error de network policy), toda escritura a la API que matchee es rechazada, y si el webhook matchea de forma amplia terminás con un cluster que no podés reparar porque no podés crear los pods que arreglarían el webhook. `ValidatingAdmissionPolicy` evalúa CEL **in-process dentro del API server**: no hay llamada de red, ni Deployment separado, ni certificado que venza, ni latencia de arranque en frío. Ahí `failurePolicy: Fail` solo se dispara ante un error de runtime de CEL (error de tipo, campo ausente en una forma de objeto inesperada), que es un bug en tu expresión, no un evento de disponibilidad. Esa es la razón operativa central para preferir VAP sobre un webhook en políticas expresables en CEL — y, en el examen, la razón para recurrir a él primero.

**A7.2** — `kubernetes.io/metadata.name` lo setea y reconcilia continuamente el propio API server sobre cada Namespace (el comportamiento `NamespaceDefaultLabelName`, GA desde v1.22); un usuario no puede quitarlo ni falsificarlo, y su valor siempre es igual al nombre del namespace. Un label propio como `exempt: "true"` está bajo el control de cualquiera con `update namespaces` — y, más sutilmente, de cualquiera que pueda *crear* un namespace, ya que elige sus labels iniciales. Eso convierte tu lista de excepciones en una primitiva de escalada de privilegios: creás el `namespace foo` con `exempt: "true"`, y después creás todos los NodePorts que quieras. La regla general para excepciones de política basadas en selectores: seleccioná sobre labels inmutables y gestionados por el servidor, y tratá el "quién puede etiquetar un namespace" como equivalente a "quién puede saltearse toda política seleccionada por namespace" — el mismo razonamiento que vuelve un permiso privilegiado al de escribir el label `pod-security.kubernetes.io/enforce`.

**A7.3** — Varias, y nombrar cualquiera alcanza: (a) **Objetos que ya existen** — VAP es un admission control, así que los Services NodePort preexistentes quedan intactos; necesitás la auditoría del paso 1 del Ejercicio 6 para encontrarlos, y por eso importan `validationActions: ["Deny","Audit"]` y una pasada de relevamiento. (b) **Los namespaces exceptuados** — `kube-system` e `ingress` están excluidos por el binding, así que cualquiera con `create services` ahí no tiene restricciones. (c) **Pods con `hostPort` / `hostNetwork`**, que exponen un puerto en el nodo sin que se cree ningún objeto Service — un recurso completamente distinto, no cubierto por `matchConstraints`. (d) Los Services de bootstrap del propio API server, y cualquier objeto creado mientras la política está ausente (binding borrado, restauración del cluster desde un backup tomado antes de que la política existiera). Estructuralmente: el admission control gobierna *la vía de escritura de acá en adelante*, así que siempre debe emparejarse con una auditoría periódica del estado existente — que es exactamente lo que provee el Ejercicio 10.

**A7.4** — Porque `loadBalancerSourceRanges: ["0.0.0.0/0"]` es semánticamente idéntico a omitir el campo — permite todo internet — y sin embargo satisface un chequeo ingenuo de "¿la lista no está vacía?". Las políticas que se pueden satisfacer trivialmente con un valor que no aporta protección son peores que no tener política: producen un resultado de auditoría en verde y una falsa sensación de cobertura, y entrenan a los ingenieros a escribir el conjuro que pasa en lugar del rango que corresponde. El `.all(r, r != '0.0.0.0/0')` de CEL cierra la forma obvia; una versión de producción iría más lejos y exigiría que cada rango sea un subconjunto de una lista de CIDRs corporativos aprobados, y rechazaría `::/0` y los casi-comodines como `0.0.0.0/1` + `128.0.0.0/1`.

### Ejercicio 8

**A8.1** — Tal como está escrito, los dos selectores son claves de un solo `NetworkPolicyPeer`, así que están en **AND**: "pods etiquetados `k8s-app: kube-dns` *que estén en* namespaces etiquetados `kubernetes.io/metadata.name: kube-system`" — es decir, exactamente los pods de CoreDNS y nada más. Agregar un `-` antes de `podSelector` lo convierte en un segundo elemento separado de la lista `to:`, y los elementos de lista están en **OR**: "cualquier pod del namespace `kube-system`, **O** cualquier pod etiquetado `k8s-app: kube-dns` en *cualquier* namespace". La segunda forma es dramáticamente más amplia — otorga egress a todos los pods de `kube-system` (incluidas las vías de proxy del API server, los agentes del CNI, cualquier operator que corra ahí) y le permite a un atacante en cualquier namespace que controle abrirse un camino con solo etiquetar su propio pod como `k8s-app: kube-dns`. Esta diferencia de un solo carácter es el error de NetworkPolicy más común y una trampa favorita del examen; leé siempre el YAML preguntándote "¿cuántos elementos de lista hay en este `to:`?"

**A8.2** — El API server valida que cada CIDR de `except` esté contenido dentro del `cidr` que lo envuelve, porque `ipBlock` está definido como una resta de conjuntos sobre un único rango de direcciones: un `except` fuera del rango carece de sentido y casi siempre indica que el autor malinterpretó la semántica (típicamente escribiendo `cidr: 10.0.0.0/8, except: [169.254.169.254/32]` y creyendo que bloqueó metadata). El API server lo rechaza en admission con un mensaje de la forma `spec.egress[1].to[0].ipBlock.except[0]: Invalid value: "169.254.169.254/32": must be a subnet of the network 10.0.0.0/8`. Consecuencia práctica: para excluir el rango link-local de metadata tenés que anidarlo bajo un `cidr` que lo contenga — `0.0.0.0/0` — que es por lo que la regla de la allowlist está escrita como "todo internet menos los rangos privados y link-local".

**A8.3** — La mayoría de los CNIs tratan el tráfico de un pod hacia la IP de *su propio nodo* como tráfico de host node-local que queda fuera de la vía de aplicación de políticas de la red de pods — el paquete se entrega por el ruteo del host sin atravesar las chains de política por endpoint, o el CNI explícitamente pone la IP del nodo en allowlist para que los health checks del kubelet y el DNS node-local sigan funcionando. El resultado es que un `except: 169.254.0.0/16` en un `ipBlock` o un deny de RFC1918 no detienen `curl https://$NODE_IP:10250/pods`, y el kubelet responde `401` (alcanzable, no autorizado) en lugar de dar timeout. Cerrarlo requiere la API de políticas a nivel de host del CNI, que el NetworkPolicy core no tiene: **Calico** — una `GlobalNetworkPolicy` con `applyOnForward` más un `HostEndpoint` para las interfaces del nodo; **Cilium** — una `CiliumClusterwideNetworkPolicy` con `nodeSelector` (host firewall, `--enable-host-firewall`); **fallback genérico** — el guard de `nftables` del nodo del Ejercicio 4, dropeando el tráfico hacia `10250` originado en el CIDR de pods. Probá siempre esta vía específica en lugar de asumir que tu NetworkPolicy la cubre.

**A8.4** — Porque los CIDRs son un mal sustituto de la identidad en la internet moderna. Un solo rango de IPs de una CDN o de un cloud fronterea millones de destinos no relacionados, así que permitir `TCP/443` hacia cualquier IP pública es efectivamente "permitir la exfiltración hacia cualquier servicio que casualmente esté detrás de Cloudflare, S3 o un sitio de GitHub Pages"; a la inversa, fijar un partner SaaS legítimo a una lista de IPs se rompe la primera vez que cambian su DNS, y el balanceo de carga basado en DNS significa que la dirección resuelta no es estable en primer lugar. Cerrá la brecha con un motor de políticas que entienda **nombres DNS y semántica L7**: `CiliumNetworkPolicy` de Cilium con `toFQDNs` (y `toPorts` + `rules.http` para granularidad de método/path), la `GlobalNetworkPolicy` de Calico con reglas basadas en dominios, o un proxy de egress explícito (Envoy/Squid) por el que todas las cargas de trabajo deban rutear, con la política de CIDR angostada a "solo el proxy". El punto general para el examen: el `NetworkPolicy` core es una API L3/L4 — decilo, y nombrá las políticas conscientes de FQDN o un egress gateway como la respuesta L7.

**A8.5** — Un pod con `hostNetwork: true` comparte el network namespace **del nodo**, así que su tráfico se origina en la IP del nodo y no pasa por el endpoint por pod al que el CNI adosa la política; no hay identidad de red de pod que seleccionar, así que `podSelector: {}` no lo matchea y el CNI no tiene punto de aplicación. También significa que semejante pod puede alcanzar todos los listeners del control plane bindeados a loopback del Ejercicio 3. El admission control que lo impide son los **Pod Security Standards** en nivel `baseline` (o `restricted`), aplicados vía Pod Security admission con el label de namespace `pod-security.kubernetes.io/enforce: baseline` — `baseline` prohíbe `hostNetwork`, `hostPID`, `hostIPC`, `hostPort` y los contenedores privilegiados. También es aceptable una aplicación equivalente vía una `ValidatingAdmissionPolicy` sobre `pods` con `!has(object.spec.hostNetwork) || object.spec.hostNetwork == false`; la clave es que una política *de red* no puede arreglar un problema de *pod spec*, así que los dos controles deben desplegarse juntos.

### Ejercicio 9

**A9.1** — `systemctl stop` termina el proceso en ejecución pero deja la unit habilitada, así que vuelve en el próximo boot; peor aún, si el servicio está activado por socket, `avahi-daemon.socket` sigue escuchando y el *kernel* reinicia el demonio en el primer paquete entrante, así que el puerto en realidad nunca se cierra. `disable` quita los symlinks de `WantedBy` para que no arranque en el boot — pero igual puede arrancarse como dependencia de otra unit, o manualmente, o por activación de socket si la unit de socket está habilitada por separado. `mask` symlinkea la unit a `/dev/null`, volviéndola imposible de arrancar por cualquier medio (dependencia, activación por socket, o un `systemctl start` explícito, que falla con "Unit is masked"). En un nodo endurecido, la secuencia correcta para un servicio que no querés nunca es `systemctl disable --now <unit>.service <unit>.socket` seguido de `systemctl mask` sobre ambos — y, mejor todavía, no instalar el paquete en absoluto (`apt purge`), que es la verdadera respuesta de minimizar la huella.

**A9.2** — `sshd -T` imprime la configuración efectiva completamente resuelta, exactamente como la computa el demonio, después de procesar cada include, cada override y cada default incorporado. Leer el archivo principal te engaña porque: (1) **`Include /etc/ssh/sshd_config.d/*.conf` se procesa en el punto donde aparece — normalmente en la línea 1 en Debian/Ubuntu — y `sshd` aplica la *primera* aparición de la mayoría de las palabras clave**, así que un archivo drop-in le gana silenciosamente al valor que estás leyendo más abajo en el archivo principal (y las imágenes cloud vienen con `50-cloud-init.conf` y `PasswordAuthentication yes`, que es como ocurre el "lo puse en no y sigue aceptando contraseñas"). (2) **Las opciones ausentes del archivo igual tienen valores** — los defaults compilados — así que que `PermitRootLogin` no aparezca no significa que esté apagado; el default histórico era `prohibit-password`, que sigue permitiendo login de root por clave. Trampas adicionales: los bloques `Match` cambian el valor efectivo por usuario/dirección (usá `sshd -T -C user=x,addr=y,host=z` para renderizarlos), y un error de configuración hace que `sshd` siga corriendo con la config *anterior* tras un reload fallido — por eso `sshd -t` antes de `systemctl reload` es obligatorio.

**A9.3** — Elimina el **port forwarding como pivote**: `ssh -L` (forward local, convirtiendo al nodo en un gateway hacia las redes internas del cluster — p. ej. `ssh -L 2379:127.0.0.1:2379 node`, que derrota todos los bindings a loopback del Ejercicio 3 con un solo comando), `ssh -R` (forward remoto, estableciendo un túnel entrante desde la infraestructura del atacante a través del egress del nodo y directo por encima del firewall), y `ssh -D` (un proxy SOCKS que convierte al nodo en un pivote de propósito general hacia los CIDRs de pods y services). Este es precisamente el control que impide que una clave robada convierta "shell en un nodo" en "acceso de red a todos los servicios bindeados a loopback y protegidos por firewall de ese nodo". Emparejalo con `AllowAgentForwarding no` (que si no le permite a un atacante en el nodo secuestrar tu socket de agente reenviado para autenticarse más adelante como vos) y, para cuentas que no necesitan shell alguna, `ForceCommand` o un prefijo `restrict` en `authorized_keys`.

**A9.4** — Con una sola NIC no podés separar roles por dirección de bind, así que el control equivalente es **restricción por origen en el filtro de paquetes más restricción de identidad en `sshd`**: (a) la regla de security group / NSG / firewall del cloud limitando `22/tcp` a la dirección del bastión o al CIDR de la VPN — el análogo cloud-nativo de `ListenAddress`, y el que mantiene a los escáneres de internet fuera del puerto por completo; (b) `AllowGroups`/`AllowUsers` y autenticación solo por clave, para que alcanzar el puerto no sea suficiente; (c) arquitectónicamente, sacar el listener de la red por completo — AWS SSM Session Manager, GCP IAP TCP forwarding o Azure Bastion abren una sesión iniciada hacia afuera, así que `22` no necesita ser alcanzable en absoluto, lo que es estrictamente mejor que cualquier allowlist porque no hay nada que escanear. El principio general a enunciar: cuando no podés angostar el alcance del *bind*, angostá el alcance del *origen*, y preferí eliminar la vía de red antes que filtrarla.

### Ejercicio 10

**A10.1** — `401 Unauthorized` es la condición de aprobación correcta porque prueba ambas mitades de la postura de seguridad del kubelet en un solo sondeo: el listener TLS está arriba (así que el chequeo realmente está probando algo), y la solicitud fue rechazada en la etapa de **autenticación** — lo que significa que `authentication.anonymous.enabled: false` está en efecto y que quien llama sin autenticar no tiene identidad alguna. `403 Forbidden` es una falla porque significa que la autenticación anónima *tuvo éxito* — a la solicitud se le asignó la identidad `system:anonymous` y solo el autorizador la detuvo. Esa es una postura estrictamente más débil: depende de que los bindings de RBAC se mantengan correctos, implica que cualquier endpoint que el autorizador llegue a permitir para `system:anonymous`/`system:unauthenticated` está abierto, y un único ClusterRoleBinding demasiado amplio (hay uno lamentablemente común que le da a `system:unauthenticated` más de lo previsto) lo convierte en `200`. `200` es la falla total: lectura no autenticada de todos los pods del nodo, y el mismo listener sirve `exec`.

**A10.2** — No puede detectar la **exposición de red aguas arriba** — que la IP del nodo esté publicada a través de un load balancer cloud, un security group abierto a `0.0.0.0/0`, un NAT/port-forward en el router del perímetro, o una VIP de `LoadBalancer` anunciada por MetalLB desde otro nodo. Cada una de esas cosas vuelve alcanzable desde internet a un listener "solo interno" mientras `ss`, `nft` y el `curl` local reportan un nodo perfectamente endurecido. (Una segunda respuesta válida: no puede ver un listener bindeado dentro del namespace de un pod sin `hostNetwork`, según A1.4.) El control complementario es la **validación externa de superficie de ataque**: un escaneo programado desde fuera del límite de confianza (`nmap` desde un host externo, o un servicio comercial de ASM/escaneo externo) cuyos resultados se comparan contra la lista de exposición aprobada, más escaneo de configuración cloud sobre los propios security groups y reglas de LB. La regla a internalizar: un control que mide desde *adentro* del límite nunca puede validar el límite — hace falta al menos un observador del otro lado.

**A10.3** — `-u` atrapa los typos de variables no seteadas y `-o pipefail` hace que los pipelines `ss | awk | grep` reporten una falla real en lugar del status del último comando — ambos deseables. `-e` se omite deliberadamente porque el propósito entero del script es **correr todos los chequeos y acumular `rc=1`**, y después reportar el panorama completo. Con `-e`, el primer comando que devuelva no-cero aborta el script: `grep -q ':10255'` devuelve legítimamente 1 cuando el puerto está *cerrado* (el caso bueno), el pipeline `kubectl`/`jq -e` devuelve no-cero como su señal normal de "encontré una violación", y `nft list table` devuelve no-cero cuando la tabla falta — así que `-e` haría que el script saliera en el primer chequeo que *pasa*, o que saliera tras la primera falla, ocultando todos los hallazgos posteriores. Un script de chequeo quiere "correr todo, agregar, salir con el agregado"; `-e` implementa "detenerse en la primera sorpresa", que es el contrato equivocado acá. (Si querés ambas cosas, envolvé cada chequeo con `if ! cmd; then ... fi` y mantené `-e`.)

**A10.4** — Con root en el nodo el atacante controla todo lo que el script lee: puede bindear el backdoor a un puerto de `ALLOWED_PORTS` (un segundo listener en `10250` es imposible, pero sí en `22` vía un `sshd` parcheado, o simplemente multiplexar el implante sobre el egress existente de `6443`/`443` para que nunca escuche); puede reemplazar `ss`/`nft`/`curl` con wrappers que filtren sus propias entradas; puede editar el propio `/usr/local/bin/check-external-exposure.sh` o apuntar el timer a un stub; o puede cargar un LKM/programa eBPF que oculte el socket de `/proc/net/tcp` para que ni siquiera un `ss` sin modificar pueda verlo. La debilidad genérica es que el chequeo es **on-host, in-band, y lee estado local mutable** — el atacante está dentro de la vía de medición. Detectar esto requiere (a) **seguridad de runtime con visibilidad a nivel de kernel** — Falco, Tetragon, o un EDR basado en eBPF emitiendo eventos `listen()`/`connect()`/`execve` fuera del nodo en tiempo real; (b) **monitoreo de integridad de archivos** sobre `/usr/local/bin`, `/etc/kubernetes`, `/etc/ssh` y los directorios de units de systemd (AIDE, reglas de Falco, o la respuesta de infraestructura inmutable: reconstruir el nodo desde una imagen y nunca parchear en el lugar); y (c) **observación fuera de banda** — escaneo externo y análisis de flujos de red en la capa del switch/VPC flow logs, que el nodo no puede manipular. Enunciá con claridad en una revisión: cualquier chequeo node-local es un detector de *deriva*, no de *intrusión*.

</details>

---

## Fuentes

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Ports and Protocols* — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes, *Kubelet authentication/authorization* — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes, *kubelet configuration (v1beta1) reference* — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes, *Service* (tipos, `externalIPs`, `loadBalancerSourceRanges`, `allocateLoadBalancerNodePorts`, `externalTrafficPolicy`) — https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes, *Virtual IPs and Service Proxies* (`nodePortAddresses`, modo nftables) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes, *kube-proxy configuration (v1alpha1) reference* — https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Kubernetes, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *kube-apiserver reference* — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- netfilter project, *nftables wiki — Configuring chains and hook priorities* — https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains
- CIS, *Kubernetes Benchmark* — https://www.cisecurity.org/benchmark/kubernetes
- Aqua Security, *kube-bench* — https://github.com/aquasecurity/kube-bench
- OpenSSH, *sshd_config(5)* — https://man.openbsd.org/sshd_config