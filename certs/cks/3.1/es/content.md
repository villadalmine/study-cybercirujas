# Usar controles de acceso basados en roles para minimizar la exposición

**Certificación:** Certified Kubernetes Security Specialist (CKS) — currículum v1.34
**Dominio:** Cluster Setup and Hardening
**Peso:** 3.75%
**Perfil:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el problema arquitectónico que RBAC resuelve realmente

En un clúster de Kubernetes en producción el API server no es "una de" las superficies de ataque — *es* la superficie de ataque. Todos los demás componentes del plano de control (scheduler, controller-manager, kubelet, CNI, CSI, operadores) son clientes de la misma API REST, autenticados con las mismas primitivas de identidad y autorizados por la misma cadena. El compromiso de una sola carga de trabajo que posea un token de ServiceAccount demasiado amplio derrumba por completo el modelo de radio de impacto: las network policies, los perfiles seccomp y la firma de imágenes se vuelven irrelevantes si el atacante simplemente puede `create` de un Pod privilegiado a través de la API.

El modo de falla contra el que diseñamos es la **acumulación lateral de privilegios**:

1. Un Pod de aplicación es comprometido (RCE en una dependencia, SSRF, endpoint de depuración expuesto).
2. El atacante lee `/var/run/secrets/kubernetes.io/serviceaccount/token` — montado por defecto salvo que se lo deshabilite explícitamente.
3. Ese token pertenece a una ServiceAccount que un equipo de plataforma apurado vinculó a `edit` "para que el job de CI funcione".
4. `edit` en un namespace permite crear un Pod que corra **como cualquier ServiceAccount de ese namespace**, y permite leer todos los Secrets de ese namespace.
5. Si alguna ServiceAccount del namespace está vinculada (directa o transitivamente) a `cluster-admin`, el atacante ya es dueño del clúster.

Notá que los pasos 3–5 no involucran ningún CVE, ninguna fuga del kernel ni ningún runtime de contenedores mal configurado. Son fallas puras del modelo de autorización. Por eso RBAC tiene un peso desproporcionado respecto de su 3.75% de asignación en el examen: es el control que determina si todos los *demás* controles importan.

El segundo problema de producción es la **deriva operativa**. Los objetos RBAC son puramente aditivos y no tienen semántica de denegación, así que en un clúster de larga vida los permisos crecen monótonamente salvo que algo los pode activamente. Cada incidente que termina con "dale `cluster-admin` a la SA por ahora" es permanente a menos que construyas detección. Por eso una plataforma madura trata a RBAC como artefactos *generados, revisados y auditados de forma continua* — no como YAML editado a mano.

Tercero: **la decisión de autorización no es toda la historia**. RBAC autoriza verbos sobre tipos de recursos. No puede expresar "este Deployment solo puede montar Secrets cuyo nombre empiece con `app-`", ni "este usuario puede escalar pero no cambiar la imagen". Esas restricciones pertenecen a admission (ValidatingAdmissionPolicy / webhooks). Saber dónde termina el límite de RBAC y dónde empieza admission es la competencia arquitectónica que se está evaluando.

---

## 2. Dónde se ubica RBAC: el pipeline de la petición

Toda petición a `kube-apiserver` atraviesa cuatro etapas. RBAC es la etapa 2.

```
                    ┌──────────────────────────────────────────────────┐
  HTTPS request ──▶ │ 1. AUTHENTICATION                                │
                    │    x509 client certs (CN → user, O → groups)     │
                    │    Bearer tokens (SA JWT via TokenReview / OIDC) │
                    │    Webhook token auth, static tokens (legacy)    │
                    │    Anonymous → system:anonymous                  │
                    └───────────────┬──────────────────────────────────┘
                                    │ user.Info{Name, UID, Groups, Extra}
                    ┌───────────────▼──────────────────────────────────┐
                    │ 2. AUTHORIZATION (ordered chain, first-allow-wins)│
                    │    Node → RBAC → [Webhook ...]                    │
                    │    Result: allow | deny | no-opinion              │
                    └───────────────┬──────────────────────────────────┘
                                    │
                    ┌───────────────▼──────────────────────────────────┐
                    │ 3. ADMISSION (mutating → schema validation →      │
                    │    validating: VAP, webhooks, PodSecurity,        │
                    │    NodeRestriction, ServiceAccount, ResourceQuota) │
                    └───────────────┬──────────────────────────────────┘
                                    │
                    ┌───────────────▼──────────────────────────────────┐
                    │ 4. PERSISTENCE (etcd, encryption-at-rest)         │
                    └──────────────────────────────────────────────────┘
```

Semántica crítica de la etapa 2:

- La cadena está **ordenada** y se evalúa hasta que un autorizador devuelve `allow` o `deny`. `no-opinion` cae al siguiente.
- **RBAC nunca devuelve `deny`.** Devuelve `allow` o `no-opinion`. Si RBAC es el último autorizador, un `no-opinion` se convierte en un `403 Forbidden` implícito. Esto significa que *no podés escribir una regla RBAC de "deny"* — un error conceptual común y caro. La restricción se logra únicamente *no otorgando*.
- Como la cadena es "gana el primer allow", colocar un autorizador permisivo (`AlwaysAllow`, o un webhook laxo) antes de RBAC neutraliza RBAC en silencio.

### 2.1 Declarar la cadena: `--authorization-config` (v1.34)

Los clústeres modernos configuran la cadena mediante un archivo estructurado en lugar del flag heredado `--authorization-mode`. Ambos son mutuamente excluyentes.

`/etc/kubernetes/authorization/config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthorizationConfiguration
authorizers:
  # Node authorizer: constrains kubelets to objects related to their own node.
  # Must be paired with the NodeRestriction admission plugin.
  - type: Node
    name: node

  # Optional: an external policy engine consulted BEFORE RBAC so it can DENY.
  # RBAC cannot deny, so any true deny-list must live in a webhook or admission.
  - type: Webhook
    name: org-guardrails
    webhook:
      connectionInfo:
        type: KubeConfigFile
        kubeConfigFile: /etc/kubernetes/authorization/guardrails.kubeconfig
      authorizedTTL: 30s
      unauthorizedTTL: 5s
      timeout: 3s
      subjectAccessReviewVersion: v1
      matchConditionSubjectAccessReviewVersion: v1
      failurePolicy: Deny
      matchConditions:
        # Only bother the webhook for high-risk resources; everything else
        # short-circuits to RBAC. Reduces latency and blast radius of an outage.
        - expression: >-
            request.resource.group == 'rbac.authorization.k8s.io' ||
            request.resource.resource == 'secrets'

  # RBAC last: the authoritative allow-list.
  - type: RBAC
    name: rbac
```

Conectalo al manifiesto del Pod estático `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.0.11
        - --allow-privileged=true
        - --authorization-config=/etc/kubernetes/authorization/config.yaml
        - --enable-admission-plugins=NodeRestriction,ServiceAccount
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --anonymous-auth=false
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-maxage=30
        - --audit-log-maxbackup=10
        - --audit-log-maxsize=100
        - --profiling=false
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
      volumeMounts:
        - name: authz
          mountPath: /etc/kubernetes/authorization
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
  volumes:
    - name: authz
      hostPath:
        path: /etc/kubernetes/authorization
        type: Directory
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

> **Nota operativa.** El `AuthorizationConfiguration` estructurado llegó a GA en `apiserver.config.k8s.io/v1` en v1.32; los clústeres en v1.30/v1.31 usan `v1beta1`. En cualquier clúster donde no estés seguro, `kubectl -n kube-system get pod kube-apiserver-<node> -o yaml | grep authorization` te dice en segundos cuál forma está en uso. El equivalente heredado es `--authorization-mode=Node,RBAC`.

Como el apiserver corre como un Pod estático, editar el manifiesto dispara un reinicio in situ por parte del kubelet. Un error de sintaxis significa que el API server no vuelve — siempre guardá una copia:

```
$ sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT  POD ID
9f1c0a2b3d4e5  4c2f1a9e0b3d7  18 seconds ago  Running  kube-apiserver   3        7a1b2c3d4e5f6
```

---

## 3. El modelo de objetos de RBAC y la semántica de evaluación

Cuatro objetos, todos en `rbac.authorization.k8s.io/v1` (las variantes `v1alpha1`/`v1beta1` fueron eliminadas en v1.22).

| Objeto | Alcance de las *reglas* | Alcance de la *concesión* | Puede referenciar |
|---|---|---|---|
| `Role` | un namespace | — | — |
| `ClusterRole` | todo el clúster (incl. recursos de ámbito de clúster y `nonResourceURLs`) | — | — |
| `RoleBinding` | — | un namespace | un `Role` **en el mismo namespace**, o *cualquier* `ClusterRole` |
| `ClusterRoleBinding` | — | todos los namespaces + ámbito de clúster | solo un `ClusterRole` |

La combinación no obvia es **`RoleBinding` → `ClusterRole`**. Es el patrón más útil en plataformas multi-tenant: escribí el conjunto de permisos *una sola vez* como `ClusterRole`, y después proyectalo a N namespaces con N `RoleBinding`s baratos. La proyección es lossy en una dirección segura — cuando un `ClusterRole` se vincula mediante un `RoleBinding`, solo surten efecto sus reglas sobre recursos namespaced; las reglas que cubren recursos de ámbito de clúster (`nodes`, `persistentvolumes`, `clusterroles`) y `nonResourceURLs` son **ignoradas silenciosamente**.

### 3.1 Anatomía de una regla

```yaml
rules:
  - apiGroups:     [""]                       # "" = core group. "*" = all groups.
    resources:     ["pods", "pods/log"]       # subresources use the slash form
    resourceNames: ["frontend-0"]             # optional; only for name-carrying requests
    verbs:         ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics", "/healthz"] # ClusterRole only; mutually exclusive
    verbs:           ["get"]                  # with apiGroups/resources
```

La evaluación es una unión pura: una petición se permite si **cualquier regla de cualquier Role/ClusterRole vinculado al sujeto (por usuario, por grupo o por ServiceAccount)** coincide con todos los campos de `{apiGroup, resource, subresource, name, verb, namespace}`. No hay orden, ni precedencia, ni negación.

**Verbos** y los métodos HTTP a los que se mapean:

| Verbo | HTTP | Notas |
|---|---|---|
| `get` | GET (con nombre) | incluye leer subrecursos como `pods/log` |
| `list` | GET (colección) | devuelve objetos completos — `list` sobre `secrets` es `get` sobre todos ellos |
| `watch` | GET `?watch=1` | misma exposición de datos que `list` |
| `create` | POST | el nombre del objeto se desconoce al momento de autorizar |
| `update` | PUT | reemplazo completo |
| `patch` | PATCH | strategic-merge/JSON-patch; poder equivalente a `update` |
| `delete` | DELETE (con nombre) | |
| `deletecollection` | DELETE (colección) | a menudo olvidado en roles de "lectura-escritura" |
| `bind` | — | verbo virtual sobre `roles`/`clusterroles`; evita el chequeo de escalada |
| `escalate` | — | verbo virtual sobre `roles`/`clusterroles`; evita el chequeo de escalada |
| `impersonate` | — | sobre `users`, `groups`, `serviceaccounts`, `uids` en `authentication.k8s.io` |
| `approve` / `sign` | — | sobre `certificatesigningrequests/approval` y `/status` (signers) |

### 3.2 `resourceNames` — límites precisos y trampas precisas

`resourceNames` restringe una regla a instancias nombradas. Solo funciona para peticiones cuya ruta **lleve el nombre del objeto**:

| Verbo | ¿`resourceNames` efectivo? | Por qué |
|---|---|---|
| `get`, `update`, `patch`, `delete` | ✅ sí | el nombre está en la ruta de la URL |
| `create` | ❌ no | el nombre está en el cuerpo (y puede ser `generateName`) |
| `list`, `watch`, `deletecollection` | ❌ no | petición de colección, sin nombre en la ruta |

La trampa: un rol que otorga `["get","list"]` sobre `secrets` con `resourceNames: ["db-credentials"]` da `get` sobre ese único Secret **y ningún `list` en absoluto**. Los usuarios entonces reportan "no puedo ver ningún secret" — ese es el comportamiento correcto, no un bug. A la inversa, otorgar `list` *sin* `resourceNames` junto a un `get` restringido por nombre vuelve a exponer todos los Secrets del namespace, ya que `list` devuelve los cuerpos completos de los objetos.

RBAC tampoco tiene **conocimiento de field-selectors ni label-selectors**. `list pods --field-selector metadata.name=x` sigue autorizándose como un `list` sin restricciones.

### 3.3 Comodines y CRDs

`apiGroups: ["*"]`, `resources: ["*"]`, `verbs: ["*"]` coinciden con todo **incluyendo recursos que todavía no existen**. Instalar un operador que registre un CRD nuevo ensancha instantáneamente todos los roles con comodín del clúster. Este es el argumento contra `*` que sobrevive al contacto con una plataforma real: no es meramente amplio, es *retroactivamente* amplio.

Para un CRD, el valor de `apiGroups` es el `spec.group` del CRD, y `resources` es `spec.names.plural`:

```
$ kubectl get crd certificates.cert-manager.io -o jsonpath='{.spec.group}/{.spec.names.plural}{"\n"}'
cert-manager.io/certificates
```

### 3.4 ClusterRoles agregados

Un `ClusterRole` que lleva un `aggregationRule` tiene su campo `rules` **gestionado por el controller-manager** — todo lo que escribas ahí se sobrescribe. El controlador une las reglas de cada `ClusterRole` que coincida con los selectores.

Los roles integrados `admin`, `edit` y `view` son agregados, y ese es el punto de extensión soportado para CRDs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-certificates-view
  labels:
    # Rules below are merged into the built-in "view" ClusterRole,
    # and transitively into "edit" and "admin" (they aggregate view).
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "certificaterequests", "issuers"]
    verbs:     ["get", "list", "watch"]
```

Consecuencia de seguridad que hay que internalizar: **cualquiera que pueda crear un `ClusterRole` con una etiqueta de agregación puede ensanchar silenciosamente `view`/`edit`/`admin` en todo el clúster.** El chequeo de escalada (§6.1) se aplica al momento de la creación, pero aun así este es un punto de control que vale la pena vigilar con admission.

### 3.5 Roles por defecto y auto-reconciliación

| ClusterRole | Vinculado por defecto a | Otorga | Notas de seguridad |
|---|---|---|---|
| `cluster-admin` | Grupo `system:masters` (binding `cluster-admin`) | `*` sobre `*` + todas las `nonResourceURLs` | Evita todo excepto admission |
| `admin` | nada | Lectura/escritura completa del namespace **incluyendo** `roles`/`rolebindings` y `secrets` | Puede auto-escalar a cualquier SA del namespace |
| `edit` | nada | Lectura/escritura del namespace, **sin** `roles`/`rolebindings` | **Puede leer Secrets** y correr Pods como cualquier SA del namespace → equivalente a todas las SA del namespace |
| `view` | nada | Solo lectura del namespace | **Excluye explícitamente `secrets`**, precisamente porque leerlos entrega credenciales de SA |
| `system:basic-user` | Grupo `system:authenticated` | `create` sobre `selfsubject*reviews` | Inofensivo; habilita `kubectl auth can-i` |
| `system:discovery` | Grupo `system:authenticated` | `get` sobre `/api*`, `/openapi*`, `/version` | Descubrimiento de la superficie de la API |
| `system:public-info-viewer` | Grupos `system:authenticated` **y `system:unauthenticated`** | `get` sobre `/healthz`, `/livez`, `/readyz`, `/version` | La única concesión por defecto a usuarios no autenticados |

En cada arranque, `kube-apiserver` **reconcilia** los roles y bindings de bootstrap: los defaults borrados se recrean, y las reglas eliminadas se vuelven a agregar. Borrar el ClusterRoleBinding `cluster-admin` no es, por lo tanto, un paso de hardening duradero. Para excluir un objeto por defecto específico de la reconciliación:

```yaml
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "false"
```

La reconciliación es aditiva: vuelve a agregar reglas y sujetos faltantes pero no elimina los extras que hayas agregado. Esa asimetría es la razón por la que los roles por defecto derivan.

---

## 4. Análisis de compromisos

### 4.1 Módulos de autorización

| Módulo | Tipos de decisión | Fuente de datos | ¿Dinámico? | Encaje |
|---|---|---|---|---|
| `Node` | allow / no-opinion | Grafo de relaciones node→pod→secret/configmap/pvc | sí | **Obligatorio.** Restringe a los kubelets a los objetos de su propio nodo. Combinar con el admission `NodeRestriction`. |
| `RBAC` | allow / no-opinion | Objetos de la API en etcd | sí | **Obligatorio.** La lista de permitidos de referencia. |
| `ABAC` | allow / no-opinion | Archivo JSON-lines estático en el host del plano de control | **no** — requiere reiniciar el apiserver | Heredado. Sin API, sin rastro de auditoría, sin deny. Evitar. |
| `Webhook` | allow / **deny** / no-opinion | Servicio HTTPS externo | sí | La única forma de expresar un deny real en autorización. Cuesta latencia en cada petición; necesita ajuste de `failurePolicy` y TTL. |
| `AlwaysAllow` | allow | — | — | Solo clústeres de prueba. Colocarlo en cualquier punto de la cadena deshabilita RBAC. |
| `AlwaysDeny` | deny | — | — | Solo diagnóstico. |

### 4.2 Topologías de RBAC multi-tenant

| Estrategia | Radio de impacto | Costo operativo | Riesgo de deriva | Cuándo elegirla |
|---|---|---|---|---|
| `Role` + `RoleBinding` por namespace, escritos a mano | Mínimo | Alto (N× objetos, N× revisiones) | Alto — las copias divergen | Clústeres chicos, tenants muy a medida |
| `ClusterRole` compartido proyectado por `RoleBinding` | Mínimo (igual que arriba) | **Bajo** — una definición, N bindings finos | Bajo — única fuente de verdad | **Recomendación por defecto** para equipos de plataforma |
| `ClusterRole` agregado que extiende `view`/`edit`/`admin` | Todo el clúster si se etiqueta mal | Bajo | Medio — una etiqueta perdida ensancha los defaults | Proveedores de CRD/operadores que publican fragmentos de rol |
| `ClusterRoleBinding` a un rol amplio | **Todo el clúster** | El más bajo | — | Solo agentes genuinamente de ámbito de clúster (CNI, CSI, métricas) |
| Generado desde grupos del IdP (OIDC) vía GitOps | Mínimo | Medio al principio, bajo en régimen | **El más bajo** — reconciliado continuamente | Entornos regulados / auditados |

### 4.3 Portadores de identidad

| Portador | Rotación | Revocación | Soporte de grupos | Veredicto |
|---|---|---|---|---|
| Certificado cliente x509 (CN=usuario, O=grupo) | Reemisión manual | **Ninguna salvo rotar la CA** — el apiserver no consulta CRL | vía `O` (repetible) | Solo break-glass. Mantener TTL corto. |
| Token de SA, proyectado/acotado (`TokenRequest`) | Automática por el kubelet | Acotado al ciclo de vida del Pod/SA; inválido una vez que el Pod ya no está | implícito `system:serviceaccounts[:ns]` | **Por defecto para cargas de trabajo.** |
| Token de SA, heredado basado en Secret | Nunca | Borrar el Secret | igual | No se crea automáticamente desde v1.24. Purgar cualquier sobreviviente. |
| id_token de OIDC | TTL del proveedor | Del lado del proveedor | vía claim (`groups`) | **Por defecto para humanos.** |
| Archivo de tokens estáticos | Nunca | Reiniciar el apiserver | limitado | Obsoleto. Eliminar. |

---

## 5. Implementación de referencia: un servicio de mínimo privilegio

El escenario: una carga de trabajo `reporter` en el namespace `payments` debe leer sus propios ConfigMaps, leer exactamente un Secret, listar Pods en `payments`, y leer los logs de los Pods. Nada más. No debe poder leer ningún otro Secret, crear nada, ni ver ningún otro namespace.

### 5.1 Namespace, ServiceAccount, Role, RoleBinding

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
---
# Dedicated identity. Never reuse the namespace "default" ServiceAccount:
# it is shared by every workload that forgets to set serviceAccountName.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: reporter
  namespace: payments
# Belt-and-braces: even if a Pod spec forgets to opt out, tokens are not
# mounted for Pods using this SA unless the Pod explicitly sets it to true.
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reporter
  namespace: payments
rules:
  # 1) Pod inventory and logs. "pods/log" is a subresource: it needs its own
  #    entry, and the verb is "get" (there is no "list" on a subresource).
  - apiGroups: [""]
    resources: ["pods"]
    verbs:     ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs:     ["get"]

  # 2) Non-sensitive configuration, read-only.
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs:     ["get", "list", "watch"]

  # 3) Exactly one Secret, by name. NOTE the deliberate absence of "list":
  #    adding it here would expose every Secret in the namespace, because
  #    resourceNames cannot constrain a collection request.
  - apiGroups:     [""]
    resources:     ["secrets"]
    resourceNames: ["reporting-db-credentials"]
    verbs:         ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter
  namespace: payments
subjects:
  - kind: ServiceAccount
    name: reporter
    namespace: payments
roleRef:
  # roleRef is IMMUTABLE. Changing the target role requires delete + recreate.
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reporter
```

### 5.2 El Deployment consumidor

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reporter
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: reporter
  template:
    metadata:
      labels:
        app: reporter
    spec:
      serviceAccountName: reporter
      # Explicit opt-in for THIS workload only. Everything else using the
      # "reporter" SA still gets no token, thanks to the SA-level default.
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: reporter
          image: registry.example.com/payments/reporter@sha256:3f1a9c2e7b5d4086f1c2a9b7d3e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f8
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: KUBERNETES_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: kube-api-access
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests: { cpu: "50m",  memory: "64Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
      volumes:
        # Explicit projected volume: 1h token TTL (kubelet refreshes at 80%),
        # audience-bound so the token is rejected by anything but the apiserver.
        - name: kube-api-access
          projected:
            defaultMode: 0444
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 3600
                  audience: https://kubernetes.default.svc.cluster.local
              - configMap:
                  name: kube-root-ca.crt
                  items:
                    - key: ca.crt
                      path: ca.crt
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef:
                        fieldPath: metadata.namespace
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
```

### 5.3 El patrón de proyección de ClusterRole compartido

Definir una sola vez:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:namespace-operator
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "events", "endpoints"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/log", "pods/status"]
    verbs:     ["get"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs:     ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs:     ["get", "list", "watch"]
  # Deliberately absent: secrets, serviceaccounts, roles, rolebindings,
  # pods/exec, pods/attach, pods/portforward, pods/ephemeralcontainers.
```

Proyectalo a los namespaces con bindings finos — notá que esto otorga *solo dentro de* `payments`, a pesar de referenciar un ClusterRole:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-operators
  namespace: payments
subjects:
  - kind: Group
    name: oidc:payments-sre          # from the OIDC "groups" claim + --oidc-group-prefix=oidc:
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: platform:namespace-operator
```

### 5.4 Una identidad humana vía CSR (patrón break-glass / de examen)

```
$ openssl genrsa -out sre-alex.key 3072
$ openssl req -new -key sre-alex.key -out sre-alex.csr \
    -subj "/CN=sre-alex/O=oidc:payments-sre"
$ cat sre-alex.csr | base64 -w0 > sre-alex.csr.b64
```

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-alex
spec:
  # base64 of the PEM CSR, single line
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0K...
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400          # 24h — short TTL compensates for no revocation
  usages:
    - client auth
```

```
$ kubectl apply -f sre-alex-csr.yaml
certificatesigningrequest.certificates.k8s.io/sre-alex created

$ kubectl get csr sre-alex
NAME       AGE   SIGNERNAME                            REQUESTOR           REQUESTEDDURATION   CONDITION
sre-alex   4s    kubernetes.io/kube-apiserver-client   kubernetes-admin    24h                 Pending

$ kubectl certificate approve sre-alex
certificatesigningrequest.certificates.k8s.io/sre-alex approved

$ kubectl get csr sre-alex -o jsonpath='{.status.certificate}' | base64 -d > sre-alex.crt
$ openssl x509 -in sre-alex.crt -noout -subject -dates
subject=CN = sre-alex, O = oidc:payments-sre
notBefore=Jul 30 09:12:00 2026 GMT
notAfter=Jul 31 09:12:00 2026 GMT
```

El `CN` se convierte en el nombre de usuario y cada `O` en un grupo — así que este certificado hereda el RoleBinding `payments-operators` de más arriba sin ningún cambio adicional de RBAC. **No hay revocación**: el apiserver no consulta CRL ni OCSP. Las únicas mitigaciones son un `expirationSeconds` corto y rotar la CA de clientes.

### 5.5 Barrera de admission: bloquear nuevos bindings a `cluster-admin`

RBAC no puede denegar, así que la lista de denegación vive en admission. `ValidatingAdmissionPolicy` (GA desde v1.30) hace esto en proceso, sin ningún webhook que mantener vivo:

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: restrict-cluster-admin-bindings.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   ["rbac.authorization.k8s.io"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["clusterrolebindings", "rolebindings"]
  matchConditions:
    # Never block the apiserver's own bootstrap reconciliation, or kubeadm.
    - name: exclude-control-plane
      expression: >-
        !(request.userInfo.username in
          ['system:apiserver', 'system:kube-controller-manager'])
  variables:
    - name: roleName
      expression: "object.roleRef.name"
    - name: subjectNames
      expression: "object.subjects.orValue([]).map(s, s.name)"
  validations:
    - expression: >-
        variables.roleName != 'cluster-admin' ||
        object.metadata.name in ['cluster-admin', 'kubeadm:cluster-admins']
      messageExpression: >-
        'binding to ClusterRole/cluster-admin is not permitted (attempted by ' +
        request.userInfo.username + '); file an exception with the platform team'
      reason: Forbidden
    - expression: >-
        !variables.subjectNames.exists(n, n == 'system:unauthenticated' ||
                                          n == 'system:anonymous')
      message: "RBAC must never be granted to anonymous or unauthenticated subjects"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: restrict-cluster-admin-bindings.security.example.com
spec:
  policyName: restrict-cluster-admin-bindings.security.example.com
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector: {}          # all namespaces + cluster scope
```

Verificá que muerda:

```
$ kubectl create clusterrolebinding oops --clusterrole=cluster-admin --serviceaccount=payments:reporter
error: failed to create clusterrolebinding: admission webhook denied the request:
ValidatingAdmissionPolicy 'restrict-cluster-admin-bindings.security.example.com'
with binding 'restrict-cluster-admin-bindings.security.example.com' denied request:
binding to ClusterRole/cluster-admin is not permitted (attempted by kubernetes-admin);
file an exception with the platform team
```

---

## 6. La superficie de escalada de privilegios

Esta tabla es el núcleo operativo del tema. Cada fila es un permiso que *parece* mundano en una revisión y en realidad es un camino a cluster-admin.

| Permiso | Camino de escalada | Mitigación |
|---|---|---|
| `create` sobre `pods` | Programar un Pod con `serviceAccountName: <cualquier SA del ns>`, `hostPID`, `hostPath: /`, `privileged: true` → root del nodo → leer todos los Secrets montados por el kubelet y el certificado cliente del kubelet | PodSecurity `restricted`, nada de `create pods` para humanos (usar controladores), NodeRestriction |
| `create` sobre `deployments`/`jobs`/`cronjobs`/`daemonsets` | Igual que arriba, indirectamente — el controlador crea el Pod por vos | Idéntico; tratá el `create` de controladores de carga de trabajo como `create` de Pod |
| `get`/`list` sobre `secrets` | Leer tokens de SA (heredados), claves TLS, credenciales de nube | Nunca otorgues `list` sobre secrets; usá `resourceNames` + `get`; el cifrado en reposo no ayuda contra una lectura autorizada |
| `create` sobre `serviceaccounts/token` | `TokenRequest` para *cualquier* SA del namespace → convertirse en ella | Otorgar solo a controladores que emitan tokens, siempre con `resourceNames` |
| `impersonate` sobre `groups` | `--as-group=system:masters` → cluster-admin instantáneo | Nunca otorgar; si es inevitable, restringir con `resourceNames` y auditar cada uso |
| `escalate` sobre `roles`/`clusterroles` | Escribir un rol que otorgue más de lo que poseés | Reservar para el controlador de bootstrap |
| `bind` sobre `roles`/`clusterroles` | Vincular un rol de alto privilegio existente a vos mismo | Restringir con `resourceNames` a una lista curada de permitidos |
| `get`/`create` sobre `nodes/proxy` | Alcanzar la API del kubelet directamente → `exec` en cualquier Pod de ese nodo, evitando el RBAC y la auditoría del apiserver | Kubelet con `--authorization-mode=Webhook`, `--anonymous-auth=false`; nunca otorgar `nodes/proxy` |
| `create` sobre `pods/exec`, `pods/attach`, `pods/portforward` | Entrar a un Pod que posee un token de SA más fuerte | Roles de "debug" separados, acotados en el tiempo, auditados a nivel `RequestResponse` |
| `patch` sobre `pods/ephemeralcontainers` | Inyectar un contenedor en un Pod en ejecución, evitando la revisión del securityContext original | Igual que `exec`; PodSecurity sigue aplicando pero se hereda la SA del Pod destino |
| `approve` sobre `certificatesigningrequests/approval` + `sign` | Emitir un certificado cliente con `O=system:masters` | Solo el controlador signer; auditar las aprobaciones de CSR |
| `update`/`patch` sobre `validatingadmissionpolicies` / `...webhookconfigurations` | Deshabilitar las barreras y luego escalar libremente | Solo cluster-admin; alertar ante cualquier cambio |
| `create`/`update` sobre `clusterroles` con etiquetas `aggregate-to-*` | Ensanchar silenciosamente `view`/`edit`/`admin` en todo el clúster | Política de admission sobre las etiquetas de agregación |

### 6.1 La prevención de escalada integrada

Kubernetes se niega a dejarte crear o actualizar un Role/ClusterRole que contenga permisos que no poseés ya:

```
$ kubectl --context=payments-sre apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: sneaky
  namespace: payments
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs:     ["*"]
EOF
Error from server (Forbidden): error when creating "STDIN": roles.rbac.authorization.k8s.io "sneaky"
is forbidden: user "sre-alex" (groups=["oidc:payments-sre" "system:authenticated"]) is attempting to
grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["secrets"], Verbs:["*"]}
```

El mismo chequeo aplica a los bindings: solo podés vincular un rol cuyos permisos ya poseés. Las dos vías de escape son los verbos virtuales `escalate` (sobre roles/clusterroles) y `bind` (sobre roles/clusterroles). Otorgar cualquiera de los dos es funcionalmente equivalente a otorgar los permisos destino — tratalos como tales en la revisión.

### 6.2 Impersonación, en concreto

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform:limited-impersonator
rules:
  # Only these two identities, never arbitrary users, and NEVER groups.
  - apiGroups:     [""]
    resources:     ["serviceaccounts"]
    resourceNames: ["ci-runner", "backup-agent"]
    verbs:         ["impersonate"]
  # Deliberately NOT granted:
  #   resources: ["groups"]  -> would allow --as-group=system:masters
  #   resources: ["users"]   -> would allow --as=<any human>
  #   resources: ["uids"]    -> allows spoofing the UID field in audit records
```

La impersonación queda completamente registrada en el log de auditoría (`impersonatedUser`), lo que hace de una concesión *acotada* un compromiso aceptable en términos de auditabilidad. Una concesión amplia no lo es.

### 6.3 `system:masters` y la división de kubeadm

`system:masters` está vinculado a `cluster-admin` por el `ClusterRoleBinding` de bootstrap llamado `cluster-admin`, que se auto-reconcilia. Desde kubeadm v1.29 los kubeconfigs de administración están divididos:

| Archivo | Sujeto del certificado | Identidad efectiva |
|---|---|---|
| `/etc/kubernetes/admin.conf` | `CN=kubernetes-admin, O=kubeadm:cluster-admins` | cluster-admin vía el binding ordinario y *borrable* `kubeadm:cluster-admins` |
| `/etc/kubernetes/super-admin.conf` | `CN=kubernetes-super-admin, O=system:masters` | cluster-admin vía el binding de bootstrap cableado; **los cambios de RBAC no pueden restringirlo** |

```
$ kubectl --kubeconfig /etc/kubernetes/admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ sudo kubectl --kubeconfig /etc/kubernetes/super-admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-super-admin
Groups      [system:masters system:authenticated]
```

Acción de hardening: `super-admin.conf` pertenece al nodo del plano de control con modo `0600`, fuera del sistema de CI y fuera de las laptops de los ingenieros. Es la credencial break-glass para el caso en que alguien borre el binding `kubeadm:cluster-admins`.

### 6.4 Acceso anónimo

```
$ kubectl get --raw /api --kubeconfig /dev/null --server https://10.0.0.11:6443 --insecure-skip-tls-verify
{"kind":"APIVersions","versions":["v1"],"serverAddressByClientCIDRs":[{"clientCIDR":"0.0.0.0/0","serverAddress":"10.0.0.11:6443"}]}
```

Si eso funciona, la autenticación anónima está activa y `system:anonymous`/`system:unauthenticated` está alcanzando `system:discovery` o `system:public-info-viewer`. Poné `--anonymous-auth=false` en el apiserver. Si las health probes necesitan acceso no autenticado, las versiones recientes permiten acotar la autenticación anónima a endpoints específicos vía `AuthenticationConfiguration` (`anonymous.conditions` con `path`) — verificá si el feature gate `AnonymousAuthConfigurableEndpoints` está habilitado en tu clúster antes de depender de eso:

```
$ kubectl get --raw /metrics | grep 'kubernetes_feature_enabled.*AnonymousAuthConfigurableEndpoints'
kubernetes_feature_enabled{name="AnonymousAuthConfigurableEndpoints",stage="BETA"} 1
```

Independientemente del gate, auditá el antipatrón:

```
$ kubectl get clusterrolebindings,rolebindings -A -o json \
  | jq -r '.items[] | select(.subjects[]?.name |
      IN("system:anonymous","system:unauthenticated","system:authenticated"))
      | "\(.kind)/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
ClusterRoleBinding/system:basic-user -> ClusterRole/system:basic-user
ClusterRoleBinding/system:discovery -> ClusterRole/system:discovery
ClusterRoleBinding/system:public-info-viewer -> ClusterRole/system:public-info-viewer
```

Esos tres son los defaults esperados. **Cualquier otra cosa en esa lista es un hallazgo.** Un binding de `system:authenticated` a un rol real significa que todas las ServiceAccounts del clúster lo poseen — `system:serviceaccounts` es miembro de `system:authenticated`.

---

## 7. Recorrido por CLI con salida real de terminal

### 7.1 ¿Quién soy y qué puedo hacer?

```
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ kubectl auth can-i --list --as=system:serviceaccount:payments:reporter -n payments
Resources                                       Non-Resource URLs                     Resource Names                Verbs
configmaps                                      []                                    []                            [get list watch]
pods                                            []                                    []                            [get list watch]
pods/log                                        []                                    []                            [get]
secrets                                         []                                    [reporting-db-credentials]    [get]
selfsubjectreviews.authentication.k8s.io        []                                    []                            [create]
selfsubjectaccessreviews.authorization.k8s.io   []                                    []                            [create]
selfsubjectrulesreviews.authorization.k8s.io    []                                    []                            [create]
                                                [/api/*]                              []                            [get]
                                                [/api]                                []                            [get]
                                                [/apis/*]                             []                            [get]
                                                [/apis]                               []                            [get]
                                                [/healthz]                            []                            [get]
                                                [/livez]                              []                            [get]
                                                [/openapi/*]                          []                            [get]
                                                [/openapi]                            []                            [get]
                                                [/readyz]                             []                            [get]
                                                [/version/]                           []                            [get]
                                                [/version]                            []                            [get]
```

`--as` realiza impersonación, así que requiere derechos de impersonación — que cluster-admin tiene. Esta es la verificación de corrección más rápida disponible.

### 7.2 Chequeos puntuales — incluyendo los negativos

```
$ kubectl auth can-i get secret/reporting-db-credentials --as=system:serviceaccount:payments:reporter -n payments
yes

$ kubectl auth can-i list secrets --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i get secret/other-app-tls --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i create pods --as=system:serviceaccount:payments:reporter -n payments
no

$ kubectl auth can-i list pods --as=system:serviceaccount:payments:reporter -n billing
no

$ kubectl auth can-i '*' '*' --as=system:serviceaccount:payments:reporter -A
no
```

`--quiet` suprime la salida y codifica la respuesta en el estado de salida, que es lo que querés en CI:

```
$ kubectl auth can-i --quiet create pods --as=system:serviceaccount:payments:reporter -n payments; echo "exit=$?"
exit=1
```

### 7.3 Probar con un token real en lugar de impersonación

La impersonación prueba RBAC, pero no la plomería del token. Para probar de punta a punta:

```
$ TOKEN=$(kubectl -n payments create token reporter --duration=10m)
$ kubectl --token="$TOKEN" --server=https://10.0.0.11:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    -n payments get pods
NAME                        READY   STATUS    RESTARTS   AGE
reporter-7d9c4b8f6c-2xk4p   1/1     Running   0          6m12s
reporter-7d9c4b8f6c-l9mzq   1/1     Running   0          6m12s

$ kubectl --token="$TOKEN" --server=https://10.0.0.11:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    -n payments get secrets
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:payments:reporter"
cannot list resource "secrets" in API group "" in the namespace "payments"
```

Decodificá el token para confirmar el binding y el TTL:

```
$ echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1785405600,
  "iat": 1785405000,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "3c1f9a2b-7d4e-4a86-9f01-2b3c4d5e6f70",
  "kubernetes.io": {
    "namespace": "payments",
    "serviceaccount": { "name": "reporter", "uid": "8a2b1c9d-4e5f-4061-9a2b-3c4d5e6f7081" }
  },
  "nbf": 1785405000,
  "sub": "system:serviceaccount:payments:reporter"
}
```

### 7.4 Desde adentro del Pod (la vista del atacante)

```
$ kubectl -n payments exec -it deploy/reporter -- sh
/ $ ls /var/run/secrets/kubernetes.io/serviceaccount/
ca.crt  namespace  token
/ $ TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
/ $ CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
/ $ curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
      https://kubernetes.default.svc/api/v1/namespaces/payments/pods | head -c 120
{"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"418293"},"items":[{"metadata":{"name":"repo
/ $ curl -sS --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
      https://kubernetes.default.svc/api/v1/namespaces/payments/secrets
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:serviceaccount:payments:reporter\" cannot list resource \"secrets\" in API group \"\" in the namespace \"payments\"",
  "reason": "Forbidden",
  "details": { "kind": "secrets" },
  "code": 403
}
```

Si `ls` sobre esa ruta devuelve "No such file or directory", `automountServiceAccountToken: false` está funcionando — ese es el resultado más fuerte posible para una carga de trabajo que no habla con la API en absoluto.

### 7.5 Consultas de autorización programáticas

`SubjectAccessReview` es lo que `can-i` usa por debajo, y está disponible para cualquier controlador que necesite delegar:

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:payments:reporter
  groups:
    - system:serviceaccounts
    - system:serviceaccounts:payments
    - system:authenticated
  resourceAttributes:
    namespace: payments
    group: ""
    resource: secrets
    verb: list
```

```
$ kubectl create -f sar.yaml -o jsonpath='{.status}{"\n"}'
{"allowed":false,"denied":false,"reason":"no relation found between subject and requested resource"}
```

Notá `allowed:false, denied:false` — ese es el resultado "no-opinion", que el apiserver convierte en un 403 porque ningún autorizador posterior lo permite.

### 7.6 Convergencia no destructiva con `kubectl auth reconcile`

`kubectl apply` sobre objetos RBAC reemplaza reglas y sujetos por completo, lo que puede quitar permisos que agregó otro equipo. `kubectl auth reconcile` fusiona en su lugar, y entiende la inmutabilidad de `roleRef`:

```
$ kubectl auth reconcile -f rbac/ --dry-run=client
clusterrole.rbac.authorization.k8s.io/platform:namespace-operator reconciled
    reconciliation required create
    missing rules added:
        {Verbs:["get" "list" "watch"], APIGroups:["networking.k8s.io"], Resources:["ingresses" "networkpolicies"]}
rolebinding.rbac.authorization.k8s.io/payments-operators reconciled (dry run)

$ kubectl auth reconcile -f rbac/ --remove-extra-permissions --remove-extra-subjects
clusterrole.rbac.authorization.k8s.io/platform:namespace-operator reconciled
rolebinding.rbac.authorization.k8s.io/payments-operators reconciled
```

Usá la forma simple para GitOps aditivo; los flags `--remove-extra-*` cuando los manifiestos son la única fuente de verdad y estás podando deriva deliberadamente.

---

## 8. Verificación, auditoría y diagnóstico de fallas

### 8.1 Leer un 403 correctamente

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:payments:reporter"
cannot list resource "pods" in API group "" in the namespace "billing"
```

Interpretalo como cinco variables independientes y verificá cada una:

| Campo en el mensaje | Qué verificar |
|---|---|
| `User "..."` | La identidad realmente presentada — no la que pretendías. Un kubeconfig desactualizado o un Pod que se olvidó de `serviceAccountName` aterriza acá. |
| `cannot <verb>` | ¿Está el verbo en tu regla? `list` ≠ `get`; `patch` ≠ `update`; `deletecollection` ≠ `delete`. |
| `resource "..."` | Plural, minúsculas, y la forma de *subrecurso* (`pods/log`) necesita su propia regla. |
| `API group "..."` | `""` es core. `apps`, `batch`, `networking.k8s.io`, `rbac.authorization.k8s.io` son separados. Un `ClusterRole` para `deployments` bajo `apiGroups: [""]` no coincide con nada. |
| `in the namespace "..."` | ¿Está el binding en *ese* namespace? Un `RoleBinding` en `payments` no otorga nada en `billing`. |

Un mensaje sutilmente distinto significa algo distinto:

```
Error from server (Forbidden): pods is forbidden: User "sre-alex" cannot list resource "pods"
in API group "" at the cluster scope
```

"at the cluster scope" significa que la petición fue para **todos los namespaces** (`-A` / sin namespace). Eso requiere un `ClusterRoleBinding`; un `RoleBinding` nunca lo satisfará, incluso apuntando al mismo `ClusterRole`.

### 8.2 La lista de triage de RBAC en ocho puntos

Ejecutá esto en orden; cada paso elimina una clase de causa.

```bash
# 1. Which identity is actually reaching the apiserver?
kubectl auth whoami

# 2. What does the authorizer think that identity can do here?
kubectl auth can-i --list --as=system:serviceaccount:payments:reporter -n payments

# 3. Does the binding exist, and does it point where you think?
kubectl -n payments get rolebinding -o wide

# 4. Does the subject in the binding match EXACTLY? (kind, name, namespace)
kubectl -n payments get rolebinding reporter -o jsonpath='{.subjects}' | jq .

# 5. Are the rules what you wrote? (apply may have replaced them)
kubectl -n payments describe role reporter

# 6. Is the API group / resource string correct for this resource?
kubectl api-resources | grep -E '^NAME|deployments|networkpolicies'

# 7. Is roleRef stale? (immutable — an "updated" binding may still point elsewhere)
kubectl -n payments get rolebinding reporter -o jsonpath='{.roleRef}' ; echo

# 8. Is RBAC even in the chain, and is something permissive ahead of it?
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -i authoriz
```

El paso 4 detecta el error más común de todos: los sujetos de `kind: ServiceAccount` **requieren** un campo `namespace` explícito, porque un `ClusterRoleBinding` no tiene namespace propio y un `RoleBinding` puede legítimamente otorgar a una ServiceAccount de otro namespace.

```
$ kubectl -n payments get rolebinding reporter -o jsonpath='{.subjects}' | jq .
[
  {
    "kind": "ServiceAccount",
    "name": "reporter",
    "namespace": "payments"
  }
]
```

El paso 7 detecta la trampa de la inmutabilidad:

```
$ kubectl -n payments patch rolebinding reporter --type=merge \
    -p '{"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"view"}}'
The RoleBinding "reporter" is invalid: roleRef: Invalid value:
rbac.RoleRef{APIGroup:"rbac.authorization.k8s.io", Kind:"ClusterRole", Name:"view"}:
cannot change roleRef

$ kubectl -n payments delete rolebinding reporter && kubectl apply -f rolebinding.yaml
rolebinding.rbac.authorization.k8s.io "reporter" deleted
rolebinding.rbac.authorization.k8s.io/reporter created
```

### 8.3 Evidencia del lado del servidor: anotaciones de auditoría

Cada petición auditada lleva el veredicto del autorizador como anotaciones, que es la respuesta autoritativa a "*por qué* se permitió esto?".

Política de auditoría enfocada en la superficie de RBAC y credenciales:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Full bodies for every RBAC mutation — this is the change log that matters.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Any use of impersonation, and any exec/attach/portforward.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
      - group: "authentication.k8s.io"
        resources: ["*"]

  # Secret access: metadata only — never log Secret bodies into a log pipeline.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps", "serviceaccounts/token"]

  # Anonymous and unauthenticated traffic, whatever it touches.
  - level: Metadata
    userGroups: ["system:unauthenticated"]

  # Silence the high-volume, low-value control-plane read loop.
  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
    verbs: ["get", "list", "watch"]

  - level: Metadata
```

Un registro resultante:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "6b2a9f1c-3d4e-4a58-9b07-1c2d3e4f5061",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/payments/secrets?limit=500",
  "verb": "list",
  "user": {
    "username": "system:serviceaccount:payments:reporter",
    "uid": "8a2b1c9d-4e5f-4061-9a2b-3c4d5e6f7081",
    "groups": ["system:serviceaccounts", "system:serviceaccounts:payments", "system:authenticated"]
  },
  "sourceIPs": ["10.244.2.17"],
  "objectRef": { "resource": "secrets", "namespace": "payments", "apiVersion": "v1" },
  "responseStatus": { "metadata": {}, "status": "Failure", "reason": "Forbidden", "code": 403 },
  "requestReceivedTimestamp": "2026-07-30T11:42:17.881204Z",
  "stageTimestamp": "2026-07-30T11:42:17.884901Z",
  "annotations": {
    "authorization.k8s.io/decision": "forbid",
    "authorization.k8s.io/reason": ""
  }
}
```

Y para una petición permitida, `reason` nombra el binding exacto — así es como respondés "¿qué concesión es la responsable?" sin adivinar:

```
$ sudo jq -r 'select(.objectRef.resource=="secrets")
    | "\(.user.username)\t\(.verb)\t\(.annotations["authorization.k8s.io/decision"])\t\(.annotations["authorization.k8s.io/reason"])"' \
    /var/log/kubernetes/audit/audit.log | sort -u | head
system:serviceaccount:kube-system:generic-garbage-collector  list  allow  RBAC: allowed by ClusterRoleBinding "system:controller:generic-garbage-collector" of ClusterRole "system:controller:generic-garbage-collector" to ServiceAccount "generic-garbage-collector/kube-system"
system:serviceaccount:payments:reporter                      get   allow  RBAC: allowed by RoleBinding "reporter/payments" of Role "reporter" to ServiceAccount "reporter/payments"
system:serviceaccount:payments:reporter                      list  forbid
```

Buscá las concesiones peligrosas en todo el histórico:

```
$ sudo jq -r 'select(.annotations["authorization.k8s.io/reason"] // "" | test("cluster-admin"))
    | [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource] | @tsv' \
    /var/log/kubernetes/audit/audit.log | tail -5
2026-07-30T09:14:02.113Z  kubernetes-admin  create  clusterrolebindings
2026-07-30T09:14:55.907Z  kubernetes-admin  delete  pods
2026-07-30T10:02:31.442Z  sre-alex          patch   deployments
```

La impersonación aparece como un campo `impersonatedUser` distinto — alertá ante cualquier ocurrencia que no hayas autorizado:

```
$ sudo jq -r 'select(.impersonatedUser != null)
    | [.requestReceivedTimestamp, .user.username, "->", .impersonatedUser.username,
       (.impersonatedUser.groups // [] | join(","))] | @tsv' \
    /var/log/kubernetes/audit/audit.log
2026-07-30T11:41:02.884Z  kubernetes-admin  ->  system:serviceaccount:payments:reporter  system:serviceaccounts,system:serviceaccounts:payments
```

### 8.4 Logging verboso del autorizador (último recurso)

Cuando la razón de auditoría está vacía y necesitás la vista interna del autorizador, subí la verbosidad solo del paquete RBAC:

```
$ sudo sed -i '/- kube-apiserver/a\    - --vmodule=rbac*=5' /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo crictl logs -f $(sudo crictl ps -q --name kube-apiserver) 2>&1 | grep -i rbac
I0730 11:42:17.884213       1 rbac.go:104] RBAC: no rules authorize user "system:serviceaccount:payments:reporter" with groups ["system:serviceaccounts" "system:serviceaccounts:payments" "system:authenticated"] to "list" resource "secrets" in API group "" in the namespace "payments"
```

El formato exacto del log cambia entre versiones; el contenido no. **Revertí esto inmediatamente** — v5 en un apiserver ocupado produce gigabytes por hora y puede convertirse en sí mismo en un incidente de disponibilidad.

### 8.5 Consultas de auditoría continua

Estas son las verificaciones que vale la pena correr de forma programada. Todas son puro `kubectl` + `jq`, así que funcionan tanto en una VM de examen como en producción.

```bash
# A. Who holds cluster-admin, by any binding?
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name == "cluster-admin")
  | .metadata.name as $b | .subjects[]? | "\($b)\t\(.kind)/\(.namespace // "-")/\(.name)"'
```
```
cluster-admin           Group/-/system:masters
kubeadm:cluster-admins  Group/-/kubeadm:cluster-admins
```

```bash
# B. Every non-system role containing a wildcard.
kubectl get clusterroles,roles -A -o json | jq -r '
  .items[]
  | select(.metadata.name | startswith("system:") | not)
  | select(.rules[]? | (.verbs // [] | index("*")) or (.resources // [] | index("*")) or (.apiGroups // [] | index("*")))
  | "\(.kind)\t\(.metadata.namespace // "cluster")\t\(.metadata.name)"'
```
```
ClusterRole  cluster   legacy-ci-runner
Role         staging   debug-everything
```

```bash
# C. Any role granting the escalation verbs.
kubectl get clusterroles,roles -A -o json | jq -r '
  .items[] as $r | $r.rules[]?
  | select((.verbs // []) | any(. == "escalate" or . == "bind" or . == "impersonate"))
  | "\($r.kind)/\($r.metadata.namespace // "cluster")/\($r.metadata.name)\tverbs=\(.verbs)\tresources=\(.resources)"'
```

```bash
# D. Which ServiceAccounts are bound to anything at all?
kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | .roleRef.name as $role | .metadata.namespace as $ns | .kind as $k
  | .subjects[]? | select(.kind == "ServiceAccount")
  | "\($k)\t\($ns // "cluster")\t\(.namespace)/\(.name)\t-> \($role)"' | sort
```

```bash
# E. Pods still mounting a token they may not need.
kubectl get pods -A -o json | jq -r '
  .items[]
  | select([.spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken)] | length > 0)
  | "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.serviceAccountName)"' | head
```

```bash
# F. Any workload still using the namespace "default" ServiceAccount.
kubectl get pods -A -o json | jq -r '
  .items[] | select((.spec.serviceAccountName // "default") == "default")
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

```bash
# G. Legacy, non-expiring ServiceAccount token Secrets (should be empty post-1.24).
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name'
```

En producción, complementá esto con el herramental del ecosistema — `krew install who-can rbac-tool access-matrix` te da `kubectl who-can delete pods -n payments` y `kubectl rbac-tool viz` para un grafo. Tené en cuenta que ninguna de esas herramientas está disponible en el entorno del examen: las recetas con `jq` de arriba son la forma portable, y son las que deberías practicar.

---

## 9. Lista de verificación de hardening

Aplicá en este orden; cada paso es verificable de forma independiente.

1. **La cadena es `Node` y luego `RBAC`.** Sin `AlwaysAllow`, sin `ABAC`, sin webhook permisivo delante de RBAC. Verificá con la línea de comandos del apiserver.
2. **`--anonymous-auth=false`**, o anónimo acotado únicamente a endpoints de salud. Verificá con un `curl` no autenticado a `/api`.
3. **Ningún binding a `system:unauthenticated`, `system:anonymous` o `system:authenticated`** más allá de los tres defaults de bootstrap. Verificá con la consulta (A)/§6.4.
4. **`cluster-admin` vinculado a lo sumo a los sujetos de bootstrap.** Todo camino humano a cluster-admin pasa por un proceso auditado y acotado en el tiempo. Verificá con la consulta (A).
5. **`super-admin.conf` fuera de las laptops de ingeniería y de CI**, modo `0600`, solo en el nodo del plano de control.
6. **Una ServiceAccount por carga de trabajo**, nunca `default`. Verificá con la consulta (F).
7. **`automountServiceAccountToken: false`** en toda ServiceAccount y en la SA `default` de cada namespace; opt-in por Pod. Verificá con la consulta (E).
8. **Sin comodines** en `apiGroups`, `resources` o `verbs` fuera de los roles `system:`. Verificá con la consulta (B).
9. **Sin `escalate`, `bind`, `impersonate`** fuera del plano de control. Verificá con la consulta (C).
10. **Sin `list`/`watch` sobre `secrets`** para cargas de trabajo de aplicación; usá `get` + `resourceNames`, o mejor, un almacén de secretos externo con credenciales de vida corta.
11. **Sin `nodes/proxy`, `pods/exec`, `pods/attach`, `pods/portforward`, `pods/ephemeralcontainers`** en roles de régimen. Roles break-glass separados, auditados a nivel `RequestResponse`.
12. **Con ámbito de namespace por defecto.** Un `ClusterRoleBinding` requiere justificación escrita; una proyección `RoleBinding`→`ClusterRole` es el idioma por defecto.
13. **La política de auditoría cubre las mutaciones de RBAC a nivel `RequestResponse`** y el acceso a Secrets a nivel `Metadata`. Verificá haciendo un cambio y grepeando el log.
14. **Barreras de admission** (`ValidatingAdmissionPolicy`) que niegan nuevos bindings a `cluster-admin` y concesiones a sujetos anónimos.
15. **RBAC vive en Git**, reconciliado con `kubectl auth reconcile`, y las consultas de auditoría de arriba corren de forma programada con alertas ante nuevos hallazgos.

Deshabilitá el automount de la ServiceAccount `default` en todos los namespaces de una pasada:

```
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n "$ns" patch serviceaccount default \
      -p '{"automountServiceAccountToken": false}' 2>/dev/null
  done
serviceaccount/default patched
serviceaccount/default patched
serviceaccount/default patched
...

$ kubectl get sa -A -o json | jq -r '
    .items[] | select(.metadata.name=="default")
    | "\(.metadata.namespace)\tautomount=\(.automountServiceAccountToken // true)"'
default       automount=false
kube-node-lease  automount=false
kube-public   automount=false
kube-system   automount=false
payments      automount=false
```

Los componentes del plano de control en `kube-system` fijan `automountServiceAccountToken` explícitamente a nivel de Pod, así que este patch no los rompe — pero confirmá con `kubectl -n kube-system get pods` antes y después en cualquier clúster con operadores de terceros.

---

## 10. Recordatorios para la velocidad del examen

- `kubectl create role`/`clusterrole`/`rolebinding`/`clusterrolebinding` con `--dry-run=client -o yaml` es más rápido y menos propenso a errores que escribir YAML a mano:

```
$ kubectl create role reporter -n payments \
    --verb=get,list,watch --resource=pods,configmaps \
    --dry-run=client -o yaml
```
```
$ kubectl create clusterrole reader \
    --verb=get --resource=secrets --resource-name=db-creds \
    --dry-run=client -o yaml
```
```
$ kubectl create rolebinding reporter -n payments \
    --role=reporter --serviceaccount=payments:reporter \
    --dry-run=client -o yaml
```
- `--serviceaccount=<ns>:<name>` para sujetos SA, `--user=` para usuarios, `--group=` para grupos. Confundirlos produce un binding que silenciosamente no coincide con nadie.
- `--resource=pods/log` y `--resource=pods/exec` funcionan en `kubectl create role` para subrecursos.
- Verificá cada respuesta con `kubectl auth can-i ... --as=...`, incluyendo al menos un chequeo **negativo**. Una regla demasiado amplia pasa el chequeo positivo y falla la tarea.
- `roleRef` es inmutable: `delete` y después `create`, nunca `edit`.
- Si una tarea dice "solo en el namespace X", la respuesta es un `RoleBinding`, incluso cuando referencia un `ClusterRole`.

---

## Referencias

- Kubernetes — *Using RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Authorization Overview*: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — *Authenticating*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes — *Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Webhook Mode*: https://kubernetes.io/docs/reference/access-authn-authz/webhook/
- Kubernetes — *Admission Controllers Reference (NodeRestriction, ServiceAccount)*: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — *Managing Service Accounts*: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Configure Service Accounts for Pods*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Certificate Signing Requests*: https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Kubernetes — *Certificates and Certificate Management*: https://kubernetes.io/docs/tasks/administer-cluster/certificates/
- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *kube-apiserver Reference*: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — *kubectl auth (can-i, whoami, reconcile)*: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/
- Kubernetes — *Controlling Access to the Kubernetes API*: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes — *Securing a Cluster*: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — *Kubernetes API Access Control (RBAC good practices)*: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
- Kubernetes — *kubeadm: super-admin.conf and admin.conf*: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Kubernetes — *Feature Gates*: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF — *Curriculum repository*: https://github.com/cncf/curriculum
- CIS — *Kubernetes Benchmark* (secciones 1.2 API server, 5.1 RBAC and Service Accounts): https://www.cisecurity.org/benchmark/kubernetes
- NSA/CISA — *Kubernetes Hardening Guide*: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF