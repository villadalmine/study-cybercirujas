# Ejercicios: 4.2 Understand authentication, authorization and admission control (CKAD)

> Fuente de referencia: [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Estos ejercicios asumen un cluster de Kubernetes accesible vía `kubectl` con permisos de administrador (`cluster-admin`), y un namespace de trabajo llamado `ckad-auth`. Creá ese namespace antes de empezar:

```bash
kubectl create namespace ckad-auth
kubectl config set-context --current --namespace=ckad-auth
```

---

## Ejercicio 1 — ServiceAccounts

1. Listá los ServiceAccounts que ya existen en el namespace `ckad-auth`.

   ```bash
   kubectl get serviceaccounts
   ```

2. Creá un ServiceAccount nuevo llamado `app-sa`.

   ```bash
   kubectl create serviceaccount app-sa
   ```

3. Inspeccioná el ServiceAccount recién creado en formato YAML.

   ```bash
   kubectl get serviceaccount app-sa -o yaml
   ```

4. Creá un Pod que use explícitamente ese ServiceAccount en lugar del `default`.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sa-demo
   spec:
     serviceAccountName: app-sa
     containers:
       - name: main
         image: nginx:1.27
   ```

   ```bash
   kubectl apply -f sa-demo.yaml
   ```

5. Confirmá qué ServiceAccount terminó usando el Pod.

   ```bash
   kubectl get pod sa-demo -o jsonpath='{.spec.serviceAccountName}'
   ```

6. Entrá al contenedor y verificá que el token del ServiceAccount está montado automáticamente.

   ```bash
   kubectl exec -it sa-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

**Preguntas de comprensión**

- Si no hubieras especificado `serviceAccountName` en el manifiesto del Pod, ¿qué ServiceAccount habría usado y por qué?
- ¿Qué tres archivos esperás encontrar montados en `/var/run/secrets/kubernetes.io/serviceaccount/` y para qué sirve cada uno?

---

## Ejercicio 2 — RBAC namespaced: Role y RoleBinding

1. Creá un `Role` que permita `get`, `list` y `watch` sobre Pods dentro de `ckad-auth`.

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: ckad-auth
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

2. Creá un `RoleBinding` que asocie el `Role` `pod-reader` con el ServiceAccount `app-sa` del Ejercicio 1.

   ```bash
   kubectl create rolebinding app-sa-pod-reader \
     --role=pod-reader \
     --serviceaccount=ckad-auth:app-sa
   ```

3. Verificá el binding creado.

   ```bash
   kubectl get rolebinding app-sa-pod-reader -o yaml
   ```

4. Comprobá con `kubectl auth can-i`, impersonando al ServiceAccount, si puede listar Pods y si puede borrarlos.

   ```bash
   kubectl auth can-i list pods \
     --as=system:serviceaccount:ckad-auth:app-sa

   kubectl auth can-i delete pods \
     --as=system:serviceaccount:ckad-auth:app-sa
   ```

**Preguntas de comprensión**

- ¿Por qué el segundo `can-i` debería devolver `no`? ¿Qué regla del `Role` lo determina?
- Un `Role` y su `RoleBinding` están ambos scoped a un namespace. Si necesitaras que `app-sa` lea Pods también en el namespace `default`, ¿alcanzaría con el `RoleBinding` actual? ¿Qué cambiarías?

---

## Ejercicio 3 — RBAC cluster-wide: ClusterRole y ClusterRoleBinding

1. Creá un `ClusterRole` que permita `get` y `list` sobre `nodes` (recurso cluster-scoped).

   ```bash
   kubectl create clusterrole node-viewer \
     --verb=get,list \
     --resource=nodes
   ```

2. Asociá ese `ClusterRole` al ServiceAccount `app-sa` mediante un `ClusterRoleBinding`.

   ```bash
   kubectl create clusterrolebinding app-sa-node-viewer \
     --clusterrole=node-viewer \
     --serviceaccount=ckad-auth:app-sa
   ```

3. Verificá el permiso resultante.

   ```bash
   kubectl auth can-i list nodes \
     --as=system:serviceaccount:ckad-auth:app-sa
   ```

4. Ahora creá un segundo `RoleBinding` (namespaced) que referencie el mismo `ClusterRole` `node-viewer`, pero limitado al namespace `ckad-auth`, y asociado a otro ServiceAccount `app-sa-2`.

   ```bash
   kubectl create serviceaccount app-sa-2

   kubectl create rolebinding app-sa-2-node-viewer \
     --clusterrole=node-viewer \
     --serviceaccount=ckad-auth:app-sa-2
   ```

5. Compará el resultado de `can-i list nodes` para `app-sa-2` contra `app-sa`.

   ```bash
   kubectl auth can-i list nodes \
     --as=system:serviceaccount:ckad-auth:app-sa-2
   ```

**Preguntas de comprensión**

- `nodes` es un recurso cluster-scoped. ¿Por qué el `RoleBinding` del paso 4, a pesar de referenciar un `ClusterRole` válido con reglas sobre `nodes`, no le otorga a `app-sa-2` el permiso de listar nodos?
- ¿Cuál es la diferencia práctica entre reutilizar un `ClusterRole` desde un `RoleBinding` versus desde un `ClusterRoleBinding`?

---

## Ejercicio 4 — Auditoría de permisos con `kubectl auth can-i`

1. Listá todos los permisos que tenés vos mismo (tu usuario/kubeconfig actual) en el namespace `ckad-auth`.

   ```bash
   kubectl auth can-i --list -n ckad-auth
   ```

2. Repetí la consulta pero impersonando al ServiceAccount `app-sa`.

   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:ckad-auth:app-sa \
     -n ckad-auth
   ```

3. Usá `--as-group` para simular pertenencia a un grupo arbitrario y verificar si eso habilita algún permiso adicional (no debería, salvo que exista un binding para ese grupo).

   ```bash
   kubectl auth can-i list secrets \
     --as=someuser \
     --as-group=system:authenticated \
     -n ckad-auth
   ```

**Preguntas de comprensión**

- `kubectl auth can-i` consulta al servidor mediante el objeto `SelfSubjectAccessReview` (o `SubjectAccessReview` cuando usás `--as`). ¿Contra qué componente del control plane se evalúa finalmente esa decisión?
- Si `can-i --list` no muestra ninguna fila para `secrets`, ¿eso garantiza que no existe ningún `ClusterRole`/`Role` en el cluster con permisos sobre `secrets`, o solo que el sujeto consultado no tiene ese permiso?

---

## Ejercicio 5 — Admission control

Los admission controllers actúan *después* de que la request pasa autenticación y autorización (RBAC), pero *antes* de que el objeto se persista en etcd. Algunos, como `ResourceQuota` y `LimitRange`, son admission controllers habilitados por defecto y se configuran con objetos de la API.

1. Creá un `LimitRange` que imponga un límite de CPU por defecto a los contenedores del namespace `ckad-auth`.

   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: cpu-limit-range
   spec:
     limits:
       - default:
           cpu: 500m
         defaultRequest:
           cpu: 250m
         type: Container
   ```

   ```bash
   kubectl apply -f cpu-limit-range.yaml
   ```

2. Creá un Pod sin especificar `resources`, y verificá que el admission controller le inyectó los valores por defecto.

   ```bash
   kubectl run limit-demo --image=nginx:1.27
   kubectl get pod limit-demo -o jsonpath='{.spec.containers[0].resources}'
   ```

3. Creá un `ResourceQuota` que limite a 2 el número de Pods en el namespace.

   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: pod-quota
   spec:
     hard:
       pods: "2"
   ```

   ```bash
   kubectl apply -f pod-quota.yaml
   ```

4. Intentá crear un tercer Pod en el namespace y observá el mensaje de error.

   ```bash
   kubectl run extra-pod --image=nginx:1.27
   ```

**Preguntas de comprensión**

- El error del paso 4 menciona `exceeded quota`. ¿Ese rechazo ocurrió durante autenticación, autorización, o admission control? Justificá con la fase del request pipeline en la que interviene `ResourceQuota`.
- ¿Qué diferencia hay entre un admission controller "built-in" como `LimitRange`/`ResourceQuota` y un `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` en términos de dónde vive la lógica de decisión?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**

- Si no se especifica `serviceAccountName`, el Pod usa el ServiceAccount `default` del namespace, que Kubernetes crea automáticamente en cada namespace nuevo.
- Se montan: `token` (JWT usado para autenticarse contra la API server), `ca.crt` (certificado de la CA del cluster, para validar la identidad del API server) y `namespace` (el namespace del Pod, en texto plano).

**Ejercicio 2**

- El segundo `can-i` devuelve `no` porque el `Role` `pod-reader` solo incluye los verbs `get`, `list` y `watch` sobre `pods`; `delete` no está en esa lista, y RBAC en Kubernetes es "deny by default" (solo se permite lo explícitamente listado en las reglas).
- No alcanzaría. El `RoleBinding` solo otorga el `Role` dentro del namespace en el que vive el `RoleBinding` (`ckad-auth`). Para dar acceso también en `default` habría que crear otro `Role` (o reusar un `ClusterRole`) y otro `RoleBinding` en el namespace `default`.

**Ejercicio 3**

- Un `RoleBinding`, aunque referencie un `ClusterRole`, solo otorga esos permisos dentro del namespace donde vive el propio `RoleBinding`. Como `nodes` es cluster-scoped y no pertenece a ningún namespace, un binding namespaced nunca puede otorgar acceso efectivo sobre un recurso cluster-scoped.
- Un `ClusterRoleBinding` otorga los permisos del `ClusterRole` en todo el cluster (todos los namespaces, más los recursos cluster-scoped). Un `RoleBinding` que referencia un `ClusterRole` reutiliza el mismo set de reglas pero limita su alcance efectivo al namespace del binding, y solo tiene efecto real sobre recursos namespaced.

**Ejercicio 4**

- Se evalúa contra el API server, que consulta los authorizers configurados (por ejemplo el authorizer RBAC) para decidir `allowed: true/false` sobre el `SubjectAccessReview`.
- Solo garantiza que el sujeto consultado (usuario/grupo/ServiceAccount específico pasado con `--as`) no tiene ese permiso. Pueden existir `Role`/`ClusterRole` con permisos sobre `secrets` asociados a otros sujetos; `can-i --list` refleja los permisos efectivos del sujeto evaluado, no un inventario global de RBAC.

**Ejercicio 5**

- Ocurrió en la fase de admission control. El pipeline de una request es: autenticación → autorización (RBAC) → admission controllers (mutating y luego validating) → persistencia en etcd. `ResourceQuota` es un validating admission controller que rechaza la request antes de persistirla, incluso si la autorización RBAC ya permitió la operación.
- Los admission controllers built-in (`LimitRange`, `ResourceQuota`, etc.) tienen su lógica compilada dentro del binario del kube-apiserver y se configuran declarando objetos de la API (`LimitRange`, `ResourceQuota`). Los webhooks (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`) delegan la decisión a un servicio HTTP externo (dentro o fuera del cluster) al que el API server le envía la `AdmissionReview` para que evalúe y responda si acepta, rechaza o modifica el objeto.

</details>