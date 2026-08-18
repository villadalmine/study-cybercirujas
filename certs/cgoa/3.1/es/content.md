# 3.1 Herramientas GitOps e Implementación

**Peso en el examen: 25%** — el dominio individual más pesado. Esta sección asume que ya aceptás los cuatro principios de OpenGitOps (declarativo, versionado e inmutable, obtenido automáticamente, reconciliado continuamente). Lo que sigue es cómo esos principios se convierten en infraestructura en ejecución, dónde divergen las implementaciones, y cómo fallan a las 03:00.

---

## 1. El problema arquitectónico

### 1.1 Qué se rompe realmente sin un reconciliador

Un pipeline de push convencional (`jenkins → kubectl apply`) es una **transición de estado del tipo dispará-y-olvidate**. Tiene tres defectos estructurales que solo aparecen a escala de producción:

1. **Sin garantía de convergencia.** `kubectl apply` devuelve éxito cuando el API server *acepta* el objeto, no cuando el clúster *converge* hacia él. Un Deployment cuyo ReplicaSet nunca puede planificarse es un pipeline verde y un clúster rojo.
2. **Sin cierre de la deriva (drift).** Entre dos ejecuciones del pipeline el clúster queda sin gestionar. Un operador ejecutando `kubectl scale`, un mutating webhook reescribiendo un campo, o un controlador de CRD propiedad de un operator escribiendo de vuelta en `spec`, todos hacen divergir silenciosamente el estado vivo respecto de Git. La siguiente ejecución del pipeline puede corregirlo o no, según si el campo está presente en el manifiesto aplicado.
3. **Frontera de confianza invertida.** CI guarda credenciales de cluster-admin *fuera* del clúster. Comprometer el runner de CI compromete cada clúster que pueda alcanzar. Esta es la razón por la que existe el modelo pull — es un control de seguridad antes que una conveniencia de entrega.

Un agente GitOps reemplaza la transición por un **lazo de control cerrado** que corre dentro de la frontera de confianza que gestiona.

### 1.2 El lazo de control, formalizado

```
                 ┌──────────────────────────────────────────┐
                 │            Desired State (S_d)           │
                 │  Git ref / OCI artifact digest — immutable│
                 └────────────────┬─────────────────────────┘
                                  │  fetch (poll interval | webhook | OCI digest)
                                  ▼
                    ┌─────────────────────────┐
                    │   Renderer / Hydrator   │  kustomize build, helm template,
                    │   (pure function)       │  jsonnet, CMP plugin
                    └────────────┬────────────┘
                                 │  S_d'  (fully rendered manifests)
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Differ:  Δ = diff(S_d', S_a, S_last-applied)   │  ← three-way merge
        └────────────────────────┬───────────────────────┘
                                 │  Δ ≠ ∅
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Actuator: SSA / patch / create / delete-prune  │
        └────────────────────────┬───────────────────────┘
                                 │
                                 ▼
        ┌────────────────────────────────────────────────┐
        │  Health assessor: Kind-aware readiness → status │
        └────────────────────────┬───────────────────────┘
                                 │  emit: events, metrics, notifications
                                 ▼
                       Actual State (S_a) in etcd
```

Cuatro propiedades que todo agente conforme debe proveer, y el vocabulario de examen para cada una:

| Propiedad | Significado | Falla si está ausente |
|---|---|---|
| **Idempotencia** | `apply(S_d)` aplicado N veces ≡ aplicado una vez | Los lazos de reconciliación se atascan, los contadores de generación giran |
| **Convergencia** | El lazo termina en `S_a ≡ S_d'` o reporta divergencia | Sincronización parcial silenciosa |
| **Detección de deriva** | `S_a ≠ S_d'` es *observable* con independencia de un evento de despliegue | Mutación manual no detectada |
| **Remediación de deriva** | El lazo revierte el cambio no autorizado (self-heal) | Detección sin aplicación — teatro de auditoría |

### 1.3 El problema del diff a tres vías

Esta es la mecánica peor entendida y una trampa de examen confiable. El diff a dos vías (`desired` contra `live`) es incorrecto, porque el objeto vivo contiene campos que *nadie escribió nunca en Git*: campos con valores por defecto (`spec.strategy`, `terminationGracePeriodSeconds`), inyecciones de mutating webhooks (sidecars de Istio, agentes de Vault) y campos escritos por controladores (`spec.replicas` bajo un HPA).

El reconciliador debe por lo tanto hacer el diff contra un registro de **lo que él mismo aplicó por última vez**:

- **Client-side apply (CSA)** guarda ese registro en la anotación `kubectl.kubernetes.io/last-applied-configuration`. Está limitada por los 256 KB de la anotación / la presión sobre etcd y pierde fidelidad en CRDs grandes.
- **Server-side apply (SSA)** mueve la propiedad a `metadata.managedFields`, por campo y por manager. El propio API server calcula la fusión y devuelve `409 Conflict` cuando dos managers reclaman el mismo campo. Este es el valor por defecto correcto en 2026.

Tanto Argo CD (`ServerSideApply=true`) como Flux (SSA por defecto desde v2) lo soportan. Consecuencia que tenés que internalizar: **con SSA, "quién es dueño de `spec.replicas`" es un hecho de primera clase y consultable.**

```bash
$ kubectl get deploy checkout-api -n payments -o jsonpath='{.metadata.managedFields[*].manager}' | tr ' ' '\n'
kustomize-controller
kube-controller-manager
horizontal-pod-autoscaler
```

---

## 2. El panorama de herramientas

### 2.1 Taxonomía

El currículum de CGOA trata al "tooling" como una pila en capas, no como una lista de productos. Conocé la capa, y cualquier producto encaja en ella:

| Capa | Responsabilidad | Implementaciones representativas |
|---|---|---|
| **Fuente / artefacto** | Obtener y verificar el estado deseado inmutable | Flux `source-controller`, Argo CD `repo-server`, registries OCI, `cosign` |
| **Renderizado de manifiestos** | Función pura: fuente → YAML | Kustomize, Helm, Jsonnet, cdk8s, KCL, sidecars CMP de Argo CD |
| **Reconciliación / entrega** | Diff + apply + prune + health | Argo CD, Flux, Rancher Fleet, Kubestack, Sveltos |
| **Promoción / orquestación** | Mover una versión a través de entornos | Kargo, sincronización progresiva de ApplicationSet, automatización de imágenes de Flux, bots de PR |
| **Entrega progresiva** | Despliegue con desplazamiento de tráfico y análisis | Argo Rollouts, Flagger |
| **Secretos** | Entregar texto cifrado a través de Git de forma segura | SOPS, Sealed Secrets, External Secrets Operator, Vault Secrets Operator |
| **Política / admisión** | Rechazar estado deseado no conforme | Kyverno, OPA Gatekeeper, `conftest` en CI |
| **Observabilidad** | Exponer deriva, latencia de sincronización, fallos | Métricas de Prometheus, notification-controller, argocd-notifications |

Argo CD y Flux son ambos **CNCF Graduated** (ambos se graduaron en diciembre de 2022, bajo los proyectos Argo y Flux respectivamente). Cualquier cosa que el examen pregunte sobre "la herramienta GitOps" es respondible en términos de esos dos.

### 2.2 Arquitectura de Argo CD, componente por componente

```
                    ┌──────────────────────────────────────────────┐
   user / CI ──────▶│ argocd-server        (API + gRPC + web UI)   │
   SSO (OIDC) ─────▶│  ├─ RBAC (argocd-rbac-cm), projects, sessions│
                    └───────────┬──────────────────────────────────┘
                                │ gRPC
                    ┌───────────▼──────────────────────────────────┐
                    │ argocd-repo-server                           │
                    │  git clone / helm pull / OCI pull            │
                    │  → kustomize build | helm template | CMP     │
                    │  → manifest cache (Redis, keyed by revision) │
                    └───────────┬──────────────────────────────────┘
                                │ rendered manifests
     ┌──────────────────────────▼──────────────────────────────────┐
     │ argocd-application-controller   (StatefulSet, shardable)    │
     │  informers per destination cluster → live state cache       │
     │  diff → sync (waves, hooks) → health assessment (Lua)       │
     └──────────────────────────┬──────────────────────────────────┘
                                │
     ┌──────────────┬───────────┴──────────┬─────────────────┐
     │ applicationset-controller           │ notifications-  │
     │ (generators → Application CRs)      │ controller      │
     └─────────────────────────────────────┴─────────────────┘
                    argocd-redis (cache)   argocd-dex-server (SSO federation)
```

Datos clave que aparecen en las preguntas:

- El **application-controller es un StatefulSet**, no un Deployment, porque el sharding es por índice (`ARGOCD_CONTROLLER_REPLICAS` + ordinal del pod).
- El **repo-server es el único componente que ejecuta código de renderizado no confiable** (hooks de Helm, plugins CMP, Jsonnet). Es el lugar correcto para imponer `securityContext`, NetworkPolicy de egreso y límites de CPU/memoria.
- Argo CD es **dirigido por API y multi-tenant por diseño**: `AppProject` es una frontera de seguridad real; el RBAC es a nivel de aplicación, no solo RBAC de Kubernetes.
- Custom resources: `Application`, `ApplicationSet`, `AppProject`, todos `argoproj.io/v1alpha1`.

### 2.3 Arquitectura de Flux, controlador por controlador

Flux es el **GitOps Toolkit**: un conjunto de controladores de responsabilidad única compuestos sobre la API de Kubernetes. No hay servidor central, ni UI, ni base de datos separada.

| Controlador | CRDs que posee | Responsabilidad |
|---|---|---|
| `source-controller` | `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`, `Bucket` | Obtener, verificar (GPG/cosign/checksum), exponer como un tarball vía HTTP interno del clúster; emitir `.status.artifact.revision` |
| `kustomize-controller` | `Kustomization` | `kustomize build` → apply con SSA → prune → health-check → emitir eventos |
| `helm-controller` | `HelmRelease` | Manejar el SDK de Helm (install/upgrade/rollback/test), detección de deriva sobre el release |
| `notification-controller` | `Provider`, `Alert`, `Receiver` | Alertas de egreso; webhooks de ingreso (`Receiver`) para disparar reconciliación inmediata |
| `image-reflector-controller` | `ImageRepository`, `ImagePolicy` | Escanear tags del registry, seleccionar una versión por política (semver/numérica/alfabética) |
| `image-automation-controller` | `ImageUpdateAutomation` | Escribir el tag seleccionado **de vuelta en Git** y hacer push |

```
 Git / OCI / S3 / Helm repo
        │
        ▼
 ┌────────────────┐   artifact (tar.gz + revision)   ┌────────────────────┐
 │ source-        │─────────────────────────────────▶│ kustomize-         │──▶ SSA apply
 │ controller     │                                  │ controller         │──▶ prune
 └────────────────┘─────────────────────────────────▶│ helm-controller    │──▶ helm upgrade
        ▲                                            └─────────┬──────────┘
        │  ImageUpdateAutomation writes back                   │ events
 ┌──────┴──────────┐   ┌─────────────────┐          ┌──────────▼──────────┐
 │ image-automation│◀──│ image-reflector │          │ notification-       │──▶ Slack/Teams/
 └─────────────────┘   └─────────────────┘          │ controller          │    GitHub/Alertmgr
                                                    └─────────────────────┘
```

La consecuencia arquitectónica crítica: **en Flux, el estado deseado del propio Flux es una `Kustomization` llamada `flux-system` que reconcilia el directorio que contiene los manifiestos del propio Flux.** Flux se actualiza a sí mismo reconciliándose a sí mismo. Argo CD logra lo equivalente con una `Application` que gestiona el namespace `argocd` ("Argo CD gestiona Argo CD").

### 2.4 Comparación frente a frente

| Dimensión | Argo CD | Flux v2 |
|---|---|---|
| **Unidad de entrega** | `Application` (un path de origen → un destino) | `Kustomization` / `HelmRelease` (desacoplados del origen) |
| **Reutilización del origen** | El origen está embebido en cada `Application` | Un `GitRepository`, N `Kustomization`s que lo referencian — menos carga de sondeo sobre Git |
| **UI / API** | UI web de primera clase, API gRPC/REST, CLI | Sin UI en el núcleo (Flux UI es de terceros/Weave GitOps); `kubectl` + CLI `flux` |
| **Modelo multi-clúster** | **Hub-and-spoke** por defecto: un Argo CD gestiona muchos clústeres vía kubeconfigs almacenados (`Secret` etiquetado con `argocd.argoproj.io/secret-type: cluster`) | **Local al clúster** por defecto: un Flux por clúster; el modelo hub es posible vía `spec.kubeConfig` |
| **Radio de impacto del plano de control** | El Argo CD central tiene credenciales de cada spoke — un objetivo de alto valor | El Flux de cada clúster tiene solo sus propias credenciales |
| **Primitiva de tenencia** | `AppProject` (lista blanca de repos, lista blanca de destinos, permitir/denegar recursos, ventanas de sincronización, roles RBAC) | Impersonación de `ServiceAccount` por `Kustomization` + `--no-cross-namespace-refs=true` |
| **Modelo RBAC** | RBAC a nivel de aplicación en `argocd-rbac-cm`, desacoplado del RBAC de k8s | RBAC puro de Kubernetes — sin un segundo sistema de autorización sobre el que razonar |
| **Ordenamiento** | Sync waves (`argocd.argoproj.io/sync-wave`) + hooks (PreSync/Sync/PostSync/SyncFail) | `spec.dependsOn` entre `Kustomization`s / `HelmRelease`s + `spec.wait: true` |
| **Remediación de deriva** | Opcional (opt-in): `syncPolicy.automated.selfHeal: true` | Implícita: cada intervalo re-aplica vía SSA; `spec.force` para conflictos de campos inmutables |
| **Prune** | Opcional (opt-in): `syncPolicy.automated.prune: true` | Opcional (opt-in): `spec.prune: true` (inventario rastreado en el status de la `Kustomization`) |
| **Mecanismo de recolección de basura** | Etiqueta/anotación de rastreo (`app.kubernetes.io/instance` o `argocd.argoproj.io/tracking-id`) | Lista de inventario explícita en `Kustomization.status.inventory` |
| **Automatización de imágenes** | Argo CD Image Updater (separado, menos maduro) o Kargo | Controladores nativos `image-reflector` + `image-automation`, escriben commits en Git |
| **Manejo de Helm** | `helm template` — **sin objeto de release de Helm en el clúster**; los hooks de Helm se emulan parcialmente | SDK real de Helm — `helm list` funciona; semántica completa de hooks/test/rollback |
| **OCI como fuente de verdad** | Soportado (`Application.spec.source.repoURL` con `oci://`) | De primera clase (`OCIRepository` + `flux push artifact`), con verificación keyless de cosign |
| **Límite de escalado** | Controlador central: shardear por clúster; CPU del repo-server en el renderizado de Helm/Kustomize | Horizontal por diseño; `--concurrent` por controlador, sharding vía `sharding.fluxcd.io/key` |
| **Modo de fallo cuando el agente está caído** | El clúster sigue funcionando; la deriva se acumula sin ser notada; una caída central afecta a todos los clústeres | El clúster sigue funcionando; la deriva se acumula solo en ese clúster |

**Heurística de selección para una plataforma de producción:**

- Muchos clústeres, muchos tenants, humanos que necesitan una superficie de autoservicio y diff visual → **Argo CD**.
- Clúster-como-producto, todo a través de PRs, sin consola humana, la historia de cadena de suministro más fuerte (OCI + cosign + SOPS nativos) → **Flux**.
- La combinación es legítima y común: **Flux para la capa de plataforma/infraestructura, Argo CD para los equipos de aplicación**, o Argo CD para la entrega + Flagger para la entrega progresiva.

### 2.5 Push contra pull, dicho con precisión

| | Push (CI aplica) | Pull (el agente reconcilia) |
|---|---|---|
| Ubicación de las credenciales | Fuera del clúster, en CI | Dentro del clúster, acotadas a ese clúster |
| Requisito de red | CI debe alcanzar el API server (a menudo público o por VPN) | El clúster alcanza Git/OCI solo por egreso; el API server puede ser totalmente privado |
| Manejo de la deriva | Ninguno entre ejecuciones | Continuo |
| Latencia hasta el despliegue | Inmediata | Intervalo de sondeo, o inmediata con un `Receiver` de webhook |
| Auditabilidad | Logs de CI (mutables, con retención limitada) | Historia de Git + eventos del clúster (el commit *es* el registro de auditoría) |
| Funciona para destinos no-Kubernetes | Sí, trivialmente | Requiere un reconciliador para ese destino (Crossplane, Terraform controller, Cluster API) |

El costo honesto del modelo pull: **no podés desplegar más rápido que el intervalo de reconciliación a menos que cablees webhooks**, y una caída de Git congela la promoción (aunque no la carga de trabajo en ejecución).

---

## 3. Topología del repositorio y generación de manifiestos

### 3.1 Monorepo contra polyrepo

| Criterio | Monorepo (un repo, todos los entornos/apps) | Polyrepo (un repo por app o por clúster) |
|---|---|---|
| Cambio transversal atómico | Un solo PR, un solo SHA de commit | N PRs, sin atomicidad |
| Granularidad de RBAC | Basada en directorios vía `CODEOWNERS` — frontera débil | A nivel de repositorio — frontera fuerte |
| Carga del agente | Un clon de `GitRepository`/repo-server reutilizado por N `Kustomization`s | N clones, N ciclos de sondeo |
| Radio de impacto de un mal commit | Potencialmente toda la plataforma | Una app |
| Revisabilidad de un diff de promoción | Excelente (directorios de entorno lado a lado) | Requiere herramientas entre repositorios |
| Límite de escalado | Tiempo de clonado de Git; CPU del repo-server de Argo CD; fan-out de webhooks | Proliferación de repos, convenciones que derivan |

**Valor por defecto de producción:** el *código fuente* en repos por app; el *estado deseado* en uno o unos pocos **repos de configuración**, separados por frontera de confianza (`platform-gitops`, `tenant-a-gitops`). Nunca pongas el estado deseado en el repo de la app si CI puede escribir en él *y* además los humanos despliegan desde ahí — perdés la compuerta de revisión.

### 3.2 Modelado de entornos

| Patrón | Mecanismo | Veredicto |
|---|---|---|
| **Una rama por entorno** (`dev`, `staging`, `prod`) | El agente sigue una rama distinta por clúster | **Antipatrón.** La promoción se convierte en un merge; los merges arrastran cambios no intencionados; las ramas derivan y los cherry-picks se vuelven la norma. Desaconsejado explícitamente por ambos proyectos. |
| **Un directorio por entorno** (`envs/prod/…`) | Misma rama, distinto `path` | **Recomendado.** La promoción es un diff que podés leer. |
| **Base + overlays de Kustomize** | `base/` + `overlays/<env>` | Recomendado, con una salvedad: los overlays ocultan el resultado final — revisás el parche, no el manifiesto. |
| **Rama de manifiestos renderizados** | CI renderiza cada entorno en ramas `env/<name>` que contienen YAML plano; el agente sigue esas, nunca plantillas | **La mejor revisabilidad.** El diff del PR es literalmente lo que va a existir en etcd. Cuesta un paso de hidratación en CI. |
| **Un artefacto OCI por entorno** | CI renderiza + `flux push artifact` + `cosign sign`; el agente obtiene por digest | **La cadena de suministro más fuerte.** El estado deseado es inmutable por construcción (digest), firmado, y desacoplado de la disponibilidad de Git. |

### 3.3 El patrón de manifiestos renderizados, en concreto

```
platform-gitops (repo)
├── main                        ← source of truth, humans edit here
│   ├── base/
│   └── envs/{dev,stg,prod}/
└── env/prod                    ← machine-written branch, humans only READ
    └── manifests.yaml          ← output of `kustomize build envs/prod`
```

Trabajo de CI al hacer merge a `main`:

```bash
$ kustomize build envs/prod --enable-helm > /tmp/manifests.yaml
$ kubeconform -strict -summary -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    /tmp/manifests.yaml
Summary: 214 resources found parsing stdin - Valid: 214, Invalid: 0, Errors: 0, Skipped: 0
$ git checkout env/prod && cp /tmp/manifests.yaml . && git commit -am "render: main@$(git rev-parse --short main)" && git push
```

El reconciliador entonces apunta a `env/prod` **sin renderizado alguno**, lo que elimina toda una clase de incidentes del tipo "renderizó distinto en el clúster que en mi terminal".

---

## 4. Implementación: Flux de punta a punta

### 4.1 Chequeo previo y bootstrap

```bash
$ flux check --pre
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
✔ prerequisites checks passed

$ export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
$ flux bootstrap github \
    --owner=acme \
    --repository=platform-gitops \
    --branch=main \
    --path=clusters/prod-eu-west-1 \
    --components-extra=image-reflector-controller,image-automation-controller \
    --token-auth=false \
    --personal=false
► connecting to github.com
► cloning branch "main" from Git repository "https://github.com/acme/platform-gitops.git"
✔ cloned repository
► generating component manifests
✔ generated component manifests
✔ committed component manifests to "main" ("7f3ac21")
► pushing component manifests to "https://github.com/acme/platform-gitops.git"
► installing components in "flux-system" namespace
✔ installed components
✔ reconciled components
► determining if source secret "flux-system/flux-system" exists
► generating source secret
✔ public key: ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAI...
✔ configured deploy key "flux-system-main-flux-system-./clusters/prod-eu-west-1"
► applying source secret "flux-system/flux-system"
✔ reconciled source secret
► generating sync manifests
✔ generated sync manifests
✔ committed sync manifests to "main" ("a91b04e")
► pushing sync manifests to "https://github.com/acme/platform-gitops.git"
► applying sync manifests
✔ reconciled sync configuration
► confirming components are healthy
✔ helm-controller: deployment ready
✔ image-automation-controller: deployment ready
✔ image-reflector-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ notification-controller: deployment ready
✔ source-controller: deployment ready
✔ all components are healthy
```

Qué hizo `bootstrap`, en términos GitOps: commiteó los propios manifiestos de Flux a Git, los aplicó una vez de forma imperativa para romper el problema del huevo y la gallina, y luego creó un par `GitRepository` + `Kustomization` que hace que Flux reconcilie ese mismo path para siempre. **Desde este punto, cada cambio al propio Flux es un PR.**

### 4.2 Disposición del repositorio

```
platform-gitops/
├── clusters/
│   ├── prod-eu-west-1/
│   │   ├── flux-system/                 # written by bootstrap, do not hand-edit
│   │   │   ├── gotk-components.yaml
│   │   │   ├── gotk-sync.yaml
│   │   │   └── kustomization.yaml
│   │   ├── infra-controllers.yaml       # Kustomization → infra/controllers
│   │   ├── infra-configs.yaml           # Kustomization → infra/configs
│   │   └── tenants.yaml                 # Kustomization → tenants/prod
│   └── stg-eu-west-1/
├── infra/
│   ├── controllers/                     # cert-manager, ingress-nginx, ESO, kyverno
│   └── configs/                         # ClusterIssuer, ClusterSecretStore, policies
└── tenants/
    ├── base/checkout/
    └── prod/checkout/
```

### 4.3 La cadena de dependencias — manifiestos completos

`clusters/prod-eu-west-1/infra-controllers.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  path: ./infra/controllers
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Fail fast instead of hanging for the full timeout on a bad chart.
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cert-manager-webhook
      namespace: cert-manager
    - apiVersion: apps/v1
      kind: Deployment
      name: ingress-nginx-controller
      namespace: ingress-nginx
```

`clusters/prod-eu-west-1/infra-configs.yaml` — depende de los controladores porque crea CRs que son propiedad de ellos:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  dependsOn:
    - name: infra-controllers
  path: ./infra/configs
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substitute:
      cluster_name: prod-eu-west-1
      cluster_region: eu-west-1
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
        optional: false
  patches:
    - target:
        kind: ClusterIssuer
        name: letsencrypt
      patch: |
        - op: replace
          path: /spec/acme/server
          value: https://acme-v02.api.letsencrypt.org/directory
```

`clusters/prod-eu-west-1/tenants.yaml` — reconciliación del tenant bajo una ServiceAccount impersonada, que es cómo Flux impone la multi-tenencia:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tenants
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 5m
  dependsOn:
    - name: infra-configs
  path: ./tenants/prod
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Impersonate a namespace-scoped SA: the tenant cannot escalate beyond
  # what this SA's RoleBindings allow, regardless of what YAML they commit.
  serviceAccountName: tenant-reconciler
  targetNamespace: checkout
```

### 4.4 Origen con verificación de firma (cadena de suministro)

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m
  ref:
    branch: main
  secretRef:
    name: flux-system
  url: ssh://git@github.com/acme/platform-gitops
  ignore: |
    /*
    !/clusters
    !/infra
    !/tenants
  # Reject any commit not signed by a key in this ConfigMap.
  verify:
    mode: HEAD
    secretRef:
      name: platform-gpg-public-keys
```

Variante OCI — el estado deseado como un artefacto firmado e inmutable:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: checkout-manifests
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/acme/checkout-manifests
  ref:
    semver: ">=1.4.0 <2.0.0"
  secretRef:
    name: ghcr-auth
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/acme/checkout/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

> Nota: `OCIRepository` fue promovido de `v1beta2` a `v1` en releases recientes de Flux. Confirmá siempre con `kubectl api-resources --api-group=source.toolkit.fluxcd.io` en el clúster al que estás apuntando, en lugar de confiar en una versión memorizada.

### 4.5 HelmRelease con semántica real de release

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: ingress-nginx
  namespace: flux-system
spec:
  interval: 24h
  url: https://kubernetes.github.io/ingress-nginx
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ingress-nginx
  namespace: ingress-nginx
spec:
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: ingress-nginx
      version: "4.12.x"
      sourceRef:
        kind: HelmRepository
        name: ingress-nginx
        namespace: flux-system
      interval: 12h          # chart version re-resolution cadence
  install:
    remediation:
      retries: 3
    crds: CreateReplace
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
      strategy: rollback
    crds: CreateReplace
    cleanupOnFail: true
  # Detect and correct drift on the rendered release, not just on the values.
  driftDetection:
    mode: enabled
    ignore:
      - paths: ["/spec/replicas"]
        target:
          kind: Deployment
  test:
    enable: true
    ignoreFailures: false
  values:
    controller:
      replicaCount: 3
      service:
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: nlb
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/component: controller
  valuesFrom:
    - kind: ConfigMap
      name: ingress-nginx-cluster-values
      valuesKey: values.yaml
      optional: true
```

### 4.6 Automatización de imágenes — el lazo de escritura de vuelta

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: checkout
  namespace: flux-system
spec:
  image: ghcr.io/acme/checkout
  interval: 5m
  secretRef:
    name: ghcr-auth
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: checkout
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: checkout
  filterTags:
    # Only tags of the form 1.4.2-<sha>; extract the semver part.
    pattern: '^(?P<semver>[0-9]+\.[0-9]+\.[0-9]+)-[a-f0-9]+$'
    extract: '$semver'
  policy:
    semver:
      range: ">=1.4.0 <2.0.0"
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: checkout-prod
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@acme.io
      messageTemplate: |
        chore(prod): update images

        {{ range .Changed.Changes -}}
        - {{ .OldValue }} -> {{ .NewValue }}
        {{ end -}}
      signingKey:
        secretRef:
          name: flux-git-signing-key
    push:
      branch: main
  update:
    path: ./tenants/prod
    strategy: Setters
```

Y el marcador en el manifiesto del tenant que le dice al controlador de automatización qué campo reescribir:

```yaml
spec:
  template:
    spec:
      containers:
        - name: checkout
          image: ghcr.io/acme/checkout:1.4.2-9f3ac21 # {"$imagepolicy": "flux-system:checkout"}
```

**Punto arquitectónico:** el nuevo tag aterriza en Git *primero*. El clúster cambia únicamente porque el reconciliador observó un commit. El rastro de auditoría nunca se rompe.

### 4.7 Notificaciones y reconciliación disparada por webhook

```yaml
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-platform
  namespace: flux-system
spec:
  type: slack
  channel: platform-alerts
  secretRef:
    name: slack-webhook-url
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: on-call
  namespace: flux-system
spec:
  providerRef:
    name: slack-platform
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      name: '*'
    - kind: Kustomization
      name: '*'
    - kind: HelmRelease
      name: '*'
  exclusionList:
    - "waiting for rollout to finish"
  suspend: false
---
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-push
  namespace: flux-system
spec:
  type: github
  events:
    - "ping"
    - "push"
  secretRef:
    name: github-webhook-token
  resources:
    - kind: GitRepository
      name: flux-system
```

```bash
$ kubectl -n flux-system get receiver github-push
NAME           AGE   READY   STATUS
github-push    3d    True    Receiver initialized for path: /hook/12ef9a...c4b1
```

Ese path, expuesto a través del Service/Ingress `webhook-receiver`, es lo que registrás en GitHub. Colapsa la latencia de reconciliación de `interval` a menos de un segundo, dejando el sondeo como red de seguridad.

---

## 5. Implementación: Argo CD de punta a punta

### 5.1 Instalación y la raíz app-of-apps

```bash
$ kubectl create namespace argocd
namespace/argocd created
$ kubectl apply -n argocd -k https://github.com/argoproj/argo-cd/manifests/cluster-install?ref=stable
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
statefulset.apps/argocd-application-controller created
deployment.apps/argocd-repo-server created
deployment.apps/argocd-server created

$ argocd login argocd.acme.io --sso --grpc-web
Opening browser for authentication
Authentication successful
'villadalmine@gmail.com' logged in successfully
Context 'argocd.acme.io' updated
```

La raíz **app-of-apps** — el único acto imperativo, después del cual todo es declarativo:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-bootstrap
  namespace: argocd
  finalizers:
    # Cascading delete: removing this Application prunes its children.
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/acme/platform-gitops.git
    targetRevision: main
    path: clusters/prod-eu-west-1/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
```

### 5.2 `AppProject` — la frontera de tenencia

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-checkout
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Checkout squad — payments domain
  sourceRepos:
    - https://github.com/acme/checkout-gitops.git
    - https://acme.github.io/charts
  destinations:
    - server: https://kubernetes.default.svc
      namespace: checkout
    - server: https://kubernetes.default.svc
      namespace: checkout-jobs
  # Tenants may not create cluster-scoped objects at all...
  clusterResourceWhitelist: []
  # ...and are denied the namespaced escalation vectors.
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: rbac.authorization.k8s.io
      kind: Role
  roles:
    - name: deployer
      description: Sync and rollback, no destination edits
      policies:
        - p, proj:tenant-checkout:deployer, applications, get,      tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, sync,     tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, action/*, tenant-checkout/*, allow
        - p, proj:tenant-checkout:deployer, applications, delete,   tenant-checkout/*, deny
      groups:
        - acme:checkout-engineers
  syncWindows:
    - kind: deny
      schedule: "0 22 * * 5"      # Friday 22:00
      duration: 58h               # through Monday 08:00
      applications:
        - "*"
      manualSync: true            # break-glass still permitted
      timeZone: "Europe/Madrid"
  orphanedResources:
    warn: true
```

### 5.3 `ApplicationSet` — generar Applications en lugar de escribirlas

El **generador matrix** (clústeres × directorios de aplicaciones) es el patrón canónico de flota:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
                  env: prod
          - git:
              repoURL: https://github.com/acme/platform-gitops.git
              revision: main
              files:
                - path: "tenants/prod/*/config.json"
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: wave
              operator: In
              values: ["canary"]
        - matchExpressions:
            - key: wave
              operator: In
              values: ["primary"]
          maxUpdate: 25%
  template:
    metadata:
      name: '{{ .name }}-{{ .tenant }}'
      labels:
        wave: '{{ .wave }}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: 'tenant-{{ .tenant }}'
      source:
        repoURL: https://github.com/acme/platform-gitops.git
        targetRevision: main
        path: 'tenants/prod/{{ .tenant }}'
        kustomize:
          commonAnnotations:
            acme.io/cluster: '{{ .name }}'
      destination:
        server: '{{ .server }}'
        namespace: '{{ .tenant }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  # Safety rail: refuse to act if the generator suddenly yields far fewer apps.
  # Without this, a bad `git` generator path deletes the whole fleet.
  syncPolicy:
    applicationsSync: create-update
    preserveResourcesOnDeletion: false
```

> El bloque `strategy.rollingSync` es lo que convierte a un `ApplicationSet` de un fan-out en un **despliegue progresivo de flota**: los clústeres canario sincronizan primero, y el paso siguiente solo comienza cuando las Applications del paso previo reportan `Healthy`.

### 5.4 Ordenamiento: sync waves y hooks

```yaml
---
# Wave -2: CRDs must exist before any CR referencing them is validated.
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: rollouts.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec: {} # …
---
# Wave -1 PreSync hook: schema migration must complete before new pods start.
apiVersion: batch/v1
kind: Job
metadata:
  name: checkout-db-migrate
  namespace: checkout
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: checkout-migrator
      containers:
        - name: migrate
          image: ghcr.io/acme/checkout-migrations:1.4.2
          command: ["/bin/migrate", "up", "--lock-timeout=300s"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: checkout-db
                  key: url
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {memory: 512Mi}
---
# Wave 0: the workload itself.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: checkout
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  replicas: 6
  selector:
    matchLabels: {app: checkout-api}
  template:
    metadata:
      labels: {app: checkout-api}
    spec:
      containers:
        - name: api
          image: ghcr.io/acme/checkout@sha256:6f2a1c9b8e4d5a3f7c0b1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a
          ports: [{containerPort: 8080, name: http}]
          readinessProbe:
            httpGet: {path: /readyz, port: http}
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /livez, port: http}
            periodSeconds: 10
          resources:
            requests: {cpu: 250m, memory: 256Mi}
            limits:   {memory: 1Gi}
---
# PostSync: smoke test. Failure triggers the SyncFail hook.
apiVersion: batch/v1
kind: Job
metadata:
  name: checkout-smoke
  namespace: checkout
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: smoke
          image: ghcr.io/acme/smoke:1.4.2
          args: ["--endpoint", "http://checkout-api.checkout.svc:8080"]
```

| Fase del hook | Cuándo se ejecuta | Uso típico |
|---|---|---|
| `PreSync` | Antes de que se aplique cualquier wave | Migración de BD, snapshot de respaldo |
| `Sync` | Junto con los manifiestos, respeta las waves | Orquestación de apply personalizada |
| `Skip` | Nunca aplicado por Argo CD | Manifiestos gestionados en otro lado |
| `PostSync` | Después de que todos los recursos reporten Healthy | Smoke test, precalentamiento de caché, notificar |
| `SyncFail` | Después de una sincronización fallida | Disparador de rollback, apertura de incidente |

`hook-delete-policy`: `HookSucceeded` | `HookFailed` | `BeforeHookCreation` (por defecto). Elegí `BeforeHookCreation` cuando necesitás que los logs del Job fallido sobrevivan para el triaje.

### 5.5 Domar la falsa deriva: `ignoreDifferences`

La queja operativa más común — "Argo CD dice OutOfSync para siempre" — es casi siempre un campo escrito por otro controlador.

```yaml
spec:
  ignoreDifferences:
    # HPA owns replicas. Argo CD must not fight it.
    - group: apps
      kind: Deployment
      name: checkout-api
      namespace: checkout
      jsonPointers:
        - /spec/replicas
    # Istio/Linkerd sidecar injection adds containers at admission time.
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - '.spec.template.spec.containers[] | select(.name == "istio-proxy")'
        - '.spec.template.spec.initContainers[] | select(.name == "istio-init")'
    # cert-manager writes the CA bundle into the webhook config.
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
    # With SSA, ignore everything a named manager owns — the precise tool.
    - group: "*"
      kind: "*"
      managedFieldsManagers:
        - kube-controller-manager
        - horizontal-pod-autoscaler
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true   # also skip these fields during SYNC, not just diff
```

`RespectIgnoreDifferences=true` es la parte que la gente pasa por alto: sin ella, `ignoreDifferences` oculta el diff en la UI pero la sincronización igual sobrescribe el campo, así que el HPA y Argo CD juegan al ping-pong.

### 5.6 Health personalizado para un CRD (Lua, en `argocd-cm`)

Argo CD no puede saber si tu CR `Cluster` está sano. Enseñáselo:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
data:
  application.resourceTrackingMethod: annotation
  timeout.reconciliation: 180s
  resource.customizations.health.cert-manager.io_Certificate: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" and condition.status == "False" then
          hs.status = "Degraded"
          hs.message = condition.message
          return hs
        end
        if condition.type == "Ready" and condition.status == "True" then
          hs.status = "Healthy"
          hs.message = condition.message
          return hs
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate to be issued"
    return hs
  resource.customizations.ignoreResourceUpdates.all: |
    jsonPointers:
      - /status
      - /metadata/resourceVersion
```

`application.resourceTrackingMethod: annotation` es un cambio de calidad productiva: el método `label` por defecto escribe `app.kubernetes.io/instance`, una etiqueta de 63 caracteres que colisiona con las convenciones de Helm/Kustomize y trunca nombres largos de Application, provocando **pruning mal atribuido**. El método `annotation` usa `argocd.argoproj.io/tracking-id`, sin restricción de longitud.

---

## 6. Secretos: la decisión de diseño inevitable

Git es público por defecto dentro de tu organización. Los manifiestos `Secret` en texto plano son una brecha, no un atajo.

| Enfoque | Dónde vive el texto cifrado | Dónde vive la clave | Rotación | Recuperación de emergencia | Compromiso |
|---|---|---|---|---|---|
| **SOPS + age/KMS** | En Git, cifrado por archivo y por clave | `Secret` del clúster (age) o KMS en la nube (IRSA/Workload Identity) | Re-cifrar archivos; la rotación de claves es un commit sobre todo el repo | Total: descifrar localmente con la clave | Diffeable por clave; el MAC cubre todo el archivo; nativo en Flux (`spec.decryption`) |
| **Sealed Secrets** | En Git, texto cifrado asimétrico | Clave privada del controlador, solo dentro del clúster | Re-sellar contra la nueva clave pública | Requiere haber respaldado la clave del controlador — **frecuentemente olvidado** | Atado a clúster y namespace por defecto; simple; el texto cifrado no es diffeable |
| **External Secrets Operator** | *Nada en Git* — Git guarda una referencia | Bóveda externa (AWS SM, Vault, GCP SM, Azure KV) | Rotar en la bóveda; el clúster lo toma en el `refreshInterval` | La bóveda es el sistema de registro | Agrega una dependencia en tiempo de ejecución; la objeción de la "pureza GitOps" — el estado deseado ahora es un puntero |
| **Vault Agent / driver CSI** | No está en Git | Vault | Nativa | Vault | Evita por completo los objetos `Secret`; el menos nativo de Kubernetes |

**Posición para el examen:** ninguno de estos viola GitOps. El principio 2 exige que el estado deseado esté *versionado y sea inmutable*; una *referencia* versionada a un secreto lo satisface. Lo que sí viola GitOps es un secreto que existe únicamente porque un humano ejecutó `kubectl create secret`.

### 6.1 SOPS con Flux

```bash
$ age-keygen -o age.agekey
Public key: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk

$ kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey=./age.agekey
secret/sops-age created

$ cat .sops.yaml
creation_rules:
  - path_regex: infra/configs/.*\.yaml$
    encrypted_regex: '^(data|stringData)$'
    age: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk

$ sops --encrypt --in-place infra/configs/checkout-db-secret.yaml
$ head -12 infra/configs/checkout-db-secret.yaml
apiVersion: v1
kind: Secret
metadata:
    name: checkout-db
    namespace: checkout
type: Opaque
stringData:
    url: ENC[AES256_GCM,data:h7Kc2Pq9wZ3nT1v...,iv:6bF2...,tag:9pQ...,type:str]
sops:
    age:
        - recipient: age1f8qmn3pkxhs8yqvzjhpq3v5s5rrqx5uzvxk2y8y6q3sqnp2zj4wsyz2pqk
```

Solo los *valores* están cifrados (`encrypted_regex`), así que `kind`, `name` y `namespace` siguen siendo revisables en un PR — por esto SOPS le gana al cifrado de archivo completo para GitOps.

### 6.2 External Secrets Operator

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: checkout-db
  namespace: checkout
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secretsmanager
  target:
    name: checkout-db
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: Opaque
      data:
        url: "postgres://{{ .username }}:{{ .password }}@checkout-db.prod.eu-west-1.rds.amazonaws.com:5432/checkout?sslmode=verify-full"
  data:
    - secretKey: username
      remoteRef:
        key: prod/checkout/db
        property: username
    - secretKey: password
      remoteRef:
        key: prod/checkout/db
        property: password
```

Agregá el `Secret` generado a `ignoreDifferences` / a las exclusiones de Flux; de lo contrario el reconciliador verá un objeto que no le pertenece y, con prune habilitado, puede borrarlo.

---

## 7. Entrega progresiva: cerrar el lazo con métricas

Un reconciliador converge hacia Git. **No** sabe si el estado convergido es *bueno*. La entrega progresiva agrega una compuerta de análisis.

| | **Argo Rollouts** | **Flagger** |
|---|---|---|
| Mecanismo | Reemplaza el `Deployment` por un CRD `Rollout` | Envuelve un `Deployment` existente, genera primary/canary |
| Estrategias | Canary, blue-green, con control fino de pasos | Canary, A/B, blue-green, mirroring |
| Proveedores de tráfico | Istio, Linkerd, SMI, NGINX, ALB, Gateway API, Traefik, Apache APISIX | El mismo conjunto, más Gateway API |
| Análisis | `AnalysisTemplate` → Prometheus, Datadog, NewRelic, CloudWatch, Job, Web | `MetricTemplate` → los mismos proveedores |
| Compuerta manual | `pause: {}` + `argo rollouts promote` | Compuertas por webhook / hook `confirm-rollout` de `flagger` |
| Fricción con GitOps | El churn de `spec.replicas`/status del objeto `Rollout` necesita `ignoreDifferences` | Flagger *crea* objetos `-primary` que el reconciliador no posee → deben excluirse del prune |
| Mejor encaje | Tiendas Argo CD; controlás el CRD de la carga de trabajo | Tiendas Flux; querés mantener `Deployment` plano en Git |

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout-api
  namespace: checkout
spec:
  replicas: 10
  strategy:
    canary:
      canaryService: checkout-api-canary
      stableService: checkout-api-stable
      trafficRouting:
        istio:
          virtualService:
            name: checkout-api
            routes: [primary]
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 2
        args:
          - name: service-name
            value: checkout-api-canary.checkout.svc.cluster.local
      steps:
        - setWeight: 5
        - pause: {duration: 5m}
        - setWeight: 20
        - pause: {duration: 10m}
        - setWeight: 50
        - pause: {duration: 10m}
        - setWeight: 100
  selector:
    matchLabels: {app: checkout-api}
  template:
    metadata:
      labels: {app: checkout-api}
    spec:
      containers:
        - name: api
          image: ghcr.io/acme/checkout:1.4.2
          resources:
            requests: {cpu: 250m, memory: 256Mi}
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: checkout
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            sum(irate(istio_requests_total{
              reporter="source",
              destination_service=~"{{args.service-name}}",
              response_code!~"5.."}[2m]))
            /
            sum(irate(istio_requests_total{
              reporter="source",
              destination_service=~"{{args.service-name}}"}[2m]))
    - name: p99-latency
      interval: 1m
      count: 5
      successCondition: result[0] <= 500
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{
              destination_service=~"{{args.service-name}}"}[2m])) by (le))
```

```bash
$ kubectl argo rollouts get rollout checkout-api -n checkout --watch
Name:            checkout-api
Namespace:       checkout
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/8
  SetWeight:     20
  ActualWeight:  20
Images:          ghcr.io/acme/checkout:1.4.1 (stable)
                 ghcr.io/acme/checkout:1.4.2 (canary)
Replicas:
  Desired:       10
  Current:       12
  Updated:       2
  Ready:         12
  Available:     12

NAME                                      KIND        STATUS     AGE  INFO
⟳ checkout-api                            Rollout     ॥ Paused   14d
├──# revision:12
│  ├──⧉ checkout-api-7c9d5f8b6d           ReplicaSet  ✔ Healthy  3m   canary
│  │  ├──□ checkout-api-7c9d5f8b6d-k2vqx  Pod         ✔ Running  3m   ready:2/2
│  │  └──□ checkout-api-7c9d5f8b6d-m8xlp  Pod         ✔ Running  3m   ready:2/2
│  └──α checkout-api-7c9d5f8b6d-2         AnalysisRun ✔ Successful 3m  ✔ 5
└──# revision:11
   └──⧉ checkout-api-5b8f4c2a19           ReplicaSet  ✔ Healthy  6d   stable
      └──□ (8 pods)                       Pod         ✔ Running  6d   ready:2/2
```

**Interacción con el reconciliador:** cuando el análisis falla, Rollouts escala el ReplicaSet canario a cero. Git sigue diciendo `1.4.2`. El reconciliador va a seguir re-aplicando `1.4.2` y Rollouts va a seguir abortando. **El rollback es un revert en Git, no una acción en el clúster** — esta es la disciplina operativa más importante de GitOps.

---

## 8. Escala y ajuste de rendimiento

### 8.1 Argo CD

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Application controller
  controller.status.processors: "50"
  controller.operation.processors: "25"
  controller.repo.server.timeout.seconds: "180"
  controller.sharding.algorithm: "consistent-hashing"
  controller.diff.server.side: "true"        # offload diff to repo-server
  # Repo server
  reposerver.parallelism.limit: "10"
  reposerver.git.request.timeout: "120s"
  # Server
  server.enable.gzip: "true"
  # Do not re-render on every status write of every resource
  resource.ignoreResourceUpdatesEnabled: "true"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: argocd-application-controller
  namespace: argocd
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: argocd-application-controller
          env:
            - name: ARGOCD_CONTROLLER_REPLICAS
              value: "3"
          resources:
            requests: {cpu: "2", memory: 4Gi}
            limits:   {memory: 8Gi}
```

| Síntoma a escala | Causa raíz | Remedio |
|---|---|---|
| La latencia de sincronización crece linealmente con la cantidad de apps | Un único shard de controlador | `ARGOCD_CONTROLLER_REPLICAS` > 1 + `consistent-hashing` |
| repo-server con OOMKilled | Charts de Helm / Jsonnet grandes renderizados concurrentemente | Subir el límite de memoria, bajar `reposerver.parallelism.limit`, habilitar TTL de caché de manifiestos |
| El proveedor de Git limita por rate a Argo CD | Cada Application sondea de forma independiente (3 min por defecto) | Webhook + subir `timeout.reconciliation` a 30m o más |
| Evicción de Redis → re-renderizado constante | `argocd-redis` subdimensionado | Desplegar `redis-ha`, dimensionar `maxmemory`, monitorear `argocd_redis_request_total{failed="true"}` |
| CPU del controlador clavada, sin sincronizaciones ocurriendo | Actualizaciones de status de CRDs con mucho churn inundando los informers | `resource.customizations.ignoreResourceUpdates.*` sobre `/status` |

### 8.2 Flux

```yaml
# Patch applied via clusters/<name>/flux-system/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: "(kustomize-controller|helm-controller|source-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --concurrent=8
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --kube-api-qps=500
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --kube-api-burst=1000
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --requeue-dependency=5s
  - target:
      kind: Deployment
      name: "(kustomize-controller|source-controller)"
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: 2Gi
```

Sharding (Flux 2.2+): etiquetá el Deployment de un controlador con `sharding.fluxcd.io/key: <shard>` y poné la etiqueta coincidente en los objetos que debe poseer. Los objetos sin la etiqueta van al shard por defecto.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 Escalera de triaje de Argo CD

```bash
$ argocd app list -o wide
NAME                        CLUSTER                   NAMESPACE  PROJECT          STATUS     HEALTH    SYNCPOLICY  CONDITIONS         REPO                                            PATH                            TARGET
argocd/platform-bootstrap   https://kubernetes...     argocd     platform         Synced     Healthy   Auto-Prune  <none>             https://github.com/acme/platform-gitops.git     clusters/prod-eu-west-1/apps    main
argocd/checkout             https://kubernetes...     checkout   tenant-checkout  OutOfSync  Degraded  Auto-Prune  SyncError          https://github.com/acme/checkout-gitops.git     envs/prod                       main
argocd/ingress-nginx        https://kubernetes...     ingress    platform         Synced     Healthy   Auto-Prune  <none>             https://acme.github.io/charts                   .                               4.12.1

$ argocd app get checkout --hard-refresh
Name:               argocd/checkout
Project:            tenant-checkout
Server:             https://kubernetes.default.svc
Namespace:          checkout
URL:                https://argocd.acme.io/applications/checkout
Repo:               https://github.com/acme/checkout-gitops.git
Target:             main
Path:               envs/prod
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune, SelfHeal)
Sync Status:        OutOfSync from main (9f3ac21)
Health Status:      Degraded

CONDITION  MESSAGE                                                                                   LAST TRANSITION
SyncError  one or more objects failed to apply, reason: Deployment.apps "checkout-api" is invalid:   2026-08-18T09:14:02Z
           spec.template.spec.containers[0].resources.requests: Invalid value: "250"

GROUP  KIND        NAMESPACE  NAME              STATUS     HEALTH     HOOK  MESSAGE
       Namespace   checkout   checkout          Synced
       Service     checkout   checkout-api      Synced     Healthy          service/checkout-api unchanged
apps   Deployment  checkout   checkout-api      OutOfSync  Degraded         Deployment.apps "checkout-api" is invalid
batch  Job         checkout   checkout-db-...   Synced     Succeeded  PreSync  job.batch/checkout-db-migrate created
```

```bash
$ argocd app diff checkout --hard-refresh
===== apps/Deployment checkout/checkout-api ======
6c6
<     image: ghcr.io/acme/checkout:1.4.1
---
>     image: ghcr.io/acme/checkout:1.4.2
14c14
<     replicas: 10
---
>     replicas: 6
```

Ese diff de `replicas` sobre una carga gestionada por HPA es la falsa deriva de manual → `ignoreDifferences` (§5.5).

**Renderizá localmente exactamente como lo haría el repo-server** — esto elimina el "funciona en mi máquina":

```bash
$ argocd app manifests checkout --source live   > /tmp/live.yaml
$ argocd app manifests checkout --source git    > /tmp/git.yaml
$ dyff between /tmp/live.yaml /tmp/git.yaml
```

Conflicto de server-side apply, el error de mayor señal en el Argo CD moderno:

```bash
$ argocd app sync checkout
FATA[0004] rpc error: code = Unknown desc = Apply error: 
Deployment.apps "checkout-api" is invalid: 
Apply failed with 1 conflict: conflict with "kube-controller-manager" using apps/v1:
  .spec.replicas
```

Resolución — decidí quién es el dueño, y después codificá la decisión:

| Decisión | Acción |
|---|---|
| Git es dueño de `replicas` (sin HPA) | `syncOptions: [ServerSideApply=true, Force=true]` o eliminar el HPA |
| El HPA es dueño de `replicas` | Quitar `replicas` del manifiesto **y** agregar `ignoreDifferences` + `RespectIgnoreDifferences=true` |

### 9.2 Escalera de triaje de Flux

```bash
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.6.4
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
► ghcr.io/fluxcd/helm-controller:v1.3.0
✔ kustomize-controller: deployment ready
► ghcr.io/fluxcd/kustomize-controller:v1.6.1
✔ notification-controller: deployment ready
► ghcr.io/fluxcd/notification-controller:v1.6.0
✔ source-controller: deployment ready
► ghcr.io/fluxcd/source-controller:v1.6.2
► checking crds
✔ alerts.notification.toolkit.fluxcd.io/v1beta3
✔ buckets.source.toolkit.fluxcd.io/v1
✔ gitrepositories.source.toolkit.fluxcd.io/v1
✔ helmreleases.helm.toolkit.fluxcd.io/v2
✔ kustomizations.kustomize.toolkit.fluxcd.io/v1
✔ all checks passed

$ flux get all -A
NAMESPACE       NAME                            REVISION                SUSPENDED  READY  MESSAGE
flux-system     gitrepository/flux-system       main@sha1:9f3ac21       False      True   stored artifact for revision 'main@sha1:9f3ac21'

NAMESPACE       NAME                            REVISION                SUSPENDED  READY  MESSAGE
flux-system     kustomization/flux-system       main@sha1:9f3ac21       False      True   Applied revision: main@sha1:9f3ac21
flux-system     kustomization/infra-controllers main@sha1:9f3ac21       False      True   Applied revision: main@sha1:9f3ac21
flux-system     kustomization/infra-configs     main@sha1:7f3ac21       False      False  Kustomization/flux-system/infra-configs dry-run failed: error validating data: ValidationError(ClusterIssuer.spec.acme): unknown field "sever"
flux-system     kustomization/tenants           main@sha1:7f3ac21       False      False  dependency 'flux-system/infra-configs' is not ready
```

Notá la propagación: `tenants` no está roto — está **negándose correctamente a continuar** porque se declaró `dependsOn`. Esa es la garantía de ordenamiento funcionando.

```bash
# Where did this live object come from? The GitOps provenance question.
$ flux trace deployment/checkout-api -n checkout
Object:         Deployment/checkout-api
Namespace:      checkout
Status:         Managed by Flux
---
Kustomization:  tenants
Namespace:      flux-system
Path:           ./tenants/prod
Revision:       main@sha1:9f3ac21
Status:         Last reconciled at 2026-08-18 09:12:41 +0200 CEST
Message:        Applied revision: main@sha1:9f3ac21
---
GitRepository:  flux-system
Namespace:      flux-system
URL:            ssh://git@github.com/acme/platform-gitops
Branch:         main
Revision:       main@sha1:9f3ac21
Status:         Last reconciled at 2026-08-18 09:12:38 +0200 CEST
Message:        stored artifact for revision 'main@sha1:9f3ac21'

# Preview server-side what a commit will change, before merging.
$ flux diff kustomization tenants --path ./tenants/prod
✚ Deployment/checkout/checkout-worker created
► Deployment/checkout/checkout-api drifted
@@ -28,7 +28,7 @@
       containers:
       - name: api
-        image: ghcr.io/acme/checkout:1.4.1
+        image: ghcr.io/acme/checkout:1.4.2

# Full ownership tree with the inventory used for pruning.
$ flux tree kustomization tenants --namespace flux-system
Kustomization/flux-system/tenants
├── Namespace/checkout
├── ServiceAccount/checkout/checkout-api
├── Service/checkout/checkout-api
├── Deployment/checkout/checkout-api
├── Deployment/checkout/checkout-worker
└── HorizontalPodAutoscaler/checkout/checkout-api

# Force an immediate cycle down the whole chain.
$ flux reconcile kustomization tenants --with-source
► annotating GitRepository flux-system in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:9f3ac21
► annotating Kustomization tenants in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ Kustomization reconciliation completed
✔ applied revision main@sha1:9f3ac21
```

Los logs de los controladores son JSON estructurado — filtrá por objeto:

```bash
$ kubectl -n flux-system logs deploy/kustomize-controller --tail=200 \
    | jq -r 'select(.level=="error") | "\(.ts) \(.name) \(.msg)"'
2026-08-18T09:11:04.882Z infra-configs Reconciliation failed after 1.4s, next try in 2m0s
2026-08-18T09:13:06.118Z infra-configs server-side apply dry-run failed: admission webhook "validate.kyverno.svc-fail" denied the request
```

### 9.3 Catálogo de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| App perpetuamente `OutOfSync`, sin diff visible | Campo escrito por otro controlador o con valor por defecto | `argocd app diff --hard-refresh`; `kubectl get -o yaml \| grep managedFields -A20` | `ignoreDifferences` + `RespectIgnoreDifferences=true` |
| `ComparisonError: rpc error … repository not accessible` | Deploy key rotada/revocada; repo movido; CA privada | `kubectl -n argocd logs deploy/argocd-repo-server`; `flux get sources git` | Recrear el `Secret` de credenciales; agregar el bundle de CA a `argocd-tls-certs-cm` / `GitRepository.spec.secretRef` |
| `SharedResourceWarning` / dos apps se pelean por un objeto | `path`s superpuestos, o un chart que incluye un CRD compartido | `argocd app resources <app>` en ambas | Agregar `FailOnSharedResource=true`; mover el objeto compartido a su propia Application/Kustomization en una wave anterior |
| La sincronización tiene éxito, la carga nunca queda Ready | La evaluación de health pasa pero las probes fallan | `kubectl describe pod`; `kubectl get events --sort-by=.lastTimestamp` | Bug real — el reconciliador está en lo correcto. Revertí el commit. |
| Prune borró un recurso que nadie esperaba | Colisión de la etiqueta de rastreo, u objeto quitado de Git por una refactorización no relacionada | `argocd app history`; `git log -p -- <path>` | Cambiar a `resourceTrackingMethod: annotation`; habilitar `PruneLast=true`; `Prune=confirm` para recursos con alcance de clúster |
| `Kustomization` de Flux trabada en `Progressing` para siempre | `wait: true` + un objetivo de `healthChecks` que nunca queda listo | `flux get kustomizations`; `flux logs --kind=Kustomization --name=<n>` | Arreglar la carga de trabajo, o poner un `timeout` para que falle ruidosamente en vez de colgarse |
| `HelmRelease` con `upgrade retries exhausted` | Cambio de un campo inmutable (p. ej. `Service.spec.clusterIP`, `volumeClaimTemplates` de un StatefulSet) | `helm history <rel> -n <ns>`; logs del controlador | `upgrade.force: true` (recrea), o un plan de migración — nunca forzar a ciegas un StatefulSet |
| CRs aplicados antes de que exista su CRD | Sin ordenamiento declarado | Error de sincronización `no matches for kind` | Argo CD: `sync-wave: "-1"` en los CRDs + `SkipDryRunOnMissingResource=true`. Flux: dividir en dos `Kustomization`s con `dependsOn` |
| El proveedor de Git devuelve HTTP 429 | Cada Application/GitRepository sondea de forma independiente | Log de auditoría del proveedor; `argocd_git_request_total` | `Receiver` de webhook + aumentar los intervalos; consolidar en un único `GitRepository` |
| Cambio mergeado, no pasa nada | `suspend: true`, ventana de sincronización de tipo deny activa, o `automated` ausente | `flux get kustomizations` (columna SUSPENDED); `argocd app get` (línea SyncWindow) | `flux resume`; ajustar `syncWindows` |
| El self-heal pelea contra un operator legítimo | El operator escribe en un campo que Git también declara | Inspección de `managedFields` | Quitar el campo de Git; el operator es el dueño |
| ApplicationSet borró toda la flota | El generador devolvió una lista vacía/corta (path incorrecto, error de API) | `argocd appset get <name>`; logs del controlador | `applicationsSync: create-update`, `preserveResourcesOnDeletion: true`, y nunca `allowEmpty: true` en la raíz |

### 9.4 Observabilidad — las cuatro señales que importan

| Señal | Métrica de Argo CD | Métrica de Flux |
|---|---|---|
| **Estado de deriva / sincronización** | `argocd_app_info{sync_status="OutOfSync"}` | `gotk_reconcile_condition{type="Ready",status="False"}` |
| **Latencia de reconciliación** | `argocd_app_reconcile_bucket` | `gotk_reconcile_duration_seconds_bucket` |
| **Fallo al obtener el origen** | `argocd_git_request_total{request_type="ls-remote"}` | `gotk_reconcile_condition{kind="GitRepository",status="False"}` |
| **Suspendido / silenciado** | `argocd_app_info{sync_policy="<none>"}` | `gotk_suspend_status == 1` |

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-slo
  namespace: monitoring
spec:
  groups:
    - name: gitops.rules
      rules:
        - alert: GitOpsDriftUnresolved
          expr: |
            sum by (name, namespace, dest_namespace) (
              argocd_app_info{sync_status="OutOfSync"}
            ) > 0
          for: 15m
          labels: {severity: warning}
          annotations:
            summary: "Application {{ $labels.name }} has been OutOfSync for 15m"
            description: "Self-heal is failing or disabled. Reconciliation is not converging."
        - alert: GitOpsReconcilerBlind
          expr: |
            sum by (kind, name, exported_namespace) (
              gotk_reconcile_condition{type="Ready",status="False"}
            ) > 0
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: "Flux {{ $labels.kind }}/{{ $labels.name }} not Ready for 10m"
        - alert: GitOpsSuspendedTooLong
          expr: gotk_suspend_status == 1
          for: 24h
          labels: {severity: warning}
          annotations:
            summary: "{{ $labels.kind }}/{{ $labels.name }} suspended >24h — Git is no longer the source of truth"
        - alert: GitOpsSourceStale
          expr: |
            time() - argocd_app_info * on() group_left()
              max(argocd_app_reconcile_sum) by (name) > 1800
          for: 10m
          labels: {severity: critical}
          annotations:
            summary: "Argo CD has not reconciled {{ $labels.name }} in 30m"
```

La alerta que la mayoría de los equipos olvida es **`GitOpsSuspendedTooLong`**. Un reconciliador suspendido es indistinguible de uno sano en cualquier otro tablero, y convierte silenciosamente tu plataforma GitOps de vuelta en un pipeline de push.

### 9.5 La lista de verificación para un clúster nuevo

```bash
# 1. The agent reconciles itself
$ flux get kustomization flux-system
NAME         REVISION            SUSPENDED  READY  MESSAGE
flux-system  main@sha1:9f3ac21   False      True   Applied revision: main@sha1:9f3ac21

# 2. Drift is actually remediated — inject drift, measure recovery
$ kubectl -n checkout scale deploy/checkout-api --replicas=1
deployment.apps/checkout-api scaled
$ sleep 60 && kubectl -n checkout get deploy checkout-api -o jsonpath='{.spec.replicas}{"\n"}'
6

# 3. Deletion is remediated too
$ kubectl -n checkout delete svc checkout-api
service "checkout-api" deleted
$ sleep 60 && kubectl -n checkout get svc checkout-api
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
checkout-api   ClusterIP   10.100.42.117   <none>        8080/TCP  47s

# 4. Prune works — remove from Git, confirm removal from cluster
# 5. Nothing in the cluster is unmanaged
$ kubectl get all -n checkout -o json \
  | jq -r '.items[] | select(.metadata.annotations["kustomize.toolkit.fluxcd.io/name"] == null
           and .metadata.labels["app.kubernetes.io/managed-by"] != "Helm")
           | "\(.kind)/\(.metadata.name)"'
(empty output = fully managed)

# 6. The bootstrap credential is not a human's PAT
$ kubectl -n flux-system get secret flux-system -o jsonpath='{.data}' | jq 'keys'
[ "identity", "identity.pub", "known_hosts" ]
```

Una implementación de GitOps que falla las pruebas 2, 3 o 5 es **despliegue continuo desde Git**, no GitOps. Esa distinción es exactamente lo que evalúa el examen.

---

## 10. Referencias

- CNCF CGOA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- OpenGitOps — Principles v1.0.0 — https://opengitops.dev/
- OpenGitOps — Glossary and Principles (repository) — https://github.com/open-gitops/documents
- Argo CD documentation — https://argo-cd.readthedocs.io/en/stable/
- Argo CD — Sync Options — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Argo CD — Resource Hooks and Sync Waves — https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- Argo CD — Diffing customization — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Argo CD — ApplicationSet controller — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- Argo CD — High Availability and scaling — https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/
- Argo CD — Projects (`AppProject`) — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Argo Rollouts — https://argo-rollouts.readthedocs.io/en/stable/
- Flux documentation — https://fluxcd.io/flux/
- Flux — Bootstrap — https://fluxcd.io/flux/installation/bootstrap/
- Flux — Kustomization API — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux — HelmRelease API — https://fluxcd.io/flux/components/helm/helmreleases/
- Flux — GitRepository API — https://fluxcd.io/flux/components/source/gitrepositories/
- Flux — OCIRepository API — https://fluxcd.io/flux/components/source/ocirepositories/
- Flux — Image update automation — https://fluxcd.io/flux/guides/image-update/
- Flux — Multi-tenancy lockdown — https://fluxcd.io/flux/installation/configuration/multitenancy/
- Flux — Manage Kubernetes secrets with SOPS — https://fluxcd.io/flux/guides/mozilla-sops/
- Flux — Monitoring and metrics — https://fluxcd.io/flux/monitoring/metrics/
- Flagger — https://fluxcd.io/flagger/
- Kubernetes — Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Declarative management with Kustomize — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- SOPS — https://github.com/getsops/sops
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- External Secrets Operator — https://external-secrets.io/latest/
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- CNCF Landscape, Continuous Delivery / GitOps category — https://landscape.cncf.io/