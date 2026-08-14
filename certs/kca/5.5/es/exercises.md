# KCA 5.5 — Reglas de generación: ejercicios guiados

> **Alcance.** Estos ejercicios cubren las reglas `generate` de Kyverno en `ClusterPolicy` / `Policy` (`kyverno.io/v1`): `data` vs `clone` vs `cloneList`, la semántica de sincronización, `generateExisting`, `foreach`, el bucle de control de `UpdateRequest`, el modelo RBAC del background controller y la ruta de diagnóstico cuando no aparece nada.
>
> **Nota sobre versiones.** Las salidas de abajo son *representativas*. Los conjuntos de columnas y los valores por defecto cambian ligeramente entre releases menores de Kyverno — registrá lo que imprime **tu** cluster y confirmá cada campo con `kubectl explain` antes de confiar en él. Los releases recientes de Kyverno también incluyen tipos de política más nuevos basados en CEL bajo el grupo de API `policies.kyverno.io`; verificá `kubectl api-resources --api-group=policies.kyverno.io` en tu cluster. El currículum de KCA y todos los ejercicios de acá apuntan a la regla `generate` estable de `kyverno.io/v1`.
>
> **Directorio de trabajo.** Creá uno: `mkdir -p ~/kca-5.5 && cd ~/kca-5.5`. Todos los archivos referenciados se crean dentro de él.

---

## Ejercicio 0 — Construir el laboratorio e identificar el componente que ejecuta

### Pasos

1. Creá un cluster descartable:

```bash
kind create cluster --name kca-generate --image kindest/node:v1.32.0
kubectl cluster-info --context kind-kca-generate
```

2. Instalá Kyverno con el conjunto completo de controladores (**no** uses perfiles de `--set` que deshabiliten el background controller):

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait
```

3. Enumerá lo que realmente se desplegó:

```bash
kubectl -n kyverno get deploy
```

Salida representativa:

```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller   1/1     1            1           94s
kyverno-background-controller  1/1     1            1           94s
kyverno-cleanup-controller     1/1     1            1           94s
kyverno-reports-controller     1/1     1            1           94s
```

4. Enumerá las service accounts y el CRD que transporta el trabajo de generación:

```bash
kubectl -n kyverno get sa
kubectl get crd | grep kyverno.io
kubectl api-resources --api-group=kyverno.io | grep -i updaterequest
```

Salida representativa del último comando:

```
updaterequests    ur    kyverno.io/v2    true    UpdateRequest
```

5. Registrá la versión contra la que estás probando — la vas a necesitar cuando un campo no exista:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Verificá tu comprensión

- **Q0.1** Hay cuatro deployments corriendo. ¿Cuál *evalúa* la regla `generate` en tiempo de admisión y cuál *crea el recurso downstream*?
- **Q0.2** `UpdateRequest` es namespaced. ¿En qué namespace viven los objetos `UpdateRequest` de generación, y por qué importa eso en un cluster multi-tenant donde los tenants tienen RBAC acotado a su namespace?
- **Q0.3** Predecí: si escalás `kyverno-background-controller` a 0 réplicas y después creás un trigger que coincida, ¿qué vas a ver y qué *no* vas a ver?

---

## Ejercicio 1 — Una regla `generate` con `data`: NetworkPolicy default-deny por namespace

El caso de uso canónico de producción: cada namespace nuevo recibe una `NetworkPolicy` default-deny para que las cargas de trabajo arranquen cerradas y haya que abrirlas explícitamente.

### Pasos

1. Escribí `01-default-deny.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-deny
  annotations:
    policies.kyverno.io/title: Add Default Deny NetworkPolicy
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/subject: Namespace, NetworkPolicy
spec:
  background: true
  rules:
    - name: generate-default-deny
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          metadata:
            labels:
              kca.io/baseline: "true"
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

2. Aplicala y confirmá que la política fue admitida y está lista:

```bash
kubectl apply -f 01-default-deny.yaml
kubectl get clusterpolicy add-default-deny
```

Salida representativa:

```
NAME               ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-default-deny   true        true         True    6s    Ready
```

3. Creá un trigger y mirá aparecer el downstream:

```bash
kubectl create namespace team-alpha
sleep 3
kubectl -n team-alpha get networkpolicy
```

Salida representativa:

```
NAME           POD-SELECTOR   AGE
default-deny   <none>         2s
```

4. Inspeccioná el objeto de control que Kyverno creó para hacer el trabajo:

```bash
kubectl -n kyverno get updaterequests
kubectl -n kyverno get ur -o yaml | grep -E 'policy:|requestType:|state:' 
```

Salida representativa:

```
NAME       POLICY             RULETYPE   RESOURCEKIND   RESOURCENAME   RESOURCENAMESPACE   STATUS      AGE
ur-9dxk7   add-default-deny   generate   Namespace      team-alpha                         Completed   8s
```

5. Inspeccioná cómo Kyverno rastrea el downstream:

```bash
kubectl -n team-alpha get netpol default-deny -o jsonpath='{.metadata.labels}' | tr ',' '\n'
kubectl -n team-alpha get netpol default-deny -o jsonpath='{.metadata.ownerReferences}'
```

Deberías ver `app.kubernetes.io/managed-by: kyverno` más una familia de labels `generate.kyverno.io/*` que nombran la política, la regla y el trigger (kind, nombre, namespace, UID). La consulta de `ownerReferences` no debería imprimir nada. Anotá las claves de label exactas que emite tu versión.

### Verificá tu comprensión

- **Q1.1** Dos componentes de Kyverno tocaron este request. Describí la secuencia exacta desde `kubectl create namespace` hasta que la `NetworkPolicy` existe, nombrando el objeto intermedio.
- **Q1.2** La `NetworkPolicy` **no** tiene un `ownerReference` que apunte al `Namespace`, aunque Kubernetes permitiría que un objeto namespaced sea propiedad de uno cluster-scoped. ¿Cómo rastrea Kyverno la relación trigger→downstream en su lugar, y nombrá una capacidad que dan las labels y que los `ownerReferences` no podrían dar?
- **Q1.3** ¿Qué pasaría si borraras el campo `namespace:` del bloque `generate` manteniendo `kind: NetworkPolicy`?
- **Q1.4** Acá `spec.background` es `true`. ¿Qué cambiaría funcionalmente si lo pusieras en `false`?

---

## Ejercicio 2 — `synchronize`: la diferencia entre "creado una vez" y "reconciliado continuamente"

Acá el trigger *no* es el namespace, así que podés borrar el trigger sin destruir el namespace del downstream — que es lo que hace observable la semántica de borrado.

### Pasos

1. Escribí `02-tenant-quota.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-quota
spec:
  background: true
  rules:
    - name: generate-quota
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
              selector:
                matchLabels:
                  kca.io/tenant: "true"
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: tenant-quota
        namespace: "{{request.object.metadata.namespace}}"
        synchronize: true
        data:
          spec:
            hard:
              requests.cpu: "{{request.object.data.cpu}}"
              requests.memory: "{{request.object.data.memory}}"
              pods: "{{request.object.data.pods}}"
```

2. Aplicá la política y creá el trigger:

```bash
kubectl apply -f 02-tenant-quota.yaml

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-config
  namespace: team-alpha
  labels:
    kca.io/tenant: "true"
data:
  cpu: "4"
  memory: "8Gi"
  pods: "20"
EOF

sleep 3
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard}{"\n"}'
```

Esperado:

```
{"pods":"20","requests.cpu":"4","requests.memory":"8Gi"}
```

3. **Prueba de drift A — mutar el downstream directamente:**

```bash
kubectl -n team-alpha patch resourcequota tenant-quota --type merge \
  -p '{"spec":{"hard":{"pods":"999"}}}'
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard.pods}{"\n"}'
```

4. **Prueba de drift B — borrar el downstream:**

```bash
kubectl -n team-alpha delete resourcequota tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota
```

5. **Prueba de fuente de verdad — cambiar el trigger:**

```bash
kubectl -n team-alpha patch configmap tenant-config --type merge \
  -p '{"data":{"cpu":"8"}}'
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.spec.hard}{"\n"}'
```

6. **Borrado del trigger con `synchronize: true`:**

```bash
kubectl -n team-alpha delete configmap tenant-config
sleep 5
kubectl -n team-alpha get resourcequota
```

7. Ahora invertí la semántica. Cambiá `synchronize: true` por `synchronize: false` en `02-tenant-quota.yaml`, volvé a aplicar, recreá el ConfigMap trigger del paso 2 y repetí los pasos 3, 4 y 6. Registrá cada resultado en una tabla.

```bash
sed -i 's/synchronize: true/synchronize: false/' 02-tenant-quota.yaml
kubectl apply -f 02-tenant-quota.yaml
```

### Verificá tu comprensión

- **Q2.1** Completá esta tabla con tus propias observaciones:

  | Acción | `synchronize: true` | `synchronize: false` |
  |---|---|---|
  | Parchear el downstream | | |
  | Borrar el downstream | | |
  | Cambiar los datos del trigger | | |
  | Borrar el trigger | | |

- **Q2.2** `synchronize: true` tiene un costo. Nombrá dos costos operativos concretos en un cluster con 2.000 namespaces.
- **Q2.3** Un equipo de plataforma quiere un objeto *seed*: creado por política y después propiedad del tenant, que puede editarlo libremente. ¿Qué configuración necesitan y qué capacidad resignan de forma permanente?
- **Q2.4** ¿Qué configuración usarías si querés sincronización continua mientras exista la política, pero querés que los objetos downstream **sobrevivan** al borrado de la política misma?

---

## Ejercicio 3 — `clone`: propagar una credencial de registry desde una única fuente de verdad

### Pasos

1. Creá el namespace fuente y el Secret fuente:

```bash
kubectl create namespace platform-secrets

kubectl -n platform-secrets create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot \
  --docker-password=s3cr3t-v1 \
  --docker-email=robot@example.com
```

2. Escribí `03-clone-regcred.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-image-pull-secret
spec:
  background: true
  rules:
    - name: clone-regcred
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        apiVersion: v1
        kind: Secret
        name: regcred
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: platform-secrets
          name: regcred
```

3. Aplicá y dispará:

```bash
kubectl apply -f 03-clone-regcred.yaml
kubectl create namespace team-beta
sleep 3
kubectl -n team-beta get secret regcred
kubectl -n team-beta get secret regcred \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

Deberías ver la credencial de `s3cr3t-v1`.

4. **Rotá la fuente** y observá la propagación:

```bash
kubectl -n platform-secrets create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=robot \
  --docker-password=r0tat3d-v2 \
  --docker-email=robot@example.com \
  --dry-run=client -o yaml | kubectl apply -f -

sleep 5
kubectl -n team-beta get secret regcred \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

5. Verificá quién tiene permitido leer la fuente:

```bash
kubectl auth can-i get secrets \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n platform-secrets
```

### Verificá tu comprensión

- **Q3.1** ¿Qué service account tuvo que leer `platform-secrets/regcred`, y cuál es el radio de impacto del permiso que hace que clonar Secrets funcione en primer lugar?
- **Q3.2** ¿Por qué está `platform-secrets` en el bloque `exclude`? Describí con precisión qué intentaría hacer la regla sin eso.
- **Q3.3** `data` vs `clone`: enunciá el trade-off en una oración cada uno, con una razón explícita de por qué `data` es la herramienta equivocada para una credencial de registry.
- **Q3.4** Con `synchronize: true`, un tenant con `edit` en `team-beta` parchea `regcred`. ¿Eso les da una forma persistente de apuntar los image pulls a un registry que ellos controlan? Justificá.

---

## Ejercicio 4 — `cloneList`: propagar un *conjunto* seleccionado por labels

### Pasos

1. Poblá el namespace fuente con varios objetos, de los cuales solo algunos están marcados para propagación:

```bash
kubectl -n platform-secrets create configmap ca-bundle \
  --from-literal=ca.crt=PLACEHOLDER
kubectl -n platform-secrets label configmap ca-bundle kca.io/propagate=true

kubectl -n platform-secrets create configmap internal-notes \
  --from-literal=note=do-not-propagate

kubectl -n platform-secrets label secret regcred kca.io/propagate=true
```

2. Escribí `04-clonelist.yaml`. Fijate en la forma: no hay `apiVersion`/`kind`/`name` al nivel de `generate`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: sync-platform-bundle
spec:
  background: true
  rules:
    - name: clone-bundle
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        cloneList:
          namespace: platform-secrets
          kinds:
            - v1/Secret
            - v1/ConfigMap
          selector:
            matchLabels:
              kca.io/propagate: "true"
```

3. Aplicá y disparalo con un namespace nuevo:

```bash
kubectl apply -f 04-clonelist.yaml
kubectl create namespace team-gamma
sleep 5
kubectl -n team-gamma get configmap,secret
```

`ca-bundle` y `regcred` deberían estar presentes; `internal-notes` no (`kube-root-ca.crt` lo crea Kubernetes mismo, no Kyverno — confirmalo revisando sus labels).

4. **Extendé el conjunto después del hecho:**

```bash
kubectl -n platform-secrets create configmap extra-trust --from-literal=x=y
kubectl -n platform-secrets label configmap extra-trust kca.io/propagate=true
sleep 5
kubectl -n team-gamma get configmap
```

5. **Retirá del conjunto:**

```bash
kubectl -n platform-secrets label configmap extra-trust kca.io/propagate-
sleep 5
kubectl -n team-gamma get configmap
```

Registrá el resultado de los pasos 4 y 5 exactamente.

### Verificá tu comprensión

- **Q4.1** ¿Por qué `cloneList` no tiene campo `name` en el bloque `generate`, y qué determina los nombres de los downstream?
- **Q4.2** Fijate en la sintaxis de `kinds`: `v1/Secret`, no `Secret`. Escribí la entrada que usarías para clonar un `Certificate` de `cert-manager.io/v1`.
- **Q4.3** A partir de los pasos 4 y 5: con `synchronize: true`, ¿el label selector se evalúa una sola vez en el momento de la generación o continuamente? ¿Qué implica eso respecto del label como frontera de seguridad?
- **Q4.4** Necesitás los mismos tres ConfigMaps en cada namespace, pero con un valor por namespace sustituido en uno de ellos. ¿Es `cloneList` la herramienta correcta? ¿Por qué sí o por qué no?

---

## Ejercicio 5 — RBAC: el background controller solo puede crear lo que tiene permitido crear

Esta es la falla de reglas `generate` más común en producción. La vas a reproducir deliberadamente contra un kind propio, para que el resultado no dependa del conjunto de roles por defecto de Kyverno.

### Pasos

1. Instalá un CRD chico:

```yaml
# 05-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: tenantprofiles.kca.io
spec:
  group: kca.io
  scope: Namespaced
  names:
    kind: TenantProfile
    listKind: TenantProfileList
    plural: tenantprofiles
    singular: tenantprofile
    shortNames:
      - tp
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                tier:
                  type: string
                owner:
                  type: string
                teams:
                  type: array
                  items:
                    type: object
                    properties:
                      name:
                        type: string
                      owner:
                        type: string
```

```bash
kubectl apply -f 05-crd.yaml
kubectl get crd tenantprofiles.kca.io
```

2. Probá que Kyverno actualmente no puede tocarlo:

```bash
kubectl auth can-i create tenantprofiles.kca.io \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n team-alpha
```

Esperado: `no`.

3. Escribí `05-seed-profile.yaml` — fijate en `synchronize: false`, porque este objeto es un *seed* que después pasa a ser propiedad del equipo de plataforma:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: seed-tenant-profile
spec:
  background: true
  rules:
    - name: create-profile
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              names:
                - kube-*
                - kyverno
                - default
                - local-path-storage
                - platform-secrets
      generate:
        apiVersion: kca.io/v1alpha1
        kind: TenantProfile
        name: profile
        namespace: "{{request.object.metadata.name}}"
        synchronize: false
        data:
          spec:
            tier: bronze
            owner: platform
            teams:
              - name: core
                owner: platform@example.com
```

4. Aplicala y observá la falla. **Hay dos resultados posibles según tu versión de Kyverno** — registrá cuál te tocó:

```bash
kubectl apply -f 05-seed-profile.yaml
```

Resultado A — rechazada en admisión, con un mensaje que nombra el permiso faltante. Resultado B — aceptada, y la falla aparece más tarde:

```bash
kubectl create namespace team-delta
sleep 5
kubectl -n team-delta get tenantprofile
kubectl -n kyverno get ur
kubectl -n kyverno get ur -o yaml | grep -iE 'state|message' | head -20
kubectl -n kyverno logs deploy/kyverno-background-controller --tail=40 | grep -i forbidden
```

5. Arreglalo de la forma segura ante upgrades, con un ClusterRole **agregado**:

```yaml
# 05-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:generate-tenantprofiles
  labels:
    rbac.kyverno.io/aggregate-to-background-controller: "true"
rules:
  - apiGroups:
      - kca.io
    resources:
      - tenantprofiles
    verbs:
      - create
      - get
      - list
      - watch
      - update
      - patch
      - delete
```

```bash
kubectl apply -f 05-rbac.yaml
sleep 5
kubectl get clusterrole kyverno:background-controller -o yaml | grep -A4 tenantprofiles
kubectl auth can-i create tenantprofiles.kca.io \
  --as=system:serviceaccount:kyverno:kyverno-background-controller \
  -n team-alpha
```

Esperado: `yes`.

6. Volvé a disparar la regla. Si la política fue rechazada en el paso 4, aplicala ahora. Si un `UpdateRequest` falló, borralo o recreá el trigger:

```bash
kubectl apply -f 05-seed-profile.yaml
kubectl delete namespace team-delta --wait
kubectl create namespace team-delta
sleep 5
kubectl -n team-delta get tenantprofile profile -o yaml | grep -A8 'spec:'
```

### Verificá tu comprensión

- **Q5.1** ¿Por qué la service account del **admission** controller no necesita `create` sobre `tenantprofiles`, aunque la política se evalúa durante la admisión?
- **Q5.2** ¿Por qué poner una label en un ClusterRole *nuevo* en vez de hacer `kubectl edit clusterrole kyverno:background-controller`?
- **Q5.3** El role otorga siete verbos. `create` es obvio. Justificá cada uno de `get`, `list`, `watch`, `update`, `patch`, `delete` en términos de un comportamiento específico de las reglas `generate`.
- **Q5.4** Kyverno no tiene permiso para crear el kind objetivo. ¿Qué modo de falla es más seguro para un equipo de plataforma — el rechazo en la admisión de la política o un `UpdateRequest` fallido — y por qué?
- **Q5.5** Para una regla basada en `clone`, ¿qué permiso *adicional* se requiere más allá de los del kind downstream?

---

## Ejercicio 6 — `generateExisting`: hacer backfill de recursos anteriores a la política

### Pasos

1. Confirmá el campo y su valor por defecto en tu versión:

```bash
kubectl explain clusterpolicy.spec.generateExisting
kubectl explain clusterpolicy.spec.rules.generate.generateExisting
```

2. Confirmá que los namespaces creados *antes* del Ejercicio 1 no tienen `default-deny`:

```bash
kubectl create namespace legacy-one
kubectl create namespace legacy-two
kubectl -n legacy-one get netpol
```

(Estos ya habrán sido generados por la política todavía activa del Ejercicio 1 — así que primero eliminá esa política para crear una población genuinamente "preexistente").

```bash
kubectl delete clusterpolicy add-default-deny
kubectl create namespace legacy-three
kubectl create namespace legacy-four
kubectl -n legacy-three get netpol
```

Esperado: `No resources found in legacy-three namespace.`

3. Volvé a aplicar la política **sin** backfill y confirmá que no pasa nada con los namespaces existentes:

```bash
kubectl apply -f 01-default-deny.yaml
sleep 5
kubectl -n legacy-three get netpol
kubectl -n kyverno get ur --no-headers | wc -l
```

4. Ahora habilitá el backfill:

```bash
kubectl patch clusterpolicy add-default-deny --type merge \
  -p '{"spec":{"generateExisting":true}}'
sleep 10
kubectl -n legacy-three get netpol
kubectl -n legacy-four get netpol
kubectl -n kyverno get ur --no-headers | wc -l
```

5. Mirá el costo sobre el control plane directamente:

```bash
kubectl -n kyverno get ur -w
# Ctrl-C after ~15s
```

### Verificá tu comprensión

- **Q6.1** Cuando pasaste `generateExisting` a `true`, ¿cuántos objetos `UpdateRequest` se produjeron en relación con la cantidad de triggers coincidentes?
- **Q6.2** Estás por habilitar `generateExisting: true` en una política que matchea `Namespace` en un cluster con 4.000 namespaces. Nombrá dos cosas que podrían salir mal y una técnica de rollout que reduzca el riesgo.
- **Q6.3** `generateExisting` puede definirse a nivel `spec` y a nivel de regla. ¿Cuál gana, y por qué existe un campo a nivel de regla?
- **Q6.4** Un colega sostiene que `generateExisting: true` vuelve innecesario a `synchronize: true`. Refutalo en una oración.

---

## Ejercicio 7 — `foreach`, preconditions y generación encadenada

El `TenantProfile` del Ejercicio 5 fue él mismo *generado*. Ahora usalo como *trigger*.

### Pasos

1. Confirmá que `foreach` existe en tu versión:

```bash
kubectl explain clusterpolicy.spec.rules.generate.foreach
```

Si esto da error, tu Kyverno es anterior a `foreach` en `generate` y deberías saltar a las preguntas.

2. Escribí `07-team-configmaps.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: tenant-team-configmaps
spec:
  background: true
  rules:
    - name: per-team-configmap
      match:
        any:
          - resources:
              kinds:
                - kca.io/v1alpha1/TenantProfile
      preconditions:
        all:
          - key: "{{ request.object.spec.tier || '' }}"
            operator: AnyIn
            value:
              - gold
              - platinum
      generate:
        synchronize: true
        foreach:
          - list: "request.object.spec.teams"
            apiVersion: v1
            kind: ConfigMap
            name: "team-{{ element.name }}"
            namespace: "{{ request.object.metadata.namespace }}"
            data:
              metadata:
                labels:
                  kca.io/team: "{{ element.name }}"
              data:
                owner: "{{ element.owner }}"
                tier: "{{ request.object.spec.tier }}"
                index: "{{ elementIndex }}"
```

3. Aplicá y confirmá que la precondition bloquea el perfil `bronze`:

```bash
kubectl apply -f 07-team-configmaps.yaml
sleep 5
kubectl -n team-delta get configmap
```

Esperado: solo `kube-root-ca.crt`.

4. Promové el tenant. Esto funciona solo porque la regla del Ejercicio 5 usó `synchronize: false`:

```bash
kubectl -n team-delta patch tenantprofile profile --type merge \
  -p '{"spec":{"tier":"gold","teams":[{"name":"core","owner":"core@example.com"},{"name":"data","owner":"data@example.com"}]}}'
sleep 5
kubectl -n team-delta get configmap
kubectl -n team-delta get configmap team-data -o jsonpath='{.data}{"\n"}'
```

5. Quitá un elemento y observá el conjunto reconciliado:

```bash
kubectl -n team-delta patch tenantprofile profile --type merge \
  -p '{"spec":{"teams":[{"name":"core","owner":"core@example.com"}]}}'
sleep 5
kubectl -n team-delta get configmap
```

6. Probá la interacción entre el modo background y las variables exclusivas de admisión. Agregá esto a una copia de trabajo de la política e intentá aplicarla:

```yaml
            data:
              data:
                createdBy: "{{ request.userInfo.username }}"
```

### Verificá tu comprensión

- **Q7.1** En un `foreach` de `generate`, ¿a qué está ligado `element`, qué es `elementIndex` y en qué campos podés referenciarlos?
- **Q7.2** Del paso 5: con `synchronize: true`, ¿qué le pasó a `team-data` cuando su elemento salió de la lista? Enunciá la regla general que esto demuestra.
- **Q7.3** El `TenantProfile` que disparó esta regla fue creado por Kyverno mismo en el Ejercicio 5. Explicá por qué un recurso generado por Kyverno puede disparar otra regla de Kyverno, y describí el modo de falla que eso habilita.
- **Q7.4** Del paso 6: ¿por qué falla `{{ request.userInfo.username }}` en una regla `generate`, y qué te daría realmente poner `background: false`?
- **Q7.5** La precondition usa `{{ request.object.spec.tier || '' }}` en lugar de `{{ request.object.spec.tier }}`. ¿Por qué importa el `|| ''` dado el schema del CRD?

---

## Ejercicio 8 — Ciclo de vida: qué pasa cuando desaparece la *política*

### Pasos

1. Establecé un downstream limpio y sincronizado:

```bash
sed -i 's/synchronize: false/synchronize: true/' 02-tenant-quota.yaml
kubectl apply -f 02-tenant-quota.yaml

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tenant-config
  namespace: team-alpha
  labels:
    kca.io/tenant: "true"
data:
  cpu: "4"
  memory: "8Gi"
  pods: "20"
EOF

sleep 5
kubectl -n team-alpha get resourcequota
```

2. Borrá la política y observá:

```bash
kubectl delete clusterpolicy tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota
```

3. Confirmá el nombre del campo en tu versión y después volvé a aplicar con orphaning habilitado:

```bash
kubectl explain clusterpolicy.spec.rules.generate.orphanDownstreamOnPolicyDelete
```

Agregá al bloque `generate` de `02-tenant-quota.yaml`:

```yaml
        orphanDownstreamOnPolicyDelete: true
```

```bash
kubectl apply -f 02-tenant-quota.yaml
sleep 5
kubectl -n team-alpha get resourcequota
kubectl delete clusterpolicy tenant-quota
sleep 5
kubectl -n team-alpha get resourcequota tenant-quota -o jsonpath='{.metadata.labels}' | tr ',' '\n'
```

4. Borrá solo la *regla* (no la política entera) de una política con varias reglas y predecí el resultado antes de ejecutarlo.

### Verificá tu comprensión

- **Q8.1** Enumerá los cuatro eventos de ciclo de vida independientes que pueden eliminar un recurso downstream, e indicá qué configuración gobierna cada uno.
- **Q8.2** Después del orphaning, el downstream sigue llevando labels `generate.kyverno.io/*`. ¿Por qué es un riesgo y qué harías al respecto en un cluster real?
- **Q8.3** Un controlador de GitOps gestiona tus objetos `ClusterPolicy`. Alguien renombra una política en Git. Trazá qué le pasa a cada recurso downstream e indicá qué configuración evita una caída de servicio.
- **Q8.4** ¿Tiene sentido `orphanDownstreamOnPolicyDelete: true` cuando `synchronize: false`? Explicá.

---

## Ejercicio 9 — Simulacro de diagnóstico: no se generó nada

Trabajá este simulacro *sin* mirar antes la clave de respuestas. Para cada falla, anotá el único comando que identificó la causa.

### Pasos

1. **Falla 1 — el worker no está.**

```bash
kubectl apply -f 01-default-deny.yaml
kubectl -n kyverno scale deploy kyverno-background-controller --replicas=0
kubectl -n kyverno rollout status deploy kyverno-background-controller --timeout=60s || true

kubectl create namespace break-one
sleep 10
kubectl -n break-one get netpol
kubectl -n kyverno get ur
```

Después reparalo y confirmá la auto-recuperación:

```bash
kubectl -n kyverno scale deploy kyverno-background-controller --replicas=1
kubectl -n kyverno rollout status deploy kyverno-background-controller
sleep 10
kubectl -n break-one get netpol
kubectl -n kyverno get ur
```

2. **Falla 2 — la fuente del clone no existe.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-clone
spec:
  background: true
  rules:
    - name: clone-missing
      match:
        any:
          - resources:
              kinds:
                - Namespace
      generate:
        apiVersion: v1
        kind: Secret
        name: does-not-exist
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        clone:
          namespace: platform-secrets
          name: no-such-secret
EOF

kubectl create namespace break-two
sleep 10
kubectl -n kyverno get ur
kubectl -n kyverno get ur -o custom-columns='NAME:.metadata.name,POLICY:.spec.policy,STATE:.status.state,MSG:.status.message'
kubectl -n kyverno logs deploy/kyverno-background-controller --tail=60 | grep -iE 'no-such-secret|not found'
```

3. **Falla 3 — el trigger nunca matcheó.** Creá un namespace cuyo nombre esté excluido y confirmá la *ausencia* de cualquier `UpdateRequest`:

```bash
kubectl create namespace kube-decoy 2>/dev/null || true
kubectl -n kyverno get ur | grep kube-decoy || echo "no UR created — the rule never matched"
```

4. **Confirmá qué te dicen y qué no te dicen los reports:**

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl get events -A --field-selector involvedObject.kind=ClusterPolicy --sort-by=.lastTimestamp | tail -20
```

5. Limpiá la política rota:

```bash
kubectl delete clusterpolicy broken-clone
kubectl delete namespace break-one break-two --wait=false
```

### Verificá tu comprensión

- **Q9.1** Distinguí el significado diagnóstico de un `UpdateRequest` en `Pending` versus `Failed` versus *ningún `UpdateRequest` en absoluto*. Asociá cada uno a una clase distinta de causa raíz.
- **Q9.2** En la Falla 1, la `NetworkPolicy` apareció después de que volviste a escalar el deployment, sin ningún re-trigger. ¿Qué lo garantiza, y qué se habría perdido si el objeto `UpdateRequest` hubiera sido borrado mientras el controlador estaba caído?
- **Q9.3** El paso 4 no produjo entradas de `PolicyReport` para ninguna de estas reglas. ¿Por qué, y cuál es el objeto correcto a observar en su lugar?
- **Q9.4** Escribí la checklist ordenada de cinco pasos que le darías a un SRE junior para "el recurso generado no está", con la verificación más barata primero.
- **Q9.5** El recurso downstream aparece y después desaparece unos segundos más tarde, repetidamente. Dá dos causas plausibles y el comando que las distingue.

---

## Ejercicio 10 — Probar reglas `generate` offline con la CLI de Kyverno

Las reglas `generate` son el tipo de regla más difícil de correr hacia la izquierda (shift left), porque el downstream aterriza en un cluster vivo. La CLI cierra la mayor parte de esa brecha.

### Pasos

1. Instalá y verificá:

```bash
kyverno version
```

2. Creá un fixture de trigger `resource-ns.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-epsilon
```

3. Ejecutá offline la política basada en `data` e imprimí el recurso generado:

```bash
kyverno apply 01-default-deny.yaml --resource resource-ns.yaml
```

4. Probá lo mismo con la política basada en `clone` y observá por qué se comporta distinto:

```bash
kyverno apply 03-clone-regcred.yaml --resource resource-ns.yaml
kyverno apply 03-clone-regcred.yaml --resource resource-ns.yaml --cluster
```

5. Escribí un test declarativo. Confirmá primero el schema actual con `kyverno test --help` y la documentación de la CLI, después creá `kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: default-deny-generation
policies:
  - 01-default-deny.yaml
resources:
  - resource-ns.yaml
results:
  - policy: add-default-deny
    rule: generate-default-deny
    kind: Namespace
    resources:
      - team-epsilon
    result: pass
    generatedResource: expected-netpol.yaml
```

`expected-netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: team-epsilon
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```bash
kyverno test .
```

### Verificá tu comprensión

- **Q10.1** ¿Por qué `kyverno apply` necesita `--cluster` para la política `clone` pero no para la política `data`?
- **Q10.2** Nombrá dos clases de defecto de reglas `generate` que `kyverno test` **no** puede detectar, e indicá qué ejercicio de arriba expuso cada una.
- **Q10.3** ¿En qué punto de un pipeline de CI corresponde `kyverno test` en relación con la verificación de RBAC del Ejercicio 5, y por qué ninguno puede sustituir al otro?

---

## Limpieza

```bash
kubectl delete clusterpolicy --all
kubectl delete crd tenantprofiles.kca.io
kubectl delete namespace team-alpha team-beta team-gamma team-delta \
  platform-secrets legacy-one legacy-two legacy-three legacy-four --wait=false
helm uninstall kyverno -n kyverno
kind delete cluster --name kca-generate
```

---

<details>
<summary><strong>Clave de respuestas</strong></summary>

### Ejercicio 0

**A0.1** El **admission controller** intercepta el request de admisión del trigger, evalúa el `match`/`exclude`/`preconditions` de la regla `generate` y — si matchea — crea un `UpdateRequest`. **No** crea el downstream. El **background controller** observa los objetos `UpdateRequest`, resuelve las variables y emite la llamada real de `create`/`update` del recurso downstream contra el API server. Esta división es la razón por la que las reglas `generate` fallan con `Forbidden` incluso cuando el admission controller tiene permisos de sobra: los dos componentes usan service accounts distintas.

**A0.2** Los objetos `UpdateRequest` viven en el namespace de instalación de Kyverno (`kyverno` en este laboratorio). Consecuencias: un tenant con RBAC solo dentro de su propio namespace **no puede** ver por qué falló una generación — todos los diagnósticos del Ejercicio 9 requieren acceso de lectura al namespace `kyverno`. Por eso los equipos de plataforma necesitan o bien un rol de lectura cluster-scoped para los tenants, o bien un flujo de soporte. También significa que el volumen de URs es una preocupación de escalado concentrada en un solo namespace, no repartida por el cluster.

**A0.3** Vas a ver creado el `UpdateRequest` (el admission controller sigue corriendo y sigue evaluando la regla) y va a quedar en `Pending`. **No** vas a ver el recurso downstream. Esta es la señal más diagnóstica del troubleshooting de `generate`: UR presente + downstream ausente aísla la falla en el background controller o su RBAC, y descarta por completo los problemas de matching/preconditions.

---

### Ejercicio 1

**A1.1** `kubectl create namespace team-alpha` → admisión en el API server → la `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` de Kyverno enruta el request `CREATE Namespace` al **admission controller** → el `match` de la regla (kind `Namespace`) y el `exclude` (nombre fuera del conjunto excluido) pasan ambos → el admission controller crea un **`UpdateRequest`** en el namespace `kyverno` registrando política, regla e identidad del trigger → el request es admitido y el namespace se crea → el **background controller** observa el nuevo `UpdateRequest`, sustituye `{{request.object.metadata.name}}` → `team-alpha`, y hace `create` de la `NetworkPolicy` → el UR pasa a `Completed`.

Críticamente, el downstream se crea **después** de que el trigger fue admitido, de forma asíncrona. Hay una ventana real (normalmente sub-segundo) en la que el namespace existe sin su política default-deny — por eso las reglas `generate` son un mecanismo de *baseline*, no un mecanismo de enforcement. El enforcement es trabajo de una regla `validate`.

**A1.2** Kyverno registra la relación en **labels** sobre el downstream: `app.kubernetes.io/managed-by: kyverno` más la familia `generate.kyverno.io/*` que identifica el nombre de la política, el namespace de la política, el nombre de la regla y el kind, nombre, namespace y UID del trigger. El background controller usa un label selector para encontrar todos los recursos que le pertenecen.

Lo que dan las labels y los `ownerReferences` no pueden dar:
- **Relaciones cross-namespace y cross-scope.** Kubernetes prohíbe que un dependiente namespaced nombre un owner en un namespace *distinto*; la garbage collection trata esa referencia como inválida. Un `ConfigMap` trigger en `team-alpha` que genera en `team-beta` es imposible de expresar con ownership.
- **Borrado reversible, dirigido por política.** Con `ownerReferences`, el borrado es incondicional y lo maneja el garbage collector de Kubernetes. Kyverno necesita que el borrado sea *condicional* respecto de `synchronize` y `orphanDownstreamOnPolicyDelete` — semántica de la que el GC no tiene noción.
- **Búsqueda multidimensional.** Kyverno consulta "todo lo de la política X", "todo lo de la regla Y" y "todo lo del trigger Z" de forma independiente. Un `ownerReference` soporta solo una de esas.

**A1.3** `NetworkPolicy` es un kind namespaced. Sin un `namespace`, Kyverno no tiene namespace destino donde crear. Las versiones modernas de Kyverno rechazan la política en la admisión con un error de validación indicando que se requiere un namespace para un destino `generate` namespaced. Las versiones más viejas pueden aceptarla y producir un `UpdateRequest` fallido. También vale lo inverso: proveer `namespace` para un kind destino **cluster-scoped** es igualmente inválido.

**A1.4** `spec.background: false` restringe la regla únicamente a eventos en tiempo de admisión. Cambian dos cosas: (a) la regla nunca puede aplicarse a recursos preexistentes — `generateExisting` pierde sentido; (b) se detiene la reconciliación periódica en background que repara el drift, así que `synchronize: true` pierde la mayor parte de su poder. Se pone en `false` solo cuando una regla genuinamente requiere contexto exclusivo de admisión, como `request.userInfo` (ver A7.4), y para reglas `generate` esa combinación rara vez es útil.

---

### Ejercicio 2

**A2.1**

| Acción | `synchronize: true` | `synchronize: false` |
|---|---|---|
| Parchear el downstream | Revertido; `pods` vuelve a `20` | El parche persiste; queda `999` |
| Borrar el downstream | Recreado | Queda borrado permanentemente |
| Cambiar los datos del trigger | El downstream se actualiza a `requests.cpu: 8` | El downstream no cambia; sigue en `4` |
| Borrar el trigger | El downstream se borra | El downstream sobrevive, ahora sin gestión |

El modelo unificador: `synchronize: true` hace que política+trigger sean el **estado deseado aplicado continuamente** del downstream, y el downstream una proyección pura sin identidad independiente. `synchronize: false` hace de la política un **creador de una sola vez** — un paso de bootstrap, no un controlador.

**A2.2**
1. **Carga de watch y reconciliación.** El background controller mantiene informers sobre cada kind downstream gestionado y re-reconcilia ante cada cambio. 2.000 namespaces × varios kinds gestionados es una huella de caché sustancial en el controlador y tráfico de watch sostenido contra el API server.
2. **Estado retenido de `UpdateRequest`.** Cada relación sincronizada necesita seguimiento durable, lo que significa objetos en etcd y costo de list/watch en el namespace `kyverno`.
3. (También válido) **Peleas en bucle con otros controladores.** Si un mutating webhook, un operator o un agente de GitOps también escribe el downstream, los dos controladores se sobrescriben indefinidamente, generando escrituras continuas a la API y ruido de auditoría.

**A2.3** `synchronize: false`. Lo que resignan de forma permanente: **corrección de drift y acoplamiento de ciclo de vida**. Si un tenant borra el objeto seed, nunca se restaura; si más adelante se corrige el bloque `data` de la política, los downstreams existentes conservan el contenido viejo para siempre. En la práctica esto significa que las políticas con `synchronize: false` necesitan un mecanismo de auditoría aparte — típicamente una regla `validate` complementaria que reporte los namespaces a los que les falta el objeto.

**A2.4** `generate.orphanDownstreamOnPolicyDelete: true`. Desacopla el borrado de la *política* del borrado del *downstream* dejando intacto el comportamiento de sincronización de `synchronize: true` mientras la política exista. Ver Ejercicio 8.

---

### Ejercicio 3

**A3.1** La service account del **background controller** (`kyverno-background-controller`) lee la fuente. Radio de impacto: para que clonar Secrets funcione siquiera, esa SA necesita `get` sobre `Secret` — y la instalación por defecto de Kyverno lo otorga de forma lo bastante amplia como para cubrir namespaces fuente arbitrarios. Eso significa que **el background controller de Kyverno es un lector de Secrets a nivel de todo el cluster**. Cualquiera que pueda escribir una `ClusterPolicy` con un bloque `clone` puede entonces exfiltrar cualquier Secret del cluster hacia un namespace que controle. En consecuencia: crear/actualizar `ClusterPolicy` es un **privilegio equivalente a cluster-admin** y debe restringirse acordemente, y el namespace de Kyverno merece la misma protección que `kube-system`.

**A3.2** Sin la exclusión, `platform-secrets` mismo matchea `kinds: [Namespace]` cada vez que se crea o se re-reconcilia, y la regla resolvería a: crear `Secret/regcred` en el namespace `platform-secrets`, clonado desde `platform-secrets/regcred` — la fuente y el downstream son el mismo objeto. Kyverno rechaza una regla `generate` cuyo downstream es idéntico a su fuente; y aunque no lo hiciera, habrías creado un objeto autogestionado cuyo bucle de sincronización no significa nada. La regla general: **siempre excluí el namespace fuente del `match` de una regla `clone`.**

**A3.3**
- **`data`**: el manifiesto de la política *es* el contenido deseado. Mejor cuando el contenido no es sensible, es uniforme y corresponde tenerlo en Git junto a la política — resource quotas, network policies, limit ranges. Completamente declarativo y revisable en un PR.
- **`clone`**: un objeto vivo del cluster es la fuente de verdad. Mejor cuando el contenido es sensible, se rota externamente, o es demasiado grande/binario para embeberlo — credenciales de registry, CA bundles, claves de licencia.

`data` es incorrecto para una credencial de registry porque la credencial quedaría escrita en texto plano dentro del manifiesto de la `ClusterPolicy`, y ese manifiesto vive en Git, en la salida de `kubectl get cpol -o yaml` legible por cualquiera con permiso de lectura sobre políticas, y en cada backup de etcd. `clone` mantiene el material secreto en exactamente un objeto con el RBAC normal de Secrets alrededor.

**A3.4** No — no de forma persistente. Con `synchronize: true` el background controller revierte el downstream para que coincida con la fuente, así que el parche del tenant se deshace en la siguiente reconciliación. Pero "no de forma persistente" no es "para nada": hay una ventana entre la escritura del tenant y la reversión durante la cual un pod podría hacer pull desde el registry del atacante. Tratá la sincronización de `generate` como **corrección de drift, no como control de admisión**. Si los tenants nunca deben modificar estos Secrets, combiná la regla `generate` con una regla `validate` (o una restricción de RBAC) que bloquee de plano las escrituras sobre `regcred`.

---

### Ejercicio 4

**A4.1** `cloneList` clona un *conjunto* de objetos cuya membresía se determina en tiempo de reconciliación mediante el `selector` de labels — quien escribe la regla no conoce los nombres de antemano. Los nombres de los downstream se heredan literalmente de los objetos fuente, y el kind del downstream se hereda de cada objeto fuente. Por eso también `apiVersion`, `kind` y `name` deben estar **ausentes** del bloque `generate` cuando se usa `cloneList`: proveerlos contradice la semántica de conjunto, y Kyverno rechaza la política.

**A4.2** `cert-manager.io/v1/Certificate` — el formato es `group/version/Kind`, omitiendo el grupo para los recursos core (`v1/Secret`, `v1/ConfigMap`). Notá que esto difiere de la lista `kinds:` de un bloque `match`, donde se acepta un `Kind` a secas.

**A4.3** Continuamente. Agregar la label a `extra-trust` hizo que se clonara en `team-gamma` sin ningún cambio en el namespace ni en la política; quitar la label hizo que se borrara la copia downstream. El background controller re-evalúa el selector y reconcilia el conjunto de downstreams para que coincida.

La implicancia de seguridad: **la label es una decisión de distribución, así que el permiso de escribir labels en el namespace fuente equivale al permiso de difundir ese objeto a todos los namespaces del cluster.** Cualquiera con `patch` sobre objetos en `platform-secrets` puede propagar contenido arbitrario a todo el cluster y (quitando una label) puede revocar silenciosamente una credencial en todos lados. Los namespaces fuente de `cloneList` necesitan RBAC estricto y auditoría de cambios.

**A4.4** No. `cloneList` copia los objetos fuente literalmente; no hay ningún hook de templating por downstream. La descomposición correcta son dos reglas: `cloneList` para los dos objetos que son idénticos en todos lados, y una regla `data` separada (con `{{request.object.metadata.name}}` o interpolación similar) para el que varía. Forzar una sola regla lleva a la gente a poner todo inline con `data`, lo que reintroduce el problema del secreto-en-Git de A3.3.

---

### Ejercicio 5

**A5.1** Porque el admission controller nunca crea el downstream. Toda su salida es un `UpdateRequest` — un objeto `kyverno.io` que ya tiene permiso de escribir. La acción privilegiada, `create tenantprofiles`, se realiza después y por una identidad distinta. Esta separación es deliberada: el admission controller está en el camino de request de cada llamada a la API y por lo tanto es el componente más sensible desde el punto de vista de seguridad, así que se le dan los *menos* permisos sobre recursos. El background controller está fuera del camino de request y tiene los permisos de escritura.

**A5.2** Porque el chart de Helm es dueño de `kyverno:background-controller`. Cualquier edición directa se revierte silenciosamente en el siguiente `helm upgrade` — un modo de falla que aparece semanas después como "la generación dejó de funcionar después de que parcheamos Kyverno", sin ningún cambio correlacionado en tu repo de políticas. Las labels de agregación de Kyverno (`rbac.kyverno.io/aggregate-to-background-controller`, y las labels paralelas para los controladores de admission, reports y cleanup) existen precisamente para que las extensiones vivan en objetos que vos poseés, en tu propio repo de Git, y sobrevivan a los upgrades. El controlador de agregación de ClusterRoles de Kubernetes fusiona las reglas automáticamente.

**A5.3**
- `create` — producir el downstream inicialmente.
- `get` — leer el downstream actual para calcular si sufrió drift (y, para `clone`, leer la fuente).
- `list` / `watch` — mantener el informer sobre los downstreams gestionados para detectar drift sin polling; también se requiere para enumerar los downstreams de una política o un trigger durante el borrado.
- `update` / `patch` — reconciliar un downstream con drift de vuelta al estado deseado bajo `synchronize: true`.
- `delete` — eliminar el downstream cuando se borra el trigger, cuando se borra la política sin `orphanDownstreamOnPolicyDelete`, o cuando un elemento de `foreach` o un miembro de `cloneList` sale del conjunto.

Con `synchronize: false` podrías arreglártelas con `create` y `get`, pero el role más angosto se convierte en una mina apenas alguien cambie `synchronize` a `true`. Otorgá el conjunto completo.

**A5.4** El rechazo en la admisión de la política. Falla **en el momento del cambio**, en el pipeline de CI/CD o en el `kubectl apply` que lo introdujo, con un mensaje que nombra el permiso faltante — atribuible a un commit específico y a un autor específico. Un `UpdateRequest` fallido falla **asincrónicamente**, en el namespace `kyverno`, visible solo para alguien a quien se le ocurra mirar ahí, y típicamente se descubre cuando un tenant reporta un recurso faltante días después. El principio general: para policy-as-code, empujá las fallas lo más a la izquierda y lo más ruidosamente posible.

**A5.5** `get` sobre el kind fuente **en el namespace fuente** (`get secrets` en `platform-secrets` para el Ejercicio 3), y para `cloneList`, además `list` y `watch` sobre los kinds fuente para poder re-evaluar el selector. Una regla puede por lo tanto fallar de cualquiera de los dos lados: con permiso para escribir el downstream pero no para leer la fuente, o al revés. Revisá ambos al diagnosticar.

---

### Ejercicio 6

**A6.1** Un `UpdateRequest` por cada trigger preexistente que matchea, creados en una ráfaga. Con cuatro namespaces legacy deberías haber visto el conteo de URs saltar en cuatro. No hay batching — la unidad de trabajo es el trigger.

**A6.2** Riesgos:
1. **Presión sobre el API server y etcd.** 4.000 URs creados casi simultáneamente, después 4.000 creaciones de downstream, más los eventos de watch resultantes difundidos a todos los controladores del cluster. En un control plane ocupado esto aparece como latencia de requests y puede disparar throttling del lado del cliente.
2. **Desenmascarar una política mala a escala.** Si el bloque `data` o una variable está mal, `generateExisting` propaga el error a todos los namespaces de una vez en lugar de al próximo que se cree. Con `synchronize: true` además va a sobrescribir cualquier objeto preexistente con el mismo nombre — un resultado genuinamente destructivo si algún equipo ya gestionaba a mano un `default-deny` con reglas distintas.

Rollout que reduce el riesgo: aplicá primero la política con un **`match` angosto** — un selector de labels de namespace como `kca.io/backfill: "true"` — habilitá `generateExisting`, hacé el backfill de un puñado de namespaces etiquetándolos, verificá el contenido del downstream, y después ensanchá progresivamente el selector. Esto te da un punto de aborto por lote, y `kyverno apply --cluster` contra manifiestos reales de namespaces de antemano te da un dry run.

**A6.3** El `generate.generateExisting` a nivel de regla tiene precedencia sobre `spec.generateExisting` para esa regla. El campo a nivel de regla existe porque una sola política habitualmente contiene varias reglas con perfiles de riesgo distintos — hacer backfill de una `NetworkPolicy` faltante en 4.000 namespaces es barato y seguro, mientras que hacer backfill de una `ResourceQuota` podría empezar de inmediato a desalojar o bloquear cargas de trabajo en namespaces que antes no tenían restricciones. El control por regla te permite escalonarlas de forma independiente sin partir la política.

**A6.4** Resuelven problemas ortogonales: `generateExisting` es un **backfill de una sola vez** que responde "¿y qué pasa con los recursos que existían antes de esta política?", mientras que `synchronize` es **reconciliación continua** que responde "¿qué pasa si el downstream se modifica o se borra después de creado?". Backfill sin sync significa que el objeto se crea una vez y después sufre drift libremente; sync sin backfill significa que solo se atienden los triggers recién creados.

---

### Ejercicio 7

**A7.1** `element` está ligado al ítem actual de la expresión JMESPath de `list`, evaluada contra el trigger — acá, cada objeto de `request.object.spec.teams`. `elementIndex` es su posición con base cero. Ambos se pueden usar en todos los campos templatizados de esa entrada de `foreach`: `name`, `namespace`, y en cualquier lugar dentro del bloque `data`, incluidos `metadata.labels` anidados y los valores de `data`. `foreach` es una lista, así que una sola regla `generate` puede contener varias entradas que producen kinds distintos a partir de listas fuente distintas.

**A7.2** `team-data` fue borrado. Regla general: bajo `synchronize: true`, la lista de `foreach` define el **conjunto deseado completo** de downstreams para esa entrada, y el background controller reconcilia el conjunto real hacia él — creando para los elementos nuevos, actualizando los que cambiaron, y **borrando para los elementos que desaparecen**. Esto convierte a `generate`-`foreach` en un fan-out declarativo genuino, no en un bucle de creación de solo agregado. Bajo `synchronize: false`, el ConfigMap del elemento removido habría quedado atrás como huérfano.

**A7.3** Kyverno crea el downstream mediante un **request normal al API server**. Pasa por la cadena de admisión completa — incluidos los propios webhooks de Kyverno — exactamente igual que cualquier otra escritura, así que es un evento de admisión ordinario para todas las demás reglas del cluster. Esto es una funcionalidad (habilita abstracciones de plataforma en capas como Namespace → TenantProfile → ConfigMaps por equipo) y un riesgo: **bucles de generación**. Si la regla A genera un kind que dispara la regla B, y la regla B genera un kind que dispara la regla A, las dos reglas se producen trabajo mutuamente de forma indefinida, llenando el namespace `kyverno` con objetos `UpdateRequest` y martillando el API server. Protegete de esto con selectores de `match` precisos, `preconditions` que excluyan recursos generados por Kyverno (la label `generate.kyverno.io/policy-name` es el marcador), y dibujando el grafo trigger→downstream antes de publicar un conjunto de políticas encadenadas. `resourceFilters` en el ConfigMap de Kyverno es la red de contención a nivel de cluster.

**A7.4** `request.userInfo` se completa solo a partir de un `AdmissionReview`. Las reglas `generate` las ejecuta el background controller a partir de un `UpdateRequest`, que lleva el objeto trigger pero ninguna identidad de admisión — durante la reconciliación en background no hay usuario, y cualquier valor sería una invención. Por eso la validación de políticas de Kyverno rechaza una política con background habilitado que referencie `userInfo`, con un mensaje del estilo *variable `{{request.userInfo...}}` is not allowed in background mode*, y te indica poner `background: false`.

Poner `background: false` acá casi no te da nada: la regla se dispararía solo en eventos de admisión en vivo, nunca sobre recursos existentes y nunca durante la reconciliación, así que `generateExisting` deja de funcionar y `synchronize` pierde su pasada de corrección de drift. Si necesitás registrar quién creó un namespace, el patrón durable es una regla **`mutate`** que estampe `{{request.userInfo.username}}` sobre el *trigger* como una anotación en tiempo de admisión, y una regla `generate` que lea esa anotación desde `request.object` — que está disponible en ambos modos.

**A7.5** El schema del CRD hace que `spec.tier` sea opcional, así que un `TenantProfile` creado sin él no tiene el campo `tier` en absoluto. Evaluar `{{ request.object.spec.tier }}` contra una ruta inexistente produce una falla de resolución de variable, y según la failure policy de Kyverno eso se convierte en un error de regla en lugar de un salteo limpio. El default `|| ''` convierte "ausente" en la cadena vacía, que después simplemente no pasa la comprobación `AnyIn` y saltea la regla. **Siempre proveé un valor por defecto para cualquier variable que lea un campo opcional** — esta es la fuente más común de errores intermitentes en reglas `generate`.

---

### Ejercicio 8

**A8.1**
1. **Se borra el trigger** → el downstream se borra, gobernado por `synchronize: true`. Con `synchronize: false`, el downstream sobrevive.
2. **Se borra la política (o la regla)** → el downstream se borra, gobernado por `generate.orphanDownstreamOnPolicyDelete`. El default `false` significa borrar; `true` significa dejarlo. Borrar una sola regla de una política con varias reglas se comporta como borrar la política *solo para los downstreams de esa regla*.
3. **La regla deja de matchear** — cambian las labels del trigger, se angosta el bloque `match`, o una `precondition` empieza a evaluar falso → el downstream se borra bajo `synchronize: true`, porque ya no forma parte del conjunto deseado.
4. **Un elemento sale del conjunto** — desaparece un ítem de la lista de `foreach` o un match del selector de `cloneList` → ese downstream específico se borra bajo `synchronize: true` (A7.2, A4.3).

Notá qué *no* está en esta lista: la garbage collection normal de Kubernetes. No hay `ownerReferences` (A1.2), así que cada borrado de arriba es un acto explícito del background controller — que es exactamente por lo que necesita `delete` en su RBAC (A5.3).

**A8.2** Las labels anuncian una relación que ya no existe. Riesgos concretos: un operator que recree una política con el mismo nombre puede adoptar al huérfano y sobrescribirlo con contenido distinto; herramientas de limpieza o un runbook que seleccione por `app.kubernetes.io/managed-by=kyverno` van a borrar un objeto que nadie gestiona; y las consultas de inventario reportan mal el objeto como gobernado por política, así que nunca lo levanta el proceso que maneja recursos no gestionados. En un cluster real, quitá o reescribí las labels como parte del procedimiento de baja — por ejemplo `kubectl label <res> generate.kyverno.io/policy-name- app.kubernetes.io/managed-by-` — y registrá al huérfano en tu inventario.

**A8.3** Un rename en Git es un **delete más un create** para el controlador de GitOps. Secuencia: se borra la `ClusterPolicy` vieja → Kyverno borra todos los downstreams que poseía (default `orphanDownstreamOnPolicyDelete: false`) → se crea la nueva `ClusterPolicy` → se generan nuevos `UpdateRequest`s → los downstreams se recrean. Entre ambos momentos, cada namespace del cluster queda brevemente sin su `NetworkPolicy` / `ResourceQuota` / credencial de registry. Para una NetworkPolicy default-deny, esa ventana es un intervalo de red abierta en todo el cluster; para una credencial de registry, es una ola de `ImagePullBackOff` en cualquier pod que reinicie.

`orphanDownstreamOnPolicyDelete: true` previene la caída: los downstreams sobreviven al borrado, y la política recreada los readopta y los reconcilia. Para cualquier política que genere un downstream crítico para la seguridad o la disponibilidad, esta debería ser la postura por defecto, y los renames de políticas igual deberían tratarse como una operación bajo control de cambios.

**A8.4** No — es un no-op. Con `synchronize: false` Kyverno no rastrea el downstream a efectos de ciclo de vida; el borrado de la política ya lo deja en su lugar. `orphanDownstreamOnPolicyDelete` solo altera comportamiento que existe exclusivamente bajo `synchronize: true`. Poner ambos es inocuo pero señala un malentendido en la revisión.

---

### Ejercicio 9

**A9.1**
- **`Pending`** — la regla matcheó y el trabajo se encoló correctamente, pero nada lo consumió. Clase de causa raíz: **el background controller no está disponible** (escalado a cero, en crash-loop, OOMKilled, con la leader election trabada, o tan atrasado que la cola se acumuló). La política en sí está bien.
- **`Failed`** — el background controller tomó el trabajo y la llamada a la API que intentó fue rechazada. Clase de causa raíz: **error de ejecución** — RBAC faltante (`Forbidden`), fuente de clone inexistente (`NotFound`), variable irresoluble, o un manifiesto downstream que el API server rechaza como inválido. `status.message` lo nombra.
- **Ningún UR** — el admission controller nunca decidió que la regla aplicaba. Clase de causa raíz: **matching** — el `match`/`exclude` no seleccionó el trigger, una `precondition` evaluó falso, el webhook no se disparó para ese kind de recurso (revisá las reglas de la `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration`), el namespace del trigger está en los `resourceFilters` del ConfigMap de Kyverno, o la política no está `READY`.

Determinar en cuál de estos tres estados estás es la primera bifurcación diagnóstica, y cuesta un comando.

**A9.2** El `UpdateRequest` es un **ítem de trabajo declarativo y durable en etcd**, no una entrada de cola en memoria. Sobrevivió a la caída, y el background controller lo reconcilió al arrancar — el mismo modelo de entrega at-least-once en el que se apoya cualquier controlador de Kubernetes. Si el UR hubiera sido borrado mientras el controlador estaba caído, el trabajo se habría perdido de forma permanente: nada lo vuelve a derivar, porque el evento de admisión que lo produjo pasó hace rato. La recuperación requeriría volver a disparar — tocando el recurso trigger, o habilitando `generateExisting` para forzar una pasada de backfill. **Nunca borres en masa objetos `UpdateRequest` como paso de "limpieza" mientras el background controller esté con problemas.**

**A9.3** `PolicyReport` y `ClusterPolicyReport` los produce el **reports controller** y registran los resultados de las reglas `validate` y `verifyImages` — tipos de regla que emiten un juicio de aprobado/reprobado sobre un recurso. Una regla `generate` no emite ningún juicio sobre su trigger; realiza una acción en otro lado, así que no hay nada que reportar contra el trigger. El objeto correcto a observar es el **`UpdateRequest`** (`kubectl -n kyverno get ur`), complementado con los logs del background controller y los eventos de Kubernetes sobre la política. Esto confunde a la gente constantemente: un `PolicyReport` vacío no es evidencia de que una regla `generate` esté sana.

**A9.4**
1. `kubectl get cpol <name>` — ¿la política está en `READY: True`? Una política que falló su propia validación no genera nada.
2. `kubectl -n kyverno get ur | grep <trigger>` — ¿existe un `UpdateRequest`? Esta es la bifurcación matching-vs-ejecución de A9.1.
3. Si no hay ninguno: releé `match`/`exclude`/`preconditions` contra las labels y el namespace reales del trigger (`kubectl get <trigger> --show-labels`), y revisá `resourceFilters` en el ConfigMap de Kyverno.
4. Si está `Pending`: `kubectl -n kyverno get pods` y `kubectl -n kyverno logs deploy/kyverno-background-controller` — ¿el controlador está corriendo y sano?
5. Si está `Failed`: leé `status.message` en el UR, después `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:kyverno:kyverno-background-controller -n <target-ns>` para el downstream **y**, si está clonando, para la fuente.

Los pasos 1–2 cuestan dos comandos y localizan la falla en uno de tres subsistemas; todo lo que sigue es dirigido.

**A9.5**
1. **Un controlador competidor u otra regla de Kyverno.** Algo más borra o sobrescribe el objeto, el bucle de `synchronize: true` de Kyverno lo restaura, y los dos oscilan. Distinguilo con `kubectl get events -n <ns> --field-selector involvedObject.name=<downstream> --sort-by=.lastTimestamp` y revisando si el `metadata.managedFields` del objeto lista más de un manager — un segundo nombre de manager es la prueba definitiva.
2. **El trigger mismo está oscilando**, o un `precondition`/`match` es intermitentemente falso — por ejemplo, un controlador alterna una label de la que depende el selector de `match`, así que el downstream alterna entre "dentro del conjunto deseado" y "fuera de él". Distinguilo observando el trigger en lugar del downstream: `kubectl get <trigger> --show-labels -w`, y observando el churn de URs con `kubectl -n kyverno get ur -w` — un flujo de URs *nuevos* apunta a un trigger oscilante, mientras que un único UR estable reconciliando repetidamente apunta a la causa 1.

Una tercera posibilidad que vale la pena descartar barato: el namespace del downstream está terminando, así que cada create tiene éxito y es inmediatamente cosechado.

---

### Ejercicio 10

**A10.1** La generación con `data` es **autocontenida**: el downstream deseado está completamente especificado por el manifiesto de la política más el fixture del trigger, que la CLI tiene ambos en disco. La generación con `clone` es **dependiente del cluster**: el contenido del downstream es lo que sea que `platform-secrets/regcred` contenga en ese momento, y ese objeto existe solo en el cluster. Sin `--cluster` la CLI no puede resolver la fuente e informa que no está disponible; con `--cluster` usa tu kubeconfig para traerla. La misma dependencia aplica a cualquier regla que use una entrada `context` de llamada a la API — probar offline es posible exactamente en la medida en que la regla sea una función pura de la política y el trigger.

**A10.2**
1. **Fallas de RBAC.** `kyverno test` nunca emite el `create` del downstream contra un API server real, así que una regla que va a fallar con `Forbidden` en producción pasa limpiamente en CI. Expuesto por el **Ejercicio 5**.
2. **Comportamiento de ciclo de vida y sincronización.** Corrección de drift, cascadas por borrado del trigger, reconciliación de conjuntos de `foreach`, `orphanDownstreamOnPolicyDelete` — todo eso requiere un controlador vivo observando cambios a lo largo del tiempo. La CLI evalúa un único trigger en un punto en el tiempo. Expuesto por los **Ejercicios 2, 7 y 8**.

También válido: los bucles de generación encadenada (Ejercicio 7), que solo se manifiestan cuando los downstreams vuelven a entrar en el camino de admisión; y el drift de la fuente de clone (Ejercicio 3), dado que una corrida con `--cluster` captura un solo snapshot de la fuente.

**A10.3** Son gates distintos y ninguno sustituye al otro. `kyverno test` corresponde **temprano**, en cada pull request contra el repositorio de políticas — es rápido, hermético para las reglas `data`, y detecta errores de resolución de variables, bugs de lógica en las preconditions y contenido downstream incorrecto. La verificación de RBAC corresponde **en tiempo de deploy contra el cluster destino**, porque la respuesta depende de los ClusterRoles agregados de ese cluster, que no están en el repo de políticas y difieren entre staging y producción.

Una regla puede ser perfectamente correcta y aun así no poder ejecutarse (RBAC faltante); también puede tener un RBAC impecable y generar exactamente el contenido equivocado. Un pipeline práctico corre `kyverno test` en CI, y después en el job de deploy corre `kubectl auth can-i` para cada kind referenciado en un bloque `generate` — kinds downstream y fuentes de clone, ambos — antes de aplicar las políticas.

</details>

---

## Fuentes

- Kyverno — Generate Rules: <https://kyverno.io/docs/writing-policies/generate/> (reorganizado en releases recientes hacia <https://kyverno.io/docs/policy-types/cluster-policy/generate/>)
- Kyverno — Definición de políticas, `match`/`exclude`, `preconditions`, variables: <https://kyverno.io/docs/writing-policies/>
- Kyverno — Personalización de la instalación y labels de agregación RBAC: <https://kyverno.io/docs/installation/customization/>
- Kyverno — Troubleshooting: <https://kyverno.io/docs/troubleshooting/>
- Kyverno — CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Kyverno — Policy Reports: <https://kyverno.io/docs/policy-reports/>
- Biblioteca de políticas de Kyverno (ejemplos de producción de reglas `data`, `clone` y `cloneList`): <https://kyverno.io/policies/> y <https://github.com/kyverno/policies>
- Kubernetes — Owner references y garbage collection (por qué `generate` usa labels en su lugar): <https://kubernetes.io/docs/concepts/architecture/garbage-collection/>
- Kubernetes — Agregación de ClusterRoles: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles>
- Kubernetes — NetworkPolicy, ResourceQuota: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>, <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
- CNCF — Currículum de KCA: <https://github.com/cncf/curriculum>