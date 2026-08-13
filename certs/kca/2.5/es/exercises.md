# Tema 2.5 — High Availability Installations

> Certificación **KCA** · Peso en el examen: **3.0**
> Objetivo: montar y operar un control plane de Kubernetes tolerante a fallos con `kubeadm`, entendiendo la mecánica del quorum de `etcd`, la capa de load balancing frente a los `kube-apiserver` y el leader election de los componentes activo-pasivo.

Antes de ejecutar nada, fijemos el modelo mental. Kubernetes tiene **dos ejes de disponibilidad** que se confunden a menudo:

1. **etcd** — es un cluster de consenso Raft. Sobrevive perdiendo hasta `(N-1)/2` miembros. Es **activo-activo con quorum**: todos participan, pero solo hay un leader que serializa las escrituras.
2. **Componentes del control plane** — `kube-apiserver` es **stateless y activo-activo** (escalás horizontalmente detrás de un load balancer); `kube-controller-manager` y `kube-scheduler` son **activo-pasivo** vía leader election (corren en las N nodos pero solo uno actúa a la vez).

Dos topologías soportadas por `kubeadm`:

| Topología | Dónde vive etcd | Nodos mínimos | Radio de fallo |
|---|---|---|---|
| **Stacked etcd** | En cada nodo del control plane | 3 control plane | Perder un nodo = perder un `kube-apiserver` **y** un miembro etcd a la vez |
| **External etcd** | En hosts dedicados | 3 control plane + 3 etcd | Desacopla el fallo de etcd del fallo del control plane; más hardware |

Fuentes:
- Topologías HA: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- Creación de cluster HA con kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- Consideraciones de HA (LB, keepalived): https://github.com/kubernetes/kubeadm/blob/main/docs/ha-considerations.md
- Quorum y tolerancia a fallos en etcd: https://etcd.io/docs/latest/faq/#what-is-failure-tolerance

---

## Ejercicio 1 — Dimensionar el quorum antes de tocar un nodo

El error más caro en HA es elegir un número de miembros que **no compra tolerancia**. Vamos a razonarlo con la aritmética real del consenso Raft.

**Pasos**

1. Calculá el quorum para un cluster de `N` miembros. La fórmula es `quorum = floor(N/2) + 1`. Completá esta tabla a mano en tu cuaderno:

   | Miembros (N) | Quorum | Fallos tolerados = N − quorum |
   |---|---|---|
   | 1 | 1 | 0 |
   | 2 | 2 | 0 |
   | 3 | 2 | 1 |
   | 4 | 3 | 1 |
   | 5 | 3 | 2 |
   | 6 | 4 | 2 |
   | 7 | 4 | 3 |

2. Observá las filas `3` vs `4` y `5` vs `6`. Confirmá numéricamente por qué agregar un miembro par **no mejora** la tolerancia respecto al impar anterior.

3. Fijá la decisión de diseño para el resto del ejercicio: **3 nodos de control plane con stacked etcd**, que tolera la pérdida de 1 nodo. Anotá las IPs que usaremos:

   ```
   cp1  10.0.0.1
   cp2  10.0.0.2
   cp3  10.0.0.3
   w1   10.0.0.11
   w2   10.0.0.12
   VIP  10.0.0.100   (dirección virtual del load balancer)
   ```

**Preguntas de comprensión**

- **1a.** ¿Cuántos miembros necesitás como mínimo para seguir escribiendo en etcd tras la pérdida de **2** nodos simultáneos, y por qué no alcanza con 4?
- **1b.** Un cluster de 4 miembros pierde 2 en una partición de red 2+2. ¿Qué le pasa a la escritura en **ambas** particiones, y qué nombre recibe ese estado?
- **1c.** ¿Por qué la documentación oficial recomienda siempre un número **impar** de miembros etcd?

---

## Ejercicio 2 — Load balancer para los `kube-apiserver` (HAProxy + keepalived)

`kubeadm` no instala el load balancer: es responsabilidad tuya y es el **single point of failure** más frecuente. Montamos un LB en L4 (TCP) con HAProxy y le damos una VIP flotante con keepalived para que el propio LB no sea único.

**Pasos**

1. En los nodos que harán de LB (pueden ser los mismos control plane para un lab, o dedicados en producción), instalá los paquetes:

   ```bash
   sudo apt-get update && sudo apt-get install -y haproxy keepalived
   ```

2. Configurá HAProxy en `/etc/haproxy/haproxy.cfg`. Trabajamos en **modo `tcp`** porque el TLS termina en cada `kube-apiserver`, no en el LB — el LB nunca debe desencriptar:

   ```
   frontend apiserver
       bind *:8443
       mode tcp
       option tcplog
       default_backend apiserverbackend

   backend apiserverbackend
       option httpchk GET /healthz
       http-check expect status 200
       mode tcp
       option ssl-hello-chk
       balance     roundrobin
           server cp1 10.0.0.1:6443 check
           server cp2 10.0.0.2:6443 check
           server cp3 10.0.0.3:6443 check
   ```

   > La VIP escucha en `:8443` y reparte al `:6443` de cada apiserver. Elegimos un puerto distinto al del apiserver a propósito, para poder colocar el LB en los mismos nodos sin colisión de bind.

3. Escribí el health check que keepalived usará para decidir si este nodo puede ser MASTER, en `/etc/keepalived/check_apiserver.sh`:

   ```bash
   #!/bin/sh
   errorExit() {
       echo "*** $*" 1>&2
       exit 1
   }
   curl --silent --max-time 2 --insecure https://localhost:6443/ -o /dev/null \
       || errorExit "Error GET https://localhost:6443/"
   if ip addr | grep -q 10.0.0.100; then
       curl --silent --max-time 2 --insecure https://10.0.0.100:8443/ -o /dev/null \
           || errorExit "Error GET https://10.0.0.100:8443/"
   fi
   ```

   ```bash
   sudo chmod +x /etc/keepalived/check_apiserver.sh
   ```

4. Configurá keepalived en `/etc/keepalived/keepalived.conf`. En el nodo primario `state MASTER` y `priority 101`; en los backups `state BACKUP` y `priority` menor (100, 99…):

   ```
   vrrp_script check_apiserver {
       script "/etc/keepalived/check_apiserver.sh"
       interval 3
       weight -2
       fall 10
       rise 2
   }

   vrrp_instance VI_1 {
       state MASTER
       interface eth0
       virtual_router_id 51
       priority 101
       authentication {
           auth_type PASS
           auth_pass 42
       }
       virtual_ipaddress {
           10.0.0.100
       }
       track_script {
           check_apiserver
       }
   }
   ```

5. Arrancá los servicios y verificá que la VIP quedó asignada en el MASTER:

   ```bash
   sudo systemctl enable --now haproxy keepalived
   ip addr show eth0 | grep 10.0.0.100
   ```

   Salida esperada en el nodo MASTER (la VIP aparece como IP secundaria):

   ```
   inet 10.0.0.100/32 scope global eth0
   ```

   En los nodos BACKUP, ese `grep` **no devuelve nada**: la VIP no está asignada porque no son el MASTER.

**Preguntas de comprensión**

- **2a.** ¿Por qué HAProxy opera en `mode tcp` y no en `mode http`? ¿Qué se rompería si terminara TLS en el LB?
- **2b.** El `vrrp_script` tiene `weight -2` con `fall 10`. Si el `kube-apiserver` local muere, ¿qué le pasa a la `priority` efectiva del nodo y qué provoca eso en la VIP?
- **2c.** ¿Qué problema resuelve keepalived que un HAProxy solo **no** resuelve?
- **2d.** El health check apunta a `/healthz` con `expect status 200`. ¿Por qué es peligroso usar un chequeo TCP puro (solo "¿el puerto 6443 acepta conexiones?") en lugar del chequeo HTTP a `/healthz`?

---

## Ejercicio 3 — Bootstrap del primer control plane con stacked etcd

Ahora inicializamos `cp1`. La clave de todo el ejercicio es `--control-plane-endpoint`: apunta a la **VIP/DNS estable**, nunca a la IP de un nodo. Si te olvidás de este flag en el `init`, el cluster queda atado a `cp1` y **no se puede convertir a HA después** sin regenerar certificados.

**Pasos**

1. En `cp1`, inicializá pasando el endpoint estable y pidiendo que suba los certificados al cluster para poder distribuirlos:

   ```bash
   sudo kubeadm init \
     --control-plane-endpoint "10.0.0.100:8443" \
     --upload-certs \
     --pod-network-cidr=10.244.0.0/16 \
     --kubernetes-version=v1.29.2
   ```

2. Leé con cuidado la salida. `kubeadm` imprime **dos** comandos `join` distintos — uno **con** `--control-plane --certificate-key` y otro sin:

   ```
   You can now join any number of the control-plane node running the following command on each as root:

     kubeadm join 10.0.0.100:8443 --token 9f3a2b.4c5d6e7f8a9b0c1d \
         --discovery-token-ca-cert-hash sha256:1a2b3c4d5e6f...  \
         --control-plane --certificate-key f8e7d6c5b4a3...

   Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
   As a safeguard, uploaded-certs will be deleted in two hours; If necessary, you can use
   "kubeadm init phase upload-certs --upload-certs" to reload certs afterward.

   Then you can join any number of worker nodes by running the following on each as root:

     kubeadm join 10.0.0.100:8443 --token 9f3a2b.4c5d6e7f8a9b0c1d \
         --discovery-token-ca-cert-hash sha256:1a2b3c4d5e6f...
   ```

3. Configurá `kubectl` para tu usuario y verificá que el apiserver responde **a través de la VIP**:

   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   grep server: $HOME/.kube/config
   ```

   Salida esperada — el `server` debe ser la VIP, no `10.0.0.1`:

   ```
       server: https://10.0.0.100:8443
   ```

4. Instalá un CNI (aquí Flannel, coherente con el `--pod-network-cidr` elegido) para que los nodos pasen a `Ready`:

   ```bash
   kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
   ```

**Preguntas de comprensión**

- **3a.** ¿Qué hace exactamente `--upload-certs` y dónde quedan almacenados esos certificados? ¿Cuánto tiempo viven por defecto?
- **3b.** Arrancaste sin `--control-plane-endpoint` por error y ya hay workloads corriendo. ¿Por qué no podés simplemente "agregar el flag después"? ¿Qué quedó grabado con la IP de `cp1`?
- **3c.** El `certificate-key` expiró (pasaron > 2 horas) y todavía te falta unir `cp3`. ¿Qué comando regenera y vuelve a subir los certificados?

---

## Ejercicio 4 — Unir el resto de control planes y los workers

**Pasos**

1. En `cp2` y `cp3`, corré el `join` **con** `--control-plane` y `--certificate-key`. Este comando levanta un nuevo `kube-apiserver`, `controller-manager`, `scheduler` **y** suma un miembro nuevo al cluster etcd:

   ```bash
   sudo kubeadm join 10.0.0.100:8443 \
     --token 9f3a2b.4c5d6e7f8a9b0c1d \
     --discovery-token-ca-cert-hash sha256:1a2b3c4d5e6f... \
     --control-plane \
     --certificate-key f8e7d6c5b4a3...
   ```

2. **Unilos de a uno, esperando `Ready` entre cada uno.** No unas `cp2` y `cp3` en paralelo: cada join agrega un miembro a etcd y hay que dejar que el cluster reestablezca quorum antes de la siguiente mutación de membresía.

3. En `w1` y `w2`, corré el `join` de worker (sin `--control-plane`):

   ```bash
   sudo kubeadm join 10.0.0.100:8443 \
     --token 9f3a2b.4c5d6e7f8a9b0c1d \
     --discovery-token-ca-cert-hash sha256:1a2b3c4d5e6f...
   ```

4. Verificá el resultado desde `cp1`:

   ```bash
   kubectl get nodes -o wide
   ```

   Salida esperada:

   ```
   NAME   STATUS   ROLES           AGE     VERSION
   cp1    Ready    control-plane   35m     v1.29.2
   cp2    Ready    control-plane   18m     v1.29.2
   cp3    Ready    control-plane   12m     v1.29.2
   w1     Ready    <none>          8m      v1.29.2
   w2     Ready    <none>          7m      v1.29.2
   ```

**Preguntas de comprensión**

- **4a.** ¿Qué diferencia concreta hay entre el join de control plane y el de worker, más allá del flag? Nombrá al menos dos componentes que se levanten solo en el primero.
- **4b.** ¿Por qué la recomendación es unir los control planes **secuencialmente** y no en paralelo?
- **4c.** Si el token de bootstrap ya expiró (viven 24 h por defecto), ¿qué dos comandos te dan un token nuevo y el hash del CA para reconstruir el `join`?

---

## Ejercicio 5 — Inspeccionar etcd y el leader election

Un cluster que dice `Ready` puede tener etcd degradado sin que lo notes. Aprendamos a mirar debajo.

**Pasos**

1. Listá los miembros de etcd ejecutando `etcdctl` dentro del pod estático de etcd en `cp1`. Los certificados están montados desde `/etc/kubernetes/pki/etcd/`:

   ```bash
   kubectl -n kube-system exec etcd-cp1 -- etcdctl \
     --cacert /etc/kubernetes/pki/etcd/ca.crt \
     --cert /etc/kubernetes/pki/etcd/server.crt \
     --key  /etc/kubernetes/pki/etcd/server.key \
     member list -w table
   ```

   Salida esperada (3 miembros, ninguno `LEARNER`):

   ```
   +------------------+---------+------+-----------------------+-----------------------+------------+
   |        ID        | STATUS  | NAME |      PEER ADDRS        |     CLIENT ADDRS      | IS LEARNER |
   +------------------+---------+------+-----------------------+-----------------------+------------+
   | 3ba9f8e8e5f7c1a2 | started | cp1  | https://10.0.0.1:2380 | https://10.0.0.1:2379 |      false |
   | 8c4f2b1a9d6e3f04 | started | cp2  | https://10.0.0.2:2380 | https://10.0.0.2:2379 |      false |
   | a1b2c3d4e5f60718 | started | cp3  | https://10.0.0.3:2380 | https://10.0.0.3:2379 |      false |
   +------------------+---------+------+-----------------------+-----------------------+------------+
   ```

2. Consultá el estado con foco en quién es el leader. Pasá los tres endpoints:

   ```bash
   kubectl -n kube-system exec etcd-cp1 -- etcdctl \
     --cacert /etc/kubernetes/pki/etcd/ca.crt \
     --cert /etc/kubernetes/pki/etcd/server.crt \
     --key  /etc/kubernetes/pki/etcd/server.key \
     --endpoints https://10.0.0.1:2379,https://10.0.0.2:2379,https://10.0.0.3:2379 \
     endpoint status -w table
   ```

   Salida esperada (exactamente **un** `IS LEADER = true`, mismo `RAFT INDEX` en los tres = están sincronizados):

   ```
   +-----------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   |       ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
   +-----------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   | https://10.0.0.1:2379 | 3ba9f8e8e5f7c1a2 |  3.5.12 |  25 MB  |      true |      false |         4 |     980342 |             980342 |        |
   | https://10.0.0.2:2379 | 8c4f2b1a9d6e3f04 |  3.5.12 |  25 MB  |     false |      false |         4 |     980342 |             980342 |        |
   | https://10.0.0.3:2379 | a1b2c3d4e5f60718 |  3.5.12 |  25 MB  |     false |      false |         4 |     980342 |             980342 |        |
   +-----------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
   ```

3. Ahora mirá el leader election de los componentes activo-pasivo. Se materializa en objetos `Lease`:

   ```bash
   kubectl -n kube-system get lease kube-scheduler kube-controller-manager
   ```

   Salida esperada — fijate en la columna `HOLDER`, el prefijo indica **qué nodo** tiene el rol activo:

   ```
   NAME                      HOLDER                                       AGE
   kube-scheduler            cp2_e5f6a7b8-1234-4c5d-9e0f-a1b2c3d4e5f6     35m
   kube-controller-manager   cp1_a1b2c3d4-9876-4f0e-8d7c-6b5a4938271f     35m
   ```

**Preguntas de comprensión**

- **5a.** En `endpoint status`, ¿qué te dice que los tres miembros tengan el mismo `RAFT INDEX`? ¿Y qué sospecharías si uno quedara varios miles de índices por detrás?
- **5b.** Aunque hay 3 `kube-scheduler` corriendo (uno por control plane), solo uno programa pods. ¿Dónde está registrado cuál es el activo y qué pasa cuando el `HOLDER` se cae?
- **5c.** ¿Por qué `kube-apiserver` **no** aparece con un `Lease` de leader election, a diferencia del scheduler y el controller-manager?

---

## Ejercicio 6 — Simular un fallo de nodo y verificar el failover

La única prueba válida de HA es apagar cosas. Vamos a matar `cp1` (que además tenía el rol activo de controller-manager y era el leader de etcd) y confirmar que el cluster sigue.

**Pasos**

1. Desde tu estación, dejá corriendo un watch a través de la VIP para ver el efecto en tiempo real:

   ```bash
   kubectl get nodes -w
   ```

2. En otra terminal, apagá `cp1` de forma abrupta (simula un fallo de hardware, no un drain ordenado):

   ```bash
   # en cp1
   sudo systemctl poweroff
   ```

3. Observá la transición. Tras el grace period (`node-monitor-grace-period`, ~40 s por defecto), `cp1` pasa a `NotReady`, pero el resto sigue `Ready` y **`kubectl` nunca deja de responder** porque la VIP redirige a `cp2`/`cp3`:

   ```
   NAME   STATUS     ROLES           AGE   VERSION
   cp1    NotReady   control-plane   40m   v1.29.2
   cp2    Ready      control-plane   23m   v1.29.2
   cp3    Ready      control-plane   17m   v1.29.2
   w1     Ready      <none>          13m   v1.29.2
   w2     Ready      <none>          12m   v1.29.2
   ```

4. Confirmá que el rol activo de controller-manager migró a otro nodo (el `HOLDER` del `Lease` cambió):

   ```bash
   kubectl -n kube-system get lease kube-controller-manager
   ```

   ```
   NAME                      HOLDER                                       AGE
   kube-controller-manager   cp3_7c8d9e0f-2345-4a6b-8c0d-1e2f3a4b5c6d     42m
   ```

5. Confirmá que etcd re-eligió leader y **mantiene quorum con 2 de 3** (uno reporta error de conexión, es esperado):

   ```bash
   kubectl -n kube-system exec etcd-cp2 -- etcdctl \
     --cacert /etc/kubernetes/pki/etcd/ca.crt \
     --cert /etc/kubernetes/pki/etcd/server.crt \
     --key  /etc/kubernetes/pki/etcd/server.key \
     --endpoints https://10.0.0.1:2379,https://10.0.0.2:2379,https://10.0.0.3:2379 \
     endpoint status -w table
   ```

   ```
   {"level":"warn","msg":"...","error":"context deadline exceeded"}
   Failed to get the status of endpoint https://10.0.0.1:2379 (context deadline exceeded)
   +-----------------------+------------------+-----------+-----------+------------+-----------+------------+--------+
   |       ENDPOINT        |        ID        |  IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | ERRORS |
   +-----------------------+------------------+-----------+-----------+------------+-----------+------------+--------+
   | https://10.0.0.2:2379 | 8c4f2b1a9d6e3f04 |      true  |      false |         5 |     981210 |        |
   | https://10.0.0.3:2379 | a1b2c3d4e5f60718 |     false  |      false |         5 |     981210 |        |
   +-----------------------+------------------+-----------+-----------+------------+-----------+------------+--------+
   ```

   > `RAFT TERM` subió de `4` a `5`: eso es exactamente la nueva elección de leader tras la caída.

6. **Prueba del límite:** ahora apagá también `cp2`. Quedan 1 de 3 miembros etcd → **por debajo del quorum**. Intentá una escritura:

   ```bash
   kubectl create deployment probe --image=nginx
   ```

   Salida esperada — el cluster deja de aceptar **escrituras** (aunque las lecturas cacheadas puedan responder un rato):

   ```
   Error from server: etcdserver: request timed out
   ```

**Preguntas de comprensión**

- **6a.** Con `cp1` caído (2/3 miembros), las escrituras siguieron funcionando. Con `cp1` **y** `cp2` caídos (1/3), fallaron. Explicá con el número de quorum del Ejercicio 1 por qué el corte es exactamente ahí.
- **6b.** ¿Por qué `kubectl` siguió respondiendo instantáneamente pese a que `cp1` (donde apuntaba tu config original) murió? ¿Qué componente hizo el trabajo?
- **6c.** En el paso 6, con 1 de 3 miembros vivos, ¿por qué recuperar el cluster **no** es tan simple como "reiniciar el miembro sobreviviente"? ¿Qué opción de etcd habría que considerar y qué riesgo tiene?
- **6d.** ¿Qué diferencia hay, para el radio de fallo, entre haber hecho esto con **stacked** etcd vs **external** etcd?

---

## Ejercicio 7 (avanzado) — External etcd topology

Cuando querés que un fallo de etcd no arrastre a un `kube-apiserver` (y viceversa), separás las capas.

**Pasos**

1. Montá primero un cluster etcd de 3 nodos **fuera** de Kubernetes (siguiendo https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/setup-ha-etcd-with-kubeadm/). El resultado es un endpoint como `https://10.0.1.1:2379,https://10.0.1.2:2379,https://10.0.1.3:2379` y sus certificados de cliente.

2. En `cp1`, en lugar de `kubeadm init` con flags sueltos, usá un **config file** que declare el etcd externo:

   ```yaml
   # kubeadm-config.yaml
   apiVersion: kubeadm.k8s.io/v1beta3
   kind: ClusterConfiguration
   kubernetesVersion: v1.29.2
   controlPlaneEndpoint: "10.0.0.100:8443"
   etcd:
       external:
           endpoints:
               - https://10.0.1.1:2379
               - https://10.0.1.2:2379
               - https://10.0.1.3:2379
           caFile: /etc/kubernetes/pki/etcd/ca.crt
           certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
           keyFile: /etc/kubernetes/pki/apiserver-etcd-client.key
   ```

3. Antes del `init`, copiá los certificados de cliente de etcd a `cp1` en las rutas declaradas (el CA de etcd y el par cliente `apiserver-etcd-client`). Luego:

   ```bash
   sudo kubeadm init --config kubeadm-config.yaml --upload-certs
   ```

4. Verificá que **no** hay pod estático `etcd-cp1` — Kubernetes ya no gestiona etcd:

   ```bash
   kubectl -n kube-system get pods -l component=etcd
   ```

   Salida esperada:

   ```
   No resources found in kube-system namespace.
   ```

**Preguntas de comprensión**

- **7a.** En external topology, ¿qué certificado necesita el `kube-apiserver` para hablar con etcd y por qué el `init` falla si no lo copiaste antes?
- **7b.** Diste 3 etcd + 3 control plane = 6 hosts. ¿Qué comprás con esos 3 hosts extra frente a stacked, en términos de qué fallo aísla?
- **7c.** ¿Por qué `kubectl -n kube-system get pods -l component=etcd` no devuelve nada en esta topología, y dónde mirarías entonces la salud de etcd?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1 — Quorum

- **1a.** Necesitás **5 miembros**: quorum = `floor(5/2)+1 = 3`, así que tolera `5 − 3 = 2` fallos. Con 4 miembros el quorum es `floor(4/2)+1 = 3` también, y `4 − 3 = 1`: solo tolera **un** fallo. El cuarto miembro sube el costo de quorum sin subir la tolerancia.
- **1b.** En una partición 2+2 de un cluster de 4, **ninguna** de las dos particiones alcanza el quorum de 3, así que **ambas** pierden la capacidad de escribir. El cluster completo queda **read-only / sin leader** hasta que se cure la partición. Un cluster de 3 con partición 2+1 conserva escritura en el lado de 2. Por eso el par es peor: introduce un modo donde nadie puede escribir.
- **1c.** Porque `N` par no aumenta la tolerancia respecto a `N−1` impar (misma cuenta de fallos tolerados), pero **sí** aumenta la probabilidad de fallo (hay un nodo más que se puede caer) y agrega el riesgo del split-brain simétrico de 1b. Impar es estrictamente mejor relación tolerancia/costo/riesgo.

### Ejercicio 2 — Load balancer

- **2a.** En `mode tcp` HAProxy reenvía bytes sin desencriptar; el TLS termina en cada `kube-apiserver`, que es quien valida los client certs y hace la autenticación mTLS. Si terminaras TLS en el LB (`mode http`), romperías la autenticación por client-certificate de kubelets, `kubeadm join`, etc., porque el apiserver dejaría de ver el certificado del cliente real — vería el del LB.
- **2b.** Si `check_apiserver.sh` empieza a fallar, tras `fall 10` chequeos el `weight -2` **resta 2 a la priority** del nodo (de 101 a 99). Si un BACKUP tiene priority efectiva mayor, keepalived hace que la **VIP migre** a ese nodo sano. Es el mecanismo que evita anunciar la VIP en un nodo cuyo apiserver está muerto.
- **2c.** keepalived resuelve la **alta disponibilidad del propio LB**: da una VIP que flota entre varios HAProxy vía VRRP. Un HAProxy solo sigue siendo un único punto de fallo; si se cae ese host, la VIP se muda a otro. HAProxy reparte carga; keepalived hace que la dirección de entrada sobreviva.
- **2d.** Un chequeo TCP puro solo confirma que el proceso acepta conexiones en `:6443`, no que el apiserver esté **funcional**. Un apiserver puede aceptar el socket pero estar sin conexión a etcd, en crashloop de readiness, o devolviendo 500. `/healthz` con `expect status 200` valida salud real, así el LB saca de rotación instancias que "escuchan pero no sirven".

### Ejercicio 3 — Bootstrap

- **3a.** `--upload-certs` cifra los certificados del control plane (CA, front-proxy, etcd, service-account key) y los guarda en un `Secret` llamado `kubeadm-certs` en el namespace `kube-system`, cifrados con el `certificate-key`. Sirve para que los otros control planes los descarguen en el `join` en vez de copiarlos a mano. Por defecto ese Secret **se borra a las 2 horas**.
- **3b.** `--control-plane-endpoint` queda grabado en la config del cluster y, sobre todo, en los **certificados TLS** del apiserver (como SAN) y en los kubeconfig de los componentes. Sin él, todo apunta a la IP/hostname de `cp1`. Agregar más apiservers exigiría que el certificado incluyera la VIP como SAN — cosa que ya no está — así que habría que **regenerar certificados**, no basta un flag. Por eso el endpoint estable se decide en el `init`, no después.
- **3c.** `sudo kubeadm init phase upload-certs --upload-certs`. Vuelve a crear el Secret `kubeadm-certs` y **imprime un `certificate-key` nuevo** que usás en el `join` del control plane pendiente.

### Ejercicio 4 — Unir nodos

- **4a.** El join de control plane, además del kubelet, levanta un **`kube-apiserver`**, un **`kube-scheduler`**, un **`kube-controller-manager`** y (en stacked) suma un **miembro de etcd** nuevo; también instala los certificados del control plane. El join de worker solo configura kubelet y `kube-proxy` para que el nodo ejecute pods. El de control plane muta la membresía de etcd; el de worker no toca el control plane.
- **4b.** Cada join de control plane **agrega un miembro a etcd**, y agregar miembros es una operación de cambio de configuración de cluster que debe reconciliar quorum. Hacerlo en paralelo puede dejar transitoriamente el cluster sin quorum o con miembros a medio unir. Secuencial, esperando `Ready`, garantiza que etcd recompute quorum de forma segura entre cada cambio.
- **4c.** `kubeadm token create` (token nuevo, o `--print-join-command` para el comando completo) y, para el hash del CA:
  `openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'`.
  Más simple: `kubeadm token create --print-join-command` te devuelve token + hash listos.

### Ejercicio 5 — etcd y leader election

- **5a.** Mismo `RAFT INDEX` en los tres = los tres miembros aplicaron exactamente las mismas entradas del log Raft, están **plenamente sincronizados**. Si uno quedara miles de índices por detrás, sospecharías que ese miembro va rezagado (disco lento, red, o recién unido replicando): sigue contando para quorum pero no está al día, y un failover hacia él podría exponer datos viejos hasta que alcance al leader.
- **5b.** El activo está registrado en el objeto `Lease` `kube-scheduler` (namespace `kube-system`), campo `holderIdentity`. Cuando el `HOLDER` se cae y deja de renovar el lease dentro del `leaseDuration`, otra instancia adquiere el lease y **pasa a ser el scheduler activo**. Es un failover activo-pasivo con detección por expiración de lease.
- **5c.** Porque `kube-apiserver` es **stateless y activo-activo**: las tres instancias sirven tráfico simultáneamente detrás del load balancer, no hay un "activo" y "pasivos". No necesita elegir líder; el LB reparte. El leader election existe justamente para los componentes que **no** deben actuar en paralelo (scheduler y controller-manager tomarían decisiones conflictivas si corrieran todos a la vez).

### Ejercicio 6 — Failover

- **6a.** Quorum de un cluster de 3 es `floor(3/2)+1 = 2`. Con `cp1` caído quedan **2 vivos = quorum**, así que se puede elegir leader y escribir. Con `cp1` y `cp2` caídos queda **1 vivo < 2**, se pierde quorum: etcd deja de aceptar escrituras para no arriesgar split-brain, y por eso el `kubectl create` da `request timed out`.
- **6b.** Siguió respondiendo porque el kubeconfig apunta a la **VIP `10.0.0.100:8443`**, no a `cp1`. Cuando `cp1` murió, keepalived movió la VIP a un nodo sano y/o HAProxy sacó a `cp1` de rotación por el health check, dirigiendo las requests a `cp2`/`cp3`. El load balancer hizo el trabajo; el cliente nunca supo que cambió el backend.
- **6c.** Con 1 de 3, reiniciar el sobreviviente **no** restaura quorum: sigue siendo 1 miembro que cree pertenecer a un cluster de 3, y no puede formar quorum solo. Habría que arrancarlo en modo recuperación con `etcdctl snapshot restore` (o `--force-new-cluster`) para forjar un cluster nuevo de 1 miembro a partir de sus datos, y luego re-agregar miembros. El riesgo: `--force-new-cluster` **descarta la información de membresía** y puede perder las escrituras no confirmadas; es una operación destructiva, por eso lo correcto es restaurar desde un `snapshot` reciente.
- **6d.** Con **stacked**, apagar un nodo del control plane te cuesta un `kube-apiserver` **y** un miembro etcd de una: dos fallos correlacionados por host. Con **external**, un host de etcd caído no baja ningún apiserver y viceversa; los dominios de fallo están desacoplados, así que el radio de un fallo de hardware es menor (pero pagás más hosts).

### Ejercicio 7 — External etcd

- **7a.** El `kube-apiserver` necesita el par **cliente `apiserver-etcd-client.crt`/`.key`** (firmado por el CA de etcd) para autenticarse contra el etcd externo por mTLS, más el `ca.crt` de etcd para validar al servidor. Si no están en las rutas del config antes del `init`, kubeadm no puede levantar un apiserver que conecte a etcd y **falla** el bootstrap: no hay backend de almacenamiento al que hablar.
- **7b.** Comprás **aislamiento del dominio de fallo**: la salud de etcd deja de estar acoplada a la del control plane. Un pico de I/O, un OOM o una caída de un host de etcd ya no derriba también un `kube-apiserver`, y actualizar/operar etcd no toca los control planes. El costo son 3 hosts extra y más superficie operativa.
- **7c.** Porque en external topology etcd **no corre como pod estático de Kubernetes** — vive como servicio (systemd/contenedor) en sus hosts dedicados, fuera del control de kubelet. Por eso no hay pods `component=etcd`. La salud la mirás directamente contra esos hosts con `etcdctl endpoint health`/`endpoint status -w table` usando los certificados de cliente, o vía sus métricas en `:2379/metrics`.

</details>