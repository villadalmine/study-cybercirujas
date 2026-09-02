# Comprender e implementar técnicas de aislamiento (multi-tenancy, contenedores en sandbox, etc.)

## 1. Por qué el aislamiento es un control de seguridad

Un clúster de Kubernetes es, por defecto, un sistema **shared-everything** (todo compartido):

- Cada Pod puede alcanzar a cualquier otro Pod por la red (red L3 plana, sin filtrado).
- Cada Pod de un nodo **comparte el kernel del host** con todos los demás Pods de ese nodo.
- Cada ServiceAccount puede hablar con el API server (aunque apenas pueda leer nada).
- Cada Service del clúster es resoluble a través del DNS del clúster, desde cualquier namespace.

El aislamiento es la disciplina de eliminar deliberadamente esos valores por defecto para que un compromiso quede acotado. El modelo mental para el examen — y para clústeres reales — es el **radio de impacto** (*blast radius*):

> Si un atacante consigue ejecución de código arbitrario dentro de un contenedor, ¿qué más puede tocar?

Las técnicas de aislamiento responden esa pregunta en cuatro capas distintas, y un diseño serio usa varias de ellas juntas (defensa en profundidad):

| Capa | Frontera | Herramientas principales |
|---|---|---|
| API / lógica | Namespace | RBAC, ServiceAccounts, ResourceQuota, LimitRange, Pod Security Admission |
| Red | Tráfico Pod a Pod | NetworkPolicy, política a nivel de CNI (Cilium), mTLS / service mesh |
| Nodo | Qué carga de trabajo aterriza en qué máquina | taints/tolerations, nodeSelector/affinity, pools de nodos dedicados, admission control |
| Kernel | Superficie de syscalls del contenedor | seccomp, AppArmor, capabilities, user namespaces, **runtimes en sandbox (gVisor, Kata)** |

Nada de lo anterior sustituye a la capa inferior. Un namespace **no** detiene un escape de contenedor; un perfil seccomp **no** impide que un Pod lea el Secret de otro namespace a través de la API.

---

## 2. Multi-tenancy: soft vs hard

Un *tenant* es la unidad que necesites mantener separada: un equipo, un cliente, un entorno, un job de CI. La pregunta de diseño crítica es cuánto confiás en ese tenant.

### 2.1 Soft multi-tenancy

Los tenants son **mutuamente no maliciosos pero potencialmente descuidados** — lo típico para equipos dentro de una misma empresa. El modelo de amenaza es el *accidente*: un mal label selector, un Deployment desbocado, un Secret leído por el equipo equivocado.

La soft multi-tenancy se implementa con namespaces más políticas:

- un namespace por tenant,
- RBAC acotado con `Role` / `RoleBinding` (nunca `ClusterRoleBinding`),
- `ResourceQuota` + `LimitRange` para que un tenant no pueda dejar sin recursos a los demás,
- `NetworkPolicy` default-deny por namespace,
- Pod Security Admission en `restricted`.

### 2.2 Hard multi-tenancy

Los tenants se **asumen hostiles** — clientes SaaS, código no confiable enviado por usuarios, runners públicos de CI. Los namespaces no alcanzan, porque un namespace es solo un ámbito a nivel de API. El modelo de amenaza ahora incluye escape de contenedor y explotación del kernel, así que hay que añadir:

- **runtimes en sandbox** (gVisor / Kata) o nodos dedicados por tenant,
- separación a nivel de nodo para que un escape exitoso deje al atacante en un nodo que solo aloja cargas de ese tenant,
- a menudo un **plano de control separado por tenant** (clúster separado, o un clúster virtual como vcluster / Capsule).

La respuesta honesta de CKS: **la verdadera hard multi-tenancy sobre un único kernel compartido no es alcanzable solo con namespaces.** La respuesta más fuerte dentro de un solo clúster es *runtime en sandbox + nodos dedicados + política de red estricta*.

### 2.3 Lo que un namespace NO aísla

Memorizá esta lista; es la fuente de la mayoría de los distractores del examen y de la mayoría de los errores del mundo real:

- **Nodos y el kernel** — Pods de distintos namespaces comparten la misma máquina y el mismo kernel por defecto.
- **Red** — los namespaces no tienen ningún efecto sobre la conectividad sin NetworkPolicy.
- **DNS** — cualquier Pod puede resolver y consultar `svc.other-tenant.svc.cluster.local`.
- **Objetos cluster-scoped** — Nodes, PersistentVolumes, StorageClasses, CRDs, ClusterRoles, IngressClasses, PriorityClasses, `RuntimeClass`, y (namespaced pero de alcance cluster-wide) las asignaciones de `NodePort`.
- **CRDs** — un CRD es cluster-scoped; un tenant que defina o elimine un CRD afecta a todos.
- **El kubelet y los metadatos del nodo** — un Pod con acceso al host alcanza el nodo sin importar su namespace.

---

## 3. Aislamiento lógico con namespaces

### 3.1 Crear el namespace del tenant y cerrar la superficie de API

```bash
kubectl create namespace tenant-a
kubectl label namespace tenant-a tenant=a
```

Cada namespace lleva automáticamente una label inmutable con su propio nombre — extremadamente útil para selectores de NetworkPolicy y PSA:

```bash
kubectl get ns tenant-a --show-labels
```

```
NAME       STATUS   AGE   LABELS
tenant-a   Active   12s   kubernetes.io/metadata.name=tenant-a,tenant=a
```

Aplicá Pod Security Admission a nivel de namespace para que el tenant no pueda crear Pods con privilegios sobre el host:

```bash
kubectl label namespace tenant-a \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34 \
  pod-security.kubernetes.io/warn=restricted
```

Este único paso bloquea `hostPID`, `hostNetwork`, `hostPath`, `privileged: true` y seccomp unconfined — es decir, los caminos más habituales desde "dentro de un contenedor" hasta "sobre el nodo".

### 3.2 Acotar RBAC al namespace

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: tenant-a
  name: tenant-admin
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "deployments", "services", "configmaps", "jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: tenant-a
  name: tenant-a-admins
subjects:
- kind: Group
  name: tenant-a-devs
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: tenant-admin
  apiGroup: rbac.authorization.k8s.io
```

Verificá la frontera desde el punto de vista del tenant:

```bash
kubectl auth can-i list secrets --namespace tenant-a --as-group tenant-a-devs --as dev1
kubectl auth can-i list pods    --namespace tenant-b --as-group tenant-a-devs --as dev1
kubectl auth can-i list nodes   --as-group tenant-a-devs --as dev1
```

```
no
no
no
```

Dos reglas extra de endurecimiento para las cargas de trabajo del tenant:

```yaml
# Evitar que el token por defecto se monte en cada Pod
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: tenant-a
automountServiceAccountToken: false
```

Nunca le concedas a un tenant `escalate`, `bind`, `impersonate`, `nodes/proxy`, `pods/exec` sobre otros namespaces, ni `create` sobre `pods` en `kube-system` — cada una de esas cosas convierte una identidad acotada al namespace en una identidad de alcance cluster.

### 3.3 Aislamiento de recursos: quotas y límites

El aislamiento incluye la disponibilidad. Sin quotas, un tenant es un vector de denegación de servicio para todo el clúster.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "50"
    count/services.nodeports: "0"     # tenants must not expose NodePorts
    count/services.loadbalancers: "2"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-defaults
  namespace: tenant-a
spec:
  limits:
  - type: Container
    default:            { cpu: 500m, memory: 512Mi }
    defaultRequest:     { cpu: 100m, memory: 128Mi }
    max:                { cpu: "4",  memory: 8Gi }
```

```bash
kubectl describe quota tenant-a-quota -n tenant-a
```

```
Name:                         tenant-a-quota
Namespace:                    tenant-a
Resource                      Used  Hard
--------                      ----  ----
count/services.nodeports      0     0
limits.cpu                    2     16
limits.memory                 2Gi   32Gi
pods                          4     50
requests.cpu                  400m  8
requests.memory               512Mi 16Gi
```

Fijate en `count/services.nodeports: "0"` — un NodePort abre un agujero en todos los nodos del clúster, así que es una preocupación entre tenants, no local a un tenant.

---

## 4. Aislamiento de red

Los namespaces te dan *nombres*, no *muros*. Empezá cada namespace de tenant con default deny en ambas direcciones, y después abrí solo lo necesario.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-a
spec:
  podSelector: {}                 # every Pod in the namespace
  policyTypes: ["Ingress", "Egress"]
```

Un `podSelector` vacío sin reglas `ingress`/`egress` deniega todo. Esto rompe el DNS inmediatamente, así que hay que devolverlo explícitamente:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - { protocol: UDP, port: 53 }
    - { protocol: TCP, port: 53 }
```

Permitir tráfico *dentro* del tenant, y solo desde un namespace par explícitamente nombrado:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-tenant-and-ingress-ns
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector: {}                       # same namespace
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Verificá desde otro tenant — esta es la comprobación que demuestra el aislamiento:

```bash
kubectl run probe -n tenant-b --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- --timeout=3 http://web.tenant-a.svc.cluster.local || echo BLOCKED'
```

```
wget: download timed out
BLOCKED
pod "probe" deleted
```

Dos sutilezas importantes:

- `namespaceSelector` + `podSelector` en el **mismo ítem de la lista** (sin `-` antes de `podSelector`) significa "ese Pod *en* ese namespace" (AND). Como **ítems separados** de la lista significa OR. Esta distinción es una trampa clásica del examen.
- La NetworkPolicy la aplica el CNI. En un CNI sin soporte de políticas los objetos se aceptan y se ignoran silenciosamente. Confirmá que tu CNI (Calico, Cilium, Antrea, …) realmente las aplica.
- Para la confidencialidad *en el cable* entre tenants, la NetworkPolicy no alcanza — agregá cifrado Pod a Pod (Cilium WireGuard/IPsec, o una malla que provea mTLS).

---

## 5. Aislamiento de nodos

Si dos tenants comparten un nodo, un escape de contenedor en uno es un compromiso del otro. El aislamiento de nodos hace que el escape aterrice en algún lugar inofensivo.

### 5.1 Dedicar nodos con taints + nodeSelector

```bash
kubectl label node worker-3 tenant=a
kubectl taint node worker-3 tenant=a:NoSchedule
```

```
node/worker-3 labeled
node/worker-3 tainted
```

Los Pods del tenant necesitan entonces tanto una toleration (para estar *permitidos* en el nodo) como un selector (para ser *forzados* hacia él):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: tenant-a
spec:
  nodeSelector:
    tenant: a
  tolerations:
  - key: tenant
    operator: Equal
    value: a
    effect: NoSchedule
  containers:
  - name: web
    image: nginx:1.27
```

**Un taint ≠ una frontera de seguridad por sí solo.** Una toleration es autoservicio: cualquier tenant que pueda crear un Pod puede escribir cualquier toleration y aterrizar en cualquier nodo con taint. Para que el aislamiento de nodos sea exigible hace falta admission control:

- Plugin de admission **`PodNodeSelector`** — fuerza un nodeSelector por namespace, y restringe qué selectores están permitidos:

  ```bash
  # kube-apiserver flag
  --enable-admission-plugins=NodeRestriction,PodNodeSelector,PodTolerationRestriction
  ```

  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: tenant-a
    annotations:
      scheduler.alpha.kubernetes.io/node-selector: "tenant=a"
  ```

- Plugin de admission **`PodTolerationRestriction`** — establece tolerations por defecto y una whitelist por namespace, de modo que un tenant no pueda inventarse una toleration para los nodos de otro tenant:

  ```yaml
  metadata:
    annotations:
      scheduler.alpha.kubernetes.io/defaultTolerations: '[{"key":"tenant","operator":"Equal","value":"a","effect":"NoSchedule"}]'
      scheduler.alpha.kubernetes.io/tolerationsWhitelist: '[{"key":"tenant","operator":"Equal","value":"a","effect":"NoSchedule"}]'
  ```

- O un motor de políticas (Kyverno / OPA Gatekeeper / una ValidatingAdmissionPolicy) que mute y valide `nodeSelector`/`tolerations` según el namespace de la petición.

### 5.2 Mantener el plano de control fuera de los nodos de tenants

Los nodos del plano de control llevan `node-role.kubernetes.io/control-plane:NoSchedule`. Nunca quites ese taint para "conseguir más capacidad" — pone cargas de tenants junto a etcd y a los certificados del API server.

---

## 6. Aislamiento del kernel: contenedores en sandbox

### 6.1 El problema

Un contenedor normal es un proceso en el host, restringido por namespaces, cgroups, capabilities, seccomp y LSMs — pero llama **directamente al kernel del host**, a través de aproximadamente 300+ syscalls. Cualquier bug del kernel explotable que sea alcanzable desde esa superficie es un camino al compromiso total del nodo, y desde el nodo a cada Pod que hay en él (incluyendo sus tokens de service account y los Secrets montados).

Un **contenedor en sandbox** reduce o elimina ese contacto directo con el kernel. Dos enfoques de producción:

| | **gVisor** (`runsc`) | **Kata Containers** |
|---|---|---|
| Técnica | Un kernel en espacio de usuario intercepta las syscalls y las reimplementa | Cada Pod corre dentro de una VM ligera (QEMU / Cloud Hypervisor / Firecracker) |
| Frontera | Interceptación de syscalls (`Sentry`) + conjunto de syscalls del host fuertemente restringido | Virtualización por hardware (VT-x/AMD-V), kernel invitado separado |
| Arranque | Milisegundos–decenas de ms | Más lento (arranque de VM), ~100s de ms |
| Compatibilidad de syscalls | Parcial — algunas syscalls no implementadas; cargas inusuales pueden fallar | Alta — kernel Linux real en el invitado |
| Rendimiento de E/S | Sobrecarga apreciable en trabajo intensivo en syscalls / en red | Sobrecarga en E/S, mejor paridad en trabajo limitado por CPU |
| ¿Necesita virt. anidada? | No | Sí, si los nodos son ellos mismos VMs |
| Uso típico | Código de usuario no confiable, funciones, jobs de CI | Garantía más fuerte, cargas que necesitan funcionalidades completas del kernel |

Ambos son **runtimes a nivel de CRI** seleccionados por Pod. Ninguno está habilitado por defecto.

### 6.2 Paso 1 — instalar el runtime en el nodo y registrarlo en containerd

gVisor incluye `runsc` más un shim para containerd:

```bash
runsc --version
```

```
runsc version release-20250401.0
spec: 1.1.0
```

containerd (config versión 2) — agregar un handler de runtime:

```toml
# /etc/containerd/config.toml
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
```

> En containerd 2.x con config `version = 3`, la clave del plugin CRI es `io.containerd.cri.v1.runtime` en lugar de `io.containerd.grpc.v1.cri`. Verificá con `containerd config dump` en el nodo en vez de adivinar.

```bash
systemctl restart containerd
systemctl is-active containerd
```

```
active
```

El nombre de la clave al final de esa ruta TOML (`runsc`, `kata`) es el nombre del **handler** — esa es exactamente la cadena que una RuntimeClass debe referenciar.

### 6.3 Paso 2 — crear la RuntimeClass

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor          # what Pod authors write
handler: runsc          # must match the containerd runtime key
```

Una versión más realista además fija la clase a los nodos que realmente tienen el runtime instalado, y contabiliza el coste de recursos del propio sandbox:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
scheduling:
  nodeSelector:
    sandbox.example.com/runtime: kata
  tolerations:
  - key: sandbox
    operator: Equal
    value: kata
    effect: NoSchedule
overhead:
  podFixed:
    cpu: 250m
    memory: 160Mi
```

```bash
kubectl get runtimeclass
```

```
NAME     HANDLER   AGE
gvisor   runsc     30s
kata     kata      12s
```

RuntimeClass es **cluster-scoped**: solo los administradores del clúster la crean; los tenants solo la referencian. Restringí quién puede referenciar qué clase con RBAC (`resourceNames`) o con una política de admission si eso importa.

### 6.4 Paso 3 — ejecutar un Pod en el sandbox

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted
  namespace: tenant-a
spec:
  runtimeClassName: gvisor
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
```

```bash
kubectl apply -f untrusted.yaml
kubectl get pod untrusted -n tenant-a -o jsonpath='{.spec.runtimeClassName}{"\n"}'
```

```
pod/untrusted created
gvisor
```

### 6.5 Paso 4 — demostrar que el sandbox es real

Vale la pena practicar este paso de verificación; "puse `runtimeClassName`" no es una prueba.

**gVisor** se anuncia en el `dmesg` del invitado:

```bash
kubectl exec -n tenant-a untrusted -- dmesg | head -5
```

```
[    0.000000] Starting gVisor...
[    0.284728] Checking naughty and nice process list...
[    0.508201] Rewriting operating system in Javascript...
[    0.762211] Creating cloned children...
[    0.913860] Ready!
```

Si el Pod **no** está en sandbox, obtenés en cambio el ring buffer del host o un error de permisos:

```bash
kubectl exec -n tenant-a normal-pod -- dmesg | head -3
```

```
dmesg: read kernel buffer failed: Operation not permitted
command terminated with exit code 1
```

**Kata**: el kernel del invitado difiere del kernel del nodo.

```bash
kubectl exec -n tenant-a kata-pod -- uname -r     # guest kernel
ssh worker-3 uname -r                             # host kernel
```

```
6.1.62
5.15.0-119-generic
```

Y en el nodo podés ver el proceso VMM que respalda al Pod:

```bash
ssh worker-3 'ps -ef | grep -c "[q]emu"'
```

```
1
```

### 6.6 Limitaciones del sandbox que hay que esperar

- Los Pods que requieren `privileged`, `hostPID`, `hostNetwork`, la mayoría de los montajes `hostPath`, o acceso directo a dispositivos, generalmente **no funcionarán** bajo gVisor — que es en buena medida el objetivo.
- Algunas syscalls y entradas de `/proc` y `/sys` están sin implementar o emuladas; el software que sondea interfaces profundas del kernel (algunos depuradores, `perf`, ciertas bases de datos, herramientas eBPF) puede fallar.
- Kata necesita virtualización disponible en el nodo; hay que habilitar la virtualización anidada si los nodos son VMs.
- Las herramientas a nivel de nodo que inspeccionan contenedores a través del kernel del host (algunos agentes de seguridad en runtime) ven menos dentro de un sandbox.
- Los sandboxes cuestan CPU/memoria/latencia — declaralo con `overhead` para que el scheduler lo contabilice.

### 6.7 Un término medio más liviano: user namespaces

En lugar de un sandbox completo, podés mapear los UIDs del contenedor a UIDs del host sin privilegios, de modo que root en el Pod sea un don nadie en el host:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-demo
spec:
  hostUsers: false          # run the Pod in its own user namespace
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
```

```bash
kubectl exec userns-demo -- id -u        # inside the Pod
```

```
0
```

```bash
ssh worker-1 'ps -o uid,cmd -C sleep'    # on the host
```

```
  UID CMD
65538 sleep 3600
```

Esto mitiga una gran clase de escapes "root en el contenedor → root en el host" con un coste de rendimiento casi nulo. Es una funcionalidad beta (habilitada por defecto desde v1.30) y requiere un runtime/kernel compatible (montajes idmap), así que verificá los feature gates y las versiones de los nodos antes de depender de ella.

---

## 7. Aislamiento del plano de control para una tenancy más fuerte

Cuando los tenants necesitan sus propios CRDs, webhooks u objetos cluster-scoped, un plano de control compartido es el cuello de botella. Opciones, de la más débil a la más fuerte:

1. **Namespaces + políticas** — soft multi-tenancy (secciones 3–4).
2. **Jerarquía de namespaces / operadores de tenancy** — Hierarchical Namespace Controller, Capsule: las políticas y el RBAC se propagan a los subárboles del tenant; sigue habiendo un plano de control y un kernel por nodo.
3. **Clústeres virtuales** (vcluster) — cada tenant obtiene su propio API server y etcd (como Pods), mientras las cargas de trabajo se sincronizan hacia el clúster anfitrión. Los tenants pueden crear CRDs y objetos cluster-scoped de forma segura; el *kernel* sigue compartido salvo que agregues sandboxing.
4. **Clústeres separados** — la frontera más fuerte y la más simple de razonar; el mayor coste operativo.

Para el examen, conocé la formulación del compromiso: *los namespaces aíslan la API, los clústeres virtuales aíslan el plano de control, los sandboxes/VMs aíslan el kernel, los clústeres separados lo aíslan todo.*

---

## 8. Poniéndolo todo junto: un namespace de hard multi-tenancy

Una configuración de aislamiento completa y por capas para un tenant no confiable:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-x
  labels:
    tenant: x
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
  annotations:
    scheduler.alpha.kubernetes.io/node-selector: "tenant=x"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota
  namespace: tenant-x
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: 8Gi
    count/services.nodeports: "0"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-x
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload
  namespace: tenant-x
spec:
  replicas: 2
  selector:
    matchLabels: { app: workload }
  template:
    metadata:
      labels: { app: workload }
    spec:
      runtimeClassName: gvisor            # kernel isolation
      automountServiceAccountToken: false # API isolation
      nodeSelector: { tenant: x }         # node isolation
      tolerations:
      - { key: tenant, operator: Equal, value: x, effect: NoSchedule }
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: app
        image: registry.example.com/app@sha256:6b6e...c41f
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
```

Cada línea se corresponde con una capa de la sección 1. Quitar cualquiera de ellas reabre un camino de ataque concreto — ese mapeo es exactamente lo que evalúa el examen.

---

## 9. Lista de verificación

Ejecutá esto contra cualquier clúster que afirmes que está aislado:

```bash
# 1. Does the namespace enforce a Pod Security Standard?
kubectl get ns tenant-a -o jsonpath='{.metadata.labels}' | tr ',' '\n'

# 2. Is there a default-deny NetworkPolicy?
kubectl get netpol -n tenant-a

# 3. Can a tenant identity reach outside its namespace?
kubectl auth can-i --list --namespace tenant-b --as-group tenant-a-devs --as dev1

# 4. Which runtime is each Pod actually using?
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RC:.spec.runtimeClassName'

# 5. Are tenants sharing nodes?
kubectl get pods -A -o wide --sort-by='.spec.nodeName' \
  | awk '{print $8, $1}' | sort -u

# 6. Any Pod with host access left?
kubectl get pods -A -o json | jq -r '.items[]
  | select(.spec.hostNetwork or .spec.hostPID or .spec.hostIPC
      or (.spec.containers[].securityContext.privileged // false))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

---

## 10. Errores comunes

- **Suponer que los namespaces son una frontera de seguridad.** Son un ámbito de API. Sin NetworkPolicy, PSA, quotas y separación de nodos, aíslan solo nombres.
- **Default-deny sin permitir el DNS.** Todo "funciona" pero falla toda resolución de nombres; los síntomas parecen bugs de la aplicación.
- **`namespaceSelector` con namespaces sin labels.** Usá la label incorporada `kubernetes.io/metadata.name` en lugar de otras mantenidas a mano.
- **Confiar solo en los taints.** Las tolerations están bajo control del atacante salvo que el admission control las restrinja.
- **RuntimeClass sin el runtime instalado.** El Pod se queda en `ContainerCreating`; `kubectl describe pod` muestra un CreateContainerError que menciona un handler de runtime desconocido — revisá siempre los `Events` y la configuración de containerd del nodo.
- **Desajuste en el nombre del handler.** `handler:` debe ser exactamente igual a la clave de runtime de containerd (`runsc`, no `gvisor`).
- **Olvidar el `overhead`.** Las VMs del sandbox consumen memoria real que el scheduler de otro modo no ve, lo que lleva a presión en el nodo y desalojos.
- **El sandbox como reemplazo de las demás capas.** gVisor no impide que un Pod lea los Secrets que está autorizado a leer, ni que escanee la red de Pods.
- **Dejar `automountServiceAccountToken` activo.** Un sandbox es inútil si el objetivo del escape es simplemente el API server a través de un token montado.

---

## Referencias

- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — Multi-tenancy: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes — Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Enforcing Pod Security Standards with namespace labels: https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-ranges/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes — Assigning Pods to Nodes: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Kubernetes — Admission Controllers (`PodNodeSelector`, `PodTolerationRestriction`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — RuntimeClass: https://kubernetes.io/docs/concepts/containers/runtime-class/
- Kubernetes — Pod Overhead: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/
- Kubernetes — User Namespaces: https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Kubernetes — RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- gVisor — Kubernetes / containerd quick start: https://gvisor.dev/docs/user_guide/quick_start/kubernetes/
- gVisor — Architecture guide: https://gvisor.dev/docs/architecture_guide/
- Kata Containers — Documentation: https://katacontainers.io/docs/
- Kata Containers — Kubernetes integration: https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/run-kata-with-k8s.md
- containerd — CRI plugin configuration: https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- Cilium — Transparent encryption (WireGuard/IPsec): https://docs.cilium.io/en/stable/security/network/encryption/
- vcluster — Virtual Kubernetes clusters: https://www.vcluster.com/docs/
- Kubernetes Hierarchical Namespace Controller: https://github.com/kubernetes-sigs/hierarchical-namespaces