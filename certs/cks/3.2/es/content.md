# CKS 3.2 — Ser cauteloso en el uso de Service Accounts

**Dominio:** Cluster Hardening (15%) · **Peso del tema:** 3.75 · **Kubernetes:** v1.34

---

## 1. El problema de arquitectura en producción

### 1.1 Todo Pod es un principal autenticado por defecto

Kubernetes no tiene noción de «workload anónimo». En el instante en que un Pod es admitido, el admission plugin `ServiceAccount` le resuelve una ServiceAccount — la que hayas nombrado, o `default` — y, salvo que se indique explícitamente lo contrario, inyecta un JWT firmado en el sistema de archivos del contenedor, en `/var/run/secrets/kubernetes.io/serviceaccount/token`.

Esto significa que el estado *de base* de un cluster es: **todo proceso en todo contenedor posee una credencial bearer para la API del control plane.** No una capacidad acotada a lo que el workload necesita, sino una identidad completa, presentada ante `kubernetes.default.svc:443`, que es alcanzable desde el network namespace de cualquier Pod salvo que una NetworkPolicy diga lo contrario.

Desde una perspectiva de SRE/modelado de atacante, esto colapsa dos cosas que deberían estar separadas:

| Preocupación | Lo que debería ser | Lo que da el default |
|---|---|---|
| Alcanzabilidad de red del API server | opt-in | universal (ClusterIP `kubernetes.default`) |
| Posesión de una credencial del control plane | opt-in | universal (automount `true`) |
| Radio de impacto de esa credencial | por workload | por *namespace* (SA `default` compartida) |

La tercera fila es la que quema a los equipos. `default` es una identidad compartida, acotada al namespace. En el instante en que alguien ejecuta `kubectl create rolebinding debug --clusterrole=edit --serviceaccount=payments:default -n payments` para destrabar una demo, **todos** los workloads de `payments` que nunca fijaron `serviceAccountName` ganan `edit` en silencio. No hay ningún evento de auditoría que diga «17 Deployments no relacionados acaban de ser promovidos» — el otorgamiento es invisible a nivel de workload.

### 1.2 La kill chain canónica

```
   ┌────────────────────────────────────────────────────────────────┐
   │ 1. Initial access                                              │
   │    RCE in app / vulnerable dependency / SSRF / log4shell-class │
   └───────────────────────────┬────────────────────────────────────┘
                               │  read a file, or make an HTTP call
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 2. Credential harvest                                          │
   │    cat /var/run/secrets/kubernetes.io/serviceaccount/token     │
   │    (SSRF variant: no code exec needed — just file:// or a      │
   │     templating engine that reads local paths)                  │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 3. Reconnaissance                                              │
   │    curl -H "Authorization: Bearer $TOK" https://kubernetes...  │
   │    SelfSubjectRulesReview → "what am I allowed to do?"         │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 4. Escalation primitive (pick one)                             │
   │    get secrets            → steal other SAs' / DB credentials  │
   │    create pods            → mount hostPath /, or run as another SA │
   │    create pods/exec       → enter a higher-privileged Pod      │
   │    create sa/token        → mint a token for a privileged SA   │
   │    impersonate            → become cluster-admin directly      │
   │    escalate / bind        → write your own ClusterRoleBinding  │
   └───────────────────────────┬────────────────────────────────────┘
                               ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ 5. Persistence / cluster takeover                              │
   └────────────────────────────────────────────────────────────────┘
```

El paso 2 es gratis por el automounting. El paso 3 es gratis por la alcanzabilidad de red. El paso 4 es donde la minimización de RBAC es el *único* control que importa.

### 1.3 Por qué el modelo de tokens legacy estaba estructuralmente roto

Antes de v1.24, crear una ServiceAccount hacía que el controller-manager autogenerara un `Secret` de tipo `kubernetes.io/service-account-token` conteniendo un **JWT sin claim `exp`, sin claim `aud` y sin vínculo con ningún objeto**.

Consecuencias:

- **La exfiltración era permanente.** La única revocación era borrar la ServiceAccount (lo que cambia su UID e invalida el token). Rotar un token significaba romper a todos los consumidores simultáneamente.
- **Replay en cualquier lado.** Sin claim de audience, un token destinado al API server era igualmente válido en cualquier otro servicio que verificara ingenuamente la firma — un amplificador clásico de confused deputy (Vault, Istio, y toda integración del tipo «autenticá mi pod con su token de SA»).
- **Proliferación de Secrets.** Cada SA producía un Secret; cualquiera con `get secrets` en el namespace poseía todas las identidades de ese namespace.

KEP-1205 (Bound Service Account Tokens) y KEP-2799 (Reduction of Secret-Based Service Account Tokens) reemplazaron esto. Desde v1.24 no se crea automáticamente ningún Secret de token; desde v1.22 el token inyectado es un JWT **projected, acotado en el tiempo, acotado por audience y vinculado a un objeto**, emitido a través de la API TokenRequest.

### 1.4 Lo que sigue sin resolverse

Sé preciso sobre lo que la higiene moderna de tokens te compra y lo que no — esta es la diferencia entre una respuesta que aprueba el CKS y un diseño correcto de producción:

- Los bound tokens acortan la *ventana* de una credencial robada; no reducen su *autoridad*. Un token de 1 hora con `cluster-admin` es un compromiso total del cluster.
- `automountServiceAccountToken: false` **no es una frontera de seguridad frente a quien puede escribir specs de Pod.** El autor de un Pod puede volver a ponerlo en `true`, o directamente omitir el campo y montar a mano un volumen projected `serviceAccountToken`.
- La ClusterIP del API server es alcanzable desde todo Pod por defecto. Quitar el token no quita el camino.

Por eso la verdadera pila de controles es en capas:

| Capa | Control | Detiene |
|---|---|---|
| Identidad | SA dedicada por workload, nunca `default` | Filtración de privilegios entre workloads |
| Autorización | Role/RoleBinding de mínimo privilegio, `resourceNames` donde sea posible | Escalada tras el robo |
| Exposición de credenciales | `automountServiceAccountToken: false` | Cosecha trivial vía lectura de archivo / SSRF |
| Vida útil de la credencial | Bound projected tokens, `expirationSeconds` corto, `audience` no por defecto | Replay y exfiltración de larga duración |
| Admisión | ValidatingAdmissionPolicy / Kyverno aplicando lo anterior | Error del autor y bypass deliberado |
| Red | NetworkPolicy que niega egress al API server | Uso de un token cosechado desde ese Pod |
| Detección | Política de auditoría sobre el uso de tokens de SA + métricas de `authentication.k8s.io` | Todo lo que se coló |

---

## 2. Mecánica de tokens: qué hay realmente en el contenedor

### 2.1 El volumen projected que inyecta el admission plugin

Cuando se admite un Pod con automounting habilitado, el admission plugin `ServiceAccount` agrega este volumen a la spec del Pod (visible en el objeto *almacenado*, no en tu manifiesto):

```yaml
volumes:
  - name: kube-api-access-4xr2n
    projected:
      defaultMode: 420
      sources:
        - serviceAccountToken:
            expirationSeconds: 3607
            path: token
        - configMap:
            name: kube-root-ca.crt
            items:
              - key: ca.crt
                path: ca.crt
        - downwardAPI:
            items:
              - fieldRef:
                  apiVersion: v1
                  fieldPath: metadata.namespace
                path: namespace
```

Notas que un arquitecto debería internalizar:

- `expirationSeconds: 3607` — una hora más jitter. El kubelet vuelve a solicitar el token cuando supera el 80% de su vida útil (o 24 h, lo que ocurra primero) y **reemplaza el archivo atómicamente**. Los clientes de larga duración que leen el token una sola vez al arrancar empezarán a fallar con `401` aproximadamente a la hora. Este es el incidente de producción tipo «funcionaba en staging» más común de este tema.
- `audience` se omite, por lo que toma por defecto la audience del API server (`--api-audiences`, que a su vez toma por defecto `--service-account-issuer`).
- El `ca.crt` viene del ConfigMap `kube-root-ca.crt` que el controller publicador de la CA raíz coloca en todos los namespaces — no de un Secret.
- El nombre del volumen lleva un sufijo aleatorio (`kube-api-access-XXXXX`), razón por la cual no podés hacer grep confiablemente de un nombre fijo en una política.

### 2.2 Decodificar un token en vivo

```
$ kubectl -n payments exec deploy/api-gateway -- \
    cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

```json
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1785413607,
  "iat": 1785410000,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11",
  "kubernetes.io": {
    "namespace": "payments",
    "node": {
      "name": "worker-2",
      "uid": "b0c1e6f2-9a44-4b1f-8f0a-7d2c3e5a9b10"
    },
    "pod": {
      "name": "api-gateway-7d9f6c4b58-mk2vq",
      "uid": "c7d2a1b3-55e6-4f77-9a01-3b8e2f6d4c99"
    },
    "serviceaccount": {
      "name": "api-gateway",
      "uid": "5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57"
    },
    "warnafter": 1785413200
  },
  "nbf": 1785410000,
  "sub": "system:serviceaccount:payments:api-gateway"
}
```

Qué te aporta cada claim relevante para la seguridad:

| Claim | Propósito | Propiedad de seguridad |
|---|---|---|
| `sub` | El sujeto RBAC | `system:serviceaccount:<ns>:<name>` — esto es lo que hacen coincidir los RoleBindings |
| `aud` | Verificador previsto | Un token emitido para `vault` es rechazado por el API server, y viceversa |
| `exp` / `nbf` | Ventana de validez | Acota el valor de la exfiltración |
| `jti` | ID único del token | Aparece en los logs de auditoría → podés rastrear *qué* token realizó una acción |
| `kubernetes.io.pod` | Objeto vinculado | El token deja de ser válido cuando ese objeto Pod se elimina |
| `kubernetes.io.node` | Vínculo con el nodo | Habilita validación acotada al nodo; el API server puede rechazar un token presentado después de que el objeto Node desapareció |
| `warnafter` | Pista para el kubelet | Timestamp a partir del cual el API server emite una advertencia/métrica de «stale token» |

El vínculo con el Pod es el importante: **borrar el Pod revoca el token de inmediato**, sin tocar la ServiceAccount. Esa es una palanca real y utilizable de respuesta a incidentes.

### 2.3 Flags del control plane que gobiernan todo esto

```
$ kubectl -n kube-system get pod kube-apiserver-cp-1 \
    -o jsonpath='{.spec.containers[0].command}' | tr ' ' '\n' | grep -E 'service-account|api-audiences'
```

```
--service-account-issuer=https://kubernetes.default.svc.cluster.local
--service-account-key-file=/etc/kubernetes/pki/sa.pub
--service-account-signing-key-file=/etc/kubernetes/pki/sa.key
--api-audiences=https://kubernetes.default.svc.cluster.local
--service-account-lookup=true
```

| Flag | Significado | Guía de hardening |
|---|---|---|
| `--service-account-issuer` | Claim `iss`; puede repetirse para rotación de issuer | Fijalo a una URL estable y resoluble externamente si federás con un IAM de nube |
| `--service-account-signing-key-file` | Clave privada usada por TokenRequest | Debe estar presente o TokenRequest (y por lo tanto todos los tokens modernos) queda deshabilitado |
| `--service-account-key-file` | Claves públicas aceptadas para verificación; repetible | Mantené la clave vieja y la nueva durante la rotación, después descartá la vieja |
| `--api-audiences` | Audiences que el API server acepta | Fijalo explícitamente; habilita emitir tokens que el API server *no* aceptará |
| `--service-account-lookup` | Valida que la SA (y el objeto vinculado) todavía exista | Dejalo en `true`; esto es lo que hace que el borrado revoque de verdad |
| `--service-account-max-token-expiration` | Limita el TTL solicitado | Fijalo a p. ej. `24h` para que ningún consumidor pueda pedir un token de un año |
| `--service-account-extend-token-expiration` | Compatibilidad: extiende silenciosamente a ~1 año los tokens de clientes in-tree | Ponelo en `false` cuando las métricas muestren cero uso de tokens stale |

---

## 3. Análisis comparativo

### 3.1 Mecanismos de entrega de tokens

| Mecanismo | TTL | `aud` | Vínculo con objeto | Revocable mediante | Uso correcto en 2026 |
|---|---|---|---|---|---|
| Secret legacy `kubernetes.io/service-account-token` | ninguno (∞) | ninguna | ninguno | borrar la SA | Nunca. Migrá fuera de él. Solo creable manualmente desde v1.24 |
| Token projected autoinyectado | ~1 h, rotado automáticamente | API server | Pod (+ Node) | borrar el Pod o la SA | Default para clientes in-cluster que realmente llaman a la API |
| Volumen projected explícito con `audience`/`expirationSeconds` propios | vos elegís (mín. 600 s) | vos elegís | Pod | borrar el Pod | Autenticación service-to-service (Vault, Istio, verificadores estilo SPIFFE) |
| `kubectl create token` / API TokenRequest | vos elegís, limitado por el API server | vos elegís | opcional (`--bound-object-*`) | borrar el objeto vinculado / la SA | Sistemas de CI, break-glass, automatización de corta duración |
| Federación OIDC vía issuer discovery | del lado de la nube, minutos | audience de la nube | Pod | borrado del Pod | Reemplazar claves estáticas de IAM de nube dentro de Pods |

### 3.2 Dónde deshabilitar el automounting — y qué garantiza realmente cada nivel

Orden de resolución de `automountServiceAccountToken` (**gana la primera coincidencia**):

```
pod.spec.automountServiceAccountToken   (explicitly true or false)
        ↓ unset
serviceAccount.automountServiceAccountToken   (explicitly true or false)
        ↓ unset
true   ← the dangerous default
```

| Fijado en | Efecto | Eludible por | Veredicto |
|---|---|---|---|
| Pod / PodTemplate | Autoritativo para ese Pod | El autor del Pod (es su propio campo) | Higiene correcta, no una frontera |
| ServiceAccount (incl. `default`) | Fallback a nivel de namespace | Cualquier Pod que ponga el campo en `true` | Buena línea base; atrapa las omisiones |
| ValidatingAdmissionPolicy / Kyverno | Rechaza el Pod en la admisión | Solo por alguien que pueda editar políticas | **La frontera real** |
| NetworkPolicy que niega egress al API server | El token queda inútil desde ese Pod | Alguien que pueda editar NetworkPolicies | Fuerte defensa en profundidad |

La secuencia relevante para el examen es: parchear la SA `default` en todos los namespaces **y** fijar el campo explícitamente en las specs de Pod de los workloads **y** respaldarlo con una política de admisión. Hacer solo lo primero es la respuesta incompleta clásica.

### 3.3 Verbos RBAC ordenados por poder de escalada

Cuando «minimizás permisos en cuentas de servicio recién creadas», estos son los otorgamientos que convierten una SA acotada en un compromiso del cluster. Tratá a cualquiera de ellos como un otorgamiento equivalente a cluster-admin salvo prueba en contrario.

| Otorgamiento | Por qué equivale a cluster-admin | Alternativa más segura |
|---|---|---|
| `secrets: get/list` (a nivel de namespace) | Lee todas las credenciales del namespace, incluidos los tokens creados manualmente de otras SAs | `resourceNames: [<one secret>]` |
| `pods: create` | Crear un Pod con `serviceAccountName: <privileged-sa>`, o `hostPath: /`, o `hostPID` | Denegar; usar un controller con un template fijo |
| `pods/exec`, `pods/attach`, `pods/portforward` | Entrar a un Pod ya privilegiado | Denegar; usar ephemeral debug containers habilitados por una persona |
| `serviceaccounts/token: create` | Emitir un token nuevo para **cualquier** SA en alcance | `resourceNames` restringido a exactamente una SA |
| `rbac: escalate` / `bind` | Escribir un binding que otorgue más de lo que uno tiene | Denegar de plano |
| `users/groups/serviceaccounts: impersonate` | Convertirse en cualquier sujeto | Denegar de plano |
| `deployments`, `daemonsets`, `statefulsets`, `jobs`, `cronjobs`: create/update | `pods: create` indirecto a través de un controller | Acotar con `resourceNames` + política de admisión sobre el Pod resultante |
| `nodes: patch`/`update` (o `nodes/status`) | Manipular el scheduling, quitar taints, apuntar al control plane | Denegar a los workloads |
| `certificatesigningrequests/approval`, `signers: approve` | Emitir un certificado de cliente para `system:masters` | Denegar |
| `validatingwebhookconfigurations`/`mutatingwebhookconfigurations`: create | Inyectar un webhook que mute todos los objetos del cluster | Denegar |
| `persistentvolumes: create` | PV con `hostPath` → sistema de archivos del nodo | Denegar |

Dos reglas estructurales que se desprenden:

1. **Preferí `Role` + `RoleBinding` sobre `ClusterRole` + `ClusterRoleBinding`.** Un `ClusterRole` referenciado por un `RoleBinding` queda acotado al namespace y es la forma correcta de reutilizar un conjunto de reglas sin otorgar alcance de cluster.
2. **Nunca ates nada a `system:serviceaccounts` ni a `system:serviceaccounts:<ns>`.** Esos grupos contienen todas las SAs, incluidas las que se creen mañana.

---

## 4. Manifiestos completos

### 4.1 Línea base del namespace: una ServiceAccount `default` neutralizada

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    kubernetes.io/metadata.name: payments
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    security.example.com/sa-hygiene: enforced
---
# The 'default' SA cannot be deleted (the controller recreates it),
# so it is neutralised instead: no token, no image pull secrets.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: payments
  annotations:
    security.example.com/rationale: >-
      Hardened baseline. No workload may bind RBAC to this SA;
      see ValidatingAdmissionPolicy sa-hygiene.security.example.com.
automountServiceAccountToken: false
```

### 4.2 Una identidad de workload correctamente acotada

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-gateway
  namespace: payments
  labels:
    app.kubernetes.io/name: api-gateway
automountServiceAccountToken: false     # opt-in per Pod, never by default
---
# Least privilege: read exactly two ConfigMaps and watch Endpoints for
# service discovery. Nothing else. Note resourceNames on the get/list path.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-gateway
  namespace: payments
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-gateway-routes", "api-gateway-tls-policy"]
    verbs: ["get", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-gateway
  namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: api-gateway
subjects:
  - kind: ServiceAccount
    name: api-gateway
    namespace: payments
```

> **Salvedad sobre `resourceNames`:** no puede restringir `list` ni `watch` en la mayoría de los recursos cuando el cliente hace una petición de colección — el authorizer no tiene un nombre individual con el cual comparar. Sí funciona para `get`, `update`, `patch`, `delete`. Acá se permite `watch` sobre un ConfigMap nombrado porque el cliente observa un único objeto por nombre (`fieldSelector=metadata.name=...`); un `watch` de colección a secas sería denegado. Verificá con `kubectl auth can-i` antes de mandarlo a producción.

### 4.3 Deployment: identidad explícita, token explícito, audience explícita

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: payments
  labels:
    app.kubernetes.io/name: api-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: api-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-gateway
      annotations:
        security.example.com/apiserver-access: "required"
    spec:
      serviceAccountName: api-gateway
      # Suppress the implicit injection: we mount the token ourselves,
      # with a TTL and audience we control, at a non-default path.
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: gateway
          image: registry.example.com/payments/api-gateway:1.14.3
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: KUBE_TOKEN_PATH
              value: /var/run/secrets/api/token
            - name: KUBE_CA_PATH
              value: /var/run/secrets/api/ca.crt
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
          volumeMounts:
            - name: apiserver-token
              mountPath: /var/run/secrets/api
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: apiserver-token
          projected:
            defaultMode: 0400
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 900          # 15 min; kubelet rotates at 80%
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

`defaultMode: 0400` más `runAsNonRoot` más una ruta no estándar significa que un exploit genérico que hace grep de `/var/run/secrets/kubernetes.io/serviceaccount/token` no encuentra nada. Eso es oscuridad, no seguridad — pero derrota gratis a una fracción grande del tooling de uso masivo.

### 4.4 Un sidecar que *no* debe alcanzar el API server

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: log-shipper
  namespace: payments
spec:
  serviceAccountName: log-shipper
  automountServiceAccountToken: false
  containers:
    - name: shipper
      image: registry.example.com/obs/vector:0.41.1
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-shipper
  namespace: payments
automountServiceAccountToken: false
# Deliberately no Role and no RoleBinding: this identity is authenticated
# but authorized for nothing. Even a stolen token yields only 403s.
```

### 4.5 Aplicación en la admisión con ValidatingAdmissionPolicy (in-tree, sin webhook)

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: sa-hygiene.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # Never gate control-plane static/mirror pods.
    - name: exclude-mirror-pods
      expression: >-
        !has(object.metadata.annotations) ||
        !('kubernetes.io/config.mirror' in object.metadata.annotations)
  variables:
    - name: sa
      expression: >-
        has(object.spec.serviceAccountName) && object.spec.serviceAccountName != ''
          ? object.spec.serviceAccountName : 'default'
    - name: automount
      expression: >-
        has(object.spec.automountServiceAccountToken)
          ? object.spec.automountServiceAccountToken : true
    - name: manualTokenVolumes
      expression: >-
        has(object.spec.volumes)
          ? object.spec.volumes.filter(v,
              has(v.projected) && has(v.projected.sources) &&
              v.projected.sources.exists(s, has(s.serviceAccountToken)))
          : []
    - name: declared
      expression: >-
        has(object.metadata.annotations) &&
        'security.example.com/apiserver-access' in object.metadata.annotations &&
        object.metadata.annotations['security.example.com/apiserver-access'] == 'required'
  validations:
    - expression: "variables.sa != 'default'"
      reason: Forbidden
      messageExpression: >-
        'pod ' + object.metadata.name +
        ' must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable'

    - expression: "variables.automount == false"
      reason: Forbidden
      message: >-
        spec.automountServiceAccountToken must be explicitly false; mount a
        projected serviceAccountToken volume with an explicit audience and
        expirationSeconds instead

    - expression: "size(variables.manualTokenVolumes) == 0 || variables.declared"
      reason: Forbidden
      message: >-
        pods that project a serviceAccountToken volume must carry the annotation
        security.example.com/apiserver-access=required

    - expression: >-
        variables.manualTokenVolumes.all(v,
          v.projected.sources.filter(s, has(s.serviceAccountToken)).all(s,
            has(s.serviceAccountToken.expirationSeconds) &&
            s.serviceAccountToken.expirationSeconds <= 3600))
      reason: Forbidden
      message: "projected serviceAccountToken volumes must set expirationSeconds <= 3600"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: sa-hygiene-binding
spec:
  policyName: sa-hygiene.security.example.com
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

**Disciplina de roll-out:** desplegá primero con `validationActions: ["Audit", "Warn"]`, leé `apiserver_validating_admission_policy_check_total{enforcement_action="audit"}` y las anotaciones de auditoría, corregí a los infractores, y recién entonces pasá a `Deny`. Ir directo a `Deny` sobre `pods` es la forma de trabar un cluster durante un drain de nodo.

**Trampa de diagnóstico:** esta política matchea `pods`, pero los usuarios crean `Deployments`. Por lo tanto el rechazo aparece en el ReplicaSet, no en el `kubectl apply`. El `kubectl apply` tiene éxito y el Deployment simplemente nunca escala. Ver §6.3.

### 4.6 Política equivalente en Kyverno (cuando necesitás mutación, no solo validación)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: service-account-hygiene
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: disallow-default-sa
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kube-node-lease", "kube-public"]
      validate:
        message: "Pods must not run as the 'default' ServiceAccount."
        pattern:
          spec:
            serviceAccountName: "!default"

    - name: default-automount-off
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system"]
      mutate:
        patchStrategicMerge:
          spec:
            +(automountServiceAccountToken): false   # add only if absent

    - name: forbid-rbac-to-default-sa
      match:
        any:
          - resources:
              kinds: ["RoleBinding", "ClusterRoleBinding"]
      validate:
        message: "RBAC must not be bound to a 'default' ServiceAccount or to the system:serviceaccounts groups."
        deny:
          conditions:
            any:
              - key: "{{ request.object.subjects[?name=='default'] | length(@) }}"
                operator: GreaterThan
                value: 0
              - key: "{{ request.object.subjects[?starts_with(name,'system:serviceaccounts')] | length(@) }}"
                operator: GreaterThan
                value: 0
```

La tercera regla es la que más equipos olvidan: vigilar los Pods no sirve de nada si alguien todavía puede atar `cluster-admin` a `payments:default`.

### 4.7 Contención en la capa de red

```yaml
---
# Default-deny egress in the namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Egress"]
---
# Allow DNS for everyone.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
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
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Only workloads explicitly labelled may reach the API server endpoints.
# 10.0.0.10/32 is the control-plane VIP in this cluster — derive it from
# `kubectl -n default get endpoints kubernetes`, not from a guess.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: payments
spec:
  podSelector:
    matchLabels:
      security.example.com/apiserver-client: "true"
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.10/32
      ports:
        - protocol: TCP
          port: 6443
```

`ipBlock` es obligatorio porque el endpoint del API server está fuera de la red de Pods, así que `namespaceSelector`/`podSelector` no pueden expresarlo. Confirmá la dirección:

```
$ kubectl -n default get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}'
10.0.0.10
```

### 4.8 Política de auditoría para el uso de tokens y la mutación de SAs

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Every token mint is a security event; capture the full request.
  - level: RequestResponse
    verbs: ["create"]
    resources:
      - group: ""
        resources: ["serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # Any RBAC change is a security event.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Anything done by a 'default' SA should not exist. Log it loudly.
  - level: Metadata
    users: []
    userGroups: []
    omitStages: ["RequestReceived"]
    namespaces: []
    # Matched by name pattern in the SIEM: sub == system:serviceaccount:*:default

  # Reads of Secrets by any service account.
  - level: Metadata
    userGroups: ["system:serviceaccounts"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["secrets"]

  - level: Metadata
```

Como el token ahora lleva un `jti`, una entrada de auditoría te permite pivotar de «esta acción» a «esta instancia exacta de token», y de ahí al UID del Pod que la poseía.

---

## 5. Recorrido por la CLI con salida real

### 5.1 Establecer la línea base

```
$ kubectl get serviceaccount -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,AUTOMOUNT:.automountServiceAccountToken \
  | head -12
```

```
NS            NAME                      AUTOMOUNT
default       default                   <none>
kube-node-lease default                 <none>
kube-public   default                   <none>
kube-system   attachdetach-controller   <none>
kube-system   coredns                   <none>
kube-system   default                   <none>
payments      api-gateway               false
payments      default                   false
payments      log-shipper               false
```

`<none>` significa «sin fijar», lo que significa **true**. Esos son tus huecos.

Parcheá todas las SAs `default` fuera del control plane:

```
$ for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep -vE '^kube-(system|public|node-lease)$'); do
    kubectl patch serviceaccount default -n "$ns" \
      -p '{"automountServiceAccountToken": false}'
  done
```

```
serviceaccount/default patched
serviceaccount/default patched
serviceaccount/default patched
```

### 5.2 Encontrar Pods que todavía llevan un token

```
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select((.spec.automountServiceAccountToken // true) == true)
    | [.metadata.namespace, .metadata.name, (.spec.serviceAccountName // "default")]
    | @tsv' | column -t
```

```
observability  grafana-6c9d4b7f88-t2xzq        default
observability  loki-0                          loki
tenant-b       legacy-batch-9f4c2-r7t8w        default
tenant-b       reporting-cron-29344160-hh9lp   default
```

Dos workloads con SA `default` en `tenant-b` con tokens vivos — ese es el hallazgo.

La verificación más fuerte es sobre el objeto Pod *almacenado*, porque un Pod puede llevar un token projected manualmente incluso con el automount deshabilitado:

```
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select(.spec.volumes // [] | any(.projected.sources // [] | any(.serviceAccountToken)))
    | [.metadata.namespace, .metadata.name] | @tsv' | column -t
```

```
payments   api-gateway-7d9f6c4b58-mk2vq
payments   api-gateway-7d9f6c4b58-p4wnl
payments   api-gateway-7d9f6c4b58-x8k3r
tenant-b   legacy-batch-9f4c2-r7t8w
```

### 5.3 Cazar tokens legacy basados en Secrets

```
$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
    -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\\.io/service-account\\.name,\
LASTUSED:.metadata.labels.kubernetes\\.io/legacy-token-last-used
```

```
NS         NAME                       SA              LASTUSED
tenant-b   legacy-batch-token-q7v2m   legacy-batch    2026-03-14
ci         jenkins-sa-token           jenkins         2026-07-29
```

`kubernetes.io/legacy-token-last-used` lo mantiene el controller de seguimiento de tokens legacy. Una fecha de hace meses significa que el token está sin uso y es seguro borrarlo; una fecha reciente significa que algo todavía depende de él — encontralo antes de borrar.

Confirmá desde las métricas del control plane:

```
$ kubectl get --raw /metrics | grep -E '^serviceaccount_(legacy|stale)' | grep -v '^#'
```

```
serviceaccount_legacy_tokens_total 2
serviceaccount_legacy_token_uses_total 41822
serviceaccount_stale_tokens_total 0
```

`serviceaccount_stale_tokens_total 0` es tu luz verde para poner `--service-account-extend-token-expiration=false`. Un `serviceaccount_legacy_token_uses_total` distinto de cero que sigue subiendo es tu backlog de migración.

### 5.4 Emitir e inspeccionar tokens bajo demanda

```
$ kubectl -n payments create token api-gateway --duration=10m
```

```
eyJhbGciOiJSUzI1NiIsImtpZCI6IlJoUWJVN0pOZDVfaG5FMEQxRzMtNU1GNGdpV0R0ZFdUMEdrRnpqUXlHRUUifQ.eyJhdWQiOlsiaHR0cHM6Ly9rdWJlcm5ldGVzLmRlZmF1bHQuc3ZjLmNsdXN0ZXIubG9jYWwiXSwiZXhwIjoxNzg1NDEwNjAwLCJpYXQiOjE3ODU0MTAwMDAsImlzcyI6Imh0dHBzOi8va3ViZXJuZXRlcy5kZWZhdWx0LnN2Yy5jbHVzdGVyLmxvY2FsIiwianRpIjoiYTFmM2M5ZDItNDRiNy00YzExLTk4ZjAtM2QyZTVhN2I5YzAxIiwia3ViZXJuZXRlcy5pbyI6eyJuYW1lc3BhY2UiOiJwYXltZW50cyIsInNlcnZpY2VhY2NvdW50Ijp7Im5hbWUiOiJhcGktZ2F0ZXdheSIsInVpZCI6IjVhMWY5YzJkLTdlMzMtNGE4OC1iMmM0LTZmOWQwZTFhM2I1NyJ9fSwibmJmIjoxNzg1NDEwMDAwLCJzdWIiOiJzeXN0ZW06c2VydmljZWFjY291bnQ6cGF5bWVudHM6YXBpLWdhdGV3YXkifQ.<signature>
```

Vinculalo a un Pod para que muera con el Pod:

```
$ POD=api-gateway-7d9f6c4b58-mk2vq
$ UID=$(kubectl -n payments get pod $POD -o jsonpath='{.metadata.uid}')
$ kubectl -n payments create token api-gateway \
    --duration=30m \
    --bound-object-kind Pod \
    --bound-object-name "$POD" \
    --bound-object-uid "$UID" > /tmp/tok
```

Emitir un token que el API server **rechazará** (acotado por audience para Vault):

```
$ kubectl -n payments create token api-gateway --audience=vault.example.com --duration=5m > /tmp/vault-tok
$ curl -sk -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $(cat /tmp/vault-tok)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/pods
```

```
401
```

Ese `401` es el sentido del claim de audience: incluso un token vinculado a Vault totalmente exfiltrado no vale nada contra el control plane.

### 5.5 Interrogar los permisos efectivos

```
$ kubectl auth can-i --list --as=system:serviceaccount:payments:api-gateway -n payments
```

```
Resources                                       Non-Resource URLs   Resource Names                                  Verbs
selfsubjectreviews.authentication.k8s.io        []                  []                                              [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []                                              [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []                                              [create]
configmaps                                      []                  [api-gateway-routes api-gateway-tls-policy]     [get watch]
endpointslices.discovery.k8s.io                 []                  []                                              [get list watch]
                                                [/healthz]          []                                              [get]
                                                [/livez]            []                                              [get]
                                                [/readyz]           []                                              [get]
                                                [/version]          []                                              [get]
```

Verificá puntualmente los verbos peligrosos de forma explícita:

```
$ for v in "get secrets" "create pods" "list secrets -A" "create serviceaccounts/token"; do
    printf '%-32s %s\n' "$v" \
      "$(kubectl auth can-i $v --as=system:serviceaccount:payments:api-gateway -n payments 2>/dev/null)"
  done
```

```
get secrets                      no
create pods                      no
list secrets -A                  no
create serviceaccounts/token     no
```

Verificación de identidad desde *adentro* de un Pod (v1.26+):

```
$ kubectl -n payments exec -it deploy/api-gateway -- \
    kubectl auth whoami --token=$(cat /var/run/secrets/api/token)
```

```
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:payments:api-gateway
UID                                                 5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57
Groups                                              [system:serviceaccounts system:serviceaccounts:payments system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11]
Extra: authentication.kubernetes.io/node-name       [worker-2]
Extra: authentication.kubernetes.io/node-uid        [b0c1e6f2-9a44-4b1f-8f0a-7d2c3e5a9b10]
Extra: authentication.kubernetes.io/pod-name        [api-gateway-7d9f6c4b58-mk2vq]
Extra: authentication.kubernetes.io/pod-uid         [c7d2a1b3-55e6-4f77-9a01-3b8e2f6d4c99]
```

Esos atributos `Extra:` son la recompensa moderna: el API server ahora sabe *qué Pod en qué Node* está llamando, y podés escribir webhooks de autorización o reglas de auditoría contra eso.

### 5.6 Reproducir el ataque y luego demostrar que falla

Antes del hardening:

```
$ kubectl -n tenant-b exec -it legacy-batch-9f4c2-r7t8w -- sh
/ # TOK=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
/ # CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
/ # curl -s --cacert $CA -H "Authorization: Bearer $TOK" \
      https://kubernetes.default.svc/api/v1/namespaces/tenant-b/secrets | head -20
```

```
{
  "kind": "SecretList",
  "apiVersion": "v1",
  "metadata": { "resourceVersion": "1884213" },
  "items": [
    {
      "metadata": { "name": "postgres-superuser", "namespace": "tenant-b" },
      "data": { "password": "c3VwM3JzM2NyM3RfcGc=" },
      "type": "Opaque"
    },
```

Después de aplicar §4.1–§4.4:

```
/ # ls /var/run/secrets/kubernetes.io/serviceaccount/
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

Y con un token suministrado deliberadamente (simulando uno robado):

```
$ curl -sk -H "Authorization: Bearer $(kubectl -n payments create token log-shipper)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/secrets | jq -r '.message'
```

```
secrets is forbidden: User "system:serviceaccount:payments:log-shipper" cannot list resource "secrets" in API group "" in the namespace "payments"
```

Autenticado, autorizado para nada. Ese es el estado objetivo.

### 5.7 Revocación de emergencia

Revocar la credencial de un solo Pod sin tocar nada más — el vínculo con el Pod hace el trabajo:

```
$ kubectl -n payments delete pod api-gateway-7d9f6c4b58-mk2vq
pod "api-gateway-7d9f6c4b58-mk2vq" deleted

$ curl -sk -H "Authorization: Bearer $(cat /tmp/tok)" \
    https://10.0.0.10:6443/api/v1/namespaces/payments/pods | jq -r '.message'
```

```
Unauthorized
```

Revocar *todos* los tokens de una identidad — recrear la SA, lo que cambia su UID:

```
$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57

$ kubectl -n payments delete sa api-gateway && kubectl apply -f sa-api-gateway.yaml
serviceaccount "api-gateway" deleted
serviceaccount/api-gateway created

$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
e3b0c442-98fc-4c14-8fca-1a2b3c4d5e6f
```

Todo token emitido previamente incrustó el UID viejo y ahora es rechazado. Los Pods en ejecución deben reiniciarse — el kubelet no puede refrescar un token para un UID que ya no existe.

### 5.8 Speed-run del examen CKS

```
$ kubectl create namespace build
namespace/build created

$ kubectl -n build create serviceaccount ci-runner
serviceaccount/ci-runner created

$ kubectl -n build patch serviceaccount default -p '{"automountServiceAccountToken":false}'
serviceaccount/default patched

$ kubectl -n build create role pod-reader --verb=get,list,watch --resource=pods
role.rbac.authorization.k8s.io/pod-reader created

$ kubectl -n build create rolebinding ci-runner-pod-reader \
    --role=pod-reader --serviceaccount=build:ci-runner
rolebinding.rbac.authorization.k8s.io/ci-runner-pod-reader created

$ kubectl auth can-i list pods -n build --as=system:serviceaccount:build:ci-runner
yes

$ kubectl auth can-i delete pods -n build --as=system:serviceaccount:build:ci-runner
no

$ kubectl -n build run probe --image=busybox:1.36 \
    --overrides='{"spec":{"serviceAccountName":"ci-runner","automountServiceAccountToken":false}}' \
    --restart=Never -- sleep 3600
pod/probe created

$ kubectl -n build exec probe -- ls /var/run/secrets/kubernetes.io/serviceaccount
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 1
```

Memorizá la forma `--overrides`: `kubectl run`/`kubectl create deployment` no tienen flag para `automountServiceAccountToken`, y bajo la presión de tiempo del examen editar YAML cuesta más que tipear el override.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Tabla de síntomas

| Síntoma | Causa más probable | Primer comando |
|---|---|---|
| `Unauthorized` (401), sin cuerpo de mensaje | Token expirado, SA borrada/recreada (UID no coincide), Pod vinculado borrado, o `aud` incorrecta | Decodificá el JWT: verificá `exp`, `aud`, `kubernetes.io.serviceaccount.uid` contra el UID de la SA viva |
| `... is forbidden: User "system:serviceaccount:..." cannot ...` (403) | Autenticó bien, RBAC insuficiente. El mensaje nombra recurso, verbo, grupo y alcance — leelo literalmente | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:<ns>:<sa> -n <ns>` |
| Funciona ~1 h y después da 401 para siempre | El cliente leyó el archivo del token una vez a memoria; el kubelet lo rotó | `kubectl exec -- stat -c '%y' <token path>`; arreglá el cliente para que relea o usá un SDK mantenido |
| `unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT must be defined` | En realidad no es un problema de token — Pod corriendo fuera de un contexto de cluster, o `hostNetwork` sin las variables de entorno | `kubectl exec -- env \| grep KUBERNETES_` |
| `open /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or directory` | Automount deshabilitado pero la app espera la ruta estándar | Decidí: rehabilitarlo con un volumen projected explícito, o apuntar la app a tu ruta propia |
| Pod trabado, `describe` muestra `error looking up service account <ns>/<sa>: serviceaccount "<sa>" not found` | `serviceAccountName` referencia una SA que no existe en ese namespace | `kubectl -n <ns> get sa` |
| El Deployment muestra `0/3` réplicas, sin Pods, sin error en el `apply` | La política de admisión rechazó el *Pod*, así que el fallo vive en el ReplicaSet | `kubectl -n <ns> describe rs -l app=<name>` |
| La SA tiene permisos que nunca otorgaste | Atada vía el grupo `system:serviceaccounts`, o un ClusterRole agregado incorporó una regla nueva | §6.4 |
| Todo da 403, incluso `/version` | El grupo `system:authenticated` no tiene binding a `system:public-info-viewer`, o la cadena de authorizers está mal configurada | `kubectl get clusterrolebinding system:public-info-viewer -o yaml` |

### 6.2 Leer correctamente un 401

Un 401 es autenticación, no autorización. Recorrelo en este orden:

```
$ TOK=$(kubectl -n payments exec deploy/api-gateway -- cat /var/run/secrets/api/token)

# 1. Is it expired?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '"exp=\(.exp)  now=\(now|floor)  remaining=\(.exp - (now|floor))s"'
exp=1785410600  now=1785412000  remaining=-1400s
```

Remaining negativo → expirado; el cliente está cacheando. Si el número es positivo:

```
# 2. Does the audience match what --api-audiences accepts?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.aud[]'
vault.example.com
```

Audience incorrecta. Si la audience es la correcta:

```
# 3. Does the embedded SA UID still match the live object?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."kubernetes.io".serviceaccount.uid'
5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57
$ kubectl -n payments get sa api-gateway -o jsonpath='{.metadata.uid}{"\n"}'
e3b0c442-98fc-4c14-8fca-1a2b3c4d5e6f
```

No coinciden → la SA fue borrada y recreada; todo Pod que la use debe reiniciarse.

```
# 4. Does the bound object still exist?
$ echo "$TOK" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."kubernetes.io".pod.name'
api-gateway-7d9f6c4b58-mk2vq
$ kubectl -n payments get pod api-gateway-7d9f6c4b58-mk2vq
Error from server (NotFound): pods "api-gateway-7d9f6c4b58-mk2vq" not found
```

La validación autoritativa, cuando tenés los permisos, es la API TokenReview — te dice exactamente qué piensa el API server:

```
$ cat <<EOF > /tmp/tr.json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {
    "token": "$TOK",
    "audiences": ["https://kubernetes.default.svc.cluster.local"]
  }
}
EOF
$ kubectl create --raw /apis/authentication.k8s.io/v1/tokenreviews -f /tmp/tr.json | jq .status
```

```json
{
  "authenticated": false,
  "error": "[invalid bearer token, service account token has expired]"
}
```

Un token sano devuelve:

```json
{
  "authenticated": true,
  "user": {
    "username": "system:serviceaccount:payments:api-gateway",
    "uid": "5a1f9c2d-7e33-4a88-b2c4-6f9d0e1a3b57",
    "groups": [
      "system:serviceaccounts",
      "system:serviceaccounts:payments",
      "system:authenticated"
    ],
    "extra": {
      "authentication.kubernetes.io/credential-id": ["JTI=8f4c1a7e-2b90-4b3d-9d6a-1c0f5b7e4a11"],
      "authentication.kubernetes.io/node-name": ["worker-2"],
      "authentication.kubernetes.io/pod-name": ["api-gateway-7d9f6c4b58-mk2vq"]
    }
  },
  "audiences": ["https://kubernetes.default.svc.cluster.local"]
}
```

> Enviar un token vivo a `TokenReview` es seguro contra tu propio API server (ya confía en él), pero nunca pegues tokens de producción en decodificadores JWT de terceros. Decodificá localmente con `base64 -d`.

### 6.3 Depurar rechazos de admisión que se esconden detrás de controllers

```
$ kubectl -n tenant-b apply -f reporting.yaml
deployment.apps/reporting created

$ kubectl -n tenant-b get deploy reporting
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
reporting   0/2     0            0           45s

$ kubectl -n tenant-b describe rs -l app=reporting | tail -8
```

```
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  12s (x5 over 44s)  replicaset-controller  Error creating: pods "reporting-6d4b8f9c7-" is forbidden:
    ValidatingAdmissionPolicy 'sa-hygiene.security.example.com' with binding 'sa-hygiene-binding' denied request:
    pod reporting-6d4b8f9c7- must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable
```

El arreglo va en `spec.template.spec`, no en el metadata propio del Deployment — una distinción con la que la gente tropieza repetidamente.

Probá la política en dry-run antes del rollout:

```
$ kubectl -n payments run policy-probe --image=busybox:1.36 --dry-run=server --restart=Never -- true
Error from server (Forbidden): admission webhook / policy denied the request:
  ValidatingAdmissionPolicy 'sa-hygiene.security.example.com' with binding 'sa-hygiene-binding' denied request:
  pod policy-probe must set spec.serviceAccountName to a dedicated ServiceAccount; the "default" SA is not usable
```

`--dry-run=server` ejecuta la cadena completa de admisión sin persistir. Es la forma más rápida de validar una política, y es legal en el examen.

### 6.4 Auditar Service Accounts con privilegios excesivos

Todo binding que alcance una SA `default`:

```
$ kubectl get rolebindings,clusterrolebindings -A -o json | jq -r '
    .items[]
    | . as $b
    | (.subjects // [])[]
    | select(.kind == "ServiceAccount" and .name == "default")
    | [$b.kind, ($b.metadata.namespace // "-"), $b.metadata.name, $b.roleRef.kind + "/" + $b.roleRef.name, .namespace]
    | @tsv' | column -t
```

```
ClusterRoleBinding  -         demo-quickfix    ClusterRole/cluster-admin  tenant-b
RoleBinding         tenant-b  batch-helper     ClusterRole/edit           tenant-b
```

Cualquier binding a los grupos `system:serviceaccounts*`:

```
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[] | . as $b | (.subjects // [])[]
    | select(.kind == "Group" and (.name | startswith("system:serviceaccounts")))
    | [$b.metadata.name, $b.roleRef.name, .name] | @tsv' | column -t
```

```
system:service-account-issuer-discovery   system:service-account-issuer-discovery   system:serviceaccounts
```

Ese es esperable (solo expone los endpoints de discovery OIDC). Cualquier otra cosa en esa lista es una emergencia.

Toda SA que posea una primitiva de escalada conocida:

```
$ for sa in $(kubectl get sa -A -o jsonpath='{range .items[*]}{.metadata.namespace}:{.metadata.name}{"\n"}{end}'); do
    ns=${sa%%:*}; name=${sa##*:}
    for perm in "create pods" "get secrets" "impersonate users" "create serviceaccounts/token" "escalate roles.rbac.authorization.k8s.io"; do
      if [ "$(kubectl auth can-i $perm --as=system:serviceaccount:$ns:$name -A 2>/dev/null)" = "yes" ]; then
        printf 'HIGH  %-40s %s\n' "$sa" "$perm"
      fi
    done
  done
```

```
HIGH  kube-system:daemon-set-controller        create pods
HIGH  kube-system:replicaset-controller        create pods
HIGH  kube-system:generic-garbage-collector    get secrets
HIGH  tenant-b:default                         create pods
HIGH  tenant-b:default                         get secrets
```

Los controllers del control plane son esperables; `tenant-b:default` es el incidente.

### 6.5 Verificar la superficie de discovery OIDC

Si federás tokens de SA a un IdP externo, los documentos de discovery deben ser alcanzables y correctos:

```
$ kubectl get --raw /.well-known/openid-configuration | jq .
```

```json
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://kubernetes.default.svc.cluster.local/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

```
$ kubectl get --raw /openid/v1/jwks | jq -r '.keys[].kid'
RhQbU7JNd5_hnE0D1G3-5MF4giWDtdWT0GkFzjQyGEE
```

Dos notas de hardening: exponer estos endpoints de forma anónima requiere atar `system:service-account-issuer-discovery` a `system:unauthenticated`, algo que la mayoría de los clusters **no** debería hacer; y el valor de `--service-account-issuer` debe ser la URL que el verificador externo pueda resolver realmente, no el nombre in-cluster.

### 6.6 Checklist previo al merge

Para cada workload nuevo, las siete deben ser verdaderas:

1. Existe una ServiceAccount dedicada; `serviceAccountName` está fijado explícitamente; no es `default`.
2. La ServiceAccount tiene `automountServiceAccountToken: false`.
3. El template del Pod fija `automountServiceAccountToken: false`, y proyecta un token explícitamente **solo si** el workload realmente llama al API server.
4. Los permisos vienen de un `Role` con namespace (o un `ClusterRole` referenciado por un `RoleBinding`), con `resourceNames` dondequiera que el verbo lo soporte, y sin ninguna de las primitivas de escalada de §3.3.
5. La salida de `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>` fue leída línea por línea y coincide con el documento de diseño.
6. `kubectl auth can-i <verb> <resource> -A --as=...` devuelve `no` para `create pods`, `get secrets`, `impersonate`, `escalate`, `bind` y `create serviceaccounts/token`.
7. El egress al API server está denegado por NetworkPolicy salvo que el workload esté etiquetado como cliente de la API.

---

## Referencias

- Kubernetes — *Service Accounts* (conceptos, mecánica de tokens, bound tokens): https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — *Configure Service Accounts for Pods* (automounting, projected tokens, `kubectl create token`): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Managing Service Accounts* (flags del control plane, issuer discovery, limpieza de tokens legacy): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Using RBAC Authorization* (prevención de escalada, `escalate`/`bind`, roles por defecto): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Authenticating* (tokens de service account, TokenReview, audiences): https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes API Reference — `TokenRequest`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/
- Kubernetes API Reference — `ServiceAccount`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/service-account-v1/
- Kubernetes API Reference — `TokenReview`: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/
- Kubernetes — *Projected Volumes* (fuente `serviceAccountToken`, `audience`, `expirationSeconds`): https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Kubernetes — *Admission Controllers Reference* (`ServiceAccount`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — referencia de línea de comandos de *kube-apiserver* (`--service-account-*`, `--api-audiences`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes — *Labels, Annotations and Taints* (`kubernetes.io/legacy-token-last-used`, `kubernetes.io/legacy-token-invalid-since`): https://kubernetes.io/docs/reference/labels-annotations-taints/
- Kubernetes — *Auditing*: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — `kubectl create token`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_token/
- Kubernetes — `kubectl auth can-i`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/
- KEP-1205 — *Bound Service Account Tokens*: https://github.com/kubernetes/enhancements/issues/1205
- KEP-2799 — *Reduction of Secret-Based Service Account Tokens*: https://github.com/kubernetes/enhancements/issues/2799
- KEP-4193 — *Bound Service Account Token Improvements* (JTI, claims de node/pod, vínculo con el nodo): https://github.com/kubernetes/enhancements/issues/4193
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Repositorio de currículas de CNCF: https://github.com/cncf/curriculum