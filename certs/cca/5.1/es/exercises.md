# Asegurar cargas de trabajo con Cilium — Ejercicios guiados

**Certificación:** Cilium Certified Associate (CCA) · **Dominio 5.1** · **Peso en el examen: 20%**

> Estos ejercicios están escritos para ejecutarse de punta a punta en un cluster descartable. Todos los comandos son reales, todos los manifiestos están completos y son sintácticamente válidos, y todas las salidas esperadas son representativas de una instalación de Cilium 1.16/1.17. Donde la salida difiere entre versiones, se lo señala en línea.
>
> **Nombre del binario:** desde Cilium v1.16 el binario de depuración dentro del agente es `cilium-dbg`. En v1.15 y anteriores los mismos comandos están disponibles como `cilium` dentro del pod del agente. La CLI del *host* (`cilium status`, `cilium connectivity test`) es un binario distinto y conserva el nombre `cilium`.

---

## Ejercicio 0 — Entorno de laboratorio y línea base

### Pasos

1. Creá un cluster kind sin CNI y sin kube-proxy, de modo que Cilium sea dueño de todo el datapath:

   ```bash
   cat <<'EOF' > kind-cca.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: cca
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   networking:
     disableDefaultCNI: true
     kubeProxyMode: none
     podSubnet: "10.244.0.0/16"
     serviceSubnet: "10.96.0.0/16"
   EOF

   kind create cluster --config kind-cca.yaml
   ```

2. Instalá Cilium con el conjunto de funcionalidades que este dominio requiere. Notá que Hubble, el proxy L7 y el proxy FQDN son lo que vuelve la política *verificable*, no solo *declarable*:

   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm repo update

   helm install cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system \
     --set kubeProxyReplacement=true \
     --set k8sServiceHost=cca-control-plane \
     --set k8sServicePort=6443 \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true \
     --set hubble.metrics.enableOpenMetrics=true \
     --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2}" \
     --set l7Proxy=true \
     --set policyEnforcementMode=default
   ```

3. Esperá a la convergencia y leé la matriz de funcionalidades:

   ```bash
   cilium status --wait
   ```

   Esperado (abreviado):

   ```
       /¯¯\
    /¯¯\__/¯¯\    Cilium:             OK
    \__/¯¯\__/    Operator:           OK
    /¯¯\__/¯¯\    Envoy DaemonSet:    OK
    \__/¯¯\__/    Hubble Relay:       OK
       \__/       ClusterMesh:        disabled

   DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
   Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
   Containers:            cilium             Running: 3
                          hubble-relay       Running: 1
   Cluster Pods:          6/6 managed by Cilium
   ```

4. Inspeccioná la visión que el propio agente tiene de las funcionalidades de seguridad habilitadas:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | \
     grep -A6 -E 'Policy|Proxy|Encryption'
   ```

   Esperado (abreviado):

   ```
   Encryption:              Disabled
   Policy enforcement:      default
   Proxy Status:            OK, ip 10.244.1.180, 0 redirects active on ports 10000-20000, Envoy: external
   ```

5. Desplegá la aplicación de demostración canónica (una API HTTP con tres consumidores):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/1.17.1/examples/minikube/http-sw-app.yaml
   kubectl get pods -L app.kubernetes.io/name,class,org
   ```

   Esperado:

   ```
   NAME                         READY   STATUS    NAME         CLASS        ORG
   deathstar-8484d6f69c-7xk4t   1/1     Running   deathstar    deathstar    empire
   deathstar-8484d6f69c-p9dvn   1/1     Running   deathstar    deathstar    empire
   tiefighter                   1/1     Running   tiefighter   tiefighter   empire
   xwing                        1/1     Running   xwing        xwing        alliance
   ```

6. Demostrá que el cluster está completamente abierto antes de que exista cualquier política:

   ```bash
   kubectl exec xwing      -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Esperado — **ambos** tienen éxito:

   ```
   Ship landed
   Ship landed
   ```

### Comprobación de comprensión — Bloque 0

* **Q0.1** — `policyEnforcementMode=default` se fijó explícitamente. ¿Cuáles son los tres valores legales, y qué le hace cada uno a un endpoint que *no* está seleccionado por ninguna política?
* **Q0.2** — El cluster se creó con `kubeProxyMode: none`. ¿Qué funcionalidad de seguridad de Cilium se degradaría silenciosamente si kube-proxy *estuviera* presente y manejara la traducción de Service antes de que Cilium vea el paquete?
* **Q0.3** — `Proxy Status` informa `Envoy: external`. ¿Cuál es la diferencia entre el Envoy embebido y el externo (DaemonSet), y por qué el modo DaemonSet importa para el radio de impacto de una política L7?
* **Q0.4** — ¿Por qué `xwing` puede alcanzar a `deathstar` en el paso 6 aunque los dos pods llevan etiquetas `org` completamente distintas?

---

## Ejercicio 1 — El modelo de identidad: etiquetas, no IPs

Este es el núcleo conceptual del dominio. Cilium no escribe reglas de firewall por IP; deriva una **identidad de seguridad numérica** a partir de las etiquetas *relevantes para la seguridad* del pod y aplica la política entre identidades en mapas eBPF.

### Pasos

1. Listá las identidades de seguridad que Cilium asignó:

   ```bash
   kubectl get ciliumidentities -o custom-columns=\
   'ID:.metadata.name,NS:.security-labels.k8s\:io\.kubernetes\.pod\.namespace,LABELS:.security-labels'
   ```

   Esperado (abreviado):

   ```
   ID      NS            LABELS
   4711    default       map[k8s:app.kubernetes.io/name:deathstar k8s:class:deathstar k8s:io.cilium.k8s.policy.cluster:default k8s:io.cilium.k8s.policy.serviceaccount:default k8s:io.kubernetes.pod.namespace:default k8s:org:empire]
   9034    default       map[... k8s:class:tiefighter ... k8s:org:empire]
   25871   default       map[... k8s:class:xwing ... k8s:org:alliance]
   ```

2. Mapeá pods a identidades a través del objeto `CiliumEndpoint` (CEP) — uno por pod:

   ```bash
   kubectl get cep -o wide
   ```

   Esperado:

   ```
   NAME                         ENDPOINT ID   IDENTITY ID   INGRESS ENFORCEMENT   EGRESS ENFORCEMENT   IPV4          STATUS
   deathstar-8484d6f69c-7xk4t   1204          4711          false                 false                10.244.1.51   ready
   deathstar-8484d6f69c-p9dvn   3310          4711          false                 false                10.244.2.19   ready
   tiefighter                   776           9034          false                 false                10.244.1.94   ready
   xwing                        2295          25871         false                 false                10.244.2.77   ready
   ```

3. Confirmá que **dos réplicas del mismo Deployment comparten una sola identidad** — por eso la política escala con la cantidad de *conjuntos de etiquetas*, no con la cantidad de pods:

   ```bash
   kubectl get cep -l class=deathstar \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.identity.id}{"\n"}{end}'
   ```

   Esperado:

   ```
   deathstar-8484d6f69c-7xk4t   4711
   deathstar-8484d6f69c-p9dvn   4711
   ```

4. Inspeccioná las identidades reservadas, que representan tráfico sin un pod detrás:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list | head -20
   ```

   Esperado:

   ```
   ID     LABELS
   1      reserved:host
   2      reserved:world
   3      reserved:unmanaged
   4      reserved:health
   5      reserved:init
   6      reserved:remote-node
   7      reserved:kube-apiserver
   8      reserved:ingress
   4711   k8s:app.kubernetes.io/name=deathstar
          k8s:class=deathstar
          ...
   ```

5. Demostrá que no toda etiqueta es relevante para la seguridad. Agregá una etiqueta con forma de anotación y observá que la identidad **queda igual**, y después agregá una etiqueta bajo un namespace que *sí* es relevante:

   ```bash
   # Default configuration ignores nothing by default, but pod-template-hash IS excluded.
   kubectl get cep deathstar-8484d6f69c-7xk4t -o jsonpath='{.status.identity.labels}' | tr ';' '\n'
   ```

   Esperado — notá la **ausencia** de `pod-template-hash`:

   ```
   k8s:app.kubernetes.io/name=deathstar
   k8s:class=deathstar
   k8s:io.cilium.k8s.policy.cluster=default
   k8s:io.cilium.k8s.policy.serviceaccount=default
   k8s:io.kubernetes.pod.namespace=default
   k8s:org=empire
   ```

6. Forzá un cambio de identidad mutando una etiqueta relevante para la seguridad, y observá la rotación:

   ```bash
   kubectl label pod xwing org=empire --overwrite
   sleep 3
   kubectl get cep xwing -o jsonpath='{.status.identity.id}{"\n"}'
   kubectl label pod xwing org=alliance --overwrite
   ```

   El ID de identidad cambia (se asigna una identidad nueva o se reutiliza una existente).

### Comprobación de comprensión — Bloque 1

* **Q1.1** — Dos pods en *namespaces distintos* llevan el mismo conjunto de etiquetas de aplicación (`class=api, org=empire`). ¿Comparten identidad de seguridad? Justificá usando la lista de etiquetas del paso 5.
* **Q1.2** — Un Deployment se escala de 3 a 300 réplicas. ¿Cuántos objetos `CiliumIdentity` nuevos se crean, y qué implica eso para el tamaño del mapa de política eBPF?
* **Q1.3** — ¿Por qué se excluye deliberadamente `pod-template-hash` del cálculo de identidad? ¿Qué se rompería durante un rolling update si se lo incluyera?
* **Q1.4** — Una política permite `reserved:remote-node`. Nombrá un modo de falla concreto que introducirías si en cambio escribieras `reserved:host` en un cluster multinodo.
* **Q1.5** — Cilium asigna identidades de alcance de cluster desde el ID 256 hacia arriba, pero las identidades derivadas de CIDR y de FQDN viven en un rango *local* (de alcance de nodo). ¿Por qué una identidad CIDR no puede ser de alcance de cluster?

---

## Ejercicio 2 — Política L3/L4 y semántica de denegación por defecto

### Pasos

1. Aplicá una política de ingress que admita solo `org=empire` en TCP/80:

   ```yaml
   # 01-l3l4-ingress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l4
     namespace: default
   spec:
     description: "L3/L4: only empire ships may reach the deathstar HTTP port"
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
   kubectl apply -f 01-l3l4-ingress.yaml
   kubectl get cnp rule1-deathstar-l4
   ```

2. Volvé a probar ambos consumidores:

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec xwing      -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Esperado:

   ```
   Ship landed
   command terminated with exit code 28      # xwing: curl timeout, the packet was dropped
   ```

3. Observá el cambio de enforcement en el endpoint:

   ```bash
   kubectl get cep -o wide
   ```

   Esperado:

   ```
   NAME                         ENDPOINT ID   IDENTITY ID   INGRESS ENFORCEMENT   EGRESS ENFORCEMENT   IPV4
   deathstar-8484d6f69c-7xk4t   1204          4711          true                  false                10.244.1.51
   tiefighter                   776           9034          false                 false                10.244.1.94
   xwing                        2295          25871         false                 false                10.244.2.77
   ```

4. Leé la política compilada directamente del mapa eBPF en el nodo donde corre `deathstar`:

   ```bash
   POD=deathstar-8484d6f69c-7xk4t
   NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')
   AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
             --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
   EPID=$(kubectl get cep "$POD" -o jsonpath='{.status.id}')

   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Esperado:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                  PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS   PREFIX
   Allow    Ingress     4711       reserved:unknown                             ANY          NONE         disabled    0       0         0
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire          80/TCP       NONE         disabled    862     11        0
   Allow    Egress      0          reserved:unknown                             ANY          NONE         disabled    4210    36        0
   ```

5. Verificá el descarte con Hubble:

   ```bash
   cilium hubble port-forward &
   hubble observe --pod default/xwing --verdict DROPPED --last 5
   ```

   Esperado:

   ```
   Sep  1 12:04:11.220: default/xwing:41022 (ID:25871) <> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) Policy denied DROPPED (TCP Flags: SYN)
   ```

6. Ahora agregá una regla de **egress** para `tiefighter` y observá que agregar *cualquier* regla de egress convierte el egress en denegación por defecto para ese endpoint — incluido DNS:

   ```yaml
   # 02-egress-trap.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule2-tiefighter-egress
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 02-egress-trap.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Esperado — **ahora falla**:

   ```
   curl: (6) Could not resolve host: deathstar.default.svc.cluster.local
   command terminated with exit code 6
   ```

7. Confirmá la causa y corregila:

   ```bash
   hubble observe --pod default/tiefighter --verdict DROPPED --last 5
   ```

   ```
   Sep  1 12:07:55.001: default/tiefighter:52310 (ID:9034) <> kube-system/coredns-xxxx:53 (ID:15410) Policy denied DROPPED (UDP)
   ```

   ```yaml
   # 02-egress-fixed.yaml — append this rule to spec.egress of rule2-tiefighter-egress
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule2-tiefighter-egress
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
       - toEndpoints:
           - matchLabels:
               io.kubernetes.pod.namespace: kube-system
               k8s-app: kube-dns
         toPorts:
           - ports:
               - port: "53"
                 protocol: ANY
   ```

   ```bash
   kubectl apply -f 02-egress-fixed.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed
   ```

### Comprobación de comprensión — Bloque 2

* **Q2.1** — En el paso 3, el `INGRESS ENFORCEMENT` de `xwing` es `false` aunque su tráfico está siendo descartado. ¿Dónde ocurre realmente el descarte, y por qué esa es la respuesta correcta para un datapath distribuido?
* **Q2.2** — Reformulá con precisión la regla de denegación por defecto. Completá la oración: *"Un endpoint entra en denegación por defecto para la dirección D apenas ______."*
* **Q2.3** — En la salida de `bpf policy get` hay una entrada `Allow Ingress` para la identidad `4711` (la identidad del propio endpoint) con `PORT/PROTO ANY`. ¿Qué es esa entrada, y sería seguro eliminarla?
* **Q2.4** — El paso 6 es la caída en producción más común causada por política de Cilium. Enunciá la falla en una oración y nombrá **dos** remedios correctos distintos (uno a nivel de política, uno a nivel de cluster).
* **Q2.5** — La regla de permiso de DNS usa `protocol: ANY` en lugar de `UDP`. Dá un escenario concreto en el que restringirla a UDP rompe la resolución de nombres.
* **Q2.6** — `rule1-deathstar-l4` selecciona `org: empire, class: deathstar`, y `rule2` selecciona `class: tiefighter`. Si borrás `rule1`, ¿`tiefighter` sigue alcanzando a `deathstar`? Explicá en términos de a qué endpoint pone cada regla en denegación por defecto.

---

## Ejercicio 3 — Hacer la política depurable: modo auditoría y Hubble

Casi nunca vas a escribir una política correcta al primer intento contra una aplicación real. El modo auditoría es la forma de desplegarla sin provocar una caída.

### Pasos

1. Poné el endpoint `deathstar` en **modo auditoría de política**:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint config "$EPID" PolicyAuditMode=Enabled
   ```

   Esperado:

   ```
   Endpoint 1204 configuration updated successfully
   ```

2. Confirmá el estado:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint get "$EPID" \
     -o jsonpath='{[0].spec.options.PolicyAuditMode}{"\n"}'
   # Enabled
   ```

3. Reintentá la petición previamente denegada:

   ```bash
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Esperado — **la petición ahora tiene éxito**:

   ```
   Ship landed
   ```

4. Pero la violación se sigue registrando:

   ```bash
   hubble observe --pod default/xwing --last 5
   ```

   Esperado:

   ```
   Sep  1 12:15:02.771: default/xwing:44118 (ID:25871) -> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
   Sep  1 12:15:02.771: default/xwing:44118 (ID:25871) -> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) to-endpoint FORWARDED (TCP Flags: SYN)
   ```

5. Usá Hubble como *generador* de política — recolectá cada flujo que el endpoint realmente recibe, para que la política resultante se derive del comportamiento observado en vez de adivinarse:

   ```bash
   hubble observe --to-pod default/deathstar-8484d6f69c-7xk4t --last 200 -o json |
     jq -r 'select(.flow.verdict=="AUDITED" or .flow.verdict=="FORWARDED")
            | [ (.flow.source.namespace + "/" + (.flow.source.labels | join(","))),
                (.flow.l4.TCP.destination_port // .flow.l4.UDP.destination_port | tostring) ]
            | @tsv' | sort -u
   ```

6. Apagá el modo auditoría y volvé a verificar la denegación:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint config "$EPID" PolicyAuditMode=Disabled
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   # command terminated with exit code 28
   ```

7. Compará los tres valores de `policy-verdict` con los que te podés encontrar:

   ```bash
   hubble observe --to-pod default/deathstar-8484d6f69c-7xk4t --type policy-verdict --last 20
   ```

### Comprobación de comprensión — Bloque 3

* **Q3.1** — `PolicyAuditMode` se fijó por endpoint mediante `cilium-dbg`. ¿Cuál es el alcance y la vida útil de esa configuración, y qué le pasa cuando el pod se reprograma en otro nodo?
* **Q3.2** — Nombrá la forma de habilitar el modo auditoría a nivel de todo el cluster en tiempo de instalación, y explicá por qué la vía por endpoint es la más segura para un cluster en producción.
* **Q3.3** — En el paso 4, Hubble emite *dos* líneas para un solo paquete: `AUDITED` y después `FORWARDED`. Explicá qué representa cada línea en el datapath.
* **Q3.4** — Hubble informa `DROPPED` con motivo `Policy denied`. Enumerá dos *otros* motivos de descarte que Cilium puede informar y que un operador con poca experiencia leería mal como un problema de política.
* **Q3.5** — ¿Por qué `hubble observe` por sí solo es insuficiente para probar que una política es correcta? ¿Qué clase de tráfico nunca te va a mostrar?

---

## Ejercicio 4 — Política HTTP L7 y la redirección a Envoy

La política L3/L4 responde *quién puede hablar con quién*. La política L7 responde *qué pueden decir*.

### Pasos

1. Reemplazá la política L4 por una política L7 que permita solo `POST /v1/request-landing`:

   ```yaml
   # 03-l7-http.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l7
     namespace: default
   spec:
     description: "L7: empire ships may request landing but not fire the superlaser"
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
                 - method: "GET"
                   path: "/v1/healthz"
   ```

   ```bash
   kubectl delete cnp rule1-deathstar-l4
   kubectl apply -f 03-l7-http.yaml
   ```

2. Probá el par verbo/ruta permitido y el prohibido:

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec tiefighter -- curl -sS -m5 -XPUT  deathstar.default.svc.cluster.local/v1/exhaust-port
   ```

   Esperado:

   ```
   Ship landed
   Access denied
   ```

3. Notá la diferencia crucial respecto de un descarte L3/L4 — obtené el código de estado HTTP:

   ```bash
   kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' -m5 \
     -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
   ```

   Esperado:

   ```
   403
   ```

4. Confirmá que la redirección a Envoy ahora existe en el datapath:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Esperado — notá el **PROXY PORT** distinto de cero:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS                                PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire   80/TCP       15039        disabled    1204    16
   ```

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg status | grep Proxy
   # Proxy Status:  OK, ip 10.244.1.180, 1 redirects active on ports 10000-20000, Envoy: external
   ```

5. Leé el registro de flujo L7 — Hubble ahora transporta semántica HTTP:

   ```bash
   hubble observe --pod default/tiefighter --protocol http --last 4
   ```

   Esperado:

   ```
   Sep  1 12:22:40.104: default/tiefighter:33212 (ID:9034) -> default/deathstar:80 (ID:4711) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
   Sep  1 12:22:40.107: default/tiefighter:33212 (ID:9034) <- default/deathstar:80 (ID:4711) http-response FORWARDED (HTTP/1.1 200 2ms)
   Sep  1 12:23:01.550: default/tiefighter:33218 (ID:9034) -> default/deathstar:80 (ID:4711) http-request DROPPED (HTTP/1.1 PUT http://deathstar.default.svc.cluster.local/v1/exhaust-port)
   ```

6. Agregá una restricción basada en cabeceras, que es la forma que toman la mayoría de las políticas reales estilo API gateway:

   ```yaml
   # 04-l7-headers.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l7-headers
     namespace: default
   spec:
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
                 - method: "PUT"
                   path: "/v1/exhaust-port"
                   headers:
                     - "X-Has-Superuser-Token: deathstar-command"
   ```

   ```bash
   kubectl apply -f 04-l7-headers.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
   # Access denied
   kubectl exec tiefighter -- curl -sS -m5 -XPUT \
     -H 'X-Has-Superuser-Token: deathstar-command' \
     deathstar.default.svc.cluster.local/v1/exhaust-port
   # Panic: deathstar exploded   (the request was allowed through)
   ```

### Comprobación de comprensión — Bloque 4

* **Q4.1** — Una denegación L3/L4 produce un timeout TCP; una denegación L7 produce `403`. Explicá la razón, a nivel de datapath, de la diferencia, y enunciá una consecuencia de seguridad del comportamiento L7 (¿qué aprende el atacante?).
* **Q4.2** — Una regla tiene `toPorts` en el puerto 80 **con** un bloque `http`, y una segunda regla en el puerto 80 **sin** él. ¿Cuál es el enforcement resultante en el puerto 80? (Esta es una trampa clásica de examen.)
* **Q4.3** — ¿Por qué una política L7 hace que el *orden* de una actualización progresiva de Cilium sea más delicado que con una política L3/L4? Referite a la línea `Envoy: external` del Ejercicio 0.
* **Q4.4** — Al servicio se lo alcanza como `deathstar.default.svc.cluster.local`, pero el flujo `http-request` muestra la identidad de pod `4711` como destino. ¿En qué punto, respecto de la redirección a Envoy, ocurre la traducción Service→backend?
* **Q4.5** — ¿Podés escribir una política HTTP L7 para una carga de trabajo que sirve HTTPS en el 443 con TLS terminado dentro del pod? ¿Cuáles son tus opciones?

---

## Ejercicio 5 — Egress consciente de DNS (`toFQDNs`) y el proxy DNS

El egress hacia internet no puede expresarse con CIDRs cuando el destino es una API respaldada por CDN. `toFQDNs` resuelve esto, pero solo si el proxy DNS ve la consulta.

### Pasos

1. Desplegá un cliente de prueba con conectividad externa real:

   ```bash
   kubectl run mubuntu --image=nicolaka/netshoot --restart=Never -l app=mubuntu -- sleep infinity
   kubectl wait --for=condition=Ready pod/mubuntu --timeout=60s
   ```

2. Aplicá una política de egress FQDN. **La regla L7 `dns` es obligatoria** — es lo que instala la redirección al proxy DNS que puebla la caché FQDN:

   ```yaml
   # 05-fqdn-egress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: fqdn-allow-github-api
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       # 1. Allow DNS to CoreDNS AND intercept it with the DNS proxy.
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
       # 2. Allow egress only to names that resolved through the proxy.
       - toFQDNs:
           - matchName: "api.github.com"
           - matchPattern: "*.githubusercontent.com"
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 05-fqdn-egress.yaml
   ```

3. Probá un destino permitido y uno denegado:

   ```bash
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w 'github:%{http_code}\n' https://api.github.com
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w 'cilium:%{http_code}\n' https://cilium.io
   ```

   Esperado:

   ```
   github:200
   curl: (28) Connection timed out after 8001 milliseconds
   ```

4. Inspeccioná la caché FQDN — este es el puente entre un nombre y las IPs que el datapath va a aceptar:

   ```bash
   AGENT2=$(kubectl -n kube-system get pod -l k8s-app=cilium \
     --field-selector spec.nodeName=$(kubectl get pod mubuntu -o jsonpath='{.spec.nodeName}') \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg fqdn cache list
   ```

   Esperado:

   ```
   Endpoint   Source   FQDN               TTL    ExpirationTime             IPs
   3891       lookup   api.github.com.    30     2026-09-01T12:31:04.000Z   140.82.121.6
   3891       lookup   raw.githubusercontent.com.   30   2026-09-01T12:31:09.000Z   185.199.108.133,185.199.109.133
   ```

5. Observá los flujos DNS L7:

   ```bash
   hubble observe --pod default/mubuntu --protocol dns --last 6
   ```

   Esperado:

   ```
   Sep  1 12:30:34.001: default/mubuntu:41501 (ID:31122) -> kube-system/coredns-xxx:53 (ID:15410) dns-request proxy FORWARDED (DNS Query api.github.com. A)
   Sep  1 12:30:34.019: kube-system/coredns-xxx:53 (ID:15410) -> default/mubuntu:41501 (ID:31122) dns-response proxy FORWARDED (DNS Answer "140.82.121.6" TTL: 30 (Proxy api.github.com. A))
   Sep  1 12:30:41.700: default/mubuntu:52200 (ID:31122) <> 104.198.14.52:443 (ID:16777219) Policy denied DROPPED (TCP Flags: SYN)
   ```

6. Demostrá el **bypass**, que es la advertencia operativa más importante de `toFQDNs`:

   ```bash
   # Resolve the IP out of band, then connect to it directly with SNI.
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w '%{http_code}\n' \
     --resolve api.github.com:443:1.1.1.1 https://api.github.com
   ```

   Esperado — esto falla, porque `1.1.1.1` nunca pasó por el proxy:

   ```
   curl: (28) Connection timed out
   ```

   Ahora la dirección opuesta — una IP compartida:

   ```bash
   kubectl exec mubuntu -- getent hosts raw.githubusercontent.com
   # 185.199.108.133  raw.githubusercontent.com
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w '%{http_code}\n' \
     -H 'Host: gist.githubusercontent.com' https://185.199.108.133
   ```

7. Verificá la identidad asignada para el CIDR derivado del FQDN:

   ```bash
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg identity list | grep -A2 'cidr:140.82'
   ```

   Esperado:

   ```
   16777224   cidr:140.82.121.6/32
              reserved:world
   ```

### Comprobación de comprensión — Bloque 5

* **Q5.1** — Quitá el bloque `rules: dns:` de la primera regla de egress pero dejá todo lo demás. Predecí exactamente qué le pasa a `curl https://api.github.com`, y explicá por qué.
* **Q5.2** — El paso 6 muestra que `toFQDNs` liga un *nombre* a las *IPs que el proxy observó*. Enunciá la garantía de seguridad que `toFQDNs` realmente te da, y la que **no** te da.
* **Q5.3** — La identidad del paso 7 es `16777224`, muy por encima del rango de identidades de cluster. ¿En qué alcance está esa identidad, y qué se rompe si asumieras que es consistente entre nodos?
* **Q5.4** — Una API externa devuelve un TTL de 30 segundos pero la aplicación cachea DNS en proceso durante 1 hora. Describí la caída que esto provoca y nombrá el ajuste de Cilium que la mitiga.
* **Q5.5** — ¿Por qué `matchPattern: "*"` en la regla DNS no debilita la política, dado que el paso 3 sigue denegando `cilium.io`?
* **Q5.6** — El proxy DNS es un componente en espacio de usuario dentro del proceso `cilium-agent`. ¿Qué pasa con las consultas DNS en vuelo cuando el agente se reinicia, y qué valor de Helm endurece esto?

---

## Ejercicio 6 — Entidades, CIDR y precedencia de las reglas de denegación

### Pasos

1. Expresá "puede alcanzar cualquier cosa fuera del cluster excepto el servicio de metadatos y RFC1918" usando un permiso más una denegación explícita:

   ```yaml
   # 06-world-egress-with-deny.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: egress-world-except-internal
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       - toEntities:
           - world
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
     egressDeny:
       - toCIDR:
           - 169.254.169.254/32          # cloud instance metadata
       - toCIDRSet:
           - cidr: 10.0.0.0/8
             except:
               - 10.244.0.0/16           # keep the pod CIDR reachable
           - cidr: 172.16.0.0/12
           - cidr: 192.168.0.0/16
   ```

   ```bash
   kubectl delete cnp fqdn-allow-github-api
   kubectl apply -f 06-world-egress-with-deny.yaml
   ```

2. Verificá que la denegación le gana al permiso amplio:

   ```bash
   kubectl exec mubuntu -- curl -sS -m4 -o /dev/null -w 'meta:%{http_code}\n' http://169.254.169.254/
   kubectl exec mubuntu -- curl -sS -m6 -o /dev/null -w 'ext:%{http_code}\n'  https://cilium.io
   ```

   Esperado:

   ```
   curl: (28) Connection timed out after 4001 milliseconds
   ext:200
   ```

3. Confirmá la entrada de denegación en el datapath:

   ```bash
   EP2=$(kubectl get cep mubuntu -o jsonpath='{.status.id}')
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg bpf policy get "$EP2" | grep -i deny
   ```

   Esperado:

   ```
   Deny    Egress   16777231   cidr:169.254.169.254/32,reserved:world   ANY   NONE   disabled   0   0   0
   ```

4. Demostrá la distinción entre `world`, `cluster` y `all`:

   ```bash
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg policy get | \
     jq -r '.[].egress[]?.toEntities[]?' 2>/dev/null | sort -u
   ```

5. Agregá una regla explícita de egress a `kube-apiserver` — requerida en cualquier cluster donde las cargas de trabajo hablan con la API (operators, controllers, service meshes):

   ```yaml
   # 07-apiserver-egress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: allow-apiserver
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       - toEntities:
           - kube-apiserver
         toPorts:
           - ports:
               - port: "6443"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 07-apiserver-egress.yaml
   kubectl exec mubuntu -- curl -sSk -m5 -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc/healthz
   # 401     (reachable; 401 is the expected unauthenticated answer)
   ```

### Comprobación de comprensión — Bloque 6

* **Q6.1** — Enunciá en una oración la regla de precedencia entre `egress` y `egressDeny`. ¿Existe alguna regla de permiso — incluidas las L7 — que pueda anular una denegación?
* **Q6.2** — En el paso 1 se usa `toCIDRSet` con `except: 10.244.0.0/16` en lugar de listar muchos CIDRs chicos. Explicá cómo se compila esto y por qué la lista `except` importa para el trie LPM en eBPF.
* **Q6.3** — Distinguí `reserved:world`, `reserved:all`, `reserved:cluster` y `reserved:remote-node`. ¿Cuál incluye silenciosamente el propio namespace de host del nodo?
* **Q6.4** — Una regla `toCIDR: 0.0.0.0/0` y una regla `toEntities: [world]` parecen equivalentes. Nombrá un caso en el que se comportan distinto.
* **Q6.5** — Antes de que existiera la entidad `kube-apiserver`, los operadores escribían `toCIDR` con la IP del API server. Dá dos razones por las que la entidad es estrictamente mejor en un cluster gestionado.
* **Q6.6** — ¿Por qué la denegación del servicio de metadatos (`169.254.169.254`) se considera un control de *línea base* en vez de uno específico de la aplicación? ¿Qué ataque bloquea?

---

## Ejercicio 7 — Política cluster-wide y el firewall del host

`CiliumClusterwideNetworkPolicy` (CCNP) no está en un namespace y es el único objeto que puede llevar un `nodeSelector`, que es la forma de aplicar firewall al **propio nodo**.

### Pasos

1. Establecé una línea base cluster-wide de denegación por defecto que igual permita DNS y health checks — la forma que despliega la mayoría de los equipos de plataforma:

   ```yaml
   # 08-ccnp-baseline.yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata:
     name: baseline-default-deny
   spec:
     description: "Cluster-wide default deny with DNS and health exceptions"
     endpointSelector:
       matchExpressions:
         - key: io.kubernetes.pod.namespace
           operator: NotIn
           values: ["kube-system"]
     ingress:
       - fromEntities:
           - host
           - remote-node
           - health
     egress:
       - toEntities:
           - host
           - remote-node
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

   > **No apliques esto a un cluster de producción sin modo auditoría primero.** Aplicarlo acá va a romper el ingress de la app de demostración hasta que vuelvas a agregar las políticas anteriores.

   ```bash
   kubectl apply -f 08-ccnp-baseline.yaml
   kubectl get ccnp
   ```

2. Habilitá el firewall del host y reiniciá los agentes:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set hostFirewall.enabled=true \
     --set devices='{eth0}'
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Confirmá que el host endpoint ahora existe y *todavía no* está aplicando enforcement:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list | grep -E 'ENDPOINT|reserved:host'
   ```

   Esperado:

   ```
   ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
                ENFORCEMENT        ENFORCEMENT
   1783       Disabled           Disabled          1          reserved:host
   ```

4. **Poné el host endpoint en modo auditoría antes de escribir una sola regla de host.** Este es el paso que evita que te dejes afuera de todos los nodos simultáneamente:

   ```bash
   HOSTEP=$(kubectl -n kube-system exec ds/cilium -- \
     cilium-dbg endpoint list -o jsonpath='{[?(@.status.identity.id==1)].id}')
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config "$HOSTEP" PolicyAuditMode=Enabled
   ```

5. Aplicá una política de host que permita SSH, el kubelet y los puertos del plano de control:

   ```yaml
   # 09-host-firewall.yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata:
     name: host-firewall-workers
   spec:
     description: "Node ingress: SSH, kubelet, VXLAN, health"
     nodeSelector:
       matchLabels:
         node-role.kubernetes.io/worker: ""
     ingress:
       - fromEntities:
           - remote-node
           - health
           - cluster
       - fromCIDR:
           - 10.0.0.0/8
         toPorts:
           - ports:
               - port: "22"
                 protocol: TCP
               - port: "10250"    # kubelet
                 protocol: TCP
               - port: "8472"     # VXLAN
                 protocol: UDP
               - port: "4240"     # cilium health
                 protocol: TCP
   ```

   ```bash
   kubectl label node cca-worker  node-role.kubernetes.io/worker=""
   kubectl label node cca-worker2 node-role.kubernetes.io/worker=""
   kubectl apply -f 09-host-firewall.yaml
   ```

6. Recolectá lo que el modo auditoría habría bloqueado, **antes** de aplicar enforcement:

   ```bash
   hubble observe --identity 1 --verdict AUDIT --last 100 -o json |
     jq -r '[.flow.IP.source, (.flow.l4.TCP.destination_port // .flow.l4.UDP.destination_port)] | @tsv' |
     sort | uniq -c | sort -rn
   ```

7. Solo cuando esa lista esté vacía (o completamente entendida), deshabilitá el modo auditoría:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config "$HOSTEP" PolicyAuditMode=Disabled
   ```

8. Limpiá para que los ejercicios posteriores no se vean afectados:

   ```bash
   kubectl delete ccnp baseline-default-deny host-firewall-workers
   ```

### Comprobación de comprensión — Bloque 7

* **Q7.1** — ¿Qué pasa si aplicás una CCNP con **ambos**, `endpointSelector` y `nodeSelector`, definidos? ¿Qué hace el API server / el operator de Cilium?
* **Q7.2** — En el paso 1, `endpointSelector` usa `matchExpressions ... NotIn [kube-system]`. ¿Por qué un `endpointSelector: {}` vacío en una CCNP es peligroso?
* **Q7.3** — La política de host permite `fromEntities: [remote-node]`. ¿Qué se rompe primero en un cluster de 3 nodos si lo omitís?
* **Q7.4** — El ingress del firewall de host se aplica, pero el egress desde el host endpoint es un asunto aparte. ¿El tráfico de qué componente del sistema se origina en `reserved:host` y se vería afectado por una política de *egress* de host?
* **Q7.5** — Aplicaste una política de host y perdiste SSH a todos los workers a la vez. Describí el procedimiento de recuperación que no requiere acceso por consola.
* **Q7.6** — ¿Por qué `hostFirewall.enabled=true` requiere que se especifique `devices` en algunos entornos, y cuál es la consecuencia de equivocarse con la lista de dispositivos?

---

## Ejercicio 8 — Cifrado transparente y autenticación mutua

La política responde *quién puede conectarse*. El cifrado responde *quién puede leerlo en el cable*. La autenticación mutua responde *si el par es realmente quien sus etiquetas dicen*.

### Pasos

1. Habilitá el cifrado transparente con WireGuard:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set encryption.enabled=true \
     --set encryption.type=wireguard
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

2. Verificá desde el propio status del agente:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
   ```

   Esperado:

   ```
   Encryption: Wireguard
   Interface: cilium_wg0
     Public key: pM3W9v0Yc3l9Zk2Bp1qX4d7hR8s+Tn5Qw0Lm6Vg2Xk4=
     Number of peers: 2
   ```

3. Confirmá que cada nodo publicó una clave pública:

   ```bash
   kubectl get ciliumnodes -o custom-columns=\
   'NODE:.metadata.name,WG_PUBKEY:.metadata.annotations.network\.cilium\.io/wg-pub-key'
   ```

4. Demostrá que el tráfico está realmente cifrado en el cable — capturá en la interfaz física del nodo mientras generás tráfico pod a pod entre nodos:

   ```bash
   # Terminal A: capture on a worker
   docker exec cca-worker timeout 20 tcpdump -ni eth0 'udp port 51871' -c 5
   # Terminal B: cross-node traffic
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing || true
   ```

   Esperado en la terminal A — solo UDP opaco, sin HTTP legible:

   ```
   12:51:03.114 IP 172.18.0.3.51871 > 172.18.0.4.51871: UDP, length 176
   12:51:03.115 IP 172.18.0.4.51871 > 172.18.0.3.51871: UDP, length 176
   ```

5. Ahora habilitá la **autenticación mutua** respaldada por SPIRE:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set authentication.mutual.spire.enabled=true \
     --set authentication.mutual.spire.install.enabled=true
   kubectl -n cilium-spire rollout status statefulset/spire-server
   kubectl -n kube-system rollout restart ds/cilium
   ```

6. Exigí autenticación mutua en una regla específica:

   ```yaml
   # 10-mutual-auth.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: deathstar-mutual-auth
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               class: tiefighter
         authentication:
           mode: "required"
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl delete cnp rule1-deathstar-l7 rule1-deathstar-l7-headers --ignore-not-found
   kubectl apply -f 10-mutual-auth.yaml
   ```

7. Observá el handshake de autenticación en el mapa de política y en Hubble:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Esperado — notá **AUTH TYPE**:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS                                PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire   80/TCP       NONE         spire       0       0
   ```

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   hubble observe --pod default/tiefighter --last 6
   ```

   Esperado — el **primer** paquete se descarta mientras se completa el handshake, y después el tráfico fluye:

   ```
   Sep  1 12:58:10.001: default/tiefighter (ID:9034) <> default/deathstar (ID:4711) Authentication required DROPPED (TCP Flags: SYN)
   Sep  1 12:58:10.412: default/tiefighter (ID:9034) -> default/deathstar (ID:4711) to-endpoint FORWARDED (TCP Flags: SYN)
   ```

8. Inspeccioná la caché de autenticación y las identidades SPIFFE registradas:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf auth list
   kubectl -n cilium-spire exec -c spire-server spire-server-0 -- \
     /opt/spire/bin/spire-server entry show -socketPath /run/spire/sockets/server.sock | head -20
   ```

   Esperado (abreviado):

   ```
   Entry ID     : 8f0c...
   SPIFFE ID    : spiffe://spiffe.cilium/identity/4711
   Parent ID    : spiffe://spiffe.cilium/cilium-agent
   Selector     : cilium:mutual-auth
   ```

### Comprobación de comprensión — Bloque 8

* **Q8.1** — WireGuard está habilitado pero el tráfico pod a pod *dentro de un mismo nodo* no está cifrado. ¿Es un bug? Explicá el modelo de amenaza.
* **Q8.2** — Compará WireGuard e IPsec en Cilium según tres ejes: rotación de claves, requisitos de kernel y postura FIPS/cumplimiento.
* **Q8.3** — En el paso 7 el primerísimo SYN se descarta con `Authentication required`. Explicá por qué esto es *por diseño* y qué debe tolerar la aplicación.
* **Q8.4** — El SPIFFE ID es `spiffe://spiffe.cilium/identity/4711` — codifica el número de **identidad de seguridad**, no el pod ni la ServiceAccount. ¿Qué prueba entonces la autenticación mutua, y qué *no* prueba?
* **Q8.5** — ¿`authentication.mode: required` cifra el payload? Si no, ¿qué agrega por encima de WireGuard, y cuál es el modelo mental correcto de las dos funcionalidades juntas?
* **Q8.6** — `encryption.nodeEncryption=true` es un flag aparte. ¿Qué tráfico adicional cubre, y por qué está desactivado por defecto?

---

## Ejercicio 9 — Verificación completa y desmontaje

### Pasos

1. Ejecutá la suite oficial de punta a punta, que ejercita las rutas L3/L4, L7, DNS y de cifrado:

   ```bash
   cilium connectivity test --test-namespace cilium-test
   ```

   Cola esperada:

   ```
   ✅ All 58 tests (312 actions) successful, 12 tests skipped, 0 scenarios skipped.
   ```

2. Ejecutá el subconjunto consciente del cifrado:

   ```bash
   cilium connectivity test --include-unsafe-tests --test 'pod-to-pod-encryption'
   ```

3. Producí un inventario de políticas para revisión — todo lo que está en enforcement, en un solo lugar:

   ```bash
   kubectl get cnp,ccnp -A -o custom-columns=\
   'KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.endpointSelector.matchLabels'
   ```

4. Verificá de forma cruzada que los objetos `NetworkPolicy` nativos de Kubernetes también estén siendo aplicados por Cilium (lo están, salvo que `enableK8sNetworkPolicy=false`):

   ```bash
   kubectl get netpol -A
   kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get | jq -r '.[].labels[]?' | sort -u | head
   ```

5. Recolectá un bundle de soporte antes de cambiar nada — esto es lo que adjuntás a un ticket de incidente:

   ```bash
   cilium sysdump --output-filename cca-51-sysdump
   ```

6. Desmontá todo:

   ```bash
   kubectl delete cnp --all -n default
   kubectl delete ccnp --all
   kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/1.17.1/examples/minikube/http-sw-app.yaml
   kubectl delete pod mubuntu --ignore-not-found
   kind delete cluster --name cca
   ```

### Comprobación de comprensión — Bloque 9

* **Q9.1** — `cilium connectivity test` informa 12 tests **omitidos**. Nombrá dos flags de funcionalidad cuya ausencia hace que los tests se omitan en lugar de fallar, y explicá por qué "todos los tests pasaron" es una afirmación más débil de lo que suena.
* **Q9.2** — Una `NetworkPolicy` de Kubernetes y una `CiliumNetworkPolicy` seleccionan el mismo pod. ¿Cuál gana? ¿Bajo qué circunstancia cambia la respuesta?
* **Q9.3** — Nombrá dos cosas que una `CiliumNetworkPolicy` puede expresar y una `NetworkPolicy` de Kubernetes no, y una cosa que perdés al elegir el CRD.
* **Q9.4** — `cilium sysdump` se ejecuta *antes* de la remediación. ¿Qué artefactos específicos de política captura que `kubectl get cnp` pasaría por alto?

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Bloque 0

**A0.1** — Los tres valores son `default`, `always`, `never`.
* `default` — un endpoint seleccionado por **ninguna** política en una dirección dada es **allow-all** en esa dirección. El enforcement se activa por dirección y por endpoint, en el momento en que al menos una regla lo selecciona.
* `always` — todo endpoint está en denegación por defecto en ambas direcciones desde el inicio, sin importar si alguna política lo selecciona. Correcto para un cluster endurecido, pero va a romper el cluster en el instante en que se habilite salvo que todos los caminos ya estén cubiertos (incluido `kube-system`).
* `never` — la política nunca se aplica. Las reglas igual se computan y Hubble igual emite eventos `policy-verdict`, lo que lo convierte en un modo de simulación para todo el cluster.

**A0.2** — La política L7, y cualquier política cuya fuente sea una *identidad de pod* detrás de un Service. Con kube-proxy haciendo DNAT en netfilter antes de que corra el programa BPF de Cilium, el destino original ya fue reescrito, y Cilium pierde la capacidad de enganchar limpiamente la redirección a nivel de socket. En la práctica `kubeProxyReplacement=true` también habilita el socket-LB, que es lo que permite la redirección al proxy L7 y la preservación correcta de la identidad de origen. Correr ambos está soportado pero es una fuente común de fallos sutiles de política.

**A0.3** — El Envoy embebido corre dentro del proceso `cilium-agent`; el Envoy externo corre como su propio DaemonSet (`cilium-envoy`). Con Envoy embebido, un reinicio del agente derriba todas las redirecciones L7 en ese nodo — cada conexión proxeada se cae durante una actualización. Con el DaemonSet, los ciclos de vida del agente y del proxy quedan desacoplados, así que un reinicio del agente o una actualización de Cilium no cortan las conexiones proxeadas en L7. Por eso el Envoy externo es el predeterminado desde 1.16 y por eso importa para el radio de impacto de la política L7.

**A0.4** — `policyEnforcementMode=default` más cero políticas que seleccionen a `deathstar`: el endpoint está en allow-all en ambas direcciones. Cilium no deniega nada implícitamente hasta que una regla selecciona el endpoint.

---

### Bloque 1

**A1.1** — **No.** `k8s:io.kubernetes.pod.namespace` es parte del conjunto de etiquetas relevantes para la seguridad (visible en el paso 5), así que el namespace queda horneado dentro de la identidad. Dos pods con etiquetas de aplicación idénticas en namespaces distintos obtienen dos identidades distintas. También por esto una regla `fromEndpoints: {matchLabels: {app: foo}}` en una CNP está implícitamente acotada al namespace de la propia política, salvo que agregues `io.kubernetes.pod.namespace` explícitamente.

**A1.2** — **Cero.** Las 300 réplicas comparten el mismo conjunto de etiquetas (menos `pod-template-hash`, que está excluido) y por lo tanto la misma identidad. El mapa de política eBPF está indexado por `(direction, identity, port, protocol)`, así que su tamaño es O(cantidad de pares identidad/puerto permitidos distintos), no O(cantidad de pods). Ese es todo el punto de la seguridad basada en identidad y la razón por la que la política de Cilium escala donde iptables por IP no.

**A1.3** — Cada rolling update genera un nuevo `pod-template-hash`, así que cada despliegue asignaría una identidad completamente nueva para la misma carga de trabajo lógica. Consecuencias: rotación de identidades en cada deploy, una tormenta de regeneración de mapas de política en todos los nodos que la referencian y — lo peor — una ventana durante la cual la identidad de los pods nuevos es desconocida para los mapas de política de los pares, causando descartes transitorios para una carga de trabajo cuyas etiquetas y política no cambiaron.

**A1.4** — `reserved:host` es únicamente el namespace de host del nodo **local**; `reserved:remote-node` cubre los *otros* nodos del cluster. Permitir solo `reserved:host` significa que los health checks, las probes del kubelet y cualquier tráfico originado en un nodo **distinto** se descartan. El síntoma clásico: las probes de liveness pasan para los pods que están en el mismo nodo que el kubelet que las emite y fallan para todo lo demás, o los health checks de Cilium reportan el nodo como inalcanzable en una dirección. (En versiones más viejas `reserved:host` incluía los nodos remotos; la división se hizo deliberadamente para que un nodo comprometido no pueda hacerse pasar por la identidad de host local.)

**A1.5** — Porque las identidades CIDR y FQDN se derivan de datos que no son globalmente consistentes. Un FQDN resuelve a IPs distintas en nodos distintos en momentos distintos (CDNs, geo-DNS, desfase de TTL), y el proxy DNS de cada nodo observa su propio conjunto de respuestas. Asignar esas identidades a nivel de cluster a través del backend kvstore/CRD requeriría consenso distribuido en cada respuesta DNS — prohibitivamente caro y propenso a carreras. Por eso se asignan en un rango numérico local al nodo (`16777216`+), lo que significa que **el mismo ID numérico puede significar CIDRs distintos en nodos distintos**. Nunca correlaciones un número de identidad de alcance local entre nodos.

---

### Bloque 2

**A2.1** — El descarte ocurre en el endpoint de **destino** (`deathstar`), en el programa BPF de ingress de ese endpoint. `xwing` no tiene ninguna política que lo seleccione, así que su egress no está bajo enforcement y su `EGRESS ENFORCEMENT` es correctamente `false`. Esto es lo correcto para un datapath distribuido: la política de ingress se aplica donde vive el mapa de política del endpoint receptor, así que un emisor comprometido no puede saltearse su propio enforcement. También explica la salida de Hubble — el flujo se reporta con el endpoint de destino como nodo informante.

**A2.2** — *"Un endpoint entra en denegación por defecto para la dirección D apenas al menos una regla de política lo selecciona vía `endpointSelector` (o `nodeSelector` para políticas de host) **y** esa regla contiene una sección para la dirección D."* Notá las dos condiciones independientes: una política con solo una sección `ingress:` **no** pone el egress en denegación por defecto, y una lista vacía `ingress: []` *sí* selecciona la dirección y deniega todo en ella — esa es la forma idiomática de escribir denegación por defecto para una sola dirección.

**A2.3** — Es el **permiso de misma identidad** instalado automáticamente (y las filas `reserved:unknown`/comodín que respaldan las entradas allow-all). Cilium siempre permite el tráfico entre endpoints que comparten una identidad — réplicas del mismo Deployment hablando entre sí, sidecars, etc. No es eliminable mediante política; si necesitás impedir la comunicación entre misma identidad, primero tenés que dividir la carga de trabajo en conjuntos de etiquetas distintos (identidades distintas). No leas esas filas como un agujero en tu política.

**A2.4** — **La falla:** agregar cualquier regla `egress` cambia el endpoint a denegación por defecto en egress, lo que silenciosamente mata el DNS hacia CoreDNS, así que la aplicación falla en la resolución de nombres en vez de en la conexión — produciendo un engañoso `Could not resolve host` en lugar de un timeout de política.
**Remedio 1 (a nivel de política):** permitir explícitamente el egress en el puerto 53 hacia los endpoints de `kube-dns` en cada política que agregue una sección de egress — idealmente desplegando una `CiliumClusterwideNetworkPolicy` que otorgue egress de DNS a todos los namespaces, para que las políticas individuales de las apps nunca tengan que acordarse.
**Remedio 2 (a nivel de cluster):** habilitar el modo auditoría en el endpoint (o `policyEnforcementMode=never`) antes del despliegue, recolectar los flujos reales desde Hubble, y recién entonces aplicar enforcement — el mismo procedimiento del Ejercicio 3.

**A2.5** — DNS cae a **TCP/53** cada vez que una respuesta excede el límite de payload UDP — conjuntos de respuestas grandes, registros DNSSEC, o cualquier respuesta con el bit de truncado (TC) activo. También lo usan los resolvers configurados con `use-vc`. Restringir a UDP produce una falla de resolución intermitente y dependiente del tamaño que es extremadamente difícil de diagnosticar: los nombres chicos resuelven, los grandes no.

**A2.6** — **No, `tiefighter` ya no alcanza a `deathstar`... y después sí.** Cuidado: borrar `rule1` elimina la única política que selecciona a `deathstar`, así que el ingress de `deathstar` vuelve a estar sin enforcement (allow-all). `rule2` selecciona a `tiefighter` y aplica su *egress*, que sigue permitiendo el puerto 80 hacia `class: deathstar`. Así que la respuesta es **sí, sigue funcionando** — pero por una razón distinta que antes: previamente estaba permitido por la regla de ingress de `deathstar` y la regla de egress de `tiefighter`; ahora solo la regla de egress está haciendo algún trabajo. La lección es que el enforcement de ingress y de egress son estados independientes por endpoint, y que quitar una política puede ampliar el acceso para *otros* pares (por ejemplo, `xwing` ahora puede volver a alcanzar a `deathstar`).

---

### Bloque 3

**A3.1** — El alcance es un **único endpoint en un único nodo**, y la vida útil es la del endpoint. Se almacena en el estado de endpoint del agente, no en un objeto de Kubernetes. Cuando el pod se borra, se reprograma, o el agente del nodo pierde su estado de endpoint, la configuración desaparece y el enforcement vuelve a la normalidad. Es deliberadamente efímero: el modo auditoría es un estado de depuración, no una configuración que puedas dejar accidentalmente en Git.

**A3.2** — A nivel de cluster: `--set policyAuditMode=true` en tiempo de instalación/actualización (Helm), lo que pone **todos** los endpoints en modo auditoría. Precisamente por eso la vía por endpoint es más segura en producción — el flag de Helm requiere reiniciar el agente, se aplica a todas las cargas de trabajo incluidas aquellas cuya política ya es correcta y ya las está protegiendo, y crea una ventana en la que el cluster entero queda efectivamente sin enforcement. El comando por endpoint es instantáneo, acotado a la única carga de trabajo que estás incorporando, no requiere reinicio, y se autocorrige si te olvidás.

**A3.3** — La línea `policy-verdict ... AUDITED` la emite el **motor de políticas**: registra el veredicto que la política *habría* producido (denegar), etiquetado como auditado en vez de aplicado. La línea `to-endpoint ... FORWARDED` la emite el **datapath** en el punto de entrega: el paquete efectivamente se pasó al endpoint. Dos subsistemas, dos eventos, un paquete. En modo de enforcement verías una sola línea `Policy denied DROPPED` y ninguna línea `to-endpoint`.

**A3.4** — Los comunes que se leen mal como problemas de política:
* `Stale or unroutable IP` / `Unsupported L3 protocol` — la identidad o la ruta de destino todavía no son conocidas por este nodo, típicamente durante el arranque del pod o la propagación de identidades. Parece una denegación de política pero es una carrera, y se resuelve al reintentar.
* `Authentication required` — el handshake de autenticación mutua todavía no se completó (Ejercicio 8). La política *permite* el flujo; solo falta el estado de autenticación.
* `Service backend not found` / `No mapping for NAT masquerade` — una falla de balanceo de carga o de conectividad, no de política.
* `CT: Map insertion failed` — agotamiento de la tabla de conntrack. Este es de capacidad, no de seguridad, y la solución es `bpf-ct-global-tcp-max`.

**A3.5** — Hubble muestra el tráfico que fue **intentado**. No puede mostrarte un permiso que tu política otorga pero que nadie ejerció todavía — la regla demasiado permisiva que solo se vuelve un incidente cuando un atacante la usa. Concretamente: una política que permite egress a `0.0.0.0/0` se ve idéntica en Hubble a una que permite egress a una sola API, mientras la aplicación solo hable con esa API. Probar que una política es *ajustada* requiere leer la política (`cilium-dbg bpf policy get`, `cilium-dbg policy get`) e, idealmente, una prueba adversarial — no observar los flujos de producción.

---

### Bloque 4

**A4.1** — **Razón:** una denegación L3/L4 descarta el paquete en eBPF antes de que exista conexión alguna, así que el cliente no ve nada y agota el tiempo en la retransmisión del SYN. Una denegación L7 requiere que el handshake TCP se *complete* — la conexión se redirige a Envoy, Envoy parsea la petición HTTP, y recién entonces aplica la regla; un rechazo en ese punto solo puede expresarse dentro del protocolo, como `403 Access denied`.
**Consecuencia de seguridad:** el comportamiento L7 es una divulgación de información. El atacante aprende que el destino existe, que está escuchando, que habla HTTP, y que su acceso L3/L4 está permitido — ahora tiene un oráculo funcional para enumerar qué rutas y métodos están permitidos sondeando `403` contra `200`/`404`. La denegación L3/L4 no filtra nada. Es un compromiso real, no un defecto: lo aceptás a cambio de granularidad por método/ruta.

**A4.2** — **El puerto 80 queda completamente abierto en L4 — la regla L7 queda efectivamente neutralizada.** Cilium toma la unión de las reglas de permiso, y una regla que permite el puerto 80 sin restricción L7 es estrictamente más amplia que una que permite el puerto 80 con una restricción HTTP. El resultado es que cualquier método y ruta HTTP se permite desde cualquier origen que coincida con la regla L4. Esa es la trampa: agregar una regla L4 "temporal" para depurar deshabilita silenciosamente la política L7 que creías que protegía el endpoint. Verificá con `cilium-dbg bpf policy get` — si `PROXY PORT` es `NONE` en una fila que esperabas proxeada, una regla L4 amplia la tapó.

**A4.3** — Con Envoy embebido (interno al agente), el proxy L7 muere y reinicia con el agente, así que toda conexión que en ese momento atraviesa el proxy se corta en cada reinicio del agente durante una actualización progresiva — para cargas de trabajo con política L7 eso es una caída visible por nodo. `Envoy: external` (el DaemonSet `cilium-envoy`, por defecto desde 1.16) los desacopla, así que los reinicios del agente dejan intactos el proxy y sus conexiones establecidas. Si estás con Envoy embebido, planificá en consecuencia las actualizaciones de las cargas con política L7, o migrá al proxy externo antes de desplegar política L7 ampliamente.

**A4.4** — La traducción Service→backend ocurre **primero**, en el balanceador de carga a nivel de socket (`kubeProxyReplacement`), en el momento del `connect()` en el pod cliente — antes de que el paquete siquiera se construya, y por lo tanto antes de la redirección a Envoy. Para cuando el flujo llega al programa de ingress del nodo de destino y se redirige a Envoy, el destino ya es la IP concreta del pod backend y su identidad (`4711`). También por eso `toServices` en una política de egress se resuelve a identidades de endpoint backend en vez de a la ClusterIP.

**A4.5** — No directamente: el motor de política L7 de Cilium necesita ver HTTP en claro, y no termina TLS por vos por defecto. Tus opciones, en orden de preferencia:
1. **Terminar TLS en el borde de ingress/mesh** y aplicar la política L7 sobre el salto en claro dentro del cluster — el diseño normal.
2. Usar la **intercepción TLS de Cilium** para egress (`terminatingTLS` / `originatingTLS` en el bloque `toPorts` con un secreto de CA que Cilium controle). Esto es un MITM real y requiere distribuir la CA a las cargas de trabajo; está soportado, pero es un compromiso operativo significativo.
3. Caer al **control basado en SNI** (`serverNames` en la regla TLS) — obtenés granularidad por nombre de host de destino sin descifrado, pero sin granularidad por método/ruta.
4. Aplicar enforcement solo en L3/L4, y empujar la decisión de autorización a la aplicación.

---

### Bloque 5

**A5.1** — `curl https://api.github.com` **falla con un timeout al conectar** (el DNS en sí sigue funcionando). Sin `rules: dns:`, no se instala ninguna redirección al proxy DNS, así que el agente nunca observa la respuesta para `api.github.com`, la caché FQDN queda vacía, y nunca se asigna una identidad CIDR para `140.82.121.6`. La regla `toFQDNs` entonces no coincide con nada y la conexión se deniega como `reserved:world`. Este es *el* error más común con `toFQDNs`: la regla DNS L7 no es una optimización, es el mecanismo.

**A5.2** — **Lo que garantiza:** que la carga de trabajo solo puede enviar paquetes a direcciones IP que *el proxy DNS de este nodo observó que fueron devueltas* para un nombre que coincide con tu patrón, dentro del TTL. Ata el egress a una resolución DNS real y visible para la política.
**Lo que no garantiza:** que el destino *sea* ese host. Por debajo es enforcement basado en IP. Cualquier otro servicio que comparta esa IP es alcanzable (el caso de IP compartida del paso 6: `185.199.108.133` sirve muchos sitios `*.github.io` y `*.githubusercontent.com`, así que permitir uno permite todos). Al revés, una carga de trabajo que usa una IP hardcodeada o su propio resolver evade el mecanismo — y por eso `toFQDNs` debe ir acompañado de un `egressDeny`/ausencia de permiso para egress directo por IP y de una política que fuerce el DNS a través del resolver del cluster. `toFQDNs` es un control de *usabilidad* sobre el egress por CIDR, no una verificación criptográfica de identidad. Para eso, mirá la autenticación mutua.

**A5.3** — Está en el **rango de identidades local (de alcance de nodo)**. El ID solo tiene sentido en el nodo que lo asignó. Si construís herramientas que unen flujos de Hubble o salidas de `bpf policy get` entre nodos por identidad numérica, las identidades de alcance local van a producir un sinsentido — el mismo número mapea a CIDRs distintos en nodos distintos. Resolvé siempre las identidades de alcance local con `cilium-dbg identity list` **en el nodo que reportó el flujo**.

**A5.4** — **La caída:** la app resuelve una vez, cachea la IP durante una hora, y la sigue usando. Cilium expira la entrada de la caché FQDN tras el TTL de 30 s (más el período de gracia), elimina la identidad CIDR, y empieza a descartar el tráfico de la app hacia una IP que ella sigue usando alegremente. El síntoma es "funcionó el primer minuto después del deploy y después dejó de funcionar", sin ningún cambio de configuración.
**La mitigación:** `--tofqdns-min-ttl` (Helm: ajuste de `dnsPolicy`/`toFQDNs`, flag del agente `--tofqdns-min-ttl`, por defecto 3600 s en versiones recientes) sube el piso de cuánto se retiene una entrada sin importar el TTL de origen, y `--tofqdns-idle-connection-grace-period` mantiene vivas las identidades mientras las conexiones todavía las usan. Subir el TTL mínimo es la solución estándar; el costo es una ventana más amplia en la que un registro DNS reapuntado sigue permitido.

**A5.5** — Porque las dos reglas hacen trabajos distintos. `matchPattern: "*"` en la regla **`dns`** gobierna *qué consultas DNS reenvía y observa el proxy* — dice "dejá que este pod consulte cualquier cosa, y mirá cada respuesta". No otorga ningún egress de plano de datos. La regla **`toFQDNs`** es la que otorga egress, y está restringida a `api.github.com` y `*.githubusercontent.com`. Así que `cilium.io` resuelve con éxito (el proxy permite y observa la consulta) pero la conexión TCP subsiguiente a su IP se deniega. Si *sí* querés restringir qué nombres se pueden siquiera resolver — un control útil contra exfiltración por DNS — angostá el `matchPattern` de la regla `dns`, y esperá ver `dns-request DROPPED` en Hubble para todo lo demás.

**A5.6** — Las consultas en vuelo fallan durante la ventana de reinicio y — peor — los nombres recién resueltos no se observan, así que las conexiones nuevas a destinos permitidos por FQDN se deniegan hasta que el proxy vuelva y la app vuelva a resolver. El endurecimiento es `dnsProxy.enableTransparentMode=true` (modo de proxy DNS transparente, por defecto en versiones recientes), que mantiene las reglas de redirección en el datapath a través de los reinicios del agente, más `bpf.preallocateMaps`/`enableRuntimeDeviceDetection` para resiliencia general ante reinicios. La caché FQDN además se persiste a disco y se restaura al arrancar el agente, lo que acota el daño.

---

### Bloque 6

**A6.1** — **Las reglas de denegación siempre ganan.** Para cualquier flujo dado, si coincide una regla `ingressDeny`/`egressDeny`, el flujo se descarta, incondicionalmente y sin importar cuán específicas o cuán numerosas sean las reglas de permiso que coinciden — incluidas las reglas de permiso L7. **No** existe regla de permiso que pueda anular una denegación. Esto es intencional: hace de las reglas de denegación una primitiva segura para barandas a nivel de plataforma que los equipos de aplicación no pueden atravesar accidentalmente con sus propias CNPs. El corolario es que una regla de denegación mal acotada es una caída sin ningún workaround del lado de la aplicación.

**A6.2** — `toCIDRSet` con `except` se compila en un **trie de coincidencia de prefijo más largo (LPM)** en el mapa CIDR de eBPF. El prefijo `10.0.0.0/8` se inserta como entrada de denegación y `10.244.0.0/16` se inserta como una entrada más específica que *no* lleva la denegación. Como la búsqueda es por prefijo más largo, un paquete a `10.244.1.51` coincide con el /16 y no se deniega, mientras que `10.1.2.3` cae al /8 y sí. Escribir esto como una lista explícita de CIDRs no superpuestos requeriría decenas de entradas, cada una consumiendo una ranura del mapa y cada una necesitando recálculo cuando cambia el CIDR de pods. La forma `except` mantiene el mapa chico y la intención legible — y es la única manera correcta de abrir un hueco en una supernet, porque no podés expresar "denegar X pero no Y" con dos reglas independientes dado que la denegación gana.

**A6.3** —
* `reserved:world` — todo lo que está **fuera** del cluster: todas las IPs que Cilium no conoce como pod, nodo o entidad del cluster.
* `reserved:all` — literalmente todo, dentro y fuera del cluster. Equivalente a no tener restricción L3.
* `reserved:cluster` — todo lo que está **dentro** del cluster: todos los pods en todos los namespaces, más `host`, `remote-node`, `health` e `init`. **Este es el que silenciosamente incluye el namespace de host del propio nodo** (y el de todos los demás nodos) — así que `toEntities: [cluster]` es mucho más amplio que "todos los pods" y otorga alcance a servicios a nivel de nodo.
* `reserved:remote-node` — únicamente los namespaces de host de *otros* nodos, no el local.

**A6.4** — Difieren en los **destinos dentro del cluster**. `toCIDR: 0.0.0.0/0` coincide por prefijo de IP y por lo tanto también coincide con IPs de pods, IPs de nodos y ClusterIPs que caen dentro — es efectivamente allow-all. `toEntities: [world]` coincide por *identidad* y excluye deliberadamente todo lo que Cilium sabe que está dentro del cluster, así que los pods y nodos **no** quedan cubiertos. Usar `0.0.0.0/0` cuando querías decir "internet" es una sobreconcesión real. (Sutileza relacionada: `toCIDR` sobre una IP interna del cluster crea una identidad CIDR que puede tapar la identidad del pod en la evaluación de política — otra razón para preferir entidades y selectores de endpoint para destinos dentro del cluster.)

**A6.5** — (1) **La IP del API server no es estable** en un cluster gestionado — puede ser un balanceador de carga con un conjunto de direcciones rotativo, múltiples IPs del plano de control, o una IP de endpoint privado que cambia en una actualización. Un `toCIDR` hardcodeado se rompe silenciosamente en el peor momento. (2) **La entidad la mantiene Cilium**, que aprende las direcciones del API server desde los endpoints del Service `kubernetes` y mantiene la identidad `7` exacta a medida que cambian, incluso a través de reemplazos del plano de control. Razón adicional: en muchas plataformas gestionadas la IP del API server cae dentro de un rango que de otro modo querrías denegar (RFC1918, o el mismo rango de LB que otros servicios), así que una regla CIDR te obliga a abrir un hueco más ancho que el API server solo.

**A6.6** — Porque no se trata de los requisitos de ninguna aplicación en particular — ninguna carga de trabajo legítima del cluster necesita el endpoint de metadatos de instancia de la nube del nodo, y toda carga de trabajo es igualmente capaz de abusarlo. Bloquea el ataque de **robo de credenciales de nube / SSRF-a-IMDS**: un pod comprometido o vulnerable a SSRF pide `http://169.254.169.254/latest/meta-data/iam/security-credentials/` (AWS) o el camino equivalente de GCP/Azure, y recibe las credenciales del rol IAM *del nodo* — escalando instantáneamente de un pod a lo que sea que el perfil de instancia del nodo pueda hacer, a nivel de todo el cluster y a menudo de toda la cuenta. Pertenece a una `CiliumClusterwideNetworkPolicy` aplicada a todos los namespaces por defecto, como un `egressDeny` para que ninguna política de aplicación pueda rehabilitarlo. (IMDSv2 sube la vara pero no lo cierra; el control de red es la solución duradera.)

---

### Bloque 7

**A7.1** — Definir ambos es **inválido y se rechaza**. `nodeSelector` y `endpointSelector` son mutuamente excluyentes en una CCNP: una política apunta a endpoints de pod o a endpoints de nodo (host), nunca a ambos. El esquema de validación del CRD rechaza el objeto, y el operator de Cilium reporta la política como inválida — no se aplica silenciosamente a medias. Escribí dos CCNPs separadas.

**A7.2** — Un `endpointSelector: {}` vacío en una **CCNP** selecciona **todos los endpoints del cluster, en todos los namespaces, incluido `kube-system`**. Combinado con una forma de denegación por defecto (una sección `ingress:`/`egress:` que no cubre el tráfico propio del plano de control), tumba CoreDNS, el operator de Cilium, el stack de métricas y cualquier componente adyacente al CNI simultáneamente — y como CoreDNS está caído, la mayoría de las herramientas de recuperación que resuelven nombres también dejan de funcionar. En una CNP con namespace un selector vacío es meramente "todos los pods de este namespace" y es un idiom normal; en una CCNP es un radio de impacto de todo el cluster. Excluí siempre `kube-system` (y tus propios namespaces de plataforma) con `matchExpressions ... NotIn`, y desplegalo siempre bajo modo auditoría primero.

**A7.3** — **Los health checks de Cilium y el tráfico de control entre nodos**, de inmediato — seguido por las probes del kubelet hacia pods en otros nodos, el tráfico encapsulado VXLAN/Geneve si estás en modo túnel, y el WireGuard/IPsec nodo a nodo si el cifrado está activo. El primer síntoma visible suele ser `cilium status` reportando fallas de salud nodo a nodo y probes de liveness fallando para pods no colocados junto al kubelet que sondea. Como el firewall de host se aplica en todos los nodos seleccionados a la vez, este es un evento de todo el cluster, no de un solo nodo.

**A7.4** — Todo lo que se origina en el namespace de red de host del nodo lleva `reserved:host`: **el kubelet** (llamadas al API server, descargas de imágenes, tráfico de probes), `kube-proxy` si está presente, el runtime de contenedores descargando imágenes de un registry, agentes a nivel de nodo (recolectores de logs, monitoreo, drivers CSI) corriendo con `hostNetwork: true`, servicios de systemd como `chronyd`/NTP y el resolver DNS, y el propio `cilium-agent` hablando con el API server. Una política de **egress** de host que omita alguno de estos rompe la capacidad del nodo de funcionar como nodo de Kubernetes — de la manera más dramática, cortando al kubelet del API server, tras lo cual el nodo pasa a `NotReady` y el plano de control empieza a desalojar sus pods. La política de egress de host es sustancialmente más peligrosa que la de ingress de host, y por eso Cilium exige que se opte por ella explícitamente y por eso casi todas las políticas de host en producción son solo de ingress.

**A7.5** — Recuperación sin acceso por consola, en orden:
1. Los pods `cilium-agent` están en la red del cluster y son alcanzables vía el API server, que no está afectado si solo aplicaste firewall a los workers. **Borrá la CCNP ofensiva con `kubectl`**: `kubectl delete ccnp host-firewall-workers`. Los agentes recalculan la política del host endpoint en segundos y el enforcement vuelve a allow-all (asumiendo `policyEnforcementMode=default` y ninguna otra política de host).
2. Si `kubectl` todavía funciona pero querés conservar la política mientras depurás, volvé a habilitar el modo auditoría en el host endpoint en cada nodo: `kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config <host-ep-id> PolicyAuditMode=Enabled` — ojo que `exec ds/cilium` alcanza solo un pod, así que iterá sobre los pods.
3. Si el propio API server ahora es inalcanzable porque también aplicaste firewall al plano de control, quedaste reducido a la consola del nodo / acceso serial del proveedor de nube, o al camino de los security groups del propio proveedor. **Por esto es que etiquetás y desplegás primero en un único nodo canario, y por esto `nodeSelector` debería coincidir con un nodo antes de coincidir con todos.**

La lección generalizable: una política de host es el único objeto de Cilium que puede eliminar tu propio camino de remediación. Siempre ponela detrás de modo auditoría y de un selector canario.

**A7.6** — `devices` le dice a Cilium a qué **interfaces de red físicas/nativas** enganchar los programas BPF del firewall de host. Cilium autodetecta dispositivos (y `enableRuntimeDeviceDetection` mantiene eso al día), pero la autodetección puede elegir el conjunto equivocado en entornos con múltiples NICs, bonds, subinterfaces VLAN o nomenclatura poco convencional — así que a menudo se fija explícitamente por determinismo.
**Consecuencia de equivocarse:** si se *omite* un dispositivo que transporta tráfico del nodo, el firewall de host simplemente no ve ese tráfico — la política parece aplicada, `cilium-dbg endpoint list` muestra el enforcement habilitado, y sin embargo el tráfico que llega por la NIC no listada queda completamente sin filtrar. Eso es un **agujero de seguridad silencioso**, el peor de los dos modos de falla. A la inversa, listar un dispositivo que transporta tráfico que no pretendías filtrar produce descartes inesperados. Verificá con `cilium-dbg status --verbose | grep -A5 Devices` y confirmá que toda NIC que pueda recibir tráfico del nodo esté listada.

---

### Bloque 8

**A8.1** — **No es un bug — es el modelo de amenaza documentado.** El cifrado transparente de Cilium protege el tráfico **en el cable entre nodos**. El tráfico pod a pod dentro de un nodo nunca sale del kernel: se reenvía entre pares veth mediante eBPF sin tocar una interfaz física, así que no hay cable en el que espiar. Un atacante que pueda leer ese tráfico ya tiene acceso a nivel de kernel en el nodo, y en ese punto cifrar entre dos procesos de ese mismo nodo no protege nada — puede leer el texto en claro en cualquiera de los dos extremos. Si tu modelo de amenaza *sí* incluye un nodo comprometido leyendo el tráfico de sus co-inquilinos, el cifrado de red es la herramienta equivocada; necesitás aislamiento de nodos (node pools dedicados, taints) o TLS a nivel de aplicación.

**A8.2** —
| Eje | WireGuard | IPsec |
|---|---|---|
| **Rotación de claves** | Automática. Cada nodo genera un par de claves al arrancar el agente y publica la clave pública en su objeto `CiliumNode`; los pares la toman. La rotación ocurre implícitamente al reiniciar el agente, sin acción del operador y sin secreto compartido que gestionar. | Manual. Una clave precompartida vive en el Secret `cilium-ipsec-keys` con un ID de clave explícito; la rotación es un procedimiento del operador — subir el ID de clave, actualizar el Secret, y dejar que los agentes converjan a través de una ventana en la que se aceptan ambas claves. Equivocarse descarta tráfico. |
| **Requisitos de kernel** | Necesita soporte de WireGuard — en el árbol desde Linux 5.6, o el módulo `wireguard`. Cilium cae a una implementación en espacio de usuario solo en casos limitados; en la práctica querés ≥5.6. | Usa el stack XFRM del kernel, presente en prácticamente todos los kernels, pero con más rarezas históricas (manejo de MTU, explosión de estados XFRM, interacciones con ciertos offloads de NIC). Compatibilidad de kernel más amplia, más casos borde. |
| **FIPS / cumplimiento** | ChaCha20-Poly1305 y Curve25519 — **no aprobados por FIPS 140-2/3**. Si tu auditor exige criptografía validada por FIPS, WireGuard queda descalificado sin importar sus méritos técnicos. | AES-GCM vía la API de cripto del kernel, que puede correr en modo FIPS sobre un kernel validado por FIPS. **Esta es la razón por la que IPsec todavía existe en Cilium** a pesar de que WireGuard es más simple de operar. |

Guía práctica: elegí WireGuard salvo que un requisito de cumplimiento te fuerce a IPsec. El costo operativo de la rotación manual de claves es la diferencia dominante en el mundo real.

**A8.3** — Es por diseño, porque el handshake de autenticación es **fuera de banda y asíncrono respecto del plano de datos**. Cuando el primer paquete de un flujo llega al mapa de política y encuentra `AUTH TYPE: spire` sin una entrada válida en la caché de autenticación, el datapath no puede bloquearse esperando un handshake de TLS mutuo — los programas eBPF no pueden dormir, y retener el paquete requeriría estado no acotado. Así que descarta el paquete, emite `Authentication required`, y le señala al agente que realice el handshake. Una vez que los agentes de ambos extremos lo completan (típicamente decenas a bajos cientos de milisegundos) el resultado se escribe en la caché de autenticación (`cilium-dbg bpf auth list`) y los paquetes siguientes se reenvían.
**Qué debe tolerar la aplicación:** el primer intento de conexión a un par recién autenticado falla en la capa TCP y debe reintentarse. La propia retransmisión de SYN de TCP normalmente lo absorbe de forma transparente (el reintento cae después de que el handshake se completa), pero una aplicación con un timeout de conexión agresivo, o un health check sin reintento, va a observar una falla en el primer intento después de cualquier expiración de la caché de autenticación. Configurá los reintentos de conexión en consecuencia, y tené en cuenta que la caché de autenticación tiene un TTL — esto no es estrictamente un costo de una sola vez por vida del pod.

**A8.4** — El SPIFFE ID codifica el **número de identidad de seguridad de Cilium**, así que la autenticación mutua prueba: *el par es un endpoint al que el plano de control de Cilium le asignó esta identidad, y posee un X.509-SVID emitido por el servidor SPIRE del cluster que lo atestigua.* En otras palabras, liga criptográficamente la identidad derivada de etiquetas contra la que se escribe la política a un certificado que el par debe presentar — cerrando la brecha donde un atacante capaz de falsificar una IP, u ocupar una IP de pod reciclada, podría de otro modo ser tratado como la identidad confiable.
**Lo que no prueba:** nada sobre el *pod*, la *ServiceAccount* ni el *proceso* específicos. Todas las réplicas de un Deployment comparten la identidad `4711` y por lo tanto comparten un SVID — la autenticación mutua no puede distinguir la réplica A de la réplica B, ni decirte *qué* proceso dentro del pod abrió la conexión. Tampoco autentica al *usuario* ni a la petición en cuyo nombre se hace la llamada; eso sigue siendo un asunto de la capa de aplicación. Y no es de extremo a extremo: los SVIDs los terminan los agentes de Cilium, no las cargas de trabajo, así que la garantía es de agente a agente sobre identidad de endpoint, no de proceso a proceso.

**A8.5** — **No, `authentication.mode: required` no cifra nada.** El handshake de autenticación mutua establece identidad; el flag resultante en el mapa de política habilita el reenvío. La confidencialidad del payload viene enteramente de la funcionalidad separada de cifrado transparente (WireGuard/IPsec).
**El modelo mental correcto:** son mitades ortogonales de lo que da el mTLS de un service mesh, y Cilium las separa deliberadamente porque se aplican en lugares distintos y con costos distintos.
* *Cifrado (WireGuard/IPsec)* responde **"¿puede alguien en el cable leer esto?"** — confidencialidad e integridad nodo a nodo.
* *Autenticación mutua (SPIRE)* responde **"¿es el par realmente la identidad que nombra mi política?"** — verificación criptográfica de identidad, por regla de política.

Querés ambas para una postura zero-trust: el cifrado sin autenticación protege el cable pero sigue confiando en aserciones de identidad derivadas de etiquetas e IPs; la autenticación sin cifrado verifica al par pero manda el payload en claro. Habilitá WireGuard a nivel de cluster como línea base, y agregá `authentication: required` selectivamente a las reglas que protegen tus servicios de mayor valor, ya que conlleva un costo de handshake por flujo.

**A8.6** — `encryption.nodeEncryption=true` extiende el cifrado al tráfico originado en o destinado al **namespace de red de host del nodo** — es decir, tráfico `reserved:host`: pods con `hostNetwork: true`, tráfico del kubelet, agentes a nivel de nodo, y health checks entre nodos. Sin él, solo el tráfico pod a pod (endpoint a endpoint) está cifrado, y el tráfico originado en el host cruza el cable en claro.
**Por qué está desactivado por defecto:** es sustancialmente más fácil de romper. El tráfico del host incluye los caminos de los que depende el cluster para recuperarse de una mala configuración — kubelet a API server, las conexiones de control de los propios agentes de Cilium, SSH, y los health checks de nodo. Si el cifrado está mal configurado o la clave de un nodo está desactualizada, habilitar el cifrado de nodo puede particionar el nodo del plano de control de una manera que no es recuperable con `kubectl`. También interactúa mal con algunos balanceadores de carga de nube y con cualquier middlebox que espere ver el tráfico del nodo. Es una opción deliberada de habilitación explícita con postura de "verificar primero en un nodo canario", igual que el firewall de host.

---

### Bloque 9

**A9.1** — Los tests se omiten cuando la funcionalidad que ejercitan no está habilitada, en vez de fallar, para que la suite sea usable en cualquier configuración. Dos ejemplos: **`hostFirewall.enabled`** (los tests de política de host se omiten cuando está apagado) y **`encryption.enabled`** (los tests de cifrado pod a pod se omiten sin él). Otros incluyen los tests de ClusterMesh sin una malla, los de egress gateway sin `egressGateway.enabled`, y el conjunto `--include-unsafe-tests` que se omite por defecto porque esos tests interrumpen el tráfico del cluster.
**Por qué "todos los tests pasaron" es más débil de lo que suena:** la suite valida las funcionalidades que *encendiste*. Un cluster con el cifrado deshabilitado reporta una corrida limpia mientras transmite cada paquete en claro. Leé siempre el conteo de omitidos y sus motivos — un número creciente de omisiones después de una actualización de Helm es una señal fuerte de que se cayó un flag de tu archivo de values. `cilium connectivity test` es un test de regresión del datapath, no una auditoría de tu postura de seguridad.

**A9.2** — **La `CiliumNetworkPolicy` y la `NetworkPolicy` se combinan, no se jerarquizan — Cilium toma la unión de todas las reglas de permiso de ambas.** No hay "ganador": Cilium traduce los objetos `NetworkPolicy` de Kubernetes a su propia representación interna de reglas y los evalúa junto con las CNPs. Un flujo se permite si *cualquier* regla de *cualquiera* de las dos fuentes lo permite. Ambas disparan por igual la denegación por defecto en las direcciones que seleccionan.
**Cuándo cambia la respuesta:** (1) si `enableK8sNetworkPolicy=false`, los objetos `NetworkPolicy` de Kubernetes se ignoran por completo y solo se aplican CNPs/CCNPs — una configuración peligrosa si los equipos de aplicación siguen escribiendo `NetworkPolicy`, porque sus objetos se aplican limpiamente en el API server y no hacen nada. (2) **Las reglas de denegación rompen la unión**: una CNP con `ingressDeny`/`egressDeny` anula todo permiso de ambas fuentes, ya que la denegación tiene precedencia absoluta y la `NetworkPolicy` de Kubernetes no tiene un concepto de denegación con el cual competir.

**A9.3** — **Dos cosas que solo el CRD puede expresar** (hay muchas; las más fuertes son):
* **Reglas L7** — método/ruta/cabecera HTTP, `matchPattern` de DNS, y Kafka. La `NetworkPolicy` de Kubernetes se detiene en L4.
* **`toFQDNs`** — egress por nombre DNS. También exclusivos del CRD: `egressDeny`/`ingressDeny` (semántica de denegación), `toEntities` (`world`, `host`, `remote-node`, `kube-apiserver`, …), alcance de todo el cluster con `CiliumClusterwideNetworkPolicy`, `nodeSelector` para el firewall de host, y `authentication: mode: required`.

**Lo que perdés:** **portabilidad**. Una `NetworkPolicy` es una API core de Kubernetes que todo CNI conforme aplica; una `CiliumNetworkPolicy` ata la postura de seguridad de la carga de trabajo a Cilium. Migrar de CNI, operar un parque multi-CNI, o entregar un chart de Helm a un cliente cuyo cluster corre Calico se vuelven más difíciles. La pérdida secundaria es de **herramientas y superficie de auditoría**: los linters de política, admission controllers, chequeos de CI y escáneres de cumplimiento entienden abrumadoramente `NetworkPolicy` y pueden no parsear el CRD. El patrón pragmático es expresar todo lo posible en `NetworkPolicy` portable y recurrir al CRD solo donde realmente necesitás L7, FQDN, denegación o alcance de host.

**A9.4** — `kubectl get cnp` devuelve solo el estado **deseado** — los objetos que escribiste. `cilium sysdump` captura el estado **realizado**, por nodo, que es donde viven realmente los bugs de política:
* La salida de `cilium-dbg policy get` por agente — el conjunto de reglas totalmente resuelto tras la expansión de selectores y la fusión de CNP + CCNP + `NetworkPolicy` de Kubernetes, incluidas reglas de namespaces que no creías involucrados.
* `cilium-dbg bpf policy get` por endpoint — el **mapa de política eBPF compilado**, con contadores de bytes y paquetes por regla. Una regla con cero paquetes tras horas de tráfico o está muerta o está tapada.
* `cilium-dbg endpoint list` / `endpoint get` — el estado de enforcement por endpoint, `PolicyAuditMode`, y la identidad y etiquetas realizadas del endpoint (que pueden diferir del spec del pod si las etiquetas cambiaron).
* `cilium-dbg identity list` y las cachés CIDR/FQDN — los mapeos de identidad de alcance local necesarios para interpretar cualquier registro de flujo, que no pueden reconstruirse después.
* Logs del agente con **errores de regeneración de política** — una CNP que el API server aceptó pero que el agente no pudo traducir o instalar solo es visible acá; el status del CRD puede no reflejarlo.
* Buffers de flujos de Hubble, y `cilium status --verbose` por nodo.

La razón para recolectarlo *antes* de remediar es que todo lo anterior es estado efímero en memoria del agente. Borrar la política ofensiva para restaurar el servicio destruye la evidencia — los contadores se resetean, las identidades se liberan, y los errores de regeneración se van del log. Primero sysdump, después arreglar.

</details>

---

## Fuentes

* Referencia de Cilium Network Policy — <https://docs.cilium.io/en/stable/security/policy/>
* Seguridad basada en identidad y el modelo de etiquetas — <https://docs.cilium.io/en/stable/overview/component-overview/> y <https://docs.cilium.io/en/stable/internals/security-identities/>
* Política de capa 7 (HTTP/DNS/Kafka) — <https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples>
* Egress basado en DNS (`toFQDNs`) — <https://docs.cilium.io/en/stable/security/policy/language/#dns-based>
* Políticas de denegación y precedencia — <https://docs.cilium.io/en/stable/security/policy/language/#deny-policies>
* Firewall de host — <https://docs.cilium.io/en/stable/security/host-firewall/>
* Cifrado transparente (WireGuard / IPsec) — <https://docs.cilium.io/en/stable/security/network/encryption/>
* Autenticación mutua — <https://docs.cilium.io/en/stable/security/network/encryption-wireguard/> y <https://docs.cilium.io/en/stable/security/network/mutual-authentication/>
* Resolución de problemas de política y modo auditoría — <https://docs.cilium.io/en/stable/security/policy-creation/> y <https://docs.cilium.io/en/stable/operations/troubleshooting/>
* Observabilidad con Hubble — <https://docs.cilium.io/en/stable/observability/hubble/>
* Currícula CCA — <https://github.com/cncf/curriculum/blob/master/cca/README.md>