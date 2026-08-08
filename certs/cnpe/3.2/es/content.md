# Tema 3.2 — Applying RBAC and Security Controls Across Platform Resources

> **Certificación:** Certified Cloud Native Platform Engineer (CNPE) · Dominio 3 · Peso: 3
> **Perfil:** Platform Architect / SRE Senior · Nivel producción

---

## 1. Motivación y el problema arquitectónico de producción

Una plataforma cloud-native no es "un cluster de Kubernetes". Es un **producto interno** sobre el que decenas de equipos hacen self-service: despliegan workloads, crean bases de datos vía Crossplane, sincronizan Applications de Argo CD, piden certificados a cert-manager, y consumen namespaces virtuales. En ese contexto, el control de acceso deja de ser una tabla plana de "quién puede hacer kubectl" y se vuelve el **plano de seguridad transversal** que gobierna *cada recurso de la plataforma*: los core objects de Kubernetes, los CRDs de las herramientas de plataforma, los secretos, y las APIs de las capas superiores (Backstage, Argo CD, la propia IDP).

El problema arquitectónico concreto es este: **la superficie de ataque de una plataforma multi-tenant se define por el least-privilege que puedas *garantizar y demostrar*, no por el que documentes.** Tres fallas recurrentes de producción:

1. **Blast radius por over-privilege.** El anti-patrón número uno es `ClusterRoleBinding` a `cluster-admin` para "el equipo de plataforma" — y después para el CI, y después para el operador que "necesitaba ver todo". Cada binding cluster-wide es un pivote lateral: un token comprometido en un namespace de un tenant no debería poder listar Secrets de otro, ni leer el kubeconfig del control plane.

2. **Privilege escalation por caminos indirectos.** RBAC directo puede ser mínimo, pero si un ServiceAccount puede `create pods`, puede montar *cualquier* otro ServiceAccount de su namespace y heredar sus permisos. Si puede `create` en `roles`/`rolebindings` sin el verbo `escalate`, el API server lo frena — pero si tiene `bind`, puede referenciar un ClusterRole existente más potente. El grafo de escalación es lo que hay que auditar, no las reglas individuales.

3. **La ilusión del control.** RBAC responde "¿este subject puede ejecutar este verbo sobre este recurso?". **No** responde "¿este Pod puede correr como root?", "¿este manifiesto monta el hostPath `/`?", "¿este namespace tiene un default-deny de red?". Esas son responsabilidades de **otros security controls** que se aplican en cadena: *authentication → authorization (RBAC) → admission control (validating/mutating webhooks, Pod Security Admission, policy engines) → runtime*. Confundir RBAC con la política de seguridad completa es el error de diseño más caro.

### La cadena de decisión de una request

```
                                      ┌─────────────────────────────────────────┐
  kubectl / SA token / OIDC  ──────►  │ 1. AUTHENTICATION                        │
                                      │    x509 | Bearer token | OIDC | webhook  │
                                      │    → identidad: user + groups            │
                                      └──────────────────┬──────────────────────┘
                                                         ▼
                                      ┌─────────────────────────────────────────┐
                                      │ 2. AUTHORIZATION (modo chain, OR)        │
                                      │    Node → RBAC → Webhook → (ABAC)        │
                                      │    RBAC: allow-only, aditivo, sin deny   │
                                      └──────────────────┬──────────────────────┘
                                                         ▼ (allow)
                                      ┌─────────────────────────────────────────┐
                                      │ 3. ADMISSION CONTROL                     │
                                      │    Mutating → schema → Validating        │
                                      │    PالسSA · Kyverno/Gatekeeper · webhooks│
                                      └──────────────────┬──────────────────────┘
                                                         ▼
                                                    etcd (persist)
```

RBAC decide **quién toca qué verbo/recurso**. Admission decide **si el objeto resultante cumple la política de seguridad**. Ambos son necesarios; ninguno sustituye al otro. Este tema exige dominar los dos y su composición.

---

## 2. Mecánica interna de RBAC en Kubernetes

RBAC vive en el API group `rbac.authorization.k8s.io/v1`. Cuatro tipos de objeto y una regla mental:

- **`Role`** — permisos **namespaced**. Solo aplica dentro de su namespace.
- **`ClusterRole`** — permisos **cluster-wide** *o* reutilizables. Puede referenciar recursos cluster-scoped (nodes, PVs, namespaces), non-resource URLs (`/healthz`, `/metrics`) y recursos namespaced (para reutilizar la misma definición en muchos namespaces).
- **`RoleBinding`** — asocia subjects a un `Role` **o a un `ClusterRole`**, otorgando sus permisos **solo dentro de un namespace**.
- **`ClusterRoleBinding`** — asocia subjects a un `ClusterRole`, otorgando permisos **en todo el cluster**.

### Anatomía de una regla (`PolicyRule`)

```yaml
rules:
- apiGroups: ["apps"]          # "" = core group; "*" = todos
  resources: ["deployments"]   # plural del recurso; "deployments/scale" = subresource
  resourceNames: ["frontend"]  # opcional: restringe a instancias nombradas (¡solo get/update/etc, NO list/create/deletecollection*!)
  verbs: ["get","list","watch","update","patch"]
- nonResourceURLs: ["/healthz","/metrics"]  # solo válido en ClusterRole
  verbs: ["get"]
```

**Verbos**: `get list watch create update patch delete deletecollection`, más los "especiales": `bind` y `escalate` (sobre roles/clusterroles), `impersonate` (sobre users/groups/serviceaccounts), `approve` (sobre CSRs), `use` (sobre PSPs, deprecado), `sign` (signers de CSR).

**Reglas de evaluación del authorizer** (críticas para el examen):
- RBAC es **puramente aditivo y allow-only**: **no existe una regla de `deny`**. El resultado es la **unión** de todas las reglas de todos los bindings que aplican al subject. Para "quitar" un permiso, se elimina el binding, nunca se agrega un deny.
- El match es **AND dentro de una regla** (apiGroups Y resources Y verbs) y **OR entre reglas**.
- `resourceNames` **no puede restringir `list`, `watch`, `create` ni `deletecollection`** — esos verbos operan sobre la colección, no sobre un nombre; el filtrado por nombre solo tiene sentido en verbos que reciben un objeto concreto (get, update, patch, delete).

### Escalation prevention integrada

El API server impide que crees permisos que vos no tenés:
- **Crear/actualizar un Role/ClusterRole** con permisos que exceden los tuyos → **denegado**, salvo que tengas el verbo `escalate` sobre `roles`/`clusterroles`.
- **Crear un RoleBinding/ClusterRoleBinding** que referencia un role → necesitás el verbo `bind` sobre ese role, o poseer ya todos sus permisos.

Esto evita que un `edit` se auto-promueva a `admin`. Es por diseño y es examinable.

### ClusterRoles agregados

Un `ClusterRole` con `aggregationRule` es **read-only para el humano**: el controlador de RBAC recalcula su `rules` uniendo todos los ClusterRoles que matchean los selectores. Así se extienden los roles built-in `admin`/`edit`/`view` para que cubran tus CRDs sin editar los originales.

### ClusterRoles built-in (memorizar)

| ClusterRole | Alcance típico | Peligro |
|---|---|---|
| `cluster-admin` | superuser, `*/*/*` + nonResourceURLs | total; nunca a tenants |
| `admin` | full read/write namespaced, **incluye gestionar Roles/RoleBindings del namespace**, NO resource quota ni el namespace en sí | puede otorgar permisos dentro del ns |
| `edit` | read/write de la mayoría de objetos, **NO** puede tocar RBAC (desde 1.14 tampoco lee Secrets vía escalación) | apto para devs |
| `view` | read-only, **NO** lee Secrets | apto para observabilidad |

---

## 3. Comparativas técnicas y trade-offs

### 3.1 Las 4 combinaciones binding × role

| Binding | Referencia a `Role` | Referencia a `ClusterRole` |
|---|---|---|
| **`RoleBinding`** | Permisos del Role **en su namespace**. Uso: tenant scoping puro. | Permisos del ClusterRole **limitados a ese namespace**. Uso: aplicar un rol reutilizable (`view`/`edit`) por-namespace. **El patrón más usado en multi-tenancy.** |
| **`ClusterRoleBinding`** | ❌ **Inválido** — un ClusterRoleBinding no puede referenciar un Role namespaced. | Permisos del ClusterRole **en todo el cluster**. Uso: platform-admins, operadores de infra. **Máximo blast radius.** |

**Regla de diseño:** definí los permisos una vez en un `ClusterRole`, y **distribuilos por namespace con `RoleBinding`**. Reservá `ClusterRoleBinding` para lo genuinamente cluster-wide.

### 3.2 Estrategias de aislamiento de tenants

| Estrategia | Aislamiento | Coste operativo | RBAC | Cuándo |
|---|---|---|---|---|
| **Namespace-per-tenant** | Soft (kernel compartido) | Bajo | RoleBinding→ClusterRole por ns | Default para plataformas internas |
| **Namespace + vCluster** | Medio (control plane virtual) | Medio | RBAC propio por vcluster | Tenants que necesitan CRDs/versiones propias |
| **Cluster-per-tenant** | Hard | Alto | Independiente | Aislamiento regulatorio/compliance |
| **Hierarchical Namespaces (HNC)** | Soft + herencia de policy | Medio | RBAC propagado por árbol | Org con sub-equipos y policy heredada |

### 3.3 Modos de autorización

| Modo | Granularidad | Dinámico | Auditable | Uso |
|---|---|---|---|---|
| **RBAC** | verbo × recurso × namespace | Sí (objetos K8s) | Alto | **Estándar de facto** |
| **ABAC** | atributos, archivo estático | No (requiere reinicio) | Bajo | Legacy; evitar |
| **Webhook** | delegado a servicio externo | Sí | Depende | Autz centralizada (ej. IAM cloud) |
| **Node** | kubelet → sus propios objetos | Sí | N/A | Siempre activo, no configurable manualmente |

### 3.4 Enforcement de policy en admission

| Control | Tipo | Lenguaje | Mutación | Fortaleza | Debilidad |
|---|---|---|---|---|---|
| **Pod Security Admission (PSA)** | built-in, por-namespace (labels) | N/A (3 niveles fijos) | No | Sin dependencias, GA | Solo Pods; 3 perfiles rígidos |
| **Kyverno** | webhook (CRD) | YAML declarativo + JMESPath | **Sí** | Curva suave, genera/mutá recursos | Overhead de webhook |
| **OPA/Gatekeeper** | webhook (CRD) | Rego | No | Expresividad, constraint library | Rego tiene curva; mutación es aparte |
| **Validating Admission Policy (VAP)** | built-in (CEL), GA 1.30 | CEL | No | Sin webhook, en-proceso, rápido | Solo validación, sin side-effects |

**Trade-off central:** PSA + VAP cubren el 80% sin webhooks externos (menos latencia, menos SPOF en el admission path). Kyverno/Gatekeeper aportan cuando necesitás *generación* de recursos, mutación compleja o políticas que cruzan varios objetos. En una plataforma madura suelen coexistir: PSA como baseline, VAP para reglas simples cluster-wide, y un policy engine para lo generativo.

---

## 4. Manifiestos completos de producción

### 4.1 Tenant baseline: ServiceAccount + RoleBinding a un ClusterRole reutilizable

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-payments
  labels:
    # Pod Security Admission — se aplica en admission, complementa RBAC
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
    platform.internal/tenant: payments
---
# ServiceAccount de la aplicación (sin token automontado por defecto)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: team-payments
automountServiceAccountToken: false
---
# Los devs del equipo obtienen 'edit' SOLO en su namespace, vía RoleBinding a un ClusterRole built-in
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-devs-edit
  namespace: team-payments
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: "oidc:team-payments-developers"   # grupo proveniente del OIDC IdP
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit                               # definición reutilizable, alcance limitado por el RoleBinding
```

### 4.2 Role de mínimo privilegio para el ServiceAccount de la app (deployment-time)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payments-api-runtime
  namespace: team-payments
rules:
# La app solo lee su propia config y un secret nombrado — nada más
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["payments-db-credentials"]   # scoping por nombre: get/watch, NO list
  verbs: ["get", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create"]                             # publicar eventos de la app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-api-runtime
  namespace: team-payments
subjects:
- kind: ServiceAccount
  name: payments-api
  namespace: team-payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: payments-api-runtime
```

### 4.3 ClusterRole agregado: extender `edit` para que cubra CRDs de plataforma

```yaml
# Este ClusterRole NO se referencia directamente: sus rules se agregan a 'edit'
# gracias al label. Los devs con 'edit' ganan acceso a Certificates sin tocar el built-in.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:aggregate-certmanager-to-edit
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
- apiGroups: ["cert-manager.io"]
  resources: ["certificates", "certificaterequests", "issuers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
# El ClusterRole 'edit' agregado se ve así (read-only, mantenido por el controller):
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: edit
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules: []   # <-- lo llena el aggregation controller; editar acá no persiste
```

### 4.4 ClusterRole para el equipo de plataforma (scoped, NO cluster-admin)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:operator
rules:
# Gestión de namespaces y quotas de tenants
- apiGroups: [""]
  resources: ["namespaces", "resourcequotas", "limitranges"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Gestión de RBAC de tenants — CON restricción: sin 'escalate'
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete", "bind"]
# Observabilidad global (read-only sobre workloads)
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "endpoints", "configmaps"]
  verbs: ["get", "list", "watch"]
# Salud del control plane
- nonResourceURLs: ["/healthz", "/livez", "/readyz", "/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-operators
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: "oidc:platform-sre"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform:operator
```

Nótese: el equipo de plataforma **puede gestionar RBAC de tenants pero no tiene `escalate` ni `*` sobre secrets cluster-wide**. Ese binding a `secrets` global no existe adrede.

### 4.5 Security control complementario: NetworkPolicy default-deny + selectiva

```yaml
# RBAC no gobierna tráfico de red. Este control vive en la capa de admission/CNI.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-payments
spec:
  podSelector: {}                 # todos los pods del namespace
  policyTypes: ["Ingress", "Egress"]
  # sin reglas ingress/egress = deny total
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-from-gateway-and-dns
  namespace: team-payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-system
    ports:
    - { protocol: TCP, port: 8080 }
  egress:
  - to:                            # DNS siempre necesario
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - { protocol: UDP, port: 53 }
    - { protocol: TCP, port: 53 }
```

### 4.6 Kyverno: guardrail que RBAC no puede expresar

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-nonroot-and-block-priv
  annotations:
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce      # rechaza el objeto en admission
  background: true                       # audita también objetos existentes
  rules:
  - name: no-privileged-containers
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "Los containers privileged están prohibidos en esta plataforma."
      pattern:
        spec:
          =(ephemeralContainers):
          - =(securityContext):
              =(privileged): "false"
          containers:
          - =(securityContext):
              =(privileged): "false"
  - name: require-runasnonroot
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "Todos los pods deben declarar runAsNonRoot: true."
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
```

### 4.7 Validating Admission Policy (CEL nativo, sin webhook)

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "block-host-namespaces"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
  validations:
  - expression: "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false"
    message: "hostNetwork está prohibido."
  - expression: "!has(object.spec.hostPID) || object.spec.hostPID == false"
    message: "hostPID está prohibido."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "block-host-namespaces-binding"
spec:
  policyName: "block-host-namespaces"
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        platform.internal/tenant-managed: "true"
```

### 4.8 RBAC sobre recursos de plataforma de capa superior — Argo CD `AppProject`

Las plataformas exponen sus **propios modelos RBAC** sobre sus CRDs. Argo CD no usa RBAC de Kubernetes para sus permisos internos: usa su `AppProject` + su fichero de políticas. Aplicar RBAC "across platform resources" incluye estos planos.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: Proyecto del equipo payments
  sourceRepos:
  - "https://git.internal/payments/*"          # solo sus repos
  destinations:
  - namespace: "team-payments"                  # solo su namespace
    server: "https://kubernetes.default.svc"
  clusterResourceWhitelist: []                  # NO puede crear recursos cluster-scoped
  namespaceResourceBlacklist:
  - group: "rbac.authorization.k8s.io"          # no puede desplegar RBAC vía GitOps
    kind: "Role"
  - group: "rbac.authorization.k8s.io"
    kind: "RoleBinding"
  roles:
  - name: deployer
    description: puede sincronizar, no borrar el proyecto
    policies:
    - "p, proj:payments:deployer, applications, sync, payments/*, allow"
    - "p, proj:payments:deployer, applications, get,  payments/*, allow"
    - "p, proj:payments:deployer, applications, delete, payments/*, deny"
    groups:
    - "oidc:team-payments-developers"
```

---

## 5. Comandos CLI reales y salidas esperadas

### 5.1 La herramienta central: `kubectl auth can-i`

```console
$ kubectl auth can-i create deployments --namespace team-payments
yes

$ kubectl auth can-i delete secrets --namespace kube-system
no

$ kubectl auth can-i '*' '*'
Warning: resource 'apis' is not namespace scoped
no
```

**Impersonation** — verificar los permisos *efectivos de otro subject* sin ser él (requiere el verbo `impersonate`):

```console
$ kubectl auth can-i list secrets \
    --namespace team-payments \
    --as system:serviceaccount:team-payments:payments-api
no

$ kubectl auth can-i get secrets/payments-db-credentials \
    --namespace team-payments \
    --as system:serviceaccount:team-payments:payments-api
yes

$ kubectl auth can-i create pods \
    --namespace team-payments \
    --as-group oidc:team-payments-developers \
    --as devuser@corp.internal
yes
```

### 5.2 Enumerar el permiso efectivo completo de un subject

```console
$ kubectl auth can-i --list \
    --namespace team-payments \
    --as system:serviceaccount:team-payments:payments-api
Resources                                       Non-Resource URLs   Resource Names               Verbs
configmaps                                       []                  []                           [get list watch]
secrets                                          []                  [payments-db-credentials]    [get watch]
events                                           []                  []                           [create]
selfsubjectaccessreviews.authorization.k8s.io    []                  []                           [create]
selfsubjectrulesreviews.authorization.k8s.io     []                  []                           [create]
```

### 5.3 Construir manifiestos con `--dry-run` (idempotente, GitOps-friendly)

```console
$ kubectl create clusterrole tenant-viewer \
    --verb=get,list,watch \
    --resource=pods,services,configmaps \
    --dry-run=client -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  creationTimestamp: null
  name: tenant-viewer
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - services
  - configmaps
  verbs:
  - get
  - list
  - watch

$ kubectl create rolebinding payments-view \
    --clusterrole=tenant-viewer \
    --group=oidc:team-payments-readers \
    --namespace=team-payments \
    --dry-run=client -o yaml | kubectl apply -f -
rolebinding.rbac.authorization.k8s.io/payments-view created
```

### 5.4 Inspeccionar la agregación y los built-in

```console
$ kubectl get clusterrole edit -o jsonpath='{.aggregationRule}' | jq
{
  "clusterRoleSelectors": [
    { "matchLabels": { "rbac.authorization.k8s.io/aggregate-to-edit": "true" } }
  ]
}

$ kubectl get clusterroles -l rbac.authorization.k8s.io/aggregate-to-edit=true
NAME                                            CREATED AT
platform:aggregate-certmanager-to-edit          2026-08-07T11:04:20Z
system:aggregate-to-edit                        2026-08-07T09:00:00Z
```

### 5.5 `SubjectAccessReview` vía API (lo que hace `can-i` por debajo)

```console
$ cat <<'EOF' | kubectl create -o yaml -f -
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:team-payments:payments-api
  resourceAttributes:
    namespace: team-payments
    verb: list
    group: ""
    resource: secrets
EOF
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
...
status:
  allowed: false
  reason: 'RBAC: no binding found that grants list on secrets in team-payments'
```

### 5.6 Diagnóstico de un token de ServiceAccount

```console
$ kubectl create token payments-api --namespace team-payments --duration=10m
eyJhbGciOiJSUzI1NiIsImtpZCI6Ijhm...   # JWT proyectado, corto TTL

$ kubectl create token payments-api --namespace team-payments --duration=10m \
    | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, exp}'
{
  "sub": "system:serviceaccount:team-payments:payments-api",
  "aud": ["https://kubernetes.default.svc"],
  "exp": 1786000000
}
```

---

## 6. Guía de verificación y diagnóstico de fallas

### 6.1 Decodificar un error `Forbidden`

El mensaje del API server es autoexplicativo — **leerlo entero** antes de tocar nada:

```console
$ kubectl get secrets --namespace kube-system \
    --as system:serviceaccount:team-payments:payments-api
Error from server (Forbidden): secrets is forbidden:
  User "system:serviceaccount:team-payments:payments-api" cannot list
  resource "secrets" in API group "" in the namespace "kube-system"
```

Descomposición: **subject** (`User ...`) · **verbo** (`list`) · **recurso** (`secrets`, apiGroup `""`) · **scope** (`namespace kube-system`). Con esos cuatro campos sabés exactamente qué regla falta. El 90% de los "RBAC no funciona" son: (a) namespace equivocado en el RoleBinding, (b) `resourceNames` bloqueando un `list`, (c) apiGroup mal (`apps` vs `""`), o (d) subject mal escrito (`ServiceAccount` name vs el username `system:serviceaccount:<ns>:<name>`).

### 6.2 ¿Quién puede hacer X? (auditoría inversa)

Con el plugin `kubectl-who-can` (de Aqua) o `rakkess`:

```console
$ kubectl who-can list secrets --namespace team-payments
ROLEBINDING          NAMESPACE       SUBJECT                  TYPE            SA-NAMESPACE
platform-audit       team-payments   platform:auditor         Group

CLUSTERROLEBINDING   SUBJECT                  TYPE     SA-NAMESPACE
cluster-admin        system:masters           Group
platform-operators   oidc:platform-sre        Group
```

```console
$ kubectl access-matrix --namespace team-payments --as oidc:platform-sre
NAME                          LIST  CREATE  UPDATE  DELETE
configmaps                    ✔     ✖       ✖       ✖
deployments.apps              ✔     ✖       ✖       ✖
pods                          ✔     ✖       ✖       ✖
secrets                       ✖     ✖       ✖       ✖
```

### 6.3 Cazar el over-privilege y los caminos de escalación

Checklist de auditoría de producción:

```console
# 1) ¿Quién tiene cluster-admin? Debe ser una lista corta y justificada.
$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | "\(.metadata.name): \([.subjects[]? | "\(.kind)/\(.name)"] | join(", "))"'
cluster-admin: Group/system:masters
platform-break-glass: User/oncall@corp.internal

# 2) ¿Algún binding otorga el verbo peligroso 'escalate' o 'bind' o 'impersonate'?
$ kubectl get clusterroles -o json \
  | jq -r '.items[] | select([.rules[]?.verbs[]?] | any(. == "escalate" or . == "impersonate"))
           | .metadata.name'
cluster-admin
platform:sso-proxy

# 3) ¿Algún ServiceAccount default con permisos? (nunca debería)
$ kubectl auth can-i --list --as system:serviceaccount:team-payments:default -n team-payments
Resources   Non-Resource URLs   Resource Names   Verbs
                                                 [ (solo selfsubject*, esperado) ]
```

**Caminos de escalación a revisar explícitamente:**
- `create pods` + un SA potente en el mismo namespace → montaje del SA → herencia de permisos. Mitigación: `automountServiceAccountToken: false` + SAs de app con mínimo privilegio.
- `create/update` sobre `roles`/`rolebindings` **con** `escalate`/`bind` → auto-promoción. Mitigación: nunca otorgar `escalate`; `bind` solo a roles concretos vía `resourceNames`.
- `impersonate` sobre `users`/`groups` → actuar como cualquiera. Mitigación: reservar a proxies de auth auditados.
- `create` sobre `certificatesigningrequests` + `approve` sobre el signer `kubernetes.io/kube-apiserver-client` → forjar un cert de cliente con el CN/O que quiera. Mitigación: separar create y approve; el approve solo al controller.
- Acceso a Secrets de tipo `kubernetes.io/service-account-token` o a `secrets` cluster-wide → robo de tokens. Mitigación: `edit`/`view` ya no leen Secrets por defecto; no revertirlo.

### 6.4 Verificar que los security controls no-RBAC están activos

```console
# Pod Security Admission — probar que el namespace rechaza un pod privileged
$ kubectl run rooted --image=busybox --privileged --namespace team-payments --command -- sleep 3600
Error from server (Forbidden): pods "rooted" is forbidden: violates PodSecurity
  "restricted:v1.30": privileged (container "rooted" must not set securityContext.privileged=true),
  allowPrivilegeEscalation != false, runAsNonRoot != true, seccompProfile ...

# Kyverno — confirmar que la policy está en Ready
$ kubectl get clusterpolicy require-run-as-nonroot-and-block-priv
NAME                                       BACKGROUND   VALIDATE ACTION   READY   AGE
require-run-as-nonroot-and-block-priv      true         Enforce           True    3d

# ValidatingAdmissionPolicy — ver rechazos
$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: hostnet, namespace: team-payments }
spec:
  hostNetwork: true
  containers: [{ name: c, image: nginx }]
EOF
The pods "hostnet" is invalid: ValidatingAdmissionPolicy 'block-host-namespaces'
  with binding 'block-host-namespaces-binding' denied request: hostNetwork está prohibido.

# NetworkPolicy — confirmar default-deny en el namespace
$ kubectl get networkpolicy -n team-payments
NAME                            POD-SELECTOR    AGE
default-deny-all                <none>          3d
allow-api-from-gateway-and-dns  app=payments-api  3d
```

### 6.5 Matriz de síntoma → causa

| Síntoma | Causa probable | Verificación |
|---|---|---|
| `Forbidden` en `list` pese a tener `get` sobre el nombre | `resourceNames` no aplica a `list` | quitar `resourceNames` o agregar regla sin él |
| Binding correcto pero sin efecto | namespace del RoleBinding ≠ namespace del recurso | `kubectl get rolebinding -A -o wide` |
| SA sin permisos pese al Role | subject mal: `kind: User` en vez de `ServiceAccount`, o name sin ns | `kubectl auth can-i --list --as system:serviceaccount:<ns>:<sa>` |
| CRD accesible sin haberlo otorgado | agregación a `admin`/`edit` vía label | `kubectl get clusterroles -l rbac.authorization.k8s.io/aggregate-to-edit=true` |
| No puede crear un Role más amplio | escalation prevention (falta `escalate`) | esperado; revisar si realmente se necesita |
| Pod privileged pasa el admission | falta label PSA en el namespace o `enforce=privileged` | `kubectl get ns <ns> -o jsonpath='{.metadata.labels}'` |

---

## 7. Referencias

- **Using RBAC Authorization** — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- **Authorization Overview (modos: Node, RBAC, ABAC, Webhook)** — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- **Authenticating (OIDC, ServiceAccount tokens, impersonation)** — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- **Managing Service Accounts / bound tokens** — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- **`kubectl auth can-i` reference** — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/
- **Pod Security Admission** — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- **Pod Security Standards (privileged/baseline/restricted)** — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- **Validating Admission Policy (CEL)** — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- **Admission Controllers Reference** — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- **Network Policies** — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **Kyverno — Policy Types & Writing Policies** — https://kyverno.io/docs/writing-policies/
- **OPA Gatekeeper** — https://open-policy-agent.github.io/gatekeeper/website/docs/
- **Argo CD — Projects (AppProject) & RBAC** — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/ · https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- **CNCF Curriculum (CNPE)** — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf