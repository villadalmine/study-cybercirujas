# CKA 4.6 — Ejercicios guiados: Understand extension interfaces (CNI, CSI, CRI, etc.)

*Peso en el examen: 3.57% · Certificación: CKA v1.35*
*Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)*

Estos ejercicios asumen un cluster creado con `kubeadm`, con `containerd` como container runtime y `crictl` instalado en los nodos. Ejecutá los comandos con acceso `root` (o `sudo`) en el control plane o en un worker node, salvo que se indique lo contrario.

---

## Ejercicio 1 — Container Runtime Interface (CRI)

El **kubelet** no crea contenedores directamente: habla con el container runtime a través de la **CRI**, un contrato gRPC. `crictl` es el cliente de línea de comandos que habla ese mismo protocolo, sin pasar por la API de Kubernetes.

1. Identificá el endpoint de CRI que usa el kubelet:
   ```bash
   ps -ef | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*'
   ```
   Si no aparece explícito, revisá el valor por defecto en la config del kubelet:
   ```bash
   cat /var/lib/kubelet/config.yaml | grep -i containerRuntimeEndpoint
   ```

2. Confirmá que `crictl` apunta al mismo socket:
   ```bash
   cat /etc/crictl.yaml
   ```

3. Listá los contenedores desde el punto de vista del runtime (no de la API de Kubernetes):
   ```bash
   sudo crictl ps
   sudo crictl ps -a
   ```

4. Listá los pod sandboxes (la unidad de aislamiento de red/namespace que agrupa los contenedores de un Pod):
   ```bash
   sudo crictl pods
   ```

5. Elegí un contenedor de la salida del paso 3 e inspeccionalo a bajo nivel:
   ```bash
   sudo crictl inspect <container-id>
   ```

6. Compará esa salida con lo que ve `kubectl` para el mismo Pod:
   ```bash
   kubectl get pod <pod-name> -o wide
   ```

7. Consultá info general del runtime, incluyendo si el CNI está configurado correctamente:
   ```bash
   sudo crictl info
   ```

**Preguntas de comprensión**

- ¿Qué componente de Kubernetes fue removido en la versión 1.24 y obligó a que todos los runtimes implementen CRI directamente?
- En la salida de `crictl info`, ¿qué campo indica si el runtime considera que el CNI está listo?
- ¿Por qué `crictl ps` puede mostrar contenedores que `kubectl get pods` no muestra (o viceversa)?

---

## Ejercicio 2 — Container Network Interface (CNI)

El kubelet delega la configuración de red del pod sandbox a un **plugin CNI**, invocado como binario ejecutable con variables de entorno (`CNI_COMMAND=ADD/DEL/CHECK`, etc.) y un archivo de configuración JSON como entrada estándar.

1. Listá la configuración CNI activa en el nodo:
   ```bash
   ls /etc/cni/net.d/
   ```

2. Inspeccioná el archivo `.conflist` (o `.conf`) que encontraste:
   ```bash
   cat /etc/cni/net.d/*.conflist
   ```
   Prestá atención a los campos `cniVersion`, `plugins[].type` y (si existe) `ipam.type`.

3. Listá los binarios de plugins CNI disponibles en el nodo:
   ```bash
   ls /opt/cni/bin/
   ```

4. Identificá qué componente de Kubernetes instaló y mantiene ese plugin (suele ser un DaemonSet en `kube-system`):
   ```bash
   kubectl get daemonset -n kube-system
   kubectl get pods -n kube-system -o wide | grep -Ei 'calico|flannel|cilium|weave'
   ```

5. Describí ese pod y localizá los `hostPath` volumes que le dan acceso a `/etc/cni/net.d` y `/opt/cni/bin`:
   ```bash
   kubectl describe pod <cni-pod-name> -n kube-system
   ```

6. Creá un Pod nuevo y verificá qué IP le asignó el plugin CNI:
   ```bash
   kubectl run cni-test --image=nginx --restart=Never
   kubectl get pod cni-test -o jsonpath='{.status.podIP}{"\n"}'
   ```

7. Confirmá que esa IP pertenece al rango configurado como pod CIDR del cluster:
   ```bash
   kubectl cluster-info dump | grep -m1 -- '--cluster-cidr'
   ```

**Preguntas de comprensión**

- ¿En qué formato está escrito el archivo de configuración CNI, y qué campo determina qué binario se ejecuta?
- ¿Quién invoca al plugin CNI: el kubelet directamente, o el container runtime a través de CRI?
- Si borrás el archivo en `/etc/cni/net.d/` de un nodo, ¿qué le pasa a los Pods nuevos que se programen ahí?

---

## Ejercicio 3 — Container Storage Interface (CSI)

**CSI** permite que proveedores de storage externos (cloud o on-prem) expongan volúmenes a Kubernetes sin necesidad de código *in-tree*. Un driver CSI típico se despliega como un `Deployment` (controller plugin: `csi-provisioner`, `csi-attacher`) y un `DaemonSet` (node plugin: `node-driver-registrar` + el driver), comunicándose con el kubelet vía un socket Unix.

1. Listá los CSI drivers registrados en el cluster:
   ```bash
   kubectl get csidrivers
   ```

2. Listá qué drivers están disponibles en cada nodo:
   ```bash
   kubectl get csinodes
   kubectl describe csinodes <node-name>
   ```

3. Encontrá los pods del driver CSI (suelen vivir en `kube-system` o un namespace dedicado):
   ```bash
   kubectl get pods -A -o wide | grep -i csi
   ```

4. Describí el pod del **node plugin** e identificá los contenedores sidecar y el socket compartido:
   ```bash
   kubectl describe pod <csi-node-pod> -n <namespace>
   ```
   Buscá el volumen `hostPath` que apunta a `/var/lib/kubelet/plugins/<driver-name>/` y el contenedor `node-driver-registrar`.

5. Creá un StorageClass que use ese driver como `provisioner`, y una PVC que lo consuma:
   ```bash
   kubectl get storageclass
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: csi-test-pvc
   spec:
     accessModes: ["ReadWriteOnce"]
     storageClassName: <storageclass-name>
     resources:
       requests:
         storage: 1Gi
   EOF
   ```

6. Verificá que la PVC quedó `Bound` y examiná el PV resultante:
   ```bash
   kubectl get pvc csi-test-pvc
   kubectl describe pv $(kubectl get pvc csi-test-pvc -o jsonpath='{.spec.volumeName}')
   ```
   Fijate en el bloque `CSI:` — `Driver`, `VolumeHandle`, `FSType`.

7. Listá el objeto que registra el attach del volumen al nodo:
   ```bash
   kubectl get volumeattachments
   ```

**Preguntas de comprensión**

- ¿Qué diferencia hay entre el *controller plugin* y el *node plugin* de un driver CSI, y por qué normalmente se despliegan como tipos de workload distintos (Deployment vs. DaemonSet)?
- ¿Qué rol cumple el sidecar `node-driver-registrar`?
- Al describir el PV, ¿qué campo prueba que el volumen fue provisionado dinámicamente por CSI y no por un plugin *in-tree*?

---

## Ejercicio 4 — Integrando las tres interfaces

1. Elegí un Pod en ejecución y determiná, en orden, qué interfaz interviene en cada etapa de su ciclo de vida:
   ```bash
   kubectl get pod <pod-name> -o wide
   sudo crictl inspectp <pod-sandbox-id>
   ```

2. A partir de la salida anterior, respondé por escrito (en tus propias palabras) la secuencia:
   `kubelet → ??? → ??? → ???`
   ubicando **CRI**, **CNI** y **CSI** en el punto del flujo donde actúan.

**Preguntas de comprensión**

- ¿Cuál de las tres interfaces actúa *antes* de que exista el pod sandbox, cuál durante su creación, y cuál puede actuar después (attach/detach en caliente)?
- Si un Pod queda en `ContainerCreating` indefinidamente, ¿qué logs y comandos usarías para determinar si el problema está en CRI, CNI o CSI?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1 — CRI**

- `dockershim` fue removido en Kubernetes 1.24. Antes traducía las llamadas CRI del kubelet al Docker Engine (que no hablaba CRI nativamente); al eliminarse, todo runtime debe implementar el protocolo CRI directamente (containerd y CRI-O ya lo hacían de forma nativa).
- En `crictl info`, el campo `status.conditions` incluye `NetworkReady`; si es `false`, el runtime no puede levantar pod sandboxes porque el CNI no está configurado o falló.
- `crictl` habla directo con el socket del runtime (nivel CRI), mientras que `kubectl` habla con el API server (nivel Kubernetes). Pueden divergir si, por ejemplo, un contenedor "huérfano" quedó vivo a nivel runtime pero su Pod ya fue borrado del API, o si el kubelet aún no sincronizó el estado.

**Ejercicio 2 — CNI**

- Es JSON (o una lista de plugins JSON en un `.conflist`). El campo `type` (dentro de cada objeto en `plugins[]`) indica el nombre del binario ejecutable en `/opt/cni/bin` que se invoca.
- El kubelet nunca invoca CNI directamente: se lo pide al container runtime a través de CRI (`RunPodSandbox`), y es el runtime (containerd/CRI-O) quien ejecuta el binario CNI con las variables de entorno correspondientes.
- Los Pods nuevos programados en ese nodo quedarán en `ContainerCreating`: `RunPodSandbox` fallará porque el runtime no encuentra una configuración CNI válida, y verás el evento `NetworkPluginNotReady` o similar en `kubectl describe pod`.

**Ejercicio 3 — CSI**

- El *controller plugin* (csi-provisioner, csi-attacher) hace operaciones globales de cluster —crear/borrar volúmenes en el backend, decidir el attach a un nodo— por eso corre como Deployment (una sola réplica activa alcanza). El *node plugin* debe montar el volumen en el filesystem local de cada nodo donde corre el Pod, por eso corre como DaemonSet (una instancia por nodo).
- `node-driver-registrar` le informa al kubelet, a través del socket en `/var/lib/kubelet/plugins_registry/`, qué driver CSI está disponible en ese nodo y en qué socket puede contactarlo (`NodeStageVolume`/`NodePublishVolume`).
- El bloque `CSI:` en la descripción del PV (con `Driver`, `VolumeHandle`, `VolumeAttributes`) sólo aparece en volúmenes provisionados vía CSI; un volumen *in-tree* mostraría en cambio un bloque específico del tipo (p. ej. `AWSElasticBlockStore:`, `NFS:`).

**Ejercicio 4 — Integración**

- Secuencia típica: `kubelet` recibe el PodSpec → pide al runtime vía **CRI** crear el pod sandbox → el runtime invoca el plugin **CNI** para darle red al sandbox → el runtime crea los contenedores del Pod vía **CRI** → si el Pod referencia una PVC, el kubelet coordina con el driver **CSI** (vía el controller plugin para el attach a nivel cluster, y el node plugin local para el mount) antes o durante el arranque de los contenedores que consumen ese volumen.
- CRI actúa en la creación del sandbox y los contenedores (siempre). CNI actúa una sola vez, al crear el sandbox (y al eliminarlo). CSI puede actuar después del arranque inicial: un `VolumeAttachment` puede crearse/destruirse dinámicamente sin recrear el Pod.
- Diagnóstico: `kubectl describe pod` (eventos) es el primer paso siempre. Si el evento menciona `FailedCreatePodSandBox` → mirar CNI (`/etc/cni/net.d`, logs del pod del plugin de red). Si menciona timeouts de runtime o `RunContainer` → mirar CRI (`crictl ps`, `journalctl -u containerd`). Si menciona `FailedMount`/`FailedAttachVolume` → mirar CSI (logs del controller y node plugin, `kubectl get volumeattachments`, `kubectl get events` filtrando por el nombre de la PVC).

</details>