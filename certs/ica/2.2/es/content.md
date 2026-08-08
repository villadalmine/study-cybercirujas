# Tema 2.2 — Troubleshooting the Mesh Control Plane

> Dominio 2 · Peso en el examen: **7** · Perfil: SRE / Platform Architect
> Foco: diagnosticar por qué la configuración deja de propagarse, por qué el control plane se degrada bajo carga, y cómo recuperar la sincronización entre `istiod` y la flota de proxies sin cortar tráfico.

---

## 1. Motivación y el problema arquitectónico de producción

En Istio, el **control plane** (`istiod`) no está en el camino del paquete. El dato viaja proxy-a-proxy (Envoy sidecar ↔ Envoy sidecar) sin tocar `istiod`. Esto tiene una consecuencia operativa que domina todo el troubleshooting de este tema:

> **El data plane es *fail-static*.** Si `istiod` se cae, se satura o rechaza tu configuración, el tráfico **sigue funcionando** con el último *config* válido que cada Envoy recibió. No hay caída inmediata: hay **deriva silenciosa** (silent staleness).

El síntoma canónico de producción no es "se cayó la malla", es:

- *"Apliqué un `VirtualService` hace 20 minutos y el tráfico sigue yendo a la versión vieja."*
- *"Escalé el `Deployment` y los pods nuevos no reciben tráfico"* (EDS no propagó).
- *"El mTLS empezó a fallar de golpe en la mitad de la flota"* (rotación de CA / SDS).

Ninguno de estos dispara una alerta de "pod caído". El control plane falla **hacia el silencio**, y por eso el instrumento primario no es `kubectl get pods` sino el **estado de sincronización xDS**.

### 1.1 Anatomía de `istiod` (qué troubleshootear)

Desde Istio 1.5 el control plane es un binario monolítico, `istiod`, que absorbió los tres componentes históricos:

| Función histórica | Rol dentro de `istiod` | Falla que produce |
|---|---|---|
| **Pilot** | Traduce CRDs + service registry a config Envoy (xDS) y la empuja por ADS | Config no propaga, STALE, NACK, EDS vacío |
| **Citadel** | CA interna: firma CSRs, emite y rota certs de workload por SDS | mTLS roto, `PERMISSION_DENIED`, cert expirado |
| **Galley** | Validación de config vía `ValidatingWebhookConfiguration` | `kubectl apply` rechazado o config inválida aceptada |
| **Sidecar Injector** | `MutatingWebhookConfiguration` que inyecta el contenedor `istio-proxy` | Pods sin sidecar, no forman parte de la malla |

### 1.2 El ciclo de reconciliación (el lazo que se rompe)

Todo el troubleshooting de propagación consiste en localizar en qué eslabón de esta cadena se cortó el flujo:

```
  Fuentes de config                Núcleo de istiod                    Data plane
 ┌──────────────────┐        ┌───────────────────────────┐        ┌──────────────┐
 │ K8s API:         │        │ 1. Config/Registry event  │        │              │
 │  VirtualService  │──────▶ │ 2. Debounce (agrupa)      │        │   Envoy      │
 │  DestinationRule │        │    PILOT_DEBOUNCE_AFTER   │        │   sidecar    │
 │  Gateway         │        │ 3. PushContext (snapshot) │        │              │
 │  ServiceEntry    │        │ 4. Genera xDS (CDS/LDS/   │  ADS   │  ┌────────┐  │
 │  Sidecar         │        │    RDS/EDS/SDS/ECDS)      │═══════▶│  │ ACK ✔  │  │
 │  Auth policies   │        │ 5. Push por ADS (gRPC)    │◀═══════│  │ NACK ✘ │  │
 │ K8s Endpoints ───┼──────▶ │ 6. Espera ACK/NACK        │        │  └────────┘  │
 │ MeshConfig       │        │ 7. CA: firma certs (SDS)  │        │              │
 └──────────────────┘        └───────────────────────────┘        └──────────────┘
```

Los puntos de ruptura, con la herramienta que los revela:

1. **El evento no llega a istiod** → registry/config no ve el objeto (`pilot_k8s_cfg_events`, `/debug/registryz`).
2. **Debounce/convergencia lenta** → istiod saturado, `pilot_proxy_convergence_time` alto.
3. **Config inválida** → istiod la descarta al construir `PushContext` (`pilot_xds_push_context_errors`, logs).
4. **Push rechazado por Envoy (NACK)** → `pilot_total_xds_rejects`, proxy-status `STALE`.
5. **Conexión ADS caída** → el proxy no está en `/debug/adsz`, `NOT SENT`.
6. **Cert no emitido** → SDS/CA, `istioctl proxy-config secret`, errores de CA.

### 1.3 Puertos que hay que conocer para diagnosticar

| Puerto | Componente | Uso en troubleshooting |
|---|---|---|
| **15010** | istiod — xDS/MCP **plaintext** | Inseguro, desalentado; útil sólo para debug local |
| **15012** | istiod — xDS + CA sobre **mTLS** | Puerto real de producción para descubrimiento y certs |
| **15014** | istiod — **monitoring** | `/metrics` Prometheus del control plane |
| **8080** | istiod — **debug** | Endpoints `/debug/*` (protegidos; usar `istioctl x internal-debug`) |
| **9876** | istiod — **ControlZ** | UI de introspección (`istioctl dashboard controlz`) |
| **15000** | Envoy sidecar — **admin** | `config_dump`, `clusters`, `stats`, `certs`, `logging` |
| **15021** | Envoy sidecar — health | `/healthz/ready` (readiness del proxy) |
| **15020** | istio-agent — merge metrics | Métricas fusionadas del pod |
| **15090** | Envoy — telemetry | `/stats/prometheus` del proxy |

---

## 2. Comparativas técnicas y tablas de trade-offs

### 2.1 Estados de sincronización xDS (la tabla que hay que memorizar)

`istioctl proxy-status` reporta, **por cada tipo xDS y por cada proxy**, uno de estos estados:

| Estado | Significado exacto | Interpretación operativa |
|---|---|---|
| **SYNCED** | Envoy recibió la última config e hizo **ACK** | Sano. La config vigente coincide con la de istiod |
| **STALE** | istiod **envió** la config pero Envoy no hizo ACK todavía | Peligroso si persiste: NACK, proxy lento, o conexión colgada |
| **NOT SENT** | istiod **no envió nada** de ese tipo | Normal si no hay config de ese tipo (p.ej. RDS sin rutas HTTP); anómalo si esperabas rutas |
| **STALE (Never Acknowledged)** | Se envió pero **nunca** hubo ACK | Casi siempre NACK persistente: la config es inválida para ese Envoy |

Regla mnemónica: **SYNCED = verdad propagada; STALE = verdad enviada pero no confirmada; NOT SENT = no hay verdad que enviar.** Un `VirtualService` que "no hace efecto" con RDS en `SYNCED` significa que tu problema no es propagación, es *contenido* de la config → pasás a `proxy-config`.

### 2.2 Superficies de diagnóstico: cuál usar y cuándo

| Herramienta | Qué responde | Costo/riesgo | Cuándo es la correcta |
|---|---|---|---|
| `istioctl proxy-status` | ¿La config **propagó**? (SYNCED/STALE) | Nulo, read-only | **Primer comando siempre.** Aísla control-plane vs data-plane |
| `istioctl proxy-config` | ¿Qué config **tiene realmente** ese Envoy? | Nulo, read-only | Cuando está SYNCED pero "no funciona" → mirar el contenido |
| `istioctl analyze` | ¿La config es **coherente** estáticamente? | Nulo, análisis estático | Antes de aplicar; detecta conflictos, refs rotas |
| `istioctl x internal-debug` | Estado **interno** de istiod (registry, push status) | Bajo; algunos endpoints fuerzan push | Cuando sospechás del control plane, no del proxy |
| **ControlZ** | Log levels, memoria, env, métricas de istiod | Bajo | Subir verbosidad en caliente, ver estado del proceso |
| Métricas Prometheus | Tendencias: convergencia, rejects, pushes | Nulo | Saturación, degradación gradual, alerting |
| Logs de `istiod` (`ads:debug`) | El "por qué" textual de un NACK/rechazo | Verboso, ruido | Última milla: mensaje exacto de rechazo |

### 2.3 Matriz falla → síntoma → herramienta

| Falla de producción | Síntoma observable | Herramienta que confirma |
|---|---|---|
| Config no propaga | `proxy-status` = STALE persistente | `proxy-status`, `pilot_total_xds_rejects` |
| Config inválida (NACK) | STALE (Never Acknowledged), spikes de rejects | logs `ads:debug`, `proxy-config` warnings |
| Sidecar no inyectado | Pod con 1/1 en vez de 2/2, no en la malla | `kubectl get mutatingwebhookconfiguration`, labels del ns |
| istiod saturado | `pilot_proxy_convergence_time` p99 ↑, OOMKilled | métricas, `kubectl top`, `/debug/push_status` |
| EDS vacío | Servicio sin endpoints, 503 UH/UF | `proxy-config endpoints`, `/debug/edsz` |
| mTLS roto | 503 con `upstream_reset`, `PERMISSION_DENIED` | `proxy-config secret`, logs CA, `citadel_*` métricas |
| Version skew | Comportamiento xDS incompatible | `istioctl proxy-status` (columna VERSION) |

---

## 3. Herramientas de diagnóstico — comandos y salidas reales

### 3.1 `istioctl proxy-status` — el estado de la malla en una vista

```console
$ istioctl proxy-status
NAME                                        CLUSTER     CDS      LDS      EDS      RDS      ECDS     ISTIOD                    VERSION
details-v1-698b5d8c98-4x2kq.default         Kubernetes  SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT istiod-5c7d9f6b8-abcde     1.20.2
productpage-v1-6b746f74dc-p9m7n.default     Kubernetes  SYNCED   SYNCED   SYNCED   STALE    NOT SENT istiod-5c7d9f6b8-abcde     1.20.2
ratings-v1-5dc79b6bcd-tqz5k.default         Kubernetes  SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT istiod-5c7d9f6b8-abcde     1.20.2
reviews-v2-5b667bcbf8-h2n6l.default         Kubernetes  STALE    STALE    STALE    STALE    NOT SENT istiod-5c7d9f6b8-abcde     1.18.5
```

Lectura del SRE:
- `productpage` en **RDS = STALE** → esa ruta HTTP no fue confirmada. Culpable típico: un `VirtualService` que Envoy rechaza. Ir a los logs.
- `reviews-v2` **todo STALE + VERSION 1.18.5** frente a istiod 1.20.2 → **version skew** de 2 minors. En el límite del soporte n-2; si fuera 1.17 estaría fuera de soporte y sería la causa raíz.
- La columna `ISTIOD` te dice **a qué réplica** está conectado el proxy: si sólo una réplica muestra STALE, el problema es esa instancia de istiod, no la config.

### 3.2 `istioctl proxy-config` — qué config tiene *realmente* el Envoy

Cuando `proxy-status` está SYNCED pero el tráfico "no obedece", el problema es el **contenido**:

```console
$ istioctl proxy-config routes productpage-v1-6b746f74dc-p9m7n.default --name 9080 -o json | jq '.[].virtualHosts[].routes[].route.cluster'
"outbound|9080|v1|reviews.default.svc.cluster.local"
```

Esto revela que la ruta apunta al subset `v1` — si esperabas `v2`, tu `DestinationRule`/`VirtualService` de destino está mal, aunque haya propagado bien.

Verificación de endpoints (el clásico "503 no healthy upstream"):

```console
$ istioctl proxy-config endpoints reviews-v1-.default --cluster "outbound|9080||reviews.default.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.1.15:9080     HEALTHY     OK                outbound|9080||reviews.default.svc.cluster.local
10.244.2.9:9080      HEALTHY     OK                outbound|9080||reviews.default.svc.cluster.local
```

Cluster vacío = EDS no descubrió pods → revisar `Service`/`EndpointSlice`, selectors, o `Sidecar` que recorta el egress.

Verificación de certificados (mTLS):

```console
$ istioctl proxy-config secret productpage-v1-6b746f74dc-p9m7n.default
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2f3a...c1            2026-08-09T12:04:11Z     2026-08-08T12:02:11Z
ROOTCA            CA             ACTIVE     true           9b7e...aa            2036-08-01T00:00:00Z     2026-08-01T00:00:00Z
```

`VALID CERT = false`, `NOT AFTER` en el pasado, o `default` ausente ⇒ SDS/CA no emitió el cert de workload → mTLS caído.

### 3.3 `istioctl analyze` — análisis estático antes de que duela

```console
$ istioctl analyze -n default
Error [IST0101] (VirtualService reviews-route.default) Referenced host+subset in destinationrule not found: "reviews.default+v3"
Warning [IST0102] (Namespace default) The namespace is not enabled for Istio injection. Run 'kubectl label namespace default istio-injection=enabled' to enable it.
Info [IST0118] (Service reviews.default) Port name http is valid but the port appears to be unnamed for protocol detection.

Error: Analyzers found issues when analyzing namespace: default.
```

`IST0101` es la causa raíz de un STALE en RDS antes siquiera de aplicar: la `VirtualService` referencia un subset `v3` que no existe en la `DestinationRule`.

### 3.4 Endpoints de debug de istiod vía `istioctl x internal-debug`

Los `/debug/*` están protegidos; el modo soportado (multi-revisión) es:

```console
$ istioctl x internal-debug syncz | jq '.[] | {proxy: .proxy, cds: .clusterSent==.clusterAcked}'
{ "proxy": "productpage-v1-....default", "cds": true }
{ "proxy": "reviews-v2-....default",     "cds": false }

# Registry de servicios que istiod conoce (¿existe el servicio?)
$ istioctl x internal-debug registryz | jq '.[] | select(.hostname=="reviews.default.svc.cluster.local") | .hostname'
"reviews.default.svc.cluster.local"

# Estado del último push y errores de contexto
$ istioctl x internal-debug push_status | jq '.pilot_push_context_errors'
```

Endpoints clave (todos bajo `/debug/`):

| Endpoint | Responde |
|---|---|
| `syncz` | Estado ACK/NACK por proxy y tipo xDS |
| `registryz` | Servicios en el service registry |
| `endpointz` / `edsz` | Endpoints por cluster (EDS) |
| `configz` | Config (CRDs) que istiod tiene cargada |
| `adsz` | Proxies conectados por ADS (`?push=true` **fuerza push — peligroso**) |
| `config_dump?proxyID=<pod.ns>` | Config completa generada para un proxy |
| `push_status` | Errores del último cómputo de push |
| `mesh` | `MeshConfig` efectivo |

### 3.5 ControlZ — introspección y verbosidad en caliente

```console
$ istioctl dashboard controlz istiod-5c7d9f6b8-abcde.istio-system
http://localhost:9876
```

Desde ControlZ (o vía CLI) se sube el nivel de log **por scope** sin reiniciar:

```console
$ kubectl exec -n istio-system deploy/istiod -- \
    curl -s -X PUT http://localhost:9876/scopej/ads -d '{"output_level":"debug"}'
```

Scopes útiles: `ads` (push/ACK/NACK), `config` (ingesta de CRDs), `validation` (webhook), `ca` (emisión de certs).

### 3.6 Logs de istiod: aislar el mensaje de rechazo

```console
$ kubectl logs -n istio-system deploy/istiod --tail=200 | grep -Ei 'nack|reject|error'
2026-08-08T14:22:07.113Z warn ads ADS:RDS: ACK ERROR productpage-v1-....default Internal:Error adding/updating
  listener(s) 0.0.0.0_9080: Only unique values for domains are permitted. Duplicate entry of domain reviews.default.svc.cluster.local
```

Ahí está la causa raíz textual del STALE de RDS: dos `VirtualService` declaran el mismo host → dominio duplicado → NACK.

### 3.7 Version skew — la regla n-2

```console
$ istioctl version
client version: 1.20.2
control plane version: 1.20.2
data plane version: 1.20.2 (11 proxies), 1.18.5 (1 proxies)
```

Istio soporta el data plane hasta **2 minors por detrás** del control plane. `1.18.5` con control plane `1.20.2` está en el borde; cualquier proxy en 1.17 o anterior debe reiniciarse para tomar el sidecar nuevo (`kubectl rollout restart deploy/<x>`).

---

## 4. Manifiestos completos — endurecer y observar el control plane

### 4.1 `istiod` con recursos, HPA y PDB (evitar el OOM/CPU bajo carga)

`istiod` mantiene en memoria un snapshot (`PushContext`) del estado completo de la malla; su footprint crece con **servicios × proxies × config**. Saturarlo produce convergencia lenta y `OOMKilled` — la causa raíz #1 de STALE masivo a escala.

```yaml
# istiod-hardening.yaml — vía IstioOperator (o valores de Helm equivalentes)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: default
  components:
    pilot:
      k8s:
        replicaCount: 3
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            memory: "4Gi"            # sólo memoria: throttling de CPU degrada el push
        hpaSpec:
          minReplicas: 3
          maxReplicas: 8
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 70
        podDisruptionBudget:
          minAvailable: 2            # nunca menos de 2 réplicas durante drains
        env:
          - name: PILOT_DEBOUNCE_AFTER      # agrupa eventos: menos pushes, más latencia
            value: "100ms"
          - name: PILOT_DEBOUNCE_MAX        # techo del agrupamiento
            value: "10s"
          - name: PILOT_PUSH_THROTTLE       # pushes concurrentes máximos
            value: "100"
          - name: PILOT_ENABLE_EDS_DEBOUNCE
            value: "true"
  meshConfig:
    # Recorta el universo de config: sólo namespaces con esta label entran al PushContext
    discoverySelectors:
      - matchLabels:
          istio-discovery: "enabled"
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
```

### 4.2 `Sidecar` — recortar el scope de config por workload (la palanca de escala)

Por defecto, **cada** Envoy recibe la config de **toda** la malla. Un recurso `Sidecar` restringe qué destinos ve un workload, reduciendo drásticamente el tamaño del push y la memoria de istiod:

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: payments        # aplica a todos los pods del namespace
spec:
  egress:
    - hosts:
        - "./*"                        # servicios del propio namespace
        - "istio-system/*"             # control plane
        - "observability/prometheus.observability.svc.cluster.local"
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY        # bloquea egress a destinos no declarados (falla ruidosa, no silenciosa)
```

Efecto medible: tras aplicar `Sidecar` selectivos, `pilot_proxy_convergence_time` y `container_memory_working_set_bytes{app="istiod"}` caen. Es la primera intervención ante istiod saturado.

### 4.3 Alertas Prometheus para el control plane (detectar la deriva silenciosa)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: istiod-control-plane
  namespace: istio-system
spec:
  groups:
    - name: istiod.rules
      rules:
        - alert: IstiodConfigRejected
          # NACKs: Envoy rechaza la config que istiod empuja → STALE persistente
          expr: sum(rate(pilot_total_xds_rejects[5m])) > 0
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "istiod: config xDS rechazada (NACK) por el data plane"

        - alert: IstiodSlowConvergence
          # p99 del tiempo desde cambio de config hasta ACK del proxy
          expr: histogram_quantile(0.99, sum(rate(pilot_proxy_convergence_time_bucket[5m])) by (le)) > 10
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "istiod: convergencia p99 > 10s (control plane saturado)"

        - alert: IstiodPushContextErrors
          expr: sum(rate(pilot_xds_push_context_errors[5m])) > 0
          for: 5m
          labels: { severity: warning }

        - alert: SidecarInjectionFailing
          expr: sum(rate(sidecar_injection_failure_total[5m])) > 0
          for: 5m
          labels: { severity: critical }

        - alert: IstiodNoConnectedProxies
          # Si de golpe hay 0 proxies conectados, el ADS se cayó
          expr: sum(pilot_xds) == 0
          for: 3m
          labels: { severity: critical }

        - alert: CitadelCertIssuanceFailing
          expr: sum(rate(citadel_server_csr_parsing_err_count[5m])) > 0
          for: 5m
          labels: { severity: critical }
```

Métricas de control plane que hay que tener en el dashboard:

| Métrica | Qué vigila |
|---|---|
| `pilot_xds` | Proxies conectados por ADS (caída = ADS roto) |
| `pilot_proxy_convergence_time` | Cambio-a-ACK; el termómetro de saturación |
| `pilot_total_xds_rejects` | NACKs (config inválida) |
| `pilot_xds_push_context_errors` | Errores al construir el snapshot |
| `pilot_xds_pushes{type=...}` | Volumen de push por tipo (amplificación) |
| `pilot_conflict_*` | Conflictos de listener/ruta entre configs |
| `galley_validation_failed` | Webhook de validación rechazando |
| `sidecar_injection_failure_total` | Inyección fallando |
| `citadel_server_csr_count` / errores | Salud de la CA |

### 4.4 Inspección de los webhooks (inyección y validación)

```console
$ kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'
Fail
$ kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
    -o jsonpath='{.webhooks[0].namespaceSelector}{"\n"}' | jq
{ "matchLabels": { "istio-injection": "enabled" } }
```

- `failurePolicy: Fail` + istiod caído ⇒ **todo `create` de pods en la malla se bloquea** (blast radius grande). `Ignore` permite crear pods pero **sin sidecar** (deriva silenciosa). Este trade-off es examinable.
- Si el namespace no tiene la label `istio-injection=enabled` (o `istio.io/rev=<rev>` en instalaciones con revisiones), el sidecar **no se inyecta** y el pod queda fuera de la malla.

---

## 5. Guía de verificación y diagnóstico de fallas (runbooks)

### Runbook A — "Apliqué config y no propaga" (STALE)

```console
# 1. ¿Es control plane o data plane? Estado de sync de la flota:
$ istioctl proxy-status
# 2. Si hay STALE en algún tipo (p.ej. RDS), traé el mensaje exacto:
$ kubectl logs -n istio-system deploy/istiod | grep -Ei 'nack|reject' | tail
# 3. Confirmá que la config es válida estáticamente:
$ istioctl analyze -n <ns>
# 4. ¿istiod está sano y no saturado?
$ kubectl top pod -n istio-system -l app=istiod
$ istioctl x internal-debug push_status | jq '.'
```

- STALE + log NACK "duplicate domain / conflict" → **config conflictiva** (dos `VirtualService`, mismo host).
- STALE sin NACK + convergencia alta → **istiod saturado** → aplicar `Sidecar` scoping + subir réplicas.
- STALE en **un solo proxy** → ese Envoy o su conexión ADS; `kubectl rollout restart` de ese workload.

### Runbook B — "El pod no está en la malla" (sidecar no inyectado)

```console
$ kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}{"\n"}'   # ¿aparece istio-proxy?
$ kubectl get ns <ns> --show-labels | grep istio                          # label de inyección
$ kubectl get mutatingwebhookconfiguration istio-sidecar-injector          # webhook existe/sano
$ kubectl logs -n istio-system deploy/istiod | grep -i inject
```

Causas: label del namespace ausente/incorrecta (revisión), webhook borrado, `failurePolicy: Ignore` con istiod caído, o pod creado **antes** de labelear (necesita `rollout restart`).

### Runbook C — "Envoy rechaza la config" (NACK / conflicto)

```console
$ istioctl proxy-config listeners <pod> -o json | jq '.. | .warning? // empty'
$ kubectl exec -n istio-system deploy/istiod -- curl -s -X PUT \
    http://localhost:9876/scopej/ads -d '{"output_level":"debug"}'
$ kubectl logs -n istio-system deploy/istiod -f | grep -i 'ACK ERROR'
```

Recordá bajar el log a `info` después: `-d '{"output_level":"info"}'`.

### Runbook D — "istiod se degrada bajo carga" (OOM/CPU)

```console
$ kubectl get pod -n istio-system -l app=istiod          # ¿Restarts? ¿OOMKilled?
$ kubectl describe pod -n istio-system -l app=istiod | grep -A3 'Last State'
# Cuánta config está empujando (amplificación):
$ istioctl x internal-debug push_status | jq '.pilot_status | keys | length'
```

Remediación en orden: (1) aplicar `Sidecar` con egress recortado, (2) `discoverySelectors` para excluir namespaces no-mesh, (3) subir réplicas + HPA, (4) subir `PILOT_DEBOUNCE_AFTER` para agrupar más pushes.

### Runbook E — "mTLS empezó a fallar" (CA / SDS)

```console
$ istioctl proxy-config secret <pod>                     # ¿cert default ACTIVE y válido?
$ kubectl logs -n istio-system deploy/istiod | grep -iE 'ca|csr|cert'
$ istioctl x internal-debug syncz | jq '.[].proxy'       # ¿el proxy sigue conectado?
```

Causas frecuentes: rotación del root CA sin propagar la nueva cadena, **clock skew** entre nodos (cert "not yet valid"), o istiod-CA no disponible en el puerto 15012.

### Runbook F — "Comportamiento xDS raro tras upgrade" (version skew)

```console
$ istioctl version                                       # data plane version (N proxies)
$ istioctl proxy-status | awk '{print $NF}' | sort | uniq -c
# Forzar reinicio de proxies rezagados para tomar el sidecar nuevo:
$ kubectl rollout restart deploy/<workload> -n <ns>
```

Regla: data plane dentro de n-2 respecto al control plane; fuera de eso, upgradeá el sidecar antes de diagnosticar cualquier otra cosa.

---

## 6. Checklist de verificación (orden operativo)

1. `istioctl proxy-status` → ¿SYNCED en todos los tipos? Si no, aislá el tipo y el proxy.
2. `istioctl analyze` → ¿la config es coherente estáticamente?
3. `istioctl proxy-config <resource> <pod>` → ¿el contenido es el esperado?
4. Logs de `istiod` (`ads:debug`) → mensaje exacto del NACK.
5. Métricas: `pilot_total_xds_rejects`, `pilot_proxy_convergence_time`, `pilot_xds`.
6. `istioctl x internal-debug push_status/registryz/syncz` → estado interno de istiod.
7. Certs: `proxy-config secret` + métricas `citadel_*`.
8. `istioctl version` → descartar version skew.

---

## 7. Referencias

- Istio — Diagnostic Tools / Debugging Envoy and Istiod: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — Component Debugging (ControlZ, debug endpoints): https://istio.io/latest/docs/ops/diagnostic-tools/controlz/
- Istio — Understand your mesh with `istioctl describe`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/
- Istio — Configuration Analysis with `istioctl analyze`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Istio — Deployment Models / istiod architecture: https://istio.io/latest/docs/ops/deployment/architecture/
- Istio — Performance and Scalability (istiod tuning, Sidecar, discoverySelectors): https://istio.io/latest/docs/ops/deployment/performance-and-scalability/
- Istio — Configure DNS / `Sidecar` resource reference: https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — Istiod Metrics (Prometheus) reference: https://istio.io/latest/docs/reference/commands/pilot-discovery/
- Istio — Canary Upgrades & version skew policy: https://istio.io/latest/docs/setup/upgrade/canary/
- Istio — Sidecar Injection (webhook, namespace labels): https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio Security — Istio CA / SDS and certificate management: https://istio.io/latest/docs/tasks/security/cert-management/
- CNCF ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf
- Envoy — xDS protocol (ADS, ACK/NACK semantics): https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol