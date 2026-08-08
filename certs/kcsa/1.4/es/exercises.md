# Preparación para el Examen CNCF KCSA: Tema 1.4 – Técnicas de Aislamiento

**Dominio:** Kubernetes & Cloud Native Security Associate (KCSA)  
**Peso del Examen:** ~2.33%  
**Audiencia Objetivo:** Arquitectos Principales de Plataforma, SREs Líderes, Ingenieros de Seguridad  

---

## Referencias Oficiales
* **Documentación de Kubernetes – Restringiendo Syscalls con Seccomp:** [https://kubernetes.io/docs/tutorials/security/seccomp/](https://kubernetes.io/docs/tutorials/security/seccomp/)
* **Documentación de Kubernetes – Asegurando un Pod con AppArmor:** [https://kubernetes.io/docs/tutorials/security/apparmor/](https://kubernetes.io/docs/tutorials/security/apparmor/)
* **Documentación de Kubernetes – Aislamiento de Contenedores y RuntimeClass:** [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
* **Documentación de Kubernetes – Network Policies:** [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* **CNCF Cloud Native Security Whitepaper (Aislamiento y Multitenencia):** [https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper.md)
* **Documentación del Kernel de Linux – Control Groups v2:** [https://www.kernel.org/doc/Documentation/cgroup-v2.txt](https://www.kernel.org/doc/Documentation/cgroup-v2.txt)

---

## Visión General Técnica y Mecánica Profunda

El aislamiento en Kubernetes opera bajo un modelo de defensa en profundidad a través de cuatro límites distintos:

```
+-------------------------------------------------------------------------+
|                              NODE BOUNDARY                              |
|  Node Isolation: Taints, Tolerations, NodeAffinity, Topology Constraints|
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  |                         NETWORK BOUNDARY                          |  |
|  |  Network Policies: Ingress/Egress Isolation (CNI / eBPF / iptables) |  |
|  |                                                                   |  |
|  |  +-------------------------------------------------------------+  |  |
|  |  |                      RUNTIME BOUNDARY                       |  |  |
|  |  |  RuntimeClass: gVisor (runsc) / Kata MicroVMs / runc        |  |  |
|  |  |                                                             |  |  |
|  |  |  +-------------------------------------------------------+  |  |  |
|  |  |  |                  KERNEL / OS BOUNDARY                 |  |  |  |
|  |  |  |  Namespaces, cgroups v2, Seccomp, AppArmor, Capabilities|  |  |  |
|  |  |  +-------------------------------------------------------+  |  |  |
|  |  +-------------------------------------------------------------+  |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

1. **Límite de Kernel y SO:** Los contenedores tradicionales comparten el kernel del host. Las primitivas del kernel de Linux—`namespaces` (pid, net, ipc, mnt, uts, user, cgroup), `cgroups v2` (aplicación de recursos), `Seccomp` (filtrado de syscalls vía BPF), `AppArmor/SELinux` (Control de Acceso Obligatorio), y `Capabilities` (división de los poderes del superusuario `root`)—previenen la contaminación cruzada de procesos y las interacciones no autorizadas con el host.
2. **Límite de Runtime:** Los runtimes estándar (`runc`) utilizan primitivas nativas de Linux en el host, exponiendo una gran superficie de ataque en el kernel del host (~350+ llamadas al sistema). Los runtimes en aislamiento (sandboxed) mitigan la exposición del kernel del host interceptando las llamadas al sistema en el espacio de usuario (`gVisor` a través de `runsc`) o ejecutando cada Pod dentro de una máquina virtual aislada asistida por hardware (`Kata Containers` usando Firecracker/QEMU).
3. **Límite de Red:** Por defecto, la red plana de Kubernetes permite la comunicación sin restricciones de Pod a Pod a través de los namespaces. Las `NetworkPolicies` aíslan el tráfico en la Capa 3/4 (y Capa 7 cuando se usa eBPF/service meshes), aplicadas en el plano de datos de CNI (por ejemplo, mapas de eBPF en Cilium o cadenas de iptables en Calico).
4. **Límite de Nodo:** El aislamiento lógico y físico previene el ruido entre múltiples inquilinos (multi-tenant noise) y el movimiento lateral. Las restricciones de programación (scheduling)—`Taints`, `Tolerations`, `NodeAffinity` y `PodAntiAffinity`—garantizan que las cargas de trabajo sensibles sean programadas estrictamente en hardware físico dedicado o en pools de nodos endurecidos (hardened).

---

## Lab 1: Endurecimiento de la Interfaz del Kernel (Seccomp, Capabilities y AppArmor)

### Objetivo
Configurar un entorno de ejecución de confianza cero (zero-trust) para un contenedor eliminando Linux capabilities, aplicando un perfil Seccomp personalizado en localhost, imponiendo AppArmor y ejecutando con un sistema de archivos raíz de solo lectura.

### Pasos Guiados

1. **Paso 1.1:** Inicie sesión en el sistema host del nodo worker de Kubernetes y cree un archivo de perfil Seccomp personalizado en el sistema de archivos del host bajo la ruta predeterminada de seccomp del Kubelet (`/var/lib/kubelet/seccomp/profiles/strict-block.json`).

```bash
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
cat <<'EOF' | sudo tee /var/lib/kubelet/seccomp/profiles/strict-block.json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "exit",
        "exit_group",
        "futex",
        "write",
        "read",
        "fstat",
        "mmap",
        "mprotect",
        "rt_sigaction",
        "rt_sigprocmask",
        "brk",
        "getpid",
        "getuid",
        "geteuid",
        "getgid",
        "getegid",
        "close",
        "execve",
        "arch_prctl"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF
```

2. **Paso 1.2:** Verifique que AppArmor esté activo en el nodo y compruebe el estado de los perfiles cargados.

```bash
sudo aa-status
```
*Fragmento de Salida Esperada:*
```text
apparmor module is loaded.
64 profiles are loaded.
64 profiles are in enforce mode.
   /usr/bin/man
   cri-containerd.apparmor.d
```

3. **Paso 1.3:** Cree un manifiesto de Deployment completamente endurecido [`hardened-app.yaml`](file:///var/lib/kubelet/seccomp/profiles/hardened-app.yaml) que haga referencia al perfil Seccomp local personalizado, elimine `ALL` las kernel capabilities, habilite `readOnlyRootFilesystem` y aplique el perfil de AppArmor por defecto del runtime (`runtime/default`).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-workload
  namespace: default
  labels:
    app.kubernetes.io/name: hardened-workload
    app.kubernetes.io/part-of: isolation-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hardened-workload
  template:
    metadata:
      labels:
        app: hardened-workload
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-block.json
        appArmorProfile:
          type: RuntimeDefault
      containers:
      - name: workload
        image: ccr.gcr.io/google-containers/pause:3.9
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
```

4. **Paso 1.4:** Aplique el Deployment al cluster.

```bash
kubectl apply -f hardened-app.yaml
```
*Salida Esperada:*
```text
deployment.apps/hardened-workload created
```

5. **Paso 1.5:** Valide la aplicación del perfil de seguridad y el despliegue del Pod a través de `kubectl`.

```bash
POD_NAME=$(kubectl get pods -l app=hardened-workload -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD_NAME" -o jsonpath='{.spec.securityContext}' | jq .
```
*Salida Esperada:*
```json
{
  "appArmorProfile": {
    "type": "RuntimeDefault"
  },
  "fsGroup": 10001,
  "runAsGroup": 10001,
  "runAsNonRoot": true,
  "runAsUser": 10001,
  "seccompProfile": {
    "localhostProfile": "profiles/strict-block.json",
    "type": "Localhost"
  }
}
```

6. **Paso 1.6:** Intente una prueba de ejecución operativa para activar una llamada al sistema bloqueada dentro del Pod endurecido.

```bash
kubectl exec -it "$POD_NAME" -- sh -c "mkdir /tmp/test"
```
*Salida Esperada:*
```text
OCI runtime exec failed: exec failed: container_linux.go:380: starting container process caused: process_linux.go:545: container init caused: Operation not permitted
```

7. **Paso 1.7:** Inspeccione los logs del kernel del sistema en el nodo host para ver violaciones de auditoría de Seccomp.

```bash
sudo dmesg -T | grep -i "audit" | tail -n 5
```
*Fragmento de Salida Esperada:*
```text
[Fri Aug  7 19:30:12 2026] audit: type=1326 audit(1723059012.842:984): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84920 comm="sh" exe="/bin/sh" sig=31 arch=c000003e syscall=83 compat=0 ip=0x7f23a41e97bb code=0x00000000
```
*(Nota: `syscall=83` corresponde a `mkdir` en x86_64).*

---

### Preguntas de Verificación (Lab 1)

1. ¿Qué mecanismo del kernel convierte las definiciones JSON de Seccomp en verificaciones de llamadas al sistema en tiempo de ejecución, y cuál es su impacto en la latencia operativa?
2. Si `allowPrivilegeEscalation` se establece en `true`, ¿cómo afecta esto a un proceso que intenta recuperar capabilities eliminadas utilizando binarios `setuid`?
3. ¿Por qué falla `mkdir` con `Operation not permitted` (o señal 31) en el Paso 1.6: ¿es provocado por `readOnlyRootFilesystem` o por `seccompProfile`? ¿Cómo puede diferenciar la causa exacta utilizando trazas de auditoría de `dmesg`?

---

## Lab 2: Sandboxing de Runtime de Contenedores vía RuntimeClass (gVisor y MicroVMs)

### Visión General Arquitectónica y Mecánica

Los runtimes de contenedores tradicionales (`runc`) actúan como capas delgadas (thin wrappers) alrededor de los namespaces y cgroups del kernel de Linux del host. Si un atacante aprovecha un fallo de escalada de privilegios en el kernel compartido del host (por ejemplo, Dirty COW, Dirty Pipe), los límites del contenedor colapsan.

Los runtimes en aislamiento (sandboxed runtimes) eliminan la exposición al kernel compartido:
* **gVisor (`runsc`):** Implementa un kernel en espacio de usuario (el **Sentry**) que intercepta las llamadas al sistema del contenedor a través de `ptrace` o `KVM`. Las operaciones de archivos se procesan a través de un proceso aislado independiente (el **Gofer**). El contenedor nunca interactúa directamente con las llamadas al sistema del kernel del host.
* **Kata Containers (`kata-runtime`):** Genera una máquina virtual dedicada y ligera (usando Firecracker o QEMU) por cada Pod. El Pod se ejecuta dentro de su propio kernel invitado (guest kernel) aislado.

```
       Standard Pod (runc)                      Sandboxed Pod (gVisor / runsc)
+--------------------------------+        +--------------------------------+
|  User Application Process      |        |  User Application Process      |
+--------------------------------+        +--------------------------------+
|  Syscall (e.g. open, socket)   |        |  Syscall (e.g. open, socket)   |
+---------------+----------------+        +---------------+----------------+
                |                                         | Intercepted
                v                                         v
+--------------------------------+        +--------------------------------+
|       Host Linux Kernel        |        |   gVisor Sentry (User Space)   |
+--------------------------------+        +---------------+----------------+
                                                          | Sanitized Syscall
                                                          v
                                          +--------------------------------+
                                          |       Host Linux Kernel        |
                                          +--------------------------------+
```

### Pasos Guiados

1. **Paso 2.1:** Verifique la disponibilidad del runtime de contenedores CRI y los runtime handlers configurados en el nodo worker.

```bash
sudo crictl info | jq '.config.containerd.runtimes'
```
*Fragmento de Salida Esperada:*
```json
{
  "gvisor": {
    "runtimeType": "io.containerd.runsc.v1",
    "options": null
  },
  "runc": {
    "runtimeType": "io.containerd.runc.v2",
    "options": null
  }
}
```

2. **Paso 2.2:** Cree un recurso `RuntimeClass` con alcance de cluster llamado `gvisor` mapeado al handler CRI `gvisor`.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
overhead:
  podFixed:
    cpu: "100m"
    memory: "64Mi"
scheduling:
  nodeSelector:
    sandbox-enabled: "true"
EOF
```
*Salida Esperada:*
```text
runtimeclass.node.k8s.io/gvisor created
```

3. **Paso 2.3:** Etiquete el nodo objetivo para cumplir con el requisito de programación (scheduling) de la `RuntimeClass`.

```bash
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label node "$NODE_NAME" sandbox-enabled=true --overwrite
```

4. **Paso 2.4:** Despliegue una carga de trabajo utilizando la RuntimeClass `gvisor`.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-sandboxed-pod
  namespace: default
spec:
  runtimeClassName: gvisor
  containers:
  - name: untrusted-app
    image: alpine:3.18
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
EOF
```
*Salida Esperada:*
```text
pod/gvisor-sandboxed-pod created
```

5. **Paso 2.5:** Inspeccione la identidad del kernel dentro del host estándar vs dentro del Pod aislado (sandboxed) para confirmar el aislamiento del kernel.

```bash
# Check host kernel version
uname -a

# Check kernel version reported inside gVisor sandbox
kubectl exec gvisor-sandboxed-pod -- uname -a
```
*Salida Esperada (gVisor interno vs Host):*
```text
Linux gvisor-sandboxed-pod 4.4.0-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 Linux
```
*(Observe que gVisor emula una interfaz de versión específica de Linux independientemente de la versión del kernel del host).*

6. **Paso 2.6:** Ejecute `dmesg` dentro del Pod aislado (sandboxed).

```bash
kubectl exec gvisor-sandboxed-pod -- dmesg
```
*Salida Esperada:*
```text
[  0.000000] Starting gVisor...
[  0.342100] Producing safe virtualized system calls...
```

7. **Paso 2.7:** Rastree el árbol de procesos del host para inspeccionar los límites del shim y del sandbox usando `crictl` y `ps`.

```bash
POD_ID=$(sudo crictl pods --name gvisor-sandboxed-pod -q)
sudo crictl inspectp "$POD_ID" | jq '.status.info.pid'
```
*Salida Esperada:*
```text
124532
```

```bash
ps aux | grep 124532
```
*Fragmento de Salida Esperada:*
```text
root      124532  0.8  0.4 1245028 34200 ?       Ssl  19:35   0:00 runsc-sandbox --root /run/containerd/runsc/k8s.io ...
```

---

### Preguntas de Verificación (Lab 2)

1. ¿Cuál es la compensación de rendimiento (latencia y huella de memoria) al usar `gVisor` (`runsc`) en comparación con el `runc` estándar para cargas de trabajo con uso intensivo de E/S (I/O)?
2. ¿Qué rol desempeña el campo `overhead` en un objeto `RuntimeClass` durante el cálculo de cuotas de recursos del pod y la programación (scheduling)?
3. ¿En qué se diferencia `Kata Containers` de `gVisor` en su enfoque de virtualización por hardware e intercepción de syscalls?

---

## Lab 3: Aislamiento de Red Multitenant y Aplicación de Egress

### Visión General Arquitectónica y Mecánica

La red de Kubernetes opera como un modelo de red plana sin aislamiento. Cualquier Pod puede enrutar paquetes a cualquier otra IP de Pod o IP de Service en todo el cluster. 

Las `NetworkPolicies` introducen reglas de firewall con estado aplicadas en la Capa 3/4 por el plugin CNI (Container Network Interface):
* **Default-Deny All Ingress & Egress:** Postura de seguridad base de confianza cero (zero-trust). Bloquea todas las conexiones entrantes y salientes por defecto.
* **Selective Ingress Allow:** Permite tráfico entrante explícito según `podSelector`, `namespaceSelector` o `ipBlock`.
* **Selective Egress Allow:** Previene la exfiltración de datos al restringir las conexiones salientes exclusivamente a microservicios internos autorizados y endpoints externos (por ejemplo, el puerto DNS 53).

```
[ Namespace: tenant-alpha ]                   [ Namespace: tenant-beta ]
+-------------------------+                   +------------------------+
|  Pod: frontend          |                   |  Pod: database         |
|  label: app=frontend    |                   |  label: app=postgres   |
+------------+------------+                   +-----------^------------+
             |                                            |
             |  Egress Request (Port 5432)                |
             +=================== X ======================+
                       BLOCKED BY DEFAULT-DENY
                       
  (Requires explicitly paired Namespace + Pod Selector Egress/Ingress Policy)
```

### Pasos Guiados

1. **Paso 3.1:** Cree namespaces aislados que representen dominios multitenant: `tenant-alpha` y `tenant-beta`.

```bash
kubectl create namespace tenant-alpha
kubectl create namespace tenant-beta
kubectl label namespace tenant-alpha tenant=alpha
kubectl label namespace tenant-beta tenant=beta
```

2. **Paso 3.2:** Despliegue cargas de trabajo de frontend web en `tenant-alpha` y cargas de trabajo de base de datos en `tenant-beta`.

```bash
# Deploy caller application in tenant-alpha
kubectl run client-app --namespace tenant-alpha --image=alpine:3.18 --labels=app=client -- sleep 3600

# Deploy target database application in tenant-beta
kubectl run db-service --namespace tenant-beta --image=nginx:1.25-alpine --labels=app=database --port=80
kubectl expose pod db-service --namespace tenant-beta --port=80
```

3. **Paso 3.3:** Pruebe la conectividad sin restricciones antes de aplicar las NetworkPolicies.

```bash
DB_IP=$(kubectl get pod db-service -n tenant-beta -o jsonpath='{.status.podIP}')
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://$DB_IP" | head -n 3
```
*Salida Esperada:*
```html
<!DOCTYPE html>
<html>
<head>
```

4. **Paso 3.4:** Aplique una **Política de Default-Deny Ingress y Egress** estricta a ambos namespaces.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-alpha
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-beta
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```
*Salida Esperada:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/default-deny-all created
```

5. **Paso 3.5:** Verifique que la conectividad esté ahora completamente bloqueada.

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://$DB_IP"
```
*Salida Esperada:*
```text
wget: download timed out
```

6. **Paso 3.6:** Cree listas de observación permitidas (allowlists) de reglas explícitas:
   - Permitir egress de `tenant-alpha/client-app` hacia kube-dns (puerto 53 UDP/TCP) y egress hacia `tenant-beta/db-service` en el puerto 80.
   - Permitir ingress en `tenant-beta/db-service` desde pods de `tenant-alpha` que coincidan con `app=client`.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-egress
  namespace: tenant-alpha
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
  - Egress
  egress:
  # Allow DNS resolution
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow specific connection to tenant-beta database pods
  - to:
    - namespaceSelector:
        matchLabels:
          tenant: beta
      podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-ingress
  namespace: tenant-beta
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          tenant: alpha
      podSelector:
        matchLabels:
          app: client
    ports:
    - protocol: TCP
      port: 80
EOF
```
*Salida Esperada:*
```text
networkpolicy.networking.k8s.io/allow-client-egress created
networkpolicy.networking.k8s.io/allow-db-ingress created
```

7. **Paso 3.7:** Pruebe la conectividad entre namespaces para confirmar el acceso exitoso.

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=3 "http://db-service.tenant-beta.svc.cluster.local" | head -n 3
```
*Salida Esperada:*
```html
<!DOCTYPE html>
<html>
<head>
```

8. **Paso 3.8:** Confirme la protección contra exfiltración intentando una conexión desde `client-app` a un destino IP no autorizado (por ejemplo, `1.1.1.1`).

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://1.1.1.1"
```
*Salida Esperada:*
```text
wget: download timed out
```

---

### Preguntas de Verificación (Lab 3)

1. ¿Qué sucede si una NetworkPolicy especifica un `podSelector` que coincide con un Pod, pero el arreglo `ingress` está vacío (`ingress: []`) vs omitido por completo?
2. ¿Cómo se evalúan `namespaceSelector` y `podSelector` cuando se definen en elementos de arreglo separados bajo `from:` en comparación con cuando se combinan dentro del mismo elemento de arreglo?
3. Si un plugin CNI subyacente (por ejemplo, Flannel) no es compatible con NetworkPolicies, ¿qué sucede cuando se aplica un objeto `NetworkPolicy` en Kubernetes?

---

## Lab 4: Aislamiento Físico y a Nivel de Nodo (Taints, Tolerations y NodeAffinity)

### Visión General Arquitectónica y Mecánica

La multitenencia estricta (hard multi-tenancy) requiere un aislamiento riguroso a nivel de nodo de cómputo físico para eliminar ataques de canal lateral (por ejemplo, Spectre, Meltdown), la contención de caché de CPU y el agotamiento de recursos del kernel.

Kubernetes aplica el aislamiento de ubicación de nodos a través de dos pares de primitivas complementarias:
1. **Taints & Tolerations (Repulsión):** Los taints aplicados a los nodos repelen a los Pods. Un Pod no puede ser programado en un nodo con taint a menos que tenga una `toleration` explícita que coincida.
2. **NodeAffinity & NodeSelector (Atracción):** Atrae explícitamente a los Pods hacia nodos designados basándose en las etiquetas (labels) del nodo.

Para garantizar un aislamiento multitenant dedicado, **ambas primitivas deben combinarse simultáneamente**:
* Taint node -> Previene que pods no autorizados lleguen al nodo dedicado.
* NodeAffinity -> Asegura que los pods dedicados lleguen *únicamente* al nodo dedicado y a ningún otro lugar.

```
                  [ Node: worker-pci-1 ]                    [ Node: worker-general-1 ]
                  Taint: tier=pci:NoSchedule                No Taints
                  Label: tier=pci
                          |                                             |
     +--------------------+--------------------+                        |
     |                                         |                        |
     v                                         v                        v
[ Pod: Payment-Service ]              [ Pod: General-App ]     [ Pod: General-App ]
- Toleration: tier=pci:NoSchedule     - No Tolerations         - No Tolerations
- NodeAffinity: tier=pci                |                        |
     |                                  +=========== X ==========+
     +---> SCHEDULED SUCCESSFULLY                   REPELLED BY TAINT
```

### Pasos Guiados

1. **Paso 4.1:** Identifique un nodo y aplique un taint restrictivo designándolo para cargas de trabajo de alta seguridad en cumplimiento con PCI-DSS.

```bash
TARGET_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "$TARGET_NODE" tier=pci:NoSchedule --overwrite
kubectl label nodes "$TARGET_NODE" tier=pci --overwrite
```
*Salida Esperada:*
```text
node/worker-1 tainted
node/worker-1 labeled
```

2. **Paso 4.2:** Intente desplegar una aplicación estándar sin privilegios y sin tolerations.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: standard-untrusted-pod
  namespace: default
spec:
  containers:
  - name: web
    image: nginx:alpine
EOF
```

3. **Paso 4.3:** Inspeccione el estado de programación (scheduling) del Pod.

```bash
kubectl get pod standard-untrusted-pod
```
*Salida Esperada:*
```text
NAME                     READY   STATUS    RESTARTS   AGE
standard-untrusted-pod   0/1     Pending   0          12s
```

```bash
kubectl describe pod standard-untrusted-pod | grep -A 3 "Events:"
```
*Fragmento de Salida Esperada:*
```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  20s   default-scheduler  0/1 nodes are available: 1 node(s) had untolerated taint {tier: pci}. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
```

4. **Paso 4.4:** Construya un manifiesto de Pod de producción aislado usando **Tolerations** explícitas Y **nodeAffinity** para vincularse de forma segura al pool de nodos PCI.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secure-pci-payment-pod
  namespace: default
  labels:
    app.kubernetes.io/name: payment-processor
    security.domain: pci-dss
spec:
  tolerations:
  - key: "tier"
    operator: "Equal"
    value: "pci"
    effect: "NoSchedule"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - pci
  containers:
  - name: payment-app
    image: nginx:alpine
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
```
*Salida Esperada:*
```text
pod/secure-pci-payment-pod created
```

5. **Paso 4.5:** Valide que `secure-pci-payment-pod` esté programado y ejecutándose en el nodo con taint.

```bash
kubectl get pod secure-pci-payment-pod -o wide
```
*Fragmento de Salida Esperada:*
```text
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE
secure-pci-payment-pod   1/1     Running   0          8s    10.244.0.9   worker-1
```

6. **Paso 4.6:** Limpie los pods de prueba y elimine el taint del nodo.

```bash
kubectl delete pod standard-untrusted-pod secure-pci-payment-pod --ignore-not-found
kubectl taint nodes "$TARGET_NODE" tier=pci:NoSchedule-
```

---

### Preguntas de Verificación (Lab 4)

1. ¿Cuál es la diferencia operativa entre los efectos de Taint `NoSchedule`, `PreferNoSchedule` y `NoExecute`?
2. Si un nodo recibe un taint con `NoExecute`, ¿qué les sucede inmediatamente a los Pods existentes ejecutándose en ese nodo que carecen de una toleration correspondiente?
3. ¿Por qué agregar únicamente una `Toleration` no logra garantizar un aislamiento multitenant estricto en un cluster de múltiples nodos?

---

<details>
<summary><strong>Haga clic para expandir: Respuestas y Explicaciones Detalladas</strong></summary>

### Respuestas del Lab 1

1. **Mecanismo del Kernel y Latencia:**
   * **Mecanismo:** Seccomp utiliza **eBPF (Extended Berkeley Packet Filters)** del kernel de Linux a través de `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)` para evaluar las llamadas al sistema contra las reglas de bytecode BPF cargadas en la capa de entrada de llamadas al sistema (`entry_SYSCALL_64`).
   * **Impacto en la Latencia:** Evaluar perfiles de Seccomp agrega un sobrecosto (overhead) mínimo (unos pocos nanosegundos por ejecución de syscall). Sin embargo, los perfiles no optimizados con listas lineales extensas de syscalls pueden introducir sobrecosto durante operaciones con un uso intensivo de llamadas al sistema. Utilizar las acciones por defecto `SCMP_ACT_ERRNO` o `SCMP_ACT_KILL_PROCESS` combinadas con listas de observados permitidos (allowlists) mínimas minimiza las rutas de evaluación de BPF.

2. **Escalada de Privilegios y Capabilities:**
   * Establecer `allowPrivilegeEscalation: false` configura el bit `no_new_privs` en el proceso a través de `prctl(PR_SET_NO_NEW_PRIVS)`.
   * Incluso si un binario dentro del contenedor tiene activados los bits `setuid` (por ejemplo, `/bin/su`, `/usr/bin/sudo`) o capabilities de archivo adjuntas, el kernel se niega a otorgar privilegios elevados o devolver capabilities que fueron eliminadas en la jerarquía del proceso padre.

3. **Diagnóstico del Fallo de `mkdir`:**
   * El fallo en el Paso 1.6 fue provocado por **Seccomp** (`strict-block.json`), no por `readOnlyRootFilesystem`.
   * **Diferenciación:**
     * El error de `readOnlyRootFilesystem` devuelve `Read-only file system` (Errno 30 / `EROFS`).
     * La acción por defecto de Seccomp `SCMP_ACT_ERRNO` (o la ausencia de `mkdir` / syscall 83 en la allowlist de syscalls) devuelve `Operation not permitted` (Errno 1 / `EPERM`).
     * Los logs de `dmesg` confirman explícitamente la acción del filtro de Seccomp: `type=1326 audit(...) ... comm="sh" ... sig=31 ... syscall=83`, donde `sig=31` (SIGSYS) o el código de auditoría indica una violación de Seccomp.

---

### Respuestas del Lab 2

1. **Compensaciones de Rendimiento de gVisor:**
   * **Sobrecosto (Overhead):** Las cargas de trabajo con alto uso intensivo de E/S (I/O) (por ejemplo, acceso pesado a archivos, procesamiento rápido de paquetes de red) sufren penalizaciones de rendimiento de CPU (sobrecosto del 10% al 30%) porque las llamadas al sistema deben ser interceptadas por el Sentry en espacio de usuario y traducidas a través de cambios de contexto entre Sentry, Gofer y el kernel del host.
   * **Beneficio:** Proporciona un tiempo de inicio extremadamente rápido (a escala de milisegundos) en comparación con el aislamiento basado en VM, exponiendo cero superficie de syscalls del kernel del host al código de contenedor no confiable.

2. **Campo Overhead de `RuntimeClass`:**
   * El campo `overhead` contabiliza los recursos fijos de memoria y CPU consumidos por la propia infraestructura de sandboxing (por ejemplo, la memoria del proceso Sentry de gVisor o el sobrecosto de VMM/kernel de Kata MicroVM).
   * El scheduler de Kubernetes **suma** el `overhead` especificado a las `requests` y `limits` de recursos del Pod al evaluar la capacidad del nodo y aplicar cuotas de recursos dentro de los Namespaces.

3. **Arquitectura de gVisor vs Kata Containers:**
   * **gVisor (`runsc`):** Emula las interfaces del kernel de Linux completamente en el espacio de usuario (escrito en Go). Se ejecuta en el mismo entorno de SO del host pero intercepta las llamadas al sistema.
   * **Kata Containers (`kata-runtime`):** Utiliza extensiones de virtualización asistidas por hardware (Intel VT-x / AMD-V a través de KVM) para arrancar un kernel invitado de Linux dedicado dentro de una microVM ligera por Pod. Las llamadas al sistema se ejecutan de forma nativa dentro del kernel invitado sin intercepción en espacio de usuario.

---

### Respuestas del Lab 3

1. **Semántica de `podSelector` y del Arreglo Ingress:**
   * Si `podSelector: {}` coincide con un Pod, y se declara `policyTypes: ["Ingress"]`:
     * `ingress: []` (arreglo vacío): **Default-Deny Ingress**. Bloquea TODO el tráfico entrante a los pods que coincidan.
     * Clave `ingress` omitida por completo: Permite TODO el tráfico entrante (sin restricciones de ingress activas).

2. **Mecánica de los Arreglos Namespace vs Pod Selector:**
   * **Elementos de Arreglo Separados (OR Lógico):**
     ```yaml
     ingress:
     - from:
       - namespaceSelector:
           matchLabels: { tenant: alpha }
       - podSelector:
           matchLabels: { role: admin }
     ```
     *Permite el tráfico desde CUALQUIER pod en namespaces etiquetados como `tenant=alpha` O CUALQUIER pod etiquetado como `role=admin` en el namespace local de la política.*

   * **Mismo Elemento de Arreglo (AND Lógico):**
     ```yaml
     ingress:
     - from:
       - namespaceSelector:
           matchLabels: { tenant: alpha }
         podSelector:
           matchLabels: { role: admin }
     ```
     *Permite el tráfico ÚNICAMENTE desde pods etiquetados como `role=admin` QUE ADEMÁS residan dentro de namespaces etiquetados como `tenant=alpha`.*

3. **Plugins CNI sin Soporte para NetworkPolicy:**
   * Kubernetes acepta con éxito los objetos de la API `NetworkPolicy` y los almacena en `etcd`.
   * Sin embargo, debido a que los plugins como Flannel estándar carecen de un motor de filtrado en el plano de datos (por ejemplo, controladores iptables/eBPF), **las políticas se ignoran por completo** y todo el tráfico de red de pod a pod permanece completamente sin aislamiento.

---

### Respuestas del Lab 4

1. **Diferencias entre los Efectos de Taint:**
   * `NoSchedule`: Previene que nuevos pods sin una toleration coincidente sean programados en el nodo. Los pods en ejecución existentes no se ven afectados.
   * `PreferNoSchedule`: Restricción suave (soft constraint). El scheduler intenta evitar colocar pods sin tolerations coincidentes en el nodo, pero los colocará si no hay otra capacidad de cómputo disponible.
   * `NoExecute`: Previene la programación de nuevos pods Y **expulsa (evicts)** inmediatamente los pods en ejecución existentes en el nodo que carezcan de tolerations coincidentes.

2. **Aplicar `NoExecute` a un Nodo:**
   * Cualquier Pod en ejecución en ese nodo que carezca de una `toleration` coincidente es finalizado inmediatamente (se le envía `SIGTERM` y luego `SIGKILL`).
   * Los Pods con tolerations coincidentes permanecen en ejecución. Si una toleration define `tolerationSeconds`, el pod permanece en ejecución en el nodo durante esa duración especificada antes de la expulsión.

3. **Por qué las Tolerations por sí Solas Fallan en la Multitenencia:**
   * Una `Toleration` le otorga a un Pod el **permiso** de llegar a un nodo con taint, pero NO fuerza al Pod a llegar a ese nodo.
   * Sin una `NodeAffinity` o `NodeSelector` coincidente, el scheduler de Kubernetes puede colocar libremente el pod en cualquier nodo normal sin taint en el cluster, rompiendo los requisitos de aislamiento de las cargas de trabajo.

</details>