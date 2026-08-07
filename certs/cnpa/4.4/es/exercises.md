# Ejercicios guiados — Tema 4.4: Kubernetes Operator Pattern for Integration and Automation

> **Objetivo.** Recorrer el patrón Operator de punta a punta: observar el *control loop* de un operator real en producción, diseñar tu propio `CustomResourceDefinition` con schema validado y subresources, implementar un `Reconcile` con Kubebuilder, dominar `finalizers` y `ownerReferences` para el ciclo de vida, y cerrar con el modelo de madurez (Capability Levels) y OLM, que es donde el patrón se vuelve una pieza de *platform engineering* para integración y automatización.
>
> **Prerequisitos.** `kubectl` ≥ 1.29, `kind` ≥ 0.23 (o `minikube`), `docker`/`podman`, `helm` ≥ 3.14, Go ≥ 1.22 y `kubebuilder` ≥ 4.1. Todo corre en un cluster local desechable; nada toca infraestructura compartida.
>
> **Fuentes de referencia.**
> - Operator pattern — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
> - Custom Resources — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
> - CustomResourceDefinitions — https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
> - Kubebuilder Book — https://book.kubebuilder.io/
> - Operator SDK / Capability Levels — https://sdk.operatorframework.io/docs/overview/operator-capabilities/
> - Operator Lifecycle Manager — https://olm.operatorframework.io/docs/

---

## Preparación del entorno

```bash
# 1. Cluster desechable con un nombre explícito
kind create cluster --name cnpa-op --image kindest/node:v1.30.0

# 2. Confirmá el contexto activo (nunca operes a ciegas sobre el cluster equivocado)
kubectl config current-context
# Salida esperada:
# kind-cnpa-op

kubectl get nodes -o wide
# NAME                    STATUS   ROLES           AGE   VERSION
# cnpa-op-control-plane   Ready    control-plane   40s   v1.30.0
```

Trabajá siempre contra `kind-cnpa-op`. Al terminar el módulo: `kind delete cluster --name cnpa-op`.

---

## Ejercicio 1 — Anatomía del patrón sobre un operator real (cert-manager)

Antes de escribir un operator conviene diseccionar uno maduro. cert-manager es ideal: instala CRDs, corre un controller que ejecuta un *reconcile loop*, y automatiza un flujo real (emisión y rotación de certificados) — exactamente la clase de "integración y automatización" que evalúa este dominio.

```bash
# 1. Instalá cert-manager (CRDs + controllers + webhook)
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.15.1 \
  --set crds.enabled=true

# 2. Esperá a que el operator esté listo
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s
# deployment "cert-manager" successfully rolled out

# 3. Mirá QUÉ agregó al API server: los CRDs son la extensión de la API
kubectl get crds | grep cert-manager.io
# certificaterequests.cert-manager.io   2026-08-07T...
# certificates.cert-manager.io          2026-08-07T...
# clusterissuers.cert-manager.io        2026-08-07T...
# issuers.cert-manager.io               2026-08-07T...

# 4. Un CRD registra un nuevo endpoint REST en el API server. Comprobalo:
kubectl api-resources --api-group=cert-manager.io
# NAME                  SHORTNAMES   APIVERSION              NAMESPACED   KIND
# certificaterequests   cr,crs       cert-manager.io/v1      true         CertificateRequest
# certificates          cert,certs   cert-manager.io/v1      true         Certificate
# clusterissuers                     cert-manager.io/v1      false        ClusterIssuer
# issuers                            cert-manager.io/v1      true         Issuer
```

```bash
# 5. Creá un Issuer self-signed y un Certificate: declarás DESEO, no pasos
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: default
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-tls
  namespace: default
spec:
  secretName: demo-tls-secret
  duration: 24h
  renewBefore: 8h
  issuerRef:
    name: selfsigned
    kind: Issuer
  commonName: demo.cnpa.local
  dnsNames:
    - demo.cnpa.local
EOF

# 6. Observá al controller reconciliar el estado deseado hacia el real
kubectl get certificate demo-tls -o wide
# NAME       READY   SECRET            AGE
# demo-tls   True    demo-tls-secret   6s

# 7. El operator MATERIALIZÓ un objeto nativo que vos nunca creaste:
kubectl get secret demo-tls-secret
# NAME               TYPE                DATA   AGE
# demo-tls-secret    kubernetes.io/tls   3      8s

# 8. El status subresource cuenta la historia de la reconciliación
kubectl get certificate demo-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq
# {
#   "lastTransitionTime": "2026-08-07T...",
#   "message": "Certificate is up to date and has not expired",
#   "reason": "Ready",
#   "status": "True",
#   "type": "Ready"
# }

# 9. Rompé el estado real y mirá al control loop repararlo (nivel-based, no edge-based)
kubectl delete secret demo-tls-secret
kubectl get secret demo-tls-secret
# NAME               TYPE                DATA   AGE
# demo-tls-secret    kubernetes.io/tls   3      2s     <-- recreado solo

# 10. Leé el diario del reconcile loop
kubectl -n cert-manager logs deploy/cert-manager --tail=20 | grep -i demo-tls
```

**Preguntas de comprensión — Ejercicio 1**

1. Un `CustomResourceDefinition` y un `CustomResource` no son lo mismo. ¿Qué instala cert-manager en el paso 3 y qué creás vos en el paso 5? ¿Cuál extiende la API y cuál es una instancia?
2. En el paso 9 borraste el `Secret` y reapareció sin que vos hicieras nada. ¿Por qué un control loop *level-based* recupera de esto, mientras que un handler *edge-based* (que solo reacciona a "se creó el Certificate") no lo haría?
3. `Certificate` es *namespaced* pero `ClusterIssuer` es cluster-scoped (paso 4, columna `NAMESPACED`). ¿Qué decide ese scope y dónde se define?
4. El `status` del paso 8 lo escribió el controller, no vos. ¿Por qué es una mala práctica que un cliente humano escriba en `.status`, y qué mecanismo del CRD lo separa de `.spec`?

---

## Ejercicio 2 — Diseñar tu propio CRD: schema OpenAPI, status subresource y printer columns

Ahora construís la *forma* de tu API antes de escribir una línea de controller. Un CRD sin schema acepta cualquier YAML; un CRD de producción valida la entrada en el API server, expone columnas útiles en `kubectl get`, y separa `spec` de `status`.

```bash
# 1. Definí el CRD de un Kind WebApp del grupo platform.example.com
cat <<'EOF' > webapp-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.platform.example.com
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    kind: WebApp
    listKind: WebAppList
    plural: webapps
    singular: webapp
    shortNames: ["wa"]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}                     # separa .status de .spec
        scale:                          # habilita `kubectl scale webapp/...`
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.readyReplicas
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
              required: ["image"]
              properties:
                image:
                  type: string
                  pattern: '^[a-z0-9./:@-]+$'
                replicas:
                  type: integer
                  minimum: 0
                  maximum: 20
                  default: 1
              # rechaza campos no declarados (structural schema)
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
                phase:
                  type: string
                  enum: ["Pending", "Progressing", "Ready", "Degraded"]
                selector:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type: {type: string}
                      status: {type: string}
                      reason: {type: string}
                      message: {type: string}
                      lastTransitionTime: {type: string, format: date-time}
EOF

kubectl apply -f webapp-crd.yaml
# customresourcedefinition.apiextensions.k8s.io/webapps.platform.example.com created

# 2. Esperá a que el API server acepte el nuevo tipo (condición Established)
kubectl wait --for=condition=Established crd/webapps.platform.example.com --timeout=30s
# customresourcedefinition.apiextensions.k8s.io/webapps.platform.example.com condition met
```

```bash
# 3. Probá la validación: el schema DEBE rechazar entradas inválidas
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: WebApp
metadata:
  name: bad
spec:
  image: "nginx:1.27"
  replicas: 99          # viola maximum: 20
EOF
# The WebApp "bad" is invalid: spec.replicas: Invalid value: 99:
#   spec.replicas in body should be less than or equal to 20

cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: WebApp
metadata:
  name: bad2
spec:
  replicas: 2           # falta el campo required "image"
EOF
# The WebApp "bad2" is invalid: spec.image: Required value

# 4. Un CR válido: replicas usa el default del schema
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.example.com/v1alpha1
kind: WebApp
metadata:
  name: hello
  namespace: default
spec:
  image: "nginx:1.27"
EOF
# webapp.platform.example.com/hello created

# 5. Verificá que el default se materializó server-side
kubectl get webapp hello -o jsonpath='{.spec.replicas}{"\n"}'
# 1

# 6. Las printer columns hacen legible el estado (aunque aún no hay controller)
kubectl get webapps
# NAME    IMAGE        DESIRED   READY   PHASE   AGE
# hello   nginx:1.27   1                         12s

# 7. El scale subresource ya funciona ANTES de escribir el controller
kubectl scale webapp/hello --replicas=3
# webapp.platform.example.com/hello scaled
kubectl get webapp hello -o jsonpath='{.spec.replicas}{"\n"}'
# 3
```

**Preguntas de comprensión — Ejercicio 2**

1. En el paso 3 el API server rechazó `replicas: 99` y el `image` faltante *antes* de que ningún controller lo viera. ¿Dónde exactamente ocurrió esa validación y qué propiedad del schema (`x-kubernetes-preserve-unknown-fields` ausente / *structural schema*) la hace posible?
2. Habilitaste el `status` subresource en el CRD. Concretamente, ¿qué cambia eso en cómo se pueden actualizar `.spec` y `.status`, y por qué importa para el *optimistic concurrency* (`resourceVersion`) del controller?
3. En el paso 7 pudiste hacer `kubectl scale` sobre un CR que no gestiona nada todavía. ¿Qué le dio esa capacidad y cómo lo aprovecharía un `HorizontalPodAutoscaler` para escalar tu recurso custom?
4. `served: true` y `storage: true` aparecen en la versión `v1alpha1`. Si mañana agregás `v1beta1`, ¿cuántas versiones pueden tener `storage: true` a la vez y qué componente necesitás para servir ambas?

---

## Ejercicio 3 — Implementar el reconcile loop con Kubebuilder

El CRD define la forma; el *controller* le da comportamiento. Acá scaffoldeás un operator con Kubebuilder e implementás el `Reconcile` que hace converger el estado real (un `Deployment`) hacia el deseado (`WebApp`).

```bash
# 1. Scaffold del proyecto (usá un módulo Go propio)
mkdir webapp-operator && cd webapp-operator
kubebuilder init --domain example.com --repo example.com/webapp-operator
# ... Writing scaffold for you to edit...

# 2. Generá la API (Kind + controller) para el MISMO group/version/kind del Ej. 2
kubebuilder create api --group platform --version v1alpha1 --kind WebApp \
  --resource --controller
# Create Resource [y/n] y
# Create Controller [y/n] y
```

```bash
# 3. Definí el spec/status en api/v1alpha1/webapp_types.go
cat > api/v1alpha1/webapp_types.go <<'EOF'
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type WebAppSpec struct {
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Pattern=`^[a-z0-9./:@-]+$`
	Image string `json:"image"`

	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=20
	// +kubebuilder:default=1
	Replicas int32 `json:"replicas,omitempty"`
}

type WebAppStatus struct {
	ReadyReplicas int32              `json:"readyReplicas,omitempty"`
	Phase         string             `json:"phase,omitempty"`
	Conditions    []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Desired",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
type WebApp struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              WebAppSpec   `json:"spec,omitempty"`
	Status            WebAppStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type WebAppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebApp `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebApp{}, &WebAppList{})
}
EOF
```

```go
// 4. Implementá el corazón del operator en internal/controller/webapp_controller.go
//    (reemplazá el método Reconcile generado por este)

// +kubebuilder:rbac:groups=platform.example.com,resources=webapps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=platform.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete

func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// 1) LEER el estado deseado. NotFound => el CR se borró; nada que hacer.
	var app platformv1alpha1.WebApp
	if err := r.Get(ctx, req.NamespacedName, &app); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2) CONSTRUIR el objeto owned que representa el estado real deseado.
	desired := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: app.Name, Namespace: app.Namespace},
		Spec: appsv1.DeploymentSpec{
			Replicas: &app.Spec.Replicas,
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"webapp": app.Name}},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"webapp": app.Name}},
				Spec: corev1.PodSpec{Containers: []corev1.Container{{
					Name:  "app",
					Image: app.Spec.Image,
				}}},
			},
		},
	}

	// 3) OWNER REFERENCE: ata el ciclo de vida del Deployment al del WebApp.
	if err := ctrl.SetControllerReference(&app, desired, r.Scheme); err != nil {
		return ctrl.Result{}, err
	}

	// 4) RECONCILIAR con CreateOrUpdate: idempotente, converge sin importar el estado previo.
	var found appsv1.Deployment
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client,
		&appsv1.Deployment{ObjectMeta: desired.ObjectMeta},
		func() error {
			found.Spec.Replicas = desired.Spec.Replicas
			found.Spec.Selector = desired.Spec.Selector
			found.Spec.Template = desired.Spec.Template
			return ctrl.SetControllerReference(&app, &found, r.Scheme)
		})
	if err != nil {
		return ctrl.Result{}, err
	}
	log.Info("reconciled deployment", "op", op)

	// 5) ESCRIBIR status: reportar el estado real observado (solo el subresource /status).
	if err := r.Get(ctx, req.NamespacedName, &found); err == nil {
		app.Status.ReadyReplicas = found.Status.ReadyReplicas
		if found.Status.ReadyReplicas == app.Spec.Replicas {
			app.Status.Phase = "Ready"
		} else {
			app.Status.Phase = "Progressing"
		}
		if err := r.Status().Update(ctx, &app); err != nil {
			return ctrl.Result{}, err
		}
	}
	return ctrl.Result{}, nil
}

// 6) OWNS: el controller vigila los Deployments que posee y se re-encola solo.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&platformv1alpha1.WebApp{}).
		Owns(&appsv1.Deployment{}).
		Complete(r)
}
```

```bash
# 5. Generá manifests (CRD + RBAC) desde los markers y compilá
make manifests generate
make install                 # instala el CRD generado en el cluster
# customresourcedefinition.apiextensions.k8s.io/webapps.platform.example.com configured

# 6. Corré el controller LOCALMENTE contra el cluster (out-of-cluster, ideal para debug)
make run
# ... "Starting Controller" controller="webapp" ...
# (dejalo corriendo; abrí otra terminal para los pasos siguientes)
```

```bash
# 7. En OTRA terminal: creá un WebApp y mirá al operator materializar el Deployment
kubectl apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: WebApp
metadata:
  name: shop
spec:
  image: nginx:1.27
  replicas: 2
EOF

kubectl get webapp shop
# NAME   IMAGE        DESIRED   READY   PHASE
# shop   nginx:1.27   2         2       Ready

kubectl get deploy shop -o wide
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES
# shop   2/2     2            2           9s    app          nginx:1.27

# 8. Editá el deseo: el reconcile loop converge de nuevo
kubectl patch webapp shop --type=merge -p '{"spec":{"replicas":4}}'
kubectl get deploy shop
# shop   4/4   4   4   30s

# 9. Rompé el estado real: borrá el Deployment y observá la reconciliación (Owns => re-encola)
kubectl delete deploy shop
kubectl get deploy shop   # reaparece en segundos, recreado por el controller
```

**Preguntas de comprensión — Ejercicio 3**

1. `Reconcile` recibe solo un `NamespacedName` (`req`), no el objeto ni "qué cambió". ¿Por qué el patrón entrega tan poca información y cómo se relaciona eso con que el reconcile deba ser *idempotente* y *level-based*?
2. En el paso 9 borraste el `Deployment` y el controller lo recreó. ¿Qué línea del `SetupWithManager` hizo que el borrado de un objeto *owned* re-encolara al `WebApp` padre, y por medio de qué campo del `Deployment` lo relacionó?
3. El status lo escribís con `r.Status().Update(...)` y el spec con `r.Update(...)`. ¿Qué pasaría si intentaras escribir `.status` con un `Update` normal en un CRD que tiene el status subresource habilitado?
4. Usaste `controllerutil.CreateOrUpdate` en vez de `Create`. Si el operator crashea justo después de crear el `Deployment` pero antes de escribir el status, ¿por qué la siguiente reconciliación no duplica ni rompe nada?
5. `make run` corre el controller *fuera* del cluster con tus credenciales de `kubectl`. Nombrá una diferencia de seguridad y una operativa respecto de desplegarlo *in-cluster* con `make deploy`.

---

## Ejercicio 4 — Finalizers, owner references y garbage collection

El ciclo de vida completo es lo que separa un operator "de instalación" de uno de producción. Acá ves las dos mitades: borrado *en cascada* automático vía `ownerReferences`, y limpieza de recursos *externos* vía `finalizers`.

```bash
# 1. Owner reference => garbage collection en cascada. Inspeccioná al Deployment del Ej.3
kubectl get deploy shop -o jsonpath='{.metadata.ownerReferences}' | jq
# [
#   {
#     "apiVersion": "platform.example.com/v1alpha1",
#     "kind": "WebApp",
#     "name": "shop",
#     "controller": true,
#     "blockOwnerDeletion": true,
#     "uid": "..."
#   }
# ]

# 2. Borrá el owner (WebApp). El GC borra al Deployment owned SIN que el controller intervenga
kubectl delete webapp shop
kubectl get deploy shop
# Error from server (NotFound): deployments.apps "shop" not found

# 3. Ahora el otro caso: un recurso EXTERNO que el GC no puede limpiar solo.
#    Simulá un finalizer y observá cómo bloquea el borrado.
kubectl apply -f - <<'EOF'
apiVersion: platform.example.com/v1alpha1
kind: WebApp
metadata:
  name: db-backed
  finalizers:
    - platform.example.com/cleanup-external-bucket
spec:
  image: nginx:1.27
  replicas: 1
EOF

# 4. Pedí el borrado. NO desaparece: queda en Terminating con deletionTimestamp seteado
kubectl delete webapp db-backed --wait=false
kubectl get webapp db-backed
# NAME        IMAGE        DESIRED   READY   PHASE
# db-backed   nginx:1.27   1                 ...

kubectl get webapp db-backed -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
# 2026-08-07T...Z            <-- marcado para borrar, pero el finalizer lo retiene

# 5. Esto es lo que hace tu Reconcile en el bloque de borrado: liberar el recurso
#    externo y RECIÉN AHÍ quitar el finalizer. Lo simulamos a mano:
kubectl patch webapp db-backed --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers/0"}]'

# 6. Removido el último finalizer, el API server completa el borrado
kubectl get webapp db-backed
# Error from server (NotFound): webapps.platform.example.com "db-backed" not found
```

El patrón real dentro de `Reconcile` (para incluir en tu controller):

```go
const finalizer = "platform.example.com/cleanup-external-bucket"

if app.ObjectMeta.DeletionTimestamp.IsZero() {
    // No se está borrando: asegurá que el finalizer esté presente.
    if !controllerutil.ContainsFinalizer(&app, finalizer) {
        controllerutil.AddFinalizer(&app, finalizer)
        return ctrl.Result{}, r.Update(ctx, &app)
    }
} else {
    // Se está borrando: ejecutá la limpieza externa y quitá el finalizer.
    if controllerutil.ContainsFinalizer(&app, finalizer) {
        if err := r.deleteExternalBucket(ctx, &app); err != nil {
            return ctrl.Result{}, err // reintenta; el objeto sigue retenido
        }
        controllerutil.RemoveFinalizer(&app, finalizer)
        return ctrl.Result{}, r.Update(ctx, &app)
    }
    return ctrl.Result{}, nil
}
```

**Preguntas de comprensión — Ejercicio 4**

1. En el paso 2, borrar el `WebApp` borró el `Deployment` sin que el controller estuviera involucrado. ¿Qué componente del `kube-controller-manager` hizo eso y qué campo (`controller: true` vs `ownerReference` a secas) determina el borrado en cascada?
2. En el paso 4 el objeto quedó en `Terminating` en vez de desaparecer. Explicá el mecanismo: qué setea el API server, por qué el objeto sigue existiendo, y qué evento *no* llega hasta que se quita el finalizer.
3. Si un operator con finalizer se desinstala (borrás su `Deployment`) mientras existen CRs con ese finalizer, ¿qué le pasa a un `kubectl delete` de esos CRs y cómo se recupera un cluster de ese *stuck terminating*?
4. `blockOwnerDeletion: true` aparece en el `ownerReference`. ¿Qué previene y qué permiso (`update` sobre el `finalizers` subresource del owner) requiere quien lo setea?
5. ¿Por qué la limpieza de un recurso *externo* (un bucket S3, una DB) necesita un finalizer, mientras que un `Deployment` interno owned no lo necesita?

---

## Ejercicio 5 — RBAC del operator, OLM y Capability Levels

Un operator es *platform engineering*: corre con permisos, se distribuye, se actualiza y madura por capacidades. Este ejercicio conecta el código con cómo se opera en un cluster real.

```bash
# 1. Inspeccioná el RBAC que Kubebuilder generó desde los markers +kubebuilder:rbac
cat config/rbac/role.yaml
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRole
# rules:
# - apiGroups: ["platform.example.com"]
#   resources: ["webapps"]
#   verbs: ["get","list","watch","create","update","patch","delete"]
# - apiGroups: ["platform.example.com"]
#   resources: ["webapps/status"]
#   verbs: ["get","update","patch"]
# - apiGroups: ["apps"]
#   resources: ["deployments"]
#   verbs: ["get","list","watch","create","update","patch","delete"]

# 2. Principio de mínimo privilegio: el operator NO pide "*". Verificá el ServiceAccount
grep -r "serviceAccountName" config/manager/manager.yaml
# serviceAccountName: webapp-operator-controller-manager

# 3. Desplegá el operator IN-CLUSTER (como corre en producción)
make docker-build docker-push IMG=example.com/webapp-operator:v0.1.0
kind load docker-image example.com/webapp-operator:v0.1.0 --name cnpa-op
make deploy IMG=example.com/webapp-operator:v0.1.0

kubectl -n webapp-operator-system get deploy
# NAME                                    READY   UP-TO-DATE   AVAILABLE
# webapp-operator-controller-manager      1/1     1            1

# 4. Comprobá que el operator usa SU identidad, no la tuya: revisá el binding
kubectl get clusterrolebinding webapp-operator-manager-rolebinding -o wide
# ROLE                                    SERVICEACCOUNTS
# ClusterRole/webapp-operator-manager-role  webapp-operator-system/...controller-manager
```

```bash
# 5. (Opcional, Capability Level 2) Instalá OLM para distribución y upgrades gestionados
curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh \
  | bash -s v0.28.0
kubectl get ns olm
# NAME   STATUS   AGE
# olm    Active   30s

# OLM introduce sus propios CRDs para gestionar el ciclo de vida DE los operators:
kubectl get crds | grep operators.coreos.com
# catalogsources.operators.coreos.com
# clusterserviceversions.operators.coreos.com     <-- el "empaquetado" de un operator
# installplans.operators.coreos.com
# subscriptions.operators.coreos.com              <-- upgrades automáticos por canal
```

Modelo de madurez (Operator Capability Levels — https://sdk.operatorframework.io/docs/overview/operator-capabilities/):

| Level | Nombre | Qué demuestra tu operator |
|-------|--------|---------------------------|
| 1 | Basic Install | Aprovisiona el workload (Ej. 3: crea el Deployment) |
| 2 | Seamless Upgrades | Maneja upgrades de la app y del propio operator (OLM Subscription) |
| 3 | Full Lifecycle | Backup, restore, failover, limpieza (Ej. 4: finalizers) |
| 4 | Deep Insights | Métricas, alertas, análisis del workload (status conditions, `/metrics`) |
| 5 | Auto Pilot | Auto-scaling, auto-tuning, auto-remediation sin intervención humana |

**Preguntas de comprensión — Ejercicio 5**

1. El `role.yaml` del paso 1 lista verbos explícitos por recurso en vez de `verbs: ["*"]`. Más allá del principio de mínimo privilegio, si un atacante compromete el pod del operator, ¿en qué se diferencia el *blast radius* de un operator con RBAC acotado frente a uno con `cluster-admin`?
2. Tu operator necesita `watch` sobre `deployments` pero solo `get;update;patch` sobre `webapps/status`. ¿Por qué no necesita `create` ni `delete` sobre el status subresource?
3. En OLM, ¿qué rol cumplen un `ClusterServiceVersion` y una `Subscription`, y cuál de los dos habilita concretamente el Capability Level 2 (Seamless Upgrades)?
4. Ubicá cada pieza que ya construiste en la tabla de Capability Levels: el `CreateOrUpdate` del Ej. 3, los `finalizers` del Ej. 4, y las `status.conditions` del schema. ¿A qué nivel llega hoy tu operator y qué te falta para el Level 5?
5. Un operator que corre in-cluster (`make deploy`) usa un `ServiceAccount` dedicado; corriéndolo con `make run` usa tus credenciales de `kubectl`. ¿Por qué el segundo modo puede *ocultar* un bug de RBAC que recién aparece en producción?

---

## Respuestas

<details>
<summary><strong>Ver respuestas de todos los ejercicios</strong></summary>

### Ejercicio 1

1. **CRD vs CR.** cert-manager instala **CustomResourceDefinitions** (`certificates.cert-manager.io`, `issuers…`, etc.): son la *definición del tipo*, y registran nuevos endpoints REST en el API server (`/apis/cert-manager.io/v1/...`). En el paso 5 vos creás **Custom Resources**: `Issuer/selfsigned` y `Certificate/demo-tls` son *instancias* de esos tipos. El CRD extiende la API; el CR es un objeto concreto que el controller reconcilia. Un CRD sin controller solo agrega almacenamiento tipado; el comportamiento lo aporta el operator.
2. **Level-based vs edge-based.** Un control loop *level-based* compara continuamente el estado deseado (`spec`) con el estado real observado y actúa sobre la *diferencia*, sin importar cómo se llegó ahí. Por eso al borrar el `Secret`, en la siguiente reconciliación el controller lo ve ausente y lo recrea. Un handler *edge-based* solo reacciona a *transiciones* ("se creó el Certificate") y perdería el evento de borrado del Secret o cualquier drift que ocurra fuera de su vista; además, un evento perdido (controller reiniciado, cola llena) nunca se recupera. El patrón Operator es deliberadamente level-based y por eso `Reconcile` recomputa desde cero en cada invocación.
3. **Scope.** Lo decide el campo `spec.scope` del CRD (`Namespaced` o `Cluster`). `Certificate` es `Namespaced` (vive en un namespace, se lista con `-n`), `ClusterIssuer` es `Cluster` (global, sin namespace). El scope afecta también el RBAC: un recurso cluster-scoped requiere `ClusterRole`/`ClusterRoleBinding`.
4. **Status subresource.** `.status` describe *lo observado por el controller*, no *lo deseado por el usuario*. Si un humano escribe `.status`, miente sobre la realidad y puede disparar reconciliaciones erróneas. El CRD lo separa con `subresources.status: {}`: eso crea un endpoint `/status` aparte, de modo que un `update` del objeto principal **no** persiste cambios en `.status` (y viceversa), y cada uno lleva su propio control de concurrencia.

### Ejercicio 2

1. **Dónde valida.** La validación ocurre en el **API server**, durante el *admission* de la request, contra el `openAPIV3Schema` del CRD — antes de persistir en etcd y antes de que ningún controller lo observe. Es posible porque el schema es **structural** (todos los campos declarados con tipos, sin `x-kubernetes-preserve-unknown-fields: true` en la raíz): un schema structural permite que el API server rechace campos desconocidos, aplique `minimum`/`maximum`/`pattern`/`required` y complete `default`s server-side.
2. **Status subresource.** Con `subresources.status: {}`, `.spec` y `.status` se actualizan por endpoints separados: un `PUT`/`PATCH` al objeto principal ignora cambios en `.status`, y solo un `PUT` a `/status` los persiste. Beneficios: (a) un usuario no puede falsear el status; (b) actualizar el status no incrementa la `generation` (que rastrea cambios de `spec`), lo que permite comparar `.metadata.generation` con `.status.observedGeneration`; (c) cada endpoint mantiene su `resourceVersion`, reduciendo conflictos de *optimistic concurrency* cuando el controller escribe status mientras el usuario edita spec.
3. **Scale subresource.** El bloque `subresources.scale` con `specReplicasPath`/`statusReplicasPath`/`labelSelectorPath` expone un endpoint `/scale`, habilitando `kubectl scale` y — clave — permitiendo que un `HorizontalPodAutoscaler` apunte su `scaleTargetRef` al `WebApp`: el HPA lee/escribe replicas por ese endpoint estándar sin saber nada del tipo custom.
4. **Versiones.** Solo **una** versión puede tener `storage: true` a la vez (es la que se persiste en etcd); las demás pueden tener `served: true` para ser leídas/escritas. Para servir `v1alpha1` y `v1beta1` simultáneamente con esquemas distintos necesitás un **conversion webhook** que traduzca entre la versión servida y la versión de almacenamiento.

### Ejercicio 3

1. **Por qué solo `req`.** El patrón es deliberadamente *level-based*: `Reconcile` recibe únicamente la identidad del objeto (`NamespacedName`) y debe **leer el estado actual y recomputar todo desde cero**, sin depender de "qué cambió". Eso lo fuerza a ser **idempotente** (correrlo N veces produce el mismo resultado) y robusto ante eventos perdidos, reordenados o duplicados, y ante reinicios del controller. La *workqueue* deduplica y reintenta con backoff por esa misma razón.
2. **Owns.** La línea `.Owns(&appsv1.Deployment{})` en `SetupWithManager`. Establece un *watch* sobre `Deployment`s y, cuando uno cambia o se borra, usa su `metadata.ownerReferences` (el que setea `SetControllerReference`) para encontrar al `WebApp` dueño y **re-encolarlo**. Así el borrado del Deployment dispara una reconciliación del padre, que lo recrea.
3. **Update vs Status().Update.** Con el status subresource habilitado, un `r.Update(...)` normal **descarta silenciosamente** los cambios en `.status` (solo persiste `.metadata`/`.spec`). Para escribir el status hay que usar el endpoint dedicado `r.Status().Update(...)`. Al revés también: `Status().Update` no persiste cambios de spec.
4. **Idempotencia de CreateOrUpdate.** `CreateOrUpdate` hace un `Get` y decide crear o actualizar según exista o no, aplicando la *mutate function* que fija el estado deseado. Si el operator crashea tras crear el Deployment y antes del status, la siguiente reconciliación vuelve a leer todo: encuentra el Deployment ya existente, confirma que coincide con lo deseado (no-op) y escribe el status. No duplica porque la operación converge al mismo estado sin importar cuántas veces corra.
5. **run vs deploy.** *Seguridad:* `make run` usa **tus** credenciales de kubectl (típicamente amplias), así que un bug de RBAC del operator pasa inadvertido; in-cluster usa un `ServiceAccount` acotado y falla si le falta un permiso. *Operativo:* `make run` corre como proceso local (se muere si cerrás la terminal, sin HA, sin resiliencia ni leader election), mientras que in-cluster corre como `Deployment` reiniciable, con probes, límites de recursos y posibilidad de réplicas con *leader election*.

### Ejercicio 4

1. **Cascade GC.** Lo hace el **garbage collector** del `kube-controller-manager`. El borrado en cascada se dispara por la presencia de `ownerReferences` que apuntan al objeto borrado; el flag `controller: true` marca al *managing controller* (relevante para `blockOwnerDeletion` y para evitar dos dueños "controladores"), pero para el GC alcanza con que exista el ownerReference. Con `propagationPolicy: Background`/`Foreground` el owner y sus owned se borran juntos.
2. **Terminating.** Cuando pedís el borrado y hay finalizers, el API server **no borra**: setea `metadata.deletionTimestamp` y deja el objeto en `Terminating`. El objeto sigue existiendo y visible; el borrado real (remoción de etcd) **no** ocurre hasta que la lista `metadata.finalizers` quede **vacía**. El controller observa el `deletionTimestamp`, ejecuta su limpieza y recién entonces quita su finalizer.
3. **Operator desinstalado con finalizers colgados.** Si el controller que "posee" el finalizer ya no existe, nadie lo quita: los CRs quedan en `Terminating` **para siempre** (`kubectl delete` cuelga). Recuperación: reinstalar el operator para que drene la limpieza, o — si es seguro — editar el objeto y borrar el finalizer manualmente (`kubectl patch ... -p '[{"op":"remove","path":"/metadata/finalizers/0"}]'`), asumiendo la deuda de limpieza externa a mano.
4. **blockOwnerDeletion.** Previene que el owner sea eliminado de etcd por el GC *antes* de que este dependiente sea borrado (útil con `Foreground` deletion). Setearlo/editarlo requiere permiso de `update` sobre el **subresource `finalizers`** del tipo owner, por eso Kubebuilder puede pedir `.../finalizers` en el RBAC.
5. **Externo vs interno.** Un `Deployment` owned se limpia solo vía cascade GC porque vive *dentro* de la API de Kubernetes y el GC lo alcanza por `ownerReference`. Un recurso **externo** (bucket, registro DNS, fila en una DB) es invisible para el GC; nadie lo borra automáticamente. El finalizer es el único gancho que garantiza que el controller *ejecute código de limpieza* antes de que el CR desaparezca, evitando *leaks* de infraestructura.

### Ejercicio 5

1. **Blast radius.** Con RBAC acotado, comprometer el pod del operator solo concede lo que el operator podía hacer (aquí: gestionar `webapps` y `deployments`). Con `cluster-admin`, el atacante hereda control total del cluster: leer todos los `Secret`s, crear pods privilegiados, moverse lateralmente, borrar cualquier recurso. El RBAC de mínimo privilegio convierte un compromiso del operator en un incidente contenido en vez de un *cluster takeover*.
2. **Verbos del status.** `.status` de un `WebApp` existe siempre que exista el `WebApp` (el subresource es parte del mismo objeto); no se crea ni se borra por separado — su ciclo de vida lo maneja el objeto padre por el endpoint principal. El controller solo necesita **leer y actualizar** el status (`get;update;patch`), nunca `create`/`delete` sobre `webapps/status`.
3. **OLM.** El **ClusterServiceVersion (CSV)** es el manifiesto que *empaqueta* una versión del operator: su Deployment, RBAC, CRDs owned, dependencias y metadatos. La **Subscription** ata una instalación a un *channel* de un `CatalogSource` y, cuando aparece una CSV más nueva en ese canal, OLM crea un `InstallPlan` y actualiza el operator. La **Subscription** es la que habilita el **Capability Level 2 (Seamless Upgrades)**: upgrades automáticos y gobernados por canal.
4. **Ubicación en la tabla.** El `CreateOrUpdate` que aprovisiona el `Deployment` = **Level 1 (Basic Install)**. Los `finalizers` con limpieza = parte de **Level 3 (Full Lifecycle)**. Las `status.conditions` + un endpoint `/metrics` = base de **Level 4 (Deep Insights)**. Hoy el operator cubre sólido el Level 1 y parte del 3/4. Para **Level 5 (Auto Pilot)** falta lógica autónoma: auto-scaling reactivo (leer métricas y ajustar replicas), auto-remediation (detectar `Degraded` y corregir), y auto-tuning sin intervención humana.
5. **run oculta bugs de RBAC.** `make run` ejecuta el controller con **tus** credenciales de kubectl, que suelen ser amplias (a menudo admin). Si el `Reconcile` accede a un recurso para el que el `ServiceAccount` del operator *no* tiene permiso, en modo `run` funciona igual (usás tu identidad), pero al desplegarlo in-cluster con su `ServiceAccount` acotado el mismo llamado devuelve `Forbidden`. El bug de RBAC solo aparece en producción; por eso conviene probar in-cluster (o con `--as=system:serviceaccount:...` para *impersonar* el SA del operator) antes de confiar en el operator.

</details>