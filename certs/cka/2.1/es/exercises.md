# Ejercicios guiados: Troubleshoot clusters and nodes (CKA 2.1)

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Estos ejercicios asumen un cluster kubeadm con al menos un control-plane node y un worker node, acceso SSH a ambos, y `kubectl` configurado.

---

## Ejercicio 1: Diagnosticar un node en estado `NotReady`

1. Listá los nodes del cluster y observá su estado:
   ```bash
   kubectl get nodes -o wide
   ```
2. Elegí un node (o simulá el problema deteniendo el kubelet en un worker, ver paso 4) y describilo para ver sus `Conditions`:
   ```bash
   kubectl describe node <node-name>
   ```
3. En la sección `Conditions`, identificá el estado de `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure` y `NetworkUnavailable`, y revisá los `Events` al final del output.
4. Para reproducir un `NotReady` real, entrá por SSH al worker node y detené el kubelet:
   ```bash
   sudo systemctl stop kubelet
   ```
5. Desde el control-plane node, volvé a ejecutar `kubectl get nodes` cada 10-15 segundos y observá cuánto tarda el node en pasar a `NotReady` (por defecto, el control plane espera `node-monitoring-grace-period`, ~40s, antes de marcarlo).

**Preguntas de comprensión:**
- ¿Qué componente del control plane es responsable de actualizar el estado de un node en base a los heartbeats que deja de recibir?
- Si `Ready` está en `Unknown` en vez de `False`, ¿qué te dice eso sobre la causa del problema?

---

## Ejercicio 2: Investigar el kubelet con `systemctl` y `journalctl`

1. En el worker donde detuviste el kubelet (Ejercicio 1), verificá su estado:
   ```bash
   sudo systemctl status kubelet
   ```
2. Revisá los logs recientes del kubelet:
   ```bash
   sudo journalctl -u kubelet -n 100 --no-pager
   ```
3. Seguí los logs en tiempo real mientras reiniciás el servicio:
   ```bash
   sudo journalctl -u kubelet -f &
   sudo systemctl start kubelet
   ```
4. Filtrá solo las líneas con nivel de error para identificar rápidamente fallos:
   ```bash
   sudo journalctl -u kubelet -p err --no-pager
   ```
5. Confirmá que el node vuelve a `Ready` desde el control-plane node:
   ```bash
   kubectl get nodes
   ```

**Preguntas de comprensión:**
- ¿Por qué `journalctl -u kubelet` es la primera herramienta a usar (en vez de `kubectl logs`) cuando un node está `NotReady`?
- ¿Dónde está el archivo de configuración del kubelet que `systemctl` usa para arrancarlo, y qué comando te permite ver los flags efectivos con los que corre el proceso?

---

## Ejercicio 3: Troubleshooting del container runtime con `crictl`

1. En el worker node, verificá que el container runtime (containerd) esté activo:
   ```bash
   sudo systemctl status containerd
   ```
2. Usá `crictl` para listar los pods conocidos por el runtime directamente (sin pasar por la API de Kubernetes):
   ```bash
   sudo crictl pods
   ```
3. Listá los containers y su estado:
   ```bash
   sudo crictl ps -a
   ```
4. Si algún container aparece en estado `Exited` o `Error`, inspeccionalo y revisá sus logs a nivel runtime:
   ```bash
   sudo crictl inspect <container-id>
   sudo crictl logs <container-id>
   ```
5. Verificá que el endpoint que usa `crictl` coincide con el que usa el kubelet (`--container-runtime-endpoint`):
   ```bash
   cat /var/lib/kubelet/config.yaml | grep -i containerRuntimeEndpoint
   ```

**Preguntas de comprensión:**
- ¿En qué escenario `crictl ps` muestra información que `kubectl get pods` no puede mostrar?
- ¿Qué mensaje de error esperás ver en los logs del kubelet si el socket del container runtime (`/run/containerd/containerd.sock`) no existe o no responde?

---

## Ejercicio 4: Troubleshooting de componentes del control plane (static pods)

1. En el control-plane node, listá los manifests de static pods:
   ```bash
   ls -la /etc/kubernetes/manifests/
   ```
2. Confirmá que `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` y `etcd` corren como pods en el namespace `kube-system`:
   ```bash
   kubectl get pods -n kube-system -o wide
   ```
3. Provocá una falla intencional: editá el manifest de `kube-scheduler` y metele un typo en la imagen:
   ```bash
   sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/kube-scheduler.yaml.bak
   sudo sed -i 's|image: .*kube-scheduler.*|image: registry.k8s.io/kube-scheduler:vX.Y.Z-typo|' /etc/kubernetes/manifests/kube-scheduler.yaml
   ```
4. Observá cómo el kubelet local detecta el cambio y recrea el pod automáticamente (sin pasar por la API server, ya que es un static pod):
   ```bash
   watch crictl ps -a
   ```
5. Diagnosticá la falla con `kubectl describe` y con los logs del container:
   ```bash
   kubectl describe pod -n kube-system kube-scheduler-<node-name>
   crictl logs $(sudo crictl ps -a --name kube-scheduler -q | head -1)
   ```
6. Restaurá el manifest original y confirmá la recuperación:
   ```bash
   sudo cp /tmp/kube-scheduler.yaml.bak /etc/kubernetes/manifests/kube-scheduler.yaml
   kubectl get pods -n kube-system -l component=kube-scheduler
   ```

**Preguntas de comprensión:**
- ¿Por qué podés seguir usando `kubectl` para inspeccionar el pod de `kube-scheduler` roto, si el propio scheduler no es indispensable para que la API server funcione?
- ¿Qué proceso del sistema es el responsable de vigilar `/etc/kubernetes/manifests/` y recrear los static pods, y cómo se llama el mirror pod que ves reflejado en la API?

---

## Ejercicio 5: Node bajo presión de recursos (`DiskPressure` / `MemoryPressure`)

1. Revisá los thresholds de eviction configurados en el kubelet del worker node:
   ```bash
   cat /var/lib/kubelet/config.yaml | grep -A5 evictionHard
   ```
2. Generá presión de disco artificialmente en el worker (ajustá el tamaño según el espacio libre real):
   ```bash
   sudo fallocate -l 5G /tmp/fill-disk.img
   ```
3. Desde el control-plane node, observá cómo aparece la condition `DiskPressure`:
   ```bash
   kubectl describe node <worker-name> | grep -A10 Conditions
   ```
4. Revisá los eventos del node y de los pods evictados:
   ```bash
   kubectl get events --field-selector involvedObject.kind=Node -A
   kubectl get pods -A --field-selector status.phase=Failed
   ```
5. Limpiá el archivo y confirmá que la condition vuelve a `False`:
   ```bash
   sudo rm /tmp/fill-disk.img
   kubectl describe node <worker-name> | grep -A10 Conditions
   ```

**Preguntas de comprensión:**
- ¿Qué hace el kubelet automáticamente con los pods `BestEffort` cuando el node entra en `DiskPressure` o `MemoryPressure`?
- ¿Qué diferencia hay entre un `eviction` por presión de recursos del node y un pod terminado por `OOMKilled` a nivel de container?

---

## Ejercicio 6: Verificar la salud y expiración de certificados del cluster

1. En el control-plane node, listá el estado de expiración de todos los certificados gestionados por kubeadm:
   ```bash
   sudo kubeadm certs check-expiration
   ```
2. Verificá directamente el certificado del kube-apiserver con `openssl`:
   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
   ```
3. Si `kubectl` empieza a fallar con errores de tipo `x509: certificate has expired`, confirmá el diagnóstico probando la conectividad directa a la API:
   ```bash
   curl -k https://localhost:6443/healthz
   ```
4. Renová los certificados con kubeadm (esto no reinicia servicios automáticamente):
   ```bash
   sudo kubeadm certs renew all
   ```
5. Reiniciá los static pods del control plane moviendo momentáneamente sus manifests para forzar la recarga:
   ```bash
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
   sleep 5
   sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```

**Preguntas de comprensión:**
- ¿Por qué un error `x509: certificate has expired or is not yet valid` puede impedir que hasta `kubectl get nodes` funcione, aunque todos los pods de la aplicación sigan corriendo?
- ¿Qué diferencia hay entre renovar certificados con `kubeadm certs renew` y regenerarlos desde cero con `kubeadm init phase certs`?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- El `node-controller`, que corre dentro del `kube-controller-manager`, es el que marca las conditions del node en base a la falta de heartbeats (`NodeStatus`) reportados por el kubelet.
- `Unknown` significa que el control plane perdió la comunicación con el kubelet (no recibe heartbeats) y no puede determinar el estado real del node — a diferencia de `False`, donde el kubelet sigue reportando pero informa explícitamente que alguna condition no se cumple.

**Ejercicio 2**
- Porque `kubectl logs` depende de que la API server pueda comunicarse con el kubelet del node afectado; si el kubelet está caído, esa vía no funciona. `journalctl` accede directamente al log del servicio systemd en el node, que es la única fuente disponible en ese escenario.
- El archivo de configuración está en `/var/lib/kubelet/config.yaml` (y los flags de arranque suelen estar en el unit file de systemd, típicamente bajo `/etc/systemd/system/kubelet.service.d/`). Para ver los flags efectivos con los que corre el proceso, se puede usar `ps aux | grep kubelet` o revisar `systemctl cat kubelet`.

**Ejercicio 3**
- Cuando el kubelet no puede comunicarse con la API server (o el node está `NotReady`/aislado de la red), `crictl` sigue funcionando porque habla directamente con el socket del container runtime en el node, mostrando el estado real de los containers aunque Kubernetes no tenga esa información actualizada.
- El kubelet reportaría errores del tipo `RunPodSandbox` o `rpc error: code = Unavailable desc = connection error` al intentar conectarse al `container-runtime-endpoint`, y el node normalmente pasaría a `NotReady` con una condition relacionada al runtime.

**Ejercicio 4**
- Porque `kubectl describe`/`get pods` solo necesitan que la API server esté sana para leer el estado guardado en etcd; el kube-scheduler roto no impide que la API server siga funcionando, solo impide que se asignen nuevos pods a nodes (el scheduling se detiene, pero el resto del cluster sigue operativo).
- El kubelet local es el que vigila el directorio `/etc/kubernetes/manifests/` (configurado vía `staticPodPath`) y recrea el container automáticamente al detectar cambios. La representación de ese static pod dentro de la API se llama mirror pod, identificable por el sufijo `-<node-name>` en su nombre y por no poder eliminarse vía `kubectl delete` (hay que editar o borrar el manifest en el node).

**Ejercicio 5**
- El kubelet evictúa (elimina) primero los pods `BestEffort`, luego los `Burstable` que exceden sus requests, priorizando mantener el node estable; los pods `Guaranteed` son los últimos en ser evictados.
- Un eviction por presión de recursos del node es una decisión del kubelet a nivel de pod completo, basada en las conditions del node (`DiskPressure`/`MemoryPressure`) y aplica el algoritmo de eviction manager; un `OOMKilled` es una acción del kernel de Linux (cgroup OOM killer) sobre un container individual que excedió su límite de memoria, independientemente del estado general del node.

**Ejercicio 6**
- Porque todo el tráfico de `kubectl` pasa por TLS contra la API server usando ese certificado; si expiró, la conexión TLS falla en la fase de handshake antes de que cualquier request llegue a procesarse, sin importar si los pods de la aplicación (que no dependen de ese certificado para seguir corriendo) están sanos.
- `kubeadm certs renew` extiende la validez de los certificados existentes manteniendo la misma CA y las mismas claves de identidad (aplica solo si la CA sigue siendo válida), mientras que `kubeadm init phase certs` regenera certificados desde cero, lo cual puede usarse para reconstruir una CA completa o certificados individuales dañados o comprometidos.

</details>