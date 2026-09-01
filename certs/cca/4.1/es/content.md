# 4.1 Observabilidad con Cilium

**Peso del dominio: 20 %.** Este es el bloque de observabilidad más pesado del blueprint del CCA, y se evalúa según si entendés *de dónde vienen los datos* — no según si podés recitar `hubble observe`. El material que sigue está escrito con profundidad de producción: origen en el datapath de cada evento, los compromisos de cardinalidad y retención que deciden si tu plataforma sobrevive al contacto con un clúster real, manifiestos completos y una escalera de diagnóstico.

---

## 1. El problema de producción

### 1.1 La telemetría indexada por IP está estructuralmente rota en Kubernetes

Toda herramienta clásica de observabilidad de red — NetFlow, sFlow, IPFIX, VPC Flow Logs, `conntrack -L`, `tcpdump` — tiene la misma clave primaria: la 5-tupla `(IP origen, puerto origen, IP destino, puerto destino, proto)`. Esa clave es estable en un datacenter donde un servidor conserva su dirección durante tres años. En Kubernetes es basura en cuestión de minutos:

| Propiedad | Red tradicional | Kubernetes |
|---|---|---|
| Vida útil de la dirección | Meses–años | Segundos–horas (las IPs de los Pods se reciclan agresivamente) |
| Mapeo dirección → workload | Estático, en un IPAM/CMDB | Solo en el apiserver, y solo mientras el Pod existe |
| Cantidad de direcciones por host | 1–4 | 30–250 (una por Pod, más las VIPs de servicio) |
| Búsqueda post-mortem | `dig -x`, CMDB | Imposible — el Pod ya no está y la IP le pertenece a otro |
| NAT | En el borde | En todos lados: DNAT de `kube-proxy`, SNAT de nodo, SNAT de egress gateway |

La consecuencia práctica: una revisión de incidente a las 09:00 sobre una línea de flow log escrita a las 02:40 que dice `10.0.7.19:52344 → 10.0.3.4:5432 DENIED` es **irresoluble**. `10.0.7.19` ahora pertenece al Pod de otro tenant. Tenés una línea de log y ninguna forma de atribuirla.

Una segunda falla, más sutil: **kube-proxy/iptables no te da ninguna señal de veredicto.** Cuando una `NetworkPolicy` descarta un paquete, iptables incrementa un contador en una cadena anónima. No hay registro de *qué* Pod intentó alcanzar a *qué* Pod, ni de *qué regla* lo denegó. Los equipos compensan corriendo `tcpdump` en los nodos — que no escala (captura en una interfaz, en un nodo, sin identidad) —, o poniendo un proxy sidecar junto a cada Pod — que grava cada request con dos saltos extra a espacio de usuario y solo ve el tráfico L7 que el proxy está configurado para interceptar.

### 1.2 La identidad es la clave primaria

La respuesta de Cilium es hacer que la clave de observabilidad sea **la identidad de seguridad**, no la dirección.

Cilium le asigna a cada endpoint una *identidad de seguridad* numérica derivada de un hash determinista de sus labels relevantes para seguridad (namespace, `app`, y lo que el operador incluya en la whitelist). Dos Pods del mismo Deployment en el mismo namespace comparten una identidad. Esa identidad es:

* propagada en el datapath — en la cabecera del túnel (VXLAN/Geneve) en modo encapsulación, o resuelta desde el mapa BPF `cilium_ipcache` en modo native-routing;
* usada por el motor de políticas como clave de coincidencia en los mapas BPF `cilium_policy_*`;
* adjuntada a **cada** evento de observabilidad que Cilium emite.

Así que un flow de Hubble está indexado por `(identidad, identidad)`, y la IP es decoración. `tenant-a/checkout (ID:14213) → tenant-b/postgres (ID:9917) DROPPED (Policy denied)` sigue siendo verdadero y sigue siendo atribuible tres meses después, cuando ambos Pods hayan sido reemplazados cuarenta veces.

**Rangos de identidad que tenés que reconocer en el examen y en un incidente:**

| Rango / valor | Significado |
|---|---|
| `1` | `reserved:host` — el propio nodo local (incluidos los Pods host-network) |
| `2` | `reserved:world` — cualquier cosa fuera del clúster sin identidad CIDR |
| `3` | `reserved:unmanaged` — un endpoint que Cilium no gestiona (todavía) |
| `4` | `reserved:health` — endpoints de cilium-health |
| `5` | `reserved:init` — endpoint cuyas labels aún no fueron resueltas |
| `6` | `reserved:remote-node` — otro nodo del clúster (o de la mesh) |
| `7` | `reserved:kube-apiserver` |
| `8` | `reserved:ingress` — Envoy de Cilium Ingress/Gateway API |
| `256 – 65535` | Identidades de alcance de clúster, asignadas desde CRDs o el kvstore |
| `≥ 16777216` (1<<24) | Identidades de **alcance local** — identidades CIDR y FQDN, locales al nodo, nunca propagadas |

La última fila es una trampa operativa: una identidad CIDR solo tiene sentido en el nodo que la asignó. Comparar números de identidad entre nodos para tráfico `toCIDR`/`toFQDN` está mal. Compará las *labels*.

### 1.3 De dónde vienen los eventos

Hubble no esnifa. Consume eventos que el datapath eBPF ya produce en el punto exacto donde se tomó la decisión.

```
                        ┌──────────────────────── one Kubernetes node ────────────────────────┐
                        │                                                                     │
   pod veth  ─ tc ingress/egress ─┐                                                           │
   host netdev ─ tc / XDP ────────┤                                                           │
   socket (cgroup/sock_ops) ──────┤                                                           │
                                  ▼                                                           │
                    ┌──────────────────────────────┐                                          │
                    │  eBPF datapath programs      │                                          │
                    │   trace_notify()   TraceNotify                                          │
                    │   send_drop_notify() DropNotify                                         │
                    │   send_policy_verdict_notify() PolicyVerdictNotify                      │
                    │   debug_msg()      DebugMsg                                             │
                    └───────────────┬──────────────┘                                          │
                                    │ bpf_perf_event_output()                                 │
                                    ▼                                                         │
                    ┌──────────────────────────────┐                                          │
                    │ cilium_events                │  BPF_MAP_TYPE_PERF_EVENT_ARRAY,          │
                    │ (per-CPU perf ring buffer)   │  size = --bpf-events-*-map-size          │
                    └───────────────┬──────────────┘                                          │
                                    │                                                         │
   Envoy L7 proxy  ──┐              │                                                         │
   DNS proxy       ──┼─ gRPC ──► ┌──▼─────────────────────────────────────────┐               │
                     │           │  cilium-agent : monitor consumer           │               │
                     │           │  decode → enrich (endpoint mgr, ipcache,   │               │
                     │           │  identity cache, service cache, k8s meta)  │               │
                     │           └──┬───────────────┬───────────────┬─────────┘               │
                     │              │               │               │                         │
                     │              ▼               ▼               ▼                         │
                     │      ┌───────────────┐ ┌────────────┐ ┌──────────────────┐             │
                     │      │ Hubble ring   │ │ Hubble     │ │ Hubble exporter  │             │
                     │      │ buffer (RAM)  │ │ metrics    │ │ (JSON to a file) │             │
                     │      │ capacity N    │ │ :9965      │ │ /var/run/cilium/ │             │
                     │      └──────┬────────┘ └────────────┘ │  hubble/events.log             │
                     │             │                         └──────────────────┘             │
                     │             │ gRPC Observer API                                        │
                     │   unix:///var/run/cilium/hubble.sock  and  TCP :4244 (mTLS)            │
                     └─────────────┴──────────────────────────────┬───────────────────────────┘
                                                                  │
                                  ┌───────────────────────────────▼──────────────┐
                                  │ hubble-relay  :4245   (stateless fan-out)    │
                                  │ discovers peers via the `hubble-peer` Service│
                                  └───────┬─────────────────────┬────────────────┘
                                          │                     │
                                 hubble CLI              hubble-ui (backend+frontend)
```

De este diagrama se desprenden cuatro cosas, y cada una es un hecho de nivel examen:

1. **Los eventos se producen donde ocurre el veredicto.** Un `DropNotify` lleva el código exacto de razón de descarte de eBPF y el punto de observación. No hay inferencia, ni heurística, ni reconstrucción a partir de capturas de paquetes.
2. **El agente es el único punto de enriquecimiento.** `hubble-relay` *no* realiza enriquecimiento alguno — es un multiplexor gRPC sin estado. Si un flow muestra `ID:0` o una IP pelada sin nombre de pod, el problema está en el agente del nodo que lo produjo (hueco en el ipcache, identidad todavía no asignada, tráfico genuinamente externo).
3. **El historial de Hubble es un ring buffer en RAM**, por nodo. No se escribe nada a disco a menos que habilites el exporter.
4. **Los eventos L7 son otro pipeline.** Vienen del proxy Envoy y del proxy DNS por gRPC, no de eBPF. Sin redirección al proxy → sin flow L7, sin importar cómo configures Hubble.

### 1.4 La verdad sobre la retención — el número que mata a la mayoría de los despliegues

El buffer por nodo se define con `--hubble-event-buffer-capacity` (Helm: es una clave de `cilium-config`; el valor debe ser `2^n − 1`). El default es **4095 flows**.

$$\text{retención}_{\text{segundos}} \approx \frac{\text{capacidad del buffer}}{\text{flows por segundo en ese nodo}}$$

| Tasa de flows del nodo | capacidad 4095 (default) | capacidad 65535 | capacidad 1048575 |
|---|---|---|---|
| 50 flows/s (tranquilo) | ~82 s | ~22 min | ~5,8 h |
| 500 flows/s (nodo prod típico) | ~8 s | ~2,2 min | ~35 min |
| 2 000 flows/s (nodo de ingress cargado) | **~2 s** | ~33 s | ~8,7 min |
| 20 000 flows/s (bajo escaneo/DDoS) | ~0,2 s | ~3 s | ~52 s |

A 2 000 flows/s el buffer por defecto guarda **dos segundos** de historial. Para cuando una alerta se dispara, un humano la lee, y alguien corre `hubble observe --last 500`, la evidencia fue sobrescrita miles de veces. Subir la capacidad cuesta aproximadamente `capacidad × ~O(1 KB)` de RSS del agente por nodo — 65 535 flows es del orden de decenas de MB, 1 048 575 es del orden de un gigabyte y casi nunca es la respuesta correcta.

**La conclusión arquitectónica — internalizala, es el punto entero del dominio:** el ring buffer de Hubble es una *superficie de depuración en vivo*, no un almacén de datos. La observabilidad de producción con Cilium son tres planos, y necesitás los tres:

| Plano | Responde | Retención | Costo |
|---|---|---|---|
| **Ring buffer** (`hubble observe`) | "¿Qué está pasando *ahora mismo* entre estos dos workloads?" | Segundos–minutos | RAM por nodo |
| **Métricas** (`:9965` → Prometheus) | "¿Subió la tasa de descartes? ¿En qué namespace? ¿Desde cuándo?" | Semanas–meses | Cardinalidad (ver §2.4) |
| **Exportación de flow logs** (archivo → Vector/Fluent Bit → Loki/S3) | "Reconstruí las 02:40 del martes pasado, flow por flow." | La que dé tu almacén de logs | Disco + $ de ingesta |

Los despliegues que solo llevan el primer plano son los que descubren, en medio de un incidente, que no tienen nada.

---

## 2. Comparaciones técnicas y compromisos

### 2.1 Enfoques de observabilidad de red en Kubernetes

| Enfoque | Consciente de identidad | L7 | Modelo de overhead | Retención | Usable post-mortem | Puntos ciegos |
|---|---|---|---|---|---|---|
| `tcpdump` en el nodo | ✗ (solo IPs) | Decodificación manual | Alto mientras corre; nulo si no | Lo que escribas | Solo si capturaste *antes* | Un nodo, una interfaz, sin veredicto, L7 cifrado opaco |
| `conntrack -L` / contadores de iptables | ✗ | ✗ | Insignificante | Ninguna (tabla en vivo) | ✗ | Sin atribución de descartes, sin identidad, rotación de la tabla |
| VPC flow logs de la nube | ✗ (IPs de nodo tras SNAT) | ✗ | Del lado del proveedor | Días–meses | Parcialmente | El tráfico Pod-a-Pod dentro de un nodo es invisible; SNAT colapsa todos los Pods a la IP del nodo |
| Telemetría de service mesh con sidecar | ✓ (workload) | ✓ | +2 saltos a espacio de usuario, ~50–100 MB de RSS *por Pod* | Solo métricas/trazas | Vía trazas | L3/L4 y protocolos no-HTTP invisibles; nada fuera de la mesh |
| Perfiladores eBPF por muestreo (p. ej. Pixie) | Parcial | ✓ | Depende del muestreo | Corta | Parcial | No es el punto de decisión de política — no puede decirte *por qué* se descartó un paquete |
| **Hubble** | ✓ (identidad + metadatos de k8s) | ✓ vía redirección al proxy | Emisión de eventos en el datapath; decodificación+enriquecimiento en el agente | Ring buffer en RAM + exportación | ✓ si se exporta | Descartes en etapa XDP, payload cifrado, todo lo que el proxy no redirige |
| Tetragon | ✓ (proceso + k8s) | ✗ (red) | Por evento, filtrado del lado del kernel | Basada en exportación | ✓ si se exporta | No es una herramienta de flows de red — responde *qué binario*, no *qué flow* |

**Frontera que tenés que saber enunciar:** Hubble responde preguntas de **red** — quién habló con quién, si fue reenviado o descartado, y por qué. Tetragon responde preguntas de **runtime** — qué proceso, qué syscall, qué archivo, qué capability. Comparten el sustrato eBPF y el modelo de identidad de Kubernetes; no son sustitutos.

### 2.2 Las cuatro formas de llegar a los datos de Hubble

| Vía de acceso | Endpoint | Alcance | Auth | Cuándo usarla |
|---|---|---|---|---|
| Socket Unix del agente | `/var/run/cilium/hubble.sock` | **Solo este nodo** | Sistema de archivos (dentro del pod) | Depuración profunda a nivel de nodo; `kubectl exec` dentro del agente |
| TCP del agente | `:4244` (Service `hubble-peer`) | Solo este nodo | mTLS | Consumido por el relay; no para humanos |
| **hubble-relay** | `:4245` | **Todo el clúster** | mTLS hacia los agentes; TLS opcional hacia los clientes | Default para la CLI `hubble` y la UI |
| Hubble UI | relay → `hubble-ui` | Clúster, con alcance por namespace | Lo que le pongas delante | Mapa de servicios, exploración, usuarios no expertos |
| Métricas | agente `:9965` | Por nodo, agregadas | Ninguna por defecto (**ver §5.6**) | Prometheus, alertas, dashboards |
| Exportación de flow logs | archivo en el nodo | Por nodo, todos los flows que coincidan con los filtros | Sistema de archivos | Retención de largo plazo, SIEM, cumplimiento |

El modo de falla que esta tabla previene: `hubble observe` ejecutado *dentro* de un Pod del agente devuelve solo los flows de ese nodo y la gente concluye "el tráfico no se está viendo". Sí se está viendo — en otro nodo.

### 2.3 Agregación del monitor — el dial de fidelidad/volumen

`monitor-aggregation` controla cuántos eventos de **trace** emite el datapath. *No* suprime los eventos de descarte.

| Nivel | Comportamiento | Eventos/s (relativo) | Qué perdés |
|---|---|---|---|
| `none` | Un evento por paquete, en ambas direcciones | 100× | Nada. Inutilizable a escala — va a saturar el perf buffer. |
| `low` | Agrega el tráfico reenviado por conexión por `monitor-aggregation-interval` | ~5× | Temporización por paquete |
| `medium` *(default)* | Como `low`, más re-emisión cuando cambian las flags TCP de `monitor-aggregation-flags` (default `all`) | 1× | Detalle por paquete en régimen estable; seguís viendo SYN/FIN/RST |
| `maximum` | La agregación más agresiva | ~0,5× | Transiciones de flags a mitad de conexión; visibilidad de retransmisiones |

Claves acompañantes: `monitor-aggregation-interval` (default `5s`), `monitor-aggregation-flags` (default `all` — `syn,fin,rst`).

**Regla:** nunca bajes la agregación a nivel de todo el clúster para depurar una sola cosa. La agregación es una perilla global del datapath; ir a `none` en un clúster de 200 nodos para perseguir un problema de retransmisión es cómo causás la caída que estabas investigando. Depurá con `cilium monitor` en el único nodo afectado.

### 2.4 Métricas de Hubble — el presupuesto de cardinalidad

Las métricas se habilitan una por una con una cadena de opciones: `<metric>:<opt>=<v>;<opt>=<v>`. Las opciones de contexto deciden tu factura de Prometheus.

| Valor de contexto | Label producida | Valores distintos (orden de) | Veredicto |
|---|---|---|---|
| `identity` | conjunto completo de labels | miles | ✗ Nunca en métricas |
| `ip` | `source_ip` / `destination_ip` | **= cantidad de Pods que alguna vez existieron** | ✗ No acotado — esta es la causa #1 de OOM de Prometheus con Cilium |
| `pod` | `namespace/pod-name` | = Pods que alguna vez existieron | ✗ No acotado |
| `pod-short` | `namespace/deployment-ish` | = workloads | ⚠ Acotado pero grande |
| `dns` | FQDN | = FQDNs distintos contactados | ⚠ No acotado para egress hacia internet |
| `namespace` | `namespace` | = namespaces | ✓ Seguro |
| `workload` / `workload-name` | workload propietario | = Deployments/StatefulSets | ✓ Seguro, mejor relación señal/costo |
| `app` | label `app` | = apps | ✓ Seguro |
| `reserved-identity` | `world`, `host`, `remote-node`… | ~8 | ✓ Seguro |

La cardinalidad es multiplicativa: `sourceContext × destinationContext × labels propias de la métrica × nodos`. `httpV2` con `labelsContext=source_ip,destination_ip` en un clúster de 100 nodos con 5 000 Pods produce conteos de series en las decenas de millones. Prometheus se va a morir.

| Métrica | Motor de series | Recomendada en prod |
|---|---|---|
| `drop` | `reason` × `protocol` × contexto | ✓ Siempre — esta es tu alarma de regresión de políticas |
| `flow` | `type` × `subtype` × `verdict` × `protocol` × contexto | ✓ Siempre |
| `tcp` | `flag` × `family` × contexto | ✓ Barata, detecta tormentas de RST |
| `dns` (`query;ignoreAAAA`) | `rcode` × `qtypes` × contexto | ✓ Alertar por NXDOMAIN es de alto valor |
| `icmp` | `family` × `type` | ✓ Barata |
| `httpV2` | `method` × `status` × `reporter` + buckets de histograma | ✓ Solo donde exista redirección L7 |
| `flows-to-world` | `protocol` × `verdict` | ✓ Señal de exposición de egress |
| `port-distribution` | **`port`** × `protocol` × contexto | ✗ Una serie por puerto de destino — los escáneres generan 65 535 |
| `http` (v1) | — | ✗ Reemplazada por `httpV2` |

`httpV2:exemplars=true` junto con `hubble.metrics.enableOpenMetrics=true` adjunta trace IDs a los buckets del histograma, que es lo que le permite a un usuario de Grafana hacer clic en un pico de latencia y aterrizar en la traza de Tempo/Jaeger. Requiere el formato de exposición OpenMetrics.

### 2.5 Obtener visibilidad L7 — los tres mecanismos

Los flows L7 existen solo si el tráfico es redirigido al proxy Envoy o al proxy DNS. No hay parseo L7 pasivo.

| Mecanismo | Cómo | Efecto colateral de enforcement | Estado |
|---|---|---|---|
| **CiliumNetworkPolicy con reglas L7** | `toPorts[].rules.http` / `.dns` / `.kafka` | **Sí** — la política también aplica enforcement; todo lo que no coincida es denegado | ✓ La ruta duradera y recomendada |
| Anotación de Pod `policy.cilium.io/proxy-visibility` | `<Egress/53/UDP/DNS>,<Ingress/80/TCP/HTTP>` | No — solo visibilidad | ⚠ Legado; en proceso de retiro en favor de las políticas L7. Verificá el soporte en tu versión menor antes de depender de ella |
| Ingress / Gateway API / Service Mesh | Envoy ya está en el camino | El suyo propio | ✓ Flows L7 gratis para el tráfico norte–sur |

Modelo de costo: redirigir un puerto a Envoy mueve ese tráfico a través del espacio de usuario. Esto es por puerto y por endpoint, no global por Pod como una mesh con sidecar — pero no es gratis. Redirigí los puertos que necesitás ver, no todos.

`enable-l7-proxy` (default `true`) es el interruptor maestro; si está apagado, los tres mecanismos producen silenciosamente nada.

### 2.6 Backends de retención

| Backend | Configuración | Retención | Consulta | Costo | Notas |
|---|---|---|---|---|---|
| Solo ring buffer | default | segundos–minutos | `hubble observe` | RAM | No es una estrategia de retención |
| Exporter de archivo estático | `hubble.export.static` | Hasta la rotación | `jq` en el nodo | Disco | Un solo conjunto de filtros, reiniciar para cambiarlo |
| **Exporter de archivo dinámico** | `hubble.export.dynamic` + ConfigMap | Hasta la rotación | `jq` / shipper | Disco | **Recargable en caliente**, múltiples exporters nombrados con filtros independientes |
| Archivo → Vector/Fluent Bit → Loki/OpenSearch/S3 | §3.6 | La de tu almacén de logs | LogQL / DSL | Ingesta + almacenamiento | La respuesta de producción |
| OpenTelemetry (`hubble-otel`, adaptador de la comunidad) | componente separado | La del backend de trazas | UI de trazas | Pipeline extra | Correlaciona flows con spans; verificá la madurez del proyecto antes de comprometerte |
| Isovalent Enterprise Timescape | comercial | Meses | Hubble UI / CLI sobre el historial | Licencia | Historiador de flows construido para eso; fuera del alcance del CCA pero sabé que existe |

### 2.7 Aprovisionamiento de TLS entre el relay y los agentes

`hubble.tls.auto.method`:

| Método | Mecanismo | Rotación | Usalo cuando |
|---|---|---|---|
| `helm` | Certificados generados en el momento del `helm template` | **Manual** — cada `helm upgrade` con una CA nueva rompe el relay hasta que los agentes reinicien | Solo laboratorio |
| `cronJob` | Un CronJob dentro del clúster regenera antes del vencimiento | Automática | Elección por defecto si no hay PKI |
| `certmanager` | `Issuer` de cert-manager | Automática, auditable | Ya corrés cert-manager |
| deshabilitado (`hubble-disable-tls: true`) | `:4244` en texto plano | — | ✗ Nunca: `:4244` expone todos los flows del clúster |

---

## 3. Manifiestos completos

### 3.1 Values de Helm de producción

```yaml
# cilium-values.yaml — Cilium with a full three-plane observability stack.
# Apply with:
#   helm upgrade --install cilium cilium/cilium \
#     --version 1.16.5 \
#     --namespace kube-system \
#     -f cilium-values.yaml \
#     --wait

k8sServiceHost: api.prod.example.internal
k8sServicePort: 6443

kubeProxyReplacement: true
routingMode: native
ipv4NativeRoutingCIDR: "10.128.0.0/12"
autoDirectNodeRoutes: true
bpf:
  masquerade: true

# L7 proxy is the precondition for every HTTP/DNS/Kafka flow Hubble will ever show.
l7Proxy: true

# --- Datapath event fidelity -------------------------------------------------
# 'medium' keeps per-connection granularity plus TCP flag transitions.
# Drop notifications are NOT affected by aggregation and are always emitted.
monitorAggregation: medium
monitorAggregationInterval: 5s
monitorAggregationFlags: all

# Perf ring buffer between eBPF and the agent. Raise on high-flow-rate clusters;
# 'hubble_lost_events_total{source="perf_event_ring_buffer"}' is the signal that
# this is too small.
bpf:
  masquerade: true
  events:
    drop:
      enabled: true
    policyVerdict:
      enabled: true
    trace:
      enabled: true

operator:
  replicas: 2
  prometheus:
    enabled: true
    port: 9963
    serviceMonitor:
      enabled: true

prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true
    trustCRDsExist: true

envoy:
  enabled: true
  prometheus:
    enabled: true
    port: 9964
    serviceMonitor:
      enabled: true

hubble:
  enabled: true

  # Agent-side gRPC listener consumed by hubble-relay.
  listenAddress: ":4244"

  # ---- Plane 1: the live ring buffer ---------------------------------------
  # MUST be 2^n - 1. 65535 flows is roughly tens of MB of agent RSS per node and
  # buys ~30 s of history on a 2000 flow/s node. See the retention table.
  eventBufferCapacity: 65535
  # 0 = auto-size the decode queue from the number of CPUs.
  eventQueueSize: 0

  # ---- Plane 2: metrics ----------------------------------------------------
  metrics:
    enabled:
      - "dns:query;ignoreAAAA;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload"
      - "drop:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
      - "tcp:labelsContext=source_namespace,destination_namespace"
      - "flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace"
      - "icmp:labelsContext=source_namespace,destination_namespace"
      - "flows-to-world:any-drop;port;syn-only"
      - "httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
      # DELIBERATELY OMITTED — one series per destination port, unbounded under
      # a port scan:
      #   - "port-distribution"
    port: 9965
    # OpenMetrics exposition — required for exemplars (trace-ID linking).
    enableOpenMetrics: true
    serviceMonitor:
      enabled: true
      interval: "30s"
      # Drop the highest-cardinality series at scrape time as a second line of
      # defence, in case someone re-enables a risky metric.
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "hubble_port_distribution_total"
          action: drop
    dashboards:
      enabled: true
      namespace: monitoring
      label: grafana_dashboard
      labelValue: "1"
      annotations:
        grafana_folder: "Cilium"

  # ---- Plane 3: durable flow logs -----------------------------------------
  export:
    fileMaxSizeMb: 100
    fileMaxBackups: 5
    static:
      enabled: false
    dynamic:
      enabled: true
      config:
        configMapName: cilium-flowlog-config
        # We manage the ConfigMap ourselves (see 3.3) so it can be edited and
        # hot-reloaded without a Helm release.
        createConfigMap: false

  # ---- TLS ------------------------------------------------------------------
  tls:
    enabled: true
    auto:
      enabled: true
      method: cronJob
      certValidityDuration: 365
      schedule: "0 3 1 */3 *"

  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 1Gi
    prometheus:
      enabled: true
      port: 9966
      serviceMonitor:
        enabled: true
    podDisruptionBudget:
      enabled: true
      maxUnavailable: 1
    tolerations: []
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            k8s-app: hubble-relay

  ui:
    enabled: true
    rollOutPods: true
    replicas: 1
    # Exposed via Gateway API in 3.7 — never with a bare LoadBalancer.
    ingress:
      enabled: false
    backend:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 512Mi
    frontend:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 256Mi
```

### 3.2 Las claves de `cilium-config` que esto produce — verificá, no asumas

```console
$ kubectl -n kube-system get configmap cilium-config -o yaml | \
    grep -E '^\s+(enable-hubble|hubble-|monitor-aggregation|enable-l7-proxy)'
  enable-hubble: "true"
  enable-l7-proxy: "true"
  hubble-disable-tls: "false"
  hubble-event-buffer-capacity: "65535"
  hubble-event-queue-size: "0"
  hubble-export-file-max-backups: "5"
  hubble-export-file-max-size-mb: "100"
  hubble-flowlogs-config-path: /flowlog-config/flowlogs.yaml
  hubble-listen-address: :4244
  hubble-metrics: dns:query;ignoreAAAA;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload drop:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction tcp:labelsContext=source_namespace,destination_namespace flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace icmp:labelsContext=source_namespace,destination_namespace flows-to-world:any-drop;port;syn-only httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction
  hubble-metrics-server: :9965
  hubble-metrics-server-enable-tls: "false"
  hubble-socket-path: /var/run/cilium/hubble.sock
  monitor-aggregation: medium
  monitor-aggregation-flags: all
  monitor-aggregation-interval: 5s
```

`cilium-config` se lee al arrancar el agente. Editarlo a mano requiere `kubectl -n kube-system rollout restart ds/cilium`. La **única excepción** es la configuración dinámica de flow logs de abajo, que es observada y recargada en caliente.

### 3.3 Exporter dinámico de flow logs — recargable en caliente, filtrado

```yaml
# cilium-flowlog-config.yaml
# Mounted into cilium-agent at /flowlog-config/flowlogs.yaml and WATCHED:
# edits take effect without restarting the DaemonSet.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-flowlog-config
  namespace: kube-system
data:
  flowlogs.yaml: |
    flowLogs:
      # ---------------------------------------------------------------------
      # 1. SECURITY: every non-forwarded verdict, cluster-wide, full fidelity.
      #    This is the stream that answers "who tried what" during an incident.
      # ---------------------------------------------------------------------
      - name: security-denies
        filePath: /var/run/cilium/hubble/security-denies.log
        fieldMask: []
        includeFilters:
          - verdict: ["DROPPED", "ERROR", "AUDIT"]
        excludeFilters: []
        end: "2027-12-31T23:59:59.000Z"

      # ---------------------------------------------------------------------
      # 2. EGRESS EXPOSURE: anything leaving the cluster boundary.
      #    reserved:world as the destination identity.
      # ---------------------------------------------------------------------
      - name: egress-to-world
        filePath: /var/run/cilium/hubble/egress-world.log
        fieldMask:
          - time
          - verdict
          - source.namespace
          - source.pod_name
          - source.workloads
          - destination.identity
          - destination.labels
          - IP.destination
          - l4
          - l7.dns
          - node_name
        includeFilters:
          - destination_label: ["reserved:world"]
        excludeFilters:
          # Node-to-node health probes are not egress.
          - source_label: ["reserved:health"]

      # ---------------------------------------------------------------------
      # 3. PCI SCOPE: full L3/L4/L7 record for one regulated namespace.
      #    Narrow filter, so the volume is bounded and the retention can be long.
      # ---------------------------------------------------------------------
      - name: pci-payments
        filePath: /var/run/cilium/hubble/pci-payments.log
        fieldMask: []
        includeFilters:
          - source_pod: ["payments/"]
          - destination_pod: ["payments/"]
        excludeFilters: []

      # ---------------------------------------------------------------------
      # 4. DNS: every resolution, for exfiltration analysis and NXDOMAIN triage.
      #    Requires an L7 DNS policy (3.5) for the DNS proxy to be in path.
      # ---------------------------------------------------------------------
      - name: dns-audit
        filePath: /var/run/cilium/hubble/dns.log
        fieldMask:
          - time
          - verdict
          - source.namespace
          - source.workloads
          - l7.dns
          - node_name
        includeFilters:
          - event_type:
              - type: 129   # L7 event
        excludeFilters: []
```

> `fieldMask: []` significa "todos los campos" — la línea JSON es grande (~1–2 KB). Las máscaras son la palanca principal sobre el volumen de logs; el exporter `egress-to-world` de arriba emite aproximadamente un cuarto de un registro completo.

### 3.4 ServiceMonitor y reglas de alerta

Si **no** estás usando el `serviceMonitor` del chart (p. ej. un Prometheus Agent fuera del operador), el Service y el ServiceMonitor son:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: hubble-metrics
  namespace: kube-system
  labels:
    k8s-app: hubble
spec:
  clusterIP: None
  type: ClusterIP
  selector:
    k8s-app: cilium
  ports:
    - name: hubble-metrics
      port: 9965
      protocol: TCP
      targetPort: hubble-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hubble
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: hubble
  endpoints:
    - port: hubble-metrics
      interval: 30s
      path: /metrics
      honorLabels: true
      relabelings:
        # Preserve which node produced the sample — indispensable for
        # localising a single-node datapath fault.
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          replacement: ${1}
          action: replace
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "hubble_port_distribution_total"
          action: drop
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hubble-observability
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: hubble.pipeline-health
      rules:
        # The observability pipeline itself is dropping data. If this fires,
        # every other Hubble-derived alert is under-reporting.
        - alert: HubbleLostEvents
          expr: sum by (node, source) (rate(hubble_lost_events_total[5m])) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Hubble is losing events on {{ $labels.node }} (source: {{ $labels.source }})"
            description: >-
              source=perf_event_ring_buffer -> raise the BPF events map size or
              increase monitor-aggregation.
              source=observer_events / hubble_ring_buffer -> the agent decode
              loop is behind; check cilium-agent CPU throttling.
            runbook_url: "https://docs.cilium.io/en/stable/observability/troubleshooting/"

        - alert: HubbleRelayDown
          expr: up{job="hubble-relay"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "hubble-relay is not scrapeable — cluster-wide flow queries are blind"

        - alert: HubblePeerCoverageDegraded
          expr: |
            count(up{job="hubble-metrics"} == 1)
              < 0.95 * count(kube_node_info)
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Fewer than 95% of nodes are exporting Hubble metrics"

    - name: hubble.network-signals
      rules:
        # A policy regression: drops appear where there were none.
        - alert: PolicyDropSpike
          expr: |
            sum by (destination_namespace, destination_workload) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
            ) > 1
            and
            sum by (destination_namespace, destination_workload) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m] offset 1h)
            ) < 0.05
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "New policy denies against {{ $labels.destination_namespace }}/{{ $labels.destination_workload }}"
            description: >-
              hubble observe --namespace {{ $labels.destination_namespace }}
              --verdict DROPPED --last 200

        - alert: DNSNXDomainSurge
          expr: |
            sum by (source_namespace, source_workload) (
              rate(hubble_dns_responses_total{rcode="NXDOMAIN"}[5m])
            ) > 20
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "NXDOMAIN surge from {{ $labels.source_namespace }}/{{ $labels.source_workload }}"
            description: >-
              Either a bad Service name / ndots search-path storm, or DNS-based
              exfiltration. Check: hubble observe --type l7 --namespace
              {{ $labels.source_namespace }} --protocol dns

        - alert: UnexpectedEgressToWorld
          expr: |
            sum by (source_namespace, source_workload) (
              rate(hubble_flows_to_world_total{verdict="FORWARDED"}[10m])
            ) > 0
            unless on (source_namespace)
            (kube_namespace_labels{label_egress_allowed="true"} == 1)
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.source_namespace }}/{{ $labels.source_workload }} is reaching the internet from a namespace not labelled egress-allowed"

        - alert: TCPResetStorm
          expr: sum by (destination_namespace) (rate(hubble_tcp_flags_total{flag="RST"}[5m])) > 50
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "RST storm toward {{ $labels.destination_namespace }} — backlog exhaustion or a half-open policy"
```

### 3.5 CiliumNetworkPolicy que habilita la visibilidad L7 (y aplica enforcement)

```yaml
---
# DNS visibility for a whole namespace. The matchPattern "*" makes the DNS proxy
# observe every query without restricting which names may be resolved, so this is
# visibility-first with enforcement available later by tightening the pattern.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-visibility
  namespace: tenant-a
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
---
# HTTP visibility + enforcement on the api workload.
# Everything not matched by these rules is denied at L7 with 403 — this is the
# trade-off of the CNP route: you get flows, and you get enforcement whether you
# wanted it or not.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-visibility
  namespace: tenant-a
spec:
  description: "L7 HTTP visibility and method/path allowlist for the orders API"
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/v2/orders(/.*)?$"
              - method: "POST"
                path: "/v2/orders$"
              - method: "GET"
                path: "/healthz$"
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "payments.partner.example.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
---
# Cluster-wide baseline that makes DROPPED flows meaningful: without a
# default-deny somewhere, "no drops" tells you nothing, because nothing is
# being evaluated. Roll this out in AUDIT mode first (see 5.7).
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: default-deny-with-baseline
spec:
  description: "Default deny for tenant namespaces, with DNS and node health allowed"
  endpointSelector:
    matchExpressions:
      - key: io.kubernetes.pod.namespace
        operator: In
        values: ["tenant-a", "tenant-b", "payments"]
  ingress:
    - fromEntities:
        - health
        - remote-node
  egress:
    - toEntities:
        - cluster
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

### 3.6 Sacar los flow logs del nodo — DaemonSet completo de Vector

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
data:
  vector.yaml: |
    data_dir: /var/lib/vector

    sources:
      hubble_flows:
        type: file
        include:
          # The exporter rotates with a lumberjack-style suffix; glob the
          # rotated files too so nothing is lost between rotations.
          - /var/run/cilium/hubble/*.log
          - /var/run/cilium/hubble/*.log.*
        read_from: beginning
        fingerprint:
          strategy: checksum
          lines: 1
        max_line_bytes: 262144

    transforms:
      parse:
        type: remap
        inputs: [hubble_flows]
        drop_on_error: true
        reroute_dropped: true
        source: |
          . = object!(parse_json!(.message))
          # Hubble wraps the payload: {"flow":{...},"node_name":"...","time":"..."}
          .flow = object(.flow) ?? {}
          .k8s_node        = string(.node_name) ?? "unknown"
          .verdict         = string(.flow.verdict) ?? "UNKNOWN"
          .src_namespace   = string(.flow.source.namespace) ?? "outside"
          .dst_namespace   = string(.flow.destination.namespace) ?? "outside"
          .src_workload    = string(.flow.source.workloads[0].name) ?? (string(.flow.source.pod_name) ?? "unknown")
          .dst_workload    = string(.flow.destination.workloads[0].name) ?? (string(.flow.destination.pod_name) ?? "unknown")
          .drop_reason     = string(.flow.drop_reason_desc) ?? ""
          .exporter        = split(string!(.file), "/")[-1]
          .timestamp       = parse_timestamp(string!(.flow.time), "%+") ?? now()

      drop_noise:
        type: filter
        inputs: [parse]
        condition: |
          !(.src_namespace == "kube-system" && .dst_namespace == "kube-system" && .verdict == "FORWARDED")

    sinks:
      loki:
        type: loki
        inputs: [drop_noise]
        endpoint: http://loki-gateway.observability.svc.cluster.local
        encoding:
          codec: json
        out_of_order_action: accept
        # Label set is deliberately low-cardinality: everything else stays in
        # the log line and is queried with LogQL JSON filters.
        labels:
          job: hubble
          cluster: prod-eu-west-1
          node: "{{ k8s_node }}"
          verdict: "{{ verdict }}"
          src_namespace: "{{ src_namespace }}"
          dst_namespace: "{{ dst_namespace }}"
          exporter: "{{ exporter }}"
        batch:
          max_bytes: 4194304
          timeout_secs: 5

      parse_failures:
        type: blackhole
        inputs: [parse.dropped]
        print_interval_secs: 300
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: hubble-flowlog-shipper
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: hubble-flowlog-shipper
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hubble-flowlog-shipper
      annotations:
        checksum/config: "REPLACED-BY-CI"
    spec:
      serviceAccountName: hubble-flowlog-shipper
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: vector
          image: timberio/vector:0.42.0-debian
          args: ["--config", "/etc/vector/vector.yaml"]
          env:
            - name: VECTOR_SELF_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: VECTOR_LOG
              value: warn
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false     # must read root-owned files under /var/run/cilium
            runAsUser: 0
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /etc/vector
              readOnly: true
            - name: hubble-flowlogs
              mountPath: /var/run/cilium/hubble
              readOnly: true
            - name: data
              mountPath: /var/lib/vector
      volumes:
        - name: config
          configMap:
            name: hubble-flowlog-shipper
        - name: hubble-flowlogs
          hostPath:
            path: /var/run/cilium/hubble
            type: DirectoryOrCreate
        - name: data
          hostPath:
            path: /var/lib/hubble-flowlog-shipper
            type: DirectoryOrCreate
```

> **Verificá el path del host antes de confiar en esto.** El directorio en el que el agente escribe en el host es el que sea que el DaemonSet monte para la ruta de exportación:
> `kubectl -n kube-system get ds cilium -o json | jq '.spec.template.spec.volumes[] | select(.name|test("hubble"))'`

### 3.7 Exponer Hubble UI de forma segura

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  parentRefs:
    - name: internal-gateway
      namespace: infra
      sectionName: https
  hostnames:
    - "hubble.internal.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove: ["X-Forwarded-Client-Cert"]
      backendRefs:
        - name: hubble-ui
          port: 80
---
# Hubble UI has no authentication of its own and renders every flow in the
# cluster. Restrict reachability to the identity of the authenticating proxy.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: hubble-ui-restrict
  namespace: kube-system
spec:
  endpointSelector:
    matchLabels:
      k8s-app: hubble-ui
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: infra
            app.kubernetes.io/name: oauth2-proxy
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
---
# Prometheus must be able to reach the hubble metrics port on every node.
# Under a default-deny host firewall this is the rule people forget, and the
# symptom is "metrics disappeared after we enabled host policies".
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-prometheus-scrape-hubble
spec:
  nodeSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9965"   # hubble metrics
              protocol: TCP
            - port: "9962"   # cilium-agent metrics
              protocol: TCP
            - port: "9964"   # cilium-envoy metrics
              protocol: TCP
```

---

## 4. CLI: comandos reales y salida real

### 4.1 Puesta en marcha y la escalera de salud

```console
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                 OK
 \__/¯¯\__/    Operator:               OK
 /¯¯\__/¯¯\    Envoy DaemonSet:        OK
 \__/¯¯\__/    Hubble Relay:           OK
    \__/       ClusterMesh:            disabled

DaemonSet              cilium             Desired: 42, Ready: 42/42, Available: 42/42
DaemonSet              cilium-envoy       Desired: 42, Ready: 42/42, Available: 42/42
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay       Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium             Running: 42
                       cilium-envoy       Running: 42
                       cilium-operator    Running: 2
                       hubble-relay       Running: 2
                       hubble-ui          Running: 1
Cluster Pods:          1834/1834 managed by Cilium
Helm chart version:    1.16.5
```

```console
$ cilium hubble port-forward &
[1] 48211
ℹ️  Hubble Relay is available at 127.0.0.1:4245

$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 2,752,470/2,752,470 (100.00%)
Flows/s: 18,431.92
Connected Nodes: 42/42
```

Leé esa salida con atención — son tres hechos independientes:

* **`Connected Nodes: 42/42`** — el relay tiene una sesión gRPC viva con todos los agentes. `41/42` significa que un nodo es un punto ciego y que toda consulta sub-reporta silenciosamente.
* **`Current/Max Flows`** — la *suma* de los ring buffers de todos los nodos (42 × 65 535 ≈ 2,75 M). `100.00%` significa que todos los buffers están llenos, lo cual es el régimen estable normal, no un error.
* **`Flows/s: 18,431`** entre 42 nodos ≈ 440 flows/s por nodo → alrededor de **150 segundos** de historial. Esa es tu ventana forense real.

```console
$ hubble list nodes
NAME                                     STATUS      AGE      FLOWS/S   CURRENT/MAX-FLOWS
ip-10-128-14-7.eu-west-1.compute.internal  Connected  38h12m   612.44    65535/65535 (100.00%)
ip-10-128-19-3.eu-west-1.compute.internal  Connected  38h12m   418.02    65535/65535 (100.00%)
ip-10-128-22-91.eu-west-1.compute.internal Unavailable 0s      0.00      0/0 (0.00%)
...
```

`Unavailable` en un solo nodo es la señal temprana de mayor valor de todo este dominio: los flows, descartes y eventos L7 de ese nodo simplemente no están en ningún resultado de consulta.

### 4.2 `hubble observe` — la gramática de consulta

```console
$ hubble observe --namespace tenant-a --last 5
Sep  1 12:11:01.982: tenant-a/frontend-6d8f9c7b5-jz4kp:41556 (ID:14201) -> kube-system/coredns-7db6d8ff4d-lq2mn:53 (ID:16785) dns-request proxy FORWARDED (DNS Query api.tenant-a.svc.cluster.local. A)
Sep  1 12:11:01.984: kube-system/coredns-7db6d8ff4d-lq2mn:53 (ID:16785) -> tenant-a/frontend-6d8f9c7b5-jz4kp:41556 (ID:14201) dns-response proxy FORWARDED (DNS Answer "10.96.14.9" TTL: 30 (Proxy api.tenant-a.svc.cluster.local. A))
Sep  1 12:11:02.101: tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) -> tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:11:02.114: tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) -> tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) http-request FORWARDED (HTTP/1.1 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders)
Sep  1 12:11:02.147: tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) -> tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) http-response FORWARDED (HTTP/1.1 200 33ms (GET http://api.tenant-a.svc.cluster.local:8080/v2/orders))
```

Anatomía de una línea compacta:

```
Sep  1 12:11:02.114: tenant-a/frontend-...:48122 (ID:14201) -> tenant-a/api-...:8080 (ID:14208) http-request FORWARDED (HTTP/1.1 GET ...)
└── timestamp ──┘   └────── source ─────┘ └identity┘  │  └──── destination ────┘└identity┘ └ type ─┘ └verdict┘ └──── summary ────┘
                                                      └─ arrow: -> one direction observed,
                                                                 <> both/unknown direction
```

La superficie de filtrado que importa en la práctica:

```console
# Everything denied toward a namespace, right now, following.
$ hubble observe --to-namespace payments --verdict DROPPED --follow

# Both directions of a specific workload pair.
$ hubble observe --from-pod tenant-a/checkout --to-pod tenant-b/postgres --last 100

# By identity, when the Pod is already gone.
$ hubble observe --identity 14213 --last 200

# By label selector — survives Pod churn.
$ hubble observe --label app=checkout --to-label app=postgres

# Everything leaving the cluster.
$ hubble observe --to-identity 2 --verdict FORWARDED --last 50

# Everything to one external name (requires DNS proxy in path).
$ hubble observe --to-fqdn "*.amazonaws.com" --last 50

# Negation: all drops that are NOT policy denies.
$ hubble observe --verdict DROPPED --not --drop-reason POLICY_DENIED

# Time windows against the ring buffer.
$ hubble observe --since 5m --until 1m --namespace tenant-a
$ hubble observe --first 20 --namespace tenant-a     # oldest in the buffer
$ hubble observe --all --namespace tenant-a          # drain the whole buffer

# HTTP-specific.
$ hubble observe --protocol http --http-status 5+ --last 50
$ hubble observe --http-method POST --http-path "/v2/orders"

# Node scoping.
$ hubble observe --node-name ip-10-128-14-7.eu-west-1.compute.internal --verdict DROPPED
```

Un flow denegado, y el evento de policy-verdict que lo explica:

```console
$ hubble observe --from-pod tenant-a/checkout --verdict DROPPED --last 4
Sep  1 12:14:55.301: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:55.301: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:56.318: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:58.334: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
```

Tres hechos extraídos en una sola pantalla:

* `policy-verdict:none INGRESS DENIED` — **`INGRESS`** es la palabra decisiva. La denegación está en la política de ingress de `postgres`, no en el egress de `checkout`. Estás editando la CNP equivocada si vas a `tenant-a`.
* `:none` es el descriptor de la regla que coincidió: no coincidió ninguna regla (a diferencia de `L3-Only`, `L3-L4`, `L4-Only`).
* El espaciado de 1 s / 2 s con `TCP Flags: SYN` es la retransmisión del SYN del cliente — confirmando que lo que falla es el establecimiento de la conexión, no un reset a mitad del stream.

### 4.3 Puntos de observación — leer la posición en el datapath

Los eventos `--type trace` llevan un *punto de observación de traza* que te dice exactamente qué tan lejos viajó el paquete antes del evento.

```console
$ hubble observe --type trace --from-pod tenant-a/frontend --to-pod tenant-b/api --last 12 -o compact
Sep  1 12:20:10.001: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) from-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.001: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) to-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.002: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) from-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.002: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) to-endpoint FORWARDED (TCP Flags: SYN)
```

| Punto de observación | Posición | Apareció → concluí | Falta → concluí |
|---|---|---|---|
| `from-endpoint` | tc egress del veth del Pod origen | El paquete salió del Pod | La aplicación nunca lo envió — andá a la app, no a la red |
| `to-proxy` | Redirigido hacia Envoy/proxy DNS | La redirección L7 está activa | No hay política/redirección L7 en este puerto |
| `from-proxy` | Saliendo del proxy | El proxy lo permitió | El proxy denegó en L7 — buscá el evento `http-request … DROPPED` |
| `to-overlay` | Entrando al túnel VXLAN/Geneve | Modo encap, el paquete va hacia otro nodo | Native routing, o el destino es local al nodo |
| `from-overlay` | Desencapsulado en el nodo destino | Cruzó la red | **Problema de underlay** — MTU, security group, puerto de túnel 8472 bloqueado |
| `to-stack` / `from-stack` | Entregado hacia/desde la pila del kernel del host | El enrutamiento del host está involucrado | — |
| `to-network` / `from-network` | NIC física | Saliendo/entrando al nodo | — |
| `to-endpoint` | tc ingress del veth destino | Fue entregado | No se entregó a ningún lado — política, o el endpoint no está listo |

**El método de diagnóstico que esta tabla codifica:** listá los puntos de observación que alcanzó el paquete, encontrá el último, y la falla está entre ese y el próximo esperado. `from-endpoint` + `to-overlay` sin `from-overlay` en el par es un problema de underlay/MTU — no un problema de política de Cilium — y lo demostraste en un solo comando en lugar de con dos horas de discusión con el equipo de red.

### 4.4 Salida estructurada y recetas de `jq`

```console
$ hubble observe --verdict DROPPED --last 1 -o json | jq .
{
  "flow": {
    "time": "2026-09-01T12:14:55.301418Z",
    "verdict": "DROPPED",
    "drop_reason": 133,
    "ethernet": {
      "source": "b6:9a:1f:0c:44:e1",
      "destination": "12:3a:77:0e:b2:04"
    },
    "IP": {
      "source": "10.128.14.211",
      "destination": "10.128.19.87",
      "ipVersion": "IPv4"
    },
    "l4": {
      "TCP": {
        "source_port": 52344,
        "destination_port": 5432,
        "flags": { "SYN": true }
      }
    },
    "source": {
      "ID": 1842,
      "identity": 14213,
      "namespace": "tenant-a",
      "labels": [
        "k8s:app=checkout",
        "k8s:io.cilium.k8s.namespace.labels.tenant=a",
        "k8s:io.kubernetes.pod.namespace=tenant-a"
      ],
      "pod_name": "checkout-7d9c5f8b4-2wq9x",
      "workloads": [{ "name": "checkout", "kind": "Deployment" }]
    },
    "destination": {
      "identity": 9917,
      "namespace": "tenant-b",
      "labels": [
        "k8s:app=postgres",
        "k8s:io.kubernetes.pod.namespace=tenant-b"
      ],
      "pod_name": "postgres-0",
      "workloads": [{ "name": "postgres", "kind": "StatefulSet" }]
    },
    "Type": "L3_L4",
    "node_name": "ip-10-128-19-3.eu-west-1.compute.internal",
    "event_type": { "type": 1, "sub_type": 133 },
    "traffic_direction": "INGRESS",
    "drop_reason_desc": "POLICY_DENIED",
    "Summary": "TCP Flags: SYN"
  },
  "node_name": "ip-10-128-19-3.eu-west-1.compute.internal",
  "time": "2026-09-01T12:14:55.301418Z"
}
```

```console
# Top denied workload pairs in the current buffer — the single most useful
# one-liner during a policy rollout.
$ hubble observe --verdict DROPPED --all -o json 2>/dev/null | \
    jq -r '.flow | "\(.source.namespace)/\(.source.workloads[0].name // .source.pod_name) -> \(.destination.namespace)/\(.destination.workloads[0].name // .destination.pod_name) [\(.l4.TCP.destination_port // .l4.UDP.destination_port // "-")] \(.drop_reason_desc)"' | \
    sort | uniq -c | sort -rn | head -15
    412 tenant-a/checkout -> tenant-b/postgres [5432] POLICY_DENIED
     87 tenant-a/worker -> outside/ [443] POLICY_DENIED
     31 payments/ledger -> kube-system/coredns [53] POLICY_DENIED
      9 tenant-c/batch -> tenant-c/redis [6379] POLICY_DENIED

# Which node produced them (localises a single-node datapath fault).
$ hubble observe --verdict DROPPED --all -o json 2>/dev/null | \
    jq -r '.node_name' | sort | uniq -c | sort -rn | head
    397 ip-10-128-19-3.eu-west-1.compute.internal
    142 ip-10-128-14-7.eu-west-1.compute.internal

# Slowest HTTP responses observed by the proxy.
$ hubble observe --protocol http --all -o json 2>/dev/null | \
    jq -r 'select(.flow.l7.http.code != null) |
           "\(.flow.l7.latency_ns/1000000 | floor)ms \(.flow.l7.http.code) \(.flow.l7.http.method) \(.flow.l7.http.url)"' | \
    sort -rn | head -10
1842ms 200 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders?expand=lines
 913ms 500 POST http://api.tenant-a.svc.cluster.local:8080/v2/orders
 402ms 200 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders
```

**Construir filtros de exporter sin adivinar.** Componé el filtro interactivamente con la CLI, después imprimí la representación de red y pegala en el ConfigMap de §3.3:

```console
$ hubble observe --namespace payments --verdict DROPPED --protocol tcp --print-raw-filters
allowlist:
    - '{"source_pod":["payments/"],"verdict":["DROPPED"],"protocol":["tcp"]}'
    - '{"destination_pod":["payments/"],"verdict":["DROPPED"],"protocol":["tcp"]}'

# And replay a filter set to confirm it matches what you expect:
$ hubble observe --allowlist '{"source_pod":["payments/"],"verdict":["DROPPED"]}' --last 5
```

### 4.5 Cuando Hubble no alcanza — el datapath crudo

`cilium monitor` lee el perf ring buffer directamente, **sin** la agregación que aplica Hubble y sin una capa de enriquecimiento que pueda estar mintiéndote.

```console
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --related-to 1842
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8e21ac4b to endpoint 1842, ifindex 27, file bpf_lxc.c:2114, , identity 14213->9917: 10.128.14.211:52344 -> 10.128.19.87:5432 tcp SYN
xx drop (Policy denied) flow 0x1c7730fa to endpoint 1842, ifindex 27, file bpf_lxc.c:2114, , identity 14213->9917: 10.128.14.211:52344 -> 10.128.19.87:5432 tcp SYN
```

`file bpf_lxc.c:2114` es la ubicación exacta en el código fuente del datapath que descartó el paquete. Hubble nunca te muestra esto; `cilium monitor` sí, y es decisivo cuando sospechás que la razón del descarte está mal etiquetada.

```console
# What identity does this Pod actually have?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg endpoint list | head -8
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                    IPv4            STATUS
           ENFORCEMENT        ENFORCEMENT
1842       Enabled            Enabled           14213      k8s:app=checkout                               10.128.14.211   ready
                                                           k8s:io.kubernetes.pod.namespace=tenant-a
2011       Disabled           Disabled          4          reserved:health                                10.128.14.9     ready
3094       Enabled            Enabled           9917       k8s:app=postgres                               10.128.19.87    ready

# Which identity owns an IP, cluster-wide (this is the ipcache Hubble enriches from)?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg ip list | grep 10.128.19.87
10.128.19.87/32   9917

# What is actually programmed in the policy map for that endpoint?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg bpf policy get 3094
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                 PORT/PROTO   PROXY PORT   BYTES     PACKETS
Allow    Ingress     14201      k8s:io.cilium.k8s.policy.name=api-ingress   5432/TCP     NONE         184220    1402
Allow    Egress      0          reserved:unknown                            ANY          NONE         92110     801

# Cilium's own drop counters, by reason — cross-check against hubble_drop_total.
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg metrics list | grep -E 'drop_count|forward_count'
cilium_drop_count_total                 reason="Policy denied" direction="INGRESS"    412
cilium_drop_count_total                 reason="Stale or unroutable IP" direction="EGRESS"   3
cilium_forward_count_total              direction="INGRESS"                        18420114
cilium_forward_count_total              direction="EGRESS"                         17993201
```

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La escalera de salud — recorrela de arriba hacia abajo, pará en la primera falla

```console
# 1. Is the control plane healthy at all?
$ cilium status --wait

# 2. Is Hubble enabled on every agent, with the config you think?
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-hubble}{"\n"}{.data.hubble-listen-address}{"\n"}{.data.hubble-event-buffer-capacity}{"\n"}'
true
:4244
65535

# 3. Does relay see every node?
$ hubble status | grep 'Connected Nodes'
Connected Nodes: 42/42

# 4. Is any node losing events?
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s localhost:9965/metrics | grep -E '^hubble_lost_events_total'
hubble_lost_events_total{source="perf_event_ring_buffer"} 0
hubble_lost_events_total{source="observer_events"} 0

# 5. Is Prometheus actually scraping it?
$ kubectl -n monitoring exec -it sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=count(up{job="hubble-metrics"}==1)' | jq -r '.data.result[0].value[1]'
42

# 6. Are flows actually being written to disk?
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- ls -la /var/run/cilium/hubble/
total 41284
drwxr-xr-x 2 root root      4096 Sep  1 03:00 .
drwxr-xr-x 4 root root       120 Aug 30 22:14 ..
-rw-r--r-- 1 root root  11284471 Sep  1 12:22 dns.log
-rw-r--r-- 1 root root   2093118 Sep  1 12:22 egress-world.log
-rw-r--r-- 1 root root  28914003 Sep  1 12:22 pci-payments.log
-rw-r--r-- 1 root root    884201 Sep  1 12:22 security-denies.log

# 7. Is the shipper keeping up?
$ kubectl -n observability logs ds/hubble-flowlog-shipper --tail=5 | grep -i 'error\|lag' || echo "clean"
clean

# 8. End-to-end: does a synthetic deny appear in Loki within the SLO?
$ kubectl -n tenant-a run probe --rm -it --restart=Never --image=busybox:1.36 -- \
    timeout 3 nc -zv 10.128.19.87 5432 ; echo "---" ; sleep 20 ; \
  logcli query --limit 5 '{job="hubble",verdict="DROPPED",src_namespace="tenant-a"}'
```

### 5.2 Catálogo de fallas

| Síntoma | Causa probable | Confirmalo con | Solución |
|---|---|---|---|
| `hubble observe` no devuelve absolutamente nada | Hubble deshabilitado | `kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-hubble}'` | `hubble.enabled=true`, reiniciar el DaemonSet |
| `hubble status` → `connection refused` en 4245 | Sin port-forward, o el relay caído | `kubectl -n kube-system get deploy hubble-relay` | `cilium hubble port-forward` |
| Relay en `CrashLoopBackOff`, logs con `x509: certificate signed by unknown authority` | Agentes y relay tienen certificados de distintas generaciones de CA (clásico después de un `helm upgrade` con `tls.auto.method=helm`) | `kubectl -n kube-system logs deploy/hubble-relay` | Borrar los Secrets `hubble-*-certs`, volver a correr el CronJob de certificados, reiniciar el relay **y** el DaemonSet del agente. Pasarse a `cronJob` o `certmanager` |
| `Connected Nodes: 41/42` | Un agente no sirve en 4244 | `hubble list nodes \| grep -v Connected` | Revisar los logs y la readiness de ese agente; revisar el firewall del host en 4244 |
| Flows visibles pero `ID:0` / sin nombres de pod | Hueco de ipcache/identidad en el nodo productor, o tráfico genuinamente externo | `cilium-dbg ip list \| grep <ip>` | Si la IP es de un Pod del clúster y está ausente del ipcache: reiniciar ese agente; revisar el GC de identidades del operador |
| Cero flows L7/HTTP | Sin redirección al proxy | `cilium-dbg endpoint get <id> -o json \| jq '.[0].status.policy.realized.l4'` buscando un `proxy-port` | Agregar una CNP con reglas L7 (§3.5); verificar `enable-l7-proxy: "true"` |
| Cero flows DNS | Sin regla L7 de DNS | `hubble observe --protocol dns --last 5` | Agregar la regla de egress DNS con `matchPattern: "*"` |
| `hubble_lost_events_total{source="perf_event_ring_buffer"}` en aumento | Desborde del perf buffer eBPF→agente | la métrica + `cilium monitor` imprimiendo "lost N events" | Aumentar el tamaño del mapa de eventos BPF; subir `monitorAggregation` a `medium`/`maximum`; investigar el pico de tráfico |
| `hubble_lost_events_total{source="observer_events"}` en aumento | El bucle de decodificación/enriquecimiento del agente está atrasado | throttling de CPU del agente: `container_cpu_cfs_throttled_seconds_total{container="cilium-agent"}` | Subir el límite de CPU del agente; reducir las métricas habilitadas |
| `hubble observe --since 10m` devuelve solo 30 s | Ring buffer más chico que la ventana | `hubble status` → Flows/s vs Current/Max | Subir `eventBufferCapacity`; **y** habilitar la exportación — el buffer no es la respuesta |
| Prometheus OOMKilled después de habilitar las métricas de Hubble | Cardinalidad (`ip`/`pod`/`port-distribution`) | `topk(10, count by (__name__)({__name__=~"hubble_.*"}))` | Cambiar los contextos a `workload-name`/`namespace`; eliminar `port-distribution` |
| Las métricas de Hubble desaparecieron tras habilitar el firewall del host | Puerto de scrape bloqueado por una política de host | `hubble observe --to-identity 1 --to-port 9965 --verdict DROPPED` | Aplicar la CCNP de §3.7 |
| El archivo de flow log existe pero nunca crece | Los filtros no coinciden con nada, o nombre de exporter equivocado | `kubectl -n kube-system logs ds/cilium -c cilium-agent \| grep -i flowlog` | Reconstruir los filtros con `hubble observe --print-raw-filters` |
| El disco del nodo se llena bajo `/var/run/cilium/hubble` | `fileMaxSizeMb × fileMaxBackups × exporters` excede el presupuesto, o el shipper está muerto | `du -sh /var/run/cilium/hubble` | Ajustar `fieldMask`/filtros; arreglar el shipper; bajar `fileMaxBackups` |
| Aparecen descartes en `cilium_drop_count_total` pero no en Hubble | El descarte ocurrió en XDP, antes de la notificación de la capa tc | comparar métricas del agente contra `hubble_drop_total` | Esperado para descartes en etapa XDP; investigar con `cilium-dbg` y los contadores de XDP |

### 5.3 Razones de descarte que tenés que saber leer

`drop_reason_desc` en el JSON, `(reason)` en `cilium monitor`, la label `reason` en `hubble_drop_total`.

| Código | `drop_reason_desc` | Qué significa realmente | Primer movimiento |
|---|---|---|---|
| 133 | `POLICY_DENIED` | Ninguna regla de política lo permitió | Leé `traffic_direction` en el evento de policy-verdict — te dice qué lado corregir |
| 181 | `POLICY_DENY` | Coincidió una regla de denegación **explícita** (deny le gana a allow, siempre) | Buscá la CCNP/CNP con `ingressDeny`/`egressDeny` |
| 189 | `POLICY_AUTH_REQUIRED` | Se requiere autenticación mutua, handshake incompleto | Revisá la integración SPIFFE/mutual-auth |
| 151 | `UNROUTABLE` / IP obsoleta | La IP de destino no está en el ipcache — endpoint borrado, o identidad no propagada | `cilium-dbg ip list`; revisar la sincronización de kvstore/CRD y clustermesh |
| 158 | `NO_SERVICE_TRANSLATION` | VIP de servicio sin backend en el mapa de LB | `cilium-dbg service list`; revisar Endpoints/EndpointSlice |
| 160 | `NO_TUNNEL_ENDPOINT` | Modo túnel, sin entrada de túnel para el nodo destino | `cilium-dbg bpf tunnel list`; el nodo no se unió |
| 171 | `INVALID_IDENTITY` | La identidad en el paquete es desconocida localmente | Latencia en la asignación de identidades; salud del kvstore/operador |
| 190 / 191 | `CT_NO_MAP_FOUND` / `SNAT_NO_MAP_FOUND` | Mapa de conntrack o de NAT agotado | `cilium_bpf_map_pressure`; subir `bpf-ct-global-*-max` / el tamaño del mapa de NAT |
| 136 | `FRAG_NEEDED` | Paquete demasiado grande, con DF activado | **Desajuste de MTU** — el clásico bug de overhead del túnel |
| 177 | `NOT_IN_SRC_RANGE` | El `loadBalancerSourceRanges` del Service rechazó al cliente | Ampliar el rango, o está funcionando tal como se configuró |
| 174 | `IS_CLUSTER_IP` | Tráfico hacia una ClusterIP llegó donde no puede ser traducido | Configuración de reemplazo de kube-proxy / socket-LB |

`cilium_bpf_map_pressure` merece una alerta permanente propia: un mapa de conntrack lleno produce descartes que se ven exactamente como inestabilidad intermitente de la aplicación.

### 5.4 Runbook — "el servicio A no puede alcanzar al servicio B"

```console
# 0. Establish the identities. Everything downstream is keyed on these.
$ kubectl -n tenant-a get pod -l app=checkout -o jsonpath='{.items[0].status.podIP}{"\n"}'
10.128.14.211
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | grep checkout
1842  Enabled  Enabled  14213  k8s:app=checkout  10.128.14.211  ready

# 1. Is anything at all observed between them? Label filters survive Pod churn.
$ hubble observe --label app=checkout --to-label app=postgres --last 20
# → nothing at all: the client never sent a packet. Go to the application,
#   DNS resolution, or the Service definition. Stop here.
# → flows present: continue.

# 2. Is it a policy verdict? This event names the direction authoritatively.
$ hubble observe --label app=checkout --to-label app=postgres --type policy-verdict --last 5
Sep  1 12:14:55.301: tenant-a/checkout-...:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
#   INGRESS  -> fix postgres's ingress rules, in tenant-b.
#   EGRESS   -> fix checkout's egress rules, in tenant-a.

# 3. Which policy is (not) programmed? Verify realised state, not the YAML.
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf policy get 3094 | grep 5432
# No row for identity 14213 on 5432/TCP -> the allow rule is genuinely absent.

# 4. Confirm the selector actually selects. The #1 cause is a label typo.
$ kubectl -n tenant-b get cnp -o yaml | yq '.items[].spec.ingress[].fromEndpoints'
- matchLabels:
    app: checkout          # <-- missing io.kubernetes.pod.namespace: tenant-a
#   In a CNP, an unqualified matchLabels is namespace-scoped: this selects
#   'app=checkout' in tenant-b, which does not exist. Cross-namespace requires
#   the namespace label explicitly.

# 5. If it is NOT a policy drop, walk the observation points (§4.3).
$ hubble observe --label app=checkout --to-label app=postgres --type trace --last 20 -o compact
#   from-endpoint present, to-overlay present, from-overlay ABSENT on the peer
#   -> underlay: MTU, security group, or UDP 8472 blocked. Not a Cilium policy issue.

# 6. Confirm the fix, with evidence.
$ hubble observe --label app=checkout --to-label app=postgres --last 5
Sep  1 12:31:02.883: tenant-a/checkout-...:52360 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
Sep  1 12:31:02.883: tenant-a/checkout-...:52360 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) to-endpoint FORWARDED (TCP Flags: SYN)
```

### 5.5 Runbook — el pipeline de observabilidad está perdiendo datos

Se disparó `HubbleLostEvents`. La label `source` decide todo.

```console
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s localhost:9965/metrics | grep hubble_lost_events_total
hubble_lost_events_total{source="perf_event_ring_buffer"} 184201
hubble_lost_events_total{source="observer_events"} 0
```

**`perf_event_ring_buffer` > 0** — el kernel produjo eventos más rápido de lo que el agente los leyó; la pérdida está en el salto eBPF→espacio de usuario.
1. Confirmá que es un evento de tráfico, no una regresión: `rate(hubble_flows_processed_total[5m])` en ese nodo contra el resto de la flota.
2. Si es un escaneo o un pico legítimo: subí `monitorAggregation` a `maximum` **temporalmente**, y aumentá el tamaño del mapa de eventos BPF.
3. Verificá que el agente no esté hambriento de CPU: `rate(container_cpu_cfs_throttled_seconds_total{container="cilium-agent"}[5m])`.

**`observer_events` > 0** — el agente leyó los eventos pero su bucle de decodificación/enriquecimiento/fan-out está atrasado.
1. Casi siempre son los límites de CPU o demasiadas métricas habilitadas con contextos caros.
2. Subí el límite de CPU de `cilium-agent`; eliminá los contextos de métricas más caros.
3. Subí `hubble-event-queue-size` por encima de `0` solo después de descartar la CPU.

En cualquiera de los dos casos, registrá el hueco. Un período con `lost_events > 0` es un período en el que "no se observaron descartes" **no** es evidencia de que no hubo descartes — y una revisión de seguridad que lo trate como evidencia está sacando una conclusión falsa.

### 5.6 Runbook — Prometheus se cayó después de habilitar las métricas de Hubble

```promql
# Which Hubble metric is producing the series?
topk(10, count by (__name__) ({__name__=~"hubble_.*"}))

# Which label is unbounded within the worst offender?
count(count by (destination_ip) (hubble_flows_processed_total))
count(count by (destination_workload) (hubble_flows_processed_total))
```

Si `destination_ip` devuelve decenas de miles y `destination_workload` devuelve cientos, ya tenés tu respuesta. La solución está en `hubble.metrics.enabled` — reemplazá `sourceContext=ip`/`pod` por `workload-name|reserved-identity`, borrá `port-distribution`, y reiniciá el DaemonSet. Mantené el drop de `metricRelabelings` en el ServiceMonitor (§3.4) como guarda permanente, para que una futura edición del archivo de values no pueda repetir el incidente antes de que alguien la revise.

El `|` en `sourceContext=workload-name|reserved-identity` es una cadena de respaldo: usa el nombre del workload cuando lo hay, y cae a la identidad reservada (`world`, `host`, `remote-node`) cuando no. Sin el respaldo, el tráfico externo colapsa en una label vacía y perdés la capacidad de distinguir el egress del tráfico intra-clúster.

### 5.7 Modo de auditoría de políticas — observá antes de aplicar enforcement

Nunca despliegues un default-deny en un clúster vivo y leas los descartes después. Poné los endpoints en modo auditoría, recolectá lo que *habría sido* denegado, escribí las reglas de permiso, y recién después aplicá enforcement.

```console
# Turn on audit for one endpoint (per-endpoint, node-local, not persisted).
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg endpoint config 3094 PolicyAuditMode=Enabled
Endpoint 3094 configuration updated successfully

# Verdicts now surface as AUDIT instead of DROPPED — traffic still flows.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict AUDIT --last 5
Sep  1 13:02:11.774: tenant-a/checkout-...:53102 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
Sep  1 13:02:14.019: ops/backup-runner-...:41880 (ID:15501) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)

# Let it run a full business cycle — including the nightly batch window, which
# is what everybody forgets — then enumerate the required allows.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict AUDIT --all -o json 2>/dev/null | \
    jq -r '.flow | "\(.source.namespace):\(.source.labels[] | select(startswith("k8s:app=")) ) -> \(.l4.TCP.destination_port // .l4.UDP.destination_port)"' | \
    sort -u
ops:k8s:app=backup-runner -> 5432
tenant-a:k8s:app=checkout -> 5432
tenant-a:k8s:app=reporting -> 5432

# Write the CNP from that list, apply it, and only then:
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg endpoint config 3094 PolicyAuditMode=Disabled

# Enforcement is live. Verify no legitimate traffic turned into a DROP.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict DROPPED --last 20
No flows returned.
```

`PolicyAuditMode` es por endpoint y local al nodo — no sobrevive a un reagendamiento del Pod, y hay que activarlo en cada nodo que hospede una réplica. Esa propiedad lo convierte en una herramienta de investigación deliberada y acotada en el tiempo, no en un estado de configuración para dejar encendido.

### 5.8 Cluster Mesh — la frontera de alcance

`hubble-relay` en el Cilium upstream se conecta al Service `hubble-peer` de **su propio clúster**. En un Cluster Mesh, un flow que sale del clúster A hacia el clúster B es observado dos veces — una por el agente de A (egress) y otra por el agente de B (ingress) — y ningún relay tiene las dos mitades.

```console
$ hubble observe --to-identity 9917 --last 3
Sep  1 13:20:44.118: tenant-a/checkout-...:54210 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) to-network FORWARDED (TCP Flags: SYN)
# Flow ends at to-network. The other half lives in cluster-b's relay.
```

Dos respuestas viables, en orden de preferencia:

1. **Correlacionar en el almacén de logs.** Ambos clústeres exportan flows al mismo Loki/OpenSearch con una label `cluster`. La reconstrucción entre clústeres se convierte en una consulta, y funciona después del hecho — que es lo que necesitan los post-mortems. Este es el diseño de §3.6.
2. **Consultar el relay de cada clúster.** Mantené un contexto de la CLI `hubble` por clúster (`hubble config` / `--server`) y corré la consulta dos veces. Está bien para depuración en vivo, inútil para el historial.

La consistencia de identidades es un prerrequisito en cualquiera de los dos casos: para que un flow en el clúster B nombre un workload del clúster A, la asignación de identidades tiene que ser compartida o equivalente en labels a lo largo de la mesh. Una asignación de identidades desajustada se manifiesta exactamente como orígenes `ID:0` / sin nombre en los flows entre clústeres.

---

## Referencias

- CNCF Cilium Certified Associate (CCA) curriculum — https://github.com/cncf/curriculum y https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- Documentación de Cilium — Network Observability with Hubble — https://docs.cilium.io/en/stable/observability/
- Documentación de Cilium — Hubble internals and architecture — https://docs.cilium.io/en/stable/overview/component-overview/
- Documentación de Cilium — Running Prometheus & Grafana / Hubble metrics reference — https://docs.cilium.io/en/stable/observability/metrics/
- Documentación de Cilium — Hubble Exporter (static and dynamic flow logs) — https://docs.cilium.io/en/stable/observability/hubble-exporter/
- Documentación de Cilium — Configuring Hubble Relay and TLS — https://docs.cilium.io/en/stable/observability/hubble/configuration/
- Documentación de Cilium — Layer 7 Protocol Visibility — https://docs.cilium.io/en/stable/observability/visibility/
- Documentación de Cilium — Network Policy (CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy) — https://docs.cilium.io/en/stable/security/policy/
- Documentación de Cilium — Policy Enforcement Modes and Audit Mode — https://docs.cilium.io/en/stable/security/policy/intro/
- Documentación de Cilium — Identity-Based security and reserved identities — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Documentación de Cilium — Troubleshooting (`cilium monitor`, `cilium-dbg`, drop reasons) — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Documentación de Cilium — Helm reference (`hubble.*` values) — https://docs.cilium.io/en/stable/helm-reference/
- Documentación de Cilium — Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/
- Código fuente y releases de la CLI de Hubble — https://github.com/cilium/hubble
- Código fuente de Hubble UI — https://github.com/cilium/hubble-ui
- Definiciones de razones de descarte del datapath eBPF de Cilium (`bpf/lib/common.h`) — https://github.com/cilium/cilium/blob/main/bpf/lib/common.h
- API de flows de Hubble (definiciones protobuf para la salida JSON) — https://github.com/cilium/cilium/tree/main/api/v1/flow
- Tetragon (observabilidad de runtime/procesos, adyacente a Hubble) — https://tetragon.io/docs/
- API de ServiceMonitor y PrometheusRule del Prometheus Operator — https://prometheus-operator.dev/docs/api-reference/api/
- Fuente `file` y sink `loki` de Vector — https://vector.dev/docs/reference/configuration/sources/file/ y https://vector.dev/docs/reference/configuration/sinks/loki/