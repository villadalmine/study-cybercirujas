# 4.1 Kubernetes Trust Boundaries and Data Flow

> **Dominio KCSA:** Kubernetes Threat Model · **Peso:** 2.29
> **Perfil:** Este tema es la base conceptual de todo el modelado de amenazas del examen. No se aprende de memoria: se aprende dibujando el cluster, marcando dónde cambia el nivel de confianza y siguiendo el dato sensible (un `Secret`, un token de ServiceAccount, una credencial de cloud) a través de cada cruce.

---

## 1. Motivación: por qué el "trust boundary" es la unidad de análisis

Un **trust boundary** (frontera de confianza) es cualquier punto donde un dato o un flujo de ejecución cambia de nivel de privilegio o de dominio de control. En un monolito clásico había pocas: usuario ↔ aplicación, aplicación ↔ base de datos. En Kubernetes hay una **docena de fronteras internas**, muchas de ellas invisibles en el `kubectl get pods`, y cada una es un lugar donde un atacante intenta *pivotar* de un nivel de confianza bajo a uno alto.

El problema arquitectónico de producción es este: **Kubernetes es, por diseño, un plano de control que ejecuta código arbitrario de terceros (los contenedores) sobre un kernel compartido, orquestado por una API con permisos de root sobre toda la flota.** Si no se sabe con precisión qué componente confía en qué otro y sobre qué canal, no se puede razonar sobre el radio de explosión (*blast radius*) de un compromiso.

Tres afirmaciones que el modelo de amenazas oficial de Kubernetes deja explícitas y que hay que interiorizar:

1. **etcd es la corona.** Quien lee etcd lee todos los `Secrets`, todos los tokens, toda la configuración. No hay RBAC dentro de etcd: es un almacén clave-valor plano. El único control es *quién puede hablar TCP con etcd* y *si el contenido está cifrado en reposo*.
2. **El límite contenedor↔host es un límite de kernel, no de hipervisor.** Un contenedor comprometido comparte el kernel con el nodo. Una vulnerabilidad de kernel o un `securityContext` laxo convierte "compromiso de pod" en "compromiso de nodo", y un nodo corre el kubelet, que tiene credenciales.
3. **La red de pods es plana por defecto.** Sin `NetworkPolicy`, todo pod alcanza a todo pod y a todo endpoint del control plane y del cloud metadata service. El aislamiento de red *no existe* hasta que se lo declara.

El objetivo de este tema es que, ante cualquier escenario del examen ("un atacante ejecuta código en un pod, ¿qué alcanza?"), puedas trazar el grafo de confianza mentalmente.

---

## 2. El mapa de fronteras de confianza

### 2.1 Diagrama de componentes y fronteras

Cada línea `═══` marca un trust boundary. El texto sobre la línea es el control que la defiende.

```
                          CLIENTES EXTERNOS
              (kubectl, CI/CD, dashboards, humanos)
                              │
              ══ TB-1 ══ AuthN (TLS/OIDC/token) + AuthZ (RBAC) + Admission ══
                              │
        ┌─────────────────────▼──────────────────────┐
        │                  CONTROL PLANE              │
        │                                             │
        │   kube-apiserver ◄──── scheduler            │
        │        │      ▲   ◄──── controller-manager  │
        │        │      │                             │
        │  ══ TB-2 ══ mTLS + encryption-at-rest ══    │
        │        │      │                             │
        │        ▼      │                             │
        │      etcd (estado del cluster, Secrets)     │
        └────────┬──────┬─────────────────────────────┘
                 │      │
     ══ TB-3 ══ mTLS + Node Authorizer + NodeRestriction ══
                 │      │
        ┌────────▼──────▼─────────────────────────────┐
        │                WORKER NODE                  │
        │                                             │
        │   kubelet ──TB-4── CRI (containerd/CRI-O)   │
        │      │                    │                 │
        │      │           ══ TB-5 ══ seccomp/AppArmor│
        │      │             /caps/userns (kernel) ══ │
        │      ▼                    ▼                 │
        │  kube-proxy         ┌──────────┐            │
        │  (iptables/IPVS)    │   POD A   │           │
        │                     │ ┌──────┐  │           │
        │        ══ TB-7 ══   │ │cnt 1 │  │ ◄TB-6► shared netns/IPC
        │      NetworkPolicy  │ │cnt 2 │  │           │
        │        (CNI) ══     │ └──────┘  │           │
        │            │        └──────────┘            │
        │            │             POD B ...          │
        └────────────┼───────────────────────────────┘
                     │
      ══ TB-8 ══ egress NetworkPolicy / metadata proxy ══
                     │
              169.254.169.254  (CLOUD METADATA / IAM)
```

### 2.2 Enumeración formal de las fronteras

| ID | Frontera | Canal / mecanismo | Control primario | Qué gana el atacante si la cruza |
|----|----------|-------------------|------------------|----------------------------------|
| TB-1 | Cliente externo ↔ API server | HTTPS :6443 | AuthN (cert/OIDC/token), RBAC, Admission | Capacidad de crear/leer objetos según el rol robado |
| TB-2 | API server ↔ etcd | gRPC/TLS :2379 | mTLS + `EncryptionConfiguration` | **Todo**: lectura directa de Secrets y estado, escritura arbitraria |
| TB-3 | Control plane ↔ kubelet | HTTPS :10250 (bidireccional) | mTLS, Node Authorizer, `NodeRestriction` | `exec`/`logs`/`port-forward` en cualquier pod del nodo |
| TB-4 | kubelet ↔ container runtime | gRPC sobre Unix socket (CRI) | Permisos del socket (`/run/containerd/containerd.sock`) | Crear contenedores privilegiados = root en el nodo |
| TB-5 | Contenedor ↔ kernel del host | syscalls | seccomp, AppArmor/SELinux, capabilities, user namespaces | Escape de contenedor → root del nodo |
| TB-6 | Contenedor ↔ contenedor (mismo pod) | netns/IPC/volúmenes compartidos | Es un límite **débil** por diseño | Un sidecar comprometido ve el tráfico y los volúmenes del pod |
| TB-7 | Pod ↔ Pod / Namespace | red CNI | `NetworkPolicy` | Movimiento lateral E-W a cualquier servicio no aislado |
| TB-8 | Pod ↔ Cloud metadata / IAM | HTTP a 169.254.169.254 | egress policy, IMDSv2, proxy | Credenciales IAM del nodo → escape del cluster al cloud |

**Punto de examen recurrente:** ordená estas fronteras por *radio de explosión*. TB-2 (etcd) y TB-4 (runtime socket) son los cruces catastróficos — ambos entregan el nodo o el cluster completo. TB-7 (red) es de movimiento lateral, no de escalada vertical inmediata.

---

## 3. Data flow: seguir el dato sensible

El modelado de amenazas no analiza componentes en el vacío, sino **flujos de datos que cruzan fronteras**. El dato más sensible del cluster es el `Secret` y su primo, el token de ServiceAccount. Sigámoslo.

### 3.1 Ciclo de vida de un Secret

```
1. kubectl apply secret ──TB-1──► API server
2. API server ──(admission, validación)──► serializa
3. API server ──TB-2──► etcd   [aquí decide: ¿cifrado en reposo o texto plano?]
4. Pod se programa en nodo N
5. kubelet(N) ──TB-3──► API server: "dame el Secret X para el pod Y"
6. API server ──TB-2──► etcd: lee, descifra
7. API server ──TB-3──► kubelet(N): entrega el Secret por mTLS
8. kubelet ──► monta en tmpfs (RAM) dentro del contenedor
9. proceso del contenedor lee el archivo montado
```

Observaciones críticas de producción:

- **En el paso 3, si no hay `EncryptionConfiguration`, el Secret queda en etcd en base64 (que NO es cifrado).** Un backup de etcd, un snapshot de disco o acceso al puerto 2379 lo expone en claro.
- **El kubelet solo recibe los Secrets de los pods que corren en su nodo** — eso lo garantiza el `NodeRestriction` admission plugin junto al Node Authorizer. Sin ellos, un kubelet comprometido podría pedir *cualquier* Secret del cluster.
- **El Secret se monta en tmpfs**, no toca el disco del nodo. Pero es legible por todo proceso del contenedor y por cualquier sidecar del mismo pod (TB-6).
- **El token de ServiceAccount es un Secret que viaja de vuelta hacia arriba:** desde el pod, atraviesa TB-1 para autenticarse contra la API. Un pod comprometido con un SA sobreprivilegiado convierte TB-5/TB-7 en TB-1 con permisos.

### 3.2 Tabla de datos sensibles y sus fronteras

| Dato | Nace en | Reposa en | Cruza fronteras | Amenaza STRIDE dominante |
|------|---------|-----------|-----------------|--------------------------|
| `Secret` (app) | Cliente/API | etcd (tmpfs en pod) | TB-1, TB-2, TB-3 | Information Disclosure |
| Token de ServiceAccount | API (auto) | tmpfs del pod | TB-3, luego TB-1 al usarse | Elevation of Privilege |
| Certificados de componentes | PKI del cluster | disco del nodo/control plane | TB-2, TB-3 | Spoofing |
| Credenciales IAM del cloud | Metadata service | memoria del kubelet/pod | TB-8 | Elevation of Privilege (fuera del cluster) |
| Estado de objetos (Deployments, etc.) | API | etcd | TB-2 | Tampering |

---

## 4. Modelo STRIDE aplicado a las fronteras

El examen espera que conectes cada frontera con las categorías de amenaza. STRIDE = **S**poofing, **T**ampering, **R**epudiation, **I**nformation disclosure, **D**enial of service, **E**levation of privilege.

| Frontera | S | T | R | I | D | E | Mitigación principal |
|----------|---|---|---|---|---|---|----------------------|
| TB-1 API | ✔ | ✔ |   |   | ✔ | ✔ | RBAC mínimo, audit log, rate limiting |
| TB-2 etcd |   | ✔ |   | ✔ |   | ✔ | mTLS + encryption at rest + firewall :2379 |
| TB-3 kubelet | ✔ | ✔ |   | ✔ |   | ✔ | Node Authorizer + NodeRestriction |
| TB-5 kernel |   | ✔ |   | ✔ |   | ✔ | seccomp `RuntimeDefault`, drop caps, no privileged |
| TB-7 red pod | ✔ |   |   | ✔ | ✔ |   | NetworkPolicy default-deny |
| TB-8 metadata |   |   |   | ✔ |   | ✔ | egress deny a 169.254.169.254, IMDSv2 |

---

## 5. Endurecer cada frontera: manifiestos e infraestructura

Los manifiestos siguientes son completos y sintácticamente válidos. Cada uno defiende una frontera concreta.

### 5.1 TB-2 — Encryption at rest para etcd

Archivo consumido por el flag `--encryption-provider-config` del kube-apiserver. Este manifiesto usa el provider `aescbc` con fallback a `identity` para migración progresiva.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      # El PRIMER provider que aparece se usa para ESCRIBIR.
      - aescbc:
          keys:
            - name: key1
              # 32 bytes en base64: openssl rand -base64 32
              secret: c2VjcmV0LXRyZWludGF5ZG9zLWJ5dGVzLWFlcy1jYmMta2V5MDE=
      # 'identity' permite LEER objetos aún no cifrados (migración).
      - identity: {}
```

Y el flag correspondiente en el manifiesto estático del API server:

```yaml
# fragmento de /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
        - --encryption-provider-config-automatic-reload=true
        # Cierre de otras fronteras del control plane:
        - --anonymous-auth=false
        - --authorization-mode=Node,RBAC
        - --enable-admission-plugins=NodeRestriction
        - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
      volumeMounts:
        - name: enc
          mountPath: /etc/kubernetes/enc
          readOnly: true
  volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
```

> **Producción:** En clusters serios el provider no es `aescbc` con clave en disco, sino `kms` (KMS v2), que delega la clave de cifrado de claves (KEK) a un HSM/cloud KMS externo. Con `aescbc`, la clave vive junto a los datos que protege — mitiga el robo de un backup de etcd, no el compromiso del nodo del control plane.

### 5.2 TB-7 — NetworkPolicy default-deny (ingress y egress)

La primera política de todo namespace productivo. Sin un selector vacío que niegue todo, la red es plana.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}          # selecciona TODOS los pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # Sin reglas ingress/egress => se niega todo en ambos sentidos.
```

Luego se abre lo mínimo. Ejemplo: el pod `api` puede recibir del `frontend` y solo puede salir hacia el DNS del cluster y hacia `db`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-allow
  namespace: payments
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
    # DNS (imprescindible o falla toda resolución)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Solo la base de datos
    - to:
        - podSelector:
            matchLabels:
              app: db
      ports:
        - protocol: TCP
          port: 5432
```

### 5.3 TB-8 — Bloqueo del cloud metadata service

Frontera crítica en cloud gestionado: un SSRF o RCE en un pod que alcanza `169.254.169.254` roba las credenciales IAM del nodo. Se bloquea con egress policy a nivel de CIDR (requiere un CNI que soporte `ipBlock`, p. ej. Calico/Cilium).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32   # IMDS AWS/GCP/Azure
              - 169.254.170.2/32     # ECS task metadata
```

### 5.4 TB-5 — securityContext que endurece la frontera contenedor↔kernel

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened
  namespace: payments
spec:
  automountServiceAccountToken: false   # no entregar token si el pod no llama a la API
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault              # bloquea syscalls peligrosas por defecto
  containers:
    - name: app
      image: registry.example.com/app@sha256:<digest>
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]                 # ninguna capability de Linux
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "256Mi" }
```

### 5.5 TB-3 — Configuración del kubelet que cierra la frontera nodo↔control plane

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false          # sin esto, :10250 acepta peticiones sin credencial
  webhook:
    enabled: true           # delega AuthN de tokens al API server
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook             # delega AuthZ a la API (SubjectAccessReview); NO 'AlwaysAllow'
readOnlyPort: 0            # cierra el puerto :10255 de solo lectura (fuga de info sin auth)
```

---

## 6. Comandos CLI: demostrar y verificar las fronteras

### 6.1 Demostrar TB-2: leer un Secret directo de etcd

Este es el ejercicio que fija el concepto de por qué etcd es la corona. Primero, **sin** cifrado en reposo:

```console
$ kubectl create secret generic demo --from-literal=password='S3cr3t-Pr0d!'
secret/demo created

$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/default/demo | hexdump -C | head
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 64 65 6d 6f 0a 6b  |s/default/demo.k|
...
000000a0  53 33 63 72 33 74 2d 50  72 30 64 21 0a 12 04 6b  |S3cr3t-Pr0d!...k|
```

El string `S3cr3t-Pr0d!` aparece **en texto plano**. Ahora, con `EncryptionConfiguration` activo y tras re-cifrar los objetos existentes:

```console
$ kubectl get secrets --all-namespaces -o json \
    | kubectl replace -f -            # reescribe todos los Secrets => se cifran
secret/demo replaced
...

$ sudo ETCDCTL_API=3 etcdctl ... get /registry/secrets/default/demo | hexdump -C | head
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000020  6b 38 73 3a 65 6e 63 3a  61 65 73 63 62 63 3a 76  |k8s:enc:aescbc:v|
00000030  31 3a 6b 65 79 31 3a ...                          |1:key1:.........|
```

Ahora el prefijo es `k8s:enc:aescbc:v1:key1:` y el resto es ciphertext. La cadena de la contraseña ya no aparece. **Ese diff es la frontera TB-2 defendida.**

### 6.2 Verificar TB-1: ¿acepta la API peticiones anónimas?

```console
$ curl -k https://127.0.0.1:6443/api/v1/namespaces/kube-system/secrets
{
  "kind": "Status",
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\"",
  "reason": "Forbidden",
  "code": 403
}
```

`403` con `system:anonymous` = la petición se autenticó como anónima pero RBAC la rechazó. Un `401` sería mejor (`--anonymous-auth=false`). Si vieras un `200`, la frontera está abierta.

### 6.3 Verificar TB-3: ¿el kubelet acepta peticiones sin autenticar?

```console
$ curl -sk https://<NODE_IP>:10250/pods/
Unauthorized

$ curl -sk https://<NODE_IP>:10255/pods/ | head -c 40
curl: (7) Failed to connect to <NODE_IP> port 10255: Connection refused
```

`Unauthorized` en :10250 y `Connection refused` en :10255 (`readOnlyPort: 0`) = frontera cerrada. Si :10250 devolviera JSON de pods sin credencial, `anonymous.enabled` está en `true` — hallazgo crítico.

### 6.4 Verificar TB-7: probar el aislamiento de red

```console
$ kubectl run probe --rm -it --image=nicolaka/netshoot -n payments -- \
    curl -m 3 http://api.payments.svc:8080/health
curl: (28) Connection timed out after 3001 milliseconds
pod "probe" deleted
```

Timeout = la `default-deny` está bloqueando el pod efímero, que no tiene el label `app: frontend`. Éxito. Si respondiera `200 OK`, la red sigue plana.

### 6.5 Verificar TB-8: ¿alcanza el pod el metadata service?

```console
$ kubectl exec -n payments deploy/api -- \
    curl -s -m 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/
command terminated with exit code 28
```

Exit 28 (timeout) = egress a IMDS bloqueado. Si devolviera el nombre del rol IAM, un RCE en ese pod escalaría al cloud.

### 6.6 Inspeccionar el token de ServiceAccount montado (el dato que sube por TB-1)

```console
$ kubectl exec -n payments deploy/api -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d. -f2 | base64 -d
{"aud":["https://kubernetes.default.svc"],"exp":1785000000,
 "iss":"https://kubernetes.default.svc","kubernetes.io":{"namespace":"payments",
 "serviceaccount":{"name":"api"}},"sub":"system:serviceaccount:payments:api"}
```

El `sub` es la identidad con la que ese pod cruza TB-1. Verificá qué puede hacer:

```console
$ kubectl auth can-i --list \
    --as=system:serviceaccount:payments:api -n payments
Resources   Non-Resource URLs   Resource Names   Verbs
configmaps  []                  []               [get list]
secrets     []                  [db-credentials] [get]
```

Este SA solo puede leer un Secret nominal. Si apareciera `secrets [*] [get list]` o `*.* [*]`, un pod comprometido sería un compromiso de namespace.

---

## 7. Comparativa de trade-offs: aislamiento vs. costo

### 7.1 Fuerza de aislamiento por tecnología de frontera

| Frontera | Aislamiento débil | Aislamiento fuerte | Costo del fuerte |
|----------|-------------------|--------------------|--------------------|
| TB-5 kernel | contenedor estándar (namespaces) | gVisor / Kata Containers (microVM) | +latencia syscall, densidad menor |
| TB-6 pod | un pod multi-contenedor | pods separados | pierde comunicación por localhost/volumen |
| TB-7 red | red plana | NetworkPolicy default-deny + mTLS (mesh) | complejidad operativa, debugging E-W |
| Multi-tenancy | namespaces (soft) | clusters/nodos dedicados (hard) | costo de infra × N tenants |
| TB-2 etcd | base64 en etcd | KMS v2 + HSM | dependencia externa, latencia de encrypt |

**Concepto de examen — soft vs hard multi-tenancy:** el namespace es una frontera *administrativa* (RBAC, quotas, políticas), **no** una frontera de kernel. Dos tenants en el mismo nodo comparten el kernel (TB-5) y el kubelet. "Soft multi-tenancy" asume que los tenants no son adversarios activos. Si lo son, la única frontera real es un nodo o cluster dedicado, o un runtime sandboxed (gVisor/Kata) que reintroduce una frontera de tipo hipervisor.

### 7.2 Contenedor vs. VM: la frontera fundamental

| Propiedad | Contenedor (namespaces) | microVM (Kata/Firecracker) |
|-----------|-------------------------|----------------------------|
| Frontera | syscall al kernel compartido | hypercall a hipervisor |
| Superficie de ataque | todo el kernel de Linux (~400 syscalls) | interfaz de dispositivos virtio (mínima) |
| Radio de un 0-day de kernel | todos los pods del nodo | solo la microVM afectada |
| Overhead de arranque | ~ms | ~100 ms |
| Densidad | alta | media |

---

## 8. Guía de verificación y diagnóstico de fallas

### 8.1 Checklist de fronteras (auditoría rápida)

```console
# TB-1: anonymous auth desactivado
$ ps aux | grep kube-apiserver | grep -o 'anonymous-auth=[a-z]*'
anonymous-auth=false

# TB-1: authorization-mode incluye RBAC (no AlwaysAllow)
$ ps aux | grep kube-apiserver | grep -o 'authorization-mode=[A-Za-z,]*'
authorization-mode=Node,RBAC

# TB-1: NodeRestriction habilitado
$ ps aux | grep kube-apiserver | grep -o 'enable-admission-plugins=[A-Za-z,]*'
enable-admission-plugins=NodeRestriction

# TB-2: encryption config presente
$ ps aux | grep kube-apiserver | grep -c 'encryption-provider-config'
1

# TB-3: kubelet no anónimo
$ sudo grep -A2 anonymous /var/lib/kubelet/config.yaml
  anonymous:
    enabled: false
```

### 8.2 Árbol de diagnóstico de fallas comunes

| Síntoma | Frontera implicada | Causa probable | Verificación |
|---------|--------------------|----------------|--------------|
| Pods no resuelven DNS tras aplicar NetworkPolicy | TB-7 | egress a `kube-system:53` no permitido | Falta la regla UDP/TCP 53 en la policy egress |
| `x509: certificate signed by unknown authority` entre API y etcd | TB-2 | CA de etcd incorrecta | `openssl verify -CAfile ca.crt server.crt` |
| Secret sigue en texto plano tras habilitar encryption | TB-2 | no se re-escribieron los objetos viejos | `kubectl get secrets -A -o json \| kubectl replace -f -` |
| kubelet responde JSON de pods sin credencial | TB-3 | `anonymous.enabled: true` o `readOnlyPort != 0` | `curl -sk https://NODE:10250/pods/` |
| Pod comprometido lista Secrets de otro namespace | TB-1 | SA con `ClusterRole` excesivo o token automontado | `kubectl auth can-i --list --as=system:serviceaccount:...` |
| RCE en pod obtiene credenciales IAM | TB-8 | egress a 169.254.169.254 abierto + IMDSv1 | `kubectl exec ... curl 169.254.169.254` |
| NetworkPolicy "no hace nada" | TB-7 | CNI sin soporte de NetworkPolicy (p. ej. Flannel puro) | Verificá el CNI: Calico/Cilium sí, Flannel no |

### 8.3 Diagnóstico de una NetworkPolicy que no aísla

```console
# 1. ¿El CNI aplica políticas?  (Flannel las ignora silenciosamente)
$ kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|weave'
calico-node-abc12   1/1   Running   ...

# 2. ¿La política selecciona los pods esperados?
$ kubectl get networkpolicy -n payments default-deny-all \
    -o jsonpath='{.spec.podSelector}'
{}

# 3. ¿Qué pods quedan "aislados"? (los que caen bajo ALGUNA policy)
$ kubectl get pod -n payments -o json \
    | jq -r '.items[].metadata.name'
api-7d9f...
frontend-55c...
```

Si el CNI es Flannel, la `NetworkPolicy` se acepta por la API (la CRD existe) pero **nadie la enforcea** — es el falso positivo más peligroso: `kubectl get netpol` muestra la política, la red sigue plana. El control plane la almacena; el data plane la ignora.

### 8.4 Verificar la cadena de certificados de las fronteras del control plane

```console
$ openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt -noout -subject -issuer
subject=CN = kube-apiserver-etcd-client
issuer=CN = etcd-ca

$ openssl verify -CAfile /etc/kubernetes/pki/etcd/ca.crt \
    /etc/kubernetes/pki/apiserver-etcd-client.crt
/etc/kubernetes/pki/apiserver-etcd-client.crt: OK
```

Un `issuer` distinto del CA esperado en TB-2/TB-3 indica una PKI mal armada o, en el peor caso, un certificado emitido por una CA no confiable — spoofing de componente.

---

## 9. Síntesis para el examen

- Un **trust boundary** es donde cambia el nivel de confianza; el análisis de amenazas sigue **flujos de datos** que cruzan esas fronteras, no componentes aislados.
- Memorizá las 8 fronteras y ordenálas por radio de explosión: **etcd (TB-2)** y **runtime socket (TB-4)** son catastróficas; **red (TB-7)** es movimiento lateral; **kernel (TB-5)** convierte pod comprometido en nodo comprometido.
- **etcd no tiene RBAC**: se protege con mTLS, firewall del puerto 2379 y cifrado en reposo. base64 ≠ cifrado.
- El **namespace es una frontera soft** (administrativa), no de kernel. Multi-tenancy hostil exige nodos/clusters dedicados o runtimes sandboxed.
- La **red de pods es plana por defecto**; el aislamiento no existe hasta declarar `NetworkPolicy`, y solo si el CNI la enforcea.
- El **token de ServiceAccount** es el dato que baja por TB-3 y vuelve a subir por TB-1: un SA sobreprivilegiado convierte cualquier RCE de pod en un compromiso de la API.
- La frontera **contenedor↔host es de kernel** (syscalls), no de hipervisor: por eso seccomp, drop de capabilities y `runAsNonRoot` son la primera línea, y gVisor/Kata la reintroducen como frontera fuerte.

---

## 10. Referencias

- Kubernetes — *Security Concepts / The 4C's of Cloud Native Security*: https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes — *Controlling Access to the Kubernetes API*: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes — *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — *Using KMS provider for data encryption*: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Kubernetes — *Kubelet authentication/authorization*: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes — *Using Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Admission Controllers Reference (NodeRestriction)*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — *Restrict a Container's Access to Resources with AppArmor / Seccomp*: https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes — *Configure a Security Context for a Pod or Container*: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- CNCF / Kubernetes SIG-Security — *Kubernetes Threat Model*: https://github.com/kubernetes/sig-security/tree/main/sig-security-docs/papers/threat_model
- CNCF — *Kubernetes Security Audit (WG Security Audit findings, 2019)*: https://github.com/kubernetes/community/tree/master/wg-security-audit
- CNCF — *Cloud Native Security Whitepaper*: https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper
- CNCF — *KCSA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- etcd — *Transport security model*: https://etcd.io/docs/latest/op-guide/security/