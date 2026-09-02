# CKS 3.1 — Usar Role Based Access Controls para minimizar la exposición

**Ejercicios de laboratorio guiados**

> **Prerrequisitos.** Un clúster donde tengas `cluster-admin` (kind, minikube, o un clúster kubeadm descartable corriendo k8s ≥ 1.30). Todas las verificaciones de suplantación de abajo usan `--as` / `--as-group`, que requieren que tu propia identidad tenga permitido suplantar. En un `kubeconfig` de admin recién creado esto ya es así. Verificá antes de empezar:
>
> ```console
> $ kubectl auth can-i '*' '*'
> yes
> $ kubectl version -o json | grep -m1 gitVersion
>   "gitVersion": "v1.34.0",
> ```
>
> RBAC está habilitado cuando el API server corre con `--authorization-mode=...,RBAC`. Confirmalo en un nodo kubeadm:
>
> ```console
> $ grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
>     - --authorization-mode=Node,RBAC
> ```

---

## Ejercicio 1 — Mapear la superficie de la API de RBAC y los roles integrados

Los cuatro objetos de RBAC y las identidades que vinculan son el vocabulario de todo lo que sigue: `Role`/`ClusterRole` (conjuntos de permisos) y `RoleBinding`/`ClusterRoleBinding` (concesiones a sujetos).

1. Listá los recursos de la API de RBAC y fijate cuáles son namespaced:

   ```console
   $ kubectl api-resources --api-group=rbac.authorization.k8s.io
   NAME                  SHORTNAMES   APIVERSION                        NAMESPACED   KIND
   clusterrolebindings                rbac.authorization.k8s.io/v1      false        ClusterRoleBinding
   clusterroles                       rbac.authorization.k8s.io/v1      false        ClusterRole
   rolebindings                       rbac.authorization.k8s.io/v1      true         RoleBinding
   roles                              rbac.authorization.k8s.io/v1      true         Role
   ```

2. Inspeccioná los cuatro ClusterRoles por defecto orientados al usuario que vienen con todo clúster:

   ```console
   $ kubectl get clusterrole cluster-admin admin edit view
   NAME            CREATED AT
   cluster-admin   2026-07-30T09:12:04Z
   admin           2026-07-30T09:12:04Z
   edit            2026-07-30T09:12:04Z
   view            2026-07-30T09:12:04Z
   ```

3. Mirá la forma del más peligroso y la de uno acotado:

   ```console
   $ kubectl get clusterrole cluster-admin -o yaml | sed -n '1,20p'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     annotations:
       rbac.authorization.kubernetes.io/autoupdate: "true"
     labels:
       kubernetes.io/bootstrapping: rbac-defaults
     name: cluster-admin
   rules:
   - apiGroups:
     - '*'
     resources:
     - '*'
     verbs:
     - '*'
   - nonResourceURLs:
     - '*'
     verbs:
     - '*'
   ```

   ```console
   $ kubectl get clusterrole view -o yaml | grep -A4 'apiGroups' | head -8
     - apiGroups:
       - ""
       resources:
       - configmaps
       - endpoints
   ```

**Punto de control de comprensión**

- **Q1.** Un `RoleBinding` vive en el namespace `dev`. Referencia un `ClusterRole` (no un `Role`). ¿En qué namespace(s) aplican los permisos concedidos, y por qué referenciar un ClusterRole desde un RoleBinding *no* concede acceso a nivel de todo el clúster?
- **Q2.** ¿Cuál de los cuatro roles por defecto (`cluster-admin`, `admin`, `edit`, `view`) concede lectura/escritura sobre la mayoría de los recursos namespaced pero es seguro vincularlo *por namespace* en lugar de a nivel de clúster, y qué único rol casi nunca debería aparecer en un `ClusterRoleBinding` en producción?
- **Q3.** En las reglas de `cluster-admin` ves tanto una regla de recursos (`apiGroups/resources/verbs`) como una regla `nonResourceURLs`. ¿Qué tipo de petición autoriza `nonResourceURLs` que la regla de recursos no puede?

---

## Ejercicio 2 — Conceder a un ServiceAccount acceso namespaced de mínimo privilegio

El objetivo: una carga de trabajo en `dev` que solo pueda **leer** pods en su propio namespace — nada más, en ningún otro lado.

1. Creá el namespace y un ServiceAccount dedicado (nunca reutilices `default`):

   ```console
   $ kubectl create namespace dev
   namespace/dev created
   $ kubectl create serviceaccount app-reader -n dev
   serviceaccount/app-reader created
   ```

2. Escribí un `Role` estrictamente acotado. Aplicalo:

   ```yaml
   # role-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: dev
   rules:
   - apiGroups: [""]          # "" is the core API group
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f role-pod-reader.yaml
   role.rbac.authorization.k8s.io/pod-reader created
   ```

3. Vinculá el Role al ServiceAccount con un `RoleBinding` en el mismo namespace:

   ```yaml
   # rb-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: app-reader-can-read-pods
     namespace: dev
   subjects:
   - kind: ServiceAccount
     name: app-reader
     namespace: dev
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```console
   $ kubectl apply -f rb-pod-reader.yaml
   rolebinding.rbac.authorization.k8s.io/app-reader-can-read-pods created
   ```

4. Verificá con suplantación *antes* de desplegar ninguna carga de trabajo. El formato del nombre de usuario del SA es `system:serviceaccount:<namespace>:<name>`:

   ```console
   $ kubectl auth can-i list pods --as=system:serviceaccount:dev:app-reader -n dev
   yes
   $ kubectl auth can-i delete pods --as=system:serviceaccount:dev:app-reader -n dev
   no
   $ kubectl auth can-i list pods --as=system:serviceaccount:dev:app-reader -n kube-system
   no
   $ kubectl auth can-i list secrets --as=system:serviceaccount:dev:app-reader -n dev
   no
   ```

5. Enumerá el conjunto de permisos efectivos *completo* del SA:

   ```console
   $ kubectl auth can-i --list --as=system:serviceaccount:dev:app-reader -n dev
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
   ```

**Punto de control de comprensión**

- **Q4.** En el paso 4, `-n kube-system` devolvió `no` aunque los mismos permisos de `pod-reader` "existen". ¿Qué propiedad estructural del `RoleBinding` produjo ese resultado?
- **Q5.** La salida de `--list` en el paso 5 muestra `selfsubjectaccessreviews` y `selfsubjectrulesreviews` con el verbo `create`, aunque nunca los concediste. ¿De dónde vienen, y son un privilegio por el que haya que preocuparse?
- **Q6.** ¿Por qué las pruebas por suplantación (`--as=system:serviceaccount:...`) son preferibles a lanzar realmente un pod con el SA y correr `kubectl` desde adentro, cuando estás validando una concesión de mínimo privilegio en una tarea al estilo CKS?

---

## Ejercicio 3 — Ajustar los verbos y fijar a recursos nombrados con `resourceNames`

El mínimo privilegio no es solo *qué recurso* sino *qué objeto nombrado* y *qué verbo*. Acá un ServiceAccount de CI debe actualizar **un** ConfigMap **específico** y nada más.

1. Creá los objetos objetivo:

   ```console
   $ kubectl create serviceaccount ci-bot -n dev
   serviceaccount/ci-bot created
   $ kubectl create configmap app-config -n dev --from-literal=env=prod
   configmap/app-config created
   $ kubectl create configmap other-config -n dev --from-literal=x=y
   configmap/other-config created
   ```

2. Escribí un Role que quede fijado a un único objeto vía `resourceNames`:

   ```yaml
   # role-cm-patch.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: app-config-writer
     namespace: dev
   rules:
   - apiGroups: [""]
     resources: ["configmaps"]
     resourceNames: ["app-config"]     # only this named object
     verbs: ["get", "update", "patch"]
   ```

   ```console
   $ kubectl apply -f role-cm-patch.yaml
   role.rbac.authorization.k8s.io/app-config-writer created
   $ kubectl create rolebinding ci-bot-writes-config -n dev \
       --role=app-config-writer --serviceaccount=dev:ci-bot
   rolebinding.rbac.authorization.k8s.io/ci-bot-writes-config created
   ```

3. Probá el límite. Fijate en la asimetría entre `list` y `get`:

   ```console
   $ kubectl auth can-i update configmap/app-config   --as=system:serviceaccount:dev:ci-bot -n dev
   yes
   $ kubectl auth can-i update configmap/other-config --as=system:serviceaccount:dev:ci-bot -n dev
   no
   $ kubectl auth can-i list configmaps                --as=system:serviceaccount:dev:ci-bot -n dev
   no
   ```

4. Comprobá que una petición real se comporta de la misma manera:

   ```console
   $ kubectl patch configmap app-config -n dev --as=system:serviceaccount:dev:ci-bot \
       -p '{"data":{"env":"staging"}}'
   configmap/app-config patched

   $ kubectl get configmaps -n dev --as=system:serviceaccount:dev:ci-bot
   Error from server (Forbidden): configmaps is forbidden: User
   "system:serviceaccount:dev:ci-bot" cannot list resource "configmaps" in API group ""
   in the namespace "dev"
   ```

**Punto de control de comprensión**

- **Q7.** Concediste `get` sobre `resourceNames: ["app-config"]` pero `kubectl auth can-i list configmaps` devuelve `no`, e incluso `get` funciona solo cuando se suministra el nombre exacto. ¿Qué verbos son compatibles con `resourceNames`, y qué verbos **nunca** puede restringir? Explicá la razón de fondo.
- **Q8.** Un compañero de equipo agrega `verbs: ["create"]` a esta misma regla esperando que `ci-bot` pueda crear *solo* un ConfigMap llamado `app-config`. ¿Qué pasa realmente, y por qué?
- **Q9.** Con este Role en su lugar, `ci-bot` puede hacer `update` sobre `app-config` pero no puede hacer `get` de la lista de ConfigMaps para descubrir su nombre. Desde el punto de vista de la contención de un atacante, ¿por qué "puede escribir un objeto conocido pero no puede enumerar objetos" es una reducción significativa de la exposición?

---

## Ejercicio 4 — Reutilización de ClusterRole: una definición, concesiones por namespace

Un único `ClusterRole` puede reutilizarse: vinculado a nivel de clúster con un `ClusterRoleBinding`, o acotado a un namespace con un `RoleBinding`. Esta es la forma idiomática de conceder el mismo conjunto de permisos en muchos namespaces sin duplicar reglas.

1. Definí un ClusterRole reutilizable para leer Deployments (grupo apps):

   ```yaml
   # cr-deploy-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: deployment-reader
   rules:
   - apiGroups: ["apps"]
     resources: ["deployments"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f cr-deploy-reader.yaml
   clusterrole.rbac.authorization.k8s.io/deployment-reader created
   ```

2. Concedelo **solo en `dev`** referenciando el ClusterRole desde un RoleBinding namespaced:

   ```console
   $ kubectl create serviceaccount deploy-viewer -n dev
   serviceaccount/deploy-viewer created
   $ kubectl create rolebinding deploy-viewer-dev -n dev \
       --clusterrole=deployment-reader --serviceaccount=dev:deploy-viewer
   rolebinding.rbac.authorization.k8s.io/deploy-viewer-dev created
   ```

3. Confirmá que la concesión está limitada al namespace aunque el rol sea de alcance de clúster:

   ```console
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n dev
   yes
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n default
   no
   ```

4. Ahora contrastá con un `ClusterRoleBinding`, que *sí* concede a nivel de todo el clúster. Crealo, observá la diferencia, y después borralo (este es exactamente el tipo de concesión excesiva que una tarea de CKS te pide evitar):

   ```console
   $ kubectl create clusterrolebinding deploy-viewer-global \
       --clusterrole=deployment-reader --serviceaccount=dev:deploy-viewer
   clusterrolebinding.rbac.authorization.k8s.io/deploy-viewer-global created

   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n default
   yes
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n kube-system
   yes

   $ kubectl delete clusterrolebinding deploy-viewer-global
   clusterrolebinding.rbac.authorization.k8s.io "deploy-viewer-global" deleted
   ```

**Punto de control de comprensión**

- **Q10.** Completá la matriz 2×2: {`Role`, `ClusterRole`} × {`RoleBinding`, `ClusterRoleBinding`}. ¿Qué combinaciones son *válidas*, y para cada una válida, cuál es el alcance efectivo de la concesión resultante?
- **Q11.** Un `RoleBinding` en `dev` referencia un `ClusterRole` que incluye una regla sobre un recurso de **alcance de clúster** (por ejemplo `nodes` o `persistentvolumes`). ¿El sujeto obtiene acceso a esos recursos de alcance de clúster a través de este RoleBinding? ¿Por qué sí o por qué no?
- **Q12.** Necesitás el mismo permiso de "leer deployments" en 30 namespaces. Compará (a) un ClusterRole + 30 RoleBindings contra (b) un ClusterRole + un ClusterRoleBinding, en términos de radio de impacto y del principio de mínimo privilegio.

---

## Ejercicio 5 — ClusterRoles agregados: extender sin editar los integrados

Tenés que agregar "leer `secrets`" a todos los que ya tienen el rol `view`, sin editar el ClusterRole `view` (auto-actualizado, gestionado por el bootstrap). La agregación es el mecanismo soportado.

1. Inspeccioná cómo está ensamblado `view` — es un rol *agregado*:

   ```console
   $ kubectl get clusterrole view -o yaml | grep -A4 aggregationRule
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         rbac.authorization.k8s.io/aggregate-to-view: "true"
   ```

2. Creá un ClusterRole pequeño que lleve la etiqueta de agregación correspondiente. El plano de control fusionará sus reglas dentro de `view` automáticamente:

   ```yaml
   # cr-aggregate-secrets-view.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: view-secrets-extension
     labels:
       rbac.authorization.k8s.io/aggregate-to-view: "true"
   rules:
   - apiGroups: [""]
     resources: ["secrets"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f cr-aggregate-secrets-view.yaml
   clusterrole.rbac.authorization.k8s.io/view-secrets-extension created
   ```

3. Observá que el rol agregado `view` ahora *contiene* la regla de secrets, aunque nunca lo editaste directamente:

   ```console
   $ kubectl get clusterrole view -o yaml | grep -B1 -A3 secrets
     - apiGroups:
       - ""
       resources:
       - secrets
       verbs:
       - get
   ```

4. Confirmá el efecto sobre un sujeto que tiene `view`, y después **limpiá** — conceder lectura de `secrets` a todo el que tenga `view` es en sí mismo una exposición y este paso es una demostración, no una recomendación:

   ```console
   $ kubectl create serviceaccount auditor -n dev
   $ kubectl create rolebinding auditor-view -n dev --clusterrole=view --serviceaccount=dev:auditor
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:auditor -n dev
   yes
   $ kubectl delete clusterrole view-secrets-extension
   clusterrole.rbac.authorization.k8s.io "view-secrets-extension" deleted
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:auditor -n dev
   no
   ```

**Punto de control de comprensión**

- **Q13.** ¿Por qué la agregación es el patrón correcto para extender `view`/`edit`/`admin`, en lugar de `kubectl edit clusterrole view` y agregar una regla?
- **Q14.** En el paso 4 el rol `view` ganó lectura de `secrets` para *todos* los sujetos ya vinculados a `view`. Desde la perspectiva de "minimizar la exposición", ¿qué hace que agregar `secrets` dentro de `view` sea un cambio peligroso, y cómo sería un diseño más seguro?
- **Q15.** Después de que borraste `view-secrets-extension`, el permiso desapareció *sin* tocar ningún RoleBinding. ¿Qué componente recalculó las `rules` agregadas, y ante qué evento?

---

## Ejercicio 6 — Encontrar y neutralizar permisos de escalada de privilegios

Los verbos `escalate`, `bind`, `impersonate`, y los comodines sobre `roles`/`clusterroles`/`*` son las construcciones de RBAC que permiten a un sujeto de bajo privilegio volverse de alto privilegio. Este ejercicio es la auditoría central de "minimizar la exposición".

1. Creá un Role deliberadamente demasiado permisivo y vinculalo, simulando una concesión mala que te podrían pedir encontrar y arreglar:

   ```yaml
   # role-dangerous.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: rbac-manager
     namespace: dev
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["*"]                       # includes create + bind + escalate
   ```

   ```console
   $ kubectl apply -f role-dangerous.yaml
   role.rbac.authorization.k8s.io/rbac-manager created
   $ kubectl create serviceaccount tenant -n dev
   $ kubectl create rolebinding tenant-rbac -n dev --role=rbac-manager --serviceaccount=dev:tenant
   rolebinding.rbac.authorization.k8s.io/tenant-rbac created
   ```

2. Mostrá la escalada. `tenant` puede gestionar Roles en `dev`, así que puede fabricarse un Role que le conceda `secrets` — *salvo* que la protección contra escalada lo bloquee. Probá si puede escalar a permisos que él mismo no tiene:

   ```console
   $ kubectl auth can-i create roles --as=system:serviceaccount:dev:tenant -n dev
   yes
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:tenant -n dev
   no
   ```

   La prevención de escalada del apiserver normalmente impide que `tenant` cree un Role con `secrets` que no tiene — **pero** como el comodín `verbs: ["*"]` concede los verbos `escalate` y `bind` sobre `roles`/`rolebindings`, esa protección queda sorteada. Precisamente por eso `*` sobre recursos de RBAC es un hallazgo crítico.

3. Auditá todo el clúster en busca de las concesiones de mayor riesgo. Estos son los greps que corre un revisor:

   ```console
   # Who is bound to cluster-admin?
   $ kubectl get clusterrolebindings -o json | \
       jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
              .metadata.name + " -> " +
              ([.subjects[]?|.kind+"/"+.name]|join(","))'
   cluster-admin -> Group/system:masters

   # Every (cluster)role that uses a wildcard verb, resource, or apiGroup
   $ kubectl get clusterroles,roles -A -o json | jq -r '
       .items[] | . as $r | .rules[]? |
       select((.verbs//[]|index("*")) or (.resources//[]|index("*")) or (.apiGroups//[]|index("*"))) |
       ($r.kind+"/"+$r.metadata.name)' | sort -u | head
   ClusterRole/cluster-admin
   Role/rbac-manager

   # Anyone granted the escalate / bind / impersonate verbs
   $ kubectl get clusterroles,roles -A -o json | jq -r '
       .items[] | . as $r | .rules[]? |
       select(.verbs[]? | test("^(escalate|bind|impersonate)$")) |
       ($r.kind+"/"+$r.metadata.name+" verbs="+(.verbs|join(",")))'
   Role/rbac-manager verbs=*
   ```

4. Remediá: reemplazá el comodín por un conjunto de verbos explícito y mínimo, y quitá `bind`/`escalate`:

   ```yaml
   # role-rbac-manager-fixed.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: rbac-manager
     namespace: dev
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["get", "list", "watch"]     # read-only; no create/bind/escalate
   ```

   ```console
   $ kubectl apply -f role-rbac-manager-fixed.yaml
   role.rbac.authorization.k8s.io/rbac-manager configured
   $ kubectl auth can-i create roles --as=system:serviceaccount:dev:tenant -n dev
   no
   ```

**Punto de control de comprensión**

- **Q16.** Explicá la **prevención de escalada** integrada del apiserver para `create`/`update` de Roles. ¿Bajo qué dos condiciones específicas se le permite a un sujeto crear un Role que contenga permisos que él mismo *no* tiene?
- **Q17.** ¿Qué permite el verbo `impersonate`, y por qué `impersonate` sobre `users`/`groups`/`serviceaccounts` equivale efectivamente a tener la unión de los permisos de todos?
- **Q18.** La auditoría encontró `cluster-admin -> Group/system:masters`. ¿Deberías remediar ese binding? ¿Qué tiene de especial `system:masters`, y cómo termina un cliente dentro de ese grupo?
- **Q19.** ¿Por qué `verbs: ["*"]` sobre `roles`/`rolebindings` es un hallazgo más severo que `verbs: ["*"]` sobre `configmaps`, aunque ambos sean comodines en un único namespace?

---

## Ejercicio 7 — Dejar de repartir tokens de API que ninguna carga de trabajo necesita

Un pod que monta un token de ServiceAccount le da a cualquier código (o atacante) dentro de ese contenedor una credencial para el API server. Minimizar la exposición significa *no montar el token* salvo que la carga de trabajo realmente llame a la API.

1. Observá el comportamiento por defecto — el token del SA `default` se auto-monta en cada pod:

   ```console
   $ kubectl run probe --image=busybox -n dev --restart=Never -- sleep 3600
   pod/probe created
   $ kubectl exec probe -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount
   ca.crt
   namespace
   token
   ```

2. Deshabilitá el auto-montaje a nivel de **ServiceAccount** (se aplica a todos los pods que lo usen y no lo sobrescriban):

   ```yaml
   # sa-no-automount.yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: no-token
     namespace: dev
   automountServiceAccountToken: false
   ```

   ```console
   $ kubectl apply -f sa-no-automount.yaml
   serviceaccount/no-token created
   ```

3. O deshabilitalo a nivel de **pod** (el ajuste del pod prevalece sobre el del SA), que es la opción más explícita y con menos sorpresas:

   ```yaml
   # pod-no-token.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: notoken
     namespace: dev
   spec:
     serviceAccountName: no-token
     automountServiceAccountToken: false
     containers:
     - name: app
       image: busybox
       command: ["sleep", "3600"]
   ```

   ```console
   $ kubectl apply -f pod-no-token.yaml
   pod/notoken created
   $ kubectl exec notoken -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount
   ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
   command terminated with exit code 1
   ```

4. Limpiá:

   ```console
   $ kubectl delete pod probe notoken -n dev
   pod "probe" deleted
   pod "notoken" deleted
   ```

**Punto de control de comprensión**

- **Q20.** Un pod establece `automountServiceAccountToken: true` mientras que su ServiceAccount establece `automountServiceAccountToken: false`. ¿Se monta el token? Enunciá la regla de precedencia.
- **Q21.** Sacaste el token de un pod que nunca habla con el API server. Concretamente, ¿qué paso de post-explotación rompe esto para un atacante que logra ejecución de código en ese contenedor?
- **Q22.** Incluso con el token *no* montado, ¿por qué vincular RBAC mínimo al ServiceAccount `default` de cada namespace sigue importando como defensa en profundidad?

---

<details>
<summary><strong>Respuestas</strong></summary>

**A1.** Los permisos aplican **solo en `dev`** — el namespace del RoleBinding. Un `RoleBinding` siempre confina una concesión a su propio namespace, sin importar si `roleRef` apunta a un `Role` o a un `ClusterRole`. Referenciar un ClusterRole desde un RoleBinding es puramente un mecanismo de *reutilización de definiciones* (escribir el conjunto de reglas una vez, concederlo en muchos namespaces); no cambia dónde el RoleBinding concede acceso. Solo un `ClusterRoleBinding` concede un ClusterRole a nivel de todo el clúster.

**A2.** `admin` y `edit` están diseñados para vincularse **por namespace** mediante un RoleBinding (`admin` = lectura/escritura completa dentro de un namespace *incluyendo* la gestión de Roles/RoleBindings ahí; `edit` = lectura/escritura de cargas de trabajo pero no de RBAC). `view` es de solo lectura. El rol que esencialmente nunca debería aparecer en un `ClusterRoleBinding` en producción es **`cluster-admin`** — un ClusterRoleBinding hacia él concede control irrestricto sobre todo el clúster (es lo que `system:masters` tiene efectivamente).

**A3.** `nonResourceURLs` autoriza peticiones a endpoints del API server que **no** son recursos REST de Kubernetes y no tienen namespace ni identidad de objeto — por ejemplo `/healthz`, `/livez`, `/readyz`, `/version`, `/metrics`, `/api`, `/openapi/v2`. Las reglas de recursos (`apiGroups`/`resources`/`verbs`) solo hacen match con rutas de recursos `/api/...` y `/apis/<group>/...`, así que se requiere una regla `nonResourceURLs` separada para autorizar esas rutas de URL planas (solo tiene sentido en ClusterRoles, ya que estas URLs no son namespaced).

**A4.** Un `RoleBinding` concede permisos **solo dentro de su propio namespace**. El binding se creó en `dev`, así que el SA está autorizado para pods en `dev` y en ningún otro lado. `kube-system` no tiene ningún RoleBinding que conceda `pod-reader` a `app-reader`, así que la petición se deniega. Para leer pods en otro namespace necesitarías un RoleBinding separado ahí (o un ClusterRoleBinding para todos los namespaces).

**A5.** Son `SelfSubjectAccessReview` y `SelfSubjectRulesReview`, concedidos a los grupos integrados `system:authenticated`/`system:basic-user` a los que pertenece toda identidad autenticada. Solo le permiten a un sujeto preguntar "¿qué tengo permitido hacer?" sobre **sí mismo** (`kubectl auth can-i`) — no conceden acceso a ningún recurso real y no pueden usarse para escalar, así que no son motivo de preocupación.

**A6.** Las verificaciones por suplantación (`kubectl auth can-i --as=...` y `--list`) consultan directamente al autorizador del apiserver y reportan la decisión *exacta* sin efectos secundarios, sin necesitar un pod corriendo, un token montado, un nodo asignado, ni ninguna descarga de imagen. Lanzar un pod real para probar es más lento, muta el estado del clúster, puede fallar por razones no relacionadas (scheduling, imagen, CrashLoopBackOff), y en un examen desperdicia tiempo. `--as`/`--as-group` es el método de verificación de RBAC canónico y determinista.

**A7.** `resourceNames` funciona con verbos que direccionan un **objeto individual ya nombrado**: `get`, `update`, `patch`, `delete` (y `watch` sobre un nombre específico). **Nunca** puede restringir `list`, `watch` (de colección), `create`, ni `deletecollection`, porque esos operan sobre una colección entera o, en el caso de `create`, sobre un objeto cuyo nombre todavía no existe al momento de la autorización — no hay nombre contra el cual hacer match. Por eso `list configmaps` devolvió `no` (no hay regla `list` sin restricción) y `get` solo funcionó con el nombre exacto.

**A8.** Agregar `create` junto a `resourceNames: ["app-config"]` **no** le permite a `ci-bot` crear un ConfigMap llamado `app-config`. Al momento del `create` el objeto todavía no tiene nombre, así que `resourceNames` no puede hacer match — el efecto es que el verbo `create` en esa regla queda inutilizable/inefectivo, y `ci-bot` sigue sin poder crear ningún ConfigMap. Para permitir crear ConfigMaps hay que conceder `create` en una regla **sin** `resourceNames` (lo que necesariamente permite crearlos bajo *cualquier* nombre).

**A9.** Bloquear la enumeración (`list`) le quita al atacante la capacidad de descubrir qué existe — nombres de objetos, cuántos, sus metadatos. Un atacante que compromete `ci-bot` solo puede actuar sobre nombres que ya conoce; no puede barrer el namespace para encontrar secrets, otras configuraciones u objetivos. Combinado con verbos estrechos sobre un único objeto nombrado, esto colapsa el radio de impacto de "todo en el namespace" a "un objeto conocido, solo escritura" — una reducción de la exposición grande y concreta.

**A10.** 
| roleRef → binding ↓ | `Role` | `ClusterRole` |
|---|---|---|
| `RoleBinding` | Válido — concesión acotada al namespace del binding | Válido — concesión acotada al namespace del binding (ClusterRole reutilizado como plantilla) |
| `ClusterRoleBinding` | **Inválido** — un ClusterRoleBinding no puede referenciar un Role namespaced | Válido — la concesión aplica a nivel de todo el clúster, todos los namespaces + recursos de alcance de clúster |

**A11.** **No.** Un `RoleBinding` solo puede conceder acceso a recursos *en su propio namespace*, y los recursos de alcance de clúster (`nodes`, `persistentvolumes`, `namespaces`, etc.) no viven en ningún namespace. Así que aunque la regla del ClusterRole mencione `nodes`, vincularlo mediante un RoleBinding namespaced no concede nada para `nodes`. Los recursos de alcance de clúster solo son alcanzables a través de un `ClusterRoleBinding`.

**A12.** (a) Un ClusterRole + 30 RoleBindings limita al sujeto exactamente a esos 30 namespaces; un namespace número 31 creado después *no* queda expuesto automáticamente, y podés revocar un namespace borrando un RoleBinding — radio de impacto mínimo, más objetos que gestionar. (b) Un ClusterRoleBinding concede el permiso en **todos** los namespaces incluyendo `kube-system` y todo namespace futuro — un radio de impacto mucho mayor. El mínimo privilegio favorece (a) salvo que el permiso genuinamente deba ser universal.

**A13.** Los roles integrados `view`/`edit`/`admin` llevan `rbac.authorization.kubernetes.io/autoupdate: "true"` y son reconciliados por el controlador al arrancar, así que un `kubectl edit` manual es susceptible de ser **sobrescrito** en el próximo reinicio/actualización del apiserver. La agregación es el punto de extensión soportado: agregás un ClusterRole pequeño y etiquetado y el plano de control lo fusiona, sobreviviendo a las actualizaciones sin que tus cambios sean revertidos.

**A14.** `view` está pensado para concederse ampliamente, incluso a nivel de todo el clúster, como un rol "inofensivo de solo lectura". Agregarle lectura de `secrets` le da silenciosamente a **todos** los sujetos con `view` la capacidad de leer todos los Secrets que puedan alcanzar — material de tokens, claves TLS, credenciales — convirtiendo un rol "seguro" en una concesión de exfiltración de secretos a nivel de todo el clúster. Un diseño más seguro es un **ClusterRole separado y con nombre específico** (por ejemplo `secret-reader`) vinculado solo a las identidades concretas que genuinamente lo necesitan, idealmente por namespace mediante RoleBinding, nunca agregado dentro de `view`.

**A15.** El **controlador de agregación de ClusterRoles** en `kube-controller-manager` recalcula el campo `rules` del rol agregado. Reevalúa los `aggregationRule.clusterRoleSelectors` cada vez que un ClusterRole que coincide (o que coincidía previamente) con las etiquetas del selector es creado, actualizado o borrado, y reescribe las reglas del rol padre en consecuencia — así que borrar la extensión etiquetada eliminó la regla fusionada automáticamente.

**A16.** Cuando un sujeto crea o actualiza un Role/ClusterRole, el apiserver exige que el sujeto **ya tenga todos los permisos** que se están concediendo (verificado regla por regla contra los permisos efectivos del propio sujeto) — esto previene la escalada de privilegios mediante la autoría de roles. Se sortea exactamente en dos casos: (1) el sujeto tiene el verbo `escalate` sobre `roles`/`clusterroles` (permite escribir reglas más allá de sus propios permisos), o (2) el verbo `bind` sobre `roles`/`clusterroles` para crear bindings hacia un rol cuyos permisos el sujeto no tiene. Un comodín `verbs: ["*"]` sobre esos recursos incluye `escalate` y `bind`, y por eso derrota la protección.

**A17.** `impersonate` le permite a un sujeto enviar peticiones **como** otro usuario, grupo o ServiceAccount (vía `--as`/`--as-group`, o los headers `Impersonate-User`/`Impersonate-Group`); el apiserver entonces autoriza la petición usando los permisos de la identidad *suplantada*. Tener `impersonate` sobre `groups` (especialmente poder suplantar `system:masters`) o sobre usuarios/SAs arbitrarios le permite al sujeto asumir la identidad de cualquiera, así que su autoridad efectiva es la **unión de todas las identidades que puede suplantar** — escalando trivialmente a cluster-admin. Es uno de los verbos más peligrosos de conceder.

**A18.** **No, no lo elimines** — el ClusterRoleBinding `cluster-admin → system:masters` (`cluster-admin`) es un valor por defecto del bootstrap y borrarlo puede dejarte afuera de la administración del clúster. `system:masters` es un **grupo especial que el autorizador de RBAC honra como super-usuario**; más importante aún, el apiserver lo trata como siempre-permitido (el certificado de cliente de admin de kubeadm lleva `O=system:masters`). Los clientes se suman a él presentando un certificado de cliente con esa Organization. El endurecimiento correcto es *evitar emitir nuevos certificados `system:masters`* y mantener el kubeconfig de admin estrictamente controlado — no borrar el binding por defecto.

**A19.** Un comodín sobre `configmaps` en un namespace le permite al sujeto controlar totalmente los ConfigMaps *ahí* — malo, pero acotado a los datos de ConfigMaps en ese namespace. Un comodín sobre `roles`/`rolebindings` concede (a través de `escalate`/`bind`) la capacidad de **autorar y vincular permisos arbitrarios**, es decir, de concederse a sí mismo cualquier acceso — es una *primitiva de escalada de privilegios* que puede apalancarse hasta el control total del namespace y, vía suplantación/acceso a secrets, potencialmente del clúster. El control sobre RBAC es el control sobre toda otra autorización, así que es categóricamente más severo.

**A20.** **Sí, el token se monta.** El `automountServiceAccountToken` a **nivel de pod** tiene precedencia sobre el ajuste a nivel de ServiceAccount. El ajuste del SA es solo el valor por defecto aplicado cuando el pod no especifica uno; un valor explícito en el pod siempre gana. (Buena práctica: poner `false` en el SA como valor por defecto *y* confiar en que los pods opten por incluirlo solo cuando llaman a la API.)

**A21.** Rompe la capacidad del atacante de **autenticarse contra la API de Kubernetes desde adentro del contenedor**. Sin el token montado no hay credencial bearer en `/var/run/secrets/kubernetes.io/serviceaccount/token`, así que el atacante no puede enumerar ni manipular recursos del clúster, no puede sondear RBAC, y no puede pivotear mediante los permisos del SA — queda confinado al contexto de proceso/red del propio contenedor, forzándolo a encontrar otra fuente de credenciales.

**A22.** Porque un token montado no es la única forma en que se usa la identidad de un SA, y las defensas pueden ser sorteadas o mal configuradas: un cambio posterior en un manifiesto puede rehabilitar el automontaje, un operador puede hacer `kubectl exec` adentro, otra carga de trabajo puede compartir el SA, o un token proyectado podría montarse explícitamente. Si el SA `default` además *no* tiene bindings de RBAC más allá de la línea base, entonces incluso un token filtrado u obtenido da una autoridad casi nula. Superponer "sin token" (reducir la exposición de credenciales) con "sin permisos en `default`" (reducir el valor de la credencial) es defensa en profundidad — cualquiera de los dos controles por sí solo puede fallar.

</details>

---

### Fuentes

- Kubernetes — *Using RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Configure Service Accounts for Pods* (automontaje de tokens, `automountServiceAccountToken`): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Managing Service Accounts*: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Authorization Overview* (verbos, peticiones de recurso vs no-recurso): https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — *Checking API Access* (`kubectl auth can-i`, SelfSubjectAccessReview): https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access
- Kubernetes — *User Impersonation*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf