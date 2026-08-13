# Ejercicios guiados — Configurar RBAC, roles y permisos de Kyverno

> **Tema del examen:** KCA 2.4 · Peso 3.0
> **Objetivo:** operar con confianza el modelo de RBAC de Kyverno basado en controladores separados — inspeccionar los `ServiceAccount` y los `ClusterRole` agregados que vienen incluidos, otorgar al *background controller* los permisos de mínimo privilegio que requieren las reglas `generate` y `mutateExisting`, exponer políticas e informes a los desarrolladores mediante la agregación nativa de Kubernetes, y demostrar cada permiso con `kubectl auth can-i`.

## Requisitos previos

- Un clúster funcionando donde tengas `cluster-admin` (kind, minikube, k3d o un clúster de laboratorio sirven igual).
- `kubectl` v1.27+ y Helm v3.
- Kyverno **1.10 o superior** — esta es la versión en la que Kyverno dividió su controlador monolítico en cuatro controladores independientes, cada uno con su propio `ServiceAccount`. Todo este tema asume esa división.

Instalá Kyverno desde el chart oficial:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl -n kyverno rollout status deploy --timeout=120s
```

Esperado:

```
deployment "kyverno-admission-controller" successfully rolled out
deployment "kyverno-background-controller" successfully rolled out
deployment "kyverno-cleanup-controller" successfully rolled out
deployment "kyverno-reports-controller" successfully rolled out
```

> Fuente: Instalación de Kyverno — https://kyverno.io/docs/installation/ · Personalización de RBAC en Kyverno — https://kyverno.io/docs/installation/customization/

---

## Exercise 1 — Mapear las identidades de Kyverno y el controlador dueño de cada responsabilidad

Kyverno no corre como un único proceso con una única identidad. Cada uno de los cuatro controladores tiene una tarea distinta y — algo crítico para RBAC — un `ServiceAccount` distinto. Saber qué controlador ejecuta una acción determinada te dice *a cuál* identidad hay que otorgarle permisos.

1. Listá los ServiceAccounts que creó Kyverno:

   ```bash
   kubectl get serviceaccounts -n kyverno
   ```

   Esperado (columna de secrets recortada):

   ```
   NAME                            AGE
   kyverno-admission-controller    3m
   kyverno-background-controller   3m
   kyverno-cleanup-controller      3m
   kyverno-reports-controller      3m
   ```

2. Mapeá cada Deployment con su ServiceAccount para confirmar el modelo de una identidad por controlador:

   ```bash
   kubectl get deploy -n kyverno \
     -o custom-columns='DEPLOY:.metadata.name,SA:.spec.template.spec.serviceAccountName'
   ```

   Esperado:

   ```
   DEPLOY                          SA
   kyverno-admission-controller    kyverno-admission-controller
   kyverno-background-controller   kyverno-background-controller
   kyverno-cleanup-controller      kyverno-cleanup-controller
   kyverno-reports-controller      kyverno-reports-controller
   ```

3. Prestá atención a la división del trabajo (memorizá esta tabla — es el núcleo del tema):

   | Controlador | ServiceAccount | Responsabilidad |
   |---|---|---|
   | admission | `kyverno-admission-controller` | Sirve el webhook; ejecuta `validate` y `mutate` (sobre la petición entrante); lee recursos de contexto (ConfigMaps, llamadas a la API) |
   | background | `kyverno-background-controller` | Ejecuta `generate` y `mutateExisting` — las reglas que **crean/modifican otros recursos** |
   | reports | `kyverno-reports-controller` | Escanea en segundo plano los recursos existentes y escribe `PolicyReport`/`ClusterPolicyReport` |
   | cleanup | `kyverno-cleanup-controller` | Ejecuta `CleanupPolicy` (borrados estilo TTL) |

**Verificación de comprensión 1**
- a) Una regla `generate` que crea una `NetworkPolicy` por defecto en cada namespace nuevo falla en silencio — no se genera nada. ¿Los permisos de qué ServiceAccount inspeccionás primero, y por qué no los del admission controller?
- b) ¿Por qué Kyverno se divide deliberadamente en cuatro ServiceAccounts en lugar de uno solo? Dá el beneficio específico en términos de RBAC.

---

## Exercise 2 — Entender el mecanismo de ClusterRole agregado que usa Kyverno

Kyverno **no** quiere que edites los `ClusterRole` que trae de fábrica (una actualización del chart los sobrescribiría). En cambio, el ClusterRole efectivo de cada controlador es un **ClusterRole agregado**: un cascarón vacío cuyas reglas ensambla el controller-manager de Kubernetes a partir de cualquier ClusterRole que lleve la etiqueta correcta. Extendés Kyverno *agregando* un ClusterRole etiquetado, nunca editando uno existente.

1. Mirá el cascarón del background controller. Fijate que declara un `aggregationRule` y que sus `rules` se completan automáticamente:

   ```bash
   kubectl get clusterrole kyverno:background-controller -o yaml
   ```

   Esperado (abreviado):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:background-controller
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:                       # <-- filled in by the controller-manager, do not edit
   - apiGroups: [""]
     resources: [configmaps]
     verbs: [get, list, watch]
   # ...more, assembled from every matching ClusterRole
   ```

2. Listá los ClusterRoles de origen que alimentan ese agregado — son los que llevan la etiqueta `rbac.kyverno.io/aggregate-to-background-controller: "true"`:

   ```bash
   kubectl get clusterroles \
     -l rbac.kyverno.io/aggregate-to-background-controller=true
   ```

   Esperado:

   ```
   NAME                                     AGE
   kyverno:background-controller:core       6m
   kyverno:background-controller:additional 6m
   ```

   `:core` es la base de Kyverno. `:additional` es un **placeholder intencionalmente vacío** que el chart incluye para dejarte un espacio libre — pero en la práctica conviene agregar tu propio ClusterRole con nombre único en lugar de editar ese.

3. Confirmá que existen las cuatro etiquetas de agregación, una por controlador:

   ```bash
   kubectl get clusterroles -o jsonpath='{range .items[*]}{.metadata.labels}{"\n"}{end}' \
     | grep -o 'rbac.kyverno.io/aggregate-to-[a-z-]*' | sort -u
   ```

   Esperado:

   ```
   rbac.kyverno.io/aggregate-to-admission-controller
   rbac.kyverno.io/aggregate-to-background-controller
   rbac.kyverno.io/aggregate-to-reports-controller
   ```
   *(cleanup usa su propia etiqueta de agregación `kyverno:cleanup-controller`, de la misma familia.)*

**Verificación de comprensión 2**
- a) Editás `kyverno:background-controller:core` directamente para agregar un permiso. Dos semanas después el permiso desapareció. ¿Qué pasó?
- b) ¿Cuál es la única clave de etiqueta que hace que las reglas de un `ClusterRole` nuevo aparezcan en los permisos efectivos de `kyverno:background-controller`? ¿Cuál es su valor?
- c) Después de crear un ClusterRole correctamente etiquetado, ¿qué componente fusiona realmente sus reglas dentro del agregado — Kyverno, o algo nativo de Kubernetes?

> Fuente: ClusterRoles agregados de Kubernetes — https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles · RBAC de Kyverno — https://kyverno.io/docs/installation/customization/

---

## Exercise 3 — Otorgar al background controller los permisos que necesita una regla `generate`

Kyverno viene con permisos **deliberadamente mínimos** — no es `cluster-admin`. Por eso una regla `generate` que crea un tipo de recurso para el que Kyverno nunca recibió permisos va a fallar. Vas a reproducir esa falla y después corregirla de la forma correcta.

1. Aplicá una política que genere una `NetworkPolicy` de denegación por defecto en cada namespace nuevo:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-networkpolicy
   spec:
     rules:
     - name: default-deny
       match:
         any:
         - resources:
             kinds:
             - Namespace
       generate:
         apiVersion: networking.k8s.io/v1
         kind: NetworkPolicy
         name: default-deny
         namespace: "{{request.object.metadata.name}}"
         synchronize: true
         data:
           spec:
             podSelector: {}
             policyTypes:
             - Ingress
             - Egress
   EOF
   ```

2. **Primero, demostrá que la identidad carece del permiso** — este es el reflejo diagnóstico que premia el examen. Suplantá el ServiceAccount del background controller:

   ```bash
   kubectl auth can-i create networkpolicies.networking.k8s.io \
     --as=system:serviceaccount:kyverno:kyverno-background-controller \
     -n default
   ```

   Esperado:

   ```
   no
   ```

3. Disparí la regla creando un namespace y después buscá el recurso generado:

   ```bash
   kubectl create namespace team-a
   kubectl get networkpolicy -n team-a
   ```

   Esperado — no se genera nada:

   ```
   No resources found in team-a namespace.
   ```

4. Confirmá que el *motivo* es de autorización, no un error de la política. Inspeccioná el UpdateRequest (el CR que Kyverno usa para rastrear la generación) y el log del controlador:

   ```bash
   kubectl get updaterequests -n kyverno
   kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i "forbidden\|not authorized" | tail -1
   ```

   Esperado (línea de log, abreviada):

   ```
   ... failed to generate resource ... networkpolicies.networking.k8s.io is forbidden:
   User "system:serviceaccount:kyverno:kyverno-background-controller" cannot create
   resource "networkpolicies" in API group "networking.k8s.io" in the namespace "team-a"
   ```

5. Corregilo por la vía de la agregación — creá un ClusterRole con nombre único y la etiqueta del background controller:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:generate-networkpolicies
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
   - apiGroups:
     - networking.k8s.io
     resources:
     - networkpolicies
     verbs:
     - create
     - update
     - delete
     - get
     - list
     - watch
   EOF
   ```

6. Verificá que el permiso tomó efecto y volvé a disparar la regla:

   ```bash
   kubectl auth can-i create networkpolicies.networking.k8s.io \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   # -> yes

   kubectl create namespace team-b
   kubectl get networkpolicy -n team-b
   ```

   Esperado:

   ```
   NAME           POD-SELECTOR   AGE
   default-deny   <none>         3s
   ```

7. (Opcional) Rellená retroactivamente el namespace que falló antes del permiso. Como `synchronize: true`, el background controller lo reconcilia — volvé a anotar o recreá `team-a`, o simplemente esperá la próxima reconciliación; `kubectl get netpol -n team-a` debería mostrar ahora `default-deny`.

**Verificación de comprensión 3**
- a) ¿Por qué el `kubectl apply` de la `ClusterPolicy` tuvo éxito aunque Kyverno no podía cumplirla? ¿Qué te dice eso sobre *dónde* se manifiestan las fallas de permisos de generate (en tiempo de admisión vs. en tiempo de ejecución)?
- b) Otorgaste `create`, `update` y `delete`. ¿Por qué una regla `generate` con `synchronize: true` necesita `update` y `delete`, y no solo `create`?
- c) Reescribí el comando `can-i` para verificar el permiso a nivel de todo el clúster en vez de en un solo namespace. ¿Por qué el namespace importa para una `NetworkPolicy` pero no para un `ClusterRole`?

> Fuente: Reglas generate de Kyverno y permisos requeridos — https://kyverno.io/docs/writing-policies/generate/ · Personalización de permisos en Kyverno — https://kyverno.io/docs/installation/customization/

---

## Exercise 4 — Permisos para `mutateExisting` (modificar recursos que ya existen)

`mutate` sobre una petición *entrante* corre en el admission controller y no necesita RBAC adicional (el objeto está en el cuerpo de la petición). `mutateExisting` sale a **parchear objetos que ya están en etcd** — es decir, el background controller actuando sobre el clúster, así que necesita `update` sobre el kind de destino.

1. Aplicá una política que, cada vez que un namespace se etiquete con `stage=prod`, agregue una anotación a cada Deployment existente dentro de él:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: annotate-existing-deployments
   spec:
     mutateExistingOnPolicyUpdate: false
     rules:
     - name: add-tier-annotation
       match:
         any:
         - resources:
             kinds:
             - Namespace
             selector:
               matchLabels:
                 stage: prod
       mutate:
         targets:
         - apiVersion: apps/v1
           kind: Deployment
           namespace: "{{request.object.metadata.name}}"
         patchStrategicMerge:
           metadata:
             annotations:
               tier: "regulated"
   EOF
   ```

2. Predecí la brecha de permisos antes de dispararla:

   ```bash
   kubectl auth can-i update deployments.apps \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   ```

   Esperado (la base de Kyverno no otorga escritura sobre Deployments):

   ```
   no
   ```

3. Otorgalo con otro ClusterRole etiquetado:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:mutate-deployments
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
   - apiGroups: ["apps"]
     resources: ["deployments"]
     verbs: ["get", "list", "watch", "update", "patch"]
   EOF

   kubectl auth can-i update deployments.apps \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   # -> yes
   ```

4. Demostrá el comportamiento de punta a punta:

   ```bash
   kubectl create namespace prod-ns
   kubectl -n prod-ns create deployment web --image=nginx
   kubectl label namespace prod-ns stage=prod
   sleep 5
   kubectl -n prod-ns get deploy web -o jsonpath='{.metadata.annotations.tier}{"\n"}'
   ```

   Esperado:

   ```
   regulated
   ```

**Verificación de comprensión 4**
- a) Una regla `mutate` simple (sin `targets:`) que agrega la misma anotación a los Deployments *a medida que se crean* no necesita ningún permiso RBAC. `mutateExisting` necesita `update` sobre Deployments. Explicá la diferencia en términos de *dónde vive el objeto* cuando Kyverno actúa sobre él.
- b) El permiso del paso 3 incluye `get`/`list`/`watch` además de `update`. ¿Por qué el background controller no puede parchear un objeto que no tiene permiso de leer?

> Fuente: Mutar recursos existentes con Kyverno — https://kyverno.io/docs/writing-policies/mutate/#mutate-existing-resources

---

## Exercise 5 — Exponer políticas e informes a los desarrolladores mediante la agregación nativa de Kubernetes

La otra mitad del RBAC de Kyverno es el acceso del *consumidor*: dejar que los desarrolladores **lean** las políticas y sus `PolicyReport` sin ser cluster-admin. Los CRDs de Kyverno son simplemente recursos de la API, así que otorgás acceso de lectura agregando hacia los ClusterRoles nativos `view`/`edit`/`admin` de Kubernetes — la familia `rbac.authorization.k8s.io/aggregate-to-*` (ojo: es una familia de etiquetas *distinta* de la del Exercise 2).

1. Confirmá que un lector con alcance de namespace actualmente **no puede** leer los informes de políticas. Simulá un usuario vinculado al rol nativo `view` en `team-b`:

   ```bash
   kubectl auth can-i list policyreports.wgpolicyk8s.io \
     --as=dev-alice \
     --as-group=system:authenticated \
     -n team-b
   ```

   Según los valores por defecto de tu clúster, esto da `no` (el rol nativo `view` es anterior a tus CRDs de Kyverno y no los incluye).

2. Creá un ClusterRole que agregue hacia el rol nativo `view`, otorgando lectura sobre las políticas e informes de Kyverno:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:policies-and-reports:view
     labels:
       rbac.authorization.k8s.io/aggregate-to-view: "true"
   rules:
   - apiGroups: ["kyverno.io"]
     resources: ["policies", "clusterpolicies"]
     verbs: ["get", "list", "watch"]
   - apiGroups: ["wgpolicyk8s.io"]
     resources: ["policyreports", "clusterpolicyreports"]
     verbs: ["get", "list", "watch"]
   EOF
   ```

3. Vinculá a `dev-alice` con el ClusterRole nativo `view` en `team-b` (un RoleBinding común — *no* estás nombrando tu ClusterRole nuevo, confiás en que la agregación ya lo incorporó dentro de `view`):

   ```bash
   kubectl -n team-b create rolebinding alice-view \
     --clusterrole=view --user=dev-alice
   ```

4. Volvé a verificar — ahora el lector puede leer los informes pero sigue sin poder escribir políticas:

   ```bash
   kubectl auth can-i list policyreports.wgpolicyk8s.io --as=dev-alice -n team-b
   # -> yes
   kubectl auth can-i delete clusterpolicies.kyverno.io --as=dev-alice
   # -> no
   ```

**Verificación de comprensión 5**
- a) Nunca hiciste referencia a `kyverno:policies-and-reports:view` en el RoleBinding — vinculaste `view`. ¿Cómo obtuvo Alice los permisos de Kyverno?
- b) Contrastá las dos familias de etiquetas que usaste: `rbac.kyverno.io/aggregate-to-background-controller` frente a `rbac.authorization.k8s.io/aggregate-to-view`. ¿Cuál le otorga a *la propia identidad de Kyverno* el poder de actuar, y cuál les otorga a *las personas* el poder de observar?
- c) Un desarrollador necesita *crear* sus propios objetos `Policy` con alcance de namespace, no solo leerlos. ¿Hacia qué rol nativo agregarías en su lugar, y qué verbos agregarías?

> Fuente: RBAC de Kyverno para acceso a políticas/informes — https://kyverno.io/docs/installation/customization/ · Agregación de RBAC en Kubernetes — https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles

---

## Exercise 6 — Auditar el mínimo privilegio y limpiar

El hábito de nivel examen es: nunca asumas un permiso, siempre demostralo — para la identidad, el verbo, el recurso y el namespace.

1. Producí una auditoría compacta de lo que el background controller puede hacer sobre los dos kinds a los que le diste permisos:

   ```bash
   SA=system:serviceaccount:kyverno:kyverno-background-controller
   for verb in get create update delete; do
     for res in networkpolicies.networking.k8s.io deployments.apps; do
       printf "%-8s %-32s -> " "$verb" "$res"
       kubectl auth can-i "$verb" "$res" --as="$SA" -n default
     done
   done
   ```

   Esperado:

   ```
   get      networkpolicies.networking.k8s.io -> yes
   get      deployments.apps                  -> yes
   create   networkpolicies.networking.k8s.io -> yes
   create   deployments.apps                  -> no
   update   networkpolicies.networking.k8s.io -> yes
   update   deployments.apps                  -> yes
   delete   networkpolicies.networking.k8s.io -> yes
   delete   deployments.apps                  -> no
   ```

2. Confirmá el límite — al background controller **no** se le otorgó nada que no hayas pedido (por ejemplo, no puede tocar Secrets):

   ```bash
   kubectl auth can-i get secrets --as="$SA" -n default
   # -> no
   ```

3. Desarmá el laboratorio (dejá Kyverno instalado):

   ```bash
   kubectl delete clusterpolicy add-default-networkpolicy annotate-existing-deployments
   kubectl delete clusterrole kyverno:generate-networkpolicies kyverno:mutate-deployments kyverno:policies-and-reports:view
   kubectl delete namespace team-a team-b prod-ns
   ```

**Verificación de comprensión 6**
- a) En la salida del paso 1, `create deployments.apps -> no` pero `update -> yes`. ¿Es una mala configuración, o exactamente lo que requería el Exercise 4? Justificalo desde el mínimo privilegio.
- b) Borrás `kyverno:generate-networkpolicies` mientras `add-default-networkpolicy` sigue activa. ¿Qué pasa en la *próxima* creación de un namespace, y dónde se manifiesta la falla?
- c) Escribí el único comando que responde "¿puede el controlador de **reports** listar Pods en todo el clúster?" — ServiceAccount correcto, alcance correcto.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Exercise 1**
- a) El ServiceAccount **`kyverno-background-controller`**. `generate` (y `mutateExisting`) los ejecuta el background controller, que actúa sobre el clúster para crear/modificar otros objetos. El admission controller solo sirve el webhook y actúa sobre el objeto que ya viene dentro de la petición AdmissionReview, así que nunca necesita permisos de create/update sobre *otros* recursos. Inspeccionar el RBAC del admission controller sería un callejón sin salida.
- b) Mínimo privilegio / aislamiento del radio de impacto. Cada controlador lleva solo los permisos que su tarea necesita: el admission controller puede leer recursos de contexto pero no puede crear objetos arbitrarios; solo el background controller obtiene create/update sobre los kinds generados; solo el reports controller obtiene lectura amplia para escanear. Un único ServiceAccount monolítico necesitaría la unión de los cuatro, así que el compromiso de cualquiera de los procesos expondría el conjunto completo. La división también te permite otorgar/revocar una capacidad (por ejemplo, "puede crear NetworkPolicies") exactamente a la identidad que la usa.

**Exercise 2**
- a) Una actualización de Helm/chart (o la propia reconciliación de Kyverno sobre los ClusterRoles que administra) restableció `kyverno:background-controller:core` a su contenido original, descartando tu edición. Los roles administrados por Kyverno no son un lugar seguro para reglas personalizadas — para eso existe la agregación.
- b) La clave `rbac.kyverno.io/aggregate-to-background-controller`, con valor `"true"` (una cadena). Cualquier ClusterRole con esa etiqueta ve sus `rules` incorporadas a `kyverno:background-controller`.
- c) Kubernetes nativo — el **controlador de agregación de ClusterRoles del controller-manager** observa los ClusterRoles que coinciden con los `clusterRoleSelectors` de un `aggregationRule` y completa las `rules` del agregado. Kyverno solo *define* el cascarón con su `aggregationRule`; no hace la fusión.

**Exercise 3**
- a) El requisito de permisos de una regla `generate` no se verifica en la admisión de la política — la `ClusterPolicy` es un objeto válido, así que `kubectl apply` tiene éxito. El permiso se ejerce **en tiempo de ejecución**, cuando el background controller intenta crear el recurso de destino. Por eso las fallas de permisos de generate se manifiestan como UpdateRequests fallidos / errores `forbidden` en el log del controlador / un recurso generado ausente — nunca como un `kubectl apply` rechazado de la política. (Por esto el diagnóstico con `can-i` del paso 2 es el camino rápido.)
- b) Con `synchronize: true`, Kyverno mantiene el recurso generado en sintonía con la política: si alguien edita o borra el `default-deny` generado, Kyverno debe **actualizarlo** nuevamente o **recrearlo**, y si la regla/disparador deja de coincidir debe **borrar** el huérfano. Solo con `create`, un usuario podría alterar o eliminar permanentemente el objeto generado.
- c) La forma a nivel de clúster elimina `-n default` y agrega `--all-namespaces` (o simplemente omitís el namespace y consultás una verificación de alcance de clúster):
  `kubectl auth can-i create networkpolicies.networking.k8s.io --as=system:serviceaccount:kyverno:kyverno-background-controller --all-namespaces`.
  El namespace importa para `NetworkPolicy` porque es un recurso **con alcance de namespace** — el permiso se puede otorgar por namespace (vía RoleBinding) o en todo el clúster (ClusterRoleBinding). `ClusterRole` tiene **alcance de clúster**, así que no hay dimensión de namespace contra la cual autorizar.

**Exercise 4**
- a) En una regla `mutate` simple, el objeto de destino está **dentro de la petición AdmissionReview entrante** — todavía no se persistió, y Kyverno muta la carga útil de la petición que el API server está por almacenar. No hay llamada a la API contra un objeto existente, por lo tanto no hay RBAC. En `mutateExisting` el destino **ya vive en etcd**; el background controller emite un `PATCH`/`UPDATE` real contra el API server para ese objeto, que el API server autoriza — de ahí que se requiera el permiso `update` (y `patch`).
- b) Para parchear un objeto, Kyverno primero debe leer su estado actual (para construir/verificar el parche y para detectar desvíos). Kubernetes autoriza los verbos de lectura y escritura de forma independiente; `update` sin `get`/`list`/`watch` deja al controlador sin poder obtener ni reconciliar el destino, así que no puede calcular ni aplicar la mutación de manera confiable.

**Exercise 5**
- a) Agregación. Tu ClusterRole llevaba `rbac.authorization.k8s.io/aggregate-to-view: "true"`, así que el controller-manager fusionó sus reglas dentro del ClusterRole nativo `view`. Vincular a Alice con `view` incluye, por lo tanto y de forma transitiva, las reglas de lectura de Kyverno — no hace falta ninguna referencia directa a tu ClusterRole.
- b) `rbac.kyverno.io/aggregate-to-background-controller` le otorga a **la propia identidad del ServiceAccount de Kyverno** el poder de actuar sobre los recursos del clúster (crear NetworkPolicies, parchear Deployments). `rbac.authorization.k8s.io/aggregate-to-view` les otorga a los **usuarios humanos/de la API** vinculados al rol nativo `view` el poder de observar los CRDs de Kyverno. Una es sobre la autoridad del controlador; la otra, sobre la visibilidad del consumidor.
- c) Agregar hacia el rol nativo **`edit`** (con alcance de namespace) — `rbac.authorization.k8s.io/aggregate-to-edit: "true"` — y añadir `create`, `update`, `patch`, `delete` sobre `policies` en el grupo `kyverno.io` (dejá `clusterpolicies` fuera de `edit`, ya que las ClusterPolicies tienen alcance de clúster y no deberían ser escribibles desde un editor con alcance de namespace).

**Exercise 6**
- a) Es exactamente lo que requería el Exercise 4, y *sí* es mínimo privilegio. `mutateExisting` sobre Deployments solo necesita modificar objetos existentes (`update`/`patch`), nunca crearlos ni borrarlos, así que otorgar `create`/`delete` sobre Deployments sería autoridad excedente. `create`/`delete` sobre NetworkPolicies es correcto porque la regla `generate`+`synchronize` genuinamente las crea y las elimina.
- b) En la próxima creación de un namespace, el background controller vuelve a carecer de `create networkpolicies`, así que la generación falla en tiempo de ejecución: no aparece ningún `default-deny`, el UpdateRequest queda en estado fallido/pendiente, y el log de `kyverno-background-controller` muestra la línea `forbidden`. La propia `ClusterPolicy` sigue tan tranquila en estado `Ready`/admitida — la falla solo aparece en la generación, no en la validación de la política.
- c) `kubectl auth can-i list pods --as=system:serviceaccount:kyverno:kyverno-reports-controller --all-namespaces` (o `-A`). La identidad correcta es el ServiceAccount de **reports**; `--all-namespaces` la convierte en una verificación a nivel de todo el clúster, coincidiendo con la forma en que el reports controller escanea cada namespace.

</details>