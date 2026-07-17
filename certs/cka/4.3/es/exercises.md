# CKA 4.3 — Manage the lifecycle of Kubernetes clusters

Ejercicios guiados para practicar el ciclo de vida completo de un cluster de Kubernetes administrado con `kubeadm`: revisión de versiones, `cordon`/`drain` de nodos, upgrade del control plane y de los worker nodes, y alta/baja de nodos.

**Fuente de referencia:** [CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

**Prerrequisitos:** cluster creado con `kubeadm`, con un control plane node (por ejemplo `k8s-cp1`) y dos worker nodes (`k8s-worker1`, `k8s-worker2`), acceso `sudo` en cada nodo y `kubectl` configurado contra el cluster.

---

## Ejercicio 1 — Auditar el estado del cluster antes de intervenir

1. Desde una terminal con acceso al cluster, listá los nodos y sus versiones de `kubelet`:
   ```bash
   kubectl get nodes -o wide
   ```
2. Confirmá la versión del `kube-apiserver` actualmente en uso:
   ```bash
   kubectl version
   ```
3. Revisá que todos los pods del namespace `kube-system` estén `Running`:
   ```bash
   kubectl get pods -n kube-system
   ```
4. Anotá la versión de cada nodo y la del control plane; la vas a necesitar para verificar el resultado del upgrade más adelante.

**Preguntas:**
- ¿Qué política de Kubernetes limita cuántas versiones minor de diferencia puede haber entre el `kube-apiserver` y el `kubelet` de un nodo?
- ¿Por qué es mala práctica saltar directamente de una versión minor a otra que esté dos o más versiones adelante (por ejemplo, de 1.33 a 1.35) en un solo paso?

---

## Ejercicio 2 — Cordon y drain de un worker node

1. Marcá `k8s-worker1` como no programable:
   ```bash
   kubectl cordon k8s-worker1
   ```
2. Verificá que el nodo aparece como `SchedulingDisabled`:
   ```bash
   kubectl get nodes
   ```
3. Drenalo para reubicar sus pods, ignorando DaemonSets y liberando volúmenes `emptyDir`:
   ```bash
   kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
   ```
4. Si el comando falla por un pod standalone (sin controlador detrás), decidí si corresponde agregar `--force` o si conviene respaldar/recrear ese pod manualmente antes.
5. Confirmá que no quedan pods de aplicación corriendo en el nodo:
   ```bash
   kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=k8s-worker1
   ```

**Preguntas:**
- ¿Qué diferencia hay entre `cordon` y `drain`, y en qué orden conviene aplicarlos?
- ¿Por qué `drain` requiere `--ignore-daemonsets` en un cluster típico y qué pasaría si no lo indicás?
- ¿Qué riesgo corrés al usar `--force` sobre un pod que no pertenece a ningún controlador?

---

## Ejercicio 3 — Upgrade del primer control plane node con kubeadm

1. Conectate por SSH a `k8s-cp1` y revisá la versión instalada de `kubeadm`:
   ```bash
   kubeadm version
   ```
2. Actualizá el paquete `kubeadm` a la versión minor objetivo (reemplazá `1.35.x-00` por la versión real disponible en tu repositorio de paquetes):
   ```bash
   sudo apt-get update
   sudo apt-get install -y --allow-change-held-packages kubeadm=1.35.x-00
   ```
3. Revisá el plan de upgrade que propone `kubeadm` antes de aplicar nada:
   ```bash
   sudo kubeadm upgrade plan
   ```
4. Al ser el primer control plane node del cluster, aplicá el upgrade:
   ```bash
   sudo kubeadm upgrade apply v1.35.x
   ```
5. Si en cambio se tratara de un control plane node adicional en un cluster HA, el comando correcto sería:
   ```bash
   sudo kubeadm upgrade node
   ```

**Preguntas:**
- ¿Por qué `kubeadm upgrade plan` no modifica nada en el cluster y qué deberías revisar en su salida antes de continuar?
- ¿Cuándo corresponde usar `kubeadm upgrade apply` en lugar de `kubeadm upgrade node`?

---

## Ejercicio 4 — Upgrade de kubelet y kubectl en el control plane

1. Sacá `k8s-cp1` de rotación de scheduling si todavía no lo hiciste:
   ```bash
   kubectl drain k8s-cp1 --ignore-daemonsets
   ```
2. Actualizá `kubelet` y `kubectl` a la misma versión minor usada en el Ejercicio 3:
   ```bash
   sudo apt-get install -y --allow-change-held-packages kubelet=1.35.x-00 kubectl=1.35.x-00
   ```
3. Recargá `systemd` y reiniciá el servicio `kubelet`:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```
4. Devolvé el nodo a rotación de scheduling:
   ```bash
   kubectl uncordon k8s-cp1
   ```
5. Confirmá que el nodo reporta la nueva versión:
   ```bash
   kubectl get nodes
   ```

**Preguntas:**
- ¿Qué pasaría si actualizás el binario de `kubelet` sin haber corrido antes `kubeadm upgrade apply`/`kubeadm upgrade node` en ese nodo?
- ¿Por qué hay que reiniciar el servicio `kubelet` después de reemplazar el binario?

---

## Ejercicio 5 — Upgrade de un worker node

1. Desde una terminal con `kubectl`, drená el nodo a actualizar:
   ```bash
   kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
   ```
2. Conectate por SSH a `k8s-worker1` y actualizá `kubeadm`:
   ```bash
   sudo apt-get update
   sudo apt-get install -y --allow-change-held-packages kubeadm=1.35.x-00
   ```
3. Alineá la configuración local del nodo (los workers no ejecutan `kubeadm upgrade apply`):
   ```bash
   sudo kubeadm upgrade node
   ```
4. Actualizá `kubelet` y `kubectl`, y reiniciá el servicio:
   ```bash
   sudo apt-get install -y --allow-change-held-packages kubelet=1.35.x-00 kubectl=1.35.x-00
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

**Preguntas:**
- ¿Por qué los worker nodes usan `kubeadm upgrade node` y nunca `kubeadm upgrade apply`?
- ¿Qué comando corrés, desde fuera del nodo, para confirmar que el upgrade se completó?

---

## Ejercicio 6 — Uncordon y verificación post-upgrade

1. Devolvé `k8s-worker1` a rotación de scheduling:
   ```bash
   kubectl uncordon k8s-worker1
   ```
2. Repetí los Ejercicios 2, 5 y este para `k8s-worker2`, un nodo a la vez.
3. Verificá que todo el cluster esté en la nueva versión:
   ```bash
   kubectl get nodes -o wide
   ```
4. Confirmá que `kube-system` volvió a `Running` y que ningún pod quedó `Pending`:
   ```bash
   kubectl get pods -n kube-system
   kubectl get pods --all-namespaces --field-selector=status.phase!=Running
   ```

**Preguntas:**
- ¿Por qué conviene actualizar los worker nodes de a uno y no todos en simultáneo?
- Si un pod queda en `Pending` después del upgrade, ¿qué dos causas deberías descartar primero?

---

## Ejercicio 7 — Agregar un nuevo worker node al cluster

1. En `k8s-cp1`, generá un comando de `join` con un token válido (expiran a las 24 horas por defecto):
   ```bash
   sudo kubeadm token create --print-join-command
   ```
2. En el nodo nuevo, con `containerd` y `kubeadm`/`kubelet` ya instalados en la misma versión minor que el cluster, ejecutá el comando devuelto:
   ```bash
   sudo kubeadm join <control-plane-host>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
   ```
3. Desde una terminal con `kubectl`, confirmá que el nodo llegó a `Ready`:
   ```bash
   kubectl get nodes
   ```
4. Etiquetá el nodo según su rol si tu organización lo requiere:
   ```bash
   kubectl label node <nombre-del-nuevo-nodo> node-role.kubernetes.io/worker=
   ```

**Preguntas:**
- ¿Qué dos piezas de información del control plane necesita un nodo nuevo para hacer `join` de forma segura?
- ¿Qué pasa si intentás usar un token que ya expiró?

---

## Ejercicio 8 — Remover un nodo del cluster de forma segura

1. Drená el nodo a dar de baja:
   ```bash
   kubectl drain <nombre-del-nodo> --ignore-daemonsets --delete-emptydir-data
   ```
2. Eliminá el objeto `Node` del API server:
   ```bash
   kubectl delete node <nombre-del-nodo>
   ```
3. En la VM/host físico que estás retirando, revertí la configuración que dejó `kubeadm`:
   ```bash
   sudo kubeadm reset
   ```
4. Limpiá manualmente las reglas de `iptables`/`nftables` y la configuración de red que hayan quedado, según indique la salida de `kubeadm reset`.
5. Si el nodo no vuelve a usarse, apagalo o reasignalo; si va a reingresar más adelante, generá un token de `join` nuevo cuando llegue el momento.

**Preguntas:**
- ¿Por qué hay que hacer `drain` antes de `delete node`, y qué pasaría si eliminás el objeto `Node` sin drenarlo primero?
- ¿Qué hace exactamente `kubeadm reset` en el nodo, y qué es lo que NO revierte automáticamente?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- La *version skew policy* de Kubernetes permite que el `kubelet` de un nodo esté hasta 3 versiones minor por detrás del `kube-apiserver`, pero nunca por delante. `kube-controller-manager`, `kube-scheduler` y `kube-proxy` tampoco deben estar por delante del `kube-apiserver` y suelen mantenerse alineados a su misma versión minor.
- `kubeadm upgrade` solo soporta saltos de una versión minor por vez. Saltear versiones minor puede dejar componentes con APIs incompatibles entre sí, además de perder los pasos de migración que cada versión intermedia aplica automáticamente.

**Ejercicio 2**
- `cordon` solo marca el nodo como no programable para pods nuevos, sin tocar los existentes; `drain` hace `cordon` implícitamente y además desaloja (evict) los pods que ya están corriendo. Conviene dejar que `drain` se encargue de ambos pasos en ese orden.
- Los pods de DaemonSets están diseñados para correr uno por nodo y se recrean automáticamente al eliminarse; `drain` no puede reubicarlos en otro nodo, así que sin `--ignore-daemonsets` el comando queda bloqueado esperando desalojar algo que no se puede reprogramar.
- `--force` elimina pods sin controlador detrás (sin ReplicaSet, Deployment, StatefulSet, etc.), por lo que esos pods no se recrean en otro nodo: se pierden definitivamente, junto con cualquier estado en memoria o en `emptyDir`.

**Ejercicio 3**
- `kubeadm upgrade plan` es de solo lectura: consulta versiones disponibles y compara contra el estado actual, mostrando qué componentes se actualizarían. Antes de continuar hay que revisar la versión objetivo propuesta, los componentes afectados (`etcd`, `CoreDNS`, etc.) y advertencias sobre configuración deprecada.
- `kubeadm upgrade apply` se corre una sola vez, en el primer control plane node del cluster (el que fija la nueva versión). `kubeadm upgrade node` se usa en los control plane nodes adicionales y en todos los worker nodes, para alinearlos a la versión que ya fijó `upgrade apply`.

**Ejercicio 4**
- Si actualizás `kubelet` antes de correr `kubeadm upgrade` en ese nodo, la configuración estática (manifiestos de `kube-apiserver`, `etcd`, etc. en `/etc/kubernetes/manifests`) puede quedar desalineada con la nueva versión, generando errores de arranque en los pods estáticos del control plane.
- El servicio `systemd` sigue corriendo el proceso original en memoria hasta el restart; reemplazar el binario en disco no aplica el cambio hasta reiniciar el servicio.

**Ejercicio 5**
- Solo el control plane necesita fijar la nueva versión del cluster con `kubeadm upgrade apply`; los worker nodes no administran estado del cluster (no corren `etcd` ni `kube-apiserver`), así que solo necesitan alinear su configuración local con `kubeadm upgrade node`.
- `kubectl get nodes -o wide` muestra la columna `KUBELET-VERSION` de cada nodo, confirmando la versión efectiva sin necesidad de conectarse por SSH.

**Ejercicio 6**
- Actualizar de a un nodo por vez mantiene capacidad disponible para reprogramar los pods desalojados y limita el impacto si el upgrade de un nodo falla; actualizar todos a la vez podría dejar temporalmente sin nodos `Ready` a workloads con requisitos de disponibilidad.
- Primero hay que descartar que no queden nodos con `SchedulingDisabled` (cordon olvidado) y que los `resource requests` del pod entren en la capacidad libre de algún nodo `Ready`; ambas son causas típicas de `Pending` tras un mantenimiento de nodos.

**Ejercicio 7**
- Necesita la dirección y puerto del `kube-apiserver` del control plane, y el hash del certificado CA del cluster (`discovery-token-ca-cert-hash`) para verificar que se conecta al control plane correcto, además del token que autentica el `join` frente al API server.
- Un token expirado hace que `kubeadm join` falle en el paso de discovery/bootstrap; hay que generar uno nuevo con `kubeadm token create --print-join-command`.

**Ejercicio 8**
- Sin `drain`, `kubectl delete node` elimina el objeto `Node` del API server pero no reubica los pods que estaban corriendo ahí: quedan huérfanos/`Terminating` sin garantía de recrearse ordenadamente en otro nodo antes de que el nodo físico se apague.
- `kubeadm reset` revierte los cambios locales que aplicó `kubeadm` (certificados, configuración de `kubelet`, archivos en `/etc/kubernetes`) y detiene el `kubelet`, pero no limpia por sí solo las reglas de `iptables`/`IPVS` ni la configuración del plugin CNI, que suelen requerir limpieza manual.

</details>