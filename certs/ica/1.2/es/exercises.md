# Ejercicios guiados — Tema 1.2: Installing Istio in Sidecar or Ambient Mode

> **Certificación:** Istio Certified Associate (ICA)
> **Peso en el examen:** 5
> **Prerrequisitos del lab:** un cluster de Kubernetes ≥ 1.28 con acceso `cluster-admin`, `kubectl` configurado (`kubectl config current-context`), y salida a Internet para descargar el release. Cualquier distro sirve (kind, minikube, k3s, EKS, GKE). Para **ambient mode** el CNI del cluster debe permitir el chaining del `istio-cni` node agent (kind, GKE, EKS con VPC-CNI y la mayoría de los CNI estándar lo soportan).

Todos los comandos asumen la versión `1.24.x` como línea base, porque es el release donde **ambient GA** quedó estabilizado. Si descargaste otra versión, sustituí el número en las rutas. Las salidas mostradas son las esperadas; si diferís, no avances: diagnosticá primero.

---

## Ejercicio 1 — Descarga, precheck e instalación en Sidecar mode con `istioctl`

El binario `istioctl` es el instalador de referencia: renderiza un `IstioOperator` a manifiestos y los aplica con server-side apply, validando el resultado. No confundir con el antiguo *Istio Operator* (controlador in-cluster), **deprecado desde 1.23**.

**Pasos:**

1. Descargá el release y ponelo en el `PATH` de tu shell:

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -
   cd istio-1.24.0
   export PATH=$PWD/bin:$PATH
   istioctl version --remote=false
   ```

   Salida esperada (aún sin control plane instalado):

   ```
   client version: 1.24.0
   ```

2. Corré el **precheck**. Verifica versión de Kubernetes, permisos RBAC, CRDs en conflicto y webhooks previos. Es *read-only* y seguro de repetir:

   ```bash
   istioctl x precheck
   ```

   ```
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

3. Instalá con el profile `demo` (habilita ingress + egress gateway y telemetría verbosa; ideal para aprender, **no** para producción). El flag `-y` (`--skip-confirmation`) evita el prompt interactivo:

   ```bash
   istioctl install --set profile=demo -y
   ```

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ Egress gateways installed 🛫
   ✔ Ingress gateways installed 🛬
   ✔ Installation complete
   Made this installation the default for cluster-wide operations.
   ```

4. Verificá que el control plane esté sano y que lo aplicado coincida con lo renderizado:

   ```bash
   kubectl get pods -n istio-system
   istioctl verify-install
   ```

   ```
   NAME                                    READY   STATUS    RESTARTS   AGE
   istio-egressgateway-7f8b...             1/1     Running   0          70s
   istio-ingressgateway-6c5...             1/1     Running   0          70s
   istiod-59d8b...                         1/1     Running   0          85s
   ```

5. Listá los profiles disponibles y dumpeá el `default` para entender qué componentes activa cada uno:

   ```bash
   istioctl profile list
   istioctl profile dump default | head -40
   ```

**Preguntas de comprensión — Bloque 1:**

1. `istioctl x precheck` no cambia nada en el cluster. ¿Qué tres clases de problema detecta que harían fallar o degradar un `install`?
2. ¿Por qué el profile `demo` es explícitamente desaconsejado para producción, y qué profile usarías como base en su lugar?
3. Instalaste con `--set profile=demo`. Si mañana corrés `istioctl install --set profile=default -y`, ¿qué pasa con el egress gateway que había creado `demo`? ¿Es aditivo o declarativo?
4. ¿Qué diferencia hay entre `istioctl verify-install` e `istioctl x precheck`, y cuándo corre cada uno en el ciclo de vida?

---

## Ejercicio 2 — Habilitar sidecar injection y validar el data plane

En sidecar mode, cada pod de la app recibe un contenedor `istio-proxy` (Envoy) inyectado por el `sidecar-injector` mutating webhook de `istiod`. La inyección se dispara por **etiqueta de namespace**.

**Pasos:**

1. Etiquetá el namespace `default` para inyección automática y verificalo:

   ```bash
   kubectl label namespace default istio-injection=enabled
   kubectl get namespace -L istio-injection
   ```

   ```
   NAME      STATUS   AGE   ISTIO-INJECTION
   default   Active   3d    enabled
   ```

2. Desplegá una app de muestra (viene en el release) y observá los contenedores por pod:

   ```bash
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   kubectl get pods
   ```

   ```
   NAME                             READY   STATUS    RESTARTS   AGE
   details-v1-7f8c...               2/2     Running   0          40s
   productpage-v1-6b6...            2/2     Running   0          40s
   ratings-v1-559...                2/2     Running   0          40s
   reviews-v1-847...                2/2     Running   0          40s
   ```

   Fijate en el `2/2`: contenedor de app + `istio-proxy`. Sin inyección sería `1/1`.

3. Confirmá que el sidecar está presente y que su config está sincronizada con `istiod`:

   ```bash
   kubectl get pod -l app=productpage -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   istioctl proxy-status
   ```

   ```
   productpage istio-proxy
   ```

   ```
   NAME                          CLUSTER      CDS        LDS        EDS        RDS          ISTIOD
   productpage-v1-6b6...         Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       istiod-59d8b...
   reviews-v1-847...             Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       istiod-59d8b...
   ```

   Todo `SYNCED` significa que Envoy recibió y aceptó la última config vía xDS. Un `STALE` indica que istiod pusheó pero el proxy no confirmó; un `NOT SENT` indica que no hay config para ese recurso.

4. Excluí un pod puntual de la inyección aun con el namespace etiquetado, usando la anotación a nivel de pod template:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: legacy-batch
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: legacy-batch
     template:
       metadata:
         labels:
           app: legacy-batch
         annotations:
           sidecar.istio.io/inject: "false"
       spec:
         containers:
           - name: worker
             image: busybox:1.36
             command: ["sh", "-c", "sleep 3600"]
   ```

   ```bash
   kubectl apply -f legacy-batch.yaml
   kubectl get pod -l app=legacy-batch
   ```

   ```
   NAME                     READY   STATUS    RESTARTS   AGE
   legacy-batch-58f...      1/1     Running   0          15s
   ```

   El `1/1` confirma que la anotación del pod **gana** sobre la etiqueta del namespace.

**Preguntas de comprensión — Bloque 2:**

1. La etiqueta `istio-injection=enabled` está en el namespace, pero la anotación `sidecar.istio.io/inject: "false"` está en el pod template. ¿Cuál tiene precedencia y por qué el diseño es así?
2. Un compañero desplegó su app **antes** de etiquetar el namespace. La etiqueta ya está puesta pero sus pods siguen en `1/1`. ¿Qué comando de una línea fuerza la inyección sin recrear el YAML a mano?
3. En `istioctl proxy-status`, ¿qué significa exactamente la columna `EDS` y qué inferirías si mostrara `STALE` solo en `EDS` mientras el resto está `SYNCED`?
4. La inyección la hace un *mutating admission webhook*. Si borrás por error el objeto `MutatingWebhookConfiguration istio-sidecar-injector`, ¿qué pasa con los pods que ya corren y con los nuevos?

---

## Ejercicio 3 — Instalación en Ambient mode (sidecar-less)

Ambient reemplaza el sidecar por dos capas: **ztunnel** (proxy L4 por nodo, DaemonSet, mTLS y política L4) y **waypoint proxies** (Envoy L7 opcionales, por namespace o por service account). El `istio-cni` node agent redirige el tráfico del pod a ztunnel sin modificar el pod. Los pods se quedan en `1/1` — ésa es la diferencia observable con sidecar.

**Pasos:**

1. Instalá el profile `ambient`. Instala core, istiod, `istio-cni` y `ztunnel`:

   ```bash
   istioctl install --set profile=ambient --skip-confirmation
   ```

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ CNI installed 🪢
   ✔ Ztunnel installed 🔒
   ✔ Installation complete
   ```

2. Verificá los componentes de node. `ztunnel` e `istio-cni` son **DaemonSets** (un pod por nodo); istiod es Deployment:

   ```bash
   kubectl get daemonset -n istio-system
   kubectl get pods -n istio-system -o wide
   ```

   ```
   NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
   istio-cni-node   3     3         3       3            3           60s
   ztunnel          3     3         3       3            3           55s
   ```

3. Inscribí el namespace `default` en ambient con la etiqueta de dataplane (distinta de la de sidecar):

   ```bash
   kubectl label namespace default istio.io/dataplane-mode=ambient
   kubectl get ns default -L istio.io/dataplane-mode
   ```

   ```
   NAME      STATUS   AGE   DATAPLANE-MODE
   default   Active   3d    ambient
   ```

4. Desplegá una app y confirmá que **no** hay sidecar (`1/1`) pero el tráfico ya está en la malla:

   ```bash
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   kubectl get pods
   istioctl ztunnel-config workloads
   ```

   ```
   NAME                             READY   STATUS    RESTARTS   AGE
   productpage-v1-6b6...            1/1     Running   0          30s
   reviews-v1-847...                1/1     Running   0          30s
   ```

   ```
   NAMESPACE   POD NAME              ADDRESS      NODE          WAYPOINT   PROTOCOL
   default     productpage-v1-6b6…   10.244.1.14  worker-1      None       HBONE
   default     reviews-v1-847…       10.244.2.9   worker-2      None       HBONE
   ```

   `PROTOCOL HBONE` confirma que ztunnel está transportando el tráfico sobre HBONE (HTTP/2 CONNECT + mTLS). `WAYPOINT None` indica que aún no hay procesamiento L7.

5. Agregá procesamiento L7 desplegando un **waypoint proxy** para el namespace (necesario para políticas L7: routing por header, authz por método HTTP, etc.):

   ```bash
   istioctl waypoint apply -n default --enroll-namespace
   kubectl get pods -n default -l gateway.networking.k8s.io/gateway-name=waypoint
   istioctl ztunnel-config workloads --workload-namespace default
   ```

   ```
   ✅ waypoint default/waypoint applied
   ✅ namespace default enrolled to use the waypoint default/waypoint
   ```

   Ahora la columna `WAYPOINT` de los workloads apunta al proxy `default/waypoint`.

**Preguntas de comprensión — Bloque 3:**

1. En sidecar mode los pods de la app quedan `2/2`; en ambient quedan `1/1`. Si el pod no cambió, ¿quién y cómo captura su tráfico hacia ztunnel?
2. Nombrá las dos capas de proxy de ambient y decí qué capa del modelo OSI cubre cada una. ¿Cuál es **obligatoria** y cuál es **opt-in**?
3. La etiqueta de sidecar es `istio-injection=enabled` y la de ambient es `istio.io/dataplane-mode=ambient`. ¿Qué pasa si ponés **las dos** en el mismo namespace?
4. Un workload aparece con `PROTOCOL HBONE` y `WAYPOINT None`. Un teammate pide bloquear las peticiones `HTTP DELETE` a ese service con una `AuthorizationPolicy`. ¿Funcionará tal cual está? ¿Qué falta?
5. ztunnel es un DaemonSet. ¿Qué implicancia operativa tiene esto para el *blast radius* comparado con un sidecar que muere junto a su pod?

---

## Ejercicio 4 — Instalación con Helm, `IstioOperator` custom y revisiones (canary upgrade)

Helm es el método soportado para GitOps/CI. Además, las **revisions** permiten correr dos control planes en paralelo y migrar namespaces uno por uno — la forma segura de actualizar en producción.

**Pasos:**

1. Instalá el control plane sidecar con Helm en tres charts (`base` → CRDs y cluster roles, `istiod` → control plane, gateway aparte). Nótese el `--wait` para bloquear hasta readiness:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   kubectl create namespace istio-system

   helm install istio-base istio/base -n istio-system --set defaultRevision=default
   helm install istiod istio/istiod -n istio-system --wait
   helm ls -n istio-system
   ```

   ```
   NAME        NAMESPACE     REVISION  STATUS    CHART         APP VERSION
   istio-base  istio-system  1         deployed  base-1.24.0   1.24.0
   istiod      istio-system  1         deployed  istiod-1.24.0 1.24.0
   ```

   Para **ambient** con Helm son dos charts extra:

   ```bash
   helm install istio-cni istio/cni -n istio-system --set profile=ambient --wait
   helm install ztunnel istio/ztunnel -n istio-system --wait
   ```

2. Para instalaciones con `istioctl` que necesitan tuneo, usá un archivo `IstioOperator` declarativo en vez de decenas de `--set`. Este manifiesto sube réplicas de istiod, activa access logs y fija recursos:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
   spec:
     profile: default
     meshConfig:
       accessLogFile: /dev/stdout
       defaultConfig:
         holdApplicationUntilProxyStarts: true
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
       ingressGateways:
         - name: istio-ingressgateway
           enabled: true
           k8s:
             service:
               type: LoadBalancer
     values:
       global:
         proxy:
           logLevel: warning
   ```

   ```bash
   istioctl install -f control-plane.yaml -y
   ```

3. Instalá un **control plane revisionado** para preparar un canary upgrade (nombre de revision válido como label DNS, p. ej. `1-24-0`):

   ```bash
   istioctl install --set revision=1-24-0 -y
   istioctl tag list
   ```

   ```
   TAG      REVISION   NAMESPACES
   default  1-24-0
   ```

4. Migrá un namespace a la nueva revision cambiando de la etiqueta genérica a la etiqueta `istio.io/rev`, y **reiniciá** los deployments para reinyectar:

   ```bash
   kubectl label namespace default istio-injection- istio.io/rev=1-24-0
   kubectl rollout restart deployment -n default
   istioctl proxy-status
   ```

   La columna `ISTIOD` de `proxy-status` debe pasar a apuntar al pod istiod de la revision `1-24-0`, confirmando que los proxies migraron.

5. Validá la configuración de toda la malla de forma estática, sin tocar tráfico:

   ```bash
   istioctl analyze -A
   ```

   ```
   ✔ No validation issues found when analyzing all namespaces.
   ```

**Preguntas de comprensión — Bloque 4:**

1. El chart `istio/base` se instala primero y por separado de `istiod`. ¿Qué instala `base` que justifica ese orden, y qué rompería si invirtieras el orden?
2. En el paso 4 corriste `kubectl label namespace default istio-injection- istio.io/rev=1-24-0` en un solo comando. ¿Qué hacen el sufijo `-` y el par `clave=valor`, y por qué es importante hacer ambas cosas atómicamente?
3. Después de re-etiquetar el namespace a la nueva revision, ¿por qué los pods existentes **no** se migran solos y hace falta `kubectl rollout restart`?
4. `holdApplicationUntilProxyStarts: true` en el `meshConfig`. ¿Qué race condition de arranque resuelve, y a qué contenedor afecta el orden?
5. ¿Por qué un canary upgrade con revisions es más seguro que un `istioctl upgrade` in-place, en términos de rollback?

---

<details>
<summary><strong>Respuestas — desplegá para verificar</strong></summary>

### Bloque 1

1. `istioctl x precheck` detecta, entre otras cosas: **(a)** versión de Kubernetes fuera del rango soportado por ese release de Istio; **(b)** permisos RBAC insuficientes del usuario para crear CRDs, ClusterRoles y webhooks; **(c)** instalaciones o CRDs previos en conflicto (otra versión de Istio, CRDs huérfanos, webhooks que interceptarían la creación de pods). Al ser read-only, es seguro correrlo tantas veces como quieras antes de instalar o actualizar.
2. El profile `demo` habilita **todos** los componentes con telemetría muy verbosa y sin límites de recursos ajustados: egress gateway, access logs completos, tracing al 100%. Eso consume CPU/memoria y ruido de logs que no querés en producción. La base recomendada es el profile **`default`**, que instala solo istiod + ingress gateway con settings de producción, y sobre él se customiza con un `IstioOperator`.
3. `istioctl install` es **declarativo**: renderiza el estado deseado del profile indicado y hace prune de lo que ya no está en él. Al pasar a `default`, el egress gateway que `demo` había creado **se elimina**, porque `default` no lo declara. No es aditivo; el último `install` define el estado completo del control plane.
4. `x precheck` corre **antes** de instalar/actualizar y valida el *entorno* (cluster listo para recibir Istio). `verify-install` corre **después** y compara lo aplicado en el cluster contra los manifiestos que Istio esperaba generar, confirmando que todos los objetos existen y están sanos.

### Bloque 2

1. **La anotación del pod gana.** El orden de precedencia es: anotación en el pod template > etiqueta del namespace. Está diseñado así para que el default sea a nivel namespace (política amplia) pero permita excepciones granulares (un job legacy, un pod que necesita networking crudo) sin desactivar la inyección para todo el namespace.
2. `kubectl rollout restart deployment -n <ns>` (o sobre el deployment puntual). El webhook solo inyecta en la **creación** del pod; reiniciar el deployment recrea los pods y dispara la inyección. No hace falta editar el YAML.
3. `EDS` = *Endpoint Discovery Service*: la lista de endpoints (IPs de pods) detrás de cada cluster/upstream. `STALE` solo en `EDS` con el resto `SYNCED` sugiere que istiod pusheó un cambio de endpoints (p. ej. pods que escalaron o cambiaron de IP) que ese proxy todavía no confirmó — típicamente un problema transitorio de conectividad xDS o de carga en ese Envoy, no un problema de routing/listeners (que serían `RDS`/`LDS`).
4. Los pods **que ya corren no se ven afectados**: su sidecar ya fue inyectado en el pasado y sigue funcionando. Pero los **pods nuevos dejan de recibir sidecar** (quedan `1/1`), porque ya no hay webhook que mute su spec en el admission. La malla se “congela” en su estado actual hasta restaurar el `MutatingWebhookConfiguration`.

### Bloque 3

1. El **`istio-cni` node agent** programa reglas de redirección (iptables/eBPF según el modo) en el network namespace del pod cuando éste arranca, de forma que su tráfico entrante y saliente se enruta al **ztunnel** del nodo. El pod *no se modifica* (sin contenedor extra, por eso `1/1`); la captura es a nivel de nodo/CNI.
2. **ztunnel** = capa **L4** (transporte): mTLS, identidad y política L4, obligatoria en ambient. **Waypoint proxy** = capa **L7** (aplicación): routing HTTP, authz por método/header/path, retries, es **opt-in** por namespace o por service account. Sin waypoint tenés seguridad L4 y cero procesamiento L7.
3. Es un conflicto y debe evitarse. Un namespace no puede estar en sidecar y ambient a la vez; Istio prioriza y advierte. Un pod inyectado con sidecar dentro de un namespace ambient produce doble captura de tráfico y comportamiento indefinido. La regla operativa: un namespace es sidecar **o** ambient, nunca ambos.
4. **No funcionará tal cual.** `WAYPOINT None` significa que ese tráfico solo pasa por ztunnel (L4). `HTTP DELETE` es un atributo **L7**, y ztunnel no inspecciona L7. Falta desplegar e inscribir un **waypoint proxy** (`istioctl waypoint apply --enroll-namespace`); recién entonces la `AuthorizationPolicy` basada en método HTTP se aplica.
5. Un sidecar comparte ciclo de vida con su pod: si muere, afecta solo a ese workload. ztunnel es un **DaemonSet por nodo**, así que su caída afecta a **todos** los pods ambient de ese nodo — mayor blast radius por nodo. A cambio, ambient reduce drásticamente el overhead agregado (un proxy por nodo en lugar de uno por pod) y desacopla los upgrades del data plane del reinicio de las apps.

### Bloque 4

1. `istio/base` instala los **CRDs** (`VirtualService`, `Gateway`, `AuthorizationPolicy`, etc.), los ClusterRoles/Bindings y la configuración de validación. `istiod` depende de que esos CRDs existan para poder arrancar y reconciliar. Si invirtieras el orden, istiod fallaría al no encontrar los tipos que necesita watchear/crear.
2. El sufijo `-` en `istio-injection-` **elimina** la etiqueta `istio-injection`, y `istio.io/rev=1-24-0` **agrega** la etiqueta de revision. Hacerlo atómico (un solo comando) evita una ventana en la que el namespace tenga ambas etiquetas o ninguna, lo que causaría inyección ambigua o pods sin sidecar durante la transición.
3. La revision de un pod se fija en el momento de la **inyección**, que ocurre solo al crear el pod. Cambiar la etiqueta del namespace no re-muta pods ya existentes; hay que recrearlos con `kubectl rollout restart` para que el webhook los inyecte contra el istiod de la nueva revision.
4. Resuelve la race donde el **contenedor de la app arranca y emite tráfico antes de que el sidecar Envoy esté listo**, lo que provoca conexiones fallidas al inicio. Con `holdApplicationUntilProxyStarts: true`, el arranque del contenedor de la app **se retiene** hasta que el `istio-proxy` reporta readiness, garantizando que haya data plane desde la primera petición.
5. Con revisions corrés el control plane nuevo **en paralelo** al viejo y migrás namespaces de a uno. Si algo falla, el **rollback es re-etiquetar el namespace a la revision anterior** y reiniciar — ambos control planes siguen vivos. Un `upgrade` in-place reemplaza el control plane existente: un fallo afecta a toda la malla a la vez y el rollback implica reinstalar la versión anterior, con mayor riesgo y downtime.

</details>

---

**Fuentes oficiales:**

- Install with `istioctl` — https://istio.io/latest/docs/setup/install/istioctl/
- Install with Helm — https://istio.io/latest/docs/setup/install/helm/
- Installation configuration profiles — https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Sidecar injection — https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Ambient mode — get started & install — https://istio.io/latest/docs/ambient/getting-started/ y https://istio.io/latest/docs/ambient/install/istioctl/
- Waypoint proxies — https://istio.io/latest/docs/ambient/usage/waypoint/
- Canary upgrades (revisions & tags) — https://istio.io/latest/docs/setup/upgrade/canary/
- `IstioOperator` API reference — https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/