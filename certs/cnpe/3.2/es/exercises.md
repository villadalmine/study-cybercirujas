# Ejercicios guiados — Tema 3.2: Applying RBAC and Security Controls Across Platform Resources

> **Contexto de plataforma.** Como Platform Engineer no configurás RBAC para un solo equipo: definís los *guardrails* que se aplican de forma consistente a decenas de namespaces de tenants, con self-service pero sin escalada de privilegios. Estos ejercicios recorren la pila completa de controles: authorization (RBAC), identidad de workloads (ServiceAccounts), admission control (Pod Security Admission + policy-as-code) y aislamiento de red (NetworkPolicy).
>
> **Requisitos.** Un cluster de prueba con permisos de `cluster-admin` (kind, minikube, k3s o un cluster efímero). No ejecutes estos pasos contra un cluster productivo compartido. Verificá tu versión: `kubectl version` — se asume Kubernetes ≥ 1.25 (Pod Security Admission GA).

---

## Ejercicio 1 — Least privilege para un tenant: Role, RoleBinding y ServiceAccount

Objetivo: aprovisionar acceso namespaced mínimo para el CI runner de un equipo, sin tocar recursos cluster-scoped.

**Pasos**

1. Creá el namespace del tenant y su ServiceAccount de CI:

   ```bash
   kubectl create namespace team-a
   kubectl create serviceaccount ci-runner --namespace team-a
   ```

2. Definí un `Role` con el mínimo necesario para desplegar: gestionar `deployments` y leer `pods`/`logs`. Guardalo como `role-ci.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: ci-deployer
     namespace: team-a
   rules:
     - apiGroups: ["apps"]
       resources: ["deployments", "replicasets"]
       verbs: ["get", "list", "watch", "create", "update", "patch"]
     - apiGroups: [""]
       resources: ["pods", "pods/log"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f role-ci.yaml
   ```

3. Enlazá el `Role` al ServiceAccount con un `RoleBinding` (`rb-ci.yaml`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: ci-runner-deployer
     namespace: team-a
   subjects:
     - kind: ServiceAccount
       name: ci-runner
       namespace: team-a
   roleRef:
     kind: Role
     name: ci-deployer
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f rb-ci.yaml
   ```

4. Verificá los permisos concedidos y los denegados mediante impersonation del ServiceAccount:

   ```bash
   kubectl auth can-i create deployments \
     --namespace team-a \
     --as system:serviceaccount:team-a:ci-runner
   # yes

   kubectl auth can-i delete deployments \
     --namespace team-a \
     --as system:serviceaccount:team-a:ci-runner
   # no

   kubectl auth can-i get secrets \
     --namespace team-a \
     --as system:serviceaccount:team-a:ci-runner
   # no

   kubectl auth can-i list pods \
     --namespace kube-system \
     --as system:serviceaccount:team-a:ci-runner
   # no
   ```

**Preguntas de comprensión**

1. El paso 4 muestra que `delete deployments` da `no` aunque el `Role` incluye el apiGroup `apps` y el recurso `deployments`. ¿Por qué?
2. ¿Por qué `list pods` en `kube-system` da `no` si el `Role` permite `list pods`? ¿Qué cambiaría si en vez de `Role`/`RoleBinding` hubieras usado `ClusterRole`/`ClusterRoleBinding`?
3. El `Role` no incluye ningún verbo sobre `secrets`. Un desarrollador argumenta "agreguemos `get secrets` por si el CI necesita variables". Desde least privilege, ¿qué alternativa proponés y por qué el `get` de secrets es especialmente peligroso comparado con `list`?

---

## Ejercicio 2 — Escalar a la plataforma: ClusterRoles y aggregation

Objetivo: evitar duplicar reglas en cada namespace. Definir una vez roles reutilizables cluster-wide y componerlos con label aggregation.

**Pasos**

1. Creá un `ClusterRole` reutilizable "view + logs" que la plataforma ofrecerá a todos los tenants (`cr-viewer.yaml`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform:app-viewer
   rules:
     - apiGroups: ["", "apps"]
       resources: ["pods", "pods/log", "deployments", "services", "configmaps"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f cr-viewer.yaml
   ```

2. Reutilizalo en un namespace concreto con un `RoleBinding` que apunta a un `ClusterRole` (el binding namespaced limita el alcance al namespace):

   ```bash
   kubectl create rolebinding team-a-viewers \
     --clusterrole=platform:app-viewer \
     --group=team-a-developers \
     --namespace=team-a
   ```

3. Ahora construí un `ClusterRole` **agregado**. Primero el "contenedor" con `aggregationRule` (`cr-aggregated.yaml`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform:tenant-admin
   aggregationRule:
     clusterRoleSelectors:
       - matchLabels:
           rbac.platform.io/aggregate-to-tenant-admin: "true"
   rules: []   # el control plane rellena esto automáticamente
   ```

4. Creá dos `ClusterRole` "aporte" con el label del selector (`cr-contributors.yaml`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform:tenant-workloads
     labels:
       rbac.platform.io/aggregate-to-tenant-admin: "true"
   rules:
     - apiGroups: ["apps", ""]
       resources: ["deployments", "statefulsets", "pods", "services"]
       verbs: ["*"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform:tenant-config
     labels:
       rbac.platform.io/aggregate-to-tenant-admin: "true"
   rules:
     - apiGroups: [""]
       resources: ["configmaps"]
       verbs: ["*"]
   ```

   ```bash
   kubectl apply -f cr-aggregated.yaml
   kubectl apply -f cr-contributors.yaml
   ```

5. Verificá que el control plane fusionó las reglas dentro del agregado:

   ```bash
   kubectl get clusterrole platform:tenant-admin -o yaml | grep -A30 '^rules:'
   ```

   Deberías ver `deployments`, `statefulsets`, `pods`, `services` **y** `configmaps` presentes, aunque `rules: []` estaba vacío al crearlo.

**Preguntas de comprensión**

1. En el paso 2 usaste un `RoleBinding` (namespaced) que referencia un `ClusterRole`. ¿En qué alcance queda efectivo el permiso: cluster-wide o solo `team-a`? ¿Qué habría cambiado con un `ClusterRoleBinding`?
2. En el paso 4 agregaste `platform:tenant-config`. Sin volver a editar `platform:tenant-admin`, sus permisos crecieron. Explicá el mecanismo y por qué esto es a la vez potente y un riesgo de seguridad para el operador de plataforma.
3. Un tenant pide `verbs: ["*"]` sobre `secrets` agregado al `tenant-admin`. ¿Qué riesgo de escalada de privilegios habilita conceder write sobre `secrets` **junto con** la capacidad de crear pods en el mismo namespace?

---

## Ejercicio 3 — Auditar RBAC: quién puede hacer qué

Objetivo: pasar de "creamos roles" a "podemos demostrar el estado de acceso". Auditoría reversa e impersonation.

**Pasos**

1. Enumerá todo lo que un subject puede hacer en un namespace con la vista propia del que impersona:

   ```bash
   kubectl auth can-i --list \
     --namespace team-a \
     --as system:serviceaccount:team-a:ci-runner
   ```

   Salida esperada (recortada):

   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   deployments.apps                                []                  []               [get list watch create update patch]
   replicasets.apps                                []                  []               [get list watch create update patch]
   pods                                            []                  []               [get list watch]
   pods/log                                        []                  []               [get list watch]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
   ```

2. Detectá subjects con privilegios peligrosos a nivel cluster. Buscá todo binding que otorgue `cluster-admin`:

   ```bash
   kubectl get clusterrolebindings -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects // [] | map(.kind+"/"+.name) | join(","))'
   ```

3. Instalá y usá `rbac-tool` (plugin de krew) para una vista *who-can*:

   ```bash
   kubectl krew install rbac-tool
   kubectl rbac-tool who-can delete secrets --namespace team-a
   kubectl rbac-tool who-can '*' '*'   # quién tiene comodín total
   ```

4. Generá el policy set efectivo de un subject y visualizalo:

   ```bash
   kubectl rbac-tool policy-rules -e '^system:serviceaccount:team-a:ci-runner$'
   ```

5. Probá una escalada real que RBAC debe bloquear — un subject intentando crear un binding a un rol más poderoso del que posee:

   ```bash
   # como cluster-admin, damos a ci-runner permiso de crear rolebindings pero NADA más poderoso
   kubectl create role rb-maker --verb=create --resource=rolebindings --namespace team-a
   kubectl create rolebinding ci-rb-maker --role=rb-maker \
     --serviceaccount=team-a:ci-runner --namespace team-a

   # ahora ci-runner intenta bindear cluster-admin (privilege escalation)
   kubectl create rolebinding pwn --clusterrole=cluster-admin \
     --serviceaccount=team-a:ci-runner --namespace team-a \
     --as system:serviceaccount:team-a:ci-runner
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): rolebindings.rbac.authorization.k8s.io "pwn" is forbidden:
   user "system:serviceaccount:team-a:ci-runner" (groups=[...]) is attempting to grant RBAC
   permissions not currently held: {...cluster-admin...}
   ```

**Preguntas de comprensión**

1. En el paso 1 aparecen `selfsubjectaccessreviews` y `selfsubjectrulesreviews` aunque nunca los concediste en el `Role`. ¿De dónde salen esos permisos y por qué todo authenticated user los tiene?
2. El paso 5 falla con "attempting to grant RBAC permissions not currently held". ¿Qué mecanismo del API server previene esta escalada, y en qué condición un subject con `create rolebindings` **sí** podría concederse cluster-admin?
3. ¿Por qué `kubectl auth can-i --list` es una fuente de verdad más confiable que leer los `Role`/`RoleBinding` a mano cuando auditás el acceso efectivo de un subject?

---

## Ejercicio 4 — Admission control con Pod Security Admission (PSA)

Objetivo: aplicar los Pod Security Standards (`privileged` / `baseline` / `restricted`) como guardrail por namespace, con los tres modos `enforce`/`audit`/`warn`.

**Pasos**

1. Etiquetá el namespace del tenant para forzar el nivel `restricted` en enforce, y también auditar/advertir contra `restricted`:

   ```bash
   kubectl label namespace team-a \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted \
     --overwrite
   ```

2. Intentá desplegar un pod que viola `restricted` (corre como root, sin `securityContext`):

   ```bash
   kubectl run bad-pod --image=nginx --namespace team-a
   ```

   Salida esperada:

   ```
   Error from server (Forbidden): pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest":
   allowPrivilegeEscalation != false (container "bad-pod" must set securityContext.allowPrivilegeEscalation=false),
   unrestricted capabilities (container "bad-pod" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "bad-pod" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "bad-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

3. Aplicá un pod conforme a `restricted` (`good-pod.yaml`):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: good-pod
     namespace: team-a
   spec:
     securityContext:
       runAsNonRoot: true
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:stable
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   kubectl apply -f good-pod.yaml
   # pod/good-pod created
   ```

4. Probá el modo `warn` sin bloquear: creá un namespace en `baseline`-enforce pero `restricted`-warn y observá el warning en el cliente:

   ```bash
   kubectl create namespace team-b
   kubectl label namespace team-b \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/warn=restricted --overwrite
   kubectl run warn-pod --image=nginx --namespace team-b
   ```

   Salida esperada:

   ```
   Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false, ...
   pod/warn-pod created
   ```

**Preguntas de comprensión**

1. En el paso 4, `warn-pod` se **crea** pese al warning, pero en el paso 2 `bad-pod` es **rechazado**. Explicá la diferencia entre los modos `enforce`, `warn` y `audit` y para qué sirve cada uno en un rollout de plataforma.
2. PSA opera a nivel de namespace y de pod-template. Un `Deployment` que crea pods no conformes en un namespace `enforce=restricted`: ¿el `Deployment` es rechazado, o algo más sutil ocurre? ¿Dónde verías el error?
3. ¿Por qué `enforce-version=latest` puede romper workloads existentes tras un upgrade del cluster, y qué estrategia usarías en una plataforma para pinnear la versión de forma segura?
4. PSA no puede exigir, por ejemplo, "solo imágenes de nuestro registry" ni "todo pod debe tener label `owner`". ¿Cuál es la limitación fundamental de PSA que motiva usar policy-as-code (siguiente ejercicio)?

---

## Ejercicio 5 — Policy-as-code: guardrails que PSA no cubre (Kyverno)

Objetivo: extender admission control más allá de los Pod Security Standards con validación y mutación declarativas. Los ejemplos usan Kyverno; el patrón equivale a OPA Gatekeeper con ConstraintTemplates.

**Pasos**

1. Instalá Kyverno:

   ```bash
   kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
   kubectl -n kyverno wait --for=condition=Ready pod -l app.kubernetes.io/component=admission-controller --timeout=120s
   ```

2. Aplicá una `ClusterPolicy` de **validación** que obliga a que todo pod lleve el label `owner` y bloquea imágenes fuera del registry corporativo (`policy-require.yaml`):

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: platform-guardrails
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: require-owner-label
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         validate:
           message: "Todo Pod debe tener el label 'owner'."
           pattern:
             metadata:
               labels:
                 owner: "?*"
       - name: restrict-registry
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         validate:
           message: "Las imágenes deben provenir de registry.corp.io/."
           pattern:
             spec:
               containers:
                 - image: "registry.corp.io/*"
   ```

   ```bash
   kubectl apply -f policy-require.yaml
   ```

3. Probá las dos reglas:

   ```bash
   kubectl run p1 --image=nginx --namespace team-a
   # Error ...: validation error: Las imágenes deben provenir de registry.corp.io/. ... require-owner-label ...

   kubectl run p2 --image=registry.corp.io/nginx --labels=owner=team-a \
     --namespace team-a --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"p2","image":"registry.corp.io/nginx","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
   # pod/p2 created   (pasa Kyverno Y PSA restricted)
   ```

4. Aplicá una policy de **mutación** que inyecta `automountServiceAccountToken: false` por defecto, cerrando el token de la API salvo opt-in explícito (`policy-mutate.yaml`):

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: default-deny-sa-token
   spec:
     rules:
       - name: mutate-automount
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         mutate:
           patchStrategicMerge:
             spec:
               +(automountServiceAccountToken): false
   ```

   ```bash
   kubectl apply -f policy-mutate.yaml
   ```

5. Verificá la mutación en un pod nuevo:

   ```bash
   kubectl get pod p2 -n team-a -o jsonpath='{.spec.automountServiceAccountToken}'
   # (vacío en p2 porque es previo; creá uno nuevo para verlo aplicado)
   ```

**Preguntas de comprensión**

1. ¿Qué dos capacidades tiene una policy-as-code engine (Kyverno/Gatekeeper) que PSA **no** puede ofrecer, según viste en los pasos 2 y 4?
2. `validationFailureAction: Enforce` versus `Audit`: ¿cómo usarías `Audit` para desplegar una policy nueva en una plataforma con 200 workloads existentes sin causar un incidente masivo?
3. Los admission webhooks de Kyverno se interponen en cada request de creación de pods. ¿Qué riesgo operativo introduce esto para la disponibilidad del cluster y cómo lo mitigan `failurePolicy` y los `--exclude` de namespaces de sistema?
4. La mutación del paso 4 usa el prefijo `+(...)`. ¿Por qué "agregar solo si no existe" (anchor de adición condicional) es más seguro que forzar el valor siempre, desde la perspectiva del opt-in del tenant?

---

## Ejercicio 6 — Aislamiento de red como control de seguridad: NetworkPolicy

Objetivo: RBAC controla la API; NetworkPolicy controla el tráfico. Aplicar default-deny por tenant y permitir explícitamente.

**Pasos**

1. Asegurate de tener un CNI que implemente NetworkPolicy (Calico, Cilium, etc.). Aplicá un **default-deny** de ingress y egress en `team-a` (`np-default-deny.yaml`):

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: team-a
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   ```

   ```bash
   kubectl apply -f np-default-deny.yaml
   ```

2. Permití explícitamente egress a DNS (necesario o todo se rompe) y a los pods del mismo tenant (`np-allow.yaml`):

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-dns-and-intra-namespace
     namespace: team-a
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
     egress:
       - to:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
         ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
       - to:
           - podSelector: {}
     ingress:
       - from:
           - podSelector: {}
   ```

   ```bash
   kubectl apply -f np-allow.yaml
   ```

3. Verificá el aislamiento con un pod de prueba conforme a `restricted`:

   ```bash
   kubectl run neta -n team-a --image=registry.corp.io/curl \
     --labels=owner=team-a --restart=Never -it --rm \
     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"neta","image":"registry.corp.io/curl","stdin":true,"tty":true,"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
     -- sh
   # dentro del pod:
   # curl -m 5 https://team-b-svc.team-b.svc.cluster.local   -> timeout (bloqueado por default-deny cross-namespace)
   # nslookup kubernetes.default                              -> resuelve (DNS permitido)
   ```

**Preguntas de comprensión**

1. Un namespace **sin** ninguna NetworkPolicy: ¿su tráfico está permitido o denegado por defecto? ¿Qué cambia el instante en que aplicás la primera policy con `podSelector: {}`?
2. En el paso 2, si **olvidás** la regla de egress a DNS (puerto 53), ¿qué síntoma verían los desarrolladores en sus aplicaciones y por qué es un fallo tan común y difícil de diagnosticar?
3. NetworkPolicy y RBAC son ambos "controles de seguridad de plataforma" pero operan en planos distintos. Definí qué protege cada uno y por qué un tenant necesita ambos (dá un ejemplo de ataque que RBAC no detiene pero NetworkPolicy sí, y viceversa).

---

## Cierre — La pila de defensa en profundidad

Repasá cómo los seis ejercicios encajan como capas independientes sobre los mismos recursos de plataforma:

| Capa | Control | Qué gobierna | Falla si se omite |
|---|---|---|---|
| AuthZ API | RBAC (Role/ClusterRole, aggregation) | Quién invoca qué verbo sobre qué recurso | Cualquier subject puede leer secrets / escalar |
| Identidad workload | ServiceAccount + token controls | Con qué identidad corre un pod | Pods montan tokens con permisos innecesarios |
| Admission (built-in) | Pod Security Admission | Postura de seguridad del pod (root, caps, seccomp) | Contenedores privilegiados / escapes |
| Admission (extensible) | Kyverno / OPA Gatekeeper | Políticas de negocio (registry, labels, mutación) | Imágenes no confiables, recursos sin dueño |
| Red | NetworkPolicy | Tráfico este-oeste entre tenants | Movimiento lateral entre namespaces |

**Pregunta de síntesis**

Un tenant es comprometido: un atacante ejecuta código dentro de un pod de `team-a`. Recorré la pila y explicá, capa por capa, qué lo detiene o lo limita — y cuál es el punto único de falla más peligroso si esa capa estuviera mal configurada.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

1. **`delete` no está en la lista de `verbs`.** RBAC es puramente aditivo y de allow-list: un subject solo puede hacer lo que algún rule concede explícitamente; no hay reglas de deny. El `Role` concede `["get","list","watch","create","update","patch"]` sobre `deployments`, pero `delete` no figura, así que la respuesta es `no`. Para permitirlo habría que agregar el verbo.
2. **`Role`/`RoleBinding` son namespaced.** El `Role` `ci-deployer` y su binding viven en `team-a`, así que sus reglas solo aplican a recursos de `team-a`; en `kube-system` el subject no tiene ninguna regla y todo es `no`. Con un `ClusterRole` referenciado por un `ClusterRoleBinding`, las reglas aplicarían en **todos** los namespaces (y a recursos cluster-scoped), lo que rompería el aislamiento del tenant. La combinación correcta para reutilizar reglas pero acotar el alcance es un `ClusterRole` referenciado por un `RoleBinding` (Ejercicio 2, paso 2).
3. En vez de `get secrets` amplio, montar solo el secret concreto que el CI necesita como variable/volumen en su propio pod (la asignación de un Secret a un pod no requiere permiso `get` sobre la API para el ServiceAccount que solo lo consume vía volumen), o usar un external secrets operator con acceso acotado por nombre (`resourceNames`). `get secrets` es más peligroso que `list` porque `get` de un secret devuelve su **contenido decodificable** (`data` en base64); con `get` sobre el nombre correcto un subject extrae credenciales. Además, otorgar `get/list secrets` a nivel namespace expone tokens de ServiceAccount de otros pods, habilitando escalada.
   > Fuente: https://kubernetes.io/docs/reference/access-authn-authz/rbac/

### Ejercicio 2

1. **Queda efectivo solo en `team-a`.** El alcance lo determina el **tipo de binding**, no el tipo de rol: un `RoleBinding` (namespaced) que apunta a un `ClusterRole` aplica esas reglas **únicamente dentro de su propio namespace**. Esto es el patrón idiomático para definir un rol una vez y reutilizarlo por tenant. Un `ClusterRoleBinding` al mismo `ClusterRole` lo haría efectivo cluster-wide.
2. **Aggregation:** el `ClusterRole` con `aggregationRule` tiene `rules` vacío; un controller del control plane observa continuamente los `ClusterRole` cuyos labels matchean el `clusterRoleSelectors` y **fusiona sus reglas** dentro del agregado, recalculando ante cualquier cambio. Es potente porque compone permisos sin editar el rol central. Es un riesgo porque **cualquiera que pueda crear/etiquetar un `ClusterRole` con ese label agrega permisos al rol agregado sin tocarlo** — una vía de escalada silenciosa. El operador de plataforma debe restringir por RBAC quién puede crear `ClusterRole` y quién puede setear esos labels.
3. Write sobre `secrets` + crear pods en el mismo namespace habilita escalada: el atacante puede (a) leer/crear tokens de ServiceAccounts más privilegiados presentes en el namespace, o (b) montar cualquier secret en un pod que él crea y exfiltrar su contenido. La combinación "gestionar secrets" + "ejecutar workloads" es un patrón clásico de privilege escalation; por eso `secrets` casi nunca debe estar en un rol de tenant con `["*"]`.
   > Fuente: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles

### Ejercicio 3

1. Los `selfsubjectaccessreviews` y `selfsubjectrulesreviews` los concede el `ClusterRole` por defecto **`system:basic-user`**, enlazado por el `ClusterRoleBinding` `system:basic-user` al grupo `system:authenticated`. Sirven precisamente para que cualquier usuario autenticado pueda preguntar "¿qué puedo hacer yo?" (`auth can-i`) sin necesitar permisos adicionales, ya que la review es sobre sí mismo.
2. El API server tiene una **protección anti-escalada** integrada: al crear o modificar un `Role`/`ClusterRole`/binding, verifica que el subject que hace la operación ya posea (o tenga el verbo especial `escalate`/`bind`) **todos** los permisos que intenta conceder. Como `ci-runner` no tiene `cluster-admin`, no puede otorgarlo. Un subject **sí** podría concederse cluster-admin si tuviera el verbo `bind` sobre ese `ClusterRole` (o `escalate` sobre roles) — por eso `bind`/`escalate` son permisos extremadamente sensibles.
3. `kubectl auth can-i --list` consulta el **motor de authorization real** del API server, que evalúa la unión de todos los `Role`/`ClusterRole` vía todos los bindings aplicables (más webhooks/node/ABAC si existen). Leer los YAML a mano falla porque el acceso efectivo es la **suma** de múltiples bindings, incluidos roles por defecto y agregados, y es fácil pasar por alto uno; la review consulta el estado computado, no la configuración parcial.
   > Fuente: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping

### Ejercicio 4

1. **`enforce`** rechaza en admission los pods que violan el nivel (por eso `bad-pod` falla). **`warn`** los admite pero devuelve un warning al cliente (por eso `warn-pod` se crea con mensaje). **`audit`** los admite silenciosamente pero anota un evento en el audit log del API server. En un rollout: primero `warn`+`audit` para medir impacto sin romper nada, luego promovés a `enforce`.
2. Con un `Deployment`, el `Deployment` mismo **se crea** (es un objeto conforme); el rechazo ocurre cuando su `ReplicaSet` intenta crear los **pods**. El síntoma es un `Deployment` con 0 replicas listas y errores en el `ReplicaSet`: `kubectl get events -n team-a` o `kubectl describe replicaset ...` muestran el `FailedCreate` con el mensaje de PodSecurity. El error no aparece en el `kubectl apply` del Deployment — un punto de confusión frecuente.
3. `enforce-version=latest` evalúa contra la política del release del control plane vigente; un upgrade puede endurecer chequeos y romper pods antes válidos. En plataforma se **pinnea** una versión explícita (p.ej. `pod-security.kubernetes.io/enforce-version=v1.28`), se sube el cluster, se valida con `warn`/`audit` contra la nueva versión, y recién entonces se avanza el pin de `enforce`.
4. PSA solo entiende los tres Pod Security Standards predefinidos aplicados a **campos del pod spec** relacionados con seguridad del contenedor. No puede expresar políticas arbitrarias de negocio (restringir registries, exigir labels, cuotas, mutaciones). Es no extensible por diseño; por eso las políticas custom requieren un admission webhook programable (Kyverno/Gatekeeper).
   > Fuentes: https://kubernetes.io/docs/concepts/security/pod-security-admission/ · https://kubernetes.io/docs/concepts/security/pod-security-standards/

### Ejercicio 5

1. (a) **Validación de políticas arbitrarias** más allá de la postura del pod — p.ej. restringir el registry de la imagen y exigir el label `owner` (paso 2), cosas que PSA no modela. (b) **Mutación** de recursos en admission — inyectar defaults seguros como `automountServiceAccountToken: false` (paso 4); PSA solo valida, nunca modifica.
2. Desplegás la policy con `validationFailureAction: Audit`: no bloquea nada, pero registra violaciones en `PolicyReport`/eventos. Corrés `kubectl get polr -A` para inventariar los 200 workloads que fallarían, remediás (o exceptúas) cada uno, y solo cuando el reporte está limpio promovés a `Enforce`. Así evitás un incidente masivo por bloqueo instantáneo.
3. Cada creación de pod pasa por el webhook de Kyverno; si el admission controller está caído o lento, con `failurePolicy: Fail` **se bloquean todas las creaciones** (incluidas las de recuperación), y con `failurePolicy: Ignore` se **cae el enforcement** (fail-open, riesgo de seguridad). Mitigaciones: alta disponibilidad del controller, timeouts acotados, y `--exclude`/namespaceSelectors que **saquen del webhook los namespaces de sistema** (`kube-system`, el propio de Kyverno) para no bloquear el arranque del cluster.
4. `+(...)` es un anchor de **adición condicional**: agrega el campo solo si el tenant no lo especificó. Forzarlo siempre pisaría un opt-in legítimo (un pod que sí necesita el token de la API quedaría roto); con la adición condicional el default seguro aplica por omisión pero el tenant conserva la capacidad de setear `automountServiceAccountToken: true` explícitamente cuando lo justifica.
   > Fuente: https://kyverno.io/docs/writing-policies/

### Ejercicio 6

1. **Sin ninguna NetworkPolicy: todo el tráfico está permitido** (modelo por defecto de Kubernetes, all-allowed). En el instante en que aplicás la primera policy que **selecciona** un pod (aquí `podSelector: {}` selecciona todos), ese pod pasa a **default-deny** para los `policyTypes` declarados: solo se permite lo que alguna policy autorice explícitamente. Las policies son aditivas (unión de allows), nunca hay deny explícito.
2. Sin egress a DNS (puerto 53 UDP/TCP hacia `kube-system`/CoreDNS), la resolución de nombres falla: las apps ven timeouts y errores tipo "could not resolve host" / "name resolution failure" en cualquier llamada por hostname, incluso a servicios permitidos. Es difícil de diagnosticar porque el síntoma parece un problema de la app o del servicio destino, no de red, y la conectividad por IP directa puede funcionar mientras la resolución por nombre no — despistando al desarrollador.
3. **RBAC protege el plano de control (API server):** quién puede leer/escribir objetos de Kubernetes. **NetworkPolicy protege el plano de datos (tráfico este-oeste):** qué pods pueden hablar con qué pods. Un ataque que **RBAC no detiene pero NetworkPolicy sí**: un pod comprometido de `team-a` escaneando y conectándose a una base de datos de `team-b` — es tráfico de red puro, RBAC nunca se consulta. Un ataque que **NetworkPolicy no detiene pero RBAC sí**: un ServiceAccount con token que llama al API server para listar secrets de otro namespace — es una request a la API autorizada por RBAC, la red no interviene (el tráfico al API server suele estar permitido). Por eso el tenant necesita ambos.
   > Fuente: https://kubernetes.io/docs/concepts/services-networking/network-policies/

### Síntesis

Atacante con ejecución de código en un pod de `team-a`:

- **NetworkPolicy (default-deny):** no puede pivotar a pods de otros tenants ni exfiltrar a Internet salvo egress explícitamente permitido; el movimiento lateral queda contenido en `team-a`.
- **PSA (`restricted`) + Kyverno:** el pod corre non-root, sin capabilities, con seccomp y sin privilege escalation, y no pudo traer una imagen fuera del registry confiable — reduce fuertemente la superficie para escapar del contenedor al nodo.
- **ServiceAccount token controls (mutación `automount:false`):** el pod no monta un token de la API por defecto, así que el atacante no obtiene credenciales de Kubernetes automáticamente.
- **RBAC (least privilege):** aun si hubiera un token, sus permisos son mínimos (no `secrets`, no cluster-scoped, no crear bindings) y la protección anti-escalada impide auto-concederse más; el radio de daño en la API es acotado.

**Punto único de falla más peligroso:** la capa de **identidad de workload + RBAC**. Si el pod montara un token de un ServiceAccount sobreprivilegiado (p.ej. con `get secrets` amplio o `cluster-admin`), el atacante hereda esos permisos sobre **todo el cluster** y las demás capas (red, PSA) resultan irrelevantes: puede leer secrets de cualquier namespace, crear pods privilegiados o modificar bindings. Por eso el token del ServiceAccount y su RBAC son el eslabón que hay que mantener en least privilege a cualquier costo.

</details>