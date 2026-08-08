# Ejercicios guiados — Tema 1.1: Installing Istio with istioctl or Helm

> **Certificación:** Istio Certified Associate (ICA) · **Peso en el examen:** 5
> **Prerrequisitos:** un cluster Kubernetes funcional (kind, minikube, k3d o uno real) con al menos 4 vCPU y 8 GB de RAM disponibles, `kubectl` configurado y apuntando al cluster correcto (`kubectl config current-context`), y acceso a Internet para descargar los artefactos.
>
> Trabajá en un cluster desechable. Varios pasos instalan y desinstalan el control plane completo.

---

## Ejercicio 1 — Descargar `istioctl` y hacer el precheck del cluster

`istioctl` es el CLI oficial de Istio. Empaqueta los charts, valida el cluster antes de tocarlo y expone comandos de diagnóstico (`proxy-status`, `analyze`, `verify-install`) que vas a usar durante toda la certificación.

### Pasos

1. Descargá la última release y fijá una versión explícita (reproducibilidad > "lo último"):

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.1 TARGET_ARCH=x86_64 sh -
   ```

   Salida esperada (abreviada):

   ```text
   Downloading istio-1.24.1 from https://github.com/istio/istio/releases/download/1.24.1/istio-1.24.1-linux-amd64.tar.gz ...
   Istio 1.24.1 Download Complete!

   Istio has been successfully downloaded into the istio-1.24.1 folder.
   ...
   Add the istioctl to your path with:
     export PATH=$PWD/istio-1.24.1/bin:$PATH
   ```

2. Agregá el binario al `PATH` de la sesión actual y confirmá la versión:

   ```bash
   cd istio-1.24.1
   export PATH=$PWD/bin:$PATH
   istioctl version --remote=false
   ```

   Salida esperada:

   ```text
   client version: 1.24.1
   ```

   > `--remote=false` evita que el CLI intente contactar un control plane que todavía no existe. Sin ese flag, `istioctl version` intenta leer la versión de `istiod` y muestra un warning porque aún no está instalado.

3. Ejecutá el precheck **antes** de instalar. Verifica versión de Kubernetes, permisos RBAC, CRDs en conflicto y webhooks:

   ```bash
   istioctl x precheck
   ```

   Salida esperada en un cluster limpio:

   ```text
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

### Preguntas de comprensión

1. ¿Por qué el pipeline `curl … | sh -` con `ISTIO_VERSION` es preferible en un entorno de producción frente a dejar que el script elija la versión por defecto?
2. ¿Qué clase de problemas detecta `istioctl x precheck` que un `kubectl apply` de los manifiestos crudos **no** detectaría por sí solo?
3. Instalaste el CLI 1.24.1 en tu máquina, pero el cluster ya tiene un `istiod` 1.22 corriendo. ¿Qué te muestra `istioctl version` (sin `--remote=false`) y por qué importa el skew entre client y control plane?

---

## Ejercicio 2 — Entender los configuration profiles sin instalar nada

Istio se instala a partir de un *profile*: un conjunto de valores por defecto que decide qué componentes se despliegan (`istiod`, ingress/egress gateways, addons de telemetría). Renderizar el manifiesto sin aplicarlo es la forma correcta de auditar qué va a entrar al cluster.

### Pasos

1. Listá los profiles disponibles:

   ```bash
   istioctl profile list
   ```

   Salida esperada:

   ```text
   Istio configuration profiles:
       ambient
       default
       demo
       empty
       minimal
       openshift
       openshift-ambient
       preview
       remote
       stable
   ```

2. Mirá qué hace el profile `demo` respecto del `default` **sin aplicar nada** (diff de configuración efectiva):

   ```bash
   istioctl profile diff default demo
   ```

   Fragmento representativo de la salida:

   ```diff
     components:
       egressGateways:
   -     enabled: false
   +     enabled: true
         name: istio-egressgateway
       ingressGateways:
         enabled: true
         name: istio-ingressgateway
     values:
       global:
   -     proxy:
   -       tracer: none
       meshConfig:
   -     accessLogFile: ""
   +     accessLogFile: /dev/stdout
   ```

3. Renderizá el YAML completo que el profile `default` aplicaría, y guardalo para revisión:

   ```bash
   istioctl manifest generate --set profile=default > /tmp/istio-default.yaml
   grep -c 'kind:' /tmp/istio-default.yaml
   ```

   Salida esperada (el número exacto varía por versión, pero debe ser > 0):

   ```text
   58
   ```

### Preguntas de comprensión

1. Nombrá los tres componentes que diferencian al profile `demo` del `default` y explicá por qué `demo` **no** debe usarse en producción.
2. ¿Cuál es la diferencia práctica entre `istioctl manifest generate` e `istioctl install`? ¿En qué flujo de trabajo (GitOps, por ejemplo) preferirías `manifest generate`?
3. El profile `minimal` instala solo `istiod`. ¿Qué capacidad concreta perdés respecto del `default` y cómo la recuperarías más tarde sin reinstalar el control plane?

---

## Ejercicio 3 — Instalar Istio con `istioctl install` y un `IstioOperator`

El flag `--set profile=demo` sirve para demos, pero producción se instala desde un archivo `IstioOperator` declarativo, versionado en Git. Es la fuente de verdad de tu instalación.

### Pasos

1. Escribí el siguiente manifiesto en `istio-control-plane.yaml`. Es sintácticamente completo y válido:

   ```yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: control-plane
     namespace: istio-system
   spec:
     profile: default
     # Etiqueta de revisión: habilita canary upgrades más adelante.
     revision: 1-24-1
     meshConfig:
       # Access logs a stdout para que 'kubectl logs' del sidecar sea útil.
       accessLogFile: /dev/stdout
       # Habilita el endpoint de métricas de Prometheus en los proxies.
       enablePrometheusMerge: true
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
             resources:
               requests:
                 cpu: 100m
                 memory: 128Mi
   ```

2. Validá el archivo antes de aplicarlo. `istioctl analyze` corre sobre la configuración, no sobre el cluster:

   ```bash
   istioctl manifest generate -f istio-control-plane.yaml | kubectl apply --dry-run=client -f - >/dev/null && echo "manifest OK"
   ```

   Salida esperada:

   ```text
   manifest OK
   ```

3. Instalá. El flag `-y` salta la confirmación interactiva:

   ```bash
   istioctl install -f istio-control-plane.yaml -y
   ```

   Salida esperada:

   ```text
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Ingress gateways installed
   ✔ Installation complete
   Made this installation the default for cluster-wide operations.
   ```

4. Verificá que el estado en el cluster coincide con el manifiesto declarado:

   ```bash
   istioctl verify-install -f istio-control-plane.yaml
   ```

   Salida esperada (última línea):

   ```text
   ✔ Istio is installed and verified successfully
   ```

5. Inspeccioná los objetos creados. Notá el sufijo de revisión en `istiod`:

   ```bash
   kubectl get pods -n istio-system
   ```

   Salida esperada:

   ```text
   NAME                                    READY   STATUS    RESTARTS   AGE
   istio-ingressgateway-7d4f8c9b5c-xk2lp   1/1     Running   0          90s
   istiod-1-24-1-6b7c9d8f4-abc12           1/1     Running   0          110s
   ```

### Preguntas de comprensión

1. En el manifiesto, `spec.revision: 1-24-1` cambia el nombre del Deployment de `istiod` a `istiod-1-24-1`. ¿Para qué sirve esa revisión y qué patrón de upgrade habilita?
2. ¿Qué diferencia hay entre `istioctl verify-install` (con `-f`) y `istioctl verify-install` sin argumentos? ¿Cuál usarías en un pipeline de CI que valida una instalación previa?
3. El `IstioOperator` de arriba pone el ingress gateway como `type: LoadBalancer`. En un cluster kind/minikube sin cloud LoadBalancer, ¿en qué estado queda el `Service` y qué dos alternativas tenés para exponer el gateway?

---

## Ejercicio 4 — Inyección de sidecar y validación end-to-end

Instalar el control plane no hace nada por sí solo: el data plane (los sidecars Envoy) se inyecta por namespace. Este ejercicio prueba que la instalación efectivamente intercepta tráfico.

### Pasos

1. Como usaste una revisión con nombre, la etiqueta de inyección debe apuntar a esa revisión, **no** al `istio-injection=enabled` genérico:

   ```bash
   kubectl create namespace demo
   kubectl label namespace demo istio.io/rev=1-24-1
   ```

   > Con `spec.revision` seteado, la etiqueta clásica `istio-injection=enabled` es **ignorada**. Debés usar `istio.io/rev=<revision>`. Este es un error de examen clásico.

2. Desplegá un pod y verificá que arranca con 2 contenedores (app + `istio-proxy`):

   ```bash
   kubectl -n demo run web --image=nginx --restart=Never
   kubectl -n demo get pod web -o jsonpath='{.spec.containers[*].name}{"\n"}'
   ```

   Salida esperada:

   ```text
   web istio-proxy
   ```

3. Confirmá que el proxy está sincronizado con el control plane:

   ```bash
   istioctl proxy-status
   ```

   Salida esperada:

   ```text
   NAME                     CLUSTER      CDS        LDS        EDS        RDS          ECDS         ISTIOD                          VERSION
   web.demo                 Kubernetes   SYNCED     SYNCED     SYNCED     NOT SENT     NOT SENT     istiod-1-24-1-6b7c9d8f4-abc12   1.24.1
   ```

4. Corré el analyzer sobre el namespace para detectar misconfiguraciones:

   ```bash
   istioctl analyze -n demo
   ```

   Salida esperada en un namespace sano:

   ```text
   ✔ No validation issues found when analyzing namespace: demo.
   ```

### Preguntas de comprensión

1. ¿Por qué en este cluster `istio-injection=enabled` **no** inyecta el sidecar, mientras que `istio.io/rev=1-24-1` sí lo hace?
2. En la salida de `istioctl proxy-status`, ¿qué significan las columnas `CDS`, `LDS`, `EDS`, `RDS`? ¿Qué representa el estado `SYNCED` frente a `STALE` o `NOT SENT`?
3. Un pod desplegado en `demo` arranca con un solo contenedor (sin `istio-proxy`). Enumerá tres causas posibles y el comando con el que confirmarías cada una.

---

## Ejercicio 5 — Instalar Istio con Helm (charts `base`, `istiod`, `gateway`)

Helm es el segundo método soportado y el preferido cuando tu tooling ya es Helm/GitOps. Istio publica tres charts que se instalan **en orden**: `base` (CRDs + recursos cluster-wide) → `istiod` (control plane) → `gateway` (data plane de ingress). Este ejercicio asume un cluster **sin** Istio previo.

### Pasos

1. Agregá el repo oficial de charts y actualizá el índice:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   ```

   Salida esperada:

   ```text
   "istio" has been added to your repositories
   ...
   Update Complete. ⎈Happy Helming!⎈
   ```

2. Creá el namespace e instalá el chart `base` (instala CRDs y el `ValidatingWebhookConfiguration`):

   ```bash
   kubectl create namespace istio-system
   helm install istio-base istio/base -n istio-system --set defaultRevision=default --wait
   ```

   Salida esperada (última línea relevante):

   ```text
   STATUS: deployed
   ```

3. Instalá el control plane `istiod`:

   ```bash
   helm install istiod istio/istiod -n istio-system --wait
   ```

4. Verificá que ambos releases están `deployed` y que `istiod` corre:

   ```bash
   helm ls -n istio-system
   kubectl get deploy -n istio-system
   ```

   Salida esperada:

   ```text
   NAME         NAMESPACE     REVISION   STATUS     CHART          APP VERSION
   istio-base   istio-system  1          deployed   base-1.24.1    1.24.1
   istiod       istio-system  1          deployed   istiod-1.24.1  1.24.1

   NAME     READY   UP-TO-DATE   AVAILABLE   AGE
   istiod   1/1     1            1           45s
   ```

5. Instalá un ingress gateway en su propio namespace (buena práctica: aislar el data plane de gateway del control plane):

   ```bash
   kubectl create namespace istio-ingress
   kubectl label namespace istio-ingress istio-injection=enabled
   helm install istio-ingressgateway istio/gateway -n istio-ingress --wait
   ```

6. Confirmá la instalación con el mismo comando de verificación que en el flujo `istioctl`:

   ```bash
   istioctl verify-install
   ```

   Salida esperada (última línea):

   ```text
   ✔ Istio is installed and verified successfully
   ```

### Preguntas de comprensión

1. ¿Por qué el orden `base` → `istiod` → `gateway` es obligatorio y no arbitrario? ¿Qué falla si instalás `istiod` antes que `base`?
2. `helm install istio-base --set defaultRevision=default` setea una revisión por defecto. ¿Qué habilita eso respecto de la inyección de sidecars y del webhook de validación?
3. Comparado con `istioctl install`, ¿qué responsabilidad operativa asume Helm que `istioctl` gestiona por vos? Pensá en el ciclo de vida de los **CRDs** durante un `helm upgrade`.

---

## Ejercicio 6 — Desinstalación limpia (ambos métodos)

Saber desinstalar sin dejar CRDs huérfanos ni webhooks colgados es parte del temario. Un webhook de validación sin `istiod` detrás bloquea la creación de recursos y "rompe" el cluster.

### Pasos

1. **Si instalaste con `istioctl`**, desinstalá el control plane completo, incluyendo CRDs:

   ```bash
   istioctl uninstall --purge -y
   kubectl delete namespace istio-system
   ```

   Salida esperada:

   ```text
   ✔ Uninstall complete
   ```

2. **Si instalaste con Helm**, borrá los releases en **orden inverso** a la instalación:

   ```bash
   helm delete istio-ingressgateway -n istio-ingress
   helm delete istiod -n istio-system
   helm delete istio-base -n istio-system
   ```

3. Helm **no** borra los CRDs de Istio automáticamente (protección contra pérdida de datos). Eliminálos a mano si querés un cluster totalmente limpio:

   ```bash
   kubectl get crd -oname | grep --color=never 'istio.io' | xargs -r kubectl delete
   kubectl delete namespace istio-system istio-ingress
   ```

4. Verificá que no quedó nada:

   ```bash
   kubectl get crd | grep istio.io || echo "sin CRDs de Istio"
   kubectl get validatingwebhookconfiguration | grep istio || echo "sin webhooks de Istio"
   ```

   Salida esperada:

   ```text
   sin CRDs de Istio
   sin webhooks de Istio
   ```

### Preguntas de comprensión

1. ¿Por qué `helm delete` **no** elimina los CRDs, y qué riesgo concreto introduce esa decisión si reinstalás una versión distinta después?
2. ¿Por qué la desinstalación con Helm debe hacerse en orden inverso (`gateway` → `istiod` → `base`)?
3. Un `ValidatingWebhookConfiguration` de Istio quedó en el cluster pero `istiod` ya no existe. Describí el síntoma que verían los usuarios al hacer `kubectl apply` y cómo lo resolverías.

---

## Respuestas

<details>
<summary>Mostrar respuestas de todos los ejercicios</summary>

### Ejercicio 1

1. **Reproducibilidad y control de skew.** Fijar `ISTIO_VERSION` garantiza que cada máquina, pipeline de CI y operador instale exactamente el mismo binario, evitando que "lo último" cambie bajo tus pies entre dos ejecuciones. En producción, la versión del CLI debe estar acoplada a la versión del control plane que vas a operar; dejar que el script elija introduce drift silencioso.
2. `istioctl x precheck` valida cosas que `kubectl apply` ignora por completo: versión de Kubernetes soportada por esa release de Istio, permisos RBAC del usuario que instala, presencia de CRDs o instalaciones de Istio en conflicto, `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` que puedan chocar, y compatibilidad del cluster. `kubectl apply` solo valida schema y aplica; no razona sobre pre-condiciones operativas.
3. Sin `--remote=false`, `istioctl version` reporta **ambas** versiones: `client version: 1.24.1` y `control plane version: 1.22.x`. Importa porque Istio soporta un skew de a lo sumo **una minor version** entre `istioctl`/sidecars y `istiod`; un salto mayor puede producir configuración que el proxy no entiende. La regla operativa: nunca uses un CLI más de una minor por delante del control plane.

### Ejercicio 2

1. El profile `demo` habilita el **egress gateway** (deshabilitado en `default`), activa **access logging** a `/dev/stdout` y sube el nivel de **tracing/telemetría** con sampling alto. No sirve para producción porque prioriza visibilidad sobre performance: el sampling de trazas al 100 % y el logging verboso tienen costo de CPU/almacenamiento inaceptable a escala, y el egress gateway abierto no refleja una postura de seguridad endurecida.
2. `manifest generate` **renderiza** el YAML a stdout sin tocar el cluster (útil para auditar, versionar en Git y aplicar con `kubectl`/Argo CD/Flux). `install` renderiza **y aplica**, además de gestionar el estado y reconciliar. En un flujo GitOps preferís `manifest generate` porque la herramienta de GitOps es la que aplica y mantiene el estado; querés el YAML como artefacto versionado, no un `install` imperativo.
3. `minimal` instala solo `istiod`; perdés los **ingress/egress gateways**. Los recuperás después aplicando un `IstioOperator` con `components.ingressGateways[].enabled: true` (o instalando el chart `gateway` de Helm por separado) sin reinstalar el control plane.

### Ejercicio 3

1. `spec.revision` renombra los recursos del control plane con ese sufijo (`istiod-1-24-1`) y crea webhooks/labels específicos de esa revisión. Habilita los **canary upgrades**: podés correr dos control planes (`1-24-1` y, por ejemplo, `1-25-0`) en paralelo y migrar namespaces uno por uno cambiando su etiqueta `istio.io/rev`, con rollback inmediato si algo falla. Sin revisión, un upgrade es in-place y no reversible fácilmente.
2. Con `-f <archivo>`, `verify-install` compara el **estado del cluster contra el manifiesto declarado** (¿lo que instalé coincide con lo que pedí?). Sin argumentos, verifica que la instalación existente sea internamente consistente y esté `Running`. En CI que valida una instalación previa usás la variante **con `-f`**, porque querés fallar el pipeline si el cluster derivó del manifiesto en Git.
3. Sin un cloud LoadBalancer, el `Service` queda con `EXTERNAL-IP` en `<pending>` indefinidamente. Alternativas: (a) instalar **MetalLB** para proveer IPs de tipo LoadBalancer en bare-metal/local; (b) cambiar el `Service` a `type: NodePort` y acceder por `nodeIP:nodePort`; o, en minikube, correr `minikube tunnel`, y en kind usar `cloud-provider-kind` o un port-forward.

### Ejercicio 4

1. Cuando `spec.revision` está seteado, `istiod` solo atiende al `MutatingWebhookConfiguration` de **esa revisión**, que matchea la etiqueta `istio.io/rev=<revision>`. La etiqueta genérica `istio-injection=enabled` está atada al webhook "default" (sin revisión), que en esta instalación no existe. Por eso solo `istio.io/rev=1-24-1` dispara la inyección.
2. Son los tipos de configuración que `istiod` (xDS) envía a cada Envoy: **CDS** (Clusters — upstreams/destinos), **LDS** (Listeners — puertos/sockets de escucha), **EDS** (Endpoints — IPs concretas de los pods destino), **RDS** (Routes — reglas de routing HTTP). `SYNCED` = el proxy recibió y confirmó (ACK) la última config. `STALE` = `istiod` la envió pero el proxy no la confirmó (posible problema de conectividad o proxy sobrecargado). `NOT SENT` = no había nada de ese tipo que enviar (p. ej. `RDS NOT SENT` si no hay rutas HTTP definidas).
3. Causas y verificación: (a) el namespace no tiene la etiqueta correcta → `kubectl get ns demo --show-labels`; (b) el webhook de inyección no está registrado o `istiod` de esa revisión no corre → `kubectl get mutatingwebhookconfiguration | grep 1-24-1` y `kubectl get pod -n istio-system`; (c) el pod tiene una anotación `sidecar.istio.io/inject: "false"` que lo excluye explícitamente → `kubectl get pod <pod> -n demo -o yaml | grep -i inject`.

### Ejercicio 5

1. El chart `base` instala los **CRDs** (`VirtualService`, `Gateway`, `DestinationRule`, etc.) y los recursos cluster-wide, incluido el `ValidatingWebhookConfiguration`. `istiod` **depende** de que esos CRDs ya existan: sus Deployments, `ServiceAccounts` y su lógica de reconciliación referencian tipos que Kubernetes debe conocer de antemano. Si instalás `istiod` primero, falla porque los CRDs y el webhook que espera no existen todavía.
2. `defaultRevision=default` marca esa instalación como la revisión por defecto del cluster: hace que la etiqueta genérica `istio-injection=enabled` funcione (queda asociada al webhook "default") y que el `ValidatingWebhookConfiguration` valide recursos contra ese control plane. Sin una `defaultRevision`, deberías usar siempre `istio.io/rev=<revision>` explícito.
3. Con Helm, **vos** sos responsable del ciclo de vida de los CRDs. Helm instala los CRDs del chart `base` en la primera instalación pero, por diseño, **no los actualiza ni los borra** en `helm upgrade`/`helm delete`. `istioctl install`/`upgrade`, en cambio, reconcilia los CRDs por vos. Con Helm, un upgrade que introduce campos nuevos en un CRD requiere que apliques manualmente los CRDs actualizados (`kubectl apply` de los `crds/` del chart) antes o durante el upgrade.

### Ejercicio 6

1. `helm delete` no borra CRDs porque borrar un CRD elimina en cascada **todos los custom resources de ese tipo** en el cluster — una pérdida de datos irreversible que Helm evita deliberadamente. El riesgo al reinstalar otra versión: quedan CRDs de la versión vieja con schemas desactualizados, y la nueva instalación puede comportarse de forma inconsistente hasta que apliques los CRDs nuevos a mano.
2. Orden inverso (`gateway` → `istiod` → `base`) porque las dependencias van de abajo hacia arriba: el `gateway` depende de `istiod` para su configuración (inyección, xDS), e `istiod` depende de los CRDs y webhooks del chart `base`. Borrar `base` primero eliminaría el webhook y CRDs mientras `istiod` y el gateway todavía los necesitan, dejando recursos en estado inconsistente.
3. **Síntoma:** cualquier `kubectl apply` (incluso de recursos no-Istio, si el webhook usa `failurePolicy: Fail` con un selector amplio; y con certeza cualquier recurso de la API de Istio) queda bloqueado con un error tipo `failed calling webhook … connection refused` / `no endpoints available for service "istiod"`, porque el webhook intenta contactar un `istiod` que ya no existe. **Resolución:** eliminar el webhook huérfano — `kubectl delete validatingwebhookconfiguration istio-validator-istio-system` (y el mutating correspondiente) — o, mejor, reinstalar/completar la desinstalación con `istioctl uninstall --purge`, que remueve webhooks, CRDs y control plane de forma coherente.

</details>

---

### Fuentes oficiales

- Istio — *Getting Started* (download e `istioctl`): https://istio.io/latest/docs/setup/getting-started/
- Istio — *Install with istioctl*: https://istio.io/latest/docs/setup/install/istioctl/
- Istio — *Install with Helm*: https://istio.io/latest/docs/setup/install/helm/
- Istio — *Configuration profiles*: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Istio — *Canary upgrades / revisions*: https://istio.io/latest/docs/setup/upgrade/canary/
- Istio — *IstioOperator API reference*: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Istio — *Sidecar injection*: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — *Uninstall*: https://istio.io/latest/docs/setup/getting-started/#uninstall
- CNCF — *ICA Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf