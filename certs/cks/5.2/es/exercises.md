# Ejercicios — Tema 5.2: Uso de Gestión de Identidad y Acceso con Mínimo Privilegio

> **Contexto del dominio (CKS v1.34, peso de examen 2.5).** Estos labs guiados construyen la memoria muscular práctica que el examen espera en torno a identidad y autorización: enumerar quién puede hacer qué, construir permisos mínimos con `Role`/`ClusterRole`, endurecer la exposición de tokens de `ServiceAccount`, y detectar las construcciones RBAC que entregan cluster-admin de forma silenciosa. Cada paso es ejecutable; se muestra la salida esperada para que puedas confirmar que vas bien encaminado antes de responder las preguntas de control.
>
> **Prerrequisitos**
> - Un clúster donde seas `cluster-admin` (un `kind` descartable, `minikube`, o el kubeconfig de admin de un clúster real). Kubernetes **v1.30+** para que `kubectl create token`, los tokens proyectados acotados (bound) y `auth can-i --list` se comporten como está documentado.
> - `kubectl` con la misma versión menor que el servidor.
> - Opcional pero recomendado: [`kubectl-who-can`](https://github.com/aquasecurity/kubectl-who-can), [`rakkess`](https://github.com/corneliusweig/rakkess), [`rbac-lookup`](https://github.com/FairwindsOps/rbac-lookup) como plugins de `kubectl`.
>
> **Material de referencia (oficial)**
> - RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
> - Panorama de autorización y `can-i`: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
> - ServiceAccounts (admin): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
> - Configurar un ServiceAccount para un Pod: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
> - Buenas prácticas de RBAC: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
> - Currículum CKS: https://github.com/cncf/curriculum

Creá un namespace de trabajo que usarán varios ejercicios:

```bash
kubectl create namespace dev
```

---

## Ejercicio 1 — Enumerar la superficie de autorización actual

El mínimo privilegio empieza por *medir* el privilegio. Antes de escribir un solo `Role`, aprendé a interrogar al autorizador directamente en lugar de leer YAML y adivinar.

**Pasos**

1. Confirmá qué podés hacer *vos* (el admin) — una verificación rápida de que RBAC es el autorizador activo:

   ```bash
   kubectl auth can-i '*' '*' --all-namespaces
   ```
   Esperado:
   ```
   yes
   ```

2. Hacé una pregunta *acotada* — ¿podés borrar Pods en `dev`?

   ```bash
   kubectl auth can-i delete pods -n dev
   ```
   Esperado:
   ```
   yes
   ```

3. Ahora suplantá un sujeto que todavía no existe y enumerá sus permisos *efectivos*. El flag `--as` hace que el API server evalúe la petición como ese sujeto; `can-i --list` imprime la matriz resuelta completa:

   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:dev:builder -n dev
   ```
   Esperado (una SA recién creada sin bindings igual hereda las reglas base de `system:discovery`/self-review):
   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                   [/api/*]            []               [get]
                                                   [/api]              []               [get]
                                                   ...
   ```

4. Hacé una pregunta puntual como esa misma SA — ¿puede leer Secrets en `dev`?

   ```bash
   kubectl auth can-i get secrets -n dev \
     --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   no
   ```

5. Usá una consulta al estilo `resourceNames` en la propia pregunta — ¿puede la SA hacer `get` sobre un Secret específico por nombre?

   ```bash
   kubectl auth can-i get secrets/db-password -n dev \
     --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   no
   ```

**Preguntas de control**

- **P1.** ¿Cuál es la diferencia práctica entre `kubectl auth can-i get secrets -n dev` y `kubectl auth can-i --list -n dev`, y por qué `--list` es la primitiva de auditoría más valiosa?
- **P2.** En el paso 3 la SA *no* tenía ningún `RoleBinding` y aun así `can-i --list` devolvió varias reglas permitidas. ¿De dónde vienen esos permisos base, y su existencia viola el mínimo privilegio?
- **P3.** ¿Qué verbo RBAC necesitaría un sujeto para *suplantar* a otro usuario o ServiceAccount como hace `--as` acá, y por qué otorgarlo es tan peligroso?

---

## Ejercicio 2 — Construir un Role de mínimo privilegio desde cero

La habilidad central: expresar exactamente el acceso que una aplicación necesita — sin comodines, sin verbos de más — y demostrarlo con el autorizador.

**Pasos**

1. Supongamos que la carga de trabajo `builder` debe **leer y observar (watch) ConfigMaps** en `dev` y **crear Events** — nada más. Escribí un `Role` con ámbito de namespace (objeto namespaced → `Role`, no `ClusterRole`):

   ```yaml
   # role-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: builder
     namespace: dev
   rules:
     - apiGroups: [""]              # core API group
       resources: ["configmaps"]
       verbs: ["get", "list", "watch"]
     - apiGroups: [""]
       resources: ["events"]
       verbs: ["create"]
   ```

2. Vinculalo al ServiceAccount `builder` con un `RoleBinding` (el permiso queda confinado al namespace `dev`):

   ```yaml
   # rolebinding-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: builder
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: builder
     apiGroup: rbac.authorization.k8s.io
   ```

3. Creá la SA y aplicá todo:

   ```bash
   kubectl create serviceaccount builder -n dev
   kubectl apply -f role-builder.yaml -f rolebinding-builder.yaml
   ```
   Esperado:
   ```
   serviceaccount/builder created
   role.rbac.authorization.k8s.io/builder created
   rolebinding.rbac.authorization.k8s.io/builder created
   ```

4. Demostrá que el permiso es exactamente el que pretendías — permitido:

   ```bash
   kubectl auth can-i watch configmaps -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i create events   -n dev --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   yes
   yes
   ```

5. Demostrá el *espacio negativo* — la denegación por defecto se sostiene para todo lo que no otorgaste, incluidos verbos vecinos y acceso entre namespaces:

   ```bash
   kubectl auth can-i delete configmaps -n dev     --as=system:serviceaccount:dev:builder
   kubectl auth can-i get configmaps    -n default --as=system:serviceaccount:dev:builder
   kubectl auth can-i list secrets      -n dev     --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   no
   no
   no
   ```

**Preguntas de control**

- **P4.** El Role `builder` otorga `create` sobre Events pero no `get`/`list`. Si la aplicación solo *emite* Events y nunca los vuelve a leer, ¿es esto mínimo privilegio correcto, o un error?
- **P5.** El paso 5 muestra que `get configmaps -n default` está denegado aunque el Role permite `get configmaps`. Explicá con precisión por qué importa el namespace acá y cómo una combinación de `ClusterRole` + `RoleBinding` cambiaría (o no) ese resultado.
- **P6.** Necesitás otorgar acceso de lectura a un recurso del grupo de API `apps` (por ejemplo, `deployments`). ¿Qué debe cambiar en el bloque `rules`, y qué pasa si dejás `apiGroups: [""]`?

---

## Ejercicio 3 — Dejar de montar tokens que las cargas de trabajo nunca usan

Cada Pod que monta un token de ServiceAccount entrega una credencial bearer a cualquier proceso (o atacante) dentro de ese contenedor. Si la carga de trabajo no habla con el API server, ese token es pura superficie de ataque.

**Pasos**

1. Observá el comportamiento por defecto. Ejecutá un Pod descartable bajo la SA *default* y verificá si se inyectó un token:

   ```bash
   kubectl run probe --image=busybox -n dev --restart=Never -- sleep 3600
   kubectl exec probe -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
   Esperado:
   ```
   ca.crt
   namespace
   token
   ```

2. Deshabilitá el automontaje **a nivel de ServiceAccount** para que todo Pod que la use tenga por defecto *ningún* token:

   ```bash
   kubectl patch serviceaccount builder -n dev \
     -p '{"automountServiceAccountToken": false}'
   ```
   Esperado:
   ```
   serviceaccount/builder patched
   ```

3. Ejecutá un Pod bajo `builder` y confirmá que el directorio del token desapareció:

   ```bash
   kubectl run probe2 --image=busybox -n dev --restart=Never \
     --overrides='{"spec":{"serviceAccountName":"builder"}}' -- sleep 3600
   kubectl exec probe2 -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```
   Esperado:
   ```
   ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   command terminated with exit code 1
   ```

4. Aprendé la regla de **precedencia**. La spec del Pod puede sobrescribir a la SA en ambas direcciones. Acá un Pod *reactiva* el montaje aunque la SA lo haya deshabilitado:

   ```yaml
   # pod-explicit-mount.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: needs-api
     namespace: dev
   spec:
     serviceAccountName: builder
     automountServiceAccountToken: true   # Pod-level wins over SA-level
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
   ```
   ```bash
   kubectl apply -f pod-explicit-mount.yaml
   kubectl exec needs-api -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
   Esperado:
   ```
   ca.crt
   namespace
   token
   ```

**Preguntas de control**

- **P7.** Enunciá la regla de precedencia entre `automountServiceAccountToken` en el ServiceAccount y en el Pod. ¿Cuál gana, y cuál es la *postura por defecto* recomendada para un clúster endurecido?
- **P8.** Una carga de trabajo tiene `automountServiceAccountToken: false` pero realmente necesita llamar a la API para un propósito acotado. ¿Cuál es la forma de mínimo privilegio de darle un token sin reactivar el automontaje amplio?
- **P9.** ¿Por qué dejar el token montado en un Pod que nunca contacta al API server es un problema real de seguridad y no solo una cuestión de prolijidad? Nombrá la escalada concreta que gana un atacante.

---

## Ejercicio 4 — Tokens acotados y de vida corta vs. Secrets estáticos heredados

Desde v1.24 Kubernetes ya no autogenera un Secret sin expiración por cada ServiceAccount. Los tokens inyectados ahora son **proyectados, acotados por audiencia, limitados en el tiempo y ligados al Pod**, y el kubelet los rota. Este ejercicio hace eso concreto y lo contrasta con el token estático heredado que deberías evitar acuñar.

**Pasos**

1. Acuñá un token acotado bajo demanda con la API TokenRequest e inspeccioná sus claims:

   ```bash
   TOKEN=$(kubectl create token builder -n dev --duration=15m)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```
   Esperado (abreviado):
   ```json
   {
     "aud": ["https://kubernetes.default.svc.cluster.local"],
     "exp": 1754320500,
     "iat": 1754319600,
     "kubernetes.io": {
       "namespace": "dev",
       "serviceaccount": {
         "name": "builder",
         "uid": "9c1f...":
       }
     },
     "sub": "system:serviceaccount:dev:builder"
   }
   ```

2. Observá el token proyectado dentro de un Pod. Inspeccioná el volumen que inyecta el kubelet — un volumen `projected` con una fuente `serviceAccountToken`, **no** un Secret:

   ```bash
   kubectl get pod needs-api -n dev -o jsonpath='{.spec.volumes[*].projected.sources}' | jq .
   ```
   Esperado:
   ```json
   [
     { "serviceAccountToken": { "expirationSeconds": 3607, "path": "token" } },
     { "configMap": { "items": [{"key":"ca.crt","path":"ca.crt"}], "name": "kube-root-ca.crt" } },
     { "downwardAPI": { "items": [{"path":"namespace","fieldRef":{"fieldPath":"metadata.namespace"}}] } }
   ]
   ```

3. Elaborá un token con una **audiencia personalizada y expiración ajustada** — así se acota un token a un consumidor específico (por ejemplo, un sidecar compatible con OIDC o un webhook de admisión) en lugar del API server:

   ```yaml
   # pod-projected-token.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: vault-agent
     namespace: dev
   spec:
     serviceAccountName: builder
     automountServiceAccountToken: false   # suppress the default API-server token
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
         volumeMounts:
           - name: vault-token
             mountPath: /var/run/secrets/vault
             readOnly: true
     volumes:
       - name: vault-token
         projected:
           sources:
             - serviceAccountToken:
                 audience: vault
                 expirationSeconds: 600      # 10 min, kubelet rotates before expiry
                 path: vault-token
   ```
   ```bash
   kubectl apply -f pod-projected-token.yaml
   kubectl exec vault-agent -n dev -- \
     sh -c 'cut -d. -f2 /var/run/secrets/vault/vault-token | base64 -d 2>/dev/null' | jq .aud
   ```
   Esperado:
   ```json
   ["vault"]
   ```

4. Mirá cómo se ve el **token estático heredado** (el antipatrón), para reconocerlo en una auditoría. Este Secret nunca expira y no está ligado a ningún Pod:

   ```yaml
   # legacy-token.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: builder-legacy-token
     namespace: dev
     annotations:
       kubernetes.io/service-account.name: builder
   type: kubernetes.io/service-account-token
   ```
   ```bash
   kubectl apply -f legacy-token.yaml
   kubectl get secret builder-legacy-token -n dev -o jsonpath='{.data.token}' \
     | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | jq 'has("exp")'
   ```
   Esperado:
   ```
   false
   ```
   (Limpiá el antipatrón de inmediato: `kubectl delete secret builder-legacy-token -n dev`.)

**Preguntas de control**

- **P10.** Enumerá las cuatro propiedades independientes que tiene un token proyectado acotado moderno y que le faltan al Secret con token estático heredado del paso 4. ¿Por qué cada una reduce el radio de impacto?
- **P11.** El token del paso 1 tiene `"aud": ["https://kubernetes.default.svc..."]` mientras que el del paso 3 tiene `"aud": ["vault"]`. Si presentaras el token con audiencia `vault` al API server de Kubernetes, ¿qué pasa, y por qué la vinculación por audiencia es un control de defensa en profundidad?
- **P12.** Un pentester encuentra un token filtrado cuyo `exp` está a 8 minutos. Comparado con un token estático heredado filtrado, ¿cómo cambia el token acotado la respuesta a incidentes, y qué único campo de la fuente proyectada controla esa ventana?

---

## Ejercicio 5 — Cazar permisos demasiado amplios y peligrosos

El mínimo privilegio es también una disciplina de *detección*. Este ejercicio siembra dos configuraciones erróneas clásicas y luego las encuentra como lo haría un auditor.

**Pasos**

1. Sembrá un permiso con comodín (el Role "que simplemente funciona" y es dueño del namespace):

   ```yaml
   # bad-wildcard.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: bad-wildcard
     namespace: dev
   rules:
     - apiGroups: ["*"]
       resources: ["*"]
       verbs: ["*"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: bad-wildcard
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: bad-wildcard
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f bad-wildcard.yaml
   ```

2. Sembrá un permiso sutil de escalada de privilegios usando los verbos `escalate` y `bind` sobre objetos RBAC:

   ```yaml
   # bad-escalate.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: bad-escalate
   rules:
     - apiGroups: ["rbac.authorization.k8s.io"]
       resources: ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]
       verbs: ["create", "escalate", "bind"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: bad-escalate
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: ClusterRole
     name: bad-escalate
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f bad-escalate.yaml
   ```

3. Detectá verbos comodín rápidamente con un barrido JSONPath sobre todos los Roles/ClusterRoles:

   ```bash
   kubectl get roles,clusterroles -A -o json \
     | jq -r '.items[]
        | select(.rules[]? | (.verbs[]? == "*") or (.resources[]? == "*"))
        | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)"' \
     | sort -u
   ```
   Esperado (tu Role sembrado más algunos roles de sistema legítimos):
   ```
   ClusterRole/-/cluster-admin
   Role/dev/bad-wildcard
   ...
   ```

4. Encontrá *quién puede hacer la cosa peligrosa* en vez de *quién tiene un rol*. Con `kubectl-who-can`:

   ```bash
   kubectl who-can create pods -n dev
   ```
   Esperado (abreviado):
   ```
   ROLEBINDING       NAMESPACE  SUBJECT   TYPE            SA-NAMESPACE
   bad-wildcard      dev        builder   ServiceAccount  dev
   ```

5. Enumerá todos los sujetos vinculados a `cluster-admin` (el permiso que debe justificarse para cada uno de sus poseedores):

   ```bash
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[]
        | select(.roleRef.name=="cluster-admin")
        | .metadata.name as $b | (.subjects[]? | "\($b)\t\(.kind)\t\(.namespace // "-")/\(.name)")'
   ```
   Esperado:
   ```
   cluster-admin   Group   -/system:masters
   ```

6. Confirmá que el permiso de escalada es real usando el autorizador:

   ```bash
   kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:dev:builder
   kubectl auth can-i escalate clusterroles     --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   yes
   yes
   ```

**Preguntas de control**

- **P13.** Explicá qué evita realmente el verbo `escalate`. Normalmente, ¿por qué un usuario *no puede* crear un Role más poderoso que sus propios permisos, y cómo derrota `escalate` esa salvaguarda?
- **P14.** ¿Qué permite el verbo `bind` que `create` sobre `rolebindings` por sí solo no permite? Describí el ataque que combina `create rolebindings` + `bind` para llegar a `cluster-admin`.
- **P15.** En el paso 5 el único sujeto de `cluster-admin` es el grupo `system:masters`. ¿Por qué *no* podés remediar un miembro sobreprivilegiado de `system:masters` editando RBAC, y de dónde proviene realmente ese binding?

---

## Ejercicio 6 — Convertir permisos RBAC en una cadena concreta de escalada de privilegios (y cerrarla)

Algunos verbos parecen inofensivos sobre el papel pero en la práctica equivalen a cluster-admin. Acá vas a *ejecutar* dos escaladas de manual como la SA de bajo privilegio, y después remediarlas.

**Pasos**

1. Reiniciá `builder` con un permiso realista pero peligroso: `create` sobre Pods y `get`/`list` sobre Secrets en `dev`. Primero eliminá las siembras de comodín/escalada del Ejercicio 5 para que la cadena quede sin ambigüedades:

   ```bash
   kubectl delete -f bad-wildcard.yaml -f bad-escalate.yaml
   ```
   ```yaml
   # risky-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: risky-builder
     namespace: dev
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["create", "get", "list"]
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "list"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: risky-builder
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: risky-builder
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f risky-builder.yaml
   ```

2. Creá una SA privilegiada cuyo token el atacante quiere robar (simulando un controlador poderoso en `dev`):

   ```bash
   kubectl create serviceaccount powerful -n dev
   kubectl create clusterrolebinding powerful-admin \
     --clusterrole=cluster-admin \
     --serviceaccount=dev:powerful
   ```

3. **Escalada A — ejecutar un Pod como la SA poderosa.** Como `builder` puede `create pods` en `dev`, puede agendar un Pod que corra bajo *cualquier* SA de `dev`, y luego leer el token montado de ese Pod. Suplantá a `builder` para demostrar que el API server lo permite:

   ```bash
   cat <<'EOF' | kubectl create -n dev --as=system:serviceaccount:dev:builder -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pwn
     namespace: dev
   spec:
     serviceAccountName: powerful
     containers:
       - name: c
         image: busybox
         command: ["sleep", "3600"]
   EOF
   ```
   Esperado:
   ```
   pod/pwn created
   ```
   El atacante ahora hace `kubectl exec` (o lee el token proyectado) y posee una credencial `cluster-admin`.

4. **Escalada B — leer Secrets directamente.** `get`/`list` sobre Secrets significa que toda credencial del namespace queda expuesta, incluidos los tokens heredados de otros ServiceAccounts si existieran:

   ```bash
   kubectl get secrets -n dev --as=system:serviceaccount:dev:builder
   ```
   Esperado: la SA puede listar todos los Secrets de `dev`.

5. **Remediá.** Reemplazá el permiso peligroso por uno mínimo que elimine ambos vectores — sacá `create pods` y acotá las lecturas de Secrets solo a objetos nombrados:

   ```yaml
   # fixed-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: risky-builder      # same name → overwrites the grant
     namespace: dev
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list"]                 # no more create
     - apiGroups: [""]
       resources: ["secrets"]
       resourceNames: ["app-config"]          # only this one Secret
       verbs: ["get"]
   ```
   ```bash
   kubectl apply -f fixed-builder.yaml
   ```

6. Verificá que ambos vectores estén cerrados:

   ```bash
   kubectl auth can-i create pods            -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i list   secrets         -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i get    secrets/app-config -n dev --as=system:serviceaccount:dev:builder
   ```
   Esperado:
   ```
   no
   no
   yes
   ```

**Preguntas de control**

- **P16.** Explicá el paso 3 con tus palabras: ¿por qué `create pods` en un namespace equivale de hecho a *"asumir la identidad del ServiceAccount más poderoso de ese namespace"*? ¿Qué otros dos campos de la spec del Pod otorgan escaladas análogas?
- **P17.** En el paso 6, `list secrets` ahora está denegado pero `get secrets/app-config` está permitido. ¿Por qué agregar `resourceNames` te obliga a descartar `list`/`watch`, y cuál es el razonamiento de seguridad detrás de esa limitación?
- **P18.** Más allá de `create pods`, `get secrets`, `escalate`, `bind` e `impersonate`, nombrá **dos** permisos más que suelen subestimarse pero que dan escalada de privilegios, y decí brevemente cómo se abusa de cada uno.

---

## Limpieza

```bash
kubectl delete namespace dev --wait=false
kubectl delete clusterrolebinding powerful-admin --ignore-not-found
kubectl delete clusterrole bad-escalate --ignore-not-found
```

---

<details>
<summary><strong>Respuestas — preguntas de control P1–P18</strong></summary>

**P1.** `can-i get secrets` responde una única pregunta sí/no sobre una sola tupla (verbo, recurso); `can-i --list` resuelve e imprime la matriz *completa* de permisos efectivos del sujeto en ese ámbito. Para auditoría, `--list` es superior porque revela permisos que no se te ocurrió preguntar — el comodín, el `escalate` perdido, el `create pods` olvidado — en lugar de solo confirmar una hipótesis que ya tenías. Consulta la API `SelfSubjectRulesReview` y refleja la unión de todos los bindings aplicables.

**P2.** Esas reglas vienen de los ClusterRoles `system:discovery`, `system:public-info-viewer` y de self-review, vinculados al grupo `system:authenticated` (y a veces `system:unauthenticated`). Toda identidad autenticada las hereda. Permiten el descubrimiento de solo lectura de rutas de la API y crear objetos `SelfSubject*Review` (preguntar "¿qué puedo hacer *yo*?"). **No** violan el mínimo privilegio: no exponen datos del clúster ni capacidad de mutación — solo metadatos de la superficie de la API y auto-introspección que el cliente ya necesita para funcionar.

**P3.** El verbo `impersonate` (sobre `users`, `groups` y/o `serviceaccounts`). Es peligroso porque permite a quien lo tiene *convertirse* en cualquier otro sujeto y heredar sus permisos — incluido un usuario `cluster-admin` — así que es una primitiva de escalada de privilegios directa y total. Prácticamente nunca debería otorgarse a cargas de trabajo, y a humanos solo para herramientas acotadas y auditadas. (Como `cluster-admin` podés usar `--as` en estos labs precisamente porque admin ya implica suplantación.)

**P4.** Es mínimo privilegio correcto. Las capacidades se otorgan por verbo; una app que solo *emite* Events legítimamente necesita solo `create`. Agregar `get`/`list` "por simetría" sería privilegio de sobra. Otorgá verbos de lectura solo si el código realmente vuelve a leer los Events.

**P5.** Un permiso de `Role` + `RoleBinding` queda confinado al namespace del `RoleBinding`, así que los derechos de `builder` existen solo en `dev`; por eso `get configmaps -n default` se deniega. Usar un **ClusterRole** referenciado por un **RoleBinding** *igual* confinaría el permiso efectivo al namespace del binding — el ClusterRole solo aporta reglas reutilizables. Solo un ClusterRole referenciado por un **ClusterRoleBinding** otorga el permiso a nivel de clúster (todos los namespaces). Es decir, la combinación de objetos, no el tipo de objeto por sí solo, determina el ámbito.

**P6.** Agregá una segunda regla (o cambiá la existente) con `apiGroups: ["apps"]` y `resources: ["deployments"]`. La pertenencia al grupo de API es significativa: los `deployments` viven en el grupo `apps`, así que dejar `apiGroups: [""]` (el grupo core) significa que la regla simplemente nunca coincide con `deployments` y la petición se deniega. Las reglas RBAC hacen match sobre la tripleta (apiGroup, recurso, verbo).

**P7.** El `automountServiceAccountToken` a nivel de Pod **sobrescribe** la configuración a nivel de ServiceAccount en ambas direcciones. La postura por defecto endurecida es poner `automountServiceAccountToken: false` en los ServiceAccounts (o al menos en `default`) para que *nada* monte un token salvo que un Pod opte explícitamente por hacerlo — denegar por defecto, opt-in por carga de trabajo.

**P8.** Mantené el automontaje apagado e inyectá un **volumen proyectado `serviceAccountToken` estrictamente acotado** solo en ese Pod (`audience` personalizada, `expirationSeconds` corto), montado como solo lectura donde la app lo espera — exactamente el patrón del paso 3 del Ejercicio 4. Eso le da a esa única carga de trabajo una credencial acotada, con expiración y ligada a una audiencia, sin reactivar el automontaje amplio y sin otorgarle a la SA ningún RBAC extra que no necesite.

**P9.** Un token montado es una credencial bearer viva legible por todo proceso dentro del contenedor. Si la carga de trabajo se ve comprometida (RCE, SSRF, una dependencia maliciosa, una shell de depuración filtrada), el atacante lee `/var/run/secrets/.../token` y puede autenticarse de inmediato ante el API server como ese ServiceAccount — convirtiendo un compromiso a nivel de contenedor en acceso a la API del clúster con el alcance de lo que esa SA pueda hacer. Un token sin uso es, entonces, superficie de ataque gratuita con cero beneficio.

**P10.** El token proyectado acotado es (1) **limitado en el tiempo** (`exp`, rotado por el kubelet), así que una filtración se auto-cura; (2) **acotado por audiencia** (`aud`), así que solo lo acepta el consumidor previsto; (3) **ligado a objetos** — su claim `kubernetes.io` lo ata al UID de un Pod (y SA) específico, así que se invalida cuando el Pod se elimina; y (4) **no almacenado como Secret persistente**, así que nunca queda en reposo en etcd esperando ser leído vía `get secrets`. El Secret con token estático heredado no tiene ninguna de estas: nunca expira, no tiene audiencia, no está ligado a nada, y vive para siempre en etcd.

**P11.** El API server lo rechaza (401/audiencia inválida) porque el `aud` del token es `vault`, no la audiencia del API server. La vinculación por audiencia es defensa en profundidad: incluso si el token de `vault` se filtra, no puede reproducirse contra la API de Kubernetes — solo es válido para el servicio específico para el que fue acuñado, limitando dónde es utilizable una credencial robada.

**P12.** Con un token acotado el reloj ya está corriendo: queda inútil en ~8 minutos sin ninguna acción del administrador, así que la respuesta a incidentes puede priorizar rotar la *carga de trabajo*/credencial en vez de correr a revocar un token permanente. Un token estático heredado filtrado, en cambio, es válido hasta que borres el Secret y requeriría encontrarlo y borrarlo en todas partes. La ventana la controla `expirationSeconds` en la fuente proyectada `serviceAccountToken` (y el kubelet rota antes de que caduque).

**P13.** Normalmente RBAC aplica una verificación de **prevención de escalada de privilegios**: para crear o actualizar un Role/ClusterRole, tenés que poseer ya *todos los permisos* que ese nuevo rol otorgaría (o poseer `escalate`). Esto impide que un usuario limitado se escriba a sí mismo un rol más poderoso. El verbo `escalate` *evita* explícitamente esa verificación, permitiendo a quien lo tiene redactar un Role con permisos que él mismo no tiene — es decir, acuñar privilegio arbitrario de la nada.

**P14.** `create` sobre `rolebindings`/`clusterrolebindings` está sujeto a una salvaguarda similar: para vincular un rol, tenés que poseer ya los permisos de ese rol (o poseer `bind`). El verbo `bind` renuncia a esa salvaguarda, permitiendo a quien lo tiene crear un binding hacia un rol *más poderoso que él mismo*. El ataque: con `create rolebindings` + `bind`, el sujeto crea un `ClusterRoleBinding` (o RoleBinding) que referencia el ClusterRole `cluster-admin` existente con él mismo como sujeto — cluster-admin instantáneo, sin necesidad de redactar un rol nuevo.

**P15.** `system:masters` es un **grupo de superusuario cableado por código** en la ruta de autorización del API server — las peticiones que llevan ese grupo cortocircuitan RBAC por completo y siempre se permiten; no hay Role ni binding que puedas editar para restringirlo. La pertenencia viene de las credenciales del cliente (típicamente certificados de cliente x509 con `O=system:masters`, por ejemplo el certificado admin de bootstrap), no de objetos RBAC. Para "remediarlo" tenés que dejar de emitir/confiar en esos certificados (rotar la CA, revocar/reemitir kubeconfigs), porque vive en la capa de autenticación/PKI, no en RBAC.

**P16.** `create pods` te permite fijar `spec.serviceAccountName` a *cualquier* SA de ese namespace; el kubelet entonces monta el token de esa SA en tu Pod, que leés vía `exec` o un volumen proyectado — así que heredás la identidad de la SA más poderosa. Es suplantación de facto de cualquier SA del namespace. Dos escaladas análogas: `spec.volumes.hostPath` (montar el filesystem del nodo, leer credenciales del kubelet / secrets de otros contenedores, escapar al host) y `spec.nodeName` / un `securityContext` privilegiado (correr privilegiado o en un nodo del plano de control). Vectores relacionados: `pods/exec` y `pods/attach` (obtener una shell en Pods privilegiados existentes), y `pods/ephemeralcontainers`.

**P17.** `resourceNames` restringe una regla a objetos nombrados específicos, pero los verbos `list` y `watch` enumeran una *colección* — la petición no tiene un nombre de objeto único contra el cual hacer match, así que RBAC no puede filtrar un list/watch por `resourceNames`. En consecuencia, `resourceNames` solo funciona con verbos que direccionan un objeto por nombre (`get`, `update`, `patch`, `delete`). El razonamiento de seguridad: permitir `list` dejaría que el sujeto leyera *todos* los objetos (derrotando la lista blanca), así que RBAC se niega a combinarlos. Para leer exactamente un Secret tenés que usar `get secrets/<name>` y renunciar a `list`.

**P18.** Dos cualesquiera de, por ejemplo:
- **`create` sobre `serviceaccounts/token` (subrecurso TokenRequest)** — acuñar un token válido para *cualquier* ServiceAccount, incluida una vinculada a `cluster-admin`, sin siquiera ejecutar un Pod.
- **`approve`/`create` sobre `certificatesigningrequests` (+ acceso al signer)** — emitirte un certificado de cliente para un usuario/grupo arbitrario como `system:masters`, evitando RBAC por completo.
- **`update`/`patch` sobre `nodes/status` o `nodes`**, o **`get nodes/proxy`** — alcanzar la API del kubelet para hacer exec en cualquier Pod del nodo y leer sus secrets.
- **`patch` sobre los subjects de tu propio `RoleBinding`/`ClusterRoleBinding`**, o **`update` sobre `webhookconfigurations` de validación/mutación** — interceptar o reescribir peticiones a la API a nivel de todo el clúster.
- **Sin `escalate` pero con `patch` sobre ClusterRoles poderosos existentes** a los que ya estás vinculado — agregar reglas a un rol que ya poseés.

*(Fuentes: RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/ ; buenas prácticas de RBAC, incl. la lista de vectores de escalada — https://kubernetes.io/docs/concepts/security/rbac-good-practices/ ; tokens de ServiceAccount — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/ .)*

</details>