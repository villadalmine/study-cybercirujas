# Tema 2.4 — Kubernetes Security Essentials and Hardening
## Ejercicios guiados de laboratorio

> **Persona del laboratorio:** operás un cluster multi-tenant donde un equipo de aplicación te pide desplegar cargas de terceros que no controlás. Tu trabajo es aplicar *defense in depth*: admission control, hardening del Pod, least privilege y micro-segmentación de red, y saber **diagnosticar** por qué algo es rechazado.

### Requisitos previos

- Un cluster de práctica **descartable** con soporte para Pod Security Admission (Kubernetes ≥ 1.25, GA). `kind` es ideal porque te da acceso al control plane:

```bash
kind create cluster --name cnpa-24 --image kindest/node:v1.31.0
kubectl version --output=json | jq -r '.serverVersion.gitVersion'
# v1.31.0
```

- Un CNI que **implemente NetworkPolicy** para el Ejercicio 4. El CNI por defecto de `kind` (kindnet) **no** aplica NetworkPolicies, así que instalamos Calico o cambiamos el CNI. Verificás el enforcement al final del Ejercicio 4; si no lo tenés, ese ejercicio se vuelve "no-op silencioso" (una trampa clásica de examen).

```bash
# Opción rápida: Calico sobre kind
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
```

- `jq` instalado para parsear salidas JSON.

> **Fuentes oficiales usadas en este tema:**
> - Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
> - Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
> - Configure a Security Context — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
> - RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
> - Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
> - Seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
> - Secrets — https://kubernetes.io/docs/concepts/configuration/secret/

---

## Ejercicio 1 — Pod Security Admission: enforce, audit y warn

El objetivo es entender que **PSA es un admission controller que actúa por namespace mediante labels**, y que aplica los tres **Pod Security Standards**: `privileged` (sin restricciones), `baseline` (bloquea escaladas conocidas) y `restricted` (best practices de hardening).

**Paso 1.** Creá un namespace y etiquetalo con los tres *modos* de PSA apuntando al perfil `restricted`. Cada modo tiene semántica distinta: `enforce` rechaza, `audit` anota en el log de auditoría, `warn` devuelve un warning al cliente pero **admite**.

```bash
kubectl create namespace tenant-a

kubectl label namespace tenant-a \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
# namespace/tenant-a labeled
```

**Paso 2.** Intentá crear un Pod "ingenuo" (sin ningún hardening). Corre como root, no declara seccomp, no restringe capabilities.

```yaml
# naive-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: naive
  namespace: tenant-a
spec:
  containers:
  - name: app
    image: nginx:1.27
    ports:
    - containerPort: 80
```

```bash
kubectl apply -f naive-pod.yaml
```

**Paso 3.** Observá el rechazo. La respuesta enumera **todas** las violaciones a la vez (no falla en la primera):

```text
Error from server (Forbidden): error when creating "naive-pod.yaml": pods "naive" is forbidden:
violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false (container "app" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set
securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set
securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set
securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**Paso 4.** Bajá el `enforce` a `baseline` dejando `warn`/`audit` en `restricted`. Esto es el patrón de **migración gradual**: forzás lo mínimo, pero recibís advertencias de lo que necesitarías para llegar a `restricted`.

```bash
kubectl label --overwrite namespace tenant-a \
  pod-security.kubernetes.io/enforce=baseline
# namespace/tenant-a labeled

kubectl apply -f naive-pod.yaml
```

Salida esperada — **se admite**, pero con warnings:

```text
Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false ...,
unrestricted capabilities ..., runAsNonRoot != true ..., seccompProfile ...
pod/naive created
```

> **Preguntas de comprensión — Bloque 1**
> 1. ¿Por qué `baseline` admite el Pod naive pero `restricted` lo rechaza? Nombrá una violación que `baseline` **sí** bloquearía (que `restricted` también bloquea).
> 2. Un Pod pasa el modo `warn=restricted` pero no aparece en ningún log. ¿Qué modo hay que activar para dejar rastro persistente de las violaciones sin bloquear al usuario, y dónde queda ese rastro?
> 3. Si aplicás el label `enforce` a un namespace que **ya tiene** Pods corriendo que lo violan, ¿esos Pods se terminan (evicted)? Justificá según cómo actúa un admission controller.

---

## Ejercicio 2 — SecurityContext: convertir el Pod naive en `restricted`-compliant

Ahora endurecemos el Pod hasta que pase `enforce=restricted`. Vas a ver que cada campo del `securityContext` mapea 1:1 con una violación del Ejercicio 1.

**Paso 1.** Volvé a subir `enforce` a `restricted` y limpiá el Pod anterior:

```bash
kubectl delete pod naive -n tenant-a --ignore-not-found
kubectl label --overwrite namespace tenant-a \
  pod-security.kubernetes.io/enforce=restricted
```

**Paso 2.** Escribí el Pod endurecido. Notá la diferencia entre `securityContext` a nivel **Pod** (afecta a todos los containers, define `runAsNonRoot`, `seccompProfile`, `fsGroup`) y a nivel **container** (`allowPrivilegeEscalation`, `capabilities`, `readOnlyRootFilesystem`).

```yaml
# hardened-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened
  namespace: tenant-a
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginxinc/nginx-unprivileged:1.27   # escucha en 8080, no requiere root
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

```bash
kubectl apply -f hardened-pod.yaml
# pod/hardened created   (sin warnings)
```

**Paso 3.** Verificá desde *dentro* del container que efectivamente no sos root y que el rootfs es de solo lectura:

```bash
kubectl exec -n tenant-a hardened -- id
# uid=10001 gid=10001 groups=10001

kubectl exec -n tenant-a hardened -- sh -c 'echo test > /etc/probe 2>&1 || echo READONLY_OK'
# sh: can't create /etc/probe: Read-only file system
# READONLY_OK
```

**Paso 4.** Confirmá el seccomp profile efectivo consultando el status del Pod y el proceso en el nodo:

```bash
kubectl get pod hardened -n tenant-a -o jsonpath='{.spec.securityContext.seccompProfile.type}{"\n"}'
# RuntimeDefault
```

**Paso 5 (diagnóstico).** Provocá un fallo deliberado: usá `nginx:1.27` (que necesita bindear el puerto 80, privilegiado) con `runAsNonRoot: true`. Observá que **el admission lo admite** pero el **runtime falla en arranque** — una distinción crítica.

```bash
kubectl run breaker -n tenant-a --image=nginx:1.27 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"breaker","image":"nginx:1.27","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'

kubectl get pod breaker -n tenant-a
# NAME      READY   STATUS             RESTARTS   AGE
# breaker   0/1     CrashLoopBackOff   2          40s

kubectl logs breaker -n tenant-a | tail -3
# ... bind() to 0.0.0.0:80 failed (13: Permission denied)
```

> **Preguntas de comprensión — Bloque 2**
> 1. `readOnlyRootFilesystem: true` rompió nginx hasta que montamos tres `emptyDir`. ¿Por qué esos tres paths específicos, y qué principio de hardening justifica hacer el rootfs inmutable en vez de solo confiar en RBAC?
> 2. En el Paso 5 el Pod fue **admitido** por PSA pero entró en `CrashLoopBackOff`. Explicá por qué PSA no lo rechazó — ¿qué garantiza `runAsNonRoot: true` y qué **no** garantiza sobre el puerto 80?
> 3. `capabilities.drop: ["ALL"]` — si la app necesitara bindear un puerto < 1024 sin correr como root, ¿qué capability única volverías a agregar (`add`), y por qué eso sigue siendo más seguro que `allowPrivilegeEscalation: true`?

---

## Ejercicio 3 — RBAC: least privilege con un ServiceAccount dedicado

Toda carga que habla con la API de Kubernetes debe usar un **ServiceAccount** con permisos mínimos, no el `default`. Acá construimos un SA que solo puede **leer** Pods de su propio namespace, y lo probamos con `kubectl auth can-i`.

**Paso 1.** Creá el ServiceAccount y **desactivá el automount** del token a nivel SA (defense in depth: si un Pod no necesita hablar con la API, no debe recibir credencial).

```yaml
# rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-reader-sa
  namespace: tenant-a
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: tenant-a
rules:
- apiGroups: [""]          # core API group
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: tenant-a
subjects:
- kind: ServiceAccount
  name: pod-reader-sa
  namespace: tenant-a
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f rbac.yaml
```

**Paso 2.** Probá los permisos **sin desplegar nada**, impersonando al SA con `--as`. Esta es la herramienta de diagnóstico central de RBAC:

```bash
kubectl auth can-i list pods -n tenant-a \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
# yes

kubectl auth can-i delete pods -n tenant-a \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
# no

kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
# no

kubectl auth can-i list secrets -n tenant-a \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
# no
```

**Paso 3.** Auditá **qué puede hacer** el SA de forma exhaustiva con `--list`:

```bash
kubectl auth can-i --list -n tenant-a \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
```

```text
Resources          Non-Resource URLs   Resource Names   Verbs
pods               []                  []               [get list watch]
selfsubjectreviews.authorization.k8s.io  []  []          [create]
selfsubjectrulesreviews.authorization.k8s.io  []  []     [create]
```

**Paso 4 (montar la credencial deliberadamente).** Como el SA tiene `automountServiceAccountToken: false`, un Pod que quiera usarlo debe **optar explícitamente**. Desplegá un Pod que lo hace y verificá que el token está presente:

```yaml
# reader-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: tenant-a
spec:
  serviceAccountName: pod-reader-sa
  automountServiceAccountToken: true   # override explícito a nivel Pod
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile: { type: RuntimeDefault }
  containers:
  - name: kubectl
    image: bitnami/kubectl:1.31
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
```

```bash
kubectl apply -f reader-pod.yaml

# Desde el Pod, la API confirma la identidad efectiva:
kubectl exec -n tenant-a reader -- kubectl get pods
# NAME     READY   STATUS    RESTARTS   AGE
# hardened 1/1     Running   0          5m
# reader   1/1     Running   0          20s

kubectl exec -n tenant-a reader -- kubectl get secrets 2>&1 | tail -1
# Error from server (Forbidden): secrets is forbidden: User
# "system:serviceaccount:tenant-a:pod-reader-sa" cannot list resource "secrets" in API group "" in the namespace "tenant-a"
```

> **Preguntas de comprensión — Bloque 3**
> 1. Diferenciá `Role`+`RoleBinding` de `ClusterRole`+`ClusterRoleBinding`. Si necesitaras que `pod-reader-sa` leyera Pods en **todos** los namespaces, ¿qué combinación usarías y por qué NO alcanzaría con cambiar el `RoleBinding`?
> 2. ¿Qué riesgo concreto mitiga `automountServiceAccountToken: false`? Pensá en un container comprometido con RCE y qué encontraría en `/var/run/secrets/kubernetes.io/serviceaccount/`.
> 3. `kubectl auth can-i --list --as=...` — ¿por qué es una mejor herramienta de auditoría que leer los YAML de los Role a mano? ¿Qué agrega que un `grep` sobre los manifiestos no puede darte?

---

## Ejercicio 4 — NetworkPolicy: default-deny y micro-segmentación

Por defecto Kubernetes es **allow-all**: cualquier Pod habla con cualquier Pod. El hardening de red arranca con un **default-deny** por namespace y va abriendo flujos explícitamente.

**Paso 1.** Desplegá dos cargas: un `backend` y un `frontend`, más un `attacker` que no debería tener acceso.

```bash
kubectl create namespace netlab
kubectl label namespace netlab \
  pod-security.kubernetes.io/enforce=baseline

kubectl -n netlab run backend  --image=hashicorp/http-echo --labels=app=backend \
  -- -text="backend-ok" -listen=:5678
kubectl -n netlab run frontend --image=curlimages/curl --labels=app=frontend \
  --command -- sleep 3600
kubectl -n netlab run attacker --image=curlimages/curl --labels=app=attacker \
  --command -- sleep 3600

kubectl -n netlab expose pod backend --port=5678 --name=backend
kubectl -n netlab wait --for=condition=Ready pod --all --timeout=60s
```

**Paso 2.** Probá que **antes** de cualquier policy, tanto `frontend` como `attacker` alcanzan el backend:

```bash
kubectl -n netlab exec frontend -- curl -s --max-time 3 backend:5678
# backend-ok
kubectl -n netlab exec attacker -- curl -s --max-time 3 backend:5678
# backend-ok      <-- allow-all: el atacante también entra
```

**Paso 3.** Aplicá un **default-deny de ingress** para todo el namespace. El `podSelector: {}` selecciona *todos* los Pods; al tener la policy tipo `Ingress` sin reglas `ingress`, todo el ingreso queda denegado.

```yaml
# default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: netlab
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
```

```bash
kubectl apply -f default-deny.yaml

kubectl -n netlab exec frontend -- curl -s --max-time 3 backend:5678 || echo "BLOCKED"
# BLOCKED     <-- ahora hasta el frontend legítimo queda afuera
```

**Paso 4.** Abrí **solo** el flujo `frontend → backend:5678` con una policy que combina `podSelector` (a qué Pods aplica) con `from.podSelector` (quién puede entrar) y `ports`.

```yaml
# allow-frontend.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: netlab
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 5678
```

```bash
kubectl apply -f allow-frontend.yaml

kubectl -n netlab exec frontend -- curl -s --max-time 3 backend:5678
# backend-ok      <-- flujo legítimo restaurado

kubectl -n netlab exec attacker -- curl -s --max-time 3 backend:5678 || echo "BLOCKED"
# BLOCKED         <-- el atacante sigue denegado
```

**Paso 5 (verificar que el CNI realmente aplica).** Este es el chequeo que separa "escribí un YAML" de "el tráfico está bloqueado". Si el atacante en el Paso 4 **no** fue bloqueado, tu CNI no implementa NetworkPolicy:

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node
# si no hay Calico/Cilium/Weave, kindnet NO aplica policies -> el test es un falso verde
```

> **Preguntas de comprensión — Bloque 4**
> 1. En el Paso 3 el `default-deny-ingress` cortó también al `frontend` legítimo. ¿Por qué es correcto (y deseable) que un default-deny rompa el tráfico bueno hasta que agregues allows explícitos? ¿Qué modelo de seguridad representa?
> 2. Las NetworkPolicies son **aditivas** (OR entre policies), no hay `deny` explícito que gane. Si un Pod es seleccionado por dos policies —una que permite `frontend` y otra que permite `monitoring`— ¿quién puede entrar? ¿Y si un Pod **no** es seleccionado por ninguna policy de tipo Ingress?
> 3. La policy del Paso 4 solo controla `Ingress`. Un atacante que comprometió el `backend` quiere exfiltrar datos a Internet. ¿Qué `policyType` adicional necesitás para impedirlo, y por qué el default-deny de ingress no lo cubre?

---

## Ejercicio 5 — Secrets, seccomp Localhost y diagnóstico integrado

**Paso 1 (Secrets: entender que no están cifrados por sí solos).** Creá un Secret y comprobá que en `etcd` va en **base64, no cifrado** — de ahí que el hardening real sea *encryption at rest* + RBAC sobre `secrets`.

```bash
kubectl -n tenant-a create secret generic db-cred \
  --from-literal=password='S3cr3t-P@ss'

kubectl -n tenant-a get secret db-cred -o jsonpath='{.data.password}' | base64 -d
# S3cr3t-P@ss     <-- cualquiera con 'get secret' lo lee en claro
```

**Paso 2.** Verificá que tu `pod-reader-sa` del Ejercicio 3 **no** puede leerlo (RBAC como control primario del acceso a Secrets):

```bash
kubectl auth can-i get secret db-cred -n tenant-a \
  --as=system:serviceaccount:tenant-a:pod-reader-sa
# no
```

**Paso 3 (seccomp Localhost profile).** Más allá de `RuntimeDefault`, podés cargar un perfil seccomp propio. El perfil vive en el nodo bajo `<kubelet-root>/seccomp/` y se referencia por path relativo.

```bash
# En kind, el "nodo" es un container; cargamos el perfil ahí:
docker exec cnpa-24-control-plane mkdir -p /var/lib/kubelet/seccomp/profiles
docker exec cnpa-24-control-plane sh -c 'cat > /var/lib/kubelet/seccomp/profiles/audit.json <<EOF
{ "defaultAction": "SCMP_ACT_LOG" }
EOF'
```

```yaml
# seccomp-localhost.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-audit
  namespace: tenant-a
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
  - name: app
    image: nginxinc/nginx-unprivileged:1.27
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
    volumeMounts:
    - { name: tmp, mountPath: /tmp }
    - { name: cache, mountPath: /var/cache/nginx }
    - { name: run, mountPath: /var/run }
  volumes:
  - { name: tmp, emptyDir: {} }
  - { name: cache, emptyDir: {} }
  - { name: run, emptyDir: {} }
```

```bash
kubectl apply -f seccomp-localhost.yaml
kubectl get pod seccomp-audit -n tenant-a \
  -o jsonpath='{.spec.securityContext.seccompProfile}{"\n"}'
# {"localhostProfile":"profiles/audit.json","type":"Localhost"}
```

**Paso 4 (diagnóstico: leer un rechazo de PSA y traducirlo a fix).** Corré este comando que **fuerza** una violación y practicá leer el mensaje estructurado:

```bash
kubectl run privileged-probe -n tenant-a --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"p","image":"busybox","securityContext":{"privileged":true}}]}}' \
  -- sleep 60
```

```text
Error from server (Forbidden): pods "privileged-probe" is forbidden:
violates PodSecurity "restricted:v1.31": privileged (container "p" must not set securityContext.privileged=true),
allowPrivilegeEscalation != false (...), unrestricted capabilities (...),
runAsNonRoot != true (...), seccompProfile (...)
```

> **Preguntas de comprensión — Bloque 5**
> 1. Un compañero dice "los Secrets de Kubernetes están cifrados". Corregilo con precisión: ¿en qué estado están por defecto en `etcd`, y qué **dos** medidas concretas hacen falta para que un atacante con acceso al disco de `etcd` no los lea?
> 2. El perfil seccomp del Paso 3 usa `SCMP_ACT_LOG`. ¿Qué hace esa acción frente a `SCMP_ACT_ERRNO`, y por qué `LOG` es el modo correcto para *descubrir* qué syscalls necesita una app antes de restringirla?
> 3. En el Paso 4, `privileged: true` disparó **cinco** violaciones distintas de `restricted`. ¿Por qué `privileged: true` es "la madre de todas las violaciones"? Nombrá al menos dos protecciones concretas que un container privileged anula de un solo golpe.

---

## Limpieza

```bash
kind delete cluster --name cnpa-24
```

---

<details>
<summary><strong>Respuestas — desplegá para verificar</strong></summary>

### Bloque 1 — Pod Security Admission

1. **`baseline` vs `restricted`.** `baseline` bloquea escaladas de privilegios *conocidas y explotables* (host namespaces, `privileged`, hostPath, hostPort, capabilities peligrosas más allá del set por defecto, `procMount`, etc.) pero **no** exige best practices de hardening. `restricted` es un superconjunto: además exige `runAsNonRoot`, `allowPrivilegeEscalation=false`, `capabilities.drop:["ALL"]`, `seccompProfile` distinto de `Unconfined`, y volúmenes restringidos. El Pod naive no viola ninguna regla de `baseline` (no pide `privileged` ni hostPath) pero sí las cuatro de hardening de `restricted`. Una violación que **ambos** bloquean: `securityContext.privileged: true`.
2. Hay que activar el modo **`audit`** (`pod-security.kubernetes.io/audit=restricted`). A diferencia de `warn` (que solo devuelve un warning efímero al cliente `kubectl`), `audit` genera una **anotación en el audit log del API server** (`pod-security.kubernetes.io/audit-violations`), que queda persistida donde tengas configurado el audit backend. `warn` es para el humano en la terminal; `audit` es para el registro forense.
3. **No, no se terminan.** PSA es un **admission controller**: solo intercepta operaciones de `create`/`update` que pasan por el API server. Actúa en el *momento de admisión*, no de forma continua sobre Pods ya corriendo. Etiquetar un namespace con `enforce` no re-evalúa la carga existente; los Pods que ya violan la política siguen vivos hasta el próximo `create`/`update` (por ejemplo, cuando un Deployment los recrea). Por eso, al endurecer, se usa primero `warn`/`audit` para descubrir qué se rompería.

### Bloque 2 — SecurityContext

1. **Los tres paths (`/tmp`, `/var/cache/nginx`, `/var/run`)** son exactamente los directorios donde nginx *escribe en runtime*: archivos temporales, la caché de respuestas y el PID/socket. Con `readOnlyRootFilesystem: true` el filesystem raíz de la imagen queda inmutable, así que hay que darle superficies de escritura acotadas vía `emptyDir`. El principio es **inmutabilidad del container**: un rootfs de solo lectura impide que un atacante con RCE deje binarios, modifique configs o instale un implante persistente. RBAC controla *el acceso a la API*; no impide que un proceso comprometido *dentro* del container escriba en su propio disco — son capas ortogonales de defense in depth.
2. PSA valida la **especificación declarada**, no el comportamiento en runtime. `runAsNonRoot: true` garantiza que el kubelet **rechace arrancar** el container si su UID efectivo es 0 — una garantía sobre la *identidad*. No dice nada sobre *qué puertos* la app intenta bindear. nginx como no-root intenta `bind()` al puerto 80, que en Linux es privilegiado (< 1024) y requiere `CAP_NET_BIND_SERVICE`; como dropeamos `ALL` las capabilities, el `bind()` devuelve `EACCES` en runtime → `CrashLoopBackOff`. Admission (estático) y runtime (dinámico) son etapas distintas.
3. La capability es **`CAP_NET_BIND_SERVICE`** (`capabilities.add: ["NET_BIND_SERVICE"]` tras el `drop: ["ALL"]`). Sigue siendo más seguro que `allowPrivilegeEscalation: true` porque otorga *una* capacidad quirúrgica (bindear puertos bajos) sin permitir que el proceso **gane privilegios adicionales** vía binarios setuid/setgid — que es justo lo que habilita `allowPrivilegeEscalation`. Menor superficie, un solo permiso explícito y auditable.

### Bloque 3 — RBAC

1. `Role`/`RoleBinding` son **namespaced**: los permisos y el binding viven en un namespace y solo aplican ahí. `ClusterRole`/`ClusterRoleBinding` son **cluster-wide**. Para leer Pods en *todos* los namespaces necesitás un **`ClusterRole`** (con las reglas sobre `pods`) enlazado por un **`ClusterRoleBinding`**. No alcanza con tocar el `RoleBinding` porque un `RoleBinding`, aun apuntando a un `ClusterRole`, **limita el alcance a su propio namespace** — es el truco de reusar un ClusterRole en un solo namespace, no de expandirlo. El *binding* es lo que define el alcance.
2. Mitiga el **robo de credencial de un container comprometido**. Sin `automount`, en `/var/run/secrets/kubernetes.io/serviceaccount/` **no hay token**; un atacante con RCE no encuentra una credencial de la API para pivotar (enumerar recursos, escalar vía permisos del SA). Con automount activado, ese directorio contiene `token`, `ca.crt` y `namespace`, dándole al atacante exactamente la identidad del Pod contra el API server. La mayoría de las cargas nunca hablan con la API y no deberían portar la credencial.
3. `kubectl auth can-i --list --as=...` consulta el **motor de autorización real** del API server (`SubjectAccessReview`), que evalúa la *unión efectiva* de **todos** los Roles/ClusterRoles enlazados a ese sujeto, incluyendo agregaciones (`aggregationRule`), bindings heredados y ClusterRoles del sistema. Un `grep` sobre los YAML solo ve *un* manifiesto a la vez y no resuelve la composición ni las reglas por defecto — te perdés permisos que llegan por bindings que no estás mirando. Auditás el resultado, no la intención.

### Bloque 4 — NetworkPolicy

1. Es correcto porque un **default-deny** implementa el modelo **allow-list / zero-trust**: nada está permitido salvo lo declarado explícitamente. Que rompa el tráfico legítimo es la *señal* de que la política tomó efecto y te obliga a **enumerar y documentar cada flujo real** en vez de asumir conectividad implícita. Lo alternativo (default-allow) deja abiertos flujos que nadie revisó — que es como el atacante alcanza el backend en el Paso 2.
2. Las NetworkPolicies son **puramente aditivas y en modo OR**: no existe una regla `deny` que gane sobre un `allow`. Si dos policies seleccionan al Pod, la **unión** de sus `from` es lo permitido → pueden entrar tanto `frontend` **como** `monitoring`. Y si un Pod **no** es seleccionado por *ninguna* policy de tipo Ingress, queda en el comportamiento por defecto **allow-all** para ingress (nadie lo restringe). Por eso el default-deny debe seleccionar *todos* los Pods (`podSelector: {}`).
3. Necesitás una policy con **`policyTypes: ["Egress"]`** (idealmente un `default-deny-egress` y luego allows explícitos, típicamente permitiendo solo DNS a `kube-dns` y los destinos legítimos). El default-deny de **ingress** solo controla el tráfico *entrante* hacia los Pods; la exfiltración es tráfico *saliente* desde el backend hacia Internet, que ingress no toca. Ingress y egress se controlan por separado.

### Bloque 5 — Secrets, seccomp y diagnóstico

1. Por defecto los Secrets se almacenan en `etcd` **codificados en base64, sin cifrar** — base64 es *encoding*, no *encryption*, y se revierte con un comando. Las dos medidas: **(a) EncryptionConfiguration at rest** en el API server (`--encryption-provider-config`, idealmente con un KMS provider externo en vez de `aescbc` con clave local), para que lo escrito en el disco de `etcd` esté cifrado; y **(b) RBAC restrictivo sobre el recurso `secrets`** (verbo `get`/`list`), más idealmente `etcd` con TLS y disco cifrado. Sin (a), quien lea el disco de `etcd` obtiene el secreto; sin (b), cualquier SA con `get secret` lo lee vía API.
2. `SCMP_ACT_LOG` **permite ejecutar la syscall pero la registra** en el audit/kernel log, mientras que `SCMP_ACT_ERRNO` la **bloquea** devolviendo un error al proceso. `LOG` es el modo correcto para *descubrimiento* porque te deja observar qué syscalls usa realmente la aplicación **sin romperla** — armás el inventario, y recién entonces construís un perfil restrictivo (`ERRNO`/`SCMP_ACT_ALLOW` con allowlist) que deniega todo lo demás. Restringir a ciegas rompe la app; `LOG` primero, `ERRNO` después.
3. `privileged: true` es "la madre de todas las violaciones" porque **desactiva de un solo flag casi todos los aislamientos del container runtime**. Entre lo que anula: (a) el **filtrado de capabilities** — el proceso obtiene *todas* las Linux capabilities (equivale a root en el host); (b) el **seccomp profile** — no se aplica ninguno; (c) el acceso **a todos los devices del host** (`/dev`) y a montar filesystems; (d) implica `allowPrivilegeEscalation` efectivo. Por eso dispara simultáneamente las violaciones de `privileged`, `capabilities`, `allowPrivilegeEscalation`, `runAsNonRoot` y `seccompProfile`: cada una es una protección que `privileged` derriba. Un container privileged comprometido es, en la práctica, un compromiso del **nodo**.

</details>