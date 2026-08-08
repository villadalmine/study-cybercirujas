# Tema 1.2 — Installing Istio in Sidecar or Ambient Mode

> **Certificación:** Istio Certified Associate (ICA) · **Dominio:** Installation & Configuration · **Peso:** 5
> **Perfil:** Platform Architect / SRE — instalación, upgrade y diagnóstico de un service mesh en producción.

---

## 1. Motivación y problema arquitectónico de producción

Un service mesh existe para sacar del código de la aplicación tres responsabilidades transversales que, gestionadas por servicio, no escalan: **mTLS mutuo** (identidad criptográfica de cada workload), **control de tráfico L7** (routing, retries, timeouts, circuit breaking) y **observabilidad uniforme** (golden signals sin instrumentar cada lenguaje). Istio implementa esto interponiendo un data plane de proxies Envoy y programándolos desde un control plane (`istiod`) que traduce configuración declarativa de Kubernetes a xDS.

El problema arquitectónico real que enfrenta el operador **no es "cómo instalo Istio"**, sino **"qué costo de recursos y qué superficie de riesgo estoy dispuesto a pagar por cada workload del cluster"**. Ese trade-off es exactamente lo que separa los dos data planes que este tema exige dominar:

- **Sidecar mode** (el modelo clásico desde 2017): cada Pod recibe un contenedor Envoy inyectado. Da L7 completo por workload, pero paga un Envoy por Pod (CPU/memoria constantes aun en reposo), obliga a reiniciar el Pod para inyectar o actualizar el proxy, y rompe con Pods que no toleran un sidecar (Jobs que nunca terminan porque el sidecar sigue vivo, `initContainers` que necesitan red antes de que Envoy arranque, etc.).
- **Ambient mode** (GA en Istio 1.24, noviembre 2024): elimina el sidecar. Divide el data plane en dos capas independientes — un **ztunnel** por nodo (DaemonSet) que da identidad y mTLS L4 a *todos* los Pods del nodo sin tocarlos, y **waypoint proxies** opcionales (Envoy desplegados por namespace o por service account) que añaden L7 **solo donde se lo necesita**. El costo pasa de "N Pods → N Envoys" a "M nodos → M ztunnels + K waypoints".

La decisión de instalación (`profile`, método, revisiones) es la que fija esta arquitectura para toda la vida operativa del cluster. Instalar mal —el perfil `demo` en producción, el operator in-cluster hoy deprecado, o sin `istio-cni` donde hace falta— genera deuda que solo se paga con un re-install disruptivo.

### El modelo de capas L4/L7 de ambient

```
                         ┌─────────────────────────────────────────┐
                         │            istiod (control plane)         │
                         │   xDS · CA (SPIFFE/mTLS) · config API     │
                         └──────────────┬────────────────────────────┘
                                        │ xDS (mTLS)
        ┌───────────────────────────────┼───────────────────────────────┐
        │ Nodo A                         │            Nodo B              │
        │  ┌──────────┐  ┌──────────┐    │   ┌──────────┐  ┌──────────┐   │
        │  │  Pod app │  │  Pod app │    │   │  Pod app │  │  Pod app │   │
        │  └────┬─────┘  └────┬─────┘    │   └────┬─────┘  └────┬─────┘   │
        │       │ redirección (istio-cni)│        │              │        │
        │  ┌────▼──────────────▼─────┐   │   ┌────▼──────────────▼────┐   │
        │  │ ztunnel (L4/mTLS/HBONE) │   │   │ ztunnel (L4/mTLS/HBONE)│   │
        │  └──────────┬──────────────┘   │   └───────────┬────────────┘   │
        └─────────────┼──────────────────┴───────────────┼────────────────┘
                      │      HBONE (HTTP CONNECT sobre mTLS, tcp/15008)     │
                      └──────────────► waypoint proxy (Envoy, L7) ◄─────────┘
                                       (por-namespace / por-SA, opcional)
```

- **ztunnel** transporta tráfico entre Pods dentro de un túnel **HBONE** (*HTTP-Based Overlay Network Environment*): un `HTTP CONNECT` sobre mTLS en el puerto **tcp/15008**. Da identidad SPIFFE, cifrado y política L4 (`AuthorizationPolicy` a nivel de puerto/identidad) sin parsear L7.
- **waypoint** es un Envoy común desplegado como `Deployment` vía Gateway API. Solo el tráfico que necesita políticas L7 (routing por header, `VirtualService`, `AuthorizationPolicy` sobre paths/métodos) se enruta a través de él. Se instala con `istioctl waypoint`.

---

## 2. Comparativas técnicas con tablas de trade-offs

### 2.1 Sidecar vs Ambient

| Dimensión | Sidecar | Ambient |
|---|---|---|
| Unidad de despliegue del proxy | 1 Envoy por Pod | 1 ztunnel por **nodo** + waypoints opcionales por ns/SA |
| Costo en reposo | CPU/mem por cada Pod, exista o no tráfico | Fijo por nodo; L7 solo si se despliega waypoint |
| Onboarding de un workload | Requiere **reinyección + restart** del Pod | Etiqueta de namespace; **sin restart** |
| Capa L4 (mTLS, identidad) | Envoy sidecar | ztunnel |
| Capa L7 (VirtualService, retries, RBAC por path) | Siempre disponible (el sidecar es L7) | Solo si hay **waypoint** en la ruta |
| Upgrade del data plane | Rolling restart de todos los Pods | Rolling del DaemonSet ztunnel; los Pods no reinician |
| Compatibilidad con Jobs / initContainers que usan red | Problemática (sidecar sobrevive al Job) | Nativa (no hay sidecar) |
| `istio-cni` | Recomendado (evita el init-container privilegiado `istio-init`) | **Obligatorio** |
| Madurez | Estable desde 2017 | **GA desde 1.24** |
| Blast radius de un fallo del proxy | 1 Pod | Un fallo de ztunnel afecta a todo el nodo |
| Modelo mental de recursos | O(Pods) | O(Nodos) + O(waypoints) |

**Regla operativa:** ambient minimiza el costo agregado y desacopla el ciclo de vida del proxy del Pod, a cambio de un blast radius por-nodo y de que L7 sea *opt-in*. Sidecar sigue siendo la opción cuando cada workload necesita L7 y se quiere aislamiento por-Pod.

### 2.2 Métodos de instalación

| Método | Caso de uso | Ventaja | Límite |
|---|---|---|---|
| `istioctl install` | Default recomendado, día a día | Validación pre-instalación, `IstioOperator` API, upgrades canary | Imperativo si no se versiona el YAML |
| **Helm** (`base` + `istiod` + `cni` + `ztunnel` + `gateway`) | Producción / GitOps / Argo CD / Flux | Declarativo, un chart por componente, rollbacks de Helm | Más piezas que orquestar y ordenar |
| Istio **Operator** in-cluster (`operator init`) | *(legado)* | Reconciliación continua | **Deprecado en 1.23, removido** — no usar |
| VM / bare-metal onboarding | Workloads fuera de k8s | Extiende el mesh a VMs | Fuera del alcance de este tema |

> `IstioOperator` como **API/CRD de configuración** sigue vigente y es lo que consume `istioctl install -f`. Lo deprecado es el **controlador in-cluster** que reconciliaba ese CR automáticamente.

### 2.3 Perfiles de configuración

| Perfil | `istiod` | Ingress GW | Egress GW | CNI | ztunnel | Uso |
|---|:---:|:---:|:---:|:---:|:---:|---|
| `default` | ✔ | ✔ | �’ | — | — | **Producción sidecar** |
| `demo` | ✔ | ✔ | ✔ | — | — | Demos; **verbose, nunca en prod** |
| `minimal` | ✔ | — | — | — | — | Control plane a medida |
| `empty` | — | — | — | — | — | Base para componer todo a mano |
| `preview` | ✔ | ✔ | — | — | — | Features experimentales |
| `ambient` | ✔ | ✔ | — | ✔ | ✔ | **Producción ambient** |
| `remote` | — | — | — | — | — | Data plane de cluster remoto (multi-cluster) |

Ver el diff exacto de cualquier perfil antes de aplicarlo:

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

$ istioctl profile diff default demo | head -n 20
The difference between profiles:
 spec:
   components:
     egressGateways:
-    - enabled: false
+    - enabled: true
       name: istio-egressgateway
   meshConfig:
     accessLogFile: ""
+    accessLogFile: /dev/stdout
     enablePrometheusMerge: true
```

---

## 3. Manifiestos e infraestructura completos

### 3.1 Pre-requisitos y precheck

```console
$ istioctl version --remote=false
client version: 1.24.2

$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

`x precheck` valida versión de Kubernetes (Istio 1.24 soporta k8s 1.28–1.31), permisos RBAC del instalador, webhooks de admisión en conflicto y CRDs de Gateway API. **Nunca instalar sin que pase.**

### 3.2 IstioOperator — instalación sidecar de producción

`istio-sidecar.yaml` — reproducible, versionable, apto para `istioctl install -f`:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane-prod
  namespace: istio-system
spec:
  profile: default
  # Revisión: habilita upgrades canary (istio.io/rev=1-24-2)
  revision: 1-24-2
  meshConfig:
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true   # la app no arranca hasta que Envoy está listo
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"        # DNS proxying en el sidecar
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY                      # deny-by-default a servicios externos
  components:
    pilot:
      k8s:
        resources:
          requests: { cpu: "500m", memory: "2048Mi" }
        hpaSpec:
          minReplicas: 2
          maxReplicas: 5
        env:
          - name: PILOT_ENABLE_STATUS
            value: "true"
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: LoadBalancer
          resources:
            requests: { cpu: "500m", memory: "256Mi" }
          hpaSpec:
            minReplicas: 2
            maxReplicas: 5
  values:
    # istio-cni: elimina el init-container privilegiado istio-init
    cni:
      enabled: true
    global:
      proxy:
        resources:
          requests: { cpu: "100m", memory: "128Mi" }
          limits: { cpu: "2000m", memory: "1024Mi" }
      logging:
        level: "default:info"
```

Aplicación:

```console
$ istioctl install -f istio-sidecar.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ CNI installed 🪢
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster-wide operations.
```

### 3.3 Inyección de sidecar (revision-aware)

Con revisiones, **no** se usa la etiqueta legacy `istio-injection=enabled`; se ancla al revision label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio.io/rev: 1-24-2      # inyecta el sidecar de esta revisión concreta
```

```console
$ kubectl label namespace payments istio.io/rev=1-24-2
namespace/payments labeled

$ kubectl -n payments rollout restart deployment    # reinyección requiere restart
$ kubectl -n payments get pod
NAME                        READY   STATUS    RESTARTS   AGE
checkout-7d9f8c6b5-2xk4p    2/2     Running   0          25s   # 2/2 = app + istio-proxy
```

Inyección manual (para pipelines que no confían en el webhook):

```console
$ istioctl kube-inject -f deployment.yaml | kubectl apply -f -
```

### 3.4 Instalación ambient completa

```console
$ istioctl install --set profile=ambient --set revision=1-24-2 -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ CNI installed 🪢
✔ Ztunnel installed 🔒
✔ Installation complete

$ kubectl -n istio-system get pods
NAME                                    READY   STATUS    RESTARTS   AGE
istio-cni-node-7bqkz                    1/1     Running   0          40s   # DaemonSet
istio-cni-node-fj2ld                    1/1     Running   0          40s
istiod-1-24-2-6c9d8f7b4d-p7m2n          1/1     Running   0          55s
ztunnel-9xq4v                           1/1     Running   0          38s   # DaemonSet
ztunnel-kd7mp                           1/1     Running   0          38s
```

Onboarding de un namespace a la malla L4 — **sin reiniciar Pods**:

```console
$ kubectl label namespace payments istio.io/dataplane-mode=ambient
namespace/payments labeled

$ kubectl -n payments get pod
NAME                        READY   STATUS    RESTARTS   AGE
checkout-7d9f8c6b5-2xk4p    1/1     Running   0          6m    # sigue 1/1: no hay sidecar
```

Añadir L7 con un **waypoint** por namespace (usa Gateway API):

```console
$ istioctl waypoint apply --namespace payments --enroll-namespace -y
✔ waypoint payments-east applied
namespace/payments labeled with "istio.io/use-waypoint=payments-east"

$ istioctl waypoint list --namespace payments
NAME            REVISION    PROGRAMMED
payments-east   1-24-2      True
```

El waypoint como recurso Gateway API declarativo (`waypoint.yaml`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: payments-east
  namespace: payments
  labels:
    istio.io/waypoint-for: service   # 'service' | 'workload' | 'all'
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

### 3.5 Instalación por Helm (producción / GitOps)

El orden importa: `base` (CRDs) → `istiod` → `cni` → `ztunnel` → gateways.

```console
$ helm repo add istio https://istio-release.storage.googleapis.com/charts
$ helm repo update

$ kubectl create namespace istio-system

# 1) CRDs y cluster roles
$ helm install istio-base istio/base -n istio-system \
    --set defaultRevision=1-24-2 --wait

# 2) Control plane (perfil ambient)
$ helm install istiod istio/istiod -n istio-system \
    --set profile=ambient --set revision=1-24-2 --wait

# 3) CNI (obligatorio en ambient)
$ helm install istio-cni istio/cni -n istio-system \
    --set profile=ambient --wait

# 4) ztunnel (data plane L4)
$ helm install ztunnel istio/ztunnel -n istio-system --wait

$ helm ls -n istio-system
NAME        NAMESPACE     REVISION  STATUS    CHART           APP VERSION
istio-base  istio-system  1         deployed  base-1.24.2     1.24.2
istio-cni   istio-system  1         deployed  cni-1.24.2      1.24.2
istiod      istio-system  1         deployed  istiod-1.24.2   1.24.2
ztunnel     istio-system  1         deployed  ztunnel-1.24.2  1.24.2
```

---

## 4. Verificación y diagnóstico de fallas

### 4.1 Verificación post-instalación

```console
$ istioctl verify-install -f istio-sidecar.yaml
✔ ClusterRole: istiod-clusterrole-istio-system.rbac.authorization.k8s.io checked successfully
✔ Deployment: istiod.apps/istio-system checked successfully
✔ Service: istiod.core/istio-system checked successfully
Checked 15 custom resource definitions
Checked 3 Istio Deployments
✔ Istio is installed and verified successfully

$ istioctl analyze -A
✔ No validation issues found when analyzing all namespaces.
```

### 4.2 Estado del data plane (sincronización xDS)

```console
$ istioctl proxy-status
NAME                          CLUSTER   CDS      LDS      EDS      RDS      ECDS     ISTIOD              VERSION
checkout-7d9f8c6b5-2xk4p...   Kubern... SYNCED   SYNCED   SYNCED   SYNCED   IGNORED  istiod-1-24-2-...   1.24.2
ztunnel-9xq4v.istio-system    Kubern... SYNCED   SYNCED   SYNCED   NOT SENT SYNCED   istiod-1-24-2-...   1.24.2
```

`SYNCED` = el proxy recibió y aceptó la última config. `STALE` = enviada pero no reconocida (Envoy sobrecargado o istiod con problemas). `NOT SENT` = no aplica ese recurso (normal en ztunnel para RDS).

### 4.3 Confirmar mTLS y la ruta HBONE

```console
$ istioctl x ztunnel-config workloads --namespace payments
NAMESPACE  POD NAME                   ADDRESS      NODE     WAYPOINT       PROTOCOL
payments   checkout-7d9f8c6b5-2xk4p   10.244.1.12  node-a   payments-east  HBONE
payments   cart-6b4c9d8f7-lm3qx       10.244.2.31  node-b   payments-east  HBONE

# PROTOCOL=HBONE confirma que el tráfico va cifrado por ztunnel.
# PROTOCOL=TCP indicaría que el Pod NO está capturado en la malla.
```

### 4.4 Matriz de diagnóstico de fallas frecuentes

| Síntoma | Causa raíz probable | Verificación | Remedio |
|---|---|---|---|
| Pod `1/2` en sidecar mode | Envoy no arranca / falta config | `kubectl logs <pod> -c istio-proxy` | Revisar `holdApplicationUntilProxyStarts`, recursos del proxy |
| Sin sidecar tras etiquetar ns | Namespace con label pero **Pod no reiniciado** | `istioctl analyze -n <ns>` | `kubectl rollout restart` |
| `PROTOCOL=TCP` en ambient | `istio-cni` no capturó el Pod | `kubectl -n istio-system logs ds/istio-cni-node` | Verificar CNI instalado y el Pod recreado tras el label |
| xDS `STALE`/`NOT SENT` persistente | istiod saturado o webhook roto | `istioctl proxy-status`; logs de istiod | Escalar istiod (HPA), revisar `MutatingWebhookConfiguration` |
| Reglas L7 ignoradas en ambient | No hay **waypoint** en la ruta | `istioctl waypoint list -n <ns>` | `istioctl waypoint apply --enroll-namespace` |
| `precheck` falla por Gateway API | CRDs de Gateway API ausentes | `kubectl get crd gateways.gateway.networking.k8s.io` | Instalar CRDs de Gateway API antes de ambient |
| Upgrade dejó Pods en revisión vieja | No se reinició tras cambiar `istio.io/rev` | `istioctl proxy-status` (columna VERSION) | Re-etiquetar y `rollout restart` |

### 4.5 Upgrade canary por revisiones (patrón de producción)

```console
# Instalar la nueva revisión junto a la vieja (control planes coexisten)
$ istioctl install --set revision=1-25-0 -y

$ kubectl get pods -n istio-system -l app=istiod
NAME                             READY   STATUS    AGE
istiod-1-24-2-6c9d8f7b4d-p7m2n   1/1     Running   3h
istiod-1-25-0-7f8c9d6b5e-k2nqr   1/1     Running   40s

# Migrar un namespace y reiniciar para tomar la nueva revisión
$ kubectl label ns payments istio.io/rev=1-25-0 --overwrite
$ kubectl rollout restart deployment -n payments
$ istioctl proxy-status | grep payments      # verificar VERSION 1.25.0 antes de seguir

# Cuando todos los ns migraron y validaron, desinstalar la revisión vieja
$ istioctl uninstall --revision 1-24-2 -y
```

Este patrón mantiene **dos control planes en paralelo**, permite rollback instantáneo (re-etiquetar al revision anterior) y evita el upgrade in-place que reinicia todo el mesh a la vez.

---

## 5. Referencias

- Istio — Installation Guides (overview): https://istio.io/latest/docs/setup/install/
- Install with istioctl: https://istio.io/latest/docs/setup/install/istioctl/
- Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Installation Configuration Profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Ambient mode — Getting Started: https://istio.io/latest/docs/ambient/getting-started/
- Ambient architecture (ztunnel & waypoint): https://istio.io/latest/docs/ambient/architecture/
- Deploy waypoint proxies: https://istio.io/latest/docs/ambient/usage/waypoint/
- Sidecar injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Install Istio CNI: https://istio.io/latest/docs/setup/additional-setup/cni/
- Canary upgrades (revisions): https://istio.io/latest/docs/setup/upgrade/canary/
- IstioOperator API reference: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- `istioctl` CLI reference: https://istio.io/latest/docs/reference/commands/istioctl/
- HBONE / ztunnel design: https://istio.io/latest/docs/ambient/architecture/traffic-redirection/
- CNCF ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf