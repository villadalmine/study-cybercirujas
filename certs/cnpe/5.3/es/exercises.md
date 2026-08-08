# Ejercicios Guiados — Tema 5.3: Using Kubernetes Operators for Platform Automation and Integration

> **Certificación:** CNPE · **Peso:** 6.25 %
> **Prerrequisitos:** un cluster funcional (kind, minikube o k3s sirven), `kubectl` con contexto activo, `helm` v3, acceso a Internet para bajar imágenes y CRDs. Algunos ejercicios instalan `operator-sdk` y `olm`.
> **Objetivo:** operar el *Operator pattern* de punta a punta — entender el control loop y las CRDs, instalar y explotar operators reales de plataforma (cert-manager, CloudNativePG), gestionar su ciclo de vida con OLM, y finalmente scaffoldear un operator propio para ver la reconciliación desde adentro.

Trabajaremos casi todo dentro de un namespace dedicado para poder limpiar sin residuos:

```bash
kubectl create namespace demo-operators
kubectl config set-context --current --namespace=demo-operators
```

---

## Ejercicio 1 — Anatomía del patrón Operator: CRDs, Custom Resources y el control loop

Un Operator no es más que un **controller** que extiende la API de Kubernetes con **Custom Resource Definitions (CRDs)** y ejecuta un *reconciliation loop*: observa el estado deseado (`.spec`) de un Custom Resource, lo compara con el estado real del cluster, y actúa para converger. Antes de instalar operators de terceros, vamos a mirar la maquinaria expuesta por la API.

### Pasos

1. Listá los grupos de API que tu cluster expone hoy, para tener una línea de base antes de instalar CRDs:

   ```bash
   kubectl api-resources --api-group='' | head -n 5
   kubectl get crd
   ```

   En un cluster limpio, `kubectl get crd` devuelve `No resources found`.

2. Instalá un operator real (cert-manager) para materializar CRDs nuevas. Usaremos su manifiesto oficial, que trae CRDs + controller + webhook:

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
   ```

3. Observá qué CRDs registró en la API:

   ```bash
   kubectl get crd | grep cert-manager.io
   ```

   Salida esperada (abreviada):

   ```
   certificaterequests.cert-manager.io   2026-08-07T...
   certificates.cert-manager.io          2026-08-07T...
   clusterissuers.cert-manager.io        2026-08-07T...
   issuers.cert-manager.io               2026-08-07T...
   orders.acme.cert-manager.io           2026-08-07T...
   ```

4. Inspeccioná la definición de una CRD concreta. Fijate en el `scope`, los `versions`, y sobre todo en el `subresource` `status`:

   ```bash
   kubectl get crd certificates.cert-manager.io -o yaml | \
     yq '.spec.scope, .spec.versions[].name, .spec.versions[].subresources'
   ```

   Verás `scope: Namespaced`, la versión `v1`, y un subresource `status: {}`. Ese subresource es clave: separa el estado deseado (`.spec`, que escribe el usuario) del estado observado (`.status`, que escribe **solo** el controller).

5. Identificá el controller que hace de "cerebro" del operator y mirá su log — ahí vive el control loop:

   ```bash
   kubectl -n cert-manager get deploy
   kubectl -n cert-manager logs deploy/cert-manager --tail=15
   ```

**Preguntas de comprensión (bloque 1):**

- 1a. ¿Qué tres cosas aporta típicamente un Operator a la API de Kubernetes que un simple Deployment no aporta?
- 1b. ¿Por qué el subresource `status` se escribe con un endpoint distinto (`/status`) al del objeto principal, y qué problema de concurrencia evita esa separación?
- 1c. Si borrás el pod del controller de cert-manager, ¿desaparecen las CRDs y los Custom Resources ya creados? ¿Por qué?

---

## Ejercicio 2 — Explotar un operator de integración: cert-manager emitiendo certificados

Ahora usamos cert-manager como lo que es en una plataforma: un componente que **automatiza la emisión y renovación de certificados TLS** e integra con Issuers (self-signed, CA interna, ACME/Let's Encrypt, Vault). Vamos a declarar el estado deseado y observar cómo el operator lo reconcilia.

### Pasos

1. Creá un `Issuer` self-signed (el emisor más simple, sin dependencias externas):

   ```yaml
   # issuer.yaml
   apiVersion: cert-manager.io/v1
   kind: Issuer
   metadata:
     name: selfsigned-issuer
     namespace: demo-operators
   spec:
     selfSigned: {}
   ```

   ```bash
   kubectl apply -f issuer.yaml
   kubectl get issuer selfsigned-issuer -o wide
   ```

   Esperá a ver `READY  True`.

2. Declará un `Certificate`. Observá que vos NO generás la clave ni el cert: solo describís el resultado deseado y el operator lo produce:

   ```yaml
   # certificate.yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: example-cert
     namespace: demo-operators
   spec:
     secretName: example-cert-tls
     duration: 2160h      # 90 días
     renewBefore: 360h    # renovar 15 días antes de expirar
     commonName: example.svc.cluster.local
     dnsNames:
       - example.svc.cluster.local
       - example.demo-operators.svc
     privateKey:
       algorithm: RSA
       encoding: PKCS1
       size: 2048
     usages:
       - server auth
       - client auth
     issuerRef:
       name: selfsigned-issuer
       kind: Issuer
       group: cert-manager.io
   ```

   ```bash
   kubectl apply -f certificate.yaml
   ```

3. Observá la reconciliación en tiempo real. El operator crea internamente un `CertificateRequest`, lo firma con el Issuer, y materializa un `Secret` de tipo `kubernetes.io/tls`:

   ```bash
   kubectl get certificate,certificaterequest,secret -l controller.cert-manager.io/fao=true
   kubectl describe certificate example-cert | sed -n '/Events:/,$p'
   ```

   Eventos esperados:

   ```
   Events:
     Type    Reason     Age   From                          Message
     ----    ------     ----  ----                          -------
     Normal  Issuing    30s   cert-manager-certificates     Issuing certificate as Secret does not exist
     Normal  Generated  30s   cert-manager-certificates     Stored new private key in temporary Secret resource
     Normal  Requested  30s   cert-manager-certificates     Created new CertificateRequest resource
     Normal  Issuing    29s   cert-manager-certificates     The certificate has been successfully issued
   ```

4. Verificá el `Secret` producido y decodificá el certificado para leer su validez:

   ```bash
   kubectl get secret example-cert-tls -o jsonpath='{.data.tls\.crt}' | \
     base64 -d | openssl x509 -noout -subject -dates
   ```

   Salida esperada (fechas aproximadas):

   ```
   subject=CN = example.svc.cluster.local
   notBefore=Aug  7 ...
   notAfter=Nov  5 ...    # ~90 días después
   ```

5. Probá el bucle de reconciliación como *self-healing*: borrá el Secret y observá que el operator lo vuelve a crear sin intervención tuya.

   ```bash
   kubectl delete secret example-cert-tls
   sleep 5
   kubectl get secret example-cert-tls
   ```

   El Secret reaparece: el `.spec` del Certificate declara que debe existir, y el controller reconcilia la diferencia.

**Preguntas de comprensión (bloque 2):**

- 2a. En el flujo `Certificate → CertificateRequest → Secret`, ¿cuál de esos objetos declara la intención del usuario y cuáles son artefactos internos gestionados por el operator?
- 2b. ¿Qué hace que el Secret reaparezca automáticamente tras borrarlo? Nombrá el mecanismo y el campo del CR que lo dispara.
- 2c. El campo `renewBefore: 360h` no lo evalúa un cron externo. ¿Quién y cuándo decide que hay que renovar, y qué patrón de diseño de controllers lo hace posible sin polling agresivo?

---

## Ejercicio 3 — Ciclo de vida con Operator Lifecycle Manager (OLM)

En una plataforma real no instalás operators a mano con `kubectl apply` de un YAML gigante: usás **OLM**, que gestiona instalación, dependencias, RBAC, versiones y upgrades declarativos mediante `Subscription`, `ClusterServiceVersion (CSV)`, `CatalogSource` y `OperatorGroup`. Vamos a instalar OLM y suscribirnos a un operator desde un catálogo.

### Pasos

1. Instalá OLM en el cluster usando `operator-sdk` (o el instalador oficial):

   ```bash
   operator-sdk olm install
   # Alternativa sin operator-sdk:
   # curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.28.0/install.sh | bash -s v0.28.0
   ```

2. Verificá que OLM levantó sus propios componentes y CRDs:

   ```bash
   kubectl get pods -n olm
   kubectl get crd | grep operators.coreos.com
   ```

   CRDs esperadas: `catalogsources`, `clusterserviceversions`, `installplans`, `operatorgroups`, `subscriptions`.

3. Inspeccioná el catálogo por defecto (operatorhubio) y buscá un operator:

   ```bash
   kubectl get catalogsource -n olm
   kubectl get packagemanifest | head
   ```

4. Creá un `OperatorGroup` en tu namespace (define el alcance de watch del operator):

   ```yaml
   # operatorgroup.yaml
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: demo-og
     namespace: demo-operators
   spec:
     targetNamespaces:
       - demo-operators
   ```

   ```bash
   kubectl apply -f operatorgroup.yaml
   ```

5. Suscribite a un operator declarando una `Subscription`. OLM resolverá un `InstallPlan`, creará el `ClusterServiceVersion` y desplegará el controller:

   ```yaml
   # subscription.yaml
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: cloudnative-pg
     namespace: demo-operators
   spec:
     channel: stable-v1
     name: cloudnative-pg
     source: operatorhubio-catalog
     sourceNamespace: olm
     installPlanApproval: Manual
   ```

   ```bash
   kubectl apply -f subscription.yaml
   ```

6. Como pusimos `installPlanApproval: Manual`, OLM **espera tu aprobación** antes de instalar. Aprobá el InstallPlan:

   ```bash
   kubectl get installplan -n demo-operators
   # Marcá approved: true en el InstallPlan generado
   kubectl patch installplan <install-plan-name> -n demo-operators \
     --type merge -p '{"spec":{"approved":true}}'
   ```

7. Seguí la transición del CSV hasta `Succeeded`:

   ```bash
   kubectl get csv -n demo-operators -w
   ```

   Fase esperada: `Pending → InstallReady → Installing → Succeeded`.

**Preguntas de comprensión (bloque 3):**

- 3a. ¿Qué rol cumple cada uno de estos objetos de OLM: `CatalogSource`, `Subscription`, `InstallPlan`, `ClusterServiceVersion`, `OperatorGroup`?
- 3b. ¿Qué diferencia práctica introduce `installPlanApproval: Manual` frente a `Automatic` en una plataforma de producción, y por qué te importaría en un upgrade de un operator que gestiona bases de datos?
- 3c. El `OperatorGroup` con `targetNamespaces: [demo-operators]` restringe algo importante. ¿Qué restringe, y cómo se relaciona con el RBAC que OLM genera para el controller?

---

## Ejercicio 4 — Automatización de plataforma: CloudNativePG operando un cluster PostgreSQL

Con el operator instalado por OLM, ahora lo explotamos para lo que fue diseñado: **gestionar un cluster de PostgreSQL con alta disponibilidad de forma declarativa** — provisioning, replicación streaming, failover automático y self-healing. Este es el corazón de "platform automation": encapsular conocimiento operativo (día 2) en un controller.

### Pasos

1. Declará un `Cluster` de PostgreSQL con 3 instancias (1 primary + 2 replicas):

   ```yaml
   # pg-cluster.yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: pg-demo
     namespace: demo-operators
   spec:
     instances: 3
     imageName: ghcr.io/cloudnative-pg/postgresql:16.4
     primaryUpdateStrategy: unsupervised
     storage:
       size: 1Gi
     bootstrap:
       initdb:
         database: appdb
         owner: appuser
   ```

   ```bash
   kubectl apply -f pg-cluster.yaml
   ```

2. Observá cómo el operator provisiona los Pods, PVCs y Services de forma ordenada (primero el primary, luego se unen las replicas por streaming replication):

   ```bash
   kubectl get cluster pg-demo -o wide
   kubectl get pods,pvc,svc -l cnpg.io/cluster=pg-demo
   ```

   Salida esperada (una vez estable):

   ```
   NAME      AGE   INSTANCES   READY   STATUS                     PRIMARY
   pg-demo   3m    3           3       Cluster in healthy state   pg-demo-1
   ```

   Notá los Services que el operator crea automáticamente: `pg-demo-rw` (read-write → primary), `pg-demo-ro` (read-only → replicas), `pg-demo-r` (cualquier instancia). Esa es la **capa de integración**: tus apps apuntan a un Service estable y el operator reasigna el endpoint tras un failover.

3. Verificá quién es el primary actual:

   ```bash
   kubectl get cluster pg-demo -o jsonpath='{.status.currentPrimary}{"\n"}'
   ```

4. Disparen un **failover** eliminando el Pod primary y observen la reconciliación automática — el operator promueve una replica y reconfigura el Service `-rw`:

   ```bash
   PRIMARY=$(kubectl get cluster pg-demo -o jsonpath='{.status.currentPrimary}')
   kubectl delete pod "$PRIMARY"
   # Observá el cambio de primary en vivo:
   kubectl get cluster pg-demo -o wide -w
   ```

   Tras unos segundos, `.status.currentPrimary` cambia a otra instancia y el Pod eliminado se recrea como replica. **Vos no ejecutaste ningún `promote` manual**: el control loop lo hizo.

5. Confirmá que la app puede seguir escribiendo apuntando siempre al mismo Service `-rw`:

   ```bash
   kubectl run pg-client --rm -it --image=ghcr.io/cloudnative-pg/postgresql:16.4 \
     --restart=Never -- \
     psql "host=pg-demo-rw dbname=appdb user=postgres" -c "SELECT pg_is_in_recovery();"
   ```

   Debe devolver `f` (false → estás conectado al primary), sin importar qué instancia sea físicamente el primary ahora.

**Preguntas de comprensión (bloque 4):**

- 4a. ¿Qué conocimiento operativo "día 2" está encapsulado en este operator que un `StatefulSet` puro **no** te daría out of the box? Nombrá al menos dos capacidades.
- 4b. Cuando eliminaste el Pod primary, ¿por qué la app pudo seguir conectándose sin cambiar su cadena de conexión? Explicá el papel del Service `pg-demo-rw` y del `.status`.
- 4c. `primaryUpdateStrategy: unsupervised` afecta cómo se hacen los rolling updates del primary. ¿Qué trade-off de disponibilidad vs. control estás aceptando frente a `supervised`?

---

## Ejercicio 5 — Desde adentro: scaffoldear un Operator propio con Operator SDK

Para cerrar el círculo, construimos un operator mínimo con **Operator SDK / Kubebuilder** y leemos el `Reconcile` generado. El objetivo no es escribir Go de producción, sino **ver el control loop, el RBAC, el status subresource y los finalizers** en el código que ejecutan todos los operators anteriores.

### Pasos

1. Inicializá un proyecto de operator (requiere Go ≥ 1.22 y `operator-sdk` instalado):

   ```bash
   mkdir platform-operator && cd platform-operator
   operator-sdk init --domain example.com --repo github.com/example/platform-operator
   ```

2. Creá una API (CRD + controller) para un recurso `Tenant`, que representará un artefacto de plataforma a automatizar:

   ```bash
   operator-sdk create api --group platform --version v1alpha1 --kind Tenant \
     --resource --controller
   ```

   Esto genera, entre otros: `api/v1alpha1/tenant_types.go` (el schema de la CRD) y `internal/controller/tenant_controller.go` (el reconciler).

3. Abrí `api/v1alpha1/tenant_types.go` y definí `Spec` (deseado) y `Status` (observado). Notá el marker `+kubebuilder:subresource:status`:

   ```go
   // TenantSpec define el estado deseado del Tenant.
   type TenantSpec struct {
       // DisplayName es el nombre visible del tenant.
       DisplayName string `json:"displayName"`
       // Quota es la cantidad de namespaces a provisionar.
       // +kubebuilder:validation:Minimum=1
       // +kubebuilder:validation:Maximum=10
       Quota int `json:"quota"`
   }

   // TenantStatus define el estado observado del Tenant.
   type TenantStatus struct {
       // Provisioned indica cuántos namespaces ya existen.
       Provisioned int `json:"provisioned,omitempty"`
       // Conditions sigue la convención estándar de Kubernetes.
       Conditions []metav1.Condition `json:"conditions,omitempty"`
   }

   // +kubebuilder:object:root=true
   // +kubebuilder:subresource:status
   type Tenant struct { /* ... generado ... */ }
   ```

4. Abrí `internal/controller/tenant_controller.go` y estudiá la firma del control loop y los **RBAC markers** que generan los `Role`/`ClusterRole` del operator:

   ```go
   // +kubebuilder:rbac:groups=platform.example.com,resources=tenants,verbs=get;list;watch;create;update;patch;delete
   // +kubebuilder:rbac:groups=platform.example.com,resources=tenants/status,verbs=get;update;patch
   // +kubebuilder:rbac:groups=platform.example.com,resources=tenants/finalizers,verbs=update
   // +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch;create;delete

   func (r *TenantReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
       log := ctrllog.FromContext(ctx)

       var tenant platformv1alpha1.Tenant
       if err := r.Get(ctx, req.NamespacedName, &tenant); err != nil {
           // NotFound => el objeto fue borrado; nada que reconciliar.
           return ctrl.Result{}, client.IgnoreNotFound(err)
       }

       // --- Finalizer: limpieza ordenada antes del borrado ---
       finalizer := "platform.example.com/cleanup"
       if tenant.DeletionTimestamp.IsZero() {
           if !controllerutil.ContainsFinalizer(&tenant, finalizer) {
               controllerutil.AddFinalizer(&tenant, finalizer)
               return ctrl.Result{}, r.Update(ctx, &tenant)
           }
       } else {
           // El objeto está en borrado: ejecutar limpieza y quitar el finalizer.
           if err := r.cleanupNamespaces(ctx, &tenant); err != nil {
               return ctrl.Result{}, err
           }
           controllerutil.RemoveFinalizer(&tenant, finalizer)
           return ctrl.Result{}, r.Update(ctx, &tenant)
       }

       // --- Reconciliación del estado deseado ---
       provisioned, err := r.ensureNamespaces(ctx, &tenant)
       if err != nil {
           return ctrl.Result{}, err // requeue automático con backoff exponencial
       }

       // Escribir el status observado en el subresource /status.
       tenant.Status.Provisioned = provisioned
       if err := r.Status().Update(ctx, &tenant); err != nil {
           return ctrl.Result{}, err
       }

       log.Info("reconciled", "tenant", tenant.Name, "provisioned", provisioned)
       return ctrl.Result{}, nil
   }
   ```

5. Generá los manifiestos (CRD + RBAC + deploy) a partir de los markers y instalalos en el cluster:

   ```bash
   make manifests    # regenera config/crd y config/rbac desde los markers
   make install      # aplica la CRD al cluster
   make run          # ejecuta el controller localmente contra tu kubeconfig
   ```

6. En otra terminal, aplicá un Custom Resource y observá el control loop actuar (verás logs `reconciled` y namespaces creados):

   ```yaml
   # tenant.yaml
   apiVersion: platform.example.com/v1alpha1
   kind: Tenant
   metadata:
     name: acme
     namespace: demo-operators
   spec:
     displayName: "ACME Corp"
     quota: 3
   ```

   ```bash
   kubectl apply -f tenant.yaml
   kubectl get tenant acme -o jsonpath='{.status.provisioned}{"\n"}'   # -> 3
   kubectl delete tenant acme    # dispara el finalizer y la limpieza ordenada
   ```

**Preguntas de comprensión (bloque 5):**

- 5a. Cuando `Reconcile` termina devolviendo `error`, ¿qué hace el framework (controller-runtime) automáticamente, y qué política aplica para no martillar la API?
- 5b. ¿Por qué el status se escribe con `r.Status().Update(...)` y no con `r.Update(...)`? Relacioná esto con el `+kubebuilder:subresource:status`.
- 5c. Sin el bloque de finalizer, ¿qué pasaría con los namespaces provisionados al borrar el `Tenant`? ¿Qué garantía te da un finalizer que un simple `ownerReference` no siempre da?
- 5d. Los markers `+kubebuilder:rbac:...` no son decorativos. ¿Qué objeto del cluster generan y por qué el principio de **least privilege** te obliga a listar `verbs` explícitos por recurso?

---

## Limpieza

```bash
kubectl delete -f tenant.yaml --ignore-not-found
kubectl delete -f pg-cluster.yaml --ignore-not-found
kubectl delete -f certificate.yaml -f issuer.yaml --ignore-not-found
kubectl delete -f subscription.yaml -f operatorgroup.yaml --ignore-not-found
operator-sdk olm uninstall
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
kubectl delete namespace demo-operators
```

> Si un namespace queda `Terminating` por un finalizer huérfano de un operator ya desinstalado, revisá `kubectl get ns demo-operators -o jsonpath='{.spec.finalizers}'` — nunca edites finalizers a ciegas en producción: primero confirmá que el controller dueño ya no existe.

---

## Fuentes oficiales

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Operator pattern (Kubernetes) — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Custom Resources & CRDs — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Operator Framework / Operator SDK — https://sdk.operatorframework.io/docs/
- Operator Lifecycle Manager (OLM) — https://olm.operatorframework.io/docs/
- Kubebuilder Book (control loop, markers, finalizers) — https://book.kubebuilder.io/
- cert-manager — https://cert-manager.io/docs/
- CloudNativePG — https://cloudnative-pg.io/documentation/

---

<details>
<summary><strong>Respuestas — verificá tu comprensión</strong></summary>

### Bloque 1 — Patrón Operator, CRDs y control loop

**1a.** Un Operator aporta: (1) **nuevos tipos de API** mediante CRDs (recursos que `kubectl` trata como nativos, con validación de schema y versionado); (2) un **control loop / reconciliation** que observa esos recursos y actúa continuamente para converger el estado real al deseado, incluyendo lógica operativa "día 2" (backups, failover, upgrades); (3) frecuentemente **status subresources, webhooks de validación/mutación y RBAC propio**. Un Deployment solo declara réplicas de un pod; no extiende la API ni encapsula lógica de dominio.

**1b.** El endpoint `/status` es un **subresource** independiente: las escrituras a `.spec` (usuario) y a `.status` (controller) no colisionan porque van por caminos distintos y cada uno actualiza solo su parte del objeto. Esto evita el problema clásico de **lost updates / conflictos de resourceVersion** en el que el controller, al escribir status, pisaría un cambio de spec hecho por el usuario (o viceversa). Además permite RBAC diferenciado: el usuario puede tener permiso sobre el objeto pero no sobre `/status`.

**1c.** No desaparecen. Las CRDs y los Custom Resources son **datos persistidos en etcd**, independientes del proceso del controller. Si matás el pod del controller, los objetos siguen existiendo pero **dejan de reconciliarse** (nadie converge el estado real hacia el deseado). Cuando el Deployment recrea el pod, el nuevo controller hace un *list+watch* inicial y reconcilia todo el estado existente. Borrar la **CRD**, en cambio, sí borra en cascada todos sus Custom Resources.

### Bloque 2 — cert-manager

**2a.** El **`Certificate`** declara la intención del usuario (el estado deseado: qué DNS names, qué Issuer, qué duración). El **`CertificateRequest`** y el **`Secret`** de tipo TLS son artefactos internos que el operator crea y gestiona; el usuario normalmente no los edita a mano.

**2b.** Reaparece por el **reconciliation loop**: el `.spec.secretName` del `Certificate` declara que ese Secret debe existir con ese contenido. Al borrarlo, el controller detecta la divergencia entre estado deseado (Secret presente y válido) y real (ausente) y lo vuelve a materializar. Es *self-healing* declarativo, el mismo mecanismo por el que un Deployment recrea pods borrados.

**2c.** El propio controller lo decide. cert-manager mantiene un **requeue programado** (schedule) para cada Certificate basado en `duration` y `renewBefore`: en lugar de polling ciego, encola un evento de reconciliación para el momento en que `notAfter - renewBefore` se alcanza. El patrón es **event-driven + scheduled requeue** de controller-runtime (`RequeueAfter`), no un cron externo.

### Bloque 3 — OLM

**3a.**
- **`CatalogSource`**: un índice/repositorio de operators disponibles (imágenes de catálogo) que OLM puede instalar.
- **`Subscription`**: la declaración del usuario de "quiero este operator, de este catálogo, siguiendo este channel, con esta política de aprobación". Es el driver de instalación y **upgrades**.
- **`InstallPlan`**: el plan concreto de recursos a crear (CSV, CRDs, RBAC) que resuelve una Subscription; puede requerir aprobación.
- **`ClusterServiceVersion (CSV)`**: el "paquete" de una versión del operator — metadatos, permisos requeridos, deployment del controller y CRDs owned. Es la unidad instalable y actualizable.
- **`OperatorGroup`**: define el **alcance de namespaces** que el operator vigilará (multitenancy/aislamiento).

**3b.** `Manual` **pausa** la instalación/upgrade hasta que un humano (o pipeline) apruebe el `InstallPlan`; `Automatic` aplica los upgrades del channel apenas aparecen. En producción, con un operator que gestiona bases de datos, un upgrade automático podría cambiar el comportamiento del reconciler o hasta la versión del engine sin ventana de mantenimiento: `Manual` te da un **gate de control de cambios** para revisar el CSV nuevo, planificar y aprobar en una ventana controlada.

**3c.** `targetNamespaces` restringe **qué namespaces observa y gestiona** el operator (su *watch scope*). OLM genera el RBAC del controller acorde a ese scope: si es un solo namespace, crea `Role`/`RoleBinding` namespaced en lugar de `ClusterRole` con alcance global. Así el operator recibe **least privilege** — solo puede actuar donde el OperatorGroup lo autoriza, no en todo el cluster.

### Bloque 4 — CloudNativePG

**4a.** Ejemplos de conocimiento día 2 encapsulado: **failover/switchover automático con promoción de replica**, **gestión de la topología de streaming replication**, **reconfiguración de los Services de routing (`-rw`/`-ro`) tras un cambio de primary**, **rolling updates ordenados del cluster**, y típicamente **backups/PITR e integración de credenciales**. Un `StatefulSet` te da identidad estable y orden de arranque, pero no sabe qué es un primary de Postgres, no promueve replicas ni redirige tráfico de escritura.

**4b.** La app se conecta al Service **`pg-demo-rw`**, que es un endpoint estable cuyo selector/endpoint el operator **reasigna** para que siempre apunte al Pod que es primary en ese momento. Tras el failover, el operator actualiza `.status.currentPrimary` y reconfigura el routing del Service `-rw` hacia la nueva instancia promovida. La cadena de conexión de la app nunca cambia porque apunta a la abstracción (Service), no al Pod físico.

**4c.** Con `unsupervised`, el operator ejecuta los updates del primary **automáticamente**, haciendo switchover cuando toca actualizar la instancia primaria — mayor automatización, pero cedés control sobre el momento exacto de la interrupción del primary. Con `supervised`, el update del primary **espera intervención/aprobación** (un switchover manual), dándote control del timing a costa de menos automatización. El trade-off es **disponibilidad automática y menos toil** vs. **control humano sobre la ventana de disrupción del rol primary**.

### Bloque 5 — Operator propio (Operator SDK)

**5a.** controller-runtime **re-encola (requeue) el objeto automáticamente** cuando `Reconcile` devuelve un error, aplicando **backoff exponencial** con rate limiting. Así reintenta la reconciliación sin saturar el API server; también podés devolver `ctrl.Result{RequeueAfter: d}` sin error para reintentos programados. La idempotencia del `Reconcile` es lo que hace seguro este reintento.

**5b.** Porque `+kubebuilder:subresource:status` habilita el endpoint `/status` separado: `r.Status().Update()` escribe **solo** el subresource `.status`, mientras que `r.Update()` escribiría el objeto principal (spec + metadata). Usar el endpoint correcto evita pisar cambios del usuario en `.spec` y respeta el RBAC diferenciado (`tenants/status`). Además, escribir status por el path del objeto principal a menudo es directamente ignorado cuando el subresource está activado.

**5c.** Sin finalizer, al borrar el `Tenant` el objeto desaparece de inmediato de etcd y el `Reconcile` ya no puede ejecutar limpieza — los namespaces provisionados quedarían **huérfanos** (a menos que dependan de un `ownerReference` con garbage collection). El finalizer **pospone el borrado real** (setea `deletionTimestamp` pero mantiene el objeto) hasta que el controller completa su limpieza y quita el finalizer. La garantía extra frente a `ownerReference`: podés ejecutar **lógica de cleanup arbitraria y ordenada** (drenar conexiones, borrar recursos externos al cluster, revocar credenciales), cosa que el garbage collector por ownerReference no hace — este solo borra objetos hijos dentro de Kubernetes.

**5d.** Generan los objetos **RBAC del operator**: `Role`/`ClusterRole` (+ sus bindings a la ServiceAccount del controller). Least privilege obliga a enumerar `verbs` explícitos por recurso porque el operator corre con una identidad (ServiceAccount) que solo debería poder hacer exactamente lo necesario: si el controller solo crea y borra namespaces, no debe tener `update` sobre secrets de todo el cluster. Verbos y recursos acotados reducen el radio de impacto si el controller es comprometido o tiene un bug.

</details>