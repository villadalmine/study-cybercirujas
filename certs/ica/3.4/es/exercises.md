# 3.4 Configuración del Traffic Shifting — Ejercicios Guiados

El traffic shifting es la migración controlada del volumen de solicitudes de una versión de un workload a otra según el **weight**, desacoplada de la cantidad de réplicas de Pods en ejecución. En Istio esto se expresa por completo en el control plane: un `DestinationRule` nombra los *subsets* (las versiones), y un `VirtualService` asigna un `weight` porcentual a cada subset dentro de un `HTTPRoute`. Los sidecars de Envoy aplican la división por solicitud — el escalado y la readiness del `Service` de Kubernetes son irrelevantes para la proporción.

Estos ejercicios construyen un despliegue canary a partir de una línea base fija, lo llevan hasta completarse, lo revierten, y luego combinan el weighting con el matching de headers y el mirroring de tráfico. Cada paso es verificable desde la CLI.

**Topología del laboratorio.** El sample oficial `helloworld` incluye dos deployments — `helloworld-v1` y `helloworld-v2` — ambos detrás de un único `Service` (`helloworld:5000`), y cada uno devuelve un body que indica su versión. Un Pod `sleep` dentro de la mesh es el cliente, de modo que podemos contar la distribución de respuestas de forma determinista.

Fuentes de referencia:
- Tarea de traffic shifting — https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- `HTTPRouteDestination.weight` de VirtualService — https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRouteDestination
- Subsets de DestinationRule — https://istio.io/latest/docs/reference/config/networking/destination-rule/#Subset
- Tarea de traffic mirroring — https://istio.io/latest/docs/tasks/traffic-management/mirroring/

---

## Ejercicio 1 — Establecer una línea base fija (100% v1)

Antes de desviar nada, tenés que poder *detener* el desvío. El punto de partida seguro es un `VirtualService` que envíe **todo** el tráfico a un único subset. Sin una regla explícita, Istio hace round-robin entre todos los endpoints del `Service`, mezclando versiones — eso no es un estado controlado.

1. Creá el namespace de la mesh y habilitá la inyección de sidecars:

   ```bash
   kubectl create namespace demo
   kubectl label namespace demo istio-injection=enabled --overwrite
   ```

2. Desplegá las dos versiones y el cliente:

   ```bash
   kubectl -n demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/helloworld/helloworld.yaml
   kubectl -n demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/sleep/sleep.yaml
   kubectl -n demo rollout status deploy/helloworld-v1
   kubectl -n demo rollout status deploy/helloworld-v2
   ```

3. Confirmá que, *sin regla de ruteo*, el tráfico se divide aproximadamente 50/50 por defecto (cada versión tiene un endpoint):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado (aproximado — round-robin simple, no una política):

   ```
     11 version: v1
      9 version: v2
   ```

4. Declará los subsets con un `DestinationRule`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: helloworld
     namespace: demo
   spec:
     host: helloworld
     subsets:
     - name: v1
       labels:
         version: v1
     - name: v2
       labels:
         version: v2
   ```

5. Fijá el 100% del tráfico a `v1` con un `VirtualService`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 100
       - destination:
           host: helloworld
           subset: v2
         weight: 0
   ```

6. Aplicá ambos y volvé a ejecutar la verificación de distribución:

   ```bash
   kubectl -n demo apply -f destinationrule.yaml -f virtualservice.yaml
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado:

   ```
     20 version: v1
   ```

**Verificación de comprensión 1**

1. Ambas versiones siguen teniendo un Pod en ejecución cada una. ¿Por qué cambió la distribución de ~50/50 a 100/0 sin tocar ningún `Deployment`?
2. ¿Qué se rompe si aplicás el `VirtualService` del paso 5 **antes** que el `DestinationRule` del paso 4?
3. La regla envía el 100% a `v1`. ¿Cuál es la diferencia práctica entre incluir `subset: v2` con `weight: 0` versus omitir por completo el destino `v2`?

---

## Ejercicio 2 — Introducir un canary del 10%

Ahora desviá una pequeña porción a `v2` manteniendo abierto el camino de rollback. Un weight de canary permite que una fracción real del tráfico de producción ejercite la nueva versión antes de confiar en ella.

1. Parcheá los weights a 90/10:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 90
       - destination:
           host: helloworld
           subset: v2
         weight: 10
   ```

2. Aplicá y muestreá una población más grande para que la proporción sea significativa:

   ```bash
   kubectl -n demo apply -f virtualservice.yaml
   for i in $(seq 1 100); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado (estadístico, no exacto):

   ```
     88 version: v1
     12 version: v2
   ```

3. Inspeccioná qué programó realmente el Envoy del *cliente* — los weights se convierten en weighted clusters en la configuración de rutas:

   ```bash
   istioctl -n demo proxy-config routes deploy/sleep --name 5000 -o json \
     | grep -A2 -i 'weightedClusters\|weight'
   ```

   Fragmento esperado:

   ```json
   "weightedClusters": {
     "clusters": [
       { "name": "outbound|5000|v1|helloworld.demo.svc.cluster.local", "weight": 90 },
       { "name": "outbound|5000|v2|helloworld.demo.svc.cluster.local", "weight": 10 }
     ]
   }
   ```

**Verificación de comprensión 2**

1. En el paso 3 la división se aplica en el **sidecar de `sleep`** (el llamador), no en los Pods de `helloworld`. ¿Qué te dice esto sobre *dónde* se toma la decisión de traffic shifting L7 de Istio, y por qué importa para la latencia y el blast radius?
2. Si escalaras `helloworld-v2` de 1 réplica a 10, ¿la división observada se movería hacia 50/50? Explicá.
3. Muestreaste 100 solicitudes y viste 12 caer en `v2`. ¿Está rota la regla? ¿Qué cambiarías para reducir el ruido en esta medición?

---

## Ejercicio 3 — Rollout progresivo hasta 100%, y luego rollback

Un rollout es una secuencia de ediciones de weight, cada una condicionada por la telemetría de la etapa anterior. Acá avanzás 10 → 50 → 100, y luego realizás un rollback instantáneo.

1. Pasá a 50/50:

   ```bash
   kubectl -n demo patch virtualservice helloworld --type merge -p '
   spec:
     http:
     - route:
       - destination: {host: helloworld, subset: v1}
         weight: 50
       - destination: {host: helloworld, subset: v2}
         weight: 50'
   ```

2. Verificá el punto medio sobre 100 solicitudes (esperá ≈50/50), y luego cambiá por completo a `v2`:

   ```yaml
   # virtualservice-v2.yaml — single destination, weight is now optional
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v2
   ```

   ```bash
   kubectl -n demo apply -f virtualservice-v2.yaml
   for i in $(seq 1 30); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado:

   ```
     30 version: v2
   ```

3. Simulá una regresión descubierta en producción y **hacé rollback instantáneo** a `v1`:

   ```bash
   kubectl -n demo patch virtualservice helloworld --type merge -p '
   spec:
     http:
     - route:
       - destination: {host: helloworld, subset: v1}'
   ```

4. Confirmá que el rollback surtió efecto y medí qué tan rápido se propagó (Envoy toma la configuración empujada en bastante menos de un segundo — sin reinicio de Pods):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado:

   ```
     20 version: v1
   ```

**Verificación de comprensión 3**

1. En el paso 2 la regla final tiene un único `destination` y **ningún campo `weight`**, y aun así Istio la acepta. ¿Cuál es la regla sobre cuándo `weight` es obligatorio versus opcional entre los destinos de un `HTTPRoute`?
2. ¿Qué pasa al momento de aplicar si escribís `weight: 60` para `v1` y `weight: 30` para `v2` (suma = 90)? ¿Se rechaza, se normaliza silenciosamente, o algo distinto?
3. El rollback del paso 3 no requirió ningún `kubectl rollout undo` ni cambio de imagen. Explicá, en términos del data plane, por qué el traffic shifting te da un rollback más rápido que un rolling update de un `Deployment` de Kubernetes.

---

## Ejercicio 4 — Canary condicionado por header combinado con weighting

El weighting es ciego respecto de *quién* es el llamador. Combinar un bloque `match` con un bloque con weight te permite rutear una cohorte conocida (testers internos) de forma determinista a `v2` mientras el público anónimo sigue siendo desviado solo por porcentaje. **El orden importa: las entradas de `HTTPRoute` se evalúan de arriba hacia abajo, gana la primera coincidencia.**

1. Aplicá un `VirtualService` de dos reglas: `end-user: tester` siempre obtiene `v2`; todos los demás obtienen un canary 95/5:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - match:
       - headers:
           end-user:
             exact: tester
       route:
       - destination:
           host: helloworld
           subset: v2
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 95
       - destination:
           host: helloworld
           subset: v2
         weight: 5
   ```

2. Comprobá que la cohorte está fijada — el header de tester siempre cae en `v2`:

   ```bash
   for i in $(seq 1 10); do
     kubectl -n demo exec deploy/sleep -c sleep -- \
       curl -s -H 'end-user: tester' helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado:

   ```
     10 version: v2
   ```

3. Comprobá que el público anónimo sigue el weighting 95/5:

   ```bash
   for i in $(seq 1 100); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado (≈95/5):

   ```
     96 version: v1
      4 version: v2
   ```

**Verificación de comprensión 4**

1. ¿Qué le pasa a una solicitud que lleva `end-user: tester` si **invertís el orden** de las dos entradas `http` (el bloque con weight primero, el bloque con match segundo)?
2. El bloque con match rutea a un único subset sin `weight`. ¿Podrías también aplicar un weight *dentro* de un bloque con match (por ejemplo, dividir la cohorte de header 70/30)? ¿Qué te permite modelar eso?
3. Llega una solicitud con el header `end-user: qa-bot`. ¿Qué bloque la atiende, y por qué?

---

## Ejercicio 5 — Mirroring (shadow) de tráfico para validar v2 con riesgo cero para el usuario

El mirroring copia las solicitudes en vivo hacia un segundo subset **fire-and-forget**: las respuestas espejadas se descartan, de modo que `v2` maneja patrones reales de tráfico de producción sin que ningún usuario vea nunca su salida. Esta es la validación pre-canary más segura posible.

1. Enviá el 100% del tráfico en vivo a `v1`, y espejá el 100% de este hacia `v2`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 100
       mirror:
         host: helloworld
         subset: v2
       mirrorPercentage:
         value: 100.0
   ```

2. Confirmá que el cliente solo *ve* `v1` (las respuestas espejadas se descartan):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Esperado:

   ```
     20 version: v1
   ```

3. Confirmá que `v2` de todos modos está recibiendo la carga shadow observando sus logs — fijate en el sufijo `-shadow` que Istio agrega al `Host`/`Authority` de la solicitud espejada:

   ```bash
   kubectl -n demo logs deploy/helloworld-v2 -c helloworld --tail=5
   ```

   Esperado (una línea shadow por cada solicitud en vivo):

   ```
   127.0.0.1 - - [.. ] "GET /hello HTTP/1.1" 200 60 "-" "curl/8.5.0"
   servicing request for helloworld-shadow:5000
   ```

**Verificación de comprensión 5**

1. `v2` es un servicio que escribe en base de datos. ¿Por qué es **peligroso** el mirroring acá a pesar de que el cliente nunca ve la respuesta de v2, y qué propiedad de la solicitud espejada le permite a un backend bien diseñado detectar y rechazar la escritura shadow?
2. El `weight` del destino `route` primario es `100`. ¿El `mirrorPercentage` de `100.0` se suma a eso, convirtiéndolo en "200% del tráfico"? Explicá la contabilidad.
3. Bajás `mirrorPercentage.value` a `10.0`. ¿Qué se espeja ahora, y qué se sigue sirviendo a usuarios reales?

---

## Limpieza

```bash
kubectl delete namespace demo
```

---

<details>
<summary>Respuestas</summary>

**Verificación de comprensión 1**

1. El traffic shifting en Istio es una **decisión de ruteo del control plane**, no un efecto de la cantidad de réplicas. El weight del `VirtualService` se compila en weighted clusters en la tabla de rutas de Envoy de cada llamador; el sidecar entonces elige el subset por solicitud sin importar cuántos Pods tenga cada subset. La cantidad de réplicas solo afecta la carga *dentro* de un subset elegido, nunca la proporción entre subsets.
2. No se rutea nada: el `VirtualService` referencia `subset: v1`/`subset: v2`, pero esos nombres de subset los define el `DestinationRule`. Sin el `DestinationRule`, los subsets son desconocidos y Envoy no tiene un cluster que coincida — las solicitudes a esas rutas fallan (típicamente HTTP 503 `NR`/`no healthy upstream`). `istioctl analyze` marca esto como un subset referenciado-pero-no-definido. Aplicá el `DestinationRule` primero (o ambos juntos; el orden dentro de un único `apply` está bien porque la configuración converge).
3. Funcionalmente idéntico para el ruteo — ambos envían 0% a `v2`. Pero listar `v2` con `weight: 0` mantiene el destino *declarado*, lo que hace que las ediciones progresivas sean un cambio de un solo campo y mantiene la intención visible en el manifiesto y en el grafo de Kiali. Omitirlo es más limpio pero oculta que `v2` existe en el panorama de ruteo. Es un trade-off de legibilidad/operabilidad, no de comportamiento.

**Verificación de comprensión 2**

1. La división se aplica en el **sidecar del llamador** (balanceo de carga del lado del cliente). Istio empuja la tabla de ruteo a cada proxy, así que la decisión ocurre en el origen antes de que la solicitud deje al llamador — no hay un salto de red extra hacia un router central, lo que mantiene baja la latencia y significa que la mala configuración de un solo llamador no puede afectar las divisiones de otros llamadores. El blast radius de un weight malo está acotado por el push de configuración, y el rollback es otro push, no un redespliegue.
2. No. Escalar `v2` a 10 réplicas cambia el balanceo de carga *dentro* del subset `v2` (10 endpoints comparten el 10% de v2), pero el weight entre subsets se mantiene en 90/10. El weight es independiente de la cantidad de réplicas — ese desacoplamiento es todo el sentido del traffic shifting por weight.
3. No está rota. Con un weight del 10% sobre 100 muestras el conteo sigue una distribución binomial; 12 (o 7, o 14) es ruido de muestreo normal. Para ajustar la medición, aumentá el tamaño de muestra (por ejemplo 1000+ solicitudes) o usá un generador de carga como `fortio` — la proporción observada converge al 10% a medida que N crece.

**Verificación de comprensión 3**

1. `weight` es **opcional cuando una ruta tiene un único destino** (obtiene implícitamente el 100%). Cuando una ruta tiene **dos o más** destinos, cada destino debe llevar un `weight` y los weights **deben sumar 100**. Por eso la regla final de un solo destino no necesita weight, mientras que las reglas 90/10 y 50/50 requieren ambos campos.
2. Es **rechazada en la admisión**. Istio valida que múltiples destinos con weight sumen exactamente 100; una suma de 90 falla la validación del webhook (`kubectl apply` devuelve un error) en lugar de normalizarse silenciosamente. Hacé siempre que los weights sumen 100.
3. Revertir un weight es una **operación puramente del control plane**: Istiod recalcula la configuración de rutas y la empuja a los sidecars, que intercambian los weighted clusters activos en el lugar — sin descarga de imagen, sin terminación de Pods, sin espera de readiness. Un rolling update de `Deployment` debe schedulear, descargar, iniciar y pasar los readiness probes en los Pods nuevos/viejos, así que está acotado por el tiempo del ciclo de vida de los Pods. El rollback del traffic shifting es efectivamente instantáneo (un único push de configuración, típicamente sub-segundo).

**Verificación de comprensión 4**

1. Si el bloque con weight (sin match) va primero, **no tiene condición `match`, así que coincide con todo** — incluida la solicitud del tester — y como gana la primera coincidencia, el bloque `end-user: tester` que está debajo se convierte en código muerto que nunca se alcanza. El tester quedaría entonces sujeto a la división 95/5 como todos los demás. Las reglas `match` específicas siempre deben preceder al catch-all.
2. Sí. Un bloque `match` y los destinos con weight son ortogonales: podés poner múltiples destinos con weight *dentro* de un bloque con match para dividir una cohorte específica (por ejemplo, testers 70% a `v2`, 30% a `v1`). Esto modela canaries por cohorte — distintas velocidades de rollout para usuarios internos versus el público.
3. Lo atiende el **bloque con weight (el segundo)**. El primer bloque coincide solo con el valor exacto `tester`; `qa-bot` no coincide, así que la evaluación cae hacia la ruta con weight catch-all y la solicitud queda sujeta a la división 95/5.

**Verificación de comprensión 5**

1. El mirroring copia la **solicitud completa, incluidos su body y sus efectos secundarios** — un `POST`/escritura espejado alcanza el camino de código real de `v2` y realizaría una escritura real en base de datos, aunque la *respuesta* se descarte. El peligro es el estado duplicado o corrupto, no una respuesta visible. Istio agrega `-shadow` al header `Host`/`Authority` de la solicitud espejada (por ejemplo `helloworld-shadow`), así que un backend consciente del mirroring puede detectarlo y cortocircuitar las escrituras (o rutear a un datastore descartable/shadow). Nunca espejes hacia una versión que muta estado compartido a menos que sea shadow-safe.
2. No hay doble conteo del tráfico *servido*. El `weight: 100` gobierna el tráfico que reciben los usuarios reales (todo a `v1`). `mirrorPercentage` es una **copia independiente** de un porcentaje de ese tráfico servido, enviada fire-and-forget al destino de mirror; esas respuestas se descartan y nunca se cuentan para los weights de la ruta. Sí genera carga real adicional sobre `v2` (100% de las solicitudes acá), lo cual es una consideración de capacidad, pero no es parte de la contabilidad de ruteo del 100%.
3. Con `mirrorPercentage.value: 10.0`, **el 10% de las solicitudes en vivo se duplican hacia `v2`** como tráfico shadow; el otro 90% no se espeja. **El 100% de los usuarios sigue siendo servido por `v1`** — bajar el porcentaje de mirror solo reduce la carga shadow sobre `v2`, nunca lo que ven los usuarios reales.

</details>