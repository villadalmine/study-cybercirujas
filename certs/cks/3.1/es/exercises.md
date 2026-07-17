# CKS 3.1 — Use Role Based Access Controls to minimize exposure

**Peso en el examen:** 3.75%
**Fuente de referencia:** [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)
**Referencias técnicas adicionales:** [Kubernetes RBAC docs](https://kubernetes.io/docs/reference/access-authn-authz/rbac/), [Authorization overview / `kubectl auth can-i`](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)

Los ejercicios asumen un cluster con el authorization mode `RBAC` habilitado (default en kubeadm, minikube, kind) y `kubectl` configurado con permisos de `cluster-admin` para poder crear los recursos de prueba.

---

## Ejercicio 1 — Mapear el estado actual de RBAC en un namespace

1. Crear un namespace de trabajo y un ServiceAccount de prueba:
   ```bash
   kubectl create namespace rbac-lab
   kubectl create serviceaccount dev-viewer -n rbac-lab
   ```

2. Listar los `Role` y `RoleBinding` que ya existen en el namespace (en un cluster recién creado suele haber alguno provisto por add-ons):
   ```bash
   kubectl get role,rolebinding -n rbac-lab
   kubectl get role,rolebinding -n kube-system
   ```

3. Listar los `ClusterRole` incluidos por default que están pensados para asignarse vía RBAC (los llamados *user-facing roles*):
   ```bash
   kubectl get clusterrole | grep -E '^(view|edit|admin|cluster-admin)\s'
   ```

4. Inspeccionar qué permisos otorga cada uno de esos cuatro ClusterRoles, de menor a mayor privilegio:
   ```bash
   kubectl describe clusterrole view
   kubectl describe clusterrole edit
   kubectl describe clusterrole admin
   kubectl describe clusterrole cluster-admin
   ```

5. Confirmar que `cluster-admin` es el único con acceso total (`*` en `apiGroups`, `resources` y `verbs`):
   ```bash
   kubectl get clusterrole cluster-admin -o jsonpath='{.rules}'
   ```

### Preguntas de comprobación
1. ¿Cuál es la diferencia práctica entre `edit` y `admin` como ClusterRoles user-facing?
2. ¿Por qué el ClusterRole `view` no incluye acceso a `secrets`, a diferencia de `edit` y `admin`?
3. ¿Qué significa, en términos de exposición, que un `Role` o `ClusterRole` use `"*"` en el campo `resources` o `verbs`?

---

## Ejercicio 2 — Diseñar un Role de mínimo privilegio

1. Crear un `Role` que sólo permita leer `pods` y `configmaps` en el namespace `rbac-lab`, usando el comando imperativo (más rápido para el examen que escribir el YAML a mano):
   ```bash
   kubectl create role pod-reader \
     --verb=get,list,watch \
     --resource=pods,configmaps \
     -n rbac-lab
   ```

2. Revisar el YAML generado para confirmar el alcance exacto:
   ```bash
   kubectl get role pod-reader -n rbac-lab -o yaml
   ```

3. Asociar el Role al ServiceAccount `dev-viewer` mediante un `RoleBinding`:
   ```bash
   kubectl create rolebinding dev-viewer-binding \
     --role=pod-reader \
     --serviceaccount=rbac-lab:dev-viewer \
     -n rbac-lab
   ```

4. Verificar el efecto **impersonando** al ServiceAccount con `kubectl auth can-i`, sin necesidad de generar un kubeconfig aparte:
   ```bash
   kubectl auth can-i get pods \
     --as=system:serviceaccount:rbac-lab:dev-viewer -n rbac-lab
   kubectl auth can-i list configmaps \
     --as=system:serviceaccount:rbac-lab:dev-viewer -n rbac-lab
   ```

5. Confirmar que el principio de mínimo privilegio se respeta probando acciones **fuera** del alcance otorgado:
   ```bash
   kubectl auth can-i list secrets \
     --as=system:serviceaccount:rbac-lab:dev-viewer -n rbac-lab
   kubectl auth can-i delete pods \
     --as=system:serviceaccount:rbac-lab:dev-viewer -n rbac-lab
   kubectl auth can-i get pods \
     --as=system:serviceaccount:rbac-lab:dev-viewer -n default
   ```

### Preguntas de comprobación
1. ¿Por qué el tercer chequeo del paso 5 (namespace `default`) devuelve `no` aunque el Role otorgue `get` sobre `pods`?
2. ¿Qué diferencia de exposición hay entre usar un `Role` + `RoleBinding` versus un `ClusterRole` + `RoleBinding` para el mismo caso de uso?
3. ¿Qué bandera de `kubectl auth can-i` usarías para obtener de una sola vez **todos** los permisos efectivos de `dev-viewer`, en lugar de probarlos uno por uno?

---

## Ejercicio 3 — Detectar y remediar bindings sobre-privilegiados

1. Simular un hallazgo típico de auditoría: un ServiceAccount de aplicación atado por error a `cluster-admin`:
   ```bash
   kubectl create serviceaccount app-sa -n rbac-lab
   kubectl create clusterrolebinding app-sa-cluster-admin \
     --clusterrole=cluster-admin \
     --serviceaccount=rbac-lab:app-sa
   ```

2. Escribir una consulta que liste **todos** los `ClusterRoleBinding` que referencian `cluster-admin`, para detectar este tipo de exposición en un cluster real:
   ```bash
   kubectl get clusterrolebinding -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
   ```

3. Ampliar la auditoría a `RoleBinding` en todos los namespaces que también apunten a `cluster-admin` (un ClusterRole puede bindearse con un RoleBinding, acotando el alcance al namespace, pero conservando todos los verbs de `cluster-admin` sobre ese namespace):
   ```bash
   kubectl get rolebinding -A -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | "\(.metadata.namespace)/\(.metadata.name)"'
   ```

4. Remediar reemplazando el binding riesgoso por el Role de mínimo privilegio ya creado en el Ejercicio 2:
   ```bash
   kubectl delete clusterrolebinding app-sa-cluster-admin
   kubectl create rolebinding app-sa-binding \
     --role=pod-reader \
     --serviceaccount=rbac-lab:app-sa \
     -n rbac-lab
   ```

5. Confirmar la remediación:
   ```bash
   kubectl auth can-i '*' '*' --as=system:serviceaccount:rbac-lab:app-sa
   kubectl auth can-i get pods --as=system:serviceaccount:rbac-lab:app-sa -n rbac-lab
   ```

### Preguntas de comprobación
1. ¿Por qué un `RoleBinding` que referencia el ClusterRole `cluster-admin` sigue siendo un hallazgo grave, aunque esté acotado a un solo namespace?
2. En un cluster productivo, ¿qué otro campo del `roleRef` (además de `name`) es importante revisar al auditar bindings peligrosos?
3. ¿Qué principio de seguridad se aplica al preferir "borrar y recrear con el mínimo necesario" en vez de simplemente reducir los `verbs` del ClusterRole `cluster-admin` original?

---

## Ejercicio 4 — Prevenir escalación de privilegios vía RBAC

1. Crear un ClusterRole que le permita a un ServiceAccount **crear RoleBindings**, algo común en herramientas de CI/CD o automatización interna:
   ```bash
   kubectl create clusterrole rolebinding-manager \
     --verb=create,get,list \
     --resource=rolebindings
   kubectl create serviceaccount ci-bot -n rbac-lab
   kubectl create rolebinding ci-bot-manager \
     --clusterrole=rolebinding-manager \
     --serviceaccount=rbac-lab:ci-bot \
     -n rbac-lab
   ```

2. Confirmar que `ci-bot` puede crear RoleBindings dentro de `rbac-lab`:
   ```bash
   kubectl auth can-i create rolebindings \
     --as=system:serviceaccount:rbac-lab:ci-bot -n rbac-lab
   ```

3. Intentar, actuando como `ci-bot`, crear un RoleBinding que le otorgue a **otra** identidad el ClusterRole `admin` (permisos que `ci-bot` mismo no posee):
   ```bash
   kubectl create rolebinding privilege-escalation-test \
     --clusterrole=admin \
     --serviceaccount=rbac-lab:app-sa \
     -n rbac-lab \
     --as=system:serviceaccount:rbac-lab:ci-bot
   ```

4. Observar el resultado (debería fallar con `Forbidden`, distinto del RBAC allow/deny plano) y verificar qué verb resuelve este bloqueo:
   ```bash
   kubectl auth can-i bind clusterroles/admin \
     --as=system:serviceaccount:rbac-lab:ci-bot
   ```

5. Repetir el mismo intento, pero ahora otorgándole a `ci-bot` el verb `bind` explícitamente sobre `clusterroles`, y confirmar que el escenario del paso 3 ahora sí es posible:
   ```bash
   kubectl create clusterrole rolebinding-manager \
     --verb=create,get,list,bind \
     --resource=rolebindings,clusterroles \
     --dry-run=client -o yaml | kubectl apply -f -

   kubectl create rolebinding privilege-escalation-test \
     --clusterrole=admin \
     --serviceaccount=rbac-lab:app-sa \
     -n rbac-lab \
     --as=system:serviceaccount:rbac-lab:ci-bot
   ```

### Preguntas de comprobación
1. ¿Qué protección de Kubernetes evitó que `ci-bot` escalara privilegios en el paso 3, sin que existiera ninguna regla `deny` explícita?
2. ¿Cuál es la diferencia entre el verb `bind` y el verb `escalate` en el contexto de RBAC?
3. Desde la perspectiva de "minimizar exposición", ¿por qué otorgar `create` sobre `rolebindings` a una automatización (CI/CD) es un riesgo aunque esa automatización no tenga otros permisos elevados?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
1. `edit` permite modificar la mayoría de los objetos dentro de un namespace (pods, deployments, services, jobs, etc.) pero no permite ver ni modificar `Role`/`RoleBinding` ni tocar cuotas de recursos; `admin` agrega justamente esa capacidad de administrar RBAC y `ResourceQuota` dentro del namespace, además de casi todo lo de `edit`.
2. Porque `secrets` suele contener credenciales o tokens; otorgar lectura de `secrets` a cualquiera con acceso de "solo lectura" ampliaría la exposición de datos sensibles más allá de lo que ese rol busca permitir.
3. Que el Role/ClusterRole otorga acceso sobre **todos** los recursos o **todas** las acciones dentro de ese `apiGroup`, incluyendo tipos de recursos que se agreguen en el futuro (CRDs nuevos, por ejemplo) — es la antítesis del mínimo privilegio y amplía innecesariamente la superficie de ataque.

**Ejercicio 2**
1. Porque el `RoleBinding` asocia el `Role` `pod-reader` (que vive en el namespace `rbac-lab`) únicamente dentro de ese namespace; un `Role` (a diferencia de un `ClusterRole`) nunca tiene efecto fuera del namespace donde fue creado.
2. Un `ClusterRole` + `RoleBinding` sigue acotando el efecto al namespace del binding, pero es reutilizable en múltiples namespaces sin duplicar el objeto; un `Role` está limitado a un único namespace por definición. Usar `ClusterRole` + `ClusterRoleBinding` en cambio expondría el permiso a todo el cluster, lo cual sería excesivo para este caso de uso.
3. `kubectl auth can-i --list --as=system:serviceaccount:rbac-lab:dev-viewer -n rbac-lab`.

**Ejercicio 3**
1. Porque dentro de ese namespace, la identidad obtiene efectivamente **todos** los verbs sobre **todos** los recursos (incluidos `secrets`, `pods/exec`, y la posibilidad de escalar aún más si el namespace tiene RBAC propio) — el "blast radius" queda acotado al namespace, pero sigue siendo control total sobre él.
2. El `apiGroup` dentro de `roleRef` (y confirmar que `kind` sea `ClusterRole` y no `Role`, ya que un nombre puede coincidir entre ambos tipos).
3. El principio de mínimo privilegio: en vez de partir de un permiso amplio y recortarlo (lo cual es propenso a dejar accesos no revisados), se parte de cero y se agregan sólo los permisos estrictamente necesarios, quedando el resultado auditable y explícito.

**Ejercicio 4**
1. La verificación de **prevención de escalación de privilegios** (*privilege escalation prevention*) que aplica el admission control de RBAC al crear o actualizar `RoleBinding`/`ClusterRoleBinding` y `Role`/`ClusterRole`: por defecto, un usuario sólo puede otorgar permisos que él mismo ya posee.
2. `escalate` permite crear o modificar `Role`/`ClusterRole` con permisos que el propio usuario no tiene (se aplica al *recurso Role/ClusterRole en sí*); `bind` permite crear `RoleBinding`/`ClusterRoleBinding` que referencian un `Role`/`ClusterRole` con permisos que el usuario no posee (se aplica al *acto de bindear*). Son dos puntos de control distintos para el mismo problema de fondo.
3. Porque `create` sobre `rolebindings` es en sí mismo un vector de escalación: si en el futuro esa automatización obtiene (por error de configuración, compromiso de credenciales, o un cambio posterior) el verb `bind`, puede usar su capacidad de crear bindings para asignarse a sí misma o a otra identidad un ClusterRole arbitrariamente más privilegiado — el riesgo no está en el permiso actual sino en la cadena de escalación que ese permiso habilita.

</details>