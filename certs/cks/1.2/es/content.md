# 1.2 Usar CIS Benchmark para revisar la configuración de seguridad de los componentes de Kubernetes (etcd, kubelet, kubedns, kubeapi)

## Por qué importa este tema

Un clúster de Kubernetes por defecto es *funcional*, no *endurecido*. `kubeadm` toma decisiones razonables, pero las distribuciones, los proveedores cloud y los instaladores hechos a mano difieren entre sí, y muchos de ellos dejan defaults peligrosos en su lugar: un kubelet alcanzable de forma anónima, un puerto de peers de etcd sin autenticar, endpoints de profiling expuestos en el API server, material PKI legible por todo el mundo.

El **CIS Kubernetes Benchmark** (Center for Internet Security) es la checklist estándar de la industria que te dice, control por control, qué significa "endurecido" para cada componente. En el examen CKS no se te pide memorizar el benchmark — se te pide **ejecutarlo, leer su salida y arreglar lo que marca**, normalmente con `kube-bench`.

---

## 1. Qué es el CIS Kubernetes Benchmark

El benchmark es un PDF/planilla versionado publicado por CIS, desarrollado por una comunidad de profesionales. Está **versionado de forma independiente de Kubernetes**: CIS Kubernetes Benchmark v1.9, v1.10, v1.11… cada uno apunta a un rango de releases de Kubernetes. Hay benchmarks separados para distribuciones gestionadas (EKS, GKE, AKS, OpenShift, RKE), porque en esas no podés ver ni editar el control plane.

### Estructura

Cada control tiene:

| Campo | Significado |
|---|---|
| **ID** | Número jerárquico, p. ej. `1.2.15` |
| **Título** | p. ej. *Ensure that the `--profiling` argument is set to `false`* |
| **Assessment** | **Automated** (una herramienta puede verificarlo) o **Manual** (un humano debe juzgarlo) |
| **Profile Level** | **Level 1** = práctico, bajo impacto operativo. **Level 2** = defensa en profundidad, puede romper cosas |
| **Audit** | El comando que prueba el cumplimiento |
| **Remediation** | El cambio exacto a realizar |
| **Impact** | Qué se rompe si lo aplicás |

### Secciones

```
1  Control Plane Components
   1.1  Control Plane Node Configuration Files   (file permissions & ownership)
   1.2  API Server                               (kube-apiserver flags)
   1.3  Controller Manager
   1.4  Scheduler
2  etcd                                          (etcd TLS & peer auth)
3  Control Plane Configuration
   3.1  Authentication and Authorization
   3.2  Logging                                  (audit policy)
4  Worker Nodes
   4.1  Worker Node Configuration Files
   4.2  Kubelet
5  Policies
   5.1  RBAC and Service Accounts
   5.2  Pod Security Standards
   5.3  Network Policies and CNI
   5.4  Secrets Management
   5.5  Extensible Admission Control
   5.7  General Policies
```

> **Advertencia crítica para el examen:** la *numeración cambia entre revisiones del benchmark*. `--protect-kernel-defaults` puede ser `4.2.6` en una release y `4.2.7` en otra. **Nunca confíes en un ID que memorizaste — leé el ID de tu propia salida de `kube-bench`.**

---

## 2. kube-bench: la herramienta que automatiza el benchmark

`kube-bench` (Aqua Security, Go, Apache-2.0) implementa los controles Automated como archivos de reglas YAML y los ejecuta contra el nodo en el que está corriendo.

### 2.1 Ejecutarlo

**A. Como contenedor en un nodo del control plane (lo más común en el examen):**

```bash
docker run --rm --pid=host \
  -v /etc:/etc:ro \
  -v /var:/var:ro \
  -t docker.io/aquasec/kube-bench:latest \
  run --targets=master
```

**B. Como un Job dentro del clúster:**

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs -f job/kube-bench
```

El repositorio upstream también incluye `job-master.yaml` y `job-node.yaml`, que fijan el pod a un nodo del control plane o a un worker respectivamente. Todos ellos necesitan `hostPID: true` (para inspeccionar los procesos en ejecución) y montajes `hostPath` de solo lectura de `/etc` y `/var`.

**C. Como un binario ya instalado en el nodo:**

```bash
kube-bench run --targets master,node,etcd,policies
```

### 2.2 Targets

| Target | Cubre | Ejecutalo en |
|---|---|---|
| `master` | secciones 1 y 3 | nodo del control plane |
| `etcd` | sección 2 | nodo que corre etcd |
| `node` | sección 4 | nodo worker |
| `policies` | sección 5 | cualquier lugar con kubeconfig |
| `controlplane` | sección 3 | nodo del control plane |

Si omitís `--targets`, kube-bench autodetecta qué está corriendo localmente.

### 2.3 Seleccionar la versión del benchmark

```bash
# Let kube-bench auto-detect the cluster version:
kube-bench run --targets master

# Pin explicitly, when auto-detection guesses wrong:
kube-bench run --benchmark cis-1.10 --targets master

# Managed clusters:
kube-bench run --benchmark eks-1.5.0
kube-bench run --benchmark gke-1.6.0

# What does my binary actually ship?
ls /etc/kube-bench/cfg/
# cis-1.8  cis-1.9  cis-1.10  cis-1.11  eks-1.5.0  gke-1.6.0  aks-1.7  rh-1.6 ...
```

Si kube-bench falla con `unable to determine benchmark version`, fijala manualmente — esa es la solución prevista, no un bug.

### 2.4 Flags útiles

```bash
kube-bench run --targets master --check 1.2.15        # one control
kube-bench run --targets master --check 1.2.15,1.2.16 # several
kube-bench run --targets node   --skip 4.2.6          # ignore a control
kube-bench run --targets master --json | jq .          # machine-readable
kube-bench run --targets master --outputfile /tmp/r.txt
kube-bench run --targets master --noremediations       # terse
kube-bench run --targets master --exit-code 1          # non-zero exit if FAIL → CI gate
```

### 2.5 Leer la salida

```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Manual)
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[WARN] 1.2.9 Ensure that the admission control plugin EventRateLimit is set (Manual)
[PASS] 1.2.24 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set

== Remediations master ==
1.2.15 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the below parameter.
--profiling=false

== Summary master ==
44 checks PASS
8 checks FAIL
11 checks WARN
0 checks INFO
```

| Estado | Significado | Qué hacés |
|---|---|---|
| `PASS` | Chequeo automated satisfecho | Nada |
| `FAIL` | Chequeo automated violado | **Arreglalo** — el texto de remediación se imprime debajo |
| `WARN` | Control manual, o un chequeo que kube-bench no pudo evaluar | Leelo y decidí; el examen normalmente solo califica `FAIL` |
| `INFO` | Informativo | Nada |

**Flujo de trabajo en el examen:** ejecutar → anotar los IDs que fallan → aplicar la remediación impresa → volver a ejecutar con `--check <id>` para confirmar `PASS`.

---

## 3. kube-apiserver (sección 1.2)

El API server es la única puerta de entrada al clúster. Todos los flags viven en el manifiesto del static pod:

```
/etc/kubernetes/manifests/kube-apiserver.yaml
```

Editar ese archivo hace que el kubelet reinicie el static pod automáticamente — no hace falta `systemctl`.

### Controles que tenés que poder arreglar a primera vista

| Control | Configuración correcta | Por qué |
|---|---|---|
| `--anonymous-auth` | `false` | De lo contrario las peticiones sin autenticar obtienen la identidad `system:anonymous` |
| `--token-auth-file` | **sin configurar** | Archivo de tokens estático = credenciales en texto plano, no revocables |
| `--authorization-mode` | contiene `Node,RBAC`, nunca `AlwaysAllow` | `AlwaysAllow` deshabilita la autorización por completo |
| `--enable-admission-plugins` | incluye `NodeRestriction`, `ServiceAccount`, `NamespaceLifecycle` | `NodeRestriction` impide que un kubelet comprometido edite otros nodos/pods |
| `--enable-admission-plugins` | **no** incluye `AlwaysAdmit` | Evita todo el control de admisión |
| `--profiling` | `false` | `/debug/pprof` filtra detalle del sistema y es un vector de DoS |
| `--audit-log-path` | configurado (p. ej. `/var/log/kubernetes/audit.log`) | Sin log de auditoría no hay forense |
| `--audit-log-maxage` / `-maxbackup` / `-maxsize` | `30` / `10` / `100` | Retención sin llenar el disco |
| `--service-account-lookup` | `true` | Valida que el token todavía exista en etcd (respeta la revocación) |
| `--kubelet-certificate-authority` | configurado | Previene MITM entre API server y kubelet |
| `--client-ca-file`, `--tls-cert-file`, `--tls-private-key-file` | configurados | TLS mutuo |
| `--etcd-cafile`, `--etcd-certfile`, `--etcd-keyfile` | configurados | TLS autenticado hacia etcd |
| `--encryption-provider-config` | configurado, con un provider real (`aescbc`/`secretbox`/`kms`), nunca `identity` primero | Cifra los Secrets en reposo |
| `--request-timeout` | valor sensato (default `60s`) | DoS estilo Slowloris |
| `--tls-cipher-suites` | solo suites fuertes | Level 2 |

### Remediación resuelta

kube-bench reporta:

```text
[FAIL] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
[FAIL] 1.2.21 Ensure that the --service-account-lookup argument is set to true (Automated)
```

Arreglo:

```bash
ssh controlplane
cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=10.0.0.10
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
    - --profiling=false                 # <-- 1.2.15
    - --service-account-lookup=true     # <-- 1.2.21
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    ...
```

Miralo volver:

```bash
# The kubelet notices the file change and recreates the static pod.
crictl ps | grep kube-apiserver
# 3f9a1c...  2 seconds ago  Running  kube-apiserver  0

kubectl get pods -n kube-system kube-apiserver-controlplane
# NAME                         READY   STATUS    RESTARTS   AGE
# kube-apiserver-controlplane  1/1     Running   0          31s
```

Volver a verificar:

```bash
kube-bench run --targets master --check 1.2.15,1.2.21
# [PASS] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
# [PASS] 1.2.21 Ensure that the --service-account-lookup argument is set to true (Automated)
```

> **Trampa:** un error de tipeo en el manifiesto hace que el API server nunca arranque, y `kubectl` deja de funcionar con `The connection to the server ... was refused`. Depurá con `crictl ps -a`, `crictl logs <id>` y `journalctl -u kubelet`. Guardá siempre una copia de respaldo **fuera** de `/etc/kubernetes/manifests/` — un archivo `.bak` dejado dentro de ese directorio se parsea como manifiesto y crea un pod duplicado.

---

## 4. etcd (sección 2)

etcd guarda todos los Secrets, ConfigMaps y objetos del clúster **en texto plano por defecto**. El acceso de lectura a etcd equivale a cluster-admin. Manifiesto:

```
/etc/kubernetes/manifests/etcd.yaml
```

| Control | Configuración correcta |
|---|---|
| 2.1 | `--cert-file` y `--key-file` configurados (TLS de cliente) |
| 2.2 | `--client-cert-auth=true` — los clientes deben presentar un certificado válido |
| 2.3 | `--auto-tls` **no** en `true` — los certificados autofirmados aceptan a cualquiera |
| 2.4 | `--peer-cert-file` y `--peer-key-file` configurados |
| 2.5 | `--peer-client-cert-auth=true` |
| 2.6 | `--peer-auto-tls` **no** en `true` |
| 2.7 | etcd usa una **CA única**, no la CA del clúster |

Fragmento endurecido:

```yaml
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://10.0.0.10:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --client-cert-auth=true
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-client-cert-auth=true
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --data-dir=/var/lib/etcd
```

Probá que el puerto de clientes realmente exige un certificado:

```bash
# Without credentials — must fail:
curl -k https://127.0.0.1:2379/version
# curl: (56) OpenSSL SSL_read: error:0A00045C:SSL routines::tlsv13 alert certificate required

# With credentials — succeeds:
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
# https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 4.2ms
```

Permisos del directorio de datos (control 1.1.11/1.1.12 según la revisión):

```bash
stat -c "%a %U:%G" /var/lib/etcd
# 700 etcd:etcd

# Remediation if wrong:
chmod 700 /var/lib/etcd
chown etcd:etcd /var/lib/etcd
```

Demostrá por qué importa el cifrado en reposo:

```bash
kubectl create secret generic demo --from-literal=password=S3cr3t
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/demo | hexdump -C | head
# ... 70 61 73 73 77 6f 72 64  ... 53 33 63 72 33 74   |password ... S3cr3t|
```

Con `--encryption-provider-config` apuntando a un provider `aescbc` o `kms`, ese mismo volcado empieza con `k8s:enc:aescbc:v1:` y el valor es ilegible.

---

## 5. kubelet (sección 4)

El kubelet expone una API en el puerto `10250` que puede **hacer exec dentro de cualquier pod del nodo**. Es el objetivo de movimiento lateral más atractivo de un clúster.

La configuración viene de dos lugares, y el archivo de configuración gana para todo lo que no se sobrescriba en la línea de comandos:

```
/var/lib/kubelet/config.yaml            # KubeletConfiguration object
/etc/systemd/system/kubelet.service.d/10-kubeadm.conf   # CLI flags
```

| Control | Configuración | Clave del archivo de configuración |
|---|---|---|
| 4.2.1 | `--anonymous-auth=false` | `authentication.anonymous.enabled: false` |
| 4.2.2 | `--authorization-mode=Webhook` (nunca `AlwaysAllow`) | `authorization.mode: Webhook` |
| 4.2.3 | `--client-ca-file` configurado | `authentication.x509.clientCAFile` |
| 4.2.4 | `--read-only-port=0` | `readOnlyPort: 0` |
| 4.2.5 | `--streaming-connection-idle-timeout` ≠ `0` | `streamingConnectionIdleTimeout: 5m` |
| 4.2.x | `--protect-kernel-defaults=true` | `protectKernelDefaults: true` |
| 4.2.x | `--make-iptables-util-chains=true` | `makeIPTablesUtilChains: true` |
| 4.2.x | `--hostname-override` sin configurar | — |
| 4.2.x | `eventRecordQPS` configurado (limita la inundación de eventos) | `eventRecordQPS: 5` |
| 4.2.x | `--rotate-certificates=true` | `rotateCertificates: true` |
| 4.2.x | `RotateKubeletServerCertificate=true` | `serverTLSBootstrap: true` |
| 4.2.x | `tlsCipherSuites` fuertes | `tlsCipherSuites: [...]` |

`config.yaml` endurecido:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false                 # 4.2.1
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # 4.2.3
authorization:
  mode: Webhook                    # 4.2.2
readOnlyPort: 0                    # 4.2.4
streamingConnectionIdleTimeout: 5m # 4.2.5
protectKernelDefaults: true
makeIPTablesUtilChains: true
eventRecordQPS: 5
rotateCertificates: true
serverTLSBootstrap: true
tlsCipherSuites:
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
```

A diferencia de los static pods, el kubelet necesita un reinicio explícito:

```bash
systemctl daemon-reload
systemctl restart kubelet
systemctl status kubelet --no-pager
journalctl -u kubelet -n 30 --no-pager
```

Verificá que la superficie de ataque esté realmente cerrada:

```bash
# Read-only port (10255) must be gone:
curl -s http://localhost:10255/pods
# curl: (7) Failed to connect to localhost port 10255: Connection refused

# Anonymous access to the authenticated port must be rejected:
curl -sk https://localhost:10250/pods
# Unauthorized
```

> **Trampa:** `protectKernelDefaults: true` hace que el kubelet **se niegue a arrancar** si sysctls como `vm.overcommit_memory` o `kernel.panic` no coinciden con sus expectativas. Revisá `journalctl -u kubelet` buscando `Failed to start ContainerManager ... sysctl ...` y configurá los valores en `/etc/sysctl.d/` antes de habilitarlo.

> **Trampa:** en algunas distribuciones el valor efectivo viene del drop-in de systemd, no de `config.yaml`. Confirmá siempre con qué está corriendo realmente el proceso:
> ```bash
> ps -ef | grep '[k]ubelet' | tr ' ' '\n' | grep -E 'anonymous|read-only|authorization|config'
> ```

---

## 6. kubedns / CoreDNS

El objetivo del examen nombra `kubedns`, lo cual es histórico — los clústeres modernos corren **CoreDNS**. El CIS Kubernetes Benchmark **no** tiene una sección dedicada a CoreDNS; queda cubierto indirectamente por la sección 5 (RBAC, Pod Security Standards, network policy). Lo endurecés como una carga de trabajo:

**1. Auditá su RBAC.** CoreDNS solo necesita *leer* endpoints, services, pods y namespaces:

```bash
kubectl get clusterrole system:coredns -o yaml
```

```yaml
rules:
- apiGroups: [""]
  resources: ["endpoints", "services", "pods", "namespaces"]
  verbs: ["list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["list", "watch"]
```

Cualquier cosa más allá de `list`/`watch` sobre esos recursos — especialmente `secrets`, o cualquier `create`/`update` — es un hallazgo.

**2. Revisá el security context del pod.** CoreDNS debería correr como no-root con un conjunto mínimo de capabilities:

```bash
kubectl get deploy coredns -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | jq .
```

```json
{
  "allowPrivilegeEscalation": false,
  "capabilities": { "add": ["NET_BIND_SERVICE"], "drop": ["ALL"] },
  "readOnlyRootFilesystem": true
}
```

**3. Revisá el Corefile** en busca de plugins peligrosos. Verificá que no haya ningún `forward` inesperado hacia un resolver no confiable, y que los endpoints de metrics/health no estén expuestos más allá del clúster:

```bash
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'
```

```
.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
```

`pods insecure` permite resolver *cualquier* IP de pod como `<ip>.<ns>.pod.cluster.local` sin verificar que el pod realmente viva en ese namespace — una ayuda para el reconocimiento. `pods verified` es la alternativa endurecida.

**4. Restringí quién puede hablarle.** Una NetworkPolicy en `kube-system` que solo permita ingress UDP/TCP 53 impide que un pod comprometido use el servicio de DNS como pivote:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: coredns-allow-dns-only
  namespace: kube-system
spec:
  podSelector:
    matchLabels:
      k8s-app: kube-dns
  policyTypes: ["Ingress"]
  ingress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

---

## 7. Permisos y propiedad de archivos (secciones 1.1 y 4.1)

Estos son los `FAIL` más fáciles de arreglar y aparecen constantemente en la salida de kube-bench.

| Ruta | Permisos | Propietario |
|---|---|---|
| `/etc/kubernetes/manifests/*.yaml` | `600` | `root:root` |
| `/etc/kubernetes/admin.conf` | `600` | `root:root` |
| `/etc/kubernetes/scheduler.conf`, `controller-manager.conf` | `600` | `root:root` |
| `/etc/kubernetes/pki/*.crt` | `644` | `root:root` |
| `/etc/kubernetes/pki/*.key` | `600` | `root:root` |
| `/var/lib/etcd` | `700` | `etcd:etcd` |
| `/var/lib/kubelet/config.yaml` | `600` | `root:root` |
| `/etc/kubernetes/kubelet.conf` | `600` | `root:root` |
| Archivos de configuración de CNI bajo `/etc/cni/net.d/` | `600` | `root:root` |

> Las revisiones más antiguas del benchmark pedían `644` en los manifiestos y kubeconfigs; las actuales requieren `600`. Aplicá lo que diga **tu** salida.

Remediación masiva:

```bash
chmod 600 /etc/kubernetes/manifests/*.yaml
chmod 600 /etc/kubernetes/admin.conf /etc/kubernetes/scheduler.conf \
          /etc/kubernetes/controller-manager.conf /etc/kubernetes/kubelet.conf
chmod 600 /etc/kubernetes/pki/*.key /etc/kubernetes/pki/etcd/*.key
chmod 644 /etc/kubernetes/pki/*.crt
chown -R root:root /etc/kubernetes/pki

# Verify:
find /etc/kubernetes/pki -name '*.key' -exec stat -c "%a %U:%G %n" {} \;
# 600 root:root /etc/kubernetes/pki/apiserver.key
# 600 root:root /etc/kubernetes/pki/ca.key
```

---

## 8. Controller manager y scheduler (secciones 1.3 y 1.4)

Superficie más chica, pero aparecen en la salida de kube-bench:

| Componente | Control | Configuración |
|---|---|---|
| controller-manager | `--profiling` | `false` |
| controller-manager | `--use-service-account-credentials` | `true` (cada controlador obtiene su propia SA de mínimo privilegio) |
| controller-manager | `--service-account-private-key-file` | configurado |
| controller-manager | `--root-ca-file` | configurado |
| controller-manager | `RotateKubeletServerCertificate` | `true` |
| controller-manager | `--bind-address` | `127.0.0.1` |
| scheduler | `--profiling` | `false` |
| scheduler | `--bind-address` | `127.0.0.1` |

---

## 9. Flujo de trabajo práctico para el examen

1. **Línea base.** Ejecutá kube-bench en el nodo del control plane y guardá la salida.
   ```bash
   kube-bench run --targets master,etcd --outputfile /tmp/cp.txt
   grep '\[FAIL\]' /tmp/cp.txt
   ```
2. **Respaldá** cada manifiesto que toques, en un directorio *fuera* de `/etc/kubernetes/manifests/`.
3. **Aplicá** la remediación que imprimió kube-bench — textualmente. No inventes tu propio nombre de flag.
4. **Reiniciá correctamente:** los static pods (apiserver, controller-manager, scheduler, etcd) se reinician solos; el kubelet necesita `systemctl restart kubelet`.
5. **Confirmá que el clúster esté vivo:** `kubectl get nodes`, `kubectl -n kube-system get pods`.
6. **Volvé a ejecutar acotado** a lo que arreglaste: `kube-bench run --targets master --check 1.2.15,1.2.21`.
7. **Repetí en los workers:** `kube-bench run --targets node`.

One-liner práctico para listar solo las fallas con sus títulos:

```bash
kube-bench run --targets master --json \
  | jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | "\(.test_number)  \(.test_desc)"'
```

```text
1.2.15  Ensure that the --profiling argument is set to false
1.2.21  Ensure that the --service-account-lookup argument is set to true
1.1.12  Ensure that the etcd data directory ownership is set to etcd:etcd
```

---

## 10. Límites y trampas

- **El benchmark es una línea base, no un programa de seguridad.** El cumplimiento total de CIS no detiene una imagen de contenedor maliciosa, un token de service account filtrado ni un binding de RBAC demasiado permisivo.
- **No todo FAIL debe arreglarse a ciegas.** Algunos controles rompen cargas de trabajo específicas (`AlwaysPullImages` en un registro air-gapped, `EventRateLimit` sin una configuración ajustada). CIS documenta esto bajo *Impact*. Justificá y documentá las excepciones en lugar de fingir que pasan.
- **kube-bench solo ve el nodo en el que corre.** En un control plane multinodo tenés que ejecutarlo en cada nodo — la deriva de configuración entre nodos del control plane es un hallazgo real y común.
- **En clústeres gestionados** (EKS/GKE/AKS) no podés editar el control plane en absoluto; usá el benchmark específico del proveedor, que solo testea nodos worker y políticas.
- **`WARN` no significa "seguro".** Los controles manuales son los que una herramienta no puede verificar — a menudo los más importantes (el contenido de la política de auditoría, la corrección del provider de cifrado, el diseño de RBAC).

---

## Ejercicios

**1.** Ejecutá kube-bench contra el control plane y producí una lista únicamente con los IDs de los chequeos que fallan en la sección del API server.

<details><summary>Solución</summary>

```bash
kube-bench run --targets master --json \
  | jq -r '.Controls[].tests[] | select(.section=="1.2") | .results[]
           | select(.status=="FAIL") | .test_number'
```
</details>

**2.** kube-bench reporta `[FAIL] 1.2.15 Ensure that the --profiling argument is set to false`. Arreglalo y probá el arreglo.

<details><summary>Solución</summary>

```bash
cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backup/
# add `- --profiling=false` to the command list
vi /etc/kubernetes/manifests/kube-apiserver.yaml
# wait for the static pod to be recreated
watch crictl ps | grep kube-apiserver
kube-bench run --targets master --check 1.2.15
# [PASS] 1.2.15 Ensure that the --profiling argument is set to false (Automated)
```
</details>

**3.** Cerrá el puerto de solo lectura del kubelet y deshabilitá la autenticación anónima en un nodo worker, después verificá ambas cosas desde la shell.

<details><summary>Solución</summary>

En `/var/lib/kubelet/config.yaml`: configurá `readOnlyPort: 0`, `authentication.anonymous.enabled: false`, `authorization.mode: Webhook`.

```bash
systemctl restart kubelet
curl -s http://localhost:10255/pods          # connection refused
curl -sk https://localhost:10250/pods        # Unauthorized
kube-bench run --targets node --check 4.2.1,4.2.2,4.2.4
```
</details>

**4.** Confirmá que etcd rechaza a los clientes que no presentan un certificado.

<details><summary>Solución</summary>

Asegurate de que `--client-cert-auth=true` esté configurado y de que `--auto-tls` esté ausente en `/etc/kubernetes/manifests/etcd.yaml`, luego:

```bash
curl -k https://127.0.0.1:2379/version
# tlsv13 alert certificate required
```
</details>

**5.** Mostrá que un Secret se almacena en texto plano en etcd, luego explicá qué control de CIS lo aborda.

<details><summary>Solución</summary>

Usá `etcdctl get /registry/secrets/<ns>/<name> | hexdump -C` y observá el valor legible. Los controles relevantes son que el `--encryption-provider-config` del API server esté configurado (1.2.27 en las revisiones recientes) y que los providers estén correctamente configurados, es decir, `identity` no debe ser el primer provider.
</details>

---

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark (descarga gratuita) — https://www.cisecurity.org/benchmark/kubernetes
- Panorama de los CIS Benchmarks — https://www.cisecurity.org/cis-benchmarks
- Repositorio de kube-bench — https://github.com/aquasecurity/kube-bench
- Documentación de kube-bench — https://aquasecurity.github.io/kube-bench/
- Kubernetes — Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — referencia de kube-apiserver — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — referencia de kubelet — https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- Kubernetes — KubeletConfiguration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes — referencia de kube-controller-manager — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- Kubernetes — referencia de kube-scheduler — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-scheduler/
- Kubernetes — Encrypting Secret Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes — Using NodeRestriction admission plugin — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Kubernetes — Customizing DNS Service (CoreDNS) — https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- CoreDNS Kubernetes plugin — https://coredns.io/plugins/kubernetes/
- etcd — Transport security model — https://etcd.io/docs/latest/op-guide/security/