# CKA 1.35 — Tema 4.4: Implement and configure a highly-available control plane

**Peso en el examen:** 3.57%
**Referencia:** [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Estos ejercicios asumen que tenés acceso a un cluster `kubeadm` con al menos un control-plane node ya inicializado (`kubeadm init`) y, cuando se indique, un nodo adicional listo para unirse como control-plane. Si trabajás en un lab de un solo nodo, los pasos de inspección (bloques 1, 2, 4 y 5) igual son válidos; el bloque 3 podés seguirlo en modo lectura, analizando los comandos sin ejecutar el join real.

---

## Bloque 1 — Explorar la arquitectura HA existente

1. Listá los nodos del cluster y confirmá cuáles cumplen el rol de control-plane:
   ```bash
   kubectl get nodes -o wide
   kubectl get nodes -l node-role.kubernetes.io/control-plane
   ```
2. Revisá a qué endpoint apunta tu `kubeconfig`:
   ```bash
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
   ```
3. Compará esa dirección con la IP de cada control-plane node individual (`kubectl get nodes -o wide` muestra `INTERNAL-IP`). En un cluster HA construido con `kubeadm init --control-plane-endpoint`, ese valor no debería coincidir con la IP de ningún nodo individual.
4. Inspeccioná el estado general del cluster:
   ```bash
   kubectl cluster-info
   ```

**Preguntas de comprensión:**
- ¿Por qué el `kubeconfig` de un cluster HA apunta a una dirección distinta de la IP de cada API server individual?
- ¿Qué componente de infraestructura falta si el `server:` del kubeconfig apunta directamente a un solo control-plane node, y qué riesgo introduce eso?

---

## Bloque 2 — Inspeccionar la topología de etcd

1. Conectate (o abrí una shell) en un control-plane node y revisá el manifest estático de etcd:
   ```bash
   sudo cat /etc/kubernetes/manifests/etcd.yaml
   ```
2. Identificá dentro del manifest las flags `--initial-cluster`, `--listen-peer-urls` y `--listen-client-urls`. Anotá cuántos miembros aparecen listados en `--initial-cluster`.
3. Consultá el estado del cluster etcd usando `etcdctl` (los certificados están en `/etc/kubernetes/pki/etcd/`):
   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list -w table
   ```
4. Repetí el comando anterior agregando `endpoint health --cluster` en lugar de `member list` para ver el estado de salud de cada miembro.

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre una topología de **stacked etcd** (etcd corriendo como pod estático en cada control-plane node) y una topología de **external etcd** (cluster etcd separado)? Mencioná al menos una ventaja y una desventaja de cada una.
- Si el manifest muestra 3 miembros en `--initial-cluster`, ¿cuántos miembros pueden fallar simultáneamente sin que el cluster etcd pierda quorum?

---

## Bloque 3 — Agregar un control-plane node adicional

1. En un control-plane node ya existente, generá una clave para poder distribuir certificados de forma segura al nuevo nodo:
   ```bash
   sudo kubeadm init phase upload-certs --upload-certs
   ```
   Guardá el valor de `certificate-key` que imprime el comando.
2. Generá el comando de join completo, incluyendo token y hash de descubrimiento:
   ```bash
   kubeadm token create --print-join-command
   ```
3. Combiná ambos resultados y ejecutá en el nuevo nodo (como root) algo equivalente a:
   ```bash
   sudo kubeadm join <control-plane-endpoint>:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash> \
     --control-plane \
     --certificate-key <certificate-key>
   ```
4. Desde una máquina con acceso al cluster, confirmá que el nuevo nodo se unió como control-plane:
   ```bash
   kubectl get nodes -l node-role.kubernetes.io/control-plane
   ```

**Preguntas de comprensión:**
- Si ejecutás `kubeadm join ... --control-plane` **sin** pasar `--certificate-key`, ¿qué falla y por qué?
- La `certificate-key` generada por `upload-certs` expira automáticamente después de 2 horas. ¿Qué problema de seguridad busca mitigar ese comportamiento?

---

## Bloque 4 — Verificar leader election entre control-plane nodes

1. Listá los objetos `Lease` del namespace `kube-system` usados para leader election:
   ```bash
   kubectl get lease -n kube-system
   ```
2. Inspeccioná en detalle las leases de `kube-controller-manager` y `kube-scheduler`:
   ```bash
   kubectl describe lease kube-controller-manager -n kube-system
   kubectl describe lease kube-scheduler -n kube-system
   ```
3. Anotá el valor de `holderIdentity` en cada una: indica qué nodo tiene el rol activo (leader) para ese componente en este momento.
4. Repetí el `describe` un par de minutos después y compará si `holderIdentity` cambió.

**Preguntas de comprensión:**
- `kube-apiserver` corre activo simultáneamente en todos los control-plane nodes, pero `kube-controller-manager` y `kube-scheduler` no. ¿Por qué estos dos últimos necesitan leader election mientras que el API server no?
- ¿Qué flag de arranque habilita el mecanismo de leader election en `kube-controller-manager` y `kube-scheduler`?

---

## Bloque 5 — Simular la falla de un control-plane node

1. Elegí un control-plane node que **no** sea el que estás usando para ejecutar `kubectl` y drenalo:
   ```bash
   kubectl drain <nombre-del-nodo> --ignore-daemonsets --delete-emptydir-data
   ```
2. Verificá que el resto del cluster sigue respondiendo consultas normalmente:
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```
3. Revisá nuevamente el estado de los miembros de etcd (Bloque 2, paso 3) apuntando a un endpoint de un nodo distinto al drenado, y confirmá si el miembro correspondiente al nodo drenado sigue reportando salud (drain no detiene los pods estáticos de etcd, solo mueve las cargas schedulables).
4. Revertí el estado del nodo:
   ```bash
   kubectl uncordon <nombre-del-nodo>
   ```

**Preguntas de comprensión:**
- En un cluster con 3 control-plane nodes y stacked etcd, ¿qué pasa con la disponibilidad del cluster si perdés **2** de los 3 nodos simultáneamente (no solo drain, sino apagados)? Relacioná tu respuesta con el concepto de quorum visto en el Bloque 2.
- `kubectl drain` no apaga el nodo ni detiene los pods estáticos (como `etcd` o `kube-apiserver`). ¿Qué comando o acción adicional harías para simular una falla real de hardware en ese nodo?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Bloque 1**
- El `kubeconfig` apunta a una dirección de **load balancer** (o a un registro DNS que resuelve a uno) porque en una arquitectura HA hay múltiples API servers activos simultáneamente. El load balancer distribuye las requests entre todos ellos y permite que el cluster siga siendo alcanzable aunque un control-plane node individual falle.
- Si el `server:` apunta directamente a la IP de un solo nodo, ese nodo se convierte en single point of failure para el acceso al API server: si cae, todo cliente que use ese kubeconfig pierde conectividad con el cluster, incluso si los demás control-plane nodes siguen sanos.

**Bloque 2**
- **Stacked etcd**: etcd corre como pod estático en cada control-plane node, junto al API server. Ventaja: topología más simple, menos nodos que administrar. Desventaja: acopla el ciclo de vida de etcd al del control-plane node — perder un nodo afecta ambos componentes a la vez, aumentando el radio de impacto de una falla.
  **External etcd**: el cluster etcd corre en nodos dedicados, separados de los control-plane nodes. Ventaja: aísla la falla de un control-plane node de la del cluster etcd (más resiliente). Desventaja: requiere más nodos e infraestructura, mayor complejidad operativa.
- Con 3 miembros, el quorum necesario es `(3/2)+1 = 2`. Por lo tanto, puede fallar **1** miembro sin perder quorum; si fallan 2, el cluster etcd deja de aceptar escrituras.

**Bloque 3**
- Sin `--certificate-key`, `kubeadm join --control-plane` falla porque no tiene forma de descargar de manera segura los certificados de control-plane (API server, etcd, front-proxy, etc.) que ya existen en el cluster. El nuevo nodo necesita esos certificados para poder actuar como control-plane, y `certificate-key` es la clave simétrica con la que `upload-certs` los cifró y subió temporalmente como Secret en el cluster.
- La expiración a las 2 horas limita la ventana de tiempo en la que esa clave (que da acceso a material criptográfico sensible del cluster) es válida, reduciendo el riesgo de que quede expuesta o reutilizada si se filtra o se olvida en un log/historial de comandos.

**Bloque 4**
- `kube-apiserver` es stateless respecto a la lógica de negocio (solo sirve el API sobre datos en etcd), por lo que puede correr activo en paralelo en todos los nodos sin conflicto: cada instancia atiende requests independientemente. `kube-controller-manager` y `kube-scheduler`, en cambio, ejecutan lógica de reconciliación y decisiones (como el scheduling de pods) que si corriera duplicada en paralelo generaría condiciones de carrera y decisiones contradictorias. Por eso solo una instancia (el leader) debe estar activa a la vez, mientras las demás quedan en standby.
- La flag es `--leader-elect=true` (habilitada por defecto en los manifests generados por `kubeadm`).

**Bloque 5**
- Con 3 control-plane nodes y stacked etcd, perder 2 nodos deja un solo miembro de etcd en pie, por debajo del quorum de 2 calculado en el Bloque 2. El cluster etcd deja de aceptar escrituras, lo que impide al `kube-apiserver` sobreviviente persistir cambios de estado: el cluster queda efectivamente en modo de solo lectura (o inoperable) hasta que se recupere el quorum.
- Para simular una falla real habría que apagar el nodo (`shutdown`/detener la VM) o directamente detener el proceso del kubelet y los pods estáticos (`etcd`, `kube-apiserver`, etc.) en esa máquina, en vez de solo drenarlo, ya que `drain` únicamente reprograma las cargas schedulables y no toca los componentes de control plane que corren como pods estáticos gestionados por el kubelet local.

</details>