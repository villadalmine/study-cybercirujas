# Ejercicios guiados — Dominio 4.1: Observabilidad con Cilium

> **Peso en el examen: 20%.** Es el segundo dominio más pesado del CCA. Casi toda pregunta de este dominio se reduce a una de tres habilidades: *leer correctamente una línea de flujo de Hubble*, *elegir el filtro adecuado para aislar un problema*, y *saber qué capa del stack (Hubble ⇄ agente ⇄ datapath eBPF) tiene realmente la respuesta que necesitás.*
>
> Trabajalos en orden. Cada bloque es un conjunto de pasos numerados que ejecutás, seguido de preguntas de comprensión. No leas las respuestas hasta haber escrito las tuyas — el examen premia recordar la semántica exacta de veredicto/tipo, y eso solo se construye prediciendo la salida antes de verla.

---

## Prerrequisitos del laboratorio

| Requisito | Versión usada en este laboratorio | Nota |
|---|---|---|
| `kind` | ≥ 0.24 | sirve cualquier host de Kubernetes-in-Docker |
| `kubectl` | minor coincidente con el clúster | |
| `helm` | ≥ 3.13 | acá Cilium se instala vía Helm para que todos los valores queden explícitos |
| CLI `cilium` | ≥ 0.16 | [github.com/cilium/cilium-cli](https://github.com/cilium/cilium-cli) |
| CLI `hubble` | ≥ 1.16 | [github.com/cilium/hubble](https://github.com/cilium/hubble) |
| Cilium | 1.16.x | fijá `CILIUM_VERSION` abajo; verificá contra la release que estés estudiando |

```bash
export CILIUM_VERSION=1.16.5
export KUBECONFIG=$HOME/.kube/cca-lab.config
```

Todo lo de abajo corre en una laptop. No hace falta ninguna cuenta en la nube.

---

## Ejercicio 0 — Construir un clúster observable desde cero

El punto de este ejercicio es que **la observabilidad es una decisión de tiempo de instalación**. Hubble no es un sidecar que se atornilla después; es un consumidor de un ring buffer de eventos dentro del agente de Cilium, y si el agente arrancó sin él, no existe ningún histórico que recuperar.

### Pasos

1. Escribí la configuración de kind. Cilium reemplaza tanto al CNI como (acá) a kube-proxy, así que hay que deshabilitar ambos valores por defecto:

   ```yaml
   # kind-cca.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: cca-lab
   networking:
     disableDefaultCNI: true
     kubeProxyMode: none
     podSubnet: "10.244.0.0/16"
     serviceSubnet: "10.96.0.0/12"
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   ```

2. Creá el clúster:

   ```bash
   kind create cluster --config kind-cca.yaml
   kubectl get nodes
   ```

   Esperado — todos los nodos están en `NotReady`, porque todavía no hay CNI:

   ```
   NAME                    STATUS     ROLES           AGE   VERSION
   cca-lab-control-plane   NotReady   control-plane   38s   v1.31.0
   cca-lab-worker          NotReady   <none>          25s   v1.31.0
   cca-lab-worker2         NotReady   <none>          25s   v1.31.0
   ```

3. Escribí un archivo de valores de Helm explícito. Usar un archivo de valores en vez de un muro de flags `--set` evita la trampa del escapado de comas en `labelsContext`, y es lo que mantendrías en Git en producción:

   ```yaml
   # cilium-values.yaml
   kubeProxyReplacement: true
   k8sServiceHost: cca-lab-control-plane
   k8sServicePort: 6443

   # Agent + operator self-metrics (separate from Hubble's flow metrics)
   prometheus:
     enabled: true
     port: 9962
   operator:
     prometheus:
       enabled: true
       port: 9963

   hubble:
     enabled: true                # turns on the observer inside the agent
     eventBufferCapacity: 16383   # per-node ring buffer of flows (default 4095)
     relay:
       enabled: true              # cluster-wide aggregation
     ui:
       enabled: true              # service map
     metrics:
       enabled:
         - "dns:query;ignoreAAAA"
         - drop
         - tcp
         - flow
         - port-distribution
         - icmp
         - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
       enableOpenMetrics: true
       port: 9965
   ```

4. Instalá Cilium y esperá a que esté listo:

   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm repo update
   helm install cilium cilium/cilium \
     --version "${CILIUM_VERSION}" \
     --namespace kube-system \
     --values cilium-values.yaml

   cilium status --wait
   ```

   Esperado — notá que `Hubble Relay` y `Hubble UI` se reportan como Deployments *separados* del agente:

   ```
       /¯¯\
    /¯¯\__/¯¯\    Cilium:             OK
    \__/¯¯\__/    Operator:           OK
    /¯¯\__/¯¯\    Envoy DaemonSet:    OK
    \__/¯¯\__/    Hubble Relay:       OK
       \__/       ClusterMesh:        disabled

   DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
   Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1
   Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
   Containers:            cilium             Running: 3
                          hubble-relay       Running: 1
                          hubble-ui          Running: 1
   ```

5. Confirmá que el observer está efectivamente habilitado *dentro del agente*, no solo que existe un Deployment:

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A3 Hubble
   ```

   Esperado:

   ```
   Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 42.17   Metrics: Ok
   ```

   > `cilium-dbg` es la CLI de depuración interna del agente (renombrada desde `cilium` en 1.16; el nombre viejo puede seguir existiendo como alias deprecado). El binario `cilium` que ejecutás en tu laptop es un *programa distinto* — la cilium-cli, que habla con la API de Kubernetes. Confundir ambos es una trampa clásica del examen.

6. Desplegá la carga de trabajo de demostración canónica:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/minikube/http-sw-app.yaml
   kubectl wait --for=condition=Ready pod --all --timeout=120s
   kubectl get pods --show-labels
   ```

   Esperado:

   ```
   NAME                         READY   STATUS    LABELS
   deathstar-8555bf78d9-5x9lk   1/1     Running   class=deathstar,org=empire,...
   deathstar-8555bf78d9-p4tzq   1/1     Running   class=deathstar,org=empire,...
   tiefighter                   1/1     Running   class=tiefighter,org=empire
   xwing                        1/1     Running   class=xwing,org=alliance
   ```

7. Generá una request para tener algo que observar:

   ```bash
   kubectl exec tiefighter -- \
     curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Esperado: `Ship landed`

### Preguntas de comprensión

- **Q0.1** — Heredás un clúster donde ocurrió una caída hace 20 minutos. En ese momento `hubble.enabled` estaba en `false`; lo habilitás ahora y reiniciás los agentes. ¿Podés recuperar los flujos de la caída? Justificá tu respuesta en términos de dónde viven los datos de flujo.
- **Q0.2** — ¿Por qué que `hubble-relay` esté `Ready` no te dice *nada* sobre si se están capturando flujos en un nodo dado?
- **Q0.3** — `eventBufferCapacity` está en `16383`. ¿Cuál es la unidad, cuál es el alcance (clúster, nodo, endpoint?) y cuál es la consecuencia operativa de aumentarlo?
- **Q0.4** — Nombrá los cuatro endpoints de Prometheus distintos que expone esta instalación y el puerto por defecto de cada uno. ¿Cuál *no* queda habilitado por nada de lo que hay en `cilium-values.yaml` arriba, y por qué existe igual?

---

## Ejercicio 1 — Las tres capas de Hubble

Hubble no es un solo componente. Entender la división vale puntos en el examen y es la diferencia entre depurar un solo nodo y depurar un clúster.

```
┌──────────────────────────── node ────────────────────────────┐
│  eBPF datapath  ──perf ring buffer──▶  cilium-agent          │
│                                        └─ Hubble observer    │
│                                           ├─ unix:///var/run/cilium/hubble.sock
│                                           └─ tcp :4244  ─────┼──▶ hubble-relay :4245 ──▶ hubble CLI / UI
└──────────────────────────────────────────────────────────────┘
```

### Pasos

1. Hablá con el observer **local al nodo**, desde dentro de un pod del agente:

   ```bash
   AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
     -o jsonpath='{.items[0].metadata.name}')
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     hubble observe --last 5
   ```

2. Ahora abrí un port-forward a **Relay** y hablá con la vista a nivel de clúster:

   ```bash
   cilium hubble port-forward &
   sleep 3
   hubble status
   ```

   Esperado:

   ```
   Healthcheck (via localhost:4245): Ok
   Current/Max Flows: 49,149/49,149 (100.00%)
   Flows/s: 126.44
   Connected Nodes: 3/3
   ```

3. Probá la diferencia de alcance explícitamente:

   ```bash
   hubble list nodes
   ```

   Esperado:

   ```
   NAME                    STATUS      AGE   FLOWS/S   CURRENT/MAX-FLOWS
   cca-lab-control-plane   Connected   14m   38.21     16,383/16,383 (100.00%)
   cca-lab-worker          Connected   14m   44.09     16,383/16,383 (100.00%)
   cca-lab-worker2         Connected   14m   44.14     16,383/16,383 (100.00%)
   ```

4. Inspeccioná cómo Relay llega a los agentes — por defecto en el chart de Helm esto es una malla gRPC con TLS mutuo:

   ```bash
   kubectl -n kube-system get secret | grep hubble
   kubectl -n kube-system get svc hubble-peer hubble-relay
   ```

   Esperado:

   ```
   hubble-ca-secret                 Opaque   2
   hubble-relay-client-certs        kubernetes.io/tls   3
   hubble-server-certs              kubernetes.io/tls   3

   NAME           TYPE        CLUSTER-IP     PORT(S)
   hubble-peer    ClusterIP   10.96.51.203   443/TCP
   hubble-relay   ClusterIP   10.96.140.11   80/TCP
   ```

5. Simulá una caída parcial y mirá cómo el plano de observabilidad se degrada honestamente:

   ```bash
   kubectl -n kube-system delete pod -l k8s-app=cilium \
     --field-selector spec.nodeName=cca-lab-worker2
   hubble status
   ```

   Esperado, brevemente:

   ```
   Healthcheck (via localhost:4245): Ok
   Connected Nodes: 2/3
   Unavailable Nodes: 1
     - cca-lab-worker2: rpc error: code = Unavailable desc = connection error
   ```

### Preguntas de comprensión

- **Q1.1** — ¿En qué puerto escucha el servidor Hubble del agente, y en qué puerto sirve Relay a los clientes? ¿Cuál de los dos reenvía `cilium hubble port-forward`?
- **Q1.2** — ¿Para qué sirve el Service `hubble-peer`? ¿Por qué es un Service y no una lista de nodos hardcodeada?
- **Q1.3** — En el paso 5, `hubble status` sigue reportando `Ok` mientras un nodo está inalcanzable. Explicá por qué ese es el diseño correcto y qué significa para una alerta que escribirías sobre esto.
- **Q1.4** — Ejecutás `hubble observe` desde dentro de un pod del agente en `worker` y no ves nada para un pod que sabés que está corriendo. Antes de sospechar de un bug, ¿cuál es la explicación más probable?

---

## Ejercicio 2 — Anatomía de una línea de flujo

Toda respuesta sobre Hubble en el examen depende de interpretar correctamente esta única línea.

### Pasos

1. Generá tráfico constante en una terminal:

   ```bash
   kubectl exec tiefighter -- sh -c \
     'while true; do curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing >/dev/null; sleep 1; done' &
   ```

2. Observalo:

   ```bash
   hubble observe --namespace default --follow
   ```

   Esperado (una request produce varios flujos — esta es la clave):

   ```
   Sep  1 14:02:11.284: default/tiefighter:45678 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) to-endpoint FORWARDED (UDP)
   Sep  1 14:02:11.301: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-overlay FORWARDED (TCP Flags: SYN)
   Sep  1 14:02:11.302: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: SYN)
   Sep  1 14:02:11.302: default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) -> default/tiefighter:45678 (ID:23459) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
   Sep  1 14:02:11.305: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
   Sep  1 14:02:11.311: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
   ```

3. Decodificá el mismo flujo como datos estructurados — esto es lo que enviarías a un SIEM:

   ```bash
   hubble observe --namespace default --last 1 --to-label class=deathstar -o json | jq '{
     time, verdict: .verdict, type: .Type,
     src: {ns: .source.namespace, pod: .source.pod_name, id: .source.identity, labels: .source.labels},
     dst: {ns: .destination.namespace, pod: .destination.pod_name, id: .destination.identity},
     l4: .l4, node: .node_name, event: .event_type
   }'
   ```

   Esperado:

   ```json
   {
     "time": "2026-09-01T14:02:11.302Z",
     "verdict": "FORWARDED",
     "src": {
       "ns": "default", "pod": "tiefighter", "id": 23459,
       "labels": ["k8s:class=tiefighter", "k8s:io.kubernetes.pod.namespace=default", "k8s:org=empire"]
     },
     "dst": { "ns": "default", "pod": "deathstar-8555bf78d9-5x9lk", "id": 12551 },
     "l4": { "TCP": { "source_port": 45678, "destination_port": 80, "flags": { "SYN": true } } },
     "node_name": "cca-lab/cca-lab-worker",
     "event": { "type": 4, "sub_type": 0 }
   }
   ```

4. Averiguá qué significan realmente esas identidades numéricas:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg identity list | head -20
   ```

   Esperado:

   ```
   ID      LABELS
   1       reserved:host
   2       reserved:world
   3       reserved:unmanaged
   4       reserved:health
   5       reserved:init
   6       reserved:remote-node
   7       reserved:kube-apiserver
   8       reserved:ingress
   12551   k8s:class=deathstar
           k8s:io.cilium.k8s.policy.cluster=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
   23459   k8s:class=tiefighter
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
   ```

5. Notá que las dos réplicas de `deathstar` comparten **una sola** identidad:

   ```bash
   hubble observe --last 200 --to-label class=deathstar -o json \
     | jq -r '"\(.destination.pod_name)\t\(.destination.identity)"' | sort -u
   ```

   Esperado:

   ```
   deathstar-8555bf78d9-5x9lk	12551
   deathstar-8555bf78d9-p4tzq	12551
   ```

### Preguntas de comprensión

- **Q2.1** — Un solo `curl` produjo seis flujos. Explicá qué significan `to-overlay`, `to-endpoint` y `to-stack` y por qué una única request lógica puede aparecer varias veces.
- **Q2.2** — Ambos pods `deathstar` reportan la identidad `12551`. ¿Qué determina una identidad de seguridad, y cuál es la consecuencia directa para el escalado de políticas en un clúster de 5.000 pods?
- **Q2.3** — La identidad `2` es `reserved:world`. Si ves `10.0.5.7 (ID:2) -> default/api:443`, ¿qué aprendiste sobre el origen, y qué *no* aprendiste?
- **Q2.4** — ¿Sobre qué identidad reservada filtrarías para encontrar tráfico hacia el servidor de API de Kubernetes, y por qué es útil tener una identidad dedicada para eso en una auditoría de políticas?
- **Q2.5** — Enumerá los valores posibles del campo `verdict`. ¿Cuál significa "la política denegó *pero* el paquete se dejó pasar igual", y cuándo querrías eso deliberadamente?

---

## Ejercicio 3 — Filtrar como un SRE

Un `hubble observe` sin filtrar en un clúster real es una manguera de incendios. El examen espera fluidez con los flags de filtrado.

### Pasos

1. Filtros direccionales — notá la diferencia entre `--pod` y las variantes direccionales:

   ```bash
   hubble observe --from-pod default/tiefighter --last 5
   hubble observe --to-pod   default/deathstar --last 5
   hubble observe --pod      default/tiefighter --last 5   # either direction
   ```

2. Filtros por etiqueta e identidad — los filtros por etiqueta sobreviven a los reinicios de pods, los de IP no:

   ```bash
   hubble observe --from-label org=empire --to-label class=deathstar --last 10
   hubble observe --identity 12551 --last 10
   ```

3. Protocolo y puerto:

   ```bash
   hubble observe --protocol tcp --port 80 --last 10
   hubble observe --protocol dns --last 10
   ```

4. Veredicto y tipo de evento — los dos filtros más útiles durante un incidente:

   ```bash
   hubble observe --verdict DROPPED --last 20
   hubble observe --type drop --type policy-verdict --last 20
   ```

5. Ventanas de tiempo. `--since` acepta tanto duraciones como timestamps RFC3339:

   ```bash
   hubble observe --since 5m --verdict DROPPED
   hubble observe --since 2026-09-01T14:00:00Z --until 2026-09-01T14:05:00Z --namespace default
   ```

6. Negación — encontrá todo *excepto* el camino conocido-bueno y ruidoso:

   ```bash
   hubble observe --last 50 --not --to-namespace kube-system
   ```

7. Inspeccioná el filtro gRPC en el que realmente se compilan tus flags. Esta es la mejor herramienta de depuración cuando un filtro "no devuelve nada":

   ```bash
   hubble observe --from-label org=empire --to-port 80 --verdict DROPPED --print-raw-filters
   ```

   Esperado:

   ```yaml
   allowlist:
     - '{"source_label":["org=empire"],"destination_port":["80"],"verdict":["DROPPED"]}'
   ```

8. Armá una línea de triaje que realmente conservarías:

   ```bash
   hubble observe --since 15m --verdict DROPPED -o json \
     | jq -r '[.source.namespace, .source.pod_name, .destination.namespace,
               .destination.pod_name, (.l4.TCP.destination_port // .l4.UDP.destination_port // "-"),
               .drop_reason_desc] | @tsv' \
     | sort | uniq -c | sort -rn | head
   ```

   Esperado:

   ```
        41  default  xwing  default  deathstar-8555bf78d9-5x9lk  80  POLICY_DENIED
         3  default  xwing  kube-system  coredns-7db6d8ff4d-2q9wv  53  POLICY_DENIED
   ```

### Preguntas de comprensión

- **Q3.1** — Dentro de una misma invocación de `hubble observe`, ¿varios flags *distintos* (`--from-label` + `--to-port`) se combinan con AND o con OR? ¿Y repetir el *mismo* flag dos veces (`--type drop --type policy-verdict`)?
- **Q3.2** — ¿Por qué un runbook debería preferir `--from-label app=checkout` sobre `--from-ip 10.244.3.19`?
- **Q3.3** — `hubble observe --verdict DROPPED --since 1h` no devuelve nada en un clúster donde tenés certeza de que se descartaron paquetes hace 40 minutos. Dá dos explicaciones independientes.
- **Q3.4** — ¿Qué imprime `--print-raw-filters`, y nombrá un bug concreto que detectaría y que leer tu propia línea de comandos no detectaría.

---

## Ejercicio 4 — Veredictos de política y forense de descartes

Este es el ejercicio de mayor rendimiento del dominio. "¿Por qué falla esta conexión?" es la pregunta real más común y la pregunta de examen más común.

### Pasos

1. Aplicá una política L3/L4 que solo deje entrar al Imperio:

   ```yaml
   # l4-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1
     namespace: default
   spec:
     description: "L4 policy to restrict deathstar access to empire ships only"
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f l4-policy.yaml
   ```

2. Confirmá que la aplicación (enforcement) se activó para los endpoints seleccionados:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg endpoint list
   ```

   Esperado — `Ingress` ahora está `Enabled` solo para deathstar:

   ```
   ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS                    IPv4          STATUS
              ENFORCEMENT        ENFORCEMENT
   184        Enabled            Disabled          12551      k8s:class=deathstar       10.244.1.201  ready
                                                              k8s:org=empire
   1742       Disabled           Disabled          23459      k8s:class=tiefighter      10.244.1.87   ready
                                                              k8s:org=empire
   ```

3. Arrancá un observer dedicado en una segunda terminal:

   ```bash
   hubble observe --follow --type policy-verdict --type drop --namespace default
   ```

4. Enviá una request permitida y una denegada:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed

   kubectl exec xwing -- curl -s --connect-timeout 5 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # (hangs, then: command terminated with exit code 28)
   ```

   Esperado en el observer — notá el **par** de eventos para la denegación:

   ```
   Sep  1 14:31:02.118: default/tiefighter:52984 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
   Sep  1 14:31:19.443: default/xwing:41010 (ID:24675) <> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
   Sep  1 14:31:19.443: default/xwing:41010 (ID:24675) <> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) Policy denied DROPPED (TCP Flags: SYN)
   ```

5. Leé el motivo del descarte como datos estructurados:

   ```bash
   hubble observe --verdict DROPPED --last 1 -o json \
     | jq '{drop_reason: .drop_reason_desc, type: .event_type, dir: .traffic_direction, node: .node_name}'
   ```

   Esperado:

   ```json
   {
     "drop_reason": "POLICY_DENIED",
     "type": { "type": 1, "sub_type": 133 },
     "dir": "INGRESS",
     "node": "cca-lab/cca-lab-worker"
   }
   ```

6. Ahora bajá una capa y leé el mapa de política eBPF del endpoint que aplica la regla. `184` es el ID del endpoint de deathstar del paso 2:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   ```

   Esperado — las columnas `BYTES`/`PACKETS` son contadores de aciertos por regla, observabilidad que el log de flujos no te puede dar:

   ```
   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   BYTES   PACKETS   PREFIX
   Allow       0          reserved:unknown              80/TCP       NONE         0       0         16
   Allow       23459      k8s:class=tiefighter          80/TCP       NONE         4218    31        0
                          k8s:org=empire
   Allow       1          reserved:host                 ANY          NONE         610     9         0
   ```

7. Comprobá que los contadores se mueven — el punto relevante para el examen es que una regla con `PACKETS 0` después de semanas es una regla muerta:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing >/dev/null
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg bpf policy get 184 | grep tiefighter -A0
   ```

8. Compará contra el stream de eventos crudo del datapath:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg monitor --type drop
   ```

   Después volvé a correr el `curl` de `xwing`. Esperado:

   ```
   Listening for events on 8 CPUs with 64x4096 of shared memory
   Press Ctrl-C to quit
   xx drop (Policy denied) flow 0x9a3f21b8 to endpoint 184, ifindex 14, file bpf_lxc.c line 2091, , identity 24675->12551: 10.244.1.93:41014 -> 10.244.1.201:80 tcp SYN
   ```

9. Confirmá el contador agregado de descartes que exporta el agente:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg metrics list | grep drop_count
   ```

   Esperado:

   ```
   cilium_drop_count_total   direction=INGRESS  reason=Policy denied   47.000000
   ```

### Preguntas de comprensión

- **Q4.1** — Explicá la diferencia entre un evento `policy-verdict` y un evento `drop`. ¿Por qué un paquete denegado emite ambos, y cuándo verías un `policy-verdict` sin un drop acompañante?
- **Q4.2** — ¿Qué significa `policy-verdict:L3-L4` frente a `policy-verdict:none`? ¿Cuáles son los otros valores de tipo de coincidencia que podrías ver?
- **Q4.3** — El `curl` de `xwing` se colgó hasta el timeout en vez de recibir `Connection refused`. ¿Qué te dice eso sobre cómo Cilium aplica una denegación L3/L4, y en qué se diferencia de una denegación L7?
- **Q4.4** — En el paso 2, el enforcement de Ingress de `tiefighter` está `Disabled` mientras que el de `deathstar` está `Enabled`. Explicá el modelo default-allow/default-deny que produce esto, y el riesgo operativo que genera.
- **Q4.5** — Tenés una `CiliumNetworkPolicy` que creés que no se usa y querés borrarla. ¿Qué comando te da evidencia en vez de una conjetura, y qué mirarías exactamente?
- **Q4.6** — ¿Cuándo usarías `cilium-dbg monitor` en vez de `hubble observe`? Nombrá dos capacidades que `monitor` tiene y Hubble no, y una desventaja importante.

---

## Ejercicio 5 — Visibilidad L7: HTTP

Los flujos L3/L4 te dicen *que* hubo una conexión. Responder "¿qué endpoint devolvió 500?" requiere el proxy L7 Envoy, y activarlo es una decisión deliberada y costosa.

### Pasos

1. Confirmá que actualmente **no** tenés visibilidad HTTP:

   ```bash
   hubble observe --protocol http --last 5
   # (no output)
   ```

2. Reemplazá la política L4 por una consciente de L7:

   ```yaml
   # l7-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1
     namespace: default
   spec:
     description: "L7 policy: empire ships may only request landing"
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
             rules:
               http:
                 - method: "POST"
                   path: "/v1/request-landing"
   ```

   ```bash
   kubectl apply -f l7-policy.yaml
   ```

3. Verificá que apareció la redirección al proxy en el mapa de política eBPF — la columna `PROXY PORT` ahora es distinta de cero:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   ```

   Esperado:

   ```
   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   BYTES   PACKETS   PREFIX
   Allow       23459      k8s:class=tiefighter          80/TCP       17423        6104     44        0
                          k8s:org=empire
   ```

4. Ejercitá tanto la llamada permitida como la prohibida:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed

   kubectl exec tiefighter -- curl -s -XPUT \
     deathstar.default.svc.cluster.local/v1/exhaust-port
   # Access denied
   ```

5. Observá los flujos L7:

   ```bash
   hubble observe --protocol http --last 10
   ```

   Esperado:

   ```
   Sep  1 15:10:04.221: default/tiefighter:54012 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
   Sep  1 15:10:04.229: default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) -> default/tiefighter:54012 (ID:23459) http-response FORWARDED (HTTP/1.1 200 8ms (POST http://deathstar.default.svc.cluster.local/v1/request-landing))
   Sep  1 15:10:12.884: default/tiefighter:54020 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) http-request DROPPED (HTTP/1.1 PUT http://deathstar.default.svc.cluster.local/v1/exhaust-port)
   ```

6. Filtrá por semántica HTTP — esto es lo que no podés hacer en L4:

   ```bash
   hubble observe --http-method PUT --last 10
   hubble observe --http-path /v1/exhaust-port --last 10
   hubble observe --http-status 200 --last 10
   ```

7. Extraé la latencia, que solo lleva el evento `http-response`:

   ```bash
   hubble observe --protocol http --last 100 -o json \
     | jq -r 'select(.l7.http.code != null)
              | [.l7.http.code, .l7.latency_ns, .l7.http.method, .l7.http.url] | @tsv'
   ```

   Esperado:

   ```
   200	8214000	POST	http://deathstar.default.svc.cluster.local/v1/request-landing
   200	6109000	POST	http://deathstar.default.svc.cluster.local/v1/request-landing
   ```

8. Medí el costo. Compará el round-trip con y sin el proxy en el camino:

   ```bash
   kubectl exec tiefighter -- sh -c \
     'for i in $(seq 1 20); do curl -s -o /dev/null -w "%{time_total}\n" \
       -XPOST deathstar.default.svc.cluster.local/v1/request-landing; done' \
     | awk '{s+=$1} END {print "mean:", s/NR, "s"}'
   ```

   Después `kubectl apply -f l4-policy.yaml` y repetí. El camino L7 es medible­mente más lento porque ahora cada paquete se termina en espacio de usuario en Envoy.

> **Nota de producción sobre la anotación de visibilidad.** Material más viejo enseña `policy.cilium.io/proxy-visibility: "<Ingress/80/TCP/HTTP>"` (originalmente `io.cilium.proxy-visibility`) como forma de obtener flujos L7 sin escribir una política L7. Esa anotación fue deprecada y eliminada en releases recientes en favor de reglas de política L7. Verificá la guía de actualización para la versión exacta que corrés; el mecanismo portable — y el que hay que dar en el examen salvo que la pregunta nombre la anotación — es una `CiliumNetworkPolicy` consciente de L7.

### Preguntas de comprensión

- **Q5.1** — ¿Qué cambio arquitectónico ocurre en el camino del paquete cuando agregás una regla `http:`, y cómo *probás* desde la CLI que ocurrió, sin enviar tráfico?
- **Q5.2** — El `PUT` prohibido produjo `Access denied` de inmediato, mientras que la denegación L3/L4 del Ejercicio 4 se colgó hasta el timeout. Explicá la razón mecánica de la diferencia.
- **Q5.3** — Un flujo `http-request` con veredicto `DROPPED` — ¿eBPF descartó algún paquete? ¿Qué pasó realmente en el cable?
- **Q5.4** — ¿Por qué `latency_ns` aparece solo en eventos `http-response` y nunca en `http-request`?
- **Q5.5** — Querés visibilidad HTTP para una auditoría pero no debés cambiar la postura de seguridad del namespace. Escribí la estrofa `rules.http` que lo logra, y enunciá los dos costos que estás aceptando.

---

## Ejercicio 6 — Visibilidad L7: DNS y FQDN

DNS es donde viven la mayoría de los incidentes "intermitentes e inexplicables", y el proxy DNS de Cilium es el único componente que ve la pregunta y la respuesta juntas.

### Pasos

1. Confirmá que todavía no tenés visibilidad DNS:

   ```bash
   hubble observe --protocol dns --last 5
   # (no output — DNS is just UDP/53 to the datapath)
   ```

2. Aplicá una política de egress que active el proxy DNS y restrinja destinos por FQDN:

   ```yaml
   # dns-egress-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: tiefighter-egress
     namespace: default
   spec:
     description: "Observe all DNS, allow egress only to the empire CDN"
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       # 1. Allow DNS to kube-dns AND enable the L7 DNS proxy for every query
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
       # 2. Allow egress to a specific FQDN only
       - toFQDNs:
           - matchName: "www.cncf.io"
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
       # 3. Keep in-cluster access working
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f dns-egress-policy.yaml
   ```

3. Generá una resolución permitida y una denegada:

   ```bash
   kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' https://www.cncf.io
   # 200
   kubectl exec tiefighter -- curl -s -o /dev/null --connect-timeout 5 https://www.example.com
   # (exit 28)
   ```

4. Observá DNS en L7:

   ```bash
   hubble observe --protocol dns --last 10
   ```

   Esperado — la consulta y la respuesta resuelta son ambas visibles:

   ```
   Sep  1 15:44:03.881: default/tiefighter:40391 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) dns-request proxy FORWARDED (DNS Query www.cncf.io. A)
   Sep  1 15:44:03.904: kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) -> default/tiefighter:40391 (ID:23459) dns-response proxy FORWARDED (DNS Answer "104.22.7.82" TTL: 30 (Proxy www.cncf.io. A))
   Sep  1 15:44:11.220: default/tiefighter:33150 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) dns-request proxy FORWARDED (DNS Query www.example.com. A)
   Sep  1 15:44:11.245: kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) -> default/tiefighter:33150 (ID:23459) dns-response proxy FORWARDED (DNS Answer "93.184.215.14" TTL: 30 (Proxy www.example.com. A))
   Sep  1 15:44:11.246: default/tiefighter:52288 (ID:23459) <> 93.184.215.14:443 (ID:16777217) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
   ```

5. Filtrá por nombre resuelto — notá que esto funciona aunque el flujo sea hacia una IP pelada:

   ```bash
   hubble observe --fqdn "www.cncf.io" --last 10
   hubble observe --to-fqdn "*.cncf.io" --last 10
   ```

6. Inspeccioná la caché de FQDN que construyó el proxy, que es contra lo que realmente se aplica la política:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg fqdn cache list
   ```

   Esperado:

   ```
   ENDPOINT   FQDN            TTL   EXPIRATION                     IPS
   1742       www.cncf.io.    30    2026-09-01T15:44:33.904Z       104.22.7.82,104.22.6.82
   1742       www.example.com. 30   2026-09-01T15:44:41.245Z       93.184.215.14
   ```

7. Encontrá los que más hablan por nombre DNS — una consulta de higiene semanal estándar:

   ```bash
   hubble observe --protocol dns --since 10m -o json \
     | jq -r 'select(.l7.dns.qtypes != null) | .l7.dns.query' \
     | sort | uniq -c | sort -rn | head
   ```

### Preguntas de comprensión

- **Q6.1** — ¿Por qué agregar una regla `dns:` a una política de *egress* produjo visibilidad, cuando no agregar ninguna política no producía nada? ¿Qué componente instancia la regla `dns:`?
- **Q6.2** — En el paso 4, `www.example.com` **resolvió correctamente** y luego fue denegado en el SYN TCP. Explicá por qué la respuesta DNS pasó, y qué significa esa división cuando estás depurando "el DNS funciona pero la app no se puede conectar".
- **Q6.3** — Apareció la identidad `16777217` para la IP externa. ¿Qué clase de identidad es esa, y en qué se diferencia de `reserved:world` (ID 2)?
- **Q6.4** — `hubble observe --fqdn www.cncf.io` matcheó un flujo cuyo campo de destino es una dirección IP. ¿De dónde viene esa asociación nombre→IP, y qué pasa con el match después de que expira el TTL?
- **Q6.5** — Una política `toFQDNs` bloquea intermitentemente un host legítimo. Dá las dos causas raíz relacionadas con DNS más probables y el comando que las distingue.

---

## Ejercicio 7 — El mapa de servicios (Hubble UI)

### Pasos

1. Abrí la UI:

   ```bash
   cilium hubble ui
   # forwards hubble-ui:80 -> localhost:12000 and opens a browser
   ```

2. Seleccioná el namespace `default`. Deberías ver nodos para `tiefighter`, `xwing`, `deathstar`, más `kube-dns` y un nodo `world`, con aristas dirigidas anotadas por puerto y color de veredicto.

3. Generá una denegación y mirá cómo la arista se pone roja:

   ```bash
   kubectl exec xwing -- curl -s --connect-timeout 3 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing || true
   ```

4. Hacé clic en la arista roja. El panel inferior muestra la tabla de flujos con los mismos campos que `hubble observe`; usá el cuadro de filtro con la misma sintaxis (`org=empire`, `dns=www.cncf.io`).

5. Confirmá qué está leyendo realmente la UI:

   ```bash
   kubectl -n kube-system get deploy hubble-ui -o jsonpath='{.spec.template.spec.containers[*].name}'
   ```

   Esperado:

   ```
   frontend backend
   ```

   El contenedor `backend` es un cliente gRPC de `hubble-relay`. La UI no tiene acceso privilegiado al datapath.

### Preguntas de comprensión

- **Q7.1** — Hubble UI muestra un mapa de servicios. ¿Ese mapa se construye a partir de los objetos Service de Kubernetes, del tráfico observado, o de las políticas de red? ¿Qué implica tu respuesta sobre un servicio que no recibe tráfico?
- **Q7.2** — Tu equipo de seguridad pide un diagrama de dependencias de 30 días para una auditoría. ¿Por qué Hubble UI es la herramienta equivocada, y qué construirías en su lugar?
- **Q7.3** — Hubble UI está vacía para un namespace donde `hubble observe --namespace X` devuelve flujos. Nombrá dos causas de configuración.

---

## Ejercicio 8 — Métricas: de flujos a series temporales

Los flujos son eventos; las métricas son el agregado sobre el que alertás. La contrapartida que tenés que saber articular es la **cardinalidad**.

### Pasos

1. Confirmá que el endpoint de métricas existe y está separado de las métricas propias del agente:

   ```bash
   kubectl -n kube-system get svc hubble-metrics -o yaml | grep -A5 annotations
   ```

   Esperado:

   ```yaml
   annotations:
     prometheus.io/port: "9965"
     prometheus.io/scrape: "true"
   ```

2. Scrapealo a mano:

   ```bash
   kubectl -n kube-system port-forward svc/hubble-metrics 9965:9965 &
   sleep 2
   curl -s localhost:9965/metrics | grep -E '^hubble_(drop|flows|http)' | head -20
   ```

   Esperado:

   ```
   hubble_drop_total{destination="default/deathstar",protocol="TCP",reason="POLICY_DENIED",source="default/xwing"} 47
   hubble_flows_processed_total{destination="default/deathstar",protocol="TCP",subtype="to-endpoint",type="Trace",verdict="FORWARDED"} 8134
   hubble_http_requests_total{method="POST",protocol="HTTP/1.1",reporter="server",source_workload="tiefighter",destination_workload="deathstar",status="200"} 612
   hubble_http_request_duration_seconds_bucket{le="0.005",...} 388
   ```

3. Compará con las métricas *propias del agente*, en un puerto distinto:

   ```bash
   kubectl -n kube-system port-forward ds/cilium 9962:9962 &
   sleep 2
   curl -s localhost:9962/metrics | grep -E '^cilium_(drop_count|policy|endpoint_state|bpf_map)' | head
   ```

   Esperado:

   ```
   cilium_drop_count_total{direction="INGRESS",reason="Policy denied"} 47
   cilium_policy_endpoint_enforcement_status{enforcement="both"} 2
   cilium_endpoint_state{endpoint_state="ready"} 12
   cilium_bpf_map_pressure{map_name="cilium_policy_00184"} 0.0031
   ```

4. Hacé explotar la cardinalidad deliberadamente y observá el costo:

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --reuse-values \
     --set hubble.metrics.enabled="{drop,flow,httpV2:labelsContext=source_ip\,destination_ip\,source_pod\,destination_pod}"
   kubectl -n kube-system rollout status ds/cilium
   sleep 60
   curl -s localhost:9965/metrics | grep -c '^hubble_http_requests_total'
   ```

   Compará esa cantidad de series con la configuración basada en `source_workload` del Ejercicio 0. `source_ip` produce una serie por cada IP de pod efímera; `source_workload` produce una por Deployment.

5. Volvé a la configuración sensata:

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --values cilium-values.yaml
   kubectl -n kube-system rollout status ds/cilium
   ```

6. Escribí una alerta que sea realmente accionable:

   ```yaml
   # alert-rules.yaml
   groups:
     - name: cilium-observability
       rules:
         - alert: CiliumPolicyDropsSpiking
           expr: |
             sum by (source, destination) (
               rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
             ) > 1
           for: 10m
           labels:
             severity: warning
           annotations:
             summary: "Policy drops {{ $labels.source }} -> {{ $labels.destination }}"
             runbook: "hubble observe --verdict DROPPED --from-pod {{ $labels.source }} --last 100"

         - alert: CiliumHubbleBufferSaturated
           expr: |
             rate(hubble_lost_events_total[5m]) > 0
           for: 5m
           labels:
             severity: critical
           annotations:
             summary: "Hubble is dropping events on {{ $labels.instance }} — flow data is incomplete"
   ```

### Preguntas de comprensión

- **Q8.1** — Dá el puerto por defecto de cada uno: métricas de cilium-agent, métricas de cilium-operator, métricas de Hubble, métricas de cilium-envoy.
- **Q8.2** — `hubble_drop_total` y `cilium_drop_count_total` cuentan ambas descartes. ¿Cuál es la diferencia en lo que saben, y cuál sobrevive a que Hubble esté deshabilitado?
- **Q8.3** — Explicá concretamente por qué `labelsContext=source_ip` es peligroso en un clúster con un HorizontalPodAutoscaler, y dá la etiqueta que deberías usar en su lugar.
- **Q8.4** — ¿Qué significa físicamente `hubble_lost_events_total > 0`? Nombrá dos formas de arreglarlo y la contrapartida de cada una.
- **Q8.5** — `enableOpenMetrics: true` más `exemplars=true` en `httpV2` te compra algo específico. ¿Qué, y qué otro sistema tiene que existir para que sea útil?

---

## Ejercicio 9 — Exportación de flujos y retención

El ring buffer en memoria de Hubble es un almacén de *depuración*, no un almacén de auditoría. La retención es una funcionalidad aparte.

### Pasos

1. Comprobá que el buffer es finito y con pérdidas:

   ```bash
   hubble observe --last 1 -o json | jq -r .time     # oldest retrievable is bounded
   hubble status                                     # Current/Max Flows: 49,149/49,149 (100.00%)
   ```

   Al 100% el buffer está lleno y cada flujo nuevo desaloja uno viejo.

2. Habilitá la exportación estática a archivo con una allowlist, para conservar el subconjunto relevante para seguridad en vez de todo:

   ```yaml
   # append to cilium-values.yaml
   hubble:
     export:
       fileMaxSizeMb: 20
       fileMaxBackups: 5
       static:
         enabled: true
         filePath: /var/run/cilium/hubble/events.log
         fieldMask:
           - time
           - source
           - destination
           - verdict
           - drop_reason_desc
           - l4
           - l7
           - node_name
         allowList:
           - '{"verdict":["DROPPED","ERROR"]}'
           - '{"event_type":[{"type":129}]}'   # policy-verdict events
         denyList: []
   ```

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --values cilium-values.yaml
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Generá denegaciones y leé el archivo exportado:

   ```bash
   for i in $(seq 1 5); do
     kubectl exec xwing -- curl -s --connect-timeout 2 \
       -XPOST deathstar.default.svc.cluster.local/v1/request-landing || true
   done

   kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
     tail -n 2 /var/run/cilium/hubble/events.log | jq -c '{
       t: .flow.time, v: .flow.verdict, r: .flow.drop_reason_desc,
       s: .flow.source.pod_name, d: .flow.destination.pod_name }'
   ```

   Esperado:

   ```json
   {"t":"2026-09-01T16:22:08.441Z","v":"DROPPED","r":"POLICY_DENIED","s":"xwing","d":"deathstar-8555bf78d9-5x9lk"}
   {"t":"2026-09-01T16:22:10.518Z","v":"DROPPED","r":"POLICY_DENIED","s":"xwing","d":"deathstar-8555bf78d9-5x9lk"}
   ```

4. Confirmá que un flujo `FORWARDED` **no** llegó al archivo — la allowlist está haciendo su trabajo:

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
     grep -c '"verdict":"FORWARDED"' /var/run/cilium/hubble/events.log || echo "0 — as designed"
   ```

5. Capturá un bundle de soporte completo, que es lo que adjuntás a un issue upstream:

   ```bash
   cilium sysdump --output-filename cca-lab-sysdump
   ```

   Esperado (abreviado):

   ```
   🔍 Collecting Kubernetes nodes, pods, services, network policies...
   🔍 Collecting Cilium bugtool output from all nodes...
   🔍 Collecting Hubble flows from all nodes...
   🗳 Compiling sysdump
   ✅ The sysdump has been saved to cca-lab-sysdump.zip
   ```

### Preguntas de comprensión

- **Q9.1** — ¿Dónde vive físicamente el archivo exportado, y cuál es la cosa más importante que tenés que configurar *fuera* de Cilium para que esta exportación valga algo?
- **Q9.2** — ¿Para qué sirve `fieldMask`? Nombrá los dos beneficios distintos.
- **Q9.3** — Tu allowlist conserva solo `DROPPED` y `ERROR`. Un auditor pregunta "¿quién habló con el servicio de pagos en julio?". ¿Podés responder? ¿Qué habrías tenido que configurar en su lugar, y cuál es el costo?
- **Q9.4** — `cilium sysdump` recolecta flujos de Hubble. Dado el ring buffer, ¿cuál es el límite práctico de hasta dónde llega hacia atrás ese snapshot, y qué implica eso sobre *cuándo* tenés que correrlo durante un incidente?

---

## Ejercicio 10 — Simulacro de incidente de punta a punta

Sin pistas. Usá solo herramientas de observabilidad para diagnosticar, y después arreglalo.

### Pasos

1. Reseteá e inyectá la falla:

   ```bash
   kubectl delete cnp --all
   kubectl apply -f - <<'EOF'
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: incident-10
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "8080"
                 protocol: TCP
             rules:
               http:
                 - method: "GET"
                   path: "/v1/request-landing"
   EOF
   ```

2. Observá el síntoma:

   ```bash
   kubectl exec tiefighter -- curl -s --connect-timeout 5 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   ```

3. Diagnosticá usando solo estos comandos, en orden, anotando qué descarta o confirma cada uno:

   ```bash
   hubble observe --to-pod default/deathstar --last 20
   hubble observe --type policy-verdict --to-label class=deathstar --last 10
   hubble observe --verdict DROPPED --last 10 -o json | jq .drop_reason_desc
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   kubectl get cnp incident-10 -o jsonpath='{.status}' | jq
   ```

4. Arreglá la política, y después comprobá el arreglo con un flujo — no con un código de salida de `curl`:

   ```bash
   hubble observe --protocol http --to-label class=deathstar --last 5
   ```

### Preguntas de comprensión

- **Q10.1** — Hay **dos** fallas independientes en `incident-10`. Nombrá ambas y enunciá la evidencia exacta de flujo que identifica a cada una.
- **Q10.2** — ¿Cuál de las dos fallas es visible en `hubble observe --protocol http`, y cuál es invisible ahí? ¿Por qué?
- **Q10.3** — Escribí la `CiliumNetworkPolicy` corregida.
- **Q10.4** — Escribí el único comando `hubble` que pondrías en el runbook como la comprobación definitiva de "¿está arreglado?", y explicá por qué una comprobación por código de salida de `curl` es insuficiente.

---

## Limpieza

```bash
kubectl delete cnp --all -n default
kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/minikube/http-sw-app.yaml
kind delete cluster --name cca-lab
```

---

## Fuentes

- CNCF CCA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- Cilium — Observability / Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium — Layer 7 protocol visibility — https://docs.cilium.io/en/stable/observability/visibility/
- Cilium — Monitoring & metrics — https://docs.cilium.io/en/stable/observability/metrics/
- Cilium — Hubble flow export — https://docs.cilium.io/en/stable/observability/hubble-exporter/
- Cilium — Network policy language (L7, `toFQDNs`) — https://docs.cilium.io/en/stable/security/policy/language/
- Cilium — Identity & security identities — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium — `cilium-dbg` command reference — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Cilium — Helm reference (`hubble.*` values) — https://docs.cilium.io/en/stable/helm-reference/
- Hubble CLI — https://github.com/cilium/hubble
- Cilium CLI (`cilium status`, `cilium sysdump`, `cilium hubble`) — https://github.com/cilium/cilium-cli

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1 — No, los flujos se perdieron para siempre.** Hubble no tiene almacenamiento persistente por defecto. El datapath eBPF del agente escribe eventos en un perf ring buffer; el observer de Hubble dentro de `cilium-agent` los consume hacia un buffer circular en memoria dimensionado por `hubble.eventBufferCapacity`. Ambas son estructuras en la memoria del proceso, en cada nodo. Si el observer estaba deshabilitado, los eventos nunca fueron consumidos; y reiniciar el agente descarta igual todo lo que estuviera en el buffer. Las únicas formas de tener histórico son (a) exportación de flujos a un archivo enviado fuera del nodo, o (b) métricas, que retienen agregados pero no flujos individuales. Este es *el* argumento para habilitar Hubble antes de necesitarlo.

**A0.2 — Porque `hubble-relay` es un agregador puro sin privilegios sobre el datapath.** Es un Deployment que abre conexiones gRPC al servidor Hubble de cada agente en el puerto 4244 (descubiertos vía el Service `hubble-peer`) y multiplexa sus streams. Relay puede estar perfectamente sano mientras un agente dado tiene Hubble deshabilitado, está en crash-loop, o es inalcanzable. La verdad por nodo es `hubble list nodes` y `cilium-dbg status | grep Hubble` en ese nodo.

**A0.3 — Unidad: eventos de flujo. Alcance: por nodo** (por proceso cilium-agent), no por clúster ni por endpoint. Aumentarlo alarga la ventana de tiempo hacia atrás que podés mirar en un nodo con carga, a costa del RSS del agente — aproximadamente lineal en la cantidad de eventos, y cada evento es un protobuf no trivial. En un nodo que hace 5.000 flujos/s, 16.383 eventos son unos 3 segundos de histórico; por eso el buffer es una ayuda de depuración, no un log. Aumentalo cuando necesitás capturar problemas cortos y a ráfagas; no lo aumentes esperando retención.

**A0.4 —**
- `cilium-agent`: **9962** — habilitado por `prometheus.enabled: true`.
- `cilium-operator`: **9963** — habilitado por `operator.prometheus.enabled: true`.
- Métricas de flujo de Hubble: **9965** — habilitado por `hubble.metrics.enabled`.
- `cilium-envoy` (proxy L7): **9964** — *no* habilitado por nada en el archivo de valores de arriba. Existe porque el DaemonSet de Envoy trae su propio endpoint de métricas para el proxy L7; lo habilitás por separado (`envoy.prometheus.enabled`). Solo importa una vez que efectivamente tenés políticas L7 en juego (Ejercicio 5).

### Ejercicio 1

**A1.1 —** El servidor gRPC de Hubble del agente escucha en el **4244**. Relay sirve a los clientes en el **4245**. `cilium hubble port-forward` reenvía el **4245** (Relay), que es por lo que la CLI `hubble` resultante ve todo el clúster. Dentro de un pod del agente, la CLI `hubble` usa por defecto el socket Unix local `/var/run/cilium/hubble.sock` y por lo tanto ve solo ese nodo.

**A1.2 —** `hubble-peer` es un Service de estilo headless que Relay usa para el **descubrimiento de pares**: resuelve al conjunto de agentes de Cilium actualmente en ejecución, de modo que Relay se entera de los nodos nuevos que se suman y descarta los que se van, sin ningún reinicio ni cambio de configuración. Una lista hardcodeada se rompería en cada escalado, reemplazo de nodo o recuperación de una instancia spot. Es un Service precisamente porque la membresía de nodos es dinámica.

**A1.3 —** Relay está diseñado para servir **resultados parciales en vez de fallar cerrado**: un único nodo inalcanzable no debe volver inservible todo el plano de observabilidad justo durante el incidente en el que lo necesitás. La salud del agregador y la completitud de los datos son hechos separados, así que `Ok` se refiere solo a lo primero. La consecuencia operativa: **nunca alertes solo sobre la salud de `hubble status`.** Alertá sobre `Connected Nodes < esperado`, y tratá "faltan flujos" como un modo de falla distinto de "Hubble está caído". Los datos parciales silenciosos son más peligrosos que una falla dura.

**A1.4 —** El pod casi con seguridad está **programado en otro nodo**. El observer local al nodo solo ve el tráfico que atraviesa el datapath de ese nodo. Cambiá a Relay (`cilium hubble port-forward` + `hubble observe`) o entrá con exec al agente del nodo del pod — `kubectl get pod <p> -o jsonpath='{.spec.nodeName}'`.

### Ejercicio 2

**A2.1 —** Son **puntos de observación del datapath**, cada uno un lugar distinto donde se vio el paquete:
- `to-overlay` — entregado a la interfaz de túnel/overlay para transmitirlo a otro nodo.
- `to-endpoint` — entregado dentro del veth del endpoint destino (último salto de ingress).
- `to-stack` — pasado hacia arriba al stack de red del kernel del host.
- `to-proxy` — redirigido al proxy de Envoy o de DNS.
- `from-endpoint` / `from-network` / `from-host` — los puntos correspondientes del lado del origen.

Una request lógica aparece muchas veces porque Hubble reporta *paquetes en puntos de observación*, no conexiones: la resolución DNS, el SYN en el nodo origen, el SYN en el nodo destino, el SYN-ACK, los segmentos de datos y el FIN generan cada uno eventos. Leer un stream de Hubble como "una línea = una request" es el error de principiante más común.

**A2.2 —** Una **identidad de seguridad se deriva del conjunto de etiquetas relevantes para seguridad** del endpoint (etiquetas del pod, menos las excluidas por la configuración de identity-relevant-labels, más el namespace y el clúster). Todos los pods que comparten ese conjunto de etiquetas comparten una identidad numérica. Consecuencia: la política se aplica sobre **identidad, no sobre IP**, así que el mapa de política eBPF de un endpoint tiene una entrada por *identidad* en vez de por *pod par*. Un Deployment escalado de 3 a 3.000 réplicas agrega **cero** entradas al mapa de política y no dispara recomputación de políticas en los pares. Esta es la razón central por la que el plano de políticas de Cilium escala donde los enfoques de iptables-por-IP no lo hacen.

**A2.3 —** Aprendiste que **Cilium no tiene identidad para esa IP** — no es un endpoint conocido del clúster, no es un nodo, no es el kube-apiserver, y no está cubierta por una regla `CiliumCIDRGroup`/`toCIDR` o `toFQDNs` que habría tallado una identidad más específica. **No** aprendiste que el tráfico venga de la internet pública. `reserved:world` simplemente significa "fuera del espacio de identidades conocido del clúster"; puede incluir rangos RFC1918 on-prem, otra VPC, o un nodo que Cilium no gestiona. Para saber más, definí política basada en CIDR o reglas FQDN, lo que hace que Cilium asigne identidades locales más específicas (ver A6.3).

**A2.4 —** `reserved:kube-apiserver`, identidad **7** (`hubble observe --to-identity 7`). Es útil porque la dirección del apiserver es frecuentemente una VIP, un balanceador de carga, o un endpoint en host-network que de otro modo colapsaría en `reserved:world` o `reserved:host` — lo que significa que una política que permita el acceso al apiserver tendría que permitir una identidad mucho más amplia. Una identidad dedicada te deja escribir y *auditar* "quién habla con el plano de control" con precisión.

**A2.5 —** `FORWARDED`, `DROPPED`, `ERROR`, `AUDIT`, `REDIRECTED`, `TRACED`, `TRANSLATED`. El que buscás es **`AUDIT`**: se emite cuando la `CiliumNetworkPolicy` está en modo auditoría (`policy-audit-mode`), donde un paquete que *habría* sido denegado se registra como `AUDIT` y se reenvía igual. Lo usás deliberadamente al desplegar una nueva política default-deny sobre un servicio vivo: obtenés la lista completa de conexiones que la política rompería, sin una caída, y promovés a enforce una vez que el stream de `AUDIT` se queda callado.

### Ejercicio 3

**A3.1 —** Flags distintos se combinan con **AND** (`--from-label org=empire --to-port 80` significa *desde empire* **y** *hacia el puerto 80*). Repetir el mismo flag se combina con **OR** (`--type drop --type policy-verdict` significa drop **o** policy-verdict). Esta asimetría es exactamente lo que `--print-raw-filters` hace visible: las repeticiones del mismo flag se convierten en varios valores dentro de un campo del filtro, mientras que flags distintos se convierten en campos adicionales dentro de la misma entrada de allowlist — y los campos dentro de una entrada se combinan con AND mientras que entradas separadas de la allowlist se combinan con OR.

**A3.2 —** Las IPs de pod son **efímeras**: un reinicio, un desalojo o un rollout las reasigna, y la IP vieja puede reciclarse a un pod no relacionado en segundos. Un runbook basado en una IP devuelve silenciosamente el tráfico del pod equivocado, o nada. Las etiquetas son identidad estable, sobreviven al reprogramado, y coinciden con la misma abstracción contra la que está escrita la política — así el filtro y la política concuerdan.

**A3.3 —** Dos explicaciones independientes:
1. **El buffer dio la vuelta.** Con un `eventBufferCapacity` por defecto de 4095 en un nodo con carga, 40 minutos de histórico no existen; `--since 1h` no puede conjurar eventos desalojados. Confirmalo con `hubble status` mostrando `Current/Max Flows` al 100%.
2. **Estás consultando el alcance equivocado o el nodo equivocado.** O estás sobre un socket local al nodo y el descarte ocurrió en otro nodo, o Relay perdió al par (`hubble list nodes` lo muestra no disponible), o el agente de ese nodo se reinició desde entonces — vaciando su buffer.

   Una tercera causa, más sutil, que vale la pena conocer: los descartes fueron **denegaciones L7**, que aparecen como `http-request DROPPED` bajo `--type l7`; los matchea `--verdict DROPPED`, pero si el operador hubiera filtrado en cambio con `--type drop` no vería nada, porque no se generó ningún evento de drop de eBPF.

**A3.4 —** Imprime el **protobuf `FlowFilter` de gRPC** en el que se compilan tus flags, como una allowlist/denylist de objetos JSON — es decir, lo que Relay va a evaluar realmente. Bug concreto que detecta: escribir `--label org=empire` (matchea origen **o** destino) cuando querías `--from-label`, o mezclar `--not` esperando que niegue solo el último flag cuando en realidad niega el filtro entero convirtiéndolo en una denylist. El filtro crudo muestra los nombres de campo y la agrupación reales, así que la estructura AND/OR de A3.1 pasa a ser literal en vez de recordada.

### Ejercicio 4

**A4.1 —**
- Un evento **`policy-verdict`** lo emite el motor de políticas en el punto de decisión, sobre el **primer paquete de una conexión nueva**. Reporta la dirección (`INGRESS`/`EGRESS`), la decisión (`ALLOWED`/`DENIED`) y el **tipo de coincidencia** — qué nivel de la regla matcheó. Responde *"¿qué decidió la política, y por qué?"*
- Un evento **`drop`** lo emite el datapath cuando un paquete efectivamente se descarta, llevando un `drop_reason`. Responde *"¿qué le pasó físicamente al paquete?"*

Un paquete denegado emite ambos porque son dos subsistemas distintos reportando el mismo instante: el motor decidió DENY, luego el datapath lo descartó. Ves un `policy-verdict` **sin** drop siempre que el veredicto es `ALLOWED` (no se descartó nada), y ves un **drop sin policy-verdict** cuando el descarte tuvo una causa no relacionada con la política — `CT: Map insertion failed`, `Stale or unroutable IP`, `Invalid source ip`, `Unsupported L3 protocol`. Esa distinción es la manera más rápida de separar "la política de alguien está mal" de "el datapath o la red están rotos", y es una pregunta de examen muy común.

**A4.2 —** El tipo de coincidencia dice qué nivel de la regla autorizó el flujo:
- `L3-L4` — matcheó tanto un selector de identidad como una regla de puerto/protocolo (el caso normal para la política del paso 1).
- `L3-Only` — matcheó un selector de identidad sin restricción de puerto (`toPorts` ausente).
- `L4-Only` — matcheó una regla de puerto/protocolo que aplica sin importar la identidad del par.
- `all` — matcheó una regla allow-all.
- `none` — **no matcheó nada**, así que aplicó default-deny. Esto es siempre lo que ves en un veredicto DENIED.

Leer `policy-verdict:none` como "no existe ninguna política" está mal — significa "acá hay política aplicada y ninguna regla matcheó".

**A4.3 —** Un `Connection refused` requiere un RST de TCP, que requiere que algo *responda*. El enforcement L3/L4 de Cilium **descarta el paquete silenciosamente en eBPF** antes de que llegue siquiera al stack del endpoint destino — sin RST, sin ICMP unreachable, así que el cliente retransmite el SYN hasta que expira su propio timeout. Por eso el síntoma de una política de red faltante es un **cuelgue**, no un rechazo, y por eso "da timeout" debería llevarte inmediatamente a revisar la política.

Una denegación L7 es lo opuesto: la conexión se *establece* contra el proxy Envoy (el TCP tuvo éxito), Envoy parsea la request y devuelve un **error de capa de aplicación** — `403 Access denied` — de inmediato. Falla rápida y explícita en L7; falla lenta y silenciosa en L3/L4. La *forma* de la falla te dice qué capa te denegó antes de que ejecutes un solo comando.

**A4.4 —** Los endpoints de Cilium son **default-allow hasta que son seleccionados por al menos una política en esa dirección**. `deathstar` es seleccionado por el `endpointSelector` de `rule1`, así que ingress pasa a default-deny-con-excepciones para ese endpoint. `tiefighter` no es seleccionado por nada, así que queda completamente abierto — incluido egress, que ninguna regla de este ejercicio restringe.

El riesgo operativo es que **la cobertura es invisible en el YAML de la política**. Escribir 40 políticas excelentes no prueba nada sobre los pods que ninguna de ellas selecciona; esos siguen totalmente permisivos y ninguna revisión de políticas lo mostrará. La auditoría que realmente necesitás es `cilium-dbg endpoint list` (o `cilium_policy_endpoint_enforcement_status`) buscando `Disabled`, más una línea base de default-deny a nivel de namespace para que *olvidarse* de una política falle cerrado en lugar de abierto.

**A4.5 —** `cilium-dbg bpf policy get <endpoint-id>` en cada endpoint que la política selecciona, y leé las columnas **`BYTES` y `PACKETS`** de las entradas que esa regla genera. Son contadores de mapas eBPF incrementados en cada coincidencia, así que una regla que muestra `PACKETS 0` en todas las réplicas durante un período más largo que tu ciclo de negocio más largo (jobs batch, reportes mensuales, failover de DR) está genuinamente sin uso. Eso es evidencia; "nadie se acuerda por qué está ahí" no lo es. Salvedad: los contadores se reinician cuando el endpoint se regenera (reinicio del pod, cambio de política, reinicio del agente), así que muestreá a lo largo del tiempo en vez de leer una sola vez — y confirmá en todos los endpoints seleccionados, no solo en uno.

**A4.6 —** Usá `cilium-dbg monitor` cuando necesitás **detalle por debajo de Hubble en un solo nodo**. Dos cosas que te da y Hubble no:
1. **Eventos de depuración internos del datapath** — `--type debug`, `--type capture`, y eventos de traza con el **archivo y número de línea** de eBPF (`file bpf_lxc.c line 2091`), lo que señala *dónde en el datapath* murió un paquete.
2. **Salida cruda y sin agregar a nivel de paquete**, incluyendo eventos que Hubble filtra o agrega, más `--hex` para los bytes reales.

La desventaja: es **local al nodo y sin agregación** — sin vista a nivel de clúster, sin enriquecimiento de pod/namespace de Kubernetes más allá de las identidades, sin consulta histórica (es solo un tail en vivo), y en un nodo con carga el volumen es inusable sin filtros ajustados. Hubble es la herramienta el 95% de las veces; `monitor` es el escalón siguiente cuando Hubble dice "dropped" y necesitás saber qué línea de C lo hizo.

### Ejercicio 5

**A5.1 —** Una regla `http:` hace que Cilium instale una **redirección al proxy** en el mapa de política eBPF del endpoint: el tráfico que matchea ya no se reenvía directo al endpoint sino que se redirige al **proxy L7 Envoy**, que termina la conexión, parsea HTTP, aplica la regla, y vuelve a originar hacia el backend. Lo probás desde la CLI con `cilium-dbg bpf policy get <endpoint-id>` leyendo la columna **`PROXY PORT`**: es `NONE` para reglas L3/L4 puras y un puerto real (p. ej. `17423`) una vez que existe una redirección. Corroboralo con `cilium-dbg proxy status` (lista los puertos de proxy asignados y las redirecciones).

**A5.2 —** Ver A4.3. En L7 el handshake TCP **tiene éxito** — contra Envoy, no contra el backend — así que el cliente tiene una conexión viva y Envoy puede responderle con un `403 Access denied` explícito en el instante en que parsea el método/path no permitido. En L3/L4 el SYN se descarta en eBPF sin nada que responda, así que al cliente solo le queda el timeout.

**A5.3 —** **Ningún paquete fue descartado por eBPF.** `DROPPED` en un evento `http-request` significa *que el proxy L7 rechazó la request*: la conexión TCP se estableció, la request se parseó y se rechazó, y se devolvió un HTTP 403. El campo de veredicto es vocabulario compartido entre capas, así que la misma palabra describe dos eventos mecánicamente distintos. Los distinguís por el **tipo de evento**: `--type drop` es un descarte del datapath con un `drop_reason`; `--type l7` con `DROPPED` es un rechazo del proxy sin `drop_reason`. Confundir ambos te manda a buscar una falla de red que no existe.

**A5.4 —** Porque la latencia solo es *conocible* una vez que llega la respuesta. Envoy marca la hora de la request al reenviarla y calcula el tiempo transcurrido cuando vuelve la respuesta correspondiente; esa duración solo se puede adjuntar al evento de respuesta. Un evento de request que nunca recibe una respuesta correspondiente por lo tanto no tiene latencia alguna — lo cual es en sí mismo una señal útil: las requests sin respuesta son tus timeouts y tus backends colgados.

**A5.5 —** Una regla L7 permisiva de todo — tiene que estar presente para instanciar el proxy, pero no debe restringir nada:

```yaml
    rules:
      http:
        - {}
```

(equivalentemente, una regla sin restricciones de `method`/`path`/`headers`, que matchea toda request HTTP). Los dos costos que aceptás:
1. **Latencia y CPU** — cada paquete en ese puerto ahora hace un ida y vuelta por un proxy Envoy en espacio de usuario en vez de quedarse en eBPF; lo mediste en el paso 8. Además convierte a Envoy en un nuevo dominio de falla en el camino de datos.
2. **Cambio semántico de la conexión** — la conexión TCP del cliente ahora termina en el proxy. Cualquier cosa que dependa del comportamiento TCP punta a punta (visibilidad del puerto de origen, algunas semánticas de keepalive/timeout, tráfico no-HTTP que accidentalmente esté en ese puerto siendo rechazado como malformado) puede cambiar. "Solo visibilidad" nunca es realmente gratis.

### Ejercicio 6

**A6.1 —** La regla `dns:` bajo `toPorts` instancia el **proxy DNS** de Cilium. Sin él, DNS es solo UDP/53 hacia el datapath — Cilium ve un paquete UDP al puerto 53 y nada de su contenido, así que no hay ningún evento `dns-request`/`dns-response` que reportar. La regla `matchPattern: "*"` redirige el DNS al proxy, que parsea la consulta y la respuesta, emite flujos L7 de DNS, y puebla la caché de FQDN contra la que se aplican las reglas `toFQDNs`. Notá el acoplamiento que vale la pena recordar: **`toFQDNs` no funciona sin una regla DNS** que enrute las resoluciones relevantes por el proxy — esa omisión es uno de los bugs de `toFQDNs` más comunes en el campo.

**A6.2 —** La política permite explícitamente DNS hacia kube-dns para **todos** los patrones (`matchPattern: "*"`), así que la resolución de `www.example.com` está permitida y se responde normalmente. La *conexión* a la IP resuelta es una decisión aparte: ninguna regla `toFQDNs` ni `toCIDR` cubre `www.example.com`, así que aplica default-deny en egress y el SYN se descarta con `policy-verdict:none EGRESS DENIED`.

La lección para "el DNS funciona pero la app no se puede conectar": **la resolución de nombres y la alcanzabilidad las aplican dos reglas distintas**, y un `nslookup` exitoso desde dentro del pod no prueba nada sobre conectividad. Depuralos por separado — `hubble observe --protocol dns --from-pod X` para resolución, `hubble observe --type policy-verdict --from-pod X` para alcanzabilidad.

**A6.3 —** `16777217` está en el **rango de identidades locales (derivadas de CIDR/FQDN)** — identidades asignadas localmente por el agente del nodo cuando una política necesita una identidad más específica que `reserved:world` para un CIDR particular o una IP resuelta por FQDN. Diferencias con `reserved:world` (ID 2):
- Alcance: `reserved:world` es una identidad reservada fija a nivel de clúster; las identidades locales se **asignan por nodo** y solo tienen sentido en ese nodo.
- Especificidad: `reserved:world` significa "cualquier dirección externa desconocida"; una identidad local significa "este CIDR/FQDN específico que una política referenció", permitiendo allow/deny preciso y atribución de flujos precisa.

En la práctica: cuantas más reglas `toCIDR`/`toFQDNs` escribís, más tráfico externo tuyo deja de ser un bloque indiferenciado de `world` en Hubble y pasa a estar nombrado individualmente.

**A6.4 —** De la **caché de FQDN del proxy DNS** (`cilium-dbg fqdn cache list`), poblada cuando el proxy observó el `dns-response`. Hubble enriquece los flujos a esa IP con el nombre que resolvió a ella, que es por lo que `--fqdn` matchea un flujo cuyo campo de destino es una IP pelada.

Después de que expira el TTL, la entrada de caché se desaloja (sujeto a `tofqdns-min-ttl` y a la configuración de recolección de basura de DNS, que deliberadamente retiene entradas más tiempo que un TTL upstream corto para evitar derribar conexiones vivas). Una vez desalojada, los flujos posteriores a esa IP pierden la asociación con el nombre y aparecen como una IP pelada con identidad `world` o local — y, lo que es importante, la política `toFQDNs` deja de permitirlos hasta que el pod vuelva a resolver. Este es precisamente el mecanismo detrás de A6.5.

**A6.5 —** Las dos causas más probables:
1. **DNS que evita el proxy** — la aplicación cachea DNS por su cuenta (`networkaddress.cache.ttl=-1` en la JVM, un resolver sidecar, una entrada hardcodeada en `/etc/hosts`, o un pool de conexiones que retiene una IP de antes de que existiera la política). El proxy nunca ve una consulta, la entrada de la caché de FQDN expira, y la conexión a la IP aún válida se deniega.
2. **Un TTL upstream corto combinado con un servicio multi-IP / de respuestas rotativas** (CDNs, `www.cncf.io` detrás de Cloudflare). El pod resuelve y obtiene el conjunto de IPs A; la caché retiene A; una conexión posterior usa una IP del conjunto B obtenida en otro lado, o el TTL expira entre la resolución y la conexión.

El comando que las distingue: `hubble observe --protocol dns --from-pod default/tiefighter --since 10m`. Si **no ves eventos `dns-request`** inmediatamente antes del SYN denegado, es la causa 1 — la app no está preguntando, así que el proxy no puede aprender. Si ves la consulta y la respuesta pero el SYN denegado va a una IP que *no* está en esa respuesta (contrastá con `cilium-dbg fqdn cache list`), es la causa 2. Los arreglos difieren por completo: la causa 1 necesita un cambio de aplicación/TTL; la causa 2 necesita un `tofqdns-min-ttl` más alto, un `matchPattern` que cubra todo el dominio, o un fallback por CIDR.

### Ejercicio 7

**A7.1 —** Se construye a partir del **tráfico observado** — el mapa es un renderizado del stream de flujos de Hubble, dibujado a partir de los flujos que Relay tiene actualmente. No es ni el catálogo de Services ni el grafo de políticas. La implicación es importante y frecuentemente malentendida: **un servicio que no recibe tráfico no aparece en el mapa, y tampoco uno cuyo tráfico ya envejeció fuera del ring buffer.** Su ausencia del mapa de servicios no es evidencia de que la dependencia no exista — solo de que no se observó ningún flujo en la ventana retenida. Nunca lo uses para concluir "nada habla con esto, es seguro borrarlo".

**A7.2 —** Hubble UI es la herramienta equivocada porque renderiza solo lo que está en el **ring buffer en memoria**, que en un clúster real son segundos a minutos de histórico — no 30 días. Además no tiene exportación, no tiene lenguaje de consulta, y no garantiza completitud (ver `hubble_lost_events_total`).

Qué construir en su lugar: habilitá la **exportación de flujos de Hubble** (Ejercicio 9) con una máscara de campos que retenga identidad de workload origen/destino y veredicto, enviá los archivos fuera del nodo con tu agente de logs hacia un almacén consultable (Loki/Elasticsearch/S3+Athena/un pipeline OTel), y generá el grafo de dependencias a partir de eso. Complementalo con `hubble_flows_processed_total` en Prometheus para la vista agregada, que retiene mucho más que el buffer y es barata. Las preguntas de auditoría necesitan un almacén durable; Hubble es la vista en vivo por encima de él.

**A7.3 —** Dos causas de configuración:
1. **El backend de la UI no puede alcanzar a Relay** — dirección de servicio `hubble.ui.backend` incorrecta, una NetworkPolicy en `kube-system` bloqueando la conexión gRPC del backend de la UI a `hubble-relay:80`, o material TLS desalineado tras una rotación de certificados. Revisá `kubectl -n kube-system logs deploy/hubble-ui -c backend`.
2. **RBAC / alcance de namespace** — la ServiceAccount del backend de la UI no tiene permiso para listar pods y services en ese namespace, así que no puede enriquecer ni renderizar los flujos aunque Relay los esté transmitiendo. La UI muestra un mapa vacío en vez de un error.

   Una tercera que vale la pena conocer: tu `hubble observe` puede estar leyendo una ventana de tiempo *distinta* — la UI transmite en vivo, así que un namespace cuyo tráfico se detuvo hace minutos aparece vacío mientras que `--last N` todavía devuelve flujos del buffer.

### Ejercicio 8

**A8.1 —** cilium-agent **9962**, cilium-operator **9963**, cilium-envoy **9964**, Hubble **9965**. Son los valores por defecto del chart y vale la pena memorizarlos — el examen los pregunta.

**A8.2 —**
- `hubble_drop_total` la computa el **handler de métricas de Hubble a partir del stream de flujos**, así que lleva contexto rico de Kubernetes: workload/namespace/pod de origen y destino, protocolo, y el motivo del descarte. Responde *a quién* le descartaron.
- `cilium_drop_count_total` la exporta el **agente a partir de contadores del datapath**, con solo las etiquetas `direction` y `reason`. Responde *cuánto y por qué*, sin idea de quién.

`cilium_drop_count_total` **sobrevive a que Hubble esté deshabilitado** — es una métrica del agente, independiente del observer. Eso la vuelve la base correcta para una alerta de línea base de "¿se está descartando algo?" que sigue funcionando aunque el plano de observabilidad se degrade, con `hubble_drop_total` como capa de enriquecimiento para el triaje.

**A8.3 —** Con un HPA, los pods se crean y destruyen continuamente y cada uno recibe una **IP nueva, que no se reutiliza pronto**. `labelsContext=source_ip` por lo tanto acuña una **nueva serie temporal por cada pod que haya existido alguna vez**, y Prometheus nunca olvida una serie dentro de su retención — la cardinalidad crece monótonamente con la cantidad de eventos de escalado, no con la cantidad de servicios. Este es el camino clásico a un Prometheus muerto por OOM. Peor aún, las series son inútiles: nadie consulta por una IP que vivió cuatro minutos.

Usá **`source_workload`** (y `destination_workload`), que es estable por Deployment/StatefulSet — cardinalidad proporcional a la cantidad de workloads, que es sobre lo que realmente razonás. `source_namespace`/`destination_namespace` son igualmente seguras. Reservá el detalle a nivel de IP para el log de flujos, donde el costo por evento está acotado, en vez del almacén de métricas, donde el costo por serie es para siempre.

**A8.4 —** Significa que el **observer de Hubble no pudo seguirle el ritmo al datapath**: se produjeron eventos en el perf ring buffer más rápido de lo que el observer los consumió, y el kernel los sobrescribió. Físicamente, se perdieron datos de flujo de forma irrecuperable — tu observabilidad tiene agujeros, en silencio, exactamente cuando la carga es más alta. Dos arreglos:
1. **Aumentar `hubble.eventBufferCapacity`** (y el buffer del monitor subyacente). Contrapartida: más memoria del agente por nodo, linealmente; compra margen para ráfagas pero no ayuda ante sobrecarga sostenida.
2. **Reducir el volumen de eventos** — habilitar agregación del monitor (`monitor-aggregation: medium|maximum`, que suprime eventos de traza repetidos para conexiones establecidas), o acotar lo que se captura. Contrapartida: perdés granularidad por paquete, así que cierto detalle de corta duración o a nivel de retransmisión se vuelve invisible; la agregación `maximum` en particular vuelve inadecuados los conteos de flujos para contabilidad precisa de paquetes.

De cualquier manera, alertá sobre esta métrica. Un sistema de observabilidad que pierde datos en silencio es peor que uno que está honestamente caído.

**A8.5 —** `enableOpenMetrics: true` cambia la exposición al formato **OpenMetrics**, que soporta **exemplars** — un trace ID adjunto a una muestra individual dentro de un bucket de histograma. Con `exemplars=true` en `httpV2`, una request lenta en el bucket p99 de `hubble_http_request_duration_seconds` lleva un puntero a la traza exacta de esa request.

Para que sea útil necesitás un **backend de trazado distribuido** (Tempo, Jaeger, o cualquier almacén compatible con OTel) *y* un Grafana (o equivalente) configurado para enlazar el datasource de métricas con él — más que la aplicación efectivamente propague el contexto de traza. Sin eso, los exemplars son bytes extra inertes en cada scrape. La ganancia cuando están presentes es grande: cierra la brecha entre "la latencia p99 está mal" y "acá está la request específica que fue lenta" en un clic, sin una búsqueda en logs.

### Ejercicio 9

**A9.1 —** El archivo vive **en el sistema de archivos local de cada nodo**, dentro del montaje del agente en `/var/run/cilium/hubble/events.log` (un hostPath bajo `/var/run/cilium` en el nodo). Lo crítico que tenés que configurar fuera de Cilium es un **shipper de logs que recolecte y reenvíe ese archivo fuera del nodo** — Fluent Bit, Vector, Promtail, el agente de nodo de tu proveedor de nube, lo que ya corras. Cilium rota el archivo (`fileMaxSizeMb`, `fileMaxBackups`) y va a sobrescribir alegremente datos viejos; y si el nodo muere, muere el archivo. Exportar sin enviar no es retención, es un buffer un poco más largo.

**A9.2 —** `fieldMask` restringe qué campos del protobuf se escriben en la exportación. Dos beneficios:
1. **Volumen y costo** — un registro de flujo completo es grande; en un clúster con carga, la diferencia entre registros completos y una máscara de diez campos es la diferencia entre terabytes y gigabytes por día de ingesta, que es plata real en cualquier almacén de logs.
2. **Minimización de datos / privacidad** — podés excluir deliberadamente campos que llevan material sensible (URLs HTTP completas con query strings y tokens, headers, IPs de origen sujetas a normas de protección de datos) para que nunca salgan del nodo. Eso a menudo es un requisito de cumplimiento, no una optimización.

**A9.3 —** **No, no podés responderla.** La allowlist conservó solo `DROPPED` y `ERROR`; las conversaciones exitosas con el servicio de pagos fueron `FORWARDED` y nunca se escribieron. El buffer que las contenía dio la vuelta en segundos, en julio.

Para responderla habrías tenido que exportar también los flujos `FORWARDED` — con un alcance realista, p. ej. una entrada de allowlist restringida al namespace de pagos, con un `fieldMask` limitado a time/source/destination/verdict y la agregación del monitor subida para que las conexiones establecidas no emitan registros por paquete. El costo es **volumen**: el tráfico reenviado supera a los descartes por órdenes de magnitud, así que esto multiplica el gasto de ingesta, almacenamiento y egreso, y pone más presión sobre el observer (ver `hubble_lost_events_total`). Esa es la contrapartida que hay que enunciar explícitamente a quien esté pidiendo la capacidad de auditoría — la retención de "todo" es una decisión de presupuesto, no un flag de configuración.

**A9.4 —** Los flujos de Hubble en un sysdump vienen del mismo **ring buffer en memoria**, así que el snapshot llega hacia atrás solo hasta donde ese buffer retenga — segundos a unos pocos minutos en un nodo con carga, acotado por `eventBufferCapacity` dividido por la tasa de flujos. La implicación es operativa y no obvia: **ejecutá `cilium sysdump` como una de las primeras acciones durante un incidente, no como parte del post-mortem.** Para cuando terminaste de triar, los flujos que explican el incidente ya fueron desalojados, y el sysdump que recolectás una hora después contiene un registro perfecto de la recuperación y nada de la falla. (Todo lo *demás* en un sysdump — políticas, estado de endpoints, logs del agente, salida de bugtool — envejece mucho mejor; son específicamente los flujos lo perecedero.)

### Ejercicio 10

**A10.1 —** Dos fallas independientes:

1. **Puerto equivocado: la política permite `8080`, el servicio y el pod escuchan en `80`.** Evidencia: `hubble observe --type policy-verdict --to-label class=deathstar` muestra `policy-verdict:none INGRESS DENIED (TCP Flags: SYN)`, emparejado con un evento `Policy denied DROPPED` cuyo `drop_reason_desc` es `POLICY_DENIED`. La denegación es sobre el **SYN**, es decir antes de cualquier dato de aplicación — que es la firma de un desajuste L3/L4, no de uno L7. Detalle confirmatorio: `cilium-dbg bpf policy get 184` lista una entrada allow para `8080/TCP` y nada para `80/TCP`.

2. **Método HTTP equivocado: la política permite `GET /v1/request-landing`, el cliente envía `POST`.** Esta falla queda *enmascarada* por la primera — ninguna conexión llega jamás al proxy, así que no produce evidencia alguna hasta que se corrija la falla 1. Tras corregir el puerto, el mismo `curl` produce `http-request DROPPED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)` y el cliente recibe `Access denied`.

   La lección general, y la razón por la que el simulacro está ordenado así: **las fallas en capas inferiores esconden fallas en capas superiores.** Arreglá y verificá una capa a la vez; una única observación de "sigue roto" después de un arreglo no significa que el arreglo estuviera mal.

**A10.2 —** Solo la **falla 2** es visible en `hubble observe --protocol http`. La falla 1 es invisible ahí porque el SYN se descarta en eBPF antes de que la conexión se establezca, así que nunca se redirige al proxy Envoy — y sin proxy no hay ningún evento L7 de ninguna clase. La falla 1 vive exclusivamente en `--type policy-verdict` y `--type drop`. Esta es la formulación práctica del apilamiento de capas: **una salida vacía de `--protocol http` durante una caída es en sí misma un hallazgo**, y te dice que la falla está por debajo de L7.

**A10.3 —**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: incident-10
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
```

Ambas correcciones: `8080` → `80`, y `GET` → `POST`.

**A10.4 —**

```bash
hubble observe --protocol http --to-label class=deathstar \
  --http-path /v1/request-landing --last 20 -o json \
  | jq -r 'select(.verdict=="DROPPED") | "STILL BLOCKED: \(.l7.http.method) \(.l7.http.url)"'
```

— se espera que no imprima nada, con el correspondiente `hubble observe --protocol http --last 5` mostrando `http-request FORWARDED` y `http-response FORWARDED (HTTP/1.1 200 ...)`.

Un código de salida de `curl` es insuficiente por tres razones:
1. **Una denegación L7 devuelve `403 Access denied` en el cuerpo de la respuesta con una transacción HTTP exitosa**, así que `curl` a secas sale con **0** — la request fue rechazada pero la herramienta reporta éxito. Declararías victoria sobre una política todavía rota.
2. Confunde modos de falla: el exit 28 (timeout) podría ser la política, un backend caído, una tabla de conntrack llena, o DNS — el código de salida no puede decirte cuál, mientras que el tipo de evento y el veredicto del flujo sí.
3. Prueba un paquete de un cliente en un instante. La consulta de Hubble prueba lo que el **plano de enforcement realmente decidió**, en cada réplica y en cada request reciente, que es lo que estás tratando de verificar.

El principio general, y el que vale la pena llevarse al examen: **verificá los cambios de política de red con el veredicto del plano de observabilidad, no con el síntoma de la aplicación.** El síntoma es una proyección con pérdidas y ambigua del veredicto.

</details>