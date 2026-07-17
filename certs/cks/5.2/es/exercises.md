# CKS 5.2 — Using least-privilege identity and access management

**Peso en el examen:** 2.5

**Fuentes:**
- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes ServiceAccounts — https://kubernetes.io/docs/concepts/security/service-accounts/

---

## Ejercicio 1 — Auditar el ServiceAccount por defecto de un namespace

Todo Pod que no especifica `serviceAccountName` usa el ServiceAccount `default` de su namespace, y por defecto Kubernetes monta un token de ese SA vía projected volume. Ese token es una identidad ante el API server, aunque nadie la haya pedido explícitamente. El primer paso de least privilege es entender qué identidad recibe un Pod sin que nadie se lo proponga.

1. Creá un namespace de trabajo:
   ```bash
   kubectl create namespace ns-rbac-lab
   ```
2. Inspeccioná el ServiceAccount `default` que Kubernetes crea automáticamente:
   ```bash
   kubectl get sa default -n ns-rbac-lab -o yaml
   ```
3. Lanzá un Pod sin indicar `serviceAccountName`:
   ```bash
   kubectl run probe --image=busybox -n ns-rbac-lab --restart=Never -- sleep 3600
   ```
4. Entrá al Pod y listá el volumen proyectado del token:
   ```bash
   kubectl exec -n ns-rbac-lab probe -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
5. Desde dentro del Pod, usá ese token para autenticarte contra el API server:
   ```bash
   kubectl exec -n ns-rbac-lab probe -- sh -c '
     TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
     CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
     wget -q -O- --header="Authorization: Bearer $TOKEN" --ca-certificate=$CACERT \
       https://kubernetes.default.svc/api/v1/namespaces/ns-rbac-lab/pods
   '
   ```

**Preguntas:**
1. El comando del paso 5 devuelve un error `403 Forbidden` en vez de `401 Unauthorized`. ¿Qué diferencia hay entre esos dos códigos en términos de authentication vs. authorization?
2. ¿Por qué el Pod pudo identificarse ante el API server (obtener respuesta autenticada) si nadie le asignó ningún Role?

---

## Ejercicio 2 — Deshabilitar el automount del token cuando no hace falta

La mayoría de los Pods de una app típica (frontends, workers que no hablan con el API server) no necesitan token alguno. Dejar de montarlo elimina una credencial que un atacante podría exfiltrar tras comprometer el contenedor.

1. Deshabilitá el automount a nivel ServiceAccount:
   ```bash
   kubectl patch sa default -n ns-rbac-lab -p '{"automountServiceAccountToken": false}'
   ```
2. Borrá el Pod anterior y volvé a crearlo:
   ```bash
   kubectl delete pod probe -n ns-rbac-lab
   kubectl run probe --image=busybox -n ns-rbac-lab --restart=Never -- sleep 3600
   ```
3. Confirmá que ya no se monta el token:
   ```bash
   kubectl exec -n ns-rbac-lab probe -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```
4. Creá un segundo Pod que necesita el token puntualmente, sobreescribiendo el setting a nivel Pod:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe-with-token
     namespace: ns-rbac-lab
   spec:
     serviceAccountName: default
     automountServiceAccountToken: true
     containers:
     - name: busybox
       image: busybox
       command: ["sleep", "3600"]
   ```
   ```bash
   kubectl apply -f probe-with-token.yaml
   kubectl exec -n ns-rbac-lab probe-with-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

**Preguntas:**
1. ¿Qué precedencia tiene `automountServiceAccountToken` cuando está definido tanto en el ServiceAccount como en el Pod?
2. Si una app nunca llama al API server, ¿qué gana en términos de superficie de ataque al deshabilitar el automount, comparado con solo restringir permisos vía RBAC?

---

## Ejercicio 3 — ServiceAccount dedicado + Role de mínimo privilegio

En vez de usar `default`, cada aplicación que sí necesita hablar con el API server debe tener su propio ServiceAccount, atado a un Role que exponga solo los verbos y recursos estrictamente necesarios.

1. Creá un ServiceAccount dedicado:
   ```bash
   kubectl create sa pod-reader -n ns-rbac-lab
   ```
2. Definí un Role namespaced que solo permite leer Pods:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: ns-rbac-lab
     name: pod-reader-role
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ```
3. Aplicá el Role y creá el RoleBinding:
   ```bash
   kubectl apply -f pod-reader-role.yaml
   kubectl create rolebinding pod-reader-binding \
     --role=pod-reader-role \
     --serviceaccount=ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
4. Creá un Pod que use ese ServiceAccount y verificá que puede listar Pods:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: reader
     namespace: ns-rbac-lab
   spec:
     serviceAccountName: pod-reader
     containers:
     - name: busybox
       image: busybox
       command: ["sleep", "3600"]
   ```
   ```bash
   kubectl apply -f reader-pod.yaml
   kubectl exec -n ns-rbac-lab reader -- sh -c '
     TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
     CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
     wget -q -O- --header="Authorization: Bearer $TOKEN" --ca-certificate=$CACERT \
       https://kubernetes.default.svc/api/v1/namespaces/ns-rbac-lab/pods
   '
   ```
5. Verificá que ese mismo ServiceAccount **no** puede leer Secrets ni borrar Pods:
   ```bash
   kubectl exec -n ns-rbac-lab reader -- sh -c '
     TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
     CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
     wget -q -O- --header="Authorization: Bearer $TOKEN" --ca-certificate=$CACERT \
       https://kubernetes.default.svc/api/v1/namespaces/ns-rbac-lab/secrets
   '
   ```

**Preguntas:**
1. Si quisiéramos permitir que esta app reinicie sus propios Pods eliminándolos, ¿qué cambio mínimo habría que hacer al Role?
2. ¿Por qué conviene un `Role` namespaced en vez de un `ClusterRole` para este caso de uso?

---

## Ejercicio 4 — Verificar permisos con `kubectl auth can-i`

`kubectl auth can-i` permite auditar permisos sin tener que generar tokens ni hacer requests HTTP manuales, incluso simulando identidades ajenas con `--as`.

1. Confirmá lo que puede hacer el ServiceAccount `pod-reader`:
   ```bash
   kubectl auth can-i list pods \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
2. Confirmá lo que **no** puede hacer:
   ```bash
   kubectl auth can-i delete pods \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab

   kubectl auth can-i list secrets \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
3. Listá todos los permisos efectivos del SA en el namespace:
   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
4. Probá una consulta de wildcard total para detectar over-privilege:
   ```bash
   kubectl auth can-i '*' '*' \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```

**Preguntas:**
1. ¿Qué ventaja tiene auditar con `kubectl auth can-i --as=...` frente a leer manualmente los YAML de Roles y RoleBindings?
2. ¿Por qué el resultado del paso 4 (`'*' '*'`) debería ser `no` para cualquier identidad de aplicación bien configurada?

---

## Ejercicio 5 — Detectar over-privilege: wildcards y bindings peligrosos

Muchos incidentes reales (incluyendo el criptojacking en clusters de Kubernetes expuestos sin autenticación) empiezan con un binding de `cluster-admin` a una identidad que no debería tenerlo, o con reglas RBAC que usan `"*"` "por las dudas".

1. Creá deliberadamente un ejemplo de mala práctica: un ClusterRole con wildcard total:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: overprivileged-example
   rules:
   - apiGroups: ["*"]
     resources: ["*"]
     verbs: ["*"]
   ```
   ```bash
   kubectl apply -f overprivileged-clusterrole.yaml
   kubectl create clusterrolebinding overprivileged-binding \
     --clusterrole=overprivileged-example \
     --serviceaccount=ns-rbac-lab:pod-reader
   ```
2. Auditá todos los ClusterRoleBindings que apuntan a `cluster-admin`:
   ```bash
   kubectl get clusterrolebindings -o json | \
     jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'
   ```
3. Auditá bindings que involucren `system:anonymous` o el grupo `system:unauthenticated`:
   ```bash
   kubectl get clusterrolebindings -o json | \
     jq -r '.items[] | select(.subjects[]?.name=="system:anonymous" or .subjects[]?.name=="system:unauthenticated") | .metadata.name'
   ```
4. Confirmá con `can-i` el alcance real del binding wildcard creado en el paso 1:
   ```bash
   kubectl auth can-i delete nodes \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader
   ```
5. Revertí la mala práctica: borrá el binding y el ClusterRole wildcard, dejando solo el Role de mínimo privilegio del Ejercicio 3:
   ```bash
   kubectl delete clusterrolebinding overprivileged-binding
   kubectl delete clusterrole overprivileged-example
   ```

**Preguntas:**
1. ¿Por qué usar `apiGroups`, `resources` o `verbs` con `"*"` es una violación de least privilege incluso si el clúster "funciona bien" con esa regla?
2. ¿Qué riesgo concreto representa un ClusterRoleBinding que otorga `cluster-admin` a `system:anonymous` en un clúster con acceso anónimo habilitado?

---

## Ejercicio 6 — Verbos sensibles: `impersonate`, `bind` y `escalate`

RBAC tiene salvaguardas específicas contra la escalación de privilegios: por default, ningún usuario puede crear un Role/ClusterRole ni un RoleBinding que otorgue permisos que él mismo no posee, salvo que tenga explícitamente los verbos `escalate` o `bind`.

1. Creá un usuario limitado (vía SA) que solo puede leer Pods, y otro Role más amplio que incluye Secrets:
   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: ns-rbac-lab
     name: role-manager
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["get", "list", "create"]
   ```
   ```bash
   kubectl apply -f role-manager.yaml
   kubectl create rolebinding role-manager-binding \
     --role=role-manager \
     --serviceaccount=ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
2. Intentá, impersonando a `pod-reader`, crear un nuevo Role que incluya permisos sobre `secrets` (que `pod-reader` no tiene):
   ```bash
   kubectl auth can-i create roles \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab

   kubectl --as=system:serviceaccount:ns-rbac-lab:pod-reader apply -f - <<'EOF'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: ns-rbac-lab
     name: secret-reader-attempt
   rules:
   - apiGroups: [""]
     resources: ["secrets"]
     verbs: ["get", "list"]
   EOF
   ```
3. Verificá que `pod-reader` necesitaría el verbo `impersonate` sobre `serviceaccounts` para poder usar `--as` en un clúster real (acá funcionó porque lo estás ejecutando vos como admin, no como el SA):
   ```bash
   kubectl auth can-i impersonate serviceaccounts \
     --as=system:serviceaccount:ns-rbac-lab:pod-reader \
     -n ns-rbac-lab
   ```
4. Agregá el verbo `escalate` al Role `role-manager` y repetí el intento del paso 2 para comparar el resultado:
   ```yaml
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["get", "list", "create", "escalate"]
   ```

**Preguntas:**
1. ¿Qué evita, por defecto, que `pod-reader` en el paso 2 pueda crear un Role con acceso a `secrets` aunque tenga el verbo `create` sobre `roles`?
2. ¿Qué diferencia hay entre el verbo `escalate` y el verbo `bind` en el contexto de prevención de privilege escalation vía RBAC?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
1. `401 Unauthorized` significa que el servidor no pudo identificar al solicitante (falla la authentication). `403 Forbidden` significa que el solicitante fue identificado correctamente (authentication OK) pero no tiene permiso para la acción pedida (falla la authorization). El Pod se autenticó con éxito usando su token de ServiceAccount, pero no tiene ningún RoleBinding que le otorgue acceso a `pods`.
2. Porque el kubelet monta automáticamente un token del ServiceAccount `default` vía projected volume, y ese token es válido para autenticarse ante el API server aunque el SA no tenga ningún Role o RoleBinding asociado. Autenticación e identidad no dependen de tener permisos: cualquier SA existente puede autenticarse; lo que falta sin bindings es la autorización.

**Ejercicio 2**
1. El valor del Pod tiene precedencia sobre el del ServiceAccount. Si el Pod define explícitamente `automountServiceAccountToken`, ese valor gana; si el Pod no lo define, se hereda el valor del SA.
2. Se elimina por completo una credencial válida del filesystem del contenedor. Aunque el RBAC esté bien configurado, un atacante que comprometa el contenedor y no encuentre ningún token no tiene ninguna identidad que exfiltrar o reusar contra el API server — es defensa en profundidad, no redundante con RBAC.

**Ejercicio 3**
1. Agregar el verbo `delete` (y opcionalmente `deletecollection`) a la lista de `verbs` sobre el recurso `pods` en el Role.
2. Porque un `ClusterRole` combinado con un `RoleBinding` (o `ClusterRoleBinding`) da alcance sobre todos los namespaces del clúster o requiere pasos extra para acotarlo. Un `Role` namespaced garantiza que el permiso nunca puede aplicarse fuera de `ns-rbac-lab`, cumpliendo mejor con least privilege al reducir el blast radius por diseño.

**Ejercicio 4**
1. `can-i --as` simula el resultado real que evalúa el admission/authorization chain del API server, incluyendo la resolución de todos los RoleBindings y ClusterRoleBindings aplicables. Leer YAML manualmente obliga a razonar a mano sobre binding aggregation, herencia y combinaciones de reglas, lo cual es propenso a error, especialmente cuando hay múltiples bindings apilados sobre la misma identidad.
2. Porque un `sí` en `'*' '*'` significa acceso total sobre cualquier recurso y verbo del clúster (equivalente a `cluster-admin`), lo cual nunca es necesario para una aplicación cuya función es específica; sería la máxima violación posible del principio de least privilege.

**Ejercicio 5**
1. Porque least privilege se mide por el permiso otorgado, no por el permiso usado. Una regla wildcard le da a la identidad la capacidad de hacer cualquier cosa sobre cualquier recurso, incluso si la app hoy solo usa una fracción de eso — si la identidad es comprometida (token robado, contenedor vulnerado), el atacante hereda toda esa capacidad no utilizada.
2. Si el acceso anónimo está habilitado, cualquier request sin credenciales (incluyendo un atacante externo que llegue al API server expuesto) se autentica como `system:anonymous`. Con `cluster-admin` ligado a esa identidad, ese atacante obtiene control total del clúster sin necesitar ninguna credencial válida — este es el patrón detrás de incidentes reales de clusters comprometidos por exposición accidental del API server.

**Ejercicio 6**
1. RBAC tiene una regla de "no escalation por defecto": un actor solo puede otorgar (vía `create`/`update` de Roles o RoleBindings) permisos que él mismo ya posee, salvo que tenga el verbo especial `escalate` sobre el recurso `roles`/`clusterroles`. Como `pod-reader` no tiene acceso a `secrets`, el API server rechaza la creación de un Role que sí lo otorgue, aunque tenga `create` sobre `roles` en general.
2. `escalate` permite crear o modificar un Role/ClusterRole que otorgue permisos que el actor no posee actualmente (rompe la regla de "no puedo dar lo que no tengo" al definir la regla). `bind` permite crear un RoleBinding/ClusterRoleBinding que referencie un Role con permisos que el actor no posee (rompe la misma regla, pero al momento de asociar el Role a un subject, no al definir el Role). Son dos puntos de control distintos sobre el mismo problema: definición de la regla vs. asignación de la regla a alguien.

</details>