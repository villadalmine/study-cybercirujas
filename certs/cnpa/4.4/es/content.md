# Tema 4.4 — El Patrón Operator de Kubernetes para Integración y Automatización

> **Peso en el examen: 3.0** · Dominio 4 (Automatización e Integración de la Plataforma) · CNPA 2025-04-01
> Perfil: SRE / Platform Architect. Este material asume que ya dominás CRDs básicos, RBAC y el ciclo de vida de un Pod.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 El conocimiento operacional como código

Kubernetes sabe reconciliar recursos *stateless* genéricos: un `Deployment` mantiene N réplicas, un `Service` balancea, un `Job` corre hasta completar. Pero **no sabe nada** sobre cómo operar una base de datos concreta. ¿Qué significa "escalar" un clúster de PostgreSQL con streaming replication? No es `replicas: 3`. Significa:

1. Provisionar un nuevo pod con un PVC vacío.
2. Hacer `pg_basebackup` desde el primary actual.
3. Configurar `recovery.conf`/`standby.signal` apuntando al primary.
4. Registrar el nuevo standby en el `synchronous_standby_names` si corresponde.
5. Actualizar el `Service` de solo-lectura para incluir el nuevo endpoint.
6. Y si el que muere es el **primary**, ejecutar un failover con promoción, fencing del nodo viejo y re-apuntado de todos los standbys.

Ese conjunto de pasos es lo que un **operador humano** (un DBA/SRE) tenía escrito en un runbook. El **problema arquitectónico** es que un runbook:

- Se ejecuta a velocidad humana (minutos/horas), mientras el SLO de recuperación exige segundos.
- No es *level-triggered*: reacciona a un ticket, no al estado real y continuo del sistema.
- No escala: 3 clústeres los opera una persona; 300 no.
- Diverge de la realidad (documentation drift).

El **Operator Pattern** codifica ese runbook como un **controller** que corre *dentro* del clúster, observa un **Custom Resource** (CR) que describe la intención (`spec`) y ejecuta continuamente la lógica de reconciliación para que el mundo real (`status`) converja hacia esa intención. En una frase de CoreOS (quienes acuñaron el término en 2016):

> *"An Operator is a method of packaging, deploying and managing a Kubernetes application... it takes human operational knowledge and encodes it into software."*

### 1.2 Teoría de control: el reconcile loop

El corazón de todo operador —y de todo Kubernetes— es el **control loop** (bucle de control). Es un lazo cerrado de teoría de control clásico:

```
        observe (watch/list)
             │
             ▼
   ┌──────────────────┐
   │   current state  │◄──────── el mundo real (API server, sistemas externos)
   └──────────────────┘
             │  diff
             ▼
   ┌──────────────────┐
   │   desired state  │◄──────── el spec del Custom Resource
   └──────────────────┘
             │
             ▼
          act (create/update/delete)  →  vuelve a observe
```

Propiedades no negociables que el examen evalúa:

- **Level-triggered, no edge-triggered.** El operador *no* reacciona a "eventos" ("se creó un pod"); reacciona al **nivel** (estado actual completo). Si pierde 100 eventos porque estuvo caído, al reiniciar hace un `list` completo y reconcilia desde cero. Esto lo hace **auto-sanante** y robusto ante reinicios. Un diseño edge-triggered que "cuente" eventos es un antipatrón que se desincroniza para siempre ante una pérdida.
- **Idempotencia.** `Reconcile()` puede ejecutarse mil veces sobre el mismo estado sin efectos acumulativos. Nunca "crea otra réplica"; siempre "asegura que existan N réplicas".
- **Declarativo, no imperativo.** El CR dice *qué* (backup diario a las 02:00), no *cómo* (no es un script de pasos).
- **Eventual consistency.** Convergencia asintótica, con reintentos y backoff exponencial. Un reconcile puede fallar y reencolarse.

### 1.3 Integración y automatización (el foco del tema 4.4)

Este tema no trata solo de "cómo escribir un operador para tu app". Trata del operador como **mecanismo universal de integración** de la plataforma:

- **Integración con sistemas externos:** un operador que observa un CR `Database` y provisiona una RDS real en AWS vía API (ej. Crossplane, ACK, Config Connector). El clúster se vuelve el *single pane of glass* declarativo de infraestructura fuera de él.
- **Automatización de Day-2 operations:** backups, upgrades, rotación de certificados, resize de volúmenes, tuning. El operador convierte tareas de guardia en reconciliación continua.
- **Extensión de la API como contrato de plataforma:** el Platform Engineer publica CRDs (`TenantNamespace`, `PostgresCluster`, `KafkaTopic`) que son la **interfaz** que consume el desarrollador. El operador es la implementación. Esto es la base del *Internal Developer Platform* (IDP) — se conecta con el tema 4.x de plataformas y con Backstage/Kratix/Crossplane.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Operator vs. otras estrategias de empaquetado y gestión

| Estrategia | Estado que gestiona | Day-2 ops (backup, failover, upgrade) | Reconciliación continua | Curva de complejidad | Cuándo usarla |
|---|---|---|---|---|---|
| **YAML + `kubectl apply`** | Ninguno más allá de lo que hace K8s | No | No (one-shot) | Trivial | Apps stateless simples |
| **Helm chart** | Templating + release history | No (Helm no corre en el clúster observando) | No — es *push* en `helm upgrade` | Baja | Distribución/instalación parametrizable |
| **Kustomize** | Overlays declarativos | No | No | Baja | Gestión de variantes de manifiestos |
| **Sidecar / init container** | Local al Pod | Limitado, por-pod | Solo dentro del pod | Media | Lógica acoplada a un pod (proxy, TLS) |
| **Controller genérico (sin CRD)** | Recursos nativos | Parcial | Sí | Media | Automatizar objetos nativos |
| **Operator (CRD + controller)** | App stateful + externos, dominio completo | **Sí** (es su razón de ser) | **Sí** (level-triggered) | **Alta** | Apps stateful, integración externa, Day-2 |

**Regla de decisión (mnemónica de examen):** *si tu aplicación necesita conocimiento operacional específico del dominio que hoy vive en un runbook humano y debe ejecutarse continuamente, es un candidato a Operator. Si solo necesitás instalarla, un Helm chart alcanza.* De hecho muchos operadores **se distribuyen** por Helm o por OLM y luego el operador **usa** conocimiento que Helm no puede expresar.

### 2.2 Helm vs. Operator — la distinción que más se confunde

| Dimensión | Helm | Operator |
|---|---|---|
| Modelo | Client-side templating (imperativo en el `upgrade`) | Server-side control loop (declarativo, continuo) |
| Momento de actuación | Solo cuando corrés `helm install/upgrade` | Siempre, ante cualquier drift |
| Drift / auto-repair | No detecta ni corrige drift | Detecta y corrige (reconcilia) |
| Conocimiento de dominio | Ninguno (renderiza texto) | Codificado en Go/Ansible |
| Rollback | `helm rollback` (revisiones) | Depende de la lógica del operador |
| Complementariedad | — | **Helm-based operator**: un operador cuya lógica *es* un chart re-aplicado en cada reconcile |

### 2.3 Frameworks/SDKs para construir operadores

| Framework | Lenguaje | Base técnica | Capability level típico | Trade-off |
|---|---|---|---|---|
| **Kubebuilder** | Go | `controller-runtime` (SIG upstream) | 3–5 | Máximo control y performance; requiere saber Go |
| **Operator SDK (Go)** | Go | Envuelve Kubebuilder + añade OLM/scorecard | 3–5 | Igual que Kubebuilder + tooling de RedHat/CNCF |
| **Operator SDK (Ansible)** | YAML/Ansible | Reconcile = ejecutar un playbook | 1–2 | Sin Go; reconcile "pesado", menos performante |
| **Operator SDK (Helm)** | YAML/Helm | Reconcile = re-aplicar un chart | 1–2 | Rápido de arrancar; no expresa lógica compleja |
| **Metacontroller** | Cualquiera (webhook) | Delega la lógica a un webhook tuyo (lambda-style) | 2–3 | Escribís solo una función; menos control del cache |
| **KUDO** | YAML declarativo | Plans/phases declarativos | 2–3 | Menos código; menos flexible |
| **Kopf** | Python | Framework Python sobre watches | 2–3 | Pythónico; menos maduro que controller-runtime |

**controller-runtime** es la biblioteca upstream (kubernetes-sigs) que subyace a Kubebuilder y al Operator SDK en Go. Es lo que el examen espera que reconozcas como el estándar de facto: aporta el `Manager`, el `Client` con cache, los `Informers` compartidos, el `WorkQueue` con rate limiting y la elección de líder.

### 2.4 Operator Capability / Maturity Model

El modelo de madurez (definido por OperatorHub/OLM) clasifica operadores en 5 niveles. Es material de examen frecuente:

| Nivel | Nombre | Qué hace |
|---|---|---|
| **1** | Basic Install | Instala la app y configuración básica vía el CR |
| **2** | Seamless Upgrades | Gestiona upgrades de versión de la app y del propio operador |
| **3** | Full Lifecycle | Backups, restores, failover, escalado — Day-2 completo |
| **4** | Deep Insights | Métricas, alertas, análisis de logs, dashboards |
| **5** | Auto Pilot | Auto-scaling, auto-healing, auto-tuning según carga real |

Los operadores basados en Helm/Ansible suelen quedar en niveles 1–2; los niveles 3–5 casi siempre requieren Go y lógica de dominio profunda.

---

## 3. Anatomía técnica y manifiestos completos

Un operador se compone de **cuatro** piezas que siempre van juntas. Las desarrollo con manifiestos reales y sintácticamente válidos para un operador de ejemplo que gestiona un CR `WebApp`.

### 3.1 Pieza 1 — El CustomResourceDefinition (la API extendida)

El CRD es el contrato. En `apiextensions.k8s.io/v1` **es obligatorio un structural schema** (OpenAPI v3). Este manifiesto ejercita las tres características que el examen espera: **validación** por schema, **status subresource**, **scale subresource** y **printer columns**.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.apps.example.com
spec:
  group: apps.example.com
  scope: Namespaced
  names:
    plural: webapps
    singular: webapp
    kind: WebApp
    shortNames:
      - wa
    categories:
      - all
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        # Habilita /status: el spec y el status se actualizan por separado.
        # El operador escribe status; el usuario escribe spec. Evita conflictos.
        status: {}
        # Habilita /scale: permite `kubectl scale webapp/foo --replicas=5`
        # y que el HPA pueda escalar este CR como si fuera un Deployment.
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.readyReplicas
          labelSelectorPath: .status.selector
      schema:
        openAPIV3Schema:
          type: object
          required: ["spec"]
          properties:
            spec:
              type: object
              required: ["image", "replicas"]
              properties:
                image:
                  type: string
                  description: "Imagen de contenedor a desplegar."
                  pattern: '^[a-z0-9./_-]+(:[a-zA-Z0-9._-]+)?$'
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 50
                  default: 1
                port:
                  type: integer
                  minimum: 1
                  maximum: 65535
                  default: 8080
                resources:
                  type: object
                  properties:
                    cpu:
                      type: string
                      default: "250m"
                    memory:
                      type: string
                      default: "256Mi"
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
                selector:
                  type: string
                observedGeneration:
                  type: integer
                  format: int64
                phase:
                  type: string
                  enum: ["Pending", "Progressing", "Ready", "Failed"]
                conditions:
                  type: array
                  items:
                    type: object
                    required: ["type", "status", "reason", "lastTransitionTime"]
                    properties:
                      type:
                        type: string
                      status:
                        type: string
                        enum: ["True", "False", "Unknown"]
                      reason:
                        type: string
                      message:
                        type: string
                      lastTransitionTime:
                        type: string
                        format: date-time
                      observedGeneration:
                        type: integer
                        format: int64
      additionalPrinterColumns:
        - name: Image
          type: string
          jsonPath: .spec.image
        - name: Desired
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

**Puntos de arquitectura clave:**

- `served` vs `storage`: podés servir varias versiones (`v1alpha1`, `v1beta1`, `v1`) simultáneamente, pero **exactamente una** tiene `storage: true`. Las demás se convierten sobre la marcha (conversion webhook) — así se hace versionado de API sin romper clientes.
- El **status subresource** es lo que separa la escritura de `spec` (usuario) de `status` (operador). Sin él, un `kubectl apply` del usuario puede pisar el status del operador y viceversa. Además, con status subresource habilitado, `.metadata.generation` solo aumenta cuando cambia `spec`, permitiendo el patrón `observedGeneration`.
- Las **conditions** siguen el estándar `metav1.Condition` de Kubernetes: `type/status/reason/message/lastTransitionTime/observedGeneration`. No inventés tu propio formato.

### 3.2 Pieza 2 — RBAC (ServiceAccount + ClusterRole + Binding)

El operador es un proceso que habla con el API server; **necesita permisos explícitos**. El error de producción #1 en operadores es RBAC insuficiente. Manifiesto completo y mínimo-necesario:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp-operator
  namespace: webapp-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: webapp-operator-role
rules:
  # Gestionar nuestro propio CRD y su status
  - apiGroups: ["apps.example.com"]
    resources: ["webapps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps.example.com"]
    resources: ["webapps/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["apps.example.com"]
    resources: ["webapps/finalizers"]
    verbs: ["update"]
  # Recursos que el operador CREA y posee (owned resources)
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Emitir Events para observabilidad (kubectl describe / kubectl get events)
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  # Leader election vía Leases (controller-runtime lo usa por defecto)
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: webapp-operator-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: webapp-operator-role
subjects:
  - kind: ServiceAccount
    name: webapp-operator
    namespace: webapp-system
```

**Principio de mínimo privilegio:** un operador namespaced debería usar `Role`/`RoleBinding` acotados; solo si observa recursos en todos los namespaces necesita `ClusterRole`. El permiso sobre `webapps/finalizers` es imprescindible cuando el operador registra finalizers (§3.5).

### 3.3 Pieza 3 — El Deployment del operador

El controller corre como un `Deployment` (habitualmente 1–2 réplicas con **leader election** para evitar que dos instancias reconcilien en paralelo):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-operator
  namespace: webapp-system
  labels:
    control-plane: webapp-operator
spec:
  replicas: 2                       # HA activo-pasivo vía leader election
  selector:
    matchLabels:
      control-plane: webapp-operator
  template:
    metadata:
      labels:
        control-plane: webapp-operator
    spec:
      serviceAccountName: webapp-operator
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: manager
          image: registry.example.com/webapp-operator:v0.4.2
          args:
            - --leader-elect                      # activa la elección de líder (Lease)
            - --health-probe-bind-address=:8081
            - --metrics-bind-address=:8443
          ports:
            - name: metrics
              containerPort: 8443
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8081
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8081
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      terminationGracePeriodSeconds: 10
```

Con `--leader-elect`, solo la réplica que posee el `Lease` reconcilia; la otra espera en caliente. Si el líder muere, la standby adquiere el Lease (por defecto en ~15 s) y toma el control. **Nunca** dejes dos réplicas reconciliando sin leader election: reconcilian en carrera y se pisan.

### 3.4 Pieza 4 — El Custom Resource (la instancia que consume el usuario)

```yaml
apiVersion: apps.example.com/v1alpha1
kind: WebApp
metadata:
  name: frontend
  namespace: production
spec:
  image: registry.example.com/frontend:2.7.1
  replicas: 3
  port: 8080
  resources:
    cpu: "500m"
    memory: "512Mi"
```

El usuario aplica *esto*. El operador lo observa y materializa un `Deployment` + `Service` + `ConfigMap` con las **ownerReferences** correctas para que la garbage collection en cascada funcione (§3.6).

### 3.5 La lógica de reconciliación (controller-runtime, Go)

El esqueleto que el examen espera que reconozcas. No hace falta programarlo en el examen, pero sí entender cada bloque:

```go
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := log.FromContext(ctx)

    // 1) LEER el estado deseado (spec). Si no existe, ya fue borrado: no error.
    var app appsv1alpha1.WebApp
    if err := r.Get(ctx, req.NamespacedName, &app); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err) // idempotente ante deletes
    }

    // 2) FINALIZER: manejar el borrado con limpieza externa antes de desaparecer.
    finalizer := "apps.example.com/cleanup"
    if !app.DeletionTimestamp.IsZero() {
        if controllerutil.ContainsFinalizer(&app, finalizer) {
            if err := r.cleanupExternal(ctx, &app); err != nil {
                return ctrl.Result{}, err // reintentará; el objeto NO se borra aún
            }
            controllerutil.RemoveFinalizer(&app, finalizer)
            return ctrl.Result{}, r.Update(ctx, &app)
        }
        return ctrl.Result{}, nil
    }
    if !controllerutil.ContainsFinalizer(&app, finalizer) {
        controllerutil.AddFinalizer(&app, finalizer)
        if err := r.Update(ctx, &app); err != nil {
            return ctrl.Result{}, err
        }
    }

    // 3) RECONCILIAR el estado real hacia el deseado (idempotente).
    deploy := r.desiredDeployment(&app)          // construye el objeto deseado
    if err := ctrl.SetControllerReference(&app, deploy, r.Scheme); err != nil {
        return ctrl.Result{}, err                 // ownerReference -> GC en cascada
    }
    if err := r.applyDeployment(ctx, deploy); err != nil { // create-or-update
        return ctrl.Result{}, err
    }

    // 4) ESCRIBIR status (subresource) con conditions y observedGeneration.
    app.Status.ObservedGeneration = app.Generation
    meta.SetStatusCondition(&app.Status.Conditions, metav1.Condition{
        Type:    "Ready",
        Status:  metav1.ConditionTrue,
        Reason:  "DeploymentReady",
        Message: "todas las réplicas disponibles",
    })
    if err := r.Status().Update(ctx, &app); err != nil {
        return ctrl.Result{}, err
    }

    // 5) Reencolar periódicamente para re-sincronizar (resync defensivo).
    return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

// SetupWithManager registra el watch y establece ownership de recursos hijos.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&appsv1alpha1.WebApp{}).
        Owns(&appsv1.Deployment{}).   // re-reconcilia el WebApp si su Deployment cambia
        Owns(&corev1.Service{}).
        Complete(r)
}
```

**Mecánica interna que subyace (imprescindible para el nivel del examen):**

- **Informer + cache:** `controller-runtime` no hace polling. Abre un `watch` HTTP streaming al API server y mantiene un **cache local** (SharedInformer). Los `r.Get()` leen del cache, no del API server — por eso el cache puede estar *ligeramente* desactualizado (eventual consistency).
- **WorkQueue con rate limiting:** cada evento encola la *key* (`namespace/name`) en una workqueue con **deduplicación** (si la misma key entra 5 veces mientras se procesa, se reconcilia una sola vez con el estado más reciente) y **backoff exponencial** por ítem ante errores (`workqueue.DefaultControllerRateLimiter`: de 5 ms hasta 1000 s).
- **`Return err` → reintento con backoff.** `Return Result{RequeueAfter: t}` → reintento fijo. `Return Result{}, nil` → no reencola (salvo eventos nuevos).
- **`Owns()`** establece un watch sobre los hijos filtrado por ownerReference: si alguien borra el Deployment a mano, el operador lo re-crea (auto-repair).

### 3.6 Owner references, garbage collection y finalizers

Dos mecanismos ortogonales que el examen suele mezclar:

| Mecanismo | Dirección | Para qué sirve |
|---|---|---|
| **ownerReference** | Del **hijo** al **padre** | Al borrar el padre (`WebApp`), el garbage collector borra en cascada los hijos (`Deployment`, `Service`). Es limpieza **interna** al clúster. |
| **finalizer** | Bloquea el borrado del **propio** objeto | Al recibir un delete, el objeto queda con `deletionTimestamp` pero **no se borra** hasta que el operador ejecute la limpieza **externa** (borrar la RDS real, un bucket, un DNS) y quite el finalizer. |

ownerReference generada por `SetControllerReference`:

```yaml
metadata:
  ownerReferences:
    - apiVersion: apps.example.com/v1alpha1
      kind: WebApp
      name: frontend
      uid: 7d9f...c1
      controller: true
      blockOwnerDeletion: true
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Descubrir y explorar la API extendida

```console
$ kubectl apply -f webapp-crd.yaml
customresourcedefinition.apiextensions.k8s.io/webapps.apps.example.com created

$ kubectl get crd webapps.apps.example.com
NAME                        CREATED AT
webapps.apps.example.com    2026-08-07T10:12:03Z

$ kubectl api-resources --api-group=apps.example.com
NAME       SHORTNAMES   APIVERSION                      NAMESPACED   KIND
webapps    wa           apps.example.com/v1alpha1       true         WebApp

$ kubectl explain webapp.spec
KIND:     WebApp
VERSION:  apps.example.com/v1alpha1

RESOURCE: spec <Object>

DESCRIPTION:
     <empty>

FIELDS:
   image        <string> -required-
     Imagen de contenedor a desplegar.
   port         <integer>
   replicas     <integer> -required-
   resources    <Object>
```

### 4.2 Desplegar el operador y crear una instancia

```console
$ kubectl create namespace webapp-system
namespace/webapp-system created

$ kubectl apply -f rbac.yaml
serviceaccount/webapp-operator created
clusterrole.rbac.authorization.k8s.io/webapp-operator-role created
clusterrolebinding.rbac.authorization.k8s.io/webapp-operator-rolebinding created

$ kubectl apply -f operator-deployment.yaml
deployment.apps/webapp-operator created

$ kubectl -n webapp-system get pods
NAME                               READY   STATUS    RESTARTS   AGE
webapp-operator-6c9f8d7b4c-2xk9p   1/1     Running   0          22s
webapp-operator-6c9f8d7b4c-lm4qt   1/1     Running   0          22s

$ kubectl apply -f webapp-frontend.yaml
webapp.apps.example.com/frontend created
```

### 4.3 Observar la reconciliación y el status

```console
$ kubectl -n production get webapp
NAME       IMAGE                                  DESIRED   READY   PHASE     AGE
frontend   registry.example.com/frontend:2.7.1    3         3       Ready     47s

$ kubectl -n production describe webapp frontend
Name:         frontend
Namespace:    production
API Version:  apps.example.com/v1alpha1
Kind:         WebApp
Spec:
  Image:     registry.example.com/frontend:2.7.1
  Port:      8080
  Replicas:  3
Status:
  Observed Generation:  1
  Phase:                Ready
  Ready Replicas:       3
  Conditions:
    Last Transition Time:  2026-08-07T10:15:41Z
    Message:               todas las réplicas disponibles
    Observed Generation:   1
    Reason:                DeploymentReady
    Status:                True
    Type:                  Ready
Events:
  Type    Reason              Age   From             Message
  ----    ------              ----  ----             -------
  Normal  ReconcileStarted    47s   webapp-operator  reconciling WebApp production/frontend
  Normal  DeploymentCreated   46s   webapp-operator  created Deployment production/frontend
  Normal  ServiceCreated      46s   webapp-operator  created Service production/frontend
  Normal  Ready               44s   webapp-operator  WebApp is Ready (3/3 replicas)
```

Verificación de la propiedad más importante — **el operador creó recursos hijos con ownership**:

```console
$ kubectl -n production get deploy,svc -l app.kubernetes.io/managed-by=webapp-operator
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/frontend   3/3     3            3           46s

NAME               TYPE        CLUSTER-IP      PORT(S)    AGE
service/frontend   ClusterIP   10.96.140.22    8080/TCP   46s

$ kubectl -n production get deploy frontend -o jsonpath='{.metadata.ownerReferences[0]}' | jq
{
  "apiVersion": "apps.example.com/v1alpha1",
  "kind": "WebApp",
  "name": "frontend",
  "uid": "7d9f1a2b-...-c1",
  "controller": true,
  "blockOwnerDeletion": true
}
```

**Prueba de auto-repair (level-triggered en acción):**

```console
$ kubectl -n production delete deploy frontend
deployment.apps "frontend" deleted

$ kubectl -n production get deploy frontend
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   3/3     3            3           3s          # ← el operador lo re-creó solo
```

**Prueba de scale subresource:**

```console
$ kubectl -n production scale webapp/frontend --replicas=5
webapp.apps.example.com/frontend scaled

$ kubectl -n production get webapp frontend
NAME       IMAGE                                  DESIRED   READY   PHASE     AGE
frontend   registry.example.com/frontend:2.7.1    5         5       Ready     3m
```

**Prueba de garbage collection en cascada:**

```console
$ kubectl -n production delete webapp frontend
webapp.apps.example.com "frontend" deleted

$ kubectl -n production get deploy,svc -l app.kubernetes.io/managed-by=webapp-operator
No resources found in production namespace.       # ← hijos borrados por ownerReference
```

### 4.4 Scaffolding con Operator SDK / Kubebuilder (integración del flujo de desarrollo)

```console
$ operator-sdk init --domain example.com --repo github.com/example/webapp-operator
Writing kustomize manifests for you to edit...
Writing scaffold for you to edit...
Get controller runtime:
$ go get sigs.k8s.io/controller-runtime@v0.18.4

$ operator-sdk create api --group apps --version v1alpha1 --kind WebApp --resource --controller
Writing kustomize manifests for you to edit...
api/v1alpha1/webapp_types.go
internal/controller/webapp_controller.go

$ make manifests            # genera CRDs y RBAC desde los // +kubebuilder markers
/home/sre/webapp-operator/bin/controller-gen ... paths="./..." output:crd:artifacts:config=config/crd/bases

$ make docker-build docker-push IMG=registry.example.com/webapp-operator:v0.4.2
$ make deploy IMG=registry.example.com/webapp-operator:v0.4.2
namespace/webapp-operator-system created
customresourcedefinition.apiextensions.k8s.io/webapps.apps.example.com created
deployment.apps/webapp-operator-controller-manager created
```

### 4.5 Operator Lifecycle Manager (OLM) — distribución de nivel plataforma

OLM gestiona el ciclo de vida de los operadores mismos (instalación, upgrades por canal, dependencias, RBAC):

```console
$ operator-sdk olm install
INFO[0000] Fetching CRDs for version "latest"
INFO[0020] Successfully installed OLM version "v0.28.0"

$ kubectl get csv -n operators
NAME                         DISPLAY            VERSION   REPLACES                     PHASE
webapp-operator.v0.4.2       WebApp Operator    0.4.2     webapp-operator.v0.4.1       Succeeded

$ kubectl get subscription,installplan -n operators
NAME                                             PACKAGE           SOURCE              CHANNEL
subscription.operators.coreos.com/webapp-op      webapp-operator   community-catalog   stable

NAME                                             CSV                      APPROVAL    APPROVED
installplan.operators.coreos.com/install-abc12   webapp-operator.v0.4.2   Automatic   true
```

Objetos OLM clave (para reconocer en el examen): **CatalogSource** (repositorio de operadores), **Subscription** (suscripción a un canal), **ClusterServiceVersion / CSV** (metadata + deployment + permisos del operador), **InstallPlan** (plan de instalación aprobable), **OperatorGroup** (define el alcance de namespaces).

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Metodología: leer siempre en este orden

1. **El CR** → `kubectl describe <cr>`: mirá `status.conditions` y los **Events**. El operador debe contarte qué está pasando ahí.
2. **Los logs del operador** → `kubectl -n <op-ns> logs deploy/<operator> -f`.
3. **RBAC** → si los logs dicen `forbidden`, es permisos.
4. **El cache/informer** → si el operador "no ve" cambios, es leader election o watch caído.

### 5.2 Tabla de diagnóstico de fallas frecuentes

| Síntoma | Causa raíz probable | Comando de diagnóstico | Resolución |
|---|---|---|---|
| El CR queda en `Pending`, sin Events | El operador no corre o no observa ese namespace | `kubectl -n op get pods`; `kubectl -n op logs deploy/op` | Verificar Deployment y `--namespace`/OperatorGroup |
| Log: `is forbidden: User "system:serviceaccount:..."` | RBAC insuficiente | `kubectl auth can-i create deployments --as=system:serviceaccount:op:op-sa` | Añadir la regla faltante al ClusterRole |
| `kubectl delete <cr>` **cuelga** para siempre | Finalizer que nunca se remueve (limpieza externa falla o el operador está caído) | `kubectl get <cr> -o jsonpath='{.metadata.finalizers}'` | Arreglar la causa; **último recurso**: quitar finalizer con patch (§5.3) |
| CR aceptó un `spec` inválido | Structural schema incompleto / falta `x-kubernetes-preserve-unknown-fields` mal usado | `kubectl explain`; revisar CRD schema | Endurecer el OpenAPI v3 schema; añadir CEL validation |
| Dos réplicas reconcilian a la vez (recursos parpadean) | `--leader-elect` desactivado | `kubectl -n op get lease` | Activar leader election |
| `error: conversion webhook ... connection refused` | Webhook de conversión caído o cert vencido | `kubectl get validatingwebhookconfigurations`; logs del webhook | Restaurar el servicio de webhook / cert-manager |
| El status nunca refleja el spec nuevo | Falta actualizar `observedGeneration` o no se usa `Status().Update()` | Comparar `.metadata.generation` vs `.status.observedGeneration` | Corregir la lógica de status |
| Reconcile en bucle rápido consumiendo CPU | Update de status dispara un nuevo evento → loop infinito | logs con timestamps muy densos | Usar predicates (`GenerationChangedPredicate`) y status subresource |

### 5.3 Diagnósticos concretos

**Verificar permisos como el propio operador (impersonation):**

```console
$ kubectl auth can-i create deployments \
    --as=system:serviceaccount:webapp-system:webapp-operator -n production
yes

$ kubectl auth can-i update webapps/status \
    --as=system:serviceaccount:webapp-system:webapp-operator
yes
```

**Un CR colgado en borrado por un finalizer** (uno de los incidentes de guardia más comunes):

```console
$ kubectl -n production get webapp frontend -o jsonpath='{.metadata.finalizers}'
["apps.example.com/cleanup"]

$ kubectl -n production get webapp frontend -o jsonpath='{.metadata.deletionTimestamp}'
2026-08-07T11:02:14Z            # ← marcado para borrar, pero bloqueado

# Diagnóstico: ¿por qué no lo quita el operador? Revisar sus logs:
$ kubectl -n webapp-system logs deploy/webapp-operator | grep -i cleanup
ERROR  cleanupExternal failed: dial tcp 10.0.5.7:5432: connect: connection refused

# Resolución correcta: arreglar la dependencia externa para que el finalizer se
# ejecute. SOLO si el recurso externo ya no existe y estás seguro, forzá:
$ kubectl -n production patch webapp frontend --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]'
webapp.apps.example.com/frontend patched
```

> ⚠️ **Advertencia de producción:** quitar un finalizer a mano **salta la limpieza externa** — podés dejar huérfano un bucket, una RDS o un registro DNS que sigue costando dinero. Es un último recurso, no un fix rutinario.

**Detectar drift entre generación y status observada:**

```console
$ kubectl -n production get webapp frontend \
    -o custom-columns='GEN:.metadata.generation,OBSERVED:.status.observedGeneration'
GEN   OBSERVED
4     2                 # ← el operador va 2 generaciones atrasado: revisá su workqueue/logs
```

**Inspeccionar la elección de líder:**

```console
$ kubectl -n webapp-system get lease
NAME                     HOLDER                              AGE
webapp-operator-leader   webapp-operator-6c9f8d7b4c-2xk9p    14m

# El holder es la réplica activa. Si matás ese pod, en ~15s el holder cambia:
$ kubectl -n webapp-system delete pod webapp-operator-6c9f8d7b4c-2xk9p
$ kubectl -n webapp-system get lease -o jsonpath='{.items[0].spec.holderIdentity}'
webapp-operator-6c9f8d7b4c-lm4qt      # ← la standby tomó el liderazgo
```

**Validación del CRD con OLM scorecard (madurez del operador):**

```console
$ operator-sdk scorecard bundle/
--------------------------------------------------------------------------------
Image:      quay.io/example/webapp-operator-bundle:v0.4.2
Labels:
  suite:    basic
Results:
  Name:   basic-check-spec
  State:  pass
  Name:   olm-crds-have-validation
  State:  pass
  Name:   olm-status-descriptors
  State:  fail
  Suggestions:
    Add status descriptors to your CSV for field 'conditions'.
--------------------------------------------------------------------------------
```

### 5.4 Checklist de "definition of done" para un operador en producción

- [ ] CRD con **structural schema** completo (validación, defaults, printer columns).
- [ ] **status subresource** habilitado; conditions en formato `metav1.Condition`; `observedGeneration` actualizado.
- [ ] **ownerReferences** en todos los hijos (GC en cascada probada con un delete).
- [ ] **finalizers** solo si hay estado externo; con test de limpieza y de recuperación ante fallo externo.
- [ ] **RBAC** mínimo verificado con `kubectl auth can-i`.
- [ ] **leader election** activada en despliegues multi-réplica; Lease verificado.
- [ ] **liveness/readiness** probes y **métricas** (`/metrics`) expuestas; regla de PrometheusRule para "reconcile errors".
- [ ] Reconcile **idempotente** y probado ante reinicio del operador (re-sync desde cero).
- [ ] Reconcile **no entra en loop** por sus propios updates (predicates + status subresource).

---

## 6. Referencias

- Kubernetes — *Operator pattern*: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Kubernetes — *Custom Resources / CustomResourceDefinitions*: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes — *Extend the Kubernetes API with CustomResourceDefinitions*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Kubernetes — *Controllers*: https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes — *Owners and Dependents / Garbage Collection*: https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes — *Finalizers*: https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- Kubernetes — *Coordinated Leader Election / Leases*: https://kubernetes.io/docs/concepts/architecture/leases/
- Kubernetes — *Versions in CustomResourceDefinitions (conversion)*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- Kubernetes — *Validation with CEL (x-kubernetes-validations)*: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- The Operator Framework — *Operator SDK*: https://sdk.operatorframework.io/docs/
- The Operator Framework — *Operator Capability Levels*: https://sdk.operatorframework.io/docs/overview/operator-capabilities/
- Operator Lifecycle Manager (OLM): https://olm.operatorframework.io/docs/
- OperatorHub.io: https://operatorhub.io/
- Kubebuilder Book: https://book.kubebuilder.io/
- `sigs.k8s.io/controller-runtime` (godoc): https://pkg.go.dev/sigs.k8s.io/controller-runtime
- CNCF — *CNPA Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CoreOS (2016) — *Introducing Operators* (origen del término): https://web.archive.org/web/20170129131616/https://coreos.com/blog/introducing-operators.html