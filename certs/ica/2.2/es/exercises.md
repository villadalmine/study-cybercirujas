# Ejercicios guiados — Tema 2.2: Troubleshooting the Mesh Control Plane

> El control plane de Istio es un único binario, `istiod`, que agrupa Pilot (distribución de configuración vía xDS), Citadel (CA e identidades SPIFFE) y Galley (validación de configuración). Cuando "algo no funciona en la malla", el 80% de las veces el problema no está en el proxy sino en que `istiod` **no pudo calcular, distribuir o firmar** lo que el proxy necesita. Estos ejercicios entrenan el flujo de diagnóstico canónico: **salud de istiod → sincronización xDS → propagación de configuración → inyección del sidecar → identidad/certificados → métricas de push**.
>
> Requisitos: un cluster con Istio ≥ 1.18 instalado (`istioctl install` o Helm), `kubectl`, `istioctl` en el `PATH`, y la app de ejemplo `bookinfo` desplegada en un namespace con inyección. Si no la tenés: `kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml`.

---

## Ejercicio 1 — Establecer la línea de base: ¿está sano el control plane?

Antes de diagnosticar un síntoma hay que descartar que istiod esté degradado. El orden importa: primero el proceso, después la sincronización.

1. Confirmá que el pod de istiod está `Running` y `Ready`, y mirá su antigüedad y reinicios:

   ```bash
   kubectl get pods -n istio-system -l app=istiod -o wide
   ```

   Salida esperada (sano):

   ```
   NAME                      READY   STATUS    RESTARTS   AGE   IP            NODE
   istiod-7c8f9d5b6-4mkzt    1/1     Running   0          9d    10.244.1.7    node-1
   ```

2. Comprobá la versión del cliente, del control plane y del data plane en una sola vista. Es el chequeo más rápido de "¿istiod es alcanzable?":

   ```bash
   istioctl version
   ```

   Salida esperada:

   ```
   client version: 1.20.1
   control plane version: 1.20.1
   data plane version: 1.20.1 (6 proxies)
   ```

3. Revisá que los probes de readiness/liveness de istiod estén apuntando al endpoint correcto (`:8080/ready`) y que no haya throttling:

   ```bash
   kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | jq .
   kubectl -n istio-system describe pod -l app=istiod | grep -A3 -iE 'readiness|liveness|OOM|Events'
   ```

4. Mirá los últimos logs de istiod buscando errores de arranque, de conexión al API server o de pushes:

   ```bash
   kubectl logs -n istio-system deploy/istiod --tail=50 | grep -iE 'error|warn|push|fail'
   ```

**Preguntas de comprensión (bloque 1):**

- a) En el paso 2, `istioctl version` devuelve `control plane version: unable to retrieve` pero los pods del paso 1 están `1/1 Running`. ¿Qué componente descartaste ya y qué dos causas probables quedan?
- b) ¿Por qué el número entre paréntesis en `data plane version: 1.20.1 (6 proxies)` es una señal diagnóstica y no solo informativa?
- c) Un `RESTARTS` alto en istiod junto a eventos `OOMKilled` no es "un bug del control plane". ¿Qué relación tiene con el tamaño de la malla?

---

## Ejercicio 2 — Leer `proxy-status`: SYNCED, STALE, NOT SENT

`istioctl proxy-status` (alias `istioctl ps`) es la herramienta central del tema. Compara, por cada proxy, el estado **conocido por istiod** contra el **último `nonce` reconocido por el proxy**, para cada tipo de recurso xDS: CDS (clusters), LDS (listeners), EDS (endpoints), RDS (routes), ECDS (extension config).

1. Obtené el estado de sincronización de todos los proxies:

   ```bash
   istioctl proxy-status
   ```

   Salida esperada (todo sano):

   ```
   NAME                                     CLUSTER      CDS        LDS        EDS        RDS        ECDS       ISTIOD                    VERSION
   productpage-v1-7bd5f...default           Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-7c8f9d5b6-4mkzt    1.20.1
   reviews-v3-5c5cf...default               Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT   istiod-7c8f9d5b6-4mkzt    1.20.1
   ```

2. Provocá una condición de configuración no aceptada. Aplicá un `VirtualService` que referencia un `host` inexistente y volvé a mirar el estado:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: networking.istio.io/v1beta1
   kind: VirtualService
   metadata:
     name: reviews-broken
     namespace: default
   spec:
     hosts:
       - reviews
     http:
       - route:
           - destination:
               host: reviews
               subset: v99   # subset inexistente
   EOF
   istioctl proxy-status
   ```

3. Interpretá el estado de un proxy puntual y compará contra lo que istiod cree que le mandó:

   ```bash
   istioctl proxy-status productpage-v1-7bd5f...default
   ```

4. Limpiá la configuración rota antes de seguir:

   ```bash
   kubectl delete virtualservice reviews-broken -n default
   ```

**Preguntas de comprensión (bloque 2):**

- a) Definí con precisión la diferencia entre `STALE` y `NOT SENT`. ¿Cuál de los dos indica un problema y cuál puede ser normal?
- b) En el paso 1, la columna `ECDS` muestra `NOT SENT` para todos los proxies y sin embargo la malla funciona. ¿Por qué eso es esperable?
- c) `STALE` persistente en la columna `EDS` de un solo proxy (los demás `SYNCED`). ¿El problema es del control plane o de ese proxy en particular? Justificá.

---

## Ejercicio 3 — `istioctl analyze`: detección estática de misconfiguración

`istioctl analyze` corre un conjunto de *analyzers* contra la configuración viva (o contra archivos), sin tocar los proxies. Encuentra clases enteras de errores que `proxy-status` no muestra porque nunca llegan a generar config válida.

1. Analizá un namespace completo:

   ```bash
   istioctl analyze -n default
   ```

   Ejemplo de salida con hallazgos:

   ```
   Warning [IST0101] (VirtualService reviews-broken.default) Referenced host+subset in destinationrule not found: "reviews+v99"
   Info [IST0102] (Namespace default) The namespace is not enabled for Istio injection...
   Error: Analyzers found issues when analyzing namespace: default.
   ```

2. Analizá toda la malla y elevá los `Info`/`Warning` a fallo (útil en CI):

   ```bash
   istioctl analyze --all-namespaces
   istioctl analyze -n default --failure-threshold Info
   ```

3. Validá un manifiesto **antes** de aplicarlo, combinando el estado del cluster con el archivo local:

   ```bash
   istioctl analyze -n default my-virtualservice.yaml
   ```

4. Verificá el código de salida, que es lo que un pipeline observa:

   ```bash
   istioctl analyze -n default; echo "exit=$?"
   ```

**Preguntas de comprensión (bloque 3):**

- a) `proxy-status` mostraba todo `SYNCED` pero `analyze` reporta `IST0101`. ¿Cómo pueden coexistir esos dos resultados sobre la misma malla?
- b) ¿Qué agrega pasar un archivo `.yaml` como argumento a `analyze` frente a hacer un `kubectl apply --dry-run=server`?
- c) ¿Por qué `--failure-threshold Info` es peligroso como gate por defecto en un cluster maduro?

---

## Ejercicio 4 — Debug endpoints internos de istiod (syncz, registryz, endpointz)

Cuando `proxy-status` dice `STALE` y no sabés si el problema es de cálculo (istiod) o de recepción (proxy), hay que ir a los endpoints de debug de istiod. La forma soportada y multi-réplica es `istioctl x internal-debug`, que consulta a **todas** las instancias de istiod.

1. Consultá el estado de sincronización directamente desde istiod (fuente de verdad del lado control plane):

   ```bash
   istioctl experimental internal-debug syncz
   ```

2. Verificá que istiod tiene el service registry correcto: ¿ve el `Service` y sus puertos como esperás?

   ```bash
   istioctl experimental internal-debug registryz | jq '.[] | select(.hostname | test("reviews"))'
   ```

3. Confirmá que istiod resolvió endpoints (Pod IPs) para ese servicio. Un `EDS` vacío acá explica un `503 UH`/`no healthy upstream` en el data plane:

   ```bash
   istioctl experimental internal-debug endpointz | jq '.[] | select(.svc | test("reviews"))'
   ```

4. Si necesitás acceder a un endpoint puntual no expuesto por `istioctl`, hacé port-forward al puerto de debug (`8080`) de una réplica concreta:

   ```bash
   kubectl -n istio-system port-forward deploy/istiod 8080:8080 &
   curl -s localhost:8080/debug/adsz | jq '.[].node' | head
   curl -s localhost:8080/debug/configz | jq 'length'
   ```

**Preguntas de comprensión (bloque 4):**

- a) ¿Por qué `istioctl x internal-debug` es preferible a un `curl` directo a `localhost:8080` cuando istiod corre con más de una réplica (HPA)?
- b) `registryz` muestra el servicio `reviews` pero `endpointz` no devuelve ninguna IP para él. ¿Dónde está el problema y dónde **no** está?
- c) Ordená estos tres, del control plane hacia el proxy, según la cadena causal de una config: `syncz`, `configz`, `registryz`. ¿Qué representa cada uno?

---

## Ejercicio 5 — Troubleshooting de la inyección del sidecar

Un Pod sin sidecar no está en la malla y `proxy-status` ni lo lista. La inyección la hace un `MutatingWebhookConfiguration` que llama a istiod; casi todas las fallas de inyección son de webhook o de labels, no de la app.

1. Verificá el mecanismo de inyección del namespace (label clásico vs. revisiones):

   ```bash
   kubectl get namespace default --show-labels
   # Espera: istio-injection=enabled   O BIEN   istio.io/rev=<revision>
   ```

2. Inspeccioná el webhook y confirmá que su `caBundle` no está vacío y que el `namespaceSelector`/`objectSelector` coinciden:

   ```bash
   kubectl get mutatingwebhookconfiguration -l app=sidecar-injector
   kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
     -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
   kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
     -o jsonpath='{.webhooks[0].namespaceSelector}'
   ```

3. Reproducí la inyección **sin desplegar**, para ver si el webhook produce el sidecar:

   ```bash
   kubectl create deployment injtest --image=nginx --dry-run=client -o yaml \
     | istioctl kube-inject -f - \
     | grep -c 'istio-proxy'   # >0 significa que la plantilla de inyección funciona
   ```

4. Si un Pod ya corriendo no tiene sidecar, mirá el conteo de containers y forzá una nueva creación tras corregir el label:

   ```bash
   kubectl get pod <pod> -n default -o jsonpath='{.spec.containers[*].name}'
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl rollout restart deployment <deploy> -n default   # la inyección ocurre solo al crear el Pod
   ```

**Preguntas de comprensión (bloque 5):**

- a) El namespace tiene `istio-injection=enabled` **y** además `istio.io/rev=canary`. ¿Qué pasa con la inyección y por qué?
- b) El `caBundle` del webhook mide 0 bytes. Explicá por qué eso rompe la inyección y qué componente debería repoblarlo.
- c) Aplicaste el label correcto pero el Pod existente sigue sin sidecar. ¿Es un bug? ¿Cuál es la acción correcta?

---

## Ejercicio 6 — Identidad y certificados emitidos por istiod (CA)

istiod actúa como CA: firma los certificados X.509/SPIFFE que cada sidecar usa para mTLS. Fallas en la CA se manifiestan como `503`/`connection reset` en mTLS aunque la config de routing esté perfecta.

1. Verificá que istiod está firmando y que los proxies tienen un certificado válido y vigente:

   ```bash
   istioctl proxy-config secret productpage-v1-7bd5f...default
   ```

   Salida esperada:

   ```
   RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
   default           Cert Chain     ACTIVE     true           2f3a...              2026-08-09T...           2026-08-08T...
   ROOTCA            CA             ACTIVE     true           1a2b...              2036-08-06T...           2026-08-08T...
   ```

2. Confirmá la identidad SPIFFE del workload dentro del certificado (debe corresponder al `ServiceAccount`):

   ```bash
   istioctl proxy-config secret productpage-v1-7bd5f...default -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
   # Espera: URI:spiffe://cluster.local/ns/default/sa/bookinfo-productpage
   ```

3. Diagnosticá errores de emisión desde los logs de istiod (CA) y desde el `istio-agent` del pod:

   ```bash
   kubectl logs -n istio-system deploy/istiod | grep -iE 'CSR|citadel|failed to sign|CA'
   kubectl logs <pod> -n default -c istio-proxy | grep -iE 'CSR|SDS|certificate|failed to warm'
   ```

4. Chequeá el estado global de mTLS entre dos workloads concretos:

   ```bash
   istioctl x describe pod productpage-v1-7bd5f...default
   ```

**Preguntas de comprensión (bloque 6):**

- a) En el paso 1, `VALID CERT` es `false` y `NOT AFTER` está en el pasado. ¿Qué falló y por qué el reinicio del **proxy** no siempre lo arregla?
- b) La SAN del certificado dice `sa/default` pero esperabas `sa/bookinfo-productpage`. ¿Qué configuración del Deployment provocó esto y por qué rompe las `AuthorizationPolicy` basadas en `principals`?
- c) Los logs del `istio-agent` muestran `failed to warm certificate: rpc error ... connection refused` hacia `istiod:15012`. ¿En cuál de los ejercicios anteriores empezarías a diagnosticar y por qué?

---

## Ejercicio 7 — Métricas del control plane: presión de push y convergencia

Un control plane "sano" puede estar al límite. Las métricas de Pilot en el puerto `15014` revelan si istiod distribuye config a tiempo o si está saturado, lo que se traduce en `STALE` intermitentes.

1. Exponé y muestreá las métricas de istiod:

   ```bash
   kubectl -n istio-system port-forward deploy/istiod 15014:15014 &
   curl -s localhost:15014/metrics | grep -E '^pilot_(xds_pushes|xds_push_time|proxy_convergence_time|xds_push_context_errors|conflict_)' 
   ```

2. Identificá errores de construcción de config y pushes rechazados:

   ```bash
   curl -s localhost:15014/metrics | grep -E 'pilot_total_xds_rejects|pilot_xds_push_context_errors|pilot_xds_write_timeout'
   ```

3. Contá conexiones xDS activas y comparalas con la cantidad de proxies que esperás:

   ```bash
   curl -s localhost:15014/metrics | grep -E 'pilot_xds\{|pilot_xds '
   ```

4. Correlacioná un pico de `pilot_proxy_convergence_time` con los `STALE` del Ejercicio 2 y con el uso de recursos de istiod:

   ```bash
   kubectl top pod -n istio-system -l app=istiod
   ```

**Preguntas de comprensión (bloque 7):**

- a) `pilot_xds_pushes` crece de forma sostenida sin que nadie aplique manifiestos nuevos. ¿Qué clase de evento del cluster puede estar generando pushes y por qué es un problema de escala?
- b) `pilot_proxy_convergence_time` en el p99 sube a varios segundos. ¿Cómo se relaciona con lo que un usuario ve como `STALE` en `proxy-status`?
- c) `pilot_total_xds_rejects` es distinto de cero. ¿El proxy está rechazando config de istiod o al revés? ¿Qué comando del Ejercicio 2/3 usarías para encontrar el recurso culpable?

---

## Respuestas

<details>
<summary>Ver respuestas de comprensión</summary>

### Bloque 1 — Salud del control plane

- **a)** Ya descartaste que el **proceso** de istiod esté caído (los pods están `1/1 Running`). Quedan dos causas: (1) el **cliente** `istioctl` no puede alcanzar el endpoint de debug de istiod — RBAC insuficiente para leer pods/`istiod`, `kubeconfig` apuntando a otro contexto, o network policy que bloquea el port-forward implícito; (2) `istiod` está `Running` pero **no `Ready`** internamente (arrancó pero falla su readiness), o hay un **desajuste de revisión** y `istioctl` busca una revisión que no existe (`istioctl version --revision <rev>`). La distinción es clave: "pod arriba" ≠ "control plane sirviendo".
- **b)** Porque te dice cuántos proxies están **conectados y reportando versión a istiod**. Si esperás 6 proxies y ves `(2 proxies)`, cuatro sidecars no están hablando con el control plane (crash, mTLS a `:15012` roto, o nunca se inyectaron) — un problema invisible en un `kubectl get pods` que muestra los Pods `Running`.
- **c)** istiod mantiene en memoria el modelo completo de la malla (servicios, endpoints, config) y recalcula config en cada cambio. Cuanto más grande la malla (más Pods, Services, EndpointSlices y CRs), más memoria consume. `OOMKilled` recurrente casi siempre significa **istiod sub-dimensionado para la escala actual**, no un defecto — la solución es subir `resources.limits` o escalar/segmentar con `Sidecar` resources para reducir el ámbito de config por proxy.

### Bloque 2 — proxy-status

- **a)** `STALE` = istiod **calculó y envió** una actualización, pero el proxy **no ha reconocido** (ACK) el `nonce` correspondiente dentro del tiempo esperado → hay un problema de propagación/recepción y **es siempre sospechoso**. `NOT SENT` = istiod **nunca tuvo nada que enviar** de ese tipo de recurso para ese proxy → normalmente **benigno**. La diferencia es "enviado-pero-no-confirmado" vs. "nunca-hubo-nada-que-enviar".
- **b)** `ECDS` (Extension Config Discovery Service) sólo se usa cuando hay `WasmPlugin`/`EnvoyFilter` que definen extensiones distribuidas por ECDS. En una malla sin esas extensiones no hay configuración ECDS que enviar, así que `NOT SENT` es el estado correcto y esperado.
- **c)** Es del **proxy en particular** (o de la ruta istiod→ese proxy). Si istiod estuviera roto para EDS, **todos** los proxies mostrarían `STALE` en EDS. Que sólo uno lo haga apunta a ese sidecar: se quedó sin conexión xDS, está saturado, o perdió el stream a `:15012`. Se confirma mirando los logs del `istio-proxy` de ese Pod y `syncz` (Ejercicio 4).

### Bloque 3 — analyze

- **a)** `proxy-status` compara *nonces* de la config que **efectivamente se distribuyó**; si istiod descartó el recurso inválido (o produjo config parcial válida), todos los proxies pueden estar `SYNCED` respecto de lo que se les mandó. `analyze` es **estático y semántico**: detecta que un `VirtualService` referencia un `subset` que no existe en ningún `DestinationRule`, aunque eso nunca haya generado un push. Miden cosas distintas: distribución vs. corrección semántica.
- **b)** `--dry-run=server` sólo valida contra el esquema del CRD y los webhooks de validación (sintaxis y campos). `analyze` corre analyzers **cross-resource**: detecta referencias colgantes entre `VirtualService`↔`DestinationRule`↔`Gateway`↔`ServiceEntry`, conflictos de `host`, `Gateway` sin `VirtualService`, mTLS incoherente, etc. — relaciones que el dry-run no evalúa.
- **c)** Porque eleva a **fallo** hallazgos meramente informativos (por ejemplo "el namespace no tiene inyección"), muchos de los cuales son intencionales en un cluster maduro. Un gate con `Info` produce falsos positivos masivos y termina siendo ignorado. Lo razonable es `Warning` (o `Error`) como umbral por defecto.

### Bloque 4 — debug endpoints

- **a)** Con HPA hay varias réplicas de istiod y **cada proxy está conectado a una sola** de ellas; su estado de sync sólo lo conoce esa réplica. Un `curl` directo llega a **una** instancia (la que resuelva el Service) y te da una foto parcial. `istioctl x internal-debug` **hace fan-out a todas** las réplicas y agrega el resultado, evitando conclusiones falsas del tipo "este proxy no aparece en syncz" cuando en realidad está en otra réplica.
- **b)** El problema está en la **resolución de endpoints** (EDS), no en el descubrimiento del servicio. `registryz` con el servicio presente prueba que istiod ve el `Service`; `endpointz` vacío significa que no encontró Pods listos detrás de él: selector del `Service` que no matchea labels de los Pods, Pods no `Ready`/failing readiness, o `EndpointSlice` vacío. **No** es un problema de routing ni de istiod-como-tal.
- **c)** De istiod hacia el proxy: **`registryz`** (qué servicios/instancias descubrió istiod del cluster — la entrada) → **`configz`** (la config Istio que istiod tiene y con la que construye la salida xDS) → **`syncz`** (el estado de distribución/ACK de esa config hacia cada proxy — la salida). Es la cadena "descubrimiento → cálculo → distribución".

### Bloque 5 — inyección

- **a)** Tener ambos labels es ambiguo pero **`istio-injection=enabled` (el label legacy) tiene prioridad y apunta al webhook por defecto**, no a la revisión `canary`. El resultado es que los Pods se inyectan con el control plane **default**, no con `canary` como pretendías — un error clásico en upgrades canary. La regla: usá **uno u otro**, nunca los dos.
- **b)** El `caBundle` es el certificado con el que el **API server verifica TLS** al llamar al webhook de istiod. Si está vacío, el API server no puede establecer confianza y **falla la llamada de admisión**; según `failurePolicy`, o bien el Pod se crea **sin** sidecar (`Ignore`) o bien **se rechaza la creación** (`Fail`). Quien debe repoblarlo es istiod (patchea el `MutatingWebhookConfiguration` con su CA); si no lo hace, revisá RBAC de istiod y sus logs.
- **c)** **No es un bug.** La inyección ocurre **sólo en el momento de creación del Pod** (admission webhook), no retroactivamente. Un Pod que ya existía cuando aplicaste el label nunca pasó por el webhook. La acción correcta es forzar la recreación: `kubectl rollout restart` del Deployment (o borrar el Pod para que el controller lo recree).

### Bloque 6 — certificados / CA

- **a)** El certificado del workload **expiró** y no se renovó. El `istio-agent` normalmente rota los certs vía SDS mucho antes del vencimiento; que haya expirado indica que la **renovación falló** — típicamente porque el agent no puede alcanzar la CA de istiod en `:15012` (red, mTLS del canal de CSR, o istiod caído). Reiniciar el **proxy** no ayuda si la causa raíz es que **istiod no está firmando**: hay que arreglar la CA/conectividad primero (ver la relación con el bloque 7c).
- **b)** El Deployment no especificó `serviceAccountName`, así que corre con el `ServiceAccount` **`default`** del namespace, y la identidad SPIFFE se deriva del SA (`spiffe://.../ns/default/sa/default`). Cualquier `AuthorizationPolicy` cuyo `principals` sea `.../sa/bookinfo-productpage` **no matchea** esa identidad → el tráfico se deniega (o se permite algo que no debía). La identidad de la malla la define el `ServiceAccount`, no el nombre del Deployment.
- **c)** Empezaría en el **Ejercicio 1** (salud de istiod) y en el **Ejercicio 7** (conectividad/errores de CA). `connection refused` hacia `istiod:15012` significa que el canal de descubrimiento y CA no está disponible: istiod caído/no-Ready, el `Service istiod` sin endpoints, o una NetworkPolicy bloqueando `15012`. Es un problema de control plane/conectividad, no del proxy que reporta el error.

### Bloque 7 — métricas

- **a)** Cambios de **endpoints** disparan pushes aunque nadie toque config Istio: Pods que escalan, se reinician, cambian de IP, `readiness` que flapea, o churn de nodos. En mallas grandes con muchos EndpointSlices, ese *endpoint churn* genera un flujo constante de pushes EDS que satura istiod. Es un problema de **escala**: se mitiga con `Sidecar` resources (limitar el ámbito de config por workload), debouncing (`PILOT_DEBOUNCE_AFTER`/`_MAX`) y dimensionando istiod.
- **b)** `pilot_proxy_convergence_time` mide cuánto tarda un cambio en propagarse y ser ACKeado por los proxies. Un p99 de varios segundos significa que, durante ese intervalo, los proxies tienen config **vieja** — que es exactamente lo que `proxy-status` reporta como `STALE`. Alta convergencia ⇒ `STALE` frecuentes/persistentes.
- **c)** Es el **proxy (Envoy) rechazando (NACK) config que istiod le envió** — config sintácticamente/semánticamente inaceptable para Envoy (un `EnvoyFilter` mal formado es la causa clásica). Para encontrar el recurso culpable: `istioctl proxy-status` (verás el proxy que no sincroniza), los logs de ese `istio-proxy` con el motivo del NACK, e `istioctl analyze` para detectar el manifiesto ofensor de forma estática.

</details>

---

### Fuentes oficiales

- Diagnóstico con `proxy-status`/`proxy-config`: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- `istioctl analyze`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Problemas comunes de inyección del sidecar: https://istio.io/latest/docs/ops/common-problems/injection/
- Arquitectura del control plane (istiod): https://istio.io/latest/docs/ops/deployment/architecture/
- ControlZ e introspección de istiod: https://istio.io/latest/docs/ops/diagnostic-tools/controlz/
- Depuración de Envoy y xDS: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/#deep-dive-into-envoy-configuration
- Gestión de certificados / istiod como CA: https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
- Referencia de configuración del webhook de inyección: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Referencia de `istioctl`: https://istio.io/latest/docs/reference/commands/istioctl/
- Curriculum ICA (CNCF): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf