# CKA 1.35 — Tema 3.6: Manage Role Based Access Control (RBAC)

*Peso en el examen: 2.5%*

RBAC es el modelo de autorización que usa la API de Kubernetes para decidir qué puede hacer un usuario, grupo o `ServiceAccount` sobre qué recursos. Se implementa con cuatro objetos: `Role`, `ClusterRole`, `RoleBinding` y `ClusterRoleBinding`, todos en el API group `rbac.authorization.k8s.io/v1`.

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf). Documentación técnica complementaria: [Using RBAC Authorization — kubernetes.io](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

---

## Ejercicio 1 — ServiceAccount y verificación de permisos por defecto

1. Creá un namespace de práctica:
   ```bash
   kubectl create namespace rbac-lab
   ```
2. Creá un `ServiceAccount` llamado `dev-reader` en ese namespace:
   ```bash
   kubectl create serviceaccount dev-reader -n rbac-lab
   ```
3. Verificá qué puede hacer ese `ServiceAccount` sobre los pods del namespace, usando `kubectl auth can-i` con el flag `--as`:
   ```bash
   kubectl auth can-i list pods \
     --as=system:serviceaccount:rbac-lab:dev-reader \
     -n rbac-lab
   ```
4. Repetí el comando pidiendo permiso para `delete` en lugar de `list`.

**Preguntas**

1. ¿Qué respuesta devuelve el comando del paso 3, y por qué?
2. ¿Cuál es la sintaxis del identificador que usa `--as` para representar a un `ServiceAccount`?
3. Si en vez de `--as` usaras `kubectl auth can-i list pods` sin flags, ¿a quién estarías evaluando?

---

## Ejercicio 2 — `Role` + `RoleBinding` a nivel de namespace

1. Creá un archivo `pod-reader-role.yaml` con un `Role` que permita `get`, `list` y `watch` sobre `pods` en el namespace `rbac-lab`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: rbac-lab
     name: pod-reader
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ```
2. Aplicalo:
   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```
3. Creá el `RoleBinding` que asocia ese `Role` al `ServiceAccount` `dev-reader` del ejercicio anterior:
   ```bash
   kubectl create rolebinding dev-reader-binding \
     --role=pod-reader \
     --serviceaccount=rbac-lab:dev-reader \
     -n rbac-lab
   ```
4. Volvé a correr la verificación del ejercicio 1, paso 3 y 4, y compará los resultados.
5. Inspeccioná el binding para confirmar el `roleRef` y el `subject`:
   ```bash
   kubectl get rolebinding dev-reader-binding -n rbac-lab -o yaml
   ```

**Preguntas**

1. ¿Cambió el resultado de `kubectl auth can-i list pods`? ¿Y el de `delete pods`? Explicá por qué.
2. En el YAML del `RoleBinding`, ¿qué tres campos identifican al `roleRef` y qué restricción existe sobre su `apiGroup` y `kind` una vez creado el binding (pueden editarse)?
3. ¿Por qué `apiGroups` está definido como `[""]` (string vacío) para el recurso `pods`?

---

## Ejercicio 3 — `ClusterRole` + `ClusterRoleBinding`

1. Creá un `ClusterRole` que permita `get` y `list` sobre `nodes` (un recurso cluster-scoped, sin namespace):
   ```bash
   kubectl create clusterrole node-viewer \
     --verb=get,list \
     --resource=nodes
   ```
2. Asociá ese `ClusterRole` a un nuevo `ServiceAccount` `ops-viewer` (creado en `rbac-lab`) mediante un `ClusterRoleBinding`:
   ```bash
   kubectl create serviceaccount ops-viewer -n rbac-lab
   kubectl create clusterrolebinding ops-viewer-binding \
     --clusterrole=node-viewer \
     --serviceaccount=rbac-lab:ops-viewer
   ```
3. Verificá el acceso a nivel de clúster (sin `-n`, porque `nodes` no tiene namespace):
   ```bash
   kubectl auth can-i list nodes \
     --as=system:serviceaccount:rbac-lab:ops-viewer
   ```
4. Ahora probá si `dev-reader` (el `ServiceAccount` del ejercicio 1-2) puede listar `nodes`.

**Preguntas**

1. ¿Por qué no se puede lograr acceso a `nodes` con un `Role` + `RoleBinding` namespaced?
2. ¿Qué diferencia de alcance hay entre un `ClusterRoleBinding` y un `RoleBinding` que referencia un `ClusterRole`?
3. `dev-reader` no puede listar `nodes`: ¿qué principio de RBAC ilustra este resultado?

---

## Ejercicio 4 — `resourceNames`: limitar el alcance a un recurso específico

1. Creá un `ConfigMap` de prueba:
   ```bash
   kubectl create configmap app-config -n rbac-lab --from-literal=env=dev
   kubectl create configmap other-config -n rbac-lab --from-literal=env=prod
   ```
2. Creá un `Role` que solo permita `get` sobre el `ConfigMap` `app-config`, usando `resourceNames`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: rbac-lab
     name: single-configmap-reader
   rules:
   - apiGroups: [""]
     resources: ["configmaps"]
     resourceNames: ["app-config"]
     verbs: ["get"]
   ```
3. Aplicalo y creá el binding hacia `dev-reader`:
   ```bash
   kubectl apply -f single-configmap-role.yaml
   kubectl create rolebinding cm-reader-binding \
     --role=single-configmap-reader \
     --serviceaccount=rbac-lab:dev-reader \
     -n rbac-lab
   ```
4. Verificá el acceso puntual usando el subrecurso con nombre:
   ```bash
   kubectl auth can-i get configmap/app-config \
     --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
   kubectl auth can-i get configmap/other-config \
     --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
   ```

**Preguntas**

1. ¿Qué diferencia hay en el resultado entre pedir acceso a `app-config` y a `other-config`? ¿Por qué?
2. ¿`resourceNames` puede combinarse con el verbo `list` o `create` de forma útil? Justificá.
3. ¿Qué pasaría si `resources` incluyera `["configmaps", "secrets"]` en la misma regla con el mismo `resourceNames: ["app-config"]`?

---

## Ejercicio 5 — `RoleBinding` que referencia un `ClusterRole` (scoping por namespace)

1. Kubernetes trae `ClusterRole`s predefinidos, como `view`. Confirmá que existe:
   ```bash
   kubectl get clusterrole view
   ```
2. Creá un `RoleBinding` en `rbac-lab` que referencie el `ClusterRole` `view` (no un `Role` propio), asociado al `ServiceAccount` `ops-viewer`:
   ```bash
   kubectl create rolebinding ops-viewer-view-binding \
     --clusterrole=view \
     --serviceaccount=rbac-lab:ops-viewer \
     -n rbac-lab
   ```
3. Verificá el acceso a `deployments` dentro de `rbac-lab` y también en otro namespace, por ejemplo `default`:
   ```bash
   kubectl auth can-i list deployments \
     --as=system:serviceaccount:rbac-lab:ops-viewer -n rbac-lab
   kubectl auth can-i list deployments \
     --as=system:serviceaccount:rbac-lab:ops-viewer -n default
   ```

**Preguntas**

1. Aunque el `roleRef` sea un `ClusterRole`, ¿por qué el acceso queda limitado al namespace `rbac-lab`?
2. ¿Qué ventaja práctica tiene reutilizar `ClusterRole`s predefinidos (`view`, `edit`, `admin`) vía `RoleBinding` en lugar de definir `Role`s propios repetidos en cada namespace?
3. Nombrá al menos otro `ClusterRole` incorporado por defecto en Kubernetes además de `view`.

---

## Ejercicio 6 — `non-resource URLs` y `aggregationRule`

1. Consultá qué `ClusterRole`s tienen acceso a endpoints que no son recursos de la API (como `/healthz` o `/metrics`):
   ```bash
   kubectl get clusterrole system:monitoring -o yaml
   ```
2. Observá la sección `rules` y localizá una entrada con la clave `nonResourceURLs` en lugar de `resources`.
3. Creá un `ClusterRole` propio con acceso de solo lectura a `/healthz`:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: healthz-reader
   rules:
   - nonResourceURLs: ["/healthz", "/healthz/*"]
     verbs: ["get"]
   ```
4. Ahora inspeccioná un `ClusterRole` agregado, como `admin` o `edit`, y buscá el campo `aggregationRule`:
   ```bash
   kubectl get clusterrole admin -o yaml | grep -A5 aggregationRule
   ```

**Preguntas**

1. ¿Qué tipo de permiso modela `nonResourceURLs` y por qué nunca lleva `apiGroups` ni `resourceNames`?
2. ¿Puede un `RoleBinding` (namespaced) referenciar reglas con `nonResourceURLs`? Justificá según el alcance de esas rutas.
3. ¿Qué hace `aggregationRule` con `clusterRoleSelectors`, y qué ventaja de mantenimiento ofrece frente a editar manualmente la lista de `rules` de un `ClusterRole` grande?

---

## Ejercicio 7 — Auditoría de permisos con `kubectl auth can-i --list`

1. Listá todos los permisos efectivos que tiene `dev-reader` en el namespace `rbac-lab`:
   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:rbac-lab:dev-reader -n rbac-lab
   ```
2. Compará contra los permisos efectivos de tu propio usuario actual en el mismo namespace:
   ```bash
   kubectl auth can-i --list -n rbac-lab
   ```
3. Limpiá los recursos creados en este set de ejercicios:
   ```bash
   kubectl delete namespace rbac-lab
   kubectl delete clusterrole node-viewer healthz-reader
   kubectl delete clusterrolebinding ops-viewer-binding
   ```

**Preguntas**

1. ¿Qué diferencia esperás ver entre la salida de `--list` para `dev-reader` y para tu propio usuario?
2. Al borrar el namespace `rbac-lab`, ¿qué pasa automáticamente con los `Role`s y `RoleBinding`s definidos dentro? ¿Y con los `ClusterRole`s y `ClusterRoleBinding`s creados en el ejercicio 3 y 6?
3. ¿Por qué es necesario borrar `node-viewer`, `healthz-reader` y `ops-viewer-binding` explícitamente en un paso aparte?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
1. Devuelve `no` — el `ServiceAccount` `dev-reader` recién creado no tiene ningún `Role`/`ClusterRole` asociado, y en Kubernetes el modelo RBAC es "deny by default": sin un binding explícito no hay permisos.
2. `system:serviceaccount:<namespace>:<nombre-del-sa>`.
3. Estarías evaluando al usuario autenticado con el que corre `kubectl` actualmente (tu `kubeconfig`), no al `ServiceAccount`.

**Ejercicio 2**
1. `list pods` pasa a `yes` porque el `RoleBinding` otorga esa acción vía el `Role` `pod-reader`. `delete pods` sigue en `no` porque el `Role` solo incluye `get`, `list`, `watch`; RBAC es puramente aditivo y no infiere verbos no listados.
2. `apiGroup`, `kind` y `name`. Una vez creado el `RoleBinding` o `ClusterRoleBinding`, el `roleRef` es inmutable: no se puede editar con `kubectl edit`/`apply` para apuntar a otro rol; hay que borrar y recrear el binding.
3. Porque `pods` pertenece al "core API group" (también llamado *legacy group*), que en Kubernetes se representa con un string vacío `""`, a diferencia de recursos con grupo propio como `apps` o `batch`.

**Ejercicio 3**
1. Porque `nodes` es un recurso cluster-scoped (no vive dentro de un namespace). Un `Role`/`RoleBinding` solo puede otorgar permisos sobre recursos namespaced dentro de su propio namespace; para recursos cluster-scoped se necesita un `ClusterRole` combinado con un `ClusterRoleBinding`.
2. Un `ClusterRoleBinding` otorga el permiso del `ClusterRole` en todo el clúster (todos los namespaces, más los recursos cluster-scoped). Un `RoleBinding` que referencia un `ClusterRole` acota ese mismo conjunto de reglas al namespace donde vive el `RoleBinding`.
3. Ilustra que los permisos no son transitivos ni compartidos entre `ServiceAccount`s: cada subject necesita su propio binding explícito, y los permisos de uno no se heredan ni se comparan con los de otro.

**Ejercicio 4**
1. `app-config` da `yes` y `other-config` da `no`, porque `resourceNames` restringe la regla a instancias específicas del recurso identificadas por nombre; el permiso no aplica a otros objetos del mismo tipo aunque estén en el mismo namespace.
2. No es útil combinarlo con `list` o `create`: `list`/`watch`/`create` operan sobre la colección completa (antes de que existan nombres que filtrar, en el caso de `create`), así que Kubernetes ignora `resourceNames` para esos verbos — solo tiene efecto real con verbos que actúan sobre un objeto puntual (`get`, `update`, `patch`, `delete`).
3. La regla otorgaría `get` sobre el `ConfigMap` llamado `app-config` **y** sobre el `Secret` llamado `app-config` (si existiera uno con ese nombre), porque `resourceNames` se aplica a cada tipo de recurso listado en `resources` de forma independiente.

**Ejercicio 5**
1. El binding es un `RoleBinding` (objeto namespaced), y el alcance de un `RoleBinding` siempre está limitado al namespace donde ese `RoleBinding` fue creado, sin importar si el `roleRef` apunta a un `Role` o a un `ClusterRole`.
2. Evita duplicar la definición de reglas en cada namespace: se define el conjunto de permisos una sola vez como `ClusterRole` y se reutiliza vía múltiples `RoleBinding`s namespaced, centralizando el mantenimiento de esas reglas.
3. `edit` y `admin` (también existe `cluster-admin`, que normalmente se usa con `ClusterRoleBinding` por dar control total del clúster).

**Ejercicio 6**
1. Modela acceso a rutas HTTP del API server que no representan objetos de la API (endpoints como `/healthz`, `/metrics`, `/logs`, `/openapi/v2`). No lleva `apiGroups` ni `resourceNames` porque esas rutas no pertenecen a ningún API group ni identifican instancias de un recurso: son URLs fijas del servidor.
2. No. Las `nonResourceURLs` son inherentemente cluster-scoped (no pertenecen a un namespace), así que solo pueden aparecer en `ClusterRole`s referenciados por `ClusterRoleBinding`s; un `RoleBinding` que las referenciara simplemente no tendría efecto sobre ellas.
3. `aggregationRule` con `clusterRoleSelectors` hace que el control plane recopile automáticamente las `rules` de todos los `ClusterRole`s cuyas labels matcheen el selector, y las combine (union) dentro del `ClusterRole` agregador. La ventaja es que plugins o add-ons pueden extender roles como `admin`/`edit`/`view` creando un `ClusterRole` nuevo con la label correspondiente, sin tener que editar directamente el rol grande y sin riesgo de conflictos de merge.

**Ejercicio 7**
1. `dev-reader` debería mostrar solo las acciones puntuales otorgadas por los `Role`s vinculados a él en `rbac-lab` (lectura de pods y de un `ConfigMap` específico), mientras que tu usuario probablemente tiene privilegios mucho más amplios (por ejemplo, si sos cluster-admin del clúster de práctica, verías prácticamente todos los verbos sobre todos los recursos).
2. Al borrar el namespace, Kubernetes hace garbage collection en cascada de todos los objetos namespaced que contenía, incluyendo los `Role`s y `RoleBinding`s definidos ahí. Los `ClusterRole`s y `ClusterRoleBinding`s son cluster-scoped y no pertenecen a ningún namespace, así que no se eliminan con ese borrado.
3. Porque son objetos cluster-scoped, independientes del ciclo de vida de cualquier namespace; Kubernetes no tiene forma de inferir que deben borrarse junto con `rbac-lab`, así que hay que eliminarlos explícitamente para no dejar permisos residuales en el clúster.

</details>