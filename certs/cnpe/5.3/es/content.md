# 5.3 Uso de Kubernetes Operators para Automatización e Integración de Plataforma

> **CNPE — Dominio 5 (Platform Automation & Integration) · Peso en el examen: 6,25 %**
> Perfil: Platform Architect / SRE Senior. Este material asume dominio previo de `Deployment`, `Service`, RBAC, `client-go` a nivel conceptual y el modelo declarativo de Kubernetes.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 El límite de los recursos declarativos "planos"

Kubernetes resuelve muy bien el **estado deseado de recursos sin estado y de ciclo de vida trivial**: un `Deployment` describe "quiero N réplicas de esta imagen" y el `Deployment controller` + `ReplicaSet controller` mantienen esa invariante. El modelo funciona porque el conocimiento operacional necesario para reconciliar un `Deployment` es **genérico y cerrado**: crear/borrar Pods.

El problema aparece cuando la unidad que la plataforma debe operar **no es un Pod, sino un sistema con conocimiento operacional propio**:

- Un cluster de PostgreSQL en HA necesita elegir un primary, promover un replica ante failover, hacer `pg_rewind` del ex-primary, rotar WAL, ejecutar `pg_basebackup` para bootstrap de nuevos miembros y orquestar upgrades de versión mayor sin pérdida de datos.
- Un cluster de Kafka necesita reasignar particiones al escalar brokers, drenar un broker antes de retirarlo (`kafka-reassign-partitions`), y coordinar rolling restarts respetando `min.insync.replicas`.
- Un `Certificate` necesita hablar ACME con Let's Encrypt, resolver un challenge DNS-01, renovar antes del vencimiento y recrear el `Secret`.

Ese conocimiento **no cabe en un `Deployment`**. En una plataforma tradicional vive en runbooks, scripts de un SRE, o un pipeline de CI que corre `helm upgrade` y reza. Esto genera tres patologías de producción:

1. **Deriva operacional (operational drift):** el estado real se aparta del deseado entre ejecuciones del pipeline. Nadie reconcilia hasta la próxima corrida manual.
2. **Conocimiento no codificado:** el "cómo se opera esto" está en la cabeza de una persona. Es el antipatrón del *snowflake* a escala de servicio.
3. **Day-2 sin dueño:** instalar es fácil (day-1); operar upgrades, backups, failover y scaling (day-2) es donde muere la plataforma.

### 1.2 El Operator pattern como respuesta arquitectónica

El **Operator pattern** (acuñado por CoreOS en 2016) codifica el conocimiento de un operador humano en software que corre *dentro* del cluster y usa la propia API de Kubernetes como plano de control. Formalmente, un Operator es:

> **Operator = Custom Resource Definition (CRD) + Controller**
> — una extensión de la API que introduce un tipo de recurso nuevo (`PostgresCluster`, `Certificate`, `KafkaTopic`) **más** un proceso que corre un **reconciliation loop** sobre instancias de ese tipo, aplicando conocimiento de dominio para llevar el estado real al deseado.

La consecuencia arquitectónica clave para platform engineering: **el Operator convierte una operación imperativa (un runbook) en una API declarativa**. El developer ya no ejecuta pasos; declara `kind: PostgresCluster, instances: 3` y el conocimiento de day-2 queda del lado de la plataforma, versionado, testeado y auditable. Esto es lo que habilita el **self-service** de un Internal Developer Platform (IDP): el equipo de plataforma publica CRDs como su *contrato de API*, y los operators son la implementación de ese contrato.

### 1.3 El control loop y por qué es *level-triggered*

El corazón de todo Operator es el **reconciliation loop**. Su semántica es **level-triggered**, no **edge-triggered**, y entender esta distinción es material de examen y de producción:

- **Edge-triggered:** reacciono al *evento* de cambio ("se creó X", "se borró Y"). Si pierdo el evento (reinicio, partición, cola llena), quedo desincronizado para siempre.
- **Level-triggered:** reacciono al *estado actual observado* ("el mundo está en estado S; ¿coincide con el deseado?"). Si pierdo un evento no importa: en la próxima reconciliación vuelvo a leer el estado completo y corrijo la diferencia.

```
                    ┌──────────────────────────────────────┐
                    │              Reconcile()               │
                    │                                        │
   watch/informer   │  1. observe:  read desired (spec)      │
  ┌──────────────►  │              read actual (cluster)     │
  │  (cache)        │  2. diff:     desired vs actual        │
  │                 │  3. act:      create/update/delete      │
  │                 │  4. update:   status/conditions        │
  │                 │  5. return:   {Requeue, RequeueAfter,  │
  │                 │                Err}                     │
  │                 └──────────────────┬─────────────────────┘
  │                                    │ requeue
  └────────────────────────────────────┘
```

Por eso un Reconcile bien escrito es **idempotente**: correrlo N veces sobre el mismo estado produce el mismo resultado. Nunca asume "esto es nuevo" ni "esto ya existe"; siempre observa y converge. Esta propiedad es la que hace que un Operator sobreviva a reinicios, a re-sincronizaciones periódicas del informer (`resync period`) y a eventos duplicados.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Operator vs. las alternativas de empaquetado/automatización

| Dimensión | Raw manifests (`kubectl apply`) | Helm chart | GitOps (Argo CD / Flux) | **Operator** |
|---|---|---|---|---|
| Modelo de ejecución | Imperativo, one-shot | Templating one-shot | Reconciliación de *manifiestos* (level-triggered) | Reconciliación de *dominio* (level-triggered) |
| Conocimiento day-2 | Ninguno | Ninguno (solo `helm upgrade`) | Ninguno (solo drift de manifiestos) | **Sí — failover, backup, scaling, upgrades** |
| Corrige drift automáticamente | No | No | Sí (del YAML), no del estado interno | **Sí, del estado real del sistema** |
| Estado interno del sistema | Invisible | Invisible | Invisible | **Modelado en `.status` + conditions** |
| Extiende la API de K8s | No | No | No | **Sí (CRD = nuevo `kind`)** |
| Complejidad de construcción | Trivial | Baja | Baja-media | **Alta (código de controller)** |
| Superficie de fallo | Nula (no hay proceso) | Nula | Un controller genérico | **Un controller con permisos amplios** |
| Ideal para | ConfigMaps, Jobs simples | Apps stateless con muchos parámetros | Entrega continua de manifiestos | **Software stateful/complejo con day-2** |

**Regla de arquitectura:** GitOps y Operators son **complementarios, no rivales**. El patrón de producción dominante es *GitOps entrega los CRs, el Operator los reconcilia*: Argo CD/Flux versiona un `PostgresCluster` en Git y lo aplica; el Postgres Operator hace el day-2. No reemplaces un Operator por GitOps ni viceversa.

**Regla de decisión "build vs. use":** el costo real de un Operator no es escribirlo, es *mantenerlo* (seguir upstream, parchear CVEs, testear upgrades). Construí un Operator propio solo cuando el conocimiento de dominio es tuyo y no existe upstream. Para PostgreSQL, Kafka, Redis, Prometheus, cert-manager, etc., **usá el Operator maduro de la comunidad**. En platform engineering, el 90 % del trabajo es *integrar y operar* Operators existentes, no escribirlos.

### 2.2 Frameworks para construir Operators

| Framework | Lenguaje | Curva | Cuándo usarlo | Límite |
|---|---|---|---|---|
| **Kubebuilder** | Go | Media-alta | Lógica compleja, performance, control fino sobre `controller-runtime` | Requiere saber Go |
| **Operator SDK (Go)** | Go | Media-alta | Igual que Kubebuilder + integración OLM/scorecard nativa | Requiere saber Go |
| **Operator SDK (Ansible)** | YAML/Jinja | Baja | Envolver playbooks existentes; equipos con skill Ansible | Reconciliación más lenta y opaca |
| **Operator SDK (Helm)** | YAML | Muy baja | "Operatorizar" un chart existente; solo install/upgrade | **Sin lógica day-2 real** (nivel de capacidad 1-2) |
| **Metacontroller** | Cualquiera (webhook) | Baja-media | Lógica de reconciliación como función stateless (JSON→JSON) | No maneja estado propio ni finalizers avanzados |
| **KUDO** | YAML (declarativo) | Baja | Operators declarativos por "planes" | Proyecto con menor tracción |

> **Nota clave:** Operator SDK y Kubebuilder **comparten el mismo core** (`controller-runtime` + `controller-tools`). Operator SDK es esencialmente Kubebuilder + tooling de OLM, scorecard y backends Ansible/Helm. Si tu destino es el ecosistema OperatorHub/OLM (OpenShift), Operator SDK; si querés el camino "vanilla" upstream, Kubebuilder.

### 2.3 Operator Capability Levels (modelo de madurez)

El **Operator Maturity Model** de operatorframework.io define 5 niveles. Es material de examen y una excelente checklist de "¿qué tan production-grade es este Operator?":

| Nivel | Nombre | Qué garantiza | Señal técnica |
|---|---|---|---|
| **1** | Basic Install | Instala y configura el workload | Reconcilia `spec` → Deployment/StatefulSet |
| **2** | Seamless Upgrades | Upgrades del operand y del operator sin intervención | Maneja versionado, migraciones de schema |
| **3** | Full Lifecycle | Backup, restore, failover, scaling | Sub-recursos: `Backup`, `Restore` CRs |
| **4** | Deep Insights | Métricas, alertas, logs, `ServiceMonitor`, dashboards | Expone `/metrics`, `PrometheusRule` |
| **5** | Auto Pilot | Auto-scaling, auto-healing, auto-tuning basado en señales | Reacciona a métricas: reasigna, tunea, remedia |

**Implicancia de plataforma:** al *seleccionar* un Operator para tu catálogo, exigí como mínimo **nivel 3** para software stateful crítico (sin backup/restore automatizado no hay day-2 real) y **nivel 4** si tu SLO depende de observabilidad. Un Operator "Helm-based" rara vez pasa del nivel 2.

---

## 3. Manifiestos e infraestructura completos

Esta sección construye un Operator de ejemplo de punta a punta: un `WebApp` que gestiona un `Deployment` + `Service`, con status subresource, conditions, finalizer, RBAC de mínimo privilegio, leader election, webhook de validación y observabilidad. Todos los manifiestos son sintácticamente válidos y aplicables.

### 3.1 CustomResourceDefinition (la extensión de API)

Este es el contrato de API que la plataforma publica. Incluye validación OpenAPI v3, `status` subresource, `scale` subresource (habilita `kubectl scale` y el HPA), *additional printer columns* y versionado con estrategia de conversión.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.platform.example.com
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    plural: webapps
    singular: webapp
    kind: WebApp
    shortNames:
      - wa
    categories:
      - platform
  versions:
    - name: v1alpha1
      served: true
      storage: false          # servida para compatibilidad, ya no es la de almacenamiento
      deprecated: true
      deprecationWarning: "platform.example.com/v1alpha1 WebApp is deprecated; use v1"
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: ["image", "replicas"]
              properties:
                image:
                  type: string
                replicas:
                  type: integer
                  minimum: 0
    - name: v1
      served: true
      storage: true           # exactamente UNA versión puede ser storage:true
      subresources:
        status: {}            # habilita .status como subresource (updates separados de spec)
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
          labelSelectorPath: .status.selector
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
                  pattern: '^[a-z0-9./:@-]+$'
                replicas:
                  type: integer
                  minimum: 0
                  maximum: 50
                  default: 1
                resources:
                  type: object
                  properties:
                    cpu:
                      type: string
                      default: "100m"
                    memory:
                      type: string
                      default: "128Mi"
                ingressHost:
                  type: string
              # validación cruzada declarativa (CEL, GA desde K8s 1.29):
              x-kubernetes-validations:
                - rule: "self.replicas <= 10 || has(self.resources)"
                  message: "resources es obligatorio cuando replicas > 10"
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: ["Pending", "Progressing", "Ready", "Degraded"]
                replicas:
                  type: integer
                readyReplicas:
                  type: integer
                selector:
                  type: string
                observedGeneration:
                  type: integer
                  format: int64
                conditions:
                  type: array
                  items:
                    type: object
                    required: ["type", "status", "lastTransitionTime", "reason"]
                    properties:
                      type:
                        type: string
                      status:
                        type: string
                        enum: ["True", "False", "Unknown"]
                      observedGeneration:
                        type: integer
                        format: int64
                      lastTransitionTime:
                        type: string
                        format: date-time
                      reason:
                        type: string
                      message:
                        type: string
                  x-kubernetes-list-type: map
                  x-kubernetes-list-map-keys: ["type"]
      # estrategia de conversión entre v1alpha1 y v1
  conversion:
    strategy: Webhook
    webhook:
      conversionReviewVersions: ["v1"]
      clientConfig:
        service:
          namespace: webapp-system
          name: webapp-conversion-webhook
          path: /convert
          port: 443
        # caBundle lo inyecta cert-manager (ver 3.6)
```

> **Puntos finos de producción:**
> - **`storage: true` en exactamente una versión.** Es el formato en el que etcd persiste el objeto; el resto se convierten al leer/escribir.
> - **`status: {}` como subresource** hace que `UpdateStatus()` no toque `spec` y **no incremente `metadata.generation`**. Esto es lo que permite comparar `status.observedGeneration` contra `metadata.generation` para saber si el controller ya "vio" el último cambio de spec.
> - **`x-kubernetes-list-type: map`** sobre `conditions` evita conflictos de merge en `apply` server-side y es requisito de las `metav1.Condition` estándar.
> - **CEL (`x-kubernetes-validations`)** mueve validación cruzada al API server: falla el `apply` sin necesidad de webhook, reduciendo superficie de fallo.

### 3.2 Custom Resource (la instancia que declara el developer)

```yaml
apiVersion: platform.example.com/v1
kind: WebApp
metadata:
  name: checkout
  namespace: shop
spec:
  image: registry.example.com/checkout:2.3.1
  replicas: 3
  resources:
    cpu: "250m"
    memory: "256Mi"
  ingressHost: checkout.shop.example.com
```

### 3.3 El Reconciler (código real, `controller-runtime` / Kubebuilder)

El manifiesto sin el controller es una API vacía. Este es el `Reconcile` idempotente que le da vida. Incluye `CreateOrUpdate`, manejo de finalizer, y actualización de conditions con `observedGeneration`.

```go
// internal/controller/webapp_controller.go
package controller

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "example.com/webapp-operator/api/v1"
)

const finalizerName = "platform.example.com/finalizer"

// +kubebuilder:rbac:groups=platform.example.com,resources=webapps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=platform.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=platform.example.com,resources=webapps/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

type WebAppReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	l := log.FromContext(ctx)

	// 1. OBSERVE: leer el estado deseado. Si desapareció, no hay nada que hacer.
	var app platformv1.WebApp
	if err := r.Get(ctx, req.NamespacedName, &app); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2. Manejo de borrado vía finalizer (cleanup ordenado antes de la GC).
	if !app.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&app, finalizerName) {
			if err := r.cleanupExternalResources(ctx, &app); err != nil {
				return ctrl.Result{}, err // reintenta hasta que el cleanup tenga éxito
			}
			controllerutil.RemoveFinalizer(&app, finalizerName)
			if err := r.Update(ctx, &app); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Asegurar el finalizer ANTES de crear recursos externos.
	if controllerutil.AddFinalizer(&app, finalizerName) {
		if err := r.Update(ctx, &app); err != nil {
			return ctrl.Result{}, err
		}
	}

	// 3. ACT: reconciliar el Deployment de forma idempotente.
	deploy := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: app.Name, Namespace: app.Namespace}}
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		deploy.Spec = r.desiredDeploymentSpec(&app)
		// owner reference: habilita garbage collection en cascada.
		return controllerutil.SetControllerReference(&app, deploy, r.Scheme)
	})
	if err != nil {
		r.setCondition(&app, "Available", metav1.ConditionFalse, "DeploymentError", err.Error())
		_ = r.Status().Update(ctx, &app)
		return ctrl.Result{}, err
	}
	l.Info("reconciled deployment", "operation", op)

	// 4. UPDATE STATUS: reflejar el estado observado (level-triggered).
	var live appsv1.Deployment
	if err := r.Get(ctx, types.NamespacedName{Name: app.Name, Namespace: app.Namespace}, &live); err != nil {
		return ctrl.Result{}, err
	}
	app.Status.Replicas = live.Status.Replicas
	app.Status.ReadyReplicas = live.Status.ReadyReplicas
	app.Status.ObservedGeneration = app.Generation
	if live.Status.ReadyReplicas == app.Spec.Replicas {
		app.Status.Phase = "Ready"
		r.setCondition(&app, "Available", metav1.ConditionTrue, "AllReplicasReady",
			fmt.Sprintf("%d/%d replicas ready", live.Status.ReadyReplicas, app.Spec.Replicas))
	} else {
		app.Status.Phase = "Progressing"
		r.setCondition(&app, "Available", metav1.ConditionFalse, "ReplicasNotReady",
			fmt.Sprintf("%d/%d replicas ready", live.Status.ReadyReplicas, app.Spec.Replicas))
	}
	if err := r.Status().Update(ctx, &app); err != nil {
		if errors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil // otro writer ganó; reintentar
		}
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *WebAppReconciler) setCondition(app *platformv1.WebApp, t string, s metav1.ConditionStatus, reason, msg string) {
	meta := metav1.Condition{
		Type: t, Status: s, Reason: reason, Message: msg,
		ObservedGeneration: app.Generation,
	}
	// meta.SetStatusCondition sólo cambia lastTransitionTime si el status cambia.
	apimeta_SetStatusCondition(&app.Status.Conditions, meta)
}

// SetupWithManager registra el controller y sus watches (owns Deployment).
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1.WebApp{}).
		Owns(&appsv1.Deployment{}). // re-encola el WebApp cuando su Deployment hijo cambia
		Owns(&corev1.Service{}).
		Complete(r)
}
```

**Por qué cada pieza importa en producción:**

- **`client.IgnoreNotFound`**: el objeto pudo borrarse entre el evento y el `Get`. No es un error.
- **`SetControllerReference` + `Owns()`**: la owner reference habilita **garbage collection en cascada** (borrás el `WebApp`, el `Deployment` se va solo) y hace que un cambio en el hijo **re-encole al padre** — cierra el loop level-triggered.
- **Finalizer**: garantiza cleanup de recursos *externos* al cluster (buckets, DNS, entradas en una DB) antes de que el objeto desaparezca. Sin él, el borrado deja huérfanos.
- **`errors.IsConflict` → `Requeue`**: los updates son *optimistic-locked* por `resourceVersion`. Un conflicto no es fatal: se re-lee y se reintenta.

### 3.4 Deployment del controller + RBAC de mínimo privilegio

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: webapp-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp-controller
  namespace: webapp-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: webapp-controller-role
rules:
  - apiGroups: ["platform.example.com"]
    resources: ["webapps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["platform.example.com"]
    resources: ["webapps/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["platform.example.com"]
    resources: ["webapps/finalizers"]
    verbs: ["update"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: webapp-controller-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: webapp-controller-role
subjects:
  - kind: ServiceAccount
    name: webapp-controller
    namespace: webapp-system
---
# Permiso separado y acotado para leader election (Lease en su namespace).
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: webapp-leader-election
  namespace: webapp-system
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["configmaps", "events"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: webapp-leader-election
  namespace: webapp-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: webapp-leader-election
subjects:
  - kind: ServiceAccount
    name: webapp-controller
    namespace: webapp-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-controller
  namespace: webapp-system
  labels:
    app.kubernetes.io/name: webapp-operator
    control-plane: controller-manager
spec:
  replicas: 2                     # HA: leader election garantiza un único reconciler activo
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      labels:
        control-plane: controller-manager
    spec:
      serviceAccountName: webapp-controller
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: manager
          image: registry.example.com/webapp-operator:v1.2.0
          args:
            - "--leader-elect"
            - "--health-probe-bind-address=:8081"
            - "--metrics-bind-address=:8443"
            - "--metrics-secure=true"
          ports:
            - name: metrics
              containerPort: 8443
            - name: health
              containerPort: 8081
          livenessProbe:
            httpGet: { path: /healthz, port: 8081 }
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet: { path: /readyz, port: 8081 }
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { memory: "256Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

> **Leader election y HA:** con `replicas: 2` y `--leader-elect`, ambas réplicas arrancan pero **solo la que sostiene el `Lease` reconcilia**; la otra queda en *standby* y toma el relevo en segundos si el líder cae. Esto evita la condición de carrera de dos controllers escribiendo el mismo objeto (que causaría *update storms* por conflicto de `resourceVersion`). **Nunca corras un Operator activo-activo sin leader election.**

### 3.5 Observabilidad (nivel de capacidad 4): `ServiceMonitor` + alertas

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-controller-metrics
  namespace: webapp-system
  labels:
    control-plane: controller-manager
spec:
  ports:
    - name: metrics
      port: 8443
      targetPort: metrics
  selector:
    control-plane: controller-manager
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: webapp-controller
  namespace: webapp-system
spec:
  selector:
    matchLabels:
      control-plane: controller-manager
  endpoints:
    - port: metrics
      scheme: https
      path: /metrics
      interval: 30s
      bearerTokenSecret:
        name: ""    # Prometheus usa su propia SA
      tlsConfig:
        insecureSkipVerify: true
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: webapp-operator-slo
  namespace: webapp-system
spec:
  groups:
    - name: webapp-operator.rules
      rules:
        # Cola de trabajo creciendo => el reconciler no da abasto o está trabado.
        - alert: OperatorWorkqueueBacklog
          expr: workqueue_depth{name="webapp"} > 50
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "Backlog de reconciliación en webapp-operator"
        # Tasa de errores de reconciliación alta.
        - alert: OperatorReconcileErrors
          expr: |
            sum(rate(controller_runtime_reconcile_errors_total{controller="webapp"}[5m]))
            /
            sum(rate(controller_runtime_reconcile_total{controller="webapp"}[5m])) > 0.1
          for: 15m
          labels: { severity: critical }
          annotations:
            summary: ">10% de reconciliaciones de webapp fallan"
        # Nadie sostiene el lease => no hay líder => no se reconcilia nada.
        - alert: OperatorNoLeader
          expr: sum(leader_election_master_status{name="webapp"}) < 1
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "webapp-operator sin líder activo"
```

Las métricas `controller_runtime_reconcile_total`, `controller_runtime_reconcile_errors_total`, `controller_runtime_reconcile_time_seconds` y `workqueue_depth` las emite `controller-runtime` **gratis**; son tu ventana al health del control loop.

### 3.6 Admission webhook de validación (con cert-manager)

Los webhooks son el mecanismo para validar/mutar CRs *antes* de que se persistan. cert-manager inyecta el `caBundle` vía anotación.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webapp-webhook-cert
  namespace: webapp-system
spec:
  secretName: webapp-webhook-tls
  dnsNames:
    - webapp-webhook.webapp-system.svc
    - webapp-webhook.webapp-system.svc.cluster.local
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: webapp-validating-webhook
  annotations:
    cert-manager.io/inject-ca-from: webapp-system/webapp-webhook-cert
webhooks:
  - name: vwebapp.platform.example.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail          # <- decisión crítica: ver diagnóstico 5.4
    timeoutSeconds: 10
    rules:
      - apiGroups: ["platform.example.com"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["webapps"]
    clientConfig:
      service:
        namespace: webapp-system
        name: webapp-webhook
        path: /validate-platform-example-com-v1-webapp
        port: 443
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "webapp-system"]   # nunca te auto-bloquees
```

### 3.7 Integración vía OLM (Operator Lifecycle Manager)

En plataformas basadas en OLM (OpenShift, o OLM instalado en vanilla), no aplicás el Deployment del controller a mano: declarás una `Subscription` y OLM resuelve dependencias, instala, y hace upgrades según un canal.

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: platform-operators
  namespace: webapp-system
spec:
  targetNamespaces:
    - webapp-system      # el operator solo vigila este namespace (own-namespace mode)
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: platform-catalog
  namespace: olm
spec:
  sourceType: grpc
  image: registry.example.com/platform-catalog:v1
  displayName: Platform Operators
  publisher: Platform Team
  updateStrategy:
    registryPoll:
      interval: 30m
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: webapp-operator
  namespace: webapp-system
spec:
  channel: stable
  name: webapp-operator
  source: platform-catalog
  sourceNamespace: olm
  installPlanApproval: Manual    # gate humano/GitOps antes de aplicar upgrades
  config:
    resources:
      requests: { cpu: "100m", memory: "128Mi" }
```

> **`installPlanApproval: Manual`** es el patrón production-grade: OLM crea un `InstallPlan` pero *no lo ejecuta* hasta que alguien (o un pipeline) lo aprueba. Esto convierte los upgrades de operator en un cambio revisable, no en algo que ocurre solo un martes a las 3 AM.

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Descubrir e inspeccionar la API extendida

```console
$ kubectl apply -f config/crd/webapps.yaml
customresourcedefinition.apiextensions.k8s.io/webapps.platform.example.com created

$ kubectl get crd | grep platform
webapps.platform.example.com          2026-08-07T14:22:10Z

$ kubectl api-resources --api-group=platform.example.com
NAME       SHORTNAMES   APIVERSION                    NAMESPACED   KIND
webapps    wa           platform.example.com/v1       true         WebApp

$ kubectl explain webapp.spec --api-version=platform.example.com/v1
GROUP:      platform.example.com
KIND:       WebApp
VERSION:    v1

FIELD: spec <Object>

DESCRIPTION:
    <empty>
FIELDS:
  image        <string> -required-
  ingressHost  <string>
  replicas     <integer> -required-
  resources    <Object>
```

### 4.2 Crear un CR y observar la reconciliación

```console
$ kubectl apply -f checkout-webapp.yaml
webapp.platform.example.com/checkout created

$ kubectl get webapp -n shop
NAME       IMAGE                              DESIRED   READY   PHASE         AGE
checkout   registry.example.com/checkout...   3         0       Progressing   4s

$ kubectl get webapp -n shop -w
NAME       IMAGE                              DESIRED   READY   PHASE         AGE
checkout   registry.example.com/checkout...   3         0       Progressing   4s
checkout   registry.example.com/checkout...   3         1       Progressing   12s
checkout   registry.example.com/checkout...   3         3       Ready         21s

$ kubectl get deploy,svc -n shop -l app.kubernetes.io/managed-by=webapp-operator
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/checkout   3/3     3            3           21s
NAME               TYPE        CLUSTER-IP      PORT(S)   AGE
service/checkout   ClusterIP   10.96.140.22    80/TCP    21s
```

### 4.3 Leer el status y las conditions (la verdad del Operator)

```console
$ kubectl get webapp checkout -n shop -o jsonpath='{.status}' | jq
{
  "phase": "Ready",
  "replicas": 3,
  "readyReplicas": 3,
  "observedGeneration": 1,
  "selector": "app=checkout",
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "AllReplicasReady",
      "message": "3/3 replicas ready",
      "observedGeneration": 1,
      "lastTransitionTime": "2026-08-07T14:25:03Z"
    }
  ]
}

$ kubectl describe webapp checkout -n shop
...
Status:
  Observed Generation:  1
  Phase:                Ready
  Ready Replicas:       3
Events:
  Type    Reason              Age   From             Message
  ----    ------              ----  ----             -------
  Normal  DeploymentCreated   30s   webapp-operator  Created Deployment shop/checkout
  Normal  Reconciled          21s   webapp-operator  WebApp is Ready
```

### 4.4 Scale vía el scale subresource (funciona porque el CRD lo declara)

```console
$ kubectl scale webapp checkout -n shop --replicas=5
webapp.platform.example.com/checkout scaled

$ kubectl get webapp checkout -n shop
NAME       IMAGE                              DESIRED   READY   PHASE         AGE
checkout   registry.example.com/checkout...   5         3       Progressing   2m
```

### 4.5 Ciclo de vida vía OLM

```console
$ kubectl get subscription,csv,installplan -n webapp-system
NAME                                                PACKAGE           SOURCE             CHANNEL
subscription.operators.coreos.com/webapp-operator   webapp-operator   platform-catalog   stable

NAME                                              DISPLAY          VERSION   REPLACES          PHASE
clusterserviceversion.operators.coreos.com/webapp-operator.v1.2.0   WebApp Operator   1.2.0     webapp-operator.v1.1.0   Succeeded

NAME                                             CSV                       APPROVAL   APPROVED
installplan.operators.coreos.com/install-x7k2p   webapp-operator.v1.3.0    Manual     false

# Aprobar el upgrade pendiente (gate manual):
$ kubectl patch installplan install-x7k2p -n webapp-system \
    --type merge -p '{"spec":{"approved":true}}'
installplan.operators.coreos.com/install-x7k2p patched
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Checklist de verificación (¿el Operator está sano?)

```console
# 1. ¿El controller está corriendo y hay líder?
$ kubectl get pods -n webapp-system -l control-plane=controller-manager
NAME                                 READY   STATUS    RESTARTS   AGE
webapp-controller-6d4b9c8f7-abcde    1/1     Running   0          5m
webapp-controller-6d4b9c8f7-fghij    1/1     Running   0          5m

$ kubectl get lease -n webapp-system
NAME                 HOLDER                              AGE
webapp-operator      webapp-controller-6d4b9c8f7-abcde   5m   # <- hay líder ✔

# 2. ¿Reconcilia sin errores? (métricas controller-runtime)
$ kubectl exec -n webapp-system deploy/webapp-controller -- \
    wget -qO- http://localhost:8080/metrics | grep reconcile_total
controller_runtime_reconcile_total{controller="webapp",result="success"} 142
controller_runtime_reconcile_total{controller="webapp",result="error"} 0

# 3. ¿Todos los CRs convergen? (observedGeneration == generation)
$ kubectl get webapp -A -o json | jq -r \
  '.items[] | select(.metadata.generation != .status.observedGeneration)
   | "\(.metadata.namespace)/\(.metadata.name) NO CONVERGIÓ"'
# (salida vacía = todos convergieron ✔)
```

### 5.2 El indicador clave: `generation` vs `observedGeneration`

Este es el diagnóstico más potente y menos usado. Cada cambio de `spec` incrementa `metadata.generation`. Un controller sano copia `generation` a `status.observedGeneration` cuando termina de reconciliar. Por lo tanto:

- `generation > observedGeneration` → **el controller aún no procesó el último cambio** (está atrasado, trabado, o muerto).
- `generation == observedGeneration` **pero** `phase != Ready` → el controller lo procesó pero **no pudo converger** (mirá conditions/eventos).

### 5.3 Fallas comunes y su diagnóstico

| Síntoma | Causa raíz probable | Diagnóstico | Remediación |
|---|---|---|---|
| El CR se crea pero no pasa nada | Controller sin RBAC sobre el recurso hijo | `kubectl logs` muestra `is forbidden: ... cannot create deployments` | Ampliar `ClusterRole`; regenerar con markers `+kubebuilder:rbac` |
| `observedGeneration` estancado | Reconciler paniquea o hay líder muerto sin relevo | `kubectl logs` + `kubectl get lease` | Reiniciar; revisar panic; verificar RBAC de `leases` |
| Todo el cluster no puede crear el CR | Webhook con `failurePolicy: Fail` y su Pod caído | `Error ... failed calling webhook ...: connection refused` | Restaurar el webhook, o `failurePolicy: Ignore` provisorio |
| CR "colgado" en `Terminating` | Finalizer que nunca se remueve (cleanup falla) | `kubectl get -o yaml` muestra `finalizers:` y `deletionTimestamp` | Arreglar el cleanup; como último recurso, quitar finalizer a mano |
| `helm/kubectl delete` deja huérfanos | Falta owner reference o el finalizer no limpia lo externo | `kubectl get deploy --show-labels` sin ownerReferences | Agregar `SetControllerReference` |
| OLM `CSV Pending` para siempre | `OperatorGroup` ausente o `InstallPlan` no aprobado | `kubectl describe csv` / `get installplan` | Crear `OperatorGroup`; aprobar `InstallPlan` |
| Update storm / `resourceVersion conflict` | Dos réplicas reconciliando sin leader election | Logs con `the object has been modified` en loop | Habilitar `--leader-elect` |
| Reconcile lento / backlog | `RequeueAfter` demasiado agresivo o `Get` sin cache | `workqueue_depth` alto, `reconcile_time_seconds` alto | Usar el cache del manager; bajar frecuencia de requeue |

### 5.4 Diagnóstico profundo de un webhook que bloquea el cluster

El fallo más peligroso: un `ValidatingWebhookConfiguration` con `failurePolicy: Fail` cuyo backend cae. Como el API server *debe* consultarlo antes de admitir el objeto y no puede, **falla toda operación** que matchee las `rules` — potencialmente incluyendo la creación de los Pods que revivirían el propio webhook (deadlock).

```console
$ kubectl apply -f checkout-webapp.yaml
Error from server (InternalError): error when creating "checkout-webapp.yaml":
Internal error occurred: failed calling webhook "vwebapp.platform.example.com":
failed to call webhook: Post "https://webapp-webhook.webapp-system.svc:443/validate...":
dial tcp 10.96.3.10:443: connect: connection refused

# Confirmar que el backend está caído:
$ kubectl get pods -n webapp-system -l control-plane=controller-manager
NAME                                 READY   STATUS             RESTARTS   AGE
webapp-controller-6d4b9c8f7-abcde    0/1     CrashLoopBackOff   6          10m

# Mitigación de emergencia: neutralizar el webhook para desbloquear la API.
$ kubectl patch validatingwebhookconfiguration webapp-validating-webhook \
    --type merge -p '{"webhooks":[{"name":"vwebapp.platform.example.com","failurePolicy":"Ignore"}]}'
```

**Prevenciones de diseño (material de examen):**
1. `namespaceSelector` que **excluya `kube-system` y el namespace del propio operator** (ya está en 3.6) — evita el deadlock de auto-bloqueo.
2. `timeoutSeconds` bajo (≤10) para que un webhook lento no cuelgue la API.
3. `failurePolicy: Ignore` para webhooks de *mutación no crítica*; `Fail` solo para invariantes de seguridad que preferís que rompan el `apply` antes que admitir algo inválido.
4. HA del backend del webhook (≥2 réplicas, PDB).

### 5.5 CR atascado en `Terminating` por finalizer

```console
$ kubectl delete webapp checkout -n shop
webapp.platform.example.com "checkout" deleted     # <- se cuelga acá

$ kubectl get webapp checkout -n shop -o jsonpath='{.metadata.finalizers}'
["platform.example.com/finalizer"]

# ¿Por qué no se remueve? El cleanup del controller falla:
$ kubectl logs -n webapp-system deploy/webapp-controller | grep cleanup
ERROR  cleanupExternalResources failed  {"error": "DNS record delete: 403 forbidden"}

# Solución correcta: arreglar el permiso/lógica del cleanup y dejar que el
# controller remueva el finalizer solo. ÚLTIMO RECURSO (deja huérfanos):
$ kubectl patch webapp checkout -n shop \
    --type json -p '[{"op":"remove","path":"/metadata/finalizers/0"}]'
```

> **Advertencia de producción:** quitar un finalizer a mano **salta el cleanup** y puede dejar recursos externos huérfanos (registros DNS, buckets, entradas de facturación). Es un martillo, no una solución. Primero arreglá la causa.

### 5.6 Anti-patrones a auditar en cualquier Operator del catálogo

- **`ClusterRole` con `["*"]` en `resources`/`verbs`** o binding a `cluster-admin`: un Operator comprometido es *game over* del cluster. Exigí RBAC de mínimo privilegio (validá con `kubectl auth can-i --list --as=system:serviceaccount:...`).
- **Reconcile no idempotente** (asume "esto es la primera vez"): rompe ante reinicio o resync.
- **`spec` mutado por el controller**: el controller **nunca** debe escribir en `.spec` del CR (ese es el input del usuario). Solo `.status`.
- **Sin `status`/conditions**: convierte el debugging en adivinanza. Nivel de capacidad 1 disfrazado.
- **CRD sin versionado ni conversion**: bloquea la evolución de la API; un breaking change rompe todos los CRs existentes.
- **Un solo replica sin leader election** para un Operator crítico: SPOF del control plane de tu plataforma.

---

## Referencias

- **Operator pattern — documentación oficial de Kubernetes:** https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- **Custom Resources / CustomResourceDefinitions:** https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- **Extend the Kubernetes API with CustomResourceDefinitions (versionado, subresources, conversion):** https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- **CRD versioning y conversion webhooks:** https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- **Validation con CEL (`x-kubernetes-validations`):** https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules
- **Dynamic Admission Control (validating/mutating webhooks):** https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Finalizers y garbage collection:** https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/ · https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- **sample-controller (referencia canónica de un controller con client-go):** https://github.com/kubernetes/sample-controller
- **Kubebuilder Book:** https://book.kubebuilder.io/
- **controller-runtime (GoDoc):** https://pkg.go.dev/sigs.k8s.io/controller-runtime
- **Operator SDK:** https://sdk.operatorframework.io/docs/
- **Operator Capability Levels (modelo de madurez):** https://operatorframework.io/operator-capabilities/
- **Operator Lifecycle Manager (OLM):** https://olm.operatorframework.io/docs/
- **OperatorHub.io (catálogo de la comunidad):** https://operatorhub.io/
- **cert-manager (CA injection para webhooks):** https://cert-manager.io/docs/concepts/ca-injector/
- **Prometheus Operator — ServiceMonitor / PrometheusRule:** https://prometheus-operator.dev/docs/
- **CNCF — Operator White Paper (TAG App Delivery):** https://github.com/cncf/tag-app-delivery/blob/main/operator-wg/whitepaper/Operator-WhitePaper_v1-0.md
- **CNPE Curriculum (fuente del temario):** https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf