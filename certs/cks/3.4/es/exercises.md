# CKS · Dominio 3.4 — Upgrade Kubernetes to avoid vulnerabilities

**Peso en el examen:** 3.75%
**Fuente de referencia:** [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf) · [Kubernetes docs — kubeadm upgrade](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/) · [Version Skew Policy](https://kubernetes.io/releases/version-skew-policy/)

Mantener el cluster actualizado es una de las mitigaciones más efectivas contra vulnerabilidades conocidas: cada release de Kubernetes trae fixes de seguridad, y quedarse atrás en versiones fuera de soporte (más de 3 minor versions) implica correr componentes sin backport de CVEs. Este set de ejercicios asume un cluster armado con `kubeadm` (por ejemplo con `kubeadm-DinD` o VMs), con al menos un control-plane node y un worker node.

---

## Ejercicio 1 — Diagnosticar versiones actuales y version skew

1. Verificá la versión del cliente `kubectl` y de los componentes del cluster:

   ```bash
   kubectl version
   ```

2. Listá los nodos junto con la versión de `kubelet` que corre cada uno:

   ```bash
   kubectl get nodes -o wide
   ```

3. Entrá al control-plane node por SSH y revisá la versión instalada de `kubeadm`, `kubelet` y `kubectl`:

   ```bash
   kubeadm version
   kubelet --version
   kubectl version --client
   dpkg -l | grep -E 'kubeadm|kubelet|kubectl'
   ```

4. Anotá la minor version actual (ej. `1.31.x`) — la vas a necesitar para calcular el próximo paso de upgrade permitido.

**Preguntas de comprensión:**

- ¿Por qué `kube-apiserver` no puede tener una minor version más vieja que la de `kubelet` en ningún nodo del cluster?
- Si el control-plane corre `v1.31`, ¿cuál es la minor version máxima permitida para `kubelet` en un worker según la version skew policy?
- ¿Podés saltar directo de `v1.29` a `v1.31` con `kubeadm upgrade apply` en un solo paso?

---

## Ejercicio 2 — Planificar el upgrade con `kubeadm upgrade plan`

1. En el control-plane node, actualizá el índice de paquetes y consultá qué versiones de `kubeadm` están disponibles en el repo configurado:

   ```bash
   sudo apt-get update
   apt-cache madison kubeadm
   ```

2. Determiná la próxima minor version target (ej. si estás en `1.31.x`, el target es `1.32.x`, nunca saltando una minor).

3. Instalá la nueva versión de `kubeadm` (liberando el `hold` primero) sin tocar todavía `kubelet`/`kubectl`:

   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get install -y kubeadm='1.32.x-*'
   sudo apt-mark hold kubeadm
   ```

4. Corré el dry-run de planificación:

   ```bash
   sudo kubeadm upgrade plan
   ```

5. Leé la salida completa: te muestra la versión actual de cada componente (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, `CoreDNS`, `etcd`) y a qué versión pasarían.

**Preguntas de comprensión:**

- ¿Por qué `kubeadm upgrade plan` se corre solo en un control-plane node y no en los workers?
- ¿Qué diferencia hay entre actualizar el paquete `kubeadm` y ejecutar `kubeadm upgrade apply`?
- Si `kubeadm upgrade plan` reporta que `etcd` va a pasar de versión, ¿quién gestiona ese upgrade — vos manualmente o `kubeadm`?

---

## Ejercicio 3 — Upgrade del primer control-plane node

1. Desde una máquina con acceso admin al cluster, marcá el nodo como no programable y drenalo (esto expulsa los pods, respetando PodDisruptionBudgets):

   ```bash
   kubectl drain <cp-node-name> --ignore-daemonsets
   ```

2. En el control-plane node, aplicá el upgrade (usa la versión de `kubeadm` ya instalada en el Ejercicio 2):

   ```bash
   sudo kubeadm upgrade apply v1.32.x
   ```

3. Confirmá cuando te pida el `y/N` y esperá a que termine — actualiza los manifests estáticos de `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` y la config de `kubelet`.

4. Actualizá `kubelet` y `kubectl` en ese mismo nodo:

   ```bash
   sudo apt-mark unhold kubelet kubectl
   sudo apt-get install -y kubelet='1.32.x-*' kubectl='1.32.x-*'
   sudo apt-mark hold kubelet kubectl
   ```

5. Recargá el daemon de systemd y reiniciá `kubelet`:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

6. Devolvé el nodo al pool de scheduling:

   ```bash
   kubectl uncordon <cp-node-name>
   ```

**Preguntas de comprensión:**

- ¿Qué pasaría si reiniciás `kubelet` con la nueva versión **antes** de correr `kubeadm upgrade apply`?
- ¿Por qué es necesario drenar el nodo si igual va a seguir siendo control-plane después del upgrade?
- Un pod sin PodDisruptionBudget que no tolera downtime, ¿qué riesgo corre durante el `drain`?

---

## Ejercicio 4 — Upgrade de control-plane nodes adicionales y worker nodes

1. Si hay más control-plane nodes, en cada uno de ellos (después de instalar la nueva versión de `kubeadm`) corré:

   ```bash
   sudo kubeadm upgrade node
   ```

   (no `upgrade apply`, que solo corre una vez en el primer control-plane node).

2. Para cada worker node, drenalo desde afuera:

   ```bash
   kubectl drain <worker-node-name> --ignore-daemonsets --delete-emptydir-data
   ```

3. En el worker, actualizá `kubeadm` y ejecutá:

   ```bash
   sudo apt-mark unhold kubeadm
   sudo apt-get install -y kubeadm='1.32.x-*'
   sudo apt-mark hold kubeadm
   sudo kubeadm upgrade node
   ```

4. Actualizá `kubelet` en el worker (los workers no necesitan `kubectl`):

   ```bash
   sudo apt-mark unhold kubelet
   sudo apt-get install -y kubelet='1.32.x-*'
   sudo apt-mark hold kubelet
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```

5. Uncordon el worker:

   ```bash
   kubectl uncordon <worker-node-name>
   ```

6. Repetí para el resto de los workers, **uno a la vez**, nunca en paralelo.

**Preguntas de comprensión:**

- ¿Por qué `kubeadm upgrade node` se usa en workers y control-plane nodes adicionales, mientras que `kubeadm upgrade apply` solo corre una vez?
- ¿Qué consecuencia tiene actualizar todos los workers en paralelo en un cluster con pocas replicas por Deployment?
- ¿Qué hace la flag `--delete-emptydir-data` y cuándo la necesitás?

---

## Ejercicio 5 — Verificación post-upgrade y detección de riesgos de seguridad

1. Confirmá que todos los nodos están en la nueva versión y en estado `Ready`:

   ```bash
   kubectl get nodes -o wide
   ```

2. Verificá que los pods del control-plane (si corren como static pods) están sanos:

   ```bash
   kubectl get pods -n kube-system
   ```

3. Revisá si tu manifests usan alguna API version que quedó deprecada o removida en la nueva minor version (esto es crítico: un upgrade puede romper workloads que usan APIs eliminadas):

   ```bash
   kubectl api-resources
   kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
   ```

4. Repasá el [Kubernetes CHANGELOG](https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG) de la versión a la que subiste, buscando específicamente entradas de seguridad (CVE fixes).

5. Chequeá que la minor version del cluster sigue dentro de la ventana soportada (las 3 minor versions más recientes, según la [política de soporte](https://kubernetes.io/releases/patch-releases/#support-period)).

**Preguntas de comprensión:**

- ¿Por qué revisar `apiserver_requested_deprecated_apis` **antes** del upgrade (y no solo después) es una práctica recomendada?
- Si tu cluster está en `v1.28` y la última estable es `v1.32`, ¿está dentro de la ventana de soporte oficial?
- ¿Qué diferencia hay, desde la óptica de seguridad, entre un upgrade de **patch version** (`v1.32.1` → `v1.32.3`) y uno de **minor version** (`v1.31` → `v1.32`)?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**

- Porque `kube-apiserver` debe poder entender y validar los recursos que reportan y consumen todos los `kubelet`s del cluster. Si un `kubelet` fuera más nuevo que el `apiserver`, podría usar features o formatos que el `apiserver` no reconoce. La policy exige `kubelet` ≤ `kube-apiserver`.
- `kubelet` puede estar hasta 3 minor versions por detrás del `kube-apiserver` (según la política vigente de N-3), es decir, entre `v1.29` y `v1.31` en este ejemplo — nunca por delante.
- No. `kubeadm upgrade apply` no soporta saltar minor versions: hay que pasar por cada minor version intermedia en orden (`1.29` → `1.30` → `1.31`).

**Ejercicio 2**

- Porque el estado del cluster (versión de cada componente, salud de `etcd`, config de `kubeadm-config` ConfigMap) es información centralizada del control-plane; correrlo en un worker no tiene sentido porque los workers no alojan esos componentes.
- Actualizar el paquete `kubeadm` solo reemplaza el binario de la herramienta en el nodo (no cambia nada del cluster corriendo). `kubeadm upgrade apply` es el comando que efectivamente reconfigura y reinicia los componentes del control-plane a la nueva versión.
- `kubeadm` gestiona automáticamente el upgrade de `etcd` como parte de `kubeadm upgrade apply` (o `upgrade node`), no requiere intervención manual del operador salvo en configuraciones no estándar (etcd externo).

**Ejercicio 3**

- El `kubelet` nuevo podría no poder comunicarse correctamente con el `kube-apiserver` viejo, o quedar en un estado de version skew inválido temporalmente, además de que `kubeadm upgrade apply` es quien genera la nueva config estática que `kubelet` necesita leer.
- Aunque el nodo siga siendo control-plane, durante el upgrade los static pods (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`) y potencialmente `kubelet` se reinician, lo que puede interrumpir workloads schedulados ahí; drenar evita downtime de aplicaciones de usuario en ese nodo.
- Puede sufrir un `Evicted` sin garantía de disponibilidad continua durante el drain, ya que sin PDB no hay ninguna restricción que limite cuántas replicas se puedan desalojar a la vez.

**Ejercicio 4**

- `kubeadm upgrade apply` hace el trabajo "pesado" de actualizar la configuración del cluster una sola vez (cambia el `ClusterConfiguration` almacenado); los demás nodos solo necesitan aplicar esos cambios localmente a su propia config de `kubelet`/componentes, que es lo que hace `upgrade node`.
- Riesgo de indisponibilidad total o parcial del servicio: si todos los workers están drenados/reiniciando `kubelet` al mismo tiempo, no queda capacidad para reprogramar pods, causando downtime real para la aplicación.
- Borra los datos de volúmenes `emptyDir` antes de desalojar los pods del nodo; se necesita cuando no querés dejar esos datos residuales en el nodo (relevante en local storage, no en la mayoría de los casos con backends remotos).

**Ejercicio 5**

- Porque detectar el uso de APIs deprecadas antes del upgrade te permite migrar los manifests con tiempo, evitando que el upgrade rompa workloads en producción apenas se aplique (algunas APIs se remueven, no solo se deprecan, entre minors).
- No. La ventana de soporte oficial cubre las 3 minor versions más recientes (`v1.30`, `v1.31`, `v1.32` en este ejemplo); `v1.28` queda fuera de soporte y sin backport de parches de seguridad, siendo un riesgo de compliance para CKS.
- Un upgrade de patch version solo trae bugfixes y CVE fixes sin cambios de API ni de comportamiento, de bajo riesgo y aplicable rápido. Un upgrade de minor version puede incluir deprecations, cambios de defaults y remociones de API, por lo que requiere planificación y testing previo — pero es indispensable para no quedar fuera de la ventana de soporte de seguridad.

</details>