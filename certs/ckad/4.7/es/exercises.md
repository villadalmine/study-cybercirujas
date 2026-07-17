# 4.7 Understand ServiceAccounts — Ejercicios guiados

**Examen:** CKAD (versión 1.35) · **Peso:** 3

Todos los ejercicios usan un namespace dedicado para no interferir con otros recursos del cluster.

```bash
kubectl create namespace ckad-4-7
kubectl config set-context --current --namespace=ckad-4-7
```

---

## Ejercicio 1 — ServiceAccount por defecto vs. ServiceAccount propio

1. Listá los ServiceAccounts que ya existen en el namespace recién creado.

   ```bash
   kubectl get serviceaccounts
   ```

2. Creá un Pod **sin** especificar `serviceAccountName`.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-default
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-default --timeout=60s
   ```

3. Confirmá qué ServiceAccount quedó asignado.

   ```bash
   kubectl get pod pod-default -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   ```

4. Creá un ServiceAccount propio y un segundo Pod que lo use explícitamente.

   ```bash
   kubectl create serviceaccount app-sa
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app-sa
   spec:
     serviceAccountName: app-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-app-sa --timeout=60s
   kubectl get pod pod-app-sa -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   ```

5. Intentá cambiar el ServiceAccount de `pod-default` **después** de creado.

   ```bash
   kubectl patch pod pod-default -p '{"spec":{"serviceAccountName":"app-sa"}}'
   ```

<details>
<summary>Preguntas — Ejercicio 1</summary>

1. ¿Qué ServiceAccount aparece en el paso 3, y de dónde sale ya que el manifiesto del paso 2 no lo menciona?
2. ¿Qué devuelve el `patch` del paso 5, y por qué?
3. Si `app-sa` no otorga ningún permiso RBAC, ¿en qué se diferencia `pod-app-sa` de `pod-default` en la práctica?

**Respuestas**

1. Aparece `default`. Todo namespace tiene desde su creación un ServiceAccount llamado `default`, y todo Pod que no especifica `spec.serviceAccountName` queda automáticamente asociado a él — no es que el Pod "no tenga" identidad, sino que Kubernetes completa el campo con ese valor por defecto.
2. Devuelve un error indicando que el campo es inmutable (algo como `Forbidden: pod updates may not change fields other than...`). `spec.serviceAccountName` solo puede fijarse al crear el Pod; cambiarlo requiere borrar y recrear el Pod (en un Deployment, esto se resuelve editando el `template` y dejando que el rollout reemplace los Pods).
3. En la práctica, ninguna: mientras ninguno de los dos ServiceAccounts tenga un `RoleBinding`/`ClusterRoleBinding` asociado, ambos Pods tienen exactamente los mismos permisos (ninguno) contra la API. La diferencia aparece recién cuando se empieza a otorgar RBAC — usar un ServiceAccount dedicado permite auditar y limitar permisos por aplicación en vez de heredarlos todos del `default` compartido por todo el namespace.

</details>

---

## Ejercicio 2 — El token: autenticación (401) vs. autorización (403)

1. Creá un Pod con una imagen que tenga `curl`, usando `app-sa`, para poder llamar a la API desde adentro.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-curl
   spec:
     serviceAccountName: app-sa
     containers:
     - name: curl
       image: curlimages/curl:8.11.0
       command: ["sleep", "3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-curl --timeout=60s
   ```

2. Confirmá qué archivos monta el kubelet para la identidad de `app-sa`.

   ```bash
   kubectl exec pod-curl -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

3. Pedí un token de vida muy corta con `kubectl create token`, y usalo de inmediato para llamar a la API desde el Pod.

   ```bash
   TOKEN=$(kubectl create token app-sa --duration=30s)
   kubectl exec pod-curl -- curl -sS -o /dev/null -w "%{http_code}\n" \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   ```

4. Esperá a que ese token expire, y repetí exactamente el mismo llamado con el mismo `$TOKEN`.

   ```bash
   sleep 40
   kubectl exec pod-curl -- curl -sS -o /dev/null -w "%{http_code}\n" \
     --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
     -H "Authorization: Bearer $TOKEN" \
     https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   ```

5. Ahora repetí el llamado usando el token que el kubelet montó automáticamente en el Pod (el del paso 2), que todavía no venció.

   ```bash
   kubectl exec pod-curl -- sh -c '
     curl -sS -o /dev/null -w "%{http_code}\n" \
       --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
       -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
       https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   '
   ```

<details>
<summary>Preguntas — Ejercicio 2</summary>

1. ¿Qué código HTTP devuelven los pasos 3 y 5, y por qué, si `app-sa` no tiene ningún `RoleBinding` todavía?
2. ¿Qué código HTTP devuelve el paso 4, y en qué se diferencia conceptualmente de los pasos 3 y 5?
3. ¿Por qué el token del paso 5 (montado automáticamente) sigue funcionando cuando el token de vida corta del paso 3 ya venció, si ambos identifican a la misma identidad `app-sa`?

**Respuestas**

1. Devuelven **403 Forbidden**. El API server sí logra autenticar el token (reconoce la identidad `system:serviceaccount:ckad-4-7:app-sa`), pero RBAC no tiene ninguna regla que le otorgue `list` sobre `pods` — la solicitud es rechazada por falta de autorización, no por un problema con el token en sí.
2. Devuelve **401 Unauthorized**. A diferencia del 403, acá el API server ni siquiera llega a evaluar RBAC: el token ya venció (pasaron los 30 segundos de `--duration=30s`), así que la autenticación falla de entrada. 401 = "no sé quién sos" (falla la autenticación); 403 = "ya sé quién sos, pero no tenés permiso" (falla la autorización).
3. El token de vida corta se pidió explícitamente con `--duration=30s` para esta demostración. El token que el kubelet monta automáticamente en `/var/run/secrets/kubernetes.io/serviceaccount/token` tiene, por defecto, una vida de aproximadamente una hora, y el kubelet lo renueva solo antes de que venza mientras el Pod siga corriendo — por eso sigue siendo válido (aunque igual de "no autorizado" en términos de RBAC) mucho después de que el token de 30 segundos ya haya expirado.

</details>

---

## Ejercicio 3 — RBAC: de `Forbidden` a `Allowed`

1. Confirmá, sin tocar nada todavía, que `app-sa` no puede listar Pods (simulación, sin necesidad de `exec`).

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

2. Creá un `Role` con permiso de lectura sobre Pods y un `RoleBinding` que se lo otorgue a `app-sa`.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
   rules:
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: app-sa-pod-reader
   subjects:
   - kind: ServiceAccount
     name: app-sa
     namespace: ckad-4-7
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   EOF
   ```

3. Repetí la simulación del paso 1.

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

4. Confirmá el cambio real, llamando a la API desde `pod-curl` (ejercicio 2) con el token montado automáticamente.

   ```bash
   kubectl exec pod-curl -- sh -c '
     curl -sS -o /dev/null -w "%{http_code}\n" \
       --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
       -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
       https://kubernetes.default.svc/api/v1/namespaces/ckad-4-7/pods
   '
   ```

5. Probá si ese mismo permiso aplica en otro namespace.

   ```bash
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa -n kube-system
   ```

<details>
<summary>Preguntas — Ejercicio 3</summary>

1. ¿Por qué el paso 3 devuelve `yes` sin que se haya tocado el token ni el Pod para nada?
2. ¿Por qué el `subject` del `RoleBinding` en el paso 2 incluye `namespace: ckad-4-7` de forma explícita?
3. ¿Qué devuelve el paso 5, y por qué un `Role`/`RoleBinding` no alcanza para eso?

**Respuestas**

1. Porque RBAC se evalúa en cada request contra el estado **actual** de `Role`s y `RoleBinding`s — no hay nada que "refrescar" en el token ni en el Pod. La misma identidad autenticada (`system:serviceaccount:ckad-4-7:app-sa`) que antes no tenía permisos ahora sí los tiene, porque el `RoleBinding` creado en el paso 2 la vincula al `Role` `pod-reader`.
2. Porque un `RoleBinding` puede, en teoría, referenciar un ServiceAccount de **otro** namespace (por ejemplo, un Pod corriendo en `ckad-4-7` cuyo ServiceAccount fue definido en otro lado). El campo `namespace` del `subject` es obligatorio precisamente para no asumir "el mismo namespace del binding" y evitar apuntar por error a una identidad equivocada.
3. Devuelve `no`. `pod-reader` es un `Role` (namespaced) y el `RoleBinding` que lo usa solo aplica dentro de `ckad-4-7`. Para que `app-sa` tenga el mismo permiso en `kube-system` (o en todo el cluster) haría falta un `ClusterRole` combinado con un `RoleBinding` en cada namespace deseado, o un `ClusterRoleBinding` si el permiso debe aplicar a todos los namespaces por igual.

</details>

---

## Ejercicio 4 — `automountServiceAccountToken`: quién gana entre Pod y ServiceAccount

1. Creá un ServiceAccount con el montaje automático del token desactivado.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: quiet-sa
   automountServiceAccountToken: false
   EOF
   ```

2. Creá un Pod que use `quiet-sa` sin definir nada a nivel Pod.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-quiet
   spec:
     serviceAccountName: quiet-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-quiet --timeout=60s
   kubectl exec pod-quiet -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```

3. Creá un segundo Pod que use `quiet-sa` pero **fuerce** el montaje a nivel Pod.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-quiet-override
   spec:
     serviceAccountName: quiet-sa
     automountServiceAccountToken: true
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-quiet-override --timeout=60s
   kubectl exec pod-quiet-override -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

4. Creá un tercer Pod que use `app-sa` (que sí automonta por defecto) pero lo desactive a nivel Pod.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app-sa-no-token
   spec:
     serviceAccountName: app-sa
     automountServiceAccountToken: false
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/pod-app-sa-no-token --timeout=60s
   kubectl exec pod-app-sa-no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```

<details>
<summary>Preguntas — Ejercicio 4</summary>

1. ¿Qué muestra el paso 2, y de dónde sale ese comportamiento si el Pod no menciona `automountServiceAccountToken` en absoluto?
2. Comparando los pasos 3 y 4, ¿qué regla de precedencia se confirma entre `spec.automountServiceAccountToken` del Pod y el del ServiceAccount?
3. ¿Cuándo conviene desactivar el automontaje, y qué se gana concretamente al hacerlo?

**Respuestas**

1. Muestra `No such file or directory`: no se monta ningún volumen de token. El Pod hereda el valor `automountServiceAccountToken: false` de `quiet-sa` porque no define nada propio a nivel `spec`.
2. Se confirma que **el valor del Pod siempre gana** cuando está definido explícitamente, sin importar qué diga el ServiceAccount: en el paso 3, el Pod fuerza `true` sobre un ServiceAccount con `false` y el token aparece; en el paso 4, el Pod fuerza `false` sobre un ServiceAccount con automontaje por defecto (`true`) y el token no aparece. Solo cuando el Pod no define el campo se usa el valor del ServiceAccount, y solo si tampoco el ServiceAccount lo define, el default final es `true`.
3. Conviene desactivarlo en cualquier Pod cuyo proceso no necesite hablar con la API server (por ejemplo, un servidor web estático o un proceso batch que solo lee de una base de datos externa). Lo que se gana es reducir superficie de ataque: si el container es comprometido, no hay ninguna credencial de cluster disponible para que el atacante la use, sin perder ninguna funcionalidad real de la aplicación.

</details>

---

## Ejercicio 5 — `imagePullSecrets` en el ServiceAccount: herencia condicional

1. Creá un Secret de tipo `docker-registry` (con datos ficticios, solo para este ejercicio).

   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=demo \
     --docker-password=demo-pass \
     --docker-email=demo@example.com
   ```

2. Asociá ese Secret como `imagePullSecrets` de `app-sa`.

   ```bash
   kubectl patch serviceaccount app-sa \
     -p '{"imagePullSecrets": [{"name": "regcred"}]}'
   ```

3. Creá un Pod que use `app-sa` **sin** declarar su propio `imagePullSecrets`, y revisá qué quedó en su `spec`.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-inherits
   spec:
     serviceAccountName: app-sa
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl get pod pod-inherits -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
   ```

4. Creá un segundo Secret ficticio distinto, y un Pod que use `app-sa` pero que además declare **su propio** `imagePullSecrets` apuntando a ese segundo Secret.

   ```bash
   kubectl create secret docker-registry regcred2 \
     --docker-server=registry2.example.com \
     --docker-username=demo2 \
     --docker-password=demo-pass2 \
     --docker-email=demo2@example.com

   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-own-secret
   spec:
     serviceAccountName: app-sa
     imagePullSecrets:
     - name: regcred2
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl get pod pod-own-secret -o jsonpath='{.spec.imagePullSecrets}{"\n"}'
   ```

<details>
<summary>Preguntas — Ejercicio 5</summary>

1. ¿Qué aparece en `spec.imagePullSecrets` de `pod-inherits` en el paso 3, si el manifiesto no lo menciona en absoluto?
2. ¿Qué aparece en `spec.imagePullSecrets` de `pod-own-secret` en el paso 4: `regcred2` solo, `regcred` solo, o ambos combinados?
3. Si una aplicación necesita **tanto** el Secret del ServiceAccount (`regcred`) **como** uno propio (`regcred2`) para tirar imágenes de dos registries distintos, ¿qué hay que hacer en el manifiesto del Pod?

**Respuestas**

1. Aparece `[{"name":"regcred"}]`. El admission controller de ServiceAccount copia los `imagePullSecrets` del ServiceAccount al `spec` del Pod en el momento de crearlo, siempre que el Pod no traiga ya su propio `imagePullSecrets`.
2. Aparece **solo** `regcred2` — el `regcred` del ServiceAccount **no** se agrega. La copia automática del ServiceAccount ocurre únicamente cuando el campo `imagePullSecrets` del Pod está vacío al momento de la creación; si el Pod ya trae uno propio (aunque sea un solo elemento), Kubernetes no combina ambas listas, simplemente no toca el campo. Esto contradice la intuición de "se van a sumar", y es un detalle fácil de asumir mal.
3. Hay que listar **ambos** Secrets explícitamente en el `imagePullSecrets` del propio Pod (`- name: regcred` y `- name: regcred2`), porque apoyarse en la herencia automática del ServiceAccount deja de funcionar apenas el Pod declara cualquier `imagePullSecrets` propio.

</details>

---

## Ejercicio 6 — Troubleshooting: ServiceAccount inexistente y `RoleBinding` huérfano

1. Intentá crear un Pod que referencia, a propósito, un ServiceAccount que **no existe**.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-bad-sa
   spec:
     serviceAccountName: no-existe
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   ```

2. Confirmá que el Pod nunca llegó a crearse.

   ```bash
   kubectl get pod pod-bad-sa
   ```

3. Borrá el ServiceAccount `app-sa`, que todavía tiene el `RoleBinding` `app-sa-pod-reader` del ejercicio 3 apuntándole.

   ```bash
   kubectl delete serviceaccount app-sa
   kubectl get serviceaccount app-sa 2>&1
   ```

4. Sin tocar el `RoleBinding`, volvé a simular el permiso sobre la misma identidad ya borrada.

   ```bash
   kubectl describe rolebinding app-sa-pod-reader
   kubectl auth can-i list pods --as=system:serviceaccount:ckad-4-7:app-sa
   ```

<details>
<summary>Preguntas — Ejercicio 6</summary>

1. ¿Qué mensaje de error devuelve el paso 1, y en qué momento exacto se rechaza el Pod (antes de guardarse en `etcd`, o después, al arrancar el container)?
2. Comparando con el tema de ConfigMaps (que admite `optional: true` para referencias rotas), ¿existe un equivalente `optional` para `serviceAccountName`?
3. ¿Qué devuelve el paso 4, y qué implica en términos de seguridad que un `RoleBinding` no se borre ni se invalide automáticamente cuando se borra el ServiceAccount que referencia?

**Respuestas**

1. Devuelve un error del estilo `pods "pod-bad-sa" is forbidden: error looking up service account ckad-4-7/no-existe: serviceaccount "no-existe" not found`. El rechazo ocurre **antes** de que el Pod se persista: el admission controller de ServiceAccount valida en el momento de la creación que el ServiceAccount referenciado exista, y si no existe, la request de creación es denegada por completo — el Pod jamás llega a existir como objeto (a diferencia de un ConfigMap faltante, que sí permite crear el Pod y solo falla después, al arrancar el container).
2. No. Para `serviceAccountName` no existe ningún campo equivalente a `optional: true`. Un Pod siempre necesita una identidad válida y existente para poder ser admitido — no hay forma de decirle a Kubernetes "si no existe, arrancá igual sin identidad".
3. Devuelve `yes`: el `RoleBinding` sigue vigente. Como RBAC evalúa el `subject` por nombre de string (`system:serviceaccount:ckad-4-7:app-sa`), no verifica en cada request si ese ServiceAccount todavía existe como objeto — el binding queda "huérfano" pero funcionalmente activo para esa identidad. La implicación de seguridad es real: si alguien vuelve a crear un ServiceAccount llamado `app-sa` en `ckad-4-7` (por accidente o a propósito) más adelante, automáticamente hereda los permisos del viejo `RoleBinding` sin que nadie lo haya vuelto a otorgar explícitamente. Por eso conviene borrar los `RoleBinding`/`ClusterRoleBinding` asociados como parte de la limpieza al borrar un ServiceAccount, no asumir que quedan inertes.

</details>

---

## Limpieza

```bash
kubectl delete rolebinding app-sa-pod-reader --ignore-not-found
kubectl delete role pod-reader --ignore-not-found
kubectl config set-context --current --namespace=default
kubectl delete namespace ckad-4-7
```