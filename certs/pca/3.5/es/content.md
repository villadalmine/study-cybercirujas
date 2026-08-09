# 3.5 Service Discovery

> **Domain:** Prometheus Fundamentals — Configuration and Scraping
> **Exam weight:** 3
> **Level:** Advanced (SRE / Platform Architect)

---

## 1. El problema de producción: monitoreo basado en pull sobre infraestructura efímera

Prometheus es un sistema **pull**. El servidor inicia cada scrape abriendo una conexión HTTP hacia el endpoint `/metrics` de un target. Esta decisión de diseño — deliberada y central en el modelo operativo de Prometheus — crea un requisito estricto que no tiene equivalente en los sistemas push: **Prometheus debe conocer la dirección de cada target antes de poder recolectar una sola muestra.**

Sobre una flota de servidores mascota con hostnames fijos esto es trivial. Los escribís en la configuración una vez y te olvidás. Pero los entornos donde Prometheus se despliega realmente — clusters de Kubernetes, grupos de auto-escalado en la nube, jobs de Nomad, service meshes de Consul — comparten una propiedad que rompe completamente esa suposición:

- **Los targets son efímeros.** La IP de un Pod se asigna en el momento del scheduling, vive lo que dura el Pod, y se recicla segundos después de su muerte. Un rollout de un `Deployment` reemplaza cada IP. Un evento de scale-up de un HPA crea diez targets nuevos con diez direcciones nuevas en menos de un minuto.
- **La cardinalidad de los *targets* es dinámica.** El conjunto de cosas a scrapear es una función del estado del cluster, no de un archivo de configuración. No podés enumerarlo por adelantado porque no existía por adelantado.
- **Identidad ≠ dirección.** La dirección (`10.244.3.17:8080`) es un detalle de implementación que cambia constantemente. La *identidad* que le importa al SRE (`job="checkout"`, `namespace="payments"`, `pod="checkout-7d9f…"`) debe sobrevivir al churn. La continuidad de las series temporales depende de labels estables, no de IPs estables.

Un bloque `static_configs` no puede expresar nada de esto. Si hardcodeás IPs de Pods, cada rollout rompe silenciosamente el monitoreo: la mitad de tus targets pasan a `down`, tus alertas `up == 0` se disparan (correctamente, y luego incorrectamente), y los reemplazos reales son invisibles porque nada le avisó a Prometheus que existen.

**Service Discovery (SD)** es el subsistema que resuelve esto. Consulta continuamente una fuente de verdad autoritativa sobre la infraestructura (la API de Kubernetes, el catálogo de Consul, una llamada `DescribeInstances` de EC2, un archivo en disco) y produce una lista de targets viva y auto-actualizada — cada uno decorado con metadata rica. **Relabeling** es el mecanismo compañero que transforma esa metadata cruda en la configuración final de scrape: qué targets conservar, qué dirección golpear, qué path y esquema usar, y qué labels de identidad llevará cada serie.

La idea arquitectónica a internalizar: en Prometheus, **la configuración de scrape se computa, no se declara.** SD provee la materia prima; relabeling es el programa que la convierte en targets. Dominá relabeling y dominás service discovery — cada mecanismo de SD desemboca en el mismo pipeline de relabeling.

### El ciclo de vida discovery → relabel → scrape

```
┌──────────────────┐   discovered      ┌──────────────────┐   final       ┌───────────┐
│  SD mechanism    │   targets +       │  relabel_configs │   target set  │  Scrape   │
│ (k8s, consul,    │──  __meta_* ─────▶│  (keep/drop/     │────────────▶ │  manager  │
│  file, dns, ec2) │   labels          │   replace/…)     │   __address__ │           │
└──────────────────┘                   └──────────────────┘   + labels    └───────────┘
        ▲                                                                        │
        │ periodic refresh                                                       │ GET /metrics
        │ (watch / poll)                                                         ▼
   source of truth                                                       ┌──────────────────┐
   (API server, catalog…)                                               │ metric_relabel_   │
                                                                          │ configs (per      │
                                                                          │ sample, post-scrape)│
                                                                          └──────────────────┘
```

Dos etapas de relabeling, a menudo confundidas, en extremos opuestos del pipeline:

| Etapa | Se ejecuta | Opera sobre | Propósito |
|---|---|---|---|
| `relabel_configs` | **Antes** del scrape, sobre el conjunto de labels `__meta_*` del target | Labels del target | Seleccionar targets (`keep`/`drop`), establecer `__address__`/`__scheme__`/`__metrics_path__`, adjuntar labels de identidad |
| `metric_relabel_configs` | **Después** del scrape, sobre cada muestra ingerida | Labels de la serie | Descartar series ruidosas, reescribir labels, controlar la cardinalidad |

Este documento trata de la primera etapa. `metric_relabel_configs` se cubre bajo exposición/cardinalidad.

---

## 2. Mecanismos de Service Discovery: comparación técnica

Prometheus incluye ~20 integraciones de SD nativas. Todas alimentan el mismo pipeline de relabeling; difieren en la *fuente de verdad*, el *modelo de refresh* (watch vs. poll), y los labels `__meta_*` que exponen.

| Mecanismo | Config key | Modelo de refresh | Fuente de verdad | Uso típico | Superficie de auth |
|---|---|---|---|---|---|
| **Static** | `static_configs` | Ninguno (solo reload de config) | El archivo de configuración mismo | Self-scrape de Prometheus, exporters fijos, node exporter sobre bare metal | ninguna |
| **File** | `file_sd_configs` | Poll (inotify + fallback de `refresh_interval`, default 5m) | Archivos JSON/YAML en disco | Capa de pegamento para cualquier cosa scriptable; CMDBs; controllers custom | permisos de archivo |
| **Kubernetes** | `kubernetes_sd_configs` | **Watch** (streaming, casi en tiempo real) | API server de Kubernetes | El caso dominante: Pods, Services, Endpoints, Nodes, Ingresses | ServiceAccount / kubeconfig |
| **Consul** | `consul_sd_configs` | Watch (blocking queries) | Catálogo de Consul | Service-mesh y flotas de VMs registradas en Consul | ACL token |
| **DNS** | `dns_sd_configs` | Poll (`refresh_interval`, default 30s) | Registros DNS `A`/`AAAA`/`SRV` | Headless Services, registros de servicios legacy que exponen DNS | ninguna |
| **EC2 / Azure / GCE** | `ec2_sd_configs`, … | Poll (default 60s) | API del proveedor de nube | Flotas de VMs / ASGs fuera de Kubernetes | credenciales IAM / SP |
| **HTTP** | `http_sd_configs` | Poll (`refresh_interval`, default 60s) | Cualquier endpoint HTTP que devuelva JSON de targets | Integración genérica con APIs de infra custom | bearer/basic/mTLS |

### Watch vs. poll — el trade-off de latencia que importa en producción

La diferencia operativa más importante es **qué tan rápido un target nuevo se vuelve scrapeable**:

| Propiedad | Basado en watch (Kubernetes, Consul) | Basado en poll (File*, DNS, EC2, HTTP) |
|---|---|---|
| Latencia de target nuevo | De sub-segundo a unos pocos segundos | Hasta un `refresh_interval` |
| Carga sobre la fuente de verdad | Un stream/conexión de larga vida | Una request por intervalo × cada Prometheus |
| Comportamiento ante caída de la fuente | Sirve el último estado conocido; reconecta | Sirve el último estado conocido; reintenta en el próximo tick |
| Riesgo de thundering herd | Bajo (streaming) | Real — muchos Prometheis haciendo poll a la misma API |
| Perilla de tuning | ninguna necesaria | `refresh_interval` (latencia vs. carga) |

\* File SD es basado en poll en el papel pero usa inotify, así que en un filesystem local reacciona a las escrituras de archivos casi inmediatamente; `refresh_interval` es la red de seguridad para filesystems donde inotify no es confiable (NFS).

**Regla general:** preferí SD basado en watch siempre que la fuente de verdad lo soporte. Reservá el SD basado en poll para fuentes que solo exponen una API request/response, y tratá `refresh_interval` como un dial de carga-vs-frescura, no como un default que ignorar.

---

## 3. Manifests completos, de producción

### 3.1 RBAC de Kubernetes para SD de Prometheus

El SD de Kubernetes requiere que el ServiceAccount de Prometheus tenga **acceso de lectura a los objetos que descubre**. Esta es la causa más común de "no targets" en una instalación fresca — el SD descubre silenciosamente nada porque la API devuelve `403`. Otorgá exactamente los verbos que usa el SD (`get`, `list`, `watch`), no más.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/metrics      # required to proxy /metrics through the kubelet
      - nodes/proxy
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources:
      - endpointslices    # for role: endpointslice
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses         # for role: ingress
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring
```

### 3.2 `prometheus.yml` — la configuración de scrape canónica para Kubernetes

Esta es la configuración de referencia de la que deriva cada Prometheus de producción. Leé el `relabel_configs` línea por línea — *son* la lógica de service discovery.

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1
    replica: "0"

scrape_configs:

  # ── Job 1: Prometheus scraping itself (static — the base case) ──────────────
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # ── Job 2: Kubernetes API servers (endpoints of the default/kubernetes svc) ─
  - job_name: kubernetes-apiservers
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      # Keep ONLY the endpoints of the apiserver Service (default/kubernetes:https)
      - source_labels:
          - __meta_kubernetes_namespace
          - __meta_kubernetes_service_name
          - __meta_kubernetes_endpoint_port_name
        action: keep
        regex: default;kubernetes;https

  # ── Job 3: Kubelets — cAdvisor + node metrics via the API server proxy ──────
  - job_name: kubernetes-nodes
    kubernetes_sd_configs:
      - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      # Promote every node label to a series label (node_label_* → *)
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      # Rewrite the target to hit the API server, then proxy to the kubelet.
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics

  # ── Job 4: Pods, opt-in via annotations (the classic auto-discovery job) ────
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 1. Opt-in: scrape only pods annotated prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true

      # 2. Override the scrape scheme if prometheus.io/scheme is set (http|https)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)

      # 3. Override the metrics path if prometheus.io/path is set
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 4. Override the port: combine pod IP with prometheus.io/port
      #    __address__ arrives as "<ip>:<declared-container-port>"; we rewrite it.
      - source_labels:
          - __address__
          - __meta_kubernetes_pod_annotation_prometheus_io_port
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      # 5. Promote all pod labels to series labels
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 6. Attach stable identity labels
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node

  # ── Job 5: Services via their Endpoints (scrapes the backing pods) ──────────
  - job_name: kubernetes-service-endpoints
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels:
          - __address__
          - __meta_kubernetes_service_annotation_prometheus_io_port
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

**Sutilezas clave que un entrevistador (y el examen) sondea:**

- **`role: endpoints` scrapea Pods, no la VIP del Service.** Descubrir vía `role: service` scrapearía la ClusterIP del Service, que balancea la carga entre réplicas — obtendrías métricas de *una réplica al azar en cada scrape*, destruyendo las series temporales por instancia. `role: endpoints` (o `endpointslice`) enumera los Pods de respaldo reales, dando un target por réplica. Por eso el job "service" de arriba usa `role: endpoints`, no `role: service`.
- **Los labels de doble guion bajo son el plano de control.** `__address__`, `__scheme__`, `__metrics_path__`, y `__param_<name>` son labels *mágicos* consumidos por el scrape manager y luego descartados. Cualquier label que empiece con `__` se descarta antes de la ingesta a menos que lo copies explícitamente. Por eso los labels de identidad (`namespace`, `pod`, …) deben ser `replace`ados fuera de `__meta_*` — los originales `__meta_*` nunca llegan al almacenamiento.
- **`labelmap` copia, no filtra.** Es cómo convertís labels arbitrarios de Kubernetes en labels de serie al por mayor. Cuidado con la cardinalidad: promover *todos* los labels de un pod puede inyectar labels de alta cardinalidad (por ejemplo `pod-template-hash`) que no querés.

### 3.3 SD basado en archivos — la vía de escape universal

File SD desacopla la producción de targets de Prometheus. Cualquier proceso — un cron job, un exporter de CMDB, un controller custom — escribe archivos de targets JSON/YAML; Prometheus vigila el directorio y recarga en milisegundos (inotify), o en `refresh_interval` como fallback.

Fragmento de `prometheus.yml`:

```yaml
  - job_name: file-sd-blackbox
    file_sd_configs:
      - files:
          - /etc/prometheus/file_sd/*.json
          - /etc/prometheus/file_sd/*.yml
        refresh_interval: 5m        # inotify handles fast changes; this is the safety net
    relabel_configs:
      - source_labels: [env]
        target_label: environment
```

Archivo de targets `/etc/prometheus/file_sd/edge-routers.json` (escrito por tu automatización):

```json
[
  {
    "targets": ["10.20.0.11:9100", "10.20.0.12:9100"],
    "labels": {
      "job": "node",
      "env": "prod",
      "region": "eu-west-1",
      "role": "edge-router"
    }
  },
  {
    "targets": ["10.30.0.5:9100"],
    "labels": {
      "job": "node",
      "env": "staging",
      "region": "eu-west-1"
    }
  }
]
```

Los labels en el archivo se vuelven directamente labels de target equivalentes a `__meta` (más `__meta_filepath` apuntando al archivo fuente, útil para depurar qué archivo produjo un target). Como el formato es trivial y agnóstico del lenguaje, file SD es la vía recomendada para cualquier fuente que Prometheus no soporte nativamente.

### 3.4 SD de Consul

```yaml
  - job_name: consul-services
    consul_sd_configs:
      - server: consul.service.consul:8500
        token_file: /etc/prometheus/consul-token
        # Restrict to specific services; omit to discover everything (rarely wise)
        services: ["checkout", "payments", "inventory"]
    relabel_configs:
      # Only keep instances tagged for scraping
      - source_labels: [__meta_consul_tags]
        regex: .*,metrics,.*
        action: keep
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_node]
        target_label: instance
      - source_labels: [__meta_consul_dc]
        target_label: datacenter
```

Notá el patrón `__meta_consul_tags`: los tags de Consul llegan como un único string unido y envuelto por el separador de tags (default `,`), así que el regex matchea `,metrics,` en el medio — esto matchea de manera confiable un tag completo en lugar de un substring de otro tag.

### 3.5 SD de DNS (headless Services, registros SRV)

```yaml
  - job_name: dns-srv-cassandra
    dns_sd_configs:
      - names:
          - _prometheus._tcp.cassandra.prod.svc.cluster.local
        type: SRV
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__meta_dns_name]
        target_label: dns_srv_record
```

Con `type: SRV`, Prometheus lee tanto el host como el puerto del registro SRV. Con `type: A`/`AAAA` debés establecer el puerto vía un campo `port:`, porque los registros A no llevan puerto.

---

## 4. Verificación por CLI e inspección en vivo

### 4.1 Validar la configuración antes de que llegue al servidor

`promtool` atrapa errores sintácticos y semánticos de la config offline. Nunca recargues un Prometheus con una config no validada en producción — un reload malo puede dejar el servidor corriendo la config *vieja* mientras creés que tomó la nueva.

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 2 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/node.yml
 SUCCESS: 14 rules found

Checking /etc/prometheus/rules/k8s.yml
 SUCCESS: 31 rules found
```

Una acción de relabel malformada se atrapa acá, no en runtime:

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  FAILED: parsing YAML file /etc/prometheus/prometheus.yml: unknown relabel action "kepp"
```

### 4.2 Disparar un reload de config en vivo (sin restart)

```console
$ curl -sf -X POST http://localhost:9090/-/reload && echo "reloaded"
reloaded
```

(Requiere `--web.enable-lifecycle`. Confirmá que el reload realmente tomó efecto vía `prometheus_config_last_reload_successful == 1` y `prometheus_config_last_reload_success_timestamp_seconds`.)

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=prometheus_config_last_reload_successful' \
    | jq -r '.data.result[0].value[1]'
1
```

### 4.3 Inspeccionar targets activos — la verdad de fondo del SD

La API `/api/v1/targets` es la vista autoritativa de lo que produjo el SD. `discoveredLabels` muestra el conjunto crudo `__meta_*` *antes* del relabeling; `labels` muestra el conjunto final *después*. Compararlos es cómo depurás el relabeling.

```console
$ curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[0]'
{
  "discoveredLabels": {
    "__address__": "10.244.3.17:8080",
    "__meta_kubernetes_namespace": "payments",
    "__meta_kubernetes_pod_annotation_prometheus_io_scrape": "true",
    "__meta_kubernetes_pod_annotation_prometheus_io_port": "9102",
    "__meta_kubernetes_pod_container_port_number": "8080",
    "__meta_kubernetes_pod_name": "checkout-7d9f6c8b4d-x2klq",
    "__meta_kubernetes_pod_node_name": "ip-10-0-3-14.eu-west-1.compute.internal",
    "__meta_kubernetes_pod_label_app": "checkout",
    "__metrics_path__": "/metrics",
    "__scheme__": "http",
    "job": "kubernetes-pods"
  },
  "labels": {
    "app": "checkout",
    "instance": "10.244.3.17:9102",
    "job": "kubernetes-pods",
    "namespace": "payments",
    "node": "ip-10-0-3-14.eu-west-1.compute.internal",
    "pod": "checkout-7d9f6c8b4d-x2klq"
  },
  "scrapePool": "kubernetes-pods",
  "scrapeUrl": "http://10.244.3.17:9102/metrics",
  "globalUrl": "http://10.244.3.17:9102/metrics",
  "lastError": "",
  "lastScrape": "2026-08-08T10:42:11.884Z",
  "lastScrapeDuration": 0.021344,
  "health": "up"
}
```

Leé la historia en ese objeto: el SD descubrió el Pod en `:8080` (su puerto de contenedor), la anotación `prometheus.io/port: "9102"` disparó la reescritura de `__address__` a `:9102`, y el `instance` final refleja la dirección reescrita. Todo cuadra — `health: up`.

Filtrá solo los no saludables durante un incidente:

```console
$ curl -s http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[]
             | select(.health!="up")
             | "\(.health)\t\(.scrapeUrl)\t\(.lastError)"'
down    http://10.244.5.9:9102/metrics    Get "http://10.244.5.9:9102/metrics": dial tcp 10.244.5.9:9102: connect: connection refused
down    http://10.244.2.3:9102/metrics    context deadline exceeded
```

### 4.4 Ver lo que el SD *descartó* — la mitad invisible

Los targets removidos por una regla de relabel `drop`/`keep` aparecen como `droppedTargets`, no `activeTargets`. Acá es donde se resuelve "mi Pod existe pero no lo scrapean y no hay error en ningún lado": fue descartado por relabeling, así que nunca se volvió target y nunca produjo un error.

```console
$ curl -s 'http://localhost:9090/api/v1/targets?state=dropped' \
    | jq '.data.droppedTargets[0].discoveredLabels
          | {ns: .__meta_kubernetes_namespace,
             pod: .__meta_kubernetes_pod_name,
             scrape: .__meta_kubernetes_pod_annotation_prometheus_io_scrape}'
{
  "ns": "default",
  "pod": "nginx-6799fc88d8-7v9qz",
  "scrape": null
}
```

`scrape: null` → el Pod no tiene anotación `prometheus.io/scrape` → la regla `keep … regex: true` lo descartó. Funcionando según lo diseñado. (Por defecto Prometheus mantiene una cantidad acotada de targets descartados en memoria por pool; ajustá con `keep_dropped_targets` si necesitás ver más, o menos para ahorrar memoria en clusters enormes.)

### 4.5 Los equivalentes en la web UI

- **`/targets`** — la vista humana de §4.3, agrupada por scrape pool, con salud, último scrape, y último error.
- **`/service-discovery`** — la vista humana del diff de labels descubiertos-vs-finales (§4.3/§4.4), incluyendo targets descartados y *qué acción de relabel* los descartó. Esta es la página más útil para depurar SD y relabeling.
- **`/config`** — la config *efectiva* en ejecución tras el último reload exitoso; verificá que el servidor realmente esté corriendo la config que creés.

---

## 5. Playbook de diagnóstico de fallas

Un árbol de decisión disciplinado, desde "target totalmente ausente" hasta "target presente pero roto". Trabajá de arriba hacia abajo — cada peldaño asume que los de arriba pasaron.

| Síntoma | Dónde mirar | Causa probable y solución |
|---|---|---|
| **Target no está en `/targets` *ni* en `/service-discovery` para nada** | Fuente de verdad | El SD no lo está descubriendo. RBAC `403` (revisá los logs de Prometheus por `Failed to watch …: forbidden`); `role` equivocado; el selector de namespace/label lo excluye; el objeto genuinamente ausente (`kubectl get endpoints -n <ns>`). |
| **El target aparece bajo `droppedTargets` / griseado en `/service-discovery`** | `relabel_configs` | Una regla `keep`/`drop` lo removió. La página `/service-discovery` nombra la acción culpable. Usualmente una anotación faltante/no coincidente (`prometheus.io/scrape != "true"`). |
| **`health: down`, error `connection refused`** | El target mismo | Nada escuchando en esa dirección:puerto. Puerto equivocado en el relabeling; el exporter crasheó; la anotación `prometheus.io/port` apunta al puerto equivocado. `kubectl exec` + `curl localhost:<port>/metrics`. |
| **`health: down`, error `context deadline exceeded`** | Red / latencia del target | `scrape_timeout` demasiado bajo para un `/metrics` lento; NetworkPolicy bloqueando Prometheus → Pod; target sobrecargado. Subí `scrape_timeout` (debe ser ≤ `scrape_interval`) o arreglá el camino de red. |
| **`health: down`, error `server returned HTTP status 401/403`** | Auth | Bearer token o cert de cliente faltante/expirado; `authorization`/`tls_config` equivocado. |
| **`health: down`, error `x509: certificate signed by unknown authority`** | TLS | `ca_file` faltante/incorrecto, o `__scheme__` puesto en `https` contra un endpoint HTTP. |
| **`health: up` pero el label `instance` está mal / series duplicadas** | Relabeling de `__address__` | `__address__` no reescrito al puerto de métricas, así que dos jobs scrapean el mismo Pod en dos puertos, o `instance` colisiona entre réplicas. |
| **Los Pods nuevos tardan minutos en aparecer** | Modelo de refresh | Estás en un SD basado en poll (DNS/EC2/HTTP) con un `refresh_interval` grande; o usaste `role: service` (VIP) en lugar de `role: endpoints`. |
| **La métrica `up` falta completamente para un job** | Cableado del job | El job produjo cero targets — toda la cadena `keep` no matcheó nada. Revisá `count(up{job="X"})` y la página `/service-discovery` para ese pool. |

### Ejemplo trabajado: "el Pod está corriendo pero no lo scrapean"

```console
# 1. Does SD see the Pod at all?  (search discovered labels for the pod name)
$ curl -s 'http://localhost:9090/api/v1/targets?state=any' \
    | jq -r '.data.activeTargets[].discoveredLabels.__meta_kubernetes_pod_name,
             .data.droppedTargets[].discoveredLabels.__meta_kubernetes_pod_name' \
    | grep checkout-7d9f6c8b4d-x2klq
checkout-7d9f6c8b4d-x2klq        # ← present, so RBAC & discovery are fine

# 2. Active or dropped?  It wasn't in activeTargets → it's dropped. Why?
$ kubectl get pod checkout-7d9f6c8b4d-x2klq -n payments \
    -o jsonpath='{.metadata.annotations}' | jq .
{
  "prometheus.io/port": "9102"
}
#    → prometheus.io/scrape is MISSING. The `keep … regex: true` rule dropped it.

# 3. Fix: add the opt-in annotation.
$ kubectl annotate pod checkout-7d9f6c8b4d-x2klq -n payments prometheus.io/scrape=true
pod/checkout-7d9f6c8b4d-x2klq annotated

# 4. Confirm it flipped to active (k8s SD is watch-based, so this is near-instant).
$ sleep 2; curl -s http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[]
             | select(.labels.pod=="checkout-7d9f6c8b4d-x2klq")
             | .health'
up
```

El principio general: **`discoveredLabels` te dice qué encontró el SD; `labels` te dice qué sobrevivió al relabeling; la brecha entre ellos es tu bug.** Para workloads persistentes, poné la anotación en el template del Pod en el `Deployment`, no en el Pod vivo (que se recrea en el rollout).

### Meta-monitoreo que siempre deberías tener

```promql
# Any target down, grouped by job — the canonical scrape-health alert.
sum by (job) (up == 0)

# SD produced fewer targets than expected for a critical job.
count(up{job="kubernetes-pods"}) < 3

# Config reload failed — you may be running stale config.
prometheus_config_last_reload_successful == 0

# Scrapes routinely exceed their timeout budget.
scrape_duration_seconds > scrape_timeout_seconds  # via the scrape's own timeout
```

---

## Referencias

- Configuration reference (`scrape_config`, all `*_sd_config` blocks): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- `kubernetes_sd_config` (roles and `__meta_kubernetes_*` labels): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- `relabel_config` (actions, `source_labels`, regex, defaults): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- `file_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config
- `consul_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#consul_sd_config
- `dns_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#dns_sd_config
- `ec2_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#ec2_sd_config
- File-based service discovery guide: https://prometheus.io/docs/guides/file-sd/
- HTTP API — `/api/v1/targets`: https://prometheus.io/docs/prometheus/latest/querying/api/#targets
- Relabeling concepts guide: https://prometheus.io/docs/prometheus/latest/configuration/relabeling/
- `promtool` management: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- Kubernetes RBAC (verbs, ClusterRole): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- CNCF PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf