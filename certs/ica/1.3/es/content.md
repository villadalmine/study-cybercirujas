# Tema 1.3 — Customizing your Istio Installation

**Certificación:** Istio Certified Associate (ICA) · Dominio *Istio Installation, Upgrade and Configuration* · Peso relativo del subtema: 5

---

## 1. Motivación: por qué el install "por defecto" no llega a producción

Istio se instala en dos planos con requisitos operativos opuestos:

- **Control plane (`istiod`):** un proceso stateful-en-memoria que hace de *xDS server*. Computa la configuración de cada proxy a partir de todos los `Service`, `Endpoint`, `VirtualService`, `DestinationRule`, `Gateway`, `PeerAuthentication`, etc. del cluster y la **empuja (push) a cada sidecar**. Su consumo de memoria y CPU crece con `O(servicios × proxies)`, no con el tráfico.
- **Data plane (los sidecars Envoy / `istio-proxy`):** un contenedor inyectado en cada Pod. Cada uno añade latencia p99, consumo de CPU y memoria, y — crítico — **arranca de forma asíncrona respecto de la app**, lo que produce fallos de conectividad en el arranque si no se ordena.

Los *profiles* de fábrica ignoran esto. El profile `demo` — el que casi todo el mundo instala primero — trae **trace sampling al 100 %**, access logs a `stdout` siempre encendidos, egress gateway, y una sola réplica de `istiod`. Eso es didáctico y suicida en producción: un `istiod` sin HA es un SPOF que, al caer, congela toda propagación de configuración del mesh; el sampling al 100 % satura el backend de tracing; y sin `holdApplicationUntilProxyStarts` cada rollout genera 5xx durante la ventana en que la app ya escucha pero el sidecar todavía no tiene rutas.

El problema arquitectónico de "customizar" es entonces **decidir en qué capa vive cada parámetro** y **hacerlo reproducible**. Istio ofrece cuatro capas de configuración con semánticas distintas:

| Capa | Qué configura | Momento | Alcance |
|---|---|---|---|
| `IstioOperator` API / Helm values | Topología del control plane, gateways, recursos K8s, imágenes, feature gates | Install / upgrade | Cluster |
| `MeshConfig` | Comportamiento global del mesh (access logs, mTLS auto, outbound policy, providers de telemetría, `discoverySelectors`) | Runtime (recarga en caliente) | Mesh entero |
| `ProxyConfig` (`defaultConfig` o CR) | Defaults del proxy (concurrency, drain, hold, env) | Runtime / inyección | Mesh o namespace |
| Annotations del Pod + `Sidecar` CR | Overrides por workload (recursos del proxy, captura de tráfico, scoping de egress) | Inyección | Pod / namespace |

La regla operativa: **lo que cambia la topología va en el install (IstioOperator/Helm); lo que cambia el comportamiento va en MeshConfig/ProxyConfig/CRs**, porque estos últimos se recargan sin reinstalar y no requieren `rollout restart` masivo.

> ⚠️ **Nota de versión imprescindible.** El *controlador in-cluster* del operador (`istioctl operator init`, que reconciliaba un CR `IstioOperator` aplicado al cluster) fue **deprecado en Istio 1.23 y eliminado en 1.24**. Lo que sigue vigente es la **API `IstioOperator`** como *fichero de entrada* para `istioctl install` / `istioctl manifest`. No confundir: hoy no se aplica un `IstioOperator` con `kubectl apply` esperando que un controlador lo reconcilie; se pasa con `istioctl install -f`. Todo este material usa la API en ese modo.

---

## 2. Comparativas técnicas

### 2.1 Métodos de instalación / customización

| Método | Cómo se customiza | Pros | Contras | Cuándo usarlo |
|---|---|---|---|---|
| **`istioctl install -f`** | `IstioOperator` YAML | Validación previa (`precheck`, `verify-install`), *prune* de recursos huérfanos en upgrade, diffs de profile | Requiere el binario `istioctl` en el pipeline; imperativo | Default para la mayoría de clusters |
| **`istioctl manifest generate` + GitOps** | `IstioOperator` YAML → manifiestos planos | Declarativo puro, auditable en Git, aplica con Argo/Flux | **No hace prune**: recursos eliminados de un upgrade quedan huérfanos si no se gestiona; hay que replicar `verify-install` aparte | Clusters gobernados por GitOps estricto |
| **Helm (`base` + `istiod` + `gateway`)** | `values.yaml` | Se integra con el tooling Helm existente, releases atómicas, rollback nativo | Config repartida entre charts; `meshConfig` va en values del chart `istiod`; más piezas que orquestar | Organizaciones 100 % Helm |
| **Operador in-cluster** | CR `IstioOperator` reconciliado | (histórico) | **Eliminado en 1.24** | No usar |

### 2.2 Installation profiles (`istioctl profile list`)

| Profile | Componentes | Uso |
|---|---|---|
| `default` | `istiod` + ingress gateway | Base recomendada para producción |
| `demo` | `istiod` + ingress + egress, tracing 100 %, logs on | **Solo laboratorio** |
| `minimal` | Solo `istiod` | Control plane; gateways por separado |
| `empty` | Nada | Punto de partida para builds a medida |
| `preview` | `default` + features experimentales | Validar features next-release |
| `remote` | Config para `istiod` externo | Multicluster (remote plane) |
| `ambient` | `istiod` + ztunnel + CNI (sin sidecars) | Ambient mesh (GA desde 1.24) |

Los profiles son **capas base**: cualquier campo puede sobreescribirse con `-f` o `--set`. La composición es *deep-merge* con precedencia `--set` > `-f` > `profile`.

### 2.3 Estrategia de upgrade

| | In-place | Canary (revisions) |
|---|---|---|
| Mecánica | Se reemplaza `istiod` y los proxies se reinician sobre la misma versión | Se instala un `istiod` con nuevo `revision`; namespaces migran uno a uno |
| Riesgo | Alto: un solo *blast radius*, rollback = otro upgrade | Bajo: convive N y N+1, rollback = re-etiquetar namespace |
| Downtime del data plane | `rollout restart` global | Gradual, por namespace |
| Recomendación | Solo dev/labs | **Estándar de producción** |

---

## 3. Manifiestos completos

### 3.1 `IstioOperator` de producción (control plane HA + ingress gateway)

```yaml
# prod-istiooperator.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-prod
  namespace: istio-system
spec:
  profile: default
  # Revision: habilita upgrades canary. El nombre de la Deployment de istiod
  # pasará a ser "istiod-1-24-0" (afecta scaleTargetRef del HPA, ver abajo).
  revision: 1-24-0
  hub: docker.io/istio
  tag: 1.24.0

  # ---------- Comportamiento global del mesh (recarga en caliente) ----------
  meshConfig:
    # Access logs a stdout con formato JSON: barato de scrapear, caro si es 100%.
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    # REGISTRY_ONLY: bloquea todo egress que no tenga ServiceEntry. Fail-closed.
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
    enableAutoMtls: true
    # discoverySelectors: istiod SOLO observa namespaces con esta label.
    # Reduce drásticamente memoria/CPU del control plane en clusters grandes.
    discoverySelectors:
      - matchLabels:
          istio-discovery: enabled
    # Providers de telemetría, referenciados luego desde la Telemetry API.
    extensionProviders:
      - name: otel-tracing
        opentelemetry:
          service: opentelemetry-collector.observability.svc.cluster.local
          port: 4317
      - name: otel-access-log
        envoyOtelAls:
          service: opentelemetry-collector.observability.svc.cluster.local
          port: 4317
    # Defaults heredados por TODOS los proxies inyectados.
    defaultConfig:
      # Ordena el arranque: la app no recibe tráfico hasta que Envoy está listo.
      holdApplicationUntilProxyStarts: true
      # Tiempo de drain al terminar: evita cortar conexiones en un rollout.
      terminationDrainDuration: 30s
      # 0 = usar todos los cores disponibles; fijar en entornos con CPU limits.
      concurrency: 2
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"

  # ---------- Componentes y su footprint en Kubernetes ----------
  components:
    pilot:
      k8s:
        replicaCount: 2
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            memory: 4Gi
        hpaSpec:
          minReplicas: 2
          maxReplicas: 5
          # OJO: el name DEBE coincidir con la Deployment revisionada.
          scaleTargetRef:
            apiVersion: apps/v1
            kind: Deployment
            name: istiod-1-24-0
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 70
        podDisruptionBudget:
          minAvailable: 1
        priorityClassName: system-cluster-critical
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchLabels:
                      app: istiod
                  topologyKey: kubernetes.io/hostname
        env:
          # Feature gates de Pilot: aquí, p.ej., limitar el push de config.
          - name: PILOT_ENABLE_STATUS
            value: "true"
          - name: PILOT_PUSH_THROTTLE
            value: "100"

    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          replicaCount: 2
          resources:
            requests:
              cpu: 200m
              memory: 128Mi
            limits:
              memory: 256Mi
          hpaSpec:
            minReplicas: 2
            maxReplicas: 5
            scaleTargetRef:
              apiVersion: apps/v1
              kind: Deployment
              name: istio-ingressgateway
            metrics:
              - type: Resource
                resource:
                  name: cpu
                  target:
                    type: Utilization
                    averageUtilization: 80
          podDisruptionBudget:
            minAvailable: 1
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
          serviceAnnotations:
            service.beta.kubernetes.io/aws-load-balancer-type: nlb
            service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
          # overlays: parches arbitrarios para lo que la API no expone.
          overlays:
            - kind: Deployment
              name: istio-ingressgateway
              patches:
                - path: spec.template.spec.topologySpreadConstraints
                  value:
                    - maxSkew: 1
                      topologyKey: topology.kubernetes.io/zone
                      whenUnsatisfiable: DoNotSchedule
                      labelSelector:
                        matchLabels:
                          app: istio-ingressgateway

    egressGateways:
      - name: istio-egressgateway
        enabled: false

  # ---------- Helm passthrough: lo que no vive en components/meshConfig ----------
  values:
    global:
      proxy:
        # Recursos del sidecar por defecto en TODO el mesh (el "sidecar tax").
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
```

### 3.2 Instalación equivalente con Helm

```yaml
# istiod-values.yaml  (chart istio/istiod)
revision: "1-24-0"
pilot:
  autoscaleEnabled: true
  autoscaleMin: 2
  autoscaleMax: 5
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      memory: 4Gi
  podAnnotations: {}
  env:
    PILOT_PUSH_THROTTLE: "100"
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  enableAutoMtls: true
  discoverySelectors:
    - matchLabels:
        istio-discovery: enabled
  defaultConfig:
    holdApplicationUntilProxyStarts: true
    terminationDrainDuration: 30s
global:
  proxy:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: "2"
        memory: 1024Mi
```

### 3.3 Scoping de egress por namespace — `Sidecar` CR (control de escala)

Sin esto, `istiod` empuja **la config de todo el mesh a cada proxy**. En un cluster con miles de servicios, cada Envoy carga listeners/clusters que nunca usará → memoria y tiempo de convergencia se disparan. El `Sidecar` recorta lo que cada proxy ve:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: default
  namespace: payments
spec:
  egress:
    - hosts:
        - "./*"                      # servicios del propio namespace
        - "istio-system/*"           # control plane
        - "observability/*"          # colector de telemetría
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
```

### 3.4 Overrides por workload (annotations en el Pod template)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
spec:
  template:
    metadata:
      annotations:
        # Recursos del sidecar solo para este workload de alto tráfico
        sidecar.istio.io/proxyCPU: "500m"
        sidecar.istio.io/proxyMemory: "256Mi"
        sidecar.istio.io/proxyCPULimit: "2"
        sidecar.istio.io/proxyMemoryLimit: "512Mi"
        # No capturar tráfico a un puerto de métricas legacy
        traffic.sidecar.istio.io/excludeOutboundPorts: "9000"
        # ProxyConfig inline (override de defaultConfig del mesh)
        proxy.istio.io/config: |
          holdApplicationUntilProxyStarts: true
          concurrency: 4
      labels:
        app: checkout
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Pre-vuelo y descubrimiento de profiles

```console
$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/

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
 meshConfig:
   accessLogFile: ""
-  enableTracing: false
+  accessLogFile: /dev/stdout
+  enableTracing: true
 components:
   egressGateways:
-  - enabled: false
+  - enabled: true
     name: istio-egressgateway
```

### 4.2 Instalación y verificación del manifiesto contra el cluster

```console
$ istioctl install -f prod-istiooperator.yaml
This will install the Istio 1.24.0 profile "default" with revision "1-24-0"
into the cluster. Proceed? (y/N) y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster-wide operations.

$ istioctl verify-install -f prod-istiooperator.yaml
1 Istio control planes detected, checking --revision "1-24-0" only
✔ ClusterRole: istiod-clusterrole-1-24-0-istio-system.istio-system checked successfully
✔ ServiceAccount: istiod-1-24-0.istio-system checked successfully
✔ Deployment: istiod-1-24-0.istio-system checked successfully
✔ Deployment: istio-ingressgateway.istio-system checked successfully
Checked 15 custom resource definitions
Checked 3 Istio Deployments
✔ Istio is installed and verified successfully
```

### 4.3 Flujo GitOps (generar manifiesto plano)

```console
$ istioctl manifest generate -f prod-istiooperator.yaml > rendered/istio.yaml
$ istioctl manifest generate -f prod-istiooperator.yaml \
    | kubectl diff -f - || true
# Se commitea rendered/istio.yaml; Argo/Flux hace el apply.
# ⚠️ manifest generate NO hace prune: en upgrades, borrar recursos obsoletos
#    requiere `istioctl install` o gestión explícita de prune en la herramienta GitOps.
```

### 4.4 Instalación con Helm

```console
$ helm repo add istio https://istio-release.storage.googleapis.com/charts
$ helm repo update
$ kubectl create namespace istio-system
$ helm install istio-base istio/base -n istio-system --set defaultRevision=1-24-0 --wait
$ helm install istiod istio/istiod -n istio-system \
    -f istiod-values.yaml --wait
NAME: istiod
STATUS: deployed
REVISION: 1
$ kubectl create namespace istio-ingress
$ helm install istio-ingress istio/gateway -n istio-ingress --wait
```

### 4.5 Verificar que el `MeshConfig` efectivo es el esperado

```console
$ kubectl get configmap istio-1-24-0 -n istio-system -o jsonpath='{.data.mesh}' \
    | grep -E 'outboundTrafficPolicy|holdApplication|accessLogFile' -A1
accessLogFile: /dev/stdout
outboundTrafficPolicy:
  mode: REGISTRY_ONLY
defaultConfig:
  holdApplicationUntilProxyStarts: true

# Confirmar el ProxyConfig realmente embebido en el bootstrap de un proxy:
$ istioctl proxy-config bootstrap deploy/checkout.payments -o json \
    | jq '.bootstrap.node.metadata.PROXY_CONFIG.holdApplicationUntilProxyStarts'
true
```

### 4.6 Upgrade canary por revisions

```console
# 1) Instalar el nuevo control plane junto al viejo (no toca a 1-24-0)
$ istioctl install -f prod-istiooperator-1-26-0.yaml --set revision=1-26-0

$ kubectl get pods -n istio-system -l app=istiod
NAME                          READY   STATUS    RESTARTS   AGE
istiod-1-24-0-7c9f...         1/1     Running   0          21d
istiod-1-26-0-5b8d...         1/1     Running   0          2m

# 2) Migrar UN namespace a la nueva revision y reiniciar sus workloads
$ kubectl label namespace payments istio.io/rev=1-26-0 istio-injection- --overwrite
$ kubectl rollout restart deployment -n payments

# 3) Verificar que los proxies apuntan a la nueva revision
$ istioctl proxy-status | grep payments
NAME                          CLUSTER   ...   VERSION   ISTIOD
checkout-abc.payments         Kubernetes ...  1.26.0    istiod-1-26-0-5b8d...

# 4) Repuntar el tag "default" cuando todo esté migrado; rollback = re-etiquetar
$ istioctl tag set default --revision 1-26-0 --overwrite
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 Análisis estático de configuración

```console
$ istioctl analyze -n payments
Warning [IST0102] (Namespace payments) The namespace is not enabled for Istio
  injection. Run 'kubectl label namespace payments istio-injection=enabled' to
  enable it, or 'kubectl label namespace payments istio-injection=disabled' to
  explicitly mark it as not needing injection.

Error [IST0118] (Service payments/checkout) Port name  (port: 8080) doesn't
  follow the naming convention of Istio port.
```

### 5.2 La inyección de sidecar no ocurre — árbol de diagnóstico

Síntoma: los Pods arrancan con `1/1` en vez de `2/2`.

```console
# a) ¿Qué label de inyección tiene el namespace?
$ kubectl get ns payments --show-labels
NAME       STATUS   AGE   LABELS
payments   Active   30d   istio.io/rev=1-26-0
#   -> Si tiene istio.io/rev Y istio-injection=enabled a la vez, GANA el default
#      injection y IGNORA la revision. Deben ser mutuamente excluyentes.

# b) ¿El webhook está registrado y apunta a la revision correcta?
$ kubectl get mutatingwebhookconfigurations | grep istio
istio-sidecar-injector-1-26-0    2    5m
istio-revision-tag-default       2    5m

# c) ¿El namespaceSelector del webhook coincide con las labels del namespace?
$ kubectl get mutatingwebhookconfiguration istio-sidecar-injector-1-26-0 \
    -o jsonpath='{.webhooks[0].namespaceSelector}'
{"matchLabels":{"istio.io/rev":"1-26-0"}}

# d) Forzar re-inyección tras corregir
$ kubectl rollout restart deployment -n payments
```

Causas frecuentes: (1) namespace sin label o con label de otra revision; (2) el Pod trae `sidecar.istio.io/inject: "false"`; (3) el webhook `failurePolicy: Ignore` estaba activo y `istiod` no respondió durante el admission.

### 5.3 `istiod` con OOMKilled — presión de configuración

```console
$ kubectl top pod -n istio-system -l app=istiod
NAME                   CPU(cores)   MEMORY(bytes)
istiod-1-26-0-5b8d...  1850m        3980Mi        # cerca del limit de 4Gi

$ kubectl logs -n istio-system deploy/istiod-1-26-0 | grep -i "push"
info  ads  Push debounce ... 4200 clients, full push
```

Diagnóstico: `4200 clients` recibiendo *full push*. Remediar con **`discoverySelectors`** (recortar namespaces observados) y **`Sidecar` CRs** (recortar egress por namespace), no subiendo memoria indefinidamente. Ambos reducen el tamaño del snapshot xDS por proxy.

### 5.4 Mismatch de revisión tras un upgrade a medias

```console
$ istioctl proxy-status
NAME                   ...  VERSION   ISTIOD                  SDS     CDS
gateway-x.istio-...    ...  1.24.0    istiod-1-24-0-7c9f...   SYNCED  SYNCED
checkout-abc.payments  ...  1.26.0    istiod-1-26-0-5b8d...   SYNCED  STALE
```

`STALE`/`NOT SENT` indica que el proxy no convergió con su `istiod`. Con revisiones mezcladas es esperado durante la migración; si persiste, `istioctl proxy-config all <pod>` y comparar contra el estado deseado, y validar conectividad proxy→`istiod` (puerto 15012, mTLS del control plane).

### 5.5 Confirmar que un cambio de MeshConfig se propagó

`MeshConfig` se recarga en caliente, pero **algunos campos (los que afectan al bootstrap del sidecar, p.ej. `holdApplicationUntilProxyStarts`, `concurrency`) requieren reinyección** (`rollout restart`), mientras que otros (outbound policy, access logs) se aplican vía xDS sin reinicio. Verificación:

```console
$ istioctl proxy-config bootstrap deploy/checkout.payments -o json \
    | jq '.bootstrap.node.metadata.PROXY_CONFIG.concurrency'
2     # si sigue mostrando el valor viejo, falta rollout restart
```

---

## 6. Referencias

- ICA Curriculum (CNCF): <https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf>
- Install with istioctl: <https://istio.io/latest/docs/setup/install/istioctl/>
- Customizing the configuration: <https://istio.io/latest/docs/setup/additional-setup/customize-installation/>
- Configuration profiles: <https://istio.io/latest/docs/setup/additional-setup/config-profiles/>
- Install with Helm: <https://istio.io/latest/docs/setup/install/helm/>
- `IstioOperator` API reference: <https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/>
- `MeshConfig` / `ProxyConfig` reference: <https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/>
- Sidecar injection: <https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/>
- Canary upgrades (revisions & tags): <https://istio.io/latest/docs/setup/upgrade/canary/>
- `Sidecar` CR reference: <https://istio.io/latest/docs/reference/config/networking/sidecar/>
- `ProxyConfig` CR reference: <https://istio.io/latest/docs/reference/config/networking/proxy-config/>
- Deployment & operational best practices (incl. `discoverySelectors`): <https://istio.io/latest/docs/ops/best-practices/deployment/>
- In-cluster operator deprecation: <https://istio.io/latest/blog/2024/in-cluster-operator-deprecation-announcement/>
- `istioctl` command reference: <https://istio.io/latest/docs/reference/commands/istioctl/>