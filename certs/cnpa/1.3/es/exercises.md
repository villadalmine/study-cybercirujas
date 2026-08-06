# CNPA · Tema 1.3 — Application Environments and Infrastructure Architecture
## Ejercicios guiados (peso en el examen: 7.2)

> **Cómo usar esta guía.** Cada ejercicio es una secuencia de pasos que ejecutás vos, con la salida esperada al lado. Después de cada bloque hay preguntas de verificación numeradas (`P<ejercicio>.<n>`). Las respuestas están al final, en la sección colapsable **Respuestas**. No las mires antes de escribir la tuya: el objetivo es que detectes dónde tu modelo mental del environment no coincide con lo que la infraestructura realmente hace.

---

## 0. Prerrequisitos y montaje del laboratorio

Necesitás una máquina Linux o macOS con:

| Herramienta | Versión mínima | Verificación |
|---|---|---|
| `docker` o `podman` | 24.x | `docker version --format '{{.Server.Version}}'` |
| `kind` | v0.24.0 | `kind version` |
| `kubectl` | v1.30 | `kubectl version --client -o yaml` |
| `clusterctl` | v1.8.0 | `clusterctl version` (solo Ejercicio 6) |
| `jq` | 1.6 | `jq --version` |

### Paso 0.1 — Definir el cluster de laboratorio

Creá el archivo `platform-lab.yaml`. Este manifiesto es la primera decisión de *infrastructure architecture* del laboratorio: define cuántos failure domains simulados vas a tener.

```yaml
# platform-lab.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: platform-lab
nodes:
  - role: control-plane
  - role: worker
    labels:
      topology.kubernetes.io/region: lab
      topology.kubernetes.io/zone: lab-a
  - role: worker
    labels:
      topology.kubernetes.io/region: lab
      topology.kubernetes.io/zone: lab-b
  - role: worker
    labels:
      topology.kubernetes.io/region: lab
      topology.kubernetes.io/zone: lab-c
```

### Paso 0.2 — Crear el cluster

```bash
kind create cluster --config platform-lab.yaml
```

Salida esperada (abreviada):

```
Creating cluster "platform-lab" ...
 ✓ Ensuring node image (kindest/node:v1.32.2) 🖼
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-platform-lab"
```

### Paso 0.3 — Verificar la topología

```bash
kubectl get nodes -L topology.kubernetes.io/zone,topology.kubernetes.io/region
```

```
NAME                         STATUS   ROLES           AGE   VERSION   ZONE    REGION
platform-lab-control-plane   Ready    control-plane   96s   v1.32.2           
platform-lab-worker          Ready    <none>          82s   v1.32.2   lab-a   lab
platform-lab-worker2         Ready    <none>          82s   v1.32.2   lab-b   lab
platform-lab-worker3         Ready    <none>          82s   v1.32.2   lab-c   lab
```

### Paso 0.4 — Confirmar que las labels las puso el kubelet, no vos

```bash
kubectl get node platform-lab-worker -o jsonpath='{.metadata.labels}' | jq
```

```json
{
  "beta.kubernetes.io/arch": "amd64",
  "beta.kubernetes.io/os": "linux",
  "kubernetes.io/arch": "amd64",
  "kubernetes.io/hostname": "platform-lab-worker",
  "kubernetes.io/os": "linux",
  "topology.kubernetes.io/region": "lab",
  "topology.kubernetes.io/zone": "lab-a"
}
```

`kind` traduce el bloque `labels:` a `--node-labels` en el kubelet. Que esas labels sobrevivan no es trivial: el admission plugin **NodeRestriction** impide que un kubelet se auto-asigne labels bajo los prefijos `kubernetes.io/` y `k8s.io/`, salvo una allowlist cerrada que incluye exactamente `topology.kubernetes.io/zone` y `topology.kubernetes.io/region`.

### Preguntas de verificación

- **P0.1** — Si en `platform-lab.yaml` hubieras escrito `labels: { node-restriction.kubernetes.io/tier: prod }`, ¿el nodo arrancaría con esa label? ¿Por qué existe esa restricción?
- **P0.2** — El nodo control-plane no tiene label de zona. ¿Qué implica eso para un `topologySpreadConstraint` sobre `topology.kubernetes.io/zone`?
- **P0.3** — ¿Por qué un platform engineer debería preferir que las labels de topología las ponga el proveedor de infraestructura (cloud-controller-manager, kubelet) y no un `kubectl label` manual en un runbook?

---

## 1. Ejercicio 1 — El boundary real de un environment: namespace-as-environment

**Objetivo:** medir empíricamente qué aísla y qué **no** aísla un Namespace, para decidir con datos entre *namespace-as-environment* y *cluster-as-environment*.

### Paso 1.1 — Crear los tres environments como namespaces

```bash
for env in dev staging prod; do
  kubectl create namespace "$env"
  kubectl label namespace "$env" \
    env.platform.io/name="$env" \
    env.platform.io/tier="$( [ "$env" = prod ] && echo production || echo non-production )"
done
kubectl get ns -L env.platform.io/name,env.platform.io/tier
```

```
NAME                 STATUS   AGE   NAME      TIER
default              Active   6m              
dev                  Active   3s    dev       non-production
kube-node-lease      Active   6m              
kube-public          Active   6m              
kube-system          Active   6m              
local-path-storage   Active   6m              
prod                 Active   1s    prod      production
staging              Active   2s    staging   non-production
```

### Paso 1.2 — Enumerar la superficie que los namespaces NO cubren

```bash
kubectl api-resources --namespaced=false --no-headers | wc -l
kubectl api-resources --namespaced=false -o name | sort | head -25
```

```
44
apiservices.apiregistration.k8s.io
clusterrolebindings.rbac.authorization.k8s.io
clusterroles.rbac.authorization.k8s.io
csidrivers.storage.k8s.io
csinodes.storage.k8s.io
customresourcedefinitions.apiextensions.k8s.io
flowschemas.flowcontrol.apiserver.k8s.io
ingressclasses.networking.k8s.io
mutatingwebhookconfigurations.admissionregistration.k8s.io
namespaces
nodes
persistentvolumes
priorityclasses.scheduling.k8s.io
runtimeclasses.node.k8s.io
storageclasses.storage.k8s.io
validatingadmissionpolicies.admissionregistration.k8s.io
validatingwebhookconfigurations.admissionregistration.k8s.io
...
```

Esa lista **es** la definición operativa del blast radius compartido: cada recurso ahí es una superficie que `dev` puede romperle a `prod` dentro del mismo cluster.

### Paso 1.3 — Demostrar el acoplamiento con un CRD

Un equipo de `dev` instala un operador y con él un CRD. Simulalo:

```yaml
# crd-v1.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: paymentgateways.fintech.platform.io
spec:
  group: fintech.platform.io
  scope: Namespaced
  names:
    plural: paymentgateways
    singular: paymentgateway
    kind: PaymentGateway
    shortNames: ["pgw"]
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["provider"]
              properties:
                provider:
                  type: string
                  enum: ["stripe", "adyen", "mercadopago"]
                timeoutSeconds:
                  type: integer
                  minimum: 1
                  maximum: 60
```

```bash
kubectl apply -f crd-v1.yaml
kubectl apply -n prod -f - <<'EOF'
apiVersion: fintech.platform.io/v1
kind: PaymentGateway
metadata:
  name: checkout
spec:
  provider: mercadopago
  timeoutSeconds: 30
EOF
kubectl get pgw -n prod
```

```
customresourcedefinition.apiextensions.k8s.io/paymentgateways.fintech.platform.io created
paymentgateway.fintech.platform.io/checkout created
NAME       AGE
checkout   4s
```

Ahora `dev` "actualiza el operador" y endurece el schema:

```bash
kubectl patch crd paymentgateways.fintech.platform.io --type=json -p='[
  {"op":"add","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/required/-","value":"merchantId"}
]'

kubectl apply -n prod -f - <<'EOF'
apiVersion: fintech.platform.io/v1
kind: PaymentGateway
metadata:
  name: checkout
spec:
  provider: mercadopago
  timeoutSeconds: 45
EOF
```

```
customresourcedefinition.apiextensions.k8s.io/paymentgateways.fintech.platform.io patched
The PaymentGateway "checkout" is invalid: spec.merchantId: Required value
```

El objeto de `prod` sigue existiendo pero pasó a ser **no reconciliable**: cualquier `apply` del pipeline de producción falla, y el cambio se hizo desde otro environment sin tocar el namespace `prod`.

### Paso 1.4 — Poner el piso de aislamiento que sí depende de vos

```yaml
# prod-guardrails.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: env-quota
  namespace: prod
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "50"
    count/deployments.apps: "20"
    services.loadbalancers: "2"
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: critical-priority-quota
  namespace: prod
spec:
  hard:
    pods: "8"
  scopeSelector:
    matchExpressions:
      - operator: In
        scopeName: PriorityClass
        values: ["platform-critical"]
---
apiVersion: v1
kind: LimitRange
metadata:
  name: env-defaults
  namespace: prod
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "2"
        memory: 4Gi
      min:
        cpu: 10m
        memory: 32Mi
```

```bash
kubectl apply -f prod-guardrails.yaml
kubectl -n prod describe resourcequota env-quota
```

```
Name:                     env-quota
Namespace:                prod
Resource                  Used  Hard
--------                  ----  ----
count/deployments.apps    0     20
limits.cpu                0     8
limits.memory             0     16Gi
persistentvolumeclaims    0     10
pods                      0     50
requests.cpu              0     4
requests.memory           0     8Gi
services.loadbalancers    0     2
```

### Paso 1.5 — Observar la interacción quota ↔ LimitRange

```bash
kubectl -n prod run probe --image=nginx:1.27-alpine --restart=Never
kubectl -n prod get pod probe -o jsonpath='{.spec.containers[0].resources}' | jq
```

```json
{
  "limits": { "cpu": "500m", "memory": "512Mi" },
  "requests": { "cpu": "100m", "memory": "128Mi" }
}
```

Ahora borrá el LimitRange y repetí:

```bash
kubectl -n prod delete pod probe
kubectl -n prod delete limitrange env-defaults
kubectl -n prod run probe --image=nginx:1.27-alpine --restart=Never
```

```
Error from server (Forbidden): pods "probe" is forbidden: failed quota: env-quota:
must specify limits.cpu for: probe; limits.memory for: probe; requests.cpu for: probe;
requests.memory for: probe
```

```bash
kubectl -n prod apply -f prod-guardrails.yaml   # restaurar el LimitRange
```

### Preguntas de verificación

- **P1.1** — El CRD del Paso 1.3 es `scope: Namespaced`, pero el incidente cruzó de `dev` a `prod`. Explicá por qué el scope del CR no protege el schema.
- **P1.2** — Enumerá tres recursos cluster-scoped de la salida del Paso 1.2 donde un error en un environment se propaga a todos, y describí el mecanismo concreto de propagación en cada caso.
- **P1.3** — En el Paso 1.5, sin LimitRange el pod es rechazado. ¿Qué componente lo rechaza, en qué fase del pipeline de admisión, y por qué el error habla de `limits.cpu` si vos nunca lo pediste?
- **P1.4** — La `critical-priority-quota` usa `scopeSelector` con `PriorityClass`. ¿Qué pasa con los pods que **no** tienen `priorityClassName: platform-critical` respecto de esa quota? ¿Y por qué esto es una herramienta de arquitectura y no solo de capacity?
- **P1.5** — Un `ResourceQuota` con `requests.cpu` está aplicado y el equipo reporta que "los deployments se crean pero no aparecen pods". ¿Dónde mirás exactamente para confirmar la causa? Escribí el comando.

---

## 2. Ejercicio 2 — Environment parity: base + overlays y detección de drift

**Objetivo:** construir un modelo de environments donde lo único que varía entre `dev`, `staging` y `prod` es escala y topología, y después detectar y resolver drift con las dos mecánicas del API server (client-side apply vs server-side apply).

### Paso 2.1 — Crear la estructura

```bash
mkdir -p env-model/base env-model/overlays/{dev,staging,prod}
cd env-model
```

```yaml
# base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/component: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
        app.kubernetes.io/component: frontend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: ghcr.io/nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: cache
              mountPath: /tmp
            - name: run
              mountPath: /var/run
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
```

```yaml
# base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
```

```yaml
# base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/part-of: storefront
```

### Paso 2.2 — Overlay de `dev`

```yaml
# overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dev
resources:
  - ../../base
labels:
  - includeSelectors: false
    pairs:
      env.platform.io/name: dev
replicas:
  - name: web
    count: 1
configMapGenerator:
  - name: web-env
    literals:
      - LOG_LEVEL=debug
      - FEATURE_FLAGS=all
patches:
  - target:
      kind: Deployment
      name: web
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/envFrom
        value:
          - configMapRef:
              name: web-env
```

### Paso 2.3 — Overlay de `prod`

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources:
  - ../../base
  - pdb.yaml
labels:
  - includeSelectors: false
    pairs:
      env.platform.io/name: prod
replicas:
  - name: web
    count: 3
configMapGenerator:
  - name: web-env
    literals:
      - LOG_LEVEL=info
      - FEATURE_FLAGS=stable
images:
  - name: ghcr.io/nginxinc/nginx-unprivileged
    newTag: 1.27-alpine
patches:
  - target:
      kind: Deployment
      name: web
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/envFrom
        value:
          - configMapRef:
              name: web-env
  - target:
      kind: Deployment
      name: web
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web
      spec:
        strategy:
          type: RollingUpdate
          rollingUpdate:
            maxUnavailable: 0
            maxSurge: 1
        template:
          spec:
            topologySpreadConstraints:
              - maxSkew: 1
                topologyKey: topology.kubernetes.io/zone
                whenUnsatisfiable: DoNotSchedule
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: web
```

```yaml
# overlays/prod/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: web
```

Replicá `overlays/staging` copiando `prod` con `namespace: staging`, `count: 2`, `LOG_LEVEL=info`, `FEATURE_FLAGS=stable`, `minAvailable: 1` y `whenUnsatisfiable: ScheduleAnyway`.

### Paso 2.4 — Renderizar y comparar environments sin aplicar nada

```bash
kubectl kustomize overlays/dev  > /tmp/dev.yaml
kubectl kustomize overlays/prod > /tmp/prod.yaml
diff <(grep -E 'kind:|replicas:|LOG_LEVEL|maxUnavailable|topologyKey' /tmp/dev.yaml) \
     <(grep -E 'kind:|replicas:|LOG_LEVEL|maxUnavailable|topologyKey' /tmp/prod.yaml)
```

```
2c2
<   LOG_LEVEL: debug
---
>   LOG_LEVEL: info
8c8,11
<   replicas: 1
---
>   replicas: 3
>       maxUnavailable: 0
>         topologyKey: topology.kubernetes.io/zone
10a14
> kind: PodDisruptionBudget
```

Esa diferencia —y nada más— es tu presupuesto de divergencia entre environments. Todo lo que aparezca ahí y **no** sea escala, topología, verbosidad o endpoints es deuda de parity.

### Paso 2.5 — Aplicar `prod` con server-side apply

```bash
kubectl apply -k overlays/prod --server-side --field-manager=platform-gitops
kubectl -n prod rollout status deploy/web --timeout=120s
kubectl -n prod get pods -o wide
```

```
deployment.apps/web serverside-applied
service/web serverside-applied
configmap/web-env-9f7bh2k4tf serverside-applied
poddisruptionbudget.policy/web serverside-applied
deployment "web" successfully rolled out
NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE                   
web-5c9d7f8b64-4nqp2   1/1     Running   0          23s   10.244.1.5   platform-lab-worker    
web-5c9d7f8b64-8jt7x   1/1     Running   0          23s   10.244.2.4   platform-lab-worker2   
web-5c9d7f8b64-x2vlm   1/1     Running   0          23s   10.244.3.6   platform-lab-worker3   
```

### Paso 2.6 — Provocar drift imperativo y detectarlo

```bash
kubectl -n prod scale deploy/web --replicas=6
kubectl diff -k overlays/prod ; echo "exit=$?"
```

```
diff -u -N /tmp/LIVE-2841/apps.v1.Deployment.prod.web /tmp/MERGED-9273/apps.v1.Deployment.prod.web
--- /tmp/LIVE-2841/apps.v1.Deployment.prod.web
+++ /tmp/MERGED-9273/apps.v1.Deployment.prod.web
@@ -33,7 +33,7 @@
   name: web
   namespace: prod
 spec:
-  replicas: 6
+  replicas: 3
   revisionHistoryLimit: 10
exit=1
```

### Paso 2.7 — Ver quién es dueño del campo

```bash
kubectl -n prod get deploy web --show-managed-fields -o json \
  | jq '[.metadata.managedFields[] | {manager, operation, replicas: (.fieldsV1."f:spec"."f:replicas" != null)}]'
```

```json
[
  { "manager": "kubectl-scale", "operation": "Update", "replicas": true },
  { "manager": "platform-gitops", "operation": "Apply", "replicas": false },
  { "manager": "kube-controller-manager", "operation": "Update", "replicas": false }
]
```

### Paso 2.8 — Reconciliar y observar el conflicto

```bash
kubectl apply -k overlays/prod --server-side --field-manager=platform-gitops
```

```
error: Apply failed with 1 conflict: conflict with "kubectl-scale" using apps/v1: .spec.replicas
Please review the fields above--they indicate which fields are managed by another field manager.
...
* If you do not care about ownership, you can run apply with the "--force-conflicts" flag.
```

```bash
kubectl apply -k overlays/prod --server-side --field-manager=platform-gitops --force-conflicts
kubectl -n prod get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
```

```
deployment.apps/web serverside-applied
3
```

### Preguntas de verificación

- **P2.1** — En el Paso 2.6 `kubectl diff` devolvió `exit=1`. ¿Por qué ese exit code, y no `0`, es lo que hace que este comando sirva como gate en CI? ¿Qué exit code devuelve ante un error real de conexión?
- **P2.2** — Explicá la diferencia de mecánica entre el drift detectado por `kubectl diff` (client-side, contra `last-applied-configuration`) y el conflicto del Paso 2.8 (server-side, contra `managedFields`). ¿Cuál de los dos detecta que alguien **borró** un campo del manifiesto?
- **P2.3** — El `configMapGenerator` produce `web-env-9f7bh2k4tf`. ¿Qué problema de environments resuelve ese sufijo hash y qué efecto tiene sobre el rollout cuando cambia `LOG_LEVEL`?
- **P2.4** — El overlay de `prod` fija `maxUnavailable: 0` y el PDB pide `minAvailable: 2` con 3 réplicas. ¿Son redundantes? Justificá con la distinción entre disrupción voluntaria y actualización controlada por el Deployment controller.
- **P2.5** — Un compañero propone usar `branch-per-environment` (una rama Git por environment) en vez de `directory-per-environment`. Dá dos argumentos técnicos concretos en contra desde la perspectiva de environment parity.
- **P2.6** — `--force-conflicts` resolvió el incidente pero es peligroso como default en un reconciliador automático. ¿Cuál es el escenario de falla concreto?

---

## 3. Ejercicio 3 — Failure domains: topology spread, PDB y drenaje

**Objetivo:** verificar que la distribución en failure domains es una propiedad del *scheduler* y no del Deployment, y que un PDB mal calibrado convierte una operación de mantenimiento en un bloqueo.

### Paso 3.1 — Confirmar la distribución inicial por zona

```bash
kubectl -n prod get pods -o custom-columns=\
'POD:.metadata.name,NODE:.spec.nodeName,ZONE:.spec.nodeName' --no-headers \
| while read -r p n _; do
    z=$(kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    printf '%-24s %-22s %s\n' "$p" "$n" "$z"
  done
```

```
web-5c9d7f8b64-4nqp2     platform-lab-worker    lab-a
web-5c9d7f8b64-8jt7x     platform-lab-worker2   lab-b
web-5c9d7f8b64-x2vlm     platform-lab-worker3   lab-c
```

### Paso 3.2 — Romper una zona y ver `DoNotSchedule` en acción

```bash
kubectl cordon platform-lab-worker3
kubectl taint node platform-lab-worker3 zone-outage=true:NoExecute
sleep 5
kubectl -n prod get pods
```

```
NAME                   READY   STATUS    RESTARTS   AGE
web-5c9d7f8b64-4nqp2   1/1     Running   0          6m
web-5c9d7f8b64-8jt7x   1/1     Running   0          6m
web-5c9d7f8b64-nkw9d   0/1     Pending   0          4s
```

```bash
kubectl -n prod describe pod -l app.kubernetes.io/name=web \
  | sed -n '/Events:/,$p' | grep -A3 FailedScheduling
```

```
  Warning  FailedScheduling  9s  default-scheduler  0/4 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  1 node(s) had untolerated taint {zone-outage: true},
  2 node(s) didn't match pod topology spread constraints.
  preemption: 0/4 nodes are available: 4 Preemption is not helpful for scheduling.
```

El pod queda `Pending` **a propósito**: con `whenUnsatisfiable: DoNotSchedule` y `maxSkew: 1`, meter la tercera réplica en `lab-a` o `lab-b` daría un skew de 2. El scheduler prefiere capacidad degradada antes que concentración de riesgo.

### Paso 3.3 — Comparar contra `ScheduleAnyway`

```bash
kubectl -n prod patch deploy web --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}
]'
kubectl -n prod rollout status deploy/web --timeout=120s
kubectl -n prod get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers
```

```
deployment.apps/web patched
deployment "web" successfully rolled out
web-6b4f8c9d55-2xhqp   platform-lab-worker
web-6b4f8c9d55-7rjkn   platform-lab-worker2
web-6b4f8c9d55-qz8mv   platform-lab-worker
```

Con `ScheduleAnyway` la constraint pasa de ser un *hard predicate* a un *scoring hint*: el scheduler la usa para puntuar nodos, pero nunca deja un pod sin ubicar. `lab-a` ahora concentra 2 de 3 réplicas.

### Paso 3.4 — Restaurar la zona y verificar que Kubernetes NO rebalancea

```bash
kubectl taint node platform-lab-worker3 zone-outage=true:NoExecute-
kubectl uncordon platform-lab-worker3
sleep 15
kubectl -n prod get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' --no-headers
```

```
web-6b4f8c9d55-2xhqp   platform-lab-worker
web-6b4f8c9d55-7rjkn   platform-lab-worker2
web-6b4f8c9d55-qz8mv   platform-lab-worker
```

La distribución desbalanceada persiste indefinidamente. El scheduler es **one-shot por pod**: decide en el momento del binding y jamás revisa esa decisión.

### Paso 3.5 — Probar el PDB contra un drain

```bash
kubectl -n prod patch deploy web --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"DoNotSchedule"}
]'
kubectl -n prod rollout status deploy/web --timeout=120s
kubectl -n prod get pdb web
```

```
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
web    2               N/A               1                     14m
```

```bash
kubectl drain platform-lab-worker --ignore-daemonsets --delete-emptydir-data --timeout=45s
```

```
node/platform-lab-worker cordoned
evicting pod prod/web-7d9c4b6f88-hg2wt
pod/web-7d9c4b6f88-hg2wt evicted
node/platform-lab-worker drained
```

Ahora forzá el bloqueo: subí el PDB a `minAvailable: 3` y drenaá una segunda zona.

```bash
kubectl -n prod patch pdb web --type=merge -p '{"spec":{"minAvailable":3}}'
kubectl -n prod get pdb web
kubectl drain platform-lab-worker2 --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

```
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
web    3               N/A               0                     16m

node/platform-lab-worker2 cordoned
evicting pod prod/web-7d9c4b6f88-p4knc
error when evicting pods/"web-7d9c4b6f88-p4knc" -n "prod" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
...
There are pending pods in node "platform-lab-worker2" when an error occurred: timed out waiting for the condition
```

```bash
kubectl -n prod patch pdb web --type=merge -p '{"spec":{"minAvailable":2}}'
kubectl uncordon platform-lab-worker platform-lab-worker2
```

### Preguntas de verificación

- **P3.1** — En el Paso 3.2 el mensaje dice `2 node(s) didn't match pod topology spread constraints`, y no `3`. ¿Por qué el control-plane no está en esa cuenta?
- **P3.2** — El Paso 3.4 demuestra que no hay rebalanceo automático. ¿Qué componente del ecosistema CNCF resuelve esto y por qué **no** es parte de kube-scheduler? Nombrá el riesgo operativo de activarlo sin PDBs bien puestos.
- **P3.3** — Con `minAvailable: 3` y 3 réplicas, `ALLOWED DISRUPTIONS` fue `0`. Explicá la fórmula que usa el disruption controller y por qué `maxUnavailable: 1` sería una definición más robusta ante cambios de escala.
- **P3.4** — El drain del Paso 3.5 falla, pero un `kubectl delete pod` sobre el mismo pod funcionaría. ¿Por qué el PDB no lo impide? ¿Qué implica eso para tu arquitectura de mantenimiento?
- **P3.5** — En un cluster real de 3 AZ con `maxSkew: 1` y `DoNotSchedule`, un HPA escala de 3 a 4 réplicas. ¿Qué pasa? ¿Y de 3 a 7 si una AZ está caída?
- **P3.6** — Durante un rolling update, los pods viejos y nuevos comparten el `labelSelector` de la constraint. ¿Qué distorsión produce eso en el cálculo de skew y qué campo la corrige?

---

## 4. Ejercicio 4 — Perfil de seguridad por environment con Pod Security Admission

**Objetivo:** implementar el patrón de *progressive hardening* (dev permisivo → prod restrictivo) y diagnosticar el modo de falla más confuso de PSA: el rechazo diferido a través de controladores.

### Paso 4.1 — Etiquetar cada namespace con su nivel

```bash
kubectl label ns dev \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline --overwrite

kubectl label ns staging \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite

kubectl label ns prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.32 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite

kubectl get ns dev staging prod \
  -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/warn
```

```
NAME      STATUS   AGE   ENFORCE      WARN
dev       Active   41m   privileged   baseline
staging   Active   41m   baseline     restricted
prod      Active   41m   restricted   restricted
```

### Paso 4.2 — Ver los tres comportamientos con el mismo pod

```yaml
# unsafe-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: unsafe
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        privileged: true
```

```bash
kubectl -n dev     apply -f unsafe-pod.yaml
kubectl -n staging apply -f unsafe-pod.yaml
kubectl -n prod    apply -f unsafe-pod.yaml
```

```
Warning: would violate PodSecurity "baseline:latest": privileged (container "app" must not set securityContext.privileged=true)
pod/unsafe created

Error from server (Forbidden): error when creating "unsafe-pod.yaml": pods "unsafe" is forbidden: violates PodSecurity "baseline:latest": privileged (container "app" must not set securityContext.privileged=true)

Error from server (Forbidden): error when creating "unsafe-pod.yaml": pods "unsafe" is forbidden: violates PodSecurity "restricted:v1.32": privileged (container "app" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Un solo manifiesto, tres resultados: `dev` avisa, `staging` bloquea lo peor, `prod` exige el perfil completo.

### Paso 4.3 — El modo de falla diferido

```bash
kubectl -n prod create deployment legacy --image=nginx:1.27-alpine
kubectl -n prod get deploy legacy
kubectl -n prod get rs -l app=legacy
```

```
Warning: would violate PodSecurity "restricted:v1.32": allowPrivilegeEscalation != false ...
deployment.apps/legacy created

NAME     READY   UP-TO-DATE   AVAILABLE   AGE
legacy   0/1     0            0           12s

NAME                DESIRED   CURRENT   READY   AGE
legacy-6d4b8f7c9    1         0         0       12s
```

El Deployment existe. El ReplicaSet existe. Pods, cero. La causa está un nivel más abajo:

```bash
kubectl -n prod describe rs -l app=legacy | sed -n '/Events:/,$p'
```

```
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  18s (x4 over 20s)  replicaset-controller  Error creating: pods "legacy-6d4b8f7c9-" is forbidden: violates PodSecurity "restricted:v1.32": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

```bash
kubectl -n prod get deploy legacy -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

```
Available=False MinimumReplicasUnavailable
Progressing=False ProgressDeadlineExceeded
```

### Paso 4.4 — Auditar un environment antes de endurecerlo

Antes de subir `staging` de `baseline` a `restricted`, medí el impacto en dry-run sin tocar nada:

```bash
kubectl label --dry-run=server --overwrite ns staging \
  pod-security.kubernetes.io/enforce=restricted
```

```
Warning: existing pods in namespace "staging" violate the new PodSecurity enforce level "restricted:latest"
Warning: unsafe: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/staging labeled (server dry run)
```

### Paso 4.5 — Limpieza parcial

```bash
kubectl -n dev delete pod unsafe --ignore-not-found
kubectl -n staging delete pod unsafe --ignore-not-found
kubectl -n prod delete deployment legacy --ignore-not-found
```

### Preguntas de verificación

- **P4.1** — En `prod` fijaste `enforce-version=v1.32` pero en `staging` quedó implícito `latest`. Explicá la diferencia y por qué pinnear la versión en producción es una decisión de arquitectura y no de gusto.
- **P4.2** — En el Paso 4.3, el `kubectl create deployment` mostró un `Warning` pero devolvió éxito. ¿Qué componente emitió ese warning, contra qué objeto se evaluó, y por qué el ReplicaSet controller no recibe el mismo trato?
- **P4.3** — Un pipeline de CI hace `kubectl apply -f deploy.yaml && echo OK`. Con el escenario del Paso 4.3, el pipeline reporta verde. Escribí el comando que lo convierte en un gate honesto.
- **P4.4** — PSA es *namespace-scoped* y se configura con labels. ¿Qué impide que el equipo de aplicación se auto-degrade a `privileged` en su propio namespace? Nombrá el mecanismo exacto.
- **P4.5** — PSA no puede expresar "solo imágenes del registry corporativo" ni "todo Ingress debe tener TLS". ¿Qué mecanismos nativos y qué proyectos CNCF cubren ese hueco, y en qué fase del pipeline de admisión actúan?

---

## 5. Ejercicio 5 — Ephemeral / preview environments, TTL y garbage collection

**Objetivo:** construir un environment efímero por pull request con expiración automática, y descubrir la clase de recursos que la eliminación del namespace **no** limpia.

### Paso 5.1 — Crear el environment efímero

```yaml
# preview-pr-42.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: preview-pr-42
  labels:
    env.platform.io/type: preview
    env.platform.io/source-ref: pr-42
    pod-security.kubernetes.io/enforce: baseline
  annotations:
    env.platform.io/owner: "team-storefront"
    env.platform.io/expires-at: "2026-08-06T09:00:00Z"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: preview-quota
  namespace: preview-pr-42
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "2"
    limits.memory: 4Gi
    pods: "10"
    services.loadbalancers: "0"
    persistentvolumeclaims: "2"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: preview-defaults
  namespace: preview-pr-42
spec:
  limits:
    - type: Container
      default: { cpu: 200m, memory: 256Mi }
      defaultRequest: { cpu: 50m, memory: 64Mi }
```

```bash
kubectl apply -f preview-pr-42.yaml
kubectl apply -k env-model/overlays/dev --dry-run=client -o yaml \
  | sed 's/namespace: dev/namespace: preview-pr-42/' \
  | kubectl apply -f -
kubectl -n preview-pr-42 get all
```

```
namespace/preview-pr-42 created
resourcequota/preview-quota created
limitrange/preview-defaults created
configmap/web-env-6t2hbc98mf created
service/web created
deployment.apps/web created

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-5c9d7f8b64-lm4rq   1/1     Running   0          9s

NAME          TYPE        CLUSTER-IP     PORT(S)   AGE
service/web   ClusterIP   10.96.204.11   80/TCP    9s

NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   1/1     1            1           9s
```

### Paso 5.2 — Crear el recurso cluster-scoped que acompaña al preview

Todo preview environment necesita que su ServiceAccount de CI pueda leer el namespace. Eso es un `ClusterRoleBinding`: **cluster-scoped**.

```yaml
# preview-pr-42-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: preview-pr-42-viewer
subjects:
  - kind: ServiceAccount
    name: default
    namespace: preview-pr-42
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f preview-pr-42-rbac.yaml
```

### Paso 5.3 — Borrar el environment y buscar la fuga

```bash
kubectl delete ns preview-pr-42 --wait=true
kubectl get clusterrolebinding preview-pr-42-viewer
```

```
namespace "preview-pr-42" deleted
NAME                    ROLE               AGE
preview-pr-42-viewer    ClusterRole/view   72s
```

El namespace desapareció; el ClusterRoleBinding sigue vivo, apuntando a un ServiceAccount que ya no existe. Multiplicá por 40 PRs por semana y tenés un cluster con miles de bindings huérfanos y una superficie de RBAC imposible de auditar.

### Paso 5.4 — Corregirlo con `ownerReferences`

```bash
kubectl apply -f preview-pr-42.yaml
NS_UID=$(kubectl get ns preview-pr-42 -o jsonpath='{.metadata.uid}')
echo "UID=$NS_UID"

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: preview-pr-42-viewer
  ownerReferences:
    - apiVersion: v1
      kind: Namespace
      name: preview-pr-42
      uid: ${NS_UID}
      blockOwnerDeletion: false
subjects:
  - kind: ServiceAccount
    name: default
    namespace: preview-pr-42
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF
```

```bash
kubectl delete ns preview-pr-42 --wait=true
sleep 10
kubectl get clusterrolebinding preview-pr-42-viewer
```

```
namespace "preview-pr-42" deleted
Error from server (NotFound): clusterrolebindings.rbac.authorization.k8s.io "preview-pr-42-viewer" not found
```

### Paso 5.5 — El reaper de TTL

```yaml
# preview-reaper.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: preview-reaper
  namespace: platform-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: preview-reaper
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: preview-reaper
subjects:
  - kind: ServiceAccount
    name: preview-reaper
    namespace: platform-system
roleRef:
  kind: ClusterRole
  name: preview-reaper
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: preview-reaper
  namespace: platform-system
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: preview-reaper
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: reaper
              image: docker.io/bitnami/kubectl:1.32
              command: ["/bin/bash", "-c"]
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: 25m, memory: 64Mi }
                limits:   { cpu: 200m, memory: 128Mi }
              args:
                - |
                  set -euo pipefail
                  now=$(date -u +%s)
                  kubectl get ns -l env.platform.io/type=preview \
                    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.env\.platform\.io/expires-at}{"\n"}{end}' \
                  > /tmp/previews
                  while IFS=$'\t' read -r ns expires; do
                    if [ -z "${ns:-}" ]; then continue; fi
                    if [ -z "${expires:-}" ]; then
                      echo "SKIP  $ns (sin annotation expires-at)"
                      continue
                    fi
                    exp=$(date -u -d "$expires" +%s)
                    if [ "$now" -ge "$exp" ]; then
                      echo "REAP  $ns (venció $expires)"
                      kubectl delete ns "$ns" --wait=false
                    else
                      echo "KEEP  $ns (vence $expires)"
                    fi
                  done < /tmp/previews
```

> **Nota de imagen.** `bitnami/kubectl` es Debian-based, así que trae `bash` y `date` de GNU coreutils (`date -d "<ISO8601>"` funciona). `registry.k8s.io/kubectl` es distroless: no tiene shell y este script no correría; ahí tendrías que mover la lógica a un ConfigMap y usar `command: ["kubectl"]` con args puntuales. En Alpine, el `date` de busybox no parsea ISO 8601 con `-d`.

```bash
kubectl apply -f preview-reaper.yaml
kubectl apply -f preview-pr-42.yaml
kubectl annotate ns preview-pr-42 --overwrite \
  env.platform.io/expires-at="2020-01-01T00:00:00Z"

kubectl -n platform-system create job --from=cronjob/preview-reaper reaper-manual
kubectl -n platform-system wait --for=condition=complete job/reaper-manual --timeout=90s
kubectl -n platform-system logs job/reaper-manual
```

```
job.batch/reaper-manual created
job.batch/reaper-manual condition met
REAP  preview-pr-42 (venció 2020-01-01T00:00:00Z)
```

```bash
kubectl get ns preview-pr-42
```

```
Error from server (NotFound): namespaces "preview-pr-42" not found
```

### Preguntas de verificación

- **P5.1** — El `ownerReference` del Paso 5.4 va de un objeto cluster-scoped (`ClusterRoleBinding`) a otro cluster-scoped (`Namespace`). ¿Funcionaría al revés — un `ClusterRoleBinding` cuyo owner es un `Deployment` del namespace? Enunciá la regla exacta de Kubernetes.
- **P5.2** — Pusiste `blockOwnerDeletion: false`. ¿Qué habría cambiado con `true`, y qué permiso RBAC extra exige ese campo?
- **P5.3** — El reaper usa `--wait=false`. ¿Por qué es la decisión correcta para un CronJob, y qué falla en cascada podría causar `--wait=true`?
- **P5.4** — Un namespace queda en `Terminating` para siempre. Describí el mecanismo (`spec.finalizers` vs `metadata.finalizers`) y el comando de diagnóstico correcto — no el `patch` que borra el finalizer a la fuerza.
- **P5.5** — La quota del preview fija `services.loadbalancers: "0"`. ¿Qué decisión de arquitectura de costos y de red codifica ese cero, y cómo expondrías el preview a un reviewer humano sin LoadBalancer?
- **P5.6** — El reaper tiene `delete` sobre namespaces a nivel cluster. Enumerá dos controles que pondrías para que ese ServiceAccount no pueda borrar `prod`.

---

## 6. Ejercicio 6 — Cluster-as-environment: management plane vs workload plane con Cluster API

**Objetivo:** materializar la arquitectura hub-and-spoke, donde los clusters de environment son objetos declarativos dentro de un cluster de management, y entender la diferencia entre control plane de Kubernetes y control plane de la plataforma.

> Este ejercicio crea un cluster de kind adicional y descarga imágenes de proveedores. Requiere ~4 GB de RAM libre y acceso a Internet.

### Paso 6.1 — Cluster de management con acceso al socket de Docker

```yaml
# capi-mgmt.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: capi-mgmt
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock
```

```bash
kind create cluster --config capi-mgmt.yaml
kubectl config use-context kind-capi-mgmt
```

### Paso 6.2 — Instalar el plano de control de la plataforma

```bash
export CLUSTER_TOPOLOGY=true
clusterctl init --infrastructure docker
```

```
Fetching providers
Installing cert-manager version="v1.16.2"
Waiting for cert-manager to be available...
Installing provider="cluster-api" version="v1.9.4" targetNamespace="capi-system"
Installing provider="bootstrap-kubeadm" version="v1.9.4" targetNamespace="capi-kubeadm-bootstrap-system"
Installing provider="control-plane-kubeadm" version="v1.9.4" targetNamespace="capi-kubeadm-control-plane-system"
Installing provider="infrastructure-docker" version="v1.9.4" targetNamespace="capd-system"

Your management cluster has been initialized successfully!
```

### Paso 6.3 — Observar qué API acaba de aparecer

```bash
kubectl api-resources --api-group=cluster.x-k8s.io
kubectl get crd | grep -c 'x-k8s.io'
```

```
NAME                     SHORTNAMES   APIVERSION                     NAMESPACED   KIND
clusterclasses           cc           cluster.x-k8s.io/v1beta1       true         ClusterClass
clusterresourcesets                   cluster.x-k8s.io/v1beta1       true         ClusterResourceSet
clusters                 cl           cluster.x-k8s.io/v1beta1       true         Cluster
machinedeployments       md           cluster.x-k8s.io/v1beta1       true         MachineDeployment
machinehealthchecks      mhc          cluster.x-k8s.io/v1beta1       true         MachineHealthCheck
machinepools             mp           cluster.x-k8s.io/v1beta1       true         MachinePool
machines                 ma           cluster.x-k8s.io/v1beta1       true         Machine
machinesets              ms           cluster.x-k8s.io/v1beta1       true         MachineSet
28
```

`Cluster`, `MachineDeployment`, `MachineSet`, `Machine` son la misma jerarquía conceptual que `Deployment`/`ReplicaSet`/`Pod`, un nivel más abajo: la infraestructura pasó a ser un recurso reconciliado.

### Paso 6.4 — Declarar un environment como Cluster

```bash
clusterctl generate cluster env-staging \
  --flavor development \
  --kubernetes-version v1.32.0 \
  --control-plane-machine-count=1 \
  --worker-machine-count=2 \
  > env-staging.yaml

grep -E '^kind:' env-staging.yaml | sort | uniq -c
```

```
      1 kind: Cluster
      1 kind: DockerCluster
      1 kind: DockerMachineTemplate
      1 kind: KubeadmConfigTemplate
      1 kind: KubeadmControlPlane
      1 kind: MachineDeployment
      1 kind: DockerMachineTemplate
```

```bash
kubectl apply -f env-staging.yaml
kubectl get cluster
```

```
NAME           CLUSTERCLASS   PHASE          AGE   VERSION
env-staging                   Provisioning   8s    
```

### Paso 6.5 — Observar la reconciliación

```bash
watch -n5 clusterctl describe cluster env-staging
```

Después de ~3 minutos:

```
NAME                                   READY  SEVERITY  REASON  SINCE  MESSAGE
Cluster/env-staging                    True                     42s
├─ClusterInfrastructure - DockerCluster/env-staging  True       3m11s
├─ControlPlane - KubeadmControlPlane/env-staging-control-plane  True  42s
│ └─Machine/env-staging-control-plane-k7xql          True       58s
└─Workers
  └─MachineDeployment/env-staging-md-0               False  Warning  WaitingForAvailableMachines  2m4s
    └─2 Machines...                                  True       61s
```

El `MachineDeployment` sigue en `False` porque **el workload cluster no tiene CNI**. Cluster API instala Kubernetes; la red es decisión de la plataforma:

```bash
clusterctl get kubeconfig env-staging > env-staging.kubeconfig
export KUBECONFIG_WL=env-staging.kubeconfig

kubectl --kubeconfig="$KUBECONFIG_WL" get nodes
```

```
NAME                                STATUS     ROLES           AGE     VERSION
env-staging-control-plane-k7xql     NotReady   control-plane   2m14s   v1.32.0
env-staging-md-0-nvx4d-9wq2p        NotReady   <none>          105s    v1.32.0
env-staging-md-0-nvx4d-hkr8t        NotReady   <none>          105s    v1.32.0
```

```bash
kubectl --kubeconfig="$KUBECONFIG_WL" apply -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml

sleep 60
kubectl --kubeconfig="$KUBECONFIG_WL" get nodes
```

```
NAME                                STATUS   ROLES           AGE     VERSION
env-staging-control-plane-k7xql     Ready    control-plane   4m22s   v1.32.0
env-staging-md-0-nvx4d-9wq2p        Ready    <none>          3m53s   v1.32.0
env-staging-md-0-nvx4d-hkr8t        Ready    <none>          3m53s   v1.32.0
```

### Paso 6.6 — Cambiar la forma del environment desde el hub

```bash
kubectl scale machinedeployment env-staging-md-0 --replicas=3
kubectl get machines
```

```
machinedeployment.cluster.x-k8s.io/env-staging-md-0 scaled

NAME                             CLUSTER       NODENAME                        PHASE         AGE   VERSION
env-staging-control-plane-k7xql  env-staging   env-staging-control-plane-k7xql Running       6m    v1.32.0
env-staging-md-0-nvx4d-9wq2p     env-staging   env-staging-md-0-nvx4d-9wq2p    Running       5m    v1.32.0
env-staging-md-0-nvx4d-hkr8t     env-staging   env-staging-md-0-nvx4d-hkr8t    Running       5m    v1.32.0
env-staging-md-0-nvx4d-t6pmc     env-staging                                   Provisioning  6s    v1.32.0
```

### Paso 6.7 — Auto-reparación declarativa

```yaml
# mhc.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineHealthCheck
metadata:
  name: env-staging-workers-unhealthy
spec:
  clusterName: env-staging
  maxUnhealthy: 40%
  nodeStartupTimeout: 10m
  selector:
    matchLabels:
      cluster.x-k8s.io/deployment-name: env-staging-md-0
  unhealthyConditions:
    - type: Ready
      status: Unknown
      timeout: 300s
    - type: Ready
      status: "False"
      timeout: 300s
```

```bash
kubectl apply -f mhc.yaml
kubectl get machinehealthcheck
```

```
NAME                            CLUSTER       EXPECTEDMACHINES   MAXUNHEALTHY   CURRENTHEALTHY   AGE
env-staging-workers-unhealthy   env-staging   3                  40%            3                7s
```

### Paso 6.8 — Verificar el boundary del hub

```bash
kubectl get pods -A --kubeconfig="$KUBECONFIG_WL" | grep -c capi
kubectl get cluster --kubeconfig="$KUBECONFIG_WL"
```

```
0
error: the server doesn't have a resource type "cluster"
```

El workload cluster no sabe que es gestionado. Toda la lógica de plataforma vive en el hub: eso es la separación entre management plane y workload plane.

### Preguntas de verificación

- **P6.1** — El Paso 6.5 muestra nodos `NotReady` hasta instalar Calico. ¿Por qué Cluster API deliberadamente no instala un CNI, y qué recurso de CAPI existe para automatizarlo sin acoplar el provider?
- **P6.2** — Compará el radio de impacto de un CRD roto (Ejercicio 1, Paso 1.3) en el modelo namespace-as-environment contra este modelo cluster-as-environment. Ahora nombrá tres costos concretos que pagás por esa reducción.
- **P6.3** — `clusterctl move` hace pivot de los objetos CAPI de un cluster a otro. Explicá por qué existe esa operación y qué falla catastróficamente si el management cluster se pierde sin pivot ni backup.
- **P6.4** — El `MachineHealthCheck` tiene `maxUnhealthy: 40%`. ¿Qué pasa si el 60% de los nodos falla a la vez? Explicá por qué ese circuit breaker es correcto.
- **P6.5** — En el Paso 6.8 el workload cluster no ve recursos CAPI. ¿Qué credencial vive en el hub y hace que esa asimetría sea el activo más sensible de la plataforma? Nombrá el objeto y su convención de nombre.
- **P6.6** — Un `ClusterClass` permite definir "el template de environment" y crear Clusters con solo unas variables. Relacioná esto con *golden path* y explicá qué gana el equipo de aplicación y qué gana el equipo de plataforma.

---

## 7. Ejercicio 7 — Runbook: mapear la arquitectura de un environment desconocido

**Objetivo:** en menos de cinco minutos, producir un inventario de arquitectura de un cluster que nunca viste. Es la habilidad diagnóstica que el tema 1.3 evalúa.

### Paso 7.1 — Volver al cluster de laboratorio

```bash
kubectl config use-context kind-platform-lab
```

### Paso 7.2 — Capa de cómputo y failure domains

```bash
kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,'\
'INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,'\
'RUNTIME:.status.nodeInfo.containerRuntimeVersion,'\
'KERNEL:.status.nodeInfo.kernelVersion,KUBELET:.status.nodeInfo.kubeletVersion'
```

```
NODE                         ZONE    INSTANCE   RUNTIME             KERNEL                  KUBELET
platform-lab-control-plane   <none>  <none>     containerd://2.0.2  7.1.4-202.fc44.x86_64   v1.32.2
platform-lab-worker          lab-a   <none>     containerd://2.0.2  7.1.4-202.fc44.x86_64   v1.32.2
platform-lab-worker2         lab-b   <none>     containerd://2.0.2  7.1.4-202.fc44.x86_64   v1.32.2
platform-lab-worker3         lab-c   <none>     containerd://2.0.2  7.1.4-202.fc44.x86_64   v1.32.2
```

### Paso 7.3 — Taints y capacidad reservada

```bash
kubectl get nodes -o json | jq -r '
  .items[] | "\(.metadata.name)\ttaints=\(.spec.taints // [] | map(.key+"="+((.value//"")+":")+.effect) | join(","))\tallocatable_cpu=\(.status.allocatable.cpu)\tcapacity_cpu=\(.status.capacity.cpu)"'
```

```
platform-lab-control-plane	taints=node-role.kubernetes.io/control-plane=:NoSchedule	allocatable_cpu=8	capacity_cpu=8
platform-lab-worker	taints=	allocatable_cpu=8	capacity_cpu=8
platform-lab-worker2	taints=	allocatable_cpu=8	capacity_cpu=8
platform-lab-worker3	taints=	allocatable_cpu=8	capacity_cpu=8
```

### Paso 7.4 — Extensiones del API server: la parte que no es Kubernetes vanilla

```bash
echo "--- CRDs por grupo ---"
kubectl get crd -o jsonpath='{range .items[*]}{.spec.group}{"\n"}{end}' | sort | uniq -c | sort -rn

echo "--- APIs agregadas (no locales) ---"
kubectl get apiservices -o json | jq -r '.items[] | select(.spec.service != null)
  | "\(.metadata.name)\t-> \(.spec.service.namespace)/\(.spec.service.name)\tavailable=\((.status.conditions[]? | select(.type=="Available") | .status))"'

echo "--- Admission webhooks ---"
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o custom-columns='KIND:.kind,NAME:.metadata.name' --no-headers
```

```
--- CRDs por grupo ---
      1 fintech.platform.io
--- APIs agregadas (no locales) ---
--- Admission webhooks ---
```

Un cluster de kind limpio no tiene webhooks. En un cluster real esta salida es la lista de todo lo que puede rechazar o reescribir silenciosamente tus manifiestos — el primer lugar a mirar cuando "apliqué X y quedó Y".

### Paso 7.5 — Almacenamiento y red

```bash
kubectl get storageclass -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,BINDING:.volumeBindingMode,'\
'EXPAND:.allowVolumeExpansion,RECLAIM:.reclaimPolicy,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'

kubectl get csidrivers
kubectl get ingressclass,gatewayclass 2>/dev/null
kubectl -n kube-system get daemonset
```

```
NAME         PROVISIONER             BINDING              EXPAND   RECLAIM   DEFAULT
standard     rancher.io/local-path   WaitForFirstConsumer  <none>  Delete    true

No resources found
No resources found
NAME         DESIRED   CURRENT   READY   NODE SELECTOR            AGE
kindnet      4         4         4       <none>                   72m
kube-proxy   4         4         4       kubernetes.io/os=linux   72m
```

`volumeBindingMode: WaitForFirstConsumer` es un dato de arquitectura de primer orden: acopla la decisión de scheduling a la de almacenamiento. Con `Immediate`, un PV se crea en `lab-a` y clava ahí a todos los pods que lo monten, rompiendo cualquier topology spread.

### Paso 7.6 — Verificar si las NetworkPolicy se aplican de verdad

Aplicar una NetworkPolicy y aplicarla **no** son lo mismo: la API la acepta siempre; hacerla cumplir es trabajo del CNI.

```bash
kubectl apply -n prod -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
EOF

kubectl -n dev run probe --rm -it --restart=Never --image=curlimages/curl:8.11.1 \
  --command -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
  http://web.prod.svc.cluster.local
```

Dos resultados posibles, ambos informativos:

```
000
command terminated with exit code 28      # el CNI aplica la política — correcto
```

```
200
pod "probe" deleted                        # el CNI IGNORA la política — falso sentido de seguridad
```

```bash
kubectl -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Las versiones antiguas de `kindnetd` no implementan NetworkPolicy en absoluto. Si el resultado fue `200`, tu política existe en etcd y no protege nada.

### Paso 7.7 — Salud del control plane y control de admisión de carga

```bash
kubectl get --raw='/readyz?verbose' | tail -20
kubectl get flowschemas -o custom-columns=\
'NAME:.metadata.name,PL:.spec.priorityLevelConfiguration.name,MATCH:.spec.matchingPrecedence' --no-headers | head -8
kubectl get priorityclasses
```

```
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]poststarthook/apiservice-openapi-controller ok
[+]shutdown ok
readyz check passed

exempt                            exempt                     1
probes                            exempt                     2
system-leader-election            leader-election            100
workload-leader-election          leader-election            200
system-node-high                  node-high                  400
system-nodes                      system                     500
kube-controller-manager           workload-high              800
kube-scheduler                    workload-high              800

NAME                      VALUE        GLOBAL-DEFAULT   AGE
system-cluster-critical   2000000000   false            73m
system-node-critical      2000001000   false            73m
```

### Paso 7.8 — La trampa de contexto

```bash
kubectl config get-contexts
```

```
CURRENT   NAME              CLUSTER           AUTHINFO          NAMESPACE
          kind-capi-mgmt    kind-capi-mgmt    kind-capi-mgmt    
*         kind-platform-lab kind-platform-lab kind-platform-lab 
```

```bash
kubectl config set-context --current --namespace=prod
kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'
```

```
Context "kind-platform-lab" modified.
prod
```

Un shell cuyo contexto activo es `prod` y cuyo prompt no lo dice es la causa raíz más común de incidentes de plataforma. El default namespace por contexto y un prompt que lo refleje (`kube-ps1`, `starship`) son controles de arquitectura, no cosmética.

### Preguntas de verificación

- **P7.1** — La salida del Paso 7.4 está vacía en kind. En un cluster de producción con 30 CRDs y 6 webhooks, ¿cuál es el riesgo de disponibilidad concreto de un `ValidatingWebhookConfiguration` con `failurePolicy: Fail` cuyo backend está caído? ¿Y qué campo lo acota?
- **P7.2** — `WaitForFirstConsumer` vs `Immediate`: describí el modo de falla exacto de `Immediate` en un cluster multi-AZ con topology spread constraints.
- **P7.3** — El Paso 7.6 puede devolver `200`. Escribí las tres verificaciones que hacés para confirmar que una NetworkPolicy realmente se aplica en un cluster nuevo, antes de confiar en ella como boundary de environment.
- **P7.4** — API Priority and Fairness (`flowschemas`) es infraestructura de aislamiento del API server. ¿Cómo se relaciona con la separación de environments cuando `dev` y `prod` comparten cluster? Nombrá el síntoma que produce su ausencia.
- **P7.5** — Escribí el comando de una línea que responde "¿este cluster corre alguna versión de Kubernetes cuyos nodos estén desalineados con el control plane?" y explicá la regla de version skew que estás verificando.
- **P7.6** — Con la salida de los pasos 7.2–7.7, redactá en tres frases el veredicto de arquitectura del cluster: ¿es apto para alojar `prod` y `dev` simultáneamente? Justificá con evidencia de las salidas.

---

## 8. Limpieza

```bash
kubectl config use-context kind-platform-lab
kubectl delete ns dev staging prod platform-system --ignore-not-found --wait=false
kubectl delete crd paymentgateways.fintech.platform.io --ignore-not-found
kubectl delete clusterrolebinding preview-pr-42-viewer preview-reaper --ignore-not-found
kubectl delete clusterrole preview-reaper --ignore-not-found

# Ejercicio 6: borrar el Cluster ANTES que el management cluster
kubectl config use-context kind-capi-mgmt
kubectl delete cluster env-staging --wait=true --timeout=5m

kind delete cluster --name capi-mgmt
kind delete cluster --name platform-lab
docker ps -a --filter 'name=env-staging' --format '{{.Names}}'   # debe salir vacío
```

> **Advertencia.** Si borrás el management cluster antes que el `Cluster`, los contenedores del workload cluster quedan huérfanos: nadie reconcilia su borrado. Es la versión de laboratorio de dejar VMs pagas corriendo en la nube.

---

## Respuestas

<details>
<summary><strong>Desplegar respuestas completas</strong></summary>

### Ejercicio 0

**R0.1** — No arrancaría, o mejor dicho: el kubelet no lograría auto-asignarse esa label. El admission plugin **NodeRestriction** (habilitado por defecto en kubeadm y en todo cluster serio) impide que un kubelet modifique labels de su propio objeto Node bajo los prefijos `kubernetes.io/` y `k8s.io/`, salvo una allowlist cerrada: `kubernetes.io/hostname`, `kubernetes.io/os`, `kubernetes.io/arch`, `topology.kubernetes.io/zone`, `topology.kubernetes.io/region`, `node.kubernetes.io/instance-type` y los prefijos `kubelet.kubernetes.io/` y `node.kubernetes.io/`. `node-restriction.kubernetes.io/*` está explícitamente reservado para lo contrario: son labels que **solo** un administrador puede poner, precisamente para que un nodo comprometido no pueda auto-declararse `tier=prod` y atraer los pods de producción hacia sí. Esa es la razón de ser de la restricción: sin ella, comprometer un nodo de `dev` bastaría para robar las cargas de `prod` vía nodeSelector.

**R0.2** — El nodo control-plane no participa del cálculo de skew para esa topología. Los pods sin la label del `topologyKey` en su nodo se excluyen del cómputo, y además el control-plane tiene el taint `node-role.kubernetes.io/control-plane:NoSchedule`, que lo saca del conjunto de nodos candidatos. Práctica: el dominio de fallo efectivo son tres zonas con un worker cada una. Ojo con el caso general: un nodo **sin** la label de topología y **sin** taint es un agujero — con `whenUnsatisfiable: DoNotSchedule` los pods jamás irán ahí (queda fuera del dominio), y desde 1.25 `nodeTaintsPolicy`/`nodeAffinityPolicy` permiten controlar explícitamente si taints y afinidad se consideran al calcular el skew.

**R0.3** — Porque la topología es una propiedad **descubierta** de la infraestructura, no declarada por un operador. Si la pone un runbook manual: (a) un nodo nuevo del autoscaler nace sin label y se convierte en un failure domain fantasma o en un agujero de scheduling; (b) la label puede quedar desincronizada con la realidad física tras una migración, y todo tu topology spread pasa a distribuir sobre una mentira — el peor fallo posible, porque es silencioso y solo se manifiesta durante el outage real de la AZ; (c) no es reproducible ni auditable. En cloud, el cloud-controller-manager las deriva de metadata del proveedor; on-prem, del inventario. La regla de plataforma: **el estado de la infraestructura se descubre, no se transcribe**.

---

### Ejercicio 1

**R1.1** — El `scope: Namespaced` gobierna dónde viven las **instancias** (`PaymentGateway`), no dónde vive la **definición**. El `CustomResourceDefinition` es cluster-scoped: hay exactamente uno por cluster, y su `openAPIV3Schema` es un contrato global que el API server aplica en la fase de validación a toda instancia, en todo namespace. Agregar `merchantId` a `required` es un cambio incompatible de esquema aplicado atómicamente a los tres environments. El objeto `checkout` de `prod` no se borró ni se modificó — quedó en etcd tal cual — pero pasó a ser irreconciliable: `apply`, `patch` y cualquier otra escritura que revalide el objeto ahora fallan. Es la clase de incidente que el modelo namespace-as-environment no puede prevenir con ningún RBAC de namespace, porque el permiso involucrado (`customresourcedefinitions`) es cluster-scoped.

**R1.2** — Tres ejemplos con su mecanismo:

1. **`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`** — un webhook con `failurePolicy: Fail` y un `rules` demasiado amplio (por ejemplo `resources: ["*"]`, `namespaceSelector` ausente) intercepta escrituras de **todos** los namespaces. Si su backend está caído, todo el cluster deja de aceptar creaciones. Blast radius total, y a menudo se lleva puesto el propio pod del webhook, produciendo un deadlock que solo se rompe borrando la configuración del webhook.
2. **`PriorityClass`** — es cluster-scoped y su `value` participa de la **preemption**. Un equipo que crea `PriorityClass value: 1000000` para "que sus pods de dev arranquen rápido" hace que el scheduler desaloje pods de producción de menor prioridad cuando falta capacidad. Sin `ResourceQuota` con `scopeSelector` sobre PriorityClass, no hay nada que lo impida.
3. **`StorageClass` / `CSIDriver`** — cambiar el `reclaimPolicy` por defecto de `Retain` a `Delete`, o actualizar el CSI driver como DaemonSet en todos los nodos, afecta simultáneamente el almacenamiento de todos los environments. Un rollout fallido del driver deja PVs sin montar en producción y en desarrollo al mismo tiempo.

Se suman: `Node` (kernel, runtime y presión de recursos compartidos — el noisy neighbour real ocurre en el cgroup del nodo, no en el namespace), `APIService` (un agregado caído rompe `kubectl get` de recursos enteros), `IngressClass` y las `FlowSchema` de APF.

**R1.3** — Lo rechaza el **admission controller `ResourceQuota`**, en la fase de **validating admission**, después de mutating admission y después de la validación de esquema. El mecanismo: cuando un `ResourceQuota` del namespace declara `requests.cpu` o `limits.cpu` en su `hard`, el controller exige que **todo** pod nuevo del namespace especifique ese recurso — no puede contabilizar contra un límite un pod cuyo consumo es indefinido. El error menciona `limits.cpu` porque tu quota incluía `limits.cpu: "8"`, no porque vos lo hayas pedido: la quota convierte cada dimensión que enumera en un campo obligatorio. Por eso `ResourceQuota` y `LimitRange` son inseparables en un environment: `LimitRange` corre en **mutating** admission (antes) e inyecta los defaults, de modo que cuando `ResourceQuota` valida, el pod ya tiene los campos. Sin `LimitRange`, la quota rompe todos los workloads que no declaren recursos explícitamente — incluidos los Jobs de terceros y los charts que no los traen.

**R1.4** — Los pods **sin** `priorityClassName: platform-critical` son completamente invisibles para esa quota: no la consumen y no son limitados por ella. Un `scopeSelector` filtra qué objetos entran en el cómputo. El efecto arquitectónico es doble y es lo que la hace interesante: (a) limita a 8 la cantidad de pods que pueden usar la clase de prioridad alta, evitando que un equipo se declare crítico y monopolice la capacidad preemptable; (b) por la mecánica de scopes de PriorityClass, si existe *alguna* quota con scope `PriorityClass` para un valor dado, un pod que use esa clase en un namespace **sin** la quota correspondiente es rechazado. Eso convierte a la PriorityClass en un recurso **concedido explícitamente por la plataforma**, no tomado por el consumidor: es la diferencia entre un límite de capacidad y un boundary de arquitectura.

**R1.5** — El síntoma clásico de la interacción quota↔LimitRange. El Deployment se admite (es solo un template, no consume quota de pods), pero el ReplicaSet controller no logra crear pods. El comando:

```bash
kubectl -n <ns> describe replicaset -l app=<app> | sed -n '/Events:/,$p'
```

o directamente sobre eventos:

```bash
kubectl -n <ns> get events --field-selector reason=FailedCreate \
  --sort-by=.lastTimestamp -o wide
```

Vas a ver `Error creating: pods "..." is forbidden: failed quota: ...`. Complementá con `kubectl -n <ns> describe resourcequota` para ver `Used` vs `Hard`. La lección general: **cuando un objeto de nivel N se crea pero el de nivel N-1 no aparece, los eventos están en el controlador intermedio, no en el objeto que aplicaste**.

---

### Ejercicio 2

**R2.1** — `kubectl diff` devuelve `0` si no hay diferencias, **`1` si hay diferencias**, y `>1` ante un error real (conexión, permisos, manifiesto inválido). Ese contrato — heredado de `diff(1)` de POSIX — lo hace usable directamente como gate: `kubectl diff -k overlays/prod` en un job de CI falla el pipeline exactamente cuando el estado vivo divergió del deseado. Es importante distinguir `1` de `>1`: un script que trate cualquier no-cero como drift reportará "drift" cuando en realidad perdió conectividad con el API server, que es un fallo operativo distinto y peor.

**R2.2** — Son dos modelos de propiedad diferentes:

- **Client-side (3-way merge)**: `kubectl` compara (1) el manifiesto nuevo, (2) el estado vivo, y (3) la anotación `kubectl.kubernetes.io/last-applied-configuration`, que guarda el último manifiesto que *este* flujo aplicó. La detección de campos borrados sale de (3): si un campo estaba en la anotación y no está en el manifiesto nuevo, se elimina. Su debilidad: la anotación es una sola, global por objeto, y no sabe nada de otros actores. Dos controladores que hagan client-side apply se pisan mutuamente sin aviso, y la anotación tiene el límite de tamaño de metadata.
- **Server-side apply**: el API server mantiene `metadata.managedFields`, un registro **por campo y por field manager** de quién es dueño de qué. Un `Apply` solo puede modificar campos que le pertenecen o que no pertenecen a nadie; tocar un campo ajeno produce el conflicto explícito del Paso 2.8. Los campos que desaparecen del manifiesto y eran propiedad del manager se eliminan.

Ambos detectan campos borrados, pero por vías distintas; SSA es el único que además te dice **quién más está escribiendo** el objeto, que es exactamente el dato que necesitás en una plataforma con varios reconciliadores (GitOps + HPA + operadores). Por eso `kubectl apply --server-side` es el default recomendado para plataformas y `--field-manager` debe ser un nombre estable y significativo.

**R2.3** — El sufijo hash es una función determinística del **contenido** del ConfigMap, y `kustomize` reescribe todas las referencias (`envFrom`, `volumes.configMap.name`) para apuntar al nombre con hash. Resuelve dos problemas de environments: (1) **inmutabilidad del artefacto de configuración** — el mismo hash implica la misma configuración, en cualquier environment y en cualquier momento, lo que hace comparable un rollout entre `staging` y `prod`; (2) **rollout automático ante cambio de config** — cambiar `LOG_LEVEL` produce un nombre nuevo, lo que cambia el `podTemplate` del Deployment, lo que dispara un rolling update. Sin el hash, editar un ConfigMap deja los pods viejos corriendo con la config vieja hasta el próximo restart, y ese desfase es una de las divergencias silenciosas más difíciles de diagnosticar. Contrapartida: los ConfigMaps huérfanos se acumulan; hay que podarlos (`--prune` con label selector, o el pruning del reconciliador GitOps).

**R2.4** — No son redundantes: gobiernan disrupciones distintas.

- `maxUnavailable: 0` es del **Deployment controller** y aplica solo a **actualizaciones deliberadas del propio Deployment** (cambio de imagen, de config). Garantiza que durante un rolling update siempre haya 3 pods listos, creando el nuevo antes de matar el viejo (por eso necesita `maxSurge: 1` y capacidad libre).
- El **PDB** es del **disruption controller** y aplica a **disrupciones voluntarias externas**: `kubectl drain`, el cluster-autoscaler retirando un nodo, un upgrade de nodos, un operador de mantenimiento. Todos esos actores llaman a la **Eviction API** (`pods/eviction`), que consulta el PDB y devuelve `429 Too Many Requests` si la evicción violaría el presupuesto.

Un Deployment con `maxUnavailable: 0` y sin PDB queda perfectamente protegido durante sus deploys y completamente indefenso ante un drain simultáneo de dos nodos. La inversa también falla. Se necesitan los dos.

**R2.5** — Dos argumentos técnicos:

1. **La promoción por merge arrastra las diferencias de environment.** Con branch-per-environment, promover de `staging` a `prod` es un merge, y ese merge acarrea inevitablemente los commits que ajustaban réplicas, recursos o endpoints de `staging`. Para evitarlo hay que hacer cherry-picks selectivos, que es exactamente el proceso manual y propenso a error que GitOps venía a eliminar. Con directory-per-environment, promover es un cambio de una línea (el tag o digest de la imagen) en un solo archivo, revisable en un diff de tres líneas.
2. **Los conflictos permanentes ocultan el drift real.** Las ramas divergen para siempre por diseño, así que `git diff staging prod` siempre muestra ruido y nunca es una respuesta útil a "¿qué diferencia hay hoy entre staging y prod?". En el modelo de directorios, `diff <(kubectl kustomize overlays/staging) <(kubectl kustomize overlays/prod)` responde esa pregunta exactamente y de forma automatizable — es lo que hiciste en el Paso 2.4. Además, un cambio en `base/` se propaga a todos los environments en un solo commit atómico y revisable, en vez de N merges con N oportunidades de resolver un conflicto de forma distinta en cada environment.

**R2.6** — El escenario: el HPA es dueño legítimo de `.spec.replicas` (es su función), y el reconciliador GitOps corre con `--force-conflicts`. Cada reconciliación (cada 3 minutos en Argo CD por defecto) arrebata la propiedad del campo y lo devuelve al valor del Git — típicamente 3. El HPA vuelve a escalar a 20 porque la carga lo justifica. El resultado es un flapping permanente entre 3 y 20 réplicas: latencia oscilante, HPA saturado de eventos, y capacidad que aparece y desaparece. La solución correcta no es `--force-conflicts` sino **excluir el campo del manifiesto** (no declarar `replicas` cuando hay HPA) o usar el mecanismo de ignore del reconciliador (`ignoreDifferences` en Argo CD). `--force-conflicts` es la herramienta para una intervención puntual y consciente de un humano recuperando propiedad tras un cambio imperativo, no un default de automatización.

---

### Ejercicio 3

**R3.1** — Porque un nodo aparece en exactamente una categoría del mensaje de `FailedScheduling`: el scheduler reporta el **primer predicado** que descartó a cada nodo. El control-plane fue descartado antes de llegar a la evaluación de topology spread, por el filtro de taints (`TaintToleration`), y por eso figura en `1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }`. `platform-lab-worker3` fue descartado por el taint `zone-outage`. Quedaron `worker` y `worker2` como únicos nodos que llegaron al filtro `PodTopologySpread` y fallaron ahí: de ahí el `2`. Leer bien estos mensajes es una habilidad diagnóstica central — la suma de las categorías siempre da el total de nodos, y el orden refleja el pipeline de filtros del scheduler.

**R3.2** — **descheduler** (proyecto sig-scheduling, `kubernetes-sigs/descheduler`). No es parte de kube-scheduler porque kube-scheduler es, por diseño explícito, **one-shot e irrevocable por pod**: decide en el binding y no vuelve a mirar. Esa restricción es lo que le permite escalar y ser predecible; un scheduler que reevaluara continuamente todas las asignaciones sería un sistema de optimización global, con costo computacional y comportamiento no determinístico. El descheduler resuelve el problema por el otro lado: **desaloja** pods que violan políticas (`RemovePodsViolatingTopologySpreadConstraint`, `LowNodeUtilization`, `RemovePodsViolatingNodeAffinity`) y deja que kube-scheduler los vuelva a ubicar con el estado actual del cluster.

El riesgo de activarlo sin PDBs correctos: el descheduler evicta en lotes. Si tus workloads no tienen PDB, puede desalojar todas las réplicas de un servicio casi simultáneamente buscando "mejorar el balance" y provocar un outage completo. Por eso el descheduler usa la Eviction API (respeta PDBs) y trae `maxNoOfPodsToEvictPerNode`/`PerNamespace` — pero ambos controles son inútiles si los PDBs no existen. Regla: **descheduler después de PDBs, nunca antes**.

**R3.3** — `ALLOWED DISRUPTIONS = currentHealthy − desiredHealthy`, donde con `minAvailable: 3` y 3 pods sanos da `3 − 3 = 0`. El PDB no promete "mantené 3", promete "nunca bajes de 3 por disrupción voluntaria", así que con exactamente 3 réplicas ninguna evicción es permitida y todo mantenimiento de nodos queda bloqueado indefinidamente.

`maxUnavailable: 1` es más robusto porque se define **relativo al tamaño actual del ReplicaSet**, no en absoluto: si el HPA escala a 10, `minAvailable: 3` permitiría desalojar 7 pods de golpe (protección que se diluye al crecer), mientras que `maxUnavailable: 1` sigue permitiendo exactamente una disrupción a la vez. Y si el deployment se reduce a 2 réplicas, `minAvailable: 3` bloquea todo para siempre, mientras `maxUnavailable: 1` sigue permitiendo mantenimiento de a uno. Para un servicio con N réplicas donde N varía, `maxUnavailable` expresa la intención real ("una a la vez") sin acoplarse a N. Nota: con `minAvailable`/`maxUnavailable` en porcentaje, `minAvailable` redondea hacia arriba y `maxUnavailable` hacia abajo — ambos hacia el lado conservador.

**R3.4** — Porque el PDB **solo** se consulta en la **Eviction API** (`POST /api/v1/namespaces/{ns}/pods/{name}/eviction`), que es lo que usan `kubectl drain`, el cluster-autoscaler y los operadores de mantenimiento. Un `DELETE` directo sobre el pod, un `OOM kill` del kernel, una caída de nodo, un `kubectl delete node` o una terminación de VM por el proveedor no pasan por ahí y no son detenidos por ningún PDB.

Implicación de arquitectura: **el PDB es un contrato entre la aplicación y los procesos de mantenimiento cooperativos de la plataforma, no un mecanismo de enforcement**. Toda herramienta de la plataforma que retire capacidad debe usar la Eviction API — y hay que verificarlo, porque las herramientas caseras casi nunca lo hacen. Para lo que el PDB no cubre (disrupciones involuntarias), la protección son las topology spread constraints y las anti-affinity: distribuir para que ninguna falla no cooperativa se lleve más de una réplica.

**R3.5** — De 3 a 4 con 3 AZ sanas: la cuarta réplica se ubica en cualquier zona, dejando la distribución en 2/1/1. El skew resultante es `2 − 1 = 1`, que satisface `maxSkew: 1`. Se programa sin problema. Con 5 quedaría 2/2/1 (skew 1, OK); con 7, 3/2/2 (skew 1, OK). Es decir: `maxSkew: 1` es perfectamente compatible con réplicas no divisibles por el número de zonas.

De 3 a 7 con una AZ caída: solo hay 2 dominios elegibles. La distribución máxima balanceada es 4/3 (skew 1, OK) — o sea, las 7 réplicas entran. El problema aparece si la AZ caída sigue teniendo nodos `Ready` que simplemente están vacíos, o si por capacidad no entran. El fallo real y frecuente es el de **maxSkew estricto con dominios de capacidad desigual**: si `lab-a` tiene 4 nodos y `lab-b` uno solo, el scheduler no puede poner 4 en `lab-b` y los pods quedan `Pending` con `DoNotSchedule`, aunque haya CPU libre de sobra en `lab-a`. Es capacidad disponible que el sistema se niega a usar. Por eso `minDomains` (estable desde 1.30) y una elección deliberada entre `DoNotSchedule` (disponibilidad de la topología por encima de la capacidad) y `ScheduleAnyway` (lo inverso) son decisiones de arquitectura, no defaults.

**R3.6** — Durante un rolling update, los pods del ReplicaSet viejo y los del nuevo comparten el label `app.kubernetes.io/name: web`, así que ambos cuentan para el mismo `labelSelector`. El scheduler calcula el skew sobre la unión de generaciones, y esa distribución transitoria puede impedir que los pods nuevos entren en las zonas correctas: quedan `Pending` hasta que los viejos terminen, y con `maxUnavailable: 0` eso es un deadlock (nadie muere hasta que el nuevo esté listo, y el nuevo no arranca por la constraint). El campo que lo corrige es **`matchLabelKeys`** — típicamente `matchLabelKeys: ["pod-template-hash"]` — que hace que el cálculo de skew se restrinja a los pods que comparten el valor de esas keys, es decir, a la misma revisión del Deployment. Es beta y habilitado por defecto desde v1.27; verificá disponibilidad en tu versión con `kubectl explain deployment.spec.template.spec.topologySpreadConstraints.matchLabelKeys`.

---

### Ejercicio 4

**R4.1** — `pod-security.kubernetes.io/enforce-version` fija **contra qué versión de los Pod Security Standards** se evalúan los pods. `latest` (el default) significa "la versión que traiga el API server en cada momento".

La diferencia es de gestión de cambios: los Pod Security Standards evolucionan entre releases de Kubernetes — el perfil `restricted` incorporó `seccompProfile` obligatorio en v1.25, `allowPrivilegeEscalation` y `capabilities.drop` en momentos distintos. Con `latest`, actualizar el cluster de v1.32 a v1.33 puede endurecer el perfil y hacer que workloads que ayer se admitían hoy sean rechazados — un cambio de política que llega **como efecto colateral de un upgrade de infraestructura**, no como una decisión revisada. Pinnear `enforce-version` en producción desacopla el ciclo de vida de la política del ciclo de vida del cluster: primero actualizás el cluster, verificás con `warn`/`audit` en la versión nueva, y **después**, en un cambio separado, subís `enforce-version`. En `staging` conviene lo opuesto — dejarlo en `latest` para que sea el canario que detecta el endurecimiento antes de que llegue a producción.

**R4.2** — El warning lo emite el **admission controller `PodSecurity`** del API server, evaluando el `podTemplate` **embebido** en el Deployment contra el perfil configurado en `warn`. Es una funcionalidad deliberada: PSA reconoce los objetos que contienen un pod template (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet, ReplicationController, Pod) y les da feedback temprano vía el header HTTP `Warning`, que `kubectl` imprime. Pero **solo advierte**: no bloquea, porque el objeto que se está creando no es un pod y el enforcement de PSA está definido sobre pods.

El ReplicaSet controller no recibe el mismo trato en un sentido —tampoco es bloqueado al crear el ReplicaSet— pero sí cuando intenta crear el **Pod**: ahí `enforce` sí aplica y la creación es rechazada con `403 Forbidden`. El controller no puede hacer nada con ese error salvo registrarlo como evento `FailedCreate` y reintentar con backoff exponencial, para siempre. De ahí el síntoma: Deployment `0/1` sin explicación visible en el propio Deployment, más allá de `ProgressDeadlineExceeded`.

**R4.3** — El problema es que `kubectl apply` devuelve `0` porque el Deployment sí se creó. El gate honesto espera la convergencia real:

```bash
kubectl apply -f deploy.yaml && \
kubectl -n prod rollout status deploy/legacy --timeout=120s
```

`rollout status` devuelve no-cero si el rollout no converge dentro del timeout, y `progressDeadlineSeconds` (600s por defecto) hace que el Deployment marque `Progressing=False / ProgressDeadlineExceeded`. Para un diagnóstico útil en el log de CI, agregá al fallo:

```bash
kubectl -n prod describe rs -l app=legacy | sed -n '/Events:/,$p'
```

Aún mejor, mové la detección a **antes** del apply con validación server-side, que ejecuta el pipeline de admisión completo sin persistir:

```bash
kubectl apply -f deploy.yaml --dry-run=server
```

Esto emite el mismo `Warning` de PSA en CI, donde todavía es barato arreglarlo. La regla general de plataforma: **un `apply` exitoso no es un deploy exitoso**; el gate tiene que ser el estado convergido.

**R4.4** — **RBAC sobre el verbo `update`/`patch` del recurso `namespaces`.** PSA se configura con labels en el objeto Namespace, así que quien pueda editar el Namespace puede bajar su propio nivel de enforcement. En un cluster multi-tenant real, los equipos de aplicación reciben permisos **dentro** de su namespace (Role/RoleBinding sobre pods, deployments, services...) pero **no** sobre el objeto Namespace en sí, que es cluster-scoped y solo lo administra la plataforma vía GitOps.

Si por alguna razón el equipo necesita editar su namespace (por ejemplo para anotaciones propias), el enforcement se refuerza con una segunda capa: una `ValidatingAdmissionPolicy` (CEL, nativa desde v1.30) o una policy de Kyverno/Gatekeeper que rechace cualquier update que degrade `pod-security.kubernetes.io/enforce` por debajo del nivel asignado al tier del namespace. Y para el cluster completo existe la configuración `AdmissionConfiguration` del API server, que define defaults y exenciones globales de PSA — esa sí está fuera del alcance de cualquier usuario del API.

**R4.5** — PSA es deliberadamente **no configurable**: implementa exactamente los tres perfiles de los Pod Security Standards y nada más. Todo lo demás requiere otras capas:

- **`ValidatingAdmissionPolicy` / `MutatingAdmissionPolicy`** (nativo, CEL, sin webhook externo; VAP estable desde v1.30). Actúa en la fase de validating/mutating admission dentro del API server. Ventaja arquitectónica enorme: no hay backend externo, así que no introduce un punto único de fallo ni latencia de red en el path de escritura. Es la opción por defecto para reglas expresables en CEL.
- **Kyverno** (proyecto graduado de la CNCF) — policies en YAML, con capacidad de mutar, generar recursos derivados y verificar firmas de imágenes (integración con Sigstore/cosign). Corre como webhook.
- **OPA Gatekeeper** (Open Policy Agent, proyecto graduado) — policies en Rego, con `ConstraintTemplate`/`Constraint` y audit mode. También webhook.

Los tres actúan en admission. Para "solo imágenes del registry corporativo" hay además una defensa complementaria y más profunda en el runtime: `ImagePolicyWebhook`, o directamente configuración de containerd/CRI restringiendo registries. Y el `failurePolicy` de cualquier webhook es la decisión de arquitectura crítica: `Fail` (seguro pero puede tumbar el cluster si el webhook cae) vs `Ignore` (disponible pero con ventana de bypass). Por eso VAP, que no puede "caerse", es preferible cuando alcanza.

---

### Ejercicio 5

**R5.1** — No funcionaría. La regla de Kubernetes garbage collection es:

- Un dependent **namespaced** puede tener un owner namespaced **del mismo namespace** (las referencias cross-namespace están prohibidas por diseño) o un owner **cluster-scoped**.
- Un dependent **cluster-scoped** solo puede tener owners **cluster-scoped**.

Si ponés un owner namespaced (un Deployment) en un dependent cluster-scoped (un ClusterRoleBinding), el garbage collector trata esa referencia como **inválida** y emite un evento `OwnerRefInvalidNamespace`; el objeto queda efectivamente sin owner y nunca se recolecta. Peor: como el GC considera al owner "ausente", en ciertas configuraciones el dependent puede quedar sujeto a borrado inmediato. Nuestro caso — `ClusterRoleBinding` (cluster) con owner `Namespace` (cluster) — es válido, y es el patrón canónico para atar recursos cluster-scoped al ciclo de vida de un environment efímero.

Detalle crítico de la implementación: el `uid` en el `ownerReference` **debe** coincidir con el UID actual del owner. Si borrás y recreás el namespace con el mismo nombre, el UID cambia y las referencias viejas se vuelven huérfanas. Por eso el Paso 5.4 lee el UID en el momento de generar el manifiesto y no lo hardcodea.

**R5.2** — `blockOwnerDeletion: true` hace que el borrado del owner entre en **foreground cascading deletion** respecto de ese dependent: el owner queda en estado `Terminating` con el finalizer `foregroundDeletion` hasta que este dependent haya sido efectivamente eliminado. Con `false` (nuestro caso) el borrado es en background: el Namespace desaparece inmediatamente y el GC limpia el ClusterRoleBinding poco después, de forma asincrónica.

El permiso extra que exige: para **crear o actualizar** un ownerReference con `blockOwnerDeletion: true`, el `OwnerReferencesPermissionEnforcement` admission plugin requiere que el usuario tenga el permiso `delete` sobre el **owner**, o específicamente el verbo `update` sobre el subrecurso `finalizers` del owner (`namespaces/finalizers` en este caso). La razón es de seguridad: sin esa comprobación, cualquier usuario podría crear un objeto que bloquee indefinidamente el borrado de un recurso ajeno — un ataque de denegación de servicio sobre el ciclo de vida de otro tenant.

Para un reaper, `false` es lo correcto: querés que el borrado del namespace sea rápido y no quede bloqueado por la limpieza de recursos secundarios.

**R5.3** — `--wait=false` hace que `kubectl` envíe el `DELETE` y retorne, sin esperar a que la terminación del namespace complete. Para un CronJob es lo correcto porque la terminación de un namespace es de duración **no acotada**: hay que evictar todos los pods (respetando `terminationGracePeriodSeconds`, que puede ser de minutos), esperar a que los finalizers de PVCs, Services de tipo LoadBalancer y CRs personalizados se resuelvan, y cada uno de esos pasos puede colgarse.

La cascada de fallo con `--wait=true`: un solo namespace atascado (típicamente por un finalizer de un CRD cuyo operador ya no existe, o un PVC con volumen no desmontable) bloquea el script para siempre. El CronJob tiene `concurrencyPolicy: Forbid`, así que ninguna ejecución posterior arranca. El reaper deja de reapear **todos** los demás previews, que se acumulan en silencio consumiendo cuota hasta que alguien nota que el cluster está lleno. Un componente de limpieza no debe poder ser bloqueado por el elemento que está limpiando. Complementos recomendados: `activeDeadlineSeconds` en el Job y alertas sobre namespaces en `Terminating` más de N minutos.

**R5.4** — Hay dos mecanismos de finalizer sobre un Namespace y se confunden habitualmente:

- **`spec.finalizers`** (típicamente `["kubernetes"]`) es el finalizer del propio namespace controller. Se retira cuando el controller confirma que **todos** los recursos del namespace fueron eliminados.
- **`metadata.finalizers`** de los objetos **dentro** del namespace son la causa real casi siempre: un CR cuyo operador ya no corre, un PVC cuyo CSI driver no responde, un Service de tipo LoadBalancer cuyo cloud-controller no puede liberar la IP.

Diagnóstico correcto — encontrar qué queda vivo:

```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 -I{} sh -c 'kubectl get {} -n <ns> --ignore-not-found -o name' 2>/dev/null
```

y luego, sobre lo que aparezca:

```bash
kubectl get <recurso> -n <ns> -o jsonpath='{.metadata.finalizers}'
kubectl get ns <ns> -o jsonpath='{.status.conditions}' | jq
```

Las `status.conditions` del Namespace (`NamespaceDeletionContentFailure`, `NamespaceDeletionDiscoveryFailure`, `NamespaceFinalizersRemaining`) nombran directamente la causa — incluyendo el caso frecuente del `APIService` agregado caído, que hace fallar el discovery y deja **todos** los namespaces sin poder terminar.

Lo que **no** hay que hacer es el `kubectl patch ns <ns> -p '{"spec":{"finalizers":[]}}' --subresource=finalize` que circula por Stack Overflow: fuerza la desaparición del objeto Namespace dejando sus recursos huérfanos en etcd, invisibles y no borrables — se convierten en basura permanente que solo se limpia con acceso directo a etcd.

**R5.5** — El cero codifica que **un environment efímero no justifica una IP pública ni el costo de un load balancer del proveedor**. Cada Service de tipo LoadBalancer en un cloud provisiona un recurso facturado (NLB/ALB, IP elástica) con costo mensual fijo independiente del uso; 40 previews por semana con un LB cada uno es una factura significativa por infraestructura que vive horas. Además hay límites duros de cuota del proveedor (cantidad de LBs por VPC/región) que, al agotarse, impiden crear LBs **en producción** — el preview environment se convierte en un vector de outage.

Alternativas para exponerlo a un reviewer:

1. **Ingress/Gateway compartido con hostname por PR**: un único LoadBalancer para todo el cluster, con `pr-42.preview.midominio.com` ruteando al Service del namespace. Es el patrón estándar; requiere DNS wildcard y un certificado wildcard (o cert-manager con DNS-01).
2. **`kubectl port-forward`** para acceso puntual del desarrollador, sin infraestructura extra.
3. **Túnel gestionado** (Cloudflare Tunnel, ngrok, Tailscale Funnel) cuando el reviewer es externo a la red corporativa.

La opción 1 es la correcta para una plataforma: convierte un recurso de infraestructura por-environment en un recurso compartido con enrutamiento por-environment, que es el patrón general de eficiencia de plataforma.

**R5.6** — Dos controles (de una lista más larga):

1. **Restringir el ClusterRole por `resourceNames` no alcanza** para namespaces creados dinámicamente, así que el control correcto es una **`ValidatingAdmissionPolicy` (o policy de Kyverno/Gatekeeper) que rechace el `DELETE` de cualquier Namespace que no tenga la label `env.platform.io/type=preview`**, con el ServiceAccount del reaper como sujeto. Convierte la restricción de "qué objeto" en "qué propiedad del objeto", que es lo que RBAC solo no puede expresar.
2. **Protección de los namespaces críticos en sí**: labelar `prod`, `kube-system` y demás con una marca de protección (`env.platform.io/protected: "true"`) y una policy que rechace su borrado por cualquier sujeto que no sea un grupo de break-glass explícito. Es defensa en profundidad: no confía en que el reaper esté bien escrito.

Complementos: `automountServiceAccountToken: false` en todos los pods que no lo necesiten, tokens de ServiceAccount con expiración corta (proyected volumes, ya es el default desde v1.22), auditoría del API server con alerta sobre `delete namespaces` por ServiceAccounts, y un dry-run obligatorio (el reaper loguea qué borraría durante un período de observación antes de habilitar el borrado real).

---

### Ejercicio 6

**R6.1** — Cluster API tiene un boundary de responsabilidad deliberado: **provisiona la infraestructura y bootstrapea Kubernetes hasta el punto en que el API server responde y los nodos se registran**. La elección de CNI es una decisión de arquitectura del operador de la plataforma, no del provider de infraestructura: Calico, Cilium, Antrea y Flannel tienen modelos de red, capacidades de NetworkPolicy, requisitos de kernel y perfiles de rendimiento radicalmente distintos, y muchos clusters además necesitan configuraciones específicas (encapsulación, IPAM, eBPF, integración con la red del datacenter). Acoplar esa elección al provider haría a CAPI opinado en la dimensión más específica de cada organización. Por eso los nodos quedan `NotReady` con `NetworkReady=false`: es el estado correcto y esperado.

El recurso que lo automatiza es el **`ClusterResourceSet`** (parte del core de CAPI): un objeto que referencia ConfigMaps o Secrets con manifiestos y los aplica automáticamente a todo `Cluster` que matchee un `clusterSelector` por labels, en modo `ApplyOnce` o `Reconcile`. Es el mecanismo canónico para el "día 0" de add-ons — CNI, CSI, metrics-server — sin acoplar el provider ni requerir un paso manual. La alternativa moderna y más completa es **CAPI add-on providers** (por ejemplo el Cluster API Add-on Provider for Helm, CAAPH) o un bootstrap de GitOps donde el `ClusterResourceSet` solo instala Argo CD y todo lo demás llega por reconciliación.

**R6.2** — **Radio de impacto.** En namespace-as-environment, el CRD roto afectó los tres environments simultáneamente y de forma instantánea: hay un único API server y un único registro de esquemas. En cluster-as-environment, cada environment tiene su propio API server, su propio etcd y su propio registro de CRDs; el mismo cambio afecta solo al cluster donde se aplicó, y la propagación a otros environments requiere un paso explícito de promoción que puede ser revisado, retrasado o revertido. El aislamiento es duro: no depende de RBAC, de policies ni de que nadie se equivoque, sino de que los sistemas son físicamente distintos.

**Tres costos concretos:**

1. **Costo de infraestructura por control plane.** Cada environment paga control plane (3 nodos para HA o el cargo de un control plane gestionado), etcd, y su propio conjunto de DaemonSets del sistema — CNI, CSI, agentes de observabilidad, service mesh — en cada nodo. Con 10 environments de 5 nodos, el overhead del sistema puede superar el cómputo útil. Los control planes gestionados (EKS/GKE/AKS) tienen además un cargo horario fijo por cluster.
2. **Fan-out operativo.** Cada upgrade de Kubernetes, cada rotación de certificados, cada parche de CVE, cada cambio de configuración del CNI hay que hacerlo N veces. Sin una capa de gestión de flota declarativa —que es exactamente lo que CAPI aporta— el trabajo crece linealmente con el número de environments y el drift entre clusters se vuelve inevitable. Los clusters divergen en versión y configuración, y "funciona en staging" deja de significar algo.
3. **Fragmentación de la visibilidad y del acceso.** Métricas, logs, trazas, políticas de RBAC, secretos y contextos de `kubectl` se multiplican. Hace falta observabilidad agregada multi-cluster (Thanos, Mimir, Loki multi-tenant), gestión de identidad federada y una capa de service discovery cross-cluster si los servicios se hablan entre environments. Cada una de esas es un sistema adicional a operar.

El punto arquitectónico es que la elección no es binaria y suele ser híbrida: cluster-per-tier (un cluster para todo lo non-production, otro para production) captura la mayor parte del aislamiento —el que separa producción de todo lo demás— a una fracción del costo de cluster-per-environment. Y tecnologías de virtualización de control plane (vcluster, Kamaji, HyperShift) ofrecen un punto intermedio: API server dedicado por tenant, nodos compartidos.

**R6.3** — `clusterctl move` traslada todos los objetos CAPI (Cluster, Machine, secrets de kubeconfig, certificados de CA) de un management cluster a otro, preservando UIDs y relaciones de ownership. Existe por dos razones: el **bootstrap** (creás un management cluster efímero de kind, provisionás desde ahí el management cluster definitivo, y hacés *pivot* de los objetos hacia él para que se auto-gestione) y la **migración/DR** (mover la flota a un management cluster nuevo o restaurado).

Si el management cluster se pierde sin pivot ni backup, la consecuencia no es que los workload clusters se caigan — siguen corriendo, porque son clusters de Kubernetes autónomos con su propio control plane. Lo que se pierde es todo lo demás, y es grave:

- Los **secrets de CA y de kubeconfig** de cada workload cluster viven en el management cluster (`<cluster>-ca`, `<cluster>-kubeconfig`). Sin ellos no podés emitir credenciales nuevas ni rotar certificados. Cuando los certificados de cliente actuales expiren (típicamente un año), perdés el acceso administrativo a los workload clusters de forma irreversible.
- Se detiene toda **reconciliación**: no hay escalado de MachineDeployments, no hay auto-reparación por MachineHealthCheck, no hay upgrades. Un nodo que falle no se reemplaza; la flota se degrada monótonamente.
- Los objetos de infraestructura del proveedor (VMs, load balancers, discos) quedan **huérfanos**: nadie los reconcilia y nadie los borra. Siguen facturándose.

Por eso el management cluster es el activo que más protección merece: backup continuo de etcd (Velero + snapshots), preferentemente HA y en una región distinta a la de los workload clusters, y un runbook probado de restauración. La disciplina es la misma que con etcd de cualquier cluster, pero el radio de impacto es toda la flota.

**R6.4** — Si más del 40% de las máquinas del target están unhealthy simultáneamente, el `MachineHealthCheck` **deja de remediar por completo**: no borra ninguna máquina. Es un **circuit breaker** y es correcto por una razón precisa: la remediación de MHC consiste en **borrar** la Machine para que el MachineSet cree una de reemplazo. Ese comportamiento asume que el fallo es local y aislado — un nodo con disco lleno, un kubelet colgado, hardware defectuoso.

Cuando falla el 60% de los nodos a la vez, la hipótesis "fallo local" es casi seguramente falsa. Las causas reales de un fallo masivo simultáneo son sistémicas: partición de red entre nodos y control plane, control plane caído (los nodos aparecen `Unknown` porque nadie recibe sus heartbeats), un rollout defectuoso de la imagen de nodo, un outage de la AZ, expiración de certificados. En **ninguno** de esos casos borrar y recrear las máquinas ayuda — las nuevas nacen con el mismo problema. Y hace un daño real: destruye el estado local, elimina la evidencia forense necesaria para diagnosticar, y satura al proveedor de infraestructura con provisioning masivo justo durante el incidente. En el peor caso entra en un bucle de borrado y recreación que convierte una degradación en un outage total y con pérdida de datos.

`maxUnhealthy` (o `unhealthyRange`) codifica el principio: **la auto-reparación automática es segura para fallos aislados y peligrosa para fallos correlacionados**; ante correlación, la respuesta correcta es parar y llamar a un humano. Es la misma lógica que un circuit breaker en un cliente HTTP o que el `--max-unavailable` de un rolling update.

**R6.5** — El objeto es un **`Secret` llamado `<cluster-name>-kubeconfig`**, en el namespace del `Cluster` del management cluster (para nuestro ejercicio: `env-staging-kubeconfig` en `default`). Es exactamente lo que `clusterctl get kubeconfig` lee. Junto a él viven `<cluster-name>-ca`, `<cluster-name>-etcd`, `<cluster-name>-sa` y `<cluster-name>-proxy`: las **claves privadas de las autoridades certificadoras** de cada workload cluster.

Eso convierte al management cluster en la raíz de confianza de toda la flota: quien tenga acceso de lectura a esos secrets puede emitirse certificados de cliente con `O=system:masters` para **cualquier** cluster gestionado, es decir, admin total en todos los environments incluido producción, sin dejar rastro en el RBAC de los clusters destino. Es una escalada de privilegios de un solo salto desde "leer secrets en el management cluster" hasta "root en toda la organización".

Controles mínimos: RBAC estricto sobre `secrets` en los namespaces de CAPI (nadie con `get secrets` a nivel cluster), encriptación de etcd en reposo con KMS externo, auditoría con alerta sobre lecturas de esos secrets, aislamiento de red del management cluster, y ninguna carga de trabajo de aplicación corriendo en él. El management cluster no es "un cluster más": es el equivalente al servidor de PKI de la organización.

**R6.6** — Un `ClusterClass` define un **template parametrizado de cluster**: topología del control plane, clases de máquinas, versión de Kubernetes, add-ons vía `ClusterResourceSet`, y un conjunto de `variables` con esquema OpenAPI y valores por defecto. Con él, crear un environment se reduce a un `Cluster` de ~15 líneas que declara `topology.class: production-gcp` y unas pocas variables (`region`, `workerCount`, `instanceType`), en lugar de los siete recursos acoplados que generó `clusterctl generate cluster` en el Paso 6.4.

Esto es la definición operativa de un **golden path**: el camino recomendado, con los defaults correctos ya incorporados, que es más fácil de recorrer que cualquier alternativa. La relación con la doctrina de platform engineering (CNCF Platforms White Paper) es directa — una plataforma provee capacidades a través de interfaces que reducen la carga cognitiva sin quitar el escape hatch.

**El equipo de aplicación gana** un tiempo de provisión de environment que baja de días a minutos, una superficie de decisión mínima (elige entre variables acotadas y validadas, no entre cientos de campos de infraestructura), y la garantía de que su cluster ya viene con las políticas, la observabilidad y el hardening de la organización — no tiene que aprenderlos ni recordarlos.

**El equipo de plataforma gana** dos cosas de mayor valor todavía: (1) **un punto único de cambio** — un upgrade de la versión de Kubernetes, un parche de seguridad o una política nueva se aplican editando el `ClusterClass`, y CAPI hace rollout sobre toda la flota con la estrategia de rollout definida, en lugar de perseguir N clusters divergentes; (2) **una superficie soportable** — al restringir la variabilidad a las `variables` declaradas, el conjunto de configuraciones posibles en producción es finito y testeable, en lugar de ser el producto cartesiano de todo lo que cada equipo pudo escribir en un YAML. Menos formas de estar roto es la propiedad que hace operable una flota.

---

### Ejercicio 7

**R7.1** — Un `ValidatingWebhookConfiguration` con `failurePolicy: Fail` cuyo backend está caído hace que el API server **rechace toda operación que matchee sus `rules`**. Si las rules son amplias (`apiGroups: ["*"], resources: ["*"], operations: ["*"]`), el cluster deja de aceptar cualquier escritura: no se crean pods, no se actualizan deployments, los controladores no pueden escribir estado. Y hay un deadlock específico y frecuente: si el propio pod del webhook muere y el webhook intercepta la creación de pods, no se puede crear el pod de reemplazo. El cluster no se recupera solo; hay que borrar la configuración del webhook con un `kubectl delete validatingwebhookconfiguration` desde credenciales de admin, lo cual desactiva la política de seguridad en el momento más caótico posible.

Los campos que lo acotan:

- **`namespaceSelector`** y **`objectSelector`** — restringen el alcance a namespaces u objetos etiquetados. Regla de oro: **excluir siempre `kube-system` y los namespaces de la infraestructura de plataforma**, para que un webhook caído nunca impida recuperar los componentes que lo sostienen.
- **`timeoutSeconds`** (máximo 30, default 10) — bajarlo a 5 acota el daño en latencia cuando el backend está lento en lugar de caído.
- **`rules`** ajustadas al mínimo — `operations: ["CREATE","UPDATE"]` sobre los recursos específicos, jamás `*`.
- **`failurePolicy: Ignore`** para políticas no críticas para la seguridad, aceptando la ventana de bypass.
- **`matchConditions`** (CEL, estable desde v1.30) — filtrado fino antes de invocar el webhook, que reduce tanto la carga como la superficie de fallo.

Y la mitigación estructural: HA del webhook (múltiples réplicas con PDB y anti-affinity), y preferir **`ValidatingAdmissionPolicy`** siempre que la regla sea expresable en CEL, porque se evalúa dentro del API server y no puede estar caída.

**R7.2** — Con **`Immediate`**, el volumen se provisiona en el momento en que se crea el PVC, **antes** de que exista un pod que lo consuma y por lo tanto antes de que el scheduler haya decidido nada. El provisioner elige la zona sin información sobre las constraints del pod. Modo de falla concreto:

1. Un StatefulSet en un cluster de 3 AZ crea 3 PVCs. El provisioner los coloca, digamos, todos en `zone-a` (o los distribuye arbitrariamente).
2. Los pods se crean con un `topologySpreadConstraint` sobre `topology.kubernetes.io/zone` con `whenUnsatisfiable: DoNotSchedule`.
3. El scheduler ahora tiene dos restricciones incompatibles: el `VolumeBinding` obliga a cada pod a la zona de su PV (un EBS/PD zonal solo se monta en su zona), y el topology spread le exige distribuir.
4. Los pods quedan **`Pending` para siempre**, con un `FailedScheduling` que menciona `node(s) had volume node affinity conflict` junto a `didn't match pod topology spread constraints`. No hay recuperación posible sin borrar los PVCs — es decir, sin destruir los datos.

Además, aun sin topology spread, `Immediate` concentra el riesgo: los 3 PVs en `zone-a` significan que la caída de `zone-a` se lleva todo el StatefulSet, aunque los pods estuvieran distribuidos.

**`WaitForFirstConsumer`** invierte el orden: el PVC queda `Pending` hasta que un pod lo referencie; el scheduler decide el nodo considerando **todas** las constraints juntas (topology spread, afinidad, taints, recursos), y recién entonces el provisioner crea el volumen **en la zona del nodo elegido**. Es el default correcto para cualquier StorageClass de volúmenes zonales, y verificarlo es de los primeros ítems del checklist al evaluar un cluster desconocido.

**R7.3** — Tres verificaciones, de menor a mayor confianza:

1. **Identificar el CNI y confirmar que implementa NetworkPolicy.** `kubectl -n kube-system get daemonset` y mirar la imagen: Calico, Cilium, Antrea y Weave la implementan; Flannel **no** (necesita Canal, es decir Flannel + Calico para policy); `kindnetd` depende de la versión. Es una verificación por documentación, no por evidencia — necesaria pero no suficiente.
2. **Test empírico de deny.** Aplicar un `default-deny-ingress` en un namespace de prueba y verificar desde otro namespace que la conexión falla (timeout, no `connection refused` — un `refused` significa que el paquete llegó y algo lo rechazó, lo cual es una respuesta distinta). Esto es lo que hicimos en el Paso 7.6 y es la única evidencia real de enforcement.
3. **Test de allow, para descartar el falso positivo.** Este paso es el que más se olvida y el más importante: aplicar una policy que **permita** explícitamente el tráfico desde el namespace origen y verificar que ahora **sí** conecta. Sin él no podés distinguir "la policy funciona" de "la conexión fallaba de todas formas" por DNS mal configurado, Service sin endpoints, puerto equivocado o el pod no listo. Una política de seguridad que parece funcionar porque el sistema estaba roto por otro motivo es la peor clase de falso positivo, porque colapsa en el momento en que alguien arregla el problema real.

Complementos para un cluster de producción: tests de policy automatizados en CI que corran contra un cluster efímero en cada cambio de política, y verificación de que el `policyTypes` incluye `Egress` cuando corresponde — una policy que solo declara `Ingress` no restringe salida en absoluto, y la exfiltración es egress.

**R7.4** — **API Priority and Fairness** (estable desde v1.29) reemplaza el viejo `--max-requests-inflight` con un sistema de colas por prioridad: las `FlowSchema` clasifican las peticiones entrantes (por usuario, ServiceAccount, namespace o recurso) y las asignan a una `PriorityLevelConfiguration`, cada una con su porción garantizada de concurrencia del API server y su cola independiente.

La relación con la separación de environments es directa: cuando `dev` y `prod` comparten cluster, comparten **un solo API server**, que es un recurso finito. Un controlador mal escrito en `dev` que haga un `LIST` sin paginar de todos los pods cada segundo, o un operador en bucle de reconciliación, satura la concurrencia del API server. Sin APF eso degrada a todos por igual, incluyendo a los componentes que sostienen producción.

El síntoma de su ausencia (o mala configuración) es característico y vale reconocerlo: **latencia creciente de `kubectl` en todo el cluster, seguida de `429 Too Many Requests`, kubelets que no logran renovar sus leases y nodos que pasan a `NotReady` en cascada** — no porque los nodos tengan un problema, sino porque no consiguen turno para hablar con el API server. Los controladores pierden sus leader elections y hay un failover masivo que agrava la carga. Es un fallo del plano de control que se presenta como un fallo de la capa de datos.

La mitigación arquitectónica es exactamente para lo que existen las FlowSchema: garantizar concurrencia a `system-nodes`, `system-leader-election` y `kube-controller-manager` — los niveles que la configuración por defecto ya protege — y crear FlowSchemas propias que acoten a las ServiceAccounts de los tenants no productivos. Métricas a vigilar: `apiserver_flowcontrol_rejected_requests_total` y `apiserver_flowcontrol_current_inqueue_requests`.

**R7.5** — El comando:

```bash
kubectl get nodes -o json | jq -r --arg cp "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
  '.items[] | select(.status.nodeInfo.kubeletVersion != $cp)
   | "\(.metadata.name)\tkubelet=\(.status.nodeInfo.kubeletVersion)\tapiserver=\($cp)"'
```

La regla que se verifica es la **version skew policy** de Kubernetes: el `kubelet` puede estar hasta **3 versiones menores por detrás** del `kube-apiserver` (ampliado de 2 a 3 en v1.28), y **nunca por delante**. Un kubelet más nuevo que el API server es una configuración no soportada con fallos impredecibles.

Sus implicaciones operativas son las que importan: (a) el orden de upgrade es obligatorio — primero el control plane, después los nodos, nunca al revés; (b) la ventana de 3 versiones (~9 meses con el ciclo de release actual) es el presupuesto real de tiempo para completar un upgrade de flota antes de entrar en territorio no soportado; (c) `kubectl` tiene su propia regla, ±1 versión menor respecto del API server, y un `kubectl` desactualizado es una causa habitual de campos que se pierden silenciosamente al aplicar manifiestos. `kube-proxy` sigue la misma política que kubelet y nunca puede ser más nuevo que el API server.

**R7.6** — Un veredicto posible con la evidencia recogida:

> El cluster tiene tres failure domains bien etiquetados y un control plane único sin HA (un solo nodo `control-plane`), lo que ya lo descalifica como sustrato de producción: cualquier fallo de ese nodo es un outage total del plano de control y una pérdida potencial de etcd. La única StorageClass es `rancher.io/local-path` con `reclaimPolicy: Delete`, es decir almacenamiento local no replicado y con borrado automático: cualquier PVC de producción sobreviviría exactamente hasta la primera reprogramación de su pod. Y el test del Paso 7.6 es determinante — si la NetworkPolicy `default-deny` no se aplicó, no existe ningún boundary de red entre `dev` y `prod`, con lo que la separación por namespaces es puramente nominal: un pod comprometido en `dev` alcanza cualquier Service de `prod`.
>
> Veredicto: **no apto** para alojar `prod` y `dev` simultáneamente. Los bloqueantes, en orden: (1) CNI que aplique NetworkPolicy de verdad, verificado empíricamente con test de deny y de allow; (2) control plane HA con backup de etcd probado; (3) StorageClass con `WaitForFirstConsumer`, `reclaimPolicy: Retain` para datos productivos y replicación; (4) ausencia total de admission webhooks y de policies más allá de PSA, lo que deja sin cubrir procedencia de imágenes, límites de egress y requisitos de TLS.

Lo importante del ejercicio no es este veredicto en particular sino el método: **cada afirmación de arquitectura se ancla en la salida de un comando concreto**, y la ausencia de evidencia (webhooks vacíos, ninguna IngressClass) es un dato tan relevante como su presencia.

</details>

---

## Fuentes

Todas las URLs verificables al 2026-08-06. El contenido de esta guía es original; estas son las referencias normativas sobre las que se apoya.

**Currículum y doctrina de plataforma**
- CNCF — *CNPA Curriculum* (v2025-04-01): https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF TAG App Delivery — *Platforms White Paper*: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF TAG App Delivery — *Platform Engineering Maturity Model*: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- *The Twelve-Factor App* — Dev/prod parity: https://12factor.net/dev-prod-parity

**Environments, tenancy y aislamiento**
- Kubernetes — *Multi-tenancy*: https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Kubernetes — *Namespaces*: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes — *Resource Quotas*: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — *Limit Ranges*: https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — *Pod Security Admission*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — *Validating Admission Policy*: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes — *Admission Controllers* (NodeRestriction, ResourceQuota, LimitRanger): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/

**Topología, scheduling y disponibilidad**
- Kubernetes — *Pod Topology Spread Constraints*: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — *Disruptions*: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Kubernetes — *Specifying a Disruption Budget*: https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Kubernetes — *Well-Known Labels, Annotations and Taints*: https://kubernetes.io/docs/reference/labels-annotations-taints/
- Kubernetes — *Safely Drain a Node*: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- `kubernetes-sigs/descheduler`: https://github.com/kubernetes-sigs/descheduler

**Configuración, drift y ciclo de vida**
- Kubernetes — *Server-Side Apply*: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — *Garbage Collection*: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kustomize — *API reference*: https://kubectl.docs.kubernetes.io/references/kustomize/
- Argo CD — *ApplicationSet Git Generator*: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/

**Infraestructura y flota**
- Cluster API — *The Cluster API Book*: https://cluster-api.sigs.k8s.io/
- Cluster API — *Quick Start*: https://cluster-api.sigs.k8s.io/user/quick-start
- Cluster API — *ClusterClass and managed topologies*: https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/
- Cluster API — *MachineHealthCheck*: https://cluster-api.sigs.k8s.io/tasks/automated-machine-management/healthchecking
- Cluster API — *ClusterResourceSet*: https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-resource-set

**Almacenamiento, red y control plane**
- Kubernetes — *Storage Classes* (`volumeBindingMode`): https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — *API Priority and Fairness*: https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes — *Version Skew Policy*: https://kubernetes.io/releases/version-skew-policy/
- kind — *Configuration*: https://kind.sigs.k8s.io/docs/user/configuration/