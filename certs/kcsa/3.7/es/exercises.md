# Ejercicios guiados — KCSA 3.7: Network Policy

> **Objetivo.** Construir, desde cero, el modelo de red *zero-trust* que exige el dominio *Kubernetes Cluster Component Security* del KCSA: partir de un namespace totalmente abierto, imponer un *default-deny*, y luego abrir el tráfico rendija por rendija con `podSelector`, `namespaceSelector`, `ipBlock` y control de *egress*. Cada bloque termina con preguntas de verificación; las respuestas están al final en una sección colapsable.
>
> **Requisito crítico.** `NetworkPolicy` es un objeto de la API que **no hace nada por sí mismo**: lo aplica el CNI plugin. Un cluster con un CNI que no implementa la spec (p. ej. `kindnet` por defecto, o Flannel sin `flannel-networkpolicy`) aceptará tus manifiestos con `kubectl apply` y **no bloqueará nada**. Este es el error de diagnóstico número uno del tema. Usaremos `kind` + **Calico** para garantizar el enforcement.
>
> Fuentes:
> - NetworkPolicy (concepto): https://kubernetes.io/docs/concepts/services-networking/network-policies/
> - Declarar una NetworkPolicy (task): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
> - Calico policy: https://docs.tigera.io/calico/latest/network-policy/get-started/kubernetes-policy/kubernetes-network-policy
> - KCSA Curriculum: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

---

## Bloque 0 — Provisionar un cluster que *sí* aplique políticas

**Pasos**

1. Crear un cluster `kind` **sin** el CNI por defecto, dejando el rango de pods que espera Calico:

   ```yaml
   # kind-calico.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   networking:
     disableDefaultCNI: true          # apagamos kindnet: no aplica NetworkPolicy
     podSubnet: "192.168.0.0/16"      # rango por defecto de Calico
   nodes:
     - role: control-plane
     - role: worker
   ```

   ```bash
   kind create cluster --name kcsa-np --config kind-calico.yaml
   ```

2. Verificar que los nodos están `NotReady` (esperado: sin CNI no hay red de pods):

   ```bash
   kubectl get nodes
   ```
   ```
   NAME                    STATUS     ROLES           AGE   VERSION
   kcsa-np-control-plane   NotReady   control-plane   40s   v1.30.0
   kcsa-np-worker          NotReady   <none>          20s   v1.30.0
   ```

3. Instalar Calico y esperar a que los nodos pasen a `Ready`:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
   kubectl -n kube-system rollout status ds/calico-node --timeout=180s
   kubectl get nodes
   ```
   ```
   NAME                    STATUS   ROLES           AGE   VERSION
   kcsa-np-control-plane   Ready    control-plane   3m    v1.30.0
   kcsa-np-worker          Ready    <none>          2m    v1.30.0
   ```

**Preguntas de verificación**

- Q0.1 — ¿Por qué los nodos aparecen `NotReady` *antes* de instalar Calico, si el API server y etcd funcionan?
- Q0.2 — Si en tu cluster de producción `kubectl apply -f una-policy.yaml` devuelve `created` pero el tráfico prohibido sigue pasando, ¿qué es lo primero que deberías verificar, y por qué no es un problema del manifiesto?
- Q0.3 — ¿A qué capas del modelo OSI opera una `NetworkPolicy` estándar de Kubernetes? Nombrá un tipo de regla que **no** puedas expresar con ella.

---

## Bloque 1 — Línea base: sin políticas, todo pasa

**Pasos**

1. Crear el namespace de trabajo y desplegar un servidor `web` (nginx) y dos clientes:

   ```bash
   kubectl create namespace app

   kubectl -n app create deployment web --image=nginx:1.27 --port=80
   kubectl -n app expose deployment web --port=80

   kubectl -n app run client-a --image=nicolaka/netshoot --labels="role=frontend" --command -- sleep infinity
   kubectl -n app run client-b --image=nicolaka/netshoot --labels="role=batch"    --command -- sleep infinity
   ```

2. Etiquetar el deployment `web` de forma explícita (los `Pod` que crea heredan `app=web`) y confirmar las etiquetas:

   ```bash
   kubectl -n app get pods --show-labels
   ```
   ```
   NAME                   READY   STATUS    RESTARTS   AGE   LABELS
   client-a               1/1     Running   0          30s   role=frontend
   client-b               1/1     Running   0          30s   role=batch
   web-6b8f9c4d7b-2xk9p   1/1     Running   0          45s   app=web,pod-template-hash=6b8f9c4d7b
   ```

3. Probar la conectividad **antes** de cualquier política. Ambos clientes deben poder llegar al servicio `web`:

   ```bash
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "client-a -> web: %{http_code}\n" --max-time 3 http://web
   kubectl -n app exec client-b -- curl -s -o /dev/null -w "client-b -> web: %{http_code}\n" --max-time 3 http://web
   ```
   ```
   client-a -> web: 200
   client-b -> web: 200
   ```

**Preguntas de verificación**

- Q1.1 — En este estado (ningún objeto `NetworkPolicy` en el namespace), ¿cómo describe la documentación oficial el estado de aislamiento de los pods? ¿Qué tráfico está permitido, ingress y egress?
- Q1.2 — El `Service` `web` tiene una `ClusterIP`, pero la conexión terminó llegando a la IP del `Pod`. ¿Sobre qué IP evalúa Calico las reglas de una `NetworkPolicy`: la del Service o la del Pod destino? ¿Por qué importa esto al escribir la regla?
- Q1.3 — ¿Es `NetworkPolicy` un objeto namespaced o cluster-scoped? ¿Qué implica eso para proteger 20 namespaces?

---

## Bloque 2 — El interruptor maestro: `default-deny-all` de ingress

**Pasos**

1. Aplicar una política que selecciona **todos** los pods del namespace (`podSelector: {}`) y no declara ninguna regla de ingress → todo ingress queda denegado:

   ```yaml
   # 01-default-deny-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: app
   spec:
     podSelector: {}            # {} = todos los pods del namespace
     policyTypes:
       - Ingress
     # sin bloque 'ingress:' => cero fuentes permitidas
   ```

   ```bash
   kubectl apply -f 01-default-deny-ingress.yaml
   ```

2. Reintentar las conexiones del Bloque 1. Ahora deben **fallar por timeout** (la conexión se descarta, no se rechaza):

   ```bash
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "client-a -> web: %{http_code}\n" --max-time 3 http://web \
     || echo "client-a -> web: BLOQUEADO (timeout)"
   ```
   ```
   command terminated with exit code 28
   client-a -> web: BLOQUEADO (timeout)
   ```

3. Confirmar que el *egress* de los clientes sigue abierto (esta política solo tocó `Ingress`). El cliente puede resolver DNS y salir a Internet, pero no llegar a `web`:

   ```bash
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "egress externo: %{http_code}\n" --max-time 3 https://kubernetes.io
   ```
   ```
   egress externo: 200
   ```

**Preguntas de verificación**

- Q2.1 — La política se llama `default-deny-ingress` pero `client-b → web` también se bloqueó. ¿Sobre qué pods aplica realmente el aislamiento: sobre las *fuentes* de tráfico o sobre los *destinos* seleccionados por `podSelector`?
- Q2.2 — El `curl` terminó en *timeout* (exit 28), no en *connection refused*. ¿Qué revela ese comportamiento sobre cómo el CNI descarta el paquete, y por qué es relevante para un atacante que hace *port scanning*?
- Q2.3 — ¿Por qué `client-a` sigue pudiendo alcanzar `kubernetes.io` a pesar de la política? ¿Qué campo tendrías que agregar a `policyTypes` para cortar también eso?
- Q2.4 — Escribí, sin mirar las respuestas, el manifiesto de un `default-deny` que corte **ingress y egress** a la vez.

---

## Bloque 3 — Abrir una rendija: `podSelector` en la regla de ingress

**Pasos**

1. Con el *default-deny* activo, autorizar **solo** a los pods con `role=frontend` a llegar a `web` por el puerto 80/TCP:

   ```yaml
   # 02-allow-frontend-to-web.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-web
     namespace: app
   spec:
     podSelector:
       matchLabels:
         app: web              # destino: los pods 'web'
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 role: frontend   # fuente permitida
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f 02-allow-frontend-to-web.yaml
   ```

2. Comprobar el resultado: `client-a` (frontend) pasa; `client-b` (batch) sigue bloqueado:

   ```bash
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "client-a (frontend) -> web: %{http_code}\n" --max-time 3 http://web
   kubectl -n app exec client-b -- curl -s -o /dev/null -w "client-b (batch)    -> web: %{http_code}\n" --max-time 3 http://web \
     || echo "client-b (batch)    -> web: BLOQUEADO"
   ```
   ```
   client-a (frontend) -> web: 200
   command terminated with exit code 28
   client-b (batch)    -> web: BLOQUEADO
   ```

3. Verificar la naturaleza **aditiva** de las políticas: `allow-frontend-to-web` y `default-deny-ingress` conviven; el resultado es la *unión* de lo que cada una permite:

   ```bash
   kubectl -n app get networkpolicy
   ```
   ```
   NAME                    POD-SELECTOR   AGE
   allow-frontend-to-web   app=web        3m
   default-deny-ingress    <none>         12m
   ```

**Preguntas de verificación**

- Q3.1 — Hay dos políticas de ingress sobre el pod `web`. ¿El resultado es una *intersección* (AND) o una *unión* (OR) de sus reglas? Enunciá la regla general del modelo.
- Q3.2 — Si borraras `default-deny-ingress` y dejaras **solo** `allow-frontend-to-web`, ¿cambiaría en algo el resultado observado para `client-b`? Justificá.
- Q3.3 — La regla incluye `ports: [{port: 80}]`. Si un atacante lograra que `web` también escuchara en el 8080, ¿ese puerto quedaría accesible desde `client-a`? ¿Qué principio de seguridad ilustra esto?
- Q3.4 — En el bloque `from`, `podSelector` selecciona pods **¿de qué namespace?** ¿Qué pasaría con un pod `role=frontend` que viviera en el namespace `monitoring`?

---

## Bloque 4 — El *gotcha* del examen: `namespaceSelector` y AND vs OR

**Pasos**

1. Crear un namespace `monitoring` con una etiqueta identificatoria y un pod `prometheus` dentro:

   ```bash
   kubectl create namespace monitoring
   kubectl label namespace monitoring team=observability
   kubectl -n monitoring run prometheus --image=nicolaka/netshoot --labels="app=prometheus" --command -- sleep infinity
   ```

2. Confirmar que, con las políticas actuales, `prometheus` **no** puede llegar a `web` (está en otro namespace y no es `role=frontend`):

   ```bash
   kubectl -n monitoring exec prometheus -- curl -s -o /dev/null -w "prometheus -> web: %{http_code}\n" --max-time 3 http://web.app.svc.cluster.local \
     || echo "prometheus -> web: BLOQUEADO"
   ```
   ```
   prometheus -> web: BLOQUEADO
   ```

3. Autorizar el scraping cross-namespace. **Observá la sintaxis con lupa**: `namespaceSelector` y `podSelector` van como **un solo elemento** de la lista `from` (sin `-` delante del segundo) → esto significa **AND**:

   ```yaml
   # 03-allow-monitoring-scrape.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-monitoring-scrape
     namespace: app
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:          # AND: pods 'app=prometheus'
               matchLabels:              #      QUE ADEMÁS estén en un
                 team: observability     #      namespace 'team=observability'
             podSelector:
               matchLabels:
                 app: prometheus
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f 03-allow-monitoring-scrape.yaml
   kubectl -n monitoring exec prometheus -- curl -s -o /dev/null -w "prometheus -> web: %{http_code}\n" --max-time 3 http://web.app.svc.cluster.local
   ```
   ```
   prometheus -> web: 200
   ```

4. **Contraejemplo — el error clásico.** Cambiar el AND por un OR agregando un `-` que convierte los dos selectores en **elementos separados** de la lista, y observar el efecto sobre la superficie de ataque:

   ```yaml
   # 03b-allow-monitoring-scrape-OR.yaml  (¡inseguro! solo para observar)
     ingress:
       - from:
           - namespaceSelector:          # OR: CUALQUIER pod de un namespace
               matchLabels:              #     'team=observability'  ...
                 team: observability
           - podSelector:                # ... O CUALQUIER pod 'app=prometheus'
               matchLabels:              #     en el namespace 'app'
                 app: prometheus
   ```

   Con esta variante, un pod cualquiera dentro de `monitoring` (aunque no sea `prometheus`) podría alcanzar `web`.

**Preguntas de verificación**

- Q4.1 — Enunciá la regla de sintaxis YAML que distingue el **AND** del **OR** dentro de un bloque `from`. ¿Dónde está el guion (`-`) en cada caso?
- Q4.2 — En la variante OR del paso 4, describí exactamente qué pods pasan a tener acceso a `web` que antes no lo tenían. ¿Por qué es una regla peligrosamente permisiva?
- Q4.3 — Desde Kubernetes 1.21+, todo namespace lleva una etiqueta automática. ¿Cuál es, y cómo la usarías para permitir tráfico de un namespace específico **sin** tener que etiquetarlo a mano?
- Q4.4 — `prometheus` usó el FQDN `web.app.svc.cluster.local`. Para que esa resolución funcione, ¿qué tráfico de *egress* necesitó el pod `prometheus`, y por qué en este bloque no hizo falta declararlo?

---

## Bloque 5 — Cerrar la otra dirección: control de *egress* y la trampa del DNS

**Pasos**

1. Imponer un *default-deny* de **egress** sobre los clientes de `app`. Observá que esto rompe la resolución DNS:

   ```yaml
   # 04-default-deny-egress.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-egress
     namespace: app
   spec:
     podSelector: {}
     policyTypes:
       - Egress
   ```

   ```bash
   kubectl apply -f 04-default-deny-egress.yaml
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 http://web \
     || echo "client-a -> web: FALLO (probablemente DNS)"
   kubectl -n app exec client-a -- nslookup web 2>&1 | tail -3
   ```
   ```
   client-a -> web: FALLO (probablemente DNS)
   ;; connection timed out; no servers could be reached
   ```

2. Diagnosticar: la resolución de `web` falla porque el pod ya no puede alcanzar a CoreDNS (UDP/53 hacia `kube-system`). Localizar las etiquetas del namespace `kube-system` y del `Service` de DNS:

   ```bash
   kubectl get namespace kube-system --show-labels
   kubectl -n kube-system get pods -l k8s-app=kube-dns
   ```
   ```
   NAME          STATUS   AGE   LABELS
   kube-system   Active   30m   kubernetes.io/metadata.name=kube-system

   NAME                       READY   STATUS    RESTARTS   AGE
   coredns-7db6d8ff4d-abcde   1/1     Running   0          30m
   coredns-7db6d8ff4d-fghij   1/1     Running   0          30m
   ```

3. Reabrir **solo** lo mínimo: DNS hacia CoreDNS (UDP y TCP/53) y HTTP hacia los pods `web`. Todo lo demás queda cortado:

   ```yaml
   # 05-egress-dns-and-web.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: egress-dns-and-web
     namespace: app
   spec:
     podSelector:
       matchLabels:
         role: frontend
     policyTypes:
       - Egress
     egress:
       - to:                                   # 1) DNS a CoreDNS
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
             podSelector:
               matchLabels:
                 k8s-app: kube-dns
         ports:
           - protocol: UDP
             port: 53
           - protocol: TCP
             port: 53
       - to:                                   # 2) HTTP hacia 'web'
           - podSelector:
               matchLabels:
                 app: web
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f 05-egress-dns-and-web.yaml
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "client-a -> web: %{http_code}\n" --max-time 3 http://web
   kubectl -n app exec client-a -- curl -s -o /dev/null -w "client-a -> internet: %{http_code}\n" --max-time 3 https://kubernetes.io \
     || echo "client-a -> internet: BLOQUEADO"
   ```
   ```
   client-a -> web: 200
   client-a -> internet: BLOQUEADO
   ```

**Preguntas de verificación**

- Q5.1 — El *default-deny-egress* rompió la aplicación de una forma sutil: no falló la conexión a `web`, falló *antes*. ¿Qué dependencia de red implícita tiene casi todo pod y que casi siempre se olvida al escribir políticas de egress?
- Q5.2 — La regla de DNS abre **UDP/53 y TCP/53**. ¿Por qué ambos, si las consultas normales usan UDP?
- Q5.3 — ¿Por qué el *egress* controlado es una defensa clave contra la exfiltración de datos y el *command-and-control* de un pod comprometido, más allá del *ingress*?
- Q5.4 — La política `egress-dns-and-web` selecciona `role=frontend`, mientras `default-deny-egress` selecciona `{}` (todos). ¿`client-b` (`role=batch`) tiene egress hacia DNS? ¿Qué le pasaría a `client-b` si intentara resolver un nombre?

---

## Bloque 6 — `ipBlock`: permitir/negar por CIDR y el `except`

**Pasos**

1. Suponé que `web` debe aceptar tráfico de ingress desde un rango de una red corporativa externa (por ejemplo un balanceador on-prem `203.0.113.0/24`) **excepto** una subred de invitados. Escribí la política con `ipBlock` y `except`:

   ```yaml
   # 06-allow-corp-cidr.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-corp-cidr
     namespace: app
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
       - Ingress
     ingress:
       - from:
           - ipBlock:
               cidr: 203.0.113.0/24        # red corporativa
               except:
                 - 203.0.113.128/25        # menos la subred de invitados
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f 06-allow-corp-cidr.yaml
   kubectl -n app describe networkpolicy allow-corp-cidr | sed -n '/Ingress/,/Egress/p'
   ```
   ```
   Ingress:
     Allowing ingress traffic:
       To Port: 80/TCP
       From IPBlock:
         CIDR: 203.0.113.0/24
         Except: 203.0.113.128/25
   ```

**Preguntas de verificación**

- Q6.1 — ¿Cuándo usarías `ipBlock` en lugar de `podSelector`/`namespaceSelector`? Dado que Kubernetes hace NAT/SNAT en varios caminos, ¿qué precaución hay con la IP de origen que ve el CNI para tráfico que entra al cluster?
- Q6.2 — ¿Qué rango de direcciones queda finalmente permitido tras aplicar `cidr: 203.0.113.0/24` con `except: 203.0.113.128/25`? Escribilo como rango.
- Q6.3 — ¿Por qué `ipBlock` es la herramienta apropiada para permitir egress hacia un endpoint externo (una API SaaS por IP), y qué fragilidad introduce frente a servicios detrás de DNS/CDN con IPs rotativas?

---

## Bloque 7 — Diagnóstico y limpieza

**Pasos**

1. Auditar todas las políticas de un namespace y qué pods selecciona cada una:

   ```bash
   kubectl -n app get networkpolicy
   for np in $(kubectl -n app get networkpolicy -o name); do
     echo "== $np =="
     kubectl -n app describe "$np" | grep -E "PodSelector|Allowing|Not affecting"
   done
   ```

2. Ante "el tráfico no fluye y no sé por qué", el árbol de decisión mínimo:

   - ¿El CNI aplica políticas? (`kubectl -n kube-system get pods | grep -Ei 'calico|cilium'`)
   - ¿Hay un *default-deny* que olvidaste? (`kubectl -n <ns> get netpol`)
   - ¿Las **etiquetas** del pod/namespace coinciden *exactamente* con los selectores? (`kubectl get pod --show-labels`, `kubectl get ns --show-labels`)
   - ¿Olvidaste el **egress de DNS**? (síntoma: falla resolución, no la conexión)
   - ¿El `port`/`protocol` de la regla coincide con el que realmente escucha el destino?

3. Destruir el cluster de práctica:

   ```bash
   kind delete cluster --name kcsa-np
   ```

**Preguntas de verificación**

- Q7.1 — Un compañero jura que su `NetworkPolicy` "no funciona": el tráfico prohibido sigue pasando. `describe` muestra la política correcta. ¿Cuáles son las **dos** causas más probables, en orden, y con qué comando descartás cada una?
- Q7.2 — Otra política "bloquea de más": un pod legítimo perdió acceso. El manifiesto se ve bien. ¿Qué dos discrepancias de *labels* revisarías primero?
- Q7.3 — Resumí en una frase el modelo mental completo de NetworkPolicy que deberías poder recitar en el examen (aislamiento, unión de reglas, direccionalidad, dependencia del CNI).

---

<details>
<summary><strong>Respuestas y explicaciones</strong></summary>

### Bloque 0

**Q0.1** — El kubelet reporta `NotReady` porque una de sus condiciones de salud es que el *network plugin* esté inicializado (`NetworkReady`). Sin CNI, no puede configurar la red de los pods, así que aunque el control plane (API server, etcd, scheduler) funcione, el nodo no acepta cargas de trabajo de red. Al desplegar Calico, cada nodo obtiene su `calico-node` y la condición se satisface.

**Q0.2** — Lo primero es verificar que el **CNI plugin instalado implementa la spec de NetworkPolicy** y está *enforcing* (`kubectl -n kube-system get pods` buscando `calico`/`cilium`/`weave`; revisar que no sea `kindnet`/Flannel a secas). El objeto `NetworkPolicy` es solo una declaración en la API; el `apply` siempre "tiene éxito" porque el API server solo valida el esquema. **Quien descarta paquetes es el CNI**, no Kubernetes. No es un problema del manifiesto: es que nadie lo está haciendo cumplir.

**Q0.3** — Opera en **L3 (IP)** y **L4 (puerto/protocolo TCP/UDP/SCTP)**. No podés expresar reglas L7 con la spec estándar: nada de "permitir solo `GET /health`", filtrado por header HTTP, por método, por hostname TLS/SNI, ni por identidad de aplicación. Eso requiere extensiones del CNI (p. ej. `CiliumNetworkPolicy`) o un service mesh.

### Bloque 1

**Q1.1** — Con cero políticas que los seleccionen, los pods están **no aislados** (*non-isolated*): permiten **todo el ingress y todo el egress**, en cualquier dirección, desde/hacia cualquier origen. Es un modelo *allow-all* por defecto (el opuesto de zero-trust).

**Q1.2** — Calico evalúa las reglas sobre la **IP del Pod destino**, no la ClusterIP del Service. `kube-proxy` (o el eBPF del CNI) hace DNAT de la ClusterIP a una IP de pod *antes* de que la política se evalúe. Consecuencia práctica: en la regla seleccionás el **pod** por sus *labels* (`podSelector`), nunca por el Service.

**Q1.3** — Es **namespaced**. No existe una NetworkPolicy que cubra todo el cluster de una vez con la API estándar (para eso están las CRDs globales de cada CNI, p. ej. `GlobalNetworkPolicy` de Calico). Para 20 namespaces necesitás replicar el *default-deny* en cada uno; se automatiza con GitOps/Kyverno o con las políticas globales del CNI.

### Bloque 2

**Q2.1** — El aislamiento aplica sobre los **destinos** seleccionados por `podSelector`. `podSelector: {}` selecciona *todos* los pods del namespace como destinos aislados; por eso `web` (destino) queda sin ingress permitido y `client-b → web` se corta. La política no dice nada sobre quién es la *fuente*: simplemente ninguna fuente está autorizada.

**Q2.2** — El *timeout* (exit 28 de curl) indica que el paquete se **descarta silenciosamente** (*drop*), no se rechaza con un RST/ICMP. Para un atacante que escanea puertos, un *drop* es más costoso: no distingue "puerto cerrado" de "filtrado", los escaneos son más lentos y menos informativos. Es el comportamiento deseado en zero-trust.

**Q2.3** — Porque `default-deny-ingress` solo lista `Ingress` en `policyTypes`; el **egress permanece no aislado** (allow-all). Para cortar la salida hay que agregar `Egress` a `policyTypes` (y, si querés denegar todo, no incluir bloque `egress`).

**Q2.4** —
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: app
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Bloque 3

**Q3.1** — **Unión (OR)**. Las políticas son puramente aditivas: un paquete se permite si **al menos una** política lo autoriza. No existen reglas de "deny" explícitas en la spec estándar; la denegación surge de *no ser permitido por ninguna*. Por eso `default-deny` + `allow-frontend` = "todo denegado, salvo frontend".

**Q3.2** — **No cambiaría nada** para `client-b`. En cuanto `web` es seleccionado por *cualquier* política de Ingress (aquí, `allow-frontend-to-web`), pasa a estar aislado para ingress y solo se permite lo explícitamente listado. El *default-deny* separado es redundante para `web` (pero sí protege a los demás pods del namespace que ninguna otra política toca).

**Q3.3** — **No**, el 8080 quedaría bloqueado: la regla solo permite `port: 80`. Ilustra el **principio de mínimo privilegio** aplicado a puertos: cerrás la superficie a exactamente lo que la app necesita, de modo que un servicio abierto por error o por un exploit no queda alcanzable.

**Q3.4** — Un `podSelector` dentro de `from` selecciona pods **del mismo namespace que la política** (aquí `app`). Un pod `role=frontend` en `monitoring` **no** sería autorizado por esta regla: para permitir orígenes de otro namespace hay que combinar con `namespaceSelector` (Bloque 4).

### Bloque 4

**Q4.1** — Todo depende del **guion (`-`)**, que en YAML marca un elemento de lista:
- **AND** — un solo elemento de `from` con *ambos* selectores como *claves* del mismo objeto:
  ```yaml
  from:
    - namespaceSelector: {...}
      podSelector: {...}      # sin '-': misma entrada => AND
  ```
- **OR** — *dos* elementos de la lista, cada uno con su `-`:
  ```yaml
  from:
    - namespaceSelector: {...}
    - podSelector: {...}      # '-' propio: entrada aparte => OR
  ```

**Q4.2** — En la variante OR, quedan autorizados: **(a)** *cualquier* pod que viva en un namespace con `team=observability` (todo `monitoring`, sea `prometheus` o no), **y** **(b)** *cualquier* pod con `app=prometheus` **en el namespace `app`**. Es peligrosa porque amplía el acceso a todos los pods de `monitoring` — un pod comprometido ahí (o uno nuevo sin relación con el scraping) obtiene acceso a `web` gratis.

**Q4.3** — La etiqueta automática es **`kubernetes.io/metadata.name: <nombre-del-namespace>`** (inyectada por el `NamespaceDefaultLabelName` admission desde 1.21). Permite seleccionar un namespace por su nombre sin etiquetarlo manualmente:
```yaml
namespaceSelector:
  matchLabels:
    kubernetes.io/metadata.name: monitoring
```

**Q4.4** — Necesitó **egress DNS (UDP/TCP 53) hacia CoreDNS** para resolver el FQDN, más el egress hacia `web`. No hubo que declararlo porque en el namespace `monitoring` **no existía ninguna política de egress**, así que `prometheus` seguía *no aislado* para egress (allow-all). El problema de DNS recién aparece cuando imponés un *default-deny-egress* (Bloque 5).

### Bloque 5

**Q5.1** — La **resolución DNS**: casi todo pod depende de alcanzar CoreDNS (`kube-dns`, UDP/53 en `kube-system`) para traducir nombres de Service a IPs. Un *default-deny-egress* corta ese tráfico y la app "falla a conectar" cuando en realidad falla a *resolver*. Es el error más común al escribir políticas de egress: hay que permitir DNS explícitamente.

**Q5.2** — Porque el DNS usa **UDP/53 por defecto**, pero conmuta a **TCP/53** cuando la respuesta excede el tamaño del datagrama UDP (respuestas grandes, o cuando el flag `TC`/truncado está activo). Si solo abrís UDP, las consultas con respuestas grandes fallan de forma intermitente y difícil de diagnosticar.

**Q5.3** — El *ingress* protege *contra* la entrada, pero un pod comprometido daña *saliendo*: exfiltra datos hacia un servidor externo, descarga un *second stage*, o llama a su C2. El *egress* restringido hace que, aun con RCE dentro del pod, el atacante no pueda **hablar hacia afuera** salvo a los destinos que la app legítimamente necesita. Es la mitad frecuentemente olvidada del zero-trust.

**Q5.4** — **No.** `egress-dns-and-web` solo selecciona `role=frontend`, así que no le da egress a `client-b` (`role=batch`). Pero `default-deny-egress` (`podSelector: {}`) **sí** selecciona a `client-b` y lo aísla. Resultado: `client-b` tiene egress **totalmente denegado**; si intentara `nslookup`, fallaría por timeout de DNS. Para arreglarlo habría que darle su propia política de egress (al menos DNS).

### Bloque 6

**Q6.1** — Usás `ipBlock` para orígenes/destinos que **no son pods del cluster**: rangos externos, on-prem, servicios gestionados por IP. Precaución: para tráfico que **entra** al cluster, la IP de origen que ve el CNI puede estar **enmascarada por SNAT** (según `externalTrafficPolicy`, el tipo de Service, el load balancer o el node como salto). Si hay SNAT, el `ipBlock` con la IP real del cliente no matchea; suele ser necesario `externalTrafficPolicy: Local` u observar la IP tras el NAT.

**Q6.2** — `203.0.113.0/24` es `.0`–`.255`; al restar `203.0.113.128/25` (`.128`–`.255`), queda permitido **`203.0.113.0` – `203.0.113.127`** (equivalente a `203.0.113.0/25`).

**Q6.3** — `ipBlock` es lo apropiado para egress a un endpoint externo porque las NetworkPolicies operan sobre **IP/CIDR**, no sobre nombres DNS. La fragilidad: si el destino está detrás de **DNS/CDN con IPs rotativas** (SaaS, balanceadores geo-distribuidos), el conjunto de IPs cambia y la lista queda desactualizada — se rompe el acceso legítimo o te obliga a un CIDR demasiado amplio. Filtrado por *nombre* (FQDN policies) solo lo dan extensiones del CNI, no la spec estándar.

### Bloque 7

**Q7.1** — En orden de probabilidad:
1. **El CNI no aplica políticas** (o no soporta la spec). Descartás con `kubectl -n kube-system get pods` (¿hay `calico`/`cilium` corriendo, o es `kindnet`/Flannel plano?).
2. **Los `podSelector`/`namespaceSelector` no matchean** por *labels* mal escritas, de modo que la política no selecciona el destino que creías (y ese pod sigue *non-isolated*). Descartás con `kubectl get pod/ns --show-labels` y comparás contra el selector.

**Q7.2** — (1) Las **labels del pod origen** no coinciden con el `podSelector` del bloque `from` (typo, valor distinto). (2) Las **labels del namespace** no coinciden con el `namespaceSelector` (olvidaste etiquetar el namespace, o usaste la clave equivocada en vez de `kubernetes.io/metadata.name`). Un tercer sospechoso: confundiste **AND vs OR** (Q4.1) y la regla es más estricta de lo que creías.

**Q7.3** — *"Un pod queda aislado solo en la dirección (ingress/egress) para la que alguna NetworkPolicy lo selecciona; entonces únicamente el tráfico explícitamente permitido por la unión (OR) de esas políticas pasa, todo lo demás se descarta — y nada de esto ocurre a menos que el CNI implemente y aplique la spec."*

</details>