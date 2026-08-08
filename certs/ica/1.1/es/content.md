# Tema 1.1 — Instalación de Istio con `istioctl` o Helm

> **Dominio:** Installation, Upgrade & Configuration · **Peso:** 5
> **Fuente del currículo:** https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

---

## 1. Motivación y problema arquitectónico de producción

Un service mesh no es una aplicación más que se despliega con un `kubectl apply -f`. Istio inyecta un **data plane** (proxies Envoy como sidecars, o `ztunnel` en modo ambient) que intercepta *todo* el tráfico L4/L7 de los workloads, y un **control plane** (`istiod`) que actúa como fuente de verdad para descubrimiento de servicios (xDS), emisión de certificados (Citadel/CA integrado) e inyección de configuración. Instalarlo mal tiene un radio de impacto igual al de toda la malla: un `istiod` mal dimensionado degrada la propagación de config a *todos* los proxies; una CRD faltante rompe la admisión; una versión desalineada entre control y data plane provoca *silent drops* difíciles de diagnosticar.

El problema arquitectónico central que resuelve el método de instalación es **cómo gestionar el ciclo de vida de un componente de infraestructura crítico y con estado de configuración distribuido**, garantizando:

- **Idempotencia y reproducibilidad**: la misma definición debe producir la misma malla, versionada en Git.
- **Upgrades sin downtime**: el control plane debe poder actualizarse mediante *canary* (revisiones paralelas) en vez de *in-place* destructivo, porque una regresión en `istiod` afecta a producción entera.
- **Skew controlado**: Istio soporta una diferencia de **n-1 minor versions** entre data plane y control plane; el instalador debe hacer cumplir esa disciplina.
- **Prune seguro**: al reconfigurar, los recursos huérfanos (un egress gateway que se deshabilitó, por ejemplo) deben eliminarse, no quedar zombies consumiendo IPs y reglas.

Las tres herramientas históricas —`istioctl`, Helm y el *in-cluster operator*— resuelven esto con filosofías distintas. La elección no es cosmética: define tu estrategia de GitOps, tu superficie de auditoría y tu procedimiento de rollback.

---

## 2. Comparativa técnica de métodos de instalación

| Dimensión | `istioctl install` | Helm charts | In-cluster Operator |
|---|---|---|---|
| **API de configuración** | `IstioOperator` (renderizado *client-side*) | `values.yaml` por chart | `IstioOperator` CR (reconciliación *server-side*) |
| **Modelo de ejecución** | Imperativo con validación previa | Declarativo, nativo de Helm | Controlador que observa el CR |
| **Prune de recursos huérfanos** | ✅ Automático (labels de ownership) | ⚠️ Solo con `helm upgrade` sobre el mismo release | ✅ El controlador reconcilia |
| **Validación pre-install** | ✅ `verify-install`, `analyze`, `x precheck` | ❌ Ninguna nativa | ⚠️ Solo tras aplicar el CR |
| **Canary upgrades (revisiones)** | ✅ *First-class* (`--revision`) | ✅ Un release por revisión | ✅ Un CR por revisión |
| **GitOps (Argo/Flux)** | Vía `manifest generate` (cuidado con prune) | ✅ Nativo, es lo natural | ⚠️ Requiere el operator corriendo |
| **Rollback** | Manual / reinstalar revisión previa | ✅ `helm rollback` | Editar/borrar el CR |
| **Curva de aprendizaje** | Baja | Media | Media |
| **Estado del proyecto** | ✅ **Recomendado** | ✅ **Recomendado** (GitOps) | ❌ **Deprecado** (Istio 1.23) y en proceso de remoción |

**Regla operativa:** para clusters gestionados manualmente o con onboarding rápido, `istioctl` es lo más directo y trae validación integrada. Para pipelines GitOps declarativos (Argo CD, Flux), Helm es el ciudadano de primera clase. **El in-cluster operator quedó deprecado**: no lo elijas para instalaciones nuevas; si lo tenés, migrá a `istioctl`/Helm.

### 2.1 Perfiles (profiles) — trade-off de superficie desplegada

Un *profile* es una plantilla de `IstioOperator` con componentes preseleccionados. Aplica tanto a `istioctl` como a Helm (indirectamente).

| Profile | `istiod` | Ingress GW | Egress GW | Telemetría | Uso recomendado |
|---|:---:|:---:|:---:|---|---|
| `default` | ✅ | ✅ | ❌ | Sampling bajo | **Producción** |
| `demo` | ✅ | ✅ | ✅ | Tracing 100% | Aprendizaje / labs (no producción) |
| `minimal` | ✅ | ❌ | ❌ | Mínima | Base para armado custom |
| `empty` | ❌ | ❌ | ❌ | — | Punto de partida totalmente manual |
| `preview` | ✅ | ✅ | ❌ | — | Features experimentales |
| `remote` | (externo) | — | — | — | Multi-cluster primary-remote |
| `ambient` | ✅ + `ztunnel` + `cni` | ✅ | — | — | Malla en modo ambient (sin sidecars) |

> ⚠️ El profile `demo` habilita el egress gateway y tracing al 100 %: nunca lo uses en producción. Su sampling y su superficie de red no están dimensionados para carga real.

---

## 3. Instalación con `istioctl`

### 3.1 Obtención del binario (pinneando versión y arquitectura)

```console
$ curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.23.0 TARGET_ARCH=x86_64 sh -
Downloading istio-1.23.0 from https://github.com/istio/istio/releases/download/1.23.0/istio-1.23.0-linux-amd64.tar.gz ...
Istio 1.23.0 Download Complete!

$ export PATH="$PWD/istio-1.23.0/bin:$PATH"
$ istioctl version --remote=false
client version: 1.23.0
```

### 3.2 Pre-check: validar el cluster ANTES de tocar nada

```console
$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

Este comando verifica versión de Kubernetes, permisos RBAC, CRDs conflictivas de instalaciones previas y webhooks. Es gratis y evita el 80 % de las instalaciones fallidas.

### 3.3 Inspección de profiles

```console
$ istioctl profile list
Istio configuration profiles:
    ambient
    default
    demo
    empty
    minimal
    openshift
    preview
    remote
    stable

$ istioctl profile diff default demo | head -20
The difference between profiles: default and demo is:
 spec:
   components:
     egressGateways:
-    - enabled: false
+    - enabled: true
       name: istio-egressgateway
...
```

### 3.4 Instalación rápida por perfil (no apto para producción tal cual)

```console
$ istioctl install --set profile=demo -y
        |\
        | \
        |  \
        |   \
      /||    \
     / ||     \
    /  ||      \
   /   ||       \
  /    ||        \
 /     ||         \
/______||__________\
____________________
  \__       _____/
     \_____/

✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Egress gateways installed 🛫
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster-wide operations.
```

### 3.5 Manifiesto `IstioOperator` completo, apto para producción

Este es el artefacto que versionás en Git. Define recursos, HPA, revisión para canary, logging y observabilidad.

```yaml
# istio-control-plane.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-control-plane
  namespace: istio-system
spec:
  profile: default
  # Revisión: habilita upgrades canary. El namespace se etiqueta con istio.io/rev=1-23-0
  revision: 1-23-0
  hub: docker.io/istio
  tag: 1.23.0
  meshConfig:
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    enableTracing: true
    defaultConfig:
      # El pod no acepta tráfico hasta que el sidecar esté listo (evita 503 en el arranque)
      holdApplicationUntilProxyStarts: true
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"        # DNS proxying para resolución de ServiceEntry
    extensionProviders:
      - name: otel-tracing
        opentelemetry:
          service: opentelemetry-collector.observability.svc.cluster.local
          port: 4317
  components:
    pilot:
      k8s:
        resources:
          requests:
            cpu: 500m
            memory: 2048Mi
          limits:
            memory: 4096Mi
        hpaSpec:
          minReplicas: 2                       # Nunca 1 réplica de istiod en producción
          maxReplicas: 5
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 80
        env:
          - name: PILOT_ENABLE_STATUS
            value: "true"                      # Reporta estado de config en los recursos Istio
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: LoadBalancer
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: http2
                port: 80
                targetPort: 8080
              - name: https
                port: 443
                targetPort: 8443
          hpaSpec:
            minReplicas: 2
            maxReplicas: 5
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "2"
              memory: 1024Mi
    egressGateways:
      - name: istio-egressgateway
        enabled: false                         # Habilitar solo si hay política de salida controlada
  values:
    global:
      proxy:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: "2"
            memory: 1024Mi
        logLevel: warning
      logging:
        level: "default:info"
    pilot:
      autoscaleEnabled: true
```

Aplicación y validación contra el mismo archivo:

```console
$ istioctl install -f istio-control-plane.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
```

### 3.6 `manifest generate` para GitOps (y el gotcha del prune)

`istioctl` puede renderizar el YAML plano para que lo aplique Argo CD/Flux:

```console
$ istioctl manifest generate -f istio-control-plane.yaml > rendered/istio.yaml
$ wc -l rendered/istio.yaml
   4127 rendered/istio.yaml
```

> ⚠️ **Gotcha crítico de producción:** `istioctl install` hace *prune* automático de recursos que ya no están en la spec (usa labels de ownership `operator.istio.io/*`). En cambio, `kubectl apply -f rendered/istio.yaml` **NO borra** lo que sacaste de la spec. Si deshabilitás el egress gateway y solo hacés `kubectl apply`, el Deployment del egress queda huérfano. En GitOps, delegá el prune al motor (Argo CD *prune=true*, Flux `prune: true`) o usá el chart de Helm, que gestiona el ciclo por release.

---

## 4. Instalación con Helm

El método declarativo nativo. Istio publica charts independientes que deben instalarse **en orden estricto**, porque `istiod` depende de las CRDs que instala `base`.

### 4.1 Repositorio y charts disponibles

```console
$ helm repo add istio https://istio-release.storage.googleapis.com/charts
"istio" has been added to your repositories

$ helm repo update
$ helm search repo istio
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
istio/base              1.23.0          1.23.0          Helm chart for deploying Istio cluster resources...
istio/cni               1.23.0          1.23.0          Helm chart for Istio CNI components
istio/gateway           1.23.0          1.23.0          Helm chart for deploying Istio gateways
istio/istiod            1.23.0          1.23.0          Helm chart for Istio control plane
istio/ztunnel           1.23.0          1.23.0          Helm chart for Istio ztunnel (ambient)
```

| Chart | Qué instala | Namespace típico | ¿Obligatorio? |
|---|---|---|---|
| `istio/base` | CRDs, ClusterRoles, validating webhook | `istio-system` | ✅ Siempre primero |
| `istio/istiod` | Control plane (Pilot, CA, injector) | `istio-system` | ✅ |
| `istio/gateway` | Deployment de un gateway (ingress/egress) | `istio-ingress` | Según necesidad |
| `istio/cni` | Node agent CNI (sustituye `istio-init`) | `istio-system` | Recomendado / obligatorio en ambient |
| `istio/ztunnel` | Proxy per-node L4 (modo ambient) | `istio-system` | Solo ambient |

### 4.2 Orden de instalación

```console
$ kubectl create namespace istio-system
namespace/istio-system created

# 1) Base: CRDs + recursos cluster-wide. defaultRevision registra el webhook por defecto.
$ helm install istio-base istio/base -n istio-system --set defaultRevision=default
NAME: istio-base
STATUS: deployed
REVISION: 1

$ helm ls -n istio-system
NAME        NAMESPACE     REVISION  STATUS    CHART        APP VERSION
istio-base  istio-system  1         deployed  base-1.23.0  1.23.0

# 2) Control plane. --wait bloquea hasta que istiod esté Ready.
$ helm install istiod istio/istiod -n istio-system -f values-istiod.yaml --wait
NAME: istiod
STATUS: deployed
REVISION: 1

# 3) Ingress gateway en su propio namespace (aislamiento y RBAC más limpios)
$ kubectl create namespace istio-ingress
$ kubectl label namespace istio-ingress istio-injection=enabled
$ helm install istio-ingress istio/gateway -n istio-ingress --wait
NAME: istio-ingress
STATUS: deployed
```

### 4.3 `values-istiod.yaml` completo (equivalente productivo al `IstioOperator`)

```yaml
# values-istiod.yaml
revision: ""                    # Vacío = revisión "default". Para canary: "1-23-0"
global:
  hub: docker.io/istio
  tag: 1.23.0
  proxy:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: "2"
        memory: 1024Mi
    logLevel: warning
  logging:
    level: "default:info"
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
  enableTracing: true
  defaultConfig:
    holdApplicationUntilProxyStarts: true
pilot:
  autoscaleEnabled: true
  autoscaleMin: 2
  autoscaleMax: 5
  cpu:
    targetAverageUtilization: 80
  resources:
    requests:
      cpu: 500m
      memory: 2048Mi
    limits:
      memory: 4096Mi
  env:
    PILOT_ENABLE_STATUS: "true"
```

### 4.4 Verificar y renderizar para auditoría

```console
$ helm status istiod -n istio-system
$ kubectl get deployments -n istio-system -o wide
NAME     READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES
istiod   2/2     2            2           90s   discovery    docker.io/istio/pilot:1.23.0

# Renderizar sin instalar (para diff en PRs / GitOps)
$ helm template istiod istio/istiod -n istio-system -f values-istiod.yaml > rendered/istiod.yaml
```

---

## 5. Revisiones y canary upgrades (concepto transversal, evaluado en el examen)

El upgrade *in-place* del control plane es riesgoso: si `istiod` nuevo tiene un bug, ya afecta a toda la malla. El patrón correcto es **instalar una revisión paralela** y migrar workloads namespace por namespace.

**Con `istioctl`:**

```console
# Instalar revisión nueva junto a la vieja
$ istioctl install --set revision=1-23-0 -y

$ kubectl get pods -n istio-system
NAME                           READY   STATUS    RESTARTS   AGE
istiod-1-22-0-6b9f...          1/1     Running   0          30d   # revisión anterior
istiod-1-23-0-7c4a...          1/1     Running   0          2m    # revisión nueva

# Migrar un namespace a la revisión nueva y reiniciar sus pods
$ kubectl label namespace default istio.io/rev=1-23-0 istio-injection- --overwrite
$ kubectl rollout restart deployment -n default

# Verificar que el data plane sincroniza con la nueva revisión
$ istioctl proxy-status | grep 1-23-0

# Cuando todos los namespaces migraron, desinstalar la revisión vieja
$ istioctl uninstall --revision=1-22-0 -y
```

**Con Helm:** un release por revisión (`helm install istiod-1-23-0 istio/istiod -n istio-system --set revision=1-23-0 --wait`), luego el mismo relabel + `rollout restart`, y finalmente `helm uninstall` de la revisión vieja.

> **Etiquetas de injection — no confundir:**
> - `istio-injection=enabled` → usa la revisión **default** (sin revisiones nombradas).
> - `istio.io/rev=<revisión>` → ancla el namespace a una revisión específica.
> Los dos labels son mutuamente excluyentes; tener ambos rompe la inyección.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Verificación post-instalación

```console
$ istioctl verify-install -f istio-control-plane.yaml
1 Istio control planes detected, checking --revision "1-23-0" only
✔ ClusterRole: istiod-clusterrole-istio-system.istio-system checked successfully
✔ ClusterRoleBinding: istiod-clusterrole-binding-istio-system.istio-system checked successfully
✔ ServiceAccount: istiod.istio-system checked successfully
✔ Deployment: istiod.istio-system checked successfully
...
Checked 15 custom resource definitions
Checked 3 Istio Deployments
✔ Istio is installed and verified successfully

$ istioctl version
client version: 1.23.0
control plane version: 1.23.0
data plane version: 1.23.0 (12 proxies)

$ kubectl get pods -n istio-system
NAME                                   READY   STATUS    RESTARTS   AGE
istio-ingressgateway-6d79b7d5b6-fghij  1/1     Running   0          3m
istiod-1-23-0-7c4a9d8f5b-klmno         1/1     Running   0          3m30s

$ kubectl get crd -A | grep 'istio.io' | wc -l
15

# Análisis de configuración: detecta problemas antes de que fallen en runtime
$ istioctl analyze -A
✔ No validation issues found when analyzing all namespaces.
```

### 6.2 Estado del data plane (la fuente de verdad del diagnóstico)

```console
$ istioctl proxy-status
NAME                                CLUSTER      CDS      LDS      EDS      RDS      ECDS     ISTIOD                          VERSION
istio-ingressgateway-...istio-ingress Kubernetes SYNCED   SYNCED   SYNCED   SYNCED   IGNORED  istiod-1-23-0-7c4a...            1.23.0
productpage-v1-...default            Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   IGNORED  istiod-1-23-0-7c4a...            1.23.0
```

Interpretación de la columna de sync:

| Valor | Significado | Acción |
|---|---|---|
| `SYNCED` | El proxy tiene la última config que envió `istiod` | OK |
| `STALE` | `istiod` envió pero el proxy no confirmó (ACK pendiente) | Revisar red/CPU del proxy |
| `NOT SENT` | `istiod` aún no envió (no hay config aplicable) | Normal si no hay recursos |
| Distinta `VERSION` | Skew entre data y control plane | Reiniciar workloads / completar migración |

### 6.3 Matriz de fallas comunes

| Síntoma | Causa raíz | Diagnóstico | Remedio |
|---|---|---|---|
| Sidecar no se inyecta | Falta label en el namespace, o `istio.io/rev` no coincide con la revisión de `istiod` | `kubectl get ns -L istio-injection -L istio.io/rev` | Etiquetar el namespace con la revisión correcta y `rollout restart` |
| `istiod` en `CrashLoopBackOff` | Recursos insuficientes o CRDs de `base` faltantes/antiguas | `kubectl logs -n istio-system deploy/istiod`; `kubectl get crd \| grep istio` | Instalar/actualizar el chart `base`; subir requests/limits |
| Ingress gateway `<pending>` sin IP externa | No hay proveedor de LoadBalancer (bare-metal) | `kubectl get svc -n istio-ingress` | Instalar MetalLB, o cambiar `service.type` a `NodePort` |
| 503 al arrancar los pods | La app recibe tráfico antes de que el sidecar esté listo | Logs del sidecar; timing del pod | `holdApplicationUntilProxyStarts: true` |
| Config no llega a los proxies | Webhook de validación/inyección roto | `kubectl get mutatingwebhookconfiguration`; `istioctl analyze` | Reinstalar `base` con `defaultRevision`; revisar `failurePolicy` |
| `verify-install` reporta recursos faltantes | `kubectl apply` de manifest sin prune, o instalación parcial | `istioctl verify-install -f <spec>` | Reinstalar con `istioctl install` (hace prune) |

Comandos de profundización:

```console
# Config efectiva de un sidecar (clusters, listeners, routes, endpoints)
$ istioctl proxy-config all productpage-v1-xxxx.default

# Logs del control plane filtrando por push de config
$ kubectl logs -n istio-system deploy/istiod | grep -i "push"

# Comprobar que el MutatingWebhook apunta a la revisión correcta
$ kubectl get mutatingwebhookconfiguration -l istio.io/rev=1-23-0
NAME                              WEBHOOKS   AGE
istio-sidecar-injector-1-23-0     4          5m
```

---

## 7. Referencias

- Istio — Install with `istioctl`: https://istio.io/latest/docs/setup/install/istioctl/
- Istio — Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Istio — Installation Configuration Profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Istio — `IstioOperator` API reference: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Istio — Canary upgrades / revisions: https://istio.io/latest/docs/setup/upgrade/canary/
- Istio — `istioctl` CLI reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Istio — Diagnostic tools (`analyze`, `proxy-status`): https://istio.io/latest/docs/ops/diagnostic-tools/
- Istio — Deprecation of the in-cluster operator: https://istio.io/latest/blog/2024/in-cluster-operator-deprecation-announcement/
- CNCF — Istio Certified Associate (ICA) Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf