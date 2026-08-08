# Ejercicios guiados — Tema 1.3: Customizing your Istio Installation

**Certificación:** Istio Certified Associate (ICA) · Dominio 1 — *Installing, Upgrading & Configuring Istio* · Peso: 5%

Estos ejercicios asumen un cluster de Kubernetes funcional (`kind`, `minikube`, k3s o similar) con `kubectl` y el binario `istioctl` en el `PATH`, versión coincidente con la de tu cluster. Verificá tu versión con `istioctl version --remote=false` antes de empezar.

> **Nota de arquitectura.** La API `IstioOperator` sigue siendo el *esquema de configuración* que consume `istioctl install` y `istioctl manifest generate`, aun cuando el **controlador operator in-cluster** (`istio-operator`) está deprecado desde 1.23 y removido en 1.24. En estos ejercicios usamos `IstioOperator` **como archivo de configuración de `istioctl`**, nunca como CR aplicado a un controlador. La otra vía soportada y recomendada para GitOps/producción es Helm; la cubrimos en el Ejercicio 5.

Fuentes de referencia:
- Customizing the configuration — https://istio.io/latest/docs/setup/additional-setup/customize-installation/
- Configuration profiles — https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- `IstioOperator` API — https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- `MeshConfig` (`istio.mesh.v1alpha1`) — https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Install with Helm — https://istio.io/latest/docs/setup/install/helm/
- Customization with Helm — https://istio.io/latest/docs/setup/additional-setup/customize-installation-helm/
- ICA Curriculum — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

---

## Ejercicio 1 — Profiles: inspeccionar, comparar y generar sin instalar

El objetivo es entender que un *profile* es solo un conjunto de valores por defecto de `IstioOperator`, y que podés inspeccionar y diferenciar profiles **sin tocar el cluster**.

1. Listá los profiles disponibles en tu versión de `istioctl`:

   ```bash
   istioctl profile list
   ```

   Salida esperada (varía según versión):

   ```
   Istio configuration profiles:
       ambient
       default
       demo
       empty
       external
       minimal
       openshift
       openshift-ambient
       preview
       remote
       stable
   ```

2. Volcá la configuración *completa* que aplicaría el profile `demo`, en formato `IstioOperator`:

   ```bash
   istioctl profile dump demo
   ```

3. Volcá solo una rama del árbol de configuración usando `--config-path`. Mirá qué componentes activa el profile `default`:

   ```bash
   istioctl profile dump --config-path components default
   ```

   Salida esperada (recortada):

   ```yaml
   base:
     enabled: true
   cni:
     enabled: false
   egressGateways:
   - enabled: false
     name: istio-egressgateway
   ingressGateways:
   - enabled: true
     name: istio-ingressgateway
   pilot:
     enabled: true
   ```

4. Compará `default` contra `demo` para ver exactamente qué agrega el profile de demostración:

   ```bash
   istioctl profile diff default demo
   ```

   Salida esperada (recortada — las líneas `+` son lo que suma `demo`):

   ```diff
    components:
      egressGateways:
   -  - enabled: false
   +  - enabled: true
        name: istio-egressgateway
    ...
      meshConfig:
   +   accessLogFile: /dev/stdout
   +   enableTracing: true
    ...
      values:
        pilot:
   -     autoscaleEnabled: true
   +     autoscaleEnabled: false
   ```

5. Generá el manifiesto de Kubernetes que produciría el profile `minimal`, **sin instalar nada**, y contá los recursos:

   ```bash
   istioctl manifest generate --set profile=minimal > /tmp/minimal.yaml
   grep -c '^kind:' /tmp/minimal.yaml
   ```

**Preguntas de comprensión**

- P1.1 — ¿Qué diferencia hay entre `istioctl profile dump` y `istioctl manifest generate`? ¿Cuál produce recursos aplicables a `kubectl`?
- P1.2 — Nombrá tres diferencias concretas que `profile diff default demo` reveló y por qué el profile `demo` **no** debe usarse en producción.
- P1.3 — El profile `empty` existe. ¿Para qué sirve un profile que no despliega nada, y con qué campo lo compondrías?
- P1.4 — ¿Por qué generar el manifiesto con `manifest generate` y aplicarlo con `kubectl apply` es distinto (y más riesgoso en actualizaciones) que usar `istioctl install`?

---

## Ejercicio 2 — Instalación personalizada con un archivo `IstioOperator`

Acá construís una instalación real partiendo de un profile y sobreponiendo `meshConfig`, activación de componentes y valores de Helm.

1. Creá el archivo `iop-custom.yaml`:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     meshConfig:
       accessLogFile: /dev/stdout
       accessLogEncoding: JSON
       outboundTrafficPolicy:
         mode: REGISTRY_ONLY
       defaultConfig:
         holdApplicationUntilProxyStarts: true
     components:
       egressGateways:
         - name: istio-egressgateway
           enabled: true
       ingressGateways:
         - name: istio-ingressgateway
           enabled: true
     values:
       global:
         proxy:
           logLevel: warning
       pilot:
         autoscaleEnabled: false
   ```

2. Validá la sintaxis y hacé un *dry-run* que muestra qué cambiaría, sin aplicar:

   ```bash
   istioctl install -f iop-custom.yaml --dry-run
   ```

3. Instalá de verdad (respondé `y` a la confirmación, o agregá `-y`):

   ```bash
   istioctl install -f iop-custom.yaml -y
   ```

   Salida esperada:

   ```
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Egress gateways installed
   ✔ Ingress gateways installed
   ✔ Installation complete
   ```

4. Verificá que la instalación coincide con el manifiesto declarado:

   ```bash
   istioctl verify-install -f iop-custom.yaml
   ```

5. Confirmá que el `meshConfig` que pediste realmente quedó en el ConfigMap del plano de control:

   ```bash
   kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' | grep -E 'outboundTrafficPolicy|accessLog' -A1
   ```

   Salida esperada (recortada):

   ```yaml
   accessLogEncoding: JSON
   accessLogFile: /dev/stdout
   outboundTrafficPolicy:
     mode: REGISTRY_ONLY
   ```

6. Confirmá el efecto de `REGISTRY_ONLY`: desplegá un pod con sidecar e intentá salir a Internet.

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl run sleep --image=curlimages/curl -- sleep 3600
   kubectl exec sleep -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" https://istio.io
   ```

   Salida esperada:

   ```
   000
   command terminated with exit code 35
   ```

   (El tráfico saliente hacia un host no registrado en el mesh es bloqueado por el sidecar.)

**Preguntas de comprensión**

- P2.1 — En el manifiesto conviven `spec.meshConfig`, `spec.components` y `spec.values`. ¿Qué tipo de configuración va en cada uno y hacia dónde se traduce `spec.values`?
- P2.2 — Cambiaste `outboundTrafficPolicy.mode` a `REGISTRY_ONLY`. ¿Cuál es el default de Istio y qué implica en seguridad cada modo? ¿Qué recurso Istio necesitarías para *permitir* `istio.io` bajo `REGISTRY_ONLY`?
- P2.3 — ¿Qué hace `holdApplicationUntilProxyStarts: true` y qué clase de bug de arranque previene?
- P2.4 — Si ejecutás `istioctl install -f iop-custom.yaml -y` una segunda vez sin cambios, ¿qué pasa? ¿Es idempotente?
- P2.5 — ¿Qué chequea exactamente `istioctl verify-install` que un simple `kubectl get pods -n istio-system` no chequea?

---

## Ejercicio 3 — Overlays de Kubernetes: recursos, HPA, service y patches JSON

El bloque `k8s` dentro de cada componente permite modificar los objetos de Kubernetes generados (Deployment, Service, HPA, PodDisruptionBudget, etc.) sin editar templates.

1. Ampliá `iop-custom.yaml`, agregando bajo `spec.components`:

   ```yaml
     components:
       pilot:
         k8s:
           resources:
             requests:
               cpu: 500m
               memory: 2048Mi
           hpaSpec:
             minReplicas: 2
             maxReplicas: 5
           env:
             - name: PILOT_TRACE_SAMPLING
               value: "10"
       ingressGateways:
         - name: istio-ingressgateway
           enabled: true
           k8s:
             service:
               type: NodePort
               ports:
                 - name: http2
                   port: 80
                   targetPort: 8080
                   nodePort: 30080
                 - name: https
                   port: 443
                   targetPort: 8443
                   nodePort: 30443
             resources:
               requests:
                 cpu: 100m
                 memory: 128Mi
             overlays:
               - kind: Deployment
                 name: istio-ingressgateway
                 patches:
                   - path: spec.template.spec.containers.[name:istio-proxy].lifecycle
                     value:
                       preStop:
                         exec:
                           command: ["sleep", "5"]
   ```

2. Previsualizá el efecto de los overlays en el YAML generado, sin instalar:

   ```bash
   istioctl manifest generate -f iop-custom.yaml | \
     grep -E 'nodePort|minReplicas|maxReplicas|PILOT_TRACE_SAMPLING' -A0
   ```

3. Aplicá la nueva configuración:

   ```bash
   istioctl install -f iop-custom.yaml -y
   ```

4. Verificá cada override en el cluster:

   ```bash
   kubectl -n istio-system get hpa istiod
   kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.type}{"\n"}'
   kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PILOT_TRACE_SAMPLING")].value}{"\n"}'
   kubectl -n istio-system get deploy istio-ingressgateway \
     -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command}{"\n"}'
   ```

   Salidas esperadas:

   ```
   NAME     REFERENCE           TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
   istiod   Deployment/istiod   .../80%   2         5         2          1m

   NodePort
   10
   ["sleep","5"]
   ```

5. Aplicá el mismo tipo de override **desde la CLI** con `--set`, sin editar el archivo, para subir la CPU de istiod:

   ```bash
   istioctl install -f iop-custom.yaml \
     --set components.pilot.k8s.resources.requests.cpu=1000m -y
   ```

**Preguntas de comprensión**

- P3.1 — ¿Cuál es la diferencia entre los campos *tipados* de `k8s` (`resources`, `hpaSpec`, `service`, `env`) y el bloque `overlays` con `patches`? ¿Cuándo estás obligado a usar `overlays`?
- P3.2 — Definiste `hpaSpec.minReplicas: 2` pero también hay `values.pilot.autoscaleEnabled`. ¿Qué pasa si `autoscaleEnabled: false` y también declarás `hpaSpec`? ¿Quién gana?
- P3.3 — En la sintaxis del `path` del overlay aparece `containers.[name:istio-proxy]`. ¿Qué selecciona esa notación y por qué no se usa un índice numérico `[0]`?
- P3.4 — Agregaste un `preStop: sleep 5` al ingress gateway. ¿Qué problema de *graceful shutdown* / *connection draining* resuelve esto durante un rollout?
- P3.5 — Un `--set` de CLI y un valor del archivo `-f` entran en conflicto sobre el mismo campo. ¿Cuál tiene precedencia?

---

## Ejercicio 4 — Ajuste fino de `MeshConfig`: tracing, logging y sidecar por defecto

`MeshConfig` es la configuración *global del data plane*: aplica a todos los proxies. Acá la ajustás y verificás su propagación.

1. Editá `spec.meshConfig` para habilitar sampling de tracing bajo y una política de concurrencia del proxy:

   ```yaml
     meshConfig:
       accessLogFile: /dev/stdout
       enableTracing: true
       defaultConfig:
         tracing:
           sampling: 1.0
         concurrency: 2
       extensionProviders:
         - name: otel
           opentelemetry:
             service: opentelemetry-collector.observability.svc.cluster.local
             port: 4317
   ```

2. Aplicá y verificá que llegó al ConfigMap `istio`:

   ```bash
   istioctl install -f iop-custom.yaml -y
   kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' | grep -E 'sampling|concurrency|enableTracing'
   ```

3. Confirmá que un proxy de aplicación **recibió** esa configuración inspeccionando su bootstrap:

   ```bash
   kubectl rollout restart deploy sleep 2>/dev/null; kubectl -n default get pod
   istioctl proxy-config bootstrap deploy/sleep -o json | \
     grep -iE 'concurrency|sampling' | head
   ```

4. Compará: aplicá un `MeshConfig` **por CLI** para una sola opción y observá que reescribe solo esa clave:

   ```bash
   istioctl install -f iop-custom.yaml --set meshConfig.accessLogFile="" -y
   kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' | grep -i accessLog || echo "access log deshabilitado"
   ```

**Preguntas de comprensión**

- P4.1 — ¿Cuál es la diferencia entre `meshConfig.<campo>` y `meshConfig.defaultConfig.<campo>`? Dado `concurrency` y `outboundTrafficPolicy`, ¿en cuál va cada uno y por qué?
- P4.2 — Cambiaste `meshConfig` con `istioctl install`. ¿Los pods de aplicación ya en ejecución adoptan el nuevo `MeshConfig` automáticamente, o hace falta algo? ¿Y para `defaultConfig` (config del proxy) específicamente?
- P4.3 — `sampling: 1.0` en producción con alto tráfico es una mala idea. ¿Por qué, y qué valor típico usarías?
- P4.4 — ¿Qué es un `extensionProvider` en `meshConfig` y cómo se relaciona con los recursos `Telemetry`? ¿Definirlo acá activa el tracing por sí solo?

---

## Ejercicio 5 — Personalización equivalente con Helm

Helm es la vía recomendada para GitOps/producción. Reproducís las personalizaciones anteriores con `values`.

1. Agregá el repo y creá el namespace:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   kubectl create namespace istio-system
   ```

2. Instalá el chart `base` (CRDs) y luego `istiod` con overrides equivalentes a los ejercicios previos:

   ```bash
   helm install istio-base istio/base -n istio-system --set defaultRevision=default

   helm install istiod istio/istiod -n istio-system --wait \
     --set meshConfig.accessLogFile=/dev/stdout \
     --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
     --set pilot.autoscaleEnabled=true \
     --set pilot.autoscaleMin=2 \
     --set pilot.autoscaleMax=5 \
     --set pilot.resources.requests.cpu=500m \
     --set pilot.resources.requests.memory=2048Mi
   ```

3. Instalá el ingress gateway como release aparte (en Helm, cada gateway es su propio chart/release):

   ```bash
   kubectl create namespace istio-ingress
   helm install istio-ingressgateway istio/gateway -n istio-ingress \
     --set service.type=NodePort
   ```

4. Verificá los valores efectivos de un release y compará con lo instalado:

   ```bash
   helm get values istiod -n istio-system
   kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' | grep -i outboundTrafficPolicy -A1
   ```

5. Aplicá un cambio de configuración con `helm upgrade` (por ejemplo, apagar el access log):

   ```bash
   helm upgrade istiod istio/istiod -n istio-system --reuse-values \
     --set meshConfig.accessLogFile=""
   ```

**Preguntas de comprensión**

- P5.1 — En Helm, ¿cuántos charts/releases distintos componen una instalación con control plane + ingress gateway, y por qué está partido así?
- P5.2 — Mapeá estos overrides de `IstioOperator` a su clave de `values` de Helm: `values.pilot.autoscaleEnabled`, `components.ingressGateways[0].k8s.service.type`, `meshConfig.accessLogFile`.
- P5.3 — En el `helm upgrade` usaste `--reuse-values`. ¿Qué pasa si lo omitís? ¿Y qué hace `--reset-values`?
- P5.4 — ¿Por qué Helm es preferible a `manifest generate | kubectl apply` para el ciclo de vida (upgrades, pruning de recursos huérfanos)?

---

## Ejercicio 6 — Personalización segura: instalaciones basadas en revisions (canary)

Cambiar la configuración del control plane *in-place* reinicia istiod para toda la malla. Las *revisions* permiten instalar una configuración personalizada en paralelo y migrar workloads gradualmente.

1. Instalá una segunda configuración de control plane con una revision nombrada, con una personalización distinta:

   ```bash
   istioctl install -f iop-custom.yaml --revision=canary-1-24 \
     --set meshConfig.defaultConfig.holdApplicationUntilProxyStarts=false -y
   ```

2. Verificá que conviven ambos control planes:

   ```bash
   kubectl -n istio-system get pods -l app=istiod -L istio.io/rev
   istioctl tag list
   ```

   Salida esperada (recortada):

   ```
   NAME                              READY   STATUS    ISTIO.IO/REV
   istiod-7d9c...                    1/1     Running   default
   istiod-canary-1-24-6b8f...        1/1     Running   canary-1-24
   ```

3. Migrá un namespace de la revision `default` a la nueva, y reiniciá sus workloads:

   ```bash
   kubectl label namespace default istio-injection- istio.io/rev=canary-1-24 --overwrite
   kubectl rollout restart deploy sleep
   ```

4. Confirmá qué control plane está gestionando el pod:

   ```bash
   istioctl proxy-status | grep sleep
   kubectl -n default get pod -l run=sleep -o jsonpath='{.items[0].spec.containers[*].image}{"\n"}'
   ```

**Preguntas de comprensión**

- P6.1 — ¿Por qué un cambio de `meshConfig` aplicado con `istioctl install` sin revision es potencialmente disruptivo para toda la malla, y cómo lo mitiga una instalación por revision?
- P6.2 — Un namespace tiene simultáneamente `istio-injection=enabled` e `istio.io/rev=canary-1-24`. ¿Cuál gana? (Por eso el paso 3 quita el primero.)
- P6.3 — ¿Qué es un `istioctl tag` (por ejemplo el tag `default`) y cómo permite promover una revision canary a estable **sin re-etiquetar todos los namespaces**?
- P6.4 — Después de validar la canary, ¿cuáles son los pasos para desinstalar la revision `default` vieja sin dejar la malla sin control plane?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **P1.1** — `profile dump` emite un objeto **`IstioOperator`** (la *configuración* de entrada, con profile ya resuelto); no es aplicable a Kubernetes. `manifest generate` **renderiza** esa configuración a los objetos concretos de Kubernetes (Deployments, Services, CRDs, ConfigMaps…), y *ese* output sí es aplicable con `kubectl apply`. En resumen: `dump` = qué quiero; `generate` = qué recursos se crearán.
- **P1.2** — `demo` agrega, entre otras cosas: habilita el **egress gateway** (`enabled: true`), activa **`accessLogFile: /dev/stdout`** y **`enableTracing: true`**, y **desactiva el autoscaling de pilot** (`autoscaleEnabled: false`). No es apto para producción porque prioriza visibilidad/facilidad sobre performance y costo: logging y tracing agresivos, sin HPA en istiod, y componentes extra corriendo sin necesidad. Está pensado para aprender/demostrar features, no para carga real.
- **P1.3** — `empty` no despliega ningún componente; sirve como **base limpia** sobre la cual componés exactamente lo que necesitás activando componentes uno por uno. Se compone activando componentes vía `spec.components.<x>.enabled: true` (o `--set`), típico para instalaciones a medida o para desplegar solo gateways.
- **P1.4** — `istioctl install` **reconcilia**: conoce el estado anterior, actualiza y **elimina (prunes)** los recursos que ya no forman parte de la config. `manifest generate | kubectl apply` solo aplica lo que está en el YAML: en un upgrade que renombra o elimina objetos, deja **recursos huérfanos** (webhooks, deployments viejos) que pueden romper la malla. Por eso `manifest generate` se recomienda solo para pipelines GitOps que gestionen el pruning explícitamente.

**Ejercicio 2**

- **P2.1** — `spec.meshConfig` → configuración **runtime del data plane** (comportamiento de los proxies: logging, tracing, tráfico saliente). `spec.components` → **topología y objetos Kubernetes** de cada componente Istio (activar/desactivar, réplicas, recursos, service). `spec.values` → **passthrough directo a los charts de Helm** subyacentes (los mismos valores que usarías en `helm install`); es la vía de escape para opciones que no tienen campo tipado en la API.
- **P2.2** — El default es **`ALLOW_ANY`**: cualquier destino externo desconocido se deja pasar (cómodo, pero permite exfiltración y oculta dependencias). **`REGISTRY_ONLY`** bloquea todo lo que no esté en el registro del mesh, forzando declarar dependencias explícitas — postura *default-deny*, mucho más segura. Para permitir `istio.io` bajo `REGISTRY_ONLY` creás un **`ServiceEntry`** (típicamente con `resolution: DNS` y el host/puertos).
- **P2.3** — `holdApplicationUntilProxyStarts: true` hace que el contenedor de aplicación **espere a que el sidecar Envoy esté listo** antes de arrancar. Previene el bug de arranque en el que la app hace llamadas salientes mientras el proxy todavía no tiene rutas/config, resultando en fallos de conexión al inicio del pod.
- **P2.4** — Es **idempotente**: reconcilia contra el estado actual; si no hay diferencias, no cambia nada (reporta que ya está instalado / sin cambios). Repetir el comando es seguro.
- **P2.5** — `verify-install` compara los recursos **realmente presentes** en el cluster contra los que el manifiesto **espera**, y valida que estén *disponibles/ready* (CRDs, webhooks, deployments), reportando faltantes o incompletos. `kubectl get pods` solo te dice el estado de los pods, no si el set de recursos coincide con la config declarada.

**Ejercicio 3**

- **P3.1** — Los campos tipados (`resources`, `hpaSpec`, `service`, `env`, `nodeSelector`, `podAnnotations`, `replicaCount`, `strategy`, `tolerations`, `serviceAnnotations`) cubren las modificaciones comunes con validación de esquema. El bloque `overlays`/`patches` es un mecanismo genérico de **parcheo por path** para modificar *cualquier* campo del objeto generado que no tenga campo tipado (p. ej. `lifecycle`, `securityContext` anidados, un `volume` custom). Usás `overlays` cuando el campo no está expuesto de forma tipada.
- **P3.2** — Con `autoscaleEnabled: false` **no se crea el HPA**, por lo que el `hpaSpec` queda inerte (no hay objeto que parchear); istiod corre con `replicaCount` fijo. El HPA solo se genera si el autoscaling está habilitado; en ese caso `hpaSpec` define sus límites. No es que "gane" uno: `autoscaleEnabled` es el interruptor que decide si el HPA existe.
- **P3.3** — `containers.[name:istio-proxy]` selecciona el elemento de la lista `containers` **cuyo campo `name` es `istio-proxy`** (selección por atributo, no por posición). Se evita el índice `[0]` porque el orden de los contenedores no está garantizado entre versiones; seleccionar por `name` hace el patch estable y determinístico.
- **P3.4** — Un `preStop: sleep 5` da al gateway una ventana de **connection draining**: durante un rollout/terminación, Kubernetes lo saca de los Endpoints y el `sleep` retrasa el `SIGTERM` a Envoy, dejando que las conexiones en curso terminen y que los clientes/kube-proxy dejen de enrutar hacia el pod. Evita errores 503/conexiones cortadas durante el shutdown.
- **P3.5** — **El `--set` de CLI tiene precedencia** sobre los valores del archivo `-f`. La jerarquía de menor a mayor es: profile por defecto → archivo(s) `-f` → flags `--set`.

**Ejercicio 4**

- **P4.1** — `meshConfig.<campo>` = configuración **global del mesh** que consume istiod/el control plane (p. ej. `outboundTrafficPolicy`, `accessLogFile`, `extensionProviders`). `meshConfig.defaultConfig.<campo>` = valores por defecto del **`ProxyConfig`** que se inyectan a cada sidecar (p. ej. `concurrency`, `tracing.sampling`, `holdApplicationUntilProxyStarts`). Entonces `concurrency` va en `defaultConfig` (es del proxy) y `outboundTrafficPolicy` va en `meshConfig` (es de la malla).
- **P4.2** — `MeshConfig` "global" (lo que lee istiod) se actualiza en caliente vía el ConfigMap y se propaga por xDS **sin reiniciar** los pods. Pero los valores de **`defaultConfig`/`ProxyConfig`** se materializan en el **bootstrap** del sidecar al momento de la inyección; los pods existentes conservan su bootstrap y necesitan un **`kubectl rollout restart`** para adoptar los cambios.
- **P4.3** — `sampling: 1.0` traza el **100% de los requests**: con alto tráfico genera un volumen enorme de spans, sobrecarga el backend de tracing y agrega overhead/costo. Un valor típico es **1% (`sampling: 1.0` significa 1%… ojo)** — corrección: en `meshConfig.defaultConfig.tracing.sampling` el valor es un **porcentaje** (0–100), así que `1.0` = 1%, y `100` = 100%. En producción se usa un porcentaje bajo (p. ej. `1`), subiéndolo puntualmente para diagnóstico.
- **P4.4** — Un `extensionProvider` **declara y nombra** un backend de telemetría (OpenTelemetry, Zipkin, Prometheus, Envoy access log, etc.) que luego los recursos **`Telemetry`** referencian por nombre para activar tracing/metrics/logging por scope. Definirlo en `meshConfig` **no** activa tracing por sí solo: solo registra el provider; hace falta un `Telemetry` (o `enableTracing` + sampling) que lo use.

**Ejercicio 5**

- **P5.1** — Como mínimo **tres** releases: `base` (CRDs y recursos cluster-wide), `istiod` (control plane) y **un release `gateway` por cada** ingress/egress gateway. Está partido así para poder versionar y ciclar cada pieza de forma independiente (p. ej. actualizar un gateway sin tocar istiod) y para soportar revisions/canary limpiamente.
- **P5.2** — `values.pilot.autoscaleEnabled` → `pilot.autoscaleEnabled` (idéntico, porque `spec.values` ya *es* passthrough de Helm). `components.ingressGateways[0].k8s.service.type` → en el chart `gateway`: `service.type`. `meshConfig.accessLogFile` → `meshConfig.accessLogFile` (el chart `istiod` expone `meshConfig` directamente).
- **P5.3** — Sin `--reuse-values`, `helm upgrade` **descarta los overrides previos** que no vuelvas a pasar y vuelve a los defaults del chart (más lo que pases en ese upgrade), lo que puede revertir configuración sin querer. `--reuse-values` conserva los valores del release anterior y aplica encima los nuevos `--set`. `--reset-values` hace lo opuesto: descarta todo override previo y parte de los defaults del chart.
- **P5.4** — Helm mantiene el **release como unidad con estado**: en `upgrade` reconcilia, versiona (`helm history`), permite `rollback` y **elimina recursos que ya no están en el chart**. `manifest generate | kubectl apply` no rastrea estado, así que deja huérfanos y no ofrece rollback atómico.

**Ejercicio 6**

- **P6.1** — Un cambio de `meshConfig` in-place actualiza el único istiod y (según el campo) puede requerir reinyección/reinicio de sidecars en **toda** la malla a la vez — radio de impacto máximo. Con una instalación por **revision** desplegás la nueva config en un istiod paralelo y migrás **namespace por namespace**, pudiendo validar y hacer rollback moviendo el label de vuelta, sin tocar los workloads que siguen en la revision estable.
- **P6.2** — Gana **`istio.io/rev`**: cuando el label de revision está presente, tiene precedencia sobre `istio-injection=enabled`. Por higiene igual se quita `istio-injection` (paso 3) para evitar ambigüedad y confusión operativa.
- **P6.3** — Un `istioctl tag` es un **alias estable** (implementado como un `MutatingWebhookConfiguration`) que apunta a una revision concreta. El tag `default` es lo que usan los namespaces con `istio-injection=enabled`. Repuntando el tag a otra revision (`istioctl tag set default --revision canary-1-24`) promovés la canary a estable **sin re-etiquetar cada namespace**: solo re-inyectan al reiniciarse.
- **P6.4** — Tras validar: (1) migrar todos los namespaces restantes a la nueva revision (o repuntar el tag), (2) reiniciar sus workloads para que tomen el nuevo sidecar, (3) confirmar con `istioctl proxy-status` que ningún proxy sigue apuntando a la revision vieja, y (4) recién entonces `istioctl uninstall --revision=default -y`. Nunca desinstalar la vieja antes de que quede sin workloads, o quedarían proxies sin control plane.

</details>