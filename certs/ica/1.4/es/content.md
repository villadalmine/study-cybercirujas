# ICA 1.4 — Upgrading Istio (Canary, In-Place)

> **Perfil:** Platform Architect / SRE Senior · **Peso en examen:** 5
> **Prerrequisitos asumidos:** modelo de sidecar injection, `istiod`, MutatingWebhookConfiguration, revisiones y arquitectura del data plane (Envoy) vs. control plane.

---

## 1. Motivación y el problema arquitectónico de producción

Istio es un componente de infraestructura *stateful desde la perspectiva del tráfico*: cada request en el mesh atraviesa un sidecar Envoy cuya configuración (`xDS`) es empujada por `istiod`. Actualizar Istio no es actualizar un Deployment cualquiera; es cambiar simultáneamente:

1. **El control plane** (`istiod`): el proceso que traduce CRDs (`VirtualService`, `DestinationRule`, `Gateway`, `Sidecar`, etc.) a configuración Envoy y la sirve por xDS.
2. **El data plane** (los sidecars `istio-proxy` inyectados en cada Pod): el binario Envoy + el agente `pilot-agent` que corre *dentro de cada workload*.
3. **Los webhooks de admisión** (`istio-sidecar-injector`): que mutan los Pods en el momento de su creación.
4. **Los CRDs** y **gateways** (ingress/egress).

El problema arquitectónico central es el **acoplamiento temporal**: el data plane vive dentro de los Pods de las aplicaciones, que pertenecen a equipos distintos, con ventanas de mantenimiento distintas, y **no puedes reiniciarlos todos a la vez** en producción. Esto genera dos tensiones:

- **Version skew inevitable.** Durante cualquier upgrade coexisten un `istiod` nuevo y sidecars viejos (o viceversa). Istio garantiza compatibilidad **solo dentro de una ventana de N-2** minor versions: un `istiod` de la versión *N* soporta proxies de hasta *N-2* minor versions atrás. Saltar de 1.18 a 1.21 en un paso viola el skew y produce configuración corrupta o proxies que no sincronizan.
- **Blast radius del control plane.** Si el `istiod` que sirve a *todo* el mesh se rompe tras un upgrade, el mesh entero deja de recibir configuración nueva. Los sidecars siguen sirviendo tráfico con su última config buena (fail-static), pero pierdes la capacidad de reaccionar a cambios de endpoints, y cualquier Pod nuevo se inyecta con el proxy roto.

De aquí nacen las dos estrategias que exige el examen:

- **In-Place upgrade:** reemplazás el `istiod` existente *en su lugar* (misma revisión, mismo webhook). Simple, un solo control plane, pero el rollback del control plane es lento y el blast radius es el mesh completo.
- **Canary upgrade:** instalás un `istiod` nuevo *en paralelo*, identificado por una **revision** distinta, migrás namespaces gradualmente y podés hacer rollback re-apuntando una etiqueta. Es la estrategia recomendada en producción por Istio desde 1.6.

El pilar técnico que hace posible el canary es la **revision**: un `istiod` puede instalarse con `spec.revision=<x>`, lo que sufija todos sus recursos (`istiod-<rev>`, webhook `istio-sidecar-injector-<rev>`) y hace que solo inyecte en namespaces etiquetados `istio.io/rev=<rev>`. Múltiples control planes conviven sin colisionar.

---

## 2. Comparativa técnica: In-Place vs. Canary

### 2.1 Trade-offs de la estrategia

| Dimensión | In-Place upgrade | Canary upgrade |
|---|---|---|
| **Control planes simultáneos** | 1 (reemplazo) | ≥2 (viejo + nuevo en paralelo) |
| **Blast radius** | Mesh completo de golpe | Namespace por namespace |
| **Rollback del control plane** | Reinstalar versión anterior (minutos, arriesgado) | Re-apuntar `revision tag` (segundos) |
| **Rollback del data plane** | Reiniciar todos los workloads | Reiniciar solo los migrados |
| **Overhead de recursos** | Bajo (un `istiod`) | Alto (2× CPU/mem de `istiod` durante la transición) |
| **Complejidad operativa** | Baja | Media/alta (gestión de revisions y tags) |
| **Granularidad de validación** | Todo-o-nada | Progresiva, con canary real de tráfico |
| **Gestión de gateways** | Reinicio in-place del Deployment | Gateway canary paralelo (opcional) |
| **Riesgo de skew** | Alto si el jump es grande | Controlado por namespace |
| **Recomendado para** | Clusters de dev/test, saltos de patch (1.20.1→1.20.2) | Producción, saltos de minor (1.20→1.21) |

> **Regla operativa:** patch upgrades (Z en X.Y.**Z**) son seguros in-place. Minor upgrades (X.**Y**) en producción deben ir por canary. **Nunca** saltes más de un minor por upgrade: respetá la ventana N-2 y encadená 1.19→1.20→1.21.

### 2.2 Revision labels vs. Revision tags

El mecanismo de canary tiene dos variantes de asignación de namespaces:

| Aspecto | Revision label directo (`istio.io/rev=1-21-0`) | Revision tag (`istio.io/rev=prod-stable`) |
|---|---|---|
| Qué apunta el namespace | Directo a una revisión concreta | A un alias estable (tag) |
| Cambiar de revisión | `kubectl label` en **cada** namespace | Un solo `istioctl tag set --overwrite` |
| Acoplamiento | El namespace conoce la versión | El namespace ignora la versión |
| Rollback | Re-labelar todos los namespaces | Re-apuntar el tag (una operación) |
| Recomendado | Migraciones puntuales / testing | Flota grande / GitOps |

Un **revision tag** es un `MutatingWebhookConfiguration` extra (`istio-revision-tag-<tag>`) que funciona como puntero: el namespace referencia el tag y vos re-apuntás el tag a la revisión que quieras. Es la mejor práctica en producción porque desacopla la identidad del namespace de la versión de Istio.

> **Gotcha crítico de precedencia:** si un namespace tiene *ambas* etiquetas `istio-injection=enabled` **y** `istio.io/rev=<x>`, gana `istio-injection=enabled` y la revisión se ignora. El label `istio-injection=enabled` es equivalente a `istio.io/rev=default`. Antes de migrar a canary, hay que **eliminar** `istio-injection`.

---

## 3. Manifiestos e infraestructura completos

### 3.1 IstioOperator — control plane base (revisión estable 1-20-0)

```yaml
# istio-1-20-0.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiod-1-20-0
  namespace: istio-system
spec:
  revision: 1-20-0            # sufija istiod-1-20-0 y su webhook
  profile: default
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
          - name: PILOT_ENABLE_STATUS
            value: "true"
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: LoadBalancer
  meshConfig:
    accessLogFile: /dev/stdout
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true   # evita 503 en arranque durante upgrades
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
  values:
    global:
      istioNamespace: istio-system
```

Instalación de la revisión base:

```console
$ istioctl install -f istio-1-20-0.yaml -y
✔ Istio core installed
✔ Istiod installed
✔ Ingress gateways installed
✔ Installation complete
Made this installation the default for cluster-wide use.
```

Fijamos el tag estable que usarán los namespaces:

```console
$ istioctl tag set prod-stable --revision 1-20-0
Revision tag "prod-stable" created, referencing control plane revision "1-20-0".
To enable injection using this revision tag, use 'istio.io/rev=prod-stable' instead of 'istio-injection=enabled'
```

Etiquetamos los namespaces contra el **tag**, no contra la revisión:

```console
$ kubectl label namespace payments istio.io/rev=prod-stable
$ kubectl label namespace payments istio-injection-   # elimina el label legacy si existe
$ kubectl rollout restart deployment -n payments
```

### 3.2 Canary — segundo control plane en paralelo (1-21-0)

```yaml
# istio-1-21-0.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiod-1-21-0
  namespace: istio-system
spec:
  revision: 1-21-0            # NUEVA revisión, coexiste con 1-20-0
  profile: default
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
  meshConfig:
    accessLogFile: /dev/stdout
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true
```

> **Nota sobre `meshConfig`:** en un canary, cada `istiod` tiene su propio `meshConfig`. Deben ser equivalentes salvo por lo que se está probando; una divergencia accidental (ej. distinto `accessLogFile`) produce comportamiento inconsistente entre namespaces migrados y no migrados. Mantené ambos `IstioOperator` en el mismo repo GitOps para diffear.

Precheck antes de instalar el canary:

```console
$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

Instalación del canary (con el binario `istioctl` **de la versión 1.21**):

```console
$ istioctl-1.21 install -f istio-1-21-0.yaml -y
✔ Istio core installed
✔ Istiod installed
✔ Installation complete

$ kubectl get pods -n istio-system -l app=istiod --show-labels
NAME                             READY   STATUS    AGE   LABELS
istiod-1-20-0-6d8f9c7b5-abcde    1/1     Running   6d    app=istiod,istio.io/rev=1-20-0
istiod-1-20-0-6d8f9c7b5-fghij    1/1     Running   6d    app=istiod,istio.io/rev=1-20-0
istiod-1-21-0-7f9a2b3c4-klmno    1/1     Running   40s   app=istiod,istio.io/rev=1-21-0
istiod-1-21-0-7f9a2b3c4-pqrst    1/1     Running   40s   app=istiod,istio.io/rev=1-21-0
```

### 3.3 Canary de un subconjunto de namespaces (validación real)

Creamos un tag `prod-canary` apuntando a la revisión nueva y migramos **un solo namespace de bajo riesgo**:

```console
$ istioctl-1.21 tag set prod-canary --revision 1-21-0
Revision tag "prod-canary" created, referencing control plane revision "1-21-0".

$ kubectl label namespace ratings istio.io/rev=prod-canary --overwrite
$ kubectl label namespace ratings istio-injection-
$ kubectl rollout restart deployment -n ratings
deployment.apps/ratings-v1 restarted
```

Los Pods de `ratings` ahora se inyectan con el proxy 1.21 servido por `istiod-1-21-0`. El resto del mesh sigue en 1.20. Validás métricas, latencia y logs. Si algo se rompe:

```console
# ROLLBACK instantáneo del namespace canary
$ kubectl label namespace ratings istio.io/rev=prod-stable --overwrite
$ kubectl rollout restart deployment -n ratings
```

### 3.4 Promoción completa: re-apuntar el tag estable

Cuando el canary probó ser sano, **promovés** re-apuntando `prod-stable` a la revisión nueva. Ningún namespace cambia sus labels:

```console
$ istioctl-1.21 tag set prod-stable --revision 1-21-0 --overwrite
Revision tag "prod-stable" updated, referencing control plane revision "1-21-0".

# Reinicio progresivo, namespace por namespace, respetando PDBs
$ kubectl rollout restart deployment -n payments
$ kubectl rollout status  deployment -n payments --timeout=5m
$ kubectl rollout restart deployment -n orders
$ kubectl rollout status  deployment -n orders --timeout=5m
```

### 3.5 Canary de gateways

Los gateways (ingress/egress) también portan un proxy Envoy y deben migrarse. Con **canary gateway**, corrés un ingress paralelo pinneado a la revisión nueva:

```yaml
# ingress-canary-1-21-0.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: ingress-1-21-0
  namespace: istio-system
spec:
  revision: 1-21-0
  profile: empty                 # solo el gateway, sin instalar otro istiod
  components:
    ingressGateways:
      - name: istio-ingressgateway-canary
        enabled: true
        label:
          istio: ingressgateway-canary
        k8s:
          service:
            type: LoadBalancer
```

```console
$ istioctl-1.21 install -f ingress-canary-1-21-0.yaml -y
✔ Ingress gateways installed
✔ Installation complete
```

Migrás el tráfico externo al nuevo gateway a nivel DNS/LB, validás, y retirás el viejo. Para gateways de baja criticidad, un **in-place** del Deployment del gateway (rollout restart tras re-apuntar el tag) es aceptable.

### 3.6 In-Place upgrade con Helm (estrategia alternativa)

Cuando no se usan revisiones (dev/test o patch upgrades), el upgrade in-place con Helm es directo. **El orden importa: CRDs/base primero, luego istiod, luego gateways.**

```console
# 1. Actualizar el repo y CRDs (chart base)
$ helm repo update istio
$ helm upgrade istio-base istio/istio-base \
    -n istio-system --version 1.21.0 --skip-crds=false

# 2. Actualizar el control plane
$ helm upgrade istiod istio/istiod \
    -n istio-system --version 1.21.0 --wait

# 3. Actualizar el gateway (namespace propio)
$ helm upgrade istio-ingressgateway istio/gateway \
    -n istio-ingress --version 1.21.0 --wait

# 4. Reiniciar TODO el data plane (obligatorio: los sidecars no se auto-actualizan)
$ kubectl rollout restart deployment -n payments
$ kubectl rollout restart deployment -n orders
```

> **Punto de examen:** un in-place upgrade del control plane **no actualiza los sidecars**. El binario Envoy vive dentro de cada Pod y solo cambia cuando el Pod se recrea. Sin `rollout restart`, tenés un `istiod` nuevo sirviendo a proxies viejos indefinidamente.

### 3.7 In-Place con `istioctl` (misma revisión)

```console
$ istioctl-1.21 upgrade -f istio-1-20-0.yaml
This will install the Istio 1.21.0 default profile with ["Istio core" "Istiod" "Ingress gateways"] components into the cluster.
Proceed? (y/N) y
✔ Istio core installed
✔ Istiod installed
✔ Ingress gateways installed
✔ Upgrade complete
```

---

## 4. Verificación y diagnóstico de fallas

### 4.1 Estado de sincronización del data plane

`istioctl proxy-status` es la herramienta primaria: muestra qué `istiod` sirve a cada proxy, su versión y si los recursos xDS están `SYNCED`.

```console
$ istioctl proxy-status
NAME                                   CLUSTER      CDS      LDS      EDS      RDS      ISTIOD                          VERSION
ratings-v1-7c9b6d.ratings              Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-21-0-7f9a2b3c4-klmno   1.21.0
payments-v2-5f7a1c.payments            Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-20-0-6d8f9c7b5-abcde   1.20.0
orders-v1-9d2e3f.orders                Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-20-0-6d8f9c7b5-abcde   1.20.0
```

Lectura del ejemplo: `ratings` ya está en el canary (servido por `istiod-1-21-0`, VERSION 1.21.0); `payments` y `orders` siguen en la revisión estable. **Todos `SYNCED`** = el mesh está sano y el skew es válido (1.20 ↔ 1.21, dentro de N-2).

Estados posibles por columna:

| Estado | Significado | Acción |
|---|---|---|
| `SYNCED` | Envoy tiene la última config que envió istiod | OK |
| `NOT SENT` | istiod no envió el recurso (aún) | Normal si no hay recursos de ese tipo; investigar si persiste |
| `STALE` | istiod envió update pero Envoy no lo ACKeó | Problema de conectividad xDS o proxy sobrecargado |

### 4.2 Versiones de control plane y data plane

```console
$ istioctl version
client version: 1.21.0
control plane version: 1.20.0, 1.21.0
data plane version: 1.20.0 (18 proxies), 1.21.0 (3 proxies)
```

Durante un canary este output **debe** mostrar dos versiones de control plane y un data plane mixto. Cuando el upgrade termina y todo se reinició, converge a una sola versión en ambos planos.

### 4.3 Verificar qué webhook inyecta un namespace

```console
$ kubectl get namespace ratings -o jsonpath='{.metadata.labels}' | jq
{
  "istio.io/rev": "prod-canary",
  "kubernetes.io/metadata.name": "ratings"
}

$ istioctl tag list
TAG           REVISION   NAMESPACES
prod-stable   1-21-0     payments,orders
prod-canary   1-21-0     ratings
```

```console
# Ver la imagen real del sidecar en un Pod (confirma la versión del data plane)
$ kubectl get pod -n ratings -l app=ratings \
    -o jsonpath='{.items[0].spec.containers[?(@.name=="istio-proxy")].image}'
docker.io/istio/proxyv2:1.21.0
```

### 4.4 Análisis de configuración

```console
$ istioctl analyze -n ratings
✔ No validation issues found when analyzing namespace: ratings.
```

### 4.5 Guía de diagnóstico de fallas

**Síntoma A — un Pod nuevo arranca sin sidecar tras migrar a canary.**
Causa habitual: el namespace conserva `istio-injection=enabled` junto con `istio.io/rev`, y el label legacy tiene precedencia hacia el webhook `default`, que puede no existir tras la migración.

```console
$ kubectl get ns ratings --show-labels
NAME      STATUS   LABELS
ratings   Active   istio-injection=enabled,istio.io/rev=prod-canary   # <-- CONFLICTO

# Fix: eliminar el label legacy y recrear el Pod
$ kubectl label namespace ratings istio-injection-
$ kubectl rollout restart deployment -n ratings
```

**Síntoma B — proxies en `STALE` o `NOT SENT` tras el upgrade.**
El sidecar no puede alcanzar a su `istiod`. Verificá endpoints del Service del control plane y logs:

```console
$ kubectl get endpoints -n istio-system istiod-1-21-0
NAME            ENDPOINTS                           AGE
istiod-1-21-0   10.244.1.15:15012,10.244.2.9:15012  12m

$ istioctl proxy-config bootstrap ratings-v1-7c9b6d.ratings | \
    grep -A2 discoveryAddress
"discoveryAddress": "istiod-1-21-0.istio-system.svc:15012"

$ kubectl logs -n istio-system deploy/istiod-1-21-0 | grep -i "push"
```

**Síntoma C — 503 UC/UF durante el rollout de los workloads.**
Envoy empieza a recibir tráfico antes de sincronizar rutas. Mitigación: `holdApplicationUntilProxyStarts: true` en `meshConfig.defaultConfig` (ver §3.1) y PodDisruptionBudgets adecuados para el `rollout restart`.

**Síntoma D — el upgrade viola el skew (salto de minor mayor a N-2).**

```console
$ istioctl proxy-status
NAME                       ...   ISTIOD                          VERSION
legacy-app-x.legacy        ...   istiod-1-23-0-...               1.20.0   # 1.20 proxy con 1.23 istiod = SKEW INVÁLIDO
```

Solución: encadenar los minors (1.20→1.21→1.22→1.23), reiniciando el data plane en cada escalón.

**Síntoma E — no puedo eliminar el `istiod` viejo.**
Antes de `uninstall`, verificá que ningún proxy siga apuntando a la revisión antigua:

```console
$ istioctl proxy-status | grep 1-20-0
# (vacío) -> ningún proxy usa la revisión vieja, es seguro desinstalar

$ istioctl uninstall --revision 1-20-0 -y
✔ Uninstall complete
```

Si el output **no** está vacío, hay namespaces sin migrar o workloads sin reiniciar; desinstalar rompería la inyección de sus Pods futuros (los existentes siguen corriendo con su última config).

### 4.6 Checklist de verificación post-upgrade

```console
# 1. Un solo control plane tras completar la promoción
$ istioctl version
control plane version: 1.21.0
data plane version: 1.21.0 (21 proxies)

# 2. Todos los proxies SYNCED
$ istioctl proxy-status | awk 'NR>1 && ($3!="SYNCED"||$4!="SYNCED"){print}'
# (sin salida = todo SYNCED)

# 3. Sin issues de configuración en todo el mesh
$ istioctl analyze --all-namespaces
✔ No validation issues found when analyzing all namespaces.

# 4. Tags apuntando a la revisión correcta
$ istioctl tag list
TAG           REVISION   NAMESPACES
prod-stable   1-21-0     payments,orders,ratings
```

---

## 5. Referencias

- Istio — Canary Upgrades: https://istio.io/latest/docs/setup/upgrade/canary/
- Istio — In-Place Upgrades: https://istio.io/latest/docs/setup/upgrade/in-place/
- Istio — Upgrade overview y skew policy: https://istio.io/latest/docs/setup/upgrade/
- Istio — Safely upgrade Istio using a canary control plane deployment: https://istio.io/latest/blog/2020/multiple-control-planes/
- Istio — Stable Revision Labels (revision tags): https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels
- Istio — Installing the Sidecar / revision-based injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — Install with istioctl: https://istio.io/latest/docs/setup/install/istioctl/
- Istio — Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Istio — Gateway canary upgrade: https://istio.io/latest/docs/setup/upgrade/gateways/
- Istio — `istioctl proxy-status` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-status
- Istio — `istioctl tag` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-tag
- Istio — Release cadence y supported releases: https://istio.io/latest/docs/releases/supported-releases/
- CNCF — Istio Certified Associate (ICA) Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf