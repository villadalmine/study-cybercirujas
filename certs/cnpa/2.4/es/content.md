# Tema 2.4 — Kubernetes Security Essentials and Hardening

> **Certificación:** CNPA (Cloud Native Platform Engineering Associate) · Examen 2025-04-01
> **Dominio 2 · Tema 2.4 · Peso: 4.0**
> Perfil de lectura: SRE Senior / Platform Architect responsable de un Internal Developer Platform (IDP) multi-tenant sobre Kubernetes.

---

## 1. Motivación y el problema arquitectónico de producción

Un IDP existe para que cientos de developers desplieguen sin abrir un ticket. Ese es exactamente el problema de seguridad: estás delegando la capacidad de correr código arbitrario sobre un cluster compartido, con acceso a red, a secretos y —si no lo controlás— al kernel del nodo. La superficie de ataque de Kubernetes no es "el cluster", es **cada `kubectl apply` que un equipo puede ejecutar**.

El error mental clásico del que viene de infra tradicional es pensar en el perímetro. En Kubernetes no hay perímetro: el API server es un plano de control declarativo al que le hablan humanos, CI/CD, controllers y los propios Pods (vía ServiceAccount). Un Pod comprometido con un token de ServiceAccount privilegiado es equivalente a un atacante con `kubectl` de admin. Por eso el modelo mental correcto es el de **defensa en capas**, formalizado por la CNCF como los **4 C del Cloud Native Security**:

```
┌─────────────────────────────────────────────┐
│  Cloud / Co-Lo / Corporate Datacenter        │  ← IAM, VPC, firewall, etcd host
│  ┌───────────────────────────────────────┐   │
│  │  Cluster                              │   │  ← RBAC, PSA, NetworkPolicy, admission
│  │  ┌─────────────────────────────────┐  │   │
│  │  │  Container                     │  │   │  ← image signing, SBOM, non-root
│  │  │  ┌───────────────────────────┐ │  │   │
│  │  │  │  Code                    │ │  │   │  ← TLS, deps, secrets en código
│  │  │  └───────────────────────────┘ │  │   │
│  │  └─────────────────────────────────┘  │   │
│  └───────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

La regla operativa que se deriva: **cada capa debe asumir que la de adentro fue comprometida.** Un contenedor que corre como root no debería poder escalar al nodo; un Pod comprometido no debería poder hablar con la base de datos de otro namespace; un token robado no debería poder listar los Secrets del cluster. El resto del tema es cómo se implementa cada uno de esos "no debería".

El escenario de producción que vamos a hardenizar en este tema es concreto: un cluster multi-tenant donde el `team-payments` corre un microservicio que procesa tarjetas (namespace `payments`, alto valor, PCI), conviviendo con `team-web` (namespace `frontend`, bajo valor, exposición pública). El objetivo: que un compromiso en `frontend` no toque `payments`, y que ningún equipo pueda escalar del contenedor al control plane.

---

## 2. Autenticación, autorización y el API server como único punto de decisión

Toda petición al API server atraviesa una cadena de tres etapas. Entenderla es requisito para diagnosticar cualquier `Forbidden`:

```
Request → [Authentication] → [Authorization] → [Admission Control] → etcd
           ¿quién sos?         ¿podés hacerlo?    ¿el objeto es válido/permitido?
```

- **Authentication** — Kubernetes **no tiene usuarios como objetos**. Un "usuario" es lo que presenta un certificado cliente x509, un OIDC token (ej. Dex, Keycloak, el IdP corporativo) o un ServiceAccount token (JWT). El API server valida el emisor y extrae `username` + `groups`.
- **Authorization** — típicamente **RBAC** (ver §3). Puede haber varios authorizers en cadena (`Node`, `RBAC`, `Webhook`); el primero que dice *allow* gana; si ninguno lo hace, es *deny*.
- **Admission Control** — plugins que pueden **mutar** o **validar/rechazar** el objeto ya autorizado (ver §6).

### 2.1 Modos de autorización — trade-offs

| Modo | Modelo | Granularidad | Cuándo usarlo | Riesgo |
|---|---|---|---|---|
| `AlwaysAllow` | ninguno | — | jamás en prod (solo test aislado) | acceso total |
| `RBAC` | roles + bindings, namespaced/cluster | verbo × recurso × namespace | **default de producción** | mal configurado → over-permission |
| `Node` | especializado para kubelets | fija | siempre activo junto a RBAC | — |
| `ABAC` | policy file estático en el nodo | atributos | legacy; requiere reinicio del apiserver | difícil de auditar, no dinámico |
| `Webhook` | delega a servicio externo (SubjectAccessReview) | arbitraria | integración con IAM externo | latencia/SPOF en el path de auth |

El flag del API server es `--authorization-mode=Node,RBAC`. El orden importa: se evalúan en secuencia hasta el primer allow.

### 2.2 Verificar tus propios permisos: `kubectl auth can-i`

Esta es la herramienta de diagnóstico #1 de RBAC. No adivines los permisos: preguntáselos al API server.

```bash
$ kubectl auth can-i create deployments --namespace payments
no

$ kubectl auth can-i list secrets --namespace payments --as system:serviceaccount:payments:api
no

# Vista completa de lo que puede un sujeto (excelente para auditoría de over-permission)
$ kubectl auth can-i --list --as system:serviceaccount:payments:api -n payments
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authorization.k8s.io         []                  []               [create]
pods                                            []                  []               [get list watch]
configmaps                                      []                  []               [get list watch]
...
```

---

## 3. RBAC — Role-Based Access Control

RBAC es la primera línea del hardening del cluster y donde más se peca por comodidad (dar `cluster-admin` "temporalmente"). Cuatro objetos, dos ejes:

| Objeto | Ámbito | Qué define |
|---|---|---|
| `Role` | namespace | permisos **dentro** de un namespace |
| `ClusterRole` | cluster | permisos cluster-wide **o** plantilla reutilizable por namespace |
| `RoleBinding` | namespace | ata un (Cluster)Role a sujetos **en ese namespace** |
| `ClusterRoleBinding` | cluster | ata un ClusterRole a sujetos **en todo el cluster** |

Regla que confunde a todos: un `RoleBinding` **puede** referenciar un `ClusterRole` — y en ese caso los permisos quedan acotados al namespace del binding. Es el patrón para reutilizar un rol estándar (ej. "read-only") por namespace sin duplicar YAML.

### 3.1 El principio: least privilege, no comodines

El anti-patrón número uno en auditorías reales:

```yaml
# ANTI-PATRÓN — NO HACER. Comodines = auto-privilegio permanente.
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
```

Un `resources: ["*"]` con verb `create` sobre `pods` ya permite montar un Pod con `hostPath: /` y leer el filesystem del nodo. Los comodines anulan el modelo.

### 3.2 Manifiesto completo — ServiceAccount + Role least-privilege

Escenario: el microservicio de pagos necesita **solo leer** ConfigMaps y su propio Secret, y **actualizar** el status de un CRD. Nada más.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
automountServiceAccountToken: false   # ver §5.3 — no montar token si el Pod no llama al API
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payments-api-role
  namespace: payments
rules:
  # Leer configuración
  - apiGroups: [""]                     # "" = core API group
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  # Leer UN secreto específico por nombre (resourceNames acota más)
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["payments-db-credentials"]
    verbs: ["get"]
  # Actualizar el status de su propio CRD
  - apiGroups: ["payments.example.com"]
    resources: ["ledgers/status"]
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-api-binding
  namespace: payments
subjects:
  - kind: ServiceAccount
    name: payments-api
    namespace: payments
roleRef:
  kind: Role
  name: payments-api-role
  apiGroup: rbac.authorization.k8s.io
```

> **Detalle fino:** `resourceNames` **no** funciona con los verbos `list`, `watch`, `create` ni `deletecollection` (esos operan sobre colecciones, no sobre nombres individuales). Restringir un `list` a un nombre no tiene efecto; para eso hace falta admission policy o namespaces separados.

### 3.3 ClusterRole reutilizable con `aggregationRule`

Los ClusterRoles pueden componerse automáticamente por labels. El controller de RBAC recalcula las `rules` uniendo todos los ClusterRoles que matcheen el selector:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-reader
aggregationRule:
  clusterRoleSelectors:
    - matchLabels:
        rbac.example.com/aggregate-to-monitoring: "true"
rules: []   # lo llena el aggregation controller — dejarlo vacío
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-reader-pods
  labels:
    rbac.example.com/aggregate-to-monitoring: "true"
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
```

### 3.4 Diagnóstico de RBAC

```bash
# ¿Qué está atado a cluster-admin? (el hallazgo más común en pentests)
$ kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects // [] | map(.kind+"/"+.name) | join(","))'
cluster-admin -> Group/system:masters
ci-deployer-admin -> ServiceAccount/ci-deployer          # ← sospechoso: revisar

# Ver el Role que resuelve un Forbidden
$ kubectl create deploy nginx --image=nginx -n payments --as=jane
Error from server (Forbidden): deployments.apps is forbidden:
User "jane" cannot create resource "deployments" in API group "apps" in the namespace "payments"

# Auditar tokens de ServiceAccount que sean cluster-admin de facto
$ kubectl get clusterrolebindings -o wide | grep -i admin
```

---

## 4. Pod Security: SecurityContext, Pod Security Standards y Pod Security Admission

Aquí ocurre el salto de capa contenedor→nodo. Un contenedor mal configurado (root, privileged, hostPath, hostPID) rompe el aislamiento y toma el nodo. El hardening tiene dos piezas: **qué le pedís al Pod (SecurityContext)** y **qué le exige el cluster (Pod Security Admission)**.

### 4.1 Historia y trade-off: por qué murió PodSecurityPolicy

| Mecanismo | Estado | Modelo | Problema |
|---|---|---|---|
| **PodSecurityPolicy (PSP)** | **eliminado en v1.25** | admission + RBAC "use" | requería binding RBAC al PSP; orden de evaluación no determinista; imposible de razonar |
| **Pod Security Admission (PSA)** | **GA (built-in) desde v1.25** | label por namespace, 3 niveles | menos granular, pero simple y auditable |
| **OPA Gatekeeper / Kyverno** | externo | políticas arbitrarias (CEL/Rego) | máxima flexibilidad, más operación (ver §6) |

> Si un manifiesto o tutorial usa `apiVersion: policy/v1beta1 kind: PodSecurityPolicy`, está **obsoleto y no aplica en clusters ≥1.25**. Es un error de auditoría frecuente.

### 4.2 Los tres Pod Security Standards

| Nivel | Intención | Bloquea (ejemplos) |
|---|---|---|
| `privileged` | sin restricciones | nada — para infra/CNI/CSI de confianza |
| `baseline` | previene escalada conocida | `privileged`, `hostNetwork`, `hostPID`, `hostPath`, capabilities peligrosas, `hostPorts` |
| `restricted` | best-practice endurecido | además: `runAsNonRoot` obligatorio, `allowPrivilegeEscalation:false`, drop `ALL` caps, `seccompProfile: RuntimeDefault`, root FS mínimo |

### 4.3 Pod Security Admission — activación por namespace (labels)

PSA es un admission controller built-in que se configura **con labels en el Namespace**, en tres modos independientes:

- `enforce` — rechaza Pods que violan el nivel.
- `audit` — permite pero anota en el audit log.
- `warn` — permite pero devuelve un warning a `kubectl`.

El patrón de rollout seguro: primero `warn`+`audit`, medís, después subís a `enforce`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # ENFORCE al máximo nivel
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Redes de seguridad: avisan si algo se cuela por un cambio de nivel
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
```

> **`enforce-version` es un detalle de producción crítico:** fija las reglas del standard a una versión de Kubernetes. Sin él, un upgrade del cluster puede endurecer el standard y rechazar Pods que antes pasaban. Pinnearlo hace que el hardening sea reproducible.

### 4.4 SecurityContext completo — un Deployment que pasa `restricted`

Este es el manifiesto de referencia. Cada campo está justificado:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels: { app: payments-api }
  template:
    metadata:
      labels: { app: payments-api }
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: false
      # --- SecurityContext a nivel Pod ---
      securityContext:
        runAsNonRoot: true            # el kubelet rechaza el arranque si la imagen es root
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001                # ownership de los volúmenes montados
        seccompProfile:
          type: RuntimeDefault        # filtra syscalls peligrosas — obligatorio en restricted
      containers:
        - name: api
          image: registry.example.com/payments/api@sha256:9b2c...e4  # digest, no tag mutable
          ports:
            - containerPort: 8443
          # --- SecurityContext a nivel contenedor (gana sobre el del Pod) ---
          securityContext:
            allowPrivilegeEscalation: false   # bloquea setuid/setgid escalation
            privileged: false
            readOnlyRootFilesystem: true      # el FS raíz es inmutable
            capabilities:
              drop: ["ALL"]                   # tira TODAS las Linux capabilities
              # add: ["NET_BIND_SERVICE"]     # agregar SOLO si bindea a <1024
          resources:                          # límites = defensa contra DoS/noisy neighbor
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
          volumeMounts:
            - name: tmp
              mountPath: /tmp                 # con readOnlyRootFilesystem necesitás emptyDir para escribir
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
```

### 4.5 Verificación y diagnóstico

Comprobar que PSA **realmente** rechaza un Pod inseguro:

```bash
$ kubectl run bad-pod --image=nginx --namespace payments \
    --overrides='{"spec":{"containers":[{"name":"bad-pod","image":"nginx","securityContext":{"privileged":true}}]}}'
Error from server (Forbidden): pods "bad-pod" is forbidden: violates PodSecurity "restricted:v1.30":
  privileged (container "bad-pod" must not set securityContext.privileged=true),
  allowPrivilegeEscalation != false (container "bad-pod" must set securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "bad-pod" must set securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "bad-pod" must set securityContext.runAsNonRoot=true),
  seccompProfile (pod or container "bad-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Verificar en caliente qué usuario corre el contenedor:

```bash
$ kubectl exec -n payments deploy/payments-api -- id
uid=10001 gid=10001 groups=10001

$ kubectl exec -n payments deploy/payments-api -- touch /root/x
touch: cannot touch '/root/x': Read-only file system    # readOnlyRootFilesystem funcionando
```

Fallo típico y su causa raíz: el Pod queda en `CreateContainerError`.

```bash
$ kubectl get pod -n payments
NAME                          READY   STATUS                       RESTARTS   AGE
payments-api-7d9f...          0/1     CreateContainerError         0          12s

$ kubectl describe pod -n payments payments-api-7d9f... | grep -A3 Events
  Warning  Failed  ...  Error: container has runAsNonRoot and image will run as root (uid 0)
```

**Diagnóstico:** la imagen declara `USER root` (o ninguno). `runAsNonRoot: true` es una verificación en runtime del kubelet: si el UID efectivo es 0, no arranca. Solución: `USER 10001` en el Dockerfile, o setear `runAsUser` a un no-cero **que exista/tenga permisos** en la imagen.

---

## 5. Secrets y ServiceAccount tokens

### 5.1 El default inseguro: Secrets en etcd son base64, no cifrado

Un `Secret` sin más configuración se guarda en etcd **codificado en base64**, que no es cifrado. Cualquiera con acceso a etcd (backup, disco, `etcdctl`) los lee en claro.

```bash
$ ETCDCTL_API=3 etcdctl get /registry/secrets/payments/payments-db-credentials | strings | grep -i password
password
Sup3rS3cr3t!                    # ← en claro dentro del snapshot de etcd
```

### 5.2 Encryption at Rest con un provider KMS

Se activa con un `EncryptionConfiguration` pasado al API server vía `--encryption-provider-config`. En producción el provider debe ser **KMS v2** (delega la clave a un HSM/KMS externo: AWS KMS, GCP KMS, Vault), no `aescbc` con clave en disco.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets                       # podés añadir configmaps, y CRDs sensibles
    providers:
      - kms:                          # PRIMER provider = el que se usa para escribir
          apiVersion: v2
          name: vault-kms
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}                  # fallback de lectura para Secrets aún sin cifrar
```

> El **orden importa**: el primer provider cifra las escrituras nuevas; `identity` al final permite leer lo viejo. Tras activarlo, hay que **re-escribir** todos los Secrets para cifrar los existentes:

```bash
$ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
secret/payments-db-credentials replaced
...
# Verificar que quedó cifrado en etcd:
$ ETCDCTL_API=3 etcdctl get /registry/secrets/payments/payments-db-credentials | hexdump -C | head -1
00000000  2f 72 65 67 ... 6b 38 73 3a 65 6e 63 3a 6b 6d 73  |/registry...k8s:enc:kms|
                                                            # prefijo k8s:enc:kms → cifrado OK
```

### 5.3 ServiceAccount tokens: bound tokens y no automontar

Desde v1.24, los tokens de ServiceAccount son **bound service account tokens** por default: JWTs de vida corta, con audience y expiración, proyectados vía `TokenRequest`. Ya **no** se crea un Secret de token permanente automáticamente. Esto reduce drásticamente el valor de un token robado.

Comparativa:

| Token | Vida | Audience | Revocable | Riesgo |
|---|---|---|---|---|
| Legacy (`kubernetes.io/service-account-token` Secret) | infinita | ninguna | no (hasta borrar el Secret) | alto — robado = válido para siempre |
| **Bound / projected** (default ≥1.24) | corta (ej. 1h), auto-rotado | específica | sí (expira, ligado al Pod) | bajo |

**No montar el token si el Pod no llama al API server** (la mayoría de los microservicios no lo hacen). Dos niveles:

```yaml
# A nivel ServiceAccount (afecta a todos los que lo usen)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
automountServiceAccountToken: false
---
# O a nivel Pod (gana sobre el SA)
spec:
  automountServiceAccountToken: false
```

Cuando **sí** necesitás un token, proyectalo explícito con audience y expiración cortas:

```yaml
spec:
  volumes:
    - name: api-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              expirationSeconds: 3600     # rotación cada hora
              audience: payments-internal # el token solo sirve para este consumidor
```

### 5.4 Diagnóstico de Secrets

```bash
# ¿Qué Pods montan el token del SA innecesariamente?
$ kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.automountServiceAccountToken != false)
  | .metadata.namespace + "/" + .metadata.name'

# Confirmar que un Pod hardenizado NO tiene el token montado
$ kubectl exec -n payments deploy/payments-api -- ls /var/run/secrets/kubernetes.io/serviceaccount
ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount': No such file or directory
```

> **External Secrets:** en producción los Secrets rara vez viven "nativos". Se usa el **External Secrets Operator** (ESO) o **Secrets Store CSI Driver** para sincronizar desde Vault/AWS Secrets Manager/GCP SM, de modo que el material sensible nunca esté en un manifiesto ni en Git.

---

## 6. Network Policies — segmentación de red L3/L4

Sin NetworkPolicy, **la red del cluster es plana**: cualquier Pod habla con cualquier Pod, cross-namespace. Es la ruta de lateral movement por excelencia. Un Pod comprometido en `frontend` puede conectarse directo a la base de datos de `payments`.

> **Requisito arquitectónico:** las NetworkPolicy las implementa el **CNI**. Cilium, Calico y Antrea las soportan; **Flannel no**. Aplicar una policy con un CNI que no la implementa no da error — simplemente **no hace nada**. Es una falsa sensación de seguridad clásica.

### 6.1 El patrón fundacional: default-deny por namespace

Una NetworkPolicy es aditiva y **permisiva**: apenas un Pod es seleccionado por *alguna* policy en una dirección, todo lo no permitido explícitamente en esa dirección queda **denegado**. El patrón es empezar con un deny-all y abrir lo necesario.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}                 # {} = TODOS los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # sin reglas ingress/egress = se deniega todo en ambas direcciones
```

### 6.2 Abrir el flujo mínimo

Permitir: (a) que `frontend` llegue al `payments-api` en 8443; (b) que `payments-api` salga solo a Postgres y a DNS.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-payments-api
  namespace: payments
spec:
  podSelector:
    matchLabels: { app: payments-api }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: frontend }
          podSelector:
            matchLabels: { app: web }
      ports:
        - protocol: TCP
          port: 8443
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-payments-api-egress
  namespace: payments
spec:
  podSelector:
    matchLabels: { app: payments-api }
  policyTypes: [Egress]
  egress:
    # DNS — casi siempre olvidado; sin esto, toda resolución falla
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    # Postgres
    - to:
        - podSelector:
            matchLabels: { app: postgres }
      ports:
        - { protocol: TCP, port: 5432 }
```

> **Trampa semántica clave:** un bloque `from`/`to` con `namespaceSelector` **y** `podSelector` en el **mismo elemento de lista** (mismo `-`) significa AND (Pods con ese label **en** ese namespace). Si van como **dos elementos separados** de la lista, es OR (esos Pods en cualquier namespace, o cualquier Pod en ese namespace). Esta diferencia es la causa #1 de policies "que no bloquean lo que creías".

```yaml
# AND: pods app=web SÓLO en el namespace frontend
- from:
    - namespaceSelector: { matchLabels: {kubernetes.io/metadata.name: frontend} }
      podSelector: { matchLabels: {app: web} }
# OR: (cualquier pod en frontend) O (pods app=web en cualquier namespace)  ← ¡mucho más permisivo!
- from:
    - namespaceSelector: { matchLabels: {kubernetes.io/metadata.name: frontend} }
    - podSelector: { matchLabels: {app: web} }
```

### 6.3 Diagnóstico

```bash
# ¿Qué namespaces NO tienen default-deny? (agujeros de segmentación)
$ for ns in $(kubectl get ns -o name | cut -d/ -f2); do
    cnt=$(kubectl get netpol -n $ns --no-headers 2>/dev/null | wc -l)
    [ "$cnt" -eq 0 ] && echo "SIN NetworkPolicy: $ns"
  done
SIN NetworkPolicy: frontend
SIN NetworkPolicy: default

# Probar conectividad esperada vs. bloqueada
$ kubectl run tester --rm -it --image=nicolaka/netshoot -n frontend -- \
    curl -sS --max-time 5 https://payments-api.payments.svc:8443/health
{"status":"ok"}                                      # permitido: OK

$ kubectl run tester --rm -it --image=nicolaka/netshoot -n default -- \
    nc -zv -w5 postgres.payments.svc 5432
nc: connect to postgres.payments.svc port 5432 (tcp) failed: Connection timed out   # bloqueado: OK
```

> **Limitación a tener presente:** las NetworkPolicy de la API estándar son L3/L4 (IP/puerto). Para L7 (paths HTTP, métodos, mTLS de identidad) se necesita un service mesh (Istio/Linkerd `AuthorizationPolicy`) o las `CiliumNetworkPolicy` extendidas.

---

## 7. Admission Control avanzado: policy-as-code

RBAC decide *quién*; PSA decide *el perfil de seguridad del Pod*. Todo lo demás —"toda imagen debe venir de nuestro registry", "todo Pod debe tener límites", "prohibido `latest`"— es dominio del **admission control**.

### 7.1 Trade-offs de las opciones

| Herramienta | Motor | Mutación | Curva | Cuándo |
|---|---|---|---|---|
| **ValidatingAdmissionPolicy** (in-tree, GA 1.30) | **CEL** | no (validación) | baja | reglas simples sin operar un controller externo |
| **MutatingAdmissionPolicy** (in-tree, alpha/beta) | CEL | sí | baja | defaults simples |
| **Kyverno** | YAML/CEL | sí | media | policies como recursos K8s, mutación + generación |
| **OPA Gatekeeper** | Rego | vía plugin | alta | lógica compleja/reutilizable, ecosistema OPA |
| Webhook propio | tu código | sí | alta | lógica arbitraria; sos responsable de HA/latencia |

Un webhook externo caído puede **bloquear todo el cluster** si su `failurePolicy: Fail`. Por eso lo built-in con CEL ganó terreno: sin componente externo en el path.

### 7.2 ValidatingAdmissionPolicy con CEL (sin dependencias externas)

Prohibir imágenes que no vengan del registry corporativo:

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-trusted-registry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: >-
        object.spec.template.spec.containers.all(c,
          c.image.startsWith('registry.example.com/'))
      message: "Todas las imágenes deben provenir de registry.example.com/"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-trusted-registry-binding
spec:
  policyName: require-trusted-registry
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

```bash
$ kubectl apply -f bad-deploy.yaml     # usa docker.io/nginx
The deployments "web" is invalid: ValidatingAdmissionPolicy 'require-trusted-registry'
  denied request: Todas las imágenes deben provenir de registry.example.com/
```

### 7.3 Equivalente en Kyverno (policy como recurso, auditable en Git)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-registry
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Las imágenes deben venir de registry.example.com/"
        pattern:
          spec:
            containers:
              - image: "registry.example.com/*"
```

---

## 8. Supply chain security: firma y verificación de imágenes

Restringir el registry no alcanza si el registry mismo puede ser envenenado. El eslabón siguiente es **verificar la firma criptográfica** de la imagen en admission. El estándar de facto es **Sigstore/cosign**.

```bash
# Firmar (keyless, con OIDC — la identidad queda en el transparency log Rekor)
$ cosign sign registry.example.com/payments/api@sha256:9b2c...e4
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
tlog entry created with index: 84930271

# Verificar
$ cosign verify \
    --certificate-identity=ci@example.com \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    registry.example.com/payments/api@sha256:9b2c...e4
Verification for registry.example.com/payments/api ... OK
The following checks were performed on the signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signatures were verified against the specified certificate identity
```

Y la verificación en admission con Kyverno (rechaza cualquier imagen sin firma válida):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-payments-images
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/payments/*"
          attestors:
            - entries:
                - keyless:
                    subject: "ci@example.com"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

> Complementar con **SBOM** (Software Bill of Materials, ej. `syft`) y **scan de vulnerabilidades** en el pipeline (`trivy`, `grype`). La firma prueba *procedencia*; el SBOM+scan prueba *contenido*. Son ortogonales.

---

## 9. Runtime security: seccomp, AppArmor y detección

Las capas anteriores son preventivas (admission). Falta la **detección en runtime**: un contenedor ya corriendo que hace algo anómalo (spawn de shell, lectura de `/etc/shadow`, conexión saliente rara).

### 9.1 Reducir la superficie del kernel: seccomp

`seccompProfile: RuntimeDefault` (visto en §4.4) aplica el perfil del container runtime, que bloquea ~44 syscalls peligrosas. Para casos de alto valor, un perfil `Localhost` custom:

```yaml
securityContext:
  seccompProfile:
    type: Localhost
    localhostProfile: profiles/payments-restricted.json   # relativo a /var/lib/kubelet/seccomp/
```

### 9.2 Comparativa de mecanismos MAC/kernel

| Mecanismo | Qué controla | Portabilidad | Notas |
|---|---|---|---|
| **seccomp** | syscalls permitidas | universal (Linux) | `RuntimeDefault` es el mínimo recomendado |
| **AppArmor** | acceso a archivos/red por perfil | Debian/Ubuntu/SUSE | campo nativo `securityContext.appArmorProfile` desde v1.30 |
| **SELinux** | labels MAC | RHEL/Fedora/CentOS | vía `seLinuxOptions`; default en OpenShift |
| **Capabilities** | privilegios root granulares | universal | `drop: [ALL]` + add mínimo |

### 9.3 Detección con Falco

Falco es el runtime security engine de la CNCF: consume eventos del kernel (eBPF) y dispara alertas según reglas.

```yaml
# Regla Falco custom
- rule: Shell en contenedor de pagos
  desc: Se abrió una shell interactiva dentro de un Pod de payments
  condition: >
    spawned_process and container
    and k8s.ns.name = "payments"
    and proc.name in (bash, sh, zsh, ash)
  output: >
    Shell abierta en payments (user=%user.name pod=%k8s.pod.name
    cmd=%proc.cmdline image=%container.image.repository)
  priority: WARNING
  tags: [container, shell, mitre_execution]
```

```bash
$ kubectl exec -it -n payments deploy/payments-api -- sh
# → en el stream de Falco:
15:42:07.882 WARNING Shell abierta en payments (user=jane
  pod=payments-api-7d9f... cmd=sh image=registry.example.com/payments/api)
```

---

## 10. Hardening del cluster: CIS Benchmark y kube-bench

Todo lo anterior es carga de trabajo. Falta el **control plane y los nodos**: configuración del API server, kubelet, etcd, permisos de archivos. El estándar es el **CIS Kubernetes Benchmark**, automatizado con **kube-bench**.

```bash
$ kube-bench run --targets master,node --check 1.2.20

[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[FAIL] 1.2.20 Ensure that the --profiling argument is set to false (Automated)
...
== Remediations master ==
1.2.20 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
       and set --profiling=false

== Summary ==
42 checks PASS
3  checks FAIL
7  checks WARN
```

Controles del API server que **no** deben faltar en un cluster de producción:

| Flag | Valor correcto | Por qué |
|---|---|---|
| `--anonymous-auth` | `false` | evita requests sin autenticar |
| `--authorization-mode` | `Node,RBAC` | nunca `AlwaysAllow` |
| `--profiling` | `false` | `/debug/pprof` es superficie de ataque/DoS |
| `--audit-log-path` | seteado | trazabilidad forense |
| `--encryption-provider-config` | seteado | Secrets cifrados (§5.2) |
| `--tls-cipher-suites` | suites fuertes | evita downgrade TLS |
| `--kubelet-certificate-authority` | seteado | valida el cert del kubelet (evita MITM apiserver↔kubelet) |

Y el **audit policy** — sin él no hay forense posible:

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # No logear el spam de watch de los controllers
  - level: None
    verbs: ["watch", "get", "list"]
  # Registrar CUERPO de peticiones a Secrets — evento de máximo valor forense
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  # Todo lo que modifica RBAC, al máximo detalle
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["*"]
  # El resto, metadata
  - level: Metadata
```

---

## 11. Checklist de verificación end-to-end

```bash
# 1. RBAC — ningún SA con cluster-admin no justificado
$ kubectl get clusterrolebindings -o json | \
  jq -r '.items[]|select(.roleRef.name=="cluster-admin")|.subjects[]?|.kind+"/"+.name'

# 2. PSA — todo namespace de app en enforce=restricted
$ kubectl get ns -L pod-security.kubernetes.io/enforce

# 3. Pods privilegiados corriendo AHORA (deuda de seguridad)
$ kubectl get pods -A -o json | jq -r '
  .items[] | select(any(.spec.containers[]; .securityContext.privileged==true))
  | .metadata.namespace+"/"+.metadata.name'

# 4. Namespaces sin NetworkPolicy
$ kubectl get netpol -A

# 5. Secrets cifrados en etcd (buscar prefijo k8s:enc:)
$ ETCDCTL_API=3 etcdctl get /registry/secrets/ --prefix --keys-only | head

# 6. Encryption + audit + authz configurados en el apiserver
$ grep -E 'encryption-provider|audit-log-path|authorization-mode|anonymous-auth' \
    /etc/kubernetes/manifests/kube-apiserver.yaml

# 7. CIS benchmark
$ kube-bench run --targets master,node
```

**Matriz de fallas comunes → causa raíz:**

| Síntoma | Causa raíz probable | Verificación |
|---|---|---|
| `Forbidden` al aplicar un manifiesto válido | RBAC insuficiente para ese sujeto | `kubectl auth can-i ... --as ...` |
| Pod en `CreateContainerError: will run as root` | imagen root + `runAsNonRoot:true` | `USER` en el Dockerfile; `kubectl describe pod` |
| Pod rechazado con "violates PodSecurity" | SecurityContext no cumple el nivel PSA | leer la lista de violaciones del error |
| NetworkPolicy "no bloquea nada" | CNI sin soporte (Flannel) o `AND` vs `OR` mal | probar con netshoot; revisar el CNI |
| DNS roto tras aplicar default-deny egress | falta abrir UDP/TCP 53 a kube-system | `nslookup` desde el Pod |
| Webhook cuelga todos los `apply` | admission webhook externo caído + `failurePolicy:Fail` | `kubectl get validatingwebhookconfigurations` |
| Secret legible en snapshot de etcd | encryption at rest no activado o no re-escrito | `etcdctl get ... \| grep k8s:enc` |

---

## 12. Síntesis arquitectónica

El hardening no es una lista de flags: es la aplicación disciplinada de **least privilege** y **defensa en capas** a cada uno de los 4 C. En el cluster multi-tenant del ejemplo, la postura final combina:

1. **RBAC** least-privilege con ServiceAccount por workload, sin comodines, `cluster-admin` auditado.
2. **PSA `restricted`** enforced y pinneado por versión en todo namespace de aplicación.
3. **SecurityContext** non-root, `readOnlyRootFilesystem`, `drop: [ALL]`, `seccomp RuntimeDefault`.
4. **NetworkPolicy default-deny** + apertura mínima, con CNI que las implemente.
5. **Secrets** cifrados en etcd vía KMS, tokens bound y no automontados, material sensible en un secret manager externo.
6. **Admission** con policy-as-code (CEL/Kyverno) para registry confiable y verificación de firma cosign.
7. **Runtime** con seccomp/AppArmor y detección Falco.
8. **Control plane** validado contra CIS con kube-bench y **audit log** activo.

Cada capa asume que la interior cayó. Esa es la única postura que sobrevive a producción.

---

## Referencias

- Overview of Cloud Native Security (4Cs) — https://kubernetes.io/docs/concepts/security/overview/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Configure a Security Context for a Pod/Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Authorization Overview (modos) — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Authorization: `kubectl auth can-i` — https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access
- Managing Service Accounts / Bound Tokens — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Encrypting Confidential Data at Rest (KMS v2) — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- kube-bench — https://github.com/aquasecurity/kube-bench
- Kyverno Documentation — https://kyverno.io/docs/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Sigstore / cosign — https://docs.sigstore.dev/
- Falco — https://falco.org/docs/
- External Secrets Operator — https://external-secrets.io/latest/
- Secrets Store CSI Driver — https://secrets-store-csi-driver.sigs.k8s.io/
- CNCF Cloud Native Security Whitepaper — https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper
- CNPA Curriculum (fuente del temario) — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf