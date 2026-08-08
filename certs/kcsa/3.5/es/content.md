# Tema 3.5 — Isolation and Segmentation

> **KCSA · Domain: Kubernetes Security Fundamentals · Peso 3.14**
> Perfil: Principal Platform Architect / SRE Senior. Nivel producción, defense-in-depth.

---

## 1. Motivación y el problema arquitectónico de producción

Kubernetes es, por diseño, un sistema **multi-tenant blando (soft multi-tenancy)**: un único control plane y un pool de nodes compartidos hospedan cargas de equipos, entornos y —a veces— clientes distintos. Esa densidad es la razón económica de existir de la plataforma, pero también es su superficie de ataque: **todo lo que corre en un node comparte el mismo kernel de Linux**. Un `namespace` de Kubernetes NO es un boundary de seguridad del kernel; es una etiqueta de agrupamiento en `etcd`. La separación real la construye el operador apilando controles independientes.

El fallo arquitectónico clásico que hay que evitar es asumir que **un** control aísla. Ejemplos reales de por qué la defensa en profundidad no es opcional:

- Un Pod comprometido con `hostPID: true` ve todos los procesos del node, aunque su `namespace` de Kubernetes esté "aislado".
- Un `ServiceAccount` con un RoleBinding demasiado amplio permite `kubectl exec` a Pods de *otros* equipos aunque las NetworkPolicies estén perfectas.
- Sin NetworkPolicies, el modelo de red por defecto de Kubernetes es **allow-all**: cualquier Pod habla con cualquier Pod en cualquier `namespace`. El aislamiento lógico de `namespaces` no implica aislamiento de red.
- Un container que corre como `root` (UID 0) con una capability como `CAP_SYS_ADMIN` y sin `seccomp` puede escapar por un CVE del runtime hacia el kernel compartido, saltándose *todo* lo anterior.

**El modelo mental correcto es una pila de planos de aislamiento**, cada uno tapando el hueco del siguiente:

| Plano | Mecanismo | Qué contiene | Qué NO contiene |
|---|---|---|---|
| **Organizativo/lógico** | `Namespace`, labels | Nombres, quotas, scoping de RBAC | Tráfico de red, syscalls, kernel |
| **Identidad/autorización** | RBAC, `ServiceAccount` | Quién ejecuta qué acción en la API | Tráfico entre Pods, acceso al kernel |
| **Red** | `NetworkPolicy`, CNI, service mesh | Flujos L3/L4 (y L7 con mesh) | Acceso a la API, syscalls |
| **Recursos** | `ResourceQuota`, `LimitRange` | Agotamiento (noisy neighbor, DoS) | Confidencialidad, integridad |
| **Runtime/kernel** | `securityContext`, capabilities, `seccomp`, AppArmor/SELinux | Superficie de syscalls, privilegios | Nada si el kernel tiene un 0-day |
| **Sandbox** | gVisor, Kata Containers | El kernel mismo (user-space o microVM) | Coste/latencia añadidos |
| **Físico/hard** | `nodeSelector`/taints, node pools dedicados, clusters separados | Co-tenancy en el node/hardware | Overhead de infraestructura |

La regla de producción: **cuanto más hostil el tenant, más abajo hay que bajar en la pila.** Equipos internos de confianza → `Namespace` + RBAC + NetworkPolicy + Pod Security Standards. Ejecución de código arbitrario de terceros (CI/CD de clientes, funciones serverless) → añadir sandbox (gVisor/Kata) y, muy probablemente, **hard multi-tenancy** con clusters o node pools dedicados.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Soft vs. Hard multi-tenancy

| Criterio | Soft multi-tenancy (namespaces) | Hard multi-tenancy (cluster/node pool dedicado) |
|---|---|---|
| Boundary | Lógico (RBAC + NetworkPolicy + PSS) | Físico (kernel/host/control-plane separado) |
| Blast radius de un escape de kernel | Todo el node → potencialmente todo el cluster | Confinado al tenant |
| Coste | Bajo (densidad alta) | Alto (infra ociosa por tenant) |
| Operación | Un control plane, una versión | N clusters que versionar/parchear |
| Caso de uso | Equipos internos, entornos (dev/stg) | SaaS con código de terceros, PCI/regulado |
| Herramientas | vanilla K8s, Capsule, vcluster, HNC | Cluster API, node pools, Karmada |

### 2.2 Sandboxing de runtime

| Tecnología | Modelo de aislamiento | Overhead arranque | Overhead syscall | Compatibilidad | Cuándo usar |
|---|---|---|---|---|---|
| **runc** (default) | Namespaces + cgroups del kernel, kernel compartido | ~ninguno | Nativo | Total | Cargas de confianza |
| **gVisor** (`runsc`) | Kernel en user-space (Sentry) intercepta syscalls | Bajo-medio | Alto (redirección) | ~parcial (algunas syscalls no soportadas) | Ejecución de código no confiable, densidad importante |
| **Kata Containers** | MicroVM ligera por Pod (kernel propio + hypervisor) | Medio-alto | Casi nativo | Alta (kernel real) | Aislamiento fuerte, workloads que hacen syscalls raras |

### 2.3 Aislamiento de red: capa donde se aplica

| Enfoque | Capa | Granularidad | Identidad | Cifrado | Coste operativo |
|---|---|---|---|---|---|
| `NetworkPolicy` (nativo) | L3/L4 | Pod/namespace por label, puerto | IP/label | No | Bajo |
| CNI extendido (Cilium `CiliumNetworkPolicy`) | L3–L7 | Métodos HTTP, DNS, Kafka | Identidad basada en labels (eBPF) | Opcional (WireGuard/IPsec) | Medio |
| Service mesh (Istio `AuthorizationPolicy`) | L7 + mTLS | Identidad SPIFFE, método/path | `ServiceAccount` (SPIFFE ID) | mTLS por defecto | Alto (sidecars/ambient) |

### 2.4 Kernel hardening por Pod

| Control | Qué restringe | Fallo por defecto | Modo recomendado prod |
|---|---|---|---|
| `runAsNonRoot` / `runAsUser` | Corre como no-root | Muchas imágenes corren como UID 0 | `runAsNonRoot: true` |
| `allowPrivilegeEscalation` | `setuid`/`no_new_privs` | `true` | `false` |
| `capabilities` | Capabilities de Linux | runc concede un set default | `drop: ["ALL"]`, añadir mínimo |
| `seccompProfile` | Set de syscalls permitidas | `Unconfined` (histórico) | `RuntimeDefault` o custom |
| AppArmor/SELinux | MAC: paths, operaciones | Depende de distro | Perfil `RuntimeDefault`/custom |
| `readOnlyRootFilesystem` | Escritura en rootfs | `false` | `true` + `emptyDir` para tmp |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Namespace con etiquetas de Pod Security Admission (PSA)

Desde Kubernetes v1.25 los **Pod Security Standards** (`privileged` / `baseline` / `restricted`) se aplican vía el admission controller **Pod Security Admission**, configurado con labels en el `Namespace`. Reemplaza a los difuntos `PodSecurityPolicy`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-payments
  labels:
    # Modo enforce: rechaza Pods que violan el nivel 'restricted'
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.29
    # Audit: registra violaciones en el audit log sin bloquear
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.29
    # Warn: devuelve un warning al usuario en kubectl
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.29
    # Label propia de scoping para NetworkPolicies
    team: payments
    environment: production
```

### 3.2 ResourceQuota + LimitRange (aislamiento de recursos)

Contiene el **noisy neighbor** y el DoS por agotamiento dentro del `namespace`.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-payments-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "100"
    services.loadbalancers: "2"
    persistentvolumeclaims: "20"
    requests.storage: 500Gi
    count/secrets: "50"
    count/configmaps: "50"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: team-payments-limits
  namespace: team-payments
spec:
  limits:
    - type: Container
      default:              # limit por defecto si el container no lo declara
        cpu: 500m
        memory: 512Mi
      defaultRequest:       # request por defecto
        cpu: 100m
        memory: 128Mi
      max:                  # techo por container
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 10m
        memory: 16Mi
    - type: PersistentVolumeClaim
      max:
        storage: 100Gi
      min:
        storage: 1Gi
```

> **Por qué el `LimitRange` importa para la seguridad:** con PSA `restricted` y `ResourceQuota` que exige `limits.cpu`/`limits.memory`, un Pod sin límites sería *rechazado*. El `LimitRange` inyecta defaults para que las cargas legítimas no rompan, cerrando el hueco de "Pod sin límites que consume todo el node".

### 3.3 NetworkPolicy — default-deny y allow explícito

El patrón de producción es **default-deny por namespace** y luego abrir flujos concretos. Requiere un CNI que implemente NetworkPolicy (Calico, Cilium, Antrea, Weave; **el `kubenet` de serie NO lo hace**).

```yaml
# 1) Deny-all de ingress y egress en el namespace completo
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-payments
spec:
  podSelector: {}            # selecciona todos los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# 2) Permitir DNS de salida hacia kube-dns (sin esto, casi todo se rompe)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: team-payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```yaml
# 3) Permitir que 'api' reciba tráfico SOLO del frontend y hable SOLO con la DB
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-ingress-egress
  namespace: team-payments
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

> **Trampa clásica:** un `namespaceSelector` y un `podSelector` en el **mismo** elemento de la lista `from`/`to` se combinan con **AND** (Pods con ese label *dentro* de esos namespaces). Ponerlos como **dos elementos separados** de la lista es **OR**. Confundirlos abre o cierra tráfico sin querer.

### 3.4 CiliumNetworkPolicy con filtrado L7 (identidad + HTTP)

Cuando L3/L4 no basta —p. ej. permitir solo `GET /health` pero no `POST`— se sube a L7 con un CNI que lo soporte:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-restrict
  namespace: team-payments
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/health"
              - method: "POST"
                path: "/v1/payments"
```

### 3.5 Pod endurecido — `securityContext` completo (nivel `restricted`)

Este es el manifiesto que un Pod debe cumplir para pasar PSA `restricted`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-api
  namespace: team-payments
  labels:
    app: api
spec:
  automountServiceAccountToken: false   # no montar el token si no se usa la API
  securityContext:                       # a nivel Pod
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault               # aplica el perfil seccomp por defecto del runtime
  containers:
    - name: api
      image: registry.example.com/api:1.8.3@sha256:abc123...  # pin por digest
      ports:
        - containerPort: 8080
      securityContext:                   # a nivel container (más específico gana)
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]                  # tira todas las capabilities
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp                # rootfs es read-only, escribir en emptyDir
  volumes:
    - name: tmp
      emptyDir: {}
```

### 3.6 Sandboxing con gVisor vía `RuntimeClass`

Para ejecutar código no confiable, se define un `RuntimeClass` que apunta al handler `runsc` (gVisor) y se referencia desde el Pod.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc            # debe existir un [runtimes.runsc] en containerd config.toml
---
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-job
  namespace: tenant-sandbox
spec:
  runtimeClassName: gvisor    # <-- este Pod corre bajo el kernel user-space de gVisor
  nodeSelector:
    sandbox.example.com/gvisor: "true"   # confinar a un node pool con runsc instalado
  containers:
    - name: worker
      image: registry.example.com/untrusted-worker:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
```

### 3.7 RBAC como aislamiento — Role scoped al namespace

RBAC contiene *quién puede hacer qué en la API*, que es un vector de escape lateral tan real como la red.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payments-developer
  namespace: team-payments
rules:
  - apiGroups: ["", "apps"]
    resources: ["pods", "deployments", "services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # NO se conceden: 'delete' de nodes, 'exec', 'secrets' amplios, etc.
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-developer-binding
  namespace: team-payments
subjects:
  - kind: Group
    name: "oidc:team-payments-devs"     # grupo del IdP OIDC
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: payments-developer
  apiGroup: rbac.authorization.k8s.io
```

> **Regla:** usar `Role`/`RoleBinding` (namespaced), no `ClusterRole`/`ClusterRoleBinding`, para tenants. Un `ClusterRoleBinding` rompe el aislamiento del `namespace` de un plumazo, porque aplica a todos.

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar que PSA rechaza un Pod privilegiado

```console
$ kubectl apply -n team-payments -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  containers:
    - name: c
      image: nginx
      securityContext:
        privileged: true
EOF
Error from server (Forbidden): error when creating "STDIN": pods "bad-pod" is forbidden:
violates PodSecurity "restricted:v1.29": privileged (container "c" must not set
securityContext.privileged=true), allowPrivilegeEscalation != false (container "c"
must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "c" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true
(pod or container "c" must set securityContext.runAsNonRoot=true), seccompProfile
(pod or container "c" must set securityContext.seccompProfile.type to "RuntimeDefault"
or "Localhost")
```

### 4.2 Comprobar que existe un default-deny y probar la conectividad

```console
$ kubectl get netpol -n team-payments
NAME                  POD-SELECTOR   AGE
default-deny-all      <none>         3d
allow-dns-egress      <none>         3d
api-ingress-egress    app=api        3d

$ kubectl run tester --image=nicolaka/netshoot -n team-payments --rm -it -- \
    curl -m 3 http://postgres:5432
curl: (28) Connection timed out after 3001 milliseconds
pod "tester" deleted
```

El timeout confirma que el default-deny está activo: `tester` no tiene el label `app: api`, así que la egress a `postgres` está bloqueada.

### 4.3 Auditar RBAC con `kubectl auth can-i`

```console
$ kubectl auth can-i create pods -n team-payments \
    --as=system:serviceaccount:team-payments:default
no

$ kubectl auth can-i --list -n team-payments \
    --as=oidc:alice --as-group=oidc:team-payments-devs
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                            []                  []               [get list watch create update patch]
deployments.apps                                []                  []               [get list watch create update patch]
pods/log                                        []                  []               [get list]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
...

$ kubectl auth can-i delete nodes --as=oidc:alice
no
```

### 4.4 Confirmar que gVisor está realmente aislando el kernel

Dentro de un Pod normal (`runc`), `dmesg`/`uname` muestran el kernel del host. Dentro de gVisor, el kernel es el Sentry:

```console
$ kubectl exec -n tenant-sandbox untrusted-job -- dmesg | head -1
[    0.000000] Starting gVisor...

$ kubectl exec -n tenant-sandbox untrusted-job -- cat /proc/version
Linux version 4.4.0 (gVisor)
```

Comparar con un Pod normal en el mismo node:

```console
$ kubectl exec -n team-payments hardened-api -- cat /proc/version
Linux version 6.6.20-flatcar (@buildhost) #1 SMP ...
```

El kernel reportado distinto prueba que gVisor intercepta las syscalls: el container no ve el kernel 6.6 del host.

### 4.5 Verificar el `securityContext` efectivo y el seccomp aplicado

```console
$ kubectl get pod hardened-api -n team-payments \
    -o jsonpath='{.spec.containers[0].securityContext}' | jq
{
  "allowPrivilegeEscalation": false,
  "capabilities": { "drop": ["ALL"] },
  "readOnlyRootFilesystem": true,
  "runAsNonRoot": true
}

$ kubectl exec -n team-payments hardened-api -- cat /proc/1/status | grep -E 'Seccomp|NoNewPrivs|CapEff'
NoNewPrivs:  1
Seccomp:     2      # 2 = SECCOMP_MODE_FILTER (perfil activo). 0 sería sin filtro.
CapEff:      0000000000000000    # todas las capabilities efectivas en cero
```

### 4.6 Ver el uso de la ResourceQuota

```console
$ kubectl describe resourcequota team-payments-quota -n team-payments
Name:                   team-payments-quota
Namespace:              team-payments
Resource                Used   Hard
--------                ----   ----
count/configmaps        8      50
limits.cpu              6      40
limits.memory           9Gi    80Gi
pods                    14     100
requests.cpu            1200m  20
requests.memory         2304Mi 40Gi
services.loadbalancers  1      2
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Metodología de verificación por plano

| Plano | Pregunta | Comando |
|---|---|---|
| PSA | ¿Se rechazan Pods inseguros? | `kubectl label ns X pod-security.kubernetes.io/warn=restricted` y `kubectl apply` un Pod malo |
| NetworkPolicy | ¿Hay default-deny? | `kubectl get netpol -n X` — debe existir uno con `podSelector: {}` y ambos `policyTypes` |
| NetworkPolicy | ¿Un flujo prohibido falla? | `kubectl run tester --image=netshoot --rm -it -- curl <destino>` |
| RBAC | ¿Un sujeto NO puede escalar? | `kubectl auth can-i <verb> <res> --as=<subject>` |
| Runtime | ¿El seccomp/caps se aplican? | `cat /proc/1/status | grep -E 'Seccomp|CapEff'` |
| Sandbox | ¿gVisor/Kata activo? | `kubectl get pod -o jsonpath='{.spec.runtimeClassName}'` + `cat /proc/version` |
| Quota | ¿Los límites se enforcan? | `kubectl describe resourcequota -n X` |

### 5.2 Fallas comunes y su diagnóstico

**Síntoma: "Apliqué NetworkPolicies pero el tráfico prohibido sigue pasando."**
- Causa #1: el CNI no implementa NetworkPolicy. Verificar: `kubectl get pods -n kube-system | grep -E 'calico|cilium|antrea'`. Un cluster con `flannel` puro o `kubenet` **ignora** las NetworkPolicies silenciosamente — se crean y no hacen nada.
  ```console
  $ kubectl get pods -n kube-system -l k8s-app=cilium
  No resources found in kube-system namespace.
  # -> el objeto NetworkPolicy existe pero nadie lo aplica
  ```
- Causa #2: el DNS se rompió por el default-deny. Los Pods no resuelven nombres → *parece* que "todo está bloqueado" incluso lo permitido. Faltó el `allow-dns-egress` de §3.3.
  ```console
  $ kubectl exec -n team-payments hardened-api -- nslookup postgres
  ;; connection timed out; no servers could be reached
  ```

**Síntoma: "Mi Pod legítimo es rechazado por PSA."**
- Leer el mensaje de `Forbidden` (es exhaustivo, §4.1). Suele faltar `runAsNonRoot`, `seccompProfile: RuntimeDefault` o `capabilities.drop: ["ALL"]`. Diagnóstico previo sin bloquear: poner `warn`/`audit` antes que `enforce` y revisar:
  ```console
  $ kubectl get events -n team-payments --field-selector reason=FailedCreate
  ```

**Síntoma: "El namespace 'aislado' ve procesos/red del host."**
- El Pod usa `hostNetwork`, `hostPID` o `hostIPC`. PSA `baseline`/`restricted` lo prohíbe; si el Pod se creó, es que el `namespace` está en `privileged`. Verificar:
  ```console
  $ kubectl get pod X -o jsonpath='{.spec.hostPID} {.spec.hostNetwork}{"\n"}'
  true true      # <-- fuga de aislamiento
  ```

**Síntoma: "gVisor no arranca el Pod."**
- El node no tiene el handler `runsc` registrado en containerd, o el Pod no cayó en un node con gVisor. Diagnóstico:
  ```console
  $ kubectl describe pod untrusted-job -n tenant-sandbox | grep -A3 Events
  Warning  FailedCreatePodSandBox  ...  failed to get sandbox runtime: no runtime for "runsc" is configured
  ```
  Solución: el `nodeSelector` de §3.6 debe forzar el scheduling al node pool con gVisor, y containerd debe tener `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]`.

**Síntoma: "Un tenant agota el node pese a la ResourceQuota."**
- La `ResourceQuota` limita el `namespace` en agregado, pero si los Pods no declaran `requests`/`limits` y no hay `LimitRange`, el scheduler no puede contabilizar y la quota basada en `requests.cpu` **rechaza** los Pods sin requests. Si en cambio la quota no incluye `requests.*`, un Pod sin límites es best-effort y compite libremente. Verificar que existe `LimitRange` (§3.2):
  ```console
  $ kubectl get limitrange -n team-payments
  NAME                    CREATED AT
  team-payments-limits    2026-08-01T10:00:00Z
  ```

### 5.3 Auditoría continua

- **Provenance de red:** ejecutar periódicamente un job que aplique un Pod `tester` sin labels y verifique que **no** alcanza servicios sensibles (test de regresión de NetworkPolicy).
- **RBAC drift:** `kubectl auth can-i --list --as=<sa>` en CI para cada `ServiceAccount` de tenant; fallar el pipeline si aparecen verbos nuevos.
- **PSA en modo audit** a nivel cluster con `AdmissionConfiguration` para capturar violaciones incluso en namespaces `privileged`, y revisarlas en el audit log del `kube-apiserver`.
- Herramientas de escaneo: **kube-bench** (CIS Benchmark), **kubescape**, **Trivy** (`trivy k8s cluster`) para detectar Pods privilegiados, `hostPath`, tokens automontados y NetworkPolicies faltantes.

```console
$ kubescape scan framework nsa --include-namespaces team-payments
[control: C-0260] Missing network policy       PASS
[control: C-0211] Apply security context       PASS
[control: C-0057] Privileged container         PASS
[control: C-0034] Automatic mapping of SA token FAIL (1 resource)
```

---

## 6. Referencias

- **KCSA Curriculum (CNCF)** — https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Namespaces** — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- **Pod Security Standards** — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- **Pod Security Admission** — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- **Network Policies** — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **Configure a Security Context for a Pod or Container** — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- **Seccomp con Kubernetes** — https://kubernetes.io/docs/tutorials/security/seccomp/
- **AppArmor** — https://kubernetes.io/docs/tutorials/security/apparmor/
- **RuntimeClass** — https://kubernetes.io/docs/concepts/containers/runtime-class/
- **Resource Quotas** — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- **Limit Ranges** — https://kubernetes.io/docs/concepts/policy/limit-range/
- **RBAC Authorization** — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- **Multi-tenancy** — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- **gVisor** — https://gvisor.dev/docs/
- **Kata Containers** — https://katacontainers.io/docs/
- **Cilium Network Policies** — https://docs.cilium.io/en/stable/security/policy/
- **Istio AuthorizationPolicy** — https://istio.io/latest/docs/reference/config/security/authorization-policy/
- **CIS Kubernetes Benchmark / kube-bench** — https://github.com/aquasecurity/kube-bench
- **Kubescape** — https://github.com/kubescape/kubescape