# 6.2 PolicyExceptions

**Peso en el examen: 3.33** · Superficie de API: `kyverno.io/v2`, `kind: PolicyException` (nombre corto `polex`)

---

## 1. El problema arquitectónico

Un motor de políticas solo se adopta si se puede operar. El modo de falla que mata los despliegues de Kyverno no es una funcionalidad faltante — es la **cola de pedidos de excepción**.

El estado estable se ve así. El equipo de plataforma es dueño de un conjunto de objetos `ClusterPolicy`: `disallow-privileged-containers`, `disallow-host-path`, `restrict-image-registries`, `require-run-as-nonroot`. Son de alcance de clúster, aplican a todos los namespaces y se reconcilian desde un repositorio Git que controla el equipo de plataforma. Después llega la realidad:

- El GPU operator necesita `privileged: true` para cargar módulos del kernel.
- El log shipper de nodo necesita `hostPath: /var/log/pods`.
- Una imagen de un proveedor legacy solo se publica en `quay.io/vendor` y tu lista de registries permitidos es `registry.internal.example.com/*`.
- Un batch job en `data-eng` corre un contenedor que genuinamente necesita `CAP_SYS_NICE`.

Cada uno de estos es un exención legítima, revisada y aprobada por el negocio. La pregunta es *dónde queda escrita esa exención*.

### Los tres antipatrones

**Antipatrón 1 — editar la política.** El movimiento obvio es agregar un bloque `exclude` al `ClusterPolicy`:

```yaml
  rules:
  - name: host-path
    match:
      any:
      - resources:
          kinds: [Pod]
    exclude:
      any:
      - resources:
          namespaces: [observability, gpu-operator, data-eng, legacy-erp]
```

Esto funciona, y está mal a escala por cuatro razones:

1. **Radio de impacto.** El objeto de exclusión *es* el objeto de enforcement. Un error de tipeo en el bloque `exclude` — un `*` perdido, una indentación equivocada que promueve `exclude` un nivel — deshabilita silenciosamente la regla en todo el clúster. No hay unidad de falla más chica que "toda la política".
2. **Inversión de propiedad.** El equipo que necesita la exención no puede hacer el cambio; lo tiene que hacer el equipo de plataforma. Cada exención se convierte en un pull request contra un repositorio en el que el equipo solicitante no tiene permiso de escritura, revisado por gente que no sabe por qué hace falta `/var/log/pods`. La cola crece, y con ella la presión para mergear sin revisar.
3. **Sin ciclo de vida.** `namespaces: [legacy-erp]` no tiene vencimiento, ni dueño, ni ticket. Tres años después nadie sabe si `legacy-erp` todavía existe, y borrar la entrada es un riesgo que nadie quiere tomar. Las listas de exclusión crecen monótonamente.
4. **Granularidad gruesa.** Excluir el namespace exime a *toda* carga de trabajo que haya en él, para siempre, incluidas las que se desplieguen el trimestre que viene. Querías eximir un DaemonSet; eximiste un namespace.

**Antipatrón 2 — el fork de la política.** Copiar el `ClusterPolicy` a un `Policy` con namespace y sacarle la regla molesta, y excluir el namespace de la política de clúster. Ahora tenés dos copias divergentes de la misma intención, y la próxima actualización upstream de la política parchea una sola de ellas.

**Antipatrón 3 — pasar la regla a Audit.** Poner la acción de falla en `Audit` para ese namespace. La regla deja de bloquear *todo* en el namespace, no solo la carga de trabajo justificada, y el reporte se llena de resultados `fail` que nadie tría.

### Qué cambia `PolicyException`

`PolicyException` es un **objeto de Kubernetes separado y con namespace, que nombra la política y la regla que exime, y los recursos que la exención cubre**. Invierte la propiedad: la política queda intacta y en manos de plataforma; la excepción es un objeto de primera clase que puede vivir en el namespace del equipo de aplicación, en el repositorio Git del equipo de aplicación, bajo el RBAC del equipo de aplicación — mientras el *permiso para crear una* sigue siendo una concesión controlada por plataforma.

Eso te da las cuatro propiedades que a los antipatrones les faltan:

| Propiedad | Mecanismo |
|---|---|
| Radio de impacto acotado | Una excepción malformada no exime nada; no puede deshabilitar una regla que no nombra |
| Delegable | RBAC sobre un CRD con namespace, no permiso de escritura sobre el repo de políticas |
| Auditable | `kubectl get polex -A` es la lista completa y consultable de cada exención del clúster |
| Con vencimiento | Es un objeto de Kubernetes — acepta labels, annotations, owner references y el `cleanup.kyverno.io/ttl` de Kyverno |

Y algo crítico: **un recurso eximido se reporta como `skip`, no como `pass`.** La exención queda visible en el policy report para siempre. Nunca perdés la señal de que un control no se aplicó.

---

## 2. Elegir un mecanismo de exclusión

Kyverno ofrece varias maneras de no-hacer-cumplir algo. No son intercambiables. Esta tabla es la superficie de decisión.

| Mecanismo | Objeto editado | Propiedad de | Granularidad | Visible en reportes | Con vencimiento | Sobrevive a una actualización de política | Usar cuando |
|---|---|---|---|---|---|---|---|
| Bloque `rule.exclude` | La política misma | Plataforma | Namespace / kind / selector | No — el recurso ni siquiera se evalúa | No | Conflicto de merge en cada bump upstream | La exclusión es **estructural y permanente** (p. ej. nunca evaluar `kube-system`) |
| Label de namespace + `namespaceSelector` en `match` | Política + namespace | Plataforma + dueño del ns | Namespace entero | No | No | Sí | Segmentar namespaces por niveles (`security-tier: baseline` vs `restricted`) |
| `validate.failureActionOverrides` | La política misma | Plataforma | Namespace | Sí, como `fail`/`warn` | No | Conflicto de merge | **Rampas de despliegue** — auditar una política nueva en prod mientras se hace cumplir en staging |
| Fork a `Policy` con namespace | Objeto de política nuevo | Quien lo forkeó | Política entera | Sí | No | No — diverge silenciosamente | Casi nunca |
| `resourceFilters` en el ConfigMap `kyverno` | Configuración de Kyverno | Plataforma | Nivel de webhook, en todo el clúster | **No — Kyverno nunca ve el recurso** | No | Sí | Excluir el propio namespace de Kyverno y componentes de sistema; triaje de rendimiento |
| **`PolicyException`** | **Objeto nuevo y separado** | **Equipo de aplicación, bajo RBAC de plataforma** | **Regla + kind + nombre/selector + control PSS + condiciones estilo CEL** | **Sí, como `skip`** | **Sí (`cleanup.kyverno.io/ttl`)** | **Sí — desacoplado de la política** | **Una exención específica, justificada y revisable a nivel de carga de trabajo** |

### Contraste con las exenciones de Pod Security Admission de upstream

El temario de KCA pone a Kyverno al lado del controlador de admisión Pod Security incorporado. Vale la pena comparar sus modelos de exención directamente, porque explican *por qué existe un motor de políticas*:

| | `exemptions` de PSA | `PolicyException` de Kyverno |
|---|---|---|
| Dónde se configura | Archivo `AdmissionConfiguration` en el **API server** | Un CRD dentro del clúster |
| Quién lo puede cambiar | Quien pueda editar la configuración estática del plano de control (proveedor cloud: a menudo nadie) | Cualquiera con RBAC sobre `policyexceptions` en un namespace |
| Propagación del cambio | Reinicio del API server / relectura de la configuración de admisión | Inmediata, vía watch |
| Dimensiones de exención | `usernames`, `runtimeClasses`, `namespaces` — nada más | política, regla, kind, glob de nombre, selector de labels, subject/role, condiciones JMESPath, control PSS individual, patrón de imagen |
| Piso de granularidad | Namespace entero | Un control, sobre un patrón de imagen, en una carga de trabajo |
| Auditabilidad | Leer un archivo en el plano de control | `kubectl get polex -A`, más una línea `skip` en cada PolicyReport afectado |
| Apto para GitOps | Rara vez | Nativamente |

PSA no puede expresar "este DaemonSet puede montar `/var/log/pods`, y nada más en el namespace puede montar nada". `PolicyException` sí.

---

## 3. Anatomía del CRD

Antes de escribir YAML contra cualquier versión, leé el esquema que el clúster realmente sirve. Esto no es ceremonia opcional — el esquema de `PolicyException` pasó por `v2alpha1` → `v2beta1` → `v2` y en cada paso se agregaron campos.

```console
$ kubectl api-resources --api-group=kyverno.io
NAME                     SHORTNAMES   APIVERSION             NAMESPACED   KIND
cleanuppolicies          cleanpol     kyverno.io/v2          true         CleanupPolicy
clustercleanuppolicies   ccleanpol    kyverno.io/v2          false        ClusterCleanupPolicy
clusterpolicies          cpol         kyverno.io/v1          false        ClusterPolicy
globalcontextentries     gctxentry    kyverno.io/v2alpha1    false        GlobalContextEntry
policies                 pol          kyverno.io/v1          true         Policy
policyexceptions         polex        kyverno.io/v2          true         PolicyException
updaterequests           ur           kyverno.io/v2          true         UpdateRequest
```

```console
$ kubectl explain polex.spec
GROUP:      kyverno.io
KIND:       PolicyException
VERSION:    v2

FIELD: spec <Object>

DESCRIPTION:
    Spec declares policy exception behaviors.

FIELDS:
  background    <boolean>
  conditions    <Object>
  exceptions    <[]Object>
  match         <Object>
  podSecurity   <[]Object>
```

Si `conditions` o `podSecurity` no aparecen en esa salida, tu Kyverno es anterior a ellos — los manifiestos de §7 y §8 los va a rechazar el API server, no los va a ignorar en silencio.

### Los cinco campos

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: <exception-name>
  namespace: <where-the-object-lives>
spec:
  # 1. Does this exception also apply during background scans (reports),
  #    or only at admission time? Default: true.
  background: true

  # 2. WHICH RESOURCES are exempted. Same schema as a policy match block.
  match:
    any:
    - resources:
        kinds:      [Pod, DaemonSet]
        namespaces: [observability]
        names:      ["node-log-shipper*"]
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
        operations:  [CREATE, UPDATE]

  # 3. WHICH POLICY RULES are skipped for those resources.
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path

  # 4. OPTIONAL extra guard: the exception only fires when these hold.
  conditions:
    all:
    - key:      "{{ ... }}"
      operator: AnyIn
      value:    [ ... ]

  # 5. OPTIONAL surgical mode for Pod Security Standards rules:
  #    remove ONE control from evaluation instead of skipping the whole rule.
  podSecurity:
  - controlName: HostPath Volumes
    images:      ["ghcr.io/example/log-shipper:*"]
```

Tres semánticas que deciden si tu excepción funciona:

- **`match` es autoritativo, `metadata.namespace` no.** El namespace donde vive el objeto determina *quién puede crearlo* (RBAC) — no, por sí mismo, qué recursos cubre. Eso lo decide `spec.match`. A menos que lo restrinjas (§9), un `PolicyException` creado en `team-a` puede nombrar `namespaces: [kube-system]`. Este es el hecho de gobernanza más importante sobre el CRD.
- **`exceptions[].ruleNames` tiene que coincidir con el nombre de regla que Kyverno realmente evaluó**, que para los controladores de cargas de trabajo es un nombre autogenerado, no el que figura en el fuente de la política (§6).
- **Una excepción es un skip, no un pass.** La regla no corre. Si la regla además hacía algo útil — una mutación, una verificación de imagen — eso también se saltea.

---

## 4. De punta a punta: el DaemonSet bloqueado

El escenario de producción completo. Plataforma hace cumplir el control de *baseline* de Pod Security sobre volúmenes `hostPath`; observability necesita leer los logs del nodo.

### 4.1 La política (propiedad de plataforma, intacta de acá en adelante)

`policies/disallow-host-path.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
  annotations:
    policies.kyverno.io/title: Disallow hostPath
    policies.kyverno.io/category: Pod Security Standards (Baseline)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod,Volume
    policies.kyverno.io/description: >-
      HostPath volumes let Pods access the host filesystem, which is a
      container-escape and data-exfiltration primitive. Mounting a host path
      also couples the workload to node layout. This policy forbids all
      hostPath volumes; justified uses are granted via PolicyException.
spec:
  background: true
  rules:
  - name: host-path
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      failureAction: Enforce
      allowExistingViolations: true
      message: >-
        HostPath volumes are forbidden. The field spec.volumes[*].hostPath
        must be unset. Request an exemption with a PolicyException.
      pattern:
        spec:
          =(volumes):
          - X(hostPath): "null"
```

> En Kyverno anterior a 1.13, `validate.failureAction` no existe: usá `spec.validationFailureAction: Enforce` a nivel de política en su lugar. Verificá qué forma acepta tu clúster con `kubectl explain cpol.spec.rules.validate.failureAction`.

```console
$ kubectl apply -f policies/disallow-host-path.yaml
clusterpolicy.kyverno.io/disallow-host-path created

$ kubectl get cpol disallow-host-path
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    9s    Ready
```

`READY=True` significa que la configuración del webhook convergió. Una política atascada en `False` todavía no está haciendo cumplir nada — revisalo antes de concluir que una excepción "funcionó".

### 4.2 La carga de trabajo que hay que eximir

`workloads/node-log-shipper.yaml`:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-log-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: node-log-shipper
    app.kubernetes.io/component: logging
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-log-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-log-shipper
        app.kubernetes.io/component: logging
    spec:
      serviceAccountName: node-log-shipper
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
      securityContext:
        runAsNonRoot: false
        runAsUser: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: shipper
        image: ghcr.io/example/log-shipper:2.9.1
        args:
        - --input=/var/log/pods
        - --output=otlp://otel-collector.observability.svc:4317
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
            add: ["DAC_READ_SEARCH"]
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi
        volumeMounts:
        - name: podlogs
          mountPath: /var/log/pods
          readOnly: true
        - name: state
          mountPath: /var/lib/log-shipper
      volumes:
      - name: podlogs
        hostPath:
          path: /var/log/pods
          type: Directory
      - name: state
        emptyDir: {}
```

```console
$ kubectl apply -f workloads/node-log-shipper.yaml
Error from server: error when creating "workloads/node-log-shipper.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource DaemonSet/observability/node-log-shipper was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.
    rule autogen-host-path failed at path /spec/template/spec/volumes/0/hostPath/'
```

**Leé ese mensaje de denegación como un diagnóstico, porque lo es.** Te entrega las dos cadenas que necesitás para la excepción:

- `disallow-host-path` → `spec.exceptions[].policyName`
- `autogen-host-path` → `spec.exceptions[].ruleNames[]` — *no* `host-path`, que es lo que dice el fuente de la política

### 4.3 La excepción

`exceptions/allow-hostpath-log-shipper.yaml`:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-hostpath-log-shipper
  namespace: observability
  labels:
    cleanup.kyverno.io/ttl: 90d
    exceptions.platform.example.com/risk: medium
  annotations:
    exceptions.platform.example.com/owner: observability-sre@example.com
    exceptions.platform.example.com/ticket: PLAT-4471
    exceptions.platform.example.com/approved-by: security-review-board
    exceptions.platform.example.com/justification: >-
      The log shipper reads container stdout/stderr from /var/log/pods on the
      node. The mount is readOnly, the container drops ALL capabilities except
      DAC_READ_SEARCH, and the root filesystem is read-only. Removal is tracked
      in PLAT-4620 (migration to the Kubernetes node log API, Q4).
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - DaemonSet
        - Pod
        namespaces:
        - observability
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
```

Dos decisiones de diseño que vale la pena defender en una revisión:

- **Ambos `kinds` y ambos `ruleNames`.** El DaemonSet lo valida `autogen-host-path`. Los Pods que el controlador de DaemonSet crea después se validan *por separado*, como `Pod`, con `host-path`. Eximir solo el DaemonSet produce el peor resultado posible: el DaemonSet se admite, después cada Pod que genera es rechazado, y la carga de trabajo nunca corre mientras el objeto existe y parece sano.
- **`selector.matchLabels`, no `names: ["node-log-shipper*"]`.** Un glob de nombre se compara contra el nombre *solicitado*, que controla cualquiera con permisos de creación en el namespace; `node-log-shipper-evil` coincide con el glob. Los selectores de labels también los controla el equipo, pero fuerzan una declaración explícita y grepeable en la carga de trabajo. Donde el riesgo es alto, agregá un bloque `conditions` (§7) para que la exención quede atada al valor real de hostPath y no a quién escribió el manifiesto.

```console
$ kubectl apply -f exceptions/allow-hostpath-log-shipper.yaml
policyexception.kyverno.io/allow-hostpath-log-shipper created

$ kubectl -n observability get polex
NAME                         AGE
allow-hostpath-log-shipper   6s

$ kubectl apply -f workloads/node-log-shipper.yaml
daemonset.apps/node-log-shipper created

$ kubectl -n observability rollout status ds/node-log-shipper
daemon set "node-log-shipper" successfully rolled out
```

### 4.4 Probar que la exención queda registrada, no escondida

Este es el paso que separa un `PolicyException` de un bloque `exclude`. El control no se aplicó, y el clúster lo dice:

```console
$ kubectl -n observability get policyreport
NAME                                   KIND        NAME                     PASS   FAIL   WARN   ERROR   SKIP   AGE
1a4f0a6f-4c7b-4a5f-9a0e-2f7c9f1a3b21   DaemonSet   node-log-shipper            3      0      0       0      1     47s
7c2d9e10-8ab3-41d2-b6f4-0d1e5c8a9b33   Pod         node-log-shipper-4nrqx      3      0      0       0      1     44s
6b1c8f27-1de4-4a0b-9c22-5f3a7d2e4c19   Pod         node-log-shipper-hs8lp      3      0      0       0      1     44s
```

```console
$ kubectl -n observability get polr -o json | jq -r '
    .items[].results[]
    | select(.result=="skip")
    | [.policy, .rule, .result, .message] | @tsv'
disallow-host-path	autogen-host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
disallow-host-path	host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
disallow-host-path	host-path	skip	rule is skipped due to policy exception observability/allow-hostpath-log-shipper
```

> En las herramientas, compará contra `result == "skip"`, nunca contra la cadena del mensaje — la redacción del mensaje de skip no es API y cambia entre releases menores. El campo `result` es estable, lo define el esquema de reportes del Policy WG de Kubernetes, y es sobre lo que tus dashboards deberían apoyarse.

La consulta de auditoría que responde "qué no se está haciendo cumplir en este clúster, y quién es el dueño":

```console
$ kubectl get polex -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TTL:.metadata.labels.cleanup\.kyverno\.io/ttl,OWNER:.metadata.annotations.exceptions\.platform\.example\.com/owner,TICKET:.metadata.annotations.exceptions\.platform\.example\.com/ticket,POLICIES:.spec.exceptions[*].policyName'
NS              NAME                          TTL   OWNER                              TICKET      POLICIES
gpu-operator    gpu-driver-privileged         30d   platform-gpu@example.com           PLAT-4390   disallow-privileged-containers
observability   allow-hostpath-log-shipper    90d   observability-sre@example.com      PLAT-4471   disallow-host-path
data-eng        spark-sys-nice                60d   data-platform@example.com          DATA-1182   restrict-capabilities
```

Esa tabla es el entregable que pide un auditor. Con bloques `exclude` no existe.

---

## 5. Habilitar y confinar la funcionalidad

`PolicyException` está detrás de un flag del controlador. En un clúster donde está apagado, aplicar una excepción falla en el API server (el CRD puede estar instalado igual por el chart) o la excepción se acepta y se ignora en silencio — ambas cosas se observaron entre releases, y por eso se verifica en vez de asumir.

```console
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kyverno")].args}' \
  | tr ',' '\n' | tr -d '[]"' | grep -i -E 'exception|enablePolicy'
--enablePolicyException=true
--exceptionNamespace=
```

Interpretación:

| Salida | Significado |
|---|---|
| `--enablePolicyException=true` | Las excepciones se respetan |
| `--enablePolicyException=false`, o el flag ausente en un release donde por defecto está apagado | Las excepciones se ignoran — el CRD puede existir y aceptar escrituras, y no va a pasar nada |
| `--exceptionNamespace=` (vacío) | Una excepción se respeta **en cualquier namespace** |
| `--exceptionNamespace=platform-exceptions` | Solo se respetan las excepciones que viven en `platform-exceptions`; todas las demás son inertes |

Valores de Helm que producen esos flags:

```yaml
# values.yaml
features:
  policyExceptions:
    enabled: true
    # Empty string = accept exceptions from any namespace (self-service model).
    # Set to a single namespace to centralise them (gatekeeping model).
    namespace: ""
```

```console
$ helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.x.x \
    --set features.policyExceptions.enabled=true \
    --set features.policyExceptions.namespace="" \
    --wait
```

### Los dos modelos operativos

| | Autoservicio (`namespace: ""`) | Centralizado (`namespace: platform-exceptions`) |
|---|---|---|
| Dónde viven las excepciones | Namespaces de los equipos, en los repos Git de los equipos | Un namespace, en el repo de plataforma |
| Quién aprueba | Concesión de RBAC + meta-política (§9) | Revisión humana en un PR |
| Latencia para eximir | Minutos | Días |
| Riesgo | Una concesión demasiado amplia se convierte en un bypass de autoservicio | Backlog en la cola de excepciones; los equipos esquivan el motor de políticas |
| Alcance entre namespaces | Debe restringirse con una meta-política | Centralizado estructuralmente, pero igual requiere revisar el `match` |
| Recomendado para | Plataformas maduras con los controles de §9 implementados | Despliegues nuevos, entornos regulados, cualquier clúster sin meta-política |

**Empezá centralizado. Pasá a autoservicio solo cuando los controles de §9 estén implementados y probados.** Un modelo de autoservicio sin meta-política es un bypass de política de seguridad a nivel de clúster concedido a cada admin de namespace.

Los propios controladores de Kyverno también necesitan acceso de lectura al CRD. Si instalás con un conjunto de RBAC escrito a mano en vez del chart, y los controladores de admisión, background y reportes no pueden hacer `list`/`watch` sobre `policyexceptions`, las excepciones aplican en admisión pero no en los reportes, o directamente no aplican:

```console
$ kubectl auth can-i list policyexceptions.kyverno.io \
    --as=system:serviceaccount:kyverno:kyverno-background-controller -A
yes
```

---

## 6. La trampa del autogen

Esta es la razón más común de que una excepción que parece correcta no haga nada, y es material de examen.

Las políticas de Kyverno normalmente se escriben contra `Pod`, porque ahí es donde viven los campos relevantes para seguridad. Pero nadie despliega Pods pelados. Así que Kyverno **autogenera** reglas adicionales que aplican la misma verificación al pod template de los controladores de cargas de trabajo. Las reglas generadas reciben nombres derivados:

| La regla fuente matchea | Nombre de la regla generada | Aplica a |
|---|---|---|
| `Pod` | `<rule-name>` (la original) | `Pod` |
| `Pod` | `autogen-<rule-name>` | `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `ReplicationController`, `Job` |
| `Pod` | `autogen-cronjob-<rule-name>` | `CronJob` |

El comportamiento de autogen se dirige con una annotation en la política:

```yaml
metadata:
  annotations:
    # Restrict which controllers get generated rules; "none" disables autogen.
    pod-policies.kyverno.io/autogen-controllers: DaemonSet,Deployment,StatefulSet
```

Una excepción que lista solo `ruleNames: [host-path]` no va a eximir un Deployment, porque la regla que se disparó fue `autogen-host-path`. Una excepción que lista solo `[autogen-host-path]` exime el Deployment y después cada Pod que crea es rechazado.

**El procedimiento confiable, en orden de preferencia:**

1. Leer el nombre de la regla en la denegación de admisión (§4.2) o en el campo `rule` del PolicyReport. Esto es empírico y no puede estar mal.
2. Enumerar qué corrió realmente, para un recurso que puedas crear:

```console
$ kubectl -n observability get polr -o json | jq -r '
    .items[]
    | select(.scope.name=="node-log-shipper")
    | .results[] | [.policy, .rule, .result] | @tsv'
disallow-host-path	autogen-host-path	skip
require-run-as-nonroot	autogen-run-as-nonroot	pass
require-requests-limits	autogen-requests-limits	pass
restrict-image-registries	autogen-validate-registries	pass
```

3. Cubrir las tres formas explícitamente:

```yaml
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
    - autogen-cronjob-host-path
```

### El comodín, y por qué prohibirlo

`ruleNames` acepta globs, así que esto cubre todas las variantes en una línea:

```yaml
  exceptions:
  - policyName: disallow-host-path
    ruleNames: ["*"]
```

También cubre **todas las reglas que la política vaya a contener alguna vez**. Cuando el equipo de plataforma agregue una segunda regla a `disallow-host-path` el trimestre que viene — digamos, una que bloquee `hostPath` en `ephemeral-containers` — el comodín también la exime, retroactiva y silenciosamente. `ruleNames: ["*"]` convierte una excepción en una exención permanente del futuro de una política.

Un glob más angosto es defendible cuando está anclado:

```yaml
    ruleNames: ["*host-path"]     # covers host-path, autogen-host-path, autogen-cronjob-host-path
```

`ruleNames: ["*"]` lo deniega la meta-política de §9.

---

## 7. Atar la exención a un hecho, no a una identidad

`spec.match` responde "qué objeto". `spec.conditions` responde "bajo qué circunstancias". La diferencia importa porque `match` selecciona sobre metadatos que controla el equipo solicitante; `conditions` puede seleccionar sobre la *sustancia* del pedido.

El log shipper fue eximido para leer `/var/log/pods`. Nada en la excepción de §4.3 impide que el equipo monte `/etc/kubernetes/pki` bajo las mismas labels. Esto sí:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: allow-hostpath-log-shipper
  namespace: observability
  labels:
    cleanup.kyverno.io/ttl: 90d
  annotations:
    exceptions.platform.example.com/owner: observability-sre@example.com
    exceptions.platform.example.com/ticket: PLAT-4471
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - DaemonSet
        - Pod
        namespaces:
        - observability
        selector:
          matchLabels:
            app.kubernetes.io/name: node-log-shipper
  conditions:
    all:
    # Every hostPath in the request must be one of the approved paths.
    - key: "{{ request.object.spec.template.spec.volumes[?hostPath != null].hostPath.path || request.object.spec.volumes[?hostPath != null].hostPath.path || `[]` }}"
      operator: AllIn
      value:
      - /var/log/pods
      - /var/log/containers
    # ...and every one of them must be mounted read-only.
    - key: "{{ request.object.spec.template.spec.containers[].volumeMounts[?name == 'podlogs'].readOnly || request.object.spec.containers[].volumeMounts[?name == 'podlogs'].readOnly || `[]` }}"
      operator: AllIn
      value:
      - true
  exceptions:
  - policyName: disallow-host-path
    ruleNames:
    - host-path
    - autogen-host-path
```

Si la condición no se cumple, la excepción no aplica, la regla corre y el pedido lo deniega la política original. La exención ahora está atada al comportamiento justificado y no a una label que cualquiera en el namespace puede poner.

Probá el JMESPath antes de enviarlo — una expresión que devuelve vacío en silencio hace que `AllIn` sea trivialmente verdadero y te deja una exención más amplia de la que escribiste:

```console
$ kubectl -n observability get ds node-log-shipper -o json \
  | jq -r '.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path'
/var/log/pods
```

### `background` y el contexto exclusivo de admisión

`spec.background` controla si la excepción se respeta durante los escaneos en segundo plano, que son los que producen PolicyReports para recursos que ya existen.

| `background` | Admisión | Escaneo en background / reportes | Consecuencia |
|---|---|---|---|
| `true` (por defecto) | La excepción aplica | La excepción aplica | El recurso muestra `skip`. Esto es lo que casi siempre querés. |
| `false` | La excepción aplica | La excepción se ignora — la regla corre | El recurso se admite y después se reporta `fail` para siempre. Tu dashboard alerta sobre una carga de trabajo que aprobaste deliberadamente. |

**Tenés que** poner `background: false` cuando `spec.conditions` referencia contexto exclusivo de admisión, porque esas variables no existen durante un escaneo en background:

- `request.userInfo.*`, `request.roles`, `request.clusterRoles`
- `request.operation`
- `serviceAccountName`, `serviceAccountNamespace`

De la misma manera, `spec.match.any[].subjects` / `roles` / `clusterRoles` son conceptos de tiempo de admisión. Una excepción que matchea sobre *quién envió el pedido* no se puede evaluar cuando nadie está enviando nada.

Aceptá el intercambio: esas excepciones producen entradas `fail` permanentes en los reportes. Preferí condiciones sobre los campos del propio objeto siempre que sea posible, precisamente para poder mantener `background: true` y mantener el reporte honesto.

---

## 8. Exenciones quirúrgicas para Pod Security Standards

Kyverno puede hacer cumplir todo el perfil de Pod Security Standards con una sola subregla:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-baseline
spec:
  background: true
  rules:
  - name: baseline
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      failureAction: Enforce
      podSecurity:
        level: baseline
        version: latest
```

Un `PolicyException` común contra la regla `baseline` saltearía **todo el perfil baseline** para la carga de trabajo matcheada — contenedores privilegiados, namespaces del host, puertos del host, todo. Para eximir la necesidad de `privileged: true` de un único Pod de driver estarías descartando once controles más.

`spec.podSecurity` en la excepción resuelve exactamente esto. Quita controles nombrados de la evaluación y deja que la regla corra sobre el resto:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: gpu-driver-privileged
  namespace: gpu-operator
  labels:
    cleanup.kyverno.io/ttl: 180d
  annotations:
    exceptions.platform.example.com/owner: platform-gpu@example.com
    exceptions.platform.example.com/ticket: PLAT-4390
    exceptions.platform.example.com/justification: >-
      The NVIDIA driver container compiles and inserts kernel modules on the
      node; this requires a privileged container. Scoped to the vendor image
      only. All other baseline controls remain enforced on this workload.
spec:
  background: true
  match:
    any:
    - resources:
        kinds:
        - Pod
        - DaemonSet
        namespaces:
        - gpu-operator
        selector:
          matchLabels:
            app: nvidia-driver-daemonset
  exceptions:
  - policyName: psa-baseline
    ruleNames:
    - baseline
    - autogen-baseline
  podSecurity:
  - controlName: Privileged Containers
    images:
    - "nvcr.io/nvidia/driver:*"
  - controlName: Capabilities
    images:
    - "nvcr.io/nvidia/driver:*"
    restrictedField: spec.containers[*].securityContext.capabilities.add
    values:
    - SYS_ADMIN
    - SYS_MODULE
```

| | Excepción a nivel de regla | Excepción `podSecurity` |
|---|---|---|
| Qué se saltea | La regla entera — todos los controles del perfil | Solo los controles nombrados |
| Acotada a una imagen | No | Sí, vía glob de `images` |
| Acotada a un valor de campo | No | Sí, vía `restrictedField` + `values` |
| Resultado reportado para la regla | `skip` | La regla igual evalúa los controles restantes, así que una carga de trabajo conforme reporta `pass` |
| Radio de impacto | Todo el perfil PSS | Un control, una imagen, un valor |

Esa última fila tiene una consecuencia operativa: con una excepción `podSecurity`, una violación *nueva* de un control *distinto* en la misma carga de trabajo se sigue detectando y sigue bloqueando. Con una excepción a nivel de regla, no. Confirmá el resultado reportado en tu propio clúster después de aplicar una — `kubectl -n gpu-operator get polr -o json | jq '.items[].results[] | select(.policy=="psa-baseline")'` — y basá cualquier dashboard en lo que observes.

Los nombres de control vienen de la tabla upstream de Pod Security Standards (`Privileged Containers`, `Host Namespaces`, `HostPath Volumes`, `Host Ports`, `Capabilities`, `HostProcess`, `Seccomp`, `SELinux`, `Sysctls`, `/proc Mount Type`, `AppArmor` para baseline; restricted agrega `Volume Types`, `Privilege Escalation`, `Running as Non-root`, `Running as Non-root user`). Un nombre de control mal escrito es una cadena válida para el esquema que no matchea nada — verificá contra la tabla upstream, y verificá empíricamente que la carga de trabajo se admite por el motivo correcto.

---

## 9. Gobernar las excepciones: RBAC, confinamiento, meta-política, vencimiento

Un mecanismo de excepción sin gobernanza es un mecanismo de bypass. Cuatro controles, aplicados juntos.

### 9.1 RBAC — conceder la creación de forma acotada

Todos tienen lectura. Casi nadie tiene escritura, y nunca a nivel de clúster.

```yaml
---
# Cluster-wide READ. Exceptions are a security-relevant inventory; make it visible.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:exceptions-viewer
rules:
- apiGroups: ["kyverno.io"]
  resources: ["policyexceptions"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno:exceptions-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:exceptions-viewer
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:authenticated
---
# WRITE, namespace-scoped, granted per team by an explicit RoleBinding.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:exceptions-author
rules:
- apiGroups: ["kyverno.io"]
  resources: ["policyexceptions"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: exceptions-author
  namespace: observability
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kyverno:exceptions-author
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: observability-sre
```

Verificá que la concesión sea tan angosta como pretendías — incluido el caso negativo:

```console
$ kubectl auth can-i create policyexceptions.kyverno.io \
    -n observability --as-group=observability-sre --as=alice@example.com
yes

$ kubectl auth can-i create policyexceptions.kyverno.io \
    -n kube-system --as-group=observability-sre --as=alice@example.com
no

$ kubectl auth can-i create policyexceptions.kyverno.io \
    -A --as-group=observability-sre --as=alice@example.com
no
```

**No metas `policyexceptions` dentro de un rol tipo `edit` de admin de namespace.** En muchos clústeres `edit` está asociado ampliamente; agregar el CRD le concede a cada admin de namespace la capacidad de escribir excepciones.

### 9.2 Confinamiento — la excepción no debe alcanzar fuera de su namespace

RBAC controla *dónde se crea el objeto*, no *qué nombra su bloque `match`*. Alice puede crear un `PolicyException` en `observability` cuyo `spec.match` nombre `namespaces: [kube-system]`. Cerrá eso con una política de Kyverno que valide los propios objetos `PolicyException` — las políticas aplican a cualquier recurso de Kubernetes, incluidos los CRDs del propio Kyverno.

### 9.3 La meta-política

`policies/govern-policy-exceptions.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: govern-policy-exceptions
  annotations:
    policies.kyverno.io/title: Govern PolicyExceptions
    policies.kyverno.io/category: Platform Governance
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: PolicyException
    policies.kyverno.io/description: >-
      PolicyExceptions are a delegated bypass of cluster security policy. This
      policy constrains them: no wildcard rule names, no cross-namespace reach,
      mandatory owner/ticket/expiry metadata, and a protected set of policies
      that may only be excepted from the platform namespace.
spec:
  background: false
  rules:

  # ---------------------------------------------------------------------------
  - name: no-wildcard-rule-names
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        A PolicyException must name the rules it exempts. ruleNames: ["*"] also
        exempts every rule added to the policy in the future. Read the rule name
        from the admission denial or the PolicyReport and list it explicitly.
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "*"
              operator: AnyIn
              value: "{{ element.ruleNames }}"

  # ---------------------------------------------------------------------------
  - name: exception-confined-to-own-namespace
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    preconditions:
      all:
      - key: "{{ request.object.metadata.namespace }}"
        operator: NotEquals
        value: platform-exceptions
    validate:
      failureAction: Enforce
      message: >-
        spec.match.any[].resources.namespaces must be exactly
        ["{{ request.object.metadata.namespace }}"]. A PolicyException may not
        exempt resources outside the namespace it lives in.
      foreach:
      - list: "request.object.spec.match.any"
        deny:
          conditions:
            any:
            - key: "{{ element.resources.namespaces || `[]` }}"
              operator: NotEquals
              value:
              - "{{ request.object.metadata.namespace }}"

  # ---------------------------------------------------------------------------
  - name: require-ownership-and-expiry
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        Every PolicyException must carry: label cleanup.kyverno.io/ttl, and
        annotations owner, ticket and justification under
        exceptions.platform.example.com/. Exceptions without an expiry become
        permanent policy holes.
      pattern:
        metadata:
          labels:
            cleanup.kyverno.io/ttl: "?*"
          annotations:
            exceptions.platform.example.com/owner: "?*@example.com"
            exceptions.platform.example.com/ticket: "?*-?*"
            exceptions.platform.example.com/justification: "?*"

  # ---------------------------------------------------------------------------
  - name: ttl-must-not-exceed-180-days
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: >-
        cleanup.kyverno.io/ttl must be expressed in days and must not exceed
        180d. Longer-lived exemptions require an architecture review, not a TTL.
      deny:
        conditions:
          any:
          - key: "{{ regex_match('^[0-9]{1,3}d$', '{{ request.object.metadata.labels.\"cleanup.kyverno.io/ttl\" }}') }}"
            operator: Equals
            value: false
          - key: "{{ to_number(trim('{{ request.object.metadata.labels.\"cleanup.kyverno.io/ttl\" }}', 'd')) }}"
            operator: GreaterThan
            value: 180

  # ---------------------------------------------------------------------------
  - name: protected-policies-need-platform-review
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    preconditions:
      all:
      - key: "{{ request.object.metadata.namespace }}"
        operator: NotEquals
        value: platform-exceptions
    validate:
      failureAction: Enforce
      message: >-
        Policy "{{ element.policyName }}" is on the protected list. An exception
        to it may only be created in the platform-exceptions namespace, by the
        platform team, after security review.
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "{{ element.policyName }}"
              operator: AnyIn
              value:
              - disallow-privileged-containers
              - disallow-host-namespaces
              - disallow-capabilities-strict
              - restrict-image-registries
              - verify-image-signatures
              - require-network-policy
```

La meta-política en acción:

```console
$ cat /tmp/bad-exception.yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: quick-fix
  namespace: team-a
spec:
  match:
    any:
    - resources:
        kinds: ["*"]
        namespaces: ["*"]
  exceptions:
  - policyName: disallow-privileged-containers
    ruleNames: ["*"]

$ kubectl apply -f /tmp/bad-exception.yaml
Error from server: error when creating "/tmp/bad-exception.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource PolicyException/team-a/quick-fix was blocked due to the following policies

govern-policy-exceptions:
  no-wildcard-rule-names: 'A PolicyException must name the rules it exempts. ruleNames:
    ["*"] also exempts every rule added to the policy in the future. Read the rule
    name from the admission denial or the PolicyReport and list it explicitly.'
  exception-confined-to-own-namespace: 'spec.match.any[].resources.namespaces must
    be exactly ["team-a"]. A PolicyException may not exempt resources outside the
    namespace it lives in.'
  require-ownership-and-expiry: 'validation error: Every PolicyException must carry:
    label cleanup.kyverno.io/ttl, and annotations owner, ticket and justification
    under exceptions.platform.example.com/. Exceptions without an expiry become
    permanent policy holes. rule require-ownership-and-expiry failed at path /metadata/labels/'
  protected-policies-need-platform-review: 'Policy "disallow-privileged-containers"
    is on the protected list. An exception to it may only be created in the
    platform-exceptions namespace, by the platform team, after security review.'
```

**Una cosa que hay que hacer bien:** la meta-política es ella misma un `ClusterPolicy`, así que se le puede hacer una excepción. Poné `govern-policy-exceptions` en su propia lista de protegidas y — por las dudas, doble cinturón — denegá las excepciones que la nombren siquiera:

```yaml
  - name: meta-policy-is-not-exceptable
    match:
      any:
      - resources:
          kinds:
          - PolicyException
    validate:
      failureAction: Enforce
      message: "govern-policy-exceptions cannot be excepted."
      foreach:
      - list: "request.object.spec.exceptions"
        deny:
          conditions:
            any:
            - key: "{{ element.policyName }}"
              operator: Equals
              value: govern-policy-exceptions
```

### 9.4 Vencimiento — hacer que las excepciones se auto-eliminen

El controlador de cleanup de Kyverno respeta una label de TTL en **cualquier** recurso, incluidos sus propios CRDs. Esto convierte "las excepciones se acumulan para siempre" en "las excepciones se renuevan a propósito".

```yaml
metadata:
  labels:
    cleanup.kyverno.io/ttl: 90d          # relative: 90 days after creation
    # or an absolute instant:
    # cleanup.kyverno.io/ttl: "2026-12-31T23:59:59Z"
```

```console
$ kubectl -n observability get polex allow-hostpath-log-shipper \
    -o jsonpath='{.metadata.creationTimestamp}{"  ttl="}{.metadata.labels.cleanup\.kyverno\.io/ttl}{"\n"}'
2026-08-14T09:41:12Z  ttl=90d

$ kubectl -n kyverno logs deploy/kyverno-cleanup-controller --tail=5 | grep -i policyexception
I0814 09:41:14.882031  1 controller.go:214] cleanup-controller "msg"="resource scheduled for deletion" "gvr"="kyverno.io/v2, Resource=policyexceptions" "namespace"="observability" "name"="allow-hostpath-log-shipper" "deletionTime"="2026-11-12T09:41:12Z"
```

Cuando se borra la excepción, la política vuelve a hacer cumplir. Poné `allowExistingViolations: true` en la política (como en §4.1) para que el vencimiento no rompa inmediatamente las cargas de trabajo en ejecución — el DaemonSet ya admitido sigue corriendo y empieza a reportar `fail`, que es la señal para que el dueño renueve o remedie. Sin ese campo, la próxima actualización de la carga de trabajo es rechazada, que es una forma sorpresiva de descubrir que una excepción venció.

La alerta complementaria (§11) se dispara cuando a una excepción le faltan menos de siete días para vencer, así que renovar es una decisión y no una caída.

---

## 10. Probar las excepciones en CI, antes de que lleguen a un clúster

Las excepciones son configuración relevante para seguridad. Pertenecen al mismo arnés de pruebas que las políticas.

Estructura del repositorio:

```
policy-tests/
└── disallow-host-path/
    ├── policy.yaml
    ├── resource.yaml            # the log shipper DaemonSet
    ├── resource-violating.yaml  # a DaemonSet mounting /etc, must still be blocked
    ├── exception.yaml
    └── kyverno-test.yaml
```

`kyverno-test.yaml`:

```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: disallow-host-path-with-exception
policies:
- policy.yaml
resources:
- resource.yaml
- resource-violating.yaml
exceptions:
- exception.yaml
results:
# The exempted workload is skipped, not passed. Assert the skip explicitly.
- policy: disallow-host-path
  rule: autogen-host-path
  kind: DaemonSet
  resources:
  - node-log-shipper
  result: skip
# The exception must NOT widen to other workloads in the same namespace.
- policy: disallow-host-path
  rule: autogen-host-path
  kind: DaemonSet
  resources:
  - rogue-agent
  result: fail
```

La segunda aserción es la que se gana el sueldo: es una prueba de regresión contra un bloque `match` demasiado amplio.

```console
$ kyverno version
Version: 1.13.4
Time: 2026-06-18T11:02:57Z
Git commit ID: 8f0e1c7a6b4d2e9f31c05a7b8e6d4f2a19c3b0d7

$ kyverno test policy-tests/

Loading test  ( policy-tests/disallow-host-path/kyverno-test.yaml ) ...
  Loading values/variables ...
  Loading policies ...
  Loading resources ...
  Loading exceptions ...
  Applying 1 policy to 2 resources ...
  Checking results ...

│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│
│ ID │ POLICY               │ RULE                │ RESOURCE                             │ RESULT │
│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│
│ 1  │ disallow-host-path   │ autogen-host-path   │ apps/v1/DaemonSet/node-log-shipper    │ Pass   │
│ 2  │ disallow-host-path   │ autogen-host-path   │ apps/v1/DaemonSet/rogue-agent         │ Pass   │
│────│──────────────────────│─────────────────────│──────────────────────────────────────│────────│

Test Summary: 2 tests passed and 0 tests failed
```

> `RESULT: Pass` en `kyverno test` significa *la aserción coincidió*, no *la política pasó*. El test 1 afirmó `skip` y obtuvo `skip`; el test 2 afirmó `fail` y obtuvo `fail`. Confundir estas dos cosas es un error de lectura clásico.

Evaluación ad-hoc sin archivo de test, útil cuando estás iterando sobre un bloque `conditions`:

```console
$ kyverno apply policy-tests/disallow-host-path/policy.yaml \
    --resource policy-tests/disallow-host-path/resource.yaml \
    --exception policy-tests/disallow-host-path/exception.yaml \
    --policy-report

Applying 1 policy rule(s) to 1 resource(s)...

pass: 0, fail: 0, warn: 0, error: 0, skip: 1
```

```console
$ kyverno apply policy-tests/disallow-host-path/policy.yaml \
    --resource policy-tests/disallow-host-path/resource.yaml

Applying 1 policy rule(s) to 1 resource(s)...

policy disallow-host-path -> resource observability/DaemonSet/node-log-shipper failed:
1. autogen-host-path: validation error: HostPath volumes are forbidden. The field spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

Correr ambos — con y sin `--exception` — prueba que la excepción es lo que cambió el resultado, y no alguna deriva ajena en el manifiesto.

Compuerta de CI:

```yaml
# .github/workflows/policy.yaml
name: policy
on: [pull_request]
jobs:
  kyverno-test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Install Kyverno CLI
      uses: kyverno/action-install-cli@v0.2.0
    - name: Validate manifests parse
      run: kubectl --dry-run=client apply -f policy-tests/ --recursive -o name
    - name: Run policy tests
      run: kyverno test policy-tests/ --detailed-results
    - name: Exceptions must satisfy the meta-policy
      run: |
        kyverno apply policies/govern-policy-exceptions.yaml \
          --resource exceptions/ \
          --policy-report
```

Ese último paso es el importante: corre la meta-política de §9 contra los manifiestos de excepción **dentro del pull request**, así una excepción demasiado amplia se rechaza en la revisión y no en el momento del `kubectl apply`.

---

## 11. Verificación y diagnóstico de fallas

### 11.1 Triaje ordenado

Trabajá de arriba hacia abajo. Cada paso es barato y elimina toda una clase de causas.

```console
# 1. Is the feature even on?
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kyverno")].args}' \
  | tr ',' '\n' | tr -d '[]"' | grep -i exception
--enablePolicyException=true
--exceptionNamespace=

# 2. Does the object exist, in the namespace Kyverno will look at?
$ kubectl get polex -A
NAMESPACE       NAME                         AGE
observability   allow-hostpath-log-shipper   3m21s

# 3. Is the policy actually ready and enforcing?
$ kubectl get cpol disallow-host-path
NAME                 ADMISSION   BACKGROUND   READY   AGE   MESSAGE
disallow-host-path   true        true         True    18m   Ready

# 4. What rule name did Kyverno evaluate? (empirical, not guessed)
$ kubectl -n observability get polr -o json \
  | jq -r '.items[].results[] | [.policy, .rule, .result] | @tsv' | sort -u
disallow-host-path	autogen-host-path	skip
disallow-host-path	host-path	skip

# 5. Does the exception name that exact rule?
$ kubectl -n observability get polex allow-hostpath-log-shipper \
    -o jsonpath='{.spec.exceptions}' | jq
[
  {
    "policyName": "disallow-host-path",
    "ruleNames": [
      "host-path",
      "autogen-host-path"
    ]
  }
]

# 6. Anything the controller wants to tell you?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 \
  | grep -i -E 'exception|polex'
```

### 11.2 Tabla de síntomas

| Síntoma | Causa más probable | Confirmar con | Solución |
|---|---|---|---|
| `error: the server doesn't have a resource type "policyexceptions"` | CRD no instalado | `kubectl get crd \| grep policyexception` | Instalar/actualizar el chart de Kyverno con `features.policyExceptions.enabled=true` |
| La excepción aplica limpiamente, el recurso igual es denegado | Feature flag apagado | §11.1 paso 1 | Habilitar el flag y reiniciar el admission controller |
| La excepción existe, se ignora, no hay errores en ningún lado | `--exceptionNamespace` confina las excepciones a otro namespace | §11.1 paso 1 — el flag tiene un valor no vacío | Mover la excepción ahí, o limpiar el flag |
| Funciona para `Pod`, falla para `Deployment`/`DaemonSet` | Falta `autogen-<rule>` en `ruleNames`, o falta el kind del controlador en `match.kinds` | Comparar el nombre de regla de la denegación con `spec.exceptions[].ruleNames` | Agregar `autogen-<rule>` (y `autogen-cronjob-<rule>`) y el kind del controlador |
| El objeto controlador se admite, todos sus Pods son rechazados | Se eximió el kind del controlador pero no `Pod` | `kubectl -n <ns> describe rs\|ds <name>` → eventos `FailedCreate` citando el webhook | Agregar `Pod` a `match.kinds` y el nombre base de la regla a `ruleNames` |
| La admisión funciona, el PolicyReport igual dice `fail` | `spec.background: false`, o el controlador de background/reportes no puede leer las excepciones | `kubectl get polex -o jsonpath='{.spec.background}'`; `kubectl auth can-i list policyexceptions --as=system:serviceaccount:kyverno:kyverno-background-controller -A` | Poner `background: true` (sacando las variables exclusivas de admisión de `conditions`), o corregir el RBAC del controlador |
| El reporte no dice absolutamente nada del recurso | El namespace está filtrado en la capa del webhook por `resourceFilters` | `kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}'` | Ajustar `resourceFilters`; ojo que es una herramienta más burda que una excepción |
| La excepción matchea mucho más de lo pretendido | `names: ["*"]`, `kinds: ["*"]`, o una lista `namespaces` más amplia que el propio namespace del objeto | `kubectl get polr -A -o json \| jq -r '.items[].results[] \| select(.result=="skip") \| [.policy,.rule] \| @tsv' \| sort \| uniq -c` | Ajustar `match`; hacer cumplir la meta-política de §9 |
| La excepción funcionaba, dejó de funcionar tras una actualización | La versión de API almacenada migró (`v2beta1` → `v2`), o se removió un campo | `kubectl get crd policyexceptions.kyverno.io -o jsonpath='{.status.storedVersions}'`; `kubectl explain polex.spec` | Reaplicar los manifiestos en la versión actual; correr `kyverno test` contra el nuevo CLI en CI |
| La excepción fue aceptada pero una guarda de `conditions` nunca se dispara | El JMESPath devuelve vacío, haciendo la comparación trivial | Evaluar la misma expresión con `jq` contra el objeto vivo (§7) | Corregir la ruta; agregar un filtro `!= null` y un default `\|\| \`[]\``, y volver a probar con `kyverno apply` |
| Un pedido denegado nombra una regla que no eximiste | La política tiene más de una regla, o matcheó una segunda política | Leé el cuerpo completo de la denegación — se listan todas las políticas y reglas que fallan | Agregar los `ruleNames` faltantes, o una segunda entrada bajo `spec.exceptions` |
| La excepción `podSecurity` no tiene efecto | `controlName` mal escrito, o el glob de `images` no coincide con la referencia de imagen que realmente está en el Pod | `kubectl -n <ns> get pod <p> -o jsonpath='{.spec.containers[*].image}'` y compararlo con el glob | Usar el nombre de control upstream exacto; ampliar el glob para incluir la forma de registry y tag |

### 11.3 Qué tiene que significar "funciona"

Una excepción está verificada solo cuando se cumplen las cuatro cosas. Menos que eso y lo que confirmaste es una coincidencia:

1. **La carga de trabajo eximida se admite.** `kubectl apply` tiene éxito, `rollout status` se completa.
2. **La exención queda registrada.** Aparece un resultado `skip` nombrando la excepción en el PolicyReport — para el controlador *y* para sus Pods.
3. **La excepción no se ensanchó.** Una carga de trabajo deliberadamente no conforme en el mismo namespace, fuera del selector de la excepción, sigue siendo denegada:

```console
$ kubectl -n observability apply -f /tmp/rogue-agent.yaml
Error from server: error when creating "/tmp/rogue-agent.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource DaemonSet/observability/rogue-agent was blocked due to the following policies

disallow-host-path:
  autogen-host-path: 'validation error: HostPath volumes are forbidden. The field
    spec.volumes[*].hostPath must be unset. Request an exemption with a PolicyException.
    rule autogen-host-path failed at path /spec/template/spec/volumes/0/hostPath/'
```

4. **La exención se revierte.** Borrá la excepción y confirmá que la política vuelve:

```console
$ kubectl -n observability delete polex allow-hostpath-log-shipper
policyexception.kyverno.io "allow-hostpath-log-shipper" deleted

$ kubectl -n observability rollout restart ds/node-log-shipper
daemonset.apps/node-log-shipper restarted

$ kubectl -n observability get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -2
2m          Warning   FailedCreate   daemonset/node-log-shipper   Error creating: admission webhook "validate.kyverno.svc-fail" denied the request: resource Pod/observability/node-log-shipper-x9k2p was blocked due to the following policies

disallow-host-path:
  host-path: 'validation error: HostPath volumes are forbidden...'
```

El paso 4 es el que la gente se saltea, y es el que prueba que la *política* alguna vez estuvo haciendo algo.

### 11.4 Métricas y alertas

```console
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 >/dev/null 2>&1 &
[1] 21884

$ curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | grep 'rule_result="skip"'
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="",policy_type="ClusterPolicy",policy_validation_mode="enforce",resource_kind="DaemonSet",resource_namespace="observability",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="autogen-host-path",rule_result="skip",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-host-path",policy_namespace="",policy_type="ClusterPolicy",policy_validation_mode="enforce",resource_kind="Pod",resource_namespace="observability",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="host-path",rule_result="skip",rule_type="validate"} 6
```

> Los conjuntos de labels de las métricas cambian entre releases menores. Leé el conjunto real de labels una vez con `curl -s localhost:8000/metrics | grep '^kyverno_policy_results_total' | head -1` antes de escribir recording rules contra él, en vez de copiar nombres de labels de la documentación.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-exceptions
  namespace: kyverno
spec:
  groups:
  - name: kyverno-exceptions
    rules:

    # A protected control was skipped. This should never happen outside the
    # platform-exceptions namespace; if it does, an exception got past review.
    - alert: KyvernoProtectedPolicySkipped
      expr: |
        sum by (policy_name, rule_name, resource_namespace) (
          increase(kyverno_policy_results_total{
            rule_result="skip",
            policy_name=~"disallow-privileged-containers|restrict-image-registries|verify-image-signatures"
          }[1h])
        ) > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Protected policy {{ $labels.policy_name }} skipped in {{ $labels.resource_namespace }}"
        description: >-
          Rule {{ $labels.rule_name }} was skipped by a PolicyException.
          Inventory: kubectl get polex -A -o wide

    # Skip volume growing fast usually means an exception widened, not that a
    # new workload appeared.
    - alert: KyvernoExceptionScopeGrowing
      expr: |
        sum by (policy_name, resource_namespace) (
          increase(kyverno_policy_results_total{rule_result="skip"}[24h])
        )
        >
        3 * sum by (policy_name, resource_namespace) (
          increase(kyverno_policy_results_total{rule_result="skip"}[24h] offset 7d)
        )
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "Exception scope for {{ $labels.policy_name }} tripled in {{ $labels.resource_namespace }}"
```

Combiná las alertas de métricas con un reporte de inventario programado, porque una excepción que nunca se ejercita igual existe:

```console
$ kubectl get polex -A -o json | jq -r '
    .items[]
    | [ .metadata.namespace,
        .metadata.name,
        (.metadata.labels["cleanup.kyverno.io/ttl"] // "NO-TTL"),
        (.metadata.annotations["exceptions.platform.example.com/owner"] // "NO-OWNER"),
        ([.spec.exceptions[].policyName] | join(","))
      ] | @tsv' | column -t
gpu-operator    gpu-driver-privileged       30d     platform-gpu@example.com        psa-baseline
observability   allow-hostpath-log-shipper  90d     observability-sre@example.com   disallow-host-path
data-eng        spark-sys-nice              NO-TTL  NO-OWNER                        restrict-capabilities
```

El `NO-TTL` / `NO-OWNER` de esa última fila es una excepción creada antes de que se hiciera cumplir la meta-política — Kyverno valida en admisión, así que los objetos preexistentes no se revisan retroactivamente. Rellená corriendo la meta-política como escaneo en background (`spec.background: true` con `failureAction: Audit` en una copia) y triando el reporte resultante antes de activar la versión que hace cumplir.

---

## 12. Superficie sensible a la versión — verificá, no asumas

La API de `PolicyException` creció a lo largo de los releases. En vez de memorizar una matriz de versiones, verificá contra el clúster que tenés enfrente. Cada fila de abajo es una verificación de un comando.

| Capacidad | Verificar con |
|---|---|
| Versiones de API servidas (`v2alpha1` / `v2beta1` / `v2`) | `kubectl get crd policyexceptions.kyverno.io -o jsonpath='{.spec.versions[*].name}{"\n"}{.status.storedVersions}'` |
| Funcionalidad habilitada, y confinada o no | `kubectl -n kyverno get deploy kyverno-admission-controller -o yaml \| grep -i -E 'enablePolicyException\|exceptionNamespace'` |
| `spec.conditions` disponible | `kubectl explain polex.spec.conditions` |
| `spec.podSecurity` disponible | `kubectl explain polex.spec.podSecurity` |
| Qué tipos de regla respetan las excepciones (`validate`, `mutate`, `generate`, `verifyImages`) | Escribí una política de dos reglas, una de cada tipo; hacé excepción a una; leé el PolicyReport buscando `skip` |
| `validate.failureAction` vs `spec.validationFailureAction` | `kubectl explain cpol.spec.rules.validate.failureAction` |
| Excepciones contra tipos de política basados en CEL (`spec.policyRefs`) | `kubectl explain polex.spec.policyRefs` — si el campo no está, tu release ata las excepciones solo a `policyName` |
| Interacción con objetos `ValidatingAdmissionPolicy` generados | `kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding` e inspeccioná `matchConditions` — una VAP nativa no sabe nada del CRD `PolicyException`, así que confirmá empíricamente que una carga de trabajo eximida vía Kyverno también sea admitida por cualquier VAP generada |

Esa última fila merece un momento. Si tu clúster depende de que Kyverno genere objetos `ValidatingAdmissionPolicy` nativos por rendimiento, el camino de enforcement de algunas políticas es el propio evaluador CEL del API server, no el webhook de Kyverno. Que una excepción se refleje ahí depende de cómo Kyverno exprese la exclusión en el binding generado. **Probalo. No lo infieras.** El modo de falla — una carga de trabajo que los reportes dicen que está eximida, denegada por un objeto de política que vos no escribiste — es genuinamente difícil de diagnosticar solo desde el mensaje.

---

## 13. Checklist de examen

- `PolicyException` tiene **namespace**, nombre corto `polex`, grupo `kyverno.io`, versión actual `v2`.
- Campos obligatorios: `spec.match` (qué recursos) y `spec.exceptions[].policyName` + `ruleNames` (qué reglas de política).
- Un recurso eximido se reporta como **`skip`** — nunca `pass`, nunca ausente.
- `metadata.namespace` gobierna el **RBAC**; `spec.match` gobierna el **alcance**. No son lo mismo, y sin restricciones divergen.
- Los controladores de cargas de trabajo los valida **`autogen-<rule>`**; los CronJobs, **`autogen-cronjob-<rule>`**. Eximí el controlador *y* el Pod, o los Pods van a ser rechazados después de que el controlador se admita.
- `ruleNames: ["*"]` también exime las reglas que se agreguen a la política más adelante. Preferí nombres explícitos o un glob anclado.
- `spec.background: false` cuando `conditions`/`match` referencian contexto exclusivo de admisión (`request.userInfo`, `request.operation`, subjects/roles). Esperá entradas `fail` permanentes en los reportes como precio.
- `spec.podSecurity` exime **un solo control PSS** (opcionalmente para un glob de imagen y un valor de campo) en vez de la regla completa — la herramienta de mayor precisión del CRD.
- Dos feature flags deciden si pasa algo o no: `--enablePolicyException` y `--exceptionNamespace`.
- Kyverno CLI: `kyverno apply --exception <file>` para evaluación ad-hoc; `exceptions:` en `kyverno-test.yaml` con `result: skip` para CI.
- Las excepciones las validan las políticas de Kyverno como a cualquier otro recurso — la meta-política es el control que hace seguro el autoservicio.
- `cleanup.kyverno.io/ttl` en la excepción la hace auto-eliminable; combinalo con `allowExistingViolations: true` en la política para que el vencimiento se manifieste como un reporte y no como una caída.

---

## Referencias

**Kyverno — documentación oficial**

- Kyverno documentation home — https://kyverno.io/docs/
- Policy exceptions — https://kyverno.io/docs/writing-policies/exceptions/
- Validate rules and failure actions — https://kyverno.io/docs/writing-policies/validate/
- Auto-generation rules for pod controllers — https://kyverno.io/docs/writing-policies/autogen/
- Match / exclude resource selection — https://kyverno.io/docs/writing-policies/match-exclude/
- Preconditions and JMESPath operators — https://kyverno.io/docs/writing-policies/preconditions/
- JMESPath in Kyverno — https://kyverno.io/docs/writing-policies/jmespath/
- Variables and admission context — https://kyverno.io/docs/writing-policies/variables/
- Policy reports — https://kyverno.io/docs/policy-reports/
- Cleanup policies and the `cleanup.kyverno.io/ttl` label — https://kyverno.io/docs/writing-policies/cleanup/
- Installation and container flags — https://kyverno.io/docs/installation/customization/
- High availability and controller architecture — https://kyverno.io/docs/high-availability/
- Kyverno CLI — `apply` — https://kyverno.io/docs/kyverno-cli/usage/apply/
- Kyverno CLI — `test` — https://kyverno.io/docs/kyverno-cli/usage/test/
- Monitoring and metrics — https://kyverno.io/docs/monitoring/
- Pod Security Standards enforcement with Kyverno — https://kyverno.io/docs/writing-policies/validate/pod-security/
- Kyverno policy library — https://kyverno.io/policies/

**Kyverno — fuente de verdad para la superficie de API**

- Kyverno repository — https://github.com/kyverno/kyverno
- `PolicyException` Go types (`kyverno.io/v2`) — https://github.com/kyverno/kyverno/blob/main/api/kyverno/v2/policy_exception_types.go
- Kyverno release notes — https://github.com/kyverno/kyverno/releases
- Kyverno Helm chart — https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno chart on Artifact Hub — https://artifacthub.io/packages/helm/kyverno/kyverno
- Kyverno CLI install action — https://github.com/kyverno/action-install-cli

**Kubernetes upstream**

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Admission exemptions and configuration — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Dynamic admission control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- RBAC authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Volumes — `hostPath` — https://kubernetes.io/docs/concepts/storage/volumes/#hostpath

**Estándares y currícula**

- Kubernetes Policy WG — Policy Report CRD (`wgpolicyk8s.io`) — https://github.com/kubernetes-sigs/wg-policy-prototypes/tree/master/policy-report
- CNCF curriculum repository — https://github.com/cncf/curriculum
- KCA curriculum (PDF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf