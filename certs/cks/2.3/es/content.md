# 2.3 Understand and implement isolation techniques (multi-tenancy, sandboxed containers)

## Introducción

Un clúster de Kubernetes rara vez es usado por un solo equipo o una sola aplicación. Cuando varios *tenants* (equipos, clientes, aplicaciones con distinto nivel de confianza) comparten el mismo clúster, hay que decidir **qué tan fuerte** es el aislamiento entre ellos. Kubernetes ofrece varios mecanismos que se combinan para lograr esto:

- **Aislamiento lógico** (multi-tenancy a nivel de API): namespaces, RBAC, ResourceQuota, NetworkPolicy, Pod Security Admission.
- **Aislamiento a nivel de nodo**: node pools dedicados, taints/tolerations, node affinity.
- **Aislamiento a nivel de runtime** (sandboxed containers): gVisor, Kata Containers, mediante `RuntimeClass`.

Es clave entender que estos mecanismos son **complementarios, no sustitutos**. Un namespace por sí solo no es un límite de seguridad; combinado con RBAC, quotas, NetworkPolicy y (opcionalmente) un runtime en sandbox, sí se acerca a un aislamiento "hard".

## Multi-tenancy: soft vs hard

- **Soft multi-tenancy**: los tenants confían entre sí (mismo equipo/organización). El objetivo es evitar errores accidentales (consumo de recursos, colisión de nombres) más que ataques deliberados. Namespaces + RBAC + ResourceQuota suelen ser suficientes.
- **Hard multi-tenancy**: los tenants son mutuamente no confiables (ej. SaaS multi-cliente). Se asume que un tenant puede intentar escapar de su aislamiento. Requiere defensa en profundidad: namespaces dedicados, NetworkPolicy default-deny, nodos dedicados (o incluso clústeres dedicados), y opcionalmente **sandboxed containers** para reducir la superficie de ataque del kernel compartido.

El [Multi-tenancy Working Group de Kubernetes](https://github.com/kubernetes-sigs/multi-tenancy) documenta que **el kernel de Linux compartido es la debilidad fundamental de cualquier esquema de multi-tenancy basado solo en namespaces**: un contenedor que compromete el kernel (via una syscall vulnerable) puede afectar a todos los tenants del nodo. De ahí la importancia de los runtimes en sandbox para el caso "hard".

## Namespace como unidad de aislamiento lógico

El namespace es la unidad organizativa básica, pero **no aísla por sí solo** cómputo, red ni el kernel. Hay que reforzarlo con:

### ResourceQuota — limita el consumo agregado por namespace

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    persistentvolumeclaims: "10"
```

### LimitRange — fuerza defaults/mínimos/máximos por Pod/Container

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: team-a-limits
  namespace: team-a
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 256Mi
    defaultRequest:
      cpu: 250m
      memory: 128Mi
    max:
      cpu: "2"
      memory: 2Gi
```

Sin `ResourceQuota`/`LimitRange`, un tenant "ruidoso" puede consumir todo el nodo y afectar a los demás (noisy neighbor), aunque estén en namespaces separados.

### RBAC por namespace

Los tenants deben tener permisos acotados a su propio namespace vía `Role` + `RoleBinding` (nunca `ClusterRole`/`ClusterRoleBinding` salvo que sea estrictamente necesario):

```bash
kubectl create role team-a-admin --verb=* --resource=pods,deployments,services -n team-a
kubectl create rolebinding team-a-admin-binding \
  --role=team-a-admin --user=alice -n team-a
```

```bash
kubectl auth can-i delete pods --namespace=team-b --as=alice
# no
```

### NetworkPolicy — aísla el tráfico entre tenants

Por defecto, en Kubernetes **todo pod puede hablar con todo pod**, sin importar el namespace. Para multi-tenancy real hace falta un default-deny y reglas explícitas:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector: {}
```

Esto requiere un CNI que soporte `NetworkPolicy` (Calico, Cilium, etc.); el CNI por defecto de algunos providers no lo hace cumplir.

### Pod Security Admission (PSA)

Restringe qué `securityContext`/capabilities puede usar un Pod dentro del namespace, evitando que un tenant despliegue contenedores privilegiados que rompan el aislamiento:

```bash
kubectl label namespace team-a \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

```bash
kubectl run privileged-pod --image=nginx --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx","securityContext":{"privileged":true}}]}}' -n team-a
# Error from server (Forbidden): pods "privileged-pod" is forbidden:
# violates PodSecurity "restricted:latest": privileged (container "nginx" must not set securityContext.privileged=true)
```

## Aislamiento a nivel de nodo

Cuando el aislamiento lógico no alcanza (tenants con distinto nivel de confianza, cargas sensibles como PCI/PII), se dedica infraestructura física/nodo a un tenant específico.

### Taints y tolerations

```bash
kubectl taint nodes node-tenant-a dedicated=team-a:NoSchedule
```

```yaml
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "team-a"
    effect: "NoSchedule"
```

El taint por sí solo **repele** pods de otros tenants, pero no impide que un pod con la toleration correcta (o sin ninguna) llegue por descuido a ese nodo si además tiene affinity. Por eso se combina con:

### Node affinity — atrae los pods del tenant al nodo dedicado

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-tenant
            operator: In
            values: ["team-a"]
```

Taint+toleration evita que **otros** entren; nodeAffinity asegura que **los tuyos** vayan ahí. Se necesitan ambos para un aislamiento efectivo a nivel de nodo.

## Sandboxed containers: aislamiento a nivel de runtime

### El problema: el kernel compartido

Con el runtime por defecto (`runc`), los contenedores de un mismo nodo comparten el **mismo kernel del host**, aislados solo por namespaces de Linux, cgroups y (idealmente) seccomp/AppArmor. Una vulnerabilidad de escape de contenedor (kernel exploit, CVE de runc como CVE-2019-5736, etc.) puede comprometer el nodo entero y, con él, a todos los tenants que corren ahí. Para cargas no confiables (multi-tenancy "hard", ejecución de código de terceros) esto no es suficiente.

### gVisor (`runsc`)

gVisor implementa un kernel de aplicación en espacio de usuario ("Sentry") que intercepta las syscalls del contenedor y las reimplementa, sin pasarlas directamente al kernel del host. Esto reduce drásticamente la superficie de ataque expuesta al kernel real, a costa de cierto overhead de performance y compatibilidad parcial de syscalls.

### Kata Containers

Kata ejecuta cada pod dentro de una **VM liviana** (usando KVM/QEMU u otros hipervisores), con su propio kernel de invitado. El aislamiento es a nivel de hardware-virtualization, más fuerte que gVisor pero con mayor overhead de arranque y memoria.

### RuntimeClass — cómo se selecciona el runtime en Kubernetes

Primero hay que configurar el runtime alternativo en containerd (`/etc/containerd/config.toml`):

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```

Luego se declara el objeto `RuntimeClass`, que mapea un nombre lógico al handler del runtime:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

```bash
kubectl get runtimeclass
```
```
NAME      HANDLER   AGE
gvisor    runsc     3m
```

Y se referencia desde el Pod del tenant no confiable:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-workload
  namespace: team-a
spec:
  runtimeClassName: gvisor
  containers:
  - name: app
    image: nginx
```

Verificación de que efectivamente corre sandboxed (gVisor reemplaza el kernel visible dentro del contenedor):

```bash
kubectl exec -it untrusted-workload -- dmesg | head -5
```
```
[    0.000000] Starting gVisor...
[    0.336914] Checking naughty and nice process list...
[    0.622551] Waiting for children...
[    1.221818] Ready!
```

Un `runc` estándar mostraría el `dmesg` real del kernel del host (o error de permisos), no este banner.

## Estrategia combinada (ejemplo hard multi-tenancy)

Para un tenant no confiable, en la práctica se combinan las tres capas:

1. **Namespace dedicado** con `ResourceQuota`, `LimitRange`, RBAC acotado y PSA en `restricted`.
2. **NetworkPolicy** default-deny + reglas explícitas de ingress/egress.
3. **Node pool dedicado** vía taint/toleration + nodeAffinity.
4. **RuntimeClass** con gVisor o Kata para los pods de ese tenant, reduciendo el impacto de un escape de contenedor incluso si logra ejecutarse en el nodo dedicado.

Ningún mecanismo aislado es "la solución"; el examen suele evaluar que sepas **combinarlos** según el nivel de confianza del tenant y que sepas diagnosticar/aplicar cada uno por separado (crear RuntimeClass, escribir NetworkPolicy, taints, etc.) bajo presión de tiempo.

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs, *Multi-tenancy*: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes SIG Multi-Tenancy: https://github.com/kubernetes-sigs/multi-tenancy
- Kubernetes docs, *RuntimeClass*: https://kubernetes.io/docs/concepts/containers/runtime-class/
- Kubernetes docs, *Resource Quotas*: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes docs, *Limit Ranges*: https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes docs, *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs, *Pod Security Admission*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes docs, *Taints and Tolerations*: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes docs, *Assigning Pods to Nodes (Affinity)*: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- gVisor docs: https://gvisor.dev/docs/
- Kata Containers docs: https://katacontainers.io/docs/