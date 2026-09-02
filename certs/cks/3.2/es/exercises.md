# Ejercer precaución en el uso de Service Accounts (CKS 1.34 — Tema 3.2)

Todo Pod en Kubernetes se autentica contra el API server como una **ServiceAccount** (SA). Si no se hace nada, esa identidad es la SA `default` del namespace y —históricamente— su token se montaba en cada contenedor en `/var/run/secrets/kubernetes.io/serviceaccount/`. Un atacante que logre ejecución de código dentro de un Pod hereda de inmediato esa identidad y todos los permisos RBAC asociados a ella. Este módulo recorre el endurecimiento de la superficie de ataque de las ServiceAccounts: deshabilitar el montaje automático de tokens, entender los tokens acotados (proyectados) frente a los tokens legacy basados en Secret, y construir SAs de mínimo privilegio.

> **Fuentes de referencia**
> - CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
> - Configure Service Accounts for Pods — <https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/>
> - Managing Service Accounts — <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/>
> - Bound Service Account Tokens / TokenRequest — <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#bound-service-account-token-volume>
> - Using RBAC Authorization — <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>

Se asume un clúster con Kubernetes **1.34** y una shell con cluster-admin. Todos los comandos son ejecutables por copiar y pegar.

---

## Ejercicio 1 — Observar la ServiceAccount default y su montaje automático de token

**Objetivo:** demostrar que un Pod sin `serviceAccountName` explícito recibe la identidad de la SA `default` y un token montado, y luego leer el contenido de ese token.

1. Cree un namespace aislado para trabajar:

   ```bash
   kubectl create namespace sa-lab
   ```

   Esperado:

   ```
   namespace/sa-lab created
   ```

2. Confirme que la ServiceAccount `default` ya existe (Kubernetes crea una por namespace automáticamente):

   ```bash
   kubectl -n sa-lab get serviceaccount
   ```

   Esperado:

   ```
   NAME      SECRETS   AGE
   default   0         10s
   ```

   > Observe que la columna `SECRETS` muestra `0`. Desde Kubernetes 1.24 (`LegacyServiceAccountTokenNoAutoGeneration`), el control plane **ya no crea automáticamente un Secret con token de larga duración** para cada SA. Los tokens ahora se emiten bajo demanda como volúmenes proyectados de vida corta y acotados por audiencia.

3. Ejecute un Pod que **no** especifique una ServiceAccount:

   ```bash
   kubectl -n sa-lab run probe --image=nginx:stable --restart=Never
   kubectl -n sa-lab wait --for=condition=Ready pod/probe --timeout=60s
   ```

4. Inspeccione a qué SA quedó vinculado el Pod y si se inyectó un volumen de token:

   ```bash
   kubectl -n sa-lab get pod probe -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   kubectl -n sa-lab get pod probe \
     -o jsonpath='{range .spec.volumes[*]}{.name}{"\t"}{.projected.sources}{"\n"}{end}'
   ```

   Esperado (abreviado):

   ```
   default
   kube-api-access-xxxxx	[{"serviceAccountToken":{...}},{"configMap":{...}},{"downwardAPI":{...}}]
   ```

5. Desde dentro del contenedor, lea el token montado y el archivo de namespace:

   ```bash
   kubectl -n sa-lab exec probe -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
   echo
   kubectl -n sa-lab exec probe -- \
     head -c 60 /var/run/secrets/kubernetes.io/serviceaccount/token; echo
   ```

   Esperado:

   ```
   sa-lab
   eyJhbGciOiJSUzI1NiIsImtpZCI6Il...   (a truncated JWT)
   ```

6. Decodifique el payload del token (base64url del segmento intermedio del JWT) para ver sus claims:

   ```bash
   kubectl -n sa-lab exec probe -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Esperado (abreviado):

   ```json
   {
       "aud": ["https://kubernetes.default.svc.cluster.local"],
       "exp": 1770000000,
       "iat": 1769996400,
       "kubernetes.io": {
           "namespace": "sa-lab",
           "pod": { "name": "probe", "uid": "..." },
           "serviceaccount": { "name": "default", "uid": "..." }
       },
       "sub": "system:serviceaccount:sa-lab:default"
   }
   ```

> **Verificación de comprensión 1**
> 1. La columna `SECRETS` de la SA `default` mostraba `0`, y sin embargo el Pod recibió un token funcional. ¿De dónde salió ese token?
> 2. ¿Cuál es la cadena de identidad (el `sub` de RBAC) que este Pod presenta al API server?
> 3. Nombre dos claims del token decodificado que lo convierten en un token *acotado* (bound) en lugar de un token estático legacy, y explique por qué cada uno limita a un atacante.

---

## Ejercicio 2 — Deshabilitar el automontaje del token (a nivel SA vs a nivel Pod)

**Objetivo:** impedir que el token se monte en absoluto, y entender las reglas de precedencia entre la configuración de la ServiceAccount y la del Pod.

1. Establezca `automountServiceAccountToken: false` en la SA `default` para que los Pods de este namespace dejen de recibir un token por defecto:

   ```bash
   kubectl -n sa-lab patch serviceaccount default \
     -p '{"automountServiceAccountToken": false}'
   ```

   Esperado:

   ```
   serviceaccount/default patched
   ```

2. Lance un Pod nuevo (sin SA explícita) y compruebe si el volumen del token está presente:

   ```bash
   kubectl -n sa-lab run probe2 --image=nginx:stable --restart=Never
   kubectl -n sa-lab wait --for=condition=Ready pod/probe2 --timeout=60s
   kubectl -n sa-lab exec probe2 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "NO TOKEN MOUNTED"
   ```

   Esperado:

   ```
   ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount/': No such file or directory
   NO TOKEN MOUNTED
   ```

3. Ahora demuestre que **el override a nivel Pod gana**. Aplique un manifiesto donde la SA dice "sin automontaje" pero el Pod explícitamente vuelve a activarlo:

   ```yaml
   # probe3.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe3
     namespace: sa-lab
   spec:
     serviceAccountName: default          # SA has automount=false
     automountServiceAccountToken: true   # Pod-level override forces the mount
     containers:
       - name: app
         image: nginx:stable
   ```

   ```bash
   kubectl apply -f probe3.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/probe3 --timeout=60s
   kubectl -n sa-lab exec probe3 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

   Esperado:

   ```
   ca.crt  namespace  token
   ```

4. Demuestre el override inverso. Vuelva a habilitar el automontaje en la SA, pero haga que el Pod se desentienda:

   ```bash
   kubectl -n sa-lab patch serviceaccount default \
     -p '{"automountServiceAccountToken": true}'
   ```

   ```yaml
   # probe4.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe4
     namespace: sa-lab
   spec:
     serviceAccountName: default          # SA has automount=true
     automountServiceAccountToken: false  # Pod-level override suppresses the mount
     containers:
       - name: app
         image: nginx:stable
   ```

   ```bash
   kubectl apply -f probe4.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/probe4 --timeout=60s
   kubectl -n sa-lab exec probe4 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "NO TOKEN MOUNTED"
   ```

   Esperado:

   ```
   NO TOKEN MOUNTED
   ```

> **Verificación de comprensión 2**
> 1. Enuncie la regla de precedencia entre `ServiceAccount.automountServiceAccountToken` y `Pod.spec.automountServiceAccountToken`.
> 2. Una carga de trabajo realmente necesita hablar con el API server. ¿Cuál es la postura de endurecimiento más defendible: poner `automountServiceAccountToken: false` en la *SA* y volver a habilitarlo solo en los Pods que lo necesitan, o ponerlo en `true` en la SA y deshabilitarlo Pod por Pod? Justifique su respuesta en términos de valores por defecto a prueba de fallos.
> 3. Deshabilitar el automontaje elimina el archivo del token dentro del Pod. ¿Eso revoca los permisos RBAC de la ServiceAccount? ¿Por qué sí o por qué no?

---

## Ejercicio 3 — Crear una ServiceAccount dedicada de mínimo privilegio

**Objetivo:** reemplazar la SA `default` compartida por una SA construida a propósito, con exactamente un permiso acotado, y vincularla con un Role namespaced.

1. Cree una SA dedicada para una aplicación hipotética que solo necesita *leer* Pods en su propio namespace. Incorpore desde el inicio el valor por defecto seguro de no automontar:

   ```yaml
   # app-sa.yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: pod-reader-sa
     namespace: sa-lab
   automountServiceAccountToken: false
   ```

   ```bash
   kubectl apply -f app-sa.yaml
   ```

2. Defina un `Role` namespaced que otorgue únicamente `get`, `list`, `watch` sobre `pods` — nada más:

   ```yaml
   # pod-reader-role.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: sa-lab
   rules:
     - apiGroups: [""]           # core API group
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

3. Vincule el Role a la SA con un `RoleBinding`:

   ```yaml
   # pod-reader-binding.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-reader-binding
     namespace: sa-lab
   subjects:
     - kind: ServiceAccount
       name: pod-reader-sa
       namespace: sa-lab
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f pod-reader-binding.yaml
   ```

4. Verifique los permisos efectivos con `kubectl auth can-i` **suplantando la SA** (el flag `--as` usa la forma `system:serviceaccount:<ns>:<name>`). Confirme tanto el caso permitido como los denegados:

   ```bash
   kubectl -n sa-lab auth can-i list pods \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl -n sa-lab auth can-i delete pods \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl -n sa-lab auth can-i get secrets \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Esperado:

   ```
   yes
   no
   no
   ```

5. Ejecute un Pod que use la nueva SA y active explícitamente el montaje del token (dado que la SA por defecto no automonta), para que pueda realmente llamar a la API:

   ```yaml
   # reader-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: reader
     namespace: sa-lab
   spec:
     serviceAccountName: pod-reader-sa
     automountServiceAccountToken: true
     containers:
       - name: kubectl
         image: bitnami/kubectl:1.34
         command: ["sleep", "3600"]
   ```

   ```bash
   kubectl apply -f reader-pod.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/reader --timeout=90s
   ```

6. Desde *dentro* del Pod, ejercite el token acotado real contra el API server — la llamada permitida tiene éxito, la prohibida devuelve `403`:

   ```bash
   kubectl -n sa-lab exec reader -- kubectl get pods
   echo "---"
   kubectl -n sa-lab exec reader -- kubectl get secrets 2>&1 || true
   ```

   Esperado (abreviado):

   ```
   NAME     READY   STATUS    ...
   reader   1/1     Running   ...
   probe    1/1     Running   ...
   ---
   Error from server (Forbidden): secrets is forbidden: User
   "system:serviceaccount:sa-lab:pod-reader-sa" cannot list resource
   "secrets" in API group "" in the namespace "sa-lab"
   ```

> **Verificación de comprensión 3**
> 1. ¿Por qué `kubectl auth can-i ... --as=system:serviceaccount:sa-lab:pod-reader-sa` es un método de verificación mejor que leer el YAML del Role a ojo?
> 2. El Role de arriba usa `apiGroups: [""]`. ¿Qué denota la cadena vacía, y qué pasaría con la regla de `pods` si escribiera `apiGroups: ["v1"]` en su lugar?
> 3. Esta SA puede leer Pods solo en `sa-lab`. ¿Qué único cambio en los objetos RBAC ampliaría (incorrectamente) eso a *todos* los namespaces, y por qué es un error frecuente de mínimo privilegio?

---

## Ejercicio 4 — Emitir y entender tokens acotados con la API TokenRequest

**Objetivo:** acuñar bajo demanda un token de vida corta y acotado por audiencia con `kubectl create token`, contrastarlo con un token legacy basado en Secret, y entender por qué los tokens acotados son la primitiva más segura.

1. Solicite un token acotado para la SA con una vigencia de 15 minutos, restringido a una audiencia específica:

   ```bash
   kubectl -n sa-lab create token pod-reader-sa \
     --duration=15m \
     --audience=vault.internal \
     --output=json | python3 -c \
     'import sys,json; d=json.load(sys.stdin); print(d["status"]["expirationTimestamp"])'
   ```

   Esperado (una marca de tiempo ~15 minutos en el futuro):

   ```
   2026-07-30T12:15:00Z
   ```

2. Acuñe un token y decodifique sus claims para confirmar que el emisor impone la audiencia y la expiración:

   ```bash
   TOKEN=$(kubectl -n sa-lab create token pod-reader-sa --duration=15m --audience=vault.internal)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Esperado (abreviado):

   ```json
   {
       "aud": ["vault.internal"],
       "exp": 1769998200,
       "iat": 1769997300,
       "sub": "system:serviceaccount:sa-lab:pod-reader-sa"
   }
   ```

3. Contraste con un token **legacy** de larga duración. Todavía se puede forzar uno creando un Secret de tipo `kubernetes.io/service-account-token`. Haga esto para *entender el riesgo*, no como patrón recomendado:

   ```yaml
   # legacy-token.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: pod-reader-legacy-token
     namespace: sa-lab
     annotations:
       kubernetes.io/service-account.name: pod-reader-sa
   type: kubernetes.io/service-account-token
   ```

   ```bash
   kubectl apply -f legacy-token.yaml
   kubectl -n sa-lab get secret pod-reader-legacy-token \
     -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Esperado (abreviado) — note la **ausencia** de un claim `exp`:

   ```json
   {
       "iss": "https://kubernetes.default.svc.cluster.local",
       "kubernetes.io/serviceaccount/namespace": "sa-lab",
       "kubernetes.io/serviceaccount/service-account.name": "pod-reader-sa",
       "sub": "system:serviceaccount:sa-lab:pod-reader-sa"
   }
   ```

4. Confirme que el control plane registra el uso de tokens legacy para poder encontrar los obsoletos. Después de que el token se usa al menos una vez, el Secret de token de SA recibe una etiqueta `kubernetes.io/legacy-token-last-used` en un objeto de seguimiento; de forma más directa, audite estos Secrets a nivel de todo el clúster:

   ```bash
   kubectl get secrets --all-namespaces \
     --field-selector type=kubernetes.io/service-account-token
   ```

   Esperado:

   ```
   NAMESPACE   NAME                       TYPE                                  DATA   AGE
   sa-lab      pod-reader-legacy-token    kubernetes.io/service-account-token   3      1m
   ```

5. Elimine el token legacy de inmediato — es exactamente el tipo de credencial persistente que conviene erradicar:

   ```bash
   kubectl -n sa-lab delete secret pod-reader-legacy-token
   ```

> **Verificación de comprensión 4**
> 1. Nombre tres propiedades de una credencial de `kubectl create token` (TokenRequest) que un token legacy basado en Secret no tiene.
> 2. El token acotado del paso 2 tiene `"aud": ["vault.internal"]`. Si un Pod presenta ese token al *kube-apiserver* (audiencia por defecto `https://kubernetes.default.svc...`), ¿qué ocurre, y por qué la vinculación de audiencia es una defensa contra el replay de tokens?
> 3. Los tokens legacy basados en Secret no tienen `exp`. ¿Qué problemas operativos y de seguridad genera eso, y cuál es el reemplazo moderno para el flujo que solía depender de ellos (por ejemplo, un sistema de CI externo autenticándose contra el clúster)?

---

## Ejercicio 5 — Auditar el clúster en busca de vinculaciones de ServiceAccount sobreprivilegiadas y peligrosas

**Objetivo:** encontrar las SAs que un escenario de CKS marcaría: las vinculadas a `cluster-admin`, las que montan tokens que no necesitan, y la SA `default` cargando permisos reales.

1. Liste cada ClusterRoleBinding cuyos subjects incluyan una ServiceAccount, y saque a la luz cualquiera vinculada a `cluster-admin`:

   ```bash
   kubectl get clusterrolebindings -o json \
   | python3 - <<'PY'
   import json, subprocess
   data = json.loads(subprocess.check_output(
       ["kubectl", "get", "clusterrolebindings", "-o", "json"]))
   for crb in data["items"]:
       role = crb.get("roleRef", {}).get("name")
       for s in crb.get("subjects") or []:
           if s.get("kind") == "ServiceAccount":
               marker = "  <-- REVIEW" if role in ("cluster-admin", "admin", "edit") else ""
               print(f'{crb["metadata"]["name"]:40} role={role:20} '
                     f'sa={s.get("namespace")}/{s["name"]}{marker}')
   PY
   ```

   Esperado (ilustrativo):

   ```
   system:kube-scheduler                   role=system:kube-scheduler sa=kube-system/kube-scheduler
   dangerous-binding                       role=cluster-admin        sa=sa-lab/pod-reader-sa  <-- REVIEW
   ```

2. Reproduzca el hallazgo marcado para practicar su remediación. Otorgue `cluster-admin` a la SA (el antipatrón), verifique y luego revoque:

   ```bash
   kubectl create clusterrolebinding dangerous-binding \
     --clusterrole=cluster-admin \
     --serviceaccount=sa-lab:pod-reader-sa
   ```

   ```bash
   kubectl auth can-i '*' '*' --all-namespaces \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Esperado:

   ```
   yes
   ```

3. Remedie eliminando la vinculación excesivamente amplia (dejando intacto el Role namespaced acotado del Ejercicio 3):

   ```bash
   kubectl delete clusterrolebinding dangerous-binding
   kubectl auth can-i '*' '*' --all-namespaces \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Esperado:

   ```
   no
   ```

4. Endurezca la SA `default` en **todos** los namespaces para que un Pod olvidado nunca reciba silenciosamente un token. Este one-liner parchea todas las SAs `default`:

   ```bash
   for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
     kubectl -n "$ns" patch serviceaccount default \
       -p '{"automountServiceAccountToken": false}' 2>/dev/null \
       && echo "patched default SA in $ns"
   done
   ```

   Esperado (ilustrativo):

   ```
   patched default SA in default
   patched default SA in sa-lab
   patched default SA in kube-node-lease
   ...
   ```

5. Verifique de punta a punta los permisos reales de una SA concreta listando lo que puede hacer — la forma `--list` enumera cada verbo/recurso permitido:

   ```bash
   kubectl -n sa-lab auth can-i --list \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Esperado (abreviado):

   ```
   Resources   Non-Resource URLs   Resource Names   Verbs
   pods        []                  []               [get list watch]
   ...
   ```

6. Desmonte el laboratorio:

   ```bash
   kubectl delete namespace sa-lab
   ```

> **Verificación de comprensión 5**
> 1. Vincular una ServiceAccount a `cluster-admin` es peligroso incluso si el Pod "parece confiable". Describa el radio de impacto concreto si ese Pod es comprometido.
> 2. ¿Por qué parchear la ServiceAccount `default` a `automountServiceAccountToken: false` es un control de base sólido, y cuál es el único riesgo operativo que debe verificar antes de desplegarlo a toda la flota?
> 3. `kubectl auth can-i --list --as=...` es una primitiva de auditoría potente. ¿Por qué puede aun así *subestimar* el poder real de una SA en un clúster que además ejecuta una capa de admission o de API agregada?

---

## Respuestas

<details>
<summary>Clic para revelar las respuestas de todas las verificaciones de comprensión</summary>

### Verificación de comprensión 1
1. **El token fue emitido bajo demanda por la API TokenRequest como un volumen proyectado.** Desde Kubernetes 1.24, las SAs ya no reciben un Secret autogenerado (de ahí `SECRETS: 0`). En su lugar, el volumen proyectado `kube-api-access-xxxxx` que inyecta el admission controller contiene una fuente `serviceAccountToken`; el kubelet solicita al API server un token fresco, de vida corta y acotado por audiencia, y lo renueva antes de que expire. El `ca.crt` y el `namespace` provienen de un ConfigMap y de la downward API dentro del mismo volumen proyectado.
2. `system:serviceaccount:sa-lab:default` — el valor del claim `sub`, y la identidad que RBAC evalúa. La forma general es `system:serviceaccount:<namespace>:<name>`, y toda SA es además miembro de los grupos `system:serviceaccounts` y `system:serviceaccounts:<namespace>`.
3. Dos cualesquiera de: **`exp`** — el token expira (vigencia acotada), de modo que un token robado solo sirve durante una ventana corta y no para siempre; **`aud`** (audiencia) — el token solo es válido para la o las audiencias listadas, así que no puede reproducirse contra otro servicio que verifique la audiencia; **`kubernetes.io.pod`** (la referencia al objeto vinculado) — el token está atado al UID del Pod y se invalida cuando el Pod se elimina, por lo que no puede sobrevivir a la carga de trabajo. Los tokens legacy no tienen ninguna de estas vinculaciones.

### Verificación de comprensión 2
1. **El `spec.automountServiceAccountToken` a nivel Pod siempre gana cuando está definido.** Si el campo está presente en el Pod, su valor prevalece sobre el de la ServiceAccount; si el Pod no lo define, aplica el valor de la ServiceAccount; si ninguno lo define, el valor por defecto es `true` (se monta).
2. **Poner `false` en la SA y volver a habilitarlo solo donde haga falta.** Esa es la postura *a prueba de fallos / segura por defecto*: un Pod recién creado u olvidado hereda "sin token", de modo que un error falla *cerrado* (sin credencial expuesta) en lugar de *abierto*. Exigir un `automountServiceAccountToken: true` explícito en las cargas de trabajo que legítimamente llaman al API server hace que la dependencia de la API sea visible y auditable.
3. **No — no revoca RBAC.** `automountServiceAccountToken` solo controla si un token se *monta en el sistema de archivos del Pod*. La identidad de la ServiceAccount y cada Role/ClusterRole vinculado a ella siguen existiendo. Un proceso que obtenga un token por otra vía (por ejemplo, mediante la API TokenRequest, o un token pasado deliberadamente) seguiría ejerciendo esos permisos. No montar el token reduce la exposición; minimizar RBAC es lo que realmente limita la autoridad.

### Verificación de comprensión 3
1. `kubectl auth can-i --as=...` le pregunta al **autorizador en vivo** (RBAC más cualquier otro módulo de autorización habilitado), de modo que refleja la decisión *efectiva* tras combinar cada Role, ClusterRole, RoleBinding, ClusterRoleBinding y pertenencia a grupos que aplique a esa SA. Leer un único YAML de Role pasa por alto vinculaciones aditivas (otro RoleBinding podría otorgar más), la agregación y las concesiones a nivel de grupo — así que mirar el YAML a ojo rutinariamente sub o sobreestima el acceso real.
2. La cadena vacía `""` denota el **grupo de API core (legacy)**, que contiene `pods`, `services`, `secrets`, `configmaps`, `nodes`, etc. `apiGroups` espera un *nombre de grupo de API*, no una versión. Escribir `apiGroups: ["v1"]` coincide con un grupo literalmente llamado `v1` (que no existe para `pods`), así que la regla **no otorgaría nada** para pods y las lecturas de pods de la SA serían denegadas.
3. **Cambiar el `RoleBinding` por un `ClusterRoleBinding` (y el `Role` por un `ClusterRole`)** otorgaría lectura de pods en *todos* los namespaces. Es un error frecuente porque los operadores recurren a `ClusterRole`/`ClusterRoleBinding` por comodidad o copian un ejemplo, sin darse cuenta de que un `ClusterRoleBinding` concede los verbos del role a nivel de todo el clúster, sin importar el namespace. (El alcance namespaced requiere un `RoleBinding` — incluso cuando referencia un `ClusterRole`, la vinculación confina la concesión a su propio namespace.)

### Verificación de comprensión 4
1. Tres cualesquiera de: **vigencia acotada** (`exp` — expira y se rota automáticamente), **acotamiento por audiencia** (`aud` — solo válido para el destinatario previsto), **vinculación a objeto** (puede atarse al UID de un Pod/Secret e invalidarse cuando ese objeto se elimina), **no almacenado en reposo** (nunca se persiste como Secret en etcd; se acuña bajo demanda). Un token legacy basado en Secret es una credencial estática, sin expiración, sin acotamiento, almacenada en etcd.
2. **El API server lo rechaza con `401 Unauthorized`.** El kube-apiserver solo acepta tokens cuya audiencia incluya la audiencia propia del API server; un token acuñado para `vault.internal` no es válido para el API server. La vinculación de audiencia derrota el replay: un token capturado por (o filtrado a) un servicio no puede darse vuelta y usarse contra otro servicio distinto, porque cada verificador comprueba que su propio identificador esté en `aud`.
3. **Sin `exp` el token nunca expira** — sigue siendo válido hasta que se elimine la SA o el Secret, así que un token legacy filtrado es una puerta trasera permanente, la rotación exige eliminar y recrear el Secret a mano, y las credenciales obsoletas se acumulan de forma invisible. El reemplazo moderno es la **API TokenRequest** (`kubectl create token`, o volúmenes `serviceAccountToken` proyectados) para cargas de trabajo dentro del clúster, y tokens de vida corta obtenidos bajo demanda (con `--audience`/`--duration`) para sistemas externos — idealmente intercambiados mediante un flujo de federación de identidad/OIDC en lugar de un token estático almacenado.

### Verificación de comprensión 5
1. `cluster-admin` otorga verbos `*` sobre recursos `*` en `*` namespaces, incluidos los `secrets` (todas las credenciales), la capacidad de crear Pods en cualquier nodo, modificar RBAC para persistir el acceso, leer/alterar cada carga de trabajo y hacer exec en cualquier Pod. Un único contenedor comprometido se convierte por lo tanto en **toma total del clúster** — el atacante puede volcar todos los Secrets, desplegar Pods privilegiados/con hostPath para escapar hacia los nodos, deshabilitar el logging y establecer persistencia. El radio de impacto es el clúster entero y cada carga de trabajo/tenant que corre en él.
2. Impone un **valor por defecto seguro**: cualquier Pod que olvide declarar su dependencia de la API simplemente nunca recibe un token, de modo que la exposición accidental de credenciales falla cerrado y la superficie de acceso a la API se reduce a las cargas de trabajo que explícitamente lo piden. El riesgo operativo a verificar primero: **cargas de trabajo existentes que dependen silenciosamente del token de la SA `default`** (sidecars, operators, controllers, `kubectl` dentro del Pod, agentes de service mesh) se romperán cuando el montaje desaparezca — así que audite los Pods que usan `default` y agregue una SA explícita más `automountServiceAccountToken: true` a los que realmente lo necesitan antes de accionar el interruptor.
3. `auth can-i --list` refleja solo la decisión de **autorización** para recursos estándar evaluados por RBAC. Puede subestimar el poder real porque: la autoridad puede ejercerse de forma **indirecta** (por ejemplo, el permiso de crear un Pod/Deployment le permite a la SA ejecutar un contenedor con una SA *distinta y más privilegiada* — escalada de privilegios mediante creación de cargas de trabajo); los **API servers agregados** y los **autorizadores personalizados/por webhook** pueden conceder accesos que el listado de RBAC no enumera; y permisos como `escalate`/`bind`, `impersonate`, o acceso de escritura a configuraciones de admission/webhook le permiten a la SA expandir sus propios derechos. El poder efectivo tiene que ver con lo que la identidad puede *alcanzar o llegar a ser*, no solo con los verbos que RBAC lista directamente.

</details>